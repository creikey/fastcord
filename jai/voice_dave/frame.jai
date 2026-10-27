MAGIC_MARKER :: cast(u16)(0xFAFA);
TAG_SIZE :: 8;
MIN_SUPPLEMENTAL :: TAG_SIZE + 1 + 1 + 2; // tag, 1-byte nonce, size, marker
KEY_SIZE :: 16;
RATCHET_RETENTION_MS :: 10_000; // previous keys kept for in-flight media
EXPORT_LABEL :: "Discord Secure Frames v0";

// Opus silence frame the SFU may synthesize; always allowed through.
OPUS_SILENCE :: u8.[0xF8, 0xFF, 0xFE];

// ---------------------------------------------------------------------------
// ULEB128

uleb_put :: (buf: []u8, v: u64) -> int {
	x := v;
	n := 0;
	while x >= 0x80 {
		buf[n] = 0x80 | cast(u8)(x & 0x7f);
		n += 1;
		x >>= 7;
	}
	buf[n] = cast(u8)(x);
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

uleb_get :: (b: []u8) -> u64, int, bool {
	v: u64;
	n: int;
	ok: bool;
	shift: u64 = 0;
	for i: 0..len(b)-1 {
		if shift >= 64 { return 0, 0, false; }
		c := b[i];
		v |= cast(u64)(c & 0x7f) << shift;
		if c & 0x80 == 0 { return v, i + 1, true; }
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
	keys: [..][KEY_SIZE]u8; // keys[g - first_gen]
	first_gen: u32;
}

ratchet_init :: (r: *Ratchet, base: []u8, allocator := context.allocator) {
	r.* = .{};
	copy(view(r.next_secret), base);
	r.base_len = len(base);
	r.keys = make_dynamic([KEY_SIZE]u8, 0, 2, allocator);
}

ratchet_destroy :: (r: *Ratchet) {
	crypto.zero_explicit(*r.next_secret, size_of(r.next_secret));
	delete(r.keys);
}

ratchet_get :: (r: *Ratchet, gen: u32) -> [KEY_SIZE]u8, bool {
	key: [KEY_SIZE]u8;
	ok: bool;
	if gen < r.first_gen { return key, ok; }
	if gen - r.first_gen > 255 && gen >= r.next_gen { return key, ok; } // refuse absurd jumps
	while r.next_gen <= gen {
		s := sub(r.next_secret, 0, r.base_len);
		k: [KEY_SIZE]u8;
		mls.derive_tree_secret(s, "key", r.next_gen, view(k));
		ns: mls.Secret;
		mls.derive_tree_secret(s, "secret", r.next_gen, view(ns));
		r.next_secret = ns;
		r.base_len = mls.NH;
		append(*r.keys, k);
		r.next_gen += 1;
	}
	return r.keys[gen - r.first_gen], true;
}
#scope_module

// ---------------------------------------------------------------------------
// AES-128-GCM with 64-bit truncated tags and the 32-bit truncated nonce
// expanded to 96 bits (zero || nonce as little-endian u32).

full_nonce :: (truncated: u32) -> [12]u8 {
	n: [12]u8;
	n[8] = cast(u8)(truncated);
	n[9] = cast(u8)(truncated >> 8);
	n[10] = cast(u8)(truncated >> 16);
	n[11] = cast(u8)(truncated >> 24);
	return n;
}
#scope_export

gcm_seal_truncated :: (key: []u8, nonce: u32, aad: []u8, pt: []u8, ct_out: []u8, tag_out: []u8) {
	ctx: aes.Context_GCM;
	aes.init_gcm(*ctx, key);
	defer aes.reset_gcm(*ctx);
	iv := full_nonce(nonce);
	tag: [16]u8;
	aes.seal_gcm(*ctx, ct_out, view(tag), view(iv), aad, pt);
	copy(tag_out, sub(tag, 0, TAG_SIZE));
}

gcm_open_truncated :: (key: []u8, nonce: u32, aad: []u8, ct: []u8, tag: []u8, pt_out: []u8) -> bool {
	iv := full_nonce(nonce);
	// CTR starts at J0 + 1 = iv || 00000002
	ctr_iv: [16]u8;
	copy(view(ctr_iv), view(iv));
	ctr_iv[15] = 2;
	cctx: aes.Context_CTR;
	aes.init_ctr(*cctx, key, view(ctr_iv));
	aes.xor_bytes_ctr(*cctx, pt_out, ct);
	aes.reset_ctr(*cctx);
	// recompute the tag over the ciphertext by re-sealing the plaintext
	ctx: aes.Context_GCM;
	aes.init_gcm(*ctx, key);
	defer aes.reset_gcm(*ctx);
	scratch := make_slice(u8, len(pt_out), temp);
	full: [16]u8;
	aes.seal_gcm(*ctx, scratch, view(full), view(iv), aad, pt_out);
	if crypto.compare_constant_time(sub(full, 0, TAG_SIZE), tag) != 1 {
		crypto.zero_explicit(raw_data(pt_out), len(pt_out));
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
	ok: bool;
	n := len(frame);
	if n < MIN_SUPPLEMENTAL { return p, ok; }
	if cast(u16)(frame[n - 2]) << 8 | cast(u16)(frame[n - 1]) != MAGIC_MARKER { return p, ok; }
	supp := cast(int)(frame[n - 3]);
	if supp < MIN_SUPPLEMENTAL || supp > n { return p, ok; }
	body_end := n - supp;
	p.interleaved = sub(frame, 0, body_end);
	p.tag = sub(frame, body_end, body_end + TAG_SIZE);
	meta := sub(frame, body_end + TAG_SIZE, n - 3);
	nonce, used, __e1 := uleb_get(meta); if failed(__e1) return p, __e1;
	if nonce > cast(u64)(U32_MAX) { return p, ok; }
	p.nonce = cast(u32)(nonce);
	meta = sub_from(meta, used);
	last_end := 0;
	while len(meta) > 0 {
		off, a, __e2 := uleb_get(meta); if failed(__e2) return p, __e2;
		meta = sub_from(meta, a);
		sz, b, __e3 := uleb_get(meta); if failed(__e3) return p, __e3;
		meta = sub_from(meta, b);
		if p.n_ranges == len(p.ranges) { return p, ok; }
		if cast(int)(off) < last_end || off + sz > cast(u64)(len(p.interleaved)) { return p, ok; }
		p.ranges[p.n_ranges] = Range.{cast(int)(off), cast(int)(sz)};
		p.n_ranges += 1;
		last_end = cast(int)(off + sz);
	}
	return p, true;
}

// encrypt_opus_frame: whole Opus frame encrypted (no unencrypted ranges).
// out must hold len(frame) + supplemental_size(nonce).
supplemental_size :: (nonce: u32) -> int {return TAG_SIZE + uleb_size(cast(u64)(nonce)) + 1 + 2;}

encrypt_opus_frame :: (key: []u8, nonce: u32, frame: []u8, out: []u8) -> int {
	n := len(frame);
	ss := supplemental_size(nonce);
	assert(len(out) >= n + ss);
	gcm_seal_truncated(key, nonce, null, frame, sub(out, 0, n), sub(out, n, n + TAG_SIZE));
	pos := n + TAG_SIZE;
	pos += uleb_put(sub_from(out, pos), cast(u64)(nonce));
	at(*out, pos).* = cast(u8)(ss);
	at(*out, pos + 1).* = 0xFA;
	at(*out, pos + 2).* = 0xFA;
	return pos + 3;
}

// decrypt_frame: codec-agnostic receive path. pt_out must be >= len(p.interleaved).
decrypt_frame :: (key: []u8, p: *Parsed_Frame, pt_out: []u8) -> int, bool {
	n: int;
	ok: bool;
	body := p.interleaved;
	if p.n_ranges == 0 {
		if !gcm_open_truncated(key, p.nonce, null, body, p.tag, sub(pt_out, 0, len(body))) { return n, ok; }
		return len(body), true;
	}
	// split into aad (unencrypted ranges joined) and ciphertext (the rest)
	aad := make_dynamic(u8, 0, len(body), temp);
	ct := make_dynamic(u8, 0, len(body), temp);
	pos := 0;
	for i: 0..p.n_ranges-1 {
		r := p.ranges[i];
		append(*ct, ..sub(body, pos, r.offset));
		append(*aad, ..sub(body, r.offset, r.offset + r.size));
		pos = r.offset + r.size;
	}
	append(*ct, ..sub_from(body, pos));
	pt := make_slice(u8, len(ct), temp);
	if !gcm_open_truncated(key, p.nonce, view(aad), view(ct), p.tag, pt) { return n, ok; }
	// re-interleave
	pos = 0;
	cpos := 0;
	for i: 0..p.n_ranges-1 {
		r := p.ranges[i];
		k := r.offset - pos;
		copy(sub_from(pt_out, pos), sub(pt, cpos, cpos + k));
		cpos += k;
		copy(sub_from(pt_out, r.offset), sub(body, r.offset, r.offset + r.size));
		pos = r.offset + r.size;
	}
	copy(sub_from(pt_out, pos), sub_from(pt, cpos));
	return len(body), true;
}

// ---------------------------------------------------------------------------
// Replay window per (cryptor): accept each nonce once.

Replay_Window :: struct {
	highest: u32;
	bits: u64; // bit i => highest - i seen
	any: bool;
}

replay_check :: (w: *Replay_Window, nonce: u32) -> bool {
	if !w.any { return true; }
	if nonce > w.highest { return true; }
	d := w.highest - nonce;
	if d >= 64 { return false; }
	return w.bits & (cast(u64)(1) << d) == 0;
}

replay_mark :: (w: *Replay_Window, nonce: u32) {
	if !w.any {
		w.any = true;
		w.highest = nonce;
		w.bits = 1;
		return;
	}
	if nonce > w.highest {
		shift := nonce - w.highest;
		w.bits = ifx shift < 64 then (w.bits << shift) else 0;
		w.bits |= 1;
		w.highest = nonce;
	} else {
		w.bits |= cast(u64)(1) << (w.highest - nonce);
	}
}

