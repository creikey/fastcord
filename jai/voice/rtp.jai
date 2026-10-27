// RTP / RTCP framing and Discord's transport encryption ("rtpsize" modes).
//
// rtpsize: the RTP header (12 + 4*CC bytes) plus, when X is set, the 4-byte
// extension header (0xBEDE + length) are authenticated but not encrypted;
// the extension body and payload are encrypted. A 32-bit big-endian nonce
// counter is appended after the tag; the AEAD nonce is that counter in the
// first 4 bytes followed by zeros (12 bytes for AES-GCM, 24 for XChaCha).
// For RTCP the 8-byte header (V/P/RC, PT, length, SSRC) is the AAD.

OPUS_PT :: cast(u8)(120); // payload_type the client negotiates for opus (op 1 codecs)
RTP_HEADER :: 12;
TAG :: 16;
NONCE_LEN :: 4;
SAMPLES_PER_FRAME :: 960; // 20 ms @ 48 kHz

// One-byte header extension (RFC 8285) on audio packets:
//   id 1: urn:ietf:params:rtp-hdrext:ssrc-audio-level (1 byte: V | level)
EXT_ID_AUDIO_LEVEL :: 1;

Mode :: enum u8 {
	None;
	Aes256_Gcm_Rtpsize;
	Xchacha20_Poly1305_Rtpsize;
}

mode_name :: (m: Mode) -> string {
	if m == {
	case .Aes256_Gcm_Rtpsize;
		return "aead_aes256_gcm_rtpsize";
	case .Xchacha20_Poly1305_Rtpsize;
		return "aead_xchacha20_poly1305_rtpsize";
	case .None;
	}
	return "";
}

mode_from_name :: (s: string) -> Mode {
	if s == {
	case "aead_aes256_gcm_rtpsize";
		return .Aes256_Gcm_Rtpsize;
	case "aead_xchacha20_poly1305_rtpsize";
		return .Xchacha20_Poly1305_Rtpsize;
	}
	return .None;
}

// choose_mode: the official client prefers AES-256-GCM when offered.
choose_mode :: (modes: []string) -> Mode {
	best := Mode.None;
	for m: modes {
		mm := mode_from_name(m);
		if mm == .Aes256_Gcm_Rtpsize { return mm; }
		if mm != .None { best = mm; }
	}
	return best;
}

Transport_Crypto :: struct {
	mode: Mode;
	key: [32]u8;
	gcm: aes.Context_GCM;
	cha: chacha20poly1305.Context;
	init: bool;
}

transport_init :: (tc: *Transport_Crypto, mode: Mode, key: []u8) {
	transport_reset(tc);
	tc.mode = mode;
	copy(view(tc.key), key);
	if mode == {
	case .Aes256_Gcm_Rtpsize;
		aes.init_gcm(*tc.gcm, view(tc.key));
	case .Xchacha20_Poly1305_Rtpsize;
		chacha20poly1305.init_xchacha(*tc.cha, view(tc.key), tls.CHACHA20_IMPL);
	case .None;
		return;
	}
	tc.init = true;
}

transport_reset :: (tc: *Transport_Crypto) {
	if !tc.init { return; }
	if tc.mode == {
	case .Aes256_Gcm_Rtpsize;
		aes.reset_gcm(*tc.gcm);
	case .Xchacha20_Poly1305_Rtpsize;
		chacha20poly1305.reset(*tc.cha);
	case .None;
	}
	tc.init = false;
}

// seal: out = packet[:aad_len] || enc(packet[aad_len:]) || tag || nonce. Returns length.
transport_seal :: (tc: *Transport_Crypto, packet: []u8, aad_len: int, nonce: u32, out: []u8) -> int {
	n := len(packet);
	assert(len(out) >= n + TAG + NONCE_LEN && tc.init);
	copy(out, sub(packet, 0, aad_len));
	iv: [24]u8;
	iv[0] = cast(u8)(nonce >> 24);
	iv[1] = cast(u8)(nonce >> 16);
	iv[2] = cast(u8)(nonce >> 8);
	iv[3] = cast(u8)(nonce);
	aad := sub(packet, 0, aad_len);
	pt := sub_from(packet, aad_len);
	if tc.mode == {
	case .Aes256_Gcm_Rtpsize;
		aes.seal_gcm(*tc.gcm, sub(out, aad_len, n), sub(out, n, n + TAG), sub(iv, 0, 12), aad, pt);
	case .Xchacha20_Poly1305_Rtpsize;
		chacha20poly1305.seal(*tc.cha, sub(out, aad_len, n), sub(out, n, n + TAG), view(iv), aad, pt);
	case .None;
		return 0;
	}
	at(*out, n + TAG).* = iv[0];
	at(*out, n + TAG + 1).* = iv[1];
	at(*out, n + TAG + 2).* = iv[2];
	at(*out, n + TAG + 3).* = iv[3];
	return n + TAG + NONCE_LEN;
}

