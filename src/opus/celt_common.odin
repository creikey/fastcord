package opus

// CELT shared pieces: mode constants, math, Laplace, PVQ codewords (cwrs),
// PVQ vector (vq), bit allocation (rate), energy (quant_bands), MDCT/FFT,
// pitch / LPC helpers, comb filter. Float path of the reference code.

import "core:math"

NB_EBANDS :: 21
OVERLAP :: 120
SHORT_MDCT_SIZE :: 120
MAX_LM :: 3
NB_ALLOC_VECTORS :: 11
EFF_EBANDS :: 21
PREEMPH :: f32(0.85000610)
MAX_PERIOD :: 1024
LPC_ORDER :: 24
COMBFILTER_MINPERIOD :: 15
COMBFILTER_MAXPERIOD :: 1024
SPREAD_NONE :: 0
SPREAD_LIGHT :: 1
SPREAD_NORMAL :: 2
SPREAD_AGGRESSIVE :: 3
MAX_FINE_BITS :: 8
FINE_OFFSET :: 21
QTHETA_OFFSET :: 4
QTHETA_OFFSET_TWOPHASE :: 16
LOG_MAX_PSEUDO :: 6
ALLOC_STEPS :: 6
EPSILON :: f32(1e-15)
VERY_SMALL :: f32(1e-30)
CELT_SIG_SCALE :: f32(32768)
SIG_SAT :: f32(300000000)
DB_SHIFT :: 10

@(rodata)
pred_coef := [4]f32{29440.0 / 32768, 26112.0 / 32768, 21248.0 / 32768, 16384.0 / 32768}
@(rodata)
beta_coef := [4]f32{30147.0 / 32768, 22282.0 / 32768, 12124.0 / 32768, 6554.0 / 32768}
BETA_INTRA :: f32(4915.0 / 32768)

// ---------------------------------------------------------------------------
// Math

frac_mul16 :: #force_inline proc "contextless" (a, b: i32) -> i32 {
	return (16384 + i32(i16(a)) * i32(i16(b))) >> 15
}

celt_lcg_rand :: #force_inline proc "contextless" (seed: u32) -> u32 {
	return 1664525 * seed + 1013904223
}

bitexact_cos :: proc "contextless" (x: i16) -> i16 {
	tmp := (4096 + i32(x) * i32(x)) >> 13
	x2 := i16(tmp)
	x2 = i16((32767 - i32(x2)) + frac_mul16(i32(x2), (-7651 + frac_mul16(i32(x2), (8277 + frac_mul16(-626, i32(x2)))))))
	return 1 + x2
}

bitexact_log2tan :: proc "contextless" (isin_, icos_: i32) -> i32 {
	lc := ec_ilog(u32(icos_))
	ls := ec_ilog(u32(isin_))
	icos := icos_ << u32(15 - lc)
	isin := isin_ << u32(15 - ls)
	return (ls - lc) * (1 << 11) + frac_mul16(isin, frac_mul16(isin, -2597) + 7932) - frac_mul16(icos, frac_mul16(icos, -2597) + 7932)
}

isqrt32 :: proc "contextless" (v: u32) -> u32 {
	val := v
	g: u32 = 0
	bshift := (ec_ilog(val) - 1) >> 1
	b := u32(1) << u32(bshift)
	for {
		t := ((g << 1) + b) << u32(bshift)
		if t <= val {
			g += b
			val -= t
		}
		b >>= 1
		bshift -= 1
		if bshift < 0 do break
	}
	return g
}

celt_exp2 :: #force_inline proc "contextless" (x: f32) -> f32 {return f32(math.exp(0.6931471805599453094 * f64(x)))}
celt_log2 :: #force_inline proc "contextless" (x: f32) -> f32 {return f32(1.442695040888963387 * math.ln(f64(x)))}
celt_sqrt :: #force_inline proc "contextless" (x: f32) -> f32 {return f32(math.sqrt(f64(x)))}
celt_rsqrt :: #force_inline proc "contextless" (x: f32) -> f32 {return 1 / celt_sqrt(x)}
celt_cos_norm :: #force_inline proc "contextless" (x: f32) -> f32 {return f32(math.cos(f64(0.5 * math.PI * x)))}

inner_prod :: #force_inline proc "contextless" (x, y: []f32, n: int) -> f32 {
	s: f32 = 0
	for i in 0 ..< n do s += x[i] * y[i]
	return s
}

// ---------------------------------------------------------------------------
// Laplace

LAPLACE_MINP :: 1
LAPLACE_NMIN :: 16

@(private = "file")
laplace_freq1 :: #force_inline proc "contextless" (fs0: u32, decay: i32) -> u32 {
	ft := 32768 - LAPLACE_MINP * (2 * LAPLACE_NMIN) - fs0
	return u32(i32(ft) * (16384 - decay) >> 15)
}

ec_laplace_decode :: proc "contextless" (dec: ^Range, fs_: u32, decay: i32) -> i32 {
	val: i32 = 0
	fs := fs_
	fm := ec_decode_bin(dec, 15)
	fl: u32 = 0
	if fm >= fs {
		val += 1
		fl = fs
		fs = laplace_freq1(fs, decay) + LAPLACE_MINP
		for fs > LAPLACE_MINP && fm >= fl + 2 * fs {
			fs *= 2
			fl += fs
			fs = u32(i32(fs - 2 * LAPLACE_MINP) * decay >> 15)
			fs += LAPLACE_MINP
			val += 1
		}
		if fs <= LAPLACE_MINP {
			di := i32((fm - fl) >> 1)
			val += di
			fl += u32(2 * di * LAPLACE_MINP)
		}
		if fm < fl + fs do val = -val
		else do fl += fs
	}
	ec_dec_update(dec, fl, min(fl + fs, 32768), 32768)
	return val
}

ec_laplace_encode :: proc "contextless" (enc: ^Range, value: ^i32, fs_: u32, decay: i32) {
	fl: u32 = 0
	fs := fs_
	val := value^
	if val != 0 {
		s: i32 = val < 0 ? -1 : 0
		val = (val + s) ~ s
		fl = fs
		fs = laplace_freq1(fs, decay)
		i: i32 = 1
		for ; fs > 0 && i < val; i += 1 {
			fs *= 2
			fl += fs + 2 * LAPLACE_MINP
			fs = u32(i32(fs) * decay >> 15)
		}
		if fs == 0 {
			ndi_max := i32(32768 - fl + LAPLACE_MINP - 1) >> 0
			ndi_max = (ndi_max - s) >> 1
			di := min(val - i, ndi_max - 1)
			fl += u32((2 * di + 1 + s) * LAPLACE_MINP)
			fs = min(LAPLACE_MINP, 32768 - fl)
			value^ = (i + di + s) ~ s
		} else {
			fs += LAPLACE_MINP
			fl += fs & u32(~s)
		}
	}
	ec_encode_bin(enc, fl, fl + fs, 15)
}

