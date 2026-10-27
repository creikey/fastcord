// Adaptive jitter buffer for one remote audio stream (20 ms Opus frames).
//
// Target delay follows the RFC 3550 interarrival jitter estimate:
// target = clamp(ceil((2*jitter + 10 ms) / 20 ms) + 1, JB_MIN, JB_MAX) frames.
// Playout starts once `target` frames are queued; a missing frame is
// recovered from the next packet's in-band FEC when that packet is already
// here, otherwise concealed (PLC). After JB_STOP_AFTER empty ticks (end of a
// talk spurt) playout stops so the next spurt re-buffers. When the queue grows
// past target + JB_SHRINK_SLACK a frame is dropped to cut latency.

JB_SLOTS :: 64;
JB_MIN :: 2;
JB_MAX :: 12;
JB_STOP_AFTER :: 5;
JB_SHRINK_SLACK :: 3;

Jb_Packet :: struct {
    valid: bool;
    seq: u16;
    ts: u32;
    len: int;
    data: [MAX_OPUS_PACKET]u8;
}

Pop_Kind :: enum u8 {
    None;    // nothing to play (not started / talk spurt over)
    Packet;
    Fec;     // decode data with fec=true (data is the NEXT packet)
    Plc;     // conceal (data empty)
}

Jitter_Stats :: struct {
    received, late, lost, concealed, fec_recovered, dropped: u64;
    jitter_ms: float64;
    target_frames: int;
    buffered: int;
}

Jitter_Buffer :: struct {
    slots: [JB_SLOTS]Jb_Packet;
    playing: bool;
    next_seq: u16;
    target := JB_MIN + 1;
    jitter_ms: float64;
    have_last: bool;
    last_arrival: float64;
    last_ts: u32;
    empty_ticks: int;
    stats: Jitter_Stats;
}

jb_init :: (jb: *Jitter_Buffer) { jb.* = .{}; }

seq_before :: (a: u16, b: u16) -> bool { return cast,no_check(s16) (a - b) < 0; }

jb_buffered :: (jb: *Jitter_Buffer) -> int {
    n := 0;
    for jb.slots if it.valid n += 1;
    return n;
}

jb_push :: (jb: *Jitter_Buffer, seq: u16, ts: u32, payload: []u8, arrival_ms: float64) {
    if payload.count > MAX_OPUS_PACKET return;
    jb.stats.received += 1;
    if jb.playing && seq_before(seq, jb.next_seq) {
        jb.stats.late += 1;
        return;
    }
    // interarrival jitter (RFC 3550 6.4.1), in ms
    if jb.have_last {
        d := (arrival_ms - jb.last_arrival) - cast(float64) cast,no_check(s32) (ts - jb.last_ts) / 48.0;
        jb.jitter_ms += (abs(d) - jb.jitter_ms) / 16.0;
    }
    jb.have_last = true;
    jb.last_arrival = arrival_ms;
    jb.last_ts = ts;
    jb.target = clamp(cast(int) ceil((2 * jb.jitter_ms + 10) / 20) + 1, JB_MIN, JB_MAX);

    s := *jb.slots[seq % JB_SLOTS];
    if s.valid && s.seq == seq return;  // duplicate
    if s.valid jb.stats.dropped += 1;   // overwritten (very late reader)
    s.valid = true;
    s.seq = seq;
    s.ts = ts;
    s.len = payload.count;
    memcpy(s.data.data, payload.data, payload.count);
}

// jb_pop is called once per 20 ms playout tick. The returned view is valid
// until the next push/pop.
jb_pop :: (jb: *Jitter_Buffer) -> kind: Pop_Kind, data: []u8 {
    if jb.playing for * jb.slots if it.valid && seq_before(it.seq, jb.next_seq) {
        it.valid = false;
        jb.stats.late += 1;
    }
    buffered := jb_buffered(jb);
    jb.stats.buffered = buffered;
    jb.stats.target_frames = jb.target;
    jb.stats.jitter_ms = jb.jitter_ms;
    if !jb.playing {
        if buffered < jb.target return .None, .[];
        found := false;
        for jb.slots if it.valid && (!found || seq_before(it.seq, jb.next_seq)) {
            jb.next_seq = it.seq;  // the lowest buffered sequence number
            found = true;
        }
        jb.playing = true;
        jb.empty_ticks = 0;
    }
    if buffered == 0 {
        jb.empty_ticks += 1;
        if jb.empty_ticks >= JB_STOP_AFTER {
            jb.playing = false;
            return .None, .[];
        }
        jb.next_seq += 1;
        jb.stats.concealed += 1;
        return .Plc, .[];
    }
    jb.empty_ticks = 0;
    // latency trim
    if buffered > jb.target + JB_SHRINK_SLACK {
        s := *jb.slots[jb.next_seq % JB_SLOTS];
        if s.valid && s.seq == jb.next_seq s.valid = false;
        jb.next_seq += 1;
        jb.stats.dropped += 1;
    }
    s := *jb.slots[jb.next_seq % JB_SLOTS];
    cur := jb.next_seq;
    jb.next_seq += 1;
    if s.valid && s.seq == cur {
        s.valid = false;
        return .Packet, array_view(s.data, 0, s.len);
    }
    jb.stats.lost += 1;
    n := *jb.slots[jb.next_seq % JB_SLOTS];
    if n.valid && n.seq == jb.next_seq {
        jb.stats.fec_recovered += 1;
        return .Fec, array_view(n.data, 0, n.len);
    }
    jb.stats.concealed += 1;
    return .Plc, .[];
}

jb_reset :: (jb: *Jitter_Buffer) {
    for * jb.slots it.valid = false;
    jb.playing = false;
    jb.have_last = false;
}
