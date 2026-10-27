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

USERNAME_CHECK_DEBOUNCE_MS :: 800;
USERNAME_CHECK_CACHE_MS :: 60_000;

Username_Check_State :: enum u8 {
	Unknown; // not checked (yet)
	Available;
	Taken;
	Error; // invalid by the local rules, or the server's message
	Rate_Limited;
}

Username_Check :: struct {
	state: Username_Check_State;
	message: string; // Error: the reason (temp allocator)
}
#scope_module

Pomelo_Result :: struct {
	state: Username_Check_State;
	message: string; // heap
	until: s64; // cache entry valid until (ms)
}

Pomelo_State :: struct {
	mu: locks.Mutex; // results (written from response workers)
	results: Table(string, Pomelo_Result); // heap keys
	limited_til: s64;
	pending: string; // heap: the debounced value
	due: s64;
}

pomelo_destroy :: (c: *Client) {
	p := *c.pomelo;
	a := context.default_allocator;
	for r, k: p.results {
		free(k,, a);
		free_str(r.message, a);
	}
	deinit(*p.results);
	free(p.pending,, a);
	p.* = .{};
}
#scope_export

// username_input_changed: the username field's text is now `name` (the app calls
// it when the editor opens with the current username and on every edit).
username_input_changed :: (c: *Client, name: string) {
	if !name return; // the effect skips "" (a check already queued still runs)
	if username_check(c, name).state != .Unknown return; // checked (cached) or rate limited
	p := *c.pomelo;
	free(p.pending,, context.default_allocator);
	p.pending = copy_string(name,, context.default_allocator);
	p.due = now_ms() + USERNAME_CHECK_DEBOUNCE_MS;
}

// username_check: what is known about `name` (Unknown while unchecked).
username_check :: (c: *Client, name: string) -> Username_Check {
	p := *c.pomelo;
	now := now_ms();
	locks.lock(*p.mu);
	defer locks.unlock(*p.mu);
	ok, r := table_find(*p.results, name);
	limited := p.limited_til > now;
	if ok && r.until <= now ok = false;
	if limited && (!ok || r.state == .Rate_Limited) return .{state = .Rate_Limited};
	if !ok || (!limited && r.state == .Rate_Limited) return .{};
	return .{state = r.state, message = copy_string(r.message,, temp)};
}

// username_rule_error: the client's local rule a username breaks ("" if none),
// with the English messages (intl z7c4bP, C7G+gr, IpijXA).
username_rule_error :: (name: string) -> string {
	for cast([]u8) name if !is_alnum(it) && it != #char "." return "Please only use numbers, letters, underscores _ , or periods.";
	if contains(name, "..") return "Username cannot contain repeating dots.";
	if name.count < 2 || name.count > 32 return "This must be 2-32 characters.";
	return "";
}
#scope_file

pomelo_store :: (c: *Client, name: string, state: Username_Check_State, message: string, ttl_ms: s64) {
	p := *c.pomelo;
	a := context.default_allocator;
	locks.lock(*p.mu);
	defer locks.unlock(*p.mu);
	p.results.allocator = a; // read and written from response workers too: never their temp
	r := table_find_pointer(*p.results, name);
	if r free_str(r.message, a);
	else r = table_set(*p.results, copy_string(name,, a), .{});
	r.* = .{state, clone_str(message, a), now_ms() + ttl_ms};
}

analytics_pomelo_error :: (c: *Client, reason: string) {
	w := aw_begin();
	json_kstr(*w, "reason", reason);
	json_kbool(*w, "username_error", true);
	json_kbool(*w, "one_click_flow", false);
	json_kstr(*w, "location", "modal");
	aw_track(c, "pomelo_errors", *w);
}
#scope_module

// flush_username_check: the debounced check, when due (client_poll).
flush_username_check :: (c: *Client, now: s64) {
	p := *c.pomelo;
	if p.due == 0 || now < p.due return;
	p.due = 0;
	name := copy_string(p.pending,, temp);
	rule := username_rule_error(name);
	if rule {
		analytics_pomelo_error(c, rule);
		pomelo_store(c, name, .Error, rule, USERNAME_CHECK_CACHE_MS);
		c.store.changed += 1;
		return;
	}
	w: Json;
	json_init(*w);
	json_obj(*w);
	json_kstr(*w, "username", name);
	json_obj_end(*w);
	j := job_new(.Api, .None);
	j.method = "POST";
	j.path = "/users/@me/pomelo-attempt";
	j.body = cast([]u8) job_str(j, json_string(*w));
	j.content_type = "application/json";
	j.track_props = job_str(j, name);
	j.on_response = pomelo_attempt_done;
	job_submit(c, j);
}
#scope_file

// pomelo_attempt_done: the attempt's response (worker thread).
pomelo_attempt_done :: (c: *Client, j: *Job, status: int, body: V) {
	if status == 0 return; // no response: nothing is tracked or cached
	name := j.track_props;
	w := aw_begin();
	json_kint(*w, "status_code", status);
	json_kstr(*w, "url", "/users/@me/pomelo-attempt");
	json_kstr(*w, "request_method", "post");
	json_kstr(*w, "requested_username", name);
	aw_track(c, "network_action_pomelo_attempt", *w);
	m := vmap(body);
	if status >= 200 && status < 300 {
		taken := fbool(m, "taken");
		if taken analytics_pomelo_error(c, "already_taken");
		pomelo_store(c, name, ifx taken then .Taken else .Available, "", USERNAME_CHECK_CACHE_MS);
	} else {
		msg := api_error_text(body);
		if msg analytics_pomelo_error(c, msg);
		if status == 429 {
			retry: s64 = 7_000;
			v := vget(m, "retry_after");
			if !vis_null(v) retry = cast(s64) (vf64(v) * 1000);
			locks.lock(*c.pomelo.mu);
			c.pomelo.limited_til = now_ms() + retry;
			locks.unlock(*c.pomelo.mu);
			pomelo_store(c, name, .Rate_Limited, msg, retry);
		} else {
			pomelo_store(c, name, .Error, ifx status < 500 && status != 401 then msg else tprint("HTTP %", status), USERNAME_CHECK_CACHE_MS);
		}
	}
	if c.cfg.wakeup c.cfg.wakeup(c.cfg.wakeup_data);
}

