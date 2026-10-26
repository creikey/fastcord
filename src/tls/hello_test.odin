package tls

import "core:crypto/ecdh"
import "core:slice"
import "core:testing"

// Captured from the official Discord client (Electron 42.11.15 / Chrome 148, macOS arm64)
// via --host-resolver-rules pointing at a local listener.
CHROME_DISCORD_COM := [?][]byte {
	#load("testdata/chrome_discord_com_1.bin"),
	#load("testdata/chrome_discord_com_2.bin"),
	#load("testdata/chrome_discord_com_3.bin"),
}
CHROME_GATEWAY := [?][]byte {
	#load("testdata/chrome_gateway_1.bin"),
	#load("testdata/chrome_gateway_2.bin"),
}

@(private)
Ext :: struct {
	id:   u16,
	data: []byte,
}

@(private)
Parsed :: struct {
	record_version: u16,
	hs_len:         int,
	session_id:     []byte,
	ciphers:        [dynamic]u16,
	exts:           [dynamic]Ext,
}

@(private)
parse_hello :: proc(t: ^testing.T, rec: []byte) -> (p: Parsed, ok: bool) {
	r := reader(rec)
	if r_u8(&r) != CT_HANDSHAKE do return
	p.record_version = r_u16(&r)
	body := reader(r_vec16(&r))
	if !r_done(&r) do return
	if r_u8(&body) != HS_CLIENT_HELLO do return
	p.hs_len = r_u24(&body)
	if p.hs_len != len(body.b) do return
	if r_u16(&body) != 0x0303 do return
	r_take(&body, 32)
	p.session_id = r_vec8(&body)
	cs := reader(r_vec16(&body))
	for len(cs.b) > 0 do append(&p.ciphers, r_u16(&cs))
	comp := r_vec8(&body)
	if len(comp) != 1 || comp[0] != 0 do return
	exts := reader(r_vec16(&body))
	if !r_done(&body) do return
	for len(exts.b) > 0 {
		id := r_u16(&exts)
		append(&p.exts, Ext{id, r_vec16(&exts)})
	}
	return p, exts.ok && cs.ok
}

@(private)
parsed_destroy :: proc(p: ^Parsed) {
	delete(p.ciphers)
	delete(p.exts)
}

@(private)
find_ext :: proc(p: ^Parsed, id: u16) -> ([]byte, bool) {
	for e in p.exts do if e.id == id do return e.data, true
	return nil, false
}

// u16_list reads a u16 vector with GREASE values normalized to 0x0a0a.
@(private)
u16_list :: proc(b: []byte, prefix: int) -> [dynamic]u16 {
	out: [dynamic]u16
	r := reader(b)
	r_take(&r, prefix)
	for len(r.b) >= 2 {
		v := r_u16(&r)
		append(&out, 0x0a0a if is_grease(v) else v)
	}
	return out
}

// share_shape lists (group, key length) pairs of a key_share extension.
@(private)
share_shape :: proc(b: []byte) -> [dynamic][2]int {
	out: [dynamic][2]int
	r := reader(b)
	r_u16(&r)
	for len(r.b) > 0 {
		g := r_u16(&r)
		k := r_vec16(&r)
		append(&out, [2]int{0x0a0a if is_grease(g) else int(g), len(k)})
	}
	return out
}

@(private)
ech_payload_len :: proc(b: []byte) -> int {
	r := reader(b)
	r_take(&r, 6)
	r_vec16(&r)
	return len(r_vec16(&r))
}

@(private)
our_hello :: proc(host: string, alpn: []string) -> []byte {
	h: Hello
	hello_init(&h, host, alpn)
	defer hello_destroy(&h)
	hs: [dynamic]byte
	defer delete(hs)
	build_client_hello(&h, &hs)
	rec: [dynamic]byte
	put_u8(&rec, CT_HANDSHAKE)
	put_u16(&rec, 0x0301)
	put_u16(&rec, u16(len(hs)))
	put_bytes(&rec, hs[:])
	return rec[:]
}