// ---------------------------------------------------------------------------
// CWRS (PVQ codeword index <-> pulse vector)

@(rodata)
PVQ_ROW := [15]i32{0, 176, 351, 525, 698, 870, 1041, 1131, 1178, 1207, 1226, 1240, 1248, 1254, 1257}

pvq_u :: #force_inline proc "contextless" (n, k: i32) -> u32 {
	a, b := min(n, k), max(n, k)
	return CELT_PVQ_U_DATA[PVQ_ROW[a] + b]
}

pvq_v :: #force_inline proc "contextless" (n, k: i32) -> u32 {
	return pvq_u(n, k) + pvq_u(n, k + 1)
}

@(private = "file")
row :: #force_inline proc "contextless" (n, i: i32) -> u32 {return CELT_PVQ_U_DATA[PVQ_ROW[n] + i]}

@(private = "file")
cwrsi :: proc "contextless" (n_: i32, k_: i32, i_: u32, y: []i32) -> f32 {
	n, k, i := n_, k_, i_
	yy: f32 = 0
	yi := 0
	p: u32
	s, k0: i32
	val: i32
	for n > 2 {
		q: u32
		if k >= n {
			p = row(n, k + 1)
			s = -i32(i >= p)
			i -= p & u32(s)
			k0 = k
			q = row(n, n)
			if q > i {
				k = n
				for {
					k -= 1
					p = row(k, n)
					if p <= i do break
				}
			} else {
				p = row(n, k)
				for p > i {
					k -= 1
					p = row(n, k)
				}
			}
			i -= p
			val = (k0 - k + s) ~ s
			y[yi] = val
			yi += 1
			yy += f32(val) * f32(val)
		} else {
			p = row(k, n)
			q = row(k + 1, n)
			if p <= i && i < q {
				i -= p
				y[yi] = 0
				yi += 1
			} else {
				s = -i32(i >= q)
				i -= q & u32(s)
				k0 = k
				for {
					k -= 1
					p = row(k, n)
					if p <= i do break
				}
				i -= p
				val = (k0 - k + s) ~ s
				y[yi] = val
				yi += 1
				yy += f32(val) * f32(val)
			}
		}
		n -= 1
	}
	p = u32(2 * k + 1)
	s = -i32(i >= p)
	i -= p & u32(s)
	k0 = k
	k = i32((i + 1) >> 1)
	if k != 0 do i -= u32(2 * k - 1)
	val = (k0 - k + s) ~ s
	y[yi] = val
	yi += 1
	yy += f32(val) * f32(val)
	s = -i32(i)
	val = (k + s) ~ s
	y[yi] = val
	yy += f32(val) * f32(val)
	return yy
}

decode_pulses :: proc "contextless" (y: []i32, n, k: i32, dec: ^Range) -> f32 {
	return cwrsi(n, k, ec_dec_uint(dec, pvq_v(n, k)), y)
}

@(private = "file")
icwrs :: proc "contextless" (n: i32, y: []i32) -> u32 {
	j := n - 1
	i := u32(y[j] < 0)
	k := abs(y[j])
	for {
		j -= 1
		i += pvq_u(n - j, k)
		k += abs(y[j])
		if y[j] < 0 do i += pvq_u(n - j, k + 1)
		if j <= 0 do break
	}
	return i
}

encode_pulses :: proc "contextless" (y: []i32, n, k: i32, enc: ^Range) {
	ec_enc_uint(enc, icwrs(n, y), pvq_v(n, k))
}

// ---------------------------------------------------------------------------
// VQ

@(private = "file")
exp_rotation1 :: proc "contextless" (x: []f32, len, stride: int, c, s: f32) {
	ms := -s
	for i in 0 ..< len - stride {
		x1 := x[i]
		x2 := x[i + stride]
		x[i + stride] = c * x2 + s * x1
		x[i] = c * x1 + ms * x2
	}
	for i := len - 2 * stride - 1; i >= 0; i -= 1 {
		x1 := x[i]
		x2 := x[i + stride]
		x[i + stride] = c * x2 + s * x1
		x[i] = c * x1 + ms * x2
	}
}

exp_rotation :: proc "contextless" (x: []f32, len_: int, dir: int, stride: int, k: int, spread: int) {
	SPREAD_FACTOR := [3]int{15, 10, 5}
	len := len_
	if 2 * k >= len || spread == SPREAD_NONE do return
	factor := SPREAD_FACTOR[spread - 1]
	gain := f32(len) / f32(len + factor * k)
	theta := 0.5 * gain * gain
	c := celt_cos_norm(theta)
	s := celt_cos_norm(1 - theta)
	stride2 := 0
	if len >= 8 * stride {
		stride2 = 1
		for (stride2 * stride2 + stride2) * stride + (stride >> 2) < len do stride2 += 1
	}
	len /= stride
	for i in 0 ..< stride {
		xs := x[i * len:]
		if dir < 0 {
			if stride2 != 0 do exp_rotation1(xs, len, stride2, s, c)
			exp_rotation1(xs, len, 1, c, s)
		} else {
			exp_rotation1(xs, len, 1, c, -s)
			if stride2 != 0 do exp_rotation1(xs, len, stride2, s, -c)
		}
	}
}

@(private = "file")
normalise_residual :: proc "contextless" (iy: []i32, x: []f32, n: int, ryy: f32, gain: f32) {
	g := celt_rsqrt(ryy) * gain
	for i in 0 ..< n do x[i] = g * f32(iy[i])
}

@(private = "file")
extract_collapse_mask :: proc "contextless" (iy: []i32, n, b: int) -> u32 {
	if b <= 1 do return 1
	n0 := n / b
	mask: u32 = 0
	for i in 0 ..< b {
		tmp: i32 = 0
		for j in 0 ..< n0 do tmp |= iy[i * n0 + j]
		if tmp != 0 do mask |= 1 << u32(i)
	}
	return mask
}

alg_unquant :: proc(x: []f32, n, k, spread, b: int, dec: ^Range, gain: f32) -> u32 {
	iy: [176]i32
	ryy := decode_pulses(iy[:n], i32(n), i32(k), dec)
	normalise_residual(iy[:], x, n, ryy, gain)
	exp_rotation(x, n, -1, b, k, spread)
	return extract_collapse_mask(iy[:], n, b)
}

