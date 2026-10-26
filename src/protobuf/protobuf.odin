// Package protobuf is a schema-less protobuf wire-format reader/writer.
// Discord ships user settings (theme, guild folders, custom status) as
// base64 protobuf in READY.user_settings_proto and USER_SETTINGS_PROTO_UPDATE.
package protobuf

Wire_Type :: enum u8 {
	Varint = 0,
	I64    = 1,
	Len    = 2,
	I32    = 5,
}

Field :: struct {
	num:   u32,
	wire:  Wire_Type,
	value: u64, // varint / fixed value
	bytes: []byte, // Len payload (submessage, string, packed)
}

Reader :: struct {
	buf: []byte,
	pos: int,
}

read_varint :: proc(r: ^Reader) -> (v: u64, ok: bool) {
	shift: uint
	for r.pos < len(r.buf) && shift < 64 {
		b := r.buf[r.pos]
		r.pos += 1
		v |= u64(b & 0x7f) << shift
		if b & 0x80 == 0 do return v, true
		shift += 7
	}
	return 0, false
}

// Next field, or ok=false at end / on malformed input.
next :: proc(r: ^Reader) -> (f: Field, ok: bool) {
	if r.pos >= len(r.buf) do return {}, false
	tag := read_varint(r) or_return
	f.num = u32(tag >> 3)
	f.wire = Wire_Type(tag & 7)
	switch f.wire {
	case .Varint:
		f.value = read_varint(r) or_return
	case .I64:
		if r.pos + 8 > len(r.buf) do return {}, false
		for i in 0 ..< 8 do f.value |= u64(r.buf[r.pos + i]) << (8 * uint(i))
		r.pos += 8
	case .I32:
		if r.pos + 4 > len(r.buf) do return {}, false
		for i in 0 ..< 4 do f.value |= u64(r.buf[r.pos + i]) << (8 * uint(i))
		r.pos += 4
	case .Len:
		n := read_varint(r) or_return
		if n > u64(len(r.buf) - r.pos) do return {}, false
		f.bytes = r.buf[r.pos:][:n]
		r.pos += int(n)
	case:
		return {}, false
	}
	return f, true
}

// Finds the first field with this number at the top level of buf.
find :: proc(buf: []byte, num: u32) -> (Field, bool) {
	r := Reader{buf = buf}
	for f in next(&r) {
		if f.num == num do return f, true
	}
	return {}, false
}

// Path lookup through nested submessages: find_path(buf, 2, 1) = field 1 of message field 2.
find_path :: proc(buf: []byte, path: ..u32) -> (Field, bool) {
	cur := buf
	f: Field
	for num, i in path {
		ok: bool
		f, ok = find(cur, num)
		if !ok do return {}, false
		if i < len(path) - 1 {
			if f.wire != .Len do return {}, false
			cur = f.bytes
		}
	}
	return f, true
}

// Packed repeated varints / fixed64 (e.g. guild folder guild_ids are packed fixed64).
packed_fixed64 :: proc(b: []byte, allocator := context.allocator) -> []u64 {
	out := make([]u64, len(b) / 8, allocator)
	for i in 0 ..< len(out) {
		v: u64
		for j in 0 ..< 8 do v |= u64(b[i * 8 + j]) << (8 * uint(j))
		out[i] = v
	}
	return out
}

Writer :: struct {
	buf: [dynamic]byte,
}

write_varint :: proc(w: ^Writer, v: u64) {
	x := v
	for x >= 0x80 {
		append(&w.buf, byte(x) | 0x80)
		x >>= 7
	}
	append(&w.buf, byte(x))
}

write_tag :: proc(w: ^Writer, num: u32, wire: Wire_Type) {write_varint(w, u64(num) << 3 | u64(wire))}

write_uint :: proc(w: ^Writer, num: u32, v: u64) {
	write_tag(w, num, .Varint)
	write_varint(w, v)
}

write_bytes :: proc(w: ^Writer, num: u32, b: []byte) {
	write_tag(w, num, .Len)
	write_varint(w, u64(len(b)))
	append(&w.buf, ..b)
}

write_string :: proc(w: ^Writer, num: u32, s: string) {write_bytes(w, num, transmute([]byte)s)}
