package voice

import "fc:opus"

// opus_codec adapts fc:opus (from-scratch codec) to the Codec interface:
// mono VOIP encoder at 64 kbit/s (the client's default voice bitrate), stereo
// decoder (mono packets are upmixed). It is the default codec.
opus_codec :: proc() -> Codec {
	return Codec {
		encoder_create = proc() -> rawptr {
			e, err := opus.encoder_create(48000, 1, .VOIP)
			if err != .None do return nil
			opus.encoder_set_bitrate(e, 64000)
			opus.encoder_set_inband_fec(e, true)
			// The native client's op-1 select_protocol (msg_select_protocol /
			// CODECS_JSON) carries no SDP fmtp, so nothing negotiates "usedtx":
			// DTX stays off (libopus default). Loss starts at 0% (libopus
			// default); with 0% libopus codes no LBRR even with FEC on, so a
			// caller that measures loss should raise it via
			// opus.encoder_set_packet_loss_perc.
			opus.encoder_set_dtx(e, false)
			opus.encoder_set_packet_loss_perc(e, 0)
			return e
		},
		encoder_destroy = proc(enc: rawptr) {if enc != nil do opus.encoder_destroy(cast(^opus.Encoder)enc)},
		encode = proc(enc: rawptr, pcm: []f32, out: []byte) -> int {
			if enc == nil do return 0
			n, err := opus.encode(cast(^opus.Encoder)enc, pcm, out)
			return n if err == .None else 0
		},
		set_bitrate = proc(enc: rawptr, bps: int) {if enc != nil do opus.encoder_set_bitrate(cast(^opus.Encoder)enc, bps)},
		decoder_create = proc() -> rawptr {
			d, err := opus.decoder_create(48000, 2)
			return d if err == .None else nil
		},
		decoder_destroy = proc(dec: rawptr) {if dec != nil do opus.decoder_destroy(cast(^opus.Decoder)dec)},
		decode = proc(dec: rawptr, packet: []byte, fec: bool, out: []f32) -> int {
			n := 0
			if dec != nil {
				nn, err := opus.decode(cast(^opus.Decoder)dec, packet, out[:SAMPLES_PER_FRAME * 2], fec)
				if err == .None do n = nn
			}
			if n <= 0 {
				for i in 0 ..< SAMPLES_PER_FRAME * 2 do out[i] = 0
				return SAMPLES_PER_FRAME
			}
			return n
		},
	}
}
