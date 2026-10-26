package opus

// SILK decoder (fixed point, bit-exact with the reference).

MAX_NB_SUBFR :: 4
MAX_FS_KHZ :: 16
MAX_FRAME_LENGTH :: 20 * MAX_FS_KHZ
MAX_SUB_FRAME_LENGTH :: 5 * MAX_FS_KHZ
MAX_LPC_ORDER :: 16
LTP_ORDER :: 5
MAX_FRAMES_PER_PACKET :: 3
SHELL_CODEC_FRAME_LENGTH :: 16
LOG2_SHELL_CODEC_FRAME_LENGTH :: 4
MAX_NB_SHELL_BLOCKS :: MAX_FRAME_LENGTH / SHELL_CODEC_FRAME_LENGTH
N_RATE_LEVELS :: 10
SILK_MAX_PULSES :: 16
NLSF_QUANT_MAX_AMPLITUDE :: 4
TYPE_NO_VOICE_ACTIVITY :: 0
TYPE_UNVOICED :: 1
TYPE_VOICED :: 2
CODE_INDEPENDENTLY :: 0
CODE_INDEPENDENTLY_NO_LTP_SCALING :: 1
CODE_CONDITIONALLY :: 2
FLAG_DECODE_NORMAL :: 0
FLAG_PACKET_LOST :: 1
FLAG_DECODE_LBRR :: 2
STEREO_INTERP_LEN_MS :: 8
BWE_AFTER_LOSS_Q16 :: 63570
QUANT_LEVEL_ADJUST_Q10 :: 80
CNG_BUF_MASK_MAX :: 255
CNG_GAIN_SMTH_Q16 :: 4634
CNG_NLSF_SMTH_Q16 :: 16348
PE_MIN_LAG_MS :: 2
PE_MAX_LAG_MS :: 18
MIN_DELTA_GAIN_QUANT :: -4
MAX_DELTA_GAIN_QUANT :: 36
N_LEVELS_QGAIN :: 64
GAIN_OFFSET :: (2 * 128) / 6 + 16 * 128
INV_SCALE_Q16 :: (65536 * (((88 - 2) * 128) / 6)) / (N_LEVELS_QGAIN - 1)

// PLC
V_PITCH_GAIN_START_MIN_Q14 :: 11469
V_PITCH_GAIN_START_MAX_Q14 :: 15565
MAX_PITCH_LAG_MS :: 18
RAND_BUF_SIZE :: 128
RAND_BUF_MASK :: RAND_BUF_SIZE - 1
LOG2_INV_LPC_GAIN_HIGH_THRES :: 3
LOG2_INV_LPC_GAIN_LOW_THRES :: 8
PITCH_DRIFT_FAC_Q16 :: 655
BWE_COEF_Q16 :: 64881 // SILK_FIX_CONST(0.99, 16)

NLSF_CB :: struct {
	n_vectors:            i32,
	order:                i32,
	quant_step_size_q16:  i32,
	inv_quant_step_q6:    i32,
	cb1_nlsf_q8:          []u8,
	cb1_wght_q9:          []i16,
	cb1_icdf:             []u8,
	pred_q8:              []u8,
	ec_sel:               []u8,
	ec_icdf:              []u8,
	ec_rates_q5:          []u8,
	delta_min_q15:        []i16,
}

silk_nlsf_cb_nb_mb := NLSF_CB {
	32, 10, 11796, 356, // SILK_FIX_CONST(0.18,16), SILK_FIX_CONST(1/0.18,6)
	silk_NLSF_CB1_NB_MB_Q8[:], silk_NLSF_CB1_Wght_Q9[:], silk_NLSF_CB1_iCDF_NB_MB[:], silk_NLSF_PRED_NB_MB_Q8[:],
	silk_NLSF_CB2_SELECT_NB_MB[:], silk_NLSF_CB2_iCDF_NB_MB[:], silk_NLSF_CB2_BITS_NB_MB_Q5[:], silk_NLSF_DELTA_MIN_NB_MB_Q15[:],
}

silk_nlsf_cb_wb := NLSF_CB {
	32, 16, 9830, 427, // SILK_FIX_CONST(0.15,16), SILK_FIX_CONST(1/0.15,6)
	silk_NLSF_CB1_WB_Q8[:], silk_NLSF_CB1_WB_Wght_Q9[:], silk_NLSF_CB1_iCDF_WB[:], silk_NLSF_PRED_WB_Q8[:],
	silk_NLSF_CB2_SELECT_WB[:], silk_NLSF_CB2_iCDF_WB[:], silk_NLSF_CB2_BITS_WB_Q5[:], silk_NLSF_DELTA_MIN_WB_Q15[:],
}

Side_Info :: struct {
	gains_indices:       [MAX_NB_SUBFR]i8,
	ltp_index:           [MAX_NB_SUBFR]i8,
	nlsf_indices:        [MAX_LPC_ORDER + 1]i8,
	lag_index:           i16,
	contour_index:       i8,
	signal_type:         i8,
	quant_offset_type:   i8,
	nlsf_interp_coef_q2: i8,
	per_index:           i8,
	ltp_scale_index:     i8,
	seed:                i8,
}

Resampler :: struct {
	s_iir:        [6]i32,
	s_fir_i32:    [36]i32,
	s_fir_i16:    [36]i16,
	delay_buf:    [48]i16,
	function:     int,
	batch_size:   i32,
	inv_ratio_q16: i32,
	fir_order:    int,
	fir_fracs:    i32,
	fs_in_khz:    i32,
	fs_out_khz:   i32,
	input_delay:  i32,
	coefs:        []i16,
}

PLC_State :: struct {
	pitch_l_q8:         i32,
	ltp_coef_q14:       [LTP_ORDER]i16,
	prev_lpc_q12:       [MAX_LPC_ORDER]i16,
	last_frame_lost:    bool,
	rand_seed:          i32,
	rand_scale_q14:     i16,
	conc_energy:        i32,
	conc_energy_shift:  i32,
	prev_ltp_scale_q14: i16,
	prev_gain_q16:      [2]i32,
	fs_khz:             i32,
	nb_subfr:           i32,
	subfr_length:       i32,
}

CNG_State :: struct {
	exc_buf_q14:      [MAX_FRAME_LENGTH]i32,
	smth_nlsf_q15:    [MAX_LPC_ORDER]i16,
	synth_state:      [MAX_LPC_ORDER]i32,
	smth_gain_q16:    i32,
	rand_seed:        i32,
	fs_khz:           i32,
}

Silk_Channel :: struct {
	prev_gain_q16:           i32,
	exc_q14:                 [MAX_FRAME_LENGTH]i32,
	slpc_q14_buf:            [MAX_LPC_ORDER]i32,
	out_buf:                 [MAX_FRAME_LENGTH + 2 * MAX_SUB_FRAME_LENGTH]i16,
	lag_prev:                i32,
	last_gain_index:         i8,
	fs_khz:                  i32,
	fs_api_hz:               i32,
	nb_subfr:                i32,
	frame_length:            i32,
	subfr_length:            i32,
	ltp_mem_length:          i32,
	lpc_order:               i32,
	prev_nlsf_q15:           [MAX_LPC_ORDER]i16,
	first_frame_after_reset: bool,
	pitch_lag_low_bits_icdf: []u8,
	pitch_contour_icdf:      []u8,
	n_frames_decoded:        i32,
	n_frames_per_packet:     i32,
	ec_prev_signal_type:     i32,
	ec_prev_lag_index:       i16,
	vad_flags:               [MAX_FRAMES_PER_PACKET]i32,
	lbrr_flag:               i32,
	lbrr_flags:              [MAX_FRAMES_PER_PACKET]i32,
	resampler:               Resampler,
	nlsf_cb:                 ^NLSF_CB,
	indices:                 Side_Info,
	cng:                     CNG_State,
	loss_cnt:                i32,
	prev_signal_type:        i32,
	plc:                     PLC_State,
}

Silk_Dec_Ctrl :: struct {
	pitch_l:       [MAX_NB_SUBFR]i32,
	gains_q16:     [MAX_NB_SUBFR]i32,
	pred_coef_q12: [2][MAX_LPC_ORDER]i16,
	ltp_coef_q14:  [LTP_ORDER * MAX_NB_SUBFR]i16,
	ltp_scale_q14: i32,
}

Silk_Dec_Control :: struct {
	n_channels_api:       i32,
	n_channels_internal:  i32,
	api_sample_rate:      i32,
	internal_sample_rate: i32,
	payload_size_ms:      i32,
	prev_pitch_lag:       i32,
}

Silk_Decoder :: struct {
	channel_state:           [2]Silk_Channel,
	stereo_pred_prev_q13:    [2]i16,
	stereo_s_mid:            [2]i16,
	stereo_s_side:           [2]i16,
	n_channels_api:          i32,
	n_channels_internal:     i32,
	prev_decode_only_middle: bool,
}

// ---------------------------------------------------------------------------

@(private = "file")
init_channel :: proc(ch: ^Silk_Channel) {
	ch^ = {}
	ch.first_frame_after_reset = true
	ch.prev_gain_q16 = 65536
	cng_reset(ch)
	plc_reset(ch)
}

silk_init_decoder :: proc(d: ^Silk_Decoder) {
	for n in 0 ..< 2 do init_channel(&d.channel_state[n])
	d.stereo_pred_prev_q13 = {}
	d.stereo_s_mid = {}
	d.stereo_s_side = {}
	d.prev_decode_only_middle = false
}

