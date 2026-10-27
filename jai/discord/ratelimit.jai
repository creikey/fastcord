// Backoff mirrors the client's Backoff class (min, max, jitter):
//   fail(): current = min(current + 2*current*random(), max); delay = max(current, floor)
Backoff :: struct {
	min_ms, max_ms: s64;
	jitter: bool;
	current: s64;
	fails: int;
}

backoff_make :: (min_ms: s64 = 500, max_ms: s64 = 0, jitter := true) -> Backoff {
	mx := ifx max_ms > 0 then max_ms else 10 * min_ms;
	return Backoff.{min_ms = min_ms, max_ms = mx, jitter = jitter, current = min_ms};
}

backoff_fail :: (b: *Backoff, floor_ms: s64 = 0, r: float64 = -1) -> s64 {
	b.fails += 1;
	n := cast(float64)(2 * b.current);
	if b.jitter { n *= ifx r >= 0 then r else rand.float64_(); }
	b.current = min(b.current + cast(s64)(n), b.max_ms);
	return ifx floor_ms > b.current then floor_ms else b.current;
}

backoff_succeed :: (b: *Backoff) {
	b.fails = 0;
	b.current = b.min_ms;
}

// Status codes the HTTP util retries when the call passes `retries`.
is_retryable_status :: (status: int) -> bool {
	if status == {
	case 502; #through; case 504; #through; case 507; #through; case 598; #through; case 599; #through; case 522; #through; case 523; #through; case 524;
		return true;
	}
	return false;
}
#scope_module

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
#scope_export

// Discord's bucket headers are tracked for introspection (and for the
// optional `proactive` mode, off by default since the official client
// doesn't do it).
Bucket :: struct {
	limit: int;
	remaining: int;
	reset_at: s64; // unix ms
	scope: string;
}

Rate_Limiter :: struct {
	mu: locks.Mutex;
	holds: Table(string, Url_Hold);
	buckets: Table(string, Bucket); // bucket hash -> state
	route_bucket: Table(string, string); // "METHOD route-key" -> bucket hash
	global_until: s64;
	proactive: bool;
	allocator: Allocator;
}

rate_limiter_init :: (r: *Rate_Limiter, allocator := context.allocator) {
	r.allocator = allocator;
	r.holds.allocator = allocator;
	r.buckets.allocator = allocator;
	r.route_bucket.allocator = allocator;
}

rate_limiter_destroy :: (r: *Rate_Limiter) {
	for v_, k: r.holds { delete(k, r.allocator); }
	deinit(*r.holds);
	for b, k: r.buckets {
		delete(k, r.allocator);
		delete(b.scope, r.allocator);
	}
	deinit(*r.buckets);
	for v, k: r.route_bucket {
		delete(k, r.allocator);
		delete(v, r.allocator);
	}
	deinit(*r.route_bucket);
}

