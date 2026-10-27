// Video frames through the voice path without a network: libdave clear ranges, DAVE frame encryption,
// RTP packetization and reassembly (with a lost packet), for H.264 and H.265.
//   jai build.jai - run src/tests/voice_video.jai && build/voice_video
#import "Basic";
voice :: #import "voice";
dave :: #import "voice_dave";

main :: () {
    ok := true;
    for codec: voice.Video_Codec.[.H264, .H265] {
        au := fake_au(codec);
        frame, nals := voice.with_long_start_codes(au);
        ranges := voice.dave_clear_ranges(codec, frame, nals);
        key: [16]u8;
        for * key it.* = xx (it_index * 7);
        enc := NewArray(frame.count + 256, u8);
        fl := dave.encrypt_frame(key, 0x01000005, frame, ranges, enc);
        ok &= check(fl > frame.count, "% encrypt", codec);
        for ranges ok &= check(memcmp(enc.data + it.offset, frame.data + it.offset, it.size) == 0, "% clear range % kept", codec, it_index);

        // packetize, drop nothing, reassemble
        Got :: struct { payloads: [..][]u8; lasts: [..]bool; }
        got: Got;
        voice.packetize(codec, array_view(enc, 0, fl), nals, (p: []u8, last: bool, data: *void) {
            g := cast(*Got) data;
            array_add(*g.payloads, array_copy(p));
            array_add(*g.lasts, last);
        }, *got);
        ok &= check(got.payloads.count > nals.count && peek(got.lasts), "% packet count %", codec, got.payloads.count);
        for got.payloads ok &= check(it.count <= voice.MAX_VIDEO_PAYLOAD + 3, "% packet size", codec);

        rx: voice.Video_Rx;
        out: []u8;
        done: bool;
        for got.payloads out, done = voice.rx_video_packet(*rx, codec, cast(u16) (65530 + it_index), 1234, got.lasts[it_index], it);
        ok &= check(done && out.count == fl && memcmp(out.data, enc.data, fl) == 0, "% reassembled frame matches (% vs %)", codec, out.count, fl);

        p, is_frame := dave.parse_protocol_frame(out);
        ok &= check(is_frame && p.n_ranges == ranges.count, "% supplemental parses (% ranges)", codec, p.n_ranges);
        plain := NewArray(p.interleaved.count, u8);
        n, dok := dave.decrypt_frame(key, *p, plain);
        ok &= check(dok && n == frame.count && memcmp(plain.data, frame.data, n) == 0, "% decrypts to the frame", codec);
        ok &= check(voice.is_keyframe(codec, plain), "% keyframe detected", codec);

        // the next frame loses its second packet: dropped, and a keyframe is wanted
        base := cast(u16) (65530 + got.payloads.count);
        for got.payloads {
            if it_index == 1 continue;
            out, done = voice.rx_video_packet(*rx, codec, base + cast(u16) it_index, 5678, got.lasts[it_index], it);
        }
        ok &= check(!done && rx.need_key, "% lossy frame dropped", codec);
    }
    // a 3-byte start code input is normalized
    au := u8.[0, 0, 1, 0x67, 1, 2, 0, 0, 0, 1, 0x68, 3, 0, 0, 1, 0x65, 9, 9, 9];
    f, nals := voice.with_long_start_codes(au);
    ok &= check(nals.count == 3 && f.count == au.count + 2 && f[0] == 0 && f[3] == 1 && f[4] == 0x67, "start codes normalized");
    print(ifx ok then "PASS\n" else "FAIL\n");
    if !ok exit(1);
}

check :: (cond: bool, what: string, args: ..Any) -> bool {
    if !cond print("FAIL: %\n", tprint(what, ..args));
    return cond;
}

// Parameter sets, then a 5000-byte IDR slice (needs fragmenting), with 4-byte start codes.
fake_au :: (codec: voice.Video_Codec) -> []u8 {
    b: [..]u8;
    nal :: (b: *[..]u8, hdr: []u8, n: int) {
        array_add(b, 0, 0, 0, 1);
        array_add(b, ..hdr);
        for 0..n-1 array_add(b, cast(u8) (it * 31 + 7));
    }
    if codec == .H264 {
        nal(*b, .[0x67, 0x42, 0xe0, 0x1f], 10);
        nal(*b, .[0x68, 0xce], 4);
        nal(*b, .[0x65, 0x88, 0x84], 5000);
    } else {
        nal(*b, .[0x40, 0x01], 20);  // VPS
        nal(*b, .[0x42, 0x01], 30);  // SPS
        nal(*b, .[0x44, 0x01], 6);   // PPS
        nal(*b, .[0x26, 0x01], 5000); // IDR_W_RADL
    }
    return b;
}
