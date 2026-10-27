package http

import "base:runtime"
import "core:c"
import "core:mem"
import "core:strings"
import "core:time"
import "fc:locks"
import "fc:netio"

// HTTP/2 client: framing, HPACK, flow control, stream states and validation of
// everything the server sends are nghttp2's (vendor/nghttp2). This file feeds it
// bytes, sends what it queues, and lets many threads share one connection.
//
// Threading model ("leader/follower", no background thread required):
//   - Any number of threads may call h2_request on one H2_Conn concurrently.
//   - Every nghttp2 call happens under `mu`. Socket writes happen under `wmu`
//     (taken before `mu`), so frames go out in the order nghttp2 queued them.
//   - Whichever thread is waiting (for its response) and finds nobody reading
//     becomes the reader: it blocks in netio.read without `mu`, hands the
//     bytes to nghttp2, sends what nghttp2 queued in reply, broadcasts, and
//     re-checks. Other waiters sleep on `cond`. Call h2_service() from a
//     thread to keep an idle connection responsive (PING/SETTINGS/GOAWAY).
//   - Requirement on the Stream: one concurrent reader + one concurrent writer
//     (full duplex) must be safe. Plain TCP and Pipe are; TLS must be too.
//
// Chrome parity (verified against a Chrome 148 netlog of the official client):
//   - preface + SETTINGS [1:65536, 2:0, 4:6291456, 6:262144] in that order
//   - WINDOW_UPDATE stream 0 increment 15663105 (window 15728640)
//   - pseudo-header order :method :authority :scheme :path
//   - request bodies sent in DATA frames of at most 2851 bytes (2*MSS - 9)
// Chrome behaviours nghttp2 lacks, done in rewrite_frames and give_back (from Chrome 148's
// net/spdy and quiche sources, not directly visible in a netlog):
//   - HEADERS blocks from hpack.odin, with the PRIORITY flag: exclusive, weight from
//     Request.priority, parent from Http2PriorityDependencies; split at 16383-byte frames
//   - receive windows acked once more than half is unacked or 5 s after the last update,
//     counted per 8 KiB read
//   - a PING before HEADERS or DATA when nothing was read for 10 s

when ODIN_OS == .Windows {
	foreign import ng {"../../build/fc_nghttp2.obj", "../../build/fc_nghttp2_http.obj"}
} else {
	foreign import ng {"../../build/fc_nghttp2.o", "../../build/fc_nghttp2_http.o"}
}

Setting :: struct {
	id:    i32,
	value: u32,
}

@(rodata)
CHROME_SETTINGS := [4]Setting{{1, 65536}, {2, 0}, {4, CHROME_STREAM_WINDOW}, {6, 262144}}
CHROME_STREAM_WINDOW :: 6291456
CHROME_CONNECTION_WINDOW :: 15728640
CHROME_CONNECTION_WINDOW_INCREMENT :: CHROME_CONNECTION_WINDOW - 65535
@(private)
CHROME_DATA_CHUNK :: 2 * 1430 - 9
// Spdy3PriorityToHttp2Weight - 1 for each Priority, by its SPDY priority (Highest 0 .. Throttled 5).
@(private, rodata)
CHROME_SPDY_PRIORITY := [Priority]u8 {
	.Highest   = 0,
	.Medium    = 1,
	.Low       = 2,
	.Lowest    = 3,
	.Idle      = 4,
	.Throttled = 5,
}
@(private, rodata)
CHROME_WEIGHT := [6]u8{255, 219, 182, 146, 109, 73}

@(private)
Ng_Session :: struct {}
@(private)
Ng_Callbacks :: struct {}
@(private)
Ng_Option :: struct {}

// nghttp2_frame_hd, the first member of every nghttp2_frame.
@(private)
Ng_Frame_Hd :: struct {
	length:    c.size_t,
	stream_id: i32,
	type:      u8,
	flags:     u8,
	reserved:  u8,
}

@(private)
Ng_Data :: struct {
	hd:     Ng_Frame_Hd,
	padlen: c.size_t,
}

@(private)
Ng_Settings :: struct {
	hd:  Ng_Frame_Hd,
	niv: c.size_t,
	iv:  [^]Setting,
}

@(private)
Ng_Nv :: struct {
	name, value:       [^]byte,
	namelen, valuelen: c.size_t,
	flags:             u8,
}

