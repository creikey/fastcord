package imagefmt

// WebP lossy (VP8 key frames, RFC 6386), matching libwebp's decoder output:
// same prediction edge rules, transforms, loop filter and the "fancy"
// chroma upsampler + YUV->RGB fixed-point conversion.

import "base:intrinsics"
import "core:mem"

// ---------------------------------------------------------------------------
// Boolean entropy decoder

@(private)
Bool_Dec :: struct {
	value: u64,
	rng:   u32, // range - 1
	bits:  i32,
	data:  []byte,
	pos:   int,
	eof:   bool,
}

@(private)
bd_init :: proc "contextless" (br: ^Bool_Dec, data: []byte) {
	br^ = {}
	br.data = data
	br.rng = 254
	br.bits = -8
	bd_load(br)
}

@(private)
bd_load :: #force_inline proc "contextless" (br: ^Bool_Dec) {
	if br.pos + 8 <= len(br.data) {
		v := u64(intrinsics.unaligned_load((^u64be)(raw_data(br.data)[br.pos:]))) >> 8
		br.pos += 7
		br.value = (br.value << 56) | v
		br.bits += 56
	} else {
		bd_load_slow(br)
	}
}

@(private)
bd_load_slow :: #force_no_inline proc "contextless" (br: ^Bool_Dec) {
	if br.pos < len(br.data) {
		br.bits += 8
		br.value = (br.value << 8) | u64(br.data[br.pos])
		br.pos += 1
	} else if !br.eof {
		br.value <<= 8
		br.bits += 8
		br.eof = true
	} else {
		br.bits = 0
	}
}

@(private)
bd_bit :: #force_inline proc "contextless" (br: ^Bool_Dec, prob: u32) -> u32 {
	if br.bits < 0 do bd_load(br)
	pos := u64(br.bits) & 63
	split := (br.rng * prob) >> 8
	value := u32(br.value >> pos)
	r := br.rng
	bit: u32
	if value > split {
		r -= split
		br.value -= u64(split + 1) << pos
		bit = 1
	} else {
		r = split + 1
	}
	shift := intrinsics.count_leading_zeros(r) - 24 // == 7 ^ log2(r) for r in [1, 255]
	r <<= shift
	br.bits -= i32(shift)
	br.rng = r - 1
	return bit
}

@(private)
bd_value :: proc "contextless" (br: ^Bool_Dec, n: u32) -> i32 {
	v: u32
	for i := n; i > 0; i -= 1 do v |= bd_bit(br, 0x80) << (i - 1)
	return i32(v)
}

@(private)
bd_signed :: proc "contextless" (br: ^Bool_Dec, n: u32) -> i32 {
	v := bd_value(br, n)
	return bd_bit(br, 0x80) == 1 ? -v : v
}

// ---------------------------------------------------------------------------

@(private)
VP8_BPS :: 32
@(private)
YO :: VP8_BPS + 8 // origin of the 16x16 Y block inside the work buffer
@(private)
UO :: VP8_BPS + 8

@(private)
ZIGZAG := [16]u8{0, 1, 4, 8, 5, 2, 3, 6, 9, 12, 13, 10, 7, 11, 14, 15}
@(private)
BANDS := [17]u8{0, 1, 2, 3, 6, 4, 5, 6, 6, 6, 6, 6, 6, 6, 6, 7, 0}
@(private)
CAT3 := [?]u8{173, 148, 140}
@(private)
CAT4 := [?]u8{176, 155, 140, 135}
@(private)
CAT5 := [?]u8{180, 157, 141, 134, 130}
@(private)
CAT6 := [?]u8{254, 254, 243, 230, 196, 177, 153, 140, 133, 130, 129}
@(private)
YMODES_INTRA4 := [18]i8{0, 1, -1, 2, -2, 3, 4, 6, -3, 5, -4, -5, -6, 7, -7, 8, -8, -9}

@(private)
NZ_Ctx :: struct {
	y:  [4]u8,
	u:  [2]u8,
	v:  [2]u8,
	dc: u8,
}

@(private)
F_Info :: struct {
	limit, ilevel, hev: u8,
	inner:              bool,
}

@(private)
Quant :: struct {
	y1, y2, uv: [2]i32,
}

@(private)
VP8_Dec :: struct {
	w, h, mb_w, mb_h: int,
	br:               Bool_Dec,
	parts:            [8]Bool_Dec,
	nparts:           int,
	use_segment:      bool,
	update_map:       bool,
	absolute_delta:   bool,
	seg_quant:        [4]i32,
	seg_filter:       [4]i32,
	seg_probs:        [3]u32,
	filter_simple:    bool,
	filter_level:     i32,
	sharpness:        i32,
	use_lf_delta:     bool,
	ref_lf_delta:     [4]i32,
	mode_lf_delta:    [4]i32,
	filter_type:      int,
	dqm:              [4]Quant,
	proba:            [4][8][3][11]u8,
	use_skip:         bool,
	skip_p:           u32,
	fstrengths:       [4][2]F_Info,
	y, u, v:          []u8,
	ystride, uvstride: int,
	intra_t:          []u8,
	nz_t:             []NZ_Ctx,
	finfo:            []F_Info,
}

