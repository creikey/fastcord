/// End-to-end encrypted DMs (TODO.md E2E 1-8) over any carrier. E2E 1: the client database `fastcord.db` on its own thread.
#import "Basic";
#import "Atomics";
#import "Thread";
#import "File";
#import "File_Utilities";
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
	moved_from: string; // An earlier home of the file, moved to path on start when path doesn't exist yet.
	wake: (); // Called on the database thread after each job, e.g. to request a UI frame.
	thread: *Thread;
	mu: locks.Mutex;
	cond: locks.Cond;
	queue: [..]*Job;
	stopping: bool;
	stopped: s32;
	error: string; // Set by the database thread before it marks jobs failed; read it after a job's done.
	set_aside: s32; // The file was sealed to another user or machine and a new one started: old sessions are gone.
	sql: *sqlite.DB; // This and seal belong to the database thread.
	seal: crypto.Aead;
}

// start opens path (":memory:" for headless runs) on a new thread and migrates it, first moving the file
// there from moved_from if only that exists. It never waits on disk.
start :: (path: string, wake: () = null, moved_from := "") -> *Db {
	d := New(Db);
	d.path = copy_string(path);
	d.moved_from = copy_string(moved_from);
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
	free(d.moved_from);
	free(d.error);
	array_free(d.queue);
	free(d);
}

// ---- Requests: the E2E operations, each one job on the database thread ----
//
// A carrier adapter names each conversation and party with opaque bytes and moves the packets; nothing
// here knows what they mean.

Op :: enum u8 {
	Load;          // conv -> encrypted, has_session, and the peer's has_peer, peer_root, verified, key_changed
	Set_Encrypted; // conv, encrypted
	Set_Verified;  // conv, peer_root, verified: marks conv.peer's root verified or not, and clears key_changed
	Hello;         // conv, me -> packet, or result Too_Long when a Hello doesn't fit the carrier
	Accept;        // conv (peer: who sent the Hello), me, packet = the Hello -> packet
	Send;          // conv, me, text = plaintext -> packet, or result No_Session / Too_Long
	Sent;          // packet: handed to its carrier, so it leaves the outbox
	Receive;       // conv, from, delivery, me, packet -> result, content, out_text
	Outbox;        // -> outbox: packets committed but never handed to their carrier, to send again after a crash
	Search;        // conv, text = words -> hits: the conversation's texts holding every word, ignoring ASCII case
	Bundle;        // conv (carrier and me only), me -> packet: a Hello any conversation on the carrier may answer, for the carrier to keep
}

Result :: enum u8 {
	Ok;
	Hello;         // A Hello; accepted is set when a session answers it.
	Undecryptable;
	Repeated;      // The same packet already arrived as another delivery: a replay or a duplicate send.
	No_Session;    // A Msg whose Init hasn't been seen yet: retry after a new session appears.
	Too_Long;      // Doesn't fit the carrier's largest packet.
	Failed;
}

Outbox_Item :: struct { carrier, conversation, packet: string; }
Hit :: struct { delivery, author, text: string; } // author: the party that sent it

// The caller fills the inputs, submits, and once done reads the outputs and calls free_request.
Request :: struct {
	#as using job: Job;
	op: Op;
	me: Identity;
	conv: Conversation;
	from: string;     // Receive: the party the carrier says sent it.
	delivery: string; // Receive: the carrier's ID for this delivery; the same packet under another is a replay.
	text: string;
	packet: string;
	silent: bool; // Send: sent with @silent. Receive: the sender asked for no sound or notification.
	encrypted: bool;
	verified: bool;
	peer_root: [32]u8;

	result: Result;
	content: Content;
	out_text: string;
	has_session: bool;
	accepted: bool;
	has_peer: bool;
	key_changed: bool; // Load: the peer's root replaced an earlier one. Receive: a Hello with a root other than the peer's.
	outbox: [..]Outbox_Item;
	hits: [..]Hit;
}

// request makes a heap Request owning copies of conv, text and packet.
request :: (op: Op, conv := Conversation.{}, text := "", packet := "") -> *Request {
	r := New(Request);
	r.op, r.text, r.packet = op, copy_string(text), copy_string(packet);
	r.conv = .{copy_string(conv.carrier), copy_string(conv.id), copy_string(conv.me), copy_string(conv.peer), conv.limit};
	r.run = (d: *Db, j: *Job) { run_request(d, cast(*Request) j); };
	return r;
}

