package quic

import "core:sync"
import "core:time"

Stream :: struct {
	conn:           ^Conn,
	id:             u64,
	// Send side.
	send:           Send_Buf,
	send_high:      u64, // highest offset ever sent (new-data flow control)
	peer_max:       u64, // peer's MAX_STREAM_DATA for us
	reset_sent:     bool,
	stop_code:      u64,
	stopped:        bool, // peer sent STOP_SENDING
	// Receive side.
	recv:           Recv_Buf,
	local_max:      u64, // our advertised limit
	final_size:     i64, // -1 until known
	reset_received: bool,
	reset_code:     u64,
	stop_sent:      bool,
	// Ownership.
	released:       bool, // the app is done with it
	local:          bool,
	uni:            bool,
	uni_type_seen:  bool, // for the h3 layer
}

STREAM_WINDOW :: CHROME_MAX_STREAM_DATA

@(private)
is_local :: proc(id: u64) -> bool {return id & 1 == 0} // client-initiated
@(private)
is_uni :: proc(id: u64) -> bool {return id & 2 != 0}

@(private)
stream_new :: proc(c: ^Conn, id: u64) -> ^Stream {
	st := new(Stream)
	st.conn = c
	st.id = id
	st.local = is_local(id)
	st.uni = is_uni(id)
	st.final_size = -1
	st.local_max = STREAM_WINDOW
	stream_apply_peer_limits(c, st)
	c.streams[id] = st
	return st
}

// stream_apply_peer_limits sets the initial send limit from transport parameters.
stream_apply_peer_limits :: proc(c: ^Conn, st: ^Stream) {
	p := &c.params
	lim: u64
	if st.uni {
		lim = p.msd_uni
	} else if st.local {
		lim = p.msd_bidi_remote // the peer's limit for streams we opened
	} else {
		lim = p.msd_bidi_local
	}
	st.peer_max = max(st.peer_max, lim)
}

@(private)
stream_free :: proc(st: ^Stream) {
	sb_destroy(&st.send)
	rb_destroy(&st.recv)
	free(st, conn_allocator())
}

// open_bidi opens a client bidirectional stream, waiting for stream credit.
open_bidi :: proc(c: ^Conn) -> (^Stream, Error) {return open_stream(c, false)}

// open_uni opens a client unidirectional stream.
open_uni :: proc(c: ^Conn) -> (^Stream, Error) {return open_stream(c, true)}

@(private)
open_stream :: proc(c: ^Conn, uni: bool) -> (^Stream, Error) {
	context.allocator = conn_allocator()
	sync.mutex_lock(&c.mu)
	defer sync.mutex_unlock(&c.mu)
	for {
		if c.err != .None do return nil, c.err
		n := c.next_uni if uni else c.next_bidi
		limit := c.peer_max_uni if uni else c.peer_max_bidi
		if n < limit {
			if uni {
				c.next_uni += 1
			} else {
				c.next_bidi += 1
			}
			return stream_new(c, n << 2 | (2 if uni else 0)), .None
		}
		sync.cond_wait(&c.cond, &c.mu)
	}
}

// open_bidi_locked opens a bidi stream without waiting; nil if no credit.
open_bidi_locked :: proc(c: ^Conn) -> ^Stream {
	context.allocator = conn_allocator()
	if c.err != .None || c.next_bidi >= c.peer_max_bidi do return nil
	n := c.next_bidi
	c.next_bidi += 1
	return stream_new(c, n << 2)
}

// stream_id returns the QUIC stream id.
stream_id :: proc(st: ^Stream) -> u64 {return st.id}

// write queues data (and optionally FIN). It does not wait for flow control.
write :: proc(st: ^Stream, data: []byte, fin := false) -> Error {
	c := st.conn
	context.allocator = conn_allocator()
	sync.mutex_lock(&c.mu)
	e := write_locked(st, data, fin)
	sync.mutex_unlock(&c.mu)
	wake(c)
	return e
}

