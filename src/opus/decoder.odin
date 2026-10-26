package opus

// Opus decoder (opus_decoder.c + packet parsing from opus.c).

import "base:runtime"

Error :: enum i32 {
	None             = 0,
	Bad_Arg          = -1,
	Buffer_Too_Small = -2,
	Internal_Error   = -3,
	Invalid_Packet   = -4,
	Unimplemented    = -5,
	Invalid_State    = -6,
	Alloc_Fail       = -7,
}

MODE_SILK_ONLY :: 1000
MODE_HYBRID :: 1001
MODE_CELT_ONLY :: 1002

BANDWIDTH_NARROWBAND :: 1101
BANDWIDTH_MEDIUMBAND :: 1102
BANDWIDTH_WIDEBAND :: 1103
BANDWIDTH_SUPERWIDEBAND :: 1104
BANDWIDTH_FULLBAND :: 1105

Decoder :: struct {
	channels:             int,
	fs:                   int,
	dec_control:          Silk_Dec_Control,
	decode_gain:          int,
	stream_channels:      int,
	bandwidth:            int,
	mode:                 int,
	prev_mode:            int,
	frame_size:           int,
	prev_redundancy:      bool,
	last_packet_duration: int,
	softclip_mem:         [2]f32,
	range_final:          u32,
	silk:                 Silk_Decoder,
	celt:                 Celt_Decoder,
}

// ---------------------------------------------------------------------------
// Packet parsing

packet_get_samples_per_frame :: proc "contextless" (toc: u8, fs: int) -> int {
	if toc & 0x80 != 0 {
		a := int((toc >> 3) & 0x3)
		return (fs << uint(a)) / 400
	} else if toc & 0x60 == 0x60 {
		return toc & 0x08 != 0 ? fs / 50 : fs / 100
	}
	a := int((toc >> 3) & 0x3)
	if a == 3 do return fs * 60 / 1000
	return (fs << uint(a)) / 100
}

packet_get_mode :: proc "contextless" (toc: u8) -> int {
	if toc & 0x80 != 0 do return MODE_CELT_ONLY
	if toc & 0x60 == 0x60 do return MODE_HYBRID
	return MODE_SILK_ONLY
}

packet_get_bandwidth :: proc "contextless" (toc: u8) -> int {
	if toc & 0x80 != 0 {
		bw := BANDWIDTH_MEDIUMBAND + int((toc >> 5) & 0x3)
		if bw == BANDWIDTH_MEDIUMBAND do bw = BANDWIDTH_NARROWBAND
		return bw
	} else if toc & 0x60 == 0x60 {
		return toc & 0x10 != 0 ? BANDWIDTH_FULLBAND : BANDWIDTH_SUPERWIDEBAND
	}
	return BANDWIDTH_NARROWBAND + int((toc >> 5) & 0x3)
}

packet_get_nb_channels :: proc "contextless" (toc: u8) -> int {return toc & 0x4 != 0 ? 2 : 1}

packet_get_nb_frames :: proc "contextless" (packet: []u8) -> (int, Error) {
	if len(packet) < 1 do return 0, .Bad_Arg
	count := packet[0] & 0x3
	if count == 0 do return 1, .None
	if count != 3 do return 2, .None
	if len(packet) < 2 do return 0, .Invalid_Packet
	return int(packet[1] & 0x3F), .None
}

packet_get_nb_samples :: proc "contextless" (packet: []u8, fs: int) -> (int, Error) {
	count, err := packet_get_nb_frames(packet)
	if err != .None do return 0, err
	samples := count * packet_get_samples_per_frame(packet[0], fs)
	if samples * 25 > fs * 3 do return 0, .Invalid_Packet
	return samples, .None
}

@(private = "file")
parse_size :: proc "contextless" (data: []u8, size: ^i32) -> int {
	if len(data) < 1 {
		size^ = -1
		return -1
	} else if data[0] < 252 {
		size^ = i32(data[0])
		return 1
	} else if len(data) < 2 {
		size^ = -1
		return -1
	}
	size^ = 4 * i32(data[1]) + i32(data[0])
	return 2
}

Parsed_Packet :: struct {
	toc:            u8,
	count:          int,
	frames:         [48][]u8,
	payload_offset: int,
	packet_offset:  int,
}