@(private)
vp8_headers :: proc(d: ^VP8_Dec, data: []byte) -> Error {
	if len(data) < 10 do return .Truncated
	bits := le24i(data)
	key := bits & 1 == 0
	profile := (bits >> 1) & 7
	show := (bits >> 4) & 1
	part_len := bits >> 5
	if !key || profile > 3 || show == 0 do return .Unsupported
	if data[3] != 0x9D || data[4] != 0x01 || data[5] != 0x2A do return .Corrupt
	d.w = le16i(data[6:]) & 0x3FFF
	d.h = le16i(data[8:]) & 0x3FFF
	if d.w == 0 || d.h == 0 do return .Corrupt
	d.mb_w = (d.w + 15) >> 4
	d.mb_h = (d.h + 15) >> 4
	rest := data[10:]
	if part_len > len(rest) do return .Truncated
	bd_init(&d.br, rest[:part_len])
	br := &d.br
	bd_value(br, 1) // color space
	bd_value(br, 1) // clamping type

	// segment header
	d.absolute_delta = true
	d.seg_probs = {255, 255, 255}
	d.use_segment = bd_value(br, 1) == 1
	if d.use_segment {
		d.update_map = bd_value(br, 1) == 1
		if bd_value(br, 1) == 1 {
			d.absolute_delta = bd_value(br, 1) == 1
			for s in 0 ..< 4 do d.seg_quant[s] = bd_value(br, 1) == 1 ? bd_signed(br, 7) : 0
			for s in 0 ..< 4 do d.seg_filter[s] = bd_value(br, 1) == 1 ? bd_signed(br, 6) : 0
		}
		if d.update_map {
			for s in 0 ..< 3 do d.seg_probs[s] = bd_value(br, 1) == 1 ? u32(bd_value(br, 8)) : 255
		}
	}
	// filter header
	d.filter_simple = bd_value(br, 1) == 1
	d.filter_level = bd_value(br, 6)
	d.sharpness = bd_value(br, 3)
	d.use_lf_delta = bd_value(br, 1) == 1
	if d.use_lf_delta && bd_value(br, 1) == 1 {
		for i in 0 ..< 4 do if bd_value(br, 1) == 1 do d.ref_lf_delta[i] = bd_signed(br, 6)
		for i in 0 ..< 4 do if bd_value(br, 1) == 1 do d.mode_lf_delta[i] = bd_signed(br, 6)
	}
	d.filter_type = d.filter_level == 0 ? 0 : d.filter_simple ? 1 : 2

	// partitions
	parts := rest[part_len:]
	d.nparts = 1 << u32(bd_value(br, 2))
	last := d.nparts - 1
	if len(parts) < 3 * last do return .Truncated
	start := 3 * last
	left := len(parts) - start
	for p in 0 ..< last {
		psize := le24i(parts[3 * p:])
		if psize > left do psize = left
		bd_init(&d.parts[p], parts[start:start + psize])
		start += psize
		left -= psize
	}
	if start >= len(parts) do return .Truncated
	bd_init(&d.parts[last], parts[start:])

	// quantizers
	base_q0 := bd_value(br, 7)
	dqy1_dc := bd_value(br, 1) == 1 ? bd_signed(br, 4) : 0
	dqy2_dc := bd_value(br, 1) == 1 ? bd_signed(br, 4) : 0
	dqy2_ac := bd_value(br, 1) == 1 ? bd_signed(br, 4) : 0
	dquv_dc := bd_value(br, 1) == 1 ? bd_signed(br, 4) : 0
	dquv_ac := bd_value(br, 1) == 1 ? bd_signed(br, 4) : 0
	clipq :: proc "contextless" (v, m: i32) -> i32 {return v < 0 ? 0 : v > m ? m : v}
	for i in 0 ..< 4 {
		q: i32
		if d.use_segment {
			q = d.seg_quant[i]
			if !d.absolute_delta do q += base_q0
		} else {
			if i > 0 {
				d.dqm[i] = d.dqm[0]
				continue
			}
			q = base_q0
		}
		m := &d.dqm[i]
		m.y1[0] = i32(VP8_DC_TABLE[clipq(q + dqy1_dc, 127)])
		m.y1[1] = i32(VP8_AC_TABLE[clipq(q, 127)])
		m.y2[0] = i32(VP8_DC_TABLE[clipq(q + dqy2_dc, 127)]) * 2
		m.y2[1] = (i32(VP8_AC_TABLE[clipq(q + dqy2_ac, 127)]) * 101581) >> 16
		if m.y2[1] < 8 do m.y2[1] = 8
		m.uv[0] = i32(VP8_DC_TABLE[clipq(q + dquv_dc, 117)])
		m.uv[1] = i32(VP8_AC_TABLE[clipq(q + dquv_ac, 127)])
	}
	bd_value(br, 1) // update_proba (ignored for key frames)
	for t in 0 ..< 4 do for b in 0 ..< 8 do for c in 0 ..< 3 do for p in 0 ..< 11 {
		v := bd_bit(br, u32(VP8_COEFFS_UPDATE_PROBA[t][b][c][p])) == 1 ? u8(bd_value(br, 8)) : VP8_COEFFS_PROBA0[t][b][c][p]
		d.proba[t][b][c][p] = v
	}
	d.use_skip = bd_value(br, 1) == 1
	if d.use_skip do d.skip_p = u32(bd_value(br, 8))
	if d.br.eof do return .Truncated

	// filter strengths
	if d.filter_type > 0 {
		for s in 0 ..< 4 {
			base := d.filter_level
			if d.use_segment {
				base = d.seg_filter[s]
				if !d.absolute_delta do base += d.filter_level
			}
			for i4 in 0 ..= 1 {
				level := base
				if d.use_lf_delta {
					level += d.ref_lf_delta[0]
					if i4 == 1 do level += d.mode_lf_delta[0]
				}
				level = clamp(level, 0, 63)
				fi := &d.fstrengths[s][i4]
				if level > 0 {
					ilevel := level
					if d.sharpness > 0 {
						ilevel >>= d.sharpness > 4 ? u32(2) : u32(1)
						if ilevel > 9 - d.sharpness do ilevel = 9 - d.sharpness
					}
					if ilevel < 1 do ilevel = 1
					fi.ilevel = u8(ilevel)
					fi.limit = u8(2 * level + ilevel)
					fi.hev = level >= 40 ? 2 : level >= 15 ? 1 : 0
				} else {
					fi.limit = 0
				}
				fi.inner = i4 == 1
			}
		}
	}
	return .None
}

@(private)
large_value :: #force_inline proc "contextless" (br: ^Bool_Dec, p: [^]u8) -> i32 {
	v: i32
	if bd_bit(br, u32(p[3])) == 0 {
		if bd_bit(br, u32(p[4])) == 0 {
			v = 2
		} else {
			v = 3 + i32(bd_bit(br, u32(p[5])))
		}
	} else {
		if bd_bit(br, u32(p[6])) == 0 {
			if bd_bit(br, u32(p[7])) == 0 {
				v = 5 + i32(bd_bit(br, 159))
			} else {
				v = 7 + 2 * i32(bd_bit(br, 165))
				v += i32(bd_bit(br, 145))
			}
		} else {
			bit1 := bd_bit(br, u32(p[8]))
			bit0 := bd_bit(br, u32(p[9 + bit1]))
			cat := 2 * bit1 + bit0
			tab: []u8
			switch cat {
			case 0: tab = CAT3[:]
			case 1: tab = CAT4[:]
			case 2: tab = CAT5[:]
			case: tab = CAT6[:]
			}
			v = 0
			for pr in tab do v += v + i32(bd_bit(br, u32(pr)))
			v += 3 + (8 << cat)
		}
	}
	return v
}

