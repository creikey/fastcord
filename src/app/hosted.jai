// Self-hosted servers joined by an fc:// invite (Hosting 1): each gets its own client beside the Discord
// one. app.client is whichever connection the selected guild belongs to; app.discord stays Discord's.
// Joined invites persist in settings.json, and every start logs in again by key, so no server token is kept.

Hosted_Server :: struct {
	invite: string;    // The fc:// URL; inv points into it.
	inv: serve.Invite;
	name: string;      // The member name sent on the first join.
	title: string;     // The server's name when last connected, kept in settings.json for while it is down.
	thread: *Thread;   // The login, running until it finishes.
	token: string;     // Set by the login thread before it finishes, with status and error.
	status: int;       // The server's HTTP answer; 0 if it couldn't be reached.
	error: string;
	client: *dc.Client;
	joined: bool;      // A member already: restored from settings, or logged in once.
	retry_at: float64; // When a failed login of a joined server is tried again; 0 when none is due.
	forget: bool;      // Remove Server: dropped, without contacting it, once a login in flight ends.
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
	if !ok return false, L("That isn't a valid fastcord invite.");
	for hosted if it.inv.id_hex == inv.id_hex return false, L("You're already in that server.");
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
		if h.forget && (!h.thread || thread_is_done(h.thread)) {
			if h.thread {
				thread_deinit(h.thread);
				free(h.thread);
			}
			free(h.token);
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
		}
		if h.forget continue;
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
				toast_show(tprint(L("Couldn't join %: %"), h.inv.host, h.error), false);
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
				if !h.backoff toast_show(tprint(L("Couldn't reach %1: %2 Retrying."), ifx h.title then h.title else h.inv.host, tprint("%1%2", h.error, ifx ends_with(h.error, ".") then "" else ".")), false);
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
		if h.client && h.client.store.ready && h.client.store.guild_order.count {
			g := dc.guild_get(*h.client.store, h.client.store.guild_order[0]);
			if g && g.name != h.title {
				free(h.title);
				h.title = copy_string(g.name);
			}
		}
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
	out: [..]string;
	out.allocator = temp;
	for hosted if !it.forget array_add(*out, it.invite);
	return out;
}

// names: each server's last known name by server ID, drawn while it is down.
hosted_restore :: (invites: []string, names: *Table(string, string)) {
	for invites if hosted_join(it) {
		h := hosted[hosted.count - 1];
		h.joined = true;
		title := table_find_pointer(names, h.inv.id_hex);
		if title h.title = copy_string(title.*);
	}
}

hosted_names :: () -> Table(string, string) {
	out: Table(string, string);
	out.allocator = temp;
	for hosted if it.title && !it.forget table_set(*out, it.inv.id_hex, it.title);
	return out;
}

