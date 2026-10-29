// Chrome's limits: 256 KiB of header fields per section (its SETTINGS_MAX_FIELD_SECTION_SIZE) and our own
// 256 MiB per response body.
MAX_FIELD_SECTION :: 262144;
MAX_RESPONSE :: 256 << 20;

// H3_SETTINGS are the SETTINGS fc_ngtcp2.c sends, as {id, value}, in Chrome's order; a GREASE setting follows.
H3_SETTINGS :: [2]u64.[.[0x01, 65536], .[0x06, MAX_FIELD_SECTION], .[0x07, 100], .[0x33, 1]];

// Conn is one HTTP/3 connection. It and its I/O thread's memory are on the heap.
Conn :: struct {
	mu: locks.Mutex;
	cond: locks.Cond;
	ctx: *#Context;              // under mu: the context fc_quic's callbacks run in
	q: *Fc_Quic;
	ssl: *tls.SSL;               // owned by q
	ev: Events;
	sock, wake_sock: Udp_Socket;
	peer: Udp_Addr;
	local: Udp_Addr;             // where wake datagrams go
	io: *Thread;
	host: string;
	streams: Table(s64, *Stream);
	err: http.Error;             // why the connection ended; .None while it is up
	ready: bool;                 // HTTP/3 is up: replay-safe requests may go, in 0-RTT on a resumed session
	confirmed: bool;             // the handshake is done: any request may go
	goaway: bool;
	stop: bool;
}

// connect starts the handshake with host:port and waits for it and the HTTP/3 setup. chrome_major picks the
// Chrome whose first flight to send (tls.Config.chrome_major; 0 = tls.presented_major).
connect :: (host: string, port := 443, chrome_major := 0) -> *Conn, http.Error {
	push_allocator(Context_Base.default_allocator);
	peer, ok := udp_resolve(host, port);
	if !ok return null, .Io;
	ssl := tls.new_ssl(quic_ctx(), .{alpn = string.["h3"], server_name = host}, true);
	if !ssl return null, .Io;
	sock, local_port, sok := udp_open(peer, bound_port = true);
	wake_sock, _, wok := udp_open(peer);
	if !sok || !wok {
		tls.SSL_free(ssl);
		if sok udp_close(*sock);
		if wok udp_close(*wake_sock);
		return null, .Io;
	}

	c := New(Conn);
	c.sock, c.wake_sock, c.peer, c.ssl = sock, wake_sock, peer, ssl;
	c.local = udp_local(peer, local_port, loopback = true);
	c.host = copy_string(host);
	c.ev = .{c, on_header, on_data, on_done, on_goaway, on_rejected, on_acked};
	rtt := cached_rtt_us(host) * 1000;
	ip := udp_ip(*peer);
	ztp := cached_0rtt(host,, temp);
	c.q = fc_quic_new(ssl, xx ifx ip.count == 4 then 4 else 6, ip.data, xx udp_port(peer), xx local_port, now_ns(), rtt, ztp.data, xx ztp.count, xx orig(chrome_major), *c.ev);
	if !c.q {
		destroy(c);
		return null, .Out_Of_Memory;
	}
	c.io = New(Thread);
	thread_init(c.io, io_loop);
	c.io.data = c;
	thread_start(c.io);

	locks.lock(*c.mu);
	while !c.ready && c.err == .None locks.cond_wait(*c.cond, *c.mu);
	err := c.err;
	locks.unlock(*c.mu);
	if err != .None {
		close(c);
		return null, err;
	}
	return c, .None;
}

// can_open reports whether new requests may go on c.
can_open :: (c: *Conn) -> bool {
	locks.guard(*c.mu);
	return c.ready && !c.goaway && c.err == .None;
}

// urgency maps Chrome's request priority to an RFC 9218 urgency.
urgency :: (p: http.Priority) -> int {
	if p == {
		case .Highest;   return 0;
		case .Low;       return 2;
		case .Lowest;    return 3;
		case .Idle;      return 4;
		case .Throttled; return 5;
	}
	return 1;
}

