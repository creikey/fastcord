package http

import "core:bytes"
import "core:c"
import "core:fmt"
import "core:mem"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "fc:netio"

// ---- fake server: raw frames, HPACK by nghttp2's standalone coder ----

when ODIN_OS == .Windows {
	foreign import ng "../../build/fc_nghttp2.obj"
} else {
	foreign import ng "../../build/fc_nghttp2.o"
}

@(private = "file")
Hd :: struct {}

@(private = "file", default_calling_convention = "c")
foreign ng {
	nghttp2_hd_deflate_new :: proc(d: ^^Hd, max_table: c.size_t) -> c.int ---
	nghttp2_hd_deflate_del :: proc(d: ^Hd) ---
	nghttp2_hd_deflate_bound :: proc(d: ^Hd, nva: [^]Ng_Nv, n: c.size_t) -> c.size_t ---
	nghttp2_hd_deflate_hd2 :: proc(d: ^Hd, buf: [^]byte, buflen: c.size_t, nva: [^]Ng_Nv, n: c.size_t) -> int ---
	nghttp2_hd_inflate_new :: proc(i: ^^Hd) -> c.int ---
	nghttp2_hd_inflate_del :: proc(i: ^Hd) ---
	nghttp2_hd_inflate_hd3 :: proc(i: ^Hd, nv: ^Ng_Nv, flags: ^c.int, data: [^]byte, n: c.size_t, final: c.int) -> int ---
	nghttp2_hd_inflate_end_headers :: proc(i: ^Hd) -> c.int ---
}

@(private = "file")
F_DATA :: 0
@(private = "file")
F_HEADERS :: 1
@(private = "file")
F_RST :: 3
@(private = "file")
F_SETTINGS :: 4
@(private = "file")
F_PUSH :: 5
@(private = "file")
F_PING :: 6
@(private = "file")
F_GOAWAY :: 7
@(private = "file")
F_WINDOW :: 8
@(private = "file")
F_CONT :: 9
@(private = "file")
END_STREAM :: 0x1
@(private = "file")
ACK :: 0x1
@(private = "file")
END_HEADERS :: 0x4
@(private = "file")
PADDED :: 0x8
@(private = "file")
PRIORITY :: 0x20

@(private = "file")
Frame :: struct {
	type, flags: u8,
	sid:         u32,
	payload:     []byte,
}

@(private = "file")
Fake :: struct {
	s:        netio.Stream,
	r:        Reader,
	enc, dec: ^Hd,
	failures: [dynamic]string,
	acks:     int, // SETTINGS ACKs seen from client
	user:     rawptr,
	wus:      [dynamic][2]u32, // WINDOW_UPDATEs received from the client (sid, increment)
	alloc:    mem.Allocator,
}

@(private = "file")
fk_init :: proc(f: ^Fake, s: netio.Stream) {
	f.s = s
	f.alloc = context.allocator
	f.failures.allocator = context.allocator
	f.wus.allocator = context.allocator
	reader_init(&f.r, s, 1 << 20)
	nghttp2_hd_deflate_new(&f.enc, 4096)
	nghttp2_hd_inflate_new(&f.dec)
}

@(private = "file")
fk_destroy :: proc(f: ^Fake) {
	reader_destroy(&f.r)
	nghttp2_hd_deflate_del(f.enc)
	nghttp2_hd_inflate_del(f.dec)
	for s in f.failures do delete(s)
	delete(f.failures)
	delete(f.wus)
}

@(private = "file")
fk_check :: proc(f: ^Fake, cond: bool, msg: string, args: ..any, loc := #caller_location) {
	if !cond do append(&f.failures, fmt.aprintf("%v: %s", loc.line, fmt.tprintf(msg, ..args), allocator = f.alloc))
}

@(private = "file")
fk_report :: proc(t: ^testing.T, f: ^Fake) {
	for s in f.failures do testing.expectf(t, false, "server: %s", s)
}

