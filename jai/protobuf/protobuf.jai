Wire_Type :: enum u8 {
	Varint :: 0;
	I64 :: 1;
	Len :: 2;
	I32 :: 5;
}

Field :: struct {
	num: u32;
	wire: Wire_Type;
	value: u64; // varint / fixed value
	bytes: []u8; // Len payload (submessage, string, packed)
}

Reader :: struct {
	buf: []u8;
	pos: int;
}

read_varint :: (r: *Reader) -> u64, bool {
	v: u64;
	ok: bool;
	shift: u64;
	while r.pos < len(r.buf) && shift < 64 {
		b := r.buf[r.pos];
		r.pos += 1;
		v |= (cast(u64)(b & 0x7f)) << shift;
		if (b & 0x80) == 0 { return v, true; }
		shift += 7;
	}
	return 0, false;
}

// Next field, or ok=false at end / on malformed input.
next :: (r: *Reader) -> Field, bool {
	f: Field;
	ok: bool;
	if r.pos >= len(r.buf) { return .{}, false; }
	tag, __e1 := read_varint(r); if failed(__e1) return f, __e1;
	f.num = cast,no_check(u32)(tag >> 3);
	f.wire = cast(Wire_Type)(tag & 7);
	if f.wire == {
	case .Varint;
		__v4, __e3 := read_varint(r); if failed(__e3) return f, __e3; f.value = __v4;
	case .I64;
		if r.pos + 8 > len(r.buf) { return .{}, false; }
		for i: 0..7 { f.value |= (cast(u64)(r.buf[r.pos + i])) << (8 * cast(u64)(i)); }
		r.pos += 8;
	case .I32;
		if r.pos + 4 > len(r.buf) { return .{}, false; }
		for i: 0..3 { f.value |= (cast(u64)(r.buf[r.pos + i])) << (8 * cast(u64)(i)); }
		r.pos += 4;
	case .Len;
		n, __e5 := read_varint(r); if failed(__e5) return f, __e5;
		if n > cast(u64)(len(r.buf) - r.pos) { return .{}, false; }
		f.bytes = sub(sub_from(r.buf, r.pos), 0, n);
		r.pos += cast(int)(n);
	case;
		return .{}, false;
	}
	return f, true;
}

// Finds the first field with this number at the top level of buf.
find :: (buf: []u8, num: u32) -> Field, bool {
	r := Reader.{buf = buf};
	while true { f, __ok6 := next(*r); if !__ok6 break;
		if f.num == num { return f, true; }
	}
	return .{}, false;
}

// Path lookup through nested submessages: find_path(buf, 2, 1) = field 1 of message field 2.
find_path :: (buf: []u8, path: ..u32) -> Field, bool {
	cur := buf;
	f: Field;
	for num, i: path {
		ok: bool;
		f, ok = find(cur, num);
		if !ok { return .{}, false; }
		if i < len(path) - 1 {
			if f.wire != .Len { return .{}, false; }
			cur = f.bytes;
		}
	}
	return f, true;
}

// Packed repeated varints / fixed64 (e.g. guild folder guild_ids are packed fixed64).
packed_fixed64 :: (b: []u8, allocator := context.allocator) -> []u64 {
	out := make_slice(u64, len(b) / 8, allocator);
	for i: 0..len(out)-1 {
		v: u64;
		for j: 0..7 { v |= (cast(u64)(b[i * 8 + j])) << (8 * cast(u64)(j)); }
		at(*out, i).* = v;
	}
	return out;
}

Writer :: struct {
	buf: [..]u8;
}

write_varint :: (w: *Writer, v: u64) {
	x := v;
	while x >= 0x80 {
		append(*w.buf, cast,no_check(u8)(x) | 0x80);
		x >>= 7;
	}
	append(*w.buf, cast(u8)(x));
}

write_tag :: (w: *Writer, num: u32, wire: Wire_Type) {write_varint(w, ((cast(u64)(num)) << 3) | (cast(u64)(wire)));}

write_uint :: (w: *Writer, num: u32, v: u64) {
	write_tag(w, num, .Varint);
	write_varint(w, v);
}

write_bytes :: (w: *Writer, num: u32, b: []u8) {
	write_tag(w, num, .Len);
	write_varint(w, cast(u64)(len(b)));
	append(*w.buf, ..b);
}

write_string :: (w: *Writer, num: u32, s: string) {write_bytes(w, num, transmute([]u8, s));}

