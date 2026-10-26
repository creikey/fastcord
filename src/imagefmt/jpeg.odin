package imagefmt

// JPEG: baseline, extended and progressive Huffman (8-bit), restart markers,
// any sampling factors, grayscale / YCbCr / RGB / CMYK / YCCK, EXIF
// orientation. Output matches libjpeg-turbo's defaults: islow IDCT, "fancy"
// upsampling and its fixed-point YCbCr->RGB tables.

import "base:intrinsics"
import "core:mem"

@(private)
JZZ := [64]u8 {
	0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5,
	12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14, 21, 28,
	35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51,
	58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63,
}

@(private)
J_Huff :: struct {
	fast:    [512]u16, // len << 8 | symbol, len == 0: slow path
	maxcode: [18]i32,
	valptr:  [17]i32,
	mincode: [17]i32,
	vals:    [256]u8,
	ok:      bool,
}

@(private)
J_Comp :: struct {
	id, h, v, tq:   int,
	td, ta:         int,
	bw, bh:         int, // blocks, padded to MCU
	dw, dh:         int, // downsampled size in samples
	coeffs:         []i16,
	dc_pred:        i32,
	plane:          []u8, // bw*8 x bh*8
}

@(private)
J_Bits :: struct {
	data:   []byte,
	pos:    int,
	bits:   u64,
	nbits:  u32,
	marker: bool,
}

@(private)
jb_fill :: proc "contextless" (b: ^J_Bits) #no_bounds_check {
	if !b.marker && b.pos + 8 <= len(b.data) {
		v := u64(intrinsics.unaligned_load((^u64be)(raw_data(b.data)[b.pos:])))
		// no 0xFF byte in the next 8: take whole bytes at once
		x := ~v
		if (x - 0x0101010101010101) & ~x & 0x8080808080808080 == 0 {
			n := (64 - b.nbits) >> 3
			b.bits |= (v >> (64 - 8 * n)) << (64 - 8 * n - b.nbits)
			b.nbits += 8 * n
			b.pos += int(n)
			return
		}
	}
	for b.nbits <= 56 {
		v: u64
		if !b.marker && b.pos < len(b.data) {
			c := b.data[b.pos]
			if c == 0xFF {
				nx: u8 = b.pos + 1 < len(b.data) ? b.data[b.pos + 1] : 0xD9
				if nx == 0 {
					b.pos += 2
					v = 0xFF
				} else if nx == 0xFF {
					b.pos += 1 // fill byte
					continue
				} else {
					b.marker = true
				}
			} else {
				b.pos += 1
				v = u64(c)
			}
		}
		b.bits |= v << (56 - b.nbits)
		b.nbits += 8
	}
}

@(private)
jb_get :: #force_inline proc "contextless" (b: ^J_Bits, n: u32) -> i32 {
	if n == 0 do return 0
	if b.nbits < n do jb_fill(b)
	v := i32(b.bits >> (64 - n))
	b.bits <<= n
	b.nbits -= n
	return v
}

@(private)
jb_extend :: #force_inline proc "contextless" (v: i32, s: u32) -> i32 {
	return v < (1 << (s - 1)) ? v - (1 << s) + 1 : v
}

@(private)
jb_huff :: #force_inline proc "contextless" (b: ^J_Bits, t: ^J_Huff) -> i32 #no_bounds_check {
	if b.nbits < 16 do jb_fill(b)
	e := t.fast[b.bits >> 55]
	if e >> 8 != 0 {
		l := u32(e >> 8)
		b.bits <<= l
		b.nbits -= l
		return i32(e & 0xFF)
	}
	code := i32(b.bits >> 48)
	for l in u32(10) ..= 16 {
		c := code >> (16 - l)
		if c <= t.maxcode[l] {
			b.bits <<= l
			b.nbits -= l
			idx := t.valptr[l] + c - t.mincode[l]
			return idx >= 0 && idx < 256 ? i32(t.vals[idx]) : 0
		}
	}
	b.bits <<= 16
	b.nbits -= 16
	return 0
}

