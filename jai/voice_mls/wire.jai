Error :: enum u8 {
	None;
	Decode;      // malformed TLS-presentation encoding
	Unsupported; // valid MLS we do not implement (other suites, PrivateMessage, ReInit...)
	Crypto;      // AEAD / HPKE / key failure
	Verify;      // bad signature, MAC, tree hash, parent hash...
	State;       // message does not fit the current group state
}

// ---------------------------------------------------------------------------
// Writer: TLS presentation language with MLS variable-size vector headers.

Writer :: struct {
	buf: [..]u8;
}

writer_make :: (allocator := temp) -> Writer {
	w: Writer;
	w.buf.allocator = allocator;
	array_reserve(*w.buf, 256);
	return w;
}

w_u8 :: (w: *Writer, v: u8) { array_add(*w.buf, v); }
w_u16 :: (w: *Writer, v: u16) { array_add(*w.buf, cast(u8) (v >> 8), cast(u8) v); }
w_u32 :: (w: *Writer, v: u32) { array_add(*w.buf, cast(u8) (v >> 24), cast(u8) (v >> 16), cast(u8) (v >> 8), cast(u8) v); }
w_u64 :: (w: *Writer, v: u64) {
	w_u32(w, cast(u32) (v >> 32));
	w_u32(w, cast(u32) v);
}
w_raw :: (w: *Writer, b: []u8) { array_add(*w.buf, ..b); }
w_raw :: (w: *Writer, s: string) { array_add(*w.buf, ..cast([]u8) s); }

w_varint :: (w: *Writer, n: int) {
	if n < (1 << 6) w_u8(w, cast(u8) n);
	else if n < (1 << 14) w_u16(w, (cast(u16) n) | 0x4000);
	else {
		assert(n < (1 << 30));
		w_u32(w, (cast(u32) n) | 0x8000_0000);
	}
}

// w_vec writes opaque data<V>.
w_vec :: (w: *Writer, b: []u8) {
	w_varint(w, b.count);
	w_raw(w, b);
}

// w_begin / w_end wrap a nested vector without a temp buffer: w_begin
// reserves a 4-byte header, w_end shrinks it to the minimal varint.
w_begin :: (w: *Writer) -> int {
	pos := w.buf.count;
	array_add(*w.buf, 0, 0, 0, 0);
	return pos;
}

w_end :: (w: *Writer, pos: int) {
	n := w.buf.count - pos - 4;
	hdr: [4]u8;
	hl := 4;
	if n < (1 << 6) {
		hdr[0] = cast(u8) n;
		hl = 1;
	} else if n < (1 << 14) {
		hdr[0] = (cast(u8) (n >> 8)) | 0x40;
		hdr[1] = cast(u8) n;
		hl = 2;
	} else {
		hdr = .[(cast(u8) (n >> 24)) | 0x80, cast(u8) (n >> 16), cast(u8) (n >> 8), cast(u8) n];
	}
	if hl < 4 {
		for i: 0..n-1 w.buf[pos + hl + i] = w.buf[pos + 4 + i];  // overlapping, moving left
		w.buf.count -= 4 - hl;
	}
	memcpy(w.buf.data + pos, hdr.data, hl);
}

w_optional :: (w: *Writer, present: bool) { w_u8(w, cast(u8) present); }

// ---------------------------------------------------------------------------
// Reader. Slices returned point into the input buffer.

Reader :: struct {
	data: []u8;
	pos: int;
	err: bool;
}

reader_make :: (b: []u8) -> Reader { return .{data = b}; }

r_ok :: (r: *Reader) -> bool { return !r.err; }
r_done :: (r: *Reader) -> bool { return !r.err && r.pos == r.data.count; }
r_left :: (r: *Reader) -> int { return r.data.count - r.pos; }

r_fail :: (r: *Reader) {
	r.err = true;
	r.pos = r.data.count;
}

r_raw :: (r: *Reader, n: int) -> []u8 {
	if r.err || n < 0 || r.pos + n > r.data.count {
		r_fail(r);
		return .[];
	}
	b: []u8 = .{n, r.data.data + r.pos};
	r.pos += n;
	return b;
}

r_u8 :: (r: *Reader) -> u8 {
	b := r_raw(r, 1);
	return ifx b.count then b[0] else 0;
}
r_u16 :: (r: *Reader) -> u16 {
	b := r_raw(r, 2);
	return ifx b.count then ((cast(u16) b[0]) << 8) | b[1] else 0;
}
r_u32 :: (r: *Reader) -> u32 {
	b := r_raw(r, 4);
	return ifx b.count then ((cast(u32) b[0]) << 24) | ((cast(u32) b[1]) << 16) | ((cast(u32) b[2]) << 8) | b[3] else 0;
}
r_u64 :: (r: *Reader) -> u64 {
	hi := r_u32(r);
	lo := r_u32(r);
	return ((cast(u64) hi) << 32) | lo;
}

r_varint :: (r: *Reader) -> int {
	if r.err || r.pos >= r.data.count {
		r_fail(r);
		return 0;
	}
	if r.data[r.pos] >> 6 == {
	case 0;
		r.pos += 1;
		return r.data[r.pos - 1];
	case 1;
		v := cast(int) (r_u16(r) & 0x3fff);
		if v < (1 << 6) r_fail(r); // must be minimal
		return v;
	case 2;
		v := cast(int) (r_u32(r) & 0x3fff_ffff);
		if v < (1 << 14) r_fail(r);
		return v;
	}
	r_fail(r);
	return 0;
}

// r_since: the bytes consumed since position start.
r_since :: (r: *Reader, start: int) -> []u8 { return .{r.pos - start, r.data.data + start}; }

r_vec :: (r: *Reader) -> []u8 { return r_raw(r, r_varint(r)); }
r_sub :: (r: *Reader) -> Reader { return reader_make(r_vec(r)); }

r_optional :: (r: *Reader) -> bool {
	v := r_u8(r);
	if v > 1 r_fail(r);
	return v == 1;
}

// ---------------------------------------------------------------------------

// clone_bytes copies into context.allocator; empty stays empty (null data).
clone_bytes :: (b: []u8) -> []u8 {
	if !b.count return .[];
	return array_copy(b);
}

bytes_equal :: (a: []u8, b: []u8) -> bool { return cast(string) a == cast(string) b; }
