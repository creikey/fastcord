package voice

import "fc:locks"

// Opus codec interface. The default is opus_codec() (fc:opus); set_codec()
// overrides it (e.g. stub_codec(), which sends Opus silence frames
// 0xF8 0xFF 0xFE and decodes to silence, for protocol tests).
//
// Contract (all at 48 kHz, 20 ms = 960 samples per channel):
//   encode(enc, pcm_mono[960], out) -> bytes written (0 = drop frame)
//   decode(dec, packet, fec, out_stereo[1920]) -> samples per channel
//     packet == nil: packet loss concealment
//     fec == true:   decode the in-band FEC (LBRR) of `packet` for the frame BEFORE it
// The encoder should be configured like the official client: Opus
// application VOIP, in-band FEC on, DTX per op-1 fmtp ("usedtx"), 64 kbit/s
// default voice bitrate (channel bitrate may override), mono input.

MAX_OPUS_PACKET :: 1275

Codec :: struct {
	encoder_create:  proc() -> rawptr,
	encoder_destroy: proc(enc: rawptr),
	encode:          proc(enc: rawptr, pcm: []f32, out: []byte) -> int,
	set_bitrate:     proc(enc: rawptr, bits_per_second: int),
	decoder_create:  proc() -> rawptr,
	decoder_destroy: proc(dec: rawptr),
	decode:          proc(dec: rawptr, packet: []byte, fec: bool, out: []f32) -> int,
}

@(private)
g_codec: Codec
@(private)
g_codec_mu: locks.Mutex

// set_codec installs the Opus implementation for connections created afterwards.
set_codec :: proc(c: Codec) {
	locks.lock(&g_codec_mu)
	g_codec = c
	locks.unlock(&g_codec_mu)
}

get_codec :: proc() -> Codec {
	locks.lock(&g_codec_mu)
	defer locks.unlock(&g_codec_mu)
	if g_codec.encode == nil do return opus_codec()
	return g_codec
}

OPUS_SILENCE_FRAME :: [3]byte{0xF8, 0xFF, 0xFE}

stub_codec :: proc() -> Codec {
	return Codec {
		encoder_create = proc() -> rawptr {return nil},
		encoder_destroy = proc(enc: rawptr) {},
		encode = proc(enc: rawptr, pcm: []f32, out: []byte) -> int {
			s := OPUS_SILENCE_FRAME
			copy(out, s[:])
			return 3
		},
		set_bitrate = proc(enc: rawptr, bps: int) {},
		decoder_create = proc() -> rawptr {return nil},
		decoder_destroy = proc(dec: rawptr) {},
		decode = proc(dec: rawptr, packet: []byte, fec: bool, out: []f32) -> int {
			for i in 0 ..< min(len(out), SAMPLES_PER_FRAME * 2) do out[i] = 0
			return SAMPLES_PER_FRAME
		},
	}
}
