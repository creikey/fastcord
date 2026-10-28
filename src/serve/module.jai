/// A self-hosted fastcord server (`fastcord -serve`): one SQLite file, TLS 1.3 under a pinned self-signed certificate, ALPN fc/1.
#import "Basic";
#import "Atomics";
#import "Thread";
#import "String";
#import "Base64";
crypto :: #import "crypto";
etf :: #import "etf";
http :: #import "http";
keys :: #import "keys";
locks :: #import "locks";
netio :: #import "netio";
sqlite :: #import "sqlite";
tls :: #import "tls";

ALPN :: "fc/1";
HEARTBEAT_INTERVAL_MS :: 41_250;

Server :: struct {
	db: *sqlite.DB;
	db_mu: locks.Mutex; // A connection's statements run on one thread at a time.
	id: [16]u8;     // Sent as SNI and part of every invite, so one host can serve several servers.
	pin: [32]u8;     // BLAKE3 of the certificate: what invites carry and clients check.
	ctx: *tls.SSL_CTX;
	listener: *netio.Listener;
	accept_thread: *Thread;
	mu: locks.Mutex; // Guards conns.
	conns: [..]*Conn;
	seq: u32; // atomic; the low bits of snowflakes
	guild: s64; // The guild ID the client sees.
	name: string;
}

Conn :: struct {
	server: *Server;
	tcp: *netio.Tcp;
	s: netio.Stream;
	thread: *Thread;
	done: bool; // atomic; the thread has finished with s.
	ws: *http.Ws_Conn; // Under server.mu: set once Identify succeeds, so broadcasts reach it.
	user: s64;         // Under server.mu, with ws.
	mu: locks.Mutex;   // Orders this gateway's dispatches: seq and their sends.
	seq: int;
}

// open makes the server file if needed: its ID, TLS key and certificate live in it, so the invite stays
// valid for as long as the file does. A new server is named after the file and gets #general and an
// unlimited invite.
open :: (path: string) -> *Server, bool {
	db, ok := sqlite.open(path);
	if !ok return null, false;
	s := New(Server);
	s.db = db;
	if !sqlite.exec(db, SCHEMA) { close(s); return null, false; }
	// Files made before these columns; each fails harmlessly once it exists.
	sqlite.exec(db, "ALTER TABLE messages ADD COLUMN reply INTEGER;");
	sqlite.exec(db, "ALTER TABLE channels ADD COLUMN topic TEXT NOT NULL DEFAULT '';");
	sqlite.exec(db, "ALTER TABLE invites ADD COLUMN owner INTEGER NOT NULL DEFAULT 0;");
	sqlite.exec(db, "ALTER TABLE invites ADD COLUMN inviter INTEGER;");
	sqlite.exec(db, "ALTER TABLE invites ADD COLUMN channel INTEGER;");
	sqlite.exec(db, "ALTER TABLE invites ADD COLUMN max_age INTEGER NOT NULL DEFAULT 0;");
	sqlite.exec(db, "ALTER TABLE invites ADD COLUMN expires INTEGER NOT NULL DEFAULT 0;");

	id := meta_get(s, "id");
	key := meta_get(s, "tls_key");
	cert := meta_get(s, "tls_cert");
	if id.count != 16 || key.count != 32 || !cert.count {
		crypto.random_bytes(s.id);
		priv, _, made := crypto.p256_generate();
		if !made { close(s); return null, false; }
		cert = tls.selfsigned_cert(priv,, temp);
		key = array_copy(cast([]u8) priv,, temp);
		code: [6]u8;
		crypto.random_bytes(code);
		ok = sqlite.exec(db, "BEGIN;")
			&& meta_put(s, "id", s.id)
			&& meta_put(s, "tls_key", key)
			&& meta_put(s, "tls_cert", cert)
			&& meta_put(s, "name", path_strip_extension(path_filename(path)))
			&& meta_put(s, "guild_id", tprint("%", snowflake(s)))
			&& sqlite.run(db, "INSERT INTO channels(id, name, position) VALUES(?, 'general', 0);", snowflake(s))
			&& sqlite.run(db, "INSERT INTO invites(code, uses_left) VALUES(?, -1);", hex(code,, temp))
			&& sqlite.exec(db, "COMMIT;");
		if !ok { close(s); return null, false; }
	} else {
		memcpy(s.id.data, id.data, 16);
	}
	s.guild = string_to_int(cast(string) meta_get(s, "guild_id"), T = s64);
	s.name = copy_string(cast(string) meta_get(s, "name"));
	if !s.guild { close(s); return null, false; }
	// Until someone claims the server, a one-use owner invite exists; the host joins with it first.
	if !meta_get(s, "owner") && !owner_invite(s) {
		code: [16]u8;
		crypto.random_bytes(code);
		sqlite.run(db, "INSERT INTO invites(code, uses_left, owner) VALUES(?, 1, 1);", hex(code,, temp));
	}
	k: [32]u8;
	memcpy(k.data, key.data, 32);
	s.pin = crypto.blake3(cert);
	s.ctx = tls.server_ctx(k, cert, ALPN);
	crypto.zero(k);
	if !s.ctx { close(s); return null, false; }
	return s, true;
}

// invite_url is what a member pastes into fastcord to join: the pin, where to connect and which server.
invite_url :: (s: *Server, host: string, port: int, code: string, allocator := temp) -> string {
	return invite_url(s.pin, host, port, hex(s.id,, temp), code,, allocator);
}

invite_url :: (pin: [32]u8, host: string, port: int, id_hex: string, code: string, allocator := temp) -> string {
	h := ifx contains(host, ":") then tprint("[%]", host) else host;
	return sprint("fc://%@%:%/%/%", hex(pin,, temp), h, port, id_hex, code,, allocator);
}

// first_invite is the oldest invite's code, the one the console prints.
first_invite :: (s: *Server, allocator := temp) -> string {
	locks.guard(*s.db_mu);
	st := sqlite.prepare(s.db, "SELECT code FROM invites WHERE owner = 0 ORDER BY rowid LIMIT 1;");
	defer sqlite.finalize(st);
	if sqlite.step(st) != .Row return "";
	return copy_string(sqlite.col_text(st, 0),, allocator);
}

// owner_invite is the unused code that makes its first user the owner, or "" once the server has one.
// An invite works while it has uses left (-1: unlimited) and hasn't expired (expires is Unix seconds, 0: never).
INVITE_LIVE :: "uses_left != 0 AND (expires = 0 OR expires > unixepoch())";

owner_invite :: (s: *Server, allocator := temp) -> string {
	locks.guard(*s.db_mu);
	st := sqlite.prepare(s.db, tprint("SELECT code FROM invites WHERE owner = 1 AND % LIMIT 1;", INVITE_LIVE));
	defer sqlite.finalize(st);
	if sqlite.step(st) != .Row return "";
	return copy_string(sqlite.col_text(st, 0),, allocator);
}

owner_id :: (s: *Server) -> s64 {
	return string_to_int(cast(string) meta_get(s, "owner"), T = s64);
}

// A member logs in by signing login_message with their identity's signing key, under LOGIN_CONTEXT. The
// exporter ties the signature to this TLS connection, so it can't be relayed to another server or
// replayed later; ALPN and server ID are bound as well, in case a key is ever reused elsewhere.
LOGIN_CONTEXT :: "fastcord 2026-10-28 login v1";
LOGIN_EXPORTER :: "EXPORTER-fastcord-login";

login_message :: (session: *tls.Session, server_id: [16]u8) -> []u8, bool {
	ex: [32]u8;
	if !tls.exporter(session, LOGIN_EXPORTER, server_id, ex) return .[], false;
	m := NewArray(32 + ALPN.count + 16, u8,, temp);
	memcpy(m.data, ex.data, 32);
	memcpy(m.data + 32, ALPN.data, ALPN.count);
	memcpy(m.data + 32 + ALPN.count, server_id.data, 16);
	return m, true;
}

// An fc:// invite, as invite_url writes it. host and code point into the parsed string.
Invite :: struct {
	pin: [32]u8;
	host: string;
	port: int;
	id: [16]u8;
	id_hex: string; // The server ID as SNI sends it.
	code: string;
}

