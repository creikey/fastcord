// Ciphersuite 2: MLS_128_DHKEMP256_AES128GCM_SHA256_P256.
CIPHER_SUITE :: cast(u16)(2);
PROTOCOL_VERSION :: cast(u16)(1); // mls10

NH :: 32; // hash / KDF output
NK :: 16; // AEAD key
NN :: 12; // AEAD nonce
NT :: 16; // AEAD tag
NPK :: 65; // uncompressed P-256 point
NSK :: 32;

KEM_ID :: cast(u16)(0x0010);
KDF_ID :: cast(u16)(0x0001);
AEAD_ID :: cast(u16)(0x0001);

Secret :: [NH]u8;

hash_bytes :: (msg: []u8) -> Secret {
	out: Secret;
	ctx: sha2.Context_256;
	sha2.init_256(*ctx);
	sha2.update(*ctx, msg);
	sha2.final(*ctx, view(out));
	return out;
}

mac :: (key: []u8, msg: []u8) -> Secret {
	out: Secret;
	hmac.sum(.SHA256, view(out), msg, key);
	return out;
}

kdf_extract :: (salt: []u8, ikm: []u8) -> Secret {
	out: Secret;
	zero: Secret;
	s := ifx len(salt) > 0 then salt else view(zero);
	hkdf.extract(.SHA256, s, ikm, view(out));
	return out;
}

kdf_expand :: (prk: []u8, info: []u8, dst: []u8) {
	hkdf.expand(.SHA256, prk, info, dst);
}

// ---------------------------------------------------------------------------
// AEAD (AES-128-GCM). ct = ciphertext || tag.

aead_seal :: (key: []u8, nonce: []u8, aad: []u8, pt: []u8, allocator := context.allocator) -> []u8 {
	ctx: aes.Context_GCM;
	aes.init_gcm(*ctx, key);
	defer aes.reset_gcm(*ctx);
	out := make_slice(u8, len(pt) + NT, allocator);
	aes.seal_gcm(*ctx, sub(out, 0, len(pt)), sub_from(out, len(pt)), nonce, aad, pt);
	return out;
}

aead_open :: (key: []u8, nonce: []u8, aad: []u8, ct: []u8, allocator := context.allocator) -> []u8, bool {
	if len(ct) < NT { return .{}, false; }
	ctx: aes.Context_GCM;
	aes.init_gcm(*ctx, key);
	defer aes.reset_gcm(*ctx);
	n := len(ct) - NT;
	out := make_slice(u8, n, allocator);
	if !aes.open_gcm(*ctx, out, nonce, aad, sub(ct, 0, n), sub_from(ct, n)) {
		delete(out, allocator);
		return .{}, false;
	}
	return out, true;
}
#scope_module

// ---------------------------------------------------------------------------
// HPKE (RFC 9180) base mode, DHKEM(P-256, HKDF-SHA256), HKDF-SHA256, AES-128-GCM.

