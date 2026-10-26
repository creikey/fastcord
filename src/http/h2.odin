package http

import "fc:locks"
import "core:mem"
import "core:strings"
import "core:time"
import "fc:netio"

// HTTP/2 client (RFC 9113) with Chrome 148 connection behaviour.
//
// Threading model ("leader/follower", no background thread):
//   - Any number of threads may call h2_request / h2_open / h2_wait on one
//     H2_Conn concurrently.
//   - Writes are serialized by `wmu`, which also guards the HPACK encoder and
//     stream-id assignment, so HEADERS always go out in stream-id order.
//   - There is no dedicated reader thread. Whichever thread is waiting on
//     something (its response, flow-control window, a concurrency slot, a PING
//     ack) and finds nobody reading becomes the reader for ONE frame, then
//     dispatches it, broadcasts, and re-checks. Other waiters sleep on `cond`.
//     The HPACK decoder and CONTINUATION state are only touched by the
//     current reader.
//   - Consequence: an idle connection (no waiters) reads nothing; PING/SETTINGS
//     from the server are answered when the next request runs. Call
//     h2_service() from a thread if you want an always-reading connection.
//   - Lock order: wmu before mu. The reader never holds mu while writing.
//   - Requirement on the Stream: one concurrent reader + one concurrent writer
//     (full duplex) must be safe. Plain TCP and Pipe are; TLS must be too.
//
// Chrome parity (verified against a Chrome 148 netlog of the official client):
//   - preface + SETTINGS [1:65536, 2:0, 4:6291456, 6:262144] in that order
//   - WINDOW_UPDATE stream 0 increment 15663105 (window 15728640)
//   - HEADERS carry PRIORITY: exclusive=1, weight from request priority
//     (Highest 256, Medium 220, Low 183, Lowest 147, Idle 110, Throttled 74),
//     parent = newest open stream with priority >= ours (Http2PriorityDependencies)
//   - pseudo-header order :method :authority :scheme :path
// From Chromium source (not directly observable in netlog):
//   - receive windows refreshed when unacked bytes exceed half the window
//   - request bodies sent in DATA frames of at most 2851 bytes (2*MSS - 9)
//   - HPACK choices: see hpack.odin

H2_PREFACE :: "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"

Frame_Type :: enum u8 {
	Data            = 0,
	Headers         = 1,
	Priority        = 2,
	Rst_Stream      = 3,
	Settings        = 4,
	Push_Promise    = 5,
	Ping            = 6,
	Goaway          = 7,
	Window_Update   = 8,
	Continuation    = 9,
	Priority_Update = 16,
}

FLAG_END_STREAM :: 0x1
FLAG_ACK :: 0x1
FLAG_END_HEADERS :: 0x4
FLAG_PADDED :: 0x8
FLAG_PRIORITY :: 0x20

H2_Code :: enum u32 {
	No_Error            = 0,
	Protocol_Error      = 1,
	Internal_Error      = 2,
	Flow_Control_Error  = 3,
	Settings_Timeout    = 4,
	Stream_Closed       = 5,
	Frame_Size_Error    = 6,
	Refused_Stream      = 7,
	Cancel              = 8,
	Compression_Error   = 9,
	Connect_Error       = 10,
	Enhance_Your_Calm   = 11,
	Inadequate_Security = 12,
	Http_1_1_Required   = 13,
}

Setting :: struct {
	id:    u16,
	value: u32,
}

SETTINGS_HEADER_TABLE_SIZE :: 1
SETTINGS_ENABLE_PUSH :: 2
SETTINGS_MAX_CONCURRENT_STREAMS :: 3
SETTINGS_INITIAL_WINDOW_SIZE :: 4
SETTINGS_MAX_FRAME_SIZE :: 5
SETTINGS_MAX_HEADER_LIST_SIZE :: 6
SETTINGS_ENABLE_CONNECT_PROTOCOL :: 8
SETTINGS_NO_RFC7540_PRIORITIES :: 9

@(rodata)
CHROME_SETTINGS := [4]Setting {
	{SETTINGS_HEADER_TABLE_SIZE, 65536},
	{SETTINGS_ENABLE_PUSH, 0},
	{SETTINGS_INITIAL_WINDOW_SIZE, 6291456},
	{SETTINGS_MAX_HEADER_LIST_SIZE, 262144},
}
CHROME_CONNECTION_WINDOW_INCREMENT :: 15663105
CHROME_DATA_CHUNK :: 2 * 1430 - 9
DEFAULT_WINDOW :: 65535
MAX_WINDOW :: 0x7fffffff

