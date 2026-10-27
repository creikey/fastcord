// Opus codec interface. The default is opus_codec() (the opus module); set_codec()
// overrides it (e.g. stub_codec(), which sends Opus silence frames
// 0xF8 0xFF 0xFE and decodes to silence, for protocol tests).
//
// Contract (all at 48 kHz, 20 ms = 960 samples per channel):
//   encode(enc, pcm_mono[960], out) -> bytes written (0 = drop frame)
//   decode(dec, packet, fec, out_stereo[1920]) -> samples per channel
//     packet empty:  packet loss concealment
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

#scope_file
g_codec: Codec;
g_codec_mu: locks.Mutex;
#scope_export

// set_codec installs the Opus implementation for connections created afterwards.
set_codec :: (c: Codec) {
    locks.guard(*g_codec_mu);
    g_codec = c;
}

get_codec :: () -> Codec {
    locks.guard(*g_codec_mu);
    return ifx g_codec.encode then g_codec else opus_codec();
}

OPUS_SILENCE_FRAME :: u8.[0xF8, 0xFF, 0xFE];

stub_codec :: () -> Codec {
    return .{
        encoder_create = () -> *void { return null; },
        encoder_destroy = (enc: *void) {},
        encode = (enc: *void, pcm: []float32, out: []u8) -> int {
            memcpy(out.data, OPUS_SILENCE_FRAME.data, 3);
            return 3;
        },
        set_bitrate = (enc: *void, bps: int) {},
        decoder_create = () -> *void { return null; },
        decoder_destroy = (dec: *void) {},
        decode = (dec: *void, packet: []u8, fec: bool, out: []float32) -> int {
            memset(out.data, 0, min(out.count, SAMPLES_PER_FRAME * 2) * size_of(float32));
            return SAMPLES_PER_FRAME;
        },
    };
}

// opus_codec adapts libopus to the Codec interface: mono VOIP encoder at
// 64 kbit/s (the client's default voice bitrate), stereo decoder (mono packets
// are upmixed). It is the default codec.
opus_codec :: () -> Codec {
    return .{
        encoder_create = () -> *void {
            e, err := opus.encoder_create(48000, 1, .VOIP);
            if err != .None return null;
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
        encoder_destroy = (enc: *void) { if enc opus.encoder_destroy(enc); },
        encode = (enc: *void, pcm: []float32, out: []u8) -> int {
            if !enc return 0;
            n, err := opus.encode(enc, pcm, out);
            return ifx err == .None then n else 0;
        },
        set_bitrate = (enc: *void, bps: int) { if enc opus.encoder_set_bitrate(enc, bps); },
        decoder_create = () -> *void {
            d, err := opus.decoder_create(48000, 2);
            return ifx err == .None then d else null;
        },
        decoder_destroy = (dec: *void) { if dec opus.decoder_destroy(dec); },
        decode = (dec: *void, packet: []u8, fec: bool, out: []float32) -> int {
            n := 0;
            if dec {
                nn, err := opus.decode(dec, packet, array_view(out, 0, SAMPLES_PER_FRAME * 2), fec);
                if err == .None n = nn;
            }
            if n > 0 return n;
            memset(out.data, 0, SAMPLES_PER_FRAME * 2 * size_of(float32));
            return SAMPLES_PER_FRAME;
        },
    };
}
