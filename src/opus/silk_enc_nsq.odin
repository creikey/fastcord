package opus

// SILK encoder: noise shaping quantizers (NSQ.c, NSQ_del_dec.c). Fixed point,
// bit-exact with the reference C implementation.

import "core:mem"

@(private = "file")
short_prediction :: #force_inline proc "contextless" (buf: []i32, idx: int, coef: []i16, order: int) -> i32 {
	out := i32(order >> 1)
	for j in 0 ..< order do out = smlawb(out, buf[idx - j], i32(coef[j]))
	return out
}

@(private = "file")
feedback_loop :: #force_inline proc "contextless" (data0: i32, data1: []i32, coef: []i16, order: int) -> i32 {
	tmp2 := data0
	tmp1 := data1[0]
	data1[0] = tmp2
	out := i32(order >> 1)
	out = smlawb(out, tmp2, i32(coef[0]))
	for j := 2; j < order; j += 2 {
		tmp2 = data1[j - 1]
		data1[j - 1] = tmp1
		out = smlawb(out, tmp1, i32(coef[j - 1]))
		tmp1 = data1[j + 0]
		data1[j + 0] = tmp2
		out = smlawb(out, tmp2, i32(coef[j]))
	}
	data1[order - 1] = tmp1
	out = smlawb(out, tmp1, i32(coef[order - 1]))
	return out << 1
}

@(private = "file")
quant_pair :: #force_inline proc "contextless" (r_q10, offset_q10, lambda_q10: i32) -> (q1_q10, q2_q10, rd1, rd2: i32) {
	q1_q10 = r_q10 - offset_q10
	q1_q0 := q1_q10 >> 10
	if lambda_q10 > 2048 {
		rdo_offset := lambda_q10 / 2 - 512
		if q1_q10 > rdo_offset {
			q1_q0 = (q1_q10 - rdo_offset) >> 10
		} else if q1_q10 < -rdo_offset {
			q1_q0 = (q1_q10 + rdo_offset) >> 10
		} else if q1_q10 < 0 {
			q1_q0 = -1
		} else {
			q1_q0 = 0
		}
	}
	if q1_q0 > 0 {
		q1_q10 = (q1_q0 << 10) - QUANT_LEVEL_ADJUST_Q10
		q1_q10 = q1_q10 + offset_q10
		q2_q10 = q1_q10 + 1024
		rd1 = smulbb(q1_q10, lambda_q10)
		rd2 = smulbb(q2_q10, lambda_q10)
	} else if q1_q0 == 0 {
		q1_q10 = offset_q10
		q2_q10 = q1_q10 + (1024 - QUANT_LEVEL_ADJUST_Q10)
		rd1 = smulbb(q1_q10, lambda_q10)
		rd2 = smulbb(q2_q10, lambda_q10)
	} else if q1_q0 == -1 {
		q2_q10 = offset_q10
		q1_q10 = q2_q10 - (1024 - QUANT_LEVEL_ADJUST_Q10)
		rd1 = smulbb(-q1_q10, lambda_q10)
		rd2 = smulbb(q2_q10, lambda_q10)
	} else {
		q1_q10 = (q1_q0 << 10) + QUANT_LEVEL_ADJUST_Q10
		q1_q10 = q1_q10 + offset_q10
		q2_q10 = q1_q10 + 1024
		rd1 = smulbb(-q1_q10, lambda_q10)
		rd2 = smulbb(-q2_q10, lambda_q10)
	}
	return
}

Silk_NSQ_Params :: struct {
	pred_coef_q12:        [2 * MAX_LPC_ORDER]i16,
	ltp_coef_q14:         [LTP_ORDER * MAX_NB_SUBFR]i16,
	ar_q13:               [MAX_NB_SUBFR * SE_MAX_SHAPE_LPC_ORDER]i16,
	harm_shape_gain_q14:  [MAX_NB_SUBFR]i32,
	tilt_q14:             [MAX_NB_SUBFR]i32,
	lf_shp_q14:           [MAX_NB_SUBFR]i32,
	gains_q16:            [MAX_NB_SUBFR]i32,
	pitch_l:              [MAX_NB_SUBFR]i32,
	lambda_q10:           i32,
	ltp_scale_q14:        i32,
}

