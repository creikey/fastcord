// Voice channels, with serve as the selective forwarding unit (SFU). Members run the client's Discord voice
// stack unchanged: op 4 on the gateway gives a voice state and VOICE_SERVER_UPDATE; the voice gateway is a
// WebSocket on this listener (/?v=9, JSON as Discord's) and media is UDP on the same port number. Serve only
// forwards: each packet is opened with its sender's transport key and sealed again with each listener's, and
// never decoded. There is no DAVE yet, so the host could listen in, as it can read every channel.
//
// Go Live is the same, as on Discord: gateway ops 18-20 give a stream its own room (its rtc_server_id), which
// the streamer and each viewer join with a second voice connection.

#load "../voice/rtp.jai"; // Discord's RTP framing and transport encryption, shared with the client.

VOICE :: 2;
// Voice gateway opcodes and speaking flags, as src/voice/gateway.jai names them.
OP_IDENTIFY :: 0;
OP_SELECT_PROTOCOL :: 1;
OP_HEARTBEAT :: 3;
OP_SPEAKING :: 5;
OP_RESUME :: 7;
OP_VIDEO :: 12;
SPEAKING_FLAGS :: 7; // Voice, soundshare, priority.
VOICE_HEARTBEAT_MS :: 13_750;
MAX_VOICE_ROOM :: 25;       // Members in one voice channel: Discord's cap with video on.
MAX_VOICE_SESSIONS :: 256;  // Voice WebSockets at once.
// What one member may send per second; more is dropped, since serve sends each packet to everyone else.
MAX_MEDIA_PACKETS :: 1500;
MAX_MEDIA_BYTES :: 1_500_000;
// Offered in READY, in the client's order of preference.
VOICE_MODES :: "[\"aead_aes256_gcm_rtpsize\",\"aead_xchacha20_poly1305_rtpsize\"]";

Voice_State :: struct {
	user: s64;
	channel: s64;
	gateway: *Conn;  // The member's gateway that joined: its session ID goes out, and its close leaves.
	token: [16]u8;   // VOICE_SERVER_UPDATE's, which the voice gateway's Identify must show.
	self_mute, self_deaf, self_video: bool;
	stream: s64;          // Go Live: the stream's room, 0 when not streaming. A stream ends with its voice state.
	stream_token: [16]u8; // STREAM_SERVER_UPDATE's, for the streamer and every viewer.
}

// One voice WebSocket and the media it carries.
Voice_Session :: struct {
	conn: *Conn;
	user: s64;
	room: s64;      // The voice channel, or a stream's room.
	ssrc: u32;      // Audio; the camera is ssrc + 1 and its retransmissions ssrc + 2.
	mode: Mode;     // .None until SELECT_PROTOCOL.
	tc: Transport_Crypto;
	nonce: u32;     // Our counter for what we seal to this member.
	addr: [16]u8;   // Where its media comes from and goes; set by IP discovery until a packet proves it.
	port: int;
	proven: bool;
	speaking: int;  // The last op 5 and op 12, replayed to who connects later.
	video: bool;
	window_ms: s64; // The current second of sending, and what it held.
	window_packets, window_bytes: int;
}

// voice_states_value is READY's voice_states; the caller holds db_mu, which comes before voice_mu.
voice_states_value :: (s: *Server) -> etf.Value {
	locks.guard(*s.voice_mu);
	list := NewArray(s.voice_states.count, etf.Value,, temp);
	for * s.voice_states list[it_index] = voice_state_value(s, it);
	return etf.vlist(list);
}

voice_state_value :: (s: *Server, vs: *Voice_State, user: s64 = 0) -> etf.Value {
	m := etf.map_builder(10,, temp);
	etf.map_put(*m, "guild_id", snow(s.guild));
	etf.map_put(*m, "channel_id", ifx vs then snow(vs.channel) else etf.Value.{});
	etf.map_put(*m, "user_id", snow(ifx vs then vs.user else user));
	etf.map_put(*m, "session_id", ifx vs then etf.vstring(hex(vs.gateway.session,, temp)) else etf.Value.{});
	etf.map_put(*m, "self_mute", etf.vbool(vs && vs.self_mute));
	etf.map_put(*m, "self_deaf", etf.vbool(vs && vs.self_deaf));
	etf.map_put(*m, "self_video", etf.vbool(vs && vs.self_video));
	etf.map_put(*m, "self_stream", etf.vbool(vs && vs.stream != 0));
	etf.map_put(*m, "mute", etf.vbool(false));
	etf.map_put(*m, "deaf", etf.vbool(false));
	return etf.vmap(etf.map_done(*m));
}

