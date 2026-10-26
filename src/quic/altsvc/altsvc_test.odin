package altsvc

import "core:log"
import "core:os"
import "core:testing"
import "core:time"

import "fc:netio"
import "fc:tls"

@(test)
parse_alt_svc :: proc(t: ^testing.T) {
	alts, clear := parse(`h3=":443"; ma=86400, h3-29=":8443"; ma=60`)
	testing.expect(t, !clear)
	testing.expect_value(t, len(alts), 2)
	testing.expect(t, alts[0].proto == "h3" && alts[0].port == 443 && alts[0].ma == 86400 && alts[0].host == "")
	testing.expect(t, alts[1].proto == "h3-29" && alts[1].port == 8443 && alts[1].ma == 60)
	_, clear = parse("clear")
	testing.expect(t, clear)
	bad, _ := parse(`h3=":0", h3="nope", garbage`)
	testing.expect_value(t, len(bad), 0)
}

@(test)
record_expiry_and_broken_backoff :: proc(t: ^testing.T) {
	c: Cache
	defer destroy(&c)
	now := time.now()
	_, ok := usable(&c, "discord.com", now)
	testing.expect(t, !ok, "first contact is TCP")
	record(&c, "discord.com", `h3=":443"; ma=100`, now)
	port, ok2 := usable(&c, "discord.com", now)
	testing.expect(t, ok2 && port == 443)
	_, ok3 := usable(&c, "discord.com", time.time_add(now, 101 * time.Second))
	testing.expect(t, !ok3, "expired")
	record(&c, "discord.com", `h3=":443"; ma=86400`, now)
	mark_broken(&c, "discord.com", now)
	_, ok4 := usable(&c, "discord.com", time.time_add(now, 4 * time.Minute))
	testing.expect(t, !ok4, "broken for 5 minutes")
	_, ok5 := usable(&c, "discord.com", time.time_add(now, 6 * time.Minute))
	testing.expect(t, ok5)
	mark_broken(&c, "discord.com", now)
	_, ok6 := usable(&c, "discord.com", time.time_add(now, 9 * time.Minute))
	testing.expect(t, !ok6, "second failure doubles to 10 minutes")
	record(&c, "discord.com", "clear", now)
	_, ok7 := usable(&c, "discord.com", now)
	testing.expect(t, !ok7)
}

@(test)
persistence_roundtrip :: proc(t: ^testing.T) {
	path := "build/altsvc_test_cache.txt"
	defer os.remove(path)
	{
		c: Cache
		c.path = path
		record(&c, "discord.com", `h3=":443"; ma=86400`)
		mark_broken(&c, "discord.com")
		c.path = ""
		destroy(&c)
	}
	c: Cache
	defer destroy(&c)
	testing.expect(t, load(&c, path))
	e, found := c.entries["discord.com"]
	testing.expect(t, found && e.port == 443 && e.broken_count == 1)
	_, ok := usable(&c, "discord.com")
	testing.expect(t, !ok, "still broken after reload")
}

@(private = "file")
dial_tls :: proc(host: string, user: rawptr) -> (rawptr, bool) {
	tcp, err := netio.dial_tcp(host, 443)
	if err != .None do return nil, false
	s, terr := tls.connect(netio.tcp_stream(tcp), {alpn = {"h2", "http/1.1"}, server_name = host})
	if terr != .None {
		netio.close(netio.tcp_stream(tcp))
		return nil, false
	}
	return s, true
}

@(private = "file")
close_tls :: proc(conn: rawptr, user: rawptr) {tls.close(cast(^tls.Session)conn)}

// First contact goes over TCP; with an Alt-Svc entry the race picks h3, and
// the session is reused.
@(test)
live_race :: proc(t: ^testing.T) {
	if os.get_env("FASTCORD_LIVE", context.temp_allocator) != "1" do return
	c: Cache
	defer destroy(&c)
	r1, ok1 := connect(&c, "discord.com", dial_tls, close_tls, nil)
	testing.expect(t, ok1 && r1.proto == .H2, "first contact over TCP")
	if ok1 && r1.tcp != nil do close_tls(r1.tcp, nil)
	record(&c, "discord.com", `h3=":443"; ma=86400`)
	r2, ok2 := connect(&c, "discord.com", dial_tls, close_tls, nil)
	testing.expect(t, ok2, "race")
	log.infof("race winner: %v", r2.proto)
	if r2.proto == .H2 && r2.tcp != nil do close_tls(r2.tcp, nil)
	// Let the QUIC job finish and register its session.
	time.sleep(500 * time.Millisecond)
	r3, ok3 := connect(&c, "discord.com", dial_tls, close_tls, nil)
	testing.expect(t, ok3 && r3.proto == .H3, "QUIC session reused")
	if ok3 && r2.proto == .H3 do testing.expect(t, r3.h3 == r2.h3, "same session")
	testing.expect(t, c.quic_works)
}