@(private = "file")
be32 :: proc(b: []byte) -> u32 {return u32(b[0]) << 24 | u32(b[1]) << 16 | u32(b[2]) << 8 | u32(b[3])}

@(private = "file")
u32be :: proc(x: u32) -> [4]byte {return {u8(x >> 24), u8(x >> 16), u8(x >> 8), u8(x)}}

// fk_read returns the next frame, counting SETTINGS ACKs and recording WINDOW_UPDATEs.
@(private = "file")
fk_read :: proc(f: ^Fake) -> (fr: Frame, err: Error) {
	for {
		h: [9]byte
		read_exact(&f.r, h[:]) or_return
		fr.type = h[3]
		fr.flags = h[4]
		fr.sid = be32(h[5:]) & 0x7fffffff
		fr.payload = make([]byte, int(h[0]) << 16 | int(h[1]) << 8 | int(h[2]), context.temp_allocator)
		read_exact(&f.r, fr.payload) or_return
		if fr.type == F_SETTINGS && fr.flags & ACK != 0 {
			f.acks += 1
			continue
		}
		if fr.type == F_WINDOW {
			append(&f.wus, [2]u32{fr.sid, be32(fr.payload)})
			continue
		}
		return fr, .None
	}
}

@(private = "file")
fk_write :: proc(f: ^Fake, type, flags: u8, sid: u32, payload: []byte) {
	buf := make([dynamic]byte, 0, len(payload) + 9, context.temp_allocator)
	n := len(payload)
	s := u32be(sid)
	append(&buf, u8(n >> 16), u8(n >> 8), u8(n), type, flags)
	append(&buf, ..s[:])
	append(&buf, ..payload)
	netio.write(f.s, buf[:])
}

// The connection preface Chrome 148 sends (from a netlog of the official client).
@(private = "file")
CHROME_PREFACE_HEX :: "505249202a20485454502f322e300d0a0d0a534d0d0a0d0a" + "000018040000000000" + "000100010000" + "000200000000" + "000400600000" + "000600040000" + "000004080000000000" + "00ef0001"

// fk_handshake checks the exact Chrome preface bytes and sends server settings.
@(private = "file")
fk_handshake :: proc(f: ^Fake, settings: [][2]u32) {
	s := CHROME_PREFACE_HEX
	want := make([]byte, len(s) / 2, context.temp_allocator)
	for i in 0 ..< len(want) {
		hex :: proc(ch: u8) -> u8 {return ch - '0' if ch <= '9' else ch - 'a' + 10}
		want[i] = hex(s[2 * i]) << 4 | hex(s[2 * i + 1])
	}
	got := make([]byte, len(want), context.temp_allocator)
	err := read_exact(&f.r, got)
	fk_check(f, err == .None && bytes.equal(got, want), "preface mismatch: %x", got)
	payload := make([dynamic]byte, context.temp_allocator)
	for s in settings {
		v := u32be(s[1])
		append(&payload, u8(s[0] >> 8), u8(s[0]))
		append(&payload, ..v[:])
	}
	fk_write(f, F_SETTINGS, 0, 0, payload[:])
	fk_write(f, F_SETTINGS, ACK, 0, nil) // nghttp2 applies its own SETTINGS only once ACKed
}

@(private = "file")
Req_In :: struct {
	sid:    u32,
	flags:  u8,
	fields: [dynamic]Header,
	path:   string,
}