// Gateway op 4 {guild_id, channel_id, self_mute, self_deaf, self_video}: join, move, leave or change state.
// A member has one voice state, so joining from another device moves the call there.
voice_state_update :: (c: *Conn, d: etf.Value) {
	s := c.server;
	if d.kind != .Map return;
	g, _ := etf.map_get(d.map, "guild_id");
	ch, _ := etf.map_get(d.map, "channel_id");
	channel: s64;
	if ch.kind == .String {
		ok: bool;
		channel, ok = string_to_int(ch.s, T = s64);
		if !ok || g.kind != .String || g.s != tprint("%", s.guild) return;
		locks.guard(*s.db_mu);
		if channel_type_locked(s, channel) != VOICE return;
	} else if ch.kind != .Nil return;
	flag :: (m: etf.Map, k: string) -> bool { v, _ := etf.map_get(m, k); return v.kind == .Bool && v.b; }
	state, server, gone: etf.Value;
	{
		locks.guard(*s.voice_mu);
		vs: *Voice_State;
		at := -1;
		for * s.voice_states if it.user == c.user { vs, at = it, it_index; }
		if !channel {
			if !vs return;
			gone = end_locked(s, vs);
			state = voice_state_value(s, null, c.user);
			array_unordered_remove_by_index(*s.voice_states, at);
		} else {
			moved := !vs || vs.channel != channel || vs.gateway != c;
			if moved {
				in_room := 0;
				for s.voice_states if it.channel == channel && it.user != c.user in_room += 1;
				if in_room >= MAX_VOICE_ROOM return;
				if vs gone = end_locked(s, vs);
				else vs = array_add(*s.voice_states);
				vs.user, vs.channel, vs.gateway = c.user, channel, c;
				crypto.random_bytes(vs.token);
				m := etf.map_builder(3,, temp);
				etf.map_put(*m, "token", etf.vstring(hex(vs.token,, temp)));
				etf.map_put(*m, "guild_id", snow(s.guild));
				// Members dial the server's own address, the invite's, so the endpoint only names this server.
				etf.map_put(*m, "endpoint", etf.vstring(id_hex(s)));
				server = etf.vmap(etf.map_done(*m));
			}
			vs.self_mute, vs.self_deaf, vs.self_video = flag(d.map, "self_mute"), flag(d.map, "self_deaf"), flag(d.map, "self_video");
			state = voice_state_value(s, vs);
		}
	}
	if gone.kind == .Map broadcast(s, "STREAM_DELETE", gone);
	broadcast(s, "VOICE_STATE_UPDATE", state);
	if server.kind == .Map dispatch(c, "VOICE_SERVER_UPDATE", server);
}

// voice_leave ends user's voice state, when only gateway (null: any) holds it: that gateway closed, the
// member was removed, or the channel went away (user 0 and channel: everyone in it).
voice_leave :: (s: *Server, user: s64, gateway: *Conn = null, channel: s64 = 0) {
	left, gone: [..]etf.Value;
	left.allocator, gone.allocator = temp, temp;
	{
		locks.guard(*s.voice_mu);
		for * s.voice_states {
			if (user && it.user != user) || (gateway && it.gateway != gateway) || (channel && it.channel != channel) continue;
			ended := end_locked(s, it);
			if ended.kind == .Map array_add(*gone, ended);
			array_add(*left, voice_state_value(s, null, it.user));
			remove it;
		}
	}
	for gone broadcast(s, "STREAM_DELETE", it);
	for left broadcast(s, "VOICE_STATE_UPDATE", it);
}

// kick_locked closes the voice WebSockets of user (0: anyone) in room (0: any), whose threads then end their
// sessions.
kick_locked :: (s: *Server, user: s64, room: s64 = 0) {
	for s.voice_sessions if (!user || it.user == user) && (!room || it.room == room) netio.shutdown(netio.tcp_stream(it.conn.tcp));
}

