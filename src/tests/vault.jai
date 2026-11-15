// Vault check: jai build.jai - run src/tests/vault.jai, then build/vault.exe. Its databases are in memory.
#import "Basic";
#import "String";
crypto :: #import "crypto";
e2e :: #import "e2e";
keys :: #import "keys";
sqlite :: #import "sqlite";
vault :: #import "vault";
#if OS == .WINDOWS {
	msvcprt :: #library,system,no_dll,link_always "msvcprt";
	ws2_32 :: #library,system,link_always "ws2_32"; // BoringSSL's socket BIOs come in with HPKE.
}

failed := 0;
check :: (ok: bool, what: string, loc := #caller_location) {
	if !ok { print("FAIL: % (line %)\n", what, loc.line_number); failed += 1; }
}

LOW :: 4; // scrypt's cost where the test isn't about it.
NONE: []vault.Line;

main :: () {
	format();
	d := New(e2e.Db);
	d.path = ":memory:";
	check(e2e.open(d), "open a database");
	db := d.sql;

	_, found := vault.newest(db);
	check(!found, "no vault at first");
	c := vault.call_start(.{title = "general"});
	check(!write(d, c, .[LINES[0]]), "with no vault, a call's lines are refused");
	check(c.failed && !write(d, c, NONE, 5000), "and the rest of the call too");
	vault.call_free(c);

	a, ok := vault.create(db, "correct horse", LOW);
	check(ok, "create a vault");
	b := vault.newest(db);
	check(same(b.id, a.id) && same(b.pub, a.pub), "newest is the vault just made");
	seed, r := vault.unlock(db, a, "correct horse");
	check(r == .Ok, "the right password unlocks");
	_, r = vault.unlock(db, a, "correct horse ");
	check(r == .Wrong_Password, "a wrong password doesn't");
	_, r = vault.unlock(db, a, "");
	check(r == .Wrong_Password, "nor an empty one");

	// A call as the app writes one: lines in a few frames, then its end.
	c = vault.call_start(.{title = "general", place = "a server", model = "base-en", started_ms = 1000});
	check(write(d, c, NONE) && !c.begun, "a frame with no lines makes no item");
	check(write(d, c, .[LINES[0], LINES[1]]) && write(d, c, .[LINES[2]]) && write(d, c, NONE, 9000), "a call's frames and end");
	vault.call_free(c);
	call := find(db, a, seed, "general");
	check(call.head.place == "a server" && call.head.model == "base-en" && call.head.started_ms == 1000, "the head reads back");
	check(call.complete && call.lines.count == 4, "every line reads back");
	for LINES check(same_line(call.lines[it_index], it), tprint("line % reads back", it_index));
	check(call.lines[3].kind == .End && call.lines[3].at_ms == 9000, "the last is the end");

	// A call where nobody spoke leaves nothing; one that was cut off has no end.
	c = vault.call_start(.{title = "quiet"});
	check(write(d, c, NONE, 9100), "a silent call ends");
	vault.call_free(c);
	c = vault.call_start(.{title = "cut off"});
	check(write(d, c, .[LINES[0]]), "a call that never ends");
	vault.call_free(c);
	listed := vault.items(db, a);
	check(listed.count == 2, "the silent call left nothing");
	cut := find(db, a, seed, "cut off");
	check(cut.complete && cut.lines.count == 1 && cut.lines[0].kind != .End, "a cut-off call has no end");

	// Someone edits the database.
	edit :: (db: *sqlite.DB, sql: string, args: ..Any) { ok := sqlite.run(db, sql, ..args); check(ok && sqlite.changes(db) == 1, sql); }
	id, cut_id: []u8 = call.id, cut.id;
	r1 := sealed(db, call.id, 1);
	flipped := array_copy(r1);
	flipped[flipped.count - 1] ^= 1;
	edit(db, "UPDATE vault_records SET sealed = ? WHERE item = ? AND seq = 1;", flipped, id);
	got := find(db, a, seed, "general");
	check(!got.complete && !got.ok[1] && got.ok[0] && got.ok[2], "a changed record fails, alone");
	edit(db, "UPDATE vault_records SET sealed = ? WHERE item = ? AND seq = 1;", sealed(db, call.id, 0), id);
	got = find(db, a, seed, "general");
	check(!got.complete && !got.ok[1], "a record copied to another seq fails");
	edit(db, "UPDATE vault_records SET sealed = ? WHERE item = ? AND seq = 1;", r1, id);
	edit(db, "DELETE FROM vault_records WHERE item = ? AND seq = 1;", id);
	got = find(db, a, seed, "general");
	check(!got.complete && got.lines.count == 3, "a deleted record leaves a gap");
	edit(db, "INSERT INTO vault_records(item, seq, sealed) VALUES(?, 1, ?);", id, r1);
	edit(db, "UPDATE vault_records SET item = ? WHERE item = ? AND seq = 3;", cut_id, id);
	got = find(db, a, seed, "general");
	check(got.complete && got.lines[got.lines.count - 1].kind != .End, "with the end moved away, the call reads as cut off");
	got = find(db, a, seed, "cut off");
	check(!got.complete, "and the record moved in fails");
	edit(db, "UPDATE vault_records SET item = ? WHERE item = ? AND seq = 3;", id, cut_id);
	head := head_of(db, call.id);
	flipped = array_copy(head);
	flipped[40] ^= 1;
	edit(db, "UPDATE vault_items SET head = ? WHERE id = ?;", flipped, id);
	check(!opens(db, a, seed, call.id), "a changed head fails");
	edit(db, "UPDATE vault_items SET head = ?, kind = 2 WHERE id = ?;", head, id);
	check(!opens(db, a, seed, call.id, 2), "an item with its kind changed fails");
	edit(db, "UPDATE vault_items SET kind = 1, head = ? WHERE id = ?;", head_of(db, cut.id), id);
	check(!opens(db, a, seed, call.id), "another item's head fails");
	edit(db, "UPDATE vault_items SET head = ? WHERE id = ?;", head, id);
	check(find(db, a, seed, "general").complete, "put back, it all opens again");

	// Start over: a new vault takes new calls, and the old one still opens with its own password.
	z, zok := vault.create(db, "new password", LOW);
	n := vault.newest(db);
	check(zok && same(n.id, z.id), "a second vault is the newest");
	c = vault.call_start(.{title = "after"});
	check(write(d, c, .[LINES[1]], 9500), "a call into the new vault");
	vault.call_free(c);
	zseed, zr := vault.unlock(db, z, "new password");
	check(zr == .Ok && find(db, z, zseed, "after").complete, "it went to the new vault");
	check(vault.items(db, a).count == 2 && find(db, a, seed, "general").complete, "the old vault's calls still open");
	_, r = vault.unlock(db, a, "new password");
	check(r == .Wrong_Password, "the new password doesn't open the old vault");
	check(!opens(db, a, zseed, call.id), "nor does the new key");

	// The public key is in the clear so calls can be sealed while locked. Replacing it is caught at unlock.
	aid, zpub: []u8 = a.id, z.pub;
	edit(db, "UPDATE vault SET pub = ? WHERE id = ?;", zpub, aid);
	a2 := a;
	a2.pub = z.pub;
	_, r = vault.unlock(db, a2, "correct horse");
	check(r == .Changed, "a replaced public key is caught");
	_, r = vault.unlock(db, a2, "wrong");
	check(r == .Wrong_Password, "a wrong password is still only wrong");

	// The real cost, once.
	t0 := current_time_monotonic();
	real, rok := vault.create(db, "slow and sure");
	t1 := current_time_monotonic();
	_, r = vault.unlock(db, real, "slow and sure");
	t2 := current_time_monotonic();
	check(rok && r == .Ok, "a vault at the real scrypt cost");
	print("create % ms, unlock % ms at 2^%\n", to_milliseconds(t1 - t0), to_milliseconds(t2 - t1), keys.SCRYPT_LOG2_N);
	crypto.zero(*seed);
	crypto.zero(*zseed);

	threaded();
	if failed { print("vault: % failed\n", failed); exit(1); }
	print("vault: ok\n");
}

