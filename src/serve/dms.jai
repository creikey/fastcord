// Direct messages between members. Serve is only their carrier: every DM message is an end-to-end
// encrypted packet in its `fc-` text form (`src/fc_text`), and anything else is refused, so serve relays
// and stores what it can't read. DMs live apart from the guild's channels and messages, so nothing
// guild-wide (READY's channels, search, mentions, audit) lists them; only the two members see a DM, its
// messages, typing and read state. Messages wait here for a member who is offline, up to MAX_DM_MESSAGES
// per DM, the oldest going first.

DM_SCHEMA :: #string SQL
CREATE TABLE IF NOT EXISTS dms(id INTEGER PRIMARY KEY, a INTEGER NOT NULL, b INTEGER NOT NULL, UNIQUE(a, b));
CREATE TABLE IF NOT EXISTS dm_messages(id INTEGER PRIMARY KEY, dm INTEGER NOT NULL, author INTEGER NOT NULL, content TEXT NOT NULL, nonce TEXT, flags INTEGER NOT NULL DEFAULT 0);
CREATE INDEX IF NOT EXISTS dm_messages_dm ON dm_messages(dm, id);
CREATE TABLE IF NOT EXISTS dm_closed(dm INTEGER NOT NULL, user INTEGER NOT NULL, PRIMARY KEY(dm, user));
CREATE TABLE IF NOT EXISTS e2e_bundles(user INTEGER PRIMARY KEY, bundle TEXT NOT NULL);
SQL

MAX_DM_MESSAGES :: 10000;
DM :: 1; // Discord's channel type.

// dm_peer_locked is the other member of DM dm, or 0 when it isn't a DM of user's. The caller holds db_mu.
dm_peer_locked :: (s: *Server, dm: s64, user: s64) -> s64 {
	st := sqlite.prepare(s.db, "SELECT CASE WHEN a = ?2 THEN b ELSE a END FROM dms WHERE id = ?1 AND (a = ?2 OR b = ?2);");
	defer sqlite.finalize(st);
	sqlite.bind_all(st, dm, user);
	return ifx sqlite.step(st) == .Row then sqlite.col_int(st, 0) else 0;
}

// dm_value is a DM as Discord sends it to one of its members, with the other as its recipient.
dm_value_locked :: (s: *Server, dm: s64, peer: s64) -> etf.Value {
	name := "";
	st := sqlite.prepare(s.db, "SELECT name FROM users WHERE id = ?;");
	sqlite.bind(st, 1, peer);
	if sqlite.step(st) == .Row name = copy_string(sqlite.col_text(st, 0),, temp);
	sqlite.finalize(st);
	last: s64;
	st = sqlite.prepare(s.db, "SELECT max(id) FROM dm_messages WHERE dm = ?;");
	sqlite.bind(st, 1, dm);
	if sqlite.step(st) == .Row last = sqlite.col_int(st, 0);
	sqlite.finalize(st);
	recipients := NewArray(1, etf.Value,, temp);
	recipients[0] = user_value(s, peer, name);
	m := etf.map_builder(5,, temp);
	etf.map_put(*m, "id", snow(dm));
	etf.map_put(*m, "type", etf.vint(DM));
	etf.map_put(*m, "last_message_id", ifx last then snow(last) else .{});
	etf.map_put(*m, "flags", etf.vint(0));
	etf.map_put(*m, "recipients", etf.vlist(recipients));
	return etf.vmap(etf.map_done(*m));
}

// READY's private_channels: the member's DMs they haven't closed.
dm_list_locked :: (s: *Server, user: s64) -> etf.Value {
	list: [..]etf.Value;
	list.allocator = temp;
	st := sqlite.prepare(s.db, "SELECT id, CASE WHEN a = ?1 THEN b ELSE a END FROM dms WHERE (a = ?1 OR b = ?1) AND id NOT IN (SELECT dm FROM dm_closed WHERE user = ?1);");
	sqlite.bind(st, 1, user);
	while sqlite.step(st) == .Row array_add(*list, dm_value_locked(s, sqlite.col_int(st, 0), sqlite.col_int(st, 1)));
	sqlite.finalize(st);
	return etf.vlist(list);
}

