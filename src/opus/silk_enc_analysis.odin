package opus

// SILK encoder: VAD, variable cutoff filters, and the float signal analysis
// (find_pitch_lags, noise_shape_analysis, find_pred_coefs, find_LPC, burg,
// find_LTP, residual energy, process_gains).

import "core:math"

// ---- VAD (fixed point)

silk_vad_init :: proc "contextless" (v: ^Silk_VAD_State) {
	v^ = {}
	for b in 0 ..< SE_VAD_N_BANDS do v.noise_level_bias[b] = max(i32(SE_VAD_NOISE_LEVELS_BIAS / (b + 1)), 1)
	for b in 0 ..< SE_VAD_N_BANDS {
		v.nl[b] = 100 * v.noise_level_bias[b]
		v.inv_nl[b] = I32_MAX / v.nl[b]
	}
	v.counter = 15
	for b in 0 ..< SE_VAD_N_BANDS do v.nrg_ratio_smth_q8[b] = 100 * 256
}

@(private = "file")
ana_filt_bank_1 :: proc "contextless" (in_: []i16, S: []i32, outL: []i16, outH: []i16, N: int) {
	A_FB1_20 :: i32(5394 << 1)
	A_FB1_21 :: i32(-24290)
	for k in 0 ..< N >> 1 {
		in32 := i32(in_[2 * k]) << 10
		Y := in32 - S[0]
		X := smlawb(Y, Y, A_FB1_21)
		out_1 := S[0] + X
		S[0] = in32 + X
		in32 = i32(in_[2 * k + 1]) << 10
		Y = in32 - S[1]
		X = smulwb(Y, A_FB1_20)
		out_2 := S[1] + X
		S[1] = in32 + X
		outL[k] = i16(sat16(rshift_round(out_2 + out_1, 11)))
		outH[k] = i16(sat16(rshift_round(out_2 - out_1, 11)))
	}
}

@(private = "file")
vad_get_noise_levels :: proc "contextless" (pX: []i32, v: ^Silk_VAD_State) {
	min_coef: i32
	if v.counter < 1000 {
		min_coef = I16_MAX / ((v.counter >> 4) + 1)
		v.counter += 1
	} else {
		min_coef = 0
	}
	for k in 0 ..< SE_VAD_N_BANDS {
		nl := v.nl[k]
		nrg := silk_add_pos_sat32(pX[k], v.noise_level_bias[k])
		inv_nrg := I32_MAX / nrg
		coef: i32
		if nrg > (nl << 3) {
			coef = SE_VAD_NOISE_LEVEL_SMOOTH_COEF_Q16 >> 3
		} else if nrg < nl {
			coef = SE_VAD_NOISE_LEVEL_SMOOTH_COEF_Q16
		} else {
			coef = smulwb(smulww(inv_nrg, nl), SE_VAD_NOISE_LEVEL_SMOOTH_COEF_Q16 << 1)
		}
		coef = max(coef, min_coef)
		v.inv_nl[k] = smlawb(v.inv_nl[k], inv_nrg - v.inv_nl[k], coef)
		nl = I32_MAX / v.inv_nl[k]
		nl = min(nl, 0x00FFFFFF)
		v.nl[k] = nl
	}
}

// pIn: frame_length samples (input_buf[1:])
silk_vad_get_sa_q8 :: proc "contextless" (cmn: ^Silk_Enc_Common, pIn: []i16) {
	v := &cmn.svad
	fl := int(cmn.frame_length)
	dec1 := fl >> 1
	dec2 := fl >> 2
	dec := fl >> 3
	X_offset: [SE_VAD_N_BANDS]int
	X_offset[0] = 0
	X_offset[1] = dec + dec2
	X_offset[2] = X_offset[1] + dec
	X_offset[3] = X_offset[2] + dec2
	X: [MAX_FRAME_LENGTH * 5 / 4]i16
	Xnrg: [SE_VAD_N_BANDS]i32
	nrg_to_noise_ratio_q8: [SE_VAD_N_BANDS]i32
	ana_filt_bank_1(pIn, v.ana_state[:], X[:], X[X_offset[3]:], fl)
	ana_filt_bank_1(X[:], v.ana_state1[:], X[:], X[X_offset[2]:], dec1)
	ana_filt_bank_1(X[:], v.ana_state2[:], X[:], X[X_offset[1]:], dec2)
	X[dec - 1] = X[dec - 1] >> 1
	hp_state_tmp := X[dec - 1]
	for i := dec - 1; i > 0; i -= 1 {
		X[i - 1] = X[i - 1] >> 1
		X[i] -= X[i - 1]
	}
	X[0] -= v.hp_state
	v.hp_state = hp_state_tmp
	for b in 0 ..< SE_VAD_N_BANDS {
		dfl := fl >> u32(min(SE_VAD_N_BANDS - b, SE_VAD_N_BANDS - 1))
		dsl := dfl >> SE_VAD_INTERNAL_SUBFRAMES_LOG2
		dso := 0
		Xnrg[b] = v.xnrg_subfr[b]
		sum_squared: i32
		for s in 0 ..< SE_VAD_INTERNAL_SUBFRAMES {
			sum_squared = 0
			for i in 0 ..< dsl {
				x_tmp := i32(X[X_offset[b] + i + dso]) >> 3
				sum_squared = smlabb(sum_squared, x_tmp, x_tmp)
			}
			if s < SE_VAD_INTERNAL_SUBFRAMES - 1 {
				Xnrg[b] = silk_add_pos_sat32(Xnrg[b], sum_squared)
			} else {
				Xnrg[b] = silk_add_pos_sat32(Xnrg[b], sum_squared >> 1)
			}
			dso += dsl
		}
		v.xnrg_subfr[b] = sum_squared
	}
	vad_get_noise_levels(Xnrg[:], v)
	sum_squared: i32 = 0
	input_tilt: i32 = 0
	for b in 0 ..< SE_VAD_N_BANDS {
		speech_nrg := Xnrg[b] - v.nl[b]
		if speech_nrg > 0 {
			if (u32(Xnrg[b]) & 0xFF800000) == 0 {
				nrg_to_noise_ratio_q8[b] = (Xnrg[b] << 8) / (v.nl[b] + 1)
			} else {
				nrg_to_noise_ratio_q8[b] = Xnrg[b] / ((v.nl[b] >> 8) + 1)
			}
			snr_q7 := lin2log(nrg_to_noise_ratio_q8[b]) - 8 * 128
			sum_squared = smlabb(sum_squared, snr_q7, snr_q7)
			if speech_nrg < (i32(1) << 20) {
				snr_q7 = smulwb(sqrt_approx(speech_nrg) << 6, snr_q7)
			}
			input_tilt = smlawb(input_tilt, silk_enc_vad_tilt_weights[b], snr_q7)
		} else {
			nrg_to_noise_ratio_q8[b] = 256
		}
	}
	sum_squared = sum_squared / SE_VAD_N_BANDS
	pSNR_dB_q7 := i32(i16(3 * sqrt_approx(sum_squared)))
	SA_q15 := silk_sigm_q15(smulwb(SE_VAD_SNR_FACTOR_Q16, pSNR_dB_q7) - SE_VAD_NEGATIVE_OFFSET_Q5)
	cmn.input_tilt_q15 = (silk_sigm_q15(input_tilt) - 16384) << 1
	speech_nrg: i32 = 0
	for b in 0 ..< SE_VAD_N_BANDS do speech_nrg += i32(b + 1) * ((Xnrg[b] - v.nl[b]) >> 4)
	if cmn.frame_length == 20 * cmn.fs_khz do speech_nrg >>= 1
	if speech_nrg <= 0 {
		SA_q15 >>= 1
	} else if speech_nrg < 16384 {
		speech_nrg <<= 16
		speech_nrg = sqrt_approx(speech_nrg)
		SA_q15 = smulwb(32768 + speech_nrg, SA_q15)
	}
	cmn.speech_activity_q8 = min(SA_q15 >> 7, 255)
	smooth_coef_q16 := smulwb(SE_VAD_SNR_SMOOTH_COEF_Q18, smulwb(SA_q15, SA_q15))
	if cmn.frame_length == 10 * cmn.fs_khz do smooth_coef_q16 >>= 1
	for b in 0 ..< SE_VAD_N_BANDS {
		v.nrg_ratio_smth_q8[b] = smlawb(v.nrg_ratio_smth_q8[b], nrg_to_noise_ratio_q8[b] - v.nrg_ratio_smth_q8[b], smooth_coef_q16)
		snr_q7 := 3 * (lin2log(v.nrg_ratio_smth_q8[b]) - 8 * 128)
		cmn.input_quality_bands_q15[b] = silk_sigm_q15((snr_q7 - 16 * 128) >> 4)
	}
}

