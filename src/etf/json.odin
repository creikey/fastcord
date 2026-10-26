package etf

import "core:mem"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"

// JSON bridge, for debugging and fixtures.
//   ETF -> JSON: maps -> objects (non-string keys are stringified), lists and
//   tuples -> arrays, Charlist -> array of ints, nil -> null, Big -> bare
//   integer digits, other atoms -> strings.
//   JSON -> Value: objects keep key order; integer literals -> i64 (or Big),
//   anything with a fraction/exponent -> f64; strings -> binaries.

// to_json renders an already-decoded Value.
to_json :: proc(v: Value, sb: ^strings.Builder) {
	switch x in v {
	case nil:
		strings.write_string(sb, "null")
	case bool:
		strings.write_string(sb, "true" if x else "false")
	case i64:
		strings.write_i64(sb, x)
	case f64:
		write_json_float(sb, x)
	case Big:
		write_big_decimal(sb, x.negative, x.digits)
	case string:
		write_json_string(sb, x)
	case Atom:
		write_json_string(sb, string(x))
	case Charlist:
		strings.write_byte(sb, '[')
		for i in 0 ..< len(x) {
			if i > 0 do strings.write_byte(sb, ',')
			strings.write_int(sb, int(x[i]))
		}
		strings.write_byte(sb, ']')
	case List:
		strings.write_byte(sb, '[')
		for e, i in x {
			if i > 0 do strings.write_byte(sb, ',')
			to_json(e, sb)
		}
		strings.write_byte(sb, ']')
	case Tuple:
		strings.write_byte(sb, '[')
		for e, i in x {
			if i > 0 do strings.write_byte(sb, ',')
			to_json(e, sb)
		}
		strings.write_byte(sb, ']')
	case Map:
		strings.write_byte(sb, '{')
		for p, i in x {
			if i > 0 do strings.write_byte(sb, ',')
			#partial switch k in p.key {
			case string:
				write_json_string(sb, k)
			case Atom:
				write_json_string(sb, string(k))
			case:
				tmp := strings.builder_make(context.temp_allocator)
				to_json(p.key, &tmp)
				write_json_string(sb, strings.to_string(tmp))
			}
			strings.write_byte(sb, ':')
			to_json(p.value, sb)
		}
		strings.write_byte(sb, '}')
	}
}

// etf_to_json converts encoded ETF straight to JSON text without building a tree.
etf_to_json :: proc(data: []byte, sb: ^strings.Builder, opts := Decode_Options{}) -> Error {
	d := Decoder{data = data, opts = opts, allocator = context.temp_allocator}
	d.opts.borrow = true
	if d.opts.max_depth <= 0 do d.opts.max_depth = DEFAULT_MAX_DEPTH
	if d.opts.max_inflated <= 0 do d.opts.max_inflated = DEFAULT_MAX_INFLATED
	if len(data) < 1 do return .Truncated
	if data[0] != VERSION do return .Bad_Version
	d.pos = 1
	if len(data) > 1 && data[1] == u8(Tag.Compressed) {
		inner, ierr := inflate_term(data[2:], d.opts.max_inflated, context.allocator)
		if ierr != .None do return ierr
		defer delete(inner)
		sub := Decoder{data = inner, opts = d.opts, allocator = d.allocator}
		json_term(&sub, sb) or_return
		return .None if sub.pos == len(inner) else .Trailing_Data
	}
	json_term(&d, sb) or_return
	return .None if d.pos == len(data) else .Trailing_Data
}