DM_SELECT :: "SELECT m.id, m.dm, m.author, u.name, m.content, m.nonce, m.flags FROM dm_messages m JOIN users u ON u.id = m.author";

row_dm_message :: (s: *Server, st: *sqlite.Stmt, with_nonce := false) -> etf.Value {
	id := sqlite.col_int(st, 0);
	m := etf.map_builder(13,, temp);
	etf.map_put(*m, "id", snow(id));
	etf.map_put(*m, "type", etf.vint(0));
	etf.map_put(*m, "channel_id", snow(sqlite.col_int(st, 1)));
	etf.map_put(*m, "author", user_value(s, sqlite.col_int(st, 2), copy_string(sqlite.col_text(st, 3),, temp)));
	etf.map_put(*m, "content", etf.vstring(copy_string(sqlite.col_text(st, 4),, temp)));
	etf.map_put(*m, "timestamp", etf.vstring(iso(id)));
	etf.map_put(*m, "edited_timestamp", .{});
	etf.map_put(*m, "flags", etf.vint(sqlite.col_int(st, 6)));
	etf.map_put(*m, "attachments", etf.vlist(.[]));
	etf.map_put(*m, "embeds", etf.vlist(.[]));
	etf.map_put(*m, "mentions", etf.vlist(.[]));
	etf.map_put(*m, "mention_everyone", etf.vbool(false));
	etf.map_put(*m, "pinned", etf.vbool(false));
	if with_nonce && !sqlite.col_is_null(st, 5) etf.map_put(*m, "nonce", etf.vstring(copy_string(sqlite.col_text(st, 5),, temp)));
	return etf.vmap(etf.map_done(*m));
}

// POST /api/v9/users/@me/channels {recipients: [id]} opens the DM with another member, making it the
// first time; it stays closed for them until its first message.
open_dm :: (c: *Conn, req: http.Request) -> bool {
	s := c.server;
	token, _ := http.header_get(req.headers, "authorization");
	user := session_user(c, token);
	if !user return json_error(c, 401, 0, "401: Unauthorized");
	v, err := etf.from_json(cast(string) req.body,, temp);
	if err != .None || v.kind != .Map return json_error(c, 400, 50035, "Invalid Form Body");
	r, _ := etf.map_get(v.map, "recipients");
	// One recipient: a group DM needs E2E's sender keys first.
	if r.kind != .List || r.list.count != 1 || r.list[0].kind != .String return json_error(c, 400, 50035, "Invalid Form Body");
	peer, ok := string_to_int(r.list[0].s, T = s64);
	if !ok || peer == user return json_error(c, 400, 50035, "Invalid Form Body");
	ch: etf.Value;
	{
		locks.guard(*s.db_mu);
		st := sqlite.prepare(s.db, "SELECT 1 FROM users WHERE id = ? AND left = 0 AND banned = 0;");
		sqlite.bind(st, 1, peer);
		member := sqlite.step(st) == .Row;
		sqlite.finalize(st);
		if !member return json_error(c, 400, 50007, "Cannot send messages to this user");
		a, b := min(user, peer), max(user, peer);
		st = sqlite.prepare(s.db, "SELECT id FROM dms WHERE a = ? AND b = ?;");
		sqlite.bind_all(st, a, b);
		dm := ifx sqlite.step(st) == .Row then sqlite.col_int(st, 0) else 0;
		sqlite.finalize(st);
		if !dm {
			dm = snowflake(s);
			ok = sqlite.exec(s.db, "BEGIN;")
				&& sqlite.run(s.db, "INSERT INTO dms(id, a, b) VALUES(?, ?, ?);", dm, a, b)
				&& sqlite.run(s.db, "INSERT INTO dm_closed(dm, user) VALUES(?, ?);", dm, peer)
				&& sqlite.exec(s.db, "COMMIT;");
			if !ok { sqlite.exec(s.db, "ROLLBACK;"); return json_error(c, 500, 0, "500: Internal Server Error"); }
		}
		sqlite.run(s.db, "DELETE FROM dm_closed WHERE dm = ? AND user = ?;", dm, user);
		ch = dm_value_locked(s, dm, peer);
	}
	send_to(s, .[user], "CHANNEL_CREATE", ch);
	return json_reply(c, 200, ch);
}

