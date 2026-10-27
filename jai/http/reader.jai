READER_SIZE :: 32 * 1024;

// Reader buffers a netio.Stream for HTTP/1.1 and the WebSocket and HTTP/2 libraries.
// Bytes read ahead (e.g. after a 101 response) stay in the buffer for the next layer.
Reader :: struct {
	s: netio.Stream;
	buf: []u8;
	start: int;
	end: int;
	allocator: Allocator;
}

reader_init :: (r: *Reader, s: netio.Stream, size := READER_SIZE, allocator := context.allocator) {
	r.* = .{s = s, buf = make_slice(u8, size, allocator), allocator = allocator};
}

reader_destroy :: (r: *Reader) {
	delete(r.buf, r.allocator);
	r.* = .{};
}
#scope_module

reader_grow :: (r: *Reader, size: int) {
	if size <= len(r.buf) { return; }
	b := make_slice(u8, size, r.allocator);
	copy(b, sub(r.buf, r.start, r.end));
	delete(r.buf, r.allocator);
	r.buf, r.end, r.start = b, r.end - r.start, 0;
}
#scope_export

map_net_error :: (e: netio.Error) -> Error {
	if e == {
	case .None;
		return .None;
	case .Closed;
		return .Closed;
	case .Timeout;
		return .Timeout;
	case .Too_Large;
		return .Too_Large;
	case .Protocol; #through; case .Tls;
		return .Protocol;
	case .Dial; #through; case .Io;
		return .Io;
	}
	return .Io;
}

buffered :: (r: *Reader) -> int {return r.end - r.start;}
#scope_module

// fill reads more data from the stream (compacting first). Returns .Closed at EOF.
fill :: (r: *Reader) -> Error {
	if r.start > 0 {
		n := r.end - r.start;
		copy(r.buf, sub(r.buf, r.start, r.end));
		r.start = 0;
		r.end = n;
	}
	if r.end == len(r.buf) { return .Too_Large; }
	n, err := netio.read(r.s, sub_from(r.buf, r.end));
	if err != .None { return map_net_error(err); }
	r.end += n;
	return .None;
}
#scope_export

// read_some copies up to len(dst) bytes, reading from the stream only if the buffer is empty.
read_some :: (r: *Reader, dst: []u8) -> int, Error {
	if len(dst) == 0 { return 0, .None; }
	if r.start == r.end {
		// Large reads bypass the buffer.
		if len(dst) >= len(r.buf) {
			n, err := netio.read(r.s, dst);
			return n, map_net_error(err);
		}
		r.start = 0;
		r.end = 0;
		{ err := fill(r);
		if err != .None { return 0, err; } }
	}
	n := copy(dst, sub(r.buf, r.start, r.end));
	r.start += n;
	return n, .None;
}

read_exact :: (r: *Reader, dst: []u8) -> Error {
	off := 0;
	while off < len(dst) {
		n, err := read_some(r, sub_from(dst, off));
		if err != .None { return err; }
		off += n;
	}
	return .None;
}

consume :: (r: *Reader, n: int) {r.start += n;}

