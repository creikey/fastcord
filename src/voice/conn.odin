// Package voice is the Discord voice client: voice gateway (WebSocket v9),
// UDP media (RTP/RTCP with rtpsize AEAD transport encryption), DAVE E2EE
// (fc:voice/dave over fc:voice/mls), jitter buffering, VAD and speaking.
//
//	c := voice.voice_connect(voice.Voice_Server_Info{...})
//	voice.set_self_mute(c, true)
//	ids := voice.speaking_users(c, context.temp_allocator)
//	voice.voice_disconnect(c)
//
// Threads per connection: gateway (WebSocket read loop + reconnect/resume),
// timer (heartbeats, hello timeout), UDP receive, audio (20 ms send/playout).
package voice

import "base:runtime"
import "core:crypto"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:math/rand"
import "core:net"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import "fc:audio"
import "fc:http"
import "fc:netio"
import "fc:tls"
import "fc:voice/dave"

// Voice_Server_Info: everything src/discord learns from the main gateway.
//   endpoint:            VOICE_SERVER_UPDATE.endpoint ("c-lax07-200a12c1.discord.media:2096"; port optional, default 443)
//   token:               VOICE_SERVER_UPDATE.token
//   guild_or_channel_id: VOICE_SERVER_UPDATE.guild_id, or for DM/group calls the call's channel_id (sent as server_id)
//   user_id:             our user id
//   session_id:          our VOICE_STATE_UPDATE.session_id (= main gateway session id)
//   channel_id:          the voice channel / DM channel id
Voice_Server_Info :: struct {
	endpoint:            string,
	token:               string,
	guild_or_channel_id: u64,
	user_id:             u64,
	session_id:          string,
	channel_id:          u64,
	stage:               bool, // stage channel (allows DAVE version 0)
	user_agent:          string, // "" = official desktop UA
	accept_language:     string, // "" = "en-US"
}

Conn_State :: enum u8 {
	Connecting, // dialing the voice gateway
	Identifying, // IDENTIFY sent, waiting for READY
	Discovering, // UDP IP discovery / SELECT_PROTOCOL
	Connected, // SESSION_DESCRIPTION received, media flowing
	Resuming, // reconnecting with RESUME
	Disconnected, // terminal; see close_code
}

Dial_Proc :: #type proc(host: string, port: int) -> (netio.Stream, bool)

Options :: struct {
	dial:             Dial_Proc, // nil = TCP + TLS (ALPN http/1.1, SNI = host)
	no_audio_devices: bool, // don't touch fc:audio (tests / headless)
	capture:          proc(data: rawptr, out: []f32) -> int, // mono 48 kHz pull, used when no_audio_devices
	playback:         proc(data: rawptr, user_id: u64, pcm: []f32), // stereo interleaved, 960 frames
	callback_data:    rawptr,
	vad_manual:       bool, // manual threshold instead of auto
	vad_threshold_db: f32, // manual threshold (0 = -60 dB default)
}

Stats :: struct {
	ws_ping_ms:       int,
	rtt_ms:           int, // from RTCP receiver reports about our stream
	packets_sent:     u64,
	packets_received: u64,
	bytes_sent:       u64,
	bytes_received:   u64,
	transport_failures: u64,
	udp_datagrams:    u64, // everything that arrived on the socket
	rtcp_received:    u64,
	other_pt:         u64, // RTP with a payload type other than opus
	unknown_ssrc:     u64, // audio from an SSRC no op 5 mapped yet
	remote_users:     int,
	e2ee_failures:    u64,
	reconnects:       int,
	jitter:           Jitter_Stats, // summed over remote users
}

User_Settings :: struct {
	volume: f32, // 0..2, 1 = unchanged
	muted:  bool,
}

Rx_Stats :: struct {
	base_seq, max_seq: u16,
	cycles:            u32,
	received:          u32,
	expected_prior:    u32,
	received_prior:    u32,
	transit:           i64,
	jitter:            f64, // in timestamp units
	lsr:               u32,
	lsr_at_ms:         i64,
	init:              bool,
}

Remote_User :: struct {
	user_id:       u64,
	ssrc:          u32,
	speaking_flag: int, // from op 5
	last_voice_ms: i64,
	jb:            Jitter_Buffer,
	decoder:       rawptr,
	source:        audio.Source,
	rx:            Rx_Stats,
}

Conn :: struct {
	info:              Voice_Server_Info,
	opts:              Options,
	host:              string,
	port:              int,
	rtc_connection_id: string,
	mu:                sync.Mutex, // users, stats, state
	ws_mu:             sync.Mutex, // ws pointer + sends
	state:             Conn_State,
	close_code:        int,
	stop:              bool, // atomic
	state_cond:        sync.Cond,

	ws:                ^http.Ws_Conn,
	ws_stream:         netio.Stream,
	ws_open:           bool,
	server_version:    int,
	hb_interval_ms:    i64,
	next_hb_ms:        i64,
	hb_acked:          bool,
	last_ack_ms:       i64,
	hello_deadline_ms: i64,
	hb_mu:             sync.Mutex, // heartbeat fields above (gateway <-> timer thread)
	session_ok:        bool, // READY/RESUMED seen on the current socket (backoff.succeed)
	last_seq:          i64,
	resumable:         bool,

	udp:               net.UDP_Socket,
	udp_open:          bool,
	server_ep:         net.Endpoint,
	ssrc:              u32,
	mode:              Mode,
	tx_crypto:         Transport_Crypto,
	rx_crypto:         Transport_Crypto,
	have_key:          bool,
	tx_nonce:          u32,
	experiments:       [dynamic]string,
	external_ip:       string,
	external_port:     int,

	dave:              dave.Session,
	users:             map[u32]^Remote_User,
	user_ssrc:         map[u64]u32,
	settings:          map[u64]User_Settings,
	self_mute:         bool,
	self_deaf:         bool,
	self_speaking:     bool,

	codec:             Codec,
	encoder:           rawptr,
	vad:               Vad,
	seq:               u16,
	ts:                u32,
	twcc:              u16,
	packets_sent:      u32,
	octets_sent:       u32,
	last_sent_ts:      u32,
	preroll:           [VAD_DEFAULT_LEADING][SAMPLES_PER_FRAME]f32,
	preroll_n:         int,
	silence_left:      int,
	next_rtcp_ms:      i64,
	stats:             Stats,

	ws_th, timer_th, udp_th, audio_th: ^thread.Thread,
	udp_started:       bool,
	audio_started:     bool,
	capture_on:        bool,
	allocator:         runtime.Allocator, // long-lived allocations from every thread
	debug:             bool, // FASTCORD_VOICE_DEBUG=1: protocol trace on stderr (no secrets)
}

