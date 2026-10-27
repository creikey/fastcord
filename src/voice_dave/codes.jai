// Displayable codes (DAVE "Displayable Codes"): groups of group_size bytes
// read big-endian, mod 10^group_size, zero padded. The string is in context.allocator.
displayable_code :: (data: []u8, desired_len: int, group_size: int) -> string, bool {
	if data.count < desired_len || desired_len % group_size != 0 || group_size > 8 return "", false;
	out := alloc_string(desired_len);
	modulus: u64 = 1;
	for 1..group_size modulus *= 10;
	for i: 0..desired_len / group_size - 1 {
		v: u64 = 0;
		for j: 0..group_size-1 v = (v << 8) | data[i * group_size + j];
		v %= modulus;
		for < k: 0..group_size-1 {
			out[i * group_size + k] = #char "0" + cast(u8) (v % 10);
			v /= 10;
		}
	}
	return out, true;
}

// format_code inserts a space every group characters ("12345 67890 ...").
format_code :: (code: string, group := 5) -> string {
	b: String_Builder;
	for i: 0..(code.count + group - 1) / group - 1 {
		if i > 0 append(*b, #char " ");
		append(*b, slice(code, i * group, group));
	}
	return builder_to_string(*b);
}

// privacy_code: 30-digit voice privacy code from the epoch authenticator.
privacy_code :: (epoch_authenticator: []u8) -> string, bool {
	s, ok := displayable_code(epoch_authenticator, 30, 5);
	return s, ok;
}

// verification_code: 45-digit displayable pairwise fingerprint.
verification_code :: (fp: []u8) -> string, bool {
	s, ok := displayable_code(fp, 45, 5);
	return s, ok;
}

FINGERPRINT_SALT :: u8.[0x24, 0xca, 0xb1, 0x7a, 0x7a, 0xf8, 0xec, 0x2b, 0x82, 0xb4, 0x12, 0xb9, 0x2d, 0xab, 0x19, 0x2e];

// pairwise_fingerprint (DAVE "Verification Fingerprint"), 64 bytes:
// scrypt(sort(V||PubA||Sa, V||PubB||Sb), salt, N=16384, r=8, p=2).
pairwise_fingerprint :: (local_user: u64, local_key: []u8, remote_user: u64, remote_key: []u8) -> [64]u8 {
	// version 0 (2 bytes) || public key || big-endian user id
	mk :: (key: []u8, uid: u64) -> string {
		b := talloc_string(2 + key.count + 8);
		memset(b.data, 0, 2);
		memcpy(b.data + 2, key.data, key.count);
		for i: 0..7 b[2 + key.count + i] = cast(u8) (uid >> (56 - 8 * cast(u64) i));
		return b;
	}
	a := mk(local_key, local_user);
	b := mk(remote_key, remote_user);
	if compare(b, a) < 0 a, b = b, a;
	out: [64]u8;
	scrypt(cast([]u8) join(a, b,, temp), FINGERPRINT_SALT, 16384, 8, 2, out);
	return out;
}

// ---------------------------------------------------------------------------
// scrypt (RFC 7914)

scrypt :: (password: []u8, salt: []u8, n: int, r: int, p: int, dst: []u8) {
	rotl :: inline (a: u32, k: u32) -> u32 { return (a << k) | (a >> (32 - k)); }
	quarter :: inline (x: *[16]u32, a: int, b: int, c: int, d: int) {
		x.*[b] ^= rotl(x.*[a] + x.*[d], 7);
		x.*[c] ^= rotl(x.*[b] + x.*[a], 9);
		x.*[d] ^= rotl(x.*[c] + x.*[b], 13);
		x.*[a] ^= rotl(x.*[d] + x.*[c], 18);
	}
	salsa20_8 :: (b: *[16]u32) {
		x := b.*;
		for 1..4 {
			quarter(*x, 0, 4, 8, 12);
			quarter(*x, 5, 9, 13, 1);
			quarter(*x, 10, 14, 2, 6);
			quarter(*x, 15, 3, 7, 11);
			quarter(*x, 0, 1, 2, 3);
			quarter(*x, 5, 6, 7, 4);
			quarter(*x, 10, 11, 8, 9);
			quarter(*x, 15, 12, 13, 14);
		}
		for i: 0..15 b.*[i] += x[i];
	}
	// block_mix: b, y hold 32*r words; even blocks go to the first half of y, odd to the second.
	block_mix :: (b: []u32, y: []u32, r: int) {
		x: [16]u32;
		memcpy(x.data, b.data + (2 * r - 1) * 16, 64);
		for i: 0..2 * r - 1 {
			for j: 0..15 x[j] ^= b[i * 16 + j];
			salsa20_8(*x);
			dst := ifx i % 2 == 0 then (i / 2) * 16 else (r + i / 2) * 16;
			memcpy(y.data + dst, x.data, 64);
		}
	}

	blen := 128 * r;
	b := NewArray(p * blen, u8,, temp);
	crypto.pbkdf2_sha256(password, salt, 1, b);
	words := 32 * r;
	v := NewArray(n * words, u32, false);
	defer array_free(v);
	x := NewArray(words, u32, false,, temp);
	y := NewArray(words, u32, false,, temp);
	for k: 0..p-1 {
		blk := array_view(b, k * blen, blen);
		for i: 0..words-1 x[i] = (cast(u32) blk[4*i]) | ((cast(u32) blk[4*i+1]) << 8) | ((cast(u32) blk[4*i+2]) << 16) | ((cast(u32) blk[4*i+3]) << 24);
		for i: 0..n-1 {
			memcpy(v.data + i * words, x.data, words * 4);
			block_mix(x, y, r);
			x, y = y, x;
		}
		for 1..n {
			j := (cast(int) x[(2 * r - 1) * 16]) & (n - 1);
			for t: 0..words-1 x[t] ^= v[j * words + t];
			block_mix(x, y, r);
			x, y = y, x;
		}
		for i: 0..words-1 {
			blk[4*i]   = cast(u8) x[i];
			blk[4*i+1] = cast(u8) (x[i] >> 8);
			blk[4*i+2] = cast(u8) (x[i] >> 16);
			blk[4*i+3] = cast(u8) (x[i] >> 24);
		}
	}
	crypto.pbkdf2_sha256(password, b, 1, dst);
	crypto.zero(b);
}
