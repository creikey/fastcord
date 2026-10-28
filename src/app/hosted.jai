// Self-hosted servers joined by an fc:// invite (Hosting 1): each gets its own client beside the Discord
// one. app.client is whichever connection the selected guild belongs to; app.discord stays Discord's.
// Joined invites persist in settings.json, and every start logs in again by key, so no server token is kept.

Hosted_Server :: struct {
	invite: string;    // The fc:// URL; inv points into it.
	inv: serve.Invite;
	name: string;      // The member name sent on the first join.
	thread: *Thread;   // The login, running until done.
	done: s32;         // atomic
	token: string;     // Set by the login thread before done.
	error: string;
	client: *dc.Client;
}

hosted: [..]*Hosted_Server;

// hosted_join adds a server by invite and logs in on a thread. False, with the reason, on a bad invite
// or one already joined.
hosted_join :: (url: string) -> bool, string {
	inv, ok := serve.parse_invite(url);
	if !ok return false, "That isn't a valid fastcord invite.";
	for hosted if it.inv.id_hex == inv.id_hex return false, "You're already in that server.";
	h := New(Hosted_Server);
	h.invite = copy_string(url);
	h.inv = serve.parse_invite(h.invite);
	me := "";
	if app.discord && app.discord.store.ready me = dc.user_name(*app.discord.store, app.discord.store.me);
	h.name = copy_string(ifx me then me else "fastcord user");
	array_add(*hosted, h);
	h.thread = dc.spawn(h, hosted_login);
	return true, "";
}

// hosted_frame finishes logins and keeps every connection that isn't app.client polled.
hosted_frame :: () {
	for h: hosted {
		if h.thread && atomic_load(*h.done) {
			locks.join(h.thread);
			h.thread = null;
			if h.token {
				cfg := dc.Config.{token = h.token, wakeup = (_: *void) { platform.request_frame(); }};
				cfg.hosted = .{host = h.inv.host, port = h.inv.port, pin = h.inv.pin, server_id = h.inv.id_hex};
				h.client = dc.client_create(cfg);
				dc.client_start(h.client);
			} else {
				toast_show(tprint("Couldn't join %: %", h.inv.host, h.error), false);
			}
		}
		if h.client && h.client != app.client dc.client_poll(h.client);
		// Leave Server ends in GUILD_DELETE for the server's one guild; forget the server with it, so the
		// next start doesn't rejoin through the saved invite.
		if h.client && h.client.store.ready && !h.client.store.guild_order.count {
			if app.client == h.client {
				app.client = app.discord;
				go_home();
			}
			client_release(h.client);
			free(h.invite);
			free(h.name);
			free(h);
			remove h;
		}
	}
	if app.discord && app.discord != app.client dc.client_poll(app.discord);
}

hosted_invites :: () -> []string {
	out := NewArray(hosted.count, string,, temp);
	for hosted out[it_index] = it.invite;
	return out;
}

hosted_restore :: (invites: []string) {
	for invites hosted_join(it);
}

// The client that owns guild gid, if a hosted one does.
hosted_client_of :: (gid: dc.Snowflake) -> *dc.Client {
	for hosted if it.client && dc.guild_get(*it.client.store, gid) return it.client;
	return null;
}

#scope_file

hosted_login :: (h: *Hosted_Server) {
	while !atomic_load(*idk.done) sleep_milliseconds(50);
	if idk.list.count {
		token, _, message := serve.member_login(h.inv, idk.list[0], h.name);
		h.token, h.error = token, copy_string(message);
	} else {
		h.error = "There is no identity key.";
	}
	atomic_swap(*h.done, 1);
	platform.request_frame();
}
