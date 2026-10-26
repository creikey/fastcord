package tls

import "base:runtime"
import "core:c"
import "core:thread"

import "fc:locks"
import "fc:netio"

// Test support: in-memory pipes, a BoringSSL server with a throwaway self-signed certificate, and a
// QUIC handshake shuttle between two SSLs.

when ODIN_OS == .Windows {
	foreign import bssl_test "../../build/fc_boringssl.lib"
} else {
	foreign import bssl_test {"../../build/libfc_boringssl.a", "system:c++"}
}

@(private = "file")
EVP_PKEY :: struct {}
@(private = "file")
EC_KEY :: struct {}
@(private = "file")
X509_NAME :: struct {}
@(private = "file")
ASN1_TIME :: struct {}
@(private = "file")
EVP_MD :: struct {}

Quic_Method :: struct {
	set_read_secret:    proc "c" (ssl: ^SSL, level: c.int, cipher: ^SSL_CIPHER, secret: [^]u8, n: uint) -> c.int,
	set_write_secret:   proc "c" (ssl: ^SSL, level: c.int, cipher: ^SSL_CIPHER, secret: [^]u8, n: uint) -> c.int,
	add_handshake_data: proc "c" (ssl: ^SSL, level: c.int, data: [^]u8, n: uint) -> c.int,
	flush_flight:       proc "c" (ssl: ^SSL) -> c.int,
	send_alert:         proc "c" (ssl: ^SSL, level: c.int, alert: u8) -> c.int,
}

@(default_calling_convention = "c")
foreign bssl_test {
	SSL_set_accept_state :: proc(ssl: ^SSL) ---
	SSL_in_init :: proc(ssl: ^SSL) -> c.int ---
	SSL_CTX_use_certificate :: proc(ctx: ^SSL_CTX, x: ^X509) -> c.int ---
	SSL_CTX_use_PrivateKey :: proc(ctx: ^SSL_CTX, pkey: ^EVP_PKEY) -> c.int ---
	SSL_CTX_set_alpn_select_cb :: proc(ctx: ^SSL_CTX, cb: proc "c" (ssl: ^SSL, out: ^[^]u8, out_len: ^u8, data: [^]u8, n: c.uint, arg: rawptr) -> c.int, arg: rawptr) ---
	SSL_CTX_set_early_data_enabled :: proc(ctx: ^SSL_CTX, enabled: c.int) ---
	SSL_set_quic_method :: proc(ssl: ^SSL, method: ^Quic_Method) -> c.int ---
	SSL_set_quic_transport_params :: proc(ssl: ^SSL, params: [^]u8, n: uint) -> c.int ---
	SSL_set_quic_early_data_context :: proc(ssl: ^SSL, data: [^]u8, n: uint) -> c.int ---
	SSL_provide_quic_data :: proc(ssl: ^SSL, level: c.int, data: [^]u8, n: uint) -> c.int ---
	SSL_process_quic_post_handshake :: proc(ssl: ^SSL) -> c.int ---
	EC_KEY_new_by_curve_name :: proc(nid: c.int) -> ^EC_KEY ---
	EC_KEY_generate_key :: proc(key: ^EC_KEY) -> c.int ---
	EVP_PKEY_new :: proc() -> ^EVP_PKEY ---
	EVP_PKEY_assign_EC_KEY :: proc(pkey: ^EVP_PKEY, key: ^EC_KEY) -> c.int ---
	EVP_PKEY_free :: proc(pkey: ^EVP_PKEY) ---
	EVP_sha256 :: proc() -> ^EVP_MD ---
	X509_new :: proc() -> ^X509 ---
	X509_set_version :: proc(x: ^X509, version: c.long) -> c.int ---
	X509_getm_notBefore :: proc(x: ^X509) -> ^ASN1_TIME ---
	X509_getm_notAfter :: proc(x: ^X509) -> ^ASN1_TIME ---
	X509_gmtime_adj :: proc(t: ^ASN1_TIME, offset: c.long) -> ^ASN1_TIME ---
	X509_get_subject_name :: proc(x: ^X509) -> ^X509_NAME ---
	X509_NAME_add_entry_by_txt :: proc(name: ^X509_NAME, field: cstring, type: c.int, bytes: cstring, n: int, loc, set: c.int) -> c.int ---
	X509_set_issuer_name :: proc(x: ^X509, name: ^X509_NAME) -> c.int ---
	X509_set_pubkey :: proc(x: ^X509, pkey: ^EVP_PKEY) -> c.int ---
	X509_sign :: proc(x: ^X509, pkey: ^EVP_PKEY, md: ^EVP_MD) -> c.int ---
}