@(private = "file")
decoder_set_fs :: proc(ch: ^Silk_Channel, fs_khz: i32, fs_api_hz: i32) -> int {
	ret := 0
	ch.subfr_length = 5 * fs_khz
	frame_length := ch.nb_subfr * ch.subfr_length
	if ch.fs_khz != fs_khz || ch.fs_api_hz != fs_api_hz {
		ret += resampler_init(&ch.resampler, fs_khz * 1000, fs_api_hz)
		ch.fs_api_hz = fs_api_hz
	}
	if ch.fs_khz != fs_khz || frame_length != ch.frame_length {
		if fs_khz == 8 {
			ch.pitch_contour_icdf = ch.nb_subfr == MAX_NB_SUBFR ? silk_pitch_contour_NB_iCDF[:] : silk_pitch_contour_10_ms_NB_iCDF[:]
		} else {
			ch.pitch_contour_icdf = ch.nb_subfr == MAX_NB_SUBFR ? silk_pitch_contour_iCDF[:] : silk_pitch_contour_10_ms_iCDF[:]
		}
		if ch.fs_khz != fs_khz {
			ch.ltp_mem_length = 20 * fs_khz
			if fs_khz == 8 || fs_khz == 12 {
				ch.lpc_order = 10
				ch.nlsf_cb = &silk_nlsf_cb_nb_mb
			} else {
				ch.lpc_order = MAX_LPC_ORDER
				ch.nlsf_cb = &silk_nlsf_cb_wb
			}
			switch fs_khz {
			case 16: ch.pitch_lag_low_bits_icdf = silk_uniform8_iCDF[:]
			case 12: ch.pitch_lag_low_bits_icdf = silk_uniform6_iCDF[:]
			case: ch.pitch_lag_low_bits_icdf = silk_uniform4_iCDF[:]
			}
			ch.first_frame_after_reset = true
			ch.lag_prev = 100
			ch.last_gain_index = 10
			ch.prev_signal_type = TYPE_NO_VOICE_ACTIVITY
			ch.out_buf = {}
			ch.slpc_q14_buf = {}
		}
		ch.fs_khz = fs_khz
		ch.frame_length = frame_length
	}
	return ret
}

// ---- Resampler

@(rodata)
delay_matrix_dec := [3][5]i8{{4, 0, 2, 0, 0}, {0, 9, 4, 7, 4}, {0, 3, 12, 7, 7}}

@(private = "file")
rate_id :: #force_inline proc "contextless" (r: i32) -> i32 {
	return (((r >> 12) - i32(r > 16000)) >> u32(r > 24000)) - 1
}

RESAMPLER_COPY :: 0
RESAMPLER_UP2_HQ :: 1
RESAMPLER_IIR_FIR :: 2
RESAMPLER_DOWN_FIR :: 3

resampler_init :: proc(S: ^Resampler, fs_in, fs_out: i32) -> int {
	S^ = {}
	if (fs_in != 8000 && fs_in != 12000 && fs_in != 16000) || (fs_out != 8000 && fs_out != 12000 && fs_out != 16000 && fs_out != 24000 && fs_out != 48000) do return -1
	S.input_delay = i32(delay_matrix_dec[rate_id(fs_in)][rate_id(fs_out)])
	S.fs_in_khz = fs_in / 1000
	S.fs_out_khz = fs_out / 1000
	S.batch_size = S.fs_in_khz * 10
	up2x: u32 = 0
	if fs_out > fs_in {
		if fs_out == fs_in * 2 {
			S.function = RESAMPLER_UP2_HQ
		} else {
			S.function = RESAMPLER_IIR_FIR
			up2x = 1
		}
	} else if fs_out < fs_in {
		S.function = RESAMPLER_DOWN_FIR
		switch {
		case fs_out * 4 == fs_in * 3: S.fir_fracs, S.fir_order, S.coefs = 3, 18, silk_Resampler_3_4_COEFS[:]
		case fs_out * 3 == fs_in * 2: S.fir_fracs, S.fir_order, S.coefs = 2, 18, silk_Resampler_2_3_COEFS[:]
		case fs_out * 2 == fs_in: S.fir_fracs, S.fir_order, S.coefs = 1, 24, silk_Resampler_1_2_COEFS[:]
		case fs_out * 3 == fs_in: S.fir_fracs, S.fir_order, S.coefs = 1, 36, silk_Resampler_1_3_COEFS[:]
		case fs_out * 4 == fs_in: S.fir_fracs, S.fir_order, S.coefs = 1, 36, silk_Resampler_1_4_COEFS[:]
		case fs_out * 6 == fs_in: S.fir_fracs, S.fir_order, S.coefs = 1, 36, silk_Resampler_1_6_COEFS[:]
		case: return -1
		}
	} else {
		S.function = RESAMPLER_COPY
	}
	S.inv_ratio_q16 = ((fs_in << (14 + up2x)) / fs_out) << 2
	for smulww(S.inv_ratio_q16, fs_out) < (fs_in << up2x) do S.inv_ratio_q16 += 1
	return 0
}

@(rodata)
up2_hq_0 := [3]i32{1746, 14986, 39083 - 65536}
@(rodata)
up2_hq_1 := [3]i32{6854, 25769, 55542 - 65536}

@(private = "file")
resampler_up2_hq :: proc "contextless" (S: []i32, out: []i16, in_: []i16, len: int) {
	for k in 0 ..< len {
		in32 := i32(in_[k]) << 10
		Y := in32 - S[0]
		X := smulwb(Y, up2_hq_0[0])
		out32_1 := S[0] + X
		S[0] = in32 + X
		Y = out32_1 - S[1]
		X = smulwb(Y, up2_hq_0[1])
		out32_2 := S[1] + X
		S[1] = out32_1 + X
		Y = out32_2 - S[2]
		X = smlawb(Y, Y, up2_hq_0[2])
		out32_1 = S[2] + X
		S[2] = out32_2 + X
		out[2 * k] = i16(sat16(rshift_round(out32_1, 10)))
		Y = in32 - S[3]
		X = smulwb(Y, up2_hq_1[0])
		out32_1 = S[3] + X
		S[3] = in32 + X
		Y = out32_1 - S[4]
		X = smulwb(Y, up2_hq_1[1])
		out32_2 = S[4] + X
		S[4] = out32_1 + X
		Y = out32_2 - S[5]
		X = smlawb(Y, Y, up2_hq_1[2])
		out32_1 = S[5] + X
		S[5] = out32_2 + X
		out[2 * k + 1] = i16(sat16(rshift_round(out32_1, 10)))
	}
}

@(private = "file")
resampler_iir_fir :: proc "contextless" (S: ^Resampler, out_: []i16, in__: []i16, in_len_: i32) {
	buf: [2 * 480 + 8]i16
	copy(buf[:8], S.s_fir_i16[:8])
	inc := S.inv_ratio_q16
	out := out_
	in_ := in__
	in_len := in_len_
	n_in: i32
	oi := 0
	for {
		n_in = min(in_len, S.batch_size)
		resampler_up2_hq(S.s_iir[:], buf[8:], in_, int(n_in))
		max_index := n_in << (16 + 1)
		for index := i32(0); index < max_index; index += inc {
			ti := smulwb(index & 0xFFFF, 12)
			b := buf[index >> 16:]
			r := smulbb(i32(b[0]), i32(silk_resampler_frac_FIR_12[ti][0]))
			r = smlabb(r, i32(b[1]), i32(silk_resampler_frac_FIR_12[ti][1]))
			r = smlabb(r, i32(b[2]), i32(silk_resampler_frac_FIR_12[ti][2]))
			r = smlabb(r, i32(b[3]), i32(silk_resampler_frac_FIR_12[ti][3]))
			r = smlabb(r, i32(b[4]), i32(silk_resampler_frac_FIR_12[11 - ti][3]))
			r = smlabb(r, i32(b[5]), i32(silk_resampler_frac_FIR_12[11 - ti][2]))
			r = smlabb(r, i32(b[6]), i32(silk_resampler_frac_FIR_12[11 - ti][1]))
			r = smlabb(r, i32(b[7]), i32(silk_resampler_frac_FIR_12[11 - ti][0]))
			out[oi] = i16(sat16(rshift_round(r, 15)))
			oi += 1
		}
		in_ = in_[n_in:]
		in_len -= n_in
		if in_len > 0 {
			copy(buf[:8], buf[n_in << 1:(n_in << 1) + 8])
		} else {
			break
		}
	}
	copy(S.s_fir_i16[:8], buf[n_in << 1:(n_in << 1) + 8])
}

@(private = "file")
resampler_ar2 :: proc "contextless" (S: []i32, out_q8: []i32, in_: []i16, A_Q14: []i16, len: int) {
	for k in 0 ..< len {
		out32 := S[0] + (i32(in_[k]) << 8)
		out_q8[k] = out32
		out32 <<= 2
		S[0] = smlawb(S[1], out32, i32(A_Q14[0]))
		S[1] = smulwb(out32, i32(A_Q14[1]))
	}
}

@(private = "file")
resampler_down_fir :: proc "contextless" (S: ^Resampler, out: []i16, in__: []i16, in_len_: i32) {
	buf: [480 + 36]i32
	ord := S.fir_order
	copy(buf[:ord], S.s_fir_i32[:ord])
	fir := S.coefs[2:]
	inc := S.inv_ratio_q16
	in_ := in__
	in_len := in_len_
	n_in: i32
	oi := 0
	for {
		n_in = min(in_len, S.batch_size)
		resampler_ar2(S.s_iir[:], buf[ord:], in_, S.coefs, int(n_in))
		max_index := n_in << 16
		switch ord {
		case 18:
			for index := i32(0); index < max_index; index += inc {
				b := buf[index >> 16:]
				ii := smulwb(index & 0xFFFF, S.fir_fracs)
				ip := fir[9 * ii:]
				r := smulwb(b[0], i32(ip[0]))
				for t in 1 ..< 9 do r = smlawb(r, b[t], i32(ip[t]))
				ip = fir[9 * (S.fir_fracs - 1 - ii):]
				for t in 0 ..< 9 do r = smlawb(r, b[17 - t], i32(ip[t]))
				out[oi] = i16(sat16(rshift_round(r, 6)))
				oi += 1
			}
		case 24:
			for index := i32(0); index < max_index; index += inc {
				b := buf[index >> 16:]
				r := smulwb(b[0] + b[23], i32(fir[0]))
				for t in 1 ..< 12 do r = smlawb(r, b[t] + b[23 - t], i32(fir[t]))
				out[oi] = i16(sat16(rshift_round(r, 6)))
				oi += 1
			}
		case 36:
			for index := i32(0); index < max_index; index += inc {
				b := buf[index >> 16:]
				r := smulwb(b[0] + b[35], i32(fir[0]))
				for t in 1 ..< 18 do r = smlawb(r, b[t] + b[35 - t], i32(fir[t]))
				out[oi] = i16(sat16(rshift_round(r, 6)))
				oi += 1
			}
		}
		in_ = in_[n_in:]
		in_len -= n_in
		if in_len > 1 {
			copy(buf[:ord], buf[n_in:int(n_in) + ord])
		} else {
			break
		}
	}
	copy(S.s_fir_i32[:ord], buf[n_in:int(n_in) + ord])
}

