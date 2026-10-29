// SecureTransport, as security-framework 2.6 drives it for native-tls (ClientBuilder::ctx_into_stream and
// MidHandshakeClientBuilder::handshake): SNI, break on server auth, TLS 1.0 as the minimum (native-tls's
// default), the enabled ciphers read and set back, then the peer's trust evaluated with an SSL policy for the
// name (empty extra anchors, system anchors kept). The I/O callbacks behave like tokio's non-blocking socket:
// they block only when nothing has arrived yet and otherwise hand back what there is (errSSLWouldBlock).

Session :: struct {
	inner: netio.Stream;
	ctx: *void; // SSLContextRef
	jai_context: *#Context; // the callbacks run inside SSL* calls made from Jai
	in: In_Buffer;
}

os_connect :: (ss: *Session, host: string) -> Error {
	ss.ctx = SSLCreateContext(null, kSSLClientSide, kSSLStreamType);
	if !ss.ctx return .Unavailable;
	ctx := ss.ctx;
	ok := SSLSetPeerDomainName(ctx, host.data, xx host.count) == 0
		&& SSLSetSessionOption(ctx, kSSLSessionOptionBreakOnServerAuth, true) == 0
		&& SSLSetProtocolVersionMin(ctx, kTLSProtocol1) == 0;
	if ok {
		n: u64;
		ok = SSLGetNumberEnabledCiphers(ctx, *n) == 0 && n <= 1024;
		suites := NewArray(xx n, SSLCipherSuite,, temp);
		ok = ok && SSLGetEnabledCiphers(ctx, suites.data, *n) == 0 && SSLSetEnabledCiphers(ctx, suites.data, n) == 0;
	}
	ok = ok && SSLSetIOFuncs(ctx, st_read, st_write) == 0 && SSLSetConnection(ctx, ss) == 0;
	if !ok return .Unavailable;
	ss.jai_context = *context;
	while true {
		st := SSLHandshake(ctx);
		if st == 0 return .None;
		if st == errSSLWouldBlock continue;
		if st != errSSLPeerAuthCompleted return .Handshake;
		if !peer_trusted(ctx, host) return .Untrusted;
	}
	return .Handshake;
}

os_read :: (ss: *Session, dst: []u8) -> int, closed: bool {
	ss.jai_context = *context;
	while true {
		// security-framework reads at most what is buffered, so SSLRead never waits for more than one record
		buffered: u64;
		want := cast(u64) dst.count;
		if SSLGetBufferedReadSize(ss.ctx, *buffered) == 0 && buffered > 0 want = min(want, buffered);
		n: u64;
		st := SSLRead(ss.ctx, dst.data, want, *n);
		if n > 0 return xx n, false;
		if st == errSSLWouldBlock continue;
		return 0, st == errSSLClosedGraceful || st == errSSLClosedNoNotify || st == errSSLClosedAbort;
	}
	return 0, false;
}

os_write :: (ss: *Session, src: []u8) -> bool {
	ss.jai_context = *context;
	done := 0;
	while done < src.count {
		n: u64;
		st := SSLWrite(ss.ctx, src.data + done, xx (src.count - done), *n);
		done += cast(int) n;
		if st != 0 && st != errSSLWouldBlock return false;
	}
	return true;
}

os_free :: (ss: *Session) { if ss.ctx CFRelease(ss.ctx); }

#scope_file

// peer_trusted: SecTrustSetAnchorCertificates (none) + AnchorCertificatesOnly(false), the SSL policy for host,
// then SecTrustEvaluate, whose Proceed or Unspecified result is a pass (security-framework's evaluate_with_error).
peer_trusted :: (ctx: *void, host: string) -> bool {
	trust: *void;
	if SSLCopyPeerTrust(ctx, *trust) != 0 || !trust return false;
	defer CFRelease(trust);
	anchors := CFArrayCreate(null, null, 0, *kCFTypeArrayCallBacks);
	if !anchors return false;
	defer CFRelease(anchors);
	hs := CFStringCreateWithBytes(null, host.data, host.count, kCFStringEncodingUTF8, false);
	if !hs return false;
	defer CFRelease(hs);
	policy := SecPolicyCreateSSL(true, hs);
	if !policy return false;
	defer CFRelease(policy);
	if SecTrustSetAnchorCertificates(trust, anchors) != 0 || SecTrustSetAnchorCertificatesOnly(trust, false) != 0 || SecTrustSetPolicies(trust, policy) != 0 return false;
	result: u32;
	if SecTrustEvaluate(trust, *result) != 0 return false;
	return result == kSecTrustResultProceed || result == kSecTrustResultUnspecified;
}

