package etf

import "core:bytes"
import "core:encoding/hex"
import "core:math/rand"
import "core:strings"
import "core:testing"

@(private = "file")
unhex :: proc(s: string) -> []byte {
	b, ok := hex.decode(transmute([]byte)s, context.temp_allocator)
	assert(ok)
	return b
}

@(private = "file")
json_of :: proc(data: []byte) -> (string, Error) {
	sb := strings.builder_make(context.temp_allocator)
	err := etf_to_json(data, &sb)
	return strings.to_string(sb), err
}

@(private = "file")
json_roundtrip :: proc(t: ^testing.T, json_text: string, want_hex: string) {
	v, err := from_json(json_text, context.temp_allocator)
	testing.expect_value(t, err, Error.None)
	got, eerr := encode(v, context.temp_allocator)
	testing.expect_value(t, eerr, Error.None)
	want := unhex(want_hex)
	if !bytes.equal(got, want) {
		testing.expectf(t, false, "encode mismatch for %s\n got %x\nwant %x", json_text, got, want)
	}
	// decode back and re-render JSON
	j, jerr := json_of(got)
	testing.expect_value(t, jerr, Error.None)
	testing.expect_value(t, j, json_text)
	dv, derr := decode(got, {}, context.temp_allocator)
	testing.expect_value(t, derr, Error.None)
	again, _ := encode(dv, context.temp_allocator)
	testing.expectf(t, bytes.equal(again, want), "decode->encode not byte identical %s %x", json_text, again)
}

// Shapes taken from the official client's sent frames (values here are not secret).
@(test)
test_official_voice_state :: proc(t: ^testing.T) {
	json_roundtrip(
		t,
		`{"op":4,"d":{"guild_id":null,"channel_id":null,"self_mute":true,"self_deaf":false,"self_video":false,"flags":2}}`,
		"8374000000026d000000026f7061046d000000016474000000066d000000086775696c645f696473036e696c6d0000000a6368616e6e656c5f696473036e696c6d0000000973656c665f6d7574657304747275656d0000000973656c665f64656166730566616c73656d0000000a73656c665f766964656f730566616c73656d00000005666c6167736102",
	)
}

@(test)
test_official_qos :: proc(t: ^testing.T) {
	json_roundtrip(
		t,
		`{"op":40,"d":{"seq":1,"qos":{"active":true,"ver":31,"reasons":["foregrounded"]}}}`,
		"8374000000026d000000026f7061286d000000016474000000026d0000000373657161016d00000003716f7374000000036d000000066163746976657304747275656d00000003766572611f6d00000007726561736f6e736c000000016d0000000c666f726567726f756e6465646a",
	)
	json_roundtrip(
		t,
		`{"op":40,"d":{"seq":3,"qos":{"active":false,"ver":31,"reasons":[]}}}`,
		"8374000000026d000000026f7061286d000000016474000000026d0000000373657161036d00000003716f7374000000036d00000006616374697665730566616c73656d00000003766572611f6d00000007726561736f6e736a",
	)
}

@(test)
test_official_big_timestamp :: proc(t: ^testing.T) {
	// 1793006560889 -> SMALL_BIG with 6 digit bytes (JS number > int32)
	json_roundtrip(t, `{"initialization_timestamp":1793006560889}`, "8374000000016d00000018696e697469616c697a6174696f6e5f74696d657374616d706e060079e68477a101")
}

@(test)
test_ints :: proc(t: ^testing.T) {
	json_roundtrip(t, `0`, "836100")
	json_roundtrip(t, `255`, "8361ff")
	json_roundtrip(t, `256`, "836200000100")
	json_roundtrip(t, `-1`, "8362ffffffff")
	json_roundtrip(t, `2147483647`, "83627fffffff")
	json_roundtrip(t, `-2147483648`, "836280000000")
	json_roundtrip(t, `2147483648`, "836e040000000080")
	json_roundtrip(t, `-2147483649`, "836e040101000080")
	json_roundtrip(t, `1546820558950371408`, "836e08005010825b1a697715")
	json_roundtrip(t, `18446744073709551615`, "836e0800ffffffffffffffff")
	json_roundtrip(t, `1.5`, "83463ff8000000000000")
	json_roundtrip(t, `[]`, "836a")
	json_roundtrip(t, `{}`, "837400000000")
	json_roundtrip(t, `"hé\"\n"`, "836d0000000568c3a9220a")
	v, _ := decode(unhex("836e0800ffffffffffffffff"), {}, context.temp_allocator)
	u, ok := as_u64(v)
	testing.expect(t, ok && u == max(u64))
	v2, _ := decode(unhex("836e08005010825b1a697715"), {}, context.temp_allocator)
	testing.expect_value(t, v2.(i64), 1546820558950371408)
}

