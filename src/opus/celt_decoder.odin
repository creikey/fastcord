package opus

// CELT decoder (celt_decoder.c, float).

DECODE_BUFFER_SIZE :: 2048
PLC_PITCH_LAG_MAX :: 720
PLC_PITCH_LAG_MIN :: 100

Celt_Decoder :: struct {
	channels:               int,
	stream_channels:        int,
	downsample:             int,
	start, end:             int,
	disable_inv:            bool,
	rng:                    u32,
	error:                  bool,
	last_pitch_index:       int,
	loss_count:             int,
	skip_plc:               bool,
	postfilter_period:      int,
	postfilter_period_old:  int,
	postfilter_gain:        f32,
	postfilter_gain_old:    f32,
	postfilter_tapset:      int,
	postfilter_tapset_old:  int,
	preemph_mem_d:          [2]f32,
	decode_mem:             [2][DECODE_BUFFER_SIZE + OVERLAP]f32,
	lpc:                    [2][LPC_ORDER]f32,
	old_band_e:             [2 * NB_EBANDS]f32,
	old_log_e:              [2 * NB_EBANDS]f32,
	old_log_e2:             [2 * NB_EBANDS]f32,
	background_log_e:       [2 * NB_EBANDS]f32,
}

resampling_factor :: proc "contextless" (rate: int) -> int {
	switch rate {
	case 48000: return 1
	case 24000: return 2
	case 16000: return 3
	case 12000: return 4
	case 8000: return 6
	}
	return 0
}

celt_decoder_init :: proc(st: ^Celt_Decoder, rate: int, channels: int) -> bool {
	st^ = {}
	st.channels = channels
	st.stream_channels = channels
	st.downsample = resampling_factor(rate)
	st.start = 0
	st.end = EFF_EBANDS
	st.disable_inv = channels == 1
	celt_decoder_reset(st)
	return st.downsample != 0
}

celt_decoder_reset :: proc(st: ^Celt_Decoder) {
	keep_ch, keep_sch, keep_ds, keep_s, keep_e, keep_inv := st.channels, st.stream_channels, st.downsample, st.start, st.end, st.disable_inv
	st^ = {}
	st.channels, st.stream_channels, st.downsample, st.start, st.end, st.disable_inv = keep_ch, keep_sch, keep_ds, keep_s, keep_e, keep_inv
	for i in 0 ..< 2 * NB_EBANDS {
		st.old_log_e[i] = -28
		st.old_log_e2[i] = -28
	}
	st.skip_plc = true
}

@(private = "file")
deemphasis :: proc "contextless" (out_syn: [2][]f32, pcm: []f32, n, C, downsample: int, mem: ^[2]f32) {
	coef0 := PREEMPH
	nd := n / downsample
	for c in 0 ..< C {
		m := mem[c]
		x := out_syn[c]
		if downsample > 1 {
			scratch: [960]f32
			for j in 0 ..< n {
				tmp := x[j] + VERY_SMALL + m
				m = coef0 * tmp
				scratch[j] = tmp
			}
			for j in 0 ..< nd do pcm[j * C + c] = scratch[j * downsample] * (1 / CELT_SIG_SCALE)
		} else {
			for j in 0 ..< n {
				tmp := x[j] + VERY_SMALL + m
				m = coef0 * tmp
				pcm[j * C + c] = tmp * (1 / CELT_SIG_SCALE)
			}
		}
		mem[c] = m
	}
}