@(private)
dbg :: proc(c: ^Conn, format: string, args: ..any) {
	if !c.debug do return
	fmt.eprintf("[voice %v] ", c.info.user_id)
	fmt.eprintfln(format, ..args)
}

now_ms :: proc() -> i64 {return time.to_unix_nanoseconds(time.now()) / 1e6}

@(private)
stopped :: proc(c: ^Conn) -> bool {return sync.atomic_load(&c.stop)}

@(private)
set_state :: proc(c: ^Conn, s: Conn_State) {
	sync.mutex_lock(&c.mu)
	c.state = s
	sync.cond_broadcast(&c.state_cond)
	sync.mutex_unlock(&c.mu)
}

// ---------------------------------------------------------------------------
// Public API

voice_connect :: proc(info: Voice_Server_Info, opts := Options{}) -> ^Conn {
	c := new(Conn)
	c.info = info
	c.info.endpoint = strings.clone(info.endpoint)
	c.info.token = strings.clone(info.token)
	c.info.session_id = strings.clone(info.session_id)
	c.info.user_agent = strings.clone(info.user_agent if info.user_agent != "" else DEFAULT_USER_AGENT)
	c.info.accept_language = strings.clone(info.accept_language if info.accept_language != "" else "en-US")
	c.opts = opts
	c.host, c.port = split_endpoint(c.info.endpoint)
	c.rtc_connection_id = uuid4()
	c.users = make(map[u32]^Remote_User)
	c.user_ssrc = make(map[u64]u32)
	c.settings = make(map[u64]User_Settings)
	c.experiments = make([dynamic]string)
	c.last_seq = -1
	c.codec = get_codec()
	c.encoder = c.codec.encoder_create()
	vad_init(&c.vad)
	if opts.vad_manual {
		c.vad.auto_threshold = false
		if opts.vad_threshold_db != 0 do c.vad.threshold_db = opts.vad_threshold_db
	}
	// WebRTC randomizes the initial sequence number and timestamp
	rb: [6]byte
	crypto.rand_bytes(rb[:])
	c.seq = u16(rb[0]) << 8 | u16(rb[1])
	c.ts = get_u32(rb[2:])
	dave.session_init(&c.dave, info.user_id, info.channel_id, info.stage)
	c.state = .Connecting
	c.allocator = context.allocator
	c.debug = os.get_env("FASTCORD_VOICE_DEBUG", context.temp_allocator) == "1"
	if os.get_env("FASTCORD_VOICE_NOEXT", context.temp_allocator) == "1" do rtp_no_extensions = true
	if os.get_env("FASTCORD_VOICE_EXT", context.temp_allocator) == "level" do rtp_ext_variant = 1
	c.ws_th = thread.create_and_start_with_data(c, ws_thread_proc)
	c.timer_th = thread.create_and_start_with_data(c, timer_thread_proc)
	return c
}

// voice_disconnect closes the gateway (code 4000, as the client's close()),
// stops all threads and frees the connection.
voice_disconnect :: proc(c: ^Conn) {
	if c == nil do return
	sync.atomic_store(&c.stop, true)
	sync.mutex_lock(&c.ws_mu)
	if c.ws != nil && c.ws_open {
		_ = http.ws_close(c.ws, CLOSE_FORCE, "")
		netio.shutdown(c.ws_stream)
	}
	sync.mutex_unlock(&c.ws_mu)
	for th in ([]^thread.Thread{c.ws_th, c.timer_th, c.udp_th, c.audio_th}) {
		if th != nil {
			thread.join(th)
			thread.destroy(th)
		}
	}
	if c.capture_on do audio.capture_stop()
	if c.udp_open do net.close(c.udp)
	transport_reset(&c.tx_crypto)
	transport_reset(&c.rx_crypto)
	for _, u in c.users do destroy_user(c, u)
	delete(c.users)
	delete(c.user_ssrc)
	delete(c.settings)
	for e in c.experiments do delete(e)
	delete(c.experiments)
	delete(c.external_ip)
	c.codec.encoder_destroy(c.encoder)
	dave.session_destroy(&c.dave)
	delete(c.info.endpoint)
	delete(c.info.token)
	delete(c.info.session_id)
	delete(c.info.user_agent)
	delete(c.info.accept_language)
	delete(c.rtc_connection_id)
	free(c)
}

state :: proc(c: ^Conn) -> (Conn_State, int) {
	sync.mutex_lock(&c.mu)
	defer sync.mutex_unlock(&c.mu)
	return c.state, c.close_code
}

// wait_state blocks until the connection reaches s (or Disconnected) or timeout.
wait_state :: proc(c: ^Conn, s: Conn_State, timeout: time.Duration) -> bool {
	deadline := time.tick_now()._nsec + i64(timeout)
	sync.mutex_lock(&c.mu)
	defer sync.mutex_unlock(&c.mu)
	for c.state != s && c.state != .Disconnected {
		left := deadline - time.tick_now()._nsec
		if left <= 0 do break
		_ = sync.cond_wait_with_timeout(&c.state_cond, &c.mu, time.Duration(left))
	}
	return c.state == s
}

set_self_mute :: proc(c: ^Conn, muted: bool) {
	sync.mutex_lock(&c.mu)
	c.self_mute = muted
	sync.mutex_unlock(&c.mu)
}

// set_self_deaf: deafened implies no playout and no sending (like the client).
set_self_deaf :: proc(c: ^Conn, deaf: bool) {
	sync.mutex_lock(&c.mu)
	c.self_deaf = deaf
	if deaf do for _, u in c.users do if u.source != 0 do audio.source_flush(u.source)
	sync.mutex_unlock(&c.mu)
}

set_user_volume :: proc(c: ^Conn, user_id: u64, volume: f32) {
	sync.mutex_lock(&c.mu)
	s := c.settings[user_id] or_else User_Settings{volume = 1}
	s.volume = clamp(volume, 0, 2)
	c.settings[user_id] = s
	sync.mutex_unlock(&c.mu)
}