@(private = "file")
nsq_scale_states :: proc "contextless" (cmn: ^Silk_Enc_Common, NSQ: ^Silk_NSQ_State, x16: []i16, x_sc_q10: []i32, sLTP: []i16, sLTP_q15: []i32,
	subfr: int, prm: ^Silk_NSQ_Params, signal_type: i32) {
	lag := prm.pitch_l[subfr]
	inv_gain_q31 := inverse32_varq(max(prm.gains_q16[subfr], 1), 47)
	inv_gain_q26 := rshift_round(inv_gain_q31, 5)
	for i in 0 ..< int(cmn.subfr_length) do x_sc_q10[i] = smulww(i32(x16[i]), inv_gain_q26)
	if NSQ.rewhite_flag != 0 {
		if subfr == 0 do inv_gain_q31 = smulwb(inv_gain_q31, prm.ltp_scale_q14) << 2
		for i := NSQ.sltp_buf_idx - lag - LTP_ORDER / 2; i < NSQ.sltp_buf_idx; i += 1 {
			sLTP_q15[i] = smulwb(inv_gain_q31, i32(sLTP[i]))
		}
	}
	if prm.gains_q16[subfr] != NSQ.prev_gain_q16 {
		gain_adj_q16 := div32_varq(NSQ.prev_gain_q16, prm.gains_q16[subfr], 16)
		for i := NSQ.sltp_shp_buf_idx - cmn.ltp_mem_length; i < NSQ.sltp_shp_buf_idx; i += 1 {
			NSQ.sltp_shp_q14[i] = smulww(gain_adj_q16, NSQ.sltp_shp_q14[i])
		}
		if signal_type == TYPE_VOICED && NSQ.rewhite_flag == 0 {
			for i := NSQ.sltp_buf_idx - lag - LTP_ORDER / 2; i < NSQ.sltp_buf_idx; i += 1 {
				sLTP_q15[i] = smulww(gain_adj_q16, sLTP_q15[i])
			}
		}
		NSQ.slf_ar_shp_q14 = smulww(gain_adj_q16, NSQ.slf_ar_shp_q14)
		NSQ.sdiff_shp_q14 = smulww(gain_adj_q16, NSQ.sdiff_shp_q14)
		for i in 0 ..< SE_NSQ_LPC_BUF_LENGTH do NSQ.slpc_q14[i] = smulww(gain_adj_q16, NSQ.slpc_q14[i])
		for i in 0 ..< SE_MAX_SHAPE_LPC_ORDER do NSQ.sar2_q14[i] = smulww(gain_adj_q16, NSQ.sar2_q14[i])
		NSQ.prev_gain_q16 = prm.gains_q16[subfr]
	}
}

