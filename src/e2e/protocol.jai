// The wire protocol: `fc-` packets, PQXDH and the Double Ratchet, as pure procedures on values. Nothing
// here touches the database; module.jai stores what these return.
//
// Discord is a carrier like UDP with an attacker on the path: packets can be lost, reordered,
// duplicated, replayed or forged. Every packet is authenticated, and a state is only replaced by the
// copy that successfully decrypted, so a bad packet never changes anything.
//
// A packet is `fc-` + unpadded base64url of at most MAX_PACKET bytes. Byte 0 is VERSION, byte 1 the Kind:
//     Hello: root[32] ik[32] proof[64] spk[32] pqpk[1184]
//     Init:  hello_id[32] root[32] ik[32] proof[64] ek[32] pqct[1088] header[40] ciphertext tag[16]
//     Msg:   session[16] header[40] ciphertext tag[16]
// header = dh[32] pn[u32 LE] n[u32 LE]. ik is the identity's Exchange key, proven to its root by proof.
// hello_id is BLAKE3 of the whole Hello packet; a session's ID is BLAKE3 of the Init up to its header.
// Prekeys are unsigned until E2E 5: this stops Discord reading DMs, not swapping keys in the first one.

VERSION :: 3;
MAX_PACKET :: 1497; // 1996 base64url characters, so "fc-" + packet fits one 2000-character message.
PREFIX :: "fc-";

Kind :: enum u8 { Hello :: 1; Init :: 2; Msg :: 3; }

// The first plaintext byte says what a ratchet message holds.
Content :: enum u8 { Text :: 0; Accept :: 1; }

HEADER_BYTES :: 40;
TAG_BYTES :: 16;
HELLO_BYTES :: 2 + 32 + 32 + 64 + 32 + crypto.MLKEM768_PUBLIC_BYTES;
INIT_PREFIX_BYTES :: 2 + 32 + 32 + 32 + 64 + 32 + crypto.MLKEM768_CIPHERTEXT_BYTES;
MSG_PREFIX_BYTES :: 2 + 16;
MAX_PLAINTEXT :: MAX_PACKET - MSG_PREFIX_BYTES - HEADER_BYTES - TAG_BYTES;
MAX_TEXT_BYTES :: MAX_PLAINTEXT - 2; // The Content byte and the padding's 0x80.
INIT_PLAINTEXT :: MAX_PACKET - INIT_PREFIX_BYTES - HEADER_BYTES - TAG_BYTES;

// A ratchet plaintext is the Content byte, the text, then ISO/IEC 7816-4 padding (0x80, then zeros) up to
// a multiple of PAD_BLOCK, as Signal pads: Discord sees a message's length to the block, not the byte.
PAD_BLOCK :: 160;

pad :: (content: Content, text: string, limit := MAX_PLAINTEXT) -> []u8 {
	n := min(limit, (text.count + 2 + PAD_BLOCK - 1) / PAD_BLOCK * PAD_BLOCK);
	assert(text.count + 2 <= n);
	pt := NewArray(n, u8,, temp);
	pt[0] = xx content;
	memcpy(pt.data + 1, text.data, text.count);
	pt[text.count + 1] = 0x80;
	return pt;
}

// unpad returns the Content byte and text, or false when the padding is malformed.
unpad :: (pt: []u8) -> []u8, bool {
	n := pt.count;
	while n > 0 && pt[n - 1] == 0 n -= 1;
	if n < 2 || pt[n - 1] != 0x80 return .[], false;
	return array_view(pt, 0, n - 1), true;
}

// Double Ratchet, Signal spec section 3.5: the most message keys one message may skip over.
MAX_SKIP :: 1000;

Identity :: struct {
	root: [32]u8;
	ik_priv: [32]u8;
	ik_pub: [32]u8;
	proof: [2][32]u8;
}

identity_of :: (k: keys.Keypair) -> Identity {
	return .{root = k.root, ik_priv = k.exchange, ik_pub = k.exchange_pub, proof = keys.proof(k, .Exchange)};
}

