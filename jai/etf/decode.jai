// Discord nests about ten deep. A debug build spends about 2.7 KiB of stack per level (release about
// 0.5 KiB), so this must stay well under 1 MiB / 2.7 KiB, the default thread stack.
DEFAULT_MAX_DEPTH :: 128;
DEFAULT_MAX_INFLATED :: 64 << 20;

Decode_Options :: struct {
	max_depth: int; // 0 = DEFAULT_MAX_DEPTH
	max_inflated: int; // cap for compressed terms (tag 80); 0 = DEFAULT_MAX_INFLATED
	// borrow: strings/binaries point into the input buffer instead of being copied.
	// The input must outlive the Value. Inflated (tag 80) data is kept in the allocator.
	borrow: bool;
}
#scope_module

Decoder :: struct {
	data: []u8;
	pos: int;
	depth: int;
	opts: Decode_Options;
	allocator: Allocator;
}
#scope_export

// decode parses one complete term (with the 131 version byte). Trailing bytes are an error.
decode :: (data: []u8, opts := Decode_Options.{}, allocator := context.allocator) -> Value, Error {
	v: Value;
	err: Error;
	d := Decoder.{data = data, opts = opts, allocator = allocator};
	if d.opts.max_depth <= 0 { d.opts.max_depth = DEFAULT_MAX_DEPTH; }
	if d.opts.max_inflated <= 0 { d.opts.max_inflated = DEFAULT_MAX_INFLATED; }
	if len(data) < 1 { return .{}, .Truncated; }
	if data[0] != VERSION { return .{}, .Bad_Version; }
	d.pos = 1;
	if len(data) > 1 && data[1] == cast(u8)(Tag.Compressed) {
		inner, ierr := inflate_term(sub_from(data, 2), d.opts.max_inflated, allocator);
		if ierr != .None { return .{}, ierr; }
		sub := Decoder.{data = inner, opts = d.opts, allocator = allocator};
		v, err = decode_term(*sub);
		if err == .None && sub.pos != len(inner) { err = .Trailing_Data; }
		if !d.opts.borrow { delete(inner, allocator); }
		if err != .None {
			if !d.opts.borrow { destroy(v, allocator); }
			return .{}, err;
		}
		return v, .None;
	}
	v, err = decode_term(*d);
	if err == .None && d.pos != len(data) { err = .Trailing_Data; }
	if err != .None {
		if !d.opts.borrow { destroy(v, allocator); }
		return .{}, err;
	}
	return v, .None;
}
#scope_module

// inflate_term decodes the body of a tag-80 term: u32 size, zlib data.
inflate_term :: (body: []u8, limit: int, allocator: Allocator) -> []u8, Error {
	if len(body) < 4 { return .{}, .Truncated; }
	size := cast(int)(cast(u32)(body[0]) << 24 | cast(u32)(body[1]) << 16 | cast(u32)(body[2]) << 8 | cast(u32)(body[3]));
	if size > limit { return .{}, .Too_Large; }
	context.allocator = allocator;
	buf: bytes.Buffer;
	zerr := zlib.inflate(sub_from(body, 4), *buf, false, size);
	if zerr != null {
		bytes.buffer_destroy(*buf);
		return .{}, .Zlib;
	}
	out := view(buf.buf);
	if len(out) != size {
		bytes.buffer_destroy(*buf);
		return .{}, .Zlib;
	}
	return out, .None;
}

need :: inline (d: *Decoder, n: int) -> bool {
	return n >= 0 && n <= len(d.data) - d.pos;
};

rd_u8 :: inline (d: *Decoder) -> u8 {
	b := d.data[d.pos];
	d.pos += 1;
	return b;
};

rd_u16 :: inline (d: *Decoder) -> int {
	x := cast(int)(d.data[d.pos]) << 8 | cast(int)(d.data[d.pos + 1]);
	d.pos += 2;
	return x;
};

