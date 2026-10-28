// Self-hosted server check: jai build.jai - run src/tests/serve.jai, then build/serve.exe. Serves on a free
// loopback port; writes only under build/serve_test.
#import "Basic";
#import "File";
#import "File_Utilities";
#import "String";
#import "Base64";
#import "Hash_Table";
#import "Thread";
crypto :: #import "crypto";
discord :: #import "discord";
keys :: #import "keys";
locks :: #import "locks";
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

	{
		bomb := NewArray(1 << 20, u8,, temp);
		for * bomb it.* = 106;
		bomb[0] = 131;
		p := 1;
		for 1..128 {
			n := bomb.count - p - 6;
			bomb[p] = 108;
			for i: 0..3 bomb[p + 1 + i] = cast(u8) (n >> (24 - 8 * i));
			p += 5;
		}
		_, err := etf.decode(bomb,, temp);
		check(err == .Too_Large, tprint("nested list headers claiming huge counts are refused before allocating: %", err));
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
	owner_code := serve.owner_invite(s,, context.default_allocator);
	check(owner_code && owner_code != code, "a new server has an owner invite");
	status, body = login(k, owner_code, "Tester");
	check(status == 200 && begins_with(body, "{\"token\": \""), tprint("join: % %", status, body));
	check(serve.owner_invite(s) == "", "the owner invite works once");
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
		members_ev := recv_event(ws);
		check(field(members_ev, "t").s == "GUILD_MEMBER_LIST_UPDATE" && field(members_ev, "d", "online_count").i == 1, "member list after READY");
		presence :: (ws: *http.Ws_Conn, status: string) {
			p := etf.map_builder();
			etf.map_put(*p, "status", etf.vstring(status));
			m := etf.map_builder();
			etf.map_put(*m, "op", etf.vint(3));
			etf.map_put(*m, "d", etf.vmap(etf.map_done(*p)));
			http.ws_send(ws, .Binary, etf.encode(etf.vmap(etf.map_done(*m))));
		}
		presence(ws, "dnd");
		ev := recv_event(ws);
		items := field(ev, "d", "ops");
		if items.kind == .List && items.list.count items = field(items.list[0], "items");
		check(items.kind == .List && items.list.count == 2 && field(items.list[1], "member", "presence", "status").s == "dnd", "Do Not Disturb shows in the member list");
		presence(ws, "invisible");
		ev = recv_event(ws);
		check(field(ev, "d", "online_count").i == 0, "Invisible lists the member offline");
		presence(ws, "online");
		ev = recv_event(ws);
		check(field(ev, "d", "online_count").i == 1, "back online");
		{
			a := etf.map_builder();
			etf.map_put(*a, "type", etf.vint(4));
			etf.map_put(*a, "name", etf.vstring("Custom Status"));
			etf.map_put(*a, "state", etf.vstring("hacking"));
			acts := NewArray(1, etf.Value);
			acts[0] = etf.vmap(etf.map_done(*a));
			p := etf.map_builder();
			etf.map_put(*p, "status", etf.vstring("online"));
			etf.map_put(*p, "activities", etf.vlist(acts));
			m := etf.map_builder();
			etf.map_put(*m, "op", etf.vint(3));
			etf.map_put(*m, "d", etf.vmap(etf.map_done(*p)));
			http.ws_send(ws, .Binary, etf.encode(etf.vmap(etf.map_done(*m))));
			ev = recv_event(ws);
			items = field(ev, "d", "ops");
			if items.kind == .List && items.list.count items = field(items.list[0], "items");
			shown: etf.Value;
			if items.kind == .List && items.list.count == 2 shown = field(items.list[1], "member", "presence", "activities");
			check(shown.kind == .List && shown.list.count == 1 && field(shown.list[0], "state").s == "hacking", "a custom status shows in the member list");
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
	// The owner's join posted a welcome; drop it so the counts below start from nothing.
	status, body = rest("GET", messages, "", token);
	welcome, _ := etf.from_json(body);
	check(status == 200 && welcome.list.count == 1 && field(welcome.list[0], "type").i == 7 && field(welcome.list[0], "author", "username").s == "Tester", tprint("the join's welcome message: %", body));
	if welcome.list.count rest("DELETE", tprint("%/%", messages, field(welcome.list[0], "id").s), "", token);
	status, body = rest("GET", messages, "", "bad");
	check(status == 401, tprint("REST needs a token: %", status));
	status, body = rest("POST", messages, "{\"content\": \"long\", \"nonce\": \"12345678901234567890123456\"}", token);
	check(status == 400, tprint("a nonce over 25 bytes is refused: %", status));
	status, body = rest("POST", messages,"{\"content\": \"hello\", \"nonce\": \"123\"}", token);
	check(status == 200 && contains(body, "\"nonce\":\"123\""),tprint("send: % %", status, body));
	if ws {
		ev := recv_event(ws);
		if field(ev, "t").s == "MESSAGE_DELETE" ev = recv_event(ws); // The welcome's.
		check(field(ev, "t").s == "MESSAGE_CREATE" && field(ev, "d", "content").s == "hello" && field(ev, "d", "author", "username").s == "Tester", "MESSAGE_CREATE");
		http.ws_close_stream(ws);
	}
	status, body = rest("GET", tprint("%?limit=50", messages), "", token);
	list, _ := etf.from_json(body);
	check(status == 200 && list.kind == .List && list.list.count == 1 && field(list.list[0], "content").s == "hello", tprint("fetch: % %", status, body));
	print("message: %\n", body);

	// Link previews: a page behind a redirect, from a server on this machine (which only tests may reach).
	check(!netio.is_public_address(u8.[127, 0, 0, 1]) && !netio.is_public_address(u8.[192, 168, 1, 1]) && !netio.is_public_address(u8.[100, 64, 0, 1])
		&& !netio.is_public_address(u8.[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0xFF, 10, 0, 0, 1]) && !netio.is_public_address(u8.[0xFE, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1])
		&& netio.is_public_address(u8.[1, 1, 1, 1]) && netio.is_public_address(u8.[0x26, 0x06, 0x47, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x11, 0x11]), "only public addresses are fetched");
	{
		pages, lerr := netio.listen_tcp(0);
		check(lerr == .None, "page server");
		page_server :: (thread: *Thread) -> s64 {
			l := cast(*netio.Listener) thread.data;
			for 0..1 {
				t, err := netio.accept_tcp(l);
				if err != .None return 0;
				h: http.H1_Conn;
				http.h1_init(*h, netio.tcp_stream(t));
				req, rerr := http.h1_read_request(*h);
				if req.path == "/start" {
					http.h1_write_response(netio.tcp_stream(t), 302, .[.{"location", "/page"}, .{"content-length", "0"}], .[]);
				} else {
					body := "<html><head><title>Plain</title><!-- <meta property=\"og:title\" content=\"hidden\"> --><meta property=\"og:title\" content=\"Tom &amp; Jerry\"><meta name=description content=\"A  cat\nand a mouse.\"><meta property=\"og:site_name\" content=\"Cartoons\"></head><body>x</body></html>";
					http.h1_write_response(netio.tcp_stream(t), 200, .[.{"content-type", "text/html; charset=utf-8"}, .{"content-length", tprint("%", body.count)}], cast([]u8) body);
				}
				http.h1_destroy(*h);
			}
			return 0;
		}
		server := New(Thread); // locks.join frees it.
		thread_init(server, page_server);
		server.data = pages;
		thread_start(server);
		s.unfurl_any_address = true;
		status, body = rest("POST", messages, tprint("{\"content\": \"look at http://127.0.0.1:%/start.\"}", pages.port), token);
		sent, _ := etf.from_json(body);
		got: etf.Value;
		for 1..100 {
			sleep_milliseconds(50);
			_, one := rest("GET", tprint("%?limit=1", messages), "", token);
			list, _ := etf.from_json(one);
			if list.kind == .List && list.list.count && field(list.list[0], "embeds").list.count { got = field(list.list[0], "embeds").list[0]; break; }
		}
		check(field(got, "title").s == "Tom & Jerry" && field(got, "description").s == "A cat and a mouse." && field(got, "provider", "name").s == "Cartoons"
			&& field(got, "url").s == tprint("http://127.0.0.1:%/start", pages.port), tprint("a link gets a preview: %", got));
		netio.close_listener(pages);
		locks.join(server);
		status, body = rest("PATCH", tprint("%/%", messages, field(sent, "id").s), "{\"flags\": 4}", token);
		hidden, _ := etf.from_json(body);
		check(status == 200 && field(hidden, "flags").i == 4 && field(hidden, "embeds").list.count == 0 && field(hidden, "content").s != "", tprint("Remove Embeds: % %", status, body));
		rest("DELETE", tprint("%/%", messages, field(sent, "id").s), "", token);
	}

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
		hello := stored()[0].id;
		discord.send_message(cl, cid, "a reply", .{reply_to = hello, reply_guild_id = cl.store.guild_order[0]});
		for 1..300 { if stored().count == 2 && !stored()[1].pending break; pump(); }
		check(stored().count == 2 && !stored()[1].pending && stored()[1].kind == 19 && stored()[1].referenced_id == hello, "client reply");
		discord.add_reaction(cl, cid, hello, "👍");
		for 1..100 pump();
		status, body = rest("GET", messages, "", token);
		fetched, _ := etf.from_json(body);
		r := field(fetched.list[fetched.list.count - 1], "reactions");
		check(r.kind == .List && r.list.count == 1 && field(r.list[0], "emoji", "name").s == "👍" && field(r.list[0], "count").i == 1 && field(r.list[0], "me").b,
			tprint("reaction: %", body));
		check(stored()[0].reactions.count == 1 && stored()[0].reactions[0].count == 1, "client reaction");
		discord.remove_reaction(cl, cid, hello, "👍");
		for 1..100 pump();
		status, body = rest("GET", messages, "", token);
		check(!contains(body, "reactions"), tprint("reaction removed: %", body));
		react := tprint("%/%/reactions", messages, hello);
		status, body = rest("PUT", tprint("%/lol/@me", react), "", token);
		check(status == 400, tprint("a word isn't an emoji: %", status));
		status, body = rest("POST", messages, "{\"content\": \"a\\u0000b\"}", token);
		check(status == 400, tprint("control characters are refused: %", status));
		// U+1F600 onwards: 20 distinct emoji fit on a message, the 21st doesn't.
		for i: 0..20 {
			status, body = rest("PUT", tprint("%/\%F0\%9F\%98\%%/@me", react, formatInt(0x80 + i, base = 16)), "", token);
			if status != 204 break;
		}
		check(status == 400 && contains(body, "30010"), tprint("at most 20 distinct reactions: % %", status, body));
		for i: 0..20 rest("DELETE", tprint("%/\%F0\%9F\%98\%%/@me", react, formatInt(0x80 + i, base = 16)), "", token);
		for 1..100 pump();

		// Pins: the owner pins through the client; the message updates and the list has it.
		epoch := discord.pins_epoch(cid);
		discord.pin_message(cl, cid, hello, true);
		for 1..300 { if stored()[0].pinned && discord.pins_epoch(cid) != epoch break; pump(); }
		check(stored()[0].pinned && discord.pins_epoch(cid) != epoch, "pin: MESSAGE_UPDATE and CHANNEL_PINS_UPDATE");
		status, body = rest("GET", tprint("%/pins", messages), "", token);
		pinned, _ := etf.from_json(body);
		items := field(pinned, "items");
		check(status == 200 && items.kind == .List && items.list.count == 1 && field(items.list[0], "message", "content").s == "hello"
			&& field(items.list[0], "pinned_at").kind == .String, tprint("pins list: % %", status, body));
		// The "pinned a message" notice: a type 6 message pointing at the pin, which can't be edited.
		for 1..300 { if stored().count == 3 break; pump(); }
		notice := ifx stored().count == 3 then *stored()[2] else null;
		check(notice && notice.kind == 6 && notice.referenced_id == hello && notice.author_id == cl.store.me, "the pinned-a-message notice");
		if notice {
			status, body = rest("PATCH", tprint("%/%", messages, notice.id), "{\"content\": \"x\"}", token);
			check(status == 400, tprint("a system message can't be edited: % %", status, body));
			status, body = rest("DELETE", tprint("%/%", messages, notice.id), "", token);
			for 1..300 { if stored().count == 2 break; pump(); }
			check(status == 204 && stored().count == 2, tprint("delete the notice: %", status));
		}
		discord.pin_message(cl, cid, hello, false);
		for 1..300 { if !stored()[0].pinned break; pump(); }
		check(!stored()[0].pinned, "unpin");

		// A read mark survives a new session: the next READY carries it.
		discord.ack_message(cl, cid, hello, immediate = true);
		for 1..100 pump();
		cl2 := discord.client_create(.{token = token, hosted = cl.cfg.hosted});
		discord.client_start(cl2);
		for 1..1000 { if cl2.store.ready break; discord.client_poll(cl2); sleep_milliseconds(10); }
		has_rs, rs := table_find(*cl2.store.read_states, cid);
		check(cl2.store.ready && has_rs && rs.last_message_id == hello, tprint("read state in READY: % %", has_rs, rs.last_message_id));
		discord.client_destroy(cl2);
	}
	discord.send_typing(cl, cid);
	typing_ok := false;
	for 1..300 {
		has_t, t := table_find(*cl.store.typing, cid);
		if has_t && t.count && t[0].user_id == cl.store.me { typing_ok = true; break; }
		pump();
	}
	check(typing_ok, "TYPING_START");
	gid := cl.store.guild_order[0];
	discord.subscribe_member_list(cl, gid, cid, ([2]int).[.[0, 99]]);
	ml: *discord.Member_List;
	for 1..300 { ml = table_find_pointer(*cl.store.member_lists, gid); if ml && ml.online_count == 1 break; pump(); }
	check(ml && ml.online_count == 1 && ml.items.count == 2 && ml.items[1].user_id == cl.store.me, tprint("member list: %", ifx ml then ml.items.count else -1));

	g := discord.guild_get(*cl.store, gid);
	check(g && g.owner_id == cl.store.me, "READY names the owner");
	// The client's own Create Channel flow, as the app runs it: no Discord-only parity fetches go out.
	discord.open_create_channel(cl, gid);
	discord.create_channel(cl, gid, .Guild_Text, "Off Topic", 0);
	new_id: u64;
	aux, created := 0, false;
	for 1..300 {
		pump();
		for * discord.feature_take(cl) {
			discord.guild_admin_apply(cl, it);
			if it.op == .Guild_Aux aux += 1;
			if it.op == .Channel_Create && it.ok { created = true; new_id = discord.fsnow(discord.vmap(it.body), "id"); }
			discord.feature_result_free(it);
		}
		if created && discord.channel_get(*cl.store, new_id) break;
	}
	ch := discord.channel_get(*cl.store, new_id);
	check(created && ch && ch.name == "off-topic", "create a channel, and CHANNEL_CREATE");
	for 1..50 { pump(); for * discord.feature_take(cl) { if it.op == .Guild_Aux aux += 1; discord.feature_result_free(it); } }
	check(aux == 0, tprint("no Discord-only fetches when hosted: %", aux));
	status, body = rest("PATCH", tprint("/api/v9/channels/%", new_id), "{\"topic\": \"anything\"}", token);
	check(status == 200 && contains(body, "\"topic\":\"anything\""), tprint("edit a channel: % %", status, body));
	status, body = rest("DELETE", tprint("/api/v9/channels/%", new_id), "", token);
	check(status == 200, tprint("delete a channel: % %", status, body));
	for 1..300 { if !discord.channel_get(*cl.store, new_id) break; pump(); }
	check(discord.channel_get(*cl.store, new_id) == null, "CHANNEL_DELETE");
	status, body = rest("DELETE", tprint("/api/v9/channels/%", cid), "", token);
	check(status == 400, tprint("the last channel stays: %", status));

	// Categories: a channel made inside one carries parent_id, a category takes no messages, and deleting
	// it leaves its channels uncategorized.
	status, body = rest("POST", tprint("/api/v9/guilds/%/channels", gid), "{\"name\": \"Big Stuff\", \"type\": 4}", token);
	cat, _ := etf.from_json(body);
	cat_id := field(cat, "id").s;
	check(status == 201 && field(cat, "name").s == "Big Stuff" && field(cat, "type").i == 4, tprint("create a category: % %", status, body));
	status, body = rest("POST", tprint("/api/v9/guilds/%/channels", gid), tprint("{\"name\": \"inside\", \"type\": 0, \"parent_id\": \"%\"}", cat_id), token);
	inside, _ := etf.from_json(body);
	inside_id := field(inside, "id").s;
	check(status == 201 && field(inside, "parent_id").s == cat_id, tprint("create a channel in a category: % %", status, body));
	status, body = rest("POST", tprint("/api/v9/guilds/%/channels", gid), tprint("{\"name\": \"x\", \"type\": 2}"), token);
	check(status == 400, tprint("no voice channels yet: %", status));
	status, body = rest("POST", tprint("/api/v9/channels/%/messages", cat_id), "{\"content\": \"x\"}", token);
	check(status == 404, tprint("a category takes no messages: %", status));
	status, body = rest("DELETE", tprint("/api/v9/channels/%", cat_id), "", token);
	check(status == 200, tprint("delete a category: % %", status, body));
	in_id := string_to_int(inside_id, T = discord.Snowflake);
	for 1..300 { ic := discord.channel_get(*cl.store, in_id); if ic && !ic.parent_id break; pump(); }
	ic := discord.channel_get(*cl.store, in_id);
	check(ic && !ic.parent_id, "a deleted category's channels stay, uncategorized");
	status, body = rest("DELETE", tprint("/api/v9/channels/%", inside_id), "", token);

	// A member's invite, as the Invite modal makes it; opening the modal again gets the same one.
	made := discord.create_invite(cl, cid,, context.default_allocator);
	again := discord.create_invite(cl, cid,, context.default_allocator);
	check(made.ok && made.code.count == 12 && made.guild_id == gid && again.code == made.code, tprint("create an invite: % % %", made.status, made.code, again.code));
	member_invite, member_ok := serve.parse_invite(serve.invite_url(pin, "127.0.0.1", port, id, made.code));

	// A dropped gateway can't resume here, so the client identifies afresh, and the fresh READY refetches
	// the open channel: a message sent while it was away still shows up.
	discord.select_channel(cl, gid, cid);
	for 1..100 pump();
	readies := cl.store.readies;
	locks.lock(*s.mu);
	for s.conns if it.ws netio.shutdown(netio.tcp_stream(it.tcp));
	locks.unlock(*s.mu);
	status, body = rest("POST", messages, "{\"content\": \"while away\"}", token);
	last :: () -> string #expand { m := stored(); return ifx m.count then m[m.count - 1].content else ""; }
	for 1..1500 { if cl.store.readies > readies && last() == "while away" break; pump(); }
	check(cl.store.readies > readies && last() == "while away", tprint("a reconnect catches up: % %", cl.store.readies - readies, last()));
	away, _ := etf.from_json(body);
	rest("DELETE", tprint("%/%", messages, field(away, "id").s), "", token);
	discord.client_destroy(cl);
	status, body = rest("PATCH", tprint("%/1", messages), "{\"content\": \"x\"}", token);
	check(status == 404, tprint("edit an unknown message: %", status));
	status, body = rest("GET", messages, "", token);
	list, _ = etf.from_json(body);
	check(status == 200 && list.kind == .List && list.list.count == 2 && field(list.list[0], "referenced_message", "content").s == "hello",
		tprint("the client's delete and reply reached the server: % %", status, body));
	if list.list.count {
		status, body = rest("PATCH", tprint("%/%", messages, field(list.list[0], "id").s), "{\"content\": \"hi\"}", token);
		edited, _ := etf.from_json(body);
		check(status == 200 && field(edited, "content").s == "hi" && field(edited, "edited_timestamp").kind == .String && field(edited, "type").i == 19, tprint("edit: % %", status, body));
	}
	status, body = rest("POST", messages, "{\"content\": \"x\", \"message_reference\": {\"message_id\": \"1\"}}", token);
	check(status == 400, tprint("a reply to an unknown message is refused: %", status));
	{
		png, _ := base64_decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==",, temp);
		status, body = rest("POST", tprint("/api/v9/channels/%/attachments", channel), tprint("{\"files\": [{\"id\": \"0\", \"filename\": \"dot.png\", \"file_size\": %, \"original_content_type\": \"image/png\"}]}", png.count), token);
		slot, _ := etf.from_json(body);
		up := field(slot, "attachments");
		check(status == 200 && up.kind == .List && up.list.count == 1, tprint("an upload slot: % %", status, body));
		if up.kind == .List && up.list.count {
			url, name := field(up.list[0], "upload_url").s, field(up.list[0], "upload_filename").s;
			path := slice(url, find_index_from_left(url, "/upload/"), url.count);
			status, body = rest("PUT", path, "short", "");
			check(status == 404, tprint("a PUT of the wrong size is refused: %", status));
			status, body = rest("PUT", path, png, "");
			check(status == 200, tprint("the PUT is taken: % %", status, body));
			status, body = rest("POST", messages, tprint("{\"attachments\": [{\"id\": \"0\", \"filename\": \"dot.png\", \"uploaded_filename\": \"%\", \"is_spoiler\": true}]}", name), token);
			sent, _ := etf.from_json(body);
			files := field(sent, "attachments");
			check(status == 200 && files.kind == .List && files.list.count == 1 && field(files.list[0], "width").i == 1 && field(files.list[0], "filename").s == "SPOILER_dot.png", tprint("a message with a file: % %", status, body));
			status, body = rest("POST", messages, tprint("{\"attachments\": [{\"id\": \"0\", \"filename\": \"dot.png\", \"uploaded_filename\": \"%\"}]}", name), token);
			check(status == 400, tprint("an upload sends only once: %", status));
			if files.kind == .List && files.list.count {
				got := field(files.list[0], "url").s;
				status, body = rest("GET", slice(got, find_index_from_left(got, "/attachments/"), got.count), "", "");
				check(status == 200 && body == png, tprint("the file reads back: % %", status, body.count));
				rest("DELETE", tprint("%/%", messages, field(sent, "id").s), "", token);
				status, body = rest("GET", slice(got, find_index_from_left(got, "/attachments/"), got.count), "", "");
				check(status == 404, tprint("a deleted message's file is gone: %", status));
			}
		}
	}
	status, body = login(other, "", "Other");
	check(status == 404, tprint("a stranger without a code is refused: % %", status, body));
	other_token, ostatus, omessage := serve.member_login(member_invite, other, "Other");
	check(member_ok && other_token.count == 64, tprint("join with a member's invite: % %", ostatus, omessage));
	status, body = rest("GET", tprint("%?limit=1", messages), "", token);
	check(contains(body, "\"type\":7") && contains(body, "\"Other\""), tprint("a member's join posts a welcome: %", body));
	status, body = rest("POST", tprint("/api/v9/channels/%/invites", cid), "{\"max_age\": 1}", token);
	short, _ := etf.from_json(body);
	check(status == 200 && field(short, "expires_at").kind == .String, tprint("an invite with an expiry: % %", status, body));
	sleep_milliseconds(2100);
	expired := member_invite;
	expired.code = field(short, "code").s;
	_, ostatus, omessage = serve.member_login(expired, keys.generate("Late"), "Late");
	check(ostatus == 404, tprint("an expired invite is refused: % %", ostatus, omessage));
	status, body = rest("POST", tprint("/api/v9/guilds/%/channels", gid), "{\"name\": \"mine\"}", other_token);
	check(status == 403, tprint("only the owner makes channels: % %", status, body));

	// Mentions: Other's ID from a message of theirs, then the owner pings them and @everyone.
	status, body = rest("POST", messages, "{\"content\": \"hi all\"}", other_token);
	said, _ := etf.from_json(body);
	other_id := field(said, "author", "id").s;
	status, body = rest("POST", messages, tprint("{\"content\": \"<@%> and <@!1> and @everyone\"}", other_id), token);
	pinged, _ := etf.from_json(body);
	ms := field(pinged, "mentions");
	check(status == 200 && ms.kind == .List && ms.list.count == 1 && field(ms.list[0], "id").s == other_id && field(pinged, "mention_everyone").b,
		tprint("mentions: % %", status, body));
	cl3 := discord.client_create(.{token = other_token, hosted = .{host = "127.0.0.1", port = port, pin = pin, server_id = id}});
	discord.client_start(cl3);
	for 1..1000 { if cl3.store.ready break; discord.client_poll(cl3); sleep_milliseconds(10); }
	has_rs, rs := table_find(*cl3.store.read_states, cid);
	check(cl3.store.ready && has_rs && rs.mention_count == 1, tprint("the pinged member's mention count: % %", has_rs, rs.mention_count));
	discord.client_destroy(cl3);
	status, body = rest("POST", messages, "{\"content\": \"soon\"}", token);
	later, _ := etf.from_json(body);
	later_url := tprint("%/%", messages, field(later, "id").s);
	status, body = rest("PATCH", later_url, tprint("{\"content\": \"<@%> @everyone\"}", other_id), token);
	edited, _ := etf.from_json(body);
	check(status == 200 && field(edited, "mentions").list.count == 1 && field(edited, "mention_everyone").b, tprint("an edit adds mentions: % %", status, body));
	status, body = rest("PATCH", later_url, "{\"content\": \"nobody\"}", token);
	edited, _ = etf.from_json(body);
	check(status == 200 && field(edited, "mentions").list.count == 0 && !field(edited, "mention_everyone").b, tprint("an edit drops mentions: % %", status, body));
	rest("DELETE", later_url, "", token);
	pinged_id := field(pinged, "id").s;
	newest_mention :: (who: string) -> string, s64 #expand {
		status, body := rest("GET", "/api/v9/users/@me/mentions?limit=25&roles=true&everyone=true", "", who);
		v, _ := etf.from_json(body);
		if status != 200 || v.kind != .List { print("mentions: % %\n", status, body); return "", -1; }
		return ifx v.list.count then field(v.list[0], "id").s else "", v.list.count;
	}
	newest := newest_mention(other_token);
	check(newest == pinged_id, tprint("Recent Mentions lists the ping: % %", newest, pinged_id));
	newest = newest_mention(token);
	check(newest != pinged_id, "Recent Mentions skips your own messages");
	status, body = rest("DELETE", tprint("/api/v9/users/@me/mentions/%", pinged_id), "", other_token);
	newest = newest_mention(other_token);
	check(status == 204 && newest != pinged_id, tprint("a dismissed mention leaves Recent Mentions: % %", status, newest));

	// Search: the channel now holds "hello", the reply edited to "hi", Other's "hi all" and the ping.
	found :: (query: string) -> s64 #expand {
		status, body := rest("GET", tprint("/api/v9/guilds/%/messages/search?%&sort_by=timestamp&sort_order=desc", gid, query), "", token);
		v, _ := etf.from_json(body);
		if status != 200 { print("search %: % %\n", query, status, body); return -1; }
		return field(v, "total_results").i;
	}
	check(found("content=hello") == 1, "search content");
	check(found("content=hi") == 2, "search content edited, and words only");
	check(found(tprint("author_id=%", other_id)) == 1, "search author");
	check(found(tprint("mentions=%", other_id)) == 1, "search mentions");
	check(found(tprint("author_id=%&content=hi", other_id)) == 1, "search filters combine");
	check(found("content=%22unbalanced") == 0, "search quotes typed text");
	check(found("has=link") == 0, "search has");
	repeated: String_Builder;
	for 1..600 append(*repeated, "pinned=true&has=link&");
	append(*repeated, "content=hello");
	check(found(builder_to_string(*repeated,, temp)) == 0, "a search repeating its filters still runs, each filter once");

	// Threads: a member starts one, posts in it and renames it; one from a message takes its ID, once.
	status, body = rest("POST", tprint("/api/v9/channels/%/threads", channel), "{\"name\": \"Plans\", \"type\": 11, \"auto_archive_duration\": 4320}", other_token);
	thread, _ := etf.from_json(body);
	thread_id := field(thread, "id").s;
	check(status == 201 && field(thread, "type").i == 11 && field(thread, "parent_id").s == channel && field(thread, "member").kind == .Map,
		tprint("a member starts a thread: % %", status, body));
	status, body = rest("POST", tprint("/api/v9/channels/%/messages", thread_id), "{\"content\": \"in the thread\"}", other_token);
	check(status == 200, tprint("a message in a thread: % %", status, body));
	status, body = rest("PATCH", tprint("/api/v9/channels/%", thread_id), "{\"name\": \"Big Plans\"}", other_token);
	check(status == 200 && field(etf.from_json(body), "name").s == "Big Plans", tprint("the starter renames a thread: % %", status, body));
	status, body = rest("POST", tprint("/api/v9/channels/%/messages/%/threads", channel, pinged_id), "{\"name\": \"About that\"}", other_token);
	from_message, _ := etf.from_json(body);
	check(status == 201 && field(from_message, "id").s == pinged_id, tprint("a thread from a message: % %", status, body));
	status, body = rest("POST", tprint("/api/v9/channels/%/messages/%/threads", channel, pinged_id), "{\"name\": \"Again\"}", other_token);
	check(status == 400, tprint("one thread per message: % %", status, body));
	status, body = rest("GET", tprint("%?around=%&limit=1", messages, pinged_id), "", token);
	page, _ := etf.from_json(body);
	check(status == 200 && page.kind == .List && page.list.count == 1 && field(page.list[0], "thread", "id").s == pinged_id,
		tprint("the starter message carries its thread: % %", status, body));
	status, body = rest("GET", tprint("/api/v9/channels/%/threads/search?archived=true&limit=25", channel), "", other_token);
	check(status == 200, tprint("the thread browser's archived list: % %", status, body));
	status, body = rest("DELETE", tprint("/api/v9/channels/%", thread_id), "", other_token);
	check(status == 403, tprint("only the owner deletes threads: % %", status, body));
	status, body = rest("DELETE", tprint("/api/v9/channels/%", thread_id), "", token);
	check(status == 200, tprint("the owner deletes a thread: % %", status, body));
	status, body = rest("POST", tprint("/api/v9/channels/%/messages", thread_id), "{\"content\": \"gone\"}", other_token);
	check(status == 404, tprint("a deleted thread takes no messages: % %", status, body));

	// Leaving: the owner can't; Other's client loses the guild, their token dies, and only an invite
	// brings them back.
	status, body = rest("DELETE", tprint("/api/v9/users/@me/guilds/%", gid), "", token);
	check(status == 400, tprint("the owner can't leave: % %", status, body));
	cl3 = discord.client_create(.{token = other_token, hosted = .{host = "127.0.0.1", port = port, pin = pin, server_id = id}});
	discord.client_start(cl3);
	for 1..1000 { if cl3.store.ready break; discord.client_poll(cl3); sleep_milliseconds(10); }
	discord.leave_guild(cl3, gid);
	for 1..1000 { if !cl3.store.guild_order.count break; discord.client_poll(cl3); sleep_milliseconds(10); }
	check(cl3.store.ready && !cl3.store.guild_order.count, "leaving deletes the guild on the member's gateway");
	discord.client_destroy(cl3);
	status, body = rest("GET", messages, "", other_token);
	check(status == 401, tprint("a member who left loses their session: %", status));
	status, body = login(other, "", "Other");
	check(status == 404, tprint("a member who left needs an invite: % %", status, body));
	other_token, ostatus, omessage = serve.member_login(member_invite, other, "Other");
	status, body = rest("GET", messages, "", other_token);
	check(other_token.count == 64 && status == 200, tprint("rejoin by invite: % % %", ostatus, omessage, status));

	// Change Nickname renames the member everywhere, old messages included; an empty one is refused.
	status, body = rest("PATCH", tprint("/api/v9/guilds/%/members/@me", gid), "{\"nick\": \" \"}", other_token);
	check(status == 400, tprint("an empty nickname is refused: % %", status, body));
	cl4 := discord.client_create(.{token = other_token, hosted = .{host = "127.0.0.1", port = port, pin = pin, server_id = id}});
	discord.client_start(cl4);
	for 1..1000 { if cl4.store.ready break; discord.client_poll(cl4); sleep_milliseconds(10); }
	discord.set_server_nickname(cl4, gid, cl4.store.me, "Renamed");
	for 1..1000 {
		m := discord.member_get(*cl4.store, gid, cl4.store.me);
		if discord.user_name(*cl4.store, cl4.store.me) == "Renamed" && m && !m.nick break;
		discord.client_poll(cl4);
		sleep_milliseconds(10);
	}
	m := discord.member_get(*cl4.store, gid, cl4.store.me);
	check(discord.user_name(*cl4.store, cl4.store.me) == "Renamed" && m && !m.nick, "Change Nickname renames the member");
	discord.client_destroy(cl4);
	status, body = rest("GET", messages, "", token);
	check(status == 200 && contains(body, "\"Renamed\"") && !contains(body, "\"Other\""), tprint("old messages show the new name: %", body));

	// Server Settings: only the owner renames the server, and every member's guild follows.
	status, body = rest("PATCH", tprint("/api/v9/guilds/%", gid), "{\"name\": \"Taken Over\"}", other_token);
	check(status == 403, tprint("only the owner renames the server: % %", status, body));
	status, body = rest("PATCH", tprint("/api/v9/guilds/%", gid), "{\"name\": \" x \"}", token);
	check(status == 400, tprint("a one-letter server name is refused: % %", status, body));
	member_cl := discord.client_create(.{token = other_token, hosted = .{host = "127.0.0.1", port = port, pin = pin, server_id = id}});
	discord.client_start(member_cl);
	for 1..1000 { if member_cl.store.ready break; discord.client_poll(member_cl); sleep_milliseconds(10); }
	status, body = rest("PATCH", tprint("/api/v9/guilds/%", gid), "{\"name\": \" Hangout \"}", token);
	check(status == 200 && contains(body, "\"Hangout\""), tprint("the owner renames the server: % %", status, body));
	for 1..1000 {
		g := discord.guild_get(*member_cl.store, gid);
		if g && g.name == "Hangout" break;
		discord.client_poll(member_cl);
		sleep_milliseconds(10);
	}
	renamed := discord.guild_get(*member_cl.store, gid);
	check(renamed && renamed.name == "Hangout", "GUILD_UPDATE renames the server for members");
	discord.client_destroy(member_cl);

	// Server icon: the owner sets one as a data URI, it is served under its hash, and null removes it.
	PNG_1PX :: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==";
	status, body = rest("PATCH", tprint("/api/v9/guilds/%", gid), "{\"icon\": \"data:image/png;base64,bm90IGFuIGltYWdl\"}", token);
	check(status == 400, tprint("an icon that isn't an image is refused: % %", status, body));
	status, body = rest("PATCH", tprint("/api/v9/guilds/%", gid), tprint("{\"icon\": \"data:image/png;base64,%\"}", PNG_1PX), other_token);
	check(status == 403, tprint("only the owner sets the icon: % %", status, body));
	status, body = rest("PATCH", tprint("/api/v9/guilds/%", gid), tprint("{\"icon\": \"data:image/png;base64,%\"}", PNG_1PX), token);
	icon_v, _ := etf.from_json(body);
	icon_hash := field(icon_v, "icon").s;
	check(status == 200 && icon_hash.count == 32 && field(icon_v, "name").s == "Hangout", tprint("the owner sets the icon: % %", status, body));
	status, body = rest("GET", tprint("/icons/%/%.png?size=96", gid, icon_hash), "", "");
	check(status == 200 && begins_with(body, "\x89PNG"), tprint("the icon is served: %", status));
	status, body = rest("GET", tprint("/icons/%/0123.png", gid), "", "");
	check(status == 404, tprint("a wrong icon hash 404s: %", status));
	status, body = rest("PATCH", tprint("/api/v9/guilds/%", gid), "{\"icon\": null}", token);
	check(status == 200 && contains(body, "\"icon\":null"), tprint("null removes the icon: % %", status, body));

	// Custom emoji: the owner adds one, it is served, and members react with it as name:id.
	emoji_path := tprint("/api/v9/guilds/%/emojis", gid);
	status, body = rest("POST", emoji_path, tprint("{\"name\": \"blob\", \"image\": \"data:image/png;base64,%\"}", PNG_1PX), other_token);
	check(status == 403, tprint("only the owner adds emoji: % %", status, body));
	status, body = rest("POST", emoji_path, tprint("{\"name\": \"no way\", \"image\": \"data:image/png;base64,%\"}", PNG_1PX), token);
	check(status == 400, tprint("an emoji name has no spaces: % %", status, body));
	status, body = rest("POST", emoji_path, tprint("{\"name\": \"blob\", \"image\": \"data:image/png;base64,%\"}", PNG_1PX), token);
	emoji_v, _ := etf.from_json(body);
	emoji_id := field(emoji_v, "id").s;
	check(status == 201 && field(emoji_v, "name").s == "blob" && emoji_id != "", tprint("the owner adds an emoji: % %", status, body));
	status, body = rest("GET", tprint("/emojis/%.webp?size=48", emoji_id), "", "");
	check(status == 200 && begins_with(body, "\x89PNG"), tprint("the emoji is served: %", status));
	status, body = rest("POST", messages, "{\"content\": \"react here\"}", token);
	react_v, _ := etf.from_json(body);
	react_path := tprint("/api/v9/channels/%/messages/%/reactions", field(react_v, "channel_id").s, field(react_v, "id").s);
	status, body = rest("PUT", tprint("%/blob\%3A%/@me", react_path, emoji_id), "", other_token);
	check(status == 204, tprint("a member reacts with a custom emoji: % %", status, body));
	status, body = rest("PUT", tprint("%/blob\%3A1/@me", react_path), "", other_token);
	check(status == 400, tprint("an unknown custom emoji is refused: % %", status, body));
	status, body = rest("GET", tprint("%?limit=1", messages), "", other_token);
	check(contains(body, tprint("\"emoji\":{\"id\":\"%\",\"name\":\"blob\",\"animated\":false}", emoji_id)), tprint("the reaction names the custom emoji: %", body));

	// Avatars: a member sets one, their messages carry it, it's served under its hash, and null removes it.
	status, body = rest("PATCH", "/api/v9/users/@me", "{\"avatar\": \"data:image/png;base64,bm90IGFuIGltYWdl\"}", other_token);
	check(status == 400, tprint("an avatar that isn't an image is refused: % %", status, body));
	status, body = rest("PATCH", "/api/v9/users/@me", tprint("{\"avatar\": \"data:image/png;base64,%\"}", PNG_1PX), other_token);
	avatar_v, _ := etf.from_json(body);
	avatar_hash := field(avatar_v, "avatar").s;
	check(status == 200 && avatar_hash.count == 32 && field(avatar_v, "id").s == other_id,tprint("a member sets an avatar: % %", status, body));
	status, body = rest("GET", tprint("%?limit=100", messages), "", token);
	check(status == 200 && contains(body, tprint("\"avatar\":\"%\"", avatar_hash)), tprint("messages carry the avatar: %", body));
	status, body = rest("GET", tprint("/avatars/%/%.png?size=80", other_id, avatar_hash), "", "");
	check(status == 200 && begins_with(body, "\x89PNG"), tprint("the avatar is served: %", status));
	// Profiles: what the server knows, with the join time and this server as the mutual one.
	status, body = rest("GET", tprint("/api/v9/users/%/profile?type=popout&with_mutual_guilds=true&guild_id=%", other_id, gid), "", token);
	prof_v, _ := etf.from_json(body);
	check(status == 200 && field(prof_v, "user", "avatar").s == avatar_hash && field(prof_v, "guild_member", "joined_at").s != "" && contains(body, tprint("\"mutual_guilds\":[{\"id\":\"%\"", gid)),
		tprint("a member's profile: % %", status, body));
	status, body = rest("GET", tprint("/api/v9/users/%/relationships", other_id), "", token);
	check(status == 200 && body == "[]", tprint("no mutual friends: % %", status, body));
	status, body = rest("GET", "/api/v9/users/1/profile", "", token);
	check(status == 404, tprint("an unknown user's profile 404s: %", status));
	status, body = rest("PATCH", "/api/v9/users/@me", "{\"avatar\": null}", other_token);
	check(status == 200 && contains(body, "\"avatar\":null"), tprint("null removes the avatar: % %", status, body));
	status, body = rest("GET", tprint("/avatars/%/%.png", other_id, avatar_hash), "", "");
	check(status == 404, tprint("a removed avatar 404s: %", status));

	// Slowmode: the owner sets it in Channel Settings; a member's second message comes too soon, the owner's doesn't.
	status, body = rest("POST", tprint("/api/v9/guilds/%/channels", gid), "{\"name\": \"slow\", \"type\": 0}", token);
	slow_v, _ := etf.from_json(body);
	slow := field(slow_v, "id").s;
	slow_messages := tprint("/api/v9/channels/%/messages", slow);
	status, body = rest("PATCH", tprint("/api/v9/channels/%", slow), "{\"rate_limit_per_user\": 60, \"nsfw\": true}", other_token);
	check(status == 403, tprint("only the owner sets slowmode: % %", status, body));
	status, body = rest("PATCH", tprint("/api/v9/channels/%", slow), "{\"rate_limit_per_user\": 60, \"nsfw\": true}", token);
	check(status == 200 && contains(body, "\"rate_limit_per_user\":60") && contains(body, "\"nsfw\":true"), tprint("the owner sets slowmode: % %", status, body));
	status, body = rest("POST", slow_messages, "{\"content\": \"first\"}", other_token);
	check(status == 200, tprint("slowmode lets the first message through: % %", status, body));
	status, body = rest("POST", slow_messages, "{\"content\": \"second\"}", other_token);
	check(status == 429 && contains(body, "20016") && contains(body, "retry_after"), tprint("slowmode holds the second: % %", status, body));
	status, body = rest("POST", slow_messages, "{\"content\": \"owner\"}", token);
	status, body = rest("POST", slow_messages, "{\"content\": \"owner again\"}", token);
	check(status == 200, tprint("the owner isn't slowed: % %", status, body));
	// A resend with the same nonce, as after a lost reply, gets the first message back, even under slowmode.
	status, body = rest("POST", slow_messages, "{\"content\": \"once\", \"nonce\": \"1234567890\"}", token);
	first_v, _ := etf.from_json(body);
	status, body = rest("POST", slow_messages, "{\"content\": \"once\", \"nonce\": \"1234567890\"}", token);
	again_v, _ := etf.from_json(body);
	check(status == 200 && field(again_v, "id").s == field(first_v, "id").s && field(again_v, "nonce").s == "1234567890", tprint("a repeated nonce returns the first message: % %", status, body));
	status, body = rest("GET", tprint("%?limit=100", slow_messages), "", token);
	page_v, _ := etf.from_json(body);
	onces := 0;
	if page_v.kind == .List for page_v.list if field(it, "content").s == "once" onces += 1;
	check(onces == 1, tprint("a repeated nonce posts once: %", body));
	// Length counts UTF-16 units like Discord, so 1400 three-byte characters fit and 2001 ASCII ones don't.
	cjk, ascii: String_Builder;
	for 1..1400 append(*cjk, "漢");
	for 1..2001 append(*ascii, "a");
	status, body = rest("POST", slow_messages, tprint("{\"content\": \"%\"}", builder_to_string(*cjk)), token);
	check(status == 200, tprint("1400 CJK characters send: %", status));
	status, body = rest("POST", slow_messages, tprint("{\"content\": \"%\"}", builder_to_string(*ascii)), token);
	check(status == 400 && contains(body, "BASE_TYPE_MAX_LENGTH"), tprint("2001 characters don't: % %", status, body));
	// A clock that steps back an hour still gives out rising IDs, so new messages sort last.
	status, body = rest("POST", slow_messages, "{\"content\": \"before the step\"}", token);
	before_v, _ := etf.from_json(body);
	s.clock_offset_ms = -60 * 60 * 1000;
	status, body = rest("POST", slow_messages, "{\"content\": \"after the step\"}", token);
	s.clock_offset_ms = 0;
	after_v, _ := etf.from_json(body);
	before_id := string_to_int(field(before_v, "id").s, T = s64);
	after_id := string_to_int(field(after_v, "id").s, T = s64);
	check(status == 200 && before_id > 0 && after_id > before_id, tprint("IDs rise when the clock steps back: % % %", status, before_id, after_id));
	status, body = rest("DELETE", tprint("/api/v9/channels/%", slow), "", token);
	check(status == 200, tprint("delete the slow channel: % %", status, body));

	// Pages around and after a message, newest first like every page.
	ids :: (query: string) -> string #expand {
		status, body := rest("GET", tprint("%?%", messages, query), "", token);
		v, _ := etf.from_json(body);
		if status != 200 || v.kind != .List return tprint("% %", status, body);
		b: String_Builder;
		b.allocator = temp;
		for v.list print_to_builder(*b, "% ", field(it, "id").s);
		return builder_to_string(*b,, temp);
	}
	all := split(ids("limit=50"), " ",, temp);
	check(all.count >= 5, "enough messages to page");
	if all.count >= 5 {
		got := ids(tprint("around=%&limit=3", all[1]));
		check(got == tprint("% % % ", all[0], all[1], all[2]), tprint("around: %", got));
		got = ids(tprint("after=%&limit=2", all[3]));
		check(got == tprint("% % ", all[1], all[2]), tprint("after: %", got));
	}

	// Mark As Read (ack-bulk) is kept: a later session starts with the channel read.
	status, body = rest("POST", messages, "{\"content\": \"unread\"}", token);
	unread, _ := etf.from_json(body);
	unread_id := string_to_int(field(unread, "id").s, T = discord.Snowflake);
	cl5 := discord.client_create(.{token = other_token, hosted = .{host = "127.0.0.1", port = port, pin = pin, server_id = id}});
	discord.client_start(cl5);
	for 1..1000 { if cl5.store.ready break; discord.client_poll(cl5); sleep_milliseconds(10); }
	acked := discord.ack_guild(cl5, gid);
	// Notification settings, too: each change merges into what the server keeps.
	discord.set_guild_muted(cl5, gid, true);
	discord.set_channel_muted(cl5, gid, cid, true);
	discord.set_guild_notify_level(cl5, gid, discord.NOTIFY_MENTIONS);
	for 1..100 { discord.client_poll(cl5); sleep_milliseconds(10); }
	discord.client_destroy(cl5);
	cl5 = discord.client_create(.{token = other_token, hosted = .{host = "127.0.0.1", port = port, pin = pin, server_id = id}});
	discord.client_start(cl5);
	for 1..1000 { if cl5.store.ready break; discord.client_poll(cl5); sleep_milliseconds(10); }
	has_rs, rs = table_find(*cl5.store.read_states, cid);
	check(acked >= 1 && has_rs && rs.last_message_id == unread_id, tprint("Mark As Read is kept: % % %", acked, has_rs, rs.last_message_id));
	kept := table_find_pointer(*cl5.store.guild_settings, gid);
	check(kept && kept.muted && kept.message_notifications == discord.NOTIFY_MENTIONS && array_find(kept.muted_channels, cid),
		tprint("notification settings are kept: %", ifx kept then kept.* else .{}));
	discord.client_destroy(cl5);

	// Two connections at once: each takes only the new messages that came on it, so the app checks a
	// message against the store it belongs to.
	{
		ca := discord.client_create(.{token = token, hosted = .{host = "127.0.0.1", port = port, pin = pin, server_id = id}});
		cb := discord.client_create(.{token = other_token, hosted = .{host = "127.0.0.1", port = port, pin = pin, server_id = id}});
		discord.client_start(ca);
		discord.client_start(cb);
		for 1..1000 { if ca.store.ready && cb.store.ready break; discord.client_poll(ca); discord.client_poll(cb); sleep_milliseconds(10); }
		discord.take_new_messages(ca);
		discord.take_new_messages(cb);
		rest("POST", messages, "{\"content\": \"for b\"}", token);
		got_b: []discord.New_Message;
		for 1..300 {
			discord.client_poll(ca);
			discord.client_poll(cb);
			got_a := discord.take_new_messages(ca);
			check(got_a.count == 0, "a connection takes no other connection's messages");
			got_b = discord.take_new_messages(cb);
			if got_b.count break;
			sleep_milliseconds(10);
		}
		check(got_b.count == 1 && got_b[0].store == *cb.store && got_b[0].content == "for b", tprint("the message reaches its own connection: %", got_b.count));
		discord.client_destroy(ca);
		discord.client_destroy(cb);
	}

	// The owner deletes anyone's message; a member deletes only their own.
	status, body = rest("POST", messages, "{\"content\": \"spam\"}", other_token);
	spam, _ := etf.from_json(body);
	status, body = rest("DELETE", tprint("%/%", messages, field(said, "id").s), "", token);
	check(status == 204, tprint("the owner deletes a member's message: % %", status, body));
	status, body = rest("DELETE", tprint("%/%", messages, field(pinged, "id").s), "", other_token);
	check(status == 403, tprint("a member can't delete the owner's message: % %", status, body));
	status, body = rest("DELETE", tprint("%/%", messages, field(spam, "id").s), "", other_token);
	check(status == 204, tprint("a member deletes their own message: % %", status, body));

	// The owner kicks and bans: either ends the member's sessions; an invite brings a kicked member back,
	// but not a banned one until the ban is lifted. Members can't moderate.
	{
		members := tprint("/api/v9/guilds/%/members/%", gid, other_id);
		bans := tprint("/api/v9/guilds/%/bans/%", gid, other_id);
		status, body = rest("DELETE", tprint("/api/v9/guilds/%/members/%", gid, field(said, "author", "id").s), "", other_token);
		check(status == 403, tprint("a member can't kick: % %", status, body));
		status, body = rest("DELETE", members, "", token);
		check(status == 204, tprint("the owner kicks: % %", status, body));
		status, body = rest("GET", tprint("%?limit=1", messages), "", other_token);
		check(status == 401, tprint("a kick ends the member's session: % %", status, body));
		status, body = rest("DELETE", members, "", token);
		check(status == 404, tprint("a kicked member can't be kicked again: % %", status, body));
		other_token, ostatus, omessage = serve.member_login(member_invite, other, "Other");
		check(ostatus == 200, tprint("an invite brings a kicked member back: % %", ostatus, omessage));
		status, body = rest("PUT", bans, "{}", token);
		check(status == 204, tprint("the owner bans: % %", status, body));
		status, body = rest("GET", tprint("%?limit=1", messages), "", other_token);
		check(status == 401, tprint("a ban ends the member's session: % %", status, body));
		_, ostatus, omessage = serve.member_login(member_invite, other, "Other");
		check(ostatus == 403, tprint("a banned member's key can't rejoin: % %", ostatus, omessage));
		status, body = rest("DELETE", bans, "", token);
		check(status == 204, tprint("the owner lifts the ban: % %", status, body));
		other_token, ostatus, omessage = serve.member_login(member_invite, other, "Other");
		check(ostatus == 200, tprint("an invite works again once the ban is lifted: % %", ostatus, omessage));
	}

	// The owner lists working invites and revokes one; a member can't do either to someone else's.
	{
		status, body = rest("GET", tprint("/api/v9/guilds/%/invites", gid), "", other_token);
		check(status == 403, tprint("a member can't list invites: % %", status, body));
		status, body = rest("GET", tprint("/api/v9/guilds/%/invites", gid), "", token);
		check(status == 200 && contains(body, made.code), tprint("the owner lists invites: % %", status, body));
		status, body = rest("DELETE", tprint("/api/v9/invites/%", made.code), "", other_token);
		check(status == 403, tprint("a member can't revoke another's invite: % %", status, body));
		status, body = rest("DELETE", tprint("/api/v9/invites/%", made.code), "", token);
		check(status == 200, tprint("the owner revokes an invite: % %", status, body));
		_, ostatus, omessage = serve.member_login(member_invite, keys.generate("Latecomer"), "Latecomer");
		check(ostatus == 404, tprint("a revoked invite lets nobody in: % %", ostatus, omessage));
		status, body = rest("GET", tprint("/api/v9/guilds/%/invites", gid), "", token);
		check(status == 200 && !contains(body, made.code), tprint("a revoked invite isn't listed: % %", status, body));
	}

	// A member keeps only their newest sessions: logging in that many times more ends the first one.
	{
		status, body = rest("GET", tprint("%?limit=1", messages), "", token);
		check(status == 200, tprint("the first session works: % %", status, body));
		for 1..16 serve.member_login(inv, k, ""); // MAX_SESSIONS
		status, body = rest("GET", tprint("%?limit=1", messages), "", token);
		check(status == 401, tprint("the oldest session ends past the cap: % %", status, body));
	}

	// A hosted client sends its server only its own token and the body's type, whatever URL it fetches:
	// every request reaches the pinned server, and no cookie goes out, even one its jar holds for discord.com.
	{
		fake, lerr := netio.listen_tcp(0);
		check(lerr == .None, "fake server listens");
		hc := discord.client_create(.{token = "hosted-token", disable_gateway = true, hosted = .{host = "127.0.0.1", port = fake.port, pin = pin, server_id = id}});
		discord.cookie_set_from_header(*hc.jar, "discord.com", "/", "__dcfduid=SECRET; Path=/; Domain=discord.com", discord.now_ms());
		discord.client_start(hc);
		for url: string.["https://discord.com/api/v9/users/@me", "https://cdn.discordapp.com/attachments/1/2/a.png", "a message page"] {
			if it_index < 2 discord.fetch_media(hc, .{url = url, kind = .Fetch});
			else discord.fetch_messages(hc, 1);
			t, aerr := netio.accept_tcp(fake);
			if aerr != .None { check(false, "fake server accepts"); break; }
			session, _, _ := tls.accept(netio.tcp_stream(t), s.ctx);
			if !session { check(false, "fake server handshakes"); netio.close(netio.tcp_stream(t)); break; }
			h: http.H1_Conn;
			http.h1_init(*h, tls.stream(session));
			req, rerr := http.h1_read_request(*h);
			clean := rerr == .None;
			for req.headers {
				if equal_nocase(it.name, "authorization") { if it.value != "hosted-token" clean = false; }
				else if equal_nocase(it.name, "cookie") || contains(it.value, "SECRET") clean = false;
			}
			check(clean, tprint("a hosted fetch of % carries only the hosted token: % %", url, rerr, req.headers));
			http.h1_write_response(tls.stream(session), 404, .[.{"connection", "close"}], .[]);
			http.request_destroy(*req);
			http.h1_destroy(*h);
		}
		discord.client_destroy(hc);
		netio.close_listener(fake);
	}

	// One address holds at most 16 connections: past that, the server hangs up at once.
	held: [..]netio.Stream;
	refused := false;
	for 1..20 {
		t, derr := netio.dial_tcp("127.0.0.1", port);
		if derr != .None break;
		st := netio.tcp_stream(t);
		array_add(*held, st);
		netio.set_timeout(st, 300);
		b: [1]u8;
		_, rerr := netio.read(st, b);
		if rerr != .Timeout { refused = true; break; }
	}
	check(refused && held.count > 1 && held.count <= 17, tprint("connections per address are capped: %", held.count));
	for held netio.close(it);

	serve.stop(s);
	print("% failed\n", failed);
	exit(xx ifx failed then 1 else 0);
}
