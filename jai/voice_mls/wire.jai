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
	return Writer.{buf = make_dynamic(u8, 0, 256, allocator)};
}

w_u8 :: (w: *Writer, v: u8) {append(*w.buf, v);}
w_u16 :: (w: *Writer, v: u16) {append(*w.buf, cast,no_check(u8)(v >> 8), cast,no_check(u8)(v));}
w_u32 :: (w: *Writer, v: u32) {append(*w.buf, cast,no_check(u8)(v >> 24), cast,no_check(u8)(v >> 16), cast,no_check(u8)(v >> 8), cast,no_check(u8)(v));}
w_u64 :: (w: *Writer, v: u64) {
	w_u32(w, cast(u32)(v >> 32));
	w_u32(w, cast,no_check(u32)(v));
}
w_raw :: (w: *Writer, b: []u8) {append(*w.buf, ..b);}

w_varint :: (w: *Writer, n: int) {
	if n < (1 << 6) {
		w_u8(w, cast(u8)(n));
	} else if n < (1 << 14) {
		w_u16(w, (cast(u16)(n)) | 0x4000);
	} else {
		assert(n < (1 << 30));
		w_u32(w, (cast(u32)(n)) | 0x8000_0000);
	}
}

// w_vec writes opaque data<V>.
w_vec :: (w: *Writer, b: []u8) {
	w_varint(w, len(b));
	w_raw(w, b);
}

// w_begin / w_end wrap a nested vector without a temp buffer: w_begin
// reserves a 4-byte header, w_end shrinks it to the minimal varint.
w_begin :: (w: *Writer) -> int {
	pos := len(w.buf);
	append(*w.buf, 0, 0, 0, 0);
	return pos;
}

w_end :: (w: *Writer, pos: int) {
	n := len(w.buf) - pos - 4;
	hdr: [4]u8;
	hl := 0;
	if n < (1 << 6) {
		hdr[0] = cast,no_check(u8)(n);
		hl = 1;
	} else if n < (1 << 14) {
		hdr[0] = cast,no_check(u8)(n >> 8) | 0x40;
		hdr[1] = cast,no_check(u8)(n);
		hl = 2;
	} else {
		hdr = .[cast,no_check(u8)(n >> 24) | 0x80, cast,no_check(u8)(n >> 16), cast,no_check(u8)(n >> 8), cast,no_check(u8)(n)];
		hl = 4;
	}
	if hl < 4 {
		copy(sub_from(w.buf, pos + hl), sub_from(w.buf, pos + 4));
		resize(*w.buf, len(w.buf) - (4 - hl));
	}
	copy(sub_from(w.buf, pos), sub(hdr, 0, hl));
}

w_optional :: (w: *Writer, present: bool) {w_u8(w, cast(u8) present);}

// ---------------------------------------------------------------------------
// Reader. Slices returned point into the input buffer.

Reader :: struct {
	data: []u8;
	pos: int;
	err: bool;
}

reader_make :: (b: []u8) -> Reader {return Reader.{data = b};}

r_ok :: (r: *Reader) -> bool {return !r.err;}
r_done :: (r: *Reader) -> bool {return !r.err && r.pos == len(r.data);}
r_left :: (r: *Reader) -> int {return len(r.data) - r.pos;}

r_fail :: (r: *Reader) {
	r.err = true;
	r.pos = len(r.data);
}

r_raw :: (r: *Reader, n: int) -> []u8 {
	if r.err || n < 0 || r.pos + n > len(r.data) {
		r_fail(r);
		return .{};
	}
	b := sub(r.data, r.pos, r.pos + n);
	r.pos += n;
	return b;
}

r_u8 :: (r: *Reader) -> u8 {
	b := r_raw(r, 1);
	return ifx b.count then b[0] else 0;
}
r_u16 :: (r: *Reader) -> u16 {
	b := r_raw(r, 2);
	return ifx b.count then ((cast(u16)(b[0])) << 8) | (cast(u16)(b[1])) else 0;
}
r_u32 :: (r: *Reader) -> u32 {
	b := r_raw(r, 4);
	return ifx b.count then ((cast(u32)(b[0])) << 24) | ((cast(u32)(b[1])) << 16) | ((cast(u32)(b[2])) << 8) | (cast(u32)(b[3])) else 0;
}
r_u64 :: (r: *Reader) -> u64 {
	hi := r_u32(r);
	lo := r_u32(r);
	return ((cast(u64)(hi)) << 32) | (cast(u64)(lo));
}

r_varint :: (r: *Reader) -> int {
	if r.err || r.pos >= len(r.data) {
		r_fail(r);
		return 0;
	}
	first := r.data[r.pos];
	if first >> 6 == {
	case 0;
		r.pos += 1;
		return cast(int)(first);
	case 1;
		v := cast(int)(r_u16(r) & 0x3fff);
		if v < (1 << 6) { r_fail(r); } // must be minimal
		return v;
	case 2;
		v := cast(int)(r_u32(r) & 0x3fff_ffff);
		if v < (1 << 14) { r_fail(r); }
		return v;
	}
	r_fail(r);
	return 0;
}

r_vec :: (r: *Reader) -> []u8 {
	n := r_varint(r);
	return r_raw(r, n);
}

r_sub :: (r: *Reader) -> Reader {
	return reader_make(r_vec(r));
}

r_optional :: (r: *Reader) -> bool {
	v := r_u8(r);
	if v > 1 { r_fail(r); }
	return v == 1;
}

// ---------------------------------------------------------------------------

clone_bytes :: (b: []u8, allocator: Allocator) -> []u8 {
	if len(b) == 0 { return .{}; }
	out := make_slice(u8, len(b), allocator);
	copy(out, b);
	return out;
}

bytes_equal :: (a: []u8, b: []u8) -> bool {
	if len(a) != len(b) { return false; }
	for i: 0..len(a)-1 { if a[i] != b[i] { return false; } }
	return true;
}

