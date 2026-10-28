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
	mu: locks.Mutex;   // Orders this gateway's dispatches: seq and their queueing.
	seq: int;
	// Under mu: encoded dispatches the writer thread hasn't sent yet, so one member who stops reading
	// can't stall everyone else's events.
	out: [..][]u8;
	out_bytes: int;
	wake: locks.Cond;
	closing: bool;
	out_ws: *http.Ws_Conn; // The writer's socket, fixed for its life (unlike ws).
	writer: *Thread;
	reply_status: int; // The reply respond kept, 0 when none.
	reply_body: string;
	reply_json: bool;
}

OUT_MAX :: 8 << 20;

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
	sqlite.exec(db, "ALTER TABLE users ADD COLUMN left INTEGER NOT NULL DEFAULT 0;");
	sqlite.exec(db, "ALTER TABLE messages ADD COLUMN reply INTEGER;");
	sqlite.exec(db, "ALTER TABLE messages ADD COLUMN everyone INTEGER NOT NULL DEFAULT 0;");
	sqlite.exec(db, "ALTER TABLE messages ADD COLUMN pinned_at INTEGER;");
	sqlite.exec(db, "ALTER TABLE messages ADD COLUMN type INTEGER NOT NULL DEFAULT 0;");
	sqlite.exec(db, "ALTER TABLE channels ADD COLUMN topic TEXT NOT NULL DEFAULT '';");
	sqlite.exec(db, "ALTER TABLE channels ADD COLUMN type INTEGER NOT NULL DEFAULT 0;");
	sqlite.exec(db, "ALTER TABLE channels ADD COLUMN parent INTEGER;");
	sqlite.exec(db, "ALTER TABLE invites ADD COLUMN owner INTEGER NOT NULL DEFAULT 0;");
	sqlite.exec(db, "ALTER TABLE invites ADD COLUMN inviter INTEGER;");
	sqlite.exec(db, "ALTER TABLE invites ADD COLUMN channel INTEGER;");
	sqlite.exec(db, "ALTER TABLE invites ADD COLUMN max_age INTEGER NOT NULL DEFAULT 0;");
	sqlite.exec(db, "ALTER TABLE invites ADD COLUMN expires INTEGER NOT NULL DEFAULT 0;");
	st := sqlite.prepare(db, "SELECT 1 FROM sqlite_master WHERE name = 'message_text';");
	indexed := sqlite.step(st) == .Row;
	sqlite.finalize(st);
	if !sqlite.exec(db, SEARCH_SCHEMA) || (!indexed && !sqlite.exec(db, "INSERT INTO message_text(message_text) VALUES('rebuild');")) {
		close(s);
		return null, false;
	}

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
CREATE TABLE IF NOT EXISTS users(id INTEGER PRIMARY KEY, root BLOB UNIQUE NOT NULL, signing_pub BLOB NOT NULL, name TEXT NOT NULL, left INTEGER NOT NULL DEFAULT 0);
CREATE TABLE IF NOT EXISTS sessions(token_hash BLOB PRIMARY KEY, user INTEGER NOT NULL REFERENCES users(id));
CREATE TABLE IF NOT EXISTS channels(id INTEGER PRIMARY KEY, name TEXT NOT NULL, position INTEGER NOT NULL, topic TEXT NOT NULL DEFAULT '', type INTEGER NOT NULL DEFAULT 0, parent INTEGER);
CREATE TABLE IF NOT EXISTS messages(id INTEGER PRIMARY KEY, channel INTEGER NOT NULL REFERENCES channels(id), author INTEGER NOT NULL REFERENCES users(id), content TEXT NOT NULL, edited INTEGER, reply INTEGER, everyone INTEGER NOT NULL DEFAULT 0, pinned_at INTEGER, type INTEGER NOT NULL DEFAULT 0);
CREATE TABLE IF NOT EXISTS read_states(user INTEGER NOT NULL, channel INTEGER NOT NULL, last INTEGER NOT NULL, mentions INTEGER NOT NULL, PRIMARY KEY(user, channel));
CREATE TABLE IF NOT EXISTS guild_settings(user INTEGER PRIMARY KEY, settings TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS mentions(message INTEGER NOT NULL, user INTEGER NOT NULL, PRIMARY KEY(message, user));
CREATE TABLE IF NOT EXISTS reactions(message INTEGER NOT NULL, emoji TEXT NOT NULL, user INTEGER NOT NULL, PRIMARY KEY(message, emoji, user));
CREATE TABLE IF NOT EXISTS invites(code TEXT PRIMARY KEY, uses_left INTEGER NOT NULL, owner INTEGER NOT NULL DEFAULT 0, inviter INTEGER, channel INTEGER,
	max_age INTEGER NOT NULL DEFAULT 0, expires INTEGER NOT NULL DEFAULT 0);
SQL

// Search's full-text index over message content, kept in step by triggers (the external-content
// pattern from the FTS5 docs). Pin and other column updates don't touch it.
SEARCH_SCHEMA :: #string SQL
CREATE VIRTUAL TABLE IF NOT EXISTS message_text USING fts5(content, content='messages', content_rowid='id');
CREATE TRIGGER IF NOT EXISTS message_text_insert AFTER INSERT ON messages BEGIN
	INSERT INTO message_text(rowid, content) VALUES(new.id, new.content);
END;
CREATE TRIGGER IF NOT EXISTS message_text_delete AFTER DELETE ON messages BEGIN
	INSERT INTO message_text(message_text, rowid, content) VALUES('delete', old.id, old.content);
END;
CREATE TRIGGER IF NOT EXISTS message_text_update AFTER UPDATE OF content ON messages BEGIN
	INSERT INTO message_text(message_text, rowid, content) VALUES('delete', old.id, old.content);
	INSERT INTO message_text(rowid, content) VALUES(new.id, new.content);
END;
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
	return respond(c, status, tprint("{\"message\": \"%\", \"code\": %}", message, code));
}

// respond keeps a handler's reply for serve_conn to write once the handler returns. Handlers often answer
// while holding db_mu, and a client that doesn't read its replies would otherwise stall every member on
// that lock until the write times out. body lives in temp, which lasts until the next request.
respond :: (c: *Conn, status: int, body := "", json := true) -> bool {
	c.reply_status, c.reply_body, c.reply_json = status, body, json;
	return true;
}

