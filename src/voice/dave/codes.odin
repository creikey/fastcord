package dave

import "core:crypto/pbkdf2"
import "core:mem"
import "core:strings"

// Displayable codes (DAVE "Displayable Codes"): groups of group_size bytes
// read big-endian, mod 10^group_size, zero padded.
displayable_code :: proc(data: []byte, desired_len, group_size: int, allocator := context.allocator) -> (string, bool) {
	if len(data) < desired_len || desired_len % group_size != 0 || group_size > 8 do return "", false
	b := strings.builder_make(0, desired_len, allocator)
	modulus: u64 = 1
	for _ in 0 ..< group_size do modulus *= 10
	for i := 0; i < desired_len; i += group_size {
		v: u64 = 0
		for j in 0 ..< group_size do v = v << 8 | u64(data[i + j])
		v %= modulus
		digits: [8]byte
		for k := group_size - 1; k >= 0; k -= 1 {
			digits[k] = '0' + u8(v % 10)
			v /= 10
		}
		strings.write_bytes(&b, digits[:group_size])
	}
	return strings.to_string(b), true
}

// format_code inserts a space every group characters ("12345 67890 ...").
format_code :: proc(code: string, group := 5, allocator := context.allocator) -> string {
	b := strings.builder_make(0, len(code) + len(code) / group, allocator)
	for i := 0; i < len(code); i += group {
		if i > 0 do strings.write_byte(&b, ' ')
		strings.write_string(&b, code[i:min(i + group, len(code))])
	}
	return strings.to_string(b)
}

// privacy_code: 30-digit voice privacy code from the epoch authenticator.
privacy_code :: proc(epoch_authenticator: []byte, allocator := context.allocator) -> (string, bool) {
	return displayable_code(epoch_authenticator, 30, 5, allocator)
}

FINGERPRINT_SALT :: [16]byte{0x24, 0xca, 0xb1, 0x7a, 0x7a, 0xf8, 0xec, 0x2b, 0x82, 0xb4, 0x12, 0xb9, 0x2d, 0xab, 0x19, 0x2e}

// pairwise_fingerprint (DAVE "Verification Fingerprint"), 64 bytes:
// scrypt(sort(V||PubA||Sa, V||PubB||Sb), salt, N=16384, r=8, p=2).
pairwise_fingerprint :: proc(local_user: u64, local_key: []byte, remote_user: u64, remote_key: []byte) -> (out: [64]byte) {
	mk :: proc(key: []byte, uid: u64) -> []byte {
		b := make([]byte, 2 + len(key) + 8, context.temp_allocator)
		copy(b[2:], key)
		for i in 0 ..< 8 do b[2 + len(key) + i] = u8(uid >> (56 - 8 * uint(i)))
		return b
	}
	a := mk(local_key, local_user)
	b := mk(remote_key, remote_user)
	if less(b, a) do a, b = b, a
	pw := make([]byte, len(a) + len(b), context.temp_allocator)
	copy(pw, a)
	copy(pw[len(a):], b)
	salt := FINGERPRINT_SALT
	scrypt(pw, salt[:], 16384, 8, 2, out[:])
	return
}

@(private)
less :: proc(a, b: []byte) -> bool {
	for i in 0 ..< min(len(a), len(b)) do if a[i] != b[i] do return a[i] < b[i]
	return len(a) < len(b)
}

// verification_code: 45-digit displayable pairwise fingerprint.
verification_code :: proc(fp: []byte, allocator := context.allocator) -> (string, bool) {
	return displayable_code(fp, 45, 5, allocator)
}

// ---------------------------------------------------------------------------
// scrypt (RFC 7914)

@(private)
rotl :: #force_inline proc "contextless" (a: u32, k: u32) -> u32 {return (a << k) | (a >> (32 - k))}

@(private)
quarter :: #force_inline proc "contextless" (x: ^[16]u32, a, b, c, d: int) {
	x[b] ~= rotl(x[a] + x[d], 7)
	x[c] ~= rotl(x[b] + x[a], 9)
	x[d] ~= rotl(x[c] + x[b], 13)
	x[a] ~= rotl(x[d] + x[c], 18)
}

@(private)
salsa20_8 :: proc(b: ^[16]u32) {
	x := b^
	for _ in 0 ..< 4 {
		quarter(&x, 0, 4, 8, 12)
		quarter(&x, 5, 9, 13, 1)
		quarter(&x, 10, 14, 2, 6)
		quarter(&x, 15, 3, 7, 11)
		quarter(&x, 0, 1, 2, 3)
		quarter(&x, 5, 6, 7, 4)
		quarter(&x, 10, 11, 8, 9)
		quarter(&x, 15, 12, 13, 14)
	}
	for i in 0 ..< 16 do b[i] += x[i]
}

@(private)
block_mix :: proc(b: []u32, y: []u32, r: int) {
	// b, y: 32*r words
	x: [16]u32
	copy(x[:], b[(2 * r - 1) * 16:])
	for i in 0 ..< 2 * r {
		for j in 0 ..< 16 do x[j] ~= b[i * 16 + j]
		salsa20_8(&x)
		// even blocks to the first half, odd to the second
		dst := (i / 2) * 16 if i % 2 == 0 else (r + i / 2) * 16
		copy(y[dst:dst + 16], x[:])
	}
}

scrypt :: proc(password, salt: []byte, n, r, p: int, dst: []byte) {
	blen := 128 * r
	b := make([]byte, p * blen, context.temp_allocator)
	pbkdf2.derive(.SHA256, password, salt, 1, b)
	words := 32 * r
	v := make([]u32, n * words)
	defer delete(v)
	x := make([]u32, words, context.temp_allocator)
	y := make([]u32, words, context.temp_allocator)
	for k in 0 ..< p {
		blk := b[k * blen:(k + 1) * blen]
		for i in 0 ..< words do x[i] = u32(blk[4 * i]) | u32(blk[4 * i + 1]) << 8 | u32(blk[4 * i + 2]) << 16 | u32(blk[4 * i + 3]) << 24
		for i in 0 ..< n {
			copy(v[i * words:], x)
			block_mix(x, y, r)
			x, y = y, x
		}
		for _ in 0 ..< n {
			j := int(x[(2 * r - 1) * 16]) & (n - 1)
			for t in 0 ..< words do x[t] ~= v[j * words + t]
			block_mix(x, y, r)
			x, y = y, x
		}
		for i in 0 ..< words {
			blk[4 * i] = u8(x[i])
			blk[4 * i + 1] = u8(x[i] >> 8)
			blk[4 * i + 2] = u8(x[i] >> 16)
			blk[4 * i + 3] = u8(x[i] >> 24)
		}
	}
	pbkdf2.derive(.SHA256, password, b, 1, dst)
	mem.zero_slice(b)
}
