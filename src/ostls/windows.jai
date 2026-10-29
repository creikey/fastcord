// SChannel through SSPI, as schannel-rs 0.1 drives it for native-tls: an SCHANNEL_CRED with TLS 1.0-1.2
// (native-tls's minimum TLS 1.0, no maximum), SCH_USE_STRONG_CRYPTO and SCH_CRED_NO_DEFAULT_CREDS from
// AcquireCredentialsHandleA, then InitializeSecurityContextW with the target name as SNI and manual
// certificate validation, done after the handshake as schannel-rs's TlsStream::validate does it.

Session :: struct {
	inner: netio.Stream;
	cred, ctx: SecHandle;
	have_cred, have_ctx: bool;
	sizes: SecPkgContext_StreamSizes;
	enc: [..]u8; // received, not decrypted yet
	dec: [..]u8; // decrypted, not read yet, from dec_next
	dec_next: int;
}

os_connect :: (ss: *Session, host: string) -> Error {
	cd := SCHANNEL_CRED.{dwVersion = SCHANNEL_CRED_VERSION, grbitEnabledProtocols = SP_PROT_TLS1_0_CLIENT | SP_PROT_TLS1_1_CLIENT | SP_PROT_TLS1_2_CLIENT, dwFlags = SCH_USE_STRONG_CRYPTO | SCH_CRED_NO_DEFAULT_CREDS};
	if AcquireCredentialsHandleA(null, UNISP_NAME_A.data, SECPKG_CRED_OUTBOUND, null, *cd, null, null, *ss.cred, null) != 0 return .Unavailable;
	ss.have_cred = true;
	name := utf8_to_wide(host,, temp);
	attrs: u32;
	first := SecBuffer.{0, SECBUFFER_EMPTY, null};
	first_desc := SecBufferDesc.{SECBUFFER_VERSION, 1, *first};
	if InitializeSecurityContextW(*ss.cred, null, name, ISC_FLAGS, 0, 0, null, 0, *ss.ctx, *first_desc, *attrs, null) != SEC_I_CONTINUE_NEEDED return .Handshake;
	ss.have_ctx = true;
	if !send_token(ss, *first) return .Handshake;
	need_read := true;
	while true {
		if need_read && !read_more(ss) return .Handshake;
		in := SecBuffer.[.{xx ss.enc.count, SECBUFFER_TOKEN, ss.enc.data}, .{0, SECBUFFER_EMPTY, null}];
		out := SecBuffer.[.{0, SECBUFFER_TOKEN, null}, .{0, SECBUFFER_ALERT, null}, .{0, SECBUFFER_EMPTY, null}];
		in_desc := SecBufferDesc.{SECBUFFER_VERSION, 2, in.data};
		out_desc := SecBufferDesc.{SECBUFFER_VERSION, 3, out.data};
		st := InitializeSecurityContextW(*ss.cred, *ss.ctx, name, ISC_FLAGS, 0, 0, *in_desc, 0, null, *out_desc, *attrs, null);
		if out[1].pvBuffer FreeContextBuffer(out[1].pvBuffer);
		if st == SEC_E_INCOMPLETE_MESSAGE {
			if out[0].pvBuffer FreeContextBuffer(out[0].pvBuffer);
			need_read = true;
			continue;
		}
		if !send_token(ss, *out[0]) return .Handshake;
		if st != SEC_E_OK && st != SEC_I_CONTINUE_NEEDED return .Handshake;
		extra := ifx in[1].BufferType == SECBUFFER_EXTRA then cast(int) in[1].cbBuffer else 0;
		keep_tail(*ss.enc, extra);
		if st == SEC_E_OK break;
		need_read = extra == 0;
	}
	if !validate(ss, name) return .Untrusted;
	if QueryContextAttributesW(*ss.ctx, SECPKG_ATTR_STREAM_SIZES, *ss.sizes) != 0 return .Handshake;
	return .None;
}

