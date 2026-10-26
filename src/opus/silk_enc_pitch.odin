package opus

// SILK encoder: open-loop pitch analysis (pitch_analysis_core_FLP.c,
// resampler_down2.c, resampler_down2_3.c).

@(private = "file")
resampler_down2 :: proc "contextless" (S: []i32, out: []i16, in_: []i16, in_len: int) {
	DOWN2_0 :: i32(9872)
	DOWN2_1 :: i32(39809 - 65536)
	for k in 0 ..< in_len >> 1 {
		in32 := i32(in_[2 * k]) << 10
		Y := in32 - S[0]
		X := smlawb(Y, Y, DOWN2_1)
		out32 := S[0] + X
		S[0] = in32 + X
		in32 = i32(in_[2 * k + 1]) << 10
		Y = in32 - S[1]
		X = smulwb(Y, DOWN2_0)
		out32 = out32 + S[1]
		out32 = out32 + X
		S[1] = in32 + X
		out[k] = i16(sat16(rshift_round(out32, 11)))
	}
}

@(private = "file")
resampler_down2_3 :: proc "contextless" (S: []i32, out_: []i16, in__: []i16, in_len_: int) {
	ORDER_FIR :: 4
	BATCH :: 480
	buf: [BATCH + ORDER_FIR]i32
	copy(buf[:ORDER_FIR], S[:ORDER_FIR])
	in_ := in__
	in_len := in_len_
	oi := 0
	n_in := 0
	c := silk_Resampler_2_3_COEFS_LQ[:]
	for {
		n_in = min(in_len, BATCH)
		// AR2
		for k in 0 ..< n_in {
			out32 := S[ORDER_FIR] + (i32(in_[k]) << 8)
			buf[ORDER_FIR + k] = out32
			out32 <<= 2
			S[ORDER_FIR] = smlawb(S[ORDER_FIR + 1], out32, i32(c[0]))
			S[ORDER_FIR + 1] = smulwb(out32, i32(c[1]))
		}
		bp := 0
		counter := n_in
		for counter > 2 {
			res_q6 := smulwb(buf[bp + 0], i32(c[2]))
			res_q6 = smlawb(res_q6, buf[bp + 1], i32(c[3]))
			res_q6 = smlawb(res_q6, buf[bp + 2], i32(c[5]))
			res_q6 = smlawb(res_q6, buf[bp + 3], i32(c[4]))
			out_[oi] = i16(sat16(rshift_round(res_q6, 6)))
			oi += 1
			res_q6 = smulwb(buf[bp + 1], i32(c[4]))
			res_q6 = smlawb(res_q6, buf[bp + 2], i32(c[5]))
			res_q6 = smlawb(res_q6, buf[bp + 3], i32(c[3]))
			res_q6 = smlawb(res_q6, buf[bp + 4], i32(c[2]))
			out_[oi] = i16(sat16(rshift_round(res_q6, 6)))
			oi += 1
			bp += 3
			counter -= 3
		}
		in_ = in_[n_in:]
		in_len -= n_in
		if in_len > 0 {
			copy(buf[:ORDER_FIR], buf[n_in:n_in + ORDER_FIR])
		} else {
			break
		}
	}
	copy(S[:ORDER_FIR], buf[n_in:n_in + ORDER_FIR])
}

@(private = "file")
cb_lags_stage2 :: #force_inline proc "contextless" (nb_subfr, i, j: int) -> int {
	return nb_subfr == SE_PE_MAX_NB_SUBFR ? int(silk_CB_lags_stage2[i][j]) : int(silk_CB_lags_stage2_10_ms[i][j])
}

@(private = "file")
cb_lags_stage3 :: #force_inline proc "contextless" (nb_subfr, i, j: int) -> int {
	return nb_subfr == SE_PE_MAX_NB_SUBFR ? int(silk_CB_lags_stage3[i][j]) : int(silk_CB_lags_stage3_10_ms[i][j])
}

@(private = "file")
lag_range_stage3 :: #force_inline proc "contextless" (nb_subfr, complexity, k, j: int) -> int {
	return nb_subfr == SE_PE_MAX_NB_SUBFR ? int(silk_Lag_range_stage3[complexity][k][j]) : int(silk_Lag_range_stage3_10_ms[k][j])
}

