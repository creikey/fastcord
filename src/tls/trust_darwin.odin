#+build darwin
package tls

// Chain validation against the macOS trust store via Security.framework.

foreign import corefoundation "system:CoreFoundation.framework"
foreign import sec "system:Security.framework"

@(private = "file")
CFTypeRef :: rawptr

@(private = "file")
CFArrayCallBacks :: struct {
	version:         int,
	retain:          rawptr,
	release:         rawptr,
	copyDescription: rawptr,
	equal:           rawptr,
}

@(private = "file")
kCFStringEncodingUTF8 :: 0x08000100

@(private = "file", default_calling_convention = "c")
foreign corefoundation {
	kCFTypeArrayCallBacks: CFArrayCallBacks
	CFDataCreate :: proc(alloc: CFTypeRef, bytes: [^]byte, length: int) -> CFTypeRef ---
	CFArrayCreate :: proc(alloc: CFTypeRef, values: [^]CFTypeRef, num: int, callbacks: ^CFArrayCallBacks) -> CFTypeRef ---
	CFStringCreateWithBytes :: proc(alloc: CFTypeRef, bytes: [^]byte, num: int, encoding: u32, external: b8) -> CFTypeRef ---
	CFRelease :: proc(cf: CFTypeRef) ---
}

@(private = "file", default_calling_convention = "c")
foreign sec {
	SecCertificateCreateWithData :: proc(alloc: CFTypeRef, data: CFTypeRef) -> CFTypeRef ---
	SecPolicyCreateSSL :: proc(server: b8, hostname: CFTypeRef) -> CFTypeRef ---
	SecTrustCreateWithCertificates :: proc(certs: CFTypeRef, policies: CFTypeRef, trust: ^CFTypeRef) -> i32 ---
	SecTrustEvaluateWithError :: proc(trust: CFTypeRef, error: ^CFTypeRef) -> b8 ---
}

// verify_chain_os evaluates leaf + intermediates with an SSL server policy for host.
verify_chain_os :: proc(chain: [][]byte, host: string) -> Error {
	certs: [16]CFTypeRef
	n := 0
	defer for i in 0 ..< n do CFRelease(certs[i])
	for der in chain {
		if n == len(certs) do break
		data := CFDataCreate(nil, raw_data(der), len(der))
		if data == nil do return .Internal
		c := SecCertificateCreateWithData(nil, data)
		CFRelease(data)
		if c == nil do return .Bad_Certificate
		certs[n] = c
		n += 1
	}
	arr := CFArrayCreate(nil, &certs[0], n, &kCFTypeArrayCallBacks)
	if arr == nil do return .Internal
	defer CFRelease(arr)

	hs := CFStringCreateWithBytes(nil, raw_data(host), len(host), kCFStringEncodingUTF8, false)
	if hs == nil do return .Internal
	defer CFRelease(hs)
	policy := SecPolicyCreateSSL(true, hs)
	if policy == nil do return .Internal
	defer CFRelease(policy)

	trust: CFTypeRef
	if SecTrustCreateWithCertificates(arr, policy, &trust) != 0 || trust == nil do return .Internal
	defer CFRelease(trust)
	cferr: CFTypeRef
	ok := SecTrustEvaluateWithError(trust, &cferr)
	if cferr != nil do CFRelease(cferr)
	return .None if ok else .Untrusted_Certificate
}
