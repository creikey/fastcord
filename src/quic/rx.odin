package quic

import "fc:locks"
import "core:crypto"
import "core:fmt"
import "core:crypto/aead"
import "core:time"

import "fc:quic/tls13"

// Transport error codes (RFC 9000 20.1).
ERR_NO_ERROR :: 0x00
ERR_INTERNAL :: 0x01
ERR_FLOW_CONTROL :: 0x03
ERR_STREAM_LIMIT :: 0x04
ERR_STREAM_STATE :: 0x05
ERR_FINAL_SIZE :: 0x06
ERR_FRAME_ENCODING :: 0x07
ERR_TRANSPORT_PARAMETER :: 0x08
ERR_PROTOCOL_VIOLATION :: 0x0a
ERR_CRYPTO_BUFFER_EXCEEDED :: 0x0d
ERR_KEY_UPDATE :: 0x0e

MAX_CRYPTO_BUFFER :: 1 << 16
MAX_UNDECRYPTABLE :: 8
MAX_ACK_DELAY :: 25 * time.Millisecond
INITIAL_ACK_DELAY :: time.Millisecond
ACK_DECIMATION_AFTER :: 100 // QUICHE kMinReceivedBeforeAckDecimation

RETRY_KEY := [16]byte{0xbe, 0x0c, 0x69, 0x0b, 0x9f, 0x66, 0x57, 0x5a, 0x1d, 0x76, 0x6b, 0x54, 0xe3, 0x68, 0xc8, 0x4e}
RETRY_NONCE := [12]byte{0x46, 0x15, 0x99, 0xd3, 0x5d, 0x63, 0x2b, 0xf2, 0x23, 0x98, 0x25, 0xbb}

@(private)
be32 :: proc(b: []byte) -> u32 {return u32(b[0]) << 24 | u32(b[1]) << 16 | u32(b[2]) << 8 | u32(b[3])}

// process_datagram_locked handles every (possibly coalesced) packet in a datagram.
process_datagram_locked :: proc(c: ^Conn, dgram: []byte, now: time.Tick) {
	b := dgram
	for len(b) > 0 {
		first := b[0]
		if first & 0x80 == 0 {
			handle_short(c, b, now)
			return
		}
		if len(b) < 7 do return
		version := be32(b[1:5])
		if version == 0 {
			// Version Negotiation: we only speak v1, so give up (before any reply).
			if !c.got_server_scid do fail_locked(c, .Version_Negotiation, ERR_NO_ERROR)
			return
		}
		if version != QUIC_V1 do return
		if first & 0x40 == 0 do return // fixed bit
		typ := (first >> 4) & 3
		r := reader(b[5:])
		dcid := r_take(&r, int(r_u8(&r)))
		scid := r_take(&r, int(r_u8(&r)))
		if !r.ok || len(dcid) > 20 || len(scid) > 20 do return
		if typ == 3 {
			handle_retry(c, b, scid)
			return
		}
		if typ == 0 do r_vec(&r) // token: always empty from a server
		length := r_varint(&r)
		if !r.ok || length > u64(len(r.b)) do return
		pn_off := len(b) - len(r.b)
		pkt := b[:pn_off + int(length)]
		b = b[pn_off + int(length):]
		space: Space
		switch typ {
		case 0:
			space = .Initial
		case 2:
			space = .Handshake
		case:
			continue // 0-RTT is client-only
		}
		handle_long(c, space, pkt, pn_off, scid, now)
	}
}

@(private)
buffer_undecryptable :: proc(sp: ^Pn_Space, pkt: []byte) {
	if len(sp.undecryptable) >= MAX_UNDECRYPTABLE do return
	cp := make([]byte, len(pkt))
	copy(cp, pkt)
	append(&sp.undecryptable, cp)
}

@(private)
handle_long :: proc(c: ^Conn, space: Space, pkt: []byte, pn_off: int, scid: []byte, now: time.Tick) {
	sp := &c.spaces[space]
	if sp.discarded do return
	if !sp.rx.valid {
		buffer_undecryptable(sp, pkt)
		return
	}
	trunc, pn_len, ok := unprotect_header(&sp.rx, pkt, pn_off)
	if !ok do return
	pn := decode_pn(sp.largest_rx, trunc, pn_len)
	pt, ok2 := open(&sp.rx, pkt, pn_off + pn_len, pn)
	if !ok2 do return
	if pkt[0] & 0x0c != 0 {
		fail_locked(c, .Protocol, ERR_PROTOCOL_VIOLATION)
		return
	}
	if space == .Initial && !c.got_server_scid {
		// The server's SCID becomes our DCID (RFC 9000 7.2).
		c.got_server_scid = true
		copy(c.server_scid[:], scid)
		c.server_scid_len = len(scid)
		copy(c.dcid[:], scid)
		c.dcid_len = len(scid)
	}
	received_packet(c, space, pn, pt, now)
}