flush_reply :: (c: *Conn) -> bool {
	status := c.reply_status;
	if !status return true;
	c.reply_status = 0;
	if c.reply_json return http.h1_write_response(c.s, status, JSON_HEADERS, cast([]u8) c.reply_body) == .None;
	return http.h1_write_response(c.s, status, .[], cast([]u8) c.reply_body) == .None;
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
	hello: etf.Value;
	{
		locks.guard(*s.db_mu);
		if !sqlite.exec(s.db, "BEGIN IMMEDIATE;") return json_error(c, 500, 0, "500: Internal Server Error");
		user: s64;
		gone, joined := false, false;
		st := sqlite.prepare(s.db, "SELECT id, left FROM users WHERE root = ?;");
		sqlite.bind(st, 1, cast([]u8) root);
		if sqlite.step(st) == .Row user, gone = sqlite.col_int(st, 0), sqlite.col_int(st, 1) != 0;
		sqlite.finalize(st);
		status, code, message := 0, 0, "";
		if !user || gone {
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
			} else if gone {
				if !sqlite.run(s.db, "UPDATE users SET left = 0 WHERE id = ?;", user) user = 0;
			} else {
				user = snowflake(s);
				joined = true;
				if !sqlite.run(s.db, "INSERT INTO users(id, root, signing_pub, name) VALUES(?, ?, ?, ?);", user, cast([]u8) root, cast([]u8) pub, name) user = 0;
				if user && owner && !meta_put(s, "owner", tprint("%", user)) user = 0;
			}
		}
		if user && (joined || gone) {
			welcome := snowflake(s);
			ok := sqlite.run(s.db, tprint("INSERT INTO messages(id, channel, author, content, type) SELECT ?, id, ?, '', % FROM channels WHERE type = % ORDER BY position, id LIMIT 1;", JOINED, TEXT), welcome, user);
			if !ok user = 0;
			else if sqlite.changes(s.db) hello = message_locked(s, welcome, nested = false);
		}
		token_hash := crypto.blake3(token);
		if user && !sqlite.run(s.db, "INSERT INTO sessions(token_hash, user) VALUES(?, ?);", cast([]u8) token_hash, user) user = 0;
		if !user && !status status, code, message = 500, 0, "500: Internal Server Error";
		sqlite.exec(s.db, ifx status then "ROLLBACK;" else "COMMIT;");
		if status return json_error(c, status, code, message);
	}
	if hello.kind == .Map broadcast(s, "MESSAGE_CREATE", hello);
	body := tprint("{\"token\": \"%\"}", hex(token,, temp));
	return respond(c, 200, body);
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
	// Finished connections are reaped here, so a long-running server holds only live ones.
	reap :: (s: *Server) {
		for s.conns if atomic_load(*it.done) {
			locks.join(it.thread);
			netio.close(it.s);
			free(it);
			remove it;
		}
	}
	backoff := 0;
	while true {
		tcp, err := netio.accept_tcp(s.listener);
		if err == .Closed break;
		if err != .None {
			// Out of file descriptors, most likely: free the finished ones and wait, rather than spin.
			locks.lock(*s.mu);
			reap(s);
			locks.unlock(*s.mu);
			backoff = clamp(backoff * 2, 10, 1000);
			sleep_milliseconds(xx backoff);
			continue;
		}
		backoff = 0;
		c := New(Conn);
		c.server, c.tcp, c.s = s, tcp, netio.tcp_stream(tcp);
		locks.lock(*s.mu);
		reap(s);
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
		if !flush_reply(c) return; // The last request's, now that its handler has let go of every lock.
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
		if req.method == "GET" && begins_with(req.path, tprint("/api/v9/guilds/%/messages/search", c.server.guild)) {
			if !search(c, req) return;
			continue;
		}
		if req.method == "POST" && req.path == tprint("/api/v9/guilds/%/channels", c.server.guild) {
			if !create_channel(c, req) return;
			continue;
		}
		if req.method == "PATCH" && req.path == "/api/v9/users/@me/guilds/settings" {
			if !patch_guild_settings(c, req) return;
			continue;
		}
		if req.method == "POST" && req.path == "/api/v9/read-states/ack-bulk" {
			if !ack_bulk(c, req) return;
			continue;
		}
		if req.method == "PATCH" && req.path == tprint("/api/v9/guilds/%/members/@me", c.server.guild) {
			if !rename(c, req) return;
			continue;
		}
		if req.method == "DELETE" && req.path == tprint("/api/v9/users/@me/guilds/%", c.server.guild) {
			if !leave(c, req) return;
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
		reply: s64 = 0, referenced := etf.Value.{}, nonce := "", reactions := etf.Value.{}, mentions := etf.Value.{}, everyone := false, pinned := false,
		kind := DEFAULT) -> etf.Value {
	m := etf.map_builder(16,, temp);
	etf.map_put(*m, "id", snow(id));
	etf.map_put(*m, "type", etf.vint(ifx kind != DEFAULT then kind else ifx reply then 19 else 0));
	if reply {
		ref := etf.map_builder(3,, temp);
		etf.map_put(*ref, "message_id", snow(reply));
		etf.map_put(*ref, "channel_id", snow(channel));
		etf.map_put(*ref, "guild_id", snow(s.guild));
		etf.map_put(*m, "message_reference", etf.vmap(etf.map_done(*ref)));
		if kind == DEFAULT etf.map_put(*m, "referenced_message", referenced);
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
	etf.map_put(*m, "mentions", ifx mentions.kind == .List then mentions else etf.vlist(.[]));
	etf.map_put(*m, "mention_everyone", etf.vbool(everyone));
	etf.map_put(*m, "pinned", etf.vbool(pinned));
	if nonce etf.map_put(*m, "nonce", etf.vstring(nonce));
	if reactions.kind == .List && reactions.list.count etf.map_put(*m, "reactions", reactions);
	return etf.vmap(etf.map_done(*m));
}

MESSAGE_SELECT :: "SELECT m.id, m.channel, m.author, u.name, m.content, coalesce(m.edited, 0), coalesce(m.reply, 0), m.everyone, m.pinned_at, m.type FROM messages m JOIN users u ON u.id = m.author";

// Message types: a "pinned a message" notice is a system message whose reply column holds the pinned one.
DEFAULT :: 0;
PINNED :: 6;
JOINED :: 7;

// row_message reads a MESSAGE_SELECT row; the caller holds db_mu. A reply's target is looked up one level
// deep, as Discord sends it.
// With a viewer it also lists reactions, whose `me` is per member, so only fetches carry them; events
// leave them out and the client keeps its own.
row_message :: (s: *Server, st: *sqlite.Stmt, nested := false, viewer: s64 = 0, nonce := "") -> etf.Value {
	id := sqlite.col_int(st, 0);
	reply := sqlite.col_int(st, 6);
	kind := sqlite.col_int(st, 9);
	referenced, reactions: etf.Value;
	if reply && !nested && kind == DEFAULT referenced = message_locked(s, reply);
	mentioned: [..]etf.Value;
	mentioned.allocator = temp;
	q := sqlite.prepare(s.db, "SELECT u.id, u.name FROM mentions x JOIN users u ON u.id = x.user WHERE x.message = ?;");
	sqlite.bind(q, 1, id);
	while sqlite.step(q) == .Row array_add(*mentioned, user_value(sqlite.col_int(q, 0), copy_string(sqlite.col_text(q, 1),, temp)));
	sqlite.finalize(q);
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
		copy_string(sqlite.col_text(st, 4),, temp), sqlite.col_int(st, 5), reply, referenced, nonce, reactions, etf.vlist(mentioned), sqlite.col_int(st, 7) != 0, !sqlite.col_is_null(st, 8), kind);
}

// message_locked is message id as sent to clients, or null if there is none; the caller holds db_mu.
message_locked :: (s: *Server, id: s64, nested := true, nonce := "") -> etf.Value {
	st := sqlite.prepare(s.db, tprint("% WHERE m.id = ?;", MESSAGE_SELECT));
	defer sqlite.finalize(st);
	sqlite.bind(st, 1, id);
	if sqlite.step(st) != .Row return .{};
	return row_message(s, st, nested, nonce = nonce);
}

// mention_ids are the user IDs in <@id> and <@!id> tags, unchecked.
mention_ids :: (content: string) -> [..]s64 {
	out: [..]s64;
	out.allocator = temp;
	rest := content;
	while true {
		i := find_index_from_left(rest, "<@");
		if i < 0 break;
		rest = advance(rest, i + 2);
		if rest && rest[0] == #char "!" rest = advance(rest, 1);
		n := 0;
		while n < rest.count && rest[n] >= #char "0" && rest[n] <= #char "9" n += 1;
		if n && n < rest.count && rest[n] == #char ">" {
			id, ok := string_to_int(slice(rest, 0, n), T = s64);
			if ok array_add_if_unique(*out, id);
		}
	}
	return out;
}