// end_locked closes vs's member's voice connections and ends their stream, the viewers' too. It returns the
// STREAM_DELETE to send, or null.
end_locked :: (s: *Server, vs: *Voice_State) -> etf.Value {
	kick_locked(s, vs.user);
	if !vs.stream return .{};
	kick_locked(s, 0, vs.stream);
	vs.stream = 0;
	return stream_value(s, vs);
}

// stream_value is {stream_key} for vs's stream, as the client names it, with its room unless it ended.
stream_value :: (s: *Server, vs: *Voice_State) -> etf.Value {
	m := etf.map_builder(5,, temp);
	etf.map_put(*m, "stream_key", etf.vstring(tprint("guild:%:%:%", s.guild, vs.channel, vs.user)));
	if vs.stream {
		etf.map_put(*m, "rtc_server_id", snow(vs.stream));
		etf.map_put(*m, "region", etf.vstring("fastcord"));
		etf.map_put(*m, "viewer_ids", etf.vlist(.[]));
		etf.map_put(*m, "paused", etf.vbool(false));
	}
	return etf.vmap(etf.map_done(*m));
}

// Go Live: gateway ops 18 STREAM_CREATE {channel_id} for the caller's own stream in their voice channel, 20
// STREAM_WATCH {stream_key} for one in theirs, and 19 STREAM_DELETE {stream_key}, which ends the caller's
// own stream or stops watching another's. Both of the first answer STREAM_CREATE and STREAM_SERVER_UPDATE.
stream_op :: (c: *Conn, op: int, d: etf.Value) {
	s := c.server;
	if d.kind != .Map return;
	key, _ := etf.map_get(d.map, "stream_key");
	ch, _ := etf.map_get(d.map, "channel_id");
	created, server, gone, state: etf.Value;
	{
		locks.guard(*s.voice_mu);
		me, streamer: *Voice_State;
		for * s.voice_states if it.user == c.user && it.gateway == c me = it;
		if !me return;
		if op == 18 {
			if ch.kind != .String || ch.s != tprint("%", me.channel) return;
			if !me.stream {
				me.stream = snowflake(s);
				crypto.random_bytes(me.stream_token);
				state = voice_state_value(s, me);
			}
			streamer = me;
		} else {
			parts := ifx key.kind == .String then split(key.s, ":",, temp) else .[];
			if parts.count != 4 || parts[0] != "guild" || parts[1] != tprint("%", s.guild) || parts[2] != tprint("%", me.channel) return;
			for * s.voice_states if it.stream && parts[3] == tprint("%", it.user) && it.channel == me.channel streamer = it;
			if !streamer return;
			if op == 19 {
				if streamer != me {
					kick_locked(s, me.user, streamer.stream);
					gone = stream_value(s, streamer);
				} else {
					kick_locked(s, 0, me.stream);
					me.stream = 0;
					gone, state = stream_value(s, me), voice_state_value(s, me);
				}
			}
		}
		if op != 19 {
			created = stream_value(s, streamer);
			m := etf.map_builder(4,, temp);
			etf.map_put(*m, "stream_key", etf.map_get(created.map, "stream_key"));
			etf.map_put(*m, "token", etf.vstring(hex(streamer.stream_token,, temp)));
			etf.map_put(*m, "guild_id", snow(s.guild));
			etf.map_put(*m, "endpoint", etf.vstring(id_hex(s)));
			server = etf.vmap(etf.map_done(*m));
		}
	}
	if created.kind == .Map {
		dispatch(c, "STREAM_CREATE", created);
		dispatch(c, "STREAM_SERVER_UPDATE", server);
	}
	// A viewer who stops watching is the only one to hear of it; the end of a stream goes to everyone.
	if gone.kind == .Map && state.kind != .Map dispatch(c, "STREAM_DELETE", gone);
	else if gone.kind == .Map broadcast(s, "STREAM_DELETE", gone);
	if state.kind == .Map broadcast(s, "VOICE_STATE_UPDATE", state);
}