// ---- LP / HP variable cutoff

@(private = "file")
lp_interpolate_filter_taps :: proc "contextless" (B_q28: []i32, A_q28: []i32, ind: int, fac_q16: i32) {
	if ind < SE_TRANSITION_INT_NUM - 1 {
		if fac_q16 > 0 {
			if fac_q16 < 32768 {
				for nb in 0 ..< SE_TRANSITION_NB {
					B_q28[nb] = smlawb(silk_Transition_LP_B_Q28[ind][nb], silk_Transition_LP_B_Q28[ind + 1][nb] - silk_Transition_LP_B_Q28[ind][nb], fac_q16)
				}
				for na in 0 ..< SE_TRANSITION_NA {
					A_q28[na] = smlawb(silk_Transition_LP_A_Q28[ind][na], silk_Transition_LP_A_Q28[ind + 1][na] - silk_Transition_LP_A_Q28[ind][na], fac_q16)
				}
			} else {
				for nb in 0 ..< SE_TRANSITION_NB {
					B_q28[nb] = smlawb(silk_Transition_LP_B_Q28[ind + 1][nb], silk_Transition_LP_B_Q28[ind + 1][nb] - silk_Transition_LP_B_Q28[ind][nb], fac_q16 - (1 << 16))
				}
				for na in 0 ..< SE_TRANSITION_NA {
					A_q28[na] = smlawb(silk_Transition_LP_A_Q28[ind + 1][na], silk_Transition_LP_A_Q28[ind + 1][na] - silk_Transition_LP_A_Q28[ind][na], fac_q16 - (1 << 16))
				}
			}
		} else {
			for nb in 0 ..< SE_TRANSITION_NB do B_q28[nb] = silk_Transition_LP_B_Q28[ind][nb]
			for na in 0 ..< SE_TRANSITION_NA do A_q28[na] = silk_Transition_LP_A_Q28[ind][na]
		}
	} else {
		for nb in 0 ..< SE_TRANSITION_NB do B_q28[nb] = silk_Transition_LP_B_Q28[SE_TRANSITION_INT_NUM - 1][nb]
		for na in 0 ..< SE_TRANSITION_NA do A_q28[na] = silk_Transition_LP_A_Q28[SE_TRANSITION_INT_NUM - 1][na]
	}
}

@(private = "file")
biquad_alt_stride1 :: proc "contextless" (io: []i16, B_q28: []i32, A_q28: []i32, S: []i32, len: int) {
	A0_L_q28 := (-A_q28[0]) & 0x00003FFF
	A0_U_q28 := (-A_q28[0]) >> 14
	A1_L_q28 := (-A_q28[1]) & 0x00003FFF
	A1_U_q28 := (-A_q28[1]) >> 14
	for k in 0 ..< len {
		inval := i32(io[k])
		out32_q14 := smlawb(S[0], B_q28[0], inval) << 2
		S[0] = S[1] + rshift_round(smulwb(out32_q14, A0_L_q28), 14)
		S[0] = smlawb(S[0], out32_q14, A0_U_q28)
		S[0] = smlawb(S[0], B_q28[1], inval)
		S[1] = rshift_round(smulwb(out32_q14, A1_L_q28), 14)
		S[1] = smlawb(S[1], out32_q14, A1_U_q28)
		S[1] = smlawb(S[1], B_q28[2], inval)
		io[k] = i16(sat16((out32_q14 + (1 << 14) - 1) >> 14))
	}
}

silk_lp_variable_cutoff :: proc "contextless" (lp: ^Silk_LP_State, frame: []i16, frame_length: int) {
	B_q28: [SE_TRANSITION_NB]i32
	A_q28: [SE_TRANSITION_NA]i32
	if lp.mode != 0 {
		fac_q16 := (SE_TRANSITION_FRAMES - lp.transition_frame_no) << (16 - 6)
		ind := int(fac_q16 >> 16)
		fac_q16 -= i32(ind) << 16
		lp_interpolate_filter_taps(B_q28[:], A_q28[:], ind, fac_q16)
		lp.transition_frame_no = limit32(lp.transition_frame_no + lp.mode, 0, SE_TRANSITION_FRAMES)
		biquad_alt_stride1(frame, B_q28[:], A_q28[:], lp.in_lp_state[:], frame_length)
	}
}

silk_hp_variable_cutoff :: proc "contextless" (ch: []Silk_Enc_Chan) {
	c := &ch[0].cmn
	if c.prev_signal_type == TYPE_VOICED {
		pitch_freq_hz_q16 := ((c.fs_khz * 1000) << 16) / c.prev_lag
		pitch_freq_log_q7 := lin2log(pitch_freq_hz_q16) - (16 << 7)
		quality_q15 := c.input_quality_bands_q15[0]
		pitch_freq_log_q7 = smlawb(pitch_freq_log_q7, smulwb((-quality_q15) << 2, quality_q15),
			pitch_freq_log_q7 - (lin2log(SE_FIX_VARIABLE_HP_MIN_CUTOFF_Q16) - (16 << 7)))
		delta_freq_q7 := pitch_freq_log_q7 - (c.variable_hp_smth1_q15 >> 8)
		if delta_freq_q7 < 0 do delta_freq_q7 = delta_freq_q7 * 3
		delta_freq_q7 = limit32(delta_freq_q7, -SE_FIX_VARIABLE_HP_MAX_DELTA_FREQ_Q7, SE_FIX_VARIABLE_HP_MAX_DELTA_FREQ_Q7)
		c.variable_hp_smth1_q15 = smlawb(c.variable_hp_smth1_q15, smulbb(c.speech_activity_q8, delta_freq_q7), SE_FIX_VARIABLE_HP_SMTH_COEF1_Q16)
		c.variable_hp_smth1_q15 = limit32(c.variable_hp_smth1_q15, lin2log(SE_VARIABLE_HP_MIN_CUTOFF_HZ) << 8, lin2log(SE_VARIABLE_HP_MAX_CUTOFF_HZ) << 8)
	}
}

// ---- pitch lags (float)

