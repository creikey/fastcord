// decode parses one complete term (with the 131 version byte) into context.allocator. Trailing bytes are an
// error. On error, whatever was allocated is left to the allocator's owner.
decode :: (data: []u8) -> Value, Error {
    if !data.count return .{}, .Truncated;
    if data[0] != VERSION return .{}, .Bad_Version;
    if data.count > 1 && data[1] == xx Tag.Compressed {
        // u32 size, then zlib data
        if data.count < 6 return .{}, .Truncated;
        size := cast(int) be32(data.data + 2);
        if size > MAX_INFLATED return .{}, .Too_Large;
        inner, ok := inflate.inflate(array_view(data, 6), .ZLIB, size);
        defer array_free(inner);
        if !ok || inner.count != size return .{}, .Zlib;
        v, err := decode_all(inner, 0);
        return v, err;
    }
    v, err := decode_all(data, 1);
    return v, err;
}

#scope_file

Decoder :: struct {
    data: []u8;
    pos: int;
    depth: int;
    // Values that lists, tuples and maps may still allocate. Each item of a valid term takes at least a byte
    // of its own, so a valid term never runs out, but nested headers that each claim a huge count would
    // otherwise allocate every count before reading one item.
    budget: int;
}

decode_all :: (data: []u8, pos: int) -> Value, Error {
    d := Decoder.{data = data, pos = pos, budget = data.count};
    v, err := decode_term(*d);
    if err == .None && d.pos != data.count err = .Trailing_Data;
    if err != .None return .{}, err;
    return v, .None;
}

be32 :: (p: *u8) -> u32 { return ((cast(u32) p[0]) << 24) | ((cast(u32) p[1]) << 16) | ((cast(u32) p[2]) << 8) | p[3]; }

need :: inline (d: *Decoder, n: int) -> bool { return n >= 0 && n <= d.data.count - d.pos; }
rd_u8 :: inline (d: *Decoder) -> u8 { d.pos += 1; return d.data[d.pos - 1]; }
rd_u16 :: inline (d: *Decoder) -> int { d.pos += 2; return ((cast(int) d.data[d.pos - 2]) << 8) | d.data[d.pos - 1]; }
rd_u32 :: inline (d: *Decoder) -> int { d.pos += 4; return be32(d.data.data + d.pos - 4); }
peek_bytes :: inline (d: *Decoder, n: int) -> string { s: string = ---; s.data = d.data.data + d.pos; s.count = n; return s; }

take_str :: (d: *Decoder, n: int) -> string, Error {
    if !need(d, n) return "", .Truncated;
    s := copy_string(peek_bytes(d, n));
    d.pos += n;
    return s, .None;
}

// Latin-1 atoms (ATOM_EXT / SMALL_ATOM_EXT) are converted to UTF-8.
take_atom :: (d: *Decoder, n: int, utf8: bool) -> Value, Error {
    if !need(d, n) return .{}, .Truncated;
    raw := peek_bytes(d, n);
    if raw == {
      case "nil";   d.pos += n; return .{}, .None;
      case "true";  d.pos += n; return vbool(true), .None;
      case "false"; d.pos += n; return vbool(false), .None;
    }
    high := false;
    if !utf8 for cast([]u8) raw if it >= 0x80 { high = true; break; }
    if !high {
        s, err := take_str(d, n);
        return vatom(s), err;
    }
    d.pos += n;
    out: [..]u8;
    array_reserve(*out, n * 2);
    for cast([]u8) raw {
        if it < 0x80 array_add(*out, it);
        else array_add(*out, 0xC0 | (it >> 6), 0x80 | (it & 0x3F));
    }
    return vatom(cast(string) out), .None;
}