@(private)
json_term :: proc(d: ^Decoder, sb: ^strings.Builder) -> Error {
	if !need(d, 1) do return .Truncated
	tag := Tag(d.data[d.pos])
	#partial switch tag {
	case .List:
		d.pos += 1
		if !need(d, 4) do return .Truncated
		d.depth += 1
		defer d.depth -= 1
		if d.depth > d.opts.max_depth do return .Too_Deep
		n := int(rd_u32(d))
		if !need(d, n + 1) do return .Truncated
		strings.write_byte(sb, '[')
		for i in 0 ..< n {
			if i > 0 do strings.write_byte(sb, ',')
			json_term(d, sb) or_return
		}
		if !need(d, 1) do return .Truncated
		if d.data[d.pos] != u8(Tag.Nil) do return .Improper_List
		d.pos += 1
		strings.write_byte(sb, ']')
		return .None
	case .Small_Tuple, .Large_Tuple:
		d.pos += 1
		n: int
		if tag == .Small_Tuple {
			if !need(d, 1) do return .Truncated
			n = int(rd_u8(d))
		} else {
			if !need(d, 4) do return .Truncated
			n = int(rd_u32(d))
		}
		if !need(d, n) do return .Truncated
		d.depth += 1
		defer d.depth -= 1
		if d.depth > d.opts.max_depth do return .Too_Deep
		strings.write_byte(sb, '[')
		for i in 0 ..< n {
			if i > 0 do strings.write_byte(sb, ',')
			json_term(d, sb) or_return
		}
		strings.write_byte(sb, ']')
		return .None
	case .Map:
		d.pos += 1
		if !need(d, 4) do return .Truncated
		n := int(rd_u32(d))
		if n > (len(d.data) - d.pos) / 2 do return .Truncated
		d.depth += 1
		defer d.depth -= 1
		if d.depth > d.opts.max_depth do return .Too_Deep
		strings.write_byte(sb, '{')
		for i in 0 ..< n {
			if i > 0 do strings.write_byte(sb, ',')
			if !need(d, 1) do return .Truncated
			kt := Tag(d.data[d.pos])
			if kt == .Binary || kt == .Atom || kt == .Small_Atom || kt == .Atom_Utf8 || kt == .Small_Atom_Utf8 {
				k, err := decode_term(d)
				if err != .None do return err
				#partial switch kk in k {
				case string:
					write_json_string(sb, kk)
				case Atom:
					write_json_string(sb, string(kk))
				case:
					tmp := strings.builder_make(context.temp_allocator)
					to_json(k, &tmp)
					write_json_string(sb, strings.to_string(tmp))
				}
			} else {
				tmp := strings.builder_make(context.temp_allocator)
				json_term(d, &tmp) or_return
				write_json_string(sb, strings.to_string(tmp))
			}
			strings.write_byte(sb, ':')
			json_term(d, sb) or_return
		}
		strings.write_byte(sb, '}')
		return .None
	}
	// Scalars: decode in borrow mode (no copies except Big digits on temp).
	v, err := decode_term(d)
	if err != .None do return err
	to_json(v, sb)
	return .None
}

@(private)
write_json_float :: proc(sb: ^strings.Builder, f: f64) {
	if f != f || f > max(f64) || f < -max(f64) {
		strings.write_string(sb, "null")
		return
	}
	buf: [64]byte
	s := strconv.write_float(buf[:], f, 'g', -1, 64)
	if len(s) > 0 && s[0] == '+' do s = s[1:]
	strings.write_string(sb, s)
	if strings.index_any(s, ".eEn") < 0 do strings.write_string(sb, ".0")
}

@(private)
write_big_decimal :: proc(sb: ^strings.Builder, negative: bool, digits: []u8) {
	tmp := make([]u8, len(digits), context.temp_allocator)
	copy(tmp, digits)
	out := make([dynamic]u8, 0, len(digits) * 3 + 1, context.temp_allocator)
	n := len(tmp)
	for n > 0 && tmp[n - 1] == 0 do n -= 1
	if n == 0 {
		strings.write_byte(sb, '0')
		return
	}
	for n > 0 {
		rem := 0
		for i := n - 1; i >= 0; i -= 1 {
			cur := rem << 8 | int(tmp[i])
			tmp[i] = u8(cur / 10)
			rem = cur % 10
		}
		append(&out, u8('0' + rem))
		for n > 0 && tmp[n - 1] == 0 do n -= 1
	}
	if negative do strings.write_byte(sb, '-')
	for i := len(out) - 1; i >= 0; i -= 1 do strings.write_byte(sb, out[i])
}

@(private)
HEX := "0123456789abcdef"

