package opus

// CELT encoder (celt_encoder.c, float path, no tonality analysis).

import "core:math"

Celt_Encoder :: struct {
	channels:          int,
	stream_channels:   int,
	force_intra:       bool,
	clip:              bool,
	disable_pf:        bool,
	complexity:        int,
	start, end:        int,
	bitrate:           i32,
	vbr:               bool,
	constrained_vbr:   bool,
	loss_rate:         int,
	lsb_depth:         int,
	disable_inv:       bool,
	// reset state
	rng:               u32,
	spread_decision:   int,
	delayed_intra:     f32,
	tonal_average:     int,
	last_coded_bands:  i32,
	hf_average:        int,
	tapset_decision:   int,
	prefilter_period:  int,
	prefilter_gain:    f32,
	prefilter_tapset:  int,
	consec_transient:  int,
	preemph_mem_e:     [2]f32,
	vbr_reservoir:     i32,
	vbr_drift:         i32,
	vbr_offset:        i32,
	vbr_count:         i32,
	overlap_max:       f32,
	stereo_saving:     f32,
	intensity:         int,
	spec_avg:          f32,
	in_mem:            [2][OVERLAP]f32,
	prefilter_mem:     [2][COMBFILTER_MAXPERIOD]f32,
	old_band_e:        [2 * NB_EBANDS]f32,
	old_log_e:         [2 * NB_EBANDS]f32,
	old_log_e2:        [2 * NB_EBANDS]f32,
	energy_error:      [2 * NB_EBANDS]f32,
}

BITRATE_MAX :: -1

celt_encoder_init :: proc(st: ^Celt_Encoder, channels: int) {
	st^ = {}
	st.channels = channels
	st.stream_channels = channels
	st.start = 0
	st.end = EFF_EBANDS
	st.clip = true
	st.bitrate = BITRATE_MAX
	st.vbr = false
	st.constrained_vbr = true
	st.complexity = 5
	st.lsb_depth = 24
	celt_encoder_reset(st)
}

celt_encoder_reset :: proc(st: ^Celt_Encoder) {
	keep := st^
	st.rng = 0
	st.spread_decision = SPREAD_NORMAL
	st.delayed_intra = 1
	st.tonal_average = 256
	st.last_coded_bands = 0
	st.hf_average = 0
	st.tapset_decision = 0
	st.prefilter_period = 0
	st.prefilter_gain = 0
	st.prefilter_tapset = 0
	st.consec_transient = 0
	st.preemph_mem_e = {}
	st.vbr_reservoir = 0
	st.vbr_drift = 0
	st.vbr_offset = 0
	st.vbr_count = 0
	st.overlap_max = 0
	st.stereo_saving = 0
	st.intensity = 0
	st.spec_avg = 0
	st.in_mem = {}
	st.prefilter_mem = {}
	st.old_band_e = {}
	st.energy_error = {}
	for i in 0 ..< 2 * NB_EBANDS {
		st.old_log_e[i] = -28
		st.old_log_e2[i] = -28
	}
	_ = keep
}

@(private = "file")
INV_TABLE := [128]u8 {
	255, 255, 156, 110, 86, 70, 59, 51, 45, 40, 37, 33, 31, 28, 26, 25,
	23, 22, 21, 20, 19, 18, 17, 16, 16, 15, 15, 14, 13, 13, 12, 12,
	12, 12, 11, 11, 11, 10, 10, 10, 9, 9, 9, 9, 9, 9, 8, 8,
	8, 8, 8, 7, 7, 7, 7, 7, 7, 6, 6, 6, 6, 6, 6, 6,
	6, 6, 6, 6, 6, 6, 6, 6, 6, 5, 5, 5, 5, 5, 5, 5,
	5, 5, 5, 5, 5, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4,
	4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 3, 3,
	3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 2,
}

@(private = "file")
transient_analysis :: proc(in_: []f32, len, C: int, tf_estimate: ^f32, tf_chan: ^int, allow_weak: bool, weak_transient: ^bool) -> bool {
	tmp: [960 + OVERLAP]f32
	weak_transient^ = false
	forward_decay: f32 = allow_weak ? 0.03125 : 0.0625
	len2 := len / 2
	mask_metric := 0
	for c in 0 ..< C {
		mem0, mem1: f32 = 0, 0
		for i in 0 ..< len {
			x := in_[i + c * len]
			y := mem0 + x
			mem0 = mem1 + y - 2 * x
			mem1 = x - 0.5 * y
			tmp[i] = y
		}
		for i in 0 ..< 12 do tmp[i] = 0
		mean: f32 = 0
		mem0 = 0
		for i in 0 ..< len2 {
			x2 := tmp[2 * i] * tmp[2 * i] + tmp[2 * i + 1] * tmp[2 * i + 1]
			mean += x2
			tmp[i] = mem0 + forward_decay * (x2 - mem0)
			mem0 = tmp[i]
		}
		mem0 = 0
		max_e: f32 = 0
		for i := len2 - 1; i >= 0; i -= 1 {
			tmp[i] = mem0 + 0.125 * (tmp[i] - mem0)
			mem0 = tmp[i]
			max_e = max(max_e, mem0)
		}
		mean = celt_sqrt(mean * max_e * 0.5 * f32(len2))
		norm := f32(len2) / (EPSILON + mean * 0.5)
		unmask := 0
		for i := 12; i < len2 - 5; i += 4 {
			id := int(max(0, min(127, math.floor(64 * norm * (tmp[i] + EPSILON)))))
			unmask += int(INV_TABLE[id])
		}
		unmask = 64 * unmask * 4 / (6 * (len2 - 17))
		if unmask > mask_metric {
			tf_chan^ = c
			mask_metric = unmask
		}
	}
	is_transient := mask_metric > 200
	if allow_weak && is_transient && mask_metric < 600 {
		is_transient = false
		weak_transient^ = true
	}
	tf_max := max(0, celt_sqrt(f32(27 * mask_metric)) - 42)
	tf_estimate^ = celt_sqrt(max(0, 0.0069 * min(163, tf_max) - 0.139))
	return is_transient
}

@(private = "file")
patch_transient_decision :: proc(new_e, old_e: []f32, start, end, C: int) -> bool {
	spread_old: [26]f32
	if C == 1 {
		spread_old[start] = old_e[start]
		for i in start + 1 ..< end do spread_old[i] = max(spread_old[i - 1] - 1, old_e[i])
	} else {
		spread_old[start] = max(old_e[start], old_e[start + NB_EBANDS])
		for i in start + 1 ..< end do spread_old[i] = max(spread_old[i - 1] - 1, max(old_e[i], old_e[i + NB_EBANDS]))
	}
	for i := end - 2; i >= start; i -= 1 do spread_old[i] = max(spread_old[i], spread_old[i + 1] - 1)
	mean_diff: f32 = 0
	for c in 0 ..< C {
		for i in max(2, start) ..< end - 1 {
			x1 := max(0, new_e[i + c * NB_EBANDS])
			x2 := max(0, spread_old[i])
			mean_diff += max(0, x1 - x2)
		}
	}
	mean_diff /= f32(C * (end - 1 - max(2, start)))
	return mean_diff > 1
}

@(private = "file")
compute_mdcts :: proc(short_blocks: int, in_: [2][]f32, out: []f32, C, CC, LM: int) {
	B, N, shift: int
	if short_blocks != 0 {
		B = short_blocks
		N = SHORT_MDCT_SIZE
		shift = MAX_LM
	} else {
		B = 1
		N = SHORT_MDCT_SIZE << uint(LM)
		shift = MAX_LM - LM
	}
	for c in 0 ..< CC {
		for b in 0 ..< B {
			clt_mdct_forward(in_[c][b * N:], out[b + c * N * B:], OVERLAP, shift, B)
		}
	}
	if CC == 2 && C == 1 {
		for i in 0 ..< B * N do out[i] = 0.5 * out[i] + 0.5 * out[B * N + i]
	}
}

