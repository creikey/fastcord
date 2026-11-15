/// The vault (TRANSCRIPTION.md "Encryption at rest", AT_REST.md): a write-only store in fastcord.db. Items are sealed to its public key at any time, and open only with its password.
#import "Basic";
#import "String";
crypto :: #import "crypto";
e2e :: #import "e2e";
keys :: #import "keys";
sqlite :: #import "sqlite";

// Everything here runs where the database lives: e2e jobs on the database thread, or tests on an opened
// e2e.Db. scrypt and HPKE are too slow for the UI thread anyway.

Vault :: struct {
	id: [16]u8;
	pub: [crypto.XWING_PUBLIC_BYTES]u8;
	created_ms: s64;
}

// The private key's seed. It is in memory only while unlocked; zero it with crypto.zero.
Seed :: [crypto.XWING_PRIVATE_BYTES]u8;

ITEM_TRANSCRIPT :: 1;

// create makes a vault with one password slot. Items go to the newest vault. Older ones are kept, so after
// "Start over" what they hold opens again with their own passwords. Only tests lower log2_n.
create :: (db: *sqlite.DB, password: string, log2_n := keys.SCRYPT_LOG2_N) -> Vault, bool {
	v: Vault;
	crypto.random_bytes(v.id);
	seed, pub := crypto.xwing_generate();
	defer crypto.zero(*seed);
	v.pub = pub;
	v.created_ms = unix_ms();
	slot: [16]u8;
	crypto.random_bytes(slot);
	store := slot_store(v.id);
	params, wrapped := keys.slot_password_make(seed, password, cast(string) store, slot, log2_n,, temp);
	id, pv, sv: []u8 = v.id, v.pub, slot;
	if !sqlite.exec(db, "SAVEPOINT vault_create;") return v, false;
	ok := sqlite.run(db, "INSERT INTO vault(id, created, version, pub) VALUES(?, ?, 1, ?);", id, v.created_ms, pv)
		&& sqlite.run(db, "INSERT INTO key_slots(store, id, kind, params, wrapped, created) VALUES(?, ?, ?, ?, ?, ?);", store, sv, keys.SLOT_PASSWORD, params, wrapped, v.created_ms);
	if !ok sqlite.exec(db, "ROLLBACK TO vault_create;");
	return v, sqlite.exec(db, "RELEASE vault_create;") && ok;
}

// newest: the vault that items go to, if there is one.
newest :: (db: *sqlite.DB) -> Vault, bool {
	v: Vault;
	st := sqlite.prepare(db, "SELECT id, created, pub FROM vault WHERE version = 1 ORDER BY created DESC, id DESC LIMIT 1;");
	if !st return v, false;
	defer sqlite.finalize(st);
	if sqlite.step(st) != .Row return v, false;
	id, pub := sqlite.col_blob(st, 0), sqlite.col_blob(st, 2);
	if id.count != v.id.count || pub.count != v.pub.count return v, false;
	memcpy(v.id.data, id.data, id.count);
	memcpy(v.pub.data, pub.data, pub.count);
	v.created_ms = sqlite.col_int(st, 1);
	return v, true;
}

Unlock_Result :: enum u8 { Ok; Wrong_Password; Changed; Failed; }

// unlock opens the seed with the password, trying each password slot. Changed means a slot opened but the
// vault's public key, kept in the clear for writing while locked, isn't the seed's: someone replaced it, and
// calls written since are sealed to their key, not this one.
unlock :: (db: *sqlite.DB, v: Vault, password: string) -> Seed, Unlock_Result {
	seed: Seed;
	st := sqlite.prepare(db, "SELECT id, params, wrapped FROM key_slots WHERE store = ? AND kind = ?;");
	if !st return seed, .Failed;
	defer sqlite.finalize(st);
	store := slot_store(v.id);
	if !sqlite.bind_all(st, store, keys.SLOT_PASSWORD) return seed, .Failed;
	while sqlite.step(st) == .Row {
		plain, ok := keys.slot_password_open(sqlite.col_blob(st, 1), sqlite.col_blob(st, 2), password, cast(string) store, sqlite.col_blob(st, 0),, temp);
		if !ok continue;
		defer crypto.zero(plain);
		if plain.count != seed.count continue;
		memcpy(seed.data, plain.data, seed.count);
		pub := crypto.xwing_public(seed);
		if !crypto.constant_time_equal(pub, v.pub) { crypto.zero(*seed); return seed, .Changed; }
		return seed, .Ok;
	}
	return seed, .Wrong_Password;
}

// ---- Writing: an item, then its records in order ----

// Its key is in memory only while the item is written.
Item :: struct {
	id: [16]u8;
	key: [32]u8;
	seq: s64;
}

