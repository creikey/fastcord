#scope_module

// Pipe is an in-memory duplex netio.Stream pair for tests: bytes written to
// one end are read from the other. Thread-safe (one reader + one writer per
// end at a time is the expected pattern, more is fine). Closing either end
// makes the peer see .Closed after it drains buffered data. The shared state
// is freed when both ends are closed.
Pipe_Half :: struct {
	data: [..]u8;
	closed: bool; // writer side closed
}

Pipe_Shared :: struct {
	mu: locks.Mutex;
	cond: locks.Cond;
	dir: [2]Pipe_Half; // dir[i]: bytes flowing towards end i
	ends_open: int;
	read_timeout: time.Duration;
	// max_chunk > 0 limits bytes returned per read (exercises partial reads).
	max_chunk: int;
	ends: [2]*Pipe_End;
}

Pipe_End :: struct {
	shared: *Pipe_Shared;
	side: int;
	closed: bool;
}
#scope_export

// pipe_make returns two connected streams. read_timeout guards tests against hangs.
pipe_make :: (read_timeout := 10 * time.Second, max_chunk := 0) -> netio.Stream, netio.Stream {
	a: netio.Stream;
	b: netio.Stream;
	sh := new(Pipe_Shared);
	sh.ends_open = 2;
	sh.read_timeout = read_timeout;
	sh.max_chunk = max_chunk;
	ea := new(Pipe_End);
	ea.* = .{shared = sh, side = 0};
	eb := new(Pipe_End);
	eb.* = .{shared = sh, side = 1};
	a = netio.Stream.{data = ea, read = pipe_read, write = pipe_write, close = pipe_close, shutdown = pipe_shutdown};
	sh.ends = .[ea, eb];
	b = netio.Stream.{data = eb, read = pipe_read, write = pipe_write, close = pipe_close, shutdown = pipe_shutdown};
	return a, b;
}
#scope_module

pipe_read :: (data: *void, dst: []u8) -> int, netio.Error {
	e := cast(*Pipe_End)data;
	sh := e.shared;
	locks.lock(*sh.mu);
	defer locks.unlock(*sh.mu);
	if e.closed { return 0, .Closed; }
	h := *sh.dir[e.side];
	deadline := time.tick_now();
	while len(h.data) == 0 {
		if h.closed || e.closed { return 0, .Closed; }
		if sh.read_timeout > 0 {
			left := sh.read_timeout - time.tick_since(deadline);
			if left <= 0 { return 0, .Timeout; }
			locks.cond_wait_with_timeout(*sh.cond, *sh.mu, left);
		} else {
			locks.cond_wait(*sh.cond, *sh.mu);
		}
	}
	want := len(dst);
	if sh.max_chunk > 0 { want = min(want, sh.max_chunk); }
	n := copy(sub(dst, 0, want), view(h.data));
	remove_range(*h.data, 0, n);
	return n, .None;
}

pipe_write :: (data: *void, src: []u8) -> netio.Error {
	e := cast(*Pipe_End)data;
	sh := e.shared;
	locks.lock(*sh.mu);
	defer locks.unlock(*sh.mu);
	if e.closed { return .Closed; }
	peer := *sh.dir[1 - e.side];
	if peer.closed { return .Closed; } // peer end closed: nobody will read
	append(*peer.data, ..src);
	locks.cond_broadcast(*sh.cond);
	return .None;
}

// pipe_shutdown ends both directions (blocked readers on both ends see .Closed).
pipe_shutdown :: (data: *void) {
	e := cast(*Pipe_End)data;
	sh := e.shared;
	locks.lock(*sh.mu);
	sh.dir[0].closed = true;
	sh.dir[1].closed = true;
	locks.cond_broadcast(*sh.cond);
	locks.unlock(*sh.mu);
}

pipe_close :: (data: *void) {
	e := cast(*Pipe_End)data;
	sh := e.shared;
	locks.lock(*sh.mu);
	if e.closed {
		locks.unlock(*sh.mu);
		return;
	}
	e.closed = true;
	// Our outgoing direction ends; and nothing more will be read on our side.
	sh.dir[1 - e.side].closed = true;
	sh.dir[e.side].closed = true;
	sh.ends_open -= 1;
	last := sh.ends_open == 0;
	locks.cond_broadcast(*sh.cond);
	locks.unlock(*sh.mu);
	if last {
		delete(sh.dir[0].data);
		delete(sh.dir[1].data);
		free(sh.ends[0]);
		free(sh.ends[1]);
		free(sh);
	}
}
#scope_export

