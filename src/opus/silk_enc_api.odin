package opus

// SILK encoder API (enc_API.c, init_encoder.c, control_codec.c, control_SNR.c,
// control_audio_bandwidth.c, check_control_input.c).

@(private = "file")
enc_rate_id :: #force_inline proc "contextless" (r: i32) -> i32 {
	return (((r >> 12) - i32(r > 16000)) >> u32(r > 24000)) - 1
}

// silk_resampler_init(..., forEnc = 1)
@(private = "file")
enc_resampler_init :: proc(S: ^Resampler, fs_in, fs_out: i32) -> int {
	if (fs_in != 8000 && fs_in != 12000 && fs_in != 16000 && fs_in != 24000 && fs_in != 48000) || (fs_out != 8000 && fs_out != 12000 && fs_out != 16000) {
		S^ = {}
		return -1
	}
	if fs_in == 8000 || fs_in == 12000 || fs_in == 16000 {
		// same structure setup as the decoder-side init; only the input delay differs
		if fs_out == 8000 || fs_out == 12000 || fs_out == 16000 {
			_ = resampler_init(S, fs_in, fs_out)
			S.input_delay = i32(silk_enc_delay_matrix[enc_rate_id(fs_in)][enc_rate_id(fs_out)])
			return 0
		}
	}
	S^ = {}
	S.input_delay = i32(silk_enc_delay_matrix[enc_rate_id(fs_in)][enc_rate_id(fs_out)])
	S.fs_in_khz = fs_in / 1000
	S.fs_out_khz = fs_out / 1000
	S.batch_size = S.fs_in_khz * 10
	// fs_out < fs_in here (24/48 kHz -> 8/12/16 kHz): down FIR
	S.function = 3
	switch {
	case fs_out * 4 == fs_in * 3: S.fir_fracs, S.fir_order, S.coefs = 3, 18, silk_Resampler_3_4_COEFS[:]
	case fs_out * 3 == fs_in * 2: S.fir_fracs, S.fir_order, S.coefs = 2, 18, silk_Resampler_2_3_COEFS[:]
	case fs_out * 2 == fs_in: S.fir_fracs, S.fir_order, S.coefs = 1, 24, silk_Resampler_1_2_COEFS[:]
	case fs_out * 3 == fs_in: S.fir_fracs, S.fir_order, S.coefs = 1, 36, silk_Resampler_1_3_COEFS[:]
	case fs_out * 4 == fs_in: S.fir_fracs, S.fir_order, S.coefs = 1, 36, silk_Resampler_1_4_COEFS[:]
	case fs_out * 6 == fs_in: S.fir_fracs, S.fir_order, S.coefs = 1, 36, silk_Resampler_1_6_COEFS[:]
	case: return -1
	}
	S.inv_ratio_q16 = ((fs_in << 14) / fs_out) << 2
	for smulww(S.inv_ratio_q16, fs_out) < fs_in do S.inv_ratio_q16 += 1
	return 0
}

@(private = "file")
init_channel_encoder :: proc(e: ^Silk_Enc_Chan) {
	e^ = {}
	e.cmn.variable_hp_smth1_q15 = (lin2log(SE_FIX_VARIABLE_HP_MIN_CUTOFF_Q16) - (16 << 7)) << 8
	e.cmn.variable_hp_smth2_q15 = e.cmn.variable_hp_smth1_q15
	e.cmn.first_frame_after_reset = 1
	silk_vad_init(&e.cmn.svad)
}

@(private = "file")
query_encoder :: proc(enc: ^Silk_Encoder, st: ^Silk_Enc_Control) {
	c := &enc.state[0].cmn
	st.n_channels_api = enc.n_channels_api
	st.n_channels_internal = enc.n_channels_internal
	st.api_sample_rate = c.api_fs_hz
	st.max_internal_sample_rate = c.max_internal_fs_hz
	st.min_internal_sample_rate = c.min_internal_fs_hz
	st.desired_internal_sample_rate = c.desired_internal_fs_hz
	st.payload_size_ms = c.packet_size_ms
	st.bit_rate = c.target_rate_bps
	st.packet_loss_percentage = c.packet_loss_perc
	st.complexity = c.complexity
	st.use_inband_fec = c.use_inband_fec
	st.use_dtx = c.use_dtx
	st.use_cbr = c.use_cbr
	st.internal_sample_rate = smulbb(c.fs_khz, 1000)
	st.allow_bandwidth_switch = c.allow_bandwidth_switch
	st.in_wb_mode_without_variable_lp = i32(c.fs_khz == 16 && c.slp.mode == 0)
}

