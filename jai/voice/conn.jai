// Voice_Server_Info: everything src/discord learns from the main gateway.
//   endpoint:            VOICE_SERVER_UPDATE.endpoint ("c-lax07-200a12c1.discord.media:2096"; port optional, default 443)
//   token:               VOICE_SERVER_UPDATE.token
//   guild_or_channel_id: VOICE_SERVER_UPDATE.guild_id, or for DM/group calls the call's channel_id (sent as server_id)
//   user_id:             our user id
//   session_id:          our VOICE_STATE_UPDATE.session_id (= main gateway session id)
//   channel_id:          the voice channel / DM channel id
Voice_Server_Info :: struct {
	endpoint: string;
	token: string;
	guild_or_channel_id: u64;
	user_id: u64;
	session_id: string;
	channel_id: u64;
	stage: bool; // stage channel (allows DAVE version 0)
	user_agent: string; // "" = official desktop UA
	accept_language: string; // "" = "en-US"
}

Conn_State :: enum u8 {
	Connecting; // dialing the voice gateway
	Identifying; // IDENTIFY sent, waiting for READY
	Discovering; // UDP IP discovery / SELECT_PROTOCOL
	Connected; // SESSION_DESCRIPTION received, media flowing
	Resuming; // reconnecting with RESUME
	Disconnected; // terminal; see close_code
}

Dial_Proc :: #type (host: string, port: int) -> netio.Stream, bool;

Options :: struct {
	dial: Dial_Proc; // nil = TCP + TLS (ALPN http/1.1, SNI = host)
	no_audio_devices: bool; // don't touch fc:audio (tests / headless)
	capture: (data: *void, out: []float32) -> int; // mono 48 kHz pull, used when no_audio_devices
	playback: (data: *void, user_id: u64, pcm: []float32); // stereo interleaved, 960 frames
	callback_data: *void;
	vad_manual: bool; // manual threshold instead of auto
	vad_threshold_db: float32; // manual threshold (0 = -60 dB default)
}

Stats :: struct {
	ws_ping_ms: int;
	rtt_ms: int; // from RTCP receiver reports about our stream
	packets_sent: u64;
	packets_received: u64;
	bytes_sent: u64;
	bytes_received: u64;
	transport_failures: u64;
	udp_datagrams: u64; // everything that arrived on the socket
	rtcp_received: u64;
	other_pt: u64; // RTP with a payload type other than opus
	unknown_ssrc: u64; // audio from an SSRC no op 5 mapped yet
	remote_users: int;
	e2ee_failures: u64;
	reconnects: int;
	jitter: Jitter_Stats; // summed over remote users
}

User_Settings :: struct {
	volume: float32; // 0..2, 1 = unchanged
	muted: bool;
}

Rx_Stats :: struct {
	base_seq, max_seq: u16;
	cycles: u32;
	received: u32;
	expected_prior: u32;
	received_prior: u32;
	transit: s64;
	jitter: float64; // in timestamp units
	lsr: u32;
	lsr_at_ms: s64;
	init: bool;
}

Remote_User :: struct {
	user_id: u64;
	ssrc: u32;
	speaking_flag: int; // from op 5
	last_voice_ms: s64;
	jb: Jitter_Buffer;
	decoder: *void;
	source: audio.Source;
	rx: Rx_Stats;
}

Conn :: struct {
	info: Voice_Server_Info;
	opts: Options;
	host: string;
	port: int;
	rtc_connection_id: string;
	mu: locks.Mutex; // users, stats, state
	ws_mu: locks.Mutex; // ws pointer + sends
	state: Conn_State;
	close_code: int;
	stop: bool; // atomic
	state_cond: locks.Cond;

	ws: *http.Ws_Conn;
	ws_stream: netio.Stream;
	ws_open: bool;
	server_version: int;
	hb_interval_ms: s64;
	next_hb_ms: s64;
	hb_acked: bool;
	last_ack_ms: s64;
	hello_deadline_ms: s64;
	hb_mu: locks.Mutex; // heartbeat fields above (gateway <-> timer thread)
	session_ok: bool; // READY/RESUMED seen on the current socket (backoff.succeed)
	last_seq: s64;
	resumable: bool;

	udp: net.UDP_Socket;
	udp_open: bool;
	server_ep: net.Endpoint;
	ssrc: u32;
	mode: Mode;
	tx_crypto: Transport_Crypto;
	rx_crypto: Transport_Crypto;
	have_key: bool;
	tx_nonce: u32;
	experiments: [..]string;
	external_ip: string;
	external_port: int;

	dave: DAVE.Session;
	users: Map(u32, *Remote_User);
	user_ssrc: Map(u64, u32);
	settings: Map(u64, User_Settings);
	self_mute: bool;
	self_deaf: bool;
	self_speaking: bool;

	codec: Codec;
	encoder: *void;
	vad: Vad;
	seq: u16;
	ts: u32;
	packets_sent: u32;
	octets_sent: u32;
	last_sent_ts: u32;
	preroll: [VAD_DEFAULT_LEADING][SAMPLES_PER_FRAME]float32;
	preroll_n: int;
	silence_left: int;
	next_rtcp_ms: s64;
	stats: Stats;

	ws_th, timer_th, udp_th, audio_th: *thread.Thread;
	udp_started: bool;
	audio_started: bool;
	capture_on: bool;
	input_gain: float32; // software input volume (1 = unchanged)
	input_db: float32; // level of the last mic frame (after gain)
	vad_open: bool;
	ptt_mode: bool; // push-to-talk instead of voice activity
	ptt_pressed: bool;
	ptt_until_ms: s64; // release delay end
	allocator: Allocator; // long-lived allocations from every thread
	debug: bool; // FASTCORD_VOICE_DEBUG=1: protocol trace on stderr (no secrets)
}
#scope_module

dbg :: (c: *Conn, format: string, args: ..Any) {
	if !c.debug { return; }
	fmt.eprintf("[voice %v] ", c.info.user_id);
	fmt.eprintfln(format, ..args);
}
#scope_export

now_ms :: () -> s64 {return time.to_unix_nanoseconds(time.now()) / 1000000;}
#scope_module

stopped :: (c: *Conn) -> bool {return atomic_load(*c.stop);}

set_state :: (c: *Conn, s: Conn_State) {
	locks.lock(*c.mu);
	c.state = s;
	locks.cond_broadcast(*c.state_cond);
	locks.unlock(*c.mu);
}
#scope_export

// ---------------------------------------------------------------------------
// Public API

