/// End-to-end encrypted DMs (TODO.md E2E 1-8). E2E 1: the client database `<state>/fastcord.db` on its own thread.
#import "Basic";
#import "Atomics";
#import "Thread";
#import "File";
#import "String";
crypto :: #import "crypto";
keys :: #import "keys";
locks :: #import "locks";
sqlite :: #import "sqlite";
#load "protocol.jai";

// A Job runs on the database thread, in the order submitted, so a write submitted before a send is
// committed before anything submitted after it runs. Embed it with #as and add the job's own fields:
// the caller owns the memory and may free it once done is set.
Job :: struct {
	run: (d: *Db, job: *Job); // d.sql is the open database.
	done: s32;
	failed: bool; // The database couldn't be opened: run was skipped.
}

Db :: struct {
	path: string;
	wake: (); // Called on the database thread after each job, e.g. to request a UI frame.
	thread: *Thread;
	mu: locks.Mutex;
	cond: locks.Cond;
	queue: [..]*Job;
	stopping: bool;
	stopped: s32;
	error: string; // Set by the database thread before it marks jobs failed; read it after a job's done.
	sql: *sqlite.DB; // This and seal belong to the database thread.
	seal: crypto.Aead;
}

// start opens path (":memory:" for headless runs) on a new thread and migrates it. It never waits on disk.
start :: (path: string, wake: () = null) -> *Db {
	d := New(Db);
	d.path = copy_string(path);
	d.wake = wake;
	d.thread = New(Thread);
	d.thread.data = d;
	thread_init(d.thread, (t: *Thread) -> s64 { loop(cast(*Db) t.data); return 0; });
	thread_start(d.thread);
	return d;
}

submit :: (d: *Db, job: *Job) {
	assert(job.run != null);
	locks.guard(*d.mu);
	assert(!d.stopping, "e2e.submit after stop");
	array_add(*d.queue, job);
	locks.cond_signal(*d.cond);
}

is_done :: (job: *Job) -> bool { return atomic_load(*job.done) != 0; }

// stop runs the jobs already queued, checkpoints the WAL into the main file and closes it.
// Poll stopped, then free with destroy.
stop :: (d: *Db) {
	locks.guard(*d.mu);
	d.stopping = true;
	locks.cond_signal(*d.cond);
}

stopped :: (d: *Db) -> bool { return atomic_load(*d.stopped) != 0; }

destroy :: (d: *Db) {
	assert(stopped(d));
	thread_deinit(d.thread);
	free(d.thread);
	free(d.path);
	free(d.error);
	array_free(d.queue);
	free(d);
}

// ---- Requests: the E2E operations, each one job on the database thread ----

Op :: enum u8 {
	Load;          // channel -> encrypted, has_session, and the peer's has_peer, peer_root, verified, key_changed
	Set_Encrypted; // channel, encrypted
	Set_Verified;  // peer, peer_root, verified: marks the root verified or not, and clears key_changed
	Hello;         // channel, me -> packet
	Accept;        // channel, peer, me, me_user, text = the Hello packet -> packet
	Send;          // channel, me, text = plaintext -> packet, or result No_Session / Too_Long
	Sent;          // text = a packet handed to Discord: drop it from the outbox
	Receive;       // channel, author, message, me, text = the message content -> result, content, out_text
	Outbox;        // -> outbox: packets committed but never handed to Discord, to send again after a crash
}

Result :: enum u8 {
	Ok;
	Hello;         // A Hello; accepted is set when a session answers it.
	Undecryptable;
	Repeated;      // The same packet already arrived as another message: a replay or a duplicate send.
	No_Session;    // A Msg whose Init hasn't been seen yet: retry after a new session appears.
	Too_Long;
	Failed;
}

Outbox_Item :: struct { channel: u64; packet: string; }

// The caller fills the inputs, submits, and once done reads the outputs and calls free_request.
Request :: struct {
	#as using job: Job;
	op: Op;
	me: Identity;
	me_user: u64; // Our Discord user ID.
	channel, peer, author, message: u64;
	text: string;
	encrypted: bool;
	verified: bool;
	peer_root: [32]u8;

	result: Result;
	content: Content;
	out_text: string;
	packet: string;
	has_session: bool;
	accepted: bool;
	has_peer: bool;
	key_changed: bool; // Load: the peer's root replaced an earlier one. Receive: a Hello with a root other than the peer's.
	outbox: [..]Outbox_Item;
}

