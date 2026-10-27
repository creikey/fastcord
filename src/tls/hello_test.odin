package tls

import "core:slice"
import "core:testing"

import "fc:locks"
import "fc:netio"

// Captured from the official Discord client (Electron 42.11.15 / Chrome 148, macOS arm64) via
// --host-resolver-rules pointing at a local listener. QUIC hellos are raw handshake messages (CRYPTO
// stream data) from its HTTP/3 connections to discord.com.
CHROME_DISCORD_COM := [?][]byte {
	#load("testdata/chrome_discord_com_1.bin"),
	#load("testdata/chrome_discord_com_2.bin"),
	#load("testdata/chrome_discord_com_3.bin"),
}
CHROME_GATEWAY := [?][]byte{#load("testdata/chrome_gateway_1.bin"), #load("testdata/chrome_gateway_2.bin")}
CHROME_GATEWAY_RESUMED :: #load("testdata/chrome_gateway_resumed.bin")
CHROME_QUIC_FULL :: #load("testdata/chrome_quic_ch_full.bin")
CHROME_QUIC_RESUMED :: #load("testdata/chrome_quic_ch_resumed.bin")

// Tests that make client SSLs hold this: they share the session cache and quic_boxes.
cache_test_mu: locks.Mutex

EXT_SERVER_NAME :: 0x0000
EXT_SUPPORTED_GROUPS :: 0x000a
EXT_SIGNATURE_ALGORITHMS :: 0x000d
EXT_PRE_SHARED_KEY :: 0x0029
EXT_SUPPORTED_VERSIONS :: 0x002b
EXT_KEY_SHARE :: 0x0033
EXT_QUIC_TRANSPORT_PARAMETERS :: 0x0039
EXT_ECH :: 0xfe0d

@(private = "file")
Rd :: struct {
	b:  []byte,
	ok: bool,
}

@(private = "file")
take :: proc(r: ^Rd, n: int) -> []byte {
	if !r.ok || n > len(r.b) {
		r.ok = false
		return nil
	}
	out := r.b[:n]
	r.b = r.b[n:]
	return out
}

@(private = "file")
be :: proc(r: ^Rd, n: int) -> (v: int) {
	for x in take(r, n) do v = v << 8 | int(x)
	return
}

@(private = "file")
vec :: proc(r: ^Rd, w: int) -> []byte {return take(r, be(r, w))}

@(private = "file")
is_grease :: proc(v: u16) -> bool {return v & 0x0f0f == 0x0a0a && v >> 8 == v & 0xff}

@(private = "file")
Ext :: struct {
	id:   u16,
	data: []byte,
}

@(private = "file")
Parsed :: struct {
	record_version: u16,
	hs_len:         int,
	session_id:     []byte,
	ciphers:        [dynamic]u16,
	exts:           [dynamic]Ext,
}

@(private = "file")
parse_hello :: proc(rec: []byte) -> (p: Parsed, ok: bool) {
	r := Rd{rec, true}
	if be(&r, 1) != 22 do return
	p.record_version = u16(be(&r, 2))
	body := Rd{vec(&r, 2), true}
	if !r.ok || len(r.b) != 0 || be(&body, 1) != 1 do return
	p.hs_len = be(&body, 3)
	if p.hs_len != len(body.b) || be(&body, 2) != 0x0303 do return
	take(&body, 32)
	p.session_id = vec(&body, 1)
	cs := Rd{vec(&body, 2), true}
	for len(cs.b) >= 2 do append(&p.ciphers, u16(be(&cs, 2)))
	comp := vec(&body, 1)
	if len(comp) != 1 || comp[0] != 0 do return
	exts := Rd{vec(&body, 2), true}
	if !body.ok || len(body.b) != 0 do return
	for exts.ok && len(exts.b) > 0 {
		id := u16(be(&exts, 2))
		append(&p.exts, Ext{id, vec(&exts, 2)})
	}
	return p, exts.ok && len(cs.b) == 0
}

@(private = "file")
parsed_destroy :: proc(p: ^Parsed) {
	delete(p.ciphers)
	delete(p.exts)
}

@(private = "file")
find_ext :: proc(p: ^Parsed, id: u16) -> ([]byte, bool) {
	for e in p.exts do if e.id == id do return e.data, true
	return nil, false
}

// u16_list reads a u16 vector with GREASE values normalised to 0x0a0a.
@(private = "file")
u16_list :: proc(b: []byte, prefix: int) -> [dynamic]u16 {
	out: [dynamic]u16
	r := Rd{b, true}
	take(&r, prefix)
	for len(r.b) >= 2 {
		v := u16(be(&r, 2))
		append(&out, 0x0a0a if is_grease(v) else v)
	}
	return out
}

// share_shape lists the (group, key length) pairs of a key_share extension.
@(private = "file")
share_shape :: proc(b: []byte) -> [dynamic][2]int {
	out: [dynamic][2]int
	r := Rd{b, true}
	take(&r, 2)
	for r.ok && len(r.b) > 0 {
		g := u16(be(&r, 2))
		append(&out, [2]int{0x0a0a if is_grease(g) else int(g), len(vec(&r, 2))})
	}
	return out
}

@(private = "file")
ech_payload_len :: proc(b: []byte) -> int {
	r := Rd{b, true}
	take(&r, 6)
	vec(&r, 2)
	return len(vec(&r, 2))
}

@(private = "file")
psk_shape :: proc(d: []byte) -> (ticket_len, binder_len: int) {
	r := Rd{d, true}
	ids := Rd{vec(&r, 2), true}
	binders := Rd{vec(&r, 2), true}
	return len(vec(&ids, 2)), len(vec(&binders, 1))
}

@(private = "file")
as_record :: proc(hs: []byte) -> []byte {
	rec := make([]byte, 5 + len(hs))
	copy(rec, []byte{22, 3, 1, u8(len(hs) >> 8), u8(len(hs))})
	copy(rec[5:], hs)
	return rec
}

// our_hello returns the first flight of a client SSL made by new_ssl, as a TLS record.
@(private = "file")
our_hello :: proc(host: string, alpn: []string, quic := false, insecure := false) -> []byte {
	ctx := new_ctx(true) if quic else tcp_ctx
	defer if quic do SSL_CTX_free(ctx)
	ssl := new_ssl(ctx, {alpn = alpn, server_name = host, insecure_skip_verify = insecure}, quic)
	assert(ssl != nil)
	if quic {
		box: Quic_Box
		params: [77]byte // fc:quic produces the real ones; any 77 bytes stand in.
		quic_attach(ssl, &box, params[:])
		SSL_do_handshake(ssl)
		out := as_record(box.level[0][:])
		quic_detach(ssl, &box)
		SSL_free(ssl)
		return out
	}
	s := session_new(ssl, {}, context.allocator)
	defer destroy(s)
	SSL_do_handshake(ssl)
	status_locked(s, 1)
	return slice.clone(s.out[:])
}

@(private = "file")
cache_drain :: proc(host: string, quic: bool) {
	for sess := cache_take(host, quic); sess != nil; sess = cache_take(host, quic) do SSL_SESSION_free(sess)
}

// compare checks one of our hellos against a Chrome capture: the same cipher list and extension set,
// deterministic extension bodies byte-identical, structured ones (key_share, ECH, QUIC transport
// parameters, PSK) by shape, and the total length once random-size fields are factored out.
@(private = "file")
compare :: proc(t: ^testing.T, ours_raw, chrome_raw: []byte, quic: bool) {
	ours, ok1 := parse_hello(ours_raw)
	defer parsed_destroy(&ours)
	chrome, ok2 := parse_hello(chrome_raw)
	defer parsed_destroy(&chrome)
	if !testing.expect(t, ok1 && ok2, "hello parse failed") do return
	testing.expect_value(t, ours.record_version, chrome.record_version)
	testing.expect_value(t, len(ours.session_id), len(chrome.session_id))

	norm :: proc(xs: []u16, sorted: bool) -> [dynamic]u16 {
		out: [dynamic]u16
		for x in xs do append(&out, 0x0a0a if is_grease(x) else x)
		if sorted do slice.sort(out[:])
		return out
	}
	oc, cc := norm(ours.ciphers[:], false), norm(chrome.ciphers[:], false)
	defer delete(oc)
	defer delete(cc)
	testing.expectf(t, slice.equal(oc[:], cc[:]), "ciphers %x vs %x", oc[:], cc[:])

	ids :: proc(p: ^Parsed) -> [dynamic]u16 {
		out: [dynamic]u16
		for e in p.exts do append(&out, e.id)
		return out
	}
	ao, ac := ids(&ours), ids(&chrome)
	defer delete(ao)
	defer delete(ac)
	a, b := norm(ao[:], true), norm(ac[:], true)
	defer delete(a)
	defer delete(b)
	testing.expectf(t, slice.equal(a[:], b[:]), "extension sets differ: %x vs %x", a[:], b[:])

	for p in ([]^Parsed{&ours, &chrome}) {
		last := len(p.exts) - 1
		if _, has := find_ext(p, EXT_PRE_SHARED_KEY); has {
			testing.expect_value(t, p.exts[last].id, u16(EXT_PRE_SHARED_KEY))
			last -= 1
		}
		if quic {
			for e in p.exts do testing.expect(t, !is_grease(e.id), "GREASE extension under QUIC")
			continue
		}
		// One empty GREASE extension first, one holding a zero byte last.
		first, end := p.exts[0], p.exts[last]
		testing.expect(t, is_grease(first.id) && len(first.data) == 0, "first extension")
		testing.expect(t, is_grease(end.id) && slice.equal(end.data, []byte{0}), "last extension")
		// The GREASE group in supported_groups is the GREASE key share's.
		g, _ := find_ext(p, EXT_SUPPORTED_GROUPS)
		k, _ := find_ext(p, EXT_KEY_SHARE)
		testing.expect(t, g[2] == k[2] && g[3] == k[3], "GREASE group vs share")
	}

	random_len := 0 // Bytes whose count is random per connection.
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
		case EXT_SIGNATURE_ALGORITHMS:
			// Known difference: BoringSSL since 2026-10 always adds a GREASE value here when GREASE is
			// on, which Chrome 148 did not yet send. JA3 and JA4 both drop GREASE values.
			x, y := u16_list(mine, 2), u16_list(e.data, 2)
			if len(x) > 0 && x[0] == 0x0a0a {
				ordered_remove(&x, 0)
				random_len += 2
			}
			testing.expectf(t, slice.equal(x[:], y[:]), "sigalgs: %x vs %x", x[:], y[:])
			delete(x)
			delete(y)
		case EXT_KEY_SHARE:
			x, y := share_shape(mine), share_shape(e.data)
			testing.expectf(t, slice.equal(x[:], y[:]), "key_share shape: %v vs %v", x[:], y[:])
			delete(x)
			delete(y)
		case EXT_ECH:
			testing.expect(t, slice.equal(mine[:3], e.data[:3]) && slice.equal(mine[6:8], e.data[6:8]), "ECH type/kdf/enc")
			// Known difference: with OPENSSL_NO_ASM, BoringSSL sees no AES hardware and picks
			// ChaCha20-Poly1305 (3) for ECH GREASE where Chrome picks AES-128-GCM (1). Same length.
			aead := u16(mine[3]) << 8 | u16(mine[4])
			testing.expectf(t, aead == 1 || aead == 3, "ECH aead %d", aead)
			random_len += ech_payload_len(mine) - ech_payload_len(e.data)
		case EXT_QUIC_TRANSPORT_PARAMETERS:
			random_len += len(mine) - len(e.data)
		case EXT_PRE_SHARED_KEY:
			ot, ob := psk_shape(mine)
			ct, cb := psk_shape(e.data)
			testing.expect_value(t, ob, cb)
			random_len += ot - ct
		case:
			testing.expectf(t, slice.equal(mine, e.data), "ext %04x: %x vs %x", e.id, mine, e.data)
		}
	}
	testing.expect_value(t, ours.hs_len - random_len, chrome.hs_len)
}