voice_connect :: (info: Voice_Server_Info, opts := Options.{}) -> *Conn {
	c := new(Conn);
	c.info = info;
	c.info.endpoint = clone(info.endpoint);
	c.info.token = clone(info.token);
	c.info.session_id = clone(info.session_id);
	c.info.user_agent = clone(ifx info.user_agent != "" then info.user_agent else DEFAULT_USER_AGENT);
	c.info.accept_language = clone(ifx info.accept_language != "" then info.accept_language else "en-US");
	c.opts = opts;
	c.host, c.port = split_endpoint(c.info.endpoint);
	c.rtc_connection_id = uuid4();
	c.users = Map(u32, *Remote_User).{};
	c.user_ssrc = Map(u64, u32).{};
	c.settings = Map(u64, User_Settings).{};
	c.experiments = make_dynamic(string, 0, 0);
	c.last_seq = -1;
	c.input_gain = 1;
	c.input_db = -127;
	c.codec = get_codec();
	c.encoder = c.codec.encoder_create();
	vad_init(*c.vad);
	if opts.vad_manual {
		c.vad.auto_threshold = false;
		if opts.vad_threshold_db != 0 { c.vad.threshold_db = opts.vad_threshold_db; }
	}
	// WebRTC randomizes the initial sequence number and timestamp
	rb: [6]u8;
	crypto.rand_bytes(view(rb));
	c.seq = ((cast(u16)(rb[0])) << 8) | (cast(u16)(rb[1]));
	c.ts = get_u32(sub_from(rb, 2));
	DAVE.session_init(*c.dave, info.user_id, info.channel_id, info.stage);
	c.state = .Connecting;
	c.allocator = context.allocator;
	c.debug = os.get_env("FASTCORD_VOICE_DEBUG", temp) == "1";
	c.ws_th = thread.create_and_start_with_data(c, ws_thread_proc);
	c.timer_th = thread.create_and_start_with_data(c, timer_thread_proc);
	return c;
}

// voice_disconnect closes the gateway (code 4000, as the client's close()),
// stops all threads and frees the connection.
voice_disconnect :: (c: *Conn) {
	if c == null { return; }
	atomic_store(*c.stop, true);
	locks.lock(*c.ws_mu);
	if c.ws != null && c.ws_open {
		http.ws_close(c.ws, CLOSE_FORCE, "");
		netio.shutdown(c.ws_stream);
	}
	locks.unlock(*c.ws_mu);
	// The ws thread starts udp_th and audio_th, so read those handles only after it has exited.
	locks.join(c.ws_th);
	for th: (*thread.Thread.[c.timer_th, c.udp_th, c.audio_th]) {
		if th != null {
			locks.join(th);
		}
	}
	if c.capture_on { audio.capture_stop(); }
	if c.udp_open { net.close(c.udp); }
	transport_reset(*c.tx_crypto);
	transport_reset(*c.rx_crypto);
	for _, u: c.users { destroy_user(c, u); }
	delete(c.users);
	delete(c.user_ssrc);
	delete(c.settings);
	for e: c.experiments { delete(e); }
	delete(c.experiments);
	delete(c.external_ip);
	c.codec.encoder_destroy(c.encoder);
	DAVE.session_destroy(*c.dave);
	delete(c.info.endpoint);
	delete(c.info.token);
	delete(c.info.session_id);
	delete(c.info.user_agent);
	delete(c.info.accept_language);
	delete(c.rtc_connection_id);
	free(c);
}

state :: (c: *Conn) -> Conn_State, int {
	locks.lock(*c.mu);
	defer locks.unlock(*c.mu);
	return c.state, c.close_code;
}

// wait_state blocks until the connection reaches s (or Disconnected) or timeout.
wait_state :: (c: *Conn, s: Conn_State, timeout: time.Duration) -> bool {
	deadline := time.tick_now()._nsec + cast(s64)(timeout);
	locks.lock(*c.mu);
	defer locks.unlock(*c.mu);
	while c.state != s && c.state != .Disconnected {
		left := deadline - time.tick_now()._nsec;
		if left <= 0 { break; }
		locks.cond_wait_with_timeout(*c.state_cond, *c.mu, (cast(time.Duration) (left)));
	}
	return c.state == s;
}

set_self_mute :: (c: *Conn, muted: bool) {
	locks.lock(*c.mu);
	c.self_mute = muted;
	locks.unlock(*c.mu);
}

// set_self_deaf: deafened implies no playout and no sending (like the client).
set_self_deaf :: (c: *Conn, deaf: bool) {
	locks.lock(*c.mu);
	c.self_deaf = deaf;
	if deaf { for _, u: c.users { if u.source != 0 { audio.source_flush(u.source); } } }
	locks.unlock(*c.mu);
}

set_user_volume :: (c: *Conn, user_id: u64, volume: float32) {
	locks.lock(*c.mu);
	s := or_else(map_find(c.settings, user_id), User_Settings.{volume = 1});
	s.volume = clamp(volume, 0, 2);
	at(*c.settings, user_id).* = s;
	locks.unlock(*c.mu);
}

set_user_mute :: (c: *Conn, user_id: u64, muted: bool) {
	locks.lock(*c.mu);
	s := or_else(map_find(c.settings, user_id), User_Settings.{volume = 1});
	s.muted = muted;
	at(*c.settings, user_id).* = s;
	locks.unlock(*c.mu);
}

// set_input_sensitivity: auto threshold (the client's default) or a manual dB threshold.
set_input_sensitivity :: (c: *Conn, auto_threshold: bool, threshold_db: float32) {
	locks.lock(*c.mu);
	c.vad.auto_threshold = auto_threshold;
	c.vad.threshold_db = threshold_db;
	locks.unlock(*c.mu);
}

// set_push_to_talk: PTT mode transmits only while pressed (+ release delay,
// the client's pttReleaseDelay default 20 ms) instead of on voice activity.
set_push_to_talk :: (c: *Conn, enabled: bool, pressed: bool, release_delay_ms := 20) {
	locks.lock(*c.mu);
	defer locks.unlock(*c.mu);
	c.ptt_mode = enabled;
	if c.ptt_pressed && !pressed { c.ptt_until_ms = now_ms() + cast(s64)(release_delay_ms); }
	c.ptt_pressed = pressed;
}

// set_input_gain: input volume, 0..2 (Settings > Voice > Input Volume).
set_input_gain :: (c: *Conn, gain: float32) {
	locks.lock(*c.mu);
	c.input_gain = clamp(gain, 0, 2);
	locks.unlock(*c.mu);
}

// input_level: last mic frame level in dBFS and whether the VAD is open (for meters).
input_level :: (c: *Conn) -> float32, bool {
	db: float32;
	open: bool;
	locks.lock(*c.mu);
	defer locks.unlock(*c.mu);
	return c.input_db, c.vad_open;
}

