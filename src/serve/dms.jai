// Direct messages between members: 1:1 DMs and group DMs of up to MAX_GROUP members. Serve is only their
// carrier: every DM message is an end-to-end encrypted packet in its `fc-` text form (`src/fc_text`), and
// anything else is refused, so serve relays and stores what it can't read. A group's packets are the same:
// its members' pairwise sessions and sender keys (E2E 8) are theirs, and serve hands every packet to every
// member. Files are ciphertext too (E2E 7): they upload as for a channel and are kept as opaque bytes,
// named DM_FILE_NAME whatever the client says, up to MAX_DM_FILE_BYTES per DM, the oldest going first. An
// edit replaces a packet with another, which is how E2E edits and deletes. DMs live apart from the guild's
// channels and messages, so nothing guild-wide (READY's channels, search, mentions, audit) lists them; only
// a DM's members see it, its messages, typing and read state. Messages wait here for a member who is
// offline, up to MAX_DM_MESSAGES per DM, the oldest going first. A group's name and icon aren't
// encrypted: serve keeps them, as Discord does.

DM_SCHEMA :: #string SQL
CREATE TABLE IF NOT EXISTS dms(id INTEGER PRIMARY KEY, a INTEGER NOT NULL, b INTEGER NOT NULL, UNIQUE(a, b));
CREATE TABLE IF NOT EXISTS dm_messages(id INTEGER PRIMARY KEY, dm INTEGER NOT NULL, author INTEGER NOT NULL, content TEXT NOT NULL, nonce TEXT, flags INTEGER NOT NULL DEFAULT 0);
CREATE INDEX IF NOT EXISTS dm_messages_dm ON dm_messages(dm, id);
CREATE TABLE IF NOT EXISTS dm_closed(dm INTEGER NOT NULL, user INTEGER NOT NULL, PRIMARY KEY(dm, user));
CREATE TABLE IF NOT EXISTS e2e_bundles(user INTEGER PRIMARY KEY, bundle TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS groups(id INTEGER PRIMARY KEY, owner INTEGER NOT NULL, name TEXT, icon TEXT, icon_type TEXT, icon_data BLOB);
CREATE TABLE IF NOT EXISTS group_members(dm INTEGER NOT NULL, user INTEGER NOT NULL, PRIMARY KEY(dm, user));
CREATE INDEX IF NOT EXISTS group_members_user ON group_members(user);
SQL

MAX_DM_MESSAGES :: 10000;
MAX_DM_FILE_BYTES :: 1 << 30;
DM_FILE_NAME :: "encrypted.bin";
DM :: 1; // Discord's channel types.
GROUP_DM :: 3;
MAX_GROUP :: 10; // A group's members, its creator included, as on Discord.
MAX_GROUP_NAME :: 100;

// dm_peer_locked is the other member of 1:1 DM dm, or 0 when it isn't a 1:1 DM of user's. The caller holds db_mu.
dm_peer_locked :: (s: *Server, dm: s64, user: s64) -> s64 {
	st := sqlite.prepare(s.db, "SELECT CASE WHEN a = ?2 THEN b ELSE a END FROM dms WHERE id = ?1 AND (a = ?2 OR b = ?2);");
	defer sqlite.finalize(st);
	sqlite.bind_all(st, dm, user);
	return ifx sqlite.step(st) == .Row then sqlite.col_int(st, 0) else 0;
}

// group_members_locked lists group dm's members still on the server (temp), oldest first; none for a 1:1 DM.
group_members_locked :: (s: *Server, dm: s64) -> [..]s64 {
	out: [..]s64;
	out.allocator = temp;
	st := sqlite.prepare(s.db, "SELECT g.user FROM group_members g JOIN users u ON u.id = g.user WHERE g.dm = ? AND u.left = 0 AND u.banned = 0 ORDER BY g.rowid;");
	sqlite.bind(st, 1, dm);
	while out.count < MAX_GROUP && sqlite.step(st) == .Row array_add(*out, sqlite.col_int(st, 0));
	sqlite.finalize(st);
	return out;
}

// dm_others_locked: the members of DM dm but user (temp), when user is one; group says it's a group DM.
dm_others_locked :: (s: *Server, dm: s64, user: s64) -> others: [..]s64, member: bool, group: bool {
	peer := dm_peer_locked(s, dm, user);
	if peer {
		others: [..]s64;
		others.allocator = temp;
		array_add(*others, peer);
		return others, true, false;
	}
	all := group_members_locked(s, dm);
	found, i := array_find(all, user);
	if found array_ordered_remove_by_index(*all, i);
	else all.count = 0;
	return all, found, found;
}

dm_member_locked :: (s: *Server, dm: s64, user: s64) -> bool {
	_, member := dm_others_locked(s, dm, user);
	return member;
}

name_locked :: (s: *Server, user: s64) -> string {
	st := sqlite.prepare(s.db, "SELECT name FROM users WHERE id = ?;");
	defer sqlite.finalize(st);
	sqlite.bind(st, 1, user);
	return ifx sqlite.step(st) == .Row then copy_string(sqlite.col_text(st, 0),, temp) else "";
}

on_server_locked :: (s: *Server, user: s64) -> bool {
	st := sqlite.prepare(s.db, "SELECT 1 FROM users WHERE id = ? AND left = 0 AND banned = 0;");
	defer sqlite.finalize(st);
	sqlite.bind(st, 1, user);
	return sqlite.step(st) == .Row;
}

// dm_value is a DM as Discord sends it to viewer, one of its members, with the others as its recipients.
dm_value_locked :: (s: *Server, dm: s64, viewer: s64) -> etf.Value {
	others, _, group := dm_others_locked(s, dm, viewer);
	recipients := NewArray(others.count, etf.Value,, temp);
	for others recipients[it_index] = user_value(s, it, name_locked(s, it));
	last: s64;
	st := sqlite.prepare(s.db, "SELECT max(id) FROM dm_messages WHERE dm = ?;");
	sqlite.bind(st, 1, dm);
	if sqlite.step(st) == .Row last = sqlite.col_int(st, 0);
	sqlite.finalize(st);
	m := etf.map_builder(8,, temp);
	etf.map_put(*m, "id", snow(dm));
	etf.map_put(*m, "type", etf.vint(ifx group then GROUP_DM else DM));
	etf.map_put(*m, "last_message_id", ifx last then snow(last) else .{});
	etf.map_put(*m, "flags", etf.vint(0));
	etf.map_put(*m, "recipients", etf.vlist(recipients));
	if group {
		st = sqlite.prepare(s.db, "SELECT owner, name, icon FROM groups WHERE id = ?;");
		sqlite.bind(st, 1, dm);
		if sqlite.step(st) == .Row {
			etf.map_put(*m, "owner_id", snow(sqlite.col_int(st, 0)));
			etf.map_put(*m, "name", ifx sqlite.col_is_null(st, 1) then etf.Value.{} else etf.vstring(copy_string(sqlite.col_text(st, 1),, temp)));
			etf.map_put(*m, "icon", ifx sqlite.col_is_null(st, 2) then etf.Value.{} else etf.vstring(copy_string(sqlite.col_text(st, 2),, temp)));
		}
		sqlite.finalize(st);
	}
	return etf.vmap(etf.map_done(*m));
}

// READY's private_channels: the member's 1:1 DMs they haven't closed, and their groups.
dm_list_locked :: (s: *Server, user: s64) -> etf.Value {
	ids: [..]s64;
	ids.allocator = temp;
	st := sqlite.prepare(s.db, "SELECT id FROM dms WHERE (a = ?1 OR b = ?1) AND id NOT IN (SELECT dm FROM dm_closed WHERE user = ?1) UNION ALL SELECT dm FROM group_members WHERE user = ?1;");
	sqlite.bind(st, 1, user);
	while sqlite.step(st) == .Row array_add(*ids, sqlite.col_int(st, 0));
	sqlite.finalize(st);
	list := NewArray(ids.count, etf.Value,, temp);
	for ids list[it_index] = dm_value_locked(s, it, user);
	return etf.vlist(list);
}

// send_dm_value sends each of users DM dm as they see it, as event t.
send_dm_value :: (s: *Server, users: []s64, dm: s64, t: string) {
	for users {
		v: etf.Value;
		{
			locks.guard(*s.db_mu);
			v = dm_value_locked(s, dm, it);
		}
		send_to(s, .[it], t, v);
	}
}

// plus is users and one more (temp).
plus :: (users: []s64, user: s64) -> [..]s64 {
	out: [..]s64;
	out.allocator = temp;
	array_add(*out, ..users);
	array_add(*out, user);
	return out;
}

// recipient_event is CHANNEL_RECIPIENT_ADD's or _REMOVE's {channel_id, user}.
recipient_event :: (s: *Server, dm: s64, user: s64) -> etf.Value {
	name: string;
	{
		locks.guard(*s.db_mu);
		name = name_locked(s, user);
	}
	d := etf.map_builder(2,, temp);
	etf.map_put(*d, "channel_id", snow(dm));
	etf.map_put(*d, "user", user_value(s, user, name));
	return etf.vmap(etf.map_done(*d));
}

DM_SELECT :: "SELECT m.id, m.dm, m.author, u.name, m.content, m.nonce, m.flags, m.edited FROM dm_messages m JOIN users u ON u.id = m.author";

row_dm_message :: (s: *Server, st: *sqlite.Stmt, with_nonce := false) -> etf.Value {
	id := sqlite.col_int(st, 0);
	m := etf.map_builder(13,, temp);
	etf.map_put(*m, "id", snow(id));
	etf.map_put(*m, "type", etf.vint(0));
	etf.map_put(*m, "channel_id", snow(sqlite.col_int(st, 1)));
	etf.map_put(*m, "author", user_value(s, sqlite.col_int(st, 2), copy_string(sqlite.col_text(st, 3),, temp)));
	etf.map_put(*m, "content", etf.vstring(copy_string(sqlite.col_text(st, 4),, temp)));
	etf.map_put(*m, "timestamp", etf.vstring(iso(id)));
	etf.map_put(*m, "edited_timestamp", ifx sqlite.col_is_null(st, 7) then etf.Value.{} else etf.vstring(iso(sqlite.col_int(st, 7))));
	etf.map_put(*m, "flags", etf.vint(sqlite.col_int(st, 6)));
	etf.map_put(*m, "attachments", attachments_locked(s, id));
	etf.map_put(*m, "embeds", etf.vlist(.[]));
	etf.map_put(*m, "mentions", etf.vlist(.[]));
	etf.map_put(*m, "mention_everyone", etf.vbool(false));
	etf.map_put(*m, "pinned", etf.vbool(false));
	if with_nonce && !sqlite.col_is_null(st, 5) etf.map_put(*m, "nonce", etf.vstring(copy_string(sqlite.col_text(st, 5),, temp)));
	return etf.vmap(etf.map_done(*m));
}

// POST /api/v9/users/@me/channels {recipients: [id...]}: one member opens the DM with them, making it the
// first time (it stays closed for them until its first message); none or several make a new group DM of
// at most MAX_GROUP, owned by its creator.
open_dm :: (c: *Conn, req: http.Request) -> bool {
	s := c.server;
	token, _ := http.header_get(req.headers, "authorization");
	user := session_user(c, token);
	if !user return json_error(c, 401, 0, "401: Unauthorized");
	v, err := etf.from_json(cast(string) req.body,, temp);
	if err != .None || v.kind != .Map return json_error(c, 400, 50035, "Invalid Form Body");
	r, _ := etf.map_get(v.map, "recipients");
	if r.kind != .List || r.list.count > MAX_GROUP - 1 return json_error(c, 400, 50035, "Invalid Form Body");
	ids: [..]s64;
	ids.allocator = temp;
	for r.list {
		id, ok := string_to_int(ifx it.kind == .String then it.s else "", T = s64);
		if !ok || id == user || array_find(ids, id) return json_error(c, 400, 50035, "Invalid Form Body");
		array_add(*ids, id);
	}
	ch: etf.Value;
	members: [..]s64;
	members.allocator = temp;
	group: s64;
	{
		locks.guard(*s.db_mu);
		for ids if !on_server_locked(s, it) return json_error(c, 400, 50007, "Cannot send messages to this user");
		if ids.count != 1 {
			group = snowflake(s);
			array_add(*members, user);
			array_add(*members, ..ids);
			ok := sqlite.exec(s.db, "BEGIN;") && sqlite.run(s.db, "INSERT INTO groups(id, owner) VALUES(?, ?);", group, user);
			for members ok = ok && sqlite.run(s.db, "INSERT INTO group_members(dm, user) VALUES(?, ?);", group, it);
			if !ok || !sqlite.exec(s.db, "COMMIT;") { sqlite.exec(s.db, "ROLLBACK;"); return json_error(c, 500, 0, "500: Internal Server Error"); }
			ch = dm_value_locked(s, group, user);
		} else {
			peer := ids[0];
			a, b := min(user, peer), max(user, peer);
			st := sqlite.prepare(s.db, "SELECT id FROM dms WHERE a = ? AND b = ?;");
			sqlite.bind_all(st, a, b);
			dm := ifx sqlite.step(st) == .Row then sqlite.col_int(st, 0) else 0;
			sqlite.finalize(st);
			if !dm {
				dm = snowflake(s);
				ok := sqlite.exec(s.db, "BEGIN;")
					&& sqlite.run(s.db, "INSERT INTO dms(id, a, b) VALUES(?, ?, ?);", dm, a, b)
					&& sqlite.run(s.db, "INSERT INTO dm_closed(dm, user) VALUES(?, ?);", dm, peer)
					&& sqlite.exec(s.db, "COMMIT;");
				if !ok { sqlite.exec(s.db, "ROLLBACK;"); return json_error(c, 500, 0, "500: Internal Server Error"); }
			}
			sqlite.run(s.db, "DELETE FROM dm_closed WHERE dm = ? AND user = ?;", dm, user);
			ch = dm_value_locked(s, dm, user);
		}
	}
	send_to(s, .[user], "CHANNEL_CREATE", ch);
	if members send_dm_value(s, array_view(members, 1), group, "CHANNEL_CREATE");
	return json_reply(c, 200, ch);
}

// group_route answers what only a group DM has, for one of its members: leaving it (DELETE, ?silent is
// all the same here), its name, icon and owner (PATCH; only the owner hands it on), and adding or, for the
// owner, removing members (PUT/DELETE recipients/{user}). Each member is told of what changed: the one who
// joined or went gets CHANNEL_CREATE or CHANNEL_DELETE, the others CHANNEL_RECIPIENT_ADD or _REMOVE.
group_route :: (c: *Conn, req: http.Request, user: s64, others: []s64, dm: s64, parts: []string) -> bool {
	s := c.server;
	owner: s64;
	{
		locks.guard(*s.db_mu);
		st := sqlite.prepare(s.db, "SELECT owner FROM groups WHERE id = ?;");
		sqlite.bind(st, 1, dm);
		if sqlite.step(st) == .Row owner = sqlite.col_int(st, 0);
		sqlite.finalize(st);
	}
	if parts.count == 3 && parts[1] == "recipients" && (req.method == "PUT" || req.method == "DELETE") {
		who, ok := string_to_int(parts[2], T = s64);
		if !ok return json_error(c, 404, 0, "404: Not Found");
		ch: etf.Value;
		if req.method == "PUT" {
			if array_find(others, who) || who == user return respond(c, 204, json = false);
			if others.count + 1 >= MAX_GROUP return json_error(c, 400, 50035, "Invalid Form Body");
			{
				locks.guard(*s.db_mu);
				if !on_server_locked(s, who) return json_error(c, 400, 50007, "Cannot send messages to this user");
				if !sqlite.run(s.db, "INSERT OR IGNORE INTO group_members(dm, user) VALUES(?, ?);", dm, who) return json_error(c, 500, 0, "500: Internal Server Error");
			}
			send_dm_value(s, .[who], dm, "CHANNEL_CREATE");
			send_to(s, plus(others, user), "CHANNEL_RECIPIENT_ADD", recipient_event(s, dm, who));
			return respond(c, 204, json = false);
		}
		if who == user return leave_group(c, user, others, dm, owner);
		if user != owner return json_error(c, 403, 50013, "Missing Permissions");
		if !array_find(others, who) return json_error(c, 404, 10013, "Unknown User");
		{
			locks.guard(*s.db_mu);
			ch = dm_value_locked(s, dm, who);
			if !sqlite.run(s.db, "DELETE FROM group_members WHERE dm = ? AND user = ?;", dm, who) return json_error(c, 500, 0, "500: Internal Server Error");
		}
		send_to(s, .[who], "CHANNEL_DELETE", ch);
		rest := plus(others, user);
		array_ordered_remove_by_value(*rest, who);
		send_to(s, rest, "CHANNEL_RECIPIENT_REMOVE", recipient_event(s, dm, who));
		return respond(c, 204, json = false);
	}
	if parts.count != 1 return json_error(c, 404, 0, "404: Not Found");
	if req.method == "DELETE" return leave_group(c, user, others, dm, owner);
	if req.method != "PATCH" return json_error(c, 405, 0, "405: Method Not Allowed");
	v, err := etf.from_json(cast(string) req.body,, temp);
	if err != .None || v.kind != .Map return json_error(c, 400, 50035, "Invalid Form Body");
	name_v, has_name := etf.map_get(v.map, "name");
	icon_v, has_icon := etf.map_get(v.map, "icon");
	owner_v, has_owner := etf.map_get(v.map, "owner");
	name := ifx name_v.kind == .String then trim(name_v.s) else "";
	if has_name && ((name_v.kind != .String && name_v.kind != .Nil) || name.count > MAX_GROUP_NAME) return json_error(c, 400, 50035, "Invalid Form Body");
	icon: []u8;
	format: imagefmt.Format;
	if has_icon && icon_v.kind != .Nil {
		ok: bool;
		icon, format, ok = image_data_uri(ifx icon_v.kind == .String then icon_v.s else "", ICON_MAX_BYTES);
		if !ok return json_error(c, 400, 50035, "Invalid Form Body");
	}
	new_owner: s64;
	if has_owner {
		ok: bool;
		new_owner, ok = string_to_int(ifx owner_v.kind == .String then owner_v.s else "", T = s64);
		if user != owner return json_error(c, 403, 50013, "Missing Permissions");
		if !ok || !array_find(others, new_owner) return json_error(c, 400, 50035, "Invalid Form Body");
	}
	{
		locks.guard(*s.db_mu);
		ok := sqlite.exec(s.db, "BEGIN;")
			&& (!has_name || sqlite.run(s.db, "UPDATE groups SET name = nullif(?, '') WHERE id = ?;", name, dm))
			&& (!has_icon || (ifx icon
				then sqlite.run(s.db, "UPDATE groups SET icon = ?, icon_type = ?, icon_data = ? WHERE id = ?;", image_hash(format), IMAGE_TYPES[cast(int) format], icon, dm)
				else sqlite.run(s.db, "UPDATE groups SET icon = NULL, icon_type = NULL, icon_data = NULL WHERE id = ?;", dm)))
			&& (!has_owner || sqlite.run(s.db, "UPDATE groups SET owner = ? WHERE id = ?;", new_owner, dm))
			&& sqlite.exec(s.db, "COMMIT;");
		if !ok { sqlite.exec(s.db, "ROLLBACK;"); return json_error(c, 500, 0, "500: Internal Server Error"); }
	}
	send_dm_value(s, plus(others, user), dm, "CHANNEL_UPDATE");
	ch: etf.Value;
	{
		locks.guard(*s.db_mu);
		ch = dm_value_locked(s, dm, user);
	}
	return json_reply(c, 200, ch);
}

// leave_group takes user out of the group: an owner's goes to the member who joined first after them, and
// a group with no one left goes with its messages and files.
leave_group :: (c: *Conn, user: s64, others: []s64, dm: s64, owner: s64) -> bool {
	s := c.server;
	ch: etf.Value;
	{
		locks.guard(*s.db_mu);
		ch = dm_value_locked(s, dm, user);
		ok := sqlite.exec(s.db, "BEGIN;")
			&& sqlite.run(s.db, "DELETE FROM group_members WHERE dm = ? AND user = ?;", dm, user)
			&& (user != owner || !others.count || sqlite.run(s.db, "UPDATE groups SET owner = ? WHERE id = ?;", others[0], dm));
		if ok && !others.count {
			ok = sqlite.run(s.db, "DELETE FROM attachments WHERE message IN (SELECT id FROM dm_messages WHERE dm = ?);", dm)
				&& sqlite.run(s.db, "DELETE FROM dm_messages WHERE dm = ?;", dm)
				&& sqlite.run(s.db, "DELETE FROM group_members WHERE dm = ?;", dm)
				&& sqlite.run(s.db, "DELETE FROM groups WHERE id = ?;", dm);
		}
		if !ok || !sqlite.exec(s.db, "COMMIT;") { sqlite.exec(s.db, "ROLLBACK;"); return json_error(c, 500, 0, "500: Internal Server Error"); }
	}
	send_to(s, .[user], "CHANNEL_DELETE", ch);
	if others.count {
		send_to(s, others, "CHANNEL_RECIPIENT_REMOVE", recipient_event(s, dm, user));
		if user == owner send_dm_value(s, others, dm, "CHANNEL_UPDATE");
	}
	return json_reply(c, 200, ch);
}

// dm_route answers everything under /api/v9/channels/{dm}/ for one of its members: closing it, message
// pages, sending, deleting their own, typing and acks, and in a group what group_route does.
dm_route :: (c: *Conn, req: http.Request, user: s64, others: []s64, group: bool, dm: s64, parts: []string, query: string) -> bool {
	s := c.server;
	everyone := plus(others, user);
	if group && (parts.count == 1 || (parts.count >= 2 && parts[1] == "recipients")) return group_route(c, req, user, others, dm, parts);
	if parts.count == 1 && req.method == "DELETE" {
		ch: etf.Value;
		{
			locks.guard(*s.db_mu);
			sqlite.run(s.db, "INSERT OR IGNORE INTO dm_closed(dm, user) VALUES(?, ?);", dm, user);
			ch = dm_value_locked(s, dm, user);
		}
		send_to(s, .[user], "CHANNEL_DELETE", ch);
		return json_reply(c, 200, ch);
	}
	if parts.count == 2 && parts[1] == "typing" && req.method == "POST" {
		d := etf.map_builder(3,, temp);
		etf.map_put(*d, "channel_id", snow(dm));
		etf.map_put(*d, "user_id", snow(user));
		etf.map_put(*d, "timestamp", etf.vint(to_seconds(current_time_consensus() - APOLLO_TIME_FOR_JAN_1_1970)));
		send_to(s, others, "TYPING_START", etf.vmap(etf.map_done(*d)));
		return respond(c, 204, json = false);
	}
	if parts.count == 2 && parts[1] == "attachments" && req.method == "POST" return request_uploads(c, req, user, dm, dm = true);
	if parts.count < 2 || parts[1] != "messages" return json_error(c, 404, 0, "404: Not Found");
	if parts.count == 4 && parts[3] == "ack" && req.method == "POST" {
		message, ok := string_to_int(parts[2], T = s64);
		if !ok return json_error(c, 404, 0, "404: Not Found");
		return ack(c, req, user, dm, message);
	}
	if parts.count == 3 && req.method == "PATCH" {
		// An edit: the author's packet replaced by another. Nothing else of a DM message changes.
		message, ok := string_to_int(parts[2], T = s64);
		v, err := etf.from_json(cast(string) req.body,, temp);
		content: etf.Value;
		if err == .None && v.kind == .Map content, _ = etf.map_get(v.map, "content");
		if !ok || content.kind != .String return json_error(c, 400, 50035, "Invalid Form Body");
		_, packet := fc_text.decode(content.s);
		if !packet return json_error(c, 400, 50035, "Invalid Form Body");
		m: etf.Value;
		{
			locks.guard(*s.db_mu);
			if !sqlite.run(s.db, "UPDATE dm_messages SET content = ?, edited = ? WHERE id = ? AND dm = ? AND author = ?;", content.s, snowflake(s), message, dm, user) return json_error(c, 500, 0, "500: Internal Server Error");
			if sqlite.changes(s.db) != 1 return json_error(c, 404, 10008, "Unknown Message");
			st := sqlite.prepare(s.db, tprint("% WHERE m.id = ?;", DM_SELECT));
			sqlite.bind(st, 1, message);
			if sqlite.step(st) == .Row m = row_dm_message(s, st);
			sqlite.finalize(st);
		}
		send_to(s, everyone, "MESSAGE_UPDATE", m);
		return json_reply(c, 200, m);
	}
	if parts.count == 3 && req.method == "DELETE" {
		message, ok := string_to_int(parts[2], T = s64);
		if !ok return json_error(c, 404, 0, "404: Not Found");
		{
			locks.guard(*s.db_mu);
			ok = sqlite.exec(s.db, "BEGIN;")
				&& sqlite.run(s.db, "DELETE FROM attachments WHERE message = (SELECT id FROM dm_messages WHERE id = ? AND dm = ? AND author = ?);", message, dm, user)
				&& sqlite.run(s.db, "DELETE FROM dm_messages WHERE id = ? AND dm = ? AND author = ?;", message, dm, user);
			found := sqlite.changes(s.db) == 1;
			if !ok || !sqlite.exec(s.db, "COMMIT;") { sqlite.exec(s.db, "ROLLBACK;"); return json_error(c, 500, 0, "500: Internal Server Error"); }
			if !found return json_error(c, 404, 10008, "Unknown Message");
		}
		d := etf.map_builder(2,, temp);
		etf.map_put(*d, "id", snow(message));
		etf.map_put(*d, "channel_id", snow(dm));
		send_to(s, everyone, "MESSAGE_DELETE", etf.vmap(etf.map_done(*d)));
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
	// Only a packet and its files: no stickers, polls, replies or forwards, which would go in the clear.
	atts, _ := etf.map_get(v.map, "attachments");
	if (atts.kind != .Nil && atts.kind != .List) || (atts.kind == .List && atts.list.count > MAX_UPLOADS) return json_error(c, 400, 50035, "Invalid Form Body");
	for string.["sticker_ids", "poll", "message_reference"] {
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
		if !group && !on_server_locked(s, others[0]) return json_error(c, 400, 50007, "Cannot send messages to this user");
		// A resend whose first reply was lost gets the message it already made.
		if nonce_s {
			st := sqlite.prepare(s.db, tprint("% WHERE m.author = ? AND m.nonce = ? AND m.dm = ? AND m.id > ?;", DM_SELECT));
			sqlite.bind_all(st, user, nonce_s, dm, id - (NONCE_WINDOW_MS << 22));
			if sqlite.step(st) == .Row {
				m = row_dm_message(s, st, with_nonce = true);
				sqlite.finalize(st);
				etf.to_json(m, *sb);
				return respond(c, 200, builder_to_string(*sb,, temp));
			}
			sqlite.finalize(st);
		}
		if !group {
			st := sqlite.prepare(s.db, "SELECT 1 FROM dm_closed WHERE dm = ? AND user = ?;");
			sqlite.bind_all(st, dm, others[0]);
			reopened = sqlite.step(st) == .Row;
			sqlite.finalize(st);
		}
		// Each unread DM message counts as a mention for the other members, as on Discord; the author has read it.
		ok := sqlite.exec(s.db, "BEGIN;")
			&& sqlite.run(s.db, "INSERT INTO dm_messages(id, dm, author, content, nonce, flags) VALUES(?, ?, ?, ?, nullif(?, ''), ?);", id, dm, user, content.s, nonce_s, flags);
		if atts.kind == .List for a: atts.list {
			// Each a ciphertext uploaded to this DM: named and typed alike, so serve says nothing of what it is.
			token: etf.Value;
			if a.kind == .Map token, _ = etf.map_get(a.map, "uploaded_filename");
			key: [8]u8;
			crypto.random_bytes(key);
			ok = ok && token.kind == .String && sqlite.run(s.db, "INSERT INTO attachments(id, message, key, filename, content_type, size, width, height, description, data) SELECT ?, ?, ?, ?, 'application/octet-stream', size, 0, 0, '', data FROM uploads WHERE token = ? AND user = ? AND channel = ? AND data IS NOT NULL;",
					snowflake(s), id, hex(key,, temp), DM_FILE_NAME, token.s, user, dm)
				&& sqlite.changes(s.db) == 1 && sqlite.run(s.db, "DELETE FROM uploads WHERE token = ?;", token.s);
			if !ok { sqlite.exec(s.db, "ROLLBACK;"); return json_error(c, 400, 50035, "Invalid Form Body"); }
		}
		ok = ok
			&& sqlite.run(s.db, "DELETE FROM attachments WHERE message IN (SELECT id FROM dm_messages WHERE dm = ?1 AND id NOT IN (SELECT id FROM dm_messages WHERE dm = ?1 ORDER BY id DESC LIMIT ?2));", dm, MAX_DM_MESSAGES)
			&& sqlite.run(s.db, "DELETE FROM dm_messages WHERE dm = ?1 AND id NOT IN (SELECT id FROM dm_messages WHERE dm = ?1 ORDER BY id DESC LIMIT ?2);", dm, MAX_DM_MESSAGES)
			&& sqlite.run(s.db, "DELETE FROM attachments WHERE id IN (SELECT id FROM (SELECT a.id, sum(a.size) OVER (ORDER BY a.id DESC) AS total FROM attachments a JOIN dm_messages m ON m.id = a.message WHERE m.dm = ?) WHERE total > ?);", dm, MAX_DM_FILE_BYTES)
			&& sqlite.run(s.db, "DELETE FROM dm_closed WHERE dm = ?;", dm);
		for others ok = ok && sqlite.run(s.db, "INSERT INTO read_states(user, channel, last, mentions) VALUES(?, ?, 0, 1) ON CONFLICT(user, channel) DO UPDATE SET mentions = mentions + 1;", it, dm);
		ok = ok
			&& sqlite.run(s.db, "INSERT OR REPLACE INTO read_states(user, channel, last, mentions) VALUES(?, ?, ?, 0);", user, dm, id)
			&& sqlite.exec(s.db, "COMMIT;");
		if !ok { sqlite.exec(s.db, "ROLLBACK;"); return json_error(c, 500, 0, "500: Internal Server Error"); }
		st := sqlite.prepare(s.db, tprint("% WHERE m.id = ?;", DM_SELECT));
		sqlite.bind(st, 1, id);
		if sqlite.step(st) == .Row m = row_dm_message(s, st, with_nonce = true);
		sqlite.finalize(st);
	}
	if reopened send_dm_value(s, others, dm, "CHANNEL_CREATE");
	send_to(s, everyone, "MESSAGE_CREATE", m);
	etf.to_json(m, *sb);
	return respond(c, 200, builder_to_string(*sb,, temp));
}

// GET /channel-icons/{dm}/{hash}.{ext}: a group's icon, served as the server's: the random hash is what
// makes it unguessable.
group_icon :: (c: *Conn, path: string) -> bool {
	s := c.server;
	parts := split(advance(path, "/channel-icons/".count), "/",, temp);
	dm, ok := string_to_int(parts[0], T = s64);
	if !ok || parts.count != 2 return json_error(c, 404, 0, "404: Not Found");
	hash := parts[1];
	dot := find_index_from_left(hash, #char ".");
	if dot >= 0 hash.count = dot;
	locks.guard(*s.db_mu);
	st := sqlite.prepare(s.db, "SELECT icon_type, icon_data FROM groups WHERE id = ? AND icon = ?;");
	defer sqlite.finalize(st);
	sqlite.bind_all(st, dm, hash);
	if sqlite.step(st) != .Row return json_error(c, 404, 0, "404: Not Found");
	c.reply_status, c.reply_json = 200, false;
	c.reply_type = copy_string(sqlite.col_text(st, 0),, temp);
	c.reply_body = copy_string(cast(string) sqlite.col_blob(st, 1),, temp);
	return true;
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
		packet, ok := fc_text.decode(b.s, fc_text.MAX_BUNDLE);
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
