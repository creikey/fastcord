// Stickers, and renaming and deleting custom emoji. The owner uploads stickers (PNG, APNG, GIF or Lottie,
// 512 KB, checked by magic bytes or as JSON and never decoded here), READY, GUILD_STICKERS_UPDATE and
// GET /guilds/{id}/stickers list them, /stickers/{id}.{ext} serves them, and a message carries up to 3 as
// `sticker_ids`, sent back as `sticker_items`. The shapes are Discord's; Discord's own sticker packs are
// its files, so a hosted server has none.

STICKER_MAX_BYTES :: 512 * 1024; // Discord's cap per sticker
MAX_STICKERS :: 60; // Discord's largest slot count (boost level 3); a hosted server has every slot
MAX_MESSAGE_STICKERS :: 3;
MAX_FORM_PARTS :: 8;

// Discord's sticker format types.
STICKER_PNG :: 1;
STICKER_APNG :: 2;
STICKER_LOTTIE :: 3;
STICKER_GIF :: 4;
STICKER_TYPES :: string.["", "image/png", "image/png", "application/json", "image/gif"];

AUDIT_STICKER_CREATE :: 90;
AUDIT_STICKER_UPDATE :: 91;
AUDIT_STICKER_DELETE :: 92;

STICKER_SCHEMA :: "CREATE TABLE IF NOT EXISTS stickers(id INTEGER PRIMARY KEY, name TEXT NOT NULL, description TEXT NOT NULL, tags TEXT NOT NULL, format INTEGER NOT NULL, data BLOB NOT NULL, user INTEGER NOT NULL);";

STICKER_SELECT :: "SELECT s.id, s.name, s.description, s.tags, s.format, s.user, u.name FROM stickers s JOIN users u ON u.id = s.user";

// row_sticker reads a STICKER_SELECT row as Discord sends a guild sticker; the uploader only for those
// who manage them, as on Discord.
row_sticker :: (s: *Server, st: *sqlite.Stmt, with_user: bool) -> etf.Value {
	m := etf.map_builder(10,, temp);
	etf.map_put(*m, "id", snow(sqlite.col_int(st, 0)));
	etf.map_put(*m, "name", etf.vstring(copy_string(sqlite.col_text(st, 1),, temp)));
	etf.map_put(*m, "description", etf.vstring(copy_string(sqlite.col_text(st, 2),, temp)));
	etf.map_put(*m, "tags", etf.vstring(copy_string(sqlite.col_text(st, 3),, temp)));
	etf.map_put(*m, "type", etf.vint(2));
	etf.map_put(*m, "format_type", etf.vint(sqlite.col_int(st, 4)));
	etf.map_put(*m, "asset", etf.vstring(""));
	etf.map_put(*m, "available", etf.vbool(true));
	etf.map_put(*m, "guild_id", snow(s.guild));
	if with_user etf.map_put(*m, "user", user_value(s, sqlite.col_int(st, 5), copy_string(sqlite.col_text(st, 6),, temp)));
	return etf.vmap(etf.map_done(*m));
}

// The server's stickers, oldest first; the caller holds db_mu.
sticker_list_locked :: (s: *Server, with_user := false) -> etf.Value {
	list: [..]etf.Value;
	list.allocator = temp;
	st := sqlite.prepare(s.db, tprint("% ORDER BY s.id;", STICKER_SELECT));
	defer sqlite.finalize(st);
	while sqlite.step(st) == .Row array_add(*list, row_sticker(s, st, with_user));
	return etf.vlist(list);
}

