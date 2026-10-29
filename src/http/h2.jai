// HTTP/2 client: framing, HPACK, flow control, stream states and validation of everything the server
// sends are nghttp2's (vendor/nghttp2). This file feeds it bytes, sends what it queues, and lets many
// threads share one connection.
//
// Threading model ("leader/follower", no background thread required):
//   - Any number of threads may call h2_request on one H2_Conn concurrently.
//   - Every nghttp2 call happens under `mu`. Socket writes happen under `wmu` (taken before `mu`), so
//     frames go out in the order nghttp2 queued them.
//   - Whichever thread is waiting (for its response) and finds nobody reading becomes the reader: it
//     blocks in netio.read without `mu`, hands the bytes to nghttp2, sends what nghttp2 queued in reply,
//     broadcasts, and re-checks. Other waiters sleep on `cond`. Call h2_service() from a thread to keep an
//     idle connection responsive (PING/SETTINGS/GOAWAY).
//   - Requirement on the Stream: one concurrent reader + one concurrent writer (full duplex) must be
//     safe. Plain TCP and Pipe are; TLS must be too.
//
// Chrome parity (verified against a Chrome 148 netlog of the official client):
//   - preface + SETTINGS [1:65536, 2:0, 4:6291456, 6:262144] in that order
//   - WINDOW_UPDATE stream 0 increment 15663105 (window 15728640)
//   - pseudo-header order :method :authority :scheme :path
//   - request bodies sent in DATA frames of at most 2851 bytes (2*MSS - 9)
// Chrome behaviours nghttp2 lacks, done in rewrite_frames and give_back (from Chrome 148's net/spdy and
// quiche sources, not directly visible in a netlog):
//   - HEADERS blocks from hpack.jai, with the PRIORITY flag: exclusive, weight from Request.priority,
//     parent from Http2PriorityDependencies; split at 16383-byte frames
//   - receive windows acked once more than half is unacked or 5 s after the last update, counted per
//     8 KiB read; DATA for a stream already closed counts toward the connection's too
//   - a PING before HEADERS or DATA when nothing was read for 10 s; if it stays unanswered and nothing
//     is read for 10 s, GOAWAY (PROTOCOL_ERROR, "Failed ping.") and the connection closes
//
// H2_Config.hyper speaks as hyper 1's client (the h2 0.4 crate, with the defaults reqwest 0.12 leaves) does
// for the native updater instead, from their sources (traffic/CLIENT_RULES.md):
//   - the preface in a write of its own, then SETTINGS [2:0, 4:2097152, 5:16384, 6:16384] and WINDOW_UPDATE
//     stream 0 increment 5177345 (window 5 MiB)
//   - HEADERS with the h2 crate's HPACK (hpack.jai), no PRIORITY, split at 16384-byte frames
//   - each DATA frame given back as the body reads it: a WINDOW_UPDATE once the bytes given back reach half
//     of what is left of the window (FlowControl::unclaimed_capacity), the connection's first; none for a
//     stream the server has ended
//   - no PINGs; h2_close sends GOAWAY then close_notify

Setting :: struct {
	id: s32;
	value: u32;
}

CHROME_SETTINGS := Setting.[.{1, 65536}, .{2, 0}, .{4, CHROME_STREAM_WINDOW}, .{6, 262144}];
CHROME_STREAM_WINDOW :: 6291456;
CHROME_CONNECTION_WINDOW :: 15728640;
CHROME_CONNECTION_WINDOW_INCREMENT :: CHROME_CONNECTION_WINDOW - 65535;

HYPER_SETTINGS := Setting.[.{2, 0}, .{4, HYPER_STREAM_WINDOW}, .{5, 16384}, .{6, 16384}];
HYPER_STREAM_WINDOW :: 2 * 1024 * 1024;
HYPER_CONNECTION_WINDOW :: 5 * 1024 * 1024;

H2_Config :: struct {
	max_response_body: int; // 0 -> 256 MiB
	max_header_block: int;  // decoded header bytes per response; 0 -> 1 MiB
	hyper: bool;            // hyper's client, not Chrome's
}

H2_Conn :: struct {
	s: netio.Stream;
	allocator: Allocator;
	cfg: H2_Config;
	mu: locks.Mutex;
	cond: locks.Cond;
	wmu: locks.Mutex;
	ctx: *#Context;                    // under mu: the context nghttp2's callbacks run in
	session: *Ng_Session;              // under mu
	streams: Table(s32, *H2_Stream);   // under mu
	rbuf: []u8;                        // reader only
	wbuf, out: [..]u8;                 // under wmu and mu: nghttp2's output, then what goes on the wire
	block: [..]u8;                     // under mu: a HEADERS block being rewritten
	sent_preface: bool;                // under wmu and mu
	enc: Hpack_Encoder;                // under mu
	tree: [6][..]s32;                  // under mu: open streams by SPDY priority, oldest first
	unacked: int;                      // under mu: connection bytes not yet given back
	acked_at: Apollo_Time;             // under mu
	last_read: Apollo_Time;            // under mu
	ping_in_flight: bool;              // under mu
	ping_at: Apollo_Time;              // under mu: when the PING in flight went out
	next_ping: u64;                    // under mu
	reading: bool;
	users: int;                        // threads inside public h2_* calls (h2_close waits for 0)
	closing: bool;
	dead: Error;
}

