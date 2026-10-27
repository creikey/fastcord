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

#if OS == .WINDOWS {
} else {
}

Setting :: struct {
	id: s32;
	value: u32;
}

CHROME_SETTINGS := Setting.[.{1, 65536}, .{2, 0}, .{4, CHROME_STREAM_WINDOW}, .{6, 262144}];
CHROME_STREAM_WINDOW :: 6291456;
CHROME_CONNECTION_WINDOW :: 15728640;
CHROME_CONNECTION_WINDOW_INCREMENT :: CHROME_CONNECTION_WINDOW - 65535;
#scope_module
CHROME_DATA_CHUNK :: 2 * 1430 - 9;
// Spdy3PriorityToHttp2Weight - 1 for each Priority, by its SPDY priority (Highest 0 .. Throttled 5).
// Spdy3PriorityToHttp2Weight - 1 for each Priority, by its SPDY priority (Highest 0 .. Throttled 5).
CHROME_SPDY_PRIORITY := ([#run enum_count(Priority)]u8).{
	__IDX__.Highest = 0,
	__IDX__.Medium = 1,
	__IDX__.Low = 2,
	__IDX__.Lowest = 3,
	__IDX__.Idle = 4,
	__IDX__.Throttled = 5
};
CHROME_WEIGHT := u8.[255, 219, 182, 146, 109, 73];

Ng_Session :: struct {}
Ng_Callbacks :: struct {}
Ng_Option :: struct {}

// nghttp2_frame_hd, the first member of every nghttp2_frame.
Ng_Frame_Hd :: struct {
	length: u64;
	stream_id: s32;
	type: u8;
	flags: u8;
	reserved: u8;
}

Ng_Data :: struct {
	hd: Ng_Frame_Hd;
	padlen: u64;
}

Ng_Settings :: struct {
	hd: Ng_Frame_Hd;
	niv: u64;
	iv: *Setting;
}

Ng_Nv :: struct {
	name, value: *u8;
	namelen, valuelen: u64;
	flags: u8;
}

Ng_Read_Proc :: #type (s: *Ng_Session, id: s32, buf: *u8, n: u64, flags: *u32, source: *void, user: *void) -> int #c_call;

Ng_Data_Provider :: struct {
	source: *void;
	read: Ng_Read_Proc;
}

NG_FRAME_DATA :: 0;
NG_FRAME_HEADERS :: 1;
NG_FRAME_SETTINGS :: 4;
NG_FRAME_PING :: 6;
NG_FRAME_CONTINUATION :: 9;
NG_FLAG_END_STREAM :: 0x1;
NG_FLAG_ACK :: 0x1;
NG_FLAG_END_HEADERS :: 0x4;
NG_FLAG_PRIORITY :: 0x20;
NG_DATA_FLAG_EOF :: 0x1;
NG_ERR_TEMPORAL_CALLBACK_FAILURE :: -521;
NG_ERR_START_STREAM_NOT_ALLOWED :: -516;
NG_REFUSED_STREAM :: 7;
NG_CANCEL :: 8;

// nghttp2's standalone HPACK coder: only the tests' fake server uses it.
Hd :: struct {}
	nghttp2_hd_deflate_new :: (d: **Hd, max_table: u64) -> s32 #foreign ng;
	nghttp2_hd_deflate_del :: (d: *Hd) #foreign ng;
	nghttp2_hd_deflate_bound :: (d: *Hd, nva: *Ng_Nv, n: u64) -> u64 #foreign ng;
	nghttp2_hd_deflate_hd2 :: (d: *Hd, buf: *u8, buflen: u64, nva: *Ng_Nv, n: u64) -> int #foreign ng;
	nghttp2_hd_inflate_new :: (i: **Hd) -> s32 #foreign ng;
	nghttp2_hd_inflate_del :: (i: *Hd) #foreign ng;
	nghttp2_hd_inflate_hd3 :: (i: *Hd, nv: *Ng_Nv, flags: *s32, data: *u8, n: u64, final: s32) -> int #foreign ng;
	nghttp2_hd_inflate_end_headers :: (i: *Hd) -> s32 #foreign ng;
	nghttp2_session_callbacks_new :: (cbs: **Ng_Callbacks) -> s32 #foreign ng;
	nghttp2_session_callbacks_del :: (cbs: *Ng_Callbacks) #foreign ng;
	nghttp2_session_callbacks_set_on_frame_recv_callback :: (cbs: *Ng_Callbacks, cb: (s: *Ng_Session, f: *Ng_Frame_Hd, user: *void) -> s32 #c_call) #foreign ng;
	nghttp2_session_callbacks_set_on_data_chunk_recv_callback :: (cbs: *Ng_Callbacks, cb: (s: *Ng_Session, flags: u8, id: s32, data: *u8, n: u64, user: *void) -> s32 #c_call) #foreign ng;
	nghttp2_session_callbacks_set_on_stream_close_callback :: (cbs: *Ng_Callbacks, cb: (s: *Ng_Session, id: s32, code: u32, user: *void) -> s32 #c_call) #foreign ng;
	nghttp2_session_callbacks_set_on_header_callback :: (cbs: *Ng_Callbacks, cb: (s: *Ng_Session, f: *Ng_Frame_Hd, name: *u8, namelen: u64, value: *u8, valuelen: u64, flags: u8, user: *void) -> s32 #c_call) #foreign ng;
	nghttp2_session_callbacks_set_on_frame_not_send_callback :: (cbs: *Ng_Callbacks, cb: (s: *Ng_Session, f: *Ng_Frame_Hd, code: s32, user: *void) -> s32 #c_call) #foreign ng;
	nghttp2_session_callbacks_set_data_source_read_length_callback2 :: (cbs: *Ng_Callbacks, cb: (s: *Ng_Session, type: u8, id: s32, conn_window: s32, stream_window: s32, max_frame: u32, user: *void) -> int #c_call) #foreign ng;
	nghttp2_option_new :: (opt: **Ng_Option) -> s32 #foreign ng;
	nghttp2_option_del :: (opt: *Ng_Option) #foreign ng;
	nghttp2_option_set_no_auto_window_update :: (opt: *Ng_Option, val: s32) #foreign ng;
	nghttp2_session_client_new2 :: (s: **Ng_Session, cbs: *Ng_Callbacks, user: *void, opt: *Ng_Option) -> s32 #foreign ng;
	nghttp2_session_del :: (s: *Ng_Session) #foreign ng;
	nghttp2_submit_settings :: (s: *Ng_Session, flags: u8, iv: *Setting, niv: u64) -> s32 #foreign ng;
	nghttp2_submit_window_update :: (s: *Ng_Session, flags: u8, id: s32, increment: s32) -> s32 #foreign ng;
	nghttp2_submit_request2 :: (s: *Ng_Session, pri_spec: *void, nva: *Ng_Nv, nvlen: u64, data: *Ng_Data_Provider, stream_user: *void) -> s32 #foreign ng;
	nghttp2_submit_rst_stream :: (s: *Ng_Session, flags: u8, id: s32, code: u32) -> s32 #foreign ng;
	nghttp2_session_terminate_session :: (s: *Ng_Session, code: u32) -> s32 #foreign ng;
	nghttp2_session_mem_recv2 :: (s: *Ng_Session, data: *u8, n: u64) -> int #foreign ng;
	nghttp2_session_mem_send2 :: (s: *Ng_Session, data: **u8) -> int #foreign ng;
	nghttp2_session_get_stream_user_data :: (s: *Ng_Session, id: s32) -> *void #foreign ng;
	nghttp2_session_set_stream_user_data :: (s: *Ng_Session, id: s32, data: *void) -> s32 #foreign ng;
	nghttp2_session_check_request_allowed :: (s: *Ng_Session) -> s32 #foreign ng;
	nghttp2_session_want_read :: (s: *Ng_Session) -> s32 #foreign ng;
	nghttp2_session_want_write :: (s: *Ng_Session) -> s32 #foreign ng;
#scope_export

H2_Config :: struct {
	max_response_body: int; // 0 -> 256 MiB
	max_header_block: int; // decoded header bytes per response; 0 -> 1 MiB
}
#scope_module

H2_Stream :: struct {
	id: s32;
	req: Request; // the caller's memory, for its HEADERS (sent before h2_request returns)
	body: []u8; // request body still to send; the caller's memory
	resp: Response;
	header_bytes: int;
	got_headers: bool; // final (non-1xx) response headers received
	done: bool; // response complete or failed (err)
	err: Error;
	in_tree: bool; // listed in H2_Conn.tree (its HEADERS went out, not yet done)
	unacked: int; // received bytes not yet given back in a WINDOW_UPDATE
	acked_at: time.Tick;
}
#scope_export

H2_Conn :: struct {
	s: netio.Stream;
	allocator: Allocator;
	cfg: H2_Config;
	mu: locks.Mutex;
	cond: locks.Cond;
	wmu: locks.Mutex;
	session: *Ng_Session; // under mu
	streams: Map(s32, *H2_Stream); // under mu
	rbuf: []u8; // reader only
	wbuf, out: [..]u8; // under wmu and mu: nghttp2's output, then what goes on the wire
	sent_preface: bool; // under wmu and mu
	enc: Hpack_Encoder; // under mu
	tree: [6][..]s32; // under mu: open streams by SPDY priority, oldest first
	unacked: int; // under mu: connection bytes not yet given back
	acked_at: time.Tick; // under mu
	last_read: time.Tick; // under mu
	ping_in_flight: bool; // under mu
	next_ping: u64; // under mu
	reading: bool;
	users: int; // threads inside public h2_* calls (h2_close waits for 0)
	closing: bool;
	dead: Error;
}

// h2_connect sends the client preface, Chrome's SETTINGS and WINDOW_UPDATE (one write).
h2_connect :: (s: netio.Stream, cfg := H2_Config.{}, allocator := context.allocator) -> *H2_Conn, Error {
	c: *H2_Conn;
	err: Error;
	context.allocator = allocator;
	c = new(H2_Conn);
	c.s = s;
	c.allocator = allocator;
	c.cfg = cfg;
	if c.cfg.max_response_body <= 0 { c.cfg.max_response_body = 256 << 20; }
	if c.cfg.max_header_block <= 0 { c.cfg.max_header_block = 1 << 20; }
	c.streams = Map(s32, *H2_Stream).{};
	c.rbuf = make_slice(u8, 8 * 1024); // Chrome's kReadBufferSize: window updates follow its reads.
	c.wbuf = make_dynamic(u8, 0, 0);
	c.out = make_dynamic(u8, 0, 0);
	hpack_init(*c.enc, allocator);
	for * l: c.tree { l = make_dynamic(s32, 0, 0); }
	c.acked_at = time.tick_now();
	c.last_read = c.acked_at;
	c.next_ping = 1;
	cbs: *Ng_Callbacks;
	if nghttp2_session_callbacks_new(*cbs) != 0 { panic("nghttp2: out of memory"); }
	nghttp2_session_callbacks_set_on_frame_recv_callback(cbs, on_frame_recv);
	nghttp2_session_callbacks_set_on_data_chunk_recv_callback(cbs, on_data_chunk);
	nghttp2_session_callbacks_set_on_stream_close_callback(cbs, on_stream_close);
	nghttp2_session_callbacks_set_on_header_callback(cbs, on_header);
	nghttp2_session_callbacks_set_on_frame_not_send_callback(cbs, on_not_sent);
	nghttp2_session_callbacks_set_data_source_read_length_callback2(cbs, data_chunk_len);
	opt: *Ng_Option;
	if nghttp2_option_new(*opt) != 0 { panic("nghttp2: out of memory"); }
	nghttp2_option_set_no_auto_window_update(opt, 1); // give_back() sends them, as Chrome does.
	rv := nghttp2_session_client_new2(*c.session, cbs, c, opt);
	nghttp2_option_del(opt);
	nghttp2_session_callbacks_del(cbs);
	if rv != 0 { panic("nghttp2: out of memory"); }
	nghttp2_submit_settings(c.session, 0, raw_data(view(CHROME_SETTINGS)), len(CHROME_SETTINGS));
	nghttp2_submit_window_update(c.session, 0, 0, CHROME_CONNECTION_WINDOW_INCREMENT);
	{ err = flush(c);
	if err != .None {
		h2_destroy(c);
		return null, err;
	} }
	return c, .None;
}

// h2_close sends GOAWAY, shuts the stream down (waking a thread blocked reading
// it), waits for every thread inside the connection to leave, then closes the
// stream and frees the connection. Threads blocked in h2_request/h2_service get
// .Closed. No calls may start after h2_close. If the stream has no shutdown
// hook and a reader stays blocked for 5 s, the connection is leaked rather than
// freed under that reader.
h2_close :: (c: *H2_Conn) {
	locks.lock(*c.mu);
	alive := c.dead == .None;
	if alive { nghttp2_session_terminate_session(c.session, 0); }
	locks.unlock(*c.mu);
	if alive { flush(c); }
	netio.shutdown(c.s);
	locks.lock(*c.mu);
	fail_conn_locked(c, .Closed);
	locks.cond_broadcast(*c.cond);
	deadline := time.tick_now();
	c.closing = true;
	while c.reading || c.users > 0 {
		if time.tick_since(deadline) > 5 * time.Second {
			locks.unlock(*c.mu);
			return; // leak: a reader is still blocked inside the stream
		}
		locks.cond_wait_with_timeout(*c.cond, *c.mu, 100 * time.Millisecond);
	}
	locks.unlock(*c.mu);
	netio.close(c.s);
	h2_destroy(c);
}
#scope_module

h2_destroy :: (c: *H2_Conn) {
	context.allocator = c.allocator;
	nghttp2_session_del(c.session);
	for _, st: c.streams {
		response_destroy(*st.resp);
		free(st);
	}
	delete(c.streams);
	delete(c.rbuf);
	delete(c.wbuf);
	delete(c.out);
	hpack_destroy(*c.enc);
	for l: c.tree { delete(l); }
	free(c);
}

// ---- nghttp2 callbacks: called from nghttp2_session_mem_recv2/mem_send2 with mu held ----

// A stream's user data is its H2_Stream until h2_request clears it, so these
// never see a freed stream: nil means the caller has gone.
stream_of :: (s: *Ng_Session, id: s32) -> *H2_Stream #no_context {
	return cast(*H2_Stream)nghttp2_session_get_stream_user_data(s, id);
}

finish :: (c: *H2_Conn, st: *H2_Stream, err: Error, code: u32) {
	if st.done { return; }
	st.done = true;
	st.err = err;
	st.resp.h2_error = code;
	if !st.in_tree { return; }
	l := *c.tree[CHROME_SPDY_PRIORITY[st.req.priority]];
	for id, i: l { if id == st.id {
		ordered_remove(l, i);
		break;
	} }
}

// give_back returns received bytes to the windows as Chrome's IncreaseRecvWindowSize does: a
// WINDOW_UPDATE once more than half the window is unacked or 5 s passed since the last one; the
// connection's first.
give_back :: (c: *H2_Conn, st: *H2_Stream, id: s32, n: int) {
	now := time.tick_now();
	c.unacked += n;
	if c.unacked > CHROME_CONNECTION_WINDOW / 2 || time.tick_diff(c.acked_at, now) >= 5 * time.Second {
		nghttp2_submit_window_update(c.session, 0, 0, cast(s32)(c.unacked));
		c.unacked, c.acked_at = 0, now;
	}
	if st == null { return; }
	st.unacked += n;
	if st.unacked > CHROME_STREAM_WINDOW / 2 || time.tick_diff(st.acked_at, now) >= 5 * time.Second {
		nghttp2_submit_window_update(c.session, 0, id, cast(s32)(st.unacked));
		st.unacked, st.acked_at = 0, now;
	}
}

on_header :: (s: *Ng_Session, f: *Ng_Frame_Hd, name: *u8, namelen: u64, value: *u8, valuelen: u64, flags: u8, user: *void) -> s32 #c_call {
	conn := cast(*H2_Conn)user;
	st := stream_of(s, f.stream_id);
	if f.type != NG_FRAME_HEADERS || st == null || st.done { return 0; }
	__ctx1: #Context; push_context,defer_pop __ctx1;
	context.allocator = conn.allocator;
	st.header_bytes += cast(int)(namelen + valuelen) + 32;
	if st.header_bytes > conn.cfg.max_header_block {
		finish(conn, st, .Too_Large, NG_CANCEL); // h2_request resets the stream
		return 0;
	}
	n, v := as_string(sub(name, 0, namelen)), as_string(sub(value, 0, valuelen));
	if n == ":status" {
		st.resp.status = cast(int)(v[0] - #char "0") * 100 + cast(int)(v[1] - #char "0") * 10 + cast(int)(v[2] - #char "0"); // nghttp2 checked: 3 digits
	} else {
		append(ifx st.got_headers then *st.resp.trailers else *st.resp.headers, Header.{clone(n), clone(v)});
	}
	return 0;
}

on_frame_recv :: (s: *Ng_Session, f: *Ng_Frame_Hd, user: *void) -> s32 #c_call {
	conn := cast(*H2_Conn)user;
	__ctx2: #Context; push_context,defer_pop __ctx2;
	if f.type == NG_FRAME_SETTINGS && f.flags & NG_FLAG_ACK == 0 {
		set := cast(*Ng_Settings)f;
		for iv: sub(set.iv, 0, set.niv) { if iv.id == 1 { hpack_set_table_size(*conn.enc, cast(int)(iv.value)); } }
	} else if f.type == NG_FRAME_PING && f.flags & NG_FLAG_ACK != 0 {
		conn.ping_in_flight = false;
	}
	if f.type != NG_FRAME_HEADERS && f.type != NG_FRAME_DATA { return 0; }
	st := stream_of(s, f.stream_id);
	if st != null && st.done { st = null; }
	// Chrome counts padding as consumed at once.
	{ pad := cast(int)((cast(*Ng_Data)f).padlen);
	if f.type == NG_FRAME_DATA && pad > 0 { give_back(conn, st, f.stream_id, pad); } }
	if st == null { return 0; }
	if f.type == NG_FRAME_HEADERS && !st.got_headers {
		if st.resp.status < 200 {
			// Interim response (100/103): drop it and wait for the final one.
			clear_headers(*st.resp);
			st.resp.status = 0;
			return 0;
		}
		st.got_headers = true;
	}
	if f.flags & NG_FLAG_END_STREAM != 0 { finish(conn, st, .None, 0); }
	return 0;
}

on_data_chunk :: (s: *Ng_Session, flags: u8, id: s32, data: *u8, n: u64, user: *void) -> s32 #c_call {
	conn := cast(*H2_Conn)user;
	__ctx4: #Context; push_context,defer_pop __ctx4;
	st := stream_of(s, id);
	if st != null && st.done { st = null; }
	give_back(conn, st, id, cast(int)(n));
	if st == null { return 0; }
	if len(st.resp.body) + cast(int)(n) > conn.cfg.max_response_body {
		finish(conn, st, .Too_Large, NG_CANCEL); // h2_request resets the stream
		return 0;
	}
	append(*st.resp.body, ..sub(data, 0, n));
	return 0;
}

on_stream_close :: (s: *Ng_Session, id: s32, code: u32, user: *void) -> s32 #c_call {
	__ctx5: #Context; push_context,defer_pop __ctx5;
	{ st := stream_of(s, id);
	if st != null { finish(cast(*H2_Conn)user, st, ifx code == NG_REFUSED_STREAM then .Refused else .Stream_Reset, code); } }
	return 0;
}

// A queued request nghttp2 drops unsent (GOAWAY arrived first) never opens a
// stream, so on_stream_close won't see it.
on_not_sent :: (s: *Ng_Session, f: *Ng_Frame_Hd, code: s32, user: *void) -> s32 #c_call {
	conn := cast(*H2_Conn)user;
	__ctx6: #Context; push_context,defer_pop __ctx6;
	{ st := get(conn.streams, f.stream_id);
	if f.type == NG_FRAME_HEADERS && st != null {
		if code == NG_ERR_START_STREAM_NOT_ALLOWED { finish(conn, st, .Refused, NG_REFUSED_STREAM); } else { finish(conn, st, .Io, 0); }
	} }
	return 0;
}

read_body :: (s: *Ng_Session, id: s32, buf: *u8, n: u64, flags: *u32, source: *void, user: *void) -> int #c_call {
	st := stream_of(s, id);
	if st == null { return NG_ERR_TEMPORAL_CALLBACK_FAILURE; }
	k := min(cast(int)(n), len(st.body));
	mem.copy(buf, raw_data(st.body), k);
	st.body = sub_from(st.body, k);
	if len(st.body) == 0 { flags.* |= NG_DATA_FLAG_EOF; }
	return k;
}

data_chunk_len :: (s: *Ng_Session, type: u8, id: s32, conn_window: s32, stream_window: s32, max_frame: u32, user: *void) -> int #c_call {
	return cast(int)(min(cast(s32)(CHROME_DATA_CHUNK), conn_window, stream_window, cast(s32)(max_frame)));
}

