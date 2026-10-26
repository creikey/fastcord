package discord

import "fc:locks"
import "core:strings"
import "core:sync"
import "core:thread"
import "fc:brotli"
import "fc:http"
import "fc:netio"
import "fc:quic/altsvc"
import "fc:quic/h3"
import "fc:zstd"

// Transport: one connection pool per origin, like Chrome's socket pools.
//   - TLS with Chrome's ClientHello, ALPN {"h2","http/1.1"}.
//   - HTTP/2 when negotiated (every Discord origin today); one session per
//     origin shared by all requests, kept read-serviced by a thread so PING/
//     SETTINGS/GOAWAY are handled while idle, as Chrome does.
//   - HTTP/1.1 keep-alive fallback.
//   - Alt-Svc: responses' `alt-svc: h3=":443"` are cached (and persisted) the
//     way Chrome's HttpServerProperties does. When an H3_Hook is installed and
//     the origin has a live h3 alternative that isn't marked broken, requests
//     go to the hook first and fall back to h2 on failure (the alternative is
//     then marked broken for 5 min, doubling per failure). This is the seam
//     for src/quic.
//   - Set-Cookie is applied to the jar; Content-Encoding (gzip/br/zstd) decoded.

Transport_Error :: enum u8 {
	None,
	Dial,
	Tls,
	Protocol,
	Timeout,
	Closed,
	Decode,
}

H3_Hook :: struct {
	data:       rawptr,
	round_trip: proc(data: rawptr, host: string, port: int, req: http.Request) -> (http.Response, http.Error),
}

// Round_Tripper replaces the network entirely (tests, replay of recorded traffic).
Round_Tripper :: struct {
	data:       rawptr,
	round_trip: proc(data: rawptr, host: string, req: http.Request) -> (http.Response, http.Error),
}

@(private)
H2_Ref :: struct {
	c:       ^http.H2_Conn,
	svc:     ^thread.Thread,
	refs:    int,
	retired: bool,
}

@(private)
Origin :: struct {
	host:    string,
	h2:      ^H2_Ref,
	idle_h1: [dynamic]^http.H1_Conn,
	dialing: bool,
}

// Conn_Event: a new session and the setup bytes/values we sent on it.
Conn_Event :: struct {
	kind:                string, // "h2" | "h3"
	host:                string,
	alpn:                string,
	quic_params:         []byte, // h3: encoded client transport parameters (borrowed)
	h2_settings:         []http.Setting,
	h2_window_increment: u32,
}

Transport :: struct {
	mu:        locks.Mutex,
	cond:      locks.Cond,
	origins:   map[string]^Origin,
	alt:       altsvc.Cache, // Chrome alternative-service state (fc:quic/altsvc)
	use_h3:    bool, // race QUIC per Alt-Svc (default on)
	race_mu:   locks.Mutex,
	// no 0-RTT on resumed QUIC sessions (off by default: Chrome uses 0-RTT).
	h3_no_0rtt: bool,
	h3:        H3_Hook, // optional override of the built-in h3 path
	override:  Round_Tripper,
	jar:       ^Cookie_Jar,
	allocator: Allocator,
	closed:    bool,
	// observer sees every request as sent (header order included) and its response: traffic tooling.
	observer:  proc(data: rawptr, host: string, req: http.Request, resp: ^http.Response, err: http.Error, start_ms: f64),
	observer_data: rawptr,
	// conn_observer sees each new h2/h3 session and what we sent to set it up
	// (same observer_data): traffic tooling writes it as a Chrome netlog.
	conn_observer: proc(data: rawptr, ev: Conn_Event),
	h3_seen:   map[rawptr]bool,
}

@(private)
decoders_once: sync.Once

@(private)
br_decoder :: proc(src: []byte, dst: ^[dynamic]byte, max_out: int) -> http.Error {
	out, err := brotli.decompress(src, context.temp_allocator, max_out)
	if err != .None do return .Decompress
	append(dst, ..out)
	return .None
}

@(private)
zstd_decoder :: proc(src: []byte, dst: ^[dynamic]byte, max_out: int) -> http.Error {
	out, err := zstd.decompress(src, context.temp_allocator, max_out)
	if err != .None do return .Decompress
	append(dst, ..out)
	return .None
}