// h2_connect sends the client preface, Chrome's SETTINGS and WINDOW_UPDATE (one write). The connection
// and its responses live in context.allocator, which must be safe to use from any thread.
h2_connect :: (s: netio.Stream, cfg := H2_Config.{}) -> *H2_Conn, Error {
	a := context.allocator;
	c := New(H2_Conn);
	c.s, c.allocator, c.cfg = s, a, cfg;
	if c.cfg.max_response_body <= 0 c.cfg.max_response_body = 256 << 20;
	if c.cfg.max_header_block <= 0 c.cfg.max_header_block = 1 << 20;
	c.streams.allocator = a;
	c.rbuf = NewArray(8 * 1024, u8, initialized = false); // Chrome's kReadBufferSize: window updates follow its reads.
	c.wbuf.allocator, c.out.allocator, c.block.allocator = a, a, a;
	c.enc.allocator, c.enc.table.allocator = a, a;
	c.enc.hyper = cfg.hyper;
	for * c.tree it.allocator = a;
	c.acked_at = current_time_monotonic();
	c.last_read = c.acked_at;
	c.next_ping = 1;
	cbs: *Ng_Callbacks;
	if nghttp2_session_callbacks_new(*cbs) != 0 assert(false, "nghttp2: out of memory");
	nghttp2_session_callbacks_set_on_begin_frame_callback(cbs, on_begin_frame);
	nghttp2_session_callbacks_set_on_frame_recv_callback(cbs, on_frame_recv);
	nghttp2_session_callbacks_set_on_data_chunk_recv_callback(cbs, on_data_chunk);
	nghttp2_session_callbacks_set_on_stream_close_callback(cbs, on_stream_close);
	nghttp2_session_callbacks_set_on_header_callback(cbs, on_header);
	nghttp2_session_callbacks_set_on_frame_not_send_callback(cbs, on_not_sent);
	nghttp2_session_callbacks_set_data_source_read_length_callback2(cbs, data_chunk_len);
	opt: *Ng_Option;
	if nghttp2_option_new(*opt) != 0 assert(false, "nghttp2: out of memory");
	nghttp2_option_set_no_auto_window_update(opt, 1); // give_back() sends them, as Chrome does.
	rv := nghttp2_session_client_new2(*c.session, cbs, c, opt);
	nghttp2_option_del(opt);
	nghttp2_session_callbacks_del(cbs);
	assert(rv == 0, "nghttp2: out of memory");
	c.ctx = *context;
	settings := ifx cfg.hyper then HYPER_SETTINGS else CHROME_SETTINGS;
	nghttp2_submit_settings(c.session, 0, settings.data, xx settings.count);
	nghttp2_submit_window_update(c.session, 0, 0, xx ifx cfg.hyper then HYPER_CONNECTION_WINDOW - 65535 else CHROME_CONNECTION_WINDOW_INCREMENT);
	err := flush(c);
	if err != .None {
		h2_destroy(c);
		return null, err;
	}
	return c, .None;
}

// h2_close sends GOAWAY, shuts the stream down (waking a thread blocked reading it), waits for every
// thread inside the connection to leave, then closes the stream and frees the connection. Threads blocked
// in h2_request/h2_service get .Closed. No calls may start after h2_close. If the stream has no shutdown
// hook and a reader stays blocked for 5 s, the connection is leaked rather than freed under that reader.
h2_close :: (c: *H2_Conn) {
	lock(c);
	alive := c.dead == .None;
	if alive nghttp2_session_terminate_session(c.session, 0);
	// hyper's connection ends with close_notify: shutting the stream down only wakes a reader
	wake := c.reading || !c.cfg.hyper;
	locks.unlock(*c.mu);
	if alive flush(c);
	if wake netio.shutdown(c.s);
	lock(c);
	fail_conn_locked(c, .Closed);
	locks.cond_broadcast(*c.cond);
	start := current_time_monotonic();
	c.closing = true;
	while c.reading || c.users > 0 {
		if current_time_monotonic() - start > seconds_to_apollo(5) {
			locks.unlock(*c.mu);
			return; // leak: a reader is still blocked inside the stream
		}
		locks.cond_wait_with_timeout(*c.cond, *c.mu, 100);
	}
	locks.unlock(*c.mu);
	netio.close(c.s);
	h2_destroy(c);
}

