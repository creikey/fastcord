// DMs on a self-hosted server: jai build.jai - run src/tests/serve_dms.jai, then build/serve_dms. Serve
// carries only `fc-` packets between members: it refuses plaintext, shows a DM to no one else, keeps
// messages for a member who is offline, and the real client gets them through READY and the gateway.
// Group DMs run end to end: four members with real keys answer each other's bundles and talk under
// sender keys through serve, one joining later and one removed.
// Writes only under build/serve_dms_test.
#import "Basic";
#import "File";
#import "File_Utilities";
#import "String";
#import "Hash_Table";
discord :: #import "discord";
e2e :: #import "e2e";
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

	// ---- Group DMs, end to end (E2E 8): real identities and e2e databases, serve as their only carrier ----
	// Each member publishes a bundle; pairwise sessions start by answering one, in the group; then each
	// sends under a sender key of their own, given to the others inside those sessions.
	Member :: struct { name, token, id: string; key: keys.Keypair; d: *e2e.Db; me: e2e.Identity; after: string; }
	CARRIER :: "fc:test";
	wait :: (j: *e2e.Job) { while !e2e.is_done(j) sleep_milliseconds(1); }
	user_id :: (token: string) -> string #expand {
		c := connect(token);
		id := tprint("%", c.store.me);
		discord.client_destroy(c);
		return id;
	}
	g_join :: (name: string) -> Member #expand {
		m: Member;
		m.name, m.key = name, keys.generate(name);
		m.token = login_with(serve.first_invite(`s), m.key, name);
		m.id = user_id(m.token);
		m.d = e2e.start(":memory:");
		m.me = e2e.identity_of(m.key);
		r := e2e.request(.Bundle, .{carrier = CARRIER, me = m.id, limit = e2e.MAX_PACKET});
		r.me = m.me;
		e2e.submit(m.d, r);
		wait(r);
		st, _ := rest("PUT", "/api/v9/users/@me/e2e-bundle", tprint("{\"bundle\": \"%\"}", fc_text.encode(xx r.packet)), m.token);
		check(r.result == .Ok && st == 204, tprint("% publishes a bundle: %", name, st));
		e2e.free_request(r);
		return m;
	}
	g_post :: (m: *Member, group: string, packet: string) -> int #expand {
		st, _ := rest("POST", tprint("/api/v9/channels/%/messages", group), tprint("{\"content\": \"%\"}", fc_text.encode(xx packet)), m.token);
		return st;
	}
	// answer: m starts a session with peer by answering peer's bundle, the Init going to the group.
	g_answer :: (m: *Member, peer: *Member, group: string) #expand {
		st, got := rest("GET", tprint("/api/v9/users/%/e2e-bundle", peer.id), "", m.token);
		v := etf.from_json(got,, temp);
		bundle, ok := fc_text.decode(ifx v.kind == .Map then etf.map_get(v.map, "bundle").s else "", fc_text.MAX_BUNDLE);
		r := e2e.request(.Accept, .{CARRIER, group, m.id, peer.id, fc_text.MAX_PACKET}, packet = xx bundle);
		r.me = m.me;
		e2e.submit(m.d, r);
		wait(r);
		check(st == 200 && ok && r.result == .Ok && g_post(m, group, r.packet) == 200, tprint("% answers %'s bundle in the group", m.name, peer.name));
		e2e.free_request(r);
	}
	g_send :: (m: *Member, group: string, text: string, members: ..*Member) -> packets: int #expand {
		r := e2e.request(.Send, .{CARRIER, group, m.id, "", fc_text.MAX_PACKET}, text);
		r.me = m.me;
		for members array_add(*r.members, copy_string(it.id));
		e2e.submit(m.d, r);
		wait(r);
		n := r.packets.count;
		ok := r.result == .Ok;
		for r.packets ok = ok && g_post(m, group, it) == 200;
		check(ok, tprint("% sends \"%\" (%)", m.name, text, r.result));
		e2e.free_request(r);
		return n;
	}
	// read: what m opens of the group's messages since last time, as "author: text" lines (No_Session
	// for a message m can't open yet); pairwise packets for others and gifts aren't listed.
	g_read :: (m: *Member, group: string) -> string #expand {
		st, got := rest("GET", tprint("/api/v9/channels/%/messages?limit=100%", group, ifx m.after then tprint("&after=%", m.after) else ""), "", m.token);
		out: String_Builder;
		out.allocator = temp;
		if st != 200 { print_to_builder(*out, "HTTP %", st); return builder_to_string(*out,, temp); }
		list := etf.from_json(got,, temp);
		if list.kind != .List return "";
		for < list.list {
			id := etf.map_get(it.map, "id").s;
			author := etf.map_get(etf.map_get(it.map, "author").map, "id").s;
			packet, ok := fc_text.decode(etf.map_get(it.map, "content").s);
			m.after = copy_string(id);
			if !ok continue;
			r := e2e.request(.Receive, .{CARRIER, group, m.id, author, fc_text.MAX_PACKET}, packet = xx packet);
			r.me, r.from, r.delivery = m.me, copy_string(author), copy_string(id);
			e2e.submit(m.d, r);
			wait(r);
			name := author;
			for `everyone if it.id == author name = it.name;
			if r.result == .Ok && (r.content == .Text || r.content == .Post) print_to_builder(*out, "%: %\n", name, r.out_text);
			else if r.result == .No_Session && packet[1] == 4 print_to_builder(*out, "%: No_Session\n", name);
			e2e.free_request(r);
		}
		return builder_to_string(*out,, temp);
	}
	ann := g_join("Ann");
	ben := g_join("Ben");
	cy := g_join("Cy");
	dee := g_join("Dee");
	everyone := (*Member).[*ann, *ben, *cy, *dee];

	ids :: (members: ..*Member) -> string {
		out: [..]string;
		out.allocator = temp;
		for members array_add(*out, tprint("\"%\"", it.id));
		return join(..out, separator = ", ",, temp);
	}
	status, body = rest("POST", "/api/v9/users/@me/channels", tprint("{\"recipients\": [%, %]}", ids(*ben), ids(*ben)), ann.token);
	check(status == 400, tprint("no one twice: %", status));
	ten: [10]string;
	for * ten it.* = tprint("\"%\"", 1000 + it_index);
	status, body = rest("POST", "/api/v9/users/@me/channels", tprint("{\"recipients\": [%]}", join(..ten, separator = ", ",, temp)), ann.token);
	check(status == 400, tprint("at most ten in a group: %", status));
	status, body = rest("POST", "/api/v9/users/@me/channels", tprint("{\"recipients\": [%]}", ids(*ben, *cy)), ann.token);
	v := etf.from_json(body,, temp);
	group := id_of(body);
	check(status == 200 && v.kind == .Map && etf.map_get(v.map, "type").i == 3 && etf.map_get(v.map, "owner_id").s == ann.id && etf.map_get(v.map, "recipients").list.count == 2,
		tprint("Ann makes a group DM with Ben and Cy: % %", status, body));
	gb := connect(ben.token);
	gch := discord.channel_get(*gb.store, discord.parse_snowflake(group));
	check(gch && gch.kind == .Group_DM && gch.recipient_ids.count == 2 && tprint("%", gch.owner_id) == ann.id, "READY lists it for Ben as a group of three, Ann's");

	// Only packets, and only its members.
	status, body = rest("POST", tprint("/api/v9/channels/%/messages", group), "{\"content\": \"hi all in the clear\"}", ann.token);
	check(status == 400, tprint("no plaintext in a group: %", status));
	status, body = rest("GET", tprint("/api/v9/channels/%/messages", group), "", dee.token);
	check(status == 404 || status == 403, tprint("Dee isn't in it: %", status));

	// Sessions: Ann answers Ben's and Cy's bundles, Ben answers Cy's.
	g_answer(*ann, *ben, group);
	g_answer(*ann, *cy, group);
	g_answer(*ben, *cy, group);
	for everyone if it.name != "Dee" g_read(it, group);
	check(g_send(*ann, group, "hello group", *ben, *cy) == 3, "Ann's first send gives her chain to both, then the message");
	check(g_read(*ben, group) == "Ann: hello group\n", "Ben reads it");
	check(g_read(*cy, group) == "Ann: hello group\n", "and Cy");
	g_send(*ben, group, "from ben", *ann, *cy);
	g_send(*cy, group, "from cy", *ann, *ben);
	check(g_read(*ann, group) == "Ann: hello group\nBen: from ben\nCy: from cy\n", "Ann reads everyone's");
	check(g_read(*ben, group) == "Ben: from ben\nCy: from cy\n", "so does Ben");
	g_read(*cy, group);

	// Dee joins later: Ben's client hears of it. She gets nothing from before her session, nor from Ben,
	// whose new chain (the members changed) she has no session for, until she answers his bundle.
	status, body = rest("PUT", tprint("/api/v9/channels/%/recipients/%", group, dee.id), "", ben.token);
	check(status == 204, tprint("any member adds another: %", status));
	for 1..300 { if gch.recipient_ids.count == 3 break; pump(gb); gch = discord.channel_get(*gb.store, discord.parse_snowflake(group)); }
	check(gch && gch.recipient_ids.count == 3, "CHANNEL_RECIPIENT_ADD reaches Ben's client");
	check(!contains(g_read(*dee, group), "hello group"), "Dee can't read what came before her");
	g_answer(*ann, *dee, group);
	g_read(*dee, group);
	check(g_send(*ann, group, "welcome dee", *ben, *cy, *dee) == 4, "a member joining rotates Ann's chain, given to all three");
	g_send(*ben, group, "ben to four", *ann, *cy, *dee);
	got := g_read(*dee, group);
	check(got == "Ann: welcome dee\nBen: No_Session\n", tprint("Dee reads Ann's, not yet Ben's: %", got));
	g_answer(*dee, *ben, group);
	g_read(*ben, group);
	check(g_send(*ben, group, "now dee too", *ann, *cy, *dee) == 4, "a new session rotates Ben's chain");
	check(g_read(*dee, group) == "Ben: now dee too\n", "and Dee reads Ben from then on");
	g_read(*ann, group); g_read(*cy, group);

	// Cy is removed, by the owner only: she can't fetch the group, and Ann's next chain isn't hers.
	status, body = rest("DELETE", tprint("/api/v9/channels/%/recipients/%", group, cy.id), "", ben.token);
	check(status == 403, tprint("only the owner removes: %", status));
	status, body = rest("DELETE", tprint("/api/v9/channels/%/recipients/%", group, cy.id), "", ann.token);
	check(status == 204, tprint("Ann removes Cy: %", status));
	for 1..300 { if gch.recipient_ids.count == 2 break; pump(gb); gch = discord.channel_get(*gb.store, discord.parse_snowflake(group)); }
	check(gch && gch.recipient_ids.count == 2, "CHANNEL_RECIPIENT_REMOVE reaches Ben's client");
	status, body = rest("GET", tprint("/api/v9/channels/%/messages", group), "", cy.token);
	check(status == 404 || status == 403, tprint("Cy can't fetch it any more: %", status));
	cy_after := ann.after;
	check(g_send(*ann, group, "without cy", *ben, *dee) == 3, "a member leaving rotates the chain");
	check(contains(g_read(*ben, group), "Ann: without cy\n"), "Ben reads on");
	// Even handed every packet (a server that kept serving her), Cy opens nothing.
	cy.token = ann.token; // read as Ann's fetch, opened with Cy's keys
	cy.after = cy_after;
	check(!contains(g_read(*cy, group), "without cy"), "the one removed reads nothing after");

	// Name, owner and leaving.
	status, body = rest("PATCH", tprint("/api/v9/channels/%", group), "{\"name\": \"the plan\"}", ben.token);
	check(status == 200 && contains(body, "\"name\":\"the plan\""), tprint("a member renames it: % %", status, body));
	status, body = rest("PATCH", tprint("/api/v9/channels/%", group), tprint("{\"owner\": \"%\"}", ben.id), ben.token);
	check(status == 403, tprint("only the owner hands it on: %", status));
	status, body = rest("PATCH", tprint("/api/v9/channels/%", group), tprint("{\"owner\": \"%\"}", ben.id), ann.token);
	check(status == 200 && contains(body, tprint("\"owner_id\":\"%\"", ben.id)), tprint("Ann makes Ben the owner: % %", status, body));
	status, body = rest("DELETE", tprint("/api/v9/channels/%", group), "", ben.token);
	check(status == 200, tprint("Ben leaves: %", status));
	status, body = rest("GET", tprint("/api/v9/channels/%/messages", group), "", ben.token);
	check(status == 404 || status == 403, tprint("Ben is out: %", status));
	status, body = rest("PATCH", tprint("/api/v9/channels/%", group), "{\"name\": null}", dee.token);
	check(status == 200 && contains(body, tprint("\"owner_id\":\"%\"", ann.id)) && contains(body, "\"name\":null"), tprint("the owner's leaving hands it to the oldest member: % %", status, body));
	discord.client_destroy(gb);
	for everyone { e2e.stop(it.d); while !e2e.stopped(it.d) sleep_milliseconds(1); e2e.destroy(it.d); }
	http.h1_destroy(*h, true);
	serve.stop(s);
	if failed { print("serve_dms: % failed\n", failed); exit(1); }
	print("serve_dms: ok\n");
}