@(private)
handle_short :: proc(c: ^Conn, pkt: []byte, now: time.Tick) {
	sp := &c.spaces[.App]
	if !sp.rx.valid {
		buffer_undecryptable(sp, pkt)
		return
	}
	if pkt[0] & 0x40 == 0 do return
	// Our SCID is empty, so the header is 1 byte + packet number.
	pn_off := 1
	trunc, pn_len, ok := unprotect_header(&sp.rx, pkt, pn_off)
	if !ok do return
	pn := decode_pn(sp.largest_rx, trunc, pn_len)
	phase := (pkt[0] >> 2) & 1
	pt: []byte
	if phase == c.key_phase {
		pt, ok = open(&sp.rx, pkt, pn_off + pn_len, pn)
		if !ok do return
	} else {
		// Peer-initiated key update (RFC 9001 6.2). Decrypt in a copy so a
		// failure leaves the packet for nothing else; then rotate both ways.
		pt, ok = open(&c.app_rx_next, pkt, pn_off + pn_len, pn)
		if !ok do return
		keys_clear(&sp.rx)
		sp.rx = c.app_rx_next
		c.app_rx_next = {}
		keys_next(&c.app_rx_next, &sp.rx)
		next_tx: Keys
		keys_next(&next_tx, &sp.tx)
		keys_clear(&sp.tx)
		sp.tx = next_tx
		c.key_phase ~= 1
	}
	if pkt[0] & 0x18 != 0 {
		fail_locked(c, .Protocol, ERR_PROTOCOL_VIOLATION)
		return
	}
	received_packet(c, .App, pn, pt, now)
}

@(private)
handle_retry :: proc(c: ^Conn, pkt: []byte, scid: []byte) {
	if c.got_server_scid || c.retry_scid_len > 0 || len(pkt) < 16 + 7 do return
	// Integrity tag over the pseudo-packet (RFC 9001 5.8).
	pseudo := make([dynamic]byte, 0, len(pkt) + 9)
	defer delete(pseudo)
	append(&pseudo, 8)
	append(&pseudo, ..c.odcid[:])
	append(&pseudo, ..pkt[:len(pkt) - 16])
	tag: [16]byte
	aead.seal_oneshot(.AES_GCM_128, nil, tag[:], RETRY_KEY[:], RETRY_NONCE[:], pseudo[:], nil)
	if crypto.compare_constant_time(tag[:], pkt[len(pkt) - 16:]) != 1 do return
	hdr := 1 + 4 + 1 + int(pkt[5])
	hdr += 1 + int(pkt[hdr])
	token := pkt[hdr:len(pkt) - 16]
	if len(token) == 0 || len(scid) == 0 do return
	clear(&c.token)
	append(&c.token, ..token)
	copy(c.retry_scid[:], scid)
	c.retry_scid_len = len(scid)
	copy(c.dcid[:], scid)
	c.dcid_len = len(scid)
	// New Initial keys from the Retry SCID; resend the ClientHello.
	sp := &c.spaces[.Initial]
	keys_clear(&sp.tx)
	keys_clear(&sp.rx)
	initial_keys(&sp.tx, &sp.rx, scid)
	for &p in sp.sent {
		if p.in_flight do cubic_on_removed(&c.cc, p.size)
		delete(p.frames)
	}
	clear(&sp.sent)
	sb_on_lost(&sp.crypto_send, 0, sp.crypto_send.end, false)
}

// received_packet runs the frames of a decrypted packet and schedules the ACK.
@(private)
received_packet :: proc(c: ^Conn, space: Space, pn: u64, pt: []byte, now: time.Tick) {
	sp := &c.spaces[space]
	if rs_contains(&sp.recv_pns, pn, pn + 1) do return // duplicate
	c.last_activity = now
	if debug_log do fmt.eprintfln("[quic] %v rx %v pn=%d len=%d first=%x", now, space, pn, len(pt), pt[0] if len(pt) > 0 else 0)
	eliciting, ok := process_frames(c, space, pt, now)
	if !ok do return
	prev_largest := sp.largest_rx
	rs_add(&sp.recv_pns, pn, pn + 1)
	if i64(pn) > sp.largest_rx {
		sp.largest_rx = i64(pn)
		sp.largest_rx_time = now
	}
	// Bound the ACK range list.
	for len(sp.recv_pns) > 32 do ordered_remove(&sp.recv_pns, 0)
	if !eliciting do return
	sp.unacked_eliciting += 1
	if space != .App {
		// QUICHE: ACK every 2nd ack-eliciting packet, otherwise after 1ms
		// (Chrome's first Initial ACK reports ~1.3ms), so a quick Handshake
		// flight can supersede it.
		if sp.unacked_eliciting >= 2 {
			sp.ack_now = true
		} else if !sp.ack_timer {
			sp.ack_timer = true
			sp.ack_deadline = time.tick_add(now, INITIAL_ACK_DELAY)
		}
		return
	}
	c.app_packets_rx += 1
	// QUICHE: ACK every 2nd packet, every 10th after 100 packets; immediately on reordering.
	threshold := 2 if c.app_packets_rx < ACK_DECIMATION_AFTER else 10
	reordered := i64(pn) < prev_largest || (prev_largest >= 0 && i64(pn) > prev_largest + 1)
	if reordered || sp.unacked_eliciting >= threshold {
		sp.ack_now = true
	} else if !sp.ack_timer {
		sp.ack_timer = true
		sp.ack_deadline = time.tick_add(now, MAX_ACK_DELAY)
	}
}