op_pvq_search :: proc "contextless" (x: []f32, iy: []i32, k, n: int) -> f32 {
	y: [176]f32
	signx: [176]bool
	for j in 0 ..< n {
		signx[j] = x[j] < 0
		x[j] = abs(x[j])
		iy[j] = 0
		y[j] = 0
	}
	xy, yy: f32 = 0, 0
	pulses_left := k
	if k > (n >> 1) {
		sum: f32 = 0
		for j in 0 ..< n do sum += x[j]
		if !(sum > EPSILON && sum < 64) {
			x[0] = 1
			for j in 1 ..< n do x[j] = 0
			sum = 1
		}
		rcp := (f32(k) + 0.8) * (1 / sum)
		for j in 0 ..< n {
			iy[j] = i32(math.floor(rcp * x[j]))
			y[j] = f32(iy[j])
			yy += y[j] * y[j]
			xy += x[j] * y[j]
			y[j] *= 2
			pulses_left -= int(iy[j])
		}
	}
	if pulses_left > n + 3 {
		tmp := f32(pulses_left)
		yy += tmp * tmp
		yy += tmp * y[0]
		iy[0] += i32(pulses_left)
		pulses_left = 0
	}
	for _ in 0 ..< pulses_left {
		best_id := 0
		yy += 1
		rxy := xy + x[0]
		ryy := yy + y[0]
		rxy = rxy * rxy
		best_den := ryy
		best_num := rxy
		for j in 1 ..< n {
			rxy = xy + x[j]
			ryy = yy + y[j]
			rxy = rxy * rxy
			if best_den * rxy > ryy * best_num {
				best_den = ryy
				best_num = rxy
				best_id = j
			}
		}
		xy += x[best_id]
		yy += y[best_id]
		y[best_id] += 2
		iy[best_id] += 1
	}
	for j in 0 ..< n {
		if signx[j] do iy[j] = -iy[j]
	}
	return yy
}

alg_quant :: proc(x: []f32, n, k, spread, b: int, enc: ^Range, gain: f32, resynth: bool) -> u32 {
	iy: [180]i32
	exp_rotation(x, n, 1, b, k, spread)
	yy := op_pvq_search(x, iy[:], k, n)
	encode_pulses(iy[:n], i32(n), i32(k), enc)
	if resynth {
		normalise_residual(iy[:], x, n, yy, gain)
		exp_rotation(x, n, -1, b, k, spread)
	}
	return extract_collapse_mask(iy[:], n, b)
}

renormalise_vector :: proc "contextless" (x: []f32, n: int, gain: f32) {
	e := EPSILON + inner_prod(x, x, n)
	g := celt_rsqrt(e) * gain
	for i in 0 ..< n do x[i] *= g
}

stereo_itheta :: proc "contextless" (x, y: []f32, stereo: bool, n: int) -> i32 {
	emid, eside: f32 = EPSILON, EPSILON
	if stereo {
		for i in 0 ..< n {
			m := x[i] + y[i]
			s := x[i] - y[i]
			emid += m * m
			eside += s * s
		}
	} else {
		emid += inner_prod(x, x, n)
		eside += inner_prod(y, y, n)
	}
	mid := celt_sqrt(emid)
	side := celt_sqrt(eside)
	return i32(math.floor(0.5 + 16384 * 0.63662 * fast_atan2f(side, mid)))
}

fast_atan2f :: proc "contextless" (y, x: f32) -> f32 {
	cA :: f32(0.43157974)
	cB :: f32(0.67848403)
	cC :: f32(0.08595542)
	cE :: f32(math.PI / 2)
	x2 := x * x
	y2 := y * y
	if x2 + y2 < 1e-18 do return 0
	if x2 < y2 {
		den := (y2 + cB * x2) * (y2 + cC * x2)
		return -x * y * (y2 + cA * x2) / den + (y < 0 ? -cE : cE)
	}
	den := (x2 + cB * y2) * (x2 + cC * y2)
	return x * y * (x2 + cA * y2) / den + (y < 0 ? -cE : cE) - (x * y < 0 ? -cE : cE)
}

// ---------------------------------------------------------------------------
// Rate allocation

get_pulses :: #force_inline proc "contextless" (i: i32) -> i32 {
	return i < 8 ? i : (8 + (i & 7)) << u32((i >> 3) - 1)
}

@(private = "file")
cache_ptr :: #force_inline proc "contextless" (lm, band: i32) -> []u8 {
	return cache_bits50[cache_index50[(lm + 1) * NB_EBANDS + band]:]
}

bits2pulses :: proc "contextless" (band, lm, bits_: i32) -> i32 {
	cache := cache_ptr(lm, band)
	lo: i32 = 0
	hi := i32(cache[0])
	bits := bits_ - 1
	for _ in 0 ..< LOG_MAX_PSEUDO {
		mid := (lo + hi + 1) >> 1
		if i32(cache[mid]) >= bits do hi = mid
		else do lo = mid
	}
	if bits - (lo == 0 ? -1 : i32(cache[lo])) <= i32(cache[hi]) - bits do return lo
	return hi
}

pulses2bits :: proc "contextless" (band, lm, pulses: i32) -> i32 {
	cache := cache_ptr(lm, band)
	return pulses == 0 ? 0 : i32(cache[pulses]) + 1
}

init_caps :: proc "contextless" (cap: []i32, lm, c: i32) {
	for i in 0 ..< NB_EBANDS {
		n := i32(eband5ms[i + 1] - eband5ms[i]) << u32(lm)
		cap[i] = (i32(cache_caps50[NB_EBANDS * (2 * lm + c - 1) + i32(i)]) + 64) * c * n >> 2
	}
}

