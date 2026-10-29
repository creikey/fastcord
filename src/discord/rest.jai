// REST execution. Jobs are built on the UI thread (actions.jai) or by the
// startup scheduler, and run on worker threads. Each job owns a pool with
// all its strings; results come back to the UI thread as Rest events.
// A worker resets its temporary storage after every job: nothing a job puts
// in temp may outlive run_job.

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
	arena: Flat_Pool;
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
	draft: u64; // upload of one staged draft (uploads.jai)
	drafts: []Draft_Attachment; // message send waiting on these drafts
	requeue: bool; // run again at not_before instead of being freed
	no_auth: bool; // logged-out request (no authorization header)
	no_super_props: bool;
	etag: bool; // fetch(cache:'no-cache') + remembered If-None-Match
	preflight_if_etag: bool;
	no_cookies: bool; // cross-origin: If-None-Match makes it a preflighted request
	preflight_only: bool; // send only the CORS preflight (the request is a later job)
	document: bool; // the window's navigation to /app (startup.jai schedule_app_load)
	host_manifest: bool; // the native updater's checks, hourly (updater.jai)
	hosts_table: bool; // the hosts table: each host version's Electron and Chrome (schedule_app_load)
	on_body: (c: *Client, body: V); // worker-side follow-up on a 2xx JSON body (body in temp)
	on_done: (c: *Client, j: *Job, status: int); // worker-side, after any response (status 0: network failure)
	track_props: string; // on_done's event properties, built on the UI thread (job pool)
	on_response: (c: *Client, j: *Job, status: int, body: V); // worker-side, after any response, with the body
	started_ms: float64; // when the request was dispatched (on_done timings)
	on_start: (c: *Client, j: *Job); // worker-side, as an Api request is dispatched (science tracked at fetch start)
	skip_if: (c: *Client) -> bool; // worker-side, when due: true drops the job unsent (a store's shouldFetch)
	js_lower_auth: bool; // page code set "authorization" (lowercase): only DevTools' view differs
	media: Media_Request;
}

// Jobs, their pools and the result pools are on the heap whatever context.allocator a caller
// pushed: they move between threads and outlive every temporary storage reset.
job_new :: (kind: Job_Kind, op: Rest_Op) -> *Job {
	j := New(Job,, context.default_allocator);
	j.kind = kind;
	j.op = op;
	j.result.op = op;
	return j;
}

job_alloc :: (j: *Job) -> Allocator { return pool_allocator(*j.arena); }

job_str :: (j: *Job, s: string) -> string { return copy_string(s,, job_alloc(j)); }

job_free :: (j: *Job) {
	fini(*j.arena);
	free(j,, context.default_allocator);
}

job_submit :: (c: *Client, j: *Job) {
	if context.req_tag && j.result.tag == 0 {
		j.result.tag = context.req_tag;
		context.req_jobs += 1;
	}
	locks.lock(*c.job_mu);
	array_add(*c.jobs, j);
	locks.cond_broadcast(*c.job_cond);
	locks.unlock(*c.job_mu);
}

worker_proc :: (c: *Client) {
	locks.lock(*c.job_mu);
	while !c.quit {
		now := now_ms();
		pick := -1;
		next_due := S64_MAX;
		for c.jobs {
			if it.not_before <= now {
				pick = it_index;
				break;
			}
			next_due = min(next_due, it.not_before);
		}
		if pick < 0 {
			locks.cond_wait_with_timeout(*c.job_cond, *c.job_mu, ifx next_due == S64_MAX then 1000 else max(next_due - now, 1));
			continue;
		}
		j := c.jobs[pick];
		array_ordered_remove_by_index(*c.jobs, pick);
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
			array_add(*c.jobs, j);
		} else {
			job_free(j);
		}
	}
	locks.unlock(*c.job_mu);
}

run_job :: (c: *Client, j: *Job) {
	if j.skip_if && j.skip_if(c) return;
	if j.kind == {
		case .Api;
			run_api(c, j);
		case .Web;
			if j.op == .Media run_media(c, j); else run_web(c, j);
		case .Upload;
			if j.draft {
				run_draft_upload(c, j);
			} else if j.drafts {
				if run_draft_send(c, j) {
					j.requeue = true;
					j.not_before = now_ms() + 50;
				}
			} else {
				run_upload(c, j);
			}
	}
}