// request makes a heap Request owning a copy of text.
request :: (op: Op, channel: u64 = 0, text := "") -> *Request {
	r := New(Request);
	r.op, r.channel, r.text = op, channel, copy_string(text);
	r.run = (d: *Db, j: *Job) { run_request(d, cast(*Request) j); };
	return r;
}

free_request :: (r: *Request) {
	crypto.zero(*r.me);
	free(r.text);
	free(r.out_text);
	free(r.packet);
	for r.outbox free(it.packet);
	array_free(r.outbox);
	free(r);
}

#scope_file

// Each entry moves the schema up one version (PRAGMA user_version). Never edit a shipped entry; append.
MIGRATIONS :: string.[
	"CREATE TABLE meta(key TEXT PRIMARY KEY, value BLOB NOT NULL) WITHOUT ROWID;",
	#string SQL
CREATE TABLE channels(id INTEGER PRIMARY KEY, encrypted INTEGER NOT NULL);
CREATE TABLE prekeys(hello_id BLOB PRIMARY KEY, channel INTEGER NOT NULL, spk BLOB NOT NULL, pq BLOB NOT NULL, created INTEGER NOT NULL) WITHOUT ROWID;
CREATE TABLE sessions(id BLOB PRIMARY KEY, channel INTEGER NOT NULL, peer INTEGER NOT NULL, peer_root BLOB NOT NULL, hello_id BLOB NOT NULL,
	state BLOB NOT NULL, updated INTEGER NOT NULL) WITHOUT ROWID;
CREATE INDEX sessions_channel ON sessions(channel, updated);
CREATE INDEX sessions_hello ON sessions(hello_id);
CREATE TABLE skipped(session BLOB NOT NULL, dh BLOB NOT NULL, n INTEGER NOT NULL, mk BLOB NOT NULL, PRIMARY KEY(session, dh, n));
CREATE TABLE plaintexts(hash BLOB PRIMARY KEY, message INTEGER NOT NULL, content INTEGER NOT NULL, text TEXT NOT NULL) WITHOUT ROWID;
CREATE TABLE outbox(hash BLOB PRIMARY KEY, channel INTEGER NOT NULL, packet TEXT NOT NULL) WITHOUT ROWID;
SQL,
	"ALTER TABLE prekeys ADD COLUMN answered INTEGER NOT NULL DEFAULT 0;",
	// Secrets sealed under the database key (seal). Never shipped unsealed, so the old rows just go.
	#string SQL
DROP TABLE prekeys;
CREATE TABLE prekeys(hello_id BLOB PRIMARY KEY, channel INTEGER NOT NULL, sealed BLOB NOT NULL, created INTEGER NOT NULL,
	answered INTEGER NOT NULL DEFAULT 0) WITHOUT ROWID;
DELETE FROM sessions;
DROP TABLE skipped;
CREATE TABLE skipped(session BLOB NOT NULL, dh BLOB NOT NULL, n INTEGER NOT NULL, sealed BLOB NOT NULL, PRIMARY KEY(session, dh, n));
DROP TABLE plaintexts;
CREATE TABLE plaintexts(hash BLOB PRIMARY KEY, message INTEGER NOT NULL, sealed BLOB NOT NULL) WITHOUT ROWID;
DELETE FROM outbox;
SQL,
	// Each peer's latest identity root: verified once safety numbers were compared, changed when a new root
	// replaced the one before.
	"CREATE TABLE peers(user INTEGER PRIMARY KEY, root BLOB NOT NULL, verified INTEGER NOT NULL DEFAULT 0, changed INTEGER NOT NULL DEFAULT 0);",
];

// A session keeps at most this many skipped message keys; the oldest go first.
MAX_SKIPPED_STORED :: 2000;

// A Hello's prekeys are deleted a day after its first Init (leaving time for an Accept from another of
// the peer's devices), or a week after it was sent if no one answered.
PREKEY_ANSWERED_MS :: 24 * 3600 * 1000;
PREKEY_UNANSWERED_MS :: 7 * 24 * 3600 * 1000;

