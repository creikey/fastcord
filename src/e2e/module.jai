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
	Load;          // conv -> encrypted, has_session, peers, and the peer's has_peer, peer_root, verified, key_changed
	Set_Encrypted; // conv, encrypted
	Set_Verified;  // conv, peer_root, verified: marks conv.peer's root verified or not, and clears key_changed
	Hello;         // conv, me -> packet, or result Too_Long when a Hello doesn't fit the carrier
	Accept;        // conv (peer: who sent the Hello), me, packet = the Hello -> packet
	Send;          // conv, me, content, text, target, reply, files -> packet, or result No_Session / Too_Long / Failed (an Edit or Delete of what isn't ours). In a group (members), packets: our sender key for each member it's new to, then the message.
	Sent;          // packet: handed to its carrier, so it leaves the outbox
	Receive;       // conv, from, delivery, me, packet -> result, content, out_text, target, reply, files
	Outbox;        // -> outbox: packets committed but never handed to their carrier, to send again after a crash
	Search;        // conv, text = words -> hits: the conversation's texts holding every word, ignoring ASCII case
	Bundle;        // conv (carrier and me only), me -> packet: a Hello any conversation on the carrier may answer, for the carrier to keep
	Bottle;        // conv (carrier, where it goes, and me), text -> packet, a Bottle anyone may see, and out_text its digest, whose key is kept as ours; Too_Long when it doesn't fit. A Send of Bottle_Key with text the digest gives a reader the key.
	Unbottle;      // conv (carrier, where it is), from, packet -> result Ok and out_text, opened with the key from gave us; No_Session with none
	Gifts;         // conv (carrier; an empty ID for all its conversations) -> gifts: Bottle keys that waited for a session there, to Send again
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

Outbox_Item :: struct { carrier, conversation, packet: string; replaces: string; silent: bool; files: [..]string; } // replaces: the delivery an Edit or Delete rewrites; files: what Send's uploads held
Hit :: struct { delivery, author, text: string; } // author: the party that sent it
Gift :: struct { conversation, digest: string; }

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
	content: Content; // Send: what to send (Text upgrades to Post with a reply or files). Receive: what came.
	target: string; // Edit, Delete, React, Unreact: the delivery they change. An Edit or Delete replaces it, so the carrier rewrites that delivery in place.
	in_place: int; // Send of an Edit: the largest packet the carrier can put in its target's place (0: any). A longer one, and every later edit of that message, goes as a delivery of its own: detached.
	detached: bool; // Send: the Edit goes as a new delivery, which the receiving side hides and applies to its target.
	order: s64; // Receive: the carrier's order of this delivery, later ones larger (0: none). The latest of a message's detached edits wins.
	reply: string;
	forward_author: string; // Send: a forward of this author's message, sent at forward_at (opaque). Receive: what the forward named.
	forward_at: string;
	files: [..]File; // Strings on the heap.
	stickers: [..]string;
	members: [..]string; // Send in a group (E2E 8): its other parties, each given our sender key.
	packets: [..]string; // Send in a group: every packet to hand the carrier, in order.
	uploads: [..]string; // Send: the opaque files the message goes with, kept with its outbox entry until Sent.
	encrypted: bool;
	verified: bool;
	peer_root: [32]u8;
	quiet: bool; // Hello, Accept: a session only to give a Bottle's key, which leaves the conversation's encryption as it was. Receive: an Init answering such a Hello.
	waiting: bool; // Send of a Bottle_Key with no session: another key already waited there, so a session is already being made.

	result: Result;
	out_text: string;
	has_session: bool;
	accepted: bool;
	has_peer: bool;
	key_changed: bool; // Load: the peer's root replaced an earlier one. Receive: a Hello with a root other than the peer's.
	outbox: [..]Outbox_Item;
	hits: [..]Hit;
	peers: [..]string; // Load: every party we have a session with in conv (in a group, who gets our sender key).
	gifts: [..]Gift;
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
	for string.[r.conv.carrier, r.conv.id, r.conv.me, r.conv.peer, r.from, r.delivery, r.text, r.out_text, r.packet, r.target, r.reply, r.forward_author, r.forward_at] free(it);
	for * r.files { crypto.zero(*it.key); free(it.name); free(it.mime); free(it.description); }
	array_free(r.files);
	for r.stickers free(it);
	array_free(r.stickers);
	for r.packets free(it);
	array_free(r.packets);
	for r.members free(it);
	array_free(r.members);
	for r.uploads free(it);
	array_free(r.uploads);
	for r.outbox { free(it.carrier); free(it.conversation); free(it.packet); free(it.replaces); for it.files free(it); array_free(it.files); }
	array_free(r.outbox);
	for r.hits { free(it.delivery); free(it.author); crypto.zero(xx it.text); free(it.text); }
	array_free(r.hits);
	for r.peers free(it);
	array_free(r.peers);
	for r.gifts { free(it.conversation); free(it.digest); }
	array_free(r.gifts);
	free(r);
}

#scope_file

