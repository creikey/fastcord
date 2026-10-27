Config :: struct {
	// ALPN protocols in preference order, e.g. {"h2", "http/1.1"}. ALPS is offered for "h2" over
	// TCP and "h3" over QUIC, as Chrome does.
	alpn: []string;
	// SNI and the name the certificate must be valid for.
	server_name: string;
	// Tests only: accepts any certificate.
	insecure_skip_verify: bool;
}

// Error is the detailed failure reason; netio.Error is what the Stream reports.
Error :: enum u8 {
	None;
	Io;                    // The underlying stream failed.
	Closed;                // close_notify, EOF, or shutdown().
	Bad_Certificate;       // The OS could not parse a certificate (trust_*.odin only).
	Untrusted_Certificate; // The OS rejected the chain, or it is not valid for the server name.
	Protocol;              // BoringSSL failed the connection and sent the peer an alert.
	Internal;
}

// Odin dev-2026-10 miscompiles the AVX2 ChaCha20 in -debug builds on Windows: its round helper is not
// inlined, reads its stack arguments from the wrong slots and faults. Every ChaCha20 user in fastcord
// passes this implementation (tests/run_all.sh checks), so debug builds use the SSE one instead.
CHACHA20_IMPL :: ifx DEBUG then chacha20.Implementation.Simd128 else chacha20.DEFAULT_IMPLEMENTATION;

// Chrome's TLS 1.2 suites, in its order.
CHROME_TLS12_CIPHERS :: "ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:ECDHE-RSA-AES128-SHA:ECDHE-RSA-AES256-SHA:AES128-GCM-SHA256:AES256-GCM-SHA384:AES128-SHA:AES256-SHA";
#scope_module
// BoringSSL puts AES first only when it detects AES hardware, which an OPENSSL_NO_ASM build never
// does; Chrome on any current machine sends this order.
// BoringSSL puts AES first only when it detects AES hardware, which an OPENSSL_NO_ASM build never
// does; Chrome on any current machine sends this order.
TLS13_CIPHERS := u16.[0x1301, 0x1302, 0x1303];
GROUPS := u16.[0x11ec, 0x001d, 0x0017, 0x0018];
#scope_export
#scope_module // X25519MLKEM768, X25519, P-256, P-384.
// Chrome's signature algorithms; its QUIC hello adds rsa_pkcs1_sha1 (0x0201) at the end.
// X25519MLKEM768, X25519, P-256, P-384.
// Chrome's signature algorithms; its QUIC hello adds rsa_pkcs1_sha1 (0x0201) at the end.
SIGALGS := u16.[0x0403, 0x0804, 0x0401, 0x0503, 0x0805, 0x0501, 0x0806, 0x0601, 0x0201];
#scope_module

host_index: s32;
tcp_ctx: *SSL_CTX;
#scope_export

init_tls :: () #no_context {
	host_index = SSL_get_ex_new_index(0, null, null, null, (parent: *void, ptr: *void, ad: *void, index: s32, argl: s64, argp: *void) #c_call {
		OPENSSL_free(ptr);
	});
	tcp_ctx = new_ctx(false);
}

// new_ctx makes an SSL_CTX configured like Chrome's, for TLS over TCP or, with quic, for QUIC: TLS 1.3
// only, GREASE only in ECH, no OCSP or SCT requests. ngtcp2's BoringSSL backend takes a context from
// here, adds its QUIC method, and makes each connection's SSL with new_ssl. Returns nil on failure.
new_ctx :: (quic: bool) -> *SSL_CTX #no_context {
	ctx := SSL_CTX_new(TLS_method());
	if ctx == null { return null; }
	nsig := ifx quic then len(SIGALGS) else len(SIGALGS) - 1;
	ok :=
		SSL_CTX_set_min_proto_version(ctx, ifx quic then TLS1_3_VERSION else TLS1_2_VERSION) == 1 &&
		SSL_CTX_set_max_proto_version(ctx, TLS1_3_VERSION) == 1 &&
		SSL_CTX_set1_tls13_ciphers(ctx, raw_data(view(TLS13_CIPHERS)), null, len(TLS13_CIPHERS)) == 1 &&
		SSL_CTX_set_strict_cipher_list(ctx, CHROME_TLS12_CIPHERS) == 1 &&
		SSL_CTX_set1_group_ids(ctx, raw_data(view(GROUPS)), len(GROUPS)) == 1 &&
		SSL_CTX_set_verify_algorithm_prefs(ctx, raw_data(view(SIGALGS)), cast(u64)(nsig)) == 1 &&
		SSL_CTX_add_cert_compression_alg(ctx, 2, null, decompress_brotli) == 1;
	if !ok {
		SSL_CTX_free(ctx);
		return null;
	}
	SSL_CTX_set_grease_enabled(ctx, ifx quic then 0 else 1);
	SSL_CTX_set_permute_extensions(ctx, 1);
	if !quic {
		SSL_CTX_enable_ocsp_stapling(ctx);
		SSL_CTX_enable_signed_cert_timestamps(ctx);
	}
	SSL_CTX_set_session_cache_mode(ctx, SSL_SESS_CACHE_CLIENT);
	SSL_CTX_sess_set_new_cb(ctx, new_session);
	SSL_CTX_set_custom_verify(ctx, SSL_VERIFY_PEER, verify_peer);
	return ctx;
}

