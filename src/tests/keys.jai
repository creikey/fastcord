// Keys module check: jai build.jai - run src/tests/keys.jai, then build/keys.exe. Writes only under build/keys_test.
#import "Basic";
#import "File";
#import "File_Utilities";
#import "String";
crypto :: #import "crypto";
keys :: #import "keys";
#if OS == .WINDOWS {
	msvcprt :: #library,system,no_dll,link_always "msvcprt";
	ws2_32 :: #library,system,link_always "ws2_32"; // BoringSSL's socket BIOs come in with HPKE.
}

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

	// scrypt: RFC 7914's vectors, then DAVE's fingerprint shape (from Python's hashlib.scrypt).
	hex :: (b: []u8) -> string {
		s := talloc_string(b.count * 2);
		for b { s[2*it_index] = "0123456789abcdef"[it >> 4]; s[2*it_index+1] = "0123456789abcdef"[it & 15]; }
		return s;
	}
	Scrypt_Vector :: struct { pass: string; salt: string; n, r, p: int; want: string; }
	dave_pass: [40]u8;
	for * dave_pass it.* = xx it_index;
	salt := u8.[0x24, 0xca, 0xb1, 0x7a, 0x7a, 0xf8, 0xec, 0x2b, 0x82, 0xb4, 0x12, 0xb9, 0x2d, 0xab, 0x19, 0x2e];
	vectors := Scrypt_Vector.[
		.{"", "", 16, 1, 1, "77d6576238657b203b19ca42c18a0497f16b4844e3074ae8dfdffa3fede21442fcd0069ded0948f8326a753a0fc81f17e8d3e0fb2e0d3628cf35e20c38d18906"},
		.{"password", "NaCl", 1024, 8, 16, "fdbabe1c9d3472007856e7190d01e9fe7c6ad7cbc8237830e77376634b3731622eaf30d92e22a3886ff109279d9830dac727afb94a83ee6d8360cbdfa2cc0640"},
		.{"pleaseletmein", "SodiumChloride", 16384, 8, 1, "7023bdcb3afd7348461c06cd81fd38ebfda8fbba904f8e3ea9b543f6545da1f2d5432955613f0fcf62d49705242a9af9e61e85dc0d651e40dfcf017b45575887"},
		.{to_string(dave_pass.data, 40), to_string(salt.data, 16), 16384, 8, 2, "0a6c9ae5f3e0a12f21ed310b07fd7c22dbdeb7c2264ffb0bf2939bfa2a750c14a2d870f3fb058032aa7e20c2ca201be5df380d179090212229fa5e042d7bd54e"},
	];
	for vectors {
		out: [64]u8;
		check(crypto.scrypt(xx it.pass, xx it.salt, it.n, it.r, it.p, out) && hex(out) == it.want, tprint("scrypt %", it.n));
	}
	t0 = current_time_monotonic();
	out: [32]u8;
	check(crypto.scrypt(xx "password", xx "salt", 1 << 17, 8, 1, out), "scrypt 2^17");
	print("scrypt 2^17: % ms\n", to_milliseconds(current_time_monotonic() - t0));
	check(!crypto.scrypt(xx "password", xx "salt", 1000, 8, 1, out), "scrypt rejects n not a power of two");
	check(!crypto.scrypt(xx "password", xx "salt", 1 << 30, 8, 1, out), "scrypt rejects more than 1 GiB");

	// HPKE with X-Wing: a round trip, then a wrong key, info, ad and every kind of changed byte all fail.
	priv, pub := crypto.xwing_generate();
	priv2, _ := crypto.xwing_generate();
	ad := cast([]u8) "item 7";
	sealed := crypto.hpke_seal(pub, "fc test", ad, xx "the item key, 32 bytes long ....");
	check(sealed.count == 32 + crypto.HPKE_OVERHEAD, "hpke size");
	opened, hok := crypto.hpke_open(priv, "fc test", ad, sealed);
	check(hok && cast(string) opened == "the item key, 32 bytes long ....", "hpke round trip");
	_, hok = crypto.hpke_open(priv2, "fc test", ad, sealed);
	check(!hok, "hpke wrong key");
	_, hok = crypto.hpke_open(priv, "fc other", ad, sealed);
	check(!hok, "hpke wrong info");
	_, hok = crypto.hpke_open(priv, "fc test", xx "item 8", sealed);
	check(!hok, "hpke wrong ad");
	for i: int.[0, 1119, 1120, sealed.count - 1] {
		sealed[i] ^= 1;
		_, hok = crypto.hpke_open(priv, "fc test", ad, sealed);
		check(!hok, tprint("hpke changed byte %", i));
		sealed[i] ^= 1;
	}
	_, hok = crypto.hpke_open(priv, "fc test", ad, array_view(sealed, 0, sealed.count - 1));
	check(!hok, "hpke truncated");
	empty := crypto.hpke_seal(pub, "fc test", .[], .[]);
	opened, hok = crypto.hpke_open(priv, "fc test", .[], empty);
	check(hok && opened.count == 0, "hpke empty plaintext");
	check(crypto.hpke_seal(array_view(pub, 0, 100), "fc test", .[], .[]).count == 0, "hpke rejects a short public key");

	print("% failed\n", failed);
	exit(xx ifx failed then 1 else 0);
}
