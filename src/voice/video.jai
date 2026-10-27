// Video over the voice connection: H.264 / H.265 RTP packetization (RFC 6184
// mode 1, RFC 7798), the DAVE clear ranges libdave leaves in each codec's
// frames, and per-SSRC reassembly of received frames.
//
// Frames are Annex B access units with a 4-byte start code before every NAL
// unit, which is how libdave and WebRTC's depacketizer hand frames to DAVE.

Video_Codec :: enum u8 {
    None;
    H264;
    H265;
    VP8;
    AV1;
}

// payload types from CODECS_JSON (rtx_payload_type is one more)
VIDEO_PT :: u8.[0, 105, 103, 107, 101];
VIDEO_CLOCK :: 90_000;
// RTP payload budget: 1200-byte packets after the 12-byte header, extension,
// AEAD tag and nonce, like WebRTC's default.
MAX_VIDEO_PAYLOAD :: 1100;

video_codec_from_name :: (s: string) -> Video_Codec {
    if s == {
      case "H264"; return .H264;
      case "H265"; return .H265;
      case "VP8";  return .VP8;
      case "AV1";  return .AV1;
    }
    return .None;
}

video_codec_from_pt :: (pt: u8) -> Video_Codec {
    for VIDEO_PT if it_index && it == pt return cast(Video_Codec) it_index;
    return .None;
}

Nal :: struct { start, end: int; }  // NAL unit bytes (after the start code)

// annexb_nals splits an Annex B stream at 3- or 4-byte start codes (in temp).
annexb_nals :: (b: []u8) -> []Nal {
    out: [..]Nal;
    out.allocator = temp;
    i := 0;
    cur := -1;
    while i + 2 < b.count {
        if b[i] == 0 && b[i + 1] == 0 && b[i + 2] == 1 {
            if cur >= 0 {
                end := i;
                if end > cur && b[end - 1] == 0 end -= 1;  // the 4-byte form's leading zero
                array_add(*out, .{cur, end});
            }
            i += 3;
            cur = i;
            continue;
        }
        i += 1;
    }
    if cur >= 0 && cur < b.count array_add(*out, .{cur, b.count});
    return out;
}

nal_type :: (codec: Video_Codec, first: u8) -> int {
    return ifx codec == .H265 then cast(int) ((first >> 1) & 0x3f) else cast(int) (first & 0x1f);
}

// is_keyframe: an IDR / IRAP picture or parameter sets (a decoder can start here).
is_keyframe :: (codec: Video_Codec, au: []u8) -> bool {
    for annexb_nals(au) {
        if it.start >= it.end continue;
        t := nal_type(codec, au[it.start]);
        if codec == .H264 && (t == 5 || t == 7) return true;
        if codec == .H265 && ((t >= 16 && t <= 21) || t == 32 || t == 33) return true;
    }
    return false;
}

// h264_slice_header_bytes: bytes covering the slice header's first three
// exp-Golomb values (first_mb_in_slice, slice_type, pic_parameter_set_id), which
// libdave leaves clear so depacketizers can read the PPS id.
h264_slice_header_bytes :: (p: []u8) -> int {
    bit := 0;
    total := p.count * 8;
    for 1..3 {
        zeros := 0;
        while bit < total && ((p[bit / 8] >> (7 - bit % 8)) & 1) == 0 { zeros += 1; bit += 1; }
        bit += 1 + zeros;
    }
    return min(bit / 8 + 1, p.count);
}

// dave_clear_ranges: libdave's codec_utils for frames whose NAL units all
// carry 4-byte start codes. Start codes stay clear; in H.264 slices the NAL
// header and the slice header's start, in H.265 VCL units the 2-byte header;
// every other NAL unit entirely. Adjacent ranges merge. In temp.
dave_clear_ranges :: (codec: Video_Codec, au: []u8, nals: []Nal) -> []DAVE.Range {
    out: [..]DAVE.Range;
    out.allocator = temp;
    add :: (off: int, size: int) #expand {
        if size <= 0 return;
        if out.count && peek(out).offset + peek(out).size == off peek_pointer(out).size += size;
        else array_add(*out, .{off, size});
    }
    for nals {
        add(it.start - 4, 4);
        n := it.end - it.start;
        if n <= 0 continue;
        t := nal_type(codec, au[it.start]);
        clear := n;
        if codec == .H264 && (t == 1 || t == 5) clear = 1 + h264_slice_header_bytes(array_view(au, it.start + 1, n - 1));
        else if codec == .H265 && t < 32 clear = min(2, n);
        add(it.start, min(clear, n));
    }
    return out;
}

