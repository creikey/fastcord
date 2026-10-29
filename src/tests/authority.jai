// Authority log check (Federation 1): jai build.jai - run src/tests/authority.jai, then build/authority.exe.
#import "Basic";
#import "Random";
authority :: #import "authority";
crypto :: #import "crypto";
keys :: #import "keys";
#if OS == .WINDOWS {
	msvcprt :: #library,system,no_dll,link_always "msvcprt";
	ws2_32 :: #library,system,link_always "ws2_32";
}

failed := 0;
check :: (ok: bool, what: string) {
	if !ok { print("FAIL: %\n", what); failed += 1; }
}

DAY :: 24 * 3600 * 1000;

main :: () {
	now := to_milliseconds(current_time_consensus() - APOLLO_TIME_FOR_JAN_1_1970);
	later := now + 30 * DAY;
	k := keys.generate("Server");
	log, ok := authority.create(k, later);
	check(ok && log.view.checkpoint.sequence == 1 && log.view.checkpoint.signer == .Recovery, "genesis, signed by the recovery key");

	authority.add(*log, authority.address_entry(4, "203.0.113.7:4433"));
	authority.add(*log, authority.address_entry(6, "[2001:db8::7]:4433"));
	cert: [32]u8;
	cert[0] = 0xCE;
	authority.add(*log, authority.certificate_entry(cert));
	check(authority.sign(*log, k.signing, .Signing, later), "a batch signed by the everyday key");
	authority.add(*log, authority.rotate_entry(.Exchange, k.recovery_pub));
	check(!authority.sign(*log, k.signing, .Signing, later) && log.entries.count == 4, "the everyday key can't sign a rotation, which is dropped");
	authority.add(*log, authority.address_entry(5, "x"));
	check(!authority.sign(*log, k.signing, .Signing, later), "a malformed entry isn't signed");
	authority.add(*log, authority.address_entry(4, "203.0.113.8:4433"));
	check(authority.sign(*log, k.signing, .Signing, later) && log.view.checkpoint.sequence == 3, "a third checkpoint");

	// A follower takes the whole history, and its state is the log's.
	f := authority.follow(k.root);
	r := authority.accept(*f, authority.update(*log, 0), now);
	check(r == .Ok && f.current.checkpoint.sequence == 3 && authority.address(*f.current.state, 4) == "203.0.113.8:4433" && authority.address(*f.current.state, 6) == "[2001:db8::7]:4433", tprint("a follower takes the history (%)", r));
	check(authority.accept(*f, authority.update(*log, 0), now) == .Ok && f.current.checkpoint.sequence == 3, "the same history again changes nothing");
	other := authority.follow(keys.generate("Other").root);
	check(authority.accept(*other, authority.update(*log, 0), now) == .Not_Extending, "a history under another root is refused");

	// State proofs: a value, a wrong one, and an absence.
	root := f.current.checkpoint.state;
	p := authority.state_proof(*f.current.state, "address/4");
	check(authority.verify_state(root, "address/4", xx "203.0.113.8:4433", p), "an address proves");
	check(!authority.verify_state(root, "address/4", xx "203.0.113.7:4433", p), "an old address doesn't");
	check(!authority.verify_state(root, "address/6", xx "203.0.113.8:4433", p), "nor under another name");
	p = authority.state_proof(*f.current.state, "key/signing");
	check(authority.verify_state(root, "key/signing", k.signing_pub, p), "the signing key proves");
	p = authority.state_proof(*f.current.state, "delegation/x");
	check(authority.verify_state(root, "delegation/x", .[], p) && !authority.verify_state(root, "delegation/x", xx "y", p), "an absent name proves absent");

	// A rollback: an older checkpoint offered as the latest.
	old := authority.follow(k.root);
	check(authority.accept(*old, authority.update(*log, 0), now) == .Ok, "second follower");
	two := copy_update(log, 1, 1);
	check(authority.accept(*old, two, now) == .Not_Extending && old.current.checkpoint.sequence == 3, "a rollback is refused");

	// A fork: the same key signs two histories at sequence 4. Whoever saw one refuses the other.
	fork_a, ok_a := authority.load(k.root, authority.update(*log, 0));
	fork_b, ok_b := authority.load(k.root, authority.update(*log, 0));
	check(ok_a && ok_b, "a log loads from its own update");
	authority.add(*fork_a, authority.address_entry(4, "198.51.100.1:4433"));
	authority.add(*fork_b, authority.address_entry(4, "198.51.100.2:4433"));
	check(authority.sign(*fork_a, k.signing, .Signing, later) && authority.sign(*fork_b, k.signing, .Signing, later), "two forks signed");
	check(authority.accept(*f, authority.update(*fork_a, 3), now) == .Ok, "one fork accepted");
	check(authority.accept(*f, authority.update(*fork_b, 3), now) == .Not_Extending && authority.address(*f.current.state, 4) == "198.51.100.1:4433", "the other refused");

	// A stolen everyday key: the thief's checkpoint is accepted (nothing can tell yet), then the recovery key
	// rotates the signing key on a history from before it, which replaces the thief's for everyone.
	thief, _ := authority.load(k.root, authority.update(*log, 0));
	authority.add(*thief, authority.address_entry(4, "192.0.2.66:4433"));
	check(authority.sign(*thief, k.signing, .Signing, later), "the thief signs");
	victim := authority.follow(k.root);
	check(authority.accept(*victim, authority.update(*thief, 0), now) == .Ok && authority.address(*victim.current.state, 4) == "192.0.2.66:4433", "the thief's history is taken");
	new_signing, new_signing_pub := crypto.slhdsa_generate();
	authority.add(*log, authority.rotate_entry(.Signing, new_signing_pub));
	check(authority.sign(*log, k.recovery, .Recovery, later), "the recovery key rotates the signing key");
	r = authority.accept(*victim, authority.update(*log, 1), now);
	check(r == .Overridden && authority.address(*victim.current.state, 4) == "203.0.113.8:4433" && same(victim.current.state.key[0], new_signing_pub), tprint("the recovery key's history replaces the thief's (%)", r));
	authority.add(*thief, authority.address_entry(4, "192.0.2.67:4433"));
	authority.sign(*thief, k.signing, .Signing, later);
	check(authority.accept(*victim, authority.update(*thief, 4), now) == .Not_Extending, "the thief's next checkpoint is refused");
	stolen, _ := authority.load(k.root, authority.update(*log, 0));
	authority.add(*stolen, authority.address_entry(4, "192.0.2.68:4433"));
	check(!authority.sign(*stolen, k.signing, .Signing, later), "the old signing key no longer signs");
	forged := forge(log, k.signing, authority.address_entry(4, "192.0.2.69:4433"), later);
	check(authority.accept(*victim, forged, now) == .Bad_Signature, "a checkpoint under the old signing key is refused");
	authority.add(*log, authority.address_entry(4, "203.0.113.9:4433"));
	check(authority.sign(*log, new_signing, .Signing, later) && authority.accept(*victim, authority.update(*log, 4), now) == .Ok, "the new signing key carries on");

	// The recovery key rotates itself; the old one can't sign again.
	new_recovery, new_recovery_pub := crypto.slhdsa_generate();
	authority.add(*log, authority.rotate_entry(.Recovery, new_recovery_pub));
	check(authority.sign(*log, k.recovery, .Recovery, later) && authority.accept(*victim, authority.update(*log, 5), now) == .Ok, "the recovery key rotates itself");
	authority.add(*log, authority.rotate_entry(.Signing, k.signing_pub));
	check(!authority.sign(*log, k.recovery, .Recovery, later), "the old recovery key signs nothing");
	authority.add(*log, authority.rotate_entry(.Policy, k.policy));
	check(!authority.sign(*log, new_recovery, .Recovery, later), "the policy leaf doesn't rotate");

	// Expiry, and tampering.
	expired := authority.follow(k.root);
	check(authority.accept(*expired, authority.update(*log, 0), later + 1) == .Expired && expired.current.checkpoint.sequence == log.view.checkpoint.sequence, "an expired history is taken, and said to be stale");
	u := authority.update(*log, 0);
	for i: 0..20 {
		t := array_copy(u,, temp);
		t[random_get() % cast(u64) t.count] ^= cast(u8) (1 + random_get() % 255);
		g := authority.follow(k.root);
		check(authority.accept(*g, t, now) != .Ok, tprint("a flipped byte is refused (%)", i));
	}
	for n: 0..u.count - 1 {
		if n % 97 != 0 continue;
		g := authority.follow(k.root);
		check(authority.accept(*g, array_view(u, 0, n), now) == .Malformed, tprint("a truncated update is refused (%)", n));
	}
	random_seed(5);
	for 1..2000 {
		junk := NewArray(cast(int) (random_get() % 300), u8,, temp);
		for * junk it.* = xx (random_get() & 0xFF);
		if junk.count >= 2 { junk[0] = 1; junk[1] = 0; }
		g := authority.follow(k.root);
		authority.accept(*g, junk, now);
		reset_temporary_storage();
	}

	if failed { print("authority: % failed\n", failed); exit(1); }
	print("authority: ok\n");
}