@(private = "file")
amp2log2 :: proc(eff_end, end: int, band_e, band_log_e: []f32, C: int) {
	for c in 0 ..< C {
		for i in 0 ..< eff_end do band_log_e[i + c * NB_EBANDS] = celt_log2(band_e[i + c * NB_EBANDS]) - eMeans[i]
		for i in eff_end ..< end do band_log_e[c * NB_EBANDS + i] = -14
	}
}

@(private = "file")
l1_metric :: proc(tmp: []f32, N, LM: int, bias: f32) -> f32 {
	l1: f32 = 0
	for i in 0 ..< N do l1 += abs(tmp[i])
	return l1 + f32(LM) * bias * l1
}

@(private = "file")
tf_analysis :: proc(len: int, is_transient: bool, tf_res: []i32, lambda: int, X: []f32, N0, LM: int, tf_estimate: f32, tf_chan: int, importance: []int) -> int {
	metric, path0, path1: [NB_EBANDS]int
	tmp, tmp1: [8 * 22]f32
	bias := 0.04 * max(-0.25, 0.5 - tf_estimate)
	ti := is_transient ? 4 : 0
	for i in 0 ..< len {
		N := int(eband5ms[i + 1] - eband5ms[i]) << uint(LM)
		narrow := eband5ms[i + 1] - eband5ms[i] == 1
		copy(tmp[:N], X[tf_chan * N0 + (int(eband5ms[i]) << uint(LM)):][:N])
		L1 := l1_metric(tmp[:], N, is_transient ? LM : 0, bias)
		best_l1 := L1
		best_level := 0
		if is_transient && !narrow {
			copy(tmp1[:N], tmp[:N])
			haar1(tmp1[:], N >> uint(LM), 1 << uint(LM))
			L1 = l1_metric(tmp1[:], N, LM + 1, bias)
			if L1 < best_l1 {
				best_l1 = L1
				best_level = -1
			}
		}
		for k in 0 ..< LM + int(!(is_transient || narrow)) {
			B := is_transient ? LM - k - 1 : k + 1
			haar1(tmp[:], N >> uint(k), 1 << uint(k))
			L1 = l1_metric(tmp[:], N, B, bias)
			if L1 < best_l1 {
				best_l1 = L1
				best_level = k + 1
			}
		}
		metric[i] = is_transient ? 2 * best_level : -2 * best_level
		if narrow && (metric[i] == 0 || metric[i] == -2 * LM) do metric[i] -= 1
	}
	tsel := proc(LM, ti, sel, b: int) -> int {return int(tf_select_table[LM][ti + 2 * sel + b])}
	tf_select := 0
	selcost: [2]int
	for sel in 0 ..< 2 {
		cost0 := importance[0] * abs(metric[0] - 2 * tsel(LM, ti, sel, 0))
		cost1 := importance[0] * abs(metric[0] - 2 * tsel(LM, ti, sel, 1)) + (is_transient ? 0 : lambda)
		for i in 1 ..< len {
			curr0 := min(cost0, cost1 + lambda)
			curr1 := min(cost0 + lambda, cost1)
			cost0 = curr0 + importance[i] * abs(metric[i] - 2 * tsel(LM, ti, sel, 0))
			cost1 = curr1 + importance[i] * abs(metric[i] - 2 * tsel(LM, ti, sel, 1))
		}
		selcost[sel] = min(cost0, cost1)
	}
	if selcost[1] < selcost[0] && is_transient do tf_select = 1
	cost0 := importance[0] * abs(metric[0] - 2 * tsel(LM, ti, tf_select, 0))
	cost1 := importance[0] * abs(metric[0] - 2 * tsel(LM, ti, tf_select, 1)) + (is_transient ? 0 : lambda)
	for i in 1 ..< len {
		from0 := cost0
		from1 := cost1 + lambda
		curr0, curr1: int
		if from0 < from1 {
			curr0 = from0
			path0[i] = 0
		} else {
			curr0 = from1
			path0[i] = 1
		}
		from0 = cost0 + lambda
		from1 = cost1
		if from0 < from1 {
			curr1 = from0
			path1[i] = 0
		} else {
			curr1 = from1
			path1[i] = 1
		}
		cost0 = curr0 + importance[i] * abs(metric[i] - 2 * tsel(LM, ti, tf_select, 0))
		cost1 = curr1 + importance[i] * abs(metric[i] - 2 * tsel(LM, ti, tf_select, 1))
	}
	tf_res[len - 1] = cost0 < cost1 ? 0 : 1
	for i := len - 2; i >= 0; i -= 1 {
		tf_res[i] = tf_res[i + 1] == 1 ? i32(path1[i + 1]) : i32(path0[i + 1])
	}
	return tf_select
}

@(private = "file")
tf_encode :: proc(start, end: int, is_transient: bool, tf_res: []i32, LM: int, tf_select_: int, enc: ^Range) {
	tf_select := tf_select_
	budget := enc.storage * 8
	tell := u32(ec_tell(enc))
	logp: u32 = is_transient ? 2 : 4
	tf_select_rsv := LM > 0 && tell + logp + 1 <= budget
	if tf_select_rsv do budget -= 1
	curr: i32 = 0
	tf_changed: i32 = 0
	for i in start ..< end {
		if tell + logp <= budget {
			ec_enc_bit_logp(enc, (tf_res[i] ~ curr) != 0, logp)
			tell = u32(ec_tell(enc))
			curr = tf_res[i]
			tf_changed |= curr
		} else {
			tf_res[i] = curr
		}
		logp = is_transient ? 4 : 5
	}
	ti := is_transient ? 4 : 0
	if tf_select_rsv && tf_select_table[LM][ti + 0 + int(tf_changed)] != tf_select_table[LM][ti + 2 + int(tf_changed)] {
		ec_enc_bit_logp(enc, tf_select != 0, 1)
	} else {
		tf_select = 0
	}
	for i in start ..< end do tf_res[i] = i32(tf_select_table[LM][ti + 2 * tf_select + int(tf_res[i])])
}

@(private = "file")
alloc_trim_analysis :: proc(X: []f32, band_log_e: []f32, end, LM, C, N0: int, stereo_saving: ^f32, tf_estimate: f32, intensity: int, equiv_rate: i32) -> i32 {
	trim: f32 = 5
	if equiv_rate < 64000 {
		trim = 4
	} else if equiv_rate < 80000 {
		frac := (equiv_rate - 64000) >> 10
		trim = 4 + (1.0 / 16) * f32(frac)
	}
	if C == 2 {
		sum: f32 = 0
		for i in 0 ..< 8 {
			o := int(eband5ms[i]) << uint(LM)
			sum += inner_prod(X[o:], X[N0 + o:], int(eband5ms[i + 1] - eband5ms[i]) << uint(LM))
		}
		sum = (1.0 / 8) * sum
		sum = min(1, abs(sum))
		min_xc := sum
		for i in 8 ..< intensity {
			o := int(eband5ms[i]) << uint(LM)
			partial := inner_prod(X[o:], X[N0 + o:], int(eband5ms[i + 1] - eband5ms[i]) << uint(LM))
			min_xc = min(min_xc, abs(partial))
		}
		min_xc = min(1, abs(min_xc))
		log_xc := celt_log2(1.001 - sum * sum)
		log_xc2 := max(0.5 * log_xc, celt_log2(1.001 - min_xc * min_xc))
		trim += max(-4, 0.75 * log_xc)
		stereo_saving^ = min(stereo_saving^ + 0.25, -0.5 * log_xc2)
	}
	diff: f32 = 0
	for c in 0 ..< C {
		for i in 0 ..< end - 1 do diff += band_log_e[i + c * NB_EBANDS] * f32(2 + 2 * i - end)
	}
	diff /= f32(C * (end - 1))
	trim -= max(-2, min(2, (diff + 1) / 6))
	trim -= 2 * tf_estimate
	trim_index := i32(math.floor(0.5 + trim))
	return clamp(trim_index, 0, 10)
}

