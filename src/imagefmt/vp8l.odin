package imagefmt

// WebP lossless (VP8L, RFC 9649).

import "base:intrinsics"
import "core:mem"

// ---------------------------------------------------------------------------
// LSB-first bit reader; reading past the end yields zeros and sets overrun.

@(private)
LBits :: struct {
	data:  []byte,
	pos:   int,
	bits:  u64,
	nbits: u32,
}

@(private)
lb_fill :: #force_inline proc "contextless" (r: ^LBits) {
	if r.pos + 8 <= len(r.data) {
		v := u64(intrinsics.unaligned_load((^u64le)(raw_data(r.data)[r.pos:])))
		r.bits |= v << (r.nbits & 63)
		r.pos += int((63 - r.nbits) >> 3)
		r.nbits |= 56
	} else {
		for r.nbits <= 56 {
			b: u64
			if r.pos < len(r.data) do b = u64(r.data[r.pos])
			r.bits |= b << (r.nbits & 63)
			r.pos += 1
			r.nbits += 8
		}
	}
}

@(private)
lb_read :: #force_inline proc "contextless" (r: ^LBits, n: u32) -> u32 {
	if r.nbits < n do lb_fill(r)
	v := u32(r.bits & ((u64(1) << (n & 63)) - 1))
	r.bits >>= n & 63
	r.nbits -= n
	return v
}

@(private)
lb_overrun :: #force_inline proc "contextless" (r: ^LBits) -> bool {
	return r.pos * 8 - int(r.nbits) > len(r.data) * 8
}

// ---------------------------------------------------------------------------
// Prefix codes: entry = value | bits << 16; 8-bit root, absolute subtable offsets.

@(private)
HROOT :: 8

@(private)
huff_sym :: #force_inline proc "contextless" (r: ^LBits, t: [^]u32) -> u32 #no_bounds_check {
	if r.nbits < 15 do lb_fill(r)
	e := t[r.bits & 0xFF]
	nb := e >> 16
	if nb > HROOT {
		r.bits >>= HROOT
		r.nbits -= HROOT
		e = t[(e & 0xFFFF) + u32(r.bits & ((u64(1) << (nb - HROOT)) - 1))]
		nb = e >> 16
	}
	r.bits >>= nb
	r.nbits -= nb
	return e & 0xFFFF
}

@(private)
huff_next_key :: #force_inline proc "contextless" (key: u32, length: u32) -> u32 {
	step := u32(1) << (length - 1)
	for key & step != 0 do step >>= 1
	return (key & (step - 1)) + step
}

// Builds a canonical prefix-code table into out. A single used symbol becomes
// a zero-length code. Returns size, or 0 if the code is empty, incomplete or
// over-subscribed.
@(private)
huff_build :: proc(out: []u32, lengths: []u8, root: u32) -> int {
	count: [16]int
	for l in lengths do count[l] += 1
	count[0] = 0
	used := 0
	for l in 1 ..= 15 do used += count[l]
	root_size := 1 << root
	if len(out) < root_size do return 0
	if used == 0 do return 0
	if used == 1 {
		for l, s in lengths do if l != 0 do for i in 0 ..< root_size do out[i] = u32(s)
		return root_size
	}
	// completeness (Kraft)
	left := 1
	for l in 1 ..= 15 {
		left <<= 1
		left -= count[l]
		if left < 0 do return 0
	}
	if left != 0 do return 0

	offs: [17]int
	for l in 1 ..= 15 do offs[l + 1] = offs[l] + count[l]
	sorted: [2400]u16
	if used > len(sorted) do return 0
	for l, s in lengths {
		if l != 0 {
			sorted[offs[l]] = u16(s)
			offs[l] += 1
		}
	}
	key: u32
	si := 0
	for length in 1 ..= root {
		for _ in 0 ..< count[length] {
			e := u32(sorted[si]) | length << 16
			si += 1
			for k := int(key); k < root_size; k += 1 << length do out[k] = e
			key = huff_next_key(key, length)
		}
	}
	total := root_size
	mask := u32(root_size - 1)
	sub_low := ~u32(0)
	sub_start, sub_size := 0, 0
	for length in root + 1 ..= 15 {
		for count[length] > 0 {
			low := key & mask
			if low != sub_low {
				l := int(length)
				lft := 1 << (u32(l) - root)
				for l < 15 {
					lft -= count[l]
					if lft <= 0 do break
					l += 1
					lft <<= 1
				}
				sub_bits := u32(l) - root
				sub_start = total
				sub_size = 1 << sub_bits
				total += sub_size
				if total > len(out) do return 0
				out[low] = u32(sub_start) | (sub_bits + root) << 16
				sub_low = low
			}
			e := u32(sorted[si]) | (length - root) << 16
			si += 1
			for k := int(key >> root); k < sub_size; k += 1 << (length - root) do out[sub_start + k] = e
			key = huff_next_key(key, length)
			count[length] -= 1
		}
	}
	return total
}