// test_server_ctx makes a server context with a fresh self-signed P-256 certificate for "localhost".
test_server_ctx :: proc(quic := false) -> ^SSL_CTX {
	key := EC_KEY_new_by_curve_name(415) // NID_X9_62_prime256v1
	assert(EC_KEY_generate_key(key) == 1)
	pkey := EVP_PKEY_new()
	assert(EVP_PKEY_assign_EC_KEY(pkey, key) == 1)
	defer EVP_PKEY_free(pkey)
	x := X509_new()
	defer X509_free(x)
	name := X509_get_subject_name(x)
	ok :=
		X509_set_version(x, 2) == 1 &&
		X509_gmtime_adj(X509_getm_notBefore(x), -3600) != nil &&
		X509_gmtime_adj(X509_getm_notAfter(x), 3600) != nil &&
		X509_NAME_add_entry_by_txt(name, "CN", 0x1001, "localhost", -1, -1, 0) == 1 && // MBSTRING_ASC
		X509_set_issuer_name(x, name) == 1 &&
		X509_set_pubkey(x, pkey) == 1 &&
		X509_sign(x, pkey, EVP_sha256()) > 0
	assert(ok)
	ctx := SSL_CTX_new(TLS_method())
	assert(SSL_CTX_use_certificate(ctx, x) == 1 && SSL_CTX_use_PrivateKey(ctx, pkey) == 1)
	SSL_CTX_set_alpn_select_cb(ctx, proc "c" (_: ^SSL, out: ^[^]u8, out_len: ^u8, data: [^]u8, n: c.uint, _: rawptr) -> c.int {
		out^, out_len^ = data[1:], data[0] // The client's first protocol.
		return 0 // SSL_TLSEXT_ERR_OK
	}, nil)
	if quic {
		assert(SSL_CTX_set_min_proto_version(ctx, TLS1_3_VERSION) == 1)
		SSL_CTX_set_early_data_enabled(ctx, 1)
	}
	return ctx
}

// Test_Pipe is one direction of a blocking in-memory byte pipe.
Test_Pipe :: struct {
	mu:     locks.Mutex,
	cond:   locks.Cond,
	buf:    [dynamic]byte,
	closed: bool,
}

Test_End :: struct {
	rx, tx: ^Test_Pipe,
}

pipe_stream :: proc(e: ^Test_End) -> netio.Stream {
	return {data = e, read = end_read, write = end_write, close = end_close, shutdown = end_close}
}

@(private = "file")
end_read :: proc(data: rawptr, dst: []byte) -> (int, netio.Error) {
	p := (cast(^Test_End)data).rx
	locks.lock(&p.mu)
	defer locks.unlock(&p.mu)
	for len(p.buf) == 0 && !p.closed do locks.cond_wait(&p.cond, &p.mu)
	if len(p.buf) == 0 do return 0, .Closed
	n := copy(dst, p.buf[:])
	remove_range(&p.buf, 0, n)
	return n, .None
}

@(private = "file")
end_write :: proc(data: rawptr, src: []byte) -> netio.Error {
	p := (cast(^Test_End)data).tx
	locks.lock(&p.mu)
	defer locks.unlock(&p.mu)
	if p.closed do return .Closed
	append(&p.buf, ..src)
	locks.cond_broadcast(&p.cond)
	return .None
}

