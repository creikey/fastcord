// WebP: Wuffs decodes every bitstream (VP8, VP8L, ALPH). Wuffs v0.4 can't animate WebP, so this file
// parses the ANIM/ANMF container itself, hands each frame to Wuffs as a little still WebP of its own,
// and composites exactly like libwebp's WebPAnimDecoder.


#scope_module

Webp_Chunk :: struct {
	fourcc: string;
	data: []u8;
}

next_chunk :: (data: []u8, pos: *int) -> Webp_Chunk, bool, Error {
	if pos.* + 8 > len(data) { return .{}, false, .None; }
	ch := Webp_Chunk.{fourcc = as_string(sub(data, pos.*, pos.* + 4))};
	size := le32i(sub_from(data, pos.* + 4));
	start := pos.* + 8;
	if size > len(data) - start { return .{}, false, .Truncated; }
	ch.data = sub(data, start, start + size);
	pos.* = start + size + (size & 1);
	return ch, true, .None;
}

// One frame's bitstream.
Webp_Bits :: struct {
	alph: []u8;
	kind: string; // "VP8 " or "VP8L"
	data: []u8;
}

vp8l_dims :: (data: []u8) -> int, int, bool, bool {
	w: int;
	h: int;
	alpha: bool;
	ok: bool;
	if len(data) < 5 || data[0] != 0x2F { return w, h, alpha, ok; }
	v := cast(u32)(le32i(sub_from(data, 1)));
	return cast(int)(v & 0x3FFF) + 1, cast(int)((v >> 14) & 0x3FFF) + 1, (v >> 28) & 1 == 1, true;
}

vp8_dims :: (data: []u8) -> int, int, bool {
	w: int;
	h: int;
	ok: bool;
	if len(data) < 10 || data[3] != 0x9D || data[4] != 0x01 || data[5] != 0x2A { return w, h, ok; }
	return le16i(sub_from(data, 6)) & 0x3FFF, le16i(sub_from(data, 8)) & 0x3FFF, true;
}

bits_dims :: (b: Webp_Bits) -> int, int, bool, bool {
	w: int;
	h: int;
	alpha: bool;
	ok: bool;
	if b.kind == "VP8L" { { __r1, __r2, __r3, __r4 := vp8l_dims(b.data); return __r1, __r2, __r3, __r4; } }
	w, h, ok = vp8_dims(b.data);
	return w, h, b.alph != null, ok;
}

// Decodes one frame's bitstream (w*h) into dst, rows dst_stride bytes apart, by wrapping it in a
// still WebP file: RIFF, then VP8X + ALPH when there is alpha, then the VP8 / VP8L chunk.
webp_decode_bits :: (c: *Decode_Ctx, b: Webp_Bits, w: int, h: int, dst: []u8, dst_stride: int) -> Error {
	put_chunk :: (out: *[..]u8, fourcc: string, data: []u8) {
		n := len(data);
		append(out, fourcc, );
		append(out, cast(u8)(n), cast(u8)(n >> 8), cast(u8)(n >> 16), cast(u8)(n >> 24));
		append(out, ..data);
		if n & 1 == 1 { append(out, 0); }
	}
	file := make_dynamic(u8, 0, len(b.data) + len(b.alph) + 64, c.allocator);
	defer delete(file);
	append(*file, "RIFF\x00\x00\x00\x00WEBP");
	if b.alph != null {
		x := u8.[0x10, 0, 0, 0, cast(u8)(w - 1), cast(u8)((w - 1) >> 8), cast(u8)((w - 1) >> 16), cast(u8)(h - 1), cast(u8)((h - 1) >> 8), cast(u8)((h - 1) >> 16)];
		put_chunk(*file, "VP8X", view(x));
		put_chunk(*file, "ALPH", b.alph);
	}
	put_chunk(*file, b.kind, b.data);
	riff := len(file) - 8;
	file[4], file[5], file[6], file[7] = cast(u8)(riff), cast(u8)(riff >> 8), cast(u8)(riff >> 16), cast(u8)(riff >> 24);
	return wuffs_decode_into(c, view(file), .WebP, w, h, dst, dst_stride);
}

Anm_Frame :: struct {
	x, y, w, h: int;
	duration: int;
	dispose_bg: bool;
	blend: bool;
	has_alpha: bool;
	bits: Webp_Bits;
}