// ---------------------------------------------------------------------------

@(private)
L_Group :: struct {
	t: [5]int, // offsets into L_Dec.tables: green, red, blue, alpha, distance
}

@(private)
L_Transform :: struct {
	type:  u32,
	bits:  u32,
	xsize: int,
	ysize: int,
	data:  []u32,
}

@(private)
L_Dec :: struct {
	br:         LBits,
	allocator:  mem.Allocator,
	transforms: [4]L_Transform,
	ntrans:     int,
	seen:       u32,
	max_pixels: int,
	lengths:    [256 + 24 + 2048]u8,
	scratch:    [4096]u32,
}

@(private)
CODE_LENGTH_ORDER_L := [19]u8{17, 18, 0, 1, 2, 3, 4, 5, 16, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15}

@(private)
l_read_code :: proc(d: ^L_Dec, alphabet: int, tables: ^[dynamic]u32) -> (int, Error) {
	br := &d.br
	lengths := d.lengths[:alphabet]
	for &l in lengths do l = 0
	if lb_read(br, 1) == 1 {
		nsym := lb_read(br, 1) + 1
		first_bits := lb_read(br, 1) == 0 ? u32(1) : u32(8)
		s := int(lb_read(br, first_bits))
		if s < alphabet do lengths[s] = 1
		if nsym == 2 {
			s = int(lb_read(br, 8))
			if s < alphabet do lengths[s] = 1
		}
	} else {
		cl: [19]u8
		n := int(lb_read(br, 4)) + 4
		for i in 0 ..< n do cl[CODE_LENGTH_ORDER_L[i]] = u8(lb_read(br, 3))
		clt: [128]u32
		if huff_build(clt[:], cl[:], 7) == 0 do return 0, .Corrupt
		max_symbol := alphabet
		if lb_read(br, 1) == 1 {
			nb := 2 + 2 * lb_read(br, 3)
			max_symbol = 2 + int(lb_read(br, nb))
			if max_symbol > alphabet do return 0, .Corrupt
		}
		sym := 0
		prev := u8(8)
		for sym < alphabet {
			if max_symbol == 0 do break
			max_symbol -= 1
			if br.nbits < 7 do lb_fill(br)
			e := clt[br.bits & 127]
			br.bits >>= e >> 16
			br.nbits -= e >> 16
			cl_sym := u8(e & 0xFFFF)
			if cl_sym < 16 {
				lengths[sym] = cl_sym
				sym += 1
				if cl_sym != 0 do prev = cl_sym
			} else {
				EXTRA := [3]u32{2, 3, 7}
				OFF := [3]int{3, 3, 11}
				slot := cl_sym - 16
				rep := int(lb_read(br, EXTRA[slot])) + OFF[slot]
				if sym + rep > alphabet do return 0, .Corrupt
				v := cl_sym == 16 ? prev : 0
				for k in 0 ..< rep do lengths[sym + k] = v
				sym += rep
			}
			if lb_overrun(br) do return 0, .Truncated
		}
	}
	if lb_overrun(br) do return 0, .Truncated
	size := huff_build(d.scratch[:], lengths, HROOT)
	if size == 0 do return 0, .Corrupt
	if tables == nil do return 0, .None // unused group: parse and discard
	off := len(tables)
	append(tables, ..d.scratch[:size])
	return off, .None
}

@(private)
subsample :: #force_inline proc "contextless" (size: int, bits: u32) -> int {
	return (size + (1 << bits) - 1) >> bits
}

