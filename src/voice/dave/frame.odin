// Package dave implements Discord's Audio & Video End-to-End Encryption
// (DAVE protocol v1, https://daveprotocol.com): per-sender media key
// ratchets exported from the MLS group, the protocol media frame format
// (AES-128-GCM, 8-byte tags, ULEB128 nonce / unencrypted ranges, 0xFAFA
// marker), passthrough handling, the session state machine driven by voice
// gateway opcodes 21-31, and displayable privacy / verification codes.
package dave

import "core:crypto"
import "core:crypto/aes"
import "fc:voice/mls"

MAGIC_MARKER :: u16(0xFAFA)
TAG_SIZE :: 8
MIN_SUPPLEMENTAL :: TAG_SIZE + 1 + 1 + 2 // tag, 1-byte nonce, size, marker
KEY_SIZE :: 16
RATCHET_RETENTION_MS :: 10_000 // previous keys kept for in-flight media
EXPORT_LABEL :: "Discord Secure Frames v0"

// Opus silence frame the SFU may synthesize; always allowed through.
OPUS_SILENCE :: [3]byte{0xF8, 0xFF, 0xFE}

// ---------------------------------------------------------------------------
// ULEB128

uleb_put :: proc(buf: []byte, v: u64) -> int {
	x := v
	n := 0
	for x >= 0x80 {
		buf[n] = 0x80 | u8(x & 0x7f)
		n += 1
		x >>= 7
	}
	buf[n] = u8(x)
	return n + 1
}

uleb_size :: proc(v: u64) -> int {
	x := v
	n := 1
	for x >= 0x80 {
		x >>= 7
		n += 1
	}
	return n
}

uleb_get :: proc(b: []byte) -> (v: u64, n: int, ok: bool) {
	shift: uint = 0
	for i in 0 ..< len(b) {
		if shift >= 64 do return 0, 0, false
		c := b[i]
		v |= u64(c & 0x7f) << shift
		if c & 0x80 == 0 do return v, i + 1, true
		shift += 7
	}
	return 0, 0, false
}

// ---------------------------------------------------------------------------
// Key ratchet: mlspp HashRatchet over the exported sender base secret
// (key = ExpandWithLabel(secret, "key", gen, 16), secret' = ExpandWithLabel(secret, "secret", gen, 32)).

Ratchet :: struct {
	next_gen:    u32,
	next_secret: mls.Secret,
	base_len:    int,
	keys:        [dynamic][KEY_SIZE]byte, // keys[g - first_gen]
	first_gen:   u32,
}

ratchet_init :: proc(r: ^Ratchet, base: []byte, allocator := context.allocator) {
	r^ = {}
	copy(r.next_secret[:], base)
	r.base_len = len(base)
	r.keys = make([dynamic][KEY_SIZE]byte, 0, 2, allocator)
}

ratchet_destroy :: proc(r: ^Ratchet) {
	crypto.zero_explicit(&r.next_secret, size_of(r.next_secret))
	delete(r.keys)
}

ratchet_get :: proc(r: ^Ratchet, gen: u32) -> (key: [KEY_SIZE]byte, ok: bool) {
	if gen < r.first_gen do return
	if gen - r.first_gen > 255 && gen >= r.next_gen do return // refuse absurd jumps
	for r.next_gen <= gen {
		s := r.next_secret[:r.base_len]
		k: [KEY_SIZE]byte
		mls.derive_tree_secret(s, "key", r.next_gen, k[:])
		ns: mls.Secret
		mls.derive_tree_secret(s, "secret", r.next_gen, ns[:])
		r.next_secret = ns
		r.base_len = mls.NH
		append(&r.keys, k)
		r.next_gen += 1
	}
	return r.keys[gen - r.first_gen], true
}

// ---------------------------------------------------------------------------
// AES-128-GCM with 64-bit truncated tags and the 32-bit truncated nonce
// expanded to 96 bits (zero || nonce as little-endian u32).

@(private)
full_nonce :: proc(truncated: u32) -> (n: [12]byte) {
	n[8] = u8(truncated)
	n[9] = u8(truncated >> 8)
	n[10] = u8(truncated >> 16)
	n[11] = u8(truncated >> 24)
	return
}

gcm_seal_truncated :: proc(key: []byte, nonce: u32, aad, pt, ct_out: []byte, tag_out: []byte) {
	ctx: aes.Context_GCM
	aes.init_gcm(&ctx, key)
	defer aes.reset_gcm(&ctx)
	iv := full_nonce(nonce)
	tag: [16]byte
	aes.seal_gcm(&ctx, ct_out, tag[:], iv[:], aad, pt)
	copy(tag_out, tag[:TAG_SIZE])
}

gcm_open_truncated :: proc(key: []byte, nonce: u32, aad, ct, tag: []byte, pt_out: []byte) -> bool {
	iv := full_nonce(nonce)
	// CTR starts at J0 + 1 = iv || 00000002
	ctr_iv: [16]byte
	copy(ctr_iv[:], iv[:])
	ctr_iv[15] = 2
	cctx: aes.Context_CTR
	aes.init_ctr(&cctx, key, ctr_iv[:])
	aes.xor_bytes_ctr(&cctx, pt_out, ct)
	aes.reset_ctr(&cctx)
	// recompute the tag over the ciphertext by re-sealing the plaintext
	ctx: aes.Context_GCM
	aes.init_gcm(&ctx, key)
	defer aes.reset_gcm(&ctx)
	scratch := make([]byte, len(pt_out), context.temp_allocator)
	full: [16]byte
	aes.seal_gcm(&ctx, scratch, full[:], iv[:], aad, pt_out)
	if crypto.compare_constant_time(full[:TAG_SIZE], tag) != 1 {
		crypto.zero_explicit(raw_data(pt_out), len(pt_out))
		return false
	}
	return true
}

