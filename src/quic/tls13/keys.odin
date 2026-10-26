package tls13

import "core:crypto"
import "core:crypto/hash"
import "core:crypto/hkdf"
import "core:crypto/hmac"

// expand_label is HKDF-Expand-Label from RFC 8446 section 7.1.
expand_label :: proc(suite: Suite, secret: []byte, label: string, ctx: []byte, out: []byte) {
	assert(len(label) <= 249 && len(ctx) <= 255)
	info: [2 + 1 + 255 + 1 + 255]byte
	info[0] = byte(len(out) >> 8)
	info[1] = byte(len(out))
	info[2] = byte(6 + len(label))
	n := 3
	n += copy(info[n:], "tls13 ")
	n += copy(info[n:], label)
	info[n] = byte(len(ctx))
	n += 1
	n += copy(info[n:], ctx)
	hkdf.expand(suite.hash, secret, info[:n], out)
}

// derive_secret is Derive-Secret(secret, label, transcript) given the transcript hash.
derive_secret :: proc(suite: Suite, secret: []byte, label: string, transcript_hash: []byte, out: []byte) {
	expand_label(suite, secret, label, transcript_hash, out[:suite.hash_len])
}

// next_stage computes HKDF-Extract(Derive-Secret(prev, "derived", ""), ikm).
// With prev == nil it computes the early secret HKDF-Extract(0, ikm).
// An empty ikm means hash_len zero bytes.
next_stage :: proc(suite: Suite, prev: []byte, ikm: []byte, out: []byte) {
	zeros: [MAX_HASH]byte
	key := ikm if len(ikm) > 0 else zeros[:suite.hash_len]
	if prev == nil {
		hkdf.extract(suite.hash, zeros[:suite.hash_len], key, out[:suite.hash_len])
		return
	}
	empty: [MAX_HASH]byte
	hash.hash_bytes_to_buffer(suite.hash, nil, empty[:suite.hash_len])
	derived: [MAX_HASH]byte
	defer crypto.zero_explicit(&derived, size_of(derived))
	derive_secret(suite, prev, "derived", empty[:suite.hash_len], derived[:])
	hkdf.extract(suite.hash, derived[:suite.hash_len], key, out[:suite.hash_len])
}

// finished_mac computes HMAC(finished_key(base), transcript_hash).
finished_mac :: proc(suite: Suite, base: []byte, transcript_hash: []byte, out: []byte) {
	fk: [MAX_HASH]byte
	defer crypto.zero_explicit(&fk, size_of(fk))
	expand_label(suite, base[:suite.hash_len], "finished", nil, fk[:suite.hash_len])
	hmac.sum(suite.hash, out[:suite.hash_len], transcript_hash, fk[:suite.hash_len])
}

// Transcript hashes the handshake with both candidate hashes until the
// server picks a cipher suite, then only with the chosen one.
Transcript :: struct {
	h256:   hash.Context,
	h384:   hash.Context,
	chosen: hash.Algorithm,
}

transcript_init :: proc(t: ^Transcript) {
	hash.init(&t.h256, .SHA256)
	hash.init(&t.h384, .SHA384)
	t.chosen = .Invalid
}

transcript_update :: proc(t: ^Transcript, msg: []byte) {
	if t.chosen != .SHA384 do hash.update(&t.h256, msg)
	if t.chosen != .SHA256 do hash.update(&t.h384, msg)
}

transcript_choose :: proc(t: ^Transcript, alg: hash.Algorithm) {
	t.chosen = alg
}

// transcript_sum writes the hash of everything so far without finalizing.
transcript_sum :: proc(t: ^Transcript, out: []byte) -> []byte {
	ctx := &t.h256 if t.chosen == .SHA256 else &t.h384
	n := hash.digest_size(ctx)
	hash.final(ctx, out[:n], true)
	return out[:n]
}

// transcript_hrr replaces ClientHello1 with the synthetic message_hash message (RFC 8446 4.4.1).
transcript_hrr :: proc(t: ^Transcript) {
	ch1: [MAX_HASH]byte
	h := transcript_sum(t, ch1[:])
	alg := t.chosen
	hash.reset(&t.h256)
	hash.reset(&t.h384)
	transcript_init(t)
	t.chosen = alg
	hdr := [4]byte{254, 0, 0, byte(len(h))}
	transcript_update(t, hdr[:])
	transcript_update(t, h)
}

transcript_destroy :: proc(t: ^Transcript) {
	hash.reset(&t.h256)
	hash.reset(&t.h384)
}
