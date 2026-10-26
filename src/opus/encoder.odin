package opus

// Opus encoder (opus_encoder.c, float build): SILK, hybrid and CELT modes with
// libopus's mode/bandwidth/channel decisions, tonality analysis, in-band FEC
// (LBRR), DTX, mode-transition redundancy, VBR/CVBR/CBR, 2.5–120 ms frames.
// Input is 48 kHz (other API rates are not wired up: CELT and the SILK
// resampler paths are only ported for 48 kHz).

import "core:math"

Application :: enum {
	VOIP,
	Audio,
	Restricted_Lowdelay,
}

OPUS_AUTO :: -1000
OPUS_BITRATE_MAX :: -1
SIGNAL_VOICE :: 3001
SIGNAL_MUSIC :: 3002

@(private = "file")
MAX_ENCODER_BUFFER :: 480
@(private = "file")
PSEUDO_SNR_THRESHOLD :: f32(316.23)
@(private = "file")
DTX_ACTIVITY_THRESHOLD :: f32(0.1)
@(private = "file")
NB_SPEECH_FRAMES_BEFORE_DTX :: 10
@(private = "file")
MAX_CONSECUTIVE_DTX :: 20
@(private = "file")
VAD_NO_DECISION :: -1
@(private = "file")
VARIABLE_HP_MIN_CUTOFF_HZ :: 60
@(private = "file")
VARIABLE_HP_SMTH_COEF2 :: 0.015

Stereo_Width_State :: struct {
	XX, XY, YY:     f32,
	smoothed_width: f32,
	max_follower:   f32,
}

Encoder :: struct {
	celt:                    Celt_Encoder,
	silk:                    Silk_Encoder,
	silk_mode:               Silk_Enc_Control,
	analysis:                Tonality_Analysis_State,
	application:             Application,
	fs:                      int,
	channels:                int,
	delay_compensation:      int,
	force_channels:          int,
	signal_type:             int,
	user_bandwidth:          int,
	max_bandwidth:           int,
	user_forced_mode:        int,
	voice_ratio:             int,
	use_vbr:                 bool,
	vbr_constraint:          bool,
	bitrate_bps:             int,
	user_bitrate_bps:        int,
	lsb_depth:               int,
	encoder_buffer:          int,
	use_dtx:                 bool,
	// cleared on reset
	stream_channels:         int,
	hybrid_stereo_width_q14: i32,
	variable_hp_smth2_q15:   i32,
	prev_hb_gain:            f32,
	hp_mem:                  [4]f32,
	mode:                    int,
	prev_mode:               int,
	prev_channels:           int,
	prev_framesize:          int,
	bandwidth:               int,
	auto_bandwidth:          int,
	silk_bw_switch:          bool,
	first:                   bool,
	width_mem:               Stereo_Width_State,
	delay_buffer:            [MAX_ENCODER_BUFFER * 2]f32,
	detected_bandwidth:      int,
	nb_no_activity_frames:   int,
	peak_signal_energy:      f32,
	nonfinal_frame:          bool,
	range_final:             u32,
}

@(private = "file", rodata)
mono_voice_bandwidth_thresholds := [8]int{9000, 700, 9000, 700, 13500, 1000, 14000, 2000}
@(private = "file", rodata)
mono_music_bandwidth_thresholds := [8]int{9000, 700, 9000, 700, 11000, 1000, 12000, 2000}
@(private = "file", rodata)
stereo_voice_bandwidth_thresholds := [8]int{9000, 700, 9000, 700, 13500, 1000, 14000, 2000}
@(private = "file", rodata)
stereo_music_bandwidth_thresholds := [8]int{9000, 700, 9000, 700, 11000, 1000, 12000, 2000}
@(private = "file")
STEREO_VOICE_THRESHOLD :: 19000
@(private = "file")
STEREO_MUSIC_THRESHOLD :: 17000
@(private = "file", rodata)
mode_thresholds := [2][2]int{{64000, 10000}, {44000, 10000}}
@(private = "file", rodata)
fec_thresholds := [10]int{12000, 1000, 14000, 1000, 16000, 1000, 20000, 1000, 22000, 1000}

@(private = "file")
fix_const :: #force_inline proc "contextless" (c: f64, q: uint) -> i32 {return i32(c * f64(i64(1) << q) + 0.5)}

encoder_init :: proc(st: ^Encoder, fs: int, channels: int, app: Application) -> Error {
	if fs != 48000 do return .Bad_Arg
	if channels != 1 && channels != 2 do return .Bad_Arg
	st^ = {}
	st.channels = channels
	st.stream_channels = channels
	st.fs = fs
	if silk_init_encoder(&st.silk, &st.silk_mode) != 0 do return .Internal_Error
	st.silk_mode.n_channels_api = i32(channels)
	st.silk_mode.n_channels_internal = i32(channels)
	st.silk_mode.api_sample_rate = i32(fs)
	st.silk_mode.max_internal_sample_rate = 16000
	st.silk_mode.min_internal_sample_rate = 8000
	st.silk_mode.desired_internal_sample_rate = 16000
	st.silk_mode.payload_size_ms = 20
	st.silk_mode.bit_rate = 25000
	st.silk_mode.packet_loss_percentage = 0
	st.silk_mode.complexity = 9
	st.silk_mode.use_inband_fec = 0
	st.silk_mode.use_dtx = 0
	st.silk_mode.use_cbr = 0
	st.silk_mode.reduced_dependency = 0
	celt_encoder_init(&st.celt, channels)
	st.celt.complexity = int(st.silk_mode.complexity)
	st.use_vbr = true
	st.vbr_constraint = true
	st.user_bitrate_bps = OPUS_AUTO
	st.bitrate_bps = 3000 + fs * channels
	st.application = app
	st.signal_type = OPUS_AUTO
	st.user_bandwidth = OPUS_AUTO
	st.max_bandwidth = BANDWIDTH_FULLBAND
	st.force_channels = OPUS_AUTO
	st.user_forced_mode = OPUS_AUTO
	st.voice_ratio = -1
	st.encoder_buffer = fs / 100
	st.lsb_depth = 24
	st.delay_compensation = fs / 250
	st.hybrid_stereo_width_q14 = 1 << 14
	st.prev_hb_gain = 1
	st.variable_hp_smth2_q15 = lin2log(VARIABLE_HP_MIN_CUTOFF_HZ) << 8
	st.first = true
	st.mode = MODE_HYBRID
	st.bandwidth = BANDWIDTH_FULLBAND
	tonality_analysis_init(&st.analysis, i32(fs))
	return .None
}

encoder_create :: proc(fs: int, channels: int, app: Application, allocator := context.allocator) -> (^Encoder, Error) {
	e, aerr := new(Encoder, allocator)
	if aerr != nil do return nil, .Alloc_Fail
	if err := encoder_init(e, fs, channels, app); err != .None {
		free(e, allocator)
		return nil, err
	}
	return e, .None
}

encoder_destroy :: proc(e: ^Encoder, allocator := context.allocator) {free(e, allocator)}