// sticker_items_locked checks a send's `sticker_ids` (at most 3 of this server's) and returns the
// message's `sticker_items` as JSON to keep with it, "" for none; false when one is bad. Kept with the
// message, so a sticker deleted later still names itself, as on Discord.
sticker_items_locked :: (s: *Server, ids: etf.Value) -> string, bool {
	if ids.kind == .Nil return "", true;
	if ids.kind != .List || ids.list.count > MAX_MESSAGE_STICKERS return "", false;
	if !ids.list.count return "", true;
	items: [..]etf.Value;
	items.allocator = temp;
	for ids.list {
		id, ok := string_to_int(ifx it.kind == .String then it.s else "", T = s64);
		if !ok return "", false;
		st := sqlite.prepare(s.db, "SELECT name, format FROM stickers WHERE id = ?;");
		sqlite.bind_all(st, id);
		found := sqlite.step(st) == .Row;
		m := etf.map_builder(3,, temp);
		if found {
			etf.map_put(*m, "id", snow(id));
			etf.map_put(*m, "name", etf.vstring(copy_string(sqlite.col_text(st, 0),, temp)));
			etf.map_put(*m, "format_type", etf.vint(sqlite.col_int(st, 1)));
		}
		sqlite.finalize(st);
		if !found return "", false;
		array_add(*items, etf.vmap(etf.map_done(*m)));
	}
	sb: String_Builder;
	sb.allocator = temp;
	etf.to_json(etf.vlist(items), *sb);
	return builder_to_string(*sb,, temp), true;
}

