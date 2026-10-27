package http

import "core:fmt"
import "core:mem"
import "core:strconv"
import "core:strings"
import "core:testing"
import "core:thread"
import "fc:netio"

// The official client's gateway handshake (header order and casing matter).
@(private = "file")
GATEWAY_HEADERS := []Header {
	{"Host", "gateway.discord.gg"},
	{"Connection", "Upgrade"},
	{"Pragma", "no-cache"},
	{"Cache-Control", "no-cache"},
	{"User-Agent", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) discord/0.0.419 Chrome/148.0.7778.280 Electron/42.11.15 Safari/537.36"},
	{"Upgrade", "websocket"},
	{"Origin", "https://discord.com"},
	{"Sec-WebSocket-Version", "13"},
	{"Accept-Encoding", "gzip, deflate, br, zstd"},
	{"Accept-Language", "en-US"},
	{"Sec-WebSocket-Key", ""},
	{"Sec-WebSocket-Extensions", "permessage-deflate; client_max_window_bits"},
}

@(private = "file")
Ws_Fake :: struct {
	s:        netio.Stream,
	r:        Reader,
	failures: [dynamic]string,
	request:  string,
	key:      string,
	mode:     int,
	script:   proc(f: ^Ws_Fake),
	alloc:    mem.Allocator, // the test thread's allocator (server thread allocates with it)
}

@(private = "file")
wf_check :: proc(f: ^Ws_Fake, cond: bool, msg: string, args: ..any, loc := #caller_location) {
	if !cond do append(&f.failures, fmt.aprintf("%v: %s", loc.line, fmt.tprintf(msg, ..args), allocator = f.alloc))
}

// wf_frame writes an unmasked server frame.
@(private = "file")
wf_frame :: proc(f: ^Ws_Fake, fin: bool, op: u8, payload: []byte, rsv: u8 = 0, mask := false) {
	buf := make([dynamic]byte, context.temp_allocator)
	b0 := op | rsv << 4
	if fin do b0 |= 0x80
	append(&buf, b0)
	m: u8 = 0x80 if mask else 0
	n := len(payload)
	switch {
	case n < 126:
		append(&buf, m | u8(n))
	case n <= 0xffff:
		append(&buf, m | 126, u8(n >> 8), u8(n))
	case:
		append(&buf, m | 127)
		for i := 7; i >= 0; i -= 1 do append(&buf, u8(u64(n) >> (8 * uint(i))))
	}
	if mask do append(&buf, 1, 2, 3, 4)
	start := len(buf)
	append(&buf, ..payload)
	if mask do for i in 0 ..< n do buf[start + i] ~= u8(i % 4 + 1)
	netio.write(f.s, buf[:])
}

// wf_read reads and unmasks one client frame.
@(private = "file")
wf_read :: proc(f: ^Ws_Fake) -> (h: Ws_Frame_Header, payload: []byte, err: Error) {
	h = ws_read_frame_header(&f.r) or_return
	wf_check(f, h.masked, "client frames must be masked")
	payload = make([]byte, int(h.length), context.temp_allocator)
	read_exact(&f.r, payload) or_return
	for i in 0 ..< len(payload) do payload[i] ~= h.key[i & 3]
	return
}

@(private = "file")
wf_server :: proc(f: ^Ws_Fake) {
	reader_init(&f.r, f.s, 1 << 20)
	defer reader_destroy(&f.r)
	sb := strings.builder_make(f.alloc)
	for {
		line, err := read_line(&f.r)
		if err != .None do return
		if strings.has_prefix(line, "Sec-WebSocket-Key: ") do f.key = strings.clone(line[len("Sec-WebSocket-Key: "):], f.alloc)
		strings.write_string(&sb, line)
		strings.write_string(&sb, "\r\n")
		if len(line) == 0 do break
	}
	f.request = strings.to_string(sb)
	accept := ws_accept_for_key(f.key, context.temp_allocator)
	switch f.mode {
	case 1:
		accept = "bogus"
	}
	ext := "Sec-WebSocket-Extensions: permessage-deflate\r\n" if f.mode == 2 else ""
	resp := fmt.tprintf("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: %s\r\n%s\r\n", accept, ext)
	netio.write(f.s, transmute([]byte)resp)
	if f.script != nil do f.script(f)
	free_all(context.temp_allocator)
}