packet_parse :: proc "contextless" (packet: []u8, self_delimited := false) -> (p: Parsed_Packet, err: Error) {
	if len(packet) == 0 do return p, .Invalid_Packet
	size: [48]i32
	framesize := packet_get_samples_per_frame(packet[0], 48000)
	cbr := false
	toc := packet[0]
	pos := 1
	length := i32(len(packet) - 1)
	last_size := length
	pad: i32 = 0
	count: int
	switch toc & 0x3 {
	case 0:
		count = 1
	case 1:
		count = 2
		cbr = true
		if !self_delimited {
			if length & 1 != 0 do return p, .Invalid_Packet
			last_size = length / 2
			size[0] = last_size
		}
	case 2:
		count = 2
		bytes := parse_size(packet[pos:pos + int(length)], &size[0])
		length -= i32(bytes)
		if size[0] < 0 || size[0] > length do return p, .Invalid_Packet
		pos += bytes
		last_size = length - size[0]
	case:
		if length < 1 do return p, .Invalid_Packet
		ch := packet[pos]
		pos += 1
		count = int(ch & 0x3F)
		if count <= 0 || framesize * count > 5760 do return p, .Invalid_Packet
		length -= 1
		if ch & 0x40 != 0 {
			for {
				if length <= 0 do return p, .Invalid_Packet
				pp := packet[pos]
				pos += 1
				length -= 1
				tmp := pp == 255 ? i32(254) : i32(pp)
				length -= tmp
				pad += tmp
				if pp != 255 do break
			}
		}
		if length < 0 do return p, .Invalid_Packet
		cbr = ch & 0x80 == 0
		if !cbr {
			last_size = length
			for i in 0 ..< count - 1 {
				bytes := parse_size(packet[pos:pos + int(length)], &size[i])
				length -= i32(bytes)
				if size[i] < 0 || size[i] > length do return p, .Invalid_Packet
				pos += bytes
				last_size -= i32(bytes) + size[i]
			}
			if last_size < 0 do return p, .Invalid_Packet
		} else if !self_delimited {
			last_size = length / i32(count)
			if last_size * i32(count) != length do return p, .Invalid_Packet
			for i in 0 ..< count - 1 do size[i] = last_size
		}
	}
	if self_delimited {
		bytes := parse_size(packet[pos:pos + int(length)], &size[count - 1])
		length -= i32(bytes)
		if size[count - 1] < 0 || size[count - 1] > length do return p, .Invalid_Packet
		pos += bytes
		if cbr {
			if size[count - 1] * i32(count) > length do return p, .Invalid_Packet
			for i in 0 ..< count - 1 do size[i] = size[count - 1]
		} else if i32(bytes) + size[count - 1] > last_size {
			return p, .Invalid_Packet
		}
	} else {
		if last_size > 1275 do return p, .Invalid_Packet
		size[count - 1] = last_size
	}
	p.payload_offset = pos
	for i in 0 ..< count {
		if pos + int(size[i]) > len(packet) do return p, .Invalid_Packet
		p.frames[i] = packet[pos:pos + int(size[i])]
		pos += int(size[i])
	}
	p.packet_offset = int(pad) + pos
	p.toc = toc
	p.count = count
	return p, .None
}

// ---------------------------------------------------------------------------
// Decoder

decoder_init :: proc(st: ^Decoder, fs: int, channels: int) -> Error {
	if (fs != 48000 && fs != 24000 && fs != 16000 && fs != 12000 && fs != 8000) || (channels != 1 && channels != 2) do return .Bad_Arg
	st^ = {}
	st.stream_channels = channels
	st.channels = channels
	st.fs = fs
	st.dec_control.api_sample_rate = i32(fs)
	st.dec_control.n_channels_api = i32(channels)
	silk_init_decoder(&st.silk)
	if !celt_decoder_init(&st.celt, fs, channels) do return .Bad_Arg
	st.prev_mode = 0
	st.frame_size = fs / 400
	return .None
}

decoder_create :: proc(fs: int, channels: int, allocator := context.allocator) -> (^Decoder, Error) {
	d, aerr := new(Decoder, allocator)
	if aerr != nil do return nil, .Alloc_Fail
	if err := decoder_init(d, fs, channels); err != .None {
		free(d, allocator)
		return nil, err
	}
	return d, .None
}

