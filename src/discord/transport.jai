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

H3_Hook :: struct {
	data: *void;
	round_trip: (data: *void, host: string, port: int, req: http.Request) -> http.Response, http.Error;
}

// Round_Tripper replaces the network entirely (tests, replay of recorded traffic).
Round_Tripper :: struct {
	data: *void;
	round_trip: (data: *void, host: string, req: http.Request) -> http.Response, http.Error;
}

H2_Ref :: struct {
	c: *http.H2_Conn;
	svc: *Thread;
	refs: int;
	retired: bool;
}

Origin :: struct {
	host: string;
	h2: *H2_Ref;
	idle_h1: [..]*http.H1_Conn;
	dialing: bool;
}

// Conn_Event: a new session and the setup bytes/values we sent on it.
Conn_Event :: struct {
	kind: string; // "h2" | "h3"
	host: string;
	alpn: string;
	quic_params: []u8; // h3: encoded client transport parameters (borrowed)
	h2_settings: []http.Setting;
	h2_window_increment: u32;
}

// Shared by every worker: origins, sessions and h3_seen are under mu and live in allocator.
Transport :: struct {
	mu: locks.Mutex;
	cond: locks.Cond;
	origins: Table(string, *Origin);
	alt: altsvc.Cache; // Chrome alternative-service state (fc:quic/altsvc)
	use_h3: bool; // race QUIC per Alt-Svc (default on)
	race_mu: locks.Mutex;
	h3: H3_Hook; // optional override of the built-in h3 path
	override: Round_Tripper;
	jar: *Cookie_Jar;
	allocator: Allocator;
	closed: bool;
	// observer sees every request as sent (header order included) and its response: traffic tooling.
	observer: (data: *void, host: string, req: http.Request, resp: *http.Response, err: http.Error, start_ms: float64);
	observer_data: *void;
	// conn_observer sees each new h2/h3 session and what we sent to set it up
	// (same observer_data): traffic tooling writes it as a Chrome netlog.
	conn_observer: (data: *void, ev: Conn_Event);
	h3_seen: Table(*void, bool);
}

decoders_mu: locks.Mutex;
decoders_registered: bool;

br_decoder :: (src: []u8, max_out: int) -> []u8, http.Error {
	out, err := brotli.decompress(src, max_out);
	return out, ifx err then .Decompress else .None;
}

zstd_decoder :: (src: []u8, max_out: int) -> []u8, http.Error {
	out, err := zstd.decompress(src, max_out);
	return out, ifx err then .Decompress else .None;
}

// register_content_decoders: once per process (clients may be created on several threads).
register_content_decoders :: () {
	locks.lock(*decoders_mu);
	defer locks.unlock(*decoders_mu);
	if decoders_registered return;
	http.register_decoder("br", br_decoder);
	http.register_decoder("zstd", zstd_decoder);
	decoders_registered = true;
}

transport_init :: (t: *Transport, jar: *Cookie_Jar, allocator := context.allocator) {
	register_content_decoders();
	t.allocator = allocator;
	t.jar = jar;
	t.origins.allocator = allocator;
	t.h3_seen.allocator = allocator;
	t.use_h3 = true;
}

// transport_drop_sessions retires every HTTP/2 session and fails what is in flight on them, so the next
// requests dial again: after the machine wakes or the gateway finds its socket dead, the old sessions
// may be dead too and would hold each request until a PING times out. close also refuses new dials
// (quitting).
transport_drop_sessions :: (t: *Transport, close := false) {
	locks.lock(*t.mu);
	defer locks.unlock(*t.mu);
	if close t.closed = true;
	for o: t.origins if o.h2 {
		r := o.h2;
		o.h2 = null;
		r.retired = true; // finalized by the last h2_release
		http.h2_abort(r.c);
		if r.refs == 0 {
			r.refs = 1; // h2_release finalizes it outside mu
			locks.unlock(*t.mu);
			h2_release(t, r);
			locks.lock(*t.mu);
		}
	}
}

