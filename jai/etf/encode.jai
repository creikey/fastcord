// encode returns a complete term (version byte included), laid out exactly
// like the official client's encoder (see package doc).
encode :: (v: Value, allocator := context.allocator) -> []u8, Error {
	buf := make_dynamic(u8, 0, 256, allocator);
	{ err := encode_into(*buf, v);
	if err != .None {
		delete(buf);
		return .{}, err;
	} }
	return view(buf), .None;
}

// encode_into appends the version byte and the term to buf.
encode_into :: (buf: *[..]u8, v: Value) -> Error {
	{ _, err := append(buf, VERSION);
	if err != null { return .Out_Of_Memory; } }
	return encode_term(buf, v, 0);
}
#scope_module

put_u16 :: (buf: *[..]u8, x: int) {
	append(buf, cast,no_check(u8)(x >> 8), cast,no_check(u8)(x));
}

put_u32 :: (buf: *[..]u8, x: u32) {
	append(buf, cast,no_check(u8)(x >> 24), cast,no_check(u8)(x >> 16), cast,no_check(u8)(x >> 8), cast,no_check(u8)(x));
}

put_atom :: (buf: *[..]u8, name: string) {
	if len(name) < 256 {
		append(buf, cast(u8)(Tag.Small_Atom), cast(u8)(len(name)));
	} else {
		append(buf, cast(u8)(Tag.Atom));
		put_u16(buf, len(name));
	}
	append(buf, name);
}

put_int :: (buf: *[..]u8, x: s64) {
	if x >= 0 && x <= 255 {
		append(buf, cast(u8)(Tag.Small_Integer), cast(u8)(x));
	} else if x >= cast(s64)(S32_MIN) && x <= cast(s64)(S32_MAX) {
		append(buf, cast(u8)(Tag.Integer));
		put_u32(buf, cast,no_check(u32)(cast,no_check(s32)(x)));
	} else {
		neg := x < 0;
		mag := ifx !neg then cast,no_check(u64)(x) else 0 - cast,no_check(u64)x;
		n := 0;
		{ t := mag;
		while t != 0 { n += 1;  t >>= 8; } }
		append(buf, cast(u8)(Tag.Small_Big), cast(u8)(n), cast(u8)(ifx neg then 1 else 0));
		for i: 0..cast(int)(n)-1 { append(buf, cast,no_check(u8)(mag >> (8 * cast,no_check(u64)(i)))); }
	}
}

encode_term :: (buf: *[..]u8, v: Value, depth: int) -> Error {
	if depth > DEFAULT_MAX_DEPTH { return .Too_Deep; }
	for __sw2: 0..0 { if v.kind == {
	case .Nil;
		put_atom(buf, "nil");
	case .Bool; x := v.b;
		put_atom(buf, ifx x then "true" else "false");
	case .Int; x := v.i;
		put_int(buf, x);
	case .Float; x := v.f;
		bits := transmute(u64, x);
		append(buf, cast(u8)(Tag.New_Float));
		put_u32(buf, cast,no_check(u32)(bits >> 32));
		put_u32(buf, cast,no_check(u32)(bits));
	case .Big; x := v.big;
		n := len(x.digits);
		if n < 256 {
			append(buf, cast(u8)(Tag.Small_Big), cast(u8)(n));
		} else {
			append(buf, cast(u8)(Tag.Large_Big));
			put_u32(buf, cast(u32)(n));
		}
		append(buf, cast(u8)(ifx x.negative then 1 else 0));
		append(buf, ..x.digits);
	case .String; x := v.s;
		if len(x) > cast(int)(U32_MAX) { return .Too_Large; }
		append(buf, cast(u8)(Tag.Binary));
		put_u32(buf, cast(u32)(len(x)));
		append(buf, x);
	case .Atom; x := v.s;
		if len(x) > 65535 { return .Too_Large; }
		put_atom(buf, as_string(x));
	case .Charlist; x := v.s;
		if len(x) <= 65535 {
			append(buf, cast(u8)(Tag.String));
			put_u16(buf, len(x));
			append(buf, as_string(x));
		} else {
			append(buf, cast(u8)(Tag.List));
			put_u32(buf, cast(u32)(len(x)));
			for i: 0..len(x)-1 { append(buf, cast(u8)(Tag.Small_Integer), x[i]); }
			append(buf, cast(u8)(Tag.Nil));
		}
	case .List; x := v.list;
		if len(x) == 0 {
			append(buf, cast(u8)(Tag.Nil));
			break __sw2;
		}
		append(buf, cast(u8)(Tag.List));
		put_u32(buf, cast(u32)(len(x)));
		for e: x { __e3 := encode_term(buf, e, depth + 1); if failed(__e3) return __e3; }
		append(buf, cast(u8)(Tag.Nil));
	case .Tuple; x := v.list;
		if len(x) < 256 {
			append(buf, cast(u8)(Tag.Small_Tuple), cast(u8)(len(x)));
		} else {
			append(buf, cast(u8)(Tag.Large_Tuple));
			put_u32(buf, cast(u32)(len(x)));
		}
		for e: x { __e4 := encode_term(buf, e, depth + 1); if failed(__e4) return __e4; }
	case .Map; x := v.map;
		append(buf, cast(u8)(Tag.Map));
		put_u32(buf, cast(u32)(len(x)));
		for p: x {
			__e5 := encode_term(buf, p.key, depth + 1); if failed(__e5) return __e5;
			__e6 := encode_term(buf, p.value, depth + 1); if failed(__e6) return __e6;
		}
	} }
	return .None;
}
#scope_export

// Builder helpers for constructing payloads in insertion order.

Map_Builder :: struct {
	pairs: [..]Pair;
}

map_builder :: (cap := 8, allocator := context.allocator) -> Map_Builder {
	return .{pairs = make_dynamic(Pair, 0, cap, allocator)};
}

map_put :: (b: *Map_Builder, key: string, value: Value) {
	append(*b.pairs, Pair.{key = vstring(key), value = value});
}

map_done :: (b: *Map_Builder) -> Map {
	return cast(Map)(view(b.pairs));
}