end_close :: proc(data: rawptr) {
	e := cast(^Test_End)data
	for p in ([]^Test_Pipe{e.rx, e.tx}) {
		locks.lock(&p.mu)
		p.closed = true
		locks.cond_broadcast(&p.cond)
		locks.unlock(&p.mu)
	}
}

// Loopback is a client Session connected over pipes to a BoringSSL server Session.
Loopback :: struct {
	ab, ba:     Test_Pipe,
	ea, eb:     Test_End,
	ctx:        ^SSL_CTX,
	server:     ^Session,
	server_err: Error,
}

loopback_connect :: proc(lb: ^Loopback, cfg: Config) -> (^Session, netio.Error) {
	lb.ea = {rx = &lb.ba, tx = &lb.ab}
	lb.eb = {rx = &lb.ab, tx = &lb.ba}
	lb.ctx = test_server_ctx()
	ssl := SSL_new(lb.ctx)
	SSL_set_accept_state(ssl)
	lb.server = session_new(ssl, pipe_stream(&lb.eb), context.allocator)
	th := thread.create_and_start_with_poly_data(lb, proc(lb: ^Loopback) {lb.server_err = handshake(lb.server)})
	s, err := connect(pipe_stream(&lb.ea), cfg)
	if err != .None do end_close(&lb.ea)
	thread.join(th)
	thread.destroy(th)
	return s, err
}

// loopback_destroy frees the server side; the client Session is closed by the test.
loopback_destroy :: proc(lb: ^Loopback) {
	end_close(&lb.eb)
	destroy(lb.server)
	SSL_CTX_free(lb.ctx)
	delete(lb.ab.buf)
	delete(lb.ba.buf)
}

// Quic_Box collects what one SSL sent, per encryption level.
Quic_Box :: struct {
	level: [4][dynamic]byte,
}

@(private = "file")
quic_boxes: map[^SSL]^Quic_Box

QUIC_CAPTURE := Quic_Method {
	set_read_secret = proc "c" (_: ^SSL, _: c.int, _: ^SSL_CIPHER, _: [^]u8, _: uint) -> c.int {return 1},
	set_write_secret = proc "c" (_: ^SSL, _: c.int, _: ^SSL_CIPHER, _: [^]u8, _: uint) -> c.int {return 1},
	add_handshake_data = proc "c" (ssl: ^SSL, level: c.int, data: [^]u8, n: uint) -> c.int {
		context = runtime.default_context()
		append(&quic_boxes[ssl].level[level], ..data[:n])
		return 1
	},
	flush_flight = proc "c" (_: ^SSL) -> c.int {return 1},
	send_alert = proc "c" (_: ^SSL, _: c.int, _: u8) -> c.int {return 1},
}

// quic_attach routes ssl's handshake output into box; single-threaded tests only.
quic_attach :: proc(ssl: ^SSL, box: ^Quic_Box, params: []byte) {
	quic_boxes[ssl] = box
	assert(SSL_set_quic_method(ssl, &QUIC_CAPTURE) == 1)
	assert(SSL_set_quic_transport_params(ssl, raw_data(params), len(params)) == 1)
}

quic_detach :: proc(ssl: ^SSL, box: ^Quic_Box) {
	delete_key(&quic_boxes, ssl)
	for &l in box.level do delete(l)
	if len(quic_boxes) == 0 do delete(quic_boxes)
}

// quic_deliver hands everything from sent over to ssl, one level at a time, letting ssl process each
// level before the next (BoringSSL rejects data for a level it has no keys for yet).
quic_deliver :: proc(sent: ^Quic_Box, ssl: ^SSL) -> bool {
	for &l, level in sent.level {
		if len(l) == 0 do continue
		if SSL_provide_quic_data(ssl, c.int(level), raw_data(l), len(l)) != 1 do return false
		clear(&l)
		if SSL_in_init(ssl) == 1 {
			SSL_do_handshake(ssl)
		} else if SSL_process_quic_post_handshake(ssl) != 1 {
			return false
		}
	}
	return true
}