// Returns the index after the last decoded coefficient (libwebp GetCoeffs).
@(private)
get_coeffs :: proc "contextless" (brp: ^Bool_Dec, prob: ^[8][3][11]u8, ctx: int, dq: [2]i32, first: int, out: [^]i16) -> int #no_bounds_check {
	// work on a local copy so the decoder state stays in registers (out may alias)
	b := brp^
	br := &b
	defer brp^ = b
	n := first
	p := raw_data(prob[BANDS[n]][ctx][:])
	for n < 16 {
		if bd_bit(br, u32(p[0])) == 0 do return n
		for bd_bit(br, u32(p[1])) == 0 {
			n += 1
			if n == 16 do return 16
			p = raw_data(prob[BANDS[n]][0][:])
		}
		nb := BANDS[n + 1]
		v: i32
		if bd_bit(br, u32(p[2])) == 0 {
			v = 1
			p = raw_data(prob[nb][1][:])
		} else {
			v = large_value(br, p)
			p = raw_data(prob[nb][2][:])
		}
		if bd_bit(br, 0x80) == 1 do v = -v
		out[ZIGZAG[n]] = i16(v * dq[n > 0 ? 1 : 0])
		n += 1
	}
	return 16
}

@(private)
clip8 :: #force_inline proc "contextless" (v: i32) -> u8 {
	return v < 0 ? 0 : v > 255 ? 255 : u8(v)
}

@(private)
transform_one :: proc "contextless" (inp: [^]i16, dst: [^]u8) #no_bounds_check {
	MUL1 :: #force_inline proc "contextless" (a: i32) -> i32 {return ((a * 20091) >> 16) + a}
	MUL2 :: #force_inline proc "contextless" (a: i32) -> i32 {return (a * 35468) >> 16}
	C: [16]i32
	for i in 0 ..< 4 {
		a := i32(inp[i]) + i32(inp[8 + i])
		b := i32(inp[i]) - i32(inp[8 + i])
		c := MUL2(i32(inp[4 + i])) - MUL1(i32(inp[12 + i]))
		dd := MUL1(i32(inp[4 + i])) + MUL2(i32(inp[12 + i]))
		C[i * 4 + 0] = a + dd
		C[i * 4 + 1] = b + c
		C[i * 4 + 2] = b - c
		C[i * 4 + 3] = a - dd
	}
	for i in 0 ..< 4 {
		dc := C[i] + 4
		a := dc + C[8 + i]
		b := dc - C[8 + i]
		c := MUL2(C[4 + i]) - MUL1(C[12 + i])
		dd := MUL1(C[4 + i]) + MUL2(C[12 + i])
		row := dst[i * VP8_BPS:]
		row[0] = clip8(i32(row[0]) + ((a + dd) >> 3))
		row[1] = clip8(i32(row[1]) + ((b + c) >> 3))
		row[2] = clip8(i32(row[2]) + ((b - c) >> 3))
		row[3] = clip8(i32(row[3]) + ((a - dd) >> 3))
	}
}

@(private)
transform_dc :: proc "contextless" (inp: [^]i16, dst: [^]u8) #no_bounds_check {
	dc := (i32(inp[0]) + 4) >> 3
	for y in 0 ..< 4 do for x in 0 ..< 4 {
		p := &dst[y * VP8_BPS + x]
		p^ = clip8(i32(p^) + dc)
	}
}

@(private)
do_transform :: #force_inline proc "contextless" (coeffs: [^]i16, nz: int, dst: [^]u8) {
	if nz > 1 {
		transform_one(coeffs, dst)
	} else if coeffs[0] != 0 {
		transform_dc(coeffs, dst)
	}
}

@(private)
transform_wht :: proc "contextless" (inp: [^]i16, out: [^]i16) #no_bounds_check {
	tmp: [16]i32
	for i in 0 ..< 4 {
		a0 := i32(inp[i]) + i32(inp[12 + i])
		a1 := i32(inp[4 + i]) + i32(inp[8 + i])
		a2 := i32(inp[4 + i]) - i32(inp[8 + i])
		a3 := i32(inp[i]) - i32(inp[12 + i])
		tmp[i] = a0 + a1
		tmp[8 + i] = a0 - a1
		tmp[4 + i] = a3 + a2
		tmp[12 + i] = a3 - a2
	}
	for i in 0 ..< 4 {
		dc := tmp[i * 4] + 3
		a0 := dc + tmp[3 + i * 4]
		a1 := tmp[1 + i * 4] + tmp[2 + i * 4]
		a2 := tmp[1 + i * 4] - tmp[2 + i * 4]
		a3 := dc - tmp[3 + i * 4]
		o := out[i * 64:]
		o[0] = i16((a0 + a1) >> 3)
		o[16] = i16((a3 + a2) >> 3)
		o[32] = i16((a0 - a1) >> 3)
		o[48] = i16((a3 - a2) >> 3)
	}
}

// ---------------------------------------------------------------------------
// Intra prediction (dst points at block origin in a VP8_BPS-stride buffer)

@(private)
avg3 :: #force_inline proc "contextless" (a, b, c: i32) -> u8 {return u8((a + 2 * b + c + 2) >> 2)}
@(private)
avg2b :: #force_inline proc "contextless" (a, b: i32) -> u8 {return u8((a + b + 1) >> 1)}

@(private)
true_motion :: proc "contextless" (dst: [^]u8, size: int) #no_bounds_check {
	top := dst[-VP8_BPS:]
	tl := i32(top[-1])
	for y in 0 ..< size {
		l := i32(dst[y * VP8_BPS - 1]) - tl
		row := dst[y * VP8_BPS:]
		for x in 0 ..< size do row[x] = clip8(i32(top[x]) + l)
	}
}

@(private)
fill_block :: #force_inline proc "contextless" (dst: [^]u8, size: int, v: u8) {
	for y in 0 ..< size do mem.set(dst[y * VP8_BPS:], v, size)
}

