// Logging in and out like the official client (AuthenticationActionCreators,
// AuthenticationStore, the login page). The same Client serves the whole
// session, as the official renderer does: the launch ids, the analytics event
// sequence and the connections survive a logout and the next login.
//
// Logged out (no token): no gateway, no heartbeat session (the super
// properties drop client_heartbeat_session_id), X-Fingerprint on API requests
// once /experiments returned one, Referer the login page, /science batches
// with "token": null. The login page loads GET /auth/location-metadata, opens
// the remote auth gateway (QR code, remote_auth.jai) and tracks login_viewed.
// Fixture: traffic/account_edits.jsonl, windows logout and login_submit; the
// rest is from the bundle (traffic/CLIENT_RULES.md "Login and logout").

Mfa_Method :: enum_flags u8 {
	Webauthn;
	Totp;
	Backup;
	Sms;
}

Auth_Event_Kind :: enum u8 {
	Logged_In; // token: the client is connecting; the app persists the token
	Login_Failed; // field errors / message / captcha
	Mfa_Required; // methods
	Mfa_Failed; // message
	Sms_Sent; // phone
	Forgot_Sent; // login: where the instructions went; one_time_login: a login link instead
	Forgot_Failed; // field errors / message
	Logged_Out; // the logout finished: show the login page
}

// Auth_Event strings are in the temp allocator of the frame that took them.
Auth_Event :: struct {
	kind: Auth_Event_Kind;
	captcha: bool; // Discord asked for a captcha (never solved here)
	login_error: string; // under EMAIL OR PHONE NUMBER
	password_error: string; // under PASSWORD
	message: string; // anything else
	methods: Mfa_Method;
	phone: string;
	login: string;
	one_time_login: bool;
	token: string;
}

Auth_Action :: enum u64 {
	None;
	Experiments;
	Location_Metadata;
	Login;
	Mfa;
	Sms_Send;
	Forgot;
	Logout;
	Remote_Token;
	Survey;
	Quests;
	Promotions;
}

Auth :: struct {
	mu: locks.Mutex; // token (Client.token), logged_out, fingerprint, referer
	logged_out: bool;
	fingerprint: string; // AuthenticationStore fingerprint (persisted as <state>/fingerprint)
	referer: string; // the login page while logged out
	login_session: bool; // logged in from the login page: the login burst replaces the launch tables
	// UI thread
	country_code: string; // location-metadata (phone numbers get its dialing code)
	screen_at: s64; // login page loads due (0 = none)
	screen_cold: bool;
	logout_batch_token: string; // analytics token of the events queued before LOGOUT
	logout_source: string;
	mfa_ticket: string;
	login_instance_id: string;
	mfa_kind: Mfa_Method;
	events: [..]Auth_Event; // pushed and taken on the UI thread
	arena: Flat_Pool; // event strings until taken
	ra: Remote_Auth;
	gw_stoppers: [..]*Thread; // logouts' gateway teardowns (joined by auth_shutdown)
}

// client_logged_out: no token (the login page is showing).
client_logged_out :: (c: *Client) -> bool {
	locks.lock(*c.auth.mu);
	defer locks.unlock(*c.auth.mu);
	return c.auth.logged_out;
}

// client_token: the current token (temp copy; "" while logged out). Worker threads read it per request.
client_token :: (c: *Client, allocator := temp) -> string {
	locks.lock(*c.auth.mu);
	defer locks.unlock(*c.auth.mu);
	return copy_string(c.token,, allocator);
}

// auth_fingerprint: the X-Fingerprint value ("" when none).
auth_fingerprint :: (c: *Client, allocator := temp) -> string {
	locks.lock(*c.auth.mu);
	defer locks.unlock(*c.auth.mu);
	return copy_string(c.auth.fingerprint,, allocator);
}

// auth_referer: the login page while logged out, else "".
auth_referer :: (c: *Client, allocator := temp) -> string {
	locks.lock(*c.auth.mu);
	defer locks.unlock(*c.auth.mu);
	return ifx c.auth.logged_out then copy_string(c.auth.referer,, allocator) else "";
}