prune_prekeys :: (db: *sqlite.DB) {
	now := now_ms();
	sqlite.run(db, "DELETE FROM prekeys WHERE created < ? OR (answered != 0 AND answered < ?);", now - PREKEY_UNANSWERED_MS, now - PREKEY_ANSWERED_MS);
}

run_request :: (d: *Db, r: *Request) {
	db := d.sql;
	if r.op == {
		case .Load;
			r.encrypted = query_int(db, "SELECT encrypted FROM channels WHERE id = ?;", r.channel) == 1;
			r.has_session = query_int(db, "SELECT 1 FROM sessions WHERE channel = ? LIMIT 1;", r.channel) == 1;
			st := sqlite.prepare(db, "SELECT p.user, p.root, p.verified, p.changed FROM sessions s JOIN peers p ON p.user = s.peer WHERE s.channel = ? ORDER BY s.updated DESC LIMIT 1;");
			if sqlite.bind_all(st, r.channel) && sqlite.step(st) == .Row && sqlite.col_blob(st, 1).count == 32 {
				r.has_peer, r.peer = true, cast(u64) sqlite.col_int(st, 0);
				memcpy(r.peer_root.data, sqlite.col_blob(st, 1).data, 32);
				r.verified, r.key_changed = sqlite.col_int(st, 2) != 0, sqlite.col_int(st, 3) != 0;
			}
			sqlite.finalize(st);
		case .Set_Encrypted;
			if !set_encrypted(db, r.channel, r.encrypted) r.result = .Failed;
		case .Set_Verified;
			// Only the root the person compared: one that changed meanwhile stays unverified and flagged.
			if !sqlite.run(db, "UPDATE peers SET verified = ?, changed = 0 WHERE user = ? AND root = ?;", r.verified, r.peer, cast([]u8) r.peer_root)
				r.result = .Failed;
		case .Hello;
			prune_prekeys(db);
			p: Packet;
			pre := make_hello(r.me, *p);
			defer crypto.zero(*pre);
			id := crypto.blake3(bytes(*p));
			ok := sqlite.exec(db, "BEGIN;")
				&& sqlite.run(db, "INSERT INTO prekeys(hello_id, channel, sealed, created) VALUES(?, ?, ?, ?);",
					cast([]u8) id, r.channel, seal(d, ad("prekeys", id), *pre), now_ms())
				&& set_encrypted(db, r.channel, true)
				&& sqlite.exec(db, "COMMIT;");
			if !ok { sqlite.exec(db, "ROLLBACK;"); r.result = .Failed; return; }
			r.packet = encode_text(bytes(*p),, context.default_allocator);
		case .Accept;
			hp: Packet;
			if !decode_text(r.text, *hp) { r.result = .Failed; return; }
			hello, ok := parse_hello(bytes(*hp));
			if !ok || r.peer == 0 || r.me_user == 0 { r.result = .Failed; return; }
			p: Packet;
			s: Session;
			s, ok = accept(r.me, hello, .{r.channel, r.me_user, r.peer}, pad(.Accept, "", INIT_PLAINTEXT), *p);
			defer crypto.zero(*s);
			if !ok { r.result = .Failed; return; }
			r.packet = encode_text(bytes(*p),, context.default_allocator);
			if !commit_sent(d, r, *s, true, hello.root, hello.id, .Accept, "") r.result = .Failed;
		case .Send;
			if r.text.count > MAX_TEXT_BYTES { r.result = .Too_Long; return; }
			st := sqlite.prepare(db, "SELECT id, state FROM sessions WHERE channel = ? ORDER BY updated DESC LIMIT 1;");
			s: Session;
			found := sqlite.bind_all(st, r.channel) && sqlite.step(st) == .Row
				&& unseal(d, ad("sessions", sqlite.col_blob(st, 0)), sqlite.col_blob(st, 1), *s);
			sqlite.finalize(st);
			defer crypto.zero(*s);
			if !found { r.result = .No_Session; return; }
			p: Packet;
			p.count = 0;
			pt := pad(.Text, r.text);
			defer crypto.zero(pt);
			head: [2]u8 = .[VERSION, xx Kind.Msg];
			memcpy(p.data.data, head.data, 2);
			memcpy(p.data.data + 2, s.id.data, 16);
			p.count = MSG_PREFIX_BYTES;
			if !encrypt(*s, pt, *p) { r.result = .Failed; return; }
			r.packet = encode_text(bytes(*p),, context.default_allocator);
			none: [32]u8;
			if !commit_sent(d, r, *s, false, none, none, .Text, r.text) r.result = .Failed;
		case .Sent;
			sqlite.run(db, "DELETE FROM outbox WHERE hash = ?;", cast([]u8) crypto.blake3(xx r.text));
		case .Receive;
			receive(d, r);
		case .Outbox;
			st := sqlite.prepare(db, "SELECT channel, packet FROM outbox;");
			while sqlite.step(st) == .Row
				array_add(*r.outbox, .{cast(u64) sqlite.col_int(st, 0), copy_string(sqlite.col_text(st, 1))});
			sqlite.finalize(st);
	}
}