set_user_mute :: proc(c: ^Conn, user_id: u64, muted: bool) {
	sync.mutex_lock(&c.mu)
	s := c.settings[user_id] or_else User_Settings{volume = 1}
	s.muted = muted
	c.settings[user_id] = s
	sync.mutex_unlock(&c.mu)
}

SPEAKING_HOLD_MS :: 250

// speaking_users: users heard within the last 250 ms (and ourselves while
// our VAD is open and we are not muted).
speaking_users :: proc(c: ^Conn, allocator := context.allocator) -> []u64 {
	sync.mutex_lock(&c.mu)
	defer sync.mutex_unlock(&c.mu)
	now := now_ms()
	out := make([dynamic]u64, 0, len(c.users) + 1, allocator)
	if c.self_speaking do append(&out, c.info.user_id)
	for _, u in c.users {
		if u.user_id != 0 && now - u.last_voice_ms < SPEAKING_HOLD_MS do append(&out, u.user_id)
	}
	return out[:]
}

is_speaking :: proc(c: ^Conn, user_id: u64) -> bool {
	ids := speaking_users(c, context.temp_allocator)
	for id in ids do if id == user_id do return true
	return false
}

get_stats :: proc(c: ^Conn) -> Stats {
	sync.mutex_lock(&c.mu)
	defer sync.mutex_unlock(&c.mu)
	s := c.stats
	s.remote_users = len(c.users)
	s.jitter = {}
	for _, u in c.users {
		js := u.jb.stats
		s.jitter.received += js.received
		s.jitter.late += js.late
		s.jitter.lost += js.lost
		s.jitter.concealed += js.concealed
		s.jitter.fec_recovered += js.fec_recovered
		s.jitter.dropped += js.dropped
		s.jitter.jitter_ms = max(s.jitter.jitter_ms, js.jitter_ms)
		s.jitter.target_frames = max(s.jitter.target_frames, js.target_frames)
	}
	ds := dave.session_status(&c.dave, context.temp_allocator)
	s.e2ee_failures = ds.stats.decrypt_failures
	return s
}

// E2EE status: privacy code is the 30-digit voice privacy code ("" when the
// call is not end-to-end encrypted).
E2EE_Status :: struct {
	protocol_version: int,
	active:           bool,
	epoch:            u64,
	privacy_code:     string,
	members:          int,
}

e2ee_status :: proc(c: ^Conn, allocator := context.allocator) -> E2EE_Status {
	ds := dave.session_status(&c.dave, allocator)
	return E2EE_Status{ds.protocol_version, ds.e2ee_active, ds.epoch, ds.privacy_code, ds.members}
}

privacy_code :: proc(c: ^Conn, allocator := context.allocator) -> string {
	return e2ee_status(c, allocator).privacy_code
}

// verification_code: 45-digit pairwise identity fingerprint with user (slow: scrypt).
verification_code :: proc(c: ^Conn, user_id: u64, allocator := context.allocator) -> (string, bool) {
	return dave.session_verification_code(&c.dave, user_id, allocator)
}

// ---------------------------------------------------------------------------
// Gateway thread

@(private)
split_endpoint :: proc(ep: string) -> (host: string, port: int) {
	e := ep
	if strings.has_prefix(e, "wss://") do e = e[6:]
	if i := strings.index_byte(e, '/'); i >= 0 do e = e[:i]
	if i := strings.last_index_byte(e, ':'); i >= 0 {
		if p, ok := strconv.parse_int(e[i + 1:]); ok do return e[:i], p
	}
	return e, 443
}

@(private)
default_dial :: proc(host: string, port: int) -> (netio.Stream, bool) {
	tcp, err := netio.dial_tcp(host, port)
	if err != .None do return {}, false
	under := netio.tcp_stream(tcp)
	sess, terr := tls.connect(under, tls.Config{alpn = {"http/1.1"}, server_name = host})
	if terr != .None {
		netio.close(under)
		return {}, false
	}
	return tls.stream(sess), true
}

// voice_ws_headers: Chrome's WebSocket upgrade request, header order as captured.
voice_ws_headers :: proc(c: ^Conn) -> []http.Header {
	host := c.host if c.port == 443 else strings.concatenate({c.host, ":", snowflake(u64(c.port))}, context.temp_allocator)
	h := make([dynamic]http.Header, 0, 12, context.temp_allocator)
	append(&h, http.Header{"Host", host})
	append(&h, http.Header{"Connection", "Upgrade"})
	append(&h, http.Header{"Pragma", "no-cache"})
	append(&h, http.Header{"Cache-Control", "no-cache"})
	append(&h, http.Header{"User-Agent", c.info.user_agent})
	append(&h, http.Header{"Upgrade", "websocket"})
	append(&h, http.Header{"Origin", "https://discord.com"})
	append(&h, http.Header{"Sec-WebSocket-Version", "13"})
	append(&h, http.Header{"Accept-Encoding", "gzip, deflate, br, zstd"})
	append(&h, http.Header{"Accept-Language", c.info.accept_language})
	append(&h, http.Header{"Sec-WebSocket-Key", ""})
	append(&h, http.Header{"Sec-WebSocket-Extensions", "permessage-deflate; client_max_window_bits"})
	return h[:]
}

@(private)
send_text :: proc(c: ^Conn, s: string) -> bool {
	sync.mutex_lock(&c.ws_mu)
	defer sync.mutex_unlock(&c.ws_mu)
	if c.ws == nil || !c.ws_open do return false
	return http.ws_send(c.ws, .Text, transmute([]byte)s) == .None
}

@(private)
send_binary :: proc(c: ^Conn, op: int, payload: []byte) -> bool {
	buf := make([]byte, len(payload) + 1, context.temp_allocator)
	buf[0] = u8(op)
	copy(buf[1:], payload)
	sync.mutex_lock(&c.ws_mu)
	defer sync.mutex_unlock(&c.ws_mu)
	if c.ws == nil || !c.ws_open do return false
	return http.ws_send(c.ws, .Binary, buf) == .None
}

@(private)
close_ws :: proc(c: ^Conn, code: int) {
	sync.mutex_lock(&c.ws_mu)
	defer sync.mutex_unlock(&c.ws_mu)
	if c.ws != nil && c.ws_open {
		_ = http.ws_close(c.ws, code, "")
		netio.shutdown(c.ws_stream)
	}
}