@(private)
build_jhuff :: proc(t: ^J_Huff, counts: []u8, vals: []u8) -> bool {
	t^ = {}
	copy(t.vals[:], vals)
	code: i32
	k: i32
	for l in 1 ..= 16 {
		n := i32(counts[l - 1])
		t.valptr[l] = k
		t.mincode[l] = code
		if n > 0 {
			if code + n > i32(1) << u32(l) do return false // over-subscribed
			t.maxcode[l] = code + n - 1
			if l <= 9 {
				for i in 0 ..< n {
					c := code + i
					sh := u32(9 - l)
					for j in 0 ..< i32(1) << sh do t.fast[(c << sh) | j] = u16(l) << 8 | u16(vals[k + i])
				}
			}
		} else {
			t.maxcode[l] = -1
		}
		k += n
		code = (code + n) << 1
		if code > (1 << 17) do return false
	}
	t.maxcode[17] = max(i32)
	t.ok = true
	return true
}

@(private)
J_Dec :: struct {
	w, h:         int,
	ncomp:        int,
	comps:        [4]J_Comp,
	qt:           [4][64]u16,
	dc, ac:       [4]J_Huff,
	hmax, vmax:   int,
	mcux, mcuy:   int,
	progressive:  bool,
	restart:      int,
	eobrun:       int,
	adobe:        bool,
	transform:    int,
	orientation:  int,
	jfif:         bool,
	seen_sof:     bool,
}

@(private)
j_decode_block :: proc(d: ^J_Dec, b: ^J_Bits, c: ^J_Comp, blk: []i16, ss, se, ah, al: int) #no_bounds_check {
	if !d.progressive {
		t := jb_huff(b, &d.dc[c.td])
		if t > 0 do c.dc_pred += jb_extend(jb_get(b, u32(t)), u32(t))
		blk[0] = i16(c.dc_pred)
		at := &d.ac[c.ta]
		for k := 1; k < 64; {
			rs := jb_huff(b, at)
			r, s := int(rs >> 4), u32(rs & 15)
			if s == 0 {
				if r != 15 do break
				k += 16
				continue
			}
			k += r
			if k > 63 do break
			blk[JZZ[k]] = i16(jb_extend(jb_get(b, s), s))
			k += 1
		}
		return
	}
	if ss == 0 {
		if ah == 0 {
			t := jb_huff(b, &d.dc[c.td])
			if t > 0 do c.dc_pred += jb_extend(jb_get(b, u32(t)), u32(t))
			blk[0] = i16(c.dc_pred << u32(al))
		} else if jb_get(b, 1) == 1 {
			blk[0] |= i16(1 << u32(al))
		}
		return
	}
	at := &d.ac[c.ta]
	if ah == 0 {
		if d.eobrun > 0 {
			d.eobrun -= 1
			return
		}
		for k := ss; k <= se; k += 1 {
			rs := jb_huff(b, at)
			r, s := int(rs >> 4), u32(rs & 15)
			if s == 0 {
				if r < 15 {
					d.eobrun = (1 << u32(r)) - 1
					if r > 0 do d.eobrun += int(jb_get(b, u32(r)))
					break
				}
				k += 15
				continue
			}
			k += r
			if k > 63 do break
			blk[JZZ[k]] = i16(jb_extend(jb_get(b, s), s) << u32(al))
		}
		return
	}
	// AC refinement
	p1 := i16(1 << u32(al))
	m1 := i16(-1 << u32(al))
	k := ss
	if d.eobrun == 0 {
		for ; k <= se; k += 1 {
			rs := jb_huff(b, at)
			r, s := int(rs >> 4), int(rs & 15)
			sv: i16
			if s != 0 {
				sv = jb_get(b, 1) == 1 ? p1 : m1
			} else if r != 15 {
				d.eobrun = 1 << u32(r)
				if r > 0 do d.eobrun += int(jb_get(b, u32(r)))
				break
			}
			for k <= se {
				coef := &blk[JZZ[k]]
				if coef^ != 0 {
					if jb_get(b, 1) == 1 && coef^ & p1 == 0 {
						coef^ += coef^ >= 0 ? p1 : m1
					}
				} else {
					r -= 1
					if r < 0 do break
				}
				k += 1
			}
			if sv != 0 && k <= 63 do blk[JZZ[k]] = sv
		}
	}
	if d.eobrun > 0 {
		for ; k <= se; k += 1 {
			coef := &blk[JZZ[k]]
			if coef^ != 0 && jb_get(b, 1) == 1 && coef^ & p1 == 0 {
				coef^ += coef^ >= 0 ? p1 : m1
			}
		}
		d.eobrun -= 1
	}
}