@(private = "file")
noise_shape_quantizer :: proc "contextless" (NSQ: ^Silk_NSQ_State, signal_type: i32, x_sc_q10: []i32, pulses: []i8, xq: []i16, sLTP_q15: []i32,
	a_q12: []i16, b_q14: []i16, ar_shp_q13: []i16, lag: i32, harm_shape_fir_packed_q14: i32, tilt_q14: i32, lf_shp_q14: i32, gain_q16: i32,
	lambda_q10: i32, offset_q10: i32, length: int, shaping_lpc_order: int, predict_lpc_order: int) {
	shp_idx := int(NSQ.sltp_shp_buf_idx - lag + SE_HARM_SHAPE_FIR_TAPS / 2)
	pred_idx := int(NSQ.sltp_buf_idx - lag + LTP_ORDER / 2)
	gain_q10 := gain_q16 >> 6
	slpc := NSQ.slpc_q14[:]
	for i in 0 ..< length {
		NSQ.rand_seed = silk_rand(NSQ.rand_seed)
		lpc_pred_q10 := short_prediction(slpc, SE_NSQ_LPC_BUF_LENGTH - 1 + i, a_q12, predict_lpc_order)
		ltp_pred_q13: i32
		if signal_type == TYPE_VOICED {
			ltp_pred_q13 = 2
			ltp_pred_q13 = smlawb(ltp_pred_q13, sLTP_q15[pred_idx], i32(b_q14[0]))
			ltp_pred_q13 = smlawb(ltp_pred_q13, sLTP_q15[pred_idx - 1], i32(b_q14[1]))
			ltp_pred_q13 = smlawb(ltp_pred_q13, sLTP_q15[pred_idx - 2], i32(b_q14[2]))
			ltp_pred_q13 = smlawb(ltp_pred_q13, sLTP_q15[pred_idx - 3], i32(b_q14[3]))
			ltp_pred_q13 = smlawb(ltp_pred_q13, sLTP_q15[pred_idx - 4], i32(b_q14[4]))
			pred_idx += 1
		}
		n_ar_q12 := feedback_loop(NSQ.sdiff_shp_q14, NSQ.sar2_q14[:], ar_shp_q13, shaping_lpc_order)
		n_ar_q12 = smlawb(n_ar_q12, NSQ.slf_ar_shp_q14, tilt_q14)
		n_lf_q12 := smulwb(NSQ.sltp_shp_q14[NSQ.sltp_shp_buf_idx - 1], lf_shp_q14)
		n_lf_q12 = smlawt(n_lf_q12, NSQ.slf_ar_shp_q14, lf_shp_q14)
		tmp1 := (lpc_pred_q10 << 2) - n_ar_q12
		tmp1 = tmp1 - n_lf_q12
		if lag > 0 {
			n_ltp_q13 := smulwb(NSQ.sltp_shp_q14[shp_idx] + NSQ.sltp_shp_q14[shp_idx - 2], harm_shape_fir_packed_q14)
			n_ltp_q13 = smlawt(n_ltp_q13, NSQ.sltp_shp_q14[shp_idx - 1], harm_shape_fir_packed_q14)
			n_ltp_q13 = n_ltp_q13 << 1
			shp_idx += 1
			tmp2 := ltp_pred_q13 - n_ltp_q13
			tmp1 = tmp2 + (tmp1 << 1)
			tmp1 = rshift_round(tmp1, 3)
		} else {
			tmp1 = rshift_round(tmp1, 2)
		}
		r_q10 := x_sc_q10[i] - tmp1
		if NSQ.rand_seed < 0 do r_q10 = -r_q10
		r_q10 = limit32(r_q10, -(31 << 10), 30 << 10)
		q1_q10, q2_q10, rd1_q20, rd2_q20 := quant_pair(r_q10, offset_q10, lambda_q10)
		rr_q10 := r_q10 - q1_q10
		rd1_q20 = smlabb(rd1_q20, rr_q10, rr_q10)
		rr_q10 = r_q10 - q2_q10
		rd2_q20 = smlabb(rd2_q20, rr_q10, rr_q10)
		if rd2_q20 < rd1_q20 do q1_q10 = q2_q10
		pulses[i] = i8(rshift_round(q1_q10, 10))
		exc_q14 := q1_q10 << 4
		if NSQ.rand_seed < 0 do exc_q14 = -exc_q14
		lpc_exc_q14 := exc_q14 + (ltp_pred_q13 << 1)
		xq_q14 := lpc_exc_q14 + (lpc_pred_q10 << 4)
		xq[i] = i16(sat16(rshift_round(smulww(xq_q14, gain_q10), 8)))
		slpc[SE_NSQ_LPC_BUF_LENGTH + i] = xq_q14
		NSQ.sdiff_shp_q14 = xq_q14 - (x_sc_q10[i] << 4)
		slf_ar_shp_q14 := NSQ.sdiff_shp_q14 - (n_ar_q12 << 2)
		NSQ.slf_ar_shp_q14 = slf_ar_shp_q14
		NSQ.sltp_shp_q14[NSQ.sltp_shp_buf_idx] = slf_ar_shp_q14 - (n_lf_q12 << 2)
		sLTP_q15[NSQ.sltp_buf_idx] = lpc_exc_q14 << 1
		NSQ.sltp_shp_buf_idx += 1
		NSQ.sltp_buf_idx += 1
		NSQ.rand_seed = i32(u32(NSQ.rand_seed) + u32(i32(pulses[i])))
	}
	copy(NSQ.slpc_q14[:SE_NSQ_LPC_BUF_LENGTH], NSQ.slpc_q14[length:length + SE_NSQ_LPC_BUF_LENGTH])
}

silk_nsq :: proc "contextless" (cmn: ^Silk_Enc_Common, NSQ: ^Silk_NSQ_State, ix: ^Side_Info, x16_: []i16, pulses_: []i8, prm: ^Silk_NSQ_Params) {
	sLTP_q15: [2 * MAX_FRAME_LENGTH]i32
	sLTP: [2 * MAX_FRAME_LENGTH]i16
	x_sc_q10: [MAX_SUB_FRAME_LENGTH]i32
	NSQ.rand_seed = i32(ix.seed)
	lag := NSQ.lag_prev
	offset_q10 := i32(silk_Quantization_Offsets_Q10[ix.signal_type >> 1][ix.quant_offset_type])
	lsf_interp := ix.nlsf_interp_coef_q2 == 4 ? 0 : 1
	ltp_mem := int(cmn.ltp_mem_length)
	sl := int(cmn.subfr_length)
	NSQ.sltp_shp_buf_idx = cmn.ltp_mem_length
	NSQ.sltp_buf_idx = cmn.ltp_mem_length
	for k in 0 ..< int(cmn.nb_subfr) {
		A_q12 := prm.pred_coef_q12[((k >> 1) | (1 - lsf_interp)) * MAX_LPC_ORDER:]
		B_q14 := prm.ltp_coef_q14[k * LTP_ORDER:]
		AR_shp := prm.ar_q13[k * SE_MAX_SHAPE_LPC_ORDER:]
		hsp := prm.harm_shape_gain_q14[k] >> 2
		hsp |= (prm.harm_shape_gain_q14[k] >> 1) << 16
		NSQ.rewhite_flag = 0
		if ix.signal_type == TYPE_VOICED {
			lag = prm.pitch_l[k]
			if (k & (3 - (lsf_interp << 1))) == 0 {
				start_idx := ltp_mem - int(lag) - int(cmn.predict_lpc_order) - LTP_ORDER / 2
				lpc_analysis_filter(sLTP[start_idx:], NSQ.xq[start_idx + k * sl:], A_q12, ltp_mem - start_idx, int(cmn.predict_lpc_order))
				NSQ.rewhite_flag = 1
				NSQ.sltp_buf_idx = cmn.ltp_mem_length
			}
		}
		nsq_scale_states(cmn, NSQ, x16_[k * sl:], x_sc_q10[:], sLTP[:], sLTP_q15[:], k, prm, i32(ix.signal_type))
		noise_shape_quantizer(NSQ, i32(ix.signal_type), x_sc_q10[:], pulses_[k * sl:], NSQ.xq[ltp_mem + k * sl:], sLTP_q15[:], A_q12, B_q14, AR_shp,
			lag, hsp, prm.tilt_q14[k], prm.lf_shp_q14[k], prm.gains_q16[k], prm.lambda_q10, offset_q10, sl, int(cmn.shaping_lpc_order),
			int(cmn.predict_lpc_order))
	}
	NSQ.lag_prev = prm.pitch_l[cmn.nb_subfr - 1]
	fl := int(cmn.frame_length)
	copy(NSQ.xq[:ltp_mem], NSQ.xq[fl:fl + ltp_mem])
	copy(NSQ.sltp_shp_q14[:ltp_mem], NSQ.sltp_shp_q14[fl:fl + ltp_mem])
}

