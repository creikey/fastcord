/// Identity keypairs: the accounts on self-hosted servers (FEDERATED.md §2 and §26, TODO.md "Keys").
#import "Basic";
#import "String";
#import "File";
#import "File_Utilities";
crypto :: #import "crypto";

// The identity format is frozen: any change here changes every identity root.
// An identity is the BLAKE3 Merkle root over four leaves, each derive_key(LEAF_CONTEXT, kind || key):
//     root = node(node(Signing, Exchange), node(Recovery, Policy)), node = derive_key(NODE_CONTEXT, a || b).
// The root is a genesis commitment, fixed for life: keys change only through rotate records signed by
// the recovery key, never by making a new root.
LEAF_CONTEXT :: "fastcord 2026-10-28 identity leaf v1";
NODE_CONTEXT :: "fastcord 2026-10-28 identity node v1";

Leaf :: enum u8 {
	Signing :: 0;  // SLH-DSA-SHA2-128s public key, the everyday one.
	Exchange :: 1; // X25519 public key.
	Recovery :: 2; // SLH-DSA-SHA2-128s public key, meant to live offline.
	Policy :: 3;   // 32 zero bytes: the v1 policy.
}

Keypair :: struct {
	name: string;
	signing: [crypto.SLHDSA_PRIVATE_BYTES]u8;
	exchange: [32]u8;
	recovery: [crypto.SLHDSA_PRIVATE_BYTES]u8; // Zero once exported and removed from disk.
	has_recovery: bool;
	policy: [32]u8;
	signing_pub: [32]u8;
	exchange_pub: [32]u8;
	recovery_pub: [32]u8;
	root: [32]u8;
}

leaf_hash :: (kind: Leaf, key: [32]u8) -> [32]u8 {
	b: [33]u8;
	b[0] = xx kind;
	memcpy(b.data + 1, key.data, 32);
	return crypto.blake3_derive(LEAF_CONTEXT, b);
}

node_hash :: (a: [32]u8, b: [32]u8) -> [32]u8 {
	ab: [64]u8;
	memcpy(ab.data, a.data, 32);
	memcpy(ab.data + 32, b.data, 32);
	return crypto.blake3_derive(NODE_CONTEXT, ab);
}

leaves :: (k: Keypair) -> [4][32]u8 {
	return .[leaf_hash(.Signing, k.signing_pub), leaf_hash(.Exchange, k.exchange_pub), leaf_hash(.Recovery, k.recovery_pub), leaf_hash(.Policy, k.policy)];
}

root_of :: (l: [4][32]u8) -> [32]u8 { return node_hash(node_hash(l[0], l[1]), node_hash(l[2], l[3])); }

// proof reveals one key: its sibling leaf, then the other pair's node.
proof :: (k: Keypair, kind: Leaf) -> [2][32]u8 {
	l := leaves(k);
	i := cast(int) kind;
	pair := ifx i < 2 then node_hash(l[2], l[3]) else node_hash(l[0], l[1]);
	return .[l[i ^ 1], pair];
}

verify_proof :: (root: [32]u8, kind: Leaf, key: [32]u8, p: [2][32]u8) -> bool {
	h := leaf_hash(kind, key);
	i := cast(int) kind;
	n := ifx (i & 1) != 0 then node_hash(p[0], h) else node_hash(h, p[0]);
	r := ifx i < 2 then node_hash(n, p[1]) else node_hash(p[1], n);
	return same(r, root);
}

// generate makes a new identity. Key generation takes tens of milliseconds: keep it off the UI thread.
generate :: (name: string) -> Keypair {
	k: Keypair;
	k.name = copy_string(name);
	k.signing, k.signing_pub = crypto.slhdsa_generate();
	k.exchange, k.exchange_pub = crypto.x25519_generate();
	k.recovery, k.recovery_pub = crypto.slhdsa_generate();
	k.has_recovery = true;
	k.root = root_of(leaves(k));
	return k;
}

