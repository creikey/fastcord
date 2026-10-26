package http

import "core:bytes"
import "core:fmt"
import "core:mem"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "fc:netio"

// ---- fake server ----

@(private = "file")
Frame :: struct {
	type:    Frame_Type,
	flags:   u8,
	sid:     u32,
	payload: []byte,
}

@(private = "file")
Fake :: struct {
	s:        netio.Stream,
	r:        Reader,
	enc:      Hpack_Encoder,
	dec:      Hpack_Decoder,
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
	hpack_encoder_init(&f.enc)
	f.enc.policy = proc(n, v: string) -> bool {return true}
	hpack_decoder_init(&f.dec, 65536)
}

@(private = "file")
fk_destroy :: proc(f: ^Fake) {
	reader_destroy(&f.r)
	hpack_encoder_destroy(&f.enc)
	hpack_decoder_destroy(&f.dec)
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

// fk_read returns the next frame, transparently counting SETTINGS ACKs.
@(private = "file")
fk_read :: proc(f: ^Fake) -> (fr: Frame, err: Error) {
	for {
		h := peek_exact(&f.r, 9) or_return
		length := int(h[0]) << 16 | int(h[1]) << 8 | int(h[2])
		fr.type = Frame_Type(h[3])
		fr.flags = h[4]
		fr.sid = be32(h[5:]) & 0x7fffffff
		consume(&f.r, 9)
		fr.payload = make([]byte, length, context.temp_allocator)
		read_exact(&f.r, fr.payload) or_return
		if fr.type == .Settings && fr.flags & FLAG_ACK != 0 {
			f.acks += 1
			continue
		}
		if fr.type == .Window_Update {
			append(&f.wus, [2]u32{fr.sid, be32(fr.payload)})
			continue
		}
		return fr, .None
	}
}

@(private = "file")
fk_write :: proc(f: ^Fake, type: Frame_Type, flags: u8, sid: u32, payload: []byte) {
	buf := make([dynamic]byte, 0, len(payload) + 9, context.temp_allocator)
	put_frame_header(&buf, len(payload), type, flags, sid)
	append(&buf, ..payload)
	netio.write(f.s, buf[:])
}

@(private = "file")
u32be :: proc(x: u32) -> [4]byte {return {u8(x >> 24), u8(x >> 16), u8(x >> 8), u8(x)}}

@(private = "file")
CHROME_PREFACE_HEX :: "505249202a20485454502f322e300d0a0d0a534d0d0a0d0a" + "000018040000000000" + "000100010000" + "000200000000" + "000400600000" + "000600040000" + "000004080000000000" + "00ef0001"

// fk_handshake checks the exact Chrome preface bytes and sends server settings.
@(private = "file")
fk_handshake :: proc(f: ^Fake, settings: []Setting) {
	want := dehex_f(CHROME_PREFACE_HEX)
	got, err := peek_exact(&f.r, len(want))
	fk_check(f, err == .None && bytes.equal(got, want), "preface mismatch: %x", got)
	consume(&f.r, len(want))
	payload := make([dynamic]byte, context.temp_allocator)
	for s in settings {
		append(&payload, u8(s.id >> 8), u8(s.id))
		v := u32be(s.value)
		append(&payload, ..v[:])
	}
	fk_write(f, .Settings, 0, 0, payload[:])
}

@(private = "file")
dehex_f :: proc(s: string) -> []byte {
	out := make([]byte, len(s) / 2, context.temp_allocator)
	for i in 0 ..< len(out) do out[i] = u8(hexval(s[2 * i]) << 4 | hexval(s[2 * i + 1]))
	return out
}

@(private = "file")
Req_In :: struct {
	sid:      u32,
	flags:    u8,
	exclusive: bool,
	parent:   u32,
	weight:   int,
	fields:   [dynamic]Header,
	block:    []byte,
}

// fk_read_request reads HEADERS (+CONTINUATION) and decodes it.
@(private = "file")
fk_read_request :: proc(f: ^Fake) -> (req: Req_In, err: Error) {
	fr := fk_read(f) or_return
	fk_check(f, fr.type == .Headers, "expected HEADERS got %v", fr.type)
	req.sid = fr.sid
	req.flags = fr.flags
	p := fr.payload
	if fr.flags & FLAG_PRIORITY != 0 {
		dep := be32(p)
		req.exclusive = dep & 0x80000000 != 0
		req.parent = dep & 0x7fffffff
		req.weight = int(p[4]) + 1
		p = p[5:]
	}
	block := make([dynamic]byte, context.temp_allocator)
	append(&block, ..p)
	flags := fr.flags
	for flags & FLAG_END_HEADERS == 0 {
		c := fk_read(f) or_return
		fk_check(f, c.type == .Continuation, "expected CONTINUATION")
		append(&block, ..c.payload)
		flags = c.flags
	}
	req.block = block[:]
	req.fields = make([dynamic]Header, context.temp_allocator)
	derr := hpack_decode(&f.dec, block[:], &req.fields, context.temp_allocator)
	fk_check(f, derr == .None, "hpack decode %v", derr)
	return req, .None
}

// fk_send_headers sends a header block split into pieces of `frag` bytes.
@(private = "file")
fk_send_headers :: proc(f: ^Fake, sid: u32, fields: []Header, end_stream: bool, frag := 1 << 20, pad := 0) {
	block := make([dynamic]byte, context.temp_allocator)
	hpack_encode(&f.enc, fields, &block)
	rest := block[:]
	first := true
	for {
		n := min(len(rest), frag)
		last := n == len(rest)
		flags: u8 = 0
		if last do flags |= FLAG_END_HEADERS
		if first && end_stream do flags |= FLAG_END_STREAM
		payload := make([dynamic]byte, context.temp_allocator)
		if first && pad > 0 {
			flags |= FLAG_PADDED
			append(&payload, u8(pad))
		}
		append(&payload, ..rest[:n])
		if first && pad > 0 do for _ in 0 ..< pad do append(&payload, 0)
		fk_write(f, .Headers if first else .Continuation, flags, sid, payload[:])
		rest = rest[n:]
		first = false
		if last do break
	}
}

@(private = "file")
fk_send_data :: proc(f: ^Fake, sid: u32, data: []byte, end_stream: bool, pad := 0) {
	payload := make([dynamic]byte, context.temp_allocator)
	flags: u8 = FLAG_END_STREAM if end_stream else 0
	if pad > 0 {
		flags |= FLAG_PADDED
		append(&payload, u8(pad))
	}
	append(&payload, ..data)
	for _ in 0 ..< pad do append(&payload, 0)
	fk_write(f, .Data, flags, sid, payload[:])
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
CF_SETTINGS := []Setting{{SETTINGS_MAX_CONCURRENT_STREAMS, 100}, {SETTINGS_INITIAL_WINDOW_SIZE, 65536}, {SETTINGS_MAX_FRAME_SIZE, 16777215}}

@(private = "file")
UA :: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) discord/0.0.419 Chrome/148.0.7778.280 Electron/42.11.15 Safari/537.36"

@(private = "file")
BASIC_HEADERS := []Header{{"user-agent", UA}, {"accept", "*/*"}, {"priority", "u=1, i"}}

@(private = "file")
basic_req :: proc(path: string, priority := Priority.Medium, body: []byte = nil) -> Request {
	return {
		method = "GET" if body == nil else "POST",
		scheme = "https",
		authority = "discord.com",
		path = path,
		headers = BASIC_HEADERS,
		body = body,
		priority = priority,
	}
}

// ---- tests ----

@(test)
test_h2_frame_header :: proc(t: ^testing.T) {
	buf := make([dynamic]byte, context.temp_allocator)
	put_frame_header(&buf, 0x123456, .Headers, 0x25, 0x80000007)
	testing.expect(t, bytes.equal(buf[:], []byte{0x12, 0x34, 0x56, 0x01, 0x25, 0, 0, 0, 7}), "frame header layout (R bit cleared)")
	testing.expect_value(t, chrome_weight(0), 256)
	testing.expect_value(t, chrome_weight(1), 220)
	testing.expect_value(t, chrome_weight(2), 183)
	testing.expect_value(t, chrome_weight(3), 147)
	testing.expect_value(t, chrome_weight(4), 110)
	testing.expect_value(t, chrome_weight(5), 74)
}

@(private = "file")
basic_server :: proc(f: ^Fake) {
	fk_handshake(f, CF_SETTINGS)
	fk_write(f, .Window_Update, 0, 0, {0x7f, 0xff, 0, 0})
	req, err := fk_read_request(f)
	fk_check(f, err == .None, "read req")
	fk_check(f, req.sid == 1 && req.flags == 0x25, "sid/flags %d %x", req.sid, req.flags)
	fk_check(f, req.exclusive && req.parent == 0 && req.weight == 220, "priority %v %d %d", req.exclusive, req.parent, req.weight)
	want := ":method: GET|:authority: discord.com|:scheme: https|:path: /api/v9/a|user-agent: " + UA + "|accept: */*|priority: u=1, i|"
	fk_check(f, fields_str(req.fields[:]) == want, "fields %s", fields_str(req.fields[:]))
	// response: 103 interim, then headers split over HEADERS+2xCONTINUATION with padding
	fk_send_headers(f, 1, {{":status", "103"}, {"link", "</x>"}}, false)
	fk_send_headers(f, 1, {{":status", "200"}, {"content-type", "application/json"}, {"x-long", strings.repeat("v", 300, context.temp_allocator)}}, false, frag = 100, pad = 7)
	fk_send_data(f, 1, transmute([]byte)string("hello "), false, pad = 10)
	fk_send_data(f, 1, transmute([]byte)string("world"), false)
	fk_send_data(f, 1, nil, false)
	fk_send_headers(f, 1, {{"x-trailer", "done"}}, true)

	// second request: HPACK must reuse the dynamic table (Chrome indexing)
	req2, err2 := fk_read_request(f)
	fk_check(f, err2 == .None && req2.sid == 3, "req2")
	// :method GET(82) :authority(dyn) :scheme https(87) :path literal-no-index(04..) then 3 dyn-indexed
	fk_check(f, req2.block[0] == 0x82 && req2.block[1] >= 0xbe && req2.block[2] == 0x87 && req2.block[3] == 0x04, "block2 %x", req2.block)
	fk_check(f, len(req2.block) < 20, "block2 should be tiny: %d", len(req2.block))
	fk_check(f, f.acks == 1, "client must ACK our SETTINGS (acks=%d)", f.acks)
	fk_send_headers(f, 3, {{":status", "204"}}, true)
	// expect GOAWAY on close
	fr, _ := fk_read(f)
	fk_check(f, fr.type == .Goaway && be32(fr.payload[4:]) == 0, "goaway on close: %v", fr.type)
}

@(test)
test_h2_basic :: proc(t: ^testing.T) {
	a, b := pipe_make()
	f: Fake
	fk_init(&f, b)
	defer fk_destroy(&f)
	th := run_server(&f, basic_server)
	c, err := h2_connect(a, {goaway_on_close = true})
	testing.expect_value(t, err, Error.None)
	resp, rerr := h2_request(c, basic_req("/api/v9/a"))
	testing.expect_value(t, rerr, Error.None)
	testing.expect_value(t, resp.status, 200)
	testing.expect_value(t, resp.version, Version.Http2)
	testing.expect_value(t, string(resp.body[:]), "hello world")
	testing.expect_value(t, len(resp.headers), 2)
	testing.expect_value(t, resp.headers[0].value, "application/json")
	testing.expect_value(t, len(resp.trailers), 1)
	if len(resp.trailers) == 1 do testing.expect_value(t, resp.trailers[0].value, "done")
	response_destroy(&resp)
	r2, e2 := h2_request(c, basic_req("/api/v9/b"))
	testing.expect_value(t, e2, Error.None)
	testing.expect_value(t, r2.status, 204)
	response_destroy(&r2)
	testing.expect_value(t, c.peer_max_concurrent, 100)
	testing.expect_value(t, c.peer_max_frame, 16777215)
	h2_close(c)
	thread.join(th)
	thread.destroy(th)
	fk_report(t, &f)
	netio.close(b)
}

// Out-of-order responses, Chrome priority dependency chain, and many threads at once.
@(private = "file")
multi_server :: proc(f: ^Fake) {
	fk_handshake(f, CF_SETTINGS)
	reqs: [3]Req_In
	for i in 0 ..< 3 do reqs[i], _ = fk_read_request(f)
	fk_check(f, reqs[0].sid == 1 && reqs[0].parent == 0 && reqs[0].weight == 220, "s1 %v", reqs[0])
	fk_check(f, reqs[1].sid == 3 && reqs[1].parent == 0 && reqs[1].weight == 256, "s3 parent %d w %d", reqs[1].parent, reqs[1].weight)
	fk_check(f, reqs[2].sid == 5 && reqs[2].parent == 1 && reqs[2].weight == 220, "s5 parent %d", reqs[2].parent)
	fk_check(f, reqs[2].flags & FLAG_END_STREAM == 0, "s5 has a body")
	// s5's body
	d, _ := fk_read(f)
	fk_check(f, d.type == .Data && d.sid == 5 && d.flags & FLAG_END_STREAM != 0 && string(d.payload) == "payload", "s5 data")
	for i := 2; i >= 0; i -= 1 {
		sid := reqs[i].sid
		fk_send_headers(f, sid, {{":status", "200"}}, false)
		fk_send_data(f, sid, transmute([]byte)fmt.tprintf("r%d", sid), true)
	}
	// concurrent phase: echo the path of each request, answering two at a time in reverse
	pending: [dynamic]Req_In
	pending.allocator = context.temp_allocator
	served := 0
	for served < 16 {
		r, err := fk_read_request(f)
		if err != .None {
			fk_check(f, false, "read %v", err)
			return
		}
		path := ""
		for h in r.fields do if h.name == ":path" do path = h.value
		append(&pending, r)
		pending[len(pending) - 1].block = transmute([]byte)strings.clone(path, context.temp_allocator)
		if len(pending) == 2 || served + len(pending) == 16 {
			for j := len(pending) - 1; j >= 0; j -= 1 {
				p := pending[j]
				fk_send_headers(f, p.sid, {{":status", "200"}}, false)
				fk_send_data(f, p.sid, p.block, true)
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
	s1, _ := h2_open(c, basic_req("/1", .Medium))
	s3, _ := h2_open(c, basic_req("/3", .Highest))
	s5, _ := h2_open(c, basic_req("/5", .Medium, transmute([]byte)string("payload")))
	r1, e1 := h2_wait(c, s1)
	r5, e5 := h2_wait(c, s5)
	r3, e3 := h2_wait(c, s3)
	testing.expect(t, e1 == .None && e3 == .None && e5 == .None)
	testing.expect_value(t, string(r1.body[:]), "r1")
	testing.expect_value(t, string(r3.body[:]), "r3")
	testing.expect_value(t, string(r5.body[:]), "r5")
	response_destroy(&r1)
	response_destroy(&r3)
	response_destroy(&r5)

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
	thread.join(th)
	thread.destroy(th)
	fk_report(t, &f)
	netio.close(b)
}

// Send-side flow control: tiny stream window, connection window exhaustion, DATA chunking.
@(private = "file")
flow_send_server :: proc(f: ^Fake) {
	fk_handshake(f, {{SETTINGS_INITIAL_WINDOW_SIZE, 1000}})
	// A client may legally send with the default 65535 window before it has
	// processed our SETTINGS (Chrome does), so warm up with one GET first.
	warm, _ := fk_read_request(f)
	fk_send_headers(f, warm.sid, {{":status", "204"}}, true)
	req, _ := fk_read_request(f)
	sid := req.sid
	fk_check(f, req.flags & FLAG_END_STREAM == 0, "POST must not end stream in HEADERS")
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
		fk_check(f, fr.type == .Data && fr.sid == sid, "frame %v", fr.type)
		fk_check(f, len(fr.payload) <= CHROME_DATA_CHUNK, "chunk %d > 2851", len(fr.payload))
		got += len(fr.payload)
		fk_check(f, got <= granted && got <= conn_granted, "window violated: got %d granted %d conn %d", got, granted, conn_granted)
		if got == stream_total {
			fk_check(f, fr.flags & FLAG_END_STREAM != 0, "last DATA must END_STREAM")
			break
		}
		if got == granted {
			inc := u32(min(30000, stream_total - granted))
			granted += int(inc)
			b := u32be(inc)
			fk_write(f, .Window_Update, 0, sid, b[:])
		}
		if got == conn_granted {
			conn_granted += 20000
			b := u32be(20000)
			fk_write(f, .Window_Update, 0, 0, b[:])
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
	resp, err := h2_request(c, basic_req("/upload", .Medium, body))
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, resp.status, 200)
	response_destroy(&resp)
	h2_close(c)
	thread.join(th)
	thread.destroy(th)
	fk_report(t, &f)
	netio.close(b)
}

// Receive-side: Chrome's WINDOW_UPDATE thresholds (half the window).
@(private = "file")
flow_recv_server :: proc(f: ^Fake) {
	fk_handshake(f, nil)
	chunk := make([]byte, 16384, context.temp_allocator)
	total := 5_000_000
	for sid in ([]u32{1, 3}) {
		_, _ = fk_read_request(f)
		fk_send_headers(f, sid, {{":status", "200"}}, false)
		sent := 0
		for sent < total {
			n := min(16384, total - sent)
			fk_send_data(f, sid, chunk[:n], sent + n == total)
			sent += n
		}
	}
	// Drain until the GOAWAY sent by h2_close; fk_read records WINDOW_UPDATEs.
	for {
		fr, err := fk_read(f)
		if err != .None || fr.type == .Goaway do break
	}
	// stream: > 3145728 unacked (half of 6291456) -> 193 frames of 16384
	// conn: > 7864320 unacked (half of 15728640) -> 5000000 + 175 * 16384
	want := [][2]u32{{1, 193 * 16384}, {0, 5_000_000 + 175 * 16384}, {3, 193 * 16384}}
	fk_check(f, len(f.wus) == len(want), "updates %v", f.wus[:])
	for w, i in want {
		if i < len(f.wus) do fk_check(f, f.wus[i] == w, "update %d: %v want %v", i, f.wus[i], w)
	}
}


@(test)
test_h2_flow_control_recv :: proc(t: ^testing.T) {
	a, b := pipe_make()
	f: Fake
	fk_init(&f, b)
	defer fk_destroy(&f)
	// Requests are sent before reading so the server's request reads don't race our updates.
	th := run_server(&f, flow_recv_server)
	c, _ := h2_connect(a, {goaway_on_close = true})
	s1, _ := h2_open(c, basic_req("/big1"))
	r1, e1 := h2_wait(c, s1)
	testing.expect_value(t, e1, Error.None)
	testing.expect_value(t, len(r1.body), 5_000_000)
	response_destroy(&r1)
	s3, _ := h2_open(c, basic_req("/big2"))
	r3, e3 := h2_wait(c, s3)
	testing.expect_value(t, e3, Error.None)
	testing.expect_value(t, len(r3.body), 5_000_000)
	response_destroy(&r3)
	h2_close(c)
	thread.join(th)
	thread.destroy(th)
	fk_report(t, &f)
	netio.close(b)
}

// RST_STREAM, PING both ways, GOAWAY semantics.
@(private = "file")
control_server :: proc(f: ^Fake) {
	fk_handshake(f, nil)
	r1, _ := fk_read_request(f)
	// server PING must be ACKed with the same payload
	fk_write(f, .Ping, 0, 0, {1, 2, 3, 4, 5, 6, 7, 8})
	for {
		fr, _ := fk_read(f)
		if fr.type == .Ping {
			fk_check(f, fr.flags == FLAG_ACK && bytes.equal(fr.payload, []byte{1, 2, 3, 4, 5, 6, 7, 8}), "ping ack")
			break
		}
	}
	rst := u32be(u32(H2_Code.Refused_Stream))
	fk_write(f, .Rst_Stream, 0, r1.sid, rst[:])
	r3, _ := fk_read_request(f)
	rst2 := u32be(u32(H2_Code.Internal_Error))
	fk_send_headers(f, r3.sid, {{":status", "200"}}, false)
	fk_write(f, .Rst_Stream, 0, r3.sid, rst2[:])
	// client PING
	fr, _ := fk_read(f)
	fk_check(f, fr.type == .Ping && fr.flags == 0, "client ping")
	fk_write(f, .Ping, FLAG_ACK, 0, fr.payload)
	// two streams then GOAWAY(last=5)
	r5, _ := fk_read_request(f)
	r7, _ := fk_read_request(f)
	fk_check(f, r5.sid == 5 && r7.sid == 7, "ids %d %d", r5.sid, r7.sid)
	ga: [8]byte
	l := u32be(5)
	copy(ga[:], l[:])
	fk_write(f, .Goaway, 0, 0, ga[:])
	fk_send_headers(f, 5, {{":status", "200"}}, true)
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
	testing.expect_value(t, r1.h2_error, u32(H2_Code.Refused_Stream))
	r3, e3 := h2_request(c, basic_req("/reset"))
	testing.expect_value(t, e3, Error.Stream_Reset)
	testing.expect_value(t, r3.h2_error, u32(H2_Code.Internal_Error))
	testing.expect_value(t, h2_ping(c, {9, 9, 9, 9, 9, 9, 9, 9}), Error.None)
	s5, _ := h2_open(c, basic_req("/5"))
	s7, _ := h2_open(c, basic_req("/7"))
	r7, e7 := h2_wait(c, s7)
	testing.expect_value(t, e7, Error.Refused)
	r5, e5 := h2_wait(c, s5)
	testing.expect_value(t, e5, Error.None)
	testing.expect_value(t, r5.status, 200)
	response_destroy(&r5)
	_ = r7
	_, eg := h2_open(c, basic_req("/after"))
	testing.expect_value(t, eg, Error.Goaway)
	testing.expect(t, !h2_can_open(c))
	h2_close(c)
	thread.join(th)
	thread.destroy(th)
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
	want := H2_Code.Protocol_Error
	switch pc.kind {
	case 0:
		fk_send_data(f, 0, {1}, false) // DATA on stream 0
	case 1:
		// HEADERS without END_HEADERS followed by a non-CONTINUATION frame
		fk_write(f, .Headers, 0, req.sid, {0x88})
		fk_write(f, .Ping, 0, 0, {0, 0, 0, 0, 0, 0, 0, 0})
	case 2:
		fk_write(f, .Push_Promise, FLAG_END_HEADERS, req.sid, {0, 0, 0, 2, 0x88})
	case 3:
		fk_write(f, .Headers, FLAG_END_HEADERS, req.sid, {0xff, 0xff, 0xff, 0xff, 0x7f}) // bad HPACK
		want = .Compression_Error
	case 4:
		fk_write(f, .Data, 0, 0, make([]byte, 20000, context.temp_allocator)) // > max frame
		want = .Frame_Size_Error
	case 5:
		inc := u32be(0x7fffffff)
		fk_write(f, .Window_Update, 0, 0, inc[:]) // overflow conn send window
		want = .Flow_Control_Error
	case 6:
		fk_write(f, .Headers, FLAG_END_HEADERS, 2, {0x88}) // even stream id
	}
	for {
		fr, err := fk_read(f)
		if err != .None {
			fk_check(f, false, "kind %d: no GOAWAY", pc.kind)
			return
		}
		if fr.type == .Goaway {
			fk_check(f, be32(fr.payload[4:]) == u32(want), "kind %d: code %d", pc.kind, be32(fr.payload[4:]))
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
		_, err := h2_open(c, r)
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
		_, err := fk_read(f)
		if err != .None do return
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
	// let the service thread block in read
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