free_request :: (r: *Request) {
	crypto.zero(*r.me);
	for string.[r.conv.carrier, r.conv.id, r.conv.me, r.conv.peer, r.from, r.delivery, r.text, r.out_text, r.packet] free(it);
	for r.outbox { free(it.carrier); free(it.conversation); free(it.packet); }
	array_free(r.outbox);
	for r.hits { free(it.delivery); free(it.author); crypto.zero(xx it.text); free(it.text); }
	array_free(r.hits);
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
	// Carrier-neutral keys: a conversation is `carrier NUL id` and a party `carrier NUL party`, both BLOBs,
	// and a plaintext is claimed by an opaque delivery ID (NULL until our own send comes back). Packet
	// version 4 binds sessions differently, so nothing from before opens; E2E never shipped, so it all goes.
	#string SQL
DROP TABLE channels; DROP TABLE prekeys; DROP TABLE sessions; DROP TABLE skipped; DROP TABLE plaintexts; DROP TABLE outbox; DROP TABLE peers;
CREATE TABLE conversations(id BLOB PRIMARY KEY, encrypted INTEGER NOT NULL) WITHOUT ROWID;
CREATE TABLE prekeys(hello_id BLOB PRIMARY KEY, conversation BLOB NOT NULL, sealed BLOB NOT NULL, created INTEGER NOT NULL,
	answered INTEGER NOT NULL DEFAULT 0) WITHOUT ROWID;
CREATE TABLE sessions(id BLOB PRIMARY KEY, conversation BLOB NOT NULL, peer BLOB NOT NULL, peer_root BLOB NOT NULL, hello_id BLOB NOT NULL,
	state BLOB NOT NULL, updated INTEGER NOT NULL) WITHOUT ROWID;
CREATE INDEX sessions_conversation ON sessions(conversation, updated);
CREATE INDEX sessions_hello ON sessions(hello_id);
CREATE TABLE skipped(session BLOB NOT NULL, dh BLOB NOT NULL, n INTEGER NOT NULL, sealed BLOB NOT NULL, PRIMARY KEY(session, dh, n));
CREATE TABLE plaintexts(hash BLOB PRIMARY KEY, delivery BLOB, sealed BLOB NOT NULL) WITHOUT ROWID;
CREATE TABLE outbox(hash BLOB PRIMARY KEY, conversation BLOB NOT NULL, packet BLOB NOT NULL) WITHOUT ROWID;
CREATE TABLE peers(party BLOB PRIMARY KEY, root BLOB NOT NULL, verified INTEGER NOT NULL DEFAULT 0, changed INTEGER NOT NULL DEFAULT 0) WITHOUT ROWID;
SQL,
	// Search: each plaintext's conversation and author, so a conversation's texts can be opened and matched
	// in memory. No word index: one would hold the words outside the seal.
	#string SQL
ALTER TABLE plaintexts ADD COLUMN conversation BLOB;
ALTER TABLE plaintexts ADD COLUMN author BLOB;
CREATE INDEX plaintexts_conversation ON plaintexts(conversation);
SQL,
];

// Search opens at most this many of a conversation's texts and returns at most MAX_HITS of them.
MAX_SEARCHED :: 50000;
MAX_HITS :: 100;

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

// key names a conversation or a party in the database: the carrier, a NUL, then the carrier's ID.
key :: (carrier: string, id: string) -> []u8 {
	out := NewArray(carrier.count + 1 + id.count, u8,, temp);
	memcpy(out.data, carrier.data, carrier.count);
	memcpy(out.data + carrier.count + 1, id.data, id.count);
	return out;
}

// valid: a conversation the request can use. Parties are needed only by the ops that bind a session.
valid :: (r: *Request) -> bool {
	c := r.conv;
	if !c.carrier.count || find_index_from_left(c.carrier, 0) >= 0 || (!c.id.count && r.op != .Bundle) || c.limit > MAX_PACKET return false;
	if r.op == .Hello || r.op == .Bundle || r.op == .Accept || r.op == .Send || r.op == .Receive
		return c.me.count && c.limit > 0 && (r.op != .Accept || c.peer.count) && (r.op != .Receive || r.from.count);
	return true;
}