rd_u32 :: inline (d: *Decoder) -> u32 {
	p := sub_from(d.data, d.pos);
	x := cast(u32)(p[0]) << 24 | cast(u32)(p[1]) << 16 | cast(u32)(p[2]) << 8 | cast(u32)(p[3]);
	d.pos += 4;
	return x;
};

take_str :: (d: *Decoder, n: int) -> string, Error {
	if !need(d, n) { return "", .Truncated; }
	src := sub(sub_from(d.data, d.pos), 0, n);
	d.pos += n;
	if n == 0 { return "", .None; }
	if d.opts.borrow { return as_string(src), .None; }
	dst, aerr := make_slice(u8, n, d.allocator);
	if aerr != null { return "", .Out_Of_Memory; }
	copy(dst, src);
	return as_string(dst), .None;
}

// latin1 atoms (ATOM_EXT / SMALL_ATOM_EXT) are converted to UTF-8.
take_atom :: (d: *Decoder, n: int, utf8: bool) -> Value, Error {
	if !need(d, n) { return .{}, .Truncated; }
	raw := as_string(sub(sub_from(d.data, d.pos), 0, n));
	if raw == {
	case "nil";
		d.pos += n;
		return .{}, .None;
	case "true";
		d.pos += n;
		return vbool(true), .None;
	case "false";
		d.pos += n;
		return vbool(false), .None;
	}
	high := false;
	if !utf8 {
		for i: 0..n-1 { if raw[i] >= 0x80 {high = true; break;} }
	}
	if !high {
		s, err := take_str(d, n);
		return vatom(s), err;
	}
	d.pos += n;
	sb := strings.builder_make(0, n * 2, d.allocator);
	for i: 0..n-1 { strings.write_rune(*sb, cast(u32)(raw[i])); }
	return vatom(strings.to_string(sb)), .None;
}