// The link Copy Link copies: discord.com's for Discord, and for a hosted server an fc:// link that keeps the
// invite's pin and address, then /channels/<server ID>/<channel>[/<message>]. gid 0 is a DM.
channel_link :: (gid: dc.Snowflake, cid: dc.Snowflake, mid: dc.Snowflake = 0) -> string {
	tail := ifx mid then tprint("/%/%", cid, mid) else tprint("/%", cid);
	c := hosted_client_of(gid);
	for hosted if c && it.client == c {
		authority := advance(it.invite, "fc://".count);
		authority.count = find_index_from_left(authority, #char "/");
		return tprint("fc://%/channels/%%", authority, it.inv.id_hex, tail);
	}
	return tprint("https://discord.com/channels/%%", ifx gid then tprint("%", gid) else "@me", tail);
}

// parse_fc_link reads an fc:// channel or message link: the joined server it names (null if none) and the
// channel and message. ok is false when url isn't one.
parse_fc_link :: (url: string) -> h: *Hosted_Server, cid: dc.Snowflake, mid: dc.Snowflake, ok: bool {
	if !begins_with(url, "fc://") return null, 0, 0, false;
	path := advance(url, "fc://".count);
	slash := find_index_from_left(path, #char "/");
	if slash < 0 return null, 0, 0, false;
	path = advance(path, slash);
	if !begins_with(path, "/channels/") return null, 0, 0, false;
	parts := split(trim_right(advance(path, "/channels/".count), "/"), "/",, temp);
	if parts.count < 2 || parts.count > 3 return null, 0, 0, false;
	cid, ok := string_to_int(parts[1], T = u64);
	if !ok return null, 0, 0, false;
	mid: u64;
	if parts.count == 3 {
		mid, ok = string_to_int(parts[2], T = u64);
		if !ok return null, 0, 0, false;
	}
	for hosted if it.inv.id_hex == to_lower_copy(parts[0],, temp) return it, cid, mid, true;
	return null, cid, mid, true;
}

// open_fc_link follows an fc:// channel or message link on a server already joined, switching to its
// connection. False when url isn't one; a server not joined gets a toast, since the link holds no invite.
open_fc_link :: (url: string) -> bool {
	h, cid, mid, ok := parse_fc_link(url);
	if !ok return false;
	if !h {
		toast_show(L("You aren't in that server. Ask a member for an invite."), false);
		return true;
	}
	if !h.client || !h.client.store.ready {
		toast_show(tprint(L("Not connected to % yet."), h.inv.host), false);
		return true;
	}
	keep := app.client;
	app.client = h.client;
	ch := dc.channel_get(store(), cid);
	if !ch {
		app.client = keep;
		toast_show(L("That channel isn't on this server anymore."), false);
		return true;
	}
	if mid jump_to_message(cid, mid);
	else select_channel(ch.guild_id, cid);
	return true;
}

// A custom emoji's image: from the joined server whose guild has it, else Discord's CDN.
emoji_url :: (id: dc.Snowflake, animated: bool, size := 48) -> string {
	for h: hosted if h.client for gid: h.client.store.guild_order {
		g := dc.guild_get(*h.client.store, gid);
		if g for g.emojis if it.id == id return tprint("https://%/emojis/%.webp?size=%", h.inv.id_hex, id, size);
	}
	return dc.custom_emoji_url(id, animated, size);
}

// A sticker's file: the selected hosted server's own, else Discord's.
sticker_file_url :: (id: dc.Snowflake, format_type: int, size := 160) -> string {
	if on_hosted() for hosted if it.client == app.client {
		return tprint("https://%/stickers/%.%?size=%", it.inv.id_hex, id, ifx format_type == 3 then "json" else ifx format_type == 4 then "gif" else "png", size);
	}
	return dc.sticker_url(id, format_type, size);
}

// Whether the selected connection is a self-hosted server, which has no DMs or friends yet.
on_hosted :: () -> bool { return app.client && app.client.cfg.hosted.host != ""; }

// The client to load url through. A hosted client sends every request to its own server, so only URLs on
// that server (host = its ID, as serve writes them) go through it; Discord's CDN and assets go through Discord's,
// and while a hosted server is selected with no Discord login, nowhere (null): they load offline or not at all.
media_client :: (url: string) -> *dc.Client {
	if begins_with(url, E2E_URL) return null; // an opened encrypted file: only in memory
	host := url;
	if begins_with(host, "https://") host = advance(host, "https://".count);
	slash := find_index_from_left(host, #char "/");
	if slash >= 0 host.count = slash;
	for hosted if it.client && it.inv.id_hex == host return it.client;
	if app.client && app.client.cfg.hosted.host return app.discord;
	return app.client;
}

// A guild's icon: a hosted server serves its own, under its ID as host so media_client routes it there.
guild_icon_url :: (gid: dc.Snowflake, hash: string, size := 96, animate := false) -> string {
	if !hash return "";
	h := hosted_of(gid);
	if h return tprint("https://%/icons/%/%.png?size=%", h.inv.id_hex, gid, hash, size);
	return dc.guild_icon_url(gid, hash, size, animate);
}

// The hosted server that owns guild gid, if one does. IDs come from untrusted servers and may collide,
// by chance or on purpose: an ID Discord knows is Discord's, else the first server's that has it, so a
// server can't take over another connection's guild (its menus, history, icon). The rail shows only
// the owner's.
hosted_of :: (gid: dc.Snowflake) -> *Hosted_Server {
	if app.discord && dc.guild_get(*app.discord.store, gid) return null;
	for hosted if it.client && dc.guild_get(*it.client.store, gid) return it;
	return null;
}

hosted_client_of :: (gid: dc.Snowflake) -> *dc.Client {
	h := hosted_of(gid);
	return ifx h then h.client;
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
	free(h.title);
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
		h.error = copy_string(L("There is no identity key."));
	}
	platform.request_frame();
}