transport_destroy :: (t: *Transport) {
	locks.lock(*t.mu);
	t.closed = true;
	origins := t.origins;
	t.origins = .{};
	locks.unlock(*t.mu);
	push_allocator(t.allocator);
	for o, k: origins {
		if o.h2 {
			locks.lock(*t.mu);
			r := o.h2;
			o.h2 = null;
			r.retired = true;
			fin := r.refs == 0;
			locks.unlock(*t.mu);
			if fin { h2_finalize(t, r); }
		}
		for o.idle_h1 {
			http.h1_destroy(it);
			free(it);
		}
		array_free(o.idle_h1);
		free(o.host);
		free(o);
		free(k);
	}
	deinit(*origins);
	deinit(*t.h3_seen);
	altsvc.destroy(*t.alt);
}

// transport_round_trip sends req to https://host and returns the decoded response.
transport_round_trip :: (t: *Transport, host: string, req_in: http.Request) -> http.Response, http.Error {
	resp: http.Response;
	err: http.Error;
	req := req_in;
	if !req.scheme req.scheme = "https";
	if !req.authority req.authority = host;
	start_ms := now_ms_f();
	if context.tl_dispatch_ms > 0 {
		start_ms = context.tl_dispatch_ms;
		context.tl_dispatch_ms = 0;
	}
	defer if t.observer t.observer(t.observer_data, host, req, *resp, err, start_ms);

	if t.override.round_trip {
		resp, err = t.override.round_trip(t.override.data, host, req);
	} else {
		resp, err = network_round_trip(t, host, req);
	}
	if err != .None return resp, err;
	now := now_ms();
	for h: resp.headers {
		if equal_nocase(h.name, "set-cookie") && t.jar {
			cookie_set_from_header(t.jar, host, req.path, h.value, now);
		} else if equal_nocase(h.name, "alt-svc") {
			altsvc.record(*t.alt, host, h.value);
		}
	}
	derr := http.decode_body(*resp);
	if derr != .None err = derr;
	return resp, err;
}

network_round_trip :: (t: *Transport, host: string, req: http.Request) -> http.Response, http.Error {
	resp: http.Response;
	err: http.Error;
	if t.h3.round_trip {
		port, ok := altsvc.usable(*t.alt, host);
		if ok {
			resp, err = t.h3.round_trip(t.h3.data, host, port, req);
			if err == .None return resp, err;
			altsvc.mark_broken(*t.alt, host);
		}
	} else if t.use_h3 {
		r, handled := h3_round_trip(t, host, req);
		if handled return r.resp, r.err;
	}
	for attempt: 0..1 {
		o, ref := origin_get_h2(t, host);
		if ref {
			resp, err = http.h2_request(ref.c, req);
			// Refused / GOAWAY before processing: safe to retry on a new session (Chrome does). So is a
			// request that can be repeated when its session died (a failed PING, dropped sessions).
			again := req.method == "GET" || req.method == "HEAD" || req.method == "PUT" || req.method == "DELETE";
			retry := err == .Refused || err == .Goaway || ((err == .Closed || (err == .Timeout && again)) && attempt == 0);
			if retry origin_drop_h2(t, o, ref);
			h2_release(t, ref);
			if retry continue;
			return resp, err;
		}
		if !o return .{}, .Io;
		// HTTP/1.1
		c := origin_take_h1(t, o);
		if !c return .{}, .Io;
		resp, err = http.h1_round_trip(c, req);
		if err == .None && c.reusable {
			origin_put_h1(t, o, c);
		} else {
			http.h1_destroy(c);
			free(c,, t.allocator);
			if err == .Closed && attempt == 0 continue;
		}
		return resp, err;
	}
	return resp, err;
}

// origin_lookup: host's pool, made on first use (caller holds t.mu).
origin_lookup :: (t: *Transport, host: string) -> *Origin {
	ok, o := table_find(*t.origins, host);
	if !ok {
		push_allocator(t.allocator);
		o = New(Origin);
		o.host = copy_string(host);
		o.idle_h1.allocator = t.allocator;
		table_add(*t.origins, copy_string(host), o);
	}
	return o;
}