@(private)
Ng_Read_Proc :: proc "c" (s: ^Ng_Session, id: i32, buf: [^]byte, n: c.size_t, flags: ^u32, source: rawptr, user: rawptr) -> int

@(private)
Ng_Data_Provider :: struct {
	source: rawptr,
	read:   Ng_Read_Proc,
}

@(private)
NG_FRAME_DATA :: 0
@(private)
NG_FRAME_HEADERS :: 1
@(private)
NG_FRAME_SETTINGS :: 4
@(private)
NG_FRAME_PING :: 6
@(private)
NG_FRAME_CONTINUATION :: 9
@(private)
NG_FLAG_END_STREAM :: 0x1
@(private)
NG_FLAG_ACK :: 0x1
@(private)
NG_FLAG_END_HEADERS :: 0x4
@(private)
NG_FLAG_PRIORITY :: 0x20
@(private)
NG_DATA_FLAG_EOF :: 0x1
@(private)
NG_ERR_TEMPORAL_CALLBACK_FAILURE :: -521
@(private)
NG_ERR_START_STREAM_NOT_ALLOWED :: -516
@(private)
NG_REFUSED_STREAM :: 7
@(private)
NG_CANCEL :: 8

// nghttp2's standalone HPACK coder: only the tests' fake server uses it.
@(private)
Hd :: struct {}

@(private, default_calling_convention = "c")
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

@(private, default_calling_convention = "c")
foreign ng {
	nghttp2_session_callbacks_new :: proc(cbs: ^^Ng_Callbacks) -> c.int ---
	nghttp2_session_callbacks_del :: proc(cbs: ^Ng_Callbacks) ---
	nghttp2_session_callbacks_set_on_frame_recv_callback :: proc(cbs: ^Ng_Callbacks, cb: proc "c" (s: ^Ng_Session, f: ^Ng_Frame_Hd, user: rawptr) -> c.int) ---
	nghttp2_session_callbacks_set_on_data_chunk_recv_callback :: proc(cbs: ^Ng_Callbacks, cb: proc "c" (s: ^Ng_Session, flags: u8, id: i32, data: [^]byte, n: c.size_t, user: rawptr) -> c.int) ---
	nghttp2_session_callbacks_set_on_stream_close_callback :: proc(cbs: ^Ng_Callbacks, cb: proc "c" (s: ^Ng_Session, id: i32, code: u32, user: rawptr) -> c.int) ---
	nghttp2_session_callbacks_set_on_header_callback :: proc(cbs: ^Ng_Callbacks, cb: proc "c" (s: ^Ng_Session, f: ^Ng_Frame_Hd, name: [^]byte, namelen: c.size_t, value: [^]byte, valuelen: c.size_t, flags: u8, user: rawptr) -> c.int) ---
	nghttp2_session_callbacks_set_on_frame_not_send_callback :: proc(cbs: ^Ng_Callbacks, cb: proc "c" (s: ^Ng_Session, f: ^Ng_Frame_Hd, code: c.int, user: rawptr) -> c.int) ---
	nghttp2_session_callbacks_set_data_source_read_length_callback2 :: proc(cbs: ^Ng_Callbacks, cb: proc "c" (s: ^Ng_Session, type: u8, id: i32, conn_window, stream_window: i32, max_frame: u32, user: rawptr) -> int) ---
	nghttp2_option_new :: proc(opt: ^^Ng_Option) -> c.int ---
	nghttp2_option_del :: proc(opt: ^Ng_Option) ---
	nghttp2_option_set_no_auto_window_update :: proc(opt: ^Ng_Option, val: c.int) ---
	nghttp2_session_client_new2 :: proc(s: ^^Ng_Session, cbs: ^Ng_Callbacks, user: rawptr, opt: ^Ng_Option) -> c.int ---
	nghttp2_session_del :: proc(s: ^Ng_Session) ---
	nghttp2_submit_settings :: proc(s: ^Ng_Session, flags: u8, iv: [^]Setting, niv: c.size_t) -> c.int ---
	nghttp2_submit_window_update :: proc(s: ^Ng_Session, flags: u8, id: i32, increment: i32) -> c.int ---
	nghttp2_submit_request2 :: proc(s: ^Ng_Session, pri_spec: rawptr, nva: [^]Ng_Nv, nvlen: c.size_t, data: ^Ng_Data_Provider, stream_user: rawptr) -> i32 ---
	nghttp2_submit_rst_stream :: proc(s: ^Ng_Session, flags: u8, id: i32, code: u32) -> c.int ---
	nghttp2_session_terminate_session :: proc(s: ^Ng_Session, code: u32) -> c.int ---
	nghttp2_session_mem_recv2 :: proc(s: ^Ng_Session, data: [^]byte, n: c.size_t) -> int ---
	nghttp2_session_mem_send2 :: proc(s: ^Ng_Session, data: ^[^]byte) -> int ---
	nghttp2_session_get_stream_user_data :: proc(s: ^Ng_Session, id: i32) -> rawptr ---
	nghttp2_session_set_stream_user_data :: proc(s: ^Ng_Session, id: i32, data: rawptr) -> c.int ---
	nghttp2_session_check_request_allowed :: proc(s: ^Ng_Session) -> c.int ---
	nghttp2_session_want_read :: proc(s: ^Ng_Session) -> c.int ---
	nghttp2_session_want_write :: proc(s: ^Ng_Session) -> c.int ---
}

