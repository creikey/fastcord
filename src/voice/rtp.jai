// RTP / RTCP framing and Discord's transport encryption ("rtpsize" modes).
//
// rtpsize: the RTP header (12 + 4*CC bytes) plus, when X is set, the 4-byte
// extension header (0xBEDE + length) are authenticated but not encrypted;
// the extension body and payload are encrypted. A 32-bit big-endian nonce
// counter is appended after the tag; the AEAD nonce is that counter in the
// first 4 bytes followed by zeros (12 bytes for AES-GCM, 24 for XChaCha).
// For RTCP the 8-byte header (V/P/RC, PT, length, SSRC) is the AAD.

OPUS_PT :: cast(u8) 120;  // payload_type the client negotiates for opus (op 1 codecs)
RTP_HEADER :: 12;
TAG :: 16;
NONCE_LEN :: 4;
SAMPLES_PER_FRAME :: 960;  // 20 ms @ 48 kHz

// One-byte header extension (RFC 8285) on audio packets:
//   id 1: urn:ietf:params:rtp-hdrext:ssrc-audio-level (1 byte: V | level)
EXT_ID_AUDIO_LEVEL :: 1;

Mode :: enum u8 {
    None;
    Aes256_Gcm_Rtpsize;
    Xchacha20_Poly1305_Rtpsize;
}

MODE_NAMES :: string.["", "aead_aes256_gcm_rtpsize", "aead_xchacha20_poly1305_rtpsize"];

mode_name :: (m: Mode) -> string { return MODE_NAMES[m]; }

mode_from_name :: (s: string) -> Mode {
    for MODE_NAMES if it_index && it == s return cast(Mode) it_index;
    return .None;
}

// choose_mode: the official client prefers AES-256-GCM when offered.
choose_mode :: (modes: []string) -> Mode {
    best := Mode.None;
    for modes {
        m := mode_from_name(it);
        if m == .Aes256_Gcm_Rtpsize return m;
        if m != .None best = m;
    }
    return best;
}

Transport_Crypto :: struct {
    mode: Mode;
    aead: crypto.Aead;
    init: bool;
}

transport_init :: (tc: *Transport_Crypto, mode: Mode, key: []u8) {
    transport_reset(tc);
    tc.mode = mode;
    if mode == .None return;
    k: [32]u8;
    memcpy(k.data, key.data, min(key.count, 32));
    tc.init = crypto.aead_init(*tc.aead, ifx mode == .Aes256_Gcm_Rtpsize then .AES_GCM else .XCHACHA20_POLY1305, k);
    crypto.zero(*k);
}

transport_reset :: (tc: *Transport_Crypto) {
    if tc.init crypto.aead_destroy(*tc.aead);
    tc.init = false;
}

// the AEAD nonce: the 32-bit counter, then zeros
nonce_of :: (tc: *Transport_Crypto, iv: *[24]u8) -> []u8 { return array_view(iv.*, 0, ifx tc.mode == .Aes256_Gcm_Rtpsize then 12 else 24); }

// seal: out = packet[:aad_len] || enc(packet[aad_len:]) || tag || nonce. Returns length.
transport_seal :: (tc: *Transport_Crypto, packet: []u8, aad_len: int, nonce: u32, out: []u8) -> int {
    n := packet.count;
    assert(out.count >= n + TAG + NONCE_LEN && tc.init);
    memcpy(out.data, packet.data, aad_len);
    iv: [24]u8;
    put_u32(iv, nonce);
    if !crypto.seal(*tc.aead, array_view(out, aad_len, n - aad_len), array_view(out, n, TAG), nonce_of(tc, *iv),
        array_view(packet, 0, aad_len), array_view(packet, aad_len, n - aad_len)) return 0;
    memcpy(out.data + n + TAG, iv.data, NONCE_LEN);
    return n + TAG + NONCE_LEN;
}

// open: returns the decrypted packet (header || plaintext) in out.
transport_open :: (tc: *Transport_Crypto, packet: []u8, aad_len: int, out: []u8) -> n: int, ok: bool {
    if !tc.init || packet.count < aad_len + TAG + NONCE_LEN return 0, false;
    body_end := packet.count - NONCE_LEN - TAG;
    iv: [24]u8;
    memcpy(iv.data, packet.data + packet.count - NONCE_LEN, NONCE_LEN);
    memcpy(out.data, packet.data, aad_len);
    ok := crypto.open(*tc.aead, array_view(out, aad_len, body_end - aad_len), nonce_of(tc, *iv), array_view(packet, 0, aad_len),
        array_view(packet, aad_len, body_end - aad_len), array_view(packet, body_end, TAG));
    return body_end, ok;
}

