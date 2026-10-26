// Package quic is a QUIC v1 client (RFC 9000/9001/9002) over UDP whose
// wire behaviour follows Chrome 148: 8-byte DCID, empty SCID, 1250-byte
// datagrams, chaos-protected (fragmented, PING/PADDING interleaved, two
// packet) Initial ClientHello, a single packet-number counter starting at 1,
// Chrome's transport parameters in random order, QUICHE's ACK decimation,
// CUBIC congestion control and no connection migration. The TLS handshake
// is fc:tls's engine with its Chrome QUIC ClientHello profile.
//
// Threading: each Conn runs one I/O thread. Streams may be used from any
// threads (one reader and one writer per stream at a time).
package quic

import "base:runtime"
import "core:crypto"
import "core:fmt"
import "core:net"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

import "fc:tls"

Error :: enum u8 {
	None,
	Io,
	Closed, // stream FIN reached, or the connection was closed locally
	Timeout, // idle timeout / handshake timeout
	Tls, // handshake failed (see Conn.tls_error)
	Protocol, // peer violated the protocol
	Flow_Control,
	Stream_Reset, // peer reset the stream (see Stream.reset_code)
	Peer_Closed, // CONNECTION_CLOSE from the peer (see Conn.peer_code)
	Version_Negotiation,
	Dns,
	Internal,
}

Space :: enum u8 {
	Initial,
	Handshake,
	App,
}

Frame_Kind :: enum u8 {
	Ack,
	Crypto,
	Stream,
	Max_Data,
	Max_Stream_Data,
	Ping,
	Reset_Stream,
	Stop_Sending,
	Retire_Cid,
	Path_Response,
	Max_Streams_Uni,
}

Sent_Frame :: struct {
	kind:   Frame_Kind,
	id:     u64, // stream id / sequence number
	lo, hi: u64,
	fin:    bool,
}

Sent_Packet :: struct {
	pn:            u64,
	time:          time.Tick,
	size:          int,
	ack_eliciting: bool,
	in_flight:     bool,
	zero_rtt:      bool,
	frames:        [dynamic]Sent_Frame,
}

Ctrl :: struct {
	kind: Frame_Kind,
	id:   u64,
	code: u64,
	data: [8]byte,
}

Pn_Space :: struct {
	tx, rx:                Keys,
	crypto_send:           Send_Buf,
	crypto_recv:           Recv_Buf,
	sent:                  [dynamic]Sent_Packet,
	largest_acked:         i64,
	loss_time:             time.Tick,
	has_loss_time:         bool,
	last_ack_eliciting:    time.Tick,
	has_ack_eliciting:     bool,
	// Receive side.
	recv_pns:              Range_Set,
	largest_rx:            i64,
	largest_rx_time:       time.Tick,
	unacked_eliciting:     int,
	ack_deadline:          time.Tick,
	ack_timer:             bool,
	ack_now:               bool,
	discarded:             bool,
	probes:                int, // PTO probes still to send
	// Packets that arrived before their keys (decrypted once keys show up).
	undecryptable:         [dynamic][]byte,
}

Config :: struct {
	tls:            tls.Config, // alpn should be {"h3"}
	port:           int, // default 443
	// Overrides DNS (tests / host mapping).
	endpoint:       net.Endpoint,
	has_endpoint:   bool,
	handshake_timeout: time.Duration, // default 10s
	// enable_0rtt lets connect return as soon as the ClientHello is out when
	// a ticket allows early data, so the caller's first requests go in 0-RTT
	// (Chrome does this for safe methods). The handshake finishes in the
	// background; wait_handshake blocks until it does.
	enable_0rtt:    bool,
}

Early_State :: enum u8 {
	None, // no 0-RTT this connection
	Sending,
	Accepted,
	Rejected,
}

// Uni_Handler receives data on peer-initiated unidirectional streams. It is
// called on the I/O thread with the connection lock held; use the *_locked
// stream procs from inside it.
Uni_Handler :: proc(user: rawptr, st: ^Stream, data: []byte, fin: bool)