H2_Config :: struct {
	max_response_body: int, // 0 -> 256 MiB
	max_header_block:  int, // decoded header bytes per response; 0 -> 1 MiB
}

@(private)
H2_Stream :: struct {
	id:           i32,
	req:          Request, // the caller's memory, for its HEADERS (sent before h2_request returns)
	body:         []byte, // request body still to send; the caller's memory
	resp:         Response,
	header_bytes: int,
	got_headers:  bool, // final (non-1xx) response headers received
	done:         bool, // response complete or failed (err)
	err:          Error,
	in_tree:      bool, // listed in H2_Conn.tree (its HEADERS went out, not yet done)
	unacked:      int, // received bytes not yet given back in a WINDOW_UPDATE
	acked_at:     time.Tick,
}

H2_Conn :: struct {
	s:              netio.Stream,
	allocator:      mem.Allocator,
	cfg:            H2_Config,
	mu:             locks.Mutex,
	cond:           locks.Cond,
	wmu:            locks.Mutex,
	session:        ^Ng_Session, // under mu
	streams:        map[i32]^H2_Stream, // under mu
	rbuf:           []byte, // reader only
	wbuf, out:      [dynamic]byte, // under wmu and mu: nghttp2's output, then what goes on the wire
	sent_preface:   bool, // under wmu and mu
	enc:            Hpack_Encoder, // under mu
	tree:           [6][dynamic]i32, // under mu: open streams by SPDY priority, oldest first
	unacked:        int, // under mu: connection bytes not yet given back
	acked_at:       time.Tick, // under mu
	last_read:      time.Tick, // under mu
	ping_in_flight: bool, // under mu
	next_ping:      u64, // under mu
	reading:        bool,
	users:          int, // threads inside public h2_* calls (h2_close waits for 0)
	closing:        bool,
	dead:           Error,
}

