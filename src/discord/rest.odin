package discord

import "core:mem/virtual"
import "core:strings"
import "core:sync"
import "core:time"
import "fc:http"

// REST execution. Jobs are built on the UI thread (actions.odin) or by the
// startup scheduler, and run on worker threads. Each job owns an arena with
// all its strings; results come back to the UI thread as Rest events.

Job_Kind :: enum u8 {
	Api, // https://discord.com/api/v9 + path, authenticated
	Web, // unauthenticated XHR to any https origin
	Upload, // attachments: POST /attachments, preflight + PUT, then send
}

Upload_File :: struct {
	filename: string,
	mime:     string,
	data:     []byte,
}

Job :: struct {
	arena:        virtual.Arena,
	kind:         Job_Kind,
	op:           Rest_Op,
	method:       string,
	host:         string, // Web jobs
	path:         string, // Api: below /api/v9 (with query). Web: full path.
	body:         []byte,
	content_type: string,
	context_b64:  string,
	extra:        []http.Header,
	retries:      int,
	not_before:   i64,
	result:       Rest_Result,
	// Web
	site:         Fetch_Site,
	referer:      string, // "" -> current route (Api) / https://discord.com/ (Web cross-origin)
	js_headers:   []http.Header,
	// 429 handling: Send_Message requeues after Retry-After (MessageQueue), reactions retry once.
	retry_429:    int,
	// Upload
	files:        []Upload_File,
	message_json: proc(j: ^Job, attachments_json: string) -> []byte, // builds the final send body
	upload_ctx:   rawptr,
	no_auth:      bool, // logged-out request (no authorization header)
	no_super_props: bool,
	etag:         bool, // fetch(cache:'no-cache') + remembered If-None-Match
	preflight_if_etag: bool,
	no_cookies:   bool, // cross-origin: If-None-Match makes it a preflighted request
	preflight_only: bool, // send only the CORS preflight (the request is a later job)
	on_body:      proc(c: ^Client, body: V), // worker-side follow-up on a 2xx JSON body
	js_lower_auth: bool, // page code set "authorization" (lowercase): only DevTools' view differs
	media:        Media_Request,
}

job_new :: proc(kind: Job_Kind, op: Rest_Op) -> ^Job {
	j := new(Job)
	_ = virtual.arena_init_growing(&j.arena)
	j.kind = kind
	j.op = op
	j.result.op = op
	return j
}

job_alloc :: proc(j: ^Job) -> Allocator {return virtual.arena_allocator(&j.arena)}

job_str :: proc(j: ^Job, s: string) -> string {return strings.clone(s, job_alloc(j))}

job_free :: proc(j: ^Job) {
	virtual.arena_destroy(&j.arena)
	free(j)
}

job_submit :: proc(c: ^Client, j: ^Job) {
	sync.mutex_lock(&c.job_mu)
	append(&c.jobs, j)
	sync.cond_broadcast(&c.job_cond)
	sync.mutex_unlock(&c.job_mu)
}

@(private)
worker_proc :: proc(c: ^Client) {
	sync.mutex_lock(&c.job_mu)
	for !c.quit {
		now := now_ms()
		pick := -1
		next_due: i64 = max(i64)
		for j, i in c.jobs {
			if j.not_before <= now {
				pick = i
				break
			}
			next_due = min(next_due, j.not_before)
		}
		if pick < 0 {
			wait := time.Duration(1000) * time.Millisecond
			if next_due != max(i64) do wait = time.Duration(max(next_due - now, 1)) * time.Millisecond
			sync.cond_wait_with_timeout(&c.job_cond, &c.job_mu, wait)
			continue
		}
		j := c.jobs[pick]
		ordered_remove(&c.jobs, pick)
		// the moment the page would call fetch(): picks are serialized here, so
		// requests due together keep their queue order (traffic recording)
		tl_dispatch_ms = now_ms_f()
		sync.mutex_unlock(&c.job_mu)
		run_job(c, j)
		job_free(j)
		free_all(context.temp_allocator)
		sync.mutex_lock(&c.job_mu)
	}
	sync.mutex_unlock(&c.job_mu)
}

@(private)
run_job :: proc(c: ^Client, j: ^Job) {
	switch j.kind {
	case .Api:
		run_api(c, j)
	case .Web:
		if j.op == .Media do run_media(c, j)
		else do run_web(c, j)
	case .Upload:
		run_upload(c, j)
	}
}

