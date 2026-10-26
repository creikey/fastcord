package opus

// SILK encoder (port of the libopus 1.3.1 float encoder): constants, state
// structs, small tables and shared helpers. BSD, see range.odin header.

import "core:c/libc"

SE_NUM_CHANNELS :: 2
SE_MIN_TARGET_RATE_BPS :: 5000
SE_NB_SPEECH_FRAMES_BEFORE_DTX :: 10
SE_MAX_CONSECUTIVE_DTX :: 20
SE_VAD_NO_ACTIVITY :: 0
SE_LTP_MEM_LENGTH_MS :: 20
SE_SUB_FRAME_LENGTH_MS :: 5
SE_MAX_FRAME_LENGTH_MS :: 20
SE_LA_PITCH_MS :: 2
SE_LA_PITCH_MAX :: SE_LA_PITCH_MS * MAX_FS_KHZ
SE_MAX_FIND_PITCH_LPC_ORDER :: 16
SE_FIND_PITCH_LPC_WIN_MS :: 20 + (SE_LA_PITCH_MS << 1)
SE_FIND_PITCH_LPC_WIN_MS_2_SF :: 10 + (SE_LA_PITCH_MS << 1)
SE_FIND_PITCH_LPC_WIN_MAX :: SE_FIND_PITCH_LPC_WIN_MS * MAX_FS_KHZ
SE_LA_SHAPE_MS :: 5
SE_LA_SHAPE_MAX :: SE_LA_SHAPE_MS * MAX_FS_KHZ
SE_SHAPE_LPC_WIN_MAX :: 15 * MAX_FS_KHZ
SE_MIN_QGAIN_DB :: 2
SE_MIN_LPC_ORDER :: 10
SE_MAX_SHAPE_LPC_ORDER :: 24
SE_HARM_SHAPE_FIR_TAPS :: 3
SE_MAX_DEL_DEC_STATES :: 4
SE_DECISION_DELAY :: 40
SE_NSQ_LPC_BUF_LENGTH :: MAX_LPC_ORDER
SE_VAD_N_BANDS :: 4
SE_VAD_INTERNAL_SUBFRAMES_LOG2 :: 2
SE_VAD_INTERNAL_SUBFRAMES :: 1 << SE_VAD_INTERNAL_SUBFRAMES_LOG2
SE_VAD_NOISE_LEVEL_SMOOTH_COEF_Q16 :: 1024
SE_VAD_NOISE_LEVELS_BIAS :: 50
SE_VAD_NEGATIVE_OFFSET_Q5 :: 128
SE_VAD_SNR_FACTOR_Q16 :: 45000
SE_VAD_SNR_SMOOTH_COEF_Q18 :: 4096
SE_NLSF_W_Q :: 2
SE_NLSF_QUANT_MAX_AMPLITUDE_EXT :: 10
SE_NLSF_QUANT_DEL_DEC_STATES_LOG2 :: 2
SE_NLSF_QUANT_DEL_DEC_STATES :: 1 << SE_NLSF_QUANT_DEL_DEC_STATES_LOG2
SE_TRANSITION_NB :: 3
SE_TRANSITION_NA :: 2
SE_TRANSITION_INT_NUM :: 5
SE_TRANSITION_FRAMES :: 5120 / 20
SE_STEREO_QUANT_TAB_SIZE :: 16
SE_STEREO_QUANT_SUB_STEPS :: 5
SE_BITRESERVOIR_DECAY_TIME_MS :: 500
SE_MAX_BANDWIDTH_SWITCH_DELAY_MS :: 5000
SE_VARIABLE_HP_MIN_CUTOFF_HZ :: 60
SE_VARIABLE_HP_MAX_CUTOFF_HZ :: 100
SE_PE_MIN_COMPLEX :: 0
SE_PE_MID_COMPLEX :: 1
SE_PE_MAX_COMPLEX :: 2
SE_PE_MAX_NB_SUBFR :: 4
SE_PE_SUBFR_LENGTH_MS :: 5
SE_PE_LTP_MEM_LENGTH_MS :: 4 * SE_PE_SUBFR_LENGTH_MS
SE_PE_MAX_FRAME_LENGTH_MS :: SE_PE_LTP_MEM_LENGTH_MS + SE_PE_MAX_NB_SUBFR * SE_PE_SUBFR_LENGTH_MS
SE_PE_MAX_LAG :: PE_MAX_LAG_MS * MAX_FS_KHZ
SE_PE_D_SRCH_LENGTH :: 24
SE_PE_NB_STAGE3_LAGS :: 5
SE_PE_NB_CBKS_STAGE2 :: 3
SE_PE_NB_CBKS_STAGE2_EXT :: 11
SE_PE_NB_CBKS_STAGE3_10MS :: 12
SE_PE_NB_CBKS_STAGE2_10MS :: 3