// Each entry moves the schema up one version (PRAGMA user_version). Never edit an entry; append. An entry
// only adds: users' sessions and decrypted history outlive every update (the #run below).
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
	// An Edit or Delete rewrites its target delivery; a resend after a crash keeps @silent.
	"ALTER TABLE outbox ADD COLUMN replaces BLOB; ALTER TABLE outbox ADD COLUMN silent INTEGER NOT NULL DEFAULT 0;",
	// E2E 8: each sender's chains in a group, ours with the members it was given to.
	"CREATE TABLE sender_keys(conversation BLOB NOT NULL, sender BLOB NOT NULL, id BLOB NOT NULL, sealed BLOB NOT NULL, members BLOB, updated INTEGER NOT NULL, PRIMARY KEY(conversation, sender, id)) WITHOUT ROWID;",
	// The opaque files a packet goes with (E2E 7's ciphertexts), kept with its outbox entry so a resend
	// after a crash carries them too.
	"CREATE TABLE outbox_files(hash BLOB NOT NULL, n INTEGER NOT NULL, data BLOB NOT NULL, PRIMARY KEY(hash, n)) WITHOUT ROWID;",
	// A detached Edit (store_plaintext): the delivery it changes, and the carrier's order of its own.
	"ALTER TABLE plaintexts ADD COLUMN target BLOB; ALTER TABLE plaintexts ADD COLUMN ord INTEGER NOT NULL DEFAULT 0; CREATE INDEX plaintexts_target ON plaintexts(conversation, target);",
	// Each Bottle's key by its digest and the party who gave it (us, for our own), so a Bottle opens only as
	// from its giver.
	"CREATE TABLE bottle_keys(digest BLOB NOT NULL, giver BLOB NOT NULL, sealed BLOB NOT NULL, created INTEGER NOT NULL, PRIMARY KEY(digest, giver)) WITHOUT ROWID;",
	// A Bottle's keys for readers we have no session with yet, given once one exists; and Hellos made only
	// for that, whose sessions leave encryption off.
	"CREATE TABLE bottle_gifts(digest BLOB NOT NULL, conversation BLOB NOT NULL, created INTEGER NOT NULL, PRIMARY KEY(digest, conversation)) WITHOUT ROWID; ALTER TABLE prekeys ADD COLUMN quiet INTEGER NOT NULL DEFAULT 0;",
];

// The entries that wiped users' sessions and history, before E2E shipped in v0.6.2. Never add to this:
// a table that must change shape is rebuilt with its rows copied, and that needs the maintainer's review.
WIPED_BEFORE_RELEASE :: int.[3, 5];

#run {
	for MIGRATIONS if !array_find(WIPED_BEFORE_RELEASE, it_index)
		assert(only_adds(it), "e2e migration % deletes data: an update must never cost a user their sessions or history", it_index);
}

