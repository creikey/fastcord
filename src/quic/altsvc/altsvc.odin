// Package altsvc mirrors Chrome's choice between HTTP/2 (TCP) and HTTP/3
// (QUIC) for an origin:
//
//   - First contact uses TCP. Alt-Svc response headers (h3=":443"; ma=N) are
//     recorded with their expiry and persisted to disk.
//   - Later connects race: the QUIC job starts at once; the TCP job starts
//     immediately, or 1.5 x the cached RTT later if QUIC is known to work on
//     this network (Chrome's delay_main_job). The first to succeed wins.
//   - If QUIC fails while TCP works, the alternative is marked broken for
//     5 minutes, doubling per failure up to 2 days
//     (BrokenAlternativeServices), and TCP is used meanwhile.
//   - An established h3 connection is reused for the origin while it is open
//     (Chrome keeps one QUIC session per origin; it idles out after 30s).
package altsvc

import "fc:locks"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:thread"
import "core:time"

import "fc:quic"
import "fc:quic/h3"

BROKEN_INITIAL :: 5 * time.Minute
BROKEN_MAX :: 48 * time.Hour
DELAY_MAIN_JOB_MULTIPLIER :: 1.5
DELAY_MAIN_JOB_MAX :: 3 * time.Second

Entry :: struct {
	port:         int,
	expires:      time.Time,
	broken_until: time.Time,
	broken_count: int,
}

Cache :: struct {
	mu:            locks.Mutex,
	entries:       map[string]Entry,
	conns:         map[string]^h3.Conn, // live h3 connection per origin
	quic_works:    bool, // QUIC succeeded on this network (enables delaying TCP)
	path:          string, // persistence file, "" for memory only
}

Alternative :: struct {
	proto: string,
	host:  string,
	port:  int,
	ma:    int, // seconds
}

// parse parses an Alt-Svc header value. clear=true for "clear".
parse :: proc(value: string, allocator := context.temp_allocator) -> (alts: [dynamic]Alternative, clear: bool) {
	alts = make([dynamic]Alternative, allocator)
	v := strings.trim_space(value)
	if v == "clear" do return alts, true
	it := v
	for part in strings.split_iterator(&it, ",") {
		a := Alternative{ma = 86400}
		fields := part
		first := true
		for f in strings.split_iterator(&fields, ";") {
			kv := strings.trim_space(f)
			eq := strings.index_byte(kv, '=')
			if eq < 0 do continue
			k, val := strings.trim_space(kv[:eq]), strings.trim_space(kv[eq + 1:])
			if first {
				first = false
				a.proto = k
				val = strings.trim(val, "\"")
				colon := strings.last_index_byte(val, ':')
				if colon < 0 do break
				a.host = val[:colon]
				p, ok := strconv.parse_int(val[colon + 1:])
				if !ok || p <= 0 || p > 65535 do break
				a.port = p
			} else if k == "ma" {
				if n, ok := strconv.parse_int(val); ok && n >= 0 do a.ma = n
			}
		}
		if a.proto != "" && a.port > 0 do append(&alts, a)
	}
	return alts, false
}

// record stores the h3 alternative advertised by a response from host.
record :: proc(c: ^Cache, host: string, header_value: string, now_ := time.Time{}) {
	now := now_ if now_ != {} else time.now()
	alts, clear := parse(header_value)
	locks.lock(&c.mu)
	defer locks.unlock(&c.mu)
	if clear {
		if k, _, ok := map_entry_key(c, host); ok {
			delete_key(&c.entries, host)
			delete(k)
		}
		save_locked(c)
		return
	}
	for a in alts {
		// Chrome uses only "h3" (RFC 9114) here, for the same host.
		if a.proto != "h3" || (a.host != "" && a.host != host) do continue
		e := c.entries[host] or_else Entry{}
		e.port = a.port
		e.expires = time.time_add(now, time.Duration(a.ma) * time.Second)
		set_entry_locked(c, host, e)
		save_locked(c)
		return
	}
}

@(private)
map_entry_key :: proc(c: ^Cache, host: string) -> (string, Entry, bool) {
	for k, v in c.entries do if k == host do return k, v, true
	return "", {}, false
}

@(private)
set_entry_locked :: proc(c: ^Cache, host: string, e: Entry) {
	if _, ok := c.entries[host]; ok {
		c.entries[host] = e
	} else {
		c.entries[strings.clone(host)] = e
	}
}

// usable reports whether h3 should be tried for host, and on which port.
usable :: proc(c: ^Cache, host: string, now_ := time.Time{}) -> (port: int, ok: bool) {
	now := now_ if now_ != {} else time.now()
	locks.lock(&c.mu)
	defer locks.unlock(&c.mu)
	e, found := c.entries[host]
	if !found || time.diff(now, e.expires) <= 0 do return 0, false
	if time.diff(now, e.broken_until) > 0 do return 0, false
	return e.port, true
}

