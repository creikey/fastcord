BROKEN_INITIAL :: 5 * time.Minute;
BROKEN_MAX :: 48 * time.Hour;
DELAY_MAIN_JOB_MULTIPLIER :: 1.5;
DELAY_MAIN_JOB_MAX :: 3 * time.Second;

Entry :: struct {
	port: int;
	expires: time.Time;
	broken_until: time.Time;
	broken_count: int;
}

Cache :: struct {
	mu: locks.Mutex;
	entries: Map(string, Entry);
	conns: Map(string, *quic.Conn); // live h3 connection per origin
	quic_works: bool; // QUIC succeeded on this network (enables delaying TCP)
	path: string; // persistence file, "" for memory only
}

Alternative :: struct {
	proto: string;
	host: string;
	port: int;
	ma: int; // seconds
}

// parse parses an Alt-Svc header value. clear=true for "clear".
parse :: (value: string, allocator := temp) -> [..]Alternative, bool {
	alts: [..]Alternative;
	clear: bool;
	alts = make_dynamic(Alternative, 0, 0, allocator);
	v := strings.trim_space(value);
	if v == "clear" { return alts, true; }
	it_ := v;
	while true { part, __ok1 := strings.split_iterator(*it_, ","); if !__ok1 break;
		a := Alternative.{ma = 86400};
		fields := part;
		first := true;
		while true { f, __ok2 := strings.split_iterator(*fields, ";"); if !__ok2 break;
			kv := strings.trim_space(f);
			eq := strings.index_byte(kv, #char "=");
			if eq < 0 { continue; }
			k, val := strings.trim_space(sub(kv, 0, eq)), strings.trim_space(sub_from(kv, eq + 1));
			if first {
				first = false;
				a.proto = k;
				val = strings.trim(val, "\"");
				colon := strings.last_index_byte(val, #char ":");
				if colon < 0 { break; }
				a.host = sub(val, 0, colon);
				p, ok := strconv.parse_int(sub_from(val, colon + 1));
				if !ok || p <= 0 || p > 65535 { break; }
				a.port = p;
			} else if k == "ma" {
				{ n, ok := strconv.parse_int(val);
				if ok && n >= 0 { a.ma = n; } }
			}
		}
		if a.proto != "" && a.port > 0 { append(*alts, a); }
	}
	return alts, false;
}

// record stores the h3 alternative advertised by a response from host.
record :: (c: *Cache, host: string, header_value: string, now_ := time.Time.{}) {
	now := ifx now_ != .{} then now_ else time.now();
	alts, clear := parse(header_value);
	locks.lock(*c.mu);
	defer locks.unlock(*c.mu);
	if clear {
		{ k, _, ok := map_entry_key(c, host);
		if ok {
			delete_key(*c.entries, host);
			delete(k);
		} }
		save_locked(c);
		return;
	}
	for a: alts {
		// Chrome uses only "h3" (RFC 9114) here, for the same host.
		if a.proto != "h3" || (a.host != "" && a.host != host) { continue; }
		e := or_else(get(c.entries, host), Entry.{});
		e.port = a.port;
		e.expires = time.time_add(now, time.Duration(a.ma) * time.Second);
		set_entry_locked(c, host, e);
		save_locked(c);
		return;
	}
}
#scope_module

map_entry_key :: (c: *Cache, host: string) -> string, Entry, bool {
	for k, v: c.entries { if k == host { return k, v, true; } }
	return "", .{}, false;
}

set_entry_locked :: (c: *Cache, host: string, e: Entry) {
	{ _, ok := map_find(c.entries, host);
	if ok {
		at(*c.entries, host).* = e;
	} else {
		at(*c.entries, clone(host)).* = e;
	} }
}
#scope_export

// usable reports whether h3 should be tried for host, and on which port.
usable :: (c: *Cache, host: string, now_ := time.Time.{}) -> int, bool {
	port: int;
	ok: bool;
	now := ifx now_ != .{} then now_ else time.now();
	locks.lock(*c.mu);
	defer locks.unlock(*c.mu);
	e, found := map_find(c.entries, host);
	if !found || time.diff(now, e.expires) <= 0 { return 0, false; }
	if time.diff(now, e.broken_until) > 0 { return 0, false; }
	return e.port, true;
}

// mark_broken records a QUIC failure for host (exponential backoff).
mark_broken :: (c: *Cache, host: string, now_ := time.Time.{}) {
	now := ifx now_ != .{} then now_ else time.now();
	locks.lock(*c.mu);
	defer locks.unlock(*c.mu);
	e, found := map_find(c.entries, host);
	if !found { return; }
	d := BROKEN_INITIAL * time.Duration(1 << cast(u64)(min(e.broken_count, 10)));
	e.broken_until = time.time_add(now, min(d, BROKEN_MAX));
	e.broken_count += 1;
	set_entry_locked(c, host, e);
	save_locked(c);
}

// mark_working clears the backoff after QUIC succeeded.
mark_working :: (c: *Cache, host: string) {
	locks.lock(*c.mu);
	defer locks.unlock(*c.mu);
	c.quic_works = true;
	e, found := map_find(c.entries, host);
	if !found || e.broken_count == 0 { return; }
	e.broken_count = 0;
	e.broken_until = .{};
	set_entry_locked(c, host, e);
	save_locked(c);
}

// load reads a cache saved by a previous run; expired entries are dropped.
load :: (c: *Cache, path: string) -> bool {
	c.path = clone(path);
	data, err := os.read_entire_file(path, temp);
	if err != null { return false; }
	now := time.now();
	locks.lock(*c.mu);
	defer locks.unlock(*c.mu);
	text := as_string(data);
	while true { line, __ok3 := strings.split_lines_iterator(*text); if !__ok3 break;
		f := strings.fields(line, temp);
		// "rtt <host> <us>": the server's smoothed RTT (Chrome network_stats.srtt)
		if len(f) == 3 && f[0] == "rtt" {
			{ us, ok := strconv.parse_u64(f[2]);
			if ok { quic.set_cached_rtt_us(f[1], us); } }
			continue;
		}
		if len(f) != 5 { continue; }
		port, ok1 := strconv.parse_int(f[1]);
		exp, ok2 := strconv.parse_i64(f[2]);
		bu, ok3 := strconv.parse_i64(f[3]);
		bc, ok4 := strconv.parse_int(f[4]);
		if !(ok1 && ok2 && ok3 && ok4) { continue; }
		e := Entry.{port, time.unix(exp, 0), time.unix(bu, 0), bc};
		if time.diff(now, e.expires) <= 0 { continue; }
		set_entry_locked(c, f[0], e);
	}
	return true;
}
#scope_module

save_locked :: (c: *Cache) {
	if c.path == "" { return; }
	b := strings.builder_make(temp);
	for host, e: c.entries {
		fmt.sbprintf(*b, "%s %d %d %d %d\n", host, e.port, time.to_unix_seconds(e.expires), time.to_unix_seconds(e.broken_until), e.broken_count);
	}
	for r: quic.cached_rtts(temp) { fmt.sbprintf(*b, "rtt %s %d\n", r.host, r.us); }
	tmp := strings.concatenate(.{c.path, ".tmp"}, temp);
	if os.write_entire_file(tmp, transmute([]u8, strings.to_string(b))) == null {
		os.rename(tmp, c.path);
	}
}
#scope_export

destroy :: (c: *Cache) {
	for k, conn: c.conns {
		quic.close(conn); // records the session's RTT
		delete(k);
	}
	delete(c.conns);
	// persist the RTTs learned this session with the alternatives
	locks.lock(*c.mu);
	save_locked(c);
	locks.unlock(*c.mu);
	for k: c.entries { delete(k); }
	delete(c.entries);
	delete(c.path);
}

Protocol :: enum u8 {
	H2; // TCP (the caller's h2/h1 connection)
	H3;
}

// Tcp_Dialer opens the caller's TCP+TLS(+h2) connection; Tcp_Closer closes one.
Tcp_Dialer :: (host: string, user: *void) -> *void, bool;
Tcp_Closer :: (conn: *void, user: *void);

Result :: struct {
	proto: Protocol;
	h3: *quic.Conn; // owned by the cache (reused); do not close
	tcp: *void; // owned by the caller
}
#scope_module

Race :: struct {
	mu: locks.Mutex;
	cond: locks.Cond;
	cache: *Cache;
	host: string;
	port: int;
	dial: Tcp_Dialer;
	closer: Tcp_Closer;
	user: *void;
	delay: time.Duration;
	start_tcp: bool;
	quic_done: bool;
	quic_ok: bool;
	quic_conn: *quic.Conn;
	tcp_done: bool;
	tcp_ok: bool;
	tcp_conn: *void;
	winner: int; // 0 none, 1 quic, 2 tcp
	refs: int;
}
#scope_export

// connect returns a connection for host following Chrome's logic. With no
// usable alternative it dials TCP only; otherwise it races QUIC and TCP.
connect :: (c: *Cache, host: string, dial: Tcp_Dialer, closer: Tcp_Closer, user: *void) -> Result, bool {
	res: Result;
	ok: bool;
	// Reuse a live session.
	locks.lock(*c.mu);
	{ conn, found := map_find(c.conns, host);
	if found {
		if quic.can_open(conn) {
			locks.unlock(*c.mu);
			return .{proto = .H3, h3 = conn}, true;
		}
		quic.close(conn);
		for k: c.conns { if k == host {
			delete_key(*c.conns, host);
			delete(k);
			break;
		} }
	} }
	locks.unlock(*c.mu);

	port, use_h3 := usable(c, host);
	if !use_h3 {
		tc, tok := dial(host, user);
		return .{proto = .H2, tcp = tc}, tok;
	}

	r := new(Race, runtime.heap_allocator());
	r.cache = c;
	r.host = clone(host, runtime.heap_allocator());
	r.port = port;
	r.dial = dial;
	r.closer = closer;
	r.user = user;
	r.refs = 3;
	locks.lock(*c.mu);
	known := c.quic_works;
	locks.unlock(*c.mu);
	if known {
		rtt := time.Duration(quic.cached_rtt_us(host)) * time.Microsecond;
		r.delay = min(time.Duration(cast(float64)(rtt) * DELAY_MAIN_JOB_MULTIPLIER), DELAY_MAIN_JOB_MAX);
	}
	thread.run_with_poly_data(r, quic_job, init_context = context);
	thread.run_with_poly_data(r, tcp_job, init_context = context);

	locks.lock(*r.mu);
	while r.winner == 0 && !(r.quic_done && r.tcp_done) { locks.cond_wait(*r.cond, *r.mu); }
	if r.winner == {
	case 1;
		res = .{proto = .H3, h3 = r.quic_conn};
		ok = true;
	case 2;
		res = .{proto = .H2, tcp = r.tcp_conn};
		ok = true;
	}
	locks.unlock(*r.mu);
	race_release(r);
	return res, ok;
}
#scope_module

race_release :: (r: *Race) {
	locks.lock(*r.mu);
	r.refs -= 1;
	last := r.refs == 0;
	locks.unlock(*r.mu);
	if last {
		delete(r.host, runtime.heap_allocator());
		free(r, runtime.heap_allocator());
	}
}

// quic_job: Chrome's QUIC job. It wins when the handshake completes. A handshake failure while TCP works
// marks the alternative broken.
quic_job :: (r: *Race) {
	conn, err := quic.connect(r.host, r.port);
	quic_job_result(r, conn, err == .None);
	if err == .None {
		mark_working(r.cache, r.host);
	} else {
		// Broken only if TCP works (else the network or origin is just down).
		locks.lock(*r.mu);
		while !r.tcp_done { locks.cond_wait(*r.cond, *r.mu); }
		tcp_ok := r.tcp_ok;
		locks.unlock(*r.mu);
		if tcp_ok { mark_broken(r.cache, r.host); }
	}
	race_release(r);
}

quic_job_result :: (r: *Race, conn: *quic.Conn, ok: bool) {
	locks.lock(*r.mu);
	r.quic_done = true;
	r.quic_ok = ok;
	if ok {
		r.quic_conn = conn;
		if r.winner == 0 { r.winner = 1; }
	}
	tcp_won := r.winner == 2;
	locks.cond_broadcast(*r.cond);
	locks.unlock(*r.mu);
	if !ok { return; }
	// Keep the session for reuse whether or not it won this race.
	locks.lock(*r.cache.mu);
	{ _, found := map_find(r.cache.conns, r.host);
	if !found {
		at(*r.cache.conns, clone(r.host)).* = conn;
	} else if tcp_won {
		quic.close(conn);
	} }
	locks.unlock(*r.cache.mu);
}

tcp_job :: (r: *Race) {
	if r.delay > 0 {
		deadline := time.tick_add(time.tick_now(), r.delay);
		locks.lock(*r.mu);
		while !r.quic_done && time.tick_diff(time.tick_now(), deadline) > 0 {
			locks.cond_wait_with_timeout(*r.cond, *r.mu, time.tick_diff(time.tick_now(), deadline));
		}
		skip := r.quic_ok;
		locks.unlock(*r.mu);
		if skip {
			// QUIC won before TCP was needed (Chrome cancels the main job).
			locks.lock(*r.mu);
			r.tcp_done = true;
			locks.cond_broadcast(*r.cond);
			locks.unlock(*r.mu);
			race_release(r);
			return;
		}
	}
	conn, ok := r.dial(r.host, r.user);
	locks.lock(*r.mu);
	r.tcp_done = true;
	r.tcp_ok = ok;
	lost := false;
	if ok {
		r.tcp_conn = conn;
		if r.winner == 0 {
			r.winner = 2;
		} else {
			lost = true;
		}
	}
	locks.cond_broadcast(*r.cond);
	locks.unlock(*r.mu);
	if lost && r.closer != null { r.closer(conn, r.user); }
	race_release(r);
}
#scope_export