run_request :: (d: *Db, r: *Request) {
	db := d.sql;
	if r.op != .Sent && r.op != .Outbox && !valid(r) { r.result = .Failed; return; }
	conv := key(r.conv.carrier, r.conv.id);
	if r.op == {
		case .Load;
			r.encrypted = query_int(db, "SELECT encrypted FROM conversations WHERE id = ?;", conv) == 1;
			r.has_session = query_int(db, "SELECT 1 FROM sessions WHERE conversation = ? LIMIT 1;", conv) == 1;
			st := sqlite.prepare(db, "SELECT p.root, p.verified, p.changed FROM sessions s JOIN peers p ON p.party = s.peer WHERE s.conversation = ? ORDER BY s.updated DESC LIMIT 1;");
			if sqlite.bind_all(st, conv) && sqlite.step(st) == .Row && sqlite.col_blob(st, 0).count == 32 {
				r.has_peer = true;
				memcpy(r.peer_root.data, sqlite.col_blob(st, 0).data, 32);
				r.verified, r.key_changed = sqlite.col_int(st, 1) != 0, sqlite.col_int(st, 2) != 0;
			}
			sqlite.finalize(st);
		case .Set_Encrypted;
			if !set_encrypted(db, conv, r.encrypted) r.result = .Failed;
		case .Set_Verified;
			// Only the root the person compared: one that changed meanwhile stays unverified and flagged.
			if !sqlite.run(db, "UPDATE peers SET verified = ?, changed = 0 WHERE party = ? AND root = ?;", r.verified, key(r.conv.carrier, r.conv.peer), cast([]u8) r.peer_root)
				r.result = .Failed;
		case .Hello; #through;
		case .Bundle;
			// A bundle's prekeys are the carrier's (`carrier NUL`, no conversation), so any DM there can answer it.
			prune_prekeys(db);
			p: Packet;
			p.limit = r.conv.limit;
			pre, fits := make_hello(r.me, *p);
			defer crypto.zero(*pre);
			if !fits { r.result = .Too_Long; return; }
			id := crypto.blake3(bytes(*p));
			ok := sqlite.exec(db, "BEGIN;")
				&& sqlite.run(db, "INSERT INTO prekeys(hello_id, conversation, sealed, created) VALUES(?, ?, ?, ?);",
					cast([]u8) id, conv, seal(d, ad("prekeys", id), *pre), now_ms())
				&& (r.op == .Bundle || set_encrypted(db, conv, true))
				&& sqlite.exec(db, "COMMIT;");
			if !ok { sqlite.exec(db, "ROLLBACK;"); r.result = .Failed; return; }
			r.packet = copy_string(xx bytes(*p),, context.default_allocator);
		case .Accept;
			hello, ok := parse_hello(xx r.packet);
			if !ok { r.result = .Failed; return; }
			p: Packet;
			p.limit = r.conv.limit;
			first := INIT_PREFIX_BYTES + HEADER_BYTES + TAG_BYTES;
			if first + 2 > p.limit { r.result = .Too_Long; return; }
			s: Session;
			s, ok = accept(r.me, hello, binding(r.conv, r.conv.me, r.conv.peer), pad(.Accept, "", p.limit - first), *p);
			defer crypto.zero(*s);
			if !ok { r.result = .Failed; return; }
			free(r.packet);
			r.packet = copy_string(xx bytes(*p),, context.default_allocator);
			if !commit_sent(d, r, conv, *s, true, hello.root, hello.id, .Accept, "") r.result = .Failed;
		case .Send;
			if r.text.count > max_text(r.conv.limit) { r.result = .Too_Long; return; }
			st := sqlite.prepare(db, "SELECT id, state FROM sessions WHERE conversation = ? ORDER BY updated DESC LIMIT 1;");
			s: Session;
			found := sqlite.bind_all(st, conv) && sqlite.step(st) == .Row
				&& unseal(d, ad("sessions", sqlite.col_blob(st, 0)), sqlite.col_blob(st, 1), *s);
			sqlite.finalize(st);
			defer crypto.zero(*s);
			if !found { r.result = .No_Session; return; }
			p: Packet;
			p.limit = r.conv.limit;
			pt := pad(.Text, r.text, p.limit - MSG_PREFIX_BYTES - HEADER_BYTES - TAG_BYTES, silent = r.silent);
			defer crypto.zero(pt);
			head: [2]u8 = .[VERSION, xx Kind.Msg];
			memcpy(p.data.data, head.data, 2);
			memcpy(p.data.data + 2, s.id.data, 16);
			p.count = MSG_PREFIX_BYTES;
			if !encrypt(*s, pt, *p) { r.result = .Failed; return; }
			r.packet = copy_string(xx bytes(*p),, context.default_allocator);
			none: [32]u8;
			if !commit_sent(d, r, conv, *s, false, none, none, .Text, r.text) r.result = .Failed;
		case .Sent;
			sqlite.run(db, "DELETE FROM outbox WHERE hash = ?;", cast([]u8) crypto.blake3(xx r.packet));
		case .Receive;
			receive(d, r, conv);
		case .Outbox;
			st := sqlite.prepare(db, "SELECT conversation, packet FROM outbox;");
			while sqlite.step(st) == .Row {
				c := cast(string) sqlite.col_blob(st, 0);
				nul := find_index_from_left(c, 0);
				if nul < 0 continue;
				array_add(*r.outbox, .{copy_string(slice(c, 0, nul)), copy_string(slice(c, nul + 1, c.count - nul - 1)), copy_string(xx sqlite.col_blob(st, 1))});
			}
			sqlite.finalize(st);
		case .Search;
			words := split(to_lower_copy(r.text,, temp), " ",, temp);
			st := sqlite.prepare(db, "SELECT hash, delivery, author, sealed FROM plaintexts WHERE conversation = ? AND delivery IS NOT NULL LIMIT ?;");
			sqlite.bind_all(st, conv, MAX_SEARCHED);
			while r.hits.count < MAX_HITS && sqlite.step(st) == .Row {
				b := sqlite.col_blob(st, 3);
				if b.count <= SEAL_BYTES continue;
				pt := NewArray(b.count - SEAL_BYTES, u8,, temp);
				defer crypto.zero(pt);
				hash := sqlite.col_blob(st, 0);
				if hash.count != 32 || !unseal(d, ad("plaintexts", hash), b, pt) || (pt[0] & ~SILENT) != xx Content.Text continue;
				text := to_string(pt.data + 1, pt.count - 1);
				lower := to_lower_copy(text,, temp);
				defer crypto.zero(xx lower);
				found := true;
				for words if it.count && !contains(lower, it) { found = false; break; }
				if found array_add(*r.hits, .{copy_string(xx sqlite.col_blob(st, 1)), copy_string(xx sqlite.col_blob(st, 2)), copy_string(text)});
			}
			sqlite.finalize(st);
	}
}

