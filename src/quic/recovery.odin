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

// CUBIC as QUICHE's TcpCubicSenderBytes configures it for Chrome: windows
// in 1460-byte MSS units, 2-connection emulation (beta 0.85, last-max 0.925),
// Reno-friendly region, hybrid slow start, 32-packet initial window.
CUBIC_NUM_CONNECTIONS :: 2
CUBIC_BETA_EFF :: (CUBIC_NUM_CONNECTIONS - 1 + CUBIC_BETA) / CUBIC_NUM_CONNECTIONS // 0.85
CUBIC_BETA_LAST_MAX :: (CUBIC_NUM_CONNECTIONS - 1 + 0.85) / CUBIC_NUM_CONNECTIONS // 0.925
CUBIC_ALPHA :: 3 * CUBIC_NUM_CONNECTIONS * CUBIC_NUM_CONNECTIONS * (1 - CUBIC_BETA_EFF) / (1 + CUBIC_BETA_EFF)
HYSTART_LOW_WINDOW :: 16 * CUBIC_MSS
HYSTART_MIN_SAMPLES :: 8
HYSTART_DELAY_MIN :: 4 * time.Millisecond
HYSTART_DELAY_MAX :: 16 * time.Millisecond

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
	// Hybrid slow start round tracking.
	hs_round_end:    u64,
	hs_in_round:     bool,
	hs_samples:      int,
	hs_round_min:    time.Duration,
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

// cubic_on_rtt_sample runs hybrid slow start (QUICHE HybridSlowStart).
cubic_on_rtt_sample :: proc(c: ^Cubic, rtt: ^Rtt, largest_acked, next_pn: u64) {
	if c.cwnd >= c.ssthresh do return
	if !c.hs_in_round || largest_acked >= c.hs_round_end {
		c.hs_in_round = true
		c.hs_round_end = next_pn
		c.hs_samples = 0
		c.hs_round_min = max(time.Duration)
	}
	if c.hs_samples < HYSTART_MIN_SAMPLES {
		c.hs_samples += 1
		c.hs_round_min = min(c.hs_round_min, rtt.latest)
		return
	}
	if c.cwnd < HYSTART_LOW_WINDOW do return
	thresh := clamp(rtt.min / 8, HYSTART_DELAY_MIN, HYSTART_DELAY_MAX)
	if c.hs_round_min > rtt.min + thresh do c.ssthresh = c.cwnd
}

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
		c.acked_in_epoch = 0
		cw := f64(c.cwnd) / CUBIC_MSS
		if c.w_max <= cw {
			c.k = 0
			c.w_max = cw
		} else {
			c.k = math.cbrt((c.w_max - cw) / CUBIC_C)
		}
	}
	t := time.duration_seconds(time.tick_diff(c.epoch_start, now)) + time.duration_seconds(rtt.min)
	target := CUBIC_C * math.pow(t - c.k, 3) + c.w_max
	cw := f64(c.cwnd) / CUBIC_MSS
	// Reno-friendly region with N-connection alpha.
	c.acked_in_epoch += bytes
	reno := cw + CUBIC_ALPHA * f64(bytes) / f64(c.cwnd)
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
	c.w_max = w * CUBIC_BETA_LAST_MAX if w < c.w_max else w
	c.cwnd = max(int(f64(c.cwnd) * CUBIC_BETA_EFF), MIN_CWND)
	c.ssthresh = c.cwnd
	c.has_epoch = false
}

cubic_persistent_congestion :: proc(c: ^Cubic) {
	c.cwnd = MIN_CWND
	c.has_epoch = false
	c.in_recovery = false
}

// Pacer follows QUICHE's PacingSender: 10 packets unpaced at start and
// after quiescence, then pacing at cwnd/srtt * (2 in slow start, 1.25
// after), with "lumpy" bursts of 2 packets.
PACER_INITIAL_BURST :: 10
PACER_LUMPY :: 2

Pacer :: struct {
	burst_tokens: int,
	lumpy_tokens: int,
	next_send:    time.Tick,
	has_next:     bool,
}

pacer_init :: proc(p: ^Pacer) {
	p^ = {}
	p.burst_tokens = PACER_INITIAL_BURST
}

pacer_can_send :: proc(p: ^Pacer, now: time.Tick) -> bool {
	if p.burst_tokens > 0 || !p.has_next do return true
	return time.tick_diff(p.next_send, now) >= 0
}

pacer_on_sent :: proc(p: ^Pacer, c: ^Cubic, rtt: ^Rtt, bytes: int, now: time.Tick) {
	// Quiescence: refill the initial burst.
	if c.in_flight <= bytes && !c.in_recovery {
		p.burst_tokens = min(PACER_INITIAL_BURST, c.cwnd / CUBIC_MSS)
	}
	if p.burst_tokens > 0 {
		p.burst_tokens -= 1
		return
	}
	// One pacing delay per pair of packets ("lumpy" pacing).
	p.lumpy_tokens += 1
	if p.lumpy_tokens < PACER_LUMPY do return
	p.lumpy_tokens = 0
	gain := 2.0 if c.cwnd < c.ssthresh else 1.25
	srtt := max(rtt.smoothed, time.Millisecond)
	rate := gain * f64(c.cwnd) / time.duration_seconds(srtt) // bytes/s
	delay := time.Duration(f64(bytes * PACER_LUMPY) / rate * f64(time.Second))
	base := now
	if p.has_next && time.tick_diff(now, p.next_send) > 0 do base = p.next_send
	p.next_send = time.tick_add(base, delay)
	p.has_next = true
}
