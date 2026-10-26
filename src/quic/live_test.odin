package quic

import "core:log"
import "core:os"
import "core:testing"

import "fc:tls"

@(private = "file")
live :: proc() -> bool {
	return os.get_env("FASTCORD_LIVE", context.temp_allocator) == "1"
}

@(test)
live_quic_handshake :: proc(t: ^testing.T) {
	if !live() do return
	debug_log = os.get_env("FASTCORD_QUIC_DEBUG", context.temp_allocator) == "1"
	cache: tls.Ticket_Cache
	defer tls.ticket_cache_clear(&cache)
	defer delete(cache.entries)
	for round in 0 ..< 2 {
		c, err := connect("discord.com", {tls = {alpn = {"h3"}, server_name = "discord.com", ticket_cache = &cache}})
		if err != .None {
			testing.expectf(t, false, "round %d: connect: %v (tls %v, peer code %x)", round, err, tls.last_error(), 0)
			return
		}
		testing.expect_value(t, c.hs.alpn, "h3")
		log.infof("quic round %d: suite=%04x group=%04x resumed=%v rtt=%v params=%v", round, c.hs.suite.id, c.hs.group, c.hs.resumed, c.rtt.smoothed, c.params)
		if round == 1 do testing.expect(t, c.hs.resumed, "second connection should resume")
		// Give the server time to send NewSessionTicket + HANDSHAKE_DONE.
		wait_confirmed(c)
		log.infof("confirmed=%v tickets=%d", c.handshake_confirmed, tls.ticket_cache_count(&cache, "discord.com", true))
		close(c)
	}
}

@(private = "file")
wait_confirmed :: proc(c: ^Conn) {
	lock(c)
	defer unlock(c)
	for !c.handshake_confirmed && c.err == .None do wait_locked(c)
}
