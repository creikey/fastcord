// The server's soundboard. The owner adds sounds (mp3 or ogg, 512 KB, checked by magic bytes and never
// decoded here; members' clients decode them), READY and GUILD_SOUNDBOARD_SOUNDS_UPDATE list them, and
// /soundboard-sounds/{id} serves them. A member in a voice channel plays one with
// POST /channels/{id}/send-soundboard-sound, and everyone in that channel gets VOICE_CHANNEL_EFFECT_SEND,
// as from Discord. The shapes are Discord's; there are no default sounds (they are Discord's files).

SOUND_MAX_BYTES :: 512 * 1024; // Discord's cap per sound
MAX_SOUNDS :: 48; // Discord's largest slot count (boost level 3); a hosted server has every slot

SOUND_SCHEMA :: "CREATE TABLE IF NOT EXISTS sounds(id INTEGER PRIMARY KEY, name TEXT NOT NULL, volume INTEGER NOT NULL, emoji_id INTEGER NOT NULL DEFAULT 0, emoji_name TEXT NOT NULL DEFAULT '', type TEXT NOT NULL, data BLOB NOT NULL, user INTEGER NOT NULL);";

// The server's sounds, oldest first; the caller holds db_mu.
sound_list_locked :: (s: *Server) -> etf.Value {
	list: [..]etf.Value;
	list.allocator = temp;
	st := sqlite.prepare(s.db, "SELECT id, name, volume, emoji_id, emoji_name, user FROM sounds ORDER BY id;");
	defer sqlite.finalize(st);
	while sqlite.step(st) == .Row {
		m := etf.map_builder(8,, temp);
		etf.map_put(*m, "sound_id", snow(sqlite.col_int(st, 0)));
		etf.map_put(*m, "name", etf.vstring(copy_string(sqlite.col_text(st, 1),, temp)));
		etf.map_put(*m, "volume", etf.vfloat(cast(float64) sqlite.col_int(st, 2) / 1000));
		emoji_id := sqlite.col_int(st, 3);
		etf.map_put(*m, "emoji_id", ifx emoji_id then snow(emoji_id) else .{});
		emoji_name := copy_string(sqlite.col_text(st, 4),, temp);
		etf.map_put(*m, "emoji_name", ifx emoji_name then etf.vstring(emoji_name) else .{});
		etf.map_put(*m, "guild_id", snow(s.guild));
		etf.map_put(*m, "user_id", snow(sqlite.col_int(st, 5)));
		etf.map_put(*m, "available", etf.vbool(true));
		array_add(*list, etf.vmap(etf.map_done(*m)));
	}
	return etf.vlist(list);
}