@(private)
pred_luma16 :: proc "contextless" (dst: [^]u8, mode: u8, mb_x, mb_y: int) #no_bounds_check {
	switch mode {
	case 0: // DC
		has_top, has_left := mb_y > 0, mb_x > 0
		dc: i32
		if has_top && has_left {
			for j in 0 ..< 16 do dc += i32(dst[j - VP8_BPS]) + i32(dst[j * VP8_BPS - 1])
			dc = (dc + 16) >> 5
		} else if has_left {
			for j in 0 ..< 16 do dc += i32(dst[j * VP8_BPS - 1])
			dc = (dc + 8) >> 4
		} else if has_top {
			for j in 0 ..< 16 do dc += i32(dst[j - VP8_BPS])
			dc = (dc + 8) >> 4
		} else {
			dc = 0x80
		}
		fill_block(dst, 16, u8(dc))
	case 1:
		true_motion(dst, 16)
	case 2:
		for y in 0 ..< 16 do mem.copy(dst[y * VP8_BPS:], dst[-VP8_BPS:], 16)
	case 3:
		for y in 0 ..< 16 do mem.set(dst[y * VP8_BPS:], dst[y * VP8_BPS - 1], 16)
	}
}

@(private)
pred_chroma8 :: proc "contextless" (dst: [^]u8, mode: u8, mb_x, mb_y: int) #no_bounds_check {
	switch mode {
	case 0:
		has_top, has_left := mb_y > 0, mb_x > 0
		dc: i32
		if has_top && has_left {
			for j in 0 ..< 8 do dc += i32(dst[j - VP8_BPS]) + i32(dst[j * VP8_BPS - 1])
			dc = (dc + 8) >> 4
		} else if has_left {
			for j in 0 ..< 8 do dc += i32(dst[j * VP8_BPS - 1])
			dc = (dc + 4) >> 3
		} else if has_top {
			for j in 0 ..< 8 do dc += i32(dst[j - VP8_BPS])
			dc = (dc + 4) >> 3
		} else {
			dc = 0x80
		}
		fill_block(dst, 8, u8(dc))
	case 1:
		true_motion(dst, 8)
	case 2:
		for y in 0 ..< 8 do mem.copy(dst[y * VP8_BPS:], dst[-VP8_BPS:], 8)
	case 3:
		for y in 0 ..< 8 do mem.set(dst[y * VP8_BPS:], dst[y * VP8_BPS - 1], 8)
	}
}