// SILK_FIX_CONST values (computed exactly as the C macros evaluate them)
SE_FIX_SPEECH_ACTIVITY_DTX_THRES_Q8 :: 13
SE_FIX_LBRR_SPEECH_ACTIVITY_THRES_Q8 :: 77
SE_FIX_SWITCH_SLOPE_Q24 :: 3188 // (1 - 0.05f) / 5000, Q24
SE_FIX_VARIABLE_HP_MAX_DELTA_FREQ_Q7 :: 51
SE_FIX_VARIABLE_HP_MIN_CUTOFF_Q16 :: 3932160
SE_FIX_VARIABLE_HP_SMTH_COEF1_Q16 :: 6554
SE_FIX_WARPING_MULTIPLIER_Q16 :: 983
SE_FIX_MAX_SUM_LOG_GAIN_Q7 :: 5333

Silk_Enc_Control :: struct {
	n_channels_api, n_channels_internal:                                                         i32,
	api_sample_rate, max_internal_sample_rate, min_internal_sample_rate, desired_internal_sample_rate: i32,
	payload_size_ms, bit_rate, packet_loss_percentage, complexity:                               i32,
	use_inband_fec, lbrr_coded, use_dtx, use_cbr, max_bits, to_mono, opus_can_switch, reduced_dependency: i32,
	internal_sample_rate, allow_bandwidth_switch, in_wb_mode_without_variable_lp, stereo_width_q14, switch_ready, signal_type, offset: i32,
}

Silk_NSQ_State :: struct {
	xq:               [2 * MAX_FRAME_LENGTH]i16,
	sltp_shp_q14:     [2 * MAX_FRAME_LENGTH]i32,
	slpc_q14:         [MAX_SUB_FRAME_LENGTH + SE_NSQ_LPC_BUF_LENGTH]i32,
	sar2_q14:         [SE_MAX_SHAPE_LPC_ORDER]i32,
	slf_ar_shp_q14:   i32,
	sdiff_shp_q14:    i32,
	lag_prev:         i32,
	sltp_buf_idx:     i32,
	sltp_shp_buf_idx: i32,
	rand_seed:        i32,
	prev_gain_q16:    i32,
	rewhite_flag:     i32,
}

Silk_VAD_State :: struct {
	ana_state:          [2]i32,
	ana_state1:         [2]i32,
	ana_state2:         [2]i32,
	xnrg_subfr:         [SE_VAD_N_BANDS]i32,
	nrg_ratio_smth_q8:  [SE_VAD_N_BANDS]i32,
	hp_state:           i16,
	nl:                 [SE_VAD_N_BANDS]i32,
	inv_nl:             [SE_VAD_N_BANDS]i32,
	noise_level_bias:   [SE_VAD_N_BANDS]i32,
	counter:            i32,
}

Silk_LP_State :: struct {
	in_lp_state:         [2]i32,
	transition_frame_no: i32,
	mode:                i32,
	saved_fs_khz:        i32,
}