// only_adds is false if sql, in any case or spacing, drops a table or column or deletes rows.
only_adds :: (sql: string) -> bool {
	s: [..]u8;
	defer array_free(s);
	for 0..sql.count-1 {
		c := to_upper(sql[it]);
		if c == #char "\t" || c == #char "\r" || c == #char "\n" c = #char " ";
		if c == #char " " && s.count && s[s.count-1] == #char " " continue;
		array_add(*s, c);
	}
	norm := cast(string) s;
	return !contains(norm, "DROP TABLE") && !contains(norm, "DROP COLUMN") && !contains(norm, "DELETE FROM");
}

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
	if !c.carrier.count || find_index_from_left(c.carrier, 0) >= 0 || (!c.id.count && r.op != .Bundle && r.op != .Gifts) || c.limit > MAX_PACKET return false;
	if r.op == .Hello || r.op == .Bundle || r.op == .Accept || r.op == .Send || r.op == .Receive || r.op == .Bottle
		return c.me.count && c.limit > 0 && (r.op != .Accept || c.peer.count) && (r.op != .Receive || r.from.count);
	if r.op == .Unbottle return r.from.count > 0;
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
			st = sqlite.prepare(db, "SELECT DISTINCT peer FROM sessions WHERE conversation = ? LIMIT 64;");
			sqlite.bind_all(st, conv);
			while sqlite.step(st) == .Row {
				p := cast(string) sqlite.col_blob(st, 0);
				nul := find_index_from_left(p, 0);
				if nul >= 0 array_add(*r.peers, copy_string(advance(p, nul + 1)));
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
				&& sqlite.run(db, "INSERT INTO prekeys(hello_id, conversation, sealed, created, quiet) VALUES(?, ?, ?, ?, ?);",
					cast([]u8) id, conv, seal(d, ad("prekeys", id), *pre), now_ms(), r.quiet)
				&& (r.op == .Bundle || r.quiet || set_encrypted(db, conv, true))
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
			r.content = .Accept;
			s, ok = accept(r.me, hello, binding(r.conv, r.conv.me, r.conv.peer), pad(encode_body(.{content = .Accept}), p.limit - first), *p);
			defer crypto.zero(*s);
			if !ok { r.result = .Failed; return; }
			free(r.packet);
			r.packet = copy_string(xx bytes(*p),, context.default_allocator);
			if !commit_sent(d, r, conv, *s, true, hello.root, hello.id, encode_body(.{content = .Accept})) r.result = .Failed;
		case .Send;
			text := r.text;
			if r.content == .Bottle_Key {
				// Only our own Bottle's key, and only to one peer: the text names it by digest.
				k: [32]u8;
				defer crypto.zero(*k);
				st := sqlite.prepare(db, "SELECT sealed FROM bottle_keys WHERE digest = ? AND giver = ?;");
				found := r.text.count == 32 && !r.members && sqlite.bind_all(st, cast([]u8) r.text, key(r.conv.carrier, r.conv.me)) && sqlite.step(st) == .Row
					&& unseal(d, ad("bottle_keys", xx r.text), sqlite.col_blob(st, 0), *k);
				sqlite.finalize(st);
				if !found { r.result = .Failed; return; }
				gift := NewArray(BOTTLE_KEY_BYTES, u8,, temp);
				memcpy(gift.data, r.text.data, 32);
				memcpy(gift.data + 32, k.data, 32);
				text = xx gift;
			}
			if r.content == .Text && (r.reply.count || r.files.count || r.stickers.count || r.forward_author.count) r.content = .Post;
			body := encode_body(.{r.content, r.silent, r.target, r.reply, r.files, text, r.stickers, r.forward_author.count > 0, r.forward_author, r.forward_at});
			defer if r.content == .Bottle_Key { crypto.zero(xx text); crypto.zero(body); }
			_, valid := parse_body(body);
			if !valid || r.content == .Accept { r.result = .Failed; return; }
			if r.members { group_send(d, r, conv, body); return; }
			if body.count + 1 > r.conv.limit - MSG_PREFIX_BYTES - HEADER_BYTES - TAG_BYTES { r.result = .Too_Long; return; }
			// Only our own message is edited or deleted.
			if replaces(r.content) && query_int(db, "SELECT 1 FROM plaintexts WHERE delivery = ? AND conversation = ? AND author = ? LIMIT 1;", cast([]u8) r.target, conv, cast([]u8) r.conv.me) != 1 {
				r.result = .Failed;
				return;
			}
			st := sqlite.prepare(db, "SELECT id, state FROM sessions WHERE conversation = ? ORDER BY updated DESC LIMIT 1;");
			s: Session;
			found := sqlite.bind_all(st, conv) && sqlite.step(st) == .Row
				&& unseal(d, ad("sessions", sqlite.col_blob(st, 0)), sqlite.col_blob(st, 1), *s);
			sqlite.finalize(st);
			defer crypto.zero(*s);
			if !found {
				// A Bottle's key waits for the session the caller now makes, then goes with Gifts.
				if r.content == .Bottle_Key {
					r.waiting = query_int(db, "SELECT 1 FROM bottle_gifts WHERE conversation = ? LIMIT 1;", conv) == 1;
					if !sqlite.run(db, "INSERT OR IGNORE INTO bottle_gifts(digest, conversation, created) VALUES(?, ?, ?);", cast([]u8) r.text, conv, now_ms()) { r.result = .Failed; return; }
				}
				r.result = .No_Session;
				return;
			}
			p: Packet;
			p.limit = r.conv.limit;
			pt := pad(body, p.limit - MSG_PREFIX_BYTES - HEADER_BYTES - TAG_BYTES);
			defer crypto.zero(pt);
			head: [2]u8 = .[VERSION, xx Kind.Msg];
			memcpy(p.data.data, head.data, 2);
			memcpy(p.data.data + 2, s.id.data, 16);
			p.count = MSG_PREFIX_BYTES;
			if !encrypt(*s, pt, *p) { r.result = .Failed; return; }
			r.packet = copy_string(xx bytes(*p),, context.default_allocator);
			r.detached = is_detached(db, r, conv, p.count);
			none: [32]u8;
			if !commit_sent(d, r, conv, *s, false, none, none, body) r.result = .Failed;
		case .Sent;
			hash := crypto.blake3(xx r.packet);
			sqlite.run(db, "DELETE FROM outbox WHERE hash = ?;", cast([]u8) hash);
			sqlite.run(db, "DELETE FROM outbox_files WHERE hash = ?;", cast([]u8) hash);
		case .Receive;
			receive(d, r, conv);
		case .Outbox;
			st := sqlite.prepare(db, "SELECT conversation, packet, replaces, silent FROM outbox;");
			while sqlite.step(st) == .Row {
				c := cast(string) sqlite.col_blob(st, 0);
				nul := find_index_from_left(c, 0);
				if nul < 0 continue;
				item := array_add(*r.outbox);
				item.carrier, item.conversation, item.packet = copy_string(slice(c, 0, nul)), copy_string(slice(c, nul + 1, c.count - nul - 1)), copy_string(xx sqlite.col_blob(st, 1));
				item.replaces, item.silent = copy_string(xx sqlite.col_blob(st, 2)), sqlite.col_int(st, 3) != 0;
				fs := sqlite.prepare(db, "SELECT data FROM outbox_files WHERE hash = ? ORDER BY n;");
				sqlite.bind_all(fs, cast([]u8) crypto.blake3(xx item.packet));
				while sqlite.step(fs) == .Row array_add(*item.files, copy_string(xx sqlite.col_blob(fs, 0)));
				sqlite.finalize(fs);
			}
			sqlite.finalize(st);
		case .Search;
			words := split(to_lower_copy(r.text,, temp), " ",, temp);
			st := sqlite.prepare(db, "SELECT hash, delivery, author, sealed FROM plaintexts WHERE conversation = ? AND delivery IS NOT NULL AND target IS NULL LIMIT ?;");
			sqlite.bind_all(st, conv, MAX_SEARCHED);
			while r.hits.count < MAX_HITS && sqlite.step(st) == .Row {
				b := sqlite.col_blob(st, 3);
				if b.count <= SEAL_BYTES continue;
				pt := NewArray(b.count - SEAL_BYTES, u8,, temp);
				defer crypto.zero(pt);
				hash := sqlite.col_blob(st, 0);
				if hash.count != 32 || !unseal(d, ad("plaintexts", hash), b, pt) continue;
				body, ok := parse_body(pt);
				if !ok || (body.content != .Text && body.content != .Post && body.content != .Edit) || !body.text continue;
				text := body.text;
				lower := to_lower_copy(text,, temp);
				defer crypto.zero(xx lower);
				found := true;
				for words if it.count && !contains(lower, it) { found = false; break; }
				if found array_add(*r.hits, .{copy_string(xx sqlite.col_blob(st, 1)), copy_string(xx sqlite.col_blob(st, 2)), copy_string(text)});
			}
			sqlite.finalize(st);
		case .Bottle;
			body := encode_body(.{content = .Text, text = r.text});
			_, valid := parse_body(body);
			if !valid || !r.text.count { r.result = .Failed; return; }
			if body.count + 1 > r.conv.limit - BOTTLE_OVERHEAD { r.result = .Too_Long; return; }
			p: Packet;
			p.limit = r.conv.limit;
			pt := pad(body, p.limit - BOTTLE_OVERHEAD);
			defer crypto.zero(pt);
			k := seal_bottle(pt, *p);
			defer crypto.zero(*k);
			digest := crypto.blake3(bytes(*p));
			if !sqlite.run(db, "INSERT INTO bottle_keys(digest, giver, sealed, created) VALUES(?, ?, ?, ?);",
					cast([]u8) digest, key(r.conv.carrier, r.conv.me), seal(d, ad("bottle_keys", digest), *k), now_ms()) {
				r.result = .Failed;
				return;
			}
			r.packet = copy_string(xx bytes(*p),, context.default_allocator);
			r.out_text = copy_string(xx digest);
		case .Unbottle;
			packet: []u8 = xx r.packet;
			if packet.count < BOTTLE_OVERHEAD + 1 || packet.count > MAX_PACKET || packet[0] != VERSION || packet[1] != xx Kind.Bottle { r.result = .Undecryptable; return; }
			digest := crypto.blake3(packet);
			k: [32]u8;
			defer crypto.zero(*k);
			st := sqlite.prepare(db, "SELECT sealed FROM bottle_keys WHERE digest = ? AND giver = ?;");
			found := sqlite.bind_all(st, cast([]u8) digest, key(r.conv.carrier, r.from)) && sqlite.step(st) == .Row
				&& unseal(d, ad("bottle_keys", digest), sqlite.col_blob(st, 0), *k);
			sqlite.finalize(st);
			if !found { r.result = .No_Session; return; }
			pt := NewArray(packet.count - BOTTLE_OVERHEAD, u8,, temp);
			defer crypto.zero(pt);
			body: []u8;
			ok: bool;
			if open_bottle(k, packet, pt) body, ok = unpad(pt);
			b: Body;
			if ok b, ok = parse_body(body);
			if !ok || b.content != .Text { r.result = .Undecryptable; return; }
			r.content, r.out_text = Content.Text, copy_string(b.text);
		case .Gifts;
			// A reader who never answers in a month won't: their keys stop waiting.
			sqlite.run(db, "DELETE FROM bottle_gifts WHERE created < ?;", now_ms() - GIFT_WAIT_MS);
			all := key(r.conv.carrier, "");
			st := sqlite.prepare(db, ifx r.conv.id.count then "SELECT conversation, digest FROM bottle_gifts WHERE conversation = ?1 AND ?2 > 0 LIMIT 1000;"
				else "SELECT conversation, digest FROM bottle_gifts WHERE substr(conversation, 1, ?2) = ?1 LIMIT 1000;");
			sqlite.bind_all(st, ifx r.conv.id.count then conv else all, all.count);
			while sqlite.step(st) == .Row {
				c := cast(string) sqlite.col_blob(st, 0);
				if c.count <= all.count continue;
				array_add(*r.gifts, .{copy_string(advance(c, all.count)), copy_string(xx sqlite.col_blob(st, 1))});
			}
			sqlite.finalize(st);
	}
}

