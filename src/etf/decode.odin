package etf

import "core:bytes"
import "core:compress/zlib"
import "core:mem"
import "core:strconv"
import "core:strings"

// Discord nests about ten deep. A debug build spends about 2.7 KiB of stack per level (release about
// 0.5 KiB), so this must stay well under 1 MiB / 2.7 KiB, the default thread stack.
DEFAULT_MAX_DEPTH :: 128
DEFAULT_MAX_INFLATED :: 64 << 20

Decode_Options :: struct {
	max_depth:    int, // 0 = DEFAULT_MAX_DEPTH
	max_inflated: int, // cap for compressed terms (tag 80); 0 = DEFAULT_MAX_INFLATED
	// borrow: strings/binaries point into the input buffer instead of being copied.
	// The input must outlive the Value. Inflated (tag 80) data is kept in the allocator.
	borrow:       bool,
}

@(private)
Decoder :: struct {
	data:      []byte,
	pos:       int,
	depth:     int,
	opts:      Decode_Options,
	allocator: mem.Allocator,
}

// decode parses one complete term (with the 131 version byte). Trailing bytes are an error.
decode :: proc(data: []byte, opts := Decode_Options{}, allocator := context.allocator) -> (v: Value, err: Error) {
	d := Decoder{data = data, opts = opts, allocator = allocator}
	if d.opts.max_depth <= 0 do d.opts.max_depth = DEFAULT_MAX_DEPTH
	if d.opts.max_inflated <= 0 do d.opts.max_inflated = DEFAULT_MAX_INFLATED
	if len(data) < 1 do return nil, .Truncated
	if data[0] != VERSION do return nil, .Bad_Version
	d.pos = 1
	if len(data) > 1 && data[1] == u8(Tag.Compressed) {
		inner, ierr := inflate_term(data[2:], d.opts.max_inflated, allocator)
		if ierr != .None do return nil, ierr
		sub := Decoder{data = inner, opts = d.opts, allocator = allocator}
		v, err = decode_term(&sub)
		if err == .None && sub.pos != len(inner) do err = .Trailing_Data
		if !d.opts.borrow do delete(inner, allocator)
		if err != .None {
			if !d.opts.borrow do destroy(v, allocator)
			return nil, err
		}
		return v, .None
	}
	v, err = decode_term(&d)
	if err == .None && d.pos != len(data) do err = .Trailing_Data
	if err != .None {
		if !d.opts.borrow do destroy(v, allocator)
		return nil, err
	}
	return v, .None
}

// inflate_term decodes the body of a tag-80 term: u32 size, zlib data.
@(private)
inflate_term :: proc(body: []byte, limit: int, allocator: mem.Allocator) -> ([]byte, Error) {
	if len(body) < 4 do return nil, .Truncated
	size := int(u32(body[0]) << 24 | u32(body[1]) << 16 | u32(body[2]) << 8 | u32(body[3]))
	if size > limit do return nil, .Too_Large
	context.allocator = allocator
	buf: bytes.Buffer
	zerr := zlib.inflate(body[4:], &buf, false, size)
	if zerr != nil {
		bytes.buffer_destroy(&buf)
		return nil, .Zlib
	}
	out := buf.buf[:]
	if len(out) != size {
		bytes.buffer_destroy(&buf)
		return nil, .Zlib
	}
	return out, .None
}

@(private)
need :: #force_inline proc(d: ^Decoder, n: int) -> bool {
	return n >= 0 && n <= len(d.data) - d.pos
}

@(private)
rd_u8 :: #force_inline proc(d: ^Decoder) -> u8 {
	b := d.data[d.pos]
	d.pos += 1
	return b
}

@(private)
rd_u16 :: #force_inline proc(d: ^Decoder) -> int {
	x := int(d.data[d.pos]) << 8 | int(d.data[d.pos + 1])
	d.pos += 2
	return x
}

@(private)
rd_u32 :: #force_inline proc(d: ^Decoder) -> u32 {
	p := d.data[d.pos:]
	x := u32(p[0]) << 24 | u32(p[1]) << 16 | u32(p[2]) << 8 | u32(p[3])
	d.pos += 4
	return x
}

@(private)
take_str :: proc(d: ^Decoder, n: int) -> (string, Error) {
	if !need(d, n) do return "", .Truncated
	src := d.data[d.pos:][:n]
	d.pos += n
	if n == 0 do return "", .None
	if d.opts.borrow do return string(src), .None
	dst, aerr := make([]byte, n, d.allocator)
	if aerr != nil do return "", .Out_Of_Memory
	copy(dst, src)
	return string(dst), .None
}

// latin1 atoms (ATOM_EXT / SMALL_ATOM_EXT) are converted to UTF-8.
@(private)
take_atom :: proc(d: ^Decoder, n: int, utf8: bool) -> (Value, Error) {
	if !need(d, n) do return nil, .Truncated
	raw := string(d.data[d.pos:][:n])
	switch raw {
	case "nil":
		d.pos += n
		return nil, .None
	case "true":
		d.pos += n
		return true, .None
	case "false":
		d.pos += n
		return false, .None
	}
	high := false
	if !utf8 {
		for i in 0 ..< n do if raw[i] >= 0x80 {high = true; break}
	}
	if !high {
		s, err := take_str(d, n)
		return Atom(s), err
	}
	d.pos += n
	sb := strings.builder_make(0, n * 2, d.allocator)
	for i in 0 ..< n do strings.write_rune(&sb, rune(raw[i]))
	return Atom(strings.to_string(sb)), .None
}

