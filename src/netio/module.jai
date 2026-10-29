// netio is the byte-stream abstraction every protocol layer sits on. TCP, TLS and test pipes all
// implement Stream so HTTP/1.1, HTTP/2 and WebSocket code never cares what is underneath.

Error :: enum {
	None;
	Dial;
	Closed;
	Io;
	Tls;
	Protocol;
	Timeout;
	Too_Large;
}

Stream :: struct {
	data: *void;
	// Reads at least 1 byte (blocking) unless error. Returns .Closed on EOF.
	read: (data: *void, dst: []u8) -> int, Error;
	// Writes all of src or errors.
	write: (data: *void, src: []u8) -> Error;
	close: (data: *void);
	// Optional. Wakes any thread blocked in read (it returns .Closed) and makes
	// later reads/writes fail, WITHOUT freeing anything. Layered streams (TLS)
	// should forward to the stream underneath. Safe to call from any thread.
	shutdown: (data: *void);
	// Optional. Bounds each blocking read and write (0 = wait forever); they fail with .Timeout.
	// Layered streams forward to the stream underneath.
	set_timeout: (data: *void, timeout_ms: s64);
}

// Every dialed connection starts with this bound on each read and write, so a peer that goes silent
// during TLS or protocol handshakes fails the connect instead of blocking its thread (and any thread
// joining it) forever. Long-lived connections call set_timeout(s, 0) once established, after which
// their own heartbeats and shutdown() take over.
DIAL_IO_TIMEOUT_MS :: 20_000;

read :: (s: Stream, dst: []u8) -> int, Error { n, err := s.read(s.data, dst); return n, err; }
write :: (s: Stream, src: []u8) -> Error { return s.write(s.data, src); }
// close frees the stream. It must not race a read/write on another thread:
// call shutdown first, wait for those threads to return, then close.
close :: (s: Stream) { s.close(s.data); }
shutdown :: (s: Stream) { if s.shutdown s.shutdown(s.data); }
set_timeout :: (s: Stream, timeout_ms: s64) { if s.set_timeout s.set_timeout(s.data, timeout_ms); }

Tcp :: struct {
	sock: Socket;
	closed: bool;
	shut: bool; // atomic
	peer: [16]u8; // An accepted connection's address, IPv4 as ::ffff:a.b.c.d.
}

// dial_tcp resolves host and connects to its first IPv4 address, else its first IPv6 one. public_only
// skips every address that isn't on the public internet (is_public_address), for a server fetching a URL
// someone else chose; the check is on the address it then connects to, so DNS can't swap it after.
dial_tcp :: (host: string, port: int, public_only := false, loc := #caller_location) -> *Tcp, Error {
	locks.may_block("TCP dial", loc);
	#if OS == .WINDOWS socket_init(); // WSAStartup: reference counted, cheap next to a dial
	hints: addrinfo;
	hints.ai_family = AF_UNSPEC;
	hints.ai_socktype = .STREAM;
	res: *addrinfo;
	if getaddrinfo(temp_c_string(host), temp_c_string(tprint("%", port)), *hints, *res) != 0 return null, .Dial;
	defer freeaddrinfo(res);
	ai: *addrinfo;
	p := res;
	while p {
		// Both sockaddr layouts put the address at a fixed offset: 4 for IPv4, 8 for IPv6.
		addr := cast(*u8) p.ai_addr;
		usable := !public_only
			|| (p.ai_family == AF_INET && is_public_address(.{4, addr + 4}))
			|| (p.ai_family == AF_INET6 && is_public_address(.{16, addr + 8}));
		if usable && p.ai_family == AF_INET { ai = p; break; }
		if usable && p.ai_family == AF_INET6 && !ai ai = p;
		p = p.ai_next;
	}
	if !ai return null, .Dial;

	sock := socket(ai.ai_family, .STREAM, .TCP);
	if sock == INVALID_SOCKET return null, .Dial;
	one: s32 = 1;
	#if OS == .MACOS setsockopt(sock, SOL_SOCKET, SO_NOSIGPIPE, *one, size_of(s32)); // a closed peer is an error, not a signal
	if connect(sock, ai.ai_addr, xx ai.ai_addrlen) != 0 { close_and_reset(*sock); return null, .Dial; }
	setsockopt(sock, xx IPPROTO.TCP, TCP_NODELAY, xx *one, size_of(s32));

	t := New(Tcp);
	t.sock = sock;
	tcp_set_timeout(t, DIAL_IO_TIMEOUT_MS);
	return t, .None;
}