// The routes: /api/v9/guilds/{id}/stickers[/{sticker}], /api/v9/stickers/{sticker} and
// /api/v9/guilds/{id}/emojis[/{emoji}]. Adding takes Create Expressions, and whoever added one may edit or
// delete it; anyone else's takes Manage Expressions, as on Discord.
expressions :: (c: *Conn, req: http.Request) -> bool {
	s := c.server;
	emojis := tprint("/api/v9/guilds/%/emojis", s.guild);
	if req.method == "POST" && req.path == emojis return create_emoji(c, req);
	token, _ := http.header_get(req.headers, "authorization");
	user := session_user(c, token);
	if !user return json_error(c, 401, 0, "401: Unauthorized");
	is_emoji := begins_with(req.path, emojis);
	base := ifx is_emoji then emojis else tprint("/api/v9/guilds/%/stickers", s.guild);
	unknown :: (c: *Conn, is_emoji: bool) -> bool { return ifx is_emoji then json_error(c, 404, 10014, "Unknown Emoji") else json_error(c, 404, 10060, "Unknown Sticker"); }
	id: s64;
	if begins_with(req.path, "/api/v9/stickers/") {
		if req.method != "GET" return json_error(c, 405, 0, "405: Method Not Allowed");
		ok: bool;
		id, ok = string_to_int(advance(req.path, "/api/v9/stickers/".count), T = s64);
		if !ok return unknown(c, false);
	} else if req.path != base {
		ok: bool;
		id, ok = string_to_int(advance(req.path, base.count + 1), T = s64);
		if !ok || req.path[base.count] != #char "/" return unknown(c, is_emoji);
	}
	if req.method == "GET" {
		locks.guard(*s.db_mu);
		owner := can_locked(s, user, P_MANAGE_GUILD_EXPRESSIONS); // Manages everyone's.
		if !id return json_reply(c, 200, ifx is_emoji then emoji_list_locked(s, with_user = owner) else sticker_list_locked(s, owner));
		if is_emoji {
			for emoji_list_locked(s, with_user = owner).list if etf.map_get(it.map, "id").s == tprint("%", id) return json_reply(c, 200, it);
			return unknown(c, true);
		}
		st := sqlite.prepare(s.db, tprint("% WHERE s.id = ?;", STICKER_SELECT));
		defer sqlite.finalize(st);
		sqlite.bind_all(st, id);
		if sqlite.step(st) != .Row return unknown(c, false);
		return json_reply(c, 200, row_sticker(s, st, owner));
	}
	if (id == 0) != (req.method == "POST") || (id && req.method != "PATCH" && req.method != "DELETE") return json_error(c, 405, 0, "405: Method Not Allowed");
	reason, reason_ok := audit_reason(req);
	if !reason_ok return json_error(c, 400, 50035, "Invalid Form Body");

	// The fields: a sticker's POST is multipart (name, tags, description, file), every PATCH is JSON.
	name, tags, description, file: string;
	has_name, has_tags, has_description: bool;
	if req.method == "POST" {
		type, _ := http.header_get(req.headers, "content-type");
		parts, ok := form_parts(type, cast(string) req.body);
		if !ok return json_error(c, 400, 50035, "Invalid Form Body");
		for parts {
			if it.name == "name" { name = it.data; has_name = true; }
			else if it.name == "tags" { tags = it.data; has_tags = true; }
			else if it.name == "description" { description = it.data; has_description = true; }
			else if it.name == "file" file = it.data;
		}
		if !has_name || !has_tags || !file return json_error(c, 400, 50035, "Invalid Form Body");
	} else if req.method == "PATCH" {
		v, err := etf.from_json(cast(string) req.body,, temp);
		if err != .None || v.kind != .Map return json_error(c, 400, 50035, "Invalid Form Body");
		text :: (v: etf.Value, k: string, out: *string) -> has: bool, ok: bool {
			f, has := etf.map_get(v.map, k);
			if f.kind == .String out.* = f.s;
			return has, !has || f.kind == .String || f.kind == .Nil;
		}
		ok1, ok2, ok3: bool;
		has_name, ok1 = text(v, "name", *name);
		has_tags, ok2 = text(v, "tags", *tags);
		has_description, ok3 = text(v, "description", *description);
		if !ok1 || !ok2 || !ok3 return json_error(c, 400, 50035, "Invalid Form Body");
	}
	name, tags, description = trim(name), trim(tags), trim(description);
	if is_emoji {
		if has_name && !emoji_name_ok(name) return json_error(c, 400, 50035, "Invalid Form Body");
	} else {
		// Discord's limits: a name of 2-30, tags (the related emoji) of up to 200, a description of 2-100 or none.
		if has_name && (name.count < 2 || name.count > 30 || !text_ok(name)) return json_error(c, 400, 50035, "Invalid Form Body");
		if has_tags && (!tags || tags.count > 200 || !text_ok(tags)) return json_error(c, 400, 50035, "Invalid Form Body");
		if has_description && (description.count == 1 || description.count > 100 || !text_ok(description)) return json_error(c, 400, 50035, "Invalid Form Body");
	}
	format := 0;
	if file {
		format = sticker_format(file);
		if !format return json_error(c, 400, 50046, "Invalid Asset");
	}

	table := ifx is_emoji then "emojis" else "stickers";
	result, list: etf.Value;
	{
		locks.guard(*s.db_mu);
		owner := can_locked(s, user, P_MANAGE_GUILD_EXPRESSIONS); // Manages everyone's.
		if id == 0 {
			if !can_any_locked(s, user, P_CREATE_GUILD_EXPRESSIONS | P_MANAGE_GUILD_EXPRESSIONS) return json_error(c, 403, 50013, "Missing Permissions");
			st := sqlite.prepare(s.db, "SELECT count(*) FROM stickers;");
			n := ifx sqlite.step(st) == .Row then sqlite.col_int(st, 0) else 0;
			sqlite.finalize(st);
			if n >= MAX_STICKERS return json_error(c, 400, 30039, tprint("Maximum number of stickers reached (%)", MAX_STICKERS));
			id = snowflake(s);
			if !sqlite.run(s.db, "INSERT INTO stickers(id, name, description, tags, format, data, user) VALUES(?, ?, ?, ?, ?, ?, ?);", id, name, description, tags, format, cast([]u8) file, user) {
				return json_error(c, 500, 0, "500: Internal Server Error");
			}
			audit_locked(s, user, AUDIT_STICKER_CREATE, id, .[audit_change("name", .{}, etf.vstring(name)), audit_change("tags", .{}, etf.vstring(tags))], reason);
		} else {
			st := sqlite.prepare(s.db, tprint("SELECT user, name FROM % WHERE id = ?;", table));
			sqlite.bind_all(st, id);
			found := sqlite.step(st) == .Row;
			creator := ifx found then sqlite.col_int(st, 0) else 0;
			old_name := ifx found then copy_string(sqlite.col_text(st, 1),, temp) else "";
			sqlite.finalize(st);
			if !found return unknown(c, is_emoji);
			if !owner && creator != user return json_error(c, 403, 50013, "Missing Permissions");
			ok := true;
			changes: [..]etf.Value;
			changes.allocator = temp;
			if req.method == "DELETE" {
				ok = sqlite.run(s.db, tprint("DELETE FROM % WHERE id = ?;", table), id);
				array_add(*changes, audit_change("name", etf.vstring(old_name), .{}));
			} else {
				if has_name {
					ok = sqlite.run(s.db, tprint("UPDATE % SET name = ? WHERE id = ?;", table), name, id);
					array_add(*changes, audit_change("name", etf.vstring(old_name), etf.vstring(name)));
				}
				if has_tags && !is_emoji ok = ok && sqlite.run(s.db, "UPDATE stickers SET tags = ? WHERE id = ?;", tags, id);
				if has_description && !is_emoji ok = ok && sqlite.run(s.db, "UPDATE stickers SET description = ? WHERE id = ?;", description, id);
			}
			if !ok return json_error(c, 500, 0, "500: Internal Server Error");
			action := ifx req.method == "DELETE" then 2 else 1;
			audit_locked(s, user, (ifx is_emoji then AUDIT_EMOJI_CREATE else AUDIT_STICKER_CREATE) + action, id, changes, reason);
		}
		if is_emoji list = emoji_list_locked(s);
		else list = sticker_list_locked(s);
		if req.method != "DELETE" {
			if is_emoji {
				for list.list if etf.map_get(it.map, "id").s == tprint("%", id) result = it;
			} else {
				st := sqlite.prepare(s.db, tprint("% WHERE s.id = ?;", STICKER_SELECT));
				sqlite.bind_all(st, id);
				if sqlite.step(st) == .Row result = row_sticker(s, st, true);
				sqlite.finalize(st);
			}
		}
	}
	d := etf.map_builder(2,, temp);
	etf.map_put(*d, "guild_id", snow(s.guild));
	etf.map_put(*d, ifx is_emoji then "emojis" else "stickers", list);
	broadcast(s, ifx is_emoji then "GUILD_EMOJIS_UPDATE" else "GUILD_STICKERS_UPDATE", etf.vmap(etf.map_done(*d)));
	if req.method == "DELETE" return respond(c, 204, json = false);
	return json_reply(c, ifx req.method == "POST" then 201 else 200, result);
}