root_hex :: (root: [32]u8, allocator := temp) -> string {
	DIGITS :: "0123456789abcdef";
	s := alloc_string(64,, allocator);
	for root { s[it_index * 2] = DIGITS[it >> 4]; s[it_index * 2 + 1] = DIGITS[it & 15]; }
	return s;
}

free_keypair :: (k: *Keypair) {
	free(k.name);
	crypto.zero(k);
}

// The file format, v1. Plain:
//     "fckeyv1\n", flags (bit 0: recovery private key present), name length, name,
//     signing private key, X25519 private key, recovery public key, recovery private key (zeros when
//     absent), policy, root, then BLAKE3 of everything before it.
// At rest on Windows the whole plain file is wrapped with DPAPI behind "fckeyw1\n".
// Exports are the plain form, so another machine can import them.
PLAIN_MAGIC :: "fckeyv1\n";
WRAPPED_MAGIC :: "fckeyw1\n";

encode :: (k: Keypair) -> []u8 {
	name := slice(k.name, 0, min(k.name.count, 255));
	n := 8 + 2 + name.count + 64 + 32 + 32 + 64 + 32 + 32 + 32;
	out := NewArray(n, u8, false);
	p := out.data;
	put :: (src: *void, count: int) #expand { memcpy(`p, src, count); `p += count; }
	put(PLAIN_MAGIC.data, 8);
	p[0] = xx ifx k.has_recovery then 1 else 0;
	p[1] = xx name.count;
	p += 2;
	put(name.data, name.count);
	put(k.signing.data, 64);
	put(k.exchange.data, 32);
	put(k.recovery_pub.data, 32);
	put(k.recovery.data, 64);
	put(k.policy.data, 32);
	put(k.root.data, 32);
	h := crypto.blake3(.{p - out.data, out.data});
	put(h.data, 32);
	return out;
}

// decode checks the hash and that the keys still make the stored root.
decode :: (b: []u8) -> Keypair, bool {
	k: Keypair;
	if b.count < 10 || to_string(b.data, 8) != PLAIN_MAGIC return k, false;
	name_len := cast(int) b[9];
	n := 8 + 2 + name_len + 64 + 32 + 32 + 64 + 32 + 32 + 32;
	if b.count != n return k, false;
	if !same(crypto.blake3(.{n - 32, b.data}), (cast(*[32]u8) (b.data + n - 32)).*) return k, false;
	p := b.data + 10;
	take :: (dst: *void, count: int) #expand { memcpy(dst, `p, count); `p += count; }
	k.has_recovery = (b[8] & 1) != 0;
	k.name = copy_string(.{name_len, p});
	p += name_len;
	take(k.signing.data, 64);
	take(k.exchange.data, 32);
	take(k.recovery_pub.data, 32);
	take(k.recovery.data, 64);
	take(k.policy.data, 32);
	take(k.root.data, 32);
	k.signing_pub = crypto.slhdsa_public(k.signing);
	k.exchange_pub = crypto.x25519_public(k.exchange);
	ok := same(root_of(leaves(k)), k.root);
	if k.has_recovery ok &&= same(crypto.slhdsa_public(k.recovery), k.recovery_pub);
	if !ok free_keypair(*k);
	return k, ok;
}

// wrap_secret seals bytes to this OS user (DPAPI on Windows), as the key files are; unwrap_secret returns
// its input unchanged when it isn't wrapped. Free a result only if its data differs from the input's.
wrap_secret :: wrap;
unwrap_secret :: unwrap;

// Boxes and key slots (AT_REST.md). A box is a value sealed under a store's 32-byte key: version 1, a random
// 24-byte nonce, then XChaCha20-Poly1305's ciphertext and tag. Its AD (box_ad) names where the value lives,
// so a box moved to another store, table, column or row won't open.
BOX_OVERHEAD :: 1 + 24 + 16;

box_ad :: (store: string, table: string, column: string, row: []u8) -> []u8 {
	return lp_join("fc-box-v1", store, table, column, cast(string) row);
}

