// VP8 and AV1 call video without a network: frames from tests/data/vp8.ivf and av1.ivf (ffmpeg's testsrc,
// 128x96) are packetized as the SFU forwards them (RFC 7741; the AV1 RTP spec, with OBUs split across
// packets), reassembled by voice.rx_video_packet and decoded by libvpx and dav1d (media.sw_decode).
//   jai build.jai - run src/tests/video_sw.jai && build/video_sw
#import "Basic";
#import "File";
voice :: #import "voice";
media :: #import "media";

main :: () {
    ok := true;
    for codec: voice.Video_Codec.[.VP8, .AV1] {
        data, rok := read_entire_file(ifx codec == .VP8 then "tests/data/vp8.ivf" else "tests/data/av1.ivf");
        ok &= check(rok && data.count > 32, "% fixture", codec);
        if !rok continue;
        dec := media.sw_decoder_create(ifx codec == .VP8 then media.Codec.VP8 else .AV1);
        ok &= check(dec != null, "% decoder", codec);
        rx: voice.Video_Rx;
        seq: u16 = 65000;
        decoded, keys := 0, 0;
        i := 32; // IVF: a 32-byte header, then frames with a 12-byte header (size, pts)
        n := 0;
        while i + 12 <= data.count {
            size := cast(int) u32_le(cast([]u8) data, i);
            i += 12;
            if size <= 0 || i + size > data.count break;
            frame := array_view(cast([]u8) data, i, size);
            i += size;
            pkts := ifx codec == .VP8 then vp8_packets(frame) else av1_packets(frame);
            out: []u8;
            done: bool;
            for pkts { out, done = voice.rx_video_packet(*rx, codec, seq, cast(u32) (n * 9000), it_index == pkts.count - 1, it); seq += 1; }
            ok &= check(done, "% frame % reassembled from % packets", codec, n, pkts.count);
            if !done continue;
            if voice.is_keyframe(codec, out) keys += 1;
            frames: [..]media.Video_Frame;
            ok &= check(media.sw_decode(dec, out, *frames), "% frame % decodes", codec, n);
            for * frames {
                ok &= check(it.width == 128 && it.height == 96, "% picture %x%", codec, it.width, it.height);
                media.video_frame_release(it);
                decoded += 1;
            }
            n += 1;
        }
        ok &= check(n == 3 && keys >= 1 && decoded >= 1, "% frames %, keyframes %, pictures %", codec, n, keys, decoded);
        media.sw_decoder_destroy(dec);
        // a lost packet: the frame is dropped, never handed on broken
        rx2: voice.Video_Rx;
        pkts := ifx codec == .VP8 then vp8_packets(array_view(cast([]u8) data, 44, u32_le(cast([]u8) data, 32))) else av1_packets(array_view(cast([]u8) data, 44, u32_le(cast([]u8) data, 32)));
        done := false;
        for pkts if it_index != 1 { _, done = voice.rx_video_packet(*rx2, codec, cast(u16) it_index, 1, it_index == pkts.count - 1, it); }
        ok &= check(pkts.count < 3 || (!done && rx2.need_key), "% lossy frame dropped", codec);
    }
    print(ifx ok then "PASS\n" else "FAIL\n");
    if !ok exit(1);
}

check :: (cond: bool, what: string, args: ..Any) -> bool {
    if !cond print("FAIL: %\n", tprint(what, ..args));
    return cond;
}

PAYLOAD :: 300; // small, so the frames need several packets

// RFC 7741: a one-byte descriptor, S set on the first packet.
vp8_packets :: (frame: []u8) -> [][]u8 {
    out: [..][]u8;
    out.allocator = temp;
    for chunk_start: 0..(frame.count - 1) / PAYLOAD {
        o := chunk_start * PAYLOAD;
        n := min(PAYLOAD, frame.count - o);
        p := NewArray(n + 1, u8,, temp);
        p[0] = ifx o == 0 then cast(u8) 0x10 else 0;
        memcpy(p.data + 1, frame.data + o, n);
        array_add(*out, p);
    }
    return out;
}

// The AV1 RTP spec: OBUs lose their size field (temporal delimiters are dropped), go as length-prefixed
// elements (W = 0), and split across packets with Z and Y.
av1_packets :: (tu: []u8) -> [][]u8 {
    elems: [..][]u8;
    elems.allocator = temp;
    i := 0;
    while i < tu.count {
        h := tu[i];
        hdr := 1 + cast(int) ((h >> 2) & 1);
        n, j, ok := voice.leb128(tu, i + hdr);
        assert(ok && (h & 2) != 0);
        e := NewArray(hdr + n, u8,, temp);
        e[0] = h & ~cast(u8) 2;
        if hdr == 2 e[1] = tu[i + 1];
        memcpy(e.data + hdr, tu.data + j, n);
        if ((h >> 3) & 0xf) != 2 array_add(*elems, e);
        i = j + n;
    }
    out: [..][]u8;
    out.allocator = temp;
    cur: [..]u8;
    cur.allocator = temp;
    z := false;
    for e: elems {
        o := 0;
        while o < e.count {
            if !cur.count array_add(*cur, ifx z then cast(u8) 0x80 else 0);
            room := PAYLOAD - cur.count - 2;
            n := min(e.count - o, room);
            array_add(*cur, cast(u8) (n & 0x7f) | 0x80, cast(u8) (n >> 7)); // a 2-byte leb128
            array_add(*cur, ..array_view(e, o, n));
            o += n;
            z = false;
            if o < e.count {
                cur[0] |= 0x40; // Y: continues
                array_add(*out, cur);
                cur = temp_buf();
                z = true;
            }
        }
        if cur.count > PAYLOAD - 40 { array_add(*out, cur); cur = temp_buf(); }
    }
    if cur.count array_add(*out, cur);
    return out;
}

u32_le :: (b: []u8, i: int) -> int { return (cast(int) b[i]) | ((cast(int) b[i + 1]) << 8) | ((cast(int) b[i + 2]) << 16) | ((cast(int) b[i + 3]) << 24); }
temp_buf :: () -> [..]u8 { b: [..]u8; b.allocator = temp; return b; }
