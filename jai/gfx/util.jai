// Minimal PNG encoder (stored/uncompressed deflate), RGBA8, for test screenshots.
encode_png :: (pixels: []u8, w: int, h: int, allocator := context.allocator) -> []u8 {
    put :: (b: *[..]u8, data: []u8) {
        n := b.count;
        array_resize(b, n + data.count, initialize = false);
        memcpy(b.data + n, data.data, data.count);
    }
    be32 :: (v: u32) -> [4]u8 { return .[cast,trunc(u8) (v >> 24), cast,trunc(u8) (v >> 16), cast,trunc(u8) (v >> 8), cast,trunc(u8) v]; }
    chunk :: (b: *[..]u8, type: string, data: []u8) {
        put(b, be32(cast(u32) data.count));
        start := b.count;
        put(b, cast([]u8) type);
        put(b, data);
        put(b, be32(crc32(array_view(b.*, start))));
    }

    b: [..]u8;
    b.allocator = allocator;
    array_reserve(*b, w * h * 4 + 1024);
    put(*b, u8.[0x89, #char "P", #char "N", #char "G", 13, 10, 0x1a, 10]);

    ihdr: [13]u8;
    memcpy(ihdr.data, be32(cast(u32) w).data, 4);
    memcpy(ihdr.data + 4, be32(cast(u32) h).data, 4);
    ihdr[8] = 8; // bit depth
    ihdr[9] = 6; // RGBA
    chunk(*b, "IHDR", ihdr);

    // zlib stream of stored blocks over filtered scanlines (filter byte 0 per row).
    row := w * 4 + 1;
    raw_len := row * h;
    raw := NewArray(raw_len, u8,, temp);
    for y: 0..h-1 memcpy(raw.data + y * row + 1, pixels.data + y * w * 4, w * 4);
    z: [..]u8;
    z.allocator = temp;
    array_reserve(*z, raw_len + raw_len / 65535 * 5 + 16);
    put(*z, u8.[0x78, 0x01]);
    off := 0;
    while true {
        n := min(65535, raw_len - off);
        final: u8 = xx ifx off + n >= raw_len then 1 else 0;
        nn := ~cast(u16) n;
        put(*z, u8.[final, cast,trunc(u8) n, cast,trunc(u8) (n >> 8), cast,trunc(u8) nn, cast,trunc(u8) (nn >> 8)]);
        put(*z, array_view(raw, off, n));
        off += n;
        if off >= raw_len break;
    }
    put(*z, be32(adler32(raw)));
    chunk(*b, "IDAT", z);
    chunk(*b, "IEND", .[]);
    return b;
}

write_png :: (path: string, pixels: []u8, w: int, h: int) -> bool {
    return write_entire_file(path, cast(string) encode_png(pixels, w, h, temp));
}

#scope_file

crc32 :: (data: []u8) -> u32 {
    TABLE :: #run -> [256]u32 {
        t: [256]u32;
        for i: 0..255 {
            c := cast(u32) i;
            for 1..8  c = ifx c & 1 then 0xEDB88320 ^ (c >> 1) else c >> 1;
            t[i] = c;
        }
        return t;
    };
    c: u32 = 0xFFFF_FFFF;
    for data  c = TABLE[(c ^ it) & 0xFF] ^ (c >> 8);
    return ~c;
}

adler32 :: (data: []u8) -> u32 {
    a, b: u32 = 1, 0;
    for data { a = (a + it) % 65521; b = (b + a) % 65521; }
    return (b << 16) | a;
}
