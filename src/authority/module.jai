/// Authority logs (FEDERATED.md §6, TODO.md "Federation 1"): an identity's append-only history of its key rotations, addresses and certificate, its current state, and the checkpoints it signs over both.
#import "Basic";
#import "String";
crypto :: #import "crypto";
keys :: #import "keys";

// Every format here is frozen once shipped: changing one makes every stored log and checkpoint unreadable.
//
// An entry is its Kind byte, then:
//     Genesis:     the identity's four leaf keys (signing, exchange, recovery, policy), 32 bytes each. The
//                  first entry, and only there: they must hash to the identity's root (keys.root_of).
//     Rotate:      a keys.Leaf (Signing, Exchange or Recovery), then its new public key, 32 bytes. Only in a
//                  checkpoint the recovery key signs (FEDERATED.md §26.4): a stolen everyday key rotates nothing.
//     Address:     family (4 or 6), then "host:port" (u8 length, printable ASCII); empty removes it.
//     Certificate: the TLS certificate's hash, 32 bytes; zeros remove it.
//
// The history is a Merkle Mountain Range: leaf = derive_key(LEAF_CONTEXT, entry), node =
// derive_key(NODE_CONTEXT, left || right), each peak a perfect tree, and its root
// derive_key(HISTORY_CONTEXT, size u64 LE || bag), where bag folds the peaks right to left as node(peak, bag).
// The state is a sparse Merkle tree over 256-bit keys derive_key(STATE_KEY_CONTEXT, name), MSB first, with
// leaf derive_key(STATE_LEAF_CONTEXT, key || value) and empty subtrees hashing to empty[h] = node(empty[h-1],
// empty[h-1]) from 32 zero bytes. Names: "key/signing", "key/exchange", "key/recovery", "key/policy",
// "address/4", "address/6" and "certificate", the last three only while set.
//
// A checkpoint is root[32] sequence[u64] size[u64] history[32] state[32] previous[32] expiry[s64 ms]
// signer[u8], all LE, then the SLH-DSA signature over those bytes under SIGNATURE_CONTEXT. Sequence 1 holds
// the genesis entry and has zeros for previous; each later one names the hash (derive_key(CHECKPOINT_CONTEXT,
// bytes)) of the one before, so a history can only grow. It's signed by a key of the state before its
// entries: the signing key, or the recovery key, which alone may rotate (itself included).
LEAF_CONTEXT :: "fastcord 2026-10-30 authority entry v1";
NODE_CONTEXT :: "fastcord 2026-10-30 authority node v1";
HISTORY_CONTEXT :: "fastcord 2026-10-30 authority history v1";
STATE_KEY_CONTEXT :: "fastcord 2026-10-30 authority state key v1";
STATE_LEAF_CONTEXT :: "fastcord 2026-10-30 authority state leaf v1";
STATE_NODE_CONTEXT :: "fastcord 2026-10-30 authority state node v1";
CHECKPOINT_CONTEXT :: "fastcord 2026-10-30 authority checkpoint v1";
SIGNATURE_CONTEXT :: "fastcord 2026-10-30 authority checkpoint signature v1";

Kind :: enum u8 { Genesis :: 0; Rotate :: 1; Address :: 2; Certificate :: 3; }
Signer :: enum u8 { Signing :: 0; Recovery :: 1; }

MAX_ADDRESS :: 128;
MAX_BATCH :: 256;       // Entries in one checkpoint.
MAX_UPDATE :: 4096;     // Checkpoints in one update.
MAX_ENTRIES :: 1 << 32; // A history's size, so its MMR never has more than 32 peaks.
GENESIS_BYTES :: 1 + 4 * 32;
CHECKPOINT_BYTES :: 32 + 8 + 8 + 32 + 32 + 32 + 8 + 1;
SIGNED_BYTES :: CHECKPOINT_BYTES + crypto.SLHDSA_SIGNATURE_BYTES;

State :: struct {
	key: [4][32]u8; // By keys.Leaf.
	address: [2][MAX_ADDRESS]u8; // IPv4, IPv6.
	address_count: [2]u8;
	certificate: [32]u8;
}