@(private)
terminal_close :: proc(code: int) -> bool {
	switch code {
	case CLOSE_AUTHENTICATION_FAILED, CLOSE_INVALID_SESSION, CLOSE_SERVER_NOT_FOUND, CLOSE_SERVER_CRASH, CLOSE_DISCONNECTED, CLOSE_CALL_TERMINATED, CLOSE_REPEATED_MLS_INVALID, CLOSE_DAVE_DOWNGRADE_REFUSED, CLOSE_DAVE_INVALID_MESSAGE, CLOSE_UNRESUMABLE:
		return true
	}
	return false
}

@(private)
ws_thread_proc :: proc(data: rawptr) {
	c := cast(^Conn)data
	context.allocator = c.allocator
	fails := 0
	resuming := false
	for !stopped(c) {
		code := ws_session(c, resuming)
		free_all(context.temp_allocator)
		if stopped(c) do break
		if terminal_close(code) {
			finish(c, code)
			return
		}
		// RTCControlSocket.handleClose: backoff (1 s .. 5 s), give up after 4 failures
		if c.session_ok do fails = 0
		c.session_ok = false
		sync.mutex_lock(&c.hb_mu)
		last_ack := c.last_ack_ms
		sync.mutex_unlock(&c.hb_mu)
		if fails > 3 || !c.resumable || (last_ack != 0 && now_ms() - last_ack > 60_000) {
			finish(c, CLOSE_UNRESUMABLE if code == 0 || !c.resumable else code)
			return
		}
		delay := min(1000 << uint(fails), 5000)
		fails += 1
		resuming = true
		set_state(c, .Resuming)
		sync.mutex_lock(&c.mu)
		c.stats.reconnects += 1
		sync.mutex_unlock(&c.mu)
		for i := 0; i < delay / 50 && !stopped(c); i += 1 do time.sleep(50 * time.Millisecond)
	}
}

@(private)
finish :: proc(c: ^Conn, code: int) {
	sync.mutex_lock(&c.mu)
	c.close_code = code
	c.state = .Disconnected
	sync.cond_broadcast(&c.state_cond)
	sync.mutex_unlock(&c.mu)
	sync.atomic_store(&c.stop, true)
}

// ws_session runs one WebSocket connection; returns the close code (0 = transport error).
@(private)
ws_session :: proc(c: ^Conn, resume: bool) -> int {
	if !resume do set_state(c, .Connecting)
	dial: Dial_Proc = c.opts.dial if c.opts.dial != nil else Dial_Proc(default_dial)
	stream, ok := dial(c.host, c.port)
	if !ok do return 0
	req := http.Request {
		method    = "GET",
		scheme    = "https",
		authority = c.host,
		path      = "/?v=9",
		headers   = voice_ws_headers(c),
	}
	ws, resp, err := http.ws_connect(stream, req)
	http.response_destroy(&resp)
	if err != .None {
		netio.close(stream)
		return 0
	}
	sync.mutex_lock(&c.ws_mu)
	c.ws = ws
	c.ws_stream = stream
	c.ws_open = true
	sync.mutex_unlock(&c.ws_mu)
	sync.mutex_lock(&c.hb_mu)
	c.hello_deadline_ms = now_ms() + 20_000
	c.hb_interval_ms = 0
	sync.mutex_unlock(&c.hb_mu)
	if resume {
		send_text(c, msg_resume(c.info.token, c.info.session_id, c.info.guild_or_channel_id, c.info.channel_id, c.last_seq))
	} else {
		set_state(c, .Identifying)
		send_text(c, msg_identify(c.info.guild_or_channel_id, c.info.channel_id, c.info.user_id, c.info.session_id, c.info.token, true))
	}
	msg := make([dynamic]byte)
	defer delete(msg)
	code := 0
	for !stopped(c) {
		mt, rerr := http.ws_recv(ws, &msg)
		if rerr != .None {
			if rerr == .Closed do code = ws.close_code
			break
		}
		if mt == .Text {
			handle_json(c, string(msg[:]))
		} else {
			handle_binary(c, msg[:])
		}
		flush_dave(c)
		if cr := dave.session_close_request(&c.dave); cr != .None {
			code = CLOSE_REPEATED_MLS_INVALID + int(cr) - 1
			close_ws(c, code)
			break
		}
		free_all(context.temp_allocator)
	}
	sync.mutex_lock(&c.ws_mu)
	c.ws_open = false
	c.ws = nil
	sync.mutex_unlock(&c.ws_mu)
	sync.mutex_lock(&c.hb_mu)
	c.hb_interval_ms = 0
	c.hello_deadline_ms = 0
	sync.mutex_unlock(&c.hb_mu)
	http.ws_destroy(ws)
	netio.close(stream)
	return code
}

@(private)
flush_dave :: proc(c: ^Conn) {
	outs := dave.session_take_outgoing(&c.dave, context.temp_allocator)
	for o in outs {
		switch o.op {
		case dave.OP_MLS_KEY_PACKAGE, dave.OP_MLS_COMMIT_WELCOME:
			send_binary(c, o.op, o.data)
		case dave.OP_READY_FOR_TRANSITION, dave.OP_MLS_INVALID_COMMIT_WELCOME:
			send_text(c, msg_transition(o.op, o.transition_id))
		}
		delete(o.data)
	}
}

