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
	set_timeout: (data: *void, d: time.Duration);
}

// Every dialed connection starts with this bound on each read and write, so a peer that goes silent
// during TLS or protocol handshakes fails the connect instead of blocking its thread (and any thread
// joining it) forever. Long-lived connections call set_timeout(s, 0) once established, after which
// their own heartbeats and shutdown() take over.
DIAL_IO_TIMEOUT :: 20 * time.Second;

read :: (s: Stream, dst: []u8) -> int, Error {{ __r1, __r2 := s.read(s.data, dst); return __r1, __r2; }}
write :: (s: Stream, src: []u8) -> Error {return s.write(s.data, src);}
// close frees the stream. It must not race a read/write on another thread:
// call shutdown first, wait for those threads to return, then close.
close :: (s: Stream) {s.close(s.data);}
shutdown :: (s: Stream) {if s.shutdown != null { s.shutdown(s.data); }}
set_timeout :: (s: Stream, d: time.Duration) {if s.set_timeout != null { s.set_timeout(s.data, d); }}

read_full :: (s: Stream, dst: []u8) -> Error {
	off := 0;
	while off < len(dst) {
		n, err := s.read(s.data, sub_from(dst, off));
		if err != .None { return err; }
		off += n;
	}
	return .None;
}

Tcp :: struct {
	sock: net.TCP_Socket;
	closed: bool;
	shut: bool; // atomic
}

dial_tcp :: (host: string, port: int, loc := #caller_location) -> *Tcp, Error {
	t: *Tcp;
	err: Error;
	locks.may_block("TCP dial", loc);
	sock, nerr := net.dial_tcp_from_hostname_with_port_override(host, port);
	if nerr != null { return null, .Dial; }
	net.set_option(sock, .TCP_Nodelay, true);
	t = new(Tcp);
	t.sock = sock;
	tcp_set_timeout(t, DIAL_IO_TIMEOUT);
	return t, .None;
}

tcp_set_timeout :: (t: *Tcp, d: time.Duration) {
	net.set_option(t.sock, .Receive_Timeout, d);
	net.set_option(t.sock, .Send_Timeout, d);
}

tcp_stream :: (t: *Tcp) -> Stream {
	return Stream.{data = t, read = tcp_read, write = tcp_write, close = tcp_close, shutdown = tcp_shutdown, set_timeout = tcp_set_timeout_raw};
}
#scope_module

tcp_set_timeout_raw :: (data: *void, d: time.Duration) {tcp_set_timeout(cast(*Tcp)data, d);}

// tcp_shutdown: shutdown(2) both directions; a blocked recv returns 0 (.Closed).
tcp_shutdown :: (data: *void) {
	t := cast(*Tcp)data;
	if sync.atomic_exchange(*t.shut, true) { return; }
	net.shutdown(t.sock, .Both);
}

tcp_read :: (data: *void, dst: []u8) -> int, Error {
	t := cast(*Tcp)data;
	if t.closed || sync.atomic_load(*t.shut) { return 0, .Closed; }
	locks.may_block("TCP read");
	n, err := net.recv_tcp(t.sock, dst);
	if sync.atomic_load(*t.shut) { return 0, .Closed; }
	if err != null {
		if err == net.TCP_Recv_Error.Timeout { return 0, .Timeout; }
		return 0, .Io;
	}
	if n == 0 { return 0, .Closed; }
	return n, .None;
}

tcp_write :: (data: *void, src: []u8) -> Error {
	t := cast(*Tcp)data;
	if t.closed || sync.atomic_load(*t.shut) { return .Closed; }
	locks.may_block("TCP write");
	off := 0;
	while off < len(src) {
		n, err := net.send_tcp(t.sock, sub_from(src, off));
		if err != null { return ifx err == net.TCP_Send_Error.Timeout then .Timeout else .Io; }
		off += n;
	}
	return .None;
}

tcp_close :: (data: *void) {
	t := cast(*Tcp)data;
	if !t.closed {
		net.close(t.sock);
		t.closed = true;
	}
	free(t);
}
#scope_export

// Pipe is an in-memory duplex used by tests: writes to one end are read from the other.