// request sends req and reads the whole response into context.allocator, which must be safe to use from
// another thread while this one waits. On error the partial response is returned too, for
// http.response_destroy.
request :: (c: *Conn, req: http.Request) -> http.Response, http.Error {
	if !req.method || !req.path || !req.authority return .{}, .Bad_Request;
	// The PRIORITY_UPDATE carries the request's own priority field value when it has one (e.g. "i" for
	// images), as Chrome does; otherwise Chrome's default for the request priority, also sent as a header.
	prio := tprint("u=%, i", urgency(req.priority));
	fields: [..]Field;
	fields.allocator = temp;
	array_reserve(*fields, req.headers.count + 5);
	field :: (f: *[..]Field, name: string, value: string) { array_add(f, .{name.data, xx name.count, value.data, xx value.count}); }
	field(*fields, ":method", req.method);
	field(*fields, ":authority", req.authority);
	field(*fields, ":scheme", ifx req.scheme then req.scheme else "https");
	field(*fields, ":path", req.path);
	has_priority := false;
	for req.headers {
		if it.name == "priority" {
			has_priority = true;
			prio = it.value;
		}
		field(*fields, it.name, it.value);
	}
	if !has_priority field(*fields, "priority", prio);

	// Like Chrome, only replay-safe methods go in 0-RTT; the rest wait for the handshake.
	safe := array_find(string.["GET", "HEAD", "OPTIONS", "TRACE"], req.method);
	st := Stream.{resp = http.make_response(.Http3), sink = req.sink, sent = req.sent};
	id: s64;
	lock(c);
	defer locks.unlock(*c.mu);
	while true {
		if c.err != .None return .{}, c.err;
		if c.goaway return .{}, .Goaway;
		rv := ERR_STREAM_ID_BLOCKED;
		if c.ready && (safe || c.confirmed) rv = fc_quic_submit(c.q, fields.data, xx fields.count, req.body.data, xx req.body.count, prio.data, xx prio.count, *id);
		if rv == 0 {
			table_set(*c.streams, id, *st);
			wake(c);
			while !st.done && !st.retry && c.err == .None locks.cond_wait(*c.cond, *c.mu);
			c.ctx = *context;
			table_remove(*c.streams, id);
			if !st.retry break;
			// The server refused 0-RTT: send it again on 1-RTT.
			st.retry = false;
			continue;
		}
		if rv != ERR_STREAM_ID_BLOCKED return .{}, .Bad_Request;
		locks.cond_wait(*c.cond, *c.mu);
		c.ctx = *context;
	}
	if st.cancel && c.err == .None {
		fc_quic_cancel(c.q, id);
		wake(c);
	}
	if !st.done st.err = c.err;
	return st.resp, st.err;
}

// close sends CONNECTION_CLOSE (H3_NO_ERROR) if the connection is still up and frees it. Requests must
// have finished.
close :: (c: *Conn) {
	if !c return;
	locks.lock(*c.mu);
	c.stop = true;
	locks.unlock(*c.mu);
	wake(c);
	locks.join(c.io,, Context_Base.default_allocator);
	if c.confirmed remember_rtt(c.host, fc_quic_srtt(c.q) / 1000);
	destroy(c);
}

// chrome_transport_params returns one fresh encoding of the transport parameters our ClientHello carries,
// from context.allocator, with Google's initial_rtt when initial_rtt_us > 0 and connection options "ORIG" from
// Chrome 152 on. Order, the GREASE parameter and the GREASE version are random per call, as in Chrome.
chrome_transport_params :: (initial_rtt_us: u64, chrome_major := 0) -> []u8 {
	buf: [256]u8;
	n := fc_quic_chrome_tp(buf.data, initial_rtt_us, xx orig(chrome_major));
	return array_copy(array_view(buf, 0, xx n));
}

// first_flight returns, for tests, the datagrams a new connection to host sends before hearing back, from
// context.allocator. Nothing goes on the network.
first_flight :: (host: string, chrome_major := 0) -> [][]u8 {
	out: [..][]u8;
	ssl := tls.new_ssl(quic_ctx(), .{alpn = string.["h3"], server_name = host}, true);
	if !ssl return out;
	ev := Events.{null, on_header, on_data, on_done, on_goaway, on_rejected, on_acked};
	ip := u8.[127, 0, 0, 1];
	q := fc_quic_new(ssl, 4, ip.data, 443, 50000, now_ns(), 0, null, 0, xx orig(chrome_major), *ev);
	if !q return out;
	buf: [2048]u8;
	while true {
		n := fc_quic_write(q, buf.data, buf.count, now_ns());
		if n <= 0 break;
		array_add(*out, array_copy(array_view(buf, 0, n)));
	}
	fc_quic_del(q);
	return out;
}

// h3_preview returns, for tests, what HTTP/3 sends on a new connection carrying n GETs whose PRIORITY_UPDATE is
// prio: records [stream id: 1 byte][length: 2 bytes, big-endian][bytes] in send order, from context.allocator.
h3_preview :: (prio: string, n: int) -> []u8 {
	buf: [4096]u8;
	used := fc_h3_preview(prio.data, xx prio.count, xx n, buf.data, buf.count);
	return array_copy(array_view(buf, 0, max(used, 0)));
}

