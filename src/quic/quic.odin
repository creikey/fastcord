// Package quic is fastcord's HTTP/3 client: vendored ngtcp2 (QUIC) and nghttp3 (HTTP/3) driven through
// vendor/ngtcp2/fc_ngtcp2.c, with the TLS handshake in BoringSSL set up by fc:tls exactly as for TCP
// (Chrome's QUIC ClientHello, OS trust store and hostname checks). It shares http.Request and http.Response
// with fc:http so callers pick h2 or h3 per Alt-Svc.
//
// What goes on the wire follows Chrome 148 where ngtcp2's and nghttp3's public settings allow: 8-byte
// destination and empty source connection IDs, 1250-byte datagrams, packet numbers from 1, CUBIC, Chrome's
// transport parameters byte for byte (fc_quic_chrome_tp), Chrome's SETTINGS values, a PRIORITY_UPDATE and a
// `priority` header on every request, pseudo-headers in Chrome's order.
//
// Threading: each Conn has one I/O thread that owns the socket and timers. All calls into C happen under
// Conn.mu, and the C side calls back (on_*) only from inside those calls.
package quic

import "base:runtime"
import "core:fmt"
import "core:net"
import "core:strconv"
import "core:strings"
import "core:thread"
import "core:time"

import "fc:http"
import "fc:locks"
import "fc:tls"

when ODIN_OS == .Windows {
	foreign import lib {"../../build/fc_ngtcp2.obj", "../../build/fc_ngtcp2.lib", "../../build/fc_nghttp3.lib"}
} else {
	foreign import lib {"../../build/fc_ngtcp2.o", "../../build/libfc_ngtcp2.a", "../../build/libfc_nghttp3.a"}
}

@(private)
Fc_Quic :: struct {}

@(private)
Events :: struct {
	user:   rawptr,
	header: proc "c" (user: rawptr, id: i64, trailer: i32, name: [^]u8, nlen: uint, value: [^]u8, vlen: uint),
	data:   proc "c" (user: rawptr, id: i64, p: [^]u8, n: uint),
	done:   proc "c" (user: rawptr, id: i64, fin: i32, code: u64),
	goaway: proc "c" (user: rawptr),
}

@(private)
Field :: struct {
	name:  [^]u8,
	nlen:  uint,
	value: [^]u8,
	vlen:  uint,
}

@(private, default_calling_convention = "c")
foreign lib {
	fc_quic_new :: proc(ssl: ^tls.SSL, family: i32, addr: [^]u8, port, local_port: i32, now, initial_rtt: u64, ev: ^Events) -> ^Fc_Quic ---
	fc_quic_del :: proc(q: ^Fc_Quic) ---
	fc_quic_read :: proc(q: ^Fc_Quic, pkt: [^]u8, n: uint, now: u64) -> i32 ---
	fc_quic_write :: proc(q: ^Fc_Quic, buf: [^]u8, cap: uint, now: u64) -> int ---
	fc_quic_expiry :: proc(q: ^Fc_Quic) -> u64 ---
	fc_quic_handle_expiry :: proc(q: ^Fc_Quic, now: u64) -> i32 ---
	fc_quic_close_packet :: proc(q: ^Fc_Quic, buf: [^]u8, cap: uint, now: u64) -> int ---
	fc_quic_submit :: proc(q: ^Fc_Quic, f: [^]Field, n: uint, body: [^]u8, blen: uint, prio: [^]u8, plen: uint, id: ^i64) -> i32 ---
	fc_quic_cancel :: proc(q: ^Fc_Quic, id: i64) ---
	fc_quic_ready :: proc(q: ^Fc_Quic) -> i32 ---
	fc_quic_srtt :: proc(q: ^Fc_Quic) -> u64 ---
	fc_quic_chrome_tp :: proc(buf: [^]u8, rtt_us: u64) -> uint ---
	fc_quic_tp :: proc(q: ^Fc_Quic, n: ^uint) -> [^]u8 ---
	ngtcp2_crypto_boringssl_configure_client_context :: proc(ctx: ^tls.SSL_CTX) -> i32 ---
}

