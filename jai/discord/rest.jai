// REST execution. Jobs are built on the UI thread (actions.odin) or by the
// startup scheduler, and run on worker threads. Each job owns an arena with
// all its strings; results come back to the UI thread as Rest events.

Job_Kind :: enum u8 {
	Api; // https://discord.com/api/v9 + path, authenticated
	Web; // unauthenticated XHR to any https origin
	Upload; // attachments: POST /attachments, preflight + PUT, then send
}

Upload_File :: struct {
	filename: string;
	mime: string;
	data: []u8;
}

Job :: struct {
	arena: virtual.Arena;
	kind: Job_Kind;
	op: Rest_Op;
	method: string;
	host: string; // Web jobs
	path: string; // Api: below /api/v9 (with query). Web: full path.
	body: []u8;
	content_type: string;
	context_b64: string;
	extra: []http.Header;
	retries: int;
	not_before: s64;
	result: Rest_Result;
	// Web
	site: Fetch_Site;
	referer: string; // "" -> current route (Api) / https://discord.com/ (Web cross-origin)
	js_headers: []http.Header;
	// 429 handling: Send_Message requeues after Retry-After (MessageQueue), reactions retry once.
	retry_429: int;
	// Upload
	files: []Upload_File;
	message_json: (j: *Job, attachments_json: string) -> []u8; // builds the final send body
	upload_ctx: *void;
	draft: u64; // upload of one staged draft (uploads.odin)
	drafts: []Draft_Attachment; // message send waiting on these drafts
	requeue: bool; // run again at not_before instead of being freed
	no_auth: bool; // logged-out request (no authorization header)
	no_super_props: bool;
	etag: bool; // fetch(cache:'no-cache') + remembered If-None-Match
	preflight_if_etag: bool;
	no_cookies: bool; // cross-origin: If-None-Match makes it a preflighted request
	preflight_only: bool; // send only the CORS preflight (the request is a later job)
	on_body: (c: *Client, body: V); // worker-side follow-up on a 2xx JSON body
	on_done: (c: *Client, j: *Job, status: int); // worker-side, after any response (status 0: network failure)
	track_props: string; // on_done's event properties, built on the UI thread (job arena)
	on_response: (c: *Client, j: *Job, status: int, body: V); // worker-side, after any response, with the body
	started_ms: float64; // when the request was dispatched (on_done timings)
	js_lower_auth: bool; // page code set "authorization" (lowercase): only DevTools' view differs
	media: Media_Request;
}

job_new :: (kind: Job_Kind, op: Rest_Op) -> *Job {
	j := new(Job);
	virtual.arena_init_growing(*j.arena);
	j.kind = kind;
	j.op = op;
	j.result.op = op;
	return j;
}

job_alloc :: (j: *Job) -> Allocator {return virtual.arena_allocator(*j.arena);}

job_str :: (j: *Job, s: string) -> string {return clone(s, job_alloc(j));}

job_free :: (j: *Job) {
	virtual.arena_destroy(*j.arena);
	free(j);
}

job_submit :: (c: *Client, j: *Job) {
	locks.lock(*c.job_mu);
	append(*c.jobs, j);
	locks.cond_broadcast(*c.job_cond);
	locks.unlock(*c.job_mu);
}
#scope_module

worker_proc :: (c: *Client) {
	locks.lock(*c.job_mu);
	while !c.quit {
		now := now_ms();
		pick := -1;
		next_due: s64 = S64_MAX;
		for j, i: c.jobs {
			if j.not_before <= now {
				pick = i;
				break;
			}
			next_due = min(next_due, j.not_before);
		}
		if pick < 0 {
			wait := ifx next_due == S64_MAX then 1000 else max(next_due - now, 1);
			locks.cond_wait_with_timeout(*c.job_cond, *c.job_mu, wait);
			continue;
		}
		j := get(c.jobs, pick);
		ordered_remove(*c.jobs, pick);
		c.jobs_running += 1;
		// the moment the page would call fetch(): picks are serialized here, so
		// requests due together keep their queue order (traffic recording)
		context.tl_dispatch_ms = now_ms_f();
		locks.unlock(*c.job_mu);
		run_job(c, j);
		reset_temporary_storage();
		locks.lock(*c.job_mu);
		c.jobs_running -= 1;
		if j.requeue && !c.quit {
			j.requeue = false;
			append(*c.jobs, j);
		} else {
			job_free(j);
		}
	}
	locks.unlock(*c.job_mu);
}

