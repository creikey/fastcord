package opus

// SILK encoder: gain quantization, side-info / pulse entropy coding, LTP gain
// quantization and stereo prediction coding. Fixed point, bit-exact.

SE_GAIN_SCALE_Q16 :: (65536 * (N_LEVELS_QGAIN - 1)) / (((88 - 2) * 128) / 6)

silk_gains_quant :: proc "contextless" (ind: []i8, gain_q16: []i32, prev_ind: ^i8, conditional: bool, nb_subfr: int) {
	for k in 0 ..< nb_subfr {
		ind[k] = i8(smulwb(SE_GAIN_SCALE_Q16, lin2log(gain_q16[k]) - GAIN_OFFSET))
		if ind[k] < prev_ind^ do ind[k] += 1
		ind[k] = i8(limit32(i32(ind[k]), 0, N_LEVELS_QGAIN - 1))
		if k == 0 && !conditional {
			ind[k] = i8(limit32(i32(ind[k]), i32(prev_ind^) + MIN_DELTA_GAIN_QUANT, N_LEVELS_QGAIN - 1))
			prev_ind^ = ind[k]
		} else {
			ind[k] = i8(i32(ind[k]) - i32(prev_ind^))
			dbl := 2 * MAX_DELTA_GAIN_QUANT - N_LEVELS_QGAIN + i32(prev_ind^)
			if i32(ind[k]) > dbl {
				ind[k] = i8(dbl + ((i32(ind[k]) - dbl + 1) >> 1))
			}
			ind[k] = i8(limit32(i32(ind[k]), MIN_DELTA_GAIN_QUANT, MAX_DELTA_GAIN_QUANT))
			if i32(ind[k]) > dbl {
				prev_ind^ = i8(i32(prev_ind^) + (i32(ind[k]) << 1) - dbl)
				prev_ind^ = i8(min(i32(prev_ind^), N_LEVELS_QGAIN - 1))
			} else {
				prev_ind^ = i8(i32(prev_ind^) + i32(ind[k]))
			}
			ind[k] = i8(i32(ind[k]) - MIN_DELTA_GAIN_QUANT)
		}
		gain_q16[k] = log2lin(min(smulwb(INV_SCALE_Q16, i32(prev_ind^)) + GAIN_OFFSET, 3967))
	}
}

silk_enc_gains_dequant :: proc "contextless" (gain_q16: []i32, ind: []i8, prev_ind: ^i8, conditional: bool, nb_subfr: int) {
	for k in 0 ..< nb_subfr {
		if k == 0 && !conditional {
			prev_ind^ = i8(max(i32(ind[k]), i32(prev_ind^) - 16))
		} else {
			ind_tmp := i32(ind[k]) + MIN_DELTA_GAIN_QUANT
			dbl := 2 * MAX_DELTA_GAIN_QUANT - N_LEVELS_QGAIN + i32(prev_ind^)
			if ind_tmp > dbl {
				prev_ind^ = i8(i32(prev_ind^) + (ind_tmp << 1) - dbl)
			} else {
				prev_ind^ = i8(i32(prev_ind^) + ind_tmp)
			}
		}
		prev_ind^ = i8(limit32(i32(prev_ind^), 0, N_LEVELS_QGAIN - 1))
		gain_q16[k] = log2lin(min(smulwb(INV_SCALE_Q16, i32(prev_ind^)) + GAIN_OFFSET, 3967))
	}
}

silk_gains_id :: proc "contextless" (ind: []i8, nb_subfr: int) -> i32 {
	id: i32 = 0
	for k in 0 ..< nb_subfr do id = i32(ind[k]) + (id << 8)
	return id
}

silk_enc_ltp_gain_icdf :: proc "contextless" (i: int) -> []u8 {
	switch i {
	case 0: return silk_LTP_gain_iCDF_0[:]
	case 1: return silk_LTP_gain_iCDF_1[:]
	}
	return silk_LTP_gain_iCDF_2[:]
}

