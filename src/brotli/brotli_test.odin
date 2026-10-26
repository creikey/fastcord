package brotli

import "core:bytes"
import "core:crypto/hash"
import "core:math/rand"
import "core:testing"

TEXT :: #load("testdata/text.txt")
JSON :: #load("testdata/sample.json")
BIN :: #load("testdata/sample.bin")
RANDOM :: #load("testdata/random.bin")

@(private = "file")
Vector :: struct {
	name: string,
	comp: []byte,
	want: []byte,
}

@(private = "file")
VECTORS := [?]Vector {
	{"text.q0", #load("testdata/text.txt.q0.br"), TEXT},
	{"text.q1", #load("testdata/text.txt.q1.br"), TEXT},
	{"text.q2", #load("testdata/text.txt.q2.br"), TEXT},
	{"text.q3", #load("testdata/text.txt.q3.br"), TEXT},
	{"text.q4", #load("testdata/text.txt.q4.br"), TEXT},
	{"text.q5", #load("testdata/text.txt.q5.br"), TEXT},
	{"text.q6", #load("testdata/text.txt.q6.br"), TEXT},
	{"text.q7", #load("testdata/text.txt.q7.br"), TEXT},
	{"text.q8", #load("testdata/text.txt.q8.br"), TEXT},
	{"text.q9", #load("testdata/text.txt.q9.br"), TEXT},
	{"text.q10", #load("testdata/text.txt.q10.br"), TEXT},
	{"text.q11", #load("testdata/text.txt.q11.br"), TEXT},
	{"json.q0", #load("testdata/sample.json.q0.br"), JSON},
	{"json.q1", #load("testdata/sample.json.q1.br"), JSON},
	{"json.q2", #load("testdata/sample.json.q2.br"), JSON},
	{"json.q5", #load("testdata/sample.json.q5.br"), JSON},
	{"json.q9", #load("testdata/sample.json.q9.br"), JSON},
	{"json.q11", #load("testdata/sample.json.q11.br"), JSON},
	{"json.q11w10", #load("testdata/sample.json.q11w10.br"), JSON},
	{"json.q5w24", #load("testdata/sample.json.q5w24.br"), JSON},
	{"bin.q1", #load("testdata/sample.bin.q1.br"), BIN},
	{"bin.q6", #load("testdata/sample.bin.q6.br"), BIN},
	{"bin.q11", #load("testdata/sample.bin.q11.br"), BIN},
	{"random.q5", #load("testdata/random.bin.q5.br"), RANDOM},
	{"empty", #load("testdata/empty.br"), nil},
}

@(test)
test_dictionary :: proc(t: ^testing.T) {
	testing.expect_value(t, len(DICT), 122784)
	digest: [32]byte
	hash.hash_bytes_to_buffer(.SHA256, DICT, digest[:])
	want := [32]byte {
		0x20, 0xe4, 0x2e, 0xb1, 0xb5, 0x11, 0xc2, 0x18, 0x06, 0xd4, 0xd2, 0x27, 0xd0, 0x7e, 0x5d, 0xd0,
		0x68, 0x77, 0xd8, 0xce, 0x7b, 0x3a, 0x81, 0x7f, 0x37, 0x8f, 0x31, 0x36, 0x53, 0xf3, 0x5c, 0x70,
	}
	testing.expect(t, digest == want)
	off: u32
	for l in 4 ..= 24 {
		testing.expect_value(t, DICT_OFFSET[l], off)
		off += u32(l) << DICT_NDBITS[l]
	}
	testing.expect_value(t, off, u32(len(DICT)))
}

@(test)
test_vectors :: proc(t: ^testing.T) {
	for v in VECTORS {
		got, err := decompress(v.comp)
		defer delete(got)
		testing.expectf(t, err == .None, "%s: err %v", v.name, err)
		testing.expectf(t, bytes.equal(got, v.want), "%s: mismatch (%d vs %d bytes)", v.name, len(got), len(v.want))
	}
}

@(test)
test_handmade_metablocks :: proc(t: ^testing.T) {
	// WBITS=16; metadata block (3 bytes); uncompressed "hi"; last empty.
	s := []byte{0x2C, 0x01, 'a', 'b', 'c', 0x08, 0x00, 0x08, 'h', 'i', 0x03}
	got, err := decompress(s)
	defer delete(got)
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, string(got), "hi")

	_, e2 := decompress([]byte{0x2C, 0x01, 'a', 'b', 'c', 0x08, 0x00, 0x08, 'h', 'i', 0x03, 0xFF})
	testing.expect_value(t, e2, Error.Corrupt) // trailing bytes
	_, e3 := decompress(nil)
	testing.expect_value(t, e3, Error.Truncated)
}

@(test)
test_max_out :: proc(t: ^testing.T) {
	_, err := decompress(#load("testdata/sample.json.q5.br"), max_out = 1000)
	testing.expect_value(t, err, Error.Output_Too_Large)
	got, e2 := decompress(#load("testdata/sample.json.q5.br"), max_out = len(JSON))
	delete(got)
	testing.expect_value(t, e2, Error.None)
}

@(test)
test_corruption :: proc(t: ^testing.T) {
	comp := #load("testdata/text.txt.q11.br")
	for n in 0 ..< len(comp) {
		got, err := decompress(comp[:n])
		delete(got)
		testing.expectf(t, err != .None, "truncated at %d accepted", n)
		if err == .None do break
	}
	// random bit flips must never crash or overrun (no checksum in brotli, so
	// a flip may still decode "successfully" to different bytes)
	r := rand.create(5)
	gen := rand.default_random_generator(&r)
	srcs := [][]byte{comp, #load("testdata/sample.bin.q6.br"), #load("testdata/sample.json.q1.br")}
	for src in srcs {
		buf := make([]byte, len(src), context.temp_allocator)
		for _ in 0 ..< 1500 {
			copy(buf, src)
			for _ in 0 ..< 1 + rand.int_max(3, gen) {
				i := rand.int_max(len(buf), gen)
				buf[i] ~= u8(1) << uint(rand.int_max(8, gen))
			}
			got, _ := decompress(buf, max_out = 1 << 20)
			delete(got)
		}
	}
}