// bps: bits/s, or OPUS_AUTO / OPUS_BITRATE_MAX (OPUS_SET_BITRATE).
encoder_set_bitrate :: proc(st: ^Encoder, bps: int) {
	v := bps
	if v != OPUS_AUTO && v != OPUS_BITRATE_MAX {
		if v <= 0 do return
		v = clamp(v, 500, 300000 * st.channels)
	}
	st.user_bitrate_bps = v
}
encoder_set_vbr :: proc(st: ^Encoder, on: bool) {
	st.use_vbr = on
	st.silk_mode.use_cbr = on ? 0 : 1
}
encoder_set_vbr_constraint :: proc(st: ^Encoder, on: bool) {st.vbr_constraint = on}
encoder_set_complexity :: proc(st: ^Encoder, c: int) {
	v := clamp(c, 0, 10)
	st.silk_mode.complexity = i32(v)
	st.celt.complexity = v
}
encoder_set_inband_fec :: proc(st: ^Encoder, on: bool) {st.silk_mode.use_inband_fec = on ? 1 : 0}
encoder_set_packet_loss_perc :: proc(st: ^Encoder, p: int) {
	v := clamp(p, 0, 100)
	st.silk_mode.packet_loss_percentage = i32(v)
	st.celt.loss_rate = v
}
encoder_set_dtx :: proc(st: ^Encoder, on: bool) {st.use_dtx = on}
// bw: BANDWIDTH_* or OPUS_AUTO (OPUS_SET_BANDWIDTH).
encoder_set_bandwidth :: proc(st: ^Encoder, bw: int) {
	if (bw < BANDWIDTH_NARROWBAND || bw > BANDWIDTH_FULLBAND) && bw != OPUS_AUTO do return
	st.user_bandwidth = bw
	switch bw {
	case BANDWIDTH_NARROWBAND: st.silk_mode.max_internal_sample_rate = 8000
	case BANDWIDTH_MEDIUMBAND: st.silk_mode.max_internal_sample_rate = 12000
	case: st.silk_mode.max_internal_sample_rate = 16000
	}
}
encoder_set_max_bandwidth :: proc(st: ^Encoder, bw: int) {
	if bw < BANDWIDTH_NARROWBAND || bw > BANDWIDTH_FULLBAND do return
	st.max_bandwidth = bw
	switch bw {
	case BANDWIDTH_NARROWBAND: st.silk_mode.max_internal_sample_rate = 8000
	case BANDWIDTH_MEDIUMBAND: st.silk_mode.max_internal_sample_rate = 12000
	case: st.silk_mode.max_internal_sample_rate = 16000
	}
}
// SIGNAL_VOICE, SIGNAL_MUSIC or OPUS_AUTO.
encoder_set_signal :: proc(st: ^Encoder, s: int) {st.signal_type = s}
// 1, 2 or OPUS_AUTO.
encoder_set_force_channels :: proc(st: ^Encoder, c: int) {st.force_channels = c}
// MODE_SILK_ONLY / MODE_HYBRID / MODE_CELT_ONLY or OPUS_AUTO (OPUS_SET_FORCE_MODE).
encoder_set_force_mode :: proc(st: ^Encoder, m: int) {st.user_forced_mode = m}
encoder_set_lsb_depth :: proc(st: ^Encoder, d: int) {st.lsb_depth = clamp(d, 8, 24)}
encoder_get_lookahead :: proc(st: ^Encoder) -> int {
	la := st.fs / 400
	if st.application != .Restricted_Lowdelay do la += st.delay_compensation
	return la
}
encoder_final_range :: proc(st: ^Encoder) -> u32 {return st.range_final}
// Mode of the last encoded frame (MODE_*), as libopus's prev_mode.
encoder_last_mode :: proc(st: ^Encoder) -> int {return st.prev_mode}

encoder_reset :: proc(st: ^Encoder) {
	tonality_analysis_reset(&st.analysis)
	st.stream_channels = 0
	st.hp_mem = {}
	st.prev_mode = 0
	st.prev_channels = 0
	st.prev_framesize = 0
	st.auto_bandwidth = 0
	st.silk_bw_switch = false
	st.width_mem = {}
	st.delay_buffer = {}
	st.detected_bandwidth = 0
	st.nb_no_activity_frames = 0
	st.peak_signal_energy = 0
	st.nonfinal_frame = false
	st.range_final = 0
	celt_encoder_reset(&st.celt)
	dummy: Silk_Enc_Control
	silk_init_encoder(&st.silk, &dummy)
	st.stream_channels = st.channels
	st.hybrid_stereo_width_q14 = 1 << 14
	st.prev_hb_gain = 1
	st.first = true
	st.mode = MODE_HYBRID
	st.bandwidth = BANDWIDTH_FULLBAND
	st.variable_hp_smth2_q15 = lin2log(VARIABLE_HP_MIN_CUTOFF_HZ) << 8
}

@(private = "file")
gen_toc :: proc(mode: int, framerate_: int, bandwidth: int, channels: int) -> u8 {
	framerate := framerate_
	period := 0
	for framerate < 400 {
		framerate <<= 1
		period += 1
	}
	toc: int
	if mode == MODE_SILK_ONLY {
		toc = (bandwidth - BANDWIDTH_NARROWBAND) << 5
		toc |= (period - 2) << 3
	} else if mode == MODE_CELT_ONLY {
		tmp := max(0, bandwidth - BANDWIDTH_MEDIUMBAND)
		toc = 0x80
		toc |= tmp << 5
		toc |= period << 3
	} else {
		toc = 0x60
		toc |= (bandwidth - BANDWIDTH_SUPERWIDEBAND) << 4
		toc |= (period - 2) << 3
	}
	if channels == 2 do toc |= 0x4
	return u8(toc)
}

@(private = "file")
silk_biquad_float :: proc(in_: []f32, B_Q28: [3]i32, A_Q28: [2]i32, S: []f32, out: []f32, len: int, stride: int) {
	A := [2]f32{f32(A_Q28[0]) * (1.0 / f32(1 << 28)), f32(A_Q28[1]) * (1.0 / f32(1 << 28))}
	B := [3]f32{f32(B_Q28[0]) * (1.0 / f32(1 << 28)), f32(B_Q28[1]) * (1.0 / f32(1 << 28)), f32(B_Q28[2]) * (1.0 / f32(1 << 28))}
	for k in 0 ..< len {
		inval := in_[k * stride]
		vout := S[0] + B[0] * inval
		S[0] = S[1] - vout * A[0] + B[1] * inval
		S[1] = -vout * A[1] + B[2] * inval + VERY_SMALL
		out[k * stride] = vout
	}
}

@(private = "file")
hp_cutoff :: proc(in_: []f32, cutoff_hz: i32, out: []f32, hp_mem: []f32, len, channels, fs: int) {
	Fc_Q19 := smulbb(fix_const(1.5 * 3.14159 / 1000, 19), cutoff_hz) / i32(fs / 1000)
	r_Q28 := fix_const(1.0, 28) - fix_const(0.92, 9) * Fc_Q19
	B_Q28 := [3]i32{r_Q28, (-r_Q28) << 1, r_Q28}
	r_Q22 := r_Q28 >> 6
	A_Q28 := [2]i32{smulww(r_Q22, smulww(Fc_Q19, Fc_Q19) - fix_const(2.0, 22)), smulww(r_Q22, r_Q22)}
	silk_biquad_float(in_, B_Q28, A_Q28, hp_mem[0:2], out, len, channels)
	if channels == 2 do silk_biquad_float(in_[1:], B_Q28, A_Q28, hp_mem[2:4], out[1:], len, channels)
}

@(private = "file")
dc_reject :: proc(in_: []f32, cutoff_hz: int, out: []f32, hp_mem: []f32, len, channels, fs: int) {
	coef := 6.3 * f32(cutoff_hz) / f32(fs)
	coef2 := 1 - coef
	if channels == 2 {
		m0 := hp_mem[0]
		m2 := hp_mem[2]
		for i in 0 ..< len {
			x0 := in_[2 * i + 0]
			x1 := in_[2 * i + 1]
			out0 := x0 - m0
			out1 := x1 - m2
			m0 = coef * x0 + VERY_SMALL + coef2 * m0
			m2 = coef * x1 + VERY_SMALL + coef2 * m2
			out[2 * i + 0] = out0
			out[2 * i + 1] = out1
		}
		hp_mem[0] = m0
		hp_mem[2] = m2
	} else {
		m0 := hp_mem[0]
		for i in 0 ..< len {
			x := in_[i]
			y := x - m0
			m0 = coef * x + VERY_SMALL + coef2 * m0
			out[i] = y
		}
		hp_mem[0] = m0
	}
}

@(private = "file")
stereo_fade :: proc(in_: []f32, out: []f32, g1_, g2_: f32, overlap48, frame_size, channels: int, fs: int) {
	inc := 48000 / fs
	overlap := overlap48 / inc
	g1 := 1 - g1_
	g2 := 1 - g2_
	i := 0
	for ; i < overlap; i += 1 {
		w := window120[i * inc] * window120[i * inc]
		g := w * g2 + (1 - w) * g1
		diff := 0.5 * (in_[i * channels] - in_[i * channels + 1])
		diff = g * diff
		out[i * channels] = out[i * channels] - diff
		out[i * channels + 1] = out[i * channels + 1] + diff
	}
	for ; i < frame_size; i += 1 {
		diff := 0.5 * (in_[i * channels] - in_[i * channels + 1])
		diff = g2 * diff
		out[i * channels] = out[i * channels] - diff
		out[i * channels + 1] = out[i * channels + 1] + diff
	}
}

