// Chain validation against the distro's CA roots with BoringSSL's X509 verifier: $SSL_CERT_FILE /
// $SSL_CERT_DIR when set (as OpenSSL reads them), else the first bundle that loads, plus the hashed
// /etc/ssl/certs directory. Loaded once, on the first handshake.
verify_chain_os :: (chain: [][]u8, host: string) -> Error {
	store := trust_store();
	if !store return .Untrusted_Certificate;
	certs: [16]*X509;
	n := 0;
	defer for i: 0..n-1 X509_free(certs[i]);
	for der: chain {
		if n == certs.count break;
		p := der.data;
		c := d2i_X509(null, *p, der.count);
		if !c return .Bad_Certificate;
		certs[n] = c;
		n += 1;
	}
	untrusted := OPENSSL_sk_new_null();
	if !untrusted return .Internal;
	defer OPENSSL_sk_free(untrusted); // the stack only; the certificates are freed above
	for i: 1..n-1 OPENSSL_sk_push(untrusted, certs[i]);
	ctx := X509_STORE_CTX_new();
	if !ctx return .Internal;
	defer X509_STORE_CTX_free(ctx);
	if !X509_STORE_CTX_init(ctx, store, certs[0], untrusted) return .Internal;
	X509_STORE_CTX_set_default(ctx, "ssl_server");
	X509_VERIFY_PARAM_set1_host(X509_STORE_CTX_get0_param(ctx), host.data, xx host.count);
	ok := X509_verify_cert(ctx) == 1;
	ERR_clear_error();
	return ifx ok then .None else .Untrusted_Certificate;
}

#scope_file

#import "POSIX";

X509_STORE :: struct {}
X509_STORE_CTX :: struct {}
X509_VERIFY_PARAM :: struct {}

X509_STORE_new :: () -> *X509_STORE #foreign bssl;
X509_STORE_load_locations :: (store: *X509_STORE, file: *u8, dir: *u8) -> s32 #foreign bssl;
X509_STORE_CTX_new :: () -> *X509_STORE_CTX #foreign bssl;
X509_STORE_CTX_free :: (ctx: *X509_STORE_CTX) #foreign bssl;
X509_STORE_CTX_init :: (ctx: *X509_STORE_CTX, store: *X509_STORE, leaf: *X509, untrusted: *OPENSSL_STACK) -> s32 #foreign bssl;
X509_STORE_CTX_set_default :: (ctx: *X509_STORE_CTX, name: *u8) -> s32 #foreign bssl;
X509_STORE_CTX_get0_param :: (ctx: *X509_STORE_CTX) -> *X509_VERIFY_PARAM #foreign bssl;
X509_VERIFY_PARAM_set1_host :: (param: *X509_VERIFY_PARAM, name: *u8, name_len: u64) -> s32 #foreign bssl;
X509_verify_cert :: (ctx: *X509_STORE_CTX) -> s32 #foreign bssl;
OPENSSL_sk_new_null :: () -> *OPENSSL_STACK #foreign bssl;
OPENSSL_sk_push :: (sk: *OPENSSL_STACK, p: *void) -> u64 #foreign bssl;
OPENSSL_sk_free :: (sk: *OPENSSL_STACK) #foreign bssl;

// Debian/Ubuntu/Arch/Gentoo, Fedora/RHEL, openSUSE, Fedora's extracted bundle, Alpine/Void/LibreSSL.
CA_BUNDLES :: string.["/etc/ssl/certs/ca-certificates.crt", "/etc/pki/tls/certs/ca-bundle.crt", "/etc/ssl/ca-bundle.pem",
	"/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem", "/etc/ssl/cert.pem"];
CA_DIR :: "/etc/ssl/certs";

store_mu: locks.Mutex;
store_loaded: bool;
store: *X509_STORE;

// trust_store: the X509_STORE, shared by all threads once loaded (no roots found: every chain fails).
trust_store :: () -> *X509_STORE {
	locks.guard(*store_mu);
	if store_loaded return store;
	store_loaded = true;
	store = X509_STORE_new();
	if !store return null;
	file, dir := getenv("SSL_CERT_FILE"), getenv("SSL_CERT_DIR");
	if file X509_STORE_load_locations(store, file, null);
	else for CA_BUNDLES if X509_STORE_load_locations(store, temp_c_string(it), null) == 1 break;
	// a hashed directory (":"-separated list) is searched per verification
	X509_STORE_load_locations(store, null, ifx dir then dir else temp_c_string(CA_DIR));
	ERR_clear_error();
	return store;
}