silk_init_encoder :: proc(enc: ^Silk_Encoder, ctl: ^Silk_Enc_Control) -> int {
	enc^ = {}
	for n in 0 ..< SE_NUM_CHANNELS do init_channel_encoder(&enc.state[n])
	enc.n_channels_api = 1
	enc.n_channels_internal = 1
	query_encoder(enc, ctl)
	return 0
}

silk_enc_variable_hp_smth1_q15 :: proc(enc: ^Silk_Encoder) -> i32 {return enc.state[0].cmn.variable_hp_smth1_q15}
silk_enc_no_speech_counter :: proc(enc: ^Silk_Encoder, n: int) -> i32 {return enc.state[n].cmn.no_speech_counter}

@(private = "file")
check_control_input :: proc(c: ^Silk_Enc_Control) -> int {
	is_api := proc(r: i32) -> bool {return r == 8000 || r == 12000 || r == 16000 || r == 24000 || r == 32000 || r == 44100 || r == 48000}
	is_int := proc(r: i32) -> bool {return r == 8000 || r == 12000 || r == 16000}
	if !is_api(c.api_sample_rate) || !is_int(c.desired_internal_sample_rate) || !is_int(c.max_internal_sample_rate) || !is_int(c.min_internal_sample_rate) ||
	   c.min_internal_sample_rate > c.desired_internal_sample_rate || c.max_internal_sample_rate < c.desired_internal_sample_rate ||
	   c.min_internal_sample_rate > c.max_internal_sample_rate {
		return -102
	}
	if c.payload_size_ms != 10 && c.payload_size_ms != 20 && c.payload_size_ms != 40 && c.payload_size_ms != 60 do return -103
	if c.packet_loss_percentage < 0 || c.packet_loss_percentage > 100 do return -105
	if c.use_dtx < 0 || c.use_dtx > 1 do return -108
	if c.use_cbr < 0 || c.use_cbr > 1 do return -109
	if c.use_inband_fec < 0 || c.use_inband_fec > 1 do return -107
	if c.n_channels_api < 1 || c.n_channels_api > SE_NUM_CHANNELS do return -111
	if c.n_channels_internal < 1 || c.n_channels_internal > SE_NUM_CHANNELS do return -111
	if c.n_channels_internal > c.n_channels_api do return -111
	if c.complexity < 0 || c.complexity > 10 do return -106
	return 0
}

@(private = "file")
control_audio_bandwidth :: proc(c: ^Silk_Enc_Common, ctl: ^Silk_Enc_Control) -> i32 {
	orig_khz := c.fs_khz
	if orig_khz == 0 do orig_khz = c.slp.saved_fs_khz
	fs_khz := orig_khz
	fs_hz := smulbb(fs_khz, 1000)
	if fs_hz == 0 {
		fs_hz = min(c.desired_internal_fs_hz, c.api_fs_hz)
		fs_khz = fs_hz / 1000
	} else if fs_hz > c.api_fs_hz || fs_hz > c.max_internal_fs_hz || fs_hz < c.min_internal_fs_hz {
		fs_hz = c.api_fs_hz
		fs_hz = min(fs_hz, c.max_internal_fs_hz)
		fs_hz = max(fs_hz, c.min_internal_fs_hz)
		fs_khz = fs_hz / 1000
	} else {
		if c.slp.transition_frame_no >= SE_TRANSITION_FRAMES do c.slp.mode = 0
		if c.allow_bandwidth_switch != 0 || ctl.opus_can_switch != 0 {
			if smulbb(orig_khz, 1000) > c.desired_internal_fs_hz {
				if c.slp.mode == 0 {
					c.slp.transition_frame_no = SE_TRANSITION_FRAMES
					c.slp.in_lp_state = {}
				}
				if ctl.opus_can_switch != 0 {
					c.slp.mode = 0
					fs_khz = orig_khz == 16 ? 12 : 8
				} else {
					if c.slp.transition_frame_no <= 0 {
						ctl.switch_ready = 1
						ctl.max_bits -= ctl.max_bits * 5 / (ctl.payload_size_ms + 5)
					} else {
						c.slp.mode = -2
					}
				}
			} else if smulbb(orig_khz, 1000) < c.desired_internal_fs_hz {
				if ctl.opus_can_switch != 0 {
					fs_khz = orig_khz == 8 ? 12 : 16
					c.slp.transition_frame_no = 0
					c.slp.in_lp_state = {}
					c.slp.mode = 1
				} else {
					if c.slp.mode == 0 {
						ctl.switch_ready = 1
						ctl.max_bits -= ctl.max_bits * 5 / (ctl.payload_size_ms + 5)
					} else {
						c.slp.mode = 1
					}
				}
			} else {
				if c.slp.mode < 0 do c.slp.mode = 1
			}
		}
	}
	return fs_khz
}

