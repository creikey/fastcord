package quic

import "core:fmt"
import "core:math/rand"
import "core:net"
import "core:sync"
import "core:time"

PTO_MAX_BACKOFF :: 8

@(private)
space_max_ack_delay :: proc(c: ^Conn, space: Space) -> time.Duration {
	if space != .App do return 0
	return time.Duration(c.params.max_ack_delay_ms) * time.Millisecond if c.handshake_complete else MAX_ACK_DELAY
}

// on_ack_frame processes an ACK for `space`. Returns false if the connection failed.
@(private)
on_ack_frame :: proc(c: ^Conn, space: Space, largest, delay: u64, ranges: []Range, now: time.Tick) -> bool {
	sp := &c.spaces[space]
	if largest >= c.next_pn {
		fail_locked(c, .Protocol, ERR_PROTOCOL_VIOLATION)
		return false
	}
	acked_any_eliciting := false
	largest_newly: ^Sent_Packet
	largest_time: time.Tick
	largest_found := false
	i := 0
	for i < len(sp.sent) {
		p := &sp.sent[i]
		hit := false
		for rg in ranges do if p.pn >= rg.lo && p.pn < rg.hi {
			hit = true
			break
		}
		if !hit {
			i += 1
			continue
		}
		if p.pn == largest {
			largest_found = true
			largest_time = p.time
		}
		if p.ack_eliciting do acked_any_eliciting = true
		on_frames_acked(c, space, p.frames[:])
		if p.in_flight do cubic_on_ack(&c.cc, p.size, p.time, now, &c.rtt)
		delete(p.frames)
		ordered_remove(&sp.sent, i)
	}
	_ = largest_newly
	if i64(largest) > sp.largest_acked do sp.largest_acked = i64(largest)
	if largest_found && acked_any_eliciting {
		ack_delay := time.Duration(delay << c.params.ack_delay_exp) * time.Microsecond if space == .App else 0
		rtt_update(&c.rtt, time.tick_diff(largest_time, now), ack_delay, space_max_ack_delay(c, space), c.handshake_confirmed)
	}
	detect_lost(c, space, now)
	c.pto_count = 0
	return true
}

@(private)
on_frames_acked :: proc(c: ^Conn, space: Space, frames: []Sent_Frame) {
	sp := &c.spaces[space]
	for f in frames {
		#partial switch f.kind {
		case .Crypto:
			sb_on_ack(&sp.crypto_send, f.lo, f.hi, false)
		case .Stream:
			if st, ok := c.streams[f.id]; ok {
				sb_on_ack(&st.send, f.lo, f.hi, f.fin)
				sync.cond_broadcast(&c.cond)
				maybe_free_stream(c, st)
			}
		case .Ack:
			// The peer has our ACK up to f.hi: stop repeating those ranges.
			if i64(f.hi) < sp.largest_rx do rs_remove(&sp.recv_pns, 0, f.hi + 1)
		}
	}
}

@(private)
on_frames_lost :: proc(c: ^Conn, space: Space, frames: []Sent_Frame) {
	sp := &c.spaces[space]
	for f in frames {
		switch f.kind {
		case .Crypto:
			sb_on_lost(&sp.crypto_send, f.lo, f.hi, false)
		case .Stream:
			if st, ok := c.streams[f.id]; ok && !st.reset_sent do sb_on_lost(&st.send, f.lo, f.hi, f.fin)
		case .Max_Data, .Max_Stream_Data, .Reset_Stream, .Stop_Sending, .Retire_Cid, .Max_Streams_Uni:
			append(&c.ctrl, Ctrl{kind = f.kind, id = f.id, code = f.lo})
		case .Ack, .Ping, .Path_Response:
		}
	}
}

