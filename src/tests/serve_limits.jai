// Rate limits on a self-hosted server: jai build.jai - run src/tests/serve_limits.jai, then
// build/serve_limits. Writes only under build/serve_limits_test.
#import "Basic";
#import "File";
#import "File_Utilities";
#import "Base64";
crypto :: #import "crypto";
keys :: #import "keys";
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

	// Logout (sent as a client quits) ends the session: its token opens nothing afterwards.
	session = dial();
	if session {
		k := keys.generate("Quitter");
		msg, _ := serve.login_message(session, s.id);
		sig := crypto.slhdsa_sign(k.signing, serve.LOGIN_CONTEXT, msg);
		p := keys.proof(k, .Signing);
		body := tprint("{\"root\": \"%\", \"signing_pub\": \"%\", \"proof\": [\"%\", \"%\"], \"sig\": \"%\", \"code\": \"%\", \"name\": \"Quitter\"}",
			keys.root_hex(k.root), keys.root_hex(k.signing_pub), keys.root_hex(p[0]), keys.root_hex(p[1]), base64_encode(cast(string) sig), serve.first_invite(s));
		h: http.H1_Conn;
		http.h1_init(*h, tls.stream(session));
		req := http.Request.{method = "POST", path = "/api/v9/fc/login", authority = id, body = cast([]u8) body,
			headers = .[.{"Content-Type", "application/json"}, .{"Content-Length", tprint("%", body.count)}]};
		resp := http.h1_round_trip(*h, req);
		token := "";
		v, err := etf.from_json(cast(string) resp.body,, temp);
		if err == .None && v.kind == .Map { t, _ := etf.map_get(v.map, "token"); if t.kind == .String token = t.s; }
		check(resp.status == 200 && token != "", tprint("login: %", resp.status));
		call :: (method: string, path: string) -> int #expand {
			r := http.Request.{method = method, path = path, authority = `id, headers = .[.{"Authorization", `token}, .{"Content-Length", "0"}]};
			rr := http.h1_round_trip(*`h, r);
			return rr.status;
		}
		check(call("GET", "/api/v9/users/@me/mentions") == 200, "the token works");
		check(call("POST", "/api/v9/auth/logout") == 204, "logout");
		check(call("GET", "/api/v9/users/@me/mentions") == 401, "after logout the token opens nothing");
		http.h1_destroy(*h, false);
		tls.close(session);
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