// The voice gateway, upgraded from GET /?v=9. Identify must match a voice state's token and session.
voice_gateway :: (c: *Conn, req: http.Request) {
	s := c.server;
	key, has_key := http.header_get(req.headers, "sec-websocket-key");
	if !has_key { http.h1_write_response(c.s, 400, .[], .[]); return; }
	headers := http.Header.[.{"Upgrade", "websocket"}, .{"Connection", "Upgrade"}, .{"Sec-WebSocket-Accept", http.ws_accept_for_key(key,, temp)}];
	if http.h1_write_response(c.s, 101, headers, .[], "Switching Protocols") != .None return;
	netio.set_timeout(c.s, VOICE_HEARTBEAT_MS * 2);
	ws := http.ws_attach(c.s, .{server = true, max_message = 64 << 10});
	c.out_ws, c.text = ws, true;
	c.writer = spawn(c, writer);
	vs: *Voice_Session;
	defer {
		if vs voice_session_end(s, vs);
		end_writer(c, ws);
	}
	voice_send(c, tprint("{\"op\":8,\"d\":{\"v\":8,\"heartbeat_interval\":%}}", VOICE_HEARTBEAT_MS));
	msg: [..]u8;
	defer array_free(msg);
	while true {
		reset_temporary_storage();
		msg.count = 0;
		type, err := http.ws_recv(ws, *msg);
		if err != .None return;
		if type != .Text continue; // DAVE's binary ops: serve runs no DAVE yet.
		v, jerr := etf.from_json(cast(string) msg,, temp);
		if jerr != .None || v.kind != .Map { http.ws_close(ws, 4002, "Failed to decode payload."); return; }
		op, _ := etf.map_get(v.map, "op");
		d, _ := etf.map_get(v.map, "d");
		field :: (d: etf.Value, k: string) -> etf.Value { if d.kind != .Map return .{}; f, _ := etf.map_get(d.map, k); return f; }
		if op.kind != .Int { http.ws_close(ws, 4001, "Unknown opcode."); return; }
		if !vs && op.i != OP_IDENTIFY && op.i != OP_HEARTBEAT { http.ws_close(ws, 4003, "Not authenticated."); return; }
		if op.i == {
			case OP_IDENTIFY;
				if vs { http.ws_close(ws, 4005, "Already authenticated."); return; }
				vs = voice_identify(c, field(d, "server_id"), field(d, "user_id"), field(d, "session_id"), field(d, "token"));
				if !vs { http.ws_close(ws, 4004, "Authentication failed."); return; }
			case OP_HEARTBEAT;
				t := field(d, "t");
				voice_send(c, tprint("{\"op\":6,\"d\":{\"t\":%}}", ifx t.kind == .Int then t.i else 0));
			case OP_SELECT_PROTOCOL;
				data := field(d, "data");
				mode_v: etf.Value;
				if data.kind == .Map mode_v, _ = etf.map_get(data.map, "mode");
				mode := ifx mode_v.kind == .String then mode_from_name(mode_v.s) else .None;
				if mode == .None { http.ws_close(ws, 4016, "Unknown encryption mode."); return; }
				key: [32]u8;
				crypto.random_bytes(key);
				{
					locks.guard(*s.voice_mu);
					transport_init(*vs.tc, mode, key);
					vs.mode = mode;
				}
				b: String_Builder;
				for key print_to_builder(*b, ifx it_index then ",%" else "%", it);
				crypto.zero(*key);
				id: [16]u8;
				crypto.random_bytes(id);
				// H.264 is the codec every fastcord can send and show, so a call never needs a second.
				voice_send(c, tprint("{\"op\":4,\"d\":{\"mode\":\"%\",\"secret_key\":[%],\"audio_codec\":\"opus\",\"video_codec\":\"H264\",\"media_session_id\":\"%\",\"dave_protocol_version\":0}}",
					mode_name(mode), builder_to_string(*b,, temp), hex(id,, temp)));
			case OP_SPEAKING;
				sp := field(d, "speaking");
				locks.lock(*s.voice_mu);
				vs.speaking = ifx sp.kind == .Int then sp.i & SPEAKING_FLAGS else 0;
				room_send(s, vs, speaking_text(vs));
				locks.unlock(*s.voice_mu);
			case OP_VIDEO;
				on := false;
				streams := field(d, "streams");
				if streams.kind == .List for streams.list if it.kind == .Map {
					a, _ := etf.map_get(it.map, "active");
					if a.kind == .Bool && a.b on = true;
				}
				locks.lock(*s.voice_mu);
				vs.video = on;
				room_send(s, vs, video_text(vs));
				locks.unlock(*s.voice_mu);
			case OP_RESUME; // Sessions don't outlive their socket: the client connects again.
				http.ws_close(ws, 4006, "Session is no longer valid.");
				return;
		}
	}
}