kem_suite_id :: () -> [5]u8 {return .[#char "K", #char "E", #char "M", cast(u8)(KEM_ID >> 8), cast(u8)(KEM_ID)];}
hpke_suite_id :: () -> [10]u8 {
	return .[#char "H", #char "P", #char "K", #char "E", cast(u8)(KEM_ID >> 8), cast(u8)(KEM_ID), cast(u8)(KDF_ID >> 8), cast(u8)(KDF_ID), cast(u8)(AEAD_ID >> 8), cast(u8)(AEAD_ID)];
}

labeled_extract :: (suite_id: []u8, salt: []u8, label: string, ikm: []u8) -> Secret {
	w := writer_make();
	w_raw(*w, transmute([]u8, as_string("HPKE-v1")));
	w_raw(*w, suite_id);
	w_raw(*w, transmute([]u8, label));
	w_raw(*w, ikm);
	return kdf_extract(salt, view(w.buf));
}

labeled_expand :: (suite_id: []u8, prk: []u8, label: string, info: []u8, dst: []u8) {
	w := writer_make();
	w_u16(*w, cast(u16)(len(dst)));
	w_raw(*w, transmute([]u8, as_string("HPKE-v1")));
	w_raw(*w, suite_id);
	w_raw(*w, transmute([]u8, label));
	w_raw(*w, info);
	kdf_expand(prk, view(w.buf), dst);
}
#scope_export

Key_Pair :: struct {
	priv: [NSK]u8;
	pub: [NPK]u8;
}

// public_from_private computes the uncompressed point for a P-256 scalar.
public_from_private :: (priv: []u8) -> [NPK]u8, bool {
	pub: [NPK]u8;
	ok: bool;
	k: ecdh.Private_Key;
	if !ecdh.private_key_set_bytes(*k, .SECP256R1, priv) { return pub, ok; }
	defer ecdh.private_key_clear(*k);
	ecdh.private_key_public_bytes(*k, view(pub));
	return pub, true;
}

// derive_key_pair: RFC 9180 7.1.3 DeriveKeyPair for P-256 (rejection sampling, bitmask 0xff).
derive_key_pair :: (ikm: []u8) -> Key_Pair, bool {
	kp: Key_Pair;
	ok: bool;
	sid := kem_suite_id();
	prk := labeled_extract(view(sid), null, "dkp_prk", ikm);
	for counter: 0..255 {
		c := u8.[cast(u8)(counter)];
		cand: [NSK]u8;
		labeled_expand(view(sid), view(prk), "candidate", view(c), view(cand));
		k: ecdh.Private_Key;
		if ecdh.private_key_set_bytes(*k, .SECP256R1, view(cand)) {
			kp.priv = cand;
			ecdh.private_key_public_bytes(*k, view(kp.pub));
			ecdh.private_key_clear(*k);
			return kp, true;
		}
	}
	return kp, ok;
}

generate_key_pair :: () -> Key_Pair {
	kp: Key_Pair;
	seed: [32]u8;
	while true {
		crypto.rand_bytes(view(seed));
		ok: bool;
		{ kp, ok = derive_key_pair(view(seed));
		if ok { return kp; } }
	}
}
#scope_module

dh :: (priv: []u8, pub: []u8) -> [32]u8, bool {
	out: [32]u8;
	ok: bool;
	sk: ecdh.Private_Key;
	pk: ecdh.Public_Key;
	if !ecdh.private_key_set_bytes(*sk, .SECP256R1, priv) { return out, ok; }
	defer ecdh.private_key_clear(*sk);
	if !ecdh.public_key_set_bytes(*pk, .SECP256R1, pub) { return out, ok; }
	defer ecdh.public_key_clear(*pk);
	if !ecdh.ecdh(*sk, *pk, view(out)) { return out, ok; }
	return out, true;
}

kem_extract_and_expand :: (dhv: []u8, kem_context: []u8) -> Secret {
	shared: Secret;
	sid := kem_suite_id();
	eae := labeled_extract(view(sid), null, "eae_prk", dhv);
	labeled_expand(view(sid), view(eae), "shared_secret", kem_context, view(shared));
	return shared;
}
#scope_export

kem_encap :: (pk_r: []u8) -> Secret, [NPK]u8, bool {
	shared: Secret;
	enc: [NPK]u8;
	ok: bool;
	e := generate_key_pair();
	dhv, __e1 := dh(view(e.priv), pk_r); if failed(__e1) return shared, enc, __e1;
	ctx := make_slice(u8, NPK + len(pk_r), temp);
	copy(ctx, view(e.pub));
	copy(sub_from(ctx, NPK), pk_r);
	return kem_extract_and_expand(view(dhv), ctx), e.pub, true;
}

kem_decap :: (enc: []u8, sk_r: []u8) -> Secret, bool {
	shared: Secret;
	ok: bool;
	pk_r, __e2 := public_from_private(sk_r); if failed(__e2) return shared, __e2;
	dhv, __e3 := dh(sk_r, enc); if failed(__e3) return shared, __e3;
	ctx := make_slice(u8, len(enc) + NPK, temp);
	copy(ctx, enc);
	copy(sub_from(ctx, len(enc)), view(pk_r));
	return kem_extract_and_expand(view(dhv), ctx), true;
}
#scope_module

hpke_key_schedule :: (shared: []u8, info: []u8) -> [NK]u8, [NN]u8 {
	key: [NK]u8;
	nonce: [NN]u8;
	sid := hpke_suite_id();
	psk_id_hash := labeled_extract(view(sid), null, "psk_id_hash", null);
	info_hash := labeled_extract(view(sid), null, "info_hash", info);
	ksc: [1 + 2 * NH]u8;
	ksc[0] = 0; // mode_base
	copy(sub_from(ksc, 1), view(psk_id_hash));
	copy(sub_from(ksc, 1 + NH), view(info_hash));
	secret := labeled_extract(view(sid), shared, "secret", null);
	labeled_expand(view(sid), view(secret), "key", view(ksc), view(key));
	labeled_expand(view(sid), view(secret), "base_nonce", view(ksc), view(nonce));
	return key, nonce;
}
#scope_export

hpke_seal :: (pk_r: []u8, info: []u8, aad: []u8, pt: []u8, allocator := context.allocator) -> [NPK]u8, []u8, bool {
	enc: [NPK]u8;
	ct: []u8;
	ok: bool;
	shared: Secret;
	__v5, __e4 := kem_encap(pk_r); if failed(__e4) return enc, ct, __e4; shared, enc = __v5;
	key, nonce := hpke_key_schedule(view(shared), info);
	return enc, aead_seal(view(key), view(nonce), aad, pt, allocator), true;
}

hpke_open :: (enc: []u8, sk_r: []u8, info: []u8, aad: []u8, ct: []u8, allocator := context.allocator) -> []u8, bool {
	shared, ok := kem_decap(enc, sk_r);
	if !ok { return .{}, false; }
	key, nonce := hpke_key_schedule(view(shared), info);
	{ __r6, __r7 := aead_open(view(key), view(nonce), aad, ct, allocator); return __r6, __r7; }
}
#scope_module

// ---------------------------------------------------------------------------
// MLS labeled primitives (RFC 9420 5.1).

w_label :: (w: *Writer, label: string) {
	p := w_begin(w);
	w_raw(w, transmute([]u8, as_string("MLS 1.0 ")));
	w_raw(w, transmute([]u8, label));
	w_end(w, p);
}
#scope_export

expand_with_label :: (secret: []u8, label: string, ctx: []u8, dst: []u8) {
	w := writer_make();
	w_u16(*w, cast(u16)(len(dst)));
	w_label(*w, label);
	w_vec(*w, ctx);
	kdf_expand(secret, view(w.buf), dst);
}

derive_secret :: (secret: []u8, label: string) -> Secret {
	out: Secret;
	expand_with_label(secret, label, null, view(out));
	return out;
}

derive_tree_secret :: (secret: []u8, label: string, generation: u32, dst: []u8) {
	g := u8.[cast(u8)(generation >> 24), cast(u8)(generation >> 16), cast(u8)(generation >> 8), cast(u8)(generation)];
	expand_with_label(secret, label, view(g), dst);
}
#scope_module

sign_content :: (label: string, content: []u8) -> []u8 {
	w := writer_make();
	w_label(*w, label);
	w_vec(*w, content);
	return view(w.buf);
}
#scope_export

// sign_with_label returns a DER ECDSA-P256-SHA256 signature.
sign_with_label :: (priv: []u8, label: string, content: []u8, allocator := context.allocator) -> []u8, bool {
	k: ecdsa.Private_Key;
	if !ecdsa.private_key_set_bytes(*k, .SECP256R1, priv) { return .{}, false; }
	defer ecdsa.private_key_clear(*k);
	{ __r8, __r9 := ecdsa.sign_asn1(*k, .SHA256, sign_content(label, content), allocator); return __r8, __r9; }
}

verify_with_label :: (pub: []u8, label: string, content: []u8, sig: []u8) -> bool {
	k: ecdsa.Public_Key;
	if !ecdsa.public_key_set_bytes(*k, .SECP256R1, pub) { return false; }
	defer ecdsa.public_key_clear(*k);
	return ecdsa.verify_asn1(*k, .SHA256, sign_content(label, content), sig);
}

signature_public_from_private :: (priv: []u8) -> [NPK]u8, bool {
	pub: [NPK]u8;
	ok: bool;
	k: ecdsa.Private_Key;
	if !ecdsa.private_key_set_bytes(*k, .SECP256R1, priv) { return pub, ok; }
	defer ecdsa.private_key_clear(*k);
	ecdsa.private_key_public_bytes(*k, view(pub));
	return pub, true;
}

generate_signature_key :: () -> [NSK]u8, [NPK]u8 {
	priv: [NSK]u8;
	pub: [NPK]u8;
	k: ecdsa.Private_Key;
	ok := ecdsa.private_key_generate(*k, .SECP256R1);
	assert(ok);
	ecdsa.private_key_bytes(*k, view(priv));
	ecdsa.private_key_public_bytes(*k, view(pub));
	ecdsa.private_key_clear(*k);
	return priv, pub;
}
#scope_module

encrypt_context :: (label: string, ctx: []u8) -> []u8 {
	w := writer_make();
	w_label(*w, label);
	w_vec(*w, ctx);
	return view(w.buf);
}
#scope_export

Hpke_Ciphertext :: struct {
	kem_output: []u8;
	ciphertext: []u8;
}

encrypt_with_label :: (pub: []u8, label: string, ctx: []u8, pt: []u8, allocator := context.allocator) -> Hpke_Ciphertext, bool {
	out: Hpke_Ciphertext;
	ok: bool;
	enc, ct, __e10 := hpke_seal(pub, encrypt_context(label, ctx), null, pt, allocator); if failed(__e10) return out, __e10;
	out.kem_output = clone_bytes(view(enc), allocator);
	out.ciphertext = ct;
	return out, true;
}

decrypt_with_label :: (priv: []u8, label: string, ctx: []u8, c: Hpke_Ciphertext, allocator := context.allocator) -> []u8, bool {
	{ __r11, __r12 := hpke_open(c.kem_output, priv, encrypt_context(label, ctx), null, c.ciphertext, allocator); return __r11, __r12; }
}

ref_hash :: (label: string, value: []u8) -> Secret {
	w := writer_make();
	p := w_begin(*w);
	w_raw(*w, transmute([]u8, label));
	w_end(*w, p);
	w_vec(*w, value);
	return hash_bytes(view(w.buf));
}


