#scope_module

read_entire_file :: (path: string) -> []u8, bool {
	data, err := os.read_entire_file(path, context.allocator);
	return data, err == null;
}
#scope_export

// Minimal PNG encoder (stored/uncompressed deflate), RGBA8, for test screenshots.
encode_png :: (pixels: []u8, w: int, h: int, allocator := context.allocator) -> []u8 {
	b: bytes.Buffer;
	bytes.buffer_init_allocator(*b, 0, w * h * 4 + 1024, allocator);
	bytes.buffer_write(*b, .{0x89, #char "P", #char "N", #char "G", 13, 10, 0x1a, 10});

	be32 :: (v: u32) -> [4]u8 {return .[cast(u8)(v >> 24), cast(u8)(v >> 16), cast(u8)(v >> 8), cast(u8)(v)];}
	chunk :: (b: *bytes.Buffer, type: string, data: []u8) {
		l := be32(cast(u32)(len(data)));
		bytes.buffer_write(b, view(l));
		start := bytes.buffer_length(b);
		bytes.buffer_write_string(b, type);
		bytes.buffer_write(b, data);
		crc := hash.crc32(sub_from(bytes.buffer_to_bytes(b), start));
		c := be32(crc);
		bytes.buffer_write(b, view(c));
	}

	ihdr: [13]u8;
	wb, hb := be32(cast(u32)(w)), be32(cast(u32)(h));
	copy(sub_from(ihdr, 0), view(wb));
	copy(sub_from(ihdr, 4), view(hb));
	ihdr[8] = 8; // bit depth
	ihdr[9] = 6; // RGBA
	chunk(*b, "IHDR", view(ihdr));

	// zlib stream of stored blocks over filtered scanlines (filter byte 0 per row).
	raw_len := (w * 4 + 1) * h;
	raw := make_slice(u8, raw_len, temp);
	for y: 0..h-1 {
		raw[y * (w * 4 + 1)] = 0;
		copy(sub_from(raw, y * (w * 4 + 1) + 1), sub(sub_from(pixels, y * w * 4), 0, w * 4));
	}
	z: bytes.Buffer;
	bytes.buffer_init_allocator(*z, 0, raw_len + raw_len / 65535 * 5 + 16, temp);
	bytes.buffer_write(*z, .{0x78, 0x01});
	{ off := 0;
	while off < raw_len || raw_len == 0 {
		n := min(65535, raw_len - off);
		final: u8 = ifx off + n >= raw_len then 1 else 0;
		hdr := u8.[final, cast(u8)(n), cast(u8)(n >> 8), cast(u8)(~cast(u16)(n)), cast(u8)(~cast(u16)(n) >> 8)];
		bytes.buffer_write(*z, view(hdr));
		bytes.buffer_write(*z, sub(sub_from(raw, off), 0, n));
		off += n;
		if raw_len == 0 { break; }
	} }
	ad := be32(hash.adler32(raw));
	bytes.buffer_write(*z, view(ad));
	chunk(*b, "IDAT", bytes.buffer_to_bytes(*z));
	chunk(*b, "IEND", null);
	return bytes.buffer_to_bytes(*b);
}

write_png :: (path: string, pixels: []u8, w: int, h: int) -> bool {
	data := encode_png(pixels, w, h, temp);
	return os.write_entire_file(path, data) == null;
}