run_job :: (c: *Client, j: *Job) {
	if j.kind == {
	case .Api;
		run_api(c, j);
	case .Web;
		if j.op == .Media { run_media(c, j); } else { run_web(c, j); }
	case .Upload;
		if j.draft != 0 {
			run_draft_upload(c, j);
		} else if len(j.drafts) > 0 {
			if run_draft_send(c, j) {
				j.requeue = true;
				j.not_before = now_ms() + 50;
			}
		} else {
			run_upload(c, j);
		}
	}
}
#scope_export

API_PREFIX :: "/api/v9";


// Result of one API call, body parsed into the event arena.
Api_Response :: struct {
	status: int;
	ok: bool;
	body: V;
	arena: *virtual.Arena;
	headers: []http.Header;
}

// api_call performs one authenticated request with the HTTP util's retry and
// rate-limit semantics. The returned arena (if any) owns body.
api_call :: (c: *Client, method: string, path: string, body: []u8, content_type: string, context_b64: string, extra: []http.Header, retries: int, retry_429: int, no_auth := false, no_super_props := false, referer := "") -> Api_Response {
	r: Api_Response;
	full_path := strings.concatenate(string.[API_PREFIX, path], temp);
	url_key := strings.concatenate(string.[API_ORIGIN, full_path], temp);
	retries_left := retries;
	retry_429_left := retry_429;
	failed := 0;
	backoff := backoff_make(500);
	while true {
		{ w := rate_wait_ms(*c.limiter, method, url_key, now_ms());
		if w > 0 {
			time.sleep(cast(time.Duration)(w) * time.Millisecond);
		} }
		now := now_ms();
		ex := extra;
		if failed > 0 {
			// X-Failed-Requests on retried requests.
			e2 := make_dynamic(http.Header, 0, len(extra) + 1, temp);
			for e: extra { append(*e2, e); }
			append(*e2, http.Header.{"x-failed-requests", itoa(failed)});
			ex = view(e2);
		}
		hin := Api_Headers_Input.{
			method = method,
			has_body = len(body) > 0,
			body_len = len(body),
			content_type = content_type,
			token = ifx no_auth then "" else client_token(c),
			fingerprint = auth_fingerprint(c),
			installation_id = c.id.installation_id,
			super_props_b64 = ifx no_super_props then "" else super_properties_b64(*c.id, now),
			context_b64 = context_b64,
			referer = ifx referer != "" then referer else client_route_referer(c),
			cookie = cookie_header(*c.jar, API_HOST, full_path, true, now),
			extra = ex
		};
		req := http.Request.{
			method = method,
			scheme = "https",
			authority = API_HOST,
			path = full_path,
			headers = api_headers(c.id.platform, hin),
			body = body
		};
		resp, err := transport_round_trip(*c.transport, API_HOST, req);
		if err != .None {
			http.response_destroy(*resp);
			if retries_left > 0 {
				retries_left -= 1;
				failed += 1;
				time.sleep(cast(time.Duration)(backoff_fail(*backoff)) * time.Millisecond);
				continue;
			}
			return .{status = 0};
		}
		if retries_left > 0 && is_retryable_status(resp.status) {
			http.response_destroy(*resp);
			retries_left -= 1;
			failed += 1;
			time.sleep(cast(time.Duration)(backoff_fail(*backoff)) * time.Millisecond);
			continue;
		}
		arena := new(virtual.Arena);
		virtual.arena_init_growing(arena);
		alloc := virtual.arena_allocator(arena);
		bv, _ := parse_json(resp.body,, alloc);
		hold := rate_note_response(*c.limiter, method, url_key, resp.status, view(resp.headers), bv, now_ms());
		if resp.status == 429 && retry_429_left > 0 {
			retry_429_left -= 1;
			ra, has := retry_after_seconds(view(resp.headers), bv);
			wait := ifx has then cast(s64)(ra * 1000) else hold;
			http.response_destroy(*resp);
			virtual.arena_destroy(arena);
			free(arena);
			time.sleep(cast(time.Duration)(max(wait, 0)) * time.Millisecond);
			continue;
		}
		hdrs := make_slice(http.Header, len(resp.headers), alloc);
		for h, i: resp.headers { hdrs[i] = .{clone(h.name, alloc), clone(h.value, alloc)}; }
		r = Api_Response.{status = resp.status, ok = resp.status >= 200 && resp.status < 300, body = bv, arena = arena, headers = hdrs};
		http.response_destroy(*resp);
		return r;
	}
}
#scope_module

