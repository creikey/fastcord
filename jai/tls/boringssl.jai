// vendor/boringssl, built by build.sh / build.bat into a static library. Its libssl is C++ built
// without exceptions or RTTI; MSVC's CRT and macOS's libc++ supply the few runtime symbols it needs.
#if OS == .WINDOWS {
} else {
}

SSL :: struct {}
SSL_CTX :: struct {}
SSL_METHOD :: struct {}
SSL_SESSION :: struct {}
SSL_CIPHER :: struct {}
BIO :: struct {}
BIO_METHOD :: struct {}
X509 :: struct {}
CRYPTO_BUFFER :: struct {}
OPENSSL_STACK :: struct {}

TLS1_2_VERSION :: 0x0303;
TLS1_3_VERSION :: 0x0304;
SSL_ERROR_WANT_READ :: 2;
SSL_ERROR_ZERO_RETURN :: 6;
SSL_VERIFY_PEER :: 1;
SSL_SESS_CACHE_CLIENT :: 1;
SSL_KEY_UPDATE_REQUESTED :: 1;
ssl_verify_ok :: 0;
ssl_verify_invalid :: 1;

Verify_Callback :: (ssl: *SSL, out_alert: *u8) -> s32 #c_call;
Decompress_Callback :: (ssl: *SSL, out: **CRYPTO_BUFFER, uncompressed_len: u64, data: *u8, data_len: u64) -> s32 #c_call;
New_Session_Callback :: (ssl: *SSL, session: *SSL_SESSION) -> s32 #c_call;
Ex_Free_Callback :: (parent: *void, ptr: *void, ad: *void, index: s32, argl: s64, argp: *void) #c_call;
	TLS_method :: () -> *SSL_METHOD #foreign bssl;
	SSL_CTX_new :: (method: *SSL_METHOD) -> *SSL_CTX #foreign bssl;
	SSL_CTX_free :: (ctx: *SSL_CTX) #foreign bssl;
	SSL_CTX_set_min_proto_version :: (ctx: *SSL_CTX, version: u16) -> s32 #foreign bssl;
	SSL_CTX_set_max_proto_version :: (ctx: *SSL_CTX, version: u16) -> s32 #foreign bssl;
	SSL_CTX_set1_tls13_ciphers :: (ctx: *SSL_CTX, ids: *u16, flags: *u32, n: u64) -> s32 #foreign bssl;
	SSL_CTX_set_strict_cipher_list :: (ctx: *SSL_CTX, str: *u8) -> s32 #foreign bssl;
	SSL_CTX_set1_group_ids :: (ctx: *SSL_CTX, ids: *u16, n: u64) -> s32 #foreign bssl;
	SSL_CTX_set_verify_algorithm_prefs :: (ctx: *SSL_CTX, prefs: *u16, n: u64) -> s32 #foreign bssl;
	SSL_CTX_add_cert_compression_alg :: (ctx: *SSL_CTX, alg: u16, compress: *void, decompress: Decompress_Callback) -> s32 #foreign bssl;
	SSL_CTX_set_grease_enabled :: (ctx: *SSL_CTX, enabled: s32) #foreign bssl;
	SSL_CTX_set_permute_extensions :: (ctx: *SSL_CTX, enabled: s32) #foreign bssl;
	SSL_CTX_enable_ocsp_stapling :: (ctx: *SSL_CTX) #foreign bssl;
	SSL_CTX_enable_signed_cert_timestamps :: (ctx: *SSL_CTX) #foreign bssl;
	SSL_CTX_set_session_cache_mode :: (ctx: *SSL_CTX, mode: s32) -> s32 #foreign bssl;
	SSL_CTX_sess_set_new_cb :: (ctx: *SSL_CTX, cb: New_Session_Callback) #foreign bssl;
	SSL_CTX_set_custom_verify :: (ctx: *SSL_CTX, mode: s32, cb: Verify_Callback) #foreign bssl;

	SSL_new :: (ctx: *SSL_CTX) -> *SSL #foreign bssl;
	SSL_free :: (ssl: *SSL) #foreign bssl;
	SSL_set_connect_state :: (ssl: *SSL) #foreign bssl;
	SSL_set_bio :: (ssl: *SSL, rbio: *BIO, wbio: *BIO) #foreign bssl;
	SSL_set_tlsext_host_name :: (ssl: *SSL, name: *u8) -> s32 #foreign bssl;
	SSL_set_alpn_protos :: (ssl: *SSL, protos: *u8, n: u64) -> s32 #foreign bssl;
	SSL_add_application_settings :: (ssl: *SSL, proto: *u8, proto_len: u64, settings: *u8, settings_len: u64) -> s32 #foreign bssl;
	SSL_set_alps_use_new_codepoint :: (ssl: *SSL, use_new: s32) #foreign bssl;
	SSL_set_enable_ech_grease :: (ssl: *SSL, enable: s32) #foreign bssl;
	SSL_set_early_data_enabled :: (ssl: *SSL, enabled: s32) #foreign bssl;
	SSL_set_custom_verify :: (ssl: *SSL, mode: s32, cb: Verify_Callback) #foreign bssl;
	SSL_set_session :: (ssl: *SSL, session: *SSL_SESSION) -> s32 #foreign bssl;
	SSL_SESSION_free :: (session: *SSL_SESSION) #foreign bssl;
	SSL_get_ex_new_index :: (argl: s64, argp: *void, unused: *void, dup: *void, free_func: Ex_Free_Callback) -> s32 #foreign bssl;
	SSL_set_ex_data :: (ssl: *SSL, idx: s32, data: *void) -> s32 #foreign bssl;
	SSL_get_ex_data :: (ssl: *SSL, idx: s32) -> *void #foreign bssl;
	SSL_is_quic :: (ssl: *SSL) -> s32 #foreign bssl;

	SSL_do_handshake :: (ssl: *SSL) -> s32 #foreign bssl;
	SSL_read :: (ssl: *SSL, buf: *void, n: s32) -> s32 #foreign bssl;
	SSL_write :: (ssl: *SSL, buf: *void, n: s32) -> s32 #foreign bssl;
	SSL_shutdown :: (ssl: *SSL) -> s32 #foreign bssl;
	SSL_key_update :: (ssl: *SSL, request_type: s32) -> s32 #foreign bssl;
	SSL_get_error :: (ssl: *SSL, ret: s32) -> s32 #foreign bssl;
	SSL_get0_alpn_selected :: (ssl: *SSL, data: **u8, n: *u32) #foreign bssl;
	SSL_get_group_id :: (ssl: *SSL) -> u16 #foreign bssl;
	SSL_get_current_cipher :: (ssl: *SSL) -> *SSL_CIPHER #foreign bssl;
	SSL_CIPHER_get_protocol_id :: (cipher: *SSL_CIPHER) -> u16 #foreign bssl;
	SSL_session_reused :: (ssl: *SSL) -> s32 #foreign bssl;
	SSL_get0_peer_certificates :: (ssl: *SSL) -> *OPENSSL_STACK #foreign bssl;

	BIO_new :: (method: *BIO_METHOD) -> *BIO #foreign bssl;
	BIO_s_mem :: () -> *BIO_METHOD #foreign bssl;
	BIO_read :: (bio: *BIO, data: *void, n: s32) -> s32 #foreign bssl;
	BIO_write :: (bio: *BIO, data: *void, n: s32) -> s32 #foreign bssl;
	BIO_pending :: (bio: *BIO) -> u64 #foreign bssl;

	OPENSSL_sk_num :: (sk: *OPENSSL_STACK) -> u64 #foreign bssl;
	OPENSSL_sk_value :: (sk: *OPENSSL_STACK, i: u64) -> *void #foreign bssl;
	CRYPTO_BUFFER_new :: (data: *u8, n: u64, pool: *void) -> *CRYPTO_BUFFER #foreign bssl;
	CRYPTO_BUFFER_data :: (buf: *CRYPTO_BUFFER) -> *u8 #foreign bssl;
	CRYPTO_BUFFER_len :: (buf: *CRYPTO_BUFFER) -> u64 #foreign bssl;
	d2i_X509 :: (out: **X509, inp: **u8, n: s64) -> *X509 #foreign bssl;
	X509_check_host :: (x: *X509, name: *u8, name_len: u64, flags: u32, peername: *void) -> s32 #foreign bssl;
	X509_free :: (x: *X509) #foreign bssl;
	OPENSSL_strdup :: (s: *u8) -> *u8 #foreign bssl;
	OPENSSL_free :: (p: *void) #foreign bssl;
	ERR_clear_error :: () #foreign bssl;
	ERR_peek_error :: () -> u32 #foreign bssl;

	// RSA-OAEP and SHA-256 for QR login (src/discord/remote_auth.odin)
	EVP_PKEY_new :: () -> *EVP_PKEY #foreign bssl;
	EVP_PKEY_free :: (pkey: *EVP_PKEY) #foreign bssl;
	EVP_PKEY_assign_RSA :: (pkey: *EVP_PKEY, key: *RSA) -> s32 #foreign bssl;
	EVP_PKEY_CTX_new :: (pkey: *EVP_PKEY, e: *void) -> *EVP_PKEY_CTX #foreign bssl;
	EVP_PKEY_CTX_new_id :: (id: s32, e: *void) -> *EVP_PKEY_CTX #foreign bssl;
	EVP_PKEY_CTX_free :: (ctx: *EVP_PKEY_CTX) #foreign bssl;
	EVP_PKEY_keygen_init :: (ctx: *EVP_PKEY_CTX) -> s32 #foreign bssl;
	EVP_PKEY_keygen :: (ctx: *EVP_PKEY_CTX, out: **EVP_PKEY) -> s32 #foreign bssl;
	EVP_PKEY_CTX_set_rsa_keygen_bits :: (ctx: *EVP_PKEY_CTX, bits: s32) -> s32 #foreign bssl;
	EVP_PKEY_CTX_set_rsa_padding :: (ctx: *EVP_PKEY_CTX, padding: s32) -> s32 #foreign bssl;
	EVP_PKEY_CTX_set_rsa_oaep_md :: (ctx: *EVP_PKEY_CTX, md: *EVP_MD) -> s32 #foreign bssl;
	EVP_PKEY_encrypt_init :: (ctx: *EVP_PKEY_CTX) -> s32 #foreign bssl;
	EVP_PKEY_encrypt :: (ctx: *EVP_PKEY_CTX, out: *u8, out_len: *u64, input: *u8, in_len: u64) -> s32 #foreign bssl;
	EVP_PKEY_decrypt_init :: (ctx: *EVP_PKEY_CTX) -> s32 #foreign bssl;
	EVP_PKEY_decrypt :: (ctx: *EVP_PKEY_CTX, out: *u8, out_len: *u64, input: *u8, in_len: u64) -> s32 #foreign bssl;
	EVP_sha256 :: () -> *EVP_MD #foreign bssl;
	i2d_PUBKEY :: (pkey: *EVP_PKEY, outp: **u8) -> s32 #foreign bssl;
	d2i_PUBKEY :: (out: **EVP_PKEY, inp: **u8, n: s64) -> *EVP_PKEY #foreign bssl;
	RSA_new_private_key :: (n: *BIGNUM, e: *BIGNUM, d: *BIGNUM, p: *BIGNUM, q: *BIGNUM, dmp1: *BIGNUM, dmq1: *BIGNUM, iqmp: *BIGNUM) -> *RSA #foreign bssl;
	BN_bin2bn :: (data: *u8, n: u64, ret: *BIGNUM) -> *BIGNUM #foreign bssl;
	BN_free :: (bn: *BIGNUM) #foreign bssl;
	SHA256 :: (data: *u8, n: u64, out: *u8) -> *u8 #foreign bssl;

EVP_PKEY :: struct {}
EVP_PKEY_CTX :: struct {}
EVP_MD :: struct {}
RSA :: struct {}
BIGNUM :: struct {}
EVP_PKEY_RSA :: 6;
RSA_PKCS1_OAEP_PADDING :: 4;

// ERR_PACK(ERR_LIB_SSL, SSL_R_CERTIFICATE_VERIFY_FAILED): what a rejected certificate leaves first
// on the thread's error queue.
ERR_CERTIFICATE_VERIFY_FAILED :: 16 << 24 | 125;