// ---- delayed decision

@(private = "file")
NSQ_Del_Dec :: struct {
	slpc_q14:  [MAX_SUB_FRAME_LENGTH + SE_NSQ_LPC_BUF_LENGTH]i32,
	rand_state: [SE_DECISION_DELAY]i32,
	q_q10:     [SE_DECISION_DELAY]i32,
	xq_q14:    [SE_DECISION_DELAY]i32,
	pred_q15:  [SE_DECISION_DELAY]i32,
	shape_q14: [SE_DECISION_DELAY]i32,
	sar2_q14:  [SE_MAX_SHAPE_LPC_ORDER]i32,
	lf_ar_q14: i32,
	diff_q14:  i32,
	seed:      i32,
	seed_init: i32,
	rd_q10:    i32,
}

@(private = "file")
NSQ_Sample :: struct {
	q_q10:        i32,
	rd_q10:       i32,
	xq_q14:       i32,
	lf_ar_q14:    i32,
	diff_q14:     i32,
	sltp_shp_q14: i32,
	lpc_exc_q14:  i32,
}

@(private = "file")
nsq_del_dec_scale_states :: proc "contextless" (cmn: ^Silk_Enc_Common, NSQ: ^Silk_NSQ_State, dd: []NSQ_Del_Dec, x16: []i16, x_sc_q10: []i32,
	sLTP: []i16, sLTP_q15: []i32, subfr: int, n_states: int, prm: ^Silk_NSQ_Params, signal_type: i32, decision_delay: i32) {
	lag := prm.pitch_l[subfr]
	inv_gain_q31 := inverse32_varq(max(prm.gains_q16[subfr], 1), 47)
	inv_gain_q26 := rshift_round(inv_gain_q31, 5)
	for i in 0 ..< int(cmn.subfr_length) do x_sc_q10[i] = smulww(i32(x16[i]), inv_gain_q26)
	if NSQ.rewhite_flag != 0 {
		if subfr == 0 do inv_gain_q31 = smulwb(inv_gain_q31, prm.ltp_scale_q14) << 2
		for i := NSQ.sltp_buf_idx - lag - LTP_ORDER / 2; i < NSQ.sltp_buf_idx; i += 1 {
			sLTP_q15[i] = smulwb(inv_gain_q31, i32(sLTP[i]))
		}
	}
	if prm.gains_q16[subfr] != NSQ.prev_gain_q16 {
		gain_adj_q16 := div32_varq(NSQ.prev_gain_q16, prm.gains_q16[subfr], 16)
		for i := NSQ.sltp_shp_buf_idx - cmn.ltp_mem_length; i < NSQ.sltp_shp_buf_idx; i += 1 {
			NSQ.sltp_shp_q14[i] = smulww(gain_adj_q16, NSQ.sltp_shp_q14[i])
		}
		if signal_type == TYPE_VOICED && NSQ.rewhite_flag == 0 {
			for i := NSQ.sltp_buf_idx - lag - LTP_ORDER / 2; i < NSQ.sltp_buf_idx - decision_delay; i += 1 {
				sLTP_q15[i] = smulww(gain_adj_q16, sLTP_q15[i])
			}
		}
		for k in 0 ..< n_states {
			d := &dd[k]
			d.lf_ar_q14 = smulww(gain_adj_q16, d.lf_ar_q14)
			d.diff_q14 = smulww(gain_adj_q16, d.diff_q14)
			for i in 0 ..< SE_NSQ_LPC_BUF_LENGTH do d.slpc_q14[i] = smulww(gain_adj_q16, d.slpc_q14[i])
			for i in 0 ..< SE_MAX_SHAPE_LPC_ORDER do d.sar2_q14[i] = smulww(gain_adj_q16, d.sar2_q14[i])
			for i in 0 ..< SE_DECISION_DELAY {
				d.pred_q15[i] = smulww(gain_adj_q16, d.pred_q15[i])
				d.shape_q14[i] = smulww(gain_adj_q16, d.shape_q14[i])
			}
		}
		NSQ.prev_gain_q16 = prm.gains_q16[subfr]
	}
}