@(private)
detect_lost :: proc(c: ^Conn, space: Space, now: time.Tick) {
	sp := &c.spaces[space]
	sp.has_loss_time = false
	if sp.largest_acked < 0 do return
	delay := loss_delay(&c.rtt)
	lost_any := false
	latest_lost: time.Tick
	i := 0
	for i < len(sp.sent) {
		p := &sp.sent[i]
		if i64(p.pn) > sp.largest_acked {
			i += 1
			continue
		}
		age := time.tick_diff(p.time, now)
		if sp.largest_acked - i64(p.pn) >= PACKET_THRESHOLD || age >= delay {
			on_frames_lost(c, space, p.frames[:])
			if p.in_flight {
				cubic_on_removed(&c.cc, p.size)
				lost_any = true
				latest_lost = p.time
			}
			delete(p.frames)
			ordered_remove(&sp.sent, i)
			continue
		}
		t := time.tick_add(p.time, delay)
		if !sp.has_loss_time || time.tick_diff(t, sp.loss_time) > 0 {
			sp.loss_time = t
			sp.has_loss_time = true
		}
		i += 1
	}
	if lost_any do cubic_on_congestion(&c.cc, latest_lost, now)
}

// pto_deadline returns the earliest probe timeout across spaces.
@(private)
pto_deadline :: proc(c: ^Conn) -> (t: time.Tick, space: Space, ok: bool) {
	backoff := time.Duration(1) << uint(min(c.pto_count, PTO_MAX_BACKOFF))
	for s in Space {
		sp := &c.spaces[s]
		if sp.discarded || !sp.tx.valid do continue
		if s == .App && !c.handshake_complete do continue
		if !sp.has_ack_eliciting {
			continue
		}
		in_flight := false
		for p in sp.sent do if p.ack_eliciting {
			in_flight = true
			break
		}
		if !in_flight do continue
		d := time.tick_add(sp.last_ack_eliciting, pto_base(&c.rtt, space_max_ack_delay(c, s)) * backoff)
		if !ok || time.tick_diff(d, t) > 0 {
			t, space, ok = d, s, true
		}
	}
	// Anti-deadlock: before the handshake completes the client keeps a timer
	// armed even with nothing in flight (RFC 9002 6.2.2.1).
	if !ok && !c.handshake_complete && c.initial_sent {
		s: Space = .Handshake if c.spaces[.Handshake].tx.valid else .Initial
		last := c.spaces[s].last_ack_eliciting if c.spaces[s].has_ack_eliciting else c.last_activity
		t = time.tick_add(last, pto_base(&c.rtt, 0) * backoff)
		space = s
		ok = true
	}
	return
}

@(private)
on_timers_locked :: proc(c: ^Conn, now: time.Tick) {
	if c.closing do return
	if time.tick_diff(c.last_activity, now) > c.idle_timeout {
		// Silent close, as Chrome does on idle timeout.
		if c.err == .None do c.err = .Timeout
		c.closing = true
		c.close_sent = true
		sync.cond_broadcast(&c.cond)
		return
	}
	if !c.handshake_complete && time.tick_diff(c.handshake_deadline, now) > 0 {
		fail_locked(c, .Timeout, ERR_NO_ERROR)
		return
	}
	for s in Space {
		sp := &c.spaces[s]
		if sp.has_loss_time && time.tick_diff(sp.loss_time, now) >= 0 do detect_lost(c, s, now)
		if sp.ack_timer && time.tick_diff(sp.ack_deadline, now) >= 0 {
			sp.ack_now = true
			sp.ack_timer = false
		}
	}
	if t, s, ok := pto_deadline(c); ok && time.tick_diff(t, now) >= 0 {
		c.pto_count += 1
		sp := &c.spaces[s]
		// Probe with the unacknowledged data of that space (or a PING).
		for p in sp.sent do if p.ack_eliciting do on_frames_lost(c, s, p.frames[:])
		sp.probes = 2
	}
}

@(private)
next_timeout_locked :: proc(c: ^Conn, now: time.Tick) -> time.Duration {
	best := c.idle_timeout - time.tick_diff(c.last_activity, now)
	consider :: proc(best: ^time.Duration, now, t: time.Tick) {
		d := time.tick_diff(now, t)
		if d < best^ do best^ = d
	}
	if !c.handshake_complete do consider(&best, now, c.handshake_deadline)
	for s in Space {
		sp := &c.spaces[s]
		if sp.has_loss_time do consider(&best, now, sp.loss_time)
		if sp.ack_timer do consider(&best, now, sp.ack_deadline)
	}
	if t, _, ok := pto_deadline(c); ok do consider(&best, now, t)
	return clamp(best, time.Millisecond, 5 * time.Second)
}

// --- Packet assembly ---

