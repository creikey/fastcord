package opus

// Opus encoder, phase 1: CELT-only (all bandwidths, 2.5–20 ms frames, longer
// durations packed as code-3 multi-frame packets), 48 kHz input, mono/stereo,
// VBR/CVBR/CBR. SILK/hybrid encoding is not implemented, so in-band FEC
// (LBRR, a SILK feature) cannot be produced; the ctl is accepted and stored.

Application :: enum {
	VOIP,
	Audio,
	Restricted_Lowdelay,
}

Encoder :: struct {
	fs:               int,
	channels:         int,
	application:      Application,
	celt:             Celt_Encoder,
	bitrate:          i32,
	vbr:              bool,
	vbr_constraint:   bool,
	inband_fec:       bool,
	packet_loss_perc: int,
	complexity:       int,
	bandwidth:        int,
	dtx:              bool,
	hp_mem:           [4]f32,
	range_final:      u32,
}

encoder_init :: proc(st: ^Encoder, fs: int, channels: int, app: Application) -> Error {
	if fs != 48000 do return .Bad_Arg // phase 1: 48 kHz only
	if channels != 1 && channels != 2 do return .Bad_Arg
	st^ = {}
	st.fs = fs
	st.channels = channels
	st.application = app
	st.bitrate = i32(channels == 2 ? 96000 : 64000)
	st.vbr = true
	st.vbr_constraint = false
	st.complexity = 10
	st.bandwidth = BANDWIDTH_FULLBAND
	celt_encoder_init(&st.celt, channels)
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

encoder_set_bitrate :: proc(st: ^Encoder, bps: int) {st.bitrate = i32(clamp(bps, 6000, 510000))}
encoder_set_vbr :: proc(st: ^Encoder, on: bool) {st.vbr = on}
encoder_set_vbr_constraint :: proc(st: ^Encoder, on: bool) {st.vbr_constraint = on}
encoder_set_complexity :: proc(st: ^Encoder, c: int) {st.complexity = clamp(c, 0, 10)}
encoder_set_inband_fec :: proc(st: ^Encoder, on: bool) {st.inband_fec = on} // stored; no LBRR in CELT-only phase
encoder_set_packet_loss_perc :: proc(st: ^Encoder, p: int) {st.packet_loss_perc = clamp(p, 0, 100)}
encoder_set_dtx :: proc(st: ^Encoder, on: bool) {st.dtx = on} // stored; not implemented
encoder_set_bandwidth :: proc(st: ^Encoder, bw: int) {st.bandwidth = clamp(bw, BANDWIDTH_NARROWBAND, BANDWIDTH_FULLBAND)}
encoder_final_range :: proc(st: ^Encoder) -> u32 {return st.range_final}
encoder_reset :: proc(st: ^Encoder) {
	celt_encoder_reset(&st.celt)
	st.hp_mem = {}
}

// One-pole DC reject (3 Hz), as opus_encoder.c dc_reject.
@(private = "file")
dc_reject :: proc(st: ^Encoder, in_: []f32, out: []f32, len: int) {
	coef := 6.3 * 3.0 / f32(st.fs)
	coef2 := 1 - coef
	C := st.channels
	for c in 0 ..< C {
		m0 := st.hp_mem[2 * c]
		m2 := st.hp_mem[2 * c + 1]
		for i in 0 ..< len {
			x := in_[C * i + c]
			y := x - m0
			m0 = coef * x + VERY_SMALL + coef2 * m0
			out[C * i + c] = y - m2
			m2 = coef * y + VERY_SMALL + coef2 * m2
			_ = m2
		}
		st.hp_mem[2 * c] = m0
		st.hp_mem[2 * c + 1] = m2
	}
}

@(private = "file")
celt_end_band :: proc(bw: int) -> int {
	switch bw {
	case BANDWIDTH_NARROWBAND: return 13
	case BANDWIDTH_MEDIUMBAND, BANDWIDTH_WIDEBAND: return 17
	case BANDWIDTH_SUPERWIDEBAND: return 19
	}
	return 21
}

@(private = "file")
toc_byte :: proc(bw: int, lm: int, stereo: bool) -> u8 {
	b := bw == BANDWIDTH_MEDIUMBAND ? BANDWIDTH_WIDEBAND : bw
	bwi := 0
	switch b {
	case BANDWIDTH_NARROWBAND: bwi = 0
	case BANDWIDTH_WIDEBAND: bwi = 1
	case BANDWIDTH_SUPERWIDEBAND: bwi = 2
	case: bwi = 3
	}
	config := 16 + 4 * bwi + lm
	return u8(config << 3) | (stereo ? 0x4 : 0)
}

@(private = "file")
encode_frame :: proc(st: ^Encoder, pcm: []f32, frame_size: int, out: []u8, bitrate: i32) -> (int, Error) {
	c := &st.celt
	c.bitrate = bitrate
	c.vbr = st.vbr
	c.constrained_vbr = st.vbr_constraint
	c.complexity = st.complexity
	c.loss_rate = st.packet_loss_perc
	c.end = celt_end_band(st.bandwidth)
	c.stream_channels = st.channels
	if !st.vbr {
		// CBR: celt uses bitrate to size the frame; leave a byte for the TOC.
		c.bitrate = bitrate - i32(8 * 48000 / frame_size)
	}
	n, err := celt_encode(c, pcm, frame_size, out)
	if err != .None do return 0, .Internal_Error
	st.range_final = c.rng
	return n, .None
}

// Encode one packet from interleaved float pcm (±1.0). Frame duration is
// len(pcm)/channels samples: 120, 240, 480, 960 (single CELT frame) or
// 1920/2880 (code-3 packet of 20 ms frames). Returns bytes written to out.
encode :: proc(st: ^Encoder, pcm: []f32, out: []u8) -> (int, Error) {
	frame_size := len(pcm) / st.channels
	if len(out) < 3 do return 0, .Buffer_Too_Small
	filtered: [2880 * 2]f32
	if frame_size > 2880 do return 0, .Bad_Arg
	dc_reject(st, pcm, filtered[:], frame_size)
	lm := -1
	switch frame_size {
	case 120: lm = 0
	case 240: lm = 1
	case 480: lm = 2
	case 960: lm = 3
	case 1920, 2880:
	case: return 0, .Bad_Arg
	}
	max_bytes := min(len(out), 1276 * (frame_size > 960 ? 3 : 1))
	if lm >= 0 {
		out[0] = toc_byte(st.bandwidth, lm, st.channels == 2)
		n, err := encode_frame(st, filtered[:frame_size * st.channels], frame_size, out[1:min(max_bytes, 1276)], st.bitrate)
		if err != .None do return 0, err
		return n + 1, .None
	}
	// Code 3, VBR: [toc][count|0x80][sizes...][frames...]
	count := frame_size / 960
	frames: [3][1275]u8
	sizes: [3]int
	for f in 0 ..< count {
		n, err := encode_frame(st, filtered[f * 960 * st.channels:(f + 1) * 960 * st.channels], 960, frames[f][:], st.bitrate)
		if err != .None do return 0, err
		sizes[f] = n
	}
	pos := 0
	out[pos] = toc_byte(st.bandwidth, 3, st.channels == 2) | 0x3
	pos += 1
	out[pos] = u8(count) | 0x80
	pos += 1
	for f in 0 ..< count - 1 {
		s := sizes[f]
		if s < 252 {
			out[pos] = u8(s)
			pos += 1
		} else {
			out[pos] = u8(252 + (s & 3))
			out[pos + 1] = u8((s - int(out[pos])) >> 2)
			pos += 2
		}
	}
	for f in 0 ..< count {
		if pos + sizes[f] > len(out) do return 0, .Buffer_Too_Small
		copy(out[pos:pos + sizes[f]], frames[f][:sizes[f]])
		pos += sizes[f]
	}
	return pos, .None
}

// Same as encode, s16 input.
encode_i16 :: proc(st: ^Encoder, pcm: []i16, out: []u8) -> (int, Error) {
	tmp: [2880 * 2]f32
	n := min(len(pcm), len(tmp))
	for i in 0 ..< n do tmp[i] = f32(pcm[i]) * (1.0 / 32768)
	return encode(st, tmp[:n], out)
}