Checkpoint :: struct {
	root: [32]u8; // The identity's.
	sequence: u64;
	size: u64;    // Entries in the history.
	history: [32]u8;
	state: [32]u8;
	previous: [32]u8;
	expiry: s64;  // Unix ms after which it's no longer current.
	signer: Signer;
}

// A View is all that checking the next checkpoint needs: the last one, its history's peaks and its state.
View :: struct {
	checkpoint: Checkpoint;
	hash: [32]u8; // Zeros before the first.
	peaks: [32][32]u8; // Left (tallest) to right, as many as size has set bits.
	state: State;
}

Result :: enum u8 {
	Ok;
	Overridden;    // The recovery key signed a history other than the one held, which it replaced.
	Expired;       // Accepted, but the latest checkpoint has expired: the identity's record is stale.
	Malformed;
	Bad_Signature;
	Not_Extending; // A rollback or a fork: it doesn't grow the history held.
}

address :: (s: *State, family: int) -> string {
	i := ifx family == 6 then 1 else 0;
	return to_string(s.address[i].data, s.address_count[i]);
}

rotate_entry :: (leaf: keys.Leaf, key: [32]u8) -> []u8 {
	e := NewArray(34, u8,, temp);
	e[0], e[1] = xx Kind.Rotate, xx leaf;
	memcpy(e.data + 2, key.data, 32);
	return e;
}

address_entry :: (family: int, host_port: string) -> []u8 {
	e := NewArray(3 + host_port.count, u8,, temp);
	e[0], e[1], e[2] = xx Kind.Address, xx family, xx host_port.count;
	memcpy(e.data + 3, host_port.data, host_port.count);
	return e;
}

certificate_entry :: (hash: [32]u8) -> []u8 {
	e := NewArray(33, u8,, temp);
	e[0] = xx Kind.Certificate;
	memcpy(e.data + 1, hash.data, 32);
	return e;
}

encode_checkpoint :: (checkpoint: Checkpoint) -> [CHECKPOINT_BYTES]u8 {
	c := checkpoint;
	b: [CHECKPOINT_BYTES]u8;
	at := 0;
	put :: (p: *void, n: int) #expand { memcpy(`b.data + `at, p, n); `at += n; }
	put(c.root.data, 32); put(*c.sequence, 8); put(*c.size, 8); put(c.history.data, 32); put(c.state.data, 32);
	put(c.previous.data, 32); put(*c.expiry, 8); put(*c.signer, 1);
	return b;
}

decode_checkpoint :: (b: []u8) -> Checkpoint, bool {
	c: Checkpoint;
	if b.count != CHECKPOINT_BYTES return c, false;
	at := 0;
	get :: (p: *void, n: int) #expand { memcpy(p, `b.data + `at, n); `at += n; }
	get(c.root.data, 32); get(*c.sequence, 8); get(*c.size, 8); get(c.history.data, 32); get(c.state.data, 32);
	get(c.previous.data, 32); get(*c.expiry, 8); get(*c.signer, 1);
	return c, c.signer <= .Recovery && c.size <= MAX_ENTRIES;
}

checkpoint_hash :: (c: Checkpoint) -> [32]u8 {
	b := encode_checkpoint(c);
	return crypto.blake3_derive(CHECKPOINT_CONTEXT, b);
}

history_root :: (peaks: [32][32]u8, size: u64) -> [32]u8 {
	n := popcount(size);
	bag: [32]u8;
	if n == 0 return bag;
	bag = peaks[n - 1];
	for < i: 0..n - 2 bag = node(NODE_CONTEXT, peaks[i], bag);
	b: [40]u8;
	s := size;
	memcpy(b.data, *s, 8);
	memcpy(b.data + 8, bag.data, 32);
	return crypto.blake3_derive(HISTORY_CONTEXT, b);
}

state_root :: (s: *State) -> [32]u8 {
	empty := empty_table();
	return smt(state_items(s), 0, *empty);
}

// A state proof: a bit per depth (MSB first), set where that depth's sibling isn't an empty subtree, then
// those siblings, deepest first.
State_Proof :: struct {
	bits: [32]u8;
	siblings: [..][32]u8;
}

