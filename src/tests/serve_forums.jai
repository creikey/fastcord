// Forum and announcement channels on a self-hosted server: jai build.jai - run src/tests/serve_forums.jai,
// then build/serve_forums. The owner makes a forum, a member posts in it, the real client lists the post
// with its starter message, and a message in an announcement channel is published. Writes only under
// build/serve_forums_test.
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

DIR :: "build/serve_forums_test";

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
	check(owner_token != "" && member_token != "", "both join");

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
	channels := tprint("/api/v9/guilds/%/channels", s.guild);

	b := discord.client_create(.{token = member_token, hosted = hosted});
	discord.client_start(b);
	pump :: () #expand { discord.client_poll(`b); sleep_milliseconds(10); }
	for 1..1000 { if b.store.ready break; pump(); }
	check(b.store.ready, "READY");

	status, body := rest("POST", channels, "{\"name\": \"Help Desk\", \"type\": 15}", owner_token);
	check(status == 201 && contains(body, "\"type\":15") && contains(body, "\"name\":\"help-desk\"") && contains(body, "\"available_tags\":[]"), tprint("the owner makes a forum: % %", status, body));
	forum := id_of(body);
	status, body = rest("POST", tprint("/api/v9/channels/%/messages", forum), "{\"content\": \"hi\"}", member_token);
	check(status == 404, tprint("a forum takes no messages of its own: %", status));
	status, body = rest("POST", tprint("/api/v9/channels/%/threads", forum), "{\"name\": \"no body\"}", member_token);
	check(status == 400, tprint("a post needs a message: %", status));
	status, body = rest("POST", tprint("/api/v9/channels/%/threads", forum), "{\"name\": \"Printer on fire\", \"auto_archive_duration\": 4320, \"applied_tags\": [], \"message\": {\"content\": \"It is on fire.\"}}", member_token);
	check(status == 201 && contains(body, "\"message\":{") && contains(body, "\"content\":\"It is on fire.\""), tprint("a member posts: % %", status, body));
	post := id_of(body);
	starter := etf.map_get(etf.from_json(body,, temp).map, "message").map;
	check(etf.map_get(starter, "id").s == post && etf.map_get(starter, "channel_id").s == post, "the starter message shares the post's ID");
	post_id := cast(discord.Snowflake) string_to_int(post, T = u64);
	forum_id := cast(discord.Snowflake) string_to_int(forum, T = u64);
	for 1..300 { if discord.forum_threads(*b.store, forum_id).count break; pump(); }
	posts := discord.forum_threads(*b.store, forum_id);
	check(posts.count == 1 && posts[0] == post_id, "THREAD_CREATE puts the post in the forum");
	discord.fetch_forum_posts(b, forum_id, posts);
	first := "";
	for 1..300 {
		for discord.feature_take_for(b) if it.op == .Forum_Posts && it.ok discord.apply_forum_threads(b, it.body);
		tm := discord.thread_meta(post_id);
		if tm && tm.first_content { first = tm.first_content; break; }
		pump();
	}
	check(first == "It is on fire.", tprint("post-data gives the card its starter message: '%'", first));
	status, body = rest("POST", tprint("/api/v9/channels/%/messages", post), "{\"content\": \"Have you tried water?\"}", owner_token);
	check(status == 200, tprint("replies go in the post: %", status));
	status, body = rest("PATCH", tprint("/api/v9/channels/%", post), "{\"archived\": true}", member_token);
	check(status == 200, tprint("the poster archives it: %", status));
	status, body = rest("GET", tprint("/api/v9/channels/%/threads/search?archived=true&sort_by=last_message_time&sort_order=desc&limit=25&tag_setting=match_some&offset=0", forum), "", member_token);
	check(status == 200 && contains(body, tprint("\"id\":\"%\"", post)) && contains(body, "\"first_messages\":[{") && contains(body, "It is on fire."), tprint("threads/search lists archived posts with their first messages: % %", status, body));
	status, body = rest("DELETE", tprint("/api/v9/channels/%", forum), "", owner_token);
	check(status == 200, tprint("the owner deletes the forum: %", status));
	status, body = rest("GET", tprint("/api/v9/channels/%/messages", post), "", member_token);
	check(status == 404, tprint("its posts go with it: %", status));

	// Announcement channels: messages, Publish once, by the author or the owner.
	status, body = rest("POST", channels, "{\"name\": \"News\", \"type\": 5}", owner_token);
	check(status == 201 && contains(body, "\"type\":5") && contains(body, "\"topic\":"), tprint("the owner makes an announcement channel: % %", status, body));
	news := id_of(body);
	status, body = rest("POST", tprint("/api/v9/channels/%/messages", news), "{\"content\": \"Version 2 is out\"}", owner_token);
	check(status == 200, tprint("the owner posts there: %", status));
	message := id_of(body);
	publish := tprint("/api/v9/channels/%/messages/%/crosspost", news, message);
	status, body = rest("POST", publish, "", member_token);
	check(status == 403, tprint("only the author or owner publishes: %", status));
	status, body = rest("POST", publish, "", owner_token);
	check(status == 200 && contains(body, "\"flags\":1"), tprint("Publish marks it crossposted: % %", status, body));
	status, body = rest("POST", publish, "", owner_token);
	check(status == 400 && contains(body, "40033"), tprint("once: % %", status, body));
	status, body = rest("POST", tprint("/api/v9/channels/%/threads", news), "{\"name\": \"Discuss\", \"type\": 11}", member_token);
	check(status == 201, tprint("announcement channels take threads: % %", status, body));

	discord.client_destroy(b);
	http.h1_destroy(*h, true);
	serve.stop(s);
	if failed { print("% failed\n", failed); exit(1); }
	print("serve forums: ok\n");
}
