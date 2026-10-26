package tls13

import "core:crypto"
import "core:crypto/ecdh"
import "core:crypto/mlkem"

import "fc:brotli"

HS_CLIENT_HELLO :: 1
HS_SERVER_HELLO :: 2
HS_NEW_SESSION_TICKET :: 4
HS_ENCRYPTED_EXTENSIONS :: 8
HS_CERTIFICATE :: 11
HS_CERTIFICATE_REQUEST :: 13
HS_CERTIFICATE_VERIFY :: 15
HS_FINISHED :: 20
HS_KEY_UPDATE :: 24
HS_COMPRESSED_CERTIFICATE :: 25

// SHA-256("HelloRetryRequest"), the ServerHello.random that marks an HRR.
HRR_RANDOM := [32]byte {
	0xcf, 0x21, 0xad, 0x74, 0xe5, 0x9a, 0x61, 0x11, 0xbe, 0x1d, 0x8c, 0x02, 0x1e, 0x65, 0xb8, 0x91,
	0xc2, 0xa2, 0x11, 0x16, 0x7a, 0xbb, 0x8c, 0x5e, 0x07, 0x9e, 0x09, 0xe2, 0xc8, 0xa8, 0x33, 0x9c,
}

@(private)
Server_Hello :: struct {
	is_hrr:       bool,
	session_id:   []byte,
	suite:        u16,
	version:      u16,
	has_share:    bool,
	group:        u16,
	share:        []byte, // empty in an HRR
	cookie:       []byte,
	has_psk:      bool,
	psk_identity: u16,
}

@(private)
find_suite :: proc(id: u16) -> (Suite, bool) {
	for s in SUITES do if s.id == id do return s, true
	return {}, false
}

@(private)
parse_server_hello :: proc(body: []byte) -> (sh: Server_Hello, err: Error) {
	r := reader(body)
	legacy := r_u16(&r)
	random := r_take(&r, 32)
	sh.session_id = r_vec8(&r)
	sh.suite = r_u16(&r)
	comp := r_u8(&r)
	exts := reader(r_vec16(&r))
	if !r_done(&r) do return sh, .Decode
	if legacy != 0x0303 do return sh, .Protocol_Version
	if comp != 0 do return sh, .Illegal_Parameter
	sh.is_hrr = crypto.compare_constant_time(random, HRR_RANDOM[:]) == 1

	seen: [3]bool
	for len(exts.b) > 0 {
		typ := r_u16(&exts)
		data := reader(r_vec16(&exts))
		if !exts.ok do return sh, .Decode
		switch typ {
		case EXT_SUPPORTED_VERSIONS:
			if seen[0] do return sh, .Illegal_Parameter
			seen[0] = true
			sh.version = r_u16(&data)
		case EXT_KEY_SHARE:
			if seen[1] do return sh, .Illegal_Parameter
			seen[1] = true
			sh.has_share = true
			sh.group = r_u16(&data)
			if !sh.is_hrr do sh.share = r_vec16(&data)
		case EXT_COOKIE:
			if seen[2] || !sh.is_hrr do return sh, .Unsupported_Extension
			seen[2] = true
			sh.cookie = r_vec16(&data)
			if len(sh.cookie) == 0 do return sh, .Decode
		case EXT_PRE_SHARED_KEY:
			if sh.is_hrr || sh.has_psk do return sh, .Illegal_Parameter
			sh.has_psk = true
			sh.psk_identity = r_u16(&data)
		case:
			return sh, .Unsupported_Extension
		}
		if !r_done(&data) do return sh, .Decode
	}
	// Without supported_versions the server negotiated TLS 1.2 or older.
	if sh.version != 0x0304 do return sh, .Protocol_Version
	return sh, .None
}

// key_exchange computes the (EC)DHE / hybrid shared secret into out.
@(private)
key_exchange :: proc(h: ^Hello, group: u16, share: []byte, out: []byte) -> (n: int, err: Error) {
	pub: ecdh.Public_Key
	defer ecdh.public_key_clear(&pub)
	switch group {
	case GROUP_X25519_MLKEM768:
		if h.hrr_group != 0 do return 0, .Illegal_Parameter
		if len(share) != MLKEM768_CT + 32 do return 0, .Illegal_Parameter
		if !mlkem.decaps(&h.mlkem_dk, share[:MLKEM768_CT], out[:32]) do return 0, .Illegal_Parameter
		if !ecdh.public_key_set_bytes(&pub, .X25519, share[MLKEM768_CT:]) do return 0, .Illegal_Parameter
		if !ecdh.ecdh(&h.hy_priv, &pub, out[32:64]) do return 0, .Illegal_Parameter
		return 64, .None
	case GROUP_X25519:
		if h.hrr_group != 0 do return 0, .Illegal_Parameter
		if len(share) != 32 do return 0, .Illegal_Parameter
		if !ecdh.public_key_set_bytes(&pub, .X25519, share) do return 0, .Illegal_Parameter
		if !ecdh.ecdh(&h.x25519_priv, &pub, out[:32]) do return 0, .Illegal_Parameter
		return 32, .None
	case GROUP_SECP256R1, GROUP_SECP384R1:
		if h.hrr_group != group do return 0, .Illegal_Parameter
		curve := ecdh.Curve.SECP256R1 if group == GROUP_SECP256R1 else ecdh.Curve.SECP384R1
		// Uncompressed points only (RFC 8446 4.2.8.2).
		if len(share) != ecdh.PUBLIC_KEY_SIZES[curve] || share[0] != 4 do return 0, .Illegal_Parameter
		if !ecdh.public_key_set_bytes(&pub, curve, share) do return 0, .Illegal_Parameter
		n = ecdh.shared_secret_size(&pub)
		if !ecdh.ecdh(&h.hrr_priv, &pub, out[:n]) do return 0, .Illegal_Parameter
		return n, .None
	}
	return 0, .Illegal_Parameter
}

// parse_certificate returns the DER certificates (views into body), leaf first.
@(private)
parse_certificate :: proc(body: []byte) -> (chain: [][]byte, err: Error) {
	r := reader(body)
	ctx := r_vec8(&r)
	list := reader(r_vec24(&r))
	if !r_done(&r) do return nil, .Decode
	if len(ctx) != 0 do return nil, .Illegal_Parameter
	out := make([dynamic][]byte)
	for len(list.b) > 0 {
		der := r_vec24(&list)
		r_vec16(&list) // per-certificate extensions (OCSP / SCT): not used
		if !list.ok || len(der) == 0 {
			delete(out)
			return nil, .Decode
		}
		append(&out, der)
		if len(out) > 16 {
			delete(out)
			return nil, .Bad_Certificate
		}
	}
	if len(out) == 0 {
		delete(out)
		return nil, .Bad_Certificate
	}
	return out[:], .None
}

// decompress_certificate unpacks an RFC 8879 CompressedCertificate body.
@(private)
decompress_certificate :: proc(body: []byte) -> (out: []byte, err: Error) {
	r := reader(body)
	alg := r_u16(&r)
	ulen := r_u24(&r)
	data := r_vec24(&r)
	if !r_done(&r) || len(data) == 0 do return nil, .Decode
	if alg != 2 do return nil, .Illegal_Parameter // we only offered brotli
	if ulen == 0 || ulen > MAX_HANDSHAKE_MESSAGE do return nil, .Bad_Certificate
	res, berr := brotli.decompress(data, context.allocator, ulen)
	if berr != .None || len(res) != ulen {
		delete(res)
		return nil, .Bad_Certificate
	}
	return res, .None
}