// state_proof proves name's value in s, or that it has none. The siblings are in temp.
state_proof :: (s: *State, name: string) -> State_Proof {
	p: State_Proof;
	p.siblings.allocator = temp;
	empty := empty_table();
	items := state_items(s);
	key := crypto.blake3_derive(STATE_KEY_CONTEXT, xx name);
	for < d: 0..255 {
		other: [..]Item;
		other.allocator = temp;
		for items if bit(it.key, d) != bit(key, d) && same_prefix(it.key, key, d) array_add(*other, it);
		if !other continue;
		p.bits[d / 8] |= cast(u8) (0x80 >> (d % 8));
		array_add(*p.siblings, smt(other, d + 1, *empty));
	}
	return p;
}

// verify_state checks that name holds value under root or, with value empty, that it holds nothing.
verify_state :: (root: [32]u8, name: string, value: []u8, p: State_Proof) -> bool {
	empty := empty_table();
	key := crypto.blake3_derive(STATE_KEY_CONTEXT, xx name);
	h := ifx value.count then state_leaf(key, value) else empty[0];
	used := 0;
	for < d: 0..255 {
		sib := empty[255 - d];
		if p.bits[d / 8] & cast(u8) (0x80 >> (d % 8)) {
			if used >= p.siblings.count return false;
			sib = p.siblings[used];
			used += 1;
		}
		h = ifx bit(key, d) then node(STATE_NODE_CONTEXT, sib, h) else node(STATE_NODE_CONTEXT, h, sib);
	}
	return used == p.siblings.count && same32(h, root);
}

// apply checks c, its signature and its entries against v and, if they all hold, moves v to c.
apply :: (v: *View, c: Checkpoint, sig: []u8, entries: [][]u8) -> Result {
	if !same32(c.root, v.checkpoint.root) || c.sequence != v.checkpoint.sequence + 1 || !same32(c.previous, v.hash) return .Not_Extending;
	if entries.count > MAX_BATCH || c.size != v.checkpoint.size + cast(u64) entries.count return .Malformed;
	first := v.checkpoint.sequence == 0;
	n := v.*;
	if !step(*n, entries, c.signer, first) return .Malformed;
	if first {
		l: [4][32]u8;
		for 0..3 l[it] = keys.leaf_hash(xx it, n.state.key[it]);
		if !same32(keys.root_of(l), c.root) return .Malformed;
	}
	before := ifx first then *n.state else *v.state; // The genesis checkpoint rotates nothing.
	signer := before.key[ifx c.signer == .Recovery then keys.Leaf.Recovery else .Signing];
	if !crypto.slhdsa_verify(signer, SIGNATURE_CONTEXT, encode_checkpoint(c), sig) return .Bad_Signature;
	if !same32(history_root(n.peaks, n.checkpoint.size), c.history) || !same32(state_root(*n.state), c.state) return .Malformed;
	n.checkpoint, n.hash = c, checkpoint_hash(c);
	v.* = n;
	return .Ok;
}

// An identity's own log: every entry and signed checkpoint, kept to hand followers what they missed.
Log :: struct {
	view: View;
	entries: [..][]u8;
	signed: [..][]u8; // Each checkpoint's bytes, then its signature.
}

// create starts k's log with its genesis checkpoint, signed by the recovery key while k holds it.
create :: (k: keys.Keypair, expiry: s64) -> Log, bool {
	log: Log;
	log.view.checkpoint.root = k.root;
	g := NewArray(GENESIS_BYTES, u8,, temp);
	g[0] = xx Kind.Genesis;
	memcpy(g.data + 1, k.signing_pub.data, 32);
	memcpy(g.data + 33, k.exchange_pub.data, 32);
	memcpy(g.data + 65, k.recovery_pub.data, 32);
	memcpy(g.data + 97, k.policy.data, 32);
	add(*log, g);
	ok := ifx k.has_recovery then sign(*log, k.recovery, .Recovery, expiry) else sign(*log, k.signing, .Signing, expiry);
	return log, ok;
}

