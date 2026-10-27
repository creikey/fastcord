// Displayable codes (DAVE "Displayable Codes"): groups of group_size bytes
// read big-endian, mod 10^group_size, zero padded.
displayable_code :: (data: []u8, desired_len: int, group_size: int, allocator := context.allocator) -> string, bool {
	if len(data) < desired_len || desired_len % group_size != 0 || group_size > 8 { return "", false; }
	b := strings.builder_make(0, desired_len, allocator);
	modulus: u64 = 1;
	for _: 0..group_size-1 { modulus *= 10; }
	{ i := 0;
	while i < desired_len {
		v: u64 = 0;
		for j: 0..group_size-1 { v = (v << 8) | (cast(u64)(data[i + j])); }
		v %= modulus;
		digits: [8]u8;
		{ k := group_size - 1;
		while k >= 0 {
			digits[k] = #char "0" + cast(u8)(v % 10);
			v /= 10;
			k -= 1;
} }
		strings.write_bytes(*b, sub(digits, 0, group_size));
		i += group_size;
} }
	return strings.to_string(b), true;
}

// format_code inserts a space every group characters ("12345 67890 ...").
format_code :: (code: string, group := 5, allocator := context.allocator) -> string {
	b := strings.builder_make(0, len(code) + len(code) / group, allocator);
	{ i := 0;
	while i < len(code) {
		if i > 0 { strings.write_byte(*b, #char " "); }
		strings.write_string(*b, sub(code, i, min(i + group, len(code))));
		i += group;
} }
	return strings.to_string(b);
}

// privacy_code: 30-digit voice privacy code from the epoch authenticator.
privacy_code :: (epoch_authenticator: []u8, allocator := context.allocator) -> string, bool {
	{ __r1, __r2 := displayable_code(epoch_authenticator, 30, 5, allocator); return __r1, __r2; }
}

FINGERPRINT_SALT :: u8.[0x24, 0xca, 0xb1, 0x7a, 0x7a, 0xf8, 0xec, 0x2b, 0x82, 0xb4, 0x12, 0xb9, 0x2d, 0xab, 0x19, 0x2e];

// pairwise_fingerprint (DAVE "Verification Fingerprint"), 64 bytes:
// scrypt(sort(V||PubA||Sa, V||PubB||Sb), salt, N=16384, r=8, p=2).
pairwise_fingerprint :: (local_user: u64, local_key: []u8, remote_user: u64, remote_key: []u8) -> [64]u8 {
	out: [64]u8;
	mk :: (key: []u8, uid: u64) -> []u8 {
		b := make_slice(u8, 2 + len(key) + 8, temp);
		copy(sub_from(b, 2), key);
		for i: 0..7 { b[2 + len(key) + i] = cast(u8)(uid >> (56 - 8 * cast(u64)(i))); }
		return b;
	}
	a := mk(local_key, local_user);
	b := mk(remote_key, remote_user);
	if less(b, a) { a, b = b, a; }
	pw := make_slice(u8, len(a) + len(b), temp);
	copy(pw, a);
	copy(sub_from(pw, len(a)), b);
	salt := FINGERPRINT_SALT;
	scrypt(pw, view(salt), 16384, 8, 2, view(out));
	return out;
}
#scope_module

less :: (a: []u8, b: []u8) -> bool {
	for i: 0..(min(len(a), len(b)))-1 { if a[i] != b[i] { return a[i] < b[i]; } }
	return len(a) < len(b);
}
#scope_export

// verification_code: 45-digit displayable pairwise fingerprint.
verification_code :: (fp: []u8, allocator := context.allocator) -> string, bool {
	{ __r3, __r4 := displayable_code(fp, 45, 5, allocator); return __r3, __r4; }
}
#scope_module

// ---------------------------------------------------------------------------
// scrypt (RFC 7914)

// ---------------------------------------------------------------------------
// scrypt (RFC 7914)

rotl :: inline (a: u32, k: u32) -> u32 #no_context {return (a << k) | (a >> (32 - k));};

quarter :: inline (x: *[16]u32, a: int, b: int, c: int, d: int) #no_context {
	x.*[b] ^= rotl(x.*[a] + x.*[d], 7);
	x.*[c] ^= rotl(x.*[b] + x.*[a], 9);
	x.*[d] ^= rotl(x.*[c] + x.*[b], 13);
	x.*[a] ^= rotl(x.*[d] + x.*[c], 18);
};

salsa20_8 :: (b: *[16]u32) {
	x := b.*;
	for _: 0..3 {
		quarter(*x, 0, 4, 8, 12);
		quarter(*x, 5, 9, 13, 1);
		quarter(*x, 10, 14, 2, 6);
		quarter(*x, 15, 3, 7, 11);
		quarter(*x, 0, 1, 2, 3);
		quarter(*x, 5, 6, 7, 4);
		quarter(*x, 10, 11, 8, 9);
		quarter(*x, 15, 12, 13, 14);
	}
	for i: 0..15 { b.*[i] += x[i]; }
}

block_mix :: (b: []u32, y: []u32, r: int) {
	// b, y: 32*r words
	x: [16]u32;
	copy(view(x), sub_from(b, (2 * r - 1) * 16));
	for i: 0..(2 * r)-1 {
		for j: 0..15 { x[j] ^= b[i * 16 + j]; }
		salsa20_8(*x);
		// even blocks to the first half, odd to the second
		dst := ifx i % 2 == 0 then (i / 2) * 16 else (r + i / 2) * 16;
		copy(sub(y, dst, dst + 16), view(x));
	}
}
#scope_export

scrypt :: (password: []u8, salt: []u8, n: int, r: int, p: int, dst: []u8) {
	blen := 128 * r;
	b := make_slice(u8, p * blen, temp);
	pbkdf2.derive(.SHA256, password, salt, 1, b);
	words := 32 * r;
	v := make_slice(u32, n * words);
	defer delete(v);
	x := make_slice(u32, words, temp);
	y := make_slice(u32, words, temp);
	for k: 0..p-1 {
		blk := sub(b, k * blen, (k + 1) * blen);
		for i: 0..words-1 { x[i] = (cast(u32)(blk[4 * i])) | ((cast(u32)(blk[4 * i + 1])) << 8) | ((cast(u32)(blk[4 * i + 2])) << 16) | ((cast(u32)(blk[4 * i + 3])) << 24); }
		for i: 0..n-1 {
			copy(sub_from(v, i * words), x);
			block_mix(x, y, r);
			x, y = y, x;
		}
		for _: 0..n-1 {
			j := (cast(int)(x[(2 * r - 1) * 16])) & (n - 1);
			for t: 0..words-1 { x[t] ^= v[j * words + t]; }
			block_mix(x, y, r);
			x, y = y, x;
		}
		for i: 0..words-1 {
			blk[4 * i] = cast(u8)(x[i]);
			blk[4 * i + 1] = cast(u8)(x[i] >> 8);
			blk[4 * i + 2] = cast(u8)(x[i] >> 16);
			blk[4 * i + 3] = cast(u8)(x[i] >> 24);
		}
	}
	pbkdf2.derive(.SHA256, password, b, 1, dst);
	mem.zero_slice(b);
}

