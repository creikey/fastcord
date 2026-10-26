package imagefmt

// WebP container (RIFF): simple VP8 / VP8L, VP8X extended with ALPH, and
// ANIM/ANMF animation composited exactly like libwebp's WebPAnimDecoder.

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

// Decoded frame bitstream, RGBA w*h.
@(private)
Webp_Bits :: struct {
	alph:  []byte,
	kind:  string, // "VP8 " or "VP8L"
	data:  []byte,
}

@(private)
unfilter_alpha :: proc(a: []u8, w, h: int, filter: u8) {
	if filter == 0 do return
	for y in 0 ..< h {
		row := a[y * w:][:w]
		if y == 0 || filter == 1 {
			pred: u8 = y == 0 ? 0 : a[(y - 1) * w]
			for i in 0 ..< w {
				row[i] = pred + row[i]
				pred = row[i]
			}
			continue
		}
		prev := a[(y - 1) * w:][:w]
		if filter == 2 {
			for i in 0 ..< w do row[i] = prev[i] + row[i]
		} else {
			top := prev[0]
			tl := top
			left := top
			for i in 0 ..< w {
				top = prev[i]
				g := i32(left) + i32(top) - i32(tl)
				pv := u8((g & ~i32(0xFF)) == 0 ? g : g < 0 ? i32(0) : i32(255))
				left = row[i] + pv
				tl = top
				row[i] = left
			}
		}
	}
}

// Decodes one frame bitstream into dst (RGBA, stride dst_stride) at its origin.
// Returns its size and whether it carries alpha.
@(private)
webp_decode_bits :: proc(c: ^Decode_Ctx, b: Webp_Bits, want_w, want_h: int, dst: []u8, dst_stride: int) -> (w, h: int, err: Error) {
	switch b.kind {
	case "VP8L":
		argb, lw, lh, _ := vp8l_decode(b.data, c.allocator, c.max_pixels) or_return
		defer delete(argb, c.allocator)
		if lw != want_w || lh != want_h do return 0, 0, .Corrupt
		for y in 0 ..< lh {
			row := dst[y * dst_stride:]
			for x in 0 ..< lw {
				p := argb[y * lw + x]
				o := row[x * 4:]
				o[0] = u8(p >> 16)
				o[1] = u8(p >> 8)
				o[2] = u8(p)
				o[3] = u8(p >> 24)
			}
		}
		return lw, lh, .None
	case "VP8 ":
		d := new(VP8_Dec, c.allocator)
		defer {
			delete(d.y, c.allocator);delete(d.u, c.allocator);delete(d.v, c.allocator)
			delete(d.intra_t, c.allocator);delete(d.nz_t, c.allocator);delete(d.finfo, c.allocator)
			free(d, c.allocator)
		}
		vp8_headers(d, b.data) or_return
		if d.w != want_w || d.h != want_h do return 0, 0, .Corrupt
		if d.w * d.h > c.max_pixels do return 0, 0, .Too_Large
		vp8_decode_frame(d, c.allocator) or_return
		vp8_to_rgba(d, dst, dst_stride)
		w, h = d.w, d.h
		if b.alph == nil {
			for y in 0 ..< h do for x in 0 ..< w do dst[y * dst_stride + x * 4 + 3] = 255
			return w, h, .None
		}
		if len(b.alph) < 1 do return 0, 0, .Corrupt
		hdr := b.alph[0]
		method := hdr & 3
		filter := (hdr >> 2) & 3
		if method > 1 || hdr >> 6 != 0 do return 0, 0, .Corrupt
		a := make([]u8, w * h, c.allocator)
		defer delete(a, c.allocator)
		if method == 0 {
			if len(b.alph) - 1 < w * h do return 0, 0, .Truncated
			copy(a, b.alph[1:])
		} else {
			argb, _, _, _ := vp8l_decode(b.alph[1:], c.allocator, c.max_pixels, false, w, h) or_return
			for p, i in argb do a[i] = u8(p >> 8)
			delete(argb, c.allocator)
		}
		unfilter_alpha(a, w, h, filter)
		for y in 0 ..< h do for x in 0 ..< w do dst[y * dst_stride + x * 4 + 3] = a[y * w + x]
		return w, h, .None
	}
	return 0, 0, .Corrupt
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

	switch first.fourcc {
	case "VP8 ", "VP8L":
		b := Webp_Bits{kind = first.fourcc, data = first.data}
		w, h, _, dok := bits_dims(b)
		if !dok do return .Corrupt
		check_size(c, w, h) or_return
		px := alloc_pixels(c, w, h) or_return
		if _, _, e := webp_decode_bits(c, b, w, h, px, w * 4); e != .None {
			delete(px, c.allocator)
			return e
		}
		img.width, img.height = w, h
		return push_frame(c, px, 0, true)
	case "VP8X":
	case:
		return .Corrupt
	}
	if len(first.data) < 10 do return .Truncated
	flags := first.data[0]
	cw := le24i(first.data[4:]) + 1
	chh := le24i(first.data[7:]) + 1
	check_size(c, cw, chh) or_return
	img.width, img.height = cw, chh

	if flags & 0x02 == 0 {
		// still image: optional ALPH then VP8/VP8L
		b: Webp_Bits
		for {
			ch, more := next_chunk(data, &pos) or_return
			if !more do return .Truncated
			if ch.fourcc == "ALPH" do b.alph = ch.data
			if ch.fourcc == "VP8 " || ch.fourcc == "VP8L" {
				b.kind = ch.fourcc
				b.data = ch.data
				if b.kind == "VP8L" do b.alph = nil
				break
			}
		}
		w, h, _, dok := bits_dims(b)
		if !dok do return .Corrupt
		if w != cw || h != chh do return .Corrupt
		px := alloc_pixels(c, w, h) or_return
		if _, _, e := webp_decode_bits(c, b, w, h, px, w * 4); e != .None {
			delete(px, c.allocator)
			return e
		}
		return push_frame(c, px, 0, true)
	}

	// animation
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