push_result :: (c: *Client, j: *Job, r: Api_Response) {
	res := j.result;
	res.ok = r.ok;
	res.status = r.status;
	{ m := vmap(r.body);
	if !is_null(m) && res.id == 0 { res.id = fsnow(m, "id"); } }
	client_push_event(c, Event.{kind = .Rest, data = r.body, arena = r.arena, result = res});
}

run_api :: (c: *Client, j: *Job) {
	extra := j.extra;
	url := strings.concatenate(string.[API_ORIGIN, API_PREFIX, j.path], temp);
	if j.etag {
		e := make_dynamic(http.Header, 0, 2, temp);
		append(*e, http.Header.{"cache-control", "max-age=0"});
		{ tag := etag_get(c, url);
		if tag != "" { append(*e, http.Header.{"if-none-match", tag}); } }
		extra = view(e);
	}
	context.tl_js_lower_auth = j.js_lower_auth;
	j.started_ms = context.tl_dispatch_ms;
	r := api_call(c, j.method, j.path, j.body, j.content_type, j.context_b64, extra, j.retries, j.retry_429, j.no_auth, j.no_super_props, j.referer);
	context.tl_js_lower_auth = false;
	if j.etag && r.status == 200 { { tag, ok := http.header_get(r.headers, "etag");
if ok { etag_put(c, url, tag); } } }
	if j.op == .Ack && r.ok {
		{ m := vmap(r.body);
		if !is_null(m) {
			tok := fstr(m, "token");
			locks.lock(*c.ack_mu);
			delete(c.ack_token, c.allocator);
			c.ack_token = ifx tok != "" then clone(tok, c.allocator) else "";
			locks.unlock(*c.ack_mu);
		} }
	}
	if j.op == .Experiments && r.ok {
		{ m := vmap(r.body);
		if !is_null(m) {
			inst := fstr(m, "installation");
			if inst != "" {
				locks.lock(*c.id.mu);
				if c.id.installation_id == "" { c.id.installation_id = clone(inst, c.allocator); }
				locks.unlock(*c.id.mu);
			}
		} }
	}
	if j.op == .Startup && r.ok && strings.has_prefix(j.path, "/quests/@me") { note_quest_applications(c, r.body); }
	if j.on_body != null && r.ok { j.on_body(c, r.body); }
	if j.on_done != null { j.on_done(c, j, r.status); }
	if j.on_response != null { j.on_response(c, j, r.status, r.body); }
	push_result(c, j, r);
}