// item_begin seals a new item's key and head (what the item is about, encoded by the caller) to v's public key.
item_begin :: (db: *sqlite.DB, v: Vault, kind: u8, head: []u8) -> Item, bool {
	it: Item;
	crypto.random_bytes(it.id);
	crypto.random_bytes(it.key);
	plain := NewArray(it.key.count + head.count, u8, false,, temp);
	defer crypto.zero(plain);
	memcpy(plain.data, it.key.data, it.key.count);
	memcpy(plain.data + it.key.count, head.data, head.count);
	sealed := crypto.hpke_seal(v.pub, ITEM_INFO, item_ad(v.id, it.id, kind), plain,, temp);
	id, vid: []u8 = it.id, v.id;
	ok := sealed.count > 0 && sqlite.run(db, "INSERT INTO vault_items(id, vault, kind, created, head) VALUES(?, ?, ?, ?, ?);", id, vid, kind, unix_ms(), sealed);
	if !ok crypto.zero(*it.key);
	return it, ok;
}

// item_append writes the item's next record.
item_append :: (db: *sqlite.DB, it: *Item, record: []u8) -> bool {
	sealed := keys.box_seal(it.key, record_ad(it.id, it.seq), record,, temp);
	id: []u8 = it.id;
	if !sqlite.run(db, "INSERT INTO vault_records(item, seq, sealed) VALUES(?, ?, ?);", id, it.seq, sealed) return false;
	it.seq += 1;
	return true;
}

item_close :: (it: *Item) { crypto.zero(*it.key); }

// ---- Reading, with the seed ----

Item_Row :: struct {
	id: [16]u8;
	kind: u8;
	created_ms: s64;
}

// items: v's items, oldest first, in context.allocator.
items :: (db: *sqlite.DB, v: Vault) -> [..]Item_Row, bool {
	out: [..]Item_Row;
	st := sqlite.prepare(db, "SELECT id, kind, created FROM vault_items WHERE vault = ? ORDER BY created, id;");
	if !st return out, false;
	defer sqlite.finalize(st);
	vid: []u8 = v.id;
	if !sqlite.bind_all(st, vid) return out, false;
	while sqlite.step(st) == .Row {
		id, kind := sqlite.col_blob(st, 0), sqlite.col_int(st, 1);
		if id.count != 16 || kind < 0 || kind > 255 continue;
		r := array_add(*out);
		memcpy(r.id.data, id.data, 16);
		r.kind, r.created_ms = xx kind, sqlite.col_int(st, 2);
	}
	return out, true;
}

// item_open: the item's key and head, the head in context.allocator. False if the head was changed, or
// moved to another item, kind or vault.
item_open :: (db: *sqlite.DB, v: Vault, seed: Seed, row: Item_Row) -> key: [32]u8, head: []u8, ok: bool {
	key: [32]u8;
	st := sqlite.prepare(db, "SELECT head FROM vault_items WHERE id = ? AND vault = ? AND kind = ?;");
	if !st return key, .[], false;
	defer sqlite.finalize(st);
	id, vid: []u8 = row.id, v.id;
	if !sqlite.bind_all(st, id, vid, row.kind) || sqlite.step(st) != .Row return key, .[], false;
	plain, ok := crypto.hpke_open(seed, ITEM_INFO, item_ad(v.id, row.id, row.kind), sqlite.col_blob(st, 0),, temp);
	if !ok return key, .[], false;
	defer crypto.zero(plain);
	if plain.count < key.count return key, .[], false;
	memcpy(key.data, plain.data, key.count);
	return key, array_copy(array_view(plain, key.count, plain.count - key.count)), true;
}

Record :: struct {
	seq: s64;
	plain: []u8; // In context.allocator, and empty when it didn't open.
	ok: bool;
}

// records: an item's records in order, in context.allocator. complete is false when one didn't open or a
// sequence number is missing, so the database was edited. Only an End record shows the last ones are there.
records :: (db: *sqlite.DB, item: [16]u8, key: [32]u8) -> [..]Record, complete: bool {
	out: [..]Record;
	st := sqlite.prepare(db, "SELECT seq, sealed FROM vault_records WHERE item = ? ORDER BY seq;");
	if !st return out, false;
	defer sqlite.finalize(st);
	id: []u8 = item;
	if !sqlite.bind_all(st, id) return out, false;
	complete := true;
	while sqlite.step(st) == .Row {
		if out.count == MAX_RECORDS return out, false;
		seq := sqlite.col_int(st, 0);
		if seq != out.count complete = false;
		plain, ok := keys.box_open(key, record_ad(item, seq), sqlite.col_blob(st, 1));
		if !ok complete = false;
		array_add(*out, .{seq, plain, ok});
	}
	return out, complete;
}

