// Package tls is fastcord's TLS client: a thin binding over vendored BoringSSL (vendor/boringssl). It
// wraps a netio.Stream and exposes one. BoringSSL is configured the way Chrome configures it, so the
// ClientHello has the shape of the official Discord client's (Electron 42 / Chrome 148): GREASE,
// permuted extensions, ECH GREASE, X25519MLKEM768 + X25519 key shares, ALPS, brotli certificate
// compression, OCSP and SCT requests. Like Chrome it offers TLS 1.2 as well as 1.3.
//
// Certificates are checked by the OS trust store for the server name (trust_*.odin), never by
// BoringSSL's own verifier; verify_peer is the only place that decides.
package tls

import "base:intrinsics"
import "base:runtime"
import "core:c"
import "core:crypto/chacha20"
import "core:time"

import "fc:brotli"
import "fc:locks"
import "fc:netio"

Config :: struct {
	// ALPN protocols in preference order, e.g. {"h2", "http/1.1"}. ALPS is offered for "h2" over
	// TCP and "h3" over QUIC, as Chrome does.
	alpn:                 []string,
	// SNI and the name the certificate must be valid for.
	server_name:          string,
	// Tests only: accepts any certificate.
	insecure_skip_verify: bool,
}

// Error is the detailed failure reason; netio.Error is what the Stream reports.
Error :: enum u8 {
	None,
	Io,                    // The underlying stream failed.
	Closed,                // close_notify, EOF, or shutdown().
	Bad_Certificate,       // The OS could not parse a certificate (trust_*.odin only).
	Untrusted_Certificate, // The OS rejected the chain, or it is not valid for the server name.
	Protocol,              // BoringSSL failed the connection and sent the peer an alert.
	Internal,
}

// Odin dev-2026-10 miscompiles the AVX2 ChaCha20 in -debug builds on Windows: its round helper is not
// inlined, reads its stack arguments from the wrong slots and faults. Every ChaCha20 user in fastcord
// passes this implementation (tests/run_all.sh checks), so debug builds use the SSE one instead.
CHACHA20_IMPL :: chacha20.Implementation.Simd128 when ODIN_DEBUG else chacha20.DEFAULT_IMPLEMENTATION

// Chrome's TLS 1.2 suites, in its order.
CHROME_TLS12_CIPHERS :: "ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:ECDHE-RSA-AES128-SHA:ECDHE-RSA-AES256-SHA:AES128-GCM-SHA256:AES256-GCM-SHA384:AES128-SHA:AES256-SHA"
// BoringSSL puts AES first only when it detects AES hardware, which an OPENSSL_NO_ASM build never
// does; Chrome on any current machine sends this order.
@(private)
TLS13_CIPHERS := [?]u16{0x1301, 0x1302, 0x1303}
@(private)
GROUPS := [?]u16{0x11ec, 0x001d, 0x0017, 0x0018} // X25519MLKEM768, X25519, P-256, P-384.
// Chrome's signature algorithms; its QUIC hello adds rsa_pkcs1_sha1 (0x0201) at the end.
@(private)
SIGALGS := [?]u16{0x0403, 0x0804, 0x0401, 0x0503, 0x0805, 0x0501, 0x0806, 0x0601, 0x0201}

@(private)
host_index: c.int
@(private)
tcp_ctx: ^SSL_CTX

@(init, private)
init_tls :: proc "contextless" () {
	host_index = SSL_get_ex_new_index(0, nil, nil, nil, proc "c" (parent, ptr, ad: rawptr, index: c.int, argl: c.long, argp: rawptr) {
		OPENSSL_free(ptr)
	})
	tcp_ctx = new_ctx(false)
}