// dm_route answers everything under /api/v9/channels/{dm}/ for one of its members: closing it, message
// pages, sending, deleting their own, typing and acks.
dm_route :: (c: *Conn, req: http.Request, user: s64, peer: s64, dm: s64, parts: []string, query: string) -> bool {
	s := c.server;
	if parts.count == 1 && req.method == "DELETE" {
		ch: etf.Value;
		{
			locks.guard(*s.db_mu);
			sqlite.run(s.db, "INSERT OR IGNORE INTO dm_closed(dm, user) VALUES(?, ?);", dm, user);
			ch = dm_value_locked(s, dm, peer);
		}
		send_to(s, .[user], "CHANNEL_DELETE", ch);
		return json_reply(c, 200, ch);
	}
	if parts.count == 2 && parts[1] == "typing" && req.method == "POST" {
		d := etf.map_builder(3,, temp);
		etf.map_put(*d, "channel_id", snow(dm));
		etf.map_put(*d, "user_id", snow(user));
		etf.map_put(*d, "timestamp", etf.vint(to_seconds(current_time_consensus() - APOLLO_TIME_FOR_JAN_1_1970)));
		send_to(s, .[peer], "TYPING_START", etf.vmap(etf.map_done(*d)));
		return respond(c, 204, json = false);
	}
	if parts.count < 2 || parts[1] != "messages" return json_error(c, 404, 0, "404: Not Found");
	if parts.count == 4 && parts[3] == "ack" && req.method == "POST" {
		message, ok := string_to_int(parts[2], T = s64);
		if !ok return json_error(c, 404, 0, "404: Not Found");
		return ack(c, req, user, dm, message);
	}
	if parts.count == 3 && req.method == "DELETE" {
		message, ok := string_to_int(parts[2], T = s64);
		if !ok return json_error(c, 404, 0, "404: Not Found");
		{
			locks.guard(*s.db_mu);
			if !sqlite.run(s.db, "DELETE FROM dm_messages WHERE id = ? AND dm = ? AND author = ?;", message, dm, user) return json_error(c, 500, 0, "500: Internal Server Error");
			if sqlite.changes(s.db) != 1 return json_error(c, 404, 10008, "Unknown Message");
		}
		d := etf.map_builder(2,, temp);
		etf.map_put(*d, "id", snow(message));
		etf.map_put(*d, "channel_id", snow(dm));
		send_to(s, .[user, peer], "MESSAGE_DELETE", etf.vmap(etf.map_done(*d)));
		return respond(c, 204, json = false);
	}
	if parts.count != 2 return json_error(c, 404, 0, "404: Not Found");
	sb: String_Builder;
	sb.allocator = temp;
	if req.method == "GET" {
		limit, before, after, around := 50, 0, 0, 0;
		for split(query, "&",, temp) {
			kv := split(it, "=",, temp);
			if kv.count != 2 continue;
			if kv[0] == "limit" limit = clamp(string_to_int(kv[1]), 1, 100);
			if kv[0] == "before" before = string_to_int(kv[1], T = s64);
			if kv[0] == "after" after = string_to_int(kv[1], T = s64);
			if kv[0] == "around" around = string_to_int(kv[1], T = s64);
		}
		list: [..]etf.Value;
		list.allocator = temp;
		{
			locks.guard(*s.db_mu);
			st: *sqlite.Stmt;
			if around {
				st = sqlite.prepare(s.db, tprint("SELECT * FROM (% WHERE m.dm = ? AND m.id > ? ORDER BY m.id LIMIT ?) UNION ALL SELECT * FROM (% WHERE m.dm = ? AND m.id <= ? ORDER BY m.id DESC LIMIT ?) ORDER BY 1 DESC;", DM_SELECT, DM_SELECT));
				sqlite.bind_all(st, dm, around, limit / 2, dm, around, limit - limit / 2);
			} else if after {
				st = sqlite.prepare(s.db, tprint("SELECT * FROM (% WHERE m.dm = ? AND m.id > ? ORDER BY m.id LIMIT ?) ORDER BY 1 DESC;", DM_SELECT));
				sqlite.bind_all(st, dm, after, limit);
			} else {
				st = sqlite.prepare(s.db, tprint("% WHERE m.dm = ? AND (? = 0 OR m.id < ?) ORDER BY m.id DESC LIMIT ?;", DM_SELECT));
				sqlite.bind_all(st, dm, before, before, limit);
			}
			while sqlite.step(st) == .Row array_add(*list, row_dm_message(s, st));
			sqlite.finalize(st);
		}
		etf.to_json(etf.vlist(list), *sb);
		return respond(c, 200, builder_to_string(*sb,, temp));
	}
	if req.method != "POST" return json_error(c, 405, 0, "405: Method Not Allowed");
	v, err := etf.from_json(cast(string) req.body,, temp);
	if err != .None || v.kind != .Map return json_error(c, 400, 50035, "Invalid Form Body");
	content, _ := etf.map_get(v.map, "content");
	nonce, _ := etf.map_get(v.map, "nonce");
	flags_v, _ := etf.map_get(v.map, "flags");
	// Only a packet: no files, stickers, polls, replies or forwards, which would go in the clear.
	for string.["attachments", "sticker_ids", "poll", "message_reference"] {
		x, _ := etf.map_get(v.map, it);
		if x.kind != .Nil && !(x.kind == .List && !x.list.count) return json_error(c, 400, 50035, "Invalid Form Body");
	}
	if content.kind != .String return json_error(c, 400, 50035, "Invalid Form Body");
	_, packet := fc_text.decode(content.s);
	if !packet return json_error(c, 400, 50035, "Invalid Form Body");
	if flags_v.kind != .Int && flags_v.kind != .Nil return json_error(c, 400, 50035, "Invalid Form Body");
	if nonce.kind == .String && nonce.s.count > 25 return json_error(c, 400, 50035, "Invalid Form Body");
	flags := flags_v.i & SUPPRESS_NOTIFICATIONS;
	nonce_s := ifx nonce.kind == .String then nonce.s else "";
	id := snowflake(s);
	m: etf.Value;
	reopened := false;
	{
		locks.guard(*s.db_mu);
		st := sqlite.prepare(s.db, "SELECT 1 FROM users WHERE id = ? AND left = 0 AND banned = 0;");
		sqlite.bind(st, 1, peer);
		member := sqlite.step(st) == .Row;
		sqlite.finalize(st);
		if !member return json_error(c, 400, 50007, "Cannot send messages to this user");
		// A resend whose first reply was lost gets the message it already made.
		if nonce_s {
			st = sqlite.prepare(s.db, tprint("% WHERE m.author = ? AND m.nonce = ? AND m.dm = ? AND m.id > ?;", DM_SELECT));
			sqlite.bind_all(st, user, nonce_s, dm, id - (NONCE_WINDOW_MS << 22));
			if sqlite.step(st) == .Row {
				m = row_dm_message(s, st, with_nonce = true);
				sqlite.finalize(st);
				etf.to_json(m, *sb);
				return respond(c, 200, builder_to_string(*sb,, temp));
			}
			sqlite.finalize(st);
		}
		st = sqlite.prepare(s.db, "SELECT 1 FROM dm_closed WHERE dm = ? AND user = ?;");
		sqlite.bind_all(st, dm, peer);
		reopened = sqlite.step(st) == .Row;
		sqlite.finalize(st);
		// Each unread DM message counts as a mention for the peer, as on Discord; the author has read it.
		ok := sqlite.exec(s.db, "BEGIN;")
			&& sqlite.run(s.db, "INSERT INTO dm_messages(id, dm, author, content, nonce, flags) VALUES(?, ?, ?, ?, nullif(?, ''), ?);", id, dm, user, content.s, nonce_s, flags)
			&& sqlite.run(s.db, "DELETE FROM dm_messages WHERE dm = ?1 AND id NOT IN (SELECT id FROM dm_messages WHERE dm = ?1 ORDER BY id DESC LIMIT ?2);", dm, MAX_DM_MESSAGES)
			&& sqlite.run(s.db, "DELETE FROM dm_closed WHERE dm = ?;", dm)
			&& sqlite.run(s.db, "INSERT INTO read_states(user, channel, last, mentions) VALUES(?, ?, 0, 1) ON CONFLICT(user, channel) DO UPDATE SET mentions = mentions + 1;", peer, dm)
			&& sqlite.run(s.db, "INSERT OR REPLACE INTO read_states(user, channel, last, mentions) VALUES(?, ?, ?, 0);", user, dm, id)
			&& sqlite.exec(s.db, "COMMIT;");
		if !ok { sqlite.exec(s.db, "ROLLBACK;"); return json_error(c, 500, 0, "500: Internal Server Error"); }
		st = sqlite.prepare(s.db, tprint("% WHERE m.id = ?;", DM_SELECT));
		sqlite.bind(st, 1, id);
		if sqlite.step(st) == .Row m = row_dm_message(s, st, with_nonce = true);
		sqlite.finalize(st);
	}
	if reopened {
		ch: etf.Value;
		{
			locks.guard(*s.db_mu);
			ch = dm_value_locked(s, dm, user);
		}
		send_to(s, .[peer], "CHANNEL_CREATE", ch);
	}
	send_to(s, .[user, peer], "MESSAGE_CREATE", m);
	etf.to_json(m, *sb);
	return respond(c, 200, builder_to_string(*sb,, temp));
}