// mark_broken records a QUIC failure for host (exponential backoff).
mark_broken :: proc(c: ^Cache, host: string, now_ := time.Time{}) {
	now := now_ if now_ != {} else time.now()
	locks.lock(&c.mu)
	defer locks.unlock(&c.mu)
	e, found := c.entries[host]
	if !found do return
	d := BROKEN_INITIAL * time.Duration(1 << uint(min(e.broken_count, 10)))
	e.broken_until = time.time_add(now, min(d, BROKEN_MAX))
	e.broken_count += 1
	set_entry_locked(c, host, e)
	save_locked(c)
}

// mark_working clears the backoff after QUIC succeeded.
mark_working :: proc(c: ^Cache, host: string) {
	locks.lock(&c.mu)
	defer locks.unlock(&c.mu)
	c.quic_works = true
	e, found := c.entries[host]
	if !found || e.broken_count == 0 do return
	e.broken_count = 0
	e.broken_until = {}
	set_entry_locked(c, host, e)
	save_locked(c)
}

// load reads a cache saved by a previous run; expired entries are dropped.
load :: proc(c: ^Cache, path: string) -> bool {
	c.path = strings.clone(path)
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil do return false
	now := time.now()
	locks.lock(&c.mu)
	defer locks.unlock(&c.mu)
	text := string(data)
	for line in strings.split_lines_iterator(&text) {
		f := strings.fields(line, context.temp_allocator)
		if len(f) != 5 do continue
		port, ok1 := strconv.parse_int(f[1])
		exp, ok2 := strconv.parse_i64(f[2])
		bu, ok3 := strconv.parse_i64(f[3])
		bc, ok4 := strconv.parse_int(f[4])
		if !(ok1 && ok2 && ok3 && ok4) do continue
		e := Entry{port, time.unix(exp, 0), time.unix(bu, 0), bc}
		if time.diff(now, e.expires) <= 0 do continue
		set_entry_locked(c, f[0], e)
	}
	return true
}

@(private)
save_locked :: proc(c: ^Cache) {
	if c.path == "" do return
	b := strings.builder_make(context.temp_allocator)
	for host, e in c.entries {
		fmt.sbprintf(&b, "%s %d %d %d %d\n", host, e.port, time.to_unix_seconds(e.expires), time.to_unix_seconds(e.broken_until), e.broken_count)
	}
	tmp := strings.concatenate({c.path, ".tmp"}, context.temp_allocator)
	if os.write_entire_file(tmp, transmute([]byte)strings.to_string(b)) == nil {
		os.rename(tmp, c.path)
	}
}

destroy :: proc(c: ^Cache) {
	for k in c.entries do delete(k)
	delete(c.entries)
	for k, conn in c.conns {
		h3.close(conn)
		delete(k)
	}
	delete(c.conns)
	delete(c.path)
}

Protocol :: enum u8 {
	H2, // TCP (the caller's h2/h1 connection)
	H3,
}

// Tcp_Dialer opens the caller's TCP+TLS(+h2) connection; Tcp_Closer closes one.
Tcp_Dialer :: proc(host: string, user: rawptr) -> (conn: rawptr, ok: bool)
Tcp_Closer :: proc(conn: rawptr, user: rawptr)

Result :: struct {
	proto: Protocol,
	h3:    ^h3.Conn, // owned by the cache (reused); do not close
	tcp:   rawptr, // owned by the caller
}

@(private)
Race :: struct {
	mu:         locks.Mutex,
	cond:       locks.Cond,
	cache:      ^Cache,
	host:       string,
	h3cfg:      h3.Config,
	dial:       Tcp_Dialer,
	closer:     Tcp_Closer,
	user:       rawptr,
	delay:      time.Duration,
	start_tcp:  bool,
	quic_done:  bool,
	quic_ok:    bool,
	quic_conn:  ^h3.Conn,
	tcp_done:   bool,
	tcp_ok:     bool,
	tcp_conn:   rawptr,
	winner:     int, // 0 none, 1 quic, 2 tcp
	refs:       int,
}

