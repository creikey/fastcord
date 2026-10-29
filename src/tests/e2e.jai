// E2E module check: jai build.jai - run src/tests/e2e.jai, then build/e2e.exe. Writes only under build/e2e_test.
#import "Basic";
#import "File";
#import "File_Utilities";
#import "Random";
#import "String";
e2e :: #import "e2e";
fc_text :: #import "fc_text";
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
	args := get_command_line_arguments();
	if args.count == 3 && args[1] == "make-fixture" { make_fixture(args[2]); return; }
	dir := "build/e2e_test";
	delete_directory(dir);
	fixtures(dir);
	database(dir);
	codec();
	conversation(dir, e2e.HELLO_BYTES); // the smallest that carries a signed Hello
	conversation(dir, e2e.MAX_PACKET);  // the largest any carrier may set
	tiny(dir);
	group(dir);
	bottles(dir);
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

	// An earlier home of the file is moved to the new path on start, keeping what it holds.
	moved := tprint("%/moved/fastcord.db", dir);
	d = e2e.start(moved, moved_from = path);
	g4: Get;
	g4.run = g.run;
	e2e.submit(d, *g4);
	wait(*g4);
	check(g4.found && g4.value == 3 && !file_exists(path), "the database moves to its new home");
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

// codec checks the `fc-` text form, the encoding of the carriers that move text (Discord and hosted DMs).
codec :: () {
	p: [fc_text.MAX_PACKET]u8;
	for n: 0..fc_text.MAX_PACKET {
		for i: 0..n-1 p[i] = xx (random_get() & 0xFF);
		t := fc_text.encode(.{n, p.data});
		got, ok := fc_text.decode(t);
		if n < 2 { check(!ok, "packets under two bytes rejected"); continue; }
		if !ok || got.count != n || memcmp(p.data, got.data, n) != 0 { check(false, tprint("round trip of % bytes", n)); break; }
		if n == fc_text.MAX_PACKET check(t.count <= 2000, "largest packet fits one message");
		if n % 3 && t.count {
			// The last character's unused low bits must be zero: a second spelling is rejected.
			bad := copy_string(t,, temp);
			B64 :: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
			bad[bad.count - 1] = B64[(find_index_from_left(B64, t[t.count - 1]) + 1) & 63];
			again, aok := fc_text.decode(bad);
			check(!aok || again.count != n || memcmp(p.data, again.data, n) != 0, "non-canonical tail rejected");
		}
		reset_temporary_storage();
	}
	for string.["fc-AAA=", "fc-AA+A", "fc-AAAAA", tprint("fc-%", repeat("A", 2000))] {
		_, ok := fc_text.decode(it);
		check(!ok, tprint("bad text form % rejected", it_index));
	}
	// A packet larger than a message is attached; the text names it by hash, and no packet reads as one.
	hash: [32]u8;
	for * hash it.* = xx it_index;
	got, ok := fc_text.decode(fc_text.attached(hash));
	named, attached := fc_text.attached_hash(got);
	check(ok && attached && memcmp(named.data, hash.data, 32) == 0, "an attached packet's text names its hash");
	_, attached = fc_text.attached_hash(cast([]u8) "\x04\x03 thirty-two bytes of a real packet");
	check(!attached, "a packet isn't taken for an attachment's name");
	big := NewArray(fc_text.MAX_BUNDLE, u8,, temp);
	got, ok = fc_text.decode(fc_text.encode(big,, temp), fc_text.MAX_BUNDLE);
	check(ok && got.count == big.count, "a bundle has a text form of its own size");
	_, ok = fc_text.decode(fc_text.encode(big,, temp));
	check(!ok, "but no message holds one");
}

// The mock carrier: conversations and parties are opaque bytes (NULs included), each delivery has its
// own opaque ID, and the largest packet is set per run.
Client :: struct {
	d: *e2e.Db;
	me: e2e.Identity;
	party: string;
}

CARRIER :: "mock";
CONV :: "conv\x00one";
limit := 0;
next_delivery := 1000;

delivery :: () -> string {
	next_delivery += 1;
	return tprint("\x00d%", next_delivery);
}

ask :: (c: *Client, op: e2e.Op, packet := "", from: *Client = null, peer: *Client = null, id := CONV, text := "", from_party := "", peer_party := "", at := "") -> *e2e.Request {
	conv := e2e.Conversation.{CARRIER, id, c.party, ifx peer then peer.party else peer_party, limit};
	r := e2e.request(op, conv, text, packet);
	r.me = c.me;
	r.from = copy_string(ifx from then from.party else from_party);
	r.delivery = copy_string(ifx at then at else delivery());
	e2e.submit(c.d, r);
	wait(r);
	return r;
}

// receive hands c a packet sent by from, in their conversation.
receive :: (c: *Client, packet: string, from: *Client, at := "", id := CONV) -> *e2e.Request {
	return ask(c, .Receive, packet, from = from, peer = from, id = id, at = at);
}

send :: (c: *Client, peer: *Client, text: string) -> *e2e.Request { return ask(c, .Send, peer = peer, text = text); }

Delivery :: struct { packet: string; author: *Client; at: string; plain: string; forged: bool; }