voice_send :: (c: *Conn, text: string) {
	locks.guard(*c.mu);
	queue(c, cast([]u8) text);
}

// room_send queues text to everyone else in vs's room; voice_mu is held.
room_send :: (s: *Server, vs: *Voice_Session, text: string) {
	for s.voice_sessions if it != vs && it.room == vs.room voice_send(it.conn, text);
}

speaking_text :: (vs: *Voice_Session) -> string {
	return tprint("{\"op\":5,\"d\":{\"user_id\":\"%\",\"ssrc\":%,\"speaking\":%}}", vs.user, vs.ssrc, vs.speaking);
}

video_text :: (vs: *Voice_Session) -> string {
	v, r := ifx vs.video then vs.ssrc + 1 else 0, ifx vs.video then vs.ssrc + 2 else 0;
	return tprint("{\"op\":12,\"d\":{\"user_id\":\"%\",\"audio_ssrc\":%,\"video_ssrc\":%,\"rtx_ssrc\":%,\"streams\":[{\"type\":\"video\",\"rid\":\"100\",\"ssrc\":%,\"rtx_ssrc\":%,\"active\":%,\"quality\":100}]}}",
		vs.user, vs.ssrc, v, r, vs.ssrc + 1, vs.ssrc + 2, vs.video);
}

voice_identify :: (c: *Conn, server_id: etf.Value, user_id: etf.Value, session_id: etf.Value, token: etf.Value) -> *Voice_Session {
	s := c.server;
	if server_id.kind != .String || user_id.kind != .String || session_id.kind != .String || token.kind != .String return null;
	user, ok := string_to_int(user_id.s, T = s64);
	if !ok return null;
	locks.guard(*s.voice_mu);
	mine: *Voice_State;
	for * s.voice_states if it.user == user && session_id.s == hex(it.gateway.session,, temp) mine = it;
	if !mine || s.voice_sessions.count >= MAX_VOICE_SESSIONS || !s.udp return null;
	// The guild's ID for the voice channel itself; a stream's room for Go Live, where any viewer's voice state
	// must be in the stream's channel.
	room: s64;
	if server_id.s == tprint("%", s.guild) {
		if constant_time_hex(token.s, mine.token) room = mine.channel;
	} else {
		for s.voice_states if it.stream && server_id.s == tprint("%", it.stream) && it.channel == mine.channel && constant_time_hex(token.s, it.stream_token) room = it.stream;
	}
	if !room return null;
	vs := New(Voice_Session);
	vs.conn, vs.user, vs.room = c, user, room;
	// Four SSRCs apart, so a member's audio, camera and retransmissions never meet another's.
	while true {
		b: [4]u8;
		crypto.random_bytes(b);
		vs.ssrc = get_u32(b) & ~cast(u32) 3;
		taken := !vs.ssrc;
		for s.voice_sessions if it.ssrc == vs.ssrc taken = true;
		if !taken break;
	}
	array_add(*s.voice_sessions, vs);
	atomic_store(*c.authed, true);
	// The client sends media to the invite's address, so READY's ip is unused.
	voice_send(c, tprint("{\"op\":2,\"d\":{\"ssrc\":%,\"ip\":\"\",\"port\":%,\"modes\":%,\"experiments\":[],\"streams\":[{\"type\":\"video\",\"rid\":\"100\",\"ssrc\":%,\"rtx_ssrc\":%,\"quality\":100,\"active\":false}]}}",
		vs.ssrc, s.udp.port, VOICE_MODES, vs.ssrc + 1, vs.ssrc + 2));
	// Everyone learns who is here and whose SSRCs are whose before any media arrives.
	others: [..]string;
	others.allocator = temp;
	for s.voice_sessions if it != vs && it.room == vs.room {
		array_add(*others, tprint("\"%\"", it.user));
		voice_send(c, video_text(it));
		if it.speaking voice_send(c, speaking_text(it));
	}
	if others.count voice_send(c, tprint("{\"op\":11,\"d\":{\"user_ids\":[%]}}", join(..others, ",")));
	room_send(s, vs, tprint("{\"op\":11,\"d\":{\"user_ids\":[\"%\"]}}", vs.user));
	room_send(s, vs, video_text(vs));
	return vs;
}

