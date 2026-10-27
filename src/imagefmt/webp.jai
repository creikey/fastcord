// encode_webp_lossless writes RGBA8 pixels (straight alpha) as Chrome's canvas.toBlob("image/webp", 1)
// does: libwebp lossless, quality 75, method 0, plus icc (the canvas's colour profile) in an ICCP
// chunk when given. Fully transparent pixels lose their colour (exact = 0, as in Chrome); Chrome's
// canvas would also premultiply other translucent pixels, which this doesn't (uploads are opaque).
// Empty on failure.
encode_webp_lossless :: (rgba: []u8, w: int, h: int, icc: []u8 = .[], allocator := context.allocator) -> []u8 {
	assert(rgba.count >= w * h * 4);
	p: *u8;
	n := fc_webp_lossless(rgba.data, xx w, xx h, icc.data, xx icc.count, *p);
	if n == 0 return .[];
	defer fc_webp_free(p);
	out := NewArray(xx n, u8, false,, allocator);
	memcpy(out.data, p, xx n);
	return out;
}

#scope_module

// vendor/libwebp: the library (fc_libwebp.sources) and its wrapper (fc_libwebp.c).
fc_webp_lossless :: (rgba: *u8, w: s32, h: s32, icc: *u8, icc_len: u64, out: **u8) -> u64 #foreign vendor;
fc_webp_free :: (p: *void) #foreign vendor;

// WebP: Wuffs decodes every bitstream (VP8, VP8L, ALPH). Wuffs v0.4 can't animate WebP, so this file
// parses the ANIM/ANMF container itself, hands each frame to Wuffs as a little still WebP of its own,
// and composites exactly like libwebp's WebPAnimDecoder.

Webp_Chunk :: struct {
	fourcc: string;
	data: []u8;
}

next_chunk :: (data: []u8, pos: *int) -> Webp_Chunk, bool, Error {
	if pos.* + 8 > data.count return .{}, false, .None;
	size := le32(data, pos.* + 4);
	start := pos.* + 8;
	if size > data.count - start return .{}, false, .Truncated;
	ch := Webp_Chunk.{bytes(data, pos.*, 4), array_view(data, start, size)};
	pos.* = start + size + (size & 1);
	return ch, true, .None;
}

// One frame's bitstream.
Webp_Bits :: struct {
	alph: []u8;
	kind: string; // "VP8 " or "VP8L"
	data: []u8;
}

// Width, height, has alpha, ok.
bits_dims :: (b: Webp_Bits) -> int, int, bool, bool {
	d := b.data;
	if b.kind == "VP8L" {
		if d.count < 5 || d[0] != 0x2F return 0, 0, false, false;
		v := le32(d, 1);
		return (v & 0x3FFF) + 1, ((v >> 14) & 0x3FFF) + 1, ((v >> 28) & 1) == 1, true;
	}
	if d.count < 10 || d[3] != 0x9D || d[4] != 0x01 || d[5] != 0x2A return 0, 0, b.alph.count != 0, false;
	return le16(d, 6) & 0x3FFF, le16(d, 8) & 0x3FFF, b.alph.count != 0, true;
}

put_u32 :: (out: *[..]u8, n: int) {
	array_add(out, cast,trunc(u8) n, cast,trunc(u8) (n >> 8), cast,trunc(u8) (n >> 16), cast,trunc(u8) (n >> 24));
}

append_bytes :: (out: *[..]u8, s: string) {
	array_add(out, ..cast([]u8) s);
}

// Decodes one frame's bitstream (w*h) into dst, rows dst_stride bytes apart, by wrapping it in a
// still WebP file: RIFF, then VP8X + ALPH when there is alpha, then the VP8 / VP8L chunk.
webp_decode_bits :: (c: *Decode_Ctx, b: Webp_Bits, w: int, h: int, dst: []u8, dst_stride: int) -> Error {
	put_chunk :: (out: *[..]u8, fourcc: string, data: []u8) {
		append_bytes(out, fourcc);
		put_u32(out, data.count);
		array_add(out, ..data);
		if data.count & 1  array_add(out, 0);
	}
	file: [..]u8;
	file.allocator = c.allocator;
	array_reserve(*file, b.data.count + b.alph.count + 64);
	defer array_free(file);
	append_bytes(*file, "RIFF\x00\x00\x00\x00WEBP");
	if b.alph.count {
		x := u8.[0x10, 0, 0, 0, cast,trunc(u8) (w - 1), cast,trunc(u8) ((w - 1) >> 8), cast,trunc(u8) ((w - 1) >> 16), cast,trunc(u8) (h - 1), cast,trunc(u8) ((h - 1) >> 8), cast,trunc(u8) ((h - 1) >> 16)];
		put_chunk(*file, "VP8X", x);
		put_chunk(*file, "ALPH", b.alph);
	}
	put_chunk(*file, b.kind, b.data);
	set_riff_size(file);
	return wuffs_decode_into(c, file, .WebP, w, h, dst, dst_stride);
}