@(private = "file")
setup_resamplers :: proc(e: ^Silk_Enc_Chan, fs_khz: i32) -> int {
	c := &e.cmn
	ret := 0
	if c.fs_khz != fs_khz || c.prev_api_fs_hz != c.api_fs_hz {
		if c.fs_khz == 0 {
			ret += enc_resampler_init(&c.resampler_state, c.api_fs_hz, fs_khz * 1000)
		} else {
			x_buf_fix: [2 * MAX_FRAME_LENGTH + SE_LA_SHAPE_MAX]i16
			x_buf_api: [(2 * 20 + SE_LA_SHAPE_MS) * 48]i16
			buf_length_ms := ((c.nb_subfr * 5) << 1) + SE_LA_SHAPE_MS
			old_buf_samples := buf_length_ms * c.fs_khz
			new_buf_samples := buf_length_ms * fs_khz
			for k := old_buf_samples - 1; k >= 0; k -= 1 do x_buf_fix[k] = silk_f2s(e.x_buf[k])
			temp: Resampler
			ret += resampler_init(&temp, smulbb(c.fs_khz, 1000), c.api_fs_hz)
			api_buf_samples := buf_length_ms * (c.api_fs_hz / 1000)
			resampler_run(&temp, x_buf_api[:], x_buf_fix[:], old_buf_samples)
			ret += enc_resampler_init(&c.resampler_state, c.api_fs_hz, smulbb(fs_khz, 1000))
			resampler_run(&c.resampler_state, x_buf_fix[:], x_buf_api[:], api_buf_samples)
			for k := new_buf_samples - 1; k >= 0; k -= 1 do e.x_buf[k] = f32(x_buf_fix[k])
		}
	}
	c.prev_api_fs_hz = c.api_fs_hz
	return ret
}

@(private = "file")
setup_fs :: proc(e: ^Silk_Enc_Chan, fs_khz: i32, packet_size_ms: i32) -> int {
	c := &e.cmn
	ret := 0
	if packet_size_ms != c.packet_size_ms {
		if packet_size_ms != 10 && packet_size_ms != 20 && packet_size_ms != 40 && packet_size_ms != 60 do ret = -103
		if packet_size_ms <= 10 {
			c.n_frames_per_packet = 1
			c.nb_subfr = packet_size_ms == 10 ? 2 : 1
			c.frame_length = smulbb(packet_size_ms, fs_khz)
			c.pitch_lpc_win_length = smulbb(SE_FIND_PITCH_LPC_WIN_MS_2_SF, fs_khz)
			c.pitch_contour_icdf = c.fs_khz == 8 ? silk_pitch_contour_10_ms_NB_iCDF[:] : silk_pitch_contour_10_ms_iCDF[:]
		} else {
			c.n_frames_per_packet = packet_size_ms / SE_MAX_FRAME_LENGTH_MS
			c.nb_subfr = MAX_NB_SUBFR
			c.frame_length = smulbb(20, fs_khz)
			c.pitch_lpc_win_length = smulbb(SE_FIND_PITCH_LPC_WIN_MS, fs_khz)
			c.pitch_contour_icdf = c.fs_khz == 8 ? silk_pitch_contour_NB_iCDF[:] : silk_pitch_contour_iCDF[:]
		}
		c.packet_size_ms = packet_size_ms
		c.target_rate_bps = 0
	}
	if c.fs_khz != fs_khz {
		e.shape = {}
		c.snsq = {}
		c.prev_nlsfq_q15 = {}
		c.slp.in_lp_state = {}
		c.input_buf_ix = 0
		c.n_frames_encoded = 0
		c.target_rate_bps = 0
		c.prev_lag = 100
		c.first_frame_after_reset = 1
		e.shape.last_gain_index = 10
		c.snsq.lag_prev = 100
		c.snsq.prev_gain_q16 = 65536
		c.prev_signal_type = TYPE_NO_VOICE_ACTIVITY
		c.fs_khz = fs_khz
		if c.fs_khz == 8 {
			c.pitch_contour_icdf = c.nb_subfr == MAX_NB_SUBFR ? silk_pitch_contour_NB_iCDF[:] : silk_pitch_contour_10_ms_NB_iCDF[:]
		} else {
			c.pitch_contour_icdf = c.nb_subfr == MAX_NB_SUBFR ? silk_pitch_contour_iCDF[:] : silk_pitch_contour_10_ms_iCDF[:]
		}
		if c.fs_khz == 8 || c.fs_khz == 12 {
			c.predict_lpc_order = SE_MIN_LPC_ORDER
			c.nlsf_cb = &silk_nlsf_cb_nb_mb
		} else {
			c.predict_lpc_order = MAX_LPC_ORDER
			c.nlsf_cb = &silk_nlsf_cb_wb
		}
		c.subfr_length = SE_SUB_FRAME_LENGTH_MS * fs_khz
		c.frame_length = smulbb(c.subfr_length, c.nb_subfr)
		c.ltp_mem_length = smulbb(SE_LTP_MEM_LENGTH_MS, fs_khz)
		c.la_pitch = smulbb(SE_LA_PITCH_MS, fs_khz)
		c.max_pitch_lag = smulbb(18, fs_khz)
		if c.nb_subfr == MAX_NB_SUBFR {
			c.pitch_lpc_win_length = smulbb(SE_FIND_PITCH_LPC_WIN_MS, fs_khz)
		} else {
			c.pitch_lpc_win_length = smulbb(SE_FIND_PITCH_LPC_WIN_MS_2_SF, fs_khz)
		}
		if c.fs_khz == 16 {
			c.pitch_lag_low_bits_icdf = silk_uniform8_iCDF[:]
		} else if c.fs_khz == 12 {
			c.pitch_lag_low_bits_icdf = silk_uniform6_iCDF[:]
		} else {
			c.pitch_lag_low_bits_icdf = silk_uniform4_iCDF[:]
		}
	}
	return ret
}

