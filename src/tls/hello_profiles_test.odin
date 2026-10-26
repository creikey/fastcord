package tls

import "core:slice"
import "core:testing"
import "core:time"

CHROME_GATEWAY_RESUMED :: #load("testdata/chrome_gateway_resumed.bin")
// QUIC hellos are raw handshake messages (CRYPTO stream data), captured from
// the official client's HTTP/3 connections to discord.com.
CHROME_QUIC_FULL :: #load("testdata/chrome_quic_ch_full.bin")
CHROME_QUIC_RESUMED :: #load("testdata/chrome_quic_ch_resumed.bin")

@(private = "file")
as_record :: proc(hs: []byte) -> []byte {
	rec: [dynamic]byte
	put_u8(&rec, CT_HANDSHAKE)
	put_u16(&rec, 0x0301)
	put_u16(&rec, u16(len(hs)))
	put_bytes(&rec, hs)
	return rec[:]
}

// fake_ticket mimics the captured ticket size so lengths line up.
@(private = "file")
fake_ticket :: proc(ticket_len: int) -> Ticket {
	t := Ticket {
		lifetime  = 3600,
		suite     = 0x1301,
		psk_len   = 32,
		max_early = 0xffffffff,
		received  = time.now(),
	}
	t.ticket = make([]byte, ticket_len)
	return t
}

@(private = "file")
build :: proc(host: string, alpn: []string, quic: bool, quic_params: []byte, psk: ^Ticket) -> []byte {
	h: Hello
	h.quic = quic
	h.quic_params = quic_params
	hello_init(&h, host, alpn)
	defer hello_destroy(&h)
	h.psk = psk
	h.early_data = quic && psk != nil
	hs: [dynamic]byte
	defer delete(hs)
	build_client_hello(&h, &hs)
	return as_record(hs[:])
}

@(private = "file")
psk_shape :: proc(d: []byte) -> (ticket_len, binder_len: int) {
	r := reader(d)
	ids := reader(r_vec16(&r))
	binders := reader(r_vec16(&r))
	ticket_len = len(r_vec16(&ids))
	binder_len = len(r_vec8(&binders))
	return
}

// compare checks one of our hellos against a Chrome capture: same extension
// set, deterministic extension bodies byte-identical, structured ones
// (key_share, ECH, QUIC transport parameters, PSK) by shape, and the total
// length once random-size fields are factored out.
@(private = "file")
compare :: proc(t: ^testing.T, ours_raw, chrome_raw: []byte, quic: bool) {
	ours, ok1 := parse_hello(t, ours_raw)
	defer parsed_destroy(&ours)
	chrome, ok2 := parse_hello(t, chrome_raw)
	defer parsed_destroy(&chrome)
	if !testing.expect(t, ok1 && ok2, "hello parse failed") do return
	testing.expect_value(t, len(ours.session_id), len(chrome.session_id))
	norm :: proc(cs: []u16) -> [dynamic]u16 {
		out: [dynamic]u16
		for c in cs do append(&out, 0x0a0a if is_grease(c) else c)
		return out
	}
	oc, cc := norm(ours.ciphers[:]), norm(chrome.ciphers[:])
	defer delete(oc)
	defer delete(cc)
	testing.expectf(t, slice.equal(oc[:], cc[:]), "ciphers %x vs %x", oc[:], cc[:])

	// pre_shared_key must be last in both.
	for p in ([]^Parsed{&ours, &chrome}) {
		_, has := find_ext(p, EXT_PRE_SHARED_KEY)
		if has do testing.expect_value(t, p.exts[len(p.exts) - 1].id, u16(EXT_PRE_SHARED_KEY))
	}
	ids :: proc(p: ^Parsed) -> [dynamic]u16 {
		out: [dynamic]u16
		for e in p.exts do append(&out, 0x0a0a if is_grease(e.id) else e.id)
		slice.sort(out[:])
		return out
	}
	a, b := ids(&ours), ids(&chrome)
	defer delete(a)
	defer delete(b)
	testing.expectf(t, slice.equal(a[:], b[:]), "extension sets differ: %x vs %x", a[:], b[:])

	random_len := 0 // bytes whose size is random per connection
	for e in chrome.exts {
		if is_grease(e.id) do continue
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
			random_len += ech_payload_len(mine) - ech_payload_len(e.data)
		case EXT_QUIC_TRANSPORT_PARAMETERS:
			random_len += len(mine) - len(e.data)
		case EXT_PRE_SHARED_KEY:
			ot, ob := psk_shape(mine)
			ct, cb := psk_shape(e.data)
			testing.expect_value(t, ot, ct)
			testing.expect_value(t, ob, cb)
		case:
			testing.expectf(t, slice.equal(mine, e.data), "ext %04x: %x vs %x", e.id, mine, e.data)
		}
	}
	testing.expect_value(t, ours.hs_len - random_len, chrome.hs_len)
	if quic do for e in ours.exts do testing.expect(t, !is_grease(e.id), "GREASE ext under QUIC")
}

@(test)
hello_resumed_matches_chrome_gateway :: proc(t: ^testing.T) {
	tk := fake_ticket(192)
	defer delete(tk.ticket)
	ours := build("gateway.discord.gg", {"http/1.1"}, false, nil, &tk)
	defer delete(ours)
	compare(t, ours, CHROME_GATEWAY_RESUMED, false)
}

// The QUIC transport parameters are produced by fc:quic; any 77-byte blob
// stands in here, the quic package tests their content.
@(test)
hello_quic_matches_chrome :: proc(t: ^testing.T) {
	params: [77]byte
	ours := build("discord.com", {"h3"}, true, params[:], nil)
	defer delete(ours)
	chrome := as_record(CHROME_QUIC_FULL)
	defer delete(chrome)
	compare(t, ours, chrome, true)
}

@(test)
hello_quic_resumed_matches_chrome :: proc(t: ^testing.T) {
	tk := fake_ticket(208)
	defer delete(tk.ticket)
	params: [77]byte
	ours := build("discord.com", {"h3"}, true, params[:], &tk)
	defer delete(ours)
	chrome := as_record(CHROME_QUIC_RESUMED)
	defer delete(chrome)
	compare(t, ours, chrome, true)
}
