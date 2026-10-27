// Chrome's CachingCertVerifier keeps verification results for 30 minutes,
// keyed by the chain and hostname; repeat full handshakes to the same
// origin skip the 2-7 ms OS trust evaluation. Only successes are cached.
TRUST_CACHE_TTL :: 30 * time.Minute;
TRUST_CACHE_MAX :: 256;
#scope_module

Trust_Key :: [32]u8;

trust_cache_mu: locks.Mutex;
// Hash_Table can't compare [32]u8 keys with ==, so the table gets its own hash and compare.
trust_cache: Table(Trust_Key, time.Tick, (k: Trust_Key) -> u32 { return (cast(*u32) k.data).*; }, (a: Trust_Key, b: Trust_Key) -> bool { return memcmp(a.data, b.data, 32) == 0; });

trust_key :: (chain: [][]u8, host: string) -> Trust_Key {
	k: Trust_Key;
	ctx: hash.Context;
	hash.init(*ctx, .SHA256);
	n: [4]u8;
	for der: chain {
		l := len(der);
		n = .[cast(u8)(l >> 24), cast(u8)(l >> 16), cast(u8)(l >> 8), cast(u8)(l)];
		hash.update(*ctx, view(n));
		hash.update(*ctx, der);
	}
	hash.update(*ctx, transmute([]u8, host));
	hash.final(*ctx, view(k));
	return k;
}
#scope_export

// verify_chain_cached is verify_chain_os behind the 30-minute result cache.
verify_chain_cached :: (chain: [][]u8, host: string) -> Error {
	k := trust_key(chain, host);
	now := time.tick_now();
	locks.lock(*trust_cache_mu);
	{ exp := table_find_pointer(*trust_cache, k);
	if exp && time.tick_diff(now, exp.*) > 0 {
		locks.unlock(*trust_cache_mu);
		return .None;
	} }
	locks.unlock(*trust_cache_mu);
	__e1 := verify_chain_os(chain, host); if failed(__e1) return __e1;
	locks.lock(*trust_cache_mu);
	defer locks.unlock(*trust_cache_mu);
	push_allocator(context.default_allocator);
	if trust_cache.count >= TRUST_CACHE_MAX {
		// Drop expired entries; if still full, start over (rare).
		expired := make_dynamic(Trust_Key, 0, 16, temp);
		for exp, key: trust_cache { if time.tick_diff(now, exp) <= 0 { append(*expired, key); } }
		for key: expired { table_remove(*trust_cache, key); }
		if trust_cache.count >= TRUST_CACHE_MAX { table_reset(*trust_cache); }
	}
	table_set(*trust_cache, k, time.tick_add(now, TRUST_CACHE_TTL));
	return .None;
}