@(private = "file")
gain_fade :: proc(in_: []f32, out: []f32, g1, g2: f32, overlap48, frame_size, channels: int, fs: int) {
	inc := 48000 / fs
	overlap := overlap48 / inc
	if channels == 1 {
		for i in 0 ..< overlap {
			w := window120[i * inc] * window120[i * inc]
			g := w * g2 + (1 - w) * g1
			out[i] = g * in_[i]
		}
	} else {
		for i in 0 ..< overlap {
			w := window120[i * inc] * window120[i * inc]
			g := w * g2 + (1 - w) * g1
			out[i * 2] = g * in_[i * 2]
			out[i * 2 + 1] = g * in_[i * 2 + 1]
		}
	}
	for c in 0 ..< channels {
		for i in overlap ..< frame_size do out[i * channels + c] = g2 * in_[i * channels + c]
	}
}

@(private = "file")
user_bitrate_to_bitrate :: proc(st: ^Encoder, frame_size_: int, max_data_bytes: int) -> int {
	frame_size := frame_size_
	if frame_size == 0 do frame_size = st.fs / 400
	if st.user_bitrate_bps == OPUS_AUTO do return 60 * st.fs / frame_size + st.fs * st.channels
	if st.user_bitrate_bps == OPUS_BITRATE_MAX do return max_data_bytes * 8 * st.fs / frame_size
	return st.user_bitrate_bps
}

@(private = "file")
frame_size_valid :: proc(n, fs: int) -> bool {
	if n < fs / 400 do return false
	return 400 * n == fs || 200 * n == fs || 100 * n == fs || 50 * n == fs || 25 * n == fs || 50 * n == 3 * fs || 50 * n == 4 * fs || 50 * n == 5 * fs ||
		50 * n == 6 * fs
}

compute_stereo_width :: proc(pcm: []f32, frame_size: int, fs: int, mem: ^Stereo_Width_State) -> f32 {
	frame_rate := fs / frame_size
	short_alpha := 1 - 25 * 1 / f32(max(50, frame_rate))
	xx, xy, yy: f32
	for i := 0; i < frame_size - 3; i += 4 {
		pxx, pxy, pyy: f32
		for k in 0 ..< 4 {
			x := pcm[2 * i + 2 * k]
			y := pcm[2 * i + 2 * k + 1]
			pxx += x * x
			pxy += x * y
			pyy += y * y
		}
		xx += pxx
		xy += pxy
		yy += pyy
	}
	if !(xx < 1e9) || math.is_nan(xx) || !(yy < 1e9) || math.is_nan(yy) {
		xy = 0
		xx = 0
		yy = 0
	}
	mem.XX += short_alpha * (xx - mem.XX)
	mem.XY += short_alpha * (xy - mem.XY)
	mem.YY += short_alpha * (yy - mem.YY)
	mem.XX = max(0, mem.XX)
	mem.XY = max(0, mem.XY)
	mem.YY = max(0, mem.YY)
	if max(mem.XX, mem.YY) > 8e-4 {
		sqrt_xx := celt_sqrt(mem.XX)
		sqrt_yy := celt_sqrt(mem.YY)
		qrrt_xx := celt_sqrt(sqrt_xx)
		qrrt_yy := celt_sqrt(sqrt_yy)
		mem.XY = min(mem.XY, sqrt_xx * sqrt_yy)
		corr := mem.XY / (EPSILON + sqrt_xx * sqrt_yy)
		ldiff := abs(qrrt_xx - qrrt_yy) / (EPSILON + qrrt_xx + qrrt_yy)
		width := celt_sqrt(1 - corr * corr) * ldiff
		mem.smoothed_width += (width - mem.smoothed_width) / f32(frame_rate)
		mem.max_follower = max(mem.max_follower - 0.02 / f32(frame_rate), mem.smoothed_width)
	}
	return min(1, 20 * mem.max_follower)
}

@(private = "file")
decide_fec :: proc(use_inband_fec: bool, packet_loss_perc: int, last_fec: i32, mode: int, bandwidth: ^int, rate: int) -> bool {
	if !use_inband_fec || packet_loss_perc == 0 || mode == MODE_CELT_ONLY do return false
	orig_bandwidth := bandwidth^
	for {
		thr := i32(fec_thresholds[2 * (bandwidth^ - BANDWIDTH_NARROWBAND)])
		hysteresis := i32(fec_thresholds[2 * (bandwidth^ - BANDWIDTH_NARROWBAND) + 1])
		if last_fec == 1 do thr -= hysteresis
		if last_fec == 0 do thr += hysteresis
		thr = smulwb(thr * (125 - i32(min(packet_loss_perc, 25))), fix_const(0.01, 16))
		if rate > int(thr) {
			return true
		} else if packet_loss_perc <= 5 {
			return false
		} else if bandwidth^ > BANDWIDTH_NARROWBAND {
			bandwidth^ -= 1
		} else {
			break
		}
	}
	bandwidth^ = orig_bandwidth
	return false
}

@(private = "file", rodata)
silk_hybrid_rate_table := [7][5]int {
	{0, 0, 0, 0, 0},
	{12000, 10000, 10000, 11000, 11000},
	{16000, 13500, 13500, 15000, 15000},
	{20000, 16000, 16000, 18000, 18000},
	{24000, 18000, 18000, 21000, 21000},
	{32000, 22000, 22000, 28000, 28000},
	{64000, 38000, 38000, 50000, 50000},
}

@(private = "file")
compute_silk_rate_for_hybrid :: proc(rate_: int, bandwidth: int, frame20ms: bool, vbr: bool, fec: bool, channels: int) -> int {
	rate := rate_ / channels
	entry := 1 + int(frame20ms) + 2 * int(fec)
	N :: len(silk_hybrid_rate_table)
	i := 1
	for ; i < N; i += 1 do if silk_hybrid_rate_table[i][0] > rate do break
	silk_rate: int
	if i == N {
		silk_rate = silk_hybrid_rate_table[i - 1][entry]
		silk_rate += (rate - silk_hybrid_rate_table[i - 1][0]) / 2
	} else {
		lo := silk_hybrid_rate_table[i - 1][entry]
		hi := silk_hybrid_rate_table[i][entry]
		x0 := silk_hybrid_rate_table[i - 1][0]
		x1 := silk_hybrid_rate_table[i][0]
		silk_rate = (lo * (x1 - rate) + hi * (rate - x0)) / (x1 - x0)
	}
	if !vbr do silk_rate += 100
	if bandwidth == BANDWIDTH_SUPERWIDEBAND do silk_rate += 300
	silk_rate *= channels
	if channels == 2 && rate >= 12000 do silk_rate -= 1000
	return silk_rate
}

@(private = "file")
compute_equiv_rate :: proc(bitrate: int, channels: int, frame_rate: int, vbr: bool, mode: int, complexity: int, loss: int) -> int {
	equiv := bitrate
	if frame_rate > 50 do equiv -= (40 * channels + 20) * (frame_rate - 50)
	if !vbr do equiv -= equiv / 12
	equiv = equiv * (90 + complexity) / 100
	if mode == MODE_SILK_ONLY || mode == MODE_HYBRID {
		if complexity < 2 do equiv = equiv * 4 / 5
		equiv -= equiv * loss / (6 * loss + 10)
	} else if mode == MODE_CELT_ONLY {
		if complexity < 5 do equiv = equiv * 9 / 10
	} else {
		equiv -= equiv * loss / (12 * loss + 20)
	}
	return equiv
}

@(private = "file")
is_digital_silence :: proc(pcm: []f32, frame_size, channels, lsb_depth: int) -> bool {
	sample_max: f32 = 0
	for i in 0 ..< frame_size * channels do sample_max = max(sample_max, abs(pcm[i]))
	return sample_max <= 1 / f32(i64(1) << uint(lsb_depth))
}

@(private = "file")
compute_frame_energy :: proc(pcm: []f32, frame_size, channels: int) -> f32 {
	n := frame_size * channels
	return inner_prod(pcm, pcm, n) / f32(n)
}

@(private = "file")
decide_dtx_mode :: proc(activity_probability: f32, nb_no_activity_frames: ^int, peak_signal_energy: f32, pcm: []f32, frame_size, channels: int,
	is_silence_: bool) -> bool {
	is_silence := is_silence_
	if !is_silence {
		if activity_probability < DTX_ACTIVITY_THRESHOLD {
			noise_energy := compute_frame_energy(pcm, frame_size, channels)
			is_silence = peak_signal_energy >= PSEUDO_SNR_THRESHOLD * noise_energy
		}
	}
	if is_silence {
		nb_no_activity_frames^ += 1
		if nb_no_activity_frames^ > NB_SPEECH_FRAMES_BEFORE_DTX {
			if nb_no_activity_frames^ <= NB_SPEECH_FRAMES_BEFORE_DTX + MAX_CONSECUTIVE_DTX do return true
			nb_no_activity_frames^ = NB_SPEECH_FRAMES_BEFORE_DTX
		}
	} else {
		nb_no_activity_frames^ = 0
	}
	return false
}