@(test)
hello_matches_chrome_discord_com :: proc(t: ^testing.T) {
	locks.guard(&cache_test_mu)
	for fx in CHROME_DISCORD_COM {
		ours := our_hello("discord.com", {"h2", "http/1.1"})
		defer delete(ours)
		compare(t, ours, fx, false)
	}
}

@(test)
hello_matches_chrome_gateway :: proc(t: ^testing.T) {
	locks.guard(&cache_test_mu)
	for fx in CHROME_GATEWAY {
		ours := our_hello("gateway.discord.gg", {"http/1.1"})
		defer delete(ours)
		compare(t, ours, fx, false)
	}
}

@(test)
hello_permutes_extensions :: proc(t: ^testing.T) {
	locks.guard(&cache_test_mu)
	seen: [dynamic]u64
	defer delete(seen)
	for _ in 0 ..< 20 {
		raw := our_hello("discord.com", {"h2", "http/1.1"})
		defer delete(raw)
		p, ok := parse_hello(raw)
		defer parsed_destroy(&p)
		testing.expect(t, ok)
		key: u64 = 1469598103934665603
		for e in p.exts[1:len(p.exts) - 1] do key = (key ~ u64(e.id)) * 1099511628211
		if !slice.contains(seen[:], key) do append(&seen, key)
	}
	testing.expectf(t, len(seen) > 15, "only %d distinct orders", len(seen))
}

