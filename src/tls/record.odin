package tls

import "fc:locks"
import "core:crypto"
import "core:crypto/aead"
import "core:encoding/endian"

import "fc:netio"

CT_CHANGE_CIPHER_SPEC :: 20
CT_ALERT :: 21
CT_HANDSHAKE :: 22
CT_APPLICATION_DATA :: 23

ALERT_CLOSE_NOTIFY :: 0
ALERT_UNEXPECTED_MESSAGE :: 10
ALERT_BAD_RECORD_MAC :: 20
ALERT_RECORD_OVERFLOW :: 22
ALERT_HANDSHAKE_FAILURE :: 40
ALERT_BAD_CERTIFICATE :: 42
ALERT_CERTIFICATE_UNKNOWN :: 46
ALERT_ILLEGAL_PARAMETER :: 47
ALERT_DECODE_ERROR :: 50
ALERT_DECRYPT_ERROR :: 51
ALERT_PROTOCOL_VERSION :: 70
ALERT_INTERNAL_ERROR :: 80
ALERT_USER_CANCELED :: 90
ALERT_MISSING_EXTENSION :: 109
ALERT_UNSUPPORTED_EXTENSION :: 110
ALERT_NO_APPLICATION_PROTOCOL :: 120

// Upper bound on a single reassembled handshake message (certificate chains are ~5-10 KiB).
MAX_HANDSHAKE_MESSAGE :: 1 << 18

AEAD_TAG :: 16

@(private)
alert_for :: proc(e: Error) -> u8 {
	#partial switch e {
	case .Decode:
		return ALERT_DECODE_ERROR
	case .Unexpected_Message:
		return ALERT_UNEXPECTED_MESSAGE
	case .Bad_Record_Mac:
		return ALERT_BAD_RECORD_MAC
	case .Record_Overflow, .Too_Large:
		return ALERT_RECORD_OVERFLOW
	case .Handshake_Failure:
		return ALERT_HANDSHAKE_FAILURE
	case .Protocol_Version:
		return ALERT_PROTOCOL_VERSION
	case .Illegal_Parameter:
		return ALERT_ILLEGAL_PARAMETER
	case .Unsupported_Extension:
		return ALERT_UNSUPPORTED_EXTENSION
	case .Missing_Extension:
		return ALERT_MISSING_EXTENSION
	case .Bad_Certificate, .Unsupported_Compression:
		return ALERT_BAD_CERTIFICATE
	case .Untrusted_Certificate:
		return ALERT_CERTIFICATE_UNKNOWN
	case .Bad_Signature, .Bad_Finished:
		return ALERT_DECRYPT_ERROR
	case .No_Application_Protocol:
		return ALERT_NO_APPLICATION_PROTOCOL
	}
	return ALERT_INTERNAL_ERROR
}

// fail marks the session dead and, for locally detected errors, tells the peer why.
@(private)
fail :: proc(s: ^Session, e: Error) {
	if !set_failed(s, e) do return
	_last_error = e
	#partial switch e {
	case .Io, .Closed, .Alert_Received:
	case:
		send_alert(s, 2, alert_for(e))
	}
}

// send_alert writes an alert best-effort; errors are ignored.
@(private)
send_alert :: proc(s: ^Session, level, desc: u8) {
	locks.lock(&s.wmu)
	defer locks.unlock(&s.wmu)
	if s.sent_close do return
	msg := [2]byte{level, desc}
	write_record_locked(s, CT_ALERT, msg[:])
	if desc == ALERT_CLOSE_NOTIFY || level == 2 do s.sent_close = true
}

@(private)
set_keys :: proc(d: ^Direction, suite: Suite, secret: []byte) {
	key: [32]byte
	defer crypto.zero_explicit(&key, size_of(key))
	copy(d.secret[:], secret)
	expand_label(suite, secret, "key", nil, key[:suite.key_len])
	expand_label(suite, secret, "iv", nil, d.iv[:])
	aead.reset(&d.ctx)
	aead.init(&d.ctx, suite.aead, key[:suite.key_len], aead_impl(suite.aead))
	d.seq = 0
	d.active = true
}

@(private)
nonce :: proc(d: ^Direction) -> (n: [12]byte) {
	n = d.iv
	seq: [8]byte
	endian.put_u64(seq[:], .Big, d.seq)
	for i in 0 ..< 8 do n[4 + i] ~= seq[i]
	return
}