Silk_Stereo_Enc_State :: struct {
	pred_prev_q13:   [2]i16,
	smid:            [2]i16,
	sside:           [2]i16,
	mid_side_amp_q0: [4]i32,
	smth_width_q14:  i16,
	width_prev_q14:  i16,
	silent_side_len: i16,
	pred_ix:         [MAX_FRAMES_PER_PACKET][2][3]i8,
	mid_only_flags:  [MAX_FRAMES_PER_PACKET]i8,
}

Silk_Enc_Common :: struct {
	in_hp_state:                    [2]i32,
	variable_hp_smth1_q15:          i32,
	variable_hp_smth2_q15:          i32,
	slp:                            Silk_LP_State,
	svad:                           Silk_VAD_State,
	snsq:                           Silk_NSQ_State,
	prev_nlsfq_q15:                 [MAX_LPC_ORDER]i16,
	speech_activity_q8:             i32,
	allow_bandwidth_switch:         i32,
	lbrr_prev_last_gain_index:      i8,
	prev_signal_type:               i8,
	prev_lag:                       i32,
	pitch_lpc_win_length:           i32,
	max_pitch_lag:                  i32,
	api_fs_hz:                      i32,
	prev_api_fs_hz:                 i32,
	max_internal_fs_hz:             i32,
	min_internal_fs_hz:             i32,
	desired_internal_fs_hz:         i32,
	fs_khz:                         i32,
	nb_subfr:                       i32,
	frame_length:                   i32,
	subfr_length:                   i32,
	ltp_mem_length:                 i32,
	la_pitch:                       i32,
	la_shape:                       i32,
	shape_win_length:               i32,
	target_rate_bps:                i32,
	packet_size_ms:                 i32,
	packet_loss_perc:               i32,
	frame_counter:                  i32,
	complexity:                     i32,
	n_states_delayed_decision:      i32,
	use_interpolated_nlsfs:         i32,
	shaping_lpc_order:              i32,
	predict_lpc_order:              i32,
	pitch_estimation_complexity:    i32,
	pitch_estimation_lpc_order:     i32,
	pitch_estimation_threshold_q16: i32,
	sum_log_gain_q7:                i32,
	nlsf_msvq_survivors:            i32,
	first_frame_after_reset:        i32,
	controlled_since_last_payload:  i32,
	warping_q16:                    i32,
	use_cbr:                        i32,
	prefill_flag:                   i32,
	pitch_lag_low_bits_icdf:        []u8,
	pitch_contour_icdf:             []u8,
	nlsf_cb:                        ^NLSF_CB,
	input_quality_bands_q15:        [SE_VAD_N_BANDS]i32,
	input_tilt_q15:                 i32,
	snr_db_q7:                      i32,
	vad_flags:                      [MAX_FRAMES_PER_PACKET]i8,
	lbrr_flag:                      i8,
	lbrr_flags:                     [MAX_FRAMES_PER_PACKET]i32,
	indices:                        Side_Info,
	pulses:                         [MAX_FRAME_LENGTH]i8,
	input_buf:                      [MAX_FRAME_LENGTH + 2]i16,
	input_buf_ix:                   i32,
	n_frames_per_packet:            i32,
	n_frames_encoded:               i32,
	n_channels_api:                 i32,
	n_channels_internal:            i32,
	channel_nb:                     i32,
	frames_since_onset:             i32,
	ec_prev_signal_type:            i32,
	ec_prev_lag_index:              i16,
	resampler_state:                Resampler,
	use_dtx:                        i32,
	in_dtx:                         i32,
	no_speech_counter:              i32,
	use_inband_fec:                 i32,
	lbrr_enabled:                   i32,
	lbrr_gain_increases:            i32,
	indices_lbrr:                   [MAX_FRAMES_PER_PACKET]Side_Info,
	pulses_lbrr:                    [MAX_FRAMES_PER_PACKET][MAX_FRAME_LENGTH]i8,
}

Silk_Shape_State :: struct {
	last_gain_index:      i8,
	harm_shape_gain_smth: f32,
	tilt_smth:            f32,
}