@(test)
hello_no_sni_for_ip :: proc(t: ^testing.T) {
	locks.guard(&cache_test_mu)
	raw := our_hello("127.0.0.1", {"http/1.1"})
	defer delete(raw)
	p, ok := parse_hello(raw)
	defer parsed_destroy(&p)
	testing.expect(t, ok)
	_, has := find_ext(&p, EXT_SERVER_NAME)
	testing.expect(t, !has)
}

@(test)
hello_resumed_matches_chrome_gateway :: proc(t: ^testing.T) {
	locks.guard(&cache_test_mu)
	defer cache_drain("insecure gateway.discord.gg", false)
	lb: Loopback
	s, err := loopback_connect(&lb, {alpn = {"http/1.1"}, server_name = "gateway.discord.gg", insecure_skip_verify = true})
	defer loopback_destroy(&lb)
	if !testing.expect_value(t, err, netio.Error.None) do return
	// The server's tickets arrive with its first application data.
	testing.expect_value(t, write(lb.server, {1}), Error.None)
	buf: [1]byte
	_, rerr := read(s, buf[:])
	testing.expect_value(t, rerr, Error.None)
	close(s)
	ours := our_hello("gateway.discord.gg", {"http/1.1"}, insecure = true)
	defer delete(ours)
	compare(t, ours, CHROME_GATEWAY_RESUMED, false)
}