write_locked :: proc(st: ^Stream, data: []byte, fin := false) -> Error {
	c := st.conn
	context.allocator = conn_allocator()
	if c.err != .None do return c.err
	if st.stopped || st.reset_sent do return .Stream_Reset
	if st.send.fin do return .Closed
	sb_write(&st.send, data)
	if fin do sb_finish(&st.send)
	return .None
}

// read blocks until data, FIN (.Closed) or an error.
read :: proc(st: ^Stream, dst: []byte) -> (int, Error) {
	c := st.conn
	context.allocator = conn_allocator()
	sync.mutex_lock(&c.mu)
	defer sync.mutex_unlock(&c.mu)
	for {
		if st.reset_received do return 0, .Stream_Reset
		avail := rb_readable(&st.recv)
		if len(avail) > 0 {
			n := copy(dst, avail)
			rb_consume(&st.recv, n)
			consumed_locked(c, st, n)
			return n, .None
		}
		if st.final_size >= 0 && st.recv.read_off == u64(st.final_size) do return 0, .Closed
		if c.err != .None do return 0, c.err
		sync.cond_wait(&c.cond, &c.mu)
	}
}

// consumed_locked updates flow-control credit after the app read n bytes.
@(private)
consumed_locked :: proc(c: ^Conn, st: ^Stream, n: int) {
	c.data_consumed += u64(n)
	need_wake := false
	// Re-advertise once half the window is used (QUICHE does likewise).
	if st.final_size < 0 && st.recv.read_off + STREAM_WINDOW / 2 > st.local_max {
		st.local_max = st.recv.read_off + STREAM_WINDOW
		append(&c.ctrl, Ctrl{kind = .Max_Stream_Data, id = st.id})
		need_wake = true
	}
	if c.data_consumed + CHROME_MAX_DATA / 2 > c.local_max_data {
		c.local_max_data = c.data_consumed + CHROME_MAX_DATA
		append(&c.ctrl, Ctrl{kind = .Max_Data})
		need_wake = true
	}
	if need_wake do wake(c)
}

// reset abandons the send side with an application error code.
reset :: proc(st: ^Stream, code: u64) {
	c := st.conn
	context.allocator = conn_allocator()
	sync.mutex_lock(&c.mu)
	reset_locked(st, code)
	sync.mutex_unlock(&c.mu)
	wake(c)
}

reset_locked :: proc(st: ^Stream, code: u64) {
	if st.reset_sent || (st.uni && !st.local) do return
	st.reset_sent = true
	clear(&st.send.pending)
	st.send.fin_pending = false
	append(&st.conn.ctrl, Ctrl{kind = .Reset_Stream, id = st.id, code = code})
}

// stop_sending asks the peer to stop sending on the stream.
stop_sending :: proc(st: ^Stream, code: u64) {
	c := st.conn
	context.allocator = conn_allocator()
	sync.mutex_lock(&c.mu)
	stop_sending_locked(st, code)
	sync.mutex_unlock(&c.mu)
	wake(c)
}

stop_sending_locked :: proc(st: ^Stream, code: u64) {
	if st.stop_sent || (st.uni && st.local) do return
	st.stop_sent = true
	append(&st.conn.ctrl, Ctrl{kind = .Stop_Sending, id = st.id, code = code})
}

// release tells the connection the app no longer uses st; it is freed once
// both directions are finished.
release :: proc(st: ^Stream) {
	c := st.conn
	sync.mutex_lock(&c.mu)
	st.released = true
	maybe_free_stream(c, st)
	sync.mutex_unlock(&c.mu)
}