// h2_abort fails the connection now without waiting: requests in flight end with .Closed and the reader
// wakes (after sleep or a network change the socket may be dead with nothing to notice it). h2_close
// still frees it.
h2_abort :: (c: *H2_Conn) {
	netio.shutdown(c.s);
	lock(c);
	fail_conn_locked(c, .Closed);
	locks.cond_broadcast(*c.cond);
	locks.unlock(*c.mu);
}

// h2_request sends req and blocks until its response is complete (caller owns it: response_destroy).
// nghttp2 holds the request back while the server's MAX_CONCURRENT_STREAMS is reached. Thread-safe.
h2_request :: (c: *H2_Conn, req: Request) -> Response, Error {
	if !validate_h2_request(req) return .{}, .Bad_Request;
	if !enter(c) return .{}, .Closed;
	defer leave(c);

	nva := NewArray(req.headers.count + 4, Ng_Nv,, temp);
	nv :: (n: string, v: string) -> Ng_Nv { return .{n.data, v.data, xx n.count, xx v.count, 0}; }
	nva[0], nva[1], nva[2], nva[3] = nv(":method", req.method), nv(":authority", req.authority), nv(":scheme", req.scheme), nv(":path", req.path);
	for req.headers nva[it_index + 4] = nv(it.name, it.value);

	st := New(H2_Stream,, c.allocator);
	st.req = req;
	st.body = req.body;
	st.acked_at = current_time_monotonic();
	st.resp = make_response(.Http2,, c.allocator);
	body := Ng_Data_Provider.{read = read_body};
	lock(c);
	if c.dead != .None || nghttp2_session_check_request_allowed(c.session) == 0 {
		err := ifx c.dead != .None then c.dead else .Goaway;
		locks.unlock(*c.mu);
		free(st,, c.allocator);
		return .{}, err;
	}
	// nghttp2 copies the header names and values.
	st.id = nghttp2_submit_request2(c.session, null, nva.data, xx nva.count, ifx req.body.count then *body else null, st);
	if st.id < 0 {
		locks.unlock(*c.mu);
		free(st,, c.allocator);
		return .{}, .Goaway;
	}
	table_set(*c.streams, st.id, st);
	locks.unlock(*c.mu);
	werr := flush(c);
	if werr != .None {
		lock(c);
		fail_conn_locked(c, werr);
		locks.cond_broadcast(*c.cond);
		locks.unlock(*c.mu);
	}

	lock(c);
	drive_until(c, st);
	if !st.done finish(c, st, ifx c.dead != .None then c.dead else .Io, 0);
	table_remove(*c.streams, st.id);
	// The stream may outlive this call (our body still sending, or a reset not yet sent): detach it so
	// nghttp2 never reads req.body or st again, and end it. A request nghttp2 still holds queued (the
	// connection died first) has no stream yet; set_stream_user_data also clears its queued copy of st.
	reset := stream_of(c.session, st.id) && c.dead == .None;
	nghttp2_session_set_stream_user_data(c.session, st.id, null);
	if reset nghttp2_submit_rst_stream(c.session, 0, st.id, xx ifx st.err == .None then 0 else NG_CANCEL);
	locks.cond_broadcast(*c.cond);
	locks.unlock(*c.mu);
	if reset flush(c);
	resp, err := st.resp, st.err;
	free(st,, c.allocator);
	if err != .None {
		code := resp.h2_error;
		response_destroy(*resp);
		resp.h2_error = code;
	}
	return resp, err;
}

// h2_service reads and handles frames until the connection dies. Run it on a thread to keep an idle
// connection responsive (PING/SETTINGS/GOAWAY).
h2_service :: (c: *H2_Conn) -> Error {
	if !enter(c) return .Closed;
	defer leave(c);
	lock(c);
	defer locks.unlock(*c.mu);
	drive_until(c, null);
	return c.dead;
}

// h2_can_open reports whether new streams may be opened on this connection.
h2_can_open :: (c: *H2_Conn) -> bool {
	lock(c);
	defer locks.unlock(*c.mu);
	return c.dead == .None && nghttp2_session_check_request_allowed(c.session) != 0;
}

#scope_module

CHROME_DATA_CHUNK :: 2 * 1430 - 9;
// Spdy3PriorityToHttp2Weight - 1 for each Priority, by its SPDY priority (Highest 0 .. Throttled 5).
CHROME_SPDY_PRIORITY := u8.[1, 0, 2, 3, 4, 5]; // indexed by Priority: Medium, Highest, Low, Lowest, Idle, Throttled
CHROME_WEIGHT := u8.[255, 219, 182, 146, 109, 73];

