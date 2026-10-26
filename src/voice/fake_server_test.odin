package voice

import "fc:locks"
import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:net"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import "fc:http"
import "fc:netio"
import "fc:voice/dave"
import "fc:voice/mls"

// A local fake voice server: WebSocket gateway on 127.0.0.1 (plain TCP via
// Options.dial), UDP media on loopback, and a second DAVE member "B" that the
// server welcomes into our client's group. Verifies the handshake order,
// IP discovery, SELECT_PROTOCOL, heartbeats with seq_ack, the DAVE MLS flow,
// E2EE media both ways and the close code.

FAKE_USER_A :: u64(1546819257420087346)
FAKE_USER_B :: u64(1090123456789012345)
FAKE_CHANNEL :: u64(1564227670806364345)
FAKE_GUILD :: u64(1564227669971832975)
FAKE_SSRC_A :: u32(8597)
FAKE_SSRC_B :: u32(9001)

@(private = "file")
Fake :: struct {
	listen:       net.TCP_Socket,
	tcp_port:     int,
	udp:          net.UDP_Socket,
	udp_port:     int,
	key:          [32]byte,
	ext_priv:     [mls.NSK]byte,
	ext_raw:      []byte,
	b_id:         mls.Identity,
	b_kp:         mls.Key_Package,
	b_secrets:    mls.Key_Package_Secrets,
	b_group:      ^mls.Group,
	b_ratchet:    dave.Ratchet,
	a_ratchet:    dave.Ratchet,
	client_ep:    net.Endpoint,
	have_client:  bool,
	mu:           locks.Mutex,
	stop:         bool,
	// results
	request_line: string,
	header_names: string,
	identify:     string,
	select_proto: string,
	got_op16:     bool,
	key_package:  bool,
	commit_ok:    bool,
	ready_tid:    int,
	heartbeats:   int,
	last_seq_ack: i64,
	speaking_on:  bool,
	rtp_e2ee_ok:  int,
	rtp_bad:      int,
	rtcp:         int,
	close_code:   int,
	discovery:    bool,
	failure:      string,
	allocator:    runtime.Allocator,
}

@(private = "file")
Srv :: struct {
	sock: net.TCP_Socket,
	buf:  [dynamic]byte,
}

@(private = "file")
srv_fill :: proc(s: ^Srv, n: int) -> bool {
	tmp: [4096]byte
	for len(s.buf) < n {
		got, err := net.recv_tcp(s.sock, tmp[:])
		if err != nil || got <= 0 do return false
		append(&s.buf, ..tmp[:got])
	}
	return true
}

@(private = "file")
srv_take :: proc(s: ^Srv, n: int) -> []byte {
	out := make([]byte, n, context.temp_allocator)
	copy(out, s.buf[:n])
	remove_range(&s.buf, 0, n)
	return out
}

@(private = "file")
srv_read_frame :: proc(s: ^Srv) -> (op: u8, payload: []byte, ok: bool) {
	if !srv_fill(s, 2) do return
	h := srv_take(s, 2)
	op = h[0] & 0x0f
	l := int(h[1] & 0x7f)
	if l == 126 {
		if !srv_fill(s, 2) do return
		e := srv_take(s, 2)
		l = int(e[0]) << 8 | int(e[1])
	} else if l == 127 {
		if !srv_fill(s, 8) do return
		e := srv_take(s, 8)
		l = 0
		for b in e do l = l << 8 | int(b)
	}
	if !srv_fill(s, 4 + l) do return
	mk := srv_take(s, 4)
	payload = srv_take(s, l)
	for i in 0 ..< l do payload[i] ~= mk[i % 4]
	return op, payload, true
}

@(private = "file")
srv_send :: proc(s: ^Srv, op: u8, payload: []byte) {
	hdr := make([dynamic]byte, 0, 10 + len(payload), context.temp_allocator)
	append(&hdr, 0x80 | op)
	if len(payload) < 126 {
		append(&hdr, u8(len(payload)))
	} else {
		append(&hdr, 126, u8(len(payload) >> 8), u8(len(payload)))
	}
	append(&hdr, ..payload)
	net.send_tcp(s.sock, hdr[:])
}

@(private = "file")
srv_text :: proc(s: ^Srv, text: string) {srv_send(s, 1, transmute([]byte)text)}