Packet_Builder :: struct {
	space:         Space,
	payload:       [dynamic]byte,
	frames:        [dynamic]Sent_Frame,
	ack_eliciting: bool,
	has_padding:   bool,
	// Position of the last STREAM frame's length field, to drop it if last.
	last_stream:   int,
	last_len_off:  int,
	last_len_size: int,
}

@(private)
long_header_len :: proc(c: ^Conn, space: Space, pn_len: int) -> int {
	n := 1 + 4 + 1 + c.dcid_len + 1 + 2 + pn_len
	if space == .Initial do n += varint_len(u64(len(c.token))) + len(c.token)
	return n
}

@(private)
header_len :: proc(c: ^Conn, space: Space, pn_len: int) -> int {
	if space == .App do return 1 + c.dcid_len + pn_len
	return long_header_len(c, space, pn_len)
}

@(private)
pn_length :: proc(c: ^Conn, space: Space) -> int {
	unacked := i64(c.next_pn) - c.spaces[space].largest_acked
	if unacked < 128 do return 1
	if unacked < 1 << 15 do return 2
	if unacked < 1 << 23 do return 3
	return 4
}

@(private)
put_ack_frame :: proc(c: ^Conn, sp: ^Pn_Space, b: ^Packet_Builder, now: time.Tick) {
	if len(sp.recv_pns) == 0 do return
	largest := u64(sp.largest_rx)
	delay_us := u64(max(time.duration_microseconds(time.tick_diff(sp.largest_rx_time, now)), 0))
	put_varint(&b.payload, 0x02)
	put_varint(&b.payload, largest)
	put_varint(&b.payload, delay_us >> 3) // our ack_delay_exponent is the default 3
	n := len(sp.recv_pns)
	put_varint(&b.payload, u64(n - 1))
	top := sp.recv_pns[n - 1]
	put_varint(&b.payload, top.hi - 1 - top.lo)
	lo := top.lo
	for i := n - 2; i >= 0; i -= 1 {
		r := sp.recv_pns[i]
		put_varint(&b.payload, lo - r.hi - 1)
		put_varint(&b.payload, r.hi - 1 - r.lo)
		lo = r.lo
	}
	append(&b.frames, Sent_Frame{kind = .Ack, hi = largest})
	sp.unacked_eliciting = 0
	sp.ack_now = false
	sp.ack_timer = false
}

@(private)
put_crypto_frames :: proc(sp: ^Pn_Space, b: ^Packet_Builder, budget: int) {
	for sb_has_pending(&sp.crypto_send) {
		room := budget - len(b.payload)
		off, data, _ := sb_peek(&sp.crypto_send, room - 1 - varint_len(sp.crypto_send.end) - 2)
		if len(data) == 0 do break
		put_varint(&b.payload, 0x06)
		put_varint(&b.payload, off)
		put_varint(&b.payload, u64(len(data)))
		append(&b.payload, ..data)
		sb_consume(&sp.crypto_send, off, len(data), false)
		append(&b.frames, Sent_Frame{kind = .Crypto, lo = off, hi = off + u64(len(data))})
		b.ack_eliciting = true
	}
}

// fill_packet gathers frames for one packet of `space` within budget bytes of
// payload. ack-eliciting content is only added when allowed (cwnd).
@(private)
fill_packet :: proc(c: ^Conn, space: Space, b: ^Packet_Builder, budget: int, allow_eliciting: bool, now: time.Tick) {
	sp := &c.spaces[space]
	b.space = space
	b.last_stream = -1
	will_elicit := allow_eliciting && has_eliciting_data(c, space)
	if sp.ack_now || (will_elicit && sp.unacked_eliciting > 0) || (sp.ack_timer && will_elicit) {
		put_ack_frame(c, sp, b, now)
	}
	if !allow_eliciting do return
	if space == .App do put_ctrl_frames(c, b, budget)
	put_crypto_frames(sp, b, budget)
	if space == .App do put_stream_frames(c, b, budget)
	if sp.probes > 0 && !b.ack_eliciting {
		put_varint(&b.payload, 0x01)
		append(&b.frames, Sent_Frame{kind = .Ping})
		b.ack_eliciting = true
	}
}