// Decodes one scan starting at data[p]; returns position after the entropy data.
@(private)
j_scan :: proc(d: ^J_Dec, data: []byte, p: int, sc: []int, ss, se, ah, al: int) -> int {
	b := J_Bits{data = data, pos = p}
	d.eobrun = 0
	for ci in sc do d.comps[ci].dc_pred = 0
	single := len(sc) == 1
	nmcu: int
	bx, by: int
	if single {
		c := &d.comps[sc[0]]
		bx = (c.dw + 7) / 8
		by = (c.dh + 7) / 8
		nmcu = bx * by
	} else {
		nmcu = d.mcux * d.mcuy
	}
	for m in 0 ..< nmcu {
		if d.restart > 0 && m > 0 && m % d.restart == 0 {
			// expect RSTn: drop buffered bits, skip the marker
			b.bits, b.nbits = 0, 0
			for b.pos + 1 < len(data) && !(data[b.pos] == 0xFF && data[b.pos + 1] >= 0xD0 && data[b.pos + 1] <= 0xD7) {
				if data[b.pos] == 0xFF && data[b.pos + 1] != 0 && data[b.pos + 1] != 0xFF do break
				b.pos += 1
			}
			if b.pos + 1 < len(data) && data[b.pos] == 0xFF && data[b.pos + 1] >= 0xD0 && data[b.pos + 1] <= 0xD7 do b.pos += 2
			b.marker = false
			d.eobrun = 0
			for ci in sc do d.comps[ci].dc_pred = 0
		}
		if single {
			c := &d.comps[sc[0]]
			x, y := m % bx, m / bx
			blk := c.coeffs[(y * c.bw + x) * 64:][:64]
			j_decode_block(d, &b, c, blk, ss, se, ah, al)
		} else {
			mx, my := m % d.mcux, m / d.mcux
			for ci in sc {
				c := &d.comps[ci]
				for v in 0 ..< c.v {
					for h in 0 ..< c.h {
						x := mx * c.h + h
						y := my * c.v + v
						blk := c.coeffs[(y * c.bw + x) * 64:][:64]
						j_decode_block(d, &b, c, blk, ss, se, ah, al)
					}
				}
			}
		}
	}
	// resume at the next marker
	q := b.pos
	for q + 1 < len(data) {
		if data[q] == 0xFF && data[q + 1] != 0 && !(data[q + 1] >= 0xD0 && data[q + 1] <= 0xD7) && data[q + 1] != 0xFF do break
		q += 1
	}
	return q
}