@(private = "file")
stereo_analysis :: proc(X: []f32, LM, N0: int) -> bool {
	sum_lr, sum_ms: f32 = EPSILON, EPSILON
	for i in 0 ..< 13 {
		for j in int(eband5ms[i]) << uint(LM) ..< int(eband5ms[i + 1]) << uint(LM) {
			L := X[j]
			R := X[N0 + j]
			M := L + R
			S := L - R
			sum_lr += abs(L) + abs(R)
			sum_ms += abs(M) + abs(S)
		}
	}
	sum_ms = 0.707107 * sum_ms
	thetas := 13
	if LM <= 1 do thetas -= 8
	return f32((int(eband5ms[13]) << uint(LM + 1)) + thetas) * sum_ms > f32(int(eband5ms[13]) << uint(LM + 1)) * sum_lr
}

@(private = "file")
median_of_5 :: proc(x: []f32) -> f32 {
	t0, t1, t3, t4: f32
	t2 := x[2]
	if x[0] > x[1] {t0, t1 = x[1], x[0]} else {t0, t1 = x[0], x[1]}
	if x[3] > x[4] {t3, t4 = x[4], x[3]} else {t3, t4 = x[3], x[4]}
	if t0 > t3 {
		t0, t3 = t3, t0
		t1, t4 = t4, t1
	}
	if t2 > t1 {
		if t1 < t3 do return min(t2, t3)
		return min(t4, t1)
	}
	if t2 < t3 do return min(t1, t3)
	return min(t2, t4)
}

@(private = "file")
median_of_3 :: proc(x: []f32) -> f32 {
	t0, t1: f32
	if x[0] > x[1] {t0, t1 = x[1], x[0]} else {t0, t1 = x[0], x[1]}
	t2 := x[2]
	if t1 < t2 do return t1
	if t0 < t2 do return t2
	return t0
}

@(private = "file")
dynalloc_analysis :: proc(band_log_e, band_log_e2: []f32, start, end, C: int, offsets: []i32, lsb_depth: int, is_transient, vbr, constrained_vbr: bool,
	LM: int, effective_bytes: int, tot_boost_out: ^i32, importance, spread_weight: []int) -> f32 {
	follower, noise_floor: [2 * NB_EBANDS]f32
	tot_boost: i32 = 0
	for i in 0 ..< NB_EBANDS do offsets[i] = 0
	max_depth: f32 = -31.9
	for i in 0 ..< end {
		noise_floor[i] = 0.0625 * f32(logN400[i]) + 0.5 + f32(9 - lsb_depth) - eMeans[i] + 0.0062 * f32((i + 5) * (i + 5))
	}
	for c in 0 ..< C do for i in 0 ..< end do max_depth = max(max_depth, band_log_e[c * NB_EBANDS + i] - noise_floor[i])
	{
		mask, sig: [NB_EBANDS]f32
		for i in 0 ..< end do mask[i] = band_log_e[i] - noise_floor[i]
		if C == 2 do for i in 0 ..< end do mask[i] = max(mask[i], band_log_e[NB_EBANDS + i] - noise_floor[i])
		copy(sig[:end], mask[:end])
		for i in 1 ..< end do mask[i] = max(mask[i], mask[i - 1] - 2)
		for i := end - 2; i >= 0; i -= 1 do mask[i] = max(mask[i], mask[i + 1] - 3)
		for i in 0 ..< end {
			smr := sig[i] - max(max(0, max_depth - 12), mask[i])
			shift := min(5, max(0, -int(math.floor(0.5 + smr))))
			spread_weight[i] = 32 >> uint(shift)
		}
	}
	if effective_bytes > 50 && LM >= 1 {
		last := 0
		for c in 0 ..< C {
			f := follower[c * NB_EBANDS:]
			b2 := band_log_e2[c * NB_EBANDS:]
			f[0] = b2[0]
			for i in 1 ..< end {
				if b2[i] > b2[i - 1] + 0.5 do last = i
				f[i] = min(f[i - 1] + 1.5, b2[i])
			}
			for i := last - 1; i >= 0; i -= 1 do f[i] = min(f[i], min(f[i + 1] + 2, b2[i]))
			offset: f32 = 1
			for i in 2 ..< end - 2 do f[i] = max(f[i], median_of_5(b2[i - 2:]) - offset)
			tmp := median_of_3(b2[0:]) - offset
			f[0] = max(f[0], tmp)
			f[1] = max(f[1], tmp)
			tmp = median_of_3(b2[end - 3:]) - offset
			f[end - 2] = max(f[end - 2], tmp)
			f[end - 1] = max(f[end - 1], tmp)
			for i in 0 ..< end do f[i] = max(f[i], noise_floor[i])
		}
		if C == 2 {
			for i in start ..< end {
				follower[NB_EBANDS + i] = max(follower[NB_EBANDS + i], follower[i] - 4)
				follower[i] = max(follower[i], follower[NB_EBANDS + i] - 4)
				follower[i] = 0.5 * (max(0, band_log_e[i] - follower[i]) + max(0, band_log_e[NB_EBANDS + i] - follower[NB_EBANDS + i]))
			}
		} else {
			for i in start ..< end do follower[i] = max(0, band_log_e[i] - follower[i])
		}
		for i in start ..< end do importance[i] = int(math.floor(0.5 + 13 * celt_exp2(min(follower[i], 4))))
		if (!vbr || constrained_vbr) && !is_transient {
			for i in start ..< end do follower[i] = 0.5 * follower[i]
		}
		for i in start ..< end {
			if i < 8 do follower[i] *= 2
			if i >= 12 do follower[i] = 0.5 * follower[i]
		}
		for i in start ..< end {
			follower[i] = min(follower[i], 4)
			width := C * int(eband5ms[i + 1] - eband5ms[i]) << uint(LM)
			boost, boost_bits: int
			if width < 6 {
				boost = int(follower[i])
				boost_bits = boost * width << BITRES
			} else if width > 48 {
				boost = int(follower[i] * 8)
				boost_bits = (boost * width << BITRES) / 8
			} else {
				boost = int(follower[i] * f32(width) / 6)
				boost_bits = boost * 6 << BITRES
			}
			if (!vbr || (constrained_vbr && !is_transient)) && (int(tot_boost) + boost_bits) >> BITRES >> 3 > 2 * effective_bytes / 3 {
				cap := i32((2 * effective_bytes / 3) << BITRES << 3)
				offsets[i] = cap - tot_boost
				tot_boost = cap
				break
			} else {
				offsets[i] = i32(boost)
				tot_boost += i32(boost_bits)
			}
		}
	} else {
		for i in start ..< end do importance[i] = 13
	}
	tot_boost_out^ = tot_boost
	return max_depth
}

@(private = "file")
SECOND_CHECK := [16]int{0, 0, 3, 2, 3, 2, 5, 2, 3, 2, 3, 2, 5, 2, 3, 2}

@(private = "file")
compute_pitch_gain :: proc(xy, xx, yy: f32) -> f32 {return xy / celt_sqrt(1 + xx * yy)}

