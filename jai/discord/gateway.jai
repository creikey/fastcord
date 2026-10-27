// Gateway reproduces GatewaySocket from the official client:
//   - URL: <resume_gateway_url or wss://gateway.discord.gg>/?encoding=etf&v=9&compress=zstd-stream
//   - first connection behaves like fast-connect.js: IDENTIFY is sent as soon
//     as the socket opens (before HELLO) with the fast-connect property set;
//     later connections send RESUME/IDENTIFY on open (_doResumeOrIdentify).
//   - HELLO: first heartbeat after floor(random()*interval), then every
//     interval; a tick that finds the previous heartbeat un-acked closes
//     with 4000 and reconnects through the backoff.
//   - heartbeats are op 40 {seq, qos:{active,ver:31,reasons}} with the QoS
//     payload consumed per send (handleActiveStateChange semantics).
//   - after every received message, a heartbeat is sent if the last one is
//     older than interval + 5 s (_sendHeartbeatIfDue).
//   - READY: op 4 (voice state reset), op 41 (time-spent session), heartbeat.
//   - close: 4004 stops; otherwise Backoff(1 s, 60 s) with jitter; after more
//     than 4 consecutive failures the session is reset (fresh IDENTIFY).
//   - RESUME only if a session exists and the last ACK is ≤ 3 min old.
//   - op 7 reconnects immediately; op 9 resumes (d=true) or identifies.
//   - HELLO must arrive within 30 s.

GATEWAY_DEFAULT_URL :: "wss://gateway.discord.gg";
GATEWAY_QUERY :: "/?encoding=etf&v=9&compress=zstd-stream";

Op :: enum s64 {
	Dispatch :: 0;
	Heartbeat :: 1;
	Identify :: 2;
	Presence_Update :: 3;
	Voice_State_Update :: 4;
	Resume :: 6;
	Reconnect :: 7;
	Request_Guild_Members :: 8;
	Invalid_Session :: 9;
	Hello :: 10;
	Heartbeat_Ack :: 11;
	Call_Connect :: 13;
	Guild_Subscriptions :: 14;
	Request_Soundboard_Sounds :: 31;
	Request_Last_Messages :: 34;
	Search_Recent_Members :: 35;
	Guild_Subscriptions_Bulk :: 37;
	Request_Channel_Member_Count :: 39;
	Qos_Heartbeat :: 40;
	Update_Time_Spent_Session_Id :: 41;
	Request_Channel_Info :: 43;
}

Qos :: struct {
	active: bool;
	reasons: [4]string; // "foregrounded", "rtc_connected"
	n: int;
}

qos_from_state :: (foregrounded: bool, rtc_connected: bool) -> Qos {
	q: Qos;
	if foregrounded {
		q.reasons[q.n] = "foregrounded";
		q.n += 1;
	}
	if rtc_connected {
		q.reasons[q.n] = "rtc_connected";
		q.n += 1;
	}
	q.active = q.n > 0;
	return q;
}

Gw_State :: enum u8 {
	Closed; // waiting for reconnect_at
	Connecting;
	Identifying;
	Resuming;
	Established;
	Stopped;
}

Gateway :: struct {
	c: *Client;
	mu: locks.Mutex;
	cond: locks.Cond;
	send_mu: locks.Mutex; // guards ws for senders
	// Frames sent from the UI thread, written by the writer thread: a socket write can block.
	out_mu: locks.Mutex;
	out_cond: locks.Cond;
	outbox: [..][]u8;
	out_stop: bool;
	writer: *thread.Thread;
	ws: *http.Ws_Conn;
	stream: netio.Stream;
	gen: int;
	state: Gw_State;
	reader: *thread.Thread;
	control: *thread.Thread;
	stop: bool;
	// session
	seq: s64;
	session_id: string;
	resume_url: string;
	fast_connect_done: bool;
	// heartbeat
	interval: s64;
	next_beat: s64; // 0 = heartbeater not running
	last_beat: s64;
	last_ack: s64;
	beat_acked: bool;
	hello_deadline: s64;
	received_hello: bool;
	qos_current: Maybe(Qos);
	qos_upcoming: Maybe(Qos);
	// reconnect
	backoff: Backoff;
	reconnect_at: s64;
	immediate: bool;
	failed_attempts: int;
	close_code: int;
	// stream decoding
	zs: zstd.Stream_Decoder;
	inflated: [..]u8;
	// what the server must see on (re)connect
	presence_status: Status;
	identified: bool; // an IDENTIFY went out in this launch
	initial_beat: bool;
	connected_once: bool;
	first_attempt: s64;
	attempt_start: s64;
	// teardown requested by the reader / timers, executed by the control thread
	pending_teardown: bool;
	pending_code: int;
	pending_gen: int;
	pending_send_close: bool;
}

