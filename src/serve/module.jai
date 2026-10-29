/// A self-hosted fastcord server (`fastcord -serve`): one SQLite file, TLS 1.3 under a pinned self-signed certificate, ALPN fc/1.
#import "Basic";
#import "Atomics";
#import "Thread";
#import "String";
#import "Base64";
#import "Hash_Table";
crypto :: #import "crypto";
etf :: #import "etf";
http :: #import "http";
imagefmt :: #import "imagefmt";
keys :: #import "keys";
locks :: #import "locks";
netio :: #import "netio";
sqlite :: #import "sqlite";
tls :: #import "tls";
mls :: #import "voice_mls";

#load "unfurl.jai";
#load "settings.jai";
#load "voice.jai";
#load "soundboard.jai";
#load "expressions.jai";

ALPN :: "fc/1";
HEARTBEAT_INTERVAL_MS :: 41_250;
LOGIN_DEADLINE_S :: 10;
// A member holds up to 3 connections (2 REST, 1 gateway), so this fits a household of several.
MAX_CONNS_PER_ADDRESS :: 16;
MAX_CONNS :: 1024;
IPV4_MAPPED :: u8.[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0xFF];

Server :: struct {
	db: *sqlite.DB;
	db_mu: locks.Mutex; // A connection's statements run on one thread at a time.
	id: [16]u8;     // Sent as SNI and part of every invite, so one host can serve several servers.
	pin: [32]u8;     // BLAKE3 of the certificate: what invites carry and clients check.
	spki: [32]u8;    // SHA-256 of the certificate's public key: curl's --pinnedpubkey, for webhooks.
	ctx: *tls.SSL_CTX;
	listener: *netio.Listener;
	accept_thread: *Thread;
	mu: locks.Mutex; // Guards conns and activities.
	conns: [..]*Conn;
	activities: [..]Member_Activities; // Kept past a member's last gateway, for when they're back.
	unfurl_mu: locks.Mutex; // Guards unfurl_jobs and unfurl_stop.
	unfurl_wake: locks.Cond;
	unfurl_jobs: [..]Unfurl_Job;
	unfurl_stop: bool;
	unfurl_thread: *Thread;
	unfurl_any_address: bool; // Tests only: let link previews fetch from this machine.
	last_id: s64; // Atomic: the last snowflake issued, so IDs keep rising when the clock steps back.
	next_sweep: s64; // Atomic: when archive_idle next looks for idle threads, in now_ms time.
	clock_offset_ms: s64; // Tests only: added to the clock snowflakes read.
	guild: s64; // The guild ID the client sees.
	name: string;
	// Members' avatar hashes, for those who set one, and every member's handle, so user_value needs no
	// query. A leaf lock: nothing else is taken while it's held, so it may be taken under any other.
	avatar_mu: locks.Mutex;
	avatars: Table(s64, string);
	handles: Table(s64, [8]u8);
	// Voice (voice.jai). voice_mu comes after db_mu and before any Conn's mu; s.mu is never taken under it.
	voice_mu: locks.Mutex;
	voice_states: [..]Voice_State;
	voice_sessions: [..]*Voice_Session;
	dave_groups: [..]*Dave_Group;
	udp: *netio.Udp; // Media, on the listener's port number.
	udp_thread: *Thread;
	udp_stop: bool;  // Atomic.
}

Conn :: struct {
	server: *Server;
	tcp: *netio.Tcp;
	s: netio.Stream;
	thread: *Thread;
	done: bool; // atomic; the thread has finished with s.
	ws: *http.Ws_Conn; // Under server.mu: set once Identify succeeds, so broadcasts reach it.
	user: s64;         // Under server.mu, with ws.
	status: int;       // Under server.mu: an index into STATUSES, the same on all of a member's gateways.
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
	text: bool;      // The writer sends text frames: a voice gateway.
	session: [16]u8; // A gateway's session ID, random per Identify.
	accepted: Apollo_Time;
	authed: bool; // atomic; set by a login or a member's token.
	reply_status: int; // The reply respond kept, 0 when none.
	reply_body: string;
	reply_json: bool;
	reply_type: string; // The Content-Type of a file reply, in temp.
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
	if !sqlite.exec(db, SCHEMA) || !sqlite.exec(db, SOUND_SCHEMA) || !sqlite.exec(db, SETTINGS_SCHEMA) || !sqlite.exec(db, STICKER_SCHEMA) { close(s); return null, false; }
	// Files made before these columns; each fails harmlessly once it exists.
	sqlite.exec(db, "ALTER TABLE users ADD COLUMN left INTEGER NOT NULL DEFAULT 0;");
	sqlite.exec(db, "ALTER TABLE users ADD COLUMN banned INTEGER NOT NULL DEFAULT 0;");
	sqlite.exec(db, "ALTER TABLE users ADD COLUMN ban_reason TEXT;");
	sqlite.exec(db, "ALTER TABLE users ADD COLUMN joined_name TEXT;");
	sqlite.exec(db, "ALTER TABLE users ADD COLUMN avatar TEXT;");
	sqlite.exec(db, "ALTER TABLE users ADD COLUMN avatar_type TEXT;");
	sqlite.exec(db, "ALTER TABLE users ADD COLUMN avatar_data BLOB;");
	sqlite.exec(db, "ALTER TABLE messages ADD COLUMN reply INTEGER;");
	sqlite.exec(db, "ALTER TABLE messages ADD COLUMN everyone INTEGER NOT NULL DEFAULT 0;");
	sqlite.exec(db, "ALTER TABLE messages ADD COLUMN pinned_at INTEGER;");
	sqlite.exec(db, "ALTER TABLE messages ADD COLUMN type INTEGER NOT NULL DEFAULT 0;");
	sqlite.exec(db, "ALTER TABLE messages ADD COLUMN flags INTEGER NOT NULL DEFAULT 0;");
	sqlite.exec(db, "ALTER TABLE channels ADD COLUMN topic TEXT NOT NULL DEFAULT '';");
	sqlite.exec(db, "ALTER TABLE events ADD COLUMN channel INTEGER;");
	sqlite.exec(db, "ALTER TABLE channels ADD COLUMN type INTEGER NOT NULL DEFAULT 0;");
	sqlite.exec(db, "ALTER TABLE channels ADD COLUMN parent INTEGER;");
	sqlite.exec(db, "ALTER TABLE channels ADD COLUMN owner INTEGER;");
	sqlite.exec(db, "ALTER TABLE channels ADD COLUMN slowmode INTEGER NOT NULL DEFAULT 0;");
	sqlite.exec(db, "ALTER TABLE channels ADD COLUMN nsfw INTEGER NOT NULL DEFAULT 0;");
	sqlite.exec(db, "ALTER TABLE channels ADD COLUMN archived INTEGER NOT NULL DEFAULT 0;");
	sqlite.exec(db, "ALTER TABLE channels ADD COLUMN locked INTEGER NOT NULL DEFAULT 0;");
	sqlite.exec(db, "ALTER TABLE channels ADD COLUMN archive_after INTEGER NOT NULL DEFAULT 4320;");
	sqlite.exec(db, "ALTER TABLE channels ADD COLUMN archived_at INTEGER;");
	sqlite.exec(db, "ALTER TABLE invites ADD COLUMN owner INTEGER NOT NULL DEFAULT 0;");
	sqlite.exec(db, "ALTER TABLE invites ADD COLUMN inviter INTEGER;");
	sqlite.exec(db, "ALTER TABLE invites ADD COLUMN channel INTEGER;");
	sqlite.exec(db, "ALTER TABLE invites ADD COLUMN max_age INTEGER NOT NULL DEFAULT 0;");
	sqlite.exec(db, "ALTER TABLE invites ADD COLUMN expires INTEGER NOT NULL DEFAULT 0;");
	sqlite.exec(db, "ALTER TABLE messages ADD COLUMN nonce TEXT;");
	sqlite.exec(db, "ALTER TABLE messages ADD COLUMN webhook INTEGER NOT NULL DEFAULT 0;");
	sqlite.exec(db, "ALTER TABLE messages ADD COLUMN username TEXT;");
	sqlite.exec(db, "ALTER TABLE messages ADD COLUMN snapshot TEXT;");
	sqlite.exec(db, "ALTER TABLE messages ADD COLUMN stickers TEXT;");
	sqlite.exec(db, "ALTER TABLE embeds ADD COLUMN rich TEXT;");
	sqlite.exec(db, "CREATE INDEX IF NOT EXISTS messages_everyone ON messages(id) WHERE everyone = 1;");
	sqlite.exec(db, "CREATE INDEX IF NOT EXISTS messages_nonce ON messages(author, nonce) WHERE nonce IS NOT NULL;");
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
	st = sqlite.prepare(db, "SELECT max((SELECT coalesce(max(id), 0) FROM users), (SELECT coalesce(max(id), 0) FROM channels), (SELECT coalesce(max(id), 0) FROM attachments), (SELECT coalesce(max(max(id), coalesce(max(edited), 0), coalesce(max(pinned_at), 0)), 0) FROM messages));");
	if sqlite.step(st) == .Row s.last_id = max(s.guild, sqlite.col_int(st, 0));
	sqlite.finalize(st);
	st = sqlite.prepare(db, "SELECT id, avatar FROM users WHERE avatar IS NOT NULL;");
	while sqlite.step(st) == .Row table_set(*s.avatars, sqlite.col_int(st, 0), copy_string(sqlite.col_text(st, 1)));
	sqlite.finalize(st);
	st = sqlite.prepare(db, "SELECT u.id, u.root FROM users u WHERE NOT EXISTS(SELECT 1 FROM webhooks w WHERE w.id = u.id);");
	while sqlite.step(st) == .Row table_set(*s.handles, sqlite.col_int(st, 0), member_handle(sqlite.col_blob(st, 1)));
	sqlite.finalize(st);
	// Until someone claims the server, a one-use owner invite exists; the host joins with it first.
	if !meta_get(s, "owner") && !owner_invite(s) {
		code: [16]u8;
		crypto.random_bytes(code);
		sqlite.run(db, "INSERT INTO invites(code, uses_left, owner) VALUES(?, 1, 1);", hex(code,, temp));
	}
	k: [32]u8;
	memcpy(k.data, key.data, 32);
	s.pin = crypto.blake3(cert);
	s.spki = crypto.sha256(p256_spki(cert));
	s.ctx = tls.server_ctx(k, cert, ALPN, "http/1.1");
	crypto.zero(k);
	if !s.ctx { close(s); return null, false; }
	return s, true;
}

// p256_spki finds the SubjectPublicKeyInfo of a P-256 key in our own certificate (selfsigned_cert): its
// fixed DER header and the 65-byte uncompressed point.
p256_spki :: (cert: []u8) -> []u8 {
	HEAD :: u8.[0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01, 0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00, 0x04];
	for 0..cert.count - 91 if memcmp(cert.data + it, HEAD.data, HEAD.count) == 0 return array_view(cert, it, 91);
	assert(false, "no P-256 key in the server's certificate");
	return .[];
}

// webhook_pin is curl's `--pinnedpubkey` value for this server, so tools outside fastcord can post to its
// webhooks without trusting whoever sits in the path (its certificate is self-signed, so they also pass -k).
webhook_pin :: (s: *Server) -> string {
	return tprint("sha256//%", base64_encode(cast(string) s.spki,, temp));
}

// invite_url is what a member pastes into fastcord to join: the pin, where to connect and which server.
invite_url :: (s: *Server, host: string, port: int, code: string, allocator := temp) -> string {
	return invite_url(s.pin, host, port, hex(s.id,, temp), code,, allocator);
}

invite_url :: (pin: [32]u8, host: string, port: int, id_hex: string, code: string, allocator := temp) -> string {
	h := ifx contains(host, ":") then tprint("[%]", host) else host;
	return sprint("fc://%@%:%/%/%", hex(pin,, temp), h, port, id_hex, code,, allocator);
}

// first_invite is the oldest working invite's code, the one the console prints, or "" if none works.
first_invite :: (s: *Server, allocator := temp) -> string {
	locks.guard(*s.db_mu);
	st := sqlite.prepare(s.db, tprint("SELECT code FROM invites WHERE owner = 0 AND % ORDER BY rowid LIMIT 1;", INVITE_LIVE));
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
	u, uerr := netio.listen_udp(l.port, 250);
	if uerr != .None { netio.close_listener(l); free(l); return false; }
	s.listener, s.udp = l, u;
	s.udp_thread = spawn(s, voice_udp);
	s.accept_thread = spawn(s, accept_loop);
	s.unfurl_thread = spawn(s, unfurler);
	return true;
}

// stop closes the listener and every connection, waits for their threads, then frees the server.
stop :: (s: *Server) {
	if s.listener {
		netio.close_listener(s.listener);
		locks.join(s.accept_thread);
		free(s.listener);
		locks.lock(*s.unfurl_mu);
		s.unfurl_stop = true;
		locks.cond_signal(*s.unfurl_wake);
		locks.unlock(*s.unfurl_mu);
		locks.join(s.unfurl_thread);
		atomic_store(*s.udp_stop, true);
		locks.join(s.udp_thread);
		netio.close_udp(s.udp);
	}
	// The accept thread has returned, so nothing else touches conns now.
	for s.conns netio.shutdown(netio.tcp_stream(it.tcp)); // Not it.s: its thread may be replacing it.
	for s.conns {
		locks.join(it.thread);
		netio.close(it.s);
		free(it);
	}
	array_free(s.conns);
	for * s.activities set_activities(it, .[]);
	array_free(s.activities);
	array_free(s.voice_states);
	array_free(s.voice_sessions); // Each session ended with its connection, and each room's group with its last.
	array_free(s.dave_groups);
	close(s);
}

#scope_module