same :: (a: [32]u8, b: [32]u8) -> bool { return memcmp(a.data, b.data, 32) == 0; }

// copy_update is update(log, after) cut to `count` checkpoints.
copy_update :: (log: authority.Log, after: u64, count: int) -> []u8 {
	short := log;
	short.signed.count = cast(int) after + count;
	return authority.update(*short, after);
}

// forge signs entry after log's latest checkpoint with priv, whether or not priv may sign there.
forge :: (log: authority.Log, priv: [crypto.SLHDSA_PRIVATE_BYTES]u8, entry: []u8, expiry: s64) -> []u8 {
	v := log.view;
	c := authority.Checkpoint.{root = v.checkpoint.root, sequence = v.checkpoint.sequence + 1, previous = v.hash, expiry = expiry, signer = .Signing};
	// The roots an Address entry for IPv4 gives, worked out here as a follower would.
	state := v.state;
	memcpy(state.address[0].data, entry.data + 3, entry[2]);
	state.address_count[0] = entry[2];
	peaks := v.peaks;
	size := v.checkpoint.size;
	cur := crypto.blake3_derive(authority.LEAF_CONTEXT, entry);
	n := 0;
	for 0..63 if size & (cast(u64) 1 << it) n += 1;
	sz := size;
	while sz & 1 { n -= 1; cur = node(peaks[n], cur); sz >>= 1; }
	peaks[n] = cur;
	c.size = size + 1;
	c.history, c.state = authority.history_root(peaks, c.size), authority.state_root(*state);
	b := authority.encode_checkpoint(c);
	sig := crypto.slhdsa_sign(priv, authority.SIGNATURE_CONTEXT, b,, temp);
	out: [..]u8;
	out.allocator = temp;
	array_add(*out, ..u8.[1, 0]);
	array_add(*out, ..b);
	array_add(*out, ..sig);
	array_add(*out, ..u8.[1, 0, xx entry.count, 0]);
	array_add(*out, ..entry);
	return out;
}

node :: (a: [32]u8, b: [32]u8) -> [32]u8 {
	ab: [64]u8;
	memcpy(ab.data, a.data, 32);
	memcpy(ab.data + 32, b.data, 32);
	return crypto.blake3_derive(authority.NODE_CONTEXT, ab);
}
