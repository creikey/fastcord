// Self-hosted server check: jai build.jai - run src/tests/serve.jai, then build/serve.exe. Serves on a free
// loopback port; writes only under build/serve_test.
#import "Basic";
#import "File";
#import "File_Utilities";
#import "String";
#import "Base64";
#import "Hash_Table";
crypto :: #import "crypto";
discord :: #import "discord";
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
	inv, inv_ok := serve.parse_invite(serve.invite_url(s, "::1", port, code));
	check(inv_ok && inv.host == "::1" && inv.port == port && inv.code == code, "parse an IPv6 invite");
	inv, inv_ok = serve.parse_invite(serve.invite_url(s, "127.0.0.1", port, code));
	token, lstatus, lmessage := serve.member_login(inv, k, "");
	check(inv_ok && token.count == 64, tprint("member_login: % %", lstatus, lmessage));
	wrong := inv;
	wrong.pin[0] ^= 1;
	_, lstatus, lmessage = serve.member_login(wrong, k, "");
	check(lstatus == 0 && contains(lmessage, "certificate"), tprint("member_login: a wrong pin: % %", lstatus, lmessage));

	// The gateway: Identify with the token, then READY lists the guild and #general.
	gs := dial(pin, serve.ALPN);
	ws: *http.Ws_Conn;
	if gs {
		req := http.Request.{method = "GET", path = "/?encoding=etf&v=9", authority = id,
			headers = .[.{"Upgrade", "websocket"}, .{"Connection", "Upgrade"}, .{"Sec-WebSocket-Version", "13"}, .{"Sec-WebSocket-Key", ""}]};
		ws = http.ws_connect(tls.stream(gs), req);
	}
	check(ws != null, "gateway");
	recv_event :: (ws: *http.Ws_Conn) -> etf.Value {
		msg: [..]u8;
		while true {
			msg.count = 0;
			_, err := http.ws_recv(ws, *msg);
			if err != .None return .{};
			v, derr := etf.decode(msg);
			op, _ := etf.map_get(v.map, "op");
			if op.i == 0 return v;
		}
		return .{};
	}
	field :: (root: etf.Value, path: ..string) -> etf.Value {
		v := root;
		for path { if v.kind != .Map return .{}; v = etf.map_get(v.map, it); }
		return v;
	}
	channel: string;
	if ws {
		d := etf.map_builder();
		etf.map_put(*d, "token", etf.vstring(token));
		m := etf.map_builder();
		etf.map_put(*m, "op", etf.vint(2));
		etf.map_put(*m, "d", etf.vmap(etf.map_done(*d)));
		http.ws_send(ws, .Binary, etf.encode(etf.vmap(etf.map_done(*m))));
		ready := recv_event(ws);
		guilds := field(ready, "d", "guilds");
		check(field(ready, "t").s == "READY" && field(ready, "d", "user", "username").s == "Tester" && guilds.list.count == 1, "READY");
		if guilds.list.count {
			chans := field(guilds.list[0], "channels");
			check(chans.list.count == 1 && field(chans.list[0], "name").s == "general", "READY has #general");
			if chans.list.count channel = field(chans.list[0], "id").s;
		}
	}

	rest :: (method: string, path: string, body: string, token: string) -> int, string #expand {
		session := dial(`pin, serve.ALPN);
		if !session return -1, "";
		defer tls.close(session);
		h: http.H1_Conn;
		http.h1_init(*h, tls.stream(session));
		defer http.h1_destroy(*h, false);
		req := http.Request.{method = method, path = path, authority = `id, body = cast([]u8) body,
			headers = .[.{"authorization", token}, .{"Content-Type", "application/json"}, .{"Content-Length", tprint("%", body.count)}]};
		resp, err := http.h1_round_trip(*h, req);
		if err != .None return -2, "";
		return resp.status, copy_string(cast(string) resp.body,, temp);
	}
	messages := tprint("/api/v9/channels/%/messages", channel);
	status, body = rest("GET", messages, "", "bad");
	check(status == 401, tprint("REST needs a token: %", status));
	status, body = rest("POST", messages,"{\"content\": \"hello\", \"nonce\": \"123\"}", token);
	check(status == 200 && contains(body, "\"nonce\":\"123\""),tprint("send: % %", status, body));
	if ws {
		ev := recv_event(ws);
		check(field(ev, "t").s == "MESSAGE_CREATE" && field(ev, "d", "content").s == "hello" && field(ev, "d", "author", "username").s == "Tester", "MESSAGE_CREATE");
		http.ws_close_stream(ws);
	}
	status, body = rest("GET", tprint("%?limit=50", messages), "", token);
	list, _ := etf.from_json(body);
	check(status == 200 && list.kind == .List && list.list.count == 1 && field(list.list[0], "content").s == "hello", tprint("fetch: % %", status, body));
	print("message: %\n", body);

	// The real client on the plain profile: READY, the first page, then a message sent through it.
	cid := string_to_int(channel, T = u64);
	cl := discord.client_create(.{token = token, hosted = .{host = "127.0.0.1", port = port, pin = pin, server_id = id}});
	discord.client_start(cl);
	pump :: () #expand { discord.client_poll(`cl); sleep_milliseconds(10); }
	stored :: () -> []discord.Message #expand {
		ok, l := table_find(*`cl.store.messages, `cid);
		if !ok return .[];
		return l.messages;
	}
	for 1..1000 { if cl.store.ready break; pump(); }
	name := "";
	if cl.store.guild_order.count {
		has_g, g := table_find(*cl.store.guilds, cl.store.guild_order[0]);
		if has_g name = g.name;
	}
	check(cl.store.ready && name == "server", tprint("client READY: % %", cl.store.ready, name));
	discord.fetch_messages(cl, cid);
	for 1..1000 { if stored().count == 1 break; pump(); }
	check(stored().count == 1 && stored()[0].content == "hello", "client fetch");
	discord.send_message(cl, cid, "from the client");
	// The send's response and MESSAGE_CREATE both settle the optimistic message into one.
	for 1..300 pump();
	check(stored().count == 2 && stored()[1].content == "from the client" && stored()[1].author_id == cl.store.me, tprint("client send: %", stored().count));
	if stored().count == 2 {
		mid := stored()[1].id;
		discord.edit_message(cl, cid, mid, "edited");
		for 1..300 { if stored()[1].content == "edited" break; pump(); }
		check(stored()[1].content == "edited", "client edit");
		discord.delete_message(cl, cid, mid);
		for 1..300 { if stored().count == 1 break; pump(); }
		check(stored().count == 1, "client delete");
	}
	discord.send_typing(cl, cid);
	typing_ok := false;
	for 1..300 {
		has_t, t := table_find(*cl.store.typing, cid);
		if has_t && t.count && t[0].user_id == cl.store.me { typing_ok = true; break; }
		pump();
	}
	check(typing_ok, "TYPING_START");
	discord.client_destroy(cl);
	status, body = rest("PATCH", tprint("%/1", messages), "{\"content\": \"x\"}", token);
	check(status == 404, tprint("edit an unknown message: %", status));
	status, body = rest("GET", messages, "", token);
	list, _ = etf.from_json(body);
	check(status == 200 && list.kind == .List && list.list.count == 1, tprint("the client's delete reached the server: % %", status, body));
	if list.list.count {
		status, body = rest("PATCH", tprint("%/%", messages, field(list.list[0], "id").s), "{\"content\": \"hi\"}", token);
		check(status == 200 && contains(body, "\"content\":\"hi\"") && !contains(body, "\"edited_timestamp\":null"), tprint("edit: % %", status, body));
	}
	status, body = login(other, "", "Other");
	check(status == 404, tprint("a stranger without a code is refused: % %", status, body));

	serve.stop(s);
	print("% failed\n", failed);
	exit(xx ifx failed then 1 else 0);
}
