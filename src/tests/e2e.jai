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
	dir := "build/e2e_test";
	delete_directory(dir);
	database(dir);
	codec();
	conversation(dir, fc_text.MAX_PACKET); // Discord's, one message of text
	conversation(dir, 4096);              // a carrier with larger packets
	tiny(dir);
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

	// An Edit rewrites its own delivery: the carrier edits the message in place.
	edit := post(a, b, .Edit, "final", target = orig_at);
	check(edit.result == .Ok, "editing our message");
	moved := receive(b, edit.packet, a);
	check(moved.result == .Undecryptable, "an edit moved onto another delivery doesn't open");
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
	for x: string.["\x02", "\x02\x00\x00\x00", "\x03\x00\x00\x00hi", "\x04\x01d\x00\x00x", "\x05\x01d\x00\x00", "\x02\x00\x00\x0b", "\x07\x00\x00\x00", "\x02\x00\x00\x01"] {
		_, ok := e2e.parse_body(xx x);
		check(!ok, tprint("bad body % refused", it_index));
	}
	_, ok := e2e.parse_body(e2e.encode_body(.{content = .Post, files = .[f], text = "ok"}));
	check(ok, "a good body parses");
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
