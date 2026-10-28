// E2E module check: jai build.jai - run src/tests/e2e.jai, then build/e2e.exe. Writes only under build/e2e_test.
#import "Basic";
#import "File";
#import "File_Utilities";
#import "Random";
#import "String";
e2e :: #import "e2e";
keys :: #import "keys";
sqlite :: #import "sqlite";
#if OS == .WINDOWS {
	msvcprt :: #library,system,no_dll,link_always "msvcprt";
	ws2_32 :: #library,system,link_always "ws2_32"; // BoringSSL's socket BIOs come in with the AEADs.
}

Put :: struct { #as using job: e2e.Job; value: s64; ok: bool; }
Get :: struct { #as using job: e2e.Job; value: s64; found: bool; }

failed := 0;
check :: (ok: bool, what: string, loc := #caller_location) {
	if !ok { print("FAIL: % (line %)\n", what, loc.line_number); failed += 1; }
}
wait :: (j: *e2e.Job) { while !e2e.is_done(j) sleep_milliseconds(1); }
stop :: (d: *e2e.Db) {
	e2e.stop(d);
	while !e2e.stopped(d) sleep_milliseconds(1);
	e2e.destroy(d);
}

main :: () {
	dir := "build/e2e_test";
	delete_directory(dir);
	database(dir);
	codec();
	conversation(dir);
	if failed { print("e2e: % failed\n", failed); exit(1); }
	print("e2e: ok\n");
}

database :: (dir: string) {
	path := tprint("%/sub/fastcord.db", dir);
	d := e2e.start(path);
	puts: [3]Put;
	for *puts {
		it.value = it_index + 1;
		it.run = (d: *e2e.Db, j: *e2e.Job) {
			p := cast(*Put) j;
			p.ok = sqlite.run(d.sql, "INSERT OR REPLACE INTO meta(key, value) VALUES('n', ?);", p.value);
		};
		e2e.submit(d, it);
	}
	e2e.stop(d);
	while !e2e.stopped(d) sleep_milliseconds(1);
	for puts check(e2e.is_done(*it) && !it.failed && it.ok, "queued jobs run before stop");
	e2e.destroy(d);
	wal := file_exists(tprint("%-wal", path)) && read_entire_file(tprint("%-wal", path)).count > 0;
	check(!wal, "WAL checkpointed into the main file on stop");

	d = e2e.start(path);
	g: Get;
	g.run = (d: *e2e.Db, j: *e2e.Job) {
		g := cast(*Get) j;
		st := sqlite.prepare(d.sql, "SELECT value FROM meta WHERE key = 'n';");
		if sqlite.step(st) == .Row { g.found = true; g.value = sqlite.col_int(st, 0); }
		sqlite.finalize(st);
	};
	e2e.submit(d, *g);
	wait(*g);
	check(g.found && g.value == 3, "jobs run in order and persist across a reopen");

	// A second connection to the same file, as a second fastcord on one <state> would make, is refused.
	d2 := e2e.start(path);
	g2: Get;
	g2.run = g.run;
	e2e.submit(d2, *g2);
	wait(*g2);
	check(g2.failed, "second opener of a held database fails");
	stop(d2);
	stop(d);

	// A path that can't be a database fails every job instead of running it.
	write_entire_file(tprint("%/bad.db", dir), "not a database, long enough to fill a header page...........................................");
	d = e2e.start(tprint("%/bad.db", dir));
	g3: Get;
	g3.run = g.run;
	e2e.submit(d, *g3);
	wait(*g3);
	check(g3.failed && !g3.found && d.error != "", "unreadable database fails jobs");
	stop(d);
}

codec :: () {
	p, q: e2e.Packet;
	for n: 0..e2e.MAX_PACKET {
		p.count = n;
		for i: 0..n-1 p.data[i] = xx (random_get() & 0xFF);
		t := e2e.encode_text(e2e.bytes(*p));
		ok := e2e.decode_text(t, *q);
		if n < 2 { check(!ok, "packets under two bytes rejected"); continue; }
		if !ok || q.count != n || memcmp(p.data.data, q.data.data, n) != 0 { check(false, tprint("round trip of % bytes", n)); break; }
		if n == e2e.MAX_PACKET check(t.count <= 2000, "largest packet fits one message");
		if n % 3 && t.count {
			// The last character's unused low bits must be zero: a second spelling is rejected.
			bad := copy_string(t,, temp);
			B64 :: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
			bad[bad.count - 1] = B64[(find_index_from_left(B64, t[t.count - 1]) + 1) & 63];
			check(!e2e.decode_text(bad, *q) || q.count != n || memcmp(p.data.data, q.data.data, n) != 0, "non-canonical tail rejected");
		}
	}
	check(!e2e.decode_text("fc-AAA=", *q), "padding rejected");
	check(!e2e.decode_text("fc-AA+A", *q), "standard alphabet rejected");
	check(!e2e.decode_text("fc-AAAAA", *q), "impossible length rejected");
	check(!e2e.decode_text(tprint("fc-%", repeat("A", 2000)), *q), "overlong rejected");
}

Client :: struct {
	d: *e2e.Db;
	me: e2e.Identity;
	user: u64;
}

CHANNEL :: 100;
next_message: u64 = 1000;

ask :: (c: *Client, op: e2e.Op, text := "", author: u64 = 0, message: u64 = 0, peer: u64 = 0, channel: u64 = CHANNEL) -> *e2e.Request {
	r := e2e.request(op, channel, text);
	r.me, r.me_user, r.author, r.message, r.peer = c.me, c.user, author, message, peer;
	e2e.submit(c.d, r);
	wait(r);
	return r;
}

Delivery :: struct { text: string; author: u64; message: u64; plain: string; forged: bool; }

conversation :: (dir: string) {
	a := Client.{d = e2e.start(tprint("%/a.db", dir)), me = e2e.identity_of(keys.generate("A")), user = 1};
	b := Client.{d = e2e.start(tprint("%/b.db", dir)), me = e2e.identity_of(keys.generate("B")), user = 2};

	r := ask(*a, .Send, "too early");
	check(r.result == .No_Session, "send before any session");

	hello := ask(*b, .Hello);
	check(hello.result == .Ok && begins_with(hello.packet, "fc-") && hello.packet.count <= 2000, "hello fits a message");
	hello_id := next_message; next_message += 1;
	r = ask(*a, .Receive, hello.packet, b.user, hello_id);
	check(r.result == .Hello && !r.accepted, "peer's hello shown with Accept");
	r = ask(*b, .Receive, hello.packet, b.user, hello_id);
	check(r.result == .Hello, "own hello shown");

	write_entire_file(tprint("%/hello.txt", dir), hello.packet); // For looking at the UI with a real Hello.
	init := ask(*a, .Accept, hello.packet, peer = b.user);
	check(init.result == .Ok && init.packet.count <= 2000, tprint("accept makes an init that fits (%, % chars)", init.result, init.packet.count));
	r = ask(*a, .Receive, hello.packet, b.user, hello_id);
	check(r.result == .Hello && r.accepted, "accepted hello no longer offers Accept");

	// A sends before B has seen the Init: B can't open it yet, then can once the Init arrives.
	early := ask(*a, .Send, "early");
	early_id := next_message; next_message += 1;
	r = ask(*b, .Receive, early.packet, a.user, early_id);
	check(r.result == .No_Session, "msg before its init waits for the session");

	init_id := next_message; next_message += 1;
	r = ask(*b, .Receive, init.packet, a.user, init_id);
	check(r.result == .Ok && r.content == .Accept, "init opens on the peer");
	r = ask(*b, .Receive, init.packet, a.user, init_id);
	check(r.result == .Ok && r.content == .Accept, "receiving the same message twice is harmless");
	r = ask(*b, .Receive, init.packet, a.user, next_message);
	check(r.result == .Repeated, "init replayed as another message");
	r = ask(*a, .Receive, init.packet, a.user, init_id);
	check(r.result == .Ok && r.content == .Accept, "own init echo");
	r = ask(*b, .Receive, early.packet, a.user, early_id);
	check(r.result == .Ok && r.out_text == "early", "waiting msg opens after the init");

	reposted := ask(*a, .Send, "mine");
	r = ask(*a, .Receive, reposted.packet, b.user, next_message);
	check(r.result == .Repeated, "our packet reposted by the peer before our echo isn't shown as theirs");
	next_message += 1;
	r = ask(*a, .Receive, reposted.packet, a.user, next_message);
	check(r.result == .Ok && r.out_text == "mine", "our echo still claims it");
	next_message += 1;

	long := ask(*a, .Send, repeat("x", e2e.MAX_TEXT_BYTES + 1));
	check(long.result == .Too_Long, "text over the packet limit refused");
	full := ask(*a, .Send, repeat("x", e2e.MAX_TEXT_BYTES));
	check(full.result == .Ok && full.packet.count <= 2000, "longest text fits one message");
	short1 := ask(*a, .Send, "ok");
	short2 := ask(*a, .Send, repeat("y", e2e.PAD_BLOCK - 2));
	block2 := ask(*a, .Send, repeat("y", e2e.PAD_BLOCK - 1));
	check(short1.packet.count == short2.packet.count && block2.packet.count > short2.packet.count, "lengths are padded to the block");
	for string.["", "\x80\x00", "x\x00\x00", "x\x80y"] {
		_, ok := e2e.unpad(cast([]u8) it);
		check(!ok, tprint("bad padding % refused", it_index));
	}
	sent := (*e2e.Request).[short1, short2, block2];
	lengths := int.[2, e2e.PAD_BLOCK - 2, e2e.PAD_BLOCK - 1];
	for sent {
		got := ask(*b, .Receive, it.packet, a.user, next_message);
		check(got.result == .Ok && got.out_text.count == lengths[it_index], "padded text opens");
		next_message += 1;
	}

	// The carrier: each packet is dropped, duplicated as another message, held back, forged or delivered.
	pending: [..]Delivery;
	seen: [..]string;
	delivered, dropped, opened, replays, forgeries := 0, 0, 0, 0, 0;
	random_seed(7);
	for round: 0..399 {
		from, to := ifx random_get() & 1 then *a else *b, ifx random_get() & 1 then *b else *a;
		if from == to to = ifx from == *a then *b else *a;
		text := tprint("message % from %", round, from.user);
		s := ask(from, .Send, text);
		if s.result != .Ok { check(false, "send"); continue; }
		echo := ask(from, .Receive, s.packet, from.user, next_message);
		check(echo.result == .Ok && echo.out_text == text, "own echo shows our plaintext");
		array_add(*pending, .{copy_string(s.packet), from.user, next_message, copy_string(text), false});
		next_message += 1;
		roll := random_get() % 100;
		if roll < 10 { dropped += 1; pop(*pending); continue; }
		if roll < 20 {
			d := peek(pending);
			array_add(*pending, .{d.text, d.author, next_message, d.plain, false}); // A replay under a new message ID.
			next_message += 1;
		}
		if roll < 25 {
			d := peek(pending);
			forged := copy_string(d.text);
			i := 3 + cast(int) (random_get() % cast(u64) (forged.count - 3));
			forged[i] = xx ifx forged[i] == #char "A" then #char "B" else #char "A";
			array_add(*pending, .{forged, d.author, next_message, "", true});
			next_message += 1;
		}
		// Deliver a random held packet, so order is shuffled. The first copy of a packet to arrive opens;
		// every later copy, under another message ID, is a replay.
		while pending.count > 3 || (pending.count && random_get() % 3 == 0) {
			i := cast(int) (random_get() % cast(u64) pending.count);
			d := pending[i];
			array_unordered_remove_by_index(*pending, i);
			target := ifx d.author == a.user then *b else *a;
			got := ask(target, .Receive, d.text, d.author, d.message);
			delivered += 1;
			if d.forged {
				check(got.result == .Undecryptable || got.result == .No_Session, tprint("forgery rejected (%)", got.result));
				forgeries += 1;
			} else if array_find(seen, d.text) {
				check(got.result == .Repeated, "replay detected");
				replays += 1;
			} else {
				check(got.result == .Ok && got.out_text == d.plain, tprint("delivery opens (%: %)", got.result, d.plain));
				array_add(*seen, d.text);
				opened += 1;
			}
		}
	}
	print("carrier: % delivered, % opened, % dropped, % replays, % forgeries\n", delivered, opened, dropped, replays, forgeries);
	check(opened > 200 && replays > 10 && forgeries > 5, "the carrier exercised every case");

	// Outbox: a packet committed but not handed to Discord is offered again; once sent it's gone.
	s := ask(*a, .Send, "crash before send");
	o := ask(*a, .Outbox);
	found := false;
	for o.outbox if it.packet == s.packet found = true;
	check(found, "unsent packet stays in the outbox");
	ask(*a, .Sent, s.packet);
	o = ask(*a, .Outbox);
	found = false;
	for o.outbox if it.packet == s.packet found = true;
	check(!found, "sent packet leaves the outbox");

	// Unknown key-share: Discord copies B's Hello into A's DM with M (channel 101), shown as M's. A accepts,
	// and Discord moves A's Init into A and B's DM. B must not open it as A's.
	MALLORY :: 3;
	moved_hello := ask(*b, .Hello);
	r = ask(*a, .Receive, moved_hello.packet, MALLORY, next_message, channel = 101);
	check(r.result == .Hello, "copied hello looks like M's");
	next_message += 1;
	moved_init := ask(*a, .Accept, moved_hello.packet, peer = MALLORY, channel = 101);
	check(moved_init.result == .Ok, "A accepts the copied hello");
	r = ask(*b, .Receive, moved_init.packet, a.user, next_message);
	check(r.result == .Undecryptable, "an init made for another DM doesn't open");
	next_message += 1;

	// Safety numbers: both sides see the same digits, and a peer's new root is flagged.
	la := ask(*a, .Load);
	lb := ask(*b, .Load);
	eq :: (x: [$N]u8, y: [N]u8) -> bool { return memcmp(x.data, y.data, N) == 0; }
	check(la.has_peer && la.peer == b.user && eq(la.peer_root, b.me.root) && !la.verified && !la.key_changed, "A knows B's root");
	check(lb.has_peer && eq(lb.peer_root, a.me.root), "B knows A's root");
	sn := e2e.safety_number(a.me.root, b.me.root);
	check(eq(sn, e2e.safety_number(b.me.root, a.me.root)), "safety number is the same from both sides");
	for sn check(it >= #char "0" && it <= #char "9", "safety number is digits");
	v := e2e.request(.Set_Verified);
	v.peer, v.peer_root, v.verified = b.user, b.me.root, true;
	e2e.submit(a.d, v);
	wait(v);
	check(ask(*a, .Load).verified, "verified sticks");
	b2 := Client.{d = e2e.start(tprint("%/b2.db", dir)), me = e2e.identity_of(keys.generate("B2")), user = b.user};
	check(!eq(e2e.safety_number(a.me.root, b2.me.root), sn), "a new root makes a new safety number");
	NEW_DM :: 102;
	h2 := ask(*b2, .Hello, channel = NEW_DM);
	r = ask(*a, .Receive, h2.packet, b.user, next_message, channel = NEW_DM);
	check(r.result == .Hello && r.key_changed, "a Hello with B's new root is flagged");
	next_message += 1;
	ask(*a, .Accept, h2.packet, peer = b.user, channel = NEW_DM);
	la = ask(*a, .Load, channel = NEW_DM);
	check(eq(la.peer_root, b2.me.root) && la.key_changed && !la.verified, "accepting B's new root drops verification and flags it");
	v = e2e.request(.Set_Verified);
	v.peer, v.peer_root, v.verified = b.user, b2.me.root, false;
	e2e.submit(a.d, v);
	wait(v);
	la = ask(*a, .Load, channel = NEW_DM);
	check(!la.key_changed && !la.verified, "dismissing clears the flag");
	stop(b2.d);

	// Prekeys: an unanswered Hello's go after a week.
	stale := ask(*b, .Hello);
	sql(b.d, "UPDATE prekeys SET created = created - 8 * 86400000;");
	check(count(b.d, "SELECT count(*) FROM prekeys;") > 0, "prekeys stored");
	fresh := ask(*b, .Hello);
	check(count(b.d, "SELECT count(*) FROM prekeys;") == 1, "a week-old unanswered hello's prekeys are deleted");
	sql(b.d, "UPDATE prekeys SET answered = 1;");
	ask(*b, .Hello);
	check(count(b.d, "SELECT count(*) FROM prekeys;") == 1, "an answered hello's prekeys go after a day");

	// Sessions survive a restart.
	stop(a.d);
	a.d = e2e.start(tprint("%/a.db", dir));
	s = ask(*a, .Send, "after restart");
	got := ask(*b, .Receive, s.packet, a.user, next_message);
	check(got.result == .Ok && got.out_text == "after restart", "session survives a restart");

	// At rest: secrets are sealed under the database key, each bound to its row.
	again := ask(*b, .Receive, s.packet, a.user, next_message);
	check(again.result == .Ok && again.out_text == "after restart", "a refetch reads the sealed plaintext");
	sql(b.d, "UPDATE plaintexts SET sealed = (SELECT sealed FROM plaintexts AS p WHERE p.hash != plaintexts.hash LIMIT 1);");
	again = ask(*b, .Receive, s.packet, a.user, next_message);
	check(again.result == .Failed, "a sealed value moved to another row doesn't open");
	stop(a.d);
	stop(b.d);
	for name: string.["a.db", "b.db"]
		check(!contains(read_entire_file(tprint("%/%", dir, name)), "after restart"), tprint("no plaintext in %", name));

	// A key that won't unwrap (a <state> copied from another machine) sets the file aside for a new one.
	a.d = e2e.start(tprint("%/a.db", dir));
	sql(a.d, "UPDATE meta SET value = X'00' WHERE key = 'db_key';");
	stop(a.d);
	a.d = e2e.start(tprint("%/a.db", dir));
	r = ask(*a, .Load);
	check(!r.failed && r.result == .Ok && !r.has_session, "a sealed database is replaced by an empty one");
	aside := false;
	for file_list(dir) if contains(it, "a.db.sealed-") aside = true;
	check(aside, "the sealed database is kept beside it");
	stop(a.d);
}

Sql :: struct { #as using job: e2e.Job; text: string; value: s64; }

sql :: (d: *e2e.Db, text: string) -> s64 {
	j: Sql;
	j.text = text;
	j.run = (d: *e2e.Db, j: *e2e.Job) {
		q := cast(*Sql) j;
		st := sqlite.prepare(d.sql, q.text);
		if sqlite.step(st) == .Row q.value = sqlite.col_int(st, 0);
		sqlite.finalize(st);
	};
	e2e.submit(d, *j);
	wait(*j);
	return j.value;
}

count :: (d: *e2e.Db, text: string) -> s64 { return sql(d, text); }

repeat :: (s: string, n: int) -> string {
	b: String_Builder;
	b.allocator = temp;
	for 1..n append(*b, s);
	return builder_to_string(*b,, temp);
}