// Terms the server (Erlang/Elixir) emits that our encoder never produces.
@(test)
test_server_shapes :: proc(t: ^testing.T) {
	cases := [][2]string {
		{"83770474727565", `true`}, // SMALL_ATOM_UTF8 true
		{"837600036e696c", `null`}, // ATOM_UTF8 nil
		{"8364000568656c6c6f", `"hello"`}, // ATOM_EXT
		{"8373026869", `"hi"`}, // SMALL_ATOM latin1
		{"837302e9e9", `"éé"`}, // latin1 -> utf8
		{"836b0003010203", `[1,2,3]`}, // STRING_EXT charlist
		{"8368026101620000012c", `[1,300]`}, // SMALL_TUPLE
		{"8369000000016a", `[[]]`}, // LARGE_TUPLE with one NIL
		{"836f0000000201ff00", `-255`}, // LARGE_BIG negative, padded digit
		{"836e0900000000000000000001", `18446744073709551616`}, // 2^64 as Big
		{"8374000000026101610274000000006a", `{"1":2,"{}":[]}`}, // non-string keys
		{"8346bff0000000000000", `-1.0`},
		{"835000000015789c2b61606060cc051189209235233527271f001f3803cb", `{"a":"hello"}`}, // compressed
	}
	for c in cases {
		data := unhex(c[0])
		j, err := json_of(data)
		testing.expectf(t, err == .None && j == c[1], "%s: got %v %s want %s", c[0], err, j, c[1])
		v, derr := decode(data, {}, context.temp_allocator)
		testing.expectf(t, derr == .None, "%s: %v", c[0], derr)
		sb := strings.builder_make(context.temp_allocator)
		to_json(v, &sb)
		testing.expect_value(t, strings.to_string(sb), c[1])
	}
	// FLOAT_EXT (old textual float)
	old := make([]byte, 33, context.temp_allocator)
	old[0] = 131
	old[1] = 'c'
	copy(old[2:], "1.50000000000000000000e+00")
	v, err := decode(old, {}, context.temp_allocator)
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, v.(f64), 1.5)
}

@(test)
test_malformed :: proc(t: ^testing.T) {
	bad := [][2]string {
		{"", "Truncated"},
		{"82", "Bad_Version"},
		{"83", "Truncated"},
		{"83ff", "Bad_Tag"},
		{"836d00000005616263", "Truncated"},
		{"836cffffffff", "Truncated"}, // huge list count must not allocate
		{"8374ffffffff", "Truncated"}, // huge map count
		{"8369ffffffff", "Truncated"}, // huge tuple
		{"836c000000016101", "Truncated"},
		{"836c0000000161016102", "Improper_List"},
		{"8361016102", "Trailing_Data"},
		{"8350ffffffff789c", "Too_Large"},
		{"835000000005789c00", "Zlib"},
		{"836fffffffff00", "Truncated"},
		{"83740000000161", "Truncated"},
	}
	for c in bad {
		_, err := decode(unhex(c[0]), {}, context.temp_allocator)
		testing.expectf(t, err != .None, "%s: expected error", c[0])
		sb := strings.builder_make(context.temp_allocator)
		jerr := etf_to_json(unhex(c[0]), &sb)
		testing.expectf(t, jerr != .None, "%s: expected json error", c[0])
	}
	// depth bomb: 100k nested single-element lists
	deep := make([dynamic]byte, context.temp_allocator)
	append(&deep, 131)
	for _ in 0 ..< 100_000 do append(&deep, 'l', 0, 0, 0, 1)
	_, err := decode(deep[:], {}, context.temp_allocator)
	testing.expect_value(t, err, Error.Too_Deep)
}

// Random mutations of valid terms must never crash.
@(test)
test_fuzz :: proc(t: ^testing.T) {
	src := `{"op":0,"d":{"id":1546820558950371408,"x":[1,2.5,"s",null,true,{"k":[]}],"n":-70000,"b":18446744073709551615},"s":42,"t":"MESSAGE_CREATE"}`
	v, _ := from_json(src, context.temp_allocator)
	base, _ := encode(v, context.allocator)
	defer delete(base)
	r := rand.create(1234)
	context.random_generator = rand.default_random_generator(&r)
	buf := make([]byte, len(base))
	defer delete(buf)
	for _ in 0 ..< 20000 {
		copy(buf, base)
		n := 1 + rand.int_max(4)
		for _ in 0 ..< n do buf[rand.int_max(len(buf))] = u8(rand.int_max(256))
		cut := len(buf) - rand.int_max(4)
		dv, err := decode(buf[:cut], {}, context.allocator)
		if err == .None do destroy(dv, context.allocator)
		sb := strings.builder_make(context.temp_allocator)
		_ = etf_to_json(buf[:cut], &sb)
		free_all(context.temp_allocator)
	}
}