API_PREFIX :: "/api/v9"


// Result of one API call, body parsed into the event arena.
Api_Response :: struct {
	status: int,
	ok:     bool,
	body:   V,
	arena:  ^virtual.Arena,
	headers: []http.Header,
}

// api_call performs one authenticated request with the HTTP util's retry and
// rate-limit semantics. The returned arena (if any) owns body.
api_call :: proc(c: ^Client, method, path: string, body: []byte, content_type, context_b64: string, extra: []http.Header, retries: int, retry_429: int, no_auth := false, no_super_props := false, referer := "") -> (r: Api_Response) {
	full_path := strings.concatenate({API_PREFIX, path}, context.temp_allocator)
	url_key := strings.concatenate({API_ORIGIN, full_path}, context.temp_allocator)
	retries_left := retries
	retry_429_left := retry_429
	failed := 0
	backoff := backoff_make(500)
	for {
		if w := rate_wait_ms(&c.limiter, method, url_key, now_ms()); w > 0 {
			time.sleep(time.Duration(w) * time.Millisecond)
		}
		now := now_ms()
		ex := extra
		if failed > 0 {
			// X-Failed-Requests on retried requests.
			e2 := make([dynamic]http.Header, 0, len(extra) + 1, context.temp_allocator)
			for e in extra do append(&e2, e)
			append(&e2, http.Header{"x-failed-requests", itoa(failed)})
			ex = e2[:]
		}
		hin := Api_Headers_Input{
			method          = method,
			has_body        = len(body) > 0,
			body_len        = len(body),
			content_type    = content_type,
			token           = "" if no_auth else c.token,
			installation_id = c.id.installation_id,
			super_props_b64 = "" if no_super_props else super_properties_b64(&c.id, now),
			context_b64     = context_b64,
			referer         = referer if referer != "" else client_route_referer(c),
			cookie          = cookie_header(&c.jar, API_HOST, full_path, true, now),
			extra           = ex,
		}
		req := http.Request{
			method    = method,
			scheme    = "https",
			authority = API_HOST,
			path      = full_path,
			headers   = api_headers(c.id.platform, hin),
			body      = body,
		}
		resp, err := transport_round_trip(&c.transport, API_HOST, req)
		if err != .None {
			http.response_destroy(&resp)
			if retries_left > 0 {
				retries_left -= 1
				failed += 1
				time.sleep(time.Duration(backoff_fail(&backoff)) * time.Millisecond)
				continue
			}
			return {status = 0}
		}
		if retries_left > 0 && is_retryable_status(resp.status) {
			http.response_destroy(&resp)
			retries_left -= 1
			failed += 1
			time.sleep(time.Duration(backoff_fail(&backoff)) * time.Millisecond)
			continue
		}
		arena := new(virtual.Arena)
		_ = virtual.arena_init_growing(arena)
		alloc := virtual.arena_allocator(arena)
		bv, _ := parse_json(resp.body[:], alloc)
		hold := rate_note_response(&c.limiter, method, url_key, resp.status, resp.headers[:], bv, now_ms())
		if resp.status == 429 && retry_429_left > 0 {
			retry_429_left -= 1
			ra, has := retry_after_seconds(resp.headers[:], bv)
			wait := i64(ra * 1000) if has else hold
			http.response_destroy(&resp)
			virtual.arena_destroy(arena)
			free(arena)
			time.sleep(time.Duration(max(wait, 0)) * time.Millisecond)
			continue
		}
		hdrs := make([]http.Header, len(resp.headers), alloc)
		for h, i in resp.headers do hdrs[i] = {strings.clone(h.name, alloc), strings.clone(h.value, alloc)}
		r = Api_Response{status = resp.status, ok = resp.status >= 200 && resp.status < 300, body = bv, arena = arena, headers = hdrs}
		http.response_destroy(&resp)
		return r
	}
}

@(private)
push_result :: proc(c: ^Client, j: ^Job, r: Api_Response) {
	res := j.result
	res.ok = r.ok
	res.status = r.status
	if m := vmap(r.body); m != nil && res.id == 0 do res.id = fsnow(m, "id")
	client_push_event(c, Event{kind = .Rest, data = r.body, arena = r.arena, result = res})
}