@(private)
pred_luma4 :: proc "contextless" (dst: [^]u8, mode: u8) #no_bounds_check {
	B :: VP8_BPS
	top := dst[-B:]
	D :: #force_inline proc "contextless" (dst: [^]u8, x, y: int, v: u8) {dst[x + y * B] = v}
	switch mode {
	case 0:
		dc: u32 = 4
		for i in 0 ..< 4 do dc += u32(top[i]) + u32(dst[i * B - 1])
		fill_block(dst, 4, u8(dc >> 3))
	case 1:
		true_motion(dst, 4)
	case 2:
		v := [4]u8 {
			avg3(i32(top[-1]), i32(top[0]), i32(top[1])),
			avg3(i32(top[0]), i32(top[1]), i32(top[2])),
			avg3(i32(top[1]), i32(top[2]), i32(top[3])),
			avg3(i32(top[2]), i32(top[3]), i32(top[4])),
		}
		for i in 0 ..< 4 do (^[4]u8)(dst[i * B:])^ = v
	case 3:
		A, Bv, C, Dv, E := i32(dst[-1 - B]), i32(dst[-1]), i32(dst[-1 + B]), i32(dst[-1 + 2 * B]), i32(dst[-1 + 3 * B])
		mem.set(dst[0:], avg3(A, Bv, C), 4)
		mem.set(dst[B:], avg3(Bv, C, Dv), 4)
		mem.set(dst[2 * B:], avg3(C, Dv, E), 4)
		mem.set(dst[3 * B:], avg3(Dv, E, E), 4)
	case 4: // RD
		I, J, K, L := i32(dst[-1]), i32(dst[-1 + B]), i32(dst[-1 + 2 * B]), i32(dst[-1 + 3 * B])
		X, A, Bt, C, Dt := i32(dst[-1 - B]), i32(top[0]), i32(top[1]), i32(top[2]), i32(top[3])
		D(dst, 0, 3, avg3(J, K, L))
		v := avg3(I, J, K);D(dst, 1, 3, v);D(dst, 0, 2, v)
		v = avg3(X, I, J);D(dst, 2, 3, v);D(dst, 1, 2, v);D(dst, 0, 1, v)
		v = avg3(A, X, I);D(dst, 3, 3, v);D(dst, 2, 2, v);D(dst, 1, 1, v);D(dst, 0, 0, v)
		v = avg3(Bt, A, X);D(dst, 3, 2, v);D(dst, 2, 1, v);D(dst, 1, 0, v)
		v = avg3(C, Bt, A);D(dst, 3, 1, v);D(dst, 2, 0, v)
		D(dst, 3, 0, avg3(Dt, C, Bt))
	case 5: // VR
		I, J, K := i32(dst[-1]), i32(dst[-1 + B]), i32(dst[-1 + 2 * B])
		X, A, Bt, C, Dt := i32(dst[-1 - B]), i32(top[0]), i32(top[1]), i32(top[2]), i32(top[3])
		v := avg2b(X, A);D(dst, 0, 0, v);D(dst, 1, 2, v)
		v = avg2b(A, Bt);D(dst, 1, 0, v);D(dst, 2, 2, v)
		v = avg2b(Bt, C);D(dst, 2, 0, v);D(dst, 3, 2, v)
		D(dst, 3, 0, avg2b(C, Dt))
		D(dst, 0, 3, avg3(K, J, I))
		D(dst, 0, 2, avg3(J, I, X))
		v = avg3(I, X, A);D(dst, 0, 1, v);D(dst, 1, 3, v)
		v = avg3(X, A, Bt);D(dst, 1, 1, v);D(dst, 2, 3, v)
		v = avg3(A, Bt, C);D(dst, 2, 1, v);D(dst, 3, 3, v)
		D(dst, 3, 1, avg3(Bt, C, Dt))
	case 6: // LD
		A, Bt, C, Dt, E, F, G, H := i32(top[0]), i32(top[1]), i32(top[2]), i32(top[3]), i32(top[4]), i32(top[5]), i32(top[6]), i32(top[7])
		D(dst, 0, 0, avg3(A, Bt, C))
		v := avg3(Bt, C, Dt);D(dst, 1, 0, v);D(dst, 0, 1, v)
		v = avg3(C, Dt, E);D(dst, 2, 0, v);D(dst, 1, 1, v);D(dst, 0, 2, v)
		v = avg3(Dt, E, F);D(dst, 3, 0, v);D(dst, 2, 1, v);D(dst, 1, 2, v);D(dst, 0, 3, v)
		v = avg3(E, F, G);D(dst, 3, 1, v);D(dst, 2, 2, v);D(dst, 1, 3, v)
		v = avg3(F, G, H);D(dst, 3, 2, v);D(dst, 2, 3, v)
		D(dst, 3, 3, avg3(G, H, H))
	case 7: // VL
		A, Bt, C, Dt, E, F, G, H := i32(top[0]), i32(top[1]), i32(top[2]), i32(top[3]), i32(top[4]), i32(top[5]), i32(top[6]), i32(top[7])
		D(dst, 0, 0, avg2b(A, Bt))
		v := avg2b(Bt, C);D(dst, 1, 0, v);D(dst, 0, 2, v)
		v = avg2b(C, Dt);D(dst, 2, 0, v);D(dst, 1, 2, v)
		v = avg2b(Dt, E);D(dst, 3, 0, v);D(dst, 2, 2, v)
		D(dst, 0, 1, avg3(A, Bt, C))
		v = avg3(Bt, C, Dt);D(dst, 1, 1, v);D(dst, 0, 3, v)
		v = avg3(C, Dt, E);D(dst, 2, 1, v);D(dst, 1, 3, v)
		v = avg3(Dt, E, F);D(dst, 3, 1, v);D(dst, 2, 3, v)
		D(dst, 3, 2, avg3(E, F, G))
		D(dst, 3, 3, avg3(F, G, H))
	case 8: // HD
		I, J, K, L := i32(dst[-1]), i32(dst[-1 + B]), i32(dst[-1 + 2 * B]), i32(dst[-1 + 3 * B])
		X, A, Bt, C := i32(dst[-1 - B]), i32(top[0]), i32(top[1]), i32(top[2])
		v := avg2b(I, X);D(dst, 0, 0, v);D(dst, 2, 1, v)
		v = avg2b(J, I);D(dst, 0, 1, v);D(dst, 2, 2, v)
		v = avg2b(K, J);D(dst, 0, 2, v);D(dst, 2, 3, v)
		D(dst, 0, 3, avg2b(L, K))
		D(dst, 3, 0, avg3(A, Bt, C))
		D(dst, 2, 0, avg3(X, A, Bt))
		v = avg3(I, X, A);D(dst, 1, 0, v);D(dst, 3, 1, v)
		v = avg3(J, I, X);D(dst, 1, 1, v);D(dst, 3, 2, v)
		v = avg3(K, J, I);D(dst, 1, 2, v);D(dst, 3, 3, v)
		D(dst, 1, 3, avg3(L, K, J))
	case 9: // HU
		I, J, K, L := i32(dst[-1]), i32(dst[-1 + B]), i32(dst[-1 + 2 * B]), i32(dst[-1 + 3 * B])
		D(dst, 0, 0, avg2b(I, J))
		v := avg2b(J, K);D(dst, 2, 0, v);D(dst, 0, 1, v)
		v = avg2b(K, L);D(dst, 2, 1, v);D(dst, 0, 2, v)
		D(dst, 1, 0, avg3(I, J, K))
		v = avg3(J, K, L);D(dst, 3, 0, v);D(dst, 1, 1, v)
		v = avg3(K, L, L);D(dst, 3, 1, v);D(dst, 1, 2, v)
		l := u8(L)
		D(dst, 3, 2, l);D(dst, 2, 2, l);D(dst, 0, 3, l);D(dst, 1, 3, l);D(dst, 2, 3, l);D(dst, 3, 3, l)
	}
}

// ---------------------------------------------------------------------------
// Loop filter (libwebp dsp/dec.c)

@(private)
sclip1 :: #force_inline proc "contextless" (v: i32) -> i32 {return v < -128 ? -128 : v > 127 ? 127 : v}
@(private)
sclip2 :: #force_inline proc "contextless" (v: i32) -> i32 {return v < -16 ? -16 : v > 15 ? 15 : v}
@(private)
uclip :: #force_inline proc "contextless" (v: i32) -> u8 {return v < 0 ? 0 : v > 255 ? 255 : u8(v)}

@(private)
do_filter2 :: #force_inline proc "contextless" (p: [^]u8, s: int) {
	p1, p0, q0, q1 := i32(p[-2 * s]), i32(p[-s]), i32(p[0]), i32(p[s])
	a := 3 * (q0 - p0) + sclip1(p1 - q1)
	a1 := sclip2((a + 4) >> 3)
	a2 := sclip2((a + 3) >> 3)
	p[-s] = uclip(p0 + a2)
	p[0] = uclip(q0 - a1)
}

@(private)
do_filter4 :: #force_inline proc "contextless" (p: [^]u8, s: int) {
	p1, p0, q0, q1 := i32(p[-2 * s]), i32(p[-s]), i32(p[0]), i32(p[s])
	a := 3 * (q0 - p0)
	a1 := sclip2((a + 4) >> 3)
	a2 := sclip2((a + 3) >> 3)
	a3 := (a1 + 1) >> 1
	p[-2 * s] = uclip(p1 + a3)
	p[-s] = uclip(p0 + a2)
	p[0] = uclip(q0 - a1)
	p[s] = uclip(q1 - a3)
}

@(private)
do_filter6 :: #force_inline proc "contextless" (p: [^]u8, s: int) {
	p2, p1, p0 := i32(p[-3 * s]), i32(p[-2 * s]), i32(p[-s])
	q0, q1, q2 := i32(p[0]), i32(p[s]), i32(p[2 * s])
	a := sclip1(3 * (q0 - p0) + sclip1(p1 - q1))
	a1 := (27 * a + 63) >> 7
	a2 := (18 * a + 63) >> 7
	a3 := (9 * a + 63) >> 7
	p[-3 * s] = uclip(p2 + a3)
	p[-2 * s] = uclip(p1 + a2)
	p[-s] = uclip(p0 + a1)
	p[0] = uclip(q0 - a1)
	p[s] = uclip(q1 - a2)
	p[2 * s] = uclip(q2 - a3)
}