gateway_create :: (c: *Client) -> *Gateway {
	g := new(Gateway);
	g.c = c;
	g.backoff = backoff_make(1000, 60000);
	g.state = .Closed;
	g.presence_status = .Online;
	g.inflated = make_dynamic(u8, 0, 0);
	g.outbox = make_dynamic([]u8, 0, 0, c.allocator);
	return g;
}

gateway_start :: (g: *Gateway) {
	g.control = thread.create_and_start_with_poly_data(g, gateway_control_proc, *g.c.ctx);
	g.writer = thread.create_and_start_with_poly_data(g, gateway_writer_proc, *g.c.ctx);
}
#scope_module

gateway_writer_proc :: (g: *Gateway) {
	locks.lock(*g.out_mu);
	while !g.out_stop {
		if len(g.outbox) == 0 {
			locks.cond_wait(*g.out_cond, *g.out_mu);
			continue;
		}
		batch := g.outbox;
		g.outbox = make_dynamic([]u8, 0, 0, g.c.allocator);
		locks.unlock(*g.out_mu);
		for b: batch {
			locks.lock(*g.send_mu);
			if g.ws != null { http.ws_send(g.ws, .Binary, b); }
			locks.unlock(*g.send_mu);
			delete(b, g.c.allocator);
		}
		delete(batch);
		locks.lock(*g.out_mu);
	}
	locks.unlock(*g.out_mu);
}
#scope_export

gateway_stop :: (g: *Gateway) {
	locks.lock(*g.mu);
	g.stop = true;
	g.state = .Stopped;
	locks.cond_broadcast(*g.cond);
	locks.unlock(*g.mu);
	gateway_close_socket(g, 1000);
	if g.control != null {
		locks.join(g.control);
	}
	// The control thread may have finished a connect after the close above, leaving a live socket
	// and reader thread behind; close and join them before the free.
	gateway_close_socket(g, 1000);
	if g.writer != null {
		locks.lock(*g.out_mu);
		g.out_stop = true;
		locks.cond_signal(*g.out_cond);
		locks.unlock(*g.out_mu);
		locks.join(g.writer);
	}
	for b: g.outbox { delete(b, g.c.allocator); }
	delete(g.outbox);
	delete(g.session_id);
	delete(g.resume_url);
	delete(g.inflated);
	free(g);
}

gateway_url :: (g: *Gateway, allocator := temp) -> string {
	base := ifx g.resume_url != "" then g.resume_url else g.c.cfg.gateway_url;
	if base == "" { base = GATEWAY_DEFAULT_URL; }
	base = strings.trim_right(base, "/");
	return strings.concatenate(string.[base, GATEWAY_QUERY], allocator);
}

// ---- sending ----

// gateway_send packs {op, d} (key order op, d) with the client's ETF layout.
gateway_send :: (g: *Gateway, op: Op, d: V) -> bool {
	if g.c.cfg.gateway_sink != null {
		g.c.cfg.gateway_sink(g.c.cfg.gateway_sink_data, op, d);
		return true;
	}
	b := etf.map_builder(2, temp);
	etf.map_put(*b, "op", to_v(cast(s64)(op)));
	etf.map_put(*b, "d", to_v(d));
	frame := etf.vmap(etf.map_done(*b));
	buf, err := etf.encode(frame, temp);
	if err != .None { return false; }
	if locks.on_ui_thread() {
		// Queued: true means accepted for sending, as a send can still fail on a dying socket.
		if atomic_load(*g.ws) == null { return false; }
		if g.c.on_gateway_send != null { g.c.on_gateway_send(g.c.observer_data, op, d); }
		if g.c.on_gateway_frame != null { g.c.on_gateway_frame(g.c.observer_data, true, frame, len(buf)); }
		locks.lock(*g.out_mu);
		append(*g.outbox, clone(buf, g.c.allocator));
		locks.cond_signal(*g.out_cond);
		locks.unlock(*g.out_mu);
		return true;
	}
	locks.lock(*g.send_mu);
	defer locks.unlock(*g.send_mu);
	if g.ws == null { return false; }
	if g.c.on_gateway_send != null { g.c.on_gateway_send(g.c.observer_data, op, d); }
	if g.c.on_gateway_frame != null { g.c.on_gateway_frame(g.c.observer_data, true, frame, len(buf)); }
	return http.ws_send(g.ws, .Binary, buf) == .None;
}
#scope_module

qos_value :: (q: Qos) -> V {
	b := etf.map_builder(3, temp);
	etf.map_put(*b, "active", to_v(q.active));
	etf.map_put(*b, "ver", to_v(cast(s64)(31)));
	reasons := make_slice(V, q.n, temp);
	for i: 0..q.n-1 { reasons[i] = to_v(q.reasons[i]); }
	etf.map_put(*b, "reasons", etf.vlist(reasons));
	return etf.vmap(etf.map_done(*b));
}

