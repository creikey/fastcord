// Captchas (HTTPUtils' interceptResponse): a 400 whose body has captcha_key opens the captcha modal
// (extractCaptchaPropsFromResponse) and the same request goes again with X-Captcha-Key, plus
// X-Captcha-Rqtoken and X-Captcha-Session-Id when the response had them; cancelling rejects it. Here:
// the challenge, checked like any other server input, the retry headers and the modal's telemetry.
// The app shows the challenge (src/app/captcha.jai).

Captcha_Service :: enum u8 {
	Recaptcha; // the modal's default, also for a missing or unknown captcha_service
	Hcaptcha;
	Recaptcha_Enterprise;
	Turnstile;
}

CAPTCHA_SERVICE_NAMES :: string.["recaptcha", "hcaptcha", "recaptcha_enterprise", "turnstile"];

Captcha :: struct {
	service: Captcha_Service;
	sitekey: string;
	session_id: string;
	rqdata: string;
	rqtoken: string;
	invisible: bool; // should_serve_invisible: no checkbox, the challenge (if any) opens at once
	user_flow: string;
}

// captcha_parse: the challenge in a failed response's body; false when there is none or it is malformed.
captcha_parse :: (body: etf.Map) -> Captcha, bool {
	ch: Captcha;
	if !vhas(body, "captcha_key") return ch, false;
	name := fstr(body, "captcha_service");
	for CAPTCHA_SERVICE_NAMES if it == name ch.service = xx it_index;
	ch.sitekey = fstr(body, "captcha_sitekey");
	ch.session_id = fstr(body, "captcha_session_id");
	ch.rqdata = fstr(body, "captcha_rqdata");
	ch.rqtoken = fstr(body, "captcha_rqtoken");
	ch.invisible = fbool(body, "should_serve_invisible");
	ch.user_flow = fstr(body, "user_flow");
	// they go into the captcha page's script and into headers: token characters only
	ok := ch.sitekey != "" && captcha_token_ok(ch.sitekey, 128) && captcha_token_ok(ch.session_id, 256)
		&& captcha_token_ok(ch.rqdata, 16384) && captcha_token_ok(ch.rqtoken, 16384) && captcha_token_ok(ch.user_flow, 64);
	return ch, ok;
}

// captcha_token_ok: at most max bytes of letters, digits and "-_.:+/=" (sitekeys, rqdata, JWTs, solved
// tokens).
captcha_token_ok :: (s: string, max: int) -> bool {
	if s.count > max return false;
	for cast([]u8) s if !is_alnum(it) && !contains("-_.:+/=", it) return false;
	return true;
}

captcha_copy :: (ch: Captcha, allocator: Allocator) -> Captcha {
	push_allocator(allocator);
	r := ch;
	r.sitekey = copy_string(ch.sitekey);
	r.session_id = copy_string(ch.session_id);
	r.rqdata = copy_string(ch.rqdata);
	r.rqtoken = copy_string(ch.rqtoken);
	r.user_flow = copy_string(ch.user_flow);
	return r;
}

captcha_free :: (ch: *Captcha, allocator: Allocator) {
	push_allocator(allocator);
	free(ch.sitekey);
	free(ch.session_id);
	free(ch.rqdata);
	free(ch.rqtoken);
	free(ch.user_flow);
	ch.* = .{};
}

// captcha_headers: the retry's headers (temp), in the interceptor's order.
captcha_headers :: (ch: Captcha, key: string) -> []http.Header {
	h: [..]http.Header;
	h.allocator = temp;
	array_add(*h, .{"x-captcha-key", key});
	if ch.rqtoken array_add(*h, .{"x-captcha-rqtoken", ch.rqtoken});
	if ch.session_id array_add(*h, .{"x-captcha-session-id", ch.session_id});
	return h;
}

// ---- a send that asked for a captcha ----

// A message send Discord answered with a captcha (UI thread). Its copy stays pending while the app
// shows the challenge (send_captcha_take); the solved token sends the same POST again with the captcha's
// headers and the same nonce (send_captcha_answer), and closing it marks the copy failed. One at a time:
// a newer one replaces it, and the older copy fails.
Send_Captcha :: struct {
	channel_id: Snowflake;
	nonce: Snowflake; // 0: none
	tag: u64;
	body: string;
	context_b64: string;
	captcha: Captcha;
	shown: bool; // handed to the app
}