// check_shape compares one of our hellos with one captured from Chrome.
@(private)
check_shape :: proc(t: ^testing.T, ours_raw, chrome_raw: []byte) {
	ours, ok1 := parse_hello(t, ours_raw)
	defer parsed_destroy(&ours)
	chrome, ok2 := parse_hello(t, chrome_raw)
	defer parsed_destroy(&chrome)
	if !testing.expect(t, ok1 && ok2, "hello parse failed") do return

	testing.expect_value(t, ours.record_version, chrome.record_version)
	testing.expect_value(t, len(ours.session_id), len(chrome.session_id))

	// Ciphers: GREASE first, then Chrome's exact list.
	for p in ([]^Parsed{&ours, &chrome}) {
		testing.expect(t, is_grease(p.ciphers[0]), "cipher[0] not GREASE")
		testing.expect(t, slice.equal(p.ciphers[1:], CHROME_CIPHERS[:]), "cipher list differs")
	}

	// GREASE extensions first (empty) and last (one zero byte), distinct, never elsewhere.
	for p in ([]^Parsed{&ours, &chrome}) {
		first, last := p.exts[0], p.exts[len(p.exts) - 1]
		testing.expect(t, is_grease(first.id) && len(first.data) == 0, "first ext")
		testing.expect(t, is_grease(last.id) && slice.equal(last.data, []byte{0}), "last ext")
		testing.expect(t, first.id != last.id, "GREASE exts equal")
		for e in p.exts[1:len(p.exts) - 1] do testing.expect(t, !is_grease(e.id), "GREASE in middle")
	}

	// Same extension set.
	ids :: proc(p: ^Parsed) -> [dynamic]u16 {
		out: [dynamic]u16
		for e in p.exts[1:len(p.exts) - 1] do append(&out, e.id)
		slice.sort(out[:])
		return out
	}
	a, b := ids(&ours), ids(&chrome)
	defer delete(a)
	defer delete(b)
	testing.expectf(t, slice.equal(a[:], b[:]), "extension sets differ: %x vs %x", a[:], b[:])

	// Per-extension content.
	for e in chrome.exts[1:len(chrome.exts) - 1] {
		mine, found := find_ext(&ours, e.id)
		if !found do continue
		switch e.id {
		case EXT_SUPPORTED_GROUPS, EXT_SUPPORTED_VERSIONS:
			pre := 2 if e.id == EXT_SUPPORTED_GROUPS else 1
			x, y := u16_list(mine, pre), u16_list(e.data, pre)
			testing.expectf(t, slice.equal(x[:], y[:]), "ext %04x: %x vs %x", e.id, x[:], y[:])
			delete(x)
			delete(y)
		case EXT_KEY_SHARE:
			x, y := share_shape(mine), share_shape(e.data)
			testing.expectf(t, slice.equal(x[:], y[:]), "key_share shape: %v vs %v", x[:], y[:])
			delete(x)
			delete(y)
		case EXT_ECH:
			testing.expect(t, slice.equal(mine[:5], e.data[:5]), "ECH type/kdf/aead")
			testing.expect(t, slice.equal(mine[6:8], e.data[6:8]), "ECH enc length")
			pl := ech_payload_len(mine)
			testing.expectf(t, pl == 144 || pl == 176 || pl == 208 || pl == 240, "ECH payload %d", pl)
		case:
			testing.expectf(t, slice.equal(mine, e.data), "ext %04x: %x vs %x", e.id, mine, e.data)
		}
	}

	// GREASE group in supported_groups equals the GREASE key share group (BoringSSL reuses it).
	for p in ([]^Parsed{&ours, &chrome}) {
		g, _ := find_ext(p, EXT_SUPPORTED_GROUPS)
		k, _ := find_ext(p, EXT_KEY_SHARE)
		testing.expect(t, g[2] == k[2] && g[3] == k[3], "GREASE group vs share")
	}

	// Length matches exactly once the random ECH payload size is factored out.
	ce, _ := find_ext(&chrome, EXT_ECH)
	oe, _ := find_ext(&ours, EXT_ECH)
	testing.expect_value(t, ours.hs_len - ech_payload_len(oe), chrome.hs_len - ech_payload_len(ce))
}

@(test)
hello_matches_chrome_discord_com :: proc(t: ^testing.T) {
	for fx in CHROME_DISCORD_COM {
		ours := our_hello("discord.com", {"h2", "http/1.1"})
		defer delete(ours)
		check_shape(t, ours, fx)
	}
}

