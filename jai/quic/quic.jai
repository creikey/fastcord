#if OS == .WINDOWS {
} else {
}
#scope_module

Fc_Quic :: struct {}

Events :: struct {
	user: *void;
	header: (user: *void, id: s64, trailer: s32, name: *u8, nlen: u64, value: *u8, vlen: u64) #c_call;
	data: (user: *void, id: s64, p: *u8, n: u64) #c_call;
	done: (user: *void, id: s64, fin: s32, code: u64) #c_call;
	goaway: (user: *void) #c_call;
}

Field :: struct {
	name: *u8;
	nlen: u64;
	value: *u8;
	vlen: u64;
}
	fc_quic_new :: (ssl: *tls.SSL, family: s32, addr: *u8, port: s32, local_port: s32, now: u64, initial_rtt: u64, ev: *Events) -> *Fc_Quic #foreign lib;
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
	fc_quic_chrome_tp :: (buf: *u8, rtt_us: u64) -> u64 #foreign lib;
	fc_quic_tp :: (q: *Fc_Quic, n: *u64) -> *u8 #foreign lib;
	ngtcp2_crypto_boringssl_configure_client_context :: (ctx: *tls.SSL_CTX) -> s32 #foreign lib;

ERR_STREAM_ID_BLOCKED :: -206;
ERR_CLOSING :: -223;
ERR_DRAINING :: -224;
ERR_DROP_CONN :: -232;
ERR_HANDSHAKE_TIMEOUT :: -236;
ERR_IDLE_CLOSE :: -238;
ERR_NOMEM :: -501;
#scope_export

// Chrome's limits: 256 KiB of header fields per section (its SETTINGS_MAX_FIELD_SECTION_SIZE) and our own
// 256 MiB per response body.
MAX_FIELD_SECTION :: 262144;
MAX_RESPONSE :: 256 << 20;

// H3_SETTINGS are the SETTINGS fc_ngtcp2.c sends, as {id, value}, in nghttp3's order.
H3_SETTINGS :: [2]u64.[.[0x06, MAX_FIELD_SECTION], .[0x01, 65536], .[0x07, 100], .[0x33, 1]];

Conn :: struct {
	mu: locks.Mutex;
	cond: locks.Cond;
	q: *Fc_Quic;
	ev: Events;
	sock: net.UDP_Socket;
	wake_sock: net.UDP_Socket;
	peer: net.Endpoint;
	local: net.Endpoint; // where wake datagrams go
	io: *thread.Thread;
	host: string;
	streams: Map(s64, *Stream);
	err: http.Error; // why the connection ended; .None while it is up
	ready: bool;
	goaway: bool;
	stop: bool;
}
#scope_module

Stream :: struct {
	resp: http.Response;
	err: http.Error;
	done: bool;
	cancel: bool; // we gave up on it: reset it once the C call that found out returns
	interim: bool; // inside a 1xx header section
	field_bytes: int;
}

quic_ctx: *tls.SSL_CTX;
#scope_export

quic_once: sync.Once;
init_quic :: () {
	tls.ensure_init();
	quic_ctx = tls.new_ctx(true);
	if quic_ctx != null && ngtcp2_crypto_boringssl_configure_client_context(quic_ctx) != 0 { quic_ctx = null; }
}
#scope_module

now_ns :: () -> u64 {return cast(u64)(time.tick_now()._nsec);}
#scope_export

// connect is dial, then a wait for the handshake and HTTP/3 setup.
connect :: (host: string, port := 443, addr: net.Address = .{}) -> *Conn, http.Error {
	c: *Conn;
	err: http.Error;
	__v2, __e1 := dial(host, port, addr); if failed(__e1) return c, __e1; c = __v2;
	locks.lock(*c.mu);
	while !c.ready && c.err == .None { locks.cond_wait(*c.cond, *c.mu); }
	err = c.err;
	locks.unlock(*c.mu);
	if err != .None {
		close(c);
		return null, err;
	}
	return c, .None;
}