@(private = "file")
srv_binary :: proc(s: ^Srv, seq: u16, op: u8, payload: []byte) {
	b := make([]byte, 3 + len(payload), context.temp_allocator)
	b[0] = u8(seq >> 8)
	b[1] = u8(seq)
	b[2] = op
	copy(b[3:], payload)
	srv_send(s, 2, b)
}

// next message that is not a heartbeat (heartbeats are acked here)
@(private = "file")
srv_next :: proc(f: ^Fake, s: ^Srv) -> (text: string, bin: []byte, is_bin: bool, ok: bool) {
	for {
		op, p, rok := srv_read_frame(s)
		if !rok do return
		switch op {
		case 8:
			code := int(p[0]) << 8 | int(p[1]) if len(p) >= 2 else 1005
			locks.lock(&f.mu)
			f.close_code = code
			locks.unlock(&f.mu)
			return
		case 1:
			v, err := json.parse_string(string(p), parse_integers = true, allocator = context.temp_allocator)
			if err == nil && jint(jget(v, "op")) == 3 {
				d := jget(v, "d")
				locks.lock(&f.mu)
				f.heartbeats += 1
				f.last_seq_ack = jint(jget(d, "seq_ack"))
				locks.unlock(&f.mu)
				srv_text(s, fmt.tprintf(`{{"op":6,"d":{{"t":%d}}}}`, jint(jget(d, "t"))))
				continue
			}
			if err == nil && jint(jget(v, "op")) == 5 {
				locks.lock(&f.mu)
				if jint(jget(jget(v, "d"), "speaking")) == 1 do f.speaking_on = true
				locks.unlock(&f.mu)
				continue
			}
			return strings.clone(string(p), context.temp_allocator), nil, false, true
		case 2:
			return "", p, true, true
		}
	}
}

@(private = "file")
fail :: proc(f: ^Fake, msg: string) {
	locks.lock(&f.mu)
	if f.failure == "" do f.failure = msg
	locks.unlock(&f.mu)
}

