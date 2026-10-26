package opus

// SILK encoder: LPC -> NLSF conversion and NLSF quantization (A2NLSF.c,
// NLSF_encode.c, NLSF_VQ.c, NLSF_VQ_weights_laroia.c, NLSF_del_dec_quant.c,
// process_NLSFs.c). Fixed point, bit-exact with the reference.

@(private = "file")
a2nlsf_trans_poly :: proc "contextless" (p: []i32, dd: int) {
	for k in 2 ..= dd {
		for n := dd; n > k; n -= 1 do p[n - 2] -= p[n]
		p[k - 2] -= p[k] << 1
	}
}

@(private = "file")
a2nlsf_eval_poly :: #force_inline proc "contextless" (p: []i32, x: i32, dd: int) -> i32 {
	y32 := p[dd]
	x_q16 := x << 4
	for n := dd - 1; n >= 0; n -= 1 do y32 = smlaww(p[n], y32, x_q16)
	return y32
}

@(private = "file")
a2nlsf_init :: proc "contextless" (a_q16: []i32, P, Q: []i32, dd: int) {
	P[dd] = 1 << 16
	Q[dd] = 1 << 16
	for k in 0 ..< dd {
		P[k] = -a_q16[dd - k - 1] - a_q16[dd + k]
		Q[k] = -a_q16[dd - k - 1] + a_q16[dd + k]
	}
	for k := dd; k > 0; k -= 1 {
		P[k - 1] -= P[k]
		Q[k - 1] += Q[k]
	}
	a2nlsf_trans_poly(P, dd)
	a2nlsf_trans_poly(Q, dd)
}

silk_a2nlsf :: proc "contextless" (NLSF: []i16, a_q16: []i32, d: int) {
	BIN_DIV_STEPS :: 3
	MAX_ITERATIONS :: 16
	P: [MAX_LPC_ORDER / 2 + 1]i32
	Q: [MAX_LPC_ORDER / 2 + 1]i32
	dd := d >> 1
	a2nlsf_init(a_q16, P[:], Q[:], dd)
	p := P[:]
	xlo := i32(silk_LSFCosTab_FIX_Q12[0])
	ylo := a2nlsf_eval_poly(p, xlo, dd)
	root_ix: int
	if ylo < 0 {
		NLSF[0] = 0
		p = Q[:]
		ylo = a2nlsf_eval_poly(p, xlo, dd)
		root_ix = 1
	} else {
		root_ix = 0
	}
	k := 1
	i := 0
	thr: i32 = 0
	for {
		xhi := i32(silk_LSFCosTab_FIX_Q12[k])
		yhi := a2nlsf_eval_poly(p, xhi, dd)
		if (ylo <= 0 && yhi >= thr) || (ylo >= 0 && yhi <= -thr) {
			thr = yhi == 0 ? 1 : 0
			ffrac: i32 = -256
			for m in 0 ..< BIN_DIV_STEPS {
				xmid := rshift_round(xlo + xhi, 1)
				ymid := a2nlsf_eval_poly(p, xmid, dd)
				if (ylo <= 0 && ymid >= 0) || (ylo >= 0 && ymid <= 0) {
					xhi = xmid
					yhi = ymid
				} else {
					xlo = xmid
					ylo = ymid
					ffrac = ffrac + (128 >> u32(m))
				}
			}
			if silk_abs(ylo) < 65536 {
				den := ylo - yhi
				nom := (ylo << (8 - BIN_DIV_STEPS)) + (den >> 1)
				if den != 0 do ffrac += nom / den
			} else {
				ffrac += ylo / ((ylo - yhi) >> (8 - BIN_DIV_STEPS))
			}
			NLSF[root_ix] = i16(min((i32(k) << 8) + ffrac, I16_MAX))
			root_ix += 1
			if root_ix >= d do break
			p = (root_ix & 1) == 0 ? P[:] : Q[:]
			xlo = i32(silk_LSFCosTab_FIX_Q12[k - 1])
			ylo = (1 - i32(root_ix & 2)) << 12
		} else {
			k += 1
			xlo = xhi
			ylo = yhi
			thr = 0
			if k > 128 {
				i += 1
				if i > MAX_ITERATIONS {
					NLSF[0] = i16((i32(1) << 15) / i32(d + 1))
					for kk in 1 ..< d do NLSF[kk] = NLSF[kk - 1] + NLSF[0]
					return
				}
				bwexpander_32(a_q16, d, 65536 - (i32(1) << u32(i)))
				a2nlsf_init(a_q16, P[:], Q[:], dd)
				p = P[:]
				xlo = i32(silk_LSFCosTab_FIX_Q12[0])
				ylo = a2nlsf_eval_poly(p, xlo, dd)
				if ylo < 0 {
					NLSF[0] = 0
					p = Q[:]
					ylo = a2nlsf_eval_poly(p, xlo, dd)
					root_ix = 1
				} else {
					root_ix = 0
				}
				k = 1
			}
		}
	}
}