write_json_string :: proc(sb: ^strings.Builder, s: string) {
	strings.write_byte(sb, '"')
	i := 0
	for i < len(s) {
		c := s[i]
		switch c {
		case '"':
			strings.write_string(sb, `\"`)
		case '\\':
			strings.write_string(sb, `\\`)
		case '\n':
			strings.write_string(sb, `\n`)
		case '\r':
			strings.write_string(sb, `\r`)
		case '\t':
			strings.write_string(sb, `\t`)
		case:
			if c < 0x20 {
				strings.write_string(sb, `\u00`)
				strings.write_byte(sb, HEX[c >> 4])
				strings.write_byte(sb, HEX[c & 15])
			} else if c < 0x80 {
				strings.write_byte(sb, c)
			} else {
				r, w := utf8.decode_rune_in_string(s[i:])
				if r == utf8.RUNE_ERROR && w <= 1 {
					strings.write_string(sb, `�`) // invalid UTF-8 byte in a binary
				} else {
					strings.write_string(sb, s[i:][:w])
				}
				i += w
				continue
			}
		}
		i += 1
	}
	strings.write_byte(sb, '"')
}

// from_json parses JSON into a Value with ordered maps. Strings are allocated.
from_json :: proc(text: string, allocator := context.allocator) -> (Value, Error) {
	p := Json_Parser{s = text, allocator = allocator}
	v, err := json_value(&p)
	if err != .None do return nil, err
	json_ws(&p)
	if p.pos != len(p.s) do return nil, .Bad_Json
	return v, .None
}

@(private)
Json_Parser :: struct {
	s:         string,
	pos:       int,
	depth:     int,
	allocator: mem.Allocator,
}

@(private)
json_ws :: proc(p: ^Json_Parser) {
	for p.pos < len(p.s) {
		switch p.s[p.pos] {
		case ' ', '\t', '\n', '\r':
			p.pos += 1
		case:
			return
		}
	}
}

@(private)
json_value :: proc(p: ^Json_Parser) -> (Value, Error) {
	json_ws(p)
	if p.pos >= len(p.s) do return nil, .Bad_Json
	p.depth += 1
	defer p.depth -= 1
	if p.depth > DEFAULT_MAX_DEPTH do return nil, .Too_Deep
	c := p.s[p.pos]
	switch c {
	case '{':
		p.pos += 1
		pairs := make([dynamic]Pair, 0, 4, p.allocator)
		json_ws(p)
		if p.pos < len(p.s) && p.s[p.pos] == '}' {
			p.pos += 1
			return Map(pairs[:]), .None
		}
		for {
			json_ws(p)
			if p.pos >= len(p.s) || p.s[p.pos] != '"' do return nil, .Bad_Json
			k, kerr := json_string(p)
			if kerr != .None do return nil, kerr
			json_ws(p)
			if p.pos >= len(p.s) || p.s[p.pos] != ':' do return nil, .Bad_Json
			p.pos += 1
			v, verr := json_value(p)
			if verr != .None do return nil, verr
			append(&pairs, Pair{key = k, value = v})
			json_ws(p)
			if p.pos >= len(p.s) do return nil, .Bad_Json
			if p.s[p.pos] == ',' {
				p.pos += 1
				continue
			}
			if p.s[p.pos] == '}' {
				p.pos += 1
				return Map(pairs[:]), .None
			}
			return nil, .Bad_Json
		}
	case '[':
		p.pos += 1
		items := make([dynamic]Value, 0, 4, p.allocator)
		json_ws(p)
		if p.pos < len(p.s) && p.s[p.pos] == ']' {
			p.pos += 1
			return List(items[:]), .None
		}
		for {
			v, verr := json_value(p)
			if verr != .None do return nil, verr
			append(&items, v)
			json_ws(p)
			if p.pos >= len(p.s) do return nil, .Bad_Json
			if p.s[p.pos] == ',' {
				p.pos += 1
				continue
			}
			if p.s[p.pos] == ']' {
				p.pos += 1
				return List(items[:]), .None
			}
			return nil, .Bad_Json
		}
	case '"':
		s, err := json_string(p)
		return s, err
	case 't':
		if strings.has_prefix(p.s[p.pos:], "true") {
			p.pos += 4
			return true, .None
		}
	case 'f':
		if strings.has_prefix(p.s[p.pos:], "false") {
			p.pos += 5
			return false, .None
		}
	case 'n':
		if strings.has_prefix(p.s[p.pos:], "null") {
			p.pos += 4
			return nil, .None
		}
	case '-', '0' ..= '9':
		return json_number(p)
	}
	return nil, .Bad_Json
}