// commit_sent stores the advanced session, our plaintext and the outbox entry in one transaction, before
// the packet can leave: a crash after the send but before the save would encrypt the next message with
// the same key.
commit_sent :: (d: *Db, r: *Request, conv: []u8, s: *Session, new: bool, peer_root: [32]u8, hello_id: [32]u8, content: Content, text: string) -> bool {
	db := d.sql;
	hash := crypto.blake3(xx r.packet);
	peer := key(r.conv.carrier, r.conv.peer);
	ok := sqlite.exec(db, "BEGIN;")
		&& (ifx new then sqlite.run(db, "INSERT INTO sessions(id, conversation, peer, peer_root, hello_id, state, updated) VALUES(?, ?, ?, ?, ?, ?, ?);",
				cast([]u8) s.id, conv, peer, cast([]u8) peer_root, cast([]u8) hello_id, seal(d, ad("sessions", s.id), s), now_ms())
			else sqlite.run(db, "UPDATE sessions SET state = ?, updated = ? WHERE id = ?;", seal(d, ad("sessions", s.id), s), now_ms(), cast([]u8) s.id))
		&& store_plaintext(d, hash, "", content, text, r.silent, conv, r.conv.me)
		&& sqlite.run(db, "INSERT INTO outbox(hash, conversation, packet) VALUES(?, ?, ?);", cast([]u8) hash, conv, cast([]u8) r.packet)
		&& (!new || (set_encrypted(db, conv, true) && note_peer(db, peer, peer_root)))
		&& sqlite.exec(db, "COMMIT;");
	if !ok { log_error("e2e: cannot save a sent message: %", sqlite.errmsg(db)); sqlite.exec(db, "ROLLBACK;"); }
	return ok;
}