// new_ssl makes a client SSL on ctx (from new_ctx with the same quic) for cfg: SNI, ALPN, ALPS, ECH
// GREASE, a cached session to resume, and certificate checks for cfg.server_name. Returns nil on failure.
new_ssl :: (ctx: *SSL_CTX, cfg: Config, quic: bool) -> *SSL {
	// The SSL's host (ex_data) names the certificate's required name and keys the session cache.
	// Unverified test connections get a key no real host can have, so a real connection never resumes
	// a session whose certificate nobody checked.
	INSECURE :: "insecure ";
	host: [len(INSECURE) + 256]u8;
	if ctx == null || cfg.server_name == "" || len(cfg.server_name) >= 256 { return null; }
	at := ifx cfg.insecure_skip_verify then copy(view(host), INSECURE) else 0;
	copy(sub_from(host, at), cfg.server_name);
	hostc := to_cstring(raw_data(view(host)));
	ssl := SSL_new(ctx);
	if ssl == null { return null; }
	dup := OPENSSL_strdup(hostc);
	ok := dup != null && SSL_set_ex_data(ssl, host_index, cast(*void)(dup)) == 1;
	if dup != null && !ok { OPENSSL_free(cast(*void)(dup)); }
	if !is_ip_literal(cfg.server_name) { ok = ok && SSL_set_tlsext_host_name(ssl, to_cstring(raw_data(sub_from(host, at)))) == 1; }
	protos: [512]u8;
	n := 0;
	for p: cfg.alpn {
		if len(p) == 0 || len(p) > 255 || n + 1 + len(p) > len(protos) {
			ok = false;
			break;
		}
		protos[n] = cast(u8)(len(p));
		copy(sub_from(protos, n + 1), p);
		n += 1 + len(p);
		if p == (ifx quic then "h3" else "h2") { ok = ok && SSL_add_application_settings(ssl, raw_data(p), len(p), null, 0) == 1; }
	}
	if n > 0 { ok = ok && SSL_set_alpn_protos(ssl, *protos[0], cast(u64)(n)) == 0; }
	SSL_set_alps_use_new_codepoint(ssl, 1);
	SSL_set_enable_ech_grease(ssl, 1);
	if quic { SSL_set_early_data_enabled(ssl, 1); }
	if cfg.insecure_skip_verify { SSL_set_custom_verify(ssl, SSL_VERIFY_PEER, (_: *SSL, _: *u8) -> s32 #c_call {return ssl_verify_ok;}); }
	{ sess := cache_take(as_string(hostc), quic);
	if sess != null {
		ok = ok && SSL_set_session(ssl, sess) == 1;
		SSL_SESSION_free(sess);
	} }
	SSL_set_connect_state(ssl);
	if !ok {
		SSL_free(ssl);
		return null;
	}
	return ssl;
}
#scope_module

// is_ip_literal: Chrome sends no SNI for IP addresses.
is_ip_literal :: (host: string) -> bool {
	for ch: host { if ch != #char ":" && ch != #char "." && !(ch >= #char "0" && ch <= #char "9") { return false; } }
	return true;
}

ssl_host :: (ssl: *SSL) -> string #no_context {
	return as_string(to_cstring(SSL_get_ex_data(ssl, host_index)));
}

// verify_peer accepts the peer only if the OS trusts its chain for the server name (trust_*.odin) and
// BoringSSL's X509_check_host also matches the leaf to that name. Every other path rejects.
verify_peer :: (ssl: *SSL, out_alert: *u8) -> s32 #c_call {
	__ctx1: #Context; push_context,defer_pop __ctx1;
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD();
	host := ssl_host(ssl);
	certs := SSL_get0_peer_certificates(ssl);
	n := ifx certs != null then cast(int)(OPENSSL_sk_num(certs)) else 0;
	chain: [16][]u8;
	if host == "" || n == 0 || n > len(chain) { return ssl_verify_invalid; }
	for i: 0..n-1 {
		b := cast(*CRYPTO_BUFFER)(OPENSSL_sk_value(certs, cast(u64)(i)));
		chain[i] = sub(CRYPTO_BUFFER_data(b), 0, CRYPTO_BUFFER_len(b));
	}
	p := raw_data(chain[0]);
	leaf := d2i_X509(null, *p, cast(s64)(len(chain[0])));
	if leaf == null { return ssl_verify_invalid; }
	name_ok := X509_check_host(leaf, raw_data(host), len(host), 0, null) == 1;
	X509_free(leaf);
	if !name_ok || verify_chain_cached(sub(chain, 0, n), host) != .None { return ssl_verify_invalid; }
	return ssl_verify_ok;
}

decompress_brotli :: (ssl: *SSL, out: **CRYPTO_BUFFER, uncompressed_len: u64, data: *u8, data_len: u64) -> s32 #c_call {
	__ctx2: #Context; push_context,defer_pop __ctx2;
	res, err := brotli.decompress(sub(data, 0, data_len), context.allocator, cast(int)(uncompressed_len));
	defer delete(res);
	if err != .None || len(res) != cast(int)(uncompressed_len) { return 0; }
	out.* = CRYPTO_BUFFER_new(raw_data(res), len(res), null);
	return ifx out.* != null then 1 else 0;
}