H2_Config :: struct {
	settings:          []Setting, // nil -> CHROME_SETTINGS (sent in this order)
	window_increment:  u32, // 0 -> Chrome's 15663105
	no_window_update:  bool, // don't send the connection WINDOW_UPDATE at all
	data_chunk:        int, // max DATA payload we send; 0 -> 2851
	max_response_body: int, // 0 -> 256 MiB
	max_header_block:  int, // accumulated HEADERS+CONTINUATION bytes; 0 -> 1 MiB
	goaway_on_close:   bool, // send GOAWAY(NO_ERROR) in h2_close
}

H2_Stream :: struct {
	id:           u32,
	priority:     u8, // spdy priority 0..5
	send_window:  i64,
	recv_window:  i64,
	recv_unacked: i64,
	resp:         Response,
	got_headers:  bool,
	done:         bool, // response complete or failed (err)
	err:          Error,
	sent_end:     bool,
}

H2_Conn :: struct {
	s:                    netio.Stream,
	r:                    Reader,
	allocator:            mem.Allocator,
	cfg:                  H2_Config,
	mu:                   locks.Mutex,
	cond:                 locks.Cond,
	wmu:                  locks.Mutex,
	enc:                  Hpack_Encoder, // under wmu
	dec:                  Hpack_Decoder, // reader only
	reading:              bool,
	users:                int, // threads inside public h2_* calls (h2_close waits for 0)
	closing:              bool,
	streams:              map[u32]^H2_Stream,
	active:               int, // reserved + open streams
	next_id:              u32,
	// peer settings
	peer_max_concurrent:  int,
	peer_initial_window:  i64,
	peer_max_frame:       int,
	peer_max_header_list: int,
	peer_no_rfc7540_prio: bool,
	conn_send_window:     i64,
	// our receive side
	our_max_frame:        int,
	our_stream_window:    i64,
	conn_recv_max:        i64,
	conn_recv_window:     i64,
	conn_recv_unacked:    i64,
	payload:              []byte,
	cont_stream:          u32,
	cont_flags:           u8,
	cont_buf:             [dynamic]byte,
	// lifecycle
	goaway:               bool,
	goaway_last:          u32,
	goaway_code:          u32,
	dead:                 Error,
	settings_acked:       bool,
	got_settings:         bool,
	ping_acks:            int,
	prio_lists:           [6][dynamic]u32,
}

// h2_connect sends the client preface, SETTINGS and WINDOW_UPDATE (one write).
h2_connect :: proc(s: netio.Stream, cfg := H2_Config{}, allocator := context.allocator) -> (c: ^H2_Conn, err: Error) {
	context.allocator = allocator
	c = new(H2_Conn)
	c.s = s
	c.allocator = allocator
	c.cfg = cfg
	if c.cfg.settings == nil do c.cfg.settings = CHROME_SETTINGS[:]
	if c.cfg.window_increment == 0 do c.cfg.window_increment = CHROME_CONNECTION_WINDOW_INCREMENT
	if c.cfg.data_chunk <= 0 do c.cfg.data_chunk = CHROME_DATA_CHUNK
	if c.cfg.max_response_body <= 0 do c.cfg.max_response_body = 256 << 20
	if c.cfg.max_header_block <= 0 do c.cfg.max_header_block = 1 << 20
	reader_init(&c.r, s, READER_SIZE)
	c.streams = make(map[u32]^H2_Stream)
	c.next_id = 1
	c.peer_max_concurrent = max(int)
	c.peer_initial_window = DEFAULT_WINDOW
	c.peer_max_frame = 16384
	c.conn_send_window = DEFAULT_WINDOW
	c.our_max_frame = 16384
	c.our_stream_window = DEFAULT_WINDOW
	table := HPACK_DEFAULT_TABLE_SIZE
	max_list := 0
	for st in c.cfg.settings {
		switch st.id {
		case SETTINGS_HEADER_TABLE_SIZE:
			table = int(st.value)
		case SETTINGS_INITIAL_WINDOW_SIZE:
			c.our_stream_window = i64(st.value)
		case SETTINGS_MAX_FRAME_SIZE:
			c.our_max_frame = int(st.value)
		case SETTINGS_MAX_HEADER_LIST_SIZE:
			max_list = int(st.value)
		}
	}
	c.conn_recv_max = DEFAULT_WINDOW
	if !c.cfg.no_window_update do c.conn_recv_max += i64(c.cfg.window_increment)
	c.conn_recv_window = c.conn_recv_max
	c.payload = make([]byte, c.our_max_frame)
	c.cont_buf = make([dynamic]byte)
	hpack_encoder_init(&c.enc)
	hpack_decoder_init(&c.dec, table, max_list)
	for i in 0 ..< len(c.prio_lists) do c.prio_lists[i] = make([dynamic]u32)

	buf := make([dynamic]byte, 0, 128, context.temp_allocator)
	append(&buf, H2_PREFACE)
	put_frame_header(&buf, 6 * len(c.cfg.settings), .Settings, 0, 0)
	for st in c.cfg.settings {
		append(&buf, u8(st.id >> 8), u8(st.id))
		put_u32(&buf, st.value)
	}
	if !c.cfg.no_window_update {
		put_frame_header(&buf, 4, .Window_Update, 0, 0)
		put_u32(&buf, c.cfg.window_increment)
	}
	if werr := netio.write(s, buf[:]); werr != .None {
		h2_destroy(c)
		return nil, map_net_error(werr)
	}
	return c, .None
}

