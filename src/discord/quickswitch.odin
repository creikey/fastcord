package discord

import "core:sync"

// Quick switcher (Cmd+K) game search, as the official client issues it
// (fixtures quick_switcher_nav, close_dm):
//   GET /games/autocomplete?q=<query>&filter_group=default
//     per keystroke, throttled to one per 500 ms (leading + trailing edge)
//   GET /games?game_ids=...  for the shown game results (top 3, top 4 for a
//     one-character query) that carry no icon, once per game per session

QS_THROTTLE_MS :: 500

Quick_Switcher :: struct {
	last_sent_ms: i64,
	pending:      string, // query waiting for the trailing edge ("" = none)
	sent:         string, // last query sent
	fetched:      map[Snowflake]bool, // games already looked up
}

// quick_switcher_type: the query text changed (one call per keystroke).
quick_switcher_type :: proc(c: ^Client, query: string) {
	qs := &c.quick_switcher
	now := now_ms()
	if query == "" do return
	if now - qs.last_sent_ms >= QS_THROTTLE_MS {
		qs_send(c, query, now)
		return
	}
	free_str(qs.pending, c.allocator)
	qs.pending = clone_str(query, c.allocator)
}

// quick_switcher_close: the switcher was dismissed (drops a pending query).
quick_switcher_close :: proc(c: ^Client) {
	qs := &c.quick_switcher
	free_str(qs.pending, c.allocator)
	qs.pending = ""
	qs.last_sent_ms = 0
}

flush_quick_switcher :: proc(c: ^Client, now: i64) {
	qs := &c.quick_switcher
	if qs.pending == "" || now - qs.last_sent_ms < QS_THROTTLE_MS do return
	q := qs.pending
	qs.pending = ""
	qs_send(c, q, now)
	free_str(q, c.allocator)
}

quick_switcher_destroy :: proc(c: ^Client) {
	qs := &c.quick_switcher
	free_str(qs.pending, c.allocator)
	free_str(qs.sent, c.allocator)
	delete(qs.fetched)
}

@(private = "file")
qs_send :: proc(c: ^Client, query: string, now: i64) {
	qs := &c.quick_switcher
	qs.last_sent_ms = now
	free_str(qs.sent, c.allocator)
	qs.sent = clone_str(query, c.allocator)
	q: Query
	query_init(&q, "/games/autocomplete")
	query_add(&q, "q", query)
	query_add(&q, "filter_group", "default")
	j := job_new(.Api, .None)
	j.method = "GET"
	j.path = job_str(j, query_string(&q))
	j.on_body = len(query) == 1 ? qs_results_4 : qs_results_3
	job_submit(c, j)
}

@(private = "file")
qs_results_3 :: proc(c: ^Client, body: V) {qs_results(c, body, 3)}
@(private = "file")
qs_results_4 :: proc(c: ^Client, body: V) {qs_results(c, body, 4)}

// worker thread: look up the shown games without an icon
@(private = "file")
qs_results :: proc(c: ^Client, body: V, shown: int) {
	q: Query
	query_init(&q, "/games")
	n := 0
	sync.mutex_lock(&c.job_mu)
	for g, i in vlist(body) {
		if i >= shown do break
		m := vmap(g)
		if vget(m, "icon") != nil do continue
		id := fsnow(m, "id")
		if id == 0 || c.quick_switcher.fetched[id] do continue
		c.quick_switcher.fetched[id] = true
		query_add_snow(&q, "game_ids", id)
		n += 1
	}
	sync.mutex_unlock(&c.job_mu)
	if n == 0 do return
	j := job_new(.Api, .None)
	j.method = "GET"
	j.path = job_str(j, query_string(&q))
	job_submit(c, j)
}