// QuestsStore loads /quests/@me; the application of every quest is then
// hydrated with GET /applications/public?application_ids=..(one param per id,
// in quest order). Fired ≈435 ms after READY in the coldstart capture.
collect_app_ids :: (v: V, out: *[..]Snowflake) {
	// Only quests with a console task (PLAY_ON_XBOX / PLAY_ON_PLAYSTATION)
	// hydrate their application (console-linking UI); first-appearance order
	// (fixture cold_start: 15 of 29 quest applications).
	for q: flist(vmap(v), "quests") {
		cfg := fmap(vmap(q), "config");
		tasks := fmap(fmap(cfg, "task_config_v2"), "tasks");
		console := false;
		for p: tasks {
			k, _ := p.key.s, p.key.kind == .String;
			if k == "PLAY_ON_XBOX" || k == "PLAY_ON_PLAYSTATION" { console = true; }
		}
		if !console { continue; }
		id := fsnow(fmap(cfg, "application"), "id");
		if id == 0 { continue; }
		dup := false;
		for e: out.* { if e == id { dup = true; } }
		if !dup { append(out, id); }
	}
}

note_quest_applications :: (c: *Client, body: V) {
	ids := make_dynamic(Snowflake, 0, 0, temp);
	collect_app_ids(body, *ids);
	if len(ids) == 0 { return; }
	locks.lock(*c.job_mu);
	delete(c.quest_app_ids);
	c.quest_app_ids = make_slice(Snowflake, len(ids), c.allocator);
	copy(c.quest_app_ids, view(ids));
	ready := c.ready_ms;
	locks.unlock(*c.job_mu);
	if ready != 0 { schedule_applications_public(c, ready); }
}
#scope_export

schedule_applications_public :: (c: *Client, ready_ms: s64) {
	// Hydrated by the home (friends/quests) surface only.
	if client_route_kind(c.start_route_guild, c.start_route_channel) != .Home { return; }
	locks.lock(*c.job_mu);
	ids := c.quest_app_ids;
	c.quest_app_ids = zero(type_of(c.quest_app_ids));
	locks.unlock(*c.job_mu);
	if len(ids) == 0 { return; }
	defer delete(ids, c.allocator);
	q: Query;
	query_init(*q, "/applications/public");
	for id: ids { query_add_snow(*q, "application_ids", id); }
	j := job_new(.Api, .Startup);
	j.method = "GET";
	j.path = job_str(j, query_string(*q));
	j.not_before = max(ready_ms + 315, now_ms());
	job_submit(c, j);
}

// Thread-local fetch() time of the job a worker is running; the transport
// takes it as the request's start (once) for the recorder.
#add_context tl_dispatch_ms: float64;

// Thread-local: the running job's page code spelled the header "authorization"
// (read by the recorder's renderer view; the wire is lowercase either way).
#add_context tl_js_lower_auth: bool;
#scope_module

send_preflight :: (c: *Client, j: *Job) {
	pre := http.Request.{method = "OPTIONS", scheme = "https", authority = j.host, path = j.path, headers = preflight_headers(c.id.platform, "GET", "if-none-match", true)};
	presp, _ := transport_round_trip(*c.transport, j.host, pre);
	http.response_destroy(*presp);
}
#scope_export

// preflight_note: a request to url is scheduled; pending = its preflight is
// a separate, earlier job.
preflight_note :: (c: *Client, host: string, path: string, pending: bool) {
	if !pending { return; }
	url := strings.concatenate(string.["https://", host, path], temp);
	locks.lock(*c.preflight_mu);
	defer locks.unlock(*c.preflight_mu);
	if table_contains(*c.preflights, url) {
		table_set(*c.preflights, url, 1);
	} else {
		table_set(*c.preflights, clone(url, c.allocator), 1);
	}
}
#scope_module

preflight_finish :: (c: *Client, url: string) {
	locks.lock(*c.preflight_mu);
	if table_contains(*c.preflights, url) { table_set(*c.preflights, url, 2); }
	locks.cond_broadcast(*c.preflight_cond);
	locks.unlock(*c.preflight_mu);
}