// Each member's prekey bundle: an E2E Hello any of their DMs may answer, so a DM can start while they're
// offline. PUT /api/v9/users/@me/e2e-bundle {bundle} replaces theirs; GET /api/v9/users/{id}/e2e-bundle
// gives another member's. Serve checks only that it's a Hello of the member's own key: the 32 bytes after
// the packet's version and kind are their root.
e2e_bundle :: (c: *Conn, req: http.Request) -> bool {
	s := c.server;
	token, _ := http.header_get(req.headers, "authorization");
	user := session_user(c, token);
	if !user return json_error(c, 401, 0, "401: Unauthorized");
	who := slice(req.path, "/api/v9/users/".count, req.path.count - "/api/v9/users/".count - "/e2e-bundle".count);
	if req.method == "PUT" && who == "@me" {
		v, err := etf.from_json(cast(string) req.body,, temp);
		b: etf.Value;
		if err == .None && v.kind == .Map b, _ = etf.map_get(v.map, "bundle");
		if b.kind != .String return json_error(c, 400, 50035, "Invalid Form Body");
		packet, ok := fc_text.decode(b.s);
		if !ok || packet.count < 34 || packet[1] != HELLO_KIND return json_error(c, 400, 50035, "Invalid Form Body");
		locks.guard(*s.db_mu);
		st := sqlite.prepare(s.db, "SELECT root FROM users WHERE id = ?;");
		sqlite.bind(st, 1, user);
		mine := sqlite.step(st) == .Row && sqlite.col_blob(st, 0).count == 32 && memcmp(sqlite.col_blob(st, 0).data, packet.data + 2, 32) == 0;
		sqlite.finalize(st);
		if !mine return json_error(c, 400, 50035, "Invalid Form Body");
		if !sqlite.run(s.db, "INSERT OR REPLACE INTO e2e_bundles(user, bundle) VALUES(?, ?);", user, b.s) return json_error(c, 500, 0, "500: Internal Server Error");
		return respond(c, 204, json = false);
	}
	id, ok := string_to_int(who, T = s64);
	if req.method != "GET" || !ok return json_error(c, 404, 0, "404: Not Found");
	bundle := "";
	{
		locks.guard(*s.db_mu);
		st := sqlite.prepare(s.db, "SELECT b.bundle FROM e2e_bundles b JOIN users u ON u.id = b.user WHERE b.user = ? AND u.left = 0 AND u.banned = 0;");
		sqlite.bind(st, 1, id);
		if sqlite.step(st) == .Row bundle = copy_string(sqlite.col_text(st, 0),, temp);
		sqlite.finalize(st);
	}
	if !bundle return json_error(c, 404, 10013, "Unknown User");
	m := etf.map_builder(1,, temp);
	etf.map_put(*m, "bundle", etf.vstring(bundle));
	return json_reply(c, 200, etf.vmap(etf.map_done(*m)));
}

HELLO_KIND :: 1; // E2E's packet kind of a Hello (src/e2e/protocol.jai).

// Tests only (the app's serve_member script command): the bundle of the member called name, unchecked.
bundle_for_test :: (s: *Server, name: string, bundle: string) {
	locks.guard(*s.db_mu);
	sqlite.run(s.db, "INSERT OR REPLACE INTO e2e_bundles(user, bundle) SELECT id, ? FROM users WHERE name = ?;", bundle, name);
}
