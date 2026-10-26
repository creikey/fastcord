package voice

import "core:crypto/aes"
import "core:encoding/json"
import "core:math"
import "core:strings"
import "core:testing"

@(test)
test_rtp_build_parse :: proc(t: ^testing.T) {
	payload := []byte{1, 2, 3, 4, 5}
	buf: [64]byte
	n, aad := build_audio_rtp(buf[:], 0x1234, 0xdeadbeef, 8597, 30, true, 7, payload)
	testing.expect(t, n == 24 + 5 && aad == 16)
	testing.expect(t, buf[0] == 0x90 && buf[1] == 120 && buf[12] == 0xBE && buf[13] == 0xDE)
	h, ok := parse_rtp_header(buf[:n])
	testing.expect(t, ok && h.seq == 0x1234 && h.ts == 0xdeadbeef && h.ssrc == 8597 && h.pt == 120)
	testing.expect(t, h.aad_len == 16 && h.payload_off == 24 && h.ext_words == 2)
	lvl, voice, lok := ext_audio_level(buf[:n], h)
	testing.expect(t, lok && lvl == 30 && voice)
	testing.expect(t, !is_rtcp(buf[:n]))
}

@(test)
test_transport_roundtrip :: proc(t: ^testing.T) {
	key: [32]byte
	for i in 0 ..< 32 do key[i] = u8(i * 7)
	for mode in ([]Mode{.Aes256_Gcm_Rtpsize, .Xchacha20_Poly1305_Rtpsize}) {
		tx, rx: Transport_Crypto
		transport_init(&tx, mode, key[:])
		transport_init(&rx, mode, key[:])
		defer transport_reset(&tx)
		defer transport_reset(&rx)
		pkt: [64]byte
		n, aad := build_audio_rtp(pkt[:], 1, 960, 42, 127, false, 0, {0xF8, 0xFF, 0xFE})
		sealed: [128]byte
		sl := transport_seal(&tx, pkt[:n], aad, 0x01020304, sealed[:])
		testing.expect(t, sl == n + 16 + 4)
		// header + ext header in the clear, nonce big-endian at the end
		testing.expect(t, string(sealed[:16]) == string(pkt[:16]))
		testing.expect(t, sealed[sl - 4] == 1 && sealed[sl - 1] == 4)
		testing.expect(t, string(sealed[16:n]) != string(pkt[16:n]), "body encrypted")
		out: [128]byte
		m, ok := transport_open(&rx, sealed[:sl], aad, out[:])
		testing.expect(t, ok && m == n && string(out[:m]) == string(pkt[:n]))
		sealed[3] ~= 1 // tamper with AAD
		_, ok2 := transport_open(&rx, sealed[:sl], aad, out[:])
		testing.expect(t, !ok2, "aad authenticated")
	}
}

@(test)
test_transport_aes_known_layout :: proc(t: ^testing.T) {
	// rtpsize AES-256-GCM == GCM(key, iv = nonce_be || 0^8, aad = header, pt = rest)
	key: [32]byte
	for i in 0 ..< 32 do key[i] = u8(255 - i)
	tc: Transport_Crypto
	transport_init(&tc, .Aes256_Gcm_Rtpsize, key[:])
	defer transport_reset(&tc)
	pkt := []byte{0x80, 0x78, 0, 1, 0, 0, 3, 0xC0, 0, 0, 0x21, 0x95, 9, 8, 7, 6, 5}
	sealed: [64]byte
	sl := transport_seal(&tc, pkt, 12, 5, sealed[:])
	ctx: aes.Context_GCM
	aes.init_gcm(&ctx, key[:])
	iv := [12]byte{0, 0, 0, 5, 0, 0, 0, 0, 0, 0, 0, 0}
	ct: [5]byte
	tag: [16]byte
	aes.seal_gcm(&ctx, ct[:], tag[:], iv[:], pkt[:12], pkt[12:])
	testing.expect(t, sl == 17 + 20)
	testing.expect(t, string(sealed[12:17]) == string(ct[:]) && string(sealed[17:33]) == string(tag[:]))
}