H2_Stream :: struct {
	id: s32;
	req: Request;      // the caller's memory, for its HEADERS (sent before h2_request returns)
	body: []u8;        // request body still to send; the caller's memory
	resp: Response;
	header_bytes: int;
	got_headers: bool; // final (non-1xx) response headers received
	done: bool;        // response complete or failed (err)
	err: Error;
	in_tree: bool;     // listed in H2_Conn.tree (its HEADERS went out, not yet done)
	unacked: int;      // received bytes not yet given back in a WINDOW_UPDATE
	acked_at: Apollo_Time;
}

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

Ng_Data_Provider :: struct {
	source: *void;
	read: (s: *Ng_Session, id: s32, buf: *u8, n: u64, flags: *u32, source: *void, user: *void) -> int #c_call;
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
NG_PROTOCOL_ERROR :: 1;
NG_REFUSED_STREAM :: 7;
NG_CANCEL :: 8;

nghttp2_session_callbacks_new :: (cbs: **Ng_Callbacks) -> s32 #foreign vendor;
nghttp2_session_callbacks_del :: (cbs: *Ng_Callbacks) #foreign vendor;
nghttp2_session_callbacks_set_on_begin_frame_callback :: (cbs: *Ng_Callbacks, cb: (s: *Ng_Session, f: *Ng_Frame_Hd, user: *void) -> s32 #c_call) #foreign vendor;
nghttp2_session_callbacks_set_on_frame_recv_callback :: (cbs: *Ng_Callbacks, cb: (s: *Ng_Session, f: *Ng_Frame_Hd, user: *void) -> s32 #c_call) #foreign vendor;
nghttp2_session_callbacks_set_on_data_chunk_recv_callback :: (cbs: *Ng_Callbacks, cb: (s: *Ng_Session, flags: u8, id: s32, data: *u8, n: u64, user: *void) -> s32 #c_call) #foreign vendor;
nghttp2_session_callbacks_set_on_stream_close_callback :: (cbs: *Ng_Callbacks, cb: (s: *Ng_Session, id: s32, code: u32, user: *void) -> s32 #c_call) #foreign vendor;
nghttp2_session_callbacks_set_on_header_callback :: (cbs: *Ng_Callbacks, cb: (s: *Ng_Session, f: *Ng_Frame_Hd, name: *u8, namelen: u64, value: *u8, valuelen: u64, flags: u8, user: *void) -> s32 #c_call) #foreign vendor;
nghttp2_session_callbacks_set_on_frame_not_send_callback :: (cbs: *Ng_Callbacks, cb: (s: *Ng_Session, f: *Ng_Frame_Hd, code: s32, user: *void) -> s32 #c_call) #foreign vendor;
nghttp2_session_callbacks_set_data_source_read_length_callback2 :: (cbs: *Ng_Callbacks, cb: (s: *Ng_Session, type: u8, id: s32, conn_window: s32, stream_window: s32, max_frame: u32, user: *void) -> int #c_call) #foreign vendor;
nghttp2_option_new :: (opt: **Ng_Option) -> s32 #foreign vendor;
nghttp2_option_del :: (opt: *Ng_Option) #foreign vendor;
nghttp2_option_set_no_auto_window_update :: (opt: *Ng_Option, val: s32) #foreign vendor;
nghttp2_session_client_new2 :: (s: **Ng_Session, cbs: *Ng_Callbacks, user: *void, opt: *Ng_Option) -> s32 #foreign vendor;
nghttp2_session_del :: (s: *Ng_Session) #foreign vendor;
nghttp2_submit_settings :: (s: *Ng_Session, flags: u8, iv: *Setting, niv: u64) -> s32 #foreign vendor;
nghttp2_submit_window_update :: (s: *Ng_Session, flags: u8, id: s32, increment: s32) -> s32 #foreign vendor;
nghttp2_submit_request2 :: (s: *Ng_Session, pri_spec: *void, nva: *Ng_Nv, nvlen: u64, data: *Ng_Data_Provider, stream_user: *void) -> s32 #foreign vendor;
nghttp2_submit_rst_stream :: (s: *Ng_Session, flags: u8, id: s32, code: u32) -> s32 #foreign vendor;
nghttp2_submit_goaway :: (s: *Ng_Session, flags: u8, last_id: s32, code: u32, data: *u8, n: u64) -> s32 #foreign vendor;
nghttp2_session_get_effective_recv_data_length :: (s: *Ng_Session) -> s32 #foreign vendor;
nghttp2_session_terminate_session :: (s: *Ng_Session, code: u32) -> s32 #foreign vendor;
nghttp2_session_mem_recv2 :: (s: *Ng_Session, data: *u8, n: u64) -> int #foreign vendor;
nghttp2_session_mem_send2 :: (s: *Ng_Session, data: **u8) -> int #foreign vendor;
nghttp2_session_get_stream_user_data :: (s: *Ng_Session, id: s32) -> *void #foreign vendor;
nghttp2_session_set_stream_user_data :: (s: *Ng_Session, id: s32, data: *void) -> s32 #foreign vendor;
nghttp2_session_check_request_allowed :: (s: *Ng_Session) -> s32 #foreign vendor;
nghttp2_session_want_read :: (s: *Ng_Session) -> s32 #foreign vendor;
nghttp2_session_want_write :: (s: *Ng_Session) -> s32 #foreign vendor;

// lock takes c.mu; nghttp2 calls made under it run their callbacks in this thread's context.
lock :: (c: *H2_Conn) #expand {
	locks.lock(*c.mu);
	c.ctx = *context;
}

h2_destroy :: (c: *H2_Conn) {
	push_allocator(c.allocator);
	c.ctx = *context;
	nghttp2_session_del(c.session);
	for c.streams {
		response_destroy(*it.resp);
		free(it);
	}
	deinit(*c.streams);
	array_free(c.rbuf);
	array_free(c.wbuf);
	array_free(c.out);
	array_free(c.block);
	hpack_destroy(*c.enc);
	for c.tree array_free(it);
	free(c);
}

// ---- nghttp2 callbacks: called from nghttp2_session_mem_recv2/mem_send2 with mu held ----

// A stream's user data is its H2_Stream until h2_request clears it, so these never see a freed stream:
// null means the caller has gone.
stream_of :: (s: *Ng_Session, id: s32) -> *H2_Stream {
	return cast(*H2_Stream) nghttp2_session_get_stream_user_data(s, id);
}

finish :: (c: *H2_Conn, st: *H2_Stream, err: Error, code: u32) {
	if st.done return;
	st.done = true;
	st.err = err;
	st.resp.h2_error = code;
	if !st.in_tree return;
	l := *c.tree[CHROME_SPDY_PRIORITY[st.req.priority]];
	for l.* if it == st.id { array_ordered_remove_by_index(l, it_index); break; }
}

// give_back returns received bytes to the windows as Chrome's IncreaseRecvWindowSize does: a
// WINDOW_UPDATE once more than half the window is unacked or 5 s passed since the last one; the
// connection's first. The connection's count is every DATA byte nghttp2 has read: padding, and DATA for
// a stream it already closed (no callback sees that), which Chrome's SpdySession also gives back at
// once. Called before each frame and after each read too, so those land in Chrome's order; should
// nghttp2 have acked such DATA itself (half the window of it unacked), its count is followed.
give_back :: (c: *H2_Conn, st: *H2_Stream, id: s32, n: int) {
	now := current_time_monotonic();
	unacked := cast(int) nghttp2_session_get_effective_recv_data_length(c.session);
	if unacked > c.unacked && (unacked > CHROME_CONNECTION_WINDOW / 2 || now - c.acked_at >= seconds_to_apollo(5)) {
		nghttp2_submit_window_update(c.session, 0, 0, xx unacked);
		unacked, c.acked_at = 0, now;
	}
	c.unacked = unacked;
	if !st return;
	st.unacked += n;
	if st.unacked > CHROME_STREAM_WINDOW / 2 || now - st.acked_at >= seconds_to_apollo(5) {
		nghttp2_submit_window_update(c.session, 0, id, xx st.unacked);
		st.unacked, st.acked_at = 0, now;
	}
}

// give_back_hyper returns a whole DATA frame (n bytes, padding included) as hyper's body does once it reads
// it; h2 then sends a WINDOW_UPDATE when what was given back reaches half of what is left of the window. The
// connection's count is nghttp2's (DATA for closed streams too).
give_back_hyper :: (c: *H2_Conn, st: *H2_Stream, id: s32, n: int, ended: bool) {
	unacked := cast(int) nghttp2_session_get_effective_recv_data_length(c.session);
	if unacked >= (HYPER_CONNECTION_WINDOW - unacked) / 2 nghttp2_submit_window_update(c.session, 0, 0, xx unacked);
	if !st || ended return;
	st.unacked += n;
	if st.unacked >= (HYPER_STREAM_WINDOW - st.unacked) / 2 {
		nghttp2_submit_window_update(c.session, 0, id, xx st.unacked);
		st.unacked = 0;
	}
}

on_begin_frame :: (s: *Ng_Session, f: *Ng_Frame_Hd, user: *void) -> s32 #c_call {
	c := cast(*H2_Conn) user;
	if !c.cfg.hyper push_context c.ctx.* { give_back(c, null, 0, 0); }
	return 0;
}

on_header :: (s: *Ng_Session, f: *Ng_Frame_Hd, name: *u8, namelen: u64, value: *u8, valuelen: u64, flags: u8, user: *void) -> s32 #c_call {
	c := cast(*H2_Conn) user;
	push_context c.ctx.* {
		st := stream_of(s, f.stream_id);
		if f.type != NG_FRAME_HEADERS || !st || st.done return 0;
		st.header_bytes += cast(int) (namelen + valuelen) + 32;
		if st.header_bytes > c.cfg.max_header_block {
			finish(c, st, .Too_Large, NG_CANCEL); // h2_request resets the stream
			return 0;
		}
		n, v := to_string(name, xx namelen), to_string(value, xx valuelen);
		if n == ":status" {
			st.resp.status = (cast(int) v[0] - #char "0") * 100 + (cast(int) v[1] - #char "0") * 10 + (cast(int) v[2] - #char "0"); // nghttp2 checked: 3 digits
		} else {
			array_add(ifx st.got_headers then *st.resp.trailers else *st.resp.headers, copy_header(n, v, c.allocator));
		}
		return 0;
	}
}

on_frame_recv :: (s: *Ng_Session, f: *Ng_Frame_Hd, user: *void) -> s32 #c_call {
	c := cast(*H2_Conn) user;
	push_context c.ctx.* {
		if f.type == NG_FRAME_SETTINGS && !(f.flags & NG_FLAG_ACK) {
			set := cast(*Ng_Settings) f;
			for i: 0..cast(int) set.niv - 1 if set.iv[i].id == 1 hpack_set_table_size(*c.enc, set.iv[i].value);
		} else if f.type == NG_FRAME_PING && (f.flags & NG_FLAG_ACK) {
			c.ping_in_flight = false;
		}
		if f.type != NG_FRAME_HEADERS && f.type != NG_FRAME_DATA return 0;
		st := stream_of(s, f.stream_id);
		if st && st.done st = null;
		// Chrome counts padding as consumed at once.
		pad := cast(int) (cast(*Ng_Data) f).padlen;
		if f.type == NG_FRAME_DATA && c.cfg.hyper give_back_hyper(c, st, f.stream_id, xx f.length, (f.flags & NG_FLAG_END_STREAM) != 0);
		else if f.type == NG_FRAME_DATA && pad > 0 give_back(c, st, f.stream_id, pad);
		if !st return 0;
		if f.type == NG_FRAME_HEADERS && !st.got_headers {
			if st.resp.status < 200 {
				// Interim response (100/103): drop it and wait for the final one.
				clear_headers(*st.resp.headers,, c.allocator);
				st.resp.status = 0;
				return 0;
			}
			st.got_headers = true;
		}
		if f.flags & NG_FLAG_END_STREAM finish(c, st, .None, 0);
		return 0;
	}
}

on_data_chunk :: (s: *Ng_Session, flags: u8, id: s32, data: *u8, n: u64, user: *void) -> s32 #c_call {
	c := cast(*H2_Conn) user;
	push_context c.ctx.* {
		st := stream_of(s, id);
		if st && st.done st = null;
		if !c.cfg.hyper give_back(c, st, id, xx n);
		if !st return 0;
		if sinking(st.req.sink, *st.resp) {
			if !st.req.sink.take(st.req.sink.data, .{xx n, data}) finish(c, st, .Closed, NG_CANCEL);
			return 0;
		}
		if st.resp.body.count + cast(int) n > c.cfg.max_response_body {
			finish(c, st, .Too_Large, NG_CANCEL); // h2_request resets the stream
			return 0;
		}
		array_add(*st.resp.body, ..[]u8.{xx n, data});
		return 0;
	}
}

on_stream_close :: (s: *Ng_Session, id: s32, code: u32, user: *void) -> s32 #c_call {
	c := cast(*H2_Conn) user;
	push_context c.ctx.* {
		st := stream_of(s, id);
		if st finish(c, st, ifx code == NG_REFUSED_STREAM then .Refused else .Stream_Reset, code);
		return 0;
	}
}

// A queued request nghttp2 drops unsent (GOAWAY arrived first) never opens a stream, so on_stream_close
// won't see it.
on_not_sent :: (s: *Ng_Session, f: *Ng_Frame_Hd, code: s32, user: *void) -> s32 #c_call {
	c := cast(*H2_Conn) user;
	push_context c.ctx.* {
		_, st := table_find(*c.streams, f.stream_id);
		if f.type == NG_FRAME_HEADERS && st {
			if code == NG_ERR_START_STREAM_NOT_ALLOWED finish(c, st, .Refused, NG_REFUSED_STREAM);
			else finish(c, st, .Io, 0);
		}
		return 0;
	}
}

read_body :: (s: *Ng_Session, id: s32, buf: *u8, n: u64, flags: *u32, source: *void, user: *void) -> int #c_call {
	st := cast(*H2_Stream) nghttp2_session_get_stream_user_data(s, id);
	if !st return NG_ERR_TEMPORAL_CALLBACK_FAILURE;
	k := ifx cast(s64) n < st.body.count then cast(s64) n else st.body.count;
	memcpy(buf, st.body.data, k);
	st.body.data += k;
	st.body.count -= k;
	if !st.body.count flags.* |= NG_DATA_FLAG_EOF;
	if st.req.sent push_context (cast(*H2_Conn) user).ctx.* { atomic_add(st.req.sent, k); }
	return k;
}

data_chunk_len :: (s: *Ng_Session, type: u8, id: s32, conn_window: s32, stream_window: s32, max_frame: u32, user: *void) -> int #c_call {
	m: s64 = CHROME_DATA_CHUNK;
	if conn_window < m m = conn_window;
	if stream_window < m m = stream_window;
	if max_frame < m m = max_frame;
	return m;
}

