package quic

import "core:encoding/hex"
import "core:math/rand"
import "core:net"
import "core:slice"
import "core:testing"
import "core:time"

// The official client's first two datagrams to discord.com (Chrome 148
// QUIC): each 1250 bytes, the ClientHello spread across both.
CHROME_INITIAL_1 :: #load("testdata/chrome_initial_1.bin")
CHROME_INITIAL_2 :: #load("testdata/chrome_initial_2.bin")
// The same connection's ClientHello, reassembled (lives with the tls fixtures).
CHROME_QUIC_CH :: #load("../tls/testdata/chrome_quic_ch_full.bin")

@(private = "file")
Decoded_Initial :: struct {
	dcid_len, scid_len, token_len, pn_len: int,
	pn:                                    u64,
	frames:                                [dynamic]u8, // frame types in order
	crypto:                                [dynamic]Range,
}

// decode_client_initial removes protection from a client Initial with the
// client keys and lists its frames, writing CRYPTO data into ch.
@(private = "file")
decode_client_initial :: proc(t: ^testing.T, dgram: []byte, keys: ^Keys, ch: []byte) -> (d: Decoded_Initial, ok: bool) {
	pkt := slice.clone(dgram, context.temp_allocator)
	r := reader(pkt[5:])
	dcid := r_take(&r, int(r_u8(&r)))
	scid := r_take(&r, int(r_u8(&r)))
	token := r_vec(&r)
	length := r_varint(&r)
	if !r.ok do return
	d.dcid_len, d.scid_len, d.token_len = len(dcid), len(scid), len(token)
	pn_off := len(pkt) - len(r.b)
	testing.expect_value(t, pn_off + int(length), len(pkt))
	trunc, pn_len, ok1 := unprotect_header(keys, pkt, pn_off)
	if !ok1 do return
	d.pn_len = pn_len
	d.pn = decode_pn(-1, trunc, pn_len)
	pt, ok2 := open(keys, pkt[:pn_off + int(length)], pn_off + pn_len, d.pn)
	if !ok2 do return
	fr := reader(pt)
	for len(fr.b) > 0 {
		typ := r_varint(&fr)
		switch typ {
		case 0x00:
			for len(fr.b) > 0 && fr.b[0] == 0 do fr.b = fr.b[1:]
		case 0x01:
		case 0x06:
			off := r_varint(&fr)
			data := r_vec(&fr)
			if !fr.ok || int(off) + len(data) > len(ch) do return
			copy(ch[off:], data)
			append(&d.crypto, Range{off, off + u64(len(data))})
		case:
			return
		}
		append(&d.frames, u8(typ))
	}
	return d, fr.ok
}

@(private = "file")
initial_dcid :: proc(dgram: []byte) -> []byte {return dgram[6:][:dgram[5]]}

// Chrome's own Initials decrypt with our RFC 9001 keys and reassemble into
// the captured ClientHello; this pins down the layout we imitate.
@(test)
chrome_initials_decode :: proc(t: ^testing.T) {
	c, s: Keys
	initial_keys(&c, &s, initial_dcid(CHROME_INITIAL_1))
	defer keys_clear(&c)
	defer keys_clear(&s)
	ch := make([]byte, len(CHROME_QUIC_CH))
	defer delete(ch)
	d1, ok1 := decode_client_initial(t, CHROME_INITIAL_1, &c, ch)
	d2, ok2 := decode_client_initial(t, CHROME_INITIAL_2, &c, ch)
	defer delete(d1.frames)
	defer delete(d2.frames)
	defer delete(d1.crypto)
	defer delete(d2.crypto)
	testing.expect(t, ok1 && ok2)
	testing.expect(t, slice.equal(ch, CHROME_QUIC_CH), "reassembled ClientHello differs")
	testing.expect_value(t, len(CHROME_INITIAL_1), MAX_DATAGRAM)
	testing.expect_value(t, d1.dcid_len, 8)
	testing.expect_value(t, d1.scid_len, 0)
	testing.expect_value(t, d1.token_len, 0)
	testing.expect_value(t, d1.pn, 1)
	testing.expect_value(t, d2.pn, 2)
	testing.expect_value(t, d1.pn_len, 1)
	testing.expect_value(t, d2.pn_len, 2)
}