// commit_sent stores the advanced session, our plaintext and the outbox entry in one transaction, before
// the packet can leave: a crash after the send but before the save would encrypt the next message with
// the same key.
commit_sent :: (d: *Db, r: *Request, s: *Session, new: bool, peer_root: [32]u8, hello_id: [32]u8, content: Content, text: string) -> bool {
	db := d.sql;
	hash := crypto.blake3(xx r.packet);
	ok := sqlite.exec(db, "BEGIN;")
		&& (ifx new then sqlite.run(db, "INSERT INTO sessions(id, channel, peer, peer_root, hello_id, state, updated) VALUES(?, ?, ?, ?, ?, ?, ?);",
				cast([]u8) s.id, r.channel, r.peer, cast([]u8) peer_root, cast([]u8) hello_id, seal(d, ad("sessions", s.id), s), now_ms())
			else sqlite.run(db, "UPDATE sessions SET state = ?, updated = ? WHERE id = ?;", seal(d, ad("sessions", s.id), s), now_ms(), cast([]u8) s.id))
		&& store_plaintext(d, hash, 0, content, text)
		&& sqlite.run(db, "INSERT INTO outbox(hash, channel, packet) VALUES(?, ?, ?);", cast([]u8) hash, r.channel, r.packet)
		&& (!new || (set_encrypted(db, r.channel, true) && note_peer(db, r.peer, peer_root)))
		&& sqlite.exec(db, "COMMIT;");
	if !ok { log_error("e2e: cannot save a sent message: %", sqlite.errmsg(db)); sqlite.exec(db, "ROLLBACK;"); }
	return ok;
}