Conn :: struct {
	mu:                 sync.Mutex,
	cond:               sync.Cond,
	sock:               net.UDP_Socket,
	peer:               net.Endpoint,
	wake_sock:          net.UDP_Socket,
	local:              net.Endpoint, // where wake datagrams are sent
	io_thread:          ^thread.Thread,
	handshake_deadline: time.Tick,

	odcid:              [8]byte,
	dcid:               [20]byte,
	dcid_len:           int,
	dcid_seq:           u64,
	got_server_scid:    bool,
	server_scid:        [20]byte,
	server_scid_len:    int,
	retry_scid:         [20]byte,
	retry_scid_len:     int,
	token:              [dynamic]byte,
	spaces:             [Space]Pn_Space,
	next_pn:            u64,
	initial_sent:       bool,
	app_rx_next:        Keys, // next key phase
	early_tx:           Keys, // 0-RTT
	early:              Early_State,
	ch_sent:            bool,
	hs_thread:          ^thread.Thread,
	hs_done:            bool, // handshake thread finished (ok or not)
	key_phase:          u8,

	// TLS.
	hs:                 tls.Handshake_State,
	hs_msgs:            [dynamic][]byte,
	hs_level_rx:        Space,
	tls_error:          tls.Error,
	handshake_complete: bool,
	handshake_confirmed: bool,
	params:             Peer_Params,

	// Streams and flow control.
	streams:            map[u64]^Stream,
	next_bidi:          u64,
	next_uni:           u64,
	peer_max_bidi:      u64,
	peer_max_uni:       u64,
	peer_max_data:      u64,
	data_sent:          u64,
	local_max_data:     u64,
	data_received:      u64,
	data_consumed:      u64,
	ctrl:               [dynamic]Ctrl,
	uni_handler:        Uni_Handler,
	uni_user:           rawptr,

	// Recovery.
	rtt:                Rtt,
	cc:                 Cubic,
	pacer:              Pacer,
	last_tx:            time.Tick,
	pto_count:          int,
	app_packets_rx:     int,
	idle_timeout:       time.Duration,
	last_activity:      time.Tick,

	// Lifecycle.
	err:                Error,
	peer_code:          u64,
	closing:            bool,
	close_sent:         bool,
	close_code:         u64,
	close_app:          bool,
	stop:               bool,
}

@(private)
space_of :: proc(l: tls.Level) -> Space {
	switch l {
	case .Initial:
		return .Initial
	case .Handshake:
		return .Handshake
	case .Early, .Application:
		return .App
	}
	return .App
}

