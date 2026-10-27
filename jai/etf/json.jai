// JSON bridge, for debugging and fixtures.
//   ETF -> JSON: maps -> objects (non-string keys are stringified), lists and
//   tuples -> arrays, Charlist -> array of ints, nil -> null, Big -> bare
//   integer digits, other atoms -> strings.
//   JSON -> Value: objects keep key order; integer literals -> i64 (or Big),
//   anything with a fraction/exponent -> f64; strings -> binaries.

// to_json renders an already-decoded Value.
to_json :: (v: Value, sb: *strings.Builder) {
	if v.kind == {
	case .Nil;
		strings.write_string(sb, "null");
	case .Bool; x := v.b;
		strings.write_string(sb, ifx x then "true" else "false");
	case .Int; x := v.i;
		strings.write_i64(sb, x);
	case .Float; x := v.f;
		write_json_float(sb, x);
	case .Big; x := v.big;
		write_big_decimal(sb, x.negative, x.digits);
	case .String; x := v.s;
		write_json_string(sb, x);
	case .Atom; x := v.s;
		write_json_string(sb, as_string(x));
	case .Charlist; x := v.s;
		strings.write_byte(sb, #char "[");
		for i: 0..len(x)-1 {
			if i > 0 { strings.write_byte(sb, #char ","); }
			strings.write_int(sb, cast(int)(x[i]));
		}
		strings.write_byte(sb, #char "]");
	case .List; x := v.list;
		strings.write_byte(sb, #char "[");
		for e, i: x {
			if i > 0 { strings.write_byte(sb, #char ","); }
			to_json(e, sb);
		}
		strings.write_byte(sb, #char "]");
	case .Tuple; x := v.list;
		strings.write_byte(sb, #char "[");
		for e, i: x {
			if i > 0 { strings.write_byte(sb, #char ","); }
			to_json(e, sb);
		}
		strings.write_byte(sb, #char "]");
	case .Map; x := v.map;
		strings.write_byte(sb, #char "{");
		for p, i: x {
			if i > 0 { strings.write_byte(sb, #char ","); }
			if p.key.kind == {
			case .String; k := p.key.s;
				write_json_string(sb, k);
			case .Atom; k := p.key.s;
				write_json_string(sb, as_string(k));
			case; k := p.key;
				tmp := strings.builder_make(temp);
				to_json(p.key, *tmp);
				write_json_string(sb, strings.to_string(tmp));
			}
			strings.write_byte(sb, #char ":");
			to_json(p.value, sb);
		}
		strings.write_byte(sb, #char "}");
	}
}

// etf_to_json converts encoded ETF straight to JSON text without building a tree.
etf_to_json :: (data: []u8, sb: *strings.Builder, opts := Decode_Options.{}) -> Error {
	d := Decoder.{data = data, opts = opts, allocator = temp};
	d.opts.borrow = true;
	if d.opts.max_depth <= 0 { d.opts.max_depth = DEFAULT_MAX_DEPTH; }
	if d.opts.max_inflated <= 0 { d.opts.max_inflated = DEFAULT_MAX_INFLATED; }
	if len(data) < 1 { return .Truncated; }
	if data[0] != VERSION { return .Bad_Version; }
	d.pos = 1;
	if len(data) > 1 && data[1] == cast(u8)(Tag.Compressed) {
		inner, ierr := inflate_term(sub_from(data, 2), d.opts.max_inflated, context.allocator);
		if ierr != .None { return ierr; }
		defer delete(inner);
		sub := Decoder.{data = inner, opts = d.opts, allocator = d.allocator};
		__e3 := json_term(*sub, sb); if failed(__e3) return __e3;
		return ifx sub.pos == len(inner) then .None else .Trailing_Data;
	}
	__e4 := json_term(*d, sb); if failed(__e4) return __e4;
	return ifx d.pos == len(data) then .None else .Trailing_Data;
}
#scope_module

json_term :: (d: *Decoder, sb: *strings.Builder) -> Error {
	if !need(d, 1) { return .Truncated; }
	tag := cast(Tag)(d.data[d.pos]);
	if tag == {
	case .List;
		d.pos += 1;
		if !need(d, 4) { return .Truncated; }
		d.depth += 1;
		defer d.depth -= 1;
		if d.depth > d.opts.max_depth { return .Too_Deep; }
		n := cast(int)(rd_u32(d));
		if !need(d, n + 1) { return .Truncated; }
		strings.write_byte(sb, #char "[");
		for i: 0..n-1 {
			if i > 0 { strings.write_byte(sb, #char ","); }
			__e6 := json_term(d, sb); if failed(__e6) return __e6;
		}
		if !need(d, 1) { return .Truncated; }
		if d.data[d.pos] != cast(u8)(Tag.Nil) { return .Improper_List; }
		d.pos += 1;
		strings.write_byte(sb, #char "]");
		return .None;
	case .Small_Tuple; #through; case .Large_Tuple;
		d.pos += 1;
		n: int;
		if tag == .Small_Tuple {
			if !need(d, 1) { return .Truncated; }
			n = cast(int)(rd_u8(d));
		} else {
			if !need(d, 4) { return .Truncated; }
			n = cast(int)(rd_u32(d));
		}
		if !need(d, n) { return .Truncated; }
		d.depth += 1;
		defer d.depth -= 1;
		if d.depth > d.opts.max_depth { return .Too_Deep; }
		strings.write_byte(sb, #char "[");
		for i: 0..n-1 {
			if i > 0 { strings.write_byte(sb, #char ","); }
			__e7 := json_term(d, sb); if failed(__e7) return __e7;
		}
		strings.write_byte(sb, #char "]");
		return .None;
	case .Map;
		d.pos += 1;
		if !need(d, 4) { return .Truncated; }
		n := cast(int)(rd_u32(d));
		if n > (len(d.data) - d.pos) / 2 { return .Truncated; }
		d.depth += 1;
		defer d.depth -= 1;
		if d.depth > d.opts.max_depth { return .Too_Deep; }
		strings.write_byte(sb, #char "{");
		for i: 0..n-1 {
			if i > 0 { strings.write_byte(sb, #char ","); }
			if !need(d, 1) { return .Truncated; }
			kt := cast(Tag)(d.data[d.pos]);
			if kt == .Binary || kt == .Atom || kt == .Small_Atom || kt == .Atom_Utf8 || kt == .Small_Atom_Utf8 {
				k, err := decode_term(d);
				if err != .None { return err; }
				if k.kind == {
				case .String; kk := k.s;
					write_json_string(sb, kk);
				case .Atom; kk := k.s;
					write_json_string(sb, as_string(kk));
				case; kk := k;
					tmp := strings.builder_make(temp);
					to_json(k, *tmp);
					write_json_string(sb, strings.to_string(tmp));
				}
			} else {
				tmp := strings.builder_make(temp);
				__e9 := json_term(d, *tmp); if failed(__e9) return __e9;
				write_json_string(sb, strings.to_string(tmp));
			}
			strings.write_byte(sb, #char ":");
			__e10 := json_term(d, sb); if failed(__e10) return __e10;
		}
		strings.write_byte(sb, #char "}");
		return .None;
	}
	// Scalars: decode in borrow mode (no copies except Big digits on temp).
	v, err := decode_term(d);
	if err != .None { return err; }
	to_json(v, sb);
	return .None;
}

write_json_float :: (sb: *strings.Builder, f: float64) {
	if f != f || f > FLOAT64_MAX || f < -FLOAT64_MAX {
		strings.write_string(sb, "null");
		return;
	}
	buf: [64]u8;
	s := strconv.write_float(view(buf), f, #char "g", -1, 64);
	if len(s) > 0 && s[0] == #char "+" { s = sub_from(s, 1); }
	strings.write_string(sb, s);
	if strings.index_any(s, ".eEn") < 0 { strings.write_string(sb, ".0"); }
}

write_big_decimal :: (sb: *strings.Builder, negative: bool, digits: []u8) {
	tmp := make_slice(u8, len(digits), temp);
	copy(tmp, digits);
	out := make_dynamic(u8, 0, len(digits) * 3 + 1, temp);
	n := len(tmp);
	while n > 0 && tmp[n - 1] == 0 { n -= 1; }
	if n == 0 {
		strings.write_byte(sb, #char "0");
		return;
	}
	while n > 0 {
		rem := 0;
		{ i := n - 1;
		while i >= 0 {
			cur := rem << 8 | cast(int)(tmp[i]);
			tmp[i] = cast(u8)(cur / 10);
			rem = cur % 10;
			i -= 1;
} }
		append(*out, cast(u8)(#char "0" + rem));
		while n > 0 && tmp[n - 1] == 0 { n -= 1; }
	}
	if negative { strings.write_byte(sb, #char "-"); }
	for < i: len(out) - 1..0 { strings.write_byte(sb, get(out, i)); }
}

HEX := "0123456789abcdef";
#scope_export

write_json_string :: (sb: *strings.Builder, s: string) {
	strings.write_byte(sb, 34);
	i := 0;
	while i < len(s) {
		c := s[i];
		if c == 34 {
			strings.write_string(sb, "\\\"");
		} else if c == 92 {
			strings.write_string(sb, "\\\\");
		} else if c == 10 {
			strings.write_string(sb, "\\n");
		} else if c == 13 {
			strings.write_string(sb, "\\r");
		} else if c == 9 {
			strings.write_string(sb, "\\t");
		} else {
			if c < 0x20 {
				strings.write_string(sb, "\\u00");
				strings.write_byte(sb, HEX[c >> 4]);
				strings.write_byte(sb, HEX[c & 15]);
			} else if c < 0x80 {
				strings.write_byte(sb, c);
			} else {
				r, w := utf8.decode_rune_in_string(sub_from(s, i));
				if r == utf8.RUNE_ERROR && w <= 1 {
					strings.write_string(sb, "�"); // invalid UTF-8 byte in a binary
				} else {
					strings.write_string(sb, sub(sub_from(s, i), 0, w));
				}
				i += w;
				continue;
			}
		}
		i += 1;
	}
	strings.write_byte(sb, 34);
}

// from_json parses JSON into a Value with ordered maps. Strings are allocated.
from_json :: (text: string, allocator := context.allocator) -> Value, Error {
	p := Json_Parser.{s = text, allocator = allocator};
	v, err := json_value(*p);
	if err != .None { return .{}, err; }
	json_ws(*p);
	if p.pos != len(p.s) { return .{}, .Bad_Json; }
	return v, .None;
}
#scope_module

Json_Parser :: struct {
	s: string;
	pos: int;
	depth: int;
	allocator: Allocator;
}

json_ws :: (p: *Json_Parser) {
	while p.pos < len(p.s) {
		{ __sw13 := p.s[p.pos];
		if __sw13 == #char " " || __sw13 == 9 || __sw13 == 10 || __sw13 == 13 {
			p.pos += 1;
		} else {
			return;
		} }
	}
}

json_value :: (p: *Json_Parser) -> Value, Error {
	json_ws(p);
	if p.pos >= len(p.s) { return .{}, .Bad_Json; }
	p.depth += 1;
	defer p.depth -= 1;
	if p.depth > DEFAULT_MAX_DEPTH { return .{}, .Too_Deep; }
	c := p.s[p.pos];
	if c == #char "{" {
		p.pos += 1;
		pairs := make_dynamic(Pair, 0, 4, p.allocator);
		json_ws(p);
		if p.pos < len(p.s) && p.s[p.pos] == #char "}" {
			p.pos += 1;
			return vmap(view(pairs)), .None;
		}
		while true {
			json_ws(p);
			if p.pos >= len(p.s) || p.s[p.pos] != 34 { return .{}, .Bad_Json; }
			k, kerr := json_string(p);
			if kerr != .None { return .{}, kerr; }
			json_ws(p);
			if p.pos >= len(p.s) || p.s[p.pos] != #char ":" { return .{}, .Bad_Json; }
			p.pos += 1;
			v, verr := json_value(p);
			if verr != .None { return .{}, verr; }
			append(*pairs, Pair.{key = vstring(k), value = v});
			json_ws(p);
			if p.pos >= len(p.s) { return .{}, .Bad_Json; }
			if p.s[p.pos] == #char "," {
				p.pos += 1;
				continue;
			}
			if p.s[p.pos] == #char "}" {
				p.pos += 1;
				return vmap(view(pairs)), .None;
			}
			return .{}, .Bad_Json;
		}
	} else if c == #char "[" {
		p.pos += 1;
		items := make_dynamic(Value, 0, 4, p.allocator);
		json_ws(p);
		if p.pos < len(p.s) && p.s[p.pos] == #char "]" {
			p.pos += 1;
			return vlist(view(items)), .None;
		}
		while true {
			v, verr := json_value(p);
			if verr != .None { return .{}, verr; }
			append(*items, v);
			json_ws(p);
			if p.pos >= len(p.s) { return .{}, .Bad_Json; }
			if p.s[p.pos] == #char "," {
				p.pos += 1;
				continue;
			}
			if p.s[p.pos] == #char "]" {
				p.pos += 1;
				return vlist(view(items)), .None;
			}
			return .{}, .Bad_Json;
		}
	} else if c == 34 {
		s, err := json_string(p);
		return vstring(s), err;
	} else if c == #char "t" {
		if strings.has_prefix(sub_from(p.s, p.pos), "true") {
			p.pos += 4;
			return vbool(true), .None;
		}
	} else if c == #char "f" {
		if strings.has_prefix(sub_from(p.s, p.pos), "false") {
			p.pos += 5;
			return vbool(false), .None;
		}
	} else if c == #char "n" {
		if strings.has_prefix(sub_from(p.s, p.pos), "null") {
			p.pos += 4;
			return .{}, .None;
		}
	} else if c == #char "-" || (c >= #char "0" && c <= #char "9") {
		{ __r15, __r16 := json_number(p); return __r15, __r16; }
	}
	return .{}, .Bad_Json;
}

json_number :: (p: *Json_Parser) -> Value, Error {
	start := p.pos;
	is_float := false;
	if p.pos < len(p.s) && p.s[p.pos] == #char "-" { p.pos += 1; }
	while p.pos < len(p.s) {
		c := p.s[p.pos];
		if c >= #char "0" && c <= #char "9" {
			p.pos += 1;
		} else if c == #char "." || c == #char "e" || c == #char "E" || c == #char "+" || (c == #char "-" && p.pos > start) {
			is_float = true;
			p.pos += 1;
		} else {
			break;
		}
	}
	lit := sub(p.s, start, p.pos);
	if !is_float {
		neg := lit[0] == #char "-";
		digits := ifx neg then sub_from(lit, 1) else lit;
		mag: u64;
		overflow := len(digits) == 0;
		for c: transmute([]u8, digits) {
			d := cast(u64)(c - #char "0");
			if mag > (U64_MAX - d) / 10 {
				overflow = true;
				break;
			}
			mag = mag * 10 + d;
		}
		if !overflow {
			if !neg { return big_from_u64(mag, p.allocator), .None; }
			if mag <= cast(u64)(S64_MAX) + 1 { return vint(cast,no_check(s64) (0 - mag)), .None; }
			out := make_slice(u8, 8, p.allocator);
			for i: 0..7 { at(*out, i).* = cast,no_check(u8)(mag >> (8 * cast,no_check(u64)(i))); }
			return vbig(Big.{negative = true, digits = out}), .None;
		}
	}
	f, ok := strconv.parse_f64(lit);
	if !ok { return .{}, .Bad_Json; }
	return vfloat(f), .None;
}

hexval :: (c: u8) -> int {
	if (c >= #char "0" && c <= #char "9") {
		return cast(int)(c - #char "0");
	} else if (c >= #char "a" && c <= #char "f") {
		return cast(int)(c - #char "a" + 10);
	} else if (c >= #char "A" && c <= #char "F") {
		return cast(int)(c - #char "A" + 10);
	}
	return -1;
}

json_hex4 :: (p: *Json_Parser) -> u32, bool {
	if p.pos + 4 > len(p.s) { return 0, false; }
	r: u32;
	for i: 0..3 {
		h := hexval(p.s[p.pos + i]);
		if h < 0 { return 0, false; }
		r = r << 4 | cast(u32)(h);
	}
	p.pos += 4;
	return r, true;
}

json_string :: (p: *Json_Parser) -> string, Error {
	p.pos += 1; // opening quote
	sb := strings.builder_make(p.allocator);
	while p.pos < len(p.s) {
		c := p.s[p.pos];
		if c == 34 {
			p.pos += 1;
			return strings.to_string(sb), .None;
		}
		if c != 92 {
			strings.write_byte(*sb, c);
			p.pos += 1;
			continue;
		}
		p.pos += 1;
		if p.pos >= len(p.s) { break; }
		e := p.s[p.pos];
		p.pos += 1;
		if e == 34 || e == 92 || e == #char "/" {
			strings.write_byte(*sb, e);
		} else if e == #char "b" {
			strings.write_byte(*sb, 8);
		} else if e == #char "f" {
			strings.write_byte(*sb, 12);
		} else if e == #char "n" {
			strings.write_byte(*sb, 10);
		} else if e == #char "r" {
			strings.write_byte(*sb, 13);
		} else if e == #char "t" {
			strings.write_byte(*sb, 9);
		} else if e == #char "u" {
			r, ok := json_hex4(p);
			if !ok { return "", .Bad_Json; }
			if r >= 0xd800 && r < 0xdc00 && p.pos + 6 <= len(p.s) && p.s[p.pos] == 92 && p.s[p.pos + 1] == #char "u" {
				save := p.pos;
				p.pos += 2;
				lo, ok2 := json_hex4(p);
				if ok2 && lo >= 0xdc00 && lo < 0xe000 {
					r = 0x10000 + ((r - 0xd800) << 10) + (lo - 0xdc00);
				} else {
					p.pos = save;
				}
			}
			strings.write_rune(*sb, r);
		} else {
			return "", .Bad_Json;
		}
	}
	return "", .Bad_Json;
}
#scope_export