@(private = "file")
ws_setup :: proc(f: ^Ws_Fake, mode := 0, script: proc(f: ^Ws_Fake) = nil, max_message := 0) -> (c: ^Ws_Conn, th: ^thread.Thread, peer: netio.Stream, err: Error) {
	a, b := pipe_make()
	f.s = b
	f.alloc = context.allocator
	f.failures.allocator = context.allocator
	f.mode = mode
	f.script = script
	peer = b
	th = thread.create_and_start_with_poly_data(f, wf_server)
	resp: Response
	c, resp, err = ws_connect(
		a,
		{method = "GET", path = "/?encoding=etf&v=9&compress=zstd-stream", headers = GATEWAY_HEADERS},
		{max_message = max_message},
	)
	response_destroy(&resp)
	if err != .None do netio.close(a)
	return
}

@(private = "file")
ws_teardown :: proc(t: ^testing.T, f: ^Ws_Fake, c: ^Ws_Conn, th: ^thread.Thread, peer: netio.Stream) {
	if c != nil do ws_close_stream(c)
	thread.join(th)
	thread.destroy(th)
	netio.close(peer)
	for s in f.failures {
		testing.expectf(t, false, "server: %s", s)
		delete(s)
	}
	delete(f.failures)
	delete(f.request)
	delete(f.key)
}

@(test)
test_ws_handshake_exact :: proc(t: ^testing.T) {
	f: Ws_Fake
	c, th, peer, err := ws_setup(&f)
	testing.expect_value(t, err, Error.None)
	want := strings.concatenate(
		{
			"GET /?encoding=etf&v=9&compress=zstd-stream HTTP/1.1\r\n",
			"Host: gateway.discord.gg\r\n",
			"Connection: Upgrade\r\n",
			"Pragma: no-cache\r\n",
			"Cache-Control: no-cache\r\n",
			"User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) discord/0.0.419 Chrome/148.0.7778.280 Electron/42.11.15 Safari/537.36\r\n",
			"Upgrade: websocket\r\n",
			"Origin: https://discord.com\r\n",
			"Sec-WebSocket-Version: 13\r\n",
			"Accept-Encoding: gzip, deflate, br, zstd\r\n",
			"Accept-Language: en-US\r\n",
			"Sec-WebSocket-Key: ",
			f.key,
			"\r\n",
			"Sec-WebSocket-Extensions: permessage-deflate; client_max_window_bits\r\n",
			"\r\n",
		},
		context.temp_allocator,
	)
	testing.expect_value(t, f.request, want)
	testing.expect_value(t, len(f.key), 24) // base64 of 16 random bytes
	ws_teardown(t, &f, c, th, peer)
}

