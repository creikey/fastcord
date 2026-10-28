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
//   - READY: op 4 (VoiceStateStore's state), op 41 (time-spent session), heartbeat.
//   - RESUMED: op 3 and op 4 again, then every guild subscription (client_after_dispatch).
//   - close: 4004 stops; otherwise Backoff(1 s, 60 s) with jitter; after more
//     than 4 consecutive failures the session is reset (fresh IDENTIFY).
//   - RESUME only if a session exists and the last ACK is ≤ 3 min old.
//   - op 7 reconnects immediately; op 9 resumes (d=true) or identifies.
//   - HELLO must arrive within 30 s.
//   - waking from sleep: expeditedHeartbeat(5000) (heartbeat now, reconnect without an ACK in 5 s).
//
// Threads: the control thread (timers, connects, teardown), one reader per socket and a writer for
// frames sent from the UI thread. Each resets its temporary storage per frame or timer round; what
// outlives that (session strings, the outbox, the inflate buffer) uses the client's allocator.

GATEWAY_DEFAULT_URL :: "wss://gateway.discord.gg";
GATEWAY_QUERY :: "/?encoding=etf&v=9&compress=zstd-stream";
GATEWAY_QUERY_PLAIN :: "/?encoding=etf&v=9"; // self-hosted servers: uncompressed frames

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
	Stream_Create :: 18;
	Stream_Delete :: 19;
	Stream_Watch :: 20;
	Stream_Set_Paused :: 22;
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
	writer: *Thread;
	ws: *http.Ws_Conn;
	stream: netio.Stream;
	gen: int;
	state: Gw_State;
	reader: *Thread;
	control: *Thread;
	stop: bool;
	// session (client allocator)
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
	expedited_deadline: s64; // an expedited heartbeat's ACK timeout (0: none)
	hello_deadline: s64;
	received_hello: bool;
	qos_current: Qos;
	qos_upcoming: Qos;
	have_qos_current: bool;
	have_qos_upcoming: bool;
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
	g := New(Gateway,, c.allocator);
	g.c = c;
	g.backoff = backoff_make(1000, 60000);
	g.state = ifx c.cfg.gateway_sink then .Established else .Closed; // a sink never connects: always established
	g.presence_status = .Online;
	g.inflated.allocator = c.allocator;
	g.outbox.allocator = c.allocator;
	return g;
}

gateway_start :: (g: *Gateway) {
	g.control = spawn(g, gateway_control_proc);
	g.writer = spawn(g, gateway_writer_proc);
}

gateway_writer_proc :: (g: *Gateway) {
	locks.lock(*g.out_mu);
	// Drains the outbox before it stops: gateway_stop joins it before closing the socket, so a last
	// op 4 (leaving voice on quit) still goes out.
	while !g.out_stop || g.outbox {
		if !g.outbox {
			locks.cond_wait(*g.out_cond, *g.out_mu);
			continue;
		}
		batch := array_copy(g.outbox,, temp);
		g.outbox.count = 0;
		locks.unlock(*g.out_mu);
		for batch {
			locks.lock(*g.send_mu);
			if g.ws http.ws_send(g.ws, .Binary, it);
			locks.unlock(*g.send_mu);
			array_free(it,, g.c.allocator);
		}
		reset_temporary_storage();
		locks.lock(*g.out_mu);
	}
	locks.unlock(*g.out_mu);
}

gateway_stop :: (g: *Gateway) {
	locks.lock(*g.mu);
	g.stop = true;
	g.state = .Stopped;
	locks.cond_broadcast(*g.cond);
	locks.unlock(*g.mu);
	if g.writer {
		locks.lock(*g.out_mu);
		g.out_stop = true;
		locks.cond_signal(*g.out_cond);
		locks.unlock(*g.out_mu);
		locks.join(g.writer);
	}
	gateway_close_socket(g, 1000);
	if g.control locks.join(g.control);
	// The control thread may have finished a connect after the close above, leaving a live socket
	// and reader thread behind; close and join them before the free.
	gateway_close_socket(g, 1000);
	push_allocator(g.c.allocator);
	for g.outbox array_free(it);
	array_free(g.outbox);
	free(g.session_id);
	free(g.resume_url);
	array_free(g.inflated);
	free(g);
}