// preflight_wait: true when an earlier job sent (or is sending) url's
// preflight; waits for it to finish (at most 10 s).
preflight_wait :: (c: *Client, url: string) -> bool {
	locks.lock(*c.preflight_mu);
	defer locks.unlock(*c.preflight_mu);
	ok, st := table_find(*c.preflights, url);
	if !ok { return false; }
	deadline := time.tick_now();
	while st == 1 && time.tick_since(deadline) < 10 * time.Second {
		locks.cond_wait_with_timeout(*c.preflight_cond, *c.preflight_mu, 250);
		_, st = table_find(*c.preflights, url);
	}
	// free the key the table owns (not url, the caller's)
	for v, k: c.preflights if k == url { table_remove(*c.preflights, url); free(k,, c.allocator); break; }
	return true;
}

// run_web: unauthenticated XHR (startup table entries for status/cdn/latency).
run_web :: (c: *Client, j: *Job) {
	now := now_ms();
	referer := j.referer;
	if referer == "" {
		referer = ifx j.site == .Same_Origin then client_route_referer(c) else #run join(API_ORIGIN, "/");
	}
	// XHR/fetch without credentials: cookies only go to the same origin.
	cookie := ifx j.no_cookies || j.site != .Same_Origin then "" else cookie_header(*c.jar, j.host, j.path, true, now);
	url := strings.concatenate(string.["https://", j.host, j.path], temp);
	js := j.js_headers;
	// Chrome's HTTP cache: fresh entries are served without a request; stale
	// ones are revalidated with the stored validators (appended after the
	// request's own headers). Not for cache:'no-cache' fetches (etag jobs).
	validators: []http.Header;
	centry, cbody, cached := cache_read(c, url);
	if cached && !j.etag {
		if centry.fresh_until > now {
			client_push_event(c, Event.{kind = .Rest, result = Rest_Result.{op = j.result.op, ok = true, status = 200, tag = j.result.tag}});
			return;
		}
		v := make_dynamic(http.Header, 0, 2, temp);
		if centry.etag != "" { append(*v, http.Header.{"if-none-match", centry.etag}); }
		if centry.last_modified != "" { append(*v, http.Header.{"if-modified-since", centry.last_modified}); }
		validators = view(v);
	}
	if j.etag {
		e := make_dynamic(http.Header, 0, 2, temp);
		append(*e, http.Header.{"cache-control", "max-age=0"});
		tag := etag_get(c, url);
		if tag != "" { append(*e, http.Header.{"if-none-match", tag}); }
		js = view(e);
		if j.preflight_if_etag && j.site != .Same_Origin {
			if j.preflight_only {
				if tag != "" { send_preflight(c, j); }
				preflight_finish(c, url);
				return;
			}
			if tag != "" && !preflight_wait(c, url) { send_preflight(c, j); }
		}
	}
	hin := Web_Headers_Input.{
		method = j.method,
		site = j.site,
		referer = referer,
		cookie = cookie,
		js_headers = js,
		cache_validator = validators
	};
	req := http.Request.{method = j.method, scheme = "https", authority = j.host, path = j.path, headers = web_headers(c.id.platform, hin), body = j.body};
	resp, err := transport_round_trip(*c.transport, j.host, req);
	if err == .None && !j.etag && j.method == "GET" {
		fresh, storable := freshness_ms(view(resp.headers), now_ms());
		if resp.status == 200 && storable {
			ce := Cache_Entry.{status = 200, fresh_until = fresh};
			ce.content_type, _ = http.header_get(view(resp.headers), "content-type");
			ce.etag, _ = http.header_get(view(resp.headers), "etag");
			ce.last_modified, _ = http.header_get(view(resp.headers), "last-modified");
			cache_write(c, url, ce, view(resp.body), true);
		} else if resp.status == 304 && cached {
			centry.fresh_until = fresh;
			cache_write(c, url, centry, .[], false);
		}
	}
	if j.etag && err == .None && resp.status == 200 { { tag, ok := http.header_get(view(resp.headers), "etag");
if ok { etag_put(c, url, tag); } } }
	if j.on_body != null && err == .None && resp.status == 200 {
		{ v, perr := etf.from_json(as_string(view(resp.body)),, temp);
		if perr == .None { j.on_body(c, v); } }
	}
	res := j.result;
	res.status = resp.status;
	res.ok = err == .None && resp.status >= 200 && resp.status < 400;
	http.response_destroy(*resp);
	client_push_event(c, Event.{kind = .Rest, result = res});
}

