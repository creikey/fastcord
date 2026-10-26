package tls

import "core:crypto"
import "core:encoding/hex"
import "core:math/rand"
import "core:slice"
import "core:testing"

import "fc:netio"

@(private = "file")
unhex :: proc(s: string) -> []byte {
	b, _ := hex.decode(transmute([]byte)s)
	return b
}

// RFC 8448 section 3 (Simple 1-RTT Handshake), TLS_AES_128_GCM_SHA256.
@(test)
key_schedule_rfc8448 :: proc(t: ^testing.T) {
	suite := SUITES[0]
	shared := unhex("8bd4054fb55b9d63fdfbacf9f04b9f0d35e6d63f537563efd46272900f89492d")
	th := unhex("860c06edc07858ee8e78f0e7428c58edd6b43f2ca3e6e95f02ed063cf0e1cad8")
	defer delete(shared)
	defer delete(th)

	check :: proc(t: ^testing.T, got: []byte, want: string, loc := #caller_location) {
		w := unhex(want)
		defer delete(w)
		testing.expectf(t, slice.equal(got, w), "got %x want %s", got, want, loc = loc)
	}

	early, hs, master, c_hs, s_hs: [MAX_HASH]byte
	next_stage(suite, nil, nil, early[:])
	check(t, early[:32], "33ad0a1c607ec03b09e6cd9893680ce210adf300aa1f2660e1b22e10f170f92a")
	next_stage(suite, early[:32], shared, hs[:])
	check(t, hs[:32], "1dc826e93606aa6fdc0aadc12f741b01046aa6b99f691ed221a9f0ca043fbeac")
	derive_secret(suite, hs[:32], "c hs traffic", th, c_hs[:])
	check(t, c_hs[:32], "b3eddb126e067f35a780b3abf45e2d8f3b1a950738f52e9600746a0e27a55a21")
	derive_secret(suite, hs[:32], "s hs traffic", th, s_hs[:])
	check(t, s_hs[:32], "b67b7d690cc16c4e75e54213cb2d37b4e9c912bcded9105d42befd59d391ad38")
	next_stage(suite, hs[:32], nil, master[:])
	check(t, master[:32], "18df06843d13a08bf2a449844c5f8a478001bc4d4c627984d5a41da8d0402919")

	key: [16]byte
	iv: [12]byte
	expand_label(suite, s_hs[:32], "key", nil, key[:])
	expand_label(suite, s_hs[:32], "iv", nil, iv[:])
	check(t, key[:], "3fce516009c21727d0f2e4e86ee403bc")
	check(t, iv[:], "5d313eb2671276ee13000b30")
}

// Fake_Server replays canned bytes. If echo_sid is set, the first read builds a
// ServerHello that echoes the client's session id, with `mutate` random byte flips.
@(private = "file")
Fake_Server :: struct {
	input:    [dynamic]byte,
	pos:      int,
	written:  [dynamic]byte,
	echo_sid: bool,
	mutate:   int,
	extra:    []byte, // appended after the generated ServerHello
}

@(private = "file")
fake_read :: proc(data: rawptr, dst: []byte) -> (int, netio.Error) {
	f := cast(^Fake_Server)data
	if f.echo_sid && len(f.input) == 0 && len(f.written) > 76 {
		sid := f.written[5 + 4 + 2 + 32 + 1:][:32]
		sh: [dynamic]byte
		defer delete(sh)
		put_u16(&sh, 0x0303)
		rnd: [32]byte
		crypto.rand_bytes(rnd[:])
		put_bytes(&sh, rnd[:])
		put_u8(&sh, 32)
		put_bytes(&sh, sid)
		put_u16(&sh, 0x1301)
		put_u8(&sh, 0)
		el := begin_vec(&sh, 2)
		put_u16(&sh, EXT_SUPPORTED_VERSIONS)
		put_u16(&sh, 2)
		put_u16(&sh, 0x0304)
		put_u16(&sh, EXT_KEY_SHARE)
		put_u16(&sh, 36)
		put_u16(&sh, GROUP_X25519)
		put_u16(&sh, 32)
		pub: [32]byte
		pub[0] = 9 // the base point: a valid public key
		put_bytes(&sh, pub[:])
		end_vec(&sh, el, 2)
		put_u8(&f.input, CT_HANDSHAKE)
		put_u16(&f.input, 0x0303)
		put_u16(&f.input, u16(len(sh) + 4))
		put_u8(&f.input, HS_SERVER_HELLO)
		put_u24(&f.input, len(sh))
		put_bytes(&f.input, sh[:])
		for _ in 0 ..< f.mutate {
			i := rand.int_max(len(f.input))
			f.input[i] = byte(rand.uint32())
		}
		put_bytes(&f.input, f.extra)
	}
	if f.pos >= len(f.input) do return 0, .Closed
	// Dribble bytes out in small random chunks to exercise reassembly.
	n := min(len(dst), len(f.input) - f.pos, 1 + rand.int_max(64))
	copy(dst, f.input[f.pos:][:n])
	f.pos += n
	return n, .None
}

