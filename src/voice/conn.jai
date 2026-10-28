// The Discord voice client: voice gateway (WebSocket v9), UDP media (RTP/RTCP
// with rtpsize AEAD transport encryption), DAVE E2EE (voice_dave over
// voice_mls), jitter buffering, VAD and speaking.
//
//	c := voice.voice_connect(.{...});
//	voice.set_self_mute(c, true);
//	ids := voice.speaking_users(c,, temp);
//	voice.voice_disconnect(c);
//
// Threads per connection: gateway (WebSocket read loop + reconnect/resume),
// timer (heartbeats, hello timeout), UDP receive, audio (20 ms send/playout).
// They inherit the allocator current at voice_connect, which frees everything
// in voice_disconnect.

// Voice_Server_Info: everything the discord module learns from the main gateway.
//   endpoint:            VOICE_SERVER_UPDATE.endpoint ("c-lax07-200a12c1.discord.media:2096"; port optional, default 443)
//   token:               VOICE_SERVER_UPDATE.token
//   guild_or_channel_id: VOICE_SERVER_UPDATE.guild_id, or for DM/group calls the call's channel_id (sent as server_id)
//   user_id:             our user id
//   session_id:          our VOICE_STATE_UPDATE.session_id (= main gateway session id)
//   channel_id:          the voice channel / DM channel id
//   stream:              a Go Live connection (STREAM_SERVER_UPDATE; server_id = rtc_server_id):
//                        identifies with a "screen" stream and never sends the microphone
Voice_Server_Info :: struct {
    endpoint: string;
    token: string;
    guild_or_channel_id: u64;
    user_id: u64;
    session_id: string;
    channel_id: u64;
    stage: bool;              // stage channel (allows DAVE version 0)
    stream: bool;
    user_agent: string;       // "" = official desktop UA
    accept_language: string;  // "" = "en-US"
}

Conn_State :: enum u8 {
    Connecting;    // dialing the voice gateway
    Identifying;   // IDENTIFY sent, waiting for READY
    Discovering;   // UDP IP discovery / SELECT_PROTOCOL
    Connected;     // SESSION_DESCRIPTION received, media flowing
    Resuming;      // reconnecting with RESUME
    Disconnected;  // terminal; see close_code
}

Dial_Proc :: #type (host: string, port: int) -> netio.Stream, bool;

Options :: struct {
    dial: Dial_Proc;          // null = TCP + TLS (ALPN http/1.1, SNI = host)
    no_audio_devices: bool;   // don't touch the audio module (tests / headless)
    capture: (data: *void, out: []float32) -> int;          // mono 48 kHz pull, used when no_audio_devices
    playback: (data: *void, user_id: u64, pcm: []float32);  // stereo interleaved, 960 frames
    // a received video frame (Annex B, decrypted), on the UDP thread; the data is valid during the call
    video: (data: *void, user_id: u64, codec: Video_Codec, au: []u8, keyframe: bool);
    callback_data: *void;
    vad_manual: bool;         // manual threshold instead of auto
    vad_threshold_db: float32; // manual threshold (0 = -60 dB default)
}

Stats :: struct {
    ws_ping_ms: int;
    rtt_ms: int;  // from RTCP receiver reports about our stream
    packets_sent: u64;
    packets_received: u64;
    bytes_sent: u64;
    bytes_received: u64;
    transport_failures: u64;
    udp_datagrams: u64;  // everything that arrived on the socket
    rtcp_received: u64;
    other_pt: u64;       // RTP with a payload type other than opus or video
    video_frames_received: u64;
    video_frames_sent: u64;
    plis_sent: u64;
    unknown_ssrc: u64;   // audio from an SSRC no op 5 mapped yet
    remote_users: int;
    e2ee_failures: u64;
    reconnects: int;
    jitter: Jitter_Stats;  // summed over remote users
}

// Timeline: when each connection step happened (epoch ms, 0 = not yet), for the
// app's telemetry (discord.analytics_voice_*). Read with timeline(c).
Timeline :: struct {
    created, ws_open, ready, select_sent, connected: s64;
    udp_port: int;
    media_session_id: string; // from SESSION_DESCRIPTION (owned by the connection)
}

User_Settings :: struct {
    volume: float32 = 1;  // 0..2, 1 = unchanged
    muted: bool;
}

Rx_Stats :: struct {
    base_seq, max_seq: u16;
    cycles: u32;
    received: u32;
    expected_prior: u32;
    received_prior: u32;
    transit: s64;
    jitter: float64;  // in timestamp units
    lsr: u32;
    lsr_at_ms: s64;
    init: bool;
}

Remote_User :: struct {
    user_id: u64;
    ssrc: u32;
    speaking_flag: int;  // from op 5
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
    mu: locks.Mutex;     // users, stats, state
    ws_mu: locks.Mutex;  // ws pointer + sends
    state: Conn_State;
    close_code: int;
    stop: bool;          // atomic
    state_cond: locks.Cond;

    ws: *http.Ws_Conn;
    ws_stream: netio.Stream;
    ws_open: bool;
    server_version: int;
    hb_interval_ms: s64;
    next_hb_ms: s64;
    hb_acked: bool;
    last_ack_ms: s64;
    expedite_ms: s64;    // an expedited heartbeat's ACK deadline (waking from sleep), 0: none
    hello_deadline_ms: s64;
    hb_mu: locks.Mutex;  // heartbeat fields above (gateway <-> timer thread)
    session_ok: bool;    // READY/RESUMED seen on the current socket (backoff.succeed)
    last_seq: s64 = -1;
    resumable: bool;

    udp: Socket;
    udp_open: bool;
    server_ep: Udp_Addr;
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
    users: Table(u32, *Remote_User);
    user_ssrc: Table(u64, u32);
    settings: Table(u64, User_Settings);
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
    tl: Timeline;        // under mu

    ws_th, timer_th, udp_th, audio_th: *Thread;
    udp_started: bool;
    audio_started: bool;
    capture_on: bool;
    mic_waits: int;             // ticks in a row without a whole mic frame (audio thread)
    echo_on, denoise_on, agc_on: bool;  // the voice processing switches (under mu)
    diag: struct {              // send side, summed for the debug trace every 2 s (audio thread)
        frames, padded, voiced, enc_drops: int;
        min_avail, max_avail: int;
        at_ms: s64;
    };
    udp_errors: u64;            // atomic: failed sendto
    udp_errno: s32;             // the last failure's errno
    aec: *void;                 // WebRTC echo canceller state, made on first use (audio thread)
    denoiser: *void;            // RNNoise state, made on first use (audio thread)
    agc: Agc;                   // (audio thread)
    input_gain: float32 = 1;    // software input volume (1 = unchanged)
    input_limiter: audio.Limiter;
    input_db: float32 = -127;   // level of the last mic frame (after gain)
    vad_open: bool;
    ptt_mode: bool;     // push-to-talk instead of voice activity
    ptt_pressed: bool;
    ptt_until_ms: s64;  // release delay end
    debug: bool;        // FASTCORD_VOICE_DEBUG=1: protocol trace on stderr (no secrets)

    // video: our stream's SSRCs from READY, the codec SESSION_DESCRIPTION chose
    video_ssrc, rtx_ssrc: u32;
    video_codec: Video_Codec;
    video_rx: Table(u32, *Video_Rx);  // remote video SSRC -> reassembly (under mu)
    video_users: Table(u64, bool);    // users whose op 12 has an active stream (under mu)
    vmu: locks.Mutex;                 // the send side below (encoder thread vs. RTCP)
    video_on: bool;
    video_announce: bool;  // op 12 due (timer thread)
    cant_encode: u8;       // a bit per Video_Codec the server picked but we can't encode
    codecs_due: bool;      // op 14 due (timer thread)
    video_w, video_h, video_fps, video_bitrate: int;
    video_seq: u16;
    video_packets, video_octets, video_last_ts: u32;
    keyframe_wanted: bool;            // atomic: a PLI/FIR for our stream arrived
}

dbg :: (c: *Conn, format: string, args: ..Any) {
    if c.debug print("[voice %] %\n", c.info.user_id, tprint(format, ..args), to_standard_error = true);
}

WAKE_GAP_MS :: 15_000; // a timer gap this long means the machine slept

now_ms :: () -> s64 { return to_milliseconds(current_time_consensus() - APOLLO_TIME_FOR_JAN_1_1970); }

stopped :: (c: *Conn) -> bool { return atomic_load(*c.stop); }