// consume_qos: returns the payload to send and promotes the upcoming state.
consume_qos_locked :: (g: *Gateway) -> Maybe(Qos) {
	cur := g.qos_current;
	{ up, ok := maybe_get(g.qos_upcoming);
	if ok { g.qos_current = some(up); } }
	g.qos_upcoming = zero(type_of(g.qos_upcoming));
	return cur;
}

send_heartbeat_locked :: (g: *Gateway) {
	q := consume_qos_locked(g);
	b := etf.map_builder(2, temp);
	etf.map_put(*b, "seq", to_v(g.seq));
	{ qq, ok := maybe_get(q);
	if ok {
		etf.map_put(*b, "qos", to_v(qos_value(qq)));
	} else {
		etf.map_put(*b, "qos", V.{});
	} }
	g.last_beat = now_ms();
	d := etf.vmap(etf.map_done(*b));
	locks.unlock(*g.mu);
	gateway_send(g, .Qos_Heartbeat, d);
	locks.lock(*g.mu);
}
#scope_export

// gateway_set_active mirrors handleActiveStateChange(K()).
gateway_set_active :: (g: *Gateway, q: Qos) {
	locks.lock(*g.mu);
	defer locks.unlock(*g.mu);
	cur, have := maybe_get(g.qos_current);
	was_inactive := !have || !cur.active;
	if !have {
		g.qos_current = some(q);
		cur = q;
	}
	if q.active {
		cur.active = true;
		for i: 0..q.n-1 {
			dup := false;
			for j: 0..cur.n-1 { if cur.reasons[j] == q.reasons[i] { dup = true; } }
			if !dup && cur.n < len(cur.reasons) {
				cur.reasons[cur.n] = q.reasons[i];
				cur.n += 1;
			}
		}
		// sorted, as [...new Set()].sort()
		for i: 1..cur.n-1 {
			{ j := i;
			while j > 0 && compare(cur.reasons[j], cur.reasons[j - 1]) < 0 {
				swap(*cur.reasons[j], *cur.reasons[j - 1]);
				j -= 1;
} }
		}
		g.qos_current = some(cur);
		if was_inactive && g.state == .Established { send_heartbeat_locked(g); }
	} else {
		g.qos_current = some(cur);
	}
	g.qos_upcoming = some(q);
}

// ---- payload builders ----

// identify_fast_connect_value: the IDENTIFY fast-connect.js sends from the
// HTML bootstrap (no presence/compress/qos_token; its own client_launch_id).
identify_fast_connect_value :: (id: *Identity, token: string, allocator := temp) -> V {
	push_allocator(allocator);
	p := id.platform;
	props := etf.map_builder(20);
	put_base_properties(*props, p, id.fast_connect_launch_id);
	etf.map_put(*props, "is_fast_connect", to_v(true));
	if id.installation_id != "" { etf.map_put(*props, "installation_id", to_v(id.installation_id)); }
	cs := etf.map_builder(1);
	etf.map_put(*cs, "guild_versions", etf.vmap(.[]));
	d := etf.map_builder(4);
	etf.map_put(*d, "token", to_v(token));
	etf.map_put(*d, "capabilities", to_v(p.capabilities));
	etf.map_put(*d, "properties", etf.vmap(etf.map_done(*props)));
	etf.map_put(*d, "client_state", etf.vmap(etf.map_done(*cs)));
	return etf.vmap(etf.map_done(*d));
}
#scope_module

put_base_properties :: (b: *etf.Map_Builder, p: Platform_Info, launch_id: string) {
	etf.map_put(b, "os", to_v(p.os));
	etf.map_put(b, "browser", to_v(p.browser));
	etf.map_put(b, "release_channel", to_v(p.release_channel));
	etf.map_put(b, "client_version", to_v(p.client_version));
	etf.map_put(b, "os_version", to_v(p.os_version));
	etf.map_put(b, "os_arch", to_v(p.os_arch));
	etf.map_put(b, "app_arch", to_v(p.app_arch));
	etf.map_put(b, "system_locale", to_v(p.system_locale));
	etf.map_put(b, "has_client_mods", to_v(false));
	etf.map_put(b, "client_launch_id", to_v(launch_id));
	etf.map_put(b, "browser_user_agent", to_v(p.browser_user_agent));
	etf.map_put(b, "browser_version", to_v(p.browser_version));
	etf.map_put(b, "os_sdk_version", to_v(p.os_sdk_version));
	etf.map_put(b, "client_build_number", to_v(p.client_build_number));
	etf.map_put(b, "native_build_number", to_v(p.native_build_number));
	etf.map_put(b, "client_event_source", V.{});
}
#scope_export