// ---- I/O ----

// flush writes everything nghttp2 has queued, in one write.
flush :: (c: *H2_Conn) -> Error {
	locks.lock(*c.wmu);
	defer locks.unlock(*c.wmu);
	clear(*c.wbuf);
	locks.lock(*c.mu);
	while c.dead == .None {
		p: *u8;
		n := nghttp2_session_mem_send2(c.session, *p);
		if n <= 0 { break; }
		append(*c.wbuf, ..sub(p, 0, n));
	}
	rewrite_frames(c);
	locks.unlock(*c.mu);
	if len(c.out) == 0 { return .None; }
	return map_net_error(netio.write(c.s, view(c.out)));
}

// rewrite_frames copies nghttp2's output (whole frames) to c.out, replacing each HEADERS and its
// CONTINUATIONs with Chrome's: hpack.odin's block, PRIORITY, 16383-byte frames (kHttp2MaxControlFrameSendSize).
rewrite_frames :: (c: *H2_Conn) {
	put_u32 :: (out: *[..]u8, v: u32) {append(out, cast(u8)(v >> 24), cast(u8)(v >> 16), cast(u8)(v >> 8), cast(u8)(v));}
	clear(*c.out);
	b := view(c.wbuf);
	if !c.sent_preface && len(b) >= 24 {
		append(*c.out, ..sub(b, 0, 24));
		b = sub_from(b, 24);
		c.sent_preface = true;
	}
	block := make_dynamic(u8, 0, 0, c.allocator);
	defer delete(block);
	while len(b) >= 9 {
		n := 9 + (cast(int)(b[0]) << 16 | cast(int)(b[1]) << 8 | cast(int)(b[2]));
		type, flags := b[3], b[4];
		id := cast(s32)((cast(u32)(b[5]) << 24 | cast(u32)(b[6]) << 16 | cast(u32)(b[7]) << 8 | cast(u32)(b[8])) & 0x7fffffff);
		frame := sub(b, 0, n);
		b = sub_from(b, n);
		if type == NG_FRAME_HEADERS || type == NG_FRAME_DATA && n > 9 { preface_ping(c); }
		if type == NG_FRAME_CONTINUATION { continue; }
		st := get(c.streams, id);
		if type != NG_FRAME_HEADERS || st == null {
			append(*c.out, ..frame);
			continue;
		}
		p := CHROME_SPDY_PRIORITY[st.req.priority];
		parent: s32;
		for < i: cast(int)(p)..0 && parent == 0 { if len(c.tree[i]) > 0 { parent = c.tree[i][len(c.tree[i]) - 1]; } }
		if !st.done {
			append(*c.tree[p], id);
			st.in_tree = true;
		}
		clear(*block);
		hpack_encode(*c.enc, *block, st.req);
		rest := view(block);
		{ first := true;
		while true {
			k := min(len(rest), 16383 - 9 - (ifx first then 5 else 0));
			end: u8 = ifx k == len(rest) then NG_FLAG_END_HEADERS else 0;
			plen := cast(u32)(k + (ifx first then 5 else 0));
			append(*c.out, cast(u8)(plen >> 16), cast(u8)(plen >> 8), cast(u8)(plen));
			if first {
				append(*c.out, NG_FRAME_HEADERS, flags & NG_FLAG_END_STREAM | NG_FLAG_PRIORITY | end);
				put_u32(*c.out, cast(u32)(id));
				put_u32(*c.out, cast(u32)(parent) | 0x80000000);
				append(*c.out, CHROME_WEIGHT[p]);
			} else {
				append(*c.out, NG_FRAME_CONTINUATION, end);
				put_u32(*c.out, cast(u32)(id));
			}
			append(*c.out, ..sub(rest, 0, k));
			rest = sub_from(rest, k);
			if end != 0 { break; }
			first = false;
} }
	}
}

