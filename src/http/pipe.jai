// pipe_make returns an in-memory duplex netio.Stream pair for tests: bytes written to one end are read from
// the other. Thread-safe. Closing either end makes the peer see .Closed after it drains buffered data; the
// shared state is freed when both ends are closed. read_timeout_ms (0 = none) guards tests against hangs;
// max_chunk > 0 limits the bytes returned per read (exercises partial reads).
pipe_make :: (read_timeout_ms := 10_000, max_chunk := 0) -> netio.Stream, netio.Stream {
	sh := New(Pipe_Shared);
	sh.read_timeout_ms, sh.max_chunk = read_timeout_ms, max_chunk;
	sh.ends_open = 2;
	for * sh.ends it.* = .{shared = sh, side = it_index};
	end :: (e: *Pipe_End) -> netio.Stream { return .{data = e, read = pipe_read, write = pipe_write, close = pipe_close, shutdown = pipe_shutdown}; }
	return end(*sh.ends[0]), end(*sh.ends[1]);
}

#scope_file

Pipe_End :: struct {
	shared: *Pipe_Shared;
	side: int;
	closed: bool;
}

Pipe_Shared :: struct {
	mu: locks.Mutex;
	cond: locks.Cond;
	data: [2][..]u8;    // data[i]: bytes flowing towards end i
	writer_closed: [2]bool;
	ends_open: int;
	read_timeout_ms: s64;
	max_chunk: int;
	ends: [2]Pipe_End;
}

pipe_read :: (data: *void, dst: []u8) -> int, netio.Error {
	e := cast(*Pipe_End) data;
	sh := e.shared;
	locks.guard(*sh.mu);
	if e.closed return 0, .Closed;
	q := *sh.data[e.side];
	start := current_time_monotonic();
	while !q.count {
		if sh.writer_closed[e.side] || e.closed return 0, .Closed;
		if sh.read_timeout_ms > 0 {
			left := sh.read_timeout_ms - to_milliseconds(current_time_monotonic() - start);
			if left <= 0 return 0, .Timeout;
			locks.cond_wait_with_timeout(*sh.cond, *sh.mu, left);
		} else {
			locks.cond_wait(*sh.cond, *sh.mu);
		}
	}
	n := min(dst.count, q.count);
	if sh.max_chunk > 0 n = min(n, sh.max_chunk);
	memcpy(dst.data, q.data, n);
	for i: n..q.count-1 q.*[i - n] = q.*[i];
	q.count -= n;
	return n, .None;
}

pipe_write :: (data: *void, src: []u8) -> netio.Error {
	e := cast(*Pipe_End) data;
	sh := e.shared;
	locks.guard(*sh.mu);
	if e.closed || sh.writer_closed[1 - e.side] return .Closed; // peer end closed: nobody will read
	array_add(*sh.data[1 - e.side], ..src);
	locks.cond_broadcast(*sh.cond);
	return .None;
}

// pipe_shutdown ends both directions (blocked readers on both ends see .Closed).
pipe_shutdown :: (data: *void) {
	sh := (cast(*Pipe_End) data).shared;
	locks.guard(*sh.mu);
	sh.writer_closed[0], sh.writer_closed[1] = true, true;
	locks.cond_broadcast(*sh.cond);
}

pipe_close :: (data: *void) {
	e := cast(*Pipe_End) data;
	sh := e.shared;
	locks.lock(*sh.mu);
	if e.closed { locks.unlock(*sh.mu); return; }
	// Our outgoing direction ends, and nothing more will be read on our side.
	e.closed = true;
	sh.writer_closed[0], sh.writer_closed[1] = true, true;
	sh.ends_open -= 1;
	last := sh.ends_open == 0;
	locks.cond_broadcast(*sh.cond);
	locks.unlock(*sh.mu);
	if last {
		array_free(sh.data[0]);
		array_free(sh.data[1]);
		free(sh);
	}
}
