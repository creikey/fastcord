package discord

import "base:runtime"
import "core:fmt"
import "core:strings"
import "fc:locks"

// Username availability while editing it (Settings > My Account > Username),
// as the official client's UniqueUsernamesStore / attemptUsername (bundle chunk
// with "UniqueUsernamesStore"; fixture account_edits):
//   - every change of the field's (non-empty) text is debounced 800 ms (lodash
//     trailing debounce); a value checked in the last 60 s is not checked again;
//   - the check: local rules first (letters, digits, "_" and "." only, no "..",
//     2-32 characters) -> pomelo_errors with the rule's message, no request; else
//     POST /users/@me/pomelo-attempt {"username"} -> network_action_pomelo_attempt
//     on the response, and pomelo_errors {reason:"already_taken"} when taken;
//   - a 429 marks the value rate limited for Retry-After (default 7 s).
// The change itself is PATCH /users/@me {"username","password"} (update_username).

USERNAME_CHECK_DEBOUNCE_MS :: 800
USERNAME_CHECK_CACHE_MS :: 60_000

Username_Check_State :: enum u8 {
	Unknown, // not checked (yet)
	Available,
	Taken,
	Error, // invalid by the local rules, or the server's message
	Rate_Limited,
}

Username_Check :: struct {
	state:   Username_Check_State,
	message: string, // Error: the reason (temp allocator)
}

@(private)
Pomelo_Result :: struct {
	state:   Username_Check_State,
	message: string, // heap
	until:   i64, // cache entry valid until (ms)
}

@(private)
Pomelo_State :: struct {
	mu:          locks.Mutex, // results (written from response workers)
	results:     map[string]Pomelo_Result, // heap keys
	limited_til: i64,
	pending:     string, // heap: the debounced value
	due:         i64,
}

@(private)
pomelo_destroy :: proc(c: ^Client) {
	p := &c.pomelo
	a := runtime.heap_allocator()
	for k, r in p.results {
		delete(k, a)
		delete(r.message, a)
	}
	delete(p.results)
	delete(p.pending, a)
	p^ = {}
}

// username_input_changed: the username field's text is now `name` (the app calls
// it when the editor opens with the current username and on every edit).
username_input_changed :: proc(c: ^Client, name: string) {
	if name == "" do return // the effect skips "" (a check already queued still runs)
	if username_check(c, name).state != .Unknown do return // checked (cached) or rate limited
	p := &c.pomelo
	a := runtime.heap_allocator()
	delete(p.pending, a)
	p.pending = strings.clone(name, a)
	p.due = now_ms() + USERNAME_CHECK_DEBOUNCE_MS
}

// username_check: what is known about `name` (Unknown while unchecked).
username_check :: proc(c: ^Client, name: string) -> Username_Check {
	p := &c.pomelo
	now := now_ms()
	locks.lock(&p.mu)
	defer locks.unlock(&p.mu)
	r, ok := p.results[name]
	limited := p.limited_til > now
	if ok && r.until <= now do ok = false
	if limited && (!ok || r.state == .Rate_Limited) do return {state = .Rate_Limited}
	if !ok || (!limited && r.state == .Rate_Limited) do return {}
	return {state = r.state, message = strings.clone(r.message, context.temp_allocator)}
}

// username_rule_error: the client's local rule a username breaks ("" if none),
// with the English messages (intl z7c4bP, C7G+gr, IpijXA).
username_rule_error :: proc(name: string) -> string {
	for ch in name {
		ok := (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') || ch == '_' || ch == '.'
		if !ok do return "Please only use numbers, letters, underscores _ , or periods."
	}
	if strings.contains(name, "..") do return "Username cannot contain repeating dots."
	if len(name) < 2 || len(name) > 32 do return "This must be 2-32 characters."
	return ""
}

@(private = "file")
pomelo_store :: proc(c: ^Client, name: string, state: Username_Check_State, message: string, ttl_ms: i64) {
	p := &c.pomelo
	a := runtime.heap_allocator()
	locks.lock(&p.mu)
	defer locks.unlock(&p.mu)
	if p.results == nil do p.results = make(map[string]Pomelo_Result, 16, a)
	if old, ok := p.results[name]; ok {
		delete(old.message, a)
		p.results[name] = {state, strings.clone(message, a), now_ms() + ttl_ms}
		return
	}
	p.results[strings.clone(name, a)] = {state, strings.clone(message, a), now_ms() + ttl_ms}
}

@(private = "file")
analytics_pomelo_error :: proc(c: ^Client, reason: string) {
	w := aw_begin()
	json_kstr(&w, "reason", reason)
	json_kbool(&w, "username_error", true)
	json_kbool(&w, "one_click_flow", false)
	json_kstr(&w, "location", "modal")
	aw_track(c, "pomelo_errors", &w)
}

// flush_username_check: the debounced check, when due (client_poll).
@(private)
flush_username_check :: proc(c: ^Client, now: i64) {
	p := &c.pomelo
	if p.due == 0 || now < p.due do return
	p.due = 0
	name := strings.clone(p.pending, context.temp_allocator)
	if rule := username_rule_error(name); rule != "" {
		analytics_pomelo_error(c, rule)
		pomelo_store(c, name, .Error, rule, USERNAME_CHECK_CACHE_MS)
		c.store.changed += 1
		return
	}
	w: Json
	json_init(&w)
	json_obj(&w)
	json_kstr(&w, "username", name)
	json_obj_end(&w)
	j := job_new(.Api, .None)
	j.method = "POST"
	j.path = "/users/@me/pomelo-attempt"
	j.body = transmute([]byte)job_str(j, json_string(&w))
	j.content_type = "application/json"
	j.track_props = job_str(j, name)
	j.on_response = pomelo_attempt_done
	job_submit(c, j)
}

// pomelo_attempt_done: the attempt's response (worker thread).
@(private = "file")
pomelo_attempt_done :: proc(c: ^Client, j: ^Job, status: int, body: V) {
	if status == 0 do return // no response: nothing is tracked or cached
	name := j.track_props
	w := aw_begin()
	json_kint(&w, "status_code", i64(status))
	json_kstr(&w, "url", "/users/@me/pomelo-attempt")
	json_kstr(&w, "request_method", "post")
	json_kstr(&w, "requested_username", name)
	aw_track(c, "network_action_pomelo_attempt", &w)
	m := vmap(body)
	if status >= 200 && status < 300 {
		taken := fbool(m, "taken")
		if taken do analytics_pomelo_error(c, "already_taken")
		pomelo_store(c, name, .Taken if taken else .Available, "", USERNAME_CHECK_CACHE_MS)
	} else {
		msg := api_error_text(body)
		if msg != "" do analytics_pomelo_error(c, msg)
		if status == 429 {
			retry := i64(7_000)
			if v := vget(m, "retry_after"); v != nil do retry = i64(r_f64(v) * 1000)
			locks.lock(&c.pomelo.mu)
			c.pomelo.limited_til = now_ms() + retry
			locks.unlock(&c.pomelo.mu)
			pomelo_store(c, name, .Rate_Limited, msg, retry)
		} else {
			pomelo_store(c, name, .Error, msg if status < 500 && status != 401 else fmt.tprintf("HTTP %d", status), USERNAME_CHECK_CACHE_MS)
		}
	}
	if c.cfg.wakeup != nil do c.cfg.wakeup(c.cfg.wakeup_data)
}

@(private = "file")
r_f64 :: proc(v: V) -> f64 {
	#partial switch x in v {
	case f64:
		return x
	case i64:
		return f64(x)
	}
	return 0
}