add :: (log: *Log, entry: []u8) { array_add(*log.entries, array_copy(entry)); }

// sign puts every entry added since the last checkpoint into a new one. SLH-DSA signing takes hundreds of
// milliseconds: batch changes, and keep it off the UI thread. false drops those entries.
sign :: (log: *Log, priv: [crypto.SLHDSA_PRIVATE_BYTES]u8, signer: Signer, expiry: s64) -> bool {
	from := cast(int) log.view.checkpoint.size;
	batch := array_view(log.entries, from, log.entries.count - from);
	v := log.view;
	c := Checkpoint.{root = v.checkpoint.root, sequence = v.checkpoint.sequence + 1, previous = v.hash, expiry = expiry, signer = signer};
	ok := step(*v, batch, signer, c.sequence == 1);
	sig: []u8;
	if ok {
		c.size, c.history, c.state = v.checkpoint.size, history_root(v.peaks, v.checkpoint.size), state_root(*v.state);
		sig = crypto.slhdsa_sign(priv, SIGNATURE_CONTEXT, encode_checkpoint(c),, temp);
		ok = apply(*log.view, c, sig, batch) == .Ok;
	}
	if !ok {
		for log.entries if it_index >= from array_free(it);
		log.entries.count = from;
		return false;
	}
	b := encode_checkpoint(c);
	s := NewArray(SIGNED_BYTES, u8);
	memcpy(s.data, b.data, CHECKPOINT_BYTES);
	memcpy(s.data + CHECKPOINT_BYTES, sig.data, sig.count);
	array_add(*log.signed, s);
	return true;
}

free_log :: (log: *Log) {
	for log.entries array_free(it);
	for log.signed array_free(it);
	array_free(log.entries);
	array_free(log.signed);
	log.* = .{};
}

// update is what a follower holding sequence `after` (0: nothing) lacks: every later checkpoint, each with
// its entries, in temp. The format: a u16 count, then each signed checkpoint, a u16 entry count and each
// entry (u16 length). load reads update(log, 0) back.
update :: (log: *Log, after: u64) -> []u8 {
	out: [..]u8;
	out.allocator = temp;
	add_u16 :: (v: int) #expand { array_add(*`out, xx (v & 0xFF)); array_add(*`out, xx ((v >> 8) & 0xFF)); }
	from := cast(int) min(after, cast(u64) log.signed.count);
	add_u16(log.signed.count - from);
	start := 0;
	for log.signed {
		c := decode_checkpoint(array_view(it, 0, CHECKPOINT_BYTES));
		end := cast(int) c.size;
		if it_index >= from {
			array_add(*out, ..it);
			add_u16(end - start);
			for e: array_view(log.entries, start, end - start) { add_u16(e.count); array_add(*out, ..e); }
		}
		start = end;
	}
	return out;
}

// load rebuilds an identity's log from update(log, 0), checking every checkpoint as a follower does.
load :: (root: [32]u8, data: []u8) -> Log, bool {
	log: Log;
	log.view.checkpoint.root = root;
	items, ok := parse_update(data);
	if !ok || !items return log, false;
	for items {
		if apply(*log.view, it.checkpoint, it.signature, it.entries) != .Ok { free_log(*log); return log, false; }
		for e: it.entries add(*log, e);
		b := encode_checkpoint(it.checkpoint);
		s := NewArray(SIGNED_BYTES, u8);
		memcpy(s.data, b.data, CHECKPOINT_BYTES);
		memcpy(s.data + CHECKPOINT_BYTES, it.signature.data, it.signature.count);
		array_add(*log.signed, s);
	}
	return log, true;
}

// A Follower is what a client keeps per identity it trusts: the last checkpoint it accepted, and the last
// one the recovery key signed (or the genesis), from which only the recovery key may branch.
Follower :: struct {
	current: View;
	anchor: View;
}

follow :: (root: [32]u8) -> Follower {
	f: Follower;
	f.current.checkpoint.root, f.anchor.checkpoint.root = root, root;
	return f;
}