// h2_close optionally sends GOAWAY, shuts the stream down (waking a thread
// blocked reading it), waits for every thread inside the connection to leave,
// then closes the stream and frees the connection. Threads blocked in
// h2_wait/h2_ping/h2_service get .Closed. No calls may start after h2_close.
// If the stream has no shutdown hook and a reader stays blocked for 5 s, the
// connection is leaked rather than freed under that reader.
h2_close :: proc(c: ^H2_Conn) {
	if c.cfg.goaway_on_close && c.dead == .None {
		buf := make([dynamic]byte, 0, 17, context.temp_allocator)
		put_goaway(&buf, 0, .No_Error)
		locks.lock(&c.wmu)
		_ = netio.write(c.s, buf[:])
		locks.unlock(&c.wmu)
	}
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
	for _, st in c.streams {
		response_destroy(&st.resp)
		free(st)
	}
	delete(c.streams)
	reader_destroy(&c.r)
	delete(c.payload)
	delete(c.cont_buf)
	hpack_encoder_destroy(&c.enc)
	hpack_decoder_destroy(&c.dec)
	for l in c.prio_lists do delete(l)
	free(c)
}

// ---- framing ----

@(private)
put_u32 :: proc(buf: ^[dynamic]byte, x: u32) {
	append(buf, u8(x >> 24), u8(x >> 16), u8(x >> 8), u8(x))
}

put_frame_header :: proc(buf: ^[dynamic]byte, length: int, type: Frame_Type, flags: u8, stream_id: u32) {
	append(buf, u8(length >> 16), u8(length >> 8), u8(length), u8(type), flags)
	put_u32(buf, stream_id & 0x7fffffff)
}

@(private)
put_goaway :: proc(buf: ^[dynamic]byte, last: u32, code: H2_Code) {
	put_frame_header(buf, 8, .Goaway, 0, 0)
	put_u32(buf, last)
	put_u32(buf, u32(code))
}

@(private)
put_rst :: proc(buf: ^[dynamic]byte, id: u32, code: H2_Code) {
	put_frame_header(buf, 4, .Rst_Stream, 0, id)
	put_u32(buf, u32(code))
}

@(private)
put_window_update :: proc(buf: ^[dynamic]byte, id: u32, inc: u32) {
	put_frame_header(buf, 4, .Window_Update, 0, id)
	put_u32(buf, inc)
}

@(private)
be32 :: #force_inline proc(b: []byte) -> u32 {
	return u32(b[0]) << 24 | u32(b[1]) << 16 | u32(b[2]) << 8 | u32(b[3])
}

// chrome_weight is spdy::Spdy3PriorityToHttp2Weight.
chrome_weight :: proc(spdy_priority: u8) -> int {
	STEPS :: f32(255.9) / 7
	return int(STEPS * (7 - f32(spdy_priority))) + 1
}

spdy_priority :: proc(p: Priority) -> u8 {
	switch p {
	case .Highest:
		return 0
	case .Medium:
		return 1
	case .Low:
		return 2
	case .Lowest:
		return 3
	case .Idle:
		return 4
	case .Throttled:
		return 5
	}
	return 1
}

// ---- waiting / reading ----

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
Wait_Pred :: #type proc(c: ^H2_Conn, data: rawptr) -> bool

// drive_until: called and returns with c.mu held.
@(private)
drive_until :: proc(c: ^H2_Conn, pred: Wait_Pred, data: rawptr) {
	for !pred(c, data) {
		if c.dead != .None do return
		if !c.reading {
			c.reading = true
			locks.unlock(&c.mu)
			err := read_one_frame(c)
			locks.lock(&c.mu)
			c.reading = false
			if err != .None do fail_conn_locked(c, err)
			locks.cond_broadcast(&c.cond)
		} else {
			locks.cond_wait(&c.cond, &c.mu)
		}
	}
}

@(private)
fail_stream_locked :: proc(c: ^H2_Conn, st: ^H2_Stream, err: Error, code: u32) {
	if st.done do return
	st.done = true
	st.err = err
	st.resp.h2_error = code
	prio_remove(c, st)
}

@(private)
fail_conn_locked :: proc(c: ^H2_Conn, err: Error) {
	if c.dead == .None do c.dead = err
	for _, st in c.streams do fail_stream_locked(c, st, c.dead, c.goaway_code)
}

