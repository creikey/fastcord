// Chain validation against the Windows trust store via CryptoAPI. Not yet exercised on a real machine.
verify_chain_os :: (chain: [][]u8, host: string) -> Error {
	store := CertOpenStore(cast(*void) CERT_STORE_PROV_MEMORY, 0, null, 0, null);
	if !store return .Internal;
	defer CertCloseStore(store, 0);

	leaf: *CERT_CONTEXT;
	defer if leaf CertFreeCertificateContext(leaf);
	for der, i: chain {
		ctx: *CERT_CONTEXT;
		if !CertAddEncodedCertificateToStore(store, X509_ASN_ENCODING | PKCS_7_ASN_ENCODING, der.data, xx der.count, CERT_STORE_ADD_ALWAYS, *ctx) return .Bad_Certificate;
		if i == 0 leaf = ctx;
		else CertFreeCertificateContext(ctx);
	}

	server_auth := "1.3.6.1.5.5.7.3.1".data;
	para := CERT_CHAIN_PARA.{cbSize = size_of(CERT_CHAIN_PARA), RequestedUsage = .{dwType = USAGE_MATCH_TYPE_AND, Usage = .{1, *server_auth}}};
	chain_ctx: *void;
	if !CertGetCertificateChain(null, leaf, null, store, *para, 0, null, *chain_ctx) return .Untrusted_Certificate;
	defer CertFreeCertificateChain(chain_ctx);

	wide := utf8_to_wide(host,, temp);
	ssl := SSL_EXTRA_CERT_CHAIN_POLICY_PARA.{cbSize = size_of(SSL_EXTRA_CERT_CHAIN_POLICY_PARA), dwAuthType = AUTHTYPE_SERVER, pwszServerName = wide};
	ppara := CERT_CHAIN_POLICY_PARA.{cbSize = size_of(CERT_CHAIN_POLICY_PARA), pvExtraPolicyPara = *ssl};
	status := CERT_CHAIN_POLICY_STATUS.{cbSize = size_of(CERT_CHAIN_POLICY_STATUS)};
	if !CertVerifyCertificateChainPolicy(cast(*void) CERT_CHAIN_POLICY_SSL, chain_ctx, *ppara, *status) return .Untrusted_Certificate;
	return ifx status.dwError == 0 then .None else .Untrusted_Certificate;
}

#scope_file

#import "Windows_Utf8";
crypt32 :: #system_library "crypt32";

X509_ASN_ENCODING :: 0x00000001;
PKCS_7_ASN_ENCODING :: 0x00010000;
CERT_STORE_PROV_MEMORY :: 2;
CERT_STORE_ADD_ALWAYS :: 4;
CERT_CHAIN_POLICY_SSL :: 4;
AUTHTYPE_SERVER :: 2;
USAGE_MATCH_TYPE_AND :: 0;

CERT_CONTEXT :: struct {}
CERT_ENHKEY_USAGE :: struct { cUsageIdentifier: u32; rgpszUsageIdentifier: **u8; }
CERT_USAGE_MATCH :: struct { dwType: u32; Usage: CERT_ENHKEY_USAGE; }
CERT_CHAIN_PARA :: struct { cbSize: u32; RequestedUsage: CERT_USAGE_MATCH; }
SSL_EXTRA_CERT_CHAIN_POLICY_PARA :: struct { cbSize, dwAuthType, fdwChecks: u32; pwszServerName: *u16; }
CERT_CHAIN_POLICY_PARA :: struct { cbSize, dwFlags: u32; pvExtraPolicyPara: *void; }
CERT_CHAIN_POLICY_STATUS :: struct { cbSize, dwError: u32; lChainIndex, lElementIndex: s32; pvExtraPolicyStatus: *void; }

CertOpenStore :: (provider: *void, encoding: u32, prov: *void, flags: u32, para: *void) -> *void #foreign crypt32;
CertCloseStore :: (store: *void, flags: u32) -> s32 #foreign crypt32;
CertAddEncodedCertificateToStore :: (store: *void, encoding: u32, data: *u8, size: u32, disposition: u32, out: **CERT_CONTEXT) -> s32 #foreign crypt32;
CertFreeCertificateContext :: (ctx: *CERT_CONTEXT) -> s32 #foreign crypt32;
CertGetCertificateChain :: (engine: *void, cert: *CERT_CONTEXT, time: *void, store: *void, para: *CERT_CHAIN_PARA, flags: u32, reserved: *void, chain: **void) -> s32 #foreign crypt32;
CertVerifyCertificateChainPolicy :: (policy: *void, chain: *void, para: *CERT_CHAIN_POLICY_PARA, status: *CERT_CHAIN_POLICY_STATUS) -> s32 #foreign crypt32;
CertFreeCertificateChain :: (chain: *void) #foreign crypt32;