// An emoji's name: 2-32 word characters, as Discord takes them.
emoji_name_ok :: (name: string) -> bool {
	if name.count < 2 || name.count > 32 return false;
	for name if !is_alnum(it) && it != #char "_" return false;
	return true;
}

// sticker_format reads a sticker file's format by its magic bytes (an APNG is a PNG with acTL before its
// first IDAT), or as a JSON object with layers for Lottie; 0 when it's none of them or too large.
sticker_format :: (file: string) -> int {
	if !file.count || file.count > STICKER_MAX_BYTES return 0;
	if begins_with(file, "GIF87a") || begins_with(file, "GIF89a") return STICKER_GIF;
	if begins_with(file, "\x89PNG\r\n\x1a\n") {
		at := 8;
		while at + 8 <= file.count {
			n := (cast(int) file[at] << 24) | (cast(int) file[at + 1] << 16) | (cast(int) file[at + 2] << 8) | file[at + 3];
			kind := slice(file, at + 4, 4);
			if kind == "acTL" return STICKER_APNG;
			if kind == "IDAT" || n > file.count return STICKER_PNG;
			at += 12 + n;
		}
		return 0;
	}
	if file[0] != #char "{" return 0;
	v, err := etf.from_json(file,, temp);
	if err != .None || v.kind != .Map return 0;
	layers, _ := etf.map_get(v.map, "layers");
	return ifx layers.kind == .List then STICKER_LOTTIE else 0;
}