@(private = "file")
gw_thread :: proc(data: rawptr) {
	f := cast(^Fake)data
	context.allocator = f.allocator
	sock, _, aerr := net.accept_tcp(f.listen)
	if aerr != nil {
		fail(f, "accept")
		return
	}
	s := Srv{sock = sock, buf = make([dynamic]byte)}
	defer delete(s.buf)
	defer net.close(sock)
	// HTTP upgrade
	for !strings.contains(string(s.buf[:]), "\r\n\r\n") {
		if !srv_fill(&s, len(s.buf) + 1) {
			fail(f, "upgrade read")
			return
		}
	}
	head := string(s.buf[:strings.index(string(s.buf[:]), "\r\n\r\n")])
	remove_range(&s.buf, 0, len(head) + 4)
	lines := strings.split(head, "\r\n", context.temp_allocator)
	f.request_line = strings.clone(lines[0])
	names := make([dynamic]string, 0, 16, context.temp_allocator)
	key := ""
	for l in lines[1:] {
		i := strings.index_byte(l, ':')
		if i < 0 do continue
		append(&names, l[:i])
		if l[:i] == "Sec-WebSocket-Key" do key = strings.trim_space(l[i + 1:])
	}
	f.header_names = strings.join(names[:], ",")
	accept := http.ws_accept_for_key(key, context.temp_allocator)
	resp := fmt.tprintf("HTTP/1.1 101 Switching Protocols\r\nConnection: upgrade\r\nsec-websocket-accept: %s\r\nupgrade: websocket\r\n\r\n", accept)
	net.send_tcp(sock, transmute([]byte)resp)

	text, _, _, ok := srv_next(f, &s)
	if !ok {
		fail(f, "no identify")
		return
	}
	f.identify = strings.clone(text)
	srv_text(&s, `{"op":8,"d":{"v":8,"heartbeat_interval":300}}`)
	srv_text(&s, fmt.tprintf(`{{"op":2,"d":{{"streams":[{{"type":"video","ssrc":8598,"rtx_ssrc":8599,"rid":"100","quality":100,"active":false}}],"ssrc":%d,"port":%d,"modes":["aead_aes256_gcm_rtpsize","aead_xchacha20_poly1305_rtpsize"],"ip":"127.0.0.1","experiments":["fixed_keyframe_interval"]}}}}`, FAKE_SSRC_A, f.udp_port))
	for {
		text, _, _, ok = srv_next(f, &s)
		if !ok {
			fail(f, "no select protocol")
			return
		}
		if strings.has_prefix(text, `{"op":16`) {
			f.got_op16 = true
			srv_text(&s, `{"op":16,"d":{"voice":"0.22.2","rtc_worker":"1.7.1"}}`)
			continue
		}
		break
	}
	f.select_proto = strings.clone(text)
	kb := strings.builder_make(context.temp_allocator)
	for b, i in f.key {
		if i > 0 do strings.write_byte(&kb, ',')
		fmt.sbprintf(&kb, "%d", b)
	}
	srv_text(&s, fmt.tprintf(`{{"op":4,"d":{{"video_codec":"H265","secure_frames_version":1,"secret_key":[%s],"mode":"aead_aes256_gcm_rtpsize","media_session_id":"m","dave_protocol_version":1,"audio_codec":"opus"}}}}`, strings.to_string(kb)))
	srv_text(&s, fmt.tprintf(`{{"seq":1,"op":11,"d":{{"user_ids":["%d"]}}}}`, FAKE_USER_B))
	srv_binary(&s, 2, 25, f.ext_raw)

	// key package (op 26), bare KeyPackage
	_, bin, is_bin, ok2 := srv_next(f, &s)
	if !ok2 || !is_bin || len(bin) < 2 || bin[0] != 26 {
		fail(f, "no key package")
		return
	}
	r := mls.reader_make(bin[1:])
	akp := mls.r_key_package(&r, context.temp_allocator)
	if !mls.r_done(&r) || mls.validate_key_package(&akp) != .None {
		fail(f, "bad key package")
		return
	}
	f.key_package = true
	gid: [8]byte
	for i in 0 ..< 8 do gid[i] = u8(FAKE_CHANNEL >> (56 - 8 * uint(i)))
	add, aok := mls.external_proposal(gid[:], 0, 0, mls.Proposal{type = .Add, add = f.b_kp}, f.ext_priv[:], context.temp_allocator)
	if !aok {
		fail(f, "proposal")
		return
	}
	w := mls.writer_make()
	mls.w_u8(&w, 0)
	mls.w_vec(&w, add)
	srv_binary(&s, 3, 27, w.buf[:])

	// commit + welcome (op 28)
	_, bin, is_bin, ok2 = srv_next(f, &s)
	if !ok2 || !is_bin || bin[0] != 28 {
		fail(f, "no commit")
		return
	}
	cr := mls.reader_make(bin[1:])
	commit := mls.r_mls_message_raw(&cr)
	welcome := bin[1 + len(commit):]
	g, jerr := mls.group_join(welcome, mls.Join_Params{key_package = &f.b_kp, secrets = &f.b_secrets, sig_priv = f.b_id.sig_priv})
	if jerr != .None {
		fail(f, fmt.tprintf("b join: %v", jerr))
		return
	}
	bb := dave.sender_base_secret(g, FAKE_USER_B)
	ab := dave.sender_base_secret(g, FAKE_USER_A)
	dave.ratchet_init(&f.b_ratchet, bb[:])
	dave.ratchet_init(&f.a_ratchet, ab[:])
	locks.lock(&f.mu)
	f.b_group = g
	f.commit_ok = true
	locks.unlock(&f.mu)
	tb := make([]byte, 2 + len(commit), context.temp_allocator)
	tb[1] = 1 // transition id 1
	copy(tb[2:], commit)
	srv_binary(&s, 4, 29, tb)

	text, _, _, ok = srv_next(f, &s)
	if !ok {
		fail(f, "no ready")
		return
	}
	v, _ := json.parse_string(text, parse_integers = true, allocator = context.temp_allocator)
	if jint(jget(v, "op")) == 23 {
		locks.lock(&f.mu)
		f.ready_tid = int(jint(jget(jget(v, "d"), "transition_id")))
		locks.unlock(&f.mu)
	}
	srv_text(&s, `{"op":22,"d":{"transition_id":1},"seq":5}`)
	srv_text(&s, fmt.tprintf(`{{"op":5,"d":{{"user_id":"%d","ssrc":%d,"speaking":1}},"seq":6}}`, FAKE_USER_B, FAKE_SSRC_B))
	// keep serving heartbeats until the client closes
	for {
		_, _, _, more := srv_next(f, &s)
		if !more do break
	}
}