// fk_read_request reads HEADERS (+CONTINUATION) and decodes it.
@(private = "file")
fk_read_request :: proc(f: ^Fake) -> (req: Req_In, err: Error) {
	fr := fk_read(f) or_return
	fk_check(f, fr.type == F_HEADERS, "expected HEADERS got %v", fr.type)
	req.sid = fr.sid
	req.flags = fr.flags
	block := make([dynamic]byte, context.temp_allocator)
	append(&block, ..fr.payload)
	for flags := fr.flags; flags & END_HEADERS == 0; {
		cf := fk_read(f) or_return
		fk_check(f, cf.type == F_CONT, "expected CONTINUATION")
		append(&block, ..cf.payload)
		flags = cf.flags
	}
	req.fields = make([dynamic]Header, context.temp_allocator)
	p := block[:]
	for {
		nv: Ng_Nv
		fl: c.int
		n := nghttp2_hd_inflate_hd3(f.dec, &nv, &fl, raw_data(p), len(p), 1)
		if n < 0 {
			fk_check(f, false, "hpack decode %d", n)
			return req, .Protocol
		}
		p = p[n:]
		if fl & 2 != 0 {
			h := Header{strings.clone(string(nv.name[:nv.namelen]), context.temp_allocator), strings.clone(string(nv.value[:nv.valuelen]), context.temp_allocator)}
			append(&req.fields, h)
			if h.name == ":path" do req.path = h.value
		}
		if fl & 1 != 0 do break
	}
	nghttp2_hd_inflate_end_headers(f.dec)
	return req, .None
}

// fk_send_headers sends a header block split into pieces of `frag` bytes.
@(private = "file")
fk_send_headers :: proc(f: ^Fake, sid: u32, fields: []Header, end_stream: bool, frag := 1 << 20, pad := 0) {
	nva := make([]Ng_Nv, len(fields), context.temp_allocator)
	for h, i in fields do nva[i] = {raw_data(h.name), raw_data(h.value), len(h.name), len(h.value), 0}
	block := make([]byte, nghttp2_hd_deflate_bound(f.enc, raw_data(nva), len(nva)), context.temp_allocator)
	n := nghttp2_hd_deflate_hd2(f.enc, raw_data(block), len(block), raw_data(nva), len(nva))
	fk_check(f, n >= 0, "hpack encode %d", n)
	rest := block[:max(n, 0)]
	for first := true; ; first = false {
		k := min(len(rest), frag)
		last := k == len(rest)
		flags: u8 = 0
		if last do flags |= END_HEADERS
		if first && end_stream do flags |= END_STREAM
		payload := make([dynamic]byte, context.temp_allocator)
		if first && pad > 0 {
			flags |= PADDED
			append(&payload, u8(pad))
		}
		append(&payload, ..rest[:k])
		if first do for _ in 0 ..< pad do append(&payload, 0)
		fk_write(f, F_HEADERS if first else F_CONT, flags, sid, payload[:])
		rest = rest[k:]
		if last do break
	}
}

@(private = "file")
fk_send_data :: proc(f: ^Fake, sid: u32, data: []byte, end_stream: bool, pad := 0) {
	payload := make([dynamic]byte, context.temp_allocator)
	flags: u8 = END_STREAM if end_stream else 0
	if pad > 0 {
		flags |= PADDED
		append(&payload, u8(pad))
	}
	append(&payload, ..data)
	for _ in 0 ..< pad do append(&payload, 0)
	fk_write(f, F_DATA, flags, sid, payload[:])
}

@(private = "file")
fields_str :: proc(fields: []Header) -> string {
	sb := strings.builder_make(context.temp_allocator)
	for h in fields do fmt.sbprintf(&sb, "%s: %s|", h.name, h.value)
	return strings.to_string(sb)
}

@(private = "file")
run_server :: proc(f: ^Fake, body: proc(f: ^Fake)) -> ^thread.Thread {
	return thread.create_and_start_with_poly_data2(f, body, proc(f: ^Fake, body: proc(f: ^Fake)) {
		body(f)
		free_all(context.temp_allocator)
	})
}

@(private = "file")
fk_finish :: proc(t: ^testing.T, f: ^Fake, th: ^thread.Thread, peer: netio.Stream) {
	thread.join(th)
	thread.destroy(th)
	fk_report(t, f)
	netio.close(peer)
}