silk_encode_indices :: proc "contextless" (cmn: ^Silk_Enc_Common, enc: ^Range, frame_index: int, encode_lbrr: bool, cond_coding: int) {
	ec_ix: [MAX_LPC_ORDER]i16
	pred_q8: [MAX_LPC_ORDER]u8
	ix := encode_lbrr ? &cmn.indices_lbrr[frame_index] : &cmn.indices
	type_offset := 2 * i32(ix.signal_type) + i32(ix.quant_offset_type)
	if encode_lbrr || type_offset >= 2 {
		ec_enc_icdf(enc, type_offset - 2, silk_type_offset_VAD_iCDF[:], 8)
	} else {
		ec_enc_icdf(enc, type_offset, silk_type_offset_no_VAD_iCDF[:], 8)
	}
	if cond_coding == CODE_CONDITIONALLY {
		ec_enc_icdf(enc, i32(ix.gains_indices[0]), silk_delta_gain_iCDF[:], 8)
	} else {
		ec_enc_icdf(enc, i32(ix.gains_indices[0]) >> 3, silk_gain_iCDF[ix.signal_type][:], 8)
		ec_enc_icdf(enc, i32(ix.gains_indices[0]) & 7, silk_uniform8_iCDF[:], 8)
	}
	for i in 1 ..< int(cmn.nb_subfr) do ec_enc_icdf(enc, i32(ix.gains_indices[i]), silk_delta_gain_iCDF[:], 8)
	cb := cmn.nlsf_cb
	ec_enc_icdf(enc, i32(ix.nlsf_indices[0]), cb.cb1_icdf[(i32(ix.signal_type) >> 1) * cb.n_vectors:], 8)
	silk_enc_nlsf_unpack(ec_ix[:], pred_q8[:], cb, i32(ix.nlsf_indices[0]))
	for i in 0 ..< int(cb.order) {
		v := i32(ix.nlsf_indices[i + 1])
		if v >= NLSF_QUANT_MAX_AMPLITUDE {
			ec_enc_icdf(enc, 2 * NLSF_QUANT_MAX_AMPLITUDE, cb.ec_icdf[ec_ix[i]:], 8)
			ec_enc_icdf(enc, v - NLSF_QUANT_MAX_AMPLITUDE, silk_NLSF_EXT_iCDF[:], 8)
		} else if v <= -NLSF_QUANT_MAX_AMPLITUDE {
			ec_enc_icdf(enc, 0, cb.ec_icdf[ec_ix[i]:], 8)
			ec_enc_icdf(enc, -v - NLSF_QUANT_MAX_AMPLITUDE, silk_NLSF_EXT_iCDF[:], 8)
		} else {
			ec_enc_icdf(enc, v + NLSF_QUANT_MAX_AMPLITUDE, cb.ec_icdf[ec_ix[i]:], 8)
		}
	}
	if cmn.nb_subfr == MAX_NB_SUBFR {
		ec_enc_icdf(enc, i32(ix.nlsf_interp_coef_q2), silk_NLSF_interpolation_factor_iCDF[:], 8)
	}
	if ix.signal_type == TYPE_VOICED {
		encode_absolute := true
		if cond_coding == CODE_CONDITIONALLY && cmn.ec_prev_signal_type == TYPE_VOICED {
			delta := i32(ix.lag_index) - i32(cmn.ec_prev_lag_index)
			if delta < -8 || delta > 11 {
				delta = 0
			} else {
				delta = delta + 9
				encode_absolute = false
			}
			ec_enc_icdf(enc, delta, silk_pitch_delta_iCDF[:], 8)
		}
		if encode_absolute {
			half := cmn.fs_khz >> 1
			hi := i32(ix.lag_index) / half
			lo := i32(ix.lag_index) - smulbb(hi, half)
			ec_enc_icdf(enc, hi, silk_pitch_lag_iCDF[:], 8)
			ec_enc_icdf(enc, lo, cmn.pitch_lag_low_bits_icdf, 8)
		}
		cmn.ec_prev_lag_index = ix.lag_index
		ec_enc_icdf(enc, i32(ix.contour_index), cmn.pitch_contour_icdf, 8)
		ec_enc_icdf(enc, i32(ix.per_index), silk_LTP_per_index_iCDF[:], 8)
		for k in 0 ..< int(cmn.nb_subfr) {
			ec_enc_icdf(enc, i32(ix.ltp_index[k]), silk_enc_ltp_gain_icdf(int(ix.per_index)), 8)
		}
		if cond_coding == CODE_INDEPENDENTLY {
			ec_enc_icdf(enc, i32(ix.ltp_scale_index), silk_LTPscale_iCDF[:], 8)
		}
	}
	cmn.ec_prev_signal_type = i32(ix.signal_type)
	ec_enc_icdf(enc, i32(ix.seed), silk_uniform4_iCDF[:], 8)
}

@(private = "file")
combine_and_check :: proc "contextless" (out: []i32, in_: []i32, max_pulses: i32, len: int) -> i32 {
	for k in 0 ..< len {
		sum := in_[2 * k] + in_[2 * k + 1]
		if sum > max_pulses do return 1
		out[k] = sum
	}
	return 0
}