// libjpeg jidctint.c (islow), output with +128 level shift and clamping.
@(private)
idct_islow :: proc "contextless" (inp: []i16, q: ^[64]u16, out: [^]u8, stride: int) #no_bounds_check {
	CB :: 13
	P1 :: 2
	F0298 :: 2446
	F0390 :: 3196
	F0541 :: 4433
	F0765 :: 6270
	F0899 :: 7373
	F1175 :: 9633
	F1501 :: 12299
	F1847 :: 15137
	F1961 :: 16069
	F2053 :: 16819
	F2562 :: 20995
	F3072 :: 25172
	{
		p := ([^]u64)(raw_data(inp))
		acc := p[0] & ~u64(0xFFFF)
		for i in 1 ..< 16 do acc |= p[i]
		if acc == 0 {
			x := ((i32(inp[0]) * i32(q[0])) * 4 + 16) >> 5 + 128
			v := x < 0 ? 0 : x > 255 ? 255 : u8(x)
			for r in 0 ..< 8 do mem.set(out[r * stride:], v, 8)
			return
		}
	}
	ws: [64]i32
	for col in 0 ..< 8 {
		DQ :: #force_inline proc "contextless" (inp: []i16, q: ^[64]u16, i: int) -> i32 {return i32(inp[i]) * i32(q[i])}
		if inp[8 + col] == 0 && inp[16 + col] == 0 && inp[24 + col] == 0 && inp[32 + col] == 0 && inp[40 + col] == 0 && inp[48 + col] == 0 && inp[56 + col] == 0 {
			dc := DQ(inp, q, col) << P1
			for r in 0 ..< 8 do ws[r * 8 + col] = dc
			continue
		}
		z2 := DQ(inp, q, 16 + col)
		z3 := DQ(inp, q, 48 + col)
		z1 := (z2 + z3) * F0541
		tmp2 := z1 + z3 * (-F1847)
		tmp3 := z1 + z2 * F0765
		z2 = DQ(inp, q, col)
		z3 = DQ(inp, q, 32 + col)
		tmp0 := (z2 + z3) << CB
		tmp1 := (z2 - z3) << CB
		tmp10 := tmp0 + tmp3
		tmp13 := tmp0 - tmp3
		tmp11 := tmp1 + tmp2
		tmp12 := tmp1 - tmp2
		tmp0 = DQ(inp, q, 56 + col)
		tmp1 = DQ(inp, q, 40 + col)
		tmp2 = DQ(inp, q, 24 + col)
		tmp3 = DQ(inp, q, 8 + col)
		z1 = tmp0 + tmp3
		z2 = tmp1 + tmp2
		z3 = tmp0 + tmp2
		z4 := tmp1 + tmp3
		z5 := (z3 + z4) * F1175
		tmp0 *= F0298
		tmp1 *= F2053
		tmp2 *= F3072
		tmp3 *= F1501
		z1 *= -F0899
		z2 *= -F2562
		z3 *= -F1961
		z4 *= -F0390
		z3 += z5
		z4 += z5
		tmp0 += z1 + z3
		tmp1 += z2 + z4
		tmp2 += z2 + z3
		tmp3 += z1 + z4
		S :: CB - P1
		R :: 1 << (S - 1)
		ws[0 * 8 + col] = (tmp10 + tmp3 + R) >> S
		ws[7 * 8 + col] = (tmp10 - tmp3 + R) >> S
		ws[1 * 8 + col] = (tmp11 + tmp2 + R) >> S
		ws[6 * 8 + col] = (tmp11 - tmp2 + R) >> S
		ws[2 * 8 + col] = (tmp12 + tmp1 + R) >> S
		ws[5 * 8 + col] = (tmp12 - tmp1 + R) >> S
		ws[3 * 8 + col] = (tmp13 + tmp0 + R) >> S
		ws[4 * 8 + col] = (tmp13 - tmp0 + R) >> S
	}
	clampb :: #force_inline proc "contextless" (v: i32) -> u8 {
		x := v + 128
		return x < 0 ? 0 : x > 255 ? 255 : u8(x)
	}
	for row in 0 ..< 8 {
		w := ws[row * 8:]
		o := out[row * stride:]
		S2 :: CB + P1 + 3
		R2 :: 1 << (S2 - 1)
		if w[1] == 0 && w[2] == 0 && w[3] == 0 && w[4] == 0 && w[5] == 0 && w[6] == 0 && w[7] == 0 {
			v := clampb((w[0] + (1 << (P1 + 2))) >> (P1 + 3))
			for i in 0 ..< 8 do o[i] = v
			continue
		}
		z2 := w[2]
		z3 := w[6]
		z1 := (z2 + z3) * F0541
		tmp2 := z1 + z3 * (-F1847)
		tmp3 := z1 + z2 * F0765
		tmp0 := (w[0] + w[4]) << CB
		tmp1 := (w[0] - w[4]) << CB
		tmp10 := tmp0 + tmp3
		tmp13 := tmp0 - tmp3
		tmp11 := tmp1 + tmp2
		tmp12 := tmp1 - tmp2
		tmp0 = w[7]
		tmp1 = w[5]
		tmp2 = w[3]
		tmp3 = w[1]
		z1 = tmp0 + tmp3
		z2 = tmp1 + tmp2
		z3 = tmp0 + tmp2
		z4 := tmp1 + tmp3
		z5 := (z3 + z4) * F1175
		tmp0 *= F0298
		tmp1 *= F2053
		tmp2 *= F3072
		tmp3 *= F1501
		z1 *= -F0899
		z2 *= -F2562
		z3 *= -F1961
		z4 *= -F0390
		z3 += z5
		z4 += z5
		tmp0 += z1 + z3
		tmp1 += z2 + z4
		tmp2 += z2 + z3
		tmp3 += z1 + z4
		o[0] = clampb((tmp10 + tmp3 + R2) >> S2)
		o[7] = clampb((tmp10 - tmp3 + R2) >> S2)
		o[1] = clampb((tmp11 + tmp2 + R2) >> S2)
		o[6] = clampb((tmp11 - tmp2 + R2) >> S2)
		o[2] = clampb((tmp12 + tmp1 + R2) >> S2)
		o[5] = clampb((tmp12 - tmp1 + R2) >> S2)
		o[3] = clampb((tmp13 + tmp0 + R2) >> S2)
		o[4] = clampb((tmp13 - tmp0 + R2) >> S2)
	}
}

