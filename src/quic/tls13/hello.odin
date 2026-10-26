package tls13

import "core:crypto"
import "core:crypto/ecdh"
import "core:crypto/mlkem"
import "core:crypto/x25519"
import "core:encoding/endian"

// Codepoints used in the Chrome-shaped ClientHello.
EXT_SERVER_NAME :: 0x0000
EXT_STATUS_REQUEST :: 0x0005
EXT_SUPPORTED_GROUPS :: 0x000a
EXT_EC_POINT_FORMATS :: 0x000b
EXT_SIGNATURE_ALGORITHMS :: 0x000d
EXT_ALPN :: 0x0010
EXT_SCT :: 0x0012
EXT_PADDING :: 0x0015
EXT_EXTENDED_MASTER_SECRET :: 0x0017
EXT_COMPRESS_CERTIFICATE :: 0x001b
EXT_SESSION_TICKET :: 0x0023
EXT_PRE_SHARED_KEY :: 0x0029
EXT_EARLY_DATA :: 0x002a
EXT_SUPPORTED_VERSIONS :: 0x002b
EXT_COOKIE :: 0x002c
EXT_PSK_KEY_EXCHANGE_MODES :: 0x002d
EXT_KEY_SHARE :: 0x0033
EXT_QUIC_TRANSPORT_PARAMETERS :: 0x0039
EXT_APPLICATION_SETTINGS :: 0x44cd // ALPS, new codepoint (Chrome 133+)
EXT_ECH :: 0xfe0d
EXT_RENEGOTIATION_INFO :: 0xff01

GROUP_X25519_MLKEM768 :: 0x11ec
GROUP_X25519 :: 0x001d
GROUP_SECP256R1 :: 0x0017
GROUP_SECP384R1 :: 0x0018

MLKEM768_EK :: 1184
MLKEM768_CT :: 1088

// Chrome's cipher list after the GREASE value: TLS 1.3, then ECDHE/RSA TLS 1.2 suites.
CHROME_CIPHERS := [?]u16 {
	0x1301, 0x1302, 0x1303,
	0xc02b, 0xc02f, 0xc02c, 0xc030, 0xcca9, 0xcca8,
	0xc013, 0xc014, 0x009c, 0x009d, 0x002f, 0x0035,
}

// Chrome's signature_algorithms (no GREASE here).
CHROME_SIGALGS := [?]u16{0x0403, 0x0804, 0x0401, 0x0503, 0x0805, 0x0501, 0x0806, 0x0601}

// Groups after the GREASE group.
CHROME_GROUPS := [?]u16{GROUP_X25519_MLKEM768, GROUP_X25519, GROUP_SECP256R1, GROUP_SECP384R1}

// Every extension BoringSSL may emit, in its table order. The permutation is
// drawn over all of them (like ssl_setup_extension_permutation); ones that do
// not apply to this hello are skipped when writing.
PERMUTED_EXTS := [?]u16 {
	EXT_SERVER_NAME, EXT_ECH, EXT_EXTENDED_MASTER_SECRET, EXT_RENEGOTIATION_INFO,
	EXT_SUPPORTED_GROUPS, EXT_EC_POINT_FORMATS, EXT_SESSION_TICKET, EXT_ALPN,
	EXT_STATUS_REQUEST, EXT_SIGNATURE_ALGORITHMS, EXT_SCT, EXT_KEY_SHARE,
	EXT_PSK_KEY_EXCHANGE_MODES, EXT_EARLY_DATA, EXT_SUPPORTED_VERSIONS, EXT_COOKIE,
	EXT_COMPRESS_CERTIFICATE, EXT_APPLICATION_SETTINGS, EXT_QUIC_TRANSPORT_PARAMETERS,
}

// Chrome's QUIC hello (a separate BoringSSL config): only the TLS 1.3 suites,
// no GREASE anywhere except ECH, and rsa_pkcs1_sha1 at the end of the sigalgs.
QUIC_CIPHERS := [?]u16{0x1301, 0x1302, 0x1303}
QUIC_SIGALGS := [?]u16{0x0403, 0x0804, 0x0401, 0x0503, 0x0805, 0x0501, 0x0806, 0x0601, 0x0201}

Grease_Slot :: enum {
	Cipher,
	Group,
	Ext1,
	Ext2,
	Version,
}

