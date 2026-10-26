package opus

// Port of libopus 1.3.1 src/analysis.c (float build; BSD, see range.odin):
// tonality / speech-music / activity / bandwidth analysis driving the
// encoder's mode and bandwidth decisions.

import "core:math"

LEAK_BANDS :: 19
ANALYSIS_NB_FRAMES :: 8
ANALYSIS_NB_TBANDS :: 18
ANALYSIS_BUF_SIZE :: 720 // 30 ms at 24 kHz
ANALYSIS_COUNT_MAX :: 10000
ANALYSIS_DETECT_SIZE :: 100
ANALYSIS_TRANSITION_PENALTY :: 10
ANALYSIS_NB_TONAL_SKIP_BANDS :: 9
ANALYSIS_LEAKAGE_OFFSET :: f32(2.5)
ANALYSIS_LEAKAGE_SLOPE :: f32(2)

Analysis_Info :: struct {
	valid:                bool,
	tonality:             f32,
	tonality_slope:       f32,
	noisiness:            f32,
	activity:             f32,
	music_prob:           f32,
	music_prob_min:       f32,
	music_prob_max:       f32,
	bandwidth:            int,
	activity_probability: f32,
	max_pitch_ratio:      f32,
	leak_boost:           [LEAK_BANDS]u8, // Q6
}

Tonality_Analysis_State :: struct {
	fs:                  i32,
	angle:               [240]f32,
	d_angle:             [240]f32,
	d2_angle:            [240]f32,
	inmem:               [ANALYSIS_BUF_SIZE]f32,
	mem_fill:            int,
	prev_band_tonality:  [ANALYSIS_NB_TBANDS]f32,
	prev_tonality:       f32,
	prev_bandwidth:      int,
	E:                   [ANALYSIS_NB_FRAMES][ANALYSIS_NB_TBANDS]f32,
	logE:                [ANALYSIS_NB_FRAMES][ANALYSIS_NB_TBANDS]f32,
	lowE:                [ANALYSIS_NB_TBANDS]f32,
	highE:               [ANALYSIS_NB_TBANDS]f32,
	meanE:               [ANALYSIS_NB_TBANDS + 1]f32,
	mem:                 [32]f32,
	cmean:               [8]f32,
	std:                 [9]f32,
	Etracker:            f32,
	lowECount:           f32,
	E_count:             int,
	count:               int,
	analysis_offset:     int,
	write_pos:           int,
	read_pos:            int,
	read_subframe:       int,
	hp_ener_accum:       f32,
	initialized:         bool,
	rnn_state:           [MLP_MAX_NEURONS]f32,
	downmix_state:       [3]f32,
	info:                [ANALYSIS_DETECT_SIZE]Analysis_Info,
}

@(rodata)
analysis_tbands := [ANALYSIS_NB_TBANDS + 1]int{4, 8, 12, 16, 20, 24, 28, 32, 40, 48, 56, 64, 80, 96, 112, 136, 160, 192, 240}

@(rodata)
analysis_dct_table := [128]f32{
	0.250000, 0.250000, 0.250000, 0.250000, 0.250000, 0.250000, 0.250000, 0.250000,
	0.250000, 0.250000, 0.250000, 0.250000, 0.250000, 0.250000, 0.250000, 0.250000,
	0.351851, 0.338330, 0.311806, 0.273300, 0.224292, 0.166664, 0.102631, 0.034654,
	-0.034654, -0.102631, -0.166664, -0.224292, -0.273300, -0.311806, -0.338330, -0.351851,
	0.346760, 0.293969, 0.196424, 0.068975, -0.068975, -0.196424, -0.293969, -0.346760,
	-0.346760, -0.293969, -0.196424, -0.068975, 0.068975, 0.196424, 0.293969, 0.346760,
	0.338330, 0.224292, 0.034654, -0.166664, -0.311806, -0.351851, -0.273300, -0.102631,
	0.102631, 0.273300, 0.351851, 0.311806, 0.166664, -0.034654, -0.224292, -0.338330,
	0.326641, 0.135299, -0.135299, -0.326641, -0.326641, -0.135299, 0.135299, 0.326641,
	0.326641, 0.135299, -0.135299, -0.326641, -0.326641, -0.135299, 0.135299, 0.326641,
	0.311806, 0.034654, -0.273300, -0.338330, -0.102631, 0.224292, 0.351851, 0.166664,
	-0.166664, -0.351851, -0.224292, 0.102631, 0.338330, 0.273300, -0.034654, -0.311806,
	0.293969, -0.068975, -0.346760, -0.196424, 0.196424, 0.346760, 0.068975, -0.293969,
	-0.293969, 0.068975, 0.346760, 0.196424, -0.196424, -0.346760, -0.068975, 0.293969,
	0.273300, -0.166664, -0.338330, 0.034654, 0.351851, 0.102631, -0.311806, -0.224292,
	0.224292, 0.311806, -0.102631, -0.351851, -0.034654, 0.338330, 0.166664, -0.273300,
}