// Decodes an entropy-coded image of xsize*ysize ARGB pixels. Level 0 (the main
// image) may have transforms and meta prefix codes.
@(private)
l_decode_stream :: proc(d: ^L_Dec, xsize, ysize: int, level0: bool) -> (out: []u32, out_xsize: int, err: Error) {
	br := &d.br
	tx := xsize
	if level0 {
		for lb_read(br, 1) == 1 {
			if d.ntrans >= 4 do return nil, 0, .Corrupt
			typ := lb_read(br, 2)
			if d.seen & (1 << typ) != 0 do return nil, 0, .Corrupt
			d.seen |= 1 << typ
			t := &d.transforms[d.ntrans]
			d.ntrans += 1
			t^ = {type = typ, xsize = tx, ysize = ysize}
			switch typ {
			case 0, 1:
				t.bits = lb_read(br, 3) + 2
				t.data, _ = l_decode_stream(d, subsample(tx, t.bits), subsample(ysize, t.bits), false) or_return
			case 3:
				ncolors := int(lb_read(br, 8)) + 1
				t.bits = ncolors > 16 ? 0 : ncolors > 4 ? 1 : ncolors > 2 ? 2 : 3
				pal, _ := l_decode_stream(d, ncolors, 1, false) or_return
				defer delete(pal, d.allocator)
				full := make([]u32, 1 << (8 >> t.bits), d.allocator)
				if len(full) < ncolors do return nil, 0, .Corrupt
				// delta-coded palette
				prev: u32
				for i in 0 ..< ncolors {
					prev = add_pixels(pal[i], prev)
					full[i] = prev
				}
				t.data = full
				tx = subsample(tx, t.bits)
			case 2:
			}
			if lb_overrun(br) do return nil, 0, .Truncated
		}
	}
	cache_bits: u32
	if lb_read(br, 1) == 1 {
		cache_bits = lb_read(br, 4)
		if cache_bits < 1 || cache_bits > 11 do return nil, 0, .Corrupt
	}
	meta: []u32
	meta_bits: u32
	meta_xsize := 0
	ngroups := 1
	defer if meta != nil do delete(meta, d.allocator)
	if level0 && lb_read(br, 1) == 1 {
		meta_bits = lb_read(br, 3) + 2
		meta_xsize = subsample(tx, meta_bits)
		meta, _ = l_decode_stream(d, meta_xsize, subsample(ysize, meta_bits), false) or_return
		for &m in meta {
			m = (m >> 8) & 0xFFFF
			ngroups = max(ngroups, int(m) + 1)
		}
	}
	// Only groups referenced by the meta image get tables; others are parsed and dropped.
	used := make([]bool, ngroups, d.allocator)
	defer delete(used, d.allocator)
	if meta == nil do used[0] = true
	for m in meta do used[m] = true
	tables := make([dynamic]u32, d.allocator)
	defer delete(tables)
	groups := make([]L_Group, ngroups, d.allocator)
	defer delete(groups, d.allocator)
	cache_size := cache_bits > 0 ? 1 << cache_bits : 0
	ALPHA := [5]int{256 + 24, 256, 256, 256, 40}
	for gi in 0 ..< ngroups {
		for k in 0 ..< 5 {
			a := ALPHA[k]
			if k == 0 do a += cache_size
			groups[gi].t[k] = l_read_code(d, a, used[gi] ? &tables : nil) or_return
		}
	}
	if tx * ysize > d.max_pixels do return nil, 0, .Too_Large
	out = make([]u32, tx * ysize, d.allocator)
	if e := l_decode_pixels(d, out, tx, ysize, cache_bits, groups, tables[:], meta, meta_bits, meta_xsize); e != .None {
		delete(out, d.allocator)
		return nil, 0, e
	}
	return out, tx, .None
}

@(private)
prefix_value :: #force_inline proc "contextless" (br: ^LBits, sym: u32) -> int {
	if sym < 4 do return int(sym) + 1
	extra := (sym - 2) >> 1
	offset := (2 + (sym & 1)) << extra
	return int(offset + lb_read(br, extra)) + 1
}