// x: index of x_frame within enc.x_buf; res: full res_pitch buffer
@(private = "file")
find_pitch_lags_flp :: proc "contextless" (enc: ^Silk_Enc_Chan, ctrl: ^Silk_Enc_Ctrl, res: []f32, xo: int) {
	c := &enc.cmn
	auto_corr: [SE_MAX_FIND_PITCH_LPC_ORDER + 1]f32
	A: [SE_MAX_FIND_PITCH_LPC_ORDER]f32
	refl_coef: [SE_MAX_FIND_PITCH_LPC_ORDER]f32
	Wsig: [SE_FIND_PITCH_LPC_WIN_MAX]f32
	buf_len := int(c.la_pitch + c.frame_length + c.ltp_mem_length)
	x_buf := enc.x_buf[xo - int(c.ltp_mem_length):]
	win := int(c.pitch_lpc_win_length)
	la := int(c.la_pitch)
	xp := buf_len - win
	silk_apply_sine_window_flp(Wsig[:], x_buf[xp:], 1, la)
	wp := la
	xp += la
	copy(Wsig[wp:wp + win - (la << 1)], x_buf[xp:xp + win - (la << 1)])
	wp += win - (la << 1)
	xp += win - (la << 1)
	silk_apply_sine_window_flp(Wsig[wp:], x_buf[xp:], 2, la)
	order := int(c.pitch_estimation_lpc_order)
	silk_autocorrelation_flp(auto_corr[:], Wsig[:], win, order + 1)
	auto_corr[0] += auto_corr[0] * 1e-3 + 1
	res_nrg := silk_schur_flp(refl_coef[:], auto_corr[:], order)
	ctrl.pred_gain = auto_corr[0] / max(res_nrg, 1.0)
	silk_k2a_flp(A[:], refl_coef[:], order)
	silk_bwexpander_flp(A[:], order, 0.99)
	silk_lpc_analysis_filter_flp(res, A[:], x_buf, buf_len, order)
	if c.indices.signal_type != TYPE_NO_VOICE_ACTIVITY && c.first_frame_after_reset == 0 {
		thrhld: f32 = 0.6
		thrhld -= 0.004 * f32(c.pitch_estimation_lpc_order)
		thrhld -= 0.1 * f32(c.speech_activity_q8) * (1.0 / 256.0)
		thrhld -= 0.15 * f32(c.prev_signal_type >> 1)
		thrhld -= 0.1 * f32(c.input_tilt_q15) * (1.0 / 32768.0)
		if silk_pitch_analysis_core_flp(res, ctrl.pitch_l[:], &c.indices.lag_index, &c.indices.contour_index, &enc.ltp_corr, int(c.prev_lag),
			   f32(c.pitch_estimation_threshold_q16) / 65536.0, thrhld, int(c.fs_khz), int(c.pitch_estimation_complexity), int(c.nb_subfr)) == 0 {
			c.indices.signal_type = TYPE_VOICED
		} else {
			c.indices.signal_type = TYPE_UNVOICED
		}
	} else {
		ctrl.pitch_l = {}
		c.indices.lag_index = 0
		c.indices.contour_index = 0
		enc.ltp_corr = 0
	}
}

// ---- noise shaping analysis

@(private = "file")
warped_gain :: proc "contextless" (coefs: []f32, lambda_: f32, order: int) -> f32 {
	lambda := -lambda_
	gain := coefs[order - 1]
	for i := order - 2; i >= 0; i -= 1 do gain = lambda * gain + coefs[i]
	return 1.0 / (1.0 - lambda * gain)
}

@(private = "file")
warped_true2monic_coefs :: proc "contextless" (coefs: []f32, lambda: f32, limit: f32, order: int) {
	ind := 0
	for i := order - 1; i > 0; i -= 1 do coefs[i - 1] -= lambda * coefs[i]
	gain := (1.0 - lambda * lambda) / (1.0 + lambda * coefs[0])
	for i in 0 ..< order do coefs[i] *= gain
	for iter in 0 ..< 10 {
		maxabs: f32 = -1
		for i in 0 ..< order {
			tmp := silk_abs_f32(coefs[i])
			if tmp > maxabs {
				maxabs = tmp
				ind = i
			}
		}
		if maxabs <= limit do return
		for i in 1 ..< order do coefs[i - 1] += lambda * coefs[i]
		gain = 1.0 / gain
		for i in 0 ..< order do coefs[i] *= gain
		chirp := 0.99 - (0.8 + 0.1 * f32(iter)) * (maxabs - limit) / (maxabs * f32(ind + 1))
		silk_bwexpander_flp(coefs, order, chirp)
		for i := order - 1; i > 0; i -= 1 do coefs[i - 1] -= lambda * coefs[i]
		gain = (1.0 - lambda * lambda) / (1.0 + lambda * coefs[0])
		for i in 0 ..< order do coefs[i] *= gain
	}
}

@(private = "file")
limit_coefs :: proc "contextless" (coefs: []f32, limit: f32, order: int) {
	ind := 0
	for iter in 0 ..< 10 {
		maxabs: f32 = -1
		for i in 0 ..< order {
			tmp := silk_abs_f32(coefs[i])
			if tmp > maxabs {
				maxabs = tmp
				ind = i
			}
		}
		if maxabs <= limit do return
		chirp := 0.99 - (0.8 + 0.1 * f32(iter)) * (maxabs - limit) / (maxabs * f32(ind + 1))
		silk_bwexpander_flp(coefs, order, chirp)
	}
}

@(private = "file")
warped_autocorrelation_flp :: proc "contextless" (corr: []f32, input: []f32, warping: f32, length: int, order: int) {
	state: [SE_MAX_SHAPE_LPC_ORDER + 1]f64
	C: [SE_MAX_SHAPE_LPC_ORDER + 1]f64
	w := f64(warping)
	for n in 0 ..< length {
		tmp1 := f64(input[n])
		for i := 0; i < order; i += 2 {
			tmp2 := state[i] + w * (state[i + 1] - tmp1)
			state[i] = tmp1
			C[i] += state[0] * tmp1
			tmp1 = state[i + 1] + w * (state[i + 2] - tmp2)
			state[i + 1] = tmp2
			C[i + 1] += state[0] * tmp2
		}
		state[order] = tmp1
		C[order] += state[0] * tmp1
	}
	for i in 0 ..< order + 1 do corr[i] = f32(C[i])
}

