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

MAX_OPUS_PACKET :: 1275;

Codec :: struct {
	encoder_create: () -> *void;
	encoder_destroy: (enc: *void);
	encode: (enc: *void, pcm: []float32, out: []u8) -> int;
	set_bitrate: (enc: *void, bits_per_second: int);
	decoder_create: () -> *void;
	decoder_destroy: (dec: *void);
	decode: (dec: *void, packet: []u8, fec: bool, out: []float32) -> int;
}
#scope_module

g_codec: Codec;
g_codec_mu: locks.Mutex;
#scope_export

// set_codec installs the Opus implementation for connections created afterwards.
set_codec :: (c: Codec) {
	locks.lock(*g_codec_mu);
	g_codec = c;
	locks.unlock(*g_codec_mu);
}

get_codec :: () -> Codec {
	locks.lock(*g_codec_mu);
	defer locks.unlock(*g_codec_mu);
	if g_codec.encode == null { return opus_codec(); }
	return g_codec;
}

OPUS_SILENCE_FRAME :: u8.[0xF8, 0xFF, 0xFE];

stub_codec :: () -> Codec {
	return Codec.{
		encoder_create = () -> *void {return null;},
		encoder_destroy = (enc: *void) {},
		encode = (enc: *void, pcm: []float32, out: []u8) -> int {
			s := OPUS_SILENCE_FRAME;
			copy(out, view(s));
			return 3;
		},
		set_bitrate = (enc: *void, bps: int) {},
		decoder_create = () -> *void {return null;},
		decoder_destroy = (dec: *void) {},
		decode = (dec: *void, packet: []u8, fec: bool, out: []float32) -> int {
			for i: 0..(min(len(out), SAMPLES_PER_FRAME * 2))-1 { at(*out, i).* = 0; }
			return SAMPLES_PER_FRAME;
		}
	};
}