set_state :: (c: *Conn, s: Conn_State) {
    locks.guard(*c.mu);
    c.state = s;
    locks.cond_broadcast(*c.state_cond);
}

start_thread :: (c: *Conn, proc: (*Thread) -> s64) -> *Thread {
    t := New(Thread);
    thread_init(t, proc);
    t.data = c;
    thread_start(t);
    return t;
}

// ---------------------------------------------------------------------------
// Public API

voice_connect :: (info: Voice_Server_Info, opts := Options.{}) -> *Conn {
    c := New(Conn);
    c.info = info;
    c.info.endpoint = copy_string(info.endpoint);
    c.info.token = copy_string(info.token);
    c.info.session_id = copy_string(info.session_id);
    c.info.user_agent = copy_string(ifx info.user_agent then info.user_agent else DEFAULT_USER_AGENT);
    c.info.accept_language = copy_string(ifx info.accept_language then info.accept_language else "en-US");
    c.opts = opts;
    c.host, c.port = split_endpoint(c.info.endpoint);
    c.rtc_connection_id = uuid4();
    c.codec = get_codec();
    c.encoder = c.codec.encoder_create();
    if opts.vad_manual {
        c.vad.auto_threshold = false;
        if opts.vad_threshold_db != 0 c.vad.threshold_db = opts.vad_threshold_db;
    }
    // WebRTC randomizes the initial sequence number and timestamp
    rb: [6]u8;
    crypto.random_bytes(rb);
    c.seq = get_u16(rb);
    c.ts = get_u32(rb, 2);
    DAVE.session_init(*c.dave, info.user_id, info.channel_id, info.stage);
    c.state = .Connecting;
    c.tl.created = now_ms();
    env := getenv("FASTCORD_VOICE_DEBUG");
    c.debug = env && to_string(env) == "1";
    c.ws_th = start_thread(c, ws_thread_proc);
    c.timer_th = start_thread(c, timer_thread_proc);
    return c;
}

// voice_disconnect closes the gateway (code 4000, as the client's close()),
// stops all threads and frees the connection.
voice_disconnect :: (c: *Conn) {
    if !c return;
    atomic_store(*c.stop, true);
    close_ws(c, CLOSE_FORCE);
    // The ws thread starts udp_th and audio_th, so read those handles only after it has exited.
    locks.join(c.ws_th);
    for th: (*Thread).[c.timer_th, c.udp_th, c.audio_th] if th locks.join(th);
    if c.capture_on audio.capture_stop();
    if c.udp_open close_and_reset(*c.udp);
    transport_reset(*c.tx_crypto);
    transport_reset(*c.rx_crypto);
    for c.users destroy_user(c, it);
    deinit(*c.users);
    for c.video_rx { array_free(it.au); free(it); }
    deinit(*c.video_rx);
    deinit(*c.video_users);
    deinit(*c.user_ssrc);
    deinit(*c.settings);
    for c.experiments free(it);
    array_free(c.experiments);
    free(c.external_ip);
    c.codec.encoder_destroy(c.encoder);
    if c.aec fc_aec_destroy(c.aec);
    if c.denoiser fc_rnnoise_destroy(c.denoiser);
    DAVE.session_destroy(*c.dave);
    free(c.info.endpoint);
    free(c.info.token);
    free(c.info.session_id);
    free(c.info.user_agent);
    free(c.info.accept_language);
    free(c.rtc_connection_id);
    free(c.tl.media_session_id);
    free(c);
}

// timeline: a copy (media_session_id in context.allocator).
timeline :: (c: *Conn) -> Timeline {
    locks.guard(*c.mu);
    t := c.tl;
    t.media_session_id = copy_string(t.media_session_id);
    return t;
}

// note: the first time a step happens (mu not held).
note :: (c: *Conn, at: *s64) {
    locks.guard(*c.mu);
    if !at.* at.* = now_ms();
}

state :: (c: *Conn) -> Conn_State, int {
    locks.guard(*c.mu);
    return c.state, c.close_code;
}

// wait_state blocks until the connection reaches s (or Disconnected) or timeout_ms passes.
wait_state :: (c: *Conn, s: Conn_State, timeout_ms: s64) -> bool {
    start := current_time_monotonic();
    locks.guard(*c.mu);
    while c.state != s && c.state != .Disconnected {
        left := timeout_ms - to_milliseconds(current_time_monotonic() - start);
        if left <= 0 break;
        locks.cond_wait_with_timeout(*c.state_cond, *c.mu, left);
    }
    return c.state == s;
}

set_self_mute :: (c: *Conn, muted: bool) {
    locks.guard(*c.mu);
    c.self_mute = muted;
}

// set_self_deaf: deafened implies no playout and no sending (like the client).
set_self_deaf :: (c: *Conn, deaf: bool) {
    locks.guard(*c.mu);
    c.self_deaf = deaf;
    if deaf for c.users if it.source audio.source_flush(it.source);
}

user_settings :: (c: *Conn, user_id: u64) -> *User_Settings {
    s, added := find_or_add(*c.settings, user_id);
    if added s.* = .{};
    return s;
}

set_user_volume :: (c: *Conn, user_id: u64, volume: float32) {
    locks.guard(*c.mu);
    user_settings(c, user_id).volume = clamp(volume, 0, 4);
}

set_user_mute :: (c: *Conn, user_id: u64, muted: bool) {
    locks.guard(*c.mu);
    user_settings(c, user_id).muted = muted;
}

// set_input_sensitivity: auto threshold (the client's default) or a manual dB threshold.
set_input_sensitivity :: (c: *Conn, auto_threshold: bool, threshold_db: float32) {
    locks.guard(*c.mu);
    c.vad.auto_threshold = auto_threshold;
    c.vad.threshold_db = threshold_db;
}

// set_push_to_talk: PTT mode transmits only while pressed (+ release delay,
// the client's pttReleaseDelay default 20 ms) instead of on voice activity.
set_push_to_talk :: (c: *Conn, enabled: bool, pressed: bool, release_delay_ms := 20) {
    locks.guard(*c.mu);
    c.ptt_mode = enabled;
    if c.ptt_pressed && !pressed c.ptt_until_ms = now_ms() + release_delay_ms;
    c.ptt_pressed = pressed;
}

// set_input_gain: input volume, 0..4 (Settings > Voice > Input Volume).
set_input_gain :: (c: *Conn, gain: float32) {
    locks.guard(*c.mu);
    c.input_gain = clamp(gain, 0, 4);
}

// set_processing: the Voice Processing switches, all done here on every platform: WebRTC's echo
// canceller (the official client's too), RNNoise for noise (it has Krisp) and our AGC.
set_processing :: (c: *Conn, echo: bool, noise: bool, agc: bool) {
    locks.guard(*c.mu);
    c.echo_on, c.denoise_on, c.agc_on = echo, noise, agc;
}

// input_level: last mic frame level in dBFS and whether the VAD is open (for meters).
input_level :: (c: *Conn) -> db: float32, open: bool {
    locks.guard(*c.mu);
    return c.input_db, c.vad_open;
}

SPEAKING_HOLD_MS :: 250;

// speaking_users: users heard within the last 250 ms (and ourselves while
// our VAD is open and we are not muted), in context.allocator.
speaking_users :: (c: *Conn) -> []u64 {
    locks.guard(*c.mu);
    now := now_ms();
    out: [..]u64;
    array_reserve(*out, c.users.count + 1);
    if c.self_speaking array_add(*out, c.info.user_id);
    for c.users if it.user_id && now - it.last_voice_ms < SPEAKING_HOLD_MS array_add(*out, it.user_id);
    return out;
}

is_speaking :: (c: *Conn, user_id: u64) -> bool {
    found := array_find(speaking_users(c,, temp), user_id);
    return found;
}