// qos_token_b64 builds QosToken{client_provided{is_active}, derived} from the
// READY qos_token (base64 DerivedQosData).
qos_token_b64 :: (ready_qos_token: string, active: bool, allocator := temp) -> string {
	derived, err := base64.decode(ready_qos_token, allocator = temp);
	w := protobuf.Writer.{buf = make_dynamic(u8, 0, 0, temp)};
	inner := protobuf.Writer.{buf = make_dynamic(u8, 0, 0, temp)};
	if active { protobuf.write_uint(*inner, 1, 1); }
	protobuf.write_bytes(*w, 1, view(inner.buf));
	if err == null && len(ready_qos_token) > 0 { protobuf.write_bytes(*w, 2, derived); }
	return base64.encode(view(w.buf), allocator = allocator);
}

// identify_value: the regular GatewaySocket._doIdentify payload (reconnects).
identify_value :: (g: *Gateway, allocator := temp) -> V {
	push_allocator(allocator);
	c := g.c;
	id := *c.id;
	now := now_ms();
	props := etf.map_builder(24);
	// {...getSuperProperties(), client_app_state, is_fast_connect:false, gateway_connect_reasons, installation_id}
	sp := super_properties_json(id, now);
	spv, perr := etf.from_json(sp);
	if perr == .None {
		// After a login from the login page the properties object IDENTIFY copies
		// still has the logout's undefined heartbeat id (null in ETF) where the key
		// was, or no key if the launch never had a session (fixture login_submit).
		stale := identity_take_identify_hb_stale(id);
		before := identity_hb_key_before_app_state(id);
		for pr: vmap(spv) {
			k := vstr(pr.key);
			if k == "client_heartbeat_session_id" && stale {
				if before { etf.map_put(*props, k, V.{}); }
				continue;
			}
			etf.map_put(*props, k, to_v(pr.value));
		}
	}
	etf.map_put(*props, "is_fast_connect", to_v(false));
	// the launch's first connect comes from the app skeleton (fixtures: typing,
	// add_reaction, open_image_attachment when native fast connect was not used)
	etf.map_put(*props, "gateway_connect_reasons", to_v(as_string(ifx g.identified then "NO_REASONS" else "AppSkeleton")));
	if id.installation_id != "" { etf.map_put(*props, "installation_id", to_v(id.installation_id)); }

	pres := etf.map_builder(4);
	// before the settings proto is loaded the presence store reports "unknown"
	// (a login from the login page reports the presence store's "online": fixture login_submit)
	etf.map_put(*pres, "status", to_v(ifx g.identified || c.auth.login_session then status_name(g.presence_status) else as_string("unknown")));
	etf.map_put(*pres, "since", to_v(cast(s64)(0)));
	etf.map_put(*pres, "activities", etf.vlist(.[]));
	etf.map_put(*pres, "afk", to_v(false));

	cs := etf.map_builder(1);
	etf.map_put(*cs, "guild_versions", etf.vmap(.[]));

	active := false;
	{ q, ok := maybe_get(g.qos_upcoming);
	if ok { active = q.active; } else { q2, ok2 := maybe_get(g.qos_current);
if ok2 { active = q2.active; } } }

	d := etf.map_builder(7);
	etf.map_put(*d, "token", to_v(client_token(c)));
	etf.map_put(*d, "capabilities", to_v(id.platform.capabilities));
	etf.map_put(*d, "properties", etf.vmap(etf.map_done(*props)));
	etf.map_put(*d, "presence", etf.vmap(etf.map_done(*pres)));
	etf.map_put(*d, "compress", to_v(false));
	etf.map_put(*d, "client_state", etf.vmap(etf.map_done(*cs)));
	etf.map_put(*d, "qos_token", to_v(qos_token_b64(c.ready_qos_token, active)));
	return etf.vmap(etf.map_done(*d));
}

voice_state_value :: (guild_id: Snowflake, channel_id: Snowflake, self_mute: bool, self_deaf: bool, self_video: bool, flags: s64, allocator := temp) -> V {
	push_allocator(allocator);
	b := etf.map_builder(6);
	etf.map_put(*b, "guild_id", ifx guild_id == 0 then V.{} else to_v(snowflake_string(guild_id, allocator)));
	etf.map_put(*b, "channel_id", ifx channel_id == 0 then V.{} else to_v(snowflake_string(channel_id, allocator)));
	etf.map_put(*b, "self_mute", to_v(self_mute));
	etf.map_put(*b, "self_deaf", to_v(self_deaf));
	etf.map_put(*b, "self_video", to_v(self_video));
	etf.map_put(*b, "flags", to_v(flags));
	return etf.vmap(etf.map_done(*b));
}
#scope_module