@(test)
hello_matches_chrome_gateway :: proc(t: ^testing.T) {
	for fx in CHROME_GATEWAY {
		ours := our_hello("gateway.discord.gg", {"http/1.1"})
		defer delete(ours)
		check_shape(t, ours, fx)
	}
}

@(test)
hello_permutes_extensions :: proc(t: ^testing.T) {
	seen_orders: [dynamic]u64
	defer delete(seen_orders)
	for _ in 0 ..< 20 {
		raw := our_hello("discord.com", {"h2", "http/1.1"})
		defer delete(raw)
		p, ok := parse_hello(t, raw)
		defer parsed_destroy(&p)
		testing.expect(t, ok)
		key: u64 = 1469598103934665603
		for e in p.exts[1:len(p.exts) - 1] do key = (key ~ u64(e.id)) * 1099511628211
		if !slice.contains(seen_orders[:], key) do append(&seen_orders, key)
	}
	testing.expectf(t, len(seen_orders) > 15, "only %d distinct orders", len(seen_orders))
}

// After a HelloRetryRequest, ClientHello2 keeps random, session id, GREASE,
// order and ECH bytes; the key share becomes just the requested group and
// a cookie is added. BoringSSL drops the GREASE key share in ClientHello2.
@(test)
hello_retry_keeps_shape :: proc(t: ^testing.T) {
	h: Hello
	hello_init(&h, "discord.com", {"h2", "http/1.1"})
	defer hello_destroy(&h)
	b1: [dynamic]byte
	defer delete(b1)
	build_client_hello(&h, &b1)

	h.retried = true
	h.hrr_group = GROUP_SECP256R1
	testing.expect(t, ecdh.private_key_generate(&h.hrr_priv, .SECP256R1))
	h.cookie = clone_bytes({1, 2, 3})
	b2: [dynamic]byte
	defer delete(b2)
	build_client_hello(&h, &b2)

	wrap :: proc(hs: []byte) -> []byte {
		rec: [dynamic]byte
		put_u8(&rec, CT_HANDSHAKE)
		put_u16(&rec, 0x0303)
		put_u16(&rec, u16(len(hs)))
		put_bytes(&rec, hs)
		return rec[:]
	}
	r1, r2 := wrap(b1[:]), wrap(b2[:])
	defer delete(r1)
	defer delete(r2)
	p1, _ := parse_hello(t, r1)
	p2, _ := parse_hello(t, r2)
	defer parsed_destroy(&p1)
	defer parsed_destroy(&p2)
	testing.expect(t, slice.equal(b1[6:38], b2[6:38]), "random changed")
	testing.expect(t, slice.equal(p1.session_id, p2.session_id), "session id changed")
	testing.expect(t, slice.equal(p1.ciphers[:], p2.ciphers[:]))

	order2: [dynamic]u16
	defer delete(order2)
	for e in p2.exts do if e.id != EXT_COOKIE do append(&order2, e.id)
	order1: [dynamic]u16
	defer delete(order1)
	for e in p1.exts do append(&order1, e.id)
	testing.expect(t, slice.equal(order1[:], order2[:]), "extension order changed")

	e1, _ := find_ext(&p1, EXT_ECH)
	e2, _ := find_ext(&p2, EXT_ECH)
	testing.expect(t, slice.equal(e1, e2), "ECH GREASE changed")
	c, has_cookie := find_ext(&p2, EXT_COOKIE)
	testing.expect(t, has_cookie && slice.equal(c, []byte{0, 3, 1, 2, 3}), "cookie")
	ks, _ := find_ext(&p2, EXT_KEY_SHARE)
	shape := share_shape(ks)
	defer delete(shape)
	testing.expect(t, slice.equal(shape[:], [][2]int{{GROUP_SECP256R1, 65}}), "HRR key share")
}

@(test)
hello_no_sni_for_ip :: proc(t: ^testing.T) {
	raw := our_hello("127.0.0.1", {"http/1.1"})
	defer delete(raw)
	p, ok := parse_hello(t, raw)
	defer parsed_destroy(&p)
	testing.expect(t, ok)
	_, has := find_ext(&p, EXT_SERVER_NAME)
	testing.expect(t, !has)
}
