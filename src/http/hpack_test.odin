package http

import "core:bytes"
import "core:encoding/hex"
import "core:strings"
import "core:testing"

@(private = "file")
dehex :: proc(s: string) -> []byte {
	clean, _ := strings.remove_all(s, " ", context.temp_allocator)
	clean2, _ := strings.remove_all(clean, "\n", context.temp_allocator)
	b, ok := hex.decode(transmute([]byte)clean2, context.temp_allocator)
	assert(ok, s)
	return b
}

@(private = "file")
expect_fields :: proc(t: ^testing.T, got: []Header, want: []Header, loc := #caller_location) {
	testing.expectf(t, len(got) == len(want), "field count %d want %d", len(got), len(want), loc = loc)
	for i in 0 ..< min(len(got), len(want)) {
		testing.expectf(t, got[i] == want[i], "field %d: got %v want %v", i, got[i], want[i], loc = loc)
	}
}

@(private = "file")
expect_table :: proc(t: ^testing.T, tab: ^Dyn_Table, want: []Header, size: int, loc := #caller_location) {
	testing.expectf(t, tab.size == size, "table size %d want %d", tab.size, size, loc = loc)
	testing.expectf(t, dyn_count(tab) == len(want), "table count %d want %d", dyn_count(tab), len(want), loc = loc)
	for i in 0 ..< min(dyn_count(tab), len(want)) {
		e := dyn_get(tab, i)
		testing.expectf(t, e.name == want[i].name && e.value == want[i].value, "entry %d: %s: %s", i, e.name, e.value, loc = loc)
	}
}

@(private = "file")
free_fields :: proc(f: ^[dynamic]Header) {
	for h in f {
		delete(h.name)
		delete(h.value)
	}
	clear(f)
}

@(test)
test_hpack_c2 :: proc(t: ^testing.T) {
	d: Hpack_Decoder
	hpack_decoder_init(&d, 4096)
	defer hpack_decoder_destroy(&d)
	out := make([dynamic]Header)
	defer {free_fields(&out); delete(out)}

	testing.expect_value(t, hpack_decode(&d, dehex("400a 6375 7374 6f6d 2d6b 6579 0d63 7573 746f 6d2d 6865 6164 6572"), &out), Error.None)
	expect_fields(t, out[:], {{"custom-key", "custom-header"}})
	expect_table(t, &d.table, {{"custom-key", "custom-header"}}, 55)
	free_fields(&out)

	d2: Hpack_Decoder
	hpack_decoder_init(&d2, 4096)
	defer hpack_decoder_destroy(&d2)
	testing.expect_value(t, hpack_decode(&d2, dehex("040c 2f73 616d 706c 652f 7061 7468"), &out), Error.None)
	expect_fields(t, out[:], {{":path", "/sample/path"}})
	testing.expect_value(t, dyn_count(&d2.table), 0)
	free_fields(&out)

	testing.expect_value(t, hpack_decode(&d2, dehex("1008 7061 7373 776f 7264 0673 6563 7265 74"), &out), Error.None)
	expect_fields(t, out[:], {{"password", "secret"}})
	testing.expect_value(t, dyn_count(&d2.table), 0)
	free_fields(&out)

	testing.expect_value(t, hpack_decode(&d2, {0x82}, &out), Error.None)
	expect_fields(t, out[:], {{":method", "GET"}})
	free_fields(&out)
}

@(private = "file")
C3_REQS := [3][]Header {
	{{":method", "GET"}, {":scheme", "http"}, {":path", "/"}, {":authority", "www.example.com"}},
	{{":method", "GET"}, {":scheme", "http"}, {":path", "/"}, {":authority", "www.example.com"}, {"cache-control", "no-cache"}},
	{{":method", "GET"}, {":scheme", "https"}, {":path", "/index.html"}, {":authority", "www.example.com"}, {"custom-key", "custom-value"}},
}

