package zstd

import "core:bytes"
import "core:math/rand"
import "core:testing"

SAMPLE_JSON :: #load("testdata/sample.json")
SAMPLE_BIN :: #load("testdata/sample.bin")
RANDOM_BIN :: #load("testdata/random.bin")

Vector :: struct {
	name: string,
	comp: []byte,
	want: []byte,
}

@(private = "file")
zeros_300k :: proc() -> []byte {return make([]byte, 300000, context.temp_allocator)}

@(private = "file")
vectors :: proc() -> []Vector {
	v := make([dynamic]Vector, context.temp_allocator)
	append(&v, Vector{"json.1", #load("testdata/sample.json.1.zst"), SAMPLE_JSON})
	append(&v, Vector{"json.3", #load("testdata/sample.json.3.zst"), SAMPLE_JSON})
	append(&v, Vector{"json.9", #load("testdata/sample.json.9.zst"), SAMPLE_JSON})
	append(&v, Vector{"json.19", #load("testdata/sample.json.19.zst"), SAMPLE_JSON})
	append(&v, Vector{"json.long", #load("testdata/sample.json.long.zst"), SAMPLE_JSON})
	append(&v, Vector{"json.stream", #load("testdata/sample.json.stream.zst"), SAMPLE_JSON})
	append(&v, Vector{"bin.1", #load("testdata/sample.bin.1.zst"), SAMPLE_BIN})
	append(&v, Vector{"bin.19", #load("testdata/sample.bin.19.zst"), SAMPLE_BIN})
	append(&v, Vector{"random", #load("testdata/random.zst"), RANDOM_BIN})
	append(&v, Vector{"zeros", #load("testdata/zeros.zst"), zeros_300k()})
	append(&v, Vector{"empty", #load("testdata/empty.zst"), nil})
	return v[:]
}

@(test)
test_decompress_vectors :: proc(t: ^testing.T) {
	for v in vectors() {
		got, err := decompress(v.comp)
		defer delete(got)
		testing.expectf(t, err == .None, "%s: err %v", v.name, err)
		testing.expectf(t, bytes.equal(got, v.want), "%s: output mismatch (%d vs %d bytes)", v.name, len(got), len(v.want))
	}
}

@(test)
test_multi_frame_and_skippable :: proc(t: ^testing.T) {
	a := #load("testdata/sample.json.3.zst")
	b := #load("testdata/sample.bin.19.zst")
	skip := []byte{0x5A, 0x2A, 0x4D, 0x18, 5, 0, 0, 0, 1, 2, 3, 4, 5}
	input := make([dynamic]byte, context.temp_allocator)
	append(&input, ..skip)
	append(&input, ..a)
	append(&input, ..skip)
	append(&input, ..b)
	append(&input, ..#load("testdata/empty.zst"))
	want := make([dynamic]byte, context.temp_allocator)
	append(&want, ..SAMPLE_JSON)
	append(&want, ..SAMPLE_BIN)
	got, err := decompress(input[:])
	defer delete(got)
	testing.expect_value(t, err, Error.None)
	testing.expect(t, bytes.equal(got, want[:]))

	// same through the stream decoder, split at random points
	d: Stream_Decoder
	stream_init(&d)
	defer stream_destroy(&d)
	out := make([dynamic]byte, context.temp_allocator)
	r := rand.create(1)
	gen := rand.default_random_generator(&r)
	p := 0
	for p < len(input) {
		n := min(len(input) - p, 1 + rand.int_max(3000, gen))
		testing.expect_value(t, stream_decode(&d, input[p:p + n], &out), Error.None)
		p += n
	}
	testing.expect(t, stream_at_frame_boundary(&d))
	testing.expect(t, bytes.equal(out[:], want[:]))
}

@(test)
test_errors :: proc(t: ^testing.T) {
	comp := #load("testdata/sample.json.19.zst")
	// truncation at every length must error, never crash
	for n in 0 ..< len(comp) {
		got, err := decompress(comp[:n])
		delete(got)
		testing.expectf(t, err != .None, "truncated at %d accepted", n)
		if err == .None do break
	}
	// bit flips: must not crash; checksum catches silent corruption
	buf := make([]byte, len(comp), context.temp_allocator)
	r := rand.create(2)
	gen := rand.default_random_generator(&r)
	for _ in 0 ..< 2000 {
		copy(buf, comp)
		i := rand.int_max(len(buf), gen)
		buf[i] ~= u8(1) << uint(rand.int_max(8, gen))
		got, err := decompress(buf)
		if err == .None do testing.expect(t, bytes.equal(got, SAMPLE_JSON))
		delete(got)
	}
	_, e1 := decompress([]byte{1, 2, 3, 4, 5})
	testing.expect_value(t, e1, Error.Bad_Magic)
	// window descriptor for 2 GB
	_, e2 := decompress([]byte{0x28, 0xB5, 0x2F, 0xFD, 0x00, 0xA8, 0, 0, 0})
	testing.expect_value(t, e2, Error.Window_Too_Large)
	// dictionary id
	_, e3 := decompress([]byte{0x28, 0xB5, 0x2F, 0xFD, 0x01, 0x50, 7, 1, 0, 0})
	testing.expect_value(t, e3, Error.Dictionary_Unsupported)
}

// Decode comp via the stream decoder fed in the given chunk sizes.
@(private = "file")
stream_chunks :: proc(comp: []byte, sizes: []int, out: ^[dynamic]byte) -> Error {
	d: Stream_Decoder
	stream_init(&d)
	defer stream_destroy(&d)
	p := 0
	for n in sizes {
		if err := stream_decode(&d, comp[p:p + n], out); err != .None do return err
		p += n
	}
	return .None
}

@(test)
test_split_every_point :: proc(t: ^testing.T) {
	small := [][]byte{#load("testdata/sample.bin.19.zst"), #load("testdata/sample.json.19.zst"), #load("testdata/random.zst"), #load("testdata/zeros.zst")}
	wants := [][]byte{SAMPLE_BIN, SAMPLE_JSON, RANDOM_BIN, zeros_300k()}
	out := make([dynamic]byte, context.temp_allocator)
	for comp, k in small {
		for s in 0 ..= len(comp) {
			clear(&out)
			err := stream_chunks(comp, {s, len(comp) - s}, &out)
			if err != .None || !bytes.equal(out[:], wants[k]) {
				testing.expectf(t, false, "vector %d split at %d: err %v, %d bytes", k, s, err, len(out))
				break
			}
		}
	}
	// byte at a time
	comp := #load("testdata/sample.json.3.zst")
	sizes := make([]int, len(comp), context.temp_allocator)
	for &s in sizes do s = 1
	clear(&out)
	testing.expect_value(t, stream_chunks(comp, sizes, &out), Error.None)
	testing.expect(t, bytes.equal(out[:], SAMPLE_JSON))
}

@(private = "file")
le32 :: proc(p: []byte) -> u32 {return u32(p[0]) | u32(p[1]) << 8 | u32(p[2]) << 16 | u32(p[3]) << 24}

// Gateway: one endless frame, flushed after each message. Every message's
// bytes must decode to exactly that message as soon as they arrive.
@(private = "file")
check_gateway :: proc(t: ^testing.T, comp: []byte, idx: []byte, extra_splits: bool) {
	raw, err := decompress(#load("testdata/gwmsgs.bin.zst"), context.temp_allocator)
	testing.expect_value(t, err, Error.None)
	d: Stream_Decoder
	stream_init(&d)
	defer stream_destroy(&d)
	out := make([dynamic]byte, context.temp_allocator)
	r := rand.create(3)
	gen := rand.default_random_generator(&r)
	p, rp := 0, 0
	for i := 0; i + 4 <= len(idx); i += 4 {
		clen := int(le32(idx[i:]))
		mlen := int(le32(raw[rp:]))
		want := raw[rp + 4:rp + 4 + mlen]
		rp += 4 + mlen
		chunk := comp[p:p + clen]
		p += clen
		clear(&out)
		if extra_splits && clen > 2 {
			// split the message itself at a random point: first part may yield
			// a prefix, the remainder must complete it
			s := 1 + rand.int_max(clen - 1, gen)
			testing.expect_value(t, stream_decode(&d, chunk[:s], &out), Error.None)
			testing.expect_value(t, stream_decode(&d, chunk[s:], &out), Error.None)
		} else {
			testing.expect_value(t, stream_decode(&d, chunk, &out), Error.None)
		}
		if !bytes.equal(out[:], want) {
			testing.expectf(t, false, "message %d: got %d bytes want %d", i / 4, len(out), len(want))
			return
		}
	}
	testing.expect_value(t, p, len(comp))
}

@(test)
test_gateway_stream :: proc(t: ^testing.T) {
	check_gateway(t, #load("testdata/gw3.zst"), #load("testdata/gw3.idx"), false)
	check_gateway(t, #load("testdata/gw19.zst"), #load("testdata/gw19.idx"), false)
	check_gateway(t, #load("testdata/gw3.zst"), #load("testdata/gw3.idx"), true)
	check_gateway(t, #load("testdata/gw19.zst"), #load("testdata/gw19.idx"), true)
}

@(test)
test_random_splits :: proc(t: ^testing.T) {
	r := rand.create(4)
	gen := rand.default_random_generator(&r)
	out := make([dynamic]byte, context.temp_allocator)
	for v in vectors() {
		for _ in 0 ..< 20 {
			sizes := make([dynamic]int, context.temp_allocator)
			rem := len(v.comp)
			for rem > 0 {
				n := min(rem, rand.int_max(2, gen) == 0 ? 1 + rand.int_max(16, gen) : 1 + rand.int_max(4000, gen))
				append(&sizes, n)
				rem -= n
			}
			clear(&out)
			err := stream_chunks(v.comp, sizes[:], &out)
			testing.expectf(t, err == .None && bytes.equal(out[:], v.want), "%s: err %v", v.name, err)
		}
	}
}