receive :: (d: *Db, r: *Request) {
	db := d.sql;
	hash := crypto.blake3(xx r.text);
	st := sqlite.prepare(db, "SELECT message, sealed FROM plaintexts WHERE hash = ?;");
	if sqlite.bind_all(st, cast([]u8) hash) && sqlite.step(st) == .Row {
		first := cast(u64) sqlite.col_int(st, 0);
		b := sqlite.col_blob(st, 1);
		pt := NewArray(max(b.count - SEAL_BYTES, 0), u8,, temp);
		ok := unseal(d, ad("plaintexts", hash), b, pt) && take_plaintext(r, pt, stored = true);
		crypto.zero(pt);
		sqlite.finalize(st);
		if !ok { r.result = .Failed; return; }
		if first == 0 && r.author != r.me_user {
			r.result = .Repeated; // Our unclaimed packet, reposted by someone else.
		} else if first == 0 {
			// Our own send coming back from Discord: it claims the plaintext and leaves the outbox.
			sqlite.run(db, "UPDATE plaintexts SET message = ? WHERE hash = ?;", r.message, cast([]u8) hash);
			sqlite.run(db, "DELETE FROM outbox WHERE hash = ?;", cast([]u8) hash);
		} else if first != r.message {
			r.result = .Repeated;
		}
		return;
	}
	sqlite.finalize(st);

	p: Packet;
	if !decode_text(r.text, *p) || p.data[0] != VERSION { r.result = .Undecryptable; return; }
	kind := cast(Kind) p.data[1];
	if kind == {
		case .Hello;
			hello, ok := parse_hello(bytes(*p));
			if !ok { r.result = .Undecryptable; return; }
			r.result = .Hello;
			r.accepted = query_int(db, "SELECT 1 FROM sessions WHERE hello_id = ? LIMIT 1;", cast([]u8) hello.id) == 1;
			r.key_changed = query_int(db, "SELECT 1 FROM peers WHERE user = ? AND root != ?;", r.author, cast([]u8) hello.root) == 1;
		case .Init;
			i, ok := parse_init(bytes(*p));
			if !ok || r.author == r.me_user { r.result = .Undecryptable; return; }
			if query_int(db, "SELECT 1 FROM sessions WHERE id = ?;", cast([]u8) i.session) == 1 { r.result = .Repeated; return; }
			st := sqlite.prepare(db, "SELECT sealed FROM prekeys WHERE hello_id = ? AND channel = ?;");
			pre: Prekeys;
			found := sqlite.bind_all(st, cast([]u8) i.hello_id, r.channel) && sqlite.step(st) == .Row
				&& unseal(d, ad("prekeys", i.hello_id), sqlite.col_blob(st, 0), *pre);
			sqlite.finalize(st);
			defer crypto.zero(*pre);
			if !found { r.result = .Undecryptable; return; }
			s: Session;
			s, ok = receive_init(r.me, pre, i, .{r.channel, r.author, r.me_user});
			defer crypto.zero(*s);
			if !ok { r.result = .Undecryptable; return; }
			skipped: [..]Skipped;
			skipped.allocator = temp;
			pt := NewArray(i.message.count - HEADER_BYTES - TAG_BYTES, u8,, temp);
			if !decrypt(*s, i.message, pt, *skipped) || !take_plaintext(r, pt) { r.result = .Undecryptable; return; }
			ok = sqlite.exec(db, "BEGIN;")
				&& sqlite.run(db, "INSERT INTO sessions(id, channel, peer, peer_root, hello_id, state, updated) VALUES(?, ?, ?, ?, ?, ?, ?);",
					cast([]u8) s.id, r.channel, r.author, cast([]u8) i.root, cast([]u8) i.hello_id, seal(d, ad("sessions", s.id), *s), now_ms())
				&& store_skipped(d, s.id, skipped)
				&& store_plaintext(d, hash, r.message, r.content, r.out_text)
				&& set_encrypted(db, r.channel, true)
				&& note_peer(db, r.author, i.root)
				&& sqlite.run(db, "UPDATE prekeys SET answered = ? WHERE hello_id = ? AND answered = 0;", now_ms(), cast([]u8) i.hello_id)
				&& sqlite.exec(db, "COMMIT;");
			crypto.zero(cast([]u8) pt);
			if !ok { sqlite.exec(db, "ROLLBACK;"); r.result = .Failed; }
			prune_prekeys(db);
		case .Msg;
			if p.count < MSG_PREFIX_BYTES + HEADER_BYTES + TAG_BYTES + 1 { r.result = .Undecryptable; return; }
			id: [16]u8;
			memcpy(id.data, p.data.data + 2, 16);
			m := array_view(bytes(*p), MSG_PREFIX_BYTES, p.count - MSG_PREFIX_BYTES);
			st := sqlite.prepare(db, "SELECT state FROM sessions WHERE id = ? AND channel = ? AND peer = ?;");
			s: Session;
			found := sqlite.bind_all(st, cast([]u8) id, r.channel, r.author) && sqlite.step(st) == .Row
				&& unseal(d, ad("sessions", id), sqlite.col_blob(st, 0), *s);
			sqlite.finalize(st);
			defer crypto.zero(*s);
			if !found { r.result = ifx r.author == r.me_user then .Undecryptable else .No_Session; return; }
			h, hok := parse_header(m);
			if !hok { r.result = .Undecryptable; return; }
			pt := NewArray(m.count - HEADER_BYTES - TAG_BYTES, u8,, temp);
			defer crypto.zero(cast([]u8) pt);
			st = sqlite.prepare(db, "SELECT sealed FROM skipped WHERE session = ? AND dh = ? AND n = ?;");
			mk: [32]u8;
			has_mk := sqlite.bind_all(st, cast([]u8) id, cast([]u8) h.dh, cast(s64) h.n) && sqlite.step(st) == .Row
				&& unseal(d, skipped_ad(id, h.dh, h.n), sqlite.col_blob(st, 0), *mk);
			sqlite.finalize(st);
			defer crypto.zero(*mk);
			ok: bool;
			if has_mk {
				if !decrypt_skipped(*s, mk, m, pt) || !take_plaintext(r, pt) { r.result = .Undecryptable; return; }
				ok = sqlite.exec(db, "BEGIN;")
					&& sqlite.run(db, "DELETE FROM skipped WHERE session = ? AND dh = ? AND n = ?;", cast([]u8) id, cast([]u8) h.dh, cast(s64) h.n)
					&& store_plaintext(d, hash, r.message, r.content, r.out_text)
					&& sqlite.exec(db, "COMMIT;");
			} else {
				next := s;
				defer crypto.zero(*next);
				skipped: [..]Skipped;
				skipped.allocator = temp;
				if !decrypt(*next, m, pt, *skipped) || !take_plaintext(r, pt) { r.result = .Undecryptable; return; }
				ok = sqlite.exec(db, "BEGIN;")
					&& sqlite.run(db, "UPDATE sessions SET state = ?, updated = ? WHERE id = ?;", seal(d, ad("sessions", id), *next), now_ms(), cast([]u8) id)
					&& store_skipped(d, id, skipped)
					&& store_plaintext(d, hash, r.message, r.content, r.out_text)
					&& sqlite.exec(db, "COMMIT;");
				for * skipped crypto.zero(*it.mk);
			}
			if !ok { sqlite.exec(db, "ROLLBACK;"); r.result = .Failed; }
		case;
			r.result = .Undecryptable;
	}
}