// h2_connect sends the client preface, Chrome's SETTINGS and WINDOW_UPDATE (one write).
h2_connect :: proc(s: netio.Stream, cfg := H2_Config{}, allocator := context.allocator) -> (c: ^H2_Conn, err: Error) {
	context.allocator = allocator
	c = new(H2_Conn)
	c.s = s
	c.allocator = allocator
	c.cfg = cfg
	if c.cfg.max_response_body <= 0 do c.cfg.max_response_body = 256 << 20
	if c.cfg.max_header_block <= 0 do c.cfg.max_header_block = 1 << 20
	c.streams = make(map[i32]^H2_Stream)
	c.rbuf = make([]byte, 8 * 1024) // Chrome's kReadBufferSize: window updates follow its reads.
	c.wbuf = make([dynamic]byte)
	c.out = make([dynamic]byte)
	hpack_init(&c.enc, allocator)
	for &l in c.tree do l = make([dynamic]i32)
	c.acked_at = time.tick_now()
	c.last_read = c.acked_at
	c.next_ping = 1
	cbs: ^Ng_Callbacks
	if nghttp2_session_callbacks_new(&cbs) != 0 do panic("nghttp2: out of memory")
	nghttp2_session_callbacks_set_on_frame_recv_callback(cbs, on_frame_recv)
	nghttp2_session_callbacks_set_on_data_chunk_recv_callback(cbs, on_data_chunk)
	nghttp2_session_callbacks_set_on_stream_close_callback(cbs, on_stream_close)
	nghttp2_session_callbacks_set_on_header_callback(cbs, on_header)
	nghttp2_session_callbacks_set_on_frame_not_send_callback(cbs, on_not_sent)
	nghttp2_session_callbacks_set_data_source_read_length_callback2(cbs, data_chunk_len)
	opt: ^Ng_Option
	if nghttp2_option_new(&opt) != 0 do panic("nghttp2: out of memory")
	nghttp2_option_set_no_auto_window_update(opt, 1) // give_back() sends them, as Chrome does.
	rv := nghttp2_session_client_new2(&c.session, cbs, c, opt)
	nghttp2_option_del(opt)
	nghttp2_session_callbacks_del(cbs)
	if rv != 0 do panic("nghttp2: out of memory")
	nghttp2_submit_settings(c.session, 0, raw_data(CHROME_SETTINGS[:]), len(CHROME_SETTINGS))
	nghttp2_submit_window_update(c.session, 0, 0, CHROME_CONNECTION_WINDOW_INCREMENT)
	if err = flush(c); err != .None {
		h2_destroy(c)
		return nil, err
	}
	return c, .None
}

// h2_close sends GOAWAY, shuts the stream down (waking a thread blocked reading
// it), waits for every thread inside the connection to leave, then closes the
// stream and frees the connection. Threads blocked in h2_request/h2_service get
// .Closed. No calls may start after h2_close. If the stream has no shutdown
// hook and a reader stays blocked for 5 s, the connection is leaked rather than
// freed under that reader.
h2_close :: proc(c: ^H2_Conn) {
	locks.lock(&c.mu)
	alive := c.dead == .None
	if alive do nghttp2_session_terminate_session(c.session, 0)
	locks.unlock(&c.mu)
	if alive do flush(c)
	netio.shutdown(c.s)
	locks.lock(&c.mu)
	fail_conn_locked(c, .Closed)
	locks.cond_broadcast(&c.cond)
	deadline := time.tick_now()
	c.closing = true
	for c.reading || c.users > 0 {
		if time.tick_since(deadline) > 5 * time.Second {
			locks.unlock(&c.mu)
			return // leak: a reader is still blocked inside the stream
		}
		locks.cond_wait_with_timeout(&c.cond, &c.mu, 100 * time.Millisecond)
	}
	locks.unlock(&c.mu)
	netio.close(c.s)
	h2_destroy(c)
}

@(private)
h2_destroy :: proc(c: ^H2_Conn) {
	context.allocator = c.allocator
	nghttp2_session_del(c.session)
	for _, st in c.streams {
		response_destroy(&st.resp)
		free(st)
	}
	delete(c.streams)
	delete(c.rbuf)
	delete(c.wbuf)
	delete(c.out)
	hpack_destroy(&c.enc)
	for l in c.tree do delete(l)
	free(c)
}

// ---- nghttp2 callbacks: called from nghttp2_session_mem_recv2/mem_send2 with mu held ----

// A stream's user data is its H2_Stream until h2_request clears it, so these
// never see a freed stream: nil means the caller has gone.
@(private)
stream_of :: proc "contextless" (s: ^Ng_Session, id: i32) -> ^H2_Stream {
	return cast(^H2_Stream)nghttp2_session_get_stream_user_data(s, id)
}

@(private)
finish :: proc(c: ^H2_Conn, st: ^H2_Stream, err: Error, code: u32) {
	if st.done do return
	st.done = true
	st.err = err
	st.resp.h2_error = code
	if !st.in_tree do return
	l := &c.tree[CHROME_SPDY_PRIORITY[st.req.priority]]
	for id, i in l do if id == st.id {
		ordered_remove(l, i)
		break
	}
}