Silk_Enc_Chan :: struct {
	cmn:      Silk_Enc_Common,
	shape:    Silk_Shape_State,
	x_buf:    [2 * MAX_FRAME_LENGTH + SE_LA_SHAPE_MAX]f32,
	ltp_corr: f32,
}

Silk_Enc_Ctrl :: struct {
	gains:               [MAX_NB_SUBFR]f32,
	pred_coef:           [2][MAX_LPC_ORDER]f32,
	ltp_coef:            [LTP_ORDER * MAX_NB_SUBFR]f32,
	ltp_scale:           f32,
	pitch_l:             [MAX_NB_SUBFR]i32,
	ar:                  [MAX_NB_SUBFR * SE_MAX_SHAPE_LPC_ORDER]f32,
	lf_ma_shp:           [MAX_NB_SUBFR]f32,
	lf_ar_shp:           [MAX_NB_SUBFR]f32,
	tilt:                [MAX_NB_SUBFR]f32,
	harm_shape_gain:     [MAX_NB_SUBFR]f32,
	lambda:              f32,
	input_quality:       f32,
	coding_quality:      f32,
	pred_gain:           f32,
	ltp_red_cod_gain:    f32,
	res_nrg:             [MAX_NB_SUBFR]f32,
	gains_unq_q16:       [MAX_NB_SUBFR]i32,
	last_gain_index_prev: i8,
}

Silk_Encoder :: struct {
	state:                        [SE_NUM_CHANNELS]Silk_Enc_Chan,
	stereo:                       Silk_Stereo_Enc_State,
	n_bits_used_lbrr:             i32,
	n_bits_exceeded:              i32,
	n_channels_api:               i32,
	n_channels_internal:          i32,
	n_prev_channels_internal:     i32,
	time_since_switch_allowed_ms: i32,
	allow_bandwidth_switch:       i32,
	prev_decode_only_middle:      i32,
}

// ---- small tables

@(rodata)
silk_enc_target_rate_nb_21 := [117 - 10]u8 {
	0, 15, 39, 52, 61, 68,
	74, 79, 84, 88, 92, 95, 99, 102, 105, 108, 111, 114, 117, 119, 122, 124,
	126, 129, 131, 133, 135, 137, 139, 142, 143, 145, 147, 149, 151, 153, 155, 157,
	158, 160, 162, 163, 165, 167, 168, 170, 171, 173, 174, 176, 177, 179, 180, 182,
	183, 185, 186, 187, 189, 190, 192, 193, 194, 196, 197, 199, 200, 201, 203, 204,
	205, 207, 208, 209, 211, 212, 213, 215, 216, 217, 219, 220, 221, 223, 224, 225,
	227, 228, 230, 231, 232, 234, 235, 236, 238, 239, 241, 242, 243, 245, 246, 248,
	249, 250, 252, 253, 255,
}

@(rodata)
silk_enc_target_rate_mb_21 := [165 - 10]u8 {
	0, 0, 28, 43, 52, 59,
	65, 70, 74, 78, 81, 85, 87, 90, 93, 95, 98, 100, 102, 105, 107, 109,
	111, 113, 115, 116, 118, 120, 122, 123, 125, 127, 128, 130, 131, 133, 134, 136,
	137, 138, 140, 141, 143, 144, 145, 147, 148, 149, 151, 152, 153, 154, 156, 157,
	158, 159, 160, 162, 163, 164, 165, 166, 167, 168, 169, 171, 172, 173, 174, 175,
	176, 177, 178, 179, 180, 181, 182, 183, 184, 185, 186, 187, 188, 188, 189, 190,
	191, 192, 193, 194, 195, 196, 197, 198, 199, 200, 201, 202, 203, 203, 204, 205,
	206, 207, 208, 209, 210, 211, 212, 213, 214, 214, 215, 216, 217, 218, 219, 220,
	221, 222, 223, 224, 224, 225, 226, 227, 228, 229, 230, 231, 232, 233, 234, 235,
	236, 236, 237, 238, 239, 240, 241, 242, 243, 244, 245, 246, 247, 248, 249, 250,
	251, 252, 253, 254, 255,
}