decode_term :: (d: *Decoder) -> Value, Error {
    if !need(d, 1) return .{}, .Truncated;
    d.depth += 1;
    defer d.depth -= 1;
    if d.depth > MAX_DEPTH return .{}, .Too_Deep;
    tag := cast(Tag) rd_u8(d);
    if tag == {
      case .Small_Integer;
        if !need(d, 1) return .{}, .Truncated;
        return vint(rd_u8(d)), .None;
      case .Integer;
        if !need(d, 4) return .{}, .Truncated;
        return vint(cast,no_check(s32) rd_u32(d)), .None;
      case .New_Float;
        if !need(d, 8) return .{}, .Truncated;
        bits := ((cast(u64) rd_u32(d)) << 32) | (cast(u64) rd_u32(d));
        return vfloat((cast(*float64) *bits).*), .None;
      case .Float;
        // 31 bytes of "%.20e" text, NUL padded
        if !need(d, 31) return .{}, .Truncated;
        raw := peek_bytes(d, 31);
        d.pos += 31;
        nul := find_index_from_left(raw, cast(u8) 0);
        if nul >= 0 raw.count = nul;
        raw = trim(raw);
        f, ok, rest := string_to_float64(raw);
        if !raw.count || !ok || rest.count return .{}, .Bad_Float;
        return vfloat(f), .None;
      case .Atom; #through;
      case .Atom_Utf8;
        if !need(d, 2) return .{}, .Truncated;
        v, err := take_atom(d, rd_u16(d), tag == .Atom_Utf8);
        return v, err;
      case .Small_Atom; #through;
      case .Small_Atom_Utf8;
        if !need(d, 1) return .{}, .Truncated;
        v, err := take_atom(d, rd_u8(d), tag == .Small_Atom_Utf8);
        return v, err;
      case .Nil;
        return vlist(.[]), .None;
      case .String;
        if !need(d, 2) return .{}, .Truncated;
        s, err := take_str(d, rd_u16(d));
        return vcharlist(s), err;
      case .Binary;
        if !need(d, 4) return .{}, .Truncated;
        s, err := take_str(d, rd_u32(d));
        return vstring(s), err;
      case .Small_Big; #through;
      case .Large_Big;
        if !need(d, ifx tag == .Small_Big then 2 else 5) return .{}, .Truncated;
        n := ifx tag == .Small_Big then cast(int) rd_u8(d) else rd_u32(d);
        if !need(d, n + 1) return .{}, .Truncated;
        neg := rd_u8(d) != 0;
        digits := array_view(d.data, d.pos, n);
        d.pos += n;
        return make_big(neg, digits), .None;
      case .List;
        if !need(d, 4) return .{}, .Truncated;
        n := rd_u32(d);
        if !need(d, n + 1) return .{}, .Truncated;  // each element and the tail take >= 1 byte
        items, err := decode_items(d, n);
        if err return .{}, err;
        if !need(d, 1) return .{}, .Truncated;
        if d.data[d.pos] != xx Tag.Nil return .{}, .Improper_List;
        d.pos += 1;
        return vlist(items), .None;
      case .Small_Tuple; #through;
      case .Large_Tuple;
        if !need(d, ifx tag == .Small_Tuple then 1 else 4) return .{}, .Truncated;
        n := ifx tag == .Small_Tuple then cast(int) rd_u8(d) else rd_u32(d);
        if !need(d, n) return .{}, .Truncated;
        items, err := decode_items(d, n);
        return vtuple(items), err;
      case .Map;
        if !need(d, 4) return .{}, .Truncated;
        n := rd_u32(d);
        if n > (d.data.count - d.pos) / 2 return .{}, .Truncated;
        d.budget -= 2 * n;
        if d.budget < 0 return .{}, .Too_Large;
        pairs := NewArray(n, Pair);
        for * pairs {
            err: Error;
            it.key, err = decode_term(d);
            if err return .{}, err;
            it.value, err = decode_term(d);
            if err return .{}, err;
        }
        return vmap(pairs), .None;
    }
    return .{}, .Bad_Tag;  // Compressed is only valid at the top level
}

decode_items :: (d: *Decoder, n: int) -> []Value, Error {
    d.budget -= n;
    if d.budget < 0 return .[], .Too_Large;
    items := NewArray(n, Value);
    for * items {
        err: Error;
        it.*, err = decode_term(d);
        if err return .[], err;
    }
    return items, .None;
}

make_big :: (neg: bool, digits: []u8) -> Value {
    n := digits.count;
    while n > 0 && digits[n - 1] == 0 n -= 1;
    if n <= 8 {
        mag: u64;
        for < i: 0..n-1 mag = (mag << 8) | digits[i];
        if !neg && mag <= cast(u64) S64_MAX return vint(cast(s64) mag);
        if neg && mag <= cast(u64) S64_MAX + 1 return vint(cast,no_check(s64) (0 - mag));
    }
    out := NewArray(n, u8, false);
    memcpy(out.data, digits.data, n);
    return vbig(.{negative = neg, digits = out});
}