@(private)
has_eliciting_data :: proc(c: ^Conn, space: Space) -> bool {
	sp := &c.spaces[space]
	if sb_has_pending(&sp.crypto_send) || sp.probes > 0 do return true
	if space != .App do return false
	if len(c.ctrl) > 0 do return true
	for _, st in c.streams do if stream_can_send(c, st) do return true
	return false
}

@(private)
needs_send :: proc(c: ^Conn, space: Space) -> bool {
	sp := &c.spaces[space]
	if sp.discarded || !sp.tx.valid do return false
	if space == .App && !c.handshake_complete && !sb_has_pending(&sp.crypto_send) && !sp.ack_now do return false
	return sp.ack_now || has_eliciting_data(c, space)
}

// seal_packet writes header + payload + tag into out and records the packet.
@(private)
seal_packet :: proc(c: ^Conn, b: ^Packet_Builder, pn_len: int, out: ^[dynamic]byte, now: time.Tick) -> int {
	sp := &c.spaces[b.space]
	// Header protection samples 16 bytes starting 4 after the packet number.
	for pn_len + len(b.payload) < 4 do append(&b.payload, 0)
	pn := c.next_pn
	c.next_pn += 1
	start := len(out)
	pn_off: int
	if b.space == .App {
		append(out, 0x40 | c.key_phase << 2 | u8(pn_len - 1))
		append(out, ..c.dcid[:c.dcid_len])
		pn_off = len(out) - start
	} else {
		typ: u8 = 0 if b.space == .Initial else 2
		append(out, 0xc0 | typ << 4 | u8(pn_len - 1))
		put_u32(out, QUIC_V1)
		append(out, u8(c.dcid_len))
		append(out, ..c.dcid[:c.dcid_len])
		append(out, 0) // empty SCID, like Chrome
		if b.space == .Initial {
			put_varint(out, u64(len(c.token)))
			append(out, ..c.token[:])
		}
		put_varint_n(out, u64(pn_len + len(b.payload) + AEAD_TAG), 2)
		pn_off = len(out) - start
	}
	for i := pn_len - 1; i >= 0; i -= 1 do append(out, u8(pn >> uint(8 * i)))
	hdr := len(out) - start
	append(out, ..b.payload[:])
	for _ in 0 ..< AEAD_TAG do append(out, 0)
	pkt := out[start:]
	if debug_log do fmt.eprintfln("[quic] %v tx %v pn=%d len=%d frames=%v", time.tick_now(), b.space, pn, len(pkt), b.frames[:])
	seal(&sp.tx, pkt, hdr, pn_off, pn_len, pn)

	in_flight := b.ack_eliciting || b.has_padding
	frames := b.frames
	b.frames = nil
	append(&sp.sent, Sent_Packet{pn = pn, time = now, size = len(pkt), ack_eliciting = b.ack_eliciting, in_flight = in_flight, frames = frames})
	if in_flight do cubic_on_sent(&c.cc, len(pkt))
	if b.ack_eliciting {
		sp.last_ack_eliciting = now
		sp.has_ack_eliciting = true
		if sp.probes > 0 do sp.probes -= 1
	}
	return len(pkt)
}

@(private)
builder_reset :: proc(b: ^Packet_Builder) {
	clear(&b.payload)
	delete(b.frames)
	b.frames = nil
	b.ack_eliciting = false
	b.has_padding = false
	b.last_stream = -1
}

// drop_last_stream_len removes the length field of a trailing STREAM frame
// (QUICHE omits it on the last frame of a packet).
@(private)
drop_last_stream_len :: proc(b: ^Packet_Builder) {
	if b.last_stream < 0 do return
	remove_range(&b.payload, b.last_len_off, b.last_len_off + b.last_len_size)
	b.payload[b.last_stream] &~= 0x02
	b.last_stream = -1
}

@(private)
send_datagram :: proc(c: ^Conn, d: []byte) {
	net.send_udp(c.sock, d, c.peer)
}

