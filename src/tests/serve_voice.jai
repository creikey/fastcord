// Voice on a self-hosted server: jai build.jai - run src/tests/serve_voice.jai, then build/serve_voice. Two
// members on the real client join a voice channel over loopback and hear each other through serve's
// forwarding. Writes only under build/serve_voice_test.
#import "Basic";
#import "File";
#import "File_Utilities";
#import "Math";
#import "String";
#import "Atomics";
#import "Hash_Table";
discord :: #import "discord";
etf :: #import "etf";
http :: #import "http";
keys :: #import "keys";
netio :: #import "netio";
serve :: #import "serve";
tls :: #import "tls";
voice :: #import "voice";
#if OS == .WINDOWS msvcprt :: #library,system,no_dll,link_always "msvcprt";

DIR :: "build/serve_voice_test";

Member :: struct {
	cl: *discord.Client;
	conn: *voice.Conn;
	heard: s64;  // Atomic: 20 ms frames with sound from the other member.
	phase: float64;
}

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
		token := serve.member_login(inv, keys.generate(name), name);
		return token;
	}
	owner_token := login(serve.owner_invite(s), "Owner");
	member_token := login(serve.first_invite(s), "Member");
	check(owner_token != "" && member_token != "", "both join");

	// The owner makes a voice channel, named as typed.
	session := tls.connect(netio.tcp_stream(netio.dial_tcp("127.0.0.1", port)), .{alpn = .[serve.ALPN], server_name = hosted.server_id, pin = hosted.pin});
	h: http.H1_Conn;
	http.h1_init(*h, tls.stream(session));
	body := "{\"name\": \"Hang Out\", \"type\": 2}";
	req := http.Request.{method = "POST", path = tprint("/api/v9/guilds/%/channels", s.guild), authority = hosted.server_id, body = cast([]u8) body,
		headers = .[.{"authorization", owner_token}, .{"Content-Type", "application/json"}, .{"Content-Length", tprint("%", body.count)}]};
	resp := http.h1_round_trip(*h, req);
	made := etf.from_json(cast(string) resp.body);
	id_v, _ := etf.map_get(made.map, "id");
	name_v, _ := etf.map_get(made.map, "name");
	check(resp.status == 201 && name_v.s == "Hang Out", tprint("create a voice channel: % %", resp.status, cast(string) resp.body));
	channel := cast(discord.Snowflake) string_to_int(id_v.s, T = u64);
	guild := cast(discord.Snowflake) s.guild;

	a, b: Member;
	members := (*Member).[*a, *b];
	for members {
		it.cl = discord.client_create(.{token = ifx it == *a then owner_token else member_token, hosted = hosted});
		discord.client_start(it.cl);
	}
	pump :: () #expand {
		for `members discord.client_poll(it.cl);
		sleep_milliseconds(10);
	}
	for 1..1000 { if a.cl.store.ready && b.cl.store.ready break; pump(); }
	check(a.cl.store.ready && b.cl.store.ready, "both READY");
	for members discord.voice_join(it.cl, guild, channel);
	in_channel :: (m: *Member, user: discord.Snowflake) -> bool #expand {
		vs := table_find_pointer(*m.cl.store.voice_states, user);
		return vs && vs.channel_id == `channel;
	}
	for 1..500 { if in_channel(*a, b.cl.store.me) && in_channel(*b, a.cl.store.me) break; pump(); }
	check(in_channel(*a, b.cl.store.me) && in_channel(*b, a.cl.store.me), "each sees the other's voice state");

	// Each connects its voice with a tone for a microphone, as the app does once VOICE_SERVER_UPDATE is in.
	for m: members {
		info, _, got := discord.voice_server_info(m.cl);
		for 1..500 { if got break; pump(); info, _, got = discord.voice_server_info(m.cl); }
		check(got, "VOICE_SERVER_UPDATE");
		if !got continue;
		m.conn = voice.voice_connect(.{endpoint = info.endpoint, token = info.token, guild_or_channel_id = xx info.guild_or_channel_id,
			user_id = xx info.user_id, session_id = info.session_id, channel_id = xx info.channel_id}, .{
			no_audio_devices = true,
			hosted = .{host = hosted.host, port = hosted.port, server_id = hosted.server_id, pin = hosted.pin},
			callback_data = m,
			capture = (data: *void, out: []float32) -> int {
				m := cast(*Member) data;
				for * out { it.* = cast(float32) (0.2 * sin(m.phase)); m.phase += 2 * PI * 440 / 48000; }
				return out.count;
			},
			playback = (data: *void, user_id: u64, pcm: []float32) {
				energy: float32;
				for pcm energy += it * it;
				if energy > 1 atomic_add(*(cast(*Member) data).heard, 1);
			}});
	}
	if failed { serve.stop(s); exit(1); }
	for 1..1000 { if atomic_load(*a.heard) > 25 && atomic_load(*b.heard) > 25 break; pump(); }
	for members {
		st, code := voice.state(it.conn);
		check(st == .Connected, tprint("voice connected: % %", st, code));
	}
	check(atomic_load(*a.heard) > 25 && atomic_load(*b.heard) > 25, tprint("each hears the other: % %", a.heard, b.heard));
	speaking := voice.speaking_users(a.conn,, temp);
	check(array_find(speaking, xx b.cl.store.me), tprint("the owner sees the member speaking: %", speaking));
	stats := voice.get_stats(a.conn);
	check(stats.transport_failures == 0 && stats.remote_users == 1, tprint("clean media: % failures, % users", stats.transport_failures, stats.remote_users));

	// The member leaves: their voice state goes, and the owner's connection drops them.
	voice.voice_disconnect(b.conn);
	discord.voice_leave(b.cl);
	for 1..500 { if !in_channel(*a, b.cl.store.me) && voice.get_stats(a.conn).remote_users == 0 break; pump(); }
	check(!in_channel(*a, b.cl.store.me) && voice.get_stats(a.conn).remote_users == 0, "a leave reaches the others");

	// Deleting the channel ends the owner's call.
	req.method, req.path, req.body = "DELETE", tprint("/api/v9/channels/%", channel), .[];
	req.headers = .[.{"authorization", owner_token}];
	resp = http.h1_round_trip(*h, req);
	for 1..500 { if !in_channel(*a, a.cl.store.me) break; pump(); }
	check(resp.status == 200 && !in_channel(*a, a.cl.store.me), tprint("deleting the channel ends its calls: %", resp.status));

	voice.voice_disconnect(a.conn);
	for members discord.client_destroy(it.cl);
	http.h1_destroy(*h, true);
	serve.stop(s);
	if failed { print("% failed\n", failed); exit(1); }
	print("serve voice: ok\n");
}