@(private = "file")
setup_complexity :: proc(c: ^Silk_Enc_Common, complexity: i32) {
	set :: proc(c: ^Silk_Enc_Common, pec: i32, thr_q16: i32, pe_order: i32, shaping_order: i32, la_mul: i32, n_states: i32, interp: i32, surv: i32, warp: bool) {
		c.pitch_estimation_complexity = pec
		c.pitch_estimation_threshold_q16 = thr_q16
		c.pitch_estimation_lpc_order = pe_order
		c.shaping_lpc_order = shaping_order
		c.la_shape = la_mul * c.fs_khz
		c.n_states_delayed_decision = n_states
		c.use_interpolated_nlsfs = interp
		c.nlsf_msvq_survivors = surv
		c.warping_q16 = warp ? c.fs_khz * SE_FIX_WARPING_MULTIPLIER_Q16 : 0
	}
	switch {
	case complexity < 1: set(c, SE_PE_MIN_COMPLEX, 52429, 6, 12, 3, 1, 0, 2, false)
	case complexity < 2: set(c, SE_PE_MID_COMPLEX, 49807, 8, 14, 5, 1, 0, 3, false)
	case complexity < 3: set(c, SE_PE_MIN_COMPLEX, 52429, 6, 12, 3, 2, 0, 2, false)
	case complexity < 4: set(c, SE_PE_MID_COMPLEX, 49807, 8, 14, 5, 2, 0, 4, false)
	case complexity < 6: set(c, SE_PE_MID_COMPLEX, 48497, 10, 16, 5, 2, 1, 6, true)
	case complexity < 8: set(c, SE_PE_MID_COMPLEX, 47186, 12, 20, 5, 3, 1, 8, true)
	case: set(c, SE_PE_MAX_COMPLEX, 45875, 16, 24, 5, SE_MAX_DEL_DEC_STATES, 1, 16, true)
	}
	c.pitch_estimation_lpc_order = min(c.pitch_estimation_lpc_order, c.predict_lpc_order)
	c.shape_win_length = SE_SUB_FRAME_LENGTH_MS * c.fs_khz + 2 * c.la_shape
	c.complexity = complexity
}

@(private = "file")
control_encoder :: proc(e: ^Silk_Enc_Chan, ctl: ^Silk_Enc_Control, allow_bw_switch: i32, channel_nb: i32, force_fs_khz: i32) -> int {
	c := &e.cmn
	ret := 0
	c.use_dtx = ctl.use_dtx
	c.use_cbr = ctl.use_cbr
	c.api_fs_hz = ctl.api_sample_rate
	c.max_internal_fs_hz = ctl.max_internal_sample_rate
	c.min_internal_fs_hz = ctl.min_internal_sample_rate
	c.desired_internal_fs_hz = ctl.desired_internal_sample_rate
	c.use_inband_fec = ctl.use_inband_fec
	c.n_channels_api = ctl.n_channels_api
	c.n_channels_internal = ctl.n_channels_internal
	c.allow_bandwidth_switch = allow_bw_switch
	c.channel_nb = channel_nb
	if c.controlled_since_last_payload != 0 && c.prefill_flag == 0 {
		if c.api_fs_hz != c.prev_api_fs_hz && c.fs_khz > 0 do ret += setup_resamplers(e, c.fs_khz)
		return ret
	}
	fs_khz := control_audio_bandwidth(c, ctl)
	if force_fs_khz != 0 do fs_khz = force_fs_khz
	ret += setup_resamplers(e, fs_khz)
	ret += setup_fs(e, fs_khz, ctl.payload_size_ms)
	setup_complexity(c, ctl.complexity)
	c.packet_loss_perc = ctl.packet_loss_percentage
	// setup_LBRR
	lbrr_in_previous_packet := c.lbrr_enabled
	c.lbrr_enabled = ctl.lbrr_coded
	if c.lbrr_enabled != 0 {
		if lbrr_in_previous_packet == 0 {
			c.lbrr_gain_increases = 7
		} else {
			c.lbrr_gain_increases = max(7 - smulwb(c.packet_loss_perc, 26214), 2)
		}
	}
	c.controlled_since_last_payload = 1
	return ret
}