// ---- copies of decoder helpers (file-private there)

silk_enc_nlsf_unpack :: proc "contextless" (ec_ix: []i16, pred_q8: []u8, cb: ^NLSF_CB, cb1_index: i32) {
	sel := cb.ec_sel[cb1_index * cb.order / 2:]
	for i := i32(0); i < cb.order; i += 2 {
		entry := sel[i / 2]
		ec_ix[i] = i16(smulbb(i32((entry >> 1) & 7), 2 * NLSF_QUANT_MAX_AMPLITUDE + 1))
		pred_q8[i] = cb.pred_q8[i + i32(entry & 1) * (cb.order - 1)]
		ec_ix[i + 1] = i16(smulbb(i32((entry >> 5) & 7), 2 * NLSF_QUANT_MAX_AMPLITUDE + 1))
		pred_q8[i + 1] = cb.pred_q8[i + i32((entry >> 4) & 1) * (cb.order - 1) + 1]
	}
}

silk_enc_nlsf_stabilize :: proc "contextless" (nlsf: []i16, delta_min: []i16, L: int) {
	for _ in 0 ..< 20 {
		min_diff := i32(nlsf[0]) - i32(delta_min[0])
		I := 0
		for i in 1 ..< L {
			diff := i32(nlsf[i]) - (i32(nlsf[i - 1]) + i32(delta_min[i]))
			if diff < min_diff {
				min_diff = diff
				I = i
			}
		}
		diff := (i32(1) << 15) - (i32(nlsf[L - 1]) + i32(delta_min[L]))
		if diff < min_diff {
			min_diff = diff
			I = L
		}
		if min_diff >= 0 do return
		if I == 0 {
			nlsf[0] = delta_min[0]
		} else if I == L {
			nlsf[L - 1] = i16((i32(1) << 15) - i32(delta_min[L]))
		} else {
			min_center: i32 = 0
			for k in 0 ..< I do min_center += i32(delta_min[k])
			min_center += i32(delta_min[I]) >> 1
			max_center := i32(1) << 15
			for k := L; k > I; k -= 1 do max_center -= i32(delta_min[k])
			max_center -= i32(delta_min[I]) >> 1
			center := i16(limit32(rshift_round(i32(nlsf[I - 1]) + i32(nlsf[I]), 1), min_center, max_center))
			nlsf[I - 1] = center - i16(i32(delta_min[I]) >> 1)
			nlsf[I] = nlsf[I - 1] + delta_min[I]
		}
	}
	for i in 1 ..< L {
		v := nlsf[i]
		j := i - 1
		for j >= 0 && v < nlsf[j] {
			nlsf[j + 1] = nlsf[j]
			j -= 1
		}
		nlsf[j + 1] = v
	}
	nlsf[0] = i16(max(i32(nlsf[0]), i32(delta_min[0])))
	for i in 1 ..< L do nlsf[i] = i16(max(i32(nlsf[i]), sat16(i32(nlsf[i - 1]) + i32(delta_min[i]))))
	nlsf[L - 1] = i16(min(i32(nlsf[L - 1]), (i32(1) << 15) - i32(delta_min[L])))
	for i := L - 2; i >= 0; i -= 1 do nlsf[i] = i16(min(i32(nlsf[i]), i32(nlsf[i + 1]) - i32(delta_min[i + 1])))
}