@(private = "file")
CF_SETTINGS := [][2]u32{{3, 100}, {4, 65536}, {5, 16777215}}

@(private = "file")
UA :: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) discord/0.0.419 Chrome/148.0.7778.280 Electron/42.11.15 Safari/537.36"

@(private = "file")
BASIC_HEADERS := []Header{{"user-agent", UA}, {"accept", "*/*"}, {"priority", "u=1, i"}}

@(private = "file")
basic_req :: proc(path: string, body: []byte = nil) -> Request {
	return {method = "GET" if body == nil else "POST", scheme = "https", authority = "discord.com", path = path, headers = BASIC_HEADERS, body = body}
}

// ---- tests ----

@(private = "file")
basic_server :: proc(f: ^Fake) {
	fk_handshake(f, CF_SETTINGS)
	fk_write(f, F_WINDOW, 0, 0, {0x7f, 0xff, 0, 0})
	req, err := fk_read_request(f)
	fk_check(f, err == .None, "read req")
	fk_check(f, req.sid == 1 && req.flags == END_STREAM | END_HEADERS, "sid/flags %d %x", req.sid, req.flags)
	want := ":method: GET|:authority: discord.com|:scheme: https|:path: /api/v9/a|user-agent: " + UA + "|accept: */*|priority: u=1, i|"
	fk_check(f, fields_str(req.fields[:]) == want, "fields %s", fields_str(req.fields[:]))
	// response: 103 interim, then headers split over HEADERS+2xCONTINUATION with padding
	fk_send_headers(f, 1, {{":status", "103"}, {"link", "</x>"}}, false)
	fk_send_headers(f, 1, {{":status", "200"}, {"content-type", "application/json"}, {"x-long", strings.repeat("v", 300, context.temp_allocator)}}, false, frag = 100, pad = 7)
	fk_send_data(f, 1, transmute([]byte)string("hello "), false, pad = 10)
	fk_send_data(f, 1, transmute([]byte)string("world"), false)
	fk_send_data(f, 1, nil, false)
	fk_send_headers(f, 1, {{"x-trailer", "done"}}, true)

	req2, err2 := fk_read_request(f)
	fk_check(f, err2 == .None && req2.sid == 3 && req2.path == "/api/v9/b", "req2")
	fk_check(f, f.acks == 1, "client must ACK our SETTINGS (acks=%d)", f.acks)
	fk_send_headers(f, 3, {{":status", "204"}}, true)
	fr, _ := fk_read(f)
	fk_check(f, fr.type == F_GOAWAY && be32(fr.payload[4:]) == 0, "goaway on close: %v", fr.type)
}

@(test)
test_h2_basic :: proc(t: ^testing.T) {
	a, b := pipe_make()
	f: Fake
	fk_init(&f, b)
	defer fk_destroy(&f)
	th := run_server(&f, basic_server)
	c, err := h2_connect(a)
	testing.expect_value(t, err, Error.None)
	resp, rerr := h2_request(c, basic_req("/api/v9/a"))
	testing.expect_value(t, rerr, Error.None)
	testing.expect_value(t, resp.status, 200)
	testing.expect_value(t, resp.version, Version.Http2)
	testing.expect_value(t, string(resp.body[:]), "hello world")
	testing.expect_value(t, len(resp.headers), 2)
	if len(resp.headers) == 2 do testing.expect_value(t, resp.headers[0].value, "application/json")
	testing.expect_value(t, len(resp.trailers), 1)
	if len(resp.trailers) == 1 do testing.expect_value(t, resp.trailers[0].value, "done")
	response_destroy(&resp)
	r2, e2 := h2_request(c, basic_req("/api/v9/b"))
	testing.expect_value(t, e2, Error.None)
	testing.expect_value(t, r2.status, 204)
	response_destroy(&r2)
	h2_close(c)
	fk_finish(t, &f, th, b)
}