@(private = "file")
encode_split :: #force_inline proc "contextless" (enc: ^Range, p_child1: i32, p: i32, table: []u8) {
	if p > 0 do ec_enc_icdf(enc, p_child1, table[silk_shell_code_table_offsets[p]:], 8)
}

@(private = "file")
shell_encoder :: proc "contextless" (enc: ^Range, p0: []i32) {
	p1: [8]i32
	p2: [4]i32
	p3: [2]i32
	p4: [1]i32
	for k in 0 ..< 8 do p1[k] = p0[2 * k] + p0[2 * k + 1]
	for k in 0 ..< 4 do p2[k] = p1[2 * k] + p1[2 * k + 1]
	for k in 0 ..< 2 do p3[k] = p2[2 * k] + p2[2 * k + 1]
	p4[0] = p3[0] + p3[1]
	t0 := silk_shell_code_table0[:]
	t1 := silk_shell_code_table1[:]
	t2 := silk_shell_code_table2[:]
	t3 := silk_shell_code_table3[:]
	encode_split(enc, p3[0], p4[0], t3)
	encode_split(enc, p2[0], p3[0], t2)
	encode_split(enc, p1[0], p2[0], t1)
	encode_split(enc, p0[0], p1[0], t0)
	encode_split(enc, p0[2], p1[1], t0)
	encode_split(enc, p1[2], p2[1], t1)
	encode_split(enc, p0[4], p1[2], t0)
	encode_split(enc, p0[6], p1[3], t0)
	encode_split(enc, p2[2], p3[1], t2)
	encode_split(enc, p1[4], p2[2], t1)
	encode_split(enc, p0[8], p1[4], t0)
	encode_split(enc, p0[10], p1[5], t0)
	encode_split(enc, p1[6], p2[3], t1)
	encode_split(enc, p0[12], p1[6], t0)
	encode_split(enc, p0[14], p1[7], t0)
}

// pulses must have room for frame_length rounded up to a multiple of 16
silk_encode_pulses :: proc "contextless" (enc: ^Range, signal_type, quant_offset_type: i32, pulses: []i8, frame_length: int) {
	pulses_comb: [8]i32
	abs_pulses: [MAX_FRAME_LENGTH + SHELL_CODEC_FRAME_LENGTH]i32
	sum_pulses: [MAX_NB_SHELL_BLOCKS + 1]i32
	n_rshifts: [MAX_NB_SHELL_BLOCKS + 1]i32
	iter := frame_length >> LOG2_SHELL_CODEC_FRAME_LENGTH
	if iter * SHELL_CODEC_FRAME_LENGTH < frame_length {
		iter += 1
		for i in 0 ..< SHELL_CODEC_FRAME_LENGTH do pulses[frame_length + i] = 0
	}
	for i in 0 ..< iter * SHELL_CODEC_FRAME_LENGTH do abs_pulses[i] = silk_abs(i32(pulses[i]))
	for i in 0 ..< iter {
		ap := abs_pulses[i * SHELL_CODEC_FRAME_LENGTH:]
		n_rshifts[i] = 0
		for {
			scale_down := combine_and_check(pulses_comb[:], ap, i32(silk_max_pulses_table[0]), 8)
			scale_down += combine_and_check(pulses_comb[:], pulses_comb[:], i32(silk_max_pulses_table[1]), 4)
			scale_down += combine_and_check(pulses_comb[:], pulses_comb[:], i32(silk_max_pulses_table[2]), 2)
			scale_down += combine_and_check(sum_pulses[i:], pulses_comb[:], i32(silk_max_pulses_table[3]), 1)
			if scale_down != 0 {
				n_rshifts[i] += 1
				for k in 0 ..< SHELL_CODEC_FRAME_LENGTH do ap[k] >>= 1
			} else {
				break
			}
		}
	}
	min_sum_bits_q5 := I32_MAX
	rate_level_index := 0
	for k in 0 ..< N_RATE_LEVELS - 1 {
		nbits := silk_pulses_per_block_BITS_Q5[k][:]
		sum_bits_q5 := i32(silk_rate_levels_BITS_Q5[signal_type >> 1][k])
		for i in 0 ..< iter {
			if n_rshifts[i] > 0 {
				sum_bits_q5 += i32(nbits[SILK_MAX_PULSES + 1])
			} else {
				sum_bits_q5 += i32(nbits[sum_pulses[i]])
			}
		}
		if sum_bits_q5 < min_sum_bits_q5 {
			min_sum_bits_q5 = sum_bits_q5
			rate_level_index = k
		}
	}
	ec_enc_icdf(enc, i32(rate_level_index), silk_rate_levels_iCDF[signal_type >> 1][:], 8)
	cdf := silk_pulses_per_block_iCDF[rate_level_index][:]
	for i in 0 ..< iter {
		if n_rshifts[i] == 0 {
			ec_enc_icdf(enc, sum_pulses[i], cdf, 8)
		} else {
			ec_enc_icdf(enc, SILK_MAX_PULSES + 1, cdf, 8)
			for _ in 0 ..< n_rshifts[i] - 1 {
				ec_enc_icdf(enc, SILK_MAX_PULSES + 1, silk_pulses_per_block_iCDF[N_RATE_LEVELS - 1][:], 8)
			}
			ec_enc_icdf(enc, sum_pulses[i], silk_pulses_per_block_iCDF[N_RATE_LEVELS - 1][:], 8)
		}
	}
	for i in 0 ..< iter {
		if sum_pulses[i] > 0 do shell_encoder(enc, abs_pulses[i * SHELL_CODEC_FRAME_LENGTH:])
	}
	for i in 0 ..< iter {
		if n_rshifts[i] > 0 {
			pp := pulses[i * SHELL_CODEC_FRAME_LENGTH:]
			nls := n_rshifts[i] - 1
			for k in 0 ..< SHELL_CODEC_FRAME_LENGTH {
				abs_q := i32(i8(silk_abs(i32(pp[k]))))
				for j := nls; j > 0; j -= 1 {
					ec_enc_icdf(enc, (abs_q >> u32(j)) & 1, silk_lsb_iCDF[:], 8)
				}
				ec_enc_icdf(enc, abs_q & 1, silk_lsb_iCDF[:], 8)
			}
		}
	}
	// signs
	icdf: [2]u8
	icdf[1] = 0
	isel := smulbb(7, quant_offset_type + (signal_type << 1))
	icdf_ptr := silk_sign_iCDF[isel:]
	length := (frame_length + SHELL_CODEC_FRAME_LENGTH / 2) >> LOG2_SHELL_CODEC_FRAME_LENGTH
	for i in 0 ..< length {
		p := sum_pulses[i]
		if p > 0 {
			icdf[0] = icdf_ptr[min(p & 0x1F, 6)]
			q := pulses[i * SHELL_CODEC_FRAME_LENGTH:]
			for j in 0 ..< SHELL_CODEC_FRAME_LENGTH {
				if q[j] != 0 do ec_enc_icdf(enc, (i32(q[j]) >> 15) + 1, icdf[:], 8)
			}
		}
	}
}