decoder_destroy :: proc(d: ^Decoder, allocator := context.allocator) {free(d, allocator)}

decoder_reset :: proc(st: ^Decoder) {
	st.stream_channels = st.channels
	st.bandwidth = 0
	st.mode = 0
	st.prev_mode = 0
	st.prev_redundancy = false
	st.last_packet_duration = 0
	st.softclip_mem = {}
	st.range_final = 0
	celt_decoder_reset(&st.celt)
	silk_init_decoder(&st.silk)
	st.frame_size = st.fs / 400
}

// Final range coder state of the last decoded packet (for conformance checks).
decoder_final_range :: proc(st: ^Decoder) -> u32 {return st.range_final}

// Duration (samples per channel at the decoder rate) of the last packet.
decoder_last_packet_duration :: proc(st: ^Decoder) -> int {return st.last_packet_duration}

// Output gain in Q8 dB (OPUS_SET_GAIN).
decoder_set_gain :: proc(st: ^Decoder, q8_db: int) {st.decode_gain = clamp(q8_db, -32768, 32767)}

@(private = "file")
smooth_fade :: proc "contextless" (in1, in2, out: []f32, overlap, channels, fs: int) {
	inc := 48000 / fs
	for c in 0 ..< channels {
		for i in 0 ..< overlap {
			w := window120[i * inc] * window120[i * inc]
			out[i * channels + c] = w * in2[i * channels + c] + (1 - w) * in1[i * channels + c]
		}
	}
}