GIFT_WAIT_MS :: 30 * 24 * 3600 * 1000;

// store_bottle_key keeps the key to a Bottle a peer gave us over our pairwise session (a Bottle_Key message).
store_bottle_key :: (d: *Db, r: *Request, from: []u8) -> bool {
	if r.content != .Bottle_Key return true;
	digest := array_view(cast([]u8) r.out_text, 0, 32);
	return sqlite.run(d.sql, "INSERT OR REPLACE INTO bottle_keys(digest, giver, sealed, created) VALUES(?, ?, ?, ?);",
		digest, from, seal(d, ad("bottle_keys", digest), array_view(cast([]u8) r.out_text, 32, 32)), now_ms());
}

// commit_sent stores the advanced session, our plaintext and the outbox entry in one transaction, before
// the packet can leave: a crash after the send but before the save would encrypt the next message with
// the same key.
commit_sent :: (d: *Db, r: *Request, conv: []u8, s: *Session, new: bool, peer_root: [32]u8, hello_id: [32]u8, body: []u8) -> bool {
	db := d.sql;
	hash := crypto.blake3(xx r.packet);
	peer := key(r.conv.carrier, r.conv.peer);
	ok := sqlite.exec(db, "BEGIN;")
		&& (ifx new then sqlite.run(db, "INSERT INTO sessions(id, conversation, peer, peer_root, hello_id, state, updated) VALUES(?, ?, ?, ?, ?, ?, ?);",
				cast([]u8) s.id, conv, peer, cast([]u8) peer_root, cast([]u8) hello_id, seal(d, ad("sessions", s.id), s), now_ms())
			else sqlite.run(db, "UPDATE sessions SET state = ?, updated = ? WHERE id = ?;", seal(d, ad("sessions", s.id), s), now_ms(), cast([]u8) s.id))
		&& store_plaintext(d, hash, in_place_target(r), body, conv, r.conv.me)
		&& sqlite.run(db, "INSERT INTO outbox(hash, conversation, packet, replaces, silent) VALUES(?, ?, ?, nullif(?, X''), ?);", cast([]u8) hash, conv, cast([]u8) r.packet, cast([]u8) in_place_target(r), r.silent || r.detached)
		&& outbox_files(db, hash, r.uploads)
		&& (!new || ((r.quiet || set_encrypted(db, conv, true)) && note_peer(db, peer, peer_root) && forget_own_sender_key(db, r, conv)))
		&& (r.content != .Bottle_Key || sqlite.run(db, "DELETE FROM bottle_gifts WHERE digest = ? AND conversation = ?;", cast([]u8) r.text, conv))
		&& sqlite.exec(db, "COMMIT;");
	if !ok { log_error("e2e: cannot save a sent message: %", sqlite.errmsg(db)); sqlite.exec(db, "ROLLBACK;"); }
	return ok;
}

