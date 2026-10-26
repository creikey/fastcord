package opus

// Band quantization (bands.c): PVQ split/theta recursion, stereo, folding.

@(rodata)
ordery_table := [30]int{1, 0, 3, 0, 2, 1, 7, 0, 4, 3, 6, 1, 5, 2, 15, 0, 8, 7, 12, 3, 11, 4, 14, 1, 9, 6, 13, 2, 10, 5}
@(rodata)
bit_interleave_table := [16]u8{0, 1, 1, 1, 2, 3, 3, 3, 2, 3, 3, 3, 2, 3, 3, 3}
@(rodata)
bit_deinterleave_table := [16]u8{0x00, 0x03, 0x0C, 0x0F, 0x30, 0x33, 0x3C, 0x3F, 0xC0, 0xC3, 0xCC, 0xCF, 0xF0, 0xF3, 0xFC, 0xFF}

compute_band_energies :: proc "contextless" (x: []f32, band_e: []f32, end, C, LM: int) {
	n := SHORT_MDCT_SIZE << uint(LM)
	for c in 0 ..< C {
		for i in 0 ..< end {
			o := c * n + (int(eband5ms[i]) << uint(LM))
			l := int(eband5ms[i + 1] - eband5ms[i]) << uint(LM)
			sum := 1e-27 + inner_prod(x[o:], x[o:], l)
			band_e[i + c * NB_EBANDS] = celt_sqrt(sum)
		}
	}
}

normalise_bands :: proc "contextless" (freq: []f32, x: []f32, band_e: []f32, end, C, M: int) {
	n := M * SHORT_MDCT_SIZE
	for c in 0 ..< C {
		for i in 0 ..< end {
			g := 1 / (1e-27 + band_e[i + c * NB_EBANDS])
			for j in M * int(eband5ms[i]) ..< M * int(eband5ms[i + 1]) do x[j + c * n] = freq[j + c * n] * g
		}
	}
}

denormalise_bands :: proc "contextless" (x: []f32, freq: []f32, band_log_e: []f32, start_, end_: int, M: int, downsample: int, silence: bool) {
	start, end := start_, end_
	n := M * SHORT_MDCT_SIZE
	bound := M * int(eband5ms[end])
	if downsample != 1 do bound = min(bound, n / downsample)
	if silence {
		bound = 0
		start = 0
		end = 0
	}
	fi := 0
	xi := M * int(eband5ms[start])
	for _ in 0 ..< M * int(eband5ms[start]) {
		freq[fi] = 0
		fi += 1
	}
	for i in start ..< end {
		j := M * int(eband5ms[i])
		band_end := M * int(eband5ms[i + 1])
		lg := band_log_e[i] + eMeans[i]
		g := celt_exp2(min(32, lg))
		for ; j < band_end; j += 1 {
			freq[fi] = x[xi] * g
			fi += 1
			xi += 1
		}
	}
	for k in bound ..< n do freq[k] = 0
}

anti_collapse :: proc "contextless" (x_: []f32, collapse_masks: []u8, LM, C, size, start, end: int, log_e, prev1_log_e, prev2_log_e: []f32, pulses: []i32, seed_: u32) {
	seed := seed_
	for i in start ..< end {
		n0 := int(eband5ms[i + 1] - eband5ms[i])
		depth := int(u32(1 + pulses[i]) / u32(n0)) >> uint(LM)
		thresh := 0.5 * celt_exp2(-0.125 * f32(depth))
		sqrt_1 := celt_rsqrt(f32(n0 << uint(LM)))
		for c in 0 ..< C {
			prev1 := prev1_log_e[c * NB_EBANDS + i]
			prev2 := prev2_log_e[c * NB_EBANDS + i]
			if C == 1 {
				prev1 = max(prev1, prev1_log_e[NB_EBANDS + i])
				prev2 = max(prev2, prev2_log_e[NB_EBANDS + i])
			}
			ediff := log_e[c * NB_EBANDS + i] - min(prev1, prev2)
			ediff = max(0, ediff)
			r := 2 * celt_exp2(-ediff)
			if LM == 3 do r *= 1.41421356
			r = min(thresh, r)
			r = r * sqrt_1
			xo := c * size + (int(eband5ms[i]) << uint(LM))
			renorm := false
			for k in 0 ..< 1 << uint(LM) {
				if collapse_masks[i * C + c] & (1 << uint(k)) == 0 {
					for j in 0 ..< n0 {
						seed = celt_lcg_rand(seed)
						x_[xo + (j << uint(LM)) + k] = (seed & 0x8000) != 0 ? r : -r
					}
					renorm = true
				}
			}
			if renorm do renormalise_vector(x_[xo:], n0 << uint(LM), 1)
		}
	}
}

