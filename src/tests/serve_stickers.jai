// Stickers and emoji edits on a self-hosted server: jai build.jai - run src/tests/serve_stickers.jai, then
// build/serve_stickers. The owner uploads stickers (multipart, as Discord's), members see them, a member
// sends one through the real client, and the owner renames and deletes stickers and emoji. Writes only
// under build/serve_stickers_test.
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

DIR :: "build/serve_stickers_test";

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
	rest :: (method: string, path: string, body: string, token: string, type := "application/json") -> int, string #expand {
		headers: [..]http.Header;
		headers.allocator = temp;
		if token array_add(*headers, .{"authorization", token});
		if body array_add(*headers, .{"Content-Type", type}, .{"Content-Length", tprint("%", body.count)});
		resp := http.h1_round_trip(*`h, .{method = method, path = path, authority = `hosted.server_id, body = cast([]u8) body, headers = headers});
		return resp.status, copy_string(cast(string) resp.body,, temp);
	}
	BOUNDARY :: "----fastcordtest";
	form :: (name: string, tags: string, file: string) -> string {
		part :: (n: string, v: string, filename := "") -> string {
			disp := ifx filename then tprint("form-data; name=\"%\"; filename=\"%\"", n, filename) else tprint("form-data; name=\"%\"", n);
			return tprint("--%\r\nContent-Disposition: %\r\n\r\n%\r\n", BOUNDARY, disp, v);
		}
		return tprint("%1%2%3%4--%5--\r\n", part("name", name), part("tags", tags), part("description", ""), part("file", file, "s.png"), BOUNDARY);
	}
	FORM :: #run tprint("multipart/form-data; boundary=%", BOUNDARY);
	PNG :: "\x89PNG\r\n\x1a\n\0\0\0\x0dIHDR\0\0\0\x01\0\0\0\x01\x08\x06\0\0\0\x1f\x15\xc4\x89\0\0\0\0IDAT\0\0\0\0";
	APNG :: "\x89PNG\r\n\x1a\n\0\0\0\x0dIHDR\0\0\0\x01\0\0\0\x01\x08\x06\0\0\0\x1f\x15\xc4\x89\0\0\0\x08acTL\0\0\0\x01\0\0\0\0\0\0\0\0\0\0\0\0IDAT\0\0\0\0";
	LOTTIE :: "{\"v\":\"5.5.2\",\"fr\":30,\"ip\":0,\"op\":30,\"w\":320,\"h\":320,\"layers\":[]}";
	stickers := tprint("/api/v9/guilds/%/stickers", s.guild);

	status, body := rest("POST", stickers, form("wave", "👋", PNG), member_token, FORM);
	check(status == 403, tprint("only the owner adds stickers: %", status));
	status, body = rest("POST", stickers, form("bad", "👋", "hello"), owner_token, FORM);
	check(status == 400, tprint("a file that isn't a sticker is refused: %", status));
	status, body = rest("POST", stickers, form("x", "👋", PNG), owner_token, FORM);
	check(status == 400, tprint("a one-letter name is refused: %", status));
	status, body = rest("POST", stickers, "--x\r\n", owner_token, FORM);
	check(status == 400, tprint("a broken form is refused: %", status));

	a := discord.client_create(.{token = owner_token, hosted = hosted});
	b := discord.client_create(.{token = member_token, hosted = hosted});
	discord.client_start(a);
	discord.client_start(b);
	pump :: () #expand {
		discord.client_poll(`a);
		discord.client_poll(`b);
		sleep_milliseconds(10);
	}
	for 1..1000 { if a.store.ready && b.store.ready break; pump(); }
	check(a.store.ready && b.store.ready, "both READY");
	if failed { serve.stop(s); exit(1); }
	gid := cast(discord.Snowflake) s.guild;
	guild :: () -> *discord.Guild #expand { return discord.guild_get(*`b.store, `gid); }

	status, body = rest("POST", stickers, form("wave", "👋", PNG), owner_token, FORM);
	check(status == 201 && contains(body, "\"format_type\":1") && contains(body, "\"tags\":\"👋\""), tprint("the owner adds a PNG sticker: % %", status, body));
	made := etf.from_json(body,, temp);
	id_v, _ := etf.map_get(made.map, "id");
	sticker := string_to_int(id_v.s, T = u64);
	status, body = rest("POST", stickers, form("dance", "💃", APNG), owner_token, FORM);
	check(status == 201 && contains(body, "\"format_type\":2"), tprint("an APNG sticker: % %", status, body));
	status, body = rest("POST", stickers, form("spin", "🌀", LOTTIE), owner_token, FORM);
	check(status == 201 && contains(body, "\"format_type\":3"), tprint("a Lottie sticker: % %", status, body));
	for 1..300 { if guild().stickers.count == 3 break; pump(); }
	check(guild().stickers.count == 3 && guild().stickers[0].name == "wave" && guild().stickers[0].format_type == 1, "GUILD_STICKERS_UPDATE reaches the members");
	status, body = rest("GET", tprint("/stickers/%.png?size=160", sticker), "", "");
	check(status == 200 && body == PNG, tprint("the file is served as sent: %", status));
	status, body = rest("GET", stickers, "", member_token);
	check(status == 200 && contains(body, "\"name\":\"spin\"") && !contains(body, "\"user\""), tprint("the list route, without uploaders for members: % %", status, body));

	// A member sends one through the client; it arrives with its item, and an unknown one is refused.
	channel := guild().channels[0];
	ids := discord.Snowflake.[cast(discord.Snowflake) sticker];
	discord.send_message(b, channel, "", .{sticker_ids = ids});
	stored :: (cl: *discord.Client) -> []discord.Message #expand {
		ok, l := table_find(*cl.store.messages, `channel);
		if !ok return .[];
		return l.messages;
	}
	for 1..300 { if stored(a).count && stored(a)[stored(a).count - 1].sticker_ids.count break; pump(); }
	got := stored(a);
	check(got.count && got[got.count - 1].sticker_ids.count == 1 && got[got.count - 1].sticker_ids[0] == cast(discord.Snowflake) sticker, "a sticker message reaches the others");
	item, known := discord.sticker_item(*a.store, cast(discord.Snowflake) sticker);
	check(known && item.name == "wave" && item.format_type == 1, "with its sticker_items");
	messages := tprint("/api/v9/channels/%/messages", channel);
	status, body = rest("POST", messages, "{\"content\": \"\", \"sticker_ids\": [\"12345\"]}", member_token);
	check(status == 400, tprint("an unknown sticker is refused: %", status));
	status, body = rest("POST", messages, tprint("{\"content\": \"\", \"sticker_ids\": [\"%\", \"%\", \"%\", \"%\"]}", sticker, sticker, sticker, sticker), member_token);
	check(status == 400, tprint("at most 3 stickers a message: %", status));

	// Edit and delete, for the owner only.
	status, body = rest("PATCH", tprint("%/%", stickers, sticker), "{\"name\": \"hello\"}", member_token);
	check(status == 403, tprint("a member can't rename a sticker: %", status));
	status, body = rest("PATCH", tprint("%/%", stickers, sticker), "{\"name\": \"hello\", \"description\": \"says hi\"}", owner_token);
	check(status == 200 && contains(body, "\"name\":\"hello\"") && contains(body, "\"description\":\"says hi\""), tprint("the owner renames it: % %", status, body));
	for 1..300 { if guild().stickers.count && guild().stickers[0].name == "hello" break; pump(); }
	check(guild().stickers.count && guild().stickers[0].name == "hello", "the rename reaches the members");
	status, body = rest("DELETE", tprint("%/%", stickers, sticker), "", owner_token);
	check(status == 204, tprint("the owner deletes it: %", status));
	for 1..300 { if guild().stickers.count == 2 break; pump(); }
	check(guild().stickers.count == 2, "the delete reaches the members");
	status, body = rest("GET", tprint("/stickers/%.png", sticker), "", "");
	check(status == 404, tprint("a deleted sticker isn't served: %", status));
	status, body = rest("GET", tprint("%?limit=50", messages), "", member_token);
	check(status == 200 && contains(body, "\"sticker_items\":[{\"id\":") && contains(body, "\"name\":\"wave\""), "a sent sticker keeps its item after the delete");

	// Emoji: rename and delete.
	GIF :: "GIF89a\x01\0\x01\0\0\0\0;";
	emojis := tprint("/api/v9/guilds/%/emojis", s.guild);
	status, body = rest("POST", emojis, tprint("{\"name\": \"party\", \"image\": \"data:image/gif;base64,%\"}", base64(GIF)), owner_token);
	check(status == 201, tprint("the owner adds an emoji: % %", status, body));
	emoji := etf.map_get(etf.from_json(body,, temp).map, "id").s;
	status, body = rest("GET", emojis, "", owner_token);
	check(status == 200 && contains(body, "\"user\":{"), tprint("the owner's list names uploaders: % %", status, body));
	status, body = rest("PATCH", tprint("%/%", emojis, emoji), "{\"name\": \"no spaces\"}", owner_token);
	check(status == 400, tprint("emoji names stay word characters: %", status));
	status, body = rest("PATCH", tprint("%/%", emojis, emoji), "{\"name\": \"fiesta\"}", member_token);
	check(status == 403, tprint("a member can't rename an emoji: %", status));
	status, body = rest("PATCH", tprint("%/%", emojis, emoji), "{\"name\": \"fiesta\"}", owner_token);
	check(status == 200 && contains(body, "\"name\":\"fiesta\""), tprint("the owner renames it: % %", status, body));
	for 1..300 { if guild().emojis.count && guild().emojis[0].name == "fiesta" break; pump(); }
	check(guild().emojis.count == 1 && guild().emojis[0].name == "fiesta", "GUILD_EMOJIS_UPDATE carries the rename");
	status, body = rest("DELETE", tprint("%/%", emojis, emoji), "", owner_token);
	check(status == 204, tprint("the owner deletes it: %", status));
	for 1..300 { if !guild().emojis.count break; pump(); }
	check(!guild().emojis.count, "and the delete");
	status, body = rest("GET", tprint("/api/v9/guilds/%/audit-logs", s.guild), "", owner_token);
	check(status == 200 && contains(body, "\"action_type\":91") && contains(body, "\"action_type\":62"), tprint("the audit log has them: % %", status, body));

	discord.client_destroy(a);
	discord.client_destroy(b);
	http.h1_destroy(*h, true);
	serve.stop(s);
	if failed { print("% failed\n", failed); exit(1); }
	print("serve stickers: ok\n");
}

base64 :: (s: string) -> string {
	B :: #import "Base64";
	return B.base64_encode(s,, temp);
}