SPEAKING_HOLD_MS :: 250;

// speaking_users: users heard within the last 250 ms (and ourselves while
// our VAD is open and we are not muted).
speaking_users :: (c: *Conn, allocator := context.allocator) -> []u64 {
	locks.lock(*c.mu);
	defer locks.unlock(*c.mu);
	now := now_ms();
	out := make_dynamic(u64, 0, len(c.users) + 1, allocator);
	if c.self_speaking { append(*out, c.info.user_id); }
	for _, u: c.users {
		if u.user_id != 0 && now - u.last_voice_ms < SPEAKING_HOLD_MS { append(*out, u.user_id); }
	}
	return view(out);
}

is_speaking :: (c: *Conn, user_id: u64) -> bool {
	ids := speaking_users(c, temp);
	for id: ids { if id == user_id { return true; } }
	return false;
}

get_stats :: (c: *Conn) -> Stats {
	locks.lock(*c.mu);
	defer locks.unlock(*c.mu);
	s := c.stats;
	s.remote_users = len(c.users);
	s.jitter = .{};
	for _, u: c.users {
		js := u.jb.stats;
		s.jitter.received += js.received;
		s.jitter.late += js.late;
		s.jitter.lost += js.lost;
		s.jitter.concealed += js.concealed;
		s.jitter.fec_recovered += js.fec_recovered;
		s.jitter.dropped += js.dropped;
		s.jitter.jitter_ms = max(s.jitter.jitter_ms, js.jitter_ms);
		s.jitter.target_frames = max(s.jitter.target_frames, js.target_frames);
	}
	ds := DAVE.session_status(*c.dave, temp);
	s.e2ee_failures = ds.stats.decrypt_failures;
	return s;
}

// E2EE status: privacy code is the 30-digit voice privacy code ("" when the
// call is not end-to-end encrypted).
E2EE_Status :: struct {
	protocol_version: int;
	active: bool;
	epoch: u64;
	privacy_code: string;
	members: int;
}

e2ee_status :: (c: *Conn, allocator := context.allocator) -> E2EE_Status {
	ds := DAVE.session_status(*c.dave, allocator);
	return E2EE_Status.{ds.protocol_version, ds.e2ee_active, ds.epoch, ds.privacy_code, ds.members};
}

privacy_code :: (c: *Conn, allocator := context.allocator) -> string {
	return e2ee_status(c, allocator).privacy_code;
}

// verification_code: 45-digit pairwise identity fingerprint with user (slow: scrypt).
verification_code :: (c: *Conn, user_id: u64, allocator := context.allocator) -> string, bool {
	{ __r1, __r2 := DAVE.session_verification_code(*c.dave, user_id, allocator); return __r1, __r2; }
}
#scope_module

// ---------------------------------------------------------------------------
// Gateway thread

