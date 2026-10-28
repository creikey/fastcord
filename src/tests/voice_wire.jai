// Prints voice gateway messages, RTP/RTCP packets and sealed packets for fixed inputs, to compare
// byte for byte with known-good frames: jai build.jai - run jai/tests/voice_wire.jai && build/voice_wire
#import "Basic";
voice :: #import "voice";

main :: () {
    print("%\n", voice.msg_identify(1564227669971832975, 1564227670806364343, 1546819257420087346, "sess\"ion\x01id", "tok\\en", true));
    print("%\n", voice.msg_resume("tok", "sid", 18446744073709551615, 1, -1));
    print("%\n", voice.msg_select_protocol("1.2.3.4", 50000, .Aes256_Gcm_Rtpsize, "abc-def", .["fixed_keyframe_interval", "x"]));
    print("%\n", voice.msg_codecs((1 << cast(int) voice.Video_Codec.H265) | (1 << cast(int) voice.Video_Codec.VP8)));
    print("%\n", voice.msg_heartbeat(1793010000123, 42));
    print("%\n", voice.msg_speaking(1, 4294967295));
    print("%\n", voice.msg_transition(23, 7));
    buf: [64]u8;
    n, aad := voice.build_audio_rtp(buf, 65535, 4294967295, 123456, 40, true, u8.[1, 2, 3]);
    print("% % %\n", n, aad, array_view(buf, 0, n));
    blocks := voice.Report_Block.[.{ssrc = 9, fraction_lost = 3, cum_lost = -5, ext_max_seq = 70000, jitter = 12, lsr = 77, dlsr = 88}];
    rn := voice.build_report(buf, 5, true, 0x0102030405060708, 99, 10, 2000, blocks);
    print("% %\n", rn, array_view(buf, 0, rn));
    r, ok := voice.parse_report(array_view(buf, 0, rn));
    print("% % % % % % % % %\n", ok, r.ssrc, r.is_sr, r.ntp, r.rtp_ts, r.n_blocks, r.blocks[0].ssrc, r.blocks[0].fraction_lost, r.blocks[0].ext_max_seq);
    key: [32]u8;
    for * key it.* = xx it_index;
    for m: voice.Mode.[.Aes256_Gcm_Rtpsize, .Xchacha20_Poly1305_Rtpsize] {
        tc: voice.Transport_Crypto;
        voice.transport_init(*tc, m, key);
        sealed: [128]u8;
        sl := voice.transport_seal(*tc, array_view(buf, 0, n), aad, 0x01020304, sealed);
        print("% % %\n", voice.mode_name(m), sl, array_view(sealed, 0, sl));
        plain: [128]u8;
        pn, pok := voice.transport_open(*tc, array_view(sealed, 0, sl), aad, plain);
        assert(pok && pn == n && memcmp(plain.data, buf.data, n) == 0, "open(seal(x)) != x");
    }
    print("% %\n", formatFloat(voice.frame_level_db(.[0.5, -0.25, 0.1]), trailing_width = 4, zero_removal = .NO), voice.audio_level_byte(-33.7));
}
