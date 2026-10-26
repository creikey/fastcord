package opus

// SILK fixed-point primitives (SigProc_FIX.h / macros.h / Inlines.h).
// All 32-bit arithmetic wraps like the reference.

I16_MAX :: 32767
I16_MIN :: -32768
I32_MAX :: max(i32)
I32_MIN :: min(i32)

smulwb :: #force_inline proc "contextless" (a, b: i32) -> i32 {return i32((i64(a) * i64(i16(b))) >> 16)}
smlawb :: #force_inline proc "contextless" (a, b, c: i32) -> i32 {return a + i32((i64(b) * i64(i16(c))) >> 16)}
smulwt :: #force_inline proc "contextless" (a, b: i32) -> i32 {return i32((i64(a) * i64(b >> 16)) >> 16)}
smlawt :: #force_inline proc "contextless" (a, b, c: i32) -> i32 {return a + i32((i64(b) * i64(c >> 16)) >> 16)}
smulbb :: #force_inline proc "contextless" (a, b: i32) -> i32 {return i32(i16(a)) * i32(i16(b))}
smlabb :: #force_inline proc "contextless" (a, b, c: i32) -> i32 {return a + i32(i16(b)) * i32(i16(c))}
smulbt :: #force_inline proc "contextless" (a, b: i32) -> i32 {return i32(i16(a)) * (b >> 16)}
smlabt :: #force_inline proc "contextless" (a, b, c: i32) -> i32 {return a + i32(i16(b)) * (c >> 16)}
smultt :: #force_inline proc "contextless" (a, b: i32) -> i32 {return (a >> 16) * (b >> 16)}
smulww :: #force_inline proc "contextless" (a, b: i32) -> i32 {return i32((i64(a) * i64(b)) >> 16)}
smlaww :: #force_inline proc "contextless" (a, b, c: i32) -> i32 {return a + i32((i64(b) * i64(c)) >> 16)}
smmul :: #force_inline proc "contextless" (a, b: i32) -> i32 {return i32((i64(a) * i64(b)) >> 32)}
smull :: #force_inline proc "contextless" (a, b: i32) -> i64 {return i64(a) * i64(b)}

rshift_round :: #force_inline proc "contextless" (a: i32, shift: u32) -> i32 {
	return shift == 1 ? (a >> 1) + (a & 1) : ((a >> (shift - 1)) + 1) >> 1
}
rshift_round64 :: #force_inline proc "contextless" (a: i64, shift: u32) -> i64 {
	return shift == 1 ? (a >> 1) + (a & 1) : ((a >> (shift - 1)) + 1) >> 1
}

sat16 :: #force_inline proc "contextless" (a: i32) -> i32 {return a > I16_MAX ? I16_MAX : (a < I16_MIN ? I16_MIN : a)}

limit32 :: #force_inline proc "contextless" (a, l1, l2: i32) -> i32 {
	if l1 > l2 do return a > l1 ? l1 : (a < l2 ? l2 : a)
	return a > l2 ? l2 : (a < l1 ? l1 : a)
}

lshift_sat32 :: #force_inline proc "contextless" (a: i32, shift: u32) -> i32 {
	return i32(u32(limit32(a, I32_MIN >> shift, I32_MAX >> shift)) << shift)
}

add_sat32 :: #force_inline proc "contextless" (a, b: i32) -> i32 {
	s := i64(a) + i64(b)
	return i32(clamp(s, i64(I32_MIN), i64(I32_MAX)))
}

sub_sat32 :: #force_inline proc "contextless" (a, b: i32) -> i32 {
	s := i64(a) - i64(b)
	return i32(clamp(s, i64(I32_MIN), i64(I32_MAX)))
}

clz32 :: #force_inline proc "contextless" (x: i32) -> i32 {return x != 0 ? 32 - ec_ilog(u32(x)) : 32}

ror32 :: #force_inline proc "contextless" (a32: i32, rot: i32) -> i32 {
	x := u32(a32)
	r := u32(rot)
	m := u32(-rot)
	if rot == 0 do return a32
	if rot < 0 do return i32((x << m) | (x >> (32 - m)))
	return i32((x << (32 - r)) | (x >> r))
}