// C.3 / C.4 are exactly what Chrome's encoder produces for these lists
// (:authority and regular headers indexed, Huffman when shorter).
@(test)
test_hpack_c3_c4_requests :: proc(t: ^testing.T) {
	plain := [3]string {
		"8286 8441 0f77 7777 2e65 7861 6d70 6c65 2e63 6f6d",
		"8286 84be 5808 6e6f 2d63 6163 6865",
		"8287 85bf 400a 6375 7374 6f6d 2d6b 6579 0c63 7573 746f 6d2d 7661 6c75 65",
	}
	huff := [3]string {
		"8286 8441 8cf1 e3c2 e5f2 3a6b a0ab 90f4 ff",
		"8286 84be 5886 a8eb 1064 9cbf",
		"8287 85bf 4088 25a8 49e9 5ba9 7d7f 8925 a849 e95b b8e8 b4bf",
	}
	sizes := [3]int{57, 110, 164}
	for use_huff in ([]bool{false, true}) {
		e: Hpack_Encoder
		hpack_encoder_init(&e)
		e.huffman = use_huff
		defer hpack_encoder_destroy(&e)
		d: Hpack_Decoder
		hpack_decoder_init(&d, 4096)
		defer hpack_decoder_destroy(&d)
		out := make([dynamic]Header)
		defer {free_fields(&out); delete(out)}
		for i in 0 ..< 3 {
			want := dehex(huff[i] if use_huff else plain[i])
			buf := make([dynamic]byte, context.temp_allocator)
			hpack_encode(&e, C3_REQS[i], &buf)
			testing.expectf(t, bytes.equal(buf[:], want), "C.%d.%d encode\n got %x\nwant %x", 4 if use_huff else 3, i + 1, buf[:], want)
			testing.expect_value(t, hpack_decode(&d, want, &out), Error.None)
			expect_fields(t, out[:], C3_REQS[i])
			testing.expect_value(t, d.table.size, sizes[i])
			testing.expect_value(t, e.table.size, sizes[i])
			free_fields(&out)
		}
	}
}

@(private = "file")
index_all :: proc(name, value: string) -> bool {return true}