// give_back returns received bytes to the windows as Chrome's IncreaseRecvWindowSize does: a
// WINDOW_UPDATE once more than half the window is unacked or 5 s passed since the last one; the
// connection's first.
@(private)
give_back :: proc(c: ^H2_Conn, st: ^H2_Stream, id: i32, n: int) {
	now := time.tick_now()
	c.unacked += n
	if c.unacked > CHROME_CONNECTION_WINDOW / 2 || time.tick_diff(c.acked_at, now) >= 5 * time.Second {
		nghttp2_submit_window_update(c.session, 0, 0, i32(c.unacked))
		c.unacked, c.acked_at = 0, now
	}
	if st == nil do return
	st.unacked += n
	if st.unacked > CHROME_STREAM_WINDOW / 2 || time.tick_diff(st.acked_at, now) >= 5 * time.Second {
		nghttp2_submit_window_update(c.session, 0, id, i32(st.unacked))
		st.unacked, st.acked_at = 0, now
	}
}

@(private)
on_header :: proc "c" (s: ^Ng_Session, f: ^Ng_Frame_Hd, name: [^]byte, namelen: c.size_t, value: [^]byte, valuelen: c.size_t, flags: u8, user: rawptr) -> c.int {
	conn := cast(^H2_Conn)user
	st := stream_of(s, f.stream_id)
	if f.type != NG_FRAME_HEADERS || st == nil || st.done do return 0
	context = runtime.default_context()
	context.allocator = conn.allocator
	st.header_bytes += int(namelen + valuelen) + 32
	if st.header_bytes > conn.cfg.max_header_block {
		finish(conn, st, .Too_Large, NG_CANCEL) // h2_request resets the stream
		return 0
	}
	n, v := string(name[:namelen]), string(value[:valuelen])
	if n == ":status" {
		st.resp.status = int(v[0] - '0') * 100 + int(v[1] - '0') * 10 + int(v[2] - '0') // nghttp2 checked: 3 digits
	} else {
		append(&st.resp.trailers if st.got_headers else &st.resp.headers, Header{strings.clone(n), strings.clone(v)})
	}
	return 0
}

@(private)
on_frame_recv :: proc "c" (s: ^Ng_Session, f: ^Ng_Frame_Hd, user: rawptr) -> c.int {
	conn := cast(^H2_Conn)user
	context = runtime.default_context()
	switch {
	case f.type == NG_FRAME_SETTINGS && f.flags & NG_FLAG_ACK == 0:
		set := cast(^Ng_Settings)f
		for iv in set.iv[:set.niv] do if iv.id == 1 do hpack_set_table_size(&conn.enc, int(iv.value))
	case f.type == NG_FRAME_PING && f.flags & NG_FLAG_ACK != 0:
		conn.ping_in_flight = false
	}
	if f.type != NG_FRAME_HEADERS && f.type != NG_FRAME_DATA do return 0
	st := stream_of(s, f.stream_id)
	if st != nil && st.done do st = nil
	// Chrome counts padding as consumed at once.
	if pad := int((cast(^Ng_Data)f).padlen); f.type == NG_FRAME_DATA && pad > 0 do give_back(conn, st, f.stream_id, pad)
	if st == nil do return 0
	if f.type == NG_FRAME_HEADERS && !st.got_headers {
		if st.resp.status < 200 {
			// Interim response (100/103): drop it and wait for the final one.
			clear_headers(&st.resp)
			st.resp.status = 0
			return 0
		}
		st.got_headers = true
	}
	if f.flags & NG_FLAG_END_STREAM != 0 do finish(conn, st, .None, 0)
	return 0
}

@(private)
on_data_chunk :: proc "c" (s: ^Ng_Session, flags: u8, id: i32, data: [^]byte, n: c.size_t, user: rawptr) -> c.int {
	conn := cast(^H2_Conn)user
	context = runtime.default_context()
	st := stream_of(s, id)
	if st != nil && st.done do st = nil
	give_back(conn, st, id, int(n))
	if st == nil do return 0
	if len(st.resp.body) + int(n) > conn.cfg.max_response_body {
		finish(conn, st, .Too_Large, NG_CANCEL) // h2_request resets the stream
		return 0
	}
	append(&st.resp.body, ..data[:n])
	return 0
}

@(private)
on_stream_close :: proc "c" (s: ^Ng_Session, id: i32, code: u32, user: rawptr) -> c.int {
	context = runtime.default_context()
	if st := stream_of(s, id); st != nil do finish(cast(^H2_Conn)user, st, .Refused if code == NG_REFUSED_STREAM else .Stream_Reset, code)
	return 0
}