@(private = "file")
St3 :: [SE_PE_MAX_NB_SUBFR][PE_NB_CBKS_STAGE3_MAX][SE_PE_NB_STAGE3_LAGS]f32

// frame = base slice, fo = index of frame[0] in base
@(private = "file")
calc_corr_st3 :: proc "contextless" (cc: ^St3, frame: []f32, start_lag: int, sf_length: int, nb_subfr: int, complexity: int) {
	SCRATCH :: 22
	scratch_mem: [SCRATCH]f32
	xcorr: [SCRATCH]f32
	nb_cbk_search := nb_subfr == SE_PE_MAX_NB_SUBFR ? int(silk_nb_cbk_searchs_stage3[complexity]) : SE_PE_NB_CBKS_STAGE3_10MS
	t := sf_length << 2
	for k in 0 ..< nb_subfr {
		lag_low := lag_range_stage3(nb_subfr, complexity, k, 0)
		lag_high := lag_range_stage3(nb_subfr, complexity, k, 1)
		pitch_xcorr(frame[t:], frame[t - start_lag - lag_high:], xcorr[:], sf_length, lag_high - lag_low + 1)
		lc := 0
		for j := lag_low; j <= lag_high; j += 1 {
			scratch_mem[lc] = xcorr[lag_high - j]
			lc += 1
		}
		delta := lag_low
		for i in 0 ..< nb_cbk_search {
			idx := cb_lags_stage3(nb_subfr, k, i) - delta
			for j in 0 ..< SE_PE_NB_STAGE3_LAGS do cc[k][i][j] = scratch_mem[idx + j]
		}
		t += sf_length
	}
}

@(private = "file")
calc_energy_st3 :: proc "contextless" (en: ^St3, frame: []f32, start_lag: int, sf_length: int, nb_subfr: int, complexity: int) {
	SCRATCH :: 22
	scratch_mem: [SCRATCH]f32
	nb_cbk_search := nb_subfr == SE_PE_MAX_NB_SUBFR ? int(silk_nb_cbk_searchs_stage3[complexity]) : SE_PE_NB_CBKS_STAGE3_10MS
	t := sf_length << 2
	for k in 0 ..< nb_subfr {
		lc := 0
		b := t - (start_lag + lag_range_stage3(nb_subfr, complexity, k, 0))
		energy := silk_energy_flp(frame[b:], sf_length) + 1e-3
		scratch_mem[lc] = f32(energy)
		lc += 1
		lag_diff := lag_range_stage3(nb_subfr, complexity, k, 1) - lag_range_stage3(nb_subfr, complexity, k, 0) + 1
		for i in 1 ..< lag_diff {
			v := frame[b + sf_length - i]
			energy -= f64(v) * f64(v)
			w := frame[b - i]
			energy += f64(w) * f64(w)
			scratch_mem[lc] = f32(energy)
			lc += 1
		}
		delta := lag_range_stage3(nb_subfr, complexity, k, 0)
		for i in 0 ..< nb_cbk_search {
			idx := cb_lags_stage3(nb_subfr, k, i) - delta
			for j in 0 ..< SE_PE_NB_STAGE3_LAGS do en[k][i][j] = scratch_mem[idx + j]
		}
		t += sf_length
	}
}

