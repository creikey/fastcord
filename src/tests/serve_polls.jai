// Polls on a self-hosted server: jai build.jai - run src/tests/serve_polls.jai, then build/serve_polls. A
// member posts a poll, others vote through the real client, the counts follow the gateway's vote events,
// and the author ends it. Writes only under build/serve_polls_test.
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

DIR :: "build/serve_polls_test";

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

	b := discord.client_create(.{token = member_token, hosted = hosted});
	discord.client_start(b);
	pump :: () #expand { discord.client_poll(`b); sleep_milliseconds(10); }
	for 1..1000 { if b.store.ready break; pump(); }
	check(b.store.ready, "READY");
	if failed { serve.stop(s); exit(1); }
	channel := discord.guild_get(*b.store, cast(discord.Snowflake) s.guild).channels[0];
	messages := tprint("/api/v9/channels/%/messages", channel);

	status, body := rest("POST", messages, "{\"poll\": {\"question\": {\"text\": \"\"}, \"answers\": [{\"poll_media\": {\"text\": \"a\"}}]}}", owner_token);
	check(status == 400, tprint("a poll needs a question: %", status));
	status, body = rest("POST", messages, "{\"poll\": {\"question\": {\"text\": \"Lunch?\"}, \"answers\": [], \"duration\": 24}}", owner_token);
	check(status == 400, tprint("and answers: %", status));
	status, body = rest("POST", messages, "{\"poll\": {\"question\": {\"text\": \"Lunch?\"}, \"answers\": [{\"poll_media\": {\"text\": \"x\"}}], \"duration\": 9999}}", owner_token);
	check(status == 400, tprint("and at most 32 days: %", status));
	POLL :: "{\"content\": \"\", \"poll\": {\"question\": {\"text\": \"Lunch?\"}, \"answers\": [{\"poll_media\": {\"text\": \"Pizza\", \"emoji\": {\"name\": \"🍕\"}}}, {\"poll_media\": {\"text\": \"Tacos\"}}], \"duration\": 1, \"allow_multiselect\": false, \"layout_type\": 1}}";
	status, body = rest("POST", messages, POLL, owner_token);
	check(status == 200 && contains(body, "\"poll\":{") && contains(body, "\"text\":\"Lunch?\"") && contains(body, "\"answer_id\":2") && contains(body, "\"is_finalized\":false"), tprint("the owner posts a poll: % %", status, body));
	v := etf.from_json(body,, temp);
	poll_id := etf.map_get(v.map, "id").s;
	message := cast(discord.Snowflake) string_to_int(poll_id, T = u64);
	stored :: () -> *discord.Message #expand {
		ok, l := table_find(*`b.store.messages, `channel);
		if ok for * l.messages if it.id == `message return it;
		return null;
	}
	for 1..300 { if stored() && stored().poll break; pump(); }
	m := stored();
	check(m && m.poll && m.poll.question == "Lunch?" && m.poll.answers.count == 2 && m.poll.answers[0].emoji == "🍕", "MESSAGE_CREATE brings the poll to the client");
	if failed { serve.stop(s); exit(1); }

	// Voting through the client: the vote events move the counts and mark ours.
	discord.poll_vote(b, channel, message, .[1]);
	for 1..300 { if stored().poll.answers[0].count == 1 break; pump(); }
	check(stored().poll.answers[0].count == 1 && stored().poll.answers[0].me, "a vote counts, and is ours");
	discord.poll_vote(b, channel, message, .[2]);
	for 1..300 { if stored().poll.answers[1].count == 1 break; pump(); }
	check(stored().poll.answers[0].count == 0 && !stored().poll.answers[0].me && stored().poll.answers[1].count == 1, "changing it moves it");
	status, body = rest("PUT", tprint("/api/v9/channels/%/polls/%/answers/@me", channel, poll_id), "{\"answer_ids\": [\"1\", \"2\"]}", owner_token);
	check(status == 400, tprint("one answer only, without allow_multiselect: %", status));
	status, body = rest("PUT", tprint("/api/v9/channels/%/polls/%/answers/@me", channel, poll_id), "{\"answer_ids\": [\"3\"]}", owner_token);
	check(status == 400, tprint("no answer past the last: %", status));
	status, body = rest("PUT", tprint("/api/v9/channels/%/polls/%/answers/@me", channel, poll_id), "{\"answer_ids\": [\"2\"]}", owner_token);
	check(status == 204, tprint("the owner votes too: %", status));
	for 1..300 { if stored().poll.answers[1].count == 2 break; pump(); }
	check(stored().poll.answers[1].count == 2, "the others' votes arrive");
	status, body = rest("GET", tprint("/api/v9/channels/%/polls/%/answers/2?limit=25", channel, poll_id), "", member_token);
	check(status == 200 && contains(body, "\"global_name\":\"Owner\"") && contains(body, "\"global_name\":\"Member\""), tprint("the voters of an answer: % %", status, body));
	status, body = rest("GET", tprint("%?limit=50", messages), "", member_token);
	check(status == 200 && contains(body, "\"me_voted\":true") && contains(body, "\"count\":2"), tprint("a fetch carries results and our votes: % %", status, body));

	// Ending it: the author only; then it's final and takes no votes.
	status, body = rest("POST", tprint("/api/v9/channels/%/polls/%/expire", channel, poll_id), "", member_token);
	check(status == 403, tprint("only the author ends it: %", status));
	status, body = rest("POST", tprint("/api/v9/channels/%/polls/%/expire", channel, poll_id), "", owner_token);
	check(status == 204, tprint("the author ends it: % %", status, body));
	for 1..300 { if stored().poll.finalized break; pump(); }
	check(stored().poll.finalized && stored().poll.answers[1].count == 2, "MESSAGE_UPDATE finalizes it with the results");
	result :: () -> *discord.Message #expand {
		ok, l := table_find(*`b.store.messages, `channel);
		if ok for * l.messages if it.kind == 46 && it.referenced_id == `message return it;
		return null;
	}
	for 1..300 { if result() break; pump(); }
	r := result();
	won := false;
	if r for e: r.embeds if e.kind == "poll_result" for e.fields if it.name == "victor_answer_text" && it.value == "Tacos" won = true;
	check(r && won, "a result message (type 46) names the winner");
	status, body = rest("GET", tprint("%?limit=50", messages), "", member_token);
	check(contains(body, "\"type\":46") && contains(body, "\"total_votes\"") && contains(body, "\"value\":\"2\""), tprint("and fetches carry it: %", body));
	discord.poll_vote(b, channel, message, .[]);
	status, body = rest("PUT", tprint("/api/v9/channels/%/polls/%/answers/@me", channel, poll_id), "{\"answer_ids\": []}", member_token);
	check(status == 400, tprint("no votes once closed: %", status));
	status, body = rest("DELETE", tprint("%/%", messages, poll_id), "", owner_token);
	check(status == 204, tprint("deleting the message: %", status));
	status, body = rest("GET", tprint("/api/v9/channels/%/polls/%/answers/2", channel, poll_id), "", member_token);
	check(status == 404, tprint("takes the poll with it: %", status));

	discord.client_destroy(b);
	http.h1_destroy(*h, true);
	serve.stop(s);
	if failed { print("% failed\n", failed); exit(1); }
	print("serve polls: ok\n");
}