// ---- LTP gain quantization

@(private = "file")
vq_wmat_ec :: proc "contextless" (ind: ^i8, res_nrg_q15: ^i32, rate_dist_q8: ^i32, gain_q7: ^i32, XX_q17: []i32, xX_q17: []i32,
	cb_q7: []i8, cb_gain_q7: []u8, cl_q5: []u8, subfr_len: i32, max_gain_q7: i32, L: int) {
	neg_xX_q24: [5]i32
	for i in 0 ..< 5 do neg_xX_q24[i] = -(xX_q17[i] << 7)
	rate_dist_q8^ = I32_MAX
	res_nrg_q15^ = I32_MAX
	ind^ = 0
	for k in 0 ..< L {
		row := cb_q7[k * LTP_ORDER:]
		gain_tmp_q7 := i32(cb_gain_q7[k])
		sum1_q15: i32 = 32801
		penalty := max(gain_tmp_q7 - max_gain_q7, 0) << 11
		sum2_q24 := neg_xX_q24[0] + XX_q17[1] * i32(row[1])
		sum2_q24 = sum2_q24 + XX_q17[2] * i32(row[2])
		sum2_q24 = sum2_q24 + XX_q17[3] * i32(row[3])
		sum2_q24 = sum2_q24 + XX_q17[4] * i32(row[4])
		sum2_q24 <<= 1
		sum2_q24 = sum2_q24 + XX_q17[0] * i32(row[0])
		sum1_q15 = smlawb(sum1_q15, sum2_q24, i32(row[0]))
		sum2_q24 = neg_xX_q24[1] + XX_q17[7] * i32(row[2])
		sum2_q24 = sum2_q24 + XX_q17[8] * i32(row[3])
		sum2_q24 = sum2_q24 + XX_q17[9] * i32(row[4])
		sum2_q24 <<= 1
		sum2_q24 = sum2_q24 + XX_q17[6] * i32(row[1])
		sum1_q15 = smlawb(sum1_q15, sum2_q24, i32(row[1]))
		sum2_q24 = neg_xX_q24[2] + XX_q17[13] * i32(row[3])
		sum2_q24 = sum2_q24 + XX_q17[14] * i32(row[4])
		sum2_q24 <<= 1
		sum2_q24 = sum2_q24 + XX_q17[12] * i32(row[2])
		sum1_q15 = smlawb(sum1_q15, sum2_q24, i32(row[2]))
		sum2_q24 = neg_xX_q24[3] + XX_q17[19] * i32(row[4])
		sum2_q24 <<= 1
		sum2_q24 = sum2_q24 + XX_q17[18] * i32(row[3])
		sum1_q15 = smlawb(sum1_q15, sum2_q24, i32(row[3]))
		sum2_q24 = neg_xX_q24[4] << 1
		sum2_q24 = sum2_q24 + XX_q17[24] * i32(row[4])
		sum1_q15 = smlawb(sum1_q15, sum2_q24, i32(row[4]))
		if sum1_q15 >= 0 {
			bits_res_q8 := smulbb(subfr_len, lin2log(sum1_q15 + penalty) - (15 << 7))
			bits_tot_q8 := bits_res_q8 + (i32(cl_q5[k]) << (3 - 1))
			if bits_tot_q8 <= rate_dist_q8^ {
				rate_dist_q8^ = bits_tot_q8
				res_nrg_q15^ = sum1_q15 + penalty
				ind^ = i8(k)
				gain_q7^ = gain_tmp_q7
			}
		}
	}
}

