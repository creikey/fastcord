package mls

import "core:crypto"
import "core:crypto/aes"
import "core:crypto/ecdh"
import "core:crypto/ecdsa"
import "core:crypto/hkdf"
import "core:crypto/hmac"
import "core:crypto/sha2"

// Ciphersuite 2: MLS_128_DHKEMP256_AES128GCM_SHA256_P256.
CIPHER_SUITE :: u16(2)
PROTOCOL_VERSION :: u16(1) // mls10

NH :: 32 // hash / KDF output
NK :: 16 // AEAD key
NN :: 12 // AEAD nonce
NT :: 16 // AEAD tag
NPK :: 65 // uncompressed P-256 point
NSK :: 32

KEM_ID :: u16(0x0010)
KDF_ID :: u16(0x0001)
AEAD_ID :: u16(0x0001)

Secret :: [NH]byte

hash_bytes :: proc(msg: []byte) -> (out: Secret) {
	ctx: sha2.Context_256
	sha2.init_256(&ctx)
	sha2.update(&ctx, msg)
	sha2.final(&ctx, out[:])
	return
}

mac :: proc(key, msg: []byte) -> (out: Secret) {
	hmac.sum(.SHA256, out[:], msg, key)
	return
}

kdf_extract :: proc(salt, ikm: []byte) -> (out: Secret) {
	zero: Secret
	s := salt if len(salt) > 0 else zero[:]
	hkdf.extract(.SHA256, s, ikm, out[:])
	return
}

kdf_expand :: proc(prk, info, dst: []byte) {
	hkdf.expand(.SHA256, prk, info, dst)
}

// ---------------------------------------------------------------------------
// AEAD (AES-128-GCM). ct = ciphertext || tag.

aead_seal :: proc(key, nonce, aad, pt: []byte, allocator := context.allocator) -> []byte {
	ctx: aes.Context_GCM
	aes.init_gcm(&ctx, key)
	defer aes.reset_gcm(&ctx)
	out := make([]byte, len(pt) + NT, allocator)
	aes.seal_gcm(&ctx, out[:len(pt)], out[len(pt):], nonce, aad, pt)
	return out
}

aead_open :: proc(key, nonce, aad, ct: []byte, allocator := context.allocator) -> ([]byte, bool) {
	if len(ct) < NT do return nil, false
	ctx: aes.Context_GCM
	aes.init_gcm(&ctx, key)
	defer aes.reset_gcm(&ctx)
	n := len(ct) - NT
	out := make([]byte, n, allocator)
	if !aes.open_gcm(&ctx, out, nonce, aad, ct[:n], ct[n:]) {
		delete(out, allocator)
		return nil, false
	}
	return out, true
}

// ---------------------------------------------------------------------------
// HPKE (RFC 9180) base mode, DHKEM(P-256, HKDF-SHA256), HKDF-SHA256, AES-128-GCM.

@(private)
kem_suite_id :: proc() -> [5]byte {return {'K', 'E', 'M', u8(KEM_ID >> 8), u8(KEM_ID)}}
@(private)
hpke_suite_id :: proc() -> [10]byte {
	return {'H', 'P', 'K', 'E', u8(KEM_ID >> 8), u8(KEM_ID), u8(KDF_ID >> 8), u8(KDF_ID), u8(AEAD_ID >> 8), u8(AEAD_ID)}
}

@(private)
labeled_extract :: proc(suite_id, salt: []byte, label: string, ikm: []byte) -> Secret {
	w := writer_make()
	w_raw(&w, transmute([]byte)string("HPKE-v1"))
	w_raw(&w, suite_id)
	w_raw(&w, transmute([]byte)label)
	w_raw(&w, ikm)
	return kdf_extract(salt, w.buf[:])
}

@(private)
labeled_expand :: proc(suite_id, prk: []byte, label: string, info: []byte, dst: []byte) {
	w := writer_make()
	w_u16(&w, u16(len(dst)))
	w_raw(&w, transmute([]byte)string("HPKE-v1"))
	w_raw(&w, suite_id)
	w_raw(&w, transmute([]byte)label)
	w_raw(&w, info)
	kdf_expand(prk, w.buf[:], dst)
}

Key_Pair :: struct {
	priv: [NSK]byte,
	pub:  [NPK]byte,
}