// ---------------------------------------------------------------------------
// RTP

Rtp_Header :: struct {
    marker: bool;
    pt: u8;
    seq: u16;
    ts: u32;
    ssrc: u32;
    csrc_count: int;
    has_ext: bool;
    ext_words: int;
    aad_len: int;      // rtpsize unencrypted prefix
    payload_off: int;  // after decrypt: start of payload (after ext body)
}

// Big-endian fields at b[i].
put_u16 :: (b: []u8, v: u16, i := 0) { b[i] = cast(u8) (v >> 8); b[i + 1] = cast,no_check(u8) v; }
put_u32 :: (b: []u8, v: u32, i := 0) { for k: 0..3 b[i + k] = cast,no_check(u8) (v >> (24 - 8 * k)); }
get_u16 :: (b: []u8, i := 0) -> u16 { return ((cast(u16) b[i]) << 8) | b[i + 1]; }
get_u32 :: (b: []u8, i := 0) -> u32 { return ((cast(u32) b[i]) << 24) | ((cast(u32) b[i + 1]) << 16) | ((cast(u32) b[i + 2]) << 8) | b[i + 3]; }

// build_audio_rtp writes the RTP header + one-byte extension block + payload.
// Returns (length, aad_len). Verified live against Discord's SFU: the
// ssrc-audio-level element alone (id 1, one 32-bit word) is accepted; adding
// a transport-wide-cc element made the SFU drop every packet.
build_audio_rtp :: (out: []u8, seq: u16, ts: u32, ssrc: u32, audio_level: u8, voice: bool, payload: []u8) -> int, int {
    out[0] = 0x90;  // V=2, X=1
    out[1] = OPUS_PT;
    put_u16(out, seq, 2);
    put_u32(out, ts, 4);
    put_u32(out, ssrc, 8);
    out[12] = 0xBE;
    out[13] = 0xDE;
    put_u16(out, 1, 14);
    out[16] = EXT_ID_AUDIO_LEVEL << 4;  // len-1 = 0
    out[17] = (ifx voice then cast(u8) 0x80 else 0) | (audio_level & 0x7f);
    out[18] = 0;
    out[19] = 0;
    memcpy(out.data + 20, payload.data, payload.count);
    return 20 + payload.count, 16;
}

is_rtcp :: (b: []u8) -> bool { return b.count >= 8 && b[1] >= 192 && b[1] <= 223; }

// parse_rtp_header reads fields available before decryption.
parse_rtp_header :: (b: []u8) -> Rtp_Header, bool {
    h: Rtp_Header;
    if b.count < RTP_HEADER || (b[0] >> 6) != 2 return h, false;
    h.csrc_count = b[0] & 0x0f;
    h.has_ext = (b[0] & 0x10) != 0;
    h.marker = (b[1] & 0x80) != 0;
    h.pt = b[1] & 0x7f;
    h.seq = get_u16(b, 2);
    h.ts = get_u32(b, 4);
    h.ssrc = get_u32(b, 8);
    h.aad_len = RTP_HEADER + 4 * h.csrc_count;
    if h.has_ext {
        if b.count < h.aad_len + 4 return h, false;
        h.ext_words = get_u16(b, h.aad_len + 2);
        h.aad_len += 4;
    }
    if b.count < h.aad_len return h, false;
    h.payload_off = h.aad_len + 4 * h.ext_words;
    return h, true;
}

// ext_audio_level returns the ssrc-audio-level element from a decrypted packet.
ext_audio_level :: (pkt: []u8, h: Rtp_Header) -> level: u8, voice: bool, ok: bool {
    if !h.has_ext || h.payload_off > pkt.count return 0, false, false;
    body := array_view(pkt, h.aad_len, h.payload_off - h.aad_len);
    i := 0;
    while i < body.count {
        b := body[i];
        if b == 0 { i += 1; continue; }
        id := b >> 4;
        l := (b & 0x0f) + 1;
        if id == 15 || i + 1 + l > body.count break;
        if id == EXT_ID_AUDIO_LEVEL return body[i + 1] & 0x7f, (body[i + 1] & 0x80) != 0, true;
        i += 1 + l;
    }
    return 0, false, false;
}

// ---------------------------------------------------------------------------
// RTCP (sender / receiver reports)

RTCP_SR :: cast(u8) 200;
RTCP_RR :: cast(u8) 201;