@(rodata)
silk_enc_target_rate_wb_21 := [201 - 10]u8 {
	0, 0, 0, 8, 29, 41,
	49, 56, 62, 66, 70, 74, 77, 80, 83, 86, 88, 91, 93, 95, 97, 99,
	101, 103, 105, 107, 108, 110, 112, 113, 115, 116, 118, 119, 121, 122, 123, 125,
	126, 127, 129, 130, 131, 132, 134, 135, 136, 137, 138, 140, 141, 142, 143, 144,
	145, 146, 147, 148, 149, 150, 151, 152, 153, 154, 156, 157, 158, 159, 159, 160,
	161, 162, 163, 164, 165, 166, 167, 168, 169, 170, 171, 171, 172, 173, 174, 175,
	176, 177, 177, 178, 179, 180, 181, 181, 182, 183, 184, 185, 185, 186, 187, 188,
	189, 189, 190, 191, 192, 192, 193, 194, 195, 195, 196, 197, 198, 198, 199, 200,
	200, 201, 202, 203, 203, 204, 205, 206, 206, 207, 208, 209, 209, 210, 211, 211,
	212, 213, 214, 214, 215, 216, 216, 217, 218, 219, 219, 220, 221, 221, 222, 223,
	224, 224, 225, 226, 226, 227, 228, 229, 229, 230, 231, 232, 232, 233, 234, 234,
	235, 236, 237, 237, 238, 239, 240, 240, 241, 242, 243, 243, 244, 245, 246, 246,
	247, 248, 249, 249, 250, 251, 252, 253, 255,
}

@(rodata)
silk_enc_sigm_lut_slope_q10 := [6]i32{237, 153, 73, 30, 12, 7}
@(rodata)
silk_enc_sigm_lut_pos_q15 := [6]i32{16384, 23955, 28861, 31213, 32178, 32548}
@(rodata)
silk_enc_sigm_lut_neg_q15 := [6]i32{16384, 8812, 3906, 1554, 589, 219}
@(rodata)
silk_enc_vad_tilt_weights := [SE_VAD_N_BANDS]i32{30000, 6000, -12000, -12000}
@(rodata)
silk_enc_delay_matrix := [5][3]i8{{6, 0, 3}, {0, 7, 3}, {0, 1, 10}, {0, 2, 6}, {18, 10, 12}}

// ---- helpers

silk_add_pos_sat32 :: #force_inline proc "contextless" (a, b: i32) -> i32 {
	s := u32(a) + u32(b)
	return s & 0x80000000 != 0 ? I32_MAX : i32(s)
}

silk_sigm_q15 :: proc "contextless" (in_q5_: i32) -> i32 {
	in_q5 := in_q5_
	if in_q5 < 0 {
		in_q5 = -in_q5
		if in_q5 >= 6 * 32 do return 0
		ind := in_q5 >> 5
		return silk_enc_sigm_lut_neg_q15[ind] - smulbb(silk_enc_sigm_lut_slope_q10[ind], in_q5 & 0x1F)
	}
	if in_q5 >= 6 * 32 do return 32767
	ind := in_q5 >> 5
	return silk_enc_sigm_lut_pos_q15[ind] + smulbb(silk_enc_sigm_lut_slope_q10[ind], in_q5 & 0x1F)
}

// silk_sigmoid: (float)(1.0 / (1.0 + exp(-x))) in double precision
silk_sigmoid_flp :: #force_inline proc "contextless" (x: f32) -> f32 {
	return f32(1.0 / (1.0 + libc.exp(-f64(x))))
}

// silk_log2: (float)(3.32192809488736 * log10(x))
silk_log2_flp :: #force_inline proc "contextless" (x: f64) -> f32 {
	return f32(3.32192809488736 * libc.log10(x))
}

