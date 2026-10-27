// Byte sources: random-access, possibly still growing (HTTP download in
// progress). Demuxers never assume data is present: a read past what's
// available returns .Pending and the caller retries later. Blocking is opt-in
// (wait) and only done on the player's worker thread.

Read_Status :: enum u8 {
	Ok;
	Pending; // not downloaded yet; retry later
	Eof; // offset is past the end of a complete source
	Error;
}

Byte_Source :: struct {
	// Reads up to buf.count bytes at offset. Short reads only at EOF/pending edge.
	read_at: (user: *void, offset: s64, buf: []u8) -> int, Read_Status;
	// Bytes available now and whether the source is complete (size final).
	extent: (user: *void) -> s64, bool;
	// Optional: block until more than `have` bytes are available, complete, or timeout.
	wait: (user: *void, have: s64, timeout_ms: s64);
	destroy: (user: *void);
	user: *void;
}

source_extent :: (src: *Byte_Source) -> s64, bool { a, c := src.extent(src.user); return a, c; }

// Read exactly buf.count bytes or report why not.
read_full :: (src: *Byte_Source, offset: s64, buf: []u8) -> Read_Status {
	got := 0;
	while got < buf.count {
		n, s := src.read_at(src.user, offset + got, array_view(buf, got));
		got += n;
		if got == buf.count return .Ok;
		if s != .Ok return s;
		if n == 0 return .Pending;
	}
	return .Ok;
}

source_destroy :: (src: *Byte_Source) {
	if src.destroy src.destroy(src.user);
	src.* = .{};
}

source_from_file :: (path: string) -> Byte_Source, bool {
	f, ok := file_open(path, log_errors = false);
	if !ok return .{}, false;
	size, sok := file_length(f);
	if !sok {
		file_close(*f);
		return .{}, false;
	}
	fs := New(File_Src);
	fs.* = .{f, size};
	return .{
		read_at = (user: *void, offset: s64, buf: []u8) -> int, Read_Status {
			fs := cast(*File_Src) user;
			if offset >= fs.size return 0, .Eof;
			want := min(buf.count, fs.size - offset);
			if want <= 0 return 0, .Ok;
			n := 0;
			ok := file_set_position(fs.f, offset);
			if ok  ok, n = file_read(fs.f, buf.data, want);
			if !ok && n == 0 return 0, .Error;
			return n, .Ok;
		},
		extent = (user: *void) -> s64, bool { return (cast(*File_Src) user).size, true; },
		destroy = (user: *void) {
			fs := cast(*File_Src) user;
			file_close(*fs.f);
			free(fs);
		},
		user = fs
	}, true;
}

// Memory (not copied; must outlive the source).
source_from_memory :: (data: []u8) -> Byte_Source {
	ms := New([]u8);
	ms.* = data;
	return .{
		read_at = (user: *void, offset: s64, buf: []u8) -> int, Read_Status {
			d := (cast(*[]u8) user).*;
			if offset >= d.count return 0, .Eof;
			n := min(buf.count, d.count - offset);
			memcpy(buf.data, d.data + offset, n);
			return n, .Ok;
		},
		extent = (user: *void) -> s64, bool { return (cast(*[]u8) user).count, true; },
		destroy = (user: *void) { free(user); },
		user = ms
	};
}

// Growing buffer: a downloader appends, the player reads concurrently.
Growing_Buffer :: struct {
	mu: locks.Mutex;
	cond: locks.Cond;
	data: [..]u8;
	complete: bool;
	failed: bool;
	refs: int;
}

growing_create :: (expected_size := 0) -> *Growing_Buffer {
	g := New(Growing_Buffer);
	array_reserve(*g.data, expected_size);
	g.refs = 1;
	return g;
}

// Called by the downloader (any thread).
growing_append :: (g: *Growing_Buffer, bytes: []u8) {
	locks.lock(*g.mu);
	array_add(*g.data, ..bytes);
	locks.unlock(*g.mu);
	locks.cond_broadcast(*g.cond);
}

growing_finish :: (g: *Growing_Buffer, ok := true) {
	locks.lock(*g.mu);
	g.complete = true;
	g.failed = !ok;
	locks.unlock(*g.mu);
	locks.cond_broadcast(*g.cond);
}

growing_release :: (g: *Growing_Buffer) {
	locks.lock(*g.mu);
	g.refs -= 1;
	last := g.refs == 0;
	locks.unlock(*g.mu);
	if last {
		array_free(g.data);
		free(g);
	}
}

// The source holds a reference; the downloader keeps its own (release both).
source_from_growing :: (g: *Growing_Buffer) -> Byte_Source {
	locks.lock(*g.mu);
	g.refs += 1;
	locks.unlock(*g.mu);
	return .{
		read_at = (user: *void, offset: s64, buf: []u8) -> int, Read_Status {
			g := cast(*Growing_Buffer) user;
			locks.lock(*g.mu);
			defer locks.unlock(*g.mu);
			if offset >= g.data.count {
				if g.failed return 0, .Error;
				return 0, ifx g.complete then .Eof else .Pending;
			}
			n := min(buf.count, g.data.count - offset);
			memcpy(buf.data, g.data.data + offset, n);
			return n, .Ok;
		},
		extent = (user: *void) -> s64, bool {
			g := cast(*Growing_Buffer) user;
			locks.lock(*g.mu);
			defer locks.unlock(*g.mu);
			return g.data.count, g.complete;
		},
		wait = (user: *void, have: s64, timeout_ms: s64) {
			g := cast(*Growing_Buffer) user;
			locks.lock(*g.mu);
			defer locks.unlock(*g.mu);
			if g.data.count <= have && !g.complete locks.cond_wait_with_timeout(*g.cond, *g.mu, timeout_ms);
		},
		destroy = (user: *void) { growing_release(cast(*Growing_Buffer) user); },
		user = g
	};
}

#scope_file

File_Src :: struct {
	f: File;
	size: s64;
}
