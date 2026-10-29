// The system libssl (OpenSSL 3, else 1.1), opened with dlopen, as rust-openssl's SslConnector and
// native-tls set it up: SSL_OP_ALL less DONT_INSERT_EMPTY_FRAGMENTS plus NO_COMPRESSION and NO_SSLv3, the
// "DEFAULT:!aNULL:..." cipher list, peer verification against the default paths (plus the bundle
// openssl-probe would point SSL_CERT_FILE at), TLS 1.0 as the minimum and no maximum; per connection SNI
// and a host check without partial wildcards. Records go through memory BIOs to the stream underneath.

Session :: struct {
	inner: netio.Stream;
	ssl: *void;
	rbio, wbio: *void; // the network's bytes in; ours out (owned by ssl)
	in: In_Buffer;
}

os_connect :: (ss: *Session, host: string) -> Error {
	ctx := connector();
	if !ctx return .Unavailable;
	fn.ERR_clear_error();
	ss.ssl = fn.SSL_new(ctx);
	if !ss.ssl return .Unavailable;
	ss.rbio, ss.wbio = fn.BIO_new(fn.BIO_s_mem()), fn.BIO_new(fn.BIO_s_mem());
	if !ss.rbio || !ss.wbio return .Unavailable;
	fn.SSL_set_bio(ss.ssl, ss.rbio, ss.wbio);
	name := temp_c_string(host);
	param := fn.SSL_get0_param(ss.ssl);
	if fn.SSL_ctrl(ss.ssl, SSL_CTRL_SET_TLSEXT_HOSTNAME, TLSEXT_NAMETYPE_host_name, name) != 1 || !param return .Unavailable;
	fn.X509_VERIFY_PARAM_set_hostflags(param, X509_CHECK_FLAG_NO_PARTIAL_WILDCARDS);
	if fn.X509_VERIFY_PARAM_set1_host(param, name, xx host.count) != 1 return .Unavailable;
	fn.SSL_set_connect_state(ss.ssl);
	while true {
		r := fn.SSL_do_handshake(ss.ssl);
		if !flush(ss) return .Handshake; // also an alert after a failure, as on a socket BIO
		if r == 1 return .None;
		e := fn.SSL_get_error(ss.ssl, r);
		if e == SSL_ERROR_WANT_READ && feed(ss) continue;
		return ifx fn.SSL_get_verify_result(ss.ssl) != X509_V_OK then .Untrusted else .Handshake;
	}
	return .Handshake;
}

os_read :: (ss: *Session, dst: []u8) -> int, closed: bool {
	fn.ERR_clear_error();
	while true {
		r := fn.SSL_read(ss.ssl, dst.data, xx min(dst.count, MAX_IO));
		if r > 0 return r, false;
		e := fn.SSL_get_error(ss.ssl, r);
		if e == SSL_ERROR_ZERO_RETURN return 0, true;
		if e != SSL_ERROR_WANT_READ || !flush(ss) return 0, false;
		if !feed(ss) return 0, true;
	}
	return 0, false;
}

os_write :: (ss: *Session, src: []u8) -> bool {
	fn.ERR_clear_error();
	rest := src;
	while rest.count {
		r := fn.SSL_write(ss.ssl, rest.data, xx min(rest.count, MAX_IO));
		if r <= 0 || !flush(ss) return false;
		rest.data += r; rest.count -= r;
	}
	return true;
}

os_free :: (ss: *Session) { if ss.ssl fn.SSL_free(ss.ssl); } // frees both BIOs

#scope_file

#import "POSIX";

// feed moves one read of the network into rbio.
feed :: (ss: *Session) -> bool {
	if !fill_from(*ss.in, ss.inner) return false;
	n := ss.in.end - ss.in.next;
	if fn.BIO_write(ss.rbio, ss.in.data.data + ss.in.next, xx n) != n return false;
	ss.in.next = ss.in.end;
	return true;
}

// flush sends what libssl wrote into wbio.
flush :: (ss: *Session) -> bool {
	buf: [READ_CHUNK]u8 = ---;
	while fn.BIO_ctrl(ss.wbio, BIO_CTRL_PENDING, 0, null) > 0 {
		n := fn.BIO_read(ss.wbio, buf.data, buf.count);
		if n <= 0 return false;
		if netio.write(ss.inner, array_view(buf, 0, n)) != .None return false;
	}
	return true;
}