// process_frames returns whether the packet was ack-eliciting; ok=false if
// the connection failed while processing.
@(private)
process_frames :: proc(c: ^Conn, space: Space, pt: []byte, now: time.Tick) -> (eliciting: bool, ok: bool) {
	r := reader(pt)
	if len(pt) == 0 {
		fail_locked(c, .Protocol, ERR_PROTOCOL_VIOLATION)
		return false, false
	}
	for len(r.b) > 0 {
		typ := r_varint(&r)
		if !r.ok do break
		if space != .App {
			switch typ {
			case 0x00, 0x01, 0x02, 0x03, 0x06, 0x1c:
			case:
				fail_locked(c, .Protocol, ERR_PROTOCOL_VIOLATION)
				return false, false
			}
		}
		if typ != 0x00 && typ != 0x02 && typ != 0x03 && typ != 0x1c && typ != 0x1d do eliciting = true
		switch typ {
		case 0x00:
			for len(r.b) > 0 && r.b[0] == 0 do r.b = r.b[1:]
		case 0x01:
		case 0x02, 0x03:
			largest := r_varint(&r)
			delay := r_varint(&r)
			count := r_varint(&r)
			first := r_varint(&r)
			if !r.ok || first > largest || count > 256 {
				fail_locked(c, .Protocol, ERR_FRAME_ENCODING)
				return false, false
			}
			ranges: [dynamic]Range
			defer delete(ranges)
			hi := largest
			lo := largest - first
			append(&ranges, Range{lo, hi + 1})
			for _ in 0 ..< count {
				gap := r_varint(&r)
				l := r_varint(&r)
				if !r.ok || gap + 2 > lo || l > lo - gap - 2 {
					fail_locked(c, .Protocol, ERR_FRAME_ENCODING)
					return false, false
				}
				hi = lo - gap - 2
				lo = hi - l
				append(&ranges, Range{lo, hi + 1})
			}
			if typ == 0x03 {
				r_varint(&r)
				r_varint(&r)
				r_varint(&r)
			}
			if !r.ok do break
			if !on_ack_frame(c, space, largest, delay, ranges[:], now) do return false, false
		case 0x04:
			id := r_varint(&r)
			code := r_varint(&r)
			final := r_varint(&r)
			if !r.ok do break
			on_reset_stream(c, id, code, final) or_return
		case 0x05:
			id := r_varint(&r)
			code := r_varint(&r)
			if !r.ok do break
			on_stop_sending(c, id, code) or_return
		case 0x06:
			off := r_varint(&r)
			data := r_vec(&r)
			if !r.ok do break
			if off + u64(len(data)) > MAX_CRYPTO_BUFFER + c.spaces[space].crypto_recv.read_off {
				fail_locked(c, .Protocol, ERR_CRYPTO_BUFFER_EXCEEDED)
				return false, false
			}
			on_crypto(c, space, off, data) or_return
		case 0x07:
			tok := r_vec(&r)
			if !r.ok || len(tok) == 0 do break
		case 0x08 ..= 0x0f:
			id := r_varint(&r)
			off: u64
			if typ & 0x04 != 0 do off = r_varint(&r)
			data: []byte
			if typ & 0x02 != 0 {
				data = r_vec(&r)
			} else {
				data = r.b
				r.b = nil
			}
			if !r.ok do break
			on_stream_frame(c, id, off, data, typ & 0x01 != 0) or_return
		case 0x10:
			v := r_varint(&r)
			if r.ok && v > c.peer_max_data do c.peer_max_data = v
		case 0x11:
			id := r_varint(&r)
			v := r_varint(&r)
			if !r.ok do break
			on_max_stream_data(c, id, v) or_return
		case 0x12, 0x13:
			v := r_varint(&r)
			if !r.ok do break
			if v > 1 << 60 {
				fail_locked(c, .Protocol, ERR_FRAME_ENCODING)
				return false, false
			}
			if typ == 0x12 && v > c.peer_max_bidi do c.peer_max_bidi = v
			if typ == 0x13 && v > c.peer_max_uni do c.peer_max_uni = v
			locks.cond_broadcast(&c.cond)
		case 0x14, 0x16, 0x17:
			r_varint(&r)
		case 0x15:
			r_varint(&r)
			r_varint(&r)
		case 0x18:
			seq := r_varint(&r)
			retire := r_varint(&r)
			cid := r_take(&r, int(r_u8(&r)))
			r_take(&r, 16)
			if !r.ok || len(cid) == 0 || len(cid) > 20 || retire > seq {
				fail_locked(c, .Protocol, ERR_FRAME_ENCODING)
				return false, false
			}
			on_new_cid(c, seq, retire, cid)
		case 0x19:
			// We use zero-length connection IDs: nothing to retire.
			fail_locked(c, .Protocol, ERR_PROTOCOL_VIOLATION)
			return false, false
		case 0x1a:
			d := r_take(&r, 8)
			if !r.ok do break
			ctl := Ctrl{kind = .Path_Response}
			copy(ctl.data[:], d)
			append(&c.ctrl, ctl)
		case 0x1b:
			r_take(&r, 8)
		case 0x1c, 0x1d:
			code := r_varint(&r)
			if typ == 0x1c do r_varint(&r)
			r_vec(&r)
			// Draining: no more sending (RFC 9000 10.2.2).
			c.peer_code = code
			if c.err == .None do c.err = .Peer_Closed
			c.closing = true
			c.close_sent = true
			locks.cond_broadcast(&c.cond)
			return eliciting, false
		case 0x1e:
			if !c.handshake_confirmed {
				c.handshake_confirmed = true
				discard_space(c, .Handshake)
				locks.cond_broadcast(&c.cond)
			}
		case 0x30:
			r.b = nil
		case 0x31:
			r_vec(&r)
		case:
			fail_locked(c, .Protocol, ERR_FRAME_ENCODING)
			return false, false
		}
		if !r.ok do break
	}
	if !r.ok {
		fail_locked(c, .Protocol, ERR_FRAME_ENCODING)
		return false, false
	}
	return eliciting, true
}