// open: returns the decrypted packet (header || plaintext) in out.
transport_open :: (tc: *Transport_Crypto, packet: []u8, aad_len: int, out: []u8) -> int, bool {
	n: int;
	ok: bool;
	if !tc.init || len(packet) < aad_len + TAG + NONCE_LEN { return n, ok; }
	body_end := len(packet) - NONCE_LEN - TAG;
	iv: [24]u8;
	copy(sub(iv, 0, 4), sub_from(packet, len(packet) - NONCE_LEN));
	copy(out, sub(packet, 0, aad_len));
	aad := sub(packet, 0, aad_len);
	ct := sub(packet, aad_len, body_end);
	tag := sub(packet, body_end, body_end + TAG);
	if tc.mode == {
	case .Aes256_Gcm_Rtpsize;
		ok = aes.open_gcm(*tc.gcm, sub(out, aad_len, body_end), sub(iv, 0, 12), aad, ct, tag);
	case .Xchacha20_Poly1305_Rtpsize;
		ok = chacha20poly1305.open(*tc.cha, sub(out, aad_len, body_end), view(iv), aad, ct, tag);
	case .None;
	}
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
	aad_len: int; // rtpsize unencrypted prefix
	payload_off: int; // after decrypt: start of payload (after ext body)
}

put_u16 :: (b: []u8, v: u16) {
	b[0] = cast(u8)(v >> 8);
	b[1] = cast(u8)(v);
}
put_u32 :: (b: []u8, v: u32) {
	b[0] = cast(u8)(v >> 24);
	b[1] = cast(u8)(v >> 16);
	b[2] = cast(u8)(v >> 8);
	b[3] = cast(u8)(v);
}
get_u16 :: (b: []u8) -> u16 {return cast(u16)(b[0]) << 8 | cast(u16)(b[1]);}
get_u32 :: (b: []u8) -> u32 {return cast(u32)(b[0]) << 24 | cast(u32)(b[1]) << 16 | cast(u32)(b[2]) << 8 | cast(u32)(b[3]);}

// build_audio_rtp writes the RTP header + one-byte extension block + payload.
// Returns (length, aad_len). Verified live against Discord's SFU: the
// ssrc-audio-level element alone (id 1, one 32-bit word) is accepted; adding
// a transport-wide-cc element made the SFU drop every packet.
build_audio_rtp :: (out: []u8, seq: u16, ts: u32, ssrc: u32, audio_level: u8, voice: bool, payload: []u8) -> int, int {
	at(*out, 0).* = 0x90; // V=2, X=1
	at(*out, 1).* = OPUS_PT;
	put_u16(sub_from(out, 2), seq);
	put_u32(sub_from(out, 4), ts);
	put_u32(sub_from(out, 8), ssrc);
	at(*out, 12).* = 0xBE;
	at(*out, 13).* = 0xDE;
	put_u16(sub_from(out, 14), 1);
	at(*out, 16).* = EXT_ID_AUDIO_LEVEL << 4; // len-1 = 0
	at(*out, 17).* = (ifx voice then 0x80 else 0) | (audio_level & 0x7f);
	at(*out, 18).* = 0;
	at(*out, 19).* = 0;
	copy(sub_from(out, 20), payload);
	return 20 + len(payload), 16;
}

is_rtcp :: (b: []u8) -> bool {
	return len(b) >= 8 && b[1] >= 192 && b[1] <= 223;
}

// parse_rtp_header reads fields available before decryption.
parse_rtp_header :: (b: []u8) -> Rtp_Header, bool {
	h: Rtp_Header;
	ok: bool;
	if len(b) < RTP_HEADER || b[0] >> 6 != 2 { return h, ok; }
	h.csrc_count = cast(int)(b[0] & 0x0f);
	h.has_ext = b[0] & 0x10 != 0;
	h.marker = b[1] & 0x80 != 0;
	h.pt = b[1] & 0x7f;
	h.seq = get_u16(sub_from(b, 2));
	h.ts = get_u32(sub_from(b, 4));
	h.ssrc = get_u32(sub_from(b, 8));
	h.aad_len = RTP_HEADER + 4 * h.csrc_count;
	if h.has_ext {
		if len(b) < h.aad_len + 4 { return h, ok; }
		h.ext_words = cast(int)(get_u16(sub_from(b, h.aad_len + 2)));
		h.aad_len += 4;
	}
	if len(b) < h.aad_len { return h, ok; }
	h.payload_off = h.aad_len + 4 * h.ext_words;
	return h, true;
}

// ext_audio_level returns the ssrc-audio-level element from a decrypted packet.
ext_audio_level :: (pkt: []u8, h: Rtp_Header) -> u8, bool, bool {
	level: u8;
	voice: bool;
	ok: bool;
	if !h.has_ext || h.payload_off > len(pkt) { return level, voice, ok; }
	body := sub(pkt, h.aad_len, h.payload_off);
	i := 0;
	while i < len(body) {
		b := body[i];
		if b == 0 {
			i += 1;
			continue;
		}
		id := b >> 4;
		l := cast(int)(b & 0x0f) + 1;
		if id == 15 || i + 1 + l > len(body) { break; }
		if id == EXT_ID_AUDIO_LEVEL { return body[i + 1] & 0x7f, body[i + 1] & 0x80 != 0, true; }
		i += 1 + l;
	}
	return level, voice, ok;
}