set_riff_size :: (file: []u8) {
	n := file.count - 8;
	file[4], file[5], file[6], file[7] = cast,trunc(u8) n, cast,trunc(u8) (n >> 8), cast,trunc(u8) (n >> 16), cast,trunc(u8) (n >> 24);
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
	riff := le32(data, 4);
	if riff < 4 return .Corrupt;
	if riff + 8 < data.count  data.count = riff + 8;
	pos := 12;
	first, ok, err := next_chunk(data, *pos);
	if err != .None return err;
	if !ok return .Truncated;
	still_vp8x := first.fourcc == "VP8X" && first.data.count >= 1 && (first.data[0] & 0x02) == 0;
	if still_vp8x {
		// Wuffs v0.4 doesn't skip the 5-byte header of a VP8L chunk inside VP8X ("bad Huffman code"),
		// which is how Chrome's canvas writes lossless WebP (VP8X + ICCP + VP8L): give it RIFF + VP8L.
		p := pos;
		while true {
			ch, more, cerr := next_chunk(data, *p);
			if cerr != .None return cerr;
			if !more break;
			if ch.fourcc != "VP8L" continue;
			start := p - ch.data.count - (ch.data.count & 1) - 8;
			plain := NewArray(12 + p - start, u8, false,, c.allocator);
			defer free(plain.data,, c.allocator);
			memcpy(plain.data, "RIFF\x00\x00\x00\x00WEBP".data, 12);
			memcpy(plain.data + 12, data.data + start, p - start);
			set_riff_size(plain);
			return wuffs_decode(c, plain, img, .WebP);
		}
	}
	if still_vp8x || first.fourcc == "VP8 " || first.fourcc == "VP8L" return wuffs_decode(c, data, img, .WebP);
	if first.fourcc != "VP8X" return .Corrupt;
	if first.data.count < 10 return .Truncated;
	cw := le24(first.data, 4) + 1;
	chh := le24(first.data, 7) + 1;
	err = check_size(c, cw, chh);
	if err != .None return err;
	img.width, img.height = cw, chh;

	frames: [..]Anm_Frame;
	frames.allocator = c.allocator;
	defer array_free(frames);
	while true {
		ch, more, cerr := next_chunk(data, *pos);
		if cerr != .None return cerr;
		if !more break;
		if ch.fourcc == {
		case "ANIM";
			if ch.data.count < 6 return .Truncated;
			img.loop_count = le16(ch.data, 4);
		case "ANMF";
			d := ch.data;
			if d.count < 16 return .Truncated;
			f := Anm_Frame.{
				x = 2 * le24(d, 0),
				y = 2 * le24(d, 3),
				w = le24(d, 6) + 1,
				h = le24(d, 9) + 1,
				duration = le24(d, 12),
				dispose_bg = (d[15] & 1) == 1,
				blend = (d[15] & 2) == 0
			};
			inner := array_view(d, 16);
			sp := 0;
			while true {
				s, smore, serr := next_chunk(inner, *sp);
				if serr != .None return serr;
				if !smore break;
				if s.fourcc == "ALPH"  f.bits.alph = s.data;
				if s.fourcc == "VP8 " || s.fourcc == "VP8L" {
					f.bits.kind = s.fourcc;
					f.bits.data = s.data;
					if s.fourcc == "VP8L"  f.bits.alph = .[];
					break;
				}
			}
			if f.bits.kind == "" return .Corrupt;
			bw, bh, alpha, dok := bits_dims(f.bits);
			if !dok || bw != f.w || bh != f.h return .Corrupt;
			if f.x + f.w > cw || f.y + f.h > chh return .Corrupt;
			f.has_alpha = alpha;
			array_add(*frames, f);
		}
		if c.first_only && frames.count > 0 break;
	}
	if frames.count == 0 return .Corrupt;

	canvas := alloc_pixels(c, cw, chh);
	defer free(canvas.data,, c.allocator);
	prev := alloc_pixels(c, cw, chh); // previous frame after disposal
	defer free(prev.data,, c.allocator);
	stride := cw * 4;
	prev_f: Anm_Frame;
	prev_key := false;
	full :: (f: Anm_Frame, w: int, h: int) -> bool { return f.w == w && f.h == h; }
	for f, i: frames {
		key := i == 0 || ((!f.has_alpha || !f.blend) && full(f, cw, chh)) || (prev_f.dispose_bg && (full(prev_f, cw, chh) || prev_key));
		if key  memset(canvas.data, 0, canvas.count);
		else    memcpy(canvas.data, prev.data, canvas.count);
		err = webp_decode_bits(c, f.bits, f.w, f.h, array_view(canvas, f.y * stride + f.x * 4), stride);
		if err != .None return err;
		if !key && f.blend {
			for y: 0..f.h-1 {
				off := (f.y + y) * stride + f.x * 4;
				for x: 0..f.w-1 {
					o := off + x * 4;
					if canvas[o + 3] != 255  blend_over(cast(*[4]u8) *canvas[o], (cast(*[4]u8) *prev[o]).*);
				}
			}
		}
		err = push_frame(c, canvas, f.duration);
		if err != .None return err;
		memcpy(prev.data, canvas.data, canvas.count);
		if f.dispose_bg {
			for y: 0..f.h-1  memset(prev.data + (f.y + y) * stride + f.x * 4, 0, f.w * 4);
		}
		prev_f = f;
		prev_key = key;
	}
	return .None;
}

// Straight-alpha "over": src onto dst, in place in src (libwebp's BlendPixelNonPremult).
blend_over :: (src: *[4]u8, dst: [4]u8) {
	sa := cast(u32) src.*[3];
	if sa == 0 { src.* = dst; return; }
	dfa := ((cast(u32) dst[3]) * (256 - sa)) >> 8;
	ba := sa + dfa;
	scale := (cast(u32) 1 << 24) / ba;
	for i: 0..2  src.*[i] = cast(u8) ((((cast(u32) src.*[i]) * sa + (cast(u32) dst[i]) * dfa) * scale) >> 24);
	src.*[3] = cast(u8) ba;
}
