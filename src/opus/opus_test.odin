package opus

import "core:math"
import "core:testing"

@(test)
test_roundtrip_celt :: proc(t: ^testing.T) {
	// RESTRICTED_LOWDELAY: CELT only, no delay compensation (120-sample codec delay).
	enc := new(Encoder)
	defer free(enc)
	dec: Decoder
	testing.expect_value(t, encoder_init(enc, 48000, 2, .Restricted_Lowdelay), Error.None)
	testing.expect_value(t, decoder_init(&dec, 48000, 2), Error.None)
	encoder_set_bitrate(enc, 64000)
	pcm: [960 * 2]f32
	out: [960 * 2]f32
	pkt: [1500]u8
	err_e, sig_e: f64
	hist: [960 * 2 * 4]f32 // input history to align with codec delay (120 samples)
	phase: f64
	for frame in 0 ..< 50 {
		for i in 0 ..< 960 {
			v := f32(0.3 * math.sin(phase))
			phase += 2 * math.PI * 440 / 48000
			pcm[2 * i] = v
			pcm[2 * i + 1] = -v
		}
		n, e := encode(enc, pcm[:], pkt[:])
		testing.expect_value(t, e, Error.None)
		got, de := decode(&dec, pkt[:n], out[:])
		testing.expect_value(t, de, Error.None)
		testing.expect_value(t, got, 960)
		testing.expect_value(t, decoder_final_range(&dec), encoder_final_range(enc))
		// shift history and compare with 120-sample delay after warmup
		copy(hist[:960 * 2], hist[960 * 2:960 * 4])
		copy(hist[960 * 2:960 * 4], pcm[:])
		if frame > 5 {
			for i in 0 ..< 960 * 2 {
				ref := hist[960 * 2 + i - 240]
				d := f64(out[i] - ref)
				err_e += d * d
				sig_e += f64(ref) * f64(ref)
			}
		}
	}
	snr := 10 * math.log10(sig_e / err_e)
	testing.expectf(t, snr > 15, "roundtrip SNR %.1f dB", snr)
}

@(test)
test_packet_parse :: proc(t: ^testing.T) {
	// code 3, CBR, 3 frames of 2 bytes
	p := []u8{0x03 | (31 << 3), 0x03, 1, 2, 3, 4, 5, 6}
	pp, err := packet_parse(p)
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, pp.count, 3)
	testing.expect_value(t, len(pp.frames[2]), 2)
	n, _ := packet_get_nb_samples(p, 48000)
	testing.expect_value(t, n, 2880)
	_, err = packet_parse([]u8{0x01, 1, 2, 3}) // code 1 with odd payload
	testing.expect_value(t, err, Error.Invalid_Packet)
}

@(test)
test_plc_silence_before_first_packet :: proc(t: ^testing.T) {
	dec: Decoder
	decoder_init(&dec, 48000, 1)
	out: [960]f32
	n, err := decode(&dec, nil, out[:])
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, n, 960)
}