// GET /stickers/{id}.{ext}: a sticker's file, whatever the extension and size asked for. Like Discord's,
// a sticker is public to whoever knows its ID.
sticker_file :: (c: *Conn, path: string) -> bool {
	s := c.server;
	name := advance(path, "/stickers/".count);
	dot := find_index_from_left(name, #char ".");
	if dot >= 0 name.count = dot;
	id, ok := string_to_int(name, T = s64);
	if !ok return json_error(c, 404, 0, "404: Not Found");
	locks.guard(*s.db_mu);
	st := sqlite.prepare(s.db, "SELECT format, data FROM stickers WHERE id = ?;");
	defer sqlite.finalize(st);
	sqlite.bind_all(st, id);
	if sqlite.step(st) != .Row return json_error(c, 404, 0, "404: Not Found");
	c.reply_status, c.reply_json = 200, false;
	c.reply_type = STICKER_TYPES[clamp(sqlite.col_int(st, 0), 0, STICKER_TYPES.count - 1)];
	c.reply_body = copy_string(cast(string) sqlite.col_blob(st, 1),, temp);
	return true;
}

Form_Part :: struct { name: string; data: string; }

// form_parts splits a multipart/form-data body into its named parts (views into body), at most
// MAX_FORM_PARTS. One pass: each part ends at the next "\r\n--boundary", and a boundary is at most 70
// characters (RFC 2046), so the scan is linear in the body.
form_parts :: (content_type: string, body: string) -> []Form_Part, bool {
	if !begins_with(content_type, "multipart/form-data") return .[], false;
	b := find_index_from_left(content_type, "boundary=");
	if b < 0 return .[], false;
	boundary := advance(content_type, b + "boundary=".count);
	semi := find_index_from_left(boundary, #char ";");
	if semi >= 0 boundary.count = semi;
	if boundary.count >= 2 && boundary[0] == #char "\"" && boundary[boundary.count - 1] == #char "\"" boundary = slice(boundary, 1, boundary.count - 2);
	if !boundary.count || boundary.count > 70 return .[], false;
	delim := tprint("\r\n--%", boundary);
	if !begins_with(body, advance(delim, 2)) return .[], false;
	parts: [..]Form_Part;
	parts.allocator = temp;
	at := delim.count - 2;
	while true {
		if begins_with(advance(body, at), "--") return parts, true; // The closing delimiter.
		if !begins_with(advance(body, at), "\r\n") || parts.count == MAX_FORM_PARTS return .[], false;
		at += 2;
		head_end := find_index_from_left(body, "\r\n\r\n", at);
		next := find_index_from_left(body, delim, at);
		if head_end < 0 || next < 0 || head_end > next return .[], false;
		part: Form_Part;
		for split(slice(body, at, head_end - at), "\r\n",, temp) {
			colon := find_index_from_left(it, #char ":");
			if colon < 0 || to_lower_copy(slice(it, 0, colon),, temp) != "content-disposition" continue;
			n := find_index_from_left(it, "name=\"");
			if n < 0 || (n > 0 && it[n - 1] != #char " " && it[n - 1] != #char ";") continue;
			name := advance(it, n + "name=\"".count);
			close := find_index_from_left(name, #char "\"");
			if close < 0 return .[], false;
			part.name = slice(name, 0, close);
		}
		part.data = slice(body, head_end + 4, next - head_end - 4);
		array_add(*parts, part);
		at = next + delim.count;
	}
	return .[], false;
}
