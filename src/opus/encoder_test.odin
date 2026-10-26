package opus

import "core:math"
import "core:math/rand"
import "core:testing"

// Synthetic voiced signal: harmonics of a gliding pitch plus a little noise,
// with a pause in the middle.
@(private = "file")
speechish :: proc(buf: []f32, frame: int, phase: ^f64, r: ^rand.Default_Random_State) {
	gen := rand.default_random_generator(r)
	silent := frame >= 40 && frame < 60
	for i in 0 ..< len(buf) {
		t := f64(frame * len(buf) + i) / 48000
		f0 := 140 + 40 * math.sin(2 * math.PI * 0.7 * t)
		phase^ += 2 * math.PI * f0 / 48000
		v: f64 = 0
		for h in 1 ..= 12 do v += math.sin(f64(h) * phase^) / f64(h)
		env := 0.5 + 0.5 * math.sin(2 * math.PI * 3 * t)
		v = 0.15 * env * v + 0.003 * (rand.float64(gen) - 0.5)
		buf[i] = silent ? 0 : f32(v)
	}
}

// Best normalized cross-correlation of decoded vs input over lags 0..1000.
@(private = "file")
best_corr :: proc(ref, got: []f32) -> f64 {
	best: f64 = 0
	for lag in 0 ..< 1000 {
		xy, xx, yy: f64
		for i in 0 ..< len(ref) - 1000 {
			a := f64(ref[i])
			b := f64(got[i + lag])
			xy += a * b
			xx += a * a
			yy += b * b
		}
		c := xy / math.sqrt(xx * yy + 1e-30)
		best = max(best, c)
	}
	return best
}

@(test)
test_voip_modes_roundtrip :: proc(t: ^testing.T) {
	// Discord voice: VOIP, mono, 20 ms, in-band FEC; 64k -> hybrid FB, 12k -> SILK.
	Case :: struct {bitrate, mode: int}
	for c in ([]Case{{64000, MODE_HYBRID}, {12000, MODE_SILK_ONLY}, {128000, MODE_CELT_ONLY}}) {
		enc := new(Encoder)
		defer free(enc)
		dec := new(Decoder)
		defer free(dec)
		testing.expect_value(t, encoder_init(enc, 48000, 1, .VOIP), Error.None)
		decoder_init(dec, 48000, 1)
		encoder_set_bitrate(enc, c.bitrate)
		encoder_set_inband_fec(enc, true)
		encoder_set_signal(enc, SIGNAL_VOICE) // the synthetic signal can look like music to the analysis MLP
		r := rand.create(1)
		phase: f64
		N :: 100
		ref := make([]f32, N * 960)
		got := make([]f32, N * 960)
		defer delete(ref)
		defer delete(got)
		pkt: [1500]u8
		modes: [3]int
		for f in 0 ..< N {
			x := ref[f * 960:(f + 1) * 960]
			speechish(x, f, &phase, &r)
			n, err := encode(enc, x, pkt[:])
			testing.expect_value(t, err, Error.None)
			m := packet_get_mode(pkt[0])
			modes[m - MODE_SILK_ONLY] += 1
			k, derr := decode(dec, pkt[:n], got[f * 960:(f + 1) * 960])
			testing.expect_value(t, derr, Error.None)
			testing.expect_value(t, k, 960)
			testing.expectf(t, decoder_final_range(dec) == encoder_final_range(enc), "bitrate %d frame %d: range mismatch", c.bitrate, f)
		}
		testing.expectf(t, modes[c.mode - MODE_SILK_ONLY] >= 95, "bitrate %d: modes %v", c.bitrate, modes)
		corr := best_corr(ref, got)
		testing.expectf(t, corr > 0.8, "bitrate %d: correlation %.3f", c.bitrate, corr)
	}
}

@(test)
test_dtx_and_fec :: proc(t: ^testing.T) {
	enc := new(Encoder)
	defer free(enc)
	dec := new(Decoder)
	defer free(dec)
	encoder_init(enc, 48000, 1, .VOIP)
	decoder_init(dec, 48000, 1)
	encoder_set_bitrate(enc, 24000)
	encoder_set_inband_fec(enc, true)
	encoder_set_packet_loss_perc(enc, 20)
	encoder_set_dtx(enc, true)
	r := rand.create(2)
	phase: f64
	pkts: [100][1500]u8
	lens: [100]int
	x: [960]f32
	dtx_frames := 0
	for f in 0 ..< 100 {
		speechish(x[:], f, &phase, &r)
		n, err := encode(enc, x[:], pkts[f][:])
		testing.expect_value(t, err, Error.None)
		lens[f] = n
		if n == 1 do dtx_frames += 1
		if f >= 40 && f < 60 do testing.expect(t, packet_get_mode(pkts[f][0]) != MODE_CELT_ONLY)
	}
	// 20 frames of digital silence: DTX after the 10-frame hangover.
	testing.expectf(t, dtx_frames >= 8, "dtx frames %d", dtx_frames)
	// Lose every 5th voiced packet and recover it from the next packet's LBRR.
	out: [960]f32
	fec_used := 0
	for f in 0 ..< 99 {
		if f % 5 == 2 && lens[f] > 1 && lens[f + 1] > 1 && f < 40 {
			k, err := decode(dec, pkts[f + 1][:lens[f + 1]], out[:], true)
			testing.expect_value(t, err, Error.None)
			testing.expect_value(t, k, 960)
			e: f32
			for v in out do e += v * v
			testing.expectf(t, e > 0, "frame %d: FEC decode silent", f)
			fec_used += 1
			continue
		}
		k, err := decode(dec, pkts[f][:lens[f]], out[:])
		testing.expect_value(t, err, Error.None)
		testing.expect_value(t, k, 960)
	}
	testing.expect(t, fec_used >= 6)
}

@(test)
test_frame_sizes_and_cbr :: proc(t: ^testing.T) {
	Case :: struct {frame, bitrate: int, vbr: bool}
	for c in ([]Case{{120, 64000, true}, {480, 32000, true}, {1920, 16000, true}, {2880, 64000, true}, {5760, 24000, true}, {960, 32000, false}, {2880, 32000, false}}) {
		enc := new(Encoder)
		defer free(enc)
		dec := new(Decoder)
		defer free(dec)
		encoder_init(enc, 48000, 1, .VOIP)
		decoder_init(dec, 48000, 1)
		encoder_set_bitrate(enc, c.bitrate)
		encoder_set_vbr(enc, c.vbr)
		r := rand.create(3)
		phase: f64
		x := make([]f32, c.frame)
		y := make([]f32, 5760)
		defer delete(x)
		defer delete(y)
		pkt: [6 * 1276]u8
		for f in 0 ..< 20 {
			speechish(x, f, &phase, &r)
			n, err := encode(enc, x, pkt[:])
			testing.expect_value(t, err, Error.None)
			if !c.vbr do testing.expect_value(t, n, c.bitrate * c.frame / 48000 / 8)
			ns, _ := packet_get_nb_samples(pkt[:n], 48000)
			testing.expect_value(t, ns, c.frame)
			k, derr := decode(dec, pkt[:n], y)
			testing.expect_value(t, derr, Error.None)
			testing.expect_value(t, k, c.frame)
			testing.expect_value(t, decoder_final_range(dec), encoder_final_range(enc))
		}
	}
}