@(private)
run_api :: proc(c: ^Client, j: ^Job) {
	extra := j.extra
	url := strings.concatenate({API_ORIGIN, API_PREFIX, j.path}, context.temp_allocator)
	if j.etag {
		e := make([dynamic]http.Header, 0, 2, context.temp_allocator)
		append(&e, http.Header{"cache-control", "max-age=0"})
		if tag := etag_get(c, url); tag != "" do append(&e, http.Header{"if-none-match", tag})
		extra = e[:]
	}
	tl_js_lower_auth = j.js_lower_auth
	r := api_call(c, j.method, j.path, j.body, j.content_type, j.context_b64, extra, j.retries, j.retry_429, j.no_auth, j.no_super_props, j.referer)
	tl_js_lower_auth = false
	if j.etag && r.status == 200 do if tag, ok := http.header_get(r.headers, "etag"); ok do etag_put(c, url, tag)
	if j.op == .Ack && r.ok {
		if m := vmap(r.body); m != nil {
			tok := fstr(m, "token")
			sync.mutex_lock(&c.ack_mu)
			delete(c.ack_token, c.allocator)
			c.ack_token = strings.clone(tok, c.allocator) if tok != "" else ""
			sync.mutex_unlock(&c.ack_mu)
		}
	}
	if j.op == .Experiments && r.ok {
		if m := vmap(r.body); m != nil {
			inst := fstr(m, "installation")
			if inst != "" {
				sync.mutex_lock(&c.id.mu)
				if c.id.installation_id == "" do c.id.installation_id = strings.clone(inst, c.allocator)
				sync.mutex_unlock(&c.id.mu)
			}
		}
	}
	if j.op == .Startup && r.ok && strings.has_prefix(j.path, "/quests/@me") do note_quest_applications(c, r.body)
	if j.on_body != nil && r.ok do j.on_body(c, r.body)
	push_result(c, j, r)
}

// QuestsStore loads /quests/@me; the application of every quest is then
// hydrated with GET /applications/public?application_ids=..(one param per id,
// in quest order). Fired ≈435 ms after READY in the coldstart capture.
@(private)
collect_app_ids :: proc(v: V, out: ^[dynamic]Snowflake) {
	// Only quests with a console task (PLAY_ON_XBOX / PLAY_ON_PLAYSTATION)
	// hydrate their application (console-linking UI); first-appearance order
	// (fixture cold_start: 15 of 29 quest applications).
	for q in flist(vmap(v), "quests") {
		cfg := fmap(vmap(q), "config")
		tasks := fmap(fmap(cfg, "task_config_v2"), "tasks")
		console := false
		for p in tasks {
			k, _ := p.key.(string)
			if k == "PLAY_ON_XBOX" || k == "PLAY_ON_PLAYSTATION" do console = true
		}
		if !console do continue
		id := fsnow(fmap(cfg, "application"), "id")
		if id == 0 do continue
		dup := false
		for e in out do if e == id do dup = true
		if !dup do append(out, id)
	}
}

@(private)
note_quest_applications :: proc(c: ^Client, body: V) {
	ids := make([dynamic]Snowflake, context.temp_allocator)
	collect_app_ids(body, &ids)
	if len(ids) == 0 do return
	sync.mutex_lock(&c.job_mu)
	delete(c.quest_app_ids)
	c.quest_app_ids = make([]Snowflake, len(ids), c.allocator)
	copy(c.quest_app_ids, ids[:])
	ready := c.ready_ms
	sync.mutex_unlock(&c.job_mu)
	if ready != 0 do schedule_applications_public(c, ready)
}

schedule_applications_public :: proc(c: ^Client, ready_ms: i64) {
	// Hydrated by the home (friends/quests) surface only.
	if client_route_kind(c.start_route_guild, c.start_route_channel) != .Home do return
	sync.mutex_lock(&c.job_mu)
	ids := c.quest_app_ids
	c.quest_app_ids = nil
	sync.mutex_unlock(&c.job_mu)
	if len(ids) == 0 do return
	defer delete(ids, c.allocator)
	q: Query
	query_init(&q, "/applications/public")
	for id in ids do query_add_snow(&q, "application_ids", id)
	j := job_new(.Api, .Startup)
	j.method = "GET"
	j.path = job_str(j, query_string(&q))
	j.not_before = max(ready_ms + 315, now_ms())
	job_submit(c, j)
}

// Thread-local fetch() time of the job a worker is running; the transport
// takes it as the request's start (once) for the recorder.
@(thread_local)
tl_dispatch_ms: f64