@(private)
maybe_free_stream :: proc(c: ^Conn, st: ^Stream) {
	if !st.released do return
	send_done := (st.uni && !st.local) || st.reset_sent || sb_all_acked(&st.send)
	recv_done := (st.uni && st.local) || st.reset_received || (st.final_size >= 0 && st.recv.read_off == u64(st.final_size)) || st.stop_sent
	if send_done && recv_done && !st.reset_sent {
		delete_key(&c.streams, st.id)
		stream_free(st)
	}
}

@(private)
stream_can_send :: proc(c: ^Conn, st: ^Stream) -> bool {
	if st.reset_sent || st.stopped || (st.uni && !st.local) do return false
	if !sb_has_pending(&st.send) do return false
	if len(st.send.pending) == 0 do return true // bare FIN
	lo := st.send.pending[0].lo
	if lo < st.send_high do return true // retransmission
	return lo < st.peer_max && c.data_sent < c.peer_max_data
}

// get_or_open_peer finds a stream for an incoming frame, creating
// peer-initiated streams on first use.
@(private)
get_stream :: proc(c: ^Conn, id: u64) -> (st: ^Stream, ok: bool) {
	if s, found := c.streams[id]; found do return s, true
	if is_local(id) {
		// A stream we opened and already freed, or never opened.
		n := id >> 2
		opened := c.next_uni if is_uni(id) else c.next_bidi
		if n >= opened do fail_locked(c, .Protocol, ERR_STREAM_STATE)
		return nil, n < opened
	}
	limit: u64 = CHROME_MAX_STREAMS_UNI if is_uni(id) else CHROME_MAX_STREAMS_BIDI
	if id >> 2 >= limit {
		fail_locked(c, .Protocol, ERR_STREAM_LIMIT)
		return nil, false
	}
	return stream_new(c, id), true
}

@(private)
on_stream_frame :: proc(c: ^Conn, id, off: u64, data: []byte, fin: bool) -> bool {
	if is_local(id) && is_uni(id) {
		fail_locked(c, .Protocol, ERR_STREAM_STATE)
		return false
	}
	st, ok := get_stream(c, id)
	if !ok do return c.err == .None
	if st == nil do return true
	end := off + u64(len(data))
	if end > st.local_max {
		fail_locked(c, .Flow_Control, ERR_FLOW_CONTROL)
		return false
	}
	if st.final_size >= 0 && end > u64(st.final_size) {
		fail_locked(c, .Protocol, ERR_FINAL_SIZE)
		return false
	}
	if fin {
		if st.final_size >= 0 && u64(st.final_size) != end || end < st.recv.highest {
			fail_locked(c, .Protocol, ERR_FINAL_SIZE)
			return false
		}
		st.final_size = i64(end)
	}
	if end > st.recv.highest {
		c.data_received += end - st.recv.highest
		if c.data_received > c.local_max_data {
			fail_locked(c, .Flow_Control, ERR_FLOW_CONTROL)
			return false
		}
	}
	if st.reset_received do return true
	if !st.local && st.uni && c.uni_handler != nil {
		// Peer uni streams go straight to the handler, in order.
		rb_insert(&st.recv, off, data)
		avail := rb_readable(&st.recv)
		done := st.final_size >= 0 && st.recv.read_off + u64(len(avail)) == u64(st.final_size)
		if len(avail) > 0 || done {
			n := len(avail)
			c.uni_handler(c.uni_user, st, avail, done)
			rb_consume(&st.recv, n)
			consumed_locked(c, st, n)
		}
		return c.err == .None
	}
	rb_insert(&st.recv, off, data)
	sync.cond_broadcast(&c.cond)
	return true
}

@(private)
on_reset_stream :: proc(c: ^Conn, id, code, final: u64) -> bool {
	if is_local(id) && is_uni(id) {
		fail_locked(c, .Protocol, ERR_STREAM_STATE)
		return false
	}
	st, ok := get_stream(c, id)
	if !ok do return c.err == .None
	if st == nil do return true
	if st.final_size >= 0 && u64(st.final_size) != final || final < st.recv.highest {
		fail_locked(c, .Protocol, ERR_FINAL_SIZE)
		return false
	}
	st.final_size = i64(final)
	st.reset_received = true
	st.reset_code = code
	sync.cond_broadcast(&c.cond)
	maybe_free_stream(c, st)
	return true
}