// preface_ping is Chrome's MaybeSendPrefacePing: a PING ahead of a request when nothing was read for 10 s.
preface_ping :: (c: *H2_Conn) {
	if c.ping_in_flight || time.tick_since(c.last_read) <= 10 * time.Second { return; }
	append(*c.out, 0, 0, 8, NG_FRAME_PING, 0, 0, 0, 0, 0);
	for i: 0..7 { append(*c.out, cast(u8)(c.next_ping >> cast(u64)(56 - 8 * i))); }
	c.ping_in_flight = true;
	c.next_ping += 1;
}

// read_once reads what the socket has, gives it to nghttp2 and sends its replies.
// Called by the reading leader without mu.
read_once :: (c: *H2_Conn) -> Error {
	n, rerr := netio.read(c.s, c.rbuf);
	if rerr != .None { return map_net_error(rerr); }
	locks.lock(*c.mu);
	c.last_read = time.tick_now();
	rv := nghttp2_session_mem_recv2(c.session, raw_data(c.rbuf), cast(u64)(n));
	locks.unlock(*c.mu);
	ferr := flush(c); // on a connection error this sends nghttp2's GOAWAY
	if rv < 0 { return .Protocol; }
	if ferr != .None { return ferr; }
	// nghttp2 is done once a GOAWAY went either way and no streams remain, or it
	// sent one for a protocol error.
	locks.lock(*c.mu);
	defer locks.unlock(*c.mu);
	return ifx nghttp2_session_want_read(c.session) == 0 && nghttp2_session_want_write(c.session) == 0 then .Goaway else .None;
}