// ---- I/O ----

// flush writes everything nghttp2 has queued, in one write.
flush :: (c: *H2_Conn) -> Error {
	locks.guard(*c.wmu);
	c.wbuf.count = 0;
	lock(c);
	while c.dead == .None {
		p: *u8;
		n := nghttp2_session_mem_send2(c.session, *p);
		if n <= 0 break;
		array_add(*c.wbuf, ..[]u8.{n, p});
	}
	first := !c.sent_preface;
	rewrite_frames(c);
	locks.unlock(*c.mu);
	if !c.out.count return .None;
	out: []u8 = c.out;
	if first && c.cfg.hyper && out.count >= 24 { // h2's bind_connection writes the preface by itself
		err := netio.write(c.s, array_view(out, 0, 24));
		if err != .None || out.count == 24 return map_net_error(err);
		out = array_view(out, 24);
	}
	return map_net_error(netio.write(c.s, out));
}

// rewrite_frames copies nghttp2's output (whole frames) to c.out, replacing each HEADERS and its
// CONTINUATIONs with Chrome's: hpack.jai's block, PRIORITY, 16383-byte frames (kHttp2MaxControlFrameSendSize).
rewrite_frames :: (c: *H2_Conn) {
	put_u32 :: (out: *[..]u8, v: u32) { array_add(out, cast(u8) (v >> 24), cast(u8) (v >> 16), cast(u8) (v >> 8), cast(u8) v); }
	c.out.count = 0;
	b: []u8 = c.wbuf;
	if !c.sent_preface && b.count >= 24 {
		array_add(*c.out, ..array_view(b, 0, 24));
		b = array_view(b, 24);
		c.sent_preface = true;
	}
	while b.count >= 9 {
		n := 9 + (((cast(int) b[0]) << 16) | ((cast(int) b[1]) << 8) | (cast(int) b[2]));
		type, flags := b[3], b[4];
		id := cast(s32) ((((cast(u32) b[5]) << 24) | ((cast(u32) b[6]) << 16) | ((cast(u32) b[7]) << 8) | (cast(u32) b[8])) & 0x7fffffff);
		frame := array_view(b, 0, n);
		b = array_view(b, n);
		if !c.cfg.hyper && (type == NG_FRAME_HEADERS || (type == NG_FRAME_DATA && n > 9)) preface_ping(c);
		if type == NG_FRAME_CONTINUATION continue;
		_, st := table_find(*c.streams, id);
		if type != NG_FRAME_HEADERS || !st {
			array_add(*c.out, ..frame);
			continue;
		}
		c.block.count = 0;
		hpack_encode(*c.enc, *c.block, st.req);
		if c.cfg.hyper { // h2's FramedWrite: no PRIORITY, CONTINUATION past the server's 16384-byte frames
			rest: []u8 = c.block;
			first := true;
			while true {
				k := min(rest.count, 16384);
				end: u8 = xx ifx k == rest.count then NG_FLAG_END_HEADERS else 0;
				array_add(*c.out, cast(u8) (k >> 16), cast(u8) (k >> 8), cast(u8) k);
				kind: u8 = xx ifx first then NG_FRAME_HEADERS else NG_FRAME_CONTINUATION;
				eos: u8 = xx ifx first then flags & NG_FLAG_END_STREAM else 0;
				array_add(*c.out, kind, eos | end);
				put_u32(*c.out, cast(u32) id);
				array_add(*c.out, ..array_view(rest, 0, k));
				rest = array_view(rest, k);
				if end break;
				first = false;
			}
			continue;
		}
		p := CHROME_SPDY_PRIORITY[st.req.priority];
		parent: s32;
		i := cast(int) p;
		while i >= 0 && !parent {
			if c.tree[i].count parent = peek(c.tree[i]);
			i -= 1;
		}
		if !st.done {
			array_add(*c.tree[p], id);
			st.in_tree = true;
		}
		rest: []u8 = c.block;
		first := true;
		while true {
			k := min(rest.count, 16383 - 9 - (ifx first then 5 else 0));
			end: u8 = xx ifx k == rest.count then NG_FLAG_END_HEADERS else 0;
			plen := cast(u32) (k + (ifx first then 5 else 0));
			array_add(*c.out, cast(u8) (plen >> 16), cast(u8) (plen >> 8), cast(u8) plen);
			if first {
				array_add(*c.out, NG_FRAME_HEADERS, (flags & NG_FLAG_END_STREAM) | NG_FLAG_PRIORITY | end);
				put_u32(*c.out, cast(u32) id);
				put_u32(*c.out, (cast(u32) parent) | 0x8000_0000);
				array_add(*c.out, CHROME_WEIGHT[p]);
			} else {
				array_add(*c.out, NG_FRAME_CONTINUATION, end);
				put_u32(*c.out, cast(u32) id);
			}
			array_add(*c.out, ..array_view(rest, 0, k));
			rest = array_view(rest, k);
			if end break;
			first = false;
		}
	}
}