@(private = "file")
fake_write :: proc(data: rawptr, src: []byte) -> netio.Error {
	f := cast(^Fake_Server)data
	append(&f.written, ..src)
	return .None
}

@(private = "file")
fake_close :: proc(data: rawptr) {}

@(private = "file")
run_fake :: proc(f: ^Fake_Server) -> Error {
	under := netio.Stream{data = f, read = fake_read, write = fake_write, close = fake_close}
	s, err := connect(under, {alpn = {"h2", "http/1.1"}, server_name = "example.com"})
	if err == .None {
		close(s)
		return .None
	}
	return last_error()
}

@(private = "file")
fake_destroy :: proc(f: ^Fake_Server) {
	delete(f.input)
	delete(f.written)
}

@(test)
fails_cleanly_on_eof :: proc(t: ^testing.T) {
	f: Fake_Server
	defer fake_destroy(&f)
	testing.expect_value(t, run_fake(&f), Error.Closed)
	// The ClientHello went out in one 0x0301 record.
	testing.expect_value(t, f.written[0], CT_HANDSHAKE)
	testing.expect_value(t, f.written[2], 1)
}

@(test)
fails_cleanly_on_alert :: proc(t: ^testing.T) {
	f: Fake_Server
	defer fake_destroy(&f)
	append(&f.input, CT_ALERT, 3, 3, 0, 2, 2, ALERT_HANDSHAKE_FAILURE)
	testing.expect_value(t, run_fake(&f), Error.Alert_Received)
}

@(test)
rejects_tls12 :: proc(t: ^testing.T) {
	// A TLS 1.2 ServerHello: no supported_versions extension.
	f: Fake_Server
	defer fake_destroy(&f)
	body: [dynamic]byte
	defer delete(body)
	put_u16(&body, 0x0303)
	for _ in 0 ..< 32 do put_u8(&body, 7)
	put_u8(&body, 0)
	put_u16(&body, 0xc02f)
	put_u8(&body, 0)
	put_u16(&body, 0)
	put_u8(&f.input, CT_HANDSHAKE)
	put_u16(&f.input, 0x0303)
	put_u16(&f.input, u16(len(body) + 4))
	put_u8(&f.input, HS_SERVER_HELLO)
	put_u24(&f.input, len(body))
	put_bytes(&f.input, body[:])
	testing.expect_value(t, run_fake(&f), Error.Protocol_Version)
	// We answered with a protocol_version alert.
	w := f.written[:]
	testing.expect(t, len(w) >= 7 && slice.equal(w[len(w) - 7:], []byte{CT_ALERT, 3, 3, 0, 2, 2, ALERT_PROTOCOL_VERSION}))
}

@(test)
valid_server_hello_then_bad_record :: proc(t: ^testing.T) {
	// A ServerHello we accept, then garbage "encrypted" data: must be bad_record_mac.
	f: Fake_Server
	defer fake_destroy(&f)
	f.echo_sid = true
	junk := [?]byte{CT_APPLICATION_DATA, 3, 3, 0, 20, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20}
	f.extra = junk[:]
	testing.expect_value(t, run_fake(&f), Error.Bad_Record_Mac)
}

@(test)
fuzz_server_hello :: proc(t: ^testing.T) {
	// Random corruption of an otherwise valid ServerHello must never crash.
	for i in 0 ..< 300 {
		f: Fake_Server
		f.echo_sid = true
		f.mutate = 1 + i % 4
		e := run_fake(&f)
		testing.expect(t, e != .None)
		fake_destroy(&f)
	}
}

@(test)
fuzz_random_records :: proc(t: ^testing.T) {
	buf: [600]byte
	for i in 0 ..< 300 {
		f: Fake_Server
		n := rand.int_max(len(buf))
		for j in 0 ..< n do buf[j] = byte(rand.uint32())
		// Half the time make the header plausible so parsing goes deeper.
		if n > 9 && i % 2 == 0 {
			buf[0] = CT_HANDSHAKE
			buf[1] = 3
			buf[3] = byte((n - 5) >> 8)
			buf[4] = byte(n - 5)
			buf[5] = HS_SERVER_HELLO
		}
		append(&f.input, ..buf[:n])
		testing.expect(t, run_fake(&f) != .None)
		fake_destroy(&f)
	}
}
