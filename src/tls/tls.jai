// CHROME_MAJOR is the Chrome whose hello we send unless told otherwise: the official client's Electron 44.
// The supported shapes are 148's and 152's; any major below 152 gets 148's.
CHROME_MAJOR :: 152;
// presented_major: the Chrome this process presents when a Config names none: the identity's host
// (src/discord client_create sets it once, before any connection).
presented_major := CHROME_MAJOR;

major_or_presented :: (chrome_major: int) -> int { return ifx chrome_major then chrome_major else presented_major; }

Config :: struct {
	// ALPN protocols in preference order, e.g. {"h2", "http/1.1"}. ALPS is offered for "h2" over
	// TCP and "h3" over QUIC, as Chrome does.
	alpn: []string;
	// SNI and the name the certificate must be valid for.
	server_name: string;
	// Tests only: accepts any certificate.
	insecure_skip_verify: bool;
	// Self-hosted servers: the BLAKE3 hash of the one leaf certificate to accept (32 bytes), with no
	// certificate authority or name check.
	pin: []u8;
	// The Chrome major version whose ClientHello to send, 0 = presented_major. From 152 the signature
	// algorithms start with a GREASE value and ML-DSA-44/65/87.
	chrome_major: int;
}

// Error is the detailed failure reason; netio.Error is what the Stream reports.
Error :: enum u8 {
	None;
	Io;                    // The underlying stream failed.
	Closed;                // close_notify, EOF, or shutdown().
	Bad_Certificate;       // The OS could not parse a certificate (trust_*.jai only).
	Untrusted_Certificate; // The OS rejected the chain, or it is not valid for the server name.
	Protocol;              // BoringSSL failed the connection and sent the peer an alert.
	Internal;
}