@(private)
hev :: #force_inline proc "contextless" (p: [^]u8, s: int, t: i32) -> bool {
	p1, p0, q0, q1 := i32(p[-2 * s]), i32(p[-s]), i32(p[0]), i32(p[s])
	return abs(p1 - p0) > t || abs(q1 - q0) > t
}

@(private)
needs_filter :: #force_inline proc "contextless" (p: [^]u8, s: int, t: i32) -> bool {
	p1, p0, q0, q1 := i32(p[-2 * s]), i32(p[-s]), i32(p[0]), i32(p[s])
	return 4 * abs(p0 - q0) + abs(p1 - q1) <= t
}

@(private)
needs_filter2 :: #force_inline proc "contextless" (p: [^]u8, s: int, t, it: i32) -> bool {
	p3, p2, p1, p0 := i32(p[-4 * s]), i32(p[-3 * s]), i32(p[-2 * s]), i32(p[-s])
	q0, q1, q2, q3 := i32(p[0]), i32(p[s]), i32(p[2 * s]), i32(p[3 * s])
	if 4 * abs(p0 - q0) + abs(p1 - q1) > t do return false
	return abs(p3 - p2) <= it && abs(p2 - p1) <= it && abs(p1 - p0) <= it && abs(q3 - q2) <= it && abs(q2 - q1) <= it && abs(q1 - q0) <= it
}

@(private)
simple_filter :: proc "contextless" (p: [^]u8, hstride, vstride: int, thresh: i32) #no_bounds_check {
	t2 := 2 * thresh + 1
	for i in 0 ..< 16 {
		q := p[i * vstride:]
		if needs_filter(q, hstride, t2) do do_filter2(q, hstride)
	}
}

@(private)
filter_loop26 :: proc "contextless" (p: [^]u8, hs, vs, size: int, thresh, ithresh, hev_t: i32) #no_bounds_check {
	t2 := 2 * thresh + 1
	for i in 0 ..< size {
		q := p[i * vs:]
		if needs_filter2(q, hs, t2, ithresh) {
			if hev(q, hs, hev_t) {
				do_filter2(q, hs)
			} else {
				do_filter6(q, hs)
			}
		}
	}
}

@(private)
filter_loop24 :: proc "contextless" (p: [^]u8, hs, vs, size: int, thresh, ithresh, hev_t: i32) #no_bounds_check {
	t2 := 2 * thresh + 1
	for i in 0 ..< size {
		q := p[i * vs:]
		if needs_filter2(q, hs, t2, ithresh) {
			if hev(q, hs, hev_t) {
				do_filter2(q, hs)
			} else {
				do_filter4(q, hs)
			}
		}
	}
}

@(private)
vp8_filter_frame :: proc(d: ^VP8_Dec) #no_bounds_check {
	ys, uvs := d.ystride, d.uvstride
	for mb_y in 0 ..< d.mb_h {
		for mb_x in 0 ..< d.mb_w {
			fi := d.finfo[mb_y * d.mb_w + mb_x]
			limit := i32(fi.limit)
			if limit == 0 do continue
			yd := raw_data(d.y)[mb_y * 16 * ys + mb_x * 16:]
			if d.filter_type == 1 {
				if mb_x > 0 do simple_filter(yd, 1, ys, limit + 4)
				if fi.inner do for k in 1 ..= 3 do simple_filter(yd[4 * k:], 1, ys, limit)
				if mb_y > 0 do simple_filter(yd, ys, 1, limit + 4)
				if fi.inner do for k in 1 ..= 3 do simple_filter(yd[4 * k * ys:], ys, 1, limit)
			} else {
				ud := raw_data(d.u)[mb_y * 8 * uvs + mb_x * 8:]
				vd := raw_data(d.v)[mb_y * 8 * uvs + mb_x * 8:]
				il := i32(fi.ilevel)
				ht := i32(fi.hev)
				if mb_x > 0 {
					filter_loop26(yd, 1, ys, 16, limit + 4, il, ht)
					filter_loop26(ud, 1, uvs, 8, limit + 4, il, ht)
					filter_loop26(vd, 1, uvs, 8, limit + 4, il, ht)
				}
				if fi.inner {
					for k in 1 ..= 3 do filter_loop24(yd[4 * k:], 1, ys, 16, limit, il, ht)
					filter_loop24(ud[4:], 1, uvs, 8, limit, il, ht)
					filter_loop24(vd[4:], 1, uvs, 8, limit, il, ht)
				}
				if mb_y > 0 {
					filter_loop26(yd, ys, 1, 16, limit + 4, il, ht)
					filter_loop26(ud, uvs, 1, 8, limit + 4, il, ht)
					filter_loop26(vd, uvs, 1, 8, limit + 4, il, ht)
				}
				if fi.inner {
					for k in 1 ..= 3 do filter_loop24(yd[4 * k * ys:], ys, 1, 16, limit, il, ht)
					filter_loop24(ud[4 * uvs:], uvs, 1, 8, limit, il, ht)
					filter_loop24(vd[4 * uvs:], uvs, 1, 8, limit, il, ht)
				}
			}
		}
	}
}

// ---------------------------------------------------------------------------
// Macroblock decoding