@(private)
l_decode_pixels :: proc(d: ^L_Dec, out: []u32, w, h: int, cache_bits: u32, groups: []L_Group, tables: []u32, meta: []u32, meta_bits: u32, meta_xsize: int) -> Error #no_bounds_check {
	br := &d.br
	cache: [2048]u32
	cshift := 32 - cache_bits
	n := w * h
	i, x, y := 0, 0, 0
	tb := raw_data(tables)
	g := groups[0]
	for i < n {
		if meta != nil do g = groups[meta[(y >> meta_bits) * meta_xsize + (x >> meta_bits)]]
		s := huff_sym(br, tb[g.t[0]:])
		if s < 256 {
			r := huff_sym(br, tb[g.t[1]:])
			lb_fill(br)
			b := huff_sym(br, tb[g.t[2]:])
			a := huff_sym(br, tb[g.t[3]:])
			px := a << 24 | r << 16 | s << 8 | b
			out[i] = px
			if cache_bits > 0 do cache[(0x1e35a7bd * px) >> cshift] = px
			i += 1
			x += 1
			if x == w {
				x = 0
				y += 1
				if lb_overrun(br) do return .Truncated
			}
		} else if s < 280 {
			length := prefix_value(br, s - 256)
			lb_fill(br)
			ds := huff_sym(br, tb[g.t[4]:])
			lb_fill(br)
			dcode := prefix_value(br, ds)
			dist: int
			if dcode > 120 {
				dist = dcode - 120
			} else {
				pc := int(VP8L_CODE_TO_PLANE[dcode - 1])
				dist = (pc >> 4) * w + 8 - (pc & 0xF)
				if dist < 1 do dist = 1
			}
			if dist > i || length > n - i do return .Corrupt
			for k in 0 ..< length {
				px := out[i + k - dist]
				out[i + k] = px
				if cache_bits > 0 do cache[(0x1e35a7bd * px) >> cshift] = px
			}
			i += length
			x += length
			for x >= w {
				x -= w
				y += 1
			}
			if lb_overrun(br) do return .Truncated
		} else {
			idx := s - 280
			if cache_bits == 0 || idx >= 1 << cache_bits do return .Corrupt
			px := cache[idx]
			out[i] = px
			cache[(0x1e35a7bd * px) >> cshift] = px
			i += 1
			x += 1
			if x == w {
				x = 0
				y += 1
			}
		}
	}
	if lb_overrun(br) do return .Truncated
	return .None
}

// ---------------------------------------------------------------------------
// Inverse transforms

@(private)
add_pixels :: #force_inline proc "contextless" (a, b: u32) -> u32 {
	ag := (a & 0xFF00FF00) + (b & 0xFF00FF00)
	rb := (a & 0x00FF00FF) + (b & 0x00FF00FF)
	return (ag & 0xFF00FF00) | (rb & 0x00FF00FF)
}

@(private)
avg2 :: #force_inline proc "contextless" (a, b: u32) -> u32 {
	return (((a ~ b) & 0xFEFEFEFE) >> 1) + (a & b)
}

@(private)
clip255 :: #force_inline proc "contextless" (a: u32) -> u32 {
	if a < 256 do return a
	return ~a >> 24
}

@(private)
predict :: #force_inline proc "contextless" (mode: u32, left: u32, top: [^]u32) -> u32 {
	switch mode {
	case 1:
		return left
	case 2:
		return top[0]
	case 3:
		return top[1]
	case 4:
		return top[-1]
	case 5:
		return avg2(avg2(left, top[1]), top[0])
	case 6:
		return avg2(left, top[-1])
	case 7:
		return avg2(left, top[0])
	case 8:
		return avg2(top[-1], top[0])
	case 9:
		return avg2(top[0], top[1])
	case 10:
		return avg2(avg2(left, top[-1]), avg2(top[0], top[1]))
	case 11:
		t, l, c := top[0], left, top[-1]
		pa_minus_pb: i32
		for sh := u32(0); sh < 32; sh += 8 {
			tv := i32((t >> sh) & 0xFF)
			lv := i32((l >> sh) & 0xFF)
			cv := i32((c >> sh) & 0xFF)
			pa_minus_pb += abs(lv - cv) - abs(tv - cv)
		}
		return pa_minus_pb <= 0 ? t : l
	case 12:
		r: u32
		for sh := u32(0); sh < 32; sh += 8 {
			v := ((left >> sh) & 0xFF) + ((top[0] >> sh) & 0xFF) - ((top[-1] >> sh) & 0xFF)
			r |= clip255(v) << sh
		}
		return r
	case 13:
		ave := avg2(left, top[0])
		r: u32
		for sh := u32(0); sh < 32; sh += 8 {
			a := i32((ave >> sh) & 0xFF)
			b := i32((top[-1] >> sh) & 0xFF)
			r |= clip255(u32(a + (a - b) / 2)) << sh
		}
		return r
	}
	return 0xFF000000
}