constant_time_hex :: (text: string, want: [16]u8) -> bool {
	got: [16]u8;
	return unhex(text, got) && crypto.constant_time_equal(got, want);
}

voice_session_end :: (s: *Server, vs: *Voice_Session) {
	locks.guard(*s.voice_mu);
	array_unordered_remove_by_value(*s.voice_sessions, vs);
	room_send(s, vs, tprint("{\"op\":13,\"d\":{\"user_id\":\"%\"}}", vs.user));
	transport_reset(*vs.tc);
	free(vs);
}

// voice_udp answers IP discovery and forwards media until stop.
voice_udp :: (s: *Server) {
	buf, plain, sealed: [2048]u8;
	while !atomic_load(*s.udp_stop) {
		reset_temporary_storage();
		n, addr, port := netio.udp_recv(s.udp, buf);
		if n <= 0 || n > 1500 continue;
		pkt := array_view(buf, 0, n);
		if n == DISCOVERY_LEN && get_u16(pkt) == 1 {
			ssrc := get_u32(pkt, 4);
			known := false;
			{
				locks.guard(*s.voice_mu);
				for s.voice_sessions if it.ssrc == ssrc && (!it.proven || (it.port == port && memcmp(it.addr.data, addr.data, 16) == 0)) {
					it.addr, it.port, known = addr, port, true;
				}
			}
			if !known continue;
			resp: [DISCOVERY_LEN]u8;
			build_discovery_response(resp, ssrc, ip_text(addr), cast(u16) port);
			netio.udp_send(s.udp, resp, addr, port);
			continue;
		}
		sender: u32;
		aad: int;
		if is_rtcp(pkt) {
			sender, aad = get_u32(pkt, 4), 8;
		} else {
			h, ok := parse_rtp_header(pkt);
			if !ok continue;
			sender, aad = h.ssrc, h.aad_len;
		}
		locks.guard(*s.voice_mu);
		vs: *Voice_Session;
		for s.voice_sessions if it.ssrc == (sender & ~cast(u32) 3) && it.mode != .None vs = it;
		if !vs continue;
		m, ok := transport_open(*vs.tc, pkt, aad, plain);
		if !ok continue;
		vs.addr, vs.port, vs.proven = addr, port, true;
		second := now_ms(s) / 1000;
		if second != vs.window_ms vs.window_ms, vs.window_packets, vs.window_bytes = second, 0, 0;
		vs.window_packets += 1;
		vs.window_bytes += n;
		if vs.window_packets > MAX_MEDIA_PACKETS || vs.window_bytes > MAX_MEDIA_BYTES continue;
		for s.voice_sessions if it != vs && it.room == vs.room && it.mode != .None && it.port {
			sl := transport_seal(*it.tc, array_view(plain, 0, m), aad, it.nonce, sealed);
			it.nonce += 1;
			if sl netio.udp_send(s.udp, array_view(sealed, 0, sl), it.addr, it.port);
		}
	}
}

// ip_text writes a 16-byte address as IP discovery reports it: dotted for IPv4.
ip_text :: (a: [16]u8) -> string {
	if memcmp(a.data, IPV4_MAPPED.data, IPV4_MAPPED.count) == 0 return tprint("%.%.%.%", a[12], a[13], a[14], a[15]);
	parts: [8]string;
	for * parts it.* = tprint("%", formatInt(((cast(int) a[2 * it_index]) << 8) | a[2 * it_index + 1], base = 16));
	return tprint("%:%:%:%:%:%:%:%", parts[0], parts[1], parts[2], parts[3], parts[4], parts[5], parts[6], parts[7]);
}