// dial starts the handshake with host:port (at addr, when given, instead of host's DNS answer) and returns
// without waiting for it.
dial :: (host: string, port := 443, addr: net.Address = .{}) -> *Conn, http.Error {
	c: *Conn;
	err: http.Error;
	// The I/O thread shares the connection: it lives on the heap allocator.
	push_allocator(context.default_allocator);
	ep := net.Endpoint.{addr, port};
	if addr.kind == .None {
		ep4, ep6, rerr := net.resolve(host);
		if rerr != .None { return null, .Io; }
		ep.address = ifx ep4.address.kind != .None then ep4.address else ep6.address;
		if ep.address.kind == .None { return null, .Io; }
	}
	sync.once_do(*quic_once, init_quic);
	ssl := tls.new_ssl(quic_ctx, .{alpn = string.["h3"], server_name = host}, true);
	if ssl == null { return null, .Io; }
	family := net.family_from_endpoint(ep);
	sock, serr := net.make_unbound_udp_socket(family);
	if serr != .None {
		tls.SSL_free(ssl);
		return null, .Io;
	}
	any_addr: net.Address = ifx family == .IP4 then net.IP4_Any else net.IP6_Any;
	wake_sock, werr := net.make_unbound_udp_socket(family);
	if werr != .None || net.bind(sock, .{any_addr, 0}) != .None {
		tls.SSL_free(ssl);
		net.close(sock);
		if werr == .None { net.close(wake_sock); }
		return null, .Io;
	}
	local, _ := net.bound_endpoint(sock);

	c = new(Conn);
	c.sock, c.wake_sock, c.peer = sock, wake_sock, ep;
	c.local = .{ifx family == .IP4 then net.IP4_Loopback else net.IP6_Loopback, local.port};
	c.host = clone(host);
	c.ev = .{c, on_header, on_data, on_done, on_goaway};
	raw: [16]u8;
	if ep.address.kind == {
	case .IP4_Address; a := ep.address.ip4_address;
		raw[0], raw[1], raw[2], raw[3] = a[0], a[1], a[2], a[3];
	case .IP6_Address; a := ep.address.ip6_address;
		raw = transmute([16]u8, a);
	}
	rtt := cached_rtt_us(host) * 1000;
	c.q = fc_quic_new(ssl, xx ifx family == .IP4 then 4 else 6, *raw[0], cast(s32)(ep.port), cast(s32)(local.port), now_ns(), rtt, *c.ev);
	if c.q == null {
		destroy(c);
		return null, .Out_Of_Memory;
	}
	c.io = thread.create_and_start_with_poly_data(c, io_loop);
	return c, .None;
}

// can_open reports whether new requests may go on c.
can_open :: (c: *Conn) -> bool {
	locks.lock(*c.mu);
	defer locks.unlock(*c.mu);
	return c.ready && !c.goaway && c.err == .None;
}

// urgency maps Chrome's request priority to an RFC 9218 urgency.
urgency :: (p: http.Priority) -> int {
	if p == {
	case .Highest;
		return 0;
	case .Medium;
		return 1;
	case .Low;
		return 2;
	case .Lowest;
		return 3;
	case .Idle;
		return 4;
	case .Throttled;
		return 5;
	}
	return 1;
}

// request sends req and reads the whole response into memory from allocator, which must be safe to use
// from another thread while this one waits. On error the partial response is returned too, for
// http.response_destroy.
request :: (c: *Conn, req: http.Request, allocator := context.allocator) -> http.Response, http.Error {
	if req.method == "" || req.path == "" || req.authority == "" { return .{}, .Bad_Request; }
	// The PRIORITY_UPDATE carries the request's own priority field value when it has one (e.g. "i" for
	// images), as Chrome does; otherwise Chrome's default for the request priority, also sent as a header.
	prio := fmt.tprintf("u=%d, i", urgency(req.priority));
	fields := make_dynamic(Field, 0, len(req.headers) + 5, temp);
	field :: (f: *[..]Field, name: string, value: string) {
		append(f, Field.{raw_data(name), xx len(name), raw_data(value), xx len(value)});
	}
	field(*fields, ":method", req.method);
	field(*fields, ":authority", req.authority);
	field(*fields, ":scheme", ifx req.scheme != "" then req.scheme else "https");
	field(*fields, ":path", req.path);
	has_priority := false;
	for h: req.headers {
		if h.name == "priority" {
			has_priority = true;
			prio = h.value;
		}
		field(*fields, h.name, h.value);
	}
	if !has_priority { field(*fields, "priority", prio); }

	st := Stream.{
		resp = .{version = .Http3, allocator = allocator}
	};
	id: s64;
	locks.lock(*c.mu);
	defer locks.unlock(*c.mu);
	while true {
		if c.err != .None { return .{}, c.err; }
		if c.goaway { return .{}, .Goaway; }
		rv := fc_quic_submit(c.q, raw_data(fields), xx len(fields), raw_data(req.body), xx len(req.body), raw_data(prio), xx len(prio), *id);
		if rv == 0 { break; }
		if rv != ERR_STREAM_ID_BLOCKED { return .{}, .Bad_Request; }
		locks.cond_wait(*c.cond, *c.mu);
	}
	at(*c.streams, id).* = *st;
	wake(c);
	while !st.done && c.err == .None { locks.cond_wait(*c.cond, *c.mu); }
	delete_key(*c.streams, id);
	if st.cancel && c.err == .None {
		fc_quic_cancel(c.q, id);
		wake(c);
	}
	if !st.done { st.err = c.err; }
	return st.resp, st.err;
}