@(private)
inv_predictor :: proc(t: ^L_Transform, px: []u32) #no_bounds_check {
	w, h := t.xsize, t.ysize
	p := raw_data(px)
	p[0] = add_pixels(p[0], 0xFF000000)
	for x in 1 ..< w do p[x] = add_pixels(p[x], p[x - 1])
	tiles := subsample(w, t.bits)
	for y in 1 ..< h {
		row := p[y * w:]
		top := p[(y - 1) * w:]
		row[0] = add_pixels(row[0], top[0])
		modes := t.data[(y >> t.bits) * tiles:]
		x := 1
		for x < w {
			mode := (modes[x >> t.bits] >> 8) & 0xF
			xe := min((x & ~((1 << t.bits) - 1)) + (1 << t.bits), w)
			switch mode {
			case 1:
				l := row[x - 1]
				for ; x < xe; x += 1 {
					l = add_pixels(row[x], l)
					row[x] = l
				}
			case 2:
				for ; x < xe; x += 1 do row[x] = add_pixels(row[x], top[x])
			case:
				for ; x < xe; x += 1 do row[x] = add_pixels(row[x], predict(mode, row[x - 1], top[x:]))
			}
		}
	}
}

@(private)
inv_color :: proc(t: ^L_Transform, px: []u32) #no_bounds_check {
	w, h := t.xsize, t.ysize
	tiles := subsample(w, t.bits)
	for y in 0 ..< h {
		row := px[y * w:]
		codes := t.data[(y >> t.bits) * tiles:]
		for x in 0 ..< w {
			c := codes[x >> t.bits]
			g2r := i32(i8(c & 0xFF))
			g2b := i32(i8((c >> 8) & 0xFF))
			r2b := i32(i8((c >> 16) & 0xFF))
			a := row[x]
			green := i32(i8((a >> 8) & 0xFF))
			nr := i32((a >> 16) & 0xFF) + ((g2r * green) >> 5)
			nr &= 0xFF
			nb := i32(a & 0xFF) + ((g2b * green) >> 5) + ((r2b * i32(i8(u8(nr)))) >> 5)
			nb &= 0xFF
			row[x] = (a & 0xFF00FF00) | u32(nr) << 16 | u32(nb)
		}
	}
}

@(private)
inv_subtract_green :: proc(px: []u32) {
	for &a in px {
		g := (a >> 8) & 0xFF
		rb := ((a & 0x00FF00FF) + (g << 16 | g)) & 0x00FF00FF
		a = (a & 0xFF00FF00) | rb
	}
}

@(private)
inv_color_index :: proc(t: ^L_Transform, src: []u32, packed_w: int, dst: []u32) #no_bounds_check {
	w, h := t.xsize, t.ysize
	pal := t.data
	if t.bits == 0 {
		for i in 0 ..< w * h do dst[i] = pal[(src[i] >> 8) & 0xFF]
		return
	}
	bpp := u32(8) >> t.bits
	cmask := (1 << t.bits) - 1
	bmask := (u32(1) << bpp) - 1
	for y in 0 ..< h {
		s := src[y * packed_w:]
		dr := dst[y * w:]
		packed: u32
		si := 0
		for x in 0 ..< w {
			if x & cmask == 0 {
				packed = (s[si] >> 8) & 0xFF
				si += 1
			}
			dr[x] = pal[packed & bmask]
			packed >>= bpp
		}
	}
}

// Decodes a VP8L bitstream. With header=false (ALPH chunk), w and h are given.
@(private)
vp8l_decode :: proc(data: []byte, allocator: mem.Allocator, max_pixels: int, header := true, aw := 0, ah := 0) -> (argb: []u32, w, h: int, has_alpha: bool, err: Error) {
	d := new(L_Dec, allocator)
	defer free(d, allocator)
	d.allocator = allocator
	d.max_pixels = max_pixels
	d.br.data = data
	if header {
		if len(data) < 5 || data[0] != 0x2F do return nil, 0, 0, false, .Corrupt
		d.br.pos = 1
		w = int(lb_read(&d.br, 14)) + 1
		h = int(lb_read(&d.br, 14)) + 1
		has_alpha = lb_read(&d.br, 1) == 1
		if lb_read(&d.br, 3) != 0 do return nil, 0, 0, false, .Unsupported
	} else {
		w, h = aw, ah
	}
	if w * h > max_pixels do return nil, 0, 0, false, .Too_Large
	defer for i in 0 ..< d.ntrans do delete(d.transforms[i].data, allocator)
	px, pw := l_decode_stream(d, w, h, true) or_return
	for i := d.ntrans - 1; i >= 0; i -= 1 {
		t := &d.transforms[i]
		switch t.type {
		case 0:
			inv_predictor(t, px)
		case 1:
			inv_color(t, px)
		case 2:
			inv_subtract_green(px)
		case 3:
			full := make([]u32, t.xsize * t.ysize, allocator)
			inv_color_index(t, px, pw, full)
			delete(px, allocator)
			px = full
			pw = t.xsize
		}
	}
	return px, w, h, has_alpha, .None
}