// A day-long call with a line every second is 86400 records.
MAX_RECORDS :: 1_000_000;

// ---- Fields: what records and heads hold ----
//
// A record or head is a list of fields: a tag byte, a u32 little-endian length, then the value. Readers skip
// tags they don't know, so a later field (an embedding vector, say) needs no new version. Integers are
// 8 bytes, little-endian.

Field :: struct { tag: u8; value: []u8; }

field :: (b: *[..]u8, tag: u8, value: []u8) {
	assert(value.count <= 0xFFFF_FFFF);
	n := value.count;
	array_add(b, tag);
	for 0..3 array_add(b, cast,trunc(u8) (n >> (8 * it)));
	array_add(b, ..value);
}
field :: (b: *[..]u8, tag: u8, value: string) { field(b, tag, cast([]u8) value); }
field :: (b: *[..]u8, tag: u8, value: s64) {
	v: [8]u8;
	for 0..7 v[it] = cast,trunc(u8) (value >> (8 * it));
	field(b, tag, v);
}

// fields: the input's fields as views into it, in temp. False when a field runs past the end.
fields :: (b: []u8) -> []Field, bool {
	out: [..]Field;
	out.allocator = temp;
	at := 0;
	while at < b.count {
		if b.count - at < 5 return out, false;
		n := 0;
		for < 1..4 n = (n << 8) | b[at + it];
		if n > b.count - at - 5 return out, false;
		array_add(*out, .{b[at], array_view(b, at + 5, n)});
		at += 5 + n;
	}
	return out, true;
}

as_int :: (f: Field) -> s64, bool {
	if f.value.count != 8 return 0, false;
	v: s64;
	for < 0..7 v = (v << 8) | f.value[it];
	return v, true;
}

// ---- Transcripts (ITEM_TRANSCRIPT) ----

Line_Kind :: enum u8 { Said :: 1; Not_Recordable :: 2; Fell_Behind :: 3; End :: 4; }

// A Line is one record of a transcript. A call's last record is an End, so a transcript without one ended
// unexpectedly: fastcord quit or crashed mid-call, or the database was cut.
Line :: struct {
	kind: Line_Kind;
	at_ms, end_ms: s64;
	speaker: u64;    // The carrier's opaque user ID.
	who: string;     // Their name as shown at the time.
	text: string;
	dropped_ms: s64; // Fell_Behind: how much speech wasn't transcribed.
}

Head :: struct {
	title: string; // The channel's name.
	place: string; // The server's name, or "" for a DM call.
	model: string;
	started_ms: s64;
}

TAG_KIND :: 1;
TAG_AT :: 2;
TAG_END :: 3;
TAG_SPEAKER :: 4;
TAG_WHO :: 5;
TAG_TEXT :: 6;
TAG_DROPPED :: 7;

TAG_TITLE :: 1;
TAG_PLACE :: 2;
TAG_MODEL :: 3;
TAG_STARTED :: 4;

// encode_line and encode_head are in context.allocator.
encode_line :: (l: Line) -> []u8 {
	b: [..]u8;
	field(*b, TAG_KIND, cast(s64) l.kind);
	field(*b, TAG_AT, l.at_ms);
	if l.end_ms field(*b, TAG_END, l.end_ms);
	if l.speaker field(*b, TAG_SPEAKER, cast,no_check(s64) l.speaker);
	if l.who field(*b, TAG_WHO, l.who);
	if l.text field(*b, TAG_TEXT, l.text);
	if l.dropped_ms field(*b, TAG_DROPPED, l.dropped_ms);
	return b;
}

// decode_line: its strings are views into b. False for a malformed record or an unknown kind.
decode_line :: (b: []u8) -> Line, bool {
	l: Line;
	fs, ok := fields(b);
	if !ok return l, false;
	for fs {
		v: s64;
		if it.tag == {
			case TAG_KIND;
				v, ok = as_int(it);
				if ok && (v < xx Line_Kind.Said || v > xx Line_Kind.End) ok = false;
				l.kind = cast,no_check(Line_Kind) v;
			case TAG_AT;      l.at_ms, ok = as_int(it);
			case TAG_END;     l.end_ms, ok = as_int(it);
			case TAG_SPEAKER; v, ok = as_int(it); l.speaker = cast,no_check(u64) v;
			case TAG_WHO;     l.who = cast(string) it.value;
			case TAG_TEXT;    l.text = cast(string) it.value;
			case TAG_DROPPED; l.dropped_ms, ok = as_int(it);
		}
		if !ok return l, false;
	}
	return l, cast(u8) l.kind != 0;
}