@(private = "file")
ltp_cb :: proc "contextless" (k: int) -> (vq: []i8, gain: []u8, bits: []u8, size: int) {
	switch k {
	case 0:
		return (cast([^]i8)&silk_LTP_gain_vq_0[0][0])[:8 * 5], silk_LTP_gain_vq_0_gain[:], silk_LTP_gain_BITS_Q5_0[:], 8
	case 1:
		return (cast([^]i8)&silk_LTP_gain_vq_1[0][0])[:16 * 5], silk_LTP_gain_vq_1_gain[:], silk_LTP_gain_BITS_Q5_1[:], 16
	}
	return (cast([^]i8)&silk_LTP_gain_vq_2[0][0])[:32 * 5], silk_LTP_gain_vq_2_gain[:], silk_LTP_gain_BITS_Q5_2[:], 32
}

// quant_LTP_gains + float wrapper
silk_quant_ltp_gains_flp :: proc "contextless" (B: []f32, cbk_index: []i8, periodicity_index: ^i8, sum_log_gain_q7: ^i32, pred_gain_db: ^f32,
	XX: []f32, xX: []f32, subfr_len: int, nb_subfr: int) {
	B_q14: [MAX_NB_SUBFR * LTP_ORDER]i16
	XX_q17: [MAX_NB_SUBFR * LTP_ORDER * LTP_ORDER]i32
	xX_q17: [MAX_NB_SUBFR * LTP_ORDER]i32
	for i in 0 ..< nb_subfr * LTP_ORDER * LTP_ORDER do XX_q17[i] = float2int(XX[i] * 131072.0)
	for i in 0 ..< nb_subfr * LTP_ORDER do xX_q17[i] = float2int(xX[i] * 131072.0)
	temp_idx: [MAX_NB_SUBFR]i8
	min_rate_dist_q7 := I32_MAX
	best_sum_log_gain_q7: i32 = 0
	res_nrg_q15: i32 = 0
	for k in 0 ..< 3 {
		gain_safety: i32 = 51
		vq, vq_gain, cl, size := ltp_cb(k)
		res_nrg_q15 = 0
		rate_dist_q7: i32 = 0
		sum_log_gain_tmp_q7 := sum_log_gain_q7^
		for j in 0 ..< nb_subfr {
			max_gain_q7 := log2lin((SE_FIX_MAX_SUM_LOG_GAIN_Q7 - sum_log_gain_tmp_q7) + (7 << 7)) - gain_safety
			res_nrg_q15_subfr, rate_dist_q7_subfr, gain_q7: i32
			vq_wmat_ec(&temp_idx[j], &res_nrg_q15_subfr, &rate_dist_q7_subfr, &gain_q7, XX_q17[j * 25:], xX_q17[j * 5:], vq, vq_gain, cl,
				i32(subfr_len), max_gain_q7, size)
			res_nrg_q15 = silk_add_pos_sat32(res_nrg_q15, res_nrg_q15_subfr)
			rate_dist_q7 = silk_add_pos_sat32(rate_dist_q7, rate_dist_q7_subfr)
			sum_log_gain_tmp_q7 = max(0, sum_log_gain_tmp_q7 + lin2log(gain_safety + gain_q7) - (7 << 7))
		}
		if rate_dist_q7 <= min_rate_dist_q7 {
			min_rate_dist_q7 = rate_dist_q7
			periodicity_index^ = i8(k)
			copy(cbk_index[:nb_subfr], temp_idx[:nb_subfr])
			best_sum_log_gain_q7 = sum_log_gain_tmp_q7
		}
	}
	vq, _, _, _ := ltp_cb(int(periodicity_index^))
	for j in 0 ..< nb_subfr {
		for k in 0 ..< LTP_ORDER do B_q14[j * LTP_ORDER + k] = i16(i32(vq[int(cbk_index[j]) * LTP_ORDER + k]) << 7)
	}
	if nb_subfr == 2 {
		res_nrg_q15 >>= 1
	} else {
		res_nrg_q15 >>= 2
	}
	sum_log_gain_q7^ = best_sum_log_gain_q7
	pred_gain_db_q7 := smulbb(-3, lin2log(res_nrg_q15) - (15 << 7))
	for i in 0 ..< nb_subfr * LTP_ORDER do B[i] = f32(B_q14[i]) * (1.0 / 16384.0)
	pred_gain_db^ = f32(pred_gain_db_q7) * (1.0 / 128.0)
}

