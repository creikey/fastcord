// The soundboard on a self-hosted server: jai build.jai - run src/tests/serve_soundboard.jai, then
// build/serve_soundboard. The owner uploads a sound through the real client, members see it, it is served,
// and a member in a voice channel plays it to the others there. Writes only under build/serve_soundboard_test.
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

DIR :: "build/serve_soundboard_test";

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
	status, body := rest("POST", tprint("/api/v9/guilds/%/channels", s.guild), "{\"name\": \"Hang Out\", \"type\": 2}", owner_token);
	made := etf.from_json(body,, temp);
	id_v, _ := etf.map_get(made.map, "id");
	check(status == 201, tprint("create a voice channel: % %", status, body));
	channel := cast(discord.Snowflake) string_to_int(id_v.s, T = u64);
	guild := cast(discord.Snowflake) s.guild;

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

	// Upload through the client: a file that isn't a sound is refused before it's sent, a member can't add one.
	OGG :: "OggS\x00\x02\x00\x00\x00\x00\x00\x00\x00\x00fastcord-test-sound";
	sound_path := tprint("%/beep.ogg", DIR);
	write_entire_file(sound_path, OGG);
	write_entire_file(tprint("%/not.ogg", DIR), "hello");
	result :: (cl: *discord.Client) -> discord.Feature_Result #expand {
		for 1..500 {
			got := discord.feature_take_for(cl);
			if got.count return got[0];
			pump();
		}
		return .{};
	}
	discord.soundboard_upload(a, guild, tprint("%/not.ogg", DIR), "nope", "", 0, 1);
	check(result(a).status == -1, "a file that isn't mp3 or ogg isn't sent");
	discord.soundboard_upload(b, guild, sound_path, "beep", "", 0, 1);
	check(result(b).status == 403, "only the owner adds sounds");
	discord.soundboard_upload(a, guild, sound_path, "beep", "🔔", 0, 0.5);
	r := result(a);
	check(r.status == 201, tprint("the owner adds a sound: %", r.status));
	for 1..300 { if b.store.soundboard.count break; pump(); }
	check(b.store.soundboard.count == 1 && b.store.soundboard[0].name == "beep" && b.store.soundboard[0].emoji_name == "🔔" && b.store.soundboard[0].volume == 0.5,
		"GUILD_SOUNDBOARD_SOUNDS_UPDATE reaches the members");
	if failed { serve.stop(s); exit(1); }
	snd := b.store.soundboard[0];
	status, body = rest("GET", tprint("/soundboard-sounds/%", snd.id), "", "");
	check(status == 200 && body == OGG, tprint("the file is served as sent: %", status));
	status, body = rest("GET", tprint("/api/v9/guilds/%/soundboard-sounds", s.guild), "", member_token);
	check(status == 200 && contains(body, "\"name\":\"beep\""), tprint("the list route: % %", status, body));
	status, body = rest("POST", tprint("/api/v9/guilds/%/soundboard-sounds", s.guild), "{\"name\": \"bad\", \"sound\": \"data:audio/ogg;base64,aGVsbG8=\"}", owner_token);
	check(status == 400, tprint("bytes that aren't a sound are refused: %", status));

	// Played from a voice channel, it reaches the others in it; from outside, it's refused.
	sound := *b.store.soundboard[0];
	status, body = rest("POST", tprint("/api/v9/channels/%/send-soundboard-sound", channel), tprint("{\"sound_id\":\"%\"}", snd.id), member_token);
	check(status == 403, tprint("only from inside the channel: %", status));
	discord.voice_join(a, guild, channel);
	discord.voice_join(b, guild, channel);
	in_channel :: (cl: *discord.Client, user: discord.Snowflake) -> bool #expand {
		vs := table_find_pointer(*cl.store.voice_states, user);
		return vs && vs.channel_id == `channel;
	}
	for 1..500 { if in_channel(a, b.store.me) && in_channel(b, a.store.me) break; pump(); }
	check(discord.has_permission(discord.channel_permissions(*b.store, channel), discord.PERM_SPEAK | discord.PERM_USE_SOUNDBOARD), "members may play sounds");
	discord.send_soundboard_sound(b, channel, sound);
	effects: []discord.Voice_Effect;
	for 1..300 { effects = discord.take_voice_effects(a); if effects.count break; pump(); }
	check(effects.count == 1 && effects[0].sound_id == snd.id && effects[0].user_id == b.store.me && effects[0].volume == 0.5,
		tprint("VOICE_CHANNEL_EFFECT_SEND reaches the channel: %", effects));
	check(!discord.take_voice_effects(b).count, "the player gets no echo of their own sound");
	// An in-call emoji reaches the others the same way, with no sound.
	discord.send_voice_effect(b, channel, "🔥");
	for 1..300 { effects = discord.take_voice_effects(a); if effects.count break; pump(); }
	check(effects.count == 1 && !effects[0].sound_id && to_string(effects[0].emoji_name.data, effects[0].emoji_len) == "🔥" && effects[0].user_id == b.store.me,
		tprint("an emoji effect reaches the channel: %", effects));

	// Edit and delete.
	discord.soundboard_edit(a, guild, snd.id, "boop", "", 0, 1);
	check(result(a).status == 200, "the owner renames it");
	for 1..300 { if b.store.soundboard.count && b.store.soundboard[0].name == "boop" break; pump(); }
	check(b.store.soundboard.count == 1 && b.store.soundboard[0].name == "boop" && b.store.soundboard[0].volume == 1, "the edit reaches the members");
	c := discord.client_create(.{token = member_token, hosted = hosted});
	discord.client_start(c);
	for 1..1000 { if c.store.ready break; pump(); discord.client_poll(c); }
	check(c.store.soundboard.count == 1 && c.store.soundboard[0].name == "boop", "READY lists the sounds");
	discord.client_destroy(c);
	discord.soundboard_delete(a, guild, snd.id);
	check(result(a).status == 204, "the owner deletes it");
	for 1..300 { if !b.store.soundboard.count break; pump(); }
	check(!b.store.soundboard.count, "the delete reaches the members");
	status, body = rest("GET", tprint("/soundboard-sounds/%", snd.id), "", "");
	check(status == 404, tprint("a deleted sound isn't served: %", status));

	discord.client_destroy(a);
	discord.client_destroy(b);
	http.h1_destroy(*h, true);
	serve.stop(s);
	if failed { print("% failed\n", failed); exit(1); }
	print("serve soundboard: ok\n");
}