Make :: struct { #as using job: e2e.Job; ok: bool; }
Read :: struct { #as using job: e2e.Job; got: Got; }

// The jobs on a real database thread, in order, as the app submits them.
threaded :: () {
	d := e2e.start(":memory:");
	h := vault.has();
	e2e.submit(d, h);
	m := New(Make);
	m.run = (d: *e2e.Db, j: *e2e.Job) { m := cast(*Make) j; _, m.ok = vault.create(d.sql, "threads", LOW); };
	e2e.submit(d, m);
	h2 := vault.has();
	e2e.submit(d, h2);
	c := vault.call_start(.{title = "threaded"});
	ws := (*vault.Write).[vault.write(c, .[LINES[0]]), vault.write(c, .[LINES[1], LINES[2]]), vault.write(c, NONE, 7000)];
	for ws e2e.submit(d, it);
	rd := New(Read);
	rd.run = (d: *e2e.Db, j: *e2e.Job) {
		rd := cast(*Read) j;
		v, _ := vault.newest(d.sql);
		seed, r := vault.unlock(d.sql, v, "threads");
		if r == .Ok rd.got = find(d.sql, v, seed, "threaded");
		crypto.zero(*seed);
	};
	e2e.submit(d, rd);
	while !e2e.is_done(rd) sleep_milliseconds(1);
	check(!h.found && m.ok && h2.found, "Has sees the vault once it's made");
	for ws check(it.ok, "each write");
	check(rd.got.complete && rd.got.lines.count == 4 && rd.got.lines[3].kind == .End, "the threaded call reads back");
	vault.call_free(c);
	for ws vault.free_write(it);
	e2e.stop(d);
	while !e2e.stopped(d) sleep_milliseconds(1);
	e2e.destroy(d);
}

// The record format is frozen once users have data: this is a line, byte for byte.
format :: () {
	b := vault.encode_line(.{kind = .Said, at_ms = 0x0102, speaker = 7, text = "hi"});
	want :: u8.[1, 8,0,0,0, 1,0,0,0,0,0,0,0,  2, 8,0,0,0, 2,1,0,0,0,0,0,0,  4, 8,0,0,0, 7,0,0,0,0,0,0,0,  6, 2,0,0,0, #char "h", #char "i"];
	check(same(b, want), "a line's bytes");
	l, ok := vault.decode_line(b);
	check(ok && l.kind == .Said && l.at_ms == 0x0102 && l.speaker == 7 && l.text == "hi" && !l.who, "and back");
	more: [..]u8;
	array_add(*more, ..b);
	vault.field(*more, 200, "a field from a later version");
	l, ok = vault.decode_line(more);
	check(ok && l.text == "hi", "an unknown field is skipped");
	_, ok = vault.decode_line(array_view(b, 0, b.count - 1));
	check(!ok, "a cut field is refused");
	bad_kind :: u8.[1, 8,0,0,0, 9,0,0,0,0,0,0,0];
	_, ok = vault.decode_line(bad_kind);
	check(!ok, "an unknown kind is refused");
	short :: u8.[1, 4,0,0,0, 1,0,0,0];
	_, ok = vault.decode_line(short);
	check(!ok, "a short integer is refused");
}

LINES :: vault.Line.[
	.{kind = .Said, at_ms = 1_700_000_000_000, end_ms = 1_700_000_004_000, speaker = 0xFFFF_FFFF_FFFF_FFFF, who = "Ada", text = "Shall we start? Ça va."},
	.{kind = .Not_Recordable, at_ms = 1_700_000_005_000, speaker = 2, who = "Grace"},
	.{kind = .Fell_Behind, at_ms = 1_700_000_006_000, dropped_ms = 12_000},
];

same :: (a: []u8, b: []u8) -> bool { return crypto.constant_time_equal(a, b); }

same_line :: (a: vault.Line, b: vault.Line) -> bool {
	return a.kind == b.kind && a.at_ms == b.at_ms && a.end_ms == b.end_ms && a.speaker == b.speaker && a.who == b.who && a.text == b.text && a.dropped_ms == b.dropped_ms;
}

write :: (d: *e2e.Db, c: *vault.Call, lines: []vault.Line, end_ms: s64 = 0) -> bool {
	w := vault.write(c, lines, end_ms);
	w.run(d, w);
	ok := w.ok;
	vault.free_write(w);
	return ok;
}

Got :: struct {
	id: [16]u8;
	head: vault.Head;
	lines: [..]vault.Line;
	ok: [..]bool;
	complete: bool;
}

// find: the vault's call with that title, opened. Items made in the same millisecond list in any order.
find :: (db: *sqlite.DB, v: vault.Vault, seed: vault.Seed, title: string) -> Got {
	got: Got;
	listed, ok := vault.items(db, v);
	check(ok, "the vault lists its items");
	for listed {
		key, head, hok := vault.item_open(db, v, seed, it);
		if !hok continue;
		h, dok := vault.decode_head(head);
		check(dok, "a head decodes");
		if h.title != title continue;
		got.id, got.head = it.id, h;
		records, complete := vault.records(db, got.id, key);
		got.complete = complete;
		for records {
			l, lok := vault.decode_line(it.plain);
			check(!it.ok || lok, "an opened record decodes");
			array_add(*got.lines, l);
			array_add(*got.ok, it.ok);
		}
		return got;
	}
	check(false, tprint("the call \"%\" is there", title));
	return got;
}

opens :: (db: *sqlite.DB, v: vault.Vault, seed: vault.Seed, id: [16]u8, kind: u8 = vault.ITEM_TRANSCRIPT) -> bool {
	_, _, ok := vault.item_open(db, v, seed, .{id = id, kind = kind});
	return ok;
}

sealed :: (db: *sqlite.DB, item: [16]u8, seq: s64) -> []u8 {
	st := sqlite.prepare(db, "SELECT sealed FROM vault_records WHERE item = ? AND seq = ?;");
	defer sqlite.finalize(st);
	id: []u8 = item;
	sqlite.bind_all(st, id, seq);
	check(sqlite.step(st) == .Row, "a record is there");
	return array_copy(sqlite.col_blob(st, 0));
}

head_of :: (db: *sqlite.DB, item: [16]u8) -> []u8 {
	st := sqlite.prepare(db, "SELECT head FROM vault_items WHERE id = ?;");
	defer sqlite.finalize(st);
	id: []u8 = item;
	sqlite.bind_all(st, id);
	check(sqlite.step(st) == .Row, "an item is there");
	return array_copy(sqlite.col_blob(st, 0));
}