@(private = "file")
noise_shape_analysis_flp :: proc "contextless" (enc: ^Silk_Enc_Chan, ctrl: ^Silk_Enc_Ctrl, pitch_res: []f32, xo: int) {
	c := &enc.cmn
	sh := &enc.shape
	x_windowed: [SE_SHAPE_LPC_WIN_MAX]f32
	auto_corr: [SE_MAX_SHAPE_LPC_ORDER + 1]f32
	rc: [SE_MAX_SHAPE_LPC_ORDER + 1]f32
	xp := xo - int(c.la_shape)
	SNR_adj_dB := f32(c.snr_db_q7) * (1 / 128.0)
	ctrl.input_quality = 0.5 * f32(c.input_quality_bands_q15[0] + c.input_quality_bands_q15[1]) * (1.0 / 32768.0)
	ctrl.coding_quality = silk_sigmoid_flp(0.25 * (SNR_adj_dB - 20.0))
	if c.use_cbr == 0 {
		b := 1.0 - f32(c.speech_activity_q8) * (1.0 / 256.0)
		SNR_adj_dB -= 2.0 * ctrl.coding_quality * (0.5 + 0.5 * ctrl.input_quality) * b * b
	}
	if c.indices.signal_type == TYPE_VOICED {
		SNR_adj_dB += 2.0 * enc.ltp_corr
	} else {
		SNR_adj_dB += (-0.4 * f32(c.snr_db_q7) * (1 / 128.0) + 6.0) * (1.0 - ctrl.input_quality)
	}
	if c.indices.signal_type == TYPE_VOICED {
		c.indices.quant_offset_type = 0
	} else {
		n_samples := int(2 * c.fs_khz)
		energy_variation: f32 = 0
		log_energy_prev: f32 = 0
		pr := 0
		n_segs := int(smulbb(SE_SUB_FRAME_LENGTH_MS, c.nb_subfr)) / 2
		for k in 0 ..< n_segs {
			nrg := f32(n_samples) + f32(silk_energy_flp(pitch_res[pr:], n_samples))
			log_energy := silk_log2_flp(f64(nrg))
			if k > 0 do energy_variation += silk_abs_f32(log_energy - log_energy_prev)
			log_energy_prev = log_energy
			pr += n_samples
		}
		thr := f32(0.6)
		if energy_variation > thr * f32(n_segs - 1) {
			c.indices.quant_offset_type = 0
		} else {
			c.indices.quant_offset_type = 1
		}
	}
	strength := f32(1e-3) * ctrl.pred_gain
	BWExp := f32(0.94) / (1.0 + strength * strength)
	warping := f32(c.warping_q16) / 65536.0 + 0.01 * ctrl.coding_quality
	for k in 0 ..< int(c.nb_subfr) {
		flat_part := int(c.fs_khz * 3)
		slope_part := (int(c.shape_win_length) - flat_part) / 2
		silk_apply_sine_window_flp(x_windowed[:], enc.x_buf[xp:], 1, slope_part)
		shift := slope_part
		copy(x_windowed[shift:shift + flat_part], enc.x_buf[xp + shift:xp + shift + flat_part])
		shift += flat_part
		silk_apply_sine_window_flp(x_windowed[shift:], enc.x_buf[xp + shift:], 2, slope_part)
		xp += int(c.subfr_length)
		order := int(c.shaping_lpc_order)
		if c.warping_q16 > 0 {
			warped_autocorrelation_flp(auto_corr[:], x_windowed[:], warping, int(c.shape_win_length), order)
		} else {
			silk_autocorrelation_flp(auto_corr[:], x_windowed[:], int(c.shape_win_length), order + 1)
		}
		auto_corr[0] += auto_corr[0] * 3e-5 + 1.0
		nrg := silk_schur_flp(rc[:], auto_corr[:], order)
		ar := ctrl.ar[k * SE_MAX_SHAPE_LPC_ORDER:]
		silk_k2a_flp(ar, rc[:], order)
		ctrl.gains[k] = math.sqrt(nrg)
		if c.warping_q16 > 0 do ctrl.gains[k] *= warped_gain(ar, warping, order)
		silk_bwexpander_flp(ar, order, BWExp)
		if c.warping_q16 > 0 {
			warped_true2monic_coefs(ar, warping, 3.999, order)
		} else {
			limit_coefs(ar, 3.999, order)
		}
	}
	gain_mult := f32(silk_pow_f(2.0, f64(-0.16 * SNR_adj_dB)))
	g016 := f32(0.16)
	gain_add := f32(silk_pow_f(2.0, f64(g016 * SE_MIN_QGAIN_DB)))
	for k in 0 ..< int(c.nb_subfr) {
		ctrl.gains[k] *= gain_mult
		ctrl.gains[k] += gain_add
	}
	strength = 4.0 * (1.0 + 0.5 * (f32(c.input_quality_bands_q15[0]) * (1.0 / 32768.0) - 1.0))
	strength *= f32(c.speech_activity_q8) * (1.0 / 256.0)
	Tilt: f32
	if c.indices.signal_type == TYPE_VOICED {
		for k in 0 ..< int(c.nb_subfr) {
			b := 0.2 / f32(c.fs_khz) + 3.0 / f32(ctrl.pitch_l[k])
			ctrl.lf_ma_shp[k] = -1.0 + b
			ctrl.lf_ar_shp[k] = 1.0 - b - b * strength
		}
		hp := f32(0.25)
		t := 1 - hp
		t *= 0.35
		Tilt = -hp - t * f32(c.speech_activity_q8) * (1.0 / 256.0)
	} else {
		b := 1.3 / f32(c.fs_khz)
		ctrl.lf_ma_shp[0] = -1.0 + b
		ctrl.lf_ar_shp[0] = 1.0 - b - b * strength * 0.6
		for k in 1 ..< int(c.nb_subfr) {
			ctrl.lf_ma_shp[k] = ctrl.lf_ma_shp[0]
			ctrl.lf_ar_shp[k] = ctrl.lf_ar_shp[0]
		}
		Tilt = -0.25
	}
	HarmShapeGain: f32
	if c.indices.signal_type == TYPE_VOICED {
		HarmShapeGain = 0.3
		HarmShapeGain += 0.2 * (1.0 - (1.0 - ctrl.coding_quality) * ctrl.input_quality)
		HarmShapeGain *= math.sqrt(enc.ltp_corr)
	} else {
		HarmShapeGain = 0
	}
	for k in 0 ..< int(c.nb_subfr) {
		sh.harm_shape_gain_smth += 0.4 * (HarmShapeGain - sh.harm_shape_gain_smth)
		ctrl.harm_shape_gain[k] = sh.harm_shape_gain_smth
		sh.tilt_smth += 0.4 * (Tilt - sh.tilt_smth)
		ctrl.tilt[k] = sh.tilt_smth
	}
}

// ---- prediction coefficients

@(private = "file")
corr_vector_flp :: proc "contextless" (x: []f32, t: []f32, L: int, order: int, Xt: []f32) {
	p := order - 1
	for lag in 0 ..< order {
		Xt[lag] = f32(silk_inner_product_flp(x[p:], t, L))
		p -= 1
	}
}

@(private = "file")
corr_matrix_flp :: proc "contextless" (x: []f32, L: int, order: int, XX: []f32) {
	p1 := order - 1
	energy := silk_energy_flp(x[p1:], L)
	XX[0] = f32(energy)
	for j in 1 ..< order {
		energy += f64(x[p1 - j] * x[p1 - j] - x[p1 + L - j] * x[p1 + L - j])
		XX[j * order + j] = f32(energy)
	}
	p2 := order - 2
	for lag in 1 ..< order {
		energy = silk_inner_product_flp(x[p1:], x[p2:], L)
		XX[lag * order + 0] = f32(energy)
		XX[0 * order + lag] = f32(energy)
		for j in 1 ..< order - lag {
			energy += f64(x[p1 - j] * x[p2 - j] - x[p1 + L - j] * x[p2 + L - j])
			XX[(lag + j) * order + j] = f32(energy)
			XX[j * order + lag + j] = f32(energy)
		}
		p2 -= 1
	}
}

// r: base slice, ro: index of r_ptr
@(private = "file")
find_ltp_flp :: proc "contextless" (XX: []f32, xX: []f32, r: []f32, ro_: int, lag: []i32, subfr_length: int, nb_subfr: int) {
	ro := ro_
	for k in 0 ..< nb_subfr {
		lp := ro - (int(lag[k]) + LTP_ORDER / 2)
		XXk := XX[k * LTP_ORDER * LTP_ORDER:]
		xXk := xX[k * LTP_ORDER:]
		corr_matrix_flp(r[lp:], subfr_length, LTP_ORDER, XXk)
		corr_vector_flp(r[lp:], r[ro:], subfr_length, LTP_ORDER, xXk)
		xx := f32(silk_energy_flp(r[ro:], subfr_length + LTP_ORDER))
		lc := f32(0.03)
		lc *= 0.5
		d := lc * (XXk[0] + XXk[24]) + 1.0
		temp := 1.0 / max(xx, d)
		silk_scale_vector_flp(XXk, temp, LTP_ORDER * LTP_ORDER)
		silk_scale_vector_flp(xXk, temp, LTP_ORDER)
		ro += subfr_length
	}
}