// Dm binds a session to the DM it was made in: the channel ID and both Discord user IDs, Alice being
// the one who accepted and Bob the one who sent the Hello. Without it Discord could move a Hello from
// one DM into another, shown as from someone else, and then move the answer back (an unknown key-share).
Dm :: struct { channel, alice, bob: u64; }
AD_BYTES :: 128 + 24;

Prekeys :: struct {
	spk_priv: [32]u8;
	pq_seed: [64]u8;
}

Packet :: struct {
	data: [MAX_PACKET]u8;
	count: int;
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
	ad: [AD_BYTES]u8; // root_a ik_a root_b ik_b, then the Dm's bytes (PQXDH section 3.3's AD, plus roots and the DM).
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

// ---- Text form ----

encode_text :: (packet: []u8) -> string {
	assert(packet.count <= MAX_PACKET);
	out := alloc_string(PREFIX.count + (packet.count * 4 + 2) / 3);
	memcpy(out.data, PREFIX.data, PREFIX.count);
	o := PREFIX.count;
	acc: u32;
	bits := 0;
	for packet {
		acc = (acc << 8) | it;
		bits += 8;
		while bits >= 6 {
			bits -= 6;
			out[o] = B64[(acc >> bits) & 63];
			o += 1;
		}
	}
	if bits { out[o] = B64[(acc << (6 - bits)) & 63]; o += 1; }
	assert(o == out.count);
	return out;
}

// decode_text accepts only the one canonical encoding of a packet: no padding, no other alphabet, and
// zero trailing bits, so a packet has exactly one text form.
decode_text :: (text: string, out: *Packet) -> bool {
	if !begins_with(text, PREFIX) return false;
	s := text;
	advance(*s, PREFIX.count);
	if s.count % 4 == 1 || s.count > (MAX_PACKET * 4 + 2) / 3 return false;
	acc: u32;
	bits := 0;
	o := 0;
	for i: 0..s.count-1 {
		v := B64_INV[s[i]];
		if v == 0xFF return false;
		acc = ((acc << 6) | v) & 0xFFFF;
		bits += 6;
		if bits >= 8 {
			bits -= 8;
			out.data[o] = xx ((acc >> bits) & 0xFF);
			o += 1;
		}
	}
	if (acc & ((cast(u32) 1 << bits) - 1)) != 0 return false;
	out.count = o;
	return o >= 2;
}

// ---- Hello ----

make_hello :: (me: Identity, out: *Packet) -> Prekeys {
	pre: Prekeys;
	spk_pub: [32]u8;
	pq_pub: [crypto.MLKEM768_PUBLIC_BYTES]u8;
	pre.spk_priv, spk_pub = crypto.x25519_generate();
	pre.pq_seed, pq_pub = crypto.mlkem768_generate();
	out.count = 0;
	put(out, .[VERSION, xx Kind.Hello]);
	put(out, me.root); put(out, me.ik_pub); put(out, me.proof[0]); put(out, me.proof[1]);
	put(out, spk_pub); put(out, pq_pub);
	assert(out.count == HELLO_BYTES);
	return pre;
}

parse_hello :: (p: []u8) -> Hello, bool {
	h: Hello;
	if p.count != HELLO_BYTES || p[0] != VERSION || p[1] != xx Kind.Hello return h, false;
	h.id = crypto.blake3(p);
	r := array_view(p, 2, p.count - 2);
	proof: [2][32]u8;
	take(*r, *h.root); take(*r, *h.ik); take(*r, *proof[0]); take(*r, *proof[1]); take(*r, *h.spk);
	h.pqpk = r;
	return h, keys.verify_proof(h.root, .Exchange, h.ik, proof);
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
accept :: (me: Identity, hello: Hello, dm: Dm, first: []u8, out: *Packet) -> Session, bool {
	s: Session;
	if same(hello.root, me.root) return s, false; // Our own Hello reflected back.
	ek_priv, ek_pub := crypto.x25519_generate();
	defer crypto.zero(*ek_priv);
	dh1, ok1 := crypto.x25519(me.ik_priv, hello.spk);
	dh2, ok2 := crypto.x25519(ek_priv, hello.ik);
	dh3, ok3 := crypto.x25519(ek_priv, hello.spk);
	ct, ss, ok4 := crypto.mlkem768_encap(hello.pqpk);
	if !(ok1 && ok2 && ok3 && ok4) return s, false;
	sk := pqxdh_kdf(dh1, dh2, dh3, ss, dm);
	defer crypto.zero(*sk);

	out.count = 0;
	put(out, .[VERSION, xx Kind.Init]);
	put(out, hello.id); put(out, me.root); put(out, me.ik_pub); put(out, me.proof[0]); put(out, me.proof[1]);
	put(out, ek_pub); put(out, ct);
	assert(out.count == INIT_PREFIX_BYTES);
	s.id = session_id(bytes(out));
	set_ad(*s, me.root, me.ik_pub, hello.root, hello.ik, dm);

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
receive_init :: (me: Identity, pre: Prekeys, i: Init, dm: Dm) -> Session, bool {
	s: Session;
	if same(i.root, me.root) return s, false;
	dh1, ok1 := crypto.x25519(pre.spk_priv, i.ik);
	dh2, ok2 := crypto.x25519(me.ik_priv, i.ek);
	dh3, ok3 := crypto.x25519(pre.spk_priv, i.ek);
	ss, ok4 := crypto.mlkem768_decap(pre.pq_seed, i.pqct);
	if !(ok1 && ok2 && ok3 && ok4) return s, false;
	sk := pqxdh_kdf(dh1, dh2, dh3, ss, dm);
	defer crypto.zero(*sk);
	s.id = i.session;
	set_ad(*s, i.root, i.ik, me.root, me.ik_pub, dm);
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
	if !r.has_cks || out.count + HEADER_BYTES + pt.count + TAG_BYTES > MAX_PACKET return false;
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

B64 :: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
B64_INV :: #run b64_inverse();
b64_inverse :: () -> [256]u8 {
	t: [256]u8;
	for *t it.* = 0xFF;
	for i: 0..B64.count-1 t[B64[i]] = xx i;
	return t;
}

PQXDH_INFO :: "fastcord_PQXDH_X25519_SHA-256_ML-KEM-768";
RK_INFO :: "fastcord_DoubleRatchet_RootKey";
MK_INFO :: "fastcord_DoubleRatchet_MessageKey";

put :: (p: *Packet, b: []u8) {
	assert(p.count + b.count <= MAX_PACKET);
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

dm_bytes :: (dm: Dm) -> [24]u8 {
	b: [24]u8;
	for v, k: u64.[dm.channel, dm.alice, dm.bob] for 0..7 b[k * 8 + it] = xx ((v >> (it * 8)) & 0xFF);
	return b;
}

set_ad :: (s: *Session, root_a: [32]u8, ik_a: [32]u8, root_b: [32]u8, ik_b: [32]u8, dm: Dm) {
	memcpy(s.ad.data, root_a.data, 32);
	memcpy(s.ad.data + 32, ik_a.data, 32);
	memcpy(s.ad.data + 64, root_b.data, 32);
	memcpy(s.ad.data + 96, ik_b.data, 32);
	d := dm_bytes(dm);
	memcpy(s.ad.data + 128, d.data, 24);
}

// PQXDH section 2.2: HKDF over F || KM with F = 32 0xFF bytes for X25519 and a zero salt. The info
// names the DM too, so the shared secret itself differs for any other DM.
pqxdh_kdf :: (dh1: [32]u8, dh2: [32]u8, dh3: [32]u8, ss: [32]u8, dm: Dm) -> [32]u8 {
	km: [32 * 5]u8;
	memset(km.data, 0xFF, 32);
	memcpy(km.data + 32, dh1.data, 32);
	memcpy(km.data + 64, dh2.data, 32);
	memcpy(km.data + 96, dh3.data, 32);
	memcpy(km.data + 128, ss.data, 32);
	zero_salt: [32]u8;
	prk := crypto.hkdf_extract(zero_salt, km);
	info: [PQXDH_INFO.count + 24]u8;
	memcpy(info.data, PQXDH_INFO.data, PQXDH_INFO.count);
	d := dm_bytes(dm);
	memcpy(info.data + PQXDH_INFO.count, d.data, 24);
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
