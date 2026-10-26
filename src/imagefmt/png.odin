package imagefmt

// PNG + APNG (own inflate in inflate.odin); filtering, interlace,
// all colour types / bit depths, tRNS and APNG compositing are here.
// CRCs are not checked (browsers tolerate bad CRCs); 16-bit samples are
// rounded to 8 bits.

import "core:mem"

@(private)
Png_Hdr :: struct {
	w, h:      int,
	depth:     int,
	ctype:     int,
	interlace: bool,
	plte:      []byte,
	trns:      []byte,
}

@(private)
png_channels :: proc(ctype: int) -> int {
	switch ctype {
	case 0, 3: return 1
	case 2: return 3
	case 4: return 2
	case 6: return 4
	}
	return 0
}

@(private)
png_unfilter :: proc(cur, prev: []u8, bpp: int, ft: u8) -> bool #no_bounds_check {
	n := len(cur)
	switch ft {
	case 0:
	case 1:
		for i in bpp ..< n do cur[i] += cur[i - bpp]
	case 2:
		for i in 0 ..< n do cur[i] += prev[i]
	case 3:
		for i in 0 ..< bpp do cur[i] += prev[i] >> 1
		for i in bpp ..< n do cur[i] += u8((int(cur[i - bpp]) + int(prev[i])) >> 1)
	case 4:
		for i in 0 ..< bpp do cur[i] += prev[i]
		for i in bpp ..< n {
			a, b, c := int(cur[i - bpp]), int(prev[i]), int(prev[i - bpp])
			p := a + b - c
			pa, pb, pc := abs(p - a), abs(p - b), abs(p - c)
			pr := pa <= pb && pa <= pc ? a : pb <= pc ? b : c
			cur[i] += u8(pr)
		}
	case:
		return false
	}
	return true
}

// Converts one unfiltered scanline of w pixels into RGBA at dst[x*xstep].
@(private)
png_emit_row :: proc(h: ^Png_Hdr, src: []u8, w: int, dst: []u8, xstart, xstep: int) #no_bounds_check {
	d := h.depth
	s16 :: #force_inline proc "contextless" (p: []u8, i: int) -> u8 {
		v := u32(p[2 * i]) << 8 | u32(p[2 * i + 1])
		return u8((v * 255 + 32895) >> 16)
	}
	raw16 :: #force_inline proc "contextless" (p: []u8, i: int) -> int {return int(p[2 * i]) << 8 | int(p[2 * i + 1])}
	// fast paths for the common 8-bit layouts
	if d == 8 && (xstep == 1 || h.ctype == 3) {
		switch h.ctype {
		case 6:
			if xstep == 1 {
				copy(dst[xstart * 4:][:w * 4], src[:w * 4])
				return
			}
		case 2:
			if xstep == 1 && len(h.trns) < 6 {
				o := dst[xstart * 4:]
				for x in 0 ..< w {
					o[4 * x], o[4 * x + 1], o[4 * x + 2], o[4 * x + 3] = src[3 * x], src[3 * x + 1], src[3 * x + 2], 255
				}
				return
			}
		case 3:
			lut: [256][4]u8
			for i in 0 ..< 256 {
				if i * 3 + 2 < len(h.plte) do lut[i] = {h.plte[i * 3], h.plte[i * 3 + 1], h.plte[i * 3 + 2], 255}
				else do lut[i] = {0, 0, 0, 255}
				if i < len(h.trns) do lut[i][3] = h.trns[i]
			}
			for x in 0 ..< w do (^[4]u8)(&dst[(xstart + x * xstep) * 4])^ = lut[src[x]]
			return
		}
	}
	for x in 0 ..< w {
		o := dst[(xstart + x * xstep) * 4:]
		switch h.ctype {
		case 0, 3:
			v: int
			if d == 16 {
				v = raw16(src, x)
			} else if d == 8 {
				v = int(src[x])
			} else {
				per := 8 / d
				v = int(src[x / per] >> uint(8 - d - (x % per) * d)) & ((1 << uint(d)) - 1)
			}
			if h.ctype == 3 {
				if v * 3 + 2 < len(h.plte) {
					o[0], o[1], o[2] = h.plte[v * 3], h.plte[v * 3 + 1], h.plte[v * 3 + 2]
				} else {
					o[0], o[1], o[2] = 0, 0, 0
				}
				o[3] = v < len(h.trns) ? h.trns[v] : 255
			} else {
				g: u8
				switch d {
				case 16: g = s16(src, x)
				case 8: g = u8(v)
				case 4: g = u8(v * 17)
				case 2: g = u8(v * 85)
				case 1: g = u8(v * 255)
				}
				o[0], o[1], o[2] = g, g, g
				o[3] = 255
				if len(h.trns) >= 2 && v == (int(h.trns[0]) << 8 | int(h.trns[1])) do o[3] = 0
			}
		case 2:
			if d == 8 {
				o[0], o[1], o[2], o[3] = src[3 * x], src[3 * x + 1], src[3 * x + 2], 255
				if len(h.trns) >= 6 && int(src[3 * x]) == be16(h.trns[0:]) && int(src[3 * x + 1]) == be16(h.trns[2:]) && int(src[3 * x + 2]) == be16(h.trns[4:]) do o[3] = 0
			} else {
				o[0], o[1], o[2], o[3] = s16(src, 3 * x), s16(src, 3 * x + 1), s16(src, 3 * x + 2), 255
				if len(h.trns) >= 6 && raw16(src, 3 * x) == be16(h.trns[0:]) && raw16(src, 3 * x + 1) == be16(h.trns[2:]) && raw16(src, 3 * x + 2) == be16(h.trns[4:]) do o[3] = 0
			}
		case 4:
			if d == 8 {
				g := src[2 * x]
				o[0], o[1], o[2], o[3] = g, g, g, src[2 * x + 1]
			} else {
				g := s16(src, 2 * x)
				o[0], o[1], o[2], o[3] = g, g, g, s16(src, 2 * x + 1)
			}
		case 6:
			if d == 8 {
				o[0], o[1], o[2], o[3] = src[4 * x], src[4 * x + 1], src[4 * x + 2], src[4 * x + 3]
			} else {
				o[0], o[1], o[2], o[3] = s16(src, 4 * x), s16(src, 4 * x + 1), s16(src, 4 * x + 2), s16(src, 4 * x + 3)
			}
		}
	}
}