close :: (s: *Server) {
	if s.ctx tls.SSL_CTX_free(s.ctx);
	sqlite.close(s.db);
	free(s.name);
	for s.avatars free(it);
	deinit(*s.avatars);
	deinit(*s.handles);
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
CREATE TABLE IF NOT EXISTS users(id INTEGER PRIMARY KEY, root BLOB UNIQUE NOT NULL, signing_pub BLOB NOT NULL, name TEXT NOT NULL, left INTEGER NOT NULL DEFAULT 0, banned INTEGER NOT NULL DEFAULT 0, ban_reason TEXT, joined_name TEXT, avatar TEXT, avatar_type TEXT, avatar_data BLOB);
CREATE TABLE IF NOT EXISTS sessions(token_hash BLOB PRIMARY KEY, user INTEGER NOT NULL REFERENCES users(id));
CREATE INDEX IF NOT EXISTS sessions_user ON sessions(user);
CREATE TABLE IF NOT EXISTS uploads(token TEXT PRIMARY KEY, user INTEGER NOT NULL, channel INTEGER NOT NULL, filename TEXT NOT NULL, size INTEGER NOT NULL,
	content_type TEXT NOT NULL, created INTEGER NOT NULL, width INTEGER NOT NULL DEFAULT 0, height INTEGER NOT NULL DEFAULT 0, data BLOB);
CREATE TABLE IF NOT EXISTS attachments(id INTEGER PRIMARY KEY, message INTEGER NOT NULL, key TEXT NOT NULL, filename TEXT NOT NULL, content_type TEXT NOT NULL,
	size INTEGER NOT NULL, width INTEGER NOT NULL, height INTEGER NOT NULL, description TEXT NOT NULL, data BLOB NOT NULL);
CREATE INDEX IF NOT EXISTS attachments_message ON attachments(message);
CREATE TABLE IF NOT EXISTS events(id INTEGER PRIMARY KEY, creator INTEGER NOT NULL, name TEXT NOT NULL, description TEXT NOT NULL, location TEXT NOT NULL,
	start INTEGER NOT NULL, end INTEGER NOT NULL, status INTEGER NOT NULL, channel INTEGER);
CREATE TABLE IF NOT EXISTS rsvps(event INTEGER NOT NULL, user INTEGER NOT NULL, PRIMARY KEY(event, user));
CREATE TABLE IF NOT EXISTS snapshot_files(message INTEGER NOT NULL, attachment INTEGER NOT NULL);
CREATE INDEX IF NOT EXISTS snapshot_files_message ON snapshot_files(message);
CREATE INDEX IF NOT EXISTS snapshot_files_attachment ON snapshot_files(attachment);
CREATE TABLE IF NOT EXISTS embeds(message INTEGER NOT NULL, position INTEGER NOT NULL, url TEXT NOT NULL, title TEXT NOT NULL, description TEXT NOT NULL,
	provider TEXT NOT NULL, color INTEGER NOT NULL, rich TEXT, PRIMARY KEY(message, position));
CREATE TABLE IF NOT EXISTS channels(id INTEGER PRIMARY KEY, name TEXT NOT NULL, position INTEGER NOT NULL, topic TEXT NOT NULL DEFAULT '', type INTEGER NOT NULL DEFAULT 0, parent INTEGER, owner INTEGER, slowmode INTEGER NOT NULL DEFAULT 0, nsfw INTEGER NOT NULL DEFAULT 0,
	archived INTEGER NOT NULL DEFAULT 0, locked INTEGER NOT NULL DEFAULT 0, archive_after INTEGER NOT NULL DEFAULT 4320, archived_at INTEGER);
CREATE TABLE IF NOT EXISTS messages(id INTEGER PRIMARY KEY, channel INTEGER NOT NULL REFERENCES channels(id), author INTEGER NOT NULL REFERENCES users(id), content TEXT NOT NULL, edited INTEGER, reply INTEGER, everyone INTEGER NOT NULL DEFAULT 0, pinned_at INTEGER, type INTEGER NOT NULL DEFAULT 0, flags INTEGER NOT NULL DEFAULT 0, nonce TEXT, webhook INTEGER NOT NULL DEFAULT 0, username TEXT, snapshot TEXT, stickers TEXT);
-- A webhook posts as a users row of its own, left = 1, so its messages join like any member's.
CREATE TABLE IF NOT EXISTS webhooks(id INTEGER PRIMARY KEY, channel INTEGER NOT NULL, token TEXT NOT NULL, creator INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS read_states(user INTEGER NOT NULL, channel INTEGER NOT NULL, last INTEGER NOT NULL, mentions INTEGER NOT NULL, PRIMARY KEY(user, channel));
CREATE TABLE IF NOT EXISTS guild_settings(user INTEGER PRIMARY KEY, settings TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS mentions(message INTEGER NOT NULL, user INTEGER NOT NULL, PRIMARY KEY(message, user));
CREATE INDEX IF NOT EXISTS mentions_user ON mentions(user, message);
CREATE TABLE IF NOT EXISTS mention_dismissals(user INTEGER NOT NULL, message INTEGER NOT NULL, PRIMARY KEY(user, message));
CREATE TRIGGER IF NOT EXISTS mention_dismissals_delete AFTER DELETE ON messages BEGIN
	DELETE FROM mention_dismissals WHERE message = old.id;
END;
CREATE TABLE IF NOT EXISTS reactions(message INTEGER NOT NULL, emoji TEXT NOT NULL, user INTEGER NOT NULL, PRIMARY KEY(message, emoji, user));
CREATE TABLE IF NOT EXISTS emojis(id INTEGER PRIMARY KEY, name TEXT NOT NULL, animated INTEGER NOT NULL, type TEXT NOT NULL, data BLOB NOT NULL, user INTEGER NOT NULL);
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
NONCE_WINDOW_MS :: 5 * 60 * 1000;

// Milliseconds since Discord's epoch, the time part of a snowflake.
now_ms :: (s: *Server) -> s64 {
	return to_milliseconds(current_time_consensus() - APOLLO_TIME_FOR_JAN_1_1970) - DISCORD_EPOCH_MS + s.clock_offset_ms;
}

snowflake :: (s: *Server) -> s64 {
	ms := now_ms(s);
	while true {
		last := atomic_read(*s.last_id);
		id := max(ms << 22, last + 1);
		if compare_and_swap(*s.last_id, last, id) return id;
	}
	return 0;
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
	c.reply_status, c.reply_body, c.reply_json, c.reply_type = status, body, json, "";
	return true;
}

flush_reply :: (c: *Conn) -> bool {
	status := c.reply_status;
	if !status return true;
	c.reply_status = 0;
	if c.reply_type return http.h1_write_response(c.s, status, .[.{"Content-Type", c.reply_type}], cast([]u8) c.reply_body) == .None;
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
		gone, joined, banned := false, false, false;
		st := sqlite.prepare(s.db, "SELECT id, left, banned FROM users WHERE root = ?;");
		sqlite.bind(st, 1, cast([]u8) root);
		if sqlite.step(st) == .Row user, gone, banned = sqlite.col_int(st, 0), sqlite.col_int(st, 1) != 0, sqlite.col_int(st, 2) != 0;
		sqlite.finalize(st);
		status, code, message := 0, 0, "";
		if banned {
			status, code, message = 403, 40007, "The user is banned from this guild.";
			user = 0;
		} else if !user || gone {
			name := trim(field("name"));
			owner := false;
			st = sqlite.prepare(s.db, tprint("SELECT owner FROM invites WHERE code = ? AND %;", INVITE_LIVE));
			sqlite.bind(st, 1, field("code"));
			if sqlite.step(st) == .Row owner = sqlite.col_int(st, 0) != 0;
			sqlite.finalize(st);
			if !owner && invites_paused_locked(s) {
				status, code, message = 403, 40069, "Invites are paused for this server.";
			} else if !sqlite.run(s.db, tprint("UPDATE invites SET uses_left = uses_left - (uses_left > 0) WHERE code = ? AND %;", INVITE_LIVE), field("code")) || sqlite.changes(s.db) != 1 {
				status, code, message = 404, 10006, "Unknown Invite";
			} else if !name || name.count > 32 || !text_ok(name) {
				status, code, message = 400, 50035, "Invalid Form Body";
			} else if gone {
				if !sqlite.run(s.db, "UPDATE users SET left = 0 WHERE id = ?;", user) user = 0;
			} else {
				user = snowflake(s);
				joined = true;
				if !sqlite.run(s.db, "INSERT INTO users(id, root, signing_pub, name, joined_name) VALUES(?, ?, ?, ?, ?4);", user, cast([]u8) root, cast([]u8) pub, name) user = 0;
				else { locks.guard(*s.avatar_mu); table_set(*s.handles, user, member_handle(root)); }
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
		// Every start of a client logs in afresh and never reuses its token, so only a member's newest
		// sessions stay.
		if user && !sqlite.run(s.db, tprint("DELETE FROM sessions WHERE user = ?1 AND rowid NOT IN (SELECT rowid FROM sessions WHERE user = ?1 ORDER BY rowid DESC LIMIT %);", MAX_SESSIONS), user) user = 0;
		if !user && !status status, code, message = 500, 0, "500: Internal Server Error";
		sqlite.exec(s.db, ifx status then "ROLLBACK;" else "COMMIT;");
		if status return json_error(c, status, code, message);
	}
	atomic_store(*c.authed, true);
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
	// A connection that hasn't logged in within LOGIN_DEADLINE_S is cut off, so idle or trickling sockets
	// can't pile up. This runs as connections arrive, which is when such a pile-up costs anything.
	reap :: (s: *Server) {
		now := current_time_monotonic();
		for s.conns {
			if atomic_load(*it.done) {
				locks.join(it.thread);
				netio.close(it.s);
				free(it);
				remove it;
			} else if !atomic_load(*it.authed) && now - it.accepted > seconds_to_apollo(LOGIN_DEADLINE_S) {
				netio.shutdown(netio.tcp_stream(it.tcp));
			}
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
		locks.lock(*s.mu);
		reap(s);
		// One address may hold MAX_CONNS_PER_ADDRESS, counting an IPv6 /64 as one address, since a home
		// gets a whole /64 to pick from.
		mapped := memcmp(tcp.peer.data, IPV4_MAPPED.data, IPV4_MAPPED.count) == 0;
		prefix := ifx mapped then 16 else 8;
		same := 0;
		for s.conns if memcmp(it.tcp.peer.data, tcp.peer.data, prefix) == 0 same += 1;
		if same >= MAX_CONNS_PER_ADDRESS || s.conns.count >= MAX_CONNS {
			locks.unlock(*s.mu);
			netio.close(netio.tcp_stream(tcp));
			continue;
		}
		c := New(Conn);
		c.server, c.tcp, c.s = s, tcp, netio.tcp_stream(tcp);
		c.accepted = current_time_monotonic();
		array_add(*s.conns, c);
		c.thread = spawn(c, serve_conn);
		locks.unlock(*s.mu);
	}
}

// serve_conn runs one connection's TLS handshake and HTTP/1.1 requests, which end in a gateway upgrade.
// Its stream is closed by whoever reaps it (accept_loop or stop), so a shutdown never races a close.
serve_conn :: (c: *Conn) {
	defer atomic_store(*c.done, true);
	session, _, _ := tls.accept(c.s, c.server.ctx, none_ok = true);
	if !session return;
	c.s = tls.stream(session);
	// Anything but fastcord (curl, CI runners, monitoring) reaches webhooks and nothing else, by any name.
	plain := tls.negotiated_alpn(session) != ALPN;
	name := tls.server_name(session);
	if name && name != id_hex(c.server) && !plain return;

	h: http.H1_Conn;
	http.h1_init(*h, c.s, .{max_header_bytes = 16 << 10, max_headers = 64, max_body = 1 << 20});
	defer http.h1_destroy(*h, false);
	while true {
		if !flush_reply(c) return; // The last request's, now that its handler has let go of every lock.
		reset_temporary_storage();
		req, err := http.h1_read_request_head(*h);
		defer http.request_destroy(*req);
		// Only a PUT to an upload URL this server handed out may be larger than 1 MiB, and only as large
		// as the file it was handed out for.
		if err == .None err = http.h1_read_request_body(*h, *req, ifx req.method == "PUT" then max(upload_size(c.server, req.path), 1 << 20) else 1 << 20);
		if err != .None {
			if err == .Too_Large http.h1_write_response(c.s, 413, .[], .[]);
			else if err == .Protocol http.h1_write_response(c.s, 400, .[], .[]);
			return;
		}
		if plain && !begins_with(req.path, "/api/webhooks/") && !begins_with(req.path, "/api/v9/webhooks/") && !begins_with(req.path, "/api/v10/webhooks/") {
			http.h1_write_response(c.s, 404, .[], .[]);
			return;
		}
		if http.header_has_token(req.headers, "upgrade", "websocket") {
			// The voice gateway is the client's /?v=9, with no encoding, on the same address.
			if req.path == "/?v=9" voice_gateway(c, req);
			else gateway(c, req);
			return;
		}
		if req.method == "POST" && req.path == "/api/v9/fc/login" {
			if !login(c, session, req) return;
			continue;
		}
		if begins_with(req.path, "/upload/") || begins_with(req.path, "/attachments/") || begins_with(req.path, "/api/v9/attachments/") || begins_with(req.path, "/icons/") || begins_with(req.path, "/avatars/") || begins_with(req.path, "/emojis/") || begins_with(req.path, "/soundboard-sounds/") || begins_with(req.path, "/stickers/") {
			if !files(c, req) return;
			continue;
		}
		if begins_with(req.path, tprint("/api/v9/guilds/%/soundboard-sounds", c.server.guild)) || req.path == "/api/v9/soundboard-default-sounds"
				|| (begins_with(req.path, "/api/v9/channels/") && ends_with(req.path, "/send-soundboard-sound")) {
			if !soundboard(c, req) return;
			continue;
		}
		if begins_with(req.path, "/api/v9/channels/") {
			if !channel_messages(c, req) return;
			continue;
		}
		if begins_with(req.path, "/api/webhooks/") || begins_with(req.path, "/api/v9/webhooks/") || begins_with(req.path, "/api/v10/webhooks/") {
			if !webhook(c, req) return;
			continue;
		}
		if req.method == "GET" && req.path == tprint("/api/v9/guilds/%/webhooks", c.server.guild) {
			token, _ := http.header_get(req.headers, "authorization");
			user := session_user(c, token);
			if !(ifx user then channel_webhooks(c, req, user, 0) else json_error(c, 401, 0, "401: Unauthorized")) return;
			continue;
		}
		if req.method == "GET" && begins_with(req.path, tprint("/api/v9/guilds/%/messages/search", c.server.guild)) {
			if !search(c, req) return;
			continue;
		}
		if begins_with(req.path, tprint("/api/v9/guilds/%/emojis", c.server.guild)) || begins_with(req.path, tprint("/api/v9/guilds/%/stickers", c.server.guild)) || begins_with(req.path, "/api/v9/stickers/") {
			if !expressions(c, req) return; // expressions.jai
			continue;
		}
		if req.method == "POST" && req.path == tprint("/api/v9/guilds/%/channels", c.server.guild) {
			if !create_channel(c, req) return;
			continue;
		}
		if req.method == "GET" && begins_with(req.path, "/api/v9/users/") && req.path.count > "/api/v9/users/".count && is_digit(req.path["/api/v9/users/".count]) {
			if !user_profile(c, req) return;
			continue;
		}
		if req.method == "PATCH" && req.path == "/api/v9/users/@me" {
			if !edit_me(c, req) return;
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
		if begins_with(req.path, "/api/v9/users/@me/mentions") || begins_with(req.path, "/api/v9/users/%40me/mentions") {
			if !recent_mentions(c, req) return;
			continue;
		}
		if req.method == "DELETE" && req.path == tprint("/api/v9/users/@me/guilds/%", c.server.guild) {
			if !leave(c, req) return;
			continue;
		}
		if (req.method == "GET" && req.path == tprint("/api/v9/guilds/%/invites", c.server.guild)) || (req.method == "DELETE" && begins_with(req.path, "/api/v9/invites/")) {
			if !manage_invites(c, req) return;
			continue;
		}
		if begins_with(req.path, tprint("/api/v9/guilds/%/members/", c.server.guild)) || begins_with(req.path, tprint("/api/v9/guilds/%/bans/", c.server.guild)) {
			if !moderate(c, req) return;
			continue;
		}
		if req.method == "GET" && (req.path == tprint("/api/v9/guilds/%/bans", c.server.guild) || begins_with(req.path, tprint("/api/v9/guilds/%/bans?", c.server.guild))) {
			if !list_bans(c, req) return;
			continue;
		}
		if begins_with(req.path, tprint("/api/v9/guilds/%/scheduled-events", c.server.guild)) || begins_with(req.path, "/api/v9/users/@me/scheduled-events")
				|| (req.method == "POST" && begins_with(req.path, tprint("/api/v9/guilds/%/ack/", c.server.guild))) {
			if !scheduled_events(c, req) return;
			continue;
		}
		handled, keep := settings_route(c, req); // settings.jai
		if handled {
			if !keep return;
			continue;
		}
		if !json_error(c, 404, 0, "404: Not Found") return;
	}
}

// Scheduled events. Until roles land (Hosting 4) only the owner creates them, the owner or the creator
// edits, starts, ends and cancels them, and anyone marks themselves Interested. An event takes place in a voice
// channel (entity type 2), which has no end and ends once the channel empties, or Somewhere Else (3), with
// an end. Both start on time by themselves (archive_idle).
MAX_EVENTS :: 100; // Scheduled and active at once, as on Discord.
IN_VOICE :: 2;
EXTERNAL :: 3;
EVENT_SCHEDULED :: 1;
EVENT_ACTIVE :: 2;
EVENT_COMPLETED :: 3;
EVENT_CANCELED :: 4;

EVENT_SELECT :: "SELECT e.id, e.creator, u.name, e.name, e.description, e.location, e.start, e.end, e.status, (SELECT count(*) FROM rsvps r WHERE r.event = e.id), coalesce(e.channel, 0) FROM events e JOIN users u ON u.id = e.creator";

// iso_ms writes unix milliseconds as Discord writes timestamps.
iso_ms :: (unix_ms: s64) -> string {
	t := to_calendar(APOLLO_TIME_FOR_JAN_1_1970 + milliseconds_to_apollo(unix_ms), .UTC);
	two :: (x: int) -> string { return tprint("%", formatInt(x, minimum_digits = 2)); }
	return tprint("%-%-%T%:%:%.%+00:00", t.year, two(t.month_starting_at_0 + 1), two(t.day_of_month_starting_at_0 + 1),
		two(t.hour), two(t.minute), two(t.second), formatInt(t.millisecond, minimum_digits = 3));
}

// parse_iso reads a UTC ISO 8601 time ("2026-10-26T23:00:00.650Z", or "+00:00" for the "Z") as unix
// milliseconds; other offsets are refused rather than guessed at.
parse_iso :: (text: string) -> s64, bool {
	FORMAT :: "dddd-dd-ddTdd:dd:dd";
	if text.count < FORMAT.count return 0, false;
	f: [6]int;
	n := 0;
	for i: 0..FORMAT.count - 1 {
		ch := text[i];
		if FORMAT[i] == #char "d" {
			if ch < #char "0" || ch > #char "9" return 0, false;
			f[n] = f[n] * 10 + ch - #char "0";
		} else {
			if ch != FORMAT[i] return 0, false;
			n += 1;
		}
	}
	y, m, d, h, mi, sec := f[0], f[1], f[2], f[3], f[4], f[5];
	i := FORMAT.count;
	ms := 0;
	if i < text.count && text[i] == #char "." {
		i += 1;
		digits := 0;
		while i < text.count && text[i] >= #char "0" && text[i] <= #char "9" && digits < 9 {
			if digits < 3 ms = ms * 10 + text[i] - #char "0";
			i += 1;
			digits += 1;
		}
		if digits == 0 return 0, false;
		while digits < 3 { ms *= 10; digits += 1; }
	}
	rest := advance(text, i);
	if rest != "Z" && rest != "+00:00" return 0, false;
	if y < 1970 || m < 1 || m > 12 || d < 1 || d > 31 || h > 23 || mi > 59 || sec > 59 return 0, false;
	// days_from_civil (Howard Hinnant, "chrono-Compatible Low-Level Date Algorithms").
	yy := y - ifx m <= 2 then 1 else 0;
	era := yy / 400;
	yoe := yy - era * 400;
	doy := (153 * (m + ifx m > 2 then -3 else 9) + 2) / 5 + d - 1;
	days := era * 146097 + yoe * 365 + yoe / 4 - yoe / 100 + doy - 719468;
	return ((cast(s64) days * 86400 + h * 3600 + mi * 60 + sec) * 1000 + ms), true;
}

row_event :: (s: *Server, st: *sqlite.Stmt) -> etf.Value {
	creator := sqlite.col_int(st, 1);
	channel := sqlite.col_int(st, 10);
	m := etf.map_builder(16,, temp);
	etf.map_put(*m, "id", snow(sqlite.col_int(st, 0)));
	etf.map_put(*m, "guild_id", snow(s.guild));
	etf.map_put(*m, "channel_id", ifx channel then snow(channel) else etf.Value.{});
	etf.map_put(*m, "creator_id", snow(creator));
	etf.map_put(*m, "creator", user_value(s, creator, copy_string(sqlite.col_text(st, 2),, temp)));
	etf.map_put(*m, "name", etf.vstring(copy_string(sqlite.col_text(st, 3),, temp)));
	etf.map_put(*m, "description", etf.vstring(copy_string(sqlite.col_text(st, 4),, temp)));
	etf.map_put(*m, "scheduled_start_time", etf.vstring(iso_ms(sqlite.col_int(st, 6))));
	etf.map_put(*m, "scheduled_end_time", ifx channel then etf.Value.{} else etf.vstring(iso_ms(sqlite.col_int(st, 7))));
	etf.map_put(*m, "privacy_level", etf.vint(2));
	etf.map_put(*m, "status", etf.vint(sqlite.col_int(st, 8)));
	etf.map_put(*m, "entity_type", etf.vint(ifx channel then IN_VOICE else EXTERNAL));
	etf.map_put(*m, "entity_id", .{});
	meta := etf.map_builder(1,, temp);
	etf.map_put(*meta, "location", etf.vstring(copy_string(sqlite.col_text(st, 5),, temp)));
	etf.map_put(*m, "entity_metadata", ifx channel then etf.Value.{} else etf.vmap(etf.map_done(*meta)));
	etf.map_put(*m, "user_count", etf.vint(sqlite.col_int(st, 9)));
	etf.map_put(*m, "recurrence_rule", .{});
	return etf.vmap(etf.map_done(*m));
}

// event_locked is an event as sent to clients, or null; the caller holds db_mu.
event_locked :: (s: *Server, id: s64) -> etf.Value {
	st := sqlite.prepare(s.db, tprint("% WHERE e.id = ?;", EVENT_SELECT));
	defer sqlite.finalize(st);
	sqlite.bind(st, 1, id);
	if sqlite.step(st) != .Row return .{};
	return row_event(s, st);
}

// events_locked lists the scheduled and active events, for READY and the list route.
events_locked :: (s: *Server) -> etf.Value {
	list: [..]etf.Value;
	list.allocator = temp;
	st := sqlite.prepare(s.db, tprint("% WHERE e.status IN (%, %) ORDER BY e.start, e.id;", EVENT_SELECT, EVENT_SCHEDULED, EVENT_ACTIVE));
	while sqlite.step(st) == .Row array_add(*list, row_event(s, st));
	sqlite.finalize(st);
	return etf.vlist(list);
}

rsvp_value :: (s: *Server, event: s64, user: s64) -> etf.Value {
	m := etf.map_builder(4,, temp);
	etf.map_put(*m, "guild_scheduled_event_id", snow(event));
	etf.map_put(*m, "user_id", snow(user));
	etf.map_put(*m, "guild_id", snow(s.guild));
	etf.map_put(*m, "response", etf.vint(1));
	return etf.vmap(etf.map_done(*m));
}

// /api/v9/guilds/{id}/scheduled-events[/{event}[/users[/@me | /counts]]], GET /users/@me/scheduled-events
// (the member's own Interested marks) and POST /guilds/{id}/ack/1/{event}, which needs nothing kept.
scheduled_events :: (c: *Conn, req: http.Request) -> bool {
	s := c.server;
	token, _ := http.header_get(req.headers, "authorization");
	user := session_user(c, token);
	if !user return json_error(c, 401, 0, "401: Unauthorized");
	path := req.path;
	q := find_index_from_left(path, #char "?");
	if q >= 0 path = slice(path, 0, q);
	if begins_with(path, tprint("/api/v9/guilds/%/ack/", s.guild)) return respond(c, 204, json = false);
	if path == "/api/v9/users/@me/scheduled-events" {
		list: [..]etf.Value;
		list.allocator = temp;
		locks.guard(*s.db_mu);
		st := sqlite.prepare(s.db, "SELECT event FROM rsvps WHERE user = ? ORDER BY event LIMIT 1000;");
		sqlite.bind(st, 1, user);
		while sqlite.step(st) == .Row array_add(*list, rsvp_value(s, sqlite.col_int(st, 0), user));
		sqlite.finalize(st);
		return json_reply(c, 200, etf.vlist(list));
	}
	parts := split(advance(path, tprint("/api/v9/guilds/%/scheduled-events", s.guild).count), "/",, temp);
	// parts[0] is "" (the path ends at scheduled-events or goes on with a slash).
	if parts.count == 1 && parts[0] == "" {
		if req.method == "GET" {
			locks.guard(*s.db_mu);
			return json_reply(c, 200, events_locked(s));
		}
		if req.method != "POST" return json_error(c, 405, 0, "405: Method Not Allowed");
		v, err := etf.from_json(cast(string) req.body,, temp);
		if err != .None || v.kind != .Map return json_error(c, 400, 50035, "Invalid Form Body");
		str :: (key: string) -> string, bool #expand {
			f, _ := etf.map_get(v.map, key);
			return ifx f.kind == .String then f.s else "", f.kind == .String || f.kind == .Nil;
		}
		name, ok_name := str("name");
		description, ok_desc := str("description");
		start_s, _ := str("scheduled_start_time");
		end_s, _ := str("scheduled_end_time");
		kind, _ := etf.map_get(v.map, "entity_type");
		meta, _ := etf.map_get(v.map, "entity_metadata");
		channel_s, _ := str("channel_id");
		channel, _ := string_to_int(channel_s, T = s64);
		location: string;
		if meta.kind == .Map {
			l, _ := etf.map_get(meta.map, "location");
			if l.kind == .String location = trim(l.s);
		}
		name = trim(name);
		start, ok_start := parse_iso(start_s);
		end, ok_end := parse_iso(end_s);
		in_voice := kind.kind == .Int && kind.i == IN_VOICE;
		if in_voice && !end_s location, end, ok_end = "", 0, true; // A voice event has no place or end.
		now := now_ms(s) + DISCORD_EPOCH_MS;
		if !ok_name || !ok_desc || !name || name.count > 100 || !text_ok(name) || description.count > 1000 || !text_ok(description, lines = true)
			|| kind.kind != .Int || !(in_voice && channel > 0) && !(kind.i == EXTERNAL && location && location.count <= 100 && text_ok(location))
			|| !ok_start || !ok_end || start < now - 60_000 || (!in_voice && (end <= start || end - start > 366 * 86_400_000)) {
			return json_error(c, 400, 50035, "Invalid Form Body");
		}
		event: etf.Value;
		id := snowflake(s);
		{
			locks.guard(*s.db_mu);
			if owner_id(s) != user return json_error(c, 403, 50013, "Missing Permissions");
			if in_voice && channel_type_locked(s, channel) != VOICE return json_error(c, 400, 50035, "Invalid Form Body");
			st := sqlite.prepare(s.db, tprint("SELECT count(*) FROM events WHERE status IN (%, %);", EVENT_SCHEDULED, EVENT_ACTIVE));
			n := ifx sqlite.step(st) == .Row then sqlite.col_int(st, 0) else 0;
			sqlite.finalize(st);
			if n >= MAX_EVENTS return json_error(c, 400, 30038, tprint("Maximum number of guild events reached (%)", MAX_EVENTS));
			ok := sqlite.exec(s.db, "BEGIN;")
				&& sqlite.run(s.db, tprint("INSERT INTO events(id, creator, name, description, location, start, end, status, channel) VALUES(?, ?, ?, ?, ?, ?, ?, %, nullif(?, 0));", EVENT_SCHEDULED), id, user, name, description, location, start, end, ifx in_voice then channel else 0)
				&& sqlite.run(s.db, "INSERT INTO rsvps(event, user) VALUES(?, ?);", id, user)
				&& sqlite.exec(s.db, "COMMIT;");
			if !ok { sqlite.exec(s.db, "ROLLBACK;"); return json_error(c, 500, 0, "500: Internal Server Error"); }
			event = event_locked(s, id);
		}
		broadcast(s, "GUILD_SCHEDULED_EVENT_CREATE", event);
		broadcast(s, "GUILD_SCHEDULED_EVENT_USER_ADD", rsvp_value(s, id, user));
		return json_reply(c, 200, event);
	}
	if parts.count < 2 || parts[0] != "" return json_error(c, 404, 0, "404: Not Found");
	id, ok_id := string_to_int(parts[1], T = s64);
	if !ok_id || id <= 0 return json_error(c, 400, 50035, "Invalid Form Body");
	event: etf.Value;
	creator: s64;
	{
		locks.guard(*s.db_mu);
		st := sqlite.prepare(s.db, "SELECT creator FROM events WHERE id = ?;");
		sqlite.bind(st, 1, id);
		if sqlite.step(st) == .Row creator = sqlite.col_int(st, 0);
		sqlite.finalize(st);
	}
	if !creator return json_error(c, 404, 10070, "Unknown Guild Scheduled Event");
	if parts.count == 4 && parts[2] == "users" && parts[3] == "counts" && req.method == "GET" {
		locks.guard(*s.db_mu);
		st := sqlite.prepare(s.db, "SELECT count(*) FROM rsvps WHERE event = ?;");
		sqlite.bind(st, 1, id);
		n := ifx sqlite.step(st) == .Row then sqlite.col_int(st, 0) else 0;
		sqlite.finalize(st);
		return respond(c, 200, tprint("{\"guild_scheduled_event_count\": %, \"guild_scheduled_event_exception_counts\": {}}", n));
	}
	if parts.count == 3 && parts[2] == "users" && req.method == "GET" {
		list: [..]etf.Value;
		list.allocator = temp;
		locks.guard(*s.db_mu);
		st := sqlite.prepare(s.db, "SELECT u.id, u.name FROM rsvps r JOIN users u ON u.id = r.user WHERE r.event = ? AND u.left = 0 ORDER BY u.id LIMIT 100;");
		sqlite.bind(st, 1, id);
		while sqlite.step(st) == .Row {
			m := etf.map_builder(2,, temp);
			etf.map_put(*m, "guild_scheduled_event_id", snow(id));
			etf.map_put(*m, "user", user_value(s, sqlite.col_int(st, 0), copy_string(sqlite.col_text(st, 1),, temp)));
			array_add(*list, etf.vmap(etf.map_done(*m)));
		}
		sqlite.finalize(st);
		return json_reply(c, 200, etf.vlist(list));
	}
	if parts.count == 4 && parts[2] == "users" && parts[3] == "@me" && (req.method == "PUT" || req.method == "DELETE") {
		adding := req.method == "PUT";
		changed: bool;
		{
			locks.guard(*s.db_mu);
			ok := ifx adding then sqlite.run(s.db, "INSERT OR IGNORE INTO rsvps(event, user) VALUES(?, ?);", id, user)
				else sqlite.run(s.db, "DELETE FROM rsvps WHERE event = ? AND user = ?;", id, user);
			if !ok return json_error(c, 500, 0, "500: Internal Server Error");
			changed = sqlite.changes(s.db) > 0;
		}
		if changed broadcast(s, ifx adding then "GUILD_SCHEDULED_EVENT_USER_ADD" else "GUILD_SCHEDULED_EVENT_USER_REMOVE", rsvp_value(s, id, user));
		if adding return json_reply(c, 200, rsvp_value(s, id, user));
		return respond(c, 204, json = false);
	}
	if parts.count != 2 return json_error(c, 404, 0, "404: Not Found");
	if req.method == "GET" {
		locks.guard(*s.db_mu);
		return json_reply(c, 200, event_locked(s, id));
	}
	if req.method == "DELETE" {
		{
			locks.guard(*s.db_mu);
			if owner_id(s) != user && creator != user return json_error(c, 403, 50013, "Missing Permissions");
			event = event_locked(s, id);
			ok := sqlite.exec(s.db, "BEGIN;")
				&& sqlite.run(s.db, "DELETE FROM rsvps WHERE event = ?;", id)
				&& sqlite.run(s.db, "DELETE FROM events WHERE id = ?;", id)
				&& sqlite.exec(s.db, "COMMIT;");
			if !ok { sqlite.exec(s.db, "ROLLBACK;"); return json_error(c, 500, 0, "500: Internal Server Error"); }
		}
		broadcast(s, "GUILD_SCHEDULED_EVENT_DELETE", event);
		return respond(c, 204, json = false);
	}
	if req.method != "PATCH" return json_error(c, 405, 0, "405: Method Not Allowed");
	v, err := etf.from_json(cast(string) req.body,, temp);
	if err != .None || v.kind != .Map return json_error(c, 400, 50035, "Invalid Form Body");
	{
		locks.guard(*s.db_mu);
		if owner_id(s) != user && creator != user return json_error(c, 403, 50013, "Missing Permissions");
		st := sqlite.prepare(s.db, "SELECT name, description, location, start, end, status, coalesce(channel, 0) FROM events WHERE id = ?;");
		sqlite.bind(st, 1, id);
		if sqlite.step(st) != .Row { sqlite.finalize(st); return json_error(c, 404, 10070, "Unknown Guild Scheduled Event"); }
		name := copy_string(sqlite.col_text(st, 0),, temp);
		description := copy_string(sqlite.col_text(st, 1),, temp);
		location := copy_string(sqlite.col_text(st, 2),, temp);
		start, end, status, channel := sqlite.col_int(st, 3), sqlite.col_int(st, 4), sqlite.col_int(st, 5), sqlite.col_int(st, 6);
		kind := ifx channel then IN_VOICE else EXTERNAL;
		sqlite.finalize(st);
		bad := false;
		for v.map {
			key := it.key.s;
			val := it.value;
			if key == {
			case "name";
				if val.kind != .String || !trim(val.s) || trim(val.s).count > 100 || !text_ok(trim(val.s)) bad = true;
				if !bad name = trim(val.s);
			case "description";
				if (val.kind != .String && val.kind != .Nil) || (val.kind == .String && (val.s.count > 1000 || !text_ok(val.s, lines = true))) bad = true;
				if !bad description = ifx val.kind == .String then val.s else "";
			case "scheduled_start_time";
				t, ok := parse_iso(ifx val.kind == .String then val.s else "");
				if !ok || status != EVENT_SCHEDULED bad = true;
				start = t;
			case "scheduled_end_time";
				t, ok := parse_iso(ifx val.kind == .String then val.s else "");
				if !ok bad = true;
				end = t;
			case "entity_metadata";
				l: etf.Value;
				if val.kind == .Map l, _ = etf.map_get(val.map, "location");
				if val.kind == .Nil { location = ""; continue; }
				if l.kind != .String || !trim(l.s) || trim(l.s).count > 100 || !text_ok(trim(l.s)) bad = true;
				if !bad location = trim(l.s);
			case "status";
				// Scheduled goes to active or canceled, and active to completed, as on Discord.
				next := ifx val.kind == .Int then val.i else 0;
				if !((status == EVENT_SCHEDULED && (next == EVENT_ACTIVE || next == EVENT_CANCELED)) || (status == EVENT_ACTIVE && next == EVENT_COMPLETED) || next == status) bad = true;
				status = next;
			case "entity_type";
				if val.kind != .Int || (val.i != EXTERNAL && val.i != IN_VOICE) bad = true;
				kind = val.i;
			case "channel_id";
				ok: bool;
				channel, ok = string_to_int(ifx val.kind == .String then val.s else "0", T = s64);
				if !ok bad = true;
			case "privacy_level"; #through;
			case "recurrence_rule";
			case; bad = true;
			}
		}
		// A voice event needs a voice channel and keeps no place or end; one Somewhere Else needs both.
		if kind == IN_VOICE { location, end = "", 0; } else channel = 0;
		if bad || (kind == IN_VOICE && channel_type_locked(s, channel) != VOICE) || (kind == EXTERNAL && (!location || end <= start || end - start > 366 * 86_400_000)) {
			return json_error(c, 400, 50035, "Invalid Form Body");
		}
		if !sqlite.run(s.db, "UPDATE events SET name = ?, description = ?, location = ?, start = ?, end = ?, status = ?, channel = nullif(?, 0) WHERE id = ?;", name, description, location, start, end, status, channel, id) {
			return json_error(c, 500, 0, "500: Internal Server Error");
		}
		event = event_locked(s, id);
	}
	broadcast(s, "GUILD_SCHEDULED_EVENT_UPDATE", event);
	return json_reply(c, 200, event);
}

// session_user is the member a token (as sent in Identify or the authorization header) logs in as, or 0.
// A token that names a member also marks c as logged in, which spares it the login deadline.
session_user :: (c: *Conn, token: string) -> id: s64, name: string {
	s := c.server;
	t: [32]u8;
	if !unhex(token, t) return 0, "";
	h := crypto.blake3(t);
	locks.guard(*s.db_mu);
	st := sqlite.prepare(s.db, "SELECT u.id, u.name FROM sessions s JOIN users u ON u.id = s.user WHERE s.token_hash = ?;");
	defer sqlite.finalize(st);
	sqlite.bind(st, 1, cast([]u8) h);
	if sqlite.step(st) != .Row return 0, "";
	atomic_store(*c.authed, true);
	return sqlite.col_int(st, 0), copy_string(sqlite.col_text(st, 0 + 1),, temp);
}

snow :: (id: s64) -> etf.Value { return etf.vstring(tprint("%", id)); }

// member_handle is a member's unique, unchosen username: 8 base32 characters (40 bits) of a hash of
// their root. Names are free to pick, so this is what tells two members of the same name apart, as
// Discord's unique @username does.
member_handle :: (root: []u8) -> [8]u8 {
	h := crypto.blake3_derive("fastcord 2026-10-29 serve member handle", root);
	bits := (cast(u64) h[0] << 32) | (cast(u64) h[1] << 24) | (cast(u64) h[2] << 16) | (cast(u64) h[3] << 8) | h[4];
	out: [8]u8;
	for 0..7 out[it] = "abcdefghijklmnopqrstuvwxyz234567"[(bits >> (35 - 5 * it)) & 31];
	return out;
}

user_value :: (s: *Server, id: s64, name: string, bot := false) -> etf.Value {
	avatar: etf.Value;
	username := name;
	{
		locks.guard(*s.avatar_mu);
		hash := table_find_pointer(*s.avatars, id);
		if hash avatar = etf.vstring(copy_string(hash.*,, temp));
		handle := table_find_pointer(*s.handles, id);
		if handle && !bot username = copy_string(string.{8, handle.data},, temp);
	}
	m := etf.map_builder(6,, temp);
	if bot etf.map_put(*m, "bot", etf.vbool(true));
	etf.map_put(*m, "id", snow(id));
	etf.map_put(*m, "username", etf.vstring(username));
	etf.map_put(*m, "global_name", etf.vstring(name));
	etf.map_put(*m, "discriminator", etf.vstring("0"));
	etf.map_put(*m, "avatar", avatar);
	return etf.vmap(etf.map_done(*m));
}

// image_data_uri reads a `data:image/...;base64,` URI of at most max bytes, checked by its magic bytes and
// never decoded; the bytes are in temp.
image_data_uri :: (uri: string, max: int) -> []u8, imagefmt.Format, bool {
	comma := find_index_from_left(uri, #char ",");
	if !begins_with(uri, "data:image/") || comma < 0 || !ends_with(slice(uri, 0, comma), ";base64") || uri.count - comma > max / 3 * 4 + 8 return .[], .Unknown, false;
	data, ok := base64_decode(advance(uri, comma + 1),, temp);
	bytes := cast([]u8) data;
	format := imagefmt.sniff(bytes);
	if !ok || bytes.count > max || format == .Unknown return .[], .Unknown, false;
	return bytes, format, true;
}

IMAGE_TYPES :: string.["", "image/png", "image/gif", "image/jpeg", "image/webp"];

// A new image's hash: random, so its URL can't be guessed, and "a_" for a GIF as Discord marks animated ones.
image_hash :: (format: imagefmt.Format) -> string {
	b: [16]u8;
	crypto.random_bytes(b);
	return tprint("%1%2", ifx format == .GIF then "a_" else "", hex(b,, temp));
}

// PATCH /api/v9/users/@me {avatar}: a member sets their avatar on this server, a `data:` URI, or null to
// remove it. It is theirs here only: nothing ties it to their Discord account.
edit_me :: (c: *Conn, req: http.Request) -> bool {
	s := c.server;
	token, _ := http.header_get(req.headers, "authorization");
	user, name := session_user(c, token);
	if !user return json_error(c, 401, 0, "401: Unauthorized");
	v, err := etf.from_json(cast(string) req.body,, temp);
	avatar_v: etf.Value;
	has_avatar := false;
	if err == .None && v.kind == .Map avatar_v, has_avatar = etf.map_get(v.map, "avatar");
	if !has_avatar return json_error(c, 400, 50035, "Invalid Form Body");
	data: []u8;
	format: imagefmt.Format;
	if avatar_v.kind != .Nil {
		ok: bool;
		data, format, ok = image_data_uri(ifx avatar_v.kind == .String then avatar_v.s else "", AVATAR_MAX_BYTES);
		if !ok return json_error(c, 400, 50035, "Invalid Form Body");
	}
	hash := ifx data then image_hash(format) else "";
	{
		locks.guard(*s.db_mu);
		ok := ifx data
			then sqlite.run(s.db, "UPDATE users SET avatar = ?, avatar_type = ?, avatar_data = ? WHERE id = ?;", hash, IMAGE_TYPES[cast(int) format], data, user)
			else sqlite.run(s.db, "UPDATE users SET avatar = NULL, avatar_type = NULL, avatar_data = NULL WHERE id = ?;", user);
		if !ok return json_error(c, 500, 0, "500: Internal Server Error");
		locks.guard(*s.avatar_mu);
		old := table_find_pointer(*s.avatars, user);
		if old free(old.*);
		if hash table_set(*s.avatars, user, copy_string(hash));
		else table_remove(*s.avatars, user);
	}
	me := user_value(s, user, name);
	m := etf.map_builder(4,, temp);
	etf.map_put(*m, "guild_id", snow(s.guild));
	etf.map_put(*m, "user", me);
	etf.map_put(*m, "nick", .{});
	no_roles: []etf.Value;
	etf.map_put(*m, "roles", etf.vlist(no_roles));
	broadcast(s, "GUILD_MEMBER_UPDATE", etf.vmap(etf.map_done(*m)));
	broadcast(s, "GUILD_MEMBER_LIST_UPDATE", member_list_value(s));
	return json_reply(c, 200, me);
}

AVATAR_MAX_BYTES :: 512 * 1024;

// GET /api/v9/users/{id}/profile: what this server knows of a member, in Discord's shape. A member's ID
// is made when they first join, so it is also their join time; this server is the one mutual guild, and
// there are no friends, bios or badges here. GET /users/{id}/relationships (mutual friends) is empty.
user_profile :: (c: *Conn, req: http.Request) -> bool {
	s := c.server;
	token, _ := http.header_get(req.headers, "authorization");
	viewer := session_user(c, token);
	if !viewer return json_error(c, 401, 0, "401: Unauthorized");
	path := req.path;
	q := find_index_from_left(path, #char "?");
	if q >= 0 path.count = q;
	parts := split(advance(path, "/api/v9/users/".count), "/",, temp);
	id, ok := string_to_int(parts[0], T = s64);
	if !ok || parts.count != 2 || (parts[1] != "profile" && parts[1] != "relationships") return json_error(c, 404, 0, "404: Not Found");
	if parts[1] == "relationships" return respond(c, 200, "[]");
	name: string;
	{
		locks.guard(*s.db_mu);
		st := sqlite.prepare(s.db, "SELECT name FROM users WHERE id = ? AND left = 0;");
		defer sqlite.finalize(st);
		sqlite.bind(st, 1, id);
		if sqlite.step(st) != .Row return json_error(c, 404, 10013, "Unknown User");
		name = copy_string(sqlite.col_text(st, 0),, temp);
	}
	empty: []etf.Value;
	member := etf.map_builder(3,, temp);
	etf.map_put(*member, "joined_at", etf.vstring(iso(id)));
	etf.map_put(*member, "nick", .{});
	etf.map_put(*member, "roles", etf.vlist(empty));
	mutual := etf.map_builder(2,, temp);
	etf.map_put(*mutual, "id", snow(s.guild));
	etf.map_put(*mutual, "nick", .{});
	mutuals := NewArray(1, etf.Value,, temp);
	mutuals[0] = etf.vmap(etf.map_done(*mutual));
	profile := etf.map_builder(2,, temp);
	etf.map_put(*profile, "bio", etf.vstring(""));
	etf.map_put(*profile, "pronouns", etf.vstring(""));
	m := etf.map_builder(7,, temp);
	etf.map_put(*m, "user", user_value(s, id, name));
	etf.map_put(*m, "user_profile", etf.vmap(etf.map_done(*profile)));
	etf.map_put(*m, "guild_member", etf.vmap(etf.map_done(*member)));
	etf.map_put(*m, "mutual_guilds", etf.vlist(ifx id == viewer then empty else mutuals));
	etf.map_put(*m, "mutual_friends", etf.vlist(empty));
	etf.map_put(*m, "badges", etf.vlist(empty));
	etf.map_put(*m, "guild_badges", etf.vlist(empty));
	return json_reply(c, 200, etf.vmap(etf.map_done(*m)));
}

// iso is a snowflake's creation time as Discord writes timestamps.
iso :: (id: s64) -> string { return iso_ms((id >> 22) + DISCORD_EPOCH_MS); }

// edited is a snowflake minted at the edit, so iso gives its time; 0 if never edited. A reply (type 19)
// carries the message it answers as referenced, or null once that is deleted. A forward's snapshot is
// the JSON forward_snapshot made: {channel_id, message_id, message}.
message_value :: (s: *Server, id: s64, channel: s64, author: s64, author_name: string, content: string, edited: s64 = 0,
		reply: s64 = 0, referenced := etf.Value.{}, nonce := "", reactions := etf.Value.{}, mentions := etf.Value.{}, everyone := false, pinned := false,
		kind := DEFAULT, attachments := etf.Value.{}, embeds := etf.Value.{}, flags := 0, thread := etf.Value.{}, webhook := false, snapshot := "", stickers := "") -> etf.Value {
	m := etf.map_builder(20,, temp);
	if stickers {
		v, err := etf.from_json(stickers,, temp);
		if err == .None && v.kind == .List etf.map_put(*m, "sticker_items", v);
	}
	if snapshot {
		v, err := etf.from_json(snapshot,, temp);
		if err == .None && v.kind == .Map {
			ref := etf.map_builder(4,, temp);
			etf.map_put(*ref, "type", etf.vint(1));
			etf.map_put(*ref, "message_id", etf.map_get(v.map, "message_id"));
			etf.map_put(*ref, "channel_id", etf.map_get(v.map, "channel_id"));
			etf.map_put(*ref, "guild_id", snow(s.guild));
			etf.map_put(*m, "message_reference", etf.vmap(etf.map_done(*ref)));
			snap := etf.map_builder(1,, temp);
			etf.map_put(*snap, "message", etf.map_get(v.map, "message"));
			snaps := NewArray(1, etf.Value,, temp);
			snaps[0] = etf.vmap(etf.map_done(*snap));
			etf.map_put(*m, "message_snapshots", etf.vlist(snaps));
		}
	}
	if webhook etf.map_put(*m, "webhook_id", snow(author));
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
	etf.map_put(*m, "author", user_value(s, author, author_name, bot = webhook));
	etf.map_put(*m, "content", etf.vstring(content));
	etf.map_put(*m, "timestamp", etf.vstring(iso(id)));
	etf.map_put(*m, "edited_timestamp", ifx edited then etf.vstring(iso(edited)) else .{});
	etf.map_put(*m, "flags", etf.vint(ifx thread.kind == .Map then flags | HAS_THREAD else flags));
	etf.map_put(*m, "attachments", ifx attachments.kind == .List then attachments else etf.vlist(.[]));
	etf.map_put(*m, "embeds", ifx embeds.kind == .List then embeds else etf.vlist(.[]));
	etf.map_put(*m, "mentions", ifx mentions.kind == .List then mentions else etf.vlist(.[]));
	etf.map_put(*m, "mention_everyone", etf.vbool(everyone));
	etf.map_put(*m, "pinned", etf.vbool(pinned));
	if nonce etf.map_put(*m, "nonce", etf.vstring(nonce));
	if reactions.kind == .List && reactions.list.count etf.map_put(*m, "reactions", reactions);
	if thread.kind == .Map etf.map_put(*m, "thread", thread);
	return etf.vmap(etf.map_done(*m));
}

MESSAGE_SELECT :: "SELECT m.id, m.channel, m.author, coalesce(m.username, u.name), m.content, coalesce(m.edited, 0), coalesce(m.reply, 0), m.everyone, m.pinned_at, m.type, m.flags, (SELECT 1 FROM channels t WHERE t.id = m.id AND t.type = 11), m.webhook , m.snapshot, m.stickers FROM messages m JOIN users u ON u.id = m.author";

// Members who can't see a new message yet count it as a mention until they read past it.
// Takes the channel, the author, whether it pings everyone, and the message.
COUNT_MENTIONS :: #string SQL
	INSERT INTO read_states(user, channel, last, mentions)
	SELECT u.id, ?, 0, 1 FROM users u WHERE u.left = 0 AND u.id != ? AND (? OR u.id IN (SELECT user FROM mentions WHERE message = ?))
	ON CONFLICT(user, channel) DO UPDATE SET mentions = mentions + 1;
SQL

SUPPRESS_EMBEDS :: 1 << 2;
SUPPRESS_NOTIFICATIONS :: 1 << 12; // @silent: no sound or push, though it still counts as a mention.
HAS_THREAD :: 1 << 5;

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
	while sqlite.step(q) == .Row array_add(*mentioned, user_value(s, sqlite.col_int(q, 0), copy_string(sqlite.col_text(q, 1),, temp)));
	sqlite.finalize(q);
	if viewer {
		list: [..]etf.Value;
		list.allocator = temp;
		r := sqlite.prepare(s.db, "SELECT emoji, count(*), max(user = ?), (SELECT animated FROM emojis e WHERE instr(emoji, ':') > 0 AND e.id = CAST(substr(emoji, instr(emoji, ':') + 1) AS INTEGER)) FROM reactions WHERE message = ? GROUP BY emoji ORDER BY min(rowid);");
		sqlite.bind_all(r, viewer, id);
		while sqlite.step(r) == .Row {
			count := sqlite.col_int(r, 1);
			details := etf.map_builder(2,, temp);
			etf.map_put(*details, "burst", etf.vint(0));
			etf.map_put(*details, "normal", etf.vint(count));
			m := etf.map_builder(6,, temp);
			etf.map_put(*m, "emoji", reaction_emoji(copy_string(sqlite.col_text(r, 0),, temp), sqlite.col_int(r, 3) != 0));
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
		copy_string(sqlite.col_text(st, 4),, temp), sqlite.col_int(st, 5), reply, referenced, nonce, reactions, etf.vlist(mentioned), sqlite.col_int(st, 7) != 0, !sqlite.col_is_null(st, 8), kind, attachments_locked(s, id), embeds_locked(s, id, (sqlite.col_int(st, 10) & SUPPRESS_EMBEDS) != 0), sqlite.col_int(st, 10),
		ifx sqlite.col_is_null(st, 11) then etf.Value.{} else channel_locked(s, id), sqlite.col_int(st, 12) != 0, copy_string(sqlite.col_text(st, 13),, temp), copy_string(sqlite.col_text(st, 14),, temp));
}

// drop_files deletes the files of the messages in set (SQL listing message IDs, which may use ?1), run
// before those messages' rows go. A forward's snapshot keeps its original's files alive, as on Discord, so
// a file goes only once its own message and every forward naming it are gone.
drop_files :: (s: *Server, set: string, arg: s64) -> bool {
	DROP :: #string SQL
		DELETE FROM attachments WHERE (message IN ({set}) OR id IN (SELECT attachment FROM snapshot_files WHERE message IN ({set})))
			AND (message IN ({set}) OR NOT EXISTS(SELECT 1 FROM messages m WHERE m.id = attachments.message))
			AND NOT EXISTS(SELECT 1 FROM snapshot_files f WHERE f.attachment = attachments.id AND f.message NOT IN ({set}));
	SQL
	return sqlite.run(s.db, replace(DROP, "{set}", set,, temp), arg)
		&& sqlite.run(s.db, tprint("DELETE FROM snapshot_files WHERE message IN (%);", set), arg);
}

// forward_snapshot freezes what a forward of source shows, as Discord's message_snapshots do: later edits
// and deletes of the original don't change it. "" if source can't be forwarded from channel. The caller
// holds db_mu.
forward_snapshot :: (s: *Server, source: s64, channel: s64) -> string {
	v := message_locked(s, source);
	if v.kind != .Map || etf.map_get(v.map, "channel_id").s != tprint("%", channel) return "";
	_, forwarded := etf.map_get(v.map, "message_snapshots");
	kind, _ := etf.map_get(v.map, "type");
	if forwarded || (kind.i != DEFAULT && kind.i != 19) return "";
	m := etf.map_builder(8,, temp);
	for key: string.["type", "content", "embeds", "attachments", "timestamp", "edited_timestamp", "flags", "mentions"] {
		f, _ := etf.map_get(v.map, key);
		etf.map_put(*m, key, ifx key == "flags" then etf.vint(f.i & ~HAS_THREAD) else f);
	}
	out := etf.map_builder(3,, temp);
	etf.map_put(*out, "channel_id", snow(channel));
	etf.map_put(*out, "message_id", snow(source));
	etf.map_put(*out, "message", etf.vmap(etf.map_done(*m)));
	sb: String_Builder;
	sb.allocator = temp;
	etf.to_json(etf.vmap(etf.map_done(*out)), *sb);
	return builder_to_string(*sb,, temp);
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

// Until roles land (Hosting 4) everyone may read, write, react, embed, attach, make invites, and in voice
// connect, speak, use voice activity, stream and play soundboard sounds.
EVERYONE_PERMISSIONS :: (1 << 0) | (1 << 6) | (1 << 9) | (1 << 10) | (1 << 11) | (1 << 14) | (1 << 15) | (1 << 16) | (1 << 18) | (1 << 20) | (1 << 21) | (1 << 25) | (1 << 26) | (1 << 35) | (1 << 38) | (1 << 42);

// Channel types, as Discord numbers them.
TEXT :: 0;
CATEGORY :: 4;
ANNOUNCEMENT :: 5; // A text channel whose messages can be published (crossposted); no followers here.
FORUM :: 15; // Takes no messages itself: each post is a thread whose starter message shares its ID.
CROSSPOSTED :: 1 << 0;
THREAD :: 11; // Public, under a text channel; one started from a message takes that message's ID.

CHANNEL_SELECT :: "SELECT c.id, c.name, c.position, c.topic, (SELECT max(id) FROM messages WHERE channel = c.id), c.type, c.parent, coalesce(c.owner, 0), CASE WHEN c.type = 11 THEN (SELECT count(*) FROM messages WHERE channel = c.id) END, c.slowmode, c.nsfw, c.archived, c.locked, c.archive_after, coalesce(c.archived_at, c.id) FROM channels c";

row_channel :: (s: *Server, st: *sqlite.Stmt, member := etf.Value.{}) -> etf.Value {
	kind := sqlite.col_int(st, 5);
	m := etf.map_builder(10,, temp);
	etf.map_put(*m, "id", snow(sqlite.col_int(st, 0)));
	etf.map_put(*m, "type", etf.vint(kind));
	etf.map_put(*m, "guild_id", snow(s.guild));
	etf.map_put(*m, "name", etf.vstring(copy_string(sqlite.col_text(st, 1),, temp)));
	etf.map_put(*m, "position", etf.vint(sqlite.col_int(st, 2)));
	texty := kind == TEXT || kind == ANNOUNCEMENT || kind == FORUM;
	if texty etf.map_put(*m, "topic", etf.vstring(copy_string(sqlite.col_text(st, 3),, temp)));
	if kind == TEXT || kind == THREAD || kind == FORUM etf.map_put(*m, "rate_limit_per_user", etf.vint(sqlite.col_int(st, 9)));
	if texty etf.map_put(*m, "nsfw", etf.vbool(sqlite.col_int(st, 10) != 0));
	if kind == FORUM {
		etf.map_put(*m, "available_tags", etf.vlist(.[]));
		etf.map_put(*m, "default_reaction_emoji", .{});
		etf.map_put(*m, "default_sort_order", .{});
		etf.map_put(*m, "default_forum_layout", etf.vint(0));
		etf.map_put(*m, "default_thread_rate_limit_per_user", etf.vint(0));
	}
	if kind == VOICE { etf.map_put(*m, "bitrate", etf.vint(64000)); etf.map_put(*m, "user_limit", etf.vint(0)); }
	if !sqlite.col_is_null(st, 4) etf.map_put(*m, "last_message_id", snow(sqlite.col_int(st, 4)));
	etf.map_put(*m, "parent_id", ifx sqlite.col_is_null(st, 6) then etf.Value.{} else snow(sqlite.col_int(st, 6)));
	if kind == THREAD {
		count := sqlite.col_int(st, 8);
		etf.map_put(*m, "owner_id", snow(sqlite.col_int(st, 7)));
		etf.map_put(*m, "message_count", etf.vint(count));
		etf.map_put(*m, "total_message_sent", etf.vint(count));
		md := etf.map_builder(5,, temp);
		etf.map_put(*md, "archived", etf.vbool(sqlite.col_int(st, 11) != 0));
		etf.map_put(*md, "locked", etf.vbool(sqlite.col_int(st, 12) != 0));
		etf.map_put(*md, "auto_archive_duration", etf.vint(sqlite.col_int(st, 13)));
		etf.map_put(*md, "archive_timestamp", etf.vstring(iso(sqlite.col_int(st, 14))));
		etf.map_put(*md, "create_timestamp", etf.vstring(iso(sqlite.col_int(st, 0))));
		etf.map_put(*m, "thread_metadata", etf.vmap(etf.map_done(*md)));
		if member.kind != .Nil etf.map_put(*m, "member", member);
	}
	return etf.vmap(etf.map_done(*m));
}

// A thread's `member` entry for user, who has joined it by starting it or posting in it; null if not.
// The caller holds db_mu.
thread_member_locked :: (s: *Server, thread: s64, user: s64) -> etf.Value {
	st := sqlite.prepare(s.db, "SELECT 1 FROM channels WHERE id = ?1 AND (owner = ?2 OR EXISTS (SELECT 1 FROM messages WHERE channel = ?1 AND author = ?2));");
	defer sqlite.finalize(st);
	sqlite.bind_all(st, thread, user);
	if sqlite.step(st) != .Row return .{};
	m := etf.map_builder(4,, temp);
	etf.map_put(*m, "id", snow(thread));
	etf.map_put(*m, "user_id", snow(user));
	etf.map_put(*m, "join_timestamp", etf.vstring(iso(thread)));
	etf.map_put(*m, "flags", etf.vint(0));
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

// Who started a thread, or 0. The caller holds db_mu.
thread_owner_locked :: (s: *Server, id: s64) -> s64 {
	st := sqlite.prepare(s.db, "SELECT coalesce(owner, 0) FROM channels WHERE id = ?;");
	defer sqlite.finalize(st);
	sqlite.bind(st, 1, id);
	if sqlite.step(st) != .Row return 0;
	return sqlite.col_int(st, 0);
}

// A channel's type, or -1 if there is no such channel. The caller holds db_mu.
channel_type_locked :: (s: *Server, id: s64) -> int {
	st := sqlite.prepare(s.db, "SELECT type FROM channels WHERE id = ?;");
	defer sqlite.finalize(st);
	sqlite.bind(st, 1, id);
	if sqlite.step(st) != .Row return -1;
	return sqlite.col_int(st, 0);
}

// Whether a channel is an archived thread, whose messages take no edits, pins or reactions until it's
// reopened. The caller holds db_mu.
archived_locked :: (s: *Server, id: s64) -> bool {
	st := sqlite.prepare(s.db, "SELECT 1 FROM channels WHERE id = ? AND archived = 1;");
	defer sqlite.finalize(st);
	sqlite.bind(st, 1, id);
	return sqlite.step(st) == .Row;
}

// archive_idle also starts events at their start time and completes them at their end, as Discord does
// for events held Somewhere Else, the only kind here.
// archive_idle archives threads with no activity (start, message or unarchive) for their
// auto_archive_duration, and tells everyone. Gateway heartbeats and the thread browser run it, at most
// once a minute, so no timer thread is needed.
archive_idle :: (s: *Server) {
	ms := now_ms(s);
	next := atomic_read(*s.next_sweep);
	if ms < next || !compare_and_swap(*s.next_sweep, next, ms + 60 * 1000) return;
	threads, events: [..]etf.Value;
	threads.allocator, events.allocator = temp, temp;
	{
		locks.guard(*s.db_mu);
		ids: [..]s64;
		ids.allocator = temp;
		st := sqlite.prepare(s.db, tprint("SELECT id FROM channels c WHERE type = % AND archived = 0 AND max(id, coalesce(archived_at, 0), coalesce((SELECT max(id) FROM messages WHERE channel = c.id), 0)) < ?1 - ((archive_after * 60000) << 22);", THREAD));
		sqlite.bind_all(st, ms << 22);
		while sqlite.step(st) == .Row array_add(*ids, sqlite.col_int(st, 0));
		sqlite.finalize(st);
		for ids if sqlite.run(s.db, "UPDATE channels SET archived = 1, archived_at = ? WHERE id = ?;", ms << 22, it) array_add(*threads, channel_locked(s, it));
		ids.count = 0;
		unix := ms + DISCORD_EPOCH_MS;
		// Events start on time. Those Somewhere Else end on time; one in a voice channel ends when everyone has
		// left it (end_voice_events), or here if it is still empty a quarter of an hour after its start.
		st = sqlite.prepare(s.db, tprint("SELECT id, coalesce(channel, 0), status FROM events WHERE (status = % AND start <= ?1) OR (status = % AND ((channel IS NULL AND end <= ?1) OR (channel IS NOT NULL AND start <= ?1 - 900000)));", EVENT_SCHEDULED, EVENT_ACTIVE));
		sqlite.bind_all(st, unix);
		next: [..]int;
		next.allocator = temp;
		while sqlite.step(st) == .Row {
			channel, status := sqlite.col_int(st, 1), sqlite.col_int(st, 2);
			occupied := false;
			if status == EVENT_ACTIVE && channel {
				locks.guard(*s.voice_mu);
				for s.voice_states if it.channel == channel occupied = true;
			}
			if occupied continue;
			array_add(*ids, sqlite.col_int(st, 0));
			array_add(*next, ifx status == EVENT_ACTIVE then EVENT_COMPLETED else EVENT_ACTIVE);
		}
		sqlite.finalize(st);
		for ids {
			ok := sqlite.run(s.db, "UPDATE events SET status = CASE WHEN channel IS NULL AND end <= ?1 THEN ?2 ELSE ?3 END WHERE id = ?4;", unix, EVENT_COMPLETED, next[it_index], it);
			if ok array_add(*events, event_locked(s, it));
		}
	}
	for threads broadcast(s, "THREAD_UPDATE", it);
	for events broadcast(s, "GUILD_SCHEDULED_EVENT_UPDATE", it);
}

// GET /api/v9/channels/{id}/threads/search?archived=true&limit=&offset=: a text channel's archived threads,
// latest activity first, as the thread browser's Archived tab asks for them.
thread_search :: (c: *Conn, user: s64, parent: s64, query: string) -> bool {
	s := c.server;
	archive_idle(s);
	limit, offset := 25, 0;
	for split(query, "&",, temp) {
		kv := split(it, "=",, temp);
		if kv.count != 2 continue;
		if kv[0] == "limit" limit = clamp(string_to_int(kv[1]), 1, 25);
		if kv[0] == "offset" offset = clamp(string_to_int(kv[1]), 0, 10000);
	}
	threads, members, firsts: [..]etf.Value;
	threads.allocator, members.allocator, firsts.allocator = temp, temp, temp;
	total := 0;
	{
		locks.guard(*s.db_mu);
		forum := channel_type_locked(s, parent) == FORUM;
		if !forum && !text_like_locked(s, parent) return json_error(c, 404, 10003, "Unknown Channel");
		st := sqlite.prepare(s.db, tprint("SELECT count(*) FROM channels WHERE parent = ? AND type = % AND archived = 1;", THREAD));
		sqlite.bind_all(st, parent);
		if sqlite.step(st) == .Row total = sqlite.col_int(st, 0);
		sqlite.finalize(st);
		st = sqlite.prepare(s.db, tprint("% WHERE c.parent = ? AND c.type = % AND c.archived = 1 ORDER BY coalesce((SELECT max(id) FROM messages WHERE channel = c.id), c.id) DESC LIMIT ? OFFSET ?;", CHANNEL_SELECT, THREAD));
		sqlite.bind_all(st, parent, limit, offset);
		while sqlite.step(st) == .Row {
			member := thread_member_locked(s, sqlite.col_int(st, 0), user);
			array_add(*threads, row_channel(s, st));
			if member.kind != .Nil array_add(*members, member);
			// A forum post's preview is its starter message, which shares its ID.
			first := ifx forum then message_locked(s, sqlite.col_int(st, 0)) else etf.Value.{};
			if first.kind == .Map array_add(*firsts, first);
		}
		sqlite.finalize(st);
	}
	m := etf.map_builder(5,, temp);
	etf.map_put(*m, "threads", etf.vlist(threads));
	etf.map_put(*m, "members", etf.vlist(members));
	etf.map_put(*m, "first_messages", etf.vlist(firsts));
	etf.map_put(*m, "has_more", etf.vbool(offset + threads.count < total));
	etf.map_put(*m, "total_results", etf.vint(total));
	return json_reply(c, 200, etf.vmap(etf.map_done(*m)));
}

ready_value ::(s: *Server, user: s64, name: string, session: [16]u8) -> etf.Value {
	locks.guard(*s.db_mu);
	channels, threads: [..]etf.Value;
	channels.allocator, threads.allocator = temp, temp;
	st := sqlite.prepare(s.db, tprint("% ORDER BY c.position, c.id;", CHANNEL_SELECT));
	while sqlite.step(st) == .Row {
		if sqlite.col_int(st, 5) != THREAD { array_add(*channels, row_channel(s, st)); continue; }
		if sqlite.col_int(st, 11) continue; // Archived threads come from /threads/search, as on Discord.
		array_add(*threads, row_channel(s, st, thread_member_locked(s, sqlite.col_int(st, 0), user)));
	}
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

	g := etf.map_builder(8,, temp);
	etf.map_put(*g, "id", snow(s.guild));
	etf.map_put(*g, "name", etf.vstring(copy_string(s.name,, temp)));
	etf.map_put(*g, "icon", guild_icon_locked(s));
	etf.map_put(*g, "emojis", emoji_list_locked(s));
	etf.map_put(*g, "soundboard_sounds", sound_list_locked(s));
	etf.map_put(*g, "stickers", sticker_list_locked(s));
	etf.map_put(*g, "member_count", etf.vint(members));
	guild_fields_locked(s, *g);
	owner := owner_id(s);
	if owner etf.map_put(*g, "owner_id", snow(owner));
	etf.map_put(*g, "channels", etf.vlist(channels));
	etf.map_put(*g, "threads", etf.vlist(threads));
	etf.map_put(*g, "guild_scheduled_events", events_locked(s));
	etf.map_put(*g, "roles", etf.vlist(roles));
	etf.map_put(*g, "voice_states", voice_states_value(s));
	guilds :=NewArray(1, etf.Value,, temp);
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
	etf.map_put(*d, "user", user_value(s, user, name));
	etf.map_put(*d, "guilds", etf.vlist(guilds));
	etf.map_put(*d, "session_id", etf.vstring(hex(session,, temp)));
	return etf.vmap(etf.map_done(*d));
}

STATUSES :: string.["online", "idle", "dnd", "invisible"];
INVISIBLE :: 3;

MAX_ACTIVITIES :: 4;
Activity :: struct { type: int; name: string; state: string; } // Strings from the default allocator.
Member_Activities :: struct { user: s64; list: [MAX_ACTIVITIES]Activity; count: int; }

// set_presence gives a member's gateways the status a presence names, since on Discord the status is
// the account's, not a session's; c is the gateway it came from. A presence without a known status
// gives c the one the member already has. Its activities (a custom status, "Playing X") replace the
// member's, except an Identify's empty list: fastcord identifies with none and sends them in an op 3
// after READY, so a reconnect mustn't wipe them. True if the member list changed. The caller holds
// server.mu.
set_presence_locked :: (s: *Server, c: *Conn, presence: etf.Value, identify := false) -> bool {
	v, acts: etf.Value;
	if presence.kind == .Map {
		v, _ = etf.map_get(presence.map, "status");
		acts, _ = etf.map_get(presence.map, "activities");
	}
	changed := false;
	if acts.kind == .List && !(identify && !acts.list.count) {
		parsed: [MAX_ACTIVITIES]Activity;
		n := 0;
		for a: acts.list {
			if n == MAX_ACTIVITIES break;
			if a.kind != .Map continue;
			type, _ := etf.map_get(a.map, "type");
			name, _ := etf.map_get(a.map, "name");
			state, _ := etf.map_get(a.map, "state");
			ok_text :: (v: etf.Value) -> bool { return v.kind == .Nil || (v.kind == .String && v.s.count <= 128 && text_ok(v.s)); }
			if type.kind != .Int || type.i < 0 || type.i > 5 || name.kind != .String || !ok_text(name) || !ok_text(state) continue;
			parsed[n] = .{type.i, name.s, ifx state.kind == .String then state.s else ""};
			n += 1;
		}
		m: *Member_Activities;
		for * s.activities if it.user == c.user m = it;
		if !m {
			m = array_add(*s.activities);
			m.user = c.user;
		}
		changed = set_activities(m, array_view(parsed, 0, n));
	}
	found, status := false, 0;
	if v.kind == .String found, status = array_find(STATUSES, v.s);
	if !found {
		c.status = 0;
		for s.conns if it != c && it.ws && it.user == c.user { c.status = it.status; break; }
		return changed;
	}
	for s.conns if it.ws && it.user == c.user && it.status != status {
		it.status = status;
		changed = true;
	}
	return changed;
}

// set_activities replaces m's list with copies of list; true if it differs.
set_activities :: (m: *Member_Activities, list: []Activity) -> bool {
	same := m.count == list.count;
	for list if same && (it.type != m.list[it_index].type || it.name != m.list[it_index].name || it.state != m.list[it_index].state) same = false;
	if same return false;
	for 0..m.count - 1 { free(m.list[it].name,, context.default_allocator); free(m.list[it].state,, context.default_allocator); }
	for list m.list[it_index] = .{it.type, copy_string(it.name,, context.default_allocator), copy_string(it.state,, context.default_allocator)};
	m.count = list.count;
	return true;
}

// member_list_value is the whole member list as one GUILD_MEMBER_LIST_UPDATE SYNC: Online, then Offline,
// each by name. Online means an identified gateway is open. Takes server.mu, then db_mu.
// @Speed: Past a few hundred members, sync only the ranges a client subscribed to and send INSERT/DELETE.
member_list_value :: (s: *Server) -> etf.Value {
	online: [..]s64;
	statuses: [..]int;
	activities: [..]etf.Value;
	online.allocator, statuses.allocator, activities.allocator = temp, temp, temp;
	locks.lock(*s.mu);
	for c: s.conns if c.ws && c.user && c.status != INVISIBLE && !array_find(online, c.user) {
		array_add(*online, c.user);
		array_add(*statuses, c.status);
		list: [..]etf.Value;
		list.allocator = temp;
		for m: s.activities if m.user == c.user for a: array_view(m.list, 0, m.count) {
			v := etf.map_builder(3,, temp);
			etf.map_put(*v, "type", etf.vint(a.type));
			etf.map_put(*v, "name", etf.vstring(copy_string(a.name,, temp)));
			if a.state etf.map_put(*v, "state", etf.vstring(copy_string(a.state,, temp)));
			array_add(*list, etf.vmap(etf.map_done(*v)));
		}
		array_add(*activities, etf.vlist(list));
	}
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
			p := etf.map_builder(2,, temp);
			found, at := array_find(`online, it.id);
			etf.map_put(*p, "status", etf.vstring(ifx found then STATUSES[`statuses[at]] else "offline"));
			if found etf.map_put(*p, "activities", `activities[at]);
			m := etf.map_builder(2,, temp);
			etf.map_put(*m, "user", user_value(`s, it.id, it.name));
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
			// A voice gateway's frames are JSON text, but for DAVE's binary ones, which start with a zero byte.
			if !stop && http.ws_send(c.out_ws, ifx c.text && it[0] == #char "{" then http.Ws_Message_Type.Text else .Binary, it) != .None {
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
	user, name := session_user(c, token);
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
	if ok && parts.count == 2 && parts[1] == "attachments" && req.method == "POST" return request_uploads(c, req, user, channel);
	// Opening the pins popout acks them; unread pins aren't tracked, so there is nothing to store.
	if ok && parts.count == 3 && parts[1] == "pins" && parts[2] == "ack" return respond(c, 204, json = false);
	if ok && parts.count == 2 && parts[1] == "threads" && req.method == "POST" return create_thread(c, req, user, channel, 0);
	if ok && parts.count == 2 && parts[1] == "webhooks" return channel_webhooks(c, req, user, channel);
	if ok && parts.count == 3 && parts[1] == "threads" && parts[2] == "search" && req.method == "GET" return thread_search(c, user, channel, query);
	if ok && parts.count == 2 && parts[1] == "post-data" && req.method == "POST" return post_data(c, req, channel);
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
		if parts[3] == "reactions" return reaction(c, req, user, channel, message, array_view(parts, 4), query);
		if parts[3] == "ack" && parts.count == 4 && req.method == "POST" return ack(c, req, user, channel, message);
		if parts[3] == "threads" && parts.count == 4 && req.method == "POST" return create_thread(c, req, user, channel, message);
		if parts[3] == "crosspost" && parts.count == 4 && req.method == "POST" return crosspost(c, user, channel, message);
		return json_error(c, 404, 0, "404: Not Found");
	}
	{
		locks.guard(*s.db_mu);
		st := sqlite.prepare(s.db, tprint("SELECT 1 FROM channels WHERE id = ? AND type IN (%, %, %, %);", TEXT, THREAD, VOICE, ANNOUNCEMENT));
		sqlite.bind(st, 1, channel);
		ok = sqlite.step(st) == .Row;
		sqlite.finalize(st);
	}
	if !ok return json_error(c, 404, 10003, "Unknown Channel");
	if typing {
		member := etf.map_builder(1,, temp);
		etf.map_put(*member, "user", user_value(s, user, name));
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
		atts, _ := etf.map_get(v.map, "attachments");
		sticker_ids, _ := etf.map_get(v.map, "sticker_ids");
		has_files := (atts.kind == .List && atts.list.count > 0) || (sticker_ids.kind == .List && sticker_ids.list.count > 0);
		flags_v, _ := etf.map_get(v.map, "flags");
		if flags_v.kind != .Int && flags_v.kind != .Nil return json_error(c, 400, 50035, "Invalid Form Body");
		// A send may set only these, as on Discord; any other bit is dropped.
		flags := flags_v.i & (SUPPRESS_EMBEDS | SUPPRESS_NOTIFICATIONS);
		if atts.kind == .List && atts.list.count > MAX_UPLOADS return json_error(c, 400, 50035, "Invalid Form Body");
		ref, _ := etf.map_get(v.map, "message_reference");
		ref_id, ref_channel, ref_type: etf.Value;
		if ref.kind == .Map {
			ref_id, _ = etf.map_get(ref.map, "message_id");
			ref_channel, _ = etf.map_get(ref.map, "channel_id");
			ref_type, _ = etf.map_get(ref.map, "type");
		}
		// A forward (type 1) carries the original in its snapshot, and nothing of its own.
		forward := ref_type.kind == .Int && ref_type.i == 1;
		if forward && (has_files || (content.kind == .String && content.s) || ref_id.kind != .String || ref_channel.kind != .String) return json_error(c, 400, 50035, "Invalid Form Body");
		if content.kind == .Nil && (has_files || forward) content = etf.vstring("");
		if content.kind != .String || (!trim(content.s) && !has_files && !forward) return json_error(c, 400, 50006, "Cannot send an empty message");
		if !text_ok(content.s, lines = true) return json_error(c, 400, 50035, "Invalid Form Body");
		if utf16_units(content.s) > MAX_CONTENT return content_too_long(c);
		if nonce.kind == .String && nonce.s.count > 25 return json_error(c, 400, 50035, "Invalid Form Body");
		reply: s64;
		if !forward {
			if ref_id.kind == .String reply = string_to_int(ref_id.s, T = s64);
			else if ref_id.kind == .Int reply = ref_id.i;
		}
		snapshot := "";
		source: s64;
		id := snowflake(s);
		nonce_s := ifx nonce.kind == .String then nonce.s else "";
		referenced, m, thread: etf.Value;
		reopened := false;
		{
			locks.guard(*s.db_mu);
			// A resend whose first reply was lost (the client retries on network errors and 5xx) gets the
			// message it already made, as Discord's enforce_nonce does, rather than posting it twice.
			if nonce_s {
				st := sqlite.prepare(s.db, "SELECT id FROM messages WHERE author = ? AND nonce = ? AND channel = ? AND id > ?;");
				sqlite.bind_all(st, user, nonce_s, channel, id - (NONCE_WINDOW_MS << 22));
				sent := ifx sqlite.step(st) == .Row then sqlite.col_int(st, 0) else 0;
				sqlite.finalize(st);
				if sent {
					m = message_locked(s, sent, nested = false, nonce = nonce_s);
					etf.to_json(m, *sb);
					return respond(c, 200, builder_to_string(*sb,, temp));
				}
			}
			if reply {
				referenced = message_locked(s, reply);
				if referenced.kind != .Map || etf.map_get(referenced.map, "channel_id").s != tprint("%", channel) {
					return json_error(c, 400, 50035, "Invalid Form Body");
				}
			}
			if forward {
				source = string_to_int(ref_id.s, T = s64);
				snapshot = forward_snapshot(s, source, string_to_int(ref_channel.s, T = s64));
				if !snapshot return json_error(c, 400, 50035, "Invalid Form Body");
			}
			stickers, stickers_ok := sticker_items_locked(s, sticker_ids);
			if !stickers_ok return json_error(c, 400, 50035, "Invalid Form Body");
			// A message reopens an archived thread, unless it's locked: then only the owner may post.
			st := sqlite.prepare(s.db, tprint("SELECT archived, locked FROM channels WHERE id = ? AND type = %;", THREAD));
			sqlite.bind_all(st, channel);
			if sqlite.step(st) == .Row && sqlite.col_int(st, 0) {
				if sqlite.col_int(st, 1) && owner_id(s) != user { sqlite.finalize(st); return json_error(c, 400, 50083, "Thread is archived"); }
				reopened = true;
			}
			sqlite.finalize(st);
			// Slowmode spaces each member's messages; the owner is exempt, as MANAGE_MESSAGES holders are on Discord.
			if owner_id(s) != user {
				st := sqlite.prepare(s.db, "SELECT slowmode, (SELECT max(id) FROM messages WHERE channel = ?1 AND author = ?2 AND type = 0) FROM channels WHERE id = ?1;");
				sqlite.bind_all(st, channel, user);
				wait_ms := 0;
				if sqlite.step(st) == .Row && sqlite.col_int(st, 0) > 0 && !sqlite.col_is_null(st, 1) {
					wait_ms = sqlite.col_int(st, 0) * 1000 - ((id >> 22) - (sqlite.col_int(st, 1) >> 22));
				}
				sqlite.finalize(st);
				if wait_ms > 0 return respond(c, 429, tprint("{\"message\": \"This action cannot be performed due to slowmode rate limit.\", \"code\": 20016, \"retry_after\": %, \"global\": false}", formatFloat(wait_ms / 1000.0, trailing_width = 3)));
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
				&& sqlite.run(s.db, "INSERT INTO messages(id, channel, author, content, reply, everyone, nonce, flags, snapshot, stickers) VALUES(?, ?, ?, coalesce(?, ''), ?, ?, nullif(?, ''), ?, nullif(?, ''), nullif(?, ''));", id, channel, user, content.s, reply, cast(int) everyone, nonce_s, flags, snapshot, stickers);
			if forward && ok ok = sqlite.run(s.db, "INSERT INTO snapshot_files(message, attachment) SELECT ?, id FROM attachments WHERE message = ?;", id, source);
			for ids if ok ok = sqlite.run(s.db, "INSERT OR IGNORE INTO mentions(message, user) SELECT ?, id FROM users WHERE id = ? AND left = 0;", id, it);
			bad_file := false;
			if atts.kind == .List for a: atts.list {
				if !ok break;
				field :: (name: string) -> string #expand {
					f, _ := etf.map_get(`a.map, name);
					return ifx f.kind == .String then f.s else "";
				}
				if a.kind != .Map { bad_file = true; break; }
				spoiler, _ := etf.map_get(a.map, "is_spoiler");
				name := field("filename");
				description := field("description");
				if !name || name.count > 255 || !text_ok(name) || contains(name, "/") || contains(name, "\\") || description.count > 1024 || !text_ok(description) { bad_file = true; break; }
				if spoiler.kind == .Bool && spoiler.b && !begins_with(name, "SPOILER_") name = tprint("SPOILER_%", name);
				key: [8]u8;
				crypto.random_bytes(key);
				ok = sqlite.run(s.db, "INSERT INTO attachments(id, message, key, filename, content_type, size, width, height, description, data) SELECT ?, ?, ?, ?, content_type, size, width, height, coalesce(?, ''), data FROM uploads WHERE token = ? AND user = ? AND channel = ? AND data IS NOT NULL;",
					snowflake(s), id, hex(key,, temp), name, description, field("uploaded_filename"), user, channel);
				if ok && sqlite.changes(s.db) != 1 { bad_file = true; break; }
				ok = ok && sqlite.run(s.db, "DELETE FROM uploads WHERE token = ?;", field("uploaded_filename"));
			}
			if bad_file {
				sqlite.exec(s.db, "ROLLBACK;");
				return json_error(c, 400, 50035, "Invalid Form Body");
			}
			ok = ok && sqlite.run(s.db, COUNT_MENTIONS, channel, user, cast(int) everyone, id) && sqlite.exec(s.db, "COMMIT;");
			if !ok {
				sqlite.exec(s.db, "ROLLBACK;");
				return json_error(c, 500, 0, "500: Internal Server Error");
			}
			m = message_locked(s, id, nested = false, nonce = nonce_s);
			if reopened && sqlite.run(s.db, "UPDATE channels SET archived = 0, archived_at = ? WHERE id = ?;", id, channel) thread = channel_locked(s, channel);
		}
		etf.to_json(m, *sb);
		if thread.kind == .Map broadcast(s, "THREAD_UPDATE", thread);
		broadcast(s, "MESSAGE_CREATE", m);
		if !(flags & SUPPRESS_EMBEDS) queue_unfurl(s, id, content.s);
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
	archived := false;
	{
		locks.guard(*s.db_mu);
		st := sqlite.prepare(s.db, "SELECT author, type FROM messages WHERE id = ? AND channel = ?;");
		sqlite.bind_all(st, message, channel);
		if sqlite.step(st) == .Row author, kind = sqlite.col_int(st, 0), sqlite.col_int(st, 1);
		sqlite.finalize(st);
		owner = owner_id(s);
		archived = archived_locked(s, channel);
	}
	if !author return json_error(c, 404, 10008, "Unknown Message");
	if archived return json_error(c, 400, 50083, "Thread is archived");
	if req.method == "PATCH" && kind != DEFAULT return json_error(c, 400, 50021, "Cannot execute action on a system message");
	v: etf.Value;
	if req.method == "PATCH" {
		body, err := etf.from_json(cast(string) req.body,, temp);
		if err != .None || body.kind != .Map return json_error(c, 400, 50035, "Invalid Form Body");
		v = body;
	}
	flags, has_flags := etf.map_get(v.map, "flags");
	_, has_content := etf.map_get(v.map, "content");
	if req.method == "PATCH" && has_flags && !has_content {
		// Remove Embeds: the author, or as with MANAGE_MESSAGES the owner, sets SUPPRESS_EMBEDS, the one flag
		// a client may change.
		if author != user && user != owner return json_error(c, 403, 50013, "Missing Permissions");
		if flags.kind != .Int return json_error(c, 400, 50035, "Invalid Form Body");
		suppress := (flags.i & SUPPRESS_EMBEDS) != 0;
		m, content: etf.Value;
		{
			locks.guard(*s.db_mu);
			ok := sqlite.run(s.db, tprint("UPDATE messages SET flags = (flags & ~%) | ? WHERE id = ?;", SUPPRESS_EMBEDS), ifx suppress then SUPPRESS_EMBEDS else 0, message)
				&& (!suppress || sqlite.run(s.db, "DELETE FROM embeds WHERE message = ? AND rich IS NULL;", message));
			if !ok return json_error(c, 500, 0, "500: Internal Server Error");
			m = message_locked(s, message, nested = false);
			content, _ = etf.map_get(m.map, "content");
		}
		if !suppress queue_unfurl(s, message, content.s);
		sb: String_Builder;
		sb.allocator = temp;
		etf.to_json(m, *sb);
		broadcast(s, "MESSAGE_UPDATE", m);
		return respond(c, 200, builder_to_string(*sb,, temp));
	}
	if author != user {
		if req.method == "PATCH" return json_error(c, 403, 50005, "Cannot edit a message authored by another user");
		if user != owner return json_error(c, 403, 50013, "Missing Permissions");
	}

	if req.method == "PATCH" {
		content, _ := etf.map_get(v.map, "content");
		if content.kind != .String || !trim(content.s) return json_error(c, 400, 50006, "Cannot send an empty message");
		if !text_ok(content.s, lines = true) return json_error(c, 400, 50035, "Invalid Form Body");
		if utf16_units(content.s) > MAX_CONTENT return content_too_long(c);
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
			// Previews of links the edit removed go now; the worker refreshes the rest.
			links: [MAX_LINKS]string;
			for link_urls(content.s) links[it_index] = it;
			ok = ok && sqlite.run(s.db, "DELETE FROM embeds WHERE message = ? AND rich IS NULL AND url NOT IN (coalesce(?, ''), coalesce(?, ''), coalesce(?, ''));", message, links[0], links[1], links[2]);
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
		queue_unfurl(s, message, content.s);
		return respond(c, 200, builder_to_string(*sb,, temp));
	} else if req.method == "DELETE" {
		{
			locks.guard(*s.db_mu);
			if !sqlite.run(s.db, "DELETE FROM messages WHERE id = ?;", message) return json_error(c, 500, 0, "500: Internal Server Error");
			sqlite.run(s.db, "DELETE FROM reactions WHERE message = ?;", message);
			sqlite.run(s.db, "DELETE FROM mentions WHERE message = ?;", message);
			drop_files(s, "?1", message);
			sqlite.run(s.db, "DELETE FROM embeds WHERE message = ?;", message);
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

// POST /api/v9/guilds/{id}/channels {name, type, parent_id?}: the owner adds a text or voice channel, or a
// category, at the end.
create_channel :: (c: *Conn, req: http.Request) -> bool {
	s := c.server;
	token, _ := http.header_get(req.headers, "authorization");
	user := session_user(c, token);
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
	// Categories and voice channels keep the name as typed; text channels get Discord's lowercase-dashed form.
	name := ifx raw.kind != .String then "" else ifx kind == CATEGORY || kind == VOICE then trim(raw.s) else channel_name(raw.s);
	known := kind == TEXT || kind == VOICE || kind == CATEGORY || kind == ANNOUNCEMENT || kind == FORUM;
	if !name || name.count > 100 || !text_ok(name) || !known || (has_parent && kind == CATEGORY) return json_error(c, 400, 50035, "Invalid Form Body");
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

// Whether a channel is a text or announcement channel, which take threads and webhooks.
// The caller holds db_mu.
text_like_locked :: (s: *Server, id: s64) -> bool {
	kind := channel_type_locked(s, id);
	return kind == TEXT || kind == ANNOUNCEMENT;
}

// POST /channels/{id}/threads {name, type: 11} and POST /channels/{id}/messages/{message}/threads {name}:
// any member starts a public thread under a text channel. One started from a message takes its ID, so a
// message has at most one, and the message then carries it as `thread`. In a forum, the post's
// `message` {content} becomes its starter message, with the thread's ID, as on Discord.
create_thread :: (c: *Conn, req: http.Request, user: s64, parent: s64, message: s64) -> bool {
	s := c.server;
	v, err := etf.from_json(cast(string) req.body,, temp);
	if err != .None || v.kind != .Map return json_error(c, 400, 50035, "Invalid Form Body");
	raw, _ := etf.map_get(v.map, "name");
	kind_v, has_kind := etf.map_get(v.map, "type");
	post_v, has_post := etf.map_get(v.map, "message");
	name := ifx raw.kind == .String then trim(raw.s) else "";
	if !name || name.count > 100 || !text_ok(name) || (has_kind && !(kind_v.kind == .Int && kind_v.i == THREAD)) return json_error(c, 400, 50035, "Invalid Form Body");
	content: etf.Value;
	if post_v.kind == .Map content, _ = etf.map_get(post_v.map, "content");
	if has_post && (content.kind != .String || !trim(content.s) || !text_ok(content.s, lines = true)) return json_error(c, 400, 50006, "Cannot send an empty message");
	if has_post && utf16_units(content.s) > MAX_CONTENT return content_too_long(c);
	thread, starter, member, post: etf.Value;
	{
		locks.guard(*s.db_mu);
		forum := channel_type_locked(s, parent) == FORUM;
		if (forum && message) || (!forum && !text_like_locked(s, parent)) return json_error(c, 404, 10003, "Unknown Channel");
		if forum != has_post return json_error(c, 400, 50035, "Invalid Form Body");
		id := message;
		if message {
			st := sqlite.prepare(s.db, "SELECT (SELECT 1 FROM messages WHERE id = ?1 AND channel = ?2), (SELECT 1 FROM channels WHERE id = ?1);");
			sqlite.bind_all(st, message, parent);
			sqlite.step(st);
			found, taken := !sqlite.col_is_null(st, 0), !sqlite.col_is_null(st, 1);
			sqlite.finalize(st);
			if !found return json_error(c, 404, 10008, "Unknown Message");
			if taken return json_error(c, 400, 160004, "A thread has already been created for this message");
		} else {
			id = snowflake(s);
		}
		if !sqlite.run(s.db, "INSERT INTO channels(id, name, position, type, parent, owner) VALUES(?, ?, 0, ?, ?, ?);", id, name, THREAD, parent, user) return json_error(c, 500, 0, "500: Internal Server Error");
		if forum {
			everyone := (contains(content.s, "@everyone") || contains(content.s, "@here")) && owner_id(s) == user;
			ok := sqlite.run(s.db, "INSERT INTO messages(id, channel, author, content, everyone) VALUES(?1, ?1, ?, ?, ?);", id, user, content.s, cast(int) everyone);
			for mention_ids(content.s) if ok ok = sqlite.run(s.db, "INSERT OR IGNORE INTO mentions(message, user) SELECT ?, id FROM users WHERE id = ? AND left = 0;", id, it);
			if !ok || !sqlite.run(s.db, COUNT_MENTIONS, id, user, cast(int) everyone, id) return json_error(c, 500, 0, "500: Internal Server Error");
			post = message_locked(s, id, nested = false);
		}
		thread = channel_locked(s, id);
		member = thread_member_locked(s, id, user);
		if message starter = message_locked(s, message);
	}
	broadcast(s, "THREAD_CREATE", thread);
	if message broadcast(s, "MESSAGE_UPDATE", starter);
	if post.kind == .Map broadcast(s, "MESSAGE_CREATE", post);
	// The starter's own copy says it has joined, as Discord's reply does, and carries a post's message.
	m := etf.map_builder(thread.map.count + 2,, temp);
	for thread.map etf.map_put(*m, it.key.s, it.value);
	etf.map_put(*m, "member", member);
	if post.kind == .Map etf.map_put(*m, "message", post);
	return json_reply(c, 201, etf.vmap(etf.map_done(*m)));
}

// POST /channels/{forum}/post-data {thread_ids}: up to 10 posts' starter messages, for the forum's cards,
// as {threads: {"<id>": {first_message, owner}}}.
post_data :: (c: *Conn, req: http.Request, forum: s64) -> bool {
	s := c.server;
	v, err := etf.from_json(cast(string) req.body,, temp);
	ids: etf.Value;
	if err == .None && v.kind == .Map ids, _ = etf.map_get(v.map, "thread_ids");
	if ids.kind != .List || ids.list.count > 10 return json_error(c, 400, 50035, "Invalid Form Body");
	out := etf.map_builder(ids.list.count,, temp);
	{
		locks.guard(*s.db_mu);
		if channel_type_locked(s, forum) != FORUM return json_error(c, 404, 10003, "Unknown Channel");
		for ids.list {
			id, ok := string_to_int(ifx it.kind == .String then it.s else "", T = s64);
			st := sqlite.prepare(s.db, tprint("SELECT 1 FROM channels WHERE id = ? AND parent = ? AND type = %;", THREAD));
			sqlite.bind_all(st, id, forum);
			found := ok && sqlite.step(st) == .Row;
			sqlite.finalize(st);
			if !found continue;
			first := message_locked(s, id, nested = false);
			p := etf.map_builder(2,, temp);
			etf.map_put(*p, "first_message", first);
			etf.map_put(*p, "owner", .{});
			etf.map_put(*out, tprint("%", id), etf.vmap(etf.map_done(*p)));
		}
	}
	m := etf.map_builder(1,, temp);
	etf.map_put(*m, "threads", etf.vmap(etf.map_done(*out)));
	return json_reply(c, 200, etf.vmap(etf.map_done(*m)));
}

// POST /channels/{id}/messages/{id}/crosspost: Publish, in an announcement channel, by the author or the
// owner. With no other servers to follow it, publishing only marks the message, once (40033 after).
crosspost :: (c: *Conn, user: s64, channel: s64, message: s64) -> bool {
	s := c.server;
	m: etf.Value;
	{
		locks.guard(*s.db_mu);
		if channel_type_locked(s, channel) != ANNOUNCEMENT return json_error(c, 404, 10003, "Unknown Channel");
		st := sqlite.prepare(s.db, "SELECT author, flags, type FROM messages WHERE id = ? AND channel = ?;");
		sqlite.bind_all(st, message, channel);
		found := sqlite.step(st) == .Row;
		author, flags, kind := ifx found then sqlite.col_int(st, 0) else 0, ifx found then sqlite.col_int(st, 1) else 0, ifx found then sqlite.col_int(st, 2) else 0;
		sqlite.finalize(st);
		if !found return json_error(c, 404, 10008, "Unknown Message");
		if author != user && owner_id(s) != user return json_error(c, 403, 50013, "Missing Permissions");
		if flags & CROSSPOSTED || kind != DEFAULT return json_error(c, 400, 40033, "This message has already been crossposted.");
		if !sqlite.run(s.db, "UPDATE messages SET flags = flags | ? WHERE id = ?;", CROSSPOSTED, message) return json_error(c, 500, 0, "500: Internal Server Error");
		m = message_locked(s, message, nested = false);
	}
	broadcast(s, "MESSAGE_UPDATE", m);
	return json_reply(c, 200, m);
}

ICON_MAX_BYTES :: 512 * 1024;

// The server icon's hash, or null; the caller holds db_mu.
MAX_WEBHOOKS :: 15; // Per channel, as on Discord.
WEBHOOK_SELECT :: "SELECT w.id, w.channel, u.name, w.token, w.creator, c.name FROM webhooks w JOIN users u ON u.id = w.id JOIN users c ON c.id = w.creator";

// row_webhook reads a WEBHOOK_SELECT row as Discord's webhook object; the token only for the owner.
row_webhook :: (s: *Server, st: *sqlite.Stmt, with_token: bool) -> etf.Value {
	m := etf.map_builder(9,, temp);
	etf.map_put(*m, "id", snow(sqlite.col_int(st, 0)));
	etf.map_put(*m, "type", etf.vint(1));
	etf.map_put(*m, "guild_id", snow(s.guild));
	etf.map_put(*m, "channel_id", snow(sqlite.col_int(st, 1)));
	etf.map_put(*m, "name", etf.vstring(copy_string(sqlite.col_text(st, 2),, temp)));
	etf.map_put(*m, "avatar", .{});
	etf.map_put(*m, "application_id", .{});
	if with_token {
		etf.map_put(*m, "token", etf.vstring(copy_string(sqlite.col_text(st, 3),, temp)));
		etf.map_put(*m, "user", user_value(s, sqlite.col_int(st, 4), copy_string(sqlite.col_text(st, 5),, temp)));
	}
	return etf.vmap(etf.map_done(*m));
}

// GET and POST /api/v9/channels/{id}/webhooks {name}, and GET /guilds/{id}/webhooks (channel 0): the
// owner lists a channel's or the server's webhooks, tokens included, and makes new ones.
channel_webhooks :: (c: *Conn, req: http.Request, user: s64, channel: s64) -> bool {
	s := c.server;
	name := "";
	if req.method == "POST" {
		v, err := etf.from_json(cast(string) req.body,, temp);
		name_v: etf.Value;
		if err == .None && v.kind == .Map name_v, _ = etf.map_get(v.map, "name");
		name = ifx name_v.kind == .String then trim(name_v.s) else "";
		if !name || name.count > 80 || !text_ok(name) return json_error(c, 400, 50035, "Invalid Form Body");
	} else if req.method != "GET" {
		return json_error(c, 405, 0, "405: Method Not Allowed");
	}
	result: etf.Value;
	{
		locks.guard(*s.db_mu);
		if owner_id(s) != user return json_error(c, 403, 50013, "Missing Permissions");
		if channel && !text_like_locked(s, channel) return json_error(c, 404, 10003, "Unknown Channel");
		if req.method == "POST" {
			st := sqlite.prepare(s.db, "SELECT count(*) FROM webhooks WHERE channel = ?;");
			sqlite.bind_all(st, channel);
			n := ifx sqlite.step(st) == .Row then sqlite.col_int(st, 0) else 0;
			sqlite.finalize(st);
			if n >= MAX_WEBHOOKS return json_error(c, 400, 30007, tprint("Maximum number of webhooks reached (%)", MAX_WEBHOOKS));
			id := snowflake(s);
			root, secret: [32]u8;
			crypto.random_bytes(root);
			crypto.random_bytes(secret);
			ok := sqlite.exec(s.db, "BEGIN;")
				&& sqlite.run(s.db, "INSERT INTO users(id, root, signing_pub, name, left) VALUES(?, ?, x'', ?, 1);", id, cast([]u8) root, name)
				&& sqlite.run(s.db, "INSERT INTO webhooks(id, channel, token, creator) VALUES(?, ?, ?, ?);", id, channel, hex(secret,, temp), user)
				&& sqlite.exec(s.db, "COMMIT;");
			if !ok { sqlite.exec(s.db, "ROLLBACK;"); return json_error(c, 500, 0, "500: Internal Server Error"); }
			st = sqlite.prepare(s.db, tprint("% WHERE w.id = ?;", WEBHOOK_SELECT));
			sqlite.bind_all(st, id);
			if sqlite.step(st) == .Row result = row_webhook(s, st, true);
			sqlite.finalize(st);
		} else {
			list: [..]etf.Value;
			list.allocator = temp;
			st := sqlite.prepare(s.db, tprint("% WHERE ?1 = 0 OR w.channel = ?1 ORDER BY w.id;", WEBHOOK_SELECT));
			sqlite.bind_all(st, channel);
			while sqlite.step(st) == .Row array_add(*list, row_webhook(s, st, true));
			sqlite.finalize(st);
			result = etf.vlist(list);
		}
	}
	return json_reply(c, ifx req.method == "POST" then 201 else 200, result);
}

// /api/webhooks/{id}/{token} (also under v9 and v10): POST {content, username?}[?wait=true] posts as the
// webhook, GET describes it and DELETE removes it, for anyone holding the token, as on Discord, so tools
// outside the app (CI, feeds, alerts) can post. /api/v9/webhooks/{id} does GET and DELETE for the owner.
// A deleted webhook's messages stay, under its name. /api/webhooks/{id}/{token}/messages/{message} reads,
// edits (PATCH {content?, embeds?}) or deletes one of the webhook's own messages.
webhook :: (c: *Conn, req: http.Request) -> bool {
	s := c.server;
	path, query := req.path, "";
	q := find_index_from_left(path, #char "?");
	if q >= 0 { query = slice(path, q + 1, path.count - q - 1); path = slice(path, 0, q); }
	parts := split(advance(path, find_index_from_left(path, "webhooks/") + "webhooks/".count), "/",, temp);
	id, ok := string_to_int(parts[0], T = s64);
	own: s64;
	if ok && parts.count == 4 && parts[1] && parts[2] == "messages" {
		own, ok = string_to_int(parts[3], T = s64);
		if !ok || own <= 0 return json_error(c, 404, 10008, "Unknown Message");
	} else if !ok || parts.count > 2 || (parts.count == 2 && !parts[1]) return json_error(c, 404, 0, "404: Not Found");
	by_token := parts.count >= 2;
	user: s64;
	if !by_token {
		token, _ := http.header_get(req.headers, "authorization");
		user = session_user(c, token);
		if !user return json_error(c, 401, 0, "401: Unauthorized");
	}
	if req.method == "PATCH" && !by_token return edit_webhook(c, req, user, id); // settings.jai
	if req.method != "GET" && req.method != "DELETE" && !(req.method == "POST" && by_token && !own) && !(req.method == "PATCH" && own) return json_error(c, 405, 0, "405: Method Not Allowed");

	content, username: string;
	embeds: []string;
	everyone := false;
	has_content, has_embeds: bool;
	// allowed_mentions, as on Discord: absent pings everyone named; present pings only what it lists.
	may_everyone, all_users := true, true;
	users: [..]s64;
	users.allocator = temp;
	v: etf.Value;
	if req.method == "PATCH" || req.method == "POST" {
		err: etf.Error;
		v, err = etf.from_json(cast(string) req.body,, temp);
		if err != .None || v.kind != .Map return json_error(c, 400, 50035, "Invalid Form Body");
		am, has_am := etf.map_get(v.map, "allowed_mentions");
		if has_am && am.kind != .Nil {
			if am.kind != .Map return json_error(c, 400, 50035, "Invalid Form Body");
			parse, _ := etf.map_get(am.map, "parse");
			listed, _ := etf.map_get(am.map, "users");
			if (parse.kind != .Nil && parse.kind != .List) || (listed.kind != .Nil && listed.kind != .List) || listed.list.count > 100 return json_error(c, 400, 50035, "Invalid Form Body");
			may_everyone, all_users = false, false;
			for parse.list {
				if it.kind != .String return json_error(c, 400, 50035, "Invalid Form Body");
				if it.s == "everyone" may_everyone = true;
				else if it.s == "users" all_users = true;
				else if it.s != "roles" return json_error(c, 400, 50035, "Invalid Form Body");
			}
			for listed.list {
				n, ok := string_to_int(ifx it.kind == .String then it.s else "", T = s64);
				if !ok return json_error(c, 400, 50035, "Invalid Form Body");
				array_add(*users, n);
			}
			// Discord refuses naming users both ways.
			if all_users && users.count return json_error(c, 400, 50035, "Invalid Form Body");
		}
	}
	if req.method == "PATCH" {
		content_v, _ := etf.map_get(v.map, "content");
		embeds_v: etf.Value;
		embeds_v, has_embeds = etf.map_get(v.map, "embeds");
		embeds_ok: bool;
		embeds, embeds_ok = webhook_embeds(embeds_v);
		if !embeds_ok || (content_v.kind != .String && content_v.kind != .Nil) return json_error(c, 400, 50035, "Invalid Form Body");
		has_content = content_v.kind == .String;
		if has_content content = content_v.s;
		if !text_ok(content, lines = true) return json_error(c, 400, 50035, "Invalid Form Body");
		if utf16_units(content) > MAX_CONTENT return content_too_long(c);
	} else if req.method == "POST" {
		content_v, _ := etf.map_get(v.map, "content");
		name_v, has_name := etf.map_get(v.map, "username");
		embeds_v, _ := etf.map_get(v.map, "embeds");
		embeds_ok: bool;
		embeds, embeds_ok = webhook_embeds(embeds_v);
		if !embeds_ok || (content_v.kind != .String && content_v.kind != .Nil) return json_error(c, 400, 50035, "Invalid Form Body");
		if content_v.kind == .String content = content_v.s;
		if !trim(content) && !embeds.count return json_error(c, 400, 50006, "Cannot send an empty message");
		if !text_ok(content, lines = true) return json_error(c, 400, 50035, "Invalid Form Body");
		if utf16_units(content) > MAX_CONTENT return content_too_long(c);
		if has_name && name_v.kind != .Nil {
			username = ifx name_v.kind == .String then trim(name_v.s) else "";
			if !username || username.count > 80 || !text_ok(username) return json_error(c, 400, 50035, "Invalid Form Body");
		}
		everyone = may_everyone && (contains(content, "@everyone") || contains(content, "@here"));
	}
	result, m: etf.Value;
	channel, message: s64;
	{
		locks.guard(*s.db_mu);
		st := sqlite.prepare(s.db, tprint("% WHERE w.id = ?;", WEBHOOK_SELECT));
		sqlite.bind_all(st, id);
		found := sqlite.step(st) == .Row;
		if found {
			channel = sqlite.col_int(st, 1);
			if by_token found = crypto.constant_time_equal(cast([]u8) parts[1], cast([]u8) copy_string(sqlite.col_text(st, 3),, temp));
			result = row_webhook(s, st, !by_token);
		}
		sqlite.finalize(st);
		if !found return json_error(c, 404, 10015, "Unknown Webhook");
		if !by_token && owner_id(s) != user return json_error(c, 403, 50013, "Missing Permissions");
		if own {
			st =sqlite.prepare(s.db, "SELECT content, (SELECT count(*) FROM embeds e WHERE e.message = m.id AND e.rich IS NOT NULL), channel FROM messages m WHERE id = ? AND author = ? AND webhook = 1;");
			sqlite.bind_all(st, own, id);
			found = sqlite.step(st) == .Row;
			old_content: string;
			old_embeds: int;
			if found {
				old_content = copy_string(sqlite.col_text(st, 0),, temp);
				old_embeds = sqlite.col_int(st, 1);
				channel = sqlite.col_int(st, 2);
			}
			sqlite.finalize(st);
			if !found return json_error(c, 404, 10008, "Unknown Message");
			message = own;
			if req.method == "PATCH" {
				if !has_content content = old_content;
				if !trim(content) && !(ifx has_embeds then embeds.count else old_embeds) return json_error(c, 400, 50006, "Cannot send an empty message");
				// As a member's edit: mentions follow the new text, but nobody is pinged again.
				everyone = may_everyone && (contains(content, "@everyone") || contains(content, "@here"));
				ok := sqlite.exec(s.db, "BEGIN;")
					&& sqlite.run(s.db, "UPDATE messages SET content = ?, edited = ?, everyone = ? WHERE id = ?;", content, snowflake(s), cast(int) everyone, message)
					&& sqlite.run(s.db, "DELETE FROM mentions WHERE message = ?;", message);
				for mention_ids(content) if ok && (all_users || array_find(users, it)) ok = sqlite.run(s.db, "INSERT OR IGNORE INTO mentions(message, user) SELECT ?, id FROM users WHERE id = ? AND left = 0;", message, it);
				if has_embeds && ok ok = sqlite.run(s.db, "DELETE FROM embeds WHERE message = ? AND rich IS NOT NULL;", message);
				if has_embeds for embeds if ok ok = sqlite.run(s.db, "INSERT INTO embeds(message, position, url, title, description, provider, color, rich) VALUES(?, ?, '', '', '', '', 0, ?);", message, it_index, it);
				links: [MAX_LINKS]string;
				for link_urls(content) links[it_index] = it;
				ok = ok && sqlite.run(s.db, "DELETE FROM embeds WHERE message = ? AND rich IS NULL AND url NOT IN (coalesce(?, ''), coalesce(?, ''), coalesce(?, ''));", message, links[0], links[1], links[2]);
				if !ok || !sqlite.exec(s.db, "COMMIT;") { sqlite.exec(s.db, "ROLLBACK;"); return json_error(c, 500, 0, "500: Internal Server Error"); }
			} else if req.method == "DELETE" {
				if !sqlite.run(s.db, "DELETE FROM messages WHERE id = ?;", message) return json_error(c, 500, 0, "500: Internal Server Error");
				sqlite.run(s.db, "DELETE FROM reactions WHERE message = ?;", message);
				sqlite.run(s.db, "DELETE FROM mentions WHERE message = ?;", message);
				drop_files(s, "?1", message);
				sqlite.run(s.db, "DELETE FROM embeds WHERE message = ?;", message);
			}
			if req.method != "DELETE" m = message_locked(s, message, nested = false);
		} else if req.method == "DELETE" {
			if !sqlite.run(s.db, "DELETE FROM webhooks WHERE id = ?;", id) return json_error(c, 500, 0, "500: Internal Server Error");
		} else if req.method == "POST" {
			message = snowflake(s);
			ok := sqlite.exec(s.db, "BEGIN;")
				&& sqlite.run(s.db, "INSERT INTO messages(id, channel, author, content, everyone, webhook, username) VALUES(?, ?, ?, ?, ?, 1, nullif(?, ''));", message, channel, id, content, cast(int) everyone, username);
			for mention_ids(content) if ok && (all_users || array_find(users, it)) ok = sqlite.run(s.db, "INSERT OR IGNORE INTO mentions(message, user) SELECT ?, id FROM users WHERE id = ? AND left = 0;", message, it);
			for embeds if ok ok = sqlite.run(s.db, "INSERT INTO embeds(message, position, url, title, description, provider, color, rich) VALUES(?, ?, '', '', '', '', 0, ?);", message, it_index, it);
			ok = ok && sqlite.run(s.db, COUNT_MENTIONS, channel, id, cast(int) everyone, message) && sqlite.exec(s.db, "COMMIT;");
			if !ok { sqlite.exec(s.db, "ROLLBACK;"); return json_error(c, 500, 0, "500: Internal Server Error"); }
			m = message_locked(s, message, nested = false);
		}
	}
	if own {
		if req.method == "GET" return json_reply(c, 200, m);
		if req.method == "PATCH" {
			broadcast(s, "MESSAGE_UPDATE", m);
			queue_unfurl(s, message, content);
			return json_reply(c, 200, m);
		}
		d := etf.map_builder(3,, temp);
		etf.map_put(*d, "id", snow(message));
		etf.map_put(*d, "channel_id", snow(channel));
		etf.map_put(*d, "guild_id", snow(s.guild));
		broadcast(s, "MESSAGE_DELETE", etf.vmap(etf.map_done(*d)));
		return respond(c, 204, json = false);
	}
	if req.method == "DELETE" return respond(c, 204, json = false);
	if req.method == "GET" return json_reply(c, 200, result);
	broadcast(s, "MESSAGE_CREATE", m);
	queue_unfurl(s, message, content);
	if contains(query, "wait=true") return json_reply(c, 200, m);
	return respond(c, 204, json = false);
}

guild_icon_locked :: (s: *Server) -> etf.Value {
	hash := cast(string) meta_get(s, "icon");
	return ifx hash then etf.vstring(hash) else .{};
}

EMOJI_MAX_BYTES :: 256 * 1024; // Discord's cap per emoji.
MAX_EMOJIS :: 50; // Static and animated each, as a server without boosts has on Discord.

// emoji_value is one custom emoji as Discord sends it in a guild's list.
emoji_value :: (id: s64, name: string, animated: bool, user := etf.Value.{}) -> etf.Value {
	e := etf.map_builder(7,, temp);
	if user.kind != .Nil etf.map_put(*e, "user", user);
	etf.map_put(*e, "id", snow(id));
	etf.map_put(*e, "name", etf.vstring(name));
	etf.map_put(*e, "animated", etf.vbool(animated));
	etf.map_put(*e, "available", etf.vbool(true));
	etf.map_put(*e, "require_colons", etf.vbool(true));
	etf.map_put(*e, "managed", etf.vbool(false));
	return etf.vmap(etf.map_done(*e));
}

// The server's custom emoji, oldest first; the caller holds db_mu.
// With with_user each names its uploader, as Discord shows those who manage expressions.
emoji_list_locked :: (s: *Server, with_user := false) -> etf.Value {
	list: [..]etf.Value;
	list.allocator = temp;
	st := sqlite.prepare(s.db, "SELECT e.id, e.name, e.animated, e.user, u.name FROM emojis e JOIN users u ON u.id = e.user ORDER BY e.id;");
	defer sqlite.finalize(st);
	while sqlite.step(st) == .Row {
		user := ifx with_user then user_value(s, sqlite.col_int(st, 3), copy_string(sqlite.col_text(st, 4),, temp)) else etf.Value.{};
		array_add(*list, emoji_value(sqlite.col_int(st, 0), copy_string(sqlite.col_text(st, 1),, temp), sqlite.col_int(st, 2) != 0, user));
	}
	return etf.vlist(list);
}

// POST /api/v9/guilds/{id}/emojis {name, image}: the owner adds a custom emoji, a `data:` URI kept as sent
// (a GIF is animated), and every member gets GUILD_EMOJIS_UPDATE with the whole list, as from Discord.
create_emoji :: (c: *Conn, req: http.Request) -> bool {
	s := c.server;
	token, _ := http.header_get(req.headers, "authorization");
	user := session_user(c, token);
	if !user return json_error(c, 401, 0, "401: Unauthorized");
	v, err := etf.from_json(cast(string) req.body,, temp);
	if err != .None || v.kind != .Map return json_error(c, 400, 50035, "Invalid Form Body");
	name_v, _ := etf.map_get(v.map, "name");
	image_v, _ := etf.map_get(v.map, "image");
	name := ifx name_v.kind == .String then name_v.s else "";
	name_ok := name.count >= 2 && name.count <= 32;
	for name if !is_alnum(it) && it != #char "_" name_ok = false;
	if !name_ok return json_error(c, 400, 50035, "Invalid Form Body");
	image, format, ok := image_data_uri(ifx image_v.kind == .String then image_v.s else "", EMOJI_MAX_BYTES);
	if !ok return json_error(c, 400, 50035, "Invalid Form Body");
	animated := format == .GIF;
	emoji, list: etf.Value;
	{
		locks.guard(*s.db_mu);
		if owner_id(s) != user return json_error(c, 403, 50013, "Missing Permissions");
		st := sqlite.prepare(s.db, "SELECT count(*) FROM emojis WHERE animated = ?;");
		sqlite.bind_all(st, cast(int) animated);
		n := ifx sqlite.step(st) == .Row then sqlite.col_int(st, 0) else 0;
		sqlite.finalize(st);
		if n >= MAX_EMOJIS return json_error(c, 400, 30008, tprint("Maximum number of emojis reached (%)", MAX_EMOJIS));
		id := snowflake(s);
		if !sqlite.run(s.db, "INSERT INTO emojis(id, name, animated, type, data, user) VALUES(?, ?, ?, ?, ?, ?);", id, name, cast(int) animated, IMAGE_TYPES[cast(int) format], image, user) {
			return json_error(c, 500, 0, "500: Internal Server Error");
		}
		audit_locked(s, user, AUDIT_EMOJI_CREATE, id, .[audit_change("name", .{}, etf.vstring(name))], "");
		emoji = emoji_value(id, name, animated);
		list = emoji_list_locked(s);
	}
	d := etf.map_builder(2,, temp);
	etf.map_put(*d, "guild_id", snow(s.guild));
	etf.map_put(*d, "emojis", list);
	broadcast(s, "GUILD_EMOJIS_UPDATE", etf.vmap(etf.map_done(*d)));
	return json_reply(c, 201, emoji);
}

// PATCH /api/v9/guilds/{id}/members/@me {nick}: Change Nickname, and /members/{user} for the owner on
// anyone. A member has one name here, so the nick replaces it, and members see it as their name with no
// nick; an empty nick goes back to the name they joined with, as Discord falls back to the username.
rename :: (c: *Conn, req: http.Request) -> bool {
	s := c.server;
	token, _ := http.header_get(req.headers, "authorization");
	user := session_user(c, token);
	if !user return json_error(c, 401, 0, "401: Unauthorized");
	target := user;
	if !ends_with(req.path, "/members/@me") {
		ok: bool;
		target, ok = string_to_int(slice(req.path, find_index_from_right(req.path, #char "/") + 1, req.path.count), T = s64);
		if !ok return json_error(c, 404, 10013, "Unknown User");
	}
	v, err := etf.from_json(cast(string) req.body,, temp);
	nick: etf.Value;
	if err == .None && v.kind == .Map nick, _ = etf.map_get(v.map, "nick");
	name := ifx nick.kind == .String then trim(nick.s) else "";
	if (nick.kind != .String && nick.kind != .Nil) || name.count > 32 || !text_ok(name) return json_error(c, 400, 50035, "Invalid Form Body");
	{
		locks.guard(*s.db_mu);
		if target != user && owner_id(s) != user return json_error(c, 403, 50013, "Missing Permissions");
		if !sqlite.run(s.db, "UPDATE users SET name = coalesce(nullif(?, ''), joined_name, name) WHERE id = ? AND left = 0;", name, target) return json_error(c, 500, 0, "500: Internal Server Error");
		if sqlite.changes(s.db) != 1 return json_error(c, 404, 10007, "Unknown Member");
		if !name {
			st := sqlite.prepare(s.db, "SELECT name FROM users WHERE id = ?;");
			sqlite.bind(st, 1, target);
			if sqlite.step(st) == .Row name = copy_string(sqlite.col_text(st, 0),, temp);
			sqlite.finalize(st);
		}
	}
	m := etf.map_builder(4,, temp);
	etf.map_put(*m, "guild_id", snow(s.guild));
	etf.map_put(*m, "user", user_value(s, target, name));
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
	user := session_user(c, token);
	if !user return json_error(c, 401, 0, "401: Unauthorized");
	{
		locks.guard(*s.db_mu);
		if owner_id(s) == user return json_error(c, 400, 50055, "Invalid Guild");
		if !remove_member_locked(s, user, banned = false) return json_error(c, 500, 0, "500: Internal Server Error");
	}
	removed(s, user);
	return respond(c, 204, json = false);
}

// DELETE /guilds/{id}/members/{user} kicks, PUT /guilds/{id}/bans/{user} {delete_message_seconds?} bans and
// DELETE unbans, for the owner. Both end the member's sessions and gateways as a leave does; a ban is on
// their key, so no invite lets them back until it's lifted. A ban can also delete what they sent in the
// last week at most, as on Discord, sent to each channel as one MESSAGE_DELETE_BULK. The ban keeps the
// reason from X-Audit-Log-Reason for the ban list.
moderate :: (c: *Conn, req: http.Request) -> bool {
	s := c.server;
	token, _ := http.header_get(req.headers, "authorization");
	user := session_user(c, token);
	if !user return json_error(c, 401, 0, "401: Unauthorized");
	parts := split(req.path, "/",, temp); // "", api, v9, guilds, {id}, members|bans, {user}
	if parts.count != 7 return json_error(c, 404, 0, "404: Not Found");
	ban := parts[5] == "bans";
	if !ban && req.method == "PATCH" return rename(c, req);
	if !(ban && (req.method == "PUT" || req.method == "DELETE")) && !(!ban && req.method == "DELETE") return json_error(c, 405, 0, "405: Method Not Allowed");
	target, tok := string_to_int(parts[6], T = s64);
	history := 0;
	if ban && req.method == "PUT" && req.body.count {
		v, err := etf.from_json(cast(string) req.body,, temp);
		if err != .None || v.kind != .Map return json_error(c, 400, 50035, "Invalid Form Body");
		secs, has := etf.map_get(v.map, "delete_message_seconds");
		if has && secs.kind != .Nil {
			if secs.kind != .Int || secs.i < 0 || secs.i > 604800 return json_error(c, 400, 50035, "Invalid Form Body");
			history = cast(int) secs.i;
		}
	}
	reason, rok := audit_reason(req);
	if !rok return json_error(c, 400, 50035, "Invalid Form Body");
	Gone :: struct { channel: s64; ids: [..]s64; }
	gone: [..]Gone;
	gone.allocator = temp;
	{
		locks.guard(*s.db_mu);
		if owner_id(s) != user return json_error(c, 403, 50013, "Missing Permissions");
		if !tok || target == user return json_error(c, 403, 50013, "Missing Permissions");
		left, banned := 1, 0;
		st := sqlite.prepare(s.db, "SELECT left, banned FROM users WHERE id = ?;");
		sqlite.bind(st, 1, target);
		found := sqlite.step(st) == .Row;
		if found left, banned = sqlite.col_int(st, 0), sqlite.col_int(st, 1);
		sqlite.finalize(st);
		if !found return json_error(c, 404, 10013, "Unknown User");
		if ban && req.method == "DELETE" {
			if !banned return json_error(c, 404, 10026, "Unknown Ban");
			if !sqlite.run(s.db, "UPDATE users SET banned = 0, ban_reason = NULL WHERE id = ?;", target) return json_error(c, 500, 0, "500: Internal Server Error");
			audit_locked(s, user, AUDIT_MEMBER_BAN_REMOVE, target, .[], reason);
			return respond(c, 204, json = false);
		}
		if !ban && left return json_error(c, 404, 10007, "Unknown Member");
		if history {
			st = sqlite.prepare(s.db, "SELECT id, channel FROM messages WHERE author = ? AND id >= ? ORDER BY channel, id;");
			sqlite.bind_all(st, target, (now_ms(s) - history * 1000) << 22);
			while sqlite.step(st) == .Row {
				channel := sqlite.col_int(st, 1);
				if !gone.count || gone[gone.count - 1].channel != channel {
					g := array_add(*gone);
					g.channel = channel;
					g.ids.allocator = temp;
				}
				array_add(*gone[gone.count - 1].ids, sqlite.col_int(st, 0));
			}
			sqlite.finalize(st);
			ok := sqlite.exec(s.db, "BEGIN;");
			for g: gone for g.ids if ok {
				ok = sqlite.run(s.db, "DELETE FROM messages WHERE id = ?;", it)
					&& sqlite.run(s.db, "DELETE FROM reactions WHERE message = ?;", it)
					&& sqlite.run(s.db, "DELETE FROM mentions WHERE message = ?;", it)
					&& drop_files(s, "?1", it)
					&& sqlite.run(s.db, "DELETE FROM embeds WHERE message = ?;", it);
			}
			if !ok || !sqlite.exec(s.db, "COMMIT;") { sqlite.exec(s.db, "ROLLBACK;"); return json_error(c, 500, 0, "500: Internal Server Error"); }
		}
		if !remove_member_locked(s, target, ban) return json_error(c, 500, 0, "500: Internal Server Error");
		if ban sqlite.run(s.db, "UPDATE users SET ban_reason = nullif(?, '') WHERE id = ?;", reason, target);
		audit_locked(s, user, ifx ban then AUDIT_MEMBER_BAN_ADD else AUDIT_MEMBER_KICK, target, .[], reason);
	}
	removed(s, target);
	for g: gone {
		ids: [..]etf.Value;
		ids.allocator = temp;
		for g.ids array_add(*ids, snow(it));
		d := etf.map_builder(3,, temp);
		etf.map_put(*d, "ids", etf.vlist(ids));
		etf.map_put(*d, "channel_id", snow(g.channel));
		etf.map_put(*d, "guild_id", snow(s.guild));
		broadcast(s, "MESSAGE_DELETE_BULK", etf.vmap(etf.map_done(*d)));
	}
	return respond(c, 204, json = false);
}

// GET /guilds/{id}/bans[?limit=&after=] lists banned members by ID, with the reason given, for the owner.
list_bans :: (c: *Conn, req: http.Request) -> bool {
	s := c.server;
	token, _ := http.header_get(req.headers, "authorization");
	user := session_user(c, token);
	if !user return json_error(c, 401, 0, "401: Unauthorized");
	limit, after := 1000, 0;
	q := find_index_from_left(req.path, #char "?");
	for split(ifx q >= 0 then slice(req.path, q + 1, req.path.count - q - 1) else "", "&",, temp) {
		kv := split(it, "=",, temp);
		if kv.count != 2 continue;
		n, ok := string_to_int(kv[1], T = s64);
		if kv[0] == "limit" {
			if !ok || n < 1 || n > 1000 return json_error(c, 400, 50035, "Invalid Form Body");
			limit = cast(int) n;
		} else if kv[0] == "after" {
			if !ok return json_error(c, 400, 50035, "Invalid Form Body");
			after = n;
		}
	}
	locks.guard(*s.db_mu);
	if owner_id(s) != user return json_error(c, 403, 50013, "Missing Permissions");
	list: [..]etf.Value;
	list.allocator = temp;
	st := sqlite.prepare(s.db, "SELECT id, name, ban_reason FROM users WHERE banned = 1 AND id > ? ORDER BY id LIMIT ?;");
	defer sqlite.finalize(st);
	sqlite.bind_all(st, after, limit);
	while sqlite.step(st) == .Row {
		m := etf.map_builder(2,, temp);
		etf.map_put(*m, "user", user_value(s, sqlite.col_int(st, 0), copy_string(sqlite.col_text(st, 1),, temp)));
		etf.map_put(*m, "reason", ifx sqlite.col_is_null(st, 2) then etf.Value.{} else etf.vstring(copy_string(sqlite.col_text(st, 2),, temp)));
		array_add(*list, etf.vmap(etf.map_done(*m)));
	}
	return json_reply(c, 200, etf.vlist(list));
}

// GET /guilds/{id}/invites lists the working invites, for the owner. DELETE /invites/{code} revokes one,
// for the owner or whoever made it; the row stays, used up, so the code never works again.
manage_invites :: (c: *Conn, req: http.Request) -> bool {
	s := c.server;
	token, _ := http.header_get(req.headers, "authorization");
	user := session_user(c, token);
	if !user return json_error(c, 401, 0, "401: Unauthorized");
	locks.guard(*s.db_mu);
	owner := owner_id(s) == user;
	if req.method == "DELETE" {
		code := slice(req.path, "/api/v9/invites/".count, req.path.count - "/api/v9/invites/".count);
		st := sqlite.prepare(s.db, tprint("SELECT inviter FROM invites WHERE code = ? AND owner = 0 AND %;", INVITE_LIVE));
		sqlite.bind(st, 1, code);
		found := sqlite.step(st) == .Row;
		inviter := ifx found then sqlite.col_int(st, 0) else 0;
		sqlite.finalize(st);
		if !found return json_error(c, 404, 10006, "Unknown Invite");
		if !owner && inviter != user return json_error(c, 403, 50013, "Missing Permissions");
		if !sqlite.run(s.db, "UPDATE invites SET uses_left = 0 WHERE code = ?;", code) return json_error(c, 500, 0, "500: Internal Server Error");
		return respond(c, 200, tprint("{\"code\": \"%\", \"guild_id\": \"%\"}", code, s.guild));
	}
	if !owner return json_error(c, 403, 50013, "Missing Permissions");
	list: [..]etf.Value;
	list.allocator = temp;
	st := sqlite.prepare(s.db, tprint("SELECT code, uses_left, inviter, channel, max_age, expires FROM invites WHERE owner = 0 AND % ORDER BY rowid;", INVITE_LIVE));
	defer sqlite.finalize(st);
	while sqlite.step(st) == .Row {
		m := etf.map_builder(7,, temp);
		etf.map_put(*m, "code", etf.vstring(copy_string(sqlite.col_text(st, 0),, temp)));
		etf.map_put(*m, "guild_id", snow(s.guild));
		uses_left := sqlite.col_int(st, 1);
		// Only the uses left are kept, so max_uses counts from now: 0 means unlimited, as on Discord.
		etf.map_put(*m, "max_uses", etf.vint(ifx uses_left > 0 then uses_left else 0));
		inviter, channel := sqlite.col_int(st, 2), sqlite.col_int(st, 3);
		etf.map_put(*m, "inviter_id", ifx inviter then snow(inviter) else .{});
		etf.map_put(*m, "channel_id", ifx channel then snow(channel) else .{});
		etf.map_put(*m, "max_age", etf.vint(sqlite.col_int(st, 4)));
		expires := sqlite.col_int(st, 5);
		etf.map_put(*m, "expires_at", ifx expires then etf.vstring(iso(((expires * 1000) - DISCORD_EPOCH_MS) << 22)) else .{});
		array_add(*list, etf.vmap(etf.map_done(*m)));
	}
	return json_reply(c, 200, etf.vlist(list));
}

// remove_member_locked marks user gone (and banned) and ends their sessions; db_mu is held.
remove_member_locked :: (s: *Server, user: s64, banned: bool) -> bool {
	ok := sqlite.exec(s.db, "BEGIN;")
		&& sqlite.run(s.db, "UPDATE users SET left = 1, banned = banned OR ? WHERE id = ?;", cast(s64) banned, user)
		&& sqlite.run(s.db, "DELETE FROM sessions WHERE user = ?;", user)
		&& sqlite.exec(s.db, "COMMIT;");
	if !ok sqlite.exec(s.db, "ROLLBACK;");
	return ok;
}

// removed tells a member's gateways their guild is gone, and everyone else the member list changed.
removed :: (s: *Server, user: s64) {
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
	voice_leave(s, user);
	broadcast(s, "GUILD_MEMBER_LIST_UPDATE", member_list_value(s));
}

// PATCH /api/v9/channels/{id} {name?, topic?} and DELETE /api/v9/channels/{id}, for the owner. The last
// channel can't be deleted, so the server always has somewhere to talk.
edit_channel :: (c: *Conn, req: http.Request, user: s64, channel: s64) -> bool {
	s := c.server;
	ch: etf.Value;
	orphans, gone_threads, gone_events: [..]etf.Value;
	orphans.allocator, gone_threads.allocator, gone_events.allocator = temp, temp, temp;
	starter: etf.Value; // A deleted thread's starter message, which loses its `thread`.
	kind := -1;
	if req.method == "PATCH" {
		v, err := etf.from_json(cast(string) req.body,, temp);
		if err != .None || v.kind != .Map return json_error(c, 400, 50035, "Invalid Form Body");
		raw, has_name := etf.map_get(v.map, "name");
		topic, has_topic := etf.map_get(v.map, "topic");
		slow, has_slow := etf.map_get(v.map, "rate_limit_per_user");
		nsfw, has_nsfw := etf.map_get(v.map, "nsfw");
		archived, has_archived := etf.map_get(v.map, "archived");
		locked, has_locked := etf.map_get(v.map, "locked");
		after, has_after := etf.map_get(v.map, "auto_archive_duration");
		if (has_slow && !(slow.kind == .Int && slow.i >= 0 && slow.i <= 21600)) || (has_nsfw && nsfw.kind != .Bool) return json_error(c, 400, 50035, "Invalid Form Body");
		if (has_archived && archived.kind != .Bool) || (has_locked && locked.kind != .Bool) || (has_after && !(after.kind == .Int && (after.i == 60 || after.i == 1440 || after.i == 4320 || after.i == 10080))) {
			return json_error(c, 400, 50035, "Invalid Form Body");
		}
		locks.guard(*s.db_mu);
		kind = channel_type_locked(s, channel);
		if kind < 0 return json_error(c, 404, 10003, "Unknown Channel");
		if (has_archived || has_locked || has_after) && kind != THREAD return json_error(c, 400, 50035, "Invalid Form Body");
		was_locked := false;
		if kind == THREAD {
			st := sqlite.prepare(s.db, "SELECT locked FROM channels WHERE id = ?;");
			sqlite.bind_all(st, channel);
			was_locked = sqlite.step(st) == .Row && sqlite.col_int(st, 0) != 0;
			sqlite.finalize(st);
		}
		// A thread's starter may rename, archive and reopen it too, until the owner locks it.
		by_starter := kind == THREAD && !has_topic && !has_slow && !has_nsfw && !has_locked && !was_locked && thread_owner_locked(s, channel) == user;
		if owner_id(s) != user && !by_starter return json_error(c, 403, 50013, "Missing Permissions");
		name := ifx raw.kind != .String then "" else ifx kind == CATEGORY || kind == THREAD || kind == VOICE then trim(raw.s) else channel_name(raw.s);
		if (has_name && (!name || name.count > 100 || !text_ok(name))) || (has_topic && topic.kind == .String && (topic.s.count > 1024 || !text_ok(topic.s, lines = true))) return json_error(c, 400, 50035, "Invalid Form Body");
		ok := (!has_name || sqlite.run(s.db, "UPDATE channels SET name = ? WHERE id = ?;", name, channel))
			&& (!has_topic || sqlite.run(s.db, "UPDATE channels SET topic = ? WHERE id = ?;", ifx topic.kind == .String then topic.s else "", channel))
			&& (!has_slow || sqlite.run(s.db, "UPDATE channels SET slowmode = ? WHERE id = ?;", slow.i, channel))
			&& (!has_nsfw || sqlite.run(s.db, "UPDATE channels SET nsfw = ? WHERE id = ?;", cast(int) nsfw.b, channel))
			&& (!has_after || sqlite.run(s.db, "UPDATE channels SET archive_after = ? WHERE id = ?;", after.i, channel))
			&& (!has_locked || sqlite.run(s.db, "UPDATE channels SET locked = ? WHERE id = ?;", cast(int) locked.b, channel))
			&& (!has_archived || sqlite.run(s.db, "UPDATE channels SET archived = ?1, archived_at = ?2 WHERE id = ?3 AND archived != ?1;", cast(int) archived.b, now_ms(s) << 22, channel));
		if !ok return json_error(c, 500, 0, "500: Internal Server Error");
		ch = channel_locked(s, channel);
	} else if req.method == "DELETE" {
		locks.guard(*s.db_mu);
		if owner_id(s) != user return json_error(c, 403, 50013, "Missing Permissions");
		ch = channel_locked(s, channel);
		if ch.kind == .Nil return json_error(c, 404, 10003, "Unknown Channel");
		kind = channel_type_locked(s, channel);
		st := sqlite.prepare(s.db, tprint("SELECT count(*) FROM channels WHERE type = %;", TEXT));
		last := kind == TEXT && sqlite.step(st) == .Row && sqlite.col_int(st, 0) <= 1;
		sqlite.finalize(st);
		if last return json_error(c, 400, 50035, "Cannot delete the last channel");
		// A deleted category's channels stay, uncategorized, as on Discord; a text channel's threads go with it.
		st = sqlite.prepare(s.db, "SELECT id, type FROM channels WHERE parent = ?;");
		sqlite.bind(st, 1, channel);
		ids: [..]s64;
		ids.allocator = temp;
		while sqlite.step(st) == .Row {
			if sqlite.col_int(st, 1) == THREAD array_add(*gone_threads, channel_locked(s, sqlite.col_int(st, 0)));
			else array_add(*ids, sqlite.col_int(st, 0));
		}
		sqlite.finalize(st);
		// A voice channel's events go with it, as on Discord.
		st = sqlite.prepare(s.db, "SELECT id FROM events WHERE channel = ?;");
		sqlite.bind(st, 1, channel);
		while sqlite.step(st) == .Row array_add(*gone_events, event_locked(s, sqlite.col_int(st, 0)));
		sqlite.finalize(st);
		// ?1 is the channel; doomed is it and its threads.
		doomed :: "(SELECT id FROM channels WHERE id = ?1 OR (parent = ?1 AND type = 11))";
		ok := sqlite.exec(s.db, "BEGIN;")
			&& sqlite.run(s.db, "UPDATE channels SET parent = NULL WHERE parent = ?1 AND type != 11;", channel)
			&& sqlite.run(s.db, tprint("DELETE FROM reactions WHERE message IN (SELECT id FROM messages WHERE channel IN %);", doomed), channel)
			&& sqlite.run(s.db, tprint("DELETE FROM mentions WHERE message IN (SELECT id FROM messages WHERE channel IN %);", doomed), channel)
			&& drop_files(s, tprint("SELECT id FROM messages WHERE channel IN %", doomed), channel)
			&& sqlite.run(s.db, tprint("DELETE FROM embeds WHERE message IN (SELECT id FROM messages WHERE channel IN %);", doomed), channel)
			&& sqlite.run(s.db, tprint("DELETE FROM uploads WHERE channel IN %;", doomed), channel)
			&& sqlite.run(s.db, tprint("DELETE FROM webhooks WHERE channel IN %;", doomed), channel)
			&& sqlite.run(s.db, tprint("DELETE FROM messages WHERE channel IN %;", doomed), channel)
			&& sqlite.run(s.db, tprint("DELETE FROM read_states WHERE channel IN %;", doomed), channel)
			&& sqlite.run(s.db, tprint("DELETE FROM channels WHERE id IN %;", doomed), channel)
			&& sqlite.run(s.db, "DELETE FROM rsvps WHERE event IN (SELECT id FROM events WHERE channel = ?1);", channel)
			&& sqlite.run(s.db, "DELETE FROM events WHERE channel = ?1;", channel)
			&& sqlite.exec(s.db, "COMMIT;");
		if !ok { sqlite.exec(s.db, "ROLLBACK;"); return json_error(c, 500, 0, "500: Internal Server Error"); }
		for ids array_add(*orphans, channel_locked(s, it));
		if kind == THREAD starter = message_locked(s, channel);
	} else {
		return json_error(c, 405, 0, "405: Method Not Allowed");
	}
	if req.method == "DELETE" && kind == VOICE voice_leave(s, 0, channel = channel); // After db_mu: it takes s.mu.
	thread := kind == THREAD;
	if req.method == "PATCH" broadcast(s, ifx thread then "THREAD_UPDATE" else "CHANNEL_UPDATE", ch);
	else broadcast(s, ifx thread then "THREAD_DELETE" else "CHANNEL_DELETE", ch);
	for gone_threads broadcast(s, "THREAD_DELETE", it);
	for gone_events broadcast(s, "GUILD_SCHEDULED_EVENT_DELETE", it);
	for orphans broadcast(s, "CHANNEL_UPDATE", it);
	if starter.kind == .Map broadcast(s, "MESSAGE_UPDATE", starter);
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
	guild_name: string;
	guild_icon: etf.Value;
	{
		locks.guard(*s.db_mu);
		guild_name = copy_string(s.name,, temp);
		guild_icon = guild_icon_locked(s);
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
	g := etf.map_builder(3,, temp);
	etf.map_put(*g, "id", snow(s.guild));
	etf.map_put(*g, "name", etf.vstring(guild_name));
	etf.map_put(*g, "icon", guild_icon);
	m := etf.map_builder(9,, temp);
	etf.map_put(*m, "code", etf.vstring(code));
	etf.map_put(*m, "type", etf.vint(0));
	etf.map_put(*m, "guild_id", snow(s.guild));
	etf.map_put(*m, "guild", etf.vmap(etf.map_done(*g)));
	etf.map_put(*m, "channel", ch);
	etf.map_put(*m, "inviter", user_value(s, user, name));
	etf.map_put(*m, "max_age", etf.vint(max_age));
	etf.map_put(*m, "expires_at", ifx expires then etf.vstring(iso(((expires * 1000) - DISCORD_EPOCH_MS) << 22)) else .{});
	etf.map_put(*m, "max_uses", etf.vint(max_uses));
	etf.map_put(*m, "temporary", etf.vbool(false));
	return json_reply(c, 200, etf.vmap(etf.map_done(*m)));
}

// Attachments follow Discord's upload flow: POST /channels/{id}/attachments hands out an upload URL per file,
// the client PUTs the bytes there, then names the upload in the message it sends. The URLs carry the
// authority themselves, since a hosted client sends its token only to /api: a random token to upload, and a
// random key to read the stored file back.
MAX_UPLOAD :: 10 << 20; // Bytes per file, as on Discord without Nitro.
MAX_UPLOADS :: 10;      // Files per message.
UPLOAD_TTL_S :: 86400;  // An upload no message claimed by then is dropped.

// POST /api/v9/channels/{id}/attachments {files: [{id, filename, file_size, original_content_type?}]}.
request_uploads :: (c: *Conn, req: http.Request, user: s64, channel: s64) -> bool {
	s := c.server;
	v, err := etf.from_json(cast(string) req.body,, temp);
	if err != .None || v.kind != .Map return json_error(c, 400, 50035, "Invalid Form Body");
	files_v, _ := etf.map_get(v.map, "files");
	if files_v.kind != .List || !files_v.list.count || files_v.list.count > MAX_UPLOADS return json_error(c, 400, 50035, "Invalid Form Body");
	out: [..]etf.Value;
	out.allocator = temp;
	now := to_seconds(current_time_consensus() - APOLLO_TIME_FOR_JAN_1_1970);
	locks.guard(*s.db_mu);
	if channel_locked(s, channel).kind == .Nil return json_error(c, 404, 10003, "Unknown Channel");
	sqlite.run(s.db, "DELETE FROM uploads WHERE created < ?;", now - UPLOAD_TTL_S);
	if !sqlite.exec(s.db, "BEGIN;") return json_error(c, 500, 0, "500: Internal Server Error");
	for f: files_v.list {
		if f.kind != .Map { sqlite.exec(s.db, "ROLLBACK;"); return json_error(c, 400, 50035, "Invalid Form Body"); }
		id, _ := etf.map_get(f.map, "id");
		name, _ := etf.map_get(f.map, "filename");
		size, _ := etf.map_get(f.map, "file_size");
		mime, _ := etf.map_get(f.map, "original_content_type");
		if name.kind != .String || !trim(name.s) || name.s.count > 255 || !text_ok(name.s) || contains(name.s, "/") || contains(name.s, "\\") || size.kind != .Int {
			sqlite.exec(s.db, "ROLLBACK;");
			return json_error(c, 400, 50035, "Invalid Form Body");
		}
		if size.i <= 0 || size.i > MAX_UPLOAD {
			sqlite.exec(s.db, "ROLLBACK;");
			return json_error(c, 413, 40005, "Request entity too large");
		}
		type := ifx mime.kind == .String && mime.s.count < 128 && text_ok(mime.s) then mime.s else "application/octet-stream";
		bytes: [16]u8;
		crypto.random_bytes(bytes);
		token := hex(bytes,, temp);
		if !sqlite.run(s.db, "INSERT INTO uploads(token, user, channel, filename, size, content_type, created) VALUES(?, ?, ?, ?, ?, ?, ?);", token, user, channel, name.s, size.i, type, now) {
			sqlite.exec(s.db, "ROLLBACK;");
			return json_error(c, 500, 0, "500: Internal Server Error");
		}
		a := etf.map_builder(3,, temp);
		etf.map_put(*a, "id", ifx id.kind == .Nil then etf.vstring(tprint("%", it_index)) else id);
		etf.map_put(*a, "upload_url", etf.vstring(tprint("https://%/upload/%", id_hex(s), token)));
		etf.map_put(*a, "upload_filename", etf.vstring(token));
		array_add(*out, etf.vmap(etf.map_done(*a)));
	}
	if !sqlite.exec(s.db, "COMMIT;") { sqlite.exec(s.db, "ROLLBACK;"); return json_error(c, 500, 0, "500: Internal Server Error"); }
	m := etf.map_builder(1,, temp);
	etf.map_put(*m, "attachments", etf.vlist(out));
	return json_reply(c, 200, etf.vmap(etf.map_done(*m)));
}

// upload_size is how many bytes the upload URL path still waits for, or 0 if it isn't one.
upload_size :: (s: *Server, path: string) -> int {
	if !begins_with(path, "/upload/") return 0;
	locks.guard(*s.db_mu);
	st := sqlite.prepare(s.db, "SELECT size FROM uploads WHERE token = ? AND data IS NULL;");
	defer sqlite.finalize(st);
	sqlite.bind(st, 1, advance(path, "/upload/".count));
	if sqlite.step(st) != .Row return 0;
	return sqlite.col_int(st, 0);
}

// files serves the upload URLs (the CORS preflight, then the PUT), stored attachments (GET
// /attachments/{id}/{key}/{filename}, any query ignored, as media proxy sizes are), and
// DELETE /api/v9/attachments/{upload} for a draft removed before sending.
files :: (c: *Conn, req: http.Request) -> bool {
	s := c.server;
	path := req.path;
	q := find_index_from_left(path, #char "?");
	if q >= 0 path = slice(path, 0, q);
	if begins_with(path, "/upload/") {
		token := advance(path, "/upload/".count);
		if req.method == "OPTIONS" return respond(c, 200, json = false);
		if req.method != "PUT" return json_error(c, 405, 0, "405: Method Not Allowed");
		size := upload_size(s, path);
		if !size || req.body.count != size return json_error(c, 404, 0, "404: Not Found");
		// Discord reads an image's size when it's sent; the client lays images out by it.
		w, h := 0, 0;
		if imagefmt.sniff(req.body) != .Unknown {
			img, ierr := imagefmt.decode_first_frame(req.body, temp, max_pixels = 16 << 20);
			if ierr == .None w, h = img.width, img.height;
		}
		locks.guard(*s.db_mu);
		if !sqlite.run(s.db, "UPDATE uploads SET data = ?, width = ?, height = ? WHERE token = ? AND data IS NULL;", req.body, w, h, token) || sqlite.changes(s.db) != 1 {
			return json_error(c, 404, 0, "404: Not Found");
		}
		return respond(c, 200, json = false);
	}
	// GET /icons/{guild}/{hash}.{ext}: the server icon, whatever the extension and size asked for, as
	// Discord's CDN converts; the random hash is what makes it unguessable, like an attachment's key.
	if begins_with(path, "/icons/") {
		if req.method != "GET" return json_error(c, 405, 0, "405: Method Not Allowed");
		parts := split(advance(path, "/icons/".count), "/",, temp);
		if parts.count != 2 || parts[0] != tprint("%", s.guild) return json_error(c, 404, 0, "404: Not Found");
		hash := parts[1];
		dot := find_index_from_left(hash, #char ".");
		if dot >= 0 hash.count = dot;
		locks.guard(*s.db_mu);
		if !hash || hash != cast(string) meta_get(s, "icon") return json_error(c, 404, 0, "404: Not Found");
		c.reply_status, c.reply_json = 200, false;
		c.reply_type = cast(string) meta_get(s, "icon_type");
		c.reply_body = cast(string) meta_get(s, "icon_data");
		return true;
	}
	// GET /avatars/{user}/{hash}.{ext}: a member's avatar, served the same way as the icon.
	if begins_with(path, "/avatars/") {
		if req.method != "GET" return json_error(c, 405, 0, "405: Method Not Allowed");
		parts := split(advance(path, "/avatars/".count), "/",, temp);
		user, ok := string_to_int(parts[0], T = s64);
		if !ok || parts.count != 2 return json_error(c, 404, 0, "404: Not Found");
		hash := parts[1];
		dot := find_index_from_left(hash, #char ".");
		if dot >= 0 hash.count = dot;
		locks.guard(*s.db_mu);
		st := sqlite.prepare(s.db, "SELECT avatar_type, avatar_data FROM users WHERE id = ? AND avatar = ?;");
		defer sqlite.finalize(st);
		sqlite.bind_all(st, user, hash);
		if sqlite.step(st) != .Row return json_error(c, 404, 0, "404: Not Found");
		c.reply_status, c.reply_json = 200, false;
		c.reply_type = copy_string(sqlite.col_text(st, 0),, temp);
		c.reply_body = copy_string(cast(string) sqlite.col_blob(st, 1),, temp);
		return true;
	}
	// GET /emojis/{id}.{ext}: a custom emoji, whatever the extension and size asked for. Like Discord's, an
	// emoji is public to whoever knows its ID.
	if begins_with(path, "/soundboard-sounds/") {
		if req.method != "GET" return json_error(c, 405, 0, "405: Method Not Allowed");
		return sound_file(c, path);
	}
	if begins_with(path, "/stickers/") {
		if req.method != "GET" return json_error(c, 405, 0, "405: Method Not Allowed");
		return sticker_file(c, path);
	}
	if begins_with(path, "/emojis/") {
		if req.method != "GET" return json_error(c, 405, 0, "405: Method Not Allowed");
		name := advance(path, "/emojis/".count);
		dot := find_index_from_left(name, #char ".");
		if dot >= 0 name.count = dot;
		id, ok := string_to_int(name, T = s64);
		if !ok return json_error(c, 404, 0, "404: Not Found");
		locks.guard(*s.db_mu);
		st := sqlite.prepare(s.db, "SELECT type, data FROM emojis WHERE id = ?;");
		defer sqlite.finalize(st);
		sqlite.bind_all(st, id);
		if sqlite.step(st) != .Row return json_error(c, 404, 0, "404: Not Found");
		c.reply_status, c.reply_json = 200, false;
		c.reply_type = copy_string(sqlite.col_text(st, 0),, temp);
		c.reply_body = copy_string(cast(string) sqlite.col_blob(st, 1),, temp);
		return true;
	}
	if begins_with(path, "/attachments/") {
		if req.method != "GET" return json_error(c, 405, 0, "405: Method Not Allowed");
		parts := split(advance(path, "/attachments/".count), "/",, temp);
		id, ok := string_to_int(parts[0], T = s64);
		if !ok || parts.count < 2 return json_error(c, 404, 0, "404: Not Found");
		locks.guard(*s.db_mu);
		st := sqlite.prepare(s.db, "SELECT content_type, data FROM attachments WHERE id = ? AND key = ?;");
		defer sqlite.finalize(st);
		sqlite.bind_all(st, id, parts[1]);
		if sqlite.step(st) != .Row return json_error(c, 404, 0, "404: Not Found");
		c.reply_status, c.reply_json = 200, false;
		c.reply_type = copy_string(sqlite.col_text(st, 0),, temp);
		c.reply_body = copy_string(cast(string) sqlite.col_blob(st, 1),, temp);
		return true;
	}
	token, _ := http.header_get(req.headers, "authorization");
	user := session_user(c, token);
	if !user return json_error(c, 401, 0, "401: Unauthorized");
	if req.method != "DELETE" return json_error(c, 405, 0, "405: Method Not Allowed");
	locks.guard(*s.db_mu);
	sqlite.run(s.db, "DELETE FROM uploads WHERE token = ? AND user = ?;", advance(path, "/api/v9/attachments/".count), user);
	return respond(c, 204, json = false);
}

// attachments_locked lists a message's files as Discord sends them; the caller holds db_mu.
attachments_locked :: (s: *Server, message: s64) -> etf.Value {
	list: [..]etf.Value;
	list.allocator = temp;
	st := sqlite.prepare(s.db, "SELECT id, key, filename, content_type, size, width, height, description FROM attachments WHERE message = ? ORDER BY id;");
	defer sqlite.finalize(st);
	sqlite.bind(st, 1, message);
	while sqlite.step(st) == .Row {
		id := sqlite.col_int(st, 0);
		name := copy_string(sqlite.col_text(st, 2),, temp);
		url := tprint("https://%/attachments/%/%/%", id_hex(s), id, sqlite.col_text(st, 1), uri_encode(name));
		a := etf.map_builder(9,, temp);
		etf.map_put(*a, "id", snow(id));
		etf.map_put(*a, "filename", etf.vstring(name));
		etf.map_put(*a, "content_type", etf.vstring(copy_string(sqlite.col_text(st, 3),, temp)));
		etf.map_put(*a, "size", etf.vint(sqlite.col_int(st, 4)));
		etf.map_put(*a, "url", etf.vstring(url));
		etf.map_put(*a, "proxy_url", etf.vstring(url));
		w, h := sqlite.col_int(st, 5), sqlite.col_int(st, 6);
		if w && h {
			etf.map_put(*a, "width", etf.vint(w));
			etf.map_put(*a, "height", etf.vint(h));
		}
		description := copy_string(sqlite.col_text(st, 7),, temp);
		if description etf.map_put(*a, "description", etf.vstring(description));
		array_add(*list, etf.vmap(etf.map_done(*a)));
	}
	return etf.vlist(list);
}

uri_encode :: (s: string) -> string {
	HEX :: "0123456789ABCDEF";
	out: [..]u8;
	out.allocator = temp;
	for b: cast([]u8) s {
		if (b >= #char "a" && b <= #char "z") || (b >= #char "A" && b <= #char "Z") || (b >= #char "0" && b <= #char "9") || b == #char "-" || b == #char "." || b == #char "_" {
			array_add(*out, b);
		} else {
			array_add(*out, #char "%", HEX[b >> 4], HEX[b & 15]);
		}
	}
	return cast(string) out;
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
	user := session_user(c, token);
	if !user return json_error(c, 401, 0, "401: Unauthorized");
	v, err := etf.from_json(cast(string) req.body,, temp);
	list: etf.Value;
	if err == .None && v.kind == .Map list, _ = etf.map_get(v.map, "read_states");
	if list.kind != .List || list.list.count > 1000 return json_error(c, 400, 50035, "Invalid Form Body");
	// One entry per channel, the last one sent winning; unknown channels are dropped below.
	acks: Table(s64, s64);
	acks.allocator = temp;
	for list.list {
		if it.kind != .Map continue;
		ch, _ := etf.map_get(it.map, "channel_id");
		m, _ := etf.map_get(it.map, "message_id");
		if ch.kind != .String || m.kind != .String continue;
		channel, cok := string_to_int(ch.s, T = s64);
		message, mok := string_to_int(m.s, T = s64);
		if cok && mok table_set(*acks, channel, message);
	}
	// All in one transaction, so marking a whole server read costs one fsync, not one per channel.
	{
		locks.guard(*s.db_mu);
		ok := sqlite.exec(s.db, "BEGIN;");
		for message, channel: acks {
			if !ok break;
			if channel_type_locked(s, channel) < 0 { remove message; continue; }
			ok = sqlite.run(s.db, "INSERT OR REPLACE INTO read_states(user, channel, last, mentions) VALUES(?, ?, ?, 0);", user, channel, message);
		}
		if !(ok && sqlite.exec(s.db, "COMMIT;")) { sqlite.exec(s.db, "ROLLBACK;"); return json_error(c, 500, 0, "500: Internal Server Error"); }
	}
	for message, channel: acks send_ack(s, user, channel, message, 0, false);
	return respond(c, 204, json = false);
}

// PATCH /api/v9/users/@me/guilds/settings {guilds: {"<id>": {...}}}: mute and notification settings,
// kept per member as the whole user_guild_settings entry. Fields the patch names replace the stored ones;
// channel_overrides comes keyed by channel ID and is merged into the entry's list per channel.
patch_guild_settings :: (c: *Conn, req: http.Request) -> bool {
	s := c.server;
	token, _ := http.header_get(req.headers, "authorization");
	user := session_user(c, token);
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
			e := merge(settings_fields(old_map, channel = false), settings_fields(patch.map, channel = false), "", "");
			etf.map_put(*e, "guild_id", snow(s.guild));
			// Overrides are kept only for channels that exist, one per channel, so a member's row stays
			// as small as the server; one deleted since goes at the next change.
			channels: Table(string, bool);
			channels.allocator = temp;
			st := sqlite.prepare(s.db, "SELECT id FROM channels;");
			while sqlite.step(st) == .Row table_set(*channels, tprint("%", sqlite.col_int(st, 0)), true);
			sqlite.finalize(st);
			kept: Table(string, etf.Value);
			kept.allocator = temp;
			was, _ := etf.map_get(old_map, "channel_overrides");
			changes, _ := etf.map_get(patch.map, "channel_overrides");
			if was.kind == .List for was.list {
				if it.kind != .Map continue;
				id, _ := etf.map_get(it.map, "channel_id");
				if id.kind == .String && table_contains(*channels, id.s) table_set(*kept, id.s, it);
			}
			if changes.kind == .Map for changes.map {
				if it.key.kind != .String || it.value.kind != .Map || !table_contains(*channels, it.key.s) continue;
				before := table_find_pointer(*kept, it.key.s);
				o := merge(ifx before && before.kind == .Map then before.map else .[], it.value.map, "", "");
				table_set(*kept, it.key.s, etf.vmap(etf.map_done(*o)));
			}
			overrides: [..]etf.Value;
			overrides.allocator = temp;
			for o, id: kept {
				f := merge(settings_fields(o.map, channel = true), .[], "", "");
				etf.map_put(*f, "channel_id", etf.vstring(id));
				array_add(*overrides, etf.vmap(etf.map_done(*f)));
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
// settings_fields keeps the user_guild_settings fields Discord has, with their types, once each: a
// guild's, or a channel override's when channel is set (without channel_id).
settings_fields :: (m: etf.Map, channel: bool) -> etf.Map {
	b := etf.map_builder(12,, temp);
	for m {
		if it.key.kind != .String continue;
		k, v := it.key.s, it.value;
		dup := false;
		for p: b.pairs if p.key.s == k dup = true;
		if dup continue;
		ok := false;
		if k == {
			case "muted";
				ok = v.kind == .Bool;
			case "collapsed";
				ok = channel && v.kind == .Bool;
			case "suppress_everyone"; #through;
			case "suppress_roles"; #through;
			case "mobile_push"; #through;
			case "hide_muted_channels"; #through;
			case "mute_scheduled_events";
				ok = !channel && v.kind == .Bool;
			case "message_notifications";
				ok = v.kind == .Int && v.i >= 0 && v.i <= 3;
			case "notify_highlights";
				ok = !channel && v.kind == .Int && v.i >= 0 && v.i <= 2;
			case "flags";
				ok = v.kind == .Int && v.i >= 0 && v.i <= 0xFFFF_FFFF;
			case "mute_config";
				if v.kind == .Nil { ok = true; }
				else if v.kind == .Map {
					w, _ := etf.map_get(v.map, "selected_time_window");
					end, _ := etf.map_get(v.map, "end_time");
					c := etf.map_builder(2,, temp);
					if w.kind == .Int etf.map_put(*c, "selected_time_window", w);
					etf.map_put(*c, "end_time", ifx end.kind == .String && end.s.count <= 40 && text_ok(end.s) then end else etf.Value.{});
					v = etf.vmap(etf.map_done(*c));
					ok = true;
				}
		}
		if ok etf.map_put(*b, k, v);
	}
	return etf.map_done(*b);
}

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
	send_ack(s, user, channel, message, count, is_manual);
	return 0;
}

// send_ack tells a member's gateways that a channel's read state changed.
send_ack :: (s: *Server, user: s64, channel: s64, message: s64, count: int, is_manual: bool) {
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
}

SEARCH_PAGE :: 25;
MAX_SEARCH_IDS :: 25; // Per kind (authors, mentions, channels).

// GET /api/v9/guilds/{id}/messages/search?content=&author_id=&mentions=&channel_id=&has=&pinned=&offset=,
// newest first, 25 a page, as {total_results, messages: [[message], ...]}. Repeated keys of one kind
// match any of them; different kinds must all match. Content matches whole words, all of them.
search :: (c: *Conn, req: http.Request) -> bool {
	s := c.server;
	token, _ := http.header_get(req.headers, "authorization");
	viewer := session_user(c, token);
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
	// Each filter adds to the query at most once and ids are capped, so one request line can't build a
	// query that scans every message thousands of times over under db_mu.
	pinned, has_link, has_other, has_content := false, false, false, false;
	add_id :: (ids: *[..]s64, n: s64, ok: bool) { if ok && ids.count < MAX_SEARCH_IDS array_add_if_unique(ids, n); }
	for split(ifx q >= 0 then slice(req.path, q + 1, req.path.count - q - 1) else "", "&",, temp) {
		kv := split(it, "=",, temp);
		if kv.count != 2 continue;
		value := percent_decode(replace(kv[1], "+", " ",, temp));
		n, n_ok := string_to_int(value, T = s64);
		if kv[0] == {
			case "author_id";  add_id(*authors, n, n_ok);
			case "mentions";   add_id(*mentioned, n, n_ok);
			case "channel_id"; add_id(*channels, n, n_ok);
			case "offset";     if n_ok offset = clamp(n, 0, 5000);
			case "pinned";     if value == "true" pinned = true;
			// Hosted messages carry no attachments, embeds or stickers yet; only links can be had.
			case "has";        if value == "link" has_link = true; else has_other = true;
			case "content";
				if has_content continue;
				has_content = true;
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
	if pinned append(*where, " AND m.pinned_at IS NOT NULL");
	if has_link append(*where, " AND (m.content LIKE '%http://%' OR m.content LIKE '%https://%')");
	if has_other append(*where, " AND 0");
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
MAX_REACTIONS :: 20; // Distinct emoji per message, as on Discord.
MAX_SESSIONS :: 16; // Per member: one per running client, so this many devices at once.

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
		if archived_locked(s, channel) return json_error(c, 400, 50083, "Thread is archived");
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

MAX_MENTIONS_PAGE :: 100;

// GET /users/@me/mentions?limit=&everyone=&before= lists the messages that ping the member, newest first,
// skipping their own and those they dismissed; DELETE /users/@me/mentions/{id} dismisses one.
recent_mentions :: (c: *Conn, req: http.Request) -> bool {
	s := c.server;
	token, _ := http.header_get(req.headers, "authorization");
	viewer := session_user(c, token);
	if !viewer return json_error(c, 401, 0, "401: Unauthorized");
	path, query := req.path, "";
	q := find_index_from_left(path, #char "?");
	if q >= 0 { query = slice(path, q + 1, path.count - q - 1); path = slice(path, 0, q); }
	parts := split(path, "/",, temp); // "", api, v9, users, @me, mentions[, id]
	if req.method == "DELETE" && parts.count == 7 {
		message, ok := string_to_int(parts[6], T = s64);
		if !ok return json_error(c, 404, 10008, "Unknown Message");
		locks.guard(*s.db_mu);
		sqlite.run(s.db, "INSERT OR IGNORE INTO mention_dismissals(user, message) SELECT ?, id FROM messages WHERE id = ?;", viewer, message);
		return respond(c, 204, json = false);
	}
	if req.method != "GET" || parts.count != 6 return json_error(c, 404, 0, "404: Not Found");

	limit, before, everyone := 25, cast(s64) 0x7fff_ffff_ffff_ffff, true;
	for split(query, "&",, temp) {
		kv := split(it, "=",, temp);
		if kv.count != 2 continue;
		n, n_ok := string_to_int(kv[1], T = s64);
		if kv[0] == {
			case "limit";    if n_ok limit = clamp(n, 1, MAX_MENTIONS_PAGE);
			case "before";   if n_ok before = n;
			case "everyone"; everyone = kv[1] != "false";
		}
	}
	found: [..]etf.Value;
	found.allocator = temp;
	{
		locks.guard(*s.db_mu);
		pinged := ifx everyone then "(m.id IN (SELECT message FROM mentions WHERE user = ?1) OR m.everyone = 1)" else "m.id IN (SELECT message FROM mentions WHERE user = ?1)";
		st := sqlite.prepare(s.db, tprint("% WHERE % AND m.author != ?1 AND m.id < ?2 AND m.id NOT IN (SELECT message FROM mention_dismissals WHERE user = ?1) ORDER BY m.id DESC LIMIT %;", MESSAGE_SELECT, pinged, limit));
		sqlite.bind_all(st, viewer, before);
		while sqlite.step(st) == .Row array_add(*found, row_message(s, st, viewer = viewer));
		sqlite.finalize(st);
	}
	return json_reply(c, 200, etf.vlist(found));
}

json_reply :: (c: *Conn, status: int, v: etf.Value) -> bool {
	sb: String_Builder;
	sb.allocator = temp;
	etf.to_json(v, *sb);
	return respond(c, status, builder_to_string(*sb,, temp));
}

// A reaction's emoji from its stored key: a Unicode emoji, or name:id for a custom one.
reaction_emoji :: (key: string, animated: bool) -> etf.Value {
	e := etf.map_builder(3,, temp);
	colon := find_index_from_left(key, #char ":");
	if colon < 0 {
		etf.map_put(*e, "id", .{});
		etf.map_put(*e, "name", etf.vstring(key));
	} else {
		etf.map_put(*e, "id", etf.vstring(advance(key, colon + 1)));
		etf.map_put(*e, "name", etf.vstring(slice(key, 0, colon)));
		etf.map_put(*e, "animated", etf.vbool(animated));
	}
	return etf.vmap(etf.map_done(*e));
}

// PUT .../reactions/{emoji}/@me and DELETE .../reactions/{emoji}/{type}/@me, with a Unicode emoji or one of
// the server's custom ones; members may remove only their own reactions.
reaction :: (c: *Conn, req: http.Request, user: s64, channel: s64, message: s64, rest: []string, query: string) -> bool {
	s := c.server;
	me := rest.count && (rest[rest.count - 1] == "@me" || rest[rest.count - 1] == "%40me");
	add := req.method == "PUT" && rest.count == 2 && me;
	// Removal is .../{emoji}/@me, or .../{emoji}/{user} and .../{emoji}/{0|1}/{user} for the owner's moderation.
	drop := req.method == "DELETE" && (rest.count == 2 || (rest.count == 3 && (rest[1] == "0" || rest[1] == "1")));
	list := req.method == "GET" && rest.count == 1;
	target := user;
	if drop && !me {
		id, ok, after := string_to_int(rest[rest.count - 1], T = s64);
		drop = ok && !after && id > 0;
		target = id;
	}
	if !add && !drop && !list return json_error(c, 404, 0, "404: Not Found");
	if drop && rest.count == 3 && rest[1] == "1" return respond(c, 204, json = false);
	emoji := percent_decode(rest[0]);
	// A custom emoji comes as name:id and is stored so; every Unicode emoji has a byte past ASCII (keycaps
	// end in U+20E3), so plain words are refused.
	custom_id: s64;
	animated := false;
	colon := find_index_from_left(emoji, #char ":");
	emoji_ok := emoji && emoji.count <= 64 && text_ok(emoji);
	if emoji_ok && colon >= 0 {
		id, ok, rest_of := string_to_int(advance(emoji, colon + 1), T = s64);
		emoji_ok = ok && !rest_of && id > 0;
		custom_id = id;
	} else if emoji_ok {
		emoji_ok = false;
		for 0..emoji.count - 1 if emoji[it] >= 0x80 emoji_ok = true;
	}
	if !emoji_ok return json_error(c, 400, 10014, "Unknown Emoji");
	changed := false;
	{
		locks.guard(*s.db_mu);
		if custom_id {
			st := sqlite.prepare(s.db, "SELECT name, animated FROM emojis WHERE id = ?;");
			sqlite.bind_all(st, custom_id);
			found := sqlite.step(st) == .Row;
			if found {
				emoji = tprint("%:%", sqlite.col_text(st, 0), custom_id);
				animated = sqlite.col_int(st, 1) != 0;
			}
			sqlite.finalize(st);
			if !found return json_error(c, 400, 10014, "Unknown Emoji");
		}
		st := sqlite.prepare(s.db, "SELECT 1 FROM messages WHERE id = ? AND channel = ?;");
		sqlite.bind_all(st, message, channel);
		found := sqlite.step(st) == .Row;
		sqlite.finalize(st);
		if !found return json_error(c, 404, 10008, "Unknown Message");
		if target != user && owner_id(s) != user return json_error(c, 403, 50013, "Missing Permissions");
		if !list && archived_locked(s, channel) return json_error(c, 400, 50083, "Thread is archived");
		if list {
			// Who reacted, by user ID as Discord orders them, a page after `after`; no one gives super reactions here.
			limit, after, burst := 25, 0, false;
			for split(query, "&",, temp) {
				kv := split(it, "=",, temp);
				if kv.count != 2 continue;
				if kv[0] == "limit" limit = clamp(string_to_int(kv[1]), 1, 100);
				if kv[0] == "after" after = string_to_int(kv[1], T = s64);
				if kv[0] == "type" burst = kv[1] == "1";
			}
			users: [..]etf.Value;
			users.allocator = temp;
			if !burst {
				st = sqlite.prepare(s.db, "SELECT r.user, u.name FROM reactions r JOIN users u ON u.id = r.user WHERE r.message = ? AND r.emoji = ? AND r.user > ? ORDER BY r.user LIMIT ?;");
				sqlite.bind_all(st, message, emoji, after, limit);
				while sqlite.step(st) == .Row array_add(*users, user_value(s, sqlite.col_int(st, 0), copy_string(sqlite.col_text(st, 1),, temp)));
				sqlite.finalize(st);
			}
			return json_reply(c, 200, etf.vlist(users));
		}
		if add {
			st = sqlite.prepare(s.db, "SELECT count(DISTINCT emoji), sum(emoji = ?) FROM reactions WHERE message = ?;");
			sqlite.bind_all(st, emoji, message);
			kinds, has := 0, 0;
			if sqlite.step(st) == .Row kinds, has = sqlite.col_int(st, 0), sqlite.col_int(st, 1);
			sqlite.finalize(st);
			if !has && kinds >= MAX_REACTIONS return json_error(c, 400, 30010, "Maximum number of reactions reached (20)");
		}
		sql := ifx add then "INSERT OR IGNORE INTO reactions(message, emoji, user) VALUES(?, ?, ?);" else "DELETE FROM reactions WHERE message = ? AND emoji = ? AND user = ?;";
		if !sqlite.run(s.db, sql, message, emoji, target) return json_error(c, 500, 0, "500: Internal Server Error");
		changed = sqlite.changes(s.db) > 0;
	}
	if changed {
		d := etf.map_builder(7,, temp);
		etf.map_put(*d, "user_id", snow(target));
		etf.map_put(*d, "channel_id", snow(channel));
		etf.map_put(*d, "message_id", snow(message));
		etf.map_put(*d, "guild_id", snow(s.guild));
		etf.map_put(*d, "emoji", reaction_emoji(emoji, animated));
		etf.map_put(*d, "burst", etf.vbool(false));
		etf.map_put(*d, "type", etf.vint(0));
		broadcast(s, ifx add then "MESSAGE_REACTION_ADD" else "MESSAGE_REACTION_REMOVE", etf.vmap(etf.map_done(*d)));
	}
	return respond(c, 204, json = false);
}

// text_ok: s is well-formed UTF-8 (no overlongs, surrogates or bytes past U+10FFFF) with no control
// characters, other than newlines and tabs where lines is set.
// Discord caps content in UTF-16 units, as JavaScript counts: a character outside the BMP counts 2.
// Count only after text_ok has checked the UTF-8.
MAX_CONTENT :: 2000;
utf16_units :: (s: string) -> int {
	n := 0;
	for i: 0..s.count-1 {
		b := s[i];
		if (b & 0xC0) == 0x80 continue;
		n += ifx b >= 0xF0 then 2 else 1;
	}
	return n;
}

content_too_long :: (c: *Conn) -> bool {
	return respond(c, 400, tprint("{\"message\": \"Invalid Form Body\", \"code\": 50035, \"errors\": {\"content\": {\"_errors\": [{\"code\": \"BASE_TYPE_MAX_LENGTH\", \"message\": \"Must be % or fewer in length.\"}]}}}", MAX_CONTENT));
}

text_ok :: (s: string, lines := false) -> bool {
	i := 0;
	while i < s.count {
		b := s[i];
		if b < 0x80 {
			if (b < 0x20 || b == 0x7F) && !(lines && (b == #char "\n" || b == #char "\t")) return false;
			i += 1;
			continue;
		}
		n, cp: int;
		if b >= 0xC2 && b <= 0xDF      n, cp = 2, b & 0x1F;
		else if b >= 0xE0 && b <= 0xEF n, cp = 3, b & 0x0F;
		else if b >= 0xF0 && b <= 0xF4 n, cp = 4, b & 0x07;
		else return false;
		if i + n > s.count return false;
		for 1..n - 1 {
			cb := s[i + it];
			if cb & 0xC0 != 0x80 return false;
			cp = (cp << 6) | (cb & 0x3F);
		}
		if (n == 3 && cp < 0x800) || (n == 4 && (cp < 0x10000 || cp > 0x10FFFF)) || (cp >= 0xD800 && cp <= 0xDFFF) return false;
		if cp >= 0x80 && cp < 0xA0 return false; // C1 controls.
		i += n;
	}
	return true;
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
		end_writer(c, ws);
		if was {
			voice_leave(c.server, was, c);
			broadcast(c.server, "GUILD_MEMBER_LIST_UPDATE", member_list_value(c.server));
		}
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
		// A compressed term would inflate up to 64 MiB from one small frame, and clients never send one.
		if msg.count > 1 && msg[1] == xx etf.Tag.Compressed { http.ws_close(ws, 4002, "Error while decoding payload."); return; }
		v, derr := etf.decode(msg,, temp);
		if derr != .None || v.kind != .Map { http.ws_close(ws, 4002, "Error while decoding payload."); return; }
		op, _ := etf.map_get(v.map, "op");
		d, _ := etf.map_get(v.map, "d");
		if op.kind != .Int { http.ws_close(ws, 4002, "Error while decoding payload."); return; }
		if op.i == {
			case 1; #through;
			case 40; // The official client heartbeats with op 40 (with QoS data).
				if !send(ws, 11, .{}) return;
				archive_idle(c.server);
			case 2;
				if c.ws { http.ws_close(ws, 4005, "Already authenticated."); return; }
				token: etf.Value;
				if d.kind == .Map token, _ = etf.map_get(d.map, "token");
				user, name := session_user(c, ifx token.kind == .String then token.s else "");
				if !user { http.ws_close(ws, 4004, "Authentication failed."); return; }
				// Registered before READY is built and sent under c.mu, so a message posted meanwhile
				// arrives after READY instead of being lost. Lock order: server.mu, then c.mu.
				presence: etf.Value;
				if d.kind == .Map presence, _ = etf.map_get(d.map, "presence");
				locks.lock(*c.server.mu);
				c.ws = ws;
				c.user = user;
				crypto.random_bytes(c.session);
				set_presence_locked(c.server, c, presence, identify = true);
				locks.lock(*c.mu);
				locks.unlock(*c.server.mu);
				c.seq += 1;
				ok := queue(c, frame(0, ready_value(c.server, user, name, c.session), c.seq, "READY"));
				locks.unlock(*c.mu);
				if !ok return;
				broadcast(c.server, "GUILD_MEMBER_LIST_UPDATE", member_list_value(c.server));
			case 37; // Guild subscriptions: there is one guild and one list, so any subscription gets all of it.
				if c.ws && !dispatch(c, "GUILD_MEMBER_LIST_UPDATE", member_list_value(c.server)) return;
			case 3;
				if !c.ws continue;
				locks.lock(*c.server.mu);
				changed := set_presence_locked(c.server, c, d);
				locks.unlock(*c.server.mu);
				if changed broadcast(c.server, "GUILD_MEMBER_LIST_UPDATE", member_list_value(c.server));
			case 4;
				if c.ws voice_state_update(c, d);
			case 18; #through;
			case 19; #through;
			case 20; // Go Live: create, delete and watch.
				if c.ws stream_op(c, op.i, d);
			case 6; // No resume: an invalid session makes the client identify again.
				if !send(ws, 9, etf.vbool(false)) return;
			case; // The rest are Discord-only; ignore them.
		}
	}
}

// end_writer stops c's writer thread and frees what it hadn't sent, then ws.
end_writer :: (c: *Conn, ws: *http.Ws_Conn) {
	locks.lock(*c.mu);
	c.closing = true;
	locks.cond_signal(*c.wake);
	locks.unlock(*c.mu);
	locks.join(c.writer);
	for c.out free(it.data,, context.default_allocator);
	array_free(c.out);
	http.ws_destroy(ws);
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
