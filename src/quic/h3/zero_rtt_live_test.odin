package h3

import "core:log"
import "core:os"
import "core:testing"
import "core:thread"

import "fc:http"
import "fc:quic"

@(private = "file")
Req_Job :: struct {
	c:      ^Conn,
	status: int,
	err:    http.Error,
}

@(private = "file")
run_req :: proc(j: ^Req_Job) {
	req := http.Request {
		method    = "GET",
		scheme    = "https",
		authority = "discord.com",
		path      = "/api/v9/experiments",
		headers   = {{"user-agent", UA}, {"accept", "*/*"}, {"accept-encoding", "gzip, deflate, br, zstd"}},
	}
	resp, err := request(j.c, req)
	j.status = resp.status
	j.err = err
	http.response_destroy(&resp)
}

// Regression: several fresh connections in one process, each resuming (0-RTT)
// from the previous one's tickets, with 10 concurrent requests per round.
@(test)
live_zero_rtt_rounds :: proc(t: ^testing.T) {
	if os.get_env("FASTCORD_LIVE", context.temp_allocator) != "1" do return
	quic.debug_log = os.get_env("FASTCORD_QUIC_DEBUG", context.temp_allocator) == "1"
	for round in 0 ..< 6 {
		c, err := connect("discord.com")
		if !testing.expectf(t, err == .None, "round %d connect: %v", round, err) do return
		jobs: [10]Req_Job
		threads: [10]^thread.Thread
		for i in 0 ..< 10 {
			jobs[i].c = c
			threads[i] = thread.create_and_start_with_poly_data(&jobs[i], run_req, init_context = context)
		}
		for th in threads {
			thread.join(th)
			thread.destroy(th)
		}
		ok := 0
		// Any HTTP status proves the request made it over 0-RTT/1-RTT; Discord
		// rate-limits /experiments (429) after a few dozen calls.
		for j in jobs do if j.err == .None && (j.status == 200 || j.status == 429) do ok += 1
		log.infof("round %d: early=%v resumed=%v tls=%v qerr=%v ok=%d/10 errs=%v st=%v", round, quic.early_state(c.q), c.q.hs.resumed, c.q.tls_error, c.q.err, ok, [10]http.Error{jobs[0].err, jobs[1].err, jobs[2].err, jobs[3].err, jobs[4].err, jobs[5].err, jobs[6].err, jobs[7].err, jobs[8].err, jobs[9].err}, [3]int{jobs[0].status, jobs[1].status, jobs[9].status})
		testing.expectf(t, ok == 10, "round %d: %d/10 ok", round, ok)
		if round > 0 do testing.expectf(t, quic.early_state(c.q) == .Accepted, "round %d: 0-RTT %v", round, quic.early_state(c.q))
		close(c)
	}
}