@(private)
ERR_STREAM_ID_BLOCKED :: -206
@(private)
ERR_CLOSING :: -223
@(private)
ERR_DRAINING :: -224
@(private)
ERR_DROP_CONN :: -232
@(private)
ERR_HANDSHAKE_TIMEOUT :: -236
@(private)
ERR_IDLE_CLOSE :: -238
@(private)
ERR_NOMEM :: -501

// Chrome's limits: 256 KiB of header fields per section (its SETTINGS_MAX_FIELD_SECTION_SIZE) and our own
// 256 MiB per response body.
MAX_FIELD_SECTION :: 262144
MAX_RESPONSE :: 256 << 20

// H3_SETTINGS are the SETTINGS fc_ngtcp2.c sends, as {id, value}, in nghttp3's order.
H3_SETTINGS :: [?][2]u64{{0x06, MAX_FIELD_SECTION}, {0x01, 65536}, {0x07, 100}, {0x33, 1}}

Conn :: struct {
	mu:        locks.Mutex,
	cond:      locks.Cond,
	q:         ^Fc_Quic,
	ev:        Events,
	sock:      net.UDP_Socket,
	wake_sock: net.UDP_Socket,
	peer:      net.Endpoint,
	local:     net.Endpoint, // where wake datagrams go
	io:        ^thread.Thread,
	host:      string,
	streams:   map[i64]^Stream,
	err:       http.Error, // why the connection ended; .None while it is up
	ready:     bool,
	goaway:    bool,
	stop:      bool,
}

@(private)
Stream :: struct {
	resp:   http.Response,
	err:    http.Error,
	done:   bool,
	cancel: bool, // we gave up on it: reset it once the C call that found out returns
	interim: bool, // inside a 1xx header section
	field_bytes: int,
}

@(private)
quic_ctx: ^tls.SSL_CTX

@(init, private)
init_quic :: proc "contextless" () {
	quic_ctx = tls.new_ctx(true)
	if quic_ctx != nil && ngtcp2_crypto_boringssl_configure_client_context(quic_ctx) != 0 do quic_ctx = nil
}

@(private)
now_ns :: proc() -> u64 {return u64(time.tick_now()._nsec)}

// connect is dial, then a wait for the handshake and HTTP/3 setup.
connect :: proc(host: string, port := 443, addr: net.Address = nil) -> (c: ^Conn, err: http.Error) {
	c = dial(host, port, addr) or_return
	locks.lock(&c.mu)
	for !c.ready && c.err == .None do locks.cond_wait(&c.cond, &c.mu)
	err = c.err
	locks.unlock(&c.mu)
	if err != .None {
		close(c)
		return nil, err
	}
	return c, .None
}

// dial starts the handshake with host:port (at addr, when given, instead of host's DNS answer) and returns
// without waiting for it.
dial :: proc(host: string, port := 443, addr: net.Address = nil) -> (c: ^Conn, err: http.Error) {
	// The I/O thread shares the connection: it lives on the heap allocator.
	context.allocator = runtime.heap_allocator()
	ep := net.Endpoint{addr, port}
	if addr == nil {
		ep4, ep6, rerr := net.resolve(host)
		if rerr != nil do return nil, .Io
		ep.address = ep4.address if ep4.address != nil else ep6.address
		if ep.address == nil do return nil, .Io
	}
	ssl := tls.new_ssl(quic_ctx, {alpn = {"h3"}, server_name = host}, true)
	if ssl == nil do return nil, .Io
	family := net.family_from_endpoint(ep)
	sock, serr := net.make_unbound_udp_socket(family)
	if serr != nil {
		tls.SSL_free(ssl)
		return nil, .Io
	}
	any_addr: net.Address = net.IP4_Any if family == .IP4 else net.IP6_Any
	wake_sock, werr := net.make_unbound_udp_socket(family)
	if werr != nil || net.bind(sock, {any_addr, 0}) != nil {
		tls.SSL_free(ssl)
		net.close(sock)
		if werr == nil do net.close(wake_sock)
		return nil, .Io
	}
	local, _ := net.bound_endpoint(sock)

	c = new(Conn)
	c.sock, c.wake_sock, c.peer = sock, wake_sock, ep
	c.local = {net.IP4_Loopback if family == .IP4 else net.IP6_Loopback, local.port}
	c.host = strings.clone(host)
	c.ev = {c, on_header, on_data, on_done, on_goaway}
	raw: [16]u8
	switch a in ep.address {
	case net.IP4_Address:
		raw[0], raw[1], raw[2], raw[3] = a[0], a[1], a[2], a[3]
	case net.IP6_Address:
		raw = transmute([16]u8)a
	}
	rtt := cached_rtt_us(host) * 1000
	c.q = fc_quic_new(ssl, 4 if family == .IP4 else 6, &raw[0], i32(ep.port), i32(local.port), now_ns(), rtt, &c.ev)
	if c.q == nil {
		destroy(c)
		return nil, .Out_Of_Memory
	}
	c.io = thread.create_and_start_with_poly_data(c, io_loop)
	return c, .None
}