// new_ctx makes an SSL_CTX configured like Chrome's, for TLS over TCP or, with quic, for QUIC: TLS 1.3
// only, GREASE only in ECH, no OCSP or SCT requests. ngtcp2's BoringSSL backend takes a context from
// here, adds its QUIC method, and makes each connection's SSL with new_ssl. Returns nil on failure.
new_ctx :: proc "contextless" (quic: bool) -> ^SSL_CTX {
	ctx := SSL_CTX_new(TLS_method())
	if ctx == nil do return nil
	nsig := len(SIGALGS) if quic else len(SIGALGS) - 1
	ok :=
		SSL_CTX_set_min_proto_version(ctx, TLS1_3_VERSION if quic else TLS1_2_VERSION) == 1 &&
		SSL_CTX_set_max_proto_version(ctx, TLS1_3_VERSION) == 1 &&
		SSL_CTX_set1_tls13_ciphers(ctx, raw_data(TLS13_CIPHERS[:]), nil, len(TLS13_CIPHERS)) == 1 &&
		SSL_CTX_set_strict_cipher_list(ctx, CHROME_TLS12_CIPHERS) == 1 &&
		SSL_CTX_set1_group_ids(ctx, raw_data(GROUPS[:]), len(GROUPS)) == 1 &&
		SSL_CTX_set_verify_algorithm_prefs(ctx, raw_data(SIGALGS[:]), uint(nsig)) == 1 &&
		SSL_CTX_add_cert_compression_alg(ctx, 2, nil, decompress_brotli) == 1
	if !ok {
		SSL_CTX_free(ctx)
		return nil
	}
	SSL_CTX_set_grease_enabled(ctx, 0 if quic else 1)
	SSL_CTX_set_permute_extensions(ctx, 1)
	if !quic {
		SSL_CTX_enable_ocsp_stapling(ctx)
		SSL_CTX_enable_signed_cert_timestamps(ctx)
	}
	SSL_CTX_set_session_cache_mode(ctx, SSL_SESS_CACHE_CLIENT)
	SSL_CTX_sess_set_new_cb(ctx, new_session)
	SSL_CTX_set_custom_verify(ctx, SSL_VERIFY_PEER, verify_peer)
	return ctx
}

// new_ssl makes a client SSL on ctx (from new_ctx with the same quic) for cfg: SNI, ALPN, ALPS, ECH
// GREASE, a cached session to resume, and certificate checks for cfg.server_name. Returns nil on failure.
new_ssl :: proc(ctx: ^SSL_CTX, cfg: Config, quic: bool) -> ^SSL {
	// The SSL's host (ex_data) names the certificate's required name and keys the session cache.
	// Unverified test connections get a key no real host can have, so a real connection never resumes
	// a session whose certificate nobody checked.
	INSECURE :: "insecure "
	host: [len(INSECURE) + 256]byte
	if ctx == nil || cfg.server_name == "" || len(cfg.server_name) >= 256 do return nil
	at := copy(host[:], INSECURE) if cfg.insecure_skip_verify else 0
	copy(host[at:], cfg.server_name)
	hostc := cstring(raw_data(host[:]))
	ssl := SSL_new(ctx)
	if ssl == nil do return nil
	dup := OPENSSL_strdup(hostc)
	ok := dup != nil && SSL_set_ex_data(ssl, host_index, rawptr(dup)) == 1
	if dup != nil && !ok do OPENSSL_free(rawptr(dup))
	if !is_ip_literal(cfg.server_name) do ok = ok && SSL_set_tlsext_host_name(ssl, cstring(raw_data(host[at:]))) == 1
	protos: [512]byte
	n := 0
	for p in cfg.alpn {
		if len(p) == 0 || len(p) > 255 || n + 1 + len(p) > len(protos) {
			ok = false
			break
		}
		protos[n] = u8(len(p))
		copy(protos[n + 1:], p)
		n += 1 + len(p)
		if p == ("h3" if quic else "h2") do ok = ok && SSL_add_application_settings(ssl, raw_data(p), len(p), nil, 0) == 1
	}
	if n > 0 do ok = ok && SSL_set_alpn_protos(ssl, &protos[0], uint(n)) == 0
	SSL_set_alps_use_new_codepoint(ssl, 1)
	SSL_set_enable_ech_grease(ssl, 1)
	if quic do SSL_set_early_data_enabled(ssl, 1)
	if cfg.insecure_skip_verify do SSL_set_custom_verify(ssl, SSL_VERIFY_PEER, proc "c" (_: ^SSL, _: ^u8) -> c.int {return ssl_verify_ok})
	if sess := cache_take(string(hostc), quic); sess != nil {
		ok = ok && SSL_set_session(ssl, sess) == 1
		SSL_SESSION_free(sess)
	}
	SSL_set_connect_state(ssl)
	if !ok {
		SSL_free(ssl)
		return nil
	}
	return ssl
}

// is_ip_literal: Chrome sends no SNI for IP addresses.
@(private)
is_ip_literal :: proc(host: string) -> bool {
	for ch in host do if ch != ':' && ch != '.' && !(ch >= '0' && ch <= '9') do return false
	return true
}

@(private)
ssl_host :: proc "contextless" (ssl: ^SSL) -> string {
	return string(cstring(SSL_get_ex_data(ssl, host_index)))
}