// Many threads on one connection, answered out of order.
@(private = "file")
multi_server :: proc(f: ^Fake) {
	fk_handshake(f, CF_SETTINGS)
	pending: [dynamic]Req_In
	pending.allocator = context.temp_allocator
	for served := 0; served < 16; {
		r, err := fk_read_request(f)
		if err != .None {
			fk_check(f, false, "read %v", err)
			return
		}
		append(&pending, r)
		if len(pending) == 2 || served + len(pending) == 16 {
			for j := len(pending) - 1; j >= 0; j -= 1 {
				p := pending[j]
				fk_send_headers(f, p.sid, {{":status", "200"}}, false)
				fk_send_data(f, p.sid, transmute([]byte)p.path, true)
			}
			served += len(pending)
			clear(&pending)
		}
	}
}

@(private = "file")
Worker :: struct {
	c:    ^H2_Conn,
	path: string,
	ok:   bool,
}

@(test)
test_h2_multiplex :: proc(t: ^testing.T) {
	a, b := pipe_make()
	f: Fake
	fk_init(&f, b)
	defer fk_destroy(&f)
	th := run_server(&f, multi_server)
	c, _ := h2_connect(a)
	workers: [16]Worker
	threads: [16]^thread.Thread
	for i in 0 ..< 16 {
		workers[i] = {c = c, path = fmt.aprintf("/w/%d", i)}
		threads[i] = thread.create_and_start_with_poly_data(&workers[i], proc(w: ^Worker) {
			resp, err := h2_request(w.c, basic_req(w.path))
			w.ok = err == .None && resp.status == 200 && string(resp.body[:]) == w.path
			response_destroy(&resp)
			free_all(context.temp_allocator)
		})
	}
	for i in 0 ..< 16 {
		thread.join(threads[i])
		thread.destroy(threads[i])
		testing.expectf(t, workers[i].ok, "worker %d", i)
		delete(workers[i].path)
	}
	h2_close(c)
	fk_finish(t, &f, th, b)
}

// Send-side flow control: tiny stream window, connection window exhaustion, DATA chunking.
@(private = "file")
flow_send_server :: proc(f: ^Fake) {
	fk_handshake(f, {{4, 1000}})
	// A client may legally send with the default 65535 window before it has
	// processed our SETTINGS (Chrome does), so warm up with one GET first.
	warm, _ := fk_read_request(f)
	fk_send_headers(f, warm.sid, {{":status", "204"}}, true)
	req, _ := fk_read_request(f)
	sid := req.sid
	fk_check(f, req.flags & END_STREAM == 0, "POST must not end stream in HEADERS")
	granted := 1000
	conn_granted := 65535
	got := 0
	stream_total := 80000
	for got < stream_total {
		fr, err := fk_read(f)
		if err != .None {
			fk_check(f, false, "read err %v after %d", err, got)
			return
		}
		fk_check(f, fr.type == F_DATA && fr.sid == sid, "frame %v", fr.type)
		fk_check(f, len(fr.payload) <= CHROME_DATA_CHUNK, "chunk %d > 2851", len(fr.payload))
		got += len(fr.payload)
		fk_check(f, got <= granted && got <= conn_granted, "window violated: got %d granted %d conn %d", got, granted, conn_granted)
		if got == stream_total {
			fk_check(f, fr.flags & END_STREAM != 0, "last DATA must END_STREAM")
			break
		}
		if got == granted {
			inc := u32(min(30000, stream_total - granted))
			granted += int(inc)
			b := u32be(inc)
			fk_write(f, F_WINDOW, 0, sid, b[:])
		}
		if got == conn_granted {
			conn_granted += 20000
			b := u32be(20000)
			fk_write(f, F_WINDOW, 0, 0, b[:])
		}
	}
	fk_send_headers(f, sid, {{":status", "200"}}, true)
}