os_read :: (ss: *Session, dst: []u8) -> int, closed: bool {
	while ss.dec_next >= ss.dec.count {
		ss.dec.count, ss.dec_next = 0, 0;
		if !ss.enc.count && !read_more(ss) return 0, true;
		b := SecBuffer.[.{xx ss.enc.count, SECBUFFER_DATA, ss.enc.data}, .{0, SECBUFFER_EMPTY, null}, .{0, SECBUFFER_EMPTY, null}, .{0, SECBUFFER_EMPTY, null}];
		desc := SecBufferDesc.{SECBUFFER_VERSION, 4, b.data};
		st := DecryptMessage(*ss.ctx, *desc, 0, null);
		if st == SEC_E_INCOMPLETE_MESSAGE {
			if !read_more(ss) return 0, true;
			continue;
		}
		if st == SEC_I_CONTEXT_EXPIRED return 0, true; // close_notify
		if st != SEC_E_OK return 0, false;
		extra := 0;
		for b {
			if it.BufferType == SECBUFFER_DATA array_add(*ss.dec, ..[]u8.{it.cbBuffer, it.pvBuffer});
			if it.BufferType == SECBUFFER_EXTRA extra = xx it.cbBuffer;
		}
		keep_tail(*ss.enc, extra); // decrypted in place: what is left is the tail
	}
	n := min(dst.count, ss.dec.count - ss.dec_next);
	memcpy(dst.data, ss.dec.data + ss.dec_next, n);
	ss.dec_next += n;
	return n, false;
}

os_write :: (ss: *Session, src: []u8) -> bool {
	rest := src;
	while rest.count {
		n := min(rest.count, cast(int) ss.sizes.cbMaximumMessage);
		buf := NewArray(ss.sizes.cbHeader + n + ss.sizes.cbTrailer, u8,, temp);
		memcpy(buf.data + ss.sizes.cbHeader, rest.data, n);
		b := SecBuffer.[
			.{ss.sizes.cbHeader, SECBUFFER_STREAM_HEADER, buf.data},
			.{xx n, SECBUFFER_DATA, buf.data + ss.sizes.cbHeader},
			.{ss.sizes.cbTrailer, SECBUFFER_STREAM_TRAILER, buf.data + ss.sizes.cbHeader + n},
			.{0, SECBUFFER_EMPTY, null}];
		desc := SecBufferDesc.{SECBUFFER_VERSION, 4, b.data};
		if EncryptMessage(*ss.ctx, 0, *desc, 0) != SEC_E_OK return false;
		if netio.write(ss.inner, array_view(buf, 0, b[0].cbBuffer + b[1].cbBuffer + b[2].cbBuffer)) != .None return false;
		rest.data += n; rest.count -= n;
	}
	return true;
}

os_free :: (ss: *Session) {
	if ss.have_ctx DeleteSecurityContext(*ss.ctx);
	if ss.have_cred FreeCredentialsHandle(*ss.cred);
	array_free(ss.enc);
	array_free(ss.dec);
}

#scope_file

#import "Windows_Utf8";

MAX_RECORD_BUFFER :: 1 << 17;

read_more :: (ss: *Session) -> bool {
	if ss.enc.count >= MAX_RECORD_BUFFER return false;
	tmp: [READ_CHUNK]u8 = ---;
	n, err := netio.read(ss.inner, tmp);
	if err != .None || n <= 0 return false;
	array_add(*ss.enc, ..array_view(tmp, 0, n));
	return true;
}

// keep_tail keeps the last n bytes of b (SECBUFFER_EXTRA: input SSPI did not consume).
keep_tail :: (b: *[..]u8, n: int) {
	if n <= 0 || n > b.count { b.count = 0; return; }
	for i: 0..n-1 b.data[i] = b.data[b.count - n + i]; // forward: the regions may overlap
	b.count = n;
}

send_token :: (ss: *Session, b: *SecBuffer) -> bool {
	if !b.pvBuffer return true;
	defer FreeContextBuffer(b.pvBuffer);
	if !b.cbBuffer return true;
	return netio.write(ss.inner, []u8.{b.cbBuffer, b.pvBuffer}) == .None;
}

