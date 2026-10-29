// The wire protocol: binary packets, PQXDH and the Double Ratchet, as pure procedures on values. Nothing
// here touches the database; module.jai stores what these return.
//
// A carrier moves packets like UDP with an attacker on the path: they can be lost, reordered,
// duplicated, replayed or forged. Every packet is authenticated, and a state is only replaced by the
// copy that successfully decrypted, so a bad packet never changes anything. How a packet travels (text
// in a message, bytes on a socket) is the carrier's business; the core sees only bytes.
//
// Byte 0 of a packet is VERSION, byte 1 the Kind:
//     Hello: root[32] ik[32] proof[64] spk[32] pqpk[1184] sk[32] sk_proof[64] signature[7856]
//     Init:  hello_id[32] root[32] ik[32] proof[64] ek[32] pqct[1088] header[40] ciphertext tag[16]
//     Msg:   session[16] header[40] ciphertext tag[16]
// header = dh[32] pn[u32 LE] n[u32 LE]. ik is the identity's Exchange key, proven to its root by proof.
// hello_id is BLAKE3 of the whole Hello packet; a session's ID is BLAKE3 of the Init up to its header.
// sk is the identity's SLH-DSA Signing key, proven to the same root, and signature is SLH-DSA over the
// Hello before it under HELLO_CONTEXT (E2E 5): the prekeys are the identity's own, so the carrier can't
// swap them to read the first message.

VERSION :: 4;
MAX_PACKET :: 16384; // The most any carrier may set as its largest packet.

Kind :: enum u8 { Hello :: 1; Init :: 2; Msg :: 3; }

// The first plaintext byte says what a ratchet message holds. Text is the text alone; every later kind
// has a Body (encode_body): a message with a reply or files is a Post, and Edit, Delete, React and Unreact
// name their target, the delivery they change.
Content :: enum u8 { Text :: 0; Accept :: 1; Post :: 2; Edit :: 3; Delete :: 4; React :: 5; Unreact :: 6; }
SILENT :: cast(u8) 0x80; // Set on the Content byte: sent with @silent, so no sound or notification on any carrier.

HEADER_BYTES :: 40;
TAG_BYTES :: 16;
HELLO_SIGNED_BYTES :: 2 + 32 + 32 + 64 + 32 + crypto.MLKEM768_PUBLIC_BYTES + 32 + 64;
HELLO_BYTES :: HELLO_SIGNED_BYTES + crypto.SLHDSA_SIGNATURE_BYTES;
HELLO_CONTEXT :: "fastcord 2026-10-29 e2e signed prekeys v1";
INIT_PREFIX_BYTES :: 2 + 32 + 32 + 32 + 64 + 32 + crypto.MLKEM768_CIPHERTEXT_BYTES;
MSG_PREFIX_BYTES :: 2 + 16;

// max_text is the longest text one Msg holds on a carrier whose largest packet is limit: the rest is the
// prefix, header and tag, the Content byte and the padding's 0x80.
max_text :: (limit: int) -> int { return limit - MSG_PREFIX_BYTES - HEADER_BYTES - TAG_BYTES - 2; }

// A Body, after the Content byte: target and reply (u8 length, then the carrier's delivery ID), a u8 count
// of files, each key[32] digest[32] size[u32 LE] width[u16 LE] height[u16 LE] flags[u8] name (u8 length)
// mime (u8 length) description (u16 LE length), a u8 count of stickers (u8 length each), then the text to
// the end.
Body :: struct {
	content: Content;
	silent: bool;
	target: string; // Edit, Delete, React, Unreact: the delivery they change.
	reply: string;  // The delivery this one answers.
	files: []File;
	text: string;   // React and Unreact: the emoji.
	stickers: []string; // Opaque, as the carrier names them.
}

// A File is sent as its own ciphertext (seal_file), uploaded wherever the carrier keeps files, in the order
// of the Body's files; only the message holds its key, its BLAKE3 digest and what it really is.
File :: struct {
	key: [32]u8;
	digest: [32]u8; // Of the ciphertext.
	size: s64;      // Of the plaintext.
	width, height: int;
	spoiler: bool;
	name, mime, description: string;
}