// ---- attachments ----
// Official flow (CloudUploader):
//   1. POST /channels/{id}/attachments {"files":[{filename,file_size,id,is_clip:false,original_content_type}]}
//   2. CORS preflight + PUT <upload_url> (application/octet-stream) to storage.googleapis.com
//   3. POST /channels/{id}/messages with attachments:[{id:"0",filename,uploaded_filename}]
run_upload :: (c: *Client, j: *Job) {
	cid := j.result.channel_id;
	alloc := job_alloc(j);
	// 1+2. upload URL, preflight + PUT per file (as each CloudUpload does)
	uploaded := make_dynamic([3]string, 0, len(j.files), alloc); // filename, upload_filename, mime
	for f0: j.files {
		f := f0;
		{ conv := webp_try_convert(atomic_load(*c.webp_variation), f.mime, f.data);
		if conv.converted { f.data = conv.data; } }
		name, ok, _, _ := upload_one(c, cid, f);
		if !ok {
			client_push_event(c, Event.{kind = .Rest, result = Rest_Result.{op = .Upload, channel_id = cid, nonce = j.result.nonce, ok = false}});
			return;
		}
		append(*uploaded, string.[f.filename, clone(name, alloc), f.mime]);
	}
	// 3. the message
	w: Json;
	json_init(*w);
	json_arr(*w);
	for u, i: uploaded {
		json_obj(*w);
		json_kstr(*w, "id", itoa(i));
		json_kstr(*w, "filename", u[0]);
		json_kstr(*w, "uploaded_filename", u[1]);
		if u[2] != "" { json_kstr(*w, "original_content_type", u[2]); }
		json_obj_end(*w);
	}
	json_arr_end(*w);
	body := j.message_json(j, json_string(*w));
	r := api_call(c, "POST", j.path, body, "application/json", j.context_b64, .[], 3, 1);
	j.result.op = .Send_Message;
	push_result(c, j, r);
}