// connect resolves host, performs the QUIC + TLS handshake and returns an
// established connection.
connect :: proc(host: string, cfg: Config) -> (c: ^Conn, err: Error) {
	// Connection state is shared with the I/O thread: always use the heap.
	context.allocator = runtime.heap_allocator()
	ep: net.Endpoint
	if cfg.has_endpoint {
		ep = cfg.endpoint
	} else {
		ep4, ep6, rerr := net.resolve(host)
		if rerr != nil do return nil, .Dns
		ep = ep4 if ep4.address != nil else ep6
		if ep.address == nil do return nil, .Dns
	}
	ep.port = cfg.port if cfg.port != 0 else (ep.port if cfg.has_endpoint else 443)

	c = new(Conn)
	c.peer = ep
	family := net.family_from_endpoint(ep)
	sock, serr := net.make_unbound_udp_socket(family)
	if serr != nil {
		free(c)
		return nil, .Io
	}
	c.sock = sock
	any_addr: net.Address = net.IP4_Any if family == .IP4 else net.IP6_Any
	if net.bind(sock, {any_addr, 0}) != nil {
		net.close(sock)
		free(c)
		return nil, .Io
	}
	// The wake socket pokes the I/O thread out of recv when the app has data.
	local, _ := net.bound_endpoint(sock)
	loop: net.Address = net.IP4_Loopback if family == .IP4 else net.IP6_Loopback
	c.local = {loop, local.port}
	ws, werr := net.make_unbound_udp_socket(family)
	if werr != nil {
		net.close(sock)
		free(c)
		return nil, .Io
	}
	c.wake_sock = ws

	conn_init(c, cfg)
	c.io_thread = thread.create_and_start_with_poly_data(c, io_loop)

	// The handshake may outlive this call (0-RTT), so the config's strings are
	// copied into connection-owned memory.
	c.hs.cfg = cfg.tls
	c.hs.cfg.server_name = strings.clone(cfg.tls.server_name if cfg.tls.server_name != "" else host)
	alpn := make([]string, len(cfg.tls.alpn))
	for p, i in cfg.tls.alpn do alpn[i] = strings.clone(p)
	c.hs.cfg.alpn = alpn
	c.hs.allocator = context.allocator
	c.hs.quic_params = chrome_transport_params(cached_rtt_us(cfg.tls.server_name))

	if cfg.enable_0rtt {
		// Run the handshake in the background; return once we know whether
		// 0-RTT is possible (the early secret is installed before the
		// ClientHello is handed to us).
		c.hs_thread = thread.create_and_start_with_poly_data(c, handshake_thread)
		sync.mutex_lock(&c.mu)
		for !c.ch_sent && !c.hs_done do sync.cond_wait(&c.cond, &c.mu)
		early := c.early == .Sending
		sync.mutex_unlock(&c.mu)
		if !early {
			if e := wait_handshake(c); e != .None {
				close(c)
				return nil, e
			}
		}
		return c, .None
	}
	run_handshake_thread_body(c)
	sync.mutex_lock(&c.mu)
	e := c.err
	sync.mutex_unlock(&c.mu)
	if e != .None {
		close(c)
		return nil, e
	}
	return c, .None
}

@(private)
handshake_thread :: proc(c: ^Conn) {
	context.allocator = conn_allocator()
	run_handshake_thread_body(c)
}

// run_handshake_thread_body runs TLS and finalizes the connection state.
@(private)
run_handshake_thread_body :: proc(c: ^Conn) {
	io := tls.Handshake_Io {
		data         = c,
		next_message = hs_next_message,
		send         = hs_send,
		set_secret   = hs_set_secret,
	}
	terr := tls.quic_handshake(&c.hs, io)
	sync.mutex_lock(&c.mu)
	defer sync.mutex_unlock(&c.mu)
	defer {
		c.hs_done = true
		sync.cond_broadcast(&c.cond)
	}
	if terr == .None && c.err == .None {
		terr = finish_handshake_locked(c)
	}
	if terr != .None || c.err != .None {
		if c.err == .None {
			c.tls_error = terr
			c.err = .Tls
			// CRYPTO_ERROR = 0x100 + alert.
			start_close_locked(c, 0x100 + u64(tls.alert_code(terr)), false)
		}
		return
	}
	c.handshake_complete = true
	if c.early == .Sending {
		if c.hs.early_accepted {
			c.early = .Accepted
		} else {
			reject_zero_rtt_locked(c)
		}
	}
	keys_clear(&c.early_tx)
	wake(c)
}

// wait_handshake blocks until the handshake completed (or failed).
wait_handshake :: proc(c: ^Conn) -> Error {
	sync.mutex_lock(&c.mu)
	defer sync.mutex_unlock(&c.mu)
	for !c.handshake_complete && c.err == .None do sync.cond_wait(&c.cond, &c.mu)
	return c.err
}

// handshake_complete reports whether 1-RTT is up (requests are no longer early).
is_handshake_complete :: proc(c: ^Conn) -> bool {
	sync.mutex_lock(&c.mu)
	defer sync.mutex_unlock(&c.mu)
	return c.handshake_complete
}