// is_detached: an Edit too long for its target's place goes as a delivery of its own, and so does every
// edit of a message after its first detached one, so no in-place edit, ordered by where its target sits,
// can be taken for newer than one.
is_detached :: (db: *sqlite.DB, r: *Request, conv: []u8, size: int) -> bool {
	if r.content != .Edit || r.in_place <= 0 return false;
	return size > r.in_place || query_int(db, "SELECT 1 FROM plaintexts WHERE conversation = ? AND target = ? LIMIT 1;", conv, cast([]u8) r.target) == 1;
}

// in_place_target: the delivery our Edit or Delete rewrites in place, which its plaintext claims at once.
in_place_target :: (r: *Request) -> string { return ifx replaces(r.content) && !r.detached then r.target else ""; }

outbox_files :: (db: *sqlite.DB, hash: [32]u8, files: []string) -> bool {
	for files if !sqlite.run(db, "INSERT INTO outbox_files(hash, n, data) VALUES(?, ?, ?);", cast([]u8) hash, it_index, cast([]u8) it) return false;
	return true;
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
		ok := unseal(d, ad("plaintexts", hash), b, pt) && take_plaintext(r, pt);
		crypto.zero(pt);
		sqlite.finalize(st);
		if !ok { r.result = .Failed; return; }
		if !first.count && !mine {
			r.result = .Repeated; // Our unclaimed packet, reposted by someone else.
		} else if !first.count {
			// Our own send coming back from the carrier: it claims the plaintext and leaves the outbox.
			sqlite.run(db, "UPDATE plaintexts SET delivery = ?, ord = ? WHERE hash = ?;", cast([]u8) r.delivery, r.order, cast([]u8) hash);
			sqlite.run(db, "DELETE FROM outbox WHERE hash = ?;", cast([]u8) hash);
			sqlite.run(db, "DELETE FROM outbox_files WHERE hash = ?;", cast([]u8) hash);
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
			st := sqlite.prepare(db, "SELECT sealed, quiet FROM prekeys WHERE hello_id = ? AND conversation IN (?, ?);");
			pre: Prekeys;
			found := sqlite.bind_all(st, cast([]u8) i.hello_id, conv, key(r.conv.carrier, "")) && sqlite.step(st) == .Row
				&& unseal(d, ad("prekeys", i.hello_id), sqlite.col_blob(st, 0), *pre);
			r.quiet = found && sqlite.col_int(st, 1) != 0;
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
			body: []u8;
			if !decrypt(*s, i.message, pt, *skipped) || !opened(r, pt, *body) { r.result = .Undecryptable; return; }
			ok = sqlite.exec(db, "BEGIN;")
				&& sqlite.run(db, "INSERT INTO sessions(id, conversation, peer, peer_root, hello_id, state, updated) VALUES(?, ?, ?, ?, ?, ?, ?);",
					cast([]u8) s.id, conv, from, cast([]u8) i.root, cast([]u8) i.hello_id, seal(d, ad("sessions", s.id), *s), now_ms())
				&& store_skipped(d, s.id, skipped)
				&& store_plaintext(d, hash, r.delivery, body, conv, r.from, r.order, r)
				&& (r.quiet || set_encrypted(db, conv, true))
				&& note_peer(db, from, i.root)
				&& forget_own_sender_key(db, r, conv)
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
			body: []u8;
			if has_mk {
				if !decrypt_skipped(*s, mk, m, pt) || !opened(r, pt, *body) { r.result = .Undecryptable; return; }
				ok = sqlite.exec(db, "BEGIN;")
					&& sqlite.run(db, "DELETE FROM skipped WHERE session = ? AND dh = ? AND n = ?;", cast([]u8) id, cast([]u8) h.dh, cast(s64) h.n)
					&& store_plaintext(d, hash, r.delivery, body, conv, r.from, r.order, r)
					&& store_sender_key(d, r, conv, from)
					&& store_bottle_key(d, r, from)
					&& sqlite.exec(db, "COMMIT;");
			} else {
				next := s;
				defer crypto.zero(*next);
				skipped: [..]Skipped;
				skipped.allocator = temp;
				if !decrypt(*next, m, pt, *skipped) || !opened(r, pt, *body) { r.result = .Undecryptable; return; }
				ok = sqlite.exec(db, "BEGIN;")
					&& sqlite.run(db, "UPDATE sessions SET state = ?, updated = ? WHERE id = ?;", seal(d, ad("sessions", id), *next), now_ms(), cast([]u8) id)
					&& store_skipped(d, id, skipped)
					&& store_plaintext(d, hash, r.delivery, body, conv, r.from, r.order, r)
					&& store_sender_key(d, r, conv, from)
					&& store_bottle_key(d, r, from)
					&& sqlite.exec(db, "COMMIT;");
				for * skipped crypto.zero(*it.mk);
			}
			if !ok { sqlite.exec(db, "ROLLBACK;"); r.result = .Failed; }
		case .Group;
			receive_group(d, r, conv, from, hash);
		case;
			r.result = .Undecryptable;
	}
}