// verify_peer accepts the peer only if the OS trusts its chain for the server name (trust_*.odin) and
// BoringSSL's X509_check_host also matches the leaf to that name. Every other path rejects.
@(private)
verify_peer :: proc "c" (ssl: ^SSL, out_alert: ^u8) -> c.int {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	host := ssl_host(ssl)
	certs := SSL_get0_peer_certificates(ssl)
	n := int(OPENSSL_sk_num(certs)) if certs != nil else 0
	chain: [16][]byte
	if host == "" || n == 0 || n > len(chain) do return ssl_verify_invalid
	for i in 0 ..< n {
		b := (^CRYPTO_BUFFER)(OPENSSL_sk_value(certs, uint(i)))
		chain[i] = CRYPTO_BUFFER_data(b)[:CRYPTO_BUFFER_len(b)]
	}
	p := raw_data(chain[0])
	leaf := d2i_X509(nil, &p, c.long(len(chain[0])))
	if leaf == nil do return ssl_verify_invalid
	name_ok := X509_check_host(leaf, raw_data(host), len(host), 0, nil) == 1
	X509_free(leaf)
	if !name_ok || verify_chain_cached(chain[:n], host) != .None do return ssl_verify_invalid
	return ssl_verify_ok
}

@(private)
decompress_brotli :: proc "c" (ssl: ^SSL, out: ^^CRYPTO_BUFFER, uncompressed_len: uint, data: [^]u8, data_len: uint) -> c.int {
	context = runtime.default_context()
	res, err := brotli.decompress(data[:data_len], context.allocator, int(uncompressed_len))
	defer delete(res)
	if err != .None || len(res) != int(uncompressed_len) do return 0
	out^ = CRYPTO_BUFFER_new(raw_data(res), len(res), nil)
	return 1 if out^ != nil else 0
}

// Session cache. Like Chrome, TLS 1.3 tickets are single-use: a connection takes the newest one for
// its host and the server's fresh tickets replace it. Indexed by [quic].
@(private)
MAX_SESSIONS_PER_HOST :: 4
@(private)
cache_mu: locks.Mutex
@(private)
cache: [2]map[string][dynamic]^SSL_SESSION

@(private)
new_session :: proc "c" (ssl: ^SSL, session: ^SSL_SESSION) -> c.int {
	context = runtime.default_context()
	host := ssl_host(ssl)
	if host == "" do return 0
	locks.lock(&cache_mu)
	defer locks.unlock(&cache_mu)
	m := &cache[SSL_is_quic(ssl)]
	if host not_in m^ do m^[clone(host)] = {}
	list := &m^[host]
	if len(list) == MAX_SESSIONS_PER_HOST {
		SSL_SESSION_free(list[0])
		ordered_remove(list, 0)
	}
	append(list, session)
	return 1
}

@(private)
clone :: proc(s: string) -> string {
	b := make([]byte, len(s))
	copy(b, s)
	return string(b)
}

@(private)
cache_take :: proc(host: string, quic: bool) -> ^SSL_SESSION {
	locks.lock(&cache_mu)
	defer locks.unlock(&cache_mu)
	if host not_in cache[int(quic)] do return nil
	list := &cache[int(quic)][host]
	return pop(list) if len(list) > 0 else nil
}

// Session is one TLS connection over a netio.Stream. One reader thread and one writer thread may use it
// at once. BoringSSL sees only memory BIOs: TLS records are queued in out under mu, in the order
// BoringSSL produced them, and written to the stream under wmu. Socket I/O never happens under mu, so
// a writer blocked on a full socket never stops the reader from draining the peer.
Session :: struct {
	ssl:        ^SSL,
	rbio, wbio: ^BIO,
	under:      netio.Stream,
	// mu guards ssl, out, failed and io_err. wmu owns sending; a thread may take mu while holding wmu,
	// never the reverse.
	mu, wmu:    locks.Mutex,
	out:        [dynamic]byte,
	sending:    [dynamic]byte,
	failed:     Error,
	io_err:     netio.Error,
	shut:       bool, // Atomic; shutdown() was called.
	allocator:  runtime.Allocator,
}

@(thread_local)
_last_error: Error

// last_error returns the detailed reason for the most recent connect failure on this thread.
last_error :: proc() -> Error {return _last_error}