celt_synthesis :: proc "contextless" (X: []f32, out_syn: [2][]f32, old_band_e: []f32, start, eff_end, C, CC: int, is_transient: bool, LM, downsample: int, silence: bool) {
	freq: [960 + OVERLAP]f32
	n := SHORT_MDCT_SIZE << uint(LM)
	M := 1 << uint(LM)
	B, NB, shift: int
	if is_transient {
		B = M
		NB = SHORT_MDCT_SIZE
		shift = MAX_LM
	} else {
		B = 1
		NB = SHORT_MDCT_SIZE << uint(LM)
		shift = MAX_LM - LM
	}
	if CC == 2 && C == 1 {
		denormalise_bands(X, freq[:], old_band_e, start, eff_end, M, downsample, silence)
		freq2 := out_syn[1][OVERLAP / 2:]
		copy(freq2[:n], freq[:n])
		for b in 0 ..< B do clt_mdct_backward(freq2[b:], out_syn[0][NB * b:], OVERLAP, shift, B)
		for b in 0 ..< B do clt_mdct_backward(freq[b:], out_syn[1][NB * b:], OVERLAP, shift, B)
	} else if CC == 1 && C == 2 {
		freq2 := out_syn[0][OVERLAP / 2:]
		denormalise_bands(X, freq[:], old_band_e, start, eff_end, M, downsample, silence)
		denormalise_bands(X[n:], freq2, old_band_e[NB_EBANDS:], start, eff_end, M, downsample, silence)
		for i in 0 ..< n do freq[i] = 0.5 * freq[i] + 0.5 * freq2[i]
		for b in 0 ..< B do clt_mdct_backward(freq[b:], out_syn[0][NB * b:], OVERLAP, shift, B)
	} else {
		for c in 0 ..< CC {
			denormalise_bands(X[c * n:], freq[:], old_band_e[c * NB_EBANDS:], start, eff_end, M, downsample, silence)
			for b in 0 ..< B do clt_mdct_backward(freq[b:], out_syn[c][NB * b:], OVERLAP, shift, B)
		}
	}
	for c in 0 ..< CC do for i in 0 ..< n do out_syn[c][i] = clamp(out_syn[c][i], -SIG_SAT, SIG_SAT)
}

@(private = "file")
tf_decode :: proc "contextless" (start, end: int, is_transient: bool, tf_res: []i32, LM: int, dec: ^Range) {
	budget := dec.storage * 8
	tell := u32(ec_tell(dec))
	logp: u32 = is_transient ? 2 : 4
	tf_select_rsv := LM > 0 && tell + logp + 1 <= budget
	if tf_select_rsv do budget -= 1
	curr: i32 = 0
	tf_changed: i32 = 0
	for i in start ..< end {
		if tell + logp <= budget {
			curr ~= i32(ec_dec_bit_logp(dec, logp))
			tell = u32(ec_tell(dec))
			tf_changed |= curr
		}
		tf_res[i] = curr
		logp = is_transient ? 4 : 5
	}
	tf_select: i32 = 0
	ti := is_transient ? 4 : 0
	if tf_select_rsv && tf_select_table[LM][ti + 0 + int(tf_changed)] != tf_select_table[LM][ti + 2 + int(tf_changed)] {
		tf_select = i32(ec_dec_bit_logp(dec, 1))
	}
	for i in start ..< end do tf_res[i] = i32(tf_select_table[LM][ti + 2 * int(tf_select) + int(tf_res[i])])
}

@(private = "file")
plc_pitch_search :: proc(st: ^Celt_Decoder, C: int) -> int {
	lp: [DECODE_BUFFER_SIZE >> 1]f32
	pitch_downsample({st.decode_mem[0][:], st.decode_mem[1][:]}, lp[:], DECODE_BUFFER_SIZE, C)
	pitch := pitch_search(lp[PLC_PITCH_LAG_MAX >> 1:], lp[:], DECODE_BUFFER_SIZE - PLC_PITCH_LAG_MAX, PLC_PITCH_LAG_MAX - PLC_PITCH_LAG_MIN)
	return PLC_PITCH_LAG_MAX - pitch
}