// frame: pitch residual starting at the start of the analysis buffer
// (length (20 + nb_subfr*5) * fs_khz). Returns 0 if voiced, 1 if unvoiced.
silk_pitch_analysis_core_flp :: proc "contextless" (frame: []f32, pitch_out: []i32, lag_index: ^i16, contour_index: ^i8, ltp_corr: ^f32,
	prev_lag_: int, search_thres1: f32, search_thres2: f32, fs_khz: int, complexity: int, nb_subfr: int) -> int {
	PE_MAX_FRAME_LENGTH_MS :: SE_PE_MAX_FRAME_LENGTH_MS
	frame_8khz: [PE_MAX_FRAME_LENGTH_MS * 8]f32
	frame_4khz: [PE_MAX_FRAME_LENGTH_MS * 4]f32
	frame_8_fix: [PE_MAX_FRAME_LENGTH_MS * 8]i16
	frame_4_fix: [PE_MAX_FRAME_LENGTH_MS * 4]i16
	filt_state: [6]i32
	C: [SE_PE_MAX_NB_SUBFR][(SE_PE_MAX_LAG >> 1) + 5]f32
	xcorr: [PE_MAX_LAG_MS * 4 - PE_MIN_LAG_MS * 4 + 1]f32
	CC: [SE_PE_NB_CBKS_STAGE2_EXT]f32
	d_srch: [SE_PE_D_SRCH_LENGTH]i32
	d_comp: [(SE_PE_MAX_LAG >> 1) + 5]i16
	energies_st3: St3
	cross_corr_st3: St3
	prev_lag := prev_lag_

	frame_length := (SE_PE_LTP_MEM_LENGTH_MS + nb_subfr * SE_PE_SUBFR_LENGTH_MS) * fs_khz
	frame_length_4khz := (SE_PE_LTP_MEM_LENGTH_MS + nb_subfr * SE_PE_SUBFR_LENGTH_MS) * 4
	frame_length_8khz := (SE_PE_LTP_MEM_LENGTH_MS + nb_subfr * SE_PE_SUBFR_LENGTH_MS) * 8
	sf_length := SE_PE_SUBFR_LENGTH_MS * fs_khz
	sf_length_4khz := SE_PE_SUBFR_LENGTH_MS * 4
	sf_length_8khz := SE_PE_SUBFR_LENGTH_MS * 8
	min_lag := PE_MIN_LAG_MS * fs_khz
	min_lag_4khz := PE_MIN_LAG_MS * 4
	min_lag_8khz := PE_MIN_LAG_MS * 8
	max_lag := PE_MAX_LAG_MS * fs_khz - 1
	max_lag_4khz := PE_MAX_LAG_MS * 4
	max_lag_8khz := PE_MAX_LAG_MS * 8 - 1

	if fs_khz == 16 {
		frame_16_fix: [16 * PE_MAX_FRAME_LENGTH_MS]i16
		for k := frame_length - 1; k >= 0; k -= 1 do frame_16_fix[k] = silk_f2s(frame[k])
		filt_state[0] = 0
		filt_state[1] = 0
		resampler_down2(filt_state[:], frame_8_fix[:], frame_16_fix[:], frame_length)
		for k in 0 ..< frame_length_8khz do frame_8khz[k] = f32(frame_8_fix[k])
	} else if fs_khz == 12 {
		frame_12_fix: [12 * PE_MAX_FRAME_LENGTH_MS]i16
		for k := frame_length - 1; k >= 0; k -= 1 do frame_12_fix[k] = silk_f2s(frame[k])
		filt_state = {}
		resampler_down2_3(filt_state[:], frame_8_fix[:], frame_12_fix[:], frame_length)
		for k in 0 ..< frame_length_8khz do frame_8khz[k] = f32(frame_8_fix[k])
	} else {
		for k := frame_length_8khz - 1; k >= 0; k -= 1 do frame_8_fix[k] = silk_f2s(frame[k])
	}
	filt_state[0] = 0
	filt_state[1] = 0
	resampler_down2(filt_state[:], frame_4_fix[:], frame_8_fix[:], frame_length_8khz)
	for k in 0 ..< frame_length_4khz do frame_4khz[k] = f32(frame_4_fix[k])
	for i := frame_length_4khz - 1; i > 0; i -= 1 {
		s := frame_4khz[i] + frame_4khz[i - 1]
		frame_4khz[i] = f32(i16(s > 32767 ? 32767 : (s < -32768 ? -32768 : s)))
	}

	// first stage at 4 kHz
	t := sf_length_4khz << 2
	for _ in 0 ..< nb_subfr >> 1 {
		b := t - min_lag_4khz
		pitch_xcorr(frame_4khz[t:], frame_4khz[t - max_lag_4khz:], xcorr[:], sf_length_8khz, max_lag_4khz - min_lag_4khz + 1)
		cross_corr := f64(xcorr[max_lag_4khz - min_lag_4khz])
		normalizer := silk_energy_flp(frame_4khz[t:], sf_length_8khz) + silk_energy_flp(frame_4khz[b:], sf_length_8khz) + f64(f32(sf_length_8khz) * 4000.0)
		C[0][min_lag_4khz] += f32(2 * cross_corr / normalizer)
		for d := min_lag_4khz + 1; d <= max_lag_4khz; d += 1 {
			b -= 1
			cross_corr = f64(xcorr[max_lag_4khz - d])
			normalizer += f64(frame_4khz[b]) * f64(frame_4khz[b]) - f64(frame_4khz[b + sf_length_8khz]) * f64(frame_4khz[b + sf_length_8khz])
			C[0][d] += f32(2 * cross_corr / normalizer)
		}
		t += sf_length_8khz
	}
	for i := max_lag_4khz; i >= min_lag_4khz; i -= 1 {
		C[0][i] -= C[0][i] * f32(i) / 4096.0
	}
	length_d_srch := 4 + 2 * complexity
	silk_insertion_sort_decreasing_flp(C[0][min_lag_4khz:], d_srch[:], max_lag_4khz - min_lag_4khz + 1, length_d_srch)
	Cmax := C[0][min_lag_4khz]
	if Cmax < 0.2 {
		for k in 0 ..< nb_subfr do pitch_out[k] = 0
		ltp_corr^ = 0
		lag_index^ = 0
		contour_index^ = 0
		return 1
	}
	threshold := search_thres1 * Cmax
	for i in 0 ..< length_d_srch {
		if C[0][min_lag_4khz + i] > threshold {
			d_srch[i] = (d_srch[i] + i32(min_lag_4khz)) << 1
		} else {
			length_d_srch = i
			break
		}
	}
	for i := min_lag_8khz - 5; i < max_lag_8khz + 5; i += 1 do d_comp[i] = 0
	for i in 0 ..< length_d_srch do d_comp[d_srch[i]] = 1
	for i := max_lag_8khz + 3; i >= min_lag_8khz; i -= 1 do d_comp[i] += d_comp[i - 1] + d_comp[i - 2]
	length_d_srch = 0
	for i := min_lag_8khz; i < max_lag_8khz + 1; i += 1 {
		if d_comp[i + 1] > 0 {
			d_srch[length_d_srch] = i32(i)
			length_d_srch += 1
		}
	}
	for i := max_lag_8khz + 3; i >= min_lag_8khz; i -= 1 do d_comp[i] += d_comp[i - 1] + d_comp[i - 2] + d_comp[i - 3]
	length_d_comp := 0
	for i := min_lag_8khz; i < max_lag_8khz + 4; i += 1 {
		if d_comp[i] > 0 {
			d_comp[length_d_comp] = i16(i - 2)
			length_d_comp += 1
		}
	}

	// second stage at 8 kHz
	C = {}
	tgt: []f32 = fs_khz == 8 ? frame : frame_8khz[:]
	t = SE_PE_LTP_MEM_LENGTH_MS * 8
	for k in 0 ..< nb_subfr {
		energy_tmp := silk_energy_flp(tgt[t:], sf_length_8khz) + 1.0
		for j in 0 ..< length_d_comp {
			d := int(d_comp[j])
			b := t - d
			cross_corr := silk_inner_product_flp(tgt[b:], tgt[t:], sf_length_8khz)
			if cross_corr > 0 {
				energy := silk_energy_flp(tgt[b:], sf_length_8khz)
				C[k][d] = f32(2 * cross_corr / (energy + energy_tmp))
			} else {
				C[k][d] = 0
			}
		}
		t += sf_length_8khz
	}
	CCmax: f32 = 0
	CCmax_b: f32 = -1000
	CBimax := 0
	lag := -1
	prev_lag_log2: f32
	if prev_lag > 0 {
		if fs_khz == 12 {
			prev_lag = (prev_lag << 1) / 3
		} else if fs_khz == 16 {
			prev_lag = prev_lag >> 1
		}
		prev_lag_log2 = silk_log2_flp(f64(f32(prev_lag)))
	} else {
		prev_lag_log2 = 0
	}
	nb_cbk_search: int
	if nb_subfr == SE_PE_MAX_NB_SUBFR {
		nb_cbk_search = (fs_khz == 8 && complexity > SE_PE_MIN_COMPLEX) ? SE_PE_NB_CBKS_STAGE2_EXT : SE_PE_NB_CBKS_STAGE2
	} else {
		nb_cbk_search = SE_PE_NB_CBKS_STAGE2_10MS
	}
	for k in 0 ..< length_d_srch {
		d := int(d_srch[k])
		for j in 0 ..< nb_cbk_search {
			CC[j] = 0
			for i in 0 ..< nb_subfr do CC[j] += C[i][d + cb_lags_stage2(nb_subfr, i, j)]
		}
		CCmax_new: f32 = -1000
		CBimax_new := 0
		for i in 0 ..< nb_cbk_search {
			if CC[i] > CCmax_new {
				CCmax_new = CC[i]
				CBimax_new = i
			}
		}
		lag_log2 := silk_log2_flp(f64(f32(d)))
		shortlag_bias := f32(0.2)
		CCmax_new_b := CCmax_new - shortlag_bias * f32(nb_subfr) * lag_log2
		if prev_lag > 0 {
			delta := lag_log2 - prev_lag_log2
			delta *= delta
			prevlag_bias := f32(0.2)
			CCmax_new_b -= prevlag_bias * f32(nb_subfr) * ltp_corr^ * delta / (delta + 0.5)
		}
		if CCmax_new_b > CCmax_b && CCmax_new > f32(nb_subfr) * search_thres2 {
			CCmax_b = CCmax_new_b
			CCmax = CCmax_new
			lag = d
			CBimax = CBimax_new
		}
	}
	if lag == -1 {
		for k in 0 ..< SE_PE_MAX_NB_SUBFR do pitch_out[k] = 0
		ltp_corr^ = 0
		lag_index^ = 0
		contour_index^ = 0
		return 1
	}
	ltp_corr^ = CCmax / f32(nb_subfr)
	if fs_khz > 8 {
		if fs_khz == 12 {
			lag = int(rshift_round(smulbb(i32(lag), 3), 1))
		} else {
			lag = lag << 1
		}
		lag = int(limit32(i32(lag), i32(min_lag), i32(max_lag)))
		start_lag := max(lag - 2, min_lag)
		end_lag := min(lag + 2, max_lag)
		lag_new := lag
		CBimax = 0
		CCmax = -1000
		calc_corr_st3(&cross_corr_st3, frame, start_lag, sf_length, nb_subfr, complexity)
		calc_energy_st3(&energies_st3, frame, start_lag, sf_length, nb_subfr, complexity)
		lag_counter := 0
		flat := f32(0.05)
		contour_bias := flat / f32(lag)
		if nb_subfr == SE_PE_MAX_NB_SUBFR {
			nb_cbk_search = int(silk_nb_cbk_searchs_stage3[complexity])
		} else {
			nb_cbk_search = SE_PE_NB_CBKS_STAGE3_10MS
		}
		t = SE_PE_LTP_MEM_LENGTH_MS * fs_khz
		energy_tmp := silk_energy_flp(frame[t:], nb_subfr * sf_length) + 1.0
		for d := start_lag; d <= end_lag; d += 1 {
			for j in 0 ..< nb_cbk_search {
				cross_corr: f64 = 0
				energy := energy_tmp
				for k in 0 ..< nb_subfr {
					cross_corr += f64(cross_corr_st3[k][j][lag_counter])
					energy += f64(energies_st3[k][j][lag_counter])
				}
				CCmax_new: f32
				if cross_corr > 0 {
					CCmax_new = f32(2 * cross_corr / energy)
					CCmax_new *= 1.0 - contour_bias * f32(j)
				} else {
					CCmax_new = 0
				}
				if CCmax_new > CCmax && (d + int(silk_CB_lags_stage3[0][j])) <= max_lag {
					CCmax = CCmax_new
					lag_new = d
					CBimax = j
				}
			}
			lag_counter += 1
		}
		for k in 0 ..< nb_subfr {
			pitch_out[k] = i32(lag_new + cb_lags_stage3(nb_subfr, k, CBimax))
			pitch_out[k] = limit32(pitch_out[k], i32(min_lag), i32(PE_MAX_LAG_MS * fs_khz))
		}
		lag_index^ = i16(lag_new - min_lag)
		contour_index^ = i8(CBimax)
	} else {
		for k in 0 ..< nb_subfr {
			pitch_out[k] = i32(lag + cb_lags_stage2(nb_subfr, k, CBimax))
			pitch_out[k] = limit32(pitch_out[k], i32(min_lag_8khz), i32(PE_MAX_LAG_MS * 8))
		}
		lag_index^ = i16(lag - min_lag_8khz)
		contour_index^ = i8(CBimax)
	}
	return 0
}