// new_ctx makes an SSL_CTX configured like Chrome chrome_major's, for TLS over TCP or, with quic, for QUIC
// (TLS 1.3 only, GREASE only in ECH, no OCSP or SCT requests, the same in every version). ngtcp2's BoringSSL
// backend takes a context from here, adds its QUIC method, and makes each connection's SSL with new_ssl.
// Returns null on failure.
new_ctx :: (quic: bool, chrome_major := CHROME_MAJOR) -> *SSL_CTX {
	ctx := SSL_CTX_new(TLS_method());
	if !ctx return null;
	v152 := !quic && chrome_major >= 152;
	sigalgs: []u16 = SIGALGS;
	if quic sigalgs = SIGALGS_QUIC;
	else if v152 sigalgs = SIGALGS_152;
	ok := SSL_CTX_set_min_proto_version(ctx, xx ifx quic then TLS1_3_VERSION else TLS1_2_VERSION) == 1
		&& SSL_CTX_set_max_proto_version(ctx, TLS1_3_VERSION) == 1
		&& SSL_CTX_set_strict_cipher_list(ctx, CHROME_TLS12_CIPHERS) == 1
		&& SSL_CTX_set1_group_ids(ctx, GROUPS.data, xx GROUPS.count) == 1
		&& SSL_CTX_set_verify_algorithm_prefs(ctx, sigalgs.data, xx sigalgs.count) == 1
		&& SSL_CTX_add_cert_compression_alg(ctx, 2, null, decompress_brotli) == 1;
	if !ok { SSL_CTX_free(ctx); return null; }
	SSL_CTX_set_grease_enabled(ctx, xx ifx quic then 0 else 1);
	SSL_CTX_set_grease_sigalgs_enabled(ctx, xx v152);
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
// GREASE, a cached session to resume, and certificate checks for cfg.server_name. Returns null on failure.
// BoringSSL's callbacks on it run in the context given to set_context.
new_ssl :: (ctx: *SSL_CTX, cfg: Config, quic: bool) -> *SSL {
	if !ctx || !cfg.server_name || cfg.server_name.count >= 256 return null;
	ensure_init();
	ssl := SSL_new(ctx);
	if !ssl return null;
	// The SSL's host names the certificate's required name and keys the session cache. Unverified test
	// connections get a key no real host can have, so a real connection never resumes a session whose
	// certificate nobody checked.
	d := cast(*Ssl_Data) OPENSSL_zalloc(size_of(Ssl_Data));
	ok := d && SSL_set_ex_data(ssl, host_index, d) == 1;
	if d && !ok OPENSSL_free(d);
	if !ok { SSL_free(ssl); return null; }
	// A pinned connection keys its sessions by the pin too, so it never resumes one whose certificate had
	// another hash.
	prefix := ifx cfg.insecure_skip_verify then INSECURE else "";
	if cfg.pin.count == 32 {
		d.pinned = true;
		memcpy(d.pin.data, cfg.pin.data, 32);
		prefix = tprint("pin % ", hex(cfg.pin));
	} else if cfg.pin.count ok = false;
	at := prefix.count;
	memcpy(d.host.data, prefix.data, at);
	memcpy(d.host.data + at, cfg.server_name.data, cfg.server_name.count);
	d.host_count = at + cfg.server_name.count;
	if !is_ip_literal(cfg.server_name) ok = SSL_set_tlsext_host_name(ssl, d.host.data + at) == 1;

	protos: [512]u8;
	n := 0;
	for p: cfg.alpn {
		if !p.count || p.count > 255 || n + 1 + p.count > protos.count { ok = false; break; }
		protos[n] = xx p.count;
		memcpy(protos.data + n + 1, p.data, p.count);
		n += 1 + p.count;
		if p == (ifx quic then "h3" else "h2") { ok = ok && SSL_add_application_settings(ssl, p.data, xx p.count, null, 0) == 1; }
	}
	if n ok = ok && SSL_set_alpn_protos(ssl, protos.data, xx n) == 0;
	SSL_set_alps_use_new_codepoint(ssl, 1);
	SSL_set_enable_ech_grease(ssl, 1);
	if quic SSL_set_early_data_enabled(ssl, 1);
	if cfg.insecure_skip_verify SSL_set_custom_verify(ssl, SSL_VERIFY_PEER, (ssl: *SSL, alert: *u8) -> s32 #c_call { return ssl_verify_ok; });
	if d.pinned SSL_set_custom_verify(ssl, SSL_VERIFY_PEER, verify_pin);
	sess := cache_take(host_of(d), quic);
	if sess {
		ok = ok && SSL_set_session(ssl, sess) == 1;
		SSL_SESSION_free(sess);
	}
	SSL_set_connect_state(ssl);
	if !ok { SSL_free(ssl); return null; }
	return ssl;
}

// set_context names the context BoringSSL's callbacks on ssl (certificate checks, session tickets) run in.
// Call it on the thread that drives ssl, before driving it.
set_context :: (ssl: *SSL, ctx: *#Context) {
	(cast(*Ssl_Data) SSL_get_ex_data(ssl, host_index)).ctx = ctx;
}

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
	shut: bool; // atomic; shutdown() was called.
	allocator: Allocator;
}

// connect runs the TLS handshake over under; the session lives in context.allocator. On success the
// Session owns under and closes it in close(). On failure under is left open; the third result is the
// detailed reason.
connect :: (under: netio.Stream, cfg: Config) -> *Session, netio.Error, Error {
	ensure_init();
	ssl := new_ssl(tcp_ctx(cfg.chrome_major), cfg, false);
	if !ssl return null, .Tls, .Internal;
	s, ne, e := start(ssl, under);
	return s, ne, e;
}

// client_hello returns, for tests, the ClientHello handshake message (no record header) connect would send
// for cfg, from context.allocator. Nothing goes on the network.
client_hello :: (cfg: Config) -> []u8 {
	ensure_init();
	ssl := new_ssl(tcp_ctx(cfg.chrome_major), cfg, false);
	if !ssl return .[];
	defer SSL_free(ssl);
	rbio, wbio := BIO_new(BIO_s_mem()), BIO_new(BIO_s_mem());
	SSL_set_bio(ssl, rbio, wbio);
	SSL_do_handshake(ssl);
	buf: [4096]u8;
	n := BIO_read(wbio, buf.data, buf.count);
	if n <= 5 return .[];
	return array_copy(array_view(buf, 5, n - 5));
}

// Self-hosted servers (`fastcord -serve`) are the server side: TLS 1.3 only, X25519MLKEM768 first, a
// self-signed P-256 certificate that clients pin by hash, and exactly one ALPN protocol.

// selfsigned_cert makes the DER certificate for a P-256 private key (crypto.p256_generate).
selfsigned_cert :: (key: [32]u8) -> []u8 {
	buf: [1024]u8;
	n := cast(int) fc_selfsigned_cert(key.data, buf.data);
	return array_copy(array_view(buf, 0, n));
}

// server_ctx returns null on failure. Contexts live as long as the server: nothing frees them. A client
// that doesn't offer alpn gets fallback when it offers that instead.
server_ctx :: (key: [32]u8, cert: []u8, alpn: string, fallback := "") -> *SSL_CTX {
	ensure_init();
	if !alpn.count || alpn.count > 255 || fallback.count > 255 return null;
	ctx := SSL_CTX_new(TLS_method());
	if !ctx return null;
	// Each protocol length-prefixed, ended by a 0 length.
	wire := NewArray(2 + alpn.count + ifx fallback then 1 + fallback.count else 0, u8,, context.default_allocator);
	wire[0] = xx alpn.count;
	memcpy(wire.data + 1, alpn.data, alpn.count);
	if fallback {
		wire[1 + alpn.count] = xx fallback.count;
		memcpy(wire.data + 2 + alpn.count, fallback.data, fallback.count);
	}
	ok := SSL_CTX_set_min_proto_version(ctx, TLS1_3_VERSION) == 1
		&& SSL_CTX_set_max_proto_version(ctx, TLS1_3_VERSION) == 1
		&& SSL_CTX_set1_group_ids(ctx, GROUPS.data, xx GROUPS.count) == 1
		&& fc_ssl_ctx_use_p256(ctx, key.data, cert.data, xx cert.count) == 1;
	if !ok { SSL_CTX_free(ctx); return null; }
	SSL_CTX_set_alpn_select_cb(ctx, (ssl: *SSL, out: **u8, out_len: *u8, in: *u8, in_len: u32, arg: *void) -> s32 #c_call {
		want := cast(*u8) arg;
		while want[0] {
			i: u32 = 0;
			while i < in_len {
				n := in[i];
				if n == want[0] && i + 1 + n <= in_len && memcmp(in + i + 1, want + 1, n) == 0 {
					out.*, out_len.* = in + i + 1, n;
					return SSL_TLSEXT_ERR_OK;
				}
				i += 1 + n;
			}
			want += 1 + want[0];
		}
		return SSL_TLSEXT_ERR_ALERT_FATAL;
	}, wire.data);
	return ctx;
}