resampler_run :: proc "contextless" (S: ^Resampler, out: []i16, in_: []i16, in_len: i32) {
	n := S.fs_in_khz - S.input_delay
	copy(S.delay_buf[S.input_delay:S.input_delay + n], in_[:n])
	switch S.function {
	case RESAMPLER_UP2_HQ:
		resampler_up2_hq(S.s_iir[:], out, S.delay_buf[:], int(S.fs_in_khz))
		resampler_up2_hq(S.s_iir[:], out[S.fs_out_khz:], in_[n:], int(in_len - S.fs_in_khz))
	case RESAMPLER_IIR_FIR:
		resampler_iir_fir(S, out, S.delay_buf[:], S.fs_in_khz)
		resampler_iir_fir(S, out[S.fs_out_khz:], in_[n:], in_len - S.fs_in_khz)
	case RESAMPLER_DOWN_FIR:
		resampler_down_fir(S, out, S.delay_buf[:], S.fs_in_khz)
		resampler_down_fir(S, out[S.fs_out_khz:], in_[n:], in_len - S.fs_in_khz)
	case:
		copy(out[:S.fs_in_khz], S.delay_buf[:S.fs_in_khz])
		copy(out[S.fs_out_khz:S.fs_out_khz + in_len - S.fs_in_khz], in_[n:n + in_len - S.fs_in_khz])
	}
	copy(S.delay_buf[:S.input_delay], in_[in_len - S.input_delay:in_len])
}

// ---- Indices / pulses

@(private = "file")
nlsf_unpack :: proc "contextless" (ec_ix: []i16, pred_q8: []u8, cb: ^NLSF_CB, cb1_index: i32) {
	sel := cb.ec_sel[cb1_index * cb.order / 2:]
	for i := i32(0); i < cb.order; i += 2 {
		entry := sel[i / 2]
		ec_ix[i] = i16(smulbb(i32((entry >> 1) & 7), 2 * NLSF_QUANT_MAX_AMPLITUDE + 1))
		pred_q8[i] = cb.pred_q8[i + i32(entry & 1) * (cb.order - 1)]
		ec_ix[i + 1] = i16(smulbb(i32((entry >> 5) & 7), 2 * NLSF_QUANT_MAX_AMPLITUDE + 1))
		pred_q8[i + 1] = cb.pred_q8[i + i32((entry >> 4) & 1) * (cb.order - 1) + 1]
	}
}

@(private = "file")
ltp_gain_icdf :: proc "contextless" (i: int) -> []u8 {
	switch i {
	case 0: return silk_LTP_gain_iCDF_0[:]
	case 1: return silk_LTP_gain_iCDF_1[:]
	}
	return silk_LTP_gain_iCDF_2[:]
}

@(private = "file")
ltp_vq :: proc "contextless" (per, ix, i: int) -> i8 {
	switch per {
	case 0: return silk_LTP_gain_vq_0[ix][i]
	case 1: return silk_LTP_gain_vq_1[ix][i]
	}
	return silk_LTP_gain_vq_2[ix][i]
}

@(private = "file")
decode_indices :: proc(ch: ^Silk_Channel, dec: ^Range, frame_index: i32, decode_lbrr: bool, cond_coding: int) {
	ix: i32
	if decode_lbrr || ch.vad_flags[frame_index] != 0 {
		ix = ec_dec_icdf(dec, silk_type_offset_VAD_iCDF[:], 8) + 2
	} else {
		ix = ec_dec_icdf(dec, silk_type_offset_no_VAD_iCDF[:], 8)
	}
	ind := &ch.indices
	ind.signal_type = i8(ix >> 1)
	ind.quant_offset_type = i8(ix & 1)
	if cond_coding == CODE_CONDITIONALLY {
		ind.gains_indices[0] = i8(ec_dec_icdf(dec, silk_delta_gain_iCDF[:], 8))
	} else {
		ind.gains_indices[0] = i8(ec_dec_icdf(dec, silk_gain_iCDF[ind.signal_type][:], 8) << 3)
		ind.gains_indices[0] += i8(ec_dec_icdf(dec, silk_uniform8_iCDF[:], 8))
	}
	for i in 1 ..< ch.nb_subfr do ind.gains_indices[i] = i8(ec_dec_icdf(dec, silk_delta_gain_iCDF[:], 8))
	cb := ch.nlsf_cb
	ind.nlsf_indices[0] = i8(ec_dec_icdf(dec, cb.cb1_icdf[(i32(ind.signal_type) >> 1) * cb.n_vectors:], 8))
	ec_ix: [MAX_LPC_ORDER]i16
	pred_q8: [MAX_LPC_ORDER]u8
	nlsf_unpack(ec_ix[:], pred_q8[:], cb, i32(ind.nlsf_indices[0]))
	for i in 0 ..< cb.order {
		ix = ec_dec_icdf(dec, cb.ec_icdf[ec_ix[i]:], 8)
		if ix == 0 {
			ix -= ec_dec_icdf(dec, silk_NLSF_EXT_iCDF[:], 8)
		} else if ix == 2 * NLSF_QUANT_MAX_AMPLITUDE {
			ix += ec_dec_icdf(dec, silk_NLSF_EXT_iCDF[:], 8)
		}
		ind.nlsf_indices[i + 1] = i8(ix - NLSF_QUANT_MAX_AMPLITUDE)
	}
	if ch.nb_subfr == MAX_NB_SUBFR {
		ind.nlsf_interp_coef_q2 = i8(ec_dec_icdf(dec, silk_NLSF_interpolation_factor_iCDF[:], 8))
	} else {
		ind.nlsf_interp_coef_q2 = 4
	}
	if ind.signal_type == TYPE_VOICED {
		decode_absolute := true
		if cond_coding == CODE_CONDITIONALLY && ch.ec_prev_signal_type == TYPE_VOICED {
			delta := i16(ec_dec_icdf(dec, silk_pitch_delta_iCDF[:], 8))
			if delta > 0 {
				delta -= 9
				ind.lag_index = ch.ec_prev_lag_index + delta
				decode_absolute = false
			}
		}
		if decode_absolute {
			ind.lag_index = i16(ec_dec_icdf(dec, silk_pitch_lag_iCDF[:], 8) * (ch.fs_khz >> 1))
			ind.lag_index += i16(ec_dec_icdf(dec, ch.pitch_lag_low_bits_icdf, 8))
		}
		ch.ec_prev_lag_index = ind.lag_index
		ind.contour_index = i8(ec_dec_icdf(dec, ch.pitch_contour_icdf, 8))
		ind.per_index = i8(ec_dec_icdf(dec, silk_LTP_per_index_iCDF[:], 8))
		for k in 0 ..< ch.nb_subfr do ind.ltp_index[k] = i8(ec_dec_icdf(dec, ltp_gain_icdf(int(ind.per_index)), 8))
		if cond_coding == CODE_INDEPENDENTLY {
			ind.ltp_scale_index = i8(ec_dec_icdf(dec, silk_LTPscale_iCDF[:], 8))
		} else {
			ind.ltp_scale_index = 0
		}
	}
	ch.ec_prev_signal_type = i32(ind.signal_type)
	ind.seed = i8(ec_dec_icdf(dec, silk_uniform4_iCDF[:], 8))
}

@(private = "file")
shell_table :: proc "contextless" (i: int) -> []u8 {
	switch i {
	case 0: return silk_shell_code_table0[:]
	case 1: return silk_shell_code_table1[:]
	case 2: return silk_shell_code_table2[:]
	}
	return silk_shell_code_table3[:]
}

@(private = "file")
decode_split :: #force_inline proc "contextless" (c1, c2: ^i16, dec: ^Range, p: i32, table: []u8) {
	if p > 0 {
		c1^ = i16(ec_dec_icdf(dec, table[silk_shell_code_table_offsets[p]:], 8))
		c2^ = i16(p) - c1^
	} else {
		c1^ = 0
		c2^ = 0
	}
}

@(private = "file")
shell_decoder :: proc "contextless" (p0: []i16, dec: ^Range, pulses4: i32) {
	p3: [2]i16
	p2: [4]i16
	p1: [8]i16
	t0, t1, t2, t3 := shell_table(0), shell_table(1), shell_table(2), shell_table(3)
	decode_split(&p3[0], &p3[1], dec, pulses4, t3)
	decode_split(&p2[0], &p2[1], dec, i32(p3[0]), t2)
	decode_split(&p1[0], &p1[1], dec, i32(p2[0]), t1)
	decode_split(&p0[0], &p0[1], dec, i32(p1[0]), t0)
	decode_split(&p0[2], &p0[3], dec, i32(p1[1]), t0)
	decode_split(&p1[2], &p1[3], dec, i32(p2[1]), t1)
	decode_split(&p0[4], &p0[5], dec, i32(p1[2]), t0)
	decode_split(&p0[6], &p0[7], dec, i32(p1[3]), t0)
	decode_split(&p2[2], &p2[3], dec, i32(p3[1]), t2)
	decode_split(&p1[4], &p1[5], dec, i32(p2[2]), t1)
	decode_split(&p0[8], &p0[9], dec, i32(p1[4]), t0)
	decode_split(&p0[10], &p0[11], dec, i32(p1[5]), t0)
	decode_split(&p1[6], &p1[7], dec, i32(p2[3]), t1)
	decode_split(&p0[12], &p0[13], dec, i32(p1[6]), t0)
	decode_split(&p0[14], &p0[15], dec, i32(p1[7]), t0)
}