silk_enc_nlsf_decode :: proc "contextless" (nlsf_q15: []i16, indices: []i8, cb: ^NLSF_CB) {
	pred_q8: [MAX_LPC_ORDER]u8
	ec_ix: [MAX_LPC_ORDER]i16
	res_q10: [MAX_LPC_ORDER]i16
	silk_enc_nlsf_unpack(ec_ix[:], pred_q8[:], cb, i32(indices[0]))
	out_q10: i32 = 0
	for i := cb.order - 1; i >= 0; i -= 1 {
		pred_q10 := smulbb(out_q10, i32(i16(pred_q8[i]))) >> 8
		out_q10 = i32(indices[i + 1]) << 10
		if out_q10 > 0 {
			out_q10 -= 102
		} else if out_q10 < 0 {
			out_q10 += 102
		}
		out_q10 = smlawb(pred_q10, out_q10, cb.quant_step_size_q16)
		res_q10[i] = i16(out_q10)
	}
	base := int(indices[0]) * int(cb.order)
	for i in 0 ..< cb.order {
		t := (i32(res_q10[i]) << 14) / i32(cb.cb1_wght_q9[base + int(i)]) + (i32(i16(cb.cb1_nlsf_q8[base + int(i)])) << 7)
		nlsf_q15[i] = i16(limit32(t, 0, 32767))
	}
	silk_enc_nlsf_stabilize(nlsf_q15, cb.delta_min_q15, int(cb.order))
}

// ----

@(private = "file")
nlsf_vq :: proc "contextless" (err_q24: []i32, in_q15: []i16, cb_q8: []u8, wght_q9: []i16, K: int, order: int) {
	for i in 0 ..< K {
		cb := cb_q8[i * order:]
		w := wght_q9[i * order:]
		sum_error_q24: i32 = 0
		pred_q24: i32 = 0
		for m := order - 2; m >= 0; m -= 2 {
			diff_q15 := i32(in_q15[m + 1]) - (i32(cb[m + 1]) << 7)
			diffw_q24 := smulbb(diff_q15, i32(w[m + 1]))
			sum_error_q24 = sum_error_q24 + silk_abs(diffw_q24 - (pred_q24 >> 1))
			pred_q24 = diffw_q24
			diff_q15 = i32(in_q15[m]) - (i32(cb[m]) << 7)
			diffw_q24 = smulbb(diff_q15, i32(w[m]))
			sum_error_q24 = sum_error_q24 + silk_abs(diffw_q24 - (pred_q24 >> 1))
			pred_q24 = diffw_q24
		}
		err_q24[i] = sum_error_q24
	}
}

silk_nlsf_vq_weights_laroia :: proc "contextless" (w_out: []i16, nlsf: []i16, D: int) {
	ONE :: i32(1) << (15 + SE_NLSF_W_Q)
	tmp1 := max(i32(nlsf[0]), 1)
	tmp1 = ONE / tmp1
	tmp2 := max(i32(nlsf[1]) - i32(nlsf[0]), 1)
	tmp2 = ONE / tmp2
	w_out[0] = i16(min(tmp1 + tmp2, I16_MAX))
	for k := 1; k < D - 1; k += 2 {
		tmp1 = max(i32(nlsf[k + 1]) - i32(nlsf[k]), 1)
		tmp1 = ONE / tmp1
		w_out[k] = i16(min(tmp1 + tmp2, I16_MAX))
		tmp2 = max(i32(nlsf[k + 2]) - i32(nlsf[k + 1]), 1)
		tmp2 = ONE / tmp2
		w_out[k + 1] = i16(min(tmp1 + tmp2, I16_MAX))
	}
	tmp1 = max((i32(1) << 15) - i32(nlsf[D - 1]), 1)
	tmp1 = ONE / tmp1
	w_out[D - 1] = i16(min(tmp1 + tmp2, I16_MAX))
}