// accept runs the server side of the handshake over under; a client that negotiated no ALPN protocol is
// refused unless none_ok. Like connect, the session owns under on success and leaves it open on failure.
accept :: (under: netio.Stream, ctx: *SSL_CTX, none_ok := false) -> *Session, netio.Error, Error {
	ssl := SSL_new(ctx);
	if !ssl return null, .Tls, .Internal;
	d := cast(*Ssl_Data) OPENSSL_zalloc(size_of(Ssl_Data));
	if !d || SSL_set_ex_data(ssl, host_index, d) != 1 { OPENSSL_free(d); SSL_free(ssl); return null, .Tls, .Internal; }
	SSL_set_accept_state(ssl);
	s, ne, e := start(ssl, under);
	if s && !none_ok && !negotiated_alpn(s) {
		destroy(s);
		return null, .Tls, .Protocol;
	}
	return s, ne, e;
}

// server_name is the SNI the client sent, or "". Valid until close.
server_name :: (s: *Session) -> string {
	p := SSL_get_servername(s.ssl, 0);
	return ifx p then to_string(p) else "";
}

// exporter fills out from the TLS exporter (RFC 8446 7.5), binding a login to this one connection.
exporter :: (s: *Session, label: string, ctx: []u8, out: []u8) -> bool {
	locks.guard(*s.mu);
	return SSL_export_keying_material(s.ssl, out.data, xx out.count, label.data, xx label.count, ctx.data, xx ctx.count, 1) == 1;
}

