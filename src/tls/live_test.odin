package tls

import "core:bytes"
import "core:log"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

import "fc:netio"

// Live tests hit Cloudflare; run with FASTCORD_LIVE=1.
@(private = "file")
live :: proc() -> bool {
	return os.get_env("FASTCORD_LIVE", context.temp_allocator) == "1"
}

@(private = "file")
dial :: proc(t: ^testing.T, host: string, alpn: []string) -> ^Session {
	tcp, err := netio.dial_tcp(host, 443)
	if !testing.expect_value(t, err, netio.Error.None) do return nil
	netio.tcp_set_read_timeout(tcp, 10 * time.Second)
	under := netio.tcp_stream(tcp)
	s, terr := connect(under, {alpn = alpn, server_name = host})
	if terr != .None {
		testing.expectf(t, false, "connect %s: %v / %v", host, terr, last_error())
		netio.close(under)
		return nil
	}
	log.infof("%s: suite=%04x group=%04x alpn=%q alps=%v", host, negotiated_suite(s), negotiated_group(s), negotiated_alpn(s), s.alps)
	return s
}

// http1_get sends GET / and returns the response head.
@(private = "file")
http1_get :: proc(t: ^testing.T, s: ^Session, host: string) -> string {
	req := bytes.Buffer{}
	defer bytes.buffer_destroy(&req)
	bytes.buffer_write_string(&req, "GET / HTTP/1.1\r\nHost: ")
	bytes.buffer_write_string(&req, host)
	bytes.buffer_write_string(&req, "\r\nUser-Agent: fastcord-tls-test\r\nAccept: */*\r\nConnection: close\r\n\r\n")
	if !testing.expect_value(t, write(s, bytes.buffer_to_bytes(&req)), Error.None) do return ""
	buf: [4096]byte
	n := 0
	for n < len(buf) {
		got, e := read(s, buf[n:])
		if e != .None do break
		n += got
		if bytes.contains(buf[:n], {'\r', '\n', '\r', '\n'}) do break
	}
	head := buf[:n]
	if i := bytes.index(head, {'\r', '\n'}); i >= 0 do head = head[:i]
	return strings.clone(string(head), context.temp_allocator)
}

@(test)
live_discord_h2_alpn :: proc(t: ^testing.T) {
	if !live() do return
	s := dial(t, "discord.com", {"h2", "http/1.1"})
	if s == nil do return
	defer close(s)
	testing.expect_value(t, negotiated_alpn(s), "h2")
	// Exercise the h2 application-data path: preface + empty SETTINGS, expect a SETTINGS frame back.
	preface := "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"
	settings := [9]byte{0, 0, 0, 4, 0, 0, 0, 0, 0}
	testing.expect_value(t, write(s, transmute([]byte)preface), Error.None)
	testing.expect_value(t, write(s, settings[:]), Error.None)
	hdr: [9]byte
	testing.expect_value(t, netio.read_full(stream(s), hdr[:]), netio.Error.None)
	testing.expect_value(t, hdr[3], 4) // SETTINGS
}

@(test)
live_discord_http1 :: proc(t: ^testing.T) {
	if !live() do return
	s := dial(t, "discord.com", {"http/1.1"})
	if s == nil do return
	defer close(s)
	testing.expect_value(t, negotiated_alpn(s), "http/1.1")
	head := http1_get(t, s, "discord.com")
	testing.expectf(t, len(head) > 12 && head[:9] == "HTTP/1.1 ", "bad response %q", head)
	// Connection: close, so the rest of the body ends with the server's close_notify.
	total := 0
	buf: [8192]byte
	last: Error
	for {
		n, e := read(s, buf[:])
		if e != .None {
			last = e
			break
		}
		total += n
	}
	testing.expect_value(t, last, Error.Closed)
	log.infof("discord.com: %q, %d more bytes until close_notify, %d tickets", head, total, ticket_cache_count(&default_ticket_cache, "discord.com", false))
}

@(test)
live_gateway_http1 :: proc(t: ^testing.T) {
	if !live() do return
	// The official client's WebSocket hello offers only http/1.1.
	s := dial(t, "gateway.discord.gg", {"http/1.1"})
	if s == nil do return
	defer close(s)
	testing.expect_value(t, negotiated_alpn(s), "http/1.1")
	head := http1_get(t, s, "gateway.discord.gg")
	testing.expectf(t, len(head) > 12 && head[:9] == "HTTP/1.1 ", "bad response %q", head)
	log.infof("gateway: %q, %d tickets", head, ticket_cache_count(&default_ticket_cache, "gateway.discord.gg", false))
}

// A second connection resumes from the tickets the first one received, and
// still works for HTTP/1.1. Uses a private cache so other tests don't interfere.
@(test)
live_resumption :: proc(t: ^testing.T) {
	if !live() do return
	cache: Ticket_Cache
	defer ticket_cache_clear(&cache)
	defer delete(cache.entries)
	for round in 0 ..< 2 {
		tcp, err := netio.dial_tcp("discord.com", 443)
		if !testing.expect_value(t, err, netio.Error.None) do return
		netio.tcp_set_read_timeout(tcp, 10 * time.Second)
		s, terr := connect(netio.tcp_stream(tcp), {alpn = {"http/1.1"}, server_name = "discord.com", ticket_cache = &cache})
		if terr != .None {
			testing.expectf(t, false, "round %d: %v / %v", round, terr, last_error())
			return
		}
		testing.expect_value(t, resumed(s), round == 1)
		head := http1_get(t, s, "discord.com")
		testing.expectf(t, len(head) > 12 && head[:9] == "HTTP/1.1 ", "round %d: bad response %q", round, head)
		log.infof("resumption round %d: resumed=%v %q, cached=%d", round, resumed(s), head, ticket_cache_count(&cache, "discord.com", false))
		close(s)
	}
}