@(private = "file")
udp_thread :: proc(data: rawptr) {
	f := cast(^Fake)data
	context.allocator = f.allocator
	buf: [2048]byte
	plain: [2048]byte
	tc: Transport_Crypto
	transport_init(&tc, .Aes256_Gcm_Rtpsize, f.key[:])
	tx: Transport_Crypto
	transport_init(&tx, .Aes256_Gcm_Rtpsize, f.key[:])
	defer transport_reset(&tc)
	defer transport_reset(&tx)
	seq: u16 = 1
	ts: u32 = 0
	nonce: u32 = 0
	dnonce: u32 = 0
	next_send := time.tick_now()
	for !sync.atomic_load(&f.stop) {
		n, from, err := net.recv_udp(f.udp, buf[:])
		if err == nil && n > 0 {
			pkt := buf[:n]
			if n == DISCOVERY_LEN && get_u16(pkt) == 1 {
				resp: [DISCOVERY_LEN]byte
				build_discovery_response(resp[:], get_u32(pkt[4:]), "127.0.0.1", u16(from.port))
				net.send_udp(f.udp, resp[:], from)
				locks.lock(&f.mu)
				f.client_ep = from
				f.have_client = true
				f.discovery = true
				locks.unlock(&f.mu)
			} else if is_rtcp(pkt) {
				m, ok := transport_open(&tc, pkt, 8, plain[:])
				if ok {
					if _, rok := parse_report(plain[:m]); rok {
						locks.lock(&f.mu)
						f.rtcp += 1
						locks.unlock(&f.mu)
					}
				}
			} else if h, hok := parse_rtp_header(pkt); hok {
				m, ok := transport_open(&tc, pkt, h.aad_len, plain[:])
				good := false
				locks.lock(&f.mu)
				bg := f.b_group
				locks.unlock(&f.mu)
				if ok && h.ssrc == FAKE_SSRC_A && bg != nil {
					p, pok := dave.parse_protocol_frame(plain[h.payload_off:m])
					if pok {
						k, kok := dave.ratchet_get(&f.a_ratchet, p.nonce >> 24)
						out: [2048]byte
						if kok {
							fl, dok := dave.decrypt_frame(k[:], &p, out[:])
							good = dok && fl == 3 && out[0] == 0xF8
						}
					}
				}
				locks.lock(&f.mu)
				if good do f.rtp_e2ee_ok += 1
				else do f.rtp_bad += 1
				locks.unlock(&f.mu)
			}
		}
		// B talks: one DAVE + transport encrypted Opus frame every 20 ms
		locks.lock(&f.mu)
		have := f.have_client && f.b_group != nil && f.ready_tid == 1
		ep := f.client_ep
		locks.unlock(&f.mu)
		if have && time.tick_diff(next_send, time.tick_now()) >= 0 {
			next_send = time.tick_add(next_send, 20 * time.Millisecond)
			opus := []byte{0xFC, 0x01, 0x02, 0x03, 0x04}
			k, _ := dave.ratchet_get(&f.b_ratchet, dnonce >> 24)
			frame: [64]byte
			fl := dave.encrypt_opus_frame(k[:], dnonce, opus, frame[:])
			dnonce += 1
			rp: [128]byte
			pl, aad := build_audio_rtp(rp[:], seq, ts, FAKE_SSRC_B, 20, true, frame[:fl])
			sealed: [200]byte
			sl := transport_seal(&tx, rp[:pl], aad, nonce, sealed[:])
			nonce += 1
			seq += 1
			ts += 960
			net.send_udp(f.udp, sealed[:sl], ep)
		}
		free_all(context.temp_allocator)
	}
}

@(private = "file")
g_capture_phase: f64

@(private = "file")
g_playback_b: int

