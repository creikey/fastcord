package gfx

import "core:bytes"
import "core:hash"
import "core:os"

@(private)
read_entire_file :: proc(path: string) -> ([]byte, bool) {
	data, err := os.read_entire_file(path, context.allocator)
	return data, err == nil
}

// Minimal PNG encoder (stored/uncompressed deflate), RGBA8, for test screenshots.
encode_png :: proc(pixels: []u8, w, h: int, allocator := context.allocator) -> []u8 {
	b: bytes.Buffer
	bytes.buffer_init_allocator(&b, 0, w * h * 4 + 1024, allocator)
	bytes.buffer_write(&b, {0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n'})

	be32 :: proc(v: u32) -> [4]u8 {return {u8(v >> 24), u8(v >> 16), u8(v >> 8), u8(v)}}
	chunk :: proc(b: ^bytes.Buffer, type: string, data: []u8) {
		l := be32(u32(len(data)))
		bytes.buffer_write(b, l[:])
		start := bytes.buffer_length(b)
		bytes.buffer_write_string(b, type)
		bytes.buffer_write(b, data)
		crc := hash.crc32(bytes.buffer_to_bytes(b)[start:])
		c := be32(crc)
		bytes.buffer_write(b, c[:])
	}

	ihdr: [13]u8
	wb, hb := be32(u32(w)), be32(u32(h))
	copy(ihdr[0:], wb[:])
	copy(ihdr[4:], hb[:])
	ihdr[8] = 8 // bit depth
	ihdr[9] = 6 // RGBA
	chunk(&b, "IHDR", ihdr[:])

	// zlib stream of stored blocks over filtered scanlines (filter byte 0 per row).
	raw_len := (w * 4 + 1) * h
	raw := make([]u8, raw_len, context.temp_allocator)
	for y in 0 ..< h {
		raw[y * (w * 4 + 1)] = 0
		copy(raw[y * (w * 4 + 1) + 1:], pixels[y * w * 4:][:w * 4])
	}
	z: bytes.Buffer
	bytes.buffer_init_allocator(&z, 0, raw_len + raw_len / 65535 * 5 + 16, context.temp_allocator)
	bytes.buffer_write(&z, {0x78, 0x01})
	for off := 0; off < raw_len || raw_len == 0; {
		n := min(65535, raw_len - off)
		final: u8 = off + n >= raw_len ? 1 : 0
		hdr := [5]u8{final, u8(n), u8(n >> 8), u8(~u16(n)), u8(~u16(n) >> 8)}
		bytes.buffer_write(&z, hdr[:])
		bytes.buffer_write(&z, raw[off:][:n])
		off += n
		if raw_len == 0 do break
	}
	ad := be32(hash.adler32(raw))
	bytes.buffer_write(&z, ad[:])
	chunk(&b, "IDAT", bytes.buffer_to_bytes(&z))
	chunk(&b, "IEND", nil)
	return bytes.buffer_to_bytes(&b)
}

write_png :: proc(path: string, pixels: []u8, w, h: int) -> bool {
	data := encode_png(pixels, w, h, context.temp_allocator)
	return os.write_entire_file(path, data) == nil
}
