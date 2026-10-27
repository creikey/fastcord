// Quick switcher (Cmd+K) game search, as the official client issues it
// (fixtures quick_switcher_nav, close_dm):
//   GET /games/autocomplete?q=<query>&filter_group=default
//     per keystroke, throttled to one per 500 ms (leading + trailing edge)
//   GET /games?game_ids=...  for the shown game results (top 3, top 4 for a
//     one-character query) that carry no icon, once per game per session

QS_THROTTLE_MS :: 500;

Quick_Switcher :: struct {
	last_sent_ms: s64;
	pending: string; // query waiting for the trailing edge ("" = none)
	sent: string; // last query sent
	fetched: Map(Snowflake, bool); // games already looked up
}

// quick_switcher_type: the query text changed (one call per keystroke).
quick_switcher_type :: (c: *Client, query: string) {
	qs := *c.quick_switcher;
	now := now_ms();
	if query == "" { return; }
	if now - qs.last_sent_ms >= QS_THROTTLE_MS {
		qs_send(c, query, now);
		return;
	}
	free_str(qs.pending, c.allocator);
	qs.pending = clone_str(query, c.allocator);
}

// quick_switcher_close: the switcher was dismissed (drops a pending query).
quick_switcher_close :: (c: *Client) {
	qs := *c.quick_switcher;
	free_str(qs.pending, c.allocator);
	qs.pending = "";
	qs.last_sent_ms = 0;
}

flush_quick_switcher :: (c: *Client, now: s64) {
	qs := *c.quick_switcher;
	if qs.pending == "" || now - qs.last_sent_ms < QS_THROTTLE_MS { return; }
	q := qs.pending;
	qs.pending = "";
	qs_send(c, q, now);
	free_str(q, c.allocator);
}

quick_switcher_destroy :: (c: *Client) {
	qs := *c.quick_switcher;
	free_str(qs.pending, c.allocator);
	free_str(qs.sent, c.allocator);
	delete(qs.fetched);
}
#scope_file

qs_send :: (c: *Client, query: string, now: s64) {
	qs := *c.quick_switcher;
	qs.last_sent_ms = now;
	free_str(qs.sent, c.allocator);
	qs.sent = clone_str(query, c.allocator);
	q: Query;
	query_init(*q, "/games/autocomplete");
	query_add(*q, "q", query);
	query_add(*q, "filter_group", "default");
	j := job_new(.Api, .None);
	j.method = "GET";
	j.path = job_str(j, query_string(*q));
	j.on_body = ifx len(query) == 1 then qs_results_4 else qs_results_3;
	job_submit(c, j);
}

qs_results_3 :: (c: *Client, body: V) {qs_results(c, body, 3);}
qs_results_4 :: (c: *Client, body: V) {qs_results(c, body, 4);}

// worker thread: look up the shown games without an icon
qs_results :: (c: *Client, body: V, shown: int) {
	q: Query;
	query_init(*q, "/games");
	n := 0;
	locks.lock(*c.job_mu);
	for g, i: vlist(body) {
		if i >= shown { break; }
		m := vmap(g);
		if vget(m, "icon") != null { continue; }
		id := fsnow(m, "id");
		if id == 0 || __MAPIDX__(c.quick_switcher.fetched|id) { continue; }
		at(*c.quick_switcher.fetched, id).* = true;
		query_add_snow(*q, "game_ids", id);
		n += 1;
	}
	locks.unlock(*c.job_mu);
	if n == 0 { return; }
	j := job_new(.Api, .None);
	j.method = "GET";
	j.path = job_str(j, query_string(*q));
	job_submit(c, j);
}
#scope_export