// Session cache. Like Chrome, TLS 1.3 tickets are single-use: a connection takes the newest one for
// its host and the server's fresh tickets replace it. Indexed by [quic].
// Session cache. Like Chrome, TLS 1.3 tickets are single-use: a connection takes the newest one for
// its host and the server's fresh tickets replace it. Indexed by [quic].
MAX_SESSIONS_PER_HOST :: 4;
cache_mu: locks.Mutex;
cache: [2]Map(string, [..]*SSL_SESSION);

new_session :: (ssl: *SSL, session: *SSL_SESSION) -> s32 #c_call {
	__ctx3: #Context; push_context,defer_pop __ctx3;
	host := ssl_host(ssl);
	if host == "" { return 0; }
	locks.lock(*cache_mu);
	defer locks.unlock(*cache_mu);
	m := *cache[SSL_is_quic(ssl)];
	if !has(m.*, host) { m.*[clone(host)] = .{}; }
	list := *m.*[host];
	if len(list) == MAX_SESSIONS_PER_HOST {
		SSL_SESSION_free(get(list, 0));
		ordered_remove(list, 0);
	}
	append(list, session);
	return 1;
}

clone :: (s: string) -> string {
	b := make_slice(u8, len(s));
	copy(b, s);
	return as_string(b);
}

cache_take :: (host: string, quic: bool) -> *SSL_SESSION {
	locks.lock(*cache_mu);
	defer locks.unlock(*cache_mu);
	if !has(cache[cast(int)(quic)], host) { return null; }
	list := *cache[cast(int)(quic)][host];
	return ifx len(list) > 0 then pop(list) else null;
}
#scope_export

// Session is one TLS connection over a netio.Stream. One reader thread and one writer thread may use it
// at once. BoringSSL sees only memory BIOs: TLS records are queued in out under mu, in the order
// BoringSSL produced them, and written to the stream under wmu. Socket I/O never happens under mu, so
// a writer blocked on a full socket never stops the reader from draining the peer.
Session :: struct {
	ssl: *SSL;
	rbio, wbio: *BIO;
	under: netio.Stream;
	// mu guards ssl, out, failed and io_err. wmu owns sending; a thread may take mu while holding wmu,
	// never the reverse.
	mu, wmu: locks.Mutex;
	out: [..]u8;
	sending: [..]u8;
	failed: Error;
	io_err: netio.Error;
	shut: bool; // Atomic; shutdown() was called.
	allocator: Allocator;
}

#add_context _last_error: Error;

// last_error returns the detailed reason for the most recent connect failure on this thread.
last_error :: () -> Error {return context._last_error;}