encode_head :: (h: Head) -> []u8 {
	b: [..]u8;
	if h.title field(*b, TAG_TITLE, h.title);
	if h.place field(*b, TAG_PLACE, h.place);
	if h.model field(*b, TAG_MODEL, h.model);
	field(*b, TAG_STARTED, h.started_ms);
	return b;
}

decode_head :: (b: []u8) -> Head, bool {
	h: Head;
	fs, ok := fields(b);
	if !ok return h, false;
	for fs {
		if it.tag == {
			case TAG_TITLE;   h.title = cast(string) it.value;
			case TAG_PLACE;   h.place = cast(string) it.value;
			case TAG_MODEL;   h.model = cast(string) it.value;
			case TAG_STARTED; h.started_ms, ok = as_int(it);
		}
		if !ok return h, false;
	}
	return h, true;
}

// ---- Jobs: the app's writes, on the database thread ----

// A Call is one transcript being written. The app makes it as the call starts and frees it with call_free
// once the job with end_ms set is done. Only jobs touch it after that, so it needs no lock.
Call :: struct {
	head: []u8;   // Encoded, heap.
	begun: bool;  // The item exists.
	failed: bool; // No vault, or a write failed: the rest of the call is dropped.
	item: Item;
}

call_start :: (head: Head) -> *Call {
	c := New(Call);
	c.head = encode_head(head);
	return c;
}

call_free :: (c: *Call) {
	crypto.zero(c.head);
	array_free(c.head);
	crypto.zero(c);
	free(c);
}

// A Write adds lines to a call. The call's last one has end_ms set and adds its End record. The item is made
// at the first line, so a call where nobody spoke leaves nothing.
Write :: struct {
	#as using job: e2e.Job;
	call: *Call;
	records: [..][]u8; // Encoded, heap.
	end_ms: s64;
	ok: bool;
}

write :: (c: *Call, lines: []Line, end_ms: s64 = 0) -> *Write {
	w := New(Write);
	w.run = run_write;
	w.call, w.end_ms = c, end_ms;
	for lines array_add(*w.records, encode_line(it));
	return w;
}

free_write :: (w: *Write) {
	for w.records { crypto.zero(it); array_free(it); }
	array_free(w.records);
	free(w);
}

unix_ms :: () -> s64 { return to_milliseconds(current_time_consensus() - APOLLO_TIME_FOR_JAN_1_1970); }

// Has answers the app's question at startup: is there a vault to write to?
Has :: struct {
	#as using job: e2e.Job;
	found: bool;
}

has :: () -> *Has {
	h := New(Has);
	h.run = (d: *e2e.Db, j: *e2e.Job) { _, found := newest(d.sql); (cast(*Has) j).found = found; };
	return h;
}

#scope_file

ITEM_INFO :: "fc-drop-v1 vault item";

// slot_store: the key slots' store name for a vault, bound as a blob so it never compares unequal to itself.
slot_store :: (id: [16]u8) -> []u8 { return cast([]u8) join("vault ", to_string(id.data, id.count),, temp); }

item_ad :: (vault: [16]u8, item: [16]u8, kind: u8) -> []u8 {
	k := kind;
	return keys.lp_join("fc-vault-v1 item", to_string(vault.data, vault.count), to_string(item.data, item.count), to_string(*k, 1));
}

record_ad :: (item: [16]u8, seq: s64) -> []u8 {
	row: [24]u8;
	memcpy(row.data, item.data, item.count);
	for 0..7 row[16 + it] = cast,trunc(u8) (seq >> (8 * it));
	return keys.box_ad("vault", "vault_records", "sealed", row);
}

run_write :: (d: *e2e.Db, j: *e2e.Job) {
	w := cast(*Write) j;
	c := w.call;
	defer if w.end_ms || c.failed item_close(*c.item);
	w.ok = !c.failed;
	if c.failed || (!c.begun && !w.records.count) return;
	ok := sqlite.exec(d.sql, "SAVEPOINT vault_write;");
	if ok && !c.begun {
		v: Vault;
		v, ok = newest(d.sql);
		if ok c.item, ok = item_begin(d.sql, v, ITEM_TRANSCRIPT, c.head);
		c.begun = ok;
	}
	for w.records if ok ok = item_append(d.sql, *c.item, it);
	if ok && w.end_ms {
		end := encode_line(.{kind = .End, at_ms = w.end_ms},, temp);
		ok = item_append(d.sql, *c.item, end);
	}
	if !ok sqlite.exec(d.sql, "ROLLBACK TO vault_write;");
	ok = sqlite.exec(d.sql, "RELEASE vault_write;") && ok;
	c.failed, w.ok = !ok, ok;
}