@(private)
on_stop_sending :: proc(c: ^Conn, id, code: u64) -> bool {
	if !is_local(id) && is_uni(id) {
		fail_locked(c, .Protocol, ERR_STREAM_STATE)
		return false
	}
	st, ok := get_stream(c, id)
	if !ok do return c.err == .None
	if st == nil do return true
	st.stopped = true
	st.stop_code = code
	// Answer with RESET_STREAM carrying the same code (RFC 9000 3.5).
	reset_locked(st, code)
	sync.cond_broadcast(&c.cond)
	return true
}

@(private)
on_max_stream_data :: proc(c: ^Conn, id, v: u64) -> bool {
	if !is_local(id) && is_uni(id) {
		fail_locked(c, .Protocol, ERR_STREAM_STATE)
		return false
	}
	st, ok := get_stream(c, id)
	if !ok do return c.err == .None
	if st != nil && v > st.peer_max do st.peer_max = v
	return true
}

// put_ctrl_frames writes queued control frames that fit.
@(private)
put_ctrl_frames :: proc(c: ^Conn, b: ^Packet_Builder, budget: int) {
	i := 0
	for i < len(c.ctrl) {
		if budget - len(b.payload) < 32 do return
		ct := c.ctrl[i]
		sf := Sent_Frame{kind = ct.kind, id = ct.id, lo = ct.code}
		switch ct.kind {
		case .Max_Data:
			put_varint(&b.payload, 0x10)
			put_varint(&b.payload, c.local_max_data)
		case .Max_Stream_Data:
			st, found := c.streams[ct.id]
			if !found || st.final_size >= 0 {
				ordered_remove(&c.ctrl, i)
				continue
			}
			put_varint(&b.payload, 0x11)
			put_varint(&b.payload, ct.id)
			put_varint(&b.payload, st.local_max)
		case .Reset_Stream:
			st, found := c.streams[ct.id]
			final := st.send.end if found else 0
			put_varint(&b.payload, 0x04)
			put_varint(&b.payload, ct.id)
			put_varint(&b.payload, ct.code)
			put_varint(&b.payload, final)
		case .Stop_Sending:
			put_varint(&b.payload, 0x05)
			put_varint(&b.payload, ct.id)
			put_varint(&b.payload, ct.code)
		case .Retire_Cid:
			put_varint(&b.payload, 0x19)
			put_varint(&b.payload, ct.id)
		case .Path_Response:
			put_varint(&b.payload, 0x1b)
			append(&b.payload, ..ct.data[:])
		case .Max_Streams_Uni:
			put_varint(&b.payload, 0x13)
			put_varint(&b.payload, ct.id)
		case .Ping:
			put_varint(&b.payload, 0x01)
		case .Ack, .Crypto, .Stream:
		}
		append(&b.frames, sf)
		b.ack_eliciting = true
		ordered_remove(&c.ctrl, i)
	}
}