@(test)
test_hpack_c5_c6_responses :: proc(t: ^testing.T) {
	lists := [3][]Header {
		{{":status", "302"}, {"cache-control", "private"}, {"date", "Mon, 21 Oct 2013 20:13:21 GMT"}, {"location", "https://www.example.com"}},
		{{":status", "307"}, {"cache-control", "private"}, {"date", "Mon, 21 Oct 2013 20:13:21 GMT"}, {"location", "https://www.example.com"}},
		{
			{":status", "200"},
			{"cache-control", "private"},
			{"date", "Mon, 21 Oct 2013 20:13:22 GMT"},
			{"location", "https://www.example.com"},
			{"content-encoding", "gzip"},
			{"set-cookie", "foo=ASDJKHQKBZXOQWEOPIUAXQWEOIU; max-age=3600; version=1"},
		},
	}
	plain := [3]string {
		"4803 3330 3258 0770 7269 7661 7465 611d 4d6f 6e2c 2032 3120 4f63 7420 3230 3133 2032 303a 3133 3a32 3120 474d 546e 1768 7474 7073 3a2f 2f77 7777 2e65 7861 6d70 6c65 2e63 6f6d",
		"4803 3330 37c1 c0bf",
		"88c1 611d 4d6f 6e2c 2032 3120 4f63 7420 3230 3133 2032 303a 3133 3a32 3220 474d 54c0 5a04 677a 6970 7738 666f 6f3d 4153 444a 4b48 514b 425a 584f 5157 454f 5049 5541 5851 5745 4f49 553b 206d 6178 2d61 6765 3d33 3630 303b 2076 6572 7369 6f6e 3d31",
	}
	huff := [3]string {
		"4882 6402 5885 aec3 771a 4b61 96d0 7abe 9410 54d4 44a8 2005 9504 0b81 66e0 82a6 2d1b ff6e 919d 29ad 1718 63c7 8f0b 97c8 e9ae 82ae 43d3",
		"4883 640e ffc1 c0bf",
		"88c1 6196 d07a be94 1054 d444 a820 0595 040b 8166 e084 a62d 1bff c05a 839b d9ab 77ad 94e7 821d d7f2 e6c7 b335 dfdf cd5b 3960 d5af 2708 7f36 72c1 ab27 0fb5 291f 9587 3160 65c0 03ed 4ee5 b106 3d50 07",
	}
	sizes := [3]int{222, 222, 215}
	final_table := []Header {
		{"set-cookie", "foo=ASDJKHQKBZXOQWEOPIUAXQWEOIU; max-age=3600; version=1"},
		{"content-encoding", "gzip"},
		{"date", "Mon, 21 Oct 2013 20:13:22 GMT"},
	}
	for use_huff in ([]bool{false, true}) {
		e: Hpack_Encoder
		hpack_encoder_init(&e)
		e.huffman = use_huff
		e.policy = index_all
		e.huffman_on_tie = true // the RFC example encoder Huffman-codes "307" (3 == 3 bytes)
		e.settings_bound = 256
		dyn_set_max(&e.table, 256)
		defer hpack_encoder_destroy(&e)
		d: Hpack_Decoder
		hpack_decoder_init(&d, 256)
		dyn_set_max(&d.table, 256)
		defer hpack_decoder_destroy(&d)
		out := make([dynamic]Header)
		defer {free_fields(&out); delete(out)}
		for i in 0 ..< 3 {
			want := dehex(huff[i] if use_huff else plain[i])
			buf := make([dynamic]byte, context.temp_allocator)
			hpack_encode(&e, lists[i], &buf)
			testing.expectf(t, bytes.equal(buf[:], want), "C.%d.%d encode\n got %x\nwant %x", 6 if use_huff else 5, i + 1, buf[:], want)
			testing.expect_value(t, hpack_decode(&d, want, &out), Error.None)
			expect_fields(t, out[:], lists[i])
			testing.expect_value(t, d.table.size, sizes[i])
			free_fields(&out)
		}
		expect_table(t, &d.table, final_table, 215)
		expect_table(t, &e.table, final_table, 215)
	}
}

@(test)
test_huffman_roundtrip :: proc(t: ^testing.T) {
	all: [256]byte
	for i in 0 ..< 256 do all[i] = u8(i)
	for n in ([]int{0, 1, 2, 7, 64, 256}) {
		src := string(all[:n])
		enc := make([dynamic]byte, context.temp_allocator)
		huffman_encode(&enc, src)
		testing.expect_value(t, len(enc), huffman_encoded_len(src))
		sb := strings.builder_make(context.temp_allocator)
		testing.expect_value(t, huffman_decode(&sb, enc[:]), Error.None)
		testing.expect(t, strings.to_string(sb) == src)
	}
	sb := strings.builder_make(context.temp_allocator)
	// 'a' = 00011, padded with 3 ones -> 0x1f. Padding of zeros is invalid.
	testing.expect_value(t, huffman_decode(&sb, {0x1f}), Error.None)
	testing.expect_value(t, huffman_decode(&sb, {0x18}), Error.Protocol)
	// more than 7 bits of padding is invalid
	testing.expect_value(t, huffman_decode(&sb, {0x1f, 0xff}), Error.Protocol)
	// explicit EOS (30 ones) is invalid
	testing.expect_value(t, huffman_decode(&sb, {0xff, 0xff, 0xff, 0xff}), Error.Protocol)
}