@(private)
prio_remove :: proc(c: ^H2_Conn, st: ^H2_Stream) {
	l := &c.prio_lists[st.priority]
	for id, i in l {
		if id == st.id {
			ordered_remove(l, i)
			return
		}
	}
}

// Writes from the reader / control paths.
@(private)
write_locked_w :: proc(c: ^H2_Conn, data: []byte) -> Error {
	locks.lock(&c.wmu)
	defer locks.unlock(&c.wmu)
	return map_net_error(netio.write(c.s, data))
}

// conn_error sends GOAWAY with code and returns the error to make the connection dead.
@(private)
conn_error :: proc(c: ^H2_Conn, code: H2_Code) -> Error {
	buf := make([dynamic]byte, 0, 17, context.temp_allocator)
	put_goaway(&buf, 0, code)
	_ = write_locked_w(c, buf[:])
	locks.lock(&c.mu)
	c.goaway_code = u32(code)
	locks.unlock(&c.mu)
	return .Protocol if code != .Flow_Control_Error else .Flow_Control
}

@(private)
stream_error :: proc(c: ^H2_Conn, id: u32, code: H2_Code) {
	buf := make([dynamic]byte, 0, 13, context.temp_allocator)
	put_rst(&buf, id, code)
	_ = write_locked_w(c, buf[:])
	locks.lock(&c.mu)
	if st, ok := c.streams[id]; ok do fail_stream_locked(c, st, .Protocol if code != .Flow_Control_Error else .Flow_Control, u32(code))
	locks.unlock(&c.mu)
}

// read_one_frame reads and handles one frame. Called by the reading leader without c.mu.
@(private)
read_one_frame :: proc(c: ^H2_Conn) -> Error {
	hdr, herr := peek_exact(&c.r, 9)
	if herr != .None do return herr
	length := int(hdr[0]) << 16 | int(hdr[1]) << 8 | int(hdr[2])
	type := hdr[3]
	flags := hdr[4]
	sid := be32(hdr[5:9]) & 0x7fffffff
	consume(&c.r, 9)
	if length > c.our_max_frame {
		return conn_error(c, .Frame_Size_Error)
	}
	p := c.payload[:length]
	if err := read_exact(&c.r, p); err != .None do return err

	if c.cont_stream != 0 && (Frame_Type(type) != .Continuation || sid != c.cont_stream) {
		return conn_error(c, .Protocol_Error)
	}

	#partial switch Frame_Type(type) {
	case .Data:
		return on_data(c, sid, flags, p)
	case .Headers:
		return on_headers(c, sid, flags, p)
	case .Continuation:
		if c.cont_stream == 0 do return conn_error(c, .Protocol_Error)
		if len(c.cont_buf) + len(p) > c.cfg.max_header_block do return conn_error(c, .Enhance_Your_Calm)
		append(&c.cont_buf, ..p)
		if flags & FLAG_END_HEADERS != 0 {
			id := c.cont_stream
			c.cont_stream = 0
			return on_header_block(c, id, c.cont_flags, c.cont_buf[:])
		}
		return .None
	case .Priority:
		if sid == 0 do return conn_error(c, .Protocol_Error)
		if length != 5 do stream_error(c, sid, .Frame_Size_Error)
		return .None
	case .Rst_Stream:
		if sid == 0 do return conn_error(c, .Protocol_Error)
		if length != 4 do return conn_error(c, .Frame_Size_Error)
		if !opened(c, sid) do return conn_error(c, .Protocol_Error) // idle stream
		code := be32(p)
		locks.lock(&c.mu)
		if st, ok := c.streams[sid]; ok {
			fail_stream_locked(c, st, .Refused if code == u32(H2_Code.Refused_Stream) else .Stream_Reset, code)
		}
		locks.unlock(&c.mu)
		return .None
	case .Settings:
		return on_settings(c, sid, flags, p)
	case .Push_Promise:
		return conn_error(c, .Protocol_Error) // we sent ENABLE_PUSH=0
	case .Ping:
		if sid != 0 do return conn_error(c, .Protocol_Error)
		if length != 8 do return conn_error(c, .Frame_Size_Error)
		if flags & FLAG_ACK != 0 {
			locks.lock(&c.mu)
			c.ping_acks += 1
			locks.unlock(&c.mu)
			return .None
		}
		buf := make([dynamic]byte, 0, 17, context.temp_allocator)
		put_frame_header(&buf, 8, .Ping, FLAG_ACK, 0)
		append(&buf, ..p)
		return write_locked_w(c, buf[:])
	case .Goaway:
		if sid != 0 do return conn_error(c, .Protocol_Error)
		if length < 8 do return conn_error(c, .Frame_Size_Error)
		last := be32(p) & 0x7fffffff
		code := be32(p[4:])
		locks.lock(&c.mu)
		c.goaway = true
		c.goaway_last = last
		c.goaway_code = code
		for id, st in c.streams {
			if id > last do fail_stream_locked(c, st, .Refused, code)
		}
		locks.unlock(&c.mu)
		return .None
	case .Window_Update:
		if length != 4 do return conn_error(c, .Frame_Size_Error)
		inc := i64(be32(p) & 0x7fffffff)
		if sid == 0 {
			if inc == 0 do return conn_error(c, .Protocol_Error)
			locks.lock(&c.mu)
			c.conn_send_window += inc
			over := c.conn_send_window > MAX_WINDOW
			locks.unlock(&c.mu)
			if over do return conn_error(c, .Flow_Control_Error)
			return .None
		}
		if inc == 0 {
			stream_error(c, sid, .Protocol_Error)
			return .None
		}
		locks.lock(&c.mu)
		over := false
		if st, ok := c.streams[sid]; ok {
			st.send_window += inc
			over = st.send_window > MAX_WINDOW
		}
		locks.unlock(&c.mu)
		if over do stream_error(c, sid, .Flow_Control_Error)
		return .None
	}
	return .None // unknown / ignored (PRIORITY_UPDATE, ALTSVC, ORIGIN, ...)
}