get_stats :: (c: *Conn) -> Stats {
    locks.guard(*c.mu);
    s := c.stats;
    s.remote_users = c.users.count;
    s.jitter = .{};
    for c.users {
        js := *it.jb.stats;
        s.jitter.received += js.received;
        s.jitter.late += js.late;
        s.jitter.lost += js.lost;
        s.jitter.concealed += js.concealed;
        s.jitter.fec_recovered += js.fec_recovered;
        s.jitter.dropped += js.dropped;
        s.jitter.jitter_ms = max(s.jitter.jitter_ms, js.jitter_ms);
        s.jitter.target_frames = max(s.jitter.target_frames, js.target_frames);
    }
    s.e2ee_failures = DAVE.session_status(*c.dave,, temp).stats.decrypt_failures;
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

// e2ee_status: privacy_code in context.allocator.
e2ee_status :: (c: *Conn) -> E2EE_Status {
    ds := DAVE.session_status(*c.dave);
    return .{ds.protocol_version, ds.e2ee_active, ds.epoch, ds.privacy_code, ds.members};
}

privacy_code :: (c: *Conn) -> string { return e2ee_status(c).privacy_code; }

// verification_code: 45-digit pairwise identity fingerprint with user (slow: scrypt), in context.allocator.
verification_code :: (c: *Conn, user_id: u64) -> string, bool {
    code, ok := DAVE.session_verification_code(*c.dave, user_id);
    return code, ok;
}

// ---------------------------------------------------------------------------
// Gateway thread

split_endpoint :: (ep: string) -> host: string, port: int {
    e := ep;
    if begins_with(e, "wss://") advance(*e, 6);
    _, e = split_from_left(e, #char "/");
    found, host, port := split_from_right(e, #char ":");
    if found {
        p, ok, rest := string_to_int(port);
        if ok && !rest return host, p;
    }
    return e, 443;
}

default_dial :: (host: string, port: int) -> netio.Stream, bool {
    tcp, err := netio.dial_tcp(host, port);
    if err != .None return .{}, false;
    under := netio.tcp_stream(tcp);
    sess, terr := tls.connect(under, .{alpn = .["http/1.1"], server_name = host});
    if terr != .None {
        netio.close(under);
        return .{}, false;
    }
    return tls.stream(sess), true;
}

// voice_ws_headers: Chrome's WebSocket upgrade request, header order as captured (in temp).
voice_ws_headers :: (c: *Conn) -> []http.Header {
    h := NewArray(12, http.Header,, temp);
    h[0]  = .{"Host", ifx c.port == 443 then c.host else tprint("%:%", c.host, c.port)};
    h[1]  = .{"Connection", "Upgrade"};
    h[2]  = .{"Pragma", "no-cache"};
    h[3]  = .{"Cache-Control", "no-cache"};
    h[4]  = .{"User-Agent", c.info.user_agent};
    h[5]  = .{"Upgrade", "websocket"};
    h[6]  = .{"Origin", "https://discord.com"};
    h[7]  = .{"Sec-WebSocket-Version", "13"};
    h[8]  = .{"Accept-Encoding", "gzip, deflate, br, zstd"};
    h[9]  = .{"Accept-Language", c.info.accept_language};
    h[10] = .{"Sec-WebSocket-Key", ""};
    h[11] = .{"Sec-WebSocket-Extensions", "permessage-deflate; client_max_window_bits"};
    return h;
}

send_ws :: (c: *Conn, type: http.Ws_Message_Type, payload: []u8) -> bool {
    locks.guard(*c.ws_mu);
    if !c.ws || !c.ws_open return false;
    return http.ws_send(c.ws, type, payload) == .None;
}

send_text :: (c: *Conn, s: string) -> bool { return send_ws(c, .Text, cast([]u8) s); }

send_binary :: (c: *Conn, op: int, payload: []u8) -> bool {
    buf := NewArray(payload.count + 1, u8,, temp);
    buf[0] = cast(u8) op;
    memcpy(buf.data + 1, payload.data, payload.count);
    return send_ws(c, .Binary, buf);
}

close_ws :: (c: *Conn, code: int) {
    locks.guard(*c.ws_mu);
    if c.ws && c.ws_open {
        http.ws_close(c.ws, code, "");
        netio.shutdown(c.ws_stream);
    }
}

// RTCControlSocket.handleClose disconnects at once on 4004, 4006, 4011 and 4015; 4014 (kicked or moved)
// and 4022 go through the resume backoff like any other close. The DAVE codes are our own closes.
terminal_close :: (code: int) -> bool {
    found := array_find(int.[CLOSE_AUTHENTICATION_FAILED, CLOSE_INVALID_SESSION, CLOSE_SERVER_NOT_FOUND, CLOSE_SERVER_CRASH,
        CLOSE_REPEATED_MLS_INVALID, CLOSE_DAVE_DOWNGRADE_REFUSED, CLOSE_DAVE_INVALID_MESSAGE, CLOSE_UNRESUMABLE], code);
    return found;
}

ws_thread_proc :: (t: *Thread) -> s64 {
    c := cast(*Conn) t.data;
    fails := 0;
    resuming := false;
    while !stopped(c) {
        code := ws_session(c, resuming);
        reset_temporary_storage();
        if stopped(c) break;
        if terminal_close(code) {
            finish(c, code);
            return 0;
        }
        // RTCControlSocket.handleClose: backoff (1 s .. 5 s), give up after 4 failures
        if c.session_ok fails = 0;
        c.session_ok = false;
        locks.lock(*c.hb_mu);
        last_ack := c.last_ack_ms;
        locks.unlock(*c.hb_mu);
        if fails > 3 || !c.resumable || (last_ack != 0 && now_ms() - last_ack > 60_000) {
            finish(c, ifx code == 0 || !c.resumable then CLOSE_UNRESUMABLE else code);
            return 0;
        }
        delay := min(1000 << fails, 5000);
        fails += 1;
        resuming = true;
        set_state(c, .Resuming);
        {
            locks.guard(*c.mu);
            c.stats.reconnects += 1;
        }
        // resetBackoff: waking from sleep (a gap in this loop) reconnects at once
        last := now_ms();
        for 1..delay / 50 {
            if stopped(c) || now_ms() - last > WAKE_GAP_MS break;
            last = now_ms();
            sleep_milliseconds(50);
        }
    }
    return 0;
}

finish :: (c: *Conn, code: int) {
    {
        locks.guard(*c.mu);
        c.close_code = code;
        c.state = .Disconnected;
        locks.cond_broadcast(*c.state_cond);
    }
    atomic_store(*c.stop, true);
}

// ws_session runs one WebSocket connection; returns the close code (0 = transport error).
ws_session :: (c: *Conn, resume: bool) -> int {
    if !resume set_state(c, .Connecting);
    dial := ifx c.opts.dial then c.opts.dial else default_dial;
    stream, ok := dial(c.host, c.port);
    if !ok return 0;
    req := http.Request.{method = "GET", scheme = "https", authority = c.host, path = "/?v=9", headers = voice_ws_headers(c)};
    ws, resp, err := http.ws_connect(stream, req);
    http.response_destroy(*resp);
    if err != .None {
        netio.close(stream);
        return 0;
    }
    netio.set_timeout(stream, 0);
    {
        locks.guard(*c.ws_mu);
        c.ws = ws;
        c.ws_stream = stream;
        c.ws_open = true;
        // voice_disconnect found no socket to shut down while this one was connecting.
        if stopped(c) netio.shutdown(stream);
    }
    note(c, *c.tl.ws_open);
    {
        locks.guard(*c.hb_mu);
        c.hello_deadline_ms = now_ms() + 20_000;
        c.hb_interval_ms = 0;
    }
    if resume {
        send_text(c, msg_resume(c.info.token, c.info.session_id, c.info.guild_or_channel_id, c.info.channel_id, c.last_seq));
    } else {
        set_state(c, .Identifying);
        send_text(c, msg_identify(c.info.guild_or_channel_id, c.info.channel_id, c.info.user_id, c.info.session_id, c.info.token, true, c.info.stream));
    }
    msg: [..]u8;
    defer array_free(msg);
    code := 0;
    while !stopped(c) {
        mt, rerr := http.ws_recv(ws, *msg);
        if rerr != .None {
            if rerr == .Closed code = ws.close_code;
            break;
        }
        if mt == .Text handle_json(c, cast(string) msg);
        else handle_binary(c, msg);
        flush_dave(c);
        cr := DAVE.session_close_request(*c.dave);
        if cr != .None {
            code = CLOSE_REPEATED_MLS_INVALID + cast(int) cr - 1;
            close_ws(c, code);
            break;
        }
        reset_temporary_storage();
    }
    {
        locks.guard(*c.ws_mu);
        c.ws_open = false;
        c.ws = null;
    }
    {
        locks.guard(*c.hb_mu);
        c.hb_interval_ms = 0;
        c.hello_deadline_ms = 0;
    }
    http.ws_destroy(ws);
    netio.close(stream);
    return code;
}

flush_dave :: (c: *Conn) {
    for DAVE.session_take_outgoing(*c.dave,, temp) {
        if it.op == DAVE.OP_MLS_KEY_PACKAGE || it.op == DAVE.OP_MLS_COMMIT_WELCOME
            send_binary(c, it.op, it.data);
        else if it.op == DAVE.OP_READY_FOR_TRANSITION || it.op == DAVE.OP_MLS_INVALID_COMMIT_WELCOME
            send_text(c, msg_transition(it.op, it.transition_id));
        array_free(it.data);
    }
}

// in_u16: a transition id or protocol version must fit 16 bits.
in_u16 :: (x: s64) -> bool { return x >= 0 && x <= 65535; }

handle_json :: (c: *Conn, text: string) {
    v, err := etf.from_json(text,, temp);
    if err != .None return;
    op := jint(jget(v, "op"));
    if c.debug && op != OP_HEARTBEAT_ACK && op != OP_SESSION_DESCRIPTION dbg(c, "<~ %", slice(text, 0, min(text.count, 400)));
    s := jint(jget(v, "seq"), 0);
    if s != 0 c.last_seq = s;  // `r && (lastRecvSeqNum = r)`
    d := jget(v, "d");
    if op == {
      case OP_HELLO;
        c.server_version = jint(jget(d, "v"), 3);
        iv := jint(jget(d, "heartbeat_interval"), 13750);
        locks.guard(*c.hb_mu);
        c.hello_deadline_ms = 0;
        // desktop (isPlatformEmbedded): interval * modifier, no 5 s cap; v<=3: 25 %
        c.hb_interval_ms = ifx c.server_version <= 3 then iv / 4 else iv;
        c.hb_acked = true;
        c.next_hb_ms = now_ms() + c.hb_interval_ms;
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
        {
            locks.guard(*c.mu);
            c.stats.ws_ping_ms = now - t;
        }
        locks.guard(*c.hb_mu);
        c.last_ack_ms = now;
        c.hb_acked = true;
        c.expedite_ms = 0;
      case OP_SPEAKING;
        uid := jsnow(jget(d, "user_id"));
        ssrc := cast,no_check(u32) jint(jget(d, "ssrc"), 0);
        if uid && ssrc {
            u := map_user(c, uid, ssrc);
            locks.guard(*c.mu);
            u.speaking_flag = jint(jget(d, "speaking"), 0);
        }
      case OP_VIDEO;
        uid := jsnow(jget(d, "user_id"));
        ssrc := cast,no_check(u32) jint(jget(d, "audio_ssrc"), 0);
        if uid && ssrc map_user(c, uid, ssrc);
        if uid on_remote_video(c, uid, d);
      case OP_CLIENTS_CONNECT;
        ids: [..]u64;
        ids.allocator = temp;
        for jarr(jget(d, "user_ids")) array_add(*ids, jsnow(it));
        DAVE.on_clients_connect(*c.dave, ids);
      case OP_CLIENT_DISCONNECT;
        uid := jsnow(jget(d, "user_id"));
        DAVE.on_client_disconnect(*c.dave, uid);
        locks.guard(*c.mu);
        drop_video_rx(c, uid);
        table_remove(*c.video_users, uid);
        found, ssrc := table_remove(*c.user_ssrc, uid);
        if found {
            had, u := table_remove(*c.users, ssrc);
            if had destroy_user(c, u);
        }
      case DAVE.OP_PREPARE_TRANSITION;
        tid, pv := jint(jget(d, "transition_id")), jint(jget(d, "protocol_version"));
        if !in_u16(tid) || !in_u16(pv) { dave_invalid(c); return; }
        DAVE.on_prepare_transition(*c.dave, tid, pv);
      case DAVE.OP_EXECUTE_TRANSITION;
        tid := jint(jget(d, "transition_id"));
        if !in_u16(tid) { dave_invalid(c); return; }
        DAVE.on_execute_transition(*c.dave, tid);
      case DAVE.OP_PREPARE_EPOCH;
        ep, pv := jint(jget(d, "epoch")), jint(jget(d, "protocol_version"));
        if ep < 0 || !in_u16(pv) { dave_invalid(c); return; }
        DAVE.on_prepare_epoch(*c.dave, cast(u64) ep, pv);
      case OP_SESSION_UPDATE;
        vcn := jstr(jget(d, "video_codec"));
        if vcn c.video_codec = video_codec_from_name(vcn);
      // OP_MEDIA_SINK_WANTS, OP_VOICE_BACKEND_VERSION, OP_FLAGS, OP_PLATFORM, OP_SFU_UPDATE: informational
    }
}

dave_invalid :: (c: *Conn) {
    close_ws(c, CLOSE_DAVE_INVALID_MESSAGE);
    finish(c, CLOSE_DAVE_INVALID_MESSAGE);
}

handle_binary :: (c: *Conn, b: []u8) {
    // server binary frames: [seq u16][op u8][payload] (v8+)
    if b.count < 3 {
        dave_invalid(c);
        return;
    }
    seq := get_u16(b);
    if seq c.last_seq = seq;
    op := b[2];
    p := array_view(b, 3, b.count - 3);
    dbg(c, "<~ binary op % (% bytes)", op, p.count);
    if op == {
      case DAVE.OP_MLS_EXTERNAL_SENDER; DAVE.on_external_sender(*c.dave, p);
      case DAVE.OP_MLS_PROPOSALS;       DAVE.on_proposals(*c.dave, p);
      case DAVE.OP_MLS_ANNOUNCE_COMMIT; #through;
      case DAVE.OP_MLS_WELCOME;
        if p.count < 2 {
            dave_invalid(c);
            return;
        }
        tid := cast(int) get_u16(p);
        rest := array_view(p, 2, p.count - 2);
        if op == DAVE.OP_MLS_ANNOUNCE_COMMIT DAVE.on_announce_commit(*c.dave, tid, rest);
        else DAVE.on_welcome(*c.dave, tid, rest);
    }
}

send_heartbeat :: (c: *Conn) {
    if c.server_version >= 8 send_text(c, msg_heartbeat(now_ms(), c.last_seq));
    else send_text(c, tprint("{\"op\":3,\"d\":%}", now_ms()));
}

on_ready :: (c: *Conn, d: etf.Value) {
    note(c, *c.tl.ready);
    c.ssrc = cast,no_check(u32) jint(jget(d, "ssrc"), 0);
    for jarr(jget(d, "streams")) {
        locks.guard(*c.vmu);
        c.video_ssrc = cast,no_check(u32) jint(jget(it, "ssrc"), 0);
        c.rtx_ssrc = cast,no_check(u32) jint(jget(it, "rtx_ssrc"), 0);
        break;
    }
    ip := jstr(jget(d, "ip"));
    port := jint(jget(d, "port"), 0);
    modes: [..]string;
    modes.allocator = temp;
    for jarr(jget(d, "modes")) array_add(*modes, jstr(it));
    for c.experiments free(it);
    c.experiments.count = 0;
    for e: jarr(jget(d, "experiments")) for SUPPORTED_EXPERIMENTS if jstr(e) == it array_add(*c.experiments, copy_string(it));
    c.session_ok = true;
    if c.server_version >= 6 send_text(c, MSG_VOICE_BACKEND_VERSION);
    c.mode = choose_mode(modes);
    set_state(c, .Discovering);
    if c.mode == .None || !ip || port == 0 return;
    if !udp_setup(c, ip, port) return;
    {
        locks.guard(*c.mu);
        c.tl.udp_port = port;
    }
    note(c, *c.tl.select_sent);
    send_text(c, msg_select_protocol(c.external_ip, c.external_port, c.mode, c.rtc_connection_id, c.experiments));
}

udp_setup :: (c: *Conn, ip: string, port: int) -> bool {
    ok: bool;
    c.server_ep, ok = udp_resolve(ip, port);
    if !ok return false;
    if !c.udp_open {
        c.udp = socket(xx (cast(*sockaddr) c.server_ep.bytes.data).sa_family, .DGRAM, .UDP);
        if c.udp == INVALID_SOCKET return false;
        c.udp_open = true;
        #if OS == .WINDOWS {
            tv: u32 = 100; // milliseconds
        } else {
            tv: timeval;
            tv.tv_usec = 100_000;
        }
        setsockopt(c.udp, SOL_SOCKET, SO_RCVTIMEO, xx *tv, xx size_of(type_of(tv)));
    }
    req: [DISCOVERY_LEN]u8;
    build_discovery_request(req, c.ssrc);
    buf: [1500]u8;
    for attempt: 0..19 {
        if stopped(c) break;
        if attempt % 5 == 0 udp_send(c, req);
        n := recvfrom(c.udp, buf.data, xx buf.count, 0, null, null);
        if n < DISCOVERY_LEN continue;
        _, address, p, found := parse_discovery(array_view(buf, 0, n), 2);
        if !found continue;
        free(c.external_ip);
        c.external_ip = copy_string(address);
        c.external_port = p;
        if !c.udp_started {
            c.udp_started = true;
            c.udp_th = start_thread(c, udp_thread_proc);
        }
        return true;
    }
    return false;
}

on_session_description :: (c: *Conn, d: etf.Value) {
    key: [32]u8;
    ka := jarr(jget(d, "secret_key"));
    if ka.count != 32 return;
    for ka key[it_index] = cast,no_check(u8) jint(it, 0);
    mode := mode_from_name(jstr(jget(d, "mode")));
    if mode == .None return;
    {
        locks.guard(*c.mu);
        c.mode = mode;
        transport_init(*c.tx_crypto, mode, key);
        transport_init(*c.rx_crypto, mode, key);
        c.have_key = true;
        if !c.tl.connected {
            c.tl.connected = now_ms();
            c.tl.media_session_id = copy_string(jstr(jget(d, "media_session_id")));
        }
    }
    crypto.zero(*key);
    dv := jint(jget(d, "dave_protocol_version"));
    if !in_u16(dv) {
        dave_invalid(c);
        return;
    }
    DAVE.on_select_protocol_ack(*c.dave, dv);
    c.video_codec = video_codec_from_name(jstr(jget(d, "video_codec")));
    c.resumable = true;
    set_state(c, .Connected);
    send_text(c, MSG_MEDIA_SINK_WANTS_ANY);
    {
        locks.guard(*c.vmu);
        if c.video_on {  // resumed / reconnected while sending
            send_text(c, msg_video(c.ssrc, c.video_ssrc, c.rtx_ssrc, true, c.video_w, c.video_h, c.video_fps, c.video_bitrate));
            atomic_store(*c.keyframe_wanted, true);
        }
    }
    if !c.audio_started {
        c.audio_started = true;
        if !c.opts.no_audio_devices && !c.info.stream {
            c.capture_on = audio.capture_start(true);
        }
        c.next_rtcp_ms = now_ms() + 1000;
        c.audio_th = start_thread(c, audio_thread_proc);
    }
}

map_user :: (c: *Conn, uid: u64, ssrc: u32) -> *Remote_User {
    locks.guard(*c.mu);
    has_old, old := table_find(*c.user_ssrc, uid);
    if has_old && old != ssrc {
        found, u := table_remove(*c.users, old);
        if found {
            u.ssrc = ssrc;
            table_set(*c.users, ssrc, u);
            table_set(*c.user_ssrc, uid, ssrc);
            return u;
        }
    }
    table_set(*c.user_ssrc, uid, ssrc);
    found, u := table_find(*c.users, ssrc);
    if found {
        u.user_id = uid;
        return u;
    }
    u = New(Remote_User);
    u.user_id = uid;
    u.ssrc = ssrc;
    u.decoder = c.codec.decoder_create();
    table_set(*c.users, ssrc, u);
    return u;
}

destroy_user :: (c: *Conn, u: *Remote_User) {
    c.codec.decoder_destroy(u.decoder);
    if u.source audio.source_destroy(u.source);
    free(u);
}

// ---------------------------------------------------------------------------
// Timer thread: heartbeats and the 20 s HELLO timeout.

timer_thread_proc :: (t: *Thread) -> s64 {
    c := cast(*Conn) t.data;
    last := now_ms();
    while !stopped(c) {
        sleep_milliseconds(25);
        now := now_ms();
        // A gap over WAKE_GAP_MS is the machine waking from sleep: RTCConnection's powerMonitor
        // "resume" sends expeditedHeartbeat(5000): a heartbeat now, no ACK in 5 s = timeout.
        woke := now - last > WAKE_GAP_MS;
        last = now;
        hello_timeout, beat, timeout: bool;
        {
            locks.guard(*c.hb_mu);
            if c.hello_deadline_ms != 0 && now > c.hello_deadline_ms {
                c.hello_deadline_ms = 0;
                hello_timeout = true;
            }
            if woke && c.hb_interval_ms > 0 {
                c.hb_acked = false;
                c.expedite_ms = now + 5000;
                beat = true;
            } else if c.expedite_ms != 0 && now >= c.expedite_ms {
                c.expedite_ms = 0;
                if !c.hb_acked {
                    c.hb_interval_ms = 0;
                    timeout = true;
                }
            } else if c.hb_interval_ms > 0 && now >= c.next_hb_ms {
                c.next_hb_ms = now + c.hb_interval_ms;
                if c.hb_acked {
                    c.hb_acked = false;
                    beat = true;
                } else if c.expedite_ms == 0 {
                    c.hb_interval_ms = 0;
                    timeout = true;
                }
            }
        }
        // HELLO timeout / HEARTBEAT ACK TIMEOUT: close(4000) and resume
        if hello_timeout || timeout close_ws(c, CLOSE_FORCE);
        if beat send_heartbeat(c);
        msg, codecs: string;
        {
            locks.guard(*c.vmu);
            if c.video_announce && c.video_ssrc && c.ws_open {
                c.video_announce = false;
                msg = msg_video(c.ssrc, c.video_ssrc, c.rtx_ssrc, c.video_on, c.video_w, c.video_h, c.video_fps, c.video_bitrate);
            }
            if c.codecs_due && c.ws_open {
                c.codecs_due = false;
                codecs = msg_codecs(c.cant_encode);
            }
        }
        if msg send_text(c, msg);
        if codecs send_text(c, codecs);
        reset_temporary_storage();
    }
    return 0;
}

// ---------------------------------------------------------------------------
// UDP: the server endpoint (a sockaddr_in or sockaddr_in6) and the socket's receive thread.

Udp_Addr :: struct {
    bytes: [128]u8 #align 8;
    len: u32;
}

// udp_resolve returns host's first IPv4 address, else its first IPv6 one, with port.
udp_resolve :: (host: string, port: int) -> Udp_Addr, bool {
    #if OS == .WINDOWS socket_init(); // WSAStartup: reference counted
    hints: addrinfo;
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = .DGRAM;
    res: *addrinfo;
    a: Udp_Addr;
    if getaddrinfo(temp_c_string(host), temp_c_string(tprint("%", port)), *hints, *res) != 0 return a, false;
    defer freeaddrinfo(res);
    ai: *addrinfo;
    p := res;
    while p {
        if p.ai_family == AF_INET { ai = p; break; }
        if p.ai_family == AF_INET6 && !ai ai = p;
        p = p.ai_next;
    }
    if !ai || ai.ai_addrlen > a.bytes.count return a, false;
    memcpy(a.bytes.data, ai.ai_addr, xx ai.ai_addrlen);
    a.len = xx ai.ai_addrlen;
    return a, true;
}

udp_send :: (c: *Conn, b: []u8) {
    if sendto(c.udp, b.data, xx b.count, 0, cast(*sockaddr) c.server_ep.bytes.data, xx c.server_ep.len) < 0 {
        c.udp_errno = xx get_last_socket_error();
        atomic_add(*c.udp_errors, 1);
    }
}

udp_thread_proc :: (t: *Thread) -> s64 {
    c := cast(*Conn) t.data;
    buf, plain, frame: [2048]u8;
    while !stopped(c) {
        n := recvfrom(c.udp, buf.data, xx buf.count, 0, null, null);
        if n <= 0 continue;
        pkt := array_view(buf, 0, n);
        have: bool;
        {
            locks.guard(*c.mu);
            c.stats.udp_datagrams += 1;
            have = c.have_key;
        }
        if !have continue;
        now := now_ms();
        if is_rtcp(pkt) {
            m, ok := transport_open(*c.rx_crypto, pkt, 8, plain);
            if !ok { count_failure(c); continue; }
            {
                locks.guard(*c.mu);
                c.stats.rtcp_received += 1;
            }
            on_rtcp(c, array_view(plain, 0, m), now);
            continue;
        }
        h, hok := parse_rtp_header(pkt);
        if !hok continue;
        m, ok := transport_open(*c.rx_crypto, pkt, h.aad_len, plain);
        if !ok { count_failure(c); continue; }
        end := m;
        if plain[0] & 0x20 && h.payload_off < m {  // padding
            pad := cast(int) plain[m - 1];
            if pad == 0 || pad > m - h.payload_off continue;
            end -= pad;
        }
        if h.payload_off > end continue;
        payload := array_view(plain, h.payload_off, end - h.payload_off);
        vcodec := video_codec_from_pt(h.pt);
        if vcodec != .None {
            on_video_packet(c, h, vcodec, payload, n, now);
            continue;
        }
        if h.pt != OPUS_PT {
            locks.guard(*c.mu);
            c.stats.other_pt += 1;
            continue;
        }
        uid: u64;
        {
            locks.guard(*c.mu);
            known, u := table_find(*c.users, h.ssrc);
            if known uid = u.user_id;
            c.stats.packets_received += 1;
            c.stats.bytes_received += xx n;
            if !uid c.stats.unknown_ssrc += 1;
        }
        if !uid continue;  // no op 5 yet: can't attribute (DAVE needs the sender)
        fl, res := DAVE.session_decrypt(*c.dave, uid, payload, frame);
        if res == .Failed continue;
        opus := array_view(frame, 0, fl);
        silent := fl == 3 && opus[0] == 0xF8 && opus[1] == 0xFF && opus[2] == 0xFE;
        level, voice, lok := ext_audio_level(array_view(plain, 0, m), h);
        if lok && !voice && level >= 127 silent = true;
        locks.guard(*c.mu);
        still, u := table_find(*c.users, h.ssrc);
        if still {
            jb_push(*u.jb, h.seq, h.ts, opus, cast(float64) now);
            rx_update(*u.rx, h.seq, h.ts, now);
            if !silent u.last_voice_ms = now;
        }
    }
    return 0;
}

count_failure :: (c: *Conn) {
    locks.guard(*c.mu);
    c.stats.transport_failures += 1;
}

// rx_update: RFC 3550 A.1 / A.8 receiver statistics.
rx_update :: (r: *Rx_Stats, seq: u16, ts: u32, now: s64) {
    if !r.init {
        r.init = true;
        r.base_seq = seq;
        r.max_seq = seq;
    } else if cast(u16) (seq - r.max_seq) < 0x8000 {
        if seq < r.max_seq r.cycles += 1 << 16;
        r.max_seq = seq;
    }
    r.received += 1;
    transit := now * 48 - cast(s64) ts;  // arrival in 48 kHz units
    if r.received > 1 r.jitter += (cast(float64) abs(transit - r.transit) - r.jitter) / 16;
    r.transit = transit;
}

on_rtcp :: (c: *Conn, b: []u8, now: s64) {
    {
        locks.guard(*c.vmu);
        if c.video_on && keyframe_requested(b, c.video_ssrc) atomic_store(*c.keyframe_wanted, true);
    }
    rep, ok := parse_report(b);
    if !ok {
        dbg(c, "rtcp pt=% len=% (unparsed)", b[1], b.count);
        return;
    }
    dbg(c, "rtcp % ssrc=% blocks=%", ifx rep.is_sr then "SR" else "RR", rep.ssrc, rep.n_blocks);
    blocks := array_view(rep.blocks, 0, rep.n_blocks);
    for blocks dbg(c, "  block ssrc=% lost=% frac=% maxseq=% jitter=%", it.ssrc, it.cum_lost, it.fraction_lost, it.ext_max_seq, it.jitter);
    locks.guard(*c.mu);
    if rep.is_sr {
        found, u := table_find(*c.users, rep.ssrc);
        if found {
            u.rx.lsr = cast,no_check(u32) (rep.ntp >> 16);
            u.rx.lsr_at_ms = now;
        }
    }
    for blocks {
        if it.ssrc != c.ssrc || it.lsr == 0 continue;
        rtt := cast,no_check(u32) (ntp_now() >> 16) - it.lsr - it.dlsr;  // 1/65536 s
        c.stats.rtt_ms = xx (cast(u64) rtt * 1000 / 65536);
    }
}

ntp_now :: () -> u64 {
    ns := cast(u64) to_nanoseconds(current_time_consensus() - APOLLO_TIME_FOR_JAN_1_1970);
    secs := ns / 1_000_000_000 + 2_208_988_800;
    frac := (ns % 1_000_000_000) * (1 << 32) / 1_000_000_000;
    return (secs << 32) | frac;
}

// ---------------------------------------------------------------------------
// Audio thread: 20 ms ticks. Send: mic -> VAD -> Opus -> DAVE -> RTP -> AEAD.
// Receive: jitter buffer -> Opus (FEC/PLC) -> volume -> output.

audio_thread_proc :: (t: *Thread) -> s64 {
    c := cast(*Conn) t.data;
    // high priority, as the Odin client's thread.create(priority = .High)
    #if OS == .WINDOWS {
        SetThreadPriority(GetCurrentThread(), 2); // THREAD_PRIORITY_HIGHEST
    } else {
        policy: s32;
        param: sched_param;
        if pthread_getschedparam(pthread_self(), *policy, *param) == 0 {
            param.sched_priority = sched_get_priority_max(policy);
            pthread_setschedparam(pthread_self(), policy, *param);
        }
    }
    pcm: [SAMPLES_PER_FRAME]float32;
    out: [SAMPLES_PER_FRAME * 2]float32;
    next := current_time_monotonic();
    while !stopped(c) {
        next += milliseconds_to_apollo(20);
        if c.capture_on audio.update();  // the mic's sample rate changed under us
        for 1..mic_frames_due(c) tx_tick(c, pcm);
        rx_tick(c, out);
        if now_ms() >= c.next_rtcp_ms send_rtcp(c);
        if c.debug diag_trace(c);
        reset_temporary_storage();
        left := to_nanoseconds(next - current_time_monotonic());
        if left > 0 accurate_sleep_until(next);
        else if left < -200_000_000 next = current_time_monotonic();  // fell far behind: resync
    }
    return 0;
}

// accurate_sleep_until sleeps 1 ms at a time while more than the observed
// oversleep (mean + stddev) remains, then spins (Odin's time.accurate_sleep).
accurate_sleep_until :: (deadline: Apollo_Time) {
    estimate: float64 = 5_000_000;
    mean := estimate;
    m2: float64;
    count := 1;
    while cast(float64) to_nanoseconds(deadline - current_time_monotonic()) > estimate {
        start := current_time_monotonic();
        sleep_milliseconds(1);
        observed := cast(float64) to_nanoseconds(current_time_monotonic() - start);
        count += 1;
        delta := observed - mean;
        mean += delta / count;
        m2 += delta * (observed - mean);
        estimate = mean + sqrt(m2 / (count - 1));
    }
    while to_nanoseconds(deadline - current_time_monotonic()) > 0 {}
}

// diag_trace: the send side every 2 s (FASTCORD_VOICE_DEBUG=1), to tell a mic that stops
// delivering from frames the VAD gates, DAVE drops or the socket refuses.
diag_trace :: (c: *Conn) {
    now := now_ms();
    if !c.diag.at_ms { c.diag = .{at_ms = now, min_avail = S64_MAX}; return; }
    if now - c.diag.at_ms < 2000 return;
    d := c.diag;
    st := DAVE.session_status(*c.dave,, temp);
    dbg(c, "send: mic frames=% padded=% avail=%..% voiced=% db=% | dave v% active=% epoch=% enc_drops=% | udp_errors=% errno=% rtt=%",
        d.frames, d.padded, d.min_avail, d.max_avail, d.voiced, cast(int) c.input_db, st.protocol_version, st.e2ee_active,
        st.epoch, d.enc_drops, atomic_load(*c.udp_errors), c.udp_errno, c.stats.rtt_ms);
    c.diag = .{at_ms = now, min_avail = S64_MAX};
}

// mic_frames_due: frames to send this 20 ms tick. The mic runs on the device's clock, so only
// whole frames go out (a short read padded with zeros cuts out mid-word); a tick without one
// waits, which leaves a frame of cushion, and a backlog drains at two frames a tick.
mic_frames_due :: (c: *Conn) -> int {
    if c.opts.no_audio_devices || !c.capture_on return 1;
    a := audio.capture_available();
    c.diag.min_avail = min(c.diag.min_avail, a);
    c.diag.max_avail = max(c.diag.max_avail, a);
    if a < SAMPLES_PER_FRAME {
        c.mic_waits += 1;
        return xx (c.mic_waits > 5);  // device stopped: send padded frames, so speaking still ends
    }
    c.mic_waits = 0;
    return ifx a >= 3 * SAMPLES_PER_FRAME then 2 else 1;
}

read_mic :: (c: *Conn, pcm: []float32) {
    n := 0;
    if c.opts.no_audio_devices {
        if c.opts.capture n = c.opts.capture(c.opts.callback_data, pcm);
    } else if c.capture_on {
        // after a stall, drop the backlog beyond 3 frames to keep latency bounded
        if audio.capture_available() > 10 * SAMPLES_PER_FRAME
            while audio.capture_available() > 3 * SAMPLES_PER_FRAME audio.capture_read(pcm);
        n = audio.capture_read(pcm);
        if n < pcm.count c.diag.padded += 1;
    }
    c.diag.frames += 1;
    for n..pcm.count-1 pcm[it] = 0;
}

tx_tick :: (c: *Conn, pcm: []float32) {
    if c.info.stream return;  // Go Live: video only (no soundshare yet)
    read_mic(c, pcm);
    locks.lock(*c.mu);
    muted := c.self_mute || c.self_deaf;
    gain := c.input_gain;
    echo, denoise, agc := c.echo_on && c.capture_on, c.denoise_on, c.agc_on && c.capture_on;
    locks.unlock(*c.mu);
    // in 10 ms frames, in the order of WebRTC's pipeline: echo, then noise, then gain
    for 0..1 {
        half := pcm.data + it * SAMPLES_PER_FRAME / 2;
        if echo {
            if !c.aec c.aec = fc_aec_create();
            played: [SAMPLES_PER_FRAME / 2]float32;
            audio.render_read(played);
            fc_aec_render(c.aec, played.data);
            fc_aec_capture(c.aec, half);
        }
        if denoise {
            if !c.denoiser c.denoiser = fc_rnnoise_create();
            fc_rnnoise_process(c.denoiser, half);  // delays its output by one frame
        }
    }
    if agc agc_process(*c.agc, pcm);
    if gain != 1 {
        for * pcm it.* *= gain;
        audio.limit(*c.input_limiter, pcm, 1);
    }
    active, db := vad_process(*c.vad, pcm);
    {
        locks.guard(*c.mu);
        c.input_db = db;
        c.vad_open = active;
        if c.ptt_mode active = c.ptt_pressed || now_ms() < c.ptt_until_ms;
    }
    if muted active = false;
    c.diag.voiced += xx active;
    frame_ts := c.ts;
    c.ts += SAMPLES_PER_FRAME;
    if active {
        if !c.self_speaking {
            send_text(c, msg_speaking(SPEAKING_VOICE, c.ssrc));
            {
                locks.guard(*c.mu);
                c.self_speaking = true;
            }
            // leading frames (pre-roll), with their original timestamps
            for i: 0..c.preroll_n-1 {
                pts := frame_ts - cast(u32) ((c.preroll_n - i) * SAMPLES_PER_FRAME);
                send_audio(c, c.preroll[i], pts, frame_level_db(c.preroll[i]), true);
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
            send_opus(c, OPUS_SILENCE_FRAME, frame_ts, 127, false);
            if c.silence_left == 0 {
                send_text(c, msg_speaking(0, c.ssrc));
                locks.guard(*c.mu);
                c.self_speaking = false;
            }
        }
        return;
    }
    if muted {
        c.preroll_n = 0;
        return;
    }
    // shift pre-roll
    if c.preroll_n == c.preroll.count {
        for 1..c.preroll.count-1 c.preroll[it - 1] = c.preroll[it];
        c.preroll_n -= 1;
    }
    memcpy(c.preroll[c.preroll_n].data, pcm.data, pcm.count * size_of(float32));
    c.preroll_n += 1;
}

send_audio :: (c: *Conn, pcm: []float32, ts: u32, db: float32, voice: bool) {
    opus: [MAX_OPUS_PACKET]u8;
    n := c.codec.encode(c.encoder, pcm, opus);
    if n > 0 send_opus(c, array_view(opus, 0, n), ts, audio_level_byte(db), voice);
}

send_opus :: (c: *Conn, opus: []u8, ts: u32, level: u8, voice: bool) {
    if !c.udp_open return;
    frame: [MAX_OPUS_PACKET + DAVE.MAX_SUPPLEMENTAL]u8;
    fl := DAVE.session_encrypt(*c.dave, opus, frame);
    if fl <= 0 {
        c.diag.enc_drops += 1;
        return;
    }
    pkt: [MAX_OPUS_PACKET + 128]u8;
    sealed: [MAX_OPUS_PACKET + 160]u8;
    plen, aad := build_audio_rtp(pkt, c.seq, ts, c.ssrc, level, voice, array_view(frame, 0, fl));
    sl: int;
    {
        locks.guard(*c.mu);
        if !c.have_key return;
        sl = transport_seal(*c.tx_crypto, array_view(pkt, 0, plen), aad, c.tx_nonce, sealed);
        c.tx_nonce += 1;
        c.stats.packets_sent += 1;
        c.stats.bytes_sent += xx sl;
    }
    c.seq += 1;
    c.packets_sent += 1;
    c.octets_sent += xx fl;
    c.last_sent_ts = ts;
    udp_send(c, array_view(sealed, 0, sl));
}

rx_tick :: (c: *Conn, out: []float32) {
    locks.guard(*c.mu);
    for u: c.users {
        kind, data := jb_pop(*u.jb);
        if kind == .None continue;
        n := c.codec.decode(u.decoder, data, kind == .Fec, out);  // .Plc: data is empty
        if n <= 0 || c.self_deaf continue;
        found, st := table_find(*c.settings, u.user_id);
        if !found st = .{};
        if st.muted continue;
        frames := array_view(out, 0, n * 2);
        if st.volume != 1 for * frames it.* *= st.volume;
        if c.opts.no_audio_devices {
            if c.opts.playback c.opts.playback(c.opts.callback_data, u.user_id, frames);
        } else {
            if !u.source u.source = audio.source_create();
            if u.source audio.source_write(u.source, frames);
        }
    }
}

// send_rtcp: SR (when we have sent since the last report) or RR, with one
// report block per remote stream; ~5 s randomized interval (RFC 3550 6.3.1).
send_rtcp :: (c: *Conn) {
    now := now_ms();
    rnd: [4]u8;
    crypto.random_bytes(rnd);
    c.next_rtcp_ms = now + 2500 + get_u32(rnd) % 5000;
    if !c.udp_open return;
    blocks: [..]Report_Block;
    blocks.allocator = temp;
    have: bool;
    {
        locks.guard(*c.mu);
        for u: c.users {
            r := *u.rx;
            if !r.init continue;
            ext_max := r.cycles + r.max_seq;
            expected := ext_max - r.base_seq + 1;
            lost := cast,no_check(s32) expected - cast,no_check(s32) r.received;
            exp_int := expected - r.expected_prior;
            rec_int := r.received - r.received_prior;
            r.expected_prior = expected;
            r.received_prior = r.received;
            lost_int := cast,no_check(s32) exp_int - cast,no_check(s32) rec_int;
            frac: u8;
            if exp_int != 0 && lost_int > 0 frac = cast,no_check(u8) (((cast(u32) lost_int) << 8) / exp_int);
            dlsr: u32;
            if r.lsr != 0 dlsr = cast,no_check(u32) ((now - r.lsr_at_ms) * 65536 / 1000);
            array_add(*blocks, .{u.ssrc, frac, lost, ext_max, cast,no_check(u32) r.jitter, r.lsr, dlsr});
        }
        have = c.have_key;
    }
    if !have return;
    pkt: [512]u8;
    n := build_report(pkt, c.ssrc, c.packets_sent > 0, ntp_now(), c.last_sent_ts, c.packets_sent, c.octets_sent, blocks);
    send_rtcp_packet(c, array_view(pkt, 0, n));
    locks.lock(*c.vmu);
    vssrc, sending, vts, vp, vo := c.video_ssrc, c.video_on && c.video_packets > 0, c.video_last_ts, c.video_packets, c.video_octets;
    locks.unlock(*c.vmu);
    if sending send_rtcp_packet(c, array_view(pkt, 0, build_report(pkt, vssrc, true, ntp_now(), vts, vp, vo, .[])));
}

send_rtcp_packet :: (c: *Conn, pkt: []u8) {
    sealed: [600]u8;
    sl: int;
    {
        locks.guard(*c.mu);
        if !c.have_key return;
        sl = transport_seal(*c.tx_crypto, pkt, 8, c.tx_nonce, sealed);
        c.tx_nonce += 1;
    }
    udp_send(c, array_view(sealed, 0, sl));
}

// ---------------------------------------------------------------------------
// Video

// set_video starts or stops sending our video stream (camera, or the screen on
// a Go Live connection): op 12 with the stream's SSRCs and limits, sent by the
// timer thread (callers may be the UI). Frames then go through send_video.
// Bitrate in bits per second.
set_video :: (c: *Conn, on: bool, width := 1280, height := 720, fps := 30, bitrate := 2_500_000) {
    locks.guard(*c.vmu);
    c.video_on = on;
    c.video_w, c.video_h, c.video_fps, c.video_bitrate = width, height, fps, bitrate;
    c.video_announce = true;
}

// cannot_encode: the call's video codec has no encoder here. Once per codec, op 14 asks the server for another
// (timer thread), as the official client does after its encoder fails; the answer changes video_codec.
cannot_encode :: (c: *Conn, codec: Video_Codec) {
    locks.guard(*c.vmu);
    bit := cast(u8) (1 << cast(int) codec);
    if c.cant_encode & bit return;
    c.cant_encode |= bit;
    c.codecs_due = true;
}

// video_codec: what SESSION_DESCRIPTION negotiated for this call (.None before it).
video_codec :: (c: *Conn) -> Video_Codec { return c.video_codec; }

// take_keyframe_request: true once after the SFU asked for a keyframe (PLI / FIR), or after a reconnect.
take_keyframe_request :: (c: *Conn) -> bool { return atomic_swap(*c.keyframe_wanted, false); }

// send_video sends one encoded frame (Annex B, as the encoder wrote it) in
// the negotiated codec: DAVE with libdave's clear ranges, then RTP at 90 kHz.
// Safe from any one thread at a time (the encoder's).
send_video :: (c: *Conn, codec: Video_Codec, au: []u8, ts_90k: u32) {
    if codec != .H264 && codec != .H265 return;
    locks.guard(*c.vmu);
    if !c.video_on || !c.video_ssrc || !c.udp_open return;
    frame, nals := with_long_start_codes(au);
    if !nals.count return;
    enc := NewArray(frame.count + 256, u8, false,, temp);
    fl := DAVE.session_encrypt(*c.dave, frame, enc, dave_clear_ranges(codec, frame, nals));
    if fl <= 0 return;
    Pk :: struct { c: *Conn; codec: Video_Codec; ts: u32; }
    pk := Pk.{c, codec, ts_90k};
    packetize(codec, array_view(enc, 0, fl), nals, (payload: []u8, last: bool, data: *void) {
        using pk := cast(*Pk) data;
        pkt: [MAX_VIDEO_PAYLOAD + 64]u8;
        sealed: [MAX_VIDEO_PAYLOAD + 96]u8;
        pkt[0] = 0x90;  // V=2, X=1
        pkt[1] = VIDEO_PT[codec] | (ifx last then cast(u8) 0x80 else 0);
        put_u16(pkt, c.video_seq, 2);
        put_u32(pkt, ts, 4);
        put_u32(pkt, c.video_ssrc, 8);
        // one-byte extension block: id 5 (playout-delay) with 2 zero bytes. Checked live: the SFU
        // forwards this; with the RFC's 3-byte form (L=2) it dropped every video packet.
        pkt[12], pkt[13] = 0xBE, 0xDE;
        put_u16(pkt, 1, 14);
        pkt[16], pkt[17], pkt[18], pkt[19] = (EXT_ID_PLAYOUT_DELAY << 4) | 1, 0, 0, 0;
        memcpy(pkt.data + 20, payload.data, payload.count);
        n := 20 + payload.count;
        sl: int;
        {
            locks.guard(*c.mu);
            if !c.have_key return;
            sl = transport_seal(*c.tx_crypto, array_view(pkt, 0, n), 16, c.tx_nonce, sealed);
            c.tx_nonce += 1;
            c.stats.packets_sent += 1;
            c.stats.bytes_sent += xx sl;
        }
        c.video_seq += 1;
        c.video_packets += 1;
        c.video_octets += xx payload.count;
        udp_send(c, array_view(sealed, 0, sl));
    }, *pk);
    c.video_last_ts = ts_90k;
    locks.guard(*c.mu);
    c.stats.video_frames_sent += 1;
}

// video_user_ids: users whose op 12 announced an active video stream, in context.allocator.
video_user_ids :: (c: *Conn) -> []u64 {
    locks.guard(*c.mu);
    out: [..]u64;
    for v, uid: c.video_users if v array_add(*out, uid);
    return out;
}

// request_keyframe asks for a keyframe of user's video (e.g. after their decoder
// failed): frames wait for one, and the UDP thread sends the PLI.
request_keyframe :: (c: *Conn, user_id: u64) {
    locks.guard(*c.mu);
    for c.video_rx if it.user_id == user_id { it.need_key = true; it.last_pli_ms = 0; }
}

#scope_file

EXT_ID_PLAYOUT_DELAY :: 5;
PLI_INTERVAL_MS :: 500;

MSG_MEDIA_SINK_WANTS_ANY :: "{\"op\":15,\"d\":{\"any\":100}}";

// on_remote_video: op 12 from the server maps a user's video SSRCs (0 / inactive = stopped).
on_remote_video :: (c: *Conn, uid: u64, d: etf.Value) {
    locks.guard(*c.mu);
    drop_video_rx(c, uid);
    active := false;
    add :: (ssrc: s64) #expand {
        if ssrc <= 0 return;
        rx := New(Video_Rx);
        rx.ssrc = cast,no_check(u32) ssrc;
        rx.user_id = uid;
        table_set(*c.video_rx, rx.ssrc, rx);
        active = true;
    }
    streams := jarr(jget(d, "streams"));
    for streams if jint(jget(it, "active"), 1) != 0 add(jint(jget(it, "ssrc"), 0));
    if !streams.count add(jint(jget(d, "video_ssrc"), 0));
    table_set(*c.video_users, uid, active);
}

drop_video_rx :: (c: *Conn, uid: u64) {
    gone: [..]u32;
    gone.allocator = temp;
    for c.video_rx if it.user_id == uid { array_add(*gone, it.ssrc); array_free(it.au); free(it); }
    for gone table_remove(*c.video_rx, it);
}

on_video_packet :: (c: *Conn, h: Rtp_Header, codec: Video_Codec, payload: []u8, n: s64, now: s64) {
    au: []u8;
    done, pli: bool;
    uid: u64;
    {
        locks.guard(*c.mu);
        c.stats.bytes_received += xx n;
        rx := table_find_pointer(*c.video_rx, h.ssrc);
        if !rx return;  // RTX, or a stream op 12 hasn't announced
        r := rx.*;
        uid = r.user_id;
        frame, ok := rx_video_packet(r, codec, h.seq, h.ts, h.marker, payload);
        if r.need_key && now - r.last_pli_ms >= PLI_INTERVAL_MS {
            r.last_pli_ms = now;
            pli = true;
        }
        if ok {
            // copied out: decryption and the callback run unlocked
            au = array_copy(frame,, temp);
            done = true;
        }
    }
    if pli send_pli(c, h.ssrc);
    if !done return;
    plain := NewArray(au.count, u8, false,, temp);
    fl, res := DAVE.session_decrypt(*c.dave, uid, au, plain);
    if res == .Failed return;
    frame := array_view(plain, 0, fl);
    key := is_keyframe(codec, frame);
    {
        locks.guard(*c.mu);
        rx := table_find_pointer(*c.video_rx, h.ssrc);
        if !rx return;
        if rx.*.need_key && !key return;
        rx.*.need_key = false;
        rx.*.frames += 1;
        c.stats.video_frames_received += 1;
    }
    if c.opts.video c.opts.video(c.opts.callback_data, uid, codec, frame, key);
    reset_temporary_storage();
}

send_pli :: (c: *Conn, media_ssrc: u32) {
    pkt: [12]u8;
    send_rtcp_packet(c, array_view(pkt, 0, build_pli(pkt, c.ssrc, media_ssrc)));
    locks.guard(*c.mu);
    c.stats.plis_sent += 1;
}

vendor :: #library,no_dll "../../build/fc_vendor";
fc_aec_create :: () -> *void #foreign vendor;
fc_aec_destroy :: (a: *void) #foreign vendor;
fc_aec_render :: (a: *void, pcm: *float32) #foreign vendor;
fc_aec_capture :: (a: *void, pcm: *float32) #foreign vendor;
fc_rnnoise_create :: () -> *void #foreign vendor;
fc_rnnoise_destroy :: (st: *void) #foreign vendor;
fc_rnnoise_process :: (st: *void, pcm: *float32) -> float32 #foreign vendor;
