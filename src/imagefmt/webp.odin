package imagefmt

// WebP: Wuffs decodes every bitstream (VP8, VP8L, ALPH). Wuffs v0.4 can't animate WebP, so this file
// parses the ANIM/ANMF container itself, hands each frame to Wuffs as a little still WebP of its own,
// and composites exactly like libwebp's WebPAnimDecoder.

import "core:mem"

@(private)
Webp_Chunk :: struct {
	fourcc: string,
	data:   []byte,
}

@(private)
next_chunk :: proc(data: []byte, pos: ^int) -> (Webp_Chunk, bool, Error) {
	if pos^ + 8 > len(data) do return {}, false, .None
	ch := Webp_Chunk{fourcc = string(data[pos^:pos^ + 4])}
	size := le32i(data[pos^ + 4:])
	start := pos^ + 8
	if size > len(data) - start do return {}, false, .Truncated
	ch.data = data[start:start + size]
	pos^ = start + size + (size & 1)
	return ch, true, .None
}

// One frame's bitstream.
@(private)
Webp_Bits :: struct {
	alph: []byte,
	kind: string, // "VP8 " or "VP8L"
	data: []byte,
}

@(private)
vp8l_dims :: proc(data: []byte) -> (w, h: int, alpha: bool, ok: bool) {
	if len(data) < 5 || data[0] != 0x2F do return
	v := u32(le32i(data[1:]))
	return int(v & 0x3FFF) + 1, int((v >> 14) & 0x3FFF) + 1, (v >> 28) & 1 == 1, true
}

@(private)
vp8_dims :: proc(data: []byte) -> (w, h: int, ok: bool) {
	if len(data) < 10 || data[3] != 0x9D || data[4] != 0x01 || data[5] != 0x2A do return
	return le16i(data[6:]) & 0x3FFF, le16i(data[8:]) & 0x3FFF, true
}

@(private)
bits_dims :: proc(b: Webp_Bits) -> (w, h: int, alpha: bool, ok: bool) {
	if b.kind == "VP8L" do return vp8l_dims(b.data)
	w, h, ok = vp8_dims(b.data)
	return w, h, b.alph != nil, ok
}

// Decodes one frame's bitstream (w*h) into dst, rows dst_stride bytes apart, by wrapping it in a
// still WebP file: RIFF, then VP8X + ALPH when there is alpha, then the VP8 / VP8L chunk.
@(private)
webp_decode_bits :: proc(c: ^Decode_Ctx, b: Webp_Bits, w, h: int, dst: []u8, dst_stride: int) -> Error {
	put_chunk :: proc(out: ^[dynamic]byte, fourcc: string, data: []byte) {
		n := len(data)
		append(out, fourcc, )
		append(out, u8(n), u8(n >> 8), u8(n >> 16), u8(n >> 24))
		append(out, ..data)
		if n & 1 == 1 do append(out, 0)
	}
	file := make([dynamic]byte, 0, len(b.data) + len(b.alph) + 64, c.allocator)
	defer delete(file)
	append(&file, "RIFF\x00\x00\x00\x00WEBP")
	if b.alph != nil {
		x := [10]u8{0x10, 0, 0, 0, u8(w - 1), u8((w - 1) >> 8), u8((w - 1) >> 16), u8(h - 1), u8((h - 1) >> 8), u8((h - 1) >> 16)}
		put_chunk(&file, "VP8X", x[:])
		put_chunk(&file, "ALPH", b.alph)
	}
	put_chunk(&file, b.kind, b.data)
	riff := len(file) - 8
	file[4], file[5], file[6], file[7] = u8(riff), u8(riff >> 8), u8(riff >> 16), u8(riff >> 24)
	return wuffs_decode_into(c, file[:], .WebP, w, h, dst, dst_stride)
}

@(private)
Anm_Frame :: struct {
	x, y, w, h: int,
	duration:   int,
	dispose_bg: bool,
	blend:      bool,
	has_alpha:  bool,
	bits:       Webp_Bits,
}