MAX_FILES :: 10;
MAX_FILE :: 500 << 20; // The most any carrier takes in one file today (Discord with Nitro).
MAX_TARGET :: 64;
MAX_REACTION :: 128;
MAX_STICKERS :: 3;
FILE_BLOCK :: 4096; // A file is padded with zeros to a multiple of this before sealing, as text is to PAD_BLOCK.
FILE_CONTEXT :: "fastcord 2026-10-29 e2e file v1";

encode_body :: (b: Body) -> []u8 {
	out: [..]u8;
	out.allocator = temp;
	array_add(*out, (cast(u8) b.content) | (ifx b.silent then SILENT else 0));
	if b.content == .Text { array_add(*out, ..cast([]u8) b.text); return out; }
	if b.content == .Accept return out;
	add_str :: (out: *[..]u8, s: string, wide := false) {
		array_add(out, xx (s.count & 0xFF));
		if wide array_add(out, xx (s.count >> 8));
		array_add(out, ..cast([]u8) s);
	}
	add_str(*out, b.target);
	add_str(*out, b.reply);
	array_add(*out, xx b.files.count);
	for f: b.files {
		array_add(*out, ..f.key); array_add(*out, ..f.digest);
		for 0..3 array_add(*out, xx ((f.size >> (8 * it)) & 0xFF));
		for v: int.[f.width, f.height] { array_add(*out, xx (v & 0xFF)); array_add(*out, xx ((v >> 8) & 0xFF)); }
		array_add(*out, xx f.spoiler);
		add_str(*out, f.name); add_str(*out, f.mime); add_str(*out, f.description, wide = true);
	}
	array_add(*out, xx b.stickers.count);
	for b.stickers add_str(*out, it);
	array_add(*out, ..cast([]u8) b.text);
	return out;
}