// take_plaintext reads a Content byte and Body into the request's outputs.
take_plaintext :: (r: *Request, pt: []u8) -> bool {
	b, ok := parse_body(pt);
	if !ok return false;
	r.content, r.silent, r.out_text, r.target, r.reply = b.content, b.silent, copy_string(b.text), copy_string(b.target), copy_string(b.reply);
	r.forward_author, r.forward_at = copy_string(b.forward_author), copy_string(b.forward_at);
	for b.files {
		f := array_add(*r.files);
		f.* = it;
		f.name, f.mime, f.description = copy_string(it.name), copy_string(it.mime), copy_string(it.description);
	}
	for b.stickers array_add(*r.stickers, copy_string(it));
	return true;
}

// opened takes the plaintext of a packet just decrypted: its padding goes, and a Delete must name the
// delivery it arrived as, so the carrier can't move it onto another message. An Edit elsewhere is
// detached: it changes only the target its sender named, and only if they wrote it (store_plaintext).
opened :: (r: *Request, padded: []u8, body: *[]u8) -> bool {
	ok: bool;
	body.*, ok = unpad(padded);
	return ok && take_plaintext(r, body.*) && (r.content != .Delete || r.target == r.delivery);
}

replaces :: (c: Content) -> bool { return c == .Edit || c == .Delete; }

// ---- Groups (E2E 8) ----

// members_key names a group's member set, in any order.
members_key :: (members: []string) -> [32]u8 {
	out: [32]u8;
	for members {
		h := crypto.blake3(xx it);
		for b: 0..31 out[b] ^= h[b];
	}
	return out;
}

forget_own_sender_key :: (db: *sqlite.DB, r: *Request, conv: []u8) -> bool {
	return sqlite.run(db, "DELETE FROM sender_keys WHERE conversation = ? AND sender = ?;", conv, key(r.conv.carrier, r.conv.me));
}

// group_send sends body under our sender key in a group. A new key (the first send, after the members
// changed, or after a new session) goes first to every member we have a session with, each a Sender_Key
// message of their pairwise session; then the Group packet. One transaction, as commit_sent.
group_send :: (d: *Db, r: *Request, conv: []u8, body: []u8) {
	db := d.sql;
	if body.count + 1 > r.conv.limit - GROUP_OVERHEAD { r.result = .Too_Long; return; }
	me := key(r.conv.carrier, r.conv.me);
	members := members_key(r.members);
	k: Sender_Key;
	defer crypto.zero(*k);
	st := sqlite.prepare(db, "SELECT id, sealed FROM sender_keys WHERE conversation = ? AND sender = ? AND members = ? ORDER BY updated DESC LIMIT 1;");
	have := sqlite.bind_all(st, conv, me, cast([]u8) members) && sqlite.step(st) == .Row
		&& unseal(d, ad("sender_keys", sqlite.col_blob(st, 0)), sqlite.col_blob(st, 1), *k);
	sqlite.finalize(st);
	if !sqlite.exec(db, "BEGIN;") { r.result = .Failed; return; }
	ok := true;
	if !have {
		k = new_sender_key();
		given := 0;
		for m: r.members {
			peer := key(r.conv.carrier, m);
			st = sqlite.prepare(db, "SELECT id, state FROM sessions WHERE conversation = ? AND peer = ? ORDER BY updated DESC LIMIT 1;");
			s: Session;
			found := sqlite.bind_all(st, conv, peer) && sqlite.step(st) == .Row && unseal(d, ad("sessions", sqlite.col_blob(st, 0)), sqlite.col_blob(st, 1), *s);
			sqlite.finalize(st);
			defer crypto.zero(*s);
			if !found continue;
			gift := encode_body(.{content = .Sender_Key, text = sender_key_body(k)});
			p: Packet;
			p.limit = r.conv.limit;
			pt := pad(gift, p.limit - MSG_PREFIX_BYTES - HEADER_BYTES - TAG_BYTES);
			head: [2]u8 = .[VERSION, xx Kind.Msg];
			memcpy(p.data.data, head.data, 2);
			memcpy(p.data.data + 2, s.id.data, 16);
			p.count = MSG_PREFIX_BYTES;
			ok = ok && encrypt(*s, pt, *p);
			crypto.zero(pt);
			packet := bytes(*p);
			ok = ok && sqlite.run(db, "UPDATE sessions SET state = ?, updated = ? WHERE id = ?;", seal(d, ad("sessions", s.id), *s), now_ms(), cast([]u8) s.id)
				&& store_plaintext(d, crypto.blake3(packet), "", gift, conv, r.conv.me)
				&& sqlite.run(db, "INSERT INTO outbox(hash, conversation, packet) VALUES(?, ?, ?);", cast([]u8) crypto.blake3(packet), conv, packet);
			array_add(*r.packets, copy_string(xx packet));
			given += 1;
		}
		if !given { sqlite.exec(db, "ROLLBACK;"); r.result = .No_Session; return; }
	}
	p: Packet;
	p.limit = r.conv.limit;
	pt := pad(body, p.limit - GROUP_OVERHEAD);
	defer crypto.zero(pt);
	ok = ok && group_seal(*k, binding(r.conv, r.conv.me, ""), pt, *p);
	packet := bytes(*p);
	r.detached = is_detached(db, r, conv, packet.count);
	ok = ok && sqlite.run(db, "INSERT OR REPLACE INTO sender_keys(conversation, sender, id, sealed, members, updated) VALUES(?, ?, ?, ?, ?, ?);",
			conv, me, cast([]u8) k.id, seal(d, ad("sender_keys", k.id), *k), cast([]u8) members, now_ms())
		&& store_plaintext(d, crypto.blake3(packet), in_place_target(r), body, conv, r.conv.me)
		&& sqlite.run(db, "INSERT INTO outbox(hash, conversation, packet, replaces, silent) VALUES(?, ?, ?, nullif(?, X''), ?);", cast([]u8) crypto.blake3(packet), conv, packet, cast([]u8) in_place_target(r), r.silent || r.detached)
		&& outbox_files(db, crypto.blake3(packet), r.uploads)
		&& sqlite.exec(db, "COMMIT;");
	if !ok { sqlite.exec(db, "ROLLBACK;"); r.result = .Failed; for r.packets free(it); r.packets.count = 0; return; }
	r.packet = copy_string(xx packet);
	array_add(*r.packets, copy_string(xx packet));
}