// validate: schannel-rs's TlsStream::validate. The chain is built from the server's certificate and the
// certificates it sent (CERT_CHAIN_CACHE_END_CERT, revocation from the cache only, root excluded; usage
// server auth or either server-gated-crypto OID), then checked with the SSL policy for the name.
validate :: (ss: *Session, name: *u16) -> bool {
	cert: *CERT_CONTEXT;
	if QueryContextAttributesW(*ss.ctx, SECPKG_ATTR_REMOTE_CERT_CONTEXT, *cert) != 0 || !cert return false;
	defer CertFreeCertificateContext(cert);
	usages := (*u8).["1.3.6.1.5.5.7.3.1".data, "1.3.6.1.4.1.311.10.3.3".data, "2.16.840.1.113730.4.1".data];
	para := CERT_CHAIN_PARA.{cbSize = size_of(CERT_CHAIN_PARA), RequestedUsage = .{dwType = USAGE_MATCH_TYPE_OR, Usage = .{xx usages.count, usages.data}}};
	chain: *void;
	flags :: CERT_CHAIN_CACHE_END_CERT | CERT_CHAIN_REVOCATION_CHECK_CACHE_ONLY | CERT_CHAIN_REVOCATION_CHECK_CHAIN_EXCLUDE_ROOT;
	if !CertGetCertificateChain(null, cert, null, cert.hCertStore, *para, flags, null, *chain) return false;
	defer CertFreeCertificateChain(chain);
	ssl := SSL_EXTRA_CERT_CHAIN_POLICY_PARA.{cbSize = size_of(SSL_EXTRA_CERT_CHAIN_POLICY_PARA), dwAuthType = AUTHTYPE_SERVER, pwszServerName = name};
	ppara := CERT_CHAIN_POLICY_PARA.{cbSize = size_of(CERT_CHAIN_POLICY_PARA), pvExtraPolicyPara = *ssl};
	status := CERT_CHAIN_POLICY_STATUS.{cbSize = size_of(CERT_CHAIN_POLICY_STATUS)};
	if !CertVerifyCertificateChainPolicy(cast(*void) CERT_CHAIN_POLICY_SSL, chain, *ppara, *status) return false;
	return status.dwError == 0;
}

secur32 :: #system_library "secur32";
crypt32 :: #system_library "crypt32";

UNISP_NAME_A :: "Microsoft Unified Security Protocol Provider\0";
SECPKG_CRED_OUTBOUND :: 2;
SCHANNEL_CRED_VERSION :: 4;
SP_PROT_TLS1_0_CLIENT :: 0x80;
SP_PROT_TLS1_1_CLIENT :: 0x200;
SP_PROT_TLS1_2_CLIENT :: 0x800;
SCH_CRED_NO_DEFAULT_CREDS :: 0x10;
SCH_USE_STRONG_CRYPTO :: 0x00400000;
// schannel-rs INIT_REQUESTS: confidentiality, integrity, replay and sequence detection, manual certificate
// validation, SSPI-allocated output, stream mode, supplied credentials only
ISC_FLAGS :: 0x10 | 0x10000 | 0x4 | 0x8 | 0x80000 | 0x100 | 0x8000 | 0x80;
SECBUFFER_VERSION :: 0;
SECBUFFER_EMPTY :: 0;
SECBUFFER_DATA :: 1;
SECBUFFER_TOKEN :: 2;
SECBUFFER_EXTRA :: 5;
SECBUFFER_STREAM_TRAILER :: 6;
SECBUFFER_STREAM_HEADER :: 7;
SECBUFFER_ALERT :: 17;
SECPKG_ATTR_STREAM_SIZES :: 4;
SECPKG_ATTR_REMOTE_CERT_CONTEXT :: 0x53;
SEC_E_OK : s32 : 0;
SEC_I_CONTINUE_NEEDED : s32 : 0x00090312;
SEC_I_CONTEXT_EXPIRED : s32 : 0x00090317;
SEC_E_INCOMPLETE_MESSAGE : s32 : cast,no_check(s32) 0x80090318;
CERT_CHAIN_POLICY_SSL :: 4;
AUTHTYPE_SERVER :: 2;
USAGE_MATCH_TYPE_OR :: 1;
CERT_CHAIN_CACHE_END_CERT :: 0x1;
CERT_CHAIN_REVOCATION_CHECK_CACHE_ONLY :: 0x80000000;
CERT_CHAIN_REVOCATION_CHECK_CHAIN_EXCLUDE_ROOT :: 0x40000000;