// put_stream_frames adds STREAM frames: client uni streams (h3 control)
// first, then bidi streams by id, like QUICHE's static-stream priority.
@(private)
put_stream_frames :: proc(c: ^Conn, b: ^Packet_Builder, budget: int) {
	ids := make([dynamic]u64, 0, len(c.streams), context.temp_allocator)
	for id, st in c.streams do if stream_can_send(c, st) do append(&ids, id)
	if len(ids) == 0 do return
	// Sort: uni first, then by id.
	key :: proc(id: u64) -> u64 {return (0 if is_uni(id) else 1 << 63) | id}
	for i in 1 ..< len(ids) {
		j := i
		for j > 0 && key(ids[j - 1]) > key(ids[j]) {
			ids[j - 1], ids[j] = ids[j], ids[j - 1]
			j -= 1
		}
	}
	for id in ids {
		st := c.streams[id]
		for stream_can_send(c, st) {
			room := budget - len(b.payload)
			if room < 8 do return
			off := st.send.pending[0].lo if len(st.send.pending) > 0 else st.send.end
			hdr := 1 + varint_len(id) + (varint_len(off) if off > 0 else 0) + 2
			// New data is limited by stream and connection credit.
			limit := st.peer_max
			if off >= st.send_high do limit = min(limit, st.send_high + (c.peer_max_data - c.data_sent))
			o, data, fin := sb_peek(&st.send, room - hdr, limit)
			if len(data) == 0 && !fin do break
			start := len(b.payload)
			typ: u8 = 0x08 | 0x02
			if o > 0 do typ |= 0x04
			if fin do typ |= 0x01
			append(&b.payload, typ)
			put_varint(&b.payload, id)
			if o > 0 do put_varint(&b.payload, o)
			len_off := len(b.payload)
			put_varint_n(&b.payload, u64(len(data)), 2 if len(data) >= 64 else 1)
			b.last_stream = start
			b.last_len_off = len_off
			b.last_len_size = len(b.payload) - len_off
			append(&b.payload, ..data)
			end := o + u64(len(data))
			if end > st.send_high {
				c.data_sent += end - max(o, st.send_high)
				st.send_high = end
			}
			sb_consume(&st.send, o, len(data), fin)
			append(&b.frames, Sent_Frame{kind = .Stream, id = id, lo = o, hi = end, fin = fin})
			b.ack_eliciting = true
		}
	}
}

// set_uni_handler installs the callback for peer-initiated uni streams.
set_uni_handler :: proc(c: ^Conn, h: Uni_Handler, user: rawptr) {
	sync.mutex_lock(&c.mu)
	c.uni_handler = h
	c.uni_user = user
	sync.mutex_unlock(&c.mu)
}

// lock / unlock give layered protocols (h3) access to the connection lock
// for state shared with the I/O thread.
lock :: proc(c: ^Conn) {sync.mutex_lock(&c.mu)}
unlock :: proc(c: ^Conn) {sync.mutex_unlock(&c.mu)}

// wait blocks on the connection condition (lock held); returns c.err.
wait_locked :: proc(c: ^Conn) -> Error {
	sync.cond_wait(&c.cond, &c.mu)
	return c.err
}

broadcast_locked :: proc(c: ^Conn) {sync.cond_broadcast(&c.cond)}

conn_error :: proc(c: ^Conn) -> Error {return c.err}

// rtt returns the smoothed RTT (for Chrome's cached initial_rtt).
smoothed_rtt :: proc(c: ^Conn) -> time.Duration {return c.rtt.smoothed}

// abort_locked closes the connection with an application error code (e.g.
// an HTTP/3 error) from inside a Uni_Handler or with the lock held.
abort_locked :: proc(c: ^Conn, code: u64) {
	if c.err == .None do c.err = .Protocol
	start_close_locked(c, code, true)
}

// open_uni_locked opens a uni stream without waiting; nil if no credit.
open_uni_locked :: proc(c: ^Conn) -> ^Stream {
	context.allocator = conn_allocator()
	if c.err != .None || c.next_uni >= c.peer_max_uni do return nil
	n := c.next_uni
	c.next_uni += 1
	return stream_new(c, n << 2 | 2)
}

// flush waits until everything written to st has been sent once (not acked).
flush :: proc(st: ^Stream) -> Error {
	c := st.conn
	wake(c)
	sync.mutex_lock(&c.mu)
	defer sync.mutex_unlock(&c.mu)
	for st.send_high < st.send.end && len(st.send.pending) > 0 {
		if c.err != .None do return c.err
		sync.cond_wait(&c.cond, &c.mu)
	}
	return .None
}