@(private = "file")
interp_bits2pulses :: proc "contextless" (start, end, skip_start: i32, bits1, bits2, thresh, cap: []i32, total_: i32, balance_out: ^i32,
	skip_rsv: i32, intensity: ^i32, intensity_rsv_: i32, dual_stereo: ^i32, dual_stereo_rsv_: i32, bits, ebits, fine_priority: []i32,
	C, LM: i32, ec: ^Range, encode: bool, prev: i32, signal_bandwidth: i32) -> i32 {
	total := total_
	intensity_rsv := intensity_rsv_
	dual_stereo_rsv := dual_stereo_rsv_
	alloc_floor := C << BITRES
	stereo: i32 = C > 1 ? 1 : 0
	log_m := LM << BITRES
	lo: i32 = 0
	hi: i32 = 1 << ALLOC_STEPS
	eb :: proc "contextless" (i: i32) -> i32 {return i32(eband5ms[i])}
	for _ in 0 ..< ALLOC_STEPS {
		mid := (lo + hi) >> 1
		psum: i32 = 0
		done := false
		for j := end - 1; j >= start; j -= 1 {
			tmp := bits1[j] + (mid * bits2[j] >> ALLOC_STEPS)
			if tmp >= thresh[j] || done {
				done = true
				psum += min(tmp, cap[j])
			} else if tmp >= alloc_floor {
				psum += alloc_floor
			}
		}
		if psum > total do hi = mid
		else do lo = mid
	}
	psum: i32 = 0
	done := false
	for j := end - 1; j >= start; j -= 1 {
		tmp := bits1[j] + (lo * bits2[j] >> ALLOC_STEPS)
		if tmp < thresh[j] && !done {
			tmp = tmp >= alloc_floor ? alloc_floor : 0
		} else {
			done = true
		}
		tmp = min(tmp, cap[j])
		bits[j] = tmp
		psum += tmp
	}
	coded_bands := end
	for ;; coded_bands -= 1 {
		j := coded_bands - 1
		if j <= skip_start {
			total += skip_rsv
			break
		}
		left := total - psum
		percoeff := left / (eb(coded_bands) - eb(start))
		left -= (eb(coded_bands) - eb(start)) * percoeff
		rem := max(left - (eb(j) - eb(start)), 0)
		band_width := eb(coded_bands) - eb(j)
		band_bits := bits[j] + percoeff * band_width + rem
		if band_bits >= max(thresh[j], alloc_floor + (1 << BITRES)) {
			if encode {
				depth_threshold: i32 = 0
				if coded_bands > 17 do depth_threshold = j < prev ? 7 : 9
				if coded_bands <= start + 2 || (band_bits > (depth_threshold * band_width << u32(LM) << BITRES) >> 4 && j <= signal_bandwidth) {
					ec_enc_bit_logp(ec, true, 1)
					break
				}
				ec_enc_bit_logp(ec, false, 1)
			} else if ec_dec_bit_logp(ec, 1) {
				break
			}
			psum += 1 << BITRES
			band_bits -= 1 << BITRES
		}
		psum -= bits[j] + intensity_rsv
		if intensity_rsv > 0 do intensity_rsv = i32(LOG2_FRAC_TABLE[j - start])
		psum += intensity_rsv
		if band_bits >= alloc_floor {
			psum += alloc_floor
			bits[j] = alloc_floor
		} else {
			bits[j] = 0
		}
	}
	if intensity_rsv > 0 {
		if encode {
			intensity^ = min(intensity^, coded_bands)
			ec_enc_uint(ec, u32(intensity^ - start), u32(coded_bands + 1 - start))
		} else {
			intensity^ = start + i32(ec_dec_uint(ec, u32(coded_bands + 1 - start)))
		}
	} else {
		intensity^ = 0
	}
	if intensity^ <= start {
		total += dual_stereo_rsv
		dual_stereo_rsv = 0
	}
	if dual_stereo_rsv > 0 {
		if encode do ec_enc_bit_logp(ec, dual_stereo^ != 0, 1)
		else do dual_stereo^ = i32(ec_dec_bit_logp(ec, 1))
	} else {
		dual_stereo^ = 0
	}
	left := total - psum
	percoeff := left / (eb(coded_bands) - eb(start))
	left -= (eb(coded_bands) - eb(start)) * percoeff
	for j in start ..< coded_bands do bits[j] += percoeff * (eb(j + 1) - eb(j))
	for j in start ..< coded_bands {
		tmp := min(left, eb(j + 1) - eb(j))
		bits[j] += tmp
		left -= tmp
	}
	balance: i32 = 0
	j := start
	for ; j < coded_bands; j += 1 {
		n0 := eb(j + 1) - eb(j)
		n := n0 << u32(LM)
		bit := bits[j] + balance
		excess: i32
		if n > 1 {
			excess = max(bit - cap[j], 0)
			bits[j] = bit - excess
			den := C * n + ((C == 2 && n > 2 && dual_stereo^ == 0 && j < intensity^) ? 1 : 0)
			nclogn := den * (i32(logN400[j]) + log_m)
			offset := (nclogn >> 1) - den * FINE_OFFSET
			if n == 2 do offset += den << BITRES >> 2
			if bits[j] + offset < den * 2 << BITRES {
				offset += nclogn >> 2
			} else if bits[j] + offset < den * 3 << BITRES {
				offset += nclogn >> 3
			}
			ebits[j] = max(0, bits[j] + offset + (den << (BITRES - 1)))
			ebits[j] = (ebits[j] / den) >> BITRES
			if C * ebits[j] > (bits[j] >> BITRES) do ebits[j] = bits[j] >> u32(stereo) >> BITRES
			ebits[j] = min(ebits[j], MAX_FINE_BITS)
			fine_priority[j] = i32(ebits[j] * (den << BITRES) >= bits[j] + offset)
			bits[j] -= C * ebits[j] << BITRES
		} else {
			excess = max(0, bit - (C << BITRES))
			bits[j] = bit - excess
			ebits[j] = 0
			fine_priority[j] = 1
		}
		if excess > 0 {
			extra_fine := min(excess >> u32(stereo + BITRES), MAX_FINE_BITS - ebits[j])
			ebits[j] += extra_fine
			extra_bits := extra_fine * C << BITRES
			fine_priority[j] = i32(extra_bits >= excess - balance)
			excess -= extra_bits
		}
		balance = excess
	}
	balance_out^ = balance
	for ; j < end; j += 1 {
		ebits[j] = bits[j] >> u32(stereo) >> BITRES
		bits[j] = 0
		fine_priority[j] = i32(ebits[j] < 1)
	}
	return coded_bands
}

clt_compute_allocation :: proc "contextless" (start, end: i32, offsets, cap: []i32, alloc_trim: i32, intensity, dual_stereo: ^i32,
	total_: i32, balance: ^i32, pulses, ebits, fine_priority: []i32, C, LM: i32, ec: ^Range, encode: bool, prev, signal_bandwidth: i32) -> i32 {
	total := max(total_, 0)
	length :: NB_EBANDS
	skip_start := start
	skip_rsv: i32 = total >= 1 << BITRES ? 1 << BITRES : 0
	total -= skip_rsv
	intensity_rsv, dual_stereo_rsv: i32 = 0, 0
	if C == 2 {
		intensity_rsv = i32(LOG2_FRAC_TABLE[end - start])
		if intensity_rsv > total {
			intensity_rsv = 0
		} else {
			total -= intensity_rsv
			dual_stereo_rsv = total >= 1 << BITRES ? 1 << BITRES : 0
			total -= dual_stereo_rsv
		}
	}
	bits1, bits2, thresh, trim_offset: [NB_EBANDS]i32
	eb :: proc "contextless" (i: i32) -> i32 {return i32(eband5ms[i])}
	for j in start ..< end {
		thresh[j] = max(C << BITRES, (3 * (eb(j + 1) - eb(j)) << u32(LM) << BITRES) >> 4)
		trim_offset[j] = C * (eb(j + 1) - eb(j)) * (alloc_trim - 5 - LM) * (end - j - 1) * (1 << u32(LM + BITRES)) >> 6
		if (eb(j + 1) - eb(j)) << u32(LM) == 1 do trim_offset[j] -= C << BITRES
	}
	lo: i32 = 1
	hi: i32 = NB_ALLOC_VECTORS - 1
	for {
		done := false
		psum: i32 = 0
		mid := (lo + hi) >> 1
		for j := end - 1; j >= start; j -= 1 {
			n := eb(j + 1) - eb(j)
			bitsj := C * n * i32(band_allocation[mid * length + j]) << u32(LM) >> 2
			if bitsj > 0 do bitsj = max(0, bitsj + trim_offset[j])
			bitsj += offsets[j]
			if bitsj >= thresh[j] || done {
				done = true
				psum += min(bitsj, cap[j])
			} else if bitsj >= C << BITRES {
				psum += C << BITRES
			}
		}
		if psum > total do hi = mid - 1
		else do lo = mid + 1
		if lo > hi do break
	}
	hi = lo
	lo -= 1
	for j in start ..< end {
		n := eb(j + 1) - eb(j)
		bits1j := C * n * i32(band_allocation[lo * length + j]) << u32(LM) >> 2
		bits2j := hi >= NB_ALLOC_VECTORS ? cap[j] : C * n * i32(band_allocation[hi * length + j]) << u32(LM) >> 2
		if bits1j > 0 do bits1j = max(0, bits1j + trim_offset[j])
		if bits2j > 0 do bits2j = max(0, bits2j + trim_offset[j])
		if lo > 0 do bits1j += offsets[j]
		bits2j += offsets[j]
		if offsets[j] > 0 do skip_start = j
		bits2j = max(0, bits2j - bits1j)
		bits1[j] = bits1j
		bits2[j] = bits2j
	}
	return interp_bits2pulses(start, end, skip_start, bits1[:], bits2[:], thresh[:], cap, total, balance, skip_rsv, intensity, intensity_rsv,
		dual_stereo, dual_stereo_rsv, pulses, ebits, fine_priority, C, LM, ec, encode, prev, signal_bandwidth)
}