// can_open reports whether new requests may go on c.
can_open :: proc(c: ^Conn) -> bool {
	locks.lock(&c.mu)
	defer locks.unlock(&c.mu)
	return c.ready && !c.goaway && c.err == .None
}

// urgency maps Chrome's request priority to an RFC 9218 urgency.
urgency :: proc(p: http.Priority) -> int {
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

// request sends req and reads the whole response into memory from allocator, which must be safe to use
// from another thread while this one waits. On error the partial response is returned too, for
// http.response_destroy.
request :: proc(c: ^Conn, req: http.Request, allocator := context.allocator) -> (http.Response, http.Error) {
	if req.method == "" || req.path == "" || req.authority == "" do return {}, .Bad_Request
	// The PRIORITY_UPDATE carries the request's own priority field value when it has one (e.g. "i" for
	// images), as Chrome does; otherwise Chrome's default for the request priority, also sent as a header.
	prio := fmt.tprintf("u=%d, i", urgency(req.priority))
	fields := make([dynamic]Field, 0, len(req.headers) + 5, context.temp_allocator)
	field :: proc(f: ^[dynamic]Field, name, value: string) {
		append(f, Field{raw_data(name), len(name), raw_data(value), len(value)})
	}
	field(&fields, ":method", req.method)
	field(&fields, ":authority", req.authority)
	field(&fields, ":scheme", req.scheme if req.scheme != "" else "https")
	field(&fields, ":path", req.path)
	has_priority := false
	for h in req.headers {
		if h.name == "priority" {
			has_priority = true
			prio = h.value
		}
		field(&fields, h.name, h.value)
	}
	if !has_priority do field(&fields, "priority", prio)

	st := Stream {
		resp = {version = .Http3, allocator = allocator},
	}
	id: i64
	locks.lock(&c.mu)
	defer locks.unlock(&c.mu)
	for {
		if c.err != .None do return {}, c.err
		if c.goaway do return {}, .Goaway
		rv := fc_quic_submit(c.q, raw_data(fields), len(fields), raw_data(req.body), len(req.body), raw_data(prio), len(prio), &id)
		if rv == 0 do break
		if rv != ERR_STREAM_ID_BLOCKED do return {}, .Bad_Request
		locks.cond_wait(&c.cond, &c.mu)
	}
	c.streams[id] = &st
	wake(c)
	for !st.done && c.err == .None do locks.cond_wait(&c.cond, &c.mu)
	delete_key(&c.streams, id)
	if st.cancel && c.err == .None {
		fc_quic_cancel(c.q, id)
		wake(c)
	}
	if !st.done do st.err = c.err
	return st.resp, st.err
}

// close sends CONNECTION_CLOSE (H3_NO_ERROR) if the connection is still up and frees it. Requests must
// have finished.
close :: proc(c: ^Conn) {
	if c == nil do return
	locks.lock(&c.mu)
	c.stop = true
	locks.unlock(&c.mu)
	wake(c)
	locks.join(c.io)
	if c.ready do remember_rtt(c.host, fc_quic_srtt(c.q) / 1000)
	destroy(c)
}

@(private)
destroy :: proc(c: ^Conn) {
	context.allocator = runtime.heap_allocator()
	fc_quic_del(c.q)
	net.close(c.sock)
	net.close(c.wake_sock)
	delete(c.streams)
	delete(c.host)
	free(c)
}

// wake interrupts the I/O thread's receive so it writes what is pending.
@(private)
wake :: proc(c: ^Conn) {
	b := [1]byte{0}
	net.send_udp(c.wake_sock, b[:], c.local)
}

@(private)
fail_locked :: proc(c: ^Conn, rv: i32) {
	if rv >= 0 || c.err != .None do return
	switch rv {
	case ERR_HANDSHAKE_TIMEOUT, ERR_IDLE_CLOSE:
		c.err = .Timeout
	case ERR_CLOSING, ERR_DRAINING, ERR_DROP_CONN:
		c.err = .Closed
	case ERR_NOMEM:
		c.err = .Out_Of_Memory
	case:
		c.err = .Protocol
	}
	locks.cond_broadcast(&c.cond)
}

@(private)
io_loop :: proc(c: ^Conn) {
	context.allocator = runtime.heap_allocator()
	buf: [2048]byte
	for {
		locks.lock(&c.mu)
		now := now_ns()
		if c.err == .None && fc_quic_expiry(c.q) <= now do fail_locked(c, fc_quic_handle_expiry(c.q, now))
		for c.err == .None {
			n := fc_quic_write(c.q, &buf[0], len(buf), now)
			if n <= 0 {
				fail_locked(c, i32(n))
				break
			}
			net.send_udp(c.sock, buf[:n], c.peer)
		}
		if c.err != .None || c.stop {
			if n := fc_quic_close_packet(c.q, &buf[0], len(buf), now); n > 0 do net.send_udp(c.sock, buf[:n], c.peer)
			if c.err == .None do c.err = .Closed
			locks.cond_broadcast(&c.cond)
			locks.unlock(&c.mu)
			return
		}
		expiry := fc_quic_expiry(c.q)
		locks.unlock(&c.mu)

		wait := time.Duration(min(expiry - now, u64(time.Second))) if expiry > now else 0
		net.set_option(c.sock, .Receive_Timeout, max(wait, time.Millisecond))
		n, from, rerr := net.recv_udp(c.sock, buf[:])
		// Wake-ups come from loopback; anything not from the peer is dropped unread.
		if rerr != nil || n == 0 || from != c.peer do continue
		locks.lock(&c.mu)
		if c.err == .None do fail_locked(c, fc_quic_read(c.q, &buf[0], uint(n), now_ns()))
		if !c.ready && c.err == .None && fc_quic_ready(c.q) != 0 do c.ready = true
		// New stream credit, handshake progress or a failure: let waiting requests look again.
		locks.cond_broadcast(&c.cond)
		locks.unlock(&c.mu)
	}
}

// The on_* procs run on the I/O thread inside a C call, with c.mu held. Their pointers are valid only
// during the call.

@(private)
on_header :: proc "c" (user: rawptr, id: i64, trailer: i32, name: [^]u8, nlen: uint, value: [^]u8, vlen: uint) {
	context = runtime.default_context()
	c := (^Conn)(user)
	st := c.streams[id] or_else nil
	if st == nil || st.done do return
	n, v := string(name[:nlen]), string(value[:vlen])
	if n == ":status" {
		st.field_bytes = 0
		code, ok := strconv.parse_int(v)
		if !ok || code < 100 || code > 999 {
			give_up(c, st, .Protocol)
			return
		}
		st.interim = code < 200
		if !st.interim do st.resp.status = code
	}
	st.field_bytes += len(n) + len(v) + 32
	if st.field_bytes > MAX_FIELD_SECTION {
		give_up(c, st, .Too_Large)
		return
	}
	if st.interim || (len(n) > 0 && n[0] == ':') do return
	h := http.Header{strings.clone(n, st.resp.allocator), strings.clone(v, st.resp.allocator)}
	append(&st.resp.trailers if trailer != 0 else &st.resp.headers, h)
}

@(private)
on_data :: proc "c" (user: rawptr, id: i64, p: [^]u8, n: uint) {
	context = runtime.default_context()
	c := (^Conn)(user)
	st := c.streams[id] or_else nil
	if st == nil || st.done do return
	if len(st.resp.body) + int(n) > MAX_RESPONSE {
		give_up(c, st, .Too_Large)
		return
	}
	if st.resp.body == nil do st.resp.body = make([dynamic]byte, 0, int(n), st.resp.allocator)
	append(&st.resp.body, ..p[:n])
}

@(private)
on_done :: proc "c" (user: rawptr, id: i64, fin: i32, code: u64) {
	context = runtime.default_context()
	c := (^Conn)(user)
	st := c.streams[id] or_else nil
	if st == nil || st.done do return
	st.done = true
	if fin == 0 {
		st.err = .Stream_Reset
		st.resp.h2_error = u32(code)
	} else if st.resp.status == 0 {
		st.err = .Protocol
	}
	locks.cond_broadcast(&c.cond)
}

@(private)
on_goaway :: proc "c" (user: rawptr) {
	context = runtime.default_context()
	c := (^Conn)(user)
	c.goaway = true
	locks.cond_broadcast(&c.cond)
}

@(private)
give_up :: proc(c: ^Conn, st: ^Stream, err: http.Error) {
	st.err, st.done, st.cancel = err, true, true
	locks.cond_broadcast(&c.cond)
}

// chrome_transport_params returns one fresh encoding of the transport parameters our ClientHello carries,
// with Google's initial_rtt when initial_rtt_us > 0. Order, the GREASE parameter and the GREASE version
// are random per call, as in Chrome.
chrome_transport_params :: proc(initial_rtt_us: u64, allocator := context.allocator) -> []byte {
	buf: [256]byte
	n := fc_quic_chrome_tp(&buf[0], initial_rtt_us)
	out := make([]byte, n, allocator)
	copy(out, buf[:n])
	return out
}

// transport_params is what c's ClientHello carried, valid until close(c).
transport_params :: proc(c: ^Conn) -> []byte {
	locks.lock(&c.mu)
	defer locks.unlock(&c.mu)
	n: uint
	p := fc_quic_tp(c.q, &n)
	return p[:n]
}

// Chrome remembers each server's smoothed RTT and sends it as initial_rtt on the next connection; this is
// that cache, in microseconds.
@(private)
rtt_cache_mu: locks.Mutex
@(private)
rtt_cache: map[string]u64

cached_rtt_us :: proc(host: string) -> u64 {
	locks.lock(&rtt_cache_mu)
	defer locks.unlock(&rtt_cache_mu)
	return rtt_cache[host] or_else 0
}

// set_cached_rtt_us seeds the cache (Chrome's persisted server network stats).
set_cached_rtt_us :: proc(host: string, us: u64) {
	if us == 0 || host == "" do return
	remember_rtt(host, us)
}

Rtt_Entry :: struct {
	host: string,
	us:   u64,
}

// cached_rtts copies the cache, for persistence.
cached_rtts :: proc(allocator := context.allocator) -> []Rtt_Entry {
	locks.lock(&rtt_cache_mu)
	defer locks.unlock(&rtt_cache_mu)
	out := make([]Rtt_Entry, len(rtt_cache), allocator)
	i := 0
	for h, us in rtt_cache {
		out[i] = {strings.clone(h, allocator), us}
		i += 1
	}
	return out
}

@(private)
remember_rtt :: proc(host: string, us: u64) {
	if us == 0 do return
	context.allocator = runtime.heap_allocator()
	locks.lock(&rtt_cache_mu)
	defer locks.unlock(&rtt_cache_mu)
	if host in rtt_cache {
		rtt_cache[host] = us
	} else {
		rtt_cache[strings.clone(host)] = us
	}
}
