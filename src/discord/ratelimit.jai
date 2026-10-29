// Backoff mirrors the client's Backoff class (min, max, jitter):
//   fail(): current = min(current + 2*current*random(), max); delay = max(current, floor)
Backoff :: struct {
	min_ms, max_ms: s64;
	jitter: bool;
	current: s64;
	fails: int;
}

backoff_make :: (min_ms: s64 = 500, max_ms: s64 = 0, jitter := true) -> Backoff {
	return .{min_ms = min_ms, max_ms = ifx max_ms > 0 then max_ms else 10 * min_ms, jitter = jitter, current = min_ms};
}

backoff_fail :: (b: *Backoff, floor_ms: s64 = 0) -> s64 {
	b.fails += 1;
	n := cast(float64) (2 * b.current);
	if b.jitter n *= random_get_zero_to_one_open();
	b.current = min(b.current + cast(s64) n, b.max_ms);
	return max(floor_ms, b.current);
}

backoff_succeed :: (b: *Backoff) {
	b.fails = 0;
	b.current = b.min_ms;
}

// Status codes the HTTP util retries when the call passes `retries`.
is_retryable_status :: (status: int) -> bool {
	if status == {
		case 502; #through; case 504; #through; case 507; #through; case 598; #through; case 599; #through;
		case 522; #through; case 523; #through; case 524; return true;
	}
	return false;
}

// ---- official behaviour: per-URL 429/503 hold (HTTPUtils, search `retryAfterTimestamp`) ----
//
// HTTPUtils keeps a map keyed by the request URL. A 429 or 503 response sets
// `retryAfterTimestamp = now + max(backoff(1s..60s).fail(), retry_after*1000)`
// (retry_after from the Retry-After header or the JSON body, default 5 s) and
// arms a timer. A request to a URL with an entry is queued (FIFO). When the
// timer fires it releases one queued request, or drops the entry if none is
// queued; every later response for that URL that is not a 429/503, once the
// hold has expired, releases the next one. So after a 429 the queue drains one
// request per round trip, never as a burst. There is no proactive use of
// X-RateLimit-* headers. Tickets model the queue: `issued` were queued,
// `released` may go; the timer is fired lazily by the first waiter to see it due.

Url_Hold :: struct {
	until: s64;
	backoff: Backoff;
	status: int;
	issued, released: s64;
	timer_due: bool; // the hold's timer has not fired yet
}

// Shared by every worker (under mu); keys live in allocator.
Rate_Limiter :: struct {
	mu: locks.Mutex;
	cond: locks.Cond;
	holds: Table(string, Url_Hold);
	allocator: Allocator;
	closed: bool; // quitting: rate_acquire waits no more
}

rate_limiter_init :: (r: *Rate_Limiter, allocator := context.allocator) {
	r.allocator = allocator;
	r.holds.allocator = allocator;
}

rate_limiter_destroy :: (r: *Rate_Limiter) {
	for r.holds free(it_index,, r.allocator);
	deinit(*r.holds);
}

// rate_acquire blocks the calling worker while url's queue holds it.
rate_acquire :: (r: *Rate_Limiter, url: string) {
	locks.lock(*r.mu);
	defer locks.unlock(*r.mu);
	ticket := -1;
	while true {
		h := table_find_pointer(*r.holds, url);
		if !h || (ticket >= 0 && ticket < h.released) || r.closed return;
		now := now_ms();
		if h.timer_due && now >= h.until {
			h.timer_due = false;
			rate_release_locked(r, url, h); // an empty queue drops the entry: go at once
			continue;
		}
		if ticket < 0 {
			ticket = h.issued;
			h.issued += 1;
		}
		locks.cond_wait_with_timeout(*r.cond, *r.mu, ifx h.timer_due then max(h.until - now, 1) else 1000);
	}
}

// T (rateLimitExpirationHandler): release the next queued request, or drop the entry.
#scope_file
rate_release_locked :: (r: *Rate_Limiter, url: string, h: *Url_Hold) {
	if h.released < h.issued {
		h.released += 1;
		locks.cond_broadcast(*r.cond);
		return;
	}
	for r.holds if it_index == url {
		key := it_index;
		table_remove(*r.holds, url);
		free(key,, r.allocator);
		break;
	}
}
#scope_export

// retry_after_seconds: the Retry-After header (parseInt: whole seconds) or body.retry_after.
retry_after_seconds :: (headers: []http.Header, body: V) -> float64, bool {
	v, ok := http.header_get(headers, "retry-after");
	if ok {
		n, nok := string_to_int(v, 10, s64);
		if nok && n > 0 return cast(float64) n, true;
	}
	f := vf64(vget(vmap(body), "retry_after"));
	if f > 0 return f, true;
	return 0, false;
}

// rate_note_response records a request's outcome (cleanupRequestEntry); status 0 = no response.
// Returns the hold in ms when the response was 429/503.
rate_note_response :: (r: *Rate_Limiter, url: string, status: int, headers: []http.Header, body: V, now: s64) -> s64 {
	locks.lock(*r.mu);
	defer locks.unlock(*r.mu);
	h := table_find_pointer(*r.holds, url);
	if status == 429 || status == 503 {
		ra, has := retry_after_seconds(headers, body);
		floor := cast(s64) ((ifx has then ra else 5) * 1000);
		if !h h = table_add(*r.holds, copy_string(url,, r.allocator), .{backoff = backoff_make(1000, 60000)});
		delay := backoff_fail(*h.backoff, floor); // the backoff fails even when a longer hold is kept
		until := now + delay;
		if h.until >= until return h.until - now;
		h.until = until;
		h.status = status;
		h.timer_due = true;
		locks.cond_broadcast(*r.cond);
		return delay;
	}
	if h && h.until < now rate_release_locked(r, url, h);
	return 0;
}
