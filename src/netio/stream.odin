// Package netio is the byte-stream abstraction every protocol layer sits on.
// TCP, TLS, and test pipes all implement Stream so HTTP/1.1, HTTP/2 and
// WebSocket code never cares what is underneath.
package netio

import "core:net"
import "core:sync"
import "core:time"

Error :: enum {
	None,
	Dial,
	Closed,
	Io,
	Tls,
	Protocol,
	Timeout,
	Too_Large,
}

Stream :: struct {
	data:  rawptr,
	// Reads at least 1 byte (blocking) unless error. Returns .Closed on EOF.
	read:  proc(data: rawptr, dst: []byte) -> (int, Error),
	// Writes all of src or errors.
	write: proc(data: rawptr, src: []byte) -> Error,
	close: proc(data: rawptr),
	// Optional. Wakes any thread blocked in read (it returns .Closed) and makes
	// later reads/writes fail, WITHOUT freeing anything. Layered streams (TLS)
	// should forward to the stream underneath. Safe to call from any thread.
	shutdown: proc(data: rawptr),
}

read :: proc(s: Stream, dst: []byte) -> (int, Error) {return s.read(s.data, dst)}
write :: proc(s: Stream, src: []byte) -> Error {return s.write(s.data, src)}
// close frees the stream. It must not race a read/write on another thread:
// call shutdown first, wait for those threads to return, then close.
close :: proc(s: Stream) {s.close(s.data)}
shutdown :: proc(s: Stream) {if s.shutdown != nil do s.shutdown(s.data)}

read_full :: proc(s: Stream, dst: []byte) -> Error {
	off := 0
	for off < len(dst) {
		n, err := s.read(s.data, dst[off:])
		if err != .None do return err
		off += n
	}
	return .None
}

Tcp :: struct {
	sock:     net.TCP_Socket,
	closed:   bool,
	shut:     bool, // atomic
}

dial_tcp :: proc(host: string, port: int) -> (t: ^Tcp, err: Error) {
	sock, nerr := net.dial_tcp_from_hostname_with_port_override(host, port)
	if nerr != nil do return nil, .Dial
	net.set_option(sock, .TCP_Nodelay, true)
	t = new(Tcp)
	t.sock = sock
	return t, .None
}

tcp_set_read_timeout :: proc(t: ^Tcp, d: time.Duration) {
	net.set_option(t.sock, .Receive_Timeout, d)
}

tcp_stream :: proc(t: ^Tcp) -> Stream {
	return Stream{data = t, read = tcp_read, write = tcp_write, close = tcp_close, shutdown = tcp_shutdown}
}

// tcp_shutdown: shutdown(2) both directions; a blocked recv returns 0 (.Closed).
@(private)
tcp_shutdown :: proc(data: rawptr) {
	t := cast(^Tcp)data
	if sync.atomic_exchange(&t.shut, true) do return
	net.shutdown(t.sock, .Both)
}

@(private)
tcp_read :: proc(data: rawptr, dst: []byte) -> (int, Error) {
	t := cast(^Tcp)data
	if t.closed || sync.atomic_load(&t.shut) do return 0, .Closed
	n, err := net.recv_tcp(t.sock, dst)
	if sync.atomic_load(&t.shut) do return 0, .Closed
	if err != nil {
		if err == net.TCP_Recv_Error.Timeout do return 0, .Timeout
		return 0, .Io
	}
	if n == 0 do return 0, .Closed
	return n, .None
}

@(private)
tcp_write :: proc(data: rawptr, src: []byte) -> Error {
	t := cast(^Tcp)data
	if t.closed || sync.atomic_load(&t.shut) do return .Closed
	off := 0
	for off < len(src) {
		n, err := net.send_tcp(t.sock, src[off:])
		if err != nil do return .Io
		off += n
	}
	return .None
}

@(private)
tcp_close :: proc(data: rawptr) {
	t := cast(^Tcp)data
	if !t.closed {
		net.close(t.sock)
		t.closed = true
	}
	free(t)
}

// Pipe is an in-memory duplex used by tests: writes to one end are read from the other.