// enter/leave bracket every public call so h2_close can wait for callers.
enter :: (c: *H2_Conn) -> bool {
	locks.lock(*c.mu);
	defer locks.unlock(*c.mu);
	if c.closing { return false; }
	c.users += 1;
	return true;
}

leave :: (c: *H2_Conn) {
	locks.lock(*c.mu);
	c.users -= 1;
	locks.cond_broadcast(*c.cond);
	locks.unlock(*c.mu);
}

fail_conn_locked :: (c: *H2_Conn, err: Error) {
	if c.dead == .None { c.dead = err; }
	for _, st: c.streams { finish(c, st, c.dead, 0); }
}

// drive_until: called and returns with c.mu held; st == nil waits until the connection dies.
drive_until :: (c: *H2_Conn, st: *H2_Stream) {
	while st == null || !st.done {
		if c.dead != .None { return; }
		if !c.reading {
			c.reading = true;
			locks.unlock(*c.mu);
			err := read_once(c);
			locks.lock(*c.mu);
			c.reading = false;
			if err != .None { fail_conn_locked(c, err); }
			locks.cond_broadcast(*c.cond);
		} else {
			locks.cond_wait(*c.cond, *c.mu);
		}
	}
}

// ---- requests ----

// ---- requests ----

FORBIDDEN_H2_HEADERS := string.["connection", "keep-alive", "proxy-connection", "transfer-encoding", "upgrade"];