SecHandle :: struct { lower, upper: u64; }
SecBuffer :: struct { cbBuffer: u32; BufferType: u32; pvBuffer: *void; }
SecBufferDesc :: struct { ulVersion: u32; cBuffers: u32; pBuffers: *SecBuffer; }
SecPkgContext_StreamSizes :: struct { cbHeader, cbTrailer, cbMaximumMessage, cBuffers, cbBlockSize: u32; }
SCHANNEL_CRED :: struct {
	dwVersion: u32;
	cCreds: u32;
	paCred: *void;
	hRootStore: *void;
	cMappers: u32;
	aphMappers: *void;
	cSupportedAlgs: u32;
	palgSupportedAlgs: *u32;
	grbitEnabledProtocols: u32;
	dwMinimumCipherStrength: u32;
	dwMaximumCipherStrength: u32;
	dwSessionLifespan: u32;
	dwFlags: u32;
	dwCredFormat: u32;
}
CERT_CONTEXT :: struct { dwCertEncodingType: u32; pbCertEncoded: *u8; cbCertEncoded: u32; pCertInfo: *void; hCertStore: *void; }
CERT_ENHKEY_USAGE :: struct { cUsageIdentifier: u32; rgpszUsageIdentifier: **u8; }
CERT_USAGE_MATCH :: struct { dwType: u32; Usage: CERT_ENHKEY_USAGE; }
CERT_CHAIN_PARA :: struct {
	cbSize: u32;
	RequestedUsage: CERT_USAGE_MATCH;
	RequestedIssuancePolicy: CERT_USAGE_MATCH;
	dwUrlRetrievalTimeout: u32;
	fCheckRevocationFreshnessTime: s32;
	dwRevocationFreshnessTime: u32;
	pftCacheResync: *void;
}
SSL_EXTRA_CERT_CHAIN_POLICY_PARA :: struct { cbSize, dwAuthType, fdwChecks: u32; pwszServerName: *u16; }
CERT_CHAIN_POLICY_PARA :: struct { cbSize, dwFlags: u32; pvExtraPolicyPara: *void; }
CERT_CHAIN_POLICY_STATUS :: struct { cbSize, dwError: u32; lChainIndex, lElementIndex: s32; pvExtraPolicyStatus: *void; }

AcquireCredentialsHandleA :: (principal: *u8, package: *u8, use: u32, logon_id: *void, auth_data: *void, get_key: *void, get_key_arg: *void, cred: *SecHandle, expiry: *s64) -> s32 #foreign secur32;
InitializeSecurityContextW :: (cred: *SecHandle, ctx: *SecHandle, target: *u16, req: u32, reserved1: u32, rep: u32, input: *SecBufferDesc, reserved2: u32, new_ctx: *SecHandle, output: *SecBufferDesc, attrs: *u32, expiry: *s64) -> s32 #foreign secur32;
DeleteSecurityContext :: (ctx: *SecHandle) -> s32 #foreign secur32;
FreeCredentialsHandle :: (cred: *SecHandle) -> s32 #foreign secur32;
FreeContextBuffer :: (p: *void) -> s32 #foreign secur32;
QueryContextAttributesW :: (ctx: *SecHandle, attr: u32, buf: *void) -> s32 #foreign secur32;
EncryptMessage :: (ctx: *SecHandle, qop: u32, msg: *SecBufferDesc, seq: u32) -> s32 #foreign secur32;
DecryptMessage :: (ctx: *SecHandle, msg: *SecBufferDesc, seq: u32, qop: *u32) -> s32 #foreign secur32;
CertFreeCertificateContext :: (ctx: *CERT_CONTEXT) -> s32 #foreign crypt32;
CertGetCertificateChain :: (engine: *void, cert: *CERT_CONTEXT, time: *void, store: *void, para: *CERT_CHAIN_PARA, flags: u32, reserved: *void, chain: **void) -> s32 #foreign crypt32;
CertVerifyCertificateChainPolicy :: (policy: *void, chain: *void, para: *CERT_CHAIN_POLICY_PARA, status: *CERT_CHAIN_POLICY_STATUS) -> s32 #foreign crypt32;
CertFreeCertificateChain :: (chain: *void) #foreign crypt32;