// accept checks an update and moves f to its latest checkpoint. It must extend what f holds; failing that,
// a history the recovery key signed from f's anchor replaces it, which is how an owner takes back an
// identity whose everyday key was stolen. Anything else is a rollback or a fork, and changes nothing.
// Each signature takes milliseconds to check: keep it off the UI thread.
accept :: (f: *Follower, data: []u8, now_ms: s64) -> Result {
	items, ok := parse_update(data);
	if !ok return .Malformed;
	result := extend(*f.current, *f.anchor, items, false);
	if result == .Not_Extending {
		v, a := f.anchor, f.anchor;
		result = extend(*v, *a, items, true);
		if result != .Ok return result;
		f.current, f.anchor, result = v, a, Result.Overridden;
	}
	if result <= .Overridden && f.current.checkpoint.expiry < now_ms return .Expired;
	return result;
}

#scope_file

Item :: struct {
	key: [32]u8;
	leaf: [32]u8;
}

Update_Item :: struct {
	checkpoint: Checkpoint;
	signature: []u8;
	entries: [][]u8;
}

// step applies entries to n: the state they set and the history they grow. false on any entry that is
// malformed or not allowed where it is.
step :: (n: *View, entries: [][]u8, signer: Signer, first: bool) -> bool {
	if first && (!entries.count || entries[0].count != GENESIS_BYTES || entries[0][0] != xx Kind.Genesis) return false;
	for e: entries {
		if !e.count return false;
		if cast(Kind) e[0] == {
			case .Genesis;
				if !first || it_index != 0 return false;
				for 0..3 memcpy(n.state.key[it].data, e.data + 1 + 32 * it, 32);
			case .Rotate;
				if e.count != 34 || e[1] > xx keys.Leaf.Recovery || signer != .Recovery || first return false;
				memcpy(n.state.key[e[1]].data, e.data + 2, 32);
			case .Address;
				if e.count < 3 || (e[1] != 4 && e[1] != 6) || e[2] > MAX_ADDRESS || e.count != 3 + cast(int) e[2] return false;
				for 3..e.count - 1 if e[it] < 0x20 || e[it] > 0x7E return false;
				i := ifx e[1] == 6 then 1 else 0;
				memcpy(n.state.address[i].data, e.data + 3, e[2]);
				n.state.address_count[i] = e[2];
			case .Certificate;
				if e.count != 33 return false;
				memcpy(n.state.certificate.data, e.data + 1, 32);
			case;
				return false;
		}
		if n.checkpoint.size >= MAX_ENTRIES return false;
		append_leaf(n, e);
	}
	return true;
}

// append_leaf adds an entry to the history: equal-height peaks merge, as a binary counter carries.
append_leaf :: (v: *View, entry: []u8) {
	cur := crypto.blake3_derive(LEAF_CONTEXT, entry);
	n := popcount(v.checkpoint.size);
	s := v.checkpoint.size;
	while s & 1 { n -= 1; cur = node(NODE_CONTEXT, v.peaks[n], cur); s >>= 1; }
	v.peaks[n] = cur;
	v.checkpoint.size += 1;
}

// extend applies the items after v's checkpoint to copies of v and its anchor, and keeps them only if all
// hold. With need_recovery, one of them must be the recovery key's.
extend :: (v: *View, anchor: *View, items: []Update_Item, need_recovery: bool) -> Result {
	start := 0;
	if v.checkpoint.sequence {
		start = -1;
		for items if same32(checkpoint_hash(it.checkpoint), v.hash) { start = it_index + 1; break; }
		if start < 0 && items.count && items[0].checkpoint.sequence == v.checkpoint.sequence + 1 start = 0;
		if start < 0 return .Not_Extending;
	}
	n, a := v.*, anchor.*;
	recovered := false;
	for i: start..items.count - 1 {
		x := items[i];
		r := apply(*n, x.checkpoint, x.signature, x.entries);
		if r != .Ok return r;
		if x.checkpoint.signer == .Recovery || x.checkpoint.sequence == 1 { a = n; recovered = true; }
	}
	if need_recovery && !recovered return .Not_Extending;
	v.*, anchor.* = n, a;
	return .Ok;
}