// box_seal is in context.allocator.
box_seal :: (key: [32]u8, ad: []u8, plain: []u8) -> []u8 {
	a: crypto.Aead;
	ok := crypto.aead_init(*a, .XCHACHA20_POLY1305, key);
	assert(ok);
	defer crypto.aead_destroy(*a);
	out := NewArray(BOX_OVERHEAD + plain.count, u8, false);
	out[0] = 1;
	crypto.random_bytes(array_view(out, 1, 24));
	ok = crypto.seal(*a, array_view(out, 25, plain.count), array_view(out, 25 + plain.count, 16), array_view(out, 1, 24), ad, plain);
	assert(ok);
	return out;
}

// box_open is in context.allocator; false for a wrong key or AD, an unknown version or any changed byte.
box_open :: (key: [32]u8, ad: []u8, b: []u8) -> []u8, bool {
	if b.count < BOX_OVERHEAD || b[0] != 1 return .[], false;
	a: crypto.Aead;
	if !crypto.aead_init(*a, .XCHACHA20_POLY1305, key) return .[], false;
	defer crypto.aead_destroy(*a);
	n := b.count - BOX_OVERHEAD;
	out := NewArray(n, u8, false);
	if !crypto.open(*a, out, array_view(b, 1, 24), ad, array_view(b, 25, n), array_view(b, 25 + n, 16)) {
		array_free(out);
		return .[], false;
	}
	return out, true;
}

// A key slot is one way to unlock a store's key (AT_REST.md "Slots"). A password slot boxes the key under
// scrypt(password, salt); its params are version 1, log2 N, r, p, then the 16-byte salt. The password is
// used as typed, with no Unicode normalisation.
SLOT_PASSWORD :: "password";
SCRYPT_LOG2_N :: 17; // 128 MiB and about 0.4 s: never on the UI thread.
SLOT_PARAMS_BYTES :: 4 + 16;

// slot_password_make: params and the wrapped key, both in context.allocator. log2_n is lowered only by tests.
slot_password_make :: (secret: []u8, password: string, store: string, id: []u8, log2_n := SCRYPT_LOG2_N) -> params: []u8, wrapped: []u8 {
	params := NewArray(SLOT_PARAMS_BYTES, u8, false);
	params[0], params[1], params[2], params[3] = 1, xx log2_n, 8, 1;
	crypto.random_bytes(array_view(params, 4, 16));
	kek: [32]u8;
	defer crypto.zero(*kek);
	ok := crypto.scrypt(xx password, array_view(params, 4, 16), 1 << log2_n, 8, 1, kek);
	assert(ok);
	return params, box_seal(kek, slot_ad(store, SLOT_PASSWORD, id), secret);
}

// slot_password_open: the key, in context.allocator, or false for a wrong password or a damaged slot.
// params come from disk, so scrypt refuses any shape past 1 GiB.
slot_password_open :: (params: []u8, wrapped: []u8, password: string, store: string, id: []u8) -> []u8, bool {
	if params.count != SLOT_PARAMS_BYTES || params[0] != 1 || params[1] > 30 return .[], false;
	kek: [32]u8;
	defer crypto.zero(*kek);
	if !crypto.scrypt(xx password, array_view(params, 4, 16), 1 << params[1], params[2], params[3], kek) return .[], false;
	key, ok := box_open(kek, slot_ad(store, SLOT_PASSWORD, id), wrapped);
	return key, ok;
}

slot_ad :: (store: string, kind: string, id: []u8) -> []u8 { return lp_join("fc-slot-v1", store, kind, cast(string) id); }

// lp_join: a label, then each part as a u16 little-endian length and its bytes, in temp.
lp_join :: (label: string, parts: ..string) -> []u8 {
	n := label.count;
	for parts { assert(it.count <= 0xFFFF); n += 2 + it.count; }
	out := NewArray(n, u8, false,, temp);
	memcpy(out.data, label.data, label.count);
	at := label.count;
	for parts {
		out[at], out[at + 1] = cast(u8) (it.count & 0xFF), cast(u8) (it.count >> 8);
		memcpy(out.data + at + 2, it.data, it.count);
		at += 2 + it.count;
	}
	return out;
}

