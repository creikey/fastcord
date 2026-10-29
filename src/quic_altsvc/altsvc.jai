BROKEN_INITIAL_MS :: 5 * 60 * 1000;
BROKEN_MAX_MS :: 48 * 60 * 60 * 1000;
DELAY_MAIN_JOB_MULTIPLIER :: 1.5;
DELAY_MAIN_JOB_MAX_NS :: 3_000_000_000;

Entry :: struct {
	port: int;
	expires: Apollo_Time;
	broken_until: Apollo_Time; // zero: not broken
	broken_count: int;
}

// Cache is shared by every thread that connects; its memory is on the heap.
Cache :: struct {
	mu: locks.Mutex;
	entries: Table(string, Entry);
	conns: Table(string, *quic.Conn); // live h3 connection per origin
	quic_works: bool;                 // QUIC succeeded on this network (enables delaying TCP)
	path: string;                     // persistence file, "" for memory only
	races: [..]*Race;                 // finished races whose job threads are still to be joined
}

Alternative :: struct {
	proto: string;
	host: string;
	port: int;
	ma: int; // seconds
}

// parse parses an Alt-Svc header value into temp; clear is true for "clear".
parse :: (value: string) -> [..]Alternative, clear: bool {
	alts: [..]Alternative;
	alts.allocator = temp;
	v := trim(value);
	if v == "clear" return alts, true;
	while v {
		a := Alternative.{ma = 86400};
		fields := next_part(*v, #char ",");
		first := true;
		while fields {
			found, k, val := split_from_left(trim(next_part(*fields, #char ";")), #char "=");
			if !found continue;
			k, val = trim(k), trim(val);
			if first {
				first = false;
				a.proto = k;
				colon, host, port := split_from_right(trim(val, "\""), #char ":");
				if !colon break;
				a.host = host;
				p, ok := parse_int(port);
				if !ok || p <= 0 || p > 65535 break;
				a.port = p;
			} else if k == "ma" {
				n, ok := parse_int(val);
				if ok && n >= 0 a.ma = n;
			}
		}
		if a.proto && a.port > 0 array_add(*alts, a);
	}
	return alts, false;
}

// record stores the h3 alternative advertised by a response from host.
record :: (c: *Cache, host: string, header_value: string) {
	now := current_time_consensus();
	alts, clear := parse(header_value);
	locks.guard(*c.mu);
	push_allocator(Context_Base.default_allocator);
	if clear {
		for * c.entries if it_index == host { free(it_index); remove it; break; }
		save_locked(c);
		return;
	}
	for alts {
		// Chrome uses only "h3" (RFC 9114) here, for the same host.
		if it.proto != "h3" || (it.host && it.host != host) continue;
		_, e := table_find(*c.entries, host);
		e.port = it.port;
		e.expires = now + seconds_to_apollo(it.ma);
		set_entry_locked(c, host, e);
		save_locked(c);
		return;
	}
}

// usable reports whether h3 should be tried for host, and on which port.
usable :: (c: *Cache, host: string) -> port: int, ok: bool {
	now := current_time_consensus();
	locks.guard(*c.mu);
	found, e := table_find(*c.entries, host);
	if !found || e.expires <= now || e.broken_until > now return 0, false;
	return e.port, true;
}

// mark_broken records a QUIC failure for host (exponential backoff).
mark_broken :: (c: *Cache, host: string) {
	now := current_time_consensus();
	locks.guard(*c.mu);
	push_allocator(Context_Base.default_allocator);
	found, e := table_find(*c.entries, host);
	if !found return;
	e.broken_until = now + milliseconds_to_apollo(min(BROKEN_INITIAL_MS << min(e.broken_count, 10), BROKEN_MAX_MS));
	e.broken_count += 1;
	set_entry_locked(c, host, e);
	save_locked(c);
}

// mark_working clears the backoff after QUIC succeeded.
mark_working :: (c: *Cache, host: string) {
	locks.guard(*c.mu);
	push_allocator(Context_Base.default_allocator);
	c.quic_works = true;
	e := table_find_pointer(*c.entries, host);
	if !e || !e.broken_count return;
	e.broken_count = 0;
	e.broken_until = .{};
	save_locked(c);
}

// load reads a cache saved by a previous run; expired entries are dropped.
load :: (c: *Cache, path: string) -> bool {
	c.path = copy_string(path,, Context_Base.default_allocator);
	text, ok := read_entire_file(path, log_errors = false,, temp);
	if !ok return false;
	now := current_time_consensus();
	locks.guard(*c.mu);
	push_allocator(Context_Base.default_allocator);
	while text {
		f: [6]string;
		n := 0;
		line := trim_right(next_part(*text, #char "\n"), "\r");
		while line && n < f.count {
			line = trim_left(line, " \t");
			if !line break;
			end := 0;
			while end < line.count && line[end] != #char " " && line[end] != #char "\t" end += 1;
			f[n] = slice(line, 0, end);
			n += 1;
			advance(*line, end);
		}
		// "rtt <host> <us>": the server's smoothed RTT (Chrome network_stats.srtt)
		if n == 3 && f[0] == "rtt" {
			us, uok := parse_int(f[2], u64);
			if uok quic.set_cached_rtt_us(f[1], us);
			continue;
		}
		if n != 5 continue;
		port, ok1 := parse_int(f[1]);
		exp, ok2 := parse_int(f[2]);
		bu, ok3 := parse_int(f[3]);
		bc, ok4 := parse_int(f[4]);
		if !(ok1 && ok2 && ok3 && ok4) continue;
		e := Entry.{port, from_unix(exp), from_unix(bu), bc};
		if e.expires <= now continue;
		set_entry_locked(c, f[0], e);
	}
	return true;
}

// destroy waits for connects still racing, closes the live sessions (recording their RTTs), saves the
// cache and frees it.
destroy :: (c: *Cache) {
	locks.lock(*c.mu);
	races := c.races;
	c.races.data, c.races.count, c.races.allocated = null, 0, 0;
	locks.unlock(*c.mu);
	for races race_free(it, wait = true);
	array_free(races,, Context_Base.default_allocator);
	push_allocator(Context_Base.default_allocator);
	for c.conns {
		quic.close(it); // records the session's RTT
		free(it_index);
	}
	deinit(*c.conns);
	// persist the RTTs learned this session with the alternatives
	locks.lock(*c.mu);
	save_locked(c);
	locks.unlock(*c.mu);
	for c.entries free(it_index);
	deinit(*c.entries);
	free_string(c.path);
	c.path = "";
}

Protocol :: enum u8 {
	H2; // TCP (the caller's h2/h1 connection)
	H3;
}

// Tcp_Dialer opens the caller's TCP+TLS(+h2) connection; Tcp_Closer closes one.
Tcp_Dialer :: #type (host: string, user: *void) -> *void, bool;
Tcp_Closer :: #type (conn: *void, user: *void);

Result :: struct {
	proto: Protocol;
	h3: *quic.Conn; // owned by the cache (reused); do not close
	tcp: *void;     // owned by the caller
}

// connect returns a connection for host following Chrome's logic. With no usable alternative it dials TCP
// only; otherwise it races QUIC and TCP on two threads.
connect :: (c: *Cache, host: string, dial: Tcp_Dialer, closer: Tcp_Closer, user: *void) -> Result, bool {
	// Reuse a live session.
	{
		locks.guard(*c.mu);
		found, conn := table_find(*c.conns, host);
		if found {
			if quic.can_open(conn) return .{proto = .H3, h3 = conn}, true;
			quic.close(conn);
			for c.conns if it_index == host { free(it_index,, Context_Base.default_allocator); remove it; break; }
		}
	}

	port, use_h3 := usable(c, host);
	if !use_h3 {
		tc, tok := dial(host, user);
		return .{proto = .H2, tcp = tc}, tok;
	}

	r := New(Race,, Context_Base.default_allocator);
	r.cache, r.port, r.dial, r.closer, r.user = c, port, dial, closer, user;
	r.host = copy_string(host,, Context_Base.default_allocator);
	locks.lock(*c.mu);
	known := c.quic_works;
	locks.unlock(*c.mu);
	if known {
		rtt_ns := cast(s64) quic.cached_rtt_us(host) * 1000;
		r.delay_ns = min(cast(s64) (cast(float64) rtt_ns * DELAY_MAIN_JOB_MULTIPLIER), DELAY_MAIN_JOB_MAX_NS);
	}
	start :: (t: *Thread, r: *Race, job: (*Thread) -> s64) {
		thread_init(t, job);
		t.data = r;
		thread_start(t);
	}
	start(*r.quic_thread, r, quic_job);
	start(*r.tcp_thread, r, tcp_job);

	res: Result;
	ok: bool;
	locks.lock(*r.mu);
	while r.winner == .None && !(r.quic_done && r.tcp_done) locks.cond_wait(*r.cond, *r.mu);
	if r.winner == .Quic { res, ok = .{proto = .H3, h3 = r.quic_conn}, true; }
	if r.winner == .Tcp  { res, ok = .{proto = .H2, tcp = r.tcp_conn}, true; }
	locks.unlock(*r.mu);

	// The losing job may still be running: its thread is joined by a later connect, or by destroy.
	locks.lock(*c.mu);
	kept: [..]*Race;
	kept.allocator = Context_Base.default_allocator;
	for c.races if !race_free(it, wait = false) array_add(*kept, it);
	array_add(*kept, r);
	array_free(c.races,, Context_Base.default_allocator);
	c.races = kept;
	locks.unlock(*c.mu);
	return res, ok;
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
	delay_ns: s64;
	quic_done, quic_ok: bool;
	quic_conn: *quic.Conn;
	tcp_done, tcp_ok: bool;
	tcp_conn: *void;
	winner: enum u8 { None; Quic; Tcp; };
	jobs_done: int;
	quic_thread, tcp_thread: Thread;
}

// race_free joins r's threads and frees it, once both jobs are done (or, with wait, after waiting for
// them); false if they are still running.
race_free :: (r: *Race, wait: bool) -> bool {
	locks.lock(*r.mu);
	done := r.jobs_done == 2;
	locks.unlock(*r.mu);
	if !done && !wait return false;
	thread_is_done(*r.quic_thread, -1);
	thread_is_done(*r.tcp_thread, -1);
	thread_deinit(*r.quic_thread);
	thread_deinit(*r.tcp_thread);
	free(r.host,, Context_Base.default_allocator);
	free(r,, Context_Base.default_allocator);
	return true;
}

job_done :: (r: *Race) {
	locks.guard(*r.mu);
	r.jobs_done += 1;
}

// quic_job: Chrome's QUIC job. It wins when the handshake completes. A handshake failure while TCP works
// marks the alternative broken.
quic_job :: (t: *Thread) -> s64 {
	r := cast(*Race) t.data;
	defer job_done(r);
	conn, err := quic.connect(r.host, r.port);
	ok := err == .None;
	locks.lock(*r.mu);
	r.quic_done, r.quic_ok = true, ok;
	if ok {
		r.quic_conn = conn;
		if r.winner == .None r.winner = .Quic;
	}
	tcp_won := r.winner == .Tcp;
	locks.cond_broadcast(*r.cond);
	locks.unlock(*r.mu);
	if ok {
		// Keep the session for reuse whether or not it won this race.
		c := r.cache;
		locks.lock(*c.mu);
		if !table_contains(*c.conns, r.host) table_add(*c.conns, copy_string(r.host,, Context_Base.default_allocator), conn);
		else if tcp_won quic.close(conn);
		locks.unlock(*c.mu);
		mark_working(c, r.host);
	} else {
		// Broken only if TCP works (else the network or origin is just down).
		locks.lock(*r.mu);
		while !r.tcp_done locks.cond_wait(*r.cond, *r.mu);
		tcp_ok := r.tcp_ok;
		locks.unlock(*r.mu);
		if tcp_ok mark_broken(r.cache, r.host);
	}
	return 0;
}

tcp_job :: (t: *Thread) -> s64 {
	r := cast(*Race) t.data;
	defer job_done(r);
	if r.delay_ns > 0 {
		deadline := current_time_monotonic() + nanoseconds_to_apollo(r.delay_ns);
		locks.lock(*r.mu);
		while !r.quic_done {
			left_ns := to_nanoseconds(deadline - current_time_monotonic());
			if left_ns <= 0 break;
			locks.cond_wait_with_timeout(*r.cond, *r.mu, (left_ns + 999_999) / 1_000_000);
		}
		skip := r.quic_ok;
		if skip {
			// QUIC won before TCP was needed (Chrome cancels the main job).
			r.tcp_done = true;
			locks.cond_broadcast(*r.cond);
		}
		locks.unlock(*r.mu);
		if skip return 0;
	}
	conn, ok := r.dial(r.host, r.user);
	locks.lock(*r.mu);
	r.tcp_done, r.tcp_ok = true, ok;
	lost := false;
	if ok {
		r.tcp_conn = conn;
		if r.winner == .None r.winner = .Tcp;
		else lost = true;
	}
	locks.cond_broadcast(*r.cond);
	locks.unlock(*r.mu);
	if lost && r.closer r.closer(conn, r.user);
	return 0;
}

// next_part cuts s at its first sep and returns what came before. Looping `while s` visits every part but
// a trailing empty one.
next_part :: (s: *string, sep: u8) -> string {
	found, part, rest := split_from_left(s.*, sep);
	s.* = rest;
	return part;
}

parse_int :: (s: string, $T := int) -> T, bool {
	n, ok, rest := string_to_int(s, 10, T);
	return n, ok && !rest;
}

set_entry_locked :: (c: *Cache, host: string, e: Entry) {
	p := table_find_pointer(*c.entries, host);
	if p p.* = e;
	else table_add(*c.entries, copy_string(host), e);
}

// The file stores Unix seconds; 0 stands for a zero time.
to_unix :: (t: Apollo_Time) -> s64 { return ifx t == .{} then 0 else to_seconds(t - APOLLO_TIME_FOR_JAN_1_1970); }
from_unix :: (s: s64) -> Apollo_Time { return ifx s then seconds_to_apollo(s) + APOLLO_TIME_FOR_JAN_1_1970 else .{}; }

save_locked :: (c: *Cache) {
	if !c.path return;
	b: String_Builder;
	b.allocator = temp;
	for c.entries print_to_builder(*b, "% % % % %\n", it_index, it.port, to_unix(it.expires), to_unix(it.broken_until), it.broken_count);
	for quic.cached_rtts(,, temp) print_to_builder(*b, "rtt % %\n", it.host, it.us);
	tmp := tprint("%.tmp", c.path);
	if write_entire_file(tmp, *b) File_Utilities.atomic_file_replace_or_just_rename_if_destination_file_does_not_exist(tmp, c.path);
}

free_string :: (s: string) { if s.count free(s.data); }