@(private = "file")
intensity_stereo :: proc "contextless" (x, y: []f32, band_e: []f32, band_id, n: int) {
	left := band_e[band_id]
	right := band_e[band_id + NB_EBANDS]
	norm := EPSILON + celt_sqrt(EPSILON + left * left + right * right)
	a1 := left / norm
	a2 := right / norm
	for j in 0 ..< n do x[j] = a1 * x[j] + a2 * y[j]
}

@(private = "file")
stereo_split :: proc "contextless" (x, y: []f32, n: int) {
	for j in 0 ..< n {
		l := 0.70710678 * x[j]
		r := 0.70710678 * y[j]
		x[j] = l + r
		y[j] = r - l
	}
}

@(private = "file")
stereo_merge :: proc "contextless" (x, y: []f32, mid: f32, n: int) {
	xp, side: f32 = 0, 0
	for j in 0 ..< n {
		xp += y[j] * x[j]
		side += y[j] * y[j]
	}
	xp = mid * xp
	mid2 := mid
	el := mid2 * mid2 + side - 2 * xp
	er := mid2 * mid2 + side + 2 * xp
	if er < 6e-4 || el < 6e-4 {
		copy(y[:n], x[:n])
		return
	}
	lgain := celt_rsqrt(el)
	rgain := celt_rsqrt(er)
	for j in 0 ..< n {
		l := mid * x[j]
		r := y[j]
		x[j] = lgain * (l - r)
		y[j] = rgain * (l + r)
	}
}

@(private = "file")
deinterleave_hadamard :: proc "contextless" (x: []f32, n0, stride: int, hadamard: bool) {
	tmp: [176]f32
	n := n0 * stride
	if hadamard {
		ordery := ordery_table[stride - 2:]
		for i in 0 ..< stride do for j in 0 ..< n0 do tmp[ordery[i] * n0 + j] = x[j * stride + i]
	} else {
		for i in 0 ..< stride do for j in 0 ..< n0 do tmp[i * n0 + j] = x[j * stride + i]
	}
	copy(x[:n], tmp[:n])
}

@(private = "file")
interleave_hadamard :: proc "contextless" (x: []f32, n0, stride: int, hadamard: bool) {
	tmp: [176]f32
	n := n0 * stride
	if hadamard {
		ordery := ordery_table[stride - 2:]
		for i in 0 ..< stride do for j in 0 ..< n0 do tmp[j * stride + i] = x[ordery[i] * n0 + j]
	} else {
		for i in 0 ..< stride do for j in 0 ..< n0 do tmp[j * stride + i] = x[i * n0 + j]
	}
	copy(x[:n], tmp[:n])
}

haar1 :: proc "contextless" (x: []f32, n0_, stride: int) {
	n0 := n0_ >> 1
	for i in 0 ..< stride {
		for j in 0 ..< n0 {
			tmp1 := 0.70710678 * x[stride * 2 * j + i]
			tmp2 := 0.70710678 * x[stride * (2 * j + 1) + i]
			x[stride * 2 * j + i] = tmp1 + tmp2
			x[stride * (2 * j + 1) + i] = tmp1 - tmp2
		}
	}
}

@(private = "file")
compute_qn :: proc "contextless" (n, b, offset, pulse_cap: i32, stereo: bool) -> i32 {
	exp2_table8 := [8]i32{16384, 17866, 19483, 21247, 23170, 25267, 27554, 30048}
	n2 := 2 * n - 1
	if stereo && n == 2 do n2 -= 1
	qb := (b + n2 * offset) / n2
	qb = min(b - pulse_cap - (4 << BITRES), qb)
	qb = min(8 << BITRES, qb)
	qn: i32
	if qb < (1 << BITRES >> 1) {
		qn = 1
	} else {
		qn = exp2_table8[qb & 0x7] >> u32(14 - (qb >> BITRES))
		qn = (qn + 1) >> 1 << 1
	}
	return qn
}