// ---------------------------------------------------------------------------
// Energy (de)quantization

unquant_coarse_energy :: proc "contextless" (start, end: i32, old_ebands: []f32, intra: bool, dec: ^Range, C, LM: i32) {
	prob_model := e_prob_model[LM][intra ? 1 : 0][:]
	prev := [2]f32{0, 0}
	coef, beta: f32
	if intra {
		coef = 0
		beta = BETA_INTRA
	} else {
		beta = beta_coef[LM]
		coef = pred_coef[LM]
	}
	budget := i32(dec.storage * 8)
	for i in start ..< end {
		for c in 0 ..< C {
			qi: i32
			tell := ec_tell(dec)
			if budget - tell >= 15 {
				pi := 2 * min(i, 20)
				qi = ec_laplace_decode(dec, u32(prob_model[pi]) << 7, i32(prob_model[pi + 1]) << 6)
			} else if budget - tell >= 2 {
				qi = ec_dec_icdf(dec, small_energy_icdf[:], 2)
				qi = (qi >> 1) ~ -(qi & 1)
			} else if budget - tell >= 1 {
				qi = -i32(ec_dec_bit_logp(dec, 1))
			} else {
				qi = -1
			}
			q := f32(qi)
			idx := i + c * NB_EBANDS
			old_ebands[idx] = max(-9.0, old_ebands[idx])
			tmp := coef * old_ebands[idx] + prev[c] + q
			old_ebands[idx] = tmp
			prev[c] = prev[c] + q - beta * q
		}
	}
}

unquant_fine_energy :: proc "contextless" (start, end: i32, old_ebands: []f32, fine_quant: []i32, dec: ^Range, C: i32) {
	for i in start ..< end {
		if fine_quant[i] <= 0 do continue
		for c in 0 ..< C {
			q2 := ec_dec_bits(dec, u32(fine_quant[i]))
			offset := (f32(q2) + 0.5) * f32(i32(1) << u32(14 - fine_quant[i])) * (1.0 / 16384) - 0.5
			old_ebands[i + c * NB_EBANDS] += offset
		}
	}
}

unquant_energy_finalise :: proc "contextless" (start, end: i32, old_ebands: []f32, fine_quant, fine_priority: []i32, bits_left_: i32, dec: ^Range, C: i32) {
	bits_left := bits_left_
	for prio in 0 ..< i32(2) {
		for i := start; i < end && bits_left >= C; i += 1 {
			if fine_quant[i] >= MAX_FINE_BITS || fine_priority[i] != prio do continue
			for c in 0 ..< C {
				q2 := ec_dec_bits(dec, 1)
				offset := (f32(q2) - 0.5) * f32(i32(1) << u32(14 - fine_quant[i] - 1)) * (1.0 / 16384)
				old_ebands[i + c * NB_EBANDS] += offset
				bits_left -= 1
			}
		}
	}
}

// ---------------------------------------------------------------------------
// FFT / MDCT (kiss_fft, float)

Fft_State :: struct {
	nfft:    int,
	scale:   f32,
	shift:   int,
	factors: [16]i16,
	bitrev:  []i16,
}

@(rodata)
fft_states := [4]Fft_State {
	{480, 0.002083333, -1, {5, 96, 3, 32, 4, 8, 2, 4, 4, 1, 0, 0, 0, 0, 0, 0}, nil},
	{240, 0.004166667, 1, {5, 48, 3, 16, 4, 4, 4, 1, 0, 0, 0, 0, 0, 0, 0, 0}, nil},
	{120, 0.008333333, 2, {5, 24, 3, 8, 2, 4, 4, 1, 0, 0, 0, 0, 0, 0, 0, 0}, nil},
	{60, 0.016666667, 3, {5, 12, 3, 4, 4, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}, nil},
}

@(private = "file")
fft_bitrev :: proc "contextless" (shift: int) -> []i16 {
	switch shift {
	case 0: return fft_bitrev480[:]
	case 1: return fft_bitrev240[:]
	case 2: return fft_bitrev120[:]
	}
	return fft_bitrev60[:]
}

Cpx :: [2]f32

@(private = "file")
cmul :: #force_inline proc "contextless" (a: Cpx, b: [2]f32) -> Cpx {
	return {a[0] * b[0] - a[1] * b[1], a[0] * b[1] + a[1] * b[0]}
}

@(private = "file")
kf_bfly2 :: proc "contextless" (fout: []Cpx, m, n: int) {
	tw :: f32(0.7071067812)
	base := 0
	for _ in 0 ..< n {
		f := fout[base:]
		t := f[4]
		f[4] = f[0] - t
		f[0] += t
		t = {(f[5][0] + f[5][1]) * tw, (f[5][1] - f[5][0]) * tw}
		f[5] = f[1] - t
		f[1] += t
		t = {f[6][1], -f[6][0]}
		f[6] = f[2] - t
		f[2] += t
		t = {(f[7][1] - f[7][0]) * tw, -(f[7][1] + f[7][0]) * tw}
		f[7] = f[3] - t
		f[3] += t
		base += 8
	}
}