// Hello holds everything that must stay identical between ClientHello1 and
// the ClientHello2 sent after a HelloRetryRequest.
Hello :: struct {
	random:      [32]byte,
	session_id:  [32]byte,
	grease:      [Grease_Slot]u16,
	order:       [len(PERMUTED_EXTS)]u16,
	ech:         [8 + 32 + 2 + 240]byte,
	ech_len:     int,
	x25519_priv: ecdh.Private_Key,
	x25519_pub:  [32]byte,
	// The hybrid share has its own X25519 key, like BoringSSL.
	hy_priv:     ecdh.Private_Key,
	hy_pub:      [32]byte,
	mlkem_dk:    mlkem.Decapsulation_Key,
	mlkem_ek:    [MLKEM768_EK]byte,
	// Set after a HelloRetryRequest.
	retried:     bool,
	hrr_group:   u16,
	hrr_priv:    ecdh.Private_Key,
	cookie:      []byte,
	alpn:        []string,
	server_name: string,
	// QUIC profile: Chrome's QUIC ClientHello carrying these transport parameters.
	quic:        bool,
	quic_params: []byte,
	// Resumption: offered PSK identity (nil for a full handshake).
	psk:         ^Ticket,
	psk_age:     u32, // obfuscated ticket age
	early_data:  bool, // offer early_data (QUIC resumption, like Chrome)
}

// grease_value maps a random byte to one of the 16 RFC 8701 values (0x?a?a).
grease_value :: proc(seed: byte) -> u16 {
	v := u16(seed & 0xf0) | 0x0a
	return v << 8 | v
}

is_grease :: proc(v: u16) -> bool {
	return v & 0x0f0f == 0x0a0a && v >> 8 == v & 0xff
}

// hello_init draws all per-connection randomness: GREASE, permutation, ECH GREASE and key shares.
hello_init :: proc(h: ^Hello, server_name: string, alpn: []string) -> bool {
	h.server_name = server_name
	h.alpn = alpn
	crypto.rand_bytes(h.random[:])
	crypto.rand_bytes(h.session_id[:])
	if h.quic do h.session_id = {}

	seeds: [len(Grease_Slot)]byte
	crypto.rand_bytes(seeds[:])
	for slot in Grease_Slot do h.grease[slot] = grease_value(seeds[slot])
	// The two GREASE extensions must differ (BoringSSL does the same xor).
	if h.grease[.Ext1] == h.grease[.Ext2] do h.grease[.Ext2] ~= 0x1010

	// Fisher-Yates, as in BoringSSL's ssl_setup_extension_permutation.
	h.order = PERMUTED_EXTS
	perm_seeds: [len(PERMUTED_EXTS)]u32
	crypto.rand_bytes(([^]byte)(&perm_seeds)[:size_of(perm_seeds)])
	for i := len(h.order) - 1; i > 0; i -= 1 {
		j := int(perm_seeds[i - 1] % u32(i + 1))
		h.order[i], h.order[j] = h.order[j], h.order[i]
	}

	// ECH GREASE: outer type, HKDF-SHA256, AES-128-GCM, random config id, a
	// real-looking X25519 enc, and a payload of 32*[4,7] + 16 (tag) bytes.
	{
		b := h.ech[:]
		rnd: [2]byte
		crypto.rand_bytes(rnd[:])
		b[0] = 0
		endian.unchecked_put_u16be(b[1:], 0x0001)
		endian.unchecked_put_u16be(b[3:], 0x0001)
		b[5] = rnd[0]
		endian.unchecked_put_u16be(b[6:], 32)
		scalar: [32]byte
		crypto.rand_bytes(scalar[:])
		x25519.scalarmult_basepoint(b[8:40], scalar[:])
		crypto.zero_explicit(&scalar, size_of(scalar))
		payload := 32 * (4 + int(rnd[1] % 4)) + 16
		endian.unchecked_put_u16be(b[40:], u16(payload))
		crypto.rand_bytes(b[42:][:payload])
		h.ech_len = 42 + payload
	}

	if !ecdh.private_key_generate(&h.x25519_priv, .X25519) do return false
	ecdh.private_key_public_bytes(&h.x25519_priv, h.x25519_pub[:])
	if !ecdh.private_key_generate(&h.hy_priv, .X25519) do return false
	ecdh.private_key_public_bytes(&h.hy_priv, h.hy_pub[:])
	if !mlkem.decapsulation_key_generate(&h.mlkem_dk, .ML_KEM_768) do return false
	mlkem.decapsulation_key_encaps_bytes(&h.mlkem_dk, h.mlkem_ek[:])
	return true
}