Band_Ctx :: struct {
	encode:            bool,
	resynth:           bool,
	i:                 int,
	intensity:         int,
	spread:            int,
	tf_change:         int,
	ec:                ^Range,
	remaining_bits:    i32,
	band_e:            []f32,
	seed:              u32,
	theta_round:       int,
	disable_inv:       bool,
	avoid_split_noise: bool,
}

@(private = "file")
Split_Ctx :: struct {
	inv:    bool,
	imid:   i32,
	iside:  i32,
	delta:  i32,
	itheta: i32,
	qalloc: i32,
}

@(private = "file")
compute_theta :: proc(ctx: ^Band_Ctx, sctx: ^Split_Ctx, x, y: []f32, n: int, b: ^i32, B, B0: int, LM: int, stereo: bool, fill: ^i32) {
	itheta: i32 = 0
	inv := false
	ec := ctx.ec
	i := ctx.i
	pulse_cap := i32(logN400[i]) + i32(LM) * (1 << BITRES)
	offset := (pulse_cap >> 1) - (stereo && n == 2 ? QTHETA_OFFSET_TWOPHASE : QTHETA_OFFSET)
	qn := compute_qn(i32(n), b^, offset, pulse_cap, stereo)
	if stereo && i >= ctx.intensity do qn = 1
	if ctx.encode do itheta = stereo_itheta(x, y, stereo, n)
	tell := i32(ec_tell_frac(ec))
	if qn != 1 {
		if ctx.encode {
			if !stereo || ctx.theta_round == 0 {
				itheta = (itheta * qn + 8192) >> 14
				if !stereo && ctx.avoid_split_noise && itheta > 0 && itheta < qn {
					unq := i32(u32(itheta) * 16384 / u32(qn))
					imid := i32(bitexact_cos(i16(unq)))
					iside := i32(bitexact_cos(i16(16384 - unq)))
					delta := frac_mul16(i32(n - 1) << 7, bitexact_log2tan(iside, imid))
					if delta > b^ do itheta = qn
					else if delta < -b^ do itheta = 0
				}
			} else {
				bias: i32 = itheta > 8192 ? 32767 / qn : -32767 / qn
				down := min(qn - 1, max(0, (itheta * qn + bias) >> 14))
				itheta = ctx.theta_round < 0 ? down : down + 1
			}
		}
		if stereo && n > 2 {
			p0: i32 = 3
			xv := itheta
			x0 := qn / 2
			ft := p0 * (x0 + 1) + x0
			if ctx.encode {
				fl := xv <= x0 ? p0 * xv : (xv - 1 - x0) + (x0 + 1) * p0
				fh := xv <= x0 ? p0 * (xv + 1) : (xv - x0) + (x0 + 1) * p0
				ec_encode(ec, u32(fl), u32(fh), u32(ft))
			} else {
				fs := i32(ec_decode(ec, u32(ft)))
				if fs < (x0 + 1) * p0 do xv = fs / p0
				else do xv = x0 + 1 + (fs - (x0 + 1) * p0)
				fl := xv <= x0 ? p0 * xv : (xv - 1 - x0) + (x0 + 1) * p0
				fh := xv <= x0 ? p0 * (xv + 1) : (xv - x0) + (x0 + 1) * p0
				ec_dec_update(ec, u32(fl), u32(fh), u32(ft))
				itheta = xv
			}
		} else if B0 > 1 || stereo {
			if ctx.encode do ec_enc_uint(ec, u32(itheta), u32(qn + 1))
			else do itheta = i32(ec_dec_uint(ec, u32(qn + 1)))
		} else {
			fs: i32 = 1
			ft := ((qn >> 1) + 1) * ((qn >> 1) + 1)
			if ctx.encode {
				fs = itheta <= (qn >> 1) ? itheta + 1 : qn + 1 - itheta
				fl := itheta <= (qn >> 1) ? itheta * (itheta + 1) >> 1 : ft - ((qn + 1 - itheta) * (qn + 2 - itheta) >> 1)
				ec_encode(ec, u32(fl), u32(fl + fs), u32(ft))
			} else {
				fl: i32 = 0
				fm := i32(ec_decode(ec, u32(ft)))
				if fm < ((qn >> 1) * ((qn >> 1) + 1) >> 1) {
					itheta = (i32(isqrt32(8 * u32(fm) + 1)) - 1) >> 1
					fs = itheta + 1
					fl = itheta * (itheta + 1) >> 1
				} else {
					itheta = (2 * (qn + 1) - i32(isqrt32(8 * u32(ft - fm - 1) + 1))) >> 1
					fs = qn + 1 - itheta
					fl = ft - ((qn + 1 - itheta) * (qn + 2 - itheta) >> 1)
				}
				ec_dec_update(ec, u32(fl), u32(fl + fs), u32(ft))
			}
		}
		itheta = i32(u32(itheta) * 16384 / u32(qn))
		if ctx.encode && stereo {
			if itheta == 0 do intensity_stereo(x, y, ctx.band_e, i, n)
			else do stereo_split(x, y, n)
		}
	} else if stereo {
		if ctx.encode {
			inv = itheta > 8192 && !ctx.disable_inv
			if inv do for j in 0 ..< n do y[j] = -y[j]
			intensity_stereo(x, y, ctx.band_e, i, n)
		}
		if b^ > 2 << BITRES && ctx.remaining_bits > 2 << BITRES {
			if ctx.encode do ec_enc_bit_logp(ec, inv, 2)
			else do inv = ec_dec_bit_logp(ec, 2)
		} else {
			inv = false
		}
		if ctx.disable_inv do inv = false
		itheta = 0
	}
	qalloc := i32(ec_tell_frac(ec)) - tell
	b^ -= qalloc
	imid, iside, delta: i32
	if itheta == 0 {
		imid = 32767
		iside = 0
		fill^ &= (1 << u32(B)) - 1
		delta = -16384
	} else if itheta == 16384 {
		imid = 0
		iside = 32767
		fill^ &= ((1 << u32(B)) - 1) << u32(B)
		delta = 16384
	} else {
		imid = i32(bitexact_cos(i16(itheta)))
		iside = i32(bitexact_cos(i16(16384 - itheta)))
		delta = frac_mul16(i32(n - 1) << 7, bitexact_log2tan(iside, imid))
	}
	sctx^ = {inv, imid, iside, delta, itheta, qalloc}
}

