// Self-hosted server check: jai build.jai - run src/tests/serve.jai, then build/serve.exe. Serves on a free
// loopback port; writes only under build/serve_test.
#import "Basic";
#import "File";
#import "File_Utilities";
#import "String";
#import "Base64";
crypto :: #import "crypto";
keys :: #import "keys";
etf :: #import "etf";
http :: #import "http";
netio :: #import "netio";
serve :: #import "serve";
tls :: #import "tls";
#if OS == .WINDOWS msvcprt :: #library,system,no_dll,link_always "msvcprt";

DIR :: "build/serve_test";

main :: () {
	failed := 0;
	check :: (ok: bool, what: string) #expand {
		if !ok { print("FAIL: %\n", what); `failed += 1; }
	}

	delete_directory(DIR);
	make_directory_if_it_does_not_exist(DIR, recursive = true);
	path := tprint("%/server.db", DIR);

	s, ok := serve.open(path);
	check(ok, "open");
	if !ok exit(1);
	pin, id := s.pin, serve.id_hex(s,, context.default_allocator);
	invite := serve.invite_url(s, "127.0.0.1", 0, "code");
	serve.stop(s);
	s, ok = serve.open(path);
	check(ok && crypto.constant_time_equal(s.pin, pin) && serve.id_hex(s) == id, "reopen keeps the pin and ID");
	check(serve.invite_url(s, "127.0.0.1", 0, "code") == invite, "invite is stable");
	print("invite: %\n", invite);
	check(serve.listen(s, 0), "listen");
	port := s.listener.port;

	dial :: (pin: [32]u8, alpn: string) -> *tls.Session #expand {
		tcp, err := netio.dial_tcp("127.0.0.1", `port);
		if err != .None return null;
		session, _, terr := tls.connect(netio.tcp_stream(tcp), .{alpn = .[alpn], server_name = `id, pin = pin});
		if !session { netio.close(netio.tcp_stream(tcp)); return null; }
		return session;
	}

	bad := pin;
	bad[0] ^= 1;
	check(dial(bad, serve.ALPN) == null, "a wrong pin is refused");
	check(dial(pin, "http/1.1") == null, "a wrong ALPN is refused");

	session := dial(pin, serve.ALPN);
	check(session != null, "pinned connect");
	if session {
		st := tls.stream(session);
		req := http.Request.{method = "GET", path = "/?encoding=etf&v=9", authority = id,
			headers = .[.{"Upgrade", "websocket"}, .{"Connection", "Upgrade"}, .{"Sec-WebSocket-Version", "13"}, .{"Sec-WebSocket-Key", ""}]};
		ws, resp, err := http.ws_connect(st, req);
		check(err == .None && resp.status == 101, tprint("upgrade: % %", err, resp.status));
		if ws {
			op_of :: (ws: *http.Ws_Conn) -> s64 {
				msg: [..]u8;
				type, err := http.ws_recv(ws, *msg);
				if err != .None return -1;
				v, derr := etf.decode(msg);
				if derr != .None || v.kind != .Map return -2;
				op, _ := etf.map_get(v.map, "op");
				return op.i;
			}
			check(op_of(ws) == 10, "hello");
			m := etf.map_builder();
			etf.map_put(*m, "op", etf.vint(1));
			etf.map_put(*m, "d", .{});
			bytes := etf.encode(etf.vmap(etf.map_done(*m)));
			check(http.ws_send(ws, .Binary, bytes) == .None, "send heartbeat");
			check(op_of(ws) == 11, "heartbeat ack");
			http.ws_close_stream(ws);
		}
	}

	// Logs in as k on a new connection, signing over the exporter of `over` (the same one, unless testing
	// a relayed signature). Returns the HTTP status and body.
	login :: (k: keys.Keypair, code: string, name: string, relay := false) -> int, string #expand {
		session := dial(`pin, serve.ALPN);
		if !session return -1, "";
		defer tls.close(session);
		signed := session;
		other: *tls.Session;
		if relay { other = dial(`pin, serve.ALPN); signed = other; }
		defer if other tls.close(other);
		msg, _ := serve.login_message(signed, `s.id);
		sig := crypto.slhdsa_sign(k.signing, serve.LOGIN_CONTEXT, msg);
		p := keys.proof(k, .Signing);
		body := tprint("{\"root\": \"%\", \"signing_pub\": \"%\", \"proof\": [\"%\", \"%\"], \"sig\": \"%\", \"code\": \"%\", \"name\": \"%\"}",
			keys.root_hex(k.root), keys.root_hex(k.signing_pub), keys.root_hex(p[0]), keys.root_hex(p[1]), base64_encode(cast(string) sig), code, name);
		h: http.H1_Conn;
		http.h1_init(*h, tls.stream(session));
		defer http.h1_destroy(*h, false);
		req := http.Request.{method = "POST", path = "/api/v9/fc/login", authority = `id, body = cast([]u8) body,
			headers = .[.{"Content-Type", "application/json"}, .{"Content-Length", tprint("%", body.count)}]};
		resp, err := http.h1_round_trip(*h, req);
		if err != .None return -2, "";
		return resp.status, copy_string(cast(string) resp.body,, temp);
	}

	k := keys.generate("Tester");
	other := keys.generate("Other");
	code := serve.first_invite(s);
	status, body := login(k, "wrong", "Tester");
	check(status == 404, tprint("a wrong code is refused: % %", status, body));
	status, body = login(k, code, "Tester", relay = true);
	check(status == 401, tprint("a signature from another connection is refused: % %", status, body));
	status, body = login(k, code, "Tester");
	check(status == 200 && begins_with(body, "{\"token\": \""), tprint("join: % %", status, body));
	status, body = login(k, "", "");
	check(status == 200, tprint("a member logs in without a code: % %", status, body));
	status, body = login(other, "", "Other");
	check(status == 404, tprint("a stranger without a code is refused: % %", status, body));

	serve.stop(s);
	print("% failed\n", failed);
	exit(xx ifx failed then 1 else 0);
}