@(private = "file")
ltp_analysis_filter_flp :: proc "contextless" (LTP_res: []f32, x: []f32, xo_: int, B: []f32, pitchL: []i32, inv_gains: []f32, subfr_length: int, nb_subfr: int, pre_length: int) {
	xo := xo_
	ro := 0
	for k in 0 ..< nb_subfr {
		xl := xo - int(pitchL[k])
		inv_gain := inv_gains[k]
		Btmp: [LTP_ORDER]f32
		for i in 0 ..< LTP_ORDER do Btmp[i] = B[k * LTP_ORDER + i]
		for i in 0 ..< subfr_length + pre_length {
			v := x[xo + i]
			for j in 0 ..< LTP_ORDER do v -= Btmp[j] * x[xl + LTP_ORDER / 2 - j]
			v *= inv_gain
			LTP_res[ro + i] = v
			xl += 1
		}
		ro += subfr_length + pre_length
		xo += subfr_length
	}
}

@(private = "file")
burg_modified_flp :: proc "contextless" (A: []f32, x: []f32, min_inv_gain: f32, subfr_length: int, nb_subfr: int, D: int) -> f32 {
	C_first_row: [24]f64
	C_last_row: [24]f64
	CAf: [25]f64
	CAb: [25]f64
	Af: [24]f64
	C0 := silk_energy_flp(x, nb_subfr * subfr_length)
	for s in 0 ..< nb_subfr {
		xp := x[s * subfr_length:]
		for n in 1 ..< D + 1 do C_first_row[n - 1] += silk_inner_product_flp(xp, xp[n:], subfr_length - n)
	}
	C_last_row = C_first_row
	cond := f64(f32(1e-5))
	CAf[0] = C0 + cond * C0 + f64(f32(1e-9))
	CAb[0] = CAf[0]
	inv_gain: f64 = 1.0
	reached_max_gain := false
	mig := f64(min_inv_gain)
	for n in 0 ..< D {
		for s in 0 ..< nb_subfr {
			xp := x[s * subfr_length:]
			tmp1 := f64(xp[n])
			tmp2 := f64(xp[subfr_length - n - 1])
			for k in 0 ..< n {
				C_first_row[k] -= f64(xp[n] * xp[n - k - 1])
				C_last_row[k] -= f64(xp[subfr_length - n - 1] * xp[subfr_length - n + k])
				Atmp := Af[k]
				tmp1 += f64(xp[n - k - 1]) * Atmp
				tmp2 += f64(xp[subfr_length - n + k]) * Atmp
			}
			for k in 0 ..= n {
				CAf[k] -= tmp1 * f64(xp[n - k])
				CAb[k] -= tmp2 * f64(xp[subfr_length - n + k - 1])
			}
		}
		tmp1 := C_first_row[n]
		tmp2 := C_last_row[n]
		for k in 0 ..< n {
			Atmp := Af[k]
			tmp1 += C_last_row[n - k - 1] * Atmp
			tmp2 += C_first_row[n - k - 1] * Atmp
		}
		CAf[n + 1] = tmp1
		CAb[n + 1] = tmp2
		num := CAb[n + 1]
		nrg_b := CAb[0]
		nrg_f := CAf[0]
		for k in 0 ..< n {
			Atmp := Af[k]
			num += CAb[n - k] * Atmp
			nrg_b += CAb[k + 1] * Atmp
			nrg_f += CAf[k + 1] * Atmp
		}
		rc := -2.0 * num / (nrg_f + nrg_b)
		tmp1 = inv_gain * (1.0 - rc * rc)
		if tmp1 <= mig {
			rc = math.sqrt(1.0 - mig / inv_gain)
			if num > 0 do rc = -rc
			inv_gain = mig
			reached_max_gain = true
		} else {
			inv_gain = tmp1
		}
		for k in 0 ..< (n + 1) >> 1 {
			t1 := Af[k]
			t2 := Af[n - k - 1]
			Af[k] = t1 + rc * t2
			Af[n - k - 1] = t2 + rc * t1
		}
		Af[n] = rc
		if reached_max_gain {
			for k in n + 1 ..< D do Af[k] = 0
			break
		}
		for k in 0 ..= n + 1 {
			t1 := CAf[k]
			CAf[k] += rc * CAb[n - k + 1]
			CAb[n - k + 1] += rc * t1
		}
	}
	nrg_f: f64
	if reached_max_gain {
		for k in 0 ..< D do A[k] = f32(-Af[k])
		for s in 0 ..< nb_subfr do C0 -= silk_energy_flp(x[s * subfr_length:], D)
		nrg_f = C0 * inv_gain
	} else {
		nrg_f = CAf[0]
		tmp1: f64 = 1.0
		for k in 0 ..< D {
			Atmp := Af[k]
			nrg_f += CAf[k + 1] * Atmp
			tmp1 += Atmp * Atmp
			A[k] = f32(-Atmp)
		}
		nrg_f -= cond * C0 * tmp1
	}
	return f32(nrg_f)
}

@(private = "file")
find_lpc_flp :: proc "contextless" (c: ^Silk_Enc_Common, nlsf_q15: []i16, x: []f32, min_inv_gain: f32) {
	a: [MAX_LPC_ORDER]f32
	a_tmp: [MAX_LPC_ORDER]f32
	nlsf0_q15: [MAX_LPC_ORDER]i16
	LPC_res: [MAX_FRAME_LENGTH + MAX_NB_SUBFR * MAX_LPC_ORDER]f32
	order := int(c.predict_lpc_order)
	subfr_length := int(c.subfr_length) + order
	c.indices.nlsf_interp_coef_q2 = 4
	res_nrg := burg_modified_flp(a[:], x, min_inv_gain, subfr_length, int(c.nb_subfr), order)
	if c.use_interpolated_nlsfs != 0 && c.first_frame_after_reset == 0 && c.nb_subfr == MAX_NB_SUBFR {
		res_nrg -= burg_modified_flp(a_tmp[:], x[(MAX_NB_SUBFR / 2) * subfr_length:], min_inv_gain, subfr_length, MAX_NB_SUBFR / 2, order)
		silk_a2nlsf_flp(nlsf_q15, a_tmp[:], order)
		res_nrg_2nd := max(f32)
		for k := 3; k >= 0; k -= 1 {
			silk_interpolate(nlsf0_q15[:], c.prev_nlsfq_q15[:], nlsf_q15, i32(k), order)
			silk_nlsf2a_flp(a_tmp[:], nlsf0_q15[:], order)
			silk_lpc_analysis_filter_flp(LPC_res[:], a_tmp[:], x, 2 * subfr_length, order)
			res_nrg_interp := f32(silk_energy_flp(LPC_res[order:], subfr_length - order) + silk_energy_flp(LPC_res[order + subfr_length:], subfr_length - order))
			if res_nrg_interp < res_nrg {
				res_nrg = res_nrg_interp
				c.indices.nlsf_interp_coef_q2 = i8(k)
			} else if res_nrg_interp > res_nrg_2nd {
				break
			}
			res_nrg_2nd = res_nrg_interp
		}
	}
	if c.indices.nlsf_interp_coef_q2 == 4 do silk_a2nlsf_flp(nlsf_q15, a[:], order)
}