// Until roles land (Hosting 4) everyone may read, write, react, embed, attach and make invites.
EVERYONE_PERMISSIONS :: (1 << 0) | (1 << 6) | (1 << 10) | (1 << 11) | (1 << 14) | (1 << 15) | (1 << 16) | (1 << 18) | (1 << 26);

// Channel types, as Discord numbers them.
TEXT :: 0;
CATEGORY :: 4;

CHANNEL_SELECT :: "SELECT c.id, c.name, c.position, c.topic, (SELECT max(id) FROM messages WHERE channel = c.id), c.type, c.parent FROM channels c";

row_channel :: (s: *Server, st: *sqlite.Stmt) -> etf.Value {
	m := etf.map_builder(8,, temp);
	etf.map_put(*m, "id", snow(sqlite.col_int(st, 0)));
	etf.map_put(*m, "type", etf.vint(sqlite.col_int(st, 5)));
	etf.map_put(*m, "guild_id", snow(s.guild));
	etf.map_put(*m, "name", etf.vstring(copy_string(sqlite.col_text(st, 1),, temp)));
	etf.map_put(*m, "position", etf.vint(sqlite.col_int(st, 2)));
	if sqlite.col_int(st, 5) == TEXT etf.map_put(*m, "topic", etf.vstring(copy_string(sqlite.col_text(st, 3),, temp)));
	if !sqlite.col_is_null(st, 4) etf.map_put(*m, "last_message_id", snow(sqlite.col_int(st, 4)));
	etf.map_put(*m, "parent_id", ifx sqlite.col_is_null(st, 6) then etf.Value.{} else snow(sqlite.col_int(st, 6)));
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

// A channel's type, or -1 if there is no such channel. The caller holds db_mu.
channel_type_locked :: (s: *Server, id: s64) -> int {
	st := sqlite.prepare(s.db, "SELECT type FROM channels WHERE id = ?;");
	defer sqlite.finalize(st);
	sqlite.bind(st, 1, id);
	if sqlite.step(st) != .Row return -1;
	return sqlite.col_int(st, 0);
}

ready_value :: (s: *Server, user: s64, name: string) -> etf.Value {
	locks.guard(*s.db_mu);
	channels: [..]etf.Value;
	channels.allocator = temp;
	st := sqlite.prepare(s.db, tprint("% ORDER BY c.position, c.id;", CHANNEL_SELECT));
	while sqlite.step(st) == .Row array_add(*channels, row_channel(s, st));
	sqlite.finalize(st);
	members := 0;
	st = sqlite.prepare(s.db, "SELECT count(*) FROM users WHERE left = 0;");
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

	settings: [..]etf.Value;
	settings.allocator = temp;
	mine := guild_settings_locked(s, user);
	if mine.kind == .Map array_add(*settings, mine);
	guild_settings := etf.map_builder(3,, temp);
	etf.map_put(*guild_settings, "entries", etf.vlist(settings));
	etf.map_put(*guild_settings, "partial", etf.vbool(false));
	etf.map_put(*guild_settings, "version", etf.vint(0));

	d := etf.map_builder(6,, temp);
	etf.map_put(*d, "read_state", etf.vmap(etf.map_done(*read_state)));
	etf.map_put(*d, "user_guild_settings", etf.vmap(etf.map_done(*guild_settings)));
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
		st := sqlite.prepare(s.db, "SELECT id, name FROM users WHERE left = 0 ORDER BY name COLLATE NOCASE, id;");
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
	return queue(c, frame(0, d, c.seq, t));
}

// queue hands bytes to c's writer; c.mu is held. A member whose backlog passes OUT_MAX has stopped
// reading, so it is disconnected instead of queued for without bound; its client reconnects.
queue :: (c: *Conn, bytes: []u8) -> bool {
	if c.closing || !bytes return false;
	if c.out_bytes + bytes.count > OUT_MAX {
		c.closing = true;
		netio.shutdown(netio.tcp_stream(c.tcp));
		locks.cond_signal(*c.wake);
		return false;
	}
	array_add(*c.out, array_copy(bytes,, context.default_allocator));
	c.out_bytes += bytes.count;
	locks.cond_signal(*c.wake);
	return true;
}

writer :: (c: *Conn) {
	batch: [..][]u8;
	defer array_free(batch);
	while true {
		locks.lock(*c.mu);
		while !c.out.count && !c.closing locks.cond_wait(*c.wake, *c.mu);
		stop := c.closing;
		spare := batch;
		batch = c.out;
		c.out = spare;
		c.out_bytes = 0;
		locks.unlock(*c.mu);
		for batch {
			if !stop && http.ws_send(c.out_ws, .Binary, it) != .None {
				stop = true;
				locks.lock(*c.mu);
				c.closing = true;
				locks.unlock(*c.mu);
				netio.shutdown(netio.tcp_stream(c.tcp));
			}
			free(it.data,, context.default_allocator);
		}
		batch.count = 0;
		if stop return;
	}
}

// broadcast dispatches to every identified gateway connection.
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
	// Opening the pins popout acks them; unread pins aren't tracked, so there is nothing to store.
	if ok && parts.count == 3 && parts[1] == "pins" && parts[2] == "ack" return respond(c, 204, json = false);
	if !ok || (!typing && (parts.count < 2 || parts[1] != "messages")) return json_error(c, 404, 0, "404: Not Found");
	if parts.count >= 3 && parts[2] == "pins" {
		if parts.count == 3 && req.method == "GET" return list_pins(c, channel);
		message: s64;
		mok := false;
		if parts.count == 4 message, mok = string_to_int(parts[3], T = s64);
		if !mok || (req.method != "PUT" && req.method != "DELETE") return json_error(c, 404, 0, "404: Not Found");
		return pin(c, user, channel, message, req.method == "PUT");
	}
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
		st := sqlite.prepare(s.db, tprint("SELECT 1 FROM channels WHERE id = ? AND type = %;", TEXT));
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
		return respond(c, 204, json = false);
	}

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
			// Pages are newest first whichever way they extend; around takes the message itself and older ones
			// for the larger half, newer ones for the rest.
			st: *sqlite.Stmt;
			if around {
				st = sqlite.prepare(s.db, tprint("SELECT * FROM (% WHERE m.channel = ? AND m.id > ? ORDER BY m.id LIMIT ?) UNION ALL SELECT * FROM (% WHERE m.channel = ? AND m.id <= ? ORDER BY m.id DESC LIMIT ?) ORDER BY 1 DESC;", MESSAGE_SELECT, MESSAGE_SELECT));
				sqlite.bind_all(st, channel, around, limit / 2, channel, around, limit - limit / 2);
			} else if after {
				st = sqlite.prepare(s.db, tprint("SELECT * FROM (% WHERE m.channel = ? AND m.id > ? ORDER BY m.id LIMIT ?) ORDER BY 1 DESC;", MESSAGE_SELECT));
				sqlite.bind_all(st, channel, after, limit);
			} else {
				st = sqlite.prepare(s.db, tprint("% WHERE m.channel = ? AND (? = 0 OR m.id < ?) ORDER BY m.id DESC LIMIT ?;", MESSAGE_SELECT));
				sqlite.bind_all(st, channel, before, before, limit);
			}
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
		if nonce.kind == .String && nonce.s.count > 25 return json_error(c, 400, 50035, "Invalid Form Body");
		ref, _ := etf.map_get(v.map, "message_reference");
		reply: s64;
		if ref.kind == .Map {
			rid, _ := etf.map_get(ref.map, "message_id");
			if rid.kind == .String reply = string_to_int(rid.s, T = s64);
			else if rid.kind == .Int reply = rid.i;
		}
		id := snowflake(s);
		referenced, m: etf.Value;
		{
			locks.guard(*s.db_mu);
			if reply {
				referenced = message_locked(s, reply);
				if referenced.kind != .Map || etf.map_get(referenced.map, "channel_id").s != tprint("%", channel) {
					return json_error(c, 400, 50035, "Invalid Form Body");
				}
			}
			// Until roles land (Hosting 4) only the owner may ping @everyone or @here.
			everyone := (contains(content.s, "@everyone") || contains(content.s, "@here")) && owner_id(s) == user;
			ids := mention_ids(content.s);
			// A reply pings the replied-to author unless the sender turned that off.
			am, _ := etf.map_get(v.map, "allowed_mentions");
			replied: etf.Value;
			if am.kind == .Map replied, _ = etf.map_get(am.map, "replied_user");
			if reply && !(replied.kind == .Bool && !replied.b) {
				author, _ := etf.map_get(etf.map_get(referenced.map, "author").map, "id");
				array_add_if_unique(*ids, string_to_int(author.s, T = s64));
			}
			ok := sqlite.exec(s.db, "BEGIN;")
				&& sqlite.run(s.db, "INSERT INTO messages(id, channel, author, content, reply, everyone) VALUES(?, ?, ?, ?, ?, ?);", id, channel, user, content.s, reply, cast(int) everyone);
			for ids if ok ok = sqlite.run(s.db, "INSERT OR IGNORE INTO mentions(message, user) SELECT ?, id FROM users WHERE id = ? AND left = 0;", id, it);
			// Members who can't see the message yet count it as a mention until they read past it.
			ok = ok && sqlite.run(s.db, #string SQL
				INSERT INTO read_states(user, channel, last, mentions)
				SELECT u.id, ?, 0, 1 FROM users u WHERE u.left = 0 AND u.id != ? AND (? OR u.id IN (SELECT user FROM mentions WHERE message = ?))
				ON CONFLICT(user, channel) DO UPDATE SET mentions = mentions + 1;
			SQL, channel, user, cast(int) everyone, id) && sqlite.exec(s.db, "COMMIT;");
			if !ok {
				sqlite.exec(s.db, "ROLLBACK;");
				return json_error(c, 500, 0, "500: Internal Server Error");
			}
			m = message_locked(s, id, nested = false, nonce = ifx nonce.kind == .String then nonce.s else "");
		}
		etf.to_json(m, *sb);
		broadcast(s, "MESSAGE_CREATE", m);
	} else {
		return json_error(c, 405, 0, "405: Method Not Allowed");
	}
	return respond(c, 200, builder_to_string(*sb,, temp));
}