// pulses/xq: full-frame buffers; base = offset of the current subframe.
@(private = "file")
noise_shape_quantizer_del_dec :: proc "contextless" (NSQ: ^Silk_NSQ_State, dd: []NSQ_Del_Dec, signal_type: i32, x_q10: []i32, pulses: []i8,
	xq: []i16, base: int, sLTP_q15: []i32, delayed_gain_q10: []i32, a_q12: []i16, b_q14: []i16, ar_shp_q13: []i16, lag: i32,
	harm_shape_fir_packed_q14: i32, tilt_q14: i32, lf_shp_q14: i32, gain_q16: i32, lambda_q10: i32, offset_q10: i32, length: int, subfr: int,
	shaping_lpc_order: int, predict_lpc_order: int, warping_q16: i32, n_states: int, smpl_buf_idx: ^int, decision_delay: int) {
	ss: [SE_MAX_DEL_DEC_STATES][2]NSQ_Sample
	shp_idx := int(NSQ.sltp_shp_buf_idx - lag + SE_HARM_SHAPE_FIR_TAPS / 2)
	pred_idx := int(NSQ.sltp_buf_idx - lag + LTP_ORDER / 2)
	gain_q10 := gain_q16 >> 6
	for i in 0 ..< length {
		ltp_pred_q14: i32
		if signal_type == TYPE_VOICED {
			ltp_pred_q14 = 2
			ltp_pred_q14 = smlawb(ltp_pred_q14, sLTP_q15[pred_idx], i32(b_q14[0]))
			ltp_pred_q14 = smlawb(ltp_pred_q14, sLTP_q15[pred_idx - 1], i32(b_q14[1]))
			ltp_pred_q14 = smlawb(ltp_pred_q14, sLTP_q15[pred_idx - 2], i32(b_q14[2]))
			ltp_pred_q14 = smlawb(ltp_pred_q14, sLTP_q15[pred_idx - 3], i32(b_q14[3]))
			ltp_pred_q14 = smlawb(ltp_pred_q14, sLTP_q15[pred_idx - 4], i32(b_q14[4]))
			ltp_pred_q14 <<= 1
			pred_idx += 1
		}
		n_ltp_q14: i32
		if lag > 0 {
			n_ltp_q14 = smulwb(NSQ.sltp_shp_q14[shp_idx] + NSQ.sltp_shp_q14[shp_idx - 2], harm_shape_fir_packed_q14)
			n_ltp_q14 = smlawt(n_ltp_q14, NSQ.sltp_shp_q14[shp_idx - 1], harm_shape_fir_packed_q14)
			n_ltp_q14 = ltp_pred_q14 - (n_ltp_q14 << 2)
			shp_idx += 1
		}
		for k in 0 ..< n_states {
			d := &dd[k]
			s := &ss[k]
			d.seed = silk_rand(d.seed)
			lpc_pred_q14 := short_prediction(d.slpc_q14[:], SE_NSQ_LPC_BUF_LENGTH - 1 + i, a_q12, predict_lpc_order)
			lpc_pred_q14 <<= 4
			tmp2 := smlawb(d.diff_q14, d.sar2_q14[0], warping_q16)
			tmp1 := smlawb(d.sar2_q14[0], d.sar2_q14[1] - tmp2, warping_q16)
			d.sar2_q14[0] = tmp2
			n_ar_q14 := i32(shaping_lpc_order >> 1)
			n_ar_q14 = smlawb(n_ar_q14, tmp2, i32(ar_shp_q13[0]))
			for j := 2; j < shaping_lpc_order; j += 2 {
				tmp2 = smlawb(d.sar2_q14[j - 1], d.sar2_q14[j + 0] - tmp1, warping_q16)
				d.sar2_q14[j - 1] = tmp1
				n_ar_q14 = smlawb(n_ar_q14, tmp1, i32(ar_shp_q13[j - 1]))
				tmp1 = smlawb(d.sar2_q14[j + 0], d.sar2_q14[j + 1] - tmp2, warping_q16)
				d.sar2_q14[j + 0] = tmp2
				n_ar_q14 = smlawb(n_ar_q14, tmp2, i32(ar_shp_q13[j]))
			}
			d.sar2_q14[shaping_lpc_order - 1] = tmp1
			n_ar_q14 = smlawb(n_ar_q14, tmp1, i32(ar_shp_q13[shaping_lpc_order - 1]))
			n_ar_q14 <<= 1
			n_ar_q14 = smlawb(n_ar_q14, d.lf_ar_q14, tilt_q14)
			n_ar_q14 <<= 2
			n_lf_q14 := smulwb(d.shape_q14[smpl_buf_idx^], lf_shp_q14)
			n_lf_q14 = smlawt(n_lf_q14, d.lf_ar_q14, lf_shp_q14)
			n_lf_q14 <<= 2
			tmp1 = n_ar_q14 + n_lf_q14
			tmp2 = n_ltp_q14 + lpc_pred_q14
			tmp1 = tmp2 - tmp1
			tmp1 = rshift_round(tmp1, 4)
			r_q10 := x_q10[i] - tmp1
			if d.seed < 0 do r_q10 = -r_q10
			r_q10 = limit32(r_q10, -(31 << 10), 30 << 10)
			q1_q10, q2_q10, rd1_q10, rd2_q10 := quant_pair(r_q10, offset_q10, lambda_q10)
			rr_q10 := r_q10 - q1_q10
			rd1_q10 = smlabb(rd1_q10, rr_q10, rr_q10) >> 10
			rr_q10 = r_q10 - q2_q10
			rd2_q10 = smlabb(rd2_q10, rr_q10, rr_q10) >> 10
			if rd1_q10 < rd2_q10 {
				s[0].rd_q10 = d.rd_q10 + rd1_q10
				s[1].rd_q10 = d.rd_q10 + rd2_q10
				s[0].q_q10 = q1_q10
				s[1].q_q10 = q2_q10
			} else {
				s[0].rd_q10 = d.rd_q10 + rd2_q10
				s[1].rd_q10 = d.rd_q10 + rd1_q10
				s[0].q_q10 = q2_q10
				s[1].q_q10 = q1_q10
			}
			for t in 0 ..< 2 {
				exc_q14 := s[t].q_q10 << 4
				if d.seed < 0 do exc_q14 = -exc_q14
				lpc_exc_q14 := exc_q14 + ltp_pred_q14
				xq_q14 := lpc_exc_q14 + lpc_pred_q14
				s[t].diff_q14 = xq_q14 - (x_q10[i] << 4)
				slf := s[t].diff_q14 - n_ar_q14
				s[t].sltp_shp_q14 = slf - n_lf_q14
				s[t].lf_ar_q14 = slf
				s[t].lpc_exc_q14 = lpc_exc_q14
				s[t].xq_q14 = xq_q14
			}
		}
		smpl_buf_idx^ = (smpl_buf_idx^ - 1) % SE_DECISION_DELAY
		if smpl_buf_idx^ < 0 do smpl_buf_idx^ += SE_DECISION_DELAY
		last_smple_idx := (smpl_buf_idx^ + decision_delay) % SE_DECISION_DELAY
		rdmin_q10 := ss[0][0].rd_q10
		winner_ind := 0
		for k in 1 ..< n_states {
			if ss[k][0].rd_q10 < rdmin_q10 {
				rdmin_q10 = ss[k][0].rd_q10
				winner_ind = k
			}
		}
		winner_rand_state := dd[winner_ind].rand_state[last_smple_idx]
		for k in 0 ..< n_states {
			if dd[k].rand_state[last_smple_idx] != winner_rand_state {
				ss[k][0].rd_q10 = ss[k][0].rd_q10 + (I32_MAX >> 4)
				ss[k][1].rd_q10 = ss[k][1].rd_q10 + (I32_MAX >> 4)
			}
		}
		rdmax_q10 := ss[0][0].rd_q10
		rdmin_q10 = ss[0][1].rd_q10
		rdmax_ind := 0
		rdmin_ind := 0
		for k in 1 ..< n_states {
			if ss[k][0].rd_q10 > rdmax_q10 {
				rdmax_q10 = ss[k][0].rd_q10
				rdmax_ind = k
			}
			if ss[k][1].rd_q10 < rdmin_q10 {
				rdmin_q10 = ss[k][1].rd_q10
				rdmin_ind = k
			}
		}
		if rdmin_q10 < rdmax_q10 {
			dst := uintptr(&dd[rdmax_ind]) + uintptr(i * 4)
			src := uintptr(&dd[rdmin_ind]) + uintptr(i * 4)
			mem.copy(rawptr(dst), rawptr(src), size_of(NSQ_Del_Dec) - i * 4)
			ss[rdmax_ind][0] = ss[rdmin_ind][1]
		}
		d := &dd[winner_ind]
		if subfr > 0 || i >= decision_delay {
			pulses[base + i - decision_delay] = i8(rshift_round(d.q_q10[last_smple_idx], 10))
			xq[base + i - decision_delay] = i16(sat16(rshift_round(smulww(d.xq_q14[last_smple_idx], delayed_gain_q10[last_smple_idx]), 8)))
			NSQ.sltp_shp_q14[int(NSQ.sltp_shp_buf_idx) - decision_delay] = d.shape_q14[last_smple_idx]
			sLTP_q15[int(NSQ.sltp_buf_idx) - decision_delay] = d.pred_q15[last_smple_idx]
		}
		NSQ.sltp_shp_buf_idx += 1
		NSQ.sltp_buf_idx += 1
		for k in 0 ..< n_states {
			dk := &dd[k]
			s := &ss[k][0]
			dk.lf_ar_q14 = s.lf_ar_q14
			dk.diff_q14 = s.diff_q14
			dk.slpc_q14[SE_NSQ_LPC_BUF_LENGTH + i] = s.xq_q14
			dk.xq_q14[smpl_buf_idx^] = s.xq_q14
			dk.q_q10[smpl_buf_idx^] = s.q_q10
			dk.pred_q15[smpl_buf_idx^] = s.lpc_exc_q14 << 1
			dk.shape_q14[smpl_buf_idx^] = s.sltp_shp_q14
			dk.seed = i32(u32(dk.seed) + u32(rshift_round(s.q_q10, 10)))
			dk.rand_state[smpl_buf_idx^] = dk.seed
			dk.rd_q10 = s.rd_q10
		}
		delayed_gain_q10[smpl_buf_idx^] = gain_q10
	}
	for k in 0 ..< n_states {
		d := &dd[k]
		copy(d.slpc_q14[:SE_NSQ_LPC_BUF_LENGTH], d.slpc_q14[length:length + SE_NSQ_LPC_BUF_LENGTH])
	}
}