// with_long_start_codes rewrites an Annex B access unit so every NAL unit has a
// 4-byte start code (in temp); returns the NAL units of the result too.
with_long_start_codes :: (au: []u8) -> []u8, []Nal {
    nals := annexb_nals(au);
    out: [..]u8;
    out.allocator = temp;
    array_reserve(*out, au.count + 4 * nals.count);
    res := NewArray(nals.count, Nal,, temp);
    for nals {
        array_add(*out, 0, 0, 0, 1);
        s := out.count;
        array_add(*out, ..array_view(au, it.start, it.end - it.start));
        res[it_index] = .{s, out.count};
    }
    return out, res;
}

// ---------------------------------------------------------------------------
// Packetizer: one RTP payload per call to emit, in order; the last one ends the frame.
// frame is the (DAVE-encrypted) access unit; nals are the NAL units of the
// plain frame, whose positions DAVE keeps (the supplemental data rides at the
// end of the last unit).

packetize :: (codec: Video_Codec, frame: []u8, nals: []Nal, emit: (payload: []u8, last: bool, data: *void), data: *void) {
    buf: [MAX_VIDEO_PAYLOAD + 3]u8;
    for nals {
        end := ifx it_index == nals.count - 1 then frame.count else it.end;
        nal := array_view(frame, it.start, end - it.start);
        last_nal := it_index == nals.count - 1;
        if nal.count <= MAX_VIDEO_PAYLOAD {
            emit(nal, last_nal, data);
            continue;
        }
        hdr := ifx codec == .H265 then 2 else 1;
        body := array_view(nal, hdr);
        first := true;
        while body.count {
            n := min(body.count, MAX_VIDEO_PAYLOAD);
            end_bit := n == body.count;
            k: int;
            if codec == .H265 {
                t := (nal[0] >> 1) & 0x3f;
                buf[0] = (nal[0] & 0x81) | (49 << 1);
                buf[1] = nal[1];
                buf[2] = (ifx first then cast(u8) 0x80 else 0) | (ifx end_bit then cast(u8) 0x40 else 0) | t;
                k = 3;
            } else {
                buf[0] = (nal[0] & 0xe0) | 28;
                buf[1] = (ifx first then cast(u8) 0x80 else 0) | (ifx end_bit then cast(u8) 0x40 else 0) | (nal[0] & 0x1f);
                k = 2;
            }
            memcpy(buf.data + k, body.data, n);
            emit(array_view(buf, 0, k + n), last_nal && end_bit, data);
            body = array_view(body, n);
            first = false;
        }
    }
}

// ---------------------------------------------------------------------------
// Receive: reassemble one access unit per RTP timestamp. Any gap in sequence
// numbers drops the frame and waits for the next keyframe (asking for one with a PLI).

Video_Rx :: struct {
    ssrc: u32;
    user_id: u64;
    codec: Video_Codec;
    ts: u32;
    in_frame: bool;
    broken: bool;        // a packet of the current frame is missing
    next_seq: u16;
    seq_init: bool;
    need_key: bool = true;
    last_pli_ms: s64;
    au: [..]u8;          // the frame so far, Annex B
    frames: u64;
}

