// Video frames through the voice path without a network: libdave clear ranges, DAVE frame encryption,
// RTP packetization and reassembly (a lost packet NACKed and retransmitted, one given up), for H.264 and H.265;
// and VP8 from end to end: video's encoder, DAVE, RFC 7741 packets, reassembly and libvpx's decoder.
//   jai build.jai - run src/tests/voice_video.jai && build/voice_video
#import "Basic";
voice :: #import "voice";
dave :: #import "voice_dave";
video :: #import "video";
media :: #import "media";

main :: () {
    ok := true;
    // VideoToolbox's 1280x720 Constrained Baseline SPS has no VUI; it goes out with the bitstream restriction
    // WebRTC's receiver would otherwise write in (so DAVE's authenticated bytes stay as sent)
    sps_in  :: u8.[0, 0, 0, 1, 0x27, 0x42, 0xc0, 0x1f, 0xab, 0x40, 0x28, 0x02, 0xdc, 0x80, 0, 0, 0, 1, 0x28, 0xce, 0x3c, 0x80];
    sps_out :: u8.[0, 0, 0, 1, 0x27, 0x42, 0xc0, 0x1f, 0xab, 0x40, 0x28, 0x02, 0xdd, 0x00, 0xda, 0x08, 0x84, 0x6a, 0, 0, 0, 1, 0x28, 0xce, 0x3c, 0x80];
    vui := voice.h264_add_vui(sps_in);
    ok &= check(vui.count == sps_out.count && memcmp(vui.data, sps_out.data, vui.count) == 0, "SPS gets a VUI: %", vui);
    again := voice.h264_add_vui(vui);
    ok &= check(again.count == vui.count && memcmp(again.data, vui.data, vui.count) == 0, "an SPS already in that form stays");
    // a camera's VUI (BT.709 colour, timing, an emulation prevention byte) is kept and gets the restriction;
    // one that allows reordering gets it lowered. Built bit by bit in Python, apart from this parser.
    SC :: u8.[0, 0, 0, 1];
    HEAD :: u8.[0x27, 0x42, 0xc0, 0x1f, 0xab, 0x40, 0x28, 0x02, 0xdd, 0x35, 0x01, 0x01, 0x01, 0x40, 0x00, 0x00, 0x03, 0x00, 0x40, 0x00, 0x00, 0x0f];
    cases :: [2][]u8.[
        .[u8.[0x01], u8.[0x03, 0x68, 0x22, 0x11, 0xa8]],
        .[u8.[0x03, 0x68, 0x22, 0x11, 0x64, 0x80], u8.[0x03, 0x68, 0x22, 0x11, 0xa8]],
    ];
    for cases {
        sps: [..]u8;
        array_add(*sps, ..SC); array_add(*sps, ..HEAD); array_add(*sps, ..it[0]);
        want: [..]u8;
        array_add(*want, ..SC); array_add(*want, ..HEAD); array_add(*want, ..it[1]);
        got := voice.h264_add_vui(sps);
        ok &= check(got.count == want.count && memcmp(got.data, want.data, got.count) == 0, "camera VUI case %: %", it_index, got);
    }
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

        // the next frame loses its second packet: it waits, NACKing it, and the retransmission completes it
        rx.need_key = false;
        base := cast(u16) (65530 + got.payloads.count);
        for got.payloads {
            if it_index == 1 continue;
            out, done = voice.rx_video_packet(*rx, codec, base + cast(u16) it_index, 5678, got.lasts[it_index], it);
        }
        lost: [8]u16;
        nl := voice.rx_lost(*rx, lost);
        ok &= check(!done && nl == 1 && lost[0] == base + 1, "% lossy frame waits, % lost", codec, nl);
        nack: [80]u8;
        nn := voice.build_nack(nack, 1, 77, array_view(lost, 0, nl));
        seqs := voice.nacked_seqs(array_view(nack, 0, nn), 77);
        ok &= check(seqs.count == 1 && seqs[0] == base + 1, "% NACK round trip", codec);
        out, done = voice.rx_video_packet(*rx, codec, base + 1, 5678, got.lasts[1], got.payloads[1]);
        ok &= check(done && out.count == fl && memcmp(out.data, enc.data, fl) == 0 && !rx.need_key, "% retransmission completes the frame", codec);

        // a frame whose packet never comes is given up once RX_FRAMES newer ones wait: a keyframe is wanted
        base += cast(u16) got.payloads.count;
        for f: 0..voice.RX_FRAMES {
            for got.payloads {
                if f == 0 && it_index == 1 continue;
                out, done = voice.rx_video_packet(*rx, codec, base + cast(u16) (f * got.payloads.count + it_index), cast(u32) (9000 + f * 3000), got.lasts[it_index], it);
            }
        }
        ok &= check(rx.need_key && done, "% lost frame given up, the next ones out", codec);
    }
    ok &= vp8_round_trip();
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