auth_init :: (c: *Client) {
	a := *c.auth;
	a.events.allocator = c.allocator;
	a.gw_stoppers.allocator = c.allocator;
	a.logged_out = !c.token;
	if !a.logged_out return;
	if c.cfg.state_dir {
		data, ok := read_entire_file(state_path(c, "fingerprint"), log_errors = false,, temp);
		if ok a.fingerprint = copy_string(trim(data),, c.allocator);
	}
	// a cold start without a token: /app redirects to the login page (guess, not captured)
	a.referer = copy_string(#run join(API_ORIGIN, "/login?redirect_to=%2Fapp"),, c.allocator);
	identity_set_logged_out(*c.id, true);
}

// auth_shutdown (client_destroy, before the workers stop): the QR socket and a logout's gateway teardown.
auth_shutdown :: (c: *Client) {
	remote_auth_stop(c);
	for c.auth.gw_stoppers locks.join(it);
	c.auth.gw_stoppers.count = 0;
}

auth_destroy :: (c: *Client) {
	using a := *c.auth;
	remote_auth_destroy(c);
	array_free(gw_stoppers);
	array_free(events);
	fini(*arena);
	push_allocator(c.allocator);
	free(fingerprint);
	free(referer);
	free(country_code);
	free(logout_batch_token);
	free(logout_source);
	free(mfa_ticket);
	free(login_instance_id);
}

// auth_cold_start: client_start of a client without a token. The
// AuthenticationStore fetches /experiments at once (with the persisted
// fingerprint), and the login page renders.
auth_cold_start :: (c: *Client) {
	schedule_app_load(c);
	auth_fetch_experiments(c, "/app", #run join(API_ORIGIN, "/app"));
	c.auth.screen_at = now_ms();
	c.auth.screen_cold = true;
}

// auth_tick (client_poll, UI thread): the login page's loads when they are due.
auth_tick :: (c: *Client, now: s64) {
	a := *c.auth;
	if a.screen_at == 0 || now < a.screen_at return;
	a.screen_at = 0;
	if client_logged_out(c) auth_login_page_loads(c);
}

// The login page's mount (LoginPage useEffect): login_viewed (flushed at
// once), location metadata, and the QR code socket.
auth_login_page_loads :: (c: *Client) {
	j := job_new(.Api, .Auth);
	j.method = "GET";
	j.path = "/auth/location-metadata";
	j.retries = 2;
	j.no_auth = true;
	j.result.tag = xx Auth_Action.Location_Metadata;
	job_submit(c, j);
	remote_auth_start(c);
	analytics_login_viewed(c);
	analytics_flush(c, now_ms(), force = true);
}

// auth_fetch_experiments: AuthenticationStore's logged-out /experiments
// (X-Fingerprint when one is stored; context location = the page's path).
auth_fetch_experiments :: (c: *Client, path: string, referer: string) {
	j := job_new(.Api, .Auth);
	j.method = "GET";
	j.path = "/experiments?with_guild_experiments=true";
	j.retries = 3;
	j.no_auth = true;
	j.context_b64 = job_str(j, context_location(path));
	j.referer = job_str(j, referer);
	j.result.tag = xx Auth_Action.Experiments;
	job_submit(c, j);
}

// ---- password login ----

// auth_login_value: the login field as sent: digits, spaces, dashes and
// parentheses (3+ characters) are a phone number and get the country's dialing
// code (location-metadata, else the United States).
auth_login_value :: (c: *Client, login: string, allocator := temp) -> string {
	if !auth_is_phone(login) return copy_string(login,, allocator);
	return join(auth_dialing_code(c.auth.country_code), login,, allocator);
}

auth_is_phone :: (login: string) -> bool {
	if login.count < 3 return false;
	for cast([]u8) login if !is_digit(it) && !contains("-() ", it) return false;
	return true;
}

auth_dialing_code :: (country: string) -> string {
	cc := ifx country then country else "US";
	for split(DIALING_CODES, ",",, temp) if it.count > 2 && begins_with(it, cc) return advance(it, 2);
	return "+1";
}

// auth_login: POST /auth/login. The password bytes are copied into the request
// body only, and that body is zeroed once the request finished.
auth_login :: (c: *Client, login: string, password: []u8) {
	w: Json;
	json_init(*w);
	json_obj(*w);
	json_kstr(*w, "login", auth_login_value(c, login));
	json_kstr(*w, "password", cast(string) password);
	json_kbool(*w, "undelete", false);
	json_knull(*w, "login_source");
	json_knull(*w, "gift_code_sku_id");
	json_obj_end(*w);
	auth_login_dispatched(c);
	j := auth_job(c, "/auth/login", w.buf, .Login, retries = 2);
	crypto.zero(w.buf);
	j.on_done = (c: *Client, j: *Job, status: int) { crypto.zero(cast([]u8) j.body); };
	job_submit(c, j);
}

mfa_kind_name :: (m: Mfa_Method) -> string {
	if m == .Backup return "backup";
	if m == .Sms return "sms";
	return "totp";
}

// auth_mfa: POST /auth/mfa/{totp|backup|sms} with the ticket of the login.
auth_mfa :: (c: *Client, method: Mfa_Method, code: string) {
	a := *c.auth;
	w: Json;
	json_init(*w);
	json_obj(*w);
	json_kstr(*w, "code", ifx method == .Backup then replace(code, "-", "",, temp) else code);
	json_kstr(*w, "ticket", a.mfa_ticket);
	json_knull(*w, "login_source");
	json_knull(*w, "gift_code_sku_id");
	if a.login_instance_id json_kstr(*w, "login_instance_id", a.login_instance_id);
	json_obj_end(*w);
	a.mfa_kind = method;
	auth_login_dispatched(c);
	job_submit(c, auth_job(c, tprint("/auth/mfa/%", mfa_kind_name(method)), w.buf, .Mfa, retries = 2));
}

// LOGIN: from here until CONNECTION_OPEN events carry no client_uuid (fixture
// login_submit: network_action_user_login has none, login_viewed before it has one).
auth_login_dispatched :: (c: *Client) {
	locks.lock(*c.analytics.mu);
	c.analytics.user_id = 0;
	locks.unlock(*c.analytics.mu);
}

// auth_mfa_sms_send: the SMS slide's POST /auth/mfa/sms/send {"ticket"} (on open and on "Resend SMS?").
auth_mfa_sms_send :: (c: *Client) {
	w: Json;
	json_init(*w);
	json_obj(*w);
	json_kstr(*w, "ticket", c.auth.mfa_ticket);
	json_obj_end(*w);
	job_submit(c, auth_job(c, "/auth/mfa/sms/send", w.buf, .Sms_Send));
}

// auth_forgot: "Forgot your password?" POST /auth/forgot {"login"}.
auth_forgot :: (c: *Client, login: string) {
	w: Json;
	json_init(*w);
	json_obj(*w);
	json_kstr(*w, "login", auth_login_value(c, login));
	json_obj_end(*w);
	job_submit(c, auth_job(c, "/auth/forgot", w.buf, .Forgot));
}

// auth_login_reset: the MFA step's close / "Go back" (LOGIN_RESET, no request).
auth_login_reset :: (c: *Client) {
	a := *c.auth;
	free_str(a.mfa_ticket, c.allocator);
	free_str(a.login_instance_id, c.allocator);
	a.mfa_ticket = "";
	a.login_instance_id = "";
}

auth_job :: (c: *Client, path: string, body: []u8, action: Auth_Action, retries := 0) -> *Job {
	j := job_new(.Api, .Auth);
	j.method = "POST";
	j.path = job_str(j, path);
	j.body = array_copy(body,, job_alloc(j));
	j.content_type = "application/json";
	j.retries = retries;
	j.no_auth = true;
	j.result.tag = xx action;
	return j;
}

// ---- log out ----

// client_logout: POST /auth/logout, then LOGOUT (auth_apply). source is the
// logout_source ("settings" from User Settings > Log Out;
// "multi_accounts_list" from the account switcher, which also tracks
// multi_account_account_remove).
client_logout :: (c: *Client, source: string) {
	a := *c.auth;
	free_str(a.logout_source, c.allocator);
	a.logout_source = copy_string(source,, c.allocator);
	j := auth_job(c, "/auth/logout", cast([]u8) "{\"provider\":null,\"voip_provider\":null}", .Logout);
	j.no_auth = false;
	job_submit(c, j);
	if source == "multi_accounts_list" analytics_multi_account_remove(c);
}

// ---- results (client_poll, UI thread) ----

auth_apply :: (c: *Client, e: *Event) {
	a := *c.auth;
	r := *e.result;
	body := vmap(e.data);
	if cast(Auth_Action) r.tag == {
		case .Experiments;
			inst := fstr(body, "installation");
			if inst {
				locks.lock(*c.id.mu);
				if !c.id.installation_id c.id.installation_id = copy_string(inst,, c.allocator);
				locks.unlock(*c.id.mu);
			}
			fp := fstr(body, "fingerprint");
			if fp && client_logged_out(c) auth_set_fingerprint(c, fp);
		case .Location_Metadata;
			if r.ok {
				free_str(a.country_code, c.allocator);
				a.country_code = copy_string(fstr(body, "country_code"),, c.allocator);
			}
		case .Login;
			analytics_network_action(c, "network_action_user_login", r.status, body, "/auth/login", "post");
			auth_login_result(c, r.status, body, false);
		case .Mfa;
			analytics_network_action(c, "network_action_user_login_mfa", r.status, body, tprint("/auth/mfa/%", mfa_kind_name(a.mfa_kind)), "post");
			auth_login_result(c, r.status, body, true);
		case .Sms_Send;
			ev := Auth_Event.{kind = .Sms_Sent, phone = fstr(body, "phone")};
			if !r.ok ev.message = auth_message(r.status, body);
			auth_push(c, ev);
		case .Forgot;
			analytics_network_action(c, "network_action_forgot_password", r.status, body, "/auth/forgot", "post");
			if r.ok {
				auth_push(c, .{kind = .Forgot_Sent, one_time_login = fstr(body, "method") == "one_time_login"});
			} else {
				ev := Auth_Event.{kind = .Forgot_Failed};
				auth_form_errors(*ev, r.status, body);
				auth_push(c, ev);
			}
		case .Logout;
			auth_after_logout(c, r.status, body);
		case .Remote_Token;
			token := fstr(body, "token");
			client_login_token(c, token);
			analytics_login_successful_qr(c, fstr(body, "fingerprint"));
			auth_push(c, .{kind = .Logged_In, token = token});
		case .Survey;
			analytics_survey_fetch(c, r.status, body);
		case .Quests;
			locks.lock(*c.job_mu);
			ready := c.ready_ms;
			locks.unlock(*c.job_mu);
			schedule_applications_public(c, ready);
		case .Promotions;
			api_get_later(c, "/users/@me/applications/521842831262875670/entitlements?exclude_consumed=false", 0);
	}
}

auth_login_result :: (c: *Client, status: int, body: etf.Map, mfa_step: bool) {
	a := *c.auth;
	if status >= 200 && status < 300 {
		if !mfa_step && fbool(body, "mfa") {
			free_str(a.mfa_ticket, c.allocator);
			free_str(a.login_instance_id, c.allocator);
			a.mfa_ticket = copy_string(fstr(body, "ticket"),, c.allocator);
			a.login_instance_id = copy_string(fstr(body, "login_instance_id"),, c.allocator);
			m: Mfa_Method;
			if fstr(body, "webauthn") m |= .Webauthn;
			if fbool(body, "totp") m |= .Totp;
			if fbool(body, "backup") m |= .Backup;
			if fbool(body, "sms") m |= .Sms;
			auth_push(c, .{kind = .Mfa_Required, methods = m});
			return;
		}
		token := fstr(body, "token");
		if token {
			auth_login_reset(c);
			client_login_token(c, token);
			auth_push(c, .{kind = .Logged_In, token = token});
			return;
		}
	}
	ev := Auth_Event.{kind = ifx mfa_step then .Mfa_Failed else .Login_Failed};
	auth_form_errors(*ev, status, body);
	auth_push(c, ev);
}

// auth_form_errors: the form's field errors (oldFormErrors), the captcha
// request, or the response's message.
auth_form_errors :: (ev: *Auth_Event, status: int, body: etf.Map) {
	if vhas(body, "captcha_key") {
		ev.captcha = true;
		return;
	}
	first :: (body: etf.Map, k: string) -> string {
		// {"errors":{"login":{"_errors":[{"message":..}]}}} or the old {"login":["..."]}
		errs := fmap(body, "errors");
		if errs {
			l := flist(fmap(errs, k), "_errors");
			if l return fstr(vmap(l[0]), "message");
		}
		l := flist(body, k);
		return ifx l then vstr(l[0]) else "";
	}
	ev.login_error = first(body, "login");
	if !ev.login_error ev.login_error = first(body, "email");
	ev.password_error = first(body, "password");
	if !ev.login_error && !ev.password_error ev.message = auth_message(status, body);
}

auth_message :: (status: int, body: etf.Map) -> string {
	if status == 0 return "Couldn't reach Discord. Check your connection and try again.";
	m := fstr(body, "message");
	return ifx m then m else "Something went wrong. Please try again.";
}

auth_push :: (c: *Client, ev: Auth_Event) {
	push_allocator(pool_allocator(*c.auth.arena));
	e := ev;
	e.login_error = copy_string(ev.login_error);
	e.password_error = copy_string(ev.password_error);
	e.message = copy_string(ev.message);
	e.phone = copy_string(ev.phone);
	e.login = copy_string(ev.login);
	e.token = copy_string(ev.token);
	array_add(*c.auth.events, e);
}

// auth_take_events: login-page results since the last call (UI thread; temp allocator).
auth_take_events :: (c: *Client) -> []Auth_Event {
	a := *c.auth;
	if !a.events return .[];
	out := NewArray(a.events.count, Auth_Event,, temp);
	for e, i: a.events {
		push_allocator(temp);
		out[i] = e;
		out[i].login_error = copy_string(e.login_error);
		out[i].password_error = copy_string(e.password_error);
		out[i].message = copy_string(e.message);
		out[i].phone = copy_string(e.phone);
		out[i].login = copy_string(e.login);
		out[i].token = copy_string(e.token);
		crypto.zero(cast([]u8) e.token);
	}
	a.events.count = 0;
	reset(*a.arena);
	return out;
}

// auth_push_token (remote auth thread): the decrypted token, applied on the UI thread.
auth_push_token :: (c: *Client, token: string, fingerprint: string, action: Auth_Action) {
	pool := New(Flat_Pool);
	push_allocator(pool_allocator(pool));
	m := etf.map_builder(2);
	etf.map_put(*m, "token", etf.vstring(copy_string(token)));
	etf.map_put(*m, "fingerprint", etf.vstring(copy_string(fingerprint)));
	ev := Event.{kind = .Rest, data = etf.vmap(etf.map_done(*m)), arena = pool};
	ev.result = .{op = .Auth, ok = true, status = 200, tag = xx action};
	client_push_event(c, ev);
}

// FINGERPRINT: the first fingerprint of a logged-out session is stored and
// tracked (user_fingerprint_changed; old_fingerprint is null after a logout:
// LOGOUT and LOGIN_SUCCESS both forget it).
auth_set_fingerprint :: (c: *Client, fp: string) {
	a := *c.auth;
	locks.lock(*a.mu);
	old := a.fingerprint;
	if !old a.fingerprint = copy_string(fp,, c.allocator);
	locks.unlock(*a.mu);
	if !old {
		analytics_fingerprint_changed(c, fp);
		if c.cfg.state_dir write_file_atomic(state_path(c, "fingerprint"), cast([]u8) fp);
	} else if old != fp {
		analytics_external_fingerprint_dropped(c, old, fp);
	}
}

auth_forget_fingerprint :: (c: *Client) {
	a := *c.auth;
	locks.lock(*a.mu);
	free_str(a.fingerprint, c.allocator);
	a.fingerprint = "";
	locks.unlock(*a.mu);
	if c.cfg.state_dir file_delete(state_path(c, "fingerprint"));
}

// LOGOUT after POST /auth/logout settled (.finally): the network action and
// the voice panel hotspot (VOICE_CHANNEL_SELECT null) are tracked while still
// logged in; then the token and the heartbeat session go, the gateway closes,
// /experiments is fetched from the old route and the login page renders.
auth_after_logout :: (c: *Client, status: int, body: etf.Map) {
	a := *c.auth;
	src := ifx a.logout_source then a.logout_source else "settings";
	analytics_network_action(c, "network_action_user_logout", status, body, "/auth/logout", "post", "logout_source", src);
	analytics_hotspot_hidden(c, "VOICE_PANEL_INTRODUCTION");
	locks.lock(*c.route_mu);
	g, ch := c.route_guild, c.route_channel;
	locks.unlock(*c.route_mu);
	old_referer := referer_for_route(g, ch);
	old_path := advance(old_referer, API_ORIGIN.count);
	// the batch holding the events above goes out with the old analytics token
	free_str(a.logout_batch_token, c.allocator);
	a.logout_batch_token = copy_string(c.store.analytics_token,, c.allocator);
	locks.lock(*a.mu);
	free_str(c.token, c.allocator);
	c.token = "";
	a.logged_out = true;
	a.login_session = false;
	free_str(a.referer, c.allocator);
	a.referer = join(API_ORIGIN, "/login?redirect_to=", uri_component(old_path),, c.allocator);
	locks.unlock(*a.mu);
	identity_set_logged_out(*c.id, true);
	if c.gw {
		gw := c.gw;
		c.gw = null;
		if c.cfg.gateway_sink gateway_stop(gw);
		else array_add(*a.gw_stoppers, spawn(gw, gateway_stop));
	}
	auth_fetch_experiments(c, old_path, old_referer);
	// Components still mounted on the old route refetch without a token (and get
	// 401): Home's referral eligibility (three times) and, from the login page,
	// the frecency settings (fixture logout).
	if g == 0 for 1..3 {
		j := job_new(.Api, .Auth);
		j.method = "GET";
		j.path = "/users/@me/referrals/eligibility";
		j.no_auth = true;
		j.referer = job_str(j, old_referer);
		job_submit(c, j);
	}
	sp := job_new(.Api, .Auth);
	sp.method = "GET";
	sp.path = "/users/@me/settings-proto/2";
	sp.no_auth = true;
	sp.not_before = now_ms() + 15;
	job_submit(c, sp);
	store_destroy(*c.store);
	store_init(*c.store, c.allocator);
	c.store.changed += 1;
	a.screen_at = now_ms() + 300; // the login route's chunk loads, then the page mounts
	a.screen_cold = false;
	auth_push(c, .{kind = .Logged_Out});
}

// client_login_token: LOGIN_SUCCESS. The fingerprint is forgotten, the QR
// socket closes, and the gateway connects at once (no fast connect) with a
// fresh session: the login burst follows READY (auth_on_ready).
client_login_token :: (c: *Client, token: string) {
	a := *c.auth;
	locks.lock(*a.mu);
	free_str(c.token, c.allocator);
	c.token = copy_string(token,, c.allocator);
	a.logged_out = false;
	a.login_session = true;
	locks.unlock(*a.mu);
	auth_forget_fingerprint(c);
	remote_auth_request_stop(c);
	client_session_reset(c);
	identity_set_logged_out(*c.id, false, now_ms());
	// localStorage was cleared by the logout: the obfuscation capability bit is gone (fixture login_submit)
	c.id.platform.capabilities = 1734653;
	c.cfg.fast_connect = false;
	c.cfg.ws_open_delay_ms = -1;
	locks.lock(*c.route_mu);
	c.route_guild, c.route_channel = 0, 0;
	locks.unlock(*c.route_mu);
	c.start_route_guild, c.start_route_channel = 0, 0;
	if !c.gw && !c.cfg.disable_gateway {
		c.gw = gateway_create(c);
		if !c.cfg.gateway_sink {
			gateway_set_active(c.gw, qos_from_state(c.focused, false));
			gateway_start(c.gw);
		}
	}
}

// client_session_reset: what a new login starts without (the official stores reset on LOGOUT).
client_session_reset :: (c: *Client) {
	locks.lock(*c.job_mu);
	c.ready_ms = 0;
	c.ready_subscribed_guild = 0;
	c.rtc_probe_at = 0;
	locks.unlock(*c.job_mu);
	c.pending_guild_open = 0;
	c.guild_open_promotions = false;
	c.pending_private_open = 0;
	c.route_page_pending = false;
	table_reset(*c.started_guilds);
	table_reset(*c.left_guilds);
	table_reset(*c.command_index_guilds);
	table_reset(*c.members_requested);
	c.command_index_user = false;
	c.emoji_picker_opened = false;
	c.home_opened = false;
	c.session_guild_set_done = false;
	c.account_popout_opened = false;
	c.soundboard_loaded = false;
	subscriptions_clear(c);
	c.subs.pending.count = 0;
	c.pending_acks.count = 0;
	locks.lock(*c.ack_mu);
	free_str(c.ack_token, c.allocator);
	c.ack_token = "";
	locks.unlock(*c.ack_mu);
	locks.lock(*c.analytics.mu);
	c.analytics.user_id = 0;
	locks.unlock(*c.analytics.mu);
	store_destroy(*c.store);
	store_init(*c.store, c.allocator);
	c.store.changed += 1;
}

// ---- after READY of a login from the login page ----

Login_Burst_Entry :: struct {
	at_ms: s64; // after READY
	method: string;
	path: string;
	referer: string; // "" = the route (/channels/@me)
	ctx: string;
	action: Auth_Action;
}

// The login_submit fixture: the app renders on /app (survey, guild affinities,
// webauthn credentials), then on /channels/@me (Friends). Detectables, the
// detectable exclusions and config_0 are not fetched again in the session.
LOGIN_BURST :: Login_Burst_Entry.[
	.{0, "GET", "/users/@me/survey?disable_auto_seen=true", #run join(API_ORIGIN, "/app"), "", .Survey},
	.{0, "WEB", "/api/v2/scheduled-maintenances/upcoming.json", "", "", .None},
	.{0, "GET", "/users/@me/affinities/guilds", #run join(API_ORIGIN, "/app"), "", .None},
	.{0, "GET", "/users/@me/mfa/webauthn/credentials", #run join(API_ORIGIN, "/app"), "", .None},
	.{0, "GET", "/users/@me/referrals/eligibility", "", "", .None},
	.{0, "GET", "/users/@me/entitlements?with_sku=false&with_application=false&entitlement_type=11&exclude_ended=true", "", "", .None},
	.{0, "GET", "/users/@me/applications/521842831262875670/entitlements?exclude_consumed=true", "", "", .None},
	.{0, "GET", "/quests/@me", "", "", .Quests},
	.{0, "GET", "/users/%40me/badges", "", "", .None},
	.{1, "GET", "/users/@me/affinities/v2/users", "", "", .None},
	.{1, "GET", "/promotions?locale={locale}&platform=0", "", "", .Promotions},
	.{1, "GET", "/quests/decision?placement=1&client_heartbeat_session_id={hb}&client_ad_session_id={ad}{visible}", "", "{\"connection_type\":\"unknown\"}", .None},
	.{2081, "GET", "/users/@me/library?country_code={country}", "", "", .None},
	.{2081, "GET", "/users/@me/saved-messages?bookmark_ids=true", "", "", .None},
	.{2081, "GET", "/partner-sdk/storefront-config", "", "", .None},
	.{2081, "POST", "/users/@me/billing/user-offer", "", "", .None},
	.{2081, "GET", "/users/@me/billing/checkout-recovery", "", "", .None},
	.{2081, "GET", "/users/@me/collectibles-marketing?platform=0", "", "", .None},
	.{7774, "GET", "/quests/get-decisions?placement=3&num_decisions_requested=1&client_heartbeat_session_id={hb}&client_ad_session_id={ad}", "", "{\"connection_type\":\"unknown\"}", .None}
];

// auth_on_ready (client_on_ready): a login session's READY-anchored loads.
auth_on_ready :: (c: *Client, ready: s64) -> bool {
	locks.lock(*c.auth.mu);
	login := c.auth.login_session;
	locks.unlock(*c.auth.mu);
	if !login return false;
	for e: LOGIN_BURST {
		j: *Job;
		if e.method == "WEB" {
			j = job_new(.Web, .Startup);
			j.method = "GET";
			j.host = "status.discord.com";
			j.site = .Same_Site;
		} else {
			j = job_new(.Api, ifx e.action != .None then .Auth else .Startup);
			j.method = e.method;
			if e.method == "POST" {
				j.body = cast([]u8) job_str(j, "{\"allow_triggers\":true}");
				j.content_type = "application/json";
			}
			if e.ctx j.context_b64 = job_str(j, context_b64(e.ctx));
			if e.referer j.referer = job_str(j, e.referer);
			j.result.tag = xx e.action;
		}
		path := e.path;
		if contains(path, "{visible}") {
			// the guilds in the sidebar, in its order (folders after the unlisted ones)
			sb: String_Builder;
			sb.allocator = temp;
			for sidebar_guild_ids(*c.store) print_to_builder(*sb, "&visible_guild_ids=%", it);
			path = replace(path, "{visible}", builder_to_string(*sb,, temp),, temp);
		}
		j.path = job_str(j, startup_expand(c, path));
		j.not_before = ready + e.at_ms;
		if begins_with(e.path, "/users/@me/billing/user-offer") analytics_schedule(c, j.not_before, "fetch_user_offer_started", "\"call_location\":\"PremiumManager\"");
		job_submit(c, j);
	}
	return true;
}

// sidebar_guild_ids: guilds missing from the folders first (READY order), then the folders' guilds (temp).
sidebar_guild_ids :: (s: *Store) -> []Snowflake {
	push_allocator(temp);
	out: [..]Snowflake;
	listed: Table(Snowflake, bool);
	for f: s.settings.guild_folders for f.guild_ids table_set(*listed, it, true);
	for s.guild_order if !table_contains(*listed, it) array_add(*out, it);
	for f: s.settings.guild_folders for f.guild_ids if table_contains(*s.guilds, it) array_add(*out, it);
	return out;
}

// Dialing codes by country (the client's country list; the first code of each).
DIALING_CODES :: "AF+93,AX+358,AL+355,DZ+213,AS+1,AD+376,AO+244,AI+1,AQ+672,AG+1,AR+54,AM+374,AW+297,AC+247,AU+61,AT+43,AZ+994,BS+1,BH+973,BD+880,BB+1,BY+375,BE+32,BZ+501,BJ+229,BM+1,BT+975,BO+591,BQ+599,BA+387,BW+267,BV+55,BR+55,IO+246,BN+673,BG+359,BF+226,BI+257,KH+855,CM+237,CA+1,CV+238,KY+1,CF+236,TD+235,CL+56,CN+86,CX+61,CC+61,CO+57,KM+269,CG+242,CD+243,CK+682,CR+506,CI+225,HR+385,CU+53,CW+599,CY+357,CZ+420,DK+45,DG+246,DJ+253,DM+1,DO+1,EC+593,EG+20,SV+503,GQ+240,ER+291,EE+372,ET+251,FK+500,FO+298,FJ+679,FI+358,FR+33,GF+594,PF+689,TF+262,GA+241,GM+220,GE+995,DE+49,GH+233,GI+350,GR+30,GL+299,GD+1,GP+590,GU+1,GT+502,GG+44,GN+224,GW+245,GY+592,HT+509,HM+672,VA+39,HN+504,HK+852,HU+36,IS+354,IN+91,ID+62,IR+98,IQ+964,IE+353,IM+44,IL+972,IT+39,JM+1,JP+81,JE+44,JO+962,KZ+7,KE+254,KI+686,XK+383,KP+850,KR+82,KW+965,KG+996,LA+856,LV+371,LB+961,LS+266,LR+231,LY+218,LI+423,LT+370,LU+352,MO+853,MK+389,MG+261,MW+265,MY+60,MV+960,ML+223,MT+356,MH+692,MQ+596,MR+222,MU+230,YT+262,MX+52,FM+691,MI+1,MD+373,MC+377,MN+976,ME+382,MS+1664,MA+212,MZ+258,MM+95,NA+264,NR+674,NP+977,NL+31,AN+599,NC+687,NZ+64,NI+505,NE+227,NG+234,NU+683,NF+672,MP+1,NO+47,OM+968,PK+92,PW+680,PS+970,PA+507,PG+675,PY+595,PE+51,PH+63,PN+64,PL+48,PT+351,PR+1,QA+974,RE+262,RO+40,RU+7,RW+250,BL+590,SH+290,KN+1,LC+1,MF+590,PM+508,VC+1,WS+685,SM+378,ST+239,SA+966,SN+221,RS+381,SC+248,SL+232,SG+65,SX+1,SK+421,SI+386,SB+677,SO+252,ZA+27,GS+500,SS+211,ES+34,LK+94,SD+249,SR+597,SJ+47,SZ+268,SE+46,CH+41,SY+963,TW+886,TJ+992,TZ+255,TH+66,TL+670,TG+228,TK+690,TO+676,TT+1,TN+216,TR+90,TM+993,TC+1,TV+688,UG+256,UA+380,AE+971,GB+44,US+1,UM+1,UY+598,UZ+998,VU+678,VE+58,VN+84,VG+1,VI+1,WF+681,EH+212,YE+967,ZM+260,ZW+263";