@(private = "file")
compute_redundancy_bytes :: proc(max_data_bytes: int, bitrate_bps: int, frame_rate: int, channels: int) -> int {
	base_bits := 40 * channels + 20
	redundancy_rate := bitrate_bps + base_bits * (200 - frame_rate)
	redundancy_rate = 3 * redundancy_rate / 2
	redundancy_bytes := redundancy_rate / 1600
	available_bits := max_data_bytes * 8 - 2 * base_bits
	redundancy_bytes_cap := (available_bits * 240 / (240 + 48000 / frame_rate) + base_bits) / 8
	redundancy_bytes = min(redundancy_bytes, redundancy_bytes_cap)
	if redundancy_bytes > 4 + 8 * channels do return min(257, redundancy_bytes)
	return 0
}

@(private = "file")
float2int16 :: #force_inline proc "contextless" (x_: f32) -> i16 {
	x := x_ * CELT_SIG_SCALE
	x = max(x, -32768)
	x = min(x, 32767)
	return i16(float2int(x))
}

// --- repacketizer (repacketizer.c subset) ---

@(private = "file")
encode_size :: proc(size: int, data: []u8) -> int {
	if size < 252 {
		data[0] = u8(size)
		return 1
	}
	data[0] = u8(252 + (size & 0x3))
	data[1] = u8((size - int(data[0])) >> 2)
	return 2
}

// opus_repacketizer_out_range_impl (not self-delimited). frames must not
// alias data. Returns the packet length or a negative Error.
@(private = "file")
repacketize :: proc(toc: u8, frames: [][]u8, data: []u8, maxlen: int, pad: bool) -> int {
	count := len(frames)
	if count < 1 || maxlen > len(data) do return int(Error.Bad_Arg)
	tot_size := 0
	ptr := 0
	if count == 1 {
		tot_size += len(frames[0]) + 1
		if tot_size > maxlen do return int(Error.Buffer_Too_Small)
		data[ptr] = toc & 0xFC
		ptr += 1
	} else if count == 2 {
		if len(frames[1]) == len(frames[0]) {
			tot_size += 2 * len(frames[0]) + 1
			if tot_size > maxlen do return int(Error.Buffer_Too_Small)
			data[ptr] = (toc & 0xFC) | 0x1
			ptr += 1
		} else {
			tot_size += len(frames[0]) + len(frames[1]) + 2 + int(len(frames[0]) >= 252)
			if tot_size > maxlen do return int(Error.Buffer_Too_Small)
			data[ptr] = (toc & 0xFC) | 0x2
			ptr += 1
			ptr += encode_size(len(frames[0]), data[ptr:])
		}
	}
	if count > 2 || (pad && tot_size < maxlen) {
		ptr = 0
		tot_size = 0
		vbr := false
		for i in 1 ..< count do if len(frames[i]) != len(frames[0]) {vbr = true; break}
		if vbr {
			tot_size += 2
			for i in 0 ..< count - 1 do tot_size += 1 + int(len(frames[i]) >= 252) + len(frames[i])
			tot_size += len(frames[count - 1])
			if tot_size > maxlen do return int(Error.Buffer_Too_Small)
			data[0] = (toc & 0xFC) | 0x3
			data[1] = u8(count) | 0x80
		} else {
			tot_size += count * len(frames[0]) + 2
			if tot_size > maxlen do return int(Error.Buffer_Too_Small)
			data[0] = (toc & 0xFC) | 0x3
			data[1] = u8(count)
		}
		ptr = 2
		pad_amount := pad ? maxlen - tot_size : 0
		if pad_amount != 0 {
			data[1] |= 0x40
			nb_255s := (pad_amount - 1) / 255
			for _ in 0 ..< nb_255s {
				data[ptr] = 255
				ptr += 1
			}
			data[ptr] = u8(pad_amount - 255 * nb_255s - 1)
			ptr += 1
			tot_size += pad_amount
		}
		if vbr do for i in 0 ..< count - 1 do ptr += encode_size(len(frames[i]), data[ptr:])
	}
	for f in frames {
		copy(data[ptr:ptr + len(f)], f)
		ptr += len(f)
	}
	if pad do for ; ptr < maxlen; ptr += 1 do data[ptr] = 0
	return tot_size
}

// opus_packet_pad: pads data[:length] in place to new_len bytes.
packet_pad :: proc(data: []u8, length, new_len: int) -> Error {
	if length < 1 do return .Bad_Arg
	if length == new_len do return .None
	if length > new_len || new_len > len(data) do return .Bad_Arg
	tmp: [1276 * 6]u8
	if length > len(tmp) do return .Bad_Arg
	copy(tmp[:length], data[:length])
	p, err := packet_parse(tmp[:length])
	if err != .None do return err
	ret := repacketize(p.toc, p.frames[:p.count], data, new_len, true)
	if ret < 0 do return Error(ret)
	return .None
}

// --- encoder core ---

@(private = "file")
encode_multiframe_packet :: proc(st: ^Encoder, pcm: []f32, nb_frames, frame_size: int, data: []u8, out_data_bytes: int, to_celt: bool, lsb_depth: int,
	float_api: bool) -> int {
	max_header_bytes := nb_frames == 2 ? 3 : 2 + (nb_frames - 1) * 2
	repacketize_len: int
	if st.use_vbr || st.user_bitrate_bps == OPUS_BITRATE_MAX {
		repacketize_len = out_data_bytes
	} else {
		cbr_bytes := 3 * st.bitrate_bps / (3 * 8 * st.fs / (frame_size * nb_frames))
		repacketize_len = min(cbr_bytes, out_data_bytes)
	}
	bytes_per_frame := min(1276, 1 + (repacketize_len - max_header_bytes) / nb_frames)
	tmp_data: [6 * 1276]u8
	bak_mode := st.user_forced_mode
	bak_bandwidth := st.user_bandwidth
	bak_channels := st.force_channels
	st.user_forced_mode = st.mode
	st.user_bandwidth = st.bandwidth
	st.force_channels = st.stream_channels
	bak_to_mono := st.silk_mode.to_mono
	if bak_to_mono != 0 do st.force_channels = 1
	else do st.prev_channels = st.stream_channels
	frames: [48][]u8
	nfr := 0
	toc: u8
	for i in 0 ..< nb_frames {
		st.silk_mode.to_mono = 0
		st.nonfinal_frame = i < nb_frames - 1
		if to_celt && i == nb_frames - 1 do st.user_forced_mode = MODE_CELT_ONLY
		buf := tmp_data[i * bytes_per_frame:(i + 1) * bytes_per_frame]
		tmp_len := encode_native(st, pcm[i * st.channels * frame_size:], frame_size, buf, lsb_depth, nil, 0, 0, 0, 0, float_api)
		if tmp_len < 0 do return int(Error.Internal_Error)
		p, err := packet_parse(buf[:tmp_len])
		if err != .None do return int(Error.Internal_Error)
		if i == 0 do toc = p.toc
		else if (p.toc & 0xFC) != (toc & 0xFC) do return int(Error.Internal_Error)
		if nfr + p.count > 48 do return int(Error.Internal_Error)
		for k in 0 ..< p.count {
			frames[nfr] = p.frames[k]
			nfr += 1
		}
	}
	ret := repacketize(toc, frames[:nfr], data, repacketize_len, !st.use_vbr)
	if ret < 0 do return int(Error.Internal_Error)
	st.user_forced_mode = bak_mode
	st.user_bandwidth = bak_bandwidth
	st.force_channels = bak_channels
	st.silk_mode.to_mono = bak_to_mono
	return ret
}

@(private = "file")
celt_end_band_for :: proc(bw: int) -> int {
	switch bw {
	case BANDWIDTH_NARROWBAND: return 13
	case BANDWIDTH_MEDIUMBAND, BANDWIDTH_WIDEBAND: return 17
	case BANDWIDTH_SUPERWIDEBAND: return 19
	}
	return 21
}

@(private = "file")
celt_set_prediction :: proc(c: ^Celt_Encoder, v: int) {
	c.disable_pf = v <= 1
	c.force_intra = v == 0
}