@(rodata)
analysis_window := [240]f32{
	0.000043, 0.000171, 0.000385, 0.000685, 0.001071, 0.001541, 0.002098, 0.002739,
	0.003466, 0.004278, 0.005174, 0.006156, 0.007222, 0.008373, 0.009607, 0.010926,
	0.012329, 0.013815, 0.015385, 0.017037, 0.018772, 0.020590, 0.022490, 0.024472,
	0.026535, 0.028679, 0.030904, 0.033210, 0.035595, 0.038060, 0.040604, 0.043227,
	0.045928, 0.048707, 0.051564, 0.054497, 0.057506, 0.060591, 0.063752, 0.066987,
	0.070297, 0.073680, 0.077136, 0.080665, 0.084265, 0.087937, 0.091679, 0.095492,
	0.099373, 0.103323, 0.107342, 0.111427, 0.115579, 0.119797, 0.124080, 0.128428,
	0.132839, 0.137313, 0.141849, 0.146447, 0.151105, 0.155823, 0.160600, 0.165435,
	0.170327, 0.175276, 0.180280, 0.185340, 0.190453, 0.195619, 0.200838, 0.206107,
	0.211427, 0.216797, 0.222215, 0.227680, 0.233193, 0.238751, 0.244353, 0.250000,
	0.255689, 0.261421, 0.267193, 0.273005, 0.278856, 0.284744, 0.290670, 0.296632,
	0.302628, 0.308658, 0.314721, 0.320816, 0.326941, 0.333097, 0.339280, 0.345492,
	0.351729, 0.357992, 0.364280, 0.370590, 0.376923, 0.383277, 0.389651, 0.396044,
	0.402455, 0.408882, 0.415325, 0.421783, 0.428254, 0.434737, 0.441231, 0.447736,
	0.454249, 0.460770, 0.467298, 0.473832, 0.480370, 0.486912, 0.493455, 0.500000,
	0.506545, 0.513088, 0.519630, 0.526168, 0.532702, 0.539230, 0.545751, 0.552264,
	0.558769, 0.565263, 0.571746, 0.578217, 0.584675, 0.591118, 0.597545, 0.603956,
	0.610349, 0.616723, 0.623077, 0.629410, 0.635720, 0.642008, 0.648271, 0.654508,
	0.660720, 0.666903, 0.673059, 0.679184, 0.685279, 0.691342, 0.697372, 0.703368,
	0.709330, 0.715256, 0.721144, 0.726995, 0.732807, 0.738579, 0.744311, 0.750000,
	0.755647, 0.761249, 0.766807, 0.772320, 0.777785, 0.783203, 0.788573, 0.793893,
	0.799162, 0.804381, 0.809547, 0.814660, 0.819720, 0.824724, 0.829673, 0.834565,
	0.839400, 0.844177, 0.848895, 0.853553, 0.858151, 0.862687, 0.867161, 0.871572,
	0.875920, 0.880203, 0.884421, 0.888573, 0.892658, 0.896677, 0.900627, 0.904508,
	0.908321, 0.912063, 0.915735, 0.919335, 0.922864, 0.926320, 0.929703, 0.933013,
	0.936248, 0.939409, 0.942494, 0.945503, 0.948436, 0.951293, 0.954072, 0.956773,
	0.959396, 0.961940, 0.964405, 0.966790, 0.969096, 0.971321, 0.973465, 0.975528,
	0.977510, 0.979410, 0.981228, 0.982963, 0.984615, 0.986185, 0.987671, 0.989074,
	0.990393, 0.991627, 0.992778, 0.993844, 0.994826, 0.995722, 0.996534, 0.997261,
	0.997902, 0.998459, 0.998929, 0.999315, 0.999615, 0.999829, 0.999957, 1.000000,
}

@(rodata)
analysis_std_feature_bias := [9]f32{
	5.684947, 3.475288, 1.770634, 1.599784, 3.773215, 2.163313, 1.260756, 1.116868,
	1.918795,
}

@(private = "file")
M_PI :: 3.14159265358979323846