// opened: sid was assigned by us (client-initiated, not idle).
@(private)
opened :: proc(c: ^H2_Conn, sid: u32) -> bool {
	locks.lock(&c.mu)
	defer locks.unlock(&c.mu)
	return sid % 2 == 1 && sid < c.next_id
}

@(private)
strip_padding :: proc(flags: u8, p: []byte) -> ([]byte, bool) {
	if flags & FLAG_PADDED == 0 do return p, true
	if len(p) < 1 do return nil, false
	pad := int(p[0])
	if pad > len(p) - 1 do return nil, false
	return p[1:len(p) - pad], true
}

@(private)
on_data :: proc(c: ^H2_Conn, sid: u32, flags: u8, p: []byte) -> Error {
	if sid == 0 do return conn_error(c, .Protocol_Error)
	if !opened(c, sid) do return conn_error(c, .Protocol_Error)
	n := i64(len(p))
	out := make([dynamic]byte, 0, 32, context.temp_allocator)
	locks.lock(&c.mu)
	if n > c.conn_recv_window {
		locks.unlock(&c.mu)
		return conn_error(c, .Flow_Control_Error)
	}
	c.conn_recv_window -= n
	c.conn_recv_unacked += n
	// Chrome: refresh the session window once more than half is unacked.
	if c.conn_recv_unacked > c.conn_recv_max / 2 {
		put_window_update(&out, 0, u32(c.conn_recv_unacked))
		c.conn_recv_window += c.conn_recv_unacked
		c.conn_recv_unacked = 0
	}
	data, ok := strip_padding(flags, p)
	st, found := c.streams[sid]
	rst_code := H2_Code.No_Error
	if !ok {
		locks.unlock(&c.mu)
		return conn_error(c, .Protocol_Error)
	}
	if found && !st.done {
		st.recv_window -= n
		switch {
		case st.recv_window < 0:
			rst_code = .Flow_Control_Error
		case !st.got_headers:
			rst_code = .Protocol_Error
		case len(st.resp.body) + len(data) > c.cfg.max_response_body:
			rst_code = .Cancel
			fail_stream_locked(c, st, .Too_Large, u32(H2_Code.Cancel))
		case:
			append(&st.resp.body, ..data)
			if flags & FLAG_END_STREAM != 0 {
				st.done = true
				prio_remove(c, st)
			} else {
				st.recv_unacked += n
				if st.recv_unacked > c.our_stream_window / 2 {
					put_window_update(&out, sid, u32(st.recv_unacked))
					st.recv_window += st.recv_unacked
					st.recv_unacked = 0
				}
			}
		}
	}
	locks.unlock(&c.mu)
	if rst_code != .No_Error {
		if rst_code == .Cancel {
			put_rst(&out, sid, .Cancel)
		} else {
			stream_error(c, sid, rst_code)
		}
	}
	if len(out) > 0 do return write_locked_w(c, out[:])
	return .None
}

@(private)
on_headers :: proc(c: ^H2_Conn, sid: u32, flags: u8, p: []byte) -> Error {
	if sid == 0 || sid % 2 == 0 || !opened(c, sid) do return conn_error(c, .Protocol_Error)
	frag, ok := strip_padding(flags, p)
	if !ok do return conn_error(c, .Protocol_Error)
	if flags & FLAG_PRIORITY != 0 {
		if len(frag) < 5 do return conn_error(c, .Frame_Size_Error)
		frag = frag[5:]
	}
	if flags & FLAG_END_HEADERS != 0 do return on_header_block(c, sid, flags, frag)
	if len(frag) > c.cfg.max_header_block do return conn_error(c, .Enhance_Your_Calm)
	clear(&c.cont_buf)
	append(&c.cont_buf, ..frag)
	c.cont_stream = sid
	c.cont_flags = flags
	return .None
}

