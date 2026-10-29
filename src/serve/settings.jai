// Server Settings on a hosted server: the routes the app's Server Settings pages call, at Discord's paths
// and in Discord's shapes, and the audit log every change lands in. Each page takes the permission Discord asks
// for (roles.jai).

SETTINGS_SCHEMA :: #string SQL
CREATE TABLE IF NOT EXISTS audit(id INTEGER PRIMARY KEY, user INTEGER NOT NULL, action INTEGER NOT NULL, target INTEGER, changes TEXT NOT NULL, reason TEXT, options TEXT);
CREATE INDEX IF NOT EXISTS audit_user ON audit(user, id);
SQL

// Discord's audit log action types.
AUDIT_GUILD_UPDATE :: 1;
AUDIT_CHANNEL_CREATE :: 10;
AUDIT_CHANNEL_UPDATE :: 11;
AUDIT_CHANNEL_DELETE :: 12;
AUDIT_MEMBER_KICK :: 20;
AUDIT_MEMBER_BAN_ADD :: 22;
AUDIT_MEMBER_BAN_REMOVE :: 23;
AUDIT_MEMBER_UPDATE :: 24;
AUDIT_INVITE_CREATE :: 40;
AUDIT_WEBHOOK_UPDATE :: 51;
AUDIT_INVITE_DELETE :: 42;
AUDIT_EMOJI_CREATE :: 60;
AUDIT_EMOJI_UPDATE :: 61;
AUDIT_EMOJI_DELETE :: 62;

MAX_TRAITS :: 5;
TRAIT_MAX_RUNES :: 24;
DESCRIPTION_MAX :: 300;

// Guild fields kept in meta, as (key, kind): written by PATCH /guilds/{id}, sent in READY and GUILD_UPDATE.
Guild_Field :: struct { key: string; kind: enum u8 { Text; Int; Channel; }; max: int; }
GUILD_FIELDS :: Guild_Field.[
	.{"description", .Text, DESCRIPTION_MAX},
	.{"system_channel_id", .Channel, 0},
	.{"system_channel_flags", .Int, 0xFF},
	.{"default_message_notifications", .Int, 1},
	.{"verification_level", .Int, 4},
	.{"explicit_content_filter", .Int, 2},
];

// audit_locked records one change. changes: a list of {key, old_value?, new_value?}.
audit_locked :: (s: *Server, user: s64, action: int, target: s64, changes: []etf.Value, reason: string) {
	sb: String_Builder;
	sb.allocator = temp;
	etf.to_json(etf.vlist(changes), *sb);
	sqlite.run(s.db, "INSERT INTO audit(id, user, action, target, changes, reason) VALUES(?, ?, ?, ?, ?, nullif(?, ''));",
		snowflake(s), user, action, target, builder_to_string(*sb,, temp), reason);
}

audit_change :: (key: string, old: etf.Value, new: etf.Value) -> etf.Value {
	m := etf.map_builder(3,, temp);
	etf.map_put(*m, "key", etf.vstring(key));
	if old.kind != .Nil etf.map_put(*m, "old_value", old);
	if new.kind != .Nil etf.map_put(*m, "new_value", new);
	return etf.vmap(etf.map_done(*m));
}

// The X-Audit-Log-Reason a request carries; false when it's malformed or too long.
audit_reason :: (req: http.Request) -> string, bool {
	reason, _ := http.header_get(req.headers, "x-audit-log-reason");
	reason = trim(percent_decode(reason));
	return reason, text_ok(reason) && utf16_units(reason) <= 512;
}

// guild_fields_locked adds the meta-kept fields (GUILD_FIELDS) to a guild object.
guild_fields_locked :: (s: *Server, g: *etf.Map_Builder) {
	for GUILD_FIELDS etf.map_put(g, it.key, guild_field_locked(s, it));
	etf.map_put(g, "incidents_data", guild_incidents_locked(s));
	etf.map_put(g, "pending_owner_id", pending_owner_locked(s));
}

guild_field_locked :: (s: *Server, f: Guild_Field) -> etf.Value {
	raw := cast(string) meta_get(s, tprint("g.%", f.key));
	if f.kind == .Text return etf.vstring(copy_string(raw,, temp));
	if !raw return ifx f.kind == .Int then etf.vint(0) else .{};
	v := string_to_int(raw, T = s64);
	return ifx f.kind == .Int then etf.vint(v) else snow(v);
}

