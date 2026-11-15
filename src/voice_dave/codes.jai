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
	ok := crypto.scrypt(cast([]u8) join(a, b,, temp), FINGERPRINT_SALT, 16384, 8, 2, out);
	assert(ok);
	return out;
}
