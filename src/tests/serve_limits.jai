// Rate limits on a self-hosted server: jai build.jai - run src/tests/serve_limits.jai, then
// build/serve_limits. Writes only under build/serve_limits_test.
#import "Basic";
#import "File";
#import "File_Utilities";
etf :: #import "etf";
http :: #import "http";
netio :: #import "netio";
serve :: #import "serve";
tls :: #import "tls";
#if OS == .WINDOWS msvcprt :: #library,system,no_dll,link_always "msvcprt";

DIR :: "build/serve_limits_test";

main :: () {
	failed := 0;
	check :: (ok: bool, what: string) #expand {
		if !ok { print("FAIL: %\n", what); `failed += 1; }
	}
	delete_directory(DIR);
	make_directory_if_it_does_not_exist(DIR, recursive = true);
	s, ok := serve.open(tprint("%/server.db", DIR));
	check(ok && serve.listen(s, 0), "open and listen");
	if failed exit(1);
	port, id := s.listener.port, serve.id_hex(s,, context.default_allocator);
	dial :: () -> *tls.Session #expand {
		tcp, err := netio.dial_tcp("127.0.0.1", `port);
		if err != .None return null;
		session := tls.connect(netio.tcp_stream(tcp), .{alpn = .[serve.ALPN], server_name = `id, pin = `s.pin});
		return session;
	}

	// A login is one attempt per connection: each costs an SLH-DSA verify.
	session := dial();
	check(session != null, "connect");
	if session {
		h: http.H1_Conn;
		http.h1_init(*h, tls.stream(session));
		req := http.Request.{method = "POST", path = "/api/v9/fc/login", authority = id, body = cast([]u8) "{}",
			headers = .[.{"Content-Type", "application/json"}, .{"Content-Length", "2"}]};
		resp, err := http.h1_round_trip(*h, req);
		check(err == .None && resp.status == 400, tprint("a bad login is refused: % %", err, resp.status));
		resp, err = http.h1_round_trip(*h, req);
		check(err == .None && resp.status == 429, tprint("a second login on the connection is rate limited: % %", err, resp.status));
		http.h1_destroy(*h, false);
		tls.close(session);
	}

	// The gateway closes past 120 events a minute with 4008.
	session = dial();
	if session {
		req := http.Request.{method = "GET", path = "/?encoding=etf&v=9", authority = id,
			headers = .[.{"Upgrade", "websocket"}, .{"Connection", "Upgrade"}, .{"Sec-WebSocket-Version", "13"}, .{"Sec-WebSocket-Key", ""}]};
		ws, resp, err := http.ws_connect(tls.stream(session), req);
		check(err == .None && resp.status == 101, "upgrade");
		if ws {
			m := etf.map_builder();
			etf.map_put(*m, "op", etf.vint(1));
			etf.map_put(*m, "d", .{});
			beat := etf.encode(etf.vmap(etf.map_done(*m)));
			acks := 0;
			msg: [..]u8;
			http.ws_recv(ws, *msg); // Hello
			for 1..121 {
				if http.ws_send(ws, .Binary, beat) != .None break;
				msg.count = 0;
				type, rerr := http.ws_recv(ws, *msg);
				if rerr != .None || type != .Binary break;
				acks += 1;
			}
			check(acks == 120, tprint("120 heartbeats are answered, then the gateway closes (% answered)", acks));
			http.ws_close_stream(ws);
		}
	}

	// Writes and logins are budgeted per address; loopback is exempt.
	tcp: netio.Tcp;
	tcp.peer = .[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0xFF, 203, 0, 113, 7];
	c := serve.Conn.{server = s, tcp = *tcp};
	writes := 0;
	for 1..200 if !serve.limited(*c, .Write) writes += 1;
	check(writes >= 50 && writes < 60, tprint("an address gets a burst of 50 writes (% allowed)", writes));
	logins := 0;
	for 1..20 if !serve.limited(*c, .Login) logins += 1;
	check(logins == 10, tprint("and 10 logins (% allowed)", logins));
	tcp.peer[15] = 8;
	check(!serve.limited(*c, .Write), "another address has its own budget");
	tcp.peer = .[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0xFF, 127, 0, 0, 1];
	for 1..200 check(!serve.limited(*c, .Write), "loopback is never limited");

	serve.stop(s);
	if failed { print("serve_limits: % failed\n", failed); exit(1); }
	print("serve_limits: ok\n");
}