// PATCH and DELETE /api/v9/channels/{id}/messages/{id}. Until roles land (Hosting 4) only the author may
// edit a message, and only the author or the owner delete it.
one_message :: (c: *Conn, req: http.Request, user: s64, name: string, channel: s64, message: s64) -> bool {
	s := c.server;
	author, owner, kind := 0, 0, DEFAULT;
	{
		locks.guard(*s.db_mu);
		st := sqlite.prepare(s.db, "SELECT author, type FROM messages WHERE id = ? AND channel = ?;");
		sqlite.bind_all(st, message, channel);
		if sqlite.step(st) == .Row author, kind = sqlite.col_int(st, 0), sqlite.col_int(st, 1);
		sqlite.finalize(st);
		owner = owner_id(s);
	}
	if !author return json_error(c, 404, 10008, "Unknown Message");
	if req.method == "PATCH" && kind != DEFAULT return json_error(c, 400, 50021, "Cannot execute action on a system message");
	if author != user {
		if req.method == "PATCH" return json_error(c, 403, 50005, "Cannot edit a message authored by another user");
		if user != owner return json_error(c, 403, 50013, "Missing Permissions");
	}

	if req.method == "PATCH" {
		v, err := etf.from_json(cast(string) req.body,, temp);
		if err != .None || v.kind != .Map return json_error(c, 400, 50035, "Invalid Form Body");
		content, _ := etf.map_get(v.map, "content");
		if content.kind != .String || !trim(content.s) || content.s.count > 4000 return json_error(c, 400, 50006, "Cannot send an empty message");
		m: etf.Value;
		{
			locks.guard(*s.db_mu);
			// Mentions follow the new text, as on Discord, but an edit pings nobody: read-state counts stay.
			// A reply's ping of its original author is kept.
			everyone := (contains(content.s, "@everyone") || contains(content.s, "@here")) && owner_id(s) == user;
			ok := sqlite.exec(s.db, "BEGIN;")
				&& sqlite.run(s.db, "UPDATE messages SET content = ?, edited = ?, everyone = ? WHERE id = ?;", content.s, snowflake(s), cast(int) everyone, message)
				&& sqlite.run(s.db, "DELETE FROM mentions WHERE message = ? AND user IS NOT (SELECT r.author FROM messages m JOIN messages r ON r.id = m.reply WHERE m.id = ?);", message, message);
			for mention_ids(content.s) if ok ok = sqlite.run(s.db, "INSERT OR IGNORE INTO mentions(message, user) SELECT ?, id FROM users WHERE id = ? AND left = 0;", message, it);
			if !ok || !sqlite.exec(s.db, "COMMIT;") {
				sqlite.exec(s.db, "ROLLBACK;");
				return json_error(c, 500, 0, "500: Internal Server Error");
			}
			m = message_locked(s, message, nested = false);
		}
		sb: String_Builder;
		sb.allocator = temp;
		etf.to_json(m, *sb);
		broadcast(s, "MESSAGE_UPDATE", m);
		return respond(c, 200, builder_to_string(*sb,, temp));
	} else if req.method == "DELETE" {
		{
			locks.guard(*s.db_mu);
			if !sqlite.run(s.db, "DELETE FROM messages WHERE id = ?;", message) return json_error(c, 500, 0, "500: Internal Server Error");
			sqlite.run(s.db, "DELETE FROM reactions WHERE message = ?;", message);
			sqlite.run(s.db, "DELETE FROM mentions WHERE message = ?;", message);
		}
		d := etf.map_builder(3,, temp);
		etf.map_put(*d, "id", snow(message));
		etf.map_put(*d, "channel_id", snow(channel));
		etf.map_put(*d, "guild_id", snow(s.guild));
		broadcast(s, "MESSAGE_DELETE", etf.vmap(etf.map_done(*d)));
		return respond(c, 204, json = false);
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
	kind_v, _ := etf.map_get(v.map, "type");
	parent_v, _ := etf.map_get(v.map, "parent_id");
	kind := ifx kind_v.kind == .Int then kind_v.i else TEXT;
	parent: s64;
	has_parent := false;
	if parent_v.kind == .String parent, has_parent = string_to_int(parent_v.s, T = s64);
	// Categories keep the name as typed; text channels get Discord's lowercase-dashed form.
	name := ifx raw.kind != .String then "" else ifx kind == CATEGORY then trim(raw.s) else channel_name(raw.s);
	if !name || name.count > 100 || (kind != TEXT && kind != CATEGORY) || (has_parent && kind != TEXT) return json_error(c, 400, 50035, "Invalid Form Body");
	ch: etf.Value;
	{
		locks.guard(*s.db_mu);
		if owner_id(s) != user return json_error(c, 403, 50013, "Missing Permissions");
		if has_parent {
			st := sqlite.prepare(s.db, tprint("SELECT 1 FROM channels WHERE id = ? AND type = %;", CATEGORY));
			sqlite.bind(st, 1, parent);
			found := sqlite.step(st) == .Row;
			sqlite.finalize(st);
			if !found return json_error(c, 400, 50035, "Invalid Form Body");
		}
		id := snowflake(s);
		ok := ifx has_parent
			then sqlite.run(s.db, "INSERT INTO channels(id, name, position, type, parent) VALUES(?, ?, (SELECT coalesce(max(position), -1) + 1 FROM channels), ?, ?);", id, name, kind, parent)
			else sqlite.run(s.db, "INSERT INTO channels(id, name, position, type) VALUES(?, ?, (SELECT coalesce(max(position), -1) + 1 FROM channels), ?);", id, name, kind);
		if !ok return json_error(c, 500, 0, "500: Internal Server Error");
		ch = channel_locked(s, id);
	}
	broadcast(s, "CHANNEL_CREATE", ch);
	return json_reply(c, 201, ch);
}

// PATCH /api/v9/guilds/{id}/members/@me {nick}: Change Nickname. A member has one name here, so the nick
// replaces it, and members see it as their name with no nick; an empty nick has nothing to fall back to.
rename :: (c: *Conn, req: http.Request) -> bool {
	s := c.server;
	token, _ := http.header_get(req.headers, "authorization");
	user := session_user(s, token);
	if !user return json_error(c, 401, 0, "401: Unauthorized");
	v, err := etf.from_json(cast(string) req.body,, temp);
	nick: etf.Value;
	if err == .None && v.kind == .Map nick, _ = etf.map_get(v.map, "nick");
	name := ifx nick.kind == .String then trim(nick.s) else "";
	if !name || name.count > 32 return json_error(c, 400, 50035, "Invalid Form Body");
	{
		locks.guard(*s.db_mu);
		if !sqlite.run(s.db, "UPDATE users SET name = ? WHERE id = ?;", name, user) return json_error(c, 500, 0, "500: Internal Server Error");
	}
	m := etf.map_builder(4,, temp);
	etf.map_put(*m, "guild_id", snow(s.guild));
	etf.map_put(*m, "user", user_value(user, name));
	etf.map_put(*m, "nick", .{});
	no_roles: []etf.Value;
	etf.map_put(*m, "roles", etf.vlist(no_roles));
	member := etf.vmap(etf.map_done(*m));
	broadcast(s, "GUILD_MEMBER_UPDATE", member);
	broadcast(s, "GUILD_MEMBER_LIST_UPDATE", member_list_value(s));
	return json_reply(c, 200, member);
}

// DELETE /api/v9/users/@me/guilds/{id}: a member leaves. They stay in users so their messages keep an
// author, but lose their sessions and gateways, and need an invite to come back. The owner can't leave.
leave :: (c: *Conn, req: http.Request) -> bool {
	s := c.server;
	token, _ := http.header_get(req.headers, "authorization");
	user := session_user(s, token);
	if !user return json_error(c, 401, 0, "401: Unauthorized");
	{
		locks.guard(*s.db_mu);
		if owner_id(s) == user return json_error(c, 400, 50055, "Invalid Guild");
		ok := sqlite.exec(s.db, "BEGIN;")
			&& sqlite.run(s.db, "UPDATE users SET left = 1 WHERE id = ?;", user)
			&& sqlite.run(s.db, "DELETE FROM sessions WHERE user = ?;", user)
			&& sqlite.exec(s.db, "COMMIT;");
		if !ok {
			sqlite.exec(s.db, "ROLLBACK;");
			return json_error(c, 500, 0, "500: Internal Server Error");
		}
	}
	g := etf.map_builder(1,, temp);
	etf.map_put(*g, "id", snow(s.guild));
	gone := etf.vmap(etf.map_done(*g));
	{
		// Unregistered, their gateways get no more events, and their next Identify fails without a session.
		locks.guard(*s.mu);
		for s.conns if it.ws && it.user == user {
			dispatch(it, "GUILD_DELETE", gone);
			it.ws = null;
			it.user = 0;
		}
	}
	broadcast(s, "GUILD_MEMBER_LIST_UPDATE", member_list_value(s));
	return respond(c, 204, json = false);
}

// PATCH /api/v9/channels/{id} {name?, topic?} and DELETE /api/v9/channels/{id}, for the owner. The last
// channel can't be deleted, so the server always has somewhere to talk.
edit_channel :: (c: *Conn, req: http.Request, user: s64, channel: s64) -> bool {
	s := c.server;
	ch: etf.Value;
	orphans: [..]etf.Value;
	orphans.allocator = temp;
	if req.method == "PATCH" {
		v, err := etf.from_json(cast(string) req.body,, temp);
		if err != .None || v.kind != .Map return json_error(c, 400, 50035, "Invalid Form Body");
		raw, has_name := etf.map_get(v.map, "name");
		topic, has_topic := etf.map_get(v.map, "topic");
		locks.guard(*s.db_mu);
		if owner_id(s) != user return json_error(c, 403, 50013, "Missing Permissions");
		kind := channel_type_locked(s, channel);
		if kind < 0 return json_error(c, 404, 10003, "Unknown Channel");
		name := ifx raw.kind != .String then "" else ifx kind == CATEGORY then trim(raw.s) else channel_name(raw.s);
		if (has_name && (!name || name.count > 100)) || (has_topic && topic.kind == .String && topic.s.count > 1024) return json_error(c, 400, 50035, "Invalid Form Body");
		ok := (!has_name || sqlite.run(s.db, "UPDATE channels SET name = ? WHERE id = ?;", name, channel))
			&& (!has_topic || sqlite.run(s.db, "UPDATE channels SET topic = ? WHERE id = ?;", ifx topic.kind == .String then topic.s else "", channel));
		if !ok return json_error(c, 500, 0, "500: Internal Server Error");
		ch = channel_locked(s, channel);
	} else if req.method == "DELETE" {
		locks.guard(*s.db_mu);
		if owner_id(s) != user return json_error(c, 403, 50013, "Missing Permissions");
		ch = channel_locked(s, channel);
		if ch.kind == .Nil return json_error(c, 404, 10003, "Unknown Channel");
		kind := channel_type_locked(s, channel);
		st := sqlite.prepare(s.db, tprint("SELECT count(*) FROM channels WHERE type = %;", TEXT));
		last := kind == TEXT && sqlite.step(st) == .Row && sqlite.col_int(st, 0) <= 1;
		sqlite.finalize(st);
		if last return json_error(c, 400, 50035, "Cannot delete the last channel");
		// A deleted category's channels stay, uncategorized, as on Discord.
		st = sqlite.prepare(s.db, "SELECT id FROM channels WHERE parent = ?;");
		sqlite.bind(st, 1, channel);
		ids: [..]s64;
		ids.allocator = temp;
		while sqlite.step(st) == .Row array_add(*ids, sqlite.col_int(st, 0));
		sqlite.finalize(st);
		ok := sqlite.exec(s.db, "BEGIN;")
			&& sqlite.run(s.db, "UPDATE channels SET parent = NULL WHERE parent = ?;", channel)
			&& sqlite.run(s.db, "DELETE FROM reactions WHERE message IN (SELECT id FROM messages WHERE channel = ?);", channel)
			&& sqlite.run(s.db, "DELETE FROM mentions WHERE message IN (SELECT id FROM messages WHERE channel = ?);", channel)
			&& sqlite.run(s.db, "DELETE FROM messages WHERE channel = ?;", channel)
			&& sqlite.run(s.db, "DELETE FROM read_states WHERE channel = ?;", channel)
			&& sqlite.run(s.db, "DELETE FROM channels WHERE id = ?;", channel)
			&& sqlite.exec(s.db, "COMMIT;");
		if !ok { sqlite.exec(s.db, "ROLLBACK;"); return json_error(c, 500, 0, "500: Internal Server Error"); }
		for ids array_add(*orphans, channel_locked(s, it));
	} else {
		return json_error(c, 405, 0, "405: Method Not Allowed");
	}
	broadcast(s, ifx req.method == "PATCH" then "CHANNEL_UPDATE" else "CHANNEL_DELETE", ch);
	for orphans broadcast(s, "CHANNEL_UPDATE", it);
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
	status := store_ack(s, user, channel, message, count, is_manual);
	if status == 404 return json_error(c, 404, 10003, "Unknown Channel");
	if status return json_error(c, 500, 0, "500: Internal Server Error");
	return respond(c, 200, "{\"token\": null}");
}

// POST /api/v9/read-states/ack-bulk {read_states: [{channel_id, message_id}]}: Mark As Read for many
// channels at once. Unknown channels are skipped.
ack_bulk :: (c: *Conn, req: http.Request) -> bool {
	s := c.server;
	token, _ := http.header_get(req.headers, "authorization");
	user := session_user(s, token);
	if !user return json_error(c, 401, 0, "401: Unauthorized");
	v, err := etf.from_json(cast(string) req.body,, temp);
	list: etf.Value;
	if err == .None && v.kind == .Map list, _ = etf.map_get(v.map, "read_states");
	if list.kind != .List || list.list.count > 1000 return json_error(c, 400, 50035, "Invalid Form Body");
	for list.list {
		if it.kind != .Map continue;
		ch, _ := etf.map_get(it.map, "channel_id");
		m, _ := etf.map_get(it.map, "message_id");
		if ch.kind != .String || m.kind != .String continue;
		channel, cok := string_to_int(ch.s, T = s64);
		message, mok := string_to_int(m.s, T = s64);
		if cok && mok && store_ack(s, user, channel, message, 0, false) == 500 return json_error(c, 500, 0, "500: Internal Server Error");
	}
	return respond(c, 204, json = false);
}

// PATCH /api/v9/users/@me/guilds/settings {guilds: {"<id>": {...}}}: mute and notification settings,
// kept per member as the whole user_guild_settings entry. Fields the patch names replace the stored ones;
// channel_overrides comes keyed by channel ID and is merged into the entry's list per channel.
patch_guild_settings :: (c: *Conn, req: http.Request) -> bool {
	s := c.server;
	token, _ := http.header_get(req.headers, "authorization");
	user := session_user(s, token);
	if !user return json_error(c, 401, 0, "401: Unauthorized");
	v, err := etf.from_json(cast(string) req.body,, temp);
	guilds, patch: etf.Value;
	if err == .None && v.kind == .Map guilds, _ = etf.map_get(v.map, "guilds");
	if guilds.kind == .Map patch, _ = etf.map_get(guilds.map, tprint("%", s.guild));
	if guilds.kind != .Map || (patch.kind != .Map && patch.kind != .Nil) return json_error(c, 400, 50035, "Invalid Form Body");

	entry: etf.Value;
	{
		locks.guard(*s.db_mu);
		old := guild_settings_locked(s, user);
		if patch.kind == .Map {
			old_map := ifx old.kind == .Map then old.map else .[];
			e := merge(old_map, patch.map, "guild_id", "channel_overrides");
			etf.map_put(*e, "guild_id", snow(s.guild));
			overrides: [..]etf.Value;
			overrides.allocator = temp;
			was, _ := etf.map_get(old_map, "channel_overrides");
			changes, _ := etf.map_get(patch.map, "channel_overrides");
			if was.kind == .List for was.list {
				if it.kind != .Map continue;
				id, _ := etf.map_get(it.map, "channel_id");
				change: etf.Value;
				if id.kind == .String && changes.kind == .Map change, _ = etf.map_get(changes.map, id.s);
				if change.kind != .Map { array_add(*overrides, it); continue; }
				o := merge(it.map, change.map, "channel_id", "");
				etf.map_put(*o, "channel_id", id);
				array_add(*overrides, etf.vmap(etf.map_done(*o)));
			}
			if changes.kind == .Map for changes.map {
				if it.key.kind != .String || it.value.kind != .Map || !string_to_int(it.key.s, T = s64) continue;
				known := false;
				if was.kind == .List for o: was.list if o.kind == .Map {
					id, _ := etf.map_get(o.map, "channel_id");
					if id.kind == .String && id.s == it.key.s known = true;
				}
				if known continue;
				o := merge(.[], it.value.map, "channel_id", "");
				etf.map_put(*o, "channel_id", it.key);
				array_add(*overrides, etf.vmap(etf.map_done(*o)));
			}
			etf.map_put(*e, "channel_overrides", etf.vlist(overrides));
			entry = etf.vmap(etf.map_done(*e));
			sb: String_Builder;
			sb.allocator = temp;
			etf.to_json(entry, *sb);
			if !sqlite.run(s.db, "INSERT OR REPLACE INTO guild_settings(user, settings) VALUES(?, ?);", user, builder_to_string(*sb,, temp)) {
				return json_error(c, 500, 0, "500: Internal Server Error");
			}
		} else {
			entry = old;
		}
	}
	list: [..]etf.Value;
	list.allocator = temp;
	if entry.kind == .Map {
		array_add(*list, entry);
		locks.guard(*s.mu);
		for s.conns if it.ws && it.user == user dispatch(it, "USER_GUILD_SETTINGS_UPDATE", entry);
	}
	return json_reply(c, 200, etf.vlist(list));
}

// merge is old's pairs with patch's on top, leaving out keys skip_a and skip_b of both, as a builder
// the caller can add to.
merge :: (old: etf.Map, patch: etf.Map, skip_a: string, skip_b: string) -> etf.Map_Builder {
	b := etf.map_builder(old.count + patch.count + 2,, temp);
	for old {
		if it.key.kind != .String || it.key.s == skip_a || it.key.s == skip_b continue;
		_, replaced := etf.map_get(patch, it.key.s);
		if !replaced array_add(*b.pairs, it);
	}
	for patch {
		if it.key.kind != .String || it.key.s == skip_a || it.key.s == skip_b continue;
		array_add(*b.pairs, it);
	}
	return b;
}

// A member's user_guild_settings entry, or Nil if they never changed one. The caller holds db_mu.
guild_settings_locked :: (s: *Server, user: s64) -> etf.Value {
	st := sqlite.prepare(s.db, "SELECT settings FROM guild_settings WHERE user = ?;");
	defer sqlite.finalize(st);
	sqlite.bind(st, 1, user);
	if sqlite.step(st) != .Row return .{};
	v, err := etf.from_json(copy_string(sqlite.col_text(st, 0),, temp),, temp);
	return ifx err == .None then v else .{};
}

// store_ack saves a member's read state for a channel and tells their other gateways. 0, or 404 for no
// such channel, or 500.
store_ack :: (s: *Server, user: s64, channel: s64, message: s64, count: int, is_manual: bool) -> int {
	{
		locks.guard(*s.db_mu);
		if channel_locked(s, channel).kind == .Nil return 404;
		if !sqlite.run(s.db, "INSERT OR REPLACE INTO read_states(user, channel, last, mentions) VALUES(?, ?, ?, ?);", user, channel, message, count) return 500;
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
	return 0;
}

SEARCH_PAGE :: 25;

// GET /api/v9/guilds/{id}/messages/search?content=&author_id=&mentions=&channel_id=&has=&pinned=&offset=,
// newest first, 25 a page, as {total_results, messages: [[message], ...]}. Repeated keys of one kind
// match any of them; different kinds must all match. Content matches whole words, all of them.
search :: (c: *Conn, req: http.Request) -> bool {
	s := c.server;
	token, _ := http.header_get(req.headers, "authorization");
	viewer := session_user(s, token);
	if !viewer return json_error(c, 401, 0, "401: Unauthorized");
	q := find_index_from_left(req.path, #char "?");
	if req.path.count > tprint("/api/v9/guilds/%/messages/search", s.guild).count && q < 0 return json_error(c, 404, 0, "404: Not Found");

	Param :: struct { text: bool; i: s64; s: string; }
	params: [..]Param;
	params.allocator = temp;
	authors, mentioned, channels: [..]s64;
	authors.allocator, mentioned.allocator, channels.allocator = temp, temp, temp;
	where: String_Builder;
	where.allocator = temp;
	print_to_builder(*where, " WHERE m.type = %", DEFAULT);
	offset := 0;
	for split(ifx q >= 0 then slice(req.path, q + 1, req.path.count - q - 1) else "", "&",, temp) {
		kv := split(it, "=",, temp);
		if kv.count != 2 continue;
		value := percent_decode(replace(kv[1], "+", " ",, temp));
		n, n_ok := string_to_int(value, T = s64);
		if kv[0] == {
			case "author_id";  if n_ok array_add(*authors, n);
			case "mentions";   if n_ok array_add(*mentioned, n);
			case "channel_id"; if n_ok array_add(*channels, n);
			case "offset";     if n_ok offset = clamp(n, 0, 5000);
			case "pinned";     if value == "true" append(*where, " AND m.pinned_at IS NOT NULL");
			case "has";
				// Hosted messages carry no attachments, embeds or stickers yet; only links can be had.
				if value == "link" append(*where, " AND (m.content LIKE '%http://%' OR m.content LIKE '%https://%')");
				else append(*where, " AND 0");
			case "content";
				// Each word quoted, so FTS5 query syntax in what was typed is matched literally.
				terms: String_Builder;
				terms.allocator = temp;
				for w: split(value, " ",, temp) if w print_to_builder(*terms, "\"%\" ", replace(w, "\"", "\"\"",, temp));
				match := builder_to_string(*terms,, temp);
				if match {
					append(*where, " AND m.id IN (SELECT rowid FROM message_text WHERE message_text MATCH ?)");
					array_add(*params, .{text = true, s = match});
				}
		}
	}
	any_of :: (open: string, ids: []s64, close := ")") #expand {
		if !ids return;
		append(*`where, open);
		for ids {
			append(*`where, ifx it_index then ", ?" else "?");
			array_add(*`params, .{i = it});
		}
		append(*`where, close);
	}
	any_of(" AND m.author IN (", authors);
	any_of(" AND m.channel IN (", channels);
	any_of(" AND EXISTS (SELECT 1 FROM mentions x WHERE x.message = m.id AND x.user IN (", mentioned, "))");
	filter := builder_to_string(*where,, temp);

	bind_params :: (st: *sqlite.Stmt) #expand {
		for `params if it.text sqlite.bind(st, it_index + 1, it.s); else sqlite.bind(st, it_index + 1, it.i);
	}
	total := 0;
	found: [..]etf.Value;
	found.allocator = temp;
	{
		locks.guard(*s.db_mu);
		st := sqlite.prepare(s.db, tprint("SELECT count(*) FROM messages m%;", filter));
		bind_params(st);
		if sqlite.step(st) == .Row total = sqlite.col_int(st, 0);
		sqlite.finalize(st);
		st = sqlite.prepare(s.db, tprint("% % ORDER BY m.id DESC LIMIT % OFFSET %;", MESSAGE_SELECT, filter, SEARCH_PAGE, offset));
		bind_params(st);
		while sqlite.step(st) == .Row {
			one := NewArray(1, etf.Value,, temp);
			one[0] = row_message(s, st, viewer = viewer);
			array_add(*found, etf.vlist(one));
		}
		sqlite.finalize(st);
	}
	d := etf.map_builder(2,, temp);
	etf.map_put(*d, "total_results", etf.vint(total));
	etf.map_put(*d, "messages", etf.vlist(found));
	return json_reply(c, 200, etf.vmap(etf.map_done(*d)));
}

MAX_PINS :: 50; // Per channel, as Discord had it; so the pins list never needs paging.

// PUT/DELETE /api/v9/channels/{id}/messages/pins/{id}: until roles land (Hosting 4) only the owner pins.
// The message (now pinned or not) follows as MESSAGE_UPDATE, then CHANNEL_PINS_UPDATE.
pin :: (c: *Conn, user: s64, channel: s64, message: s64, on: bool) -> bool {
	s := c.server;
	m, notice: etf.Value;
	last := "";
	{
		locks.guard(*s.db_mu);
		if owner_id(s) != user return json_error(c, 403, 50013, "Missing Permissions");
		st := sqlite.prepare(s.db, "SELECT (SELECT count(*) FROM messages WHERE channel = ?1 AND pinned_at IS NOT NULL) FROM messages WHERE id = ?2 AND channel = ?1;");
		sqlite.bind_all(st, channel, message);
		found := sqlite.step(st) == .Row;
		pins := ifx found then sqlite.col_int(st, 0) else 0;
		sqlite.finalize(st);
		if !found return json_error(c, 404, 10008, "Unknown Message");
		if on && pins >= MAX_PINS return json_error(c, 400, 30003, "Maximum number of pins reached (50)");
		ok := ifx on then sqlite.run(s.db, "UPDATE messages SET pinned_at = ? WHERE id = ? AND pinned_at IS NULL;", snowflake(s), message)
			else sqlite.run(s.db, "UPDATE messages SET pinned_at = NULL WHERE id = ?;", message);
		if !ok return json_error(c, 500, 0, "500: Internal Server Error");
		if !sqlite.changes(s.db) return respond(c, 204, json = false);
		m = message_locked(s, message, nested = false);
		if on {
			notice_id := snowflake(s);
			if sqlite.run(s.db, "INSERT INTO messages(id, channel, author, content, reply, type) VALUES(?, ?, ?, '', ?, ?);", notice_id, channel, user, message, PINNED) {
				notice = message_locked(s, notice_id, nested = false);
			}
		}
		st = sqlite.prepare(s.db, "SELECT max(pinned_at) FROM messages WHERE channel = ?;");
		sqlite.bind(st, 1, channel);
		if sqlite.step(st) == .Row && !sqlite.col_is_null(st, 0) last = iso(sqlite.col_int(st, 0));
		sqlite.finalize(st);
	}
	broadcast(s, "MESSAGE_UPDATE", m);
	if notice.kind == .Map broadcast(s, "MESSAGE_CREATE", notice);
	d := etf.map_builder(3,, temp);
	etf.map_put(*d, "channel_id", snow(channel));
	etf.map_put(*d, "guild_id", snow(s.guild));
	etf.map_put(*d, "last_pin_timestamp", ifx last then etf.vstring(last) else .{});
	broadcast(s, "CHANNEL_PINS_UPDATE", etf.vmap(etf.map_done(*d)));
	return respond(c, 204, json = false);
}

// GET /api/v9/channels/{id}/messages/pins: newest pin first, all of them (MAX_PINS).
list_pins :: (c: *Conn, channel: s64) -> bool {
	s := c.server;
	items: [..]etf.Value;
	items.allocator = temp;
	{
		locks.guard(*s.db_mu);
		st := sqlite.prepare(s.db, tprint("% WHERE m.channel = ? AND m.pinned_at IS NOT NULL ORDER BY m.pinned_at DESC;", MESSAGE_SELECT));
		sqlite.bind(st, 1, channel);
		while sqlite.step(st) == .Row {
			item := etf.map_builder(2,, temp);
			etf.map_put(*item, "pinned_at", etf.vstring(iso(sqlite.col_int(st, 8))));
			etf.map_put(*item, "message", row_message(s, st));
			array_add(*items, etf.vmap(etf.map_done(*item)));
		}
		sqlite.finalize(st);
	}
	d := etf.map_builder(2,, temp);
	etf.map_put(*d, "items", etf.vlist(items));
	etf.map_put(*d, "has_more", etf.vbool(false));
	return json_reply(c, 200, etf.vmap(etf.map_done(*d)));
}

json_reply :: (c: *Conn, status: int, v: etf.Value) -> bool {
	sb: String_Builder;
	sb.allocator = temp;
	etf.to_json(v, *sb);
	return respond(c, status, builder_to_string(*sb,, temp));
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
	return respond(c, 204, json = false);
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
	c.out_ws = ws;
	c.writer = spawn(c, writer);
	defer {
		locks.lock(*c.server.mu);
		was := c.user;
		c.ws = null;
		c.user = 0;
		locks.unlock(*c.server.mu);
		locks.lock(*c.mu);
		c.closing = true;
		locks.cond_signal(*c.wake);
		locks.unlock(*c.mu);
		locks.join(c.writer);
		for c.out free(it.data,, context.default_allocator);
		array_free(c.out);
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
				ok := queue(c, frame(0, ready_value(c.server, user, name), c.seq, "READY"));
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

// frame encodes a gateway payload in temp; empty if it can't be encoded.
frame :: (op: int, d: etf.Value, seq := 0, t := "") -> []u8 {
	m := etf.map_builder(4,, temp);
	etf.map_put(*m, "op", etf.vint(op));
	etf.map_put(*m, "d", d);
	etf.map_put(*m, "s", ifx seq then etf.vint(seq) else .{});
	etf.map_put(*m, "t", ifx t then etf.vatom(t) else .{});
	bytes, err := etf.encode(etf.vmap(etf.map_done(*m)),, temp);
	if err != .None return .[];
	return bytes;
}

// send writes straight from the reader thread, for replies that carry no seq (Hello, heartbeat acks).
// Ws_Conn serializes its writes, so this can't interleave with the writer's frames.
send :: (ws: *http.Ws_Conn, op: int, d: etf.Value) -> bool {
	bytes := frame(op, d);
	return bytes && http.ws_send(ws, .Binary, bytes) == .None;
}