decode_term :: (d: *Decoder) -> Value, Error {
	v: Value;
	err: Error;
	if !need(d, 1) { return .{}, .Truncated; }
	d.depth += 1;
	defer d.depth -= 1;
	if d.depth > d.opts.max_depth { return .{}, .Too_Deep; }
	tag := rd_u8(d);
	if cast(Tag)(tag) == {
	case .Small_Integer;
		if !need(d, 1) { return .{}, .Truncated; }
		return vint(rd_u8(d)), .None;
	case .Integer;
		if !need(d, 4) { return .{}, .Truncated; }
		return vint(cast(s32)(rd_u32(d))), .None;
	case .New_Float;
		if !need(d, 8) { return .{}, .Truncated; }
		hi := cast(u64)(rd_u32(d));
		lo := cast(u64)(rd_u32(d));
		return transmute(float64, (hi << 32 | lo)), .None;
	case .Float;
		if !need(d, 31) { return .{}, .Truncated; }
		raw := as_string(sub(sub_from(d.data, d.pos), 0, 31));
		d.pos += 31;
		{ i := strings.index_byte(raw, 0);
		if i >= 0 { raw = sub(raw, 0, i); } }
		f, ok := strconv.parse_f64(strings.trim_space(raw));
		if !ok { return .{}, .Bad_Float; }
		return f, .None;
	case .Atom; #through; case .Atom_Utf8;
		if !need(d, 2) { return .{}, .Truncated; }
		n := rd_u16(d);
		{ __r3, __r4 := take_atom(d, n, cast(Tag)(tag) == .Atom_Utf8); return __r3, __r4; }
	case .Small_Atom; #through; case .Small_Atom_Utf8;
		if !need(d, 1) { return .{}, .Truncated; }
		n := cast(int)(rd_u8(d));
		{ __r5, __r6 := take_atom(d, n, cast(Tag)(tag) == .Small_Atom_Utf8); return __r5, __r6; }
	case .Nil;
		return vlist(null), .None;
	case .String;
		if !need(d, 2) { return .{}, .Truncated; }
		n := rd_u16(d);
		s, serr := take_str(d, n);
		return vcharlist(s), serr;
	case .Binary;
		if !need(d, 4) { return .{}, .Truncated; }
		n := cast(int)(rd_u32(d));
		{ __r7, __r8 := take_str(d, n); return __r7, __r8; }
	case .Small_Big; #through; case .Large_Big;
		n: int;
		if cast(Tag)(tag) == .Small_Big {
			if !need(d, 2) { return .{}, .Truncated; }
			n = cast(int)(rd_u8(d));
		} else {
			if !need(d, 5) { return .{}, .Truncated; }
			n = cast(int)(rd_u32(d));
		}
		if !need(d, n + 1) { return .{}, .Truncated; }
		neg := rd_u8(d) != 0;
		digits := sub(sub_from(d.data, d.pos), 0, n);
		d.pos += n;
		{ __r9, __r10 := make_big(d, neg, digits); return __r9, __r10; }
	case .List;
		if !need(d, 4) { return .{}, .Truncated; }
		n := cast(int)(rd_u32(d));
		if !need(d, n + 1) { return .{}, .Truncated; } // each element and the tail take >=1 byte
		items, aerr := make_slice(Value, n, d.allocator);
		if aerr != null { return .{}, .Out_Of_Memory; }
		for i: 0..n-1 {
			items[i], err = decode_term(d);
			if err != .None { return vlist(sub(items, 0, i + 1)), err; }
		}
		if !need(d, 1) { return vlist(items), .Truncated; }
		if d.data[d.pos] != cast(u8)(Tag.Nil) { return vlist(items), .Improper_List; }
		d.pos += 1;
		return vlist(items), .None;
	case .Small_Tuple; #through; case .Large_Tuple;
		n: int;
		if cast(Tag)(tag) == .Small_Tuple {
			if !need(d, 1) { return .{}, .Truncated; }
			n = cast(int)(rd_u8(d));
		} else {
			if !need(d, 4) { return .{}, .Truncated; }
			n = cast(int)(rd_u32(d));
		}
		if !need(d, n) { return .{}, .Truncated; }
		items, aerr := make_slice(Value, n, d.allocator);
		if aerr != null { return .{}, .Out_Of_Memory; }
		for i: 0..n-1 {
			items[i], err = decode_term(d);
			if err != .None { return vtuple(sub(items, 0, i + 1)), err; }
		}
		return vtuple(items), .None;
	case .Map;
		if !need(d, 4) { return .{}, .Truncated; }
		n := cast(int)(rd_u32(d));
		if n > (len(d.data) - d.pos) / 2 { return .{}, .Truncated; }
		pairs, aerr := make_slice(Pair, n, d.allocator);
		if aerr != null { return .{}, .Out_Of_Memory; }
		for i: 0..n-1 {
			pairs[i].key, err = decode_term(d);
			if err != .None { return vmap(sub(pairs, 0, i + 1)), err; }
			pairs[i].value, err = decode_term(d);
			if err != .None { return vmap(sub(pairs, 0, i + 1)), err; }
		}
		return vmap(pairs), .None;
	case .Compressed;
		// Only valid at top level (handled in decode).
		return .{}, .Bad_Tag;
	}
	return .{}, .Bad_Tag;
}

make_big :: (d: *Decoder, neg: bool, digits: []u8) -> Value, Error {
	n := len(digits);
	while n > 0 && digits[n - 1] == 0 { n -= 1; }
	if n <= 8 {
		mag: u64;
		for < i: n - 1..0 { mag = mag << 8 | cast(u64)(digits[i]); }
		if !neg && mag <= cast(u64)(S64_MAX) { return vint(mag), .None; }
		if neg && mag <= cast(u64)(S64_MAX) + 1 { return vint(0 - mag), .None; }
	}
	out, aerr := make_slice(u8, n, d.allocator);
	if aerr != null { return .{}, .Out_Of_Memory; }
	copy(out, sub(digits, 0, n));
	return vbig(Big.{negative = neg, digits = out}), .None;
}
#scope_export