@(test)
test_fake_voice_server :: proc(t: ^testing.T) {
	f := new(Fake)
	defer free(f)
	f.allocator = context.allocator
	for i in 0 ..< 32 do f.key[i] = u8(i + 1)
	pub: [mls.NPK]byte
	f.ext_priv, pub = mls.generate_signature_key()
	w := mls.writer_make(context.allocator)
	mls.w_external_sender(&w, mls.External_Sender{signature_key = pub[:], credential = mls.Credential{mls.CRED_BASIC, {0}}})
	f.ext_raw = w.buf[:]
	defer delete(w.buf)
	f.b_id.sig_priv, f.b_id.sig_pub = mls.generate_signature_key()
	bid := make([]byte, 8, context.temp_allocator)
	for i in 0 ..< 8 do bid[i] = u8(FAKE_USER_B >> (56 - 8 * uint(i)))
	f.b_id.credential = mls.Credential{mls.CRED_BASIC, bid}
	_, f.b_kp, f.b_secrets = mls.key_package_create(&f.b_id, context.temp_allocator)

	lsock, lerr := net.listen_tcp(net.Endpoint{net.IP4_Loopback, 0})
	testing.expect(t, lerr == nil)
	if lerr != nil do return
	f.listen = lsock
	lep, _ := net.bound_endpoint(lsock)
	f.tcp_port = lep.port
	usock, uerr := net.make_bound_udp_socket(net.IP4_Loopback, 0)
	testing.expect(t, uerr == nil)
	if uerr != nil do return
	f.udp = usock
	net.set_option(usock, .Receive_Timeout, 5 * time.Millisecond)
	uep, _ := net.bound_endpoint(usock)
	f.udp_port = uep.port

	gth := thread.create_and_start_with_data(f, gw_thread)
	uth := thread.create_and_start_with_data(f, udp_thread)

	g_playback_b = 0
	set_codec(stub_codec())
	opts := Options {
		dial = proc(host: string, port: int) -> (netio.Stream, bool) {
			tcp, err := netio.dial_tcp(host, port)
			if err != .None do return {}, false
			return netio.tcp_stream(tcp), true
		},
		no_audio_devices = true,
		capture = proc(data: rawptr, out: []f32) -> int {
			for i in 0 ..< len(out) {
				out[i] = 0.3 * f32(math.sin(g_capture_phase))
				g_capture_phase += 2 * math.PI * 440 / 48000
			}
			return len(out)
		},
		playback = proc(data: rawptr, user_id: u64, pcm: []f32) {
			if user_id == FAKE_USER_B do sync.atomic_add(&g_playback_b, 1)
		},
	}
	info := Voice_Server_Info {
		endpoint            = fmt.tprintf("127.0.0.1:%d", f.tcp_port),
		token               = "TOKEN",
		guild_or_channel_id = FAKE_GUILD,
		user_id             = FAKE_USER_A,
		session_id          = "SESSION",
		channel_id          = FAKE_CHANNEL,
	}
	c := voice_connect(info, opts)
	connected := wait_state(c, .Connected, 5 * time.Second)
	testing.expect(t, connected, "connected")
	time.sleep(1800 * time.Millisecond)

	st := e2ee_status(c, context.temp_allocator)
	testing.expect(t, st.active && st.protocol_version == 1 && st.epoch == 1, "e2ee active")
	if f.b_group != nil {
		auth := mls.epoch_authenticator(f.b_group)
		want, _ := dave.privacy_code(auth[:], context.temp_allocator)
		testing.expect(t, st.privacy_code == want, "privacy code matches peer")
	}
	speakers := speaking_users(c, context.temp_allocator)
	has_a, has_b := false, false
	for id in speakers {
		if id == FAKE_USER_A do has_a = true
		if id == FAKE_USER_B do has_b = true
	}
	testing.expect(t, has_a && has_b, "speaking indicators for self and peer")
	stats := get_stats(c)
	testing.expect(t, stats.ws_ping_ms >= 0 && stats.packets_sent > 20 && stats.packets_received > 20)
	vc, vok := verification_code(c, FAKE_USER_B, context.temp_allocator)
	testing.expect(t, vok && len(vc) == 45, "verification code")

	voice_disconnect(c)
	time.sleep(100 * time.Millisecond)
	sync.atomic_store(&f.stop, true)
	thread.join(gth)
	thread.join(uth)
	thread.destroy(gth)
	thread.destroy(uth)
	net.close(lsock)
	net.close(usock)

	testing.expectf(t, f.failure == "", "server failure: %s", f.failure)
	testing.expectf(t, f.request_line == "GET /?v=9 HTTP/1.1", "request line %q", f.request_line)
	testing.expectf(t, f.header_names == "Host,Connection,Pragma,Cache-Control,User-Agent,Upgrade,Origin,Sec-WebSocket-Version,Accept-Encoding,Accept-Language,Sec-WebSocket-Key,Sec-WebSocket-Extensions", "header order %q", f.header_names)
	testing.expect(t, strings.has_prefix(f.identify, `{"op":0,"d":{"server_id":"1564227669971832975","channel_id":"1564227670806364345","user_id":"1546819257420087346","session_id":"SESSION","token":"TOKEN","max_dave_protocol_version":1`), "identify")
	testing.expect(t, f.got_op16, "op 16 after READY")
	testing.expect(t, f.discovery, "ip discovery")
	testing.expect(t, strings.contains(f.select_proto, fmt.tprintf(`"data":{{"address":"127.0.0.1","port":`)) && strings.contains(f.select_proto, `"mode":"aead_aes256_gcm_rtpsize"`), "select protocol")
	testing.expect(t, f.key_package && f.commit_ok && f.ready_tid == 1, "DAVE MLS flow")
	testing.expect(t, f.heartbeats >= 3 && f.last_seq_ack == 6, "heartbeats with seq_ack")
	testing.expect(t, f.speaking_on, "op 5 speaking")
	testing.expectf(t, f.rtp_e2ee_ok > 20, "E2EE rtp from client: ok=%d bad=%d", f.rtp_e2ee_ok, f.rtp_bad)
	testing.expect(t, f.rtcp >= 1, "rtcp report")
	testing.expectf(t, f.close_code == CLOSE_FORCE, "close code %d", f.close_code)
	testing.expectf(t, sync.atomic_load(&g_playback_b) > 20, "played B's audio: %d", g_playback_b)

	delete(f.request_line)
	delete(f.header_names)
	delete(f.identify)
	delete(f.select_proto)
	if f.b_group != nil {
		dave.ratchet_destroy(&f.b_ratchet)
		dave.ratchet_destroy(&f.a_ratchet)
		mls.group_destroy(f.b_group)
	}
}