@(test)
hello_quic_matches_chrome :: proc(t: ^testing.T) {
	locks.guard(&cache_test_mu)
	ours := our_hello("discord.com", {"h3"}, quic = true)
	defer delete(ours)
	chrome := as_record(CHROME_QUIC_FULL)
	defer delete(chrome)
	compare(t, ours, chrome, true)
}

@(test)
hello_quic_resumed_matches_chrome :: proc(t: ^testing.T) {
	locks.guard(&cache_test_mu)
	defer cache_drain("insecure discord.com", true)
	testing.expect(t, quic_handshake("discord.com"), "QUIC handshake failed")
	ours := our_hello("discord.com", {"h3"}, quic = true, insecure = true)
	defer delete(ours)
	chrome := as_record(CHROME_QUIC_RESUMED)
	defer delete(chrome)
	compare(t, ours, chrome, true)
}

// quic_handshake runs a full QUIC-flavoured handshake against the test server, leaving its tickets in
// the session cache.
@(private = "file")
quic_handshake :: proc(host: string) -> bool {
	cctx := new_ctx(true)
	defer SSL_CTX_free(cctx)
	sctx := test_server_ctx(quic = true)
	defer SSL_CTX_free(sctx)
	cl := new_ssl(cctx, {alpn = {"h3"}, server_name = host, insecure_skip_verify = true}, true)
	sv := SSL_new(sctx)
	SSL_set_accept_state(sv)
	params: [77]byte
	cb, sb: Quic_Box
	quic_attach(cl, &cb, params[:])
	quic_attach(sv, &sb, params[:])
	ok := SSL_set_quic_early_data_context(sv, &params[0], 1) == 1
	SSL_do_handshake(cl)
	for _ in 0 ..< 4 do ok = ok && quic_deliver(&cb, sv) && quic_deliver(&sb, cl)
	ok = ok && SSL_in_init(cl) == 0 && SSL_in_init(sv) == 0
	quic_detach(cl, &cb)
	quic_detach(sv, &sb)
	SSL_free(cl)
	SSL_free(sv)
	return ok
}