// parse_update reads an update without copying: its signatures and entries point into data.
parse_update :: (data: []u8) -> []Update_Item, bool {
	r := data;
	ok := true;
	bytes :: (n: int) -> []u8 #expand {
		if n > `r.count { `ok = false; return .[]; }
		v := array_view(`r, 0, n);
		`r.data += n; `r.count -= n;
		return v;
	}
	get_u16 :: () -> int #expand { b := bytes(2); return ifx b.count then b[0] | (cast(int) b[1] << 8) else 0; }
	n := get_u16();
	if !ok || n > MAX_UPDATE return .[], false;
	items := NewArray(n, Update_Item,, temp);
	for * items {
		c: bool;
		it.checkpoint, c = decode_checkpoint(bytes(CHECKPOINT_BYTES));
		it.signature = bytes(crypto.SLHDSA_SIGNATURE_BYTES);
		m := get_u16();
		if !ok || !c || m > MAX_BATCH return .[], false;
		it.entries = NewArray(m, []u8,, temp);
		for * e: it.entries e.* = bytes(get_u16());
		if !ok return .[], false;
	}
	return items, r.count == 0;
}

state_items :: (s: *State) -> []Item {
	items: [..]Item;
	items.allocator = temp;
	put :: (name: string, value: []u8) #expand {
		k := crypto.blake3_derive(STATE_KEY_CONTEXT, xx name);
		array_add(*`items, .{k, state_leaf(k, value)});
	}
	put("key/signing", s.key[0]);
	put("key/exchange", s.key[1]);
	put("key/recovery", s.key[2]);
	put("key/policy", s.key[3]);
	if s.address_count[0] put("address/4", array_view(s.address[0], 0, s.address_count[0]));
	if s.address_count[1] put("address/6", array_view(s.address[1], 0, s.address_count[1]));
	none: [32]u8;
	if !same32(s.certificate, none) put("certificate", s.certificate);
	return items;
}

state_leaf :: (key: [32]u8, value: []u8) -> [32]u8 {
	b := NewArray(32 + value.count, u8,, temp);
	memcpy(b.data, key.data, 32);
	memcpy(b.data + 32, value.data, value.count);
	return crypto.blake3_derive(STATE_LEAF_CONTEXT, b);
}

// smt hashes the subtree at depth over items, which share the path to it. It recurses once per key bit, so
// at most 256 deep.
smt :: (items: []Item, depth: int, empty: *[257][32]u8) -> [32]u8 {
	assert(depth <= 256);
	if !items.count return empty.*[256 - depth];
	if depth == 256 { assert(items.count == 1); return items[0].leaf; }
	left, right: [..]Item;
	left.allocator, right.allocator = temp, temp;
	for items array_add(ifx bit(it.key, depth) then *right else *left, it);
	return node(STATE_NODE_CONTEXT, smt(left, depth + 1, empty), smt(right, depth + 1, empty));
}

// empty_table holds the roots of empty subtrees by height, built per call (257 hashes) rather than shared
// between threads.
empty_table :: () -> [257][32]u8 {
	t: [257][32]u8;
	for 1..256 t[it] = node(STATE_NODE_CONTEXT, t[it - 1], t[it - 1]);
	return t;
}

bit :: (key: [32]u8, d: int) -> bool { return (key[d / 8] & cast(u8) (0x80 >> (d % 8))) != 0; }

same_prefix :: (a: [32]u8, b: [32]u8, d: int) -> bool {
	for 0..d - 1 if bit(a, it) != bit(b, it) return false;
	return true;
}

node :: (ctx: string, a: [32]u8, b: [32]u8) -> [32]u8 {
	ab: [64]u8;
	memcpy(ab.data, a.data, 32);
	memcpy(ab.data + 32, b.data, 32);
	return crypto.blake3_derive(ctx, ab);
}

same32 :: (a: [32]u8, b: [32]u8) -> bool { return memcmp(a.data, b.data, 32) == 0; }

popcount :: (x: u64) -> int {
	n := 0;
	y := x;
	while y { n += 1; y &= y - 1; }
	return n;
}
