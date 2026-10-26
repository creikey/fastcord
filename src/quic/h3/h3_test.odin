package h3

import "core:encoding/hex"
import "core:slice"
import "core:testing"

import "fc:http"
import "fc:quic"

// Chrome's control stream bytes (type, SETTINGS, GREASE frame).
CHROME_CONTROL := #load("../testdata/chrome_h3_control.bin")

@(private = "file")
unhex :: proc(s: string) -> []byte {
	b, _ := hex.decode(transmute([]byte)s)
	return b
}

@(private = "file")
Frame :: struct {
	typ:     u64,
	payload: []byte,
}

@(private = "file")
parse_control :: proc(b: []byte) -> (stream_type: u64, frames: [dynamic]Frame) {
	r := quic.reader(b)
	stream_type = quic.r_varint(&r)
	for len(r.b) > 0 {
		typ := quic.r_varint(&r)
		p := quic.r_vec(&r)
		if !r.ok do break
		append(&frames, Frame{typ, p})
	}
	return
}

@(private = "file")
is_grease :: proc(id: u64) -> bool {return id >= 0x21 && (id - 0x21) % 0x1f == 0}

@(test)
control_stream_matches_chrome :: proc(t: ^testing.T) {
	ours: [dynamic]byte
	defer delete(ours)
	control_preamble(&ours)
	for raw in ([][]byte{ours[:], CHROME_CONTROL}) {
		st, frames := parse_control(raw)
		defer delete(frames)
		testing.expect_value(t, st, 0)
		if !testing.expect_value(t, len(frames), 2) do continue
		testing.expect_value(t, frames[0].typ, FRAME_SETTINGS)
		testing.expect(t, is_grease(frames[1].typ), "second frame is GREASE")
		// SETTINGS: identical ids, values and encodings except the GREASE pair.
		r := quic.reader(frames[0].payload)
		want := [?][2]u64{{1, 65536}, {6, 262144}, {7, 100}, {0x33, 1}}
		for w in want {
			testing.expect_value(t, quic.r_varint(&r), w[0])
			testing.expect_value(t, quic.r_varint(&r), w[1])
		}
		testing.expect(t, is_grease(quic.r_varint(&r)))
		quic.r_varint(&r)
		testing.expect(t, quic.r_done(&r))
	}
	// The fixed settings are byte-identical (same varint sizes).
	testing.expect(t, slice.equal(ours[3:18], CHROME_CONTROL[3:18]), "fixed settings bytes")
}

// RFC 9204 B.1: literal field line with a static name reference.
@(test)
qpack_rfc9204_b1 :: proc(t: ^testing.T) {
	d: Decoder
	decoder_init(&d)
	defer decoder_destroy(&d)
	block := unhex("0000510b2f696e6465782e68746d6c")
	defer delete(block)
	out: [dynamic]http.Header
	defer delete(out)
	res, _ := decode_section(&d, block, &out, context.temp_allocator)
	testing.expect_value(t, res, Decode_Result.Ok)
	testing.expect(t, len(out) == 1 && out[0].name == ":path" && out[0].value == "/index.html")
}

// RFC 9204 B.2: dynamic table inserts then post-base references.
@(test)
qpack_rfc9204_b2 :: proc(t: ^testing.T) {
	d: Decoder
	decoder_init(&d)
	d.max_capacity = 220
	defer decoder_destroy(&d)
	block := unhex("03811011")
	defer delete(block)
	out: [dynamic]http.Header
	defer delete(out)
	// Before the encoder stream arrives the section is blocked.
	res, ric := decode_section(&d, block, &out, context.temp_allocator)
	testing.expect_value(t, res, Decode_Result.Blocked)
	testing.expect_value(t, ric, 2)
	enc := unhex("3fbd01c00f7777772e6578616d706c652e636f6dc10c2f73616d706c652f70617468")
	defer delete(enc)
	// Feed in two pieces to exercise partial instructions.
	testing.expect(t, feed_encoder_stream(&d, enc[:7]))
	testing.expect(t, feed_encoder_stream(&d, enc[7:]))
	testing.expect_value(t, inserted(&d), 2)
	res, _ = decode_section(&d, block, &out, context.temp_allocator)
	testing.expect_value(t, res, Decode_Result.Ok)
	testing.expect(t, len(out) == 2)
	testing.expect(t, out[0].name == ":authority" && out[0].value == "www.example.com")
	testing.expect(t, out[1].name == ":path" && out[1].value == "/sample/path")
}

// The encoder makes Chrome's representation choices (checked against the
// official client's captured request: d1 50.. d7 51.. de 5f..).
@(test)
qpack_encoder_choices :: proc(t: ^testing.T) {
	b: [dynamic]byte
	defer delete(b)
	encode_section(&b, {
		{":method", "GET"},
		{":authority", "discord.com"},
		{":scheme", "https"},
		{":path", "/app"},
		{"upgrade-insecure-requests", "1"},
		{"sec-fetch-user", "?1"},
		{"cookie", "a=1; b=2"},
	})
	testing.expect(t, b[0] == 0 && b[1] == 0, "prefix")
	testing.expect_value(t, b[2], 0xd1) // indexed static 17
	testing.expect_value(t, b[3], 0x50) // literal, static name 0
	testing.expect_value(t, b[4], 0x88) // huffman, 8 bytes ("discord.com")
	testing.expect_value(t, b[13], 0xd7) // indexed static 23
	// Decode everything back.
	d: Decoder
	decoder_init(&d)
	defer decoder_destroy(&d)
	out: [dynamic]http.Header
	defer delete(out)
	res, _ := decode_section(&d, b[:], &out, context.temp_allocator)
	testing.expect_value(t, res, Decode_Result.Ok)
	names := [?]string{":method", ":authority", ":scheme", ":path", "upgrade-insecure-requests", "sec-fetch-user", "cookie", "cookie"}
	values := [?]string{"GET", "discord.com", "https", "/app", "1", "?1", "a=1", "b=2"}
	if testing.expect_value(t, len(out), len(names)) {
		for h, i in out {
			testing.expect_value(t, h.name, names[i])
			testing.expect_value(t, h.value, values[i])
		}
	}
}

@(test)
qpack_decoder_rejects_garbage :: proc(t: ^testing.T) {
	d: Decoder
	decoder_init(&d)
	defer decoder_destroy(&d)
	bad := [?][]byte{{0x00}, {0x00, 0x00, 0xff}, {0xff, 0xff, 0xff}, {0x00, 0x00, 0x80}, {0x00, 0x00, 0x5f, 0xff}}
	for blk in bad {
		out: [dynamic]http.Header
		res, _ := decode_section(&d, blk, &out, context.temp_allocator)
		testing.expectf(t, res != .Ok || len(out) == 0, "accepted %x", blk)
		delete(out)
	}
	testing.expect(t, !feed_encoder_stream(&d, {0x81, 0x01, 0x41})) // insert into a zero-capacity table
}