// public_from_private computes the uncompressed point for a P-256 scalar.
public_from_private :: proc(priv: []byte) -> (pub: [NPK]byte, ok: bool) {
	k: ecdh.Private_Key
	if !ecdh.private_key_set_bytes(&k, .SECP256R1, priv) do return
	defer ecdh.private_key_clear(&k)
	ecdh.private_key_public_bytes(&k, pub[:])
	return pub, true
}

// derive_key_pair: RFC 9180 7.1.3 DeriveKeyPair for P-256 (rejection sampling, bitmask 0xff).
derive_key_pair :: proc(ikm: []byte) -> (kp: Key_Pair, ok: bool) {
	sid := kem_suite_id()
	prk := labeled_extract(sid[:], nil, "dkp_prk", ikm)
	for counter in 0 ..< 256 {
		c := [1]byte{u8(counter)}
		cand: [NSK]byte
		labeled_expand(sid[:], prk[:], "candidate", c[:], cand[:])
		k: ecdh.Private_Key
		if ecdh.private_key_set_bytes(&k, .SECP256R1, cand[:]) {
			kp.priv = cand
			ecdh.private_key_public_bytes(&k, kp.pub[:])
			ecdh.private_key_clear(&k)
			return kp, true
		}
	}
	return
}

generate_key_pair :: proc() -> (kp: Key_Pair) {
	seed: [32]byte
	for {
		crypto.rand_bytes(seed[:])
		ok: bool
		if kp, ok = derive_key_pair(seed[:]); ok do return
	}
}

@(private)
dh :: proc(priv, pub: []byte) -> (out: [32]byte, ok: bool) {
	sk: ecdh.Private_Key
	pk: ecdh.Public_Key
	if !ecdh.private_key_set_bytes(&sk, .SECP256R1, priv) do return
	defer ecdh.private_key_clear(&sk)
	if !ecdh.public_key_set_bytes(&pk, .SECP256R1, pub) do return
	defer ecdh.public_key_clear(&pk)
	if !ecdh.ecdh(&sk, &pk, out[:]) do return
	return out, true
}

@(private)
kem_extract_and_expand :: proc(dhv: []byte, kem_context: []byte) -> (shared: Secret) {
	sid := kem_suite_id()
	eae := labeled_extract(sid[:], nil, "eae_prk", dhv)
	labeled_expand(sid[:], eae[:], "shared_secret", kem_context, shared[:])
	return
}

kem_encap :: proc(pk_r: []byte) -> (shared: Secret, enc: [NPK]byte, ok: bool) {
	e := generate_key_pair()
	dhv := dh(e.priv[:], pk_r) or_return
	ctx := make([]byte, NPK + len(pk_r), context.temp_allocator)
	copy(ctx, e.pub[:])
	copy(ctx[NPK:], pk_r)
	return kem_extract_and_expand(dhv[:], ctx), e.pub, true
}

kem_decap :: proc(enc, sk_r: []byte) -> (shared: Secret, ok: bool) {
	pk_r := public_from_private(sk_r) or_return
	dhv := dh(sk_r, enc) or_return
	ctx := make([]byte, len(enc) + NPK, context.temp_allocator)
	copy(ctx, enc)
	copy(ctx[len(enc):], pk_r[:])
	return kem_extract_and_expand(dhv[:], ctx), true
}

@(private)
hpke_key_schedule :: proc(shared, info: []byte) -> (key: [NK]byte, nonce: [NN]byte) {
	sid := hpke_suite_id()
	psk_id_hash := labeled_extract(sid[:], nil, "psk_id_hash", nil)
	info_hash := labeled_extract(sid[:], nil, "info_hash", info)
	ksc: [1 + 2 * NH]byte
	ksc[0] = 0 // mode_base
	copy(ksc[1:], psk_id_hash[:])
	copy(ksc[1 + NH:], info_hash[:])
	secret := labeled_extract(sid[:], shared, "secret", nil)
	labeled_expand(sid[:], secret[:], "key", ksc[:], key[:])
	labeled_expand(sid[:], secret[:], "base_nonce", ksc[:], nonce[:])
	return
}

hpke_seal :: proc(pk_r, info, aad, pt: []byte, allocator := context.allocator) -> (enc: [NPK]byte, ct: []byte, ok: bool) {
	shared: Secret
	shared, enc = kem_encap(pk_r) or_return
	key, nonce := hpke_key_schedule(shared[:], info)
	return enc, aead_seal(key[:], nonce[:], aad, pt, allocator), true
}