@(private = "file")
decode_pulses :: proc "contextless" (dec: ^Range, pulses: []i16, signal_type, quant_offset_type: i32, frame_length: i32) {
	sum_pulses, n_lshifts: [MAX_NB_SHELL_BLOCKS + 1]i32
	rate_level := ec_dec_icdf(dec, silk_rate_levels_iCDF[signal_type >> 1][:], 8)
	iter := frame_length >> LOG2_SHELL_CODEC_FRAME_LENGTH
	if iter * SHELL_CODEC_FRAME_LENGTH < frame_length do iter += 1
	cdf := silk_pulses_per_block_iCDF[rate_level][:]
	for i in 0 ..< iter {
		n_lshifts[i] = 0
		sum_pulses[i] = ec_dec_icdf(dec, cdf, 8)
		for sum_pulses[i] == SILK_MAX_PULSES + 1 {
			n_lshifts[i] += 1
			sum_pulses[i] = ec_dec_icdf(dec, silk_pulses_per_block_iCDF[N_RATE_LEVELS - 1][(n_lshifts[i] == 10 ? 1 : 0):], 8)
		}
	}
	for i in 0 ..< iter {
		p := pulses[i * SHELL_CODEC_FRAME_LENGTH:]
		if sum_pulses[i] > 0 {
			shell_decoder(p, dec, sum_pulses[i])
		} else {
			for k in 0 ..< SHELL_CODEC_FRAME_LENGTH do p[k] = 0
		}
	}
	for i in 0 ..< iter {
		if n_lshifts[i] > 0 {
			nls := n_lshifts[i]
			p := pulses[i * SHELL_CODEC_FRAME_LENGTH:]
			for k in 0 ..< SHELL_CODEC_FRAME_LENGTH {
				abs_q := i32(p[k])
				for _ in 0 ..< nls {
					abs_q <<= 1
					abs_q += ec_dec_icdf(dec, silk_lsb_iCDF[:], 8)
				}
				p[k] = i16(abs_q)
			}
			sum_pulses[i] |= nls << 5
		}
	}
	// signs
	icdf: [2]u8
	icdf[1] = 0
	icdf_ptr := silk_sign_iCDF[smulbb(7, quant_offset_type + (signal_type << 1)):]
	length := (frame_length + SHELL_CODEC_FRAME_LENGTH / 2) >> LOG2_SHELL_CODEC_FRAME_LENGTH
	for i in 0 ..< length {
		p := sum_pulses[i]
		if p > 0 {
			icdf[0] = icdf_ptr[min(p & 0x1F, 6)]
			q := pulses[i * SHELL_CODEC_FRAME_LENGTH:]
			for j in 0 ..< SHELL_CODEC_FRAME_LENGTH {
				if q[j] > 0 {
					s := ec_dec_icdf(dec, icdf[:], 8)
					q[j] *= i16((s << 1) - 1)
				}
			}
		}
	}
}

// ---- Parameters