@(private = "file")
resampler_down2_hp :: proc "contextless" (S: ^[3]f32, out: []f32, in_: []f32, in_len: int) -> f32 {
	len2 := in_len / 2
	hp_ener := f32(0)
	for k in 0 ..< len2 {
		in32 := in_[2 * k]
		// All-pass section for even input sample
		Y := in32 - S[0]
		X := 0.6074371 * Y
		out32 := S[0] + X
		S[0] = in32 + X
		out32_hp := out32
		in32 = in_[2 * k + 1]
		// All-pass section for odd input sample
		Y = in32 - S[1]
		X = 0.15063 * Y
		out32 = out32 + S[1]
		out32 = out32 + X
		S[1] = in32 + X

		Y = -in32 - S[2]
		X = 0.15063 * Y
		out32_hp = out32_hp + S[2]
		out32_hp = out32_hp + X
		S[2] = -in32 + X

		hp_ener += out32_hp * out32_hp
		out[k] = 0.5 * out32
	}
	return hp_ener
}

// downmix_float from opus_encoder.c (PCM2VAL = x*32768 in the float build).
@(private = "file")
downmix_float :: proc "contextless" (x: []f32, y: []f32, subframe, offset, c1, c2, C: int) {
	for j in 0 ..< subframe do y[j] = 32768 * x[(j + offset) * C + c1]
	if c2 > -1 {
		for j in 0 ..< subframe do y[j] += 32768 * x[(j + offset) * C + c2]
	} else if c2 == -2 {
		for c in 1 ..< C {
			for j in 0 ..< subframe do y[j] += 32768 * x[(j + offset) * C + c]
		}
	}
}

@(private = "file")
downmix_and_resample :: proc "contextless" (x: []f32, y: []f32, S: ^[3]f32, subframe_, offset_, c1, c2, C: int, fs: i32) -> f32 {
	subframe, offset := subframe_, offset_
	if subframe == 0 do return 0
	if fs == 48000 {
		subframe *= 2
		offset *= 2
	} else if fs == 16000 {
		subframe = subframe * 2 / 3
		offset = offset * 2 / 3
	}
	tmp: [ANALYSIS_BUF_SIZE * 2]f32 // subframe <= 2*720 at 48 kHz
	downmix_float(x, tmp[:], subframe, offset, c1, c2, C)
	scale := f32(1.0 / 32768)
	if c2 == -2 {
		scale /= f32(C)
	} else if c2 > -1 {
		scale /= 2
	}
	for j in 0 ..< subframe do tmp[j] *= scale
	ret := f32(0)
	if fs == 48000 {
		ret = resampler_down2_hp(S, y, tmp[:], subframe)
	} else if fs == 24000 {
		copy(y[:subframe], tmp[:subframe])
	} else if fs == 16000 {
		// Crude 16 -> 48 -> 24 kHz path, as in libopus (aliasing above 8 kHz is ignored).
		tmp3x: [ANALYSIS_BUF_SIZE * 3]f32
		for j in 0 ..< subframe {
			tmp3x[3 * j] = tmp[j]
			tmp3x[3 * j + 1] = tmp[j]
			tmp3x[3 * j + 2] = tmp[j]
		}
		resampler_down2_hp(S, y, tmp3x[:], 3 * subframe)
	}
	return ret
}

tonality_analysis_init :: proc(st: ^Tonality_Analysis_State, fs: i32) {
	st.fs = fs
	tonality_analysis_reset(st)
}

tonality_analysis_reset :: proc(st: ^Tonality_Analysis_State) {
	fs := st.fs
	st^ = {}
	st.fs = fs
}