@(test)
test_h2_flow_control_send :: proc(t: ^testing.T) {
	a, b := pipe_make()
	f: Fake
	fk_init(&f, b)
	defer fk_destroy(&f)
	th := run_server(&f, flow_send_server)
	c, _ := h2_connect(a)
	body := make([]byte, 80000)
	defer delete(body)
	for i in 0 ..< len(body) do body[i] = u8(i)
	warm, _ := h2_request(c, basic_req("/warm"))
	response_destroy(&warm)
	resp, err := h2_request(c, basic_req("/upload", body))
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, resp.status, 200)
	response_destroy(&resp)
	h2_close(c)
	fk_finish(t, &f, th, b)
}

// Receive side: WINDOW_UPDATE once half the window is consumed.
@(private = "file")
flow_recv_server :: proc(f: ^Fake) {
	fk_handshake(f, nil)
	chunk := make([]byte, 16384, context.temp_allocator)
	total := 5_000_000
	for sid in ([]u32{1, 3}) {
		_, _ = fk_read_request(f)
		fk_send_headers(f, sid, {{":status", "200"}}, false)
		for sent := 0; sent < total; {
			n := min(16384, total - sent)
			fk_send_data(f, sid, chunk[:n], sent + n == total)
			sent += n
		}
	}
	// Drain until the GOAWAY sent by h2_close; fk_read records WINDOW_UPDATEs.
	for {
		fr, err := fk_read(f)
		if err != .None || fr.type == F_GOAWAY do break
	}
	// stream: >= 3145728 unacked (half of 6291456) -> 192 frames of 16384
	// conn: >= 7864320 unacked (half of 15728640); nghttp2 counts partly read
	// frames, so the exact amount depends on read boundaries.
	want := [][2]u32{{1, 192 * 16384}, {0, 7864320}, {3, 192 * 16384}}
	fk_check(f, len(f.wus) == len(want), "updates %v", f.wus[:])
	for w, i in want {
		if i >= len(f.wus) do break
		got := f.wus[i]
		fk_check(f, got[0] == w[0] && got[1] >= w[1] && got[1] < w[1] + 16384, "update %d: %v want %v", i, got, w)
	}
}

@(test)
test_h2_flow_control_recv :: proc(t: ^testing.T) {
	a, b := pipe_make()
	f: Fake
	fk_init(&f, b)
	defer fk_destroy(&f)
	th := run_server(&f, flow_recv_server)
	c, _ := h2_connect(a)
	for path in ([]string{"/big1", "/big2"}) {
		r, e := h2_request(c, basic_req(path))
		testing.expect_value(t, e, Error.None)
		testing.expect_value(t, len(r.body), 5_000_000)
		response_destroy(&r)
	}
	h2_close(c)
	fk_finish(t, &f, th, b)
}

// RST_STREAM, server PING, GOAWAY semantics.
@(private = "file")
control_server :: proc(f: ^Fake) {
	fk_handshake(f, nil)
	r1, _ := fk_read_request(f)
	fk_write(f, F_PING, 0, 0, {1, 2, 3, 4, 5, 6, 7, 8})
	for {
		fr, err := fk_read(f)
		if err != .None do return
		if fr.type == F_PING {
			fk_check(f, fr.flags == ACK && bytes.equal(fr.payload, []byte{1, 2, 3, 4, 5, 6, 7, 8}), "ping ack")
			break
		}
	}
	rst := u32be(7) // REFUSED_STREAM
	fk_write(f, F_RST, 0, r1.sid, rst[:])
	r3, _ := fk_read_request(f)
	rst2 := u32be(2) // INTERNAL_ERROR
	fk_send_headers(f, r3.sid, {{":status", "200"}}, false)
	fk_write(f, F_RST, 0, r3.sid, rst2[:])
	// two streams then GOAWAY naming the first
	ra, _ := fk_read_request(f)
	rb, _ := fk_read_request(f)
	fk_check(f, ra.sid == 5 && rb.sid == 7, "ids %d %d", ra.sid, rb.sid)
	ga: [8]byte
	l := u32be(5)
	copy(ga[:], l[:])
	fk_write(f, F_GOAWAY, 0, 0, ga[:])
	fk_send_headers(f, 5, {{":status", "200"}}, true)
	for {
		if _, err := fk_read(f); err != .None do return
	}
}