// send_captcha_keep (a failed send's result): true when it asked for a well-formed captcha, now kept.
send_captcha_keep :: (c: *Client, e: *Event) -> bool {
	r := e.result;
	if !r.captcha || r.status != 400 || !e.sent_body || e.data.kind != .Map return false;
	ch, ok := captcha_parse(e.data.map);
	if !ok return false;
	sc := *c.send_captcha;
	if sc.nonce send_captcha_drop(c, true);
	sc.* = .{channel_id = r.channel_id, nonce = r.nonce, tag = r.tag, body = copy_string(e.sent_body,, c.allocator),
		context_b64 = copy_string(e.sent_context,, c.allocator), captcha = captcha_copy(ch, c.allocator)};
	analytics_captcha_opened(c, ch);
	return true;
}

// send_captcha_take: a send's captcha the app hasn't shown yet (strings valid until it's answered).
send_captcha_take :: (c: *Client) -> Captcha, bool {
	sc := *c.send_captcha;
	if !sc.nonce || sc.shown return .{}, false;
	sc.shown = true;
	return sc.captcha, true;
}

// send_captcha_answer: the solved token; the send goes again with the captcha's headers.
send_captcha_answer :: (c: *Client, key: string) {
	sc := *c.send_captcha;
	if !sc.nonce return;
	if !key || !captcha_token_ok(key, 16384) {
		send_captcha_cancel(c);
		return;
	}
	j := job_new(.Api, .Send_Message);
	j.method = "POST";
	j.path = job_str(j, channel_path(sc.channel_id, "/messages"));
	j.body = cast([]u8) job_str(j, sc.body);
	j.content_type = "application/json";
	j.context_b64 = job_str(j, sc.context_b64);
	headers := captcha_headers(sc.captcha, key);
	j.extra = NewArray(headers.count, http.Header,, job_alloc(j));
	for headers j.extra[it_index] = .{job_str(j, it.name), job_str(j, it.value)};
	j.retries = 3;
	j.retry_429 = 3;
	j.result = .{op = .Send_Message, channel_id = sc.channel_id, nonce = sc.nonce, tag = sc.tag};
	job_submit(c, j);
	send_captcha_drop(c, false);
}

// send_captcha_cancel: the captcha was closed unsolved (or couldn't be shown): the send fails.
send_captcha_cancel :: (c: *Client) {
	if !c.send_captcha.nonce return;
	analytics_captcha_dismissed(c);
	send_captcha_drop(c, true);
}

// ---- telemetry (the modal's CaptchaModal and its captcha component) ----

// analytics_captcha_opened: the modal mounted. The captcha component's effect runs first
// (captcha_event "initial-load"), then the modal's: open_modal "Guild Join Captcha" (the cancel hook's
// default analyticsType) and open_modal "Captcha Modal".
analytics_captcha_opened :: (c: *Client, ch: Captcha) {
	analytics_captcha_event(c, ch, "initial-load");
	for string.["Guild Join Captcha", "Captcha Modal"] {
		w := aw_begin();
		json_kstr(*w, "type", it);
		aw_track(c, "open_modal", *w);
	}
}

// analytics_captcha_event: captcha_event {captcha_event_name, captcha_service, sitekey,
// captcha_flow_key}; the flow key is a fresh UUID on each of the component's renders.
analytics_captcha_event :: (c: *Client, ch: Captcha, name: string) {
	w := aw_begin();
	json_kstr(*w, "captcha_event_name", name);
	json_kstr(*w, "captcha_service", CAPTCHA_SERVICE_NAMES[ch.service]);
	json_kstr(*w, "sitekey", ch.sitekey);
	json_kstr(*w, "captcha_flow_key", uuid4(,, temp));
	aw_track(c, "captcha_event", *w);
}

// analytics_captcha_dismissed: the modal closed without a solution.
analytics_captcha_dismissed :: (c: *Client) {
	w := aw_begin();
	json_kstr(*w, "type", "Guild Join Captcha");
	aw_track(c, "modal_dismissed", *w);
}

#scope_file

send_captcha_drop :: (c: *Client, failed: bool) {
	sc := *c.send_captcha;
	if failed {
		send_failed(*c.store, sc.channel_id, sc.nonce);
		array_add(*c.results, .{op = .Send_Message, status = 400, captcha = true, channel_id = sc.channel_id, nonce = sc.nonce, tag = sc.tag});
		c.store.changed += 1;
	}
	free_str(sc.body, c.allocator);
	free_str(sc.context_b64, c.allocator);
	captcha_free(*sc.captcha, c.allocator);
	sc.* = .{};
}