@(private)
handle_json :: proc(c: ^Conn, text: string) {
	v, err := json.parse_string(text, parse_integers = true, allocator = context.temp_allocator)
	if err != nil do return
	op := int(jint(jget(v, "op")))
	if c.debug && op != OP_HEARTBEAT_ACK && op != OP_SESSION_DESCRIPTION do dbg(c, "<~ %s", text[:min(len(text), 400)])
	if s := jint(jget(v, "seq"), 0); s != 0 do c.last_seq = s // `r && (lastRecvSeqNum = r)`
	d := jget(v, "d")
	switch op {
	case OP_HELLO:
		c.server_version = int(jint(jget(d, "v"), 3))
		iv := jint(jget(d, "heartbeat_interval"), 13750)
		sync.mutex_lock(&c.hb_mu)
		c.hello_deadline_ms = 0
		// desktop (isPlatformEmbedded): interval * modifier, no 5 s cap; v<=3: 25 %
		c.hb_interval_ms = iv / 4 if c.server_version <= 3 else iv
		c.hb_acked = true
		c.next_hb_ms = now_ms() + c.hb_interval_ms
		sync.mutex_unlock(&c.hb_mu)
	case OP_READY:
		on_ready(c, d)
	case OP_SESSION_DESCRIPTION:
		on_session_description(c, d)
	case OP_RESUMED:
		c.session_ok = true
		set_state(c, .Connected)
	case OP_HEARTBEAT:
		send_heartbeat(c)
	case OP_HEARTBEAT_ACK:
		t := jint(jget(d, "t"), 0) if c.server_version >= 8 else jint(d, 0)
		now := now_ms()
		sync.mutex_lock(&c.mu)
		c.stats.ws_ping_ms = int(now - t)
		sync.mutex_unlock(&c.mu)
		sync.mutex_lock(&c.hb_mu)
		c.last_ack_ms = now
		c.hb_acked = true
		sync.mutex_unlock(&c.hb_mu)
	case OP_SPEAKING:
		uid := jsnow(jget(d, "user_id"))
		ssrc := u32(jint(jget(d, "ssrc"), 0))
		flags := int(jint(jget(d, "speaking"), 0))
		if uid != 0 && ssrc != 0 {
			u := map_user(c, uid, ssrc)
			sync.mutex_lock(&c.mu)
			u.speaking_flag = flags
			sync.mutex_unlock(&c.mu)
		}
	case OP_VIDEO:
		uid := jsnow(jget(d, "user_id"))
		ssrc := u32(jint(jget(d, "audio_ssrc"), 0))
		if uid != 0 && ssrc != 0 do map_user(c, uid, ssrc)
	case OP_CLIENTS_CONNECT:
		ids := make([dynamic]u64, 0, 4, context.temp_allocator)
		for x in jarr(jget(d, "user_ids")) do append(&ids, jsnow(x))
		dave.on_clients_connect(&c.dave, ids[:])
	case OP_CLIENT_DISCONNECT:
		uid := jsnow(jget(d, "user_id"))
		dave.on_client_disconnect(&c.dave, uid)
		sync.mutex_lock(&c.mu)
		if ssrc, ok := c.user_ssrc[uid]; ok {
			if u, uok := c.users[ssrc]; uok {
				destroy_user(c, u)
				delete_key(&c.users, ssrc)
			}
			delete_key(&c.user_ssrc, uid)
		}
		sync.mutex_unlock(&c.mu)
	case dave.OP_PREPARE_TRANSITION:
		tid := jint(jget(d, "transition_id"))
		pv := jint(jget(d, "protocol_version"))
		if tid < 0 || tid > 65535 || pv < 0 || pv > 65535 {
			dave_invalid(c)
			return
		}
		dave.on_prepare_transition(&c.dave, int(tid), int(pv))
	case dave.OP_EXECUTE_TRANSITION:
		tid := jint(jget(d, "transition_id"))
		if tid < 0 || tid > 65535 {
			dave_invalid(c)
			return
		}
		dave.on_execute_transition(&c.dave, int(tid))
	case dave.OP_PREPARE_EPOCH:
		ep := jint(jget(d, "epoch"))
		pv := jint(jget(d, "protocol_version"))
		if ep < 0 || pv < 0 || pv > 65535 {
			dave_invalid(c)
			return
		}
		dave.on_prepare_epoch(&c.dave, u64(ep), int(pv))
	case OP_SESSION_UPDATE, OP_MEDIA_SINK_WANTS, OP_VOICE_BACKEND_VERSION, OP_FLAGS, OP_PLATFORM, OP_SFU_UPDATE:
	// informational for an audio-only client
	}
}

@(private)
dave_invalid :: proc(c: ^Conn) {
	close_ws(c, CLOSE_DAVE_INVALID_MESSAGE)
	finish(c, CLOSE_DAVE_INVALID_MESSAGE)
}

@(private)
handle_binary :: proc(c: ^Conn, b: []byte) {
	// server binary frames: [seq u16][op u8][payload] (v8+)
	if len(b) < 3 {
		dave_invalid(c)
		return
	}
	seq := i64(get_u16(b))
	if seq != 0 do c.last_seq = seq
	op := int(b[2])
	p := b[3:]
	dbg(c, "<~ binary op %d (%d bytes)", op, len(p))
	switch op {
	case dave.OP_MLS_EXTERNAL_SENDER:
		dave.on_external_sender(&c.dave, p)
	case dave.OP_MLS_PROPOSALS:
		dave.on_proposals(&c.dave, p)
	case dave.OP_MLS_ANNOUNCE_COMMIT, dave.OP_MLS_WELCOME:
		if len(p) < 2 {
			dave_invalid(c)
			return
		}
		tid := int(get_u16(p))
		if op == dave.OP_MLS_ANNOUNCE_COMMIT {
			dave.on_announce_commit(&c.dave, tid, p[2:])
		} else {
			dave.on_welcome(&c.dave, tid, p[2:])
		}
	}
}

@(private)
send_heartbeat :: proc(c: ^Conn) {
	if c.server_version >= 8 {
		send_text(c, msg_heartbeat(now_ms(), c.last_seq))
	} else {
		send_text(c, strings.concatenate({`{"op":3,"d":`, snowflake(u64(now_ms())), "}"}, context.temp_allocator))
	}
}

@(private)
on_ready :: proc(c: ^Conn, d: json.Value) {
	c.ssrc = u32(jint(jget(d, "ssrc"), 0))
	ip := jstr(jget(d, "ip"))
	port := int(jint(jget(d, "port"), 0))
	modes := make([dynamic]string, 0, 4, context.temp_allocator)
	for m in jarr(jget(d, "modes")) do append(&modes, jstr(m))
	for e in c.experiments do delete(e)
	clear(&c.experiments)
	for e in jarr(jget(d, "experiments")) {
		for s in SUPPORTED_EXPERIMENTS do if jstr(e) == s do append(&c.experiments, strings.clone(s))
	}
	c.session_ok = true
	if c.server_version >= 6 do send_text(c, MSG_VOICE_BACKEND_VERSION)
	c.mode = choose_mode(modes[:])
	set_state(c, .Discovering)
	if c.mode == .None || ip == "" || port == 0 do return
	if !udp_setup(c, ip, port) do return
	send_text(c, msg_select_protocol(c.external_ip, c.external_port, c.mode, c.rtc_connection_id, c.experiments[:]))
}

