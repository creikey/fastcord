// Package etf encodes and decodes Erlang External Term Format, the gateway
// encoding the official client uses (`encoding=etf`).
//
// Decoded terms map onto a small JSON-like tree so the rest of the code can
// treat ETF and JSON payloads the same way:
//   atoms nil/true/false -> Nil / Bool, other atoms -> Atom
//   binaries             -> String (Discord sends all strings as binaries)
//   integers and bigs    -> Int (i64; Discord's bigs are snowflakes < 2^64)
//   maps                 -> Map with insertion order kept
package etf

import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"

Nil :: struct {}
Atom :: distinct string

Pair :: struct {
	key:   Value,
	value: Value,
}

Value :: union {
	Nil,
	bool,
	i64,
	u64, // only for bigs that don't fit i64
	f64,
	string,
	Atom,
	[]Value, // lists and tuples
	[]Pair,  // maps
}

Error :: enum {
	None,
	Truncated,
	Bad_Version,
	Bad_Tag,
	Too_Big,
	Too_Deep,
}

VERSION :: 131

// Decodes a full term (with the 131 version byte). Strings are copied into
// `allocator`; free everything with an arena or `destroy`.
decode :: proc(data: []byte, allocator := context.allocator) -> (v: Value, err: Error) {
	context.allocator = allocator
	if len(data) < 1 do return nil, .Truncated
	if data[0] != VERSION do return nil, .Bad_Version
	pos := 1
	v, err = decode_term(data, &pos, 0)
	return
}

@(private)
need :: #force_inline proc(data: []byte, pos: int, n: int) -> Error {
	return pos + n <= len(data) ? .None : .Truncated
}

@(private)
be16 :: #force_inline proc(b: []byte) -> int { return int(b[0]) << 8 | int(b[1]) }
@(private)
be32 :: #force_inline proc(b: []byte) -> u32 { return u32(b[0]) << 24 | u32(b[1]) << 16 | u32(b[2]) << 8 | u32(b[3]) }

@(private)
atom_value :: proc(s: string) -> Value {
	switch s {
	case "nil":   return Nil{}
	case "true":  return true
	case "false": return false
	}
	return Atom(strings.clone(s))
}