// connect runs the TLS handshake over under. On success the Session owns under and closes it in
// close(). On failure under is left open.
connect :: proc(under: netio.Stream, cfg: Config, allocator := context.allocator) -> (^Session, netio.Error) {
	ssl := new_ssl(tcp_ctx, cfg, false)
	if ssl == nil {
		_last_error = .Internal
		return nil, .Tls
	}
	s := session_new(ssl, under, allocator)
	_last_error = handshake(s)
	if _last_error != .None {
		ne := to_netio(s, _last_error)
		destroy(s)
		return nil, ne
	}
	return s, .None
}

@(private)
session_new :: proc(ssl: ^SSL, under: netio.Stream, allocator: runtime.Allocator) -> ^Session {
	s := new(Session, allocator)
	s.ssl, s.under, s.allocator = ssl, under, allocator
	s.rbio, s.wbio = BIO_new(BIO_s_mem()), BIO_new(BIO_s_mem())
	s.out = make([dynamic]byte, allocator)
	s.sending = make([dynamic]byte, allocator)
	SSL_set_bio(ssl, s.rbio, s.wbio)
	return s
}

@(private)
handshake :: proc(s: ^Session) -> Error {
	for {
		locks.lock(&s.mu)
		ERR_clear_error()
		r := SSL_do_handshake(s.ssl)
		e := status_locked(s, r)
		locks.unlock(&s.mu)
		fe := flush(s)
		if r == 1 do return fe
		if e != .None do return e
		if fe != .None do return fe
		feed(s) or_return
	}
}

// status_locked queues BoringSSL's output and classifies the result of an SSL call; .None means
// success or "needs more input". The first failure sticks.
@(private)
status_locked :: proc(s: ^Session, r: c.int) -> Error {
	for {
		n := int(BIO_pending(s.wbio))
		if n == 0 do break
		old := len(s.out)
		resize(&s.out, old + n)
		resize(&s.out, old + max(int(BIO_read(s.wbio, &s.out[old], c.int(n))), 0))
	}
	if r > 0 || s.failed != .None do return s.failed
	switch SSL_get_error(s.ssl, r) {
	case SSL_ERROR_WANT_READ:
		return .None
	case SSL_ERROR_ZERO_RETURN:
		return .Closed
	}
	s.failed = .Untrusted_Certificate if ERR_peek_error() == ERR_CERTIFICATE_VERIFY_FAILED else .Protocol
	return s.failed
}

// feed reads once from the underlying stream, blocking without any lock held, into BoringSSL.
@(private)
feed :: proc(s: ^Session) -> Error {
	buf: [16 << 10]byte = ---
	n, ne := netio.read(s.under, buf[:])
	if ne != .None do return io_failed(s, ne)
	locks.lock(&s.mu)
	defer locks.unlock(&s.mu)
	if BIO_write(s.rbio, &buf[0], c.int(n)) != c.int(n) && s.failed == .None do s.failed = .Internal
	return s.failed
}

@(private)
io_failed :: proc(s: ^Session, ne: netio.Error) -> Error {
	if ne == .Closed || is_shut(s) do return .Closed
	locks.lock(&s.mu)
	defer locks.unlock(&s.mu)
	if s.failed == .None {
		s.failed = .Io
		s.io_err = ne
	}
	return .Io
}

// flush writes the queued records. With block = false, a thread that finds another one writing leaves
// its records to that writer, which checks the queue again after letting go of wmu.
@(private)
flush :: proc(s: ^Session, block := true) -> Error {
	for {
		if block {
			locks.lock(&s.wmu)
		} else if !locks.try_lock(&s.wmu) {
			return .None
		}
		e := Error.None
		for e == .None {
			locks.lock(&s.mu)
			s.out, s.sending = s.sending, s.out
			clear(&s.out)
			locks.unlock(&s.mu)
			if len(s.sending) == 0 do break
			if ne := netio.write(s.under, s.sending[:]); ne != .None do e = io_failed(s, ne)
		}
		locks.unlock(&s.wmu)
		if e != .None do return e
		locks.lock(&s.mu)
		more := len(s.out) > 0
		locks.unlock(&s.mu)
		if !more do return .None
	}
}

stream :: proc(s: ^Session) -> netio.Stream {
	return netio.Stream{data = s, read = stream_read, write = stream_write, close = stream_close, shutdown = stream_shutdown, set_timeout = stream_set_timeout}
}

// negotiated_alpn returns the protocol the server selected, or "". Valid until close.
negotiated_alpn :: proc(s: ^Session) -> string {
	p: [^]u8
	n: u32
	SSL_get0_alpn_selected(s.ssl, &p, &n)
	return string(p[:n])
}