// A queued request nghttp2 drops unsent (GOAWAY arrived first) never opens a
// stream, so on_stream_close won't see it.
@(private)
on_not_sent :: proc "c" (s: ^Ng_Session, f: ^Ng_Frame_Hd, code: c.int, user: rawptr) -> c.int {
	conn := cast(^H2_Conn)user
	context = runtime.default_context()
	if st := conn.streams[f.stream_id]; f.type == NG_FRAME_HEADERS && st != nil {
		if code == NG_ERR_START_STREAM_NOT_ALLOWED do finish(conn, st, .Refused, NG_REFUSED_STREAM)
		else do finish(conn, st, .Io, 0)
	}
	return 0
}

@(private)
read_body :: proc "c" (s: ^Ng_Session, id: i32, buf: [^]byte, n: c.size_t, flags: ^u32, source: rawptr, user: rawptr) -> int {
	st := stream_of(s, id)
	if st == nil do return NG_ERR_TEMPORAL_CALLBACK_FAILURE
	k := min(int(n), len(st.body))
	mem.copy(buf, raw_data(st.body), k)
	st.body = st.body[k:]
	if len(st.body) == 0 do flags^ |= NG_DATA_FLAG_EOF
	return k
}

@(private)
data_chunk_len :: proc "c" (s: ^Ng_Session, type: u8, id: i32, conn_window, stream_window: i32, max_frame: u32, user: rawptr) -> int {
	return int(min(i32(CHROME_DATA_CHUNK), conn_window, stream_window, i32(max_frame)))
}

// ---- I/O ----

// flush writes everything nghttp2 has queued, in one write.
@(private)
flush :: proc(c: ^H2_Conn) -> Error {
	locks.lock(&c.wmu)
	defer locks.unlock(&c.wmu)
	clear(&c.wbuf)
	locks.lock(&c.mu)
	for c.dead == .None {
		p: [^]byte
		n := nghttp2_session_mem_send2(c.session, &p)
		if n <= 0 do break
		append(&c.wbuf, ..p[:n])
	}
	rewrite_frames(c)
	locks.unlock(&c.mu)
	if len(c.out) == 0 do return .None
	return map_net_error(netio.write(c.s, c.out[:]))
}

// rewrite_frames copies nghttp2's output (whole frames) to c.out, replacing each HEADERS and its
// CONTINUATIONs with Chrome's: hpack.odin's block, PRIORITY, 16383-byte frames (kHttp2MaxControlFrameSendSize).
@(private)
rewrite_frames :: proc(c: ^H2_Conn) {
	put_u32 :: proc(out: ^[dynamic]byte, v: u32) {append(out, u8(v >> 24), u8(v >> 16), u8(v >> 8), u8(v))}
	clear(&c.out)
	b := c.wbuf[:]
	if !c.sent_preface && len(b) >= 24 {
		append(&c.out, ..b[:24])
		b = b[24:]
		c.sent_preface = true
	}
	block := make([dynamic]byte, c.allocator)
	defer delete(block)
	for len(b) >= 9 {
		n := 9 + (int(b[0]) << 16 | int(b[1]) << 8 | int(b[2]))
		type, flags := b[3], b[4]
		id := i32((u32(b[5]) << 24 | u32(b[6]) << 16 | u32(b[7]) << 8 | u32(b[8])) & 0x7fffffff)
		frame := b[:n]
		b = b[n:]
		if type == NG_FRAME_HEADERS || type == NG_FRAME_DATA && n > 9 do preface_ping(c)
		if type == NG_FRAME_CONTINUATION do continue
		st := c.streams[id]
		if type != NG_FRAME_HEADERS || st == nil {
			append(&c.out, ..frame)
			continue
		}
		p := CHROME_SPDY_PRIORITY[st.req.priority]
		parent: i32
		for i := int(p); i >= 0 && parent == 0; i -= 1 do if len(c.tree[i]) > 0 do parent = c.tree[i][len(c.tree[i]) - 1]
		if !st.done {
			append(&c.tree[p], id)
			st.in_tree = true
		}
		clear(&block)
		hpack_encode(&c.enc, &block, st.req)
		rest := block[:]
		for first := true; ; first = false {
			k := min(len(rest), 16383 - 9 - (5 if first else 0))
			end: u8 = NG_FLAG_END_HEADERS if k == len(rest) else 0
			plen := u32(k + (5 if first else 0))
			append(&c.out, u8(plen >> 16), u8(plen >> 8), u8(plen))
			if first {
				append(&c.out, NG_FRAME_HEADERS, flags & NG_FLAG_END_STREAM | NG_FLAG_PRIORITY | end)
				put_u32(&c.out, u32(id))
				put_u32(&c.out, u32(parent) | 0x80000000)
				append(&c.out, CHROME_WEIGHT[p])
			} else {
				append(&c.out, NG_FRAME_CONTINUATION, end)
				put_u32(&c.out, u32(id))
			}
			append(&c.out, ..rest[:k])
			rest = rest[k:]
			if end != 0 do break
		}
	}
}