// fill makes sure at least n bytes are buffered from the underlying stream.
@(private)
fill :: proc(s: ^Session, n: int) -> Error {
	if s.in_hi - s.in_lo >= n do return .None
	if s.in_lo > 0 {
		copy(s.inbuf[:], s.inbuf[s.in_lo:s.in_hi])
		s.in_hi -= s.in_lo
		s.in_lo = 0
	}
	for s.in_hi < n {
		got, err := netio.read(s.under, s.inbuf[s.in_hi:])
		if err == .Closed do return .Closed
		if err != .None do return .Io
		s.in_hi += got
	}
	return .None
}

// read_record returns the next record's content type and plaintext (a view into
// s.ptbuf valid until the next call). ChangeCipherSpec during the handshake is
// dropped here; alerts are handled here.
@(private)
read_record :: proc(s: ^Session) -> (ct: u8, payload: []byte, err: Error) {
	for {
		fill(s, 5) or_return
		hdr := s.inbuf[s.in_lo:][:5]
		ct = hdr[0]
		length := int(endian.unchecked_get_u16be(hdr[3:]))
		if hdr[1] != 3 do return 0, nil, .Decode
		if length > MAX_CIPHERTEXT do return 0, nil, .Record_Overflow
		fill(s, 5 + length) or_return
		hdr = s.inbuf[s.in_lo:][:5]
		body := s.inbuf[s.in_lo + 5:][:length]
		s.in_lo += 5 + length

		if ct == CT_CHANGE_CIPHER_SPEC {
			// Middlebox-compat CCS: only during the handshake, exactly {1}, unprotected.
			if s.handshake_done || length != 1 || body[0] != 1 do return 0, nil, .Unexpected_Message
			continue
		}

		if !s.rd.active {
			if length > MAX_PLAINTEXT do return 0, nil, .Record_Overflow
			if ct != CT_HANDSHAKE && ct != CT_ALERT do return 0, nil, .Unexpected_Message
			if length == 0 do return 0, nil, .Decode
			payload = s.ptbuf[:length]
			copy(payload, body)
		} else {
			if ct != CT_APPLICATION_DATA do return 0, nil, .Unexpected_Message
			if length < AEAD_TAG + 1 do return 0, nil, .Bad_Record_Mac
			if s.rd.seq == max(u64) do return 0, nil, .Internal
			n := nonce(&s.rd)
			clen := length - AEAD_TAG
			pt := s.ptbuf[:clen]
			if !aead.open_ctx(&s.rd.ctx, pt, n[:], hdr, body[:clen], body[clen:]) {
				return 0, nil, .Bad_Record_Mac
			}
			s.rd.seq += 1
			// Strip zero padding; the last non-zero byte is the real content type.
			i := clen - 1
			for i >= 0 && pt[i] == 0 do i -= 1
			if i < 0 do return 0, nil, .Unexpected_Message
			ct = pt[i]
			payload = pt[:i]
			if len(payload) > MAX_PLAINTEXT do return 0, nil, .Record_Overflow
			if ct != CT_APPLICATION_DATA && len(payload) == 0 do return 0, nil, .Unexpected_Message
		}

		if ct == CT_ALERT {
			if len(s.hsbuf) > 0 do return 0, nil, .Unexpected_Message
			if len(payload) != 2 do return 0, nil, .Decode
			desc := payload[1]
			switch desc {
			case ALERT_CLOSE_NOTIFY:
				return 0, nil, .Closed
			case ALERT_USER_CANCELED:
				continue
			}
			s.peer_alert = desc
			return 0, nil, .Alert_Received
		}
		if ct != CT_HANDSHAKE && ct != CT_APPLICATION_DATA do return 0, nil, .Unexpected_Message
		return ct, payload, .None
	}
}