Report_Block :: struct {
    ssrc: u32;
    fraction_lost: u8;
    cum_lost: s32;
    ext_max_seq: u32;
    jitter: u32;
    lsr: u32;
    dlsr: u32;
}

// build_report: SR with report blocks (or RR when !sender). Returns length; the
// first 8 bytes are the AAD.
build_report :: (out: []u8, ssrc: u32, sender: bool, ntp: u64, rtp_ts: u32, packets: u32, octets: u32, blocks: []Report_Block) -> int {
    nb := min(blocks.count, 31);
    length := 8 + (ifx sender then 20 else 0) + 24 * nb;
    out[0] = 0x80 | cast(u8) nb;
    out[1] = ifx sender then RTCP_SR else RTCP_RR;
    put_u16(out, cast(u16) (length / 4 - 1), 2);
    put_u32(out, ssrc, 4);
    p := 8;
    if sender {
        put_u32(out, cast(u32) (ntp >> 32), 8);
        put_u32(out, cast,no_check(u32) ntp, 12);
        put_u32(out, rtp_ts, 16);
        put_u32(out, packets, 20);
        put_u32(out, octets, 24);
        p = 28;
    }
    for b: array_view(blocks, 0, nb) {
        put_u32(out, b.ssrc, p);
        // the 24-bit cumulative loss overwrites byte 4; fraction_lost goes there after
        put_u32(out, (cast,no_check(u32) clamp(b.cum_lost, -0x800000, 0x7fffff)) & 0xffffff, p + 4);
        out[p + 4] = b.fraction_lost;
        put_u32(out, b.ext_max_seq, p + 8);
        put_u32(out, b.jitter, p + 12);
        put_u32(out, b.lsr, p + 16);
        put_u32(out, b.dlsr, p + 20);
        p += 24;
    }
    return length;
}

Parsed_Report :: struct {
    ssrc: u32;
    is_sr: bool;
    ntp: u64;
    rtp_ts: u32;
    blocks: [8]Report_Block;
    n_blocks: int;
}

parse_report :: (b: []u8) -> Parsed_Report, bool {
    r: Parsed_Report;
    if b.count < 8 || (b[0] >> 6) != 2 return r, false;
    pt := b[1];
    if pt != RTCP_SR && pt != RTCP_RR return r, false;
    length := (cast(int) get_u16(b, 2) + 1) * 4;
    if length > b.count return r, false;
    rc := b[0] & 0x1f;
    r.ssrc = get_u32(b, 4);
    p := 8;
    if pt == RTCP_SR {
        if length < 28 return r, false;
        r.is_sr = true;
        r.ntp = ((cast(u64) get_u32(b, 8)) << 32) | get_u32(b, 12);
        r.rtp_ts = get_u32(b, 16);
        p = 28;
    }
    for 1..rc {
        if p + 24 > length || r.n_blocks == r.blocks.count break;
        blk := *r.blocks[r.n_blocks];
        blk.ssrc = get_u32(b, p);
        blk.fraction_lost = b[p + 4];
        blk.ext_max_seq = get_u32(b, p + 8);
        blk.jitter = get_u32(b, p + 12);
        blk.lsr = get_u32(b, p + 16);
        blk.dlsr = get_u32(b, p + 20);
        r.n_blocks += 1;
        p += 24;
    }
    return r, true;
}

// ---------------------------------------------------------------------------
// UDP IP discovery: type 1 request / type 2 response, length 70, ssrc,
// 64-byte NUL-terminated address, big-endian port. 74 bytes total.

DISCOVERY_LEN :: 74;

build_discovery_request :: (out: []u8, ssrc: u32) {
    memset(out.data, 0, DISCOVERY_LEN);
    put_u16(out, 1);
    put_u16(out, 70, 2);
    put_u32(out, ssrc, 4);
}

build_discovery_response :: (out: []u8, ssrc: u32, address: string, port: u16) {
    memset(out.data, 0, DISCOVERY_LEN);
    put_u16(out, 2);
    put_u16(out, 70, 2);
    put_u32(out, ssrc, 4);
    memcpy(out.data + 8, address.data, min(address.count, 63));
    put_u16(out, port, 72);
}

parse_discovery :: (b: []u8, want_type: u16) -> ssrc: u32, address: string, port: u16, ok: bool {
    if b.count < DISCOVERY_LEN || get_u16(b) != want_type || get_u16(b, 2) != 70 return 0, "", 0, false;
    a := array_view(b, 8, 64);
    end := 0;
    while end < a.count && a[end] != 0 end += 1;
    return get_u32(b, 4), to_string(a.data, end), get_u16(b, 72), true;
}