// Upsample component c to full resolution w x h (libjpeg-turbo jdsample.c).
@(private)
j_upsample :: proc(d: ^J_Dec, c: ^J_Comp, out: []u8, allocator: mem.Allocator) #no_bounds_check {
	W, H := d.w, d.h
	hr, vr := d.hmax / c.h, d.vmax / c.v
	ps := c.bw * 8
	src := c.plane
	ow := c.dw * hr // output row length before cropping
	S :: #force_inline proc "contextless" (src: []u8, ps, x, y: int) -> int {return int(src[y * ps + x])}
	row := make([]u8, ow + 2, allocator)
	defer delete(row, allocator)
	dw, dh := c.dw, c.dh
	for oy in 0 ..< H {
		iy := oy / vr
		r := row
		switch {
		case hr == 1 && vr == 1:
			copy(r, src[iy * ps:][:dw])
		case hr == 2 && vr == 1:
			sr := src[iy * ps:]
			if dw > 2 {
				r[0] = sr[0]
				r[1] = u8((int(sr[0]) * 3 + int(sr[1]) + 2) >> 2)
				for x in 1 ..< dw - 1 {
					v := int(sr[x]) * 3
					r[2 * x] = u8((v + int(sr[x - 1]) + 1) >> 2)
					r[2 * x + 1] = u8((v + int(sr[x + 1]) + 2) >> 2)
				}
				v := int(sr[dw - 1])
				r[2 * dw - 2] = u8((v * 3 + int(sr[dw - 2]) + 1) >> 2)
				r[2 * dw - 1] = u8(v)
			} else {
				for x in 0 ..< dw do r[2 * x], r[2 * x + 1] = sr[x], sr[x]
			}
		case hr == 1 && vr == 2:
			v := oy & 1
			other := v == 0 ? max(iy - 1, 0) : min(iy + 1, dh - 1)
			bias := v == 0 ? 1 : 2
			for x in 0 ..< dw do r[x] = u8((S(src, ps, x, iy) * 3 + S(src, ps, x, other) + bias) >> 2)
		case hr == 2 && vr == 2:
			v := oy & 1
			other := v == 0 ? max(iy - 1, 0) : min(iy + 1, dh - 1)
			if dw > 2 {
				r0 := src[iy * ps:]
				r1 := src[other * ps:]
				this := int(r0[0]) * 3 + int(r1[0])
				next := int(r0[1]) * 3 + int(r1[1])
				r[0] = u8((this * 4 + 8) >> 4)
				r[1] = u8((this * 3 + next + 7) >> 4)
				last := this
				this = next
				for x in 1 ..< dw - 1 {
					next = int(r0[x + 1]) * 3 + int(r1[x + 1])
					r[2 * x] = u8((this * 3 + last + 8) >> 4)
					r[2 * x + 1] = u8((this * 3 + next + 7) >> 4)
					last = this
					this = next
				}
				r[2 * dw - 2] = u8((this * 3 + last + 8) >> 4)
				r[2 * dw - 1] = u8((this * 4 + 7) >> 4)
			} else {
				sr := src[iy * ps:]
				for x in 0 ..< dw do r[2 * x], r[2 * x + 1] = sr[x], sr[x]
			}
		case:
			sr := src[iy * ps:]
			for x in 0 ..< W do r[x] = sr[min(x / hr, ps - 1)]
		}
		copy(out[oy * W:][:W], r[:W])
	}
}

