package discord

import "core:mem/virtual"
import "core:strings"
import "core:sync"
import "core:time"
import "fc:etf"
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
api_call :: proc(c: ^Client, method, path: string, body: []byte, content_type, context_b64: string, extra: []http.Header, retries: int, retry_429: int, no_auth := false) -> (r: Api_Response) {
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
			super_props_b64 = super_properties_b64(&c.id, now),
			context_b64     = context_b64,
			referer         = client_route_referer(c),
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
	r := api_call(c, j.method, j.path, j.body, j.content_type, j.context_b64, j.extra, j.retries, j.retry_429, j.no_auth)
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
	push_result(c, j, r)
}

// QuestsStore loads /quests/@me; the application of every quest is then
// hydrated with GET /applications/public?application_ids=..(one param per id,
// in quest order). Fired ≈435 ms after READY in the coldstart capture.
@(private)
collect_app_ids :: proc(v: V, out: ^[dynamic]Snowflake) {
	#partial switch x in v {
	case etf.Map:
		if app := fmap(x, "application"); app != nil {
			id := fsnow(app, "id")
			if id != 0 {
				dup := false
				for e in out do if e == id do dup = true
				if !dup do append(out, id)
			}
		}
		for p in x do collect_app_ids(p.value, out)
	case etf.List:
		for e in x do collect_app_ids(e, out)
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
	j.not_before = max(ready_ms + 435, now_ms())
	job_submit(c, j)
}

// run_web: unauthenticated XHR (startup table entries for status/cdn/latency).
@(private)
run_web :: proc(c: ^Client, j: ^Job) {
	now := now_ms()
	referer := j.referer
	if referer == "" {
		referer = client_route_referer(c) if j.site == .Same_Origin else API_ORIGIN + "/"
	}
	cookie := cookie_header(&c.jar, j.host, j.path, true, now)
	hin := Web_Headers_Input{
		method     = j.method,
		site       = j.site,
		referer    = referer,
		cookie     = cookie,
		js_headers = j.js_headers,
	}
	req := http.Request{method = j.method, scheme = "https", authority = j.host, path = j.path, headers = web_headers(c.id.platform, hin), body = j.body}
	resp, err := transport_round_trip(&c.transport, j.host, req)
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
	uploaded := make([dynamic][2]string, 0, len(j.files), alloc) // filename, upload_filename
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
		up_url := fstr(vmap(att[0]), "upload_url")
		up_name := strings.clone(fstr(vmap(att[0]), "upload_filename"), alloc)
		virtual.arena_destroy(r.arena)
		free(r.arena)
		// 2. preflight + PUT
		if !upload_put(c, up_url, f.data) {
			client_push_event(c, Event{kind = .Rest, result = Rest_Result{op = .Upload, channel_id = cid, nonce = j.result.nonce, ok = false}})
			return
		}
		append(&uploaded, [2]string{f.filename, up_name})
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
	pre := http.Request{method = "OPTIONS", scheme = "https", authority = host, path = path, headers = preflight_headers(c.id.platform, "PUT", "content-type")}
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
			l.loaded = true
			if r.before != 0 || len(items) > 0 do l.has_more_before = len(items) >= r.limit
			if len(items) < r.limit do l.has_more_before = false
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
			}
		}
	case .Settings:
		if r.ok do if sp := fstr(vmap(e.data), "settings"); sp != "" do apply_settings_proto(s, sp)
	case .None, .Media, .Add_Reaction, .Remove_Reaction, .Typing, .Ack, .Relationship, .Experiments, .Startup, .Guild_Open:
	}
}