// connect returns a connection for host following Chrome's logic. With no
// usable alternative it dials TCP only; otherwise it races QUIC and TCP.
connect :: proc(c: ^Cache, host: string, dial: Tcp_Dialer, closer: Tcp_Closer, user: rawptr, h3cfg := h3.Config{}) -> (res: Result, ok: bool) {
	// Reuse a live session.
	locks.lock(&c.mu)
	if conn, found := c.conns[host]; found {
		if h3.can_open(conn) {
			locks.unlock(&c.mu)
			return {proto = .H3, h3 = conn}, true
		}
		h3.close(conn)
		for k in c.conns do if k == host {
			delete_key(&c.conns, host)
			delete(k)
			break
		}
	}
	locks.unlock(&c.mu)

	port, use_h3 := usable(c, host)
	if !use_h3 {
		tc, tok := dial(host, user)
		return {proto = .H2, tcp = tc}, tok
	}

	r := new(Race, quic.conn_allocator())
	r.cache = c
	r.host = strings.clone(host, quic.conn_allocator())
	r.h3cfg = h3cfg
	r.h3cfg.quic.port = port
	r.dial = dial
	r.closer = closer
	r.user = user
	r.refs = 3
	locks.lock(&c.mu)
	known := c.quic_works
	locks.unlock(&c.mu)
	if known {
		rtt := time.Duration(quic.cached_rtt_us(host)) * time.Microsecond
		r.delay = min(time.Duration(f64(rtt) * DELAY_MAIN_JOB_MULTIPLIER), DELAY_MAIN_JOB_MAX)
	}
	thread.run_with_poly_data(r, quic_job, init_context = context)
	thread.run_with_poly_data(r, tcp_job, init_context = context)

	locks.lock(&r.mu)
	for r.winner == 0 && !(r.quic_done && r.tcp_done) do locks.cond_wait(&r.cond, &r.mu)
	switch r.winner {
	case 1:
		res = {proto = .H3, h3 = r.quic_conn}
		ok = true
	case 2:
		res = {proto = .H2, tcp = r.tcp_conn}
		ok = true
	}
	locks.unlock(&r.mu)
	race_release(r)
	return
}

@(private)
race_release :: proc(r: ^Race) {
	locks.lock(&r.mu)
	r.refs -= 1
	last := r.refs == 0
	locks.unlock(&r.mu)
	if last {
		delete(r.host, quic.conn_allocator())
		free(r, quic.conn_allocator())
	}
}

// quic_job: Chrome's QUIC job. With 0-RTT the session is usable as soon as
// the ClientHello is out, so it wins at once and the first requests go early;
// otherwise it wins when the handshake completes. Only a handshake failure
// (while TCP works) marks the alternative broken; a rejected 0-RTT attempt is
// not a failure (the data is resent in 1-RTT), matching Chrome.
@(private)
quic_job :: proc(r: ^Race) {
	conn, err := h3.connect(r.host, r.h3cfg)
	early := err == .None && quic.early_state(conn.q) == .Sending
	if early do quic_job_result(r, conn, true)
	if err == .None && quic.wait_handshake(conn.q) != .None {
		err = .Io
	}
	if !early {
		if err != .None && conn != nil {
			h3.close(conn)
			conn = nil
		}
		quic_job_result(r, conn, err == .None)
	}
	if err == .None {
		mark_working(r.cache, r.host)
	} else {
		// Broken only if TCP works (else the network/origin is just down).
		locks.lock(&r.mu)
		for !r.tcp_done do locks.cond_wait(&r.cond, &r.mu)
		tcp_ok := r.tcp_ok
		locks.unlock(&r.mu)
		if tcp_ok do mark_broken(r.cache, r.host)
		// A failed early session stays in the cache with an error; the next
		// connect sees !can_open and closes it.
	}
	race_release(r)
}

@(private)
quic_job_result :: proc(r: ^Race, conn: ^h3.Conn, ok: bool) {
	locks.lock(&r.mu)
	r.quic_done = true
	r.quic_ok = ok
	if ok {
		r.quic_conn = conn
		if r.winner == 0 do r.winner = 1
	}
	tcp_won := r.winner == 2
	locks.cond_broadcast(&r.cond)
	locks.unlock(&r.mu)
	if !ok do return
	// Keep the session for reuse whether or not it won this race.
	locks.lock(&r.cache.mu)
	if _, found := r.cache.conns[r.host]; !found {
		r.cache.conns[strings.clone(r.host)] = conn
	} else if tcp_won {
		h3.close(conn)
	}
	locks.unlock(&r.cache.mu)
}

@(private)
tcp_job :: proc(r: ^Race) {
	if r.delay > 0 {
		deadline := time.tick_add(time.tick_now(), r.delay)
		locks.lock(&r.mu)
		for !r.quic_done && time.tick_diff(time.tick_now(), deadline) > 0 {
			locks.cond_wait_with_timeout(&r.cond, &r.mu, time.tick_diff(time.tick_now(), deadline))
		}
		skip := r.quic_ok
		locks.unlock(&r.mu)
		if skip {
			// QUIC won before TCP was needed (Chrome cancels the main job).
			locks.lock(&r.mu)
			r.tcp_done = true
			locks.cond_broadcast(&r.cond)
			locks.unlock(&r.mu)
			race_release(r)
			return
		}
	}
	conn, ok := r.dial(r.host, r.user)
	locks.lock(&r.mu)
	r.tcp_done = true
	r.tcp_ok = ok
	lost := false
	if ok {
		r.tcp_conn = conn
		if r.winner == 0 {
			r.winner = 2
		} else {
			lost = true
		}
	}
	locks.cond_broadcast(&r.cond)
	locks.unlock(&r.mu)
	if lost && r.closer != nil do r.closer(conn, r.user)
	race_release(r)
}