clz_frac :: #force_inline proc "contextless" (x: i32) -> (lz: i32, frac_q7: i32) {
	lz = clz32(x)
	frac_q7 = ror32(x, 24 - lz) & 0x7f
	return
}

sqrt_approx :: proc "contextless" (x: i32) -> i32 {
	if x <= 0 do return 0
	lz, frac := clz_frac(x)
	y: i32 = (lz & 1) != 0 ? 32768 : 46214
	y >>= u32(lz >> 1)
	y = smlawb(y, y, smulbb(213, frac))
	return y
}

silk_abs :: #force_inline proc "contextless" (a: i32) -> i32 {return a > 0 ? a : -a}

div32_varq :: proc "contextless" (a32, b32: i32, qres: i32) -> i32 {
	a_headrm := clz32(silk_abs(a32)) - 1
	a32_nrm := a32 << u32(a_headrm)
	b_headrm := clz32(silk_abs(b32)) - 1
	b32_nrm := b32 << u32(b_headrm)
	b32_inv := (I32_MAX >> 2) / (b32_nrm >> 16)
	result := smulwb(a32_nrm, b32_inv)
	a32_nrm = i32(u32(a32_nrm) - u32(smmul(b32_nrm, result)) << 3)
	result = smlawb(result, a32_nrm, b32_inv)
	lshift := 29 + a_headrm - b_headrm - qres
	if lshift < 0 do return lshift_sat32(result, u32(-lshift))
	if lshift < 32 do return result >> u32(lshift)
	return 0
}

inverse32_varq :: proc "contextless" (b32: i32, qres: i32) -> i32 {
	b_headrm := clz32(silk_abs(b32)) - 1
	b32_nrm := b32 << u32(b_headrm)
	b32_inv := (I32_MAX >> 2) / (b32_nrm >> 16)
	result := b32_inv << 16
	err_q32 := ((i32(1) << 29) - smulwb(b32_nrm, b32_inv)) << 3
	result = smlaww(result, err_q32, b32_inv)
	lshift := 61 - b_headrm - qres
	if lshift <= 0 do return lshift_sat32(result, u32(-lshift))
	if lshift < 32 do return result >> u32(lshift)
	return 0
}

silk_rand :: #force_inline proc "contextless" (seed: i32) -> i32 {
	return i32(u32(907633515) + u32(seed) * u32(196314165))
}

log2lin :: proc "contextless" (in_log_q7: i32) -> i32 {
	if in_log_q7 < 0 do return 0
	if in_log_q7 >= 3967 do return I32_MAX
	out := i32(1) << u32(in_log_q7 >> 7)
	frac := in_log_q7 & 0x7F
	if in_log_q7 < 2048 {
		out = out + ((out * smlawb(frac, smulbb(frac, 128 - frac), -174)) >> 7)
	} else {
		out = out + (out >> 7) * smlawb(frac, smulbb(frac, 128 - frac), -174)
	}
	return out
}

lin2log :: proc "contextless" (in_lin: i32) -> i32 {
	lz, frac := clz_frac(in_lin)
	return smlawb(frac, frac * (128 - frac), 179) + ((31 - lz) << 7)
}

sum_sqr_shift :: proc "contextless" (x: []i16, len: int) -> (energy: i32, shift: i32) {
	shft := 31 - clz32(i32(len))
	nrg := i32(len)
	i := 0
	for ; i < len - 1; i += 2 {
		t := u32(smulbb(i32(x[i]), i32(x[i])))
		t = u32(i32(t) + i32(x[i + 1]) * i32(x[i + 1]))
		nrg = i32(u32(nrg) + (t >> u32(shft)))
	}
	if i < len {
		t := u32(smulbb(i32(x[i]), i32(x[i])))
		nrg = i32(u32(nrg) + (t >> u32(shft)))
	}
	shft = max(0, shft + 3 - clz32(nrg))
	nrg = 0
	i = 0
	for ; i < len - 1; i += 2 {
		t := u32(smulbb(i32(x[i]), i32(x[i])))
		t = u32(i32(t) + i32(x[i + 1]) * i32(x[i + 1]))
		nrg = i32(u32(nrg) + (t >> u32(shft)))
	}
	if i < len {
		t := u32(smulbb(i32(x[i]), i32(x[i])))
		nrg = i32(u32(nrg) + (t >> u32(shft)))
	}
	return nrg, shft
}