// connect runs the TLS handshake over under. On success the Session owns under and closes it in
// close(). On failure under is left open.
connect :: (under: netio.Stream, cfg: Config, allocator := context.allocator) -> *Session, netio.Error {
	ssl := new_ssl(tcp_ctx, cfg, false);
	if ssl == null {
		context._last_error = .Internal;
		return null, .Tls;
	}
	s := session_new(ssl, under, allocator);
	context._last_error = handshake(s);
	if context._last_error != .None {
		ne := to_netio(s, context._last_error);
		destroy(s);
		return null, ne;
	}
	return s, .None;
}
#scope_module

session_new :: (ssl: *SSL, under: netio.Stream, allocator: Allocator) -> *Session {
	s := new(Session, allocator);
	s.ssl, s.under, s.allocator = ssl, under, allocator;
	s.rbio, s.wbio = BIO_new(BIO_s_mem()), BIO_new(BIO_s_mem());
	s.out = make_dynamic(u8, 0, 0, allocator);
	s.sending = make_dynamic(u8, 0, 0, allocator);
	SSL_set_bio(ssl, s.rbio, s.wbio);
	return s;
}

handshake :: (s: *Session) -> Error {
	while true {
		locks.lock(*s.mu);
		ERR_clear_error();
		r := SSL_do_handshake(s.ssl);
		e := status_locked(s, r);
		locks.unlock(*s.mu);
		fe := flush(s);
		if r == 1 { return fe; }
		if e != .None { return e; }
		if fe != .None { return fe; }
		__e4 := feed(s); if failed(__e4) return __e4;
	}
}

// status_locked queues BoringSSL's output and classifies the result of an SSL call; .None means
// success or "needs more input". The first failure sticks.
status_locked :: (s: *Session, r: s32) -> Error {
	while true {
		n := cast(int)(BIO_pending(s.wbio));
		if n == 0 { break; }
		old := len(s.out);
		resize(*s.out, old + n);
		resize(*s.out, old + max(cast(int)(BIO_read(s.wbio, at(*s.out, old), cast(s32)(n))), 0));
	}
	if r > 0 || s.failed != .None { return s.failed; }
	if SSL_get_error(s.ssl, r) == {
	case SSL_ERROR_WANT_READ;
		return .None;
	case SSL_ERROR_ZERO_RETURN;
		return .Closed;
	}
	s.failed = ifx ERR_peek_error() == ERR_CERTIFICATE_VERIFY_FAILED then .Untrusted_Certificate else .Protocol;
	return s.failed;
}

// feed reads once from the underlying stream, blocking without any lock held, into BoringSSL.
feed :: (s: *Session) -> Error {
	buf: [16 << 10]u8 = ---;
	n, ne := netio.read(s.under, view(buf));
	if ne != .None { return io_failed(s, ne); }
	locks.lock(*s.mu);
	defer locks.unlock(*s.mu);
	if BIO_write(s.rbio, *buf[0], cast(s32)(n)) != cast(s32)(n) && s.failed == .None { s.failed = .Internal; }
	return s.failed;
}

io_failed :: (s: *Session, ne: netio.Error) -> Error {
	if ne == .Closed || is_shut(s) { return .Closed; }
	locks.lock(*s.mu);
	defer locks.unlock(*s.mu);
	if s.failed == .None {
		s.failed = .Io;
		s.io_err = ne;
	}
	return .Io;
}

// flush writes the queued records. With block = false, a thread that finds another one writing leaves
// its records to that writer, which checks the queue again after letting go of wmu.
flush :: (s: *Session, block := true) -> Error {
	while true {
		if block {
			locks.lock(*s.wmu);
		} else if !locks.try_lock(*s.wmu) {
			return .None;
		}
		e := Error.None;
		while e == .None {
			locks.lock(*s.mu);
			s.out, s.sending = s.sending, s.out;
			clear(*s.out);
			locks.unlock(*s.mu);
			if len(s.sending) == 0 { break; }
			{ ne := netio.write(s.under, view(s.sending));
			if ne != .None { e = io_failed(s, ne); } }
		}
		locks.unlock(*s.wmu);
		if e != .None { return e; }
		locks.lock(*s.mu);
		more := len(s.out) > 0;
		locks.unlock(*s.mu);
		if !more { return .None; }
	}
}
#scope_export

stream :: (s: *Session) -> netio.Stream {
	return netio.Stream.{data = s, read = stream_read, write = stream_write, close = stream_close, shutdown = stream_shutdown, set_timeout = stream_set_timeout};
}

// negotiated_alpn returns the protocol the server selected, or "". Valid until close.
negotiated_alpn :: (s: *Session) -> string {
	p: *u8;
	n: u32;
	SSL_get0_alpn_selected(s.ssl, *p, *n);
	return as_string(sub(p, 0, n));
}