// early_state reports the 0-RTT outcome.
early_state :: proc(c: ^Conn) -> Early_State {
	sync.mutex_lock(&c.mu)
	defer sync.mutex_unlock(&c.mu)
	return c.early
}

@(private)
conn_init :: proc(c: ^Conn, cfg: Config) {
	crypto.rand_bytes(c.odcid[:])
	copy(c.dcid[:], c.odcid[:])
	c.dcid_len = 8
	initial_keys(&c.spaces[.Initial].tx, &c.spaces[.Initial].rx, c.odcid[:])
	for &sp in c.spaces {
		sp.largest_acked = -1
		sp.largest_rx = -1
	}
	c.next_pn = 1
	c.next_bidi = 0
	c.next_uni = 0
	c.local_max_data = CHROME_MAX_DATA
	rtt_init(&c.rtt, INITIAL_RTT)
	cubic_init(&c.cc)
	pacer_init(&c.pacer)
	c.idle_timeout = CHROME_MAX_IDLE_MS * time.Millisecond
	c.last_activity = time.tick_now()
	c.streams = make(map[u64]^Stream)
	c.ctrl = make([dynamic]Ctrl)
	c.token = make([dynamic]byte)
	c.hs_msgs = make([dynamic][]byte)
	hto := cfg.handshake_timeout if cfg.handshake_timeout != 0 else 10 * time.Second
	c.handshake_deadline = time.tick_add(time.tick_now(), hto)
}

// finish_handshake_locked validates the server's transport parameters.
@(private)
finish_handshake_locked :: proc(c: ^Conn) -> tls.Error {
	p, ok := parse_peer_params(c.hs.server_params)
	if !ok do return .Illegal_Parameter
	// Connection ID authentication (RFC 9000 7.3).
	if string(p.original_dcid) != string(c.odcid[:]) do return .Illegal_Parameter
	if string(p.initial_scid) != string(c.server_scid[:c.server_scid_len]) do return .Illegal_Parameter
	if c.retry_scid_len > 0 && (!p.has_retry_scid || string(p.retry_scid) != string(c.retry_scid[:c.retry_scid_len])) {
		return .Illegal_Parameter
	}
	c.params = p
	// Slices into server_params stay valid; it lives as long as c.hs.
	c.peer_max_data = max(c.peer_max_data, p.max_data)
	c.peer_max_bidi = max(c.peer_max_bidi, p.max_streams_bidi)
	c.peer_max_uni = max(c.peer_max_uni, p.max_streams_uni)
	if p.max_idle_ms > 0 do c.idle_timeout = min(c.idle_timeout, time.Duration(p.max_idle_ms) * time.Millisecond)
	for _, st in c.streams do stream_apply_peer_limits(c, st)
	return .None
}

// close sends CONNECTION_CLOSE (H3_NO_ERROR) if still open, stops the I/O
// thread and frees everything. Streams become invalid.
close :: proc(c: ^Conn) {
	if c == nil do return
	context.allocator = conn_allocator()
	sync.mutex_lock(&c.mu)
	if c.err == .None && !c.closing {
		start_close_locked(c, 0x100, true)
	}
	c.stop = true
	sync.mutex_unlock(&c.mu)
	wake(c)
	thread.join(c.io_thread)
	thread.destroy(c.io_thread)
	if c.hs_thread != nil {
		thread.join(c.hs_thread)
		thread.destroy(c.hs_thread)
	}
	if c.rtt.has_sample do remember_rtt(c.hs.cfg.server_name, c.rtt.smoothed)
	net.close(c.sock)
	net.close(c.wake_sock)
	conn_destroy(c)
}