// Decodes a zlib stream of w*h pixels (header fields from h) into RGBA.
@(private)
png_decode_image :: proc(c: ^Decode_Ctx, h: ^Png_Hdr, zdata: []byte, w, ht: int) -> (pixels: []u8, err: Error) {
	ch := png_channels(h.ctype)
	bpp_bits := ch * h.depth
	bpp := max(1, bpp_bits / 8)
	stride :: proc(w, bits: int) -> int {return (w * bits + 7) / 8}
	PX := [7]int{0, 4, 0, 2, 0, 1, 0}
	PY := [7]int{0, 0, 4, 0, 2, 0, 1}
	SX := [7]int{8, 8, 4, 4, 2, 2, 1}
	SY := [7]int{8, 8, 8, 4, 4, 2, 2}
	npass := h.interlace ? 7 : 1
	expected := 0
	for pi in 0 ..< npass {
		pw, ph := w, ht
		if h.interlace {
			pw = (w - PX[pi] + SX[pi] - 1) / SX[pi]
			ph = (ht - PY[pi] + SY[pi] - 1) / SY[pi]
		}
		if pw > 0 && ph > 0 do expected += ph * (1 + stride(pw, bpp_bits))
	}
	raw := make([]u8, expected + 8, c.allocator)
	defer delete(raw, c.allocator)
	got, ierr := inflate_zlib(zdata, raw[:expected])
	// tolerate a bad tail if the image data itself is complete
	if got < expected do return nil, ierr == .None ? .Truncated : ierr
	out := alloc_pixels(c, w, ht) or_return
	prev := make([]u8, stride(w, bpp_bits) + 1, c.allocator)
	defer delete(prev, c.allocator)
	pos := 0
	for pi in 0 ..< npass {
		pw, ph := w, ht
		x0, y0, xs, ys := 0, 0, 1, 1
		if h.interlace {
			x0, y0, xs, ys = PX[pi], PY[pi], SX[pi], SY[pi]
			pw = (w - x0 + xs - 1) / xs
			ph = (ht - y0 + ys - 1) / ys
		}
		if pw <= 0 || ph <= 0 do continue
		sl := stride(pw, bpp_bits)
		mem.zero_slice(prev)
		for r in 0 ..< ph {
			ft := raw[pos]
			cur := raw[pos + 1:pos + 1 + sl]
			pos += 1 + sl
			if !png_unfilter(cur, prev[:sl], bpp, ft) {
				delete(out, c.allocator)
				return nil, .Corrupt
			}
			copy(prev, cur)
			png_emit_row(h, cur, pw, out[(y0 + r * ys) * w * 4:], x0, xs)
		}
	}
	return out, .None
}

@(private)
Apng_Frame :: struct {
	w, h, x, y:  int,
	delay_ms:    int,
	dispose:     u8,
	blend:       u8,
	data:        [dynamic]byte, // concatenated IDAT/fdAT payloads
}