// preface_ping is Chrome's MaybeSendPrefacePing: a PING ahead of a request when nothing was read for 10 s.
preface_ping :: (c: *H2_Conn) {
	if c.ping_in_flight || current_time_monotonic() - c.last_read <= seconds_to_apollo(10) return;
	array_add(*c.out, 0, 0, 8, NG_FRAME_PING, 0, 0, 0, 0, 0);
	for i: 0..7 array_add(*c.out, cast(u8) (c.next_ping >> (56 - 8 * i)));
	c.ping_in_flight = true;
	c.ping_at = current_time_monotonic();
	c.next_ping += 1;
}

// read_once reads what the socket has, gives it to nghttp2 and sends its replies. Called by the reading
// leader without mu.
read_once :: (c: *H2_Conn) -> Error {
	n, rerr := netio.read(c.s, c.rbuf);
	if rerr != .None return map_net_error(rerr);
	lock(c);
	c.last_read = current_time_monotonic();
	rv := nghttp2_session_mem_recv2(c.session, c.rbuf.data, xx n);
	if rv >= 0 give_back(c, null, 0, 0);
	locks.unlock(*c.mu);
	ferr := flush(c); // on a connection error this sends nghttp2's GOAWAY
	if rv < 0 return .Protocol;
	if ferr != .None return ferr;
	// nghttp2 is done once a GOAWAY went either way and no streams remain, or it sent one for a
	// protocol error.
	lock(c);
	defer locks.unlock(*c.mu);
	return ifx nghttp2_session_want_read(c.session) == 0 && nghttp2_session_want_write(c.session) == 0 then .Goaway else .None;
}