API_PREFIX :: "/api/v9";

// Result of one API call, body parsed into its own pool.
Api_Response :: struct {
	status: int;
	ok: bool;
	body: V;
	arena: *Flat_Pool; // owns body and headers (null on a network failure)
	headers: []http.Header;
}

// api_call performs one authenticated request with the HTTP util's retry and
// rate-limit semantics. The returned arena (if any) owns body.
api_call :: (c: *Client, method: string, path: string, body: []u8, content_type: string, context_b64: string, extra: []http.Header, retries: int, retry_429: int, no_auth := false, no_super_props := false, referer := "") -> Api_Response {
	full_path := join(API_PREFIX, path,, temp);
	url_key := join(API_ORIGIN, full_path,, temp);
	retries_left := retries;
	retry_429_left := retry_429;
	failed := 0;
	backoff := backoff_make(500);
	queued := true; // a retry after a network error or 5xx skips the queue (HTTPUtils calls I, not g)
	while true {
		if queued rate_acquire(*c.limiter, url_key);
		queued = false;
		now := now_ms();
		ex := extra;
		if failed > 0 {
			// X-Failed-Requests on retried requests.
			e2: [..]http.Header;
			e2.allocator = temp;
			array_add(*e2, ..extra);
			array_add(*e2, .{"x-failed-requests", itoa(failed)});
			ex = e2;
		}
		hin := Api_Headers_Input.{
			method = method,
			has_body = body.count > 0,
			body_len = body.count,
			content_type = content_type,
			token = ifx no_auth then "" else client_token(c),
			fingerprint = auth_fingerprint(c),
			installation_id = c.id.installation_id,
			super_props_b64 = ifx no_super_props then "" else super_properties_b64(*c.id, now),
			context_b64 = context_b64,
			referer = ifx referer then referer else client_route_referer(c),
			cookie = cookie_header(*c.jar, API_HOST, full_path, true, now),
			extra = ex
		};
		req := http.Request.{method = method, scheme = "https", authority = API_HOST, path = full_path, headers = api_headers(identity_platform(*c.id), hin), body = body};
		resp, err := transport_round_trip(*c.transport, API_HOST, req);
		if err != .None || (retries_left > 0 && is_retryable_status(resp.status)) {
			http.response_destroy(*resp);
			if retries_left <= 0 {
				rate_note_response(*c.limiter, url_key, 0, .[], .{}, now_ms());
				return .{status = 0};
			}
			retries_left -= 1;
			failed += 1;
			sleep_milliseconds(xx backoff_fail(*backoff));
			continue;
		}
		pool := New(Flat_Pool,, context.default_allocator);
		alloc := pool_allocator(pool);
		bv := parse_json(resp.body,, alloc);
		hold := rate_note_response(*c.limiter, url_key, resp.status, resp.headers, bv, now_ms());
		if resp.status == 429 && retry_429_left > 0 {
			retry_429_left -= 1;
			ra, has := retry_after_seconds(resp.headers, bv);
			wait := ifx has then cast(s64) (ra * 1000) else hold;
			http.response_destroy(*resp);
			fini(pool);
			free(pool,, context.default_allocator);
			if wait > 0 sleep_milliseconds(xx wait);
			queued = true;
			continue;
		}
		hdrs := NewArray(resp.headers.count, http.Header,, alloc);
		for resp.headers hdrs[it_index] = .{copy_string(it.name,, alloc), copy_string(it.value,, alloc)};
		r := Api_Response.{status = resp.status, ok = resp.status >= 200 && resp.status < 300, body = bv, arena = pool, headers = hdrs};
		http.response_destroy(*resp);
		return r;
	}
}

push_result :: (c: *Client, j: *Job, r: Api_Response) {
	res := j.result;
	res.ok = r.ok;
	res.status = r.status;
	if r.body.kind == .Map && res.id == 0 res.id = fsnow(r.body.map, "id");
	client_push_event(c, .{kind = .Rest, data = r.body, arena = r.arena, result = res});
}

