// Package mls is the subset of Messaging Layer Security (RFC 9420) that DAVE
// (Discord's audio/video E2EE) needs, written from scratch on core:crypto:
// ciphersuite 2 only (DHKEMP256_AES128GCM_SHA256_P256), HPKE base mode,
// TreeKEM ratchet tree, key packages, external senders, Add/Remove/Update/
// PSK/GroupContextExtensions proposals, commits (with and without path),
// welcomes, key schedule, transcript hashes and the exporter.
//
// Only PublicMessage framing is implemented (DAVE requires handshake
// messages in plaintext); PrivateMessage / the secret tree are not needed.
package mls

import "core:mem"

Error :: enum u8 {
	None,
	Decode,      // malformed TLS-presentation encoding
	Unsupported, // valid MLS we do not implement (other suites, PrivateMessage, ReInit...)
	Crypto,      // AEAD / HPKE / key failure
	Verify,      // bad signature, MAC, tree hash, parent hash...
	State,       // message does not fit the current group state
}

// ---------------------------------------------------------------------------
// Writer: TLS presentation language with MLS variable-size vector headers.

Writer :: struct {
	buf: [dynamic]byte,
}

writer_make :: proc(allocator := context.temp_allocator) -> Writer {
	return Writer{buf = make([dynamic]byte, 0, 256, allocator)}
}

w_u8 :: proc(w: ^Writer, v: u8) {append(&w.buf, v)}
w_u16 :: proc(w: ^Writer, v: u16) {append(&w.buf, u8(v >> 8), u8(v))}
w_u32 :: proc(w: ^Writer, v: u32) {append(&w.buf, u8(v >> 24), u8(v >> 16), u8(v >> 8), u8(v))}
w_u64 :: proc(w: ^Writer, v: u64) {
	w_u32(w, u32(v >> 32))
	w_u32(w, u32(v))
}
w_raw :: proc(w: ^Writer, b: []byte) {append(&w.buf, ..b)}

w_varint :: proc(w: ^Writer, n: int) {
	switch {
	case n < 1 << 6:
		w_u8(w, u8(n))
	case n < 1 << 14:
		w_u16(w, u16(n) | 0x4000)
	case:
		assert(n < 1 << 30)
		w_u32(w, u32(n) | 0x8000_0000)
	}
}

// w_vec writes opaque data<V>.
w_vec :: proc(w: ^Writer, b: []byte) {
	w_varint(w, len(b))
	w_raw(w, b)
}

// w_begin / w_end wrap a nested vector without a temp buffer: w_begin
// reserves a 4-byte header, w_end shrinks it to the minimal varint.
w_begin :: proc(w: ^Writer) -> int {
	pos := len(w.buf)
	append(&w.buf, 0, 0, 0, 0)
	return pos
}

w_end :: proc(w: ^Writer, pos: int) {
	n := len(w.buf) - pos - 4
	hdr: [4]byte
	hl := 0
	switch {
	case n < 1 << 6:
		hdr[0] = u8(n)
		hl = 1
	case n < 1 << 14:
		hdr[0] = u8(n >> 8) | 0x40
		hdr[1] = u8(n)
		hl = 2
	case:
		hdr = {u8(n >> 24) | 0x80, u8(n >> 16), u8(n >> 8), u8(n)}
		hl = 4
	}
	if hl < 4 {
		copy(w.buf[pos + hl:], w.buf[pos + 4:])
		resize(&w.buf, len(w.buf) - (4 - hl))
	}
	copy(w.buf[pos:], hdr[:hl])
}

w_optional :: proc(w: ^Writer, present: bool) {w_u8(w, 1 if present else 0)}

// ---------------------------------------------------------------------------
// Reader. Slices returned point into the input buffer.

Reader :: struct {
	data: []byte,
	pos:  int,
	err:  bool,
}

reader_make :: proc(b: []byte) -> Reader {return Reader{data = b}}

r_ok :: proc(r: ^Reader) -> bool {return !r.err}
r_done :: proc(r: ^Reader) -> bool {return !r.err && r.pos == len(r.data)}
r_left :: proc(r: ^Reader) -> int {return len(r.data) - r.pos}

r_fail :: proc(r: ^Reader) {
	r.err = true
	r.pos = len(r.data)
}

r_raw :: proc(r: ^Reader, n: int) -> []byte {
	if r.err || n < 0 || r.pos + n > len(r.data) {
		r_fail(r)
		return nil
	}
	b := r.data[r.pos:r.pos + n]
	r.pos += n
	return b
}

r_u8 :: proc(r: ^Reader) -> u8 {
	b := r_raw(r, 1)
	return b[0] if b != nil else 0
}
r_u16 :: proc(r: ^Reader) -> u16 {
	b := r_raw(r, 2)
	return u16(b[0]) << 8 | u16(b[1]) if b != nil else 0
}
r_u32 :: proc(r: ^Reader) -> u32 {
	b := r_raw(r, 4)
	return u32(b[0]) << 24 | u32(b[1]) << 16 | u32(b[2]) << 8 | u32(b[3]) if b != nil else 0
}
r_u64 :: proc(r: ^Reader) -> u64 {
	hi := r_u32(r)
	lo := r_u32(r)
	return u64(hi) << 32 | u64(lo)
}

r_varint :: proc(r: ^Reader) -> int {
	if r.err || r.pos >= len(r.data) {
		r_fail(r)
		return 0
	}
	first := r.data[r.pos]
	switch first >> 6 {
	case 0:
		r.pos += 1
		return int(first)
	case 1:
		v := int(r_u16(r) & 0x3fff)
		if v < 1 << 6 do r_fail(r) // must be minimal
		return v
	case 2:
		v := int(r_u32(r) & 0x3fff_ffff)
		if v < 1 << 14 do r_fail(r)
		return v
	}
	r_fail(r)
	return 0
}

r_vec :: proc(r: ^Reader) -> []byte {
	n := r_varint(r)
	return r_raw(r, n)
}

r_sub :: proc(r: ^Reader) -> Reader {
	return reader_make(r_vec(r))
}

r_optional :: proc(r: ^Reader) -> bool {
	v := r_u8(r)
	if v > 1 do r_fail(r)
	return v == 1
}

// ---------------------------------------------------------------------------

clone_bytes :: proc(b: []byte, allocator: mem.Allocator) -> []byte {
	if len(b) == 0 do return nil
	out := make([]byte, len(b), allocator)
	copy(out, b)
	return out
}

bytes_equal :: proc(a, b: []byte) -> bool {
	if len(a) != len(b) do return false
	for i in 0 ..< len(a) do if a[i] != b[i] do return false
	return true
}