hello_destroy :: proc(h: ^Hello) {
	ecdh.private_key_clear(&h.x25519_priv)
	ecdh.private_key_clear(&h.hrr_priv)
	ecdh.private_key_clear(&h.hy_priv)
	mlkem.decapsulation_key_clear(&h.mlkem_dk)
	delete(h.cookie)
	h.cookie = nil
}

// alps_protocol is the protocol Chrome sends application_settings for, or "".
@(private)
alps_protocol :: proc(h: ^Hello) -> string {
	want := "h3" if h.quic else "h2"
	for p in h.alpn do if p == want do return want
	return ""
}

@(private)
has_h2 :: proc(alpn: []string) -> bool {
	for p in alpn do if p == "h2" do return true
	return false
}

// is_ip_literal: Chrome sends no SNI for IP addresses.
@(private)
is_ip_literal :: proc(host: string) -> bool {
	if len(host) == 0 do return true
	for c in host {
		if c == ':' do return true
		if !(c == '.' || (c >= '0' && c <= '9')) do return false
	}
	return true
}

@(private)
write_ext :: proc(h: ^Hello, b: ^[dynamic]byte, id: u16) {
	start := len(b)
	put_u16(b, id)
	m := begin_vec(b, 2)
	switch id {
	case EXT_SERVER_NAME:
		if is_ip_literal(h.server_name) {
			resize(b, start)
			return
		}
		l := begin_vec(b, 2)
		put_u8(b, 0) // host_name
		n := begin_vec(b, 2)
		put_bytes(b, transmute([]byte)h.server_name)
		end_vec(b, n, 2)
		end_vec(b, l, 2)
	case EXT_ECH:
		put_bytes(b, h.ech[:h.ech_len])
	case EXT_EXTENDED_MASTER_SECRET, EXT_SESSION_TICKET, EXT_SCT:
		if h.quic {
			resize(b, start)
			return
		}
	case EXT_RENEGOTIATION_INFO:
		if h.quic {
			resize(b, start)
			return
		}
		put_u8(b, 0)
	case EXT_SUPPORTED_GROUPS:
		l := begin_vec(b, 2)
		if !h.quic do put_u16(b, h.grease[.Group])
		for g in CHROME_GROUPS do put_u16(b, g)
		end_vec(b, l, 2)
	case EXT_EC_POINT_FORMATS:
		if h.quic {
			resize(b, start)
			return
		}
		put_u8(b, 1)
		put_u8(b, 0) // uncompressed
	case EXT_ALPN:
		if len(h.alpn) == 0 {
			resize(b, start)
			return
		}
		l := begin_vec(b, 2)
		for p in h.alpn {
			put_u8(b, u8(len(p)))
			put_bytes(b, transmute([]byte)p)
		}
		end_vec(b, l, 2)
	case EXT_STATUS_REQUEST:
		if h.quic {
			resize(b, start)
			return
		}
		put_bytes(b, {1, 0, 0, 0, 0}) // ocsp, empty responder list and extensions
	case EXT_SIGNATURE_ALGORITHMS:
		l := begin_vec(b, 2)
		for a in (QUIC_SIGALGS[:] if h.quic else CHROME_SIGALGS[:]) do put_u16(b, a)
		end_vec(b, l, 2)
	case EXT_KEY_SHARE:
		l := begin_vec(b, 2)
		if h.hrr_group == 0 {
			// GREASE share only in the first hello (ssl_setup_key_shares skips it
			// on override) and never under QUIC.
			if !h.quic {
				put_u16(b, h.grease[.Group])
				put_u16(b, 1)
				put_u8(b, 0)
			}
			put_u16(b, GROUP_X25519_MLKEM768)
			put_u16(b, MLKEM768_EK + 32)
			put_bytes(b, h.mlkem_ek[:])
			put_bytes(b, h.hy_pub[:])
			put_u16(b, GROUP_X25519)
			put_u16(b, 32)
			put_bytes(b, h.x25519_pub[:])
		} else {
			pub: [97]byte
			n := ecdh.PUBLIC_KEY_SIZES[ecdh.curve(&h.hrr_priv)]
			ecdh.private_key_public_bytes(&h.hrr_priv, pub[:n])
			put_u16(b, h.hrr_group)
			put_u16(b, u16(n))
			put_bytes(b, pub[:n])
		}
		end_vec(b, l, 2)
	case EXT_PSK_KEY_EXCHANGE_MODES:
		put_bytes(b, {1, 1}) // psk_dhe_ke
	case EXT_SUPPORTED_VERSIONS:
		if h.quic {
			put_bytes(b, {2, 3, 4})
		} else {
			put_u8(b, 6)
			put_u16(b, h.grease[.Version])
			put_u16(b, 0x0304)
			put_u16(b, 0x0303)
		}
	case EXT_COMPRESS_CERTIFICATE:
		put_bytes(b, {2, 0, 2}) // brotli
	case EXT_APPLICATION_SETTINGS:
		// Chrome offers ALPS only for h2 (TCP) / h3 (QUIC).
		proto := alps_protocol(h)
		if proto == "" {
			resize(b, start)
			return
		}
		l := begin_vec(b, 2)
		put_u8(b, u8(len(proto)))
		put_bytes(b, transmute([]byte)proto)
		end_vec(b, l, 2)
	case EXT_QUIC_TRANSPORT_PARAMETERS:
		if !h.quic {
			resize(b, start)
			return
		}
		put_bytes(b, h.quic_params)
	case EXT_EARLY_DATA:
		if !h.early_data || h.psk == nil {
			resize(b, start)
			return
		}
	case EXT_COOKIE:
		if h.cookie == nil {
			resize(b, start)
			return
		}
		l := begin_vec(b, 2)
		put_bytes(b, h.cookie)
		end_vec(b, l, 2)
	case:
		// pre_shared_key is appended last by build_client_hello.
		resize(b, start)
		return
	}
	end_vec(b, m, 2)
}