silk_nsq_del_dec :: proc "contextless" (cmn: ^Silk_Enc_Common, NSQ: ^Silk_NSQ_State, ix: ^Side_Info, x16: []i16, pulses: []i8, prm: ^Silk_NSQ_Params) {
	dd: [SE_MAX_DEL_DEC_STATES]NSQ_Del_Dec
	sLTP_q15: [2 * MAX_FRAME_LENGTH]i32
	sLTP: [2 * MAX_FRAME_LENGTH]i16
	x_sc_q10: [MAX_SUB_FRAME_LENGTH]i32
	delayed_gain_q10: [SE_DECISION_DELAY]i32
	n_states := int(cmn.n_states_delayed_decision)
	lag := NSQ.lag_prev
	ltp_mem := int(cmn.ltp_mem_length)
	sl := int(cmn.subfr_length)
	for k in 0 ..< n_states {
		d := &dd[k]
		d.seed = (i32(k) + i32(ix.seed)) & 3
		d.seed_init = d.seed
		d.rd_q10 = 0
		d.lf_ar_q14 = NSQ.slf_ar_shp_q14
		d.diff_q14 = NSQ.sdiff_shp_q14
		d.shape_q14[0] = NSQ.sltp_shp_q14[ltp_mem - 1]
		copy(d.slpc_q14[:SE_NSQ_LPC_BUF_LENGTH], NSQ.slpc_q14[:SE_NSQ_LPC_BUF_LENGTH])
		d.sar2_q14 = NSQ.sar2_q14
	}
	offset_q10 := i32(silk_Quantization_Offsets_Q10[ix.signal_type >> 1][ix.quant_offset_type])
	smpl_buf_idx := 0
	decision_delay := min(SE_DECISION_DELAY, sl)
	if ix.signal_type == TYPE_VOICED {
		for k in 0 ..< int(cmn.nb_subfr) do decision_delay = min(decision_delay, int(prm.pitch_l[k]) - LTP_ORDER / 2 - 1)
	} else {
		if lag > 0 do decision_delay = min(decision_delay, int(lag) - LTP_ORDER / 2 - 1)
	}
	lsf_interp := ix.nlsf_interp_coef_q2 == 4 ? 0 : 1
	pxq_base := ltp_mem // xq index of current subframe = pxq_base + k*sl
	NSQ.sltp_shp_buf_idx = cmn.ltp_mem_length
	NSQ.sltp_buf_idx = cmn.ltp_mem_length
	subfr := 0
	for k in 0 ..< int(cmn.nb_subfr) {
		A_q12 := prm.pred_coef_q12[((k >> 1) | (1 - lsf_interp)) * MAX_LPC_ORDER:]
		B_q14 := prm.ltp_coef_q14[k * LTP_ORDER:]
		AR_shp := prm.ar_q13[k * SE_MAX_SHAPE_LPC_ORDER:]
		hsp := prm.harm_shape_gain_q14[k] >> 2
		hsp |= (prm.harm_shape_gain_q14[k] >> 1) << 16
		NSQ.rewhite_flag = 0
		if ix.signal_type == TYPE_VOICED {
			lag = prm.pitch_l[k]
			if (k & (3 - (lsf_interp << 1))) == 0 {
				if k == 2 {
					rdmin_q10 := dd[0].rd_q10
					winner_ind := 0
					for i in 1 ..< n_states {
						if dd[i].rd_q10 < rdmin_q10 {
							rdmin_q10 = dd[i].rd_q10
							winner_ind = i
						}
					}
					for i in 0 ..< n_states {
						if i != winner_ind do dd[i].rd_q10 += I32_MAX >> 4
					}
					d := &dd[winner_ind]
					last_smple_idx := smpl_buf_idx + decision_delay
					for i in 0 ..< decision_delay {
						last_smple_idx = (last_smple_idx - 1) % SE_DECISION_DELAY
						if last_smple_idx < 0 do last_smple_idx += SE_DECISION_DELAY
						o := k * sl + i - decision_delay
						pulses[o] = i8(rshift_round(d.q_q10[last_smple_idx], 10))
						NSQ.xq[pxq_base + o] = i16(sat16(rshift_round(smulww(d.xq_q14[last_smple_idx], prm.gains_q16[1]), 14)))
						NSQ.sltp_shp_q14[int(NSQ.sltp_shp_buf_idx) - decision_delay + i] = d.shape_q14[last_smple_idx]
					}
					subfr = 0
				}
				start_idx := ltp_mem - int(lag) - int(cmn.predict_lpc_order) - LTP_ORDER / 2
				lpc_analysis_filter(sLTP[start_idx:], NSQ.xq[start_idx + k * sl:], A_q12, ltp_mem - start_idx, int(cmn.predict_lpc_order))
				NSQ.sltp_buf_idx = cmn.ltp_mem_length
				NSQ.rewhite_flag = 1
			}
		}
		nsq_del_dec_scale_states(cmn, NSQ, dd[:], x16[k * sl:], x_sc_q10[:], sLTP[:], sLTP_q15[:], k, n_states, prm, i32(ix.signal_type),
			i32(decision_delay))
		noise_shape_quantizer_del_dec(NSQ, dd[:], i32(ix.signal_type), x_sc_q10[:], pulses, NSQ.xq[pxq_base:], k * sl, sLTP_q15[:],
			delayed_gain_q10[:], A_q12, B_q14, AR_shp, lag, hsp, prm.tilt_q14[k], prm.lf_shp_q14[k], prm.gains_q16[k], prm.lambda_q10,
			offset_q10, sl, subfr, int(cmn.shaping_lpc_order), int(cmn.predict_lpc_order), cmn.warping_q16, n_states, &smpl_buf_idx,
			decision_delay)
		subfr += 1
	}
	rdmin_q10 := dd[0].rd_q10
	winner_ind := 0
	for k in 1 ..< n_states {
		if dd[k].rd_q10 < rdmin_q10 {
			rdmin_q10 = dd[k].rd_q10
			winner_ind = k
		}
	}
	d := &dd[winner_ind]
	ix.seed = i8(d.seed_init)
	last_smple_idx := smpl_buf_idx + decision_delay
	gain_q10 := prm.gains_q16[cmn.nb_subfr - 1] >> 6
	end := int(cmn.nb_subfr) * sl
	for i in 0 ..< decision_delay {
		last_smple_idx = (last_smple_idx - 1) % SE_DECISION_DELAY
		if last_smple_idx < 0 do last_smple_idx += SE_DECISION_DELAY
		o := end + i - decision_delay
		pulses[o] = i8(rshift_round(d.q_q10[last_smple_idx], 10))
		NSQ.xq[pxq_base + o] = i16(sat16(rshift_round(smulww(d.xq_q14[last_smple_idx], gain_q10), 8)))
		NSQ.sltp_shp_q14[int(NSQ.sltp_shp_buf_idx) - decision_delay + i] = d.shape_q14[last_smple_idx]
	}
	copy(NSQ.slpc_q14[:SE_NSQ_LPC_BUF_LENGTH], d.slpc_q14[sl:sl + SE_NSQ_LPC_BUF_LENGTH])
	NSQ.sar2_q14 = d.sar2_q14
	NSQ.slf_ar_shp_q14 = d.lf_ar_q14
	NSQ.sdiff_shp_q14 = d.diff_q14
	NSQ.lag_prev = prm.pitch_l[cmn.nb_subfr - 1]
	fl := int(cmn.frame_length)
	copy(NSQ.xq[:ltp_mem], NSQ.xq[fl:fl + ltp_mem])
	copy(NSQ.sltp_shp_q14[:ltp_mem], NSQ.sltp_shp_q14[fl:fl + ltp_mem])
}
