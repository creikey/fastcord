// fastcord's call-and-return wrappers over BoringSSL's crypto for the Jai side: hashes, HMAC/HKDF/PBKDF2,
// AEADs with a detached tag, AES-CTR, and P-256 ECDH/ECDSA on raw byte strings. Built by build.jai into
// build/fc_boringssl.o; bound in jai/fc_crypto.
#include <openssl/aead.h>
#include <openssl/aes.h>
#include <openssl/bn.h>
#include <openssl/ec.h>
#include <openssl/ec_key.h>
#include <openssl/ecdh.h>
#include <openssl/ecdsa.h>
#include <openssl/evp.h>
#include <openssl/hkdf.h>
#include <openssl/hmac.h>
#include <openssl/bytestring.h>
#include <openssl/md5.h>
#include <openssl/mem.h>
#include <openssl/mlkem.h>
#include <openssl/nid.h>
#include <openssl/rand.h>
#include <openssl/sha.h>
#include <openssl/ssl.h>
#include <openssl/x509.h>
#include <string.h>

void fc_rand_bytes(uint8_t *p, size_t n) { RAND_bytes(p, n); }
void fc_zero(void *p, size_t n) { OPENSSL_cleanse(p, n); }
int fc_compare_constant_time(const uint8_t *a, const uint8_t *b, size_t n) { return CRYPTO_memcmp(a, b, n) == 0; }

void fc_sha1(const uint8_t *p, size_t n, uint8_t out[20]) { SHA1(p, n, out); }
void fc_md5(const uint8_t *p, size_t n, uint8_t out[16]) { MD5(p, n, out); }
void fc_sha256(const uint8_t *p, size_t n, uint8_t out[32]) { SHA256(p, n, out); }

void fc_hmac_sha256(const uint8_t *key, size_t klen, const uint8_t *msg, size_t mlen, uint8_t out[32]) {
    unsigned len = 32;
    HMAC(EVP_sha256(), key, klen, msg, mlen, out, &len);
}
int fc_hkdf_extract(const uint8_t *salt, size_t slen, const uint8_t *ikm, size_t ilen, uint8_t out[32]) {
    size_t len = 32;
    return HKDF_extract(out, &len, EVP_sha256(), ikm, ilen, salt, slen);
}
int fc_hkdf_expand(const uint8_t *prk, size_t plen, const uint8_t *info, size_t ilen, uint8_t *out, size_t olen) {
    return HKDF_expand(out, olen, EVP_sha256(), prk, plen, info, ilen);
}
int fc_pbkdf2_sha256(const uint8_t *pass, size_t plen, const uint8_t *salt, size_t slen, unsigned iters, uint8_t *out, size_t olen) {
    return PKCS5_PBKDF2_HMAC((const char *)pass, plen, salt, slen, iters, EVP_sha256(), olen, out);
}

// AEAD: kind 0 = AES-GCM (key size picks 128/256), 1 = XChaCha20-Poly1305. The context lives in the caller's blob.
size_t fc_aead_size(void) { return sizeof(EVP_AEAD_CTX); }
int fc_aead_init(void *ctx, int kind, const uint8_t *key, size_t klen) {
    const EVP_AEAD *a = kind == 2 ? EVP_aead_chacha20_poly1305() : kind == 1 ? EVP_aead_xchacha20_poly1305() : klen == 32 ? EVP_aead_aes_256_gcm() : EVP_aead_aes_128_gcm();
    return EVP_AEAD_CTX_init((EVP_AEAD_CTX *)ctx, a, key, klen, 16, NULL);
}
void fc_aead_reset(void *ctx) { EVP_AEAD_CTX_cleanup((EVP_AEAD_CTX *)ctx); }
int fc_aead_seal(void *ctx, uint8_t *out, uint8_t *tag, const uint8_t *nonce, size_t nlen, const uint8_t *ad, size_t adlen, const uint8_t *in, size_t inlen) {
    size_t tag_len = 0;
    return EVP_AEAD_CTX_seal_scatter((EVP_AEAD_CTX *)ctx, out, tag, &tag_len, 16, nonce, nlen, in, inlen, NULL, 0, ad, adlen);
}
int fc_aead_open(void *ctx, uint8_t *out, const uint8_t *nonce, size_t nlen, const uint8_t *ad, size_t adlen, const uint8_t *in, size_t inlen, const uint8_t *tag, size_t tlen) {
    return EVP_AEAD_CTX_open_gather((EVP_AEAD_CTX *)ctx, out, nonce, nlen, in, inlen, tag, tlen, ad, adlen);
}

