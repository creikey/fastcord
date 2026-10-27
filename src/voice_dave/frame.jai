MAGIC_MARKER :: cast(u16) 0xFAFA;
TAG_SIZE :: 8;
MIN_SUPPLEMENTAL :: TAG_SIZE + 1 + 1 + 2; // tag, 1-byte nonce, size, marker
KEY_SIZE :: 16;
RATCHET_RETENTION_MS :: 10_000; // previous keys kept for in-flight media
EXPORT_LABEL :: "Discord Secure Frames v0";

// ---------------------------------------------------------------------------
// ULEB128

uleb_put :: (buf: []u8, v: u64) -> int {
	x := v;
	n := 0;
	while x >= 0x80 {
		buf[n] = 0x80 | (cast(u8) (x & 0x7f));
		n += 1;
		x >>= 7;
	}
	buf[n] = cast(u8) x;
	return n + 1;
}

uleb_size :: (v: u64) -> int {
	x := v;
	n := 1;
	while x >= 0x80 {
		x >>= 7;
		n += 1;
	}
	return n;
}

uleb_get :: (b: []u8) -> value: u64, used: int, ok: bool {
	v: u64;
	shift: u64 = 0;
	for c: b {
		if shift >= 64 return 0, 0, false;
		v |= (cast(u64) (c & 0x7f)) << shift;
		if (c & 0x80) == 0 return v, it_index + 1, true;
		shift += 7;
	}
	return 0, 0, false;
}

// ---------------------------------------------------------------------------
// Key ratchet: mlspp HashRatchet over the exported sender base secret
// (key = ExpandWithLabel(secret, "key", gen, 16), secret' = ExpandWithLabel(secret, "secret", gen, 32)).

Ratchet :: struct {
	next_gen: u32;
	next_secret: mls.Secret;
	base_len: int;
	keys: [..][KEY_SIZE]u8; // keys[g - first_gen], in the allocator current at ratchet_init
	first_gen: u32;
}

ratchet_init :: (r: *Ratchet, base: []u8) {
	r.* = .{};
	memcpy(r.next_secret.data, base.data, base.count);
	r.base_len = base.count;
	r.keys.allocator = context.allocator;
}

ratchet_destroy :: (r: *Ratchet) {
	crypto.zero(*r.next_secret);
	array_free(r.keys);
}

ratchet_get :: (r: *Ratchet, gen: u32) -> [KEY_SIZE]u8, bool {
	key: [KEY_SIZE]u8;
	if gen < r.first_gen return key, false;
	if gen - r.first_gen > 255 && gen >= r.next_gen return key, false; // refuse absurd jumps
	while r.next_gen <= gen {
		s := array_view(r.next_secret, 0, r.base_len);
		k: [KEY_SIZE]u8;
		mls.derive_tree_secret(s, "key", r.next_gen, k);
		ns: mls.Secret;
		mls.derive_tree_secret(s, "secret", r.next_gen, ns);
		r.next_secret = ns;
		r.base_len = mls.NH;
		array_add(*r.keys, k);
		r.next_gen += 1;
	}
	return r.keys[gen - r.first_gen], true;
}

// ---------------------------------------------------------------------------
// AES-128-GCM with 64-bit truncated tags and the 32-bit truncated nonce
// expanded to 96 bits (zero || nonce as little-endian u32).

full_nonce :: (truncated: u32) -> [12]u8 {
	n: [12]u8;
	n[8] = cast(u8) truncated;
	n[9] = cast(u8) (truncated >> 8);
	n[10] = cast(u8) (truncated >> 16);
	n[11] = cast(u8) (truncated >> 24);
	return n;
}

gcm_seal_truncated :: (key: []u8, nonce: u32, aad: []u8, pt: []u8, ct_out: []u8, tag_out: []u8) {
	a: crypto.Aead;
	crypto.aead_init(*a, .AES_GCM, key);
	defer crypto.aead_destroy(*a);
	iv := full_nonce(nonce);
	tag: [16]u8;
	crypto.seal(*a, ct_out, tag, iv, aad, pt);
	memcpy(tag_out.data, tag.data, TAG_SIZE);
}

// gcm_open_truncated: BoringSSL won't check an 8-byte GCM tag, so decrypt with
// AES-CTR and recompute the tag by sealing the plaintext again.
gcm_open_truncated :: (key: []u8, nonce: u32, aad: []u8, ct: []u8, tag: []u8, pt_out: []u8) -> bool {
	iv := full_nonce(nonce);
	// CTR starts at J0 + 1 = iv || 00000002
	ctr_iv: [16]u8;
	memcpy(ctr_iv.data, iv.data, 12);
	ctr_iv[15] = 2;
	crypto.aes_ctr(key, ctr_iv, ct, pt_out);
	a: crypto.Aead;
	crypto.aead_init(*a, .AES_GCM, key);
	defer crypto.aead_destroy(*a);
	scratch := NewArray(pt_out.count, u8, false,, temp);
	full: [16]u8;
	crypto.seal(*a, scratch, full, iv, aad, pt_out);
	if !crypto.constant_time_equal(array_view(full, 0, TAG_SIZE), tag) {
		crypto.zero(pt_out);
		return false;
	}
	return true;
}

// ---------------------------------------------------------------------------
// Protocol frames

Range :: struct {
	offset, size: int;
}

