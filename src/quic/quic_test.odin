package quic

import "core:log"
import "core:net"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import "core:time"

import "fc:http"

// The official client's first two datagrams to discord.com (Chrome 148), and the same connection's
// ClientHello, reassembled.
CHROME_INITIAL_1 :: #load("testdata/chrome_initial_1.bin")
CHROME_INITIAL_2 :: #load("testdata/chrome_initial_2.bin")
CHROME_QUIC_CH :: #load("../tls/testdata/chrome_quic_ch_full.bin")

@(private = "file")
varint :: proc(b: ^[]byte) -> (v: u64, ok: bool) {
	if len(b) == 0 do return 0, false
	n := 1 << (b[0] >> 6)
	if len(b) < n do return 0, false
	v = u64(b[0] & 0x3f)
	for i in 1 ..< n do v = v << 8 | u64(b[i])
	b^ = b[n:]
	return v, true
}

@(private = "file")
tp_map :: proc(b: []byte) -> map[u64][]byte {
	m := make(map[u64][]byte, context.temp_allocator)
	r := b
	for len(r) > 0 {
		id, ok1 := varint(&r)
		l, ok2 := varint(&r)
		if !ok1 || !ok2 || l > u64(len(r)) do break
		m[id] = r[:l]
		r = r[l:]
	}
	return m
}

@(private = "file")
is_grease_tp :: proc(id: u64) -> bool {return id >= 27 && (id - 27) % 31 == 0}

// find_qtp returns the quic_transport_parameters extension of a ClientHello.
@(private = "file")
find_qtp :: proc(ch: []byte) -> []byte {
	// type(1) len(3) version(2) random(32) session id(1+n) ciphers(2+n) compression(1+n) extensions(2)
	p := 4 + 2 + 32
	p += 1 + int(ch[p])
	p += 2 + (int(ch[p]) << 8 | int(ch[p + 1]))
	p += 1 + int(ch[p])
	end := p + 2 + (int(ch[p]) << 8 | int(ch[p + 1]))
	p += 2
	for p < end {
		typ := int(ch[p]) << 8 | int(ch[p + 1])
		l := int(ch[p + 2]) << 8 | int(ch[p + 3])
		if typ == 0x39 do return ch[p + 4:][:l]
		p += 4 + l
	}
	return nil
}

// Our transport parameters are Chrome's: the same ids and bytes, one GREASE parameter, a GREASE version.
@(test)
transport_params_match_chrome :: proc(t: ^testing.T) {
	chrome := tp_map(find_qtp(CHROME_QUIC_CH))
	testing.expect(t, len(chrome) > 10, "no parameters in the capture")
	for _ in 0 ..< 20 {
		ours := tp_map(chrome_transport_params(0, context.temp_allocator))
		testing.expect_value(t, len(ours), len(chrome))
		grease := 0
		for id, v in ours {
			if is_grease_tp(id) {
				grease += 1
				testing.expect(t, len(v) < 16)
				continue
			}
			cv, found := chrome[id]
			testing.expectf(t, found, "param %x is not in Chrome's hello", id)
			if id == 0x11 {
				testing.expect(t, slice.equal(v[:8], cv[:8]) && len(v) == len(cv), "version_information")
				testing.expect(t, v[8] & 0x0f == 0x0a && v[11] & 0x0f == 0x0a, "GREASE version")
			} else {
				testing.expectf(t, slice.equal(v, cv), "param %x: %x vs Chrome's %x", id, v, cv)
			}
		}
		testing.expect_value(t, grease, 1)
	}
	rtt := tp_map(chrome_transport_params(61662, context.temp_allocator))
	testing.expect(t, slice.equal(rtt[0x3127], []byte{0x80, 0x00, 0xf0, 0xde}), "initial_rtt")
}

// Initial_Header is the unprotected part of a client Initial's long header.
@(private = "file")
Initial_Header :: struct {
	size, form, version, dcid_len, scid_len, token_len, rest: int,
}

@(private = "file")
initial_header :: proc(d: []byte) -> (h: Initial_Header) {
	h.size = len(d)
	h.form = int(d[0] & 0xf0) // protected low bits differ per packet
	h.version = int(d[1]) << 24 | int(d[2]) << 16 | int(d[3]) << 8 | int(d[4])
	h.dcid_len = int(d[5])
	h.scid_len = int(d[6 + h.dcid_len])
	r := d[7 + h.dcid_len + h.scid_len:]
	tl, _ := varint(&r)
	h.token_len = int(tl)
	l, _ := varint(&r)
	h.rest = int(l) - len(r) // 0 when the packet fills the rest of the datagram
	return
}

// The first flight has the envelope of Chrome's: two 1250-byte datagrams, each one Initial with an 8-byte
// destination CID, an empty source CID and no token. The frames inside are ngtcp2's, not Chrome's.
@(test)
initials_match_chrome_envelope :: proc(t: ^testing.T) {
	sock, err := net.make_bound_udp_socket(net.IP4_Loopback, 0)
	if !testing.expect(t, err == nil) do return
	defer net.close(sock)
	ep, _ := net.bound_endpoint(sock)
	net.set_option(sock, .Receive_Timeout, 2 * time.Second)
	c, derr := dial("discord.com", ep.port, net.IP4_Loopback)
	if !testing.expect_value(t, derr, http.Error.None) do return
	defer close(c)
	buf: [2048]byte
	for want in ([][]byte{CHROME_INITIAL_1, CHROME_INITIAL_2}) {
		n, _, rerr := net.recv_udp(sock, buf[:])
		if !testing.expect(t, rerr == nil) do return
		testing.expect_value(t, initial_header(buf[:n]), initial_header(want))
	}
}

// GET /api/v9/experiments over HTTP/3 against discord.com, twice on one connection, then on a second
// connection that resumes the TLS session. Read-only; FASTCORD_LIVE=1 only.
@(test)
live_h3_experiments :: proc(t: ^testing.T) {
	if os.get_env("FASTCORD_LIVE", context.temp_allocator) != "1" do return
	for round in 0 ..< 2 {
		c, err := connect("discord.com")
		if !testing.expectf(t, err == .None, "round %d connect: %v", round, err) do return
		for i in 0 ..< 2 {
			req := http.Request {
				method    = "GET",
				scheme    = "https",
				authority = "discord.com",
				path      = "/api/v9/experiments",
				headers   = {{"accept", "*/*"}, {"accept-encoding", "gzip, deflate, br, zstd"}, {"accept-language", "en-US"}},
			}
			resp, rerr := request(c, req)
			defer http.response_destroy(&resp)
			if !testing.expectf(t, rerr == .None, "round %d request %d: %v", round, i, rerr) do break
			testing.expect_value(t, resp.status, 200)
			testing.expect(t, http.decode_body(&resp) == .None)
			body := string(resp.body[:])
			testing.expectf(t, strings.contains(body, "fingerprint") || strings.contains(body, "assignments"), "body %q", body[:min(len(body), 200)])
			log.infof("h3 round %d request %d: %d, %d bytes", round, i, resp.status, len(resp.body))
		}
		close(c)
	}
	testing.expect(t, cached_rtt_us("discord.com") > 0, "no RTT remembered")
	// A server whose certificate is not valid for the name (Google's, which speaks QUIC) fails.
	google, _, rerr := net.resolve("www.google.com")
	if !testing.expect(t, rerr == nil) do return
	start := time.tick_now()
	c, err := connect("discord.com", 443, google.address)
	testing.expectf(t, c == nil && err == .Protocol, "wrong certificate: %v", err)
	testing.expect(t, time.tick_since(start) < 5 * time.Second, "failed by timeout, not by the certificate check")
}