// ---------------------------------------------------------------------------
// Resume: the server drops the TCP connection after SESSION_DESCRIPTION; the
// client must reconnect and send RESUME (op 7) with seq_ack, then accept
// RESUMED (op 9) and be Connected again without a new IDENTIFY.

@(private = "file")
Resume_Fake :: struct {
	listen:     net.TCP_Socket,
	udp:        net.UDP_Socket,
	udp_port:   int,
	allocator:  runtime.Allocator,
	stop:       bool,
	resume_msg: string,
	second:     bool,
	failure:    string,
}

@(private = "file")
upgrade :: proc(listen: net.TCP_Socket) -> (s: Srv, ok: bool) {
	sock, _, aerr := net.accept_tcp(listen)
	if aerr != nil do return
	s = Srv{sock = sock, buf = make([dynamic]byte)}
	for !strings.contains(string(s.buf[:]), "\r\n\r\n") {
		if !srv_fill(&s, len(s.buf) + 1) do return s, false
	}
	head := string(s.buf[:strings.index(string(s.buf[:]), "\r\n\r\n")])
	key := ""
	for l in strings.split(head, "\r\n", context.temp_allocator) {
		if strings.has_prefix(l, "Sec-WebSocket-Key:") do key = strings.trim_space(l[len("Sec-WebSocket-Key:"):])
	}
	remove_range(&s.buf, 0, len(head) + 4)
	resp := fmt.tprintf("HTTP/1.1 101 Switching Protocols\r\nupgrade: websocket\r\nConnection: upgrade\r\nsec-websocket-accept: %s\r\n\r\n", http.ws_accept_for_key(key, context.temp_allocator))
	net.send_tcp(sock, transmute([]byte)resp)
	return s, true
}

@(private = "file")
next_text :: proc(s: ^Srv) -> (string, bool) {
	for {
		op, p, ok := srv_read_frame(s)
		if !ok || op == 8 do return "", false
		if op == 1 {
			if strings.has_prefix(string(p), `{"op":3`) do continue
			return strings.clone(string(p), context.temp_allocator), true
		}
	}
}