@(private)
decode_term :: proc(d: ^Decoder) -> (v: Value, err: Error) {
	if !need(d, 1) do return nil, .Truncated
	d.depth += 1
	defer d.depth -= 1
	if d.depth > d.opts.max_depth do return nil, .Too_Deep
	tag := rd_u8(d)
	switch Tag(tag) {
	case .Small_Integer:
		if !need(d, 1) do return nil, .Truncated
		return i64(rd_u8(d)), .None
	case .Integer:
		if !need(d, 4) do return nil, .Truncated
		return i64(i32(rd_u32(d))), .None
	case .New_Float:
		if !need(d, 8) do return nil, .Truncated
		hi := u64(rd_u32(d))
		lo := u64(rd_u32(d))
		return transmute(f64)(hi << 32 | lo), .None
	case .Float:
		if !need(d, 31) do return nil, .Truncated
		raw := string(d.data[d.pos:][:31])
		d.pos += 31
		if i := strings.index_byte(raw, 0); i >= 0 do raw = raw[:i]
		f, ok := strconv.parse_f64(strings.trim_space(raw))
		if !ok do return nil, .Bad_Float
		return f, .None
	case .Atom, .Atom_Utf8:
		if !need(d, 2) do return nil, .Truncated
		n := rd_u16(d)
		return take_atom(d, n, Tag(tag) == .Atom_Utf8)
	case .Small_Atom, .Small_Atom_Utf8:
		if !need(d, 1) do return nil, .Truncated
		n := int(rd_u8(d))
		return take_atom(d, n, Tag(tag) == .Small_Atom_Utf8)
	case .Nil:
		return List(nil), .None
	case .String:
		if !need(d, 2) do return nil, .Truncated
		n := rd_u16(d)
		s, serr := take_str(d, n)
		return Charlist(s), serr
	case .Binary:
		if !need(d, 4) do return nil, .Truncated
		n := int(rd_u32(d))
		return take_str(d, n)
	case .Small_Big, .Large_Big:
		n: int
		if Tag(tag) == .Small_Big {
			if !need(d, 2) do return nil, .Truncated
			n = int(rd_u8(d))
		} else {
			if !need(d, 5) do return nil, .Truncated
			n = int(rd_u32(d))
		}
		if !need(d, n + 1) do return nil, .Truncated
		neg := rd_u8(d) != 0
		digits := d.data[d.pos:][:n]
		d.pos += n
		return make_big(d, neg, digits)
	case .List:
		if !need(d, 4) do return nil, .Truncated
		n := int(rd_u32(d))
		if !need(d, n + 1) do return nil, .Truncated // each element and the tail take >=1 byte
		items, aerr := make([]Value, n, d.allocator)
		if aerr != nil do return nil, .Out_Of_Memory
		for i in 0 ..< n {
			items[i], err = decode_term(d)
			if err != .None do return List(items[:i + 1]), err
		}
		if !need(d, 1) do return List(items), .Truncated
		if d.data[d.pos] != u8(Tag.Nil) do return List(items), .Improper_List
		d.pos += 1
		return List(items), .None
	case .Small_Tuple, .Large_Tuple:
		n: int
		if Tag(tag) == .Small_Tuple {
			if !need(d, 1) do return nil, .Truncated
			n = int(rd_u8(d))
		} else {
			if !need(d, 4) do return nil, .Truncated
			n = int(rd_u32(d))
		}
		if !need(d, n) do return nil, .Truncated
		items, aerr := make([]Value, n, d.allocator)
		if aerr != nil do return nil, .Out_Of_Memory
		for i in 0 ..< n {
			items[i], err = decode_term(d)
			if err != .None do return Tuple(items[:i + 1]), err
		}
		return Tuple(items), .None
	case .Map:
		if !need(d, 4) do return nil, .Truncated
		n := int(rd_u32(d))
		if n > (len(d.data) - d.pos) / 2 do return nil, .Truncated
		pairs, aerr := make([]Pair, n, d.allocator)
		if aerr != nil do return nil, .Out_Of_Memory
		for i in 0 ..< n {
			pairs[i].key, err = decode_term(d)
			if err != .None do return Map(pairs[:i + 1]), err
			pairs[i].value, err = decode_term(d)
			if err != .None do return Map(pairs[:i + 1]), err
		}
		return Map(pairs), .None
	case .Compressed:
		// Only valid at top level (handled in decode).
		return nil, .Bad_Tag
	}
	return nil, .Bad_Tag
}

@(private)
make_big :: proc(d: ^Decoder, neg: bool, digits: []u8) -> (Value, Error) {
	n := len(digits)
	for n > 0 && digits[n - 1] == 0 do n -= 1
	if n <= 8 {
		mag: u64
		for i := n - 1; i >= 0; i -= 1 do mag = mag << 8 | u64(digits[i])
		if !neg && mag <= u64(max(i64)) do return i64(mag), .None
		if neg && mag <= u64(max(i64)) + 1 do return cast(i64)(0 - mag), .None
	}
	out, aerr := make([]u8, n, d.allocator)
	if aerr != nil do return nil, .Out_Of_Memory
	copy(out, digits[:n])
	return Big{negative = neg, digits = out}, .None
}