@(private)
conn_destroy :: proc(c: ^Conn) {
	for &sp in c.spaces {
		keys_clear(&sp.tx)
		keys_clear(&sp.rx)
		sb_destroy(&sp.crypto_send)
		rb_destroy(&sp.crypto_recv)
		for &p in sp.sent do delete(p.frames)
		delete(sp.sent)
		delete(sp.recv_pns)
		for b in sp.undecryptable do delete(b)
		delete(sp.undecryptable)
	}
	keys_clear(&c.app_rx_next)
	keys_clear(&c.early_tx)
	for m in c.hs_msgs do delete(m)
	delete(c.hs_msgs)
	tls.handshake_state_destroy(&c.hs)
	for p in c.hs.cfg.alpn do delete(p)
	delete(c.hs.cfg.alpn)
	delete(c.hs.cfg.server_name)
	delete(c.hs.quic_params)
	for _, st in c.streams do stream_free(st)
	delete(c.streams)
	delete(c.ctrl)
	delete(c.token)
	free(c)
}

// start_close_locked queues CONNECTION_CLOSE; the I/O thread sends it and stops.
@(private)
start_close_locked :: proc(c: ^Conn, code: u64, app: bool) {
	if c.closing do return
	c.closing = true
	c.close_code = code
	c.close_app = app
	if c.err == .None do c.err = .Closed
	sync.cond_broadcast(&c.cond)
}

// fail_locked records a local protocol error and closes the connection.
@(private)
fail_locked :: proc(c: ^Conn, e: Error, code: u64) {
	if c.err == .None do c.err = e
	start_close_locked(c, code, false)
}

// wake interrupts the I/O thread's blocking receive.
wake :: proc(c: ^Conn) {
	b := [1]byte{0}
	net.send_udp(c.wake_sock, b[:], c.local)
}

// --- Handshake_Io for the TLS engine ---

@(private)
hs_next_message :: proc(data: rawptr) -> ([]byte, tls.Error) {
	c := cast(^Conn)data
	sync.mutex_lock(&c.mu)
	defer sync.mutex_unlock(&c.mu)
	for len(c.hs_msgs) == 0 {
		if c.err != .None do return nil, .Io
		sync.cond_wait(&c.cond, &c.mu)
	}
	m := c.hs_msgs[0]
	ordered_remove(&c.hs_msgs, 0)
	if debug_log do fmt.eprintfln("[quic] %v hs_next got type %d", time.tick_now(), m[0])
	return m, .None
}

@(private)
hs_send :: proc(data: rawptr, level: tls.Level, flight: []byte, first: bool, ccs: bool) -> tls.Error {
	c := cast(^Conn)data
	sync.mutex_lock(&c.mu)
	sb_write(&c.spaces[space_of(level)].crypto_send, flight)
	if debug_log do fmt.eprintfln("[quic] %v hs_send %v %d", time.tick_now(), level, len(flight))
	if first {
		c.ch_sent = true
		sync.cond_broadcast(&c.cond)
	}
	sync.mutex_unlock(&c.mu)
	wake(c)
	return .None
}

@(private)
hs_set_secret :: proc(data: rawptr, level: tls.Level, is_write: bool, suite: tls.Suite, secret: []byte) -> tls.Error {
	c := cast(^Conn)data
	if level == .Early {
		sync.mutex_lock(&c.mu)
		defer sync.mutex_unlock(&c.mu)
		// 0-RTT needs the server's remembered transport parameters (RFC 9000 7.4.1).
		p, ok := parse_peer_params(c.hs.early_params)
		if !ok || len(c.hs.early_params) == 0 do return .None
		keys_set(&c.early_tx, suite, secret)
		c.early = .Sending
		c.params = p
		c.params.original_dcid = nil
		c.params.initial_scid = nil
		c.peer_max_data = p.max_data
		c.peer_max_bidi = p.max_streams_bidi
		c.peer_max_uni = p.max_streams_uni
		return .None
	}
	// New keys may arm timers (ACKs for buffered packets): re-plan the I/O loop.
	defer wake(c)
	sync.mutex_lock(&c.mu)
	defer sync.mutex_unlock(&c.mu)
	sp := &c.spaces[space_of(level)]
	if is_write {
		keys_set(&sp.tx, suite, secret)
	} else {
		keys_set(&sp.rx, suite, secret)
		c.hs_level_rx = space_of(level)
		// Handshake messages must not continue across a key change.
		prev := &c.spaces[.Initial] if level == .Handshake else &c.spaces[.Handshake]
		if len(rb_readable(&prev.crypto_recv)) > 0 do return .Unexpected_Message
		if level == .Application do keys_next(&c.app_rx_next, &sp.rx)
		// Retry packets that arrived before these keys.
		pending := sp.undecryptable
		sp.undecryptable = nil
		for b in pending {
			process_datagram_locked(c, b, time.tick_now())
			delete(b)
		}
		delete(pending)
	}
	return .None
}