@(private = "file")
kf_bfly4 :: proc "contextless" (fout: []Cpx, fstride: int, tw: []Cpx, m, n, mm: int) {
	if m == 1 {
		base := 0
		for _ in 0 ..< n {
			f := fout[base:]
			s0 := f[0] - f[2]
			f[0] += f[2]
			s1 := f[1] + f[3]
			f[2] = f[0] - s1
			f[0] += s1
			s1 = f[1] - f[3]
			f[1] = {s0[0] + s1[1], s0[1] - s1[0]}
			f[3] = {s0[0] - s1[1], s0[1] + s1[0]}
			base += 4
		}
		return
	}
	m2, m3 := 2 * m, 3 * m
	for i in 0 ..< n {
		f := fout[i * mm:]
		t1, t2, t3 := 0, 0, 0
		for j in 0 ..< m {
			s0 := cmul(f[j + m], tw[t1])
			s1 := cmul(f[j + m2], tw[t2])
			s2 := cmul(f[j + m3], tw[t3])
			s5 := f[j] - s1
			f[j] += s1
			s3 := s0 + s2
			s4 := s0 - s2
			f[j + m2] = f[j] - s3
			t1 += fstride
			t2 += fstride * 2
			t3 += fstride * 3
			f[j] += s3
			f[j + m] = {s5[0] + s4[1], s5[1] - s4[0]}
			f[j + m3] = {s5[0] - s4[1], s5[1] + s4[0]}
		}
	}
}

@(private = "file")
kf_bfly3 :: proc "contextless" (fout: []Cpx, fstride: int, tw: []Cpx, m, n, mm: int) {
	m2 := 2 * m
	epi3 := tw[fstride * m]
	for i in 0 ..< n {
		f := fout[i * mm:]
		t1, t2 := 0, 0
		for j in 0 ..< m {
			s1 := cmul(f[j + m], tw[t1])
			s2 := cmul(f[j + m2], tw[t2])
			s3 := s1 + s2
			s0 := s1 - s2
			t1 += fstride
			t2 += fstride * 2
			f[j + m] = {f[j][0] - s3[0] * 0.5, f[j][1] - s3[1] * 0.5}
			s0 *= epi3[1]
			f[j] += s3
			f[j + m2] = {f[j + m][0] + s0[1], f[j + m][1] - s0[0]}
			f[j + m] = {f[j + m][0] - s0[1], f[j + m][1] + s0[0]}
		}
	}
}

@(private = "file")
kf_bfly5 :: proc "contextless" (fout: []Cpx, fstride: int, tw: []Cpx, m, n, mm: int) {
	ya := tw[fstride * m]
	yb := tw[fstride * 2 * m]
	for i in 0 ..< n {
		f := fout[i * mm:]
		for u in 0 ..< m {
			s0 := f[u]
			s1 := cmul(f[u + m], tw[u * fstride])
			s2 := cmul(f[u + 2 * m], tw[2 * u * fstride])
			s3 := cmul(f[u + 3 * m], tw[3 * u * fstride])
			s4 := cmul(f[u + 4 * m], tw[4 * u * fstride])
			s7 := s1 + s4
			s10 := s1 - s4
			s8 := s2 + s3
			s9 := s2 - s3
			f[u] = {f[u][0] + (s7[0] + s8[0]), f[u][1] + (s7[1] + s8[1])}
			s5 := Cpx{s0[0] + (s7[0] * ya[0] + s8[0] * yb[0]), s0[1] + (s7[1] * ya[0] + s8[1] * yb[0])}
			s6 := Cpx{s10[1] * ya[1] + s9[1] * yb[1], -(s10[0] * ya[1] + s9[0] * yb[1])}
			f[u + m] = s5 - s6
			f[u + 4 * m] = s5 + s6
			s11 := Cpx{s0[0] + (s7[0] * yb[0] + s8[0] * ya[0]), s0[1] + (s7[1] * yb[0] + s8[1] * ya[0])}
			s12 := Cpx{s9[1] * ya[1] - s10[1] * yb[1], s10[0] * yb[1] - s9[0] * ya[1]}
			f[u + 2 * m] = s11 + s12
			f[u + 3 * m] = s11 - s12
		}
	}
}

opus_fft_impl :: proc "contextless" (st: ^Fft_State, fout: []Cpx) {
	fstride: [8]int
	shift := st.shift > 0 ? st.shift : 0
	fstride[0] = 1
	L := 0
	m: int
	for {
		p := int(st.factors[2 * L])
		m = int(st.factors[2 * L + 1])
		fstride[L + 1] = fstride[L] * p
		L += 1
		if m == 1 do break
	}
	tw := (transmute([]Cpx)fft_twiddles48000_960[:])
	m = int(st.factors[2 * L - 1])
	for i := L - 1; i >= 0; i -= 1 {
		m2 := i != 0 ? int(st.factors[2 * i - 1]) : 1
		switch st.factors[2 * i] {
		case 2: kf_bfly2(fout, m, fstride[i])
		case 4: kf_bfly4(fout, fstride[i] << uint(shift), tw, m, fstride[i], m2)
		case 3: kf_bfly3(fout, fstride[i] << uint(shift), tw, m, fstride[i], m2)
		case 5: kf_bfly5(fout, fstride[i] << uint(shift), tw, m, fstride[i], m2)
		}
		m = m2
	}
}

// Inverse MDCT of `in` (stride `stride`) into out[0 .. N/2+overlap), windowed overlap.
clt_mdct_backward :: proc "contextless" (in_: []f32, out: []f32, overlap: int, shift: int, stride: int) {
	n := 1920
	trig := mdct_twiddles960[:]
	for _ in 0 ..< shift {
		n >>= 1
		trig = trig[n:]
	}
	n2 := n >> 1
	n4 := n >> 2
	st := &fft_states[shift]
	bitrev := fft_bitrev(shift)
	yp := out[overlap >> 1:]
	{
		xp1 := 0
		xp2 := stride * (n2 - 1)
		for i in 0 ..< n4 {
			rev := int(bitrev[i])
			yr := in_[xp2] * trig[i] + in_[xp1] * trig[n4 + i]
			yi := in_[xp1] * trig[i] - in_[xp2] * trig[n4 + i]
			yp[2 * rev + 1] = yr
			yp[2 * rev] = yi
			xp1 += 2 * stride
			xp2 -= 2 * stride
		}
	}
	opus_fft_impl(st, (transmute([]Cpx)yp)[:n4])
	{
		y0 := 0
		y1 := n2 - 2
		for i in 0 ..< (n4 + 1) >> 1 {
			re := yp[y0 + 1]
			im := yp[y0]
			t0 := trig[i]
			t1 := trig[n4 + i]
			yr := re * t0 + im * t1
			yi := re * t1 - im * t0
			re = yp[y1 + 1]
			im = yp[y1]
			yp[y0] = yr
			yp[y1 + 1] = yi
			t0 = trig[n4 - i - 1]
			t1 = trig[n2 - i - 1]
			yr = re * t0 + im * t1
			yi = re * t1 - im * t0
			yp[y1] = yr
			yp[y0 + 1] = yi
			y0 += 2
			y1 -= 2
		}
	}
	{
		xp1 := overlap - 1
		yp1 := 0
		wp1 := 0
		wp2 := overlap - 1
		for _ in 0 ..< overlap / 2 {
			x1 := out[xp1]
			x2 := out[yp1]
			out[yp1] = window120[wp2] * x2 - window120[wp1] * x1
			out[xp1] = window120[wp1] * x2 + window120[wp2] * x1
			yp1 += 1
			xp1 -= 1
			wp1 += 1
			wp2 -= 1
		}
	}
}