// ---- stereo

silk_stereo_encode_pred :: proc "contextless" (enc: ^Range, ix: ^[2][3]i8) {
	n := 5 * i32(ix[0][2]) + i32(ix[1][2])
	ec_enc_icdf(enc, n, silk_stereo_pred_joint_iCDF[:], 8)
	for k in 0 ..< 2 {
		ec_enc_icdf(enc, i32(ix[k][0]), silk_uniform3_iCDF[:], 8)
		ec_enc_icdf(enc, i32(ix[k][1]), silk_uniform5_iCDF[:], 8)
	}
}

silk_stereo_encode_mid_only :: proc "contextless" (enc: ^Range, mid_only_flag: i8) {
	ec_enc_icdf(enc, i32(mid_only_flag), silk_stereo_only_code_mid_iCDF[:], 8)
}

@(private = "file")
stereo_find_predictor :: proc "contextless" (ratio_q14: ^i32, x: []i16, y: []i16, mid_res_amp_q0: []i32, length: int, smooth_coef_q16_: i32) -> i32 {
	smooth_coef_q16 := smooth_coef_q16_
	nrgx, scale1 := sum_sqr_shift(x, length)
	nrgy, scale2 := sum_sqr_shift(y, length)
	scale := max(scale1, scale2)
	scale = scale + (scale & 1)
	nrgy = nrgy >> u32(scale - scale2)
	nrgx = nrgx >> u32(scale - scale1)
	nrgx = max(nrgx, 1)
	corr: i32 = 0
	for i in 0 ..< length do corr = corr + (smulbb(i32(x[i]), i32(y[i])) >> u32(scale))
	pred_q13 := div32_varq(corr, nrgx, 13)
	pred_q13 = limit32(pred_q13, -(1 << 14), 1 << 14)
	pred2_q10 := smulwb(pred_q13, pred_q13)
	smooth_coef_q16 = max(smooth_coef_q16, silk_abs(pred2_q10))
	scale >>= 1
	mid_res_amp_q0[0] = smlawb(mid_res_amp_q0[0], (sqrt_approx(nrgx) << u32(scale)) - mid_res_amp_q0[0], smooth_coef_q16)
	nrgy = nrgy - (smulwb(corr, pred_q13) << (3 + 1))
	nrgy = nrgy + (smulwb(nrgx, pred2_q10) << 6)
	mid_res_amp_q0[1] = smlawb(mid_res_amp_q0[1], (sqrt_approx(nrgy) << u32(scale)) - mid_res_amp_q0[1], smooth_coef_q16)
	ratio_q14^ = div32_varq(mid_res_amp_q0[1], max(mid_res_amp_q0[0], 1), 14)
	ratio_q14^ = limit32(ratio_q14^, 0, 32767)
	return pred_q13
}

@(private = "file")
stereo_quant_pred :: proc "contextless" (pred_q13: []i32, ix: ^[2][3]i8) {
	quant_pred_q13: i32 = 0
	for n in 0 ..< 2 {
		err_min_q13 := I32_MAX
		done: for i in 0 ..< SE_STEREO_QUANT_TAB_SIZE - 1 {
			low_q13 := i32(silk_stereo_pred_quant_Q13[i])
			step_q13 := smulwb(i32(silk_stereo_pred_quant_Q13[i + 1]) - low_q13, 6554)
			for j in 0 ..< SE_STEREO_QUANT_SUB_STEPS {
				lvl_q13 := smlabb(low_q13, step_q13, i32(2 * j + 1))
				err_q13 := silk_abs(pred_q13[n] - lvl_q13)
				if err_q13 < err_min_q13 {
					err_min_q13 = err_q13
					quant_pred_q13 = lvl_q13
					ix[n][0] = i8(i)
					ix[n][1] = i8(j)
				} else {
					break done
				}
			}
		}
		ix[n][2] = ix[n][0] / 3
		ix[n][0] -= ix[n][2] * 3
		pred_q13[n] = quant_pred_q13
	}
	pred_q13[0] -= pred_q13[1]
}