split_endpoint :: (ep: string) -> string, int {
	host: string;
	port: int;
	e := ep;
	if strings.has_prefix(e, "wss://") { e = sub_from(e, 6); }
	{ i := strings.index_byte(e, #char "/");
	if i >= 0 { e = sub(e, 0, i); } }
	{ i := strings.last_index_byte(e, #char ":");
	if i >= 0 {
		{ p, ok := strconv.parse_int(sub_from(e, i + 1));
		if ok { return sub(e, 0, i), p; } }
	} }
	return e, 443;
}

default_dial :: (host: string, port: int) -> netio.Stream, bool {
	tcp, err := netio.dial_tcp(host, port);
	if err != .None { return .{}, false; }
	under := netio.tcp_stream(tcp);
	sess, terr := tls.connect(under, tls.Config.{alpn = string.["http/1.1"], server_name = host});
	if terr != .None {
		netio.close(under);
		return .{}, false;
	}
	return tls.stream(sess), true;
}
#scope_export

// voice_ws_headers: Chrome's WebSocket upgrade request, header order as captured.
voice_ws_headers :: (c: *Conn) -> []http.Header {
	host := ifx c.port == 443 then c.host else strings.concatenate(string.[c.host, ":", snowflake(cast(u64)(c.port))], temp);
	h := make_dynamic(http.Header, 0, 12, temp);
	append(*h, http.Header.{"Host", host});
	append(*h, http.Header.{"Connection", "Upgrade"});
	append(*h, http.Header.{"Pragma", "no-cache"});
	append(*h, http.Header.{"Cache-Control", "no-cache"});
	append(*h, http.Header.{"User-Agent", c.info.user_agent});
	append(*h, http.Header.{"Upgrade", "websocket"});
	append(*h, http.Header.{"Origin", "https://discord.com"});
	append(*h, http.Header.{"Sec-WebSocket-Version", "13"});
	append(*h, http.Header.{"Accept-Encoding", "gzip, deflate, br, zstd"});
	append(*h, http.Header.{"Accept-Language", c.info.accept_language});
	append(*h, http.Header.{"Sec-WebSocket-Key", ""});
	append(*h, http.Header.{"Sec-WebSocket-Extensions", "permessage-deflate; client_max_window_bits"});
	return view(h);
}
#scope_module

send_text :: (c: *Conn, s: string) -> bool {
	locks.lock(*c.ws_mu);
	defer locks.unlock(*c.ws_mu);
	if c.ws == null || !c.ws_open { return false; }
	return http.ws_send(c.ws, .Text, transmute([]u8, s)) == .None;
}

send_binary :: (c: *Conn, op: int, payload: []u8) -> bool {
	buf := make_slice(u8, len(payload) + 1, temp);
	buf[0] = cast(u8)(op);
	copy(sub_from(buf, 1), payload);
	locks.lock(*c.ws_mu);
	defer locks.unlock(*c.ws_mu);
	if c.ws == null || !c.ws_open { return false; }
	return http.ws_send(c.ws, .Binary, buf) == .None;
}

close_ws :: (c: *Conn, code: int) {
	locks.lock(*c.ws_mu);
	defer locks.unlock(*c.ws_mu);
	if c.ws != null && c.ws_open {
		http.ws_close(c.ws, code, "");
		netio.shutdown(c.ws_stream);
	}
}

terminal_close :: (code: int) -> bool {
	if code == {
	case CLOSE_AUTHENTICATION_FAILED; #through; case CLOSE_INVALID_SESSION; #through; case CLOSE_SERVER_NOT_FOUND; #through; case CLOSE_SERVER_CRASH; #through; case CLOSE_DISCONNECTED; #through; case CLOSE_CALL_TERMINATED; #through; case CLOSE_REPEATED_MLS_INVALID; #through; case CLOSE_DAVE_DOWNGRADE_REFUSED; #through; case CLOSE_DAVE_INVALID_MESSAGE; #through; case CLOSE_UNRESUMABLE;
		return true;
	}
	return false;
}

ws_thread_proc :: (data: *void) {
	c := cast(*Conn)data;
	push_allocator(c.allocator);
	fails := 0;
	resuming := false;
	while !stopped(c) {
		code := ws_session(c, resuming);
		reset_temporary_storage();
		if stopped(c) { break; }
		if terminal_close(code) {
			finish(c, code);
			return;
		}
		// RTCControlSocket.handleClose: backoff (1 s .. 5 s), give up after 4 failures
		if c.session_ok { fails = 0; }
		c.session_ok = false;
		locks.lock(*c.hb_mu);
		last_ack := c.last_ack_ms;
		locks.unlock(*c.hb_mu);
		if fails > 3 || !c.resumable || (last_ack != 0 && now_ms() - last_ack > 60_000) {
			finish(c, ifx code == 0 || !c.resumable then CLOSE_UNRESUMABLE else code);
			return;
		}
		delay := min(1000 << (cast(u64)(fails)), 5000);
		fails += 1;
		resuming = true;
		set_state(c, .Resuming);
		locks.lock(*c.mu);
		c.stats.reconnects += 1;
		locks.unlock(*c.mu);
		{ i := 0;
		while i < delay / 50 && !stopped(c) { time.sleep(50 * time.Millisecond);  i += 1; } }
	}
}

finish :: (c: *Conn, code: int) {
	locks.lock(*c.mu);
	c.close_code = code;
	c.state = .Disconnected;
	locks.cond_broadcast(*c.state_cond);
	locks.unlock(*c.mu);
	atomic_store(*c.stop, true);
}

// ws_session runs one WebSocket connection; returns the close code (0 = transport error).
ws_session :: (c: *Conn, resume: bool) -> int {
	if !resume { set_state(c, .Connecting); }
	dial: Dial_Proc = ifx c.opts.dial != null then c.opts.dial else default_dial;
	stream, ok := dial(c.host, c.port);
	if !ok { return 0; }
	req := http.Request.{
		method = "GET",
		scheme = "https",
		authority = c.host,
		path = "/?v=9",
		headers = voice_ws_headers(c)
	};
	ws, resp, err := http.ws_connect(stream, req);
	http.response_destroy(*resp);
	if err != .None {
		netio.close(stream);
		return 0;
	}
	netio.set_timeout(stream, 0);
	locks.lock(*c.ws_mu);
	c.ws = ws;
	c.ws_stream = stream;
	c.ws_open = true;
	// voice_disconnect found no socket to shut down while this one was connecting.
	if atomic_load(*c.stop) { netio.shutdown(stream); }
	locks.unlock(*c.ws_mu);
	locks.lock(*c.hb_mu);
	c.hello_deadline_ms = now_ms() + 20_000;
	c.hb_interval_ms = 0;
	locks.unlock(*c.hb_mu);
	if resume {
		send_text(c, msg_resume(c.info.token, c.info.session_id, c.info.guild_or_channel_id, c.info.channel_id, c.last_seq));
	} else {
		set_state(c, .Identifying);
		send_text(c, msg_identify(c.info.guild_or_channel_id, c.info.channel_id, c.info.user_id, c.info.session_id, c.info.token, true));
	}
	msg := make_dynamic(u8, 0, 0);
	defer delete(msg);
	code := 0;
	while !stopped(c) {
		mt, rerr := http.ws_recv(ws, *msg);
		if rerr != .None {
			if rerr == .Closed { code = ws.close_code; }
			break;
		}
		if mt == .Text {
			handle_json(c, as_string(view(msg)));
		} else {
			handle_binary(c, view(msg));
		}
		flush_dave(c);
		{ cr := DAVE.session_close_request(*c.dave);
		if cr != .None {
			code = CLOSE_REPEATED_MLS_INVALID + cast(int)(cr) - 1;
			close_ws(c, code);
			break;
		} }
		reset_temporary_storage();
	}
	locks.lock(*c.ws_mu);
	c.ws_open = false;
	c.ws = null;
	locks.unlock(*c.ws_mu);
	locks.lock(*c.hb_mu);
	c.hb_interval_ms = 0;
	c.hello_deadline_ms = 0;
	locks.unlock(*c.hb_mu);
	http.ws_destroy(ws);
	netio.close(stream);
	return code;
}

flush_dave :: (c: *Conn) {
	outs := DAVE.session_take_outgoing(*c.dave, temp);
	for o: outs {
		if o.op == {
		case DAVE.OP_MLS_KEY_PACKAGE; #through; case DAVE.OP_MLS_COMMIT_WELCOME;
			send_binary(c, o.op, o.data);
		case DAVE.OP_READY_FOR_TRANSITION; #through; case DAVE.OP_MLS_INVALID_COMMIT_WELCOME;
			send_text(c, msg_transition(o.op, o.transition_id));
		}
		delete(o.data);
	}
}

handle_json :: (c: *Conn, text: string) {
	v, err := json.parse_string(text, parse_integers = true, allocator = temp);
	if err != .None { return; }
	op := cast(int)(jint(jget(v, "op")));
	if c.debug && op != OP_HEARTBEAT_ACK && op != OP_SESSION_DESCRIPTION { dbg(c, "<~ %s", sub(text, 0, min(len(text), 400))); }
	{ s := jint(jget(v, "seq"), 0);
	if s != 0 { c.last_seq = s; } } // `r && (lastRecvSeqNum = r)`
	d := jget(v, "d");
	if op == {
	case OP_HELLO;
		c.server_version = cast(int)(jint(jget(d, "v"), 3));
		iv := jint(jget(d, "heartbeat_interval"), 13750);
		locks.lock(*c.hb_mu);
		c.hello_deadline_ms = 0;
		// desktop (isPlatformEmbedded): interval * modifier, no 5 s cap; v<=3: 25 %
		c.hb_interval_ms = ifx c.server_version <= 3 then iv / 4 else iv;
		c.hb_acked = true;
		c.next_hb_ms = now_ms() + c.hb_interval_ms;
		locks.unlock(*c.hb_mu);
	case OP_READY;
		on_ready(c, d);
	case OP_SESSION_DESCRIPTION;
		on_session_description(c, d);
	case OP_RESUMED;
		c.session_ok = true;
		set_state(c, .Connected);
	case OP_HEARTBEAT;
		send_heartbeat(c);
	case OP_HEARTBEAT_ACK;
		t := ifx c.server_version >= 8 then jint(jget(d, "t"), 0) else jint(d, 0);
		now := now_ms();
		locks.lock(*c.mu);
		c.stats.ws_ping_ms = cast(int)(now - t);
		locks.unlock(*c.mu);
		locks.lock(*c.hb_mu);
		c.last_ack_ms = now;
		c.hb_acked = true;
		locks.unlock(*c.hb_mu);
	case OP_SPEAKING;
		uid := jsnow(jget(d, "user_id"));
		ssrc := cast(u32)(jint(jget(d, "ssrc"), 0));
		flags := cast(int)(jint(jget(d, "speaking"), 0));
		if uid != 0 && ssrc != 0 {
			u := map_user(c, uid, ssrc);
			locks.lock(*c.mu);
			u.speaking_flag = flags;
			locks.unlock(*c.mu);
		}
	case OP_VIDEO;
		uid := jsnow(jget(d, "user_id"));
		ssrc := cast(u32)(jint(jget(d, "audio_ssrc"), 0));
		if uid != 0 && ssrc != 0 { map_user(c, uid, ssrc); }
	case OP_CLIENTS_CONNECT;
		ids := make_dynamic(u64, 0, 4, temp);
		for x: jarr(jget(d, "user_ids")) { append(*ids, jsnow(x)); }
		DAVE.on_clients_connect(*c.dave, view(ids));
	case OP_CLIENT_DISCONNECT;
		uid := jsnow(jget(d, "user_id"));
		DAVE.on_client_disconnect(*c.dave, uid);
		locks.lock(*c.mu);
		{ ssrc, ok := map_find(c.user_ssrc, uid);
		if ok {
			{ u, uok := map_find(c.users, ssrc);
			if uok {
				destroy_user(c, u);
				delete_key(*c.users, ssrc);
			} }
			delete_key(*c.user_ssrc, uid);
		} }
		locks.unlock(*c.mu);
	case DAVE.OP_PREPARE_TRANSITION;
		tid := jint(jget(d, "transition_id"));
		pv := jint(jget(d, "protocol_version"));
		if tid < 0 || tid > 65535 || pv < 0 || pv > 65535 {
			dave_invalid(c);
			return;
		}
		DAVE.on_prepare_transition(*c.dave, cast(int)(tid), cast(int)(pv));
	case DAVE.OP_EXECUTE_TRANSITION;
		tid := jint(jget(d, "transition_id"));
		if tid < 0 || tid > 65535 {
			dave_invalid(c);
			return;
		}
		DAVE.on_execute_transition(*c.dave, cast(int)(tid));
	case DAVE.OP_PREPARE_EPOCH;
		ep := jint(jget(d, "epoch"));
		pv := jint(jget(d, "protocol_version"));
		if ep < 0 || pv < 0 || pv > 65535 {
			dave_invalid(c);
			return;
		}
		DAVE.on_prepare_epoch(*c.dave, cast(u64)(ep), cast(int)(pv));
	case OP_SESSION_UPDATE; #through; case OP_MEDIA_SINK_WANTS; #through; case OP_VOICE_BACKEND_VERSION; #through; case OP_FLAGS; #through; case OP_PLATFORM; #through; case OP_SFU_UPDATE;
	// informational for an audio-only client
	}
}

dave_invalid :: (c: *Conn) {
	close_ws(c, CLOSE_DAVE_INVALID_MESSAGE);
	finish(c, CLOSE_DAVE_INVALID_MESSAGE);
}

handle_binary :: (c: *Conn, b: []u8) {
	// server binary frames: [seq u16][op u8][payload] (v8+)
	if len(b) < 3 {
		dave_invalid(c);
		return;
	}
	seq := cast(s64)(get_u16(b));
	if seq != 0 { c.last_seq = seq; }
	op := cast(int)(b[2]);
	p := sub_from(b, 3);
	dbg(c, "<~ binary op %d (%d bytes)", op, len(p));
	if op == {
	case DAVE.OP_MLS_EXTERNAL_SENDER;
		DAVE.on_external_sender(*c.dave, p);
	case DAVE.OP_MLS_PROPOSALS;
		DAVE.on_proposals(*c.dave, p);
	case DAVE.OP_MLS_ANNOUNCE_COMMIT; #through; case DAVE.OP_MLS_WELCOME;
		if len(p) < 2 {
			dave_invalid(c);
			return;
		}
		tid := cast(int)(get_u16(p));
		if op == DAVE.OP_MLS_ANNOUNCE_COMMIT {
			DAVE.on_announce_commit(*c.dave, tid, sub_from(p, 2));
		} else {
			DAVE.on_welcome(*c.dave, tid, sub_from(p, 2));
		}
	}
}

send_heartbeat :: (c: *Conn) {
	if c.server_version >= 8 {
		send_text(c, msg_heartbeat(now_ms(), c.last_seq));
	} else {
		send_text(c, strings.concatenate(string.["{\"op\":3,\"d\":", snowflake(cast(u64)(now_ms())), "}"], temp));
	}
}

on_ready :: (c: *Conn, d: json.Value) {
	c.ssrc = cast(u32)(jint(jget(d, "ssrc"), 0));
	ip := jstr(jget(d, "ip"));
	port := cast(int)(jint(jget(d, "port"), 0));
	modes := make_dynamic(string, 0, 4, temp);
	for m: jarr(jget(d, "modes")) { append(*modes, jstr(m)); }
	for e: c.experiments { delete(e); }
	clear(*c.experiments);
	for e: jarr(jget(d, "experiments")) {
		for s: SUPPORTED_EXPERIMENTS { if jstr(e) == s { append(*c.experiments, clone(s)); } }
	}
	c.session_ok = true;
	if c.server_version >= 6 { send_text(c, MSG_VOICE_BACKEND_VERSION); }
	c.mode = choose_mode(view(modes));
	set_state(c, .Discovering);
	if c.mode == .None || ip == "" || port == 0 { return; }
	if !udp_setup(c, ip, port) { return; }
	send_text(c, msg_select_protocol(c.external_ip, c.external_port, c.mode, c.rtc_connection_id, view(c.experiments)));
}

udp_setup :: (c: *Conn, ip: string, port: int) -> bool {
	addr := net.parse_address(ip);
	if addr.kind == .None {
		ep, err := net.resolve_ip4(ip);
		if err != .None { return false; }
		addr = ep.address;
	}
	c.server_ep = net.Endpoint.{addr, port};
	if !c.udp_open {
		bind: net.Address = net.IP4_Any;
		{ _, is6 := addr.ip6_address, addr.kind == .IP6_Address;
		if is6 { bind = net.IP6_Any; } }
		sock, err := net.make_bound_udp_socket(bind, 0);
		if err != .None { return false; }
		c.udp = sock;
		c.udp_open = true;
		net.set_option(c.udp, .Receive_Timeout, 100 * time.Millisecond);
	}
	req: [DISCOVERY_LEN]u8;
	build_discovery_request(view(req), c.ssrc);
	buf: [1500]u8;
	{ attempt := 0;
	while attempt < 20 && !stopped(c) {
		if attempt % 5 == 0 { net.send_udp(c.udp, view(req), c.server_ep); }
		n, _, rerr := net.recv_udp(c.udp, view(buf));
		if rerr != .None || n < DISCOVERY_LEN { { attempt += 1; continue; } }
		_, address, p, ok := parse_discovery(sub(buf, 0, n), 2);
		if !ok { { attempt += 1; continue; } }
		delete(c.external_ip);
		c.external_ip = clone(address);
		c.external_port = cast(int)(p);
		if !c.udp_started {
			c.udp_started = true;
			c.udp_th = thread.create_and_start_with_data(c, udp_thread_proc);
		}
		return true;
		attempt += 1;
} }
	return false;
}

on_session_description :: (c: *Conn, d: json.Value) {
	key: [32]u8;
	ka := jarr(jget(d, "secret_key"));
	if len(ka) != 32 { return; }
	for x, i: ka { key[i] = cast(u8)(jint(x, 0)); }
	mode := mode_from_name(jstr(jget(d, "mode")));
	if mode == .None { return; }
	locks.lock(*c.mu);
	c.mode = mode;
	transport_init(*c.tx_crypto, mode, view(key));
	transport_init(*c.rx_crypto, mode, view(key));
	c.have_key = true;
	locks.unlock(*c.mu);
	crypto.zero_explicit(*key, size_of(type_of(key)));
	dv := jint(jget(d, "dave_protocol_version"));
	if dv < 0 || dv > 65535 {
		dave_invalid(c);
		return;
	}
	DAVE.on_select_protocol_ack(*c.dave, cast(int)(dv));
	c.resumable = true;
	set_state(c, .Connected);
	if !c.audio_started {
		c.audio_started = true;
		if !c.opts.no_audio_devices {
			c.capture_on = audio.capture_start(true);
			if c.capture_on { audio.apply_device_selection(); } // chosen devices + DSP switches
		}
		c.next_rtcp_ms = now_ms() + 1000;
		c.audio_th = thread.create_and_start_with_data(c, audio_thread_proc); // Odin: priority = .High (fc_thread has none)
	}
}

map_user :: (c: *Conn, uid: u64, ssrc: u32) -> *Remote_User {
	locks.lock(*c.mu);
	defer locks.unlock(*c.mu);
	{ old, ok := map_find(c.user_ssrc, uid);
	if ok && old != ssrc {
		{ u, uok := map_find(c.users, old);
		if uok {
			delete_key(*c.users, old);
			u.ssrc = ssrc;
			at(*c.users, ssrc).* = u;
			at(*c.user_ssrc, uid).* = ssrc;
			return u;
		} }
	} }
	{ u, ok := map_find(c.users, ssrc);
	if ok {
		u.user_id = uid;
		at(*c.user_ssrc, uid).* = ssrc;
		return u;
	} }
	u := new(Remote_User);
	u.user_id = uid;
	u.ssrc = ssrc;
	jb_init(*u.jb);
	u.decoder = c.codec.decoder_create();
	at(*c.users, ssrc).* = u;
	at(*c.user_ssrc, uid).* = ssrc;
	return u;
}

destroy_user :: (c: *Conn, u: *Remote_User) {
	c.codec.decoder_destroy(u.decoder);
	if u.source != 0 { audio.source_destroy(u.source); }
	free(u);
}

// ---------------------------------------------------------------------------
// Timer thread: heartbeats and the 20 s HELLO timeout.

timer_thread_proc :: (data: *void) {
	c := cast(*Conn)data;
	push_allocator(c.allocator);
	while !stopped(c) {
		time.sleep(25 * time.Millisecond);
		now := now_ms();
		hello_timeout, beat, timeout := false, false, false;
		locks.lock(*c.hb_mu);
		if c.hello_deadline_ms != 0 && now > c.hello_deadline_ms {
			c.hello_deadline_ms = 0;
			hello_timeout = true;
		}
		if c.hb_interval_ms > 0 && now >= c.next_hb_ms {
			c.next_hb_ms = now + c.hb_interval_ms;
			if c.hb_acked {
				c.hb_acked = false;
				beat = true;
			} else {
				c.hb_interval_ms = 0;
				timeout = true;
			}
		}
		locks.unlock(*c.hb_mu);
		// HELLO timeout / HEARTBEAT ACK TIMEOUT: close(4000) and resume
		if hello_timeout || timeout { close_ws(c, CLOSE_FORCE); }
		if beat { send_heartbeat(c); }
		reset_temporary_storage();
	}
}

// ---------------------------------------------------------------------------
// UDP receive

udp_thread_proc :: (data: *void) {
	c := cast(*Conn)data;
	push_allocator(c.allocator);
	buf: [2048]u8;
	plain: [2048]u8;
	frame: [2048]u8;
	while !stopped(c) {
		n, from, err := net.recv_udp(c.udp, view(buf));
		if err != .None || n <= 0 { continue; }
		pkt := sub(buf, 0, n);
		locks.lock(*c.mu);
		c.stats.udp_datagrams += 1;
		have := c.have_key;
		locks.unlock(*c.mu);
		if !have { continue; }
		now := now_ms();
		if is_rtcp(pkt) {
			m, ok := transport_open(*c.rx_crypto, pkt, 8, view(plain));
			if !ok {
				count_failure(c);
				continue;
			}
			locks.lock(*c.mu);
			c.stats.rtcp_received += 1;
			locks.unlock(*c.mu);
			on_rtcp(c, sub(plain, 0, m), now);
			continue;
		}
		h, hok := parse_rtp_header(pkt);
		if !hok { continue; }
		m, ok := transport_open(*c.rx_crypto, pkt, h.aad_len, view(plain));
		if !ok {
			count_failure(c);
			continue;
		}
		if h.pt != OPUS_PT || h.payload_off > m {
			locks.lock(*c.mu);
			c.stats.other_pt += 1;
			locks.unlock(*c.mu);
			continue;
		}
		end := m;
		if (plain[0] & 0x20) != 0 { 	// padding
			pad := cast(int)(plain[m - 1]);
			if pad == 0 || pad > m - h.payload_off { continue; }
			end -= pad;
		}
		payload := sub(plain, h.payload_off, end);
		locks.lock(*c.mu);
		u, known := map_find(c.users, h.ssrc);
		uid: u64 = ifx known then u.user_id else 0;
		c.stats.packets_received += 1;
		c.stats.bytes_received += cast(u64)(n);
		locks.unlock(*c.mu);
		if !known || uid == 0 {
			locks.lock(*c.mu);
			c.stats.unknown_ssrc += 1;
			locks.unlock(*c.mu);
			continue; // no op 5 yet: can't attribute (DAVE needs the sender)
		}
		fl, res := DAVE.session_decrypt(*c.dave, uid, payload, view(frame));
		if res == .Failed { continue; }
		opus := sub(frame, 0, fl);
		silent := fl == 3 && opus[0] == 0xF8 && opus[1] == 0xFF && opus[2] == 0xFE;
		{ level, voice, lok := ext_audio_level(sub(plain, 0, m), h);
		if lok && !voice && level >= 127 { silent = true; } }
		locks.lock(*c.mu);
		{ uu, still := map_find(c.users, h.ssrc);
		if still {
			jb_push(*uu.jb, h.seq, h.ts, opus, cast(float64)(now));
			rx_update(*uu.rx, h.seq, h.ts, now);
			if !silent { uu.last_voice_ms = now; }
		} }
		locks.unlock(*c.mu);
	}
}

count_failure :: (c: *Conn) {
	locks.lock(*c.mu);
	c.stats.transport_failures += 1;
	locks.unlock(*c.mu);
}

// rx_update: RFC 3550 A.1 / A.8 receiver statistics.
rx_update :: (r: *Rx_Stats, seq: u16, ts: u32, now: s64) {
	if !r.init {
		r.init = true;
		r.base_seq = seq;
		r.max_seq = seq;
	} else {
		delta := seq - r.max_seq;
		if delta < 0x8000 {
			if seq < r.max_seq { r.cycles += 1 << 16; }
			r.max_seq = seq;
		}
	}
	r.received += 1;
	arrival := now * 48; // ms -> 48 kHz units
	transit := arrival - cast(s64)(ts);
	if r.received > 1 {
		d := transit - r.transit; if d < 0 { d = -d; }
		r.jitter += (cast(float64)(d) - r.jitter) / 16;
	}
	r.transit = transit;
}

on_rtcp :: (c: *Conn, b: []u8, now: s64) {
	rep, ok := parse_report(b);
	if !ok {
		dbg(c, "rtcp pt=%d len=%d (unparsed)", b[1], len(b));
		return;
	}
	dbg(c, "rtcp %s ssrc=%d blocks=%d", ifx rep.is_sr then "SR" else "RR", rep.ssrc, rep.n_blocks);
	for i: 0..cast(int)(rep.n_blocks)-1 {
		bl := rep.blocks[i];
		dbg(c, "  block ssrc=%d lost=%d frac=%d maxseq=%d jitter=%d", bl.ssrc, bl.cum_lost, bl.fraction_lost, bl.ext_max_seq, bl.jitter);
	}
	locks.lock(*c.mu);
	defer locks.unlock(*c.mu);
	if rep.is_sr {
		{ u, has := map_find(c.users, rep.ssrc);
		if has {
			u.rx.lsr = cast(u32)(rep.ntp >> 16);
			u.rx.lsr_at_ms = now;
		} }
	}
	for i: 0..cast(int)(rep.n_blocks)-1 {
		blk := rep.blocks[i];
		if blk.ssrc != c.ssrc || blk.lsr == 0 { continue; }
		ntp_mid := cast(u32)(ntp_now() >> 16);
		rtt := ntp_mid - blk.lsr - blk.dlsr; // 1/65536 s
		c.stats.rtt_ms = cast(int)(cast(u64)(rtt) * 1000 / 65536);
	}
}

ntp_now :: () -> u64 {
	ns := time.to_unix_nanoseconds(time.now());
	secs := cast(u64)(ns / 1000000000) + 2_208_988_800;
	frac := cast(u64)(ns % 1000000000) * (1 << 32) / 1000000000;
	return (secs << 32) | frac;
}

// ---------------------------------------------------------------------------
// Audio thread: 20 ms ticks. Send: mic -> VAD -> Opus -> DAVE -> RTP -> AEAD.
// Receive: jitter buffer -> Opus (FEC/PLC) -> volume -> output.

audio_thread_proc :: (data: *void) {
	c := cast(*Conn)data;
	push_allocator(c.allocator);
	pcm: [SAMPLES_PER_FRAME]float32;
	out: [SAMPLES_PER_FRAME * 2]float32;
	next := time.tick_now();
	while !stopped(c) {
		next = time.tick_add(next, 20 * time.Millisecond);
		tx_tick(c, view(pcm));
		rx_tick(c, view(out));
		if now_ms() >= c.next_rtcp_ms { send_rtcp(c); }
		reset_temporary_storage();
		left := time.tick_diff(time.tick_now(), next);
		if left > 0 {
			time.accurate_sleep(left);
		} else if left < -200 * time.Millisecond {
			next = time.tick_now(); // fell far behind: resync
		}
	}
}

read_mic :: (c: *Conn, pcm: []float32) {
	n := 0;
	if c.opts.no_audio_devices {
		if c.opts.capture != null { n = c.opts.capture(c.opts.callback_data, pcm); }
	} else if c.capture_on {
		// keep latency bounded: drop backlog beyond 3 frames
		while audio.capture_available() > 4 * SAMPLES_PER_FRAME {
			audio.capture_read(pcm);
		}
		n = audio.capture_read(pcm);
	}
	for i: n..len(pcm)-1 { pcm[i] = 0; }
}

tx_tick :: (c: *Conn, pcm: []float32) {
	read_mic(c, pcm);
	locks.lock(*c.mu);
	muted := c.self_mute || c.self_deaf;
	gain := c.input_gain;
	locks.unlock(*c.mu);
	if gain != 1 { for * x: pcm { x.* = clamp(x.* * gain, -1, 1); } }
	active, db := vad_process(*c.vad, pcm);
	locks.lock(*c.mu);
	c.input_db = db;
	c.vad_open = active;
	locks.unlock(*c.mu);
	locks.lock(*c.mu);
	if c.ptt_mode { active = c.ptt_pressed || now_ms() < c.ptt_until_ms; }
	locks.unlock(*c.mu);
	if muted { active = false; }
	frame_ts := c.ts;
	c.ts += SAMPLES_PER_FRAME;
	if active {
		if !c.self_speaking {
			send_text(c, msg_speaking(SPEAKING_VOICE, c.ssrc));
			locks.lock(*c.mu);
			c.self_speaking = true;
			locks.unlock(*c.mu);
			// leading frames (pre-roll), with their original timestamps
			for i: 0..cast(int)(c.preroll_n)-1 {
				pts := frame_ts - cast(u32)(c.preroll_n - i) * SAMPLES_PER_FRAME;
				send_audio(c, view(c.preroll[i]), pts, frame_level_db(view(c.preroll[i])), true);
			}
		}
		c.preroll_n = 0;
		c.silence_left = 5;
		send_audio(c, pcm, frame_ts, db, true);
		return;
	}
	if c.self_speaking {
		if c.silence_left > 0 {
			// five Opus silence frames on speaking stop
			c.silence_left -= 1;
			s := OPUS_SILENCE_FRAME;
			send_opus(c, view(s), frame_ts, 127, false);
			if c.silence_left == 0 {
				send_text(c, msg_speaking(0, c.ssrc));
				locks.lock(*c.mu);
				c.self_speaking = false;
				locks.unlock(*c.mu);
			}
		}
		return;
	}
	if muted {
		c.preroll_n = 0;
		return;
	}
	// shift pre-roll
	if c.preroll_n == len(c.preroll) {
		for i: 1..len(c.preroll)-1 { c.preroll[i - 1] = c.preroll[i]; }
		c.preroll_n -= 1;
	}
	copy(view(c.preroll[c.preroll_n]), pcm);
	c.preroll_n += 1;
}

send_audio :: (c: *Conn, pcm: []float32, ts: u32, db: float32, voice: bool) {
	opus: [MAX_OPUS_PACKET]u8;
	n := c.codec.encode(c.encoder, pcm, view(opus));
	if n <= 0 { return; }
	send_opus(c, sub(opus, 0, n), ts, audio_level_byte(db), voice);
}

send_opus :: (c: *Conn, opus: []u8, ts: u32, level: u8, voice: bool) {
	if !c.udp_open { return; }
	frame: [MAX_OPUS_PACKET + DAVE.MAX_SUPPLEMENTAL]u8;
	fl := DAVE.session_encrypt(*c.dave, opus, view(frame));
	if fl <= 0 { return; }
	pkt: [MAX_OPUS_PACKET + 128]u8;
	sealed: [MAX_OPUS_PACKET + 160]u8;
	plen, aad := build_audio_rtp(view(pkt), c.seq, ts, c.ssrc, level, voice, sub(frame, 0, fl));
	locks.lock(*c.mu);
	if !c.have_key {
		locks.unlock(*c.mu);
		return;
	}
	nonce := c.tx_nonce;
	c.tx_nonce += 1;
	sl := transport_seal(*c.tx_crypto, sub(pkt, 0, plen), aad, nonce, view(sealed));
	c.stats.packets_sent += 1;
	c.stats.bytes_sent += cast(u64)(sl);
	locks.unlock(*c.mu);
	c.seq += 1;
	c.packets_sent += 1;
	c.octets_sent += cast(u32)(fl);
	c.last_sent_ts = ts;
	net.send_udp(c.udp, sub(sealed, 0, sl), c.server_ep);
}

rx_tick :: (c: *Conn, out: []float32) {
	locks.lock(*c.mu);
	defer locks.unlock(*c.mu);
	deaf := c.self_deaf;
	for _, u: c.users {
		kind, data := jb_pop(*u.jb);
		if kind == .None { continue; }
		n := 0;
		if kind == {
		case .Packet;
			n = c.codec.decode(u.decoder, data, false, out);
		case .Fec;
			n = c.codec.decode(u.decoder, data, true, out);
		case .Plc;
			n = c.codec.decode(u.decoder, .[], false, out);
		case .None;
		}
		if n <= 0 || deaf { continue; }
		st := or_else(map_find(c.settings, u.user_id), User_Settings.{volume = 1});
		if st.muted { continue; }
		frames := sub(out, 0, n * 2);
		if st.volume != 1 { for * s: frames { s.* *= st.volume; } }
		if c.opts.no_audio_devices {
			if c.opts.playback != null { c.opts.playback(c.opts.callback_data, u.user_id, frames); }
		} else {
			if u.source == 0 { u.source = audio.source_create(); }
			if u.source != 0 { audio.source_write(u.source, frames); }
		}
	}
}

// send_rtcp: SR (when we have sent since the last report) or RR, with one
// report block per remote stream; ~5 s randomized interval (RFC 3550 6.3.1).
send_rtcp :: (c: *Conn) {
	now := now_ms();
	c.next_rtcp_ms = now + 2500 + cast(s64)(rand.int31_max(5000));
	if !c.udp_open { return; }
	blocks := make_dynamic(Report_Block, 0, 8, temp);
	locks.lock(*c.mu);
	for _, u: c.users {
		r := *u.rx;
		if !r.init { continue; }
		ext_max := r.cycles + cast(u32)(r.max_seq);
		expected := ext_max - cast(u32)(r.base_seq) + 1;
		lost := cast(s32)(expected) - cast(s32)(r.received);
		exp_int := expected - r.expected_prior;
		rec_int := r.received - r.received_prior;
		r.expected_prior = expected;
		r.received_prior = r.received;
		lost_int := cast(s32)(exp_int) - cast(s32)(rec_int);
		frac: u8 = 0;
		if exp_int != 0 && lost_int > 0 { frac = cast(u8)(((cast(u32)(lost_int)) << 8) / exp_int); }
		dlsr: u32 = 0;
		if r.lsr != 0 { dlsr = cast(u32)((now - r.lsr_at_ms) * 65536 / 1000); }
		append(*blocks, Report_Block.{u.ssrc, frac, lost, ext_max, cast(u32)(r.jitter), r.lsr, dlsr});
	}
	have := c.have_key;
	locks.unlock(*c.mu);
	if !have { return; }
	pkt: [512]u8;
	sealed: [600]u8;
	sender := c.packets_sent > 0;
	n := build_report(view(pkt), c.ssrc, sender, ntp_now(), c.last_sent_ts, c.packets_sent, c.octets_sent, view(blocks));
	locks.lock(*c.mu);
	nonce := c.tx_nonce;
	c.tx_nonce += 1;
	sl := transport_seal(*c.tx_crypto, sub(pkt, 0, n), 8, nonce, view(sealed));
	locks.unlock(*c.mu);
	net.send_udp(c.udp, sub(sealed, 0, sl), c.server_ep);
}
#scope_export