// origin_get_h2 returns a referenced h2 session, dialing if needed. If the
// server negotiated http/1.1 the connection is parked as an idle h1 conn and ref=nil.
origin_get_h2 :: (t: *Transport, host: string) -> *Origin, *H2_Ref {
	o: *Origin;
	ref: *H2_Ref;
	locks.lock(*t.mu);
	if t.closed {
		locks.unlock(*t.mu);
		return null, null;
	}
	o = origin_lookup(t, host);
	while true {
		if o.h2 && http.h2_can_open(o.h2.c) {
			o.h2.refs += 1;
			r := o.h2;
			locks.unlock(*t.mu);
			return o, r;
		}
		if o.h2 {
			r := o.h2;
			o.h2 = null;
			r.retired = true;
			if r.refs == 0 {
				locks.unlock(*t.mu);
				h2_finalize(t, r);
				locks.lock(*t.mu);
			}
			continue;
		}
		if o.idle_h1 {
			locks.unlock(*t.mu);
			return o, null;
		}
		if !o.dialing { break; }
		locks.cond_wait(*t.cond, *t.mu);
	}
	o.dialing = true;
	locks.unlock(*t.mu);

	stream, alpn, dok := dial_tls_stream(host, string.["h2", "http/1.1"]);
	new_h2: *http.H2_Conn;
	new_h1: *http.H1_Conn;
	if dok {
		if alpn == "h2" {
			c, herr := http.h2_connect(stream, .{},, t.allocator);
			if herr == .None {
				new_h2 = c;
				// The h2 reader idles in read between requests; HTTP/1.1 keeps the dial timeout per request.
				netio.set_timeout(stream, 0);
				// h2_connect with a zero config sends CHROME_SETTINGS and the
				// connection WINDOW_UPDATE.
				if t.conn_observer {
					t.conn_observer(t.observer_data, .{kind = "h2", host = host, alpn = alpn, h2_settings = http.CHROME_SETTINGS, h2_window_increment = http.CHROME_CONNECTION_WINDOW_INCREMENT});
				}
			} else {
				netio.close(stream);
			}
		} else {
			new_h1 = New(http.H1_Conn,, t.allocator);
			http.h1_init(new_h1, stream, .{},, t.allocator);
		}
	}

	locks.lock(*t.mu);
	defer locks.unlock(*t.mu);
	o.dialing = false;
	locks.cond_broadcast(*t.cond);
	if new_h2 {
		r := New(H2_Ref,, t.allocator);
		r.c = new_h2;
		r.svc = spawn(new_h2, (c: *http.H2_Conn) { http.h2_service(c); },, t.allocator); // joined (and freed) by h2_finalize
		r.refs = 1;
		o.h2 = r;
		return o, r;
	}
	if new_h1 {
		array_add(*o.idle_h1, new_h1);
		return o, null;
	}
	return null, null;
}

h2_finalize :: (t: *Transport, r: *H2_Ref) {
	http.h2_close(r.c); // wakes the service thread, waits for users, frees the conn
	if r.svc locks.join(r.svc,, t.allocator);
	free(r,, t.allocator);
}

h2_release :: (t: *Transport, r: *H2_Ref) {
	locks.lock(*t.mu);
	r.refs -= 1;
	fin := r.retired && r.refs == 0;
	locks.unlock(*t.mu);
	if fin { h2_finalize(t, r); }
}

origin_drop_h2 :: (t: *Transport, o: *Origin, r: *H2_Ref) {
	locks.lock(*t.mu);
	defer locks.unlock(*t.mu);
	if o && o.h2 == r {
		o.h2 = null;
		r.retired = true; // finalized by the last h2_release
	}
}