// opus_encode_native. Returns bytes written or a negative Error value.
@(private = "file")
encode_native :: proc(st: ^Encoder, pcm: []f32, frame_size: int, data_out: []u8, lsb_depth_: int, analysis_pcm: []f32, analysis_size, c1, c2,
	analysis_channels: int, float_api: bool) -> int {
	out_data_bytes := len(data_out)
	max_data_bytes := min(1276, out_data_bytes)
	st.range_final = 0
	if frame_size <= 0 || max_data_bytes <= 0 do return int(Error.Bad_Arg)
	if max_data_bytes == 1 && st.fs == frame_size * 10 do return int(Error.Buffer_Too_Small)
	celt := &st.celt
	data := data_out
	ret := 0
	prefill := 0
	start_band := 0
	redundancy := false
	redundancy_bytes := 0
	celt_to_silk := false
	to_celt := false
	redundant_rng: u32 = 0
	delay_compensation := st.application == .Restricted_Lowdelay ? 0 : st.delay_compensation
	lsb_depth := min(lsb_depth_, st.lsb_depth)
	analysis_info: Analysis_Info
	analysis_read_pos_bak := -1
	analysis_read_subframe_bak := -1
	is_silence := false
	if st.silk_mode.complexity >= 7 && st.fs >= 16000 {
		is_silence = is_digital_silence(pcm, frame_size, st.channels, lsb_depth)
		analysis_read_pos_bak = st.analysis.read_pos
		analysis_read_subframe_bak = st.analysis.read_subframe
		run_analysis(&st.analysis, analysis_pcm, analysis_size, frame_size, c1, c2, analysis_channels, i32(st.fs), lsb_depth, &analysis_info)
		if !is_silence && analysis_info.activity_probability > DTX_ACTIVITY_THRESHOLD {
			st.peak_signal_energy = max(0.999 * st.peak_signal_energy, compute_frame_energy(pcm, frame_size, st.channels))
		}
	} else if st.analysis.initialized {
		tonality_analysis_reset(&st.analysis)
	}
	if !is_silence do st.voice_ratio = -1
	st.detected_bandwidth = 0
	if analysis_info.valid {
		if st.signal_type == OPUS_AUTO {
			prob: f32
			if st.prev_mode == 0 do prob = analysis_info.music_prob
			else if st.prev_mode == MODE_CELT_ONLY do prob = analysis_info.music_prob_max
			else do prob = analysis_info.music_prob_min
			st.voice_ratio = int(math.floor(0.5 + 100 * (1 - f64(prob))))
		}
		ab := analysis_info.bandwidth
		switch {
		case ab <= 12: st.detected_bandwidth = BANDWIDTH_NARROWBAND
		case ab <= 14: st.detected_bandwidth = BANDWIDTH_MEDIUMBAND
		case ab <= 16: st.detected_bandwidth = BANDWIDTH_WIDEBAND
		case ab <= 18: st.detected_bandwidth = BANDWIDTH_SUPERWIDEBAND
		case: st.detected_bandwidth = BANDWIDTH_FULLBAND
		}
	}
	stereo_width: f32 = 0
	if st.channels == 2 && st.force_channels != 1 do stereo_width = compute_stereo_width(pcm, frame_size, st.fs, &st.width_mem)
	total_buffer := delay_compensation
	st.bitrate_bps = user_bitrate_to_bitrate(st, frame_size, max_data_bytes)
	frame_rate := st.fs / frame_size
	if !st.use_vbr {
		frame_rate12 := 12 * st.fs / frame_size
		cbr_bytes := min((12 * st.bitrate_bps / 8 + frame_rate12 / 2) / frame_rate12, max_data_bytes)
		st.bitrate_bps = cbr_bytes * frame_rate12 * 8 / 12
		max_data_bytes = max(1, cbr_bytes)
	}
	if max_data_bytes < 3 || st.bitrate_bps < 3 * frame_rate * 8 || (frame_rate < 50 && (max_data_bytes * frame_rate < 300 || st.bitrate_bps < 2400)) {
		// Not enough space to do anything useful: emit PLC frames.
		tocmode := st.mode
		bw := st.bandwidth == 0 ? BANDWIDTH_NARROWBAND : st.bandwidth
		packet_code := 0
		num_multiframes := 0
		if tocmode == 0 do tocmode = MODE_SILK_ONLY
		if frame_rate > 100 do tocmode = MODE_CELT_ONLY
		if frame_rate == 25 && tocmode != MODE_SILK_ONLY {
			frame_rate = 50
			packet_code = 1
		}
		if frame_rate <= 16 {
			if out_data_bytes == 1 || (tocmode == MODE_SILK_ONLY && frame_rate != 10) {
				tocmode = MODE_SILK_ONLY
				packet_code = int(frame_rate <= 12)
				frame_rate = frame_rate == 12 ? 25 : 16
			} else {
				num_multiframes = 50 / frame_rate
				frame_rate = 50
				packet_code = 3
			}
		}
		if tocmode == MODE_SILK_ONLY && bw > BANDWIDTH_WIDEBAND do bw = BANDWIDTH_WIDEBAND
		else if tocmode == MODE_CELT_ONLY && bw == BANDWIDTH_MEDIUMBAND do bw = BANDWIDTH_NARROWBAND
		else if tocmode == MODE_HYBRID && bw <= BANDWIDTH_SUPERWIDEBAND do bw = BANDWIDTH_SUPERWIDEBAND
		data[0] = gen_toc(tocmode, frame_rate, bw, st.stream_channels)
		data[0] |= u8(packet_code)
		ret = packet_code <= 1 ? 1 : 2
		max_data_bytes = max(max_data_bytes, ret)
		if packet_code == 3 do data[1] = u8(num_multiframes)
		if !st.use_vbr {
			if packet_pad(data, ret, max_data_bytes) == .None do ret = max_data_bytes
			else do ret = int(Error.Internal_Error)
		}
		return ret
	}
	max_rate := frame_rate * max_data_bytes * 8
	complexity := int(st.silk_mode.complexity)
	loss := int(st.silk_mode.packet_loss_percentage)
	equiv_rate := compute_equiv_rate(st.bitrate_bps, st.channels, st.fs / frame_size, st.use_vbr, 0, complexity, loss)
	voice_est: int
	if st.signal_type == SIGNAL_VOICE {
		voice_est = 127
	} else if st.signal_type == SIGNAL_MUSIC {
		voice_est = 0
	} else if st.voice_ratio >= 0 {
		voice_est = st.voice_ratio * 327 >> 8
		if st.application == .Audio do voice_est = min(voice_est, 115)
	} else if st.application == .VOIP {
		voice_est = 115
	} else {
		voice_est = 48
	}
	if st.force_channels != OPUS_AUTO && st.channels == 2 {
		st.stream_channels = st.force_channels
	} else {
		if st.channels == 2 {
			stereo_threshold := STEREO_MUSIC_THRESHOLD + ((voice_est * voice_est * (STEREO_VOICE_THRESHOLD - STEREO_MUSIC_THRESHOLD)) >> 14)
			if st.stream_channels == 2 do stereo_threshold -= 1000
			else do stereo_threshold += 1000
			st.stream_channels = equiv_rate > stereo_threshold ? 2 : 1
		} else {
			st.stream_channels = st.channels
		}
	}
	equiv_rate = compute_equiv_rate(st.bitrate_bps, st.stream_channels, st.fs / frame_size, st.use_vbr, 0, complexity, loss)
	st.silk_mode.use_dtx = i32(st.use_dtx && !(analysis_info.valid || is_silence))
	if st.application == .Restricted_Lowdelay {
		st.mode = MODE_CELT_ONLY
	} else if st.user_forced_mode == OPUS_AUTO {
		mode_voice := int((1 - stereo_width) * f32(mode_thresholds[0][0]) + stereo_width * f32(mode_thresholds[1][0]))
		mode_music := int((1 - stereo_width) * f32(mode_thresholds[1][1]) + stereo_width * f32(mode_thresholds[1][1]))
		threshold := mode_music + ((voice_est * voice_est * (mode_voice - mode_music)) >> 14)
		if st.application == .VOIP do threshold += 8000
		if st.prev_mode == MODE_CELT_ONLY do threshold -= 4000
		else if st.prev_mode > 0 do threshold += 4000
		st.mode = equiv_rate >= threshold ? MODE_CELT_ONLY : MODE_SILK_ONLY
		if st.silk_mode.use_inband_fec != 0 && int(st.silk_mode.packet_loss_percentage) > (128 - voice_est) >> 4 do st.mode = MODE_SILK_ONLY
		if st.silk_mode.use_dtx != 0 && voice_est > 100 do st.mode = MODE_SILK_ONLY
		if max_data_bytes < (frame_rate > 50 ? 9000 : 6000) * frame_size / (st.fs * 8) do st.mode = MODE_CELT_ONLY
	} else {
		st.mode = st.user_forced_mode
	}
	if st.mode != MODE_CELT_ONLY && frame_size < st.fs / 100 do st.mode = MODE_CELT_ONLY
	if st.prev_mode > 0 &&
	   ((st.mode != MODE_CELT_ONLY && st.prev_mode == MODE_CELT_ONLY) || (st.mode == MODE_CELT_ONLY && st.prev_mode != MODE_CELT_ONLY)) {
		redundancy = true
		celt_to_silk = st.mode != MODE_CELT_ONLY
		if !celt_to_silk {
			if frame_size >= st.fs / 100 {
				st.mode = st.prev_mode
				to_celt = true
			} else {
				redundancy = false
			}
		}
	}
	if st.stream_channels == 1 && st.prev_channels == 2 && st.silk_mode.to_mono == 0 && st.mode != MODE_CELT_ONLY && st.prev_mode != MODE_CELT_ONLY {
		st.silk_mode.to_mono = 1
		st.stream_channels = 2
	} else {
		st.silk_mode.to_mono = 0
	}
	equiv_rate = compute_equiv_rate(st.bitrate_bps, st.stream_channels, st.fs / frame_size, st.use_vbr, st.mode, complexity, loss)
	if st.mode != MODE_CELT_ONLY && st.prev_mode == MODE_CELT_ONLY {
		dummy: Silk_Enc_Control
		silk_init_encoder(&st.silk, &dummy)
		prefill = 1
	}
	if st.mode == MODE_CELT_ONLY || st.first || st.silk_mode.allow_bandwidth_switch != 0 {
		voice_thr, music_thr: ^[8]int
		if st.channels == 2 && st.force_channels != 1 {
			voice_thr = &stereo_voice_bandwidth_thresholds
			music_thr = &stereo_music_bandwidth_thresholds
		} else {
			voice_thr = &mono_voice_bandwidth_thresholds
			music_thr = &mono_music_bandwidth_thresholds
		}
		bandwidth_thresholds: [8]int
		for i in 0 ..< 8 do bandwidth_thresholds[i] = music_thr[i] + ((voice_est * voice_est * (voice_thr[i] - music_thr[i])) >> 14)
		bandwidth := BANDWIDTH_FULLBAND
		for {
			threshold := bandwidth_thresholds[2 * (bandwidth - BANDWIDTH_MEDIUMBAND)]
			hysteresis := bandwidth_thresholds[2 * (bandwidth - BANDWIDTH_MEDIUMBAND) + 1]
			if !st.first {
				if st.auto_bandwidth >= bandwidth do threshold -= hysteresis
				else do threshold += hysteresis
			}
			if equiv_rate >= threshold do break
			bandwidth -= 1
			if bandwidth <= BANDWIDTH_NARROWBAND do break
		}
		if bandwidth == BANDWIDTH_MEDIUMBAND do bandwidth = BANDWIDTH_WIDEBAND
		st.bandwidth = bandwidth
		st.auto_bandwidth = bandwidth
		if !st.first && st.mode != MODE_CELT_ONLY && st.silk_mode.in_wb_mode_without_variable_lp == 0 && st.bandwidth > BANDWIDTH_WIDEBAND {
			st.bandwidth = BANDWIDTH_WIDEBAND
		}
	}
	if st.bandwidth > st.max_bandwidth do st.bandwidth = st.max_bandwidth
	if st.user_bandwidth != OPUS_AUTO do st.bandwidth = st.user_bandwidth
	if st.mode != MODE_CELT_ONLY && max_rate < 15000 do st.bandwidth = min(st.bandwidth, BANDWIDTH_WIDEBAND)
	if st.fs <= 24000 && st.bandwidth > BANDWIDTH_SUPERWIDEBAND do st.bandwidth = BANDWIDTH_SUPERWIDEBAND
	if st.fs <= 16000 && st.bandwidth > BANDWIDTH_WIDEBAND do st.bandwidth = BANDWIDTH_WIDEBAND
	if st.fs <= 12000 && st.bandwidth > BANDWIDTH_MEDIUMBAND do st.bandwidth = BANDWIDTH_MEDIUMBAND
	if st.fs <= 8000 && st.bandwidth > BANDWIDTH_NARROWBAND do st.bandwidth = BANDWIDTH_NARROWBAND
	if st.detected_bandwidth != 0 && st.user_bandwidth == OPUS_AUTO {
		min_detected_bandwidth: int
		if equiv_rate <= 18000 * st.stream_channels && st.mode == MODE_CELT_ONLY do min_detected_bandwidth = BANDWIDTH_NARROWBAND
		else if equiv_rate <= 24000 * st.stream_channels && st.mode == MODE_CELT_ONLY do min_detected_bandwidth = BANDWIDTH_MEDIUMBAND
		else if equiv_rate <= 30000 * st.stream_channels do min_detected_bandwidth = BANDWIDTH_WIDEBAND
		else if equiv_rate <= 44000 * st.stream_channels do min_detected_bandwidth = BANDWIDTH_SUPERWIDEBAND
		else do min_detected_bandwidth = BANDWIDTH_FULLBAND
		st.detected_bandwidth = max(st.detected_bandwidth, min_detected_bandwidth)
		st.bandwidth = min(st.bandwidth, st.detected_bandwidth)
	}
	st.silk_mode.lbrr_coded = i32(decide_fec(st.silk_mode.use_inband_fec != 0, loss, st.silk_mode.lbrr_coded, st.mode, &st.bandwidth, equiv_rate))
	celt.lsb_depth = lsb_depth
	if st.mode == MODE_CELT_ONLY && st.bandwidth == BANDWIDTH_MEDIUMBAND do st.bandwidth = BANDWIDTH_WIDEBAND
	curr_bandwidth := st.bandwidth
	if st.mode == MODE_SILK_ONLY && curr_bandwidth > BANDWIDTH_WIDEBAND do st.mode = MODE_HYBRID
	if st.mode == MODE_HYBRID && curr_bandwidth <= BANDWIDTH_WIDEBAND do st.mode = MODE_SILK_ONLY
	if (frame_size > st.fs / 50 && st.mode != MODE_SILK_ONLY) || frame_size > 3 * st.fs / 50 {
		enc_frame_size: int
		if st.mode == MODE_SILK_ONLY {
			if frame_size == 2 * st.fs / 25 do enc_frame_size = st.fs / 25
			else if frame_size == 3 * st.fs / 25 do enc_frame_size = 3 * st.fs / 50
			else do enc_frame_size = st.fs / 50
		} else {
			enc_frame_size = st.fs / 50
		}
		nb_frames := frame_size / enc_frame_size
		if analysis_read_pos_bak != -1 {
			st.analysis.read_pos = analysis_read_pos_bak
			st.analysis.read_subframe = analysis_read_subframe_bak
		}
		return encode_multiframe_packet(st, pcm, nb_frames, enc_frame_size, data_out, out_data_bytes, to_celt, lsb_depth, float_api)
	}
	if st.silk_bw_switch {
		redundancy = true
		celt_to_silk = true
		st.silk_bw_switch = false
		prefill = 2
	}
	if st.mode == MODE_CELT_ONLY do redundancy = false
	if redundancy {
		redundancy_bytes = compute_redundancy_bytes(max_data_bytes, st.bitrate_bps, frame_rate, st.stream_channels)
		if redundancy_bytes == 0 do redundancy = false
	}
	bytes_target := min(max_data_bytes - redundancy_bytes, st.bitrate_bps * frame_size / (st.fs * 8)) - 1
	payload := data[1:max_data_bytes]
	enc: Range
	ec_enc_init(&enc, payload)
	CH := st.channels
	pcm_buf_store: [(MAX_ENCODER_BUFFER + 2880) * 2]f32
	pcm_buf := pcm_buf_store[:(total_buffer + frame_size) * CH]
	copy(pcm_buf[:total_buffer * CH], st.delay_buffer[(st.encoder_buffer - total_buffer) * CH:][:total_buffer * CH])
	hp_freq_smth1: i32
	if st.mode == MODE_CELT_ONLY do hp_freq_smth1 = lin2log(VARIABLE_HP_MIN_CUTOFF_HZ) << 8
	else do hp_freq_smth1 = silk_enc_variable_hp_smth1_q15(&st.silk)
	st.variable_hp_smth2_q15 = smlawb(st.variable_hp_smth2_q15, hp_freq_smth1 - st.variable_hp_smth2_q15, fix_const(VARIABLE_HP_SMTH_COEF2, 16))
	cutoff_hz := log2lin(st.variable_hp_smth2_q15 >> 8)
	if st.application == .VOIP {
		hp_cutoff(pcm, cutoff_hz, pcm_buf[total_buffer * CH:], st.hp_mem[:], frame_size, CH, st.fs)
	} else {
		dc_reject(pcm, 3, pcm_buf[total_buffer * CH:], st.hp_mem[:], frame_size, CH, st.fs)
	}
	if float_api {
		x := pcm_buf[total_buffer * CH:]
		sum := inner_prod(x, x, frame_size * CH)
		if !(sum < 1e9) || math.is_nan(sum) {
			for i in 0 ..< frame_size * CH do x[i] = 0
			st.hp_mem = {}
		}
	}
	hb_gain: f32 = 1
	if st.mode != MODE_CELT_ONLY {
		pcm_silk: [MAX_ENCODER_BUFFER * 2 + 2880 * 2]i16
		activity := VAD_NO_DECISION
		if analysis_info.valid do activity = int(analysis_info.activity_probability >= DTX_ACTIVITY_THRESHOLD)
		total_bit_rate := 8 * bytes_target * frame_rate
		if st.mode == MODE_HYBRID {
			st.silk_mode.bit_rate = i32(compute_silk_rate_for_hybrid(total_bit_rate, curr_bandwidth, st.fs == 50 * frame_size, st.use_vbr,
					st.silk_mode.lbrr_coded != 0, st.stream_channels))
			celt_rate := total_bit_rate - int(st.silk_mode.bit_rate)
			hb_gain = 1 - celt_exp2(f32(-celt_rate) * (1.0 / 1024)) // SHR32(.., 1) is a no-op in the float build
		} else {
			st.silk_mode.bit_rate = i32(total_bit_rate)
		}
		st.silk_mode.payload_size_ms = i32(1000 * frame_size / st.fs)
		st.silk_mode.n_channels_api = i32(st.channels)
		st.silk_mode.n_channels_internal = i32(st.stream_channels)
		if curr_bandwidth == BANDWIDTH_NARROWBAND do st.silk_mode.desired_internal_sample_rate = 8000
		else if curr_bandwidth == BANDWIDTH_MEDIUMBAND do st.silk_mode.desired_internal_sample_rate = 12000
		else do st.silk_mode.desired_internal_sample_rate = 16000
		st.silk_mode.min_internal_sample_rate = st.mode == MODE_HYBRID ? 16000 : 8000
		st.silk_mode.max_internal_sample_rate = 16000
		if st.mode == MODE_SILK_ONLY {
			effective_max_rate := max_rate
			if frame_rate > 50 do effective_max_rate = effective_max_rate * 2 / 3
			if effective_max_rate < 8000 {
				st.silk_mode.max_internal_sample_rate = 12000
				st.silk_mode.desired_internal_sample_rate = min(12000, st.silk_mode.desired_internal_sample_rate)
			}
			if effective_max_rate < 7000 {
				st.silk_mode.max_internal_sample_rate = 8000
				st.silk_mode.desired_internal_sample_rate = min(8000, st.silk_mode.desired_internal_sample_rate)
			}
		}
		st.silk_mode.use_cbr = i32(!st.use_vbr)
		st.silk_mode.max_bits = i32((max_data_bytes - 1) * 8)
		if redundancy && redundancy_bytes >= 2 {
			st.silk_mode.max_bits -= i32(redundancy_bytes * 8 + 1)
			if st.mode == MODE_HYBRID do st.silk_mode.max_bits -= 20
		}
		if st.silk_mode.use_cbr != 0 {
			if st.mode == MODE_HYBRID {
				st.silk_mode.max_bits = min(st.silk_mode.max_bits, i32(int(st.silk_mode.bit_rate) * frame_size / st.fs))
			}
		} else {
			if st.mode == MODE_HYBRID {
				max_bit_rate := compute_silk_rate_for_hybrid(int(st.silk_mode.max_bits) * st.fs / frame_size, curr_bandwidth, st.fs == 50 * frame_size,
					st.use_vbr, st.silk_mode.lbrr_coded != 0, st.stream_channels)
				st.silk_mode.max_bits = i32(max_bit_rate * frame_size / st.fs)
			}
		}
		if prefill != 0 {
			zero: i32 = 0
			prefill_offset := CH * (st.encoder_buffer - st.delay_compensation - st.fs / 400)
			db := st.delay_buffer[prefill_offset:]
			gain_fade(db, db, 0, 1, OVERLAP, st.fs / 400, CH, st.fs)
			for i in 0 ..< prefill_offset do st.delay_buffer[i] = 0
			for i in 0 ..< st.encoder_buffer * CH do pcm_silk[i] = float2int16(st.delay_buffer[i])
			silk_encode(&st.silk, &st.silk_mode, pcm_silk[:st.encoder_buffer * CH], st.encoder_buffer, nil, &zero, prefill, activity)
			st.silk_mode.opus_can_switch = 0
		}
		for i in 0 ..< frame_size * CH do pcm_silk[i] = float2int16(pcm_buf[total_buffer * CH + i])
		n_bytes: i32
		if silk_encode(&st.silk, &st.silk_mode, pcm_silk[:frame_size * CH], frame_size, &enc, &n_bytes, 0, activity) != 0 {
			return int(Error.Internal_Error)
		}
		if st.mode == MODE_SILK_ONLY {
			switch st.silk_mode.internal_sample_rate {
			case 8000: curr_bandwidth = BANDWIDTH_NARROWBAND
			case 12000: curr_bandwidth = BANDWIDTH_MEDIUMBAND
			case 16000: curr_bandwidth = BANDWIDTH_WIDEBAND
			}
		}
		st.silk_mode.opus_can_switch = i32(st.silk_mode.switch_ready != 0 && !st.nonfinal_frame)
		if n_bytes == 0 {
			st.range_final = 0
			data[0] = gen_toc(st.mode, st.fs / frame_size, curr_bandwidth, st.stream_channels)
			return 1
		}
		if st.silk_mode.opus_can_switch != 0 {
			redundancy_bytes = compute_redundancy_bytes(max_data_bytes, st.bitrate_bps, frame_rate, st.stream_channels)
			redundancy = redundancy_bytes != 0
			celt_to_silk = false
			st.silk_bw_switch = true
		}
	}
	celt.end = celt_end_band_for(curr_bandwidth)
	celt.stream_channels = st.stream_channels
	celt.bitrate = BITRATE_MAX
	if st.mode != MODE_SILK_ONLY {
		celt.vbr = false
		celt_set_prediction(celt, st.silk_mode.reduced_dependency != 0 ? 0 : 2)
		if st.mode == MODE_HYBRID {
			if st.use_vbr {
				celt.bitrate = i32(st.bitrate_bps - int(st.silk_mode.bit_rate))
				celt.constrained_vbr = false
			}
		} else {
			if st.use_vbr {
				celt.vbr = true
				celt.constrained_vbr = st.vbr_constraint
				celt.bitrate = i32(st.bitrate_bps)
			}
		}
	}
	N4 := st.fs / 400
	tmp_prefill: [2 * 120]f32
	if st.mode != MODE_SILK_ONLY && st.mode != st.prev_mode && st.prev_mode > 0 {
		copy(tmp_prefill[:CH * N4], st.delay_buffer[(st.encoder_buffer - total_buffer - N4) * CH:][:CH * N4])
	}
	if CH * (st.encoder_buffer - (frame_size + total_buffer)) > 0 {
		n := CH * (st.encoder_buffer - frame_size - total_buffer)
		copy(st.delay_buffer[:n], st.delay_buffer[CH * frame_size:][:n])
		copy(st.delay_buffer[n:][:(frame_size + total_buffer) * CH], pcm_buf[:(frame_size + total_buffer) * CH])
	} else {
		copy(st.delay_buffer[:st.encoder_buffer * CH], pcm_buf[(frame_size + total_buffer - st.encoder_buffer) * CH:][:st.encoder_buffer * CH])
	}
	if st.prev_hb_gain < 1 || hb_gain < 1 do gain_fade(pcm_buf, pcm_buf, st.prev_hb_gain, hb_gain, OVERLAP, frame_size, CH, st.fs)
	st.prev_hb_gain = hb_gain
	if st.mode != MODE_HYBRID || st.stream_channels == 1 {
		if equiv_rate > 32000 do st.silk_mode.stereo_width_q14 = 16384
		else if equiv_rate < 16000 do st.silk_mode.stereo_width_q14 = 0
		else do st.silk_mode.stereo_width_q14 = i32(16384 - 2048 * (32000 - equiv_rate) / (equiv_rate - 14000))
	}
	if CH == 2 {
		if st.hybrid_stereo_width_q14 < (1 << 14) || st.silk_mode.stereo_width_q14 < (1 << 14) {
			g1 := f32(i16(st.hybrid_stereo_width_q14)) * (1.0 / 16384)
			g2 := f32(i16(st.silk_mode.stereo_width_q14)) * (1.0 / 16384)
			stereo_fade(pcm_buf, pcm_buf, g1, g2, OVERLAP, frame_size, CH, st.fs)
			st.hybrid_stereo_width_q14 = i32(i16(st.silk_mode.stereo_width_q14))
		}
	}
	if st.mode != MODE_CELT_ONLY && int(ec_tell(&enc)) + 17 + 20 * int(st.mode == MODE_HYBRID) <= 8 * (max_data_bytes - 1) {
		if st.mode == MODE_HYBRID do ec_enc_bit_logp(&enc, redundancy, 12)
		if redundancy {
			ec_enc_bit_logp(&enc, celt_to_silk, 1)
			max_redundancy: int
			if st.mode == MODE_HYBRID do max_redundancy = (max_data_bytes - 1) - ((int(ec_tell(&enc)) + 8 + 3 + 7) >> 3)
			else do max_redundancy = (max_data_bytes - 1) - ((int(ec_tell(&enc)) + 7) >> 3)
			redundancy_bytes = min(max_redundancy, redundancy_bytes)
			redundancy_bytes = min(257, max(2, redundancy_bytes))
			if st.mode == MODE_HYBRID do ec_enc_uint(&enc, u32(redundancy_bytes - 2), 256)
		}
	} else {
		redundancy = false
	}
	if !redundancy {
		st.silk_bw_switch = false
		redundancy_bytes = 0
	}
	if st.mode != MODE_CELT_ONLY do start_band = 17
	nb_compr_bytes: int
	if st.mode == MODE_SILK_ONLY {
		ret = (int(ec_tell(&enc)) + 7) >> 3
		ec_enc_done(&enc)
		nb_compr_bytes = ret
	} else {
		nb_compr_bytes = (max_data_bytes - 1) - redundancy_bytes
		ec_enc_shrink(&enc, u32(nb_compr_bytes))
	}
	if redundancy || st.mode != MODE_SILK_ONLY do celt.analysis = analysis_info
	if st.mode == MODE_HYBRID {
		celt.silk_info.signal_type = int(st.silk_mode.signal_type)
		celt.silk_info.offset = int(st.silk_mode.offset)
	}
	N2 := st.fs / 200
	if redundancy && celt_to_silk {
		// 5 ms redundant CELT frame before switching to SILK
		celt.start = 0
		celt.vbr = false
		celt.bitrate = BITRATE_MAX
		_, err := celt_encode(celt, pcm_buf, N2, payload[nb_compr_bytes:nb_compr_bytes + redundancy_bytes])
		if err != .None do return int(Error.Internal_Error)
		redundant_rng = celt.rng
		celt_encoder_reset(celt)
	}
	celt.start = start_band
	if st.mode != MODE_SILK_ONLY {
		if st.mode != st.prev_mode && st.prev_mode > 0 {
			dummy: [2]u8
			celt_encoder_reset(celt)
			celt_encode(celt, tmp_prefill[:CH * N4], N4, dummy[:])
			celt_set_prediction(celt, 0)
		}
		if int(ec_tell(&enc)) <= 8 * nb_compr_bytes {
			if redundancy && celt_to_silk && st.mode == MODE_HYBRID && st.use_vbr do celt.bitrate = i32(st.bitrate_bps - int(st.silk_mode.bit_rate))
			celt.vbr = st.use_vbr
			n, err := celt_encode(celt, pcm_buf, frame_size, payload[:nb_compr_bytes], &enc)
			if err != .None do return int(Error.Internal_Error)
			ret = n
			if redundancy && celt_to_silk && st.mode == MODE_HYBRID && st.use_vbr {
				copy(payload[ret:ret + redundancy_bytes], payload[nb_compr_bytes:nb_compr_bytes + redundancy_bytes])
				nb_compr_bytes = nb_compr_bytes + redundancy_bytes
			}
		}
	}
	if redundancy && !celt_to_silk {
		// 5 ms redundant CELT frame after SILK, to switch to CELT
		dummy: [2]u8
		celt_encoder_reset(celt)
		celt.start = 0
		celt_set_prediction(celt, 0)
		celt.vbr = false
		celt.bitrate = BITRATE_MAX
		if st.mode == MODE_HYBRID {
			nb_compr_bytes = ret
			ec_enc_shrink(&enc, u32(nb_compr_bytes))
		}
		celt_encode(celt, pcm_buf[CH * (frame_size - N2 - N4):], N4, dummy[:])
		_, err := celt_encode(celt, pcm_buf[CH * (frame_size - N2):], N2, payload[nb_compr_bytes:nb_compr_bytes + redundancy_bytes])
		if err != .None do return int(Error.Internal_Error)
		redundant_rng = celt.rng
	}
	data[0] = gen_toc(st.mode, st.fs / frame_size, curr_bandwidth, st.stream_channels)
	st.range_final = enc.rng ~ redundant_rng
	st.prev_mode = to_celt ? MODE_CELT_ONLY : st.mode
	st.prev_channels = st.stream_channels
	st.prev_framesize = frame_size
	st.first = false
	if st.use_dtx && (analysis_info.valid || is_silence) {
		if decide_dtx_mode(analysis_info.activity_probability, &st.nb_no_activity_frames, st.peak_signal_energy, pcm, frame_size, CH, is_silence) {
			st.range_final = 0
			data[0] = gen_toc(st.mode, st.fs / frame_size, curr_bandwidth, st.stream_channels)
			return 1
		}
	} else {
		st.nb_no_activity_frames = 0
	}
	if int(ec_tell(&enc)) > (max_data_bytes - 1) * 8 {
		if max_data_bytes < 2 do return int(Error.Buffer_Too_Small)
		data[1] = 0
		ret = 1
		st.range_final = 0
	} else if st.mode == MODE_SILK_ONLY && !redundancy {
		for ret > 2 && data[ret] == 0 do ret -= 1
	}
	ret += 1 + redundancy_bytes
	if !st.use_vbr {
		if packet_pad(data, ret, max_data_bytes) != .None do return int(Error.Internal_Error)
		ret = max_data_bytes
	}
	return ret
}