@(private = "file")
remove_doubling :: proc(x_: []f32, maxperiod_, minperiod_, N_: int, T0_: ^int, prev_period_: int, prev_gain: f32) -> f32 {
	minperiod0 := minperiod_
	maxperiod := maxperiod_ / 2
	minperiod := minperiod_ / 2
	T0_^ /= 2
	prev_period := prev_period_ / 2
	N := N_ / 2
	x := x_[maxperiod:]
	if T0_^ >= maxperiod do T0_^ = maxperiod - 1
	T := T0_^
	T0 := T
	yy_lookup: [COMBFILTER_MAXPERIOD / 2 + 1]f32
	// x[-k] indexes into x_ before maxperiod
	xm :: proc(x_: []f32, base, k: int) -> f32 {return x_[base + k]}
	xx := inner_prod(x, x, N)
	xy := inner_prod(x, x_[maxperiod - T0:], N)
	yy_lookup[0] = xx
	yy := xx
	for i in 1 ..= maxperiod {
		yy = yy + xm(x_, maxperiod, -i) * xm(x_, maxperiod, -i) - xm(x_, maxperiod, N - i) * xm(x_, maxperiod, N - i)
		yy_lookup[i] = max(0, yy)
	}
	yy = yy_lookup[T0]
	best_xy := xy
	best_yy := yy
	g := compute_pitch_gain(xy, xx, yy)
	g0 := g
	for k in 2 ..= 15 {
		T1 := (2 * T0 + k) / (2 * k)
		if T1 < minperiod do break
		T1b: int
		if k == 2 {
			T1b = T1 + T0 > maxperiod ? T0 : T0 + T1
		} else {
			T1b = (2 * SECOND_CHECK[k] * T0 + k) / (2 * k)
		}
		xy1 := inner_prod(x, x_[maxperiod - T1:], N)
		xy2 := inner_prod(x, x_[maxperiod - T1b:], N)
		xy = 0.5 * (xy1 + xy2)
		yy = 0.5 * (yy_lookup[T1] + yy_lookup[T1b])
		g1 := compute_pitch_gain(xy, xx, yy)
		cont: f32
		if abs(T1 - prev_period) <= 1 {
			cont = prev_gain
		} else if abs(T1 - prev_period) <= 2 && 5 * k * k < T0 {
			cont = 0.5 * prev_gain
		}
		thresh := max(0.3, 0.7 * g0 - cont)
		if T1 < 3 * minperiod {
			thresh = max(0.4, 0.85 * g0 - cont)
		} else if T1 < 2 * minperiod {
			thresh = max(0.5, 0.9 * g0 - cont)
		}
		if g1 > thresh {
			best_xy = xy
			best_yy = yy
			T = T1
			g = g1
		}
	}
	best_xy = max(0, best_xy)
	pg: f32 = best_yy <= best_xy ? 1 : best_xy / (best_yy + 1)
	xcorr: [3]f32
	for k in 0 ..< 3 do xcorr[k] = inner_prod(x, x_[maxperiod - (T + k - 1):], N)
	offset := 0
	if (xcorr[2] - xcorr[0]) > 0.7 * (xcorr[1] - xcorr[0]) do offset = 1
	else if (xcorr[0] - xcorr[2]) > 0.7 * (xcorr[1] - xcorr[2]) do offset = -1
	if pg > g do pg = g
	T0_^ = 2 * T + offset
	if T0_^ < minperiod0 do T0_^ = minperiod0
	return pg
}

@(private = "file")
run_prefilter :: proc(st: ^Celt_Encoder, in_: [2][]f32, CC, N: int, prefilter_tapset: int, pitch: ^int, gain: ^f32, qgain: ^int, enabled: bool, nb_available_bytes: int) -> bool {
	pre_buf: [2][COMBFILTER_MAXPERIOD + 960]f32
	for c in 0 ..< CC {
		copy(pre_buf[c][:COMBFILTER_MAXPERIOD], st.prefilter_mem[c][:])
		copy(pre_buf[c][COMBFILTER_MAXPERIOD:COMBFILTER_MAXPERIOD + N], in_[c][OVERLAP:OVERLAP + N])
	}
	pitch_index: int
	gain1: f32
	if enabled {
		pitch_buf: [(COMBFILTER_MAXPERIOD + 960) >> 1]f32
		pitch_downsample({pre_buf[0][:], pre_buf[1][:]}, pitch_buf[:], COMBFILTER_MAXPERIOD + N, CC)
		pitch_index = pitch_search(pitch_buf[COMBFILTER_MAXPERIOD >> 1:], pitch_buf[:], N, COMBFILTER_MAXPERIOD - 3 * COMBFILTER_MINPERIOD)
		pitch_index = COMBFILTER_MAXPERIOD - pitch_index
		gain1 = remove_doubling(pitch_buf[:], COMBFILTER_MAXPERIOD, COMBFILTER_MINPERIOD, N, &pitch_index, st.prefilter_period, st.prefilter_gain)
		if pitch_index > COMBFILTER_MAXPERIOD - 2 do pitch_index = COMBFILTER_MAXPERIOD - 2
		gain1 = 0.7 * gain1
		if st.loss_rate > 2 do gain1 *= 0.5
		if st.loss_rate > 4 do gain1 *= 0.5
		if st.loss_rate > 8 do gain1 = 0
	} else {
		gain1 = 0
		pitch_index = COMBFILTER_MINPERIOD
	}
	pf_threshold: f32 = 0.2
	if abs(pitch_index - st.prefilter_period) * 10 > pitch_index do pf_threshold += 0.2
	if nb_available_bytes < 25 do pf_threshold += 0.1
	if nb_available_bytes < 35 do pf_threshold += 0.1
	if st.prefilter_gain > 0.4 do pf_threshold -= 0.1
	if st.prefilter_gain > 0.55 do pf_threshold -= 0.1
	pf_threshold = max(pf_threshold, 0.2)
	pf_on := false
	qg := 0
	if gain1 < pf_threshold {
		gain1 = 0
	} else {
		if abs(gain1 - st.prefilter_gain) < 0.1 do gain1 = st.prefilter_gain
		qg = int(math.floor(0.5 + gain1 * 32 / 3)) - 1
		qg = clamp(qg, 0, 7)
		gain1 = 0.09375 * f32(qg + 1)
		pf_on = true
	}
	for c in 0 ..< CC {
		offset := SHORT_MDCT_SIZE - OVERLAP
		st.prefilter_period = max(st.prefilter_period, COMBFILTER_MINPERIOD)
		inb := in_[c]
		copy(inb[:OVERLAP], st.in_mem[c][:])
		pre := pre_buf[c][:]
		if offset != 0 {
			comb_filter(inb, OVERLAP, pre, COMBFILTER_MAXPERIOD, st.prefilter_period, st.prefilter_period, offset, -st.prefilter_gain, -st.prefilter_gain,
				st.prefilter_tapset, st.prefilter_tapset, 0)
		}
		comb_filter(inb, OVERLAP + offset, pre, COMBFILTER_MAXPERIOD + offset, st.prefilter_period, pitch_index, N - offset, -st.prefilter_gain, -gain1,
			st.prefilter_tapset, prefilter_tapset, OVERLAP)
		copy(st.in_mem[c][:], inb[N:N + OVERLAP])
		if N > COMBFILTER_MAXPERIOD {
			copy(st.prefilter_mem[c][:], pre[N:N + COMBFILTER_MAXPERIOD])
		} else {
			copy(st.prefilter_mem[c][:COMBFILTER_MAXPERIOD - N], st.prefilter_mem[c][N:])
			copy(st.prefilter_mem[c][COMBFILTER_MAXPERIOD - N:], pre[COMBFILTER_MAXPERIOD:COMBFILTER_MAXPERIOD + N])
		}
	}
	gain^ = gain1
	pitch^ = pitch_index
	qgain^ = qg
	return pf_on
}