@(private)
on_header_block :: proc(c: ^H2_Conn, sid: u32, flags: u8, block: []byte) -> Error {
	fields := make([dynamic]Header, 0, 16, c.allocator)
	defer {
		for h in fields {
			delete(h.name, c.allocator)
			delete(h.value, c.allocator)
		}
		delete(fields)
	}
	derr := hpack_decode(&c.dec, block, &fields, c.allocator)
	if derr == .Protocol do return conn_error(c, .Compression_Error)
	end_stream := flags & FLAG_END_STREAM != 0

	locks.lock(&c.mu)
	st, found := c.streams[sid]
	if !found || st.done {
		locks.unlock(&c.mu)
		return .None
	}
	if derr == .Too_Large {
		fail_stream_locked(c, st, .Too_Large, u32(H2_Code.Protocol_Error))
		locks.unlock(&c.mu)
		buf := make([dynamic]byte, 0, 13, context.temp_allocator)
		put_rst(&buf, sid, .Protocol_Error)
		return write_locked_w(c, buf[:])
	}
	bad := false
	if !st.got_headers {
		status := -1
		pseudo_done := false
		for h in fields {
			if len(h.name) > 0 && h.name[0] == ':' {
				if pseudo_done || h.name != ":status" || status >= 0 {
					bad = true
					break
				}
				status = parse_status(h.value)
				if status < 0 do bad = true
			} else {
				pseudo_done = true
			}
		}
		if status < 0 do bad = true
		if !bad && status >= 100 && status < 200 {
			// interim response (100/103): ignore; END_STREAM here is invalid
			bad = end_stream
		} else if !bad {
			st.resp.status = status
			st.got_headers = true
			for h in fields {
				if h.name[0] == ':' do continue
				append(&st.resp.headers, Header{strings.clone(h.name, c.allocator), strings.clone(h.value, c.allocator)})
			}
		}
	} else {
		// trailers: must end the stream and carry no pseudo-headers
		if !end_stream do bad = true
		for h in fields {
			if len(h.name) > 0 && h.name[0] == ':' do bad = true
		}
		if !bad {
			for h in fields {
				append(&st.resp.trailers, Header{strings.clone(h.name, c.allocator), strings.clone(h.value, c.allocator)})
			}
		}
	}
	if !bad && end_stream && st.got_headers {
		st.done = true
		prio_remove(c, st)
	}
	locks.unlock(&c.mu)
	if bad do stream_error(c, sid, .Protocol_Error)
	return .None
}

@(private)
parse_status :: proc(s: string) -> int {
	if len(s) != 3 do return -1
	n := 0
	for ch in transmute([]byte)s {
		if ch < '0' || ch > '9' do return -1
		n = n * 10 + int(ch - '0')
	}
	return n
}