start :: (ssl: *SSL, under: netio.Stream) -> *Session, netio.Error, Error {
	s := New(Session);
	s.ssl, s.under, s.allocator = ssl, under, context.allocator;
	s.out.allocator, s.sending.allocator = context.allocator, context.allocator;
	s.rbio, s.wbio = BIO_new(BIO_s_mem()), BIO_new(BIO_s_mem());
	SSL_set_bio(ssl, s.rbio, s.wbio);
	err := handshake(s);
	if err != .None {
		ne := to_netio(s, err);
		destroy(s);
		return null, ne, err;
	}
	return s, .None, .None;
}

stream :: (s: *Session) -> netio.Stream {
	return .{data = s, read = stream_read, write = stream_write, close = stream_close, shutdown = stream_shutdown, set_timeout = stream_set_timeout};
}

// negotiated_alpn returns the protocol the server selected, or "". Valid until close.
negotiated_alpn :: (s: *Session) -> string {
	p: *u8;
	n: u32;
	SSL_get0_alpn_selected(s.ssl, *p, *n);
	return to_string(p, n);
}

// negotiated_group returns the key exchange group codepoint, e.g. 0x11ec.
negotiated_group :: (s: *Session) -> u16 { return SSL_get_group_id(s.ssl); }

// negotiated_suite returns the cipher suite codepoint, e.g. 0x1301.
negotiated_suite :: (s: *Session) -> u16 { return SSL_CIPHER_get_protocol_id(SSL_get_current_cipher(s.ssl)); }

// resumed reports whether the session was resumed from a cached ticket.
resumed :: (s: *Session) -> bool { return SSL_session_reused(s.ssl) == 1; }

// read returns at least one byte of application data, blocking as needed.
read :: (s: *Session, dst: []u8) -> int, Error {
	if !dst.count return 0, .None;
	while true {
		if is_shut(s) return 0, .Closed;
		lock_ssl(s);
		r := SSL_read(s.ssl, dst.data, xx min(dst.count, 1 << 30));
		e := status_locked(s, r);
		locks.unlock(*s.mu);
		flush(s, block = false);
		if r > 0 return r, .None;
		if e != .None return 0, e;
		e = feed(s);
		if e != .None return 0, e;
	}
	return 0, .None;
}

// write sends all of src as application data.
write :: (s: *Session, src: []u8) -> Error {
	if is_shut(s) return .Closed;
	lock_ssl(s);
	e := s.failed;
	rest := src;
	while e == .None && rest.count {
		n := min(rest.count, 1 << 30);
		r := SSL_write(s.ssl, rest.data, xx n);
		e = status_locked(s, r);
		if e == .None && r != n e = ifx s.failed != .None then s.failed else .Internal;
		rest.data += n; rest.count -= n;
	}
	locks.unlock(*s.mu);
	if e != .None return e;
	return flush(s);
}

// key_update rotates our write keys and asks the peer to rotate its own (RFC 8446 4.6.3).
key_update :: (s: *Session) -> Error {
	lock_ssl(s);
	e := s.failed;
	if e == .None && SSL_key_update(s.ssl, SSL_KEY_UPDATE_REQUESTED) != 1 e = .Internal;
	status_locked(s, 1);
	locks.unlock(*s.mu);
	if e != .None return e;
	return flush(s);
}

