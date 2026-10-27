// JSON bridge.
//   Value -> JSON: maps -> objects (non-string keys are stringified), lists and tuples -> arrays,
//   Charlist -> array of ints, nil -> null, Big -> bare integer digits, other atoms -> strings.
//   JSON -> Value: objects keep key order; integer literals -> s64 (or Big), anything with a
//   fraction/exponent -> float64; strings -> binaries.

to_json :: (v: Value, sb: *String_Builder) {
    if v.kind == {
      case .Nil;      append(sb, "null");
      case .Bool;     append(sb, ifx v.b then "true" else "false");
      case .Int;      print_to_builder(sb, "%", v.i);
      case .Float;    write_json_float(sb, v.f);
      case .Big;      write_big_decimal(sb, v.big);
      case .String; #through;
      case .Atom;     write_json_string(sb, v.s);
      case .Charlist;
        append(sb, #char "[");
        for cast([]u8) v.s {
            if it_index append(sb, #char ",");
            print_to_builder(sb, "%", it);
        }
        append(sb, #char "]");
      case .List; #through;
      case .Tuple;
        append(sb, #char "[");
        for v.list {
            if it_index append(sb, #char ",");
            to_json(it, sb);
        }
        append(sb, #char "]");
      case .Map;
        append(sb, #char "{");
        for v.map {
            if it_index append(sb, #char ",");
            if it.key.kind == .String || it.key.kind == .Atom {
                write_json_string(sb, it.key.s);
            } else {
                tmp: String_Builder;
                tmp.allocator = temp;
                to_json(it.key, *tmp);
                write_json_string(sb, builder_to_string(*tmp,, temp));
            }
            append(sb, #char ":");
            to_json(it.value, sb);
        }
        append(sb, #char "}");
    }
}

// write_json_string writes s quoted and escaped; invalid UTF-8 bytes become U+FFFD.
write_json_string :: (sb: *String_Builder, s: string) {
    HEX :: "0123456789abcdef";
    append(sb, #char "\"");
    i := 0;
    while i < s.count {
        c := s[i];
        if c == {
          case #char "\""; append(sb, "\\\"");
          case #char "\\"; append(sb, "\\\\");
          case #char "\n"; append(sb, "\\n");
          case #char "\r"; append(sb, "\\r");
          case #char "\t"; append(sb, "\\t");
          case;
            if c < 0x20 {
                append(sb, "\\u00");
                append(sb, HEX[c >> 4]);
                append(sb, HEX[c & 15]);
            } else if c < 0x80 {
                append(sb, c);
            } else {
                w := utf8_width(s, i);
                if w { append(sb, s.data + i, w); i += w; }
                else { append(sb, "\xEF\xBF\xBD"); i += 1; }
                continue;
            }
        }
        i += 1;
    }
    append(sb, #char "\"");
}

// from_json parses JSON into a Value with ordered maps, in context.allocator.
from_json :: (text: string) -> Value, Error {
    p := Json_Parser.{s = text};
    v, err := json_value(*p);
    if err != .None return .{}, err;
    json_ws(*p);
    if p.pos != p.s.count return .{}, .Bad_Json;
    return v, .None;
}

#scope_file

// Shortest digits that read back exactly (libc's correctly rounded conversions), printed like Odin's
// strconv 'g': exponent form when the exponent is < -4 or >= 6, a ".0" on whole numbers.
write_json_float :: (sb: *String_Builder, f: float64) {
    if f != f || f > FLOAT64_MAX || f < -FLOAT64_MAX { append(sb, "null"); return; }
    buf: [48]u8;
    p: s32 = 1;
    while p < 17 {
        snprintf(buf.data, buf.count, "%.*e", p - 1, f);
        if strtod(buf.data, null) == f break;
        p += 1;
    }
    snprintf(buf.data, buf.count, "%.*e", p - 1, f);
    e := to_string(buf.data);
    exp := string_to_int(slice(e, find_index_from_left(e, #char "e") + 1, e.count));
    if exp >= -4 && exp < 6 snprintf(buf.data, buf.count, "%.*f", max(p - 1 - exp, 0), f);
    s := to_string(buf.data);
    append(sb, s);
    for cast([]u8) s if it == #char "." || it == #char "e" return;
    append(sb, ".0");
}
libc :: #system_library "libc";
snprintf :: (buf: *u8, n: u64, fmt: *u8, args: ..Any) -> s32 #foreign libc;
strtod :: (s: *u8, end: **u8) -> float64 #foreign libc;

write_big_decimal :: (sb: *String_Builder, b: Big) {
    tmp := array_copy(b.digits,, temp);
    n := tmp.count;
    while n > 0 && tmp[n - 1] == 0 n -= 1;
    if !n { append(sb, #char "0"); return; }
    out: [..]u8;
    out.allocator = temp;
    while n > 0 {
        rem := 0;
        for < i: 0..n-1 {
            cur := (rem << 8) | tmp[i];
            tmp[i] = cast(u8) (cur / 10);
            rem = cur % 10;
        }
        array_add(*out, cast(u8) (#char "0" + rem));
        while n > 0 && tmp[n - 1] == 0 n -= 1;
    }
    if b.negative append(sb, #char "-");
    for < out append(sb, it);
}

// utf8_width is the length of the well-formed UTF-8 sequence at s[i], or 0.
utf8_width :: (s: string, i: int) -> int {
    c := s[i];
    n, lo, hi := 0, 0x80, 0xBF;
    if c >= 0xC2 && c <= 0xDF n = 2;
    else if c >= 0xE0 && c <= 0xEF { n = 3; if c == 0xE0 lo = 0xA0; if c == 0xED hi = 0x9F; }
    else if c >= 0xF0 && c <= 0xF4 { n = 4; if c == 0xF0 lo = 0x90; if c == 0xF4 hi = 0x8F; }
    else return 0;
    if i + n > s.count return 0;
    for k: 1..n-1 {
        b := s[i + k];
        if b < lo || b > hi return 0;
        lo, hi = 0x80, 0xBF;
    }
    return n;
}

// put_rune appends r as UTF-8; surrogates and values past U+10FFFF become U+FFFD.
put_rune :: (out: *[..]u8, r: u32) {
    if r < 0x80 { array_add(out, cast(u8) r); return; }
    if r < 0x800 { array_add(out, cast(u8) (0xC0 | (r >> 6)), cast(u8) (0x80 | (r & 0x3F))); return; }
    if (r >= 0xD800 && r <= 0xDFFF) || r > 0x10FFFF r = 0xFFFD;
    if r < 0x10000 {
        array_add(out, cast(u8) (0xE0 | (r >> 12)), cast(u8) (0x80 | ((r >> 6) & 0x3F)), cast(u8) (0x80 | (r & 0x3F)));
        return;
    }
    array_add(out, cast(u8) (0xF0 | (r >> 18)), cast(u8) (0x80 | ((r >> 12) & 0x3F)), cast(u8) (0x80 | ((r >> 6) & 0x3F)), cast(u8) (0x80 | (r & 0x3F)));
}

Json_Parser :: struct {
    s: string;
    pos: int;
    depth: int;
}

json_ws :: (p: *Json_Parser) {
    while p.pos < p.s.count {
        c := p.s[p.pos];
        if c != #char " " && c != #char "\t" && c != #char "\n" && c != #char "\r" return;
        p.pos += 1;
    }
}

at :: inline (p: *Json_Parser, c: u8) -> bool { return p.pos < p.s.count && p.s[p.pos] == c; }

json_value :: (p: *Json_Parser) -> Value, Error {
    json_ws(p);
    if p.pos >= p.s.count return .{}, .Bad_Json;
    p.depth += 1;
    defer p.depth -= 1;
    if p.depth > MAX_DEPTH return .{}, .Too_Deep;
    rest := slice(p.s, p.pos, p.s.count - p.pos);
    c := p.s[p.pos];
    if c == #char "{" {
        p.pos += 1;
        pairs: [..]Pair;
        array_reserve(*pairs, 4);
        json_ws(p);
        if at(p, #char "}") { p.pos += 1; return vmap(pairs), .None; }
        while true {
            json_ws(p);
            if !at(p, #char "\"") return .{}, .Bad_Json;
            k, kerr := json_string(p);
            if kerr != .None return .{}, kerr;
            json_ws(p);
            if !at(p, #char ":") return .{}, .Bad_Json;
            p.pos += 1;
            v, verr := json_value(p);
            if verr != .None return .{}, verr;
            array_add(*pairs, .{vstring(k), v});
            json_ws(p);
            if at(p, #char ",") { p.pos += 1; continue; }
            if at(p, #char "}") { p.pos += 1; return vmap(pairs), .None; }
            return .{}, .Bad_Json;
        }
    } else if c == #char "[" {
        p.pos += 1;
        items: [..]Value;
        array_reserve(*items, 4);
        json_ws(p);
        if at(p, #char "]") { p.pos += 1; return vlist(items), .None; }
        while true {
            v, verr := json_value(p);
            if verr != .None return .{}, verr;
            array_add(*items, v);
            json_ws(p);
            if at(p, #char ",") { p.pos += 1; continue; }
            if at(p, #char "]") { p.pos += 1; return vlist(items), .None; }
            return .{}, .Bad_Json;
        }
    } else if c == #char "\"" {
        s, err := json_string(p);
        return vstring(s), err;
    } else if begins_with(rest, "true") {
        p.pos += 4;
        return vbool(true), .None;
    } else if begins_with(rest, "false") {
        p.pos += 5;
        return vbool(false), .None;
    } else if begins_with(rest, "null") {
        p.pos += 4;
        return .{}, .None;
    } else if c == #char "-" || (c >= #char "0" && c <= #char "9") {
        v, err := json_number(p);
        return v, err;
    }
    return .{}, .Bad_Json;
}

json_number :: (p: *Json_Parser) -> Value, Error {
    start := p.pos;
    is_float := false;
    if at(p, #char "-") p.pos += 1;
    while p.pos < p.s.count {
        c := p.s[p.pos];
        if c >= #char "0" && c <= #char "9" {
        } else if c == #char "." || c == #char "e" || c == #char "E" || c == #char "+" || (c == #char "-" && p.pos > start) {
            is_float = true;
        } else {
            break;
        }
        p.pos += 1;
    }
    lit := slice(p.s, start, p.pos - start);
    if !is_float {
        neg := lit[0] == #char "-";
        digits := ifx neg then slice(lit, 1, lit.count - 1) else lit;
        mag: u64;
        overflow := !digits.count;
        for cast([]u8) digits {
            d := cast(u64) (it - #char "0");
            if mag > (U64_MAX - d) / 10 { overflow = true; break; }
            mag = mag * 10 + d;
        }
        if !overflow {
            if !neg return big_from_u64(mag), .None;
            if mag <= cast(u64) S64_MAX + 1 return vint(cast,no_check(s64) (0 - mag)), .None;
            return vbig(.{negative = true, digits = le_digits(mag)}), .None;
        }
    }
    f, ok, rest := string_to_float64(lit);
    if !ok || rest.count return .{}, .Bad_Json;
    return vfloat(f), .None;
}

json_hex4 :: (p: *Json_Parser) -> u32, bool {
    if p.pos + 4 > p.s.count return 0, false;
    r: u32;
    for 0..3 {
        c := p.s[p.pos + it];
        h: u32;
        if c >= #char "0" && c <= #char "9"      h = c - #char "0";
        else if c >= #char "a" && c <= #char "f" h = c - #char "a" + 10;
        else if c >= #char "A" && c <= #char "F" h = c - #char "A" + 10;
        else return 0, false;
        r = (r << 4) | h;
    }
    p.pos += 4;
    return r, true;
}

json_string :: (p: *Json_Parser) -> string, Error {
    p.pos += 1;  // opening quote
    // Fast path: no escapes, one copy.
    for i: p.pos..p.s.count-1 {
        c := p.s[i];
        if c == #char "\\" break;
        if c == #char "\"" {
            s := copy_string(slice(p.s, p.pos, i - p.pos));
            p.pos = i + 1;
            return s, .None;
        }
    }
    out: [..]u8;
    while p.pos < p.s.count {
        c := p.s[p.pos];
        p.pos += 1;
        if c == #char "\"" return cast(string) out, .None;
        if c != #char "\\" { array_add(*out, c); continue; }
        if p.pos >= p.s.count break;
        e := p.s[p.pos];
        p.pos += 1;
        if e == {
          case #char "\""; #through;
          case #char "\\"; #through;
          case #char "/"; array_add(*out, e);
          case #char "b"; array_add(*out, 8);
          case #char "f"; array_add(*out, 12);
          case #char "n"; array_add(*out, #char "\n");
          case #char "r"; array_add(*out, #char "\r");
          case #char "t"; array_add(*out, #char "\t");
          case #char "u";
            r, ok := json_hex4(p);
            if !ok return "", .Bad_Json;
            if r >= 0xD800 && r < 0xDC00 && p.pos + 6 <= p.s.count && p.s[p.pos] == #char "\\" && p.s[p.pos + 1] == #char "u" {
                save := p.pos;
                p.pos += 2;
                lo, ok2 := json_hex4(p);
                if ok2 && lo >= 0xDC00 && lo < 0xE000 r = 0x10000 + ((r - 0xD800) << 10) + (lo - 0xDC00);
                else p.pos = save;
            }
            put_rune(*out, r);
          case;
            return "", .Bad_Json;
        }
    }
    return "", .Bad_Json;
}