// take_plaintext splits off the Content byte, and the padding of one just decrypted. Text must be UTF-8,
// since it goes to the markdown parser.
take_plaintext :: (r: *Request, padded: []u8, stored := false) -> bool {
	pt, ok := padded, true;
	if !stored pt, ok = unpad(padded);
	if !ok || pt.count < 1 || pt[0] > xx Content.Accept return false;
	r.content = xx pt[0];
	text := to_string(pt.data + 1, pt.count - 1);
	if !valid_utf8(text) || (r.content == .Accept && text.count) return false;
	r.out_text = copy_string(text);
	return true;
}

// A plaintext is sealed as the Content byte then the text, the form take_plaintext reads.
store_plaintext :: (d: *Db, hash: [32]u8, message: u64, content: Content, text: string) -> bool {
	pt := NewArray(text.count + 1, u8, false,, temp);
	defer crypto.zero(pt);
	pt[0] = xx content;
	memcpy(pt.data + 1, text.data, text.count);
	return sqlite.run(d.sql, "INSERT INTO plaintexts(hash, message, sealed) VALUES(?, ?, ?);", cast([]u8) hash, message, seal(d, ad("plaintexts", hash), pt));
}

store_skipped :: (d: *Db, session: [16]u8, skipped: []Skipped) -> bool {
	for * skipped {
		if !sqlite.run(d.sql, "INSERT OR REPLACE INTO skipped(session, dh, n, sealed) VALUES(?, ?, ?, ?);", cast([]u8) session, cast([]u8) it.dh, cast(s64) it.n,
				seal(d, skipped_ad(session, it.dh, it.n), *it.mk))
			return false;
	}
	if !skipped.count return true;
	return sqlite.run(d.sql, "DELETE FROM skipped WHERE session = ?1 AND rowid NOT IN (SELECT rowid FROM skipped WHERE session = ?1 ORDER BY rowid DESC LIMIT ?2);",
		cast([]u8) session, MAX_SKIPPED_STORED);
}

// note_peer records the root a new session was made with. A root other than the peer's last one loses
// any verification and is flagged until the person verifies or dismisses it.
note_peer :: (db: *sqlite.DB, user: u64, root: [32]u8) -> bool {
	return sqlite.run(db, "INSERT INTO peers(user, root) VALUES(?, ?) ON CONFLICT(user) DO UPDATE SET root = excluded.root, verified = 0, changed = 1 WHERE peers.root != excluded.root;",
		user, cast([]u8) root);
}

set_encrypted :: (db: *sqlite.DB, channel: u64, on: bool) -> bool {
	return sqlite.run(db, "INSERT INTO channels(id, encrypted) VALUES(?, ?) ON CONFLICT(id) DO UPDATE SET encrypted = excluded.encrypted;", channel, on);
}