// cache_control_headers: fetch(cache:'no-cache') with the remembered If-None-Match (temp).
cache_control_headers :: (c: *Client, url: string) -> []http.Header {
	e: [..]http.Header;
	e.allocator = temp;
	array_add(*e, .{"cache-control", "max-age=0"});
	tag := etag_get(c, url);
	if tag array_add(*e, .{"if-none-match", tag});
	return e;
}

run_api :: (c: *Client, j: *Job) {
	extra := j.extra;
	url := join(API_ORIGIN, API_PREFIX, j.path,, temp);
	if j.etag extra = cache_control_headers(c, url);
	context.tl_js_lower_auth = j.js_lower_auth;
	j.started_ms = context.tl_dispatch_ms;
	if j.on_start j.on_start(c, j);
	r := api_call(c, j.method, j.path, j.body, j.content_type, j.context_b64, extra, j.retries, j.retry_429, j.no_auth, j.no_super_props, j.referer);
	context.tl_js_lower_auth = false;
	if j.etag && r.status == 200 {
		tag, ok := http.header_get(r.headers, "etag");
		if ok etag_put(c, url, tag);
	}
	if j.op == .Ack && r.ok && vmap(r.body) {
		tok := fstr(r.body.map, "token");
		locks.lock(*c.ack_mu);
		if c.ack_token free(c.ack_token,, c.allocator);
		c.ack_token = ifx tok then copy_string(tok,, c.allocator) else "";
		locks.unlock(*c.ack_mu);
	}
	if j.op == .Experiments && r.ok && r.body.kind == .Map {
		inst := fstr(r.body.map, "installation");
		if inst {
			locks.lock(*c.id.mu);
			if !c.id.installation_id c.id.installation_id = copy_string(inst,, c.allocator);
			locks.unlock(*c.id.mu);
		}
	}
	if j.op == .Startup && r.ok && begins_with(j.path, "/quests/@me") note_quest_applications(c, r.body);
	if j.op == .Startup && r.ok && begins_with(j.path, "/users/@me/collectibles-marketing") promo_shop_marketing(c, r.body);
	if j.op == .Startup && begins_with(j.path, "/quests/decision?placement=1&") promo_quest_decision(c, j, r);
	if j.on_body && r.ok j.on_body(c, r.body);
	if j.on_done j.on_done(c, j, r.status);
	if j.on_response j.on_response(c, j, r.status, r.body);
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
		console := false;
		for fmap(fmap(cfg, "task_config_v2"), "tasks") {
			k := vstr(it.key);
			if k == "PLAY_ON_XBOX" || k == "PLAY_ON_PLAYSTATION" console = true;
		}
		id := fsnow(fmap(cfg, "application"), "id");
		if console && id array_add_if_unique(out, id);
	}
}

note_quest_applications :: (c: *Client, body: V) {
	ids: [..]Snowflake;
	ids.allocator = temp;
	collect_app_ids(body, *ids);
	if !ids return;
	locks.lock(*c.job_mu);
	array_free(c.quest_app_ids,, c.allocator);
	c.quest_app_ids = array_copy(ids,, c.allocator);
	ready := c.ready_ms;
	locks.unlock(*c.job_mu);
	if ready schedule_applications_public(c, ready);
}

