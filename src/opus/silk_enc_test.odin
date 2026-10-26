package opus

import "core:log"
import "core:math"
import "core:testing"

@(test)
test_silk_encode_roundtrip :: proc(t: ^testing.T) {
	N_FRAMES :: 50
	enc := new(Silk_Encoder)
	defer free(enc)
	dec := new(Silk_Decoder)
	defer free(dec)
	ctl: Silk_Enc_Control
	testing.expect_value(t, silk_init_encoder(enc, &ctl), 0)
	silk_init_decoder(dec)
	dctl := Silk_Dec_Control {
		n_channels_api       = 1,
		n_channels_internal  = 1,
		api_sample_rate      = 48000,
		internal_sample_rate = 16000,
		payload_size_ms      = 20,
	}
	input := make([]i16, N_FRAMES * 960)
	defer delete(input)
	output := make([]i16, N_FRAMES * 960)
	defer delete(output)
	phase: f64
	seed: u32 = 1
	for i in 0 ..< len(input) {
		f0 := 150 + 20 * math.sin(2 * math.PI * f64(i) / 48000)
		phase += 2 * math.PI * f0 / 48000
		v: f64 = 0
		for h in 1 ..= 8 do v += math.sin(f64(h) * phase) / f64(h)
		seed = seed * 1664525 + 1013904223
		v = 6000 * v + f64(i32(seed >> 16) - 32768) / 64
		input[i] = i16(v)
	}
	buf: [1275]u8
	for f in 0 ..< N_FRAMES {
		ctl.n_channels_api = 1
		ctl.n_channels_internal = 1
		ctl.api_sample_rate = 48000
		ctl.max_internal_sample_rate = 16000
		ctl.min_internal_sample_rate = 16000
		ctl.desired_internal_sample_rate = 16000
		ctl.payload_size_ms = 20
		ctl.bit_rate = 32000
		ctl.complexity = 10
		ctl.use_inband_fec = 1
		ctl.lbrr_coded = 1
		ctl.packet_loss_percentage = 10
		ctl.max_bits = 1274 * 8
		enc_r: Range
		ec_enc_init(&enc_r, buf[:])
		nb: i32 = 1275
		testing.expect_value(t, silk_encode(enc, &ctl, input[f * 960:(f + 1) * 960], 960, &enc_r, &nb, 0, -1), 0)
		ec_enc_done(&enc_r)
		testing.expect(t, nb > 0)
		dec_r: Range
		ec_dec_init(&dec_r, buf[:enc_r.offs])
		n: int
		testing.expect_value(t, silk_decode(dec, &dctl, 0, true, &dec_r, output[f * 960:], &n), 0)
		testing.expect_value(t, n, 960)
		testing.expect_value(t, dec_r.rng, enc_r.rng)
	}
	// align codec delay, measure SNR over the second half
	best_lag, best := 0, f64(-1e30)
	start := len(input) / 2
	L := len(input) / 4
	for lag in 0 ..< 600 {
		s: f64 = 0
		for i in start ..< start + L do s += f64(input[i]) * f64(output[i + lag])
		if s > best {
			best = s
			best_lag = lag
		}
	}
	sig, err: f64
	for i in start ..< start + L {
		d := f64(input[i]) - f64(output[i + best_lag])
		sig += f64(input[i]) * f64(input[i])
		err += d * d
	}
	snr := 10 * math.log10(sig / err)
	log.infof("SILK roundtrip SNR %.2f dB (lag %d)", snr, best_lag)
	testing.expectf(t, snr > 5, "SILK roundtrip SNR %.2f dB (lag %d)", snr, best_lag)
}