// discard_space drops keys and in-flight accounting for a finished level.
discard_space :: proc(c: ^Conn, space: Space) {
	sp := &c.spaces[space]
	if sp.discarded do return
	sp.discarded = true
	for &p in sp.sent {
		if p.in_flight do cubic_on_removed(&c.cc, p.size)
		delete(p.frames)
	}
	clear(&sp.sent)
	keys_clear(&sp.tx)
	keys_clear(&sp.rx)
	sp.has_loss_time = false
	sp.ack_now = false
	sp.ack_timer = false
	sp.unacked_eliciting = 0
	c.pto_count = 0
}

@(private)
on_crypto :: proc(c: ^Conn, space: Space, off: u64, data: []byte) -> bool {
	sp := &c.spaces[space]
	rb_insert(&sp.crypto_recv, off, data)
	for {
		avail := rb_readable(&sp.crypto_recv)
		if len(avail) < 4 do break
		n := 4 + (int(avail[1]) << 16 | int(avail[2]) << 8 | int(avail[3]))
		if n > MAX_CRYPTO_BUFFER {
			fail_locked(c, .Protocol, ERR_CRYPTO_BUFFER_EXCEEDED)
			return false
		}
		if len(avail) < n do break
		msg := make([]byte, n)
		copy(msg, avail[:n])
		rb_consume(&sp.crypto_recv, n)
		if space == .App {
			e := tls13.quic_post_handshake(&c.hs, msg)
			delete(msg)
			if e != .None {
				fail_locked(c, .Tls, 0x100 + u64(tls13.alert_code(e)))
				return false
			}
		} else {
			append(&c.hs_msgs, msg)
			locks.cond_broadcast(&c.cond)
		}
	}
	return true
}

@(private)
on_new_cid :: proc(c: ^Conn, seq, retire: u64, cid: []byte) {
	// We keep using one DCID; switch only when told to retire the current one.
	if retire > c.dcid_seq + 16 {
		// Far more retirements than the 2 IDs we accept (CONNECTION_ID_LIMIT_ERROR).
		fail_locked(c, .Protocol, 0x09)
		return
	}
	if retire > c.dcid_seq && seq >= retire {
		for s in c.dcid_seq ..< retire do append(&c.ctrl, Ctrl{kind = .Retire_Cid, id = s})
		copy(c.dcid[:], cid)
		c.dcid_len = len(cid)
		c.dcid_seq = seq
	} else if seq < retire {
		append(&c.ctrl, Ctrl{kind = .Retire_Cid, id = seq})
	}
}