// store_sender_key keeps a chain a member gave us over our pairwise session (a Sender_Key message).
store_sender_key :: (d: *Db, r: *Request, conv: []u8, from: []u8) -> bool {
	if r.content != .Sender_Key return true;
	k := sender_key_of(r.out_text);
	defer crypto.zero(*k);
	return sqlite.run(d.sql, "INSERT OR REPLACE INTO sender_keys(conversation, sender, id, sealed, updated) VALUES(?, ?, ?, ?, ?);",
		conv, from, cast([]u8) k.id, seal(d, ad("sender_keys", k.id), *k), now_ms());
}

// receive_group opens a Group packet with the chain its sender gave us: No_Session until they have.
receive_group :: (d: *Db, r: *Request, conv: []u8, from: []u8, hash: [32]u8) {
	db := d.sql;
	packet: []u8 = xx r.packet;
	id, n, ok := parse_group(packet);
	if !ok { r.result = .Undecryptable; return; }
	k: Sender_Key;
	defer crypto.zero(*k);
	st := sqlite.prepare(db, "SELECT sealed FROM sender_keys WHERE conversation = ? AND sender = ? AND id = ?;");
	found := sqlite.bind_all(st, conv, from, cast([]u8) id) && sqlite.step(st) == .Row && unseal(d, ad("sender_keys", id), sqlite.col_blob(st, 0), *k);
	sqlite.finalize(st);
	if !found { r.result = ifx r.from == r.conv.me then .Undecryptable else .No_Session; return; }
	bind := binding(r.conv, r.from, "");
	pt := NewArray(packet.count - GROUP_OVERHEAD, u8,, temp);
	defer crypto.zero(pt);
	dh: [32]u8;
	memcpy(dh.data, id.data, 16);
	st = sqlite.prepare(db, "SELECT sealed FROM skipped WHERE session = ? AND dh = ? AND n = ?;");
	mk: [32]u8;
	defer crypto.zero(*mk);
	skipped_key := sqlite.bind_all(st, cast([]u8) id, cast([]u8) dh, cast(s64) n) && sqlite.step(st) == .Row && unseal(d, skipped_ad(id, dh, n), sqlite.col_blob(st, 0), *mk);
	sqlite.finalize(st);
	next := k;
	defer crypto.zero(*next);
	skipped: [..]Skipped;
	skipped.allocator = temp;
	if !skipped_key mk, ok = group_advance(*next, n, *skipped);
	body: []u8;
	if !ok || !group_open(k, mk, bind, packet, pt) || !opened(r, pt, *body) || r.content == .Sender_Key || r.content == .Bottle_Key { r.result = .Undecryptable; return; }
	ok = sqlite.exec(db, "BEGIN;")
		&& (ifx skipped_key then sqlite.run(db, "DELETE FROM skipped WHERE session = ? AND dh = ? AND n = ?;", cast([]u8) id, cast([]u8) dh, cast(s64) n)
			else sqlite.run(db, "UPDATE sender_keys SET sealed = ?, updated = ? WHERE conversation = ? AND sender = ? AND id = ?;", seal(d, ad("sender_keys", id), *next), now_ms(), conv, from, cast([]u8) id)
				&& store_skipped(d, id, skipped))
		&& store_plaintext(d, hash, r.delivery, body, conv, r.from, r.order, r)
		&& sqlite.exec(db, "COMMIT;");
	for * skipped crypto.zero(*it.mk);
	if !ok { sqlite.exec(db, "ROLLBACK;"); r.result = .Failed; }
}