// close sends CONNECTION_CLOSE (H3_NO_ERROR) if the connection is still up and frees it. Requests must
// have finished.
close :: (c: *Conn) {
	if c == null { return; }
	locks.lock(*c.mu);
	c.stop = true;
	locks.unlock(*c.mu);
	wake(c);
	locks.join(c.io);
	if c.ready { remember_rtt(c.host, fc_quic_srtt(c.q) / 1000); }
	destroy(c);
}
#scope_module

destroy :: (c: *Conn) {
	push_allocator(context.default_allocator);
	fc_quic_del(c.q);
	net.close(c.sock);
	net.close(c.wake_sock);
	delete(c.streams);
	delete(c.host);
	free(c);
}

// wake interrupts the I/O thread's receive so it writes what is pending.
wake :: (c: *Conn) {
	b := u8.[0];
	net.send_udp(c.wake_sock, view(b), c.local);
}

fail_locked :: (c: *Conn, rv: s32) {
	if rv >= 0 || c.err != .None { return; }
	if rv == {
	case ERR_HANDSHAKE_TIMEOUT; #through; case ERR_IDLE_CLOSE;
		c.err = .Timeout;
	case ERR_CLOSING; #through; case ERR_DRAINING; #through; case ERR_DROP_CONN;
		c.err = .Closed;
	case ERR_NOMEM;
		c.err = .Out_Of_Memory;
	case;
		c.err = .Protocol;
	}
	locks.cond_broadcast(*c.cond);
}

io_loop :: (c: *Conn) {
	push_allocator(context.default_allocator);
	buf: [2048]u8;
	while true {
		locks.lock(*c.mu);
		now := now_ns();
		if c.err == .None && fc_quic_expiry(c.q) <= now { fail_locked(c, fc_quic_handle_expiry(c.q, now)); }
		while c.err == .None {
			n := fc_quic_write(c.q, *buf[0], xx len(buf), now);
			if n <= 0 {
				fail_locked(c, cast(s32)(n));
				break;
			}
			net.send_udp(c.sock, sub(buf, 0, n), c.peer);
		}
		if c.err != .None || c.stop {
			{ n := fc_quic_close_packet(c.q, *buf[0], xx len(buf), now);
			if n > 0 { net.send_udp(c.sock, sub(buf, 0, n), c.peer); } }
			if c.err == .None { c.err = .Closed; }
			locks.cond_broadcast(*c.cond);
			locks.unlock(*c.mu);
			return;
		}
		expiry := fc_quic_expiry(c.q);
		locks.unlock(*c.mu);

		wait: time.Duration = ifx expiry > now then cast(time.Duration) min(expiry - now, cast(u64) time.Second) else 0;
		net.set_option(c.sock, .Receive_Timeout, max(wait, time.Millisecond));
		n, from, rerr := net.recv_udp(c.sock, view(buf));
		// Wake-ups come from loopback; anything not from the peer is dropped unread.
		if rerr != .None || n == 0 || !same_endpoint(from, c.peer) { continue; }
		locks.lock(*c.mu);
		if c.err == .None { fail_locked(c, fc_quic_read(c.q, *buf[0], cast(u64)(n), now_ns())); }
		if !c.ready && c.err == .None && fc_quic_ready(c.q) != 0 { c.ready = true; }
		// New stream credit, handshake progress or a failure: let waiting requests look again.
		locks.cond_broadcast(*c.cond);
		locks.unlock(*c.mu);
	}
}

// The on_* procs run on the I/O thread inside a C call, with c.mu held. Their pointers are valid only
// during the call.

on_header :: (user: *void, id: s64, trailer: s32, name: *u8, nlen: u64, value: *u8, vlen: u64) #c_call {
	push_context,defer_pop thread_context().*;
	c := cast(*Conn)(user);
	st := get(c.streams, id);
	if st == null || st.done { return; }
	n, v := as_string(sub(name, 0, nlen)), as_string(sub(value, 0, vlen));
	if n == ":status" {
		st.field_bytes = 0;
		code, ok := strconv.parse_int(v);
		if !ok || code < 100 || code > 999 {
			give_up(c, st, .Protocol);
			return;
		}
		st.interim = code < 200;
		if !st.interim { st.resp.status = code; }
	}
	st.field_bytes += len(n) + len(v) + 32;
	if st.field_bytes > MAX_FIELD_SECTION {
		give_up(c, st, .Too_Large);
		return;
	}
	if st.interim || (len(n) > 0 && n[0] == #char ":") { return; }
	h := http.Header.{clone(n, st.resp.allocator), clone(v, st.resp.allocator)};
	append(ifx trailer != 0 then *st.resp.trailers else *st.resp.headers, h);
}

