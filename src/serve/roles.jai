// Roles and permissions, as Discord has them: @everyone (the guild's ID) and up to 250 more roles, each with a
// position and a permission set; members hold roles; channels carry overwrites for roles and members. A
// member's permissions in a channel follow Discord's order (base, @everyone's overwrite, role overwrites,
// the member's own), a thread takes its parent's, and the owner and administrators have every one. Without
// View Channel a channel and its threads are hidden: left out of READY, events, pages and search.

ROLE_SCHEMA :: #string SQL
CREATE TABLE IF NOT EXISTS roles(id INTEGER PRIMARY KEY, name TEXT NOT NULL, color INTEGER NOT NULL DEFAULT 0, hoist INTEGER NOT NULL DEFAULT 0, mentionable INTEGER NOT NULL DEFAULT 0, position INTEGER NOT NULL, permissions INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS member_roles(user INTEGER NOT NULL, role INTEGER NOT NULL, PRIMARY KEY(user, role));
CREATE INDEX IF NOT EXISTS member_roles_role ON member_roles(role);
CREATE TABLE IF NOT EXISTS overwrites(channel INTEGER NOT NULL, target INTEGER NOT NULL, type INTEGER NOT NULL, allow INTEGER NOT NULL, deny INTEGER NOT NULL, PRIMARY KEY(channel, target));
SQL

MAX_ROLES :: 250; // As on Discord.
MAX_OVERWRITES :: 100; // Per channel.
OWNER_RANK :: 1 << 30; // Above every role's position.

P_CREATE_INSTANT_INVITE : u64 : 1 << 0;
P_KICK_MEMBERS : u64 : 1 << 1;
P_BAN_MEMBERS : u64 : 1 << 2;
P_ADMINISTRATOR : u64 : 1 << 3;
P_MANAGE_CHANNELS : u64 : 1 << 4;
P_MANAGE_GUILD : u64 : 1 << 5;
P_ADD_REACTIONS : u64 : 1 << 6;
P_VIEW_AUDIT_LOG : u64 : 1 << 7;
P_VIEW_CHANNEL : u64 : 1 << 10;
P_SEND_MESSAGES : u64 : 1 << 11;
P_MANAGE_MESSAGES : u64 : 1 << 13;
P_ATTACH_FILES : u64 : 1 << 15;
P_READ_MESSAGE_HISTORY : u64 : 1 << 16;
P_MENTION_EVERYONE : u64 : 1 << 17;
P_CONNECT : u64 : 1 << 20;
P_SPEAK : u64 : 1 << 21;
P_CHANGE_NICKNAME : u64 : 1 << 26;
P_MANAGE_NICKNAMES : u64 : 1 << 27;
P_MANAGE_ROLES : u64 : 1 << 28;
P_MANAGE_WEBHOOKS : u64 : 1 << 29;
P_MANAGE_GUILD_EXPRESSIONS : u64 : 1 << 30;
P_MANAGE_EVENTS : u64 : 1 << 33;
P_MANAGE_THREADS : u64 : 1 << 34;
P_CREATE_PUBLIC_THREADS : u64 : 1 << 35;
P_SEND_MESSAGES_IN_THREADS : u64 : 1 << 38;
P_USE_SOUNDBOARD : u64 : 1 << 42;
P_CREATE_GUILD_EXPRESSIONS : u64 : 1 << 43;
P_CREATE_EVENTS : u64 : 1 << 44;
P_PIN_MESSAGES : u64 : 1 << 51;
P_ALL : u64 : (1 << 52) - 1; // Every flag Discord defines.

// A member's server-wide standing, read once per request: their roles and the permissions those give.
Perms_Of :: struct {
	user: s64;
	all: bool; // The owner, or an administrator.
	top: int;  // Their highest role's position; the owner outranks every role.
	base: u64;
	roles: [..]s64;
}

perms_of_locked :: (s: *Server, user: s64) -> Perms_Of {
	p: Perms_Of;
	p.user = user;
	p.roles.allocator = temp;
	if user && user == owner_id(s) {
		p.all, p.top, p.base = true, OWNER_RANK, P_ALL;
		return p;
	}
	st := sqlite.prepare(s.db, "SELECT id, permissions, position FROM roles WHERE id = ?1 OR id IN (SELECT role FROM member_roles WHERE user = ?2);");
	defer sqlite.finalize(st);
	sqlite.bind_all(st, s.guild, user);
	while sqlite.step(st) == .Row {
		id := sqlite.col_int(st, 0);
		p.base |= cast(u64) sqlite.col_int(st, 1);
		if id == s.guild continue;
		array_add(*p.roles, id);
		p.top = max(p.top, sqlite.col_int(st, 2));
	}
	if p.base & P_ADMINISTRATOR p.all, p.base = true, P_ALL;
	return p;
}

// The member's permissions in a channel (a thread: its parent's), 0 without View Channel or for a channel
// that doesn't exist.
channel_perms_locked :: (s: *Server, p: *Perms_Of, channel: s64) -> u64 {
	st := sqlite.prepare(s.db, "SELECT type, coalesce(parent, 0) FROM channels WHERE id = ?;");
	sqlite.bind_all(st, channel);
	found := sqlite.step(st) == .Row;
	if found && sqlite.col_int(st, 0) == THREAD channel = sqlite.col_int(st, 1);
	sqlite.finalize(st);
	if !found return 0;
	if p.all return P_ALL;
	perms := p.base;
	allow, deny: u64;
	mine_allow, mine_deny: u64;
	st = sqlite.prepare(s.db, "SELECT target, type, allow, deny FROM overwrites WHERE channel = ?;");
	sqlite.bind_all(st, channel);
	while sqlite.step(st) == .Row {
		target, a, d := sqlite.col_int(st, 0), cast(u64) sqlite.col_int(st, 2), cast(u64) sqlite.col_int(st, 3);
		if sqlite.col_int(st, 1) == 1 {
			if target == p.user { mine_allow, mine_deny = a, d; }
		} else if target == s.guild {
			perms = (perms & ~d) | a;
		} else if array_find(p.roles, target) {
			allow |= a;
			deny |= d;
		}
	}
	sqlite.finalize(st);
	perms = (perms & ~deny) | allow;
	perms = (perms & ~mine_deny) | mine_allow;
	return ifx perms & P_VIEW_CHANNEL then perms else 0;
}

// can_locked: whether user holds every flag of want, server-wide (channel 0) or in a channel.
can_locked :: (s: *Server, user: s64, want: u64, channel: s64 = 0) -> bool {
	p := perms_of_locked(s, user);
	got := ifx channel then channel_perms_locked(s, *p, channel) else p.base;
	return (got & want) == want;
}

// can_any_locked: whether user holds any flag of mask, server-wide.
can_any_locked :: (s: *Server, user: s64, mask: u64) -> bool { return (perms_of_locked(s, user).base & mask) != 0; }

// Whether the actor outranks target: never the owner, and otherwise a highest role above theirs.
outranks_locked :: (s: *Server, p: *Perms_Of, target: s64) -> bool {
	if target == owner_id(s) return false;
	if p.top == OWNER_RANK return true;
	return perms_of_locked(s, target).top < p.top;
}

// The channels and threads user can't see (or lacks the rest of want in), for leaving them out of lists
// and search.
hidden_channels_locked :: (s: *Server, user: s64, want: u64 = P_VIEW_CHANNEL) -> []s64 {
	hidden: [..]s64;
	hidden.allocator = temp;
	p := perms_of_locked(s, user);
	if p.all return hidden;
	st := sqlite.prepare(s.db, "SELECT id FROM channels;");
	defer sqlite.finalize(st);
	ids: [..]s64;
	ids.allocator = temp;
	while sqlite.step(st) == .Row array_add(*ids, sqlite.col_int(st, 0));
	for ids if (channel_perms_locked(s, *p, it) & want) != want array_add(*hidden, it);
	return hidden;
}

// An SQL list of IDs, "(0)" when empty, for `NOT IN`.
id_list :: (ids: []s64) -> string {
	if !ids return "(0)";
	sb: String_Builder;
	sb.allocator = temp;
	append(*sb, "(");
	for ids print_to_builder(*sb, "%1%2", ifx it_index then "," else "", it);
	append(*sb, ")");
	return builder_to_string(*sb,, temp);
}

// Whether everyone sees a channel (or it no longer exists), so its events need no filtering.
public_locked :: (s: *Server, channel: s64) -> bool {
	st := sqlite.prepare(s.db, "SELECT type, coalesce(parent, 0) FROM channels WHERE id = ?;");
	sqlite.bind_all(st, channel);
	found := sqlite.step(st) == .Row;
	if found && sqlite.col_int(st, 0) == THREAD channel = sqlite.col_int(st, 1);
	sqlite.finalize(st);
	if !found return true;
	st = sqlite.prepare(s.db, "SELECT (SELECT permissions FROM roles WHERE id = ?1), EXISTS (SELECT 1 FROM overwrites WHERE channel = ?2 AND deny & ?3 != 0);");
	defer sqlite.finalize(st);
	sqlite.bind_all(st, s.guild, channel, P_VIEW_CHANNEL);
	if sqlite.step(st) != .Row return false;
	everyone := cast(u64) sqlite.col_int(st, 0);
	return (everyone & (P_VIEW_CHANNEL | P_ADMINISTRATOR)) != 0 && !sqlite.col_int(st, 1);
}

// The channel an event is about, for showing it only to those who see that channel; 0 for guild-wide events.
// A thread's events go by its parent, which may already be gone along with it.
event_channel :: (t: string, d: etf.Value) -> s64 {
	if d.kind != .Map return 0;
	key := "channel_id";
	if t == "CHANNEL_CREATE" || t == "CHANNEL_UPDATE" key = "id";
	else if begins_with(t, "THREAD_") key = "parent_id";
	else if !begins_with(t, "MESSAGE_") && t != "TYPING_START" && t != "CHANNEL_PINS_UPDATE" && !begins_with(t, "GUILD_SCHEDULED_EVENT_") && t != "VOICE_STATE_UPDATE" return 0;
	v, _ := etf.map_get(d.map, key);
	if v.kind != .String return 0;
	id, _ := string_to_int(v.s, T = s64);
	return id;
}

// The members with a gateway open (each once), or just `only`'s if they have one.
connected_users :: (s: *Server, only: s64 = 0) -> []s64 {
	users: [..]s64;
	users.allocator = temp;
	locks.guard(*s.mu);
	for s.conns if it.ws && it.user && (!only || it.user == only) array_add_if_unique(*users, it.user);
	return users;
}

// The members of users who see channel.
viewers :: (s: *Server, channel: s64, users: []s64) -> []s64 {
	out: [..]s64;
	out.allocator = temp;
	locks.guard(*s.db_mu);
	for users {
		p := perms_of_locked(s, it);
		if channel_perms_locked(s, *p, channel) array_add(*out, it);
	}
	return out;
}

// send_to dispatches one event to the gateways of the members in users.
send_to :: (s: *Server, users: []s64, t: string, d: etf.Value) {
	locks.guard(*s.mu);
	for s.conns if it.ws && array_find(users, it.user) dispatch(it, t, d);
}

// resync tells members which channels they now see, after a change to roles, a member's roles or
// overwrites: CHANNEL_UPDATE for each channel they see (the client adds one it didn't have) and
// CHANNEL_DELETE for each they don't, and the same with THREAD_UPDATE and THREAD_DELETE for open threads.
resync :: (s: *Server, only: s64 = 0) {
	users := connected_users(s, only);
	Send :: struct { user: s64; t: string; d: etf.Value; }
	sends: [..]Send;
	sends.allocator = temp;
	{
		locks.guard(*s.db_mu);
		for u: users {
			p := perms_of_locked(s, u);
			st := sqlite.prepare(s.db, tprint("% WHERE c.type != % OR c.archived = 0 ORDER BY c.type = %, c.position, c.id;", CHANNEL_SELECT, THREAD, THREAD));
			while sqlite.step(st) == .Row {
				thread := sqlite.col_int(st, 5) == THREAD;
				ch := row_channel(s, st);
				seen := channel_perms_locked(s, *p, sqlite.col_int(st, 0)) != 0;
				t := ifx thread then ifx seen then "THREAD_UPDATE" else "THREAD_DELETE" else ifx seen then "CHANNEL_UPDATE" else "CHANNEL_DELETE";
				array_add(*sends, .{u, t, ch});
			}
			sqlite.finalize(st);
		}
	}
	locks.guard(*s.mu);
	for c: s.conns if c.ws for sends if it.user == c.user dispatch(c, it.t, it.d);
}

// A role as Discord sends it; the caller holds db_mu.
ROLE_SELECT :: "SELECT id, name, color, hoist, mentionable, position, permissions FROM roles";

row_role :: (st: *sqlite.Stmt) -> etf.Value {
	color := sqlite.col_int(st, 2);
	colors := etf.map_builder(3,, temp);
	etf.map_put(*colors, "primary_color", etf.vint(color));
	etf.map_put(*colors, "secondary_color", .{});
	etf.map_put(*colors, "tertiary_color", .{});
	m := etf.map_builder(13,, temp);
	etf.map_put(*m, "id", snow(sqlite.col_int(st, 0)));
	etf.map_put(*m, "name", etf.vstring(copy_string(sqlite.col_text(st, 1),, temp)));
	etf.map_put(*m, "color", etf.vint(color));
	etf.map_put(*m, "colors", etf.vmap(etf.map_done(*colors)));
	etf.map_put(*m, "hoist", etf.vbool(sqlite.col_int(st, 3) != 0));
	etf.map_put(*m, "icon", .{});
	etf.map_put(*m, "unicode_emoji", .{});
	etf.map_put(*m, "position", etf.vint(sqlite.col_int(st, 5)));
	etf.map_put(*m, "permissions", etf.vstring(tprint("%", sqlite.col_int(st, 6))));
	etf.map_put(*m, "managed", etf.vbool(false));
	etf.map_put(*m, "mentionable", etf.vbool(sqlite.col_int(st, 4) != 0));
	etf.map_put(*m, "flags", etf.vint(0));
	return etf.vmap(etf.map_done(*m));
}

role_list_locked :: (s: *Server) -> etf.Value {
	list: [..]etf.Value;
	list.allocator = temp;
	st := sqlite.prepare(s.db, tprint("% ORDER BY position, id;", ROLE_SELECT));
	defer sqlite.finalize(st);
	while sqlite.step(st) == .Row array_add(*list, row_role(st));
	return etf.vlist(list);
}

role_locked :: (s: *Server, id: s64) -> etf.Value {
	st := sqlite.prepare(s.db, tprint("% WHERE id = ?;", ROLE_SELECT));
	defer sqlite.finalize(st);
	sqlite.bind_all(st, id);
	if sqlite.step(st) != .Row return .{};
	return row_role(st);
}

// A member's role IDs, as members carry them.
member_roles_locked :: (s: *Server, user: s64) -> etf.Value {
	list: [..]etf.Value;
	list.allocator = temp;
	st := sqlite.prepare(s.db, "SELECT m.role FROM member_roles m JOIN roles r ON r.id = m.role WHERE m.user = ? ORDER BY r.position DESC;");
	defer sqlite.finalize(st);
	sqlite.bind_all(st, user);
	while sqlite.step(st) == .Row array_add(*list, snow(sqlite.col_int(st, 0)));
	return etf.vlist(list);
}

// A channel's permission_overwrites; the caller holds db_mu.
overwrites_locked :: (s: *Server, channel: s64) -> etf.Value {
	list: [..]etf.Value;
	list.allocator = temp;
	st := sqlite.prepare(s.db, "SELECT target, type, allow, deny FROM overwrites WHERE channel = ? ORDER BY type, target;");
	defer sqlite.finalize(st);
	sqlite.bind_all(st, channel);
	while sqlite.step(st) == .Row {
		m := etf.map_builder(4,, temp);
		etf.map_put(*m, "id", snow(sqlite.col_int(st, 0)));
		etf.map_put(*m, "type", etf.vint(sqlite.col_int(st, 1)));
		etf.map_put(*m, "allow", etf.vstring(tprint("%", sqlite.col_int(st, 2))));
		etf.map_put(*m, "deny", etf.vstring(tprint("%", sqlite.col_int(st, 3))));
		array_add(*list, etf.vmap(etf.map_done(*m)));
	}
	return etf.vlist(list);
}

// A permission set as Discord's JSON gives it, a decimal string (or a number); false when it's neither or
// names flags Discord doesn't have.
perms_value :: (v: etf.Value) -> u64, bool {
	n: s64;
	ok := true;
	if v.kind == .String n, ok = string_to_int(v.s, T = s64);
	else if v.kind == .Int n = v.i;
	else return 0, false;
	return cast(u64) n, ok && n >= 0 && ((cast(u64) n) & ~P_ALL) == 0;
}

// Overwrite :: {target, type, allow, deny}; read from a permission_overwrites entry.
Overwrite :: struct { target: s64; type: int; allow: u64; deny: u64; }

overwrite_value :: (v: etf.Value) -> Overwrite, bool {
	o: Overwrite;
	if v.kind != .Map return o, false;
	id, _ := etf.map_get(v.map, "id");
	type, _ := etf.map_get(v.map, "type");
	allow, _ := etf.map_get(v.map, "allow");
	deny, _ := etf.map_get(v.map, "deny");
	ok1, ok2, ok3 := false, true, true;
	if id.kind == .String o.target, ok1 = string_to_int(id.s, T = s64);
	if allow.kind != .Nil o.allow, ok2 = perms_value(allow);
	if deny.kind != .Nil o.deny, ok3 = perms_value(deny);
	if type.kind == .String type = etf.vint(string_to_int(type.s));
	o.type = ifx type.kind == .Int then cast(int) type.i else -1;
	return o, ok1 && ok2 && ok3 && (o.type == 0 || o.type == 1);
}

// set_overwrite_locked checks one overwrite against the actor (who may only grant or deny what they hold
// in the channel) and the target (a role of this server or a member), then keeps it. Returns the error code
// for json_error, 0 when kept.
set_overwrite_locked :: (s: *Server, p: *Perms_Of, channel: s64, o: Overwrite) -> status: int, code: int {
	if !p.all {
		mine := channel_perms_locked(s, p, channel);
		if !mine mine = p.base; // A channel the actor hides from themselves while making it.
		if ((o.allow | o.deny) & ~mine) return 403, 50013;
	}
	st := sqlite.prepare(s.db, ifx o.type == 0 then "SELECT 1 FROM roles WHERE id = ?;" else "SELECT 1 FROM users WHERE id = ? AND left = 0;");
	sqlite.bind_all(st, o.target);
	known := sqlite.step(st) == .Row;
	sqlite.finalize(st);
	if !known return 400, 50035;
	st = sqlite.prepare(s.db, "SELECT count(*) FROM overwrites WHERE channel = ? AND target != ?;");
	sqlite.bind_all(st, channel, o.target);
	n := ifx sqlite.step(st) == .Row then sqlite.col_int(st, 0) else 0;
	sqlite.finalize(st);
	if n >= MAX_OVERWRITES return 400, 30046;
	if !sqlite.run(s.db, "INSERT INTO overwrites(channel, target, type, allow, deny) VALUES(?, ?, ?, ?, ?) ON CONFLICT(channel, target) DO UPDATE SET type = excluded.type, allow = excluded.allow, deny = excluded.deny;",
		channel, o.target, o.type, cast(s64) o.allow, cast(s64) o.deny) return 500, 0;
	return 0, 0;
}

// PUT /api/v9/channels/{id}/permissions/{target} {type, allow, deny} and DELETE: a channel's overwrites, for
// those with Manage Roles there.
channel_permission :: (c: *Conn, req: http.Request, user: s64, channel: s64, target_text: string) -> bool {
	s := c.server;
	target, tok := string_to_int(target_text, T = s64);
	if !tok return json_error(c, 404, 10009, "Unknown Overwrite");
	o: Overwrite;
	if req.method == "PUT" {
		v, err := etf.from_json(cast(string) req.body,, temp);
		if err != .None || v.kind != .Map return json_error(c, 400, 50035, "Invalid Form Body");
		m := etf.map_builder(v.map.count + 1,, temp);
		for v.map etf.map_put(*m, it.key.s, it.value);
		etf.map_put(*m, "id", etf.vstring(target_text));
		ok: bool;
		o, ok = overwrite_value(etf.vmap(etf.map_done(*m)));
		if !ok return json_error(c, 400, 50035, "Invalid Form Body");
	} else if req.method != "DELETE" return json_error(c, 405, 0, "405: Method Not Allowed");
	{
		locks.guard(*s.db_mu);
		kind := channel_type_locked(s, channel);
		if kind < 0 || kind == THREAD return json_error(c, 404, 10003, "Unknown Channel");
		p := perms_of_locked(s, user);
		if !(channel_perms_locked(s, *p, channel) & P_MANAGE_ROLES) return json_error(c, 403, 50013, "Missing Permissions");
		if req.method == "PUT" {
			status, code := set_overwrite_locked(s, *p, channel, o);
			if status return json_error(c, status, code, ifx status == 403 then "Missing Permissions" else "Invalid Form Body");
		} else if !sqlite.run(s.db, "DELETE FROM overwrites WHERE channel = ? AND target = ?;", channel, target) return json_error(c, 500, 0, "500: Internal Server Error");
		audit_locked(s, user, ifx req.method == "PUT" then AUDIT_OVERWRITE_UPDATE else AUDIT_OVERWRITE_DELETE, channel, .[], "");
	}
	resync(s);
	return respond(c, 204, json = false);
}

AUDIT_OVERWRITE_UPDATE :: 14;
AUDIT_OVERWRITE_DELETE :: 15;
AUDIT_MEMBER_ROLE_UPDATE :: 25;
AUDIT_ROLE_CREATE :: 30;
AUDIT_ROLE_UPDATE :: 31;
AUDIT_ROLE_DELETE :: 32;

// The roles routes: GET and POST /guilds/{id}/roles, PATCH there with [{id, position}] to reorder,
// PATCH and DELETE /guilds/{id}/roles/{role}, GET /guilds/{id}/roles/member-counts, and
// PUT and DELETE /guilds/{id}/members/{user}/roles/{role}. Managing takes Manage Roles, and only roles below
// your highest; no one grants permissions they lack. @everyone keeps its name and position.
roles :: (c: *Conn, req: http.Request) -> bool {
	s := c.server;
	token, _ := http.header_get(req.headers, "authorization");
	user := session_user(c, token);
	if !user return json_error(c, 401, 0, "401: Unauthorized");
	base := tprint("/api/v9/guilds/%/", s.guild);
	parts := split(advance(req.path, base.count), "/",, temp); // roles[/{id}] or members/{user}/roles/{id}
	if parts[0] == "members" return member_role(c, req, user, parts);
	if parts.count == 2 && parts[1] == "member-counts" && req.method == "GET" {
		m := etf.map_builder(16,, temp);
		{
			locks.guard(*s.db_mu);
			st := sqlite.prepare(s.db, "SELECT r.id, (SELECT count(*) FROM member_roles m JOIN users u ON u.id = m.user WHERE m.role = r.id AND u.left = 0) FROM roles r WHERE r.id != ?;");
			sqlite.bind_all(st, s.guild);
			while sqlite.step(st) == .Row etf.map_put(*m, tprint("%", sqlite.col_int(st, 0)), etf.vint(sqlite.col_int(st, 1)));
			sqlite.finalize(st);
		}
		return json_reply(c, 200, etf.vmap(etf.map_done(*m)));
	}
	if parts.count == 1 && req.method == "GET" {
		locks.guard(*s.db_mu);
		return json_reply(c, 200, role_list_locked(s));
	}
	id: s64;
	if parts.count == 2 {
		ok: bool;
		id, ok = string_to_int(parts[1], T = s64);
		if !ok return json_error(c, 404, 10011, "Unknown Role");
	} else if parts.count != 1 return json_error(c, 404, 0, "404: Not Found");
	reorder := !id && req.method == "PATCH";
	if !reorder && ((id == 0) != (req.method == "POST") || (id && req.method != "PATCH" && req.method != "DELETE")) return json_error(c, 405, 0, "405: Method Not Allowed");
	reason, reason_ok := audit_reason(req);
	if !reason_ok return json_error(c, 400, 50035, "Invalid Form Body");
	v: etf.Value;
	if req.method != "DELETE" && req.body.count {
		err: etf.Error;
		v, err = etf.from_json(cast(string) req.body,, temp);
		if err != .None || (v.kind != .Map && !reorder) || (reorder && v.kind != .List) return json_error(c, 400, 50035, "Invalid Form Body");
	}
	field :: (v: etf.Value, k: string) -> etf.Value, bool { if v.kind != .Map return .{}, false; f, ok := etf.map_get(v.map, k); return f, ok; }
	name_v, has_name := field(v, "name");
	perms_v, has_perms := field(v, "permissions");
	color_v, has_color := field(v, "color");
	colors_v, has_colors := field(v, "colors");
	hoist_v, has_hoist := field(v, "hoist");
	mention_v, has_mention := field(v, "mentionable");
	name := ifx name_v.kind == .String then trim(name_v.s) else "";
	if has_name && (!name || name.count > 100 || !text_ok(name)) return json_error(c, 400, 50035, "Invalid Form Body");
	perms: u64;
	if has_perms && perms_v.kind != .Nil {
		ok: bool;
		perms, ok = perms_value(perms_v);
		if !ok return json_error(c, 400, 50035, "Invalid Form Body");
	}
	if has_colors && colors_v.kind == .Map { color_v, has_color = etf.map_get(colors_v.map, "primary_color"); }
	color := ifx color_v.kind == .Int then color_v.i else 0;
	if (has_color && color_v.kind != .Int && color_v.kind != .Nil) || color < 0 || color > 0xFFFFFF return json_error(c, 400, 50035, "Invalid Form Body");
	if (has_hoist && hoist_v.kind != .Bool) || (has_mention && mention_v.kind != .Bool) return json_error(c, 400, 50035, "Invalid Form Body");

	Event :: struct { t: string; d: etf.Value; }
	events: [..]Event;
	events.allocator = temp;
	reply: etf.Value;
	{
		locks.guard(*s.db_mu);
		p := perms_of_locked(s, user);
		if !(p.base & P_MANAGE_ROLES) return json_error(c, 403, 50013, "Missing Permissions");
		if has_perms && !p.all && (perms & ~p.base) return json_error(c, 403, 50013, "Missing Permissions");
		event_of :: (s: *Server, t: string, role: etf.Value) -> Event {
			d := etf.map_builder(2,, temp);
			etf.map_put(*d, "guild_id", snow(s.guild));
			etf.map_put(*d, "role", role);
			return .{t, etf.vmap(etf.map_done(*d))};
		}
		if reorder {
			for v.list {
				rid_v, _ := field(it, "id");
				pos_v, _ := field(it, "position");
				rid, ok := string_to_int(ifx rid_v.kind == .String then rid_v.s else "", T = s64);
				if !ok || pos_v.kind != .Int || pos_v.i < 1 || pos_v.i > MAX_ROLES || rid == s.guild return json_error(c, 400, 50035, "Invalid Form Body");
				st := sqlite.prepare(s.db, "SELECT position FROM roles WHERE id = ?;");
				sqlite.bind_all(st, rid);
				found := sqlite.step(st) == .Row;
				old := ifx found then sqlite.col_int(st, 0) else 0;
				sqlite.finalize(st);
				if !found return json_error(c, 400, 50035, "Invalid Form Body");
				if !p.all && (old >= p.top || pos_v.i >= p.top) return json_error(c, 403, 50013, "Missing Permissions");
				if !sqlite.run(s.db, "UPDATE roles SET position = ? WHERE id = ?;", pos_v.i, rid) return json_error(c, 500, 0, "500: Internal Server Error");
				array_add(*events, event_of(s, "GUILD_ROLE_UPDATE", role_locked(s, rid)));
			}
			reply = role_list_locked(s);
		} else if id == 0 {
			st := sqlite.prepare(s.db, "SELECT count(*) FROM roles;");
			n := ifx sqlite.step(st) == .Row then sqlite.col_int(st, 0) else 0;
			sqlite.finalize(st);
			if n > MAX_ROLES return json_error(c, 400, 30005, tprint("Maximum number of guild roles reached (%)", MAX_ROLES));
			// A new role sits just above @everyone, as on Discord, and the others move up one.
			id = snowflake(s);
			ok := sqlite.run(s.db, "UPDATE roles SET position = position + 1 WHERE id != ?;", s.guild)
				&& sqlite.run(s.db, "INSERT INTO roles(id, name, color, hoist, mentionable, position, permissions) VALUES(?, ?, ?, ?, ?, 1, ?);",
					id, ifx name then name else "new role", color, cast(int) (hoist_v.kind == .Bool && hoist_v.b), cast(int) (mention_v.kind == .Bool && mention_v.b), cast(s64) perms);
			if !ok return json_error(c, 500, 0, "500: Internal Server Error");
			st = sqlite.prepare(s.db, "SELECT id FROM roles WHERE id NOT IN (?, ?);");
			sqlite.bind_all(st, s.guild, id);
			moved: [..]s64;
			moved.allocator = temp;
			while sqlite.step(st) == .Row array_add(*moved, sqlite.col_int(st, 0));
			sqlite.finalize(st);
			reply = role_locked(s, id);
			array_add(*events, event_of(s, "GUILD_ROLE_CREATE", reply));
			for moved array_add(*events, event_of(s, "GUILD_ROLE_UPDATE", role_locked(s, it)));
			audit_locked(s, user, AUDIT_ROLE_CREATE, id, .[audit_change("name", .{}, etf.vstring(ifx name then name else "new role"))], reason);
		} else {
			st := sqlite.prepare(s.db, "SELECT position, name FROM roles WHERE id = ?;");
			sqlite.bind_all(st, id);
			found := sqlite.step(st) == .Row;
			position := ifx found then sqlite.col_int(st, 0) else 0;
			old_name := ifx found then copy_string(sqlite.col_text(st, 1),, temp) else "";
			sqlite.finalize(st);
			if !found return json_error(c, 404, 10011, "Unknown Role");
			everyone := id == s.guild;
			if !p.all && !everyone && position >= p.top return json_error(c, 403, 50013, "Missing Permissions");
			if req.method == "DELETE" {
				if everyone return json_error(c, 400, 50028, "Invalid Role");
				ok := sqlite.run(s.db, "DELETE FROM roles WHERE id = ?;", id)
					&& sqlite.run(s.db, "DELETE FROM member_roles WHERE role = ?;", id)
					&& sqlite.run(s.db, "DELETE FROM overwrites WHERE target = ? AND type = 0;", id);
				if !ok return json_error(c, 500, 0, "500: Internal Server Error");
				d := etf.map_builder(2,, temp);
				etf.map_put(*d, "guild_id", snow(s.guild));
				etf.map_put(*d, "role_id", snow(id));
				array_add(*events, .{"GUILD_ROLE_DELETE", etf.vmap(etf.map_done(*d))});
				audit_locked(s, user, AUDIT_ROLE_DELETE, id, .[audit_change("name", etf.vstring(old_name), .{})], reason);
			} else {
				if everyone && (has_name || has_color || has_hoist || has_mention) return json_error(c, 400, 50035, "Invalid Form Body");
				ok := (!has_name || sqlite.run(s.db, "UPDATE roles SET name = ? WHERE id = ?;", name, id))
					&& (!has_perms || sqlite.run(s.db, "UPDATE roles SET permissions = ? WHERE id = ?;", cast(s64) perms, id))
					&& (!has_color || sqlite.run(s.db, "UPDATE roles SET color = ? WHERE id = ?;", color, id))
					&& (!has_hoist || sqlite.run(s.db, "UPDATE roles SET hoist = ? WHERE id = ?;", cast(int) hoist_v.b, id))
					&& (!has_mention || sqlite.run(s.db, "UPDATE roles SET mentionable = ? WHERE id = ?;", cast(int) mention_v.b, id));
				if !ok return json_error(c, 500, 0, "500: Internal Server Error");
				reply = role_locked(s, id);
				array_add(*events, event_of(s, "GUILD_ROLE_UPDATE", reply));
				changes: [..]etf.Value;
				changes.allocator = temp;
				if has_name array_add(*changes, audit_change("name", etf.vstring(old_name), etf.vstring(name)));
				if has_perms array_add(*changes, audit_change("permissions", .{}, etf.vstring(tprint("%", perms))));
				audit_locked(s, user, AUDIT_ROLE_UPDATE, id, changes, reason);
			}
		}
	}
	for events broadcast(s, it.t, it.d);
	if has_perms || req.method == "DELETE" resync(s);
	if req.method == "DELETE" return respond(c, 204, json = false);
	return json_reply(c, ifx req.method == "POST" then 201 else 200, reply);
}

// PUT and DELETE /guilds/{id}/members/{user}/roles/{role}: give a member a role or take it away.
member_role :: (c: *Conn, req: http.Request, user: s64, parts: []string) -> bool {
	s := c.server;
	if parts.count != 4 || parts[2] != "roles" return json_error(c, 404, 0, "404: Not Found");
	if req.method != "PUT" && req.method != "DELETE" return json_error(c, 405, 0, "405: Method Not Allowed");
	target, tok := string_to_int(parts[1], T = s64);
	role, rok := string_to_int(parts[3], T = s64);
	if !tok return json_error(c, 404, 10007, "Unknown Member");
	if !rok return json_error(c, 404, 10011, "Unknown Role");
	reason, reason_ok := audit_reason(req);
	if !reason_ok return json_error(c, 400, 50035, "Invalid Form Body");
	ids: []s64 = .[role];
	none: []s64;
	member, status, code := set_member_roles(c.server, user, target, ifx req.method == "PUT" then ids else none, ifx req.method == "DELETE" then ids else none, reason);
	if status return json_error(c, status, code, ifx status == 403 then "Missing Permissions" else ifx status == 404 then "Unknown Member" else "Invalid Form Body");
	return respond(c, 204, json = false);
}

// set_member_roles gives target the roles in add and takes away those in drop, each one the actor may
// manage, then tells everyone (GUILD_MEMBER_UPDATE) and the target which channels they now see. Returns the
// member, or an HTTP status and code.
set_member_roles :: (s: *Server, user: s64, target: s64, add: []s64, drop: []s64, reason: string) -> member: etf.Value, status: int, code: int {
	member: etf.Value;
	{
		locks.guard(*s.db_mu);
		p := perms_of_locked(s, user);
		if !(p.base & P_MANAGE_ROLES) return .{}, 403, 50013;
		st := sqlite.prepare(s.db, "SELECT name FROM users WHERE id = ? AND left = 0;");
		sqlite.bind_all(st, target);
		found := sqlite.step(st) == .Row;
		name := ifx found then copy_string(sqlite.col_text(st, 0),, temp) else "";
		sqlite.finalize(st);
		if !found return .{}, 404, 10007;
		changes: [..]etf.Value;
		changes.allocator = temp;
		for role: add {
			st = sqlite.prepare(s.db, "SELECT position FROM roles WHERE id = ? AND id != ?;");
			sqlite.bind_all(st, role, s.guild);
			known := sqlite.step(st) == .Row;
			position := ifx known then sqlite.col_int(st, 0) else 0;
			sqlite.finalize(st);
			if !known return .{}, 400, 50028;
			if !p.all && position >= p.top return .{}, 403, 50013;
		}
		for role: drop {
			st = sqlite.prepare(s.db, "SELECT position FROM roles WHERE id = ?;");
			sqlite.bind_all(st, role);
			position := ifx sqlite.step(st) == .Row then sqlite.col_int(st, 0) else 0;
			sqlite.finalize(st);
			if !p.all && position >= p.top return .{}, 403, 50013;
		}
		for add if !sqlite.run(s.db, "INSERT OR IGNORE INTO member_roles(user, role) VALUES(?, ?);", target, it) return .{}, 500, 0;
		for drop if !sqlite.run(s.db, "DELETE FROM member_roles WHERE user = ? AND role = ?;", target, it) return .{}, 500, 0;
		ids :: (l: []s64) -> etf.Value {
			out := NewArray(l.count, etf.Value,, temp);
			for l out[it_index] = snow(it);
			return etf.vlist(out);
		}
		if add.count array_add(*changes, audit_change("$add", .{}, ids(add)));
		if drop.count array_add(*changes, audit_change("$remove", .{}, ids(drop)));
		audit_locked(s, user, AUDIT_MEMBER_ROLE_UPDATE, target, changes, reason);
		member = member_value_locked(s, target, name);
	}
	broadcast(s, "GUILD_MEMBER_UPDATE", member);
	broadcast(s, "GUILD_MEMBER_LIST_UPDATE", member_list_value(s));
	resync(s, target);
	return member, 0, 0;
}

// A member as GUILD_MEMBER_UPDATE and REST replies carry it; the caller holds db_mu.
member_value_locked :: (s: *Server, user: s64, name: string) -> etf.Value {
	m := etf.map_builder(5,, temp);
	etf.map_put(*m, "guild_id", snow(s.guild));
	etf.map_put(*m, "user", user_value(s, user, name));
	etf.map_put(*m, "nick", .{});
	etf.map_put(*m, "roles", member_roles_locked(s, user));
	etf.map_put(*m, "joined_at", etf.vstring(iso(user)));
	return etf.vmap(etf.map_done(*m));
}
