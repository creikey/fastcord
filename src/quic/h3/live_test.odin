package h3

import "core:log"
import "core:os"
import "core:strings"
import "core:testing"

import "fc:http"
import "fc:quic"

@(private = "file")
live :: proc() -> bool {
	return os.get_env("FASTCORD_LIVE", context.temp_allocator) == "1"
}

UA :: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) discord/0.0.419 Chrome/148.0.7778.280 Electron/42.11.15 Safari/537.36"

// GET /api/v9/experiments over HTTP/3 (twice on one connection, then again on
// a resumed connection).
@(test)
live_h3_experiments :: proc(t: ^testing.T) {
	if !live() do return
	quic.debug_log = os.get_env("FASTCORD_QUIC_DEBUG", context.temp_allocator) == "1"
	for round in 0 ..< 2 {
		c, err := connect("discord.com")
		if err != .None {
			testing.expectf(t, false, "round %d connect: %v", round, err)
			return
		}
		for i in 0 ..< 2 {
			req := http.Request {
				method    = "GET",
				scheme    = "https",
				authority = "discord.com",
				path      = "/api/v9/experiments",
				headers   = {
					{"user-agent", UA},
					{"accept", "*/*"},
					{"accept-encoding", "gzip, deflate, br, zstd"},
					{"accept-language", "en-US"},
				},
			}
			resp, rerr := request(c, req)
			defer http.response_destroy(&resp)
			if !testing.expectf(t, rerr == .None, "round %d req %d: %v", round, i, rerr) do break
			testing.expect_value(t, resp.status, 200)
			ce, _ := http.header_get(resp.headers[:], "content-encoding")
			testing.expect(t, http.decode_body(&resp) == .None)
			body := string(resp.body[:])
			testing.expectf(t, strings.contains(body, "fingerprint") || strings.contains(body, "assignments"), "unexpected body %q", body[:min(len(body), 200)])
			log.infof("h3 round %d req %d: status=%d enc=%q body=%d bytes resumed=%v", round, i, resp.status, ce, len(resp.body), c.q.hs.resumed)
		}
		close(c)
	}
}