// x1, x2 point at input_buf[2:] of each channel; the two samples before
// (x1[-2..-1], x2[-2..-1]) are accessed through the full buffers.
silk_stereo_lr_to_ms :: proc "contextless" (state: ^Silk_Stereo_Enc_State, buf1: []i16, buf2: []i16, ix: ^[2][3]i8, mid_only_flag: ^i8,
	mid_side_rates_bps: []i32, total_rate_bps_: i32, prev_speech_act_q8: i32, to_mono: bool, fs_khz: i32, frame_length: int) {
	// buf1 = &x1[-2], buf2 = &x2[-2]
	total_rate_bps := total_rate_bps_
	side: [MAX_FRAME_LENGTH + 2]i16
	LP_mid, HP_mid, LP_side, HP_side: [MAX_FRAME_LENGTH]i16
	mid := buf1
	for n in 0 ..< frame_length + 2 {
		sum := i32(buf1[n]) + i32(buf2[n])
		diff := i32(buf1[n]) - i32(buf2[n])
		mid[n] = i16(rshift_round(sum, 1))
		side[n] = i16(sat16(rshift_round(diff, 1)))
	}
	mid[0] = state.smid[0]
	mid[1] = state.smid[1]
	side[0] = state.sside[0]
	side[1] = state.sside[1]
	state.smid[0] = mid[frame_length]
	state.smid[1] = mid[frame_length + 1]
	state.sside[0] = side[frame_length]
	state.sside[1] = side[frame_length + 1]
	for n in 0 ..< frame_length {
		sum := rshift_round((i32(mid[n]) + i32(mid[n + 2])) + (i32(mid[n + 1]) << 1), 2)
		LP_mid[n] = i16(sum)
		HP_mid[n] = i16(i32(mid[n + 1]) - sum)
	}
	for n in 0 ..< frame_length {
		sum := rshift_round((i32(side[n]) + i32(side[n + 2])) + (i32(side[n + 1]) << 1), 2)
		LP_side[n] = i16(sum)
		HP_side[n] = i16(i32(side[n + 1]) - sum)
	}
	is10ms := frame_length == int(10 * fs_khz)
	smooth_coef_q16: i32 = is10ms ? 328 : 655
	smooth_coef_q16 = smulwb(smulbb(prev_speech_act_q8, prev_speech_act_q8), smooth_coef_q16)
	pred_q13: [2]i32
	LP_ratio_q14, HP_ratio_q14: i32
	pred_q13[0] = stereo_find_predictor(&LP_ratio_q14, LP_mid[:], LP_side[:], state.mid_side_amp_q0[0:2], frame_length, smooth_coef_q16)
	pred_q13[1] = stereo_find_predictor(&HP_ratio_q14, HP_mid[:], HP_side[:], state.mid_side_amp_q0[2:4], frame_length, smooth_coef_q16)
	frac_q16 := smlabb(HP_ratio_q14, LP_ratio_q14, 3)
	frac_q16 = min(frac_q16, 1 << 16)
	total_rate_bps -= is10ms ? 1200 : 600
	if total_rate_bps < 1 do total_rate_bps = 1
	min_mid_rate_bps := smlabb(2000, fs_khz, 600)
	frac_3_q16 := 3 * frac_q16
	width_q14: i32
	mid_side_rates_bps[0] = div32_varq(total_rate_bps, (13 << 16) + frac_3_q16, 16 + 3)
	if mid_side_rates_bps[0] < min_mid_rate_bps {
		mid_side_rates_bps[0] = min_mid_rate_bps
		mid_side_rates_bps[1] = total_rate_bps - mid_side_rates_bps[0]
		width_q14 = div32_varq((mid_side_rates_bps[1] << 1) - min_mid_rate_bps, smulwb((1 << 16) + frac_3_q16, min_mid_rate_bps), 14 + 2)
		width_q14 = limit32(width_q14, 0, 1 << 14)
	} else {
		mid_side_rates_bps[1] = total_rate_bps - mid_side_rates_bps[0]
		width_q14 = 1 << 14
	}
	state.smth_width_q14 = i16(smlawb(i32(state.smth_width_q14), width_q14 - i32(state.smth_width_q14), smooth_coef_q16))
	mid_only_flag^ = 0
	sw := i32(state.smth_width_q14)
	if to_mono {
		width_q14 = 0
		pred_q13[0] = 0
		pred_q13[1] = 0
		stereo_quant_pred(pred_q13[:], ix)
	} else if state.width_prev_q14 == 0 && (8 * total_rate_bps < 13 * min_mid_rate_bps || smulwb(frac_q16, sw) < 819) {
		pred_q13[0] = smulbb(sw, pred_q13[0]) >> 14
		pred_q13[1] = smulbb(sw, pred_q13[1]) >> 14
		stereo_quant_pred(pred_q13[:], ix)
		width_q14 = 0
		pred_q13[0] = 0
		pred_q13[1] = 0
		mid_side_rates_bps[0] = total_rate_bps
		mid_side_rates_bps[1] = 0
		mid_only_flag^ = 1
	} else if state.width_prev_q14 != 0 && (8 * total_rate_bps < 11 * min_mid_rate_bps || smulwb(frac_q16, sw) < 328) {
		pred_q13[0] = smulbb(sw, pred_q13[0]) >> 14
		pred_q13[1] = smulbb(sw, pred_q13[1]) >> 14
		stereo_quant_pred(pred_q13[:], ix)
		width_q14 = 0
		pred_q13[0] = 0
		pred_q13[1] = 0
	} else if sw > 15565 {
		stereo_quant_pred(pred_q13[:], ix)
		width_q14 = 1 << 14
	} else {
		pred_q13[0] = smulbb(sw, pred_q13[0]) >> 14
		pred_q13[1] = smulbb(sw, pred_q13[1]) >> 14
		stereo_quant_pred(pred_q13[:], ix)
		width_q14 = sw
	}
	if mid_only_flag^ == 1 {
		state.silent_side_len = i16(i32(state.silent_side_len) + i32(frame_length) - STEREO_INTERP_LEN_MS * fs_khz)
		if i32(state.silent_side_len) < SE_LA_SHAPE_MS * fs_khz {
			mid_only_flag^ = 0
		} else {
			state.silent_side_len = 10000
		}
	} else {
		state.silent_side_len = 0
	}
	if mid_only_flag^ == 0 && mid_side_rates_bps[1] < 1 {
		mid_side_rates_bps[1] = 1
		mid_side_rates_bps[0] = max(1, total_rate_bps - mid_side_rates_bps[1])
	}
	pred0_q13 := -i32(state.pred_prev_q13[0])
	pred1_q13 := -i32(state.pred_prev_q13[1])
	w_q24 := i32(state.width_prev_q14) << 10
	denom_q16 := (i32(1) << 16) / (STEREO_INTERP_LEN_MS * fs_khz)
	delta0_q13 := -rshift_round(smulbb(pred_q13[0] - i32(state.pred_prev_q13[0]), denom_q16), 16)
	delta1_q13 := -rshift_round(smulbb(pred_q13[1] - i32(state.pred_prev_q13[1]), denom_q16), 16)
	deltaw_q24 := smulwb(width_q14 - i32(state.width_prev_q14), denom_q16) << 10
	// x2[n-1] = buf2[n+1]
	interp := int(STEREO_INTERP_LEN_MS * fs_khz)
	for n in 0 ..< interp {
		pred0_q13 += delta0_q13
		pred1_q13 += delta1_q13
		w_q24 += deltaw_q24
		sum := ((i32(mid[n]) + i32(mid[n + 2])) + (i32(mid[n + 1]) << 1)) << 9
		sum = smlawb(smulwb(w_q24, i32(side[n + 1])), sum, pred0_q13)
		sum = smlawb(sum, i32(mid[n + 1]) << 11, pred1_q13)
		buf2[n + 1] = i16(sat16(rshift_round(sum, 8)))
	}
	pred0_q13 = -pred_q13[0]
	pred1_q13 = -pred_q13[1]
	w_q24 = width_q14 << 10
	for n in interp ..< frame_length {
		sum := ((i32(mid[n]) + i32(mid[n + 2])) + (i32(mid[n + 1]) << 1)) << 9
		sum = smlawb(smulwb(w_q24, i32(side[n + 1])), sum, pred0_q13)
		sum = smlawb(sum, i32(mid[n + 1]) << 11, pred1_q13)
		buf2[n + 1] = i16(sat16(rshift_round(sum, 8)))
	}
	state.pred_prev_q13[0] = i16(pred_q13[0])
	state.pred_prev_q13[1] = i16(pred_q13[1])
	state.width_prev_q14 = i16(width_q14)
}
