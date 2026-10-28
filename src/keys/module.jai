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
