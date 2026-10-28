// Keys module check: jai build.jai - run src/tests/keys.jai, then build/keys.exe. Writes only under build/keys_test.
#import "Basic";
#import "File";
#import "File_Utilities";
#import "String";
crypto :: #import "crypto";
keys :: #import "keys";
#if OS == .WINDOWS msvcprt :: #library,system,no_dll,link_always "msvcprt";

same :: (a: []u8, b: []u8) -> bool { return crypto.constant_time_equal(a, b); }

main :: () {
	failed := 0;
	check :: (ok: bool, what: string) #expand {
		if !ok { print("FAIL: %\n", what); `failed += 1; }
	}

	// BLAKE3's published test vector for the empty input.
	check(keys.root_hex(crypto.blake3(.[])) == "af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262", "blake3 empty");

	t0 := current_time_monotonic();
	k := keys.generate("Default");
	print("generate: % ms\n", to_milliseconds(current_time_monotonic() - t0));

	for kind: enum_values_as_enum(keys.Leaf) {
		key := ifx kind == .Signing then k.signing_pub else ifx kind == .Exchange then k.exchange_pub else ifx kind == .Recovery then k.recovery_pub else k.policy;
		p := keys.proof(k, kind);
		check(keys.verify_proof(k.root, kind, key, p), tprint("proof %", kind));
		key[0] ^= 1;
		check(!keys.verify_proof(k.root, kind, key, p), tprint("bad proof %", kind));
	}

	t0 = current_time_monotonic();
	msg := cast([]u8) "hello";
	sig := crypto.slhdsa_sign(k.signing, "fastcord test", msg);
	print("sign: % ms\n", to_milliseconds(current_time_monotonic() - t0));
	check(crypto.slhdsa_verify(k.signing_pub, "fastcord test", msg, sig), "verify");
	check(!crypto.slhdsa_verify(k.signing_pub, "fastcord other", msg, sig), "verify other context");

	b := keys.encode(k);
	d, ok := keys.decode(b);
	check(ok && d.name == "Default" && same(d.root, k.root) && same(d.signing, k.signing) && same(d.recovery, k.recovery), "round trip");
	b[b.count / 2] ^= 1;
	_, ok = keys.decode(b);
	check(!ok, "tampered file rejected");

	dir := "build/keys_test";
	delete_directory(dir);
	check(keys.save(dir, k), "save");
	name := tprint("%.key", keys.root_hex(k.root));
	main_path := tprint("%/%", dir, name);
	data, rok := read_entire_file(main_path);
	check(rok && !contains(data, to_string(k.signing.data, 64)), "private key not stored in the clear");

	// A damaged main copy loads from the second copy and is rewritten.
	write_entire_file(main_path, "garbage");
	l := keys.load(dir);
	check(l.count == 1 && same(l[0].root, k.root), "load from copy");
	l2 := keys.load(dir);
	check(l2.count == 1 && file_list(tprint("%/trash", dir)).count == 1, "main repaired, damaged file kept in trash");

	check(keys.trash(dir, k.root), "trash");
	check(keys.load(dir).count == 0 && file_list(tprint("%/trash", dir)).count == 3, "trashed, nothing deleted");

	print("% failed\n", failed);
	exit(xx ifx failed then 1 else 0);
}