@(private = "file")
residual_energy_flp :: proc "contextless" (nrgs: []f32, x: []f32, a: ^[2][MAX_LPC_ORDER]f32, gains: []f32, subfr_length: int, nb_subfr: int, order: int) {
	LPC_res: [(MAX_FRAME_LENGTH + MAX_NB_SUBFR * MAX_LPC_ORDER) / 2]f32
	shift := order + subfr_length
	silk_lpc_analysis_filter_flp(LPC_res[:], a[0][:], x, 2 * shift, order)
	nrgs[0] = f32(f64(gains[0] * gains[0]) * silk_energy_flp(LPC_res[order:], subfr_length))
	nrgs[1] = f32(f64(gains[1] * gains[1]) * silk_energy_flp(LPC_res[order + shift:], subfr_length))
	if nb_subfr == MAX_NB_SUBFR {
		silk_lpc_analysis_filter_flp(LPC_res[:], a[1][:], x[2 * shift:], 2 * shift, order)
		nrgs[2] = f32(f64(gains[2] * gains[2]) * silk_energy_flp(LPC_res[order:], subfr_length))
		nrgs[3] = f32(f64(gains[3] * gains[3]) * silk_energy_flp(LPC_res[order + shift:], subfr_length))
	}
}

@(private = "file")
ltp_scale_ctrl_flp :: proc "contextless" (enc: ^Silk_Enc_Chan, ctrl: ^Silk_Enc_Ctrl, cond_coding: int) {
	c := &enc.cmn
	if cond_coding == CODE_INDEPENDENTLY {
		round_loss := c.packet_loss_perc + c.n_frames_per_packet
		v := f32(round_loss) * ctrl.ltp_red_cod_gain * 0.1
		v = v > 2.0 ? 2.0 : (v < 0.0 ? 0.0 : v)
		c.indices.ltp_scale_index = i8(v)
	} else {
		c.indices.ltp_scale_index = 0
	}
	ctrl.ltp_scale = f32(silk_LTPScales_table_Q14[c.indices.ltp_scale_index]) / 16384.0
}

@(private = "file")
find_pred_coefs_flp :: proc "contextless" (enc: ^Silk_Enc_Chan, ctrl: ^Silk_Enc_Ctrl, res_pitch: []f32, rpo: int, xo: int, cond_coding: int) {
	c := &enc.cmn
	XXLTP: [MAX_NB_SUBFR * LTP_ORDER * LTP_ORDER]f32
	xXLTP: [MAX_NB_SUBFR * LTP_ORDER]f32
	inv_gains: [MAX_NB_SUBFR]f32
	nlsf_q15: [MAX_LPC_ORDER]i16
	LPC_in_pre: [MAX_NB_SUBFR * MAX_LPC_ORDER + MAX_FRAME_LENGTH]f32
	nb := int(c.nb_subfr)
	sl := int(c.subfr_length)
	order := int(c.predict_lpc_order)
	for i in 0 ..< nb do inv_gains[i] = 1.0 / ctrl.gains[i]
	if c.indices.signal_type == TYPE_VOICED {
		find_ltp_flp(XXLTP[:], xXLTP[:], res_pitch, rpo, ctrl.pitch_l[:], sl, nb)
		silk_quant_ltp_gains_flp(ctrl.ltp_coef[:], c.indices.ltp_index[:], &c.indices.per_index, &c.sum_log_gain_q7, &ctrl.ltp_red_cod_gain, XXLTP[:],
			xXLTP[:], sl, nb)
		ltp_scale_ctrl_flp(enc, ctrl, cond_coding)
		ltp_analysis_filter_flp(LPC_in_pre[:], enc.x_buf[:], xo - order, ctrl.ltp_coef[:], ctrl.pitch_l[:], inv_gains[:], sl, nb, order)
	} else {
		xp := xo - order
		pp := 0
		for i in 0 ..< nb {
			silk_scale_copy_vector_flp(LPC_in_pre[pp:], enc.x_buf[xp:], inv_gains[i], sl + order)
			pp += sl + order
			xp += sl
		}
		for i in 0 ..< nb * LTP_ORDER do ctrl.ltp_coef[i] = 0
		ctrl.ltp_red_cod_gain = 0
		c.sum_log_gain_q7 = 0
	}
	min_inv_gain: f32
	if c.first_frame_after_reset != 0 {
		one := f32(1.0)
		min_inv_gain = one / 1e2
	} else {
		min_inv_gain = f32(silk_pow_f(2, f64(ctrl.ltp_red_cod_gain / 3))) / 1e4
		min_inv_gain /= 0.25 + 0.75 * ctrl.coding_quality
	}
	find_lpc_flp(c, nlsf_q15[:], LPC_in_pre[:], min_inv_gain)
	silk_process_nlsfs_flp(c, &ctrl.pred_coef, nlsf_q15[:], c.prev_nlsfq_q15[:])
	residual_energy_flp(ctrl.res_nrg[:], LPC_in_pre[:], &ctrl.pred_coef, ctrl.gains[:], sl, nb, order)
	c.prev_nlsfq_q15 = nlsf_q15
}

@(private = "file")
process_gains_flp :: proc "contextless" (enc: ^Silk_Enc_Chan, ctrl: ^Silk_Enc_Ctrl, cond_coding: int) {
	c := &enc.cmn
	sh := &enc.shape
	pGains_q16: [MAX_NB_SUBFR]i32
	nb := int(c.nb_subfr)
	if c.indices.signal_type == TYPE_VOICED {
		s := 1.0 - 0.5 * silk_sigmoid_flp(0.25 * (ctrl.ltp_red_cod_gain - 12.0))
		for k in 0 ..< nb do ctrl.gains[k] *= s
	}
	g033 := f32(0.33)
	InvMaxSqrVal := f32(silk_pow_f(2.0, f64(g033 * (21.0 - f32(c.snr_db_q7) * (1 / 128.0)))) / f64(c.subfr_length))
	for k in 0 ..< nb {
		gain := ctrl.gains[k]
		gain = math.sqrt(gain * gain + ctrl.res_nrg[k] * InvMaxSqrVal)
		ctrl.gains[k] = min(gain, 32767.0)
	}
	for k in 0 ..< nb do pGains_q16[k] = i32(ctrl.gains[k] * 65536.0)
	ctrl.gains_unq_q16 = pGains_q16
	ctrl.last_gain_index_prev = sh.last_gain_index
	silk_gains_quant(c.indices.gains_indices[:], pGains_q16[:], &sh.last_gain_index, cond_coding == CODE_CONDITIONALLY, nb)
	for k in 0 ..< nb do ctrl.gains[k] = f32(pGains_q16[k]) / 65536.0
	if c.indices.signal_type == TYPE_VOICED {
		if ctrl.ltp_red_cod_gain + f32(c.input_tilt_q15) * (1.0 / 32768.0) > 1.0 {
			c.indices.quant_offset_type = 0
		} else {
			c.indices.quant_offset_type = 1
		}
	}
	quant_offset := f32(silk_Quantization_Offsets_Q10[c.indices.signal_type >> 1][c.indices.quant_offset_type]) / 1024.0
	l := f32(1.2)
	l += -0.05 * f32(c.n_states_delayed_decision)
	l += -0.2 * f32(c.speech_activity_q8) * (1.0 / 256.0)
	l += -0.1 * ctrl.input_quality
	l += -0.2 * ctrl.coding_quality
	l += 0.8 * quant_offset
	ctrl.lambda = l
}