// ---------------------------------------------------------------------------
// RTCP (sender / receiver reports)

RTCP_SR :: cast(u8)(200);
RTCP_RR :: cast(u8)(201);

Report_Block :: struct {
	ssrc: u32;
	fraction_lost: u8;
	cum_lost: s32;
	ext_max_seq: u32;
	jitter: u32;
	lsr: u32;
	dlsr: u32;
}

// build_sr: SR with report blocks (or RR when !sender). Returns length; the
// first 8 bytes are the AAD.
build_report :: (out: []u8, ssrc: u32, sender: bool, ntp: u64, rtp_ts: u32, packets: u32, octets: u32, blocks: []Report_Block) -> int {
	nb := min(len(blocks), 31);
	length := 8 + (ifx sender then 20 else 0) + 24 * nb;
	at(*out, 0).* = 0x80 | cast(u8)(nb);
	at(*out, 1).* = ifx sender then RTCP_SR else RTCP_RR;
	put_u16(sub_from(out, 2), cast(u16)(length / 4 - 1));
	put_u32(sub_from(out, 4), ssrc);
	p := 8;
	if sender {
		put_u32(sub_from(out, 8), cast(u32)(ntp >> 32));
		put_u32(sub_from(out, 12), cast(u32)(ntp));
		put_u32(sub_from(out, 16), rtp_ts);
		put_u32(sub_from(out, 20), packets);
		put_u32(sub_from(out, 24), octets);
		p = 28;
	}
	for i: 0..nb-1 {
		b := blocks[i];
		put_u32(sub_from(out, p), b.ssrc);
		at(*out, p + 4).* = b.fraction_lost;
		cl := cast(u32)(clamp(b.cum_lost, -0x800000, 0x7fffff)) & 0xffffff;
		at(*out, p + 5).* = cast(u8)(cl >> 16);
		at(*out, p + 6).* = cast(u8)(cl >> 8);
		at(*out, p + 7).* = cast(u8)(cl);
		put_u32(sub_from(out, p + 8), b.ext_max_seq);
		put_u32(sub_from(out, p + 12), b.jitter);
		put_u32(sub_from(out, p + 16), b.lsr);
		put_u32(sub_from(out, p + 20), b.dlsr);
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
	ok: bool;
	if len(b) < 8 || b[0] >> 6 != 2 { return r, ok; }
	pt := b[1];
	if pt != RTCP_SR && pt != RTCP_RR { return r, ok; }
	length := (cast(int)(get_u16(sub_from(b, 2))) + 1) * 4;
	if length > len(b) { return r, ok; }
	rc := cast(int)(b[0] & 0x1f);
	r.ssrc = get_u32(sub_from(b, 4));
	p := 8;
	if pt == RTCP_SR {
		if length < 28 { return r, ok; }
		r.is_sr = true;
		r.ntp = cast(u64)(get_u32(sub_from(b, 8))) << 32 | cast(u64)(get_u32(sub_from(b, 12)));
		r.rtp_ts = get_u32(sub_from(b, 16));
		p = 28;
	}
	for i: 0..rc-1 {
		if p + 24 > length || r.n_blocks == len(r.blocks) { break; }
		blk := *r.blocks[r.n_blocks];
		blk.ssrc = get_u32(sub_from(b, p));
		blk.fraction_lost = b[p + 4];
		blk.ext_max_seq = get_u32(sub_from(b, p + 8));
		blk.jitter = get_u32(sub_from(b, p + 12));
		blk.lsr = get_u32(sub_from(b, p + 16));
		blk.dlsr = get_u32(sub_from(b, p + 20));
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
	for i: 0..DISCOVERY_LEN-1 { at(*out, i).* = 0; }
	put_u16(sub_from(out, 0), 1);
	put_u16(sub_from(out, 2), 70);
	put_u32(sub_from(out, 4), ssrc);
}

build_discovery_response :: (out: []u8, ssrc: u32, address: string, port: u16) {
	for i: 0..DISCOVERY_LEN-1 { at(*out, i).* = 0; }
	put_u16(sub_from(out, 0), 2);
	put_u16(sub_from(out, 2), 70);
	put_u32(sub_from(out, 4), ssrc);
	copy(sub(out, 8, 71), address);
	put_u16(sub_from(out, 72), port);
}

parse_discovery :: (b: []u8, want_type: u16) -> u32, string, u16, bool {
	ssrc: u32;
	address: string;
	port: u16;
	ok: bool;
	if len(b) < DISCOVERY_LEN || get_u16(b) != want_type || get_u16(sub_from(b, 2)) != 70 { return ssrc, address, port, ok; }
	ssrc = get_u32(sub_from(b, 4));
	a := sub(b, 8, 72);
	end := 0;
	while end < len(a) && a[end] != 0 { end += 1; }
	return ssrc, as_string(sub(a, 0, end)), get_u16(sub_from(b, 72)), true;
}

