package quic

import "core:encoding/hex"
import "core:slice"
import "core:testing"

import "fc:tls"

@(private = "file")
unhex :: proc(s: string) -> []byte {
	b, _ := hex.decode(transmute([]byte)s)
	return b
}

@(private = "file")
expect_hex :: proc(t: ^testing.T, got: []byte, want: string, loc := #caller_location) {
	w := unhex(want)
	defer delete(w)
	testing.expectf(t, slice.equal(got, w), "got %x want %s", got, want, loc = loc)
}

// RFC 9001 Appendix A.1: keys from DCID 0x8394c8f03e515708.
@(test)
rfc9001_initial_keys :: proc(t: ^testing.T) {
	dcid := unhex("8394c8f03e515708")
	defer delete(dcid)
	c, s: Keys
	initial_keys(&c, &s, dcid)
	defer keys_clear(&c)
	defer keys_clear(&s)
	expect_hex(t, c.secret[:32], "c00cf151ca5be075ed0ebfb5c80323c42d6b7db67881289af4008f1f6c357aea")
	expect_hex(t, c.iv[:], "fa044b2f42a3fd3b46fb255c")
	expect_hex(t, s.secret[:32], "3c199828fd139efd216c155ad844cc81fb82fa8d7446fa7d78be803acdda951b")
	expect_hex(t, s.iv[:], "0ac1493ca1905853b0bba03e")
	// A.2: header protection mask from the client Initial's sample.
	sample := unhex("d1b1c98dd7689fb8ec11d242b123dc9b")
	defer delete(sample)
	mask := hp_mask(&c, sample)
	expect_hex(t, mask[:], "437b9aec36")
}

// RFC 9001 Appendix A.5: ChaCha20-Poly1305 short header packet.
@(test)
rfc9001_chacha_short_header :: proc(t: ^testing.T) {
	secret := unhex("9ac312a7f877468ebe69422748ad00a15443f18203a07d6060f688f30f21632b")
	defer delete(secret)
	k: Keys
	keys_set(&k, tls.SUITES[2], secret)
	defer keys_clear(&k)
	expect_hex(t, k.iv[:], "e0459b3474bdd0e44a41c144")
	expect_hex(t, k.hp_chacha[:], "25a282b9e82f06f21f488917a4fc8f1b73573685608597d0efcb076b0ab7a7a4")
	// pn 654360564 encoded in 3 bytes; header 4200bff4, payload 01.
	pkt := [?]byte{0x42, 0x00, 0xbf, 0xf4, 0x01, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}
	seal(&k, pkt[:], 4, 1, 3, 654360564)
	expect_hex(t, pkt[:], "4cfe4189655e5cd55c41f69080575d7999c25a5bfb")

	// And back.
	trunc, pn_len, ok := unprotect_header(&k, pkt[:], 1)
	testing.expect(t, ok)
	pn := decode_pn(654360563, trunc, pn_len)
	testing.expect_value(t, pn, 654360564)
	pt, ok2 := open(&k, pkt[:], 1 + pn_len, pn)
	testing.expect(t, ok2 && slice.equal(pt, []byte{1}))
}

@(test)
decode_pn_rfc9000_example :: proc(t: ^testing.T) {
	// RFC 9000 A.3: largest 0xa82f30ea, truncated 0x9b32 (16 bits) -> 0xa82f9b32.
	testing.expect_value(t, decode_pn(0xa82f30ea, 0x9b32, 2), 0xa82f9b32)
}

@(test)
varints :: proc(t: ^testing.T) {
	// RFC 9000 A.1 examples.
	cases := [?]struct {
		hex: string,
		v:   u64,
	}{{"c2197c5eff14e88c", 151288809941952652}, {"9d7f3e7d", 494878333}, {"7bbd", 15293}, {"25", 37}, {"4025", 37}}
	for c in cases {
		b := unhex(c.hex)
		defer delete(b)
		r := reader(b)
		testing.expect_value(t, r_varint(&r), c.v)
		testing.expect(t, r_done(&r))
	}
	out: [dynamic]byte
	defer delete(out)
	put_varint(&out, 151288809941952652)
	expect_hex(t, out[:], "c2197c5eff14e88c")
}