@(private)
exif_orientation :: proc(seg: []byte) -> int {
	if len(seg) < 14 || string(seg[:6]) != "Exif\x00\x00" do return 1
	t := seg[6:]
	le := t[0] == 'I'
	r16 :: proc(t: []byte, o: int, le: bool) -> int {
		if o + 2 > len(t) do return 0
		return le ? le16i(t[o:]) : be16(t[o:])
	}
	r32 :: proc(t: []byte, o: int, le: bool) -> int {
		if o + 4 > len(t) do return 0
		return le ? le32i(t[o:]) : be32(t[o:])
	}
	ifd := r32(t, 4, le)
	n := r16(t, ifd, le)
	for i in 0 ..< n {
		e := ifd + 2 + i * 12
		if e + 12 > len(t) do break
		if r16(t, e, le) == 0x0112 {
			v := r16(t, e + 8, le)
			return v >= 1 && v <= 8 ? v : 1
		}
	}
	return 1
}

@(private)
jpeg_decode :: proc(c: ^Decode_Ctx, data: []byte, img: ^Image) -> Error {
	d := new(J_Dec, c.allocator)
	defer {
		for i in 0 ..< 4 {
			delete(d.comps[i].coeffs, c.allocator)
			delete(d.comps[i].plane, c.allocator)
		}
		free(d, c.allocator)
	}
	d.orientation = 1
	d.transform = -1
	p := 2
	scans := 0
	done := false
	for !done && p + 4 <= len(data) {
		if data[p] != 0xFF {
			p += 1
			continue
		}
		m := data[p + 1]
		if m == 0xFF {
			p += 1
			continue
		}
		p += 2
		if m == 0xD9 do break
		if m >= 0xD0 && m <= 0xD7 || m == 0x01 do continue
		if p + 2 > len(data) do break
		ln := be16(data[p:])
		if ln < 2 || p + ln > len(data) {
			if scans > 0 do break
			return .Truncated
		}
		seg := data[p + 2:p + ln]
		switch m {
		case 0xC0, 0xC1, 0xC2:
			if d.seen_sof || len(seg) < 6 do return .Corrupt
			d.seen_sof = true
			d.progressive = m == 0xC2
			if seg[0] != 8 do return .Unsupported
			d.h, d.w = be16(seg[1:]), be16(seg[3:])
			d.ncomp = int(seg[5])
			if d.h == 0 do return .Unsupported // DNL not supported
			check_size(c, d.w, d.h) or_return
			if d.ncomp != 1 && d.ncomp != 3 && d.ncomp != 4 do return .Unsupported
			if len(seg) < 6 + 3 * d.ncomp do return .Corrupt
			for i in 0 ..< d.ncomp {
				cp := &d.comps[i]
				cp.id = int(seg[6 + 3 * i])
				cp.h = int(seg[7 + 3 * i] >> 4)
				cp.v = int(seg[7 + 3 * i] & 15)
				cp.tq = int(seg[8 + 3 * i] & 3)
				if cp.h < 1 || cp.h > 4 || cp.v < 1 || cp.v > 4 do return .Corrupt
				d.hmax = max(d.hmax, cp.h)
				d.vmax = max(d.vmax, cp.v)
			}
			if d.ncomp == 1 {
				// a single component is always one block per MCU
				d.comps[0].h, d.comps[0].v, d.hmax, d.vmax = 1, 1, 1, 1
			}
			d.mcux = (d.w + 8 * d.hmax - 1) / (8 * d.hmax)
			d.mcuy = (d.h + 8 * d.vmax - 1) / (8 * d.vmax)
			for i in 0 ..< d.ncomp {
				cp := &d.comps[i]
				if d.hmax % cp.h != 0 || d.vmax % cp.v != 0 do return .Unsupported
				cp.bw = d.mcux * cp.h
				cp.bh = d.mcuy * cp.v
				cp.dw = (d.w * cp.h + d.hmax - 1) / d.hmax
				cp.dh = (d.h * cp.v + d.vmax - 1) / d.vmax
				n := cp.bw * cp.bh * 64
				if n > 4 * c.max_pixels do return .Too_Large
				cp.coeffs = make([]i16, n, c.allocator)
				if cp.coeffs == nil do return .Out_Of_Memory
			}
		case 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF:
			return .Unsupported
		case 0xC4:
			q := 0
			for q < len(seg) {
				if q + 17 > len(seg) do return .Corrupt
				tc, th := int(seg[q] >> 4), int(seg[q] & 15)
				counts := seg[q + 1:q + 17]
				total := 0
				for n in counts do total += int(n)
				if th > 3 || tc > 1 || total > 256 || q + 17 + total > len(seg) do return .Corrupt
				t := tc == 0 ? &d.dc[th] : &d.ac[th]
				if !build_jhuff(t, counts, seg[q + 17:q + 17 + total]) do return .Corrupt
				q += 17 + total
			}
		case 0xDB:
			q := 0
			for q < len(seg) {
				pq, tq := int(seg[q] >> 4), int(seg[q] & 15)
				if tq > 3 do return .Corrupt
				sz := pq == 0 ? 64 : 128
				if q + 1 + sz > len(seg) do return .Corrupt
				for i in 0 ..< 64 {
					v := pq == 0 ? u16(seg[q + 1 + i]) : u16(be16(seg[q + 1 + 2 * i:]))
					d.qt[tq][JZZ[i]] = v
				}
				q += 1 + sz
			}
		case 0xDD:
			if len(seg) >= 2 do d.restart = be16(seg)
		case 0xE0:
			if len(seg) >= 5 && string(seg[:5]) == "JFIF\x00" do d.jfif = true
		case 0xE1:
			if d.orientation == 1 do d.orientation = exif_orientation(seg)
		case 0xEE:
			if len(seg) >= 12 && string(seg[:5]) == "Adobe" {
				d.adobe = true
				d.transform = int(seg[11])
			}
		case 0xDA:
			if !d.seen_sof || len(seg) < 1 do return .Corrupt
			ns := int(seg[0])
			if ns < 1 || ns > 4 || len(seg) < 1 + 2 * ns + 3 do return .Corrupt
			sc: [4]int
			for i in 0 ..< ns {
				id := int(seg[1 + 2 * i])
				found := -1
				for k in 0 ..< d.ncomp do if d.comps[k].id == id do found = k
				if found < 0 do return .Corrupt
				sc[i] = found
				d.comps[found].td = int(seg[2 + 2 * i] >> 4) & 3
				d.comps[found].ta = int(seg[2 + 2 * i] & 15) & 3
			}
			ss := int(seg[1 + 2 * ns])
			se := int(seg[2 + 2 * ns])
			ah := int(seg[3 + 2 * ns] >> 4)
			al := int(seg[3 + 2 * ns] & 15)
			if !d.progressive {
				ss, se, ah, al = 0, 63, 0, 0
			} else if ss > se || se > 63 || (ss == 0 && se != 0) || (ss > 0 && ns != 1) || al > 13 {
				return .Corrupt
			}
			for i in 0 ..< ns {
				cp := &d.comps[sc[i]]
				if (ss == 0 && ah == 0 || !d.progressive) && !d.dc[cp.td].ok do return .Corrupt
				if (se > 0) && !d.ac[cp.ta].ok do return .Corrupt
			}
			p = j_scan(d, data, p + ln, sc[:ns], ss, se, ah, al)
			scans += 1
			continue
		}
		p += ln
	}
	if scans == 0 do return .Truncated

	// IDCT
	for i in 0 ..< d.ncomp {
		cp := &d.comps[i]
		ps := cp.bw * 8
		cp.plane = make([]u8, ps * cp.bh * 8, c.allocator)
		if cp.plane == nil do return .Out_Of_Memory
		q := &d.qt[cp.tq]
		for by in 0 ..< cp.bh {
			for bx in 0 ..< cp.bw {
				idct_islow(cp.coeffs[(by * cp.bw + bx) * 64:][:64], q, raw_data(cp.plane)[by * 8 * ps + bx * 8:], ps)
			}
		}
		delete(cp.coeffs, c.allocator)
		cp.coeffs = nil
	}
	W, H := d.w, d.h
	planes: [4][]u8
	defer for pl in planes do delete(pl, c.allocator)
	for i in 0 ..< d.ncomp {
		planes[i] = make([]u8, W * H, c.allocator)
		j_upsample(d, &d.comps[i], planes[i], c.allocator)
	}
	px := alloc_pixels(c, W, H) or_return
	// colour conversion
	ycc := d.ncomp >= 3
	if d.ncomp == 3 {
		if d.adobe {
			ycc = d.transform != 0
		} else if !d.jfif && d.comps[0].id == 'R' && d.comps[1].id == 'G' && d.comps[2].id == 'B' {
			ycc = false
		}
	} else if d.ncomp == 4 {
		ycc = d.adobe && d.transform == 2
	}
	j_color(d, planes, px, ycc)
	// EXIF orientation
	ow, oh := W, H
	if d.orientation != 1 {
		if d.orientation >= 5 do ow, oh = H, W
		rot := alloc_pixels(c, ow, oh) or_return
		for y in 0 ..< H {
			for x in 0 ..< W {
				nx, ny: int
				switch d.orientation {
				case 2: nx, ny = W - 1 - x, y
				case 3: nx, ny = W - 1 - x, H - 1 - y
				case 4: nx, ny = x, H - 1 - y
				case 5: nx, ny = y, x
				case 6: nx, ny = H - 1 - y, x
				case 7: nx, ny = H - 1 - y, W - 1 - x
				case 8: nx, ny = y, W - 1 - x
				}
				copy(rot[(ny * ow + nx) * 4:][:4], px[(y * W + x) * 4:][:4])
			}
		}
		delete(px, c.allocator)
		px = rot
	}
	img.width, img.height = ow, oh
	img.loop_count = 1
	return push_frame(c, px, 0, true)
}