// send_pending_locked sends everything that is due, coalescing levels into
// 1250-byte datagrams; datagrams carrying Initial packets are padded to 1250.
send_pending_locked :: proc(c: ^Conn, now: time.Tick) {
	if c.closing {
		if !c.close_sent do send_close(c, now)
		return
	}
	if !c.initial_sent && sb_has_pending(&c.spaces[.Initial].crypto_send) {
		send_chaos_client_hello(c, now)
		return
	}
	dgram := make([dynamic]byte, 0, MAX_DATAGRAM)
	defer delete(dgram)
	builders: [Space]Packet_Builder
	defer for &b in builders {
		delete(b.payload)
		delete(b.frames)
	}
	for _ in 0 ..< 64 {
		clear(&dgram)
		has_initial := false
		sent_handshake := false
		// Pass 1: decide what goes in each packet of this datagram.
		used := 0
		pn_lens: [Space]int
		active: [Space]bool
		for s in Space {
			if !needs_send(c, s) do continue
			pn_lens[s] = pn_length(c, s)
			overhead := header_len(c, s, pn_lens[s]) + AEAD_TAG
			budget := MAX_DATAGRAM - used - overhead
			if budget < 32 do break
			allow := cubic_can_send(&c.cc, MAX_DATAGRAM) || c.spaces[s].probes > 0
			builder_reset(&builders[s])
			fill_packet(c, s, &builders[s], budget, allow, now)
			if len(builders[s].payload) == 0 do continue
			active[s] = true
			used += overhead + len(builders[s].payload)
			if s == .Initial do has_initial = true
		}
		if used == 0 do break
		// Initial-carrying datagrams are padded to the full size inside the
		// Initial packet (as Chrome does, even when Handshake follows).
		if has_initial && used < MAX_DATAGRAM {
			b := &builders[.Initial]
			drop_last_stream_len(b)
			for _ in 0 ..< MAX_DATAGRAM - used do append(&b.payload, 0)
			b.has_padding = true
		}
		for s in Space {
			if !active[s] do continue
			if s != .Initial || !has_initial do drop_last_stream_len(&builders[s])
			seal_packet(c, &builders[s], pn_lens[s], &dgram, now)
			if s == .Handshake do sent_handshake = true
		}
		send_datagram(c, dgram[:])
		sync.cond_broadcast(&c.cond) // wake flush() waiters
		// A client drops Initial keys once it sends a Handshake packet (RFC 9001 4.9.1).
		if sent_handshake do discard_space(c, .Initial)
	}
}

// send_close sends CONNECTION_CLOSE at the highest level available.
@(private)
send_close :: proc(c: ^Conn, now: time.Tick) {
	c.close_sent = true
	space: Space = .Initial
	if c.handshake_complete && c.spaces[.App].tx.valid {
		space = .App
	} else if c.spaces[.Handshake].tx.valid {
		space = .Handshake
	} else if !c.spaces[.Initial].tx.valid {
		return
	}
	b: Packet_Builder
	defer delete(b.payload)
	defer delete(b.frames)
	b.space = space
	b.last_stream = -1
	app := c.close_app && space == .App
	if app {
		put_varint(&b.payload, 0x1d)
		put_varint(&b.payload, c.close_code)
	} else {
		put_varint(&b.payload, 0x1c)
		// Application errors are sent as APPLICATION_ERROR before 1-RTT.
		put_varint(&b.payload, c.close_code if !c.close_app else 0x0c)
		put_varint(&b.payload, 0)
	}
	put_varint(&b.payload, 0)
	dgram := make([dynamic]byte, 0, MAX_DATAGRAM)
	defer delete(dgram)
	pn_len := pn_length(c, space)
	if space == .Initial {
		pad := MAX_DATAGRAM - (header_len(c, space, pn_len) + AEAD_TAG + len(b.payload))
		for _ in 0 ..< pad do append(&b.payload, 0)
	}
	seal_packet(c, &b, pn_len, &dgram, now)
	send_datagram(c, dgram[:])
}

// --- Chrome's chaos-protected first flight ---

@(private)
Chaos_Item :: struct {
	kind:   u8, // 0 crypto, 1 ping, 2 padding
	lo, hi: u64,
	pad:    int,
}