// VP8: moving NV12 frames through video's encoder (a keyframe asked for halfway), then each as send_video sends
// it: DAVE with libdave's VP8 clear range, RFC 7741 packets with a picture_id, reassembled and decrypted,
// and decoded by libvpx at the encoder's size.
vp8_round_trip :: () -> bool {
    W :: 320;
    H :: 240;
    ok := true;
    frames: [..][]u8;
    keys: [..]bool;
    Out :: struct { frames: *[..][]u8; keys: *[..]bool; }
    o := Out.{*frames, *keys};
    enc := video.vp8_encoder_create(W, H, 30, 600_000, false, (user: *void, f: []u8, key: bool, pts: u32) {
        o := cast(*Out) user;
        array_add(o.frames, array_copy(f));
        array_add(o.keys, key);
    }, *o);
    ok &= check(enc != null, "VP8 encoder");
    if !enc return false;
    pic := NewArray(W * H * 3 / 2, u8);
    for t: 0..9 {
        for y: 0..H - 1 for x: 0..W - 1 pic[y * W + x] = cast(u8) (16 + (x + y + t * 8) % 200);
        for i: W * H..pic.count - 1 pic[i] = cast(u8) (ifx i & 1 then 100 + t else 160);
        video.vp8_encode_nv12(enc, pic.data, pic.data + W * H, W, W, W, H, cast(u32) (t * 3000), t == 5);
    }
    video.vp8_encoder_destroy(enc);
    ok &= check(frames.count >= 8 && keys[0] && voice.is_keyframe(.VP8, frames[0]), "VP8 frames % (first a keyframe)", frames.count);
    ok &= check(keys.count > 5 && keys[5] && !keys[1], "VP8 keyframe on request");

    key: [16]u8;
    for * key it.* = xx (it_index * 5 + 1);
    dec := media.sw_decoder_create(.VP8);
    rx: voice.Video_Rx;
    seq: u16 = 65500;
    decoded := 0;
    for frame, fi: frames {
        ranges := voice.dave_clear_ranges(.VP8, frame, .[]);
        want := ifx keys[fi] then 10 else 1;
        ok &= check(ranges.count == 1 && ranges[0].offset == 0 && ranges[0].size == want, "VP8 frame % clear range %", fi, ranges);
        e := NewArray(frame.count + 256, u8,, temp);
        fl := dave.encrypt_frame(key, cast(u32) (0x01000010 + fi), frame, ranges, e);
        ok &= check(fl > frame.count && memcmp(e.data, frame.data, want) == 0, "VP8 frame % encrypts, clear bytes kept", fi);
        Got :: struct { payloads: [..][]u8; lasts: [..]bool; }
        got: Got;
        voice.packetize(.VP8, array_view(e, 0, fl), .[], (p: []u8, last: bool, data: *void) {
            g := cast(*Got) data;
            array_add(*g.payloads, array_copy(p,, temp));
            array_add(*g.lasts, last);
        }, *got, cast(u16) (0x7ffe + fi) & 0x7fff);
        pid := cast(u16) (0x7ffe + fi) & 0x7fff;
        for p: got.payloads {
            first := it_index == 0;
            ok &= check(p.count <= voice.MAX_VIDEO_PAYLOAD && p[0] == (ifx first then cast(u8) 0x90 else 0x80) && p[1] == 0x80 && p[2] == 0x80 | cast(u8) (pid >> 8) && p[3] == cast(u8) pid, "VP8 frame % packet % descriptor", fi, it_index);
        }
        out: []u8;
        done: bool;
        for got.payloads { out, done = voice.rx_video_packet(*rx, .VP8, seq, cast(u32) (fi * 3000), got.lasts[it_index], it); seq += 1; }
        ok &= check(done && out.count == fl && memcmp(out.data, e.data, fl) == 0, "VP8 frame % reassembled from % packets", fi, got.payloads.count);
        p, is_frame := dave.parse_protocol_frame(out);
        plain := NewArray(p.interleaved.count, u8,, temp);
        n, dok := dave.decrypt_frame(key, *p, plain);
        ok &= check(is_frame && dok && n == frame.count && memcmp(plain.data, frame.data, n) == 0, "VP8 frame % decrypts", fi);
        pics: [..]media.Video_Frame;
        pics.allocator = temp;
        ok &= check(media.sw_decode(dec, array_view(plain, 0, n), *pics), "VP8 frame % decodes", fi);
        for * pics {
            ok &= check(it.width == W && it.height == H, "VP8 picture %x%", it.width, it.height);
            media.video_frame_release(it);
            decoded += 1;
        }
    }
    media.sw_decoder_destroy(dec);
    ok &= check(decoded == frames.count, "VP8 pictures % of %", decoded, frames.count);
    return ok;
}