// Forward MDCT (encoder).
clt_mdct_forward :: proc "contextless" (in_: []f32, out: []f32, overlap: int, shift: int, stride: int) {
	n := 1920
	trig := mdct_twiddles960[:]
	for _ in 0 ..< shift {
		n >>= 1
		trig = trig[n:]
	}
	n2 := n >> 1
	n4 := n >> 2
	st := &fft_states[shift]
	bitrev := fft_bitrev(shift)
	scale := st.scale
	f: [960]f32
	f2: [480]Cpx
	{
		xp1 := overlap >> 1
		xp2 := n2 - 1 + (overlap >> 1)
		yp := 0
		wp1 := overlap >> 1
		wp2 := (overlap >> 1) - 1
		i := 0
		for ; i < (overlap + 3) >> 2; i += 1 {
			f[yp] = window120[wp2] * in_[xp1 + n2] + window120[wp1] * in_[xp2]
			f[yp + 1] = window120[wp1] * in_[xp1] - window120[wp2] * in_[xp2 - n2]
			yp += 2
			xp1 += 2
			xp2 -= 2
			wp1 += 2
			wp2 -= 2
		}
		wp1 = 0
		wp2 = overlap - 1
		for ; i < n4 - ((overlap + 3) >> 2); i += 1 {
			f[yp] = in_[xp2]
			f[yp + 1] = in_[xp1]
			yp += 2
			xp1 += 2
			xp2 -= 2
		}
		for ; i < n4; i += 1 {
			f[yp] = -window120[wp1] * in_[xp1 - n2] + window120[wp2] * in_[xp2]
			f[yp + 1] = window120[wp2] * in_[xp1] + window120[wp1] * in_[xp2 + n2]
			yp += 2
			xp1 += 2
			xp2 -= 2
			wp1 += 2
			wp2 -= 2
		}
	}
	{
		for i in 0 ..< n4 {
			t0 := trig[i]
			t1 := trig[n4 + i]
			re := f[2 * i]
			im := f[2 * i + 1]
			yr := re * t0 - im * t1
			yi := im * t0 + re * t1
			f2[bitrev[i]] = {yr * scale, yi * scale}
		}
	}
	opus_fft_impl(st, f2[:n4])
	{
		yp := 0
		yp1 := stride * (n2 - 1)
		for i in 0 ..< n4 {
			yr := f2[i][1] * trig[n4 + i] - f2[i][0] * trig[i]
			yi := f2[i][0] * trig[n4 + i] + f2[i][1] * trig[i]
			out[yp] = yr
			out[yp1] = yi
			yp += 2 * stride
			yp1 -= 2 * stride
		}
	}
}

// ---------------------------------------------------------------------------
// Comb filter (post-filter / pre-filter)

@(rodata)
COMB_GAINS := [3][3]f32{{0.3066406250, 0.2170410156, 0.1296386719}, {0.4638671875, 0.2680664062, 0.0}, {0.7998046875, 0.1000976562, 0.0}}

// y[yo+i] / x[xo+i]: x may be read at negative offsets (pitch history).
comb_filter :: proc "contextless" (y: []f32, yo: int, x: []f32, xo: int, T0_, T1_: int, n: int, g0, g1: f32, tapset0, tapset1: int, overlap_: int) {
	if g0 == 0 && g1 == 0 {
		if !(raw_data(x) == raw_data(y) && xo == yo) do copy(y[yo:yo + n], x[xo:xo + n])
		return
	}
	T0 := max(T0_, COMBFILTER_MINPERIOD)
	T1 := max(T1_, COMBFILTER_MINPERIOD)
	overlap := overlap_
	g00 := g0 * COMB_GAINS[tapset0][0]
	g01 := g0 * COMB_GAINS[tapset0][1]
	g02 := g0 * COMB_GAINS[tapset0][2]
	g10 := g1 * COMB_GAINS[tapset1][0]
	g11 := g1 * COMB_GAINS[tapset1][1]
	g12 := g1 * COMB_GAINS[tapset1][2]
	x1 := x[xo - T1 + 1]
	x2 := x[xo - T1]
	x3 := x[xo - T1 - 1]
	x4 := x[xo - T1 - 2]
	if g0 == g1 && T0 == T1 && tapset0 == tapset1 do overlap = 0
	i := 0
	for ; i < overlap; i += 1 {
		x0 := x[xo + i - T1 + 2]
		f := window120[i] * window120[i]
		v := x[xo + i] + ((1 - f) * g00) * x[xo + i - T0] + ((1 - f) * g01) * (x[xo + i - T0 + 1] + x[xo + i - T0 - 1]) +
			((1 - f) * g02) * (x[xo + i - T0 + 2] + x[xo + i - T0 - 2]) + (f * g10) * x2 + (f * g11) * (x1 + x3) + (f * g12) * (x0 + x4)
		y[yo + i] = clamp(v, -SIG_SAT, SIG_SAT)
		x4 = x3
		x3 = x2
		x2 = x1
		x1 = x0
	}
	if g1 == 0 {
		if !(raw_data(x) == raw_data(y) && xo == yo) do copy(y[yo + overlap:yo + n], x[xo + overlap:xo + n])
		return
	}
	// comb_filter_const
	{
		xb := xo + i
		yb := yo + i
		cx4 := x[xb - T1 - 2]
		cx3 := x[xb - T1 - 1]
		cx2 := x[xb - T1]
		cx1 := x[xb - T1 + 1]
		for k in 0 ..< n - i {
			cx0 := x[xb + k - T1 + 2]
			v := x[xb + k] + g10 * cx2 + g11 * (cx1 + cx3) + g12 * (cx0 + cx4)
			y[yb + k] = clamp(v, -SIG_SAT, SIG_SAT)
			cx4 = cx3
			cx3 = cx2
			cx2 = cx1
			cx1 = cx0
		}
	}
}

// ---------------------------------------------------------------------------
// LPC / pitch helpers (PLC and encoder)

celt_lpc :: proc "contextless" (lpc: []f32, ac: []f32, p: int) {
	err := ac[0]
	for i in 0 ..< p do lpc[i] = 0
	if ac[0] != 0 {
		for i in 0 ..< p {
			rr: f32 = 0
			for j in 0 ..< i do rr += lpc[j] * ac[i - j]
			rr += ac[i + 1]
			r := -rr / err
			lpc[i] = r
			for j in 0 ..< (i + 1) >> 1 {
				tmp1 := lpc[j]
				tmp2 := lpc[i - 1 - j]
				lpc[j] = tmp1 + r * tmp2
				lpc[i - 1 - j] = tmp2 + r * tmp1
			}
			err = err - r * r * err
			if err < 0.001 * ac[0] do break
		}
	}
}