// connector: native-tls's TlsConnector::new, once per process (reqwest builds one per client).
connector :: () -> *void {
	locks.guard(*lib.mu);
	if lib.tried return lib.ctx;
	lib.tried = true;
	h := dlopen("libssl.so.3", RTLD_NOW | RTLD_DEEPBIND);
	v3 := h != null;
	if !h h = dlopen("libssl.so.1.1", RTLD_NOW | RTLD_DEEPBIND);
	if !h return null;
	for type_info(Libssl).members {
		f := dlsym(h, temp_c_string(it.name));
		if !f return null;
		(cast(**void) (cast(*u8) *fn + it.offset_in_bytes)).* = f;
	}
	ctx := fn.SSL_CTX_new(fn.TLS_method());
	if !ctx return null;
	// openssl-sys's SSL_OP_ALL differs by version: 1.1 still has LEGACY_SERVER_CONNECT in it
	all: u64 = SSL_OP_CRYPTOPRO_TLSEXT_BUG | SSL_OP_DONT_INSERT_EMPTY_FRAGMENTS | SSL_OP_TLSEXT_PADDING | SSL_OP_SAFARI_ECDHE_ECDSA_BUG;
	if !v3 all |= SSL_OP_LEGACY_SERVER_CONNECT;
	fn.SSL_CTX_set_options(ctx, (all | SSL_OP_NO_COMPRESSION | SSL_OP_NO_SSLv3) & ~SSL_OP_DONT_INSERT_EMPTY_FRAGMENTS);
	fn.SSL_CTX_ctrl(ctx, SSL_CTRL_MODE, SSL_MODE_ENABLE_PARTIAL_WRITE | SSL_MODE_ACCEPT_MOVING_WRITE_BUFFER | SSL_MODE_AUTO_RETRY | SSL_MODE_RELEASE_BUFFERS, null);
	ok := fn.SSL_CTX_set_default_verify_paths(ctx) == 1
		&& fn.SSL_CTX_set_cipher_list(ctx, "DEFAULT:!aNULL:!eNULL:!MD5:!3DES:!DES:!RC4:!IDEA:!SEED:!aDSS:!SRP:!PSK") == 1;
	fn.SSL_CTX_set_verify(ctx, SSL_VERIFY_PEER, null);
	ok = ok && fn.SSL_CTX_ctrl(ctx, SSL_CTRL_SET_MIN_PROTO_VERSION, TLS1_VERSION, null) == 1
		&& fn.SSL_CTX_ctrl(ctx, SSL_CTRL_SET_MAX_PROTO_VERSION, 0, null) == 1;
	// openssl-probe sets SSL_CERT_FILE / SSL_CERT_DIR to what it finds when they are unset
	if ok && !getenv("SSL_CERT_FILE") for BUNDLES if file_exists(it) { fn.SSL_CTX_load_verify_locations(ctx, temp_c_string(it), null); break; }
	if ok && !getenv("SSL_CERT_DIR") && file_exists("/etc/ssl/certs") fn.SSL_CTX_load_verify_locations(ctx, null, "/etc/ssl/certs");
	if !ok { fn.SSL_CTX_free(ctx); return null; }
	lib.ctx = ctx;
	return ctx;
}

file_exists :: (path: string) -> bool { return access(temp_c_string(path), F_OK) == 0; }

BUNDLES :: string.["/etc/ssl/certs/ca-certificates.crt", "/etc/pki/tls/certs/ca-bundle.crt", "/etc/ssl/ca-bundle.pem", "/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem", "/etc/ssl/cert.pem"];

locks :: #import "locks";
lib: struct { mu: locks.Mutex; tried: bool; ctx: *void; };

libc :: #system_library "libc"; // dlopen/dlsym are in libdl before glibc 2.34; the link adds -ldl
dlopen :: (file: *u8, mode: s32) -> *void #foreign libc;
dlsym :: (handle: *void, name: *u8) -> *void #foreign libc;
RTLD_NOW :: 2;
RTLD_DEEPBIND :: 8; // libssl binds to its own libcrypto, never to BoringSSL's names in this binary