@(private = "file")
decode_frame :: proc(st: ^Decoder, data_: []u8, pcm: []f32, frame_size_: int, decode_fec: bool) -> (int, Error) {
	data := data_
	frame_size := frame_size_
	F20 := st.fs / 50
	F10 := F20 >> 1
	F5 := F10 >> 1
	F2_5 := F5 >> 1
	if frame_size < F2_5 do return 0, .Buffer_Too_Small
	frame_size = min(frame_size, st.fs / 25 * 3)
	if len(data) <= 1 {
		data = nil
		frame_size = min(frame_size, st.frame_size)
	}
	audiosize, mode, bandwidth: int
	dec: Range
	length := len(data)
	if data != nil {
		audiosize = st.frame_size
		mode = st.mode
		bandwidth = st.bandwidth
		ec_dec_init(&dec, data)
	} else {
		audiosize = frame_size
		mode = st.prev_mode
		bandwidth = 0
		if mode == 0 {
			for i in 0 ..< audiosize * st.channels do pcm[i] = 0
			return audiosize, .None
		}
		if audiosize > F20 {
			pos := 0
			for audiosize > 0 {
				ret, err := decode_frame(st, nil, pcm[pos * st.channels:], min(audiosize, F20), false)
				if err != .None do return 0, err
				pos += ret
				audiosize -= ret
			}
			return frame_size, .None
		} else if audiosize < F20 {
			if audiosize > F10 {
				audiosize = F10
			} else if mode != MODE_SILK_ONLY && audiosize > F5 && audiosize < F10 {
				audiosize = F5
			}
		}
	}
	transition := false
	pcm_transition_celt: [480 * 2]f32
	pcm_transition_silk: [480 * 2]f32
	pcm_transition: []f32
	if data != nil && st.prev_mode > 0 &&
	   ((mode == MODE_CELT_ONLY && st.prev_mode != MODE_CELT_ONLY && !st.prev_redundancy) || (mode != MODE_CELT_ONLY && st.prev_mode == MODE_CELT_ONLY)) {
		transition = true
	}
	if transition && mode == MODE_CELT_ONLY {
		pcm_transition = pcm_transition_celt[:]
		decode_frame(st, nil, pcm_transition, min(F5, audiosize), false)
	}
	if audiosize > frame_size do return 0, .Bad_Arg
	frame_size = audiosize

	pcm_silk: [960 * 3 * 2]i16 // up to 60 ms @48k stereo
	if mode != MODE_CELT_ONLY {
		if st.prev_mode == MODE_CELT_ONLY do silk_init_decoder(&st.silk)
		st.dec_control.payload_size_ms = i32(max(10, 1000 * audiosize / st.fs))
		if data != nil {
			st.dec_control.n_channels_internal = i32(st.stream_channels)
			if mode == MODE_SILK_ONLY {
				switch bandwidth {
				case BANDWIDTH_NARROWBAND: st.dec_control.internal_sample_rate = 8000
				case BANDWIDTH_MEDIUMBAND: st.dec_control.internal_sample_rate = 12000
				case: st.dec_control.internal_sample_rate = 16000
				}
			} else {
				st.dec_control.internal_sample_rate = 16000
			}
		}
		lost_flag := data == nil ? 1 : 2 * int(decode_fec)
		decoded := 0
		for {
			first_frame := decoded == 0
			silk_frame_size: int
			ret := silk_decode(&st.silk, &st.dec_control, lost_flag, first_frame, &dec, pcm_silk[decoded * st.channels:], &silk_frame_size)
			if ret != 0 {
				if lost_flag != 0 {
					silk_frame_size = frame_size
					for i in 0 ..< frame_size * st.channels do pcm_silk[decoded * st.channels + i] = 0
				} else {
					return 0, .Internal_Error
				}
			}
			decoded += silk_frame_size
			if decoded >= frame_size do break
		}
	}
	start_band := 0
	redundancy := false
	redundancy_bytes := 0
	celt_to_silk := false
	if !decode_fec && mode != MODE_CELT_ONLY && data != nil && int(ec_tell(&dec)) + 17 + 20 * int(st.mode == MODE_HYBRID) <= 8 * length {
		if mode == MODE_HYBRID do redundancy = ec_dec_bit_logp(&dec, 12)
		else do redundancy = true
		if redundancy {
			celt_to_silk = ec_dec_bit_logp(&dec, 1)
			redundancy_bytes = mode == MODE_HYBRID ? int(ec_dec_uint(&dec, 256)) + 2 : length - ((int(ec_tell(&dec)) + 7) >> 3)
			length -= redundancy_bytes
			if length * 8 < int(ec_tell(&dec)) {
				length = 0
				redundancy_bytes = 0
				redundancy = false
			}
			dec.storage -= u32(redundancy_bytes)
		}
	}
	if mode != MODE_CELT_ONLY do start_band = 17
	if redundancy do transition = false
	if transition && mode != MODE_CELT_ONLY {
		pcm_transition = pcm_transition_silk[:]
		decode_frame(st, nil, pcm_transition, min(F5, audiosize), false)
	}
	if bandwidth != 0 {
		endband := 21
		switch bandwidth {
		case BANDWIDTH_NARROWBAND: endband = 13
		case BANDWIDTH_MEDIUMBAND, BANDWIDTH_WIDEBAND: endband = 17
		case BANDWIDTH_SUPERWIDEBAND: endband = 19
		case BANDWIDTH_FULLBAND: endband = 21
		}
		st.celt.end = endband
	}
	st.celt.stream_channels = st.stream_channels
	redundant_audio: [240 * 2]f32
	redundant_rng: u32 = 0
	if redundancy && celt_to_silk {
		st.celt.start = 0
		celt_decode_with_ec(&st.celt, data[length:length + redundancy_bytes], redundant_audio[:], F5, nil)
		redundant_rng = st.celt.rng
	}
	st.celt.start = start_band
	celt_err := Celt_Error.None
	if mode != MODE_SILK_ONLY {
		celt_frame_size := min(F20, frame_size)
		if mode != st.prev_mode && st.prev_mode > 0 && !st.prev_redundancy do celt_decoder_reset(&st.celt)
		cdata := decode_fec ? nil : data[:length]
		_, celt_err = celt_decode_with_ec(&st.celt, cdata, pcm, celt_frame_size, &dec)
	} else {
		silence := [2]u8{0xFF, 0xFF}
		for i in 0 ..< frame_size * st.channels do pcm[i] = 0
		if st.prev_mode == MODE_HYBRID && !(redundancy && celt_to_silk && st.prev_redundancy) {
			st.celt.start = 0
			celt_decode_with_ec(&st.celt, silence[:], pcm, F2_5, nil)
		}
	}
	if mode != MODE_CELT_ONLY {
		for i in 0 ..< frame_size * st.channels do pcm[i] = pcm[i] + (1.0 / 32768) * f32(pcm_silk[i])
	}
	if redundancy && !celt_to_silk {
		celt_decoder_reset(&st.celt)
		st.celt.start = 0
		celt_decode_with_ec(&st.celt, data[length:length + redundancy_bytes], redundant_audio[:], F5, nil)
		redundant_rng = st.celt.rng
		o := st.channels * (frame_size - F2_5)
		smooth_fade(pcm[o:], redundant_audio[st.channels * F2_5:], pcm[o:], F2_5, st.channels, st.fs)
	}
	if redundancy && celt_to_silk {
		for c in 0 ..< st.channels {
			for i in 0 ..< F2_5 do pcm[st.channels * i + c] = redundant_audio[st.channels * i + c]
		}
		o := st.channels * F2_5
		smooth_fade(redundant_audio[o:], pcm[o:], pcm[o:], F2_5, st.channels, st.fs)
	}
	if transition {
		if audiosize >= F5 {
			for i in 0 ..< st.channels * F2_5 do pcm[i] = pcm_transition[i]
			o := st.channels * F2_5
			smooth_fade(pcm_transition[o:], pcm[o:], pcm[o:], F2_5, st.channels, st.fs)
		} else {
			smooth_fade(pcm_transition, pcm, pcm, F2_5, st.channels, st.fs)
		}
	}
	if st.decode_gain != 0 {
		gain := celt_exp2(6.48814081e-4 * f32(st.decode_gain))
		for i in 0 ..< frame_size * st.channels {
			x := pcm[i] * gain
			pcm[i] = clamp(x, -32767, 32767)
		}
	}
	if length <= 1 {
		st.range_final = 0
	} else {
		st.range_final = dec.rng ~ redundant_rng
	}
	st.prev_mode = mode
	st.prev_redundancy = redundancy && !celt_to_silk
	if celt_err != .None do return 0, .Internal_Error
	return audiosize, .None
}