@(private = "file")
quant_band_n1 :: proc(ctx: ^Band_Ctx, x: []f32, y: []f32, b_: i32, lowband_out: []f32) -> u32 {
	b := b_
	xs := x
	stereo := y != nil
	for c in 0 ..< (stereo ? 2 : 1) {
		sign := false
		if ctx.remaining_bits >= 1 << BITRES {
			if ctx.encode {
				sign = xs[0] < 0
				ec_enc_bits(ctx.ec, u32(sign), 1)
			} else {
				sign = ec_dec_bits(ctx.ec, 1) != 0
			}
			ctx.remaining_bits -= 1 << BITRES
			b -= 1 << BITRES
		}
		if ctx.resynth do xs[0] = sign ? -1 : 1
		xs = y
		_ = c
	}
	if lowband_out != nil do lowband_out[0] = x[0]
	return 1
}

@(private = "file")
quant_partition :: proc(ctx: ^Band_Ctx, x: []f32, n_: int, b_: i32, B_: int, lowband: []f32, LM_: int, gain: f32, fill_: i32) -> u32 {
	n, b, B, LM, fill := n_, b_, B_, LM_, fill_
	B0 := B
	cm: u32 = 0
	i := ctx.i
	cache := cache_bits50[cache_index50[(LM + 1) * NB_EBANDS + i]:]
	if LM != -1 && b > i32(cache[cache[0]]) + 12 && n > 2 {
		sctx: Split_Ctx
		n >>= 1
		y := x[n:]
		LM -= 1
		if B == 1 do fill = (fill & 1) | (fill << 1)
		B = (B + 1) >> 1
		compute_theta(ctx, &sctx, x, y, n, &b, B, B0, LM, false, &fill)
		mid := (1.0 / 32768) * f32(sctx.imid)
		side := (1.0 / 32768) * f32(sctx.iside)
		delta := sctx.delta
		itheta := sctx.itheta
		if B0 > 1 && (itheta & 0x3fff) != 0 {
			if itheta > 8192 do delta -= delta >> u32(4 - LM)
			else do delta = min(0, delta + (i32(n) << BITRES >> u32(5 - LM)))
		}
		mbits := max(0, min(b, (b - delta) / 2))
		sbits := b - mbits
		ctx.remaining_bits -= sctx.qalloc
		next_lowband2: []f32
		if lowband != nil do next_lowband2 = lowband[n:]
		rebalance := ctx.remaining_bits
		if mbits >= sbits {
			cm = quant_partition(ctx, x, n, mbits, B, lowband, LM, gain * mid, fill)
			rebalance = mbits - (rebalance - ctx.remaining_bits)
			if rebalance > 3 << BITRES && itheta != 0 do sbits += rebalance - (3 << BITRES)
			cm |= quant_partition(ctx, y, n, sbits, B, next_lowband2, LM, gain * side, fill >> u32(B)) << u32(B0 >> 1)
		} else {
			cm = quant_partition(ctx, y, n, sbits, B, next_lowband2, LM, gain * side, fill >> u32(B)) << u32(B0 >> 1)
			rebalance = sbits - (rebalance - ctx.remaining_bits)
			if rebalance > 3 << BITRES && itheta != 16384 do mbits += rebalance - (3 << BITRES)
			cm |= quant_partition(ctx, x, n, mbits, B, lowband, LM, gain * mid, fill)
		}
	} else {
		q := bits2pulses(i32(i), i32(LM), b)
		curr_bits := pulses2bits(i32(i), i32(LM), q)
		ctx.remaining_bits -= curr_bits
		for ctx.remaining_bits < 0 && q > 0 {
			ctx.remaining_bits += curr_bits
			q -= 1
			curr_bits = pulses2bits(i32(i), i32(LM), q)
			ctx.remaining_bits -= curr_bits
		}
		if q != 0 {
			k := int(get_pulses(q))
			if ctx.encode {
				cm = alg_quant(x, n, k, ctx.spread, B, ctx.ec, gain, ctx.resynth)
			} else {
				cm = alg_unquant(x, n, k, ctx.spread, B, ctx.ec, gain)
			}
		} else if ctx.resynth {
			cm_mask := u32((u64(1) << u32(B)) - 1)
			fill &= i32(cm_mask)
			if fill == 0 {
				for j in 0 ..< n do x[j] = 0
			} else {
				if lowband == nil {
					for j in 0 ..< n {
						ctx.seed = celt_lcg_rand(ctx.seed)
						x[j] = f32(i32(ctx.seed) >> 20)
					}
					cm = cm_mask
				} else {
					for j in 0 ..< n {
						ctx.seed = celt_lcg_rand(ctx.seed)
						tmp: f32 = 1.0 / 256
						tmp = (ctx.seed & 0x8000) != 0 ? tmp : -tmp
						x[j] = lowband[j] + tmp
					}
					cm = u32(fill)
				}
				renormalise_vector(x, n, gain)
			}
		}
	}
	return cm
}