@(test)
test_h2_control :: proc(t: ^testing.T) {
	a, b := pipe_make()
	f: Fake
	fk_init(&f, b)
	defer fk_destroy(&f)
	th := run_server(&f, control_server)
	c, _ := h2_connect(a)
	r1, e1 := h2_request(c, basic_req("/refused"))
	testing.expect_value(t, e1, Error.Refused)
	testing.expect_value(t, r1.h2_error, 7)
	r3, e3 := h2_request(c, basic_req("/reset"))
	testing.expect_value(t, e3, Error.Stream_Reset)
	testing.expect_value(t, r3.h2_error, 2)
	ws: [2]Worker
	ths: [2]^thread.Thread
	for i in 0 ..< 2 {
		ws[i] = {c = c, path = "/5" if i == 0 else "/7"}
		ths[i] = thread.create_and_start_with_poly_data(&ws[i], proc(w: ^Worker) {
			resp, err := h2_request(w.c, basic_req(w.path))
			w.ok = err == .None && resp.status == 200
			if err != .None do w.ok = false
			response_destroy(&resp)
		})
	}
	oks := 0
	for i in 0 ..< 2 {
		thread.join(ths[i])
		thread.destroy(ths[i])
		if ws[i].ok do oks += 1
	}
	testing.expect_value(t, oks, 1) // stream 5 answered, stream 7 refused by GOAWAY
	_, eg := h2_request(c, basic_req("/after"))
	testing.expect_value(t, eg, Error.Goaway)
	testing.expect(t, !h2_can_open(c))
	h2_close(c)
	fk_finish(t, &f, th, b)
}

// A body over the cap fails the request with Too_Large and cancels the stream.
@(private = "file")
cap_server :: proc(f: ^Fake) {
	fk_handshake(f, nil)
	r, _ := fk_read_request(f)
	fk_send_headers(f, r.sid, {{":status", "200"}}, false)
	fk_send_data(f, r.sid, make([]byte, 20, context.temp_allocator), false)
	fr, _ := fk_read(f)
	fk_check(f, fr.type == F_RST && fr.sid == r.sid && be32(fr.payload) == 8, "want RST_STREAM CANCEL, got %v %x", fr.type, fr.payload)
}

@(test)
test_h2_body_cap :: proc(t: ^testing.T) {
	a, b := pipe_make()
	f: Fake
	fk_init(&f, b)
	defer fk_destroy(&f)
	th := run_server(&f, cap_server)
	c, _ := h2_connect(a, {max_response_body = 10})
	_, err := h2_request(c, basic_req("/big"))
	testing.expect_value(t, err, Error.Too_Large)
	thread.join(th)
	thread.destroy(th)
	h2_close(c)
	fk_report(t, &f)
	netio.close(b)
}

@(private = "file")
Proto_Case :: struct {
	f:    Fake,
	kind: int,
}