// y[i] = x[i] + sum num[j]*x[i-j-1]; x must have `ord` history before xo.
celt_fir :: proc "contextless" (x: []f32, xo: int, num: []f32, y: []f32, n, ord: int) {
	for i in 0 ..< n {
		sum := x[xo + i]
		for j in 0 ..< ord do sum += num[j] * x[xo + i - j - 1]
		y[i] = sum
	}
}

celt_iir :: proc "contextless" (x: []f32, den: []f32, y: []f32, n, ord: int, mem: []f32) {
	// direct form, mem[0] = most recent output
	m: [LPC_ORDER]f32
	for i in 0 ..< ord do m[i] = mem[i]
	for i in 0 ..< n {
		sum := x[i]
		for j in 0 ..< ord do sum -= den[j] * m[j]
		for j := ord - 1; j >= 1; j -= 1 do m[j] = m[j - 1]
		m[0] = sum
		y[i] = sum
	}
	for i in 0 ..< ord do mem[i] = y[n - i - 1]
}

celt_autocorr :: proc "contextless" (x: []f32, ac: []f32, window: []f32, overlap, lag, n: int) {
	xx: [MAX_PERIOD + LPC_ORDER]f32
	for i in 0 ..< n do xx[i] = x[i]
	if overlap > 0 {
		for i in 0 ..< overlap {
			xx[i] = x[i] * window[i]
			xx[n - i - 1] = x[n - i - 1] * window[i]
		}
	}
	for k in 0 ..= lag {
		d: f32 = 0
		for i in k ..< n do d += xx[i] * xx[i - k]
		ac[k] = d
	}
}

pitch_xcorr :: proc "contextless" (x: []f32, y: []f32, xcorr: []f32, len, max_pitch: int) {
	for i in 0 ..< max_pitch {
		s: f32 = 0
		for j in 0 ..< len do s += x[j] * y[i + j]
		xcorr[i] = s
	}
}

@(private = "file")
find_best_pitch :: proc "contextless" (xcorr: []f32, y: []f32, len, max_pitch: int, best_pitch: ^[2]int) {
	syy: f32 = 1
	best_num := [2]f32{-1, -1}
	best_den := [2]f32{0, 0}
	best_pitch^ = {0, 1}
	for j in 0 ..< len do syy += y[j] * y[j]
	for i in 0 ..< max_pitch {
		if xcorr[i] > 0 {
			x16 := xcorr[i] * 1e-12
			num := x16 * x16
			if num * best_den[1] > best_num[1] * syy {
				if num * best_den[0] > best_num[0] * syy {
					best_num[1] = best_num[0]
					best_den[1] = best_den[0]
					best_pitch[1] = best_pitch[0]
					best_num[0] = num
					best_den[0] = syy
					best_pitch[0] = i
				} else {
					best_num[1] = num
					best_den[1] = syy
					best_pitch[1] = i
				}
			}
		}
		syy += y[i + len] * y[i + len] - y[i] * y[i]
		syy = max(1, syy)
	}
}

pitch_downsample :: proc "contextless" (x: [2][]f32, x_lp: []f32, len, C: int) {
	ac: [5]f32
	tmp: f32 = 1
	lpc: [4]f32
	lpc2: [5]f32
	c1 :: f32(0.8)
	for i in 1 ..< len >> 1 do x_lp[i] = 0.5 * (0.5 * (x[0][2 * i - 1] + x[0][2 * i + 1]) + x[0][2 * i])
	x_lp[0] = 0.5 * (0.5 * x[0][1] + x[0][0])
	if C == 2 {
		for i in 1 ..< len >> 1 do x_lp[i] += 0.5 * (0.5 * (x[1][2 * i - 1] + x[1][2 * i + 1]) + x[1][2 * i])
		x_lp[0] += 0.5 * (0.5 * x[1][1] + x[1][0])
	}
	celt_autocorr(x_lp, ac[:], nil, 0, 4, len >> 1)
	ac[0] *= 1.0001
	for i in 1 ..= 4 do ac[i] -= ac[i] * (0.008 * f32(i)) * (0.008 * f32(i))
	celt_lpc(lpc[:], ac[:], 4)
	for i in 0 ..< 4 {
		tmp = 0.9 * tmp
		lpc[i] = lpc[i] * tmp
	}
	lpc2[0] = lpc[0] + 0.8
	lpc2[1] = lpc[1] + c1 * lpc[0]
	lpc2[2] = lpc[2] + c1 * lpc[1]
	lpc2[3] = lpc[3] + c1 * lpc[2]
	lpc2[4] = c1 * lpc[3]
	mem: [5]f32
	for i in 0 ..< len >> 1 {
		sum := x_lp[i] + lpc2[0] * mem[0] + lpc2[1] * mem[1] + lpc2[2] * mem[2] + lpc2[3] * mem[3] + lpc2[4] * mem[4]
		mem[4] = mem[3]
		mem[3] = mem[2]
		mem[2] = mem[1]
		mem[1] = mem[0]
		mem[0] = x_lp[i]
		x_lp[i] = sum
	}
}

pitch_search :: proc "contextless" (x_lp: []f32, y: []f32, len, max_pitch: int) -> int {
	lag := len + max_pitch
	x_lp4: [MAX_PERIOD]f32
	y_lp4: [MAX_PERIOD]f32
	xcorr: [MAX_PERIOD]f32
	best_pitch: [2]int
	for j in 0 ..< len >> 2 do x_lp4[j] = x_lp[2 * j]
	for j in 0 ..< lag >> 2 do y_lp4[j] = y[2 * j]
	pitch_xcorr(x_lp4[:], y_lp4[:], xcorr[:], len >> 2, max_pitch >> 2)
	find_best_pitch(xcorr[:], y_lp4[:], len >> 2, max_pitch >> 2, &best_pitch)
	for i in 0 ..< max_pitch >> 1 {
		xcorr[i] = 0
		if abs(i - 2 * best_pitch[0]) > 2 && abs(i - 2 * best_pitch[1]) > 2 do continue
		sum := inner_prod(x_lp, y[i:], len >> 1)
		xcorr[i] = max(-1, sum)
	}
	find_best_pitch(xcorr[:], y, len >> 1, max_pitch >> 1, &best_pitch)
	offset := 0
	if best_pitch[0] > 0 && best_pitch[0] < (max_pitch >> 1) - 1 {
		a := xcorr[best_pitch[0] - 1]
		b := xcorr[best_pitch[0]]
		c := xcorr[best_pitch[0] + 1]
		if (c - a) > 0.7 * (b - a) do offset = 1
		else if (a - c) > 0.7 * (b - c) do offset = -1
	}
	return 2 * best_pitch[0] - offset
}