validate_h2_request :: (req: Request) -> bool {
	if len(req.method) == 0 || len(req.path) == 0 || len(req.scheme) == 0 { return false; }
	for h: req.headers {
		if len(h.name) == 0 || h.name[0] == #char ":" { return false; }
		for ch: transmute([]u8, h.name) {
			if ch >= #char "A" && ch <= #char "Z" { return false; }
			if ch <= #char " " || ch >= 0x7f { return false; }
		}
		if !valid_value(h.value) { return false; }
		for f: FORBIDDEN_H2_HEADERS { if h.name == f { return false; } }
		if h.name == "te" && h.value != "trailers" { return false; }
	}
	return true;
}
#scope_export

// h2_request sends req and blocks until its response is complete (caller owns
// it: response_destroy). nghttp2 holds the request back while the server's
// MAX_CONCURRENT_STREAMS is reached. Thread-safe.
h2_request :: (c: *H2_Conn, req: Request) -> Response, Error {
	resp: Response;
	err: Error;
	if !validate_h2_request(req) { return .{}, .Bad_Request; }
	if !enter(c) { return .{}, .Closed; }
	defer leave(c);

	nva := make_dynamic(Ng_Nv, 0, len(req.headers) + 4, temp);
	nv :: (n: string, v: string) -> Ng_Nv {return .{raw_data(n), raw_data(v), len(n), len(v), 0};}
	append(*nva, nv(":method", req.method), nv(":authority", req.authority), nv(":scheme", req.scheme), nv(":path", req.path));
	for h: req.headers { append(*nva, nv(h.name, h.value)); }

	st := new(H2_Stream, c.allocator);
	st.req = req;
	st.body = req.body;
	st.acked_at = time.tick_now();
	st.resp = Response.{
		version = .Http2,
		allocator = c.allocator,
		headers = make_dynamic(Header, 0, 16, c.allocator),
		trailers = make_dynamic(Header, 0, 0, c.allocator),
		body = make_dynamic(u8, 0, 0, c.allocator)
	};
	body := Ng_Data_Provider.{read = read_body};
	locks.lock(*c.mu);
	if c.dead != .None || nghttp2_session_check_request_allowed(c.session) == 0 {
		err = ifx c.dead != .None then c.dead else .Goaway;
		locks.unlock(*c.mu);
		response_destroy(*st.resp);
		free(st, c.allocator);
		return .{}, err;
	}
	// nghttp2 copies the header names and values.
	st.id = nghttp2_submit_request2(c.session, null, raw_data(nva), len(nva), ifx len(req.body) > 0 then *body else null, st);
	if st.id < 0 {
		locks.unlock(*c.mu);
		response_destroy(*st.resp);
		free(st, c.allocator);
		return .{}, .Goaway;
	}
	at(*c.streams, st.id).* = st;
	locks.unlock(*c.mu);
	{ werr := flush(c);
	if werr != .None {
		locks.lock(*c.mu);
		fail_conn_locked(c, werr);
		locks.cond_broadcast(*c.cond);
		locks.unlock(*c.mu);
	} }

	locks.lock(*c.mu);
	drive_until(c, st);
	if !st.done { finish(c, st, ifx c.dead != .None then c.dead else .Io, 0); }
	delete_key(*c.streams, st.id);
	// The stream may outlive this call (our body still sending, or a reset not yet
	// sent): detach it so nghttp2 never reads req.body or st again, and end it.
	// A request nghttp2 still holds queued (the connection died first) has no
	// stream yet; set_stream_user_data also clears its queued copy of st.
	reset := stream_of(c.session, st.id) != null && c.dead == .None;
	nghttp2_session_set_stream_user_data(c.session, st.id, null);
	if reset { nghttp2_submit_rst_stream(c.session, 0, st.id, ifx st.err == .None then 0 else NG_CANCEL); }
	locks.cond_broadcast(*c.cond);
	locks.unlock(*c.mu);
	if reset { flush(c); }
	resp, err = st.resp, st.err;
	free(st, c.allocator);
	if err != .None {
		code := resp.h2_error;
		response_destroy(*resp);
		resp.h2_error = code;
	}
	return resp, err;
}

// h2_service reads and handles frames until the connection dies. Run it on a
// thread to keep an idle connection responsive (PING/SETTINGS/GOAWAY).
h2_service :: (c: *H2_Conn) -> Error {
	if !enter(c) { return .Closed; }
	defer leave(c);
	locks.lock(*c.mu);
	defer locks.unlock(*c.mu);
	drive_until(c, null);
	return c.dead;
}

// h2_can_open reports whether new streams may be opened on this connection.
h2_can_open :: (c: *H2_Conn) -> bool {
	locks.lock(*c.mu);
	defer locks.unlock(*c.mu);
	return c.dead == .None && nghttp2_session_check_request_allowed(c.session) != 0;
}

