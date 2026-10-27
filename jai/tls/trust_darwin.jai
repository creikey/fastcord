// verify_chain_os evaluates leaf + intermediates with an SSL server policy for host (Security.framework).
verify_chain_os :: (chain: [][]u8, host: string) -> Error {
	certs: [16]CFTypeRef;
	n := 0;
	defer for i: 0..n-1 CFRelease(certs[i]);
	for der: chain {
		if n == certs.count break;
		data := CFDataCreate(null, der.data, der.count);
		if !data return .Internal;
		c := SecCertificateCreateWithData(null, data);
		CFRelease(data);
		if !c return .Bad_Certificate;
		certs[n] = c;
		n += 1;
	}
	arr := CFArrayCreate(null, certs.data, n, *kCFTypeArrayCallBacks);
	if !arr return .Internal;
	defer CFRelease(arr);
	hs := CFStringCreateWithBytes(null, host.data, host.count, kCFStringEncodingUTF8, false);
	if !hs return .Internal;
	defer CFRelease(hs);
	policy := SecPolicyCreateSSL(true, hs);
	if !policy return .Internal;
	defer CFRelease(policy);
	trust: CFTypeRef;
	if SecTrustCreateWithCertificates(arr, policy, *trust) != 0 || !trust return .Internal;
	defer CFRelease(trust);
	cferr: CFTypeRef;
	ok := SecTrustEvaluateWithError(trust, *cferr);
	if cferr CFRelease(cferr);
	return ifx ok then .None else .Untrusted_Certificate;
}

#scope_file

corefoundation :: #library,system,link_always "CoreFoundation";
sec :: #library,system,link_always "Security";

CFTypeRef :: *void;
CFArrayCallBacks :: struct {
	version: int;
	retain, release, copyDescription, equal: *void;
}
kCFStringEncodingUTF8 :: 0x08000100;

kCFTypeArrayCallBacks: CFArrayCallBacks #elsewhere corefoundation;
CFDataCreate :: (alloc: CFTypeRef, bytes: *u8, length: int) -> CFTypeRef #foreign corefoundation;
CFArrayCreate :: (alloc: CFTypeRef, values: *CFTypeRef, num: int, callbacks: *CFArrayCallBacks) -> CFTypeRef #foreign corefoundation;
CFStringCreateWithBytes :: (alloc: CFTypeRef, bytes: *u8, num: int, encoding: u32, external: bool) -> CFTypeRef #foreign corefoundation;
CFRelease :: (cf: CFTypeRef) #foreign corefoundation;
SecCertificateCreateWithData :: (alloc: CFTypeRef, data: CFTypeRef) -> CFTypeRef #foreign sec;
SecPolicyCreateSSL :: (server: bool, hostname: CFTypeRef) -> CFTypeRef #foreign sec;
SecTrustCreateWithCertificates :: (certs: CFTypeRef, policies: CFTypeRef, trust: *CFTypeRef) -> s32 #foreign sec;
SecTrustEvaluateWithError :: (trust: CFTypeRef, error: *CFTypeRef) -> bool #foreign sec;
