package opus

import "core:math"
import "core:testing"

// Discord's settings: mono VOIP encoder at 64 kbit/s with in-band FEC, stereo decoder.
@(test)
test_voice_roundtrip :: proc(t: ^testing.T) {
	enc, eerr := encoder_create(48000, 1, .VOIP)
	testing.expect_value(t, eerr, Error.None)
	defer encoder_destroy(enc)
	encoder_set_bitrate(enc, 64000)
	encoder_set_inband_fec(enc, true)
	encoder_set_packet_loss_perc(enc, 20)
	dec, derr := decoder_create(48000, 2)
	testing.expect_value(t, derr, Error.None)
	defer decoder_destroy(dec)

	// Before any packet, concealment is silence of the requested length.
	out: [960 * 2]f32
	n, err := decode(dec, nil, out[:])
	testing.expect(t, err == .None && n == 960)

	x: [960]f32
	pkt: [1500]u8
	prev: [1500]u8
	prev_n := 0
	phase: f64
	sig, noise: f64
	for f in 0 ..< 50 {
		for i in 0 ..< 960 {
			x[i] = f32(0.3 * math.sin(phase))
			phase += 2 * math.PI * 440 / 48000
		}
		pn, perr := encode(enc, x[:], pkt[:])
		testing.expect(t, perr == .None && pn > 0)
		// Every 10th packet is "lost" and rebuilt from the next packet's FEC copy.
		if f % 10 == 9 && prev_n > 0 {
			k, ferr := decode(dec, pkt[:pn], out[:], true)
			testing.expect(t, ferr == .None && k == 960)
		}
		k, kerr := decode(dec, pkt[:pn], out[:])
		testing.expect(t, kerr == .None && k == 960)
		if f > 10 {
			// A pure tone survives as a tone: energy, not phase, since the codec delays the signal.
			for i in 0 ..< 960 {
				sig += f64(out[2 * i] * out[2 * i])
				noise += f64((out[2 * i] - out[2 * i + 1]) * (out[2 * i] - out[2 * i + 1]))
			}
		}
		copy(prev[:], pkt[:pn])
		prev_n = pn
	}
	rms := math.sqrt(sig / (39 * 960))
	testing.expectf(t, rms > 0.15 && rms < 0.27, "decoded rms %.3f, want about 0.21", rms)
	testing.expectf(t, noise < sig * 1e-6, "mono packets must decode to identical channels")
}
