// BoringSSL crypto (vendor/boringssl/fc_boringssl.c) as plain procedures on bytes.
#import "Basic";

random_bytes :: (b: []u8) { fc_rand_bytes(b.data, xx b.count); }
// zero wipes secrets in a way the optimizer can't drop.
zero :: (b: []u8) { fc_zero(b.data, xx b.count); }
zero :: (x: *$T) { fc_zero(x, size_of(T)); }
constant_time_equal :: (a: []u8, b: []u8) -> bool {
    return a.count == b.count && fc_compare_constant_time(a.data, b.data, xx a.count) == 1;
}

sha1   :: (data: []u8) -> [20]u8 { out: [20]u8; fc_sha1(data.data, xx data.count, out.data); return out; }
md5    :: (data: []u8) -> [16]u8 { out: [16]u8; fc_md5(data.data, xx data.count, out.data); return out; }
sha256 :: (data: []u8) -> [32]u8 { out: [32]u8; fc_sha256(data.data, xx data.count, out.data); return out; }
hmac_sha256 :: (key: []u8, msg: []u8) -> [32]u8 {
    out: [32]u8;
    fc_hmac_sha256(key.data, xx key.count, msg.data, xx msg.count, out.data);
    return out;
}
// HKDF and PBKDF2 over SHA-256.
hkdf_extract :: (salt: []u8, ikm: []u8) -> [32]u8 {
    out: [32]u8;
    fc_hkdf_extract(salt.data, xx salt.count, ikm.data, xx ikm.count, out.data);
    return out;
}
hkdf_expand :: (prk: []u8, info: []u8, out: []u8) -> bool {
    return fc_hkdf_expand(prk.data, xx prk.count, info.data, xx info.count, out.data, xx out.count) == 1;
}
pbkdf2_sha256 :: (password: []u8, salt: []u8, iterations: u32, out: []u8) -> bool {
    return fc_pbkdf2_sha256(password.data, xx password.count, salt.data, xx salt.count, iterations, out.data, xx out.count) == 1;
}

// AEAD with 16-byte tags kept apart from the ciphertext. AES-GCM picks 128 or 256 from the key size.
Aead_Kind :: enum s32 { AES_GCM :: 0; XCHACHA20_POLY1305 :: 1; }
Aead :: struct { ctx: [72]u64; }  // BoringSSL's EVP_AEAD_CTX (576 bytes, 8-aligned)
aead_init :: (a: *Aead, kind: Aead_Kind, key: []u8) -> bool {
    assert(fc_aead_size() <= size_of(type_of(a.ctx)));
    return fc_aead_init(a.ctx.data, xx kind, key.data, xx key.count) == 1;
}
aead_destroy :: (a: *Aead) { fc_aead_reset(a.ctx.data); }
// seal encrypts pt into dst (same length) and writes the tag.
seal :: (a: *Aead, dst: []u8, tag: []u8, nonce: []u8, aad: []u8, pt: []u8) -> bool {
    return fc_aead_seal(a.ctx.data, dst.data, tag.data, nonce.data, xx nonce.count, aad.data, xx aad.count, pt.data, xx pt.count) == 1;
}
// open decrypts ct into dst (same length); false when the tag doesn't match.
open :: (a: *Aead, dst: []u8, nonce: []u8, aad: []u8, ct: []u8, tag: []u8) -> bool {
    return fc_aead_open(a.ctx.data, dst.data, nonce.data, xx nonce.count, aad.data, xx aad.count, ct.data, xx ct.count, tag.data, xx tag.count) == 1;
}

// aes_ctr XORs src with the AES-CTR keystream starting at a 16-byte iv; dst may be src.
aes_ctr :: (key: []u8, iv: []u8, src: []u8, dst: []u8) {
    assert(iv.count == 16 && dst.count >= src.count);
    fc_aes_ctr(key.data, xx key.count, iv.data, src.data, dst.data, xx src.count);
}

