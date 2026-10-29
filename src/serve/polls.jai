// Polls, in Discord's shapes: a message's `poll` (question, up to 10 answers, a duration of 1 hour to 32
// days, one answer or several), votes by PUT /channels/{id}/polls/{message}/answers/@me with
// MESSAGE_POLL_VOTE_ADD and _REMOVE to everyone who sees the channel, the voters of an answer, and closing:
// at the expiry (archive_idle's sweep) or early by its author (POST .../expire), which finalizes the results.

POLL_SCHEMA :: #string SQL
CREATE TABLE IF NOT EXISTS polls(message INTEGER PRIMARY KEY, question TEXT NOT NULL, answers TEXT NOT NULL, expiry INTEGER NOT NULL, multiselect INTEGER NOT NULL, finalized INTEGER NOT NULL DEFAULT 0);
CREATE TABLE IF NOT EXISTS poll_votes(message INTEGER NOT NULL, answer INTEGER NOT NULL, user INTEGER NOT NULL, PRIMARY KEY(message, answer, user));
CREATE TRIGGER IF NOT EXISTS polls_delete AFTER DELETE ON messages BEGIN
	DELETE FROM polls WHERE message = old.id;
	DELETE FROM poll_votes WHERE message = old.id;
END;
SQL

MAX_POLL_ANSWERS :: 10;
MAX_POLL_HOURS :: 768; // 32 days, as on Discord.

// poll_create checks a send's `poll` and returns what to keep: the question, the answers as JSON (each
// {answer_id, poll_media}), the duration in hours and whether several answers may be picked; false when
// it's malformed.
poll_create :: (v: etf.Value) -> question: string, answers: string, hours: int, multiselect: bool, ok: bool {
	if v.kind != .Map return "", "", 0, false, false;
	q, _ := etf.map_get(v.map, "question");
	qtext: etf.Value;
	if q.kind == .Map qtext, _ = etf.map_get(q.map, "text");
	question := ifx qtext.kind == .String then trim(qtext.s) else "";
	if !question || utf16_units(question) > 300 || !text_ok(question) return "", "", 0, false, false;
	list, _ := etf.map_get(v.map, "answers");
	if list.kind != .List || !list.list.count || list.list.count > MAX_POLL_ANSWERS return "", "", 0, false, false;
	answers: [..]etf.Value;
	answers.allocator = temp;
	for list.list {
		media: etf.Value;
		if it.kind == .Map media, _ = etf.map_get(it.map, "poll_media");
		text, emoji: etf.Value;
		if media.kind == .Map {
			text, _ = etf.map_get(media.map, "text");
			emoji, _ = etf.map_get(media.map, "emoji");
		}
		t := ifx text.kind == .String then trim(text.s) else "";
		if !t || utf16_units(t) > 55 || !text_ok(t) return "", "", 0, false, false;
		m := etf.map_builder(2,, temp);
		etf.map_put(*m, "text", etf.vstring(t));
		// A Unicode emoji by name (a custom one would need checking against this server's; left out).
		name: etf.Value;
		if emoji.kind == .Map name, _ = etf.map_get(emoji.map, "name");
		if name.kind == .String && name.s && name.s.count <= 32 && text_ok(name.s) {
			e := etf.map_builder(2,, temp);
			etf.map_put(*e, "id", .{});
			etf.map_put(*e, "name", name);
			etf.map_put(*m, "emoji", etf.vmap(etf.map_done(*e)));
		}
		a := etf.map_builder(2,, temp);
		etf.map_put(*a, "answer_id", etf.vint(it_index + 1));
		etf.map_put(*a, "poll_media", etf.vmap(etf.map_done(*m)));
		array_add(*answers, etf.vmap(etf.map_done(*a)));
	}
	duration, has_duration := etf.map_get(v.map, "duration");
	hours := ifx has_duration then (ifx duration.kind == .Int then cast(int) duration.i else -1) else 24;
	if hours < 1 || hours > MAX_POLL_HOURS return "", "", 0, false, false;
	multi, _ := etf.map_get(v.map, "allow_multiselect");
	sb: String_Builder;
	sb.allocator = temp;
	etf.to_json(etf.vlist(answers), *sb);
	return question, builder_to_string(*sb,, temp), hours, multi.kind == .Bool && multi.b, true;
}