// ---- NSQ wrapper / LBRR / frame encoder

@(private = "file")
nsq_wrapper_flp :: proc "contextless" (enc: ^Silk_Enc_Chan, ctrl: ^Silk_Enc_Ctrl, ix: ^Side_Info, nsq: ^Silk_NSQ_State, pulses: []i8, x: []f32) {
	c := &enc.cmn
	prm: Silk_NSQ_Params
	x16: [MAX_FRAME_LENGTH]i16
	nb := int(c.nb_subfr)
	for i in 0 ..< nb {
		for j in 0 ..< int(c.shaping_lpc_order) {
			prm.ar_q13[i * SE_MAX_SHAPE_LPC_ORDER + j] = i16(float2int(ctrl.ar[i * SE_MAX_SHAPE_LPC_ORDER + j] * 8192.0))
		}
	}
	for i in 0 ..< nb {
		prm.lf_shp_q14[i] = i32(u32(float2int(ctrl.lf_ar_shp[i] * 16384.0)) << 16) | i32(u16(float2int(ctrl.lf_ma_shp[i] * 16384.0)))
		prm.tilt_q14[i] = float2int(ctrl.tilt[i] * 16384.0)
		prm.harm_shape_gain_q14[i] = float2int(ctrl.harm_shape_gain[i] * 16384.0)
	}
	prm.lambda_q10 = float2int(ctrl.lambda * 1024.0)
	for i in 0 ..< nb * LTP_ORDER do prm.ltp_coef_q14[i] = i16(float2int(ctrl.ltp_coef[i] * 16384.0))
	for j in 0 ..< 2 {
		for i in 0 ..< int(c.predict_lpc_order) do prm.pred_coef_q12[j * MAX_LPC_ORDER + i] = i16(float2int(ctrl.pred_coef[j][i] * 4096.0))
	}
	for i in 0 ..< nb do prm.gains_q16[i] = float2int(ctrl.gains[i] * 65536.0)
	if ix.signal_type == TYPE_VOICED {
		prm.ltp_scale_q14 = i32(silk_LTPScales_table_Q14[ix.ltp_scale_index])
	} else {
		prm.ltp_scale_q14 = 0
	}
	for i in 0 ..< int(c.frame_length) do x16[i] = i16(float2int(x[i]))
	prm.pitch_l = ctrl.pitch_l
	if c.n_states_delayed_decision > 1 || c.warping_q16 > 0 {
		silk_nsq_del_dec(c, nsq, ix, x16[:], pulses, &prm)
	} else {
		silk_nsq(c, nsq, ix, x16[:], pulses, &prm)
	}
}

@(private = "file")
lbrr_encode_flp :: proc "contextless" (enc: ^Silk_Enc_Chan, ctrl: ^Silk_Enc_Ctrl, xfw: []f32, cond_coding: int) {
	c := &enc.cmn
	gains_q16: [MAX_NB_SUBFR]i32
	temp_gains: [MAX_NB_SUBFR]f32
	fe := int(c.n_frames_encoded)
	ix := &c.indices_lbrr[fe]
	nb := int(c.nb_subfr)
	if c.lbrr_enabled != 0 && c.speech_activity_q8 > SE_FIX_LBRR_SPEECH_ACTIVITY_THRES_Q8 {
		c.lbrr_flags[fe] = 1
		nsq_lbrr := c.snsq
		ix^ = c.indices
		temp_gains = ctrl.gains
		if fe == 0 || c.lbrr_flags[fe - 1] == 0 {
			c.lbrr_prev_last_gain_index = enc.shape.last_gain_index
			ix.gains_indices[0] = i8(i32(ix.gains_indices[0]) + c.lbrr_gain_increases)
			ix.gains_indices[0] = i8(min(i32(ix.gains_indices[0]), N_LEVELS_QGAIN - 1))
		}
		silk_enc_gains_dequant(gains_q16[:], ix.gains_indices[:], &c.lbrr_prev_last_gain_index, cond_coding == CODE_CONDITIONALLY, nb)
		for k in 0 ..< nb do ctrl.gains[k] = f32(gains_q16[k]) * (1.0 / 65536.0)
		nsq_wrapper_flp(enc, ctrl, ix, &nsq_lbrr, c.pulses_lbrr[fe][:], xfw)
		for k in 0 ..< nb do ctrl.gains[k] = temp_gains[k]
	}
}

silk_encode_do_vad_flp :: proc "contextless" (enc: ^Silk_Enc_Chan, activity: int) {
	c := &enc.cmn
	thr :: SE_FIX_SPEECH_ACTIVITY_DTX_THRES_Q8
	silk_vad_get_sa_q8(c, c.input_buf[1:])
	if activity == SE_VAD_NO_ACTIVITY && c.speech_activity_q8 >= thr do c.speech_activity_q8 = thr - 1
	if c.speech_activity_q8 < thr {
		c.indices.signal_type = TYPE_NO_VOICE_ACTIVITY
		c.no_speech_counter += 1
		if c.no_speech_counter <= SE_NB_SPEECH_FRAMES_BEFORE_DTX {
			c.in_dtx = 0
		} else if c.no_speech_counter > SE_MAX_CONSECUTIVE_DTX + SE_NB_SPEECH_FRAMES_BEFORE_DTX {
			c.no_speech_counter = SE_NB_SPEECH_FRAMES_BEFORE_DTX
			c.in_dtx = 0
		}
		c.vad_flags[c.n_frames_encoded] = 0
	} else {
		c.no_speech_counter = 0
		c.in_dtx = 0
		c.indices.signal_type = TYPE_UNVOICED
		c.vad_flags[c.n_frames_encoded] = 1
	}
}