// settings_route handles the Server Settings routes; handled = false for any other request.
settings_route :: (c: *Conn, req: http.Request) -> handled: bool, keep: bool {
	s := c.server;
	base := tprint("/api/v9/guilds/%", s.guild);
	if !begins_with(req.path, base) return false, true;
	rest := advance(req.path, base.count);
	q := find_index_from_left(rest, #char "?");
	query := "";
	if q >= 0 { query = advance(rest, q + 1); rest.count = q; }
	if rest == "" && req.method == "PATCH" return true, edit_guild(c, req);
	if rest == "/owner-transfer" && (req.method == "PUT" || req.method == "DELETE") return true, owner_transfer(c, req);
	if rest == "/profile" && (req.method == "GET" || req.method == "PATCH") return true, guild_profile(c, req);
	if rest == "/audit-logs" && req.method == "GET" return true, audit_logs(c, req, query);
	if rest == "/members-search" && req.method == "POST" return true, members_search(c, req);
	if rest == "/incident-actions" && req.method == "PUT" return true, incident_actions(c, req);
	return false, true;
}

MEMBER_SEARCH_MAX :: 1000;

// POST /api/v9/guilds/{id}/members-search {or_query: {usernames: {or_query: [..]}, user_id: {..}}, limit}:
// Server Settings' Members, newest first, in Discord's shape. For anyone who may open the page (the owner).
members_search :: (c: *Conn, req: http.Request) -> bool {
	s := c.server;
	user := owner_session(c, req);
	if !user return json_error(c, 401, 0, "401: Unauthorized");
	v, err := etf.from_json(cast(string) req.body,, temp);
	if err != .None || v.kind != .Map return json_error(c, 400, 50035, "Invalid Form Body");
	limit := 250;
	lv, has_limit := etf.map_get(v.map, "limit");
	if has_limit {
		if lv.kind != .Int || lv.i < 1 || lv.i > MEMBER_SEARCH_MAX return json_error(c, 400, 50035, "Invalid Form Body");
		limit = cast(int) lv.i;
	}
	or, _ := etf.map_get(v.map, "or_query");
	names: [..]string;
	ids: [..]s64;
	names.allocator, ids.allocator = temp, temp;
	for k: string.["usernames", "user_id"] {
		q, _ := etf.map_get(or.map, k);
		terms, _ := etf.map_get(q.map, "or_query");
		if terms.kind != .List continue;
		if terms.list.count > 10 return json_error(c, 400, 50035, "Invalid Form Body");
		for terms.list {
			if it.kind != .String || it.s.count > 100 return json_error(c, 400, 50035, "Invalid Form Body");
			if k == "usernames" array_add(*names, to_lower_copy(it.s,, temp));
			else { id, ok := string_to_int(it.s, T = s64); if ok array_add(*ids, id); }
		}
	}
	locks.guard(*s.db_mu);
	if !(perms_of_locked(s, user).base & (P_MANAGE_GUILD | P_KICK_MEMBERS | P_BAN_MEMBERS | P_MANAGE_ROLES)) return json_error(c, 403, 50013, "Missing Permissions");
	list: [..]etf.Value;
	list.allocator = temp;
	total := 0;
	st := sqlite.prepare(s.db, "SELECT id, name FROM users WHERE left = 0 ORDER BY id DESC;");
	defer sqlite.finalize(st);
	while sqlite.step(st) == .Row {
		id := sqlite.col_int(st, 0);
		name := copy_string(sqlite.col_text(st, 1),, temp);
		u := user_value(s, id, name);
		if names.count || ids.count {
			match := array_find(ids, id);
			handle := etf.map_get(u.map, "username");
			for names if contains(to_lower_copy(name,, temp), it) || contains(handle.s, it) match = true;
			if !match continue;
		}
		total += 1;
		if list.count >= limit continue;
		m := etf.map_builder(4,, temp);
		etf.map_put(*m, "user", u);
		etf.map_put(*m, "joined_at", etf.vstring(iso(id)));
		etf.map_put(*m, "roles", etf.vlist(.[]));
		etf.map_put(*m, "nick", .{});
		e := etf.map_builder(4,, temp);
		etf.map_put(*e, "member", etf.vmap(etf.map_done(*m)));
		etf.map_put(*e, "join_source_type", etf.vint(0));
		etf.map_put(*e, "source_invite_code", .{});
		etf.map_put(*e, "inviter_id", .{});
		array_add(*list, etf.vmap(etf.map_done(*e)));
	}
	r := etf.map_builder(4,, temp);
	etf.map_put(*r, "guild_id", snow(s.guild));
	etf.map_put(*r, "members", etf.vlist(list));
	etf.map_put(*r, "page_result_count", etf.vint(list.count));
	etf.map_put(*r, "total_result_count", etf.vint(total));
	return json_reply(c, 200, etf.vmap(etf.map_done(*r)));
}

// invites_paused_locked: Pause Invites is on (incident-actions' invites_disabled_until is ahead).
invites_paused_locked :: (s: *Server) -> bool {
	until, ok := parse_iso(cast(string) meta_get(s, "invites_disabled_until"));
	return ok && until > to_milliseconds(current_time_consensus() - APOLLO_TIME_FOR_JAN_1_1970);
}

// PUT /api/v9/guilds/{id}/incident-actions {invites_disabled_until, dms_disabled_until, lockdown_duration_hours}:
// Pause Invites until a time at most a day ahead, or null to enable them. DMs aren't the server's to pause.
incident_actions :: (c: *Conn, req: http.Request) -> bool {
	s := c.server;
	user := owner_session(c, req);
	if !user return json_error(c, 401, 0, "401: Unauthorized");
	v, err := etf.from_json(cast(string) req.body,, temp);
	until, has := etf.map_get(v.map, "invites_disabled_until");
	if err != .None || v.kind != .Map || !has return json_error(c, 400, 50035, "Invalid Form Body");
	text := "";
	if until.kind != .Nil {
		ms, ok := parse_iso(ifx until.kind == .String then until.s else "");
		now := to_milliseconds(current_time_consensus() - APOLLO_TIME_FOR_JAN_1_1970);
		if !ok || ms > now + 24 * 3600_000 + 60_000 return json_error(c, 400, 50035, "Invalid Form Body");
		text = until.s;
	}
	g := etf.map_builder(2,, temp);
	{
		locks.guard(*s.db_mu);
		if !can_locked(s, user, P_MANAGE_GUILD) return json_error(c, 403, 50013, "Missing Permissions");
		old := guild_incidents_locked(s);
		ok := ifx text then meta_put(s, "invites_disabled_until", text) else sqlite.run(s.db, "DELETE FROM meta WHERE k = 'invites_disabled_until';");
		if !ok return json_error(c, 500, 0, "500: Internal Server Error");
		audit_locked(s, user, AUDIT_GUILD_UPDATE, s.guild, .[audit_change("invites_disabled_until", etf.map_get(old.map, "invites_disabled_until"), ifx text then etf.vstring(text) else .{})], "");
		etf.map_put(*g, "id", snow(s.guild));
		etf.map_put(*g, "incidents_data", guild_incidents_locked(s));
	}
	guild := etf.vmap(etf.map_done(*g));
	broadcast(s, "GUILD_UPDATE", guild);
	return json_reply(c, 200, etf.map_get(guild.map, "incidents_data"));
}

guild_incidents_locked :: (s: *Server) -> etf.Value {
	text := copy_string(cast(string) meta_get(s, "invites_disabled_until"),, temp);
	m := etf.map_builder(2,, temp);
	etf.map_put(*m, "invites_disabled_until", ifx text then etf.vstring(text) else .{});
	etf.map_put(*m, "dms_disabled_until", .{});
	return etf.vmap(etf.map_done(*m));
}

owner_session :: (c: *Conn, req: http.Request) -> s64 {
	token, _ := http.header_get(req.headers, "authorization");
	user := session_user(c, token);
	return user;
}

// PATCH /api/v9/guilds/{id}: the owner renames the server, sets its icon (a `data:` URI kept as sent,
// checked by its magic bytes; null removes it) or any GUILD_FIELDS. s.name changes under db_mu, so
// readers copy it while holding that lock. Each change is audited.
edit_guild :: (c: *Conn, req: http.Request) -> bool {
	s := c.server;
	user := owner_session(c, req);
	if !user return json_error(c, 401, 0, "401: Unauthorized");
	reason, rok := audit_reason(req);
	v, err := etf.from_json(cast(string) req.body,, temp);
	if err != .None || v.kind != .Map || !rok return json_error(c, 400, 50035, "Invalid Form Body");
	new_owner, has_owner := etf.map_get(v.map, "owner_id");
	if has_owner return offer_ownership(c, user, new_owner);
	raw, has_name := etf.map_get(v.map, "name");
	icon_v, has_icon := etf.map_get(v.map, "icon");
	name := ifx raw.kind == .String then trim(raw.s) else "";
	if has_name && (name.count < 2 || name.count > 100 || !text_ok(name)) return json_error(c, 400, 50035, "Invalid Form Body");
	icon: []u8;
	format: imagefmt.Format;
	if has_icon && icon_v.kind != .Nil {
		ok: bool;
		icon, format, ok = image_data_uri(ifx icon_v.kind == .String then icon_v.s else "", ICON_MAX_BYTES);
		if !ok return json_error(c, 400, 50035, "Invalid Form Body");
	}
	g := etf.map_builder(12,, temp);
	etf.map_put(*g, "id", snow(s.guild));
	{
		locks.guard(*s.db_mu);
		if !can_locked(s, user, P_MANAGE_GUILD) return json_error(c, 403, 50013, "Missing Permissions");
		// Every field is checked before anything is written.
		Set :: struct { f: Guild_Field; value: string; new: etf.Value; }
		sets: [..]Set;
		sets.allocator = temp;
		for f: GUILD_FIELDS {
			x, has := etf.map_get(v.map, f.key);
			if !has continue;
			st := Set.{f = f};
			if f.kind == {
			case .Text;
				t := ifx x.kind == .String then trim(x.s) else "";
				if (x.kind != .String && x.kind != .Nil) || utf16_units(t) > f.max || !text_ok(t, lines = true) return json_error(c, 400, 50035, "Invalid Form Body");
				st.value, st.new = t, etf.vstring(t);
			case .Int;
				if x.kind != .Int || x.i < 0 || x.i > f.max return json_error(c, 400, 50035, "Invalid Form Body");
				st.value, st.new = tprint("%", x.i), etf.vint(x.i);
			case .Channel;
				if x.kind != .Nil {
					id, ok := string_to_int(ifx x.kind == .String then x.s else "", T = s64);
					if !ok || channel_type_locked(s, id) != 0 return json_error(c, 400, 50035, "Invalid Form Body");
					st.value, st.new = tprint("%", id), snow(id);
				}
			}
			array_add(*sets, st);
		}
		changes: [..]etf.Value;
		changes.allocator = temp;
		if !sqlite.exec(s.db, "BEGIN;") return json_error(c, 500, 0, "500: Internal Server Error");
		ok := true;
		if has_name && name != s.name {
			array_add(*changes, audit_change("name", etf.vstring(copy_string(s.name,, temp)), etf.vstring(name)));
			ok = meta_put(s, "name", name);
		}
		if has_icon && ok {
			old := guild_icon_locked(s);
			if icon {
				ok = meta_put(s, "icon", image_hash(format))
					&& meta_put(s, "icon_type", IMAGE_TYPES[cast(int) format])
					&& meta_put(s, "icon_data", icon);
			} else {
				ok = sqlite.run(s.db, "DELETE FROM meta WHERE k IN ('icon', 'icon_type', 'icon_data');");
			}
			array_add(*changes, audit_change("icon_hash", old, guild_icon_locked(s)));
		}
		for sets if ok {
			old := guild_field_locked(s, it.f);
			ok = ifx it.value then meta_put(s, tprint("g.%", it.f.key), it.value) else sqlite.run(s.db, "DELETE FROM meta WHERE k = ?;", tprint("g.%", it.f.key));
			array_add(*changes, audit_change(it.f.key, old, it.new));
		}
		if ok && changes.count audit_locked(s, user, AUDIT_GUILD_UPDATE, s.guild, changes, reason);
		if !ok || !sqlite.exec(s.db, "COMMIT;") {
			sqlite.exec(s.db, "ROLLBACK;");
			return json_error(c, 500, 0, "500: Internal Server Error");
		}
		if has_name {
			free(s.name);
			s.name = copy_string(name);
		}
		etf.map_put(*g, "name", etf.vstring(copy_string(s.name,, temp)));
		etf.map_put(*g, "icon", guild_icon_locked(s));
		guild_fields_locked(s, *g);
	}
	guild := etf.vmap(etf.map_done(*g));
	broadcast(s, "GUILD_UPDATE", guild);
	return json_reply(c, 200, guild);
}

// Transfer Ownership: PATCH /guilds/{id} {owner_id} from the owner only offers the server to a member
// (pending_owner_id in GUILD_UPDATE); it changes hands when that member accepts with PUT
// /guilds/{id}/owner-transfer, and DELETE declines (or the owner withdraws). The old owner stays a member.
offer_ownership :: (c: *Conn, user: s64, v: etf.Value) -> bool {
	s := c.server;
	target, ok := string_to_int(ifx v.kind == .String then v.s else "", T = s64);
	if !ok return json_error(c, 400, 50035, "Invalid Form Body");
	g := etf.map_builder(2,, temp);
	{
		locks.guard(*s.db_mu);
		if owner_id(s) != user return json_error(c, 403, 50013, "Missing Permissions");
		if target == user {
			sqlite.run(s.db, "DELETE FROM meta WHERE k = 'pending_owner';");
		} else {
			st := sqlite.prepare(s.db, "SELECT 1 FROM users WHERE id = ? AND left = 0 AND banned = 0 AND signing_pub != x'';");
			sqlite.bind(st, 1, target);
			member := sqlite.step(st) == .Row;
			sqlite.finalize(st);
			if !member return json_error(c, 404, 10013, "Unknown User");
			if !meta_put(s, "pending_owner", tprint("%", target)) return json_error(c, 500, 0, "500: Internal Server Error");
			audit_locked(s, user, AUDIT_GUILD_UPDATE, s.guild, .[audit_change("pending_owner_id", .{}, snow(target))], "");
		}
		etf.map_put(*g, "id", snow(s.guild));
		etf.map_put(*g, "pending_owner_id", pending_owner_locked(s));
	}
	guild := etf.vmap(etf.map_done(*g));
	broadcast(s, "GUILD_UPDATE", guild);
	return json_reply(c, 200, guild);
}

pending_owner_locked :: (s: *Server) -> etf.Value {
	p := string_to_int(cast(string) meta_get(s, "pending_owner"), T = s64);
	return ifx p then snow(p) else .{};
}

owner_transfer :: (c: *Conn, req: http.Request) -> bool {
	s := c.server;
	user := owner_session(c, req);
	if !user return json_error(c, 401, 0, "401: Unauthorized");
	g := etf.map_builder(3,, temp);
	{
		locks.guard(*s.db_mu);
		pending := string_to_int(cast(string) meta_get(s, "pending_owner"), T = s64);
		old := owner_id(s);
		if !pending || (pending != user && !(req.method == "DELETE" && old == user)) return json_error(c, 403, 50013, "Missing Permissions");
		ok := sqlite.exec(s.db, "BEGIN;") && sqlite.run(s.db, "DELETE FROM meta WHERE k = 'pending_owner';");
		if ok && req.method == "PUT" {
			ok = meta_put(s, "owner", tprint("%", user));
			audit_locked(s, user, AUDIT_GUILD_UPDATE, s.guild, .[audit_change("owner_id", snow(old), snow(user))], "");
		}
		if !ok || !sqlite.exec(s.db, "COMMIT;") {
			sqlite.exec(s.db, "ROLLBACK;");
			return json_error(c, 500, 0, "500: Internal Server Error");
		}
		etf.map_put(*g, "id", snow(s.guild));
		etf.map_put(*g, "owner_id", snow(owner_id(s)));
		etf.map_put(*g, "pending_owner_id", .{});
	}
	guild := etf.vmap(etf.map_done(*g));
	broadcast(s, "GUILD_UPDATE", guild);
	return json_reply(c, 200, guild);
}

// GET and PATCH /api/v9/guilds/{id}/profile: the Server Profile, in Discord's shape. Name, description and
// icon are the guild's own; brand colour, visibility and traits are kept beside them. The icon in a PATCH
// is the current hash (unchanged), a `data:` URI or null.
guild_profile :: (c: *Conn, req: http.Request) -> bool {
	s := c.server;
	user := owner_session(c, req);
	if !user return json_error(c, 401, 0, "401: Unauthorized");
	if req.method == "PATCH" {
		v, err := etf.from_json(cast(string) req.body,, temp);
		if err != .None || v.kind != .Map return json_error(c, 400, 50035, "Invalid Form Body");
		patch := etf.map_builder(4,, temp);
		for k: string.["name", "description"] {
			x, has := etf.map_get(v.map, k);
			if has etf.map_put(*patch, k, x);
		}
		icon, has_icon := etf.map_get(v.map, "icon");
		if has_icon {
			current: string;
			{
				locks.guard(*s.db_mu);
				current = copy_string(cast(string) meta_get(s, "icon"),, temp);
			}
			if !(icon.kind == .String && icon.s == current && current) etf.map_put(*patch, "icon", icon);
		}
		// brand colour, visibility and traits, checked whole before the guild fields go through edit_guild
		color, has_color := etf.map_get(v.map, "brand_color_primary");
		if has_color && color.kind != .Nil && !(color.kind == .String && is_hex_color(color.s)) return json_error(c, 400, 50035, "Invalid Form Body");
		vis, has_vis := etf.map_get(v.map, "visibility");
		if has_vis && (vis.kind != .Int || vis.i < 0 || vis.i > 3) return json_error(c, 400, 50035, "Invalid Form Body");
		traits_v, has_traits := etf.map_get(v.map, "traits");
		traits: [..]etf.Value;
		traits.allocator = temp;
		if has_traits {
			if traits_v.kind != .List || traits_v.list.count > MAX_TRAITS return json_error(c, 400, 50035, "Invalid Form Body");
			for traits_v.list {
				label, _ := etf.map_get(it.map, "label");
				pos, _ := etf.map_get(it.map, "position");
				if it.kind != .Map || label.kind != .String || pos.kind != .Int || pos.i < 0 || pos.i >= MAX_TRAITS return json_error(c, 400, 50035, "Invalid Form Body");
				t := trim(label.s);
				if !t || utf16_units(t) > TRAIT_MAX_RUNES || !text_ok(t) return json_error(c, 400, 50035, "Invalid Form Body");
				m := etf.map_builder(2,, temp);
				etf.map_put(*m, "label", etf.vstring(t));
				etf.map_put(*m, "position", etf.vint(pos.i));
				array_add(*traits, etf.vmap(etf.map_done(*m)));
			}
		}
		if patch.pairs.count {
			body: String_Builder;
			body.allocator = temp;
			etf.to_json(etf.vmap(etf.map_done(*patch)), *body);
			sub := req;
			sub.body = cast([]u8) builder_to_string(*body,, temp);
			// edit_guild replies on its own; only a failure is passed back
			if !edit_guild(c, sub) return false;
			if c.reply_status != 200 return true;
		}
		{
			locks.guard(*s.db_mu);
			if !can_locked(s, user, P_MANAGE_GUILD) return json_error(c, 403, 50013, "Missing Permissions");
			changes: [..]etf.Value;
			changes.allocator = temp;
			ok := true;
			if has_color {
				old := cast(string) meta_get(s, "p.brand_color");
				new := ifx color.kind == .String then color.s else "";
				if new != old {
					array_add(*changes, audit_change("brand_color_primary", ifx old then etf.vstring(copy_string(old,, temp)) else .{}, ifx new then etf.vstring(new) else .{}));
					ok = ifx new then meta_put(s, "p.brand_color", new) else sqlite.run(s.db, "DELETE FROM meta WHERE k = 'p.brand_color';");
				}
			}
			if has_vis && ok ok = meta_put(s, "p.visibility", tprint("%", vis.i));
			if has_traits && ok {
				sb: String_Builder;
				sb.allocator = temp;
				etf.to_json(etf.vlist(traits), *sb);
				ok = meta_put(s, "p.traits", builder_to_string(*sb,, temp));
			}
			if !ok return json_error(c, 500, 0, "500: Internal Server Error");
			if changes.count audit_locked(s, user, AUDIT_GUILD_UPDATE, s.guild, changes, "");
		}
	}
	locks.guard(*s.db_mu);
	return json_reply(c, 200, profile_locked(s));
}

profile_locked :: (s: *Server) -> etf.Value {
	members := 0;
	st := sqlite.prepare(s.db, "SELECT count(*) FROM users WHERE left = 0;");
	if sqlite.step(st) == .Row members = sqlite.col_int(st, 0);
	sqlite.finalize(st);
	color := copy_string(cast(string) meta_get(s, "p.brand_color"),, temp);
	vis := string_to_int(cast(string) meta_get(s, "p.visibility"), T = s64);
	traits, err := etf.from_json(copy_string(cast(string) meta_get(s, "p.traits"),, temp),, temp);
	m := etf.map_builder(12,, temp);
	etf.map_put(*m, "id", snow(s.guild));
	etf.map_put(*m, "name", etf.vstring(copy_string(s.name,, temp)));
	etf.map_put(*m, "icon_hash", guild_icon_locked(s));
	etf.map_put(*m, "description", guild_field_locked(s, GUILD_FIELDS[0]));
	etf.map_put(*m, "custom_banner_hash", .{});
	etf.map_put(*m, "brand_color_primary", ifx color then etf.vstring(color) else .{});
	etf.map_put(*m, "visibility", etf.vint(ifx vis then vis else 1));
	etf.map_put(*m, "traits", ifx err == .None && traits.kind == .List then traits else etf.vlist(.[]));
	etf.map_put(*m, "game_application_ids", etf.vlist(.[]));
	etf.map_put(*m, "member_count", etf.vint(members));
	etf.map_put(*m, "features", etf.vlist(.[]));
	return etf.vmap(etf.map_done(*m));
}

is_hex_color :: (t: string) -> bool {
	if t.count != 7 || t[0] != #char "#" return false;
	for 1..6 if !is_digit(t[it]) && !(t[it] >= #char "a" && t[it] <= #char "f") && !(t[it] >= #char "A" && t[it] <= #char "F") return false;
	return true;
}

// GET /api/v9/guilds/{id}/audit-logs[?limit=&before=&user_id=&action_type=]: the newest entries first (at
// most 100), with the users they name, for the owner.
audit_logs :: (c: *Conn, req: http.Request, query: string) -> bool {
	s := c.server;
	user := owner_session(c, req);
	if !user return json_error(c, 401, 0, "401: Unauthorized");
	limit, before, by, action := 50, 0x7FFF_FFFF_FFFF_FFFF, 0, 0;
	for split(query, "&",, temp) {
		kv := split(it, "=",, temp);
		if kv.count != 2 continue;
		n, ok := string_to_int(kv[1], T = s64);
		if !ok return json_error(c, 400, 50035, "Invalid Form Body");
		if kv[0] == {
		case "limit";
			if n < 1 || n > 100 return json_error(c, 400, 50035, "Invalid Form Body");
			limit = cast(int) n;
		case "before"; before = n;
		case "user_id"; by = n;
		case "action_type"; action = cast(int) n;
		}
	}
	locks.guard(*s.db_mu);
	if !can_locked(s, user, P_VIEW_AUDIT_LOG) return json_error(c, 403, 50013, "Missing Permissions");
	entries: [..]etf.Value;
	entries.allocator = temp;
	ids: [..]s64;
	ids.allocator = temp;
	st := sqlite.prepare(s.db, "SELECT id, user, action, target, changes, reason FROM audit WHERE id < ? AND (? = 0 OR user = ?) AND (? = 0 OR action = ?) ORDER BY id DESC LIMIT ?;");
	sqlite.bind_all(st, before, by, by, action, action, limit);
	while sqlite.step(st) == .Row {
		m := etf.map_builder(7,, temp);
		who := sqlite.col_int(st, 1);
		target := sqlite.col_int(st, 3);
		etf.map_put(*m, "id", snow(sqlite.col_int(st, 0)));
		etf.map_put(*m, "user_id", snow(who));
		etf.map_put(*m, "target_id", ifx sqlite.col_is_null(st, 3) then etf.Value.{} else snow(target));
		etf.map_put(*m, "action_type", etf.vint(sqlite.col_int(st, 2)));
		changes, err := etf.from_json(copy_string(sqlite.col_text(st, 4),, temp),, temp);
		if err == .None && changes.kind == .List && changes.list.count etf.map_put(*m, "changes", changes);
		if !sqlite.col_is_null(st, 5) etf.map_put(*m, "reason", etf.vstring(copy_string(sqlite.col_text(st, 5),, temp)));
		array_add(*entries, etf.vmap(etf.map_done(*m)));
		array_add_if_unique(*ids, who);
		if target && target != s.guild array_add_if_unique(*ids, target);
	}
	sqlite.finalize(st);
	users: [..]etf.Value;
	users.allocator = temp;
	st = sqlite.prepare(s.db, "SELECT name FROM users WHERE id = ?;");
	for ids {
		sqlite.reset(st);
		sqlite.bind(st, 1, it);
		if sqlite.step(st) == .Row array_add(*users, user_value(s, it, copy_string(sqlite.col_text(st, 0),, temp)));
	}
	sqlite.finalize(st);
	m := etf.map_builder(8,, temp);
	etf.map_put(*m, "audit_log_entries", etf.vlist(entries));
	etf.map_put(*m, "users", etf.vlist(users));
	for string.["webhooks", "integrations", "threads", "guild_scheduled_events", "application_commands", "auto_moderation_rules"] etf.map_put(*m, it, etf.vlist(.[]));
	return json_reply(c, 200, etf.vmap(etf.map_done(*m)));
}

// PATCH /api/v9/webhooks/{id} {name?, channel_id?}: Manage Webhooks renames a webhook or moves it to another text
// channel (Server Settings' Integrations).
edit_webhook :: (c: *Conn, req: http.Request, user: s64, id: s64) -> bool {
	s := c.server;
	v, err := etf.from_json(cast(string) req.body,, temp);
	if err != .None || v.kind != .Map return json_error(c, 400, 50035, "Invalid Form Body");
	name_v, has_name := etf.map_get(v.map, "name");
	chan_v, has_chan := etf.map_get(v.map, "channel_id");
	name := ifx name_v.kind == .String then trim(name_v.s) else "";
	if has_name && (!name || name.count > 80 || !text_ok(name)) return json_error(c, 400, 50035, "Invalid Form Body");
	channel, cok := string_to_int(ifx chan_v.kind == .String then chan_v.s else "", T = s64);
	if has_chan && !cok return json_error(c, 400, 50035, "Invalid Form Body");
	locks.guard(*s.db_mu);
	if !can_locked(s, user, P_MANAGE_WEBHOOKS) return json_error(c, 403, 50013, "Missing Permissions");
	st := sqlite.prepare(s.db, tprint("% WHERE w.id = ?;", WEBHOOK_SELECT));
	sqlite.bind_all(st, id);
	found := sqlite.step(st) == .Row;
	old_name := ifx found then copy_string(sqlite.col_text(st, 2),, temp) else "";
	old_chan := ifx found then sqlite.col_int(st, 1) else 0;
	sqlite.finalize(st);
	if !found return json_error(c, 404, 10015, "Unknown Webhook");
	if has_chan && !text_like_locked(s, channel) return json_error(c, 400, 50035, "Invalid Form Body");
	changes: [..]etf.Value;
	changes.allocator = temp;
	ok := sqlite.exec(s.db, "BEGIN;");
	if ok && has_name && name != old_name {
		ok = sqlite.run(s.db, "UPDATE users SET name = ? WHERE id = ?;", name, id);
		array_add(*changes, audit_change("name", etf.vstring(old_name), etf.vstring(name)));
	}
	if ok && has_chan && channel != old_chan {
		ok = sqlite.run(s.db, "UPDATE webhooks SET channel = ? WHERE id = ?;", channel, id);
		array_add(*changes, audit_change("channel_id", snow(old_chan), snow(channel)));
	}
	if ok && changes.count audit_locked(s, user, AUDIT_WEBHOOK_UPDATE, id, changes, "");
	if !ok || !sqlite.exec(s.db, "COMMIT;") {
		sqlite.exec(s.db, "ROLLBACK;");
		return json_error(c, 500, 0, "500: Internal Server Error");
	}
	st = sqlite.prepare(s.db, tprint("% WHERE w.id = ?;", WEBHOOK_SELECT));
	defer sqlite.finalize(st);
	sqlite.bind_all(st, id);
	if sqlite.step(st) != .Row return json_error(c, 500, 0, "500: Internal Server Error");
	return json_reply(c, 200, row_webhook(s, st, true));
}
