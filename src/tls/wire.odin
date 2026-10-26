package tls

// Byte-level helpers for building and parsing TLS structures.

put_u8 :: proc(b: ^[dynamic]byte, v: u8) {append(b, v)}
put_u16 :: proc(b: ^[dynamic]byte, v: u16) {append(b, byte(v >> 8), byte(v))}
put_u24 :: proc(b: ^[dynamic]byte, v: int) {append(b, byte(v >> 16), byte(v >> 8), byte(v))}
put_u32 :: proc(b: ^[dynamic]byte, v: u32) {append(b, byte(v >> 24), byte(v >> 16), byte(v >> 8), byte(v))}
put_bytes :: proc(b: ^[dynamic]byte, v: []byte) {append(b, ..v)}

// begin_vec reserves an n-byte length prefix; end_vec patches it.
begin_vec :: proc(b: ^[dynamic]byte, n: int) -> int {
	for _ in 0 ..< n do append(b, 0)
	return len(b)
}

end_vec :: proc(b: ^[dynamic]byte, mark: int, n: int) {
	l := len(b) - mark
	for i in 0 ..< n {
		b[mark - 1 - i] = byte(l >> uint(8 * i))
	}
}

// Reader is a bounds-checked cursor. Any overrun clears ok and yields zeros;
// callers check ok (and usually that the reader is drained) once at the end.
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

r_u16 :: proc(r: ^Reader) -> u16 {
	v := r_take(r, 2)
	return u16(v[0]) << 8 | u16(v[1]) if v != nil else 0
}

r_u24 :: proc(r: ^Reader) -> int {
	v := r_take(r, 3)
	return int(v[0]) << 16 | int(v[1]) << 8 | int(v[2]) if v != nil else 0
}

r_u32 :: proc(r: ^Reader) -> u32 {
	v := r_take(r, 4)
	return u32(v[0]) << 24 | u32(v[1]) << 16 | u32(v[2]) << 8 | u32(v[3]) if v != nil else 0
}

r_vec8 :: proc(r: ^Reader) -> []byte {return r_take(r, int(r_u8(r)))}
r_vec16 :: proc(r: ^Reader) -> []byte {return r_take(r, int(r_u16(r)))}
r_vec24 :: proc(r: ^Reader) -> []byte {return r_take(r, r_u24(r))}

// r_done reports whether parsing succeeded and consumed everything.
r_done :: proc(r: ^Reader) -> bool {return r.ok && len(r.b) == 0}
