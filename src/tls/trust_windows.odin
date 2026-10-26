#+build windows
package tls

// Chain validation against the Windows trust store via CryptoAPI.
// Compiles for windows_amd64; not yet exercised on a real machine.

import win "core:sys/windows"

foreign import crypt32 "system:crypt32.lib"

@(private = "file")
X509_ASN_ENCODING :: 0x00000001
@(private = "file")
PKCS_7_ASN_ENCODING :: 0x00010000
@(private = "file")
CERT_STORE_PROV_MEMORY :: 2
@(private = "file")
CERT_STORE_ADD_ALWAYS :: 4
@(private = "file")
CERT_CHAIN_POLICY_SSL :: 4
@(private = "file")
AUTHTYPE_SERVER :: 2
@(private = "file")
USAGE_MATCH_TYPE_AND :: 0

@(private = "file")
CERT_ENHKEY_USAGE :: struct {
	cUsageIdentifier:     win.DWORD,
	rgpszUsageIdentifier: ^cstring,
}

@(private = "file")
CERT_USAGE_MATCH :: struct {
	dwType: win.DWORD,
	Usage:  CERT_ENHKEY_USAGE,
}

@(private = "file")
CERT_CHAIN_PARA :: struct {
	cbSize:         win.DWORD,
	RequestedUsage: CERT_USAGE_MATCH,
}

@(private = "file")
SSL_EXTRA_CERT_CHAIN_POLICY_PARA :: struct {
	cbSize:         win.DWORD,
	dwAuthType:     win.DWORD,
	fdwChecks:      win.DWORD,
	pwszServerName: win.LPWSTR,
}

@(private = "file")
CERT_CHAIN_POLICY_PARA :: struct {
	cbSize:            win.DWORD,
	dwFlags:           win.DWORD,
	pvExtraPolicyPara: rawptr,
}

@(private = "file")
CERT_CHAIN_POLICY_STATUS :: struct {
	cbSize:              win.DWORD,
	dwError:             win.DWORD,
	lChainIndex:         win.LONG,
	lElementIndex:       win.LONG,
	pvExtraPolicyStatus: rawptr,
}

@(private = "file", default_calling_convention = "system")
foreign crypt32 {
	CertOpenStore :: proc(provider: rawptr, encoding: win.DWORD, prov: rawptr, flags: win.DWORD, para: rawptr) -> win.HCERTSTORE ---
	CertCloseStore :: proc(store: win.HCERTSTORE, flags: win.DWORD) -> win.BOOL ---
	CertAddEncodedCertificateToStore :: proc(store: win.HCERTSTORE, encoding: win.DWORD, data: [^]byte, size: win.DWORD, disposition: win.DWORD, out: ^^win.CERT_CONTEXT) -> win.BOOL ---
	CertFreeCertificateContext :: proc(ctx: ^win.CERT_CONTEXT) -> win.BOOL ---
	CertGetCertificateChain :: proc(engine: rawptr, cert: ^win.CERT_CONTEXT, time: rawptr, store: win.HCERTSTORE, para: ^CERT_CHAIN_PARA, flags: win.DWORD, reserved: rawptr, chain: ^rawptr) -> win.BOOL ---
	CertVerifyCertificateChainPolicy :: proc(policy: rawptr, chain: rawptr, para: ^CERT_CHAIN_POLICY_PARA, status: ^CERT_CHAIN_POLICY_STATUS) -> win.BOOL ---
	CertFreeCertificateChain :: proc(chain: rawptr) ---
}

verify_chain_os :: proc(chain: [][]byte, host: string) -> Error {
	store := CertOpenStore(rawptr(uintptr(CERT_STORE_PROV_MEMORY)), 0, nil, 0, nil)
	if store == nil do return .Internal
	defer CertCloseStore(store, 0)

	leaf: ^win.CERT_CONTEXT
	defer if leaf != nil do CertFreeCertificateContext(leaf)
	for der, i in chain {
		ctx: ^win.CERT_CONTEXT
		enc :: X509_ASN_ENCODING | PKCS_7_ASN_ENCODING
		if !CertAddEncodedCertificateToStore(store, enc, raw_data(der), win.DWORD(len(der)), CERT_STORE_ADD_ALWAYS, &ctx) {
			return .Bad_Certificate
		}
		if i == 0 {
			leaf = ctx
		} else {
			CertFreeCertificateContext(ctx)
		}
	}

	server_auth := cstring("1.3.6.1.5.5.7.3.1")
	para := CERT_CHAIN_PARA {
		cbSize = size_of(CERT_CHAIN_PARA),
		RequestedUsage = {dwType = USAGE_MATCH_TYPE_AND, Usage = {1, &server_auth}},
	}
	chain_ctx: rawptr
	if !CertGetCertificateChain(nil, leaf, nil, store, &para, 0, nil, &chain_ctx) do return .Untrusted_Certificate
	defer CertFreeCertificateChain(chain_ctx)

	wide := win.utf8_to_wstring(host, context.temp_allocator)
	ssl := SSL_EXTRA_CERT_CHAIN_POLICY_PARA {
		cbSize         = size_of(SSL_EXTRA_CERT_CHAIN_POLICY_PARA),
		dwAuthType     = AUTHTYPE_SERVER,
		pwszServerName = cast(win.LPWSTR)wide,
	}
	ppara := CERT_CHAIN_POLICY_PARA {
		cbSize            = size_of(CERT_CHAIN_POLICY_PARA),
		pvExtraPolicyPara = &ssl,
	}
	status := CERT_CHAIN_POLICY_STATUS {
		cbSize = size_of(CERT_CHAIN_POLICY_STATUS),
	}
	policy := rawptr(uintptr(CERT_CHAIN_POLICY_SSL))
	if !CertVerifyCertificateChainPolicy(policy, chain_ctx, &ppara, &status) do return .Untrusted_Certificate
	return .None if status.dwError == 0 else .Untrusted_Certificate
}