@(private = "file")
decode_native :: proc(st: ^Decoder, data: []u8, pcm: []f32, frame_size: int, decode_fec: bool, soft_clip: bool) -> (int, Error) {
	if (decode_fec || len(data) == 0) && frame_size % (st.fs / 400) != 0 do return 0, .Bad_Arg
	if len(data) == 0 {
		pcm_count := 0
		for pcm_count < frame_size {
			ret, err := decode_frame(st, nil, pcm[pcm_count * st.channels:], frame_size - pcm_count, false)
			if err != .None do return 0, err
			pcm_count += ret
		}
		st.last_packet_duration = pcm_count
		return pcm_count, .None
	}
	packet_mode := packet_get_mode(data[0])
	packet_bandwidth := packet_get_bandwidth(data[0])
	packet_frame_size := packet_get_samples_per_frame(data[0], st.fs)
	packet_stream_channels := packet_get_nb_channels(data[0])
	pp, perr := packet_parse(data)
	if perr != .None do return 0, perr
	if decode_fec {
		if frame_size < packet_frame_size || packet_mode == MODE_CELT_ONLY || st.mode == MODE_CELT_ONLY {
			return decode_native(st, nil, pcm, frame_size, false, soft_clip)
		}
		duration_copy := st.last_packet_duration
		if frame_size - packet_frame_size != 0 {
			_, err := decode_native(st, nil, pcm, frame_size - packet_frame_size, false, soft_clip)
			if err != .None {
				st.last_packet_duration = duration_copy
				return 0, err
			}
		}
		st.mode = packet_mode
		st.bandwidth = packet_bandwidth
		st.frame_size = packet_frame_size
		st.stream_channels = packet_stream_channels
		_, err := decode_frame(st, pp.frames[0], pcm[st.channels * (frame_size - packet_frame_size):], packet_frame_size, true)
		if err != .None do return 0, err
		st.last_packet_duration = frame_size
		return frame_size, .None
	}
	if pp.count * packet_frame_size > frame_size do return 0, .Buffer_Too_Small
	st.mode = packet_mode
	st.bandwidth = packet_bandwidth
	st.frame_size = packet_frame_size
	st.stream_channels = packet_stream_channels
	nb := 0
	for i in 0 ..< pp.count {
		ret, err := decode_frame(st, pp.frames[i], pcm[nb * st.channels:], frame_size - nb, false)
		if err != .None do return 0, err
		nb += ret
	}
	st.last_packet_duration = nb
	if soft_clip {
		pcm_soft_clip(pcm[:nb * st.channels], nb, st.channels, &st.softclip_mem)
	} else {
		st.softclip_mem = {}
	}
	return nb, .None
}