@(private)
udp_setup :: proc(c: ^Conn, ip: string, port: int) -> bool {
	addr := net.parse_address(ip)
	if addr == nil {
		ep, err := net.resolve_ip4(ip)
		if err != nil do return false
		addr = ep.address
	}
	c.server_ep = net.Endpoint{addr, port}
	if !c.udp_open {
		bind: net.Address = net.IP4_Any
		if _, is6 := addr.(net.IP6_Address); is6 do bind = net.IP6_Any
		sock, err := net.make_bound_udp_socket(bind, 0)
		if err != nil do return false
		c.udp = sock
		c.udp_open = true
		net.set_option(c.udp, .Receive_Timeout, 100 * time.Millisecond)
	}
	req: [DISCOVERY_LEN]byte
	build_discovery_request(req[:], c.ssrc)
	buf: [1500]byte
	for attempt := 0; attempt < 20 && !stopped(c); attempt += 1 {
		if attempt % 5 == 0 do net.send_udp(c.udp, req[:], c.server_ep)
		n, _, rerr := net.recv_udp(c.udp, buf[:])
		if rerr != nil || n < DISCOVERY_LEN do continue
		_, address, p, ok := parse_discovery(buf[:n], 2)
		if !ok do continue
		delete(c.external_ip)
		c.external_ip = strings.clone(address)
		c.external_port = int(p)
		if !c.udp_started {
			c.udp_started = true
			c.udp_th = thread.create_and_start_with_data(c, udp_thread_proc)
		}
		return true
	}
	return false
}

@(private)
on_session_description :: proc(c: ^Conn, d: json.Value) {
	key: [32]byte
	ka := jarr(jget(d, "secret_key"))
	if len(ka) != 32 do return
	for x, i in ka do key[i] = u8(jint(x, 0))
	mode := mode_from_name(jstr(jget(d, "mode")))
	if mode == .None do return
	sync.mutex_lock(&c.mu)
	c.mode = mode
	transport_init(&c.tx_crypto, mode, key[:])
	transport_init(&c.rx_crypto, mode, key[:])
	c.have_key = true
	sync.mutex_unlock(&c.mu)
	crypto.zero_explicit(&key, size_of(key))
	dv := jint(jget(d, "dave_protocol_version"))
	if dv < 0 || dv > 65535 {
		dave_invalid(c)
		return
	}
	dave.on_select_protocol_ack(&c.dave, int(dv))
	c.resumable = true
	set_state(c, .Connected)
	if !c.audio_started {
		c.audio_started = true
		if !c.opts.no_audio_devices do c.capture_on = audio.capture_start(true)
		c.next_rtcp_ms = now_ms() + 1000
		c.audio_th = thread.create_and_start_with_data(c, audio_thread_proc, priority = .High)
	}
}

@(private)
map_user :: proc(c: ^Conn, uid: u64, ssrc: u32) -> ^Remote_User {
	sync.mutex_lock(&c.mu)
	defer sync.mutex_unlock(&c.mu)
	if old, ok := c.user_ssrc[uid]; ok && old != ssrc {
		if u, uok := c.users[old]; uok {
			delete_key(&c.users, old)
			u.ssrc = ssrc
			c.users[ssrc] = u
			c.user_ssrc[uid] = ssrc
			return u
		}
	}
	if u, ok := c.users[ssrc]; ok {
		u.user_id = uid
		c.user_ssrc[uid] = ssrc
		return u
	}
	u := new(Remote_User)
	u.user_id = uid
	u.ssrc = ssrc
	jb_init(&u.jb)
	u.decoder = c.codec.decoder_create()
	c.users[ssrc] = u
	c.user_ssrc[uid] = ssrc
	return u
}

@(private)
destroy_user :: proc(c: ^Conn, u: ^Remote_User) {
	c.codec.decoder_destroy(u.decoder)
	if u.source != 0 do audio.source_destroy(u.source)
	free(u)
}

// ---------------------------------------------------------------------------
// Timer thread: heartbeats and the 20 s HELLO timeout.

@(private)
timer_thread_proc :: proc(data: rawptr) {
	c := cast(^Conn)data
	context.allocator = c.allocator
	for !stopped(c) {
		time.sleep(25 * time.Millisecond)
		now := now_ms()
		hello_timeout, beat, timeout := false, false, false
		sync.mutex_lock(&c.hb_mu)
		if c.hello_deadline_ms != 0 && now > c.hello_deadline_ms {
			c.hello_deadline_ms = 0
			hello_timeout = true
		}
		if c.hb_interval_ms > 0 && now >= c.next_hb_ms {
			c.next_hb_ms = now + c.hb_interval_ms
			if c.hb_acked {
				c.hb_acked = false
				beat = true
			} else {
				c.hb_interval_ms = 0
				timeout = true
			}
		}
		sync.mutex_unlock(&c.hb_mu)
		// HELLO timeout / HEARTBEAT ACK TIMEOUT: close(4000) and resume
		if hello_timeout || timeout do close_ws(c, CLOSE_FORCE)
		if beat do send_heartbeat(c)
		free_all(context.temp_allocator)
	}
}

// ---------------------------------------------------------------------------
// UDP receive