@(private)
j_color :: proc(d: ^J_Dec, planes: [4][]u8, px: []u8, ycc: bool) #no_bounds_check {
	FIX :: proc "contextless" (x: f64) -> i32 {return i32(x * 65536 + 0.5)}
	cr_r, cb_b, cr_g, cb_g: [256]i32
	for i in 0 ..< 256 {
		x := i32(i) - 128
		cr_r[i] = (FIX(1.40200) * x + 32768) >> 16
		cb_b[i] = (FIX(1.77200) * x + 32768) >> 16
		cr_g[i] = -FIX(0.71414) * x
		cb_g[i] = -FIX(0.34414) * x + 32768
	}
	cl :: #force_inline proc "contextless" (v: i32) -> u8 {return v < 0 ? 0 : v > 255 ? 255 : u8(v)}
	lut: [1024]u32
	for i in 0 ..< 1024 do lut[i] = u32(cl(i32(i) - 384))
	n := d.w * d.h
	o := raw_data(px)
	p0, p1, p2, p3 := raw_data(planes[0]), raw_data(planes[1]), raw_data(planes[2]), raw_data(planes[3])
	switch {
	case d.ncomp == 1:
		for i in 0 ..< n {
			g := p0[i]
			o[4 * i], o[4 * i + 1], o[4 * i + 2], o[4 * i + 3] = g, g, g, 255
		}
	case d.ncomp == 3 && ycc:
		o32 := ([^]u32)(o)
		L := raw_data(lut[384:])
		for i in 0 ..< n {
			y := i32(p0[i])
			cb, cr := p1[i], p2[i]
			r := L[y + cr_r[cr]]
			g := L[y + ((cb_g[cb] + cr_g[cr]) >> 16)]
			b := L[y + cb_b[cb]]
			intrinsics.unaligned_store(&o32[i], r | g << 8 | b << 16 | 0xFF000000)
		}
	case d.ncomp == 3:
		for i in 0 ..< n {
			o[4 * i], o[4 * i + 1], o[4 * i + 2], o[4 * i + 3] = p0[i], p1[i], p2[i], 255
		}
	case:
		// Adobe CMYK / YCCK, stored inverted
		for i in 0 ..< n {
			r, g, b := p0[i], p1[i], p2[i]
			if ycc {
				y := i32(r)
				r = 255 - cl(y + cr_r[b])
				g = 255 - cl(y + ((cb_g[g] + cr_g[b]) >> 16))
				b = 255 - cl(y + cb_b[p1[i]])
			}
			k := u32(p3[i])
			o[4 * i] = u8((u32(r) * k + 127) / 255)
			o[4 * i + 1] = u8((u32(g) * k + 127) / 255)
			o[4 * i + 2] = u8((u32(b) * k + 127) / 255)
			o[4 * i + 3] = 255
		}
	}
}