gateway_url :: (g: *Gateway, allocator := temp) -> string {
	base := ifx g.resume_url then g.resume_url else g.c.cfg.gateway_url;
	if !base base = GATEWAY_DEFAULT_URL;
	return join(trim_right(base, "/"), GATEWAY_QUERY,, allocator);
}

// ---- sending ----

// gateway_send packs {op, d} (key order op, d) with the client's ETF layout.
gateway_send :: (g: *Gateway, op: Op, d: V) -> bool {
	c := g.c;
	if c.cfg.gateway_sink {
		c.cfg.gateway_sink(c.cfg.gateway_sink_data, op, d);
		return true;
	}
	frame := etf.vmap(.[.{etf.vstring("op"), etf.vint(xx op)}, .{etf.vstring("d"), d}]);
	buf, err := etf.encode(frame,, temp);
	if err != .None return false;
	if locks.on_ui_thread() {
		// Queued: true means accepted for sending, as a send can still fail on a dying socket.
		if atomic_load(*g.ws) == null return false;
		if c.on_gateway_send c.on_gateway_send(c.observer_data, op, d);
		if c.on_gateway_frame c.on_gateway_frame(c.observer_data, true, frame, buf.count);
		locks.lock(*g.out_mu);
		array_add(*g.outbox, array_copy(buf,, c.allocator));
		locks.cond_signal(*g.out_cond);
		locks.unlock(*g.out_mu);
		return true;
	}
	locks.lock(*g.send_mu);
	defer locks.unlock(*g.send_mu);
	if !g.ws return false;
	if c.on_gateway_send c.on_gateway_send(c.observer_data, op, d);
	if c.on_gateway_frame c.on_gateway_frame(c.observer_data, true, frame, buf.count);
	return http.ws_send(g.ws, .Binary, buf) == .None;
}

qos_value :: (q: Qos) -> V {
	push_allocator(temp);
	reasons := NewArray(q.n, V);
	for * reasons it.* = etf.vstring(q.reasons[it_index]);
	b := etf.map_builder(3);
	etf.map_put(*b, "active", etf.vbool(q.active));
	etf.map_put(*b, "ver", etf.vint(31));
	etf.map_put(*b, "reasons", etf.vlist(reasons));
	return etf.vmap(etf.map_done(*b));
}

// send_heartbeat_locked consumes the QoS payload (and promotes the upcoming state).
send_heartbeat_locked :: (g: *Gateway) {
	q, have := g.qos_current, g.have_qos_current;
	if g.have_qos_upcoming g.qos_current, g.have_qos_current = g.qos_upcoming, true;
	g.have_qos_upcoming = false;
	b := etf.map_builder(2,, temp);
	etf.map_put(*b, "seq", etf.vint(g.seq));
	etf.map_put(*b, "qos", ifx have then qos_value(q) else .{});
	g.last_beat = now_ms();
	d := etf.vmap(etf.map_done(*b));
	locks.unlock(*g.mu);
	gateway_send(g, .Qos_Heartbeat, d);
	locks.lock(*g.mu);
}

// gateway_set_active mirrors handleActiveStateChange(K()).
gateway_set_active :: (g: *Gateway, q: Qos) {
	locks.lock(*g.mu);
	defer locks.unlock(*g.mu);
	cur := ifx g.have_qos_current then g.qos_current else q;
	was_inactive := !g.have_qos_current || !g.qos_current.active;
	if q.active {
		cur.active = true;
		for r: array_view(q.reasons, 0, q.n) {
			dup := false;
			for array_view(cur.reasons, 0, cur.n) if it == r dup = true;
			if !dup && cur.n < cur.reasons.count {
				cur.reasons[cur.n] = r;
				cur.n += 1;
			}
		}
		// sorted, as [...new Set()].sort()
		for i: 1..cur.n-1 {
			j := i;
			while j > 0 && compare(cur.reasons[j], cur.reasons[j - 1]) < 0 {
				cur.reasons[j], cur.reasons[j - 1] = cur.reasons[j - 1], cur.reasons[j];
				j -= 1;
			}
		}
	}
	g.qos_current, g.have_qos_current = cur, true;
	if q.active && was_inactive && g.state == .Established send_heartbeat_locked(g);
	g.qos_upcoming, g.have_qos_upcoming = q, true;
}