// is_public_address: an IPv4 (4 bytes) or IPv6 (16 bytes) address that is globally routable. Refused:
// this host, private and carrier-grade NAT ranges, link-local, multicast and reserved ones, and IPv6 forms
// that embed a refused IPv4 address (mapped, compatible, NAT64).
is_public_address :: (a: []u8) -> bool {
	if a.count == 16 {
		zero10 := true;
		for 0..9 if a[it] zero10 = false;
		if zero10 && ((a[10] == 0xFF && a[11] == 0xFF) || (a[10] == 0 && a[11] == 0)) return is_public_address(.{4, a.data + 12});
		if a[0] == 0x00 && a[1] == 0x64 && a[2] == 0xFF && a[3] == 0x9B return is_public_address(.{4, a.data + 12});
		if (a[0] & 0xFE) == 0xFC return false;                  // fc00::/7, unique local.
		if a[0] == 0xFE && (a[1] & 0xC0) == 0x80 return false;  // fe80::/10, link-local.
		if a[0] == 0xFF return false;                           // Multicast.
		if a[0] == 0x20 && a[1] == 0x01 && a[2] == 0x0D && a[3] == 0xB8 return false; // Documentation.
		return (a[0] & 0xE0) == 0x20;                           // 2000::/3, global unicast.
	}
	if a.count != 4 return false;
	b0, b1 := a[0], a[1];
	if b0 == 0 || b0 == 10 || b0 == 127 || b0 >= 224 return false;
	if b0 == 100 && (b1 & 0xC0) == 64 return false;           // 100.64/10, carrier-grade NAT.
	if b0 == 169 && b1 == 254 return false;                   // Link-local.
	if b0 == 172 && (b1 & 0xF0) == 16 return false;           // 172.16/12.
	if b0 == 192 && b1 == 168 return false;
	if b0 == 192 && b1 == 0 && a[2] == 0 return false;        // 192.0.0/24, protocol assignments.
	if b0 == 198 && (b1 & 0xFE) == 18 return false;           // 198.18/15, benchmarking.
	return true;
}

tcp_stream :: (t: *Tcp) -> Stream {
	return .{data = t, read = tcp_read, write = tcp_write, close = tcp_close, shutdown = tcp_shutdown, set_timeout = tcp_set_timeout};
}

Listener :: struct {
	sock: Socket;
	port: int;
	shut: bool; // atomic
}

// listen_tcp listens on every IPv6 and IPv4 address. Port 0 picks a free port: see Listener.port.
listen_tcp :: (port: int) -> *Listener, Error {
	#if OS == .WINDOWS socket_init();
	sock := socket(AF_INET6, .STREAM, .TCP);
	if sock == INVALID_SOCKET return null, .Dial;
	zero, one: s32 = 0, 1;
	setsockopt(sock, xx IPPROTO.IPV6, IPV6_V6ONLY, xx *zero, size_of(s32));
	#if OS != .WINDOWS setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, *one, size_of(s32));
	any: [16]u8;
	if bind(sock, any, cast(u16) port) != 0 || listen(sock, 128) != 0 { close_and_reset(*sock); return null, .Dial; }
	a: sockaddr_in6;
	#if OS == .WINDOWS n: s32 = size_of(sockaddr_in6);
	else n: socklen_t = size_of(sockaddr_in6);
	getsockname(sock, cast(*sockaddr) *a, *n);
	l := New(Listener);
	l.sock, l.port = sock, ntohs(a.sin6_port);
	return l, .None;
}

// accept_tcp blocks until a client connects. It fails with .Closed once close_listener has run.
accept_tcp :: (l: *Listener) -> *Tcp, Error {
	a: sockaddr_in6;
	#if OS == .WINDOWS n: s32 = size_of(sockaddr_in6);
	else n: socklen_t = size_of(sockaddr_in6);
	sock := accept(l.sock, cast(*sockaddr) *a, *n);
	if atomic_load(*l.shut) { if sock != INVALID_SOCKET close_and_reset(*sock); return null, .Closed; }
	if sock == INVALID_SOCKET return null, .Io;
	one: s32 = 1;
	#if OS == .MACOS setsockopt(sock, SOL_SOCKET, SO_NOSIGPIPE, *one, size_of(s32));
	setsockopt(sock, xx IPPROTO.TCP, TCP_NODELAY, xx *one, size_of(s32));
	t := New(Tcp);
	t.sock = sock;
	memcpy(t.peer.data, *a.sin6_addr, 16);
	tcp_set_timeout(t, DIAL_IO_TIMEOUT_MS);
	return t, .None;
}

// close_listener wakes a thread blocked in accept_tcp; free the Listener once that thread has returned.
close_listener :: (l: *Listener) {
	if atomic_exchange(*l.shut, true) return;
	#if OS == .WINDOWS shutdown(l.sock, SD_BOTH);
	else shutdown(l.sock, .RDWR);
	close_and_reset(*l.sock);
}

// A UDP socket on every IPv6 and IPv4 address, for a server: addresses are 16 bytes, IPv4 as ::ffff:a.b.c.d.
Udp :: struct {
	sock: Socket;
	port: int;
}