// Thread-local: the running job's page code spelled the header "authorization"
// (read by the recorder's renderer view; the wire is lowercase either way).
@(thread_local)
tl_js_lower_auth: bool

@(private)
send_preflight :: proc(c: ^Client, j: ^Job) {
	pre := http.Request{method = "OPTIONS", scheme = "https", authority = j.host, path = j.path, headers = preflight_headers(c.id.platform, "GET", "if-none-match", true)}
	presp, _ := transport_round_trip(&c.transport, j.host, pre)
	http.response_destroy(&presp)
}

// preflight_note: a request to url is scheduled; pending = its preflight is
// a separate, earlier job.
preflight_note :: proc(c: ^Client, host, path: string, pending: bool) {
	if !pending do return
	url := strings.concatenate({"https://", host, path}, context.temp_allocator)
	sync.mutex_lock(&c.preflight_mu)
	defer sync.mutex_unlock(&c.preflight_mu)
	if url in c.preflights {
		c.preflights[url] = 1
	} else {
		c.preflights[strings.clone(url, c.allocator)] = 1
	}
}

@(private)
preflight_finish :: proc(c: ^Client, url: string) {
	sync.mutex_lock(&c.preflight_mu)
	if url in c.preflights do c.preflights[url] = 2
	sync.cond_broadcast(&c.preflight_cond)
	sync.mutex_unlock(&c.preflight_mu)
}

// preflight_wait: true when an earlier job sent (or is sending) url's
// preflight; waits for it to finish (at most 10 s).
@(private)
preflight_wait :: proc(c: ^Client, url: string) -> bool {
	sync.mutex_lock(&c.preflight_mu)
	defer sync.mutex_unlock(&c.preflight_mu)
	st, ok := c.preflights[url]
	if !ok do return false
	deadline := time.tick_now()
	for st == 1 && time.tick_since(deadline) < 10 * time.Second {
		sync.cond_wait_with_timeout(&c.preflight_cond, &c.preflight_mu, 250 * time.Millisecond)
		st = c.preflights[url]
	}
	key, _ := delete_key(&c.preflights, url)
	delete(key, c.allocator)
	return true
}

// run_web: unauthenticated XHR (startup table entries for status/cdn/latency).
@(private)
run_web :: proc(c: ^Client, j: ^Job) {
	now := now_ms()
	referer := j.referer
	if referer == "" {
		referer = client_route_referer(c) if j.site == .Same_Origin else API_ORIGIN + "/"
	}
	// XHR/fetch without credentials: cookies only go to the same origin.
	cookie := "" if j.no_cookies || j.site != .Same_Origin else cookie_header(&c.jar, j.host, j.path, true, now)
	url := strings.concatenate({"https://", j.host, j.path}, context.temp_allocator)
	js := j.js_headers
	// Chrome's HTTP cache: fresh entries are served without a request; stale
	// ones are revalidated with the stored validators (appended after the
	// request's own headers). Not for cache:'no-cache' fetches (etag jobs).
	validators: []http.Header
	centry, cbody, cached := cache_read(c, url)
	if cached && !j.etag {
		if centry.fresh_until > now {
			client_push_event(c, Event{kind = .Rest, result = Rest_Result{op = j.result.op, ok = true, status = 200, tag = j.result.tag}})
			return
		}
		v := make([dynamic]http.Header, 0, 2, context.temp_allocator)
		if centry.etag != "" do append(&v, http.Header{"if-none-match", centry.etag})
		if centry.last_modified != "" do append(&v, http.Header{"if-modified-since", centry.last_modified})
		validators = v[:]
	}
	_ = cbody
	if j.etag {
		e := make([dynamic]http.Header, 0, 2, context.temp_allocator)
		append(&e, http.Header{"cache-control", "max-age=0"})
		tag := etag_get(c, url)
		if tag != "" do append(&e, http.Header{"if-none-match", tag})
		js = e[:]
		if j.preflight_if_etag && j.site != .Same_Origin {
			if j.preflight_only {
				if tag != "" do send_preflight(c, j)
				preflight_finish(c, url)
				return
			}
			if tag != "" && !preflight_wait(c, url) do send_preflight(c, j)
		}
	}
	hin := Web_Headers_Input{
		method     = j.method,
		site       = j.site,
		referer    = referer,
		cookie     = cookie,
		js_headers = js,
		cache_validator = validators,
	}
	req := http.Request{method = j.method, scheme = "https", authority = j.host, path = j.path, headers = web_headers(c.id.platform, hin), body = j.body}
	resp, err := transport_round_trip(&c.transport, j.host, req)
	if err == .None && !j.etag && j.method == "GET" {
		fresh, storable := freshness_ms(resp.headers[:], now_ms())
		if resp.status == 200 && storable {
			ce := Cache_Entry{status = 200, fresh_until = fresh}
			ce.content_type, _ = http.header_get(resp.headers[:], "content-type")
			ce.etag, _ = http.header_get(resp.headers[:], "etag")
			ce.last_modified, _ = http.header_get(resp.headers[:], "last-modified")
			cache_write(c, url, ce, resp.body[:], true)
		} else if resp.status == 304 && cached {
			centry.fresh_until = fresh
			cache_write(c, url, centry, nil, false)
		}
	}
	if j.etag && err == .None && resp.status == 200 do if tag, ok := http.header_get(resp.headers[:], "etag"); ok do etag_put(c, url, tag)
	res := j.result
	res.status = resp.status
	res.ok = err == .None && resp.status >= 200 && resp.status < 400
	http.response_destroy(&resp)
	client_push_event(c, Event{kind = .Rest, result = res})
}