// Decode a packet (nil/empty = lost: packet loss concealment). pcm holds
// interleaved f32 (±1.0); its length / channels is the max frame size, which
// for PLC / FEC must be exactly the duration to fill (a multiple of 2.5 ms).
// fec = true decodes the in-band FEC (LBRR) copy of the *previous* packet that
// is carried in `packet`.
decode :: proc(st: ^Decoder, packet: []u8, pcm: []f32, fec := false) -> (int, Error) {
	frame_size := len(pcm) / st.channels
	if frame_size <= 0 do return 0, .Bad_Arg
	return decode_native(st, packet, pcm, frame_size, fec, false)
}

// Same as decode, s16 output (applies libopus's soft clipper like opus_decode).
decode_i16 :: proc(st: ^Decoder, packet: []u8, pcm: []i16, fec := false) -> (int, Error) {
	frame_size := len(pcm) / st.channels
	if frame_size <= 0 do return 0, .Bad_Arg
	if len(packet) > 0 && !fec {
		ns, err := packet_get_nb_samples(packet, st.fs)
		if err != .None || ns <= 0 do return 0, .Invalid_Packet
		frame_size = min(frame_size, ns)
	}
	tmp: [5760 * 2]f32
	n, err := decode_native(st, packet, tmp[:frame_size * st.channels], frame_size, fec, true)
	if err != .None do return 0, err
	for i in 0 ..< n * st.channels {
		x := tmp[i] * CELT_SIG_SCALE
		x = clamp(x, -32768, 32767)
		pcm[i] = i16(float2int(x))
	}
	return n, .None
}

float2int :: #force_inline proc "contextless" (x: f32) -> i32 {
	// lrintf: round half to even
	r := f32(i32(x))
	d := x - r
	if d > 0.5 || (d == 0.5 && i32(r) & 1 != 0) do return i32(r) + 1
	if d < -0.5 || (d == -0.5 && i32(r) & 1 != 0) do return i32(r) - 1
	return i32(r)
}

pcm_soft_clip :: proc "contextless" (x_: []f32, n, C: int, declip_mem: ^[2]f32) {
	if C < 1 || n < 1 do return
	for i in 0 ..< n * C do x_[i] = max(-2, min(2, x_[i]))
	for c in 0 ..< C {
		x := x_[c:]
		a := declip_mem[c]
		for i in 0 ..< n {
			if x[i * C] * a >= 0 do break
			x[i * C] = x[i * C] + a * x[i * C] * x[i * C]
		}
		curr := 0
		x0 := x[0]
		for {
			i := curr
			for ; i < n; i += 1 do if x[i * C] > 1 || x[i * C] < -1 do break
			if i == n {
				a = 0
				break
			}
			peak_pos := i
			start := i
			end := i
			maxval := abs(x[i * C])
			for start > 0 && x[i * C] * x[(start - 1) * C] >= 0 do start -= 1
			for end < n && x[i * C] * x[end * C] >= 0 {
				if abs(x[end * C]) > maxval {
					maxval = abs(x[end * C])
					peak_pos = end
				}
				end += 1
			}
			special := start == 0 && x[i * C] * x[0] >= 0
			a = (maxval - 1) / (maxval * maxval)
			a += a * 2.4e-7
			if x[i * C] > 0 do a = -a
			for k in start ..< end do x[k * C] = x[k * C] + a * x[k * C] * x[k * C]
			if special && peak_pos >= 2 {
				offset := x0 - x[0]
				delta := offset / f32(peak_pos)
				for k in curr ..< peak_pos {
					offset -= delta
					x[k * C] += offset
					x[k * C] = max(-1, min(1, x[k * C]))
				}
			}
			curr = end
			if curr == n do break
		}
		declip_mem[c] = a
	}
}

@(private = "file")
_unused_rt :: runtime.Allocator