// ---- payload builders ----

// identify_fast_connect_value: the IDENTIFY fast-connect.js sends from the
// HTML bootstrap (no presence/compress/qos_token; its own client_launch_id).
identify_fast_connect_value :: (id: *Identity, token: string, allocator := temp) -> V {
	push_allocator(allocator);
	p := id.platform;
	props := etf.map_builder(20);
	put_base_properties(*props, p, id.fast_connect_launch_id);
	etf.map_put(*props, "is_fast_connect", etf.vbool(true));
	if id.installation_id etf.map_put(*props, "installation_id", etf.vstring(id.installation_id));
	d := etf.map_builder(4);
	etf.map_put(*d, "token", etf.vstring(token));
	etf.map_put(*d, "capabilities", etf.vint(p.capabilities));
	etf.map_put(*d, "properties", etf.vmap(etf.map_done(*props)));
	etf.map_put(*d, "client_state", client_state_value());
	return etf.vmap(etf.map_done(*d));
}

// {guild_versions: {}}
client_state_value :: () -> V {
	cs := etf.map_builder(1);
	etf.map_put(*cs, "guild_versions", etf.vmap(.[]));
	return etf.vmap(etf.map_done(*cs));
}

put_base_properties :: (b: *etf.Map_Builder, p: Platform_Info, launch_id: string) {
	put :: (k: string, v: string) #expand { etf.map_put(b, k, etf.vstring(v)); }
	put("os", p.os);
	put("browser", p.browser);
	put("release_channel", p.release_channel);
	put("client_version", p.client_version);
	put("os_version", p.os_version);
	put("os_arch", p.os_arch);
	put("app_arch", p.app_arch);
	put("system_locale", p.system_locale);
	etf.map_put(b, "has_client_mods", etf.vbool(false));
	put("client_launch_id", launch_id);
	put("browser_user_agent", p.browser_user_agent);
	put("browser_version", p.browser_version);
	if p.os_sdk_version put("os_sdk_version", p.os_sdk_version);
	if p.window_manager {
		put("window_manager", p.window_manager);
		put("distro", p.distro);
		put("runtime_environment", p.runtime_environment);
		put("display_server", p.display_server);
	}
	etf.map_put(b, "client_build_number", etf.vint(p.client_build_number));
	etf.map_put(b, "native_build_number", ifx p.native_build_number then etf.vint(p.native_build_number) else .{});
	etf.map_put(b, "client_event_source", .{});
}

// qos_token_b64 builds QosToken{client_provided{is_active}, derived} from the
// READY qos_token (base64 DerivedQosData).
qos_token_b64 :: (ready_qos_token: string, active: bool, allocator := temp) -> string {
	derived, ok := base64_decode(ready_qos_token,, temp);
	w, inner: protobuf.Writer;
	w.buf.allocator, inner.buf.allocator = temp, temp;
	if active protobuf.write_uint(*inner, 1, 1);
	protobuf.write_bytes(*w, 1, inner.buf);
	if ok && ready_qos_token protobuf.write_bytes(*w, 2, cast([]u8) derived);
	return base64_encode(cast(string) w.buf,, allocator);
}