@(private = "file")
quant_band :: proc(ctx: ^Band_Ctx, x: []f32, n: int, b: i32, B_: int, lowband_: []f32, LM: int, lowband_out: []f32, gain: f32, lowband_scratch: []f32, fill_: i32) -> u32 {
	B := B_
	lowband := lowband_
	fill := fill_
	n0 := n
	n_b := n
	B0 := B
	time_divide := 0
	recombine := 0
	long_blocks := B0 == 1
	cm: u32 = 0
	tf_change := ctx.tf_change
	n_b = n_b / B
	if n == 1 do return quant_band_n1(ctx, x, nil, b, lowband_out)
	if tf_change > 0 do recombine = tf_change
	if lowband_scratch != nil && lowband != nil && (recombine != 0 || ((n_b & 1) == 0 && tf_change < 0) || B0 > 1) {
		copy(lowband_scratch[:n], lowband[:n])
		lowband = lowband_scratch
	}
	for k in 0 ..< recombine {
		if ctx.encode do haar1(x, n >> uint(k), 1 << uint(k))
		if lowband != nil do haar1(lowband, n >> uint(k), 1 << uint(k))
		fill = i32(bit_interleave_table[fill & 0xF]) | i32(bit_interleave_table[fill >> 4]) << 2
	}
	B >>= uint(recombine)
	n_b <<= uint(recombine)
	for (n_b & 1) == 0 && tf_change < 0 {
		if ctx.encode do haar1(x, n_b, B)
		if lowband != nil do haar1(lowband, n_b, B)
		fill |= fill << u32(B)
		B <<= 1
		n_b >>= 1
		time_divide += 1
		tf_change += 1
	}
	B0 = B
	n_b0 := n_b
	if B0 > 1 {
		if ctx.encode do deinterleave_hadamard(x, n_b >> uint(recombine), B0 << uint(recombine), long_blocks)
		if lowband != nil do deinterleave_hadamard(lowband, n_b >> uint(recombine), B0 << uint(recombine), long_blocks)
	}
	cm = quant_partition(ctx, x, n, b, B, lowband, LM, gain, fill)
	if ctx.resynth {
		if B0 > 1 do interleave_hadamard(x, n_b >> uint(recombine), B0 << uint(recombine), long_blocks)
		n_b = n_b0
		B = B0
		for _ in 0 ..< time_divide {
			B >>= 1
			n_b <<= 1
			cm |= cm >> u32(B)
			haar1(x, n_b, B)
		}
		for k in 0 ..< recombine {
			cm = u32(bit_deinterleave_table[cm])
			haar1(x, n0 >> uint(k), 1 << uint(k))
		}
		B <<= uint(recombine)
		if lowband_out != nil {
			nn := celt_sqrt(f32(n0))
			for j in 0 ..< n0 do lowband_out[j] = nn * x[j]
		}
		cm &= (1 << u32(B)) - 1
	}
	return cm
}

