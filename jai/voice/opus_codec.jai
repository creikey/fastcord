// opus_codec adapts fc:opus (libopus) to the Codec interface:
// mono VOIP encoder at 64 kbit/s (the client's default voice bitrate), stereo
// decoder (mono packets are upmixed). It is the default codec.
opus_codec :: () -> Codec {
	return Codec.{
		encoder_create = () -> *void {
			e, err := opus.encoder_create(48000, 1, .VOIP);
			if err != .None { return null; }
			opus.encoder_set_bitrate(e, 64000);
			opus.encoder_set_inband_fec(e, true);
			// The native client's op-1 select_protocol (msg_select_protocol /
			// CODECS_JSON) carries no SDP fmtp, so nothing negotiates "usedtx":
			// DTX stays off (libopus default). Loss starts at 0% (libopus
			// default); with 0% libopus codes no LBRR even with FEC on, so a
			// caller that measures loss should raise it via
			// opus.encoder_set_packet_loss_perc.
			opus.encoder_set_dtx(e, false);
			opus.encoder_set_packet_loss_perc(e, 0);
			return e;
		},
		encoder_destroy = (enc: *void) {if enc != null { opus.encoder_destroy(cast(*opus.Encoder)enc); }},
		encode = (enc: *void, pcm: []float32, out: []u8) -> int {
			if enc == null { return 0; }
			n, err := opus.encode(cast(*opus.Encoder)enc, pcm, out);
			return ifx err == .None then n else 0;
		},
		set_bitrate = (enc: *void, bps: int) {if enc != null { opus.encoder_set_bitrate(cast(*opus.Encoder)enc, bps); }},
		decoder_create = () -> *void {
			d, err := opus.decoder_create(48000, 2);
			return ifx err == .None then d else null;
		},
		decoder_destroy = (dec: *void) {if dec != null { opus.decoder_destroy(cast(*opus.Decoder)dec); }},
		decode = (dec: *void, packet: []u8, fec: bool, out: []float32) -> int {
			n := 0;
			if dec != null {
				nn, err := opus.decode(cast(*opus.Decoder)dec, packet, sub(out, 0, SAMPLES_PER_FRAME * 2), fec);
				if err == .None { n = nn; }
			}
			if n <= 0 {
				for i: 0..(SAMPLES_PER_FRAME * 2)-1 { at(*out, i).* = 0; }
				return SAMPLES_PER_FRAME;
			}
			return n;
		}
	};
}