hpke_open :: proc(enc, sk_r, info, aad, ct: []byte, allocator := context.allocator) -> ([]byte, bool) {
	shared, ok := kem_decap(enc, sk_r)
	if !ok do return nil, false
	key, nonce := hpke_key_schedule(shared[:], info)
	return aead_open(key[:], nonce[:], aad, ct, allocator)
}

// ---------------------------------------------------------------------------
// MLS labeled primitives (RFC 9420 5.1).

@(private)
w_label :: proc(w: ^Writer, label: string) {
	p := w_begin(w)
	w_raw(w, transmute([]byte)string("MLS 1.0 "))
	w_raw(w, transmute([]byte)label)
	w_end(w, p)
}

expand_with_label :: proc(secret: []byte, label: string, ctx: []byte, dst: []byte) {
	w := writer_make()
	w_u16(&w, u16(len(dst)))
	w_label(&w, label)
	w_vec(&w, ctx)
	kdf_expand(secret, w.buf[:], dst)
}

derive_secret :: proc(secret: []byte, label: string) -> (out: Secret) {
	expand_with_label(secret, label, nil, out[:])
	return
}

derive_tree_secret :: proc(secret: []byte, label: string, generation: u32, dst: []byte) {
	g := [4]byte{u8(generation >> 24), u8(generation >> 16), u8(generation >> 8), u8(generation)}
	expand_with_label(secret, label, g[:], dst)
}

@(private)
sign_content :: proc(label: string, content: []byte) -> []byte {
	w := writer_make()
	w_label(&w, label)
	w_vec(&w, content)
	return w.buf[:]
}

// sign_with_label returns a DER ECDSA-P256-SHA256 signature.
sign_with_label :: proc(priv: []byte, label: string, content: []byte, allocator := context.allocator) -> ([]byte, bool) {
	k: ecdsa.Private_Key
	if !ecdsa.private_key_set_bytes(&k, .SECP256R1, priv) do return nil, false
	defer ecdsa.private_key_clear(&k)
	return ecdsa.sign_asn1(&k, .SHA256, sign_content(label, content), allocator)
}

verify_with_label :: proc(pub: []byte, label: string, content, sig: []byte) -> bool {
	k: ecdsa.Public_Key
	if !ecdsa.public_key_set_bytes(&k, .SECP256R1, pub) do return false
	defer ecdsa.public_key_clear(&k)
	return ecdsa.verify_asn1(&k, .SHA256, sign_content(label, content), sig)
}

signature_public_from_private :: proc(priv: []byte) -> (pub: [NPK]byte, ok: bool) {
	k: ecdsa.Private_Key
	if !ecdsa.private_key_set_bytes(&k, .SECP256R1, priv) do return
	defer ecdsa.private_key_clear(&k)
	ecdsa.private_key_public_bytes(&k, pub[:])
	return pub, true
}

generate_signature_key :: proc() -> (priv: [NSK]byte, pub: [NPK]byte) {
	k: ecdsa.Private_Key
	ok := ecdsa.private_key_generate(&k, .SECP256R1)
	assert(ok)
	ecdsa.private_key_bytes(&k, priv[:])
	ecdsa.private_key_public_bytes(&k, pub[:])
	ecdsa.private_key_clear(&k)
	return
}

@(private)
encrypt_context :: proc(label: string, ctx: []byte) -> []byte {
	w := writer_make()
	w_label(&w, label)
	w_vec(&w, ctx)
	return w.buf[:]
}

Hpke_Ciphertext :: struct {
	kem_output: []byte,
	ciphertext: []byte,
}

encrypt_with_label :: proc(pub: []byte, label: string, ctx, pt: []byte, allocator := context.allocator) -> (out: Hpke_Ciphertext, ok: bool) {
	enc, ct := hpke_seal(pub, encrypt_context(label, ctx), nil, pt, allocator) or_return
	out.kem_output = clone_bytes(enc[:], allocator)
	out.ciphertext = ct
	return out, true
}

decrypt_with_label :: proc(priv: []byte, label: string, ctx: []byte, c: Hpke_Ciphertext, allocator := context.allocator) -> ([]byte, bool) {
	return hpke_open(c.kem_output, priv, encrypt_context(label, ctx), nil, c.ciphertext, allocator)
}

ref_hash :: proc(label: string, value: []byte) -> Secret {
	w := writer_make()
	p := w_begin(&w)
	w_raw(&w, transmute([]byte)label)
	w_end(&w, p)
	w_vec(&w, value)
	return hash_bytes(w.buf[:])
}

