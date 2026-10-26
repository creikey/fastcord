package icon_sheet

import "core:hash"

// encode_png_gray encodes an 8-bit grayscale image as PNG (stored deflate blocks).
encode_png_gray :: proc(pix: []u8, w, h: int, allocator := context.allocator) -> []u8 {
	out := make([dynamic]u8, allocator)
	be32 :: proc(b: ^[dynamic]u8, v: u32) {
		append(b, u8(v >> 24), u8(v >> 16), u8(v >> 8), u8(v))
	}
	chunk :: proc(out: ^[dynamic]u8, typ: string, data: []u8) {
		be32(out, u32(len(data)))
		start := len(out)
		append(out, typ)
		append(out, ..data)
		be32(out, hash.crc32(out[start:]))
	}
	append(&out, "\x89PNG\r\n\x1a\n")
	ihdr: [dynamic]u8
	defer delete(ihdr)
	be32(&ihdr, u32(w))
	be32(&ihdr, u32(h))
	append(&ihdr, 8, 0, 0, 0, 0) // 8-bit, grayscale, deflate, filter 0, no interlace
	chunk(&out, "IHDR", ihdr[:])
	raw := make([dynamic]u8, 0, (w + 1) * h)
	defer delete(raw)
	for y in 0 ..< h {
		append(&raw, 0)
		append(&raw, ..pix[y * w:(y + 1) * w])
	}
	z: [dynamic]u8
	defer delete(z)
	append(&z, 0x78, 0x01)
	for i := 0; i < len(raw); i += 65535 {
		n := min(65535, len(raw) - i)
		append(&z, i + n == len(raw) ? 1 : 0, u8(n), u8(n >> 8), u8(~u16(n)), u8(~u16(n) >> 8))
		append(&z, ..raw[i:i + n])
	}
	be32(&z, hash.adler32(raw[:]))
	chunk(&out, "IDAT", z[:])
	chunk(&out, "IEND", nil)
	return out[:]
}