register_content_decoders :: proc() {
	sync.once_do(&decoders_once, proc() {
		http.register_decoder("br", br_decoder)
		http.register_decoder("zstd", zstd_decoder)
	})
}

transport_init :: proc(t: ^Transport, jar: ^Cookie_Jar, allocator := context.allocator) {
	register_content_decoders()
	t.allocator = allocator
	t.jar = jar
	t.origins = make(map[string]^Origin, allocator = allocator)
	t.use_h3 = true
}

transport_destroy :: proc(t: ^Transport) {
	locks.lock(&t.mu)
	t.closed = true
	origins := t.origins
	t.origins = {}
	locks.unlock(&t.mu)
	for k, o in origins {
		if o.h2 != nil {
			locks.lock(&t.mu)
			r := o.h2
			o.h2 = nil
			r.retired = true
			fin := r.refs == 0
			locks.unlock(&t.mu)
			if fin do h2_finalize(t, r)
		}
		for c in o.idle_h1 {
			http.h1_destroy(c)
			free(c, t.allocator)
		}
		delete(o.idle_h1)
		delete(o.host, t.allocator)
		free(o, t.allocator)
		delete(k, t.allocator)
	}
	delete(origins)
	delete(t.h3_seen)
	altsvc.destroy(&t.alt)
}

@(private)
h2_service_proc :: proc(th: ^thread.Thread) {
	c := cast(^http.H2_Conn)th.data
	_ = http.h2_service(c)
}

// transport_round_trip sends req to https://host and returns the decoded response.
transport_round_trip :: proc(t: ^Transport, host: string, req: http.Request) -> (resp: http.Response, err: http.Error) {
	req := req
	if req.scheme == "" do req.scheme = "https"
	if req.authority == "" do req.authority = host
	start_ms := now_ms_f()
	defer if t.observer != nil do t.observer(t.observer_data, host, req, &resp, err, start_ms)

	if t.override.round_trip != nil {
		resp, err = t.override.round_trip(t.override.data, host, req)
	} else {
		resp, err = network_round_trip(t, host, req)
	}
	if err != .None do return
	now := now_ms()
	for h in resp.headers {
		if strings.equal_fold(h.name, "set-cookie") && t.jar != nil {
			cookie_set_from_header(t.jar, host, req.path, h.value, now)
		} else if strings.equal_fold(h.name, "alt-svc") {
			altsvc.record(&t.alt, host, h.value)
		}
	}
	if derr := http.decode_body(&resp); derr != .None do err = derr
	return
}

@(private)
network_round_trip :: proc(t: ^Transport, host: string, req: http.Request) -> (resp: http.Response, err: http.Error) {
	if t.h3.round_trip != nil {
		if port, ok := altsvc.usable(&t.alt, host); ok {
			resp, err = t.h3.round_trip(t.h3.data, host, port, req)
			if err == .None do return
			altsvc.mark_broken(&t.alt, host)
		}
	} else if t.use_h3 {
		if r, handled := h3_round_trip(t, host, req); handled do return r.resp, r.err
	}
	for attempt in 0 ..< 2 {
		o, ref := origin_get_h2(t, host)
		if ref != nil {
			resp, err = http.h2_request(ref.c, req)
			// Refused / GOAWAY before processing: safe to retry on a new session (Chrome does).
			retry := err == .Refused || err == .Goaway || (err == .Closed && attempt == 0)
			if retry do origin_drop_h2(t, o, ref)
			h2_release(t, ref)
			if retry do continue
			return
		}
		if o == nil do return {}, .Io
		// HTTP/1.1
		c := origin_take_h1(t, o)
		if c == nil do return {}, .Io
		resp, err = http.h1_round_trip(c, req)
		if err == .None && c.reusable {
			origin_put_h1(t, o, c)
		} else {
			http.h1_destroy(c)
			free(c, t.allocator)
			if err == .Closed && attempt == 0 do continue
		}
		return
	}
	return
}

@(private)
origin_lookup :: proc(t: ^Transport, host: string) -> ^Origin {
	o, ok := t.origins[host]
	if !ok {
		o = new(Origin, t.allocator)
		o.host = strings.clone(host, t.allocator)
		o.idle_h1 = make([dynamic]^http.H1_Conn, t.allocator)
		t.origins[strings.clone(host, t.allocator)] = o
	}
	return o
}