// preface_ping is Chrome's MaybeSendPrefacePing: a PING ahead of a request when nothing was read for 10 s.
@(private)
preface_ping :: proc(c: ^H2_Conn) {
	if c.ping_in_flight || time.tick_since(c.last_read) <= 10 * time.Second do return
	append(&c.out, 0, 0, 8, NG_FRAME_PING, 0, 0, 0, 0, 0)
	for i in 0 ..< 8 do append(&c.out, u8(c.next_ping >> uint(56 - 8 * i)))
	c.ping_in_flight = true
	c.next_ping += 1
}

// read_once reads what the socket has, gives it to nghttp2 and sends its replies.
// Called by the reading leader without mu.
@(private)
read_once :: proc(c: ^H2_Conn) -> Error {
	n, rerr := netio.read(c.s, c.rbuf)
	if rerr != .None do return map_net_error(rerr)
	locks.lock(&c.mu)
	c.last_read = time.tick_now()
	rv := nghttp2_session_mem_recv2(c.session, raw_data(c.rbuf), uint(n))
	locks.unlock(&c.mu)
	ferr := flush(c) // on a connection error this sends nghttp2's GOAWAY
	if rv < 0 do return .Protocol
	if ferr != .None do return ferr
	// nghttp2 is done once a GOAWAY went either way and no streams remain, or it
	// sent one for a protocol error.
	locks.lock(&c.mu)
	defer locks.unlock(&c.mu)
	return .Goaway if nghttp2_session_want_read(c.session) == 0 && nghttp2_session_want_write(c.session) == 0 else .None
}

// enter/leave bracket every public call so h2_close can wait for callers.
@(private)
enter :: proc(c: ^H2_Conn) -> bool {
	locks.lock(&c.mu)
	defer locks.unlock(&c.mu)
	if c.closing do return false
	c.users += 1
	return true
}

@(private)
leave :: proc(c: ^H2_Conn) {
	locks.lock(&c.mu)
	c.users -= 1
	locks.cond_broadcast(&c.cond)
	locks.unlock(&c.mu)
}

@(private)
fail_conn_locked :: proc(c: ^H2_Conn, err: Error) {
	if c.dead == .None do c.dead = err
	for _, st in c.streams do finish(c, st, c.dead, 0)
}

// drive_until: called and returns with c.mu held; st == nil waits until the connection dies.
@(private)
drive_until :: proc(c: ^H2_Conn, st: ^H2_Stream) {
	for st == nil || !st.done {
		if c.dead != .None do return
		if !c.reading {
			c.reading = true
			locks.unlock(&c.mu)
			err := read_once(c)
			locks.lock(&c.mu)
			c.reading = false
			if err != .None do fail_conn_locked(c, err)
			locks.cond_broadcast(&c.cond)
		} else {
			locks.cond_wait(&c.cond, &c.mu)
		}
	}
}

// ---- requests ----

@(private)
FORBIDDEN_H2_HEADERS := [?]string{"connection", "keep-alive", "proxy-connection", "transfer-encoding", "upgrade"}

@(private)
validate_h2_request :: proc(req: Request) -> bool {
	if len(req.method) == 0 || len(req.path) == 0 || len(req.scheme) == 0 do return false
	for h in req.headers {
		if len(h.name) == 0 || h.name[0] == ':' do return false
		for ch in transmute([]byte)h.name {
			if ch >= 'A' && ch <= 'Z' do return false
			if ch <= ' ' || ch >= 0x7f do return false
		}
		if !valid_value(h.value) do return false
		for f in FORBIDDEN_H2_HEADERS do if h.name == f do return false
		if h.name == "te" && h.value != "trailers" do return false
	}
	return true
}

