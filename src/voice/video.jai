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

// is_keyframe: an IDR / IRAP picture or parameter sets (a decoder can start here); VP8's key frame bit
// (clear in the frame's first byte), AV1's sequence header.
is_keyframe :: (codec: Video_Codec, au: []u8) -> bool {
    if codec == .VP8 return au.count > 0 && (au[0] & 1) == 0;
    if codec == .AV1 {
        i := 0;
        while i < au.count {
            h := au[i];
            if ((h >> 3) & 0xf) == 1 return true;  // OBU_SEQUENCE_HEADER
            i += 1 + cast(int) ((h >> 2) & 1);
            if !(h & 2) return false;  // no size field: the rest is this OBU
            n, j, ok := leb128(au, i);
            if !ok return false;
            i = j + n;
        }
        return false;
    }
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

// h264_add_vui: the access unit with each SPS given the VUI bitstream restriction WebRTC's receiver
// would otherwise write in (SpsVuiRewriter): max_num_reorder_frames 0, max_dec_frame_buffering =
// max_num_ref_frames, the rest of an existing VUI kept bit for bit (cameras' carries colour info).
// Sent as is, the receiver rewrites it, and under DAVE the changed bytes fail the frame's authentication:
// every keyframe is lost and the tile shows "Failed to start camera" (Error 2012). An SPS it can't read,
// or already in that form, stays as it is. In temp.
h264_add_vui :: (au: []u8) -> []u8 {
    nals := annexb_nals(au);
    out: [..]u8;
    out.allocator = temp;
    array_reserve(*out, au.count + 16 * nals.count);
    for nals {
        nal := array_view(au, it.start, it.end - it.start);
        array_add(*out, 0, 0, 0, 1);
        sps, ok := ifx nal.count && (nal[0] & 0x1f) == 7 then sps_with_vui(nal);
        array_add(*out, ..ifx ok then sps else nal);
    }
    return out;
}

#scope_file

Bits :: struct { b: []u8; pos: int; bad: bool; }

bit :: (r: *Bits) -> int {
    if r.pos >= r.b.count * 8 { r.bad = true; return 0; }
    v := (r.b[r.pos / 8] >> (7 - r.pos % 8)) & 1;
    r.pos += 1;
    return v;
}

bits :: (r: *Bits, n: int) -> int { v := 0; for 1..n v = (v << 1) | bit(r); return v; }

ue :: (r: *Bits) -> int {
    zeros := 0;
    while !bit(r) && !r.bad { zeros += 1; if zeros > 31 { r.bad = true; return 0; } }
    return (1 << zeros) - 1 + bits(r, zeros);
}

put_bit :: (w: *[..]u8, pos: *int, v: int) {
    if pos.* % 8 == 0 array_add(w, 0);
    if v w.*[pos.* / 8] |= cast(u8) (0x80 >> (pos.* % 8));
    pos.* += 1;
}

put_ue :: (w: *[..]u8, pos: *int, v: int) {
    n := 0;
    while (v + 1) >> (n + 1) n += 1;
    for 1..n put_bit(w, pos, 0);
    for < 0..n put_bit(w, pos, ((v + 1) >> it) & 1);
}

sps_with_vui :: (nal: []u8) -> []u8, bool {
    // the RBSP: emulation prevention bytes out
    rbsp: [..]u8;
    rbsp.allocator = temp;
    zeros := 0;
    for nal {
        if it_index == 0 continue;
        if zeros >= 2 && it == 3 { zeros = 0; continue; }
        array_add(*rbsp, it);
        zeros = ifx it == 0 then zeros + 1 else 0;
    }
    r := Bits.{b = rbsp};
    profile := bits(*r, 8);
    bits(*r, 16); // constraint flags, level
    ue(*r);       // seq_parameter_set_id
    if array_find(int.[100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135], profile) {
        if ue(*r) == 3 bit(*r); // chroma_format_idc, separate_colour_plane_flag
        ue(*r); ue(*r); bit(*r);
        if bit(*r) return .[], false; // scaling matrices: not worth parsing for a VUI
    }
    ue(*r); // log2_max_frame_num_minus4
    poc := ue(*r);
    if poc == 0 ue(*r);
    else if poc == 1 {
        bit(*r); ue(*r); ue(*r); // se() reads as ue() bit for bit
        n := ue(*r);
        if n > 255 return .[], false;
        for 1..n ue(*r);
    }
    refs := ue(*r);
    bit(*r); ue(*r); ue(*r); // gaps, width, height
    if !bit(*r) bit(*r);     // frame_mbs_only_flag, mb_adaptive_frame_field_flag
    bit(*r);                 // direct_8x8_inference_flag
    if bit(*r) for 1..4 ue(*r);
    if r.bad || refs > 16 return .[], false;
    // keep: the bits copied as they are; then what WebRTC's SpsVuiRewriter would write from there
    keep: int;
    no_vui, no_restriction: bool;
    if !bit(*r) {
        keep, no_vui, no_restriction = r.pos - 1, true, true;
    } else {
        if bit(*r) && bits(*r, 8) == 255 bits(*r, 32);  // aspect_ratio_idc, Extended_SAR
        if bit(*r) bit(*r);                             // overscan
        if bit(*r) { bits(*r, 4); if bit(*r) bits(*r, 24); } // video signal type, colour description
        if bit(*r) { ue(*r); ue(*r); }                  // chroma sample locations
        if bit(*r) { bits(*r, 32); bits(*r, 32); bit(*r); } // timing
        hrd :: (r: *Bits) {
            n := ue(r) + 1;
            if n > 32 { r.bad = true; return; }
            bits(r, 8);
            for 1..n { ue(r); ue(r); bit(r); }
            bits(r, 20);
        }
        nal_hrd := bit(*r);
        if nal_hrd hrd(*r);
        vcl_hrd := bit(*r);
        if vcl_hrd hrd(*r);
        if nal_hrd || vcl_hrd bit(*r); // low_delay_hrd_flag
        bit(*r);                       // pic_struct_present_flag
        if !bit(*r) {
            keep, no_restriction = r.pos - 1, true;
        } else {
            bit(*r); for 1..4 ue(*r);
            keep = r.pos;
            reorder, dec := ue(*r), ue(*r);
            if reorder == 0 && dec <= refs return .[], false; // nothing WebRTC would change
        }
    }
    if r.bad return .[], false;

    w: [..]u8;
    w.allocator = temp;
    pos := 0;
    rd := Bits.{b = rbsp};
    while rd.pos < keep put_bit(*w, *pos, bit(*rd));
    if no_vui {
        put_bit(*w, *pos, 1); // vui_parameters_present_flag
        for 1..8 put_bit(*w, *pos, 0); // aspect, overscan, signal, chroma loc, timing, nal hrd, vcl hrd, pic_struct
    }
    if no_restriction {
        put_bit(*w, *pos, 1); // bitstream_restriction_flag
        put_bit(*w, *pos, 1); // motion_vectors_over_pic_boundaries_flag
        for v: int.[2, 1, 16, 16] put_ue(*w, *pos, v); // as WebRTC writes them
    }
    put_ue(*w, *pos, 0);    // max_num_reorder_frames
    put_ue(*w, *pos, refs); // max_dec_frame_buffering
    put_bit(*w, *pos, 1); // rbsp_stop_one_bit, then zeros to the byte

    // back to a NAL unit: the header, and emulation prevention bytes in
    out: [..]u8;
    out.allocator = temp;
    array_add(*out, nal[0]);
    zeros = 0;
    for w {
        if zeros >= 2 && it <= 3 { array_add(*out, 3); zeros = 0; }
        array_add(*out, it);
        zeros = ifx it == 0 then zeros + 1 else 0;
    }
    return out, true;
}

#scope_export

// dave_clear_ranges: libdave's codec_utils for frames whose NAL units all
// carry 4-byte start codes. Start codes stay clear; in H.264 slices the NAL
// header and the slice header's start, in H.265 VCL units the 2-byte header;
// every other NAL unit entirely. Adjacent ranges merge. VP8 (no NAL units):
// the first 10 bytes of a keyframe, 1 of any other frame. In temp.
dave_clear_ranges :: (codec: Video_Codec, au: []u8, nals: []Nal) -> []DAVE.Range {
    out: [..]DAVE.Range;
    out.allocator = temp;
    if codec == .VP8 {
        if au.count array_add(*out, .{0, min(au.count, ifx is_keyframe(.VP8, au) then 10 else 1)});
        return out;
    }
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
// end of the last unit). VP8 ignores nals: RFC 7741's payload descriptor as
// WebRTC writes it with one stream (X, S on the first packet, partition 0, I
// with the 15-bit picture_id), then the frame in pieces.

packetize :: (codec: Video_Codec, frame: []u8, nals: []Nal, emit: (payload: []u8, last: bool, data: *void), data: *void, picture_id: u16 = 0) {
    buf: [MAX_VIDEO_PAYLOAD + 3]u8;
    if codec == .VP8 {
        body := frame;
        first := true;
        while body.count {
            n := min(body.count, MAX_VIDEO_PAYLOAD - 4);
            buf[0] = 0x80 | (ifx first then cast(u8) 0x10 else 0);
            buf[1] = 0x80;
            buf[2] = 0x80 | cast(u8) ((picture_id >> 8) & 0x7f);
            buf[3] = cast(u8) (picture_id & 0xff);
            memcpy(buf.data + 4, body.data, n);
            body = array_view(body, n);
            emit(array_view(buf, 0, 4 + n), body.count == 0, data);
            first = false;
        }
        return;
    }
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
// Receive: packets wait per RTP timestamp until their frame is whole (the marker's packet and every
// sequence number before it since the last frame), in any order, so a retransmission (RTX) can fill a
// gap. Frames go out in order; one still missing packets when RX_FRAMES newer ones wait is given up,
// and the stream waits for a keyframe (asking for one with a PLI). rx_lost lists what to NACK.

Video_Rx :: struct {
    ssrc: u32;
    user_id: u64;
    codec: Video_Codec;
    need_key: bool = true;
    last_pli_ms: s64;
    last_nack_ms: s64;
    pending: [..]Rx_Frame;  // oldest first
    end_seq: u16;           // the last frame out (or given up)'s marker packet
    end_known: bool;
    max_seq: u16;           // the newest sequence number seen
    au: [..]u8;             // the last frame out: Annex B, VP8's frame, or AV1's OBUs with size fields
    av1_obu: [..]u8;        // AV1: an OBU element split across packets, so far
    frames: u64;
}

Rx_Frame :: struct {
    ts: u32;
    codec: Video_Codec;
    pkts: [..]Rx_Packet;
    marker_seq: u16;
    has_marker: bool;
    bytes: int;
}

Rx_Packet :: struct { seq: u16; data: []u8; } // data: heap

RX_FRAMES :: 3;
MAX_VIDEO_FRAME :: 8 << 20; // a frame past this is dropped, whatever the sender claims

// rx_video_packet adds one RTP payload and returns the next whole frame, if one is (in rx.au, valid until
// the next call); more may follow from rx_next_frame.
rx_video_packet :: (rx: *Video_Rx, codec: Video_Codec, seq: u16, ts: u32, marker: bool, p: []u8) -> []u8, bool {
    rx_insert(rx, codec, seq, ts, marker, p);
    au, ok := rx_next_frame(rx);
    return au, ok;
}

rx_insert :: (rx: *Video_Rx, codec: Video_Codec, seq: u16, ts: u32, marker: bool, p: []u8) {
    if rx.end_known && cast(u16) (seq - rx.end_seq - 1) >= 0x8000 return;  // its frame is already out
    if !rx.end_known && !rx.pending.count rx.max_seq = seq;
    if cast(u16) (seq - rx.max_seq) < 0x8000 rx.max_seq = seq;
    f: *Rx_Frame;
    for * rx.pending if it.ts == ts { f = it; break; }
    if !f {
        f = array_add(*rx.pending);
        f.* = .{ts = ts, codec = codec};
    }
    for f.pkts if it.seq == seq return;  // a duplicate
    if f.bytes + p.count > MAX_VIDEO_FRAME || f.pkts.count >= MAX_VIDEO_FRAME / 64 return;
    array_add(*f.pkts, .{seq, array_copy(p)});
    f.bytes += p.count;
    if marker { f.marker_seq, f.has_marker = seq, true; }
}

// rx_next_frame: the oldest waiting frame once it's whole, depacketized into rx.au.
rx_next_frame :: (rx: *Video_Rx) -> []u8, bool {
    while rx.pending.count {
        f := *rx.pending[0];
        start := ifx rx.end_known then rx.end_seq + 1 else rx_first_seq(f);
        if !f.has_marker || cast(int) cast(u16) (f.marker_seq - start) + 1 != f.pkts.count {
            // still missing packets: wait for them (a retransmission) while few newer frames wait
            if rx.pending.count <= RX_FRAMES return .[], false;
            rx_give_up(rx);
            continue;
        }
        quick_sort(f.pkts, (a: Rx_Packet, b: Rx_Packet) -> s64 { return cast(s64) cast(s16) (a.seq - b.seq); });
        rx.au.count = 0;
        rx.av1_obu.count = 0;
        rx.codec = f.codec;
        ok := true;
        for f.pkts if !it.data.count || !depacketize(rx, f.codec, it.data) { ok = false; break; }
        rx.end_seq, rx.end_known = f.marker_seq, true;
        rx_frame_free(rx, 0);
        if !ok { rx.need_key = true; continue; }
        return rx.au, true;
    }
    return .[], false;
}

// rx_lost: the sequence numbers missing between the last frame out and the newest seen (at most out.count).
rx_lost :: (rx: *Video_Rx, out: []u16) -> int {
    if !rx.end_known return 0;
    n := 0;
    s := rx.end_seq + 1;
    while cast(u16) (rx.max_seq - s) < 0x8000 && s != rx.max_seq && n < out.count {
        have := false;
        for f: rx.pending { for f.pkts if it.seq == s { have = true; break; } if have break; }
        if !have { out[n] = s; n += 1; }
        s += 1;
    }
    return n;
}

rx_reset :: (rx: *Video_Rx) {
    while rx.pending.count rx_frame_free(rx, 0);
    array_free(rx.pending);
    array_free(rx.au);
    array_free(rx.av1_obu);
}

#scope_file

// The first frame seen: its lowest sequence number starts it.
rx_first_seq :: (f: *Rx_Frame) -> u16 {
    first := f.marker_seq;
    for f.pkts if cast(u16) (first - it.seq) < 0x8000 first = it.seq;
    return first;
}

rx_give_up :: (rx: *Video_Rx) {
    f := *rx.pending[0];
    if f.has_marker { rx.end_seq, rx.end_known = f.marker_seq, true; }
    else rx.end_known = false;
    rx.need_key = true;
    rx_frame_free(rx, 0);
}

rx_frame_free :: (rx: *Video_Rx, i: int) {
    for rx.pending[i].pkts free(it.data.data);
    array_free(rx.pending[i].pkts);
    array_ordered_remove_by_index(*rx.pending, i);
}

#scope_export

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
    if codec == .VP8 {  // RFC 7741: the payload descriptor, then the frame's bytes
        i := 1;
        if p[0] & 0x80 {  // X: an extension byte with I, L, T, K
            if p.count < 2 return false;
            x := p[1];
            i = 2;
            if x & 0x80 { if i >= p.count return false; i += ifx p[i] & 0x80 then 2 else 1; }  // PictureID, 7 or 15 bits
            if x & 0x40 i += 1;  // TL0PICIDX
            if x & 0x30 i += 1;  // TID, Y, KEYIDX
        }
        if i > p.count || (!rx.au.count && !(p[0] & 0x10)) return false;  // a frame starts with S set
        array_add(*rx.au, ..array_view(p, i));
        return true;
    }
    if codec == .AV1 {  // AV1 RTP: an aggregation header (Z Y W N), then OBU elements
        z, y, w := (p[0] & 0x80) != 0, (p[0] & 0x40) != 0, cast(int) ((p[0] >> 4) & 3);
        if z != (rx.av1_obu.count > 0) return false;  // a continuation without its start, or a start never ended
        i, k := 1, 0;
        while i < p.count {
            k += 1;
            n := p.count - i;  // the last element when W counts them
            if w == 0 || k < w {
                m, j, ok := leb128(p, i);
                if !ok || m > p.count - j return false;
                n, i = m, j;
            }
            array_add(*rx.av1_obu, ..array_view(p, i, n));
            i += n;
            if i >= p.count && y break;  // continues in the next packet
            if !av1_obu_add(rx, rx.av1_obu) return false;
            rx.av1_obu.count = 0;
        }
        return true;
    }
    return false;
}

// av1_obu_add appends one whole OBU to the frame with its size field, as WebRTC's depacketizer does
// (RTP leaves it out). Temporal delimiters and tile lists aren't sent and are dropped if they are.
av1_obu_add :: (rx: *Video_Rx, obu: []u8) -> bool {
    if !obu.count return false;
    h := obu[0];
    hdr := 1 + cast(int) ((h >> 2) & 1);
    if obu.count < hdr return false;
    t := (h >> 3) & 0xf;
    if t == 2 || t == 8 return true;
    if h & 2 { array_add(*rx.au, ..obu); return true; }  // already sized
    array_add(*rx.au, h | 2);
    if hdr == 2 array_add(*rx.au, obu[1]);
    n := obu.count - hdr;
    while true {
        b := cast(u8) (n & 0x7f);
        n >>= 7;
        if n { array_add(*rx.au, b | 0x80); } else { array_add(*rx.au, b); break; }
    }
    array_add(*rx.au, ..array_view(obu, hdr));
    return true;
}

// leb128 reads an AV1 leb128 at b[i] (at most 8 bytes, below 2^31): the value and the index after it.
leb128 :: (b: []u8, i: int) -> value: int, next: int, ok: bool {
    v := 0;
    for 0..7 {
        if i + it >= b.count return 0, 0, false;
        c := b[i + it];
        v |= (cast(int) (c & 0x7f)) << (7 * it);
        if v >= 1 << 31 return 0, 0, false;
        if !(c & 0x80) return v, i + it + 1, true;
    }
    return 0, 0, false;
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

// nacked_seqs: the sequence numbers a compound RTCP packet's generic NACKs (205/1, RFC 4585) ask ssrc
// to send again (in temp).
nacked_seqs :: (b: []u8, ssrc: u32) -> []u16 {
    out: [..]u16;
    out.allocator = temp;
    i := 0;
    while i + 12 <= b.count {
        n := (cast(int) get_u16(b, i + 2) + 1) * 4;
        if b[i + 1] == RTCP_RTPFB && (b[i] & 0x1f) == 1 && get_u32(b, i + 8) == ssrc {
            j := i + 12;
            while j + 4 <= min(i + n, b.count) && out.count < 512 {
                pid, blp := get_u16(b, j), get_u16(b, j + 2);
                array_add(*out, pid);
                for k: 0..15 if blp & (cast(u16) 1 << k) array_add(*out, pid + cast(u16) (k + 1));
                j += 4;
            }
        }
        i += n;
    }
    return out;
}

// build_nack: one generic NACK for media_ssrc's lost sequence numbers (sorted, at most 16 FCIs).
build_nack :: (out: []u8, sender_ssrc: u32, media_ssrc: u32, lost: []u16) -> int {
    out[0] = 0x81;  // V=2, FMT=1
    out[1] = RTCP_RTPFB;
    put_u32(out, sender_ssrc, 4);
    put_u32(out, media_ssrc, 8);
    n := 12;
    i := 0;
    while i < lost.count && n + 4 <= out.count && n < 12 + 16 * 4 {
        pid := lost[i];
        blp: u16;
        i += 1;
        while i < lost.count && cast(u16) (lost[i] - pid) >= 1 && cast(u16) (lost[i] - pid) <= 16 { blp |= cast(u16) 1 << (lost[i] - pid - 1); i += 1; }
        put_u16(out, pid, n);
        put_u16(out, blp, n + 2);
        n += 4;
    }
    put_u16(out, cast(u16) (n / 4 - 1), 2);
    return n;
}

RTCP_RTPFB :: cast(u8) 205;

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

// remb_bitrate: the estimate (bits/s) in a compound RTCP packet's REMB (206/15 with "REMB", the SFU's
// receive-side estimate for everything we send it), or -1 when it has none.
remb_bitrate :: (b: []u8) -> int {
    i := 0;
    while i + 4 <= b.count {
        n := (cast(int) get_u16(b, i + 2) + 1) * 4;
        if b[i + 1] == RTCP_PSFB && (b[i] & 0x1f) == 15 && n >= 20 && i + 20 <= b.count && memcmp(b.data + i + 12, "REMB".data, 4) == 0 {
            exp := b[i + 17] >> 2;
            mantissa := ((cast(int) b[i + 17] & 3) << 16) | ((cast(int) b[i + 18]) << 8) | b[i + 19];
            return ifx exp > 32 then 1 << 40 else mantissa << exp;
        }
        i += n;
    }
    return -1;
}

// Our video's bandwidth estimate: WebRTC's loss-based controller (SendSideBandwidthEstimation) over the
// SFU's receiver reports, capped by its REMB. Up 8% a second while under 2% is lost, down by half the loss
// above 10% (at most once per 300 ms + RTT), between BWE_MIN and the stream's bitrate.
Bwe :: struct {
    target: int;  // bits/s
    max: int;     // the stream's bitrate (set_video)
    remb: int;    // 0: none yet
    last_ms, last_cut_ms: s64;
}

BWE_MIN :: 150_000;  // the client's videoBitrateFloor

bwe_reset :: (b: *Bwe, max: int) { b.* = .{target = max, max = max}; }

// bwe_on_loss: a receiver report's fraction lost (of 256) for our stream.
bwe_on_loss :: (b: *Bwe, fraction: u8, now_ms: s64, rtt_ms: int) {
    loss := fraction / 256.0;
    dt := ifx b.last_ms then clamp(now_ms - b.last_ms, 0, 2000) else 0;
    b.last_ms = now_ms;
    if loss < 0.02 {
        b.target += cast(int) (b.target * 0.08 * dt / 1000) + 1000 * dt / 1000;
    } else if loss > 0.1 && now_ms - b.last_cut_ms >= 300 + rtt_ms {
        b.target = cast(int) (b.target * (1 - loss / 2));
        b.last_cut_ms = now_ms;
    }
    bwe_clamp(b);
}

bwe_on_remb :: (b: *Bwe, bitrate: int) {
    b.remb = max(bitrate, 1);
    bwe_clamp(b);
}

bwe_clamp :: (b: *Bwe) {
    hi := ifx b.remb then min(b.max, b.remb) else b.max;
    b.target = clamp(b.target, min(BWE_MIN, hi), hi);
}