// listen_udp binds port (0 picks one: see Udp.port). Each receive waits at most timeout_ms.
listen_udp :: (port: int, timeout_ms: s64) -> *Udp, Error {
	#if OS == .WINDOWS socket_init();
	sock := socket(AF_INET6, .DGRAM, .UDP);
	if sock == INVALID_SOCKET return null, .Dial;
	zero: s32 = 0;
	setsockopt(sock, xx IPPROTO.IPV6, IPV6_V6ONLY, xx *zero, size_of(s32));
	any: [16]u8;
	if bind(sock, any, cast(u16) port) != 0 { close_and_reset(*sock); return null, .Dial; }
	u := New(Udp);
	u.sock = sock;
	socket_timeout(sock, timeout_ms);
	a: sockaddr_in6;
	#if OS == .WINDOWS n: s32 = size_of(sockaddr_in6);
	else n: socklen_t = size_of(sockaddr_in6);
	getsockname(sock, cast(*sockaddr) *a, *n);
	u.port = ntohs(a.sin6_port);
	return u, .None;
}

// udp_recv: one datagram into buf and who sent it; n <= 0 on a timeout or error.
udp_recv :: (u: *Udp, buf: []u8) -> n: int, addr: [16]u8, port: int {
	a: sockaddr_in6;
	#if OS == .WINDOWS n: s32 = size_of(sockaddr_in6);
	else n: socklen_t = size_of(sockaddr_in6);
	got := recvfrom(u.sock, buf.data, xx buf.count, 0, cast(*sockaddr) *a, *n);
	addr: [16]u8;
	memcpy(addr.data, *a.sin6_addr, 16);
	return got, addr, ntohs(a.sin6_port);
}

udp_send :: (u: *Udp, data: []u8, addr: [16]u8, port: int) {
	a: sockaddr_in6;
	#if OS == .MACOS a.sin6_len = size_of(sockaddr_in6);
	a.sin6_family = xx AF_INET6;
	a.sin6_port = htons(cast(u16) port);
	memcpy(*a.sin6_addr, addr.data, 16);
	sendto(u.sock, data.data, xx data.count, 0, cast(*sockaddr) *a, xx size_of(sockaddr_in6));
}

// close_udp: once no thread is in udp_recv (its timeout bounds the wait).
close_udp :: (u: *Udp) {
	close_and_reset(*u.sock);
	free(u);
}

#scope_file

#import "Basic";
#import "Atomics";
#import "Socket";
#if OS != .WINDOWS #import "POSIX";
locks :: #import "locks";

tcp_set_timeout :: (data: *void, timeout_ms: s64) { socket_timeout((cast(*Tcp) data).sock, timeout_ms); }

socket_timeout :: (sock: Socket, timeout_ms: s64) {
	#if OS == .WINDOWS {
		v: u32 = xx timeout_ms;
	} else {
		v: timeval;
		v.tv_sec = xx (timeout_ms / 1000);
		v.tv_usec = xx ((timeout_ms % 1000) * 1000);
	}
	setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, xx *v, size_of(type_of(v)));
	setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, xx *v, size_of(type_of(v)));
}

// tcp_shutdown: shutdown(2) both directions; a blocked recv returns 0 (.Closed).
tcp_shutdown :: (data: *void) {
	t := cast(*Tcp) data;
	if atomic_exchange(*t.shut, true) return;
	#if OS == .WINDOWS shutdown(t.sock, SD_BOTH);
	else shutdown(t.sock, .RDWR);
}

// The error of a failed send/recv: a socket timeout (SO_RCVTIMEO / SO_SNDTIMEO) or anything else.
failure :: () -> Error {
	e := get_last_socket_error();
	#if OS == .WINDOWS return ifx e == WSAETIMEDOUT then .Timeout else .Io;
	else return ifx e == EAGAIN || e == ETIMEDOUT then .Timeout else .Io;
}

tcp_read :: (data: *void, dst: []u8) -> int, Error {
	t := cast(*Tcp) data;
	if t.closed || atomic_load(*t.shut) return 0, .Closed;
	locks.may_block("TCP read");
	n := recv(t.sock, dst.data, xx dst.count, 0);
	if atomic_load(*t.shut) return 0, .Closed;
	if n < 0 return 0, failure();
	if n == 0 return 0, .Closed;
	return n, .None;
}

tcp_write :: (data: *void, src: []u8) -> Error {
	t := cast(*Tcp) data;
	if t.closed || atomic_load(*t.shut) return .Closed;
	locks.may_block("TCP write");
	rest := src;
	while rest.count {
		n := send(t.sock, rest.data, xx rest.count, SEND_FLAGS);
		if n < 0 return failure();
		rest.data += n; rest.count -= n;
	}
	return .None;
}

// a closed peer is an error, not SIGPIPE: macOS sets SO_NOSIGPIPE at dial, Linux asks per send
#if OS == .LINUX SEND_FLAGS :: MSG.NOSIGNAL; else SEND_FLAGS :: cast(MSG) 0;

tcp_close :: (data: *void) {
	t := cast(*Tcp) data;
	if !t.closed close_and_reset(*t.sock);
	free(t);
}