// ---- connection lifecycle ----

gateway_close_socket :: (g: *Gateway, code: int) {
	locks.lock(*g.send_mu);
	ws := g.ws;
	stream := g.stream;
	g.ws = null;
	locks.unlock(*g.send_mu);
	if ws == null { return; }
	if g.c.on_ws_close != null { g.c.on_ws_close(g.c.observer_data, code); }
	http.ws_close(ws, code);
	netio.shutdown(stream);
	locks.lock(*g.mu);
	rd := g.reader;
	g.reader = null;
	locks.unlock(*g.mu);
	if !is_null(rd) {
		locks.join(rd);
	}
	http.ws_close_stream(ws);
	zstd.stream_destroy(*g.zs);
}

gateway_connect :: (g: *Gateway) {
	c := g.c;
	url := gateway_url(g);
	g.attempt_start = now_ms();
	if g.first_attempt == 0 { g.first_attempt = g.attempt_start; }
	host := sub_from(url, len("wss://"));
	host = sub(host, 0, strings.index_byte(host, #char "/"));
	path := sub_from(url, len("wss://") + len(host));
	client_push_state(c, .Connecting);

	stream, _, ok := dial_tls_stream(host, string.["http/1.1"]);
	if !ok {
		gateway_on_closed(g, g.gen, false, 0);
		return;
	}
	now := now_ms();
	cookie := cookie_header(*c.jar, host, path, true, now);
	hdrs := gateway_ws_headers(c.id.platform, host, cookie);
	key_raw: [16]u8;
	crypto.rand_bytes(view(key_raw));
	for * h: hdrs { if h.name == "Sec-WebSocket-Key" { h.value = base64.encode(view(key_raw), allocator = temp); } }
	req := http.Request.{method = "GET", scheme = "https", authority = host, path = path, headers = hdrs};
	if c.on_ws_open != null { c.on_ws_open(c.observer_data, url, req.headers); }
	ws, resp, err := http.ws_connect(stream, req, .{}, c.allocator);
	if err != .None {
		http.response_destroy(*resp);
		netio.close(stream);
		gateway_on_closed(g, g.gen, false, 0);
		return;
	}
	for h: resp.headers {
		if strings.equal_fold(h.name, "set-cookie") { cookie_set_from_header(*c.jar, host, path, h.value, now); }
	}
	http.response_destroy(*resp);
	netio.set_timeout(stream, 0);

	locks.lock(*g.mu);
	g.gen += 1;
	gen := g.gen;
	zstd.stream_init(*g.zs);
	g.received_hello = false;
	g.hello_deadline = now_ms() + 30_000;
	g.next_beat = 0;
	locks.unlock(*g.mu);

	locks.lock(*g.send_mu);
	g.ws = ws;
	g.stream = stream;
	locks.unlock(*g.send_mu);

	rd := thread.create(gateway_reader_proc);
	rd.data = g;
	rd.user_index = gen;
	rd.ctx = c.ctx;
	locks.lock(*g.mu);
	g.reader = rd;
	locks.unlock(*g.mu);
	thread.start(rd);

	// onOpen
	locks.lock(*g.mu);
	if !g.fast_connect_done && c.cfg.fast_connect {
		g.fast_connect_done = true;
		g.seq = 0;
		delete(g.session_id);
		g.session_id = "";
		g.state = .Identifying;
		g.last_ack = now_ms();
		g.identified = true;
		locks.unlock(*g.mu);
		client_push_state(c, .Identifying);
		// fast-connect.js runs once the deferred scripts have loaded: ~300 ms after open.
		d := ifx c.cfg.fast_identify_delay_ms != 0 then c.cfg.fast_identify_delay_ms else 300;
		if d > 0 { time.sleep(cast(time.Duration)(d) * time.Millisecond); }
		gateway_send(g, .Identify, identify_fast_connect_value(*c.id, client_token(c)));
	} else {
		g.fast_connect_done = true;
		resume_or_identify_locked(g);
		locks.unlock(*g.mu);
	}
}

// resume_or_identify_locked: _doResumeOrIdentify.
resume_or_identify_locked :: (g: *Gateway) {
	now := now_ms();
	if g.session_id != "" && (g.last_ack == 0 || now - g.last_ack <= 3 * 60_000) {
		g.state = .Resuming;
		b := etf.map_builder(3, temp);
		etf.map_put(*b, "token", to_v(client_token(g.c)));
		etf.map_put(*b, "session_id", to_v(g.session_id));
		etf.map_put(*b, "seq", to_v(g.seq));
		d := etf.vmap(etf.map_done(*b));
		locks.unlock(*g.mu);
		client_push_state(g.c, .Resuming);
		gateway_send(g, .Resume, d);
		locks.lock(*g.mu);
	} else {
		identify_locked(g);
	}
	g.last_ack = now;
}

identify_locked :: (g: *Gateway) {
	g.seq = 0;
	delete(g.session_id);
	g.session_id = "";
	g.state = .Identifying;
	d := identify_value(g);
	g.identified = true;
	locks.unlock(*g.mu);
	client_push_state(g.c, .Identifying);
	gateway_send(g, .Identify, d);
	locks.lock(*g.mu);
}

// gateway_on_closed: _handleClose. Called from the reader (socket died) or connect failure.
gateway_on_closed :: (g: *Gateway, gen: int, clean: bool, code: int) {
	locks.lock(*g.mu);
	defer locks.unlock(*g.mu);
	if gen != g.gen || g.stop { return; }
	g.next_beat = 0;
	g.hello_deadline = 0;
	g.close_code = code;
	if code == 4004 {
		g.state = .Stopped;
		delete(g.session_id);
		g.session_id = "";
		g.seq = 0;
		locks.unlock(*g.mu);
		client_push_state(g.c, .Auth_Failed);
		locks.lock(*g.mu);
		return;
	}
	if !g.received_hello { g.failed_attempts += 1; }
	g.state = .Closed;
	if g.immediate {
		g.immediate = false;
		g.reconnect_at = now_ms();
	} else {
		delay := backoff_fail(*g.backoff);
		g.reconnect_at = now_ms() + delay;
		if g.backoff.fails > 4 {
			// _reset: drop the session so the next connect identifies.
			delete(g.session_id);
			g.session_id = "";
			g.seq = 0;
		}
	}
	g.gen += 1; // invalidate the dead reader's generation
	locks.cond_broadcast(*g.cond);
	locks.unlock(*g.mu);
	client_push_state(g.c, .Disconnected);
	locks.lock(*g.mu);
}

gateway_reader_proc :: (th: *thread.Thread) {
	g := cast(*Gateway)th.data;
	gen := th.user_index;
	msg := make_dynamic(u8, 0, 0);
	defer delete(msg);
	locks.lock(*g.send_mu);
	ws := g.ws;
	locks.unlock(*g.send_mu);
	if ws == null { return; }
	while true {
		clear(*msg);
		typ, err := http.ws_recv(ws, *msg);
		if err != .None {
			code := ifx err == .Closed then ws.close_code else 0;
			// Detach and tear down on the control thread.
			go_closed := false;
			locks.lock(*g.mu);
			go_closed = gen == g.gen && !g.stop;
			locks.unlock(*g.mu);
			if go_closed { gateway_schedule_teardown(g, gen, code); }
			return;
		}
		if typ != .Binary { continue; }
		if !gateway_handle_frame(g, gen, view(msg)) {
			gateway_schedule_teardown(g, gen, 0);
			return;
		}
	}
}

// Teardown runs on the control thread (it must join this reader).
gateway_schedule_teardown :: (g: *Gateway, gen: int, code: int) {
	locks.lock(*g.mu);
	if gen == g.gen && !g.stop {
		g.pending_teardown = true;
		g.pending_code = code;
		g.pending_gen = gen;
		locks.cond_broadcast(*g.cond);
	}
	locks.unlock(*g.mu);
}

// gateway_handle_frame: inflate (zstd-stream), unpack, act. Returns false on a decode error.
gateway_handle_frame :: (g: *Gateway, gen: int, frame: []u8) -> bool {
	clear(*g.inflated);
	if zstd.stream_decode(*g.zs, frame, *g.inflated) != .None { return false; }
	if len(g.inflated) == 0 { return true; }
	arena := new(virtual.Arena);
	if virtual.arena_init_growing(arena) != .None {
		free(arena);
		return false;
	}
	alloc := virtual.arena_allocator(arena);
	v, derr := etf.decode(view(g.inflated), .{}, alloc);
	if derr != .None {
		virtual.arena_destroy(arena);
		free(arena);
		return false;
	}
	keep := gateway_handle_payload(g, gen, v, arena, alloc);
	if !keep {
		virtual.arena_destroy(arena);
		free(arena);
	}
	return true;
}

// gateway_handle_payload returns true when ownership of arena moved to the event queue.
gateway_handle_payload :: (g: *Gateway, gen: int, v: V, arena: *virtual.Arena, alloc: Allocator) -> bool {
	kept: bool;
	m := vmap(v);
	op := cast(Op)(fint(m, "op"));
	d := vget(m, "d");
	t := fstr(m, "t");
	sv := vget(m, "s");
	c := g.c;
	if c.on_gateway_recv != null { c.on_gateway_recv(c.observer_data, op, t, d); }
	if c.on_gateway_frame != null { c.on_gateway_frame(c.observer_data, false, v, 0); }
	if c.on_dispatch != null && op == .Dispatch { c.on_dispatch(c.user_data, t); }

	locks.lock(*g.mu);
	defer {
		send_heartbeat_if_due_locked(g);
		locks.unlock(*g.mu);
	}
	if gen != g.gen { return false; }
	if !is_null(sv) { g.seq = vint(sv); }
	if op == {
	case .Hello;
		g.hello_deadline = 0;
		g.received_hello = true;
		g.interval = fint(vmap(d), "heartbeat_interval");
		{
			now := now_ms();
			url := ifx g.resume_url != "" then g.resume_url else (ifx c.cfg.gateway_url != "" then c.cfg.gateway_url else GATEWAY_DEFAULT_URL);
			analytics_gateway_connected(c, g.failed_attempts, url, g.connected_once, !g.connected_once && c.cfg.fast_connect, now - g.first_attempt, now - g.attempt_start);
			g.connected_once = true;
			g.first_attempt = 0;
			g.failed_attempts = 0;
		}
		// _startHeartbeater: first beat after floor(random*interval).
		g.next_beat = now_ms() + cast(s64)(rand.float64_() * cast(float64)(g.interval));
		g.initial_beat = true;
		locks.cond_broadcast(*g.cond);
	case .Heartbeat_Ack;
		g.last_ack = now_ms();
		g.beat_acked = true;
	case .Heartbeat;
		send_heartbeat_locked(g);
		if g.next_beat != 0 { g.next_beat = now_ms() + g.interval; }
	case .Reconnect;
		g.immediate = true;
		g.pending_teardown = true;
		g.pending_code = 4000;
		g.pending_gen = gen;
		g.pending_send_close = true;
		locks.cond_broadcast(*g.cond);
	case .Invalid_Session;
		if vbool(d) { resume_or_identify_locked(g); } else { identify_locked(g); }
	case .Dispatch;
		if t == {
		case "READY";
			dm := vmap(d);
			delete(g.session_id);
			g.session_id = clone(fstr(dm, "session_id"));
			delete(g.resume_url);
			g.resume_url = clone(strings.trim_right(fstr(dm, "resume_gateway_url"), "/"));
			g.state = .Established;
			backoff_succeed(*g.backoff);
			// AuthenticationStore CONNECTION_OPEN: apex_experiments.installation -> installation_id_v3.
			{ inst := fstr(fmap(dm, "apex_experiments"), "installation");
			if inst != "" {
				locks.lock(*c.id.mu);
				if c.id.installation_id == "" { c.id.installation_id = clone(inst, c.allocator); }
				locks.unlock(*c.id.mu);
			} }
			locks.lock(*c.qos_mu);
			delete(c.ready_qos_token, c.allocator);
			c.ready_qos_token = clone(fstr(dm, "qos_token"), c.allocator);
			locks.unlock(*c.qos_mu);
			gateway_on_ready_locked(g);
		case "READY_SUPPLEMENTAL"; #through; case "RESUMED";
			g.state = .Established;
			backoff_succeed(*g.backoff);
		}
		ev := Event.{kind = .Dispatch, data = d, arena = arena};
		ev.name = clone(t, alloc);
		locks.unlock(*g.mu);
		client_push_event(c, ev);
		locks.lock(*g.mu);
		return true;
	}
	return false;
}

// After READY the client sends op 4 (VoiceStateStore reset), op 41
// (SessionHeartbeatScheduler on CONNECTION_OPEN) and a heartbeat.
gateway_on_ready_locked :: (g: *Gateway) {
	c := g.c;
	locks.unlock(*g.mu);
	gateway_send(g, .Voice_State_Update, voice_state_value(0, 0, c.cfg.voice_self_mute, false, false, 2));
	// Reopening on a route: GuildSubscriptions re-sends the guild's full
	// subscription state on CONNECTION_OPEN; a private channel route connects the call (op 13).
	locks.lock(*c.route_mu);
	rg, rch := c.route_guild, c.route_channel;
	locks.unlock(*c.route_mu);
	if rg != 0 {
		locks.lock(*c.job_mu);
		c.ready_subscribed_guild = rg;
		locks.unlock(*c.job_mu);
		gb := etf.map_builder(7, temp);
		etf.map_put(*gb, "typing", to_v(true));
		etf.map_put(*gb, "threads", to_v(true));
		etf.map_put(*gb, "activities", to_v(true));
		etf.map_put(*gb, "members", etf.vlist(.[]));
		etf.map_put(*gb, "member_updates", to_v(false));
		etf.map_put(*gb, "channels", etf.vmap(.[]));
		etf.map_put(*gb, "thread_member_lists", etf.vlist(.[]));
		sb := etf.map_builder(1, temp);
		etf.map_put(*sb, snowflake_string(rg), etf.vmap(etf.map_done(*gb)));
		db := etf.map_builder(1, temp);
		etf.map_put(*db, "subscriptions", etf.vmap(etf.map_done(*sb)));
		gateway_send(g, .Guild_Subscriptions_Bulk, etf.vmap(etf.map_done(*db)));
	} else if rch != 0 {
		cb := etf.map_builder(1, temp);
		etf.map_put(*cb, "channel_id", to_v(snowflake_string(rch)));
		gateway_send(g, .Call_Connect, etf.vmap(etf.map_done(*cb)));
	}
	now := now_ms();
	identity_touch_heartbeat(*c.id, now);
	hb := identity_heartbeat_snapshot(*c.id);
	if hb.uuid != "" {
		b := etf.map_builder(3, temp);
		etf.map_put(*b, "initialization_timestamp", to_v(hb.created_at));
		etf.map_put(*b, "session_id", to_v(hb.uuid));
		etf.map_put(*b, "client_launch_id", to_v(c.id.client_launch_id));
		gateway_send(g, .Update_Time_Spent_Session_Id, etf.vmap(etf.map_done(*b)));
	}
	client_on_ready(c);
	locks.lock(*g.mu);
	send_heartbeat_locked(g);
}

send_heartbeat_if_due_locked :: (g: *Gateway) {
	if g.interval == 0 || g.next_beat == 0 || g.last_beat == 0 { return; }
	if now_ms() - g.last_beat > g.interval + 5000 { send_heartbeat_locked(g); }
}

// ---- control thread: timers, reconnects, teardown ----

gateway_control_proc :: (g: *Gateway) {
	locks.lock(*g.mu);
	// The HTML bootstrap opens the socket ~190 ms after navigation (fixtures median).
	g.reconnect_at = g.c.launch_ms + (ifx g.c.cfg.ws_open_delay_ms != 0 then g.c.cfg.ws_open_delay_ms else 190);
	while !g.stop {
		now := now_ms();
		if g.pending_teardown {
			code := g.pending_code;
			gen := g.pending_gen;
			send_close := g.pending_send_close;
			g.pending_teardown = false;
			g.pending_send_close = false;
			locks.unlock(*g.mu);
			gateway_close_socket(g, ifx send_close then 4000 else 1000);
			gateway_on_closed(g, gen, false, code);
			locks.lock(*g.mu);
			continue;
		}
		if g.state == {
		case .Closed;
			if now >= g.reconnect_at {
				g.state = .Connecting;
				locks.unlock(*g.mu);
				gateway_connect(g);
				locks.lock(*g.mu);
				continue;
			}
		case .Connecting; #through; case .Identifying; #through; case .Resuming; #through; case .Established;
			if g.hello_deadline != 0 && now >= g.hello_deadline {
				// "did not receive OP_HELLO in time": also forget the resume url.
				g.hello_deadline = 0;
				delete(g.resume_url);
				g.resume_url = "";
				g.pending_teardown = true;
				g.pending_code = 0;
				g.pending_gen = g.gen;
				continue;
			}
			if g.next_beat != 0 && now >= g.next_beat {
				// _doHeartbeatInterval
				if g.initial_beat {
					g.initial_beat = false;
					g.beat_acked = true;
				}
				g.next_beat = now + g.interval;
				if g.beat_acked {
					g.beat_acked = false;
					send_heartbeat_locked(g);
				} else {
					// ACK timeout: close 4000 and reconnect through the backoff.
					g.pending_teardown = true;
					g.pending_code = 0;
					g.pending_gen = g.gen;
					g.pending_send_close = true;
				}
				continue;
			}
		case .Stopped;
		}
		wake: s64 = now + 1000;
		if g.state == .Closed { wake = min(wake, g.reconnect_at); }
		if g.next_beat != 0 { wake = min(wake, g.next_beat); }
		if g.hello_deadline != 0 { wake = min(wake, g.hello_deadline); }
		d := max(wake - now, 1);
		locks.cond_wait_with_timeout(*g.cond, *g.mu, cast(time.Duration)(d) * time.Millisecond);
	}
	locks.unlock(*g.mu);
}
#scope_export

// gateway_expedite: resetBackoff (app became active / network online).
gateway_reset_backoff :: (g: *Gateway) {
	locks.lock(*g.mu);
	defer locks.unlock(*g.mu);
	backoff_succeed(*g.backoff);
	if g.state == .Closed {
		g.reconnect_at = now_ms();
		locks.cond_broadcast(*g.cond);
	}
}

gateway_state :: (g: *Gateway) -> Gw_State {
	locks.lock(*g.mu);
	defer locks.unlock(*g.mu);
	return g.state;
}