@(private = "file")
celt_decode_lost :: proc(st: ^Celt_Decoder, n: int, LM: int) {
	C := st.channels
	out_syn: [2][]f32
	for c in 0 ..< C do out_syn[c] = st.decode_mem[c][DECODE_BUFFER_SIZE - n:]
	loss_count := st.loss_count
	start := st.start
	noise_based := loss_count >= 5 || start != 0 || st.skip_plc
	if noise_based {
		X: [2 * 960]f32
		end := st.end
		eff_end := max(start, min(end, EFF_EBANDS))
		decay: f32 = loss_count == 0 ? 1.5 : 0.5
		for c in 0 ..< C {
			for i in start ..< end {
				st.old_band_e[c * NB_EBANDS + i] = max(st.background_log_e[c * NB_EBANDS + i], st.old_band_e[c * NB_EBANDS + i] - decay)
			}
		}
		seed := st.rng
		for c in 0 ..< C {
			for i in start ..< eff_end {
				boffs := n * c + (int(eband5ms[i]) << uint(LM))
				blen := int(eband5ms[i + 1] - eband5ms[i]) << uint(LM)
				for j in 0 ..< blen {
					seed = celt_lcg_rand(seed)
					X[boffs + j] = f32(i32(seed) >> 20)
				}
				renormalise_vector(X[boffs:], blen, 1)
			}
		}
		st.rng = seed
		for c in 0 ..< C {
			dm := st.decode_mem[c][:]
			copy(dm[0:DECODE_BUFFER_SIZE - n + (OVERLAP >> 1)], dm[n:n + DECODE_BUFFER_SIZE - n + (OVERLAP >> 1)])
		}
		celt_synthesis(X[:], out_syn, st.old_band_e[:], start, eff_end, C, C, false, LM, st.downsample, false)
	} else {
		fade: f32 = 1
		pitch_index: int
		if loss_count == 0 {
			pitch_index = plc_pitch_search(st, C)
			st.last_pitch_index = pitch_index
		} else {
			pitch_index = st.last_pitch_index
			fade = 0.8
		}
		exc_length := min(2 * pitch_index, MAX_PERIOD)
		etmp: [OVERLAP]f32
		exc_buf: [MAX_PERIOD + LPC_ORDER]f32
		fir_tmp: [MAX_PERIOD]f32
		for c in 0 ..< C {
			buf := st.decode_mem[c][:]
			for i in 0 ..< MAX_PERIOD + LPC_ORDER do exc_buf[i] = buf[DECODE_BUFFER_SIZE - MAX_PERIOD - LPC_ORDER + i]
			exc := exc_buf[LPC_ORDER:]
			if loss_count == 0 {
				ac: [LPC_ORDER + 1]f32
				celt_autocorr(exc, ac[:], window120[:], OVERLAP, LPC_ORDER, MAX_PERIOD)
				ac[0] *= 1.0001
				for i in 1 ..= LPC_ORDER do ac[i] -= ac[i] * (0.008 * 0.008) * f32(i) * f32(i)
				celt_lpc(st.lpc[c][:], ac[:], LPC_ORDER)
			}
			celt_fir(exc_buf[:], LPC_ORDER + MAX_PERIOD - exc_length, st.lpc[c][:], fir_tmp[:], exc_length, LPC_ORDER)
			copy(exc[MAX_PERIOD - exc_length:MAX_PERIOD], fir_tmp[:exc_length])
			decay: f32
			{
				e1, e2: f32 = 1, 1
				decay_length := exc_length >> 1
				for i in 0 ..< decay_length {
					e := exc[MAX_PERIOD - decay_length + i]
					e1 += e * e
					e = exc[MAX_PERIOD - 2 * decay_length + i]
					e2 += e * e
				}
				e1 = min(e1, e2)
				decay = celt_sqrt(e1 / e2)
			}
			copy(buf[0:DECODE_BUFFER_SIZE - n], buf[n:DECODE_BUFFER_SIZE])
			extrapolation_offset := MAX_PERIOD - pitch_index
			extrapolation_len := n + OVERLAP
			attenuation := fade * decay
			s1: f32 = 0
			j := 0
			for i in 0 ..< extrapolation_len {
				if j >= pitch_index {
					j -= pitch_index
					attenuation = attenuation * decay
				}
				buf[DECODE_BUFFER_SIZE - n + i] = attenuation * exc[extrapolation_offset + j]
				tmp := buf[DECODE_BUFFER_SIZE - MAX_PERIOD - n + extrapolation_offset + j]
				s1 += tmp * tmp
				j += 1
			}
			{
				lpc_mem: [LPC_ORDER]f32
				for i in 0 ..< LPC_ORDER do lpc_mem[i] = buf[DECODE_BUFFER_SIZE - n - 1 - i]
				seg := buf[DECODE_BUFFER_SIZE - n:DECODE_BUFFER_SIZE - n + extrapolation_len]
				celt_iir(seg, st.lpc[c][:], seg, extrapolation_len, LPC_ORDER, lpc_mem[:])
			}
			{
				s2: f32 = 0
				for i in 0 ..< extrapolation_len {
					tmp := buf[DECODE_BUFFER_SIZE - n + i]
					s2 += tmp * tmp
				}
				if !(s1 > 0.2 * s2) {
					for i in 0 ..< extrapolation_len do buf[DECODE_BUFFER_SIZE - n + i] = 0
				} else if s1 < s2 {
					ratio := celt_sqrt((s1 + 1) / (s2 + 1)) // SHR32 is identity in the float build
					for i in 0 ..< OVERLAP {
						tmp_g := 1 - window120[i] * (1 - ratio)
						buf[DECODE_BUFFER_SIZE - n + i] = tmp_g * buf[DECODE_BUFFER_SIZE - n + i]
					}
					for i in OVERLAP ..< extrapolation_len do buf[DECODE_BUFFER_SIZE - n + i] = ratio * buf[DECODE_BUFFER_SIZE - n + i]
				}
			}
			comb_filter(etmp[:], 0, buf, DECODE_BUFFER_SIZE, st.postfilter_period, st.postfilter_period, OVERLAP, -st.postfilter_gain, -st.postfilter_gain,
				st.postfilter_tapset, st.postfilter_tapset, 0)
			for i in 0 ..< OVERLAP / 2 {
				buf[DECODE_BUFFER_SIZE + i] = window120[i] * etmp[OVERLAP - 1 - i] + window120[OVERLAP - i - 1] * etmp[i]
			}
		}
	}
	st.loss_count = loss_count + 1
}