@(private)
vp8_decode_frame :: proc(d: ^VP8_Dec, allocator: mem.Allocator) -> Error #no_bounds_check {
	d.ystride = d.mb_w * 16
	d.uvstride = d.mb_w * 8
	d.y = make([]u8, d.ystride * d.mb_h * 16, allocator)
	d.u = make([]u8, d.uvstride * d.mb_h * 8, allocator)
	d.v = make([]u8, d.uvstride * d.mb_h * 8, allocator)
	d.intra_t = make([]u8, d.mb_w * 4, allocator)
	d.nz_t = make([]NZ_Ctx, d.mb_w, allocator)
	d.finfo = make([]F_Info, d.mb_w * d.mb_h, allocator)
	if d.y == nil || d.u == nil || d.v == nil || d.intra_t == nil || d.nz_t == nil || d.finfo == nil do return .Out_Of_Memory

	ybuf: [VP8_BPS * 17]u8
	ubuf: [VP8_BPS * 9]u8
	vbuf: [VP8_BPS * 9]u8
	coeffs: [384]i16
	nzs: [24]int
	br := &d.br
	ys, uvs := d.ystride, d.uvstride

	for mb_y in 0 ..< d.mb_h {
		intra_l: [4]u8
		nz_l: NZ_Ctx
		tbr := &d.parts[mb_y & (d.nparts - 1)]
		for mb_x in 0 ..< d.mb_w {
			// --- header (first partition)
			seg := 0
			if d.update_map {
				seg = bd_bit(br, d.seg_probs[0]) == 0 ? int(bd_bit(br, d.seg_probs[1])) : int(bd_bit(br, d.seg_probs[2])) + 2
			}
			skip := d.use_skip ? bd_bit(br, d.skip_p) == 1 : false
			is_i4 := bd_bit(br, 145) == 0
			imodes: [16]u8
			ymode: u8
			top := d.intra_t[mb_x * 4:][:4]
			if !is_i4 {
				ymode = bd_bit(br, 156) == 1 ? (bd_bit(br, 128) == 1 ? 1 : 3) : (bd_bit(br, 163) == 1 ? 2 : 0)
				for i in 0 ..< 4 {
					top[i] = ymode
					intra_l[i] = ymode
				}
			} else {
				for y in 0 ..< 4 {
					m := intra_l[y]
					for x in 0 ..< 4 {
						prob := &VP8_BMODES_PROBA[top[x]][m]
						i := i32(YMODES_INTRA4[bd_bit(br, u32(prob[0]))])
						for i > 0 do i = i32(YMODES_INTRA4[2 * i + i32(bd_bit(br, u32(prob[i])))])
						m = u8(-i)
						top[x] = m
						imodes[y * 4 + x] = m
					}
					intra_l[y] = m
				}
			}
			uvmode: u8 = bd_bit(br, 142) == 0 ? 0 : bd_bit(br, 114) == 0 ? 2 : bd_bit(br, 183) == 1 ? 1 : 3

			// --- residuals
			coeffs = {}
			nzs = {}
			has_coeffs := false
			tnz := &d.nz_t[mb_x]
			if !skip {
				q := &d.dqm[seg]
				first := 0
				ac_type := 3
				if !is_i4 {
					dc: [16]i16
					ctx := int(tnz.dc + nz_l.dc)
					nz := get_coeffs(tbr, &d.proba[1], ctx, q.y2, 0, raw_data(dc[:]))
					f := u8(nz > 0 ? 1 : 0)
					tnz.dc = f
					nz_l.dc = f
					if nz > 1 {
						transform_wht(raw_data(dc[:]), raw_data(coeffs[:]))
					} else {
						dc0 := i16((i32(dc[0]) + 3) >> 3)
						for i in 0 ..< 16 do coeffs[i * 16] = dc0
					}
					first = 1
					ac_type = 0
				}
				for y in 0 ..< 4 {
					for x in 0 ..< 4 {
						b := y * 4 + x
						ctx := int(nz_l.y[y] + tnz.y[x])
						nz := get_coeffs(tbr, &d.proba[ac_type], ctx, q.y1, first, raw_data(coeffs[b * 16:]))
						f := u8(nz > first ? 1 : 0)
						nz_l.y[y] = f
						tnz.y[x] = f
						nzs[b] = nz
						if nz > 1 || coeffs[b * 16] != 0 do has_coeffs = true
					}
				}
				for ch in 0 ..< 2 {
					lc := ch == 0 ? &nz_l.u : &nz_l.v
					tc := ch == 0 ? &tnz.u : &tnz.v
					for y in 0 ..< 2 {
						for x in 0 ..< 2 {
							b := 16 + ch * 4 + y * 2 + x
							ctx := int(lc[y] + tc[x])
							nz := get_coeffs(tbr, &d.proba[2], ctx, q.uv, 0, raw_data(coeffs[b * 16:]))
							f := u8(nz > 0 ? 1 : 0)
							lc[y] = f
							tc[x] = f
							nzs[b] = nz
							if nz > 0 do has_coeffs = true
						}
					}
				}
			} else {
				dcs := tnz.dc
				dcl := nz_l.dc
				tnz^ = {}
				nz_l = {}
				if is_i4 {
					tnz.dc = dcs
					nz_l.dc = dcl
				}
			}
			if d.filter_type > 0 {
				fi := d.fstrengths[seg][is_i4 ? 1 : 0]
				if has_coeffs do fi.inner = true
				d.finfo[mb_y * d.mb_w + mb_x] = fi
			}

			// --- reconstruction into work buffers
			yb := raw_data(ybuf[:])
			ub := raw_data(ubuf[:])
			vb := raw_data(vbuf[:])
			px := mb_x * 16
			py := mb_y * 16
			cx := mb_x * 8
			cy := mb_y * 8
			if mb_y > 0 {
				mem.copy(yb[YO - VP8_BPS:], &d.y[(py - 1) * ys + px], 16)
				mem.copy(ub[UO - VP8_BPS:], &d.u[(cy - 1) * uvs + cx], 8)
				mem.copy(vb[UO - VP8_BPS:], &d.v[(cy - 1) * uvs + cx], 8)
				if mb_x > 0 {
					yb[YO - VP8_BPS - 1] = d.y[(py - 1) * ys + px - 1]
					ub[UO - VP8_BPS - 1] = d.u[(cy - 1) * uvs + cx - 1]
					vb[UO - VP8_BPS - 1] = d.v[(cy - 1) * uvs + cx - 1]
				} else {
					yb[YO - VP8_BPS - 1] = 129
					ub[UO - VP8_BPS - 1] = 129
					vb[UO - VP8_BPS - 1] = 129
				}
				tr := yb[YO - VP8_BPS + 16:]
				if mb_x >= d.mb_w - 1 {
					mem.set(tr, d.y[(py - 1) * ys + px + 15], 4)
				} else {
					mem.copy(tr, &d.y[(py - 1) * ys + px + 16], 4)
				}
			} else {
				mem.set(yb[YO - VP8_BPS - 1:], 127, 21)
				mem.set(ub[UO - VP8_BPS - 1:], 127, 9)
				mem.set(vb[UO - VP8_BPS - 1:], 127, 9)
			}
			if mb_x > 0 {
				for j in 0 ..< 16 do yb[YO + j * VP8_BPS - 1] = d.y[(py + j) * ys + px - 1]
				for j in 0 ..< 8 {
					ub[UO + j * VP8_BPS - 1] = d.u[(cy + j) * uvs + cx - 1]
					vb[UO + j * VP8_BPS - 1] = d.v[(cy + j) * uvs + cx - 1]
				}
			} else {
				for j in 0 ..< 16 do yb[YO + j * VP8_BPS - 1] = 129
				for j in 0 ..< 8 {
					ub[UO + j * VP8_BPS - 1] = 129
					vb[UO + j * VP8_BPS - 1] = 129
				}
			}
			// replicate the top-right samples for sub-block rows 1..3
			for k in 1 ..= 3 do mem.copy(yb[YO + (4 * k - 1) * VP8_BPS + 16:], yb[YO - VP8_BPS + 16:], 4)

			cf := raw_data(coeffs[:])
			if is_i4 {
				for n in 0 ..< 16 {
					dst := yb[YO + (n >> 2) * 4 * VP8_BPS + (n & 3) * 4:]
					pred_luma4(dst, imodes[n])
					do_transform(cf[n * 16:], nzs[n], dst)
				}
			} else {
				pred_luma16(yb[YO:], ymode, mb_x, mb_y)
				for n in 0 ..< 16 {
					do_transform(cf[n * 16:], nzs[n], yb[YO + (n >> 2) * 4 * VP8_BPS + (n & 3) * 4:])
				}
			}
			pred_chroma8(ub[UO:], uvmode, mb_x, mb_y)
			pred_chroma8(vb[UO:], uvmode, mb_x, mb_y)
			for n in 0 ..< 4 {
				off := (n >> 1) * 4 * VP8_BPS + (n & 1) * 4
				do_transform(cf[(16 + n) * 16:], nzs[16 + n], ub[UO + off:])
				do_transform(cf[(20 + n) * 16:], nzs[20 + n], vb[UO + off:])
			}
			for j in 0 ..< 16 do mem.copy(&d.y[(py + j) * ys + px], yb[YO + j * VP8_BPS:], 16)
			for j in 0 ..< 8 {
				mem.copy(&d.u[(cy + j) * uvs + cx], ub[UO + j * VP8_BPS:], 8)
				mem.copy(&d.v[(cy + j) * uvs + cx], vb[UO + j * VP8_BPS:], 8)
			}
			if tbr.eof do return .Truncated
		}
		if br.eof do return .Truncated
	}
	if d.filter_type > 0 do vp8_filter_frame_simd(d)
	return .None
}