// Secret columns hold sealed values: a random XChaCha20-Poly1305 nonce, then ciphertext and tag under the
// database key (unlock). The AD names the table and the row, so a value moved to another row won't open.
NONCE_BYTES :: 24;
SEAL_BYTES :: NONCE_BYTES + 16;

seal :: (d: *Db, ad: []u8, pt: []u8) -> []u8 {
	out := NewArray(SEAL_BYTES + pt.count, u8, false,, temp);
	crypto.random_bytes(array_view(out, 0, NONCE_BYTES));
	ok := crypto.seal(*d.seal, array_view(out, NONCE_BYTES, pt.count), array_view(out, NONCE_BYTES + pt.count, 16), array_view(out, 0, NONCE_BYTES), ad, pt);
	assert(ok);
	return out;
}
seal :: (d: *Db, ad: []u8, x: *$T) -> []u8 { return seal(d, ad, .{size_of(T), cast(*u8) x}); }

unseal :: (d: *Db, ad: []u8, b: []u8, out: []u8) -> bool {
	if b.count != SEAL_BYTES + out.count return false;
	ok := crypto.open(*d.seal, out, array_view(b, 0, NONCE_BYTES), ad, array_view(b, NONCE_BYTES, out.count), array_view(b, NONCE_BYTES + out.count, 16));
	if !ok crypto.zero(out);
	return ok;
}
unseal :: (d: *Db, ad: []u8, b: []u8, x: *$T) -> bool { return unseal(d, ad, b, .{size_of(T), cast(*u8) x}); }

ad :: (table: string, row: []u8) -> []u8 {
	out := NewArray(table.count + row.count, u8, false,, temp);
	memcpy(out.data, table.data, table.count);
	memcpy(out.data + table.count, row.data, row.count);
	return out;
}

skipped_ad :: (session: [16]u8, dh: [32]u8, n: u32) -> []u8 {
	row: [16 + 32 + 4]u8;
	memcpy(row.data, session.data, 16);
	memcpy(row.data + 16, dh.data, 32);
	memcpy(row.data + 48, *n, 4);
	return ad("skipped", row);
}

// unlock loads the database key, wrapped for this OS user (keys.wrap_secret), or makes one on first run.
// It returns false with sealed set when the key is there but won't unwrap: a <state> copied from another
// machine or user.
unlock :: (d: *Db) -> ok: bool, sealed: bool {
	key: [32]u8;
	defer crypto.zero(*key);
	st := sqlite.prepare(d.sql, "SELECT value FROM meta WHERE key = 'db_key';");
	if !st return false, false;
	if sqlite.step(st) == .Row {
		b := sqlite.col_blob(st, 0);
		plain, ok := keys.unwrap_secret(b);
		ok &&= plain.count == 32;
		if ok memcpy(key.data, plain.data, 32);
		if plain.data != b.data { crypto.zero(plain); array_free(plain); }
		sqlite.finalize(st);
		if !ok return false, true;
	} else {
		sqlite.finalize(st);
		crypto.random_bytes(key);
		wrapped, ok := keys.wrap_secret(key);
		ok &&= sqlite.run(d.sql, "INSERT INTO meta(key, value) VALUES('db_key', ?);", wrapped);
		if wrapped.data != key.data array_free(wrapped);
		if !ok return false, false;
	}
	return crypto.aead_init(*d.seal, .XCHACHA20_POLY1305, key), false;
}

query_int :: (db: *sqlite.DB, sql: string, args: ..Any) -> s64 {
	st := sqlite.prepare(db, sql);
	v: s64 = -1;
	if sqlite.bind_all(st, ..args) && sqlite.step(st) == .Row v = sqlite.col_int(st, 0);
	sqlite.finalize(st);
	return v;
}

now_ms :: () -> s64 { return to_milliseconds(current_time_consensus()); }

valid_utf8 :: (s: string) -> bool {
	i := 0;
	while i < s.count {
		c := s[i];
		n := ifx c < 0x80 then 1 else ifx (c & 0xE0) == 0xC0 then 2 else ifx (c & 0xF0) == 0xE0 then 3 else ifx (c & 0xF8) == 0xF0 then 4 else 0;
		if n == 0 || i + n > s.count return false;
		for 1..n-1 if (s[i + it] & 0xC0) != 0x80 return false;
		cp := ifx n == 1 then cast(u32) c else cast(u32) c & (cast(u32) 0xFF >> (n + 1));
		for 1..n-1 cp = (cp << 6) | (s[i + it] & 0x3F);
		if (n == 2 && cp < 0x80) || (n == 3 && cp < 0x800) || (n == 4 && (cp < 0x10000 || cp > 0x10FFFF)) || (cp >= 0xD800 && cp <= 0xDFFF) return false;
		i += n;
	}
	return true;
}