receive :: (d: *Db, r: *Request, conv: []u8) {
	db := d.sql;
	mine := r.from == r.conv.me;
	if !r.delivery.count || r.packet.count > r.conv.limit { r.result = .Undecryptable; return; }
	hash := crypto.blake3(xx r.packet);
	st := sqlite.prepare(db, "SELECT delivery, sealed FROM plaintexts WHERE hash = ?;");
	if sqlite.bind_all(st, cast([]u8) hash) && sqlite.step(st) == .Row {
		first := copy_string(xx sqlite.col_blob(st, 0),, temp);
		b := sqlite.col_blob(st, 1);
		pt := NewArray(max(b.count - SEAL_BYTES, 0), u8,, temp);
		ok := unseal(d, ad("plaintexts", hash), b, pt) && take_plaintext(r, pt, stored = true);
		crypto.zero(pt);
		sqlite.finalize(st);
		if !ok { r.result = .Failed; return; }
		if !first.count && !mine {
			r.result = .Repeated; // Our unclaimed packet, reposted by someone else.
		} else if !first.count {
			// Our own send coming back from the carrier: it claims the plaintext and leaves the outbox.
			sqlite.run(db, "UPDATE plaintexts SET delivery = ? WHERE hash = ?;", cast([]u8) r.delivery, cast([]u8) hash);
			sqlite.run(db, "DELETE FROM outbox WHERE hash = ?;", cast([]u8) hash);
		} else if first != r.delivery {
			r.result = .Repeated;
		}
		return;
	}
	sqlite.finalize(st);

	if r.packet.count < 2 || r.packet[0] != VERSION { r.result = .Undecryptable; return; }
	from := key(r.conv.carrier, r.from);
	packet: []u8 = xx r.packet;
	kind := cast(Kind) packet[1];
	if kind == {
		case .Hello;
			hello, ok := parse_hello(packet);
			if !ok { r.result = .Undecryptable; return; }
			r.result = .Hello;
			r.accepted = query_int(db, "SELECT 1 FROM sessions WHERE hello_id = ? LIMIT 1;", cast([]u8) hello.id) == 1;
			r.key_changed = query_int(db, "SELECT 1 FROM peers WHERE party = ? AND root != ?;", from, cast([]u8) hello.root) == 1;
		case .Init;
			i, ok := parse_init(packet);
			if !ok || mine { r.result = .Undecryptable; return; }
			if query_int(db, "SELECT 1 FROM sessions WHERE id = ?;", cast([]u8) i.session) == 1 { r.result = .Repeated; return; }
			st := sqlite.prepare(db, "SELECT sealed FROM prekeys WHERE hello_id = ? AND conversation IN (?, ?);");
			pre: Prekeys;
			found := sqlite.bind_all(st, cast([]u8) i.hello_id, conv, key(r.conv.carrier, "")) && sqlite.step(st) == .Row
				&& unseal(d, ad("prekeys", i.hello_id), sqlite.col_blob(st, 0), *pre);
			sqlite.finalize(st);
			defer crypto.zero(*pre);
			if !found { r.result = .Undecryptable; return; }
			s: Session;
			s, ok = receive_init(r.me, pre, i, binding(r.conv, r.from, r.conv.me));
			defer crypto.zero(*s);
			if !ok { r.result = .Undecryptable; return; }
			skipped: [..]Skipped;
			skipped.allocator = temp;
			pt := NewArray(i.message.count - HEADER_BYTES - TAG_BYTES, u8,, temp);
			if !decrypt(*s, i.message, pt, *skipped) || !take_plaintext(r, pt) { r.result = .Undecryptable; return; }
			ok = sqlite.exec(db, "BEGIN;")
				&& sqlite.run(db, "INSERT INTO sessions(id, conversation, peer, peer_root, hello_id, state, updated) VALUES(?, ?, ?, ?, ?, ?, ?);",
					cast([]u8) s.id, conv, from, cast([]u8) i.root, cast([]u8) i.hello_id, seal(d, ad("sessions", s.id), *s), now_ms())
				&& store_skipped(d, s.id, skipped)
				&& store_plaintext(d, hash, r.delivery, r.content, r.out_text, r.silent, conv, r.from)
				&& set_encrypted(db, conv, true)
				&& note_peer(db, from, i.root)
				&& sqlite.run(db, "UPDATE prekeys SET answered = ? WHERE hello_id = ? AND answered = 0;", now_ms(), cast([]u8) i.hello_id)
				&& sqlite.exec(db, "COMMIT;");
			crypto.zero(cast([]u8) pt);
			if !ok { sqlite.exec(db, "ROLLBACK;"); r.result = .Failed; }
			prune_prekeys(db);
		case .Msg;
			if packet.count < MSG_PREFIX_BYTES + HEADER_BYTES + TAG_BYTES + 1 { r.result = .Undecryptable; return; }
			id: [16]u8;
			memcpy(id.data, packet.data + 2, 16);
			m := array_view(packet, MSG_PREFIX_BYTES, packet.count - MSG_PREFIX_BYTES);
			st := sqlite.prepare(db, "SELECT state FROM sessions WHERE id = ? AND conversation = ? AND peer = ?;");
			s: Session;
			found := sqlite.bind_all(st, cast([]u8) id, conv, from) && sqlite.step(st) == .Row
				&& unseal(d, ad("sessions", id), sqlite.col_blob(st, 0), *s);
			sqlite.finalize(st);
			defer crypto.zero(*s);
			if !found { r.result = ifx mine then .Undecryptable else .No_Session; return; }
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
					&& store_plaintext(d, hash, r.delivery, r.content, r.out_text, r.silent, conv, r.from)
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
					&& store_plaintext(d, hash, r.delivery, r.content, r.out_text, r.silent, conv, r.from)
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
	if !ok || pt.count < 1 || (pt[0] & ~SILENT) > xx Content.Accept return false;
	r.content, r.silent = xx (pt[0] & ~SILENT), (pt[0] & SILENT) != 0;
	text := to_string(pt.data + 1, pt.count - 1);
	if !valid_utf8(text) || (r.content == .Accept && text.count) return false;
	r.out_text = copy_string(text);
	return true;
}

// A plaintext is sealed as the Content byte then the text, the form take_plaintext reads. delivery is
// empty (NULL) for our own send until the carrier hands it back; author is the party that sent it.
store_plaintext :: (d: *Db, hash: [32]u8, delivery: string, content: Content, text: string, silent: bool, conv: []u8, author: string) -> bool {
	pt := NewArray(text.count + 1, u8, false,, temp);
	defer crypto.zero(pt);
	pt[0] = (cast(u8) content) | (ifx silent then SILENT else 0);
	memcpy(pt.data + 1, text.data, text.count);
	sealed := seal(d, ad("plaintexts", hash), pt);
	if !delivery.count return sqlite.run(d.sql, "INSERT INTO plaintexts(hash, sealed, conversation, author) VALUES(?, ?, ?, ?);", cast([]u8) hash, sealed, conv, cast([]u8) author);
	return sqlite.run(d.sql, "INSERT INTO plaintexts(hash, delivery, sealed, conversation, author) VALUES(?, ?, ?, ?, ?);", cast([]u8) hash, cast([]u8) delivery, sealed, conv, cast([]u8) author);
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
note_peer :: (db: *sqlite.DB, party: []u8, root: [32]u8) -> bool {
	return sqlite.run(db, "INSERT INTO peers(party, root) VALUES(?, ?) ON CONFLICT(party) DO UPDATE SET root = excluded.root, verified = 0, changed = 1 WHERE peers.root != excluded.root;",
		party, cast([]u8) root);
}

set_encrypted :: (db: *sqlite.DB, conv: []u8, on: bool) -> bool {
	return sqlite.run(db, "INSERT INTO conversations(id, encrypted) VALUES(?, ?) ON CONFLICT(id) DO UPDATE SET encrypted = excluded.encrypted;", conv, on);
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
	// A WAL left by a crash goes with it; the shared-memory index is rebuilt.
	if d.moved_from && !file_exists(d.path) && file_exists(d.moved_from) {
		wal := tprint("%-wal", d.moved_from);
		ok := file_move(d.moved_from, d.path) && (!file_exists(wal) || file_move(wal, tprint("%-wal", d.path)));
		file_delete(tprint("%-shm", d.moved_from));
		if ok log("e2e: moved % to %", d.moved_from, d.path);
		else log_error("e2e: cannot move % to %", d.moved_from, d.path);
	}
	ok, sealed := open(d);
	if sealed {
		// Its sessions can't be read here, but the file can go back to the machine that wrote it.
		aside := sprint("%.sealed-%", d.path, now_ms());
		log_error("e2e: % is sealed to another user or machine; moved to % and starting over", d.path, aside);
		free(d.error);
		d.error = .{};
		ok = file_move(d.path, aside) && open(d);
		free(aside);
		atomic_store(*d.set_aside, 1);
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
