// Package tls13 is the hand-written TLS 1.3 handshake that src/quic still runs over CRYPTO frames.
// TCP TLS is BoringSSL (src/tls); this package is deleted when ngtcp2 replaces src/quic.
package tls13

import "core:crypto/aead"
import "core:crypto/hash"
import "core:time"

import "fc:tls"

Config :: struct {
	// ALPN protocols in preference order, e.g. {"h3"}.
	alpn:                 []string,
	// SNI and the name the certificate is checked against.
	server_name:          string,
	// Skips OS trust evaluation (tests only). CertificateVerify and Finished are still checked.
	insecure_skip_verify: bool,
	// Session resumption: tickets are taken from / stored into this cache
	// (default_ticket_cache when nil) unless disable_resumption is set.
	ticket_cache:         ^Ticket_Cache,
	disable_resumption:   bool,
}

Error :: enum u8 {
	None,
	Io,
	Closed,
	Decode,
	Unexpected_Message,
	Bad_Record_Mac,
	Record_Overflow,
	Handshake_Failure,
	Protocol_Version,
	Illegal_Parameter,
	Unsupported_Extension,
	Missing_Extension,
	Bad_Certificate,
	Untrusted_Certificate,
	Bad_Signature,
	Bad_Finished,
	No_Application_Protocol,
	Unsupported_Compression,
	Alert_Received,
	Too_Large,
	Internal,
}

// Ticket is a stored NewSessionTicket with its derived resumption PSK.
Ticket :: struct {
	lifetime:    u32,
	age_add:     u32,
	ticket:      []byte,
	psk:         [MAX_HASH]byte,
	psk_len:     int,
	suite:       u16,
	max_early:   u32,
	received:    time.Time,
	quic_params: []byte, // The server's transport parameters, for 0-RTT.
}

MAX_HASH :: 48

Suite :: struct {
	id:       u16,
	aead:     aead.Algorithm,
	key_len:  int,
	hash:     hash.Algorithm,
	hash_len: int,
}

SUITES := [?]Suite {
	{0x1301, .AES_GCM_128, 16, .SHA256, 32},
	{0x1302, .AES_GCM_256, 32, .SHA384, 48},
	{0x1303, .CHACHA20POLY1305, 32, .SHA256, 32},
}

// aead_impl is the implementation argument for aead.init(_, alg, _).
aead_impl :: proc(alg: aead.Algorithm) -> aead.Implementation {
	#partial switch alg {
	case .CHACHA20POLY1305, .XCHACHA20POLY1305:
		return tls.CHACHA20_IMPL
	}
	return nil
}
