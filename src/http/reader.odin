package http

import "core:mem"
import "fc:netio"

READER_SIZE :: 32 * 1024

// Reader buffers a netio.Stream for HTTP/1.1 and the WebSocket and HTTP/2 libraries.
// Bytes read ahead (e.g. after a 101 response) stay in the buffer for the next layer.
Reader :: struct {
	s:         netio.Stream,
	buf:       []byte,
	start:     int,
	end:       int,
	allocator: mem.Allocator,
}

reader_init :: proc(r: ^Reader, s: netio.Stream, size := READER_SIZE, allocator := context.allocator) {
	r^ = {s = s, buf = make([]byte, size, allocator), allocator = allocator}
}

reader_destroy :: proc(r: ^Reader) {
	delete(r.buf, r.allocator)
	r^ = {}
}

@(private)
reader_grow :: proc(r: ^Reader, size: int) {
	if size <= len(r.buf) do return
	b := make([]byte, size, r.allocator)
	copy(b, r.buf[r.start:r.end])
	delete(r.buf, r.allocator)
	r.buf, r.end, r.start = b, r.end - r.start, 0
}

map_net_error :: proc(e: netio.Error) -> Error {
	switch e {
	case .None:
		return .None
	case .Closed:
		return .Closed
	case .Timeout:
		return .Timeout
	case .Too_Large:
		return .Too_Large
	case .Protocol, .Tls:
		return .Protocol
	case .Dial, .Io:
		return .Io
	}
	return .Io
}

buffered :: proc(r: ^Reader) -> int {return r.end - r.start}

// fill reads more data from the stream (compacting first). Returns .Closed at EOF.
@(private)
fill :: proc(r: ^Reader) -> Error {
	if r.start > 0 {
		n := r.end - r.start
		copy(r.buf, r.buf[r.start:r.end])
		r.start = 0
		r.end = n
	}
	if r.end == len(r.buf) do return .Too_Large
	n, err := netio.read(r.s, r.buf[r.end:])
	if err != .None do return map_net_error(err)
	r.end += n
	return .None
}

// read_some copies up to len(dst) bytes, reading from the stream only if the buffer is empty.
read_some :: proc(r: ^Reader, dst: []byte) -> (int, Error) {
	if len(dst) == 0 do return 0, .None
	if r.start == r.end {
		// Large reads bypass the buffer.
		if len(dst) >= len(r.buf) {
			n, err := netio.read(r.s, dst)
			return n, map_net_error(err)
		}
		r.start = 0
		r.end = 0
		if err := fill(r); err != .None do return 0, err
	}
	n := copy(dst, r.buf[r.start:r.end])
	r.start += n
	return n, .None
}

read_exact :: proc(r: ^Reader, dst: []byte) -> Error {
	off := 0
	for off < len(dst) {
		n, err := read_some(r, dst[off:])
		if err != .None do return err
		off += n
	}
	return .None
}

consume :: proc(r: ^Reader, n: int) {r.start += n}