@(private)
on_settings :: proc(c: ^H2_Conn, sid: u32, flags: u8, p: []byte) -> Error {
	if sid != 0 do return conn_error(c, .Protocol_Error)
	if flags & FLAG_ACK != 0 {
		if len(p) != 0 do return conn_error(c, .Frame_Size_Error)
		locks.lock(&c.mu)
		c.settings_acked = true
		locks.unlock(&c.mu)
		return .None
	}
	if len(p) % 6 != 0 do return conn_error(c, .Frame_Size_Error)
	new_table := -1
	// validate first
	for i := 0; i < len(p); i += 6 {
		id := u16(p[i]) << 8 | u16(p[i + 1])
		v := be32(p[i + 2:])
		switch id {
		case SETTINGS_ENABLE_PUSH:
			if v > 1 do return conn_error(c, .Protocol_Error)
		case SETTINGS_INITIAL_WINDOW_SIZE:
			if v > MAX_WINDOW do return conn_error(c, .Flow_Control_Error)
		case SETTINGS_MAX_FRAME_SIZE:
			if v < 16384 || v > 16777215 do return conn_error(c, .Protocol_Error)
		}
	}
	locks.lock(&c.mu)
	for i := 0; i < len(p); i += 6 {
		id := u16(p[i]) << 8 | u16(p[i + 1])
		v := be32(p[i + 2:])
		switch id {
		case SETTINGS_HEADER_TABLE_SIZE:
			new_table = int(v)
		case SETTINGS_MAX_CONCURRENT_STREAMS:
			c.peer_max_concurrent = int(v)
		case SETTINGS_INITIAL_WINDOW_SIZE:
			delta := i64(v) - c.peer_initial_window
			c.peer_initial_window = i64(v)
			for _, st in c.streams do st.send_window += delta
		case SETTINGS_MAX_FRAME_SIZE:
			c.peer_max_frame = int(v)
		case SETTINGS_MAX_HEADER_LIST_SIZE:
			c.peer_max_header_list = int(v)
		case SETTINGS_NO_RFC7540_PRIORITIES:
			c.peer_no_rfc7540_prio = v == 1
		}
	}
	c.got_settings = true
	locks.unlock(&c.mu)
	// Apply the encoder table size and ACK under wmu so every HEADERS block
	// written after the ACK uses the new size.
	buf := make([dynamic]byte, 0, 9, context.temp_allocator)
	put_frame_header(&buf, 0, .Settings, FLAG_ACK, 0)
	locks.lock(&c.wmu)
	if new_table >= 0 do hpack_encoder_set_peer_table_size(&c.enc, new_table)
	werr := netio.write(c.s, buf[:])
	locks.unlock(&c.wmu)
	return map_net_error(werr)
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

@(private)
pred_slot :: proc(c: ^H2_Conn, _: rawptr) -> bool {
	return c.active < c.peer_max_concurrent || c.goaway
}

@(private)
pred_done :: proc(c: ^H2_Conn, data: rawptr) -> bool {
	return (cast(^H2_Stream)data).done
}

@(private)
pred_window :: proc(c: ^H2_Conn, data: rawptr) -> bool {
	st := cast(^H2_Stream)data
	return st.done || (c.conn_send_window > 0 && st.send_window > 0)
}

// h2_open sends HEADERS (and the body, honouring flow control) and returns the
// stream; collect the response with h2_wait. Blocks while the peer's
// MAX_CONCURRENT_STREAMS is reached. Thread-safe.
h2_open :: proc(c: ^H2_Conn, req: Request) -> (st: ^H2_Stream, err: Error) {
	if !validate_h2_request(req) do return nil, .Bad_Request
	if !enter(c) do return nil, .Closed
	defer leave(c)

	locks.lock(&c.mu)
	drive_until(c, pred_slot, nil)
	if c.dead != .None {
		err = c.dead
		locks.unlock(&c.mu)
		return nil, err
	}
	if c.goaway {
		locks.unlock(&c.mu)
		return nil, .Goaway
	}
	c.active += 1
	locks.unlock(&c.mu)

	fields := make([dynamic]Header, 0, len(req.headers) + 4, context.temp_allocator)
	append(&fields, Header{":method", req.method})
	append(&fields, Header{":authority", req.authority})
	append(&fields, Header{":scheme", req.scheme})
	append(&fields, Header{":path", req.path})
	append(&fields, ..req.headers)
	has_body := len(req.body) > 0

	locks.lock(&c.wmu)
	locks.lock(&c.mu)
	if c.dead != .None || c.goaway || c.next_id > MAX_WINDOW {
		err = c.dead if c.dead != .None else .Goaway
		c.active -= 1
		locks.unlock(&c.mu)
		locks.unlock(&c.wmu)
		return nil, err
	}
	st = new(H2_Stream, c.allocator)
	st.id = c.next_id
	c.next_id += 2
	st.priority = spdy_priority(req.priority)
	st.send_window = c.peer_initial_window
	st.recv_window = c.our_stream_window
	st.resp = Response {
		version   = .Http2,
		allocator = c.allocator,
		headers   = make([dynamic]Header, 0, 16, c.allocator),
		trailers  = make([dynamic]Header, 0, 0, c.allocator),
		body      = make([dynamic]byte, 0, 0, c.allocator),
	}
	// Chrome Http2PriorityDependencies::OnStreamCreation
	parent: u32 = 0
	for i := int(st.priority); i >= 0; i -= 1 {
		if l := c.prio_lists[i]; len(l) > 0 {
			parent = l[len(l) - 1]
			break
		}
	}
	append(&c.prio_lists[st.priority], st.id)
	c.streams[st.id] = st
	max_frame := c.peer_max_frame
	locks.unlock(&c.mu)

	block := make([dynamic]byte, 0, 512, context.temp_allocator)
	hpack_encode(&c.enc, fields[:], &block)
	out := make([dynamic]byte, 0, len(block) + 32, context.temp_allocator)
	first_cap := max_frame - 5
	first := min(len(block), first_cap)
	hflags: u8 = FLAG_PRIORITY
	if !has_body do hflags |= FLAG_END_STREAM
	if first == len(block) do hflags |= FLAG_END_HEADERS
	put_frame_header(&out, first + 5, .Headers, hflags, st.id)
	put_u32(&out, parent | 0x80000000) // exclusive
	append(&out, u8(chrome_weight(st.priority) - 1))
	append(&out, ..block[:first])
	rest := block[first:]
	for len(rest) > 0 {
		n := min(len(rest), max_frame)
		put_frame_header(&out, n, .Continuation, FLAG_END_HEADERS if n == len(rest) else 0, st.id)
		append(&out, ..rest[:n])
		rest = rest[n:]
	}
	werr := map_net_error(netio.write(c.s, out[:]))
	locks.unlock(&c.wmu)
	if werr != .None {
		locks.lock(&c.mu)
		fail_conn_locked(c, werr)
		locks.cond_broadcast(&c.cond)
		locks.unlock(&c.mu)
		return st, .None // h2_wait reports the error
	}
	if !has_body {
		st.sent_end = true
		return st, .None
	}
	send_body(c, st, req.body)
	return st, .None
}

@(private)
send_body :: proc(c: ^H2_Conn, st: ^H2_Stream, body: []byte) {
	rest := body
	for len(rest) > 0 {
		locks.lock(&c.mu)
		drive_until(c, pred_window, st)
		if st.done || c.dead != .None {
			locks.unlock(&c.mu)
			return
		}
		n := min(len(rest), c.cfg.data_chunk, c.peer_max_frame, int(c.conn_send_window), int(st.send_window))
		c.conn_send_window -= i64(n)
		st.send_window -= i64(n)
		locks.unlock(&c.mu)
		last := n == len(rest)
		buf := make([dynamic]byte, 0, n + 9, context.temp_allocator)
		put_frame_header(&buf, n, .Data, FLAG_END_STREAM if last else 0, st.id)
		append(&buf, ..rest[:n])
		werr := write_locked_w(c, buf[:])
		if werr != .None {
			locks.lock(&c.mu)
			fail_conn_locked(c, werr)
			locks.cond_broadcast(&c.cond)
			locks.unlock(&c.mu)
			return
		}
		rest = rest[n:]
		if last do st.sent_end = true
	}
}

// h2_wait blocks until the stream's response is complete and returns it
// (caller owns it: response_destroy). The stream handle is freed.
h2_wait :: proc(c: ^H2_Conn, st: ^H2_Stream) -> (resp: Response, err: Error) {
	if !enter(c) do return {}, .Closed // stream is freed by h2_close
	defer leave(c)
	locks.lock(&c.mu)
	drive_until(c, pred_done, st)
	if !st.done do fail_stream_locked(c, st, c.dead if c.dead != .None else .Io, 0)
	delete_key(&c.streams, st.id)
	c.active -= 1
	resp = st.resp
	err = st.err
	sent_end := st.sent_end
	locks.cond_broadcast(&c.cond)
	locks.unlock(&c.mu)
	// Server finished before our body was fully sent: tell it we're done.
	if err == .None && !sent_end {
		buf := make([dynamic]byte, 0, 13, context.temp_allocator)
		put_rst(&buf, st.id, .No_Error)
		_ = write_locked_w(c, buf[:])
	}
	free(st, c.allocator)
	if err != .None {
		code := resp.h2_error
		response_destroy(&resp)
		resp.h2_error = code
	}
	return
}

// h2_request = h2_open + h2_wait.
h2_request :: proc(c: ^H2_Conn, req: Request) -> (Response, Error) {
	st, err := h2_open(c, req)
	if err != .None do return {}, err
	return h2_wait(c, st)
}

@(private)
pred_ping :: proc(c: ^H2_Conn, data: rawptr) -> bool {
	return c.ping_acks >= (cast(^int)data)^
}

// h2_ping sends a PING and waits for its ACK.
h2_ping :: proc(c: ^H2_Conn, payload: [8]byte = {}) -> Error {
	payload := payload
	if !enter(c) do return .Closed
	defer leave(c)
	locks.lock(&c.mu)
	want := c.ping_acks + 1
	locks.unlock(&c.mu)
	buf := make([dynamic]byte, 0, 17, context.temp_allocator)
	put_frame_header(&buf, 8, .Ping, 0, 0)
	append(&buf, ..payload[:])
	write_locked_w(c, buf[:]) or_return
	locks.lock(&c.mu)
	defer locks.unlock(&c.mu)
	drive_until(c, pred_ping, &want)
	return c.dead
}

@(private)
pred_never :: proc(c: ^H2_Conn, _: rawptr) -> bool {return false}

// h2_service reads and handles frames until the connection dies. Run it on a
// thread to keep an idle connection responsive (PING/SETTINGS/GOAWAY).
h2_service :: proc(c: ^H2_Conn) -> Error {
	if !enter(c) do return .Closed
	defer leave(c)
	locks.lock(&c.mu)
	defer locks.unlock(&c.mu)
	drive_until(c, pred_never, nil)
	return c.dead
}

// h2_can_open reports whether new streams may be opened on this connection.
h2_can_open :: proc(c: ^H2_Conn) -> bool {
	locks.lock(&c.mu)
	defer locks.unlock(&c.mu)
	return c.dead == .None && !c.goaway && c.next_id <= MAX_WINDOW
}