// Soundboard routes: /api/v9/guilds/{id}/soundboard-sounds[/{sound}], /api/v9/soundboard-default-sounds and
// /api/v9/channels/{id}/send-soundboard-sound. Adding takes Create Expressions, and the one who added a
// sound may edit or delete it; anyone else's takes Manage Expressions.
soundboard :: (c: *Conn, req: http.Request) -> bool {
	s := c.server;
	token, _ := http.header_get(req.headers, "authorization");
	user := session_user(c, token);
	if !user return json_error(c, 401, 0, "401: Unauthorized");
	if req.path == "/api/v9/soundboard-default-sounds" return respond(c, 200, "[]");
	if ends_with(req.path, "/send-soundboard-sound") return send_sound(c, req, user);
	base := tprint("/api/v9/guilds/%/soundboard-sounds", s.guild);
	if req.path == base && req.method == "GET" {
		m := etf.map_builder(1,, temp);
		{
			locks.guard(*s.db_mu);
			etf.map_put(*m, "items", sound_list_locked(s));
		}
		return json_reply(c, 200, etf.vmap(etf.map_done(*m)));
	}
	id: s64;
	if req.path != base {
		ok: bool;
		id, ok = string_to_int(advance(req.path, base.count + 1), T = s64);
		if !ok || !begins_with(req.path, tprint("%/", base)) return json_error(c, 404, 10097, "Unknown Sound");
	}
	if (id == 0) != (req.method == "POST") || (id && req.method != "PATCH" && req.method != "DELETE") return json_error(c, 405, 0, "405: Method Not Allowed");
	v: etf.Value;
	if req.method != "DELETE" {
		err: etf.Error;
		v, err = etf.from_json(cast(string) req.body,, temp);
		if err != .None || v.kind != .Map return json_error(c, 400, 50035, "Invalid Form Body");
	}
	field :: (v: etf.Value, k: string) -> etf.Value, bool { if v.kind != .Map return .{}, false; f, ok := etf.map_get(v.map, k); return f, ok; }
	name_v, has_name := field(v, "name");
	name := ifx name_v.kind == .String then trim(name_v.s) else "";
	if (has_name || id == 0) && (name.count < 2 || name.count > 32 || !text_ok(name)) return json_error(c, 400, 50035, "Invalid Form Body");
	vol_v, has_vol := field(v, "volume");
	volume := 1000;
	if has_vol && vol_v.kind != .Nil {
		f := ifx vol_v.kind == .Float then vol_v.f else ifx vol_v.kind == .Int then cast(float64) vol_v.i else -1;
		if f < 0 || f > 1 return json_error(c, 400, 50035, "Invalid Form Body");
		volume = cast(int) (f * 1000 + 0.5);
	}
	eid_v, has_eid := field(v, "emoji_id");
	emoji_id: s64;
	if eid_v.kind == .String {
		ok: bool;
		emoji_id, ok = string_to_int(eid_v.s, T = s64);
		if !ok return json_error(c, 400, 50035, "Invalid Form Body");
	} else if eid_v.kind != .Nil return json_error(c, 400, 50035, "Invalid Form Body");
	ename_v, has_ename := field(v, "emoji_name");
	emoji_name := ifx ename_v.kind == .String then ename_v.s else "";
	if emoji_name.count > 32 || !text_ok(emoji_name) || (ename_v.kind != .String && ename_v.kind != .Nil) return json_error(c, 400, 50035, "Invalid Form Body");
	data: []u8;
	mime: string;
	if id == 0 {
		sound_v, _ := field(v, "sound");
		data, mime = sound_data_uri(ifx sound_v.kind == .String then sound_v.s else "");
		if !data return json_error(c, 400, 50035, "Invalid Form Body");
	}
	list: etf.Value;
	{
		locks.guard(*s.db_mu);
		owner := can_locked(s, user, P_MANAGE_GUILD_EXPRESSIONS); // Manages everyone's.
		if emoji_id {
			st := sqlite.prepare(s.db, "SELECT 1 FROM emojis WHERE id = ?;");
			sqlite.bind_all(st, emoji_id);
			known := sqlite.step(st) == .Row;
			sqlite.finalize(st);
			if !known return json_error(c, 400, 50035, "Invalid Form Body");
		}
		if id == 0 {
			if !can_any_locked(s, user, P_CREATE_GUILD_EXPRESSIONS | P_MANAGE_GUILD_EXPRESSIONS) return json_error(c, 403, 50013, "Missing Permissions");
			st := sqlite.prepare(s.db, "SELECT count(*) FROM sounds;");
			n := ifx sqlite.step(st) == .Row then sqlite.col_int(st, 0) else 0;
			sqlite.finalize(st);
			if n >= MAX_SOUNDS return json_error(c, 400, 30045, tprint("Maximum number of soundboard sounds reached (%)", MAX_SOUNDS));
			id = snowflake(s);
			if !sqlite.run(s.db, "INSERT INTO sounds(id, name, volume, emoji_id, emoji_name, type, data, user) VALUES(?, ?, ?, ?, ?, ?, ?, ?);", id, name, volume, emoji_id, emoji_name, mime, data, user) {
				return json_error(c, 500, 0, "500: Internal Server Error");
			}
		} else {
			st := sqlite.prepare(s.db, "SELECT user FROM sounds WHERE id = ?;");
			sqlite.bind_all(st, id);
			found := sqlite.step(st) == .Row;
			creator := ifx found then sqlite.col_int(st, 0) else 0;
			sqlite.finalize(st);
			if !found return json_error(c, 404, 10097, "Unknown Sound");
			if !owner && creator != user return json_error(c, 403, 50013, "Missing Permissions");
			ok := true;
			if req.method == "DELETE" ok = sqlite.run(s.db, "DELETE FROM sounds WHERE id = ?;", id);
			else {
				if has_name ok = ok && sqlite.run(s.db, "UPDATE sounds SET name = ? WHERE id = ?;", name, id);
				if has_vol ok = ok && sqlite.run(s.db, "UPDATE sounds SET volume = ? WHERE id = ?;", volume, id);
				if has_eid || has_ename ok = ok && sqlite.run(s.db, "UPDATE sounds SET emoji_id = ?, emoji_name = ? WHERE id = ?;", emoji_id, emoji_name, id);
			}
			if !ok return json_error(c, 500, 0, "500: Internal Server Error");
		}
		list = sound_list_locked(s);
	}
	d := etf.map_builder(2,, temp);
	etf.map_put(*d, "guild_id", snow(s.guild));
	etf.map_put(*d, "soundboard_sounds", list);
	broadcast(s, "GUILD_SOUNDBOARD_SOUNDS_UPDATE", etf.vmap(etf.map_done(*d)));
	if req.method == "DELETE" return respond(c, 204, json = false);
	for list.list {
		sid, _ := etf.map_get(it.map, "sound_id");
		if sid.s == tprint("%", id) return json_reply(c, ifx req.method == "POST" then 201 else 200, it);
	}
	return json_error(c, 500, 0, "500: Internal Server Error");
}