// psk_ext_len is the encoded size of the pre_shared_key extension.
@(private)
psk_ext_len :: proc(h: ^Hello) -> int {
	if h.psk == nil do return 0
	return 4 + 2 + 2 + len(h.psk.ticket) + 4 + 2 + 1 + h.psk.psk_len
}

// build_client_hello appends the full handshake message (type + u24 length +
// body). With a PSK the binder is left zeroed; binders_len is the size of the
// trailing binders vector, which the binder MAC excludes (RFC 8446 4.2.11.2).
build_client_hello :: proc(h: ^Hello, b: ^[dynamic]byte) -> (binders_len: int) {
	put_u8(b, 1)
	msg := begin_vec(b, 3)
	put_u16(b, 0x0303)
	put_bytes(b, h.random[:])
	if h.quic {
		put_u8(b, 0)
	} else {
		put_u8(b, 32)
		put_bytes(b, h.session_id[:])
	}
	cl := begin_vec(b, 2)
	if h.quic {
		for c in QUIC_CIPHERS do put_u16(b, c)
	} else {
		put_u16(b, h.grease[.Cipher])
		for c in CHROME_CIPHERS do put_u16(b, c)
	}
	end_vec(b, cl, 2)
	put_bytes(b, {1, 0}) // null compression

	header_len := len(b) - msg + 4
	el := begin_vec(b, 2)
	if !h.quic {
		put_u16(b, h.grease[.Ext1])
		put_u16(b, 0)
	}
	for id in h.order do write_ext(h, b, id)
	if !h.quic {
		put_u16(b, h.grease[.Ext2])
		put_u16(b, 1)
		put_u8(b, 0)
	}

	// RFC 7685 padding exactly as BoringSSL decides it (F5 workaround), counting
	// the PSK extension; never triggers with a post-quantum key share but kept
	// for parity. Not after HRR and not for QUIC.
	if !h.retried && !h.quic {
		total := header_len + 2 + (len(b) - el) + psk_ext_len(h)
		if total > 0xff && total < 0x200 {
			pad := 0x200 - total
			pad = pad - 4 if pad >= 5 else 1
			put_u16(b, EXT_PADDING)
			put_u16(b, u16(pad))
			for _ in 0 ..< pad do put_u8(b, 0)
		}
	}

	if h.psk != nil {
		put_u16(b, EXT_PRE_SHARED_KEY)
		put_u16(b, u16(psk_ext_len(h) - 4))
		put_u16(b, u16(2 + len(h.psk.ticket) + 4))
		put_u16(b, u16(len(h.psk.ticket)))
		put_bytes(b, h.psk.ticket)
		put_u32(b, h.psk_age)
		binders_len = 2 + 1 + h.psk.psk_len
		put_u16(b, u16(1 + h.psk.psk_len))
		put_u8(b, u8(h.psk.psk_len))
		for _ in 0 ..< h.psk.psk_len do put_u8(b, 0)
	}
	end_vec(b, el, 2)
	end_vec(b, msg, 3)
	return
}