@(private = "file")
nlsf_del_dec_quant :: proc "contextless" (indices: []i8, x_q10: []i16, w_q5: []i16, pred_coef_q8: []u8, ec_ix: []i16, ec_rates_q5: []u8,
	quant_step_size_q16: i32, inv_quant_step_size_q6: i32, mu_q20: i32, order: int) -> i32 {
	NS :: SE_NLSF_QUANT_DEL_DEC_STATES
	AMP :: NLSF_QUANT_MAX_AMPLITUDE
	EXT :: SE_NLSF_QUANT_MAX_AMPLITUDE_EXT
	ind_sort: [NS]i32
	ind: [NS][MAX_LPC_ORDER]i8
	prev_out_q10: [2 * NS]i16
	RD_q25: [2 * NS]i32
	RD_min_q25: [NS]i32
	RD_max_q25: [NS]i32
	out0_q10_table: [2 * EXT]i32
	out1_q10_table: [2 * EXT]i32
	for i in -EXT ..= EXT - 1 {
		out0_q10 := i16(i32(i) << 10)
		out1_q10 := i16(i32(out0_q10) + 1024)
		if i > 0 {
			out0_q10 = i16(i32(out0_q10) - 102)
			out1_q10 = i16(i32(out1_q10) - 102)
		} else if i == 0 {
			out1_q10 = i16(i32(out1_q10) - 102)
		} else if i == -1 {
			out0_q10 = i16(i32(out0_q10) + 102)
		} else {
			out0_q10 = i16(i32(out0_q10) + 102)
			out1_q10 = i16(i32(out1_q10) + 102)
		}
		out0_q10_table[i + EXT] = smulbb(i32(out0_q10), quant_step_size_q16) >> 16
		out1_q10_table[i + EXT] = smulbb(i32(out1_q10), quant_step_size_q16) >> 16
	}
	n_states := 1
	RD_q25[0] = 0
	prev_out_q10[0] = 0
	for i := order - 1; i >= 0; i -= 1 {
		rates_q5 := ec_rates_q5[ec_ix[i]:]
		in_q10 := i32(x_q10[i])
		for j in 0 ..< n_states {
			pred_q10 := smulbb(i32(i16(pred_coef_q8[i])), i32(prev_out_q10[j])) >> 8
			res_q10 := in_q10 - pred_q10
			ind_tmp := smulbb(inv_quant_step_size_q6, res_q10) >> 16
			ind_tmp = limit32(ind_tmp, -EXT, EXT - 1)
			ind[j][i] = i8(ind_tmp)
			out0_q10 := i16(out0_q10_table[ind_tmp + EXT])
			out1_q10 := i16(out1_q10_table[ind_tmp + EXT])
			out0_q10 = i16(i32(out0_q10) + pred_q10)
			out1_q10 = i16(i32(out1_q10) + pred_q10)
			prev_out_q10[j] = out0_q10
			prev_out_q10[j + n_states] = out1_q10
			rate0_q5, rate1_q5: i32
			if ind_tmp + 1 >= AMP {
				if ind_tmp + 1 == AMP {
					rate0_q5 = i32(rates_q5[ind_tmp + AMP])
					rate1_q5 = 280
				} else {
					rate0_q5 = smlabb(280 - 43 * AMP, 43, ind_tmp)
					rate1_q5 = rate0_q5 + 43
				}
			} else if ind_tmp <= -AMP {
				if ind_tmp == -AMP {
					rate0_q5 = 280
					rate1_q5 = i32(rates_q5[ind_tmp + 1 + AMP])
				} else {
					rate0_q5 = smlabb(280 - 43 * AMP, -43, ind_tmp)
					rate1_q5 = rate0_q5 - 43
				}
			} else {
				rate0_q5 = i32(rates_q5[ind_tmp + AMP])
				rate1_q5 = i32(rates_q5[ind_tmp + 1 + AMP])
			}
			RD_tmp_q25 := RD_q25[j]
			diff_q10 := in_q10 - i32(out0_q10)
			RD_q25[j] = smlabb(RD_tmp_q25 + smulbb(diff_q10, diff_q10) * i32(w_q5[i]), mu_q20, rate0_q5)
			diff_q10 = in_q10 - i32(out1_q10)
			RD_q25[j + n_states] = smlabb(RD_tmp_q25 + smulbb(diff_q10, diff_q10) * i32(w_q5[i]), mu_q20, rate1_q5)
		}
		if n_states <= NS / 2 {
			for j in 0 ..< n_states do ind[j + n_states][i] = ind[j][i] + 1
			n_states <<= 1
			for j in n_states ..< NS do ind[j][i] = ind[j - n_states][i]
		} else {
			for j in 0 ..< NS {
				if RD_q25[j] > RD_q25[j + NS] {
					RD_max_q25[j] = RD_q25[j]
					RD_min_q25[j] = RD_q25[j + NS]
					RD_q25[j] = RD_min_q25[j]
					RD_q25[j + NS] = RD_max_q25[j]
					t := prev_out_q10[j]
					prev_out_q10[j] = prev_out_q10[j + NS]
					prev_out_q10[j + NS] = t
					ind_sort[j] = i32(j + NS)
				} else {
					RD_min_q25[j] = RD_q25[j]
					RD_max_q25[j] = RD_q25[j + NS]
					ind_sort[j] = i32(j)
				}
			}
			for {
				min_max_q25 := I32_MAX
				max_min_q25: i32 = 0
				ind_min_max := 0
				ind_max_min := 0
				for j in 0 ..< NS {
					if min_max_q25 > RD_max_q25[j] {
						min_max_q25 = RD_max_q25[j]
						ind_min_max = j
					}
					if max_min_q25 < RD_min_q25[j] {
						max_min_q25 = RD_min_q25[j]
						ind_max_min = j
					}
				}
				if min_max_q25 >= max_min_q25 do break
				ind_sort[ind_max_min] = ind_sort[ind_min_max] ~ NS
				RD_q25[ind_max_min] = RD_q25[ind_min_max + NS]
				prev_out_q10[ind_max_min] = prev_out_q10[ind_min_max + NS]
				RD_min_q25[ind_max_min] = 0
				RD_max_q25[ind_min_max] = I32_MAX
				ind[ind_max_min] = ind[ind_min_max]
			}
			for j in 0 ..< NS do ind[j][i] += i8(ind_sort[j] >> SE_NLSF_QUANT_DEL_DEC_STATES_LOG2)
		}
	}
	ind_tmp := 0
	min_q25 := I32_MAX
	for j in 0 ..< 2 * NS {
		if min_q25 > RD_q25[j] {
			min_q25 = RD_q25[j]
			ind_tmp = j
		}
	}
	for j in 0 ..< order do indices[j] = ind[ind_tmp & (NS - 1)][j]
	indices[0] += i8(ind_tmp >> SE_NLSF_QUANT_DEL_DEC_STATES_LOG2)
	return min_q25
}

