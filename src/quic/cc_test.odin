package quic

import "core:testing"
import "core:time"

@(test)
pacer_initial_burst_then_paced :: proc(t: ^testing.T) {
	p: Pacer
	pacer_init(&p)
	c: Cubic
	cubic_init(&c)
	r: Rtt
	rtt_init(&r, 100 * time.Millisecond)
	now := time.tick_now()
	sent := 0
	for pacer_can_send(&p, now) && sent < 100 {
		cubic_on_sent(&c, MAX_DATAGRAM)
		pacer_on_sent(&p, &c, &r, MAX_DATAGRAM, now)
		sent += 1
	}
	// 10 unpaced + one lumpy pair before the first delay.
	testing.expect_value(t, sent, PACER_INITIAL_BURST + PACER_LUMPY)
	later := time.tick_add(now, 50 * time.Millisecond)
	testing.expect(t, pacer_can_send(&p, later))
}

@(test)
cubic_loss_uses_quiche_beta :: proc(t: ^testing.T) {
	c: Cubic
	cubic_init(&c)
	now := time.tick_now()
	before := c.cwnd
	cubic_on_congestion(&c, now, time.tick_add(now, time.Millisecond))
	testing.expect_value(t, c.cwnd, int(f64(before) * 0.85))
	// A second loss from the same flight is the same congestion event.
	cubic_on_congestion(&c, now, time.tick_add(now, 2 * time.Millisecond))
	testing.expect_value(t, c.cwnd, int(f64(before) * 0.85))
	cubic_persistent_congestion(&c)
	testing.expect_value(t, c.cwnd, MIN_CWND)
}

@(test)
zero_rtt_rejection_requeues_data :: proc(t: ^testing.T) {
	context.allocator = conn_allocator()
	c := new(Conn)
	conn_init(c, {})
	c.peer_max_bidi = 10
	c.peer_max_data = 1 << 20
	st := stream_new(c, 0)
	st.peer_max = 1 << 20
	sb_write(&st.send, transmute([]byte)string("GET request bytes"))
	sb_finish(&st.send)
	// Pretend it went out as 0-RTT.
	b: Packet_Builder
	b.space = .App
	b.zero_rtt = true
	put_stream_frames(c, &b, 1000)
	testing.expect(t, !sb_has_pending(&st.send))
	append(&c.spaces[.App].sent, Sent_Packet{pn = 3, zero_rtt = true, ack_eliciting = true, in_flight = true, size = 100, frames = b.frames})
	b.frames = nil
	delete(b.payload)
	cubic_on_sent(&c.cc, 100)
	reject_zero_rtt_locked(c)
	testing.expect_value(t, c.early, Early_State.Rejected)
	testing.expect_value(t, len(c.spaces[.App].sent), 0)
	testing.expect_value(t, c.cc.in_flight, 0)
	off, data, fin := sb_peek(&st.send, 1000)
	testing.expect(t, off == 0 && string(data) == "GET request bytes" && fin, "data requeued for 1-RTT")
	conn_destroy(c)
}

// A PTO skips one packet number before the probes, as QUICHE does.
@(test)
pto_skips_packet_number :: proc(t: ^testing.T) {
	context.allocator = conn_allocator()
	c := new(Conn)
	conn_init(c, {})
	c.initial_sent = true
	then := time.tick_now()
	sp := &c.spaces[.Initial]
	append(&sp.sent, Sent_Packet{pn = 1, time = then, ack_eliciting = true, in_flight = true, size = 1250})
	sp.last_ack_eliciting = then
	sp.has_ack_eliciting = true
	c.next_pn = 2
	c.last_activity = then
	on_timers_locked(c, time.tick_add(then, 2 * time.Second))
	testing.expect_value(t, c.next_pn, 3)
	testing.expect_value(t, sp.probes, 2)
	testing.expect_value(t, c.pto_count, 1)
	conn_destroy(c)
}