// transport_params is what c's ClientHello carried, valid until close(c).
transport_params :: (c: *Conn) -> []u8 {
	locks.guard(*c.mu);
	n: u64;
	p := fc_quic_tp(c.q, *n);
	return .{xx n, p};
}

// Chrome remembers each server's smoothed RTT and sends it as initial_rtt on the next connection; this is
// that cache, in microseconds.
cached_rtt_us :: (host: string) -> u64 {
	locks.guard(*rtt_cache_mu);
	_, us := table_find(*rtt_cache, host);
	return us;
}

// set_cached_rtt_us seeds the cache (Chrome's persisted server network stats).
set_cached_rtt_us :: (host: string, us: u64) {
	if host remember_rtt(host, us);
}

Rtt_Entry :: struct {
	host: string;
	us: u64;
}

// cached_rtts copies the cache, for persistence, into context.allocator.
cached_rtts :: () -> []Rtt_Entry {
	locks.guard(*rtt_cache_mu);
	out := NewArray(rtt_cache.count, Rtt_Entry);
	i := 0;
	for rtt_cache {
		out[i] = .{copy_string(it_index), it};
		i += 1;
	}
	return out;
}

#scope_module

Fc_Quic :: struct {}

Events :: struct {
	user: *void;
	header: (user: *void, id: s64, trailer: s32, name: *u8, nlen: u64, value: *u8, vlen: u64) #c_call;
	data: (user: *void, id: s64, p: *u8, n: u64) #c_call;
	done: (user: *void, id: s64, fin: s32, code: u64) #c_call;
	goaway: (user: *void) #c_call;
	rejected: (user: *void) #c_call;
	acked: (user: *void, id: s64, n: u64) #c_call;
}

Field :: struct {
	name: *u8;
	nlen: u64;
	value: *u8;
	vlen: u64;
}

fc_quic_new :: (ssl: *tls.SSL, family: s32, addr: *u8, port: s32, local_port: s32, now: u64, initial_rtt: u64, ztp: *u8, ztplen: u64, orig: s32, ev: *Events) -> *Fc_Quic #foreign lib;
fc_quic_del :: (q: *Fc_Quic) #foreign lib;
fc_quic_read :: (q: *Fc_Quic, pkt: *u8, n: u64, now: u64) -> s32 #foreign lib;
fc_quic_write :: (q: *Fc_Quic, buf: *u8, cap: u64, now: u64) -> int #foreign lib;
fc_quic_expiry :: (q: *Fc_Quic) -> u64 #foreign lib;
fc_quic_handle_expiry :: (q: *Fc_Quic, now: u64) -> s32 #foreign lib;
fc_quic_close_packet :: (q: *Fc_Quic, buf: *u8, cap: u64, now: u64) -> int #foreign lib;
fc_quic_submit :: (q: *Fc_Quic, f: *Field, n: u64, body: *u8, blen: u64, prio: *u8, plen: u64, id: *s64) -> s32 #foreign lib;
fc_quic_cancel :: (q: *Fc_Quic, id: s64) #foreign lib;
fc_quic_ready :: (q: *Fc_Quic) -> s32 #foreign lib;
fc_quic_srtt :: (q: *Fc_Quic) -> u64 #foreign lib;
fc_quic_chrome_tp :: (buf: *u8, rtt_us: u64, orig: s32) -> u64 #foreign lib;
fc_quic_tp :: (q: *Fc_Quic, n: *u64) -> *u8 #foreign lib;
fc_quic_0rtt_tp :: (q: *Fc_Quic, buf: *u8, cap: u64) -> u64 #foreign lib;
fc_h3_preview :: (prio: *u8, plen: u64, n: s32, buf: *u8, cap: u64) -> int #foreign lib;
ngtcp2_crypto_boringssl_configure_client_context :: (ctx: *tls.SSL_CTX) -> s32 #foreign lib;

ERR_STREAM_ID_BLOCKED :: -206;
ERR_CLOSING :: -223;
ERR_DRAINING :: -224;
ERR_DROP_CONN :: -232;
ERR_HANDSHAKE_TIMEOUT :: -236;
ERR_IDLE_CLOSE :: -238;
ERR_NOMEM :: -501;