@(private)
udp_thread_proc :: proc(data: rawptr) {
	c := cast(^Conn)data
	context.allocator = c.allocator
	buf: [2048]byte
	plain: [2048]byte
	frame: [2048]byte
	for !stopped(c) {
		n, from, err := net.recv_udp(c.udp, buf[:])
		if err != nil || n <= 0 do continue
		_ = from
		pkt := buf[:n]
		sync.mutex_lock(&c.mu)
		c.stats.udp_datagrams += 1
		have := c.have_key
		sync.mutex_unlock(&c.mu)
		if !have do continue
		now := now_ms()
		if is_rtcp(pkt) {
			m, ok := transport_open(&c.rx_crypto, pkt, 8, plain[:])
			if !ok {
				count_failure(c)
				continue
			}
			sync.mutex_lock(&c.mu)
			c.stats.rtcp_received += 1
			sync.mutex_unlock(&c.mu)
			on_rtcp(c, plain[:m], now)
			continue
		}
		h, hok := parse_rtp_header(pkt)
		if !hok do continue
		m, ok := transport_open(&c.rx_crypto, pkt, h.aad_len, plain[:])
		if !ok {
			count_failure(c)
			continue
		}
		if h.pt != OPUS_PT || h.payload_off > m {
			sync.mutex_lock(&c.mu)
			c.stats.other_pt += 1
			sync.mutex_unlock(&c.mu)
			continue
		}
		end := m
		if plain[0] & 0x20 != 0 { 	// padding
			pad := int(plain[m - 1])
			if pad == 0 || pad > m - h.payload_off do continue
			end -= pad
		}
		payload := plain[h.payload_off:end]
		sync.mutex_lock(&c.mu)
		u, known := c.users[h.ssrc]
		uid: u64 = u.user_id if known else 0
		c.stats.packets_received += 1
		c.stats.bytes_received += u64(n)
		sync.mutex_unlock(&c.mu)
		if !known || uid == 0 {
			sync.mutex_lock(&c.mu)
			c.stats.unknown_ssrc += 1
			sync.mutex_unlock(&c.mu)
			continue // no op 5 yet: can't attribute (DAVE needs the sender)
		}
		fl, res := dave.session_decrypt(&c.dave, uid, payload, frame[:])
		if res == .Failed do continue
		opus := frame[:fl]
		silent := fl == 3 && opus[0] == 0xF8 && opus[1] == 0xFF && opus[2] == 0xFE
		if level, voice, lok := ext_audio_level(plain[:m], h); lok && !voice && level >= 127 do silent = true
		sync.mutex_lock(&c.mu)
		if uu, still := c.users[h.ssrc]; still {
			jb_push(&uu.jb, h.seq, h.ts, opus, f64(now))
			rx_update(&uu.rx, h.seq, h.ts, now)
			if !silent do uu.last_voice_ms = now
		}
		sync.mutex_unlock(&c.mu)
	}
}

@(private)
count_failure :: proc(c: ^Conn) {
	sync.mutex_lock(&c.mu)
	c.stats.transport_failures += 1
	sync.mutex_unlock(&c.mu)
}

// rx_update: RFC 3550 A.1 / A.8 receiver statistics.
@(private)
rx_update :: proc(r: ^Rx_Stats, seq: u16, ts: u32, now: i64) {
	if !r.init {
		r.init = true
		r.base_seq = seq
		r.max_seq = seq
	} else {
		delta := seq - r.max_seq
		if delta < 0x8000 {
			if seq < r.max_seq do r.cycles += 1 << 16
			r.max_seq = seq
		}
	}
	r.received += 1
	arrival := now * 48 // ms -> 48 kHz units
	transit := arrival - i64(ts)
	if r.received > 1 {
		d := abs(transit - r.transit)
		r.jitter += (f64(d) - r.jitter) / 16
	}
	r.transit = transit
}

@(private)
on_rtcp :: proc(c: ^Conn, b: []byte, now: i64) {
	rep, ok := parse_report(b)
	if !ok {
		dbg(c, "rtcp pt=%d len=%d (unparsed)", b[1], len(b))
		return
	}
	dbg(c, "rtcp %s ssrc=%d blocks=%d", "SR" if rep.is_sr else "RR", rep.ssrc, rep.n_blocks)
	for i in 0 ..< rep.n_blocks {
		bl := rep.blocks[i]
		dbg(c, "  block ssrc=%d lost=%d frac=%d maxseq=%d jitter=%d", bl.ssrc, bl.cum_lost, bl.fraction_lost, bl.ext_max_seq, bl.jitter)
	}
	sync.mutex_lock(&c.mu)
	defer sync.mutex_unlock(&c.mu)
	if rep.is_sr {
		if u, has := c.users[rep.ssrc]; has {
			u.rx.lsr = u32(rep.ntp >> 16)
			u.rx.lsr_at_ms = now
		}
	}
	for i in 0 ..< rep.n_blocks {
		blk := rep.blocks[i]
		if blk.ssrc != c.ssrc || blk.lsr == 0 do continue
		ntp_mid := u32(ntp_now() >> 16)
		rtt := ntp_mid - blk.lsr - blk.dlsr // 1/65536 s
		c.stats.rtt_ms = int(u64(rtt) * 1000 / 65536)
	}
}

@(private)
ntp_now :: proc() -> u64 {
	ns := time.to_unix_nanoseconds(time.now())
	secs := u64(ns / 1e9) + 2_208_988_800
	frac := u64(ns % 1e9) * (1 << 32) / 1e9
	return secs << 32 | frac
}

// ---------------------------------------------------------------------------
// Audio thread: 20 ms ticks. Send: mic -> VAD -> Opus -> DAVE -> RTP -> AEAD.
// Receive: jitter buffer -> Opus (FEC/PLC) -> volume -> output.

@(private)
audio_thread_proc :: proc(data: rawptr) {
	c := cast(^Conn)data
	context.allocator = c.allocator
	pcm: [SAMPLES_PER_FRAME]f32
	out: [SAMPLES_PER_FRAME * 2]f32
	next := time.tick_now()
	for !stopped(c) {
		next = time.tick_add(next, 20 * time.Millisecond)
		tx_tick(c, pcm[:])
		rx_tick(c, out[:])
		if now_ms() >= c.next_rtcp_ms do send_rtcp(c)
		free_all(context.temp_allocator)
		left := time.tick_diff(time.tick_now(), next)
		if left > 0 {
			time.accurate_sleep(left)
		} else if left < -200 * time.Millisecond {
			next = time.tick_now() // fell far behind: resync
		}
	}
}

@(private)
read_mic :: proc(c: ^Conn, pcm: []f32) {
	n := 0
	if c.opts.no_audio_devices {
		if c.opts.capture != nil do n = c.opts.capture(c.opts.callback_data, pcm)
	} else if c.capture_on {
		// keep latency bounded: drop backlog beyond 3 frames
		for audio.capture_available() > 4 * SAMPLES_PER_FRAME {
			_ = audio.capture_read(pcm)
		}
		n = audio.capture_read(pcm)
	}
	for i in n ..< len(pcm) do pcm[i] = 0
}