@(private = "file")
compute_vbr :: proc(base_target: i32, LM: int, bitrate: i32, last_coded_bands: i32, C: int, intensity: int, constrained_vbr: bool, stereo_saving_: f32,
	tot_boost: i32, tf_estimate: f32, max_depth: f32, temporal_vbr: f32) -> i32 {
	stereo_saving := stereo_saving_
	coded_bands := last_coded_bands != 0 ? int(last_coded_bands) : NB_EBANDS
	coded_bins := int(eband5ms[coded_bands]) << uint(LM)
	if C == 2 do coded_bins += int(eband5ms[min(intensity, coded_bands)]) << uint(LM)
	target := base_target
	if C == 2 {
		coded_stereo_bands := min(intensity, coded_bands)
		coded_stereo_dof := (int(eband5ms[coded_stereo_bands]) << uint(LM)) - coded_stereo_bands
		max_frac := 0.8 * f32(coded_stereo_dof) / f32(coded_bins)
		stereo_saving = min(stereo_saving, 1)
		target -= i32(min(max_frac * f32(target), (stereo_saving - 0.1) * f32(coded_stereo_dof << BITRES)))
	}
	target += tot_boost - (19 << uint(LM))
	tf_calibration: f32 = 0.044
	target += i32(2 * ((tf_estimate - tf_calibration) * f32(target)))
	{
		bins := int(eband5ms[NB_EBANDS - 2]) << uint(LM)
		floor_depth := i32(f32(C * bins << BITRES) * max_depth)
		floor_depth = max(floor_depth, target >> 2)
		target = min(target, floor_depth)
	}
	if constrained_vbr do target = base_target + i32(0.67 * f32(target - base_target))
	if tf_estimate < 0.2 {
		amount := 0.0000031 * f32(max(0, min(32000, 96000 - bitrate)))
		tvbr_factor := temporal_vbr * amount
		target += i32(tvbr_factor * f32(target))
	}
	return min(2 * base_target, target)
}

@(private = "file")
hysteresis_decision :: proc(val: f32, thresholds, hysteresis: []f32, N, prev: int) -> int {
	i := 0
	for ; i < N; i += 1 do if val < thresholds[i] do break
	if i > prev && val < thresholds[prev] + hysteresis[prev] do i = prev
	if i < prev && val > thresholds[prev - 1] - hysteresis[prev - 1] do i = prev
	return i
}

@(private = "file")
spreading_decision :: proc(X: []f32, average: ^int, last_decision: int, hf_average: ^int, tapset_decision: ^int, update_hf: bool, end, C, M: int, spread_weight: []int) -> int {
	N0 := M * SHORT_MDCT_SIZE
	if M * int(eband5ms[end] - eband5ms[end - 1]) <= 8 do return SPREAD_NONE
	sum, nb_bands, hf_sum := 0, 0, 0
	for c in 0 ..< C {
		for i in 0 ..< end {
			x := X[M * int(eband5ms[i]) + c * N0:]
			N := M * int(eband5ms[i + 1] - eband5ms[i])
			if N <= 8 do continue
			tcount: [3]int
			for j in 0 ..< N {
				x2n := x[j] * x[j] * f32(N)
				if x2n < 0.25 do tcount[0] += 1
				if x2n < 0.0625 do tcount[1] += 1
				if x2n < 0.015625 do tcount[2] += 1
			}
			if i > NB_EBANDS - 4 do hf_sum += 32 * (tcount[1] + tcount[0]) / N
			tmp := int(2 * tcount[2] >= N) + int(2 * tcount[1] >= N) + int(2 * tcount[0] >= N)
			sum += tmp * spread_weight[i]
			nb_bands += spread_weight[i]
		}
	}
	if update_hf {
		if hf_sum != 0 do hf_sum = hf_sum / (C * (4 - NB_EBANDS + end))
		hf_average^ = (hf_average^ + hf_sum) >> 1
		hf_sum = hf_average^
		if tapset_decision^ == 2 do hf_sum += 4
		else if tapset_decision^ == 0 do hf_sum -= 4
		if hf_sum > 22 do tapset_decision^ = 2
		else if hf_sum > 18 do tapset_decision^ = 1
		else do tapset_decision^ = 0
	}
	sum = (sum << 8) / max(nb_bands, 1)
	sum = (sum + average^) >> 1
	average^ = sum
	sum = (3 * sum + (((3 - last_decision) << 7) + 64) + 2) >> 2
	if sum < 80 do return SPREAD_AGGRESSIVE
	if sum < 256 do return SPREAD_NORMAL
	if sum < 384 do return SPREAD_LIGHT
	return SPREAD_NONE
}

// ---- Energy quantization (encoder side)

@(private = "file")
loss_distortion :: proc(e_bands, old_e_bands: []f32, start, end, C: int) -> f32 {
	dist: f32 = 0
	for c in 0 ..< C {
		for i in start ..< end {
			d := e_bands[i + c * NB_EBANDS] - old_e_bands[i + c * NB_EBANDS]
			dist += d * d
		}
	}
	return min(200, dist)
}

@(private = "file")
quant_coarse_energy_impl :: proc(start, end: int, e_bands, old_e_bands: []f32, budget: i32, tell_: i32, prob_model: []u8, error: []f32, enc: ^Range, C, LM: int, intra: bool, max_decay: f32) -> int {
	badness := 0
	prev := [2]f32{0, 0}
	coef, beta: f32
	if tell_ + 3 <= budget do ec_enc_bit_logp(enc, intra, 3)
	if intra {
		coef = 0
		beta = BETA_INTRA
	} else {
		beta = beta_coef[LM]
		coef = pred_coef[LM]
	}
	for i in start ..< end {
		for c in 0 ..< C {
			x := e_bands[i + c * NB_EBANDS]
			old_e := max(-9, old_e_bands[i + c * NB_EBANDS])
			f := x - coef * old_e - prev[c]
			qi := i32(math.floor(0.5 + f))
			decay_bound := max(-28, old_e_bands[i + c * NB_EBANDS]) - max_decay
			if qi < 0 && x < decay_bound {
				qi += i32(decay_bound - x)
				if qi > 0 do qi = 0
			}
			qi0 := qi
			tell := ec_tell(enc)
			bits_left := budget - tell - 3 * i32(C) * i32(end - i)
			if i != start && bits_left < 30 {
				if bits_left < 24 do qi = min(1, qi)
				if bits_left < 16 do qi = max(-1, qi)
			}
			if budget - tell >= 15 {
				pi := 2 * min(i, 20)
				ec_laplace_encode(enc, &qi, u32(prob_model[pi]) << 7, i32(prob_model[pi + 1]) << 6)
			} else if budget - tell >= 2 {
				qi = max(-1, min(qi, 1))
				ec_enc_icdf(enc, 2 * qi ~ -i32(qi < 0), small_energy_icdf[:], 2)
			} else if budget - tell >= 1 {
				qi = min(0, qi)
				ec_enc_bit_logp(enc, qi != 0, 1)
			} else {
				qi = -1
			}
			error[i + c * NB_EBANDS] = f - f32(qi)
			badness += int(abs(qi0 - qi))
			q := f32(qi)
			tmp := coef * old_e + prev[c] + q
			old_e_bands[i + c * NB_EBANDS] = tmp
			prev[c] = prev[c] + q - beta * q
		}
	}
	return badness
}