silk_pow_f :: #force_inline proc "contextless" (x, y: f64) -> f64 {return libc.pow(x, y)}

silk_f2s :: #force_inline proc "contextless" (x: f32) -> i16 {return i16(sat16(float2int(x)))}

silk_abs_f32 :: #force_inline proc "contextless" (x: f32) -> f32 {return x < 0 ? -x : x}

silk_insertion_sort_increasing :: proc "contextless" (a: []i32, idx: []i32, L, K: int) {
	for i in 0 ..< K do idx[i] = i32(i)
	for i in 1 ..< K {
		value := a[i]
		j := i - 1
		for ; j >= 0 && value < a[j]; j -= 1 {
			a[j + 1] = a[j]
			idx[j + 1] = idx[j]
		}
		a[j + 1] = value
		idx[j + 1] = i32(i)
	}
	for i in K ..< L {
		value := a[i]
		if value < a[K - 1] {
			j := K - 2
			for ; j >= 0 && value < a[j]; j -= 1 {
				a[j + 1] = a[j]
				idx[j + 1] = idx[j]
			}
			a[j + 1] = value
			idx[j + 1] = i32(i)
		}
	}
}

silk_insertion_sort_decreasing_flp :: proc "contextless" (a: []f32, idx: []i32, L, K: int) {
	for i in 0 ..< K do idx[i] = i32(i)
	for i in 1 ..< K {
		value := a[i]
		j := i - 1
		for ; j >= 0 && value > a[j]; j -= 1 {
			a[j + 1] = a[j]
			idx[j + 1] = idx[j]
		}
		a[j + 1] = value
		idx[j + 1] = i32(i)
	}
	for i in K ..< L {
		value := a[i]
		if value > a[K - 1] {
			j := K - 2
			for ; j >= 0 && value > a[j]; j -= 1 {
				a[j + 1] = a[j]
				idx[j + 1] = idx[j]
			}
			a[j + 1] = value
			idx[j + 1] = i32(i)
		}
	}
}

silk_energy_flp :: proc "contextless" (data: []f32, n: int) -> f64 {
	result: f64 = 0
	i := 0
	for ; i < n - 3; i += 4 {
		result += f64(data[i + 0]) * f64(data[i + 0]) + f64(data[i + 1]) * f64(data[i + 1]) + f64(data[i + 2]) * f64(data[i + 2]) + f64(data[i + 3]) * f64(data[i + 3])
	}
	for ; i < n; i += 1 do result += f64(data[i]) * f64(data[i])
	return result
}

silk_inner_product_flp :: proc "contextless" (d1, d2: []f32, n: int) -> f64 {
	result: f64 = 0
	i := 0
	for ; i < n - 3; i += 4 {
		result += f64(d1[i + 0]) * f64(d2[i + 0]) + f64(d1[i + 1]) * f64(d2[i + 1]) + f64(d1[i + 2]) * f64(d2[i + 2]) + f64(d1[i + 3]) * f64(d2[i + 3])
	}
	for ; i < n; i += 1 do result += f64(d1[i]) * f64(d2[i])
	return result
}

silk_autocorrelation_flp :: proc "contextless" (results: []f32, input: []f32, input_size: int, correlation_count_: int) {
	correlation_count := min(correlation_count_, input_size)
	for i in 0 ..< correlation_count {
		results[i] = f32(silk_inner_product_flp(input, input[i:], input_size - i))
	}
}

silk_schur_flp :: proc "contextless" (refl_coef: []f32, auto_corr: []f32, order: int) -> f32 {
	C: [24 + 1][2]f64
	for k in 0 ..= order {
		C[k][0] = f64(auto_corr[k])
		C[k][1] = f64(auto_corr[k])
	}
	for k in 0 ..< order {
		d := C[0][1]
		if !(d > f64(f32(1e-9))) do d = f64(f32(1e-9))
		rc_tmp := -C[k + 1][0] / d
		refl_coef[k] = f32(rc_tmp)
		for n in 0 ..< order - k {
			ctmp1 := C[n + k + 1][0]
			ctmp2 := C[n][1]
			C[n + k + 1][0] = ctmp1 + ctmp2 * rc_tmp
			C[n][1] = ctmp2 + ctmp1 * rc_tmp
		}
	}
	return f32(C[0][1])
}