// Encode one packet from interleaved float pcm (±1.0, 48 kHz). The frame
// duration is len(pcm)/channels samples: 2.5, 5, 10, 20, 40, 60, 80, 100 or
// 120 ms. Returns bytes written to out (at most 1275 per frame; a 1-byte
// packet is a DTX/PLC frame).
encode :: proc(st: ^Encoder, pcm: []f32, out: []u8) -> (int, Error) {
	frame_size := len(pcm) / st.channels
	if !frame_size_valid(frame_size, st.fs) do return 0, .Bad_Arg
	n := encode_native(st, pcm, frame_size, out, 24, pcm, frame_size, 0, -2, st.channels, true)
	if n < 0 do return 0, Error(n)
	return n, .None
}

// Same as encode, s16 input (opus_encode: lsb depth 16).
encode_i16 :: proc(st: ^Encoder, pcm: []i16, out: []u8) -> (int, Error) {
	frame_size := len(pcm) / st.channels
	if !frame_size_valid(frame_size, st.fs) do return 0, .Bad_Arg
	tmp: [5760 * 2]f32
	for i in 0 ..< frame_size * st.channels do tmp[i] = (1.0 / 32768) * f32(pcm[i])
	x := tmp[:frame_size * st.channels]
	n := encode_native(st, x, frame_size, out, 16, x, frame_size, 0, -2, st.channels, false)
	if n < 0 do return 0, Error(n)
	return n, .None
}