// ---------------------------------------------------------------------------
// Protocol frames

Range :: struct {
	offset, size: int,
}

Parsed_Frame :: struct {
	interleaved: []byte, // frame bytes before the supplemental data
	tag:         []byte,
	nonce:       u32,
	ranges:      [8]Range,
	n_ranges:    int,
}

// parse_protocol_frame performs the protocol frame check.
parse_protocol_frame :: proc(frame: []byte) -> (p: Parsed_Frame, ok: bool) {
	n := len(frame)
	if n < MIN_SUPPLEMENTAL do return
	if u16(frame[n - 2]) << 8 | u16(frame[n - 1]) != MAGIC_MARKER do return
	supp := int(frame[n - 3])
	if supp < MIN_SUPPLEMENTAL || supp > n do return
	body_end := n - supp
	p.interleaved = frame[:body_end]
	p.tag = frame[body_end:body_end + TAG_SIZE]
	meta := frame[body_end + TAG_SIZE:n - 3]
	nonce, used := uleb_get(meta) or_return
	if nonce > u64(max(u32)) do return
	p.nonce = u32(nonce)
	meta = meta[used:]
	last_end := 0
	for len(meta) > 0 {
		off, a := uleb_get(meta) or_return
		meta = meta[a:]
		sz, b := uleb_get(meta) or_return
		meta = meta[b:]
		if p.n_ranges == len(p.ranges) do return
		if int(off) < last_end || off + sz > u64(len(p.interleaved)) do return
		p.ranges[p.n_ranges] = Range{int(off), int(sz)}
		p.n_ranges += 1
		last_end = int(off + sz)
	}
	return p, true
}

// encrypt_opus_frame: whole Opus frame encrypted (no unencrypted ranges).
// out must hold len(frame) + supplemental_size(nonce).
supplemental_size :: proc(nonce: u32) -> int {return TAG_SIZE + uleb_size(u64(nonce)) + 1 + 2}

encrypt_opus_frame :: proc(key: []byte, nonce: u32, frame: []byte, out: []byte) -> int {
	n := len(frame)
	ss := supplemental_size(nonce)
	assert(len(out) >= n + ss)
	gcm_seal_truncated(key, nonce, nil, frame, out[:n], out[n:n + TAG_SIZE])
	pos := n + TAG_SIZE
	pos += uleb_put(out[pos:], u64(nonce))
	out[pos] = u8(ss)
	out[pos + 1] = 0xFA
	out[pos + 2] = 0xFA
	return pos + 3
}

// decrypt_frame: codec-agnostic receive path. pt_out must be >= len(p.interleaved).
decrypt_frame :: proc(key: []byte, p: ^Parsed_Frame, pt_out: []byte) -> (n: int, ok: bool) {
	body := p.interleaved
	if p.n_ranges == 0 {
		if !gcm_open_truncated(key, p.nonce, nil, body, p.tag, pt_out[:len(body)]) do return
		return len(body), true
	}
	// split into aad (unencrypted ranges joined) and ciphertext (the rest)
	aad := make([dynamic]byte, 0, len(body), context.temp_allocator)
	ct := make([dynamic]byte, 0, len(body), context.temp_allocator)
	pos := 0
	for i in 0 ..< p.n_ranges {
		r := p.ranges[i]
		append(&ct, ..body[pos:r.offset])
		append(&aad, ..body[r.offset:r.offset + r.size])
		pos = r.offset + r.size
	}
	append(&ct, ..body[pos:])
	pt := make([]byte, len(ct), context.temp_allocator)
	if !gcm_open_truncated(key, p.nonce, aad[:], ct[:], p.tag, pt) do return
	// re-interleave
	pos = 0
	cpos := 0
	for i in 0 ..< p.n_ranges {
		r := p.ranges[i]
		k := r.offset - pos
		copy(pt_out[pos:], pt[cpos:cpos + k])
		cpos += k
		copy(pt_out[r.offset:], body[r.offset:r.offset + r.size])
		pos = r.offset + r.size
	}
	copy(pt_out[pos:], pt[cpos:])
	return len(body), true
}

// ---------------------------------------------------------------------------
// Replay window per (cryptor): accept each nonce once.

Replay_Window :: struct {
	highest: u32,
	bits:    u64, // bit i => highest - i seen
	any:     bool,
}

replay_check :: proc(w: ^Replay_Window, nonce: u32) -> bool {
	if !w.any do return true
	if nonce > w.highest do return true
	d := w.highest - nonce
	if d >= 64 do return false
	return w.bits & (u64(1) << d) == 0
}

replay_mark :: proc(w: ^Replay_Window, nonce: u32) {
	if !w.any {
		w.any = true
		w.highest = nonce
		w.bits = 1
		return
	}
	if nonce > w.highest {
		shift := nonce - w.highest
		w.bits = (w.bits << shift) if shift < 64 else 0
		w.bits |= 1
		w.highest = nonce
	} else {
		w.bits |= u64(1) << (w.highest - nonce)
	}
}