// A message's `poll`, with results and, for a viewer, which answers they picked; Nil if it has none. The
// caller holds db_mu.
poll_locked :: (s: *Server, message: s64, viewer: s64) -> etf.Value {
	st := sqlite.prepare(s.db, "SELECT question, answers, expiry, multiselect, finalized FROM polls WHERE message = ?;");
	sqlite.bind_all(st, message);
	if sqlite.step(st) != .Row { sqlite.finalize(st); return .{}; }
	question := copy_string(sqlite.col_text(st, 0),, temp);
	answers, _ := etf.from_json(copy_string(sqlite.col_text(st, 1),, temp),, temp);
	expiry, multi, finalized := sqlite.col_int(st, 2), sqlite.col_int(st, 3) != 0, sqlite.col_int(st, 4) != 0;
	sqlite.finalize(st);
	counts: [..]etf.Value;
	counts.allocator = temp;
	st = sqlite.prepare(s.db, "SELECT answer, count(*), max(user = ?) FROM poll_votes WHERE message = ? GROUP BY answer ORDER BY answer;");
	sqlite.bind_all(st, viewer, message);
	while sqlite.step(st) == .Row {
		c := etf.map_builder(3,, temp);
		etf.map_put(*c, "id", etf.vint(sqlite.col_int(st, 0)));
		etf.map_put(*c, "count", etf.vint(sqlite.col_int(st, 1)));
		etf.map_put(*c, "me_voted", etf.vbool(viewer != 0 && sqlite.col_int(st, 2) != 0));
		array_add(*counts, etf.vmap(etf.map_done(*c)));
	}
	sqlite.finalize(st);
	q := etf.map_builder(1,, temp);
	etf.map_put(*q, "text", etf.vstring(question));
	results := etf.map_builder(2,, temp);
	etf.map_put(*results, "is_finalized", etf.vbool(finalized));
	etf.map_put(*results, "answer_counts", etf.vlist(counts));
	m := etf.map_builder(6,, temp);
	etf.map_put(*m, "question", etf.vmap(etf.map_done(*q)));
	etf.map_put(*m, "answers", ifx answers.kind == .List then answers else etf.vlist(.[]));
	etf.map_put(*m, "expiry", etf.vstring(iso_ms(expiry)));
	etf.map_put(*m, "allow_multiselect", etf.vbool(multi));
	etf.map_put(*m, "layout_type", etf.vint(1));
	etf.map_put(*m, "results", etf.vmap(etf.map_done(*results)));
	return etf.vmap(etf.map_done(*m));
}