// rx_video_packet adds one RTP payload; returns the finished access unit (in
// rx.au, valid until the next call) when the marker packet completes a frame.
rx_video_packet :: (rx: *Video_Rx, codec: Video_Codec, seq: u16, ts: u32, marker: bool, p: []u8) -> []u8, bool {
    gap := false;
    if rx.seq_init {
        d := cast(u16) (seq - rx.next_seq);
        if d >= 0x8000 return .[], false;  // late or duplicate
        gap = d != 0;
    }
    rx.seq_init = true;
    rx.next_seq = seq + 1;
    if !rx.in_frame || ts != rx.ts {
        if rx.in_frame rx.need_key = true;  // the previous frame's marker never came
        rx.in_frame = true;
        rx.ts = ts;
        rx.codec = codec;
        rx.au.count = 0;
        rx.broken = gap;  // this frame's first packets may be the lost ones
    } else if gap {
        rx.broken = true;
    }
    if !p.count || !depacketize(rx, codec, p) rx.broken = true;
    if !marker return .[], false;
    rx.in_frame = false;
    if rx.broken {
        rx.need_key = true;
        return .[], false;
    }
    return rx.au, true;
}

depacketize :: (rx: *Video_Rx, codec: Video_Codec, p: []u8) -> bool {
    sc :: (rx: *Video_Rx) { array_add(*rx.au, 0, 0, 0, 1); }
    if codec == .H264 {
        t := p[0] & 0x1f;
        if t >= 1 && t <= 23 { sc(rx); array_add(*rx.au, ..p); return true; }
        if t == 24 {  // STAP-A
            i := 1;
            while i + 2 <= p.count {
                n := cast(int) get_u16(p, i);
                i += 2;
                if i + n > p.count return false;
                sc(rx);
                array_add(*rx.au, ..array_view(p, i, n));
                i += n;
            }
            return true;
        }
        if t == 28 && p.count >= 2 {  // FU-A
            if p[1] & 0x80 { sc(rx); array_add(*rx.au, (p[0] & 0xe0) | (p[1] & 0x1f)); }
            else if !rx.au.count return false;  // started mid-unit
            array_add(*rx.au, ..array_view(p, 2));
            return true;
        }
        return false;
    }
    if codec == .H265 {
        if p.count < 2 return false;
        t := (p[0] >> 1) & 0x3f;
        if t < 48 { sc(rx); array_add(*rx.au, ..p); return true; }
        if t == 48 {  // aggregation packet
            i := 2;
            while i + 2 <= p.count {
                n := cast(int) get_u16(p, i);
                i += 2;
                if i + n > p.count return false;
                sc(rx);
                array_add(*rx.au, ..array_view(p, i, n));
                i += n;
            }
            return true;
        }
        if t == 49 && p.count >= 3 {  // fragmentation unit
            if p[2] & 0x80 { sc(rx); array_add(*rx.au, (p[0] & 0x81) | ((p[2] & 0x3f) << 1), p[1]); }
            else if !rx.au.count return false;
            array_add(*rx.au, ..array_view(p, 3));
            return true;
        }
        return false;
    }
    return false;  // VP8 / AV1: not decoded here
}

// ---------------------------------------------------------------------------
// RTCP feedback: PLI (206/1) and FIR (206/4) ask the sender for a keyframe.

RTCP_PSFB :: cast(u8) 206;

build_pli :: (out: []u8, sender_ssrc: u32, media_ssrc: u32) -> int {
    out[0] = 0x81;  // V=2, FMT=1
    out[1] = RTCP_PSFB;
    put_u16(out, 2, 2);
    put_u32(out, sender_ssrc, 4);
    put_u32(out, media_ssrc, 8);
    return 12;
}

// keyframe_requested: whether a compound RTCP packet carries a PLI or FIR for ssrc.
keyframe_requested :: (b: []u8, ssrc: u32) -> bool {
    i := 0;
    while i + 12 <= b.count {
        n := (cast(int) get_u16(b, i + 2) + 1) * 4;
        if b[i + 1] == RTCP_PSFB {
            fmt := b[i] & 0x1f;
            if fmt == 1 && get_u32(b, i + 8) == ssrc return true;
            if fmt == 4 && i + 16 <= b.count && get_u32(b, i + 12) == ssrc return true;
        }
        i += n;
    }
    return false;
}