@(private)
tx_tick :: proc(c: ^Conn, pcm: []f32) {
	read_mic(c, pcm)
	sync.mutex_lock(&c.mu)
	muted := c.self_mute || c.self_deaf
	sync.mutex_unlock(&c.mu)
	active, db := vad_process(&c.vad, pcm)
	if muted do active = false
	frame_ts := c.ts
	c.ts += SAMPLES_PER_FRAME
	if active {
		if !c.self_speaking {
			send_text(c, msg_speaking(SPEAKING_VOICE, c.ssrc))
			sync.mutex_lock(&c.mu)
			c.self_speaking = true
			sync.mutex_unlock(&c.mu)
			// leading frames (pre-roll), with their original timestamps
			for i in 0 ..< c.preroll_n {
				pts := frame_ts - u32(c.preroll_n - i) * SAMPLES_PER_FRAME
				send_audio(c, c.preroll[i][:], pts, frame_level_db(c.preroll[i][:]), true)
			}
		}
		c.preroll_n = 0
		c.silence_left = 5
		send_audio(c, pcm, frame_ts, db, true)
		return
	}
	if c.self_speaking {
		if c.silence_left > 0 {
			// five Opus silence frames on speaking stop
			c.silence_left -= 1
			s := OPUS_SILENCE_FRAME
			send_opus(c, s[:], frame_ts, 127, false)
			if c.silence_left == 0 {
				send_text(c, msg_speaking(0, c.ssrc))
				sync.mutex_lock(&c.mu)
				c.self_speaking = false
				sync.mutex_unlock(&c.mu)
			}
		}
		return
	}
	if muted {
		c.preroll_n = 0
		return
	}
	// shift pre-roll
	if c.preroll_n == len(c.preroll) {
		for i in 1 ..< len(c.preroll) do c.preroll[i - 1] = c.preroll[i]
		c.preroll_n -= 1
	}
	copy(c.preroll[c.preroll_n][:], pcm)
	c.preroll_n += 1
}

@(private)
send_audio :: proc(c: ^Conn, pcm: []f32, ts: u32, db: f32, voice: bool) {
	opus: [MAX_OPUS_PACKET]byte
	n := c.codec.encode(c.encoder, pcm, opus[:])
	if n <= 0 do return
	send_opus(c, opus[:n], ts, audio_level_byte(db), voice)
}

@(private)
send_opus :: proc(c: ^Conn, opus: []byte, ts: u32, level: u8, voice: bool) {
	if !c.udp_open do return
	frame: [MAX_OPUS_PACKET + dave.MAX_SUPPLEMENTAL]byte
	fl := dave.session_encrypt(&c.dave, opus, frame[:])
	if fl <= 0 do return
	pkt: [MAX_OPUS_PACKET + 128]byte
	sealed: [MAX_OPUS_PACKET + 160]byte
	plen, aad := build_audio_rtp(pkt[:], c.seq, ts, c.ssrc, level, voice, c.twcc, frame[:fl])
	sync.mutex_lock(&c.mu)
	if !c.have_key {
		sync.mutex_unlock(&c.mu)
		return
	}
	nonce := c.tx_nonce
	c.tx_nonce += 1
	sl := transport_seal(&c.tx_crypto, pkt[:plen], aad, nonce, sealed[:])
	c.stats.packets_sent += 1
	c.stats.bytes_sent += u64(sl)
	sync.mutex_unlock(&c.mu)
	c.seq += 1
	c.twcc += 1
	c.packets_sent += 1
	c.octets_sent += u32(fl)
	c.last_sent_ts = ts
	net.send_udp(c.udp, sealed[:sl], c.server_ep)
}

@(private)
rx_tick :: proc(c: ^Conn, out: []f32) {
	sync.mutex_lock(&c.mu)
	defer sync.mutex_unlock(&c.mu)
	deaf := c.self_deaf
	for _, u in c.users {
		kind, data := jb_pop(&u.jb)
		if kind == .None do continue
		n := 0
		switch kind {
		case .Packet:
			n = c.codec.decode(u.decoder, data, false, out)
		case .Fec:
			n = c.codec.decode(u.decoder, data, true, out)
		case .Plc:
			n = c.codec.decode(u.decoder, nil, false, out)
		case .None:
		}
		if n <= 0 || deaf do continue
		st := c.settings[u.user_id] or_else User_Settings{volume = 1}
		if st.muted do continue
		frames := out[:n * 2]
		if st.volume != 1 do for &s in frames do s *= st.volume
		if c.opts.no_audio_devices {
			if c.opts.playback != nil do c.opts.playback(c.opts.callback_data, u.user_id, frames)
		} else {
			if u.source == 0 do u.source = audio.source_create()
			if u.source != 0 do audio.source_write(u.source, frames)
		}
	}
}

// send_rtcp: SR (when we have sent since the last report) or RR, with one
// report block per remote stream; ~5 s randomized interval (RFC 3550 6.3.1).
@(private)
send_rtcp :: proc(c: ^Conn) {
	now := now_ms()
	c.next_rtcp_ms = now + 2500 + i64(rand.int31_max(5000))
	if !c.udp_open do return
	blocks := make([dynamic]Report_Block, 0, 8, context.temp_allocator)
	sync.mutex_lock(&c.mu)
	for _, u in c.users {
		r := &u.rx
		if !r.init do continue
		ext_max := r.cycles + u32(r.max_seq)
		expected := ext_max - u32(r.base_seq) + 1
		lost := i32(expected) - i32(r.received)
		exp_int := expected - r.expected_prior
		rec_int := r.received - r.received_prior
		r.expected_prior = expected
		r.received_prior = r.received
		lost_int := i32(exp_int) - i32(rec_int)
		frac: u8 = 0
		if exp_int != 0 && lost_int > 0 do frac = u8((u32(lost_int) << 8) / exp_int)
		dlsr: u32 = 0
		if r.lsr != 0 do dlsr = u32((now - r.lsr_at_ms) * 65536 / 1000)
		append(&blocks, Report_Block{u.ssrc, frac, lost, ext_max, u32(r.jitter), r.lsr, dlsr})
	}
	have := c.have_key
	sync.mutex_unlock(&c.mu)
	if !have do return
	pkt: [512]byte
	sealed: [600]byte
	sender := c.packets_sent > 0
	n := build_report(pkt[:], c.ssrc, sender, ntp_now(), c.last_sent_ts, c.packets_sent, c.octets_sent, blocks[:])
	sync.mutex_lock(&c.mu)
	nonce := c.tx_nonce
	c.tx_nonce += 1
	sl := transport_seal(&c.tx_crypto, pkt[:n], 8, nonce, sealed[:])
	sync.mutex_unlock(&c.mu)
	net.send_udp(c.udp, sealed[:sl], c.server_ep)
}