// identify_value: the regular GatewaySocket._doIdentify payload (reconnects).
identify_value :: (g: *Gateway, allocator := temp) -> V {
	push_allocator(allocator);
	c := g.c;
	id := *c.id;
	props := etf.map_builder(24);
	// {...getSuperProperties(), client_app_state, is_fast_connect:false, gateway_connect_reasons, installation_id}
	spv, perr := etf.from_json(super_properties_json(id, now_ms()));
	if perr == .None {
		// After a login from the login page the properties object IDENTIFY copies
		// still has the logout's undefined heartbeat id (null in ETF) where the key
		// was, or no key if the launch never had a session (fixture login_submit).
		stale := identity_take_identify_hb_stale(id);
		before := identity_hb_key_before_app_state(id);
		for vmap(spv) {
			k := vstr(it.key);
			if k == "client_heartbeat_session_id" && stale {
				if before etf.map_put(*props, k, .{});
				continue;
			}
			etf.map_put(*props, k, it.value);
		}
	}
	etf.map_put(*props, "is_fast_connect", etf.vbool(false));
	// the launch's first connect comes from the app skeleton (fixtures: typing,
	// add_reaction, open_image_attachment when native fast connect was not used)
	etf.map_put(*props, "gateway_connect_reasons", etf.vstring(ifx g.identified then "NO_REASONS" else "AppSkeleton"));
	if id.installation_id etf.map_put(*props, "installation_id", etf.vstring(id.installation_id));

	pres := etf.map_builder(4);
	// before the settings proto is loaded the presence store reports "unknown"
	// (a login from the login page reports the presence store's "online": fixture login_submit)
	idle_since := atomic_load(*c.idle_since);
	status := ifx g.presence_status == .Online && idle_since then Status.Idle else g.presence_status;
	etf.map_put(*pres, "status", etf.vstring(ifx g.identified || c.auth.login_session then status_name(status) else "unknown"));
	etf.map_put(*pres, "since", etf.vint(idle_since));
	etf.map_put(*pres, "activities", etf.vlist(.[]));
	etf.map_put(*pres, "afk", etf.vbool(idle_since != 0));

	active := ifx g.have_qos_upcoming then g.qos_upcoming.active else g.have_qos_current && g.qos_current.active;

	d := etf.map_builder(7);
	etf.map_put(*d, "token", etf.vstring(client_token(c)));
	etf.map_put(*d, "capabilities", etf.vint(id.platform.capabilities));
	etf.map_put(*d, "properties", etf.vmap(etf.map_done(*props)));
	etf.map_put(*d, "presence", etf.vmap(etf.map_done(*pres)));
	etf.map_put(*d, "compress", etf.vbool(false));
	etf.map_put(*d, "client_state", client_state_value());
	etf.map_put(*d, "qos_token", etf.vstring(qos_token_b64(c.ready_qos_token, active)));
	return etf.vmap(etf.map_done(*d));
}

voice_state_value :: (guild_id: Snowflake, channel_id: Snowflake, self_mute: bool, self_deaf: bool, self_video: bool, flags: s64, allocator := temp) -> V {
	push_allocator(allocator);
	id :: (x: Snowflake) -> V { return ifx x then etf.vstring(sprint("%", x)) else .{}; }
	b := etf.map_builder(6);
	etf.map_put(*b, "guild_id", id(guild_id));
	etf.map_put(*b, "channel_id", id(channel_id));
	etf.map_put(*b, "self_mute", etf.vbool(self_mute));
	etf.map_put(*b, "self_deaf", etf.vbool(self_deaf));
	etf.map_put(*b, "self_video", etf.vbool(self_video));
	etf.map_put(*b, "flags", etf.vint(flags));
	return etf.vmap(etf.map_done(*b));
}

// ---- connection lifecycle ----

gateway_close_socket :: (g: *Gateway, code: int) {
	locks.lock(*g.send_mu);
	ws := g.ws;
	stream := g.stream;
	g.ws = null;
	locks.unlock(*g.send_mu);
	if !ws return;
	if g.c.on_ws_close g.c.on_ws_close(g.c.observer_data, code);
	http.ws_close(ws, code);
	netio.shutdown(stream);
	locks.lock(*g.mu);
	rd := g.reader;
	g.reader = null;
	locks.unlock(*g.mu);
	if rd locks.join(rd);
	http.ws_close_stream(ws);
	zstd.stream_destroy(*g.zs);
}