// --- I/O thread ---

@(private)
io_loop :: proc(c: ^Conn) {
	buf: [2048]byte
	for {
		sync.mutex_lock(&c.mu)
		now := time.tick_now()
		on_timers_locked(c, now)
		send_pending_locked(c, now)
		if c.stop || (c.closing && c.close_sent) {
			if c.err == .None do c.err = .Closed
			sync.cond_broadcast(&c.cond)
			if c.stop {
				sync.mutex_unlock(&c.mu)
				return
			}
		}
		timeout := next_timeout_locked(c, now)
		sync.mutex_unlock(&c.mu)

		net.set_option(c.sock, .Receive_Timeout, max(timeout, time.Millisecond))
		n, from, rerr := net.recv_udp(c.sock, buf[:])
		if rerr != nil || n == 0 do continue
		if from.port != c.peer.port || !address_equal(from.address, c.peer.address) do continue // wake-up or stray
		sync.mutex_lock(&c.mu)
		if !c.closing {
			process_datagram_locked(c, buf[:n], time.tick_now())
		}
		sync.mutex_unlock(&c.mu)
	}
}

@(private)
address_equal :: proc(a, b: net.Address) -> bool {
	switch x in a {
	case net.IP4_Address:
		y, ok := b.(net.IP4_Address)
		return ok && x == y
	case net.IP6_Address:
		y, ok := b.(net.IP6_Address)
		return ok && x == y
	}
	return false
}

// conn_allocator is used for all connection state (shared with the I/O thread).
conn_allocator :: proc() -> runtime.Allocator {return runtime.heap_allocator()}

// Chrome remembers each server's RTT and sends it as initial_rtt on the next
// connection; this is that cache (microseconds of smoothed RTT).
@(private)
rtt_cache_mu: sync.Mutex
@(private)
rtt_cache: map[string]u64

cached_rtt_us :: proc(host: string) -> u64 {
	sync.mutex_lock(&rtt_cache_mu)
	defer sync.mutex_unlock(&rtt_cache_mu)
	return rtt_cache[host] or_else 0
}

@(private)
remember_rtt :: proc(host: string, rtt: time.Duration) {
	if rtt <= 0 do return
	context.allocator = conn_allocator()
	sync.mutex_lock(&rtt_cache_mu)
	defer sync.mutex_unlock(&rtt_cache_mu)
	us := u64(time.duration_microseconds(rtt))
	if _, ok := rtt_cache[host]; ok {
		rtt_cache[host] = us
	} else {
		rtt_cache[strings.clone(host)] = us
	}
}

// reject_zero_rtt_locked requeues everything sent as 0-RTT for 1-RTT
// retransmission (QUICHE MarkZeroRttPacketsForRetransmission); no
// congestion response, since nothing was lost on the path.
reject_zero_rtt_locked :: proc(c: ^Conn) {
	c.early = .Rejected
	sp := &c.spaces[.App]
	i := 0
	for i < len(sp.sent) {
		p := &sp.sent[i]
		if !p.zero_rtt {
			i += 1
			continue
		}
		on_frames_lost(c, .App, p.frames[:])
		if p.in_flight do cubic_on_removed(&c.cc, p.size)
		delete(p.frames)
		ordered_remove(&sp.sent, i)
	}
}