silk_nlsf_encode :: proc "contextless" (nlsf_indices: []i8, nlsf_q15: []i16, cb: ^NLSF_CB, w_q2: []i16, nlsf_mu_q20: i32, n_survivors: int, signal_type: i32) -> i32 {
	err_q24: [32]i32
	RD_q25: [16]i32
	temp_indices1: [16]i32
	temp_indices2: [16 * MAX_LPC_ORDER]i8
	res_q10: [MAX_LPC_ORDER]i16
	w_adj_q5: [MAX_LPC_ORDER]i16
	pred_q8: [MAX_LPC_ORDER]u8
	ec_ix: [MAX_LPC_ORDER]i16
	order := int(cb.order)
	silk_enc_nlsf_stabilize(nlsf_q15, cb.delta_min_q15, order)
	nlsf_vq(err_q24[:], nlsf_q15, cb.cb1_nlsf_q8, cb.cb1_wght_q9, int(cb.n_vectors), order)
	silk_insertion_sort_increasing(err_q24[:], temp_indices1[:], int(cb.n_vectors), n_survivors)
	for s in 0 ..< n_survivors {
		ind1 := temp_indices1[s]
		cb_el := cb.cb1_nlsf_q8[int(ind1) * order:]
		cb_w := cb.cb1_wght_q9[int(ind1) * order:]
		for i in 0 ..< order {
			nlsf_tmp_q15 := i32(i16(u16(cb_el[i]) << 7))
			w_tmp_q9 := i32(cb_w[i])
			res_q10[i] = i16(smulbb(i32(nlsf_q15[i]) - nlsf_tmp_q15, w_tmp_q9) >> 14)
			w_adj_q5[i] = i16(div32_varq(i32(w_q2[i]), smulbb(w_tmp_q9, w_tmp_q9), 21))
		}
		silk_enc_nlsf_unpack(ec_ix[:], pred_q8[:], cb, ind1)
		RD_q25[s] = nlsf_del_dec_quant(temp_indices2[s * MAX_LPC_ORDER:], res_q10[:], w_adj_q5[:], pred_q8[:], ec_ix[:], cb.ec_rates_q5,
			cb.quant_step_size_q16, cb.inv_quant_step_q6, nlsf_mu_q20, order)
		icdf := cb.cb1_icdf[(signal_type >> 1) * cb.n_vectors:]
		prob_q8: i32
		if ind1 == 0 {
			prob_q8 = 256 - i32(icdf[ind1])
		} else {
			prob_q8 = i32(icdf[ind1 - 1]) - i32(icdf[ind1])
		}
		bits_q7 := (8 << 7) - lin2log(prob_q8)
		RD_q25[s] = smlabb(RD_q25[s], bits_q7, nlsf_mu_q20 >> 2)
	}
	best_index: [1]i32
	silk_insertion_sort_increasing(RD_q25[:], best_index[:], n_survivors, 1)
	nlsf_indices[0] = i8(temp_indices1[best_index[0]])
	copy(nlsf_indices[1:1 + order], temp_indices2[int(best_index[0]) * MAX_LPC_ORDER:][:order])
	silk_enc_nlsf_decode(nlsf_q15, nlsf_indices, cb)
	return RD_q25[0]
}