origin_take_h1 :: (t: *Transport, o: *Origin) -> *http.H1_Conn {
	locks.lock(*t.mu);
	if o.idle_h1 {
		c := pop(*o.idle_h1);
		locks.unlock(*t.mu);
		return c;
	}
	locks.unlock(*t.mu);
	stream, _, dok := dial_tls_stream(o.host, string.["h2", "http/1.1"]);
	if !dok return null;
	c := New(http.H1_Conn,, t.allocator);
	http.h1_init(c, stream, .{},, t.allocator);
	return c;
}

origin_put_h1 :: (t: *Transport, o: *Origin, c: *http.H1_Conn) {
	locks.lock(*t.mu);
	defer locks.unlock(*t.mu);
	if o.idle_h1.count < 6 && !t.closed {
		array_add(*o.idle_h1, c);
	} else {
		http.h1_destroy(c);
		free(c,, t.allocator);
	}
}

// ---- HTTP/3 (Chrome job racing via fc:quic/altsvc) ----

H3_Outcome :: struct {
	resp: http.Response;
	err: http.Error;
}

// The race's "TCP job": our pooled h2 session (dialed or reused).
tcp_dialer :: (host: string, user: *void) -> *void, bool {
	_, ref := origin_get_h2(cast(*Transport) user, host);
	return ref, ref != null;
}

tcp_closer :: (conn: *void, user: *void) {
	if conn h2_release(cast(*Transport) user, cast(*H2_Ref) conn);
}

// h3_round_trip: when the origin has a usable h3 alternative (or a live h3
// session), race QUIC against TCP like Chrome and send on the winner.
// handled=false means no alternative is known: caller uses h2.
h3_round_trip :: (t: *Transport, host: string, req: http.Request) -> H3_Outcome, bool {
	locks.lock(*t.alt.mu);
	live, _ := table_find(*t.alt.conns, host);
	locks.unlock(*t.alt.mu);
	if !live {
		_, usable := altsvc.usable(*t.alt, host);
		if !usable return .{}, false;
		// An established h2 session is preferred over starting a QUIC job
		// (Chrome reuses the SPDY session the main job finds).
		locks.lock(*t.mu);
		has, o := table_find(*t.origins, host);
		h2_live := has && o.h2 && http.h2_can_open(o.h2.c);
		locks.unlock(*t.mu);
		if h2_live return .{}, false;
	}
	// One job per origin at a time (Chrome joins requests onto the pending
	// job instead of racing again).
	if !live locks.lock(*t.race_mu);
	res, ok := altsvc.connect(*t.alt, host, tcp_dialer, tcp_closer, t);
	if !live locks.unlock(*t.race_mu);
	if !ok return .{}, false;
	if res.proto == {
	case .H3;
		if t.conn_observer {
			locks.lock(*t.mu);
			seen := table_contains(*t.h3_seen, res.h3);
			if !seen table_add(*t.h3_seen, res.h3, true);
			locks.unlock(*t.mu);
			// the transport parameters bytes this session's ClientHello carried
			if !seen { t.conn_observer(t.observer_data, .{kind = "h3", host = host, alpn = "h3", quic_params = quic.transport_params(res.h3)}); }
		}
		resp, err := quic.request(res.h3, req,, t.allocator);
		if err != .None && err != .Stream_Reset {
			// Session-level failure after it was established: fall back to h2 this time.
			http.response_destroy(*resp);
			return .{}, false;
		}
		return .{resp, err}, true;
	case .H2;
		ref := cast(*H2_Ref) res.tcp;
		if !ref return .{}, false;
		resp, err := http.h2_request(ref.c, req);
		h2_release(t, ref);
		return .{resp, err}, true;
	}
	return .{}, false;
}

// transport_note_alt_svc: an Alt-Svc value seen for host (jai/tests/transport_probe.jai).
transport_note_alt_svc :: (t: *Transport, host: string, value: string, now: s64) { altsvc.record(*t.alt, host, value); }

// transport_set_altsvc_path enables persistence (Chrome's Network Persistent State).
transport_set_altsvc_path :: (t: *Transport, path: string) { altsvc.load(*t.alt, path); }