tonality_get_info :: proc(tonal: ^Tonality_Analysis_State, info_out: ^Analysis_Info, len: int) {
	pos := tonal.read_pos
	curr_lookahead := tonal.write_pos - tonal.read_pos
	if curr_lookahead < 0 do curr_lookahead += ANALYSIS_DETECT_SIZE

	tonal.read_subframe += len / int(tonal.fs / 400)
	for tonal.read_subframe >= 8 {
		tonal.read_subframe -= 8
		tonal.read_pos += 1
	}
	if tonal.read_pos >= ANALYSIS_DETECT_SIZE do tonal.read_pos -= ANALYSIS_DETECT_SIZE

	// On long frames, look at the second analysis window rather than the first.
	if len > int(tonal.fs / 50) && pos != tonal.write_pos {
		pos += 1
		if pos == ANALYSIS_DETECT_SIZE do pos = 0
	}
	if pos == tonal.write_pos do pos -= 1
	if pos < 0 do pos = ANALYSIS_DETECT_SIZE - 1
	pos0 := pos
	info_out^ = tonal.info[pos]
	if !info_out.valid do return
	tonality_max := info_out.tonality
	tonality_avg := info_out.tonality
	tonality_count := 1
	// Look at the neighbouring frames and pick largest bandwidth found (to be safe).
	bandwidth_span := 6
	// If possible, look ahead for a tone to compensate for the delay in the tone detector.
	for _ in 0 ..< 3 {
		pos += 1
		if pos == ANALYSIS_DETECT_SIZE do pos = 0
		if pos == tonal.write_pos do break
		tonality_max = max(tonality_max, tonal.info[pos].tonality)
		tonality_avg += tonal.info[pos].tonality
		tonality_count += 1
		info_out.bandwidth = max(info_out.bandwidth, tonal.info[pos].bandwidth)
		bandwidth_span -= 1
	}
	pos = pos0
	// Look back in time to see if any has a wider bandwidth than the current frame.
	for _ in 0 ..< bandwidth_span {
		pos -= 1
		if pos < 0 do pos = ANALYSIS_DETECT_SIZE - 1
		if pos == tonal.write_pos do break
		info_out.bandwidth = max(info_out.bandwidth, tonal.info[pos].bandwidth)
	}
	info_out.tonality = max(tonality_avg / f32(tonality_count), tonality_max - 0.2)

	mpos, vpos := pos0, pos0
	// With enough look-ahead, compensate for the ~5-frame music prob and ~1-frame VAD delay.
	if curr_lookahead > 15 {
		mpos += 5
		if mpos >= ANALYSIS_DETECT_SIZE do mpos -= ANALYSIS_DETECT_SIZE
		vpos += 1
		if vpos >= ANALYSIS_DETECT_SIZE do vpos -= ANALYSIS_DETECT_SIZE
	}

	// Minimum-badness switching thresholds (see the comment in libopus analysis.c).
	prob_min := f32(1)
	prob_max := f32(0)
	vad_prob := tonal.info[vpos].activity_probability
	prob_count := max(f32(0.1), vad_prob)
	prob_avg := max(f32(0.1), vad_prob) * tonal.info[mpos].music_prob
	for {
		mpos += 1
		if mpos == ANALYSIS_DETECT_SIZE do mpos = 0
		if mpos == tonal.write_pos do break
		vpos += 1
		if vpos == ANALYSIS_DETECT_SIZE do vpos = 0
		if vpos == tonal.write_pos do break
		pos_vad := tonal.info[vpos].activity_probability
		prob_min = min((prob_avg - ANALYSIS_TRANSITION_PENALTY * (vad_prob - pos_vad)) / prob_count, prob_min)
		prob_max = max((prob_avg + ANALYSIS_TRANSITION_PENALTY * (vad_prob - pos_vad)) / prob_count, prob_max)
		prob_count += max(f32(0.1), pos_vad)
		prob_avg += max(f32(0.1), pos_vad) * tonal.info[mpos].music_prob
	}
	info_out.music_prob = prob_avg / prob_count
	prob_min = min(prob_avg / prob_count, prob_min)
	prob_max = max(prob_avg / prob_count, prob_max)
	prob_min = max(prob_min, 0)
	prob_max = min(prob_max, 1)

	// If we don't have enough look-ahead, do our best to make a decent decision.
	if curr_lookahead < 10 {
		pmin := prob_min
		pmax := prob_max
		pos = pos0
		// Look for min/max in the past.
		for _ in 0 ..< min(tonal.count - 1, 15) {
			pos -= 1
			if pos < 0 do pos = ANALYSIS_DETECT_SIZE - 1
			pmin = min(pmin, tonal.info[pos].music_prob)
			pmax = max(pmax, tonal.info[pos].music_prob)
		}
		// Bias against switching on active audio.
		pmin = max(0, pmin - 0.1 * vad_prob)
		pmax = min(1, pmax + 0.1 * vad_prob)
		prob_min += (1 - 0.1 * f32(curr_lookahead)) * (pmin - prob_min)
		prob_max += (1 - 0.1 * f32(curr_lookahead)) * (pmax - prob_max)
	}
	info_out.music_prob_min = prob_min
	info_out.music_prob_max = prob_max
}

@(private = "file")
flog :: #force_inline proc "contextless" (x: f32) -> f32 {return f32(math.ln(f64(x)))}
@(private = "file")
fsqrt :: #force_inline proc "contextless" (x: f32) -> f32 {return f32(math.sqrt(f64(x)))}

@(private = "file")
binE_at :: #force_inline proc "contextless" (out: []Cpx, i, N: int) -> f32 {
	return out[i][0] * out[i][0] + out[N - i][0] * out[N - i][0] + out[i][1] * out[i][1] + out[N - i][1] * out[N - i][1]
}