// sound_data_uri reads a `data:audio/...;base64,` URI of an mp3 or ogg file of at most SOUND_MAX_BYTES, by its
// magic bytes; the bytes are in temp, empty when it isn't one.
sound_data_uri :: (uri: string) -> []u8, string {
	comma := find_index_from_left(uri, #char ",");
	if !begins_with(uri, "data:audio/") || comma < 0 || !ends_with(slice(uri, 0, comma), ";base64") || uri.count - comma > SOUND_MAX_BYTES / 3 * 4 + 8 return .[], "";
	text, ok := base64_decode(advance(uri, comma + 1),, temp);
	bytes := cast([]u8) text;
	if !ok || !bytes.count || bytes.count > SOUND_MAX_BYTES return .[], "";
	if begins_with(text, "OggS") return bytes, "audio/ogg";
	if begins_with(text, "ID3") || (bytes.count >= 2 && bytes[0] == 0xFF && (bytes[1] & 0xE0) == 0xE0) return bytes, "audio/mpeg";
	return .[], "";
}

// POST /api/v9/channels/{id}/send-soundboard-sound {sound_id, source_guild_id?}: a member in that voice
// channel, not deafened, plays one of the server's sounds to everyone in it.
send_sound :: (c: *Conn, req: http.Request, user: s64) -> bool {
	s := c.server;
	if req.method != "POST" return json_error(c, 405, 0, "405: Method Not Allowed");
	rest := advance(req.path, "/api/v9/channels/".count);
	slash := find_index_from_left(rest, #char "/");
	channel, ok := string_to_int(slice(rest, 0, max(slash, 0)), T = s64);
	if !ok || slash < 0 return json_error(c, 404, 10003, "Unknown Channel");
	v, err := etf.from_json(cast(string) req.body,, temp);
	sid_v: etf.Value;
	if err == .None && v.kind == .Map sid_v, _ = etf.map_get(v.map, "sound_id");
	sound: s64;
	if sid_v.kind == .String sound, ok = string_to_int(sid_v.s, T = s64);
	if !sound || !ok return json_error(c, 400, 50035, "Invalid Form Body");
	volume := 1000;
	emoji_id: s64;
	emoji_name: string;
	{
		locks.guard(*s.db_mu);
		if !can_locked(s, user, P_SPEAK | P_USE_SOUNDBOARD, channel) return json_error(c, 403, 50013, "Missing Permissions");
		st := sqlite.prepare(s.db, "SELECT volume, emoji_id, emoji_name FROM sounds WHERE id = ?;");
		defer sqlite.finalize(st);
		sqlite.bind_all(st, sound);
		if sqlite.step(st) != .Row return json_error(c, 404, 10097, "Unknown Sound");
		volume, emoji_id, emoji_name = sqlite.col_int(st, 0), sqlite.col_int(st, 1), copy_string(sqlite.col_text(st, 2),, temp);
	}
	room: [..]s64;
	room.allocator = temp;
	{
		locks.guard(*s.voice_mu);
		allowed := false;
		for s.voice_states if it.user == user && it.channel == channel && !it.self_deaf allowed = true;
		if !allowed return json_error(c, 403, 50013, "Missing Permissions");
		for s.voice_states if it.channel == channel array_add(*room, it.user);
	}
	m := etf.map_builder(8,, temp);
	etf.map_put(*m, "channel_id", snow(channel));
	etf.map_put(*m, "guild_id", snow(s.guild));
	etf.map_put(*m, "user_id", snow(user));
	etf.map_put(*m, "sound_id", snow(sound));
	etf.map_put(*m, "sound_volume", etf.vfloat(cast(float64) volume / 1000));
	etf.map_put(*m, "emoji", .{});
	etf.map_put(*m, "animation_type", .{});
	etf.map_put(*m, "animation_id", etf.vint(0));
	effect := etf.vmap(etf.map_done(*m));
	{
		locks.guard(*s.mu);
		for s.conns if it.ws && array_find(room, it.user) dispatch(it, "VOICE_CHANNEL_EFFECT_SEND", effect);
	}
	return respond(c, 204, json = false);
}

// GET /soundboard-sounds/{id}: a sound's file. Like Discord's, a sound is public to whoever knows its ID.
sound_file :: (c: *Conn, path: string) -> bool {
	s := c.server;
	id, ok := string_to_int(advance(path, "/soundboard-sounds/".count), T = s64);
	if !ok return json_error(c, 404, 0, "404: Not Found");
	locks.guard(*s.db_mu);
	st := sqlite.prepare(s.db, "SELECT type, data FROM sounds WHERE id = ?;");
	defer sqlite.finalize(st);
	sqlite.bind_all(st, id);
	if sqlite.step(st) != .Row return json_error(c, 404, 0, "404: Not Found");
	c.reply_status, c.reply_json = 200, false;
	c.reply_type = copy_string(sqlite.col_text(st, 0),, temp);
	c.reply_body = copy_string(cast(string) sqlite.col_blob(st, 1),, temp);
	return true;
}