schedule_applications_public :: (c: *Client, ready_ms: s64) {
	// Hydrated by the home (friends/quests) surface only.
	if client_route_kind(c.start_route_guild, c.start_route_channel) != .Home return;
	locks.lock(*c.job_mu);
	ids := c.quest_app_ids;
	c.quest_app_ids = .[];
	locks.unlock(*c.job_mu);
	if !ids return;
	defer array_free(ids,, c.allocator);
	q: Query;
	query_init(*q, "/applications/public");
	for ids query_add_snow(*q, "application_ids", it);
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

// Set by the app around a user action: the jobs it submits carry this result tag
// (when they have none) and are counted, so a button can wait for its request.
#add_context req_tag: u64;
#add_context req_jobs: int;

send_preflight :: (c: *Client, j: *Job) {
	pre := http.Request.{method = "OPTIONS", scheme = "https", authority = j.host, path = j.path, headers = preflight_headers(c.id.platform, "GET", "if-none-match", true)};
	presp := transport_round_trip(*c.transport, j.host, pre);
	http.response_destroy(*presp);
}

// preflight_note: a request to url is scheduled; pending = its preflight is
// a separate, earlier job.
preflight_note :: (c: *Client, host: string, path: string, pending: bool) {
	if !pending return;
	url := join("https://", host, path,, temp);
	locks.lock(*c.preflight_mu);
	defer locks.unlock(*c.preflight_mu);
	p := table_find_pointer(*c.preflights, url);
	if p p.* = 1;
	else table_add(*c.preflights, copy_string(url,, c.allocator), 1);
}

preflight_finish :: (c: *Client, url: string) {
	locks.lock(*c.preflight_mu);
	p := table_find_pointer(*c.preflights, url);
	if p p.* = 2;
	locks.cond_broadcast(*c.preflight_cond);
	locks.unlock(*c.preflight_mu);
}

// preflight_wait: true when an earlier job sent (or is sending) url's
// preflight; waits for it to finish (at most 10 s).
preflight_wait :: (c: *Client, url: string) -> bool {
	locks.lock(*c.preflight_mu);
	defer locks.unlock(*c.preflight_mu);
	ok, st := table_find(*c.preflights, url);
	if !ok return false;
	start := mono_ms();
	while st == 1 && mono_ms() - start < 10_000 {
		locks.cond_wait_with_timeout(*c.preflight_cond, *c.preflight_mu, 250);
		_, st = table_find(*c.preflights, url);
	}
	// free the key the table owns (not url, the caller's)
	for c.preflights if it_index == url {
		key := it_index;
		table_remove(*c.preflights, url);
		free(key,, c.allocator);
		break;
	}
	return true;
}

// run_web: unauthenticated XHR (startup table entries for status/cdn/latency).
run_web :: (c: *Client, j: *Job) {
	now := now_ms();
	if j.document {
		req := http.Request.{method = "GET", scheme = "https", authority = j.host, path = j.path, headers = document_headers(c.id.platform, cookie_header(*c.jar, j.host, j.path, true, now))};
		resp, err := transport_round_trip(*c.transport, j.host, req);
		if err == .None && resp.status == 200 app_document_loaded(c, cast(string) resp.body);
		http.response_destroy(*resp);
		return;
	}
	if j.host_manifest {
		updater_run(c, j);
		return;
	}
	if j.hosts_table {
		req := http.Request.{method = "GET", scheme = "https", authority = j.host, path = j.path};
		resp, err := transport_round_trip(*c.transport, j.host, req);
		if err == .None && resp.status == 200 hosts_table_loaded(c, resp.body);
		http.response_destroy(*resp);
		return;
	}
	referer := j.referer;
	if !referer referer = ifx j.site == .Same_Origin then client_route_referer(c) else #run join(API_ORIGIN, "/");
	// XHR/fetch without credentials: cookies only go to the same origin.
	cookie := ifx j.no_cookies || j.site != .Same_Origin then "" else cookie_header(*c.jar, j.host, j.path, true, now);
	url := join("https://", j.host, j.path,, temp);
	js := j.js_headers;
	// Chrome's HTTP cache: fresh entries are served without a request; stale
	// ones are revalidated with the stored validators (appended after the
	// request's own headers). Not for cache:'no-cache' fetches (etag jobs).
	validators: [..]http.Header;
	validators.allocator = temp;
	centry, _, cached := cache_read(c, url);
	if cached && !j.etag {
		if centry.fresh_until > now {
			client_push_event(c, .{kind = .Rest, result = .{op = j.result.op, ok = true, status = 200, tag = j.result.tag}});
			return;
		}
		if centry.etag array_add(*validators, .{"if-none-match", centry.etag});
		if centry.last_modified array_add(*validators, .{"if-modified-since", centry.last_modified});
	}
	if j.etag {
		js = cache_control_headers(c, url);
		has_tag := js.count > 1;
		if j.preflight_if_etag && j.site != .Same_Origin {
			if j.preflight_only {
				if has_tag send_preflight(c, j);
				preflight_finish(c, url);
				return;
			}
			if has_tag && !preflight_wait(c, url) send_preflight(c, j);
		}
	}
	hin := Web_Headers_Input.{method = j.method, site = j.site, referer = referer, cookie = cookie, js_headers = js, cache_validator = validators};
	req := http.Request.{method = j.method, scheme = "https", authority = j.host, path = j.path, headers = web_headers(c.id.platform, hin), body = j.body};
	resp, err := transport_round_trip(*c.transport, j.host, req);
	if err == .None && !j.etag && j.method == "GET" {
		fresh, storable := freshness_ms(resp.headers, now_ms());
		if resp.status == 200 && storable {
			ce := Cache_Entry.{status = 200, fresh_until = fresh};
			ce.content_type = http.header_get(resp.headers, "content-type");
			ce.etag = http.header_get(resp.headers, "etag");
			ce.last_modified = http.header_get(resp.headers, "last-modified");
			cache_write(c, url, ce, resp.body, true);
		} else if resp.status == 304 && cached {
			centry.fresh_until = fresh;
			cache_write(c, url, centry, .[], false);
		}
	}
	if err == .None && resp.status == 200 {
		if j.etag {
			tag, ok := http.header_get(resp.headers, "etag");
			if ok etag_put(c, url, tag);
		}
		if j.on_body {
			v, perr := etf.from_json(cast(string) resp.body,, temp);
			if perr == .None j.on_body(c, v);
		}
	}
	res := j.result;
	res.status = resp.status;
	res.ok = err == .None && resp.status >= 200 && resp.status < 400;
	http.response_destroy(*resp);
	client_push_event(c, .{kind = .Rest, result = res});
}

// ---- attachments ----
// Official flow (CloudUploader):
//   1. POST /channels/{id}/attachments {"files":[{filename,file_size,id,is_clip:false,original_content_type}]}
//   2. CORS preflight + PUT <upload_url> (application/octet-stream) to storage.googleapis.com
//   3. POST /channels/{id}/messages with attachments:[{id:"0",filename,uploaded_filename}]
run_upload :: (c: *Client, j: *Job) {
	cid := j.result.channel_id;
	// 1+2. upload URL, preflight + PUT per file (as each CloudUpload does)
	w: Json;
	json_init(*w);
	json_arr(*w);
	for f0: j.files {
		f := f0;
		conv := webp_try_convert(atomic_load(*c.webp_variation), f.mime, f.data);
		if conv.converted f.data = conv.data;
		name, ok := upload_one(c, cid, f);
		if !ok {
			client_push_event(c, .{kind = .Rest, result = .{op = .Upload, channel_id = cid, nonce = j.result.nonce, ok = false}});
			return;
		}
		// 3. the message's attachment entry
		json_obj(*w);
		json_kstr(*w, "id", itoa(it_index));
		json_kstr(*w, "filename", f.filename);
		json_kstr(*w, "uploaded_filename", name);
		if f.mime json_kstr(*w, "original_content_type", f.mime);
		json_obj_end(*w);
	}
	json_arr_end(*w);
	body := j.message_json(j, json_string(*w));
	r := api_call(c, "POST", j.path, body, "application/json", j.context_b64, .[], 3, 1);
	j.result.op = .Send_Message;
	push_result(c, j, r);
}

// split_url: "https://host/path" -> host, path. The host must be a bare name, so a URL from a server can't
// slip in userinfo, a port or a query (`https://cdn.discordapp.com@other.example/`).
split_url :: (url: string) -> string, string, bool {
	if !begins_with(url, "https://") return "", "", false;
	rest := advance(url, "https://".count);
	found, host := split_from_left(rest, #char "/");
	if !host return "", "", false;
	for host if !is_alnum(it) && it != #char "." && it != #char "-" return "", "", false;
	return host, ifx found then advance(rest, host.count) else "/", true;
}

upload_put :: (c: *Client, url: string, data: []u8) -> bool {
	host, path, ok := split_url(url);
	if !ok return false;
	pre := http.Request.{method = "OPTIONS", scheme = "https", authority = host, path = path, headers = preflight_headers(c.id.platform, "PUT", "content-type", false)};
	presp, perr := transport_round_trip(*c.transport, host, pre);
	pstatus := presp.status;
	http.response_destroy(*presp);
	if perr != .None || pstatus >= 300 return false;
	put := http.Request.{method = "PUT", scheme = "https", authority = host, path = path, headers = upload_put_headers(c.id.platform, data.count), body = data};
	backoff := backoff_make(500, 5000);
	for attempt: 0..2 {
		resp, err := transport_round_trip(*c.transport, host, put);
		status := resp.status;
		http.response_destroy(*resp);
		if err == .None && status >= 200 && status < 300 return true;
		if attempt < 2 sleep_milliseconds(xx backoff_fail(*backoff));
	}
	return false;
}

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
			l.failed = !r.ok;
			if r.ok {
				items := vlist(e.data);
				// a refetch after a fresh READY: the page is the channel's present, so messages deleted
				// meanwhile and the gap before it go (our unsent messages stay)
				refetch := l.stale && r.before == 0;
				if refetch {
					l.stale = false;
					n := 0;
					for * l.messages {
						if it.pending || it.failed l.messages[n] = it.*;
						else free_message(s, it);
						if it.pending || it.failed n += 1;
					}
					l.messages.count = n;
				}
				for items upsert_message(s, vmap(it));
				locks.lock(*c.route_mu);
				on_route := c.route_channel == r.channel_id;
				locks.unlock(*c.route_mu);
				if on_route analytics_redactable_page(c, r.channel_id, items);
				first := !l.loaded && !refetch;
				l.loaded = true;
				if r.before != 0 || items.count > 0 l.has_more_before = items.count >= r.limit;
				if items.count < r.limit l.has_more_before = false;
				if first && r.before == 0 on_channel_page(c, r.channel_id, items.count, items.count >= r.limit);
				request_page_members(c, r.channel_id, items);
			}
		case .Send_Message; #through;
		case .Upload;
			rt := table_find_pointer(*c.analytics.roundtrips, r.nonce);
			if rt && rt.api == 0 rt.api = now_ms();
			if r.ok {
				upsert_message(s, vmap(e.data));
			} else {
				l := table_find_pointer(*s.messages, r.channel_id);
				if l {
					nonce := snowflake_string(r.nonce);
					for * l.messages {
						if it.pending && it.nonce == nonce {
							it.failed = true;
							it.pending = false;
						}
					}
				}
			}
		case .Add_Reaction; #through;
		case .Remove_Reaction;
			reaction_result(c, r.*);
		case .Edit_Message;
			if r.ok upsert_message(s, vmap(e.data));
		case .Delete_Message;
			l := table_find_pointer(*s.messages, r.channel_id);
			if r.ok && l {
				i := message_index(l, r.message_id);
				if i >= 0 {
					free_message(s, *l.messages[i]);
					array_ordered_remove_by_index(*l.messages, i);
				}
			}
		case .Open_Dm;
			if r.ok {
				cid := parse_channel_into(s, vmap(e.data));
				r.id = cid;
				if cid {
					array_add_if_unique(*s.private_channels, cid);
					analytics_group_dm_created(c, cid);
				}
			}
		case .Fetch_Profile;
			if r.ok {
				m := vmap(e.data);
				uid := parse_user_into(s, fmap(m, "user"));
				prof := fmap(m, "user_profile");
				if prof.count && uid {
					u := find_or_add(*s.users, uid);
					if vhas(prof, "bio") { free_str(u.bio, s.allocator); u.bio = clone_str(fstr(prof, "bio"), s.allocator); }
					if vhas(prof, "pronouns") { free_str(u.pronouns, s.allocator); u.pronouns = clone_str(fstr(prof, "pronouns"), s.allocator); }
					profile_props_apply(s, u, m);
					if vhas(m, "mutual_guilds") u.mutual_guilds = flist(m, "mutual_guilds").count;
					if vhas(m, "mutual_friends") u.mutual_friends = flist(m, "mutual_friends").count;
					else if vhas(m, "mutual_friends_count") u.mutual_friends = fint(m, "mutual_friends_count");
				}
				analytics_on_profile(c, r.user_id);
			}
		case .Settings;
			sp := ifx r.ok then fstr(vmap(e.data), "settings") else "";
			if r.tag == FRECENCY_SETTINGS_TYPE frecency_apply(c, r.ok, sp);
			else if sp apply_settings_proto(s, sp);
	}
}
