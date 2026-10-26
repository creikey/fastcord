package discord

import "core:math/rand"
import "core:strconv"
import "core:strings"
import "core:sync"
import "fc:http"

// Backoff mirrors the client's Backoff class (min, max, jitter):
//   fail(): current = min(current + 2*current*random(), max); delay = max(current, floor)
Backoff :: struct {
	min_ms, max_ms: i64,
	jitter:         bool,
	current:        i64,
	fails:          int,
}

backoff_make :: proc(min_ms: i64 = 500, max_ms: i64 = 0, jitter := true) -> Backoff {
	mx := max_ms if max_ms > 0 else 10 * min_ms
	return Backoff{min_ms = min_ms, max_ms = mx, jitter = jitter, current = min_ms}
}

backoff_fail :: proc(b: ^Backoff, floor_ms: i64 = 0, r: f64 = -1) -> i64 {
	b.fails += 1
	n := f64(2 * b.current)
	if b.jitter do n *= r if r >= 0 else rand.float64()
	b.current = min(b.current + i64(n), b.max_ms)
	return floor_ms if floor_ms > b.current else b.current
}

backoff_succeed :: proc(b: ^Backoff) {
	b.fails = 0
	b.current = b.min_ms
}

// Status codes the HTTP util retries when the call passes `retries`.
is_retryable_status :: proc(status: int) -> bool {
	switch status {
	case 502, 504, 507, 598, 599, 522, 523, 524:
		return true
	}
	return false
}

// ---- official behaviour: per-URL 429/503 hold ----
//
// HTTPUtils keeps a map keyed by the request URL. A 429 or 503 response sets
// `retryAfterTimestamp = now + max(backoff(1s..60s).fail(), retry_after*1000)`
// (retry_after from the Retry-After header or the JSON body, default 5 s);
// requests to that URL issued meanwhile are queued and released one by one
// when the hold expires. There is no proactive use of X-RateLimit-* headers.

@(private)
Url_Hold :: struct {
	until:   i64,
	backoff: Backoff,
	status:  int,
}

// Discord's bucket headers are tracked for introspection (and for the
// optional `proactive` mode, off by default since the official client
// doesn't do it).
Bucket :: struct {
	limit:       int,
	remaining:   int,
	reset_at:    i64, // unix ms
	scope:       string,
}

Rate_Limiter :: struct {
	mu:          sync.Mutex,
	holds:       map[string]Url_Hold,
	buckets:     map[string]Bucket, // bucket hash -> state
	route_bucket: map[string]string, // "METHOD route-key" -> bucket hash
	global_until: i64,
	proactive:   bool,
	allocator:   Allocator,
}

rate_limiter_init :: proc(r: ^Rate_Limiter, allocator := context.allocator) {
	r.allocator = allocator
	r.holds = make(map[string]Url_Hold, allocator = allocator)
	r.buckets = make(map[string]Bucket, allocator = allocator)
	r.route_bucket = make(map[string]string, allocator = allocator)
}

rate_limiter_destroy :: proc(r: ^Rate_Limiter) {
	for k in r.holds do delete(k, r.allocator)
	delete(r.holds)
	for k, b in r.buckets {
		delete(k, r.allocator)
		delete(b.scope, r.allocator)
	}
	delete(r.buckets)
	for k, v in r.route_bucket {
		delete(k, r.allocator)
		delete(v, r.allocator)
	}
	delete(r.route_bucket)
}

// route_key collapses ids like Discord's bucketing: major params (channel,
// guild, webhook ids) are kept, other snowflakes become ":id"; reactions
// share one route; query strings are ignored.
route_key :: proc(method, path: string, allocator := context.temp_allocator) -> string {
	p := path
	if q := strings.index_byte(p, '?'); q >= 0 do p = p[:q]
	parts := strings.split(p, "/", context.temp_allocator)
	sb := strings.builder_make(allocator)
	strings.write_string(&sb, method)
	strings.write_byte(&sb, ' ')
	prev := ""
	for part, i in parts {
		if i > 0 do strings.write_byte(&sb, '/')
		is_id := len(part) >= 15 && is_digits(part)
		if prev == "reactions" && i > 0 {
			strings.write_string(&sb, ":emoji")
			strings.write_string(&sb, "/*")
			break
		}
		if is_id && !(prev == "channels" || prev == "guilds" || prev == "webhooks") {
			strings.write_string(&sb, ":id")
		} else {
			strings.write_string(&sb, part)
		}
		prev = part
	}
	return strings.to_string(sb)
}

