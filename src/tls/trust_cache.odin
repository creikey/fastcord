package tls

import "fc:locks"
import "base:runtime"
import "core:crypto/hash"
import "core:time"

// Chrome's CachingCertVerifier keeps verification results for 30 minutes,
// keyed by the chain and hostname; repeat full handshakes to the same
// origin skip the 2-7 ms OS trust evaluation. Only successes are cached.
TRUST_CACHE_TTL :: 30 * time.Minute
TRUST_CACHE_MAX :: 256

@(private)
Trust_Key :: [32]byte

@(private)
trust_cache_mu: locks.Mutex
@(private)
trust_cache: map[Trust_Key]time.Tick

@(private)
trust_key :: proc(chain: [][]byte, host: string) -> (k: Trust_Key) {
	ctx: hash.Context
	hash.init(&ctx, .SHA256)
	n: [4]byte
	for der in chain {
		l := len(der)
		n = {byte(l >> 24), byte(l >> 16), byte(l >> 8), byte(l)}
		hash.update(&ctx, n[:])
		hash.update(&ctx, der)
	}
	hash.update(&ctx, transmute([]byte)host)
	hash.final(&ctx, k[:])
	return
}

// verify_chain_cached is verify_chain_os behind the 30-minute result cache.
verify_chain_cached :: proc(chain: [][]byte, host: string) -> Error {
	k := trust_key(chain, host)
	now := time.tick_now()
	locks.lock(&trust_cache_mu)
	if exp, ok := trust_cache[k]; ok && time.tick_diff(now, exp) > 0 {
		locks.unlock(&trust_cache_mu)
		return .None
	}
	locks.unlock(&trust_cache_mu)
	verify_chain_os(chain, host) or_return
	locks.lock(&trust_cache_mu)
	defer locks.unlock(&trust_cache_mu)
	context.allocator = runtime.heap_allocator()
	if len(trust_cache) >= TRUST_CACHE_MAX {
		// Drop expired entries; if still full, start over (rare).
		expired := make([dynamic]Trust_Key, 0, 16, context.temp_allocator)
		for key, exp in trust_cache do if time.tick_diff(now, exp) <= 0 do append(&expired, key)
		for key in expired do delete_key(&trust_cache, key)
		if len(trust_cache) >= TRUST_CACHE_MAX do clear(&trust_cache)
	}
	trust_cache[k] = time.tick_add(now, TRUST_CACHE_TTL)
	return .None
}