gateway_connect :: (g: *Gateway) {
	c := g.c;
	url := gateway_url(g);
	g.attempt_start = now_ms();
	if g.first_attempt == 0 g.first_attempt = g.attempt_start;
	_, host := split_from_left(advance(url, "wss://".count), #char "/");
	path := advance(url, "wss://".count + host.count);
	client_push_state(c, .Connecting);

	stream: netio.Stream;
	ok: bool;
	hosted := c.cfg.hosted.host != "";
	if hosted {
		host, path = c.cfg.hosted.server_id, GATEWAY_QUERY_PLAIN;
		stream, ok = dial_hosted(c.cfg.hosted);
	} else {
		stream, _, ok = dial_tls_stream(host, .["http/1.1"]);
	}
	if !ok {
		gateway_on_closed(g, g.gen, false, 0);
		return;
	}
	now := now_ms();
	hdrs: []http.Header;
	if hosted hdrs = array_copy(http.Header.[.{"Upgrade", "websocket"}, .{"Connection", "Upgrade"}, .{"Sec-WebSocket-Version", "13"}, .{"Sec-WebSocket-Key", ""}],, temp);
	else hdrs = gateway_ws_headers(c.id.platform, host, cookie_header(*c.jar, host, path, true, now));
	key_raw: [16]u8;
	crypto.random_bytes(key_raw);
	for * hdrs if it.name == "Sec-WebSocket-Key" it.value = base64_encode(cast(string) key_raw,, temp);
	req := http.Request.{method = "GET", scheme = "https", authority = host, path = path, headers = hdrs};
	if c.on_ws_open c.on_ws_open(c.observer_data, url, req.headers);
	ws, resp, err := http.ws_connect(stream, req, .{},, c.allocator);
	if err != .None {
		http.response_destroy(*resp);
		netio.close(stream);
		gateway_on_closed(g, g.gen, false, 0);
		return;
	}
	for resp.headers if equal_nocase(it.name, "set-cookie") cookie_set_from_header(*c.jar, host, path, it.value, now);
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

	locks.lock(*g.mu);
	g.reader = spawn(Gw_Reader.{g, gen}, gateway_reader_proc);
	// onOpen
	if !g.fast_connect_done && c.cfg.fast_connect {
		g.fast_connect_done = true;
		g.seq = 0;
		forget_session_locked(g);
		g.state = .Identifying;
		g.last_ack = now_ms();
		g.identified = true;
		locks.unlock(*g.mu);
		client_push_state(c, .Identifying);
		// fast-connect.js runs once the deferred scripts have loaded: ~300 ms after open.
		d := ifx c.cfg.fast_identify_delay_ms != 0 then c.cfg.fast_identify_delay_ms else 300;
		if d > 0 sleep_milliseconds(xx d);
		gateway_send(g, .Identify, identify_fast_connect_value(*c.id, client_token(c)));
		analytics_launch_identify(c);
	} else {
		g.fast_connect_done = true;
		resume_or_identify_locked(g);
		locks.unlock(*g.mu);
	}
}

forget_session_locked :: (g: *Gateway) {
	free_str(g.session_id, g.c.allocator);
	g.session_id = "";
}

// resume_or_identify_locked: _doResumeOrIdentify.
resume_or_identify_locked :: (g: *Gateway) {
	now := now_ms();
	if g.session_id && (g.last_ack == 0 || now - g.last_ack <= 3 * 60_000) {
		g.state = .Resuming;
		b := etf.map_builder(3,, temp);
		etf.map_put(*b, "token", etf.vstring(client_token(g.c)));
		etf.map_put(*b, "session_id", etf.vstring(copy_string(g.session_id,, temp)));
		etf.map_put(*b, "seq", etf.vint(g.seq));
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
	forget_session_locked(g);
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
	if gen != g.gen || g.stop return;
	g.next_beat = 0;
	g.hello_deadline = 0;
	g.expedited_deadline = 0;
	g.close_code = code;
	if code == 4004 {
		g.state = .Stopped;
		forget_session_locked(g);
		g.seq = 0;
		locks.unlock(*g.mu);
		client_push_state(g.c, .Auth_Failed);
		locks.lock(*g.mu);
		return;
	}
	if !g.received_hello g.failed_attempts += 1;
	g.state = .Closed;
	if g.immediate {
		g.immediate = false;
		g.reconnect_at = now_ms();
	} else {
		g.reconnect_at = now_ms() + backoff_fail(*g.backoff);
		if g.backoff.fails > 4 {
			// _reset: drop the session so the next connect identifies.
			forget_session_locked(g);
			g.seq = 0;
		}
	}
	g.gen += 1; // invalidate the dead reader's generation
	locks.cond_broadcast(*g.cond);
	locks.unlock(*g.mu);
	client_push_state(g.c, .Disconnected);
	locks.lock(*g.mu);
}

Gw_Reader :: struct { g: *Gateway; gen: int; }

gateway_reader_proc :: (using r: Gw_Reader) {
	msg: [..]u8;
	defer array_free(msg);
	locks.lock(*g.send_mu);
	ws := g.ws;
	locks.unlock(*g.send_mu);
	if !ws return;
	while true {
		msg.count = 0;
		typ, err := http.ws_recv(ws, *msg);
		if err != .None {
			// Detach and tear down on the control thread.
			locks.lock(*g.mu);
			go_closed := gen == g.gen && !g.stop;
			locks.unlock(*g.mu);
			if go_closed gateway_schedule_teardown(g, gen, ifx err == .Closed then ws.close_code else 0);
			return;
		}
		if typ != .Binary continue;
		ok := gateway_handle_frame(g, gen, msg);
		reset_temporary_storage(); // a frame's payload lives in its own pool
		if !ok {
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
	g.inflated.count = 0;
	if g.c.cfg.hosted.host array_add(*g.inflated, ..frame);
	else if zstd.stream_decode(*g.zs, frame, *g.inflated) != .None return false;
	if !g.inflated return true;
	pool := New(Flat_Pool);
	t0 := current_time_monotonic();
	v, derr := etf.decode(g.inflated,, pool_allocator(pool));
	if derr == .None && fstr(vmap(v), "t") == "READY" analytics_ready_frame(g.c, frame.count, g.inflated.count, to_milliseconds(current_time_monotonic() - t0));
	keep := derr == .None && gateway_handle_payload(g, gen, v, pool);
	if !keep {
		fini(pool);
		free(pool);
	}
	return derr == .None;
}

// gateway_handle_payload returns true when ownership of pool moved to the event queue.
gateway_handle_payload :: (g: *Gateway, gen: int, v: V, pool: *Flat_Pool) -> bool {
	m := vmap(v);
	op := cast(Op) fint(m, "op");
	d := vget(m, "d");
	t := fstr(m, "t");
	sv := vget(m, "s");
	c := g.c;
	if c.on_gateway_recv c.on_gateway_recv(c.observer_data, op, t, d);
	if c.on_gateway_frame c.on_gateway_frame(c.observer_data, false, v, 0);
	if c.on_dispatch && op == .Dispatch c.on_dispatch(c.user_data, t);

	locks.lock(*g.mu);
	defer {
		send_heartbeat_if_due_locked(g);
		locks.unlock(*g.mu);
	}
	if gen != g.gen return false;
	if !vis_null(sv) g.seq = vint(sv);
	if op == {
		case .Hello;
			g.hello_deadline = 0;
			g.received_hello = true;
			g.interval = fint(vmap(d), "heartbeat_interval");
			now := now_ms();
			url := ifx g.resume_url then g.resume_url else ifx c.cfg.gateway_url then c.cfg.gateway_url else GATEWAY_DEFAULT_URL;
			analytics_gateway_connected(c, g.failed_attempts, url, g.connected_once, !g.connected_once && c.cfg.fast_connect, now - g.first_attempt, now - g.attempt_start);
			g.connected_once = true;
			g.first_attempt = 0;
			g.failed_attempts = 0;
			// _startHeartbeater: first beat after floor(random*interval).
			g.next_beat = now_ms() + cast(s64) (cast(float64) random_get_zero_to_one_open() * cast(float64) g.interval);
			g.initial_beat = true;
			locks.cond_broadcast(*g.cond);
		case .Heartbeat_Ack;
			g.last_ack = now_ms();
			g.beat_acked = true;
			g.expedited_deadline = 0;
		case .Heartbeat;
			send_heartbeat_locked(g);
			if g.next_beat != 0 g.next_beat = now_ms() + g.interval;
		case .Reconnect;
			g.immediate = true;
			g.pending_teardown = true;
			g.pending_code = 4000;
			g.pending_gen = gen;
			g.pending_send_close = true;
			locks.cond_broadcast(*g.cond);
		case .Invalid_Session;
			if vbool(d) resume_or_identify_locked(g); else identify_locked(g);
		case .Dispatch;
			if t == {
				case "READY";
					dm := vmap(d);
					push_allocator(c.allocator);
					forget_session_locked(g);
					g.session_id = copy_string(fstr(dm, "session_id"));
					free(g.resume_url);
					g.resume_url = copy_string(trim_right(fstr(dm, "resume_gateway_url"), "/"));
					g.state = .Established;
					backoff_succeed(*g.backoff);
					// AuthenticationStore CONNECTION_OPEN: apex_experiments.installation -> installation_id_v3.
					inst := fstr(fmap(dm, "apex_experiments"), "installation");
					if inst {
						locks.lock(*c.id.mu);
						if !c.id.installation_id c.id.installation_id = copy_string(inst);
						locks.unlock(*c.id.mu);
					}
					locks.lock(*c.qos_mu);
					free(c.ready_qos_token);
					c.ready_qos_token = copy_string(fstr(dm, "qos_token"));
					locks.unlock(*c.qos_mu);
					gateway_on_ready_locked(g);
				case "READY_SUPPLEMENTAL"; #through;
				case "RESUMED";
					g.state = .Established;
					backoff_succeed(*g.backoff);
			}
			ev := Event.{kind = .Dispatch, name = copy_string(t,, pool_allocator(pool)), data = d, arena = pool};
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
	// CONNECTION_OPEN: VoiceStateStore commits its state: no channel at launch, the call we're in
	// on a later READY (a new session), or a join made while the socket was down
	locks.lock(*c.route_mu);
	vs := c.voice_self;
	locks.unlock(*c.route_mu);
	gateway_send(g, .Voice_State_Update, voice_self_value(c, vs));
	// Reopening on a route: GuildSubscriptions re-sends the guild's full
	// subscription state on CONNECTION_OPEN; a private channel route connects the call (op 13).
	locks.lock(*c.route_mu);
	rg, rch := c.route_guild, c.route_channel;
	locks.unlock(*c.route_mu);
	if rg {
		locks.lock(*c.job_mu);
		c.ready_subscribed_guild = rg;
		locks.unlock(*c.job_mu);
		sb := etf.map_builder(1,, temp);
		etf.map_put(*sb, tprint("%", rg), guild_subscription_value(.[]));
		db := etf.map_builder(1,, temp);
		etf.map_put(*db, "subscriptions", etf.vmap(etf.map_done(*sb)));
		gateway_send(g, .Guild_Subscriptions_Bulk, etf.vmap(etf.map_done(*db)));
	} else if rch {
		cb := etf.map_builder(1,, temp);
		etf.map_put(*cb, "channel_id", etf.vstring(tprint("%", rch)));
		gateway_send(g, .Call_Connect, etf.vmap(etf.map_done(*cb)));
	}
	identity_touch_heartbeat(*c.id, now_ms());
	hb := identity_heartbeat_snapshot(*c.id);
	if hb.uuid {
		b := etf.map_builder(3,, temp);
		etf.map_put(*b, "initialization_timestamp", etf.vint(hb.created_at));
		etf.map_put(*b, "session_id", etf.vstring(hb.uuid));
		etf.map_put(*b, "client_launch_id", etf.vstring(c.id.client_launch_id));
		gateway_send(g, .Update_Time_Spent_Session_Id, etf.vmap(etf.map_done(*b)));
	}
	client_on_ready(c);
	locks.lock(*g.mu);
	send_heartbeat_locked(g);
}

send_heartbeat_if_due_locked :: (g: *Gateway) {
	if g.interval == 0 || g.next_beat == 0 || g.last_beat == 0 return;
	if now_ms() - g.last_beat > g.interval + 5000 send_heartbeat_locked(g);
}

// ---- control thread: timers, reconnects, teardown ----

gateway_control_proc :: (g: *Gateway) {
	locks.lock(*g.mu);
	g.reconnect_at = gateway_open_at(g.c);
	last_round := now_ms();
	next_idle_poll: s64;
	while !g.stop {
		reset_temporary_storage(); // nothing in temp outlives a round
		now := now_ms();
		// A round waits at most 1 s, so a longer gap is the machine waking from sleep: the client's
		// powerMonitor "resume" sends expeditedHeartbeat(5000).
		if now - last_round > WAKE_GAP_MS gateway_expedited_heartbeat_locked(g, 5000);
		last_round = now;
		if now >= next_idle_poll {
			next_idle_poll = now + 10_000;
			locks.unlock(*g.mu);
			idle_poll(g.c, now);
			locks.lock(*g.mu);
		}
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
			case .Connecting; #through;
			case .Identifying; #through;
			case .Resuming; #through;
			case .Established;
				if g.hello_deadline != 0 && now >= g.hello_deadline {
					// "did not receive OP_HELLO in time": also forget the resume url.
					g.hello_deadline = 0;
					free_str(g.resume_url, g.c.allocator);
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
					} else if g.expedited_deadline == 0 {
						// ACK timeout: close 4000 and reconnect through the backoff.
						g.pending_teardown = true;
						g.pending_code = 0;
						g.pending_gen = g.gen;
						g.pending_send_close = true;
					}
					continue;
				}
				if g.expedited_deadline != 0 && now >= g.expedited_deadline {
					g.expedited_deadline = 0;
					if !g.beat_acked {
						g.pending_teardown = true;
						g.pending_code = 0;
						g.pending_gen = g.gen;
						g.pending_send_close = true;
					}
					continue;
				}
		}
		wake := now + 1000;
		if g.state == .Closed wake = min(wake, g.reconnect_at);
		if g.next_beat != 0 wake = min(wake, g.next_beat);
		if g.hello_deadline != 0 wake = min(wake, g.hello_deadline);
		if g.expedited_deadline != 0 wake = min(wake, g.expedited_deadline);
		locks.cond_wait_with_timeout(*g.cond, *g.mu, max(wake - now, 1));
	}
	locks.unlock(*g.mu);
}

WAKE_GAP_MS :: 15_000;

// expeditedHeartbeat(timeout): connected, heartbeat now and reconnect if no ACK within timeout_ms;
// waiting to reconnect, resetBackoff: reconnect at once.
gateway_expedited_heartbeat_locked :: (g: *Gateway, timeout_ms: s64) {
	if g.state == .Stopped return;
	if g.state == .Closed {
		backoff_succeed(*g.backoff);
		g.reconnect_at = now_ms();
	} else if g.state != .Connecting {
		g.beat_acked = false;
		send_heartbeat_locked(g);
		g.expedited_deadline = now_ms() + timeout_ms;
	}
	locks.cond_broadcast(*g.cond);
}

// gateway_established: isSessionEstablished (SESSION_ESTABLISHED or RESUMING), when the stores
// commit their state; what they skip goes out with READY or RESUMED.
gateway_established :: (g: *Gateway) -> bool {
	st := gateway_state(g);
	return st == .Established || st == .Resuming;
}

gateway_state :: (g: *Gateway) -> Gw_State {
	locks.lock(*g.mu);
	defer locks.unlock(*g.mu);
	return g.state;
}