// h2_request sends req and blocks until its response is complete (caller owns
// it: response_destroy). nghttp2 holds the request back while the server's
// MAX_CONCURRENT_STREAMS is reached. Thread-safe.
h2_request :: proc(c: ^H2_Conn, req: Request) -> (resp: Response, err: Error) {
	if !validate_h2_request(req) do return {}, .Bad_Request
	if !enter(c) do return {}, .Closed
	defer leave(c)

	nva := make([dynamic]Ng_Nv, 0, len(req.headers) + 4, context.temp_allocator)
	nv :: proc(n, v: string) -> Ng_Nv {return {raw_data(n), raw_data(v), len(n), len(v), 0}}
	append(&nva, nv(":method", req.method), nv(":authority", req.authority), nv(":scheme", req.scheme), nv(":path", req.path))
	for h in req.headers do append(&nva, nv(h.name, h.value))

	st := new(H2_Stream, c.allocator)
	st.req = req
	st.body = req.body
	st.acked_at = time.tick_now()
	st.resp = Response {
		version   = .Http2,
		allocator = c.allocator,
		headers   = make([dynamic]Header, 0, 16, c.allocator),
		trailers  = make([dynamic]Header, 0, 0, c.allocator),
		body      = make([dynamic]byte, 0, 0, c.allocator),
	}
	body := Ng_Data_Provider{read = read_body}
	locks.lock(&c.mu)
	if c.dead != .None || nghttp2_session_check_request_allowed(c.session) == 0 {
		err = c.dead if c.dead != .None else .Goaway
		locks.unlock(&c.mu)
		response_destroy(&st.resp)
		free(st, c.allocator)
		return {}, err
	}
	// nghttp2 copies the header names and values.
	st.id = nghttp2_submit_request2(c.session, nil, raw_data(nva), len(nva), &body if len(req.body) > 0 else nil, st)
	if st.id < 0 {
		locks.unlock(&c.mu)
		response_destroy(&st.resp)
		free(st, c.allocator)
		return {}, .Goaway
	}
	c.streams[st.id] = st
	locks.unlock(&c.mu)
	if werr := flush(c); werr != .None {
		locks.lock(&c.mu)
		fail_conn_locked(c, werr)
		locks.cond_broadcast(&c.cond)
		locks.unlock(&c.mu)
	}

	locks.lock(&c.mu)
	drive_until(c, st)
	if !st.done do finish(c, st, c.dead if c.dead != .None else .Io, 0)
	delete_key(&c.streams, st.id)
	// The stream may outlive this call (our body still sending, or a reset not yet
	// sent): detach it so nghttp2 never reads req.body or st again, and end it.
	// A request nghttp2 still holds queued (the connection died first) has no
	// stream yet; set_stream_user_data also clears its queued copy of st.
	reset := stream_of(c.session, st.id) != nil && c.dead == .None
	nghttp2_session_set_stream_user_data(c.session, st.id, nil)
	if reset do nghttp2_submit_rst_stream(c.session, 0, st.id, 0 if st.err == .None else NG_CANCEL)
	locks.cond_broadcast(&c.cond)
	locks.unlock(&c.mu)
	if reset do flush(c)
	resp, err = st.resp, st.err
	free(st, c.allocator)
	if err != .None {
		code := resp.h2_error
		response_destroy(&resp)
		resp.h2_error = code
	}
	return
}

// h2_service reads and handles frames until the connection dies. Run it on a
// thread to keep an idle connection responsive (PING/SETTINGS/GOAWAY).
h2_service :: proc(c: ^H2_Conn) -> Error {
	if !enter(c) do return .Closed
	defer leave(c)
	locks.lock(&c.mu)
	defer locks.unlock(&c.mu)
	drive_until(c, nil)
	return c.dead
}

// h2_can_open reports whether new streams may be opened on this connection.
h2_can_open :: proc(c: ^H2_Conn) -> bool {
	locks.lock(&c.mu)
	defer locks.unlock(&c.mu)
	return c.dead == .None && nghttp2_session_check_request_allowed(c.session) != 0
}
