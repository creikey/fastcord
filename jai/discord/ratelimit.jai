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

// ---- official behaviour: per-URL 429/503 hold ----
//
// HTTPUtils keeps a map keyed by the request URL. A 429 or 503 response sets
// `retryAfterTimestamp = now + max(backoff(1s..60s).fail(), retry_after*1000)`
// (retry_after from the Retry-After header or the JSON body, default 5 s);
// requests to that URL issued meanwhile are queued and released one by one
// when the hold expires. There is no proactive use of X-RateLimit-* headers.

Url_Hold :: struct {
	until: s64;
	backoff: Backoff;
	status: int;
}

// Shared by every worker (under mu); keys live in allocator.
Rate_Limiter :: struct {
	mu: locks.Mutex;
	holds: Table(string, Url_Hold);
	allocator: Allocator;
}

rate_limiter_init :: (r: *Rate_Limiter, allocator := context.allocator) {
	r.allocator = allocator;
	r.holds.allocator = allocator;
}

rate_limiter_destroy :: (r: *Rate_Limiter) {
	for r.holds free(it_index,, r.allocator);
	deinit(*r.holds);
}

// rate_wait_ms returns how long a request to url must wait before being sent (0 = now).
rate_wait_ms :: (r: *Rate_Limiter, url: string, now: s64) -> s64 {
	locks.lock(*r.mu);
	defer locks.unlock(*r.mu);
	h := table_find_pointer(*r.holds, url);
	return ifx h && h.until > now then h.until - now else 0;
}

// retry_after_seconds reads Retry-After (header, integer seconds) or body.retry_after.
retry_after_seconds :: (headers: []http.Header, body: V) -> float64, bool {
	v, ok := http.header_get(headers, "retry-after");
	if ok {
		n, nok, rest := string_to_float64(v);
		if nok && !rest && n > 0 return n, true;
	}
	f := vf64(vget(vmap(body), "retry_after"));
	if f > 0 return f, true;
	return 0, false;
}

// rate_note_response records the outcome of a request (the official hold logic).
// Returns the hold in ms when the response was 429/503.
rate_note_response :: (r: *Rate_Limiter, url: string, status: int, headers: []http.Header, body: V, now: s64) -> s64 {
	locks.lock(*r.mu);
	defer locks.unlock(*r.mu);
	h := table_find_pointer(*r.holds, url);
	if status == 429 || status == 503 {
		ra, has := retry_after_seconds(headers, body);
		floor := cast(s64) ((ifx has then ra else 5) * 1000);
		if !h h = table_add(*r.holds, copy_string(url,, r.allocator), .{backoff = backoff_make(1000, 60000)});
		saved := h.backoff; // a hold that already lasts longer keeps its backoff
		delay := backoff_fail(*h.backoff, floor);
		until := now + delay;
		if h.until >= until {
			h.backoff = saved;
			return h.until - now;
		}
		h.until = until;
		h.status = status;
		return delay;
	}
	// Expired holds are dropped on the next response for that URL.
	if h && h.until < now {
		for r.holds if it_index == url {
			key := it_index;
			table_remove(*r.holds, url);
			free(key,, r.allocator);
			break;
		}
	}
	return 0;
}
