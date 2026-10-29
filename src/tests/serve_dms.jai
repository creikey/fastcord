// DMs on a self-hosted server: jai build.jai - run src/tests/serve_dms.jai, then build/serve_dms. Serve
// carries only `fc-` packets between two members: it refuses plaintext, shows a DM to no one else, keeps
// messages for a member who is offline, and the real client gets them through READY and the gateway.
// Writes only under build/serve_dms_test.
#import "Basic";
#import "File";
#import "File_Utilities";
#import "String";
#import "Hash_Table";
discord :: #import "discord";
etf :: #import "etf";
fc_text :: #import "fc_text";
http :: #import "http";
keys :: #import "keys";
netio :: #import "netio";
serve :: #import "serve";
tls :: #import "tls";
#if OS == .WINDOWS msvcprt :: #library,system,no_dll,link_always "msvcprt";

DIR :: "build/serve_dms_test";

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
	port := s.listener.port;
	hosted := discord.Hosted.{host = "127.0.0.1", port = port, pin = s.pin, server_id = serve.id_hex(s,, context.default_allocator)};
	login_with :: (code: string, k: keys.Keypair, name: string) -> string #expand {
		inv, _ := serve.parse_invite(serve.invite_url(`s, "127.0.0.1", `port, code));
		return serve.member_login(inv, k, name);
	}
	login :: (code: string, name: string) -> string #expand { return login_with(code, keys.generate(name), name); }
	a_token := login(serve.owner_invite(s), "Alice");
	b_key := keys.generate("Bob");
	b_root := b_key.root;
	b_token := login_with(serve.first_invite(s), b_key, "Bob");
	c_token := login(serve.first_invite(s), "Carol");
	check(a_token != "" && b_token != "" && c_token != "", "three join");

	session := tls.connect(netio.tcp_stream(netio.dial_tcp("127.0.0.1", port)), .{alpn = .[serve.ALPN], server_name = hosted.server_id, pin = hosted.pin});
	h: http.H1_Conn;
	http.h1_init(*h, tls.stream(session));
	rest :: (method: string, path: string, body: string, token: string) -> int, string #expand {
		headers: [..]http.Header;
		headers.allocator = temp;
		if token array_add(*headers, .{"authorization", token});
		if body array_add(*headers, .{"Content-Type", "application/json"}, .{"Content-Length", tprint("%", body.count)});
		resp := http.h1_round_trip(*`h, .{method = method, path = path, authority = `hosted.server_id, body = cast([]u8) body, headers = headers});
		return resp.status, copy_string(cast(string) resp.body,, temp);
	}
	id_of :: (body: string) -> string {
		v := etf.from_json(body,, temp);
		return ifx v.kind == .Map then etf.map_get(v.map, "id").s else "";
	}
	pump :: (c: *discord.Client) #expand { discord.client_poll(c); sleep_milliseconds(10); }
	connect :: (token: string) -> *discord.Client #expand {
		c := discord.client_create(.{token = token, hosted = `hosted});
		discord.client_start(c);
		for 1..1000 { if c.store.ready break; pump(c); }
		return c;
	}

	// Bob was online once, then went offline; Alice's client is up.
	b := connect(b_token);
	bob := b.store.me;
	discord.client_destroy(b);
	a := connect(a_token);
	check(a.store.ready && bob != 0, "READY");
	if failed { serve.stop(s); exit(1); }

	status, body := rest("POST", "/api/v9/users/@me/channels", "{\"recipients\": [\"1\", \"2\"]}", a_token);
	check(status == 400, tprint("one recipient only: %", status));
	status, body = rest("POST", "/api/v9/users/@me/channels", tprint("{\"recipients\": [\"%\"]}", a.store.me), a_token);
	check(status == 400, tprint("not yourself: %", status));
	status, body = rest("POST", "/api/v9/users/@me/channels", "{\"recipients\": [\"12345\"]}", a_token);
	check(status == 400, tprint("only a member: %", status));

	// The real client opens it, as the profile's Message button does.
	existing := discord.open_dm(a, bob, "User Profile");
	check(existing == 0, "no DM yet");
	dm: discord.Snowflake;
	for 1..300 {
		for discord.client_take_results(a) if it.op == .Open_Dm && it.ok dm = it.id;
		if dm break;
		pump(a);
	}
	check(dm != 0, "the client opens a DM");
	ch := discord.channel_get(*a.store, dm);
	check(ch && ch.kind == .DM && ch.recipient_ids.count == 1 && ch.recipient_ids[0] == bob && !ch.guild_id, "it's a DM with Bob, in no guild");
	status, body = rest("POST", "/api/v9/users/@me/channels", tprint("{\"recipients\": [\"%\"]}", bob), a_token);
	check(status == 200 && id_of(body) == tprint("%", dm), "opening it again gives the same DM");
	messages := tprint("/api/v9/channels/%/messages", dm);

	// Only packets: plaintext, files never uploaded and replies are refused.
	status, body = rest("POST", messages, "{\"content\": \"hello in the clear\"}", a_token);
	check(status == 400, tprint("plaintext refused: %", status));
	status, body = rest("POST", messages, "{\"content\": \"fc-AA+A\"}", a_token);
	check(status == 400, tprint("a malformed packet refused: %", status));
	packet := fc_text.encode(cast([]u8) "\x04\x03 an opaque packet");
	status, body = rest("POST", messages, tprint("{\"content\": \"%\", \"attachments\": [{\"id\": \"0\", \"filename\": \"x\"}]}", packet), a_token);
	check(status == 400, tprint("a file never uploaded is refused: %", status));
	status, body = rest("POST", messages, tprint("{\"content\": \"%\", \"nonce\": \"77\"}", packet), a_token);
	check(status == 200 && contains(body, packet) && !contains(body, "guild_id"), tprint("a packet is relayed: % %", status, body));
	first := id_of(body);
	status, body = rest("POST", messages, tprint("{\"content\": \"%\", \"nonce\": \"77\"}", packet), a_token);
	check(status == 200 && id_of(body) == first, "a resend with the same nonce isn't posted twice");
	for 1..300 {
		found, l := table_find(*a.store.messages, dm);
		if found && l.messages.count break;
		pump(a);
	}
	found, l := table_find(*a.store.messages, dm);
	check(found && l.messages.count == 1 && l.messages[0].content == packet, "MESSAGE_CREATE reaches the sender's client");

	// No one else sees it.
	status, body = rest("GET", messages, "", c_token);
	check(status == 404 || status == 403, tprint("Carol can't read it: %", status));
	status, body = rest("POST", messages, tprint("{\"content\": \"%\"}", packet), c_token);
	check(status == 404 || status == 403, tprint("or post in it: %", status));
	status, body = rest("POST", tprint("/api/v9/channels/%/messages/%/ack", dm, first), "{}", c_token);
	check(status == 404 || status == 403, tprint("or ack it: %", status));
	status, body = rest("GET", tprint("/api/v9/guilds/%/messages/search?content=opaque", s.guild), "", a_token);
	check(!contains(body, first), "guild search never finds DMs");

	// Bob comes online later: the DM, its unread count and the message waited for him.
	b = connect(b_token);
	bch := discord.channel_get(*b.store, dm);
	check(b.store.ready && bch && array_find(b.store.private_channels, dm), "READY lists the DM for Bob");
	rs := table_find_pointer(*b.store.read_states, dm);
	check(rs && rs.mention_count == 1, "with the message unread");
	status, body = rest("GET", messages, "", b_token);
	check(status == 200 && contains(body, packet) && contains(body, "\"global_name\":\"Alice\""), tprint("and the page has it: % %", status, body));
	status, body = rest("POST", tprint("/api/v9/channels/%/messages/%/ack", dm, first), "{}", b_token);
	check(status == 200, tprint("Bob acks it: %", status));

	// Typing goes to the peer only.
	status, body = rest("POST", tprint("/api/v9/channels/%/typing", dm), "", b_token);
	check(status == 204, tprint("typing: %", status));

	// Bob answers; Alice's client gets it live.
	reply := fc_text.encode(cast([]u8) "\x04\x03 the answer");
	status, body = rest("POST", messages, tprint("{\"content\": \"%\"}", reply), b_token);
	check(status == 200, tprint("Bob answers: %", status));
	answer := id_of(body);
	for 1..300 {
		found, l = table_find(*a.store.messages, dm);
		if found && l.messages.count == 2 break;
		pump(a); pump(b);
	}
	found, l = table_find(*a.store.messages, dm);
	check(found && l.messages.count == 2 && l.messages[1].content == reply, "Alice gets the answer");

	// Files are ciphertext uploaded to the DM, kept as encrypted.bin whatever the client called them.
	status, body = rest("POST", tprint("/api/v9/channels/%/attachments", dm), "{\"files\": [{\"id\": \"0\", \"filename\": \"cat.png\", \"file_size\": 20}]}", a_token);
	up := etf.from_json(body,, temp);
	token := "";
	if status == 200 && up.kind == .Map {
		list := etf.map_get(up.map, "attachments");
		if list.kind == .List && list.list.count == 1 token = etf.map_get(list.list[0].map, "upload_filename").s;
	}
	check(token != "", tprint("an upload to the DM: % %", status, body));
	status, body = rest("PUT", tprint("/upload/%", token), "twenty opaque bytes!", "");
	check(status == 200, tprint("its bytes: % %", status, body));
	status, body = rest("POST", messages, tprint("{\"content\": \"%\", \"attachments\": [{\"id\": \"0\", \"filename\": \"cat.png\", \"uploaded_filename\": \"%\"}]}", packet, token), a_token);
	check(status == 200 && contains(body, "encrypted.bin") && contains(body, "application/octet-stream") && !contains(body, "cat.png"), tprint("a packet with its file: % %", status, body));
	with_file := id_of(body);
	status, body = rest("POST", messages, tprint("{\"content\": \"%\", \"attachments\": [{\"id\": \"0\", \"filename\": \"cat.png\", \"uploaded_filename\": \"%\"}]}", packet, token), a_token);
	check(status == 400, tprint("an upload is used once: %", status));

	// An edit replaces the author's packet with another; nothing else of the message changes.
	edited := fc_text.encode(cast([]u8) "\x04\x03 edited packet");
	status, body = rest("PATCH", tprint("%/%", messages, with_file), "{\"content\": \"edited in the clear\"}", a_token);
	check(status == 400, tprint("an edit to plaintext is refused: %", status));
	status, body = rest("PATCH", tprint("%/%", messages, with_file), tprint("{\"content\": \"%\"}", edited), a_token);
	check(status == 200 && contains(body, edited) && contains(body, "encrypted.bin") && !contains(body, "\"edited_timestamp\":null"), tprint("an edit: % %", status, body));
	status, body = rest("DELETE", tprint("%/%", messages, with_file), "", a_token);
	check(status == 204, tprint("deleting it takes its file: %", status));

	// Editing and deleting: only your own.
	status, body = rest("PATCH", tprint("%/%", messages, answer), tprint("{\"content\": \"%\"}", edited), a_token);
	check(status == 404, tprint("no editing someone else's: %", status));
	status, body = rest("DELETE", tprint("%/%", messages, answer), "", a_token);
	check(status == 404, tprint("not someone else's: %", status));
	status, body = rest("DELETE", tprint("%/%", messages, answer), "", b_token);
	check(status == 204, tprint("your own: %", status));

	// Closing hides it from READY until the next message.
	status, body = rest("DELETE", tprint("/api/v9/channels/%", dm), "", b_token);
	check(status == 200, tprint("Bob closes it: %", status));
	discord.client_destroy(b);
	b = connect(b_token);
	check(b.store.ready && !array_find(b.store.private_channels, dm), "a closed DM stays out of READY");
	status, body = rest("POST", messages, tprint("{\"content\": \"%\"}", fc_text.encode(cast([]u8) "\x04\x03 again")), a_token);
	for 1..300 { if array_find(b.store.private_channels, dm) break; pump(b); }
	check(array_find(b.store.private_channels, dm), "a new message reopens it with CHANNEL_CREATE");

	// Prekey bundles: a Hello of the member's own key only, which other members fetch.
	status, body = rest("GET", tprint("/api/v9/users/%/e2e-bundle", bob), "", a_token);
	check(status == 404, tprint("no bundle yet: %", status));
	bob_key := keys.generate("Bob's other key");
	fake: [34]u8;
	fake[0], fake[1] = 4, 1;
	memcpy(fake.data + 2, bob_key.root.data, 32);
	status, body = rest("PUT", "/api/v9/users/@me/e2e-bundle", tprint("{\"bundle\": \"%\"}", fc_text.encode(fake)), b_token);
	check(status == 400, tprint("a Hello of another key is refused: %", status));
	status, body = rest("PUT", "/api/v9/users/@me/e2e-bundle", "{\"bundle\": \"hello\"}", b_token);
	check(status == 400, tprint("so is anything but a packet: %", status));
	memcpy(fake.data + 2, b_root.data, 32);
	bundle := fc_text.encode(fake);
	status, body = rest("PUT", "/api/v9/users/@me/e2e-bundle", tprint("{\"bundle\": \"%\"}", bundle), b_token);
	check(status == 204, tprint("Bob publishes his: %", status));
	status, body = rest("GET", tprint("/api/v9/users/%/e2e-bundle", bob), "", a_token);
	check(status == 200 && contains(body, bundle), tprint("Alice fetches it: % %", status, body));

	discord.client_destroy(a);
	discord.client_destroy(b);
	http.h1_destroy(*h, true);
	serve.stop(s);
	if failed { print("serve_dms: % failed\n", failed); exit(1); }
	print("serve_dms: ok\n");
}