@(private)
webp_decode :: proc(c: ^Decode_Ctx, data_in: []byte, img: ^Image) -> Error {
	data := data_in
	riff := le32i(data[4:])
	if riff < 4 do return .Corrupt
	if riff + 8 < len(data) do data = data[:riff + 8]
	pos := 12
	first, ok := next_chunk(data, &pos) or_return
	if !ok do return .Truncated
	if first.fourcc == "VP8X" && len(first.data) >= 1 && first.data[0] & 0x02 == 0 {
		// Wuffs v0.4 doesn't skip the 5-byte header of a VP8L chunk inside VP8X ("bad Huffman code"),
		// which is how Chrome's canvas writes lossless WebP (VP8X + ICCP + VP8L): give it RIFF + VP8L.
		p := pos
		for {
			ch, more := next_chunk(data, &p) or_return
			if !more do break
			if ch.fourcc != "VP8L" do continue
			start := p - len(ch.data) - (len(ch.data) & 1) - 8
			plain := make([]byte, 12 + p - start, c.allocator)
			defer delete(plain, c.allocator)
			copy(plain, "RIFF\x00\x00\x00\x00WEBP")
			copy(plain[12:], data[start:p])
			n := len(plain) - 8
			plain[4], plain[5], plain[6], plain[7] = u8(n), u8(n >> 8), u8(n >> 16), u8(n >> 24)
			return wuffs_decode(c, plain, img, .WebP)
		}
	}
	if first.fourcc == "VP8X" && len(first.data) >= 1 && first.data[0] & 0x02 == 0 || first.fourcc == "VP8 " || first.fourcc == "VP8L" {
		return wuffs_decode(c, data, img, .WebP)
	}
	if first.fourcc != "VP8X" do return .Corrupt
	if len(first.data) < 10 do return .Truncated
	cw := le24i(first.data[4:]) + 1
	chh := le24i(first.data[7:]) + 1
	check_size(c, cw, chh) or_return
	img.width, img.height = cw, chh

	frames := make([dynamic]Anm_Frame, c.allocator)
	defer delete(frames)
	for {
		ch, more := next_chunk(data, &pos) or_return
		if !more do break
		switch ch.fourcc {
		case "ANIM":
			if len(ch.data) < 6 do return .Truncated
			img.loop_count = le16i(ch.data[4:])
		case "ANMF":
			if len(ch.data) < 16 do return .Truncated
			f := Anm_Frame {
				x          = 2 * le24i(ch.data[0:]),
				y          = 2 * le24i(ch.data[3:]),
				w          = le24i(ch.data[6:]) + 1,
				h          = le24i(ch.data[9:]) + 1,
				duration   = le24i(ch.data[12:]),
				dispose_bg = ch.data[15] & 1 == 1,
				blend      = ch.data[15] & 2 == 0,
			}
			sub := ch.data[16:]
			sp := 0
			for {
				s, smore := next_chunk(sub, &sp) or_return
				if !smore do break
				if s.fourcc == "ALPH" do f.bits.alph = s.data
				if s.fourcc == "VP8 " || s.fourcc == "VP8L" {
					f.bits.kind = s.fourcc
					f.bits.data = s.data
					if s.fourcc == "VP8L" do f.bits.alph = nil
					break
				}
			}
			if f.bits.kind == "" do return .Corrupt
			bw, bh, alpha, dok := bits_dims(f.bits)
			if !dok || bw != f.w || bh != f.h do return .Corrupt
			if f.x + f.w > cw || f.y + f.h > chh do return .Corrupt
			f.has_alpha = alpha
			append(&frames, f)
		}
		if c.first_only && len(frames) > 0 do break
	}
	if len(frames) == 0 do return .Corrupt

	canvas := alloc_pixels(c, cw, chh) or_return
	defer delete(canvas, c.allocator)
	prev := alloc_pixels(c, cw, chh) or_return // previous frame after disposal
	defer delete(prev, c.allocator)
	stride := cw * 4
	prev_f: Anm_Frame
	prev_key := false
	for f, i in frames {
		full :: proc(f: Anm_Frame, cw, ch: int) -> bool {return f.w == cw && f.h == ch}
		key := i == 0 || ((!f.has_alpha || !f.blend) && full(f, cw, chh)) || (prev_f.dispose_bg && (full(prev_f, cw, chh) || prev_key))
		if key {
			mem.zero_slice(canvas)
		} else {
			copy(canvas, prev)
		}
		origin := canvas[f.y * stride + f.x * 4:]
		webp_decode_bits(c, f.bits, f.w, f.h, origin, stride) or_return
		if !key && f.blend {
			for y in 0 ..< f.h {
				off := (f.y + y) * stride + f.x * 4
				for x in 0 ..< f.w {
					o := off + x * 4
					if canvas[o + 3] != 255 {
						(^[4]u8)(&canvas[o])^ = blend_over((^[4]u8)(&canvas[o])^, (^[4]u8)(&prev[o])^)
					}
				}
			}
		}
		push_frame(c, canvas, f.duration) or_return
		copy(prev, canvas)
		if f.dispose_bg {
			for y in 0 ..< f.h do mem.zero_slice(prev[(f.y + y) * stride + f.x * 4:][:f.w * 4])
		}
		prev_f = f
		prev_key = key
	}
	return .None
}