@(test)
test_rtcp_reports :: proc(t: ^testing.T) {
	blocks := []Report_Block{{ssrc = 999, fraction_lost = 12, cum_lost = 3, ext_max_seq = 70000, jitter = 40, lsr = 0x11223344, dlsr = 0x10000}}
	buf: [128]byte
	n := build_report(buf[:], 8597, true, 0x0102030405060708, 960, 10, 100, blocks)
	testing.expect(t, n == 8 + 20 + 24 && buf[1] == 200 && buf[0] == 0x81)
	testing.expect(t, is_rtcp(buf[:n]))
	r, ok := parse_report(buf[:n])
	testing.expect(t, ok && r.is_sr && r.ssrc == 8597 && r.ntp == 0x0102030405060708 && r.n_blocks == 1)
	testing.expect(t, r.blocks[0].ssrc == 999 && r.blocks[0].lsr == 0x11223344 && r.blocks[0].ext_max_seq == 70000)
	n2 := build_report(buf[:], 8597, false, 0, 0, 0, 0, nil)
	testing.expect(t, n2 == 8 && buf[1] == 201)
}

@(test)
test_ip_discovery_packets :: proc(t: ^testing.T) {
	req: [DISCOVERY_LEN]byte
	build_discovery_request(req[:], 8597)
	testing.expect(t, req[0] == 0 && req[1] == 1 && req[2] == 0 && req[3] == 70 && get_u32(req[4:]) == 8597)
	ssrc, _, _, ok := parse_discovery(req[:], 1)
	testing.expect(t, ok && ssrc == 8597)
	resp: [DISCOVERY_LEN]byte
	build_discovery_response(resp[:], 8597, "172.112.135.118", 60263)
	s2, addr, port, ok2 := parse_discovery(resp[:], 2)
	testing.expect(t, ok2 && s2 == 8597 && addr == "172.112.135.118" && port == 60263)
}

@(test)
test_mode_choice :: proc(t: ^testing.T) {
	testing.expect(t, choose_mode({"aead_aes256_gcm_rtpsize", "aead_xchacha20_poly1305_rtpsize"}) == .Aes256_Gcm_Rtpsize)
	testing.expect(t, choose_mode({"aead_xchacha20_poly1305_rtpsize", "aead_aes256_gcm_rtpsize"}) == .Aes256_Gcm_Rtpsize)
	testing.expect(t, choose_mode({"aead_xchacha20_poly1305_rtpsize", "xsalsa20_poly1305"}) == .Xchacha20_Poly1305_Rtpsize)
	testing.expect(t, choose_mode({"xsalsa20_poly1305"}) == .None)
}

@(test)
test_gateway_messages_match_capture :: proc(t: ^testing.T) {
	// shapes captured from the official client (tokens replaced)
	id := msg_identify(1564227669971832975, 1564227670806364345, 1546819257420087346, "SESSION", "TOKEN", true)
	testing.expect(t, id == `{"op":0,"d":{"server_id":"1564227669971832975","channel_id":"1564227670806364345","user_id":"1546819257420087346","session_id":"SESSION","token":"TOKEN","max_dave_protocol_version":1,"video":true,"streams":[{"type":"video","rid":"100","quality":100}]}}`)
	sp := msg_select_protocol("172.112.135.118", 60263, .Aes256_Gcm_Rtpsize, "0a3ebb58-5f80-4b6f-b136-b8ce12b86ff8", {"fixed_keyframe_interval"})
	testing.expect(t, sp == `{"op":1,"d":{"protocol":"udp","data":{"address":"172.112.135.118","port":60263,"mode":"aead_aes256_gcm_rtpsize"},"address":"172.112.135.118","port":60263,"mode":"aead_aes256_gcm_rtpsize","codecs":[{"name":"opus","type":"audio","priority":1000,"payload_type":120},{"name":"AV1","type":"video","priority":1000,"payload_type":101,"rtx_payload_type":102,"encode":false,"decode":true},{"name":"H265","type":"video","priority":2000,"payload_type":103,"rtx_payload_type":104,"encode":true,"decode":true},{"name":"H264","type":"video","priority":3000,"payload_type":105,"rtx_payload_type":106,"encode":true,"decode":true},{"name":"VP8","type":"video","priority":4000,"payload_type":107,"rtx_payload_type":108,"encode":true,"decode":true}],"rtc_connection_id":"0a3ebb58-5f80-4b6f-b136-b8ce12b86ff8","experiments":["fixed_keyframe_interval"]}}`)
	testing.expect(t, msg_speaking(1, 8597) == `{"op":5,"d":{"speaking":1,"delay":0,"ssrc":8597}}`)
	testing.expect(t, msg_heartbeat(1793012180966, 5) == `{"op":3,"d":{"t":1793012180966,"seq_ack":5}}`)
	testing.expect(t, msg_transition(23, 10) == `{"op":23,"d":{"transition_id":10}}`)
	testing.expect(t, msg_resume("T", "S", 1, 2, -1) == `{"op":7,"d":{"token":"T","session_id":"S","server_id":"1","channel_id":"2","seq_ack":-1}}`)
	for s in ([]string{id, sp}) {
		_, err := json.parse_string(s, allocator = context.temp_allocator)
		testing.expect(t, err == nil, "valid json")
	}
	u := uuid4(context.temp_allocator)
	testing.expect(t, len(u) == 36 && u[14] == '4' && strings.count(u, "-") == 4)
	h, p := split_endpoint("c-lax07-200a12c1.discord.media:2096")
	testing.expect(t, h == "c-lax07-200a12c1.discord.media" && p == 2096)
	h2, p2 := split_endpoint("wss://example.discord.media")
	testing.expect(t, h2 == "example.discord.media" && p2 == 443)
}