// Under /api/v9/channels/{id}/polls/{message}: PUT answers/@me {answer_ids} votes (an empty list takes
// the votes back), GET answers/{answer}?limit=&after= lists voters, POST expire closes it early.
poll_route :: (c: *Conn, req: http.Request, user: s64, channel: s64, parts: []string, query: string) -> bool {
	s := c.server;
	message, ok := string_to_int(parts[2], T = s64);
	if !ok return json_error(c, 404, 10008, "Unknown Message");
	vote := parts.count == 5 && parts[3] == "answers" && (parts[4] == "@me" || parts[4] == "%40me") && req.method == "PUT";
	voters := parts.count == 5 && parts[3] == "answers" && req.method == "GET";
	expire := parts.count == 4 && parts[3] == "expire" && req.method == "POST";
	if !vote && !voters && !expire return json_error(c, 404, 0, "404: Not Found");
	picked: [..]s64;
	picked.allocator = temp;
	if vote {
		v, err := etf.from_json(cast(string) req.body,, temp);
		ids: etf.Value;
		if err == .None && v.kind == .Map ids, _ = etf.map_get(v.map, "answer_ids");
		if ids.kind != .List || ids.list.count > MAX_POLL_ANSWERS return json_error(c, 400, 50035, "Invalid Form Body");
		for ids.list {
			n, nok := string_to_int(ifx it.kind == .String then it.s else "", T = s64);
			if it.kind == .Int n, nok = it.i, true;
			if !nok || n < 1 || n > MAX_POLL_ANSWERS return json_error(c, 400, 50035, "Invalid Form Body");
			array_add_if_unique(*picked, n);
		}
	}
	Change :: struct { added: bool; answer: s64; }
	changes: [..]Change;
	changes.allocator = temp;
	updated: etf.Value;
	{
		locks.guard(*s.db_mu);
		st := sqlite.prepare(s.db, "SELECT p.answers, p.expiry, p.multiselect, p.finalized, m.author FROM polls p JOIN messages m ON m.id = p.message WHERE p.message = ? AND m.channel = ?;");
		sqlite.bind_all(st, message, channel);
		found := sqlite.step(st) == .Row;
		answers, expiry, multi, finalized, author := "", 0, false, false, 0;
		if found {
			answers = copy_string(sqlite.col_text(st, 0),, temp);
			expiry, multi, finalized, author = sqlite.col_int(st, 1), sqlite.col_int(st, 2) != 0, sqlite.col_int(st, 3) != 0, sqlite.col_int(st, 4);
		}
		sqlite.finalize(st);
		if !found return json_error(c, 404, 10008, "Unknown Message");
		if voters {
			answer, aok := string_to_int(parts[4], T = s64);
			if !aok return json_error(c, 404, 0, "404: Not Found");
			limit, after := 25, 0;
			for split(query, "&",, temp) {
				kv := split(it, "=",, temp);
				if kv.count != 2 continue;
				if kv[0] == "limit" limit = clamp(string_to_int(kv[1]), 1, 100);
				if kv[0] == "after" after = string_to_int(kv[1], T = s64);
			}
			users: [..]etf.Value;
			users.allocator = temp;
			st = sqlite.prepare(s.db, "SELECT v.user, u.name FROM poll_votes v JOIN users u ON u.id = v.user WHERE v.message = ? AND v.answer = ? AND v.user > ? ORDER BY v.user LIMIT ?;");
			sqlite.bind_all(st, message, answer, after, limit);
			while sqlite.step(st) == .Row array_add(*users, user_value(s, sqlite.col_int(st, 0), copy_string(sqlite.col_text(st, 1),, temp)));
			sqlite.finalize(st);
			m := etf.map_builder(1,, temp);
			etf.map_put(*m, "users", etf.vlist(users));
			return json_reply(c, 200, etf.vmap(etf.map_done(*m)));
		}
		closed := finalized || expiry <= now_ms(s) + DISCORD_EPOCH_MS;
		if expire {
			if author != user && !can_locked(s, user, P_MANAGE_MESSAGES, channel) return json_error(c, 403, 50013, "Missing Permissions");
			if closed return json_error(c, 400, 520001, "Poll expired");
			if !sqlite.run(s.db, "UPDATE polls SET expiry = ?, finalized = 1 WHERE message = ?;", now_ms(s) + DISCORD_EPOCH_MS, message) return json_error(c, 500, 0, "500: Internal Server Error");
			updated = message_locked(s, message, nested = false);
		} else {
			if closed return json_error(c, 400, 520001, "Poll expired");
			count := 0;
			list, _ := etf.from_json(answers,, temp);
			if list.kind == .List count = list.list.count;
			for picked if it > count return json_error(c, 400, 50035, "Invalid Form Body");
			if picked.count > 1 && !multi return json_error(c, 400, 50035, "Invalid Form Body");
			old: [..]s64;
			old.allocator = temp;
			st = sqlite.prepare(s.db, "SELECT answer FROM poll_votes WHERE message = ? AND user = ?;");
			sqlite.bind_all(st, message, user);
			while sqlite.step(st) == .Row array_add(*old, sqlite.col_int(st, 0));
			sqlite.finalize(st);
			for old if !array_find(picked, it) {
				if !sqlite.run(s.db, "DELETE FROM poll_votes WHERE message = ? AND answer = ? AND user = ?;", message, it, user) return json_error(c, 500, 0, "500: Internal Server Error");
				array_add(*changes, .{false, it});
			}
			for picked if !array_find(old, it) {
				if !sqlite.run(s.db, "INSERT INTO poll_votes(message, answer, user) VALUES(?, ?, ?);", message, it, user) return json_error(c, 500, 0, "500: Internal Server Error");
				array_add(*changes, .{true, it});
			}
		}
	}
	if updated.kind == .Map {
		broadcast(s, "MESSAGE_UPDATE", updated);
		return respond(c, 204, json = false);
	}
	for changes {
		d := etf.map_builder(5,, temp);
		etf.map_put(*d, "user_id", snow(user));
		etf.map_put(*d, "channel_id", snow(channel));
		etf.map_put(*d, "message_id", snow(message));
		etf.map_put(*d, "guild_id", snow(s.guild));
		etf.map_put(*d, "answer_id", etf.vint(it.answer));
		broadcast(s, ifx it.added then "MESSAGE_POLL_VOTE_ADD" else "MESSAGE_POLL_VOTE_REMOVE", etf.vmap(etf.map_done(*d)));
	}
	return respond(c, 204, json = false);
}

// close_polls_locked finalizes the polls past their expiry and returns their messages, for MESSAGE_UPDATE.
close_polls_locked :: (s: *Server) -> []etf.Value {
	out: [..]etf.Value;
	out.allocator = temp;
	ids: [..]s64;
	ids.allocator = temp;
	st := sqlite.prepare(s.db, "SELECT message FROM polls WHERE finalized = 0 AND expiry <= ?;");
	sqlite.bind_all(st, now_ms(s) + DISCORD_EPOCH_MS);
	while sqlite.step(st) == .Row array_add(*ids, sqlite.col_int(st, 0));
	sqlite.finalize(st);
	for ids if sqlite.run(s.db, "UPDATE polls SET finalized = 1 WHERE message = ?;", it) array_add(*out, message_locked(s, it, nested = false));
	return out;
}