webp_decode :: (c: *Decode_Ctx, data_in: []u8, img: *Image) -> Error {
	data := data_in;
	riff := le32i(sub_from(data, 4));
	if riff < 4 { return .Corrupt; }
	if riff + 8 < len(data) { data = sub(data, 0, riff + 8); }
	pos := 12;
	first, ok, __e5 := next_chunk(data, *pos); if failed(__e5) return __e5;
	if !ok { return .Truncated; }
	if first.fourcc == "VP8X" && len(first.data) >= 1 && first.data[0] & 0x02 == 0 {
		// Wuffs v0.4 doesn't skip the 5-byte header of a VP8L chunk inside VP8X ("bad Huffman code"),
		// which is how Chrome's canvas writes lossless WebP (VP8X + ICCP + VP8L): give it RIFF + VP8L.
		p := pos;
		while true {
			ch, more, __e6 := next_chunk(data, *p); if failed(__e6) return __e6;
			if !more { break; }
			if ch.fourcc != "VP8L" { continue; }
			start := p - len(ch.data) - (len(ch.data) & 1) - 8;
			plain := make_slice(u8, 12 + p - start, c.allocator);
			defer delete(plain, c.allocator);
			copy(plain, "RIFF\x00\x00\x00\x00WEBP");
			copy(sub_from(plain, 12), sub(data, start, p));
			n := len(plain) - 8;
			plain[4], plain[5], plain[6], plain[7] = cast(u8)(n), cast(u8)(n >> 8), cast(u8)(n >> 16), cast(u8)(n >> 24);
			return wuffs_decode(c, plain, img, .WebP);
		}
	}
	if first.fourcc == "VP8X" && len(first.data) >= 1 && first.data[0] & 0x02 == 0 || first.fourcc == "VP8 " || first.fourcc == "VP8L" {
		return wuffs_decode(c, data, img, .WebP);
	}
	if first.fourcc != "VP8X" { return .Corrupt; }
	if len(first.data) < 10 { return .Truncated; }
	cw := le24i(sub_from(first.data, 4)) + 1;
	chh := le24i(sub_from(first.data, 7)) + 1;
	__e7 := check_size(c, cw, chh); if failed(__e7) return __e7;
	img.width, img.height = cw, chh;

	frames := make_dynamic(Anm_Frame, 0, 0, c.allocator);
	defer delete(frames);
	while true {
		ch, more, __e8 := next_chunk(data, *pos); if failed(__e8) return __e8;
		if !more { break; }
		if ch.fourcc == {
		case "ANIM";
			if len(ch.data) < 6 { return .Truncated; }
			img.loop_count = le16i(sub_from(ch.data, 4));
		case "ANMF";
			if len(ch.data) < 16 { return .Truncated; }
			f := Anm_Frame.{
				x = 2 * le24i(sub_from(ch.data, 0)),
				y = 2 * le24i(sub_from(ch.data, 3)),
				w = le24i(sub_from(ch.data, 6)) + 1,
				h = le24i(sub_from(ch.data, 9)) + 1,
				duration = le24i(sub_from(ch.data, 12)),
				dispose_bg = ch.data[15] & 1 == 1,
				blend = ch.data[15] & 2 == 0
			};
			sub := sub_from(ch.data, 16);
			sp := 0;
			while true {
				s, smore, __e10 := next_chunk(sub, *sp); if failed(__e10) return __e10;
				if !smore { break; }
				if s.fourcc == "ALPH" { f.bits.alph = s.data; }
				if s.fourcc == "VP8 " || s.fourcc == "VP8L" {
					f.bits.kind = s.fourcc;
					f.bits.data = s.data;
					if s.fourcc == "VP8L" { f.bits.alph = null; }
					break;
				}
			}
			if f.bits.kind == "" { return .Corrupt; }
			bw, bh, alpha, dok := bits_dims(f.bits);
			if !dok || bw != f.w || bh != f.h { return .Corrupt; }
			if f.x + f.w > cw || f.y + f.h > chh { return .Corrupt; }
			f.has_alpha = alpha;
			append(*frames, f);
		}
		if c.first_only && len(frames) > 0 { break; }
	}
	if len(frames) == 0 { return .Corrupt; }

	canvas, __e11 := alloc_pixels(c, cw, chh); if failed(__e11) return __e11;
	defer delete(canvas, c.allocator);
	prev, __e12 := alloc_pixels(c, cw, chh); if failed(__e12) return __e12; // previous frame after disposal
	defer delete(prev, c.allocator);
	stride := cw * 4;
	prev_f: Anm_Frame;
	prev_key := false;
	for f, i: frames {
		full :: (f: Anm_Frame, cw: int, ch: int) -> bool {return f.w == cw && f.h == ch;}
		key := i == 0 || ((!f.has_alpha || !f.blend) && full(f, cw, chh)) || (prev_f.dispose_bg && (full(prev_f, cw, chh) || prev_key));
		if key {
			mem.zero_slice(canvas);
		} else {
			copy(canvas, prev);
		}
		origin := sub_from(canvas, f.y * stride + f.x * 4);
		__e13 := webp_decode_bits(c, f.bits, f.w, f.h, origin, stride); if failed(__e13) return __e13;
		if !key && f.blend {
			for y: 0..f.h-1 {
				off := (f.y + y) * stride + f.x * 4;
				for x: 0..f.w-1 {
					o := off + x * 4;
					if canvas[o + 3] != 255 {
						(cast(*[4]u8)(*canvas[o])).* = blend_over((cast(*[4]u8)(*canvas[o])).*, (cast(*[4]u8)(*prev[o])).*);
					}
				}
			}
		}
		__e14 := push_frame(c, canvas, f.duration); if failed(__e14) return __e14;
		copy(prev, canvas);
		if f.dispose_bg {
			for y: 0..f.h-1 { mem.zero_slice(sub(sub_from(prev, (f.y + y) * stride + f.x * 4), 0, f.w * 4)); }
		}
		prev_f = f;
		prev_key = key;
	}
	return .None;
}
#scope_export