@(private = "file")
tonality_analysis :: proc(tonal: ^Tonality_Analysis_State, x: []f32, len_, offset_, c1, c2, C, lsb_depth: int) {
	N :: 480
	N2 :: 240
	NB_TBANDS :: ANALYSIS_NB_TBANDS
	A := &tonal.angle
	dA := &tonal.d_angle
	d2A := &tonal.d2_angle
	tonality, noisiness, tonality2: [240]f32
	band_tonality: [NB_TBANDS]f32
	logE: [NB_TBANDS]f32
	BFCC, midE: [8]f32
	features: [25]f32
	frame_probs: [2]f32
	is_masked: [NB_TBANDS + 1]bool
	band_log2, leakage_from, leakage_to: [NB_TBANDS + 1]f32
	layer_out: [MLP_MAX_NEURONS]f32
	pi4 := f32(M_PI * M_PI * M_PI * M_PI)
	slope := f32(0)
	spec_variability := f32(0)
	len, offset := len_, offset_

	if !tonal.initialized {
		tonal.mem_fill = 240
		tonal.initialized = true
	}
	alpha := 1 / f32(min(10, 1 + tonal.count))
	alphaE := 1 / f32(min(25, 1 + tonal.count))
	// Noise floor related decay for bandwidth detection: -2.2 dB/second
	alphaE2 := 1 / f32(min(100, 1 + tonal.count))
	if tonal.count <= 1 do alphaE2 = 1

	if tonal.fs == 48000 {
		// len and offset are now at 24 kHz.
		len /= 2
		offset /= 2
	} else if tonal.fs == 16000 {
		len = 3 * len / 2
		offset = 3 * offset / 2
	}

	tonal.hp_ener_accum += downmix_and_resample(x, tonal.inmem[tonal.mem_fill:], &tonal.downmix_state,
		min(len, ANALYSIS_BUF_SIZE - tonal.mem_fill), offset, c1, c2, C, tonal.fs)
	if tonal.mem_fill + len < ANALYSIS_BUF_SIZE {
		tonal.mem_fill += len
		return // not enough to update the analysis
	}
	hp_ener := tonal.hp_ener_accum
	info := &tonal.info[tonal.write_pos]
	tonal.write_pos += 1
	if tonal.write_pos >= ANALYSIS_DETECT_SIZE do tonal.write_pos -= ANALYSIS_DETECT_SIZE

	// is_digital_silence (float build) on the 24 kHz buffer
	is_silence := false
	{
		maxv, minv := f32(0), f32(0)
		for v in tonal.inmem {
			maxv = max(maxv, v)
			minv = min(minv, v)
		}
		is_silence = max(maxv, -minv) <= 1 / f32(i32(1) << uint(lsb_depth))
	}

	in_, out: [N]Cpx
	for i in 0 ..< N2 {
		w := analysis_window[i]
		in_[i][0] = w * tonal.inmem[i]
		in_[i][1] = w * tonal.inmem[N2 + i]
		in_[N - i - 1][0] = w * tonal.inmem[N - i - 1]
		in_[N - i - 1][1] = w * tonal.inmem[N + N2 - i - 1]
	}
	copy(tonal.inmem[:240], tonal.inmem[ANALYSIS_BUF_SIZE - 240:])
	remaining := len - (ANALYSIS_BUF_SIZE - tonal.mem_fill)
	tonal.hp_ener_accum = downmix_and_resample(x, tonal.inmem[240:], &tonal.downmix_state, remaining,
		offset + ANALYSIS_BUF_SIZE - tonal.mem_fill, c1, c2, C, tonal.fs)
	tonal.mem_fill = 240 + remaining
	if is_silence {
		// On silence, copy the previous analysis.
		prev_pos := tonal.write_pos - 2
		if prev_pos < 0 do prev_pos += ANALYSIS_DETECT_SIZE
		info^ = tonal.info[prev_pos]
		return
	}
	// opus_fft: scaled bit-reversed copy, then in-place kiss FFT (480-point state)
	fst := &fft_states[0]
	for i in 0 ..< N {
		r := int(fft_bitrev480[i])
		out[r][0] = fst.scale * in_[i][0]
		out[r][1] = fst.scale * in_[i][1]
	}
	opus_fft_impl(fst, out[:])
	// Any NaN on the input makes the whole output NaN.
	if out[0][0] != out[0][0] {
		info.valid = false
		return
	}

	for i in 1 ..< N2 {
		X1r := out[i][0] + out[N - i][0]
		X1i := out[i][1] - out[N - i][1]
		X2r := out[i][1] + out[N - i][1]
		X2i := out[N - i][0] - out[i][0]

		angle := f32(0.5 / M_PI) * fast_atan2f(X1i, X1r)
		d_angle := angle - A[i]
		d2_angle := d_angle - dA[i]

		angle2 := f32(0.5 / M_PI) * fast_atan2f(X2i, X2r)
		d_angle2 := angle2 - angle
		d2_angle2 := d_angle2 - d_angle

		mod1 := d2_angle - f32(float2int(d2_angle))
		noisiness[i] = abs(mod1)
		mod1 *= mod1
		mod1 *= mod1

		mod2 := d2_angle2 - f32(float2int(d2_angle2))
		noisiness[i] += abs(mod2)
		mod2 *= mod2
		mod2 *= mod2

		avg_mod := 0.25 * (d2A[i] + mod1 + 2 * mod2)
		// This introduces an extra delay of 2 frames in the detection.
		tonality[i] = 1 / (1 + 40 * 16 * pi4 * avg_mod) - 0.015
		// No delay on this detection, but it's less reliable.
		tonality2[i] = 1 / (1 + 40 * 16 * pi4 * mod2) - 0.015

		A[i] = angle2
		dA[i] = d_angle2
		d2A[i] = mod2
	}
	for i in 2 ..< N2 - 1 {
		tt := min(tonality2[i], max(tonality2[i - 1], tonality2[i + 1]))
		tonality[i] = 0.9 * max(tonality[i], tt - 0.1)
	}
	frame_tonality := f32(0)
	max_frame_tonality := f32(0)
	info.activity = 0
	frame_noisiness := f32(0)
	frame_stationarity := f32(0)
	if tonal.count == 0 {
		for b in 0 ..< NB_TBANDS {
			tonal.lowE[b] = 1e10
			tonal.highE[b] = -1e10
		}
	}
	relativeE := f32(0)
	frame_loudness := f32(0)
	// The energy of the very first band is special because of DC.
	{
		X1r := 2 * out[0][0]
		X2r := 2 * out[0][1]
		E := X1r * X1r + X2r * X2r
		for i in 1 ..< 4 do E += binE_at(out[:], i, N)
		band_log2[0] = 0.5 * 1.442695 * flog(E + 1e-10)
	}
	for b in 0 ..< NB_TBANDS {
		E, tE, nE := f32(0), f32(0), f32(0)
		for i in analysis_tbands[b] ..< analysis_tbands[b + 1] {
			binE := binE_at(out[:], i, N)
			E += binE
			tE += binE * max(0, tonality[i])
			nE += binE * 2 * (0.5 - noisiness[i])
		}
		// Check for extreme band energies that could cause NaNs later.
		if !(E < 1e9) || E != E {
			info.valid = false
			return
		}

		tonal.E[tonal.E_count][b] = E
		frame_noisiness += nE / (1e-15 + E)

		frame_loudness += fsqrt(E + 1e-10)
		logE[b] = flog(E + 1e-10)
		band_log2[b + 1] = 0.5 * 1.442695 * flog(E + 1e-10)
		tonal.logE[tonal.E_count][b] = logE[b]
		if tonal.count == 0 {
			tonal.lowE[b] = logE[b]
			tonal.highE[b] = logE[b]
		}
		if f64(tonal.highE[b]) > f64(tonal.lowE[b]) + 7.5 {
			if tonal.highE[b] - logE[b] > logE[b] - tonal.lowE[b] {
				tonal.highE[b] -= 0.01
			} else {
				tonal.lowE[b] += 0.01
			}
		}
		if logE[b] > tonal.highE[b] {
			tonal.highE[b] = logE[b]
			tonal.lowE[b] = max(tonal.highE[b] - 15, tonal.lowE[b])
		} else if logE[b] < tonal.lowE[b] {
			tonal.lowE[b] = logE[b]
			tonal.highE[b] = min(tonal.lowE[b] + 15, tonal.highE[b])
		}
		relativeE += (logE[b] - tonal.lowE[b]) / (1e-5 + (tonal.highE[b] - tonal.lowE[b]))

		L1, L2 := f32(0), f32(0)
		for i in 0 ..< ANALYSIS_NB_FRAMES {
			L1 += fsqrt(tonal.E[i][b])
			L2 += tonal.E[i][b]
		}

		stationarity := min(f32(0.99), L1 / f32(math.sqrt(1e-15 + f64(ANALYSIS_NB_FRAMES * L2))))
		stationarity *= stationarity
		stationarity *= stationarity
		frame_stationarity += stationarity
		band_tonality[b] = max(tE / (1e-15 + E), stationarity * tonal.prev_band_tonality[b])
		frame_tonality += band_tonality[b]
		if b >= NB_TBANDS - ANALYSIS_NB_TONAL_SKIP_BANDS {
			frame_tonality -= band_tonality[b - NB_TBANDS + ANALYSIS_NB_TONAL_SKIP_BANDS]
		}
		max_frame_tonality = max(max_frame_tonality, (1 + 0.03 * f32(b - NB_TBANDS)) * frame_tonality)
		slope += band_tonality[b] * f32(b - 8)
		tonal.prev_band_tonality[b] = band_tonality[b]
	}

	leakage_from[0] = band_log2[0]
	leakage_to[0] = band_log2[0] - ANALYSIS_LEAKAGE_OFFSET
	for b in 1 ..< NB_TBANDS + 1 {
		leak_slope := ANALYSIS_LEAKAGE_SLOPE * f32(analysis_tbands[b] - analysis_tbands[b - 1]) / 4
		leakage_from[b] = min(leakage_from[b - 1] + leak_slope, band_log2[b])
		leakage_to[b] = max(leakage_to[b - 1] - leak_slope, band_log2[b] - ANALYSIS_LEAKAGE_OFFSET)
	}
	for b := NB_TBANDS - 2; b >= 0; b -= 1 {
		leak_slope := ANALYSIS_LEAKAGE_SLOPE * f32(analysis_tbands[b + 1] - analysis_tbands[b]) / 4
		leakage_from[b] = min(leakage_from[b + 1] + leak_slope, leakage_from[b])
		leakage_to[b] = max(leakage_to[b + 1] - leak_slope, leakage_to[b])
	}
	for b in 0 ..< NB_TBANDS + 1 {
		// Boost for analysis leakage from louder neighbours, plus synthesis leakage from loud bands.
		boost := max(0, leakage_to[b] - band_log2[b]) + max(0, band_log2[b] - (leakage_from[b] + ANALYSIS_LEAKAGE_OFFSET))
		info.leak_boost[b] = u8(min(255, int(math.floor(0.5 + f64(64 * boost)))))
	}

	for i in 0 ..< ANALYSIS_NB_FRAMES {
		mindist := f32(1e15)
		for j in 0 ..< ANALYSIS_NB_FRAMES {
			dist := f32(0)
			for k in 0 ..< NB_TBANDS {
				tmp := tonal.logE[i][k] - tonal.logE[j][k]
				dist += tmp * tmp
			}
			if j != i do mindist = min(mindist, dist)
		}
		spec_variability += mindist
	}
	spec_variability = fsqrt(spec_variability / ANALYSIS_NB_FRAMES / NB_TBANDS)
	bandwidth_mask := f32(0)
	bandwidth := 0
	maxE := f32(0)
	noise_floor := 5.7e-4 / f32(i32(1) << uint(max(0, lsb_depth - 8)))
	noise_floor *= noise_floor
	below_max_pitch := f32(0)
	above_max_pitch := f32(0)
	b := 0
	for ; b < NB_TBANDS; b += 1 {
		E := f32(0)
		band_start := analysis_tbands[b]
		band_end := analysis_tbands[b + 1]
		for i in band_start ..< band_end do E += binE_at(out[:], i, N)
		maxE = max(maxE, E)
		if band_start < 64 {
			below_max_pitch += E
		} else {
			above_max_pitch += E
		}
		tonal.meanE[b] = max((1 - alphaE2) * tonal.meanE[b], E)
		Em := max(E, tonal.meanE[b])
		// "Active" if < 90 dB below the peak band and above the PCM quantization noise floor.
		if E * 1e9 > maxE && (Em > 3 * noise_floor * f32(band_end - band_start) || E > noise_floor * f32(band_end - band_start)) {
			bandwidth = b + 1
		}
		is_masked[b] = E < (tonal.prev_bandwidth >= b + 1 ? f32(0.01) : f32(0.05)) * bandwidth_mask
		// Simple follower with 13 dB/Bark slope for the spreading function.
		bandwidth_mask = max(0.05 * bandwidth_mask, E)
	}
	// The last two bands only have the HP energy above 12 kHz.
	if tonal.fs == 48000 {
		E := hp_ener * (1.0 / (60 * 60))
		noise_ratio := tonal.prev_bandwidth == 20 ? f32(10) : f32(30)
		above_max_pitch += E
		tonal.meanE[b] = max((1 - alphaE2) * tonal.meanE[b], E)
		Em := max(E, tonal.meanE[b])
		if Em > 3 * noise_ratio * noise_floor * 160 || E > noise_ratio * noise_floor * 160 do bandwidth = 20
		is_masked[b] = E < (tonal.prev_bandwidth == 20 ? f32(0.01) : f32(0.05)) * bandwidth_mask
	}
	if above_max_pitch > below_max_pitch {
		info.max_pitch_ratio = below_max_pitch / above_max_pitch
	} else {
		info.max_pitch_ratio = 1
	}
	// Resampling aliasing can leave a little energy in the first cut band; drop it if masked.
	if bandwidth == 20 && is_masked[NB_TBANDS] {
		bandwidth -= 2
	} else if bandwidth > 0 && bandwidth <= NB_TBANDS && is_masked[bandwidth - 1] {
		bandwidth -= 1
	}
	if tonal.count <= 2 do bandwidth = 20
	frame_loudness = 20 * f32(math.log10(f64(frame_loudness)))
	tonal.Etracker = max(tonal.Etracker - 0.003, frame_loudness)
	tonal.lowECount *= (1 - alphaE)
	if frame_loudness < tonal.Etracker - 30 do tonal.lowECount += alphaE

	for i in 0 ..< 8 {
		sum := f32(0)
		for bb in 0 ..< 16 do sum += analysis_dct_table[i * 16 + bb] * logE[bb]
		BFCC[i] = sum
	}
	for i in 0 ..< 8 {
		sum := f32(0)
		for bb in 0 ..< 16 do sum += analysis_dct_table[i * 16 + bb] * 0.5 * (tonal.highE[bb] + tonal.lowE[bb])
		midE[i] = sum
	}

	frame_stationarity /= NB_TBANDS
	relativeE /= NB_TBANDS
	if tonal.count < 10 do relativeE = 0.5
	frame_noisiness /= NB_TBANDS
	info.activity = frame_noisiness + (1 - frame_noisiness) * relativeE
	frame_tonality = (max_frame_tonality / (NB_TBANDS - ANALYSIS_NB_TONAL_SKIP_BANDS))
	frame_tonality = max(frame_tonality, tonal.prev_tonality * 0.8)
	tonal.prev_tonality = frame_tonality

	slope /= 8 * 8
	info.tonality_slope = slope

	tonal.E_count = (tonal.E_count + 1) % ANALYSIS_NB_FRAMES
	tonal.count = min(tonal.count + 1, ANALYSIS_COUNT_MAX)
	info.tonality = frame_tonality

	mem := &tonal.mem
	for i in 0 ..< 4 {
		features[i] = -0.12299 * (BFCC[i] + mem[i + 24]) + 0.49195 * (mem[i] + mem[i + 16]) + 0.69693 * mem[i + 8] - 1.4349 * tonal.cmean[i]
	}
	for i in 0 ..< 4 do tonal.cmean[i] = (1 - alpha) * tonal.cmean[i] + alpha * BFCC[i]
	for i in 0 ..< 4 do features[4 + i] = 0.63246 * (BFCC[i] - mem[i + 24]) + 0.31623 * (mem[i] - mem[i + 16])
	for i in 0 ..< 3 do features[8 + i] = 0.53452 * (BFCC[i] + mem[i + 24]) - 0.26726 * (mem[i] + mem[i + 16]) - 0.53452 * mem[i + 8]

	if tonal.count > 5 {
		for i in 0 ..< 9 do tonal.std[i] = (1 - alpha) * tonal.std[i] + alpha * features[i] * features[i]
	}
	for i in 0 ..< 4 do features[i] = BFCC[i] - midE[i]

	for i in 0 ..< 8 {
		mem[i + 24] = mem[i + 16]
		mem[i + 16] = mem[i + 8]
		mem[i + 8] = mem[i]
		mem[i] = BFCC[i]
	}
	for i in 0 ..< 9 do features[11 + i] = fsqrt(tonal.std[i]) - analysis_std_feature_bias[i]
	features[18] = spec_variability - 0.78
	features[20] = info.tonality - 0.154723
	features[21] = info.activity - 0.724643
	features[22] = frame_stationarity - 0.743717
	features[23] = info.tonality_slope + 0.069216
	features[24] = tonal.lowECount - 0.067930

	l0 := mlp_layer0()
	l1 := mlp_layer1()
	l2 := mlp_layer2()
	mlp_compute_dense(&l0, layer_out[:], features[:])
	mlp_compute_gru(&l1, tonal.rnn_state[:], layer_out[:])
	mlp_compute_dense(&l2, frame_probs[:], tonal.rnn_state[:])

	// Probability of speech or music vs noise
	info.activity_probability = frame_probs[1]
	info.music_prob = frame_probs[0]

	info.bandwidth = bandwidth
	tonal.prev_bandwidth = bandwidth
	info.noisiness = frame_noisiness
	info.valid = true
}

run_analysis :: proc(st: ^Tonality_Analysis_State, analysis_pcm: []f32, analysis_frame_size_, frame_size, c1, c2, C: int, fs: i32, lsb_depth: int, info: ^Analysis_Info) {
	analysis_frame_size := analysis_frame_size_
	analysis_frame_size -= analysis_frame_size & 1
	if analysis_pcm != nil {
		f50 := int(fs / 50)
		// Avoid overflow/wrap-around of the analysis buffer
		analysis_frame_size = min((ANALYSIS_DETECT_SIZE - 5) * int(fs) / 50, analysis_frame_size)
		pcm_len := analysis_frame_size - st.analysis_offset
		offset := st.analysis_offset
		for pcm_len > 0 {
			tonality_analysis(st, analysis_pcm, min(f50, pcm_len), offset, c1, c2, C, lsb_depth)
			offset += f50
			pcm_len -= f50
		}
		st.analysis_offset = analysis_frame_size
		st.analysis_offset -= frame_size
	}
	tonality_get_info(st, info, frame_size)
}