@(private)
png_decode :: proc(c: ^Decode_Ctx, data: []byte, img: ^Image) -> Error {
	p := 8
	h: Png_Hdr
	have_hdr := false
	idat := make([dynamic]byte, c.allocator)
	defer delete(idat)
	frames := make([dynamic]Apng_Frame, c.allocator)
	defer {
		for f in frames do delete(f.data)
		delete(frames)
	}
	actl := false
	num_plays := 0
	default_is_frame := false
	seen_idat := false
	loop: for p + 8 <= len(data) {
		n := be32(data[p:])
		typ := string(data[p + 4:p + 8])
		if n < 0 || p + 12 + n > len(data) {
			if typ == "IDAT" || typ == "fdAT" {
				n = len(data) - p - 8 // truncated final data chunk: use what is there
			} else {
				break
			}
		}
		cd := data[p + 8:p + 8 + n]
		p += 12 + n
		switch typ {
		case "IHDR":
			if n < 13 || have_hdr do return .Corrupt
			h.w, h.h = be32(cd), be32(cd[4:])
			h.depth, h.ctype = int(cd[8]), int(cd[9])
			h.interlace = cd[12] == 1
			if cd[10] != 0 || cd[11] != 0 || cd[12] > 1 do return .Unsupported
			ok := false
			switch h.ctype {
			case 0: ok = h.depth == 1 || h.depth == 2 || h.depth == 4 || h.depth == 8 || h.depth == 16
			case 3: ok = h.depth == 1 || h.depth == 2 || h.depth == 4 || h.depth == 8
			case 2, 4, 6: ok = h.depth == 8 || h.depth == 16
			}
			if !ok do return .Corrupt
			check_size(c, h.w, h.h) or_return
			have_hdr = true
		case "PLTE":
			h.plte = cd
		case "tRNS":
			h.trns = cd
		case "acTL":
			if n >= 8 && !seen_idat {
				actl = true
				num_plays = be32(cd[4:])
			}
		case "fcTL":
			if n < 26 || !have_hdr do return .Corrupt
			f := Apng_Frame {
				w       = be32(cd[4:]),
				h       = be32(cd[8:]),
				x       = be32(cd[12:]),
				y       = be32(cd[16:]),
				dispose = cd[24],
				blend   = cd[25],
			}
			num, den := be16(cd[20:]), be16(cd[22:])
			if den == 0 do den = 100
			f.delay_ms = num * 1000 / den
			if f.w <= 0 || f.h <= 0 || f.x < 0 || f.y < 0 || f.x + f.w > h.w || f.y + f.h > h.h do return .Corrupt
			if !seen_idat do default_is_frame = true
			f.data = make([dynamic]byte, c.allocator)
			append(&frames, f)
		case "IDAT":
			if !have_hdr do return .Corrupt
			seen_idat = true
			append(&idat, ..cd)
		case "fdAT":
			if len(frames) > 0 && n >= 4 && seen_idat do append(&frames[len(frames) - 1].data, ..cd[4:])
		case "IEND":
			break loop
		}
	}
	if !have_hdr do return .Corrupt
	img.width, img.height = h.w, h.h
	img.loop_count = 1
	animated := actl && len(frames) > 0
	if !animated || c.first_only && default_is_frame {
		px := png_decode_image(c, &h, idat[:], h.w, h.h) or_return
		return push_frame(c, px, animated ? frames[0].delay_ms : 0, true)
	}
	img.loop_count = num_plays
	if default_is_frame do append(&frames[0].data, ..idat[:])

	canvas := alloc_pixels(c, h.w, h.h) or_return
	defer delete(canvas, c.allocator)
	saved := alloc_pixels(c, h.w, h.h) or_return
	defer delete(saved, c.allocator)
	stride := h.w * 4
	for &f, i in frames {
		if len(f.data) == 0 {
			if len(c.frames) > 0 do break
			return .Truncated
		}
		px, e := png_decode_image(c, &h, f.data[:], f.w, f.h)
		if e != .None {
			if len(c.frames) > 0 do break // keep the frames decoded so far
			return e
		}
		dispose := f.dispose
		if i == 0 && dispose == 2 do dispose = 1
		if dispose == 2 do copy(saved, canvas)
		for y in 0 ..< f.h {
			row := canvas[(f.y + y) * stride + f.x * 4:]
			src := px[y * f.w * 4:]
			if f.blend == 0 || i == 0 {
				copy(row[:f.w * 4], src[:f.w * 4])
			} else {
				for x in 0 ..< f.w {
					sp := (^[4]u8)(&src[x * 4])^
					dp := (^[4]u8)(&row[x * 4])
					if sp[3] == 0 {
						// keep dst
					} else if sp[3] == 255 || dp[3] == 0 {
						dp^ = sp
					} else {
						dp^ = blend_over(sp, dp^)
					}
				}
			}
		}
		delete(px, c.allocator)
		push_frame(c, canvas, f.delay_ms) or_return
		if c.first_only do break
		switch dispose {
		case 1:
			for y in 0 ..< f.h do mem.zero_slice(canvas[(f.y + y) * stride + f.x * 4:][:f.w * 4])
		case 2:
			copy(canvas, saved)
		}
	}
	return .None
}