// ---- attachments ----
// Official flow (CloudUploader):
//   1. POST /channels/{id}/attachments {"files":[{filename,file_size,id,is_clip:false,original_content_type}]}
//   2. CORS preflight + PUT <upload_url> (application/octet-stream) to storage.googleapis.com
//   3. POST /channels/{id}/messages with attachments:[{id:"0",filename,uploaded_filename}]
@(private)
run_upload :: proc(c: ^Client, j: ^Job) {
	cid := j.result.channel_id
	alloc := job_alloc(j)
	// 1. upload URLs (one request per file, as each CloudUpload does)
	uploaded := make([dynamic][3]string, 0, len(j.files), alloc) // filename, upload_filename, mime
	for f in j.files {
		w: Json
		json_init(&w)
		json_obj(&w)
		json_key(&w, "files")
		json_arr(&w)
		json_obj(&w)
		json_kstr(&w, "filename", f.filename)
		json_kint(&w, "file_size", i64(len(f.data)))
		sync.mutex_lock(&c.job_mu)
		c.upload_seq += 1
		uid := c.upload_seq
		sync.mutex_unlock(&c.job_mu)
		json_kstr(&w, "id", itoa(uid))
		json_kbool(&w, "is_clip", false)
		if f.mime != "" do json_kstr(&w, "original_content_type", f.mime)
		json_obj_end(&w)
		json_arr_end(&w)
		json_obj_end(&w)
		body := transmute([]byte)json_string(&w)
		r := api_call(c, "POST", strings.concatenate({"/channels/", snowflake_string(cid), "/attachments"}, context.temp_allocator), body, "application/json", "", nil, 0, 0)
		if !r.ok {
			push_result(c, j, r)
			return
		}
		att := flist(vmap(r.body), "attachments")
		if len(att) == 0 {
			r.ok = false
			push_result(c, j, r)
			return
		}
		up_url := strings.clone(fstr(vmap(att[0]), "upload_url"), alloc)
		up_name := strings.clone(fstr(vmap(att[0]), "upload_filename"), alloc)
		virtual.arena_destroy(r.arena)
		free(r.arena)
		// 2. preflight + PUT
		if !upload_put(c, up_url, f.data) {
			client_push_event(c, Event{kind = .Rest, result = Rest_Result{op = .Upload, channel_id = cid, nonce = j.result.nonce, ok = false}})
			return
		}
		append(&uploaded, [3]string{f.filename, up_name, f.mime})
	}
	// 3. the message
	w: Json
	json_init(&w)
	json_arr(&w)
	for u, i in uploaded {
		json_obj(&w)
		json_kstr(&w, "id", itoa(i))
		json_kstr(&w, "filename", u[0])
		json_kstr(&w, "uploaded_filename", u[1])
		if u[2] != "" do json_kstr(&w, "original_content_type", u[2])
		json_obj_end(&w)
	}
	json_arr_end(&w)
	body := j.message_json(j, json_string(&w))
	r := api_call(c, "POST", j.path, body, "application/json", j.context_b64, nil, 3, 1)
	j.result.op = .Send_Message
	push_result(c, j, r)
}