@(private = "file")
gains_dequant :: proc "contextless" (gain_q16: []i32, ind: []i8, prev_ind: ^i8, conditional: bool, nb_subfr: i32) {
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

@(private = "file")
nlsf_stabilize :: proc "contextless" (nlsf: []i16, delta_min: []i16, L: int) {
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
	// fallback
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

@(private = "file")
nlsf_decode :: proc "contextless" (nlsf_q15: []i16, indices: []i8, cb: ^NLSF_CB) {
	pred_q8: [MAX_LPC_ORDER]u8
	ec_ix: [MAX_LPC_ORDER]i16
	res_q10: [MAX_LPC_ORDER]i16
	nlsf_unpack(ec_ix[:], pred_q8[:], cb, i32(indices[0]))
	// residual dequant
	{
		out_q10: i32 = 0
		for i := cb.order - 1; i >= 0; i -= 1 {
			pred_q10 := smulbb(out_q10, i32(i16(pred_q8[i]))) >> 8
			out_q10 = i32(indices[i + 1]) << 10
			if out_q10 > 0 {
				out_q10 -= 102 // SILK_FIX_CONST(0.1, 10)
			} else if out_q10 < 0 {
				out_q10 += 102
			}
			out_q10 = smlawb(pred_q10, out_q10, cb.quant_step_size_q16)
			res_q10[i] = i16(out_q10)
		}
	}
	base := int(indices[0]) * int(cb.order)
	for i in 0 ..< cb.order {
		t := (i32(res_q10[i]) << 14) / i32(cb.cb1_wght_q9[base + int(i)]) + (i32(i16(cb.cb1_nlsf_q8[base + int(i)])) << 7)
		nlsf_q15[i] = i16(limit32(t, 0, 32767))
	}
	nlsf_stabilize(nlsf_q15, cb.delta_min_q15, int(cb.order))
}

@(rodata)
ordering16 := [16]u8{0, 15, 8, 7, 4, 11, 12, 3, 2, 13, 10, 5, 6, 9, 14, 1}
@(rodata)
ordering10 := [10]u8{0, 9, 6, 3, 4, 5, 8, 1, 2, 7}

@(private = "file")
nlsf2a_find_poly :: proc "contextless" (out: []i32, c_lsf: []i32, dd: int) {
	QA :: 16
	out[0] = 1 << QA
	out[1] = -c_lsf[0]
	for k in 1 ..< dd {
		ftmp := c_lsf[2 * k]
		out[k + 1] = (out[k - 1] << 1) - i32(rshift_round64(smull(ftmp, out[k]), QA))
		for n := k; n > 1; n -= 1 do out[n] += out[n - 2] - i32(rshift_round64(smull(ftmp, out[n - 1]), QA))
		out[1] -= ftmp
	}
}

@(private = "file")
lpc_fit :: proc "contextless" (a_qout: []i16, a_qin: []i32, qout, qin: u32, d: int) {
	i := 0
	idx := 0
	for ; i < 10; i += 1 {
		maxabs: i32 = 0
		for k in 0 ..< d {
			absval := silk_abs(a_qin[k])
			if absval > maxabs {
				maxabs = absval
				idx = k
			}
		}
		maxabs = rshift_round(maxabs, qin - qout)
		if maxabs > I16_MAX {
			maxabs = min(maxabs, 163838)
			chirp := i32(65470) - ((maxabs - I16_MAX) << 14) / ((maxabs * i32(idx + 1)) >> 2) // SILK_FIX_CONST(0.999,16)=65470
			bwexpander_32(a_qin, d, chirp)
		} else {
			break
		}
	}
	if i == 10 {
		for k in 0 ..< d {
			a_qout[k] = i16(sat16(rshift_round(a_qin[k], qin - qout)))
			a_qin[k] = i32(a_qout[k]) << (qin - qout)
		}
	} else {
		for k in 0 ..< d do a_qout[k] = i16(rshift_round(a_qin[k], qin - qout))
	}
}

nlsf2a :: proc "contextless" (a_q12: []i16, nlsf: []i16, d: int) {
	QA :: 16
	ordering := d == 16 ? ordering16[:] : ordering10[:]
	cos_lsf: [16]i32
	P, Q: [9]i32
	a32: [16]i32
	for k in 0 ..< d {
		f_int := i32(nlsf[k]) >> (15 - 7)
		f_frac := i32(nlsf[k]) - (f_int << (15 - 7))
		cos_val := i32(silk_LSFCosTab_FIX_Q12[f_int])
		delta := i32(silk_LSFCosTab_FIX_Q12[f_int + 1]) - cos_val
		cos_lsf[ordering[k]] = rshift_round((cos_val << 8) + delta * f_frac, 20 - QA)
	}
	dd := d >> 1
	nlsf2a_find_poly(P[:], cos_lsf[0:], dd)
	nlsf2a_find_poly(Q[:], cos_lsf[1:], dd)
	for k in 0 ..< dd {
		ptmp := P[k + 1] + P[k]
		qtmp := Q[k + 1] - Q[k]
		a32[k] = -qtmp - ptmp
		a32[d - k - 1] = qtmp - ptmp
	}
	lpc_fit(a_q12, a32[:], 12, QA + 1, d)
	for i := 0; lpc_inverse_pred_gain(a_q12, d) == 0 && i < 16; i += 1 {
		bwexpander_32(a32[:], d, 65536 - (i32(2) << u32(i)))
		for k in 0 ..< d do a_q12[k] = i16(rshift_round(a32[k], QA + 1 - 12))
	}
}

@(private = "file")
decode_pitch :: proc "contextless" (lag_index: i16, contour_index: i8, pitch_lags: []i32, fs_khz, nb_subfr: i32) {
	min_lag := smulbb(PE_MIN_LAG_MS, fs_khz)
	max_lag := smulbb(PE_MAX_LAG_MS, fs_khz)
	lag := min_lag + i32(lag_index)
	for k in 0 ..< nb_subfr {
		v: i32
		if fs_khz == 8 {
			if nb_subfr == MAX_NB_SUBFR do v = i32(silk_CB_lags_stage2[k][contour_index])
			else do v = i32(silk_CB_lags_stage2_10_ms[k][contour_index])
		} else {
			if nb_subfr == MAX_NB_SUBFR do v = i32(silk_CB_lags_stage3[k][contour_index])
			else do v = i32(silk_CB_lags_stage3_10_ms[k][contour_index])
		}
		pitch_lags[k] = limit32(lag + v, min_lag, max_lag)
	}
}

@(private = "file")
decode_parameters :: proc(ch: ^Silk_Channel, ctrl: ^Silk_Dec_Ctrl, cond_coding: int) {
	nlsf_q15, nlsf0_q15: [MAX_LPC_ORDER]i16
	gains_dequant(ctrl.gains_q16[:], ch.indices.gains_indices[:], &ch.last_gain_index, cond_coding == CODE_CONDITIONALLY, ch.nb_subfr)
	nlsf_decode(nlsf_q15[:], ch.indices.nlsf_indices[:], ch.nlsf_cb)
	nlsf2a(ctrl.pred_coef_q12[1][:], nlsf_q15[:], int(ch.lpc_order))
	if ch.first_frame_after_reset do ch.indices.nlsf_interp_coef_q2 = 4
	if ch.indices.nlsf_interp_coef_q2 < 4 {
		for i in 0 ..< ch.lpc_order {
			nlsf0_q15[i] = i16(i32(ch.prev_nlsf_q15[i]) + ((i32(ch.indices.nlsf_interp_coef_q2) * (i32(nlsf_q15[i]) - i32(ch.prev_nlsf_q15[i]))) >> 2))
		}
		nlsf2a(ctrl.pred_coef_q12[0][:], nlsf0_q15[:], int(ch.lpc_order))
	} else {
		copy(ctrl.pred_coef_q12[0][:ch.lpc_order], ctrl.pred_coef_q12[1][:ch.lpc_order])
	}
	copy(ch.prev_nlsf_q15[:ch.lpc_order], nlsf_q15[:ch.lpc_order])
	if ch.loss_cnt != 0 {
		bwexpander(ctrl.pred_coef_q12[0][:], int(ch.lpc_order), BWE_AFTER_LOSS_Q16)
		bwexpander(ctrl.pred_coef_q12[1][:], int(ch.lpc_order), BWE_AFTER_LOSS_Q16)
	}
	if ch.indices.signal_type == TYPE_VOICED {
		decode_pitch(ch.indices.lag_index, ch.indices.contour_index, ctrl.pitch_l[:], ch.fs_khz, ch.nb_subfr)
		for k in 0 ..< ch.nb_subfr {
			ix := int(ch.indices.ltp_index[k])
			for i in 0 ..< LTP_ORDER do ctrl.ltp_coef_q14[int(k) * LTP_ORDER + i] = i16(i32(ltp_vq(int(ch.indices.per_index), ix, i)) << 7)
		}
		ctrl.ltp_scale_q14 = i32(silk_LTPScales_table_Q14[ch.indices.ltp_scale_index])
	} else {
		ctrl.pitch_l = {}
		ctrl.ltp_coef_q14 = {}
		ch.indices.per_index = 0
		ctrl.ltp_scale_q14 = 0
	}
}

// ---- Core synthesis

@(private = "file")
decode_core :: proc(ch: ^Silk_Channel, ctrl: ^Silk_Dec_Ctrl, xq: []i16, pulses: []i16) {
	sltp: [MAX_FRAME_LENGTH]i16
	sltp_q15: [2 * MAX_FRAME_LENGTH]i32
	res_q14: [MAX_SUB_FRAME_LENGTH]i32
	slpc_q14: [MAX_SUB_FRAME_LENGTH + MAX_LPC_ORDER]i32
	offset_q10 := i32(silk_Quantization_Offsets_Q10[ch.indices.signal_type >> 1][ch.indices.quant_offset_type])
	nlsf_interpolation_flag := ch.indices.nlsf_interp_coef_q2 < 1 << 2
	rand_seed := i32(ch.indices.seed)
	for i in 0 ..< ch.frame_length {
		rand_seed = silk_rand(rand_seed)
		e := i32(pulses[i]) << 14
		if e > 0 {
			e -= QUANT_LEVEL_ADJUST_Q10 << 4
		} else if e < 0 {
			e += QUANT_LEVEL_ADJUST_Q10 << 4
		}
		e += offset_q10 << 4
		if rand_seed < 0 do e = -e
		ch.exc_q14[i] = e
		rand_seed = i32(u32(rand_seed) + u32(i32(pulses[i])))
	}
	copy(slpc_q14[:MAX_LPC_ORDER], ch.slpc_q14_buf[:])
	pexc := 0
	pxq := 0
	sltp_buf_idx := ch.ltp_mem_length
	lag: i32 = 0
	for k in 0 ..< ch.nb_subfr {
		A_Q12 := ctrl.pred_coef_q12[k >> 1][:]
		a_tmp: [MAX_LPC_ORDER]i16
		copy(a_tmp[:ch.lpc_order], A_Q12[:ch.lpc_order])
		B_Q14 := ctrl.ltp_coef_q14[k * LTP_ORDER:]
		signal_type := i32(ch.indices.signal_type)
		gain_q10 := ctrl.gains_q16[k] >> 6
		inv_gain_q31 := inverse32_varq(ctrl.gains_q16[k], 47)
		gain_adj_q16: i32
		if ctrl.gains_q16[k] != ch.prev_gain_q16 {
			gain_adj_q16 = div32_varq(ch.prev_gain_q16, ctrl.gains_q16[k], 16)
			for i in 0 ..< MAX_LPC_ORDER do slpc_q14[i] = smulww(gain_adj_q16, slpc_q14[i])
		} else {
			gain_adj_q16 = 1 << 16
		}
		ch.prev_gain_q16 = ctrl.gains_q16[k]
		if ch.loss_cnt != 0 && ch.prev_signal_type == TYPE_VOICED && ch.indices.signal_type != TYPE_VOICED && k < MAX_NB_SUBFR / 2 {
			for i in 0 ..< LTP_ORDER do B_Q14[i] = 0
			B_Q14[LTP_ORDER / 2] = 4096 // SILK_FIX_CONST(0.25, 14)
			signal_type = TYPE_VOICED
			ctrl.pitch_l[k] = ch.lag_prev
		}
		if signal_type == TYPE_VOICED {
			lag = ctrl.pitch_l[k]
			if k == 0 || (k == 2 && nlsf_interpolation_flag) {
				start_idx := ch.ltp_mem_length - lag - ch.lpc_order - LTP_ORDER / 2
				if k == 2 do copy(ch.out_buf[ch.ltp_mem_length:ch.ltp_mem_length + 2 * ch.subfr_length], xq[:2 * ch.subfr_length])
				lpc_analysis_filter(sltp[start_idx:], ch.out_buf[start_idx + k * ch.subfr_length:], A_Q12, int(ch.ltp_mem_length - start_idx), int(ch.lpc_order))
				if k == 0 do inv_gain_q31 = smulwb(inv_gain_q31, ctrl.ltp_scale_q14) << 2
				for i in 0 ..< lag + LTP_ORDER / 2 {
					sltp_q15[sltp_buf_idx - i - 1] = smulwb(inv_gain_q31, i32(sltp[ch.ltp_mem_length - i - 1]))
				}
			} else if gain_adj_q16 != 1 << 16 {
				for i in 0 ..< lag + LTP_ORDER / 2 {
					sltp_q15[sltp_buf_idx - i - 1] = smulww(gain_adj_q16, sltp_q15[sltp_buf_idx - i - 1])
				}
			}
		}
		pres: []i32
		if signal_type == TYPE_VOICED {
			pl := sltp_buf_idx - lag + LTP_ORDER / 2
			for i in 0 ..< ch.subfr_length {
				p: i32 = 2
				p = smlawb(p, sltp_q15[pl], i32(B_Q14[0]))
				p = smlawb(p, sltp_q15[pl - 1], i32(B_Q14[1]))
				p = smlawb(p, sltp_q15[pl - 2], i32(B_Q14[2]))
				p = smlawb(p, sltp_q15[pl - 3], i32(B_Q14[3]))
				p = smlawb(p, sltp_q15[pl - 4], i32(B_Q14[4]))
				pl += 1
				res_q14[i] = ch.exc_q14[pexc + int(i)] + (p << 1)
				sltp_q15[sltp_buf_idx] = res_q14[i] << 1
				sltp_buf_idx += 1
			}
			pres = res_q14[:]
		} else {
			pres = ch.exc_q14[pexc:]
		}
		for i in 0 ..< ch.subfr_length {
			pred := ch.lpc_order >> 1
			for j in 0 ..< ch.lpc_order do pred = smlawb(pred, slpc_q14[MAX_LPC_ORDER + i - j - 1], i32(a_tmp[j]))
			slpc_q14[MAX_LPC_ORDER + i] = add_sat32(pres[i], lshift_sat32(pred, 4))
			xq[pxq + int(i)] = i16(sat16(rshift_round(smulww(slpc_q14[MAX_LPC_ORDER + i], gain_q10), 8)))
		}
		copy(slpc_q14[:MAX_LPC_ORDER], slpc_q14[ch.subfr_length:ch.subfr_length + MAX_LPC_ORDER])
		pexc += int(ch.subfr_length)
		pxq += int(ch.subfr_length)
	}
	copy(ch.slpc_q14_buf[:], slpc_q14[:MAX_LPC_ORDER])
}

// ---- PLC

@(rodata)
HARM_ATT_Q15 := [2]i32{32440, 31130}
@(rodata)
PLC_RAND_ATTENUATE_V_Q15 := [2]i32{31130, 26214}
@(rodata)
PLC_RAND_ATTENUATE_UV_Q15 := [2]i32{32440, 29491}

@(private = "file")
plc_reset :: proc "contextless" (ch: ^Silk_Channel) {
	ch.plc.pitch_l_q8 = ch.frame_length << (8 - 1)
	ch.plc.prev_gain_q16 = {65536, 65536}
	ch.plc.subfr_length = 20
	ch.plc.nb_subfr = 2
}

@(private = "file")
plc_update :: proc "contextless" (ch: ^Silk_Channel, ctrl: ^Silk_Dec_Ctrl) {
	plc := &ch.plc
	ch.prev_signal_type = i32(ch.indices.signal_type)
	ltp_gain_q14: i32 = 0
	if ch.indices.signal_type == TYPE_VOICED {
		for j := i32(0); j * ch.subfr_length < ctrl.pitch_l[ch.nb_subfr - 1]; j += 1 {
			if j == ch.nb_subfr do break
			tmp: i32 = 0
			for i in 0 ..< LTP_ORDER do tmp += i32(ctrl.ltp_coef_q14[(ch.nb_subfr - 1 - j) * LTP_ORDER + i32(i)])
			if tmp > ltp_gain_q14 {
				ltp_gain_q14 = tmp
				o := smulbb(ch.nb_subfr - 1 - j, LTP_ORDER)
				copy(plc.ltp_coef_q14[:], ctrl.ltp_coef_q14[o:o + LTP_ORDER])
				plc.pitch_l_q8 = ctrl.pitch_l[ch.nb_subfr - 1 - j] << 8
			}
		}
		plc.ltp_coef_q14 = {}
		plc.ltp_coef_q14[LTP_ORDER / 2] = i16(ltp_gain_q14)
		if ltp_gain_q14 < V_PITCH_GAIN_START_MIN_Q14 {
			scale_q10 := (i32(V_PITCH_GAIN_START_MIN_Q14) << 10) / max(ltp_gain_q14, 1)
			for i in 0 ..< LTP_ORDER do plc.ltp_coef_q14[i] = i16(smulbb(i32(plc.ltp_coef_q14[i]), scale_q10) >> 10)
		} else if ltp_gain_q14 > V_PITCH_GAIN_START_MAX_Q14 {
			scale_q14 := (i32(V_PITCH_GAIN_START_MAX_Q14) << 14) / max(ltp_gain_q14, 1)
			for i in 0 ..< LTP_ORDER do plc.ltp_coef_q14[i] = i16(smulbb(i32(plc.ltp_coef_q14[i]), scale_q14) >> 14)
		}
	} else {
		plc.pitch_l_q8 = smulbb(ch.fs_khz, 18) << 8
		plc.ltp_coef_q14 = {}
	}
	copy(plc.prev_lpc_q12[:ch.lpc_order], ctrl.pred_coef_q12[1][:ch.lpc_order])
	plc.prev_ltp_scale_q14 = i16(ctrl.ltp_scale_q14)
	plc.prev_gain_q16[0] = ctrl.gains_q16[ch.nb_subfr - 2]
	plc.prev_gain_q16[1] = ctrl.gains_q16[ch.nb_subfr - 1]
	plc.subfr_length = ch.subfr_length
	plc.nb_subfr = ch.nb_subfr
}

@(private = "file")
plc_conceal :: proc(ch: ^Silk_Channel, ctrl: ^Silk_Dec_Ctrl, frame: []i16) {
	plc := &ch.plc
	sltp_q14: [2 * MAX_FRAME_LENGTH]i32
	sltp: [MAX_FRAME_LENGTH]i16
	prev_gain_q10 := [2]i32{plc.prev_gain_q16[0] >> 6, plc.prev_gain_q16[1] >> 6}
	if ch.first_frame_after_reset do plc.prev_lpc_q12 = {}
	energy1, shift1, energy2, shift2: i32
	{
		exc_buf: [2 * MAX_SUB_FRAME_LENGTH]i16
		sl := int(ch.subfr_length)
		for k in 0 ..< 2 {
			for i in 0 ..< sl {
				exc_buf[k * sl + i] = i16(sat16(smulww(ch.exc_q14[i + (k + int(ch.nb_subfr) - 2) * sl], prev_gain_q10[k]) >> 8))
			}
		}
		energy1, shift1 = sum_sqr_shift(exc_buf[:], sl)
		energy2, shift2 = sum_sqr_shift(exc_buf[sl:], sl)
	}
	rand_off: int
	if energy1 >> u32(shift2) < energy2 >> u32(shift1) {
		rand_off = int(max(0, (plc.nb_subfr - 1) * plc.subfr_length - RAND_BUF_SIZE))
	} else {
		rand_off = int(max(0, plc.nb_subfr * plc.subfr_length - RAND_BUF_SIZE))
	}
	rand_ptr := ch.exc_q14[rand_off:]
	B_Q14 := plc.ltp_coef_q14[:]
	rand_scale_q14 := i32(plc.rand_scale_q14)
	harm_gain_q15 := HARM_ATT_Q15[min(1, ch.loss_cnt)]
	rand_gain_q15: i32
	if ch.prev_signal_type == TYPE_VOICED {
		rand_gain_q15 = PLC_RAND_ATTENUATE_V_Q15[min(1, ch.loss_cnt)]
	} else {
		rand_gain_q15 = PLC_RAND_ATTENUATE_UV_Q15[min(1, ch.loss_cnt)]
	}
	bwexpander(plc.prev_lpc_q12[:], int(ch.lpc_order), BWE_COEF_Q16)
	A_Q12: [MAX_LPC_ORDER]i16
	copy(A_Q12[:ch.lpc_order], plc.prev_lpc_q12[:ch.lpc_order])
	if ch.loss_cnt == 0 {
		rand_scale_q14 = 1 << 14
		if ch.prev_signal_type == TYPE_VOICED {
			for i in 0 ..< LTP_ORDER do rand_scale_q14 -= i32(B_Q14[i])
			rand_scale_q14 = i32(max(i16(3277), i16(rand_scale_q14)))
			rand_scale_q14 = i32(i16(smulbb(rand_scale_q14, i32(plc.prev_ltp_scale_q14)) >> 14))
		} else {
			inv_gain_q30 := lpc_inverse_pred_gain(plc.prev_lpc_q12[:], int(ch.lpc_order))
			down := min(i32(1 << 30) >> LOG2_INV_LPC_GAIN_HIGH_THRES, inv_gain_q30)
			down = max(i32(1 << 30) >> LOG2_INV_LPC_GAIN_LOW_THRES, down)
			down <<= LOG2_INV_LPC_GAIN_HIGH_THRES
			rand_gain_q15 = smulwb(down, rand_gain_q15) >> 14
		}
	}
	rand_seed := plc.rand_seed
	lag := rshift_round(plc.pitch_l_q8, 8)
	sltp_buf_idx := ch.ltp_mem_length
	idx := ch.ltp_mem_length - lag - ch.lpc_order - LTP_ORDER / 2
	lpc_analysis_filter(sltp[idx:], ch.out_buf[idx:], A_Q12[:], int(ch.ltp_mem_length - idx), int(ch.lpc_order))
	inv_gain_q30 := inverse32_varq(plc.prev_gain_q16[1], 46)
	inv_gain_q30 = min(inv_gain_q30, I32_MAX >> 1)
	for i := idx + ch.lpc_order; i < ch.ltp_mem_length; i += 1 do sltp_q14[i] = smulwb(inv_gain_q30, i32(sltp[i]))
	for _ in 0 ..< ch.nb_subfr {
		pl := sltp_buf_idx - lag + LTP_ORDER / 2
		for _ in 0 ..< ch.subfr_length {
			p: i32 = 2
			p = smlawb(p, sltp_q14[pl], i32(B_Q14[0]))
			p = smlawb(p, sltp_q14[pl - 1], i32(B_Q14[1]))
			p = smlawb(p, sltp_q14[pl - 2], i32(B_Q14[2]))
			p = smlawb(p, sltp_q14[pl - 3], i32(B_Q14[3]))
			p = smlawb(p, sltp_q14[pl - 4], i32(B_Q14[4]))
			pl += 1
			rand_seed = silk_rand(rand_seed)
			ri := (rand_seed >> 25) & RAND_BUF_MASK
			sltp_q14[sltp_buf_idx] = smlawb(p, rand_ptr[ri], rand_scale_q14) << 2
			sltp_buf_idx += 1
		}
		for j in 0 ..< LTP_ORDER do B_Q14[j] = i16(smulbb(harm_gain_q15, i32(B_Q14[j])) >> 15)
		if ch.indices.signal_type != TYPE_NO_VOICE_ACTIVITY {
			rand_scale_q14 = i32(i16(smulbb(rand_scale_q14, rand_gain_q15) >> 15))
		}
		plc.pitch_l_q8 = smlawb(plc.pitch_l_q8, plc.pitch_l_q8, PITCH_DRIFT_FAC_Q16)
		plc.pitch_l_q8 = min(plc.pitch_l_q8, smulbb(MAX_PITCH_LAG_MS, ch.fs_khz) << 8)
		lag = rshift_round(plc.pitch_l_q8, 8)
	}
	slpc := sltp_q14[ch.ltp_mem_length - MAX_LPC_ORDER:]
	copy(slpc[:MAX_LPC_ORDER], ch.slpc_q14_buf[:])
	for i in 0 ..< ch.frame_length {
		pred := ch.lpc_order >> 1
		for j in 0 ..< ch.lpc_order do pred = smlawb(pred, slpc[MAX_LPC_ORDER + i - j - 1], i32(A_Q12[j]))
		slpc[MAX_LPC_ORDER + i] = add_sat32(slpc[MAX_LPC_ORDER + i], lshift_sat32(pred, 4))
		frame[i] = i16(sat16(sat16(rshift_round(smulww(slpc[MAX_LPC_ORDER + i], prev_gain_q10[1]), 8))))
	}
	copy(ch.slpc_q14_buf[:], slpc[ch.frame_length:ch.frame_length + MAX_LPC_ORDER])
	plc.rand_seed = rand_seed
	plc.rand_scale_q14 = i16(rand_scale_q14)
	for i in 0 ..< MAX_NB_SUBFR do ctrl.pitch_l[i] = lag
}

@(private = "file")
plc :: proc(ch: ^Silk_Channel, ctrl: ^Silk_Dec_Ctrl, frame: []i16, lost: bool) {
	if ch.fs_khz != ch.plc.fs_khz {
		plc_reset(ch)
		ch.plc.fs_khz = ch.fs_khz
	}
	if lost {
		plc_conceal(ch, ctrl, frame)
		ch.loss_cnt += 1
	} else {
		plc_update(ch, ctrl)
	}
}

@(private = "file")
plc_glue_frames :: proc "contextless" (ch: ^Silk_Channel, frame: []i16, length: int) {
	plc := &ch.plc
	if ch.loss_cnt != 0 {
		plc.conc_energy, plc.conc_energy_shift = sum_sqr_shift(frame, length)
		plc.last_frame_lost = true
	} else {
		if plc.last_frame_lost {
			energy, energy_shift := sum_sqr_shift(frame, length)
			if energy_shift > plc.conc_energy_shift {
				plc.conc_energy >>= u32(energy_shift - plc.conc_energy_shift)
			} else if energy_shift < plc.conc_energy_shift {
				energy >>= u32(plc.conc_energy_shift - energy_shift)
			}
			if energy > plc.conc_energy {
				LZ := clz32(plc.conc_energy) - 1
				plc.conc_energy <<= u32(LZ)
				energy >>= u32(max(24 - LZ, 0))
				frac_q24 := plc.conc_energy / max(energy, 1)
				gain_q16 := sqrt_approx(frac_q24) << 4
				slope_q16 := ((i32(1) << 16) - gain_q16) / i32(length)
				slope_q16 <<= 2
				for i in 0 ..< length {
					frame[i] = i16(smulwb(gain_q16, i32(frame[i])))
					gain_q16 += slope_q16
					if gain_q16 > 1 << 16 do break
				}
			}
		}
		plc.last_frame_lost = false
	}
}

// ---- CNG

@(private = "file")
cng_reset :: proc "contextless" (ch: ^Silk_Channel) {
	step := I16_MAX / (ch.lpc_order + 1)
	acc: i32 = 0
	for i in 0 ..< ch.lpc_order {
		acc += step
		ch.cng.smth_nlsf_q15[i] = i16(acc)
	}
	ch.cng.smth_gain_q16 = 0
	ch.cng.rand_seed = 3176576
}

@(private = "file")
cng :: proc(ch: ^Silk_Channel, ctrl: ^Silk_Dec_Ctrl, frame: []i16, length: int) {
	c := &ch.cng
	if ch.fs_khz != c.fs_khz {
		cng_reset(ch)
		c.fs_khz = ch.fs_khz
	}
	if ch.loss_cnt == 0 && ch.prev_signal_type == TYPE_NO_VOICE_ACTIVITY {
		for i in 0 ..< ch.lpc_order {
			c.smth_nlsf_q15[i] += i16(smulwb(i32(ch.prev_nlsf_q15[i]) - i32(c.smth_nlsf_q15[i]), CNG_NLSF_SMTH_Q16))
		}
		max_gain: i32 = 0
		subfr: i32 = 0
		for i in 0 ..< ch.nb_subfr {
			if ctrl.gains_q16[i] > max_gain {
				max_gain = ctrl.gains_q16[i]
				subfr = i
			}
		}
		n := (ch.nb_subfr - 1) * ch.subfr_length
		copy(c.exc_buf_q14[ch.subfr_length:ch.subfr_length + n], c.exc_buf_q14[:n])
		copy(c.exc_buf_q14[:ch.subfr_length], ch.exc_q14[subfr * ch.subfr_length:(subfr + 1) * ch.subfr_length])
		for i in 0 ..< ch.nb_subfr do c.smth_gain_q16 += smulwb(ctrl.gains_q16[i] - c.smth_gain_q16, CNG_GAIN_SMTH_Q16)
	}
	if ch.loss_cnt != 0 {
		sig: [MAX_FRAME_LENGTH + MAX_LPC_ORDER]i32
		gain_q16 := smulww(i32(ch.plc.rand_scale_q14), ch.plc.prev_gain_q16[1])
		if gain_q16 >= (1 << 21) || c.smth_gain_q16 > (1 << 23) {
			gain_q16 = smultt(gain_q16, gain_q16)
			gain_q16 = smultt(c.smth_gain_q16, c.smth_gain_q16) - (gain_q16 << 5)
			gain_q16 = sqrt_approx(gain_q16) << 16
		} else {
			gain_q16 = smulww(gain_q16, gain_q16)
			gain_q16 = smulww(c.smth_gain_q16, c.smth_gain_q16) - (gain_q16 << 5)
			gain_q16 = sqrt_approx(gain_q16) << 8
		}
		gain_q10 := gain_q16 >> 6
		{
			mask: i32 = CNG_BUF_MASK_MAX
			for mask > i32(length) do mask >>= 1
			seed := c.rand_seed
			for i in 0 ..< length {
				seed = silk_rand(seed)
				idx := (seed >> 24) & mask
				sig[MAX_LPC_ORDER + i] = c.exc_buf_q14[idx]
			}
			c.rand_seed = seed
		}
		A_Q12: [MAX_LPC_ORDER]i16
		nlsf2a(A_Q12[:], c.smth_nlsf_q15[:], int(ch.lpc_order))
		copy(sig[:MAX_LPC_ORDER], c.synth_state[:])
		for i in 0 ..< length {
			pred := ch.lpc_order >> 1
			for j in 0 ..< ch.lpc_order do pred = smlawb(pred, sig[MAX_LPC_ORDER + i - int(j) - 1], i32(A_Q12[j]))
			sig[MAX_LPC_ORDER + i] = add_sat32(sig[MAX_LPC_ORDER + i], lshift_sat32(pred, 4))
			frame[i] = i16(sat16(i32(frame[i]) + sat16(rshift_round(smulww(sig[MAX_LPC_ORDER + i], gain_q10), 8))))
		}
		copy(c.synth_state[:], sig[length:length + MAX_LPC_ORDER])
	} else {
		for i in 0 ..< ch.lpc_order do c.synth_state[i] = 0
	}
}

// ---- Frame

@(private = "file")
decode_frame :: proc(ch: ^Silk_Channel, dec: ^Range, out: []i16, lost_flag: int, cond_coding: int) -> i32 {
	ctrl: Silk_Dec_Ctrl
	L := ch.frame_length
	if lost_flag == FLAG_DECODE_NORMAL || (lost_flag == FLAG_DECODE_LBRR && ch.lbrr_flags[ch.n_frames_decoded] == 1) {
		pulses: [(MAX_FRAME_LENGTH + SHELL_CODEC_FRAME_LENGTH - 1) & ~int(SHELL_CODEC_FRAME_LENGTH - 1)]i16
		decode_indices(ch, dec, ch.n_frames_decoded, lost_flag != 0, cond_coding)
		decode_pulses(dec, pulses[:], i32(ch.indices.signal_type), i32(ch.indices.quant_offset_type), ch.frame_length)
		decode_parameters(ch, &ctrl, cond_coding)
		decode_core(ch, &ctrl, out, pulses[:])
		plc(ch, &ctrl, out, false)
		ch.loss_cnt = 0
		ch.prev_signal_type = i32(ch.indices.signal_type)
		ch.first_frame_after_reset = false
	} else {
		ch.indices.signal_type = i8(ch.prev_signal_type)
		plc(ch, &ctrl, out, true)
	}
	mv_len := ch.ltp_mem_length - ch.frame_length
	copy(ch.out_buf[:mv_len], ch.out_buf[ch.frame_length:ch.frame_length + mv_len])
	copy(ch.out_buf[mv_len:mv_len + ch.frame_length], out[:ch.frame_length])
	cng(ch, &ctrl, out, int(L))
	plc_glue_frames(ch, out, int(L))
	ch.lag_prev = ctrl.pitch_l[ch.nb_subfr - 1]
	return L
}

// ---- Stereo

@(private = "file")
stereo_decode_pred :: proc "contextless" (dec: ^Range, pred_q13: []i32) {
	ix: [2][3]i32
	n := ec_dec_icdf(dec, silk_stereo_pred_joint_iCDF[:], 8)
	ix[0][2] = n / 5
	ix[1][2] = n - 5 * ix[0][2]
	for k in 0 ..< 2 {
		ix[k][0] = ec_dec_icdf(dec, silk_uniform3_iCDF[:], 8)
		ix[k][1] = ec_dec_icdf(dec, silk_uniform5_iCDF[:], 8)
	}
	for k in 0 ..< 2 {
		ix[k][0] += 3 * ix[k][2]
		low_q13 := i32(silk_stereo_pred_quant_Q13[ix[k][0]])
		step_q13 := smulwb(i32(silk_stereo_pred_quant_Q13[ix[k][0] + 1]) - low_q13, 6554) // SILK_FIX_CONST(0.5/5, 16)
		pred_q13[k] = smlabb(low_q13, step_q13, 2 * ix[k][1] + 1)
	}
	pred_q13[0] -= pred_q13[1]
}

@(private = "file")
stereo_ms_to_lr :: proc "contextless" (d: ^Silk_Decoder, x1, x2: []i16, pred_q13: []i32, fs_khz: i32, frame_length: int) {
	x1[0], x1[1] = d.stereo_s_mid[0], d.stereo_s_mid[1]
	x2[0], x2[1] = d.stereo_s_side[0], d.stereo_s_side[1]
	d.stereo_s_mid = {x1[frame_length], x1[frame_length + 1]}
	d.stereo_s_side = {x2[frame_length], x2[frame_length + 1]}
	pred0 := i32(d.stereo_pred_prev_q13[0])
	pred1 := i32(d.stereo_pred_prev_q13[1])
	denom_q16 := (i32(1) << 16) / (STEREO_INTERP_LEN_MS * fs_khz)
	delta0 := rshift_round(smulbb(pred_q13[0] - i32(d.stereo_pred_prev_q13[0]), denom_q16), 16)
	delta1 := rshift_round(smulbb(pred_q13[1] - i32(d.stereo_pred_prev_q13[1]), denom_q16), 16)
	interp := int(STEREO_INTERP_LEN_MS * fs_khz)
	for n in 0 ..< interp {
		pred0 += delta0
		pred1 += delta1
		sum := ((i32(x1[n]) + i32(x1[n + 2])) + (i32(x1[n + 1]) << 1)) << 9
		sum = smlawb(i32(x2[n + 1]) << 8, sum, pred0)
		sum = smlawb(sum, i32(x1[n + 1]) << 11, pred1)
		x2[n + 1] = i16(sat16(rshift_round(sum, 8)))
	}
	pred0 = pred_q13[0]
	pred1 = pred_q13[1]
	for n in interp ..< frame_length {
		sum := ((i32(x1[n]) + i32(x1[n + 2])) + (i32(x1[n + 1]) << 1)) << 9
		sum = smlawb(i32(x2[n + 1]) << 8, sum, pred0)
		sum = smlawb(sum, i32(x1[n + 1]) << 11, pred1)
		x2[n + 1] = i16(sat16(rshift_round(sum, 8)))
	}
	d.stereo_pred_prev_q13 = {i16(pred_q13[0]), i16(pred_q13[1])}
	for n in 0 ..< frame_length {
		sum := i32(x1[n + 1]) + i32(x2[n + 1])
		diff := i32(x1[n + 1]) - i32(x2[n + 1])
		x1[n + 1] = i16(sat16(sum))
		x2[n + 1] = i16(sat16(diff))
	}
}

// ---- API

// lost_flag: 0 normal, 1 lost (PLC), 2 decode LBRR (FEC). Writes n_samples_out
// samples per channel (interleaved if API channels == 2) to samples_out.
silk_decode :: proc(d: ^Silk_Decoder, ctl: ^Silk_Dec_Control, lost_flag: int, new_packet: bool, dec: ^Range, samples_out: []i16, n_samples_out: ^int) -> int {
	ret := 0
	decode_only_middle := false
	ms_pred_q13: [2]i32
	cs := &d.channel_state
	if new_packet {
		for n in 0 ..< ctl.n_channels_internal do cs[n].n_frames_decoded = 0
	}
	if ctl.n_channels_internal > d.n_channels_internal do init_channel(&cs[1])
	stereo_to_mono := ctl.n_channels_internal == 1 && d.n_channels_internal == 2 && ctl.internal_sample_rate == 1000 * cs[0].fs_khz
	if cs[0].n_frames_decoded == 0 {
		for n in 0 ..< ctl.n_channels_internal {
			switch ctl.payload_size_ms {
			case 0, 10:
				cs[n].n_frames_per_packet = 1
				cs[n].nb_subfr = 2
			case 20:
				cs[n].n_frames_per_packet = 1
				cs[n].nb_subfr = 4
			case 40:
				cs[n].n_frames_per_packet = 2
				cs[n].nb_subfr = 4
			case 60:
				cs[n].n_frames_per_packet = 3
				cs[n].nb_subfr = 4
			case:
				return -1
			}
			fs_khz_dec := (ctl.internal_sample_rate >> 10) + 1
			if fs_khz_dec != 8 && fs_khz_dec != 12 && fs_khz_dec != 16 do return -1
			ret += decoder_set_fs(&cs[n], fs_khz_dec, ctl.api_sample_rate)
		}
	}
	if ctl.n_channels_api == 2 && ctl.n_channels_internal == 2 && (d.n_channels_api == 1 || d.n_channels_internal == 1) {
		d.stereo_pred_prev_q13 = {}
		d.stereo_s_side = {}
		cs[1].resampler = cs[0].resampler
	}
	d.n_channels_api = ctl.n_channels_api
	d.n_channels_internal = ctl.n_channels_internal
	if ctl.api_sample_rate > 48000 || ctl.api_sample_rate < 8000 do return -1
	if lost_flag != FLAG_PACKET_LOST && cs[0].n_frames_decoded == 0 {
		for n in 0 ..< ctl.n_channels_internal {
			for i in 0 ..< cs[n].n_frames_per_packet do cs[n].vad_flags[i] = i32(ec_dec_bit_logp(dec, 1))
			cs[n].lbrr_flag = i32(ec_dec_bit_logp(dec, 1))
		}
		for n in 0 ..< ctl.n_channels_internal {
			cs[n].lbrr_flags = {}
			if cs[n].lbrr_flag != 0 {
				if cs[n].n_frames_per_packet == 1 {
					cs[n].lbrr_flags[0] = 1
				} else {
					tab := cs[n].n_frames_per_packet == 2 ? silk_LBRR_flags_2_iCDF[:] : silk_LBRR_flags_3_iCDF[:]
					sym := ec_dec_icdf(dec, tab, 8) + 1
					for i in 0 ..< cs[n].n_frames_per_packet do cs[n].lbrr_flags[i] = (sym >> u32(i)) & 1
				}
			}
		}
		if lost_flag == FLAG_DECODE_NORMAL {
			// skip LBRR data
			for i in 0 ..< cs[0].n_frames_per_packet {
				for n in 0 ..< ctl.n_channels_internal {
					if cs[n].lbrr_flags[i] != 0 {
						pulses: [MAX_FRAME_LENGTH]i16
						if ctl.n_channels_internal == 2 && n == 0 {
							stereo_decode_pred(dec, ms_pred_q13[:])
							if cs[1].lbrr_flags[i] == 0 do decode_only_middle = ec_dec_icdf(dec, silk_stereo_only_code_mid_iCDF[:], 8) != 0
						}
						cond := (i > 0 && cs[n].lbrr_flags[i - 1] != 0) ? CODE_CONDITIONALLY : CODE_INDEPENDENTLY
						decode_indices(&cs[n], dec, i, true, cond)
						decode_pulses(dec, pulses[:], i32(cs[n].indices.signal_type), i32(cs[n].indices.quant_offset_type), cs[n].frame_length)
					}
				}
			}
		}
	}
	if ctl.n_channels_internal == 2 {
		if lost_flag == FLAG_DECODE_NORMAL || (lost_flag == FLAG_DECODE_LBRR && cs[0].lbrr_flags[cs[0].n_frames_decoded] == 1) {
			stereo_decode_pred(dec, ms_pred_q13[:])
			if (lost_flag == FLAG_DECODE_NORMAL && cs[1].vad_flags[cs[0].n_frames_decoded] == 0) ||
			   (lost_flag == FLAG_DECODE_LBRR && cs[1].lbrr_flags[cs[0].n_frames_decoded] == 0) {
				decode_only_middle = ec_dec_icdf(dec, silk_stereo_only_code_mid_iCDF[:], 8) != 0
			} else {
				decode_only_middle = false
			}
		} else {
			ms_pred_q13 = {i32(d.stereo_pred_prev_q13[0]), i32(d.stereo_pred_prev_q13[1])}
		}
	}
	if ctl.n_channels_internal == 2 && !decode_only_middle && d.prev_decode_only_middle {
		c1 := &cs[1]
		c1.out_buf = {}
		c1.slpc_q14_buf = {}
		c1.lag_prev = 100
		c1.last_gain_index = 10
		c1.prev_signal_type = TYPE_NO_VOICE_ACTIVITY
		c1.first_frame_after_reset = true
	}
	tmp1: [2][MAX_FRAME_LENGTH + 2]i16
	has_side: bool
	if lost_flag == FLAG_DECODE_NORMAL {
		has_side = !decode_only_middle
	} else {
		has_side = !d.prev_decode_only_middle || (ctl.n_channels_internal == 2 && lost_flag == FLAG_DECODE_LBRR && cs[1].lbrr_flags[cs[1].n_frames_decoded] == 1)
	}
	n_samples_dec: i32 = 0
	for n in 0 ..< ctl.n_channels_internal {
		if n == 0 || has_side {
			frame_index := cs[0].n_frames_decoded - n
			cond: int
			if frame_index <= 0 {
				cond = CODE_INDEPENDENTLY
			} else if lost_flag == FLAG_DECODE_LBRR {
				cond = cs[n].lbrr_flags[frame_index - 1] != 0 ? CODE_CONDITIONALLY : CODE_INDEPENDENTLY
			} else if n > 0 && d.prev_decode_only_middle {
				cond = CODE_INDEPENDENTLY_NO_LTP_SCALING
			} else {
				cond = CODE_CONDITIONALLY
			}
			n_samples_dec = decode_frame(&cs[n], dec, tmp1[n][2:], lost_flag, cond)
		} else {
			for i in 0 ..< n_samples_dec do tmp1[n][2 + i] = 0
		}
		cs[n].n_frames_decoded += 1
	}
	if ctl.n_channels_api == 2 && ctl.n_channels_internal == 2 {
		stereo_ms_to_lr(d, tmp1[0][:], tmp1[1][:], ms_pred_q13[:], cs[0].fs_khz, int(n_samples_dec))
	} else {
		tmp1[0][0], tmp1[0][1] = d.stereo_s_mid[0], d.stereo_s_mid[1]
		d.stereo_s_mid = {tmp1[0][n_samples_dec], tmp1[0][n_samples_dec + 1]}
	}
	nout := (n_samples_dec * ctl.api_sample_rate) / (cs[0].fs_khz * 1000)
	n_samples_out^ = int(nout)
	resample_out: [960 * 2]i16
	for n in 0 ..< min(ctl.n_channels_api, ctl.n_channels_internal) {
		if ctl.n_channels_api == 2 {
			resampler_run(&cs[n].resampler, resample_out[:], tmp1[n][1:], n_samples_dec)
			for i in 0 ..< nout do samples_out[n + 2 * i] = resample_out[i]
		} else {
			resampler_run(&cs[n].resampler, samples_out, tmp1[n][1:], n_samples_dec)
		}
	}
	if ctl.n_channels_api == 2 && ctl.n_channels_internal == 1 {
		if stereo_to_mono {
			resampler_run(&cs[1].resampler, resample_out[:], tmp1[0][1:], n_samples_dec)
			for i in 0 ..< nout do samples_out[1 + 2 * i] = resample_out[i]
		} else {
			for i in 0 ..< nout do samples_out[1 + 2 * i] = samples_out[2 * i]
		}
	}
	if cs[0].prev_signal_type == TYPE_VOICED {
		mult_tab := [3]i32{6, 4, 3}
		ctl.prev_pitch_lag = cs[0].lag_prev * mult_tab[(cs[0].fs_khz - 8) >> 2]
	} else {
		ctl.prev_pitch_lag = 0
	}
	if lost_flag == FLAG_PACKET_LOST {
		for i in 0 ..< d.n_channels_internal do cs[i].last_gain_index = 10
	} else {
		d.prev_decode_only_middle = decode_only_middle
	}
	return ret
}

OFFSET_VL_Q10 :: 32
OFFSET_VH_Q10 :: 100
OFFSET_UVL_Q10 :: 100
OFFSET_UVH_Q10 :: 240
PE_NB_CBKS_STAGE3_MIN :: 16
PE_NB_CBKS_STAGE3_MID :: 24
PE_NB_CBKS_STAGE3_MAX :: 34