@(private = "file")
quant_band_stereo :: proc(ctx: ^Band_Ctx, x, y: []f32, n: int, b_: i32, B: int, lowband: []f32, LM: int, lowband_out: []f32, lowband_scratch: []f32, fill_: i32) -> u32 {
	b := b_
	fill := fill_
	cm: u32 = 0
	if n == 1 do return quant_band_n1(ctx, x, y, b, lowband_out)
	orig_fill := fill
	sctx: Split_Ctx
	compute_theta(ctx, &sctx, x, y, n, &b, B, B, LM, true, &fill)
	inv := sctx.inv
	mid := (1.0 / 32768) * f32(sctx.imid)
	side := (1.0 / 32768) * f32(sctx.iside)
	delta := sctx.delta
	itheta := sctx.itheta
	if n == 2 {
		mbits := b
		sbits: i32 = 0
		if itheta != 0 && itheta != 16384 do sbits = 1 << BITRES
		mbits -= sbits
		c := itheta > 8192
		ctx.remaining_bits -= sctx.qalloc + sbits
		x2 := c ? y : x
		y2 := c ? x : y
		sign: i32 = 0
		if sbits != 0 {
			if ctx.encode {
				s := x2[0] * y2[1] - x2[1] * y2[0] < 0
				sign = i32(s)
				ec_enc_bits(ctx.ec, u32(sign), 1)
			} else {
				sign = i32(ec_dec_bits(ctx.ec, 1))
			}
		}
		sign = 1 - 2 * sign
		cm = quant_band(ctx, x2, n, mbits, B, lowband, LM, lowband_out, 1, lowband_scratch, orig_fill)
		y2[0] = -f32(sign) * x2[1]
		y2[1] = f32(sign) * x2[0]
		if ctx.resynth {
			x[0] = mid * x[0]
			x[1] = mid * x[1]
			y[0] = side * y[0]
			y[1] = side * y[1]
			tmp := x[0]
			x[0] = tmp - y[0]
			y[0] = tmp + y[0]
			tmp = x[1]
			x[1] = tmp - y[1]
			y[1] = tmp + y[1]
		}
	} else {
		mbits := max(0, min(b, (b - delta) / 2))
		sbits := b - mbits
		ctx.remaining_bits -= sctx.qalloc
		rebalance := ctx.remaining_bits
		if mbits >= sbits {
			cm = quant_band(ctx, x, n, mbits, B, lowband, LM, lowband_out, 1, lowband_scratch, fill)
			rebalance = mbits - (rebalance - ctx.remaining_bits)
			if rebalance > 3 << BITRES && itheta != 0 do sbits += rebalance - (3 << BITRES)
			cm |= quant_band(ctx, y, n, sbits, B, nil, LM, nil, side, nil, fill >> u32(B))
		} else {
			cm = quant_band(ctx, y, n, sbits, B, nil, LM, nil, side, nil, fill >> u32(B))
			rebalance = sbits - (rebalance - ctx.remaining_bits)
			if rebalance > 3 << BITRES && itheta != 16384 do mbits += rebalance - (3 << BITRES)
			cm |= quant_band(ctx, x, n, mbits, B, lowband, LM, lowband_out, 1, lowband_scratch, fill)
		}
	}
	if ctx.resynth {
		if n != 2 do stereo_merge(x, y, mid, n)
		if inv do for j in 0 ..< n do y[j] = -y[j]
	}
	return cm
}