@(private)
decode_term :: proc(data: []byte, pos: ^int, depth: int) -> (v: Value, err: Error) {
	if depth > 128 do return nil, .Too_Deep
	if err = need(data, pos^, 1); err != .None do return
	tag := data[pos^]
	pos^ += 1
	p := pos^
	switch tag {
	case 97: // SMALL_INTEGER
		if err = need(data, p, 1); err != .None do return
		pos^ += 1
		return i64(data[p]), .None
	case 98: // INTEGER
		if err = need(data, p, 4); err != .None do return
		pos^ += 4
		return i64(i32(be32(data[p:]))), .None
	case 70: // NEW_FLOAT
		if err = need(data, p, 8); err != .None do return
		bits: u64 = 0
		for i in 0 ..< 8 do bits = bits << 8 | u64(data[p + i])
		pos^ += 8
		return transmute(f64)bits, .None
	case 99: // FLOAT (old, 31-byte string)
		if err = need(data, p, 31); err != .None do return
		s := strings.trim_right(string(data[p:p + 31]), "\x00")
		pos^ += 31
		f, _ := strconv.parse_f64(s)
		return f, .None
	case 100, 118: // ATOM, ATOM_UTF8
		if err = need(data, p, 2); err != .None do return
		n := be16(data[p:])
		if err = need(data, p + 2, n); err != .None do return
		pos^ += 2 + n
		return atom_value(string(data[p + 2:p + 2 + n])), .None
	case 115, 119: // SMALL_ATOM, SMALL_ATOM_UTF8
		if err = need(data, p, 1); err != .None do return
		n := int(data[p])
		if err = need(data, p + 1, n); err != .None do return
		pos^ += 1 + n
		return atom_value(string(data[p + 1:p + 1 + n])), .None
	case 104, 105: // SMALL_TUPLE, LARGE_TUPLE
		n: int
		if tag == 104 {
			if err = need(data, p, 1); err != .None do return
			n = int(data[p])
			pos^ += 1
		} else {
			if err = need(data, p, 4); err != .None do return
			n = int(be32(data[p:]))
			pos^ += 4
		}
		if n > len(data) - pos^ do return nil, .Truncated
		items := make([]Value, n)
		for i in 0 ..< n {
			items[i], err = decode_term(data, pos, depth + 1)
			if err != .None do return
		}
		return items, .None
	case 106: // NIL (empty list)
		return []Value{}, .None
	case 107: // STRING_EXT: list of bytes
		if err = need(data, p, 2); err != .None do return
		n := be16(data[p:])
		if err = need(data, p + 2, n); err != .None do return
		items := make([]Value, n)
		for i in 0 ..< n do items[i] = i64(data[p + 2 + i])
		pos^ += 2 + n
		return items, .None
	case 108: // LIST
		if err = need(data, p, 4); err != .None do return
		n := int(be32(data[p:]))
		pos^ += 4
		if n > len(data) - pos^ do return nil, .Truncated
		items := make([]Value, n)
		for i in 0 ..< n {
			items[i], err = decode_term(data, pos, depth + 1)
			if err != .None do return
		}
		// Proper lists end in NIL; improper tails are dropped.
		_, err = decode_term(data, pos, depth + 1)
		return items, err
	case 109: // BINARY
		if err = need(data, p, 4); err != .None do return
		n := int(be32(data[p:]))
		if err = need(data, p + 4, n); err != .None do return
		pos^ += 4 + n
		return strings.clone(string(data[p + 4:p + 4 + n])), .None
	case 110, 111: // SMALL_BIG, LARGE_BIG
		n: int
		if tag == 110 {
			if err = need(data, p, 2); err != .None do return
			n = int(data[p])
			p += 1
		} else {
			if err = need(data, p, 5); err != .None do return
			n = int(be32(data[p:]))
			p += 4
		}
		if err = need(data, p + 1, n); err != .None do return
		sign := data[p]
		digits := data[p + 1:p + 1 + n]
		pos^ = p + 1 + n
		if n > 8 do return nil, .Too_Big
		u: u64 = 0
		for i := n - 1; i >= 0; i -= 1 do u = u << 8 | u64(digits[i])
		if sign != 0 {
			if u > u64(max(i64)) + 1 do return nil, .Too_Big
			return -i64(u - 1) - 1, .None
		}
		if u > u64(max(i64)) do return u, .None
		return i64(u), .None
	case 116: // MAP
		if err = need(data, p, 4); err != .None do return
		n := int(be32(data[p:]))
		pos^ += 4
		if n > len(data) - pos^ do return nil, .Truncated
		pairs := make([]Pair, n)
		for i in 0 ..< n {
			pairs[i].key, err = decode_term(data, pos, depth + 1)
			if err != .None do return
			pairs[i].value, err = decode_term(data, pos, depth + 1)
			if err != .None do return
		}
		return pairs, .None
	}
	return nil, .Bad_Tag
}

destroy :: proc(v: Value, allocator := context.allocator) {
	context.allocator = allocator
	switch x in v {
	case string: delete(x)
	case Atom: delete(string(x))
	case []Value:
		for e in x do destroy(e)
		delete(x)
	case []Pair:
		for p in x {
			destroy(p.key)
			destroy(p.value)
		}
		delete(x)
	case Nil, bool, i64, u64, f64:
	}
}

// ---------------------------------------------------------------------------
// Lookup helpers

get :: proc(v: Value, key: string) -> (Value, bool) {
	m, ok := v.([]Pair)
	if !ok do return nil, false
	for p in m {
		switch k in p.key {
		case string: if k == key do return p.value, true
		case Atom: if string(k) == key do return p.value, true
		case Nil, bool, i64, u64, f64, []Value, []Pair:
		}
	}
	return nil, false
}

get_str :: proc(v: Value, key: string) -> string {
	x, _ := get(v, key)
	s, _ := x.(string)
	return s
}

get_int :: proc(v: Value, key: string) -> i64 {
	x, _ := get(v, key)
	#partial switch n in x {
	case i64: return n
	case u64: return i64(n)
	case f64: return i64(n)
	}
	return 0
}

// ---------------------------------------------------------------------------
// Encoding

Encoder :: struct {
	buf: [dynamic]byte,
}

// Keys in maps are encoded as atoms when `atom_keys` (matches what the
// official client sends for gateway payloads), otherwise as binaries.
encode :: proc(v: Value, atom_keys := false, allocator := context.allocator) -> []byte {
	e := Encoder{buf = make([dynamic]byte, 0, 256, allocator)}
	append(&e.buf, VERSION)
	encode_term(&e, v, atom_keys)
	return e.buf[:]
}

@(private)
put_be16 :: proc(e: ^Encoder, n: int) { append(&e.buf, u8(n >> 8), u8(n)) }
@(private)
put_be32 :: proc(e: ^Encoder, n: int) { append(&e.buf, u8(n >> 24), u8(n >> 16), u8(n >> 8), u8(n)) }