// P-256: private keys are 32-byte scalars, public keys 65-byte uncompressed points.
p256_public :: (priv: [32]u8) -> [65]u8, bool {
    pub: [65]u8;
    ok := fc_p256_public(priv.data, pub.data) == 1;
    return pub, ok;
}
p256_generate :: () -> priv: [32]u8, pub: [65]u8, ok: bool {
    priv: [32]u8;
    pub: [65]u8;
    ok := fc_p256_generate(priv.data, pub.data) == 1;
    return priv, pub, ok;
}
p256_valid_public :: (pub: []u8) -> bool { return pub.count == 65 && fc_p256_valid_public(pub.data, 65) == 1; }
p256_ecdh :: (priv: [32]u8, pub: []u8) -> [32]u8, bool {
    out: [32]u8;
    ok := fc_p256_ecdh(priv.data, pub.data, xx pub.count, out.data) == 1;
    return out, ok;
}
// p256_sign makes an ECDSA-SHA256 DER signature in context.allocator; empty on failure.
p256_sign :: (priv: [32]u8, msg: []u8) -> []u8 {
    sig: [72]u8;
    n := cast(int) fc_p256_sign(priv.data, msg.data, xx msg.count, sig.data);
    out := NewArray(n, u8, false);
    memcpy(out.data, sig.data, n);
    return out;
}
p256_verify :: (pub: []u8, msg: []u8, sig: []u8) -> bool {
    return fc_p256_verify(pub.data, xx pub.count, msg.data, xx msg.count, sig.data, xx sig.count) == 1;
}

#scope_file
bssl :: #library,no_dll "../../build/fc_vendor";
fc_rand_bytes :: (p: *u8, n: u64) #foreign bssl;
fc_zero :: (p: *void, n: u64) #foreign bssl;
fc_compare_constant_time :: (a: *u8, b: *u8, n: u64) -> s32 #foreign bssl;
fc_sha1 :: (p: *u8, n: u64, out: *u8) #foreign bssl;
fc_md5 :: (p: *u8, n: u64, out: *u8) #foreign bssl;
fc_sha256 :: (p: *u8, n: u64, out: *u8) #foreign bssl;
fc_hmac_sha256 :: (key: *u8, klen: u64, msg: *u8, mlen: u64, out: *u8) #foreign bssl;
fc_hkdf_extract :: (salt: *u8, slen: u64, ikm: *u8, ilen: u64, out: *u8) -> s32 #foreign bssl;
fc_hkdf_expand :: (prk: *u8, plen: u64, info: *u8, ilen: u64, out: *u8, olen: u64) -> s32 #foreign bssl;
fc_pbkdf2_sha256 :: (pass: *u8, plen: u64, salt: *u8, slen: u64, iters: u32, out: *u8, olen: u64) -> s32 #foreign bssl;
fc_aead_size :: () -> u64 #foreign bssl;
fc_aead_init :: (ctx: *void, kind: s32, key: *u8, klen: u64) -> s32 #foreign bssl;
fc_aead_reset :: (ctx: *void) #foreign bssl;
fc_aead_seal :: (ctx: *void, out: *u8, tag: *u8, nonce: *u8, nlen: u64, ad: *u8, adlen: u64, in: *u8, inlen: u64) -> s32 #foreign bssl;
fc_aead_open :: (ctx: *void, out: *u8, nonce: *u8, nlen: u64, ad: *u8, adlen: u64, in: *u8, inlen: u64, tag: *u8, tlen: u64) -> s32 #foreign bssl;
fc_aes_ctr :: (key: *u8, klen: u64, iv: *u8, in: *u8, out: *u8, n: u64) #foreign bssl;
fc_p256_public :: (priv: *u8, pub: *u8) -> s32 #foreign bssl;
fc_p256_generate :: (priv: *u8, pub: *u8) -> s32 #foreign bssl;
fc_p256_valid_public :: (pub: *u8, n: u64) -> s32 #foreign bssl;
fc_p256_ecdh :: (priv: *u8, pub: *u8, pub_len: u64, out: *u8) -> s32 #foreign bssl;
fc_p256_sign :: (priv: *u8, msg: *u8, mlen: u64, sig: *u8) -> u64 #foreign bssl;
fc_p256_verify :: (pub: *u8, pub_len: u64, msg: *u8, mlen: u64, sig: *u8, slen: u64) -> s32 #foreign bssl;
