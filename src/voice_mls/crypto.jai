// Ciphersuite 2: MLS_128_DHKEMP256_AES128GCM_SHA256_P256.
CIPHER_SUITE :: cast(u16) 2;
PROTOCOL_VERSION :: cast(u16) 1; // mls10

NH :: 32; // hash / KDF output
NK :: 16; // AEAD key
NN :: 12; // AEAD nonce
NT :: 16; // AEAD tag
NPK :: 65; // uncompressed P-256 point
NSK :: 32;

Secret :: [NH]u8;
ZERO_SECRET: Secret;  // never written: the value returned with a failure

hash_bytes :: (msg: []u8) -> Secret { return crypto.sha256(msg); }
mac :: (key: []u8, msg: []u8) -> Secret { return crypto.hmac_sha256(key, msg); }

kdf_extract :: (salt: []u8, ikm: []u8) -> Secret {
	zero: Secret;
	return crypto.hkdf_extract(ifx salt.count then salt else zero, ikm);
}

kdf_expand :: (prk: []u8, info: []u8, dst: []u8) { crypto.hkdf_expand(prk, info, dst); }

// ---------------------------------------------------------------------------
// AEAD (AES-128-GCM). ct = ciphertext || tag, in context.allocator.

aead_seal :: (key: []u8, nonce: []u8, aad: []u8, pt: []u8) -> []u8 {
	a: crypto.Aead;
	crypto.aead_init(*a, .AES_GCM, key);
	defer crypto.aead_destroy(*a);
	out := NewArray(pt.count + NT, u8);
	crypto.seal(*a, array_view(out, 0, pt.count), array_view(out, pt.count), nonce, aad, pt);
	return out;
}

aead_open :: (key: []u8, nonce: []u8, aad: []u8, ct: []u8) -> []u8, bool {
	if ct.count < NT return .[], false;
	a: crypto.Aead;
	crypto.aead_init(*a, .AES_GCM, key);
	defer crypto.aead_destroy(*a);
	n := ct.count - NT;
	out := NewArray(n, u8);
	if !crypto.open(*a, out, nonce, aad, array_view(ct, 0, n), array_view(ct, n)) {
		array_free(out);
		return .[], false;
	}
	return out, true;
}

// ---------------------------------------------------------------------------
// HPKE (RFC 9180) base mode, DHKEM(P-256, HKDF-SHA256), HKDF-SHA256, AES-128-GCM.