// process_NLSFs + float wrapper
silk_process_nlsfs_flp :: proc "contextless" (cmn: ^Silk_Enc_Common, pred_coef: ^[2][MAX_LPC_ORDER]f32, nlsf_q15: []i16, prev_nlsf_q15: []i16) {
	pred_coef_q12: [2][MAX_LPC_ORDER]i16
	nlsf0_temp_q15: [MAX_LPC_ORDER]i16
	nlsfw_qw: [MAX_LPC_ORDER]i16
	nlsfw0_temp_qw: [MAX_LPC_ORDER]i16
	order := int(cmn.predict_lpc_order)
	nlsf_mu_q20 := smlawb(3146, -268434, cmn.speech_activity_q8)
	if cmn.nb_subfr == 2 do nlsf_mu_q20 = nlsf_mu_q20 + (nlsf_mu_q20 >> 1)
	silk_nlsf_vq_weights_laroia(nlsfw_qw[:], nlsf_q15, order)
	do_interpolate := cmn.use_interpolated_nlsfs == 1 && cmn.indices.nlsf_interp_coef_q2 < 4
	if do_interpolate {
		silk_interpolate(nlsf0_temp_q15[:], prev_nlsf_q15, nlsf_q15, i32(cmn.indices.nlsf_interp_coef_q2), order)
		silk_nlsf_vq_weights_laroia(nlsfw0_temp_qw[:], nlsf0_temp_q15[:], order)
		ic := i32(cmn.indices.nlsf_interp_coef_q2)
		i_sqr_q15 := i32(i16(smulbb(ic, ic) << 11))
		for i in 0 ..< order {
			nlsfw_qw[i] = i16((i32(nlsfw_qw[i]) >> 1) + (smulbb(i32(nlsfw0_temp_qw[i]), i_sqr_q15) >> 16))
		}
	}
	silk_nlsf_encode(cmn.indices.nlsf_indices[:], nlsf_q15, cmn.nlsf_cb, nlsfw_qw[:], nlsf_mu_q20, int(cmn.nlsf_msvq_survivors), i32(cmn.indices.signal_type))
	nlsf2a(pred_coef_q12[1][:], nlsf_q15, order)
	if do_interpolate {
		silk_interpolate(nlsf0_temp_q15[:], prev_nlsf_q15, nlsf_q15, i32(cmn.indices.nlsf_interp_coef_q2), order)
		nlsf2a(pred_coef_q12[0][:], nlsf0_temp_q15[:], order)
	} else {
		copy(pred_coef_q12[0][:order], pred_coef_q12[1][:order])
	}
	for j in 0 ..< 2 {
		for i in 0 ..< order do pred_coef[j][i] = f32(pred_coef_q12[j][i]) * (1.0 / 4096.0)
	}
}
