// Chain validation against the Windows trust store via CryptoAPI.
// Compiles for windows_amd64; not yet exercised on a real machine.


#scope_file

X509_ASN_ENCODING :: 0x00000001;
PKCS_7_ASN_ENCODING :: 0x00010000;
CERT_STORE_PROV_MEMORY :: 2;
CERT_STORE_ADD_ALWAYS :: 4;
CERT_CHAIN_POLICY_SSL :: 4;
AUTHTYPE_SERVER :: 2;
USAGE_MATCH_TYPE_AND :: 0;

CERT_ENHKEY_USAGE :: struct {
	cUsageIdentifier: win.DWORD;
	rgpszUsageIdentifier: **u8;
}

CERT_USAGE_MATCH :: struct {
	dwType: win.DWORD;
	Usage: CERT_ENHKEY_USAGE;
}

CERT_CHAIN_PARA :: struct {
	cbSize: win.DWORD;
	RequestedUsage: CERT_USAGE_MATCH;
}

SSL_EXTRA_CERT_CHAIN_POLICY_PARA :: struct {
	cbSize: win.DWORD;
	dwAuthType: win.DWORD;
	fdwChecks: win.DWORD;
	pwszServerName: win.LPWSTR;
}

CERT_CHAIN_POLICY_PARA :: struct {
	cbSize: win.DWORD;
	dwFlags: win.DWORD;
	pvExtraPolicyPara: *void;
}

CERT_CHAIN_POLICY_STATUS :: struct {
	cbSize: win.DWORD;
	dwError: win.DWORD;
	lChainIndex: win.LONG;
	lElementIndex: win.LONG;
	pvExtraPolicyStatus: *void;
}
	CertOpenStore :: (provider: *void, encoding: win.DWORD, prov: *void, flags: win.DWORD, para: *void) -> win.HCERTSTORE #foreign crypt32;
	CertCloseStore :: (store: win.HCERTSTORE, flags: win.DWORD) -> win.BOOL #foreign crypt32;
	CertAddEncodedCertificateToStore :: (store: win.HCERTSTORE, encoding: win.DWORD, data: *u8, size: win.DWORD, disposition: win.DWORD, out: **win.CERT_CONTEXT) -> win.BOOL #foreign crypt32;
	CertFreeCertificateContext :: (ctx: *win.CERT_CONTEXT) -> win.BOOL #foreign crypt32;
	CertGetCertificateChain :: (engine: *void, cert: *win.CERT_CONTEXT, time: *void, store: win.HCERTSTORE, para: *CERT_CHAIN_PARA, flags: win.DWORD, reserved: *void, chain: **void) -> win.BOOL #foreign crypt32;
	CertVerifyCertificateChainPolicy :: (policy: *void, chain: *void, para: *CERT_CHAIN_POLICY_PARA, status: *CERT_CHAIN_POLICY_STATUS) -> win.BOOL #foreign crypt32;
	CertFreeCertificateChain :: (chain: *void) #foreign crypt32;
#scope_export

verify_chain_os :: (chain: [][]u8, host: string) -> Error {
	store := CertOpenStore(cast(*void)(cast(u64)(CERT_STORE_PROV_MEMORY)), 0, null, 0, null);
	if store == null { return .Internal; }
	defer CertCloseStore(store, 0);

	leaf: *win.CERT_CONTEXT;
	defer if leaf != null { CertFreeCertificateContext(leaf); }
	for der, i: chain {
		ctx: *win.CERT_CONTEXT;
		enc :: X509_ASN_ENCODING | PKCS_7_ASN_ENCODING;
		if !CertAddEncodedCertificateToStore(store, enc, raw_data(der), win.DWORD(len(der)), CERT_STORE_ADD_ALWAYS, *ctx) {
			return .Bad_Certificate;
		}
		if i == 0 {
			leaf = ctx;
		} else {
			CertFreeCertificateContext(ctx);
		}
	}

	server_auth := to_cstring("1.3.6.1.5.5.7.3.1");
	para := CERT_CHAIN_PARA.{
		cbSize = size_of(CERT_CHAIN_PARA),
		RequestedUsage = .{dwType = USAGE_MATCH_TYPE_AND, Usage = .{1, *server_auth}}
	};
	chain_ctx: *void;
	if !CertGetCertificateChain(null, leaf, null, store, *para, 0, null, *chain_ctx) { return .Untrusted_Certificate; }
	defer CertFreeCertificateChain(chain_ctx);

	wide := win.utf8_to_wstring(host, temp);
	ssl := SSL_EXTRA_CERT_CHAIN_POLICY_PARA.{
		cbSize = size_of(SSL_EXTRA_CERT_CHAIN_POLICY_PARA),
		dwAuthType = AUTHTYPE_SERVER,
		pwszServerName = cast(win.LPWSTR)wide
	};
	ppara := CERT_CHAIN_POLICY_PARA.{
		cbSize = size_of(CERT_CHAIN_POLICY_PARA),
		pvExtraPolicyPara = *ssl
	};
	status := CERT_CHAIN_POLICY_STATUS.{
		cbSize = size_of(CERT_CHAIN_POLICY_STATUS)
	};
	policy := cast(*void)(cast(u64)(CERT_CHAIN_POLICY_SSL));
	if !CertVerifyCertificateChainPolicy(policy, chain_ctx, *ppara, *status) { return .Untrusted_Certificate; }
	return ifx status.dwError == 0 then .None else .Untrusted_Certificate;
}

