// Chrome's CachingCertVerifier keeps verification results for 30 minutes, keyed by the chain and hostname;
// repeat full handshakes to the same origin skip the 2-7 ms OS trust evaluation. Only successes are cached.
TRUST_CACHE_TTL_MS :: 30 * 60 * 1000;
TRUST_CACHE_MAX :: 256;

// verify_chain_cached is verify_chain_os behind the 30-minute result cache.
verify_chain_cached :: (chain: [][]u8, host: string) -> Error {
	k := trust_key(chain, host);
	now := current_time_monotonic();
	{
		locks.guard(*trust_cache_mu);
		exp := table_find_pointer(*trust_cache, k);
		if exp && exp.* > now return .None;
	}
	err := verify_chain_os(chain, host);
	if err != .None return err;
	locks.guard(*trust_cache_mu);
	push_allocator(Context_Base.default_allocator);
	if trust_cache.count >= TRUST_CACHE_MAX {
		// Drop expired entries; if still full, start over (rare).
		for trust_cache if it <= now remove it;
		if trust_cache.count >= TRUST_CACHE_MAX table_reset(*trust_cache);
	}
	table_set(*trust_cache, k, now + milliseconds_to_apollo(TRUST_CACHE_TTL_MS));
	return .None;
}

#scope_file

Trust_Key :: [32]u8;

trust_cache_mu: locks.Mutex;
// A [32]u8 key has no == or hash of its own.
trust_cache: Table(Trust_Key, Apollo_Time, (k: Trust_Key) -> u32 { return (cast(*u32) k.data).*; }, (a: Trust_Key, b: Trust_Key) -> bool { return memcmp(a.data, b.data, 32) == 0; });

// trust_key: SHA-256 over each certificate's 4-byte big-endian length and DER, then the host.
trust_key :: (chain: [][]u8, host: string) -> Trust_Key {
	buf: [..]u8;
	buf.allocator = temp;
	for der: chain {
		l := der.count;
		array_add(*buf, cast(u8) (l >> 24), cast(u8) (l >> 16), cast(u8) (l >> 8), cast(u8) l);
		array_add(*buf, ..der);
	}
	array_add(*buf, ..cast([]u8) host);
	return crypto.sha256(buf);
}