conversation :: (dir: string, max: int) {
	limit = max;
	tag := tprint("%/%", dir, max);
	make_directory_if_it_does_not_exist(tag);
	a := Client.{d = e2e.start(tprint("%/a.db", tag)), me = e2e.identity_of(keys.generate("A")), party = "alice\x00"};
	b := Client.{d = e2e.start(tprint("%/b.db", tag)), me = e2e.identity_of(keys.generate("B")), party = "bob"};

	r := send(*a, *b, "too early");
	check(r.result == .No_Session, "send before any session");

	hello := ask(*b, .Hello, peer = *a);
	check(hello.result == .Ok && hello.packet.count <= limit, "hello fits the carrier");
	// E2E 5: the prekeys are signed by the identity's Signing key; a Hello with any byte changed is refused.
	for at: int.[40, 200, e2e.HELLO_SIGNED_BYTES - 70, e2e.HELLO_SIGNED_BYTES + 100, e2e.HELLO_BYTES - 1] {
		forged := copy_string(hello.packet,, temp);
		forged[at] ^= 1;
		_, ok := e2e.parse_hello(xx forged);
		check(!ok, tprint("a hello changed at byte % is refused", at));
	}
	_, signed := e2e.parse_hello(xx hello.packet);
	check(signed, "a signed hello verifies");
	hello_at := copy_string(delivery());
	r = receive(*a, hello.packet, *b, hello_at);
	check(r.result == .Hello && !r.accepted, "peer's hello shown with Accept");
	r = ask(*b, .Receive, hello.packet, from = *b, peer = *a, at = hello_at);
	check(r.result == .Hello, "own hello shown");

	init := ask(*a, .Accept, hello.packet, peer = *b);
	check(init.result == .Ok && init.packet.count <= limit, tprint("accept makes an init that fits (%, % bytes)", init.result, init.packet.count));
	r = receive(*a, hello.packet, *b, hello_at);
	check(r.result == .Hello && r.accepted, "accepted hello no longer offers Accept");

	// A sends before B has seen the Init: B can't open it yet, then can once the Init arrives.
	early := send(*a, *b, "early");
	early_at := copy_string(delivery());
	r = receive(*b, early.packet, *a, early_at);
	check(r.result == .No_Session, "msg before its init waits for the session");

	init_at := copy_string(delivery());
	r = receive(*b, init.packet, *a, init_at);
	check(r.result == .Ok && r.content == .Accept, "init opens on the peer");
	r = receive(*b, init.packet, *a, init_at);
	check(r.result == .Ok && r.content == .Accept, "receiving the same delivery twice is harmless");
	r = receive(*b, init.packet, *a);
	check(r.result == .Repeated, "init replayed as another delivery");
	r = ask(*a, .Receive, init.packet, from = *a, peer = *b, at = init_at);
	check(r.result == .Ok && r.content == .Accept, "own init echo");
	r = receive(*b, early.packet, *a, early_at);
	check(r.result == .Ok && r.out_text == "early", "waiting msg opens after the init");

	// @silent travels inside the packet, so it holds whatever the carrier does with its flags.
	quiet := e2e.request(.Send, .{CARRIER, CONV, a.party, b.party, limit}, "shh");
	quiet.me, quiet.silent = a.me, true;
	e2e.submit(a.d, quiet);
	wait(quiet);
	quiet_at := copy_string(delivery());
	r = receive(*b, quiet.packet, *a, quiet_at);
	check(r.result == .Ok && r.out_text == "shh" && r.silent, "silent message opens silent");
	r = receive(*b, quiet.packet, *a, quiet_at);
	check(r.result == .Ok && r.silent, "silent kept with the stored plaintext");
	r = ask(*a, .Receive, quiet.packet, from = *a, peer = *b);
	check(r.result == .Ok && r.silent, "own silent echo");
	r = receive(*b, early.packet, *a, early_at);
	check(!r.silent, "plain message isn't silent");

	reposted := send(*a, *b, "mine");
	r = receive(*a, reposted.packet, *b);
	check(r.result == .Repeated, "our packet reposted by the peer before our echo isn't shown as theirs");
	r = ask(*a, .Receive, reposted.packet, from = *a, peer = *b);
	check(r.result == .Ok && r.out_text == "mine", "our echo still claims it");

	most := e2e.max_text(limit);
	long := send(*a, *b, repeat("x", most + 1));
	check(long.result == .Too_Long, "text over the carrier's packet refused");
	full := send(*a, *b, repeat("x", most));
	check(full.result == .Ok && full.packet.count <= limit, "longest text fits the carrier's packet");
	r = receive(*b, full.packet, *a);
	check(r.result == .Ok && r.out_text.count == most, "longest text opens");
	short1 := send(*a, *b, "ok");
	short2 := send(*a, *b, repeat("y", e2e.PAD_BLOCK - 2));
	block2 := send(*a, *b, repeat("y", e2e.PAD_BLOCK - 1));
	check(short1.packet.count == short2.packet.count && block2.packet.count > short2.packet.count, "lengths are padded to the block");
	for string.["", "\x80\x00", "x\x00\x00", "x\x80y"] {
		_, ok := e2e.unpad(cast([]u8) it);
		check(!ok, tprint("bad padding % refused", it_index));
	}
	sent := (*e2e.Request).[short1, short2, block2];
	lengths := int.[2, e2e.PAD_BLOCK - 2, e2e.PAD_BLOCK - 1];
	for sent {
		got := receive(*b, it.packet, *a);
		check(got.result == .Ok && got.out_text.count == lengths[it_index], "padded text opens");
	}
	// Search opens the conversation's sealed texts in memory: every word, any ASCII case.
	found := ask(*b, .Search, peer = *a, text = "EARLY");
	check(found.hits.count == 1 && found.hits[0].text == "early" && found.hits[0].author == a.party && found.hits[0].delivery == early_at, "search finds a received text");
	found = ask(*a, .Search, peer = *b, text = "mine");
	check(found.hits.count == 1 && found.hits[0].author == a.party, "and our own, once its echo claimed it");
	found = ask(*b, .Search, peer = *a, text = "early nothing");
	check(found.hits.count == 0, "every word must match");
	r = receive(*b, repeat("z", limit + 1), *a);
	check(r.result == .Undecryptable, "a delivery over the carrier's largest packet is refused");

	// Each packet is dropped, duplicated as another delivery, held back, forged or delivered.
	pending: [..]Delivery;
	seen: [..]string;
	delivered, dropped, opened, replays, forgeries := 0, 0, 0, 0, 0;
	random_seed(7);
	for round: 0..399 {
		from, to := ifx random_get() & 1 then *a else *b, ifx random_get() & 1 then *b else *a;
		if from == to to = ifx from == *a then *b else *a;
		text := tprint("message % from %", round, from.party);
		s := send(from, to, text);
		if s.result != .Ok { check(false, "send"); continue; }
		at := copy_string(delivery());
		echo := ask(from, .Receive, s.packet, from = from, peer = to, at = at);
		check(echo.result == .Ok && echo.out_text == text, "own echo shows our plaintext");
		array_add(*pending, .{copy_string(s.packet), from, at, copy_string(text), false});
		roll := random_get() % 100;
		if roll < 10 { dropped += 1; pop(*pending); continue; }
		if roll < 20 {
			d := peek(pending);
			array_add(*pending, .{d.packet, d.author, copy_string(delivery()), d.plain, false}); // A replay under a new delivery ID.
		}
		if roll < 25 {
			d := peek(pending);
			forged := copy_string(d.packet);
			i := cast(int) (random_get() % cast(u64) forged.count);
			forged[i] ^= xx (1 + random_get() % 255);
			array_add(*pending, .{forged, d.author, copy_string(delivery()), "", true});
		}
		// Deliver a random held packet, so order is shuffled. The first copy of a packet to arrive opens;
		// every later copy, under another delivery ID, is a replay.
		while pending.count > 3 || (pending.count && random_get() % 3 == 0) {
			i := cast(int) (random_get() % cast(u64) pending.count);
			d := pending[i];
			array_unordered_remove_by_index(*pending, i);
			target := ifx d.author == *a then *b else *a;
			got := receive(target, d.packet, d.author, d.at);
			delivered += 1;
			if d.forged {
				check(got.result == .Undecryptable || got.result == .No_Session, tprint("forgery rejected (%)", got.result));
				forgeries += 1;
			} else if array_find(seen, d.packet) {
				check(got.result == .Repeated, "replay detected");
				replays += 1;
			} else {
				check(got.result == .Ok && got.out_text == d.plain, tprint("delivery opens (%: %)", got.result, d.plain));
				array_add(*seen, d.packet);
				opened += 1;
			}
		}
	}
	print("carrier (largest packet %): % delivered, % opened, % dropped, % replays, % forgeries\n", limit, delivered, opened, dropped, replays, forgeries);
	check(opened > 200 && replays > 10 && forgeries > 5, "the carrier exercised every case");

	contents(*a, *b);

	// Outbox: a packet committed but not handed to the carrier is offered again; once sent it's gone.
	s := send(*a, *b, "crash before send");
	in_outbox :: (o: *e2e.Request, packet: string) -> bool {
		for o.outbox if it.packet == packet && it.carrier == CARRIER && it.conversation == CONV return true;
		return false;
	}
	check(in_outbox(ask(*a, .Outbox), s.packet), "unsent packet stays in the outbox with its conversation");
	ask(*a, .Sent, s.packet);
	check(!in_outbox(ask(*a, .Outbox), s.packet), "sent packet leaves the outbox");
	// A message's files are kept with it, so a resend after a crash carries them.
	fr := e2e.request(.Send, .{CARRIER, CONV, a.party, b.party, limit}, "with files");
	fr.me = a.me;
	array_add(*fr.uploads, copy_string("first ciphertext"), copy_string("second"));
	e2e.submit(a.d, fr);
	wait(fr);
	files_back := false;
	for ask(*a, .Outbox).outbox if it.packet == fr.packet files_back = it.files.count == 2 && it.files[0] == "first ciphertext" && it.files[1] == "second";
	check(fr.result == .Ok && files_back, "the outbox gives back a message's files, in order");
	ask(*a, .Sent, fr.packet);
	check(count(a.d, "SELECT count(*) FROM outbox_files") == 0, "and drops them once it's sent");

	// Unknown key-share: the carrier copies B's Hello into A's conversation with M, shown as M's. A
	// accepts, and the carrier moves A's Init into A and B's conversation. B must not open it as A's.
	OTHER :: "conv two";
	moved_hello := ask(*b, .Hello, peer = *a);
	r = ask(*a, .Receive, moved_hello.packet, from_party = "mallory", peer_party = "mallory", id = OTHER);
	check(r.result == .Hello, "copied hello looks like M's");
	moved_init := ask(*a, .Accept, moved_hello.packet, peer_party = "mallory", id = OTHER);
	check(moved_init.result == .Ok, "A accepts the copied hello");
	r = receive(*b, moved_init.packet, *a);
	check(r.result == .Undecryptable, "an init made for another conversation doesn't open");

	// Safety numbers: both sides see the same digits, and a peer's new root is flagged.
	la := ask(*a, .Load, peer = *b);
	lb := ask(*b, .Load, peer = *a);
	eq :: (x: [$N]u8, y: [N]u8) -> bool { return memcmp(x.data, y.data, N) == 0; }
	check(la.has_peer && eq(la.peer_root, b.me.root) && !la.verified && !la.key_changed, "A knows B's root");
	check(lb.has_peer && eq(lb.peer_root, a.me.root), "B knows A's root");
	sn := e2e.safety_number(a.me.root, b.me.root);
	check(eq(sn, e2e.safety_number(b.me.root, a.me.root)), "safety number is the same from both sides");
	for sn check(it >= #char "0" && it <= #char "9", "safety number is digits");
	verify :: (c: *Client, peer: *Client, root: [32]u8, on: bool, id := CONV) {
		v := e2e.request(.Set_Verified, .{CARRIER, id, c.party, peer.party, limit});
		v.peer_root, v.verified = root, on;
		e2e.submit(c.d, v);
		wait(v);
	}
	verify(*a, *b, b.me.root, true);
	check(ask(*a, .Load, peer = *b).verified, "verified sticks");
	b2 := Client.{d = e2e.start(tprint("%/b2.db", tag)), me = e2e.identity_of(keys.generate("B2")), party = b.party};
	check(!eq(e2e.safety_number(a.me.root, b2.me.root), sn), "a new root makes a new safety number");
	NEW_CONV :: "conv three";
	h2 := ask(*b2, .Hello, peer = *a, id = NEW_CONV);
	r = receive(*a, h2.packet, *b2, id = NEW_CONV);
	check(r.result == .Hello && r.key_changed, "a Hello with B's new root is flagged");
	ask(*a, .Accept, h2.packet, peer = *b2, id = NEW_CONV);
	la = ask(*a, .Load, peer = *b, id = NEW_CONV);
	check(eq(la.peer_root, b2.me.root) && la.key_changed && !la.verified, "accepting B's new root drops verification and flags it");
	verify(*a, *b, b2.me.root, false, NEW_CONV);
	la = ask(*a, .Load, peer = *b, id = NEW_CONV);
	check(!la.key_changed && !la.verified, "dismissing clears the flag");
	stop(b2.d);

	// Prekeys: an unanswered Hello's go after a week.
	ask(*b, .Hello, peer = *a);
	sql(b.d, "UPDATE prekeys SET created = created - 8 * 86400000;");
	check(count(b.d, "SELECT count(*) FROM prekeys;") > 0, "prekeys stored");
	ask(*b, .Hello, peer = *a);
	check(count(b.d, "SELECT count(*) FROM prekeys;") == 1, "a week-old unanswered hello's prekeys are deleted");
	sql(b.d, "UPDATE prekeys SET answered = 1;");
	ask(*b, .Hello, peer = *a);
	check(count(b.d, "SELECT count(*) FROM prekeys;") == 1, "an answered hello's prekeys go after a day");

	// A bundle: B's Hello, kept by the carrier, answered in conversations it was never sent in, while B is away.
	bundle := ask(*b, .Bundle, id = "");
	check(bundle.result == .Ok && bundle.packet.count == e2e.HELLO_BYTES, "a bundle is a Hello");
	carol := Client.{d = e2e.start(tprint("%/c.db", tag)), me = e2e.identity_of(keys.generate("C")), party = "carol"};
	for who: (*Client).[*a, *carol] {
		id := tprint("bundled by %", who.party);
		init := ask(who, .Accept, bundle.packet, peer = *b, id = id);
		first := ask(who, .Send, peer = *b, id = id, text = "first, via the bundle");
		check(init.result == .Ok && first.result == .Ok, "a bundle is answered with a message at once");
		r = receive(*b, init.packet, who, id = id);
		check(r.result == .Ok && r.content == .Accept, "the bundle's owner opens the init later");
		r = receive(*b, first.packet, who, id = id);
		check(r.result == .Ok && r.out_text == "first, via the bundle", "and what followed it");
	}
	stop(carol.d);

	// Sessions survive a restart.
	stop(a.d);
	a.d = e2e.start(tprint("%/a.db", tag));
	s = send(*a, *b, "after restart");
	restart_at := copy_string(delivery());
	got := receive(*b, s.packet, *a, restart_at);
	check(got.result == .Ok && got.out_text == "after restart", "session survives a restart");

	// At rest: secrets are sealed under the database key, each bound to its row.
	again := receive(*b, s.packet, *a, restart_at);
	check(again.result == .Ok && again.out_text == "after restart", "a refetch reads the sealed plaintext");
	sql(b.d, "UPDATE plaintexts SET sealed = (SELECT sealed FROM plaintexts AS p WHERE p.hash != plaintexts.hash LIMIT 1);");
	again = receive(*b, s.packet, *a, restart_at);
	check(again.result == .Failed, "a sealed value moved to another row doesn't open");
	stop(a.d);
	stop(b.d);
	for name: string.["a.db", "b.db"]
		check(!contains(read_entire_file(tprint("%/%", tag, name)), "after restart"), tprint("no plaintext in %", name));

	// An update first copies the file as it was beside it.
	old_path := tprint("%/old.db", tag);
	old := sqlite.open(old_path);
	check(sqlite.exec(old, "CREATE TABLE meta(key TEXT PRIMARY KEY, value BLOB NOT NULL) WITHOUT ROWID; PRAGMA user_version = 1;"), "make a schema 1 file");
	sqlite.close(old);
	o := e2e.start(old_path);
	check(sql(o, "SELECT count(*) FROM meta;") == 1, "the old file updates");
	stop(o);
	copied := false;
	for file_list(tag) if contains(it, "old.db.pre-v") copied = true;
	check(copied, "the file as it was is kept beside it");

	// A key that won't unwrap (a <state> copied from another machine) sets the file aside for a new one.
	a.d = e2e.start(tprint("%/a.db", tag));
	sql(a.d, "UPDATE meta SET value = X'00' WHERE key = 'db_key';");
	stop(a.d);
	a.d = e2e.start(tprint("%/a.db", tag));
	r = ask(*a, .Load, peer = *b);
	check(!r.failed && r.result == .Ok && !r.has_session, "a sealed database is replaced by an empty one");
	aside := false;
	for file_list(tag) if contains(it, "a.db.sealed-") aside = true;
	check(aside, "the sealed database is kept beside it");
	stop(a.d);
}

// post sends a message of any kind from c to peer.
post :: (c: *Client, peer: *Client, content: e2e.Content, text := "", target := "", reply := "", files: []e2e.File = .[]) -> *e2e.Request {
	r := e2e.request(.Send, .{CARRIER, CONV, c.party, peer.party, limit}, text);
	r.me, r.content, r.target, r.reply = c.me, content, copy_string(target), copy_string(reply);
	for files {
		f := array_add(*r.files);
		f.* = it;
		f.name, f.mime, f.description = copy_string(it.name), copy_string(it.mime), copy_string(it.description);
	}
	e2e.submit(c.d, r);
	wait(r);
	return r;
}

// contents: replies, files, edits, deletes and reactions, each inside the packet (E2E 7).
contents :: (a: *Client, b: *Client) {
	// Echo and deliver: the sender's own copy claims the delivery, then the peer opens it.
	land :: (from: *Client, to: *Client, s: *e2e.Request, at := "") -> *e2e.Request {
		id := ifx at then at else copy_string(delivery());
		ask(from, .Receive, s.packet, from = from, peer = to, at = id);
		return receive(to, s.packet, from, id);
	}
	original := post(a, b, .Text, "first draft");
	orig_at := copy_string(delivery());
	r := land(a, b, original, orig_at);
	check(r.result == .Ok && r.content == .Text && r.out_text == "first draft", "a plain text stays Text");

	// A reply names the delivery it answers, inside the packet.
	s := post(b, a, .Text, "answer", reply = orig_at);
	answer_at := copy_string(delivery());
	r = land(b, a, s, answer_at);
	check(r.result == .Ok && r.content == .Post && r.reply == orig_at && r.out_text == "answer", "a reply carries its target");
	s = post(b, a, .Edit, "answer, edited", target = answer_at, reply = orig_at);
	r = land(b, a, s, answer_at);
	check(r.result == .Ok && r.content == .Edit && r.reply == orig_at && r.out_text == "answer, edited", tprint("an edit keeps the reply (%)", r.result));

	// A forward names the original's author and time inside the packet.
	fw := e2e.request(.Send, .{CARRIER, CONV, a.party, b.party, limit}, "passed on");
	fw.me, fw.forward_author, fw.forward_at = a.me, copy_string("carol"), copy_string("2026-10-30T12:00:00+00:00");
	e2e.submit(a.d, fw);
	wait(fw);
	r = land(a, b, fw);
	check(r.result == .Ok && r.content == .Post && r.forward_author == "carol" && r.forward_at == "2026-10-30T12:00:00+00:00" && r.out_text == "passed on", "a forward carries its original's author and time");

	// Files: the ciphertext goes wherever the carrier keeps files; the message holds key, digest and what it is.
	data := cast([]u8) repeat("picture bytes ", 1000);
	f := e2e.File.{width = 640, height = 480, spoiler = true, name = "cat.png", mime = "image/png", description = "a cat"};
	ct := e2e.seal_file(data, *f);
	check(ct.count == e2e.sealed_size(data.count) && ct.count % e2e.FILE_BLOCK == e2e.TAG_BYTES && !contains(xx ct, "picture"), "a file is sealed, padded to the block");
	s = post(a, b, .Text, "look", files = .[f]);
	r = land(a, b, s);
	check(r.result == .Ok && r.content == .Post && r.files.count == 1 && r.out_text == "look", "a message carries its file");
	if r.files.count {
		g := r.files[0];
		check(g.name == "cat.png" && g.mime == "image/png" && g.description == "a cat" && g.width == 640 && g.height == 480 && g.spoiler && g.size == data.count, "the file's name, type, size and dimensions arrive");
		got, ok := e2e.open_file(g, ct);
		check(ok && got.count == data.count && memcmp(got.data, data.data, data.count) == 0, "the file opens");
		bad := array_copy(ct,, temp);
		bad[7] ^= 1;
		_, ok = e2e.open_file(g, bad);
		check(!ok, "a changed ciphertext is refused");
		_, ok = e2e.open_file(g, array_view(ct, 0, ct.count - 1));
		check(!ok, "a cut ciphertext is refused");
		huge := g;
		huge.size = e2e.MAX_FILE + 1;
		_, ok = e2e.open_file(huge, ct);
		check(!ok, "a file over the cap is refused before allocating");
		other := g;
		other.key[0] ^= 1;
		_, ok = e2e.open_file(other, ct);
		check(!ok, "the wrong key is refused");
	}
	r = receive(b, s.packet, a);
	check(r.result == .Repeated, "a file message replayed as another delivery");
	s = e2e.request(.Send, .{CARRIER, CONV, a.party, b.party, limit});
	s.me = a.me;
	array_add(*s.stickers, copy_string("sticker\x00one"));
	e2e.submit(a.d, s);
	wait(s);
	r = land(a, b, s);
	check(r.result == .Ok && r.content == .Post && r.stickers.count == 1 && r.stickers[0] == "sticker\x00one" && !r.out_text, "a sticker alone, named as the carrier names it");

	// An Edit rewrites its own delivery: the carrier edits the message in place.
	edit := post(a, b, .Edit, "final", target = orig_at);
	check(edit.result == .Ok, "editing our message");
	moved := receive(b, edit.packet, a);
	check(moved.result == .Ok && moved.content == .Edit && moved.target == orig_at, "an edit moved onto another delivery changes only the message it names");
	edit = post(a, b, .Edit, "final", target = orig_at);
	r = land(a, b, edit, orig_at);
	check(r.result == .Ok && r.content == .Edit && r.target == orig_at && r.out_text == "final", "the edit opens in place");
	found := ask(b, .Search, peer = a, text = "draft");
	check(found.hits.count == 0, "the old text is gone from search");
	found = ask(b, .Search, peer = a, text = "final");
	check(found.hits.count == 1 && found.hits[0].delivery == orig_at, "and the new one is found");
	theirs := post(b, a, .Edit, "not mine", target = orig_at);
	check(theirs.result == .Failed, "editing the peer's message is refused");

	// Delete: the delivery is rewritten into a Delete, and its plaintext goes.
	del := post(a, b, .Delete, target = orig_at);
	r = land(a, b, del, orig_at);
	check(r.result == .Ok && r.content == .Delete && r.target == orig_at, "a delete opens in place");
	found = ask(b, .Search, peer = a, text = "final");
	check(found.hits.count == 0, "a deleted text isn't found");

	// Reactions are their own packets, naming the message they're on.
	react := post(b, a, .React, "+1", target = orig_at);
	r = land(b, a, react);
	check(r.result == .Ok && r.content == .React && r.target == orig_at && r.out_text == "+1", "a reaction");
	r = land(b, a, post(b, a, .Unreact, "+1", target = orig_at));
	check(r.result == .Ok && r.content == .Unreact, "and taking it back");
	check(post(b, a, .React, "", target = orig_at).result == .Failed && post(b, a, .React, "x").result == .Failed, "a reaction needs an emoji and a target");

	// An Edit too long for its target's place goes as a delivery of its own, which changes only its target.
	detach :: (c: *Client, peer: *Client, target: string, text: string) -> *e2e.Request {
		r := e2e.request(.Send, .{CARRIER, CONV, c.party, peer.party, limit}, text);
		r.me, r.content, r.target, r.in_place = c.me, e2e.Content.Edit, copy_string(target), 200;
		e2e.submit(c.d, r);
		wait(r);
		return r;
	}
	// deliver: the echo and the peer's copy, as the carrier orders them.
	deliver :: (from: *Client, to: *Client, s: *e2e.Request, order: s64) -> *e2e.Request {
		at := copy_string(delivery());
		fx_receive(from, from, to, CONV, at, s.packet, order);
		return fx_receive(to, from, from, CONV, at, s.packet, order);
	}
	t := post(a, b, .Text, "short");
	t_at := copy_string(delivery());
	land(a, b, t, t_at);
	long := repeat("long ", 100);
	de := detach(a, b, t_at, long);
	check(de.result == .Ok && de.detached && de.packet.count > 200, "a long edit is detached");
	posted := false;
	for ask(a, .Outbox).outbox if it.packet == de.packet posted = !it.replaces && it.silent;
	check(posted, "the outbox posts it as a new, silent message");
	ask(a, .Sent, de.packet);
	r = deliver(a, b, de, 10);
	check(r.result == .Ok && r.content == .Edit && r.target == t_at && r.out_text == long, "a detached edit names its target");
	for c: (*Client).[a, b] {
		r = fx_receive(c, a, ifx c == a then b else a, CONV, t_at, t.packet);
		check(r.result == .Ok && r.out_text == long, "its target, refetched, opens as edited");
	}
	found = ask(b, .Search, peer = a, text = "long");
	check(found.hits.count == 1 && found.hits[0].delivery == t_at, "search finds the edit at its target, once");
	short := detach(a, b, t_at, "short again");
	check(short.result == .Ok && short.detached, "after one detached edit, every edit of that message is");
	ask(a, .Sent, short.packet);
	newer := detach(a, b, t_at, "newest");
	ask(a, .Sent, newer.packet);
	deliver(a, b, newer, 30);
	deliver(a, b, short, 20);
	r = fx_receive(b, a, a, CONV, t_at, t.packet);
	check(r.out_text == "newest", "the carrier's latest detached edit wins, whatever order they arrive in");
	// A detached edit can arrive before its target: the target then opens as edited.
	t2 := post(a, b, .Text, "first version");
	t2_at := copy_string(delivery());
	fx_receive(a, a, b, CONV, t2_at, t2.packet);
	early_edit := detach(a, b, t2_at, "second version");
	ask(a, .Sent, early_edit.packet);
	deliver(a, b, early_edit, 40);
	r = fx_receive(b, a, a, CONV, t2_at, t2.packet);
	check(r.result == .Ok && r.out_text == "second version", "a target arriving after its detached edit opens as edited");
	// A delete takes the detached edits' text with it.
	del2 := post(a, b, .Delete, target = t_at);
	land(a, b, del2, t_at);
	found = ask(b, .Search, peer = a, text = "newest");
	check(found.hits.count == 0, "a deleted message's detached edits aren't found");
	check(count(b.d, "SELECT count(*) FROM plaintexts WHERE target IS NOT NULL;") >= 3, "they keep their rows");
	r = deliver(a, b, newer, 30);
	check(r.result == .Repeated, "a detached edit replayed as another delivery");

	// The outbox keeps an Edit's target and @silent for a resend after a crash.
	again := post(a, b, .Text, "to edit");
	again_at := copy_string(delivery());
	land(a, b, again, again_at);
	e := e2e.request(.Send, .{CARRIER, CONV, a.party, b.party, limit}, "edited quietly");
	e.me, e.content, e.target, e.silent = a.me, e2e.Content.Edit, copy_string(again_at), true;
	e2e.submit(a.d, e);
	wait(e);
	o := ask(a, .Outbox);
	kept := false;
	for o.outbox if it.packet == e.packet kept = it.replaces == again_at && it.silent;
	check(kept, "the outbox keeps what an edit replaces and @silent");
	ask(a, .Sent, e.packet);

	// Bodies come from the peer: no malformed one opens, and none crashes.
	random_seed(11);
	for 1..2000 {
		n := cast(int) (random_get() % 200);
		junk := NewArray(n, u8,, temp);
		for * junk it.* = xx (random_get() & 0xFF);
		if n junk[0] = xx (2 + random_get() % 5);
		e2e.parse_body(junk);
	}
	for x: string.["\x02", "\x02\x00\x00\x00", "\x03\x00\x00\x00hi", "\x04\x01d\x00\x00x", "\x05\x01d\x00\x00", "\x02\x00\x00\x0b", "\x07\x00\x00\x00", "\x02\x00\x00\x01",
			"\x42\x00\x00\x00\x00\x00", "\x42\x00\x00\x00\x00\x01\x00hi", "\x42\x00\x00\x00\x00\x01a\x01\x0ahi", "\x43\x01d\x00\x00\x00\x01a\x00hi", "\x40hi", "\x41"] {
		_, ok := e2e.parse_body(xx x);
		check(!ok, tprint("bad body % refused", it_index));
	}
	_, ok := e2e.parse_body(e2e.encode_body(.{content = .Post, files = .[f], text = "ok"}));
	check(ok, "a good body parses");
	fwd, fwd_ok := e2e.parse_body(xx "\xc2\x00\x00\x00\x00\x01a\x00hi");
	check(fwd_ok && fwd.forwarded && fwd.silent && fwd.forward_author == "a" && fwd.forward_at == "" && fwd.text == "hi", "a forward's body parses");
}

// group: three members over the mock carrier with sender keys (E2E 8). Each pair has a session in the group
// conversation; a member's chain goes to the others inside those, then their messages go once to all.
group :: (dir: string) {
	limit = e2e.MAX_PACKET;
	GROUP :: "group\x00conv";
	tag := tprint("%/group", dir);
	make_directory_if_it_does_not_exist(tag);
	names :: string.["ann", "ben\x00", "cy"];
	m: [3]Client;
	for * m it.* = .{d = e2e.start(tprint("%/%.db", tag, it_index)), me = e2e.identity_of(keys.generate(names[it_index])), party = names[it_index]};
	others :: (c: *Client, all: []Client, gone := "") -> []string {
		out: [..]string;
		out.allocator = temp;
		for all if it.party != c.party && it.party != gone array_add(*out, it.party);
		return out;
	}
	conv_of :: (c: *Client, peer := "") -> e2e.Conversation { return .{CARRIER, GROUP, c.party, peer, limit}; }
	gsend :: (c: *Client, members: []string, text: string) -> *e2e.Request {
		r := e2e.request(.Send, conv_of(c), text);
		r.me = c.me;
		for members array_add(*r.members, copy_string(it));
		e2e.submit(c.d, r);
		wait(r);
		return r;
	}
	grecv :: (c: *Client, packet: string, from: *Client, at: string) -> *e2e.Request {
		r := e2e.request(.Receive, conv_of(c, from.party), packet = packet);
		r.me, r.from, r.delivery = c.me, copy_string(from.party), copy_string(at);
		e2e.submit(c.d, r);
		wait(r);
		return r;
	}
	// Pairwise sessions: each member's Hello, answered by the two others.
	for * h: m {
		hello := e2e.request(.Hello, conv_of(h));
		hello.me = h.me;
		e2e.submit(h.d, hello);
		wait(hello);
		for * a: m if a != h {
			init := e2e.request(.Accept, conv_of(a, h.party), packet = hello.packet);
			init.me = a.me;
			e2e.submit(a.d, init);
			wait(init);
			check(init.result == .Ok, "a member answers another's Hello");
			check(grecv(h, init.packet, a, copy_string(delivery())).result == .Ok, "and the Init opens");
		}
	}
	all := array_view(m, 0, 3);
	first := gsend(*m[0], others(*m[0], all), "hello group");
	check(first.result == .Ok && first.packets.count == 3, tprint("the first send gives the chain to both, then the message (% packets)", first.packets.count));
	at := copy_string(delivery());
	for i: 1..2 {
		// Every member sees every packet; the gift for the other member isn't theirs to open.
		gifts := 0;
		for g: 0..1 {
			gr := grecv(*m[i], first.packets[g], *m[0], copy_string(delivery()));
			if gr.result == .Ok && gr.content == .Sender_Key gifts += 1;
			else check(gr.result == .No_Session, tprint("another's gift waits as no session (%)", gr.result));
		}
		check(gifts == 1, "each member gets one gift");
		got := grecv(*m[i], first.packet, *m[0], at);
		check(got.result == .Ok && got.out_text == "hello group", tprint("member % opens the group message (%)", i, got.result));
	}
	check(grecv(*m[1], first.packet, *m[0], copy_string(delivery())).result == .Repeated, "a replay as another delivery");
	forged := copy_string(first.packet);
	forged[30] ^= 1;
	check(grecv(*m[2], forged, *m[0], copy_string(delivery())).result == .Undecryptable, "a forged group message");
	unsigned := copy_string(first.packet);
	unsigned[unsigned.count - 1] ^= 1;
	check(grecv(*m[1], unsigned, *m[0], copy_string(delivery())).result == .Undecryptable, "a bad signature");

	// The chain is ours: later sends are one packet, and arrive in any order.
	a2 := gsend(*m[0], others(*m[0], all), "second");
	a3 := gsend(*m[0], others(*m[0], all), "third");
	check(a2.packets.count == 1 && a3.packets.count == 1, "later sends reuse the chain");
	check(grecv(*m[1], a3.packet, *m[0], copy_string(delivery())).out_text == "third", "out of order");
	check(grecv(*m[1], a2.packet, *m[0], copy_string(delivery())).out_text == "second", "a skipped key opens the earlier one");

	// A message before its chain arrives waits for it.
	b1 := gsend(*m[1], others(*m[1], all), "from ben");
	check(b1.packets.count == 3, "ben's first send gives his chain");
	b_at := copy_string(delivery());
	check(grecv(*m[2], b1.packet, *m[1], b_at).result == .No_Session, "ben's message before his chain");
	for b1.packets grecv(*m[2], it, *m[1], copy_string(delivery()));
	check(grecv(*m[2], b1.packet, *m[1], b_at).out_text == "from ben", "then it opens");
	// A member's chain can't be used to speak as another member.
	stolen := grecv(*m[2], a2.packet, *m[1], copy_string(delivery()));
	check(stolen.result != .Ok, "ann's message shown as ben's doesn't open");

	// Cy leaves: ann's next send is under a new chain, given only to ben.
	left := gsend(*m[0], others(*m[0], all, gone = "cy"), "without cy");
	check(left.result == .Ok && left.packets.count == 2, "a member leaving rotates the chain");
	for left.packets grecv(*m[2], it, *m[0], copy_string(delivery()));
	check(grecv(*m[2], left.packet, *m[0], copy_string(delivery())).result == .No_Session, "the one who left can't read on");
	for left.packets grecv(*m[1], it, *m[0], copy_string(delivery()));
	check(grecv(*m[1], left.packet, *m[0], copy_string(delivery())).out_text == "without cy", "the one who stayed can");
	for * m stop(it.d);
}

// bottles: a Bottle posted where anyone sees it opens only for those its sender gave the key to, over their
// pairwise sessions, and only as from that sender.
bottles :: (dir: string) {
	limit = e2e.MAX_PACKET; // A signed Hello goes as an attachment; a Bottle fits a message.
	tag := tprint("%/bottles", dir);
	make_directory_if_it_does_not_exist(tag);
	a := Client.{d = e2e.start(tprint("%/a.db", tag)), me = e2e.identity_of(keys.generate("A")), party = "ann"};
	b := Client.{d = e2e.start(tprint("%/b.db", tag)), me = e2e.identity_of(keys.generate("B")), party = "ben\x00"};
	c := Client.{d = e2e.start(tprint("%/c.db", tag)), me = e2e.identity_of(keys.generate("C")), party = "cy"};
	AB :: "dm\x00ab";
	AC :: "dm ac";
	PLACE :: "channel";
	for peer: (*Client).[*b, *c] {
		id := ifx peer == *b then AB else AC;
		hello := ask(peer, .Hello, peer = *a, id = id);
		init := ask(*a, .Accept, hello.packet, peer = peer, id = id);
		check(receive(peer, init.packet, *a, id = id).result == .Ok, "a session for the bottle's keys");
	}
	limit = fc_text.MAX_PACKET;
	bottle := ask(*a, .Bottle, id = PLACE, text = "for ben");
	check(bottle.result == .Ok && bottle.packet.count <= limit && bottle.out_text.count == 32, "a bottle is sealed");
	unbottle :: (c: *Client, packet: string, from: *Client) -> *e2e.Request { return ask(c, .Unbottle, packet, from = from, id = PLACE); }
	r := unbottle(*a, bottle.packet, *a);
	check(r.result == .Ok && r.out_text == "for ben", "its sender opens it");
	check(unbottle(*b, bottle.packet, *a).result == .No_Session, "a reader can't before the key comes");

	give :: (from: *Client, to: *Client, id: string, digest: string) -> *e2e.Request {
		g := e2e.request(.Send, .{CARRIER, id, from.party, to.party, limit}, digest);
		g.me, g.content, g.silent = from.me, e2e.Content.Bottle_Key, true;
		e2e.submit(from.d, g);
		wait(g);
		return g;
	}
	gift := give(*a, *b, AB, bottle.out_text);
	check(gift.result == .Ok, "the key goes over the reader's session");
	r = receive(*b, gift.packet, *a, id = AB);
	check(r.result == .Ok && r.content == .Bottle_Key, "the reader takes the key");
	r = unbottle(*b, bottle.packet, *a);
	check(r.result == .Ok && r.out_text == "for ben", "then opens the bottle");
	check(unbottle(*b, bottle.packet, *c).result == .No_Session, "the same bottle posted by another doesn't open as theirs");
	check(unbottle(*c, bottle.packet, *a).result == .No_Session, "one not given the key can't open it");
	check(give(*c, *b, AB, bottle.out_text).result == .Failed, "only the bottle's sender gives its key");
	check(give(*a, *c, AC, "not a digest of any bottle......").result == .Failed, "a key never made isn't given");
	forged := copy_string(bottle.packet);
	forged[10] ^= 1;
	check(unbottle(*b, forged, *a).result == .No_Session, "a changed bottle has no key");
	check(unbottle(*b, "\x04\x05", *a).result == .Undecryptable, "a bottle too short to hold anything");

	most := e2e.max_bottle_text(limit);
	check(ask(*a, .Bottle, id = PLACE, text = repeat("x", most + 1)).result == .Too_Long, "a bottle over the carrier's packet refused");
	full := ask(*a, .Bottle, id = PLACE, text = repeat("x", most));
	check(full.result == .Ok && full.packet.count <= limit, "the longest bottle fits");
	check(unbottle(*a, full.packet, *a).out_text.count == most, "and opens whole");
	for d: (*e2e.Db).[a.d, b.d, c.d] stop(d);
}

// tiny: a carrier whose largest packet is smaller than a Hello refuses cleanly instead of sending a cut one.
tiny :: (dir: string) {
	limit = e2e.HELLO_BYTES - 1;
	a := Client.{d = e2e.start(tprint("%/tiny.db", dir)), me = e2e.identity_of(keys.generate("A")), party = "a"};
	r := ask(*a, .Hello, peer_party = "b");
	check(r.result == .Too_Long && !r.packet.count, "a Hello that doesn't fit is refused");
	r = ask(*a, .Load, peer_party = "b");
	check(!r.encrypted, "a refused Hello leaves encryption off");
	r = ask(*a, .Hello, peer_party = "b", id = "");
	check(r.result == .Failed, "a conversation with no ID is refused");
	stop(a.d);
}

// Release fixtures (tests/data/e2e/<release>/): what a release left on disk, three members' databases and
// key files and a sealed file, and the packets each had yet to receive. Every later build must open them
// all: stored plaintexts read, sessions go on, and every shipped packet version decrypts. Write one with
// `build/e2e make-fixture <release>` from that release's sources, once per release that changed a format.
FIXTURES :: "tests/data/e2e";
FIXTURE_PARTIES :: string.["alice\x00", "bob", "carol"];
FIXTURE_FILE :: "picture bytes ";
CONV2 :: "fixture two";
CONV3 :: "fixture three";
GROUP_CONV :: "fixture\x00group";

// A Line is a packet to receive (kind R), with what it must open as, or a packet the owner's outbox must
// still offer (kind O). Parties are indexes into FIXTURE_PARTIES.
Line :: struct {
	kind: u8;
	to, from, peer: int;
	conv, at, packet: string;
	result: e2e.Result;
	content: e2e.Content;
	silent: bool;
	text, target, reply, file: string;
}

fx_lines: [..]Line;
fx_stored: [..]Line; // Received while making the fixture; what a refetch gives is recorded once everything has happened.

party_index :: (c: *Client) -> int {
	for FIXTURE_PARTIES if it == c.party return it_index;
	assert(false);
	return -1;
}

fx_send :: (c: *Client, id: string, peer: *Client, text := "", content := e2e.Content.Text, target := "", reply := "", files: []e2e.File = .[], members: []*Client = .[], silent := false, handed := true) -> *e2e.Request {
	r := e2e.request(.Send, .{CARRIER, id, c.party, ifx peer then peer.party else "", limit}, text);
	r.me, r.content, r.target, r.reply, r.silent = c.me, content, copy_string(target), copy_string(reply), silent;
	for files {
		f := array_add(*r.files);
		f.* = it;
		f.name, f.mime, f.description = copy_string(it.name), copy_string(it.mime), copy_string(it.description);
	}
	for members array_add(*r.members, copy_string(it.party));
	e2e.submit(c.d, r);
	wait(r);
	check(r.result == .Ok, tprint("send of \"%\" (%)", text, r.result));
	if handed {
		if r.packets.count for r.packets ask(c, .Sent, it);
		else ask(c, .Sent, r.packet);
	}
	return r;
}

fx_receive :: (to: *Client, from: *Client, peer: *Client, id: string, at: string, packet: string, order: s64 = 0) -> *e2e.Request {
	r := e2e.request(.Receive, .{CARRIER, id, to.party, peer.party, limit}, packet = packet);
	r.me, r.from, r.delivery, r.order = to.me, copy_string(from.party), copy_string(at), order;
	e2e.submit(to.d, r);
	wait(r);
	return r;
}

fx_line :: (to: *Client, from: *Client, peer: *Client, id: string, packet: string, at: string) -> Line {
	return .{kind = #char "R", to = party_index(to), from = party_index(from), peer = party_index(peer), conv = id, at = ifx at then at else copy_string(delivery()), packet = packet};
}

// keep receives a packet now, to be refetched once the fixture is made.
keep :: (to: *Client, from: *Client, peer: *Client, id: string, packet: string, at := "") -> string, *e2e.Request {
	l := fx_line(to, from, peer, id, packet, at);
	r := fx_receive(to, from, peer, id, l.at, packet);
	array_add(*fx_stored, l);
	return l.at, r;
}

// land: the sender's echo claims the delivery, then the peer opens it.
land :: (from: *Client, to: *Client, id: string, packet: string, at := "") -> string {
	got := keep(from, from, to, id, packet, at);
	keep(to, from, from, id, packet, got);
	return got;
}

// later leaves a packet for a later build to receive, saying what it must open as.
later :: (to: *Client, from: *Client, peer: *Client, id: string, packet: string, result: e2e.Result, content := e2e.Content.Text, text := "", at := "") {
	l := fx_line(to, from, peer, id, packet, at);
	l.result, l.content, l.text = result, content, text;
	array_add(*fx_lines, l);
}

make_fixture :: (release: string) {
	out := tprint("%/%", FIXTURES, release);
	if file_exists(out) { print("% exists, and a release's fixture is never rewritten\n", out); exit(1); }
	tmp := tprint("build/e2e_test/make/%", release);
	delete_directory(tmp);
	make_directory_if_it_does_not_exist(tmp, recursive = true);
	limit = e2e.MAX_PACKET;
	ks: [3]keys.Keypair;
	m: [3]Client;
	for * m {
		ks[it_index] = keys.generate(FIXTURE_PARTIES[it_index]);
		it.* = .{d = e2e.start(tprint("%/%.db", tmp, it_index)), me = e2e.identity_of(ks[it_index]), party = FIXTURE_PARTIES[it_index]};
	}
	a, b, c := *m[0], *m[1], *m[2];

	// Alice and Bob: a session, then a little of everything, each delivered and echoed.
	hello := ask(b, .Hello, peer = a);
	ask(b, .Sent, hello.packet);
	land(b, a, CONV, hello.packet);
	init := ask(a, .Accept, hello.packet, peer = b);
	ask(a, .Sent, init.packet);
	land(a, b, CONV, init.packet);
	first := land(a, b, CONV, fx_send(a, CONV, b, tprint("the first message, from %", release)).packet);
	land(b, a, CONV, fx_send(b, CONV, a, "an answer", reply = first).packet);
	f := e2e.File.{width = 640, height = 480, spoiler = true, name = "cat.png", mime = "image/png", description = "a cat"};
	ct := e2e.seal_file(cast([]u8) repeat(FIXTURE_FILE, 1000), *f);
	land(a, b, CONV, fx_send(a, CONV, b, "look", files = .[f]).packet);
	edited := land(a, b, CONV, fx_send(a, CONV, b, "to be edited").packet);
	land(a, b, CONV, fx_send(a, CONV, b, "edited", content = .Edit, target = edited).packet, edited);
	deleted := land(a, b, CONV, fx_send(a, CONV, b, "to be deleted").packet);
	land(a, b, CONV, fx_send(a, CONV, b, content = .Delete, target = deleted).packet, deleted);
	land(b, a, CONV, fx_send(b, CONV, a, "+1", content = .React, target = first).packet);
	land(b, a, CONV, fx_send(b, CONV, a, "quietly", silent = true).packet);

	// Out of order: Bob opens the third first, keeping the skipped keys of the two before it.
	one := fx_send(a, CONV, b, "one");
	two := fx_send(a, CONV, b, "two");
	keep(b, a, a, CONV, fx_send(a, CONV, b, "three").packet);
	later(b, a, a, CONV, two.packet, .Ok, text = "two");
	later(b, a, a, CONV, one.packet, .Ok, text = "one");
	// Alice's echo of what Bob already opened.
	echo := fx_send(a, CONV, b, "echoed later");
	echo_at := keep(b, a, a, CONV, echo.packet);
	later(a, a, b, CONV, echo.packet, .Ok, text = "echoed later", at = echo_at);
	// Committed but never handed to the carrier, as after a crash.
	unsent := fx_send(a, CONV, b, "never handed over", handed = false);
	array_add(*fx_lines, .{kind = #char "O", to = 0, packet = unsent.packet});
	later(b, a, a, CONV, unsent.packet, .Ok, text = "never handed over");

	// Alice answers Carol's Hello; Carol hasn't seen the Init, so her prekeys wait in her database.
	h2 := ask(c, .Hello, peer = a, id = CONV2);
	ask(c, .Sent, h2.packet);
	land(c, a, CONV2, h2.packet);
	init2 := ask(a, .Accept, h2.packet, peer = c, id = CONV2);
	ask(a, .Sent, init2.packet);
	at2 := keep(a, a, c, CONV2, init2.packet);
	later(c, a, a, CONV2, init2.packet, .Ok, .Accept, at = at2);
	later(c, a, a, CONV2, fx_send(a, CONV2, c, "through a session Carol hasn't opened").packet, .Ok, text = "through a session Carol hasn't opened");
	// A Hello Carol hasn't seen, so Bob's prekeys wait too.
	h3 := ask(b, .Hello, peer = c, id = CONV3);
	ask(b, .Sent, h3.packet);
	at3 := keep(b, b, c, CONV3, h3.packet);
	later(c, b, b, CONV3, h3.packet, .Hello, at = at3);

	// A group: pairwise sessions, then Alice's chain and messages. Bob has opened the first; Carol nothing.
	for * h: m {
		gh := ask(h, .Hello, id = GROUP_CONV);
		ask(h, .Sent, gh.packet);
		for * x: m if x != h {
			gi := ask(x, .Accept, gh.packet, peer = h, id = GROUP_CONV);
			ask(x, .Sent, gi.packet);
			keep(h, x, x, GROUP_CONV, gi.packet);
		}
	}
	g1 := fx_send(a, GROUP_CONV, null, "hello group", members = .[b, c]);
	check(g1.packets.count == 3, "the first group send gives the chain to both");
	for g1.packets {
		at, r := keep(b, a, a, GROUP_CONV, it);
		// Carol's gift is the one Bob can't open.
		if it_index == g1.packets.count - 1 later(c, a, a, GROUP_CONV, it, .Ok, text = "hello group", at = at);
		else if r.result == .Ok later(c, a, a, GROUP_CONV, it, .No_Session, at = at);
		else later(c, a, a, GROUP_CONV, it, .Ok, .Sender_Key, at = at);
	}
	g2 := fx_send(a, GROUP_CONV, null, "a second, under the same chain", members = .[b, c]);
	later(b, a, a, GROUP_CONV, g2.packet, .Ok, text = "a second, under the same chain");
	later(c, a, a, GROUP_CONV, g2.packet, .Ok, text = "a second, under the same chain");

	// What each refetch gives now is what every later build must give.
	for fx_stored {
		r := fx_receive(*m[it.to], *m[it.from], *m[it.peer], it.conv, it.at, it.packet);
		l := it;
		l.result, l.content, l.silent, l.text, l.target, l.reply = r.result, r.content, r.silent, r.out_text, r.target, r.reply;
		if r.files.count l.file = r.files[0].name;
		array_add(*fx_lines, l);
	}
	for * m stop(it.d);
	if failed { print("make-fixture: % failed, nothing written\n", failed); exit(1); }

	// The database key is left unwrapped, so the fixture opens on every machine and OS.
	make_directory_if_it_does_not_exist(out, recursive = true);
	for 0..2 {
		path := tprint("%/%.db", tmp, it);
		db := sqlite.open(path);
		st := sqlite.prepare(db, "SELECT value FROM meta WHERE key = 'db_key';");
		sqlite.step(st);
		plain, ok := keys.unwrap_secret(array_copy(sqlite.col_blob(st, 0)));
		sqlite.finalize(st);
		check(ok && plain.count == 32 && sqlite.run(db, "UPDATE meta SET value = ? WHERE key = 'db_key';", plain), "unwrap the database key");
		sqlite.exec(db, "PRAGMA wal_checkpoint(TRUNCATE);");
		sqlite.close(db);
		copy_file(path, tprint("%/%.db", out, it));
		write_entire_file(tprint("%/%.key", out, it), cast(string) keys.encode(ks[it]));
	}
	write_entire_file(tprint("%/file.bin", out), cast(string) ct);
	sb: String_Builder;
	for fx_lines {
		print_to_builder(*sb, "% % % % % % % % % % % % % %\n", ifx it.kind == #char "O" then "O" else "R", it.to, it.from, it.peer, hex(it.conv), hex(it.at), hex(it.packet),
			cast(int) it.result, cast(int) it.content, cast(int) it.silent, hex(it.text), hex(it.target), hex(it.reply), hex(it.file));
	}
	write_entire_file(tprint("%/packets.txt", out), builder_to_string(*sb));
	if failed exit(1);
	print("make-fixture: wrote %, % lines\n", out, fx_lines.count);
}

// fixtures opens every release's fixture, as an update would, in a copy under dir.
fixtures :: (dir: string) {
	releases: [..]string;
	visit_files(FIXTURES, false, *releases, (info: *File_Visit_Info, out: *[..]string) { array_add(out, copy_string(info.short_name)); }, visit_files = false, visit_directories = true);
	check(releases.count > 0, "release fixtures exist");
	limit = e2e.MAX_PACKET;
	next_delivery = 1_000_000_000; // Past every delivery a fixture holds.
	for release: releases {
		src := tprint("%/%", FIXTURES, release);
		tag := tprint("%/fixtures/%", dir, release);
		make_directory_if_it_does_not_exist(tag, recursive = true);
		m: [3]Client;
		for * m {
			path := tprint("%/%.db", tag, it_index);
			check(copy_file(tprint("%/%.db", src, it_index), path), tprint("% copies", release));
			// The fixture's clock stopped when it was made; its prekeys would otherwise expire under it.
			now := to_milliseconds(current_time_consensus());
			db := sqlite.open(path);
			sqlite.run(db, "UPDATE prekeys SET created = ?, answered = CASE answered WHEN 0 THEN 0 ELSE ? END;", now, now);
			sqlite.close(db);
			kf := read_entire_file(tprint("%/%.key", src, it_index));
			k, ok := keys.decode(xx kf);
			check(ok, tprint("% key file % opens", release, it_index));
			it.* = .{d = e2e.start(path), me = e2e.identity_of(k), party = FIXTURE_PARTIES[it_index]};
		}
		a, b, c := *m[0], *m[1], *m[2];
		ct := cast([]u8) read_entire_file(tprint("%/file.bin", src));
		data := repeat(FIXTURE_FILE, 1000);
		n := 0;
		hello3: string;
		for raw: split(read_entire_file(tprint("%/packets.txt", src)), "\n") {
			fl := split(trim_right(raw, "\r"), " ");
			if fl.count != 14 continue;
			n += 1;
			to := *m[parse_int(*fl[1])];
			from := *m[parse_int(*fl[2])];
			conv, packet := unhex(fl[4]), unhex(fl[6]);
			if fl[0] == "O" {
				found := false;
				for ask(to, .Outbox).outbox if it.packet == packet found = true;
				check(found, tprint("% line %: the outbox still offers an unsent packet", release, n));
				continue;
			}
			if to == c && from == b && conv == CONV3 hello3 = packet;
			r := fx_receive(to, from, *m[parse_int(*fl[3])], conv, unhex(fl[5]), packet);
			result, content, silent := cast(e2e.Result) parse_int(*fl[7]), cast(e2e.Content) parse_int(*fl[8]), parse_int(*fl[9]) != 0;
			ok := r.result == result;
			if result == .Ok ok &&= r.content == content && r.silent == silent && (content == .Sender_Key || r.out_text == unhex(fl[10])) && r.target == unhex(fl[11]) && r.reply == unhex(fl[12]);
			if fl[13] != "-" {
				ok &&= r.files.count == 1 && r.files[0].name == unhex(fl[13]);
				if ok { got, fok := e2e.open_file(r.files[0], ct); ok &&= fok && cast(string) got == data; }
			}
			check(ok, tprint("% line %: got % % \"%\", want % % \"%\"", release, n, r.result, r.content, r.out_text, result, content, unhex(fl[10])));
		}
		check(n > 20 && hello3.count > 0, tprint("% has its packets", release));

		// Every session goes on: pairs both ways, Bob's old Hello answered, the group under a new chain and an old one.
		after :: (from: *Client, to: *Client, id: string, what: string, release: string) {
			s := fx_send(from, id, to, what);
			r := fx_receive(to, from, from, id, copy_string(delivery()), s.packet);
			check(r.result == .Ok && r.out_text == what, tprint("% goes on: % (%)", release, what, r.result));
		}
		after(a, b, CONV, "after the update", release);
		after(b, a, CONV, "and back", release);
		after(c, a, CONV2, "carol answers", release);
		i3 := ask(c, .Accept, hello3, peer = b, id = CONV3);
		ask(c, .Sent, i3.packet);
		r := fx_receive(b, c, c, CONV3, copy_string(delivery()), i3.packet);
		check(i3.result == .Ok && r.result == .Ok && r.content == .Accept, tprint("% opens an Init to a Hello it sent", release));
		after(b, c, CONV3, "a new session on old prekeys", release);
		g := fx_send(b, GROUP_CONV, null, "bob's chain, after", members = .[a, c]);
		for x: (*Client).[a, c] {
			for g.packets fx_receive(x, b, b, GROUP_CONV, copy_string(delivery()), it);
			check(fx_receive(x, b, b, GROUP_CONV, copy_string(delivery()), g.packet).out_text == "bob's chain, after", tprint("% group: a new chain", release));
		}
		g = fx_send(a, GROUP_CONV, null, "alice's old chain", members = .[b, c]);
		check(g.packets.count == 1, tprint("% group: Alice's chain is kept", release));
		for x: (*Client).[b, c]
			check(fx_receive(x, a, a, GROUP_CONV, copy_string(delivery()), g.packet).out_text == "alice's old chain", tprint("% group: the old chain goes on", release));
		hits := ask(b, .Search, peer = a, text = "first message");
		check(hits.hits.count == 1 && hits.hits[0].author == a.party, tprint("% search reads stored texts", release));
		load := ask(a, .Load, peer = b);
		check(load.has_session && memcmp(load.peer_root.data, b.me.root.data, 32) == 0, tprint("% knows Bob's root", release));
		for * m stop(it.d);
	}
}

hex :: (s: string) -> string {
	if !s return "-";
	DIGITS :: "0123456789abcdef";
	out := alloc_string(s.count * 2,, temp);
	for 0..s.count-1 { out[it * 2] = DIGITS[s[it] >> 4]; out[it * 2 + 1] = DIGITS[s[it] & 15]; }
	return out;
}

unhex :: (s: string) -> string {
	if s == "-" return "";
	nib :: (c: u8) -> u8 { return xx ifx c >= #char "a" then c - #char "a" + 10 else c - #char "0"; }
	out := alloc_string(s.count / 2);
	for 0..out.count-1 out[it] = (nib(s[it * 2]) << 4) | nib(s[it * 2 + 1]);
	return out;
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
