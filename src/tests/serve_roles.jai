// Roles, permissions and private channels on a self-hosted server: jai build.jai - run src/tests/serve_roles.jai,
// then build/serve_roles. The owner makes roles and gives them out, permissions follow them, and a member who
// can't see a channel gets nothing from it on any path: READY, events, pages, pins, threads, search and
// mentions. Writes only under build/serve_roles_test.
#import "Basic";
#import "File";
#import "File_Utilities";
#import "String";
#import "Hash_Table";
discord :: #import "discord";
etf :: #import "etf";
http :: #import "http";
keys :: #import "keys";
netio :: #import "netio";
serve :: #import "serve";
tls :: #import "tls";
#if OS == .WINDOWS msvcprt :: #library,system,no_dll,link_always "msvcprt";

DIR :: "build/serve_roles_test";

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
	login :: (code: string, name: string) -> string #expand {
		inv, _ := serve.parse_invite(serve.invite_url(`s, "127.0.0.1", `port, code));
		return serve.member_login(inv, keys.generate(name), name);
	}
	owner_token := login(serve.owner_invite(s), "Owner");
	member_token := login(serve.first_invite(s), "Member");
	mod_token := login(serve.first_invite(s), "Mod");
	check(owner_token != "" && member_token != "" && mod_token != "", "all join");

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
		if v.kind != .Map return "";
		id, _ := etf.map_get(v.map, "id");
		return id.s;
	}
	g := tprint("/api/v9/guilds/%", s.guild);

	b := discord.client_create(.{token = member_token, hosted = hosted});
	discord.client_start(b);
	pump :: () #expand { discord.client_poll(`b); sleep_milliseconds(10); }
	for 1..1000 { if b.store.ready break; pump(); }
	check(b.store.ready, "READY");
	if failed { serve.stop(s); exit(1); }
	member_id := tprint("%", b.store.me);
	general := discord.guild_get(*b.store, cast(discord.Snowflake) s.guild).channels[0];
	status: int;
	body: string;

	// Roles: only Manage Roles makes them, and no one grants what they lack.
	status, body = rest("POST", tprint("%/roles", g), "{\"name\": \"Mod\"}", member_token);
	check(status == 403, tprint("a member can't make roles: %", status));
	MANAGE_MESSAGES :: 1 << 13;
	KICK :: 1 << 1;
	MANAGE_ROLES :: 1 << 28;
	status, body = rest("POST", tprint("%/roles", g), tprint("{\"name\": \"Mod\", \"color\": 3447003, \"hoist\": true, \"permissions\": \"%\"}", MANAGE_MESSAGES | KICK | MANAGE_ROLES), owner_token);
	check(status == 201 && contains(body, "\"name\":\"Mod\"") && contains(body, "\"position\":1"), tprint("the owner makes a role: % %", status, body));
	mod_role := id_of(body);
	status, body = rest("POST", tprint("%/roles", g), "{\"name\": \"Staff\"}", owner_token);
	staff_role := id_of(body);
	check(status == 201 && contains(body, "\"position\":1"), tprint("a new role goes just above @everyone: % %", status, body));
	for 1..300 { if discord.guild_get(*b.store, cast(discord.Snowflake) s.guild).roles.count == 3 break; pump(); }
	check(discord.guild_get(*b.store, cast(discord.Snowflake) s.guild).roles.count == 3, "GUILD_ROLE_CREATE reaches the members");

	// A message from the member that the mod will try to delete.
	status, body = rest("POST", tprint("/api/v9/channels/%/messages", general), "{\"content\": \"delete me\"}", member_token);
	victim := id_of(body);
	author_of :: (body: string) -> string {
		v := etf.from_json(body,, temp);
		if v.kind != .Map return "";
		a, _ := etf.map_get(v.map, "author");
		return ifx a.kind == .Map then etf.map_get(a.map, "id").s else "";
	}
	status, body = rest("POST", tprint("/api/v9/channels/%/messages", general), "{\"content\": \"hi\"}", mod_token);
	mod_user := author_of(body);
	status, body = rest("DELETE", tprint("/api/v9/channels/%/messages/%", general, victim), "", mod_token);
	check(status == 403, tprint("without the role, no deleting others' messages: %", status));
	status, body = rest("PUT", tprint("%/members/%/roles/%", g, mod_user, mod_role), "", member_token);
	check(status == 403, tprint("a member can't hand out roles: %", status));
	status, body = rest("PUT", tprint("%/members/%/roles/%", g, mod_user, mod_role), "", owner_token);
	check(status == 204, tprint("the owner gives the mod the role: % %", status, body));
	status, body = rest("DELETE", tprint("/api/v9/channels/%/messages/%", general, victim), "", mod_token);
	check(status == 204, tprint("with it, the mod deletes the member's message: % %", status, body));
	status, body = rest("PATCH", tprint("%/roles/%", g, staff_role), "{\"permissions\": \"8\"}", mod_token);
	check(status == 403, tprint("the mod can't grant Administrator: %", status));
	status, body = rest("PATCH", tprint("%/roles/%", g, mod_role), "{\"name\": \"Boss\"}", mod_token);
	check(status == 403, tprint("nor edit their own top role: %", status));
	status, body = rest("PUT", tprint("%/members/%/roles/%", g, member_id, staff_role), "", mod_token);
	check(status == 204, tprint("but hands out roles below it: % %", status, body));
	for 1..300 { if discord.my_roles(*b.store, cast(discord.Snowflake) s.guild).count == 1 break; pump(); }
	check(discord.my_roles(*b.store, cast(discord.Snowflake) s.guild).count == 1, "GUILD_MEMBER_UPDATE carries the member's roles");
	status, body = rest("PATCH", tprint("%/roles/%", g, staff_role), "{\"hoist\": true}", owner_token);
	hoisted :: () -> bool #expand {
		ml := table_find_pointer(*`b.store.member_lists, cast(discord.Snowflake) `s.guild);
		if ml for ml.groups if it.id == `staff_role && it.count == 1 return true;
		return false;
	}
	for 1..300 { if hoisted() break; pump(); }
	check(status == 200 && hoisted(), tprint("a hoisted role gets its own member list group: % %", status, body));
	status, body = rest("DELETE", tprint("%/members/%/roles/%", g, member_id, staff_role), "", mod_token);
	check(status == 204, tprint("and takes them away: %", status));
	status, body = rest("GET", tprint("%/roles/member-counts", g), "", member_token);
	check(status == 200 && contains(body, tprint("\"%\":1", mod_role)) && contains(body, tprint("\"%\":0", staff_role)), tprint("member counts: % %", status, body));

	// A private channel: @everyone can't see it, Staff can.
	VIEW :: 1 << 10;
	status, body = rest("POST", tprint("%/channels", g), tprint("{\"name\": \"staff-room\", \"type\": 0, \"permission_overwrites\": [{\"id\": \"%\", \"type\": 0, \"deny\": \"%\"}, {\"id\": \"%\", \"type\": 0, \"allow\": \"%\"}]}", s.guild, VIEW, staff_role, VIEW), owner_token);
	check(status == 201 && contains(body, "\"permission_overwrites\":[{"), tprint("the owner makes a private channel: % %", status, body));
	secret := id_of(body);
	secret_id := cast(discord.Snowflake) string_to_int(secret, T = u64);
	for 1..100 pump();
	check(!discord.channel_get(*b.store, secret_id), "the member never hears of it");
	status, body = rest("POST", tprint("/api/v9/channels/%/messages", secret), tprint("{\"content\": \"secret plans <@%> @everyone\"}", member_id), owner_token);
	check(status == 200, tprint("the owner posts there: %", status));
	secret_message := id_of(body);
	status, body = rest("PUT", tprint("/api/v9/channels/%/messages/pins/%", secret, secret_message), "", owner_token);
	status, body = rest("POST", tprint("/api/v9/channels/%/threads", secret), "{\"name\": \"plot\", \"type\": 11}", owner_token);
	plot := id_of(body);
	for 1..100 pump();
	check(!discord.channel_get(*b.store, cast(discord.Snowflake) string_to_int(plot, T = u64)), "nor of its threads");
	ok_list, l := table_find(*b.store.messages, secret_id);
	check(!ok_list || !l.messages.count, "no MESSAGE_CREATE from it");
	for path: string.[tprint("/api/v9/channels/%/messages", secret), tprint("/api/v9/channels/%/messages/pins", secret), tprint("/api/v9/channels/%/messages", plot), tprint("/api/v9/channels/%/threads/search?archived=true", secret)] {
		status, body = rest("GET", path, "", member_token);
		check(status == 403 && !contains(body, "secret"), tprint("% answers 403: % %", path, status, body));
	}
	status, body = rest("POST", tprint("/api/v9/channels/%/messages", secret), "{\"content\": \"let me in\"}", member_token);
	check(status == 403, tprint("no posting there: %", status));
	status, body = rest("GET", tprint("%/messages/search?content=secret", g), "", member_token);
	check(status == 200 && contains(body, "\"total_results\":0"), tprint("search finds nothing in it: % %", status, body));
	status, body = rest("GET", "/api/v9/users/@me/mentions?limit=25", "", member_token);
	check(status == 200 && !contains(body, "secret"), tprint("nor do Recent Mentions: % %", status, body));
	c2 := discord.client_create(.{token = member_token, hosted = hosted});
	discord.client_start(c2);
	for 1..1000 { if c2.store.ready break; discord.client_poll(c2); sleep_milliseconds(10); }
	check(c2.store.ready && !discord.channel_get(*c2.store, secret_id), "READY leaves it out");
	discord.client_destroy(c2);

	// Given Staff, the member sees it all at once, and loses it again with the role.
	status, body = rest("PUT", tprint("%/members/%/roles/%", g, member_id, staff_role), "", owner_token);
	for 1..300 { if discord.channel_get(*b.store, secret_id) break; pump(); }
	check(discord.channel_get(*b.store, secret_id) != null, "a role that shows the channel brings it in");
	check(discord.has_permission(discord.channel_permissions(*b.store, secret_id), VIEW), "and the client agrees it may see it");
	status, body = rest("GET", tprint("/api/v9/channels/%/messages", secret), "", member_token);
	check(status == 200 && contains(body, "secret plans"), tprint("its messages load: % %", status, body));
	status, body = rest("GET", tprint("%/messages/search?content=secret", g), "", member_token);
	check(status == 200 && contains(body, "\"total_results\":1"), tprint("search finds them: % %", status, body));
	status, body = rest("PUT", tprint("/api/v9/channels/%/permissions/%", secret, member_id), tprint("{\"type\": 1, \"deny\": \"%\"}", 1 << 11), owner_token);
	check(status == 204, tprint("an overwrite for the member: % %", status, body));
	status, body = rest("POST", tprint("/api/v9/channels/%/messages", secret), "{\"content\": \"me too\"}", member_token);
	check(status == 403, tprint("denies them Send Messages: %", status));
	status, body = rest("DELETE", tprint("%/roles/%", g, staff_role), "", owner_token);
	check(status == 204, tprint("the owner deletes Staff: %", status));
	for 1..300 { if !discord.channel_get(*b.store, secret_id) break; pump(); }
	check(!discord.channel_get(*b.store, secret_id), "the channel goes with it");

	// Kicking: Kick Members, and only over members you outrank.
	status, body = rest("DELETE", tprint("%/members/%", g, member_id), "", member_token);
	check(status == 403, tprint("a member can't kick: %", status));
	status, body = rest("POST", tprint("/api/v9/channels/%/messages", general), "{\"content\": \"x\"}", owner_token);
	owner_user := author_of(body);
	status, body = rest("DELETE", tprint("%/members/%", g, owner_user), "", mod_token);
	check(status == 403, tprint("the mod can't kick the owner: %", status));
	status, body = rest("DELETE", tprint("%/members/%", g, member_id), "", mod_token);
	check(status == 204, tprint("the mod kicks the member: % %", status, body));

	discord.client_destroy(b);
	http.h1_destroy(*h, true);
	serve.stop(s);
	if failed { print("% failed\n", failed); exit(1); }
	print("serve roles: ok\n");
}