// shutdown wakes a thread blocked in read (it returns .Closed) and makes later reads and writes fail,
// without freeing anything. It forwards to the underlying stream and is safe from any thread. close()
// is still required afterwards, once the other threads have returned.
shutdown :: (s: *Session) {
	atomic_store(*s.shut, true);
	netio.shutdown(s.under);
}

// close sends close_notify, closes the underlying stream and frees the session.
close :: (s: *Session) {
	if !s return;
	if !is_shut(s) {
		lock_ssl(s);
		if s.failed == .None {
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

// Chrome's TLS 1.2 suites, in its order.
CHROME_TLS12_CIPHERS :: "ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:ECDHE-RSA-AES128-SHA:ECDHE-RSA-AES256-SHA:AES128-GCM-SHA256:AES256-GCM-SHA384:AES128-SHA:AES256-SHA";
GROUPS := u16.[0x11ec, 0x001d, 0x0017, 0x0018]; // X25519MLKEM768, X25519, P-256, P-384.
// Chrome's signature algorithms over TCP (net/socket/ssl_client_socket_impl.cc kVerifyPrefs). Chrome 152
// puts ML-DSA-44, -65 and -87 first (kVerifyPrefsWithMlDsa) and BoringSSL a GREASE value before them
// (kTlsGreaseSigalgs). QUIC leaves BoringSSL's default list, rsa_pkcs1_sha1 (0x0201) last, in both.
SIGALGS := u16.[0x0403, 0x0804, 0x0401, 0x0503, 0x0805, 0x0501, 0x0806, 0x0601];
SIGALGS_152 := u16.[0x0904, 0x0905, 0x0906, 0x0403, 0x0804, 0x0401, 0x0503, 0x0805, 0x0501, 0x0806, 0x0601];
SIGALGS_QUIC := u16.[0x0403, 0x0804, 0x0401, 0x0503, 0x0805, 0x0501, 0x0806, 0x0601, 0x0201];

INSECURE :: "insecure ";

// Ssl_Data is each SSL's ex_data (BoringSSL frees it with the SSL): its host and the context its
// callbacks run in.
Ssl_Data :: struct {
	ctx: *#Context;
	host_count: int;
	host: [72 + 256]u8; // NUL-terminated, after "insecure " or "pin <hex> ".
	pinned: bool;
	pin: [32]u8;
}

hex :: (b: []u8) -> string {
	DIGITS :: "0123456789abcdef";
	s := alloc_string(b.count * 2,, temp);
	for b { s[it_index * 2] = DIGITS[it >> 4]; s[it_index * 2 + 1] = DIGITS[it & 15]; }
	return s;
}

verify_pin :: (ssl: *SSL, out_alert: *u8) -> s32 #c_call {
	d := cast(*Ssl_Data) SSL_get_ex_data(ssl, host_index);
	push_context d.ctx.* {
		certs := SSL_get0_peer_certificates(ssl);
		if !certs || OPENSSL_sk_num(certs) < 1 return ssl_verify_invalid;
		b := cast(*CRYPTO_BUFFER) OPENSSL_sk_value(certs, 0);
		h := crypto.blake3(.{cast(s64) CRYPTO_BUFFER_len(b), CRYPTO_BUFFER_data(b)});
		if !crypto.constant_time_equal(h, d.pin) return ssl_verify_invalid;
		return ssl_verify_ok;
	}
}

host_of :: (d: *Ssl_Data) -> string { return to_string(d.host.data, d.host_count); }

// The ex_data index and the shared TCP contexts (Chrome 148's and 152's), made on first use.
init_mu: locks.Mutex;
inited: bool;
host_index: s32;
tcp_ctxs: [2]*SSL_CTX;

tcp_ctx :: (chrome_major: int) -> *SSL_CTX { return tcp_ctxs[xx (major_or_presented(chrome_major) >= 152)]; }

ensure_init :: () {
	if atomic_load(*inited) return;
	locks.guard(*init_mu);
	if inited return;
	host_index = SSL_get_ex_new_index(0, null, null, null, (parent: *void, ptr: *void, ad: *void, index: s32, argl: s64, argp: *void) #c_call {
		OPENSSL_free(ptr);
	});
	tcp_ctxs = .[new_ctx(false, 148), new_ctx(false, 152)];
	atomic_store(*inited, true);
}

// is_ip_literal: Chrome sends no SNI for IP addresses.
is_ip_literal :: (host: string) -> bool {
	for host if it != #char ":" && it != #char "." && !(it >= #char "0" && it <= #char "9") return false;
	return true;
}

// verify_peer accepts the peer only if the OS trusts its chain for the server name (trust_*.jai) and
// BoringSSL's X509_check_host also matches the leaf to that name. Every other path rejects.
verify_peer :: (ssl: *SSL, out_alert: *u8) -> s32 #c_call {
	d := cast(*Ssl_Data) SSL_get_ex_data(ssl, host_index);
	push_context d.ctx.* {
		host := host_of(d);
		certs := SSL_get0_peer_certificates(ssl);
		n := ifx certs then cast(int) OPENSSL_sk_num(certs) else 0;
		chain: [16][]u8;
		if !host || !n || n > chain.count return ssl_verify_invalid;
		for i: 0..n-1 {
			b := cast(*CRYPTO_BUFFER) OPENSSL_sk_value(certs, xx i);
			chain[i] = .{cast(s64) CRYPTO_BUFFER_len(b), CRYPTO_BUFFER_data(b)};
		}
		p := chain[0].data;
		leaf := d2i_X509(null, *p, chain[0].count);
		if !leaf return ssl_verify_invalid;
		name_ok := X509_check_host(leaf, host.data, xx host.count, 0, null) == 1;
		X509_free(leaf);
		if !name_ok || verify_chain_cached(array_view(chain, 0, n), host) != .None return ssl_verify_invalid;
		return ssl_verify_ok;
	}
}