@(private)
encode_atom :: proc(e: ^Encoder, s: string) {
	if len(s) < 256 {
		append(&e.buf, 119, u8(len(s)))
	} else {
		append(&e.buf, 118)
		put_be16(e, len(s))
	}
	append(&e.buf, ..transmute([]byte)s)
}

@(private)
encode_term :: proc(e: ^Encoder, v: Value, atom_keys: bool) {
	switch x in v {
	case Nil:
		encode_atom(e, "nil")
	case bool:
		encode_atom(e, x ? "true" : "false")
	case i64:
		switch {
		case x >= 0 && x <= 255:
			append(&e.buf, 97, u8(x))
		case x >= i64(min(i32)) && x <= i64(max(i32)):
			append(&e.buf, 98)
			put_be32(e, int(x))
		case:
			u := x < 0 ? u64(-(x + 1)) + 1 : u64(x)
			encode_big(e, u, x < 0)
		}
	case u64:
		encode_big(e, x, false)
	case f64:
		append(&e.buf, 70)
		bits := transmute(u64)x
		for i in 0 ..< 8 do append(&e.buf, u8(bits >> uint(56 - 8 * i)))
	case string:
		append(&e.buf, 109)
		put_be32(e, len(x))
		append(&e.buf, ..transmute([]byte)x)
	case Atom:
		encode_atom(e, string(x))
	case []Value:
		if len(x) == 0 {
			append(&e.buf, 106)
			return
		}
		append(&e.buf, 108)
		put_be32(e, len(x))
		for item in x do encode_term(e, item, atom_keys)
		append(&e.buf, 106)
	case []Pair:
		append(&e.buf, 116)
		put_be32(e, len(x))
		for p in x {
			if s, is_str := p.key.(string); is_str && atom_keys {
				encode_atom(e, s)
			} else {
				encode_term(e, p.key, atom_keys)
			}
			encode_term(e, p.value, atom_keys)
		}
	}
}

@(private)
encode_big :: proc(e: ^Encoder, u: u64, neg: bool) {
	n := 0
	t := u
	for t > 0 {
		n += 1
		t >>= 8
	}
	append(&e.buf, 110, u8(n), neg ? 1 : 0)
	t = u
	for _ in 0 ..< n {
		append(&e.buf, u8(t))
		t >>= 8
	}
}

// ---------------------------------------------------------------------------
// JSON rendering (for captures, logs and diffs)

to_json :: proc(v: Value, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	write_json(&b, v)
	return strings.to_string(b)
}

write_json :: proc(b: ^strings.Builder, v: Value) {
	switch x in v {
	case Nil: strings.write_string(b, "null")
	case bool: strings.write_string(b, x ? "true" : "false")
	case i64: fmt.sbprintf(b, "%d", x)
	case u64: fmt.sbprintf(b, "%d", x)
	case f64:
		if math.is_nan(x) || math.is_inf(x) {
			strings.write_string(b, "null")
		} else if x == math.trunc(x) && abs(x) < 1e15 {
			fmt.sbprintf(b, "%d.0", i64(x))
		} else {
			fmt.sbprintf(b, "%v", x)
		}
	case string: write_json_string(b, x)
	case Atom: fmt.sbprintf(b, `{{"$atom":`); write_json_string(b, string(x)); strings.write_byte(b, '}')
	case []Value:
		strings.write_byte(b, '[')
		for item, i in x {
			if i > 0 do strings.write_byte(b, ',')
			write_json(b, item)
		}
		strings.write_byte(b, ']')
	case []Pair:
		strings.write_byte(b, '{')
		for p, i in x {
			if i > 0 do strings.write_byte(b, ',')
			#partial switch k in p.key {
			case string: write_json_string(b, k)
			case Atom: write_json_string(b, string(k))
			case:
				ks := strings.builder_make(context.temp_allocator)
				write_json(&ks, p.key)
				write_json_string(b, strings.to_string(ks))
			}
			strings.write_byte(b, ':')
			write_json(b, p.value)
		}
		strings.write_byte(b, '}')
	}
}

write_json_string :: proc(b: ^strings.Builder, s: string) {
	strings.write_byte(b, '"')
	for r in s {
		switch r {
		case '"': strings.write_string(b, `\"`)
		case '\\': strings.write_string(b, `\\`)
		case '\n': strings.write_string(b, `\n`)
		case '\r': strings.write_string(b, `\r`)
		case '\t': strings.write_string(b, `\t`)
		case:
			if r < 0x20 {
				fmt.sbprintf(b, `\u%04x`, r)
			} else {
				strings.write_rune(b, r)
			}
		}
	}
	strings.write_byte(b, '"')
}