// Storage: <dir>/<root>.key, a second copy in <dir>/copy/, and <dir>/trash/ for removed keys.
// fastcord never deletes a key file. dir lives beside <state>, never inside it, so resetting
// settings or deleting <state> leaves the keys alone.

// save writes both copies. Each write goes to a new file that is synced to disk and read back
// before it replaces the old one.
save :: (dir: string, k: Keypair) -> bool {
	plain := encode(k);
	defer { crypto.zero(plain); array_free(plain); }
	data, wok := wrap(plain);
	defer if data.data != plain.data { crypto.zero(data); array_free(data); }
	if !wok return false;
	name := tprint("%.key", root_hex(k.root));
	ok := true;
	for sub: string.["", "/copy"] {
		d := tprint("%1%2", dir, sub);
		make_directory_if_it_does_not_exist(d, recursive = true);
		ok &&= write_durable(tprint("%/%", d, name), data);
	}
	return ok;
}

// load reads every keypair under dir and repairs a missing or damaged copy from the other one.
load :: (dir: string) -> [..]Keypair {
	names: [..]string;
	names.allocator = temp;
	for sub: string.["", "/copy"] {
		for file_list(tprint("%1%2", dir, sub),, temp) {
			f := path_filename(it);
			if ends_with(f, ".key") && !array_find(names, f) array_add(*names, copy_string(f,, temp));
		}
	}
	out: [..]Keypair;
	for f: names {
		main := tprint("%/%", dir, f);
		copy := tprint("%/copy/%", dir, f);
		k, ok := read_key(main);
		bad: string;
		if ok {
			k2, ok2 := read_key(copy);
			if ok2 free_keypair(*k2);
			else bad = copy;
		} else {
			k, ok = read_key(copy);
			bad = main;
		}
		if !ok continue;
		if bad {
			make_directory_if_it_does_not_exist(path_strip_filename(bad), recursive = true);
			if file_exists(bad) {
				make_directory_if_it_does_not_exist(tprint("%/trash", dir), recursive = true);
				file_move(bad, tprint("%/trash/%-damaged-%", dir, current_unix_ms(), f));
			}
			plain := encode(k);
			data, wok := wrap(plain);
			if wok write_durable(bad, data);
			if data.data != plain.data { crypto.zero(data); array_free(data); }
			crypto.zero(plain);
			array_free(plain);
		}
		array_add(*out, k);
	}
	return out;
}

// trash moves both copies of a keypair to <dir>/trash.
trash :: (dir: string, root: [32]u8) -> bool {
	t := tprint("%/trash", dir);
	make_directory_if_it_does_not_exist(t, recursive = true);
	f := tprint("%.key", root_hex(root));
	stamp := current_unix_ms();
	ok := true;
	for sub: string.["", "/copy"] {
		src := tprint("%1%2/%3", dir, sub, f);
		if file_exists(src) ok &&= file_move(src, tprint("%/%-%-%", t, stamp, ifx sub then "copy" else "main", f));
	}
	return ok;
}

// write_durable writes path so that a crash or power cut leaves the old file or the new one: a synced
// .new file, read back and checked, then renamed over it (the directory synced too).
write_durable :: (path: string, data: []u8) -> bool {
	tmp := tprint("%.new", path);
	f, ok := file_open(tmp, for_writing = true);
	if !ok return false;
	ok = file_write(*f, data.data, data.count) && sync(f);
	file_close(*f);
	if ok {
		back, rok := read_entire_file(tmp, log_errors = false);
		ok = rok && same(crypto.blake3(cast([]u8) back), crypto.blake3(data));
		free(back);
	}
	if ok ok = replace(tmp, path);
	if !ok file_delete(tmp); // The .new file is a failed write, never a key's only copy.
	return ok;
}

#scope_file

same :: (a: [32]u8, b: [32]u8) -> bool { return crypto.constant_time_equal(a, b); }