// negotiated_group returns the key exchange group codepoint, e.g. 0x11ec.
negotiated_group :: (s: *Session) -> u16 {return SSL_get_group_id(s.ssl);}

// negotiated_suite returns the cipher suite codepoint, e.g. 0x1301.
negotiated_suite :: (s: *Session) -> u16 {return SSL_CIPHER_get_protocol_id(SSL_get_current_cipher(s.ssl));}

// resumed reports whether the session was resumed from a cached ticket.
resumed :: (s: *Session) -> bool {return SSL_session_reused(s.ssl) == 1;}

// read returns at least one byte of application data, blocking as needed.
read :: (s: *Session, dst: []u8) -> int, Error {
	n: int;
	err: Error;
	if len(dst) == 0 { return 0, .None; }
	while true {
		if is_shut(s) { return 0, .Closed; }
		locks.lock(*s.mu);
		ERR_clear_error();
		r := SSL_read(s.ssl, raw_data(dst), cast(s32)(min(len(dst), 1 << 30)));
		e := status_locked(s, r);
		locks.unlock(*s.mu);
		flush(s, block = false);
		if r > 0 { return cast(int)(r), .None; }
		if e != .None { return 0, e; }
		__e6 := feed(s); if failed(__e6) return n, __e6;
	}
}

// write sends all of src as application data.
write :: (s: *Session, src: []u8) -> Error {
	if is_shut(s) { return .Closed; }
	locks.lock(*s.mu);
	e := s.failed;
	rest := src;
	while e == .None && len(rest) > 0 {
		n := min(len(rest), 1 << 30);
		ERR_clear_error();
		r := SSL_write(s.ssl, raw_data(rest), cast(s32)(n));
		e = status_locked(s, r);
		if e == .None && cast(int)(r) != n { e = ifx s.failed != .None then s.failed else .Internal; }
		rest = sub_from(rest, n);
	}
	locks.unlock(*s.mu);
	if e != .None { return e; }
	return flush(s);
}

// key_update rotates our write keys and asks the peer to rotate its own (RFC 8446 4.6.3).
key_update :: (s: *Session) -> Error {
	locks.lock(*s.mu);
	e := s.failed;
	if e == .None && SSL_key_update(s.ssl, SSL_KEY_UPDATE_REQUESTED) != 1 { e = .Internal; }
	status_locked(s, 1);
	locks.unlock(*s.mu);
	if e != .None { return e; }
	return flush(s);
}

// shutdown wakes a thread blocked in read (it returns .Closed) and makes later reads and writes fail,
// without freeing anything. It forwards to the underlying stream and is safe from any thread. close()
// is still required afterwards, once the other threads have returned.
shutdown :: (s: *Session) {
	intrinsics.atomic_store(*s.shut, true);
	netio.shutdown(s.under);
}
#scope_module

is_shut :: (s: *Session) -> bool {return intrinsics.atomic_load(*s.shut);}
#scope_export

// close sends close_notify, closes the underlying stream and frees the session.
close :: (s: *Session) {
	if s == null { return; }
	if !is_shut(s) {
		locks.lock(*s.mu);
		if s.failed == .None {
			ERR_clear_error();
			SSL_shutdown(s.ssl);
			status_locked(s, 1);
		}
		locks.unlock(*s.mu);
		flush(s);
	}
	netio.close(s.under);
	destroy(s);
}
#scope_module

destroy :: (s: *Session) {
	SSL_free(s.ssl);
	delete(s.out);
	delete(s.sending);
	free(s, s.allocator);
}

to_netio :: (s: *Session, e: Error) -> netio.Error {
	if e == {
	case .None;
		return .None;
	case .Closed;
		return .Closed;
	case .Io;
		return ifx s.io_err != .None then s.io_err else .Io;
	}
	return .Tls;
}

stream_read :: (data: *void, dst: []u8) -> int, netio.Error {
	s := cast(*Session)data;
	n, e := read(s, dst);
	return n, to_netio(s, e);
}

stream_write :: (data: *void, src: []u8) -> netio.Error {
	s := cast(*Session)data;
	return to_netio(s, write(s, src));
}

stream_close :: (data: *void) {close(cast(*Session)data);}

stream_shutdown :: (data: *void) {shutdown(cast(*Session)data);}

stream_set_timeout :: (data: *void, d: time.Duration) {netio.set_timeout((cast(*Session)data).under, d);}
#scope_export

