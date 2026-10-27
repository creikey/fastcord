READER_SIZE :: 32 * 1024;

// Reader buffers a netio.Stream for HTTP/1.1 and WebSocket. Bytes read ahead (e.g. after a 101
// response) stay in the buffer for the next layer.
Reader :: struct {
	s: netio.Stream;
	buf: []u8;
	start, end: int;
	allocator: Allocator;
}

#scope_module

reader_init :: (r: *Reader, s: netio.Stream) {
	r.* = .{s = s, buf = NewArray(READER_SIZE, u8, initialized = false), allocator = context.allocator};
}

reader_destroy :: (r: *Reader) {
	array_free(r.buf,, r.allocator);
	r.* = .{};
}

// reader_grow makes the buffer size bytes, keeping the unread ones (moved to its start).
reader_grow :: (r: *Reader, size: int) {
	if size <= r.buf.count return;
	b := NewArray(size, u8, initialized = false,, r.allocator);
	memcpy(b.data, r.buf.data + r.start, r.end - r.start);
	array_free(r.buf,, r.allocator);
	r.buf, r.end, r.start = b, r.end - r.start, 0;
}

map_net_error :: (e: netio.Error) -> Error {
	if e == {
		case .None;      return .None;
		case .Closed;    return .Closed;
		case .Timeout;   return .Timeout;
		case .Too_Large; return .Too_Large;
		case .Protocol; #through;
		case .Tls;       return .Protocol;
	}
	return .Io;
}

// fill reads more data from the stream (compacting first). Returns .Closed at EOF.
fill :: (r: *Reader) -> Error {
	if r.start > 0 {
		n := r.end - r.start;
		for i: 0..n-1 r.buf[i] = r.buf[r.start + i]; // the ranges may overlap
		r.start, r.end = 0, n;
	}
	if r.end == r.buf.count return .Too_Large;
	n, err := netio.read(r.s, array_view(r.buf, r.end));
	if err != .None return map_net_error(err);
	r.end += n;
	return .None;
}

// read_some copies up to dst.count bytes, reading from the stream only if the buffer is empty.
read_some :: (r: *Reader, dst: []u8) -> int, Error {
	if !dst.count return 0, .None;
	if r.start == r.end {
		// Large reads bypass the buffer.
		if dst.count >= r.buf.count {
			n, err := netio.read(r.s, dst);
			return n, map_net_error(err);
		}
		r.start, r.end = 0, 0;
		err := fill(r);
		if err != .None return 0, err;
	}
	n := min(dst.count, r.end - r.start);
	memcpy(dst.data, r.buf.data + r.start, n);
	r.start += n;
	return n, .None;
}

read_exact :: (r: *Reader, dst: []u8) -> Error {
	off := 0;
	while off < dst.count {
		n, err := read_some(r, array_view(dst, off));
		if err != .None return err;
		off += n;
	}
	return .None;
}
