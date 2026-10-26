package http

import "fc:netio"

READER_SIZE :: 32 * 1024

// Reader buffers a netio.Stream. Used by h1 (lines), WebSocket and h2 (frames).
// Bytes read ahead (e.g. after a 101 response) stay in the buffer for the next layer.
Reader :: struct {
	s:     netio.Stream,
	buf:   []byte,
	start: int,
	end:   int,
}

reader_init :: proc(r: ^Reader, s: netio.Stream, size := READER_SIZE, allocator := context.allocator) {
	r.s = s
	r.buf = make([]byte, size, allocator)
	r.start = 0
	r.end = 0
}

reader_destroy :: proc(r: ^Reader, allocator := context.allocator) {
	delete(r.buf, allocator)
	r^ = {}
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

// read_line returns a line without its CRLF (bare LF tolerated). The slice is
// only valid until the next read. Lines longer than the buffer are .Too_Large.
read_line :: proc(r: ^Reader) -> (string, Error) {
	scanned := 0
	for {
		for i in r.start + scanned ..< r.end {
			if r.buf[i] == '\n' {
				line := r.buf[r.start:i]
				r.start = i + 1
				if len(line) > 0 && line[len(line) - 1] == '\r' do line = line[:len(line) - 1]
				return string(line), .None
			}
		}
		scanned = r.end - r.start
		if err := fill(r); err != .None do return "", err
	}
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

// peek_exact returns the next n bytes without consuming (n <= buffer size).
peek_exact :: proc(r: ^Reader, n: int) -> ([]byte, Error) {
	if n > len(r.buf) do return nil, .Too_Large
	for r.end - r.start < n {
		if r.start > 0 && r.start + n > len(r.buf) {
			m := r.end - r.start
			copy(r.buf, r.buf[r.start:r.end])
			r.start = 0
			r.end = m
		}
		nn, err := netio.read(r.s, r.buf[r.end:])
		if err != .None do return nil, map_net_error(err)
		r.end += nn
	}
	return r.buf[r.start:][:n], .None
}

consume :: proc(r: ^Reader, n: int) {r.start += n}