// send_chaos_client_hello splits the ClientHello into randomly sized CRYPTO
// fragments spread over two Initial packets, mixed with PING and PADDING
// frames in random order, each datagram exactly 1250 bytes (QUICHE's
// QuicChaosProtector, multi-packet form). The second packet uses a 2-byte
// packet number like Chrome's.
@(private)
send_chaos_client_hello :: proc(c: ^Conn, now: time.Tick) {
	sp := &c.spaces[.Initial]
	total := sp.crypto_send.end
	c.initial_sent = true
	pn_len := [2]int{1, 2}
	caps: [2]int
	for i in 0 ..< 2 do caps[i] = MAX_DATAGRAM - long_header_len(c, .Initial, pn_len[i]) - AEAD_TAG

	frame_cost :: proc(lo, hi: u64) -> int {return 1 + varint_len(lo) + varint_len(hi - lo) + int(hi - lo)}

	// Random cut points.
	nfrag := 10 + int(rand.uint32() % 9)
	cuts: [dynamic]u64
	defer delete(cuts)
	append(&cuts, 0, total)
	for _ in 0 ..< nfrag - 1 do append(&cuts, 1 + u64(rand.uint64() % (total - 1)))
	sort_u64(cuts[:])
	frags: [dynamic]Chaos_Item
	defer delete(frags)
	// Chrome's largest observed fragment is ~480 bytes; keep pieces below
	// that so the two packets can always be balanced.
	MAX_FRAG :: 480
	for i in 0 ..< len(cuts) - 1 {
		lo := cuts[i]
		for lo < cuts[i + 1] {
			hi := min(cuts[i + 1], lo + MAX_FRAG)
			append(&frags, Chaos_Item{kind = 0, lo = lo, hi = hi})
			lo = hi
		}
	}
	rand.shuffle(frags[:])

	pkts: [2][dynamic]Chaos_Item
	defer for p in pkts do delete(p)
	used: [2]int
	pings: [2]int
	for i in 0 ..< 2 {
		pings[i] = 3 + int(rand.uint32() % 6)
		used[i] = pings[i] + 4 // room for the pings and a few padding runs
	}
	for f in frags {
		cost := frame_cost(f.lo, f.hi)
		target := int(rand.uint32() % 2)
		if used[target] + cost > caps[target] do target = 1 - target
		if used[target] + cost > caps[target] {
			// Doesn't fit (huge hello): fall back to plain packetization.
			return
		}
		append(&pkts[target], f)
		used[target] += cost
	}
	for i in 0 ..< 2 {
		for _ in 0 ..< pings[i] do append(&pkts[i], Chaos_Item{kind = 1})
		// Split the leftover into padding runs.
		left := caps[i] - used[i] + 4
		runs := 2 + int(rand.uint32() % 4)
		for r in 0 ..< runs {
			n := left if r == runs - 1 else int(rand.uint32() % u32(max(left / 2, 1)))
			if n <= 0 do continue
			append(&pkts[i], Chaos_Item{kind = 2, pad = n})
			left -= n
		}
		rand.shuffle(pkts[i][:])
	}

	for i in 0 ..< 2 {
		b: Packet_Builder
		b.space = .Initial
		b.last_stream = -1
		for it in pkts[i] {
			switch it.kind {
			case 0:
				put_varint(&b.payload, 0x06)
				put_varint(&b.payload, it.lo)
				put_varint(&b.payload, it.hi - it.lo)
				append(&b.payload, ..sp.crypto_send.data[it.lo - sp.crypto_send.base:it.hi - sp.crypto_send.base])
				sb_consume(&sp.crypto_send, it.lo, int(it.hi - it.lo), false)
				append(&b.frames, Sent_Frame{kind = .Crypto, lo = it.lo, hi = it.hi})
				b.ack_eliciting = true
			case 1:
				put_varint(&b.payload, 0x01)
				b.ack_eliciting = true
			case 2:
				for _ in 0 ..< it.pad do append(&b.payload, 0)
				b.has_padding = true
			}
		}
		// Exact fill.
		for len(b.payload) < caps[i] do append(&b.payload, 0)
		dgram := make([dynamic]byte, 0, MAX_DATAGRAM)
		seal_packet(c, &b, pn_len[i], &dgram, now)
		send_datagram(c, dgram[:])
		delete(dgram)
		delete(b.payload)
		delete(b.frames)
	}
}

@(private)
sort_u64 :: proc(a: []u64) {
	for i in 1 ..< len(a) {
		j := i
		for j > 0 && a[j - 1] > a[j] {
			a[j - 1], a[j] = a[j], a[j - 1]
			j -= 1
		}
	}
}

// debug_log prints every packet sent and received to stderr.
debug_log := false