// parse_body reads a Content byte and its Body, checking every length and field before using it. The
// strings point into pt; files are in temp.
parse_body :: (pt: []u8) -> Body, bool {
	b: Body;
	if pt.count < 1 || (pt[0] & ~SILENT) > xx Content.Unreact return b, false;
	b.content, b.silent = xx (pt[0] & ~SILENT), (pt[0] & SILENT) != 0;
	r := array_view(pt, 1, pt.count - 1);
	if b.content == .Text { b.text = xx r; return b, valid_utf8(b.text); }
	if b.content == .Accept return b, r.count == 0;
	ok := true;
	bytes :: (n: int) -> []u8 #expand {
		if n > `r.count { `ok = false; return .[]; }
		v := array_view(`r, 0, n);
		`r.data += n; `r.count -= n;
		return v;
	}
	num :: (n: int) -> int #expand { v := 0; for < bytes(n) v = (v << 8) | it; return v; }
	str :: (wide := false) -> string #expand { return xx bytes(num(ifx wide then 2 else 1)); }
	b.target = str();
	b.reply = str();
	n := num(1);
	if n > MAX_FILES return b, false;
	files := NewArray(n, File,, temp);
	for * files {
		memcpy(it.key.data, bytes(32).data, ifx ok then 32 else 0);
		memcpy(it.digest.data, bytes(32).data, ifx ok then 32 else 0);
		it.size = num(4);
		it.width = num(2);
		it.height = num(2);
		it.spoiler = num(1) == 1;
		it.name = str();
		it.mime = str();
		it.description = str(wide = true);
		ok &&= it.size <= MAX_FILE && it.name.count && valid_utf8(it.name) && valid_utf8(it.description) && printable(it.mime)
			&& find_index_of_any_from_left(it.name, "/\\\x00") < 0;
		if !ok break;
	}
	b.files = files;
	n = num(1);
	if n > MAX_STICKERS return b, false;
	stickers := NewArray(n, string,, temp);
	for * stickers { it.* = str(); ok &&= it.count && valid_utf8(it.*); }
	b.stickers = stickers;
	b.text = xx r;
	if !ok || b.target.count > MAX_TARGET || b.reply.count > MAX_TARGET || !valid_utf8(b.text) return b, false;
	some := b.text.count || files.count || stickers.count;
	if b.content == {
		case .Post;    return b, !b.target.count && some;
		case .Edit;    return b, b.target.count && some;
		case .Delete;  return b, b.target.count && !b.reply.count && !files.count && !stickers.count && !b.text.count;
		case;          return b, b.target.count && !b.reply.count && !files.count && !stickers.count && b.text.count && b.text.count <= MAX_REACTION;
	}
}

// A ratchet plaintext is a Content byte and its body, then ISO/IEC 7816-4 padding (0x80, then zeros) up
// to a multiple of PAD_BLOCK, as Signal pads: the carrier sees a message's length to the block, not the
// byte. limit caps the plaintext, so a message near the carrier's largest packet pads only up to what fits.
PAD_BLOCK :: 160;

pad :: (body: []u8, limit: int) -> []u8 {
	n := min(limit, (body.count + 1 + PAD_BLOCK - 1) / PAD_BLOCK * PAD_BLOCK);
	assert(body.count + 1 <= n);
	pt := NewArray(n, u8,, temp);
	memcpy(pt.data, body.data, body.count);
	pt[body.count] = 0x80;
	return pt;
}

// unpad returns the Content byte and body, or false when the padding is malformed.
unpad :: (pt: []u8) -> []u8, bool {
	n := pt.count;
	while n > 0 && pt[n - 1] == 0 n -= 1;
	if n < 2 || pt[n - 1] != 0x80 return .[], false;
	return array_view(pt, 0, n - 1), true;
}

// sealed_size is a file's ciphertext size: padded to the block, then the tag.
sealed_size :: (size: s64) -> s64 { return (size + FILE_BLOCK - 1) / FILE_BLOCK * FILE_BLOCK + TAG_BYTES; }

// seal_file encrypts data under a new key with ChaCha20-Poly1305 (the key is used once, so the nonce is
// zero) and fills f's key, digest and size. The ciphertext is on the heap.
seal_file :: (data: []u8, f: *File) -> []u8 {
	n := sealed_size(data.count);
	out := NewArray(n, u8);
	memcpy(out.data, data.data, data.count);
	crypto.random_bytes(f.key);
	f.size = data.count;
	pt := array_view(out, 0, n - TAG_BYTES);
	ok := file_aead(true, f.key, pt, pt, array_view(out, n - TAG_BYTES, TAG_BYTES));
	assert(ok);
	f.digest = crypto.blake3(out);
	return out;
}

// open_file checks a downloaded ciphertext's size and digest, then decrypts it; the plaintext is on the
// heap, f.size bytes in a buffer of the padded size.
open_file :: (f: File, ct: []u8) -> []u8, bool {
	if f.size > MAX_FILE || ct.count != sealed_size(f.size) || !same(crypto.blake3(ct), f.digest) return .[], false;
	out := NewArray(ct.count - TAG_BYTES, u8, false);
	if !file_aead(false, f.key, array_view(ct, 0, out.count), out, array_view(ct, out.count, TAG_BYTES)) { array_free(out); return .[], false; }
	out.count = f.size;
	return out, true;
}

// Double Ratchet, Signal spec section 3.5: the most message keys one message may skip over.
MAX_SKIP :: 1000;

Identity :: struct {
	root: [32]u8;
	ik_priv: [32]u8;
	ik_pub: [32]u8;
	proof: [2][32]u8;
	sk_priv: [crypto.SLHDSA_PRIVATE_BYTES]u8; // Signs our Hellos' prekeys.
	sk_pub: [32]u8;
	sk_proof: [2][32]u8;
}

identity_of :: (k: keys.Keypair) -> Identity {
	return .{root = k.root, ik_priv = k.exchange, ik_pub = k.exchange_pub, proof = keys.proof(k, .Exchange),
		sk_priv = k.signing, sk_pub = k.signing_pub, sk_proof = keys.proof(k, .Signing)};
}

// A Conversation is where packets travel, as its carrier names it: the carrier (no NUL byte), the
// conversation's ID and both parties' IDs, all opaque bytes, and the carrier's largest packet.
Conversation :: struct {
	carrier: string;
	id: string;
	me, peer: string;
	limit: int;
}

// binding hashes a conversation and its two parties, Alice being the one who accepted and Bob the one
// who sent the Hello, into a session's AD and PQXDH info. Without it a carrier could move a Hello from
// one conversation into another, shown as from someone else, and then move the answer back (an unknown
// key-share). Each field is length-prefixed, so no two conversations hash alike.
BINDING_CONTEXT :: "fastcord 2026-10-29 e2e conversation binding v1";

binding :: (c: Conversation, alice: string, bob: string) -> [32]u8 {
	b: String_Builder;
	b.allocator = temp;
	for string.[c.carrier, c.id, alice, bob] {
		n := cast(u32) it.count;
		append(*b, cast(*u8) *n, 4);
		append(*b, it);
	}
	return crypto.blake3_derive(BINDING_CONTEXT, xx builder_to_string(*b,, temp));
}

AD_BYTES :: 128 + 32;

Prekeys :: struct {
	spk_priv: [32]u8;
	pq_seed: [64]u8;
}

Packet :: struct {
	data: [MAX_PACKET]u8;
	count: int;
	limit := MAX_PACKET; // The carrier's largest packet: building past it fails.
}

bytes :: (p: *Packet) -> []u8 { return .{p.count, p.data.data}; }

Hello :: struct {
	id: [32]u8;
	root: [32]u8;
	ik: [32]u8;
	spk: [32]u8;
	pqpk: []u8; // Points into the packet.
}

Init :: struct {
	hello_id: [32]u8;
	root: [32]u8;
	ik: [32]u8;
	ek: [32]u8;
	pqct: []u8;
	session: [16]u8;
	message: []u8; // header, ciphertext and tag
}

Ratchet :: struct {
	dhs_priv: [32]u8;
	dhs_pub: [32]u8;
	dhr: [32]u8;
	rk: [32]u8;
	cks: [32]u8;
	ckr: [32]u8;
	ns, nr, pn: u32;
	has_dhr, has_cks, has_ckr: bool;
}

// A Session is plain bytes: module.jai stores it as a blob and rejects one of another size.
Session :: struct {
	id: [16]u8;
	ad: [AD_BYTES]u8; // root_a ik_a root_b ik_b, then the binding (PQXDH section 3.3's AD, plus roots and the conversation).
	ratchet: Ratchet;
}

Skipped :: struct {
	dh: [32]u8;
	n: u32;
	mk: [32]u8;
}

Header :: struct {
	dh: [32]u8;
	pn, n: u32;
}

// ---- Hello ----

// make_hello fails when a Hello doesn't fit the carrier. Signing takes hundreds of milliseconds: it runs
// on the database thread.
make_hello :: (me: Identity, out: *Packet) -> Prekeys, bool {
	pre: Prekeys;
	if HELLO_BYTES > out.limit return pre, false;
	spk_pub: [32]u8;
	pq_pub: [crypto.MLKEM768_PUBLIC_BYTES]u8;
	pre.spk_priv, spk_pub = crypto.x25519_generate();
	pre.pq_seed, pq_pub = crypto.mlkem768_generate();
	out.count = 0;
	put(out, .[VERSION, xx Kind.Hello]);
	put(out, me.root); put(out, me.ik_pub); put(out, me.proof[0]); put(out, me.proof[1]);
	put(out, spk_pub); put(out, pq_pub);
	put(out, me.sk_pub); put(out, me.sk_proof[0]); put(out, me.sk_proof[1]);
	sig := crypto.slhdsa_sign(me.sk_priv, HELLO_CONTEXT, bytes(out),, temp);
	put(out, sig);
	assert(out.count == HELLO_BYTES);
	return pre, true;
}

parse_hello :: (p: []u8) -> Hello, bool {
	h: Hello;
	if p.count != HELLO_BYTES || p[0] != VERSION || p[1] != xx Kind.Hello return h, false;
	h.id = crypto.blake3(p);
	r := array_view(p, 2, p.count - 2);
	proof: [2][32]u8;
	take(*r, *h.root); take(*r, *h.ik); take(*r, *proof[0]); take(*r, *proof[1]); take(*r, *h.spk);
	h.pqpk = array_view(r, 0, crypto.MLKEM768_PUBLIC_BYTES);
	r = array_view(r, crypto.MLKEM768_PUBLIC_BYTES, r.count - crypto.MLKEM768_PUBLIC_BYTES);
	sk: [32]u8;
	sk_proof: [2][32]u8;
	take(*r, *sk); take(*r, *sk_proof[0]); take(*r, *sk_proof[1]);
	return h, keys.verify_proof(h.root, .Exchange, h.ik, proof) && keys.verify_proof(h.root, .Signing, sk, sk_proof)
		&& crypto.slhdsa_verify(sk, HELLO_CONTEXT, array_view(p, 0, HELLO_SIGNED_BYTES), r);
}

// A safety number is 60 digits, 30 per identity root, the lower root's first so both people see the same.
// Each half is six 5-byte big-endian chunks of a hash of the root, each mod 100000, as Signal's numeric
// fingerprint makes them. A forged root matching all 30 digits costs about 2^100 tries.
SAFETY_CONTEXT :: "fastcord 2026-10-29 safety number v1";

safety_number :: (a: [32]u8, b: [32]u8) -> [60]u8 {
	roots: [2][32]u8;
	roots[0], roots[1] = a, b;
	if memcmp(a.data, b.data, 32) > 0 roots[0], roots[1] = b, a;
	out: [60]u8;
	for root, half: roots {
		h := crypto.blake3_derive(SAFETY_CONTEXT, root);
		for c: 0..5 {
			v: u64;
			for 0..4 v = (v << 8) | h[c * 5 + it];
			v %= 100000;
			for < 0..4 { out[half * 30 + c * 5 + it] = #char "0" + cast(u8) (v % 10); v /= 10; }
		}
	}
	return out;
}

// ---- PQXDH (Signal's PQXDH spec, revision 3) ----

// accept runs PQXDH as Alice (section 3.3) against a peer's Hello and writes the Init packet carrying
// the first ratchet message.
accept :: (me: Identity, hello: Hello, bind: [32]u8, first: []u8, out: *Packet) -> Session, bool {
	s: Session;
	if same(hello.root, me.root) return s, false; // Our own Hello reflected back.
	if INIT_PREFIX_BYTES + HEADER_BYTES + first.count + TAG_BYTES > out.limit return s, false;
	ek_priv, ek_pub := crypto.x25519_generate();
	defer crypto.zero(*ek_priv);
	dh1, ok1 := crypto.x25519(me.ik_priv, hello.spk);
	dh2, ok2 := crypto.x25519(ek_priv, hello.ik);
	dh3, ok3 := crypto.x25519(ek_priv, hello.spk);
	ct, ss, ok4 := crypto.mlkem768_encap(hello.pqpk);
	if !(ok1 && ok2 && ok3 && ok4) return s, false;
	sk := pqxdh_kdf(dh1, dh2, dh3, ss, bind);
	defer crypto.zero(*sk);

	out.count = 0;
	put(out, .[VERSION, xx Kind.Init]);
	put(out, hello.id); put(out, me.root); put(out, me.ik_pub); put(out, me.proof[0]); put(out, me.proof[1]);
	put(out, ek_pub); put(out, ct);
	assert(out.count == INIT_PREFIX_BYTES);
	s.id = session_id(bytes(out));
	set_ad(*s, me.root, me.ik_pub, hello.root, hello.ik, bind);

	// Double Ratchet section 3.3, RatchetInitAlice: Bob's first ratchet key is his signed prekey.
	r := *s.ratchet;
	r.dhs_priv, r.dhs_pub = crypto.x25519_generate();
	r.dhr, r.has_dhr = hello.spk, true;
	dh, ok := crypto.x25519(r.dhs_priv, r.dhr);
	if !ok return s, false;
	r.rk, r.cks = kdf_rk(sk, dh);
	r.has_cks = true;
	if !encrypt(*s, first, out) return s, false;
	return s, true;
}

parse_init :: (p: []u8) -> Init, bool {
	i: Init;
	if p.count < INIT_PREFIX_BYTES + HEADER_BYTES + TAG_BYTES + 1 || p[0] != VERSION || p[1] != xx Kind.Init return i, false;
	i.session = session_id(array_view(p, 0, INIT_PREFIX_BYTES));
	r := array_view(p, 2, p.count - 2);
	proof: [2][32]u8;
	take(*r, *i.hello_id); take(*r, *i.root); take(*r, *i.ik); take(*r, *proof[0]); take(*r, *proof[1]); take(*r, *i.ek);
	i.pqct = array_view(r, 0, crypto.MLKEM768_CIPHERTEXT_BYTES);
	i.message = array_view(r, i.pqct.count, r.count - i.pqct.count);
	return i, keys.verify_proof(i.root, .Exchange, i.ik, proof);
}

// receive_init runs PQXDH as Bob (section 3.4) with the prekeys of the Hello the Init answers. The
// caller then decrypts i.message with the returned session.
receive_init :: (me: Identity, pre: Prekeys, i: Init, bind: [32]u8) -> Session, bool {
	s: Session;
	if same(i.root, me.root) return s, false;
	dh1, ok1 := crypto.x25519(pre.spk_priv, i.ik);
	dh2, ok2 := crypto.x25519(me.ik_priv, i.ek);
	dh3, ok3 := crypto.x25519(pre.spk_priv, i.ek);
	ss, ok4 := crypto.mlkem768_decap(pre.pq_seed, i.pqct);
	if !(ok1 && ok2 && ok3 && ok4) return s, false;
	sk := pqxdh_kdf(dh1, dh2, dh3, ss, bind);
	defer crypto.zero(*sk);
	s.id = i.session;
	set_ad(*s, i.root, i.ik, me.root, me.ik_pub, bind);
	// RatchetInitBob.
	r := *s.ratchet;
	r.dhs_priv = pre.spk_priv;
	r.dhs_pub = crypto.x25519_public(pre.spk_priv);
	r.rk = sk;
	return s, true;
}

// ---- Double Ratchet (Signal's Double Ratchet spec, revision 4) ----

// encrypt appends header, ciphertext and tag to out (section 3.4, RatchetEncrypt).
encrypt :: (s: *Session, pt: []u8, out: *Packet) -> bool {
	r := *s.ratchet;
	if !r.has_cks || out.count + HEADER_BYTES + pt.count + TAG_BYTES > out.limit return false;
	mk: [32]u8;
	r.cks, mk = kdf_ck(r.cks);
	defer crypto.zero(*mk);
	start := out.count;
	put(out, r.dhs_pub); put_u32(out, r.pn); put_u32(out, r.ns);
	r.ns += 1;
	header := array_view(bytes(out), start, HEADER_BYTES);
	ct := array_view(out.data, out.count, pt.count);
	tag := array_view(out.data, out.count + pt.count, TAG_BYTES);
	if !aead(true, mk, s.ad, header, pt, ct, tag) return false;
	out.count += pt.count + TAG_BYTES;
	return true;
}

parse_header :: (m: []u8) -> Header, bool {
	h: Header;
	if m.count < HEADER_BYTES + TAG_BYTES return h, false;
	memcpy(h.dh.data, m.data, 32);
	h.pn = get_u32(m, 32);
	h.n = get_u32(m, 36);
	return h, true;
}

// decrypt_skipped opens a message with a stored skipped key: the caller found it by (dh, n) and deletes it.
decrypt_skipped :: (s: *Session, mk: [32]u8, m: []u8, pt: []u8) -> bool {
	if m.count < HEADER_BYTES + TAG_BYTES || pt.count != m.count - HEADER_BYTES - TAG_BYTES return false;
	return open_message(s, mk, m, pt);
}

// decrypt advances s and fills pt (sized m.count - HEADER_BYTES - TAG_BYTES); keys it skips over are
// appended to skipped. Call it on a copy: on failure the copy is garbage, and the caller keeps the old
// state, as section 3.5 requires.
decrypt :: (s: *Session, m: []u8, pt: []u8, skipped: *[..]Skipped) -> bool {
	h, ok := parse_header(m);
	if !ok || pt.count != m.count - HEADER_BYTES - TAG_BYTES return false;
	r := *s.ratchet;
	if !r.has_dhr || !same(h.dh, r.dhr) {
		if !skip_keys(r, h.pn, skipped) return false;
		// DHRatchet.
		r.pn = r.ns;
		r.ns, r.nr = 0, 0;
		r.dhr, r.has_dhr = h.dh, true;
		dh, ok := crypto.x25519(r.dhs_priv, r.dhr);
		if !ok return false;
		r.rk, r.ckr = kdf_rk(r.rk, dh);
		r.has_ckr = true;
		crypto.zero(*r.dhs_priv);
		r.dhs_priv, r.dhs_pub = crypto.x25519_generate();
		dh, ok = crypto.x25519(r.dhs_priv, r.dhr);
		if !ok return false;
		r.rk, r.cks = kdf_rk(r.rk, dh);
		r.has_cks = true;
	}
	if !skip_keys(r, h.n, skipped) return false;
	mk: [32]u8;
	r.ckr, mk = kdf_ck(r.ckr);
	defer crypto.zero(*mk);
	r.nr += 1;
	return open_message(s, mk, m, pt);
}

same :: (a: []u8, b: []u8) -> bool { return crypto.constant_time_equal(a, b); }

#scope_file

PQXDH_INFO :: "fastcord_PQXDH_X25519_SHA-256_ML-KEM-768";
RK_INFO :: "fastcord_DoubleRatchet_RootKey";
MK_INFO :: "fastcord_DoubleRatchet_MessageKey";

put :: (p: *Packet, b: []u8) {
	assert(p.count + b.count <= p.limit);
	memcpy(p.data.data + p.count, b.data, b.count);
	p.count += b.count;
}

put_u32 :: (p: *Packet, v: u32) { put(p, .[xx (v & 0xFF), xx ((v >> 8) & 0xFF), xx ((v >> 16) & 0xFF), xx (v >> 24)]); }

get_u32 :: (b: []u8, at: int) -> u32 {
	return cast(u32) b[at] | (cast(u32) b[at + 1] << 8) | (cast(u32) b[at + 2] << 16) | (cast(u32) b[at + 3] << 24);
}

// take copies the next 32 bytes; callers have already checked the length.
take :: (r: *[]u8, out: *[32]u8) {
	memcpy(out.data, r.data, 32);
	r.data += 32;
	r.count -= 32;
}

session_id :: (init_prefix: []u8) -> [16]u8 {
	h := crypto.blake3(init_prefix);
	id: [16]u8;
	memcpy(id.data, h.data, 16);
	return id;
}

set_ad :: (s: *Session, root_a: [32]u8, ik_a: [32]u8, root_b: [32]u8, ik_b: [32]u8, bind: [32]u8) {
	memcpy(s.ad.data, root_a.data, 32);
	memcpy(s.ad.data + 32, ik_a.data, 32);
	memcpy(s.ad.data + 64, root_b.data, 32);
	memcpy(s.ad.data + 96, ik_b.data, 32);
	memcpy(s.ad.data + 128, bind.data, 32);
}

// PQXDH section 2.2: HKDF over F || KM with F = 32 0xFF bytes for X25519 and a zero salt. The info
// names the conversation too, so the shared secret itself differs for any other.
pqxdh_kdf :: (dh1: [32]u8, dh2: [32]u8, dh3: [32]u8, ss: [32]u8, bind: [32]u8) -> [32]u8 {
	km: [32 * 5]u8;
	memset(km.data, 0xFF, 32);
	memcpy(km.data + 32, dh1.data, 32);
	memcpy(km.data + 64, dh2.data, 32);
	memcpy(km.data + 96, dh3.data, 32);
	memcpy(km.data + 128, ss.data, 32);
	zero_salt: [32]u8;
	prk := crypto.hkdf_extract(zero_salt, km);
	info: [PQXDH_INFO.count + 32]u8;
	memcpy(info.data, PQXDH_INFO.data, PQXDH_INFO.count);
	memcpy(info.data + PQXDH_INFO.count, bind.data, 32);
	sk: [32]u8;
	crypto.hkdf_expand(prk, info, sk);
	crypto.zero(*km);
	crypto.zero(*prk);
	return sk;
}

// Double Ratchet section 5.2's recommended KDF_RK: HKDF with the root key as salt.
kdf_rk :: (rk: [32]u8, dh: [32]u8) -> rk: [32]u8, ck: [32]u8 {
	prk := crypto.hkdf_extract(rk, dh);
	out: [64]u8;
	crypto.hkdf_expand(prk, xx RK_INFO, out);
	new_rk, ck: [32]u8;
	memcpy(new_rk.data, out.data, 32);
	memcpy(ck.data, out.data + 32, 32);
	crypto.zero(*out);
	crypto.zero(*prk);
	return new_rk, ck;
}

// KDF_CK, section 5.2: HMAC with constant 0x02 for the next chain key and 0x01 for the message key.
kdf_ck :: (ck: [32]u8) -> ck: [32]u8, mk: [32]u8 {
	return crypto.hmac_sha256(ck, .[2]), crypto.hmac_sha256(ck, .[1]);
}

// ENCRYPT and DECRYPT with ChaCha20-Poly1305 instead of section 5.2's AES-CBC and HMAC: the key and
// nonce come from HKDF over the message key, which is used once, and the AD is the session's AD
// followed by the header.
aead :: (seal: bool, mk: [32]u8, ad: [AD_BYTES]u8, header: []u8, src: []u8, dst: []u8, tag: []u8) -> bool {
	zero_salt: [32]u8;
	prk := crypto.hkdf_extract(zero_salt, mk);
	kn: [44]u8;
	crypto.hkdf_expand(prk, xx MK_INFO, kn);
	defer { crypto.zero(*kn); crypto.zero(*prk); }
	full_ad: [AD_BYTES + HEADER_BYTES]u8;
	memcpy(full_ad.data, ad.data, AD_BYTES);
	memcpy(full_ad.data + AD_BYTES, header.data, HEADER_BYTES);
	a: crypto.Aead;
	if !crypto.aead_init(*a, .CHACHA20_POLY1305, array_view(kn, 0, 32)) return false;
	defer crypto.aead_destroy(*a);
	nonce := array_view(kn, 32, 12);
	if seal return crypto.seal(*a, dst, tag, nonce, full_ad, src);
	return crypto.open(*a, dst, nonce, full_ad, src, tag);
}

file_aead :: (seal: bool, key: [32]u8, src: []u8, dst: []u8, tag: []u8) -> bool {
	a: crypto.Aead;
	if !crypto.aead_init(*a, .CHACHA20_POLY1305, key) return false;
	defer crypto.aead_destroy(*a);
	nonce: [12]u8;
	if seal return crypto.seal(*a, dst, tag, nonce, xx FILE_CONTEXT, src);
	return crypto.open(*a, dst, nonce, xx FILE_CONTEXT, src, tag);
}

valid_utf8 :: (s: string) -> bool {
	i := 0;
	while i < s.count {
		c := s[i];
		n := ifx c < 0x80 then 1 else ifx (c & 0xE0) == 0xC0 then 2 else ifx (c & 0xF0) == 0xE0 then 3 else ifx (c & 0xF8) == 0xF0 then 4 else 0;
		if n == 0 || i + n > s.count return false;
		for 1..n-1 if (s[i + it] & 0xC0) != 0x80 return false;
		cp := ifx n == 1 then cast(u32) c else cast(u32) c & (cast(u32) 0xFF >> (n + 1));
		for 1..n-1 cp = (cp << 6) | (s[i + it] & 0x3F);
		if (n == 2 && cp < 0x80) || (n == 3 && cp < 0x800) || (n == 4 && (cp < 0x10000 || cp > 0x10FFFF)) || (cp >= 0xD800 && cp <= 0xDFFF) return false;
		i += n;
	}
	return true;
}

printable :: (s: string) -> bool {
	for cast([]u8) s if it < 0x20 || it > 0x7E return false;
	return true;
}

open_message :: (s: *Session, mk: [32]u8, m: []u8, pt: []u8) -> bool {
	header := array_view(m, 0, HEADER_BYTES);
	ct := array_view(m, HEADER_BYTES, m.count - HEADER_BYTES - TAG_BYTES);
	tag := array_view(m, m.count - TAG_BYTES, TAG_BYTES);
	return aead(false, mk, s.ad, header, ct, pt, tag);
}

// SkipMessageKeys, section 3.5.
skip_keys :: (r: *Ratchet, until: u32, skipped: *[..]Skipped) -> bool {
	if !r.has_ckr return true;
	if until < r.nr return true;
	if until - r.nr > MAX_SKIP return false;
	while r.nr < until {
		mk: [32]u8;
		r.ckr, mk = kdf_ck(r.ckr);
		array_add(skipped, .{dh = r.dhr, n = r.nr, mk = mk});
		r.nr += 1;
	}
	return true;
}
