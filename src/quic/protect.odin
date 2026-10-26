package quic

import "core:crypto"
import "core:crypto/aead"
import "core:crypto/aes"
import "core:crypto/chacha20"
import "core:crypto/hkdf"

import "fc:tls"

// Packet protection (RFC 9001 5).

QUIC_V1 :: 0x00000001
INITIAL_SALT := [20]byte {
	0x38, 0x76, 0x2c, 0xf7, 0xf5, 0x59, 0x34, 0xb3, 0x4d, 0x17,
	0x9a, 0xe6, 0xa4, 0xc8, 0x0c, 0xad, 0xcc, 0xbb, 0x7f, 0x0a,
}
AEAD_TAG :: 16

// Keys protects one direction of one encryption level.
Keys :: struct {
	valid:     bool,
	suite:     tls.Suite,
	secret:    [48]byte,
	ctx:       aead.Context,
	iv:        [12]byte,
	hp_aes:    aes.Context_ECB,
	hp_chacha: [32]byte,
}

keys_set :: proc(k: ^Keys, suite: tls.Suite, secret: []byte) {
	keys_clear(k)
	k.suite = suite
	copy(k.secret[:], secret)
	key, hp: [32]byte
	defer crypto.zero_explicit(&key, size_of(key))
	defer crypto.zero_explicit(&hp, size_of(hp))
	tls.expand_label(suite, secret, "quic key", nil, key[:suite.key_len])
	tls.expand_label(suite, secret, "quic iv", nil, k.iv[:])
	tls.expand_label(suite, secret, "quic hp", nil, hp[:suite.key_len])
	aead.init(&k.ctx, suite.aead, key[:suite.key_len])
	if suite.aead == .CHACHA20POLY1305 {
		k.hp_chacha = hp
	} else {
		aes.init_ecb(&k.hp_aes, hp[:suite.key_len])
	}
	k.valid = true
}

keys_clear :: proc(k: ^Keys) {
	if k.valid {
		aead.reset(&k.ctx)
		if k.suite.aead != .CHACHA20POLY1305 do aes.reset_ecb(&k.hp_aes)
	}
	crypto.zero_explicit(k, size_of(Keys))
}

// keys_next derives the next 1-RTT key phase (RFC 9001 6.1); hp is unchanged.
keys_next :: proc(dst, cur: ^Keys) {
	hl := cur.suite.hash_len
	next: [48]byte
	defer crypto.zero_explicit(&next, size_of(next))
	tls.expand_label(cur.suite, cur.secret[:hl], "quic ku", nil, next[:hl])
	hp_aes := cur.hp_aes
	hp_chacha := cur.hp_chacha
	keys_set(dst, cur.suite, next[:hl])
	// Keep the original header protection key.
	if cur.suite.aead == .CHACHA20POLY1305 {
		dst.hp_chacha = hp_chacha
	} else {
		dst.hp_aes = hp_aes
	}
}

// initial_keys derives the client and server Initial keys from the client's
// first Destination Connection ID.
initial_keys :: proc(client, server: ^Keys, dcid: []byte) {
	suite := tls.SUITES[0] // AES-128-GCM / SHA-256
	initial, cs, ss: [32]byte
	defer crypto.zero_explicit(&initial, size_of(initial))
	defer crypto.zero_explicit(&cs, size_of(cs))
	defer crypto.zero_explicit(&ss, size_of(ss))
	hkdf.extract(.SHA256, INITIAL_SALT[:], dcid, initial[:])
	tls.expand_label(suite, initial[:], "client in", nil, cs[:])
	tls.expand_label(suite, initial[:], "server in", nil, ss[:])
	keys_set(client, suite, cs[:])
	keys_set(server, suite, ss[:])
}