loop :: (d: *Db) {
	if d.path != ":memory:" make_directory_if_it_does_not_exist(path_strip_filename(d.path), recursive = true);
	ok, sealed := open(d);
	if sealed {
		// Its sessions can't be read here, but the file can go back to the machine that wrote it.
		aside := sprint("%.sealed-%", d.path, now_ms());
		log_error("e2e: % is sealed to another user or machine; moved to % and starting over", d.path, aside);
		free(d.error);
		d.error = .{};
		ok = file_move(d.path, aside) && open(d);
		free(aside);
	}
	db := d.sql;
	if ok prune_prekeys(db);
	if !ok log_error("e2e: %", d.error);
	while true {
		reset_temporary_storage();
		locks.lock(*d.mu);
		while !d.queue.count && !d.stopping locks.cond_wait(*d.cond, *d.mu);
		if !d.queue.count { locks.unlock(*d.mu); break; }
		job := d.queue[0];
		array_ordered_remove_by_index(*d.queue, 0);
		locks.unlock(*d.mu);
		if ok {
			job.run(d, job);
			// The WAL keeps the old copy of every page a job rewrote, spent keys included, until a
			// checkpoint; TRUNCATE also empties the file. DMs are slow enough to afford it per job.
			sqlite.exec(db, "PRAGMA wal_checkpoint(TRUNCATE);");
		} else {
			job.failed = true;
		}
		atomic_store(*job.done, 1);
		if d.wake d.wake();
	}
	if ok {
		// TRUNCATE leaves the main file complete on its own, so a copy of it alone loses nothing.
		sqlite.exec(db, "PRAGMA wal_checkpoint(TRUNCATE);");
		sqlite.close(db);
		crypto.aead_destroy(*d.seal);
	}
	atomic_store(*d.stopped, 1);
	if d.wake d.wake();
}

// open sets d.sql, or d.error. sealed: see unlock.
open :: (d: *Db) -> ok: bool, sealed: bool {
	// Exclusive: a second fastcord on the same <state> gets no database, rather than two processes
	// advancing one ratchet and encrypting two messages under the same key.
	db, ok := sqlite.open(d.path, exclusive = true);
	if !ok {
		d.error = sprint("cannot open % (damaged, or in use by another fastcord)", d.path);
		return false, false;
	}
	// secure_delete overwrites what's deleted or replaced: forward secrecy needs used message keys,
	// old ratchet states and expired prekeys gone from the file, not left in free pages.
	if !sqlite.exec(db, "PRAGMA secure_delete=ON;") || !migrate(db) {
		d.error = sprint("cannot migrate %: %", d.path, sqlite.errmsg(db));
		sqlite.close(db);
		return false, false;
	}
	d.sql = db;
	uok, sealed := unlock(d);
	if !uok {
		d.error = sprint("cannot unlock the key of %", d.path);
		sqlite.close(db);
		d.sql = null;
		return false, sealed;
	}
	return true, false;
}

migrate :: (db: *sqlite.DB) -> bool {
	st := sqlite.prepare(db, "PRAGMA user_version;");
	if !st return false;
	version := ifx sqlite.step(st) == .Row then sqlite.col_int(st, 0) else -1;
	sqlite.finalize(st);
	if version < 0 return false;
	if version > MIGRATIONS.count {
		log_error("e2e: the database is schema version %, newer than this fastcord's %", version, MIGRATIONS.count);
		return false;
	}
	for i: version..MIGRATIONS.count-1 {
		ok := sqlite.exec(db, "BEGIN;") && sqlite.exec(db, MIGRATIONS[i])
			&& sqlite.exec(db, tprint("PRAGMA user_version = %;", i + 1)) && sqlite.exec(db, "COMMIT;");
		if !ok { sqlite.exec(db, "ROLLBACK;"); return false; }
	}
	return true;
}
