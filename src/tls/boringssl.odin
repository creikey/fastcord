package tls

import "core:c"

// vendor/boringssl, built by build.sh / build.bat into a static library. Its libssl is C++ built
// without exceptions or RTTI; MSVC's CRT and macOS's libc++ supply the few runtime symbols it needs.
when ODIN_OS == .Windows {
	foreign import bssl "../../build/fc_boringssl.lib"
} else {
	foreign import bssl {"../../build/libfc_boringssl.a", "system:c++"}
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

TLS1_2_VERSION :: 0x0303
TLS1_3_VERSION :: 0x0304
SSL_ERROR_WANT_READ :: 2
SSL_ERROR_ZERO_RETURN :: 6
SSL_VERIFY_PEER :: 1
SSL_SESS_CACHE_CLIENT :: 1
SSL_KEY_UPDATE_REQUESTED :: 1
ssl_verify_ok :: 0
ssl_verify_invalid :: 1

Verify_Callback :: #type proc "c" (ssl: ^SSL, out_alert: ^u8) -> c.int
Decompress_Callback :: #type proc "c" (ssl: ^SSL, out: ^^CRYPTO_BUFFER, uncompressed_len: uint, data: [^]u8, data_len: uint) -> c.int
New_Session_Callback :: #type proc "c" (ssl: ^SSL, session: ^SSL_SESSION) -> c.int
Ex_Free_Callback :: #type proc "c" (parent, ptr: rawptr, ad: rawptr, index: c.int, argl: c.long, argp: rawptr)

@(default_calling_convention = "c")
foreign bssl {
	TLS_method :: proc() -> ^SSL_METHOD ---
	SSL_CTX_new :: proc(method: ^SSL_METHOD) -> ^SSL_CTX ---
	SSL_CTX_free :: proc(ctx: ^SSL_CTX) ---
	SSL_CTX_set_min_proto_version :: proc(ctx: ^SSL_CTX, version: u16) -> c.int ---
	SSL_CTX_set_max_proto_version :: proc(ctx: ^SSL_CTX, version: u16) -> c.int ---
	SSL_CTX_set1_tls13_ciphers :: proc(ctx: ^SSL_CTX, ids: [^]u16, flags: [^]u32, n: uint) -> c.int ---
	SSL_CTX_set_strict_cipher_list :: proc(ctx: ^SSL_CTX, str: cstring) -> c.int ---
	SSL_CTX_set1_group_ids :: proc(ctx: ^SSL_CTX, ids: [^]u16, n: uint) -> c.int ---
	SSL_CTX_set_verify_algorithm_prefs :: proc(ctx: ^SSL_CTX, prefs: [^]u16, n: uint) -> c.int ---
	SSL_CTX_add_cert_compression_alg :: proc(ctx: ^SSL_CTX, alg: u16, compress: rawptr, decompress: Decompress_Callback) -> c.int ---
	SSL_CTX_set_grease_enabled :: proc(ctx: ^SSL_CTX, enabled: c.int) ---
	SSL_CTX_set_permute_extensions :: proc(ctx: ^SSL_CTX, enabled: c.int) ---
	SSL_CTX_enable_ocsp_stapling :: proc(ctx: ^SSL_CTX) ---
	SSL_CTX_enable_signed_cert_timestamps :: proc(ctx: ^SSL_CTX) ---
	SSL_CTX_set_session_cache_mode :: proc(ctx: ^SSL_CTX, mode: c.int) -> c.int ---
	SSL_CTX_sess_set_new_cb :: proc(ctx: ^SSL_CTX, cb: New_Session_Callback) ---
	SSL_CTX_set_custom_verify :: proc(ctx: ^SSL_CTX, mode: c.int, cb: Verify_Callback) ---

	SSL_new :: proc(ctx: ^SSL_CTX) -> ^SSL ---
	SSL_free :: proc(ssl: ^SSL) ---
	SSL_set_connect_state :: proc(ssl: ^SSL) ---
	SSL_set_bio :: proc(ssl: ^SSL, rbio, wbio: ^BIO) ---
	SSL_set_tlsext_host_name :: proc(ssl: ^SSL, name: cstring) -> c.int ---
	SSL_set_alpn_protos :: proc(ssl: ^SSL, protos: [^]u8, n: uint) -> c.int ---
	SSL_add_application_settings :: proc(ssl: ^SSL, proto: [^]u8, proto_len: uint, settings: [^]u8, settings_len: uint) -> c.int ---
	SSL_set_alps_use_new_codepoint :: proc(ssl: ^SSL, use_new: c.int) ---
	SSL_set_enable_ech_grease :: proc(ssl: ^SSL, enable: c.int) ---
	SSL_set_early_data_enabled :: proc(ssl: ^SSL, enabled: c.int) ---
	SSL_set_custom_verify :: proc(ssl: ^SSL, mode: c.int, cb: Verify_Callback) ---
	SSL_set_session :: proc(ssl: ^SSL, session: ^SSL_SESSION) -> c.int ---
	SSL_SESSION_free :: proc(session: ^SSL_SESSION) ---
	SSL_get_ex_new_index :: proc(argl: c.long, argp: rawptr, unused: rawptr, dup: rawptr, free_func: Ex_Free_Callback) -> c.int ---
	SSL_set_ex_data :: proc(ssl: ^SSL, idx: c.int, data: rawptr) -> c.int ---
	SSL_get_ex_data :: proc(ssl: ^SSL, idx: c.int) -> rawptr ---
	SSL_is_quic :: proc(ssl: ^SSL) -> c.int ---

	SSL_do_handshake :: proc(ssl: ^SSL) -> c.int ---
	SSL_read :: proc(ssl: ^SSL, buf: rawptr, n: c.int) -> c.int ---
	SSL_write :: proc(ssl: ^SSL, buf: rawptr, n: c.int) -> c.int ---
	SSL_shutdown :: proc(ssl: ^SSL) -> c.int ---
	SSL_key_update :: proc(ssl: ^SSL, request_type: c.int) -> c.int ---
	SSL_get_error :: proc(ssl: ^SSL, ret: c.int) -> c.int ---
	SSL_get0_alpn_selected :: proc(ssl: ^SSL, data: ^[^]u8, n: ^u32) ---
	SSL_get_group_id :: proc(ssl: ^SSL) -> u16 ---
	SSL_get_current_cipher :: proc(ssl: ^SSL) -> ^SSL_CIPHER ---
	SSL_CIPHER_get_protocol_id :: proc(cipher: ^SSL_CIPHER) -> u16 ---
	SSL_session_reused :: proc(ssl: ^SSL) -> c.int ---
	SSL_get0_peer_certificates :: proc(ssl: ^SSL) -> ^OPENSSL_STACK ---

	BIO_new :: proc(method: ^BIO_METHOD) -> ^BIO ---
	BIO_s_mem :: proc() -> ^BIO_METHOD ---
	BIO_read :: proc(bio: ^BIO, data: rawptr, n: c.int) -> c.int ---
	BIO_write :: proc(bio: ^BIO, data: rawptr, n: c.int) -> c.int ---
	BIO_pending :: proc(bio: ^BIO) -> uint ---

	OPENSSL_sk_num :: proc(sk: ^OPENSSL_STACK) -> uint ---
	OPENSSL_sk_value :: proc(sk: ^OPENSSL_STACK, i: uint) -> rawptr ---
	CRYPTO_BUFFER_new :: proc(data: [^]u8, n: uint, pool: rawptr) -> ^CRYPTO_BUFFER ---
	CRYPTO_BUFFER_data :: proc(buf: ^CRYPTO_BUFFER) -> [^]u8 ---
	CRYPTO_BUFFER_len :: proc(buf: ^CRYPTO_BUFFER) -> uint ---
	d2i_X509 :: proc(out: ^^X509, inp: ^[^]u8, n: c.long) -> ^X509 ---
	X509_check_host :: proc(x: ^X509, name: [^]u8, name_len: uint, flags: c.uint, peername: rawptr) -> c.int ---
	X509_free :: proc(x: ^X509) ---
	OPENSSL_strdup :: proc(s: cstring) -> cstring ---
	OPENSSL_free :: proc(p: rawptr) ---
	ERR_clear_error :: proc() ---
	ERR_peek_error :: proc() -> u32 ---
}

// ERR_PACK(ERR_LIB_SSL, SSL_R_CERTIFICATE_VERIFY_FAILED): what a rejected certificate leaves first
// on the thread's error queue.
ERR_CERTIFICATE_VERIFY_FAILED :: 16 << 24 | 125