bwexpander :: proc "contextless" (ar: []i16, d: int, chirp_q16_: i32) {
	chirp_q16 := chirp_q16_
	chirp_minus_one := chirp_q16 - 65536
	for i in 0 ..< d - 1 {
		ar[i] = i16(rshift_round(chirp_q16 * i32(ar[i]), 16))
		chirp_q16 += rshift_round(chirp_q16 * chirp_minus_one, 16)
	}
	ar[d - 1] = i16(rshift_round(chirp_q16 * i32(ar[d - 1]), 16))
}

bwexpander_32 :: proc "contextless" (ar: []i32, d: int, chirp_q16_: i32) {
	chirp_q16 := chirp_q16_
	chirp_minus_one := chirp_q16 - 65536
	for i in 0 ..< d - 1 {
		ar[i] = smulww(chirp_q16, ar[i])
		chirp_q16 += rshift_round(chirp_q16 * chirp_minus_one, 16)
	}
	ar[d - 1] = smulww(chirp_q16, ar[d - 1])
}

lpc_analysis_filter :: proc "contextless" (out: []i16, in_: []i16, B: []i16, len, d: int) {
	for ix in d ..< len {
		p := ix - 1
		o := smulbb(i32(in_[p]), i32(B[0]))
		for j in 1 ..< d do o = i32(u32(o) + u32(i32(in_[p - j]) * i32(B[j])))
		o = i32(u32(i32(in_[p + 1]) << 12) - u32(o))
		out[ix] = i16(sat16(rshift_round(o, 12)))
	}
	for j in 0 ..< d do out[j] = 0
}

@(private = "file")
lpc_inverse_pred_gain_qa :: proc "contextless" (A_QA: []i32, order: int) -> i32 {
	QA :: 24
	A_LIMIT :: i32(16773022) // SILK_FIX_CONST(0.99975, 24)
	inv_gain_q30 := i32(1) << 30
	k := order - 1
	for ; k > 0; k -= 1 {
		if A_QA[k] > A_LIMIT || A_QA[k] < -A_LIMIT do return 0
		rc_q31 := -(A_QA[k] << (31 - QA))
		rc_mult1_q30 := (i32(1) << 30) - smmul(rc_q31, rc_q31)
		inv_gain_q30 = smmul(inv_gain_q30, rc_mult1_q30) << 2
		if inv_gain_q30 < 107374 do return 0 // SILK_FIX_CONST(1/1e4, 30)
		mult2q := 32 - clz32(silk_abs(rc_mult1_q30))
		rc_mult2 := inverse32_varq(rc_mult1_q30, mult2q + 30)
		for n in 0 ..< (k + 1) >> 1 {
			tmp1 := A_QA[n]
			tmp2 := A_QA[k - n - 1]
			t64 := rshift_round64(smull(sub_sat32(tmp1, i32(rshift_round64(smull(tmp2, rc_q31), 31))), rc_mult2), u32(mult2q))
			if t64 > i64(I32_MAX) || t64 < i64(I32_MIN) do return 0
			A_QA[n] = i32(t64)
			t64 = rshift_round64(smull(sub_sat32(tmp2, i32(rshift_round64(smull(tmp1, rc_q31), 31))), rc_mult2), u32(mult2q))
			if t64 > i64(I32_MAX) || t64 < i64(I32_MIN) do return 0
			A_QA[k - n - 1] = i32(t64)
		}
	}
	if A_QA[k] > A_LIMIT || A_QA[k] < -A_LIMIT do return 0
	rc_q31 := -(A_QA[0] << (31 - QA))
	rc_mult1_q30 := (i32(1) << 30) - smmul(rc_q31, rc_q31)
	inv_gain_q30 = smmul(inv_gain_q30, rc_mult1_q30) << 2
	if inv_gain_q30 < 107374 do return 0
	return inv_gain_q30
}

lpc_inverse_pred_gain :: proc "contextless" (A_Q12: []i16, order: int) -> i32 {
	atmp: [24]i32
	dc_resp: i32 = 0
	for k in 0 ..< order {
		dc_resp += i32(A_Q12[k])
		atmp[k] = i32(A_Q12[k]) << (24 - 12)
	}
	if dc_resp >= 4096 do return 0
	return lpc_inverse_pred_gain_qa(atmp[:], order)
}