// ---------------------------------------------------------------------------
// YUV -> RGBA with libwebp's "fancy" upsampling

@(private)
yuv_rgb :: #force_inline proc "contextless" (y, u, v: i32, dst: [^]u8) {
	MultHi :: #force_inline proc "contextless" (v, c: i32) -> i32 {return (v * c) >> 8}
	Clip8 :: #force_inline proc "contextless" (v: i32) -> u8 {
		return (v & ~i32(16383)) == 0 ? u8(v >> 6) : v < 0 ? 0 : 255
	}
	yy := MultHi(y, 19077)
	dst[0] = Clip8(yy + MultHi(v, 26149) - 14234)
	dst[1] = Clip8(yy - MultHi(u, 6419) - MultHi(v, 13320) + 8708)
	dst[2] = Clip8(yy + MultHi(u, 33050) - 17685)
}

// One output row: near/far are the chroma rows weighted 3:1.
@(private)
upsample_row :: proc "contextless" (y: [^]u8, nu, nv, fu, fv: [^]u8, dst: [^]u8, w: int) #no_bounds_check {
	last := (w - 1) >> 1
	tl_u, tl_v := i32(nu[0]), i32(nv[0])
	l_u, l_v := i32(fu[0]), i32(fv[0])
	yuv_rgb(i32(y[0]), (3 * tl_u + l_u + 2) >> 2, (3 * tl_v + l_v + 2) >> 2, dst)
	for x in 1 ..= last {
		t_u, t_v := i32(nu[x]), i32(nv[x])
		c_u, c_v := i32(fu[x]), i32(fv[x])
		avg_u := tl_u + t_u + l_u + c_u + 8
		avg_v := tl_v + t_v + l_v + c_v + 8
		d12u := (avg_u + 2 * (t_u + l_u)) >> 3
		d03u := (avg_u + 2 * (tl_u + c_u)) >> 3
		d12v := (avg_v + 2 * (t_v + l_v)) >> 3
		d03v := (avg_v + 2 * (tl_v + c_v)) >> 3
		yuv_rgb(i32(y[2 * x - 1]), (d12u + tl_u) >> 1, (d12v + tl_v) >> 1, dst[(2 * x - 1) * 4:])
		yuv_rgb(i32(y[2 * x]), (d03u + t_u) >> 1, (d03v + t_v) >> 1, dst[(2 * x) * 4:])
		tl_u, tl_v = t_u, t_v
		l_u, l_v = c_u, c_v
	}
	if w & 1 == 0 {
		yuv_rgb(i32(y[w - 1]), (3 * tl_u + l_u + 2) >> 2, (3 * tl_v + l_v + 2) >> 2, dst[(w - 1) * 4:])
	}
}

// Writes RGB into an RGBA canvas (stride = canvas width*4); alpha untouched.
@(private)
vp8_to_rgba :: proc(d: ^VP8_Dec, dst: []u8, dst_stride: int) #no_bounds_check {
	w, h := d.w, d.h
	uvh := (h + 1) / 2
	Y, U, V := raw_data(d.y), raw_data(d.u), raw_data(d.v)
	ys, uvs := d.ystride, d.uvstride
	for r in 0 ..< h {
		near, far: int
		if r == 0 {
			near, far = 0, 0
		} else if r & 1 == 1 {
			near = (r - 1) / 2
			far = min((r + 1) / 2, uvh - 1)
		} else {
			near = r / 2
			far = r / 2 - 1
		}
		upsample_row(Y[r * ys:], U[near * uvs:], V[near * uvs:], U[far * uvs:], V[far * uvs:], raw_data(dst)[r * dst_stride:], w)
	}
}
