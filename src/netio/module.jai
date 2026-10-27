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
}

// dial_tcp resolves host and connects to its first IPv4 address, else its first IPv6 one.
dial_tcp :: (host: string, port: int, loc := #caller_location) -> *Tcp, Error {
	locks.may_block("TCP dial", loc);
	hints: addrinfo;
	hints.ai_family = AF_UNSPEC;
	hints.ai_socktype = .STREAM;
	res: *addrinfo;
	if getaddrinfo(temp_c_string(host), temp_c_string(tprint("%", port)), *hints, *res) != 0 return null, .Dial;
	defer freeaddrinfo(res);
	ai: *addrinfo;
	p := res;
	while p {
		if p.ai_family == AF_INET { ai = p; break; }
		if p.ai_family == AF_INET6 && !ai ai = p;
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

tcp_stream :: (t: *Tcp) -> Stream {
	return .{data = t, read = tcp_read, write = tcp_write, close = tcp_close, shutdown = tcp_shutdown, set_timeout = tcp_set_timeout};
}

#scope_file

#import "Basic";
#import "Atomics";
#import "Socket";
#if OS != .WINDOWS #import "POSIX";
locks :: #import "locks";

tcp_set_timeout :: (data: *void, timeout_ms: s64) {
	t := cast(*Tcp) data;
	#if OS == .WINDOWS {
		v: u32 = xx timeout_ms;
	} else {
		v: timeval;
		v.tv_sec = xx (timeout_ms / 1000);
		v.tv_usec = xx ((timeout_ms % 1000) * 1000);
	}
	setsockopt(t.sock, SOL_SOCKET, SO_RCVTIMEO, xx *v, size_of(type_of(v)));
	setsockopt(t.sock, SOL_SOCKET, SO_SNDTIMEO, xx *v, size_of(type_of(v)));
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