// "KEM" || kem_id, "HPKE" || kem_id || kdf_id || aead_id
KEM_SUITE_ID :: u8.[#char "K", #char "E", #char "M", 0x00, 0x10];
HPKE_SUITE_ID :: u8.[#char "H", #char "P", #char "K", #char "E", 0x00, 0x10, 0x00, 0x01, 0x00, 0x01];

labeled_extract :: (suite_id: []u8, salt: []u8, label: string, ikm: []u8) -> Secret {
	w := writer_make();
	w_raw(*w, "HPKE-v1");
	w_raw(*w, suite_id);
	w_raw(*w, label);
	w_raw(*w, ikm);
	return kdf_extract(salt, w.buf);
}

labeled_expand :: (suite_id: []u8, prk: []u8, label: string, info: []u8, dst: []u8) {
	w := writer_make();
	w_u16(*w, cast(u16) dst.count);
	w_raw(*w, "HPKE-v1");
	w_raw(*w, suite_id);
	w_raw(*w, label);
	w_raw(*w, info);
	kdf_expand(prk, w.buf, dst);
}

Key_Pair :: struct {
	priv: [NSK]u8;
	pub: [NPK]u8;
}

as_priv :: (b: []u8) -> [NSK]u8, bool {
	k: [NSK]u8;
	if b.count != NSK return k, false;
	memcpy(k.data, b.data, NSK);
	return k, true;
}

// public_from_private computes the uncompressed point for a P-256 scalar (ECDH and ECDSA alike).
public_from_private :: (priv: []u8) -> [NPK]u8, bool {
	k, ok := as_priv(priv);
	if !ok { pub: [NPK]u8; return pub, false; }
	defer crypto.zero(*k);
	pub, valid := crypto.p256_public(k);
	return pub, valid;
}

// derive_key_pair: RFC 9180 7.1.3 DeriveKeyPair for P-256 (rejection sampling, bitmask 0xff).
derive_key_pair :: (ikm: []u8) -> Key_Pair, bool {
	kp: Key_Pair;
	prk := labeled_extract(KEM_SUITE_ID, .[], "dkp_prk", ikm);
	for counter: 0..255 {
		c := u8.[cast(u8) counter];
		labeled_expand(KEM_SUITE_ID, prk, "candidate", c, kp.priv);
		ok: bool;
		kp.pub, ok = crypto.p256_public(kp.priv);
		if ok return kp, true;
	}
	return .{}, false;
}

generate_key_pair :: () -> Key_Pair {
	seed: [32]u8;
	while true {
		crypto.random_bytes(seed);
		kp, ok := derive_key_pair(seed);
		if ok return kp;
	}
	return .{};
}

dh :: (priv: []u8, pub: []u8) -> [32]u8, bool {
	k, ok := as_priv(priv);
	if !ok || !crypto.p256_valid_public(pub) { out: [32]u8; return out, false; }
	defer crypto.zero(*k);
	out, valid := crypto.p256_ecdh(k, pub);
	return out, valid;
}

kem_extract_and_expand :: (dhv: []u8, kem_context: []u8) -> Secret {
	shared: Secret;
	eae := labeled_extract(KEM_SUITE_ID, .[], "eae_prk", dhv);
	labeled_expand(KEM_SUITE_ID, eae, "shared_secret", kem_context, shared);
	return shared;
}

concat :: (a: []u8, b: []u8) -> []u8 {
	out := NewArray(a.count + b.count, u8,, temp);
	memcpy(out.data, a.data, a.count);
	memcpy(out.data + a.count, b.data, b.count);
	return out;
}

kem_encap :: (pk_r: []u8) -> Secret, [NPK]u8, bool {
	e := generate_key_pair();
	dhv, ok := dh(e.priv, pk_r);
	if !ok return ZERO_SECRET, e.pub, false;
	return kem_extract_and_expand(dhv, concat(e.pub, pk_r)), e.pub, true;
}

kem_decap :: (enc: []u8, sk_r: []u8) -> Secret, bool {
	pk_r, ok := public_from_private(sk_r);
	if !ok return ZERO_SECRET, false;
	dhv, ok2 := dh(sk_r, enc);
	if !ok2 return ZERO_SECRET, false;
	return kem_extract_and_expand(dhv, concat(enc, pk_r)), true;
}

hpke_key_schedule :: (shared: []u8, info: []u8) -> [NK]u8, [NN]u8 {
	key: [NK]u8;
	nonce: [NN]u8;
	psk_id_hash := labeled_extract(HPKE_SUITE_ID, .[], "psk_id_hash", .[]);
	info_hash := labeled_extract(HPKE_SUITE_ID, .[], "info_hash", info);
	ksc: [1 + 2 * NH]u8;  // mode_base (0) || psk_id_hash || info_hash
	memcpy(ksc.data + 1, psk_id_hash.data, NH);
	memcpy(ksc.data + 1 + NH, info_hash.data, NH);
	secret := labeled_extract(HPKE_SUITE_ID, shared, "secret", .[]);
	labeled_expand(HPKE_SUITE_ID, secret, "key", ksc, key);
	labeled_expand(HPKE_SUITE_ID, secret, "base_nonce", ksc, nonce);
	return key, nonce;
}

hpke_seal :: (pk_r: []u8, info: []u8, aad: []u8, pt: []u8) -> [NPK]u8, []u8, bool {
	shared, enc, ok := kem_encap(pk_r);
	if !ok return enc, .[], false;
	key, nonce := hpke_key_schedule(shared, info);
	return enc, aead_seal(key, nonce, aad, pt), true;
}

hpke_open :: (enc: []u8, sk_r: []u8, info: []u8, aad: []u8, ct: []u8) -> []u8, bool {
	shared, ok := kem_decap(enc, sk_r);
	if !ok return .[], false;
	key, nonce := hpke_key_schedule(shared, info);
	pt, ok2 := aead_open(key, nonce, aad, ct);
	return pt, ok2;
}

// ---------------------------------------------------------------------------
// MLS labeled primitives (RFC 9420 5.1).

w_label :: (w: *Writer, label: string) {
	p := w_begin(w);
	w_raw(w, "MLS 1.0 ");
	w_raw(w, label);
	w_end(w, p);
}

expand_with_label :: (secret: []u8, label: string, ctx: []u8, dst: []u8) {
	w := writer_make();
	w_u16(*w, cast(u16) dst.count);
	w_label(*w, label);
	w_vec(*w, ctx);
	kdf_expand(secret, w.buf, dst);
}

derive_secret :: (secret: []u8, label: string) -> Secret {
	out: Secret;
	expand_with_label(secret, label, .[], out);
	return out;
}

derive_tree_secret :: (secret: []u8, label: string, generation: u32, dst: []u8) {
	g := u8.[cast(u8) (generation >> 24), cast(u8) (generation >> 16), cast(u8) (generation >> 8), cast(u8) generation];
	expand_with_label(secret, label, g, dst);
}

// SignContent and EncryptContext share one layout: label vector || content vector.
label_content :: (label: string, content: []u8) -> []u8 {
	w := writer_make();
	w_label(*w, label);
	w_vec(*w, content);
	return w.buf;
}

// sign_with_label returns a DER ECDSA-P256-SHA256 signature in context.allocator.
sign_with_label :: (priv: []u8, label: string, content: []u8) -> []u8, bool {
	k, ok := as_priv(priv);
	if !ok return .[], false;
	defer crypto.zero(*k);
	sig := crypto.p256_sign(k, label_content(label, content));
	return sig, sig.count > 0;
}

verify_with_label :: (pub: []u8, label: string, content: []u8, sig: []u8) -> bool {
	return crypto.p256_valid_public(pub) && crypto.p256_verify(pub, label_content(label, content), sig);
}

generate_signature_key :: () -> [NSK]u8, [NPK]u8 {
	priv, pub, ok := crypto.p256_generate();
	assert(ok);
	return priv, pub;
}

Hpke_Ciphertext :: struct {
	kem_output: []u8;
	ciphertext: []u8;
}

encrypt_with_label :: (pub: []u8, label: string, ctx: []u8, pt: []u8) -> Hpke_Ciphertext, bool {
	enc, ct, ok := hpke_seal(pub, label_content(label, ctx), .[], pt);
	if !ok return .{}, false;
	return .{kem_output = clone_bytes(enc), ciphertext = ct}, true;
}

decrypt_with_label :: (priv: []u8, label: string, ctx: []u8, c: Hpke_Ciphertext) -> []u8, bool {
	pt, ok := hpke_open(c.kem_output, priv, label_content(label, ctx), .[], c.ciphertext);
	return pt, ok;
}

ref_hash :: (label: string, value: []u8) -> Secret {
	w := writer_make();
	p := w_begin(*w);
	w_raw(*w, label);
	w_end(*w, p);
	w_vec(*w, value);
	return hash_bytes(w.buf);
}