// origin_get_h2 returns a referenced h2 session, dialing if needed. If the
// server negotiated http/1.1 the connection is parked as an idle h1 conn and ref=nil.
@(private)
origin_get_h2 :: proc(t: ^Transport, host: string) -> (o: ^Origin, ref: ^H2_Ref) {
	locks.lock(&t.mu)
	if t.closed {
		locks.unlock(&t.mu)
		return nil, nil
	}
	o = origin_lookup(t, host)
	for {
		if o.h2 != nil && http.h2_can_open(o.h2.c) {
			o.h2.refs += 1
			r := o.h2
			locks.unlock(&t.mu)
			return o, r
		}
		if o.h2 != nil {
			r := o.h2
			o.h2 = nil
			r.retired = true
			if r.refs == 0 {
				locks.unlock(&t.mu)
				h2_finalize(t, r)
				locks.lock(&t.mu)
			}
			continue
		}
		if len(o.idle_h1) > 0 {
			locks.unlock(&t.mu)
			return o, nil
		}
		if !o.dialing do break
		locks.cond_wait(&t.cond, &t.mu)
	}
	o.dialing = true
	locks.unlock(&t.mu)

	stream, alpn, dok := dial_tls_stream(host, {"h2", "http/1.1"})
	new_h2: ^http.H2_Conn
	new_h1: ^http.H1_Conn
	if dok {
		if alpn == "h2" {
			c, herr := http.h2_connect(stream, {}, t.allocator)
			if herr == .None {
				new_h2 = c
				// The h2 reader idles in read between requests; HTTP/1.1 keeps the dial timeout per request.
				netio.set_timeout(stream, 0)
				// h2_connect with a zero config sends CHROME_SETTINGS and the
				// connection WINDOW_UPDATE.
				if t.conn_observer != nil {
					t.conn_observer(t.observer_data, {kind = "h2", host = host, alpn = alpn, h2_settings = http.CHROME_SETTINGS[:], h2_window_increment = http.CHROME_CONNECTION_WINDOW_INCREMENT})
				}
			} else {
				netio.close(stream)
			}
		} else {
			new_h1 = new(http.H1_Conn, t.allocator)
			http.h1_init(new_h1, stream, {}, t.allocator)
		}
	}

	locks.lock(&t.mu)
	defer locks.unlock(&t.mu)
	o.dialing = false
	locks.cond_broadcast(&t.cond)
	if new_h2 != nil {
		r := new(H2_Ref, t.allocator)
		r.c = new_h2
		r.svc = thread.create(h2_service_proc)
		r.svc.data = new_h2
		r.svc.init_context = context
		thread.start(r.svc)
		r.refs = 1
		o.h2 = r
		return o, r
	}
	if new_h1 != nil {
		append(&o.idle_h1, new_h1)
		return o, nil
	}
	return nil, nil
}

@(private)
h2_finalize :: proc(t: ^Transport, r: ^H2_Ref) {
	http.h2_close(r.c) // wakes the service thread, waits for users, frees the conn
	if r.svc != nil {
		locks.join(r.svc)
	}
	free(r, t.allocator)
}

@(private)
h2_release :: proc(t: ^Transport, r: ^H2_Ref) {
	locks.lock(&t.mu)
	r.refs -= 1
	fin := r.retired && r.refs == 0
	locks.unlock(&t.mu)
	if fin do h2_finalize(t, r)
}

@(private)
origin_drop_h2 :: proc(t: ^Transport, o: ^Origin, r: ^H2_Ref) {
	locks.lock(&t.mu)
	defer locks.unlock(&t.mu)
	if o != nil && o.h2 == r {
		o.h2 = nil
		r.retired = true // finalized by the last h2_release
	}
}

@(private)
origin_take_h1 :: proc(t: ^Transport, o: ^Origin) -> ^http.H1_Conn {
	locks.lock(&t.mu)
	if n := len(o.idle_h1); n > 0 {
		c := pop(&o.idle_h1)
		locks.unlock(&t.mu)
		return c
	}
	locks.unlock(&t.mu)
	stream, _, dok := dial_tls_stream(o.host, {"h2", "http/1.1"})
	if !dok do return nil
	c := new(http.H1_Conn, t.allocator)
	http.h1_init(c, stream, {}, t.allocator)
	return c
}