@(private)
json_number :: proc(p: ^Json_Parser) -> (Value, Error) {
	start := p.pos
	is_float := false
	if p.pos < len(p.s) && p.s[p.pos] == '-' do p.pos += 1
	for p.pos < len(p.s) {
		c := p.s[p.pos]
		if c >= '0' && c <= '9' {
			p.pos += 1
		} else if c == '.' || c == 'e' || c == 'E' || c == '+' || (c == '-' && p.pos > start) {
			is_float = true
			p.pos += 1
		} else {
			break
		}
	}
	lit := p.s[start:p.pos]
	if !is_float {
		neg := lit[0] == '-'
		digits := lit[1:] if neg else lit
		mag: u64
		overflow := len(digits) == 0
		for c in transmute([]byte)digits {
			d := u64(c - '0')
			if mag > (max(u64) - d) / 10 {
				overflow = true
				break
			}
			mag = mag * 10 + d
		}
		if !overflow {
			if !neg do return big_from_u64(mag, p.allocator), .None
			if mag <= u64(max(i64)) + 1 do return cast(i64)(0 - mag), .None
			out := make([]u8, 8, p.allocator)
			for i in 0 ..< 8 do out[i] = u8(mag >> (8 * uint(i)))
			return Big{negative = true, digits = out}, .None
		}
	}
	f, ok := strconv.parse_f64(lit)
	if !ok do return nil, .Bad_Json
	return f, .None
}

@(private)
hexval :: proc(c: u8) -> int {
	switch c {
	case '0' ..= '9':
		return int(c - '0')
	case 'a' ..= 'f':
		return int(c - 'a' + 10)
	case 'A' ..= 'F':
		return int(c - 'A' + 10)
	}
	return -1
}

@(private)
json_hex4 :: proc(p: ^Json_Parser) -> (rune, bool) {
	if p.pos + 4 > len(p.s) do return 0, false
	r: rune
	for i in 0 ..< 4 {
		h := hexval(p.s[p.pos + i])
		if h < 0 do return 0, false
		r = r << 4 | rune(h)
	}
	p.pos += 4
	return r, true
}

@(private)
json_string :: proc(p: ^Json_Parser) -> (string, Error) {
	p.pos += 1 // opening quote
	sb := strings.builder_make(p.allocator)
	for p.pos < len(p.s) {
		c := p.s[p.pos]
		if c == '"' {
			p.pos += 1
			return strings.to_string(sb), .None
		}
		if c != '\\' {
			strings.write_byte(&sb, c)
			p.pos += 1
			continue
		}
		p.pos += 1
		if p.pos >= len(p.s) do break
		e := p.s[p.pos]
		p.pos += 1
		switch e {
		case '"', '\\', '/':
			strings.write_byte(&sb, e)
		case 'b':
			strings.write_byte(&sb, 8)
		case 'f':
			strings.write_byte(&sb, 12)
		case 'n':
			strings.write_byte(&sb, '\n')
		case 'r':
			strings.write_byte(&sb, '\r')
		case 't':
			strings.write_byte(&sb, '\t')
		case 'u':
			r, ok := json_hex4(p)
			if !ok do return "", .Bad_Json
			if r >= 0xd800 && r < 0xdc00 && p.pos + 6 <= len(p.s) && p.s[p.pos] == '\\' && p.s[p.pos + 1] == 'u' {
				save := p.pos
				p.pos += 2
				lo, ok2 := json_hex4(p)
				if ok2 && lo >= 0xdc00 && lo < 0xe000 {
					r = 0x10000 + ((r - 0xd800) << 10) + (lo - 0xdc00)
				} else {
					p.pos = save
				}
			}
			strings.write_rune(&sb, r)
		case:
			return "", .Bad_Json
		}
	}
	return "", .Bad_Json
}