@(test)
test_hpack_malformed :: proc(t: ^testing.T) {
	d: Hpack_Decoder
	hpack_decoder_init(&d, 4096)
	defer hpack_decoder_destroy(&d)
	out := make([dynamic]Header)
	defer {free_fields(&out); delete(out)}
	cases := []string {
		"80", // index 0
		"be", // dynamic index past end
		"ff ff ff ff ff ff ff 7f", // integer overflow
		"40 05 61", // string longer than block
		"41", // truncated
		"3fe13f", // size update 8192 above our max 4096
		"82 20", // size update after a field
	}
	for c in cases {
		err := hpack_decode(&d, dehex(c), &out)
		testing.expectf(t, err != .None, "%s should fail", c)
		free_fields(&out)
	}
	// header list size limit: the block is still fully applied
	d2: Hpack_Decoder
	hpack_decoder_init(&d2, 4096, 40)
	defer hpack_decoder_destroy(&d2)
	testing.expect_value(t, hpack_decode(&d2, dehex("400a 6375 7374 6f6d 2d6b 6579 0d63 7573 746f 6d2d 6865 6164 6572"), &out), Error.Too_Large)
	testing.expect_value(t, dyn_count(&d2.table), 1)
	free_fields(&out)
}

// Chrome-specific encoder behaviour (quiche HpackEncoder).
@(test)
test_hpack_chrome_policy :: proc(t: ^testing.T) {
	e: Hpack_Encoder
	hpack_encoder_init(&e)
	defer hpack_encoder_destroy(&e)
	buf := make([dynamic]byte, context.temp_allocator)
	hpack_encode(&e, {{":path", "/api/v9/x"}, {":method", "POST"}}, &buf)
	// :path not indexed -> 0x04 literal-without-indexing with name index 4; :method POST static 3
	testing.expect_value(t, buf[0], 0x04)
	testing.expect_value(t, buf[len(buf) - 1], 0x83)
	testing.expect_value(t, dyn_count(&e.table), 0)

	// cookie crumbs: each crumb indexed separately; "; " separators removed
	clear(&buf)
	hpack_encode(&e, {{"cookie", " a=1; b=2;c=3 "}}, &buf)
	testing.expect_value(t, dyn_count(&e.table), 3)
	testing.expect_value(t, dyn_get(&e.table, 0).value, "c=3")
	testing.expect_value(t, dyn_get(&e.table, 1).value, "b=2")
	testing.expect_value(t, dyn_get(&e.table, 2).value, "a=1")
	d: Hpack_Decoder
	hpack_decoder_init(&d, 4096)
	defer hpack_decoder_destroy(&d)
	out := make([dynamic]Header)
	defer {free_fields(&out); delete(out)}
	testing.expect_value(t, hpack_decode(&d, buf[:], &out), Error.None)
	testing.expect_value(t, len(out), 3)
	free_fields(&out)

	// repeated header -> fully indexed (dynamic) single byte
	clear(&buf)
	hpack_encode(&e, {{"cookie", "a=1"}}, &buf)
	testing.expect_value(t, len(buf), 1)
	testing.expect_value(t, buf[0], 0x80 | 64) // a=1 is third newest: 62 + 2

	// raw string kept when Huffman isn't strictly shorter
	clear(&buf)
	hpack_encode(&e, {{"x-a", "\x00\x01"}}, &buf) // NUL splits into "", "\x01"
	testing.expect_value(t, dyn_get(&e.table, 0).value, "\x01")
	testing.expect_value(t, dyn_get(&e.table, 1).value, "")

	// peer table size change -> size update at start of next block
	hpack_encoder_set_peer_table_size(&e, 8192)
	clear(&buf)
	hpack_encode(&e, {{":method", "GET"}}, &buf)
	testing.expect(t, bytes.equal(buf[:], []byte{0x3f, 0xe1, 0x3f, 0x82}), "size update 8192")
	hpack_encoder_set_peer_table_size(&e, 100)
	hpack_encoder_set_peer_table_size(&e, 2000)
	clear(&buf)
	hpack_encode(&e, {{":method", "GET"}}, &buf)
	// min (100) then current (2000)
	testing.expect(t, bytes.equal(buf[:], []byte{0x3f, 0x45, 0x3f, 0xb1, 0x0f, 0x82}), "shrink then grow")
}