// Peer protocol violations -> GOAWAY with the right code, request fails.
@(private = "file")
proto_server :: proc(f: ^Fake) {
	pc := cast(^Proto_Case)f.user
	fk_handshake(f, nil)
	req, _ := fk_read_request(f)
	want: u32 = 1 // PROTOCOL_ERROR
	switch pc.kind {
	case 0:
		fk_send_data(f, 0, {1}, false) // DATA on stream 0
	case 1:
		// HEADERS without END_HEADERS followed by a non-CONTINUATION frame
		fk_write(f, F_HEADERS, 0, req.sid, {0x88})
		fk_write(f, F_PING, 0, 0, {0, 0, 0, 0, 0, 0, 0, 0})
	case 2:
		fk_write(f, F_PUSH, END_HEADERS, req.sid, {0, 0, 0, 2, 0x88}) // push is disabled
	case 3:
		fk_write(f, F_HEADERS, END_HEADERS, req.sid, {0xff, 0xff, 0xff, 0xff, 0x7f}) // bad HPACK
		want = 9 // COMPRESSION_ERROR
	case 4:
		fk_write(f, F_DATA, 0, 0, make([]byte, 20000, context.temp_allocator)) // > max frame
		want = 6 // FRAME_SIZE_ERROR
	case 5:
		inc := u32be(0x7fffffff)
		fk_write(f, F_WINDOW, 0, 0, inc[:]) // overflows the connection send window
		want = 3 // FLOW_CONTROL_ERROR
	case 6:
		fk_write(f, F_HEADERS, END_HEADERS, 2, {0x88}) // even stream id
	}
	for {
		fr, err := fk_read(f)
		if err != .None {
			fk_check(f, false, "kind %d: no GOAWAY", pc.kind)
			return
		}
		if fr.type == F_GOAWAY {
			fk_check(f, be32(fr.payload[4:]) == want, "kind %d: code %d", pc.kind, be32(fr.payload[4:]))
			return
		}
	}
}

@(test)
test_h2_protocol_errors :: proc(t: ^testing.T) {
	for kind in 0 ..< 7 {
		a, b := pipe_make()
		pc := new(Proto_Case)
		pc.kind = kind
		pc.f.user = pc
		fk_init(&pc.f, b)
		th := run_server(&pc.f, proto_server)
		c, _ := h2_connect(a)
		_, err := h2_request(c, basic_req("/x"))
		testing.expectf(t, err != .None, "kind %d should fail", kind)
		thread.join(th)
		thread.destroy(th)
		h2_close(c)
		fk_report(t, &pc.f)
		fk_destroy(&pc.f)
		free(pc)
		netio.close(b)
	}
}

@(test)
test_h2_bad_requests :: proc(t: ^testing.T) {
	a, b := pipe_make()
	c, _ := h2_connect(a)
	bad := []Request {
		{method = "GET", scheme = "https", authority = "x", path = "/", headers = {{"Upper", "x"}}},
		{method = "GET", scheme = "https", authority = "x", path = "/", headers = {{"connection", "keep-alive"}}},
		{method = "GET", scheme = "https", authority = "x", path = "/", headers = {{":path", "/"}}},
		{method = "GET", scheme = "https", authority = "x", path = "/", headers = {{"x", "a\r\nb"}}},
		{method = "GET", scheme = "https", authority = "x", path = ""},
	}
	for r in bad {
		_, err := h2_request(c, r)
		testing.expect_value(t, err, Error.Bad_Request)
	}
	h2_close(c)
	netio.close(b)
}

// h2_close from another thread while a reader is blocked: must wake it and not crash.
@(private = "file")
idle_server :: proc(f: ^Fake) {
	fk_handshake(f, nil)
	for {
		if _, err := fk_read(f); err != .None do return
	}
}

@(test)
test_h2_close_while_reading :: proc(t: ^testing.T) {
	a, b := pipe_make(read_timeout = 0)
	f: Fake
	fk_init(&f, b)
	defer fk_destroy(&f)
	th := run_server(&f, idle_server)
	c, _ := h2_connect(a)
	Svc :: struct {
		c:   ^H2_Conn,
		err: Error,
	}
	svc := Svc{c = c}
	st := thread.create_and_start_with_poly_data(&svc, proc(s: ^Svc) {s.err = h2_service(s.c)})
	for i := 0; i < 1000; i += 1 {
		if sync.atomic_load(&c.reading) do break
		thread.yield()
	}
	h2_close(c)
	thread.join(st)
	thread.destroy(st)
	testing.expect_value(t, svc.err, Error.Closed)
	netio.close(b)
	thread.join(th)
	thread.destroy(th)
}