Parsed_Frame :: struct {
	interleaved: []u8; // frame bytes before the supplemental data
	tag: []u8;
	nonce: u32;
	ranges: [8]Range;
	n_ranges: int;
}

// parse_protocol_frame performs the protocol frame check.
parse_protocol_frame :: (frame: []u8) -> Parsed_Frame, bool {
	p: Parsed_Frame;
	n := frame.count;
	if n < MIN_SUPPLEMENTAL return p, false;
	if (((cast(u16) frame[n - 2]) << 8) | frame[n - 1]) != MAGIC_MARKER return p, false;
	supp := cast(int) frame[n - 3];
	if supp < MIN_SUPPLEMENTAL || supp > n return p, false;
	body_end := n - supp;
	p.interleaved = array_view(frame, 0, body_end);
	p.tag = array_view(frame, body_end, TAG_SIZE);
	meta := array_view(frame, body_end + TAG_SIZE, supp - TAG_SIZE - 3);
	nonce, used, ok := uleb_get(meta);
	if !ok || nonce > 0xFFFF_FFFF return p, false;
	p.nonce = cast(u32) nonce;
	meta = array_view(meta, used);
	last_end := 0;
	while meta.count > 0 {
		off, a, ok1 := uleb_get(meta);
		if !ok1 return p, false;
		meta = array_view(meta, a);
		sz, b, ok2 := uleb_get(meta);
		if !ok2 return p, false;
		meta = array_view(meta, b);
		if p.n_ranges == p.ranges.count return p, false;
		if cast(int) off < last_end || off + sz > cast(u64) p.interleaved.count return p, false;
		p.ranges[p.n_ranges] = .{cast(int) off, cast(int) sz};
		p.n_ranges += 1;
		last_end = cast(int) (off + sz);
	}
	return p, true;
}

// supplemental_size: what encrypt_opus_frame appends to a frame.
supplemental_size :: (nonce: u32) -> int { return TAG_SIZE + uleb_size(nonce) + 1 + 2; }

// encrypt_opus_frame: whole Opus frame encrypted (no unencrypted ranges).
// out must hold frame.count + supplemental_size(nonce).
encrypt_opus_frame :: (key: []u8, nonce: u32, frame: []u8, out: []u8) -> int {
	n := frame.count;
	ss := supplemental_size(nonce);
	assert(out.count >= n + ss);
	gcm_seal_truncated(key, nonce, .[], frame, array_view(out, 0, n), array_view(out, n, TAG_SIZE));
	pos := n + TAG_SIZE;
	pos += uleb_put(array_view(out, pos), nonce);
	out[pos] = cast(u8) ss;
	out[pos + 1] = 0xFA;
	out[pos + 2] = 0xFA;
	return pos + 3;
}

// decrypt_frame: codec-agnostic receive path. pt_out must hold p.interleaved.count.
decrypt_frame :: (key: []u8, p: *Parsed_Frame, pt_out: []u8) -> int, bool {
	body := p.interleaved;
	if p.n_ranges == 0 {
		if !gcm_open_truncated(key, p.nonce, .[], body, p.tag, array_view(pt_out, 0, body.count)) return 0, false;
		return body.count, true;
	}
	// split into aad (unencrypted ranges joined) and ciphertext (the rest)
	aad, ct: [..]u8;
	aad.allocator, ct.allocator = temp, temp;
	array_reserve(*aad, body.count);
	array_reserve(*ct, body.count);
	pos := 0;
	for r: array_view(p.ranges, 0, p.n_ranges) {
		array_add(*ct, ..array_view(body, pos, r.offset - pos));
		array_add(*aad, ..array_view(body, r.offset, r.size));
		pos = r.offset + r.size;
	}
	array_add(*ct, ..array_view(body, pos));
	pt := NewArray(ct.count, u8, false,, temp);
	if !gcm_open_truncated(key, p.nonce, aad, ct, p.tag, pt) return 0, false;
	// re-interleave
	pos = 0;
	cpos := 0;
	for r: array_view(p.ranges, 0, p.n_ranges) {
		k := r.offset - pos;
		memcpy(pt_out.data + pos, pt.data + cpos, k);
		cpos += k;
		memcpy(pt_out.data + r.offset, body.data + r.offset, r.size);
		pos = r.offset + r.size;
	}
	memcpy(pt_out.data + pos, pt.data + cpos, pt.count - cpos);
	return body.count, true;
}

// ---------------------------------------------------------------------------
// Replay window per (cryptor): accept each nonce once.

Replay_Window :: struct {
	highest: u32;
	bits: u64; // bit i => highest - i seen
	any: bool;
}

replay_check :: (w: *Replay_Window, nonce: u32) -> bool {
	if !w.any || nonce > w.highest return true;
	d := w.highest - nonce;
	if d >= 64 return false;
	return (w.bits & ((cast(u64) 1) << d)) == 0;
}

replay_mark :: (w: *Replay_Window, nonce: u32) {
	if !w.any {
		w.any = true;
		w.highest = nonce;
		w.bits = 1;
	} else if nonce > w.highest {
		shift := nonce - w.highest;
		w.bits = ifx shift < 64 then (w.bits << shift) else 0;
		w.bits |= 1;
		w.highest = nonce;
	} else {
		w.bits |= (cast(u64) 1) << (w.highest - nonce);
	}
}