// AES-CTR over a 16-byte IV, one shot.
void fc_aes_ctr(const uint8_t *key, size_t klen, const uint8_t iv[16], const uint8_t *in, uint8_t *out, size_t n) {
    AES_KEY k;
    AES_set_encrypt_key(key, (unsigned)klen * 8, &k);
    uint8_t ivec[16], ecount[16] = {0};
    unsigned num = 0;
    memcpy(ivec, iv, 16);
    AES_ctr128_encrypt(in, out, n, &k, ivec, ecount, &num);
    OPENSSL_cleanse(&k, sizeof k);
}

// P-256 on raw bytes: private keys are 32-byte scalars, public keys 65-byte uncompressed points.
static EC_KEY *fc__key(const uint8_t *priv) {
    EC_KEY *k = EC_KEY_new_by_curve_name(NID_X9_62_prime256v1);
    if (!k) return NULL;
    if (priv) {
        BIGNUM *d = BN_bin2bn(priv, 32, NULL);
        EC_POINT *p = EC_POINT_new(EC_KEY_get0_group(k));
        int ok = d && p && EC_KEY_set_private_key(k, d) && EC_POINT_mul(EC_KEY_get0_group(k), p, d, NULL, NULL, NULL) && EC_KEY_set_public_key(k, p);
        BN_clear_free(d);
        EC_POINT_free(p);
        if (!ok) { EC_KEY_free(k); return NULL; }
    }
    return k;
}
int fc_p256_public(const uint8_t priv[32], uint8_t pub[65]) {
    EC_KEY *k = fc__key(priv);
    if (!k) return 0;
    size_t n = EC_POINT_point2oct(EC_KEY_get0_group(k), EC_KEY_get0_public_key(k), POINT_CONVERSION_UNCOMPRESSED, pub, 65, NULL);
    EC_KEY_free(k);
    return n == 65;
}
int fc_p256_generate(uint8_t priv[32], uint8_t pub[65]) {
    EC_KEY *k = fc__key(NULL);
    if (!k || !EC_KEY_generate_key(k)) { EC_KEY_free(k); return 0; }
    int ok = BN_bn2bin_padded(priv, 32, EC_KEY_get0_private_key(k)) &&
             EC_POINT_point2oct(EC_KEY_get0_group(k), EC_KEY_get0_public_key(k), POINT_CONVERSION_UNCOMPRESSED, pub, 65, NULL) == 65;
    EC_KEY_free(k);
    return ok;
}
int fc_p256_valid_public(const uint8_t *pub, size_t n) {
    EC_KEY *k = fc__key(NULL);
    EC_POINT *p = EC_POINT_new(EC_KEY_get0_group(k));
    int ok = EC_POINT_oct2point(EC_KEY_get0_group(k), p, pub, n, NULL);
    EC_POINT_free(p);
    EC_KEY_free(k);
    return ok;
}
int fc_p256_ecdh(const uint8_t priv[32], const uint8_t *pub, size_t pub_len, uint8_t out[32]) {
    EC_KEY *k = fc__key(priv);
    if (!k) return 0;
    EC_POINT *p = EC_POINT_new(EC_KEY_get0_group(k));
    int ok = EC_POINT_oct2point(EC_KEY_get0_group(k), p, pub, pub_len, NULL) && ECDH_compute_key(out, 32, p, k, NULL) == 32;
    EC_POINT_free(p);
    EC_KEY_free(k);
    return ok;
}
// ECDSA-SHA256, DER signature. sig must hold 72 bytes; returns its length or 0.
size_t fc_p256_sign(const uint8_t priv[32], const uint8_t *msg, size_t mlen, uint8_t *sig) {
    uint8_t h[32];
    SHA256(msg, mlen, h);
    EC_KEY *k = fc__key(priv);
    unsigned len = 0;
    int ok = k && ECDSA_sign(0, h, 32, sig, &len, k);
    EC_KEY_free(k);
    return ok ? len : 0;
}
int fc_p256_verify(const uint8_t *pub, size_t pub_len, const uint8_t *msg, size_t mlen, const uint8_t *sig, size_t slen) {
    uint8_t h[32];
    SHA256(msg, mlen, h);
    EC_KEY *k = fc__key(NULL);
    EC_POINT *p = EC_POINT_new(EC_KEY_get0_group(k));
    int ok = EC_POINT_oct2point(EC_KEY_get0_group(k), p, pub, pub_len, NULL) && EC_KEY_set_public_key(k, p) &&
             ECDSA_verify(0, h, 32, sig, slen, k) == 1;
    EC_POINT_free(p);
    EC_KEY_free(k);
    return ok;
}

