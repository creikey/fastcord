#scope_file

CFTypeRef :: *void;

CFArrayCallBacks :: struct {
	version: int;
	retain: *void;
	release: *void;
	copyDescription: *void;
	equal: *void;
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
#scope_export

// verify_chain_os evaluates leaf + intermediates with an SSL server policy for host.
verify_chain_os :: (chain: [][]u8, host: string) -> Error {
	certs: [16]CFTypeRef;
	n := 0;
	defer for i: 0..n-1 { CFRelease(certs[i]); }
	for der: chain {
		if n == len(certs) { break; }
		data := CFDataCreate(null, raw_data(der), len(der));
		if data == null { return .Internal; }
		c := SecCertificateCreateWithData(null, data);
		CFRelease(data);
		if c == null { return .Bad_Certificate; }
		certs[n] = c;
		n += 1;
	}
	arr := CFArrayCreate(null, *certs[0], n, *kCFTypeArrayCallBacks);
	if arr == null { return .Internal; }
	defer CFRelease(arr);

	hs := CFStringCreateWithBytes(null, raw_data(host), len(host), kCFStringEncodingUTF8, false);
	if hs == null { return .Internal; }
	defer CFRelease(hs);
	policy := SecPolicyCreateSSL(true, hs);
	if policy == null { return .Internal; }
	defer CFRelease(policy);

	trust: CFTypeRef;
	if SecTrustCreateWithCertificates(arr, policy, *trust) != 0 || trust == null { return .Internal; }
	defer CFRelease(trust);
	cferr: CFTypeRef;
	ok := SecTrustEvaluateWithError(trust, *cferr);
	if cferr != null { CFRelease(cferr); }
	return ifx ok then .None else .Untrusted_Certificate;
}