Celt_Error :: enum {None, Bad_Arg, Internal, Invalid_Packet}

// Decodes one CELT frame of `frame_size` samples per channel (at the decoder's
// output rate) into interleaved pcm. data == nil -> PLC. dec != nil: continue
// an existing range decoder (hybrid mode).
celt_decode_with_ec :: proc(st: ^Celt_Decoder, data: []u8, pcm: []f32, frame_size_: int, dec_: ^Range) -> (int, Celt_Error) {
	CC := st.channels
	C := st.stream_channels
	start := st.start
	end := st.end
	frame_size := frame_size_ * st.downsample
	LM := 0
	for ; LM <= MAX_LM; LM += 1 do if SHORT_MDCT_SIZE << uint(LM) == frame_size do break
	if LM > MAX_LM do return 0, .Bad_Arg
	M := 1 << uint(LM)
	if len(data) > 1275 do return 0, .Bad_Arg
	n := M * SHORT_MDCT_SIZE
	out_syn: [2][]f32
	for c in 0 ..< CC do out_syn[c] = st.decode_mem[c][DECODE_BUFFER_SIZE - n:]
	eff_end := min(end, EFF_EBANDS)
	if data == nil || len(data) <= 1 {
		celt_decode_lost(st, n, LM)
		deemphasis(out_syn, pcm, n, CC, st.downsample, &st.preemph_mem_d)
		return frame_size / st.downsample, .None
	}
	st.skip_plc = st.loss_count != 0
	_dec: Range
	dec := dec_
	if dec == nil {
		ec_dec_init(&_dec, data)
		dec = &_dec
	}
	if C == 1 {
		for i in 0 ..< NB_EBANDS do st.old_band_e[i] = max(st.old_band_e[i], st.old_band_e[NB_EBANDS + i])
	}
	total_bits := i32(len(data) * 8)
	tell := ec_tell(dec)
	silence := false
	if tell >= total_bits {
		silence = true
	} else if tell == 1 {
		silence = ec_dec_bit_logp(dec, 15)
	}
	if silence {
		tell = i32(len(data) * 8)
		dec.nbits_total += tell - ec_tell(dec)
	}
	postfilter_gain: f32 = 0
	postfilter_pitch := 0
	postfilter_tapset := 0
	if start == 0 && tell + 16 <= total_bits {
		if ec_dec_bit_logp(dec, 1) {
			octave := ec_dec_uint(dec, 6)
			postfilter_pitch = int((u32(16) << octave) + ec_dec_bits(dec, 4 + octave)) - 1
			qg := ec_dec_bits(dec, 3)
			if ec_tell(dec) + 2 <= total_bits do postfilter_tapset = int(ec_dec_icdf(dec, tapset_icdf[:], 2))
			postfilter_gain = 0.09375 * f32(qg + 1)
		}
		tell = ec_tell(dec)
	}
	is_transient := false
	if LM > 0 && tell + 3 <= total_bits {
		is_transient = ec_dec_bit_logp(dec, 3)
		tell = ec_tell(dec)
	}
	short_blocks := is_transient
	intra_ener := tell + 3 <= total_bits ? ec_dec_bit_logp(dec, 3) : false
	unquant_coarse_energy(i32(start), i32(end), st.old_band_e[:], intra_ener, dec, i32(C), i32(LM))
	tf_res: [NB_EBANDS]i32
	tf_decode(start, end, is_transient, tf_res[:], LM, dec)
	tell = ec_tell(dec)
	spread_decision := SPREAD_NORMAL
	if tell + 4 <= total_bits do spread_decision = int(ec_dec_icdf(dec, spread_icdf[:], 5))
	cap: [NB_EBANDS]i32
	init_caps(cap[:], i32(LM), i32(C))
	offsets: [NB_EBANDS]i32
	dynalloc_logp: i32 = 6
	total_bits <<= BITRES
	tellf := i32(ec_tell_frac(dec))
	for i in start ..< end {
		width := i32(C) * i32(eband5ms[i + 1] - eband5ms[i]) << uint(LM)
		quanta := min(width << BITRES, max(6 << BITRES, width))
		dynalloc_loop_logp := dynalloc_logp
		boost: i32 = 0
		for tellf + (dynalloc_loop_logp << BITRES) < total_bits && boost < cap[i] {
			flag := ec_dec_bit_logp(dec, u32(dynalloc_loop_logp))
			tellf = i32(ec_tell_frac(dec))
			if !flag do break
			boost += quanta
			total_bits -= quanta
			dynalloc_loop_logp = 1
		}
		offsets[i] = boost
		if boost > 0 do dynalloc_logp = max(2, dynalloc_logp - 1)
	}
	fine_quant: [NB_EBANDS]i32
	alloc_trim: i32 = tellf + (6 << BITRES) <= total_bits ? ec_dec_icdf(dec, trim_icdf[:], 7) : 5
	bits := (i32(len(data) * 8) << BITRES) - i32(ec_tell_frac(dec)) - 1
	anti_collapse_rsv: i32 = is_transient && LM >= 2 && bits >= i32(LM + 2) << BITRES ? 1 << BITRES : 0
	bits -= anti_collapse_rsv
	pulses, fine_priority: [NB_EBANDS]i32
	intensity, dual_stereo, balance: i32
	coded_bands := clt_compute_allocation(i32(start), i32(end), offsets[:], cap[:], alloc_trim, &intensity, &dual_stereo, bits, &balance, pulses[:],
		fine_quant[:], fine_priority[:], i32(C), i32(LM), dec, false, 0, 0)
	unquant_fine_energy(i32(start), i32(end), st.old_band_e[:], fine_quant[:], dec, i32(C))
	for c in 0 ..< CC {
		dm := st.decode_mem[c][:]
		cnt := DECODE_BUFFER_SIZE - n + OVERLAP / 2
		copy(dm[0:cnt], dm[n:n + cnt])
	}
	collapse_masks: [2 * NB_EBANDS]u8
	X: [2 * 960]f32
	y_: []f32 = C == 2 ? X[n:] : nil
	quant_all_bands(false, start, end, X[:], y_, collapse_masks[:], nil, pulses[:], short_blocks, spread_decision, dual_stereo != 0, int(intensity),
		tf_res[:], i32(len(data)) * (8 << BITRES) - anti_collapse_rsv, balance, dec, LM, int(coded_bands), &st.rng, 0, st.disable_inv)
	anti_collapse_on := false
	if anti_collapse_rsv > 0 do anti_collapse_on = ec_dec_bits(dec, 1) != 0
	unquant_energy_finalise(i32(start), i32(end), st.old_band_e[:], fine_quant[:], fine_priority[:], i32(len(data) * 8) - ec_tell(dec), dec, i32(C))
	if anti_collapse_on {
		anti_collapse(X[:], collapse_masks[:], LM, C, n, start, end, st.old_band_e[:], st.old_log_e[:], st.old_log_e2[:], pulses[:], st.rng)
	}
	if silence {
		for i in 0 ..< C * NB_EBANDS do st.old_band_e[i] = -28
	}
	celt_synthesis(X[:], out_syn, st.old_band_e[:], start, eff_end, C, CC, is_transient, LM, st.downsample, silence)
	for c in 0 ..< CC {
		st.postfilter_period = max(st.postfilter_period, COMBFILTER_MINPERIOD)
		st.postfilter_period_old = max(st.postfilter_period_old, COMBFILTER_MINPERIOD)
		buf := st.decode_mem[c][:]
		o := DECODE_BUFFER_SIZE - n
		comb_filter(buf, o, buf, o, st.postfilter_period_old, st.postfilter_period, SHORT_MDCT_SIZE, st.postfilter_gain_old, st.postfilter_gain,
			st.postfilter_tapset_old, st.postfilter_tapset, OVERLAP)
		if LM != 0 {
			comb_filter(buf, o + SHORT_MDCT_SIZE, buf, o + SHORT_MDCT_SIZE, st.postfilter_period, postfilter_pitch, n - SHORT_MDCT_SIZE, st.postfilter_gain,
				postfilter_gain, st.postfilter_tapset, postfilter_tapset, OVERLAP)
		}
	}
	st.postfilter_period_old = st.postfilter_period
	st.postfilter_gain_old = st.postfilter_gain
	st.postfilter_tapset_old = st.postfilter_tapset
	st.postfilter_period = postfilter_pitch
	st.postfilter_gain = postfilter_gain
	st.postfilter_tapset = postfilter_tapset
	if LM != 0 {
		st.postfilter_period_old = st.postfilter_period
		st.postfilter_gain_old = st.postfilter_gain
		st.postfilter_tapset_old = st.postfilter_tapset
	}
	if C == 1 do copy(st.old_band_e[NB_EBANDS:], st.old_band_e[:NB_EBANDS])
	if !is_transient {
		copy(st.old_log_e2[:], st.old_log_e[:])
		copy(st.old_log_e[:], st.old_band_e[:])
		max_background_increase: f32 = st.loss_count < 10 ? f32(M) * 0.001 : 1
		for i in 0 ..< 2 * NB_EBANDS do st.background_log_e[i] = min(st.background_log_e[i] + max_background_increase, st.old_band_e[i])
	} else {
		for i in 0 ..< 2 * NB_EBANDS do st.old_log_e[i] = min(st.old_log_e[i], st.old_band_e[i])
	}
	for c in 0 ..< 2 {
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
	st.rng = dec.rng
	deemphasis(out_syn, pcm, n, CC, st.downsample, &st.preemph_mem_d)
	st.loss_count = 0
	if ec_tell(dec) > 8 * i32(len(data)) do return 0, .Internal
	if dec.error != 0 do st.error = true
	return frame_size / st.downsample, .None
}