Stream :: struct {
	resp: http.Response;
	err: http.Error;
	done: bool;
	cancel: bool;   // we gave up on it: reset it once the C call that found out returns
	retry: bool;    // sent in refused 0-RTT: submit it again
	interim: bool;  // inside a 1xx header section
	field_bytes: int;
	sink: http.Body_Sink; // the request's
	sent: *s64;           // the request's: acknowledged stream bytes are added here
}

// The QUIC TLS context, made on first use.
ctx_mu: locks.Mutex;
ctx_made: bool;
ctx_quic: *tls.SSL_CTX;

quic_ctx :: () -> *tls.SSL_CTX {
	locks.guard(*ctx_mu);
	if !ctx_made {
		ctx_made = true;
		ctx_quic = tls.new_ctx(true);
		if ctx_quic && ngtcp2_crypto_boringssl_configure_client_context(ctx_quic) != 0 ctx_quic = null;
	}
	return ctx_quic;
}

// orig: Chrome 152 sends the connection option ORIG (kQuicOptions); 148 sent none. Its TLS is the same.
orig :: (chrome_major: int) -> bool { return tls.major_or_presented(chrome_major) >= 152; }

now_ns :: () -> u64 { return xx to_nanoseconds(current_time_monotonic()); }

// lock takes c.mu; fc_quic calls made under it run their callbacks in this thread's context.
lock :: (c: *Conn) #expand {
	locks.lock(*c.mu);
	c.ctx = *context;
}

destroy :: (c: *Conn) {
	push_allocator(Context_Base.default_allocator);
	fc_quic_del(c.q);
	udp_close(*c.sock);
	udp_close(*c.wake_sock);
	deinit(*c.streams);
	free(c.host);
	free(c);
}

// wake interrupts the I/O thread's receive so it writes what is pending.
wake :: (c: *Conn) {
	b := u8.[0];
	udp_send(c.wake_sock, b, c.local);
}

fail_locked :: (c: *Conn, rv: s32) {
	if rv >= 0 || c.err != .None return;
	if rv == {
		case ERR_HANDSHAKE_TIMEOUT; #through;
		case ERR_IDLE_CLOSE;        c.err = .Timeout;
		case ERR_CLOSING;           #through;
		case ERR_DRAINING;          #through;
		case ERR_DROP_CONN;         c.err = .Closed;
		case ERR_NOMEM;             c.err = .Out_Of_Memory;
		case;                       c.err = .Protocol;
	}
	locks.cond_broadcast(*c.cond);
}

io_loop :: (t: *Thread) -> s64 {
	c := cast(*Conn) t.data;
	push_allocator(Context_Base.default_allocator);
	tls.set_context(c.ssl, *context); // only this thread drives the handshake and its tickets
	buf: [2048]u8;
	while true {
		lock(c);
		now := now_ns();
		if c.err == .None && fc_quic_expiry(c.q) <= now fail_locked(c, fc_quic_handle_expiry(c.q, now));
		while c.err == .None {
			n := fc_quic_write(c.q, buf.data, buf.count, now);
			if n <= 0 { fail_locked(c, xx n); break; }
			udp_send(c.sock, array_view(buf, 0, n), c.peer);
		}
		update_ready(c);
		if c.err != .None || c.stop {
			n := fc_quic_close_packet(c.q, buf.data, buf.count, now);
			if n > 0 udp_send(c.sock, array_view(buf, 0, n), c.peer);
			if c.err == .None c.err = .Closed;
			locks.cond_broadcast(*c.cond);
			locks.unlock(*c.mu);
			return 0;
		}
		expiry := fc_quic_expiry(c.q);
		locks.unlock(*c.mu);

		wait_us := ifx expiry > now then cast(s64) (min(expiry - now, 1_000_000_000) / 1000) else 0;
		n, from := udp_recv(c.sock, buf, max(wait_us, 1000));
		// Wake-ups come from loopback; anything not from the peer is dropped unread.
		if n <= 0 || !same_addr(from, c.peer) continue;
		lock(c);
		if c.err == .None fail_locked(c, fc_quic_read(c.q, buf.data, xx n, now_ns()));
		update_ready(c);
		// New stream credit, handshake progress or a failure: let waiting requests look again.
		locks.cond_broadcast(*c.cond);
		locks.unlock(*c.mu);
	}
	return 0;
}

