package etf

// encode returns a complete term (version byte included), laid out exactly
// like the official client's encoder (see package doc).
encode :: proc(v: Value, allocator := context.allocator) -> ([]byte, Error) {
	buf := make([dynamic]byte, 0, 256, allocator)
	if err := encode_into(&buf, v); err != .None {
		delete(buf)
		return nil, err
	}
	return buf[:], .None
}

// encode_into appends the version byte and the term to buf.
encode_into :: proc(buf: ^[dynamic]byte, v: Value) -> Error {
	if _, err := append(buf, VERSION); err != nil do return .Out_Of_Memory
	return encode_term(buf, v, 0)
}

@(private)
put_u16 :: proc(buf: ^[dynamic]byte, x: int) {
	append(buf, u8(x >> 8), u8(x))
}

@(private)
put_u32 :: proc(buf: ^[dynamic]byte, x: u32) {
	append(buf, u8(x >> 24), u8(x >> 16), u8(x >> 8), u8(x))
}

@(private)
put_atom :: proc(buf: ^[dynamic]byte, name: string) {
	if len(name) < 256 {
		append(buf, u8(Tag.Small_Atom), u8(len(name)))
	} else {
		append(buf, u8(Tag.Atom))
		put_u16(buf, len(name))
	}
	append(buf, name)
}

@(private)
put_int :: proc(buf: ^[dynamic]byte, x: i64) {
	switch {
	case x >= 0 && x <= 255:
		append(buf, u8(Tag.Small_Integer), u8(x))
	case x >= i64(min(i32)) && x <= i64(max(i32)):
		append(buf, u8(Tag.Integer))
		put_u32(buf, u32(i32(x)))
	case:
		neg := x < 0
		mag := u64(x) if !neg else 0 - cast(u64)x
		n := 0
		for t := mag; t != 0; t >>= 8 do n += 1
		append(buf, u8(Tag.Small_Big), u8(n), u8(1 if neg else 0))
		for i in 0 ..< n do append(buf, u8(mag >> (8 * uint(i))))
	}
}

@(private)
encode_term :: proc(buf: ^[dynamic]byte, v: Value, depth: int) -> Error {
	if depth > DEFAULT_MAX_DEPTH do return .Too_Deep
	switch x in v {
	case nil:
		put_atom(buf, "nil")
	case bool:
		put_atom(buf, "true" if x else "false")
	case i64:
		put_int(buf, x)
	case f64:
		bits := transmute(u64)x
		append(buf, u8(Tag.New_Float))
		put_u32(buf, u32(bits >> 32))
		put_u32(buf, u32(bits))
	case Big:
		n := len(x.digits)
		if n < 256 {
			append(buf, u8(Tag.Small_Big), u8(n))
		} else {
			append(buf, u8(Tag.Large_Big))
			put_u32(buf, u32(n))
		}
		append(buf, u8(1 if x.negative else 0))
		append(buf, ..x.digits)
	case string:
		if len(x) > int(max(u32)) do return .Too_Large
		append(buf, u8(Tag.Binary))
		put_u32(buf, u32(len(x)))
		append(buf, x)
	case Atom:
		if len(x) > 65535 do return .Too_Large
		put_atom(buf, string(x))
	case Charlist:
		if len(x) <= 65535 {
			append(buf, u8(Tag.String))
			put_u16(buf, len(x))
			append(buf, string(x))
		} else {
			append(buf, u8(Tag.List))
			put_u32(buf, u32(len(x)))
			for i in 0 ..< len(x) do append(buf, u8(Tag.Small_Integer), x[i])
			append(buf, u8(Tag.Nil))
		}
	case List:
		if len(x) == 0 {
			append(buf, u8(Tag.Nil))
			break
		}
		append(buf, u8(Tag.List))
		put_u32(buf, u32(len(x)))
		for e in x do encode_term(buf, e, depth + 1) or_return
		append(buf, u8(Tag.Nil))
	case Tuple:
		if len(x) < 256 {
			append(buf, u8(Tag.Small_Tuple), u8(len(x)))
		} else {
			append(buf, u8(Tag.Large_Tuple))
			put_u32(buf, u32(len(x)))
		}
		for e in x do encode_term(buf, e, depth + 1) or_return
	case Map:
		append(buf, u8(Tag.Map))
		put_u32(buf, u32(len(x)))
		for p in x {
			encode_term(buf, p.key, depth + 1) or_return
			encode_term(buf, p.value, depth + 1) or_return
		}
	}
	return .None
}

// Builder helpers for constructing payloads in insertion order.

Map_Builder :: struct {
	pairs: [dynamic]Pair,
}

map_builder :: proc(cap := 8, allocator := context.allocator) -> Map_Builder {
	return {pairs = make([dynamic]Pair, 0, cap, allocator)}
}

map_put :: proc(b: ^Map_Builder, key: string, value: Value) {
	append(&b.pairs, Pair{key = key, value = value})
}

map_done :: proc(b: ^Map_Builder) -> Map {
	return Map(b.pairs[:])
}