// negotiated_group returns the key exchange group codepoint, e.g. 0x11ec.
negotiated_group :: proc(s: ^Session) -> u16 {return SSL_get_group_id(s.ssl)}

// negotiated_suite returns the cipher suite codepoint, e.g. 0x1301.
negotiated_suite :: proc(s: ^Session) -> u16 {return SSL_CIPHER_get_protocol_id(SSL_get_current_cipher(s.ssl))}

// resumed reports whether the session was resumed from a cached ticket.
resumed :: proc(s: ^Session) -> bool {return SSL_session_reused(s.ssl) == 1}

// read returns at least one byte of application data, blocking as needed.
read :: proc(s: ^Session, dst: []byte) -> (n: int, err: Error) {
	if len(dst) == 0 do return 0, .None
	for {
		if is_shut(s) do return 0, .Closed
		locks.lock(&s.mu)
		ERR_clear_error()
		r := SSL_read(s.ssl, raw_data(dst), c.int(min(len(dst), 1 << 30)))
		e := status_locked(s, r)
		locks.unlock(&s.mu)
		flush(s, block = false)
		if r > 0 do return int(r), .None
		if e != .None do return 0, e
		feed(s) or_return
	}
}

// write sends all of src as application data.
write :: proc(s: ^Session, src: []byte) -> Error {
	if is_shut(s) do return .Closed
	locks.lock(&s.mu)
	e := s.failed
	rest := src
	for e == .None && len(rest) > 0 {
		n := min(len(rest), 1 << 30)
		ERR_clear_error()
		r := SSL_write(s.ssl, raw_data(rest), c.int(n))
		e = status_locked(s, r)
		if e == .None && int(r) != n do e = s.failed if s.failed != .None else .Internal
		rest = rest[n:]
	}
	locks.unlock(&s.mu)
	if e != .None do return e
	return flush(s)
}

// key_update rotates our write keys and asks the peer to rotate its own (RFC 8446 4.6.3).
key_update :: proc(s: ^Session) -> Error {
	locks.lock(&s.mu)
	e := s.failed
	if e == .None && SSL_key_update(s.ssl, SSL_KEY_UPDATE_REQUESTED) != 1 do e = .Internal
	status_locked(s, 1)
	locks.unlock(&s.mu)
	if e != .None do return e
	return flush(s)
}

// shutdown wakes a thread blocked in read (it returns .Closed) and makes later reads and writes fail,
// without freeing anything. It forwards to the underlying stream and is safe from any thread. close()
// is still required afterwards, once the other threads have returned.
shutdown :: proc(s: ^Session) {
	intrinsics.atomic_store(&s.shut, true)
	netio.shutdown(s.under)
}

@(private)
is_shut :: proc(s: ^Session) -> bool {return intrinsics.atomic_load(&s.shut)}

// close sends close_notify, closes the underlying stream and frees the session.
close :: proc(s: ^Session) {
	if s == nil do return
	if !is_shut(s) {
		locks.lock(&s.mu)
		if s.failed == .None {
			ERR_clear_error()
			SSL_shutdown(s.ssl)
			status_locked(s, 1)
		}
		locks.unlock(&s.mu)
		flush(s)
	}
	netio.close(s.under)
	destroy(s)
}

@(private)
destroy :: proc(s: ^Session) {
	SSL_free(s.ssl)
	delete(s.out)
	delete(s.sending)
	free(s, s.allocator)
}

@(private)
to_netio :: proc(s: ^Session, e: Error) -> netio.Error {
	#partial switch e {
	case .None:
		return .None
	case .Closed:
		return .Closed
	case .Io:
		return s.io_err if s.io_err != .None else .Io
	}
	return .Tls
}

@(private)
stream_read :: proc(data: rawptr, dst: []byte) -> (int, netio.Error) {
	s := cast(^Session)data
	n, e := read(s, dst)
	return n, to_netio(s, e)
}

@(private)
stream_write :: proc(data: rawptr, src: []byte) -> netio.Error {
	s := cast(^Session)data
	return to_netio(s, write(s, src))
}

@(private)
stream_close :: proc(data: rawptr) {close(cast(^Session)data)}

@(private)
stream_shutdown :: proc(data: rawptr) {shutdown(cast(^Session)data)}

@(private)
stream_set_timeout :: proc(data: rawptr, d: time.Duration) {netio.set_timeout((cast(^Session)data).under, d)}