@(private)
origin_put_h1 :: proc(t: ^Transport, o: ^Origin, c: ^http.H1_Conn) {
	locks.lock(&t.mu)
	defer locks.unlock(&t.mu)
	if len(o.idle_h1) < 6 && !t.closed {
		append(&o.idle_h1, c)
	} else {
		http.h1_destroy(c)
		free(c, t.allocator)
	}
}

// ---- HTTP/3 (Chrome job racing via fc:quic/altsvc) ----

@(private)
H3_Outcome :: struct {
	resp: http.Response,
	err:  http.Error,
}

// The race's "TCP job": our pooled h2 session (dialed or reused).
@(private)
tcp_dialer :: proc(host: string, user: rawptr) -> (conn: rawptr, ok: bool) {
	t := cast(^Transport)user
	_, ref := origin_get_h2(t, host)
	return ref, ref != nil
}

@(private)
tcp_closer :: proc(conn: rawptr, user: rawptr) {
	if conn != nil do h2_release(cast(^Transport)user, cast(^H2_Ref)conn)
}

// h3_round_trip: when the origin has a usable h3 alternative (or a live h3
// session), race QUIC against TCP like Chrome and send on the winner.
// handled=false means no alternative is known: caller uses h2.
@(private)
h3_round_trip :: proc(t: ^Transport, host: string, req: http.Request) -> (out: H3_Outcome, handled: bool) {
	locks.lock(&t.alt.mu)
	_, live := t.alt.conns[host]
	locks.unlock(&t.alt.mu)
	if !live {
		if _, ok := altsvc.usable(&t.alt, host); !ok do return {}, false
		// An established h2 session is preferred over starting a QUIC job
		// (Chrome reuses the SPDY session the main job finds).
		locks.lock(&t.mu)
		o, has := t.origins[host]
		h2_live := has && o.h2 != nil && http.h2_can_open(o.h2.c)
		locks.unlock(&t.mu)
		if h2_live do return {}, false
	}
	// One job per origin at a time (Chrome joins requests onto the pending
	// job instead of racing again).
	if !live do locks.lock(&t.race_mu)
	res, ok := altsvc.connect(&t.alt, host, tcp_dialer, tcp_closer, t, h3.Config{no_0rtt = t.h3_no_0rtt})
	if !live do locks.unlock(&t.race_mu)
	if !ok do return {}, false
	switch res.proto {
	case .H3:
		if t.conn_observer != nil {
			locks.lock(&t.mu)
			seen := res.h3 in t.h3_seen
			if !seen do t.h3_seen[res.h3] = true
			locks.unlock(&t.mu)
			// the transport parameters bytes this session's ClientHello carried
			if !seen do t.conn_observer(t.observer_data, {kind = "h3", host = host, alpn = "h3", quic_params = res.h3.q.hs.quic_params})
		}
		resp, err := h3.request(res.h3, req, t.allocator)
		if err != .None && err != .Stream_Reset {
			// Session-level failure after it was established: fall back to h2 this time.
			http.response_destroy(&resp)
			return {}, false
		}
		return {resp, err}, true
	case .H2:
		ref := cast(^H2_Ref)res.tcp
		if ref == nil do return {}, false
		resp, err := http.h2_request(ref.c, req)
		h2_release(t, ref)
		return {resp, err}, true
	}
	return {}, false
}

// Wrappers kept for callers/tests.
transport_note_alt_svc :: proc(t: ^Transport, host, value: string, now: i64) {altsvc.record(&t.alt, host, value)}
transport_h3_alternative :: proc(t: ^Transport, host: string) -> (int, bool) {return altsvc.usable(&t.alt, host)}
transport_mark_h3_broken :: proc(t: ^Transport, host: string) {altsvc.mark_broken(&t.alt, host)}

// transport_set_altsvc_path enables persistence (Chrome's Network Persistent State).
transport_set_altsvc_path :: proc(t: ^Transport, path: string) {
	_ = altsvc.load(&t.alt, path)
}
