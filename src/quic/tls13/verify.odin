package tls13

import "core:bytes"
import "core:crypto/ecdsa"
import "core:crypto/hash"
import "core:crypto/rsa"
import "core:crypto/x509"

SIG_ECDSA_P256_SHA256 :: 0x0403
SIG_ECDSA_P384_SHA384 :: 0x0503
SIG_RSA_PSS_SHA256 :: 0x0804
SIG_RSA_PSS_SHA384 :: 0x0805
SIG_RSA_PSS_SHA512 :: 0x0806

// cv_content builds the signed CertificateVerify input (RFC 8446 4.4.3).
@(private)
cv_content :: proc(th: []byte, out: []byte) -> []byte {
	CTX :: "TLS 1.3, server CertificateVerify"
	n := 0
	for _ in 0 ..< 64 {
		out[n] = 0x20
		n += 1
	}
	n += copy(out[n:], CTX)
	out[n] = 0
	n += 1
	n += copy(out[n:], th)
	return out[:n]
}

// verify_certificate_verify checks the server's signature with the leaf key.
// Only the TLS 1.3-legal schemes we offered are accepted (no PKCS#1 v1.5).
verify_certificate_verify :: proc(leaf: ^x509.Certificate, alg: u16, sig: []byte, th: []byte) -> Error {
	buf: [64 + 34 + MAX_HASH]byte
	msg := cv_content(th, buf[:])
	switch alg {
	case SIG_ECDSA_P256_SHA256, SIG_ECDSA_P384_SHA384:
		curve := ecdsa.Curve.SECP256R1
		h := hash.Algorithm.SHA256
		want := x509.Public_Key_Algorithm.ECDSA_P256
		if alg == SIG_ECDSA_P384_SHA384 {
			curve, h, want = .SECP384R1, .SHA384, .ECDSA_P384
		}
		if leaf.public_key_algorithm != want do return .Illegal_Parameter
		pub: ecdsa.Public_Key
		defer ecdsa.public_key_clear(&pub)
		if !ecdsa.public_key_set_bytes(&pub, curve, leaf.ec_point) do return .Bad_Certificate
		if !ecdsa.verify_asn1(&pub, h, msg, sig) do return .Bad_Signature
		return .None
	case SIG_RSA_PSS_SHA256, SIG_RSA_PSS_SHA384, SIG_RSA_PSS_SHA512:
		if leaf.public_key_algorithm != .RSA do return .Illegal_Parameter
		h := hash.Algorithm.SHA256
		if alg == SIG_RSA_PSS_SHA384 do h = .SHA384
		if alg == SIG_RSA_PSS_SHA512 do h = .SHA512
		pub: rsa.Public_Key
		defer rsa.public_key_clear(&pub)
		e := bytes.trim_left(leaf.rsa_e, {0})
		if !rsa.public_key_set_bytes(&pub, leaf.rsa_n, e) do return .Bad_Certificate
		if !rsa.verify_pss(&pub, h, hash.DIGEST_SIZES[h], msg, sig) do return .Bad_Signature
		return .None
	}
	return .Illegal_Parameter
}