@(private)
split_url :: proc(url: string) -> (host, path: string, ok: bool) {
	if !strings.has_prefix(url, "https://") do return "", "", false
	rest := url[len("https://"):]
	slash := strings.index_byte(rest, '/')
	if slash < 0 do return rest, "/", true
	return rest[:slash], rest[slash:], true
}

@(private)
upload_put :: proc(c: ^Client, url: string, data: []byte) -> bool {
	host, path, ok := split_url(url)
	if !ok do return false
	pre := http.Request{method = "OPTIONS", scheme = "https", authority = host, path = path, headers = preflight_headers(c.id.platform, "PUT", "content-type", false)}
	presp, perr := transport_round_trip(&c.transport, host, pre)
	pstatus := presp.status
	http.response_destroy(&presp)
	if perr != .None || pstatus >= 300 do return false
	put := http.Request{method = "PUT", scheme = "https", authority = host, path = path, headers = upload_put_headers(c.id.platform, len(data)), body = data}
	backoff := backoff_make(500, 5000)
	for attempt in 0 ..< 3 {
		resp, err := transport_round_trip(&c.transport, host, put)
		status := resp.status
		http.response_destroy(&resp)
		if err == .None && status >= 200 && status < 300 do return true
		if attempt < 2 do time.sleep(time.Duration(backoff_fail(&backoff)) * time.Millisecond)
	}
	return false
}

// ---- applying results on the UI thread ----

client_apply_rest :: proc(c: ^Client, e: ^Event) {
	s := &c.store
	r := &e.result
	context.allocator = s.allocator
	switch r.op {
	case .Fetch_Messages:
		l := message_list(s, r.channel_id)
		l.loading = false
		if r.ok {
			items := vlist(e.data)
			for mv in items do upsert_message(s, vmap(mv))
			first := !l.loaded
			l.loaded = true
			if r.before != 0 || len(items) > 0 do l.has_more_before = len(items) >= r.limit
			if len(items) < r.limit do l.has_more_before = false
			if first && r.before == 0 do on_channel_page(c, r.channel_id, len(items), len(items) >= r.limit)
		}
	case .Send_Message, .Upload:
		if rt, ok := &c.analytics.roundtrips[r.nonce]; ok && rt.api == 0 do rt.api = now_ms()
		if r.ok {
			upsert_message(s, vmap(e.data))
		} else if l, ok := &s.messages[r.channel_id]; ok {
			nonce := snowflake_string(r.nonce)
			for &m in l.messages {
				if m.pending && m.nonce == nonce {
					m.failed = true
					m.pending = false
				}
			}
		}
	case .Edit_Message:
		if r.ok do upsert_message(s, vmap(e.data))
	case .Delete_Message:
		if r.ok {
			if l, ok := &s.messages[r.channel_id]; ok {
				if i := message_index(l, r.message_id); i >= 0 {
					free_message(s, &l.messages[i])
					ordered_remove(&l.messages, i)
				}
			}
		}
	case .Open_Dm:
		if r.ok {
			cid := parse_channel_into(s, vmap(e.data))
			r.id = cid
			if cid != 0 {
				found := false
				for pc in s.private_channels do if pc == cid do found = true
				if !found do append(&s.private_channels, cid)
			}
		}
	case .Fetch_Profile:
		if r.ok {
			m := vmap(e.data)
			uid := parse_user_into(s, fmap(m, "user"))
			if prof := fmap(m, "user_profile"); prof != nil && uid != 0 {
				u := &s.users[uid]
				if vhas(prof, "bio") {free_str(u.bio, s.allocator); u.bio = clone_str(fstr(prof, "bio"), s.allocator)}
				if vhas(prof, "pronouns") {free_str(u.pronouns, s.allocator); u.pronouns = clone_str(fstr(prof, "pronouns"), s.allocator)}
				if vhas(m, "mutual_guilds") do u.mutual_guilds = len(flist(m, "mutual_guilds"))
				if vhas(m, "mutual_friends") do u.mutual_friends = len(flist(m, "mutual_friends"))
				else if vhas(m, "mutual_friends_count") do u.mutual_friends = int(fint(m, "mutual_friends_count"))
			}
		}
	case .Settings:
		if r.ok do if sp := fstr(vmap(e.data), "settings"); sp != "" do apply_settings_proto(s, sp)
	case .None, .Media, .Add_Reaction, .Remove_Reaction, .Typing, .Ack, .Relationship, .Experiments, .Startup, .Guild_Open:
	}
}