@(test)
test_ws_accept_known_vector :: proc(t: ^testing.T) {
	// RFC 6455 section 1.3
	testing.expect_value(t, ws_accept_for_key("dGhlIHNhbXBsZSBub25jZQ==", context.temp_allocator), "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
}

@(test)
test_ws_handshake_rejects :: proc(t: ^testing.T) {
	for mode in 1 ..= 2 {
		f: Ws_Fake
		c, th, peer, err := ws_setup(&f, mode)
		testing.expect_value(t, err, Error.Handshake)
		ws_teardown(t, &f, c, th, peer)
	}
}

@(private = "file")
script_messages :: proc(f: ^Ws_Fake) {
	// fragmented text with an interleaved ping; then 16-bit and 64-bit lengths
	wf_frame(f, false, 1, transmute([]byte)string("hel"))
	wf_frame(f, false, 0, transmute([]byte)string("lo "))
	wf_frame(f, true, 9, transmute([]byte)string("pp"))
	wf_frame(f, true, 0, transmute([]byte)string("wörld"))
	mid := make([]byte, 300, context.temp_allocator)
	for i in 0 ..< len(mid) do mid[i] = u8(i)
	wf_frame(f, true, 2, mid)
	big := make([]byte, 70000, context.temp_allocator)
	big[69999] = 7
	wf_frame(f, true, 2, big)
	wf_frame(f, true, 2, nil) // empty binary
	// the pong for "pp"
	h, p, err := wf_read(f)
	wf_check(f, err == .None && Ws_Opcode(h.opcode) == .Pong && string(p) == "pp", "pong %v %v", h, err)
	// client message: single frame
	h, p, err = wf_read(f)
	wf_check(f, err == .None && h.fin && h.opcode == 2 && string(p) == "etf-bytes", "single frame %v", h)
	// client fragmented message
	parts := [?]string{"abc", "def", "g"}
	for part, i in parts {
		h, p, err = wf_read(f)
		wf_check(f, err == .None && string(p) == part && h.fin == (i == 2) && h.opcode == (1 if i == 0 else 0), "fragment %d %v", i, h)
	}
	// 126-length client frame
	h, p, err = wf_read(f)
	wf_check(f, err == .None && h.length == 1000 && p[999] == 0xaa, "126-len frame %v", h)
	// close handshake initiated by client
	h, p, err = wf_read(f)
	wf_check(f, Ws_Opcode(h.opcode) == .Close && len(p) >= 2 && int(p[0]) << 8 | int(p[1]) == 4000 && string(p[2:]) == "bye", "close %v %x", h, p)
	wf_frame(f, true, 8, {0x0f, 0xa0, 'o', 'k'})
}

@(test)
test_ws_messages :: proc(t: ^testing.T) {
	f: Ws_Fake
	c, th, peer, err := ws_setup(&f, 0, script_messages)
	testing.expect_value(t, err, Error.None)
	msg := make([dynamic]byte)
	defer delete(msg)
	typ, rerr := ws_recv(c, &msg)
	testing.expect(t, rerr == .None && typ == .Text && string(msg[:]) == "hello wörld", "fragmented text")
	typ, rerr = ws_recv(c, &msg)
	testing.expect(t, rerr == .None && typ == .Binary && len(msg) == 300 && msg[299] == u8(299 & 0xff), "16-bit length")
	typ, rerr = ws_recv(c, &msg)
	testing.expect(t, rerr == .None && len(msg) == 70000 && msg[69999] == 7, "64-bit length")
	typ, rerr = ws_recv(c, &msg)
	testing.expect(t, rerr == .None && typ == .Binary && len(msg) == 0, "empty")
	testing.expect_value(t, ws_send(c, .Binary, transmute([]byte)string("etf-bytes")), Error.None)
	testing.expect_value(t, ws_send_fragmented(c, .Text, transmute([]byte)string("abcdefg"), 3), Error.None)
	k := make([]byte, 1000, context.temp_allocator)
	k[999] = 0xaa
	testing.expect_value(t, ws_send(c, .Binary, k), Error.None)
	testing.expect_value(t, ws_close(c, 4000, "bye"), Error.None)
	testing.expect_value(t, ws_send(c, .Text, nil), Error.Closed)
	_, rerr = ws_recv(c, &msg)
	testing.expect_value(t, rerr, Error.Closed)
	testing.expect_value(t, c.close_code, 4000)
	testing.expect_value(t, c.close_reason, "ok")
	ws_teardown(t, &f, c, th, peer)
}

@(private = "file")
bad_script :: proc(f: ^Ws_Fake) {
	switch f.mode {
	case 10:
		wf_frame(f, true, 2, {1}, mask = true) // masked server frame
	case 11:
		wf_frame(f, true, 2, {1}, rsv = 4) // RSV1 without extension
	case 12:
		wf_frame(f, true, 9, make([]byte, 126, context.temp_allocator)) // control > 125
	case 13:
		wf_frame(f, false, 9, nil) // fragmented control
	case 14:
		wf_frame(f, true, 1, {0xff, 0xfe}) // invalid UTF-8
	case 15:
		wf_frame(f, true, 0, {1}) // continuation without start
	case 16:
		wf_frame(f, false, 1, {'a'})
		wf_frame(f, true, 1, {'b'}) // new message inside a fragmented one
	case 17:
		wf_frame(f, true, 2, make([]byte, 2000, context.temp_allocator)) // > max_message (1000)
	case 18:
		wf_frame(f, true, 3, nil) // reserved opcode
	case 19:
		wf_frame(f, true, 8, {0x03, 0xe8 + 5}) // close code 1005 is not sendable
	}
	h, p, err := wf_read(f)
	want := 1002
	switch f.mode {
	case 14:
		want = 1007
	case 17:
		want = 1009
	}
	wf_check(f, err == .None && Ws_Opcode(h.opcode) == .Close && len(p) >= 2 && int(p[0]) << 8 | int(p[1]) == want, "mode %d: close %x", f.mode, p)
}

@(test)
test_ws_protocol_errors :: proc(t: ^testing.T) {
	for mode in 10 ..= 19 {
		f: Ws_Fake
		c, th, peer, err := ws_setup(&f, mode, bad_script, max_message = 1000)
		testing.expect_value(t, err, Error.None)
		msg := make([dynamic]byte)
		_, rerr := ws_recv(c, &msg)
		testing.expectf(t, rerr == .Protocol || rerr == .Too_Large, "mode %d: %v", mode, rerr)
		delete(msg)
		ws_teardown(t, &f, c, th, peer)
	}
}

@(private = "file")
script_server_close :: proc(f: ^Ws_Fake) {
	wf_frame(f, true, 8, {0x0f, 0xa4, 'r'}) // 4004 "r"
	h, p, _ := wf_read(f)
	wf_check(f, Ws_Opcode(h.opcode) == .Close && len(p) == 2 && p[0] == 0x0f && p[1] == 0xa4, "echoed close %x", p)
}

@(test)
test_ws_server_close :: proc(t: ^testing.T) {
	f: Ws_Fake
	c, th, peer, _ := ws_setup(&f, 0, script_server_close)
	msg := make([dynamic]byte)
	defer delete(msg)
	_, err := ws_recv(c, &msg)
	testing.expect_value(t, err, Error.Closed)
	testing.expect_value(t, c.close_code, 4004)
	testing.expect_value(t, c.close_reason, "r")
	ws_teardown(t, &f, c, th, peer)
}

@(test)
test_ws_mask_and_header_layout :: proc(t: ^testing.T) {
	buf := make([dynamic]byte, context.temp_allocator)
	ws_put_header(&buf, true, .Binary, 125, {1, 2, 3, 4})
	testing.expect_value(t, len(buf), 6)
	testing.expect_value(t, buf[1], 0x80 | 125)
	clear(&buf)
	ws_put_header(&buf, true, .Binary, 126, {})
	testing.expect(t, len(buf) == 8 && buf[1] == 0xfe && buf[2] == 0 && buf[3] == 126)
	clear(&buf)
	ws_put_header(&buf, false, .Text, 65536, {})
	testing.expect(t, len(buf) == 14 && buf[0] == 0x01 && buf[1] == 0xff && buf[7] == 1 && buf[8] == 0)
}

@(private = "file")
script_idle :: proc(f: ^Ws_Fake) {
	buf: [64]byte
	for {
		if _, err := read_some(&f.r, buf[:]); err != .None do return
	}
}

@(test)
test_ws_shutdown_wakes_reader :: proc(t: ^testing.T) {
	f: Ws_Fake
	c, th, peer, _ := ws_setup(&f, 0, script_idle)
	R :: struct {
		c:   ^Ws_Conn,
		err: Error,
	}
	r := R{c = c}
	rt := thread.create_and_start_with_poly_data(&r, proc(r: ^R) {
		msg := make([dynamic]byte)
		_, r.err = ws_recv(r.c, &msg)
		delete(msg)
	})
	thread.yield()
	ws_shutdown(c)
	thread.join(rt)
	thread.destroy(rt)
	testing.expect_value(t, r.err, Error.Closed)
	ws_teardown(t, &f, c, th, peer)
}

// permessage-deflate: two messages from one zlib stream (raw DEFLATE, sync
// flush, 00 00 ff ff stripped; the second refers back into the first), and our
// stored-block encoding read back.
@(test)
test_ws_inflate_context_takeover :: proc(t: ^testing.T) {
	hexb :: proc(s: string) -> []byte {
		out := make([]byte, len(s) / 2, context.temp_allocator)
		for i in 0 ..< len(out) {
			v, _ := strconv.parse_u64_of_base(s[2 * i:][:2], 16)
			out[i] = u8(v)
		}
		return out
	}
	c: Ws_Conn
	c.deflate = true
	c.max_message = 1 << 20
	defer delete(c.history)
	msg := make([dynamic]byte, context.temp_allocator)
	append(&msg, ..hexb("aa56ca2f50b252ca48cdc9c957d201d289452549a98925f1997925a9456589394a56268646a6063a4a2599b9a9f9a525f1b9c54a5686460640500b00"))
	testing.expect(t, ws_inflate(&c, &msg))
	testing.expect_value(t, string(msg[:]), `{"op":"hello","heartbeat_interval":41250,"timeout_ms":120000}`)
	clear(&msg)
	append(&msg, ..hexb("aaa640b38e52627a62669e92554951696a2d00"))
	testing.expect(t, ws_inflate(&c, &msg))
	testing.expect_value(t, string(msg[:]), `{"op":"hello","heartbeat_interval":41250,"timeout_ms":120000,"again":true}`)
	// what we send decodes with the same reader
	d: Ws_Conn
	d.deflate = true
	d.max_message = 1 << 20
	defer delete(d.history)
	clear(&msg)
	append(&msg, ..deflate_stored(transmute([]byte)string(`{"op":"heartbeat"}`)))
	testing.expect(t, ws_inflate(&d, &msg))
	testing.expect_value(t, string(msg[:]), `{"op":"heartbeat"}`)
	ok := ws_accept_deflate(&d, "permessage-deflate; client_max_window_bits=15")
	testing.expect(t, ok)
	testing.expect(t, !ws_accept_deflate(&d, "x-webkit-deflate-frame"))
}