current_unix_ms :: () -> s64 { return to_milliseconds(current_time_consensus() - APOLLO_TIME_FOR_JAN_1_1970); }

read_key :: (path: string) -> Keypair, bool {
	data, ok := read_entire_file(path, log_errors = false);
	if !ok return .{}, false;
	defer { crypto.zero(cast([]u8) data); free(data); }
	plain, uok := unwrap(cast([]u8) data);
	if !uok return .{}, false;
	defer if plain.data != data.data { crypto.zero(plain); array_free(plain); }
	k, kok := decode(plain);
	return k, kok;
}


#if OS == .WINDOWS {
	#import "Windows_Utf8";
	kernel32 :: #system_library "kernel32";
	crypt32 :: #system_library "crypt32";
	MoveFileExW :: (from: *u16, to: *u16, flags: u32) -> s32 #foreign kernel32;
	LocalFree :: (p: *void) -> *void #foreign kernel32;
	DATA_BLOB :: struct { count: u32; data: *u8; }
	CryptProtectData :: (in: *DATA_BLOB, desc: *u16, entropy: *DATA_BLOB, reserved: *void, prompt: *void, flags: u32, out: *DATA_BLOB) -> s32 #foreign crypt32;
	CryptUnprotectData :: (in: *DATA_BLOB, desc: **u16, entropy: *DATA_BLOB, reserved: *void, prompt: *void, flags: u32, out: *DATA_BLOB) -> s32 #foreign crypt32;
	CRYPTPROTECT_UI_FORBIDDEN :: 0x1;
	MOVEFILE_REPLACE_EXISTING :: 0x1;
	MOVEFILE_WRITE_THROUGH :: 0x8;

	sync :: file_flush; // FlushFileBuffers.

	replace :: (from: string, to: string) -> bool {
		return MoveFileExW(utf8_to_wide(from,, temp), utf8_to_wide(to,, temp), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH) != 0;
	}

	// wrap seals the plain file with DPAPI, which ties it to this Windows user.
	wrap :: (plain: []u8) -> []u8, bool {
		in := DATA_BLOB.{xx plain.count, plain.data};
		out: DATA_BLOB;
		if !CryptProtectData(*in, null, null, null, null, CRYPTPROTECT_UI_FORBIDDEN, *out) return .[], false;
		b := NewArray(8 + out.count, u8, false);
		memcpy(b.data, WRAPPED_MAGIC.data, 8);
		memcpy(b.data + 8, out.data, out.count);
		LocalFree(out.data);
		return b, true;
	}

	unwrap :: (b: []u8) -> []u8, bool {
		if b.count < 8 || to_string(b.data, 8) != WRAPPED_MAGIC return b, true;
		in := DATA_BLOB.{xx (b.count - 8), b.data + 8};
		out: DATA_BLOB;
		if !CryptUnprotectData(*in, null, null, null, null, CRYPTPROTECT_UI_FORBIDDEN, *out) return .[], false;
		p := NewArray(out.count, u8, false);
		memcpy(p.data, out.data, out.count);
		crypto.zero(.{out.count, out.data});
		LocalFree(out.data);
		return p, true;
	}
} else {
	POSIX :: #import "POSIX";

	sync :: (f: File) -> bool { return POSIX.fflush(f.handle) == 0 && POSIX.fsync(POSIX.fileno(f.handle)) == 0; }

	// rename replaces atomically; syncing the directory makes the new name durable too.
	replace :: (from: string, to: string) -> bool {
		if POSIX.rename(temp_c_string(from), temp_c_string(to)) != 0 return false;
		fd := POSIX.open(temp_c_string(path_strip_filename(to)), POSIX.O_RDONLY);
		if fd >= 0 { POSIX.fsync(fd); POSIX.close(fd); }
		return true;
	}

	// @Todo: Wrap with the Keychain (macOS) and libsecret (Linux).
	wrap :: (plain: []u8) -> []u8, bool { return plain, true; }
	unwrap :: (b: []u8) -> []u8, bool { return b, true; }
}
