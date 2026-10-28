// Self-hosted servers joined by an fc:// invite (Hosting 1): each gets its own client beside the Discord
// one. app.client is whichever connection the selected guild belongs to; app.discord stays Discord's.
// Joined invites persist in settings.json, and every start logs in again by key, so no server token is kept.

Hosted_Server :: struct {
	invite: string;    // The fc:// URL; inv points into it.
	inv: serve.Invite;
	name: string;      // The member name sent on the first join.
	thread: *Thread;   // The login, running until it finishes.
	token: string;     // Set by the login thread before it finishes, with status and error.
	status: int;       // The server's HTTP answer; 0 if it couldn't be reached.
	error: string;
	client: *dc.Client;
	joined: bool;      // A member already: restored from settings, or logged in once.
	retry_at: float64; // When a failed login of a joined server is tried again; 0 when none is due.
	backoff: float64;
	// What mirror_presence last told status_client, which a re-login replaces.
	status_sent: dc.Status;
	custom_sent: string;
	status_client: *dc.Client;
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
	hosted_start(h);
	return true, "";
}

// hosted_frame finishes logins and keeps every connection that isn't app.client polled.
hosted_frame :: () {
	for h: hosted {
		if h.thread && thread_is_done(h.thread) {
			// Reaped without locks.join, which flags any join on the UI thread; this one can't wait.
			thread_deinit(h.thread);
			free(h.thread);
			h.thread = null;
			if h.token {
				h.joined, h.backoff, h.retry_at = true, 0, 0;
				cfg := dc.Config.{token = h.token, wakeup = (_: *void) { platform.request_frame(); }};
				cfg.hosted = .{host = h.inv.host, port = h.inv.port, pin = h.inv.pin, server_id = h.inv.id_hex};
				old := h.client;
				h.client = dc.client_create(cfg);
				dc.client_start(h.client);
				free(h.token);
				h.token = "";
				if old {
					if app.client == old app.client = h.client;
					client_release(old);
				}
			} else if !h.joined || h.status == 404 || h.status == 403 {
				// A first join that fails, a server that no longer knows us and whose invite is dead, or one
				// that banned us, is dropped, so settings.json doesn't keep it and a corrected invite can be pasted.
				toast_show(tprint("Couldn't join %: %", h.inv.host, h.error), false);
				if h.client {
					if app.client == h.client {
						app.client = app.discord;
						go_home();
					}
					client_release(h.client);
				}
				hosted_free(h);
				remove h;
				continue;
			} else {
				// A server we're in that is down or refusing for now: try again later, saying so once.
				if !h.backoff toast_show(tprint("Couldn't reach %: %. Retrying.", h.inv.host, h.error), false);
				h.backoff = clamp(h.backoff * 2, 5, 300);
				h.retry_at = platform.time_now() + h.backoff;
			}
		}
		// The server ended this session (past its per-member cap, or by a kick): log in again by key, keeping
		// the old client on screen until the new one replaces it.
		if h.client && h.client.store.connection == .Auth_Failed && !h.thread && !h.retry_at hosted_start(h);
		if h.retry_at && !h.thread {
			if platform.time_now() >= h.retry_at {
				h.retry_at = 0;
				hosted_start(h);
			} else {
				request_wake(h.retry_at);
			}
		}
		if h.client && h.client.store.connection == .Ready && app.discord && app.discord.store.settings.status != .Offline {
			st := *app.discord.store.settings;
			custom := tprint("%\0%\0%", st.custom_status_text, st.custom_status_emoji, st.custom_status_emoji_id);
			if st.status != h.status_sent || custom != h.custom_sent || h.client != h.status_client {
				dc.mirror_presence(h.client, app.discord);
				free(h.custom_sent);
				h.status_sent, h.custom_sent, h.status_client = st.status, copy_string(custom), h.client;
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
			hosted_free(h);
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
	for invites if hosted_join(it) hosted[hosted.count - 1].joined = true;
}

// Whether the selected connection is a self-hosted server, which has no DMs or friends yet.
on_hosted :: () -> bool { return app.client && app.client.cfg.hosted.host != ""; }

// The client that owns guild gid, if a hosted one does.
hosted_client_of :: (gid: dc.Snowflake) -> *dc.Client {
	for hosted if it.client && dc.guild_get(*it.client.store, gid) return it.client;
	return null;
}

// use_guild_client points app.client at the connection gid belongs to, for a menu or modal opened on a
// guild that isn't selected; it returns the client to put back afterwards.
use_guild_client :: (gid: dc.Snowflake) -> *dc.Client {
	keep := app.client;
	c := hosted_client_of(gid);
	if c app.client = c;
	else if app.discord && dc.guild_get(*app.discord.store, gid) app.client = app.discord;
	return keep;
}

#scope_file

hosted_free :: (h: *Hosted_Server) {
	free(h.invite);
	free(h.name);
	free(h.error);
	free(h.custom_sent);
	free(h);
}

hosted_start :: (h: *Hosted_Server) {
	free(h.error);
	h.error, h.status = "", 0;
	h.thread = dc.spawn(h, hosted_login);
}

hosted_login :: (h: *Hosted_Server) {
	while !atomic_load(*idk.done) sleep_milliseconds(50);
	if idk.list.count {
		token, status, message := serve.member_login(h.inv, idk.list[0], h.name);
		h.token, h.status, h.error = token, status, copy_string(message);
	} else {
		h.error = copy_string("There is no identity key.");
	}
	platform.request_frame();
}