@(private = "file")
special_hybrid_folding :: proc "contextless" (norm, norm2: []f32, start, M: int, dual_stereo: bool) {
	n1 := M * int(eband5ms[start + 1] - eband5ms[start])
	n2 := M * int(eband5ms[start + 2] - eband5ms[start + 1])
	copy(norm[n1:n1 + n2 - n1], norm[2 * n1 - n2:2 * n1 - n2 + n2 - n1])
	if dual_stereo do copy(norm2[n1:n1 + n2 - n1], norm2[2 * n1 - n2:2 * n1 - n2 + n2 - n1])
}

quant_all_bands :: proc(encode: bool, start, end: int, x_: []f32, y_: []f32, collapse_masks: []u8, band_e: []f32, pulses: []i32, short_blocks: bool,
	spread: int, dual_stereo_: bool, intensity: int, tf_res: []i32, total_bits: i32, balance_: i32, ec: ^Range, LM: int, coded_bands: int,
	seed: ^u32, complexity: int, disable_inv: bool) {
	dual_stereo := dual_stereo_
	balance := balance_
	M := 1 << uint(LM)
	B := short_blocks ? M : 1
	C := y_ != nil ? 2 : 1
	norm_offset := M * int(eband5ms[start])
	theta_rdo := encode && y_ != nil && !dual_stereo && complexity >= 8
	resynth := !encode || theta_rdo
	norm_buf: [2 * 8 * 100]f32
	nlen := M * int(eband5ms[NB_EBANDS - 1]) - norm_offset
	norm := norm_buf[:nlen]
	norm2 := norm_buf[nlen:2 * nlen]
	scratch_buf: [8 * 22]f32
	lowband_scratch: []f32
	if encode && resynth {
		lowband_scratch = scratch_buf[:]
	} else {
		lowband_scratch = x_[M * int(eband5ms[NB_EBANDS - 1]):]
	}
	x_save, y_save, x_save2, y_save2, norm_save2: [8 * 22]f32
	lowband_offset := 0
	update_lowband := true
	ctx := Band_Ctx {
		band_e            = band_e,
		ec                = ec,
		encode            = encode,
		intensity         = intensity,
		seed              = seed^,
		spread            = spread,
		disable_inv       = disable_inv,
		resynth           = resynth,
		theta_round       = 0,
		avoid_split_noise = B > 1,
	}
	for i in start ..< end {
		ctx.i = i
		last := i == end - 1
		X := x_[M * int(eband5ms[i]):]
		Y: []f32
		if y_ != nil do Y = y_[M * int(eband5ms[i]):]
		n := M * int(eband5ms[i + 1]) - M * int(eband5ms[i])
		tell := i32(ec_tell_frac(ec))
		if i != start do balance -= tell
		remaining_bits := total_bits - tell - 1
		ctx.remaining_bits = remaining_bits
		b: i32
		if i <= coded_bands - 1 {
			curr_balance := balance / i32(min(3, coded_bands - i))
			b = max(0, min(16383, min(remaining_bits + 1, pulses[i] + curr_balance)))
		}
		if resynth && (M * int(eband5ms[i]) - n >= M * int(eband5ms[start]) || i == start + 1) && (update_lowband || lowband_offset == 0) do lowband_offset = i
		if i == start + 1 do special_hybrid_folding(norm, norm2, start, M, dual_stereo)
		tf_change := int(tf_res[i])
		ctx.tf_change = tf_change
		if i >= EFF_EBANDS {
			X = norm
			if y_ != nil do Y = norm
			lowband_scratch = nil
		}
		if last && !theta_rdo do lowband_scratch = nil
		effective_lowband := -1
		x_cm, y_cm: u32
		if lowband_offset != 0 && (spread != SPREAD_AGGRESSIVE || B > 1 || tf_change < 0) {
			effective_lowband = max(0, M * int(eband5ms[lowband_offset]) - norm_offset - n)
			fold_start := lowband_offset
			for {
				fold_start -= 1
				if M * int(eband5ms[fold_start]) <= effective_lowband + norm_offset do break
			}
			fold_end := lowband_offset - 1
			for {
				fold_end += 1
				if !(fold_end < i && M * int(eband5ms[fold_end]) < effective_lowband + norm_offset + n) do break
			}
			fold_i := fold_start
			for {
				x_cm |= u32(collapse_masks[fold_i * C + 0])
				y_cm |= u32(collapse_masks[fold_i * C + C - 1])
				fold_i += 1
				if fold_i >= fold_end do break
			}
		} else {
			x_cm = (1 << u32(B)) - 1
			y_cm = x_cm
		}
		if dual_stereo && i == intensity {
			dual_stereo = false
			if resynth do for j in 0 ..< M * int(eband5ms[i]) - norm_offset do norm[j] = 0.5 * (norm[j] + norm2[j])
		}
		lb := effective_lowband != -1 ? norm[effective_lowband:] : nil
		lb2 := effective_lowband != -1 ? norm2[effective_lowband:] : nil
		out1 := last ? nil : norm[M * int(eband5ms[i]) - norm_offset:]
		out2 := last ? nil : norm2[M * int(eband5ms[i]) - norm_offset:]
		if dual_stereo {
			x_cm = quant_band(&ctx, X, n, b / 2, B, lb, LM, out1, 1, lowband_scratch, i32(x_cm))
			y_cm = quant_band(&ctx, Y, n, b / 2, B, lb2, LM, out2, 1, lowband_scratch, i32(y_cm))
		} else {
			if Y != nil {
				if theta_rdo && i < intensity {
					w: [2]f32
					{
						ex := band_e[i]
						ey := band_e[i + NB_EBANDS]
						min_e := min(ex, ey)
						w = {ex + min_e / 3, ey + min_e / 3}
					}
					cm := x_cm | y_cm
					ec_save := ec^
					ctx_save := ctx
					copy(x_save[:n], X[:n])
					copy(y_save[:n], Y[:n])
					ctx.theta_round = -1
					x_cm = quant_band_stereo(&ctx, X, Y, n, b, B, lb, LM, out1, lowband_scratch, i32(cm))
					dist0 := w[0] * inner_prod(x_save[:], X, n) + w[1] * inner_prod(y_save[:], Y, n)
					cm2 := x_cm
					ec_save2 := ec^
					ctx_save2 := ctx
					copy(x_save2[:n], X[:n])
					copy(y_save2[:n], Y[:n])
					if !last do copy(norm_save2[:n], out1[:n])
					nstart := ec_save.offs
					nend := ec_save.storage
					bytes_save: [1275]u8
					save_bytes := int(nend - nstart)
					copy(bytes_save[:save_bytes], ec_save.buf[nstart:nend])
					ec^ = ec_save
					ctx = ctx_save
					copy(X[:n], x_save[:n])
					copy(Y[:n], y_save[:n])
					if i == start + 1 do special_hybrid_folding(norm, norm2, start, M, dual_stereo)
					ctx.theta_round = 1
					x_cm = quant_band_stereo(&ctx, X, Y, n, b, B, lb, LM, out1, lowband_scratch, i32(cm))
					dist1 := w[0] * inner_prod(x_save[:], X, n) + w[1] * inner_prod(y_save[:], Y, n)
					if dist0 >= dist1 {
						x_cm = cm2
						ec^ = ec_save2
						ctx = ctx_save2
						copy(X[:n], x_save2[:n])
						copy(Y[:n], y_save2[:n])
						if !last do copy(out1[:n], norm_save2[:n])
						copy(ec_save.buf[nstart:nend], bytes_save[:save_bytes])
					}
				} else {
					ctx.theta_round = 0
					x_cm = quant_band_stereo(&ctx, X, Y, n, b, B, lb, LM, out1, lowband_scratch, i32(x_cm | y_cm))
				}
			} else {
				x_cm = quant_band(&ctx, X, n, b, B, lb, LM, out1, 1, lowband_scratch, i32(x_cm | y_cm))
			}
			y_cm = x_cm
		}
		collapse_masks[i * C + 0] = u8(x_cm)
		collapse_masks[i * C + C - 1] = u8(y_cm)
		balance += pulses[i] + tell
		update_lowband = b > (i32(n) << BITRES)
		ctx.avoid_split_noise = false
	}
	seed^ = ctx.seed
}