// Our chaos-protected first flight has the same envelope as Chrome's.
@(test)
our_initials_match_chrome_envelope :: proc(t: ^testing.T) {
	recv_sock, e1 := net.make_bound_udp_socket(net.IP4_Loopback, 0)
	if !testing.expect(t, e1 == nil) do return
	defer net.close(recv_sock)
	recv_ep, _ := net.bound_endpoint(recv_sock)
	send_sock, e2 := net.make_unbound_udp_socket(.IP4)
	if !testing.expect(t, e2 == nil) do return
	defer net.close(send_sock)
	net.set_option(recv_sock, .Receive_Timeout, time.Second)

	context.allocator = conn_allocator()
	c := new(Conn)
	c.sock = send_sock
	c.peer = recv_ep
	conn_init(c, {})
	ch := slice.clone(CHROME_QUIC_CH)
	defer delete(ch)
	sb_write(&c.spaces[.Initial].crypto_send, ch)
	send_chaos_client_hello(c, time.tick_now())

	ck, sk: Keys
	initial_keys(&ck, &sk, c.odcid[:])
	defer keys_clear(&ck)
	defer keys_clear(&sk)
	got := make([]byte, len(ch))
	defer delete(got)
	have: Range_Set
	defer delete(have)
	buf: [2048]byte
	for i in 0 ..< 2 {
		n, _, err := net.recv_udp(recv_sock, buf[:])
		if !testing.expect(t, err == nil) do break
		testing.expect_value(t, n, MAX_DATAGRAM)
		d, ok := decode_client_initial(t, buf[:n], &ck, got)
		testing.expect(t, ok)
		testing.expect_value(t, d.dcid_len, 8)
		testing.expect_value(t, d.scid_len, 0)
		testing.expect_value(t, d.pn, u64(i + 1))
		testing.expect_value(t, d.pn_len, i + 1)
		pings, cryptos := 0, 0
		for f in d.frames {
			if f == 0x01 do pings += 1
			if f == 0x06 do cryptos += 1
		}
		testing.expectf(t, pings >= 3 && cryptos >= 2, "packet %d: %d pings %d crypto", i, pings, cryptos)
		for r in d.crypto do rs_add(&have, r.lo, r.hi)
		delete(d.frames)
		delete(d.crypto)
	}
	testing.expect(t, slice.equal(got, ch), "reassembly differs")
	testing.expect(t, len(have) == 1 && have[0] == Range{0, u64(len(ch))}, "CRYPTO coverage")
	conn_destroy(c)
}

// Our transport parameters: Chrome's set and values (order is random).
@(test)
transport_params_match_chrome :: proc(t: ^testing.T) {
	// Pull Chrome's quic_transport_parameters out of the captured hello.
	chrome := find_qtp(CHROME_QUIC_CH)
	for round in 0 ..< 5 {
		ours := chrome_transport_params(0)
		defer delete(ours)
		a, b := tp_map(ours), tp_map(chrome)
		defer delete(a)
		defer delete(b)
		testing.expect_value(t, len(a), len(b))
		for id, v in b {
			if is_grease_tp(id) do continue
			ov, found := a[id]
			testing.expectf(t, found, "missing param %x", id)
			if id == TP_VERSION_INFORMATION {
				testing.expect(t, slice.equal(ov[:8], v[:8]), "version_information chosen/available")
				testing.expect(t, ov[8] & 0x0f == 0x0a && ov[11] & 0x0f == 0x0a, "GREASE version")
			} else {
				testing.expectf(t, slice.equal(ov, v), "param %x: %x vs %x", id, ov, v)
			}
		}
		grease := 0
		for id in a do if is_grease_tp(id) do grease += 1
		testing.expect_value(t, grease, 1)
		_ = round
	}
	with_rtt := chrome_transport_params(61662)
	defer delete(with_rtt)
	m := tp_map(with_rtt)
	defer delete(m)
	v, found := m[TP_GOOGLE_INITIAL_RTT]
	testing.expect(t, found && slice.equal(v, []byte{0x80, 0x00, 0xf0, 0xde}), "initial_rtt")
}

@(private = "file")
is_grease_tp :: proc(id: u64) -> bool {return id >= 27 && (id - 27) % 31 == 0}

@(private = "file")
tp_map :: proc(b: []byte) -> map[u64][]byte {
	m := make(map[u64][]byte)
	r := reader(b)
	for len(r.b) > 0 {
		id := r_varint(&r)
		v := r_vec(&r)
		if !r.ok do break
		m[id] = v
	}
	return m
}

@(private = "file")
find_qtp :: proc(ch: []byte) -> []byte {
	// type(1) len(3) version(2) random(32) sid(1+n) ciphers(2+n) comp(1+n) exts(2)
	p := 4 + 2 + 32
	p += 1 + int(ch[p])
	p += 2 + (int(ch[p]) << 8 | int(ch[p + 1]))
	p += 1 + int(ch[p])
	end := p + 2 + (int(ch[p]) << 8 | int(ch[p + 1]))
	p += 2
	for p < end {
		typ := int(ch[p]) << 8 | int(ch[p + 1])
		l := int(ch[p + 2]) << 8 | int(ch[p + 3])
		if typ == 0x39 do return ch[p + 4:][:l]
		p += 4 + l
	}
	return nil
}