parse_invite :: (url: string) -> Invite, bool {
	inv: Invite;
	if !begins_with(url, "fc://") return inv, false;
	rest := advance(url, "fc://".count);
	if rest.count < 65 || rest[64] != #char "@" || !unhex(slice(rest, 0, 64), inv.pin) return inv, false;
	rest = advance(rest, 65);
	slash := find_index_from_left(rest, #char "/");
	if slash < 0 return inv, false;
	hostport := slice(rest, 0, slash);
	colon := find_index_from_right(hostport, #char ":");
	if colon <= 0 return inv, false;
	inv.host = slice(hostport, 0, colon);
	if begins_with(inv.host, "[") && ends_with(inv.host, "]") inv.host = slice(inv.host, 1, inv.host.count - 2);
	port, ok := string_to_int(advance(hostport, colon + 1));
	if !ok || port <= 0 || port > 65535 return inv, false;
	inv.port = port;
	rest = trim_right(advance(rest, slash + 1), "/");
	slash = find_index_from_left(rest, #char "/");
	if slash != 32 || !unhex(slice(rest, 0, 32), inv.id) return inv, false;
	inv.id_hex = slice(rest, 0, 32);
	inv.code = advance(rest, 33);
	for inv.code if !is_alnum(it) return inv, false;
	return inv, inv.host.count > 0;
}

// member_login is the member's half of POST /api/v9/fc/login: dial the invite's server under its pin, sign
// over this connection's exporter, and get a session token (context.allocator). On failure the token is
// empty and status and message say why (status 0: the server couldn't be reached). Blocks for the
// round trip and about half a second of SLH-DSA signing, so never call it on the UI thread.
member_login :: (inv: Invite, k: keys.Keypair, name: string) -> token: string, status: int, message: string {
	tcp, derr := netio.dial_tcp(inv.host, inv.port);
	if derr != .None return "", 0, "Couldn't reach the server.";
	under := netio.tcp_stream(tcp);
	session, _, terr := tls.connect(under, .{alpn = .[ALPN], server_name = hex(inv.id,, temp), pin = inv.pin});
	if !session {
		netio.close(under);
		return "", 0, ifx terr == .Untrusted_Certificate then "The server's certificate doesn't match the invite." else "Couldn't reach the server.";
	}
	defer tls.close(session);
	msg, ok := login_message(session, inv.id);
	if !ok return "", 0, "Couldn't reach the server.";
	sig := crypto.slhdsa_sign(k.signing, LOGIN_CONTEXT, msg,, temp);
	p := keys.proof(k, .Signing);
	proof := NewArray(2, etf.Value,, temp);
	proof[0], proof[1] = etf.vstring(hex(p[0],, temp)), etf.vstring(hex(p[1],, temp));
	b := etf.map_builder(6,, temp);
	etf.map_put(*b, "root", etf.vstring(hex(k.root,, temp)));
	etf.map_put(*b, "signing_pub", etf.vstring(hex(k.signing_pub,, temp)));
	etf.map_put(*b, "proof", etf.vlist(proof));
	etf.map_put(*b, "sig", etf.vstring(base64_encode(cast(string) sig,, temp)));
	etf.map_put(*b, "code", etf.vstring(inv.code));
	etf.map_put(*b, "name", etf.vstring(name));
	sb: String_Builder;
	sb.allocator = temp;
	etf.to_json(etf.vmap(etf.map_done(*b)), *sb);
	body := builder_to_string(*sb,, temp);

	h: http.H1_Conn;
	http.h1_init(*h, tls.stream(session),, temp);
	defer http.h1_destroy(*h, false);
	req := http.Request.{method = "POST", path = "/api/v9/fc/login", authority = hex(inv.id,, temp), body = cast([]u8) body,
		headers = .[.{"content-type", "application/json"}, .{"content-length", tprint("%", body.count)}]};
	resp, err := http.h1_round_trip(*h, req,, temp);
	if err != .None return "", 0, "Couldn't reach the server.";
	v, _ := etf.from_json(cast(string) resp.body,, temp);
	field := ifx resp.status == 200 then "token" else "message";
	f: etf.Value;
	if v.kind == .Map f = etf.map_get(v.map, field);
	text := ifx f.kind == .String then f.s else "";
	if resp.status != 200 || !text return "", resp.status, ifx resp.status != 200 && text then copy_string(text) else "The server refused the login.";
	return copy_string(text), 200, "";
}

id_hex :: (s: *Server, allocator := temp) -> string { return hex(s.id,, allocator); }
pin_hex ::(s: *Server, allocator := temp) -> string { return hex(s.pin,, allocator); }

// listen accepts connections on a thread until stop. Port 0 picks a free port: see s.listener.port.
listen :: (s: *Server, port: int) -> bool {
	l, err := netio.listen_tcp(port);
	if err != .None return false;
	s.listener = l;
	s.accept_thread = spawn(s, accept_loop);
	return true;
}

// stop closes the listener and every connection, waits for their threads, then frees the server.
stop :: (s: *Server) {
	if s.listener {
		netio.close_listener(s.listener);
		locks.join(s.accept_thread);
		free(s.listener);
	}
	// The accept thread has returned, so nothing else touches conns now.
	for s.conns netio.shutdown(netio.tcp_stream(it.tcp)); // Not it.s: its thread may be replacing it.
	for s.conns {
		locks.join(it.thread);
		netio.close(it.s);
		free(it);
	}
	array_free(s.conns);
	close(s);
}

#scope_file

close :: (s: *Server) {
	if s.ctx tls.SSL_CTX_free(s.ctx);
	sqlite.close(s.db);
	free(s.name);
	free(s);
}

hex :: (b: []u8) -> string {
	DIGITS :: "0123456789abcdef";
	out := alloc_string(b.count * 2);
	for b { out[2 * it_index] = DIGITS[it >> 4]; out[2 * it_index + 1] = DIGITS[it & 15]; }
	return out;
}

meta_get :: (s: *Server, k: string) -> []u8 {
	st := sqlite.prepare(s.db, "SELECT v FROM meta WHERE k = ?;");
	defer sqlite.finalize(st);
	sqlite.bind(st, 1, k);
	if sqlite.step(st) != .Row return .[];
	return array_copy(sqlite.col_blob(st, 0),, temp);
}

meta_put :: (s: *Server, k: string, v: []u8) -> bool {
	return sqlite.run(s.db, "INSERT OR REPLACE INTO meta(k, v) VALUES(?, ?);", k, v);
}
meta_put :: (s: *Server, k: string, v: string) -> bool { return meta_put(s, k, cast([]u8) v); }

// Users, channels and messages have Discord-shaped snowflake IDs, since the client reads times from them.
SCHEMA :: #string SQL
CREATE TABLE IF NOT EXISTS meta(k TEXT PRIMARY KEY, v BLOB NOT NULL);
CREATE TABLE IF NOT EXISTS users(id INTEGER PRIMARY KEY, root BLOB UNIQUE NOT NULL, signing_pub BLOB NOT NULL, name TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS sessions(token_hash BLOB PRIMARY KEY, user INTEGER NOT NULL REFERENCES users(id));
CREATE TABLE IF NOT EXISTS channels(id INTEGER PRIMARY KEY, name TEXT NOT NULL, position INTEGER NOT NULL, topic TEXT NOT NULL DEFAULT '');
CREATE TABLE IF NOT EXISTS messages(id INTEGER PRIMARY KEY, channel INTEGER NOT NULL REFERENCES channels(id), author INTEGER NOT NULL REFERENCES users(id), content TEXT NOT NULL, edited INTEGER, reply INTEGER);
CREATE TABLE IF NOT EXISTS read_states(user INTEGER NOT NULL, channel INTEGER NOT NULL, last INTEGER NOT NULL, mentions INTEGER NOT NULL, PRIMARY KEY(user, channel));
CREATE TABLE IF NOT EXISTS reactions(message INTEGER NOT NULL, emoji TEXT NOT NULL, user INTEGER NOT NULL, PRIMARY KEY(message, emoji, user));
CREATE TABLE IF NOT EXISTS invites(code TEXT PRIMARY KEY, uses_left INTEGER NOT NULL, owner INTEGER NOT NULL DEFAULT 0, inviter INTEGER, channel INTEGER,
	max_age INTEGER NOT NULL DEFAULT 0, expires INTEGER NOT NULL DEFAULT 0);
SQL

DISCORD_EPOCH_MS :: 1420070400000;

snowflake :: (s: *Server) -> s64 {
	ms := to_milliseconds(current_time_consensus() - APOLLO_TIME_FOR_JAN_1_1970) - DISCORD_EPOCH_MS;
	return (ms << 22) | (atomic_add(*s.seq, 1) & 0xfff);
}

unhex :: (s: string, out: []u8) -> bool {
	if s.count != out.count * 2 return false;
	nib :: (c: u8) -> int {
		if c >= #char "0" && c <= #char "9" return c - #char "0";
		if c >= #char "a" && c <= #char "f" return c - #char "a" + 10;
		return -1;
	}
	for * out {
		hi, lo := nib(s[2 * it_index]), nib(s[2 * it_index + 1]);
		if hi < 0 || lo < 0 return false;
		it.* = cast(u8) (hi << 4 | lo);
	}
	return true;
}

json_error :: (c: *Conn, status: int, code: int, message: string) -> bool {
	body := tprint("{\"message\": \"%\", \"code\": %}", message, code);
	return http.h1_write_response(c.s, status, JSON_HEADERS, cast([]u8) body) == .None;
}

JSON_HEADERS :: http.Header.[.{"Content-Type", "application/json"}];

// POST /api/v9/fc/login {root, signing_pub, proof: [2 hex], sig (base64), code?, name?}. A known root
// logs in; a new one needs an invite code with uses left, which makes it a member named name.
login :: (c: *Conn, session: *tls.Session, req: http.Request) -> bool {
	s := c.server;
	v, err := etf.from_json(cast(string) req.body,, temp);
	if err != .None || v.kind != .Map return json_error(c, 400, 50035, "Invalid Form Body");
	field :: (name: string) -> string #expand {
		f, _ := etf.map_get(`v.map, name);
		return ifx f.kind == .String then f.s else "";
	}
	root, pub: [32]u8;
	proof: [2][32]u8;
	p, _ := etf.map_get(v.map, "proof");
	ok := unhex(field("root"), root) && unhex(field("signing_pub"), pub) && p.kind == .List && p.list.count == 2
		&& p.list[0].kind == .String && unhex(p.list[0].s, proof[0]) && p.list[1].kind == .String && unhex(p.list[1].s, proof[1]);
	sig, sig_ok := base64_decode(field("sig"),, temp);
	if !ok || !sig_ok return json_error(c, 400, 50035, "Invalid Form Body");
	msg, has_msg := login_message(session, s.id);
	if !has_msg || !keys.verify_proof(root, .Signing, pub, proof) || !crypto.slhdsa_verify(pub, LOGIN_CONTEXT, msg, cast([]u8) sig) {
		return json_error(c, 401, 0, "401: Unauthorized");
	}

	token: [32]u8;
	crypto.random_bytes(token);
	{
		locks.guard(*s.db_mu);
		if !sqlite.exec(s.db, "BEGIN IMMEDIATE;") return json_error(c, 500, 0, "500: Internal Server Error");
		user: s64;
		st := sqlite.prepare(s.db, "SELECT id FROM users WHERE root = ?;");
		sqlite.bind(st, 1, cast([]u8) root);
		if sqlite.step(st) == .Row user = sqlite.col_int(st, 0);
		sqlite.finalize(st);
		status, code, message := 0, 0, "";
		if !user {
			name := trim(field("name"));
			owner := false;
			st = sqlite.prepare(s.db, tprint("SELECT owner FROM invites WHERE code = ? AND %;", INVITE_LIVE));
			sqlite.bind(st, 1, field("code"));
			if sqlite.step(st) == .Row owner = sqlite.col_int(st, 0) != 0;
			sqlite.finalize(st);
			if !sqlite.run(s.db, tprint("UPDATE invites SET uses_left = uses_left - (uses_left > 0) WHERE code = ? AND %;", INVITE_LIVE), field("code")) || sqlite.changes(s.db) != 1 {
				status, code, message = 404, 10006, "Unknown Invite";
			} else if !name || name.count > 32 {
				status, code, message = 400, 50035, "Invalid Form Body";
			} else {
				user = snowflake(s);
				if !sqlite.run(s.db, "INSERT INTO users(id, root, signing_pub, name) VALUES(?, ?, ?, ?);", user, cast([]u8) root, cast([]u8) pub, name) user = 0;
				if user && owner && !meta_put(s, "owner", tprint("%", user)) user = 0;
			}
		}
		token_hash := crypto.blake3(token);
		if user && !sqlite.run(s.db, "INSERT INTO sessions(token_hash, user) VALUES(?, ?);", cast([]u8) token_hash, user) user = 0;
		if !user && !status status, code, message = 500, 0, "500: Internal Server Error";
		sqlite.exec(s.db, ifx status then "ROLLBACK;" else "COMMIT;");
		if status return json_error(c, status, code, message);
	}
	body := tprint("{\"token\": \"%\"}", hex(token,, temp));
	return http.h1_write_response(c.s, 200, JSON_HEADERS, cast([]u8) body) == .None;
}

spawn :: (data: $D, proc: (D)) -> *Thread {
	Spawned :: struct { #as thread: Thread; arg: D; run: (D); }
	t := New(Spawned);
	t.arg, t.run = data, proc;
	thread_init(t, (t: *Thread) -> s64 { s := cast(*Spawned) t; s.run(s.arg); return 0; });
	thread_start(t);
	return t;
}

accept_loop :: (s: *Server) {
	while true {
		tcp, err := netio.accept_tcp(s.listener);
		if err == .Closed break;
		if err != .None continue;
		c := New(Conn);
		c.server, c.tcp, c.s = s, tcp, netio.tcp_stream(tcp);
		locks.lock(*s.mu);
		// Finished connections are reaped here, so a long-running server holds only live ones.
		for s.conns if atomic_load(*it.done) {
			locks.join(it.thread);
			netio.close(it.s);
			free(it);
			remove it;
		}
		array_add(*s.conns, c);
		c.thread = spawn(c, serve_conn);
		locks.unlock(*s.mu);
	}
}

// serve_conn runs one connection's TLS handshake and HTTP/1.1 requests, which end in a gateway upgrade.
// Its stream is closed by whoever reaps it (accept_loop or stop), so a shutdown never races a close.
serve_conn :: (c: *Conn) {
	defer atomic_store(*c.done, true);
	session, _, _ := tls.accept(c.s, c.server.ctx);
	if !session return;
	c.s = tls.stream(session);
	name := tls.server_name(session);
	if name && name != id_hex(c.server) return;

	h: http.H1_Conn;
	http.h1_init(*h, c.s, .{max_header_bytes = 16 << 10, max_headers = 64, max_body = 1 << 20});
	defer http.h1_destroy(*h, false);
	while true {
		reset_temporary_storage();
		req, err := http.h1_read_request(*h);
		defer http.request_destroy(*req);
		if err != .None {
			if err == .Too_Large http.h1_write_response(c.s, 413, .[], .[]);
			else if err == .Protocol http.h1_write_response(c.s, 400, .[], .[]);
			return;
		}
		if http.header_has_token(req.headers, "upgrade", "websocket") {
			gateway(c, req);
			return;
		}
		if req.method == "POST" && req.path == "/api/v9/fc/login" {
			if !login(c, session, req) return;
			continue;
		}
		if begins_with(req.path, "/api/v9/channels/") {
			if !channel_messages(c, req) return;
			continue;
		}
		if req.method == "POST" && req.path == tprint("/api/v9/guilds/%/channels", c.server.guild) {
			if !create_channel(c, req) return;
			continue;
		}
		if !json_error(c, 404, 0, "404: Not Found") return;
	}
}

// session_user is the member a token (as sent in Identify or the authorization header) logs in as, or 0.
session_user :: (s: *Server, token: string) -> id: s64, name: string {
	t: [32]u8;
	if !unhex(token, t) return 0, "";
	h := crypto.blake3(t);
	locks.guard(*s.db_mu);
	st := sqlite.prepare(s.db, "SELECT u.id, u.name FROM sessions s JOIN users u ON u.id = s.user WHERE s.token_hash = ?;");
	defer sqlite.finalize(st);
	sqlite.bind(st, 1, cast([]u8) h);
	if sqlite.step(st) != .Row return 0, "";
	return sqlite.col_int(st, 0), copy_string(sqlite.col_text(st, 0 + 1),, temp);
}

snow :: (id: s64) -> etf.Value { return etf.vstring(tprint("%", id)); }

user_value :: (id: s64, name: string) -> etf.Value {
	m := etf.map_builder(5,, temp);
	etf.map_put(*m, "id", snow(id));
	etf.map_put(*m, "username", etf.vstring(name));
	etf.map_put(*m, "global_name", etf.vstring(name));
	etf.map_put(*m, "discriminator", etf.vstring("0"));
	etf.map_put(*m, "avatar", .{});
	return etf.vmap(etf.map_done(*m));
}

// iso is a snowflake's creation time as Discord writes timestamps.
iso :: (id: s64) -> string {
	t := to_calendar(APOLLO_TIME_FOR_JAN_1_1970 + milliseconds_to_apollo((id >> 22) + DISCORD_EPOCH_MS), .UTC);
	two :: (x: int) -> string { return tprint("%", formatInt(x, minimum_digits = 2)); }
	return tprint("%-%-%T%:%:%.%+00:00", t.year, two(t.month_starting_at_0 + 1), two(t.day_of_month_starting_at_0 + 1),
		two(t.hour), two(t.minute), two(t.second), formatInt(t.millisecond, minimum_digits = 3));
}

// edited is a snowflake minted at the edit, so iso gives its time; 0 if never edited. A reply (type 19)
// carries the message it answers as referenced, or null once that is deleted.
message_value :: (s: *Server, id: s64, channel: s64, author: s64, author_name: string, content: string, edited: s64 = 0,
		reply: s64 = 0, referenced := etf.Value.{}, nonce := "", reactions := etf.Value.{}) -> etf.Value {
	m := etf.map_builder(16,, temp);
	etf.map_put(*m, "id", snow(id));
	etf.map_put(*m, "type", etf.vint(ifx reply then 19 else 0));
	if reply {
		ref := etf.map_builder(3,, temp);
		etf.map_put(*ref, "message_id", snow(reply));
		etf.map_put(*ref, "channel_id", snow(channel));
		etf.map_put(*ref, "guild_id", snow(s.guild));
		etf.map_put(*m, "message_reference", etf.vmap(etf.map_done(*ref)));
		etf.map_put(*m, "referenced_message", referenced);
	}
	etf.map_put(*m, "channel_id", snow(channel));
	etf.map_put(*m, "guild_id", snow(s.guild));
	etf.map_put(*m, "author", user_value(author, author_name));
	etf.map_put(*m, "content", etf.vstring(content));
	etf.map_put(*m, "timestamp", etf.vstring(iso(id)));
	etf.map_put(*m, "edited_timestamp", ifx edited then etf.vstring(iso(edited)) else .{});
	etf.map_put(*m, "flags", etf.vint(0));
	etf.map_put(*m, "attachments", etf.vlist(.[]));
	etf.map_put(*m, "embeds", etf.vlist(.[]));
	etf.map_put(*m, "mentions", etf.vlist(.[]));
	if nonce etf.map_put(*m, "nonce", etf.vstring(nonce));
	if reactions.kind == .List && reactions.list.count etf.map_put(*m, "reactions", reactions);
	return etf.vmap(etf.map_done(*m));
}

MESSAGE_SELECT :: "SELECT m.id, m.channel, m.author, u.name, m.content, coalesce(m.edited, 0), coalesce(m.reply, 0) FROM messages m JOIN users u ON u.id = m.author";

// row_message reads a MESSAGE_SELECT row; the caller holds db_mu. A reply's target is looked up one level
// deep, as Discord sends it.
// With a viewer it also lists reactions, whose `me` is per member, so only fetches carry them; events
// leave them out and the client keeps its own.
row_message :: (s: *Server, st: *sqlite.Stmt, nested := false, viewer: s64 = 0) -> etf.Value {
	id, reply := sqlite.col_int(st, 0), sqlite.col_int(st, 6);
	referenced, reactions: etf.Value;
	if reply && !nested referenced = message_locked(s, reply);
	if viewer {
		list: [..]etf.Value;
		list.allocator = temp;
		r := sqlite.prepare(s.db, "SELECT emoji, count(*), max(user = ?) FROM reactions WHERE message = ? GROUP BY emoji ORDER BY min(rowid);");
		sqlite.bind_all(r, viewer, id);
		while sqlite.step(r) == .Row {
			count := sqlite.col_int(r, 1);
			e := etf.map_builder(2,, temp);
			etf.map_put(*e, "id", .{});
			etf.map_put(*e, "name", etf.vstring(copy_string(sqlite.col_text(r, 0),, temp)));
			details := etf.map_builder(2,, temp);
			etf.map_put(*details, "burst", etf.vint(0));
			etf.map_put(*details, "normal", etf.vint(count));
			m := etf.map_builder(6,, temp);
			etf.map_put(*m, "emoji", etf.vmap(etf.map_done(*e)));
			etf.map_put(*m, "count", etf.vint(count));
			etf.map_put(*m, "count_details", etf.vmap(etf.map_done(*details)));
			etf.map_put(*m, "burst_count", etf.vint(0));
			etf.map_put(*m, "me", etf.vbool(sqlite.col_int(r, 2) != 0));
			etf.map_put(*m, "me_burst", etf.vbool(false));
			array_add(*list, etf.vmap(etf.map_done(*m)));
		}
		sqlite.finalize(r);
		reactions = etf.vlist(list);
	}
	return message_value(s, id, sqlite.col_int(st, 1), sqlite.col_int(st, 2), copy_string(sqlite.col_text(st, 3),, temp),
		copy_string(sqlite.col_text(st, 4),, temp), sqlite.col_int(st, 5), reply, referenced, reactions = reactions);
}

// message_locked is message id as sent to clients, or null if there is none; the caller holds db_mu.
message_locked :: (s: *Server, id: s64, nested := true) -> etf.Value {
	st := sqlite.prepare(s.db, tprint("% WHERE m.id = ?;", MESSAGE_SELECT));
	defer sqlite.finalize(st);
	sqlite.bind(st, 1, id);
	if sqlite.step(st) != .Row return .{};
	return row_message(s, st, nested);
}

// Until roles land (Hosting 4) everyone may read, write, react, embed, attach and make invites.
EVERYONE_PERMISSIONS :: (1 << 0) | (1 << 6) | (1 << 10) | (1 << 11) | (1 << 14) | (1 << 15) | (1 << 16) | (1 << 18) | (1 << 26);

CHANNEL_SELECT :: "SELECT c.id, c.name, c.position, c.topic, (SELECT max(id) FROM messages WHERE channel = c.id) FROM channels c";

row_channel :: (s: *Server, st: *sqlite.Stmt) -> etf.Value {
	m := etf.map_builder(7,, temp);
	etf.map_put(*m, "id", snow(sqlite.col_int(st, 0)));
	etf.map_put(*m, "type", etf.vint(0));
	etf.map_put(*m, "guild_id", snow(s.guild));
	etf.map_put(*m, "name", etf.vstring(copy_string(sqlite.col_text(st, 1),, temp)));
	etf.map_put(*m, "position", etf.vint(sqlite.col_int(st, 2)));
	etf.map_put(*m, "topic", etf.vstring(copy_string(sqlite.col_text(st, 3),, temp)));
	if !sqlite.col_is_null(st, 4) etf.map_put(*m, "last_message_id", snow(sqlite.col_int(st, 4)));
	return etf.vmap(etf.map_done(*m));
}

// channel_locked is channel id as sent to clients, or null; the caller holds db_mu.
channel_locked :: (s: *Server, id: s64) -> etf.Value {
	st := sqlite.prepare(s.db, tprint("% WHERE c.id = ?;", CHANNEL_SELECT));
	defer sqlite.finalize(st);
	sqlite.bind(st, 1, id);
	if sqlite.step(st) != .Row return .{};
	return row_channel(s, st);
}

ready_value :: (s: *Server, user: s64, name: string) -> etf.Value {
	locks.guard(*s.db_mu);
	channels: [..]etf.Value;
	channels.allocator = temp;
	st := sqlite.prepare(s.db, tprint("% ORDER BY c.position, c.id;", CHANNEL_SELECT));
	while sqlite.step(st) == .Row array_add(*channels, row_channel(s, st));
	sqlite.finalize(st);
	members := 0;
	st = sqlite.prepare(s.db, "SELECT count(*) FROM users;");
	if sqlite.step(st) == .Row members = sqlite.col_int(st, 0);
	sqlite.finalize(st);

	everyone := etf.map_builder(4,, temp);
	etf.map_put(*everyone, "id", snow(s.guild));
	etf.map_put(*everyone, "name", etf.vstring("@everyone"));
	etf.map_put(*everyone, "position", etf.vint(0));
	etf.map_put(*everyone, "permissions", etf.vstring(tprint("%", EVERYONE_PERMISSIONS)));
	roles := NewArray(1, etf.Value,, temp);
	roles[0] = etf.vmap(etf.map_done(*everyone));

	g := etf.map_builder(6,, temp);
	etf.map_put(*g, "id", snow(s.guild));
	etf.map_put(*g, "name", etf.vstring(s.name));
	etf.map_put(*g, "member_count", etf.vint(members));
	owner := owner_id(s);
	if owner etf.map_put(*g, "owner_id", snow(owner));
	etf.map_put(*g, "channels", etf.vlist(channels));
	etf.map_put(*g, "roles", etf.vlist(roles));
	guilds := NewArray(1, etf.Value,, temp);
	guilds[0] = etf.vmap(etf.map_done(*g));

	entries: [..]etf.Value;
	entries.allocator = temp;
	st = sqlite.prepare(s.db, "SELECT channel, last, mentions FROM read_states WHERE user = ?;");
	sqlite.bind(st, 1, user);
	while sqlite.step(st) == .Row {
		e := etf.map_builder(3,, temp);
		etf.map_put(*e, "id", snow(sqlite.col_int(st, 0)));
		etf.map_put(*e, "last_message_id", snow(sqlite.col_int(st, 1)));
		etf.map_put(*e, "mention_count", etf.vint(sqlite.col_int(st, 2)));
		array_add(*entries, etf.vmap(etf.map_done(*e)));
	}
	sqlite.finalize(st);
	read_state := etf.map_builder(3,, temp);
	etf.map_put(*read_state, "entries", etf.vlist(entries));
	etf.map_put(*read_state, "partial", etf.vbool(false));
	etf.map_put(*read_state, "version", etf.vint(0));

	d := etf.map_builder(5,, temp);
	etf.map_put(*d, "read_state", etf.vmap(etf.map_done(*read_state)));
	etf.map_put(*d, "v", etf.vint(9));
	etf.map_put(*d, "user", user_value(user, name));
	etf.map_put(*d, "guilds", etf.vlist(guilds));
	etf.map_put(*d, "session_id", etf.vstring(tprint("%", user)));
	return etf.vmap(etf.map_done(*d));
}

// member_list_value is the whole member list as one GUILD_MEMBER_LIST_UPDATE SYNC: Online, then Offline,
// each by name. Online means an identified gateway is open. Takes server.mu, then db_mu.
// @Speed: Past a few hundred members, sync only the ranges a client subscribed to and send INSERT/DELETE.
member_list_value :: (s: *Server) -> etf.Value {
	online: [..]s64;
	online.allocator = temp;
	locks.lock(*s.mu);
	for s.conns if it.ws && it.user array_add_if_unique(*online, it.user);
	locks.unlock(*s.mu);

	Row :: struct { id: s64; name: string; }
	on, off: [..]Row;
	on.allocator, off.allocator = temp, temp;
	{
		locks.guard(*s.db_mu);
		st := sqlite.prepare(s.db, "SELECT id, name FROM users ORDER BY name COLLATE NOCASE, id;");
		while sqlite.step(st) == .Row {
			r := Row.{sqlite.col_int(st, 0), copy_string(sqlite.col_text(st, 1),, temp)};
			array_add(ifx array_find(online, r.id) then *on else *off, r);
		}
		sqlite.finalize(st);
	}
	items: [..]etf.Value;
	groups: [..]etf.Value;
	items.allocator, groups.allocator = temp, temp;
	add_group :: (id: string, rows: []Row) #expand {
		g := etf.map_builder(2,, temp);
		etf.map_put(*g, "id", etf.vstring(id));
		etf.map_put(*g, "count", etf.vint(rows.count));
		gv := etf.vmap(etf.map_done(*g));
		array_add(*`groups, gv);
		if !rows return;
		item := etf.map_builder(1,, temp);
		etf.map_put(*item, "group", gv);
		array_add(*`items, etf.vmap(etf.map_done(*item)));
		for rows {
			p := etf.map_builder(1,, temp);
			etf.map_put(*p, "status", etf.vstring(id));
			m := etf.map_builder(2,, temp);
			etf.map_put(*m, "user", user_value(it.id, it.name));
			etf.map_put(*m, "presence", etf.vmap(etf.map_done(*p)));
			wrap := etf.map_builder(1,, temp);
			etf.map_put(*wrap, "member", etf.vmap(etf.map_done(*m)));
			array_add(*`items, etf.vmap(etf.map_done(*wrap)));
		}
	}
	add_group("online", on);
	add_group("offline", off);

	range := NewArray(2, etf.Value,, temp);
	range[0], range[1] = etf.vint(0), etf.vint(max(items.count - 1, 0));
	op := etf.map_builder(3,, temp);
	etf.map_put(*op, "op", etf.vstring("SYNC"));
	etf.map_put(*op, "range", etf.vlist(range));
	etf.map_put(*op, "items", etf.vlist(items));
	ops := NewArray(1, etf.Value,, temp);
	ops[0] = etf.vmap(etf.map_done(*op));
	d := etf.map_builder(6,, temp);
	etf.map_put(*d, "id", etf.vstring("everyone"));
	etf.map_put(*d, "guild_id", snow(s.guild));
	etf.map_put(*d, "member_count", etf.vint(on.count + off.count));
	etf.map_put(*d, "online_count", etf.vint(on.count));
	etf.map_put(*d, "groups", etf.vlist(groups));
	etf.map_put(*d, "ops", etf.vlist(ops));
	return etf.vmap(etf.map_done(*d));
}

// dispatch sends an op 0 event with the connection's next sequence number.
dispatch :: (c: *Conn, t: string, d: etf.Value) -> bool {
	locks.guard(*c.mu);
	c.seq += 1;
	return send(c.ws, 0, d, c.seq, t);
}

// broadcast dispatches to every identified gateway connection.
// @Speed: A client that stops reading stalls everyone's events until its send times out; queue per connection.
broadcast :: (s: *Server, t: string, d: etf.Value) {
	locks.guard(*s.mu);
	for s.conns if it.ws dispatch(it, t, d);
}

// GET and POST /api/v9/channels/{id}/messages, for members (authorization: <token>).
channel_messages :: (c: *Conn, req: http.Request) -> bool {
	s := c.server;
	token, _ := http.header_get(req.headers, "authorization");
	user, name := session_user(s, token);
	if !user return json_error(c, 401, 0, "401: Unauthorized");
	path, query := req.path, "";
	q := find_index_from_left(path, #char "?");
	if q >= 0 { query = slice(path, q + 1, path.count - q - 1); path = slice(path, 0, q); }
	rest := advance(path, "/api/v9/channels/".count);
	parts := split(rest, "/",, temp);
	channel, ok := string_to_int(parts[0], T = s64);
	typing := parts.count == 2 && parts[1] == "typing";
	if typing && req.method != "POST" return json_error(c, 405, 0, "405: Method Not Allowed");
	if ok && parts.count == 1 return edit_channel(c, req, user, channel);
	if ok && parts.count == 2 && parts[1] == "invites" && req.method == "POST" return create_invite(c, req, user, name, channel);
	if !ok || (!typing && (parts.count < 2 || parts[1] != "messages")) return json_error(c, 404, 0, "404: Not Found");
	if parts.count >= 3 {
		message, mok := string_to_int(parts[2], T = s64);
		if !mok return json_error(c, 404, 0, "404: Not Found");
		if parts.count == 3 return one_message(c, req, user, name, channel, message);
		if parts[3] == "reactions" return reaction(c, req, user, channel, message, array_view(parts, 4));
		if parts[3] == "ack" && parts.count == 4 && req.method == "POST" return ack(c, req, user, channel, message);
		return json_error(c, 404, 0, "404: Not Found");
	}
	{
		locks.guard(*s.db_mu);
		st := sqlite.prepare(s.db, "SELECT 1 FROM channels WHERE id = ?;");
		sqlite.bind(st, 1, channel);
		ok = sqlite.step(st) == .Row;
		sqlite.finalize(st);
	}
	if !ok return json_error(c, 404, 10003, "Unknown Channel");
	if typing {
		member := etf.map_builder(1,, temp);
		etf.map_put(*member, "user", user_value(user, name));
		d := etf.map_builder(5,, temp);
		etf.map_put(*d, "channel_id", snow(channel));
		etf.map_put(*d, "guild_id", snow(s.guild));
		etf.map_put(*d, "user_id", snow(user));
		etf.map_put(*d, "timestamp", etf.vint(to_seconds(current_time_consensus() - APOLLO_TIME_FOR_JAN_1_1970)));
		etf.map_put(*d, "member", etf.vmap(etf.map_done(*member)));
		broadcast(s, "TYPING_START", etf.vmap(etf.map_done(*d)));
		return http.h1_write_response(c.s, 204, .[], .[]) == .None;
	}

	sb: String_Builder;
	sb.allocator = temp;
	if req.method == "GET" {
		limit, before := 50, 0;
		for split(query, "&",, temp) {
			kv := split(it, "=",, temp);
			if kv.count != 2 continue;
			if kv[0] == "limit" limit = clamp(string_to_int(kv[1]), 1, 100);
			if kv[0] == "before" before = string_to_int(kv[1], T = s64);
		}
		list: [..]etf.Value;
		list.allocator = temp;
		{
			locks.guard(*s.db_mu);
			st := sqlite.prepare(s.db, tprint("% WHERE m.channel = ? AND (? = 0 OR m.id < ?) ORDER BY m.id DESC LIMIT ?;", MESSAGE_SELECT));
			sqlite.bind_all(st, channel, before, before, limit);
			while sqlite.step(st) == .Row array_add(*list, row_message(s, st, viewer = user));
			sqlite.finalize(st);
		}
		etf.to_json(etf.vlist(list), *sb);
	} else if req.method == "POST" {
		v, err := etf.from_json(cast(string) req.body,, temp);
		if err != .None || v.kind != .Map return json_error(c, 400, 50035, "Invalid Form Body");
		content, _ := etf.map_get(v.map, "content");
		nonce, _ := etf.map_get(v.map, "nonce");
		if content.kind != .String || !trim(content.s) || content.s.count > 4000 return json_error(c, 400, 50006, "Cannot send an empty message");
		ref, _ := etf.map_get(v.map, "message_reference");
		reply: s64;
		if ref.kind == .Map {
			rid, _ := etf.map_get(ref.map, "message_id");
			if rid.kind == .String reply = string_to_int(rid.s, T = s64);
			else if rid.kind == .Int reply = rid.i;
		}
		id := snowflake(s);
		referenced: etf.Value;
		{
			locks.guard(*s.db_mu);
			if reply {
				referenced = message_locked(s, reply);
				if referenced.kind != .Map || etf.map_get(referenced.map, "channel_id").s != tprint("%", channel) {
					return json_error(c, 400, 50035, "Invalid Form Body");
				}
			}
			if !sqlite.run(s.db, "INSERT INTO messages(id, channel, author, content, reply) VALUES(?, ?, ?, ?, ?);", id, channel, user, content.s, reply) {
				return json_error(c, 500, 0, "500: Internal Server Error");
			}
		}
		m := message_value(s, id, channel, user, name, content.s, 0, reply, referenced, ifx nonce.kind == .String then nonce.s else "");
		etf.to_json(m, *sb);
		broadcast(s, "MESSAGE_CREATE", m);
	} else {
		return json_error(c, 405, 0, "405: Method Not Allowed");
	}
	return http.h1_write_response(c.s, 200, JSON_HEADERS, cast([]u8) builder_to_string(*sb,, temp)) == .None;
}

// PATCH and DELETE /api/v9/channels/{id}/messages/{id}. Until roles land (Hosting 4) only the author may
// edit or delete a message.
one_message :: (c: *Conn, req: http.Request, user: s64, name: string, channel: s64, message: s64) -> bool {
	s := c.server;
	author := 0;
	{
		locks.guard(*s.db_mu);
		st := sqlite.prepare(s.db, "SELECT author FROM messages WHERE id = ? AND channel = ?;");
		sqlite.bind_all(st, message, channel);
		if sqlite.step(st) == .Row author = sqlite.col_int(st, 0);
		sqlite.finalize(st);
	}
	if !author return json_error(c, 404, 10008, "Unknown Message");
	if author != user {
		if req.method == "PATCH" return json_error(c, 403, 50005, "Cannot edit a message authored by another user");
		return json_error(c, 403, 50013, "Missing Permissions");
	}

	if req.method == "PATCH" {
		v, err := etf.from_json(cast(string) req.body,, temp);
		if err != .None || v.kind != .Map return json_error(c, 400, 50035, "Invalid Form Body");
		content, _ := etf.map_get(v.map, "content");
		if content.kind != .String || !trim(content.s) || content.s.count > 4000 return json_error(c, 400, 50006, "Cannot send an empty message");
		m: etf.Value;
		{
			locks.guard(*s.db_mu);
			if !sqlite.run(s.db, "UPDATE messages SET content = ?, edited = ? WHERE id = ?;", content.s, snowflake(s), message) {
				return json_error(c, 500, 0, "500: Internal Server Error");
			}
			m = message_locked(s, message, nested = false);
		}
		sb: String_Builder;
		sb.allocator = temp;
		etf.to_json(m, *sb);
		broadcast(s, "MESSAGE_UPDATE", m);
		return http.h1_write_response(c.s, 200, JSON_HEADERS, cast([]u8) builder_to_string(*sb,, temp)) == .None;
	} else if req.method == "DELETE" {
		{
			locks.guard(*s.db_mu);
			if !sqlite.run(s.db, "DELETE FROM messages WHERE id = ?;", message) return json_error(c, 500, 0, "500: Internal Server Error");
			sqlite.run(s.db, "DELETE FROM reactions WHERE message = ?;", message);
		}
		d := etf.map_builder(3,, temp);
		etf.map_put(*d, "id", snow(message));
		etf.map_put(*d, "channel_id", snow(channel));
		etf.map_put(*d, "guild_id", snow(s.guild));
		broadcast(s, "MESSAGE_DELETE", etf.vmap(etf.map_done(*d)));
		return http.h1_write_response(c.s, 204, .[], .[]) == .None;
	}
	return json_error(c, 405, 0, "405: Method Not Allowed");
}

// Text channel names as Discord makes them: lowercase, with dashes for spaces. "" if none is left.
channel_name :: (raw: string) -> string {
	n := to_lower_copy(trim(raw),, temp);
	for 0..n.count - 1 if n[it] == #char " " n[it] = #char "-";
	return ifx n.count <= 100 then n else "";
}

// POST /api/v9/guilds/{id}/channels {name, type}: the owner adds a text channel at the end.
create_channel :: (c: *Conn, req: http.Request) -> bool {
	s := c.server;
	token, _ := http.header_get(req.headers, "authorization");
	user := session_user(s, token);
	if !user return json_error(c, 401, 0, "401: Unauthorized");
	v, err := etf.from_json(cast(string) req.body,, temp);
	if err != .None || v.kind != .Map return json_error(c, 400, 50035, "Invalid Form Body");
	raw, _ := etf.map_get(v.map, "name");
	kind, _ := etf.map_get(v.map, "type");
	name := ifx raw.kind == .String then channel_name(raw.s) else "";
	if !name || (kind.kind == .Int && kind.i != 0) return json_error(c, 400, 50035, "Invalid Form Body");
	ch: etf.Value;
	{
		locks.guard(*s.db_mu);
		if owner_id(s) != user return json_error(c, 403, 50013, "Missing Permissions");
		id := snowflake(s);
		if !sqlite.run(s.db, "INSERT INTO channels(id, name, position) VALUES(?, ?, (SELECT coalesce(max(position), -1) + 1 FROM channels));", id, name) {
			return json_error(c, 500, 0, "500: Internal Server Error");
		}
		ch = channel_locked(s, id);
	}
	broadcast(s, "CHANNEL_CREATE", ch);
	return json_reply(c, 201, ch);
}

// PATCH /api/v9/channels/{id} {name?, topic?} and DELETE /api/v9/channels/{id}, for the owner. The last
// channel can't be deleted, so the server always has somewhere to talk.
edit_channel :: (c: *Conn, req: http.Request, user: s64, channel: s64) -> bool {
	s := c.server;
	ch: etf.Value;
	if req.method == "PATCH" {
		v, err := etf.from_json(cast(string) req.body,, temp);
		if err != .None || v.kind != .Map return json_error(c, 400, 50035, "Invalid Form Body");
		raw, has_name := etf.map_get(v.map, "name");
		topic, has_topic := etf.map_get(v.map, "topic");
		name := ifx raw.kind == .String then channel_name(raw.s) else "";
		if (has_name && !name) || (has_topic && topic.kind == .String && topic.s.count > 1024) return json_error(c, 400, 50035, "Invalid Form Body");
		locks.guard(*s.db_mu);
		if owner_id(s) != user return json_error(c, 403, 50013, "Missing Permissions");
		if channel_locked(s, channel).kind == .Nil return json_error(c, 404, 10003, "Unknown Channel");
		ok := (!has_name || sqlite.run(s.db, "UPDATE channels SET name = ? WHERE id = ?;", name, channel))
			&& (!has_topic || sqlite.run(s.db, "UPDATE channels SET topic = ? WHERE id = ?;", ifx topic.kind == .String then topic.s else "", channel));
		if !ok return json_error(c, 500, 0, "500: Internal Server Error");
		ch = channel_locked(s, channel);
	} else if req.method == "DELETE" {
		locks.guard(*s.db_mu);
		if owner_id(s) != user return json_error(c, 403, 50013, "Missing Permissions");
		ch = channel_locked(s, channel);
		if ch.kind == .Nil return json_error(c, 404, 10003, "Unknown Channel");
		st := sqlite.prepare(s.db, "SELECT count(*) FROM channels;");
		last := sqlite.step(st) == .Row && sqlite.col_int(st, 0) <= 1;
		sqlite.finalize(st);
		if last return json_error(c, 400, 50035, "Cannot delete the last channel");
		ok := sqlite.exec(s.db, "BEGIN;")
			&& sqlite.run(s.db, "DELETE FROM reactions WHERE message IN (SELECT id FROM messages WHERE channel = ?);", channel)
			&& sqlite.run(s.db, "DELETE FROM messages WHERE channel = ?;", channel)
			&& sqlite.run(s.db, "DELETE FROM read_states WHERE channel = ?;", channel)
			&& sqlite.run(s.db, "DELETE FROM channels WHERE id = ?;", channel)
			&& sqlite.exec(s.db, "COMMIT;");
		if !ok { sqlite.exec(s.db, "ROLLBACK;"); return json_error(c, 500, 0, "500: Internal Server Error"); }
	} else {
		return json_error(c, 405, 0, "405: Method Not Allowed");
	}
	broadcast(s, ifx req.method == "PATCH" then "CHANNEL_UPDATE" else "CHANNEL_DELETE", ch);
	return json_reply(c, 200, ch);
}

// POST /api/v9/channels/{id}/invites {max_uses?, validate?}: any member makes an invite. validate names
// the invite this member got before; while it still works, that one is returned instead of a new one.
// max_age is in seconds, 0 for never, up to the 30 days the modal asks for.
create_invite :: (c: *Conn, req: http.Request, user: s64, name: string, channel: s64) -> bool {
	s := c.server;
	v, err := etf.from_json(cast(string) req.body,, temp);
	if err != .None || v.kind != .Map return json_error(c, 400, 50035, "Invalid Form Body");
	uses, _ := etf.map_get(v.map, "max_uses");
	age, _ := etf.map_get(v.map, "max_age");
	validate, _ := etf.map_get(v.map, "validate");
	max_uses := ifx uses.kind == .Int then uses.i else 0;
	max_age := ifx age.kind == .Int then age.i else 86400;
	if max_uses < 0 || max_uses > 100 || max_age < 0 || max_age > 2592000 return json_error(c, 400, 50035, "Invalid Form Body");
	code := "";
	expires := 0;
	ch: etf.Value;
	{
		locks.guard(*s.db_mu);
		ch = channel_locked(s, channel);
		if ch.kind == .Nil return json_error(c, 404, 10003, "Unknown Channel");
		if validate.kind == .String {
			st := sqlite.prepare(s.db, tprint("SELECT code, max_age, expires FROM invites WHERE code = ? AND inviter = ? AND channel = ? AND %;", INVITE_LIVE));
			sqlite.bind_all(st, validate.s, user, channel);
			if sqlite.step(st) == .Row {
				code = copy_string(sqlite.col_text(st, 0),, temp);
				max_age = sqlite.col_int(st, 1);
				expires = sqlite.col_int(st, 2);
			}
			sqlite.finalize(st);
		}
		if !code {
			bytes: [6]u8;
			crypto.random_bytes(bytes);
			code = hex(bytes,, temp);
			expires = ifx max_age then to_seconds(current_time_consensus() - APOLLO_TIME_FOR_JAN_1_1970) + max_age else 0;
			if !sqlite.run(s.db, "INSERT INTO invites(code, uses_left, inviter, channel, max_age, expires) VALUES(?, ?, ?, ?, ?, ?);",
					code, ifx max_uses then max_uses else -1, user, channel, max_age, expires) {
				return json_error(c, 500, 0, "500: Internal Server Error");
			}
		}
	}
	g := etf.map_builder(2,, temp);
	etf.map_put(*g, "id", snow(s.guild));
	etf.map_put(*g, "name", etf.vstring(s.name));
	m := etf.map_builder(9,, temp);
	etf.map_put(*m, "code", etf.vstring(code));
	etf.map_put(*m, "type", etf.vint(0));
	etf.map_put(*m, "guild_id", snow(s.guild));
	etf.map_put(*m, "guild", etf.vmap(etf.map_done(*g)));
	etf.map_put(*m, "channel", ch);
	etf.map_put(*m, "inviter", user_value(user, name));
	etf.map_put(*m, "max_age", etf.vint(max_age));
	etf.map_put(*m, "expires_at", ifx expires then etf.vstring(iso(((expires * 1000) - DISCORD_EPOCH_MS) << 22)) else .{});
	etf.map_put(*m, "max_uses", etf.vint(max_uses));
	etf.map_put(*m, "temporary", etf.vbool(false));
	return json_reply(c, 200, etf.vmap(etf.map_done(*m)));
}

// POST .../messages/{id}/ack {manual?, mention_count?}: the member has read up to message, or with manual,
// marked it unread from there. Their other sessions follow through MESSAGE_ACK.
ack :: (c: *Conn, req: http.Request, user: s64, channel: s64, message: s64) -> bool {
	s := c.server;
	v, err := etf.from_json(cast(string) req.body,, temp);
	manual, mentions: etf.Value;
	if err == .None && v.kind == .Map {
		manual, _ = etf.map_get(v.map, "manual");
		mentions, _ = etf.map_get(v.map, "mention_count");
	}
	is_manual := manual.kind == .Bool && manual.b;
	count := ifx is_manual && mentions.kind == .Int then clamp(mentions.i, 0, 1000) else 0;
	{
		locks.guard(*s.db_mu);
		if channel_locked(s, channel).kind == .Nil return json_error(c, 404, 10003, "Unknown Channel");
		if !sqlite.run(s.db, "INSERT OR REPLACE INTO read_states(user, channel, last, mentions) VALUES(?, ?, ?, ?);", user, channel, message, count) {
			return json_error(c, 500, 0, "500: Internal Server Error");
		}
	}
	d := etf.map_builder(5,, temp);
	etf.map_put(*d, "channel_id", snow(channel));
	etf.map_put(*d, "message_id", snow(message));
	etf.map_put(*d, "mention_count", etf.vint(count));
	etf.map_put(*d, "manual", etf.vbool(is_manual));
	etf.map_put(*d, "version", etf.vint(0));
	ev := etf.vmap(etf.map_done(*d));
	{
		locks.guard(*s.mu);
		for s.conns if it.ws && it.user == user dispatch(it, "MESSAGE_ACK", ev);
	}
	return http.h1_write_response(c.s, 200, JSON_HEADERS, cast([]u8) "{\"token\": null}") == .None;
}

json_reply :: (c: *Conn, status: int, v: etf.Value) -> bool {
	sb: String_Builder;
	sb.allocator = temp;
	etf.to_json(v, *sb);
	return http.h1_write_response(c.s, status, JSON_HEADERS, cast([]u8) builder_to_string(*sb,, temp)) == .None;
}

// PUT .../reactions/{emoji}/@me and DELETE .../reactions/{emoji}/{type}/@me. Unicode emoji only, since a
// hosted server has no custom ones yet; members may remove only their own reactions.
reaction :: (c: *Conn, req: http.Request, user: s64, channel: s64, message: s64, rest: []string) -> bool {
	s := c.server;
	me := rest.count && (rest[rest.count - 1] == "@me" || rest[rest.count - 1] == "%40me");
	add := req.method == "PUT" && rest.count == 2 && me;
	drop := req.method == "DELETE" && (rest.count == 2 || rest.count == 3) && me;
	if !add && !drop {
		if req.method == "DELETE" && rest.count == 3 return json_error(c, 403, 50013, "Missing Permissions");
		return json_error(c, 404, 0, "404: Not Found");
	}
	emoji := percent_decode(rest[0]);
	if !emoji || emoji.count > 64 || contains(emoji, ":") return json_error(c, 400, 10014, "Unknown Emoji");
	changed := false;
	{
		locks.guard(*s.db_mu);
		st := sqlite.prepare(s.db, "SELECT 1 FROM messages WHERE id = ? AND channel = ?;");
		sqlite.bind_all(st, message, channel);
		found := sqlite.step(st) == .Row;
		sqlite.finalize(st);
		if !found return json_error(c, 404, 10008, "Unknown Message");
		sql := ifx add then "INSERT OR IGNORE INTO reactions(message, emoji, user) VALUES(?, ?, ?);" else "DELETE FROM reactions WHERE message = ? AND emoji = ? AND user = ?;";
		if !sqlite.run(s.db, sql, message, emoji, user) return json_error(c, 500, 0, "500: Internal Server Error");
		changed = sqlite.changes(s.db) > 0;
	}
	if changed {
		e := etf.map_builder(2,, temp);
		etf.map_put(*e, "id", .{});
		etf.map_put(*e, "name", etf.vstring(emoji));
		d := etf.map_builder(7,, temp);
		etf.map_put(*d, "user_id", snow(user));
		etf.map_put(*d, "channel_id", snow(channel));
		etf.map_put(*d, "message_id", snow(message));
		etf.map_put(*d, "guild_id", snow(s.guild));
		etf.map_put(*d, "emoji", etf.vmap(etf.map_done(*e)));
		etf.map_put(*d, "burst", etf.vbool(false));
		etf.map_put(*d, "type", etf.vint(0));
		broadcast(s, ifx add then "MESSAGE_REACTION_ADD" else "MESSAGE_REACTION_REMOVE", etf.vmap(etf.map_done(*d)));
	}
	return http.h1_write_response(c.s, 204, .[], .[]) == .None;
}

percent_decode :: (s: string) -> string {
	out := alloc_string(s.count,, temp);
	n, i := 0, 0;
	while i < s.count {
		if s[i] == #char "%" && i + 2 < s.count {
			v, ok := string_to_int(slice(s, i + 1, 2), 16);
			if ok { out[n] = cast(u8) v; n += 1; i += 3; continue; }
		}
		out[n] = s[i];
		n += 1;
		i += 1;
	}
	out.count = n;
	return out;
}

gateway :: (c: *Conn, req: http.Request) {
	key, has_key := http.header_get(req.headers, "sec-websocket-key");
	// The plain profile sends no compress parameter; a client asking for zstd would fail to read us.
	if !has_key || !begins_with(req.path, "/?") || !contains(req.path, "encoding=etf") || contains(req.path, "compress=") {
		http.h1_write_response(c.s, 400, .[], .[]);
		return;
	}
	accept := http.ws_accept_for_key(key,, temp);
	headers := http.Header.[.{"Upgrade", "websocket"}, .{"Connection", "Upgrade"}, .{"Sec-WebSocket-Accept", accept}];
	if http.h1_write_response(c.s, 101, headers, .[], "Switching Protocols") != .None return;
	netio.set_timeout(c.s, HEARTBEAT_INTERVAL_MS * 2);

	ws := http.ws_attach(c.s, .{server = true, max_message = 1 << 20});
	defer {
		locks.lock(*c.server.mu);
		was := c.user;
		c.ws = null;
		c.user = 0;
		locks.unlock(*c.server.mu);
		http.ws_destroy(ws);
		if was broadcast(c.server, "GUILD_MEMBER_LIST_UPDATE", member_list_value(c.server));
	}

	hello := etf.map_builder(,, temp);
	etf.map_put(*hello, "heartbeat_interval", etf.vint(HEARTBEAT_INTERVAL_MS));
	if !send(ws, 10, etf.vmap(etf.map_done(*hello))) return;

	msg: [..]u8;
	defer array_free(msg);
	while true {
		reset_temporary_storage();
		msg.count = 0;
		type, err := http.ws_recv(ws, *msg);
		if err != .None || type != .Binary return;
		v, derr := etf.decode(msg,, temp);
		if derr != .None || v.kind != .Map { http.ws_close(ws, 4002, "Error while decoding payload."); return; }
		op, _ := etf.map_get(v.map, "op");
		d, _ := etf.map_get(v.map, "d");
		if op.kind != .Int { http.ws_close(ws, 4002, "Error while decoding payload."); return; }
		if op.i == {
			case 1; #through;
			case 40; // The official client heartbeats with op 40 (with QoS data).
				if !send(ws, 11, .{}) return;
			case 2;
				if c.ws { http.ws_close(ws, 4005, "Already authenticated."); return; }
				token: etf.Value;
				if d.kind == .Map token, _ = etf.map_get(d.map, "token");
				user, name := session_user(c.server, ifx token.kind == .String then token.s else "");
				if !user { http.ws_close(ws, 4004, "Authentication failed."); return; }
				// Registered before READY is built and sent under c.mu, so a message posted meanwhile
				// arrives after READY instead of being lost. Lock order: server.mu, then c.mu.
				locks.lock(*c.server.mu);
				c.ws = ws;
				c.user = user;
				locks.lock(*c.mu);
				locks.unlock(*c.server.mu);
				c.seq += 1;
				ok := send(ws, 0, ready_value(c.server, user, name), c.seq, "READY");
				locks.unlock(*c.mu);
				if !ok return;
				broadcast(c.server, "GUILD_MEMBER_LIST_UPDATE", member_list_value(c.server));
			case 37; // Guild subscriptions: there is one guild and one list, so any subscription gets all of it.
				if c.ws && !dispatch(c, "GUILD_MEMBER_LIST_UPDATE", member_list_value(c.server)) return;
			case 6; // No resume: an invalid session makes the client identify again.
				if !send(ws, 9, etf.vbool(false)) return;
			case; // Voice states and the rest are Discord-only; ignore them.
		}
	}
}

send :: (ws: *http.Ws_Conn, op: int, d: etf.Value, seq := 0, t := "") -> bool {
	m := etf.map_builder(4,, temp);
	etf.map_put(*m, "op", etf.vint(op));
	etf.map_put(*m, "d", d);
	etf.map_put(*m, "s", ifx seq then etf.vint(seq) else .{});
	etf.map_put(*m, "t", ifx t then etf.vatom(t) else .{});
	bytes, err := etf.encode(etf.vmap(etf.map_done(*m)),, temp);
	return err == .None && http.ws_send(ws, .Binary, bytes) == .None;
}