@(private = "file")
resume_gw :: proc(data: rawptr) {
	f := cast(^Resume_Fake)data
	context.allocator = f.allocator
	s, ok := upgrade(f.listen)
	if !ok {
		f.failure = "upgrade 1"
		return
	}
	_, _ = next_text(&s) // identify
	srv_text(&s, `{"op":8,"d":{"v":8,"heartbeat_interval":5000}}`)
	srv_text(&s, fmt.tprintf(`{{"op":2,"d":{{"ssrc":77,"port":%d,"modes":["aead_xchacha20_poly1305_rtpsize"],"ip":"127.0.0.1","experiments":[]}}}}`, f.udp_port))
	for {
		t, tok := next_text(&s)
		if !tok {
			f.failure = "no select"
			break
		}
		if strings.has_prefix(t, `{"op":1,`) do break
	}
	key := strings.repeat("7,", 31, context.temp_allocator)
	srv_text(&s, fmt.tprintf(`{{"op":4,"d":{{"secret_key":[%s7],"mode":"aead_xchacha20_poly1305_rtpsize","dave_protocol_version":1,"audio_codec":"opus"}},"seq":3}}`, key))
	time.sleep(200 * time.Millisecond)
	net.close(s.sock) // abrupt drop (1006)
	delete(s.buf)

	s2, ok2 := upgrade(f.listen)
	if !ok2 {
		f.failure = "upgrade 2"
		return
	}
	defer delete(s2.buf)
	defer net.close(s2.sock)
	m, mok := next_text(&s2)
	if mok do f.resume_msg = strings.clone(m)
	srv_text(&s2, `{"op":9,"d":null}`)
	f.second = true
	for {
		if _, more := next_text(&s2); !more do break
	}
}

@(private = "file")
resume_udp :: proc(data: rawptr) {
	f := cast(^Resume_Fake)data
	context.allocator = f.allocator
	buf: [2048]byte
	for !sync.atomic_load(&f.stop) {
		n, from, err := net.recv_udp(f.udp, buf[:])
		if err != nil || n != DISCOVERY_LEN do continue
		resp: [DISCOVERY_LEN]byte
		build_discovery_response(resp[:], get_u32(buf[4:]), "127.0.0.1", u16(from.port))
		net.send_udp(f.udp, resp[:], from)
	}
}

@(test)
test_fake_voice_resume :: proc(t: ^testing.T) {
	f := new(Resume_Fake)
	defer free(f)
	f.allocator = context.allocator
	lsock, lerr := net.listen_tcp(net.Endpoint{net.IP4_Loopback, 0})
	usock, uerr := net.make_bound_udp_socket(net.IP4_Loopback, 0)
	testing.expect(t, lerr == nil && uerr == nil)
	if lerr != nil || uerr != nil do return
	f.listen = lsock
	f.udp = usock
	net.set_option(usock, .Receive_Timeout, 20 * time.Millisecond)
	uep, _ := net.bound_endpoint(usock)
	f.udp_port = uep.port
	lep, _ := net.bound_endpoint(lsock)
	set_codec(stub_codec())
	gth := thread.create_and_start_with_data(f, resume_gw)
	uth := thread.create_and_start_with_data(f, resume_udp)
	opts := Options {
		dial = proc(host: string, port: int) -> (netio.Stream, bool) {
			tcp, err := netio.dial_tcp(host, port)
			if err != .None do return {}, false
			return netio.tcp_stream(tcp), true
		},
		no_audio_devices = true,
	}
	c := voice_connect(Voice_Server_Info{endpoint = fmt.tprintf("127.0.0.1:%d", lep.port), token = "TK", guild_or_channel_id = 5, user_id = 6, session_id = "SS", channel_id = 7}, opts)
	testing.expect(t, wait_state(c, .Connected, 3 * time.Second), "first connect")
	testing.expect(t, wait_state(c, .Resuming, 3 * time.Second), "resuming after drop")
	testing.expect(t, wait_state(c, .Connected, 5 * time.Second), "resumed")
	st := get_stats(c)
	testing.expect(t, st.reconnects == 1)
	voice_disconnect(c)
	sync.atomic_store(&f.stop, true)
	thread.join(gth)
	thread.join(uth)
	thread.destroy(gth)
	thread.destroy(uth)
	net.close(lsock)
	net.close(usock)
	testing.expectf(t, f.failure == "", "server: %s", f.failure)
	testing.expectf(t, f.resume_msg == `{"op":7,"d":{"token":"TK","session_id":"SS","server_id":"5","channel_id":"7","seq_ack":3}}`, "resume: %q", f.resume_msg)
	delete(f.resume_msg)
}
