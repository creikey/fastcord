package quic

// Variable-length integers (RFC 9000 16) and a bounds-checked reader.

MAX_VARINT :: (u64(1) << 62) - 1

varint_len :: proc(v: u64) -> int {
	switch {
	case v < 1 << 6:
		return 1
	case v < 1 << 14:
		return 2
	case v < 1 << 30:
		return 4
	}
	return 8
}

// put_varint appends v with the minimal encoding.
put_varint :: proc(b: ^[dynamic]byte, v: u64) {put_varint_n(b, v, varint_len(v))}

// put_varint_n appends v encoded in exactly n (1, 2, 4 or 8) bytes.
put_varint_n :: proc(b: ^[dynamic]byte, v: u64, n: int) {
	assert(v <= MAX_VARINT && varint_len(v) <= n)
	prefix: u64
	switch n {
	case 1:
		prefix = 0
	case 2:
		prefix = 1
	case 4:
		prefix = 2
	case 8:
		prefix = 3
	case:
		panic("bad varint size")
	}
	x := v | prefix << uint(8 * n - 2)
	for i := n - 1; i >= 0; i -= 1 do append(b, byte(x >> uint(8 * i)))
}

put_u8 :: proc(b: ^[dynamic]byte, v: u8) {append(b, v)}
put_u32 :: proc(b: ^[dynamic]byte, v: u32) {append(b, byte(v >> 24), byte(v >> 16), byte(v >> 8), byte(v))}
put_bytes :: proc(b: ^[dynamic]byte, v: []byte) {append(b, ..v)}

Reader :: struct {
	b:  []byte,
	ok: bool,
}

reader :: proc(b: []byte) -> Reader {return Reader{b, true}}

r_take :: proc(r: ^Reader, n: int) -> []byte {
	if !r.ok || n < 0 || n > len(r.b) {
		r.ok = false
		return nil
	}
	v := r.b[:n]
	r.b = r.b[n:]
	return v
}

r_u8 :: proc(r: ^Reader) -> u8 {
	v := r_take(r, 1)
	return v[0] if v != nil else 0
}

r_u32 :: proc(r: ^Reader) -> u32 {
	v := r_take(r, 4)
	return u32(v[0]) << 24 | u32(v[1]) << 16 | u32(v[2]) << 8 | u32(v[3]) if v != nil else 0
}

r_varint :: proc(r: ^Reader) -> u64 {
	if !r.ok || len(r.b) == 0 {
		r.ok = false
		return 0
	}
	n := 1 << (r.b[0] >> 6)
	v := r_take(r, n)
	if v == nil do return 0
	x := u64(v[0] & 0x3f)
	for i in 1 ..< n do x = x << 8 | u64(v[i])
	return x
}

// r_vec reads a varint length followed by that many bytes.
r_vec :: proc(r: ^Reader) -> []byte {
	n := r_varint(r)
	if n > u64(len(r.b)) {
		r.ok = false
		return nil
	}
	return r_take(r, int(n))
}

r_done :: proc(r: ^Reader) -> bool {return r.ok && len(r.b) == 0}
