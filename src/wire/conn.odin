// Package wire is the byte-stream layer: TCP, optional TLS, buffered reads.
// HTTP/1.1, WebSocket and the Discord transports sit on top of Conn.
package wire

import "core:net"
import "core:strings"
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

// A Tls_Session is anything that can encrypt a byte stream over a socket.
// The tls package fills this in; plaintext connections leave it nil.
Tls_Session :: struct {
	data:  rawptr,
	read:  proc(data: rawptr, sock: net.TCP_Socket, dst: []byte) -> (int, Error),
	write: proc(data: rawptr, sock: net.TCP_Socket, src: []byte) -> Error,
	close: proc(data: rawptr, sock: net.TCP_Socket),
}

Conn :: struct {
	sock:   net.TCP_Socket,
	tls:    Maybe(Tls_Session),
	host:   string,
	port:   int,
	rbuf:   [dynamic]byte,
	rpos:   int,
	closed: bool,
}

dial :: proc(host: string, port: int, timeout := 10 * time.Second) -> (c: ^Conn, err: Error) {
	sock, nerr := net.dial_tcp_from_hostname_with_port_override(host, port)
	if nerr != nil {
		return nil, .Dial
	}
	net.set_option(sock, .TCP_Nodelay, true)
	c = new(Conn)
	c.sock = sock
	c.host = strings.clone(host)
	c.port = port
	reserve(&c.rbuf, 64 * 1024)
	return c, .None
}

// Sets the receive timeout. Zero means block forever.
set_read_timeout :: proc(c: ^Conn, d: time.Duration) {
	net.set_option(c.sock, .Receive_Timeout, d)
}

close :: proc(c: ^Conn) {
	if c == nil do return
	if !c.closed {
		if t, ok := c.tls.?; ok do t.close(t.data, c.sock)
		net.close(c.sock)
		c.closed = true
	}
}

destroy :: proc(c: ^Conn) {
	if c == nil do return
	close(c)
	delete(c.rbuf)
	delete(c.host)
	free(c)
}

write :: proc(c: ^Conn, data: []byte) -> Error {
	if c.closed do return .Closed
	if t, ok := c.tls.?; ok {
		return t.write(t.data, c.sock, data)
	}
	return raw_write(c.sock, data)
}

raw_write :: proc(sock: net.TCP_Socket, data: []byte) -> Error {
	off := 0
	for off < len(data) {
		n, err := net.send_tcp(sock, data[off:])
		if err != nil || n <= 0 do return .Io
		off += n
	}
	return .None
}

raw_read :: proc(sock: net.TCP_Socket, dst: []byte) -> (int, Error) {
	n, err := net.recv_tcp(sock, dst)
	for err == .Interrupted do n, err = net.recv_tcp(sock, dst)
	if err != nil {
		// SO_RCVTIMEO expiry surfaces as EAGAIN (Would_Block) on posix.
		if err == .Timeout || err == .Would_Block do return 0, .Timeout
		return 0, .Io
	}
	if n == 0 do return 0, .Closed
	return n, .None
}

// Pulls more bytes from the socket into the read buffer.
@(private)
fill :: proc(c: ^Conn) -> Error {
	if c.closed do return .Closed
	if c.rpos > 0 && c.rpos == len(c.rbuf) {
		clear(&c.rbuf)
		c.rpos = 0
	} else if c.rpos > 32 * 1024 {
		copy(c.rbuf[:], c.rbuf[c.rpos:])
		resize(&c.rbuf, len(c.rbuf) - c.rpos)
		c.rpos = 0
	}
	tmp: [16 * 1024]byte
	n: int
	err: Error
	if t, ok := c.tls.?; ok {
		n, err = t.read(t.data, c.sock, tmp[:])
	} else {
		n, err = raw_read(c.sock, tmp[:])
	}
	if err != .None do return err
	append(&c.rbuf, ..tmp[:n])
	return .None
}

// Waits up to `timeout` for at least one readable byte without consuming it.
// Use this before a framed read so a timeout never splits a frame.
poll :: proc(c: ^Conn, timeout: time.Duration) -> Error {
	if len(buffered(c)) > 0 do return .None
	set_read_timeout(c, timeout)
	err := fill(c)
	set_read_timeout(c, 0)
	return err
}

buffered :: proc(c: ^Conn) -> []byte {
	return c.rbuf[c.rpos:]
}

consume :: proc(c: ^Conn, n: int) {
	c.rpos += n
}

// Reads exactly len(dst) bytes.
read_full :: proc(c: ^Conn, dst: []byte) -> Error {
	off := 0
	for off < len(dst) {
		if len(buffered(c)) == 0 {
			if err := fill(c); err != .None do return err
		}
		b := buffered(c)
		n := copy(dst[off:], b)
		consume(c, n)
		off += n
	}
	return .None
}

// Reads whatever is available (at least one byte).
read_some :: proc(c: ^Conn, dst: []byte) -> (int, Error) {
	if len(buffered(c)) == 0 {
		if err := fill(c); err != .None do return 0, err
	}
	n := copy(dst, buffered(c))
	consume(c, n)
	return n, .None
}

// Reads one CRLF-terminated line, returned without the terminator.
// The returned slice is only valid until the next read.
read_line :: proc(c: ^Conn, max_len := 64 * 1024) -> (line: string, err: Error) {
	scanned := 0
	for {
		b := buffered(c)
		for i := scanned; i + 1 < len(b); i += 1 {
			if b[i] == '\r' && b[i + 1] == '\n' {
				line = string(b[:i])
				consume(c, i + 2)
				return line, .None
			}
		}
		scanned = max(0, len(b) - 1)
		if len(b) > max_len do return "", .Too_Large
		if err = fill(c); err != .None do return "", err
	}
}