split_url :: (url: string) -> string, string, bool {
	host: string;
	path: string;
	ok: bool;
	if !strings.has_prefix(url, "https://") { return "", "", false; }
	rest := sub_from(url, len("https://"));
	slash := strings.index_byte(rest, #char "/");
	if slash < 0 { return rest, "/", true; }
	return sub(rest, 0, slash), sub_from(rest, slash), true;
}

upload_put :: (c: *Client, url: string, data: []u8) -> bool {
	host, path, ok := split_url(url);
	if !ok { return false; }
	pre := http.Request.{method = "OPTIONS", scheme = "https", authority = host, path = path, headers = preflight_headers(c.id.platform, "PUT", "content-type", false)};
	presp, perr := transport_round_trip(*c.transport, host, pre);
	pstatus := presp.status;
	http.response_destroy(*presp);
	if perr != .None || pstatus >= 300 { return false; }
	put := http.Request.{method = "PUT", scheme = "https", authority = host, path = path, headers = upload_put_headers(c.id.platform, len(data)), body = data};
	backoff := backoff_make(500, 5000);
	for attempt: 0..2 {
		resp, err := transport_round_trip(*c.transport, host, put);
		status := resp.status;
		http.response_destroy(*resp);
		if err == .None && status >= 200 && status < 300 { return true; }
		if attempt < 2 { time.sleep(cast(time.Duration)(backoff_fail(*backoff)) * time.Millisecond); }
	}
	return false;
}
#scope_export

// ---- applying results on the UI thread ----

client_apply_rest :: (c: *Client, e: *Event) {
	s := *c.store;
	r := *e.result;
	push_allocator(s.allocator);
	if r.op == {
	case .Auth;
		auth_apply(c, e);
	case .Fetch_Messages;
		l := message_list(s, r.channel_id);
		l.loading = false;
		if r.ok {
			items := vlist(e.data);
			for mv: items { upsert_message(s, vmap(mv)); }
			first := !l.loaded;
			l.loaded = true;
			if r.before != 0 || len(items) > 0 { l.has_more_before = len(items) >= r.limit; }
			if len(items) < r.limit { l.has_more_before = false; }
			if first && r.before == 0 { on_channel_page(c, r.channel_id, len(items), len(items) >= r.limit); }
			request_page_members(c, r.channel_id, items);
		}
	case .Send_Message; #through; case .Upload;
		{ rt := table_find_pointer(*c.analytics.roundtrips, r.nonce); ok := rt != null;
		if ok && rt.api == 0 { rt.api = now_ms(); } }
		if r.ok {
			upsert_message(s, vmap(e.data));
		} else { l := table_find_pointer(*s.messages, r.channel_id); ok := l != null;
if ok {
			nonce := snowflake_string(r.nonce);
			for * m: l.messages {
				if m.pending && m.nonce == nonce {
					m.failed = true;
					m.pending = false;
				}
			}
		} }
	case .Edit_Message;
		if r.ok { upsert_message(s, vmap(e.data)); }
	case .Delete_Message;
		if r.ok {
			{ l := table_find_pointer(*s.messages, r.channel_id); ok := l != null;
			if ok {
				{ i := message_index(l, r.message_id);
				if i >= 0 {
					free_message(s, at(*l.messages, i));
					ordered_remove(*l.messages, i);
				} }
			} }
		}
	case .Open_Dm;
		if r.ok {
			cid := parse_channel_into(s, vmap(e.data));
			r.id = cid;
			if cid != 0 {
				found := false;
				for pc: s.private_channels { if pc == cid { found = true; } }
				if !found { append(*s.private_channels, cid); }
				analytics_group_dm_created(c, cid);
			}
		}
	case .Fetch_Profile;
		defer if r.ok { analytics_on_profile(c, r.user_id); }
		if r.ok {
			m := vmap(e.data);
			uid := parse_user_into(s, fmap(m, "user"));
			{ prof := fmap(m, "user_profile");
			if !is_null(prof) && uid != 0 {
				u := find_or_add(*s.users, uid);
				if vhas(prof, "bio") {free_str(u.bio, s.allocator); u.bio = clone_str(fstr(prof, "bio"), s.allocator);}
				if vhas(prof, "pronouns") {free_str(u.pronouns, s.allocator); u.pronouns = clone_str(fstr(prof, "pronouns"), s.allocator);}
				if vhas(m, "mutual_guilds") { u.mutual_guilds = len(flist(m, "mutual_guilds")); }
				if vhas(m, "mutual_friends") { u.mutual_friends = len(flist(m, "mutual_friends")); } else if vhas(m, "mutual_friends_count") { u.mutual_friends = cast(int)(fint(m, "mutual_friends_count")); }
			} }
		}
	case .Settings;
		if r.ok { { sp := fstr(vmap(e.data), "settings");
if sp != "" { apply_settings_proto(s, sp); } } }
	case .None; #through; case .Media; #through; case .Add_Reaction; #through; case .Remove_Reaction; #through; case .Typing; #through; case .Ack; #through; case .Relationship; #through; case .Experiments; #through; case .Startup; #through; case .Guild_Open; #through; case .Invite;
	}
}