// update_ready follows fc_quic_ready (caller holds c.mu) and keeps the server's 0-RTT transport parameters
// once the handshake is done.
update_ready :: (c: *Conn) {
	r := fc_quic_ready(c.q);
	if r == 2 && !c.confirmed {
		buf: [256]u8;
		remember_0rtt(c.host, array_view(buf, 0, xx fc_quic_0rtt_tp(c.q, buf.data, buf.count)));
	}
	if c.err != .None || (c.ready == (r > 0) && c.confirmed == (r == 2)) return;
	c.ready, c.confirmed = r > 0, r == 2;
	locks.cond_broadcast(*c.cond);
}

// The on_* procs run inside a C call with c.mu held. Their pointers are valid only during the call.

on_header :: (user: *void, id: s64, trailer: s32, name: *u8, nlen: u64, value: *u8, vlen: u64) #c_call {
	c := cast(*Conn) user;
	push_context c.ctx.* {
		_, st := table_find(*c.streams, id);
		if !st || st.done return;
		n, v := to_string(name, xx nlen), to_string(value, xx vlen);
		if n == ":status" {
			st.field_bytes = 0;
			code, ok, rest := string_to_int(v);
			if !ok || rest || code < 100 || code > 999 { give_up(c, st, .Protocol); return; }
			st.interim = code < 200;
			if !st.interim st.resp.status = code;
		}
		st.field_bytes += n.count + v.count + 32;
		if st.field_bytes > MAX_FIELD_SECTION { give_up(c, st, .Too_Large); return; }
		if st.interim || (n && n[0] == #char ":") return;
		a := st.resp.allocator;
		array_add(ifx trailer then *st.resp.trailers else *st.resp.headers, .{copy_string(n,, a), copy_string(v,, a)});
	}
}

on_data :: (user: *void, id: s64, p: *u8, n: u64) #c_call {
	c := cast(*Conn) user;
	push_context c.ctx.* {
		_, st := table_find(*c.streams, id);
		if !st || st.done return;
		if http.sinking(st.sink, *st.resp) {
			if !st.sink.take(st.sink.data, .{xx n, p}) give_up(c, st, .Closed);
			return;
		}
		if st.resp.body.count + cast(int) n > MAX_RESPONSE { give_up(c, st, .Too_Large); return; }
		array_add(*st.resp.body, ..[]u8.{xx n, p});
	}
}

on_acked :: (user: *void, id: s64, n: u64) #c_call {
	c := cast(*Conn) user;
	push_context c.ctx.* {
		_, st := table_find(*c.streams, id);
		if st && st.sent atomic_add(st.sent, cast(s64) n);
	}
}

on_done :: (user: *void, id: s64, fin: s32, code: u64) #c_call {
	c := cast(*Conn) user;
	push_context c.ctx.* {
		_, st := table_find(*c.streams, id);
		if !st || st.done return;
		st.done = true;
		if !fin {
			st.err = .Stream_Reset;
			st.resp.h2_error = xx code;
		} else if !st.resp.status {
			st.err = .Protocol;
		}
		locks.cond_broadcast(*c.cond);
	}
}

on_goaway :: (user: *void) #c_call {
	c := cast(*Conn) user;
	c.goaway = true;
	push_context c.ctx.* { locks.cond_broadcast(*c.cond); }
}

on_rejected :: (user: *void) #c_call {
	c := cast(*Conn) user;
	push_context c.ctx.* {
		for c.streams it.retry = true; // no response can have started
		locks.cond_broadcast(*c.cond);
	}
}

give_up :: (c: *Conn, st: *Stream, err: http.Error) {
	st.err, st.done, st.cancel = err, true, true;
	locks.cond_broadcast(*c.cond);
}

rtt_cache_mu: locks.Mutex;
rtt_cache: Table(string, u64); // heap
zero_rtt_cache: Table(string, []u8); // heap, under rtt_cache_mu: each server's last 0-RTT transport parameters

cached_0rtt :: (host: string) -> []u8 {
	locks.guard(*rtt_cache_mu);
	_, p := table_find(*zero_rtt_cache, host);
	return array_copy(p);
}

remember_0rtt :: (host: string, p: []u8) {
	if !p return;
	locks.guard(*rtt_cache_mu);
	push_allocator(Context_Base.default_allocator);
	old := table_find_pointer(*zero_rtt_cache, host);
	if old { array_free(old.*); old.* = array_copy(p); }
	else table_add(*zero_rtt_cache, copy_string(host), array_copy(p));
}

remember_rtt :: (host: string, us: u64) {
	if !us return;
	locks.guard(*rtt_cache_mu);
	push_allocator(Context_Base.default_allocator);
	p := table_find_pointer(*rtt_cache, host);
	if p p.* = us;
	else table_add(*rtt_cache, copy_string(host), us);
}
