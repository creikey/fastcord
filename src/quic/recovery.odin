package quic

import "core:math"
import "core:time"

// Loss detection and congestion control (RFC 9002), with CUBIC (RFC 9438),
// which is what Chrome's QUIC client uses by default.

INITIAL_RTT :: 100 * time.Millisecond // QUICHE kInitialRttMs
GRANULARITY :: time.Millisecond
PACKET_THRESHOLD :: 3
MAX_DATAGRAM :: 1250 // Chrome never sends larger UDP payloads
CUBIC_MSS :: 1460 // QUICHE counts its windows in kDefaultTCPMSS units
INITIAL_CWND :: 32 * CUBIC_MSS // QUICHE kInitialCongestionWindow
MIN_CWND :: 2 * CUBIC_MSS
CUBIC_C :: 0.4
CUBIC_BETA :: 0.7

Rtt :: struct {
	has_sample: bool,
	latest:     time.Duration,
	min:        time.Duration,
	smoothed:   time.Duration,
	var:        time.Duration,
}

rtt_init :: proc(r: ^Rtt, initial: time.Duration) {
	r^ = {}
	r.smoothed = initial
	r.var = initial / 2
}

rtt_update :: proc(r: ^Rtt, latest, ack_delay, max_ack_delay: time.Duration, confirmed: bool) {
	r.latest = latest
	if !r.has_sample {
		r.has_sample = true
		r.min = latest
		r.smoothed = latest
		r.var = latest / 2
		return
	}
	r.min = min(r.min, latest)
	delay := ack_delay
	if confirmed do delay = min(delay, max_ack_delay)
	adjusted := latest
	if latest >= r.min + delay do adjusted = latest - delay
	diff := r.smoothed - adjusted
	if diff < 0 do diff = -diff
	r.var = (3 * r.var + diff) / 4
	r.smoothed = (7 * r.smoothed + adjusted) / 8
}

// pto_base is smoothed_rtt + max(4*rttvar, granularity) (+ max_ack_delay for 1-RTT).
pto_base :: proc(r: ^Rtt, max_ack_delay: time.Duration) -> time.Duration {
	return r.smoothed + max(4 * r.var, GRANULARITY) + max_ack_delay
}

loss_delay :: proc(r: ^Rtt) -> time.Duration {
	return max(time.Duration(f64(max(r.latest, r.smoothed)) * 9.0 / 8.0), GRANULARITY)
}

Cubic :: struct {
	cwnd:            int,
	ssthresh:        int,
	in_flight:       int,
	recovery_start:  time.Tick,
	in_recovery:     bool,
	epoch_start:     time.Tick,
	has_epoch:       bool,
	w_max:           f64, // in MSS
	k:               f64,
	acked_in_epoch:  int,
}

cubic_init :: proc(c: ^Cubic) {
	c^ = {}
	c.cwnd = INITIAL_CWND
	c.ssthresh = max(int)
}

cubic_can_send :: proc(c: ^Cubic, bytes: int) -> bool {
	return c.in_flight + bytes <= c.cwnd
}

cubic_on_sent :: proc(c: ^Cubic, bytes: int) {c.in_flight += bytes}

cubic_on_removed :: proc(c: ^Cubic, bytes: int) {c.in_flight = max(c.in_flight - bytes, 0)}

cubic_on_ack :: proc(c: ^Cubic, bytes: int, sent: time.Tick, now: time.Tick, rtt: ^Rtt) {
	cubic_on_removed(c, bytes)
	if c.in_recovery && time.tick_diff(c.recovery_start, sent) <= 0 do return
	c.in_recovery = false
	if c.cwnd < c.ssthresh {
		c.cwnd += bytes
		return
	}
	if !c.has_epoch {
		c.has_epoch = true
		c.epoch_start = now
		if c.w_max < f64(c.cwnd) / CUBIC_MSS do c.w_max = f64(c.cwnd) / CUBIC_MSS
		c.k = math.cbrt(c.w_max * (1 - CUBIC_BETA) / CUBIC_C)
	}
	t := time.duration_seconds(time.tick_diff(c.epoch_start, now)) + time.duration_seconds(rtt.min)
	target := CUBIC_C * math.pow(t - c.k, 3) + c.w_max
	cw := f64(c.cwnd) / CUBIC_MSS
	// Reno-friendly region (RFC 9438 4.3) keeps growth at least TCP-like.
	c.acked_in_epoch += bytes
	reno := c.w_max * CUBIC_BETA + 3 * (1 - CUBIC_BETA) / (1 + CUBIC_BETA) * f64(c.acked_in_epoch) / f64(c.cwnd)
	target = max(target, reno)
	if target > cw {
		inc := (target - cw) / cw * f64(bytes)
		c.cwnd += int(min(inc, f64(bytes)))
	}
}

// cubic_on_congestion handles a loss event for a packet sent at `sent`.
cubic_on_congestion :: proc(c: ^Cubic, sent: time.Tick, now: time.Tick) {
	if c.in_recovery && time.tick_diff(c.recovery_start, sent) <= 0 do return
	c.in_recovery = true
	c.recovery_start = now
	w := f64(c.cwnd) / CUBIC_MSS
	// Fast convergence.
	c.w_max = w * (1 + CUBIC_BETA) / 2 if w < c.w_max else w
	c.cwnd = max(int(f64(c.cwnd) * CUBIC_BETA), MIN_CWND)
	c.ssthresh = c.cwnd
	c.has_epoch = false
	c.acked_in_epoch = 0
}

cubic_persistent_congestion :: proc(c: ^Cubic) {
	c.cwnd = MIN_CWND
	c.has_epoch = false
}