@(private)
is_digits :: proc(s: string) -> bool {
	for c in transmute([]byte)s do if c < '0' || c > '9' do return false
	return len(s) > 0
}

// rate_wait_ms returns how long a request to url must wait before being sent (0 = now).
rate_wait_ms :: proc(r: ^Rate_Limiter, method, url: string, now: i64) -> i64 {
	sync.mutex_lock(&r.mu)
	defer sync.mutex_unlock(&r.mu)
	wait: i64 = 0
	if h, ok := r.holds[url]; ok && h.until > now do wait = h.until - now
	if r.proactive {
		if r.global_until > now do wait = max(wait, r.global_until - now)
		rk := route_key(method, url)
		if bh, ok := r.route_bucket[rk]; ok {
			if b, bok := r.buckets[bh]; bok && b.remaining <= 0 && b.reset_at > now do wait = max(wait, b.reset_at - now)
		}
	}
	return wait
}

// retry_after_seconds reads Retry-After (header, integer seconds) or body.retry_after.
retry_after_seconds :: proc(headers: []http.Header, body: V) -> (f64, bool) {
	if v, ok := http.header_get(headers, "retry-after"); ok {
		if n, nok := strconv.parse_f64(v); nok && n > 0 do return n, true
	}
	if m := vmap(body); m != nil {
		ra := vget(m, "retry_after")
		if f := vf64(ra); f > 0 do return f, true
	}
	return 0, false
}

// rate_note_response records the outcome of a request (official hold logic + bucket headers).
// Returns the hold in ms when the response was 429/503.
rate_note_response :: proc(r: ^Rate_Limiter, method, url: string, status: int, headers: []http.Header, body: V, now: i64, jitter_r: f64 = -1) -> i64 {
	sync.mutex_lock(&r.mu)
	defer sync.mutex_unlock(&r.mu)
	note_bucket_locked(r, method, url, headers, now)
	if status == 429 || status == 503 {
		ra, has := retry_after_seconds(headers, body)
		floor := i64((ra if has else 5) * 1000)
		h, existing := r.holds[url]
		if !existing do h.backoff = backoff_make(1000, 60000)
		delay := backoff_fail(&h.backoff, floor, jitter_r)
		until := now + delay
		if existing && h.until >= until do return h.until - now
		h.until = until
		h.status = status
		if existing {
			r.holds[url] = h
		} else {
			r.holds[strings.clone(url, r.allocator)] = h
		}
		if global, _ := http.header_get(headers, "x-ratelimit-global"); global == "true" {
			r.global_until = until
		}
		return delay
	}
	// Expired holds are dropped on the next response for that URL.
	if h, ok := r.holds[url]; ok && h.until < now {
		for k in r.holds {
			if k == url {
				delete_key(&r.holds, k)
				delete(k, r.allocator)
				break
			}
		}
	}
	return 0
}

@(private)
note_bucket_locked :: proc(r: ^Rate_Limiter, method, url: string, headers: []http.Header, now: i64) {
	bh, ok := http.header_get(headers, "x-ratelimit-bucket")
	if !ok do return
	b: Bucket
	if v, vok := http.header_get(headers, "x-ratelimit-limit"); vok do b.limit, _ = strconv.parse_int(v)
	if v, vok := http.header_get(headers, "x-ratelimit-remaining"); vok do b.remaining, _ = strconv.parse_int(v)
	if v, vok := http.header_get(headers, "x-ratelimit-reset-after"); vok {
		f, _ := strconv.parse_f64(v)
		b.reset_at = now + i64(f * 1000)
	}
	scope, _ := http.header_get(headers, "x-ratelimit-scope")
	b.scope = strings.clone(scope, r.allocator)
	if old, had := r.buckets[bh]; had {
		delete(old.scope, r.allocator)
		r.buckets[bh] = b
	} else {
		r.buckets[strings.clone(bh, r.allocator)] = b
	}
	rk := route_key(method, url)
	if old, had := r.route_bucket[rk]; had {
		if old != bh {
			delete(old, r.allocator)
			r.route_bucket[rk] = strings.clone(bh, r.allocator)
		}
	} else {
		r.route_bucket[strings.clone(rk, r.allocator)] = strings.clone(bh, r.allocator)
	}
}

rate_bucket_for :: proc(r: ^Rate_Limiter, method, url: string) -> (Bucket, bool) {
	sync.mutex_lock(&r.mu)
	defer sync.mutex_unlock(&r.mu)
	bh, ok := r.route_bucket[route_key(method, url)]
	if !ok do return {}, false
	b, bok := r.buckets[bh]
	return b, bok
}