// next_handshake_message returns one full handshake message (4-byte header
// included), reassembling across records. The caller owns the returned slice.
@(private)
next_handshake_message :: proc(s: ^Session) -> (msg: []byte, err: Error) {
	for {
		if len(s.hsbuf) >= 4 {
			n := int(s.hsbuf[1]) << 16 | int(s.hsbuf[2]) << 8 | int(s.hsbuf[3])
			if n > MAX_HANDSHAKE_MESSAGE do return nil, .Too_Large
			if len(s.hsbuf) >= 4 + n {
				msg = make([]byte, 4 + n)
				copy(msg, s.hsbuf[:4 + n])
				remove_range(&s.hsbuf, 0, 4 + n)
				return msg, .None
			}
		}
		ct, payload := read_record(s) or_return
		if ct != CT_HANDSHAKE do return nil, .Unexpected_Message
		append(&s.hsbuf, ..payload)
	}
}

// read_record_app reads one record after the handshake: application data goes
// to s.pending, post-handshake messages are processed.
@(private)
read_record_app :: proc(s: ^Session) -> Error {
	ct, payload := read_record(s) or_return
	if ct == CT_APPLICATION_DATA {
		if len(s.hsbuf) > 0 do return .Unexpected_Message
		s.pending = payload
		return .None
	}
	append(&s.hsbuf, ..payload)
	for len(s.hsbuf) >= 4 {
		n := int(s.hsbuf[1]) << 16 | int(s.hsbuf[2]) << 8 | int(s.hsbuf[3])
		if n > MAX_HANDSHAKE_MESSAGE do return .Too_Large
		if len(s.hsbuf) < 4 + n do break
		e := post_handshake(s, s.hsbuf[0], s.hsbuf[4:4 + n], len(s.hsbuf) - (4 + n))
		remove_range(&s.hsbuf, 0, 4 + n)
		if e != .None do return e
	}
	return .None
}

@(private)
write_record_locked :: proc(s: ^Session, ct: u8, data: []byte, legacy_version: u16 = 0x0303) -> Error {
	buf: [5 + MAX_PLAINTEXT + 1 + AEAD_TAG]byte = ---
	out := seal_record(s, ct, data, legacy_version, buf[:]) or_return
	if netio.write(s.under, out) != .None do return .Io
	return .None
}

// seal_record frames (and, once keys are set, encrypts) one record into buf.
@(private)
seal_record :: proc(s: ^Session, ct: u8, data: []byte, legacy_version: u16, buf: []byte) -> (out: []byte, err: Error) {
	assert(len(data) <= MAX_PLAINTEXT && len(buf) >= 5 + len(data) + 1 + AEAD_TAG)
	if !s.wr.active {
		buf[0] = ct
		endian.unchecked_put_u16be(buf[1:], legacy_version)
		endian.unchecked_put_u16be(buf[3:], u16(len(data)))
		copy(buf[5:], data)
		return buf[:5 + len(data)], .None
	}
	if s.wr.seq == max(u64) do return nil, .Internal
	inner := len(data) + 1
	buf[0] = CT_APPLICATION_DATA
	endian.unchecked_put_u16be(buf[1:], 0x0303)
	endian.unchecked_put_u16be(buf[3:], u16(inner + AEAD_TAG))
	copy(buf[5:], data)
	buf[5 + len(data)] = ct
	pt := buf[5:][:inner]
	n := nonce(&s.wr)
	aead.seal_ctx(&s.wr.ctx, pt, buf[5 + inner:][:AEAD_TAG], n[:], buf[:5], pt)
	s.wr.seq += 1
	return buf[:5 + inner + AEAD_TAG], .None
}

// write_handshake sends a handshake flight, fragmented into records, in a
// single write like BoringSSL's flight buffer. With ccs set, the unprotected
// middlebox-compat ChangeCipherSpec record goes first.
@(private)
write_handshake :: proc(s: ^Session, msg: []byte, legacy_version: u16 = 0x0303, ccs := false) -> Error {
	locks.lock(&s.wmu)
	defer locks.unlock(&s.wmu)
	flight := make([dynamic]byte, 0, len(msg) + 64)
	defer delete(flight)
	if ccs do append(&flight, CT_CHANGE_CIPHER_SPEC, 3, 3, 0, 1, 1)
	buf: [5 + MAX_PLAINTEXT + 1 + AEAD_TAG]byte = ---
	rest := msg
	for len(rest) > 0 {
		n := min(len(rest), MAX_PLAINTEXT)
		rec := seal_record(s, CT_HANDSHAKE, rest[:n], legacy_version, buf[:]) or_return
		append(&flight, ..rec)
		rest = rest[n:]
	}
	if netio.write(s.under, flight[:]) != .None do return .Io
	return .None
}