// hp_mask computes the 5-byte header protection mask from a 16-byte sample.
hp_mask :: proc(k: ^Keys, sample: []byte) -> (mask: [5]byte) {
	if k.suite.aead == .CHACHA20POLY1305 {
		ctx: chacha20.Context
		chacha20.init(&ctx, k.hp_chacha[:], sample[4:16])
		counter := u64(sample[0]) | u64(sample[1]) << 8 | u64(sample[2]) << 16 | u64(sample[3]) << 24
		chacha20.seek(&ctx, counter)
		chacha20.keystream_bytes(&ctx, mask[:])
		chacha20.reset(&ctx)
		return
	}
	block: [16]byte
	aes.encrypt_ecb(&k.hp_aes, block[:], sample[:16])
	copy(mask[:], block[:5])
	return
}

@(private)
packet_nonce :: proc(k: ^Keys, pn: u64) -> (n: [12]byte) {
	n = k.iv
	for i in 0 ..< 8 do n[11 - i] ~= byte(pn >> uint(8 * i))
	return
}

// seal encrypts pkt[hdr_len:] in place (the tag goes in the 16 bytes after the
// payload, which the caller reserved) and applies header protection.
// pn_off is the offset of the packet number, pn_len its encoded size.
seal :: proc(k: ^Keys, pkt: []byte, hdr_len, pn_off, pn_len: int, pn: u64) {
	n := packet_nonce(k, pn)
	plen := len(pkt) - hdr_len - AEAD_TAG
	pt := pkt[hdr_len:][:plen]
	aead.seal_ctx(&k.ctx, pt, pkt[hdr_len + plen:], n[:], pkt[:hdr_len], pt)
	sample := pkt[pn_off + 4:][:16]
	mask := hp_mask(k, sample)
	if pkt[0] & 0x80 != 0 {
		pkt[0] ~= mask[0] & 0x0f
	} else {
		pkt[0] ~= mask[0] & 0x1f
	}
	for i in 0 ..< pn_len do pkt[pn_off + i] ~= mask[1 + i]
}

// unprotect_header removes header protection in place and returns the
// truncated packet number and its length. pkt starts at the first byte.
unprotect_header :: proc(k: ^Keys, pkt: []byte, pn_off: int) -> (truncated: u64, pn_len: int, ok: bool) {
	if pn_off + 4 + 16 > len(pkt) do return 0, 0, false
	mask := hp_mask(k, pkt[pn_off + 4:][:16])
	if pkt[0] & 0x80 != 0 {
		pkt[0] ~= mask[0] & 0x0f
	} else {
		pkt[0] ~= mask[0] & 0x1f
	}
	pn_len = int(pkt[0] & 0x03) + 1
	for i in 0 ..< pn_len {
		pkt[pn_off + i] ~= mask[1 + i]
		truncated = truncated << 8 | u64(pkt[pn_off + i])
	}
	return truncated, pn_len, true
}

// open decrypts the payload in place; returns the plaintext view.
open :: proc(k: ^Keys, pkt: []byte, hdr_len: int, pn: u64) -> ([]byte, bool) {
	if len(pkt) < hdr_len + AEAD_TAG do return nil, false
	n := packet_nonce(k, pn)
	clen := len(pkt) - hdr_len - AEAD_TAG
	ct := pkt[hdr_len:][:clen]
	if !aead.open_ctx(&k.ctx, ct, n[:], pkt[:hdr_len], ct, pkt[hdr_len + clen:]) do return nil, false
	return ct, true
}

// decode_pn expands a truncated packet number (RFC 9000 A.3).
decode_pn :: proc(largest: i64, truncated: u64, pn_len: int) -> u64 {
	expected := u64(largest + 1)
	win := u64(1) << uint(pn_len * 8)
	hwin := win / 2
	mask := win - 1
	candidate := (expected & ~mask) | truncated
	if candidate + hwin <= expected && candidate < (u64(1) << 62) - win do return candidate + win
	if candidate > expected + hwin && candidate >= win do return candidate - win
	return candidate
}