@(test)
range_set_ops :: proc(t: ^testing.T) {
	s: Range_Set
	defer delete(s)
	rs_add(&s, 10, 20)
	rs_add(&s, 30, 40)
	rs_add(&s, 20, 30)
	testing.expect(t, len(s) == 1 && s[0] == Range{10, 40})
	rs_remove(&s, 15, 25)
	testing.expect(t, len(s) == 2 && s[0] == Range{10, 15} && s[1] == Range{25, 40})
	testing.expect(t, rs_contains(&s, 26, 30))
	testing.expect(t, !rs_contains(&s, 14, 26))
}

@(test)
recv_buf_reassembly :: proc(t: ^testing.T) {
	b: Recv_Buf
	defer rb_destroy(&b)
	rb_insert(&b, 5, transmute([]byte)string("world"))
	testing.expect_value(t, len(rb_readable(&b)), 0)
	rb_insert(&b, 0, transmute([]byte)string("hello"))
	testing.expect_value(t, string(rb_readable(&b)), "helloworld")
	rb_consume(&b, 7)
	rb_insert(&b, 3, transmute([]byte)string("loXX")) // old data + overlap
	testing.expect_value(t, string(rb_readable(&b)), "rld")
}

@(test)
send_buf_loss_and_ack :: proc(t: ^testing.T) {
	b: Send_Buf
	defer sb_destroy(&b)
	sb_write(&b, transmute([]byte)string("0123456789"))
	sb_finish(&b)
	off, d, fin := sb_peek(&b, 4)
	testing.expect(t, off == 0 && string(d) == "0123" && !fin)
	sb_consume(&b, off, len(d), fin)
	off, d, fin = sb_peek(&b, 100)
	testing.expect(t, off == 4 && string(d) == "456789" && fin)
	sb_consume(&b, off, len(d), fin)
	testing.expect(t, !sb_has_pending(&b))
	sb_on_lost(&b, 0, 4, false)
	sb_on_ack(&b, 4, 10, true)
	off, d, fin = sb_peek(&b, 100)
	testing.expect(t, off == 0 && string(d) == "0123" && !fin)
	sb_consume(&b, off, len(d), fin)
	sb_on_ack(&b, 0, 4, false)
	testing.expect(t, sb_all_acked(&b))
}

// RFC 9001 Appendix A.4: a Retry for ODCID 8394c8f03e515708 passes the
// integrity check and switches DCID/token; a corrupted one is ignored.
@(test)
rfc9001_retry_integrity :: proc(t: ^testing.T) {
	context.allocator = conn_allocator()
	pkt_hex := "ff000000010008f067a5502a4262b5746f6b656e04a265ba2eff4d829058fb3f0f2496ba"
	for corrupt in ([]bool{true, false}) {
		c := new(Conn)
		conn_init(c, {})
		c.odcid = {0x83, 0x94, 0xc8, 0xf0, 0x3e, 0x51, 0x57, 0x08}
		pkt, _ := hex.decode(transmute([]byte)pkt_hex)
		if corrupt do pkt[len(pkt) - 1] ~= 1
		process_datagram_locked(c, pkt, time.tick_now())
		if corrupt {
			testing.expect_value(t, c.retry_scid_len, 0)
		} else {
			testing.expect_value(t, c.retry_scid_len, 8)
			testing.expect_value(t, string(c.token[:]), "token")
			testing.expect(t, slice.equal(c.dcid[:c.dcid_len], []byte{0xf0, 0x67, 0xa5, 0x50, 0x2a, 0x42, 0x62, 0xb5}))
		}
		delete(pkt)
		conn_destroy(c)
	}
}

// Garbage datagrams and random frame payloads must never crash.
@(test)
fuzz_receive_path :: proc(t: ^testing.T) {
	context.allocator = conn_allocator()
	buf: [1400]byte
	frame_types := [?]u8{0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x0a, 0x0e, 0x0f, 0x10, 0x11, 0x12, 0x13, 0x18, 0x1a, 0x1c, 0x1d, 0x1e, 0x30}
	for i in 0 ..< 2000 {
		c := new(Conn)
		conn_init(c, {})
		c.handshake_complete = true
		c.peer_max_bidi = 100
		n := 1 + int(rand.uint32() % len(buf))
		for j in 0 ..< n do buf[j] = byte(rand.uint32())
		if i % 2 == 0 {
			// Frame parser with a plausible first frame type.
			buf[0] = frame_types[rand.uint32() % len(frame_types)]
			process_frames(c, .App, buf[:n], time.tick_now())
		} else {
			if i % 4 == 1 {
				buf[0] = 0xc0
				buf[1], buf[2], buf[3], buf[4] = 0, 0, 0, 1
			}
			process_datagram_locked(c, buf[:n], time.tick_now())
		}
		conn_destroy(c)
	}
}