silk_k2a_flp :: proc "contextless" (A: []f32, rc: []f32, order: int) {
	for k in 0 ..< order {
		rck := rc[k]
		for n in 0 ..< (k + 1) >> 1 {
			tmp1 := A[n]
			tmp2 := A[k - n - 1]
			A[n] = tmp1 + tmp2 * rck
			A[k - n - 1] = tmp2 + tmp1 * rck
		}
		A[k] = -rck
	}
}

silk_bwexpander_flp :: proc "contextless" (ar: []f32, d: int, chirp: f32) {
	cfac := chirp
	for i in 0 ..< d - 1 {
		ar[i] *= cfac
		cfac *= chirp
	}
	ar[d - 1] *= cfac
}

// r_LPC[ix] = s[ix] - sum_{j<order} s[ix-1-j]*coef[j], left to right
silk_lpc_analysis_filter_flp :: proc "contextless" (r_lpc: []f32, pred_coef: []f32, s: []f32, length: int, order: int) {
	for ix in order ..< length {
		p := s[ix - order:ix]
		pred: f32 = p[order - 1] * pred_coef[0]
		for j in 1 ..< order do pred += p[order - 1 - j] * pred_coef[j]
		r_lpc[ix] = s[ix] - pred
	}
	for i in 0 ..< order do r_lpc[i] = 0
}

silk_apply_sine_window_flp :: proc "contextless" (px_win: []f32, px: []f32, win_type: int, length: int) {
	pi := f32(3.1415926536)
	freq := pi / f32(length + 1)
	c := 2.0 - freq * freq
	S0, S1: f32
	if win_type < 2 {
		S0 = 0
		S1 = freq
	} else {
		S0 = 1
		S1 = 0.5 * c
	}
	for k := 0; k < length; k += 4 {
		px_win[k + 0] = px[k + 0] * 0.5 * (S0 + S1)
		px_win[k + 1] = px[k + 1] * S1
		S0 = c * S1 - S0
		px_win[k + 2] = px[k + 2] * 0.5 * (S1 + S0)
		px_win[k + 3] = px[k + 3] * S0
		S1 = c * S0 - S1
	}
}

silk_scale_copy_vector_flp :: proc "contextless" (out: []f32, in_: []f32, gain: f32, n: int) {
	for i in 0 ..< n do out[i] = gain * in_[i]
}

silk_scale_vector_flp :: proc "contextless" (data: []f32, gain: f32, n: int) {
	for i in 0 ..< n do data[i] *= gain
}

silk_interpolate :: proc "contextless" (xi: []i16, x0: []i16, x1: []i16, ifact_q2: i32, d: int) {
	for i in 0 ..< d {
		xi[i] = i16(i32(x0[i]) + (smulbb(i32(x1[i]) - i32(x0[i]), ifact_q2) >> 2))
	}
}

silk_a2nlsf_flp :: proc "contextless" (nlsf_q15: []i16, pAR: []f32, order: int) {
	a_fix_q16: [MAX_LPC_ORDER]i32
	for i in 0 ..< order do a_fix_q16[i] = float2int(pAR[i] * 65536.0)
	silk_a2nlsf(nlsf_q15, a_fix_q16[:], order)
}

silk_nlsf2a_flp :: proc "contextless" (pAR: []f32, nlsf_q15: []i16, order: int) {
	a_fix_q12: [MAX_LPC_ORDER]i16
	nlsf2a(a_fix_q12[:], nlsf_q15, order)
	for i in 0 ..< order do pAR[i] = f32(a_fix_q12[i]) * (1.0 / 4096.0)
}