@(private = "file")
control_snr :: proc(c: ^Silk_Enc_Common, target_rate_bps_: i32) {
	target_rate_bps := target_rate_bps_
	c.target_rate_bps = target_rate_bps
	if c.nb_subfr == 2 do target_rate_bps -= 2000 + c.fs_khz / 16
	table: []u8
	if c.fs_khz == 8 {
		table = silk_enc_target_rate_nb_21[:]
	} else if c.fs_khz == 12 {
		table = silk_enc_target_rate_mb_21[:]
	} else {
		table = silk_enc_target_rate_wb_21[:]
	}
	id := (target_rate_bps + 200) / 400
	id = min(id - 10, i32(len(table)) - 1)
	if id <= 0 {
		c.snr_db_q7 = 0
	} else {
		c.snr_db_q7 = i32(table[id]) * 21
	}
}

silk_encode :: proc(enc: ^Silk_Encoder, ctl: ^Silk_Enc_Control, samples_in_: []i16, n_samples_in_: int, range_enc: ^Range, n_bytes_out: ^i32,
	prefill_flag: int, activity: int) -> int {
	ret := 0
	samples_in := samples_in_
	n_samples_in := n_samples_in_
	tmp_payload_size_ms: i32 = 0
	tmp_complexity: i32 = 0
	s0 := &enc.state[0]
	s1 := &enc.state[1]
	if ctl.reduced_dependency != 0 {
		s0.cmn.first_frame_after_reset = 1
		s1.cmn.first_frame_after_reset = 1
	}
	s0.cmn.n_frames_encoded = 0
	s1.cmn.n_frames_encoded = 0
	if r := check_control_input(ctl); r != 0 do return r
	ctl.switch_ready = 0
	if ctl.n_channels_internal > enc.n_channels_internal {
		init_channel_encoder(s1)
		enc.stereo.pred_prev_q13 = {}
		enc.stereo.sside = {}
		enc.stereo.mid_side_amp_q0 = {0, 1, 0, 1}
		enc.stereo.width_prev_q14 = 0
		enc.stereo.smth_width_q14 = 1 << 14
		if enc.n_channels_api == 2 {
			s1.cmn.resampler_state = s0.cmn.resampler_state
			s1.cmn.in_hp_state = s0.cmn.in_hp_state
		}
	}
	transition := ctl.payload_size_ms != s0.cmn.packet_size_ms || enc.n_channels_internal != ctl.n_channels_internal
	enc.n_channels_api = ctl.n_channels_api
	enc.n_channels_internal = ctl.n_channels_internal
	n_blocks_of_10ms := i32(100 * n_samples_in) / ctl.api_sample_rate
	tot_blocks: i32 = n_blocks_of_10ms > 1 ? n_blocks_of_10ms >> 1 : 1
	curr_block: i32 = 0
	if prefill_flag != 0 {
		if n_blocks_of_10ms != 1 do return -101
		save_lp: Silk_LP_State
		if prefill_flag == 2 {
			save_lp = s0.cmn.slp
			save_lp.saved_fs_khz = s0.cmn.fs_khz
		}
		for n in 0 ..< int(ctl.n_channels_internal) {
			init_channel_encoder(&enc.state[n])
			if prefill_flag == 2 do enc.state[n].cmn.slp = save_lp
		}
		tmp_payload_size_ms = ctl.payload_size_ms
		ctl.payload_size_ms = 10
		tmp_complexity = ctl.complexity
		ctl.complexity = 0
		for n in 0 ..< int(ctl.n_channels_internal) {
			enc.state[n].cmn.controlled_since_last_payload = 0
			enc.state[n].cmn.prefill_flag = 1
		}
	} else {
		if n_blocks_of_10ms * ctl.api_sample_rate != i32(100 * n_samples_in) || n_samples_in < 0 do return -101
		if 1000 * i32(n_samples_in) > ctl.payload_size_ms * ctl.api_sample_rate do return -101
	}
	for n in 0 ..< int(ctl.n_channels_internal) {
		force_fs_khz: i32 = n == 1 ? s0.cmn.fs_khz : 0
		if r := control_encoder(&enc.state[n], ctl, enc.allow_bandwidth_switch, i32(n), force_fs_khz); r != 0 do return r
		if enc.state[n].cmn.first_frame_after_reset != 0 || transition {
			for i in 0 ..< int(s0.cmn.n_frames_per_packet) do enc.state[n].cmn.lbrr_flags[i] = 0
		}
		enc.state[n].cmn.in_dtx = enc.state[n].cmn.use_dtx
	}
	n_samples_to_buffer_max := 10 * n_blocks_of_10ms * s0.cmn.fs_khz
	buf: [20 * 48 * 3]i16
	for {
		n_samples_to_buffer := s0.cmn.frame_length - s0.cmn.input_buf_ix
		n_samples_to_buffer = min(n_samples_to_buffer, n_samples_to_buffer_max)
		n_samples_from_input := int((n_samples_to_buffer * s0.cmn.api_fs_hz) / (s0.cmn.fs_khz * 1000))
		if ctl.n_channels_api == 2 && ctl.n_channels_internal == 2 {
			id := s0.cmn.n_frames_encoded
			for n in 0 ..< n_samples_from_input do buf[n] = samples_in[2 * n]
			if enc.n_prev_channels_internal == 1 && id == 0 do s1.cmn.resampler_state = s0.cmn.resampler_state
			resampler_run(&s0.cmn.resampler_state, s0.cmn.input_buf[s0.cmn.input_buf_ix + 2:], buf[:], i32(n_samples_from_input))
			s0.cmn.input_buf_ix += n_samples_to_buffer
			n_samples_to_buffer = s1.cmn.frame_length - s1.cmn.input_buf_ix
			n_samples_to_buffer = min(n_samples_to_buffer, 10 * n_blocks_of_10ms * s1.cmn.fs_khz)
			for n in 0 ..< n_samples_from_input do buf[n] = samples_in[2 * n + 1]
			resampler_run(&s1.cmn.resampler_state, s1.cmn.input_buf[s1.cmn.input_buf_ix + 2:], buf[:], i32(n_samples_from_input))
			s1.cmn.input_buf_ix += n_samples_to_buffer
		} else if ctl.n_channels_api == 2 && ctl.n_channels_internal == 1 {
			for n in 0 ..< n_samples_from_input {
				sum := i32(samples_in[2 * n]) + i32(samples_in[2 * n + 1])
				buf[n] = i16(rshift_round(sum, 1))
			}
			resampler_run(&s0.cmn.resampler_state, s0.cmn.input_buf[s0.cmn.input_buf_ix + 2:], buf[:], i32(n_samples_from_input))
			if enc.n_prev_channels_internal == 2 && s0.cmn.n_frames_encoded == 0 {
				resampler_run(&s1.cmn.resampler_state, s1.cmn.input_buf[s1.cmn.input_buf_ix + 2:], buf[:], i32(n_samples_from_input))
				for n in 0 ..< int(s0.cmn.frame_length) {
					a := &s0.cmn.input_buf[int(s0.cmn.input_buf_ix) + n + 2]
					a^ = i16((i32(a^) + i32(s1.cmn.input_buf[int(s1.cmn.input_buf_ix) + n + 2])) >> 1)
				}
			}
			s0.cmn.input_buf_ix += n_samples_to_buffer
		} else {
			copy(buf[:n_samples_from_input], samples_in[:n_samples_from_input])
			resampler_run(&s0.cmn.resampler_state, s0.cmn.input_buf[s0.cmn.input_buf_ix + 2:], buf[:], i32(n_samples_from_input))
			s0.cmn.input_buf_ix += n_samples_to_buffer
		}
		samples_in = samples_in[n_samples_from_input * int(ctl.n_channels_api):]
		n_samples_in -= n_samples_from_input
		enc.allow_bandwidth_switch = 0
		if s0.cmn.input_buf_ix >= s0.cmn.frame_length {
			if s0.cmn.n_frames_encoded == 0 && prefill_flag == 0 {
				icdf: [2]u8
				icdf[0] = u8(i32(256) - (i32(256) >> u32((s0.cmn.n_frames_per_packet + 1) * ctl.n_channels_internal)))
				ec_enc_icdf(range_enc, 0, icdf[:], 8)
				for n in 0 ..< int(ctl.n_channels_internal) {
					cn := &enc.state[n].cmn
					lbrr_symbol: i32 = 0
					for i in 0 ..< int(cn.n_frames_per_packet) do lbrr_symbol |= cn.lbrr_flags[i] << u32(i)
					cn.lbrr_flag = lbrr_symbol > 0 ? 1 : 0
					if lbrr_symbol != 0 && cn.n_frames_per_packet > 1 {
						t := cn.n_frames_per_packet == 2 ? silk_LBRR_flags_2_iCDF[:] : silk_LBRR_flags_3_iCDF[:]
						ec_enc_icdf(range_enc, lbrr_symbol - 1, t, 8)
					}
				}
				for i in 0 ..< int(s0.cmn.n_frames_per_packet) {
					for n in 0 ..< int(ctl.n_channels_internal) {
						cn := &enc.state[n].cmn
						if cn.lbrr_flags[i] != 0 {
							if ctl.n_channels_internal == 2 && n == 0 {
								silk_stereo_encode_pred(range_enc, &enc.stereo.pred_ix[i])
								if s1.cmn.lbrr_flags[i] == 0 do silk_stereo_encode_mid_only(range_enc, enc.stereo.mid_only_flags[i])
							}
							cond_coding := (i > 0 && cn.lbrr_flags[i - 1] != 0) ? CODE_CONDITIONALLY : CODE_INDEPENDENTLY
							silk_encode_indices(cn, range_enc, i, true, cond_coding)
							silk_encode_pulses(range_enc, i32(cn.indices_lbrr[i].signal_type), i32(cn.indices_lbrr[i].quant_offset_type), cn.pulses_lbrr[i][:],
								int(cn.frame_length))
						}
					}
				}
				for n in 0 ..< int(ctl.n_channels_internal) do enc.state[n].cmn.lbrr_flags = {}
				enc.n_bits_used_lbrr = ec_tell(range_enc)
			}
			silk_hp_variable_cutoff(enc.state[:])
			n_bits := (ctl.bit_rate * ctl.payload_size_ms) / 1000
			if prefill_flag == 0 do n_bits -= enc.n_bits_used_lbrr
			n_bits = n_bits / s0.cmn.n_frames_per_packet
			target_rate_bps: i32
			if ctl.payload_size_ms == 10 {
				target_rate_bps = smulbb(n_bits, 100)
			} else {
				target_rate_bps = smulbb(n_bits, 50)
			}
			target_rate_bps -= (enc.n_bits_exceeded * 1000) / SE_BITRESERVOIR_DECAY_TIME_MS
			if prefill_flag == 0 && s0.cmn.n_frames_encoded > 0 {
				bits_balance := ec_tell(range_enc) - enc.n_bits_used_lbrr - n_bits * s0.cmn.n_frames_encoded
				target_rate_bps -= (bits_balance * 1000) / SE_BITRESERVOIR_DECAY_TIME_MS
			}
			target_rate_bps = limit32(target_rate_bps, ctl.bit_rate, 5000)
			ms_target_rates_bps: [2]i32
			fe := s0.cmn.n_frames_encoded
			if ctl.n_channels_internal == 2 {
				silk_stereo_lr_to_ms(&enc.stereo, s0.cmn.input_buf[:], s1.cmn.input_buf[:], &enc.stereo.pred_ix[fe], &enc.stereo.mid_only_flags[fe],
					ms_target_rates_bps[:], target_rate_bps, s0.cmn.speech_activity_q8, ctl.to_mono != 0, s0.cmn.fs_khz, int(s0.cmn.frame_length))
				if enc.stereo.mid_only_flags[fe] == 0 {
					if enc.prev_decode_only_middle == 1 {
						s1.shape = {}
						s1.cmn.snsq = {}
						s1.cmn.prev_nlsfq_q15 = {}
						s1.cmn.slp.in_lp_state = {}
						s1.cmn.prev_lag = 100
						s1.cmn.snsq.lag_prev = 100
						s1.shape.last_gain_index = 10
						s1.cmn.prev_signal_type = TYPE_NO_VOICE_ACTIVITY
						s1.cmn.snsq.prev_gain_q16 = 65536
						s1.cmn.first_frame_after_reset = 1
					}
					silk_encode_do_vad_flp(s1, activity)
				} else {
					s1.cmn.vad_flags[fe] = 0
				}
				if prefill_flag == 0 {
					silk_stereo_encode_pred(range_enc, &enc.stereo.pred_ix[fe])
					if s1.cmn.vad_flags[fe] == 0 do silk_stereo_encode_mid_only(range_enc, enc.stereo.mid_only_flags[fe])
				}
			} else {
				s0.cmn.input_buf[0] = enc.stereo.smid[0]
				s0.cmn.input_buf[1] = enc.stereo.smid[1]
				enc.stereo.smid[0] = s0.cmn.input_buf[s0.cmn.frame_length]
				enc.stereo.smid[1] = s0.cmn.input_buf[s0.cmn.frame_length + 1]
			}
			silk_encode_do_vad_flp(s0, activity)
			for n in 0 ..< int(ctl.n_channels_internal) {
				max_bits := ctl.max_bits
				if tot_blocks == 2 && curr_block == 0 {
					max_bits = max_bits * 3 / 5
				} else if tot_blocks == 3 {
					if curr_block == 0 {
						max_bits = max_bits * 2 / 5
					} else if curr_block == 1 {
						max_bits = max_bits * 3 / 4
					}
				}
				use_cbr := ctl.use_cbr != 0 && curr_block == tot_blocks - 1
				channel_rate_bps: i32
				if ctl.n_channels_internal == 1 {
					channel_rate_bps = target_rate_bps
				} else {
					channel_rate_bps = ms_target_rates_bps[n]
					if n == 0 && ms_target_rates_bps[1] > 0 {
						use_cbr = false
						max_bits -= ctl.max_bits / (tot_blocks * 2)
					}
				}
				if channel_rate_bps > 0 {
					control_snr(&enc.state[n].cmn, channel_rate_bps)
					cond_coding: int
					if s0.cmn.n_frames_encoded - i32(n) <= 0 {
						cond_coding = CODE_INDEPENDENTLY
					} else if n > 0 && enc.prev_decode_only_middle != 0 {
						cond_coding = CODE_INDEPENDENTLY_NO_LTP_SCALING
					} else {
						cond_coding = CODE_CONDITIONALLY
					}
					ret = silk_encode_frame_flp(&enc.state[n], n_bytes_out, range_enc, cond_coding, max_bits, use_cbr)
				}
				enc.state[n].cmn.controlled_since_last_payload = 0
				enc.state[n].cmn.input_buf_ix = 0
				enc.state[n].cmn.n_frames_encoded += 1
			}
			enc.prev_decode_only_middle = i32(enc.stereo.mid_only_flags[s0.cmn.n_frames_encoded - 1])
			if n_bytes_out^ > 0 && s0.cmn.n_frames_encoded == s0.cmn.n_frames_per_packet {
				flags: u32 = 0
				for n in 0 ..< int(ctl.n_channels_internal) {
					cn := &enc.state[n].cmn
					for i in 0 ..< int(cn.n_frames_per_packet) {
						flags <<= 1
						flags |= u32(cn.vad_flags[i])
					}
					flags <<= 1
					flags |= u32(cn.lbrr_flag)
				}
				if prefill_flag == 0 do ec_enc_patch_initial_bits(range_enc, flags, u32((s0.cmn.n_frames_per_packet + 1) * ctl.n_channels_internal))
				if s0.cmn.in_dtx != 0 && (ctl.n_channels_internal == 1 || s1.cmn.in_dtx != 0) do n_bytes_out^ = 0
				enc.n_bits_exceeded += n_bytes_out^ * 8
				enc.n_bits_exceeded -= (ctl.bit_rate * ctl.payload_size_ms) / 1000
				enc.n_bits_exceeded = limit32(enc.n_bits_exceeded, 0, 10000)
				speech_act_thr_for_switch_q8 := smlawb(SE_FIX_SPEECH_ACTIVITY_DTX_THRES_Q8, SE_FIX_SWITCH_SLOPE_Q24, enc.time_since_switch_allowed_ms)
				if s0.cmn.speech_activity_q8 < speech_act_thr_for_switch_q8 {
					enc.allow_bandwidth_switch = 1
					enc.time_since_switch_allowed_ms = 0
				} else {
					enc.allow_bandwidth_switch = 0
					enc.time_since_switch_allowed_ms += ctl.payload_size_ms
				}
			}
			if n_samples_in == 0 do break
		} else {
			break
		}
		curr_block += 1
	}
	enc.n_prev_channels_internal = ctl.n_channels_internal
	ctl.allow_bandwidth_switch = enc.allow_bandwidth_switch
	ctl.in_wb_mode_without_variable_lp = i32(s0.cmn.fs_khz == 16 && s0.cmn.slp.mode == 0)
	ctl.internal_sample_rate = smulbb(s0.cmn.fs_khz, 1000)
	ctl.stereo_width_q14 = ctl.to_mono != 0 ? 0 : i32(enc.stereo.smth_width_q14)
	if prefill_flag != 0 {
		ctl.payload_size_ms = tmp_payload_size_ms
		ctl.complexity = tmp_complexity
		for n in 0 ..< int(ctl.n_channels_internal) {
			enc.state[n].cmn.controlled_since_last_payload = 0
			enc.state[n].cmn.prefill_flag = 0
		}
	}
	ctl.signal_type = i32(s0.cmn.indices.signal_type)
	ctl.offset = i32(silk_Quantization_Offsets_Q10[s0.cmn.indices.signal_type >> 1][s0.cmn.indices.quant_offset_type])
	return ret
}