// route_key collapses ids like Discord's bucketing: major params (channel,
// guild, webhook ids) are kept, other snowflakes become ":id"; reactions
// share one route; query strings are ignored.
route_key :: (method: string, path: string, allocator := temp) -> string {
	p := path;
	if strings.has_prefix(p, "https://") {
		rest := sub_from(p, len("https://"));
		sl := strings.index_byte(rest, #char "/");
		p = ifx sl >= 0 then sub_from(rest, sl) else "/";
	}
	{ q := strings.index_byte(p, #char "?");
	if q >= 0 { p = sub(p, 0, q); } }
	parts := strings.split(p, "/", temp);
	sb := strings.builder_make(allocator);
	strings.write_string(*sb, method);
	strings.write_byte(*sb, #char " ");
	prev := "";
	for part, i: parts {
		if i > 0 { strings.write_byte(*sb, #char "/"); }
		is_id := len(part) >= 15 && is_digits(part);
		if prev == "reactions" && i > 0 {
			strings.write_string(*sb, ":emoji");
			strings.write_string(*sb, "/*");
			break;
		}
		if is_id && !(prev == "channels" || prev == "guilds" || prev == "webhooks") {
			strings.write_string(*sb, ":id");
		} else {
			strings.write_string(*sb, part);
		}
		prev = part;
	}
	return strings.to_string(sb);
}
#scope_module

is_digits :: (s: string) -> bool {
	for c: transmute([]u8, s) { if c < #char "0" || c > #char "9" { return false; } }
	return len(s) > 0;
}
#scope_export

// rate_wait_ms returns how long a request to url must wait before being sent (0 = now).
rate_wait_ms :: (r: *Rate_Limiter, method: string, url: string, now: s64) -> s64 {
	locks.lock(*r.mu);
	defer locks.unlock(*r.mu);
	wait: s64 = 0;
	{ ok, h := table_find(*r.holds, url);
	if ok && h.until > now { wait = h.until - now; } }
	if r.proactive {
		if r.global_until > now { wait = max(wait, r.global_until - now); }
		rk := route_key(method, url);
		{ ok, bh := table_find(*r.route_bucket, rk);
		if ok {
			{ bok, b := table_find(*r.buckets, bh);
			if bok && b.remaining <= 0 && b.reset_at > now { wait = max(wait, b.reset_at - now); } }
		} }
	}
	return wait;
}

// retry_after_seconds reads Retry-After (header, integer seconds) or body.retry_after.
retry_after_seconds :: (headers: []http.Header, body: V) -> float64, bool {
	{ v, ok := http.header_get(headers, "retry-after");
	if ok {
		{ n, nok := strconv.parse_f64(v);
		if nok && n > 0 { return n, true; } }
	} }
	{ m := vmap(body);
	if !is_null(m) {
		ra := vget(m, "retry_after");
		{ f := vf64(ra);
		if f > 0 { return f, true; } }
	} }
	return 0, false;
}

// rate_note_response records the outcome of a request (official hold logic + bucket headers).
// Returns the hold in ms when the response was 429/503.
rate_note_response :: (r: *Rate_Limiter, method: string, url: string, status: int, headers: []http.Header, body: V, now: s64, jitter_r: float64 = -1) -> s64 {
	locks.lock(*r.mu);
	defer locks.unlock(*r.mu);
	note_bucket_locked(r, method, url, headers, now);
	if status == 429 || status == 503 {
		ra, has := retry_after_seconds(headers, body);
		floor := cast(s64)((ifx has then ra else 5) * 1000);
		existing, h := table_find(*r.holds, url);
		if !existing { h.backoff = backoff_make(1000, 60000); }
		delay := backoff_fail(*h.backoff, floor, jitter_r);
		until := now + delay;
		if existing && h.until >= until { return h.until - now; }
		h.until = until;
		h.status = status;
		if existing {
			table_set(*r.holds, url, h);
		} else {
			table_set(*r.holds, clone(url, r.allocator), h);
		}
		{ global, _ := http.header_get(headers, "x-ratelimit-global");
		if global == "true" {
			r.global_until = until;
		} }
		return delay;
	}
	// Expired holds are dropped on the next response for that URL.
	{ ok, h := table_find(*r.holds, url);
	if ok && h.until < now {
		for v_, k: r.holds {
			if k == url {
				table_remove(*r.holds, k);
				delete(k, r.allocator);
				break;
			}
		}
	} }
	return 0;
}
#scope_module

note_bucket_locked :: (r: *Rate_Limiter, method: string, url: string, headers: []http.Header, now: s64) {
	bh, ok := http.header_get(headers, "x-ratelimit-bucket");
	if !ok { return; }
	b: Bucket;
	{ v, vok := http.header_get(headers, "x-ratelimit-limit");
	if vok { b.limit, _ = strconv.parse_int(v); } }
	{ v, vok := http.header_get(headers, "x-ratelimit-remaining");
	if vok { b.remaining, _ = strconv.parse_int(v); } }
	{ v, vok := http.header_get(headers, "x-ratelimit-reset-after");
	if vok {
		f, _ := strconv.parse_f64(v);
		b.reset_at = now + cast(s64)(f * 1000);
	} }
	scope, _ := http.header_get(headers, "x-ratelimit-scope");
	b.scope = clone(scope, r.allocator);
	{ had, old := table_find(*r.buckets, bh);
	if had {
		delete(old.scope, r.allocator);
		table_set(*r.buckets, bh, b);
	} else {
		table_set(*r.buckets, clone(bh, r.allocator), b);
	} }
	rk := route_key(method, url);
	{ had, old := table_find(*r.route_bucket, rk);
	if had {
		if old != bh {
			delete(old, r.allocator);
			table_set(*r.route_bucket, rk, clone(bh, r.allocator));
		}
	} else {
		table_set(*r.route_bucket, clone(rk, r.allocator), clone(bh, r.allocator));
	} }
}
#scope_export

rate_bucket_for :: (r: *Rate_Limiter, method: string, url: string) -> Bucket, bool {
	locks.lock(*r.mu);
	defer locks.unlock(*r.mu);
	ok, bh := table_find(*r.route_bucket, route_key(method, url));
	if !ok { return .{}, false; }
	bok, b := table_find(*r.buckets, bh);
	return b, bok;
}

