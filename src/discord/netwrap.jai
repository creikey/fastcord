// dial_tls_stream: TCP + Chrome TLS to host:443 with the given ALPN list.
// tls.stream forwards shutdown to the socket, so h2_close / the gateway can
// wake a reader blocked inside TLS.
dial_tls_stream :: (host: string, alpn: []string) -> netio.Stream, string, bool {
	under: netio.Stream;
	p := proxy_config();
	if p.kind != .None {
		ok: bool;
		under, ok = proxy_tunnel(p, host, 443);
		if !ok return .{}, "", false;
	} else {
		tcp, derr := netio.dial_tcp(host, 443);
		if derr != .None return .{}, "", false;
		under = netio.tcp_stream(tcp);
	}
	sess, terr := tls.connect(under, .{alpn = alpn, server_name = host});
	if terr != .None {
		netio.close(under);
		return .{}, "", false;
	}
	return tls.stream(sess), tls.negotiated_alpn(sess), true;
}

HOSTED_ALPN :: "fc/1";

// serve gives up on a connection quiet for netio.DIAL_IO_TIMEOUT_MS. A request sent on one it gave up on
// can wait out the whole timeout with no reply and no close, so a connection idle this long is redialled.
HOSTED_IDLE_MS :: netio.DIAL_IO_TIMEOUT_MS - 5_000;

Hosted_Idle :: struct {
	conn: *http.H1_Conn;
	since: Apollo_Time; // monotonic
}

// dial_hosted: TCP + TLS 1.3 to a self-hosted server, accepting only its pinned certificate.
dial_hosted :: (h: Hosted) -> netio.Stream, bool {
	tcp, derr := netio.dial_tcp(h.host, h.port);
	if derr != .None return .{}, false;
	under := netio.tcp_stream(tcp);
	sess, terr := tls.connect(under, .{alpn = .[HOSTED_ALPN], server_name = h.server_id, pin = h.pin});
	if terr != .None {
		netio.close(under);
		return .{}, false;
	}
	return tls.stream(sess), true;
}

// hosted_round_trip carries REST to cfg.hosted over keep-alive HTTP/1.1. Only the token and the body's
// type go out: the browser's headers, cookies and super properties are Discord's business alone.
hosted_round_trip :: (data: *void, host: string, req_in: http.Request) -> http.Response, http.Error {
	c := cast(*Client) data;
	h: [..]http.Header;
	h.allocator = temp;
	for req_in.headers if equal_nocase(it.name, "authorization") || equal_nocase(it.name, "content-type") array_add(*h, it);
	if req_in.method != "GET" && req_in.method != "HEAD" array_add(*h, .{"content-length", tprint("%", req_in.body.count)});
	req := req_in;
	req.headers = h;
	req.authority = c.cfg.hosted.server_id;
	for attempt: 0..1 {
		conn: *http.H1_Conn;
		locks.lock(*c.hosted_mu);
		while !conn && c.hosted_idle.count {
			e := pop(*c.hosted_idle);
			if current_time_monotonic() - e.since < milliseconds_to_apollo(HOSTED_IDLE_MS) conn = e.conn;
			else { http.h1_destroy(e.conn); free(e.conn,, c.allocator); }
		}
		locks.unlock(*c.hosted_mu);
		reused := conn != null;
		if !conn {
			s, ok := dial_hosted(c.cfg.hosted);
			if !ok return .{}, .Io;
			conn = New(http.H1_Conn,, c.allocator);
			http.h1_init(conn, s,, c.allocator);
		}
		resp, err := http.h1_round_trip(conn, req);
		if err == .None && conn.reusable {
			locks.lock(*c.hosted_mu);
			kept := c.hosted_idle.count < 2;
			if kept array_add(*c.hosted_idle, .{conn, current_time_monotonic()});
			locks.unlock(*c.hosted_mu);
			if kept return resp, err;
		}
		http.h1_destroy(conn);
		free(conn,, c.allocator);
		// The server may have closed an idle connection before reading: try once more on a new one.
		if !(reused && err == .Closed) return resp, err;
	}
	return .{}, .Io;
}