// enter/leave bracket every public call so h2_close can wait for callers.
enter :: (c: *H2_Conn) -> bool {
	locks.guard(*c.mu);
	if c.closing return false;
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
	if c.dead == .None c.dead = err;
	for c.streams finish(c, it, c.dead, 0);
}

// drive_until: called and returns with c.mu held; st == null waits until the connection dies.
drive_until :: (c: *H2_Conn, st: *H2_Stream) {
	while !st || !st.done {
		if c.dead != .None return;
		if !c.reading {
			c.reading = true;
			locks.unlock(*c.mu);
			err := read_once(c);
			lock(c);
			c.reading = false;
			if err != .None fail_conn_locked(c, err);
			locks.cond_broadcast(*c.cond);
		} else if c.ping_in_flight {
			// Chrome's CheckPingStatus, run by a waiter since the reader is blocked in read
			left := to_milliseconds(max(c.ping_at, c.last_read) + seconds_to_apollo(10) - current_time_monotonic());
			if left <= 0 failed_ping(c);
			else locks.cond_wait_with_timeout(*c.cond, *c.mu, left);
			c.ctx = *context;
		} else {
			locks.cond_wait(*c.cond, *c.mu);
			c.ctx = *context;
		}
	}
}

// failed_ping is Chrome's DoDrainSession(ERR_HTTP2_PING_FAILED): GOAWAY, then the connection closes.
// Called and returns with c.mu held.
failed_ping :: (c: *H2_Conn) {
	WHY :: "Failed ping.";
	nghttp2_submit_goaway(c.session, 0, 0, NG_PROTOCOL_ERROR, WHY.data, WHY.count);
	c.ping_in_flight = false;
	locks.unlock(*c.mu);
	flush(c);
	netio.shutdown(c.s); // wakes the reader
	lock(c);
	fail_conn_locked(c, .Timeout);
	locks.cond_broadcast(*c.cond);
}

// ---- requests ----

FORBIDDEN_H2_HEADERS :: string.["connection", "keep-alive", "proxy-connection", "transfer-encoding", "upgrade"];

validate_h2_request :: (req: Request) -> bool {
	if !req.method || !req.path || !req.scheme return false;
	for h: req.headers {
		if !h.name || h.name[0] == #char ":" return false;
		for h.name if (it >= #char "A" && it <= #char "Z") || it <= #char " " || it >= 0x7f return false;
		if !valid_value(h.value) return false;
		for FORBIDDEN_H2_HEADERS if h.name == it return false;
		if h.name == "te" && h.value != "trailers" return false;
	}
	return true;
}