on_data :: (user: *void, id: s64, p: *u8, n: u64) #c_call {
	push_context,defer_pop thread_context().*;
	c := cast(*Conn)(user);
	st := get(c.streams, id);
	if st == null || st.done { return; }
	if len(st.resp.body) + cast(int)(n) > MAX_RESPONSE {
		give_up(c, st, .Too_Large);
		return;
	}
	if st.resp.body.data == null { st.resp.body = make_dynamic(u8, 0, cast(int)(n), st.resp.allocator); }
	append(*st.resp.body, ..sub(p, 0, n));
}

on_done :: (user: *void, id: s64, fin: s32, code: u64) #c_call {
	push_context,defer_pop thread_context().*;
	c := cast(*Conn)(user);
	st := get(c.streams, id);
	if st == null || st.done { return; }
	st.done = true;
	if fin == 0 {
		st.err = .Stream_Reset;
		st.resp.h2_error = cast(u32)(code);
	} else if st.resp.status == 0 {
		st.err = .Protocol;
	}
	locks.cond_broadcast(*c.cond);
}

on_goaway :: (user: *void) #c_call {
	push_context,defer_pop thread_context().*;
	c := cast(*Conn)(user);
	c.goaway = true;
	locks.cond_broadcast(*c.cond);
}

same_endpoint :: (a: net.Endpoint, b: net.Endpoint) -> bool {
	return a.port == b.port && a.address.kind == b.address.kind && memcmp(*a.address.ip6_address[0], *b.address.ip6_address[0], ifx a.address.kind == .IP4_Address then 4 else 16) == 0;
}

give_up :: (c: *Conn, st: *Stream, err: http.Error) {
	st.err, st.done, st.cancel = err, true, true;
	locks.cond_broadcast(*c.cond);
}
#scope_export

// chrome_transport_params returns one fresh encoding of the transport parameters our ClientHello carries,
// with Google's initial_rtt when initial_rtt_us > 0. Order, the GREASE parameter and the GREASE version
// are random per call, as in Chrome.
chrome_transport_params :: (initial_rtt_us: u64, allocator := context.allocator) -> []u8 {
	buf: [256]u8;
	n := cast(int) fc_quic_chrome_tp(*buf[0], initial_rtt_us);
	out := make_slice(u8, n, allocator);
	copy(out, sub(buf, 0, n));
	return out;
}

// transport_params is what c's ClientHello carried, valid until close(c).
transport_params :: (c: *Conn) -> []u8 {
	locks.lock(*c.mu);
	defer locks.unlock(*c.mu);
	n: u64;
	p := fc_quic_tp(c.q, *n);
	return sub(p, 0, n);
}
#scope_module

// Chrome remembers each server's smoothed RTT and sends it as initial_rtt on the next connection; this is
// that cache, in microseconds.
// Chrome remembers each server's smoothed RTT and sends it as initial_rtt on the next connection; this is
// that cache, in microseconds.
rtt_cache_mu: locks.Mutex;
rtt_cache: Map(string, u64);
#scope_export

cached_rtt_us :: (host: string) -> u64 {
	locks.lock(*rtt_cache_mu);
	defer locks.unlock(*rtt_cache_mu);
	return get(rtt_cache, host);
}

// set_cached_rtt_us seeds the cache (Chrome's persisted server network stats).
set_cached_rtt_us :: (host: string, us: u64) {
	if us == 0 || host == "" { return; }
	remember_rtt(host, us);
}

Rtt_Entry :: struct {
	host: string;
	us: u64;
}

// cached_rtts copies the cache, for persistence.
cached_rtts :: (allocator := context.allocator) -> []Rtt_Entry {
	locks.lock(*rtt_cache_mu);
	defer locks.unlock(*rtt_cache_mu);
	out := make_slice(Rtt_Entry, len(rtt_cache), allocator);
	i := 0;
	for h, us: rtt_cache {
		at(*out, i).* = .{clone(h, allocator), us};
		i += 1;
	}
	return out;
}
#scope_module

remember_rtt :: (host: string, us: u64) {
	if us == 0 { return; }
	push_allocator(context.default_allocator);
	locks.lock(*rtt_cache_mu);
	defer locks.unlock(*rtt_cache_mu);
	if has(rtt_cache, host) {
		at(*rtt_cache, host).* = us;
	} else {
		at(*rtt_cache, clone(host)).* = us;
	}
}
#scope_export