@(private = "file")
quant_coarse_energy :: proc(start, end, eff_end: int, e_bands, old_e_bands: []f32, budget: u32, error: []f32, enc: ^Range, C, LM: int,
	nb_available_bytes: int, force_intra: bool, delayed_intra: ^f32, two_pass_: bool, loss_rate: int) {
	two_pass := two_pass_
	intra := force_intra || (!two_pass && delayed_intra^ > f32(2 * C * (end - start)) && nb_available_bytes > (end - start) * C)
	intra_bias := i32((f32(budget) * delayed_intra^ * f32(loss_rate)) / f32(C * 512))
	new_distortion := loss_distortion(e_bands, old_e_bands, start, eff_end, C)
	tell := u32(ec_tell(enc))
	if tell + 3 > budget {
		two_pass = false
		intra = false
	}
	max_decay: f32 = 16
	if end - start > 10 do max_decay = min(max_decay, 0.125 * f32(nb_available_bytes))
	enc_start_state := enc^
	old_intra: [2 * NB_EBANDS]f32
	error_intra: [2 * NB_EBANDS]f32
	copy(old_intra[:], old_e_bands[:2 * NB_EBANDS])
	badness1 := 0
	if two_pass || intra {
		badness1 = quant_coarse_energy_impl(start, end, e_bands, old_intra[:], i32(budget), i32(tell), e_prob_model[LM][1][:], error_intra[:], enc, C, LM, true, max_decay)
	}
	if !intra {
		tell_intra := i32(ec_tell_frac(enc))
		enc_intra_state := enc^
		nstart := enc_start_state.offs
		nintra := enc_intra_state.offs
		intra_bits: [1275]u8
		save_bytes := int(nintra - nstart)
		copy(intra_bits[:save_bytes], enc.buf[nstart:nintra])
		enc^ = enc_start_state
		badness2 := quant_coarse_energy_impl(start, end, e_bands, old_e_bands, i32(budget), i32(tell), e_prob_model[LM][0][:], error, enc, C, LM, false, max_decay)
		if two_pass && (badness1 < badness2 || (badness1 == badness2 && i32(ec_tell_frac(enc)) + intra_bias > tell_intra)) {
			enc^ = enc_intra_state
			copy(enc.buf[nstart:nintra], intra_bits[:save_bytes])
			copy(old_e_bands[:2 * NB_EBANDS], old_intra[:])
			copy(error[:2 * NB_EBANDS], error_intra[:])
			intra = true
		}
	} else {
		copy(old_e_bands[:2 * NB_EBANDS], old_intra[:])
		copy(error[:2 * NB_EBANDS], error_intra[:])
	}
	if intra {
		delayed_intra^ = new_distortion
	} else {
		delayed_intra^ = pred_coef[LM] * pred_coef[LM] * delayed_intra^ + new_distortion
	}
}

@(private = "file")
quant_fine_energy :: proc(start, end: int, old_e_bands, error: []f32, fine_quant: []i32, enc: ^Range, C: int) {
	for i in start ..< end {
		if fine_quant[i] <= 0 do continue
		frac := i32(1) << u32(fine_quant[i])
		for c in 0 ..< C {
			q2 := i32(math.floor((error[i + c * NB_EBANDS] + 0.5) * f32(frac)))
			q2 = clamp(q2, 0, frac - 1)
			ec_enc_bits(enc, u32(q2), u32(fine_quant[i]))
			offset := (f32(q2) + 0.5) * f32(i32(1) << u32(14 - fine_quant[i])) * (1.0 / 16384) - 0.5
			old_e_bands[i + c * NB_EBANDS] += offset
			error[i + c * NB_EBANDS] -= offset
		}
	}
}

@(private = "file")
quant_energy_finalise :: proc(start, end: int, old_e_bands, error: []f32, fine_quant, fine_priority: []i32, bits_left_: i32, enc: ^Range, C: int) {
	bits_left := bits_left_
	for prio in 0 ..< i32(2) {
		for i := start; i < end && bits_left >= i32(C); i += 1 {
			if fine_quant[i] >= MAX_FINE_BITS || fine_priority[i] != prio do continue
			for c in 0 ..< C {
				q2: i32 = error[i + c * NB_EBANDS] < 0 ? 0 : 1
				ec_enc_bits(enc, u32(q2), 1)
				offset := (f32(q2) - 0.5) * f32(i32(1) << u32(14 - fine_quant[i] - 1)) * (1.0 / 16384)
				old_e_bands[i + c * NB_EBANDS] += offset
				error[i + c * NB_EBANDS] -= offset
				bits_left -= 1
			}
		}
	}
}

// ---------------------------------------------------------------------------

@(rodata)
INTENSITY_THRESHOLDS := [21]f32{1, 2, 3, 4, 5, 6, 7, 8, 16, 24, 36, 44, 50, 56, 62, 67, 72, 79, 88, 106, 134}
@(rodata)
INTENSITY_HISTERESIS := [21]f32{1, 1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 2, 2, 2, 3, 3, 4, 5, 6, 8, 8}