@(test)
test_jitter_buffer :: proc(t: ^testing.T) {
	jb: Jitter_Buffer
	jb_init(&jb)
	pk :: proc(i: int) -> []byte {
		@(static) b: [1]byte
		b[0] = u8(i)
		return b[:]
	}
	// in order, steady arrival: plays after `target` frames
	now := 0.0
	jb_push(&jb, 100, 0, pk(0), now)
	k, _ := jb_pop(&jb)
	testing.expect(t, k == .None, "buffering")
	for i in 1 ..< 4 {
		now += 20
		jb_push(&jb, u16(100 + i), u32(960 * i), pk(i), now)
	}
	d: []byte
	k, d = jb_pop(&jb)
	testing.expect(t, k == .Packet && d[0] == 0)
	k, d = jb_pop(&jb)
	testing.expect(t, k == .Packet && d[0] == 1)
	// loss of 102 with 103 present -> FEC from 103
	jb.slots[102 % JB_SLOTS].valid = false
	k, d = jb_pop(&jb)
	testing.expect(t, k == .Fec && d[0] == 3, "fec recovery")
	k, d = jb_pop(&jb)
	testing.expect(t, k == .Packet && d[0] == 3)
	// empty: PLC a few times then stop
	k, _ = jb_pop(&jb)
	testing.expect(t, k == .Plc)
	for _ in 0 ..< JB_STOP_AFTER do k, _ = jb_pop(&jb)
	testing.expect(t, k == .None, "talk spurt over")
	// late packet dropped
	jb.playing = true
	jb.next_seq = 200
	jb_push(&jb, 150, 0, pk(9), now)
	testing.expect(t, jb.stats.late == 1)
	// jitter raises the target
	jb2: Jitter_Buffer
	jb_init(&jb2)
	arr := 0.0
	for i in 0 ..< 50 {
		arr += 20 + (60 if i % 2 == 0 else -40)
		jb_push(&jb2, u16(i), u32(960 * i), pk(i), arr)
		jb_pop(&jb2)
	}
	testing.expect(t, jb2.target > JB_MIN + 1, "adaptive target grows with jitter")
}

@(test)
test_vad :: proc(t: ^testing.T) {
	v: Vad
	vad_init(&v)
	silence: [960]f32
	tone: [960]f32
	for i in 0 ..< 960 do tone[i] = 0.2 * f32(math.sin(f64(i) * 2 * math.PI * 440 / 48000))
	for _ in 0 ..< 50 {
		a, _ := vad_process(&v, silence[:])
		testing.expect(t, !a)
	}
	a, db := vad_process(&v, tone[:])
	testing.expect(t, a && db > -20, "speech detected")
	// trailing hang of 25 frames
	for i in 0 ..< VAD_DEFAULT_TRAILING {
		a, _ = vad_process(&v, silence[:])
		testing.expectf(t, a, "hang frame %d", i)
	}
	a, _ = vad_process(&v, silence[:])
	testing.expect(t, !a, "released after trailing")
	testing.expect(t, audio_level_byte(-200) == 127 && audio_level_byte(0) == 0)
}