decompress_brotli :: (ssl: *SSL, out: **CRYPTO_BUFFER, uncompressed_len: u64, data: *u8, data_len: u64) -> s32 #c_call {
	d := cast(*Ssl_Data) SSL_get_ex_data(ssl, host_index);
	push_context d.ctx.* {
		res, err := brotli.decompress(.{xx data_len, data}, xx uncompressed_len);
		defer array_free(res);
		if err != .None || res.count != xx uncompressed_len return 0;
		out.* = CRYPTO_BUFFER_new(res.data, xx res.count, null);
		return xx ifx out.* then 1 else 0;
	}
}

// Session cache. Like Chrome, TLS 1.3 tickets are single-use: a connection takes the newest one for
// its host and the server's fresh tickets replace it. Indexed by [quic]; heap-allocated.
MAX_SESSIONS_PER_HOST :: 4;
cache_mu: locks.Mutex;
cache: [2]Table(string, [..]*SSL_SESSION);

new_session :: (ssl: *SSL, session: *SSL_SESSION) -> s32 #c_call {
	d := cast(*Ssl_Data) SSL_get_ex_data(ssl, host_index);
	push_context d.ctx.* {
		host := host_of(d);
		if !host return 0;
		locks.guard(*cache_mu);
		push_allocator(Context_Base.default_allocator);
		m := *cache[SSL_is_quic(ssl)];
		list := table_find_pointer(m, host);
		if !list { empty: [..]*SSL_SESSION; list = table_add(m, copy_string(host), empty); }
		if list.count == MAX_SESSIONS_PER_HOST {
			SSL_SESSION_free(list.*[0]);
			array_ordered_remove_by_index(list, 0);
		}
		array_add(list, session);
		return 1;
	}
}

cache_take :: (host: string, quic: bool) -> *SSL_SESSION {
	locks.guard(*cache_mu);
	list := table_find_pointer(*cache[cast(int) quic], host);
	if !list || !list.count return null;
	return pop(list);
}

