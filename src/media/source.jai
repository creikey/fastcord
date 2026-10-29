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

// Growing buffer: a downloader appends, the player reads concurrently. An MP4 whose index (moov) comes after
// its media also gets a tail from a second download (from tail_off, as a browser's range request), so the
// player can start before the media in between is in.
Growing_Buffer :: struct {
	mu: locks.Mutex;
	cond: locks.Cond;
	data: [..]u8;
	complete: bool;
	failed: bool;
	refs: int;
	tail: [..]u8;
	tail_off: s64 = -1;
	tail_complete: bool;
	probe_pos: s64; // growing_tail_wanted's next top-level box (the head's writer only)
	probe_done: bool;
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

// growing_tail_wanted: called by the head's writer after each append. The offset to fetch the rest from,
// once (an MP4's mdat came first and the moov follows it at that offset), else -1.
growing_tail_wanted :: (g: *Growing_Buffer) -> s64 {
	if g.probe_done return -1;
	d := g.data; // only this writer grows it
	for 1..64 {
		p := g.probe_pos;
		if p + 8 > d.count return -1;
		size := ((cast(s64) d[p]) << 24) | ((cast(s64) d[p + 1]) << 16) | ((cast(s64) d[p + 2]) << 8) | cast(s64) d[p + 3];
		type := string.{4, d.data + p + 4};
		if size == 1 {
			if p + 16 > d.count return -1;
			size = 0;
			for i: 0..7 size = (size << 8) | d[p + 8 + i];
		}
		if (p == 0 && type != "ftyp") || type == "moov" || size < 8 || size > (1 << 40) { g.probe_done = true; return -1; }
		if type == "mdat" {
			g.probe_done = true;
			locks.lock(*g.mu);
			g.tail_off = p + size;
			locks.unlock(*g.mu);
			return p + size;
		}
		g.probe_pos = p + size;
	}
	g.probe_done = true;
	return -1;
}

growing_append_tail :: (g: *Growing_Buffer, bytes: []u8) {
	locks.lock(*g.mu);
	array_add(*g.tail, ..bytes);
	locks.unlock(*g.mu);
	locks.cond_broadcast(*g.cond);
}

growing_finish_tail :: (g: *Growing_Buffer, ok: bool) {
	locks.lock(*g.mu);
	g.tail_complete = ok;
	if !ok { g.tail_off = -1; array_reset(*g.tail); } // the head alone, as before
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
		array_free(g.tail);
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
				if g.tail_off >= 0 && offset >= g.tail_off && offset < g.tail_off + g.tail.count && !g.complete {
					n := min(buf.count, g.tail_off + g.tail.count - offset);
					memcpy(buf.data, g.tail.data + (offset - g.tail_off), n);
					return n, .Ok;
				}
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
			// with a tail, as far as it reaches: the head's gap reads as pending until it's in
			if !g.complete && g.tail_off >= 0 && g.tail.count return g.tail_off + g.tail.count, g.tail_complete;
			return g.data.count, g.complete;
		},
		wait = (user: *void, have: s64, timeout_ms: s64) {
			g := cast(*Growing_Buffer) user;
			locks.lock(*g.mu);
			defer locks.unlock(*g.mu);
			if !g.complete locks.cond_wait_with_timeout(*g.cond, *g.mu, timeout_ms); // the head or the tail grows
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