SSL_OP_LEGACY_SERVER_CONNECT :: 0x4;
SSL_OP_TLSEXT_PADDING :: 0x10;
SSL_OP_SAFARI_ECDHE_ECDSA_BUG :: 0x40;
SSL_OP_DONT_INSERT_EMPTY_FRAGMENTS :: 0x800;
SSL_OP_NO_COMPRESSION :: 0x20000;
SSL_OP_NO_SSLv3 :: 0x2000000;
SSL_OP_CRYPTOPRO_TLSEXT_BUG :: 0x80000000;
SSL_MODE_ENABLE_PARTIAL_WRITE :: 0x1;
SSL_MODE_ACCEPT_MOVING_WRITE_BUFFER :: 0x2;
SSL_MODE_AUTO_RETRY :: 0x4;
SSL_MODE_RELEASE_BUFFERS :: 0x10;
SSL_CTRL_MODE :: 33;
SSL_CTRL_SET_TLSEXT_HOSTNAME :: 55;
SSL_CTRL_SET_MIN_PROTO_VERSION :: 123;
SSL_CTRL_SET_MAX_PROTO_VERSION :: 124;
TLSEXT_NAMETYPE_host_name :: 0;
TLS1_VERSION :: 0x301;
SSL_VERIFY_PEER :: 1;
X509_CHECK_FLAG_NO_PARTIAL_WILDCARDS :: 0x4;
X509_V_OK :: 0;
SSL_ERROR_WANT_READ :: 2;
SSL_ERROR_ZERO_RETURN :: 6;
BIO_CTRL_PENDING :: 10;
MAX_IO :: 1 << 30; // one SSL_read / SSL_write

// Every libssl / libcrypto entry point used, resolved by name with dlsym (libssl's handle reaches libcrypto).
Libssl :: struct {
	TLS_method: () -> *void #c_call;
	SSL_CTX_new: (method: *void) -> *void #c_call;
	SSL_CTX_free: (ctx: *void) #c_call;
	SSL_CTX_set_options: (ctx: *void, op: u64) -> u64 #c_call;
	SSL_CTX_ctrl: (ctx: *void, cmd: s32, larg: s64, parg: *void) -> s64 #c_call;
	SSL_CTX_set_default_verify_paths: (ctx: *void) -> s32 #c_call;
	SSL_CTX_load_verify_locations: (ctx: *void, file: *u8, dir: *u8) -> s32 #c_call;
	SSL_CTX_set_cipher_list: (ctx: *void, list: *u8) -> s32 #c_call;
	SSL_CTX_set_verify: (ctx: *void, mode: s32, cb: *void) #c_call;
	SSL_new: (ctx: *void) -> *void #c_call;
	SSL_free: (ssl: *void) #c_call;
	SSL_ctrl: (ssl: *void, cmd: s32, larg: s64, parg: *void) -> s64 #c_call;
	SSL_get0_param: (ssl: *void) -> *void #c_call;
	SSL_set_bio: (ssl: *void, rbio: *void, wbio: *void) #c_call;
	SSL_set_connect_state: (ssl: *void) #c_call;
	SSL_do_handshake: (ssl: *void) -> s32 #c_call;
	SSL_read: (ssl: *void, buf: *void, n: s32) -> s32 #c_call;
	SSL_write: (ssl: *void, buf: *void, n: s32) -> s32 #c_call;
	SSL_get_error: (ssl: *void, ret: s32) -> s32 #c_call;
	SSL_get_verify_result: (ssl: *void) -> s64 #c_call;
	X509_VERIFY_PARAM_set_hostflags: (param: *void, flags: u32) #c_call;
	X509_VERIFY_PARAM_set1_host: (param: *void, name: *u8, len: u64) -> s32 #c_call;
	BIO_s_mem: () -> *void #c_call;
	BIO_new: (method: *void) -> *void #c_call;
	BIO_read: (bio: *void, buf: *void, n: s32) -> s32 #c_call;
	BIO_write: (bio: *void, buf: *void, n: s32) -> s32 #c_call;
	BIO_ctrl: (bio: *void, cmd: s32, larg: s64, parg: *void) -> s64 #c_call;
	ERR_clear_error: () #c_call;
}
fn: Libssl;