// A self-signed certificate for a self-hosted server's P-256 key, valid for 100 years. Clients pin its
// hash, so no field but the key matters. out must hold 1024 bytes; returns the DER length or 0.
size_t fc_selfsigned_cert(const uint8_t priv[32], uint8_t *out) {
    EC_KEY *k = fc__key(priv);
    EVP_PKEY *pk = EVP_PKEY_new();
    X509 *x = X509_new();
    size_t n = 0;
    if (k && pk && x && EVP_PKEY_set1_EC_KEY(pk, k)) {
        X509_NAME *name = X509_get_subject_name(x);
        int ok = X509_set_version(x, X509_VERSION_3) && ASN1_INTEGER_set(X509_get_serialNumber(x), 1) &&
                 X509_gmtime_adj(X509_getm_notBefore(x), -86400) && X509_time_adj_ex(X509_getm_notAfter(x), 36500, 0, NULL) &&
                 X509_NAME_add_entry_by_txt(name, "CN", MBSTRING_ASC, (const uint8_t *)"fastcord", -1, -1, 0) &&
                 X509_set_issuer_name(x, name) && X509_set_pubkey(x, pk) && X509_sign(x, pk, EVP_sha256());
        int len = ok ? i2d_X509(x, NULL) : 0;
        if (len > 0 && len <= 1024) { uint8_t *p = out; i2d_X509(x, &p); n = (size_t)len; }
    }
    X509_free(x);
    EVP_PKEY_free(pk);
    EC_KEY_free(k);
    return n;
}

// ML-KEM-768. The private key is kept as its 64-byte seed, so no opaque struct crosses into Jai.
void fc_mlkem768_generate(uint8_t pub[MLKEM768_PUBLIC_KEY_BYTES], uint8_t seed[MLKEM_SEED_BYTES]) {
    struct MLKEM768_private_key priv;
    MLKEM768_generate_key(pub, seed, &priv);
    OPENSSL_cleanse(&priv, sizeof priv);
}

int fc_mlkem768_encap(const uint8_t pub[MLKEM768_PUBLIC_KEY_BYTES], uint8_t ct[MLKEM768_CIPHERTEXT_BYTES], uint8_t ss[MLKEM_SHARED_SECRET_BYTES]) {
    struct MLKEM768_public_key pk;
    CBS cbs;
    CBS_init(&cbs, pub, MLKEM768_PUBLIC_KEY_BYTES);
    if (!MLKEM768_parse_public_key(&pk, &cbs) || CBS_len(&cbs) != 0) return 0;
    MLKEM768_encap(ct, ss, &pk);
    return 1;
}

int fc_mlkem768_decap(const uint8_t seed[MLKEM_SEED_BYTES], const uint8_t ct[MLKEM768_CIPHERTEXT_BYTES], uint8_t ss[MLKEM_SHARED_SECRET_BYTES]) {
    struct MLKEM768_private_key priv;
    if (!MLKEM768_private_key_from_seed(&priv, seed, MLKEM_SEED_BYTES)) return 0;
    int ok = MLKEM768_decap(ss, ct, MLKEM768_CIPHERTEXT_BYTES, &priv);
    OPENSSL_cleanse(&priv, sizeof priv);
    return ok;
}

int fc_ssl_ctx_use_p256(SSL_CTX *ctx, const uint8_t priv[32], const uint8_t *cert, size_t cert_len) {
    EC_KEY *k = fc__key(priv);
    EVP_PKEY *pk = EVP_PKEY_new();
    int ok = k && pk && EVP_PKEY_set1_EC_KEY(pk, k) && SSL_CTX_use_certificate_ASN1(ctx, cert_len, cert) &&
             SSL_CTX_use_PrivateKey(ctx, pk) && SSL_CTX_check_private_key(ctx);
    EVP_PKEY_free(pk);
    EC_KEY_free(k);
    return ok;
}