// lock_ssl takes s.mu before a BoringSSL call on s.ssl, whose callbacks run in this thread's context.
lock_ssl :: (s: *Session) #expand {
	locks.lock(*s.mu);
	(cast(*Ssl_Data) SSL_get_ex_data(s.ssl, host_index)).ctx = *context;
	ERR_clear_error();
}

handshake :: (s: *Session) -> Error {
	while true {
		lock_ssl(s);
		r := SSL_do_handshake(s.ssl);
		e := status_locked(s, r);
		locks.unlock(*s.mu);
		fe := flush(s);
		if r == 1 return fe;
		if e != .None return e;
		if fe != .None return fe;
		e = feed(s);
		if e != .None return e;
	}
	return .None;
}

// status_locked queues BoringSSL's output and classifies the result of an SSL call; .None means
// success or "needs more input". The first failure sticks.
status_locked :: (s: *Session, r: s32) -> Error {
	while true {
		n := cast(int) BIO_pending(s.wbio);
		if !n break;
		old := s.out.count;
		if old + n > s.out.allocated array_reserve(*s.out, max(2 * s.out.allocated, old + n));
		s.out.count = old + max(BIO_read(s.wbio, s.out.data + old, xx n), 0);
	}
	if r > 0 || s.failed != .None return s.failed;
	if SSL_get_error(s.ssl, r) == {
		case SSL_ERROR_WANT_READ;   return .None;
		case SSL_ERROR_ZERO_RETURN; return .Closed;
	}
	s.failed = ifx ERR_peek_error() == ERR_CERTIFICATE_VERIFY_FAILED then .Untrusted_Certificate else .Protocol;
	return s.failed;
}

// feed reads once from the underlying stream, blocking without any lock held, into BoringSSL.
feed :: (s: *Session) -> Error {
	buf: [16 << 10]u8 = ---;
	n, ne := netio.read(s.under, buf);
	if ne != .None return io_failed(s, ne);
	locks.guard(*s.mu);
	if BIO_write(s.rbio, buf.data, xx n) != n && s.failed == .None s.failed = .Internal;
	return s.failed;
}

io_failed :: (s: *Session, ne: netio.Error) -> Error {
	if ne == .Closed || is_shut(s) return .Closed;
	locks.guard(*s.mu);
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
		if block locks.lock(*s.wmu);
		else if !locks.try_lock(*s.wmu) return .None;
		e := Error.None;
		while e == .None {
			locks.lock(*s.mu);
			swap(*s.out, *s.sending);
			s.out.count = 0;
			locks.unlock(*s.mu);
			if !s.sending.count break;
			ne := netio.write(s.under, s.sending);
			if ne != .None e = io_failed(s, ne);
		}
		locks.unlock(*s.wmu);
		if e != .None return e;
		locks.lock(*s.mu);
		more := s.out.count > 0;
		locks.unlock(*s.mu);
		if !more return .None;
	}
	return .None;
}

is_shut :: (s: *Session) -> bool { return atomic_load(*s.shut); }

destroy :: (s: *Session) {
	SSL_free(s.ssl);
	array_free(s.out);
	array_free(s.sending);
	free(s,, s.allocator);
}

to_netio :: (s: *Session, e: Error) -> netio.Error {
	if e == {
		case .None;   return .None;
		case .Closed; return .Closed;
		case .Io;     return ifx s.io_err != .None then s.io_err else .Io;
	}
	return .Tls;
}

stream_read :: (data: *void, dst: []u8) -> int, netio.Error {
	s := cast(*Session) data;
	n, e := read(s, dst);
	return n, to_netio(s, e);
}
stream_write :: (data: *void, src: []u8) -> netio.Error { s := cast(*Session) data; return to_netio(s, write(s, src)); }
stream_close :: (data: *void) { close(cast(*Session) data); }
stream_shutdown :: (data: *void) { shutdown(cast(*Session) data); }
stream_set_timeout :: (data: *void, timeout_ms: s64) { netio.set_timeout((cast(*Session) data).under, timeout_ms); }