st_read :: (conn: *void, data: *void, len: *u64) -> s32 #c_call {
	ss := cast(*Session) conn;
	want := cast(int) len.*;
	got := 0;
	eof := false;
	push_context ss.jai_context.* {
		while got < want {
			if ss.in.next == ss.in.end {
				if got > 0 break;
				if !fill_from(*ss.in, ss.inner) { eof = true; break; }
			}
			got += take(*ss.in, cast(*u8) data + got, want - got);
		}
	}
	len.* = xx got;
	if eof return errSSLClosedNoNotify;
	return ifx got < want then errSSLWouldBlock else 0;
}

st_write :: (conn: *void, data: *void, len: *u64) -> s32 #c_call {
	ss := cast(*Session) conn;
	err: netio.Error;
	push_context ss.jai_context.* { err = netio.write(ss.inner, .{cast(s64) len.*, cast(*u8) data}); }
	if err == .None return 0;
	len.* = 0;
	return errSSLClosedAbort;
}

#if CPU == .ARM64 SSLCipherSuite :: u16; else SSLCipherSuite :: u32;
kSSLClientSide :: 1;
kSSLStreamType :: 0;
kSSLSessionOptionBreakOnServerAuth :: 0;
kTLSProtocol1 :: 4;
errSSLWouldBlock : s32 : -9803;
errSSLClosedGraceful : s32 : -9805;
errSSLClosedAbort : s32 : -9806;
errSSLClosedNoNotify : s32 : -9816;
errSSLPeerAuthCompleted : s32 : -9841;
kSecTrustResultProceed :: 1;
kSecTrustResultUnspecified :: 4;
kCFStringEncodingUTF8 :: 0x08000100;

corefoundation :: #library,system,link_always "CoreFoundation";
sec :: #library,system,link_always "Security";

CFArrayCallBacks :: struct { version: int; retain, release, copyDescription, equal: *void; }
kCFTypeArrayCallBacks: CFArrayCallBacks #elsewhere corefoundation;
CFArrayCreate :: (alloc: *void, values: **void, num: int, callbacks: *CFArrayCallBacks) -> *void #foreign corefoundation;
CFStringCreateWithBytes :: (alloc: *void, bytes: *u8, num: int, encoding: u32, external: bool) -> *void #foreign corefoundation;
CFRelease :: (cf: *void) #foreign corefoundation;

SSLReadWrite :: #type (conn: *void, data: *void, len: *u64) -> s32 #c_call;
SSLCreateContext :: (alloc: *void, side: s32, kind: s32) -> *void #foreign sec;
SSLSetPeerDomainName :: (ctx: *void, name: *u8, len: u64) -> s32 #foreign sec;
SSLSetSessionOption :: (ctx: *void, option: s32, value: bool) -> s32 #foreign sec;
SSLSetProtocolVersionMin :: (ctx: *void, version: s32) -> s32 #foreign sec;
SSLGetNumberEnabledCiphers :: (ctx: *void, n: *u64) -> s32 #foreign sec;
SSLGetEnabledCiphers :: (ctx: *void, suites: *SSLCipherSuite, n: *u64) -> s32 #foreign sec;
SSLSetEnabledCiphers :: (ctx: *void, suites: *SSLCipherSuite, n: u64) -> s32 #foreign sec;
SSLSetIOFuncs :: (ctx: *void, read: SSLReadWrite, write: SSLReadWrite) -> s32 #foreign sec;
SSLSetConnection :: (ctx: *void, conn: *void) -> s32 #foreign sec;
SSLHandshake :: (ctx: *void) -> s32 #foreign sec;
SSLCopyPeerTrust :: (ctx: *void, trust: **void) -> s32 #foreign sec;
SSLGetBufferedReadSize :: (ctx: *void, size: *u64) -> s32 #foreign sec;
SSLRead :: (ctx: *void, data: *void, len: u64, processed: *u64) -> s32 #foreign sec;
SSLWrite :: (ctx: *void, data: *void, len: u64, processed: *u64) -> s32 #foreign sec;
SecPolicyCreateSSL :: (server: bool, hostname: *void) -> *void #foreign sec;
SecTrustSetAnchorCertificates :: (trust: *void, anchors: *void) -> s32 #foreign sec;
SecTrustSetAnchorCertificatesOnly :: (trust: *void, only: bool) -> s32 #foreign sec;
SecTrustSetPolicies :: (trust: *void, policies: *void) -> s32 #foreign sec;
SecTrustEvaluate :: (trust: *void, result: *u32) -> s32 #foreign sec;