// Encodes one CELT frame of interleaved float pcm (±1.0) into compressed
// (whose length is the max size). Returns bytes written.
celt_encode :: proc(st: ^Celt_Encoder, pcm: []f32, frame_size: int, compressed: []u8) -> (int, Celt_Error) {
	CC := st.channels
	C := st.stream_channels
	start := st.start
	end := st.end
	hybrid := start != 0
	tf_estimate: f32 = 0
	if len(compressed) < 2 do return 0, .Bad_Arg
	LM := 0
	for ; LM <= MAX_LM; LM += 1 do if SHORT_MDCT_SIZE << uint(LM) == frame_size do break
	if LM > MAX_LM do return 0, .Bad_Arg
	M := 1 << uint(LM)
	N := M * SHORT_MDCT_SIZE
	tell: i32 = 1
	tell0_frac: i32 = 1
	nb_filled_bytes := 0
	nb_compressed_bytes := min(len(compressed), 1275)
	nb_available_bytes := nb_compressed_bytes - nb_filled_bytes
	vbr_rate: i32
	effective_bytes: int
	if st.vbr && st.bitrate != BITRATE_MAX {
		den := i32(48000 >> BITRES)
		vbr_rate = (st.bitrate * i32(frame_size) + (den >> 1)) / den
		effective_bytes = int(vbr_rate >> (3 + BITRES))
	} else {
		vbr_rate = 0
		tmp := st.bitrate * i32(frame_size)
		if tell > 1 do tmp += tell
		if st.bitrate != BITRATE_MAX {
			nb_compressed_bytes = max(2, min(nb_compressed_bytes, int((tmp + 4 * 48000) / (8 * 48000))))
		}
		effective_bytes = nb_compressed_bytes - nb_filled_bytes
	}
	equiv_rate := (i32(nb_compressed_bytes) * 8 * 50 >> uint(3 - LM)) - i32(40 * C + 20) * i32((400 >> uint(LM)) - 50)
	if st.bitrate != BITRATE_MAX do equiv_rate = min(equiv_rate, st.bitrate - i32(40 * C + 20) * i32((400 >> uint(LM)) - 50))
	enc_: Range
	ec_enc_init(&enc_, compressed[:nb_compressed_bytes])
	enc := &enc_
	if vbr_rate > 0 && st.constrained_vbr {
		vbr_bound := vbr_rate
		max_allowed := min(max(tell == 1 ? 2 : 0, int((vbr_rate + vbr_bound - st.vbr_reservoir) >> (BITRES + 3))), nb_available_bytes)
		if max_allowed < nb_available_bytes {
			nb_compressed_bytes = nb_filled_bytes + max_allowed
			nb_available_bytes = max_allowed
			ec_enc_shrink(enc, u32(nb_compressed_bytes))
		}
	}
	total_bits := i32(nb_compressed_bytes * 8)
	eff_end := min(end, EFF_EBANDS)

	in_bufs: [2][960 + OVERLAP]f32
	in_: [2][]f32 = {in_bufs[0][:N + OVERLAP], in_bufs[1][:N + OVERLAP]}
	sample_max := st.overlap_max
	for i in 0 ..< C * (N - OVERLAP) do sample_max = max(sample_max, abs(pcm[i]))
	st.overlap_max = 0
	for i in C * (N - OVERLAP) ..< C * N do st.overlap_max = max(st.overlap_max, abs(pcm[i]))
	sample_max = max(sample_max, st.overlap_max)
	silence := sample_max <= 1.0 / f32(i64(1) << uint(st.lsb_depth))
	if tell == 1 do ec_enc_bit_logp(enc, silence, 15)
	else do silence = false
	if silence {
		if vbr_rate > 0 {
			nb_compressed_bytes = min(nb_compressed_bytes, nb_filled_bytes + 2)
			effective_bytes = nb_compressed_bytes
			total_bits = i32(nb_compressed_bytes * 8)
			nb_available_bytes = 2
			ec_enc_shrink(enc, u32(nb_compressed_bytes))
		}
		tell = i32(nb_compressed_bytes * 8)
		enc.nbits_total += tell - ec_tell(enc)
	}
	for c in 0 ..< CC {
		need_clip := st.clip && sample_max > 65536
		m := st.preemph_mem_e[c]
		dst := in_[c][OVERLAP:]
		for i in 0 ..< N {
			x := pcm[CC * i + c] * CELT_SIG_SCALE
			if need_clip do x = max(-65536, min(65536, x))
			dst[i] = x - m
			m = PREEMPH * x
		}
		st.preemph_mem_e[c] = m
	}
	pitch_index := COMBFILTER_MINPERIOD
	gain1: f32 = 0
	prefilter_tapset := 0
	pf_on := false
	{
		enabled := nb_available_bytes > 12 * C && !hybrid && !silence && !st.disable_pf && st.complexity >= 5
		prefilter_tapset = st.tapset_decision
		qg: int
		pf_on = run_prefilter(st, in_, CC, N, prefilter_tapset, &pitch_index, &gain1, &qg, enabled, nb_available_bytes)
		if !pf_on {
			if !hybrid && tell + 16 <= total_bits do ec_enc_bit_logp(enc, false, 1)
		} else {
			ec_enc_bit_logp(enc, true, 1)
			pitch_index += 1
			octave := ec_ilog(u32(pitch_index)) - 5
			ec_enc_uint(enc, u32(octave), 6)
			ec_enc_bits(enc, u32(pitch_index - (16 << uint(octave))), u32(4 + octave))
			pitch_index -= 1
			ec_enc_bits(enc, u32(qg), 3)
			ec_enc_icdf(enc, i32(prefilter_tapset), tapset_icdf[:], 2)
		}
	}
	is_transient := false
	short_blocks := 0
	tf_chan := 0
	weak_transient := false
	transient_got_disabled := false
	if st.complexity >= 1 {
		planar: [2 * (960 + OVERLAP)]f32
		for c in 0 ..< CC do copy(planar[c * (N + OVERLAP):(c + 1) * (N + OVERLAP)], in_[c][:N + OVERLAP])
		is_transient = transient_analysis(planar[:], N + OVERLAP, CC, &tf_estimate, &tf_chan, false, &weak_transient)
	}
	if LM > 0 && ec_tell(enc) + 3 <= total_bits {
		if is_transient do short_blocks = M
	} else {
		is_transient = false
		transient_got_disabled = true
	}
	freq: [2 * 960]f32
	band_e, band_log_e, band_log_e2: [2 * NB_EBANDS]f32
	second_mdct := short_blocks != 0 && st.complexity >= 8
	if second_mdct {
		compute_mdcts(0, in_, freq[:], C, CC, LM)
		compute_band_energies(freq[:], band_e[:], eff_end, C, LM)
		amp2log2(eff_end, end, band_e[:], band_log_e2[:], C)
		for i in 0 ..< C * NB_EBANDS do band_log_e2[i] += 0.5 * f32(LM)
	}
	compute_mdcts(short_blocks, in_, freq[:], C, CC, LM)
	if CC == 2 && C == 1 do tf_chan = 0
	compute_band_energies(freq[:], band_e[:], eff_end, C, LM)
	amp2log2(eff_end, end, band_e[:], band_log_e[:], C)
	temporal_vbr: f32 = 0
	{
		follow: f32 = -10
		frame_avg: f32 = 0
		offset: f32 = short_blocks != 0 ? 0.5 * f32(LM) : 0
		for i in start ..< end {
			follow = max(follow - 1, band_log_e[i] - offset)
			if C == 2 do follow = max(follow, band_log_e[i + NB_EBANDS] - offset)
			frame_avg += follow
		}
		frame_avg /= f32(end - start)
		temporal_vbr = frame_avg - st.spec_avg
		temporal_vbr = min(3, max(-1.5, temporal_vbr))
		st.spec_avg += 0.02 * temporal_vbr
	}
	if !second_mdct do copy(band_log_e2[:], band_log_e[:])
	if LM > 0 && ec_tell(enc) + 3 <= total_bits && !is_transient && st.complexity >= 5 && !hybrid {
		if patch_transient_decision(band_log_e[:], st.old_band_e[:], start, end, C) {
			is_transient = true
			short_blocks = M
			compute_mdcts(short_blocks, in_, freq[:], C, CC, LM)
			compute_band_energies(freq[:], band_e[:], eff_end, C, LM)
			amp2log2(eff_end, end, band_e[:], band_log_e[:], C)
			for i in 0 ..< C * NB_EBANDS do band_log_e2[i] += 0.5 * f32(LM)
			tf_estimate = 0.2
		}
	}
	if LM > 0 && ec_tell(enc) + 3 <= total_bits do ec_enc_bit_logp(enc, is_transient, 3)
	X: [2 * 960]f32
	normalise_bands(freq[:], X[:], band_e[:], eff_end, C, M)
	enable_tf_analysis := effective_bytes >= 15 * C && !hybrid && st.complexity >= 2
	offsets: [NB_EBANDS]i32
	importance, spread_weight: [NB_EBANDS]int
	tot_boost: i32
	max_depth := dynalloc_analysis(band_log_e[:], band_log_e2[:], start, end, C, offsets[:], st.lsb_depth, is_transient, st.vbr, st.constrained_vbr, LM,
		effective_bytes, &tot_boost, importance[:], spread_weight[:])
	tf_res: [NB_EBANDS]i32
	tf_select := 0
	if enable_tf_analysis {
		lambda := max(80, 20480 / effective_bytes + 2)
		tf_select = tf_analysis(eff_end, is_transient, tf_res[:], lambda, X[:], N, LM, tf_estimate, tf_chan, importance[:])
		for i in eff_end ..< end do tf_res[i] = tf_res[eff_end - 1]
	} else {
		for i in 0 ..< end do tf_res[i] = i32(is_transient)
		tf_select = 0
	}
	error: [2 * NB_EBANDS]f32
	for c in 0 ..< C {
		for i in start ..< end {
			if abs(band_log_e[i + c * NB_EBANDS] - st.old_band_e[i + c * NB_EBANDS]) < 2 {
				band_log_e[i + c * NB_EBANDS] -= st.energy_error[i + c * NB_EBANDS] * 0.25
			}
		}
	}
	quant_coarse_energy(start, end, eff_end, band_log_e[:], st.old_band_e[:], u32(total_bits), error[:], enc, C, LM, nb_available_bytes, st.force_intra,
		&st.delayed_intra, st.complexity >= 4, st.loss_rate)
	tf_encode(start, end, is_transient, tf_res[:], LM, tf_select, enc)
	if ec_tell(enc) + 4 <= total_bits {
		if short_blocks != 0 || st.complexity < 3 || nb_available_bytes < 10 * C {
			st.spread_decision = st.complexity == 0 ? SPREAD_NONE : SPREAD_NORMAL
		} else {
			st.spread_decision = spreading_decision(X[:], &st.tonal_average, st.spread_decision, &st.hf_average, &st.tapset_decision,
				pf_on && short_blocks == 0, eff_end, C, M, spread_weight[:])
		}
		ec_enc_icdf(enc, i32(st.spread_decision), spread_icdf[:], 5)
	}
	cap: [NB_EBANDS]i32
	init_caps(cap[:], i32(LM), i32(C))
	dynalloc_logp: i32 = 6
	total_bits <<= BITRES
	total_boost: i32 = 0
	tellf := i32(ec_tell_frac(enc))
	for i in start ..< end {
		width := i32(C) * i32(eband5ms[i + 1] - eband5ms[i]) << uint(LM)
		quanta := min(width << BITRES, max(6 << BITRES, width))
		dynalloc_loop_logp := dynalloc_logp
		boost: i32 = 0
		j: i32 = 0
		for ; tellf + (dynalloc_loop_logp << BITRES) < total_bits - total_boost && boost < cap[i]; j += 1 {
			flag := j < offsets[i]
			ec_enc_bit_logp(enc, flag, u32(dynalloc_loop_logp))
			tellf = i32(ec_tell_frac(enc))
			if !flag do break
			boost += quanta
			total_boost += quanta
			dynalloc_loop_logp = 1
		}
		if j != 0 do dynalloc_logp = max(2, dynalloc_logp - 1)
		offsets[i] = boost
	}
	dual_stereo := false
	if C == 2 {
		if LM != 0 do dual_stereo = stereo_analysis(X[:], LM, N)
		st.intensity = hysteresis_decision(f32(equiv_rate / 1000), INTENSITY_THRESHOLDS[:], INTENSITY_HISTERESIS[:], 21, st.intensity)
		st.intensity = min(end, max(start, st.intensity))
	}
	alloc_trim: i32 = 5
	if tellf + (6 << BITRES) <= total_bits - total_boost {
		alloc_trim = alloc_trim_analysis(X[:], band_log_e[:], end, LM, C, N, &st.stereo_saving, tf_estimate, st.intensity, equiv_rate)
		ec_enc_icdf(enc, alloc_trim, trim_icdf[:], 7)
		tellf = i32(ec_tell_frac(enc))
	}
	if vbr_rate > 0 {
		lm_diff := u32(MAX_LM - LM)
		nb_compressed_bytes = min(nb_compressed_bytes, 1275 >> uint(3 - LM))
		base_target := vbr_rate - i32((40 * C + 20) << BITRES)
		if st.constrained_vbr do base_target += st.vbr_offset >> lm_diff
		target := compute_vbr(base_target, LM, equiv_rate, st.last_coded_bands, C, st.intensity, st.constrained_vbr, st.stereo_saving, tot_boost, tf_estimate,
			max_depth, temporal_vbr)
		target = target + tellf
		min_allowed := int((tellf + total_boost + (1 << (BITRES + 3)) - 1) >> (BITRES + 3)) + 2
		nb_available_bytes = int((target + (1 << (BITRES + 2))) >> (BITRES + 3))
		nb_available_bytes = max(min_allowed, nb_available_bytes)
		nb_available_bytes = min(nb_compressed_bytes, nb_available_bytes)
		delta := target - vbr_rate
		target = i32(nb_available_bytes) << (BITRES + 3)
		if silence {
			nb_available_bytes = 2
			target = 2 * 8 << BITRES
			delta = 0
		}
		alpha: f32
		if st.vbr_count < 970 {
			st.vbr_count += 1
			alpha = 1 / f32(st.vbr_count + 20)
		} else {
			alpha = 0.001
		}
		if st.constrained_vbr do st.vbr_reservoir += target - vbr_rate
		if st.constrained_vbr {
			st.vbr_drift += i32(alpha * f32((delta * (1 << lm_diff)) - st.vbr_offset - st.vbr_drift))
			st.vbr_offset = -st.vbr_drift
		}
		if st.constrained_vbr && st.vbr_reservoir < 0 {
			adjust := int((-st.vbr_reservoir) / (8 << BITRES))
			nb_available_bytes += silence ? 0 : adjust
			st.vbr_reservoir = 0
		}
		nb_compressed_bytes = min(nb_compressed_bytes, nb_available_bytes)
		ec_enc_shrink(enc, u32(nb_compressed_bytes))
	}
	fine_quant, pulses, fine_priority: [NB_EBANDS]i32
	bits := (i32(nb_compressed_bytes * 8) << BITRES) - i32(ec_tell_frac(enc)) - 1
	anti_collapse_rsv: i32 = is_transient && LM >= 2 && bits >= i32(LM + 2) << BITRES ? 1 << BITRES : 0
	bits -= anti_collapse_rsv
	signal_bandwidth := i32(end - 1)
	{
		min_bw: i32
		switch {
		case equiv_rate < 32000 * i32(C): min_bw = 13
		case equiv_rate < 48000 * i32(C): min_bw = 16
		case equiv_rate < 60000 * i32(C): min_bw = 18
		case equiv_rate < 80000 * i32(C): min_bw = 19
		case: min_bw = 20
		}
		signal_bandwidth = max(signal_bandwidth, min_bw)
	}
	intensity_ := i32(st.intensity)
	dual_stereo_ := i32(dual_stereo)
	balance: i32
	coded_bands := clt_compute_allocation(i32(start), i32(end), offsets[:], cap[:], alloc_trim, &intensity_, &dual_stereo_, bits, &balance, pulses[:],
		fine_quant[:], fine_priority[:], i32(C), i32(LM), enc, true, st.last_coded_bands, signal_bandwidth)
	st.intensity = int(intensity_)
	dual_stereo = dual_stereo_ != 0
	if st.last_coded_bands != 0 {
		st.last_coded_bands = min(st.last_coded_bands + 1, max(st.last_coded_bands - 1, coded_bands))
	} else {
		st.last_coded_bands = coded_bands
	}
	quant_fine_energy(start, end, st.old_band_e[:], error[:], fine_quant[:], enc, C)
	collapse_masks: [2 * NB_EBANDS]u8
	y_: []f32 = C == 2 ? X[N:] : nil
	quant_all_bands(true, start, end, X[:], y_, collapse_masks[:], band_e[:], pulses[:], short_blocks != 0, st.spread_decision, dual_stereo, st.intensity,
		tf_res[:], i32(nb_compressed_bytes) * (8 << BITRES) - anti_collapse_rsv, balance, enc, LM, int(coded_bands), &st.rng, st.complexity, st.disable_inv)
	if anti_collapse_rsv > 0 {
		anti_collapse_on := st.consec_transient < 2
		ec_enc_bits(enc, u32(anti_collapse_on), 1)
	}
	quant_energy_finalise(start, end, st.old_band_e[:], error[:], fine_quant[:], fine_priority[:], i32(nb_compressed_bytes * 8) - ec_tell(enc), enc, C)
	st.energy_error = {}
	for c in 0 ..< C do for i in start ..< end do st.energy_error[i + c * NB_EBANDS] = max(-0.5, min(0.5, error[i + c * NB_EBANDS]))
	if silence do for i in 0 ..< C * NB_EBANDS do st.old_band_e[i] = -28
	st.prefilter_period = pitch_index
	st.prefilter_gain = gain1
	st.prefilter_tapset = prefilter_tapset
	if CC == 2 && C == 1 do copy(st.old_band_e[NB_EBANDS:], st.old_band_e[:NB_EBANDS])
	if !is_transient {
		copy(st.old_log_e2[:], st.old_log_e[:])
		copy(st.old_log_e[:], st.old_band_e[:])
	} else {
		for i in 0 ..< CC * NB_EBANDS do st.old_log_e[i] = min(st.old_log_e[i], st.old_band_e[i])
	}
	for c in 0 ..< CC {
		for i in 0 ..< start {
			st.old_band_e[c * NB_EBANDS + i] = 0
			st.old_log_e[c * NB_EBANDS + i] = -28
			st.old_log_e2[c * NB_EBANDS + i] = -28
		}
		for i in end ..< NB_EBANDS {
			st.old_band_e[c * NB_EBANDS + i] = 0
			st.old_log_e[c * NB_EBANDS + i] = -28
			st.old_log_e2[c * NB_EBANDS + i] = -28
		}
	}
	if is_transient || transient_got_disabled do st.consec_transient += 1
	else do st.consec_transient = 0
	st.rng = enc.rng
	ec_enc_done(enc)
	if enc.error != 0 do return 0, .Internal
	return nb_compressed_bytes, .None
}