silk_encode_frame_flp :: proc "contextless" (enc: ^Silk_Enc_Chan, pn_bytes_out: ^i32, ps_range_enc: ^Range, cond_coding: int, max_bits: i32, use_cbr: bool) -> int {
	c := &enc.cmn
	ctrl: Silk_Enc_Ctrl
	res_pitch: [2 * MAX_FRAME_LENGTH + SE_LA_PITCH_MAX]f32
	gain_lock: [MAX_NB_SUBFR]bool
	best_gain_mult: [MAX_NB_SUBFR]i16
	best_sum: [MAX_NB_SUBFR]i32
	pGains_q16: [MAX_NB_SUBFR]i32
	ec_buf_copy: [1275]u8
	last_gain_index_copy2: i8 = 0
	n_bits_lower, n_bits_upper: i32
	gain_mult_lower, gain_mult_upper: i32
	c.indices.seed = i8(c.frame_counter & 3)
	c.frame_counter += 1
	xo := int(c.ltp_mem_length) // x_frame = x_buf + ltp_mem_length
	rpo := int(c.ltp_mem_length) // res_pitch_frame = res_pitch + ltp_mem_length
	fl := int(c.frame_length)
	la := int(SE_LA_SHAPE_MS * c.fs_khz)
	silk_lp_variable_cutoff(&c.slp, c.input_buf[1:], fl)
	for k in 0 ..< fl do enc.x_buf[xo + la + k] = f32(c.input_buf[1 + k])
	for i in 0 ..< 8 {
		enc.x_buf[xo + la + i * (fl >> 3)] += f32(1 - (i & 2)) * 1e-6
	}
	if c.prefill_flag == 0 {
		find_pitch_lags_flp(enc, &ctrl, res_pitch[:], xo)
		noise_shape_analysis_flp(enc, &ctrl, res_pitch[rpo:], xo)
		find_pred_coefs_flp(enc, &ctrl, res_pitch[:], rpo, xo, cond_coding)
		process_gains_flp(enc, &ctrl, cond_coding)
		x_frame := enc.x_buf[xo:]
		lbrr_encode_flp(enc, &ctrl, x_frame, cond_coding)
		max_iter :: 6
		gain_mult_q8: i32 = 1 << 8
		found_lower := false
		found_upper := false
		gains_id := silk_gains_id(c.indices.gains_indices[:], int(c.nb_subfr))
		gains_id_lower: i32 = -1
		gains_id_upper: i32 = -1
		range_copy := ps_range_enc^
		nsq_copy := c.snsq
		seed_copy := c.indices.seed
		ec_prev_lag_index_copy := c.ec_prev_lag_index
		ec_prev_signal_type_copy := c.ec_prev_signal_type
		range_copy2: Range
		nsq_copy2: Silk_NSQ_State
		n_bits: i32
		for iter := 0; ; iter += 1 {
			if gains_id == gains_id_lower {
				n_bits = n_bits_lower
			} else if gains_id == gains_id_upper {
				n_bits = n_bits_upper
			} else {
				if iter > 0 {
					ps_range_enc^ = range_copy
					c.snsq = nsq_copy
					c.indices.seed = seed_copy
					c.ec_prev_lag_index = ec_prev_lag_index_copy
					c.ec_prev_signal_type = ec_prev_signal_type_copy
				}
				nsq_wrapper_flp(enc, &ctrl, &c.indices, &c.snsq, c.pulses[:], x_frame)
				if iter == max_iter && !found_lower do range_copy2 = ps_range_enc^
				silk_encode_indices(c, ps_range_enc, int(c.n_frames_encoded), false, cond_coding)
				silk_encode_pulses(ps_range_enc, i32(c.indices.signal_type), i32(c.indices.quant_offset_type), c.pulses[:], fl)
				n_bits = ec_tell(ps_range_enc)
				if iter == max_iter && !found_lower && n_bits > max_bits {
					ps_range_enc^ = range_copy2
					enc.shape.last_gain_index = ctrl.last_gain_index_prev
					for i in 0 ..< int(c.nb_subfr) do c.indices.gains_indices[i] = 4
					if cond_coding != CODE_CONDITIONALLY do c.indices.gains_indices[0] = ctrl.last_gain_index_prev
					c.ec_prev_lag_index = ec_prev_lag_index_copy
					c.ec_prev_signal_type = ec_prev_signal_type_copy
					for i in 0 ..< fl do c.pulses[i] = 0
					silk_encode_indices(c, ps_range_enc, int(c.n_frames_encoded), false, cond_coding)
					silk_encode_pulses(ps_range_enc, i32(c.indices.signal_type), i32(c.indices.quant_offset_type), c.pulses[:], fl)
					n_bits = ec_tell(ps_range_enc)
				}
				if !use_cbr && iter == 0 && n_bits <= max_bits do break
			}
			if iter == max_iter {
				if found_lower && (gains_id == gains_id_lower || n_bits > max_bits) {
					ps_range_enc^ = range_copy2
					copy(ps_range_enc.buf[:range_copy2.offs], ec_buf_copy[:range_copy2.offs])
					c.snsq = nsq_copy2
					enc.shape.last_gain_index = last_gain_index_copy2
				}
				break
			}
			if n_bits > max_bits {
				if !found_lower && iter >= 2 {
					ctrl.lambda = max(ctrl.lambda * 1.5, 1.5)
					c.indices.quant_offset_type = 0
					found_upper = false
					gains_id_upper = -1
				} else {
					found_upper = true
					n_bits_upper = n_bits
					gain_mult_upper = gain_mult_q8
					gains_id_upper = gains_id
				}
			} else if n_bits < max_bits - 5 {
				found_lower = true
				n_bits_lower = n_bits
				gain_mult_lower = gain_mult_q8
				if gains_id != gains_id_lower {
					gains_id_lower = gains_id
					range_copy2 = ps_range_enc^
					copy(ec_buf_copy[:ps_range_enc.offs], ps_range_enc.buf[:ps_range_enc.offs])
					nsq_copy2 = c.snsq
					last_gain_index_copy2 = enc.shape.last_gain_index
				}
			} else {
				break
			}
			if !found_lower && n_bits > max_bits {
				sl := int(c.subfr_length)
				for i in 0 ..< int(c.nb_subfr) {
					sum: i32 = 0
					for j in i * sl ..< (i + 1) * sl do sum += silk_abs(i32(c.pulses[j]))
					if iter == 0 || (sum < best_sum[i] && !gain_lock[i]) {
						best_sum[i] = sum
						best_gain_mult[i] = i16(gain_mult_q8)
					} else {
						gain_lock[i] = true
					}
				}
			}
			if !(found_lower && found_upper) {
				if n_bits > max_bits {
					if gain_mult_q8 < 16384 {
						gain_mult_q8 *= 2
					} else {
						gain_mult_q8 = 32767
					}
				} else {
					gain_factor_q16 := log2lin(((n_bits - max_bits) << 7) / i32(fl) + (16 << 7))
					gain_mult_q8 = smulwb(gain_factor_q16, gain_mult_q8)
				}
			} else {
				gain_mult_q8 = gain_mult_lower + ((gain_mult_upper - gain_mult_lower) * (max_bits - n_bits_lower)) / (n_bits_upper - n_bits_lower)
				if gain_mult_q8 > gain_mult_lower + ((gain_mult_upper - gain_mult_lower) >> 2) {
					gain_mult_q8 = gain_mult_lower + ((gain_mult_upper - gain_mult_lower) >> 2)
				} else if gain_mult_q8 < gain_mult_upper - ((gain_mult_upper - gain_mult_lower) >> 2) {
					gain_mult_q8 = gain_mult_upper - ((gain_mult_upper - gain_mult_lower) >> 2)
				}
			}
			gain_mult_q8 = i32(i16(gain_mult_q8))
			for i in 0 ..< int(c.nb_subfr) {
				tmp := gain_lock[i] ? i32(best_gain_mult[i]) : gain_mult_q8
				pGains_q16[i] = lshift_sat32(smulwb(ctrl.gains_unq_q16[i], tmp), 8)
			}
			enc.shape.last_gain_index = ctrl.last_gain_index_prev
			silk_gains_quant(c.indices.gains_indices[:], pGains_q16[:], &enc.shape.last_gain_index, cond_coding == CODE_CONDITIONALLY, int(c.nb_subfr))
			gains_id = silk_gains_id(c.indices.gains_indices[:], int(c.nb_subfr))
			for i in 0 ..< int(c.nb_subfr) do ctrl.gains[i] = f32(pGains_q16[i]) / 65536.0
		}
	}
	n := int(c.ltp_mem_length) + la
	copy(enc.x_buf[:n], enc.x_buf[fl:fl + n])
	if c.prefill_flag != 0 {
		pn_bytes_out^ = 0
		return 0
	}
	c.prev_lag = ctrl.pitch_l[c.nb_subfr - 1]
	c.prev_signal_type = c.indices.signal_type
	c.first_frame_after_reset = 0
	pn_bytes_out^ = (ec_tell(ps_range_enc) + 7) >> 3
	return 0
}
