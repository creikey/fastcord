// BoringSSL crypto (vendor/boringssl/fc_boringssl.c) for the per-algorithm modules.
#import "Basic";
#import "fc";
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

rand_bytes :: (b: []u8) { fc_rand_bytes(b.data, xx b.count); }
zero_explicit :: (p: *void, n: int) { fc_zero(p, xx n); }
compare_constant_time :: (a: []u8, b: []u8) -> int { if a.count != b.count return 0; return fc_compare_constant_time(a.data, b.data, xx a.count); }

Hash :: enum { SHA256; }
Curve :: enum { SECP256R1; }
// Streaming hash contexts buffer their input; final hashes it in one call.
Hash_Context :: struct { data: [..]u8; }
hash_update :: (c: *Hash_Context, b: []u8) { append(*c.data, ..b); }
Aead :: struct { ctx: [64]u8; }  // EVP_AEAD_CTX (size checked by aead_init)
aead_init :: (a: *Aead, kind: s32, key: []u8) {
    assert(fc_aead_size() <= size_of(type_of(a.ctx)));
    fc_aead_init(a.ctx.data, kind, key.data, xx key.count);
}
aead_seal :: (a: *Aead, dst: []u8, tag: []u8, iv: []u8, aad: []u8, pt: []u8) {
    fc_aead_seal(a.ctx.data, dst.data, tag.data, iv.data, xx iv.count, aad.data, xx aad.count, pt.data, xx pt.count);
}
aead_open :: (a: *Aead, dst: []u8, iv: []u8, aad: []u8, ct: []u8, tag: []u8) -> bool {
    return fc_aead_open(a.ctx.data, dst.data, iv.data, xx iv.count, aad.data, xx aad.count, ct.data, xx ct.count, tag.data, xx tag.count) == 1;
}
Key :: struct { priv: [32]u8; pub: [65]u8; ok: bool; }