// A plaintext is sealed as its Content byte and Body, the form take_plaintext reads. delivery is empty
// (NULL) for our own send until the carrier hands it back; author is the party that sent it; order is the
// carrier's order of the delivery. An Edit or Delete in its target's place takes the place of what that
// delivery held. A detached Edit keeps a row of its own, naming its target, and the target's row is
// resealed with the latest one's body, so the target, refetched or arriving later, opens as edited. A
// Delete reseals its target's detached edits as itself, so no text of a deleted message stays. r, when
// given, is the Receive to hand what was kept.
store_plaintext :: (d: *Db, hash: [32]u8, delivery: string, body: []u8, conv: []u8, author: string, order: s64 = 0, r: *Request = null) -> bool {
	db := d.sql;
	b, ok := parse_body(body);
	if !ok return false;
	if b.content == .Edit && b.target != delivery {
		if !sqlite.run(db, "INSERT INTO plaintexts(hash, delivery, sealed, conversation, author, target, ord) VALUES(?, nullif(?, X''), ?, ?, ?, ?, ?);",
				cast([]u8) hash, cast([]u8) delivery, seal(d, ad("plaintexts", hash), body), conv, cast([]u8) author, cast([]u8) b.target, order)
			return false;
		latest := latest_detached(d, conv, b.target, author);
		defer crypto.zero(latest);
		return reseal(d, "SELECT hash, sealed FROM plaintexts WHERE delivery = ? AND conversation = ? AND author = ? AND target IS NULL;", b.target, conv, author, latest);
	}
	if b.content == .Delete && !reseal(d, "SELECT hash, sealed FROM plaintexts WHERE target = ? AND conversation = ? AND author = ?;", delivery, conv, author, body) return false;
	if replaces(b.content) && !sqlite.run(db, "DELETE FROM plaintexts WHERE delivery = ? AND conversation = ? AND target IS NULL;", cast([]u8) delivery, conv) return false;
	latest: []u8;
	defer crypto.zero(latest);
	if !replaces(b.content) && delivery.count latest = latest_detached(d, conv, delivery, author);
	if latest.count && r {
		free(r.out_text);
		free(r.target);
		free(r.reply);
		free(r.forward_author);
		free(r.forward_at);
		for * r.files { crypto.zero(*it.key); free(it.name); free(it.mime); free(it.description); }
		r.files.count = 0;
		for r.stickers free(it);
		r.stickers.count = 0;
		if !take_plaintext(r, latest) return false;
	}
	return sqlite.run(db, "INSERT INTO plaintexts(hash, delivery, sealed, conversation, author) VALUES(?, nullif(?, X''), ?, ?, ?);",
		cast([]u8) hash, cast([]u8) delivery, seal(d, ad("plaintexts", hash), ifx latest.count then latest else body), conv, cast([]u8) author);
}

// latest_detached is the body of author's latest detached Edit of target (temp), ours not yet handed back
// first, or empty.
latest_detached :: (d: *Db, conv: []u8, target: string, author: string) -> []u8 {
	st := sqlite.prepare(d.sql, "SELECT hash, sealed FROM plaintexts WHERE conversation = ? AND target = ? AND author = ? ORDER BY delivery IS NULL DESC, ord DESC LIMIT 1;");
	defer sqlite.finalize(st);
	if !sqlite.bind_all(st, conv, cast([]u8) target, cast([]u8) author) || sqlite.step(st) != .Row return .[];
	b := sqlite.col_blob(st, 1);
	pt := NewArray(max(b.count - SEAL_BYTES, 0), u8,, temp);
	if !unseal(d, ad("plaintexts", sqlite.col_blob(st, 0)), b, pt) return .[];
	return pt;
}

// reseal gives every row the query (delivery, conversation, author) picks the plaintext body, sealed
// under its own hash, leaving deleted messages deleted.
reseal :: (d: *Db, query: string, delivery: string, conv: []u8, author: string, body: []u8) -> bool {
	if !body.count return true;
	hashes: [..][32]u8;
	hashes.allocator = temp;
	st := sqlite.prepare(d.sql, query);
	sqlite.bind_all(st, cast([]u8) delivery, conv, cast([]u8) author);
	while sqlite.step(st) == .Row {
		h, b := sqlite.col_blob(st, 0), sqlite.col_blob(st, 1);
		if h.count != 32 || b.count <= SEAL_BYTES continue;
		pt := NewArray(b.count - SEAL_BYTES, u8,, temp);
		defer crypto.zero(pt);
		if !unseal(d, ad("plaintexts", h), b, pt) || (pt[0] & ~FLAGS) == xx Content.Delete continue;
		array_add(*hashes, (cast(*[32]u8) h.data).*);
	}
	sqlite.finalize(st);
	for hashes if !sqlite.run(d.sql, "UPDATE plaintexts SET sealed = ? WHERE hash = ?;", seal(d, ad("plaintexts", it), body), cast([]u8) it) return false;
	return true;
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
	if !sqlite.exec(db, "PRAGMA secure_delete=ON;") || !migrate(db, d.path) {
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

migrate :: (db: *sqlite.DB, path: string) -> bool {
	st := sqlite.prepare(db, "PRAGMA user_version;");
	if !st return false;
	version := ifx sqlite.step(st) == .Row then sqlite.col_int(st, 0) else -1;
	sqlite.finalize(st);
	if version < 0 return false;
	if version > MIGRATIONS.count {
		log_error("e2e: the database is schema version %, newer than this fastcord's %", version, MIGRATIONS.count);
		return false;
	}
	// A copy as the file was before this update, kept beside it and never overwritten, so a migration with
	// a bug can be undone. It holds no more than the file did, sealed the same way. No copy, no migration.
	if version > 0 && version < MIGRATIONS.count && path != ":memory:" {
		backup := tprint("%.pre-v%", path, MIGRATIONS.count);
		if !file_exists(backup) {
			if !sqlite.run(db, "VACUUM INTO ?;", backup) {
				log_error("e2e: cannot back up % before updating it: %", path, sqlite.errmsg(db));
				return false;
			}
			log("e2e: backed up % to % before updating it to schema %", path, backup, MIGRATIONS.count);
		}
	}
	for i: version..MIGRATIONS.count-1 {
		ok := sqlite.exec(db, "BEGIN;") && sqlite.exec(db, MIGRATIONS[i])
			&& sqlite.exec(db, tprint("PRAGMA user_version = %;", i + 1)) && sqlite.exec(db, "COMMIT;");
		if !ok { sqlite.exec(db, "ROLLBACK;"); return false; }
	}
	return true;
}
