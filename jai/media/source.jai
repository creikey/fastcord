// Byte sources: random-access, possibly still growing (HTTP download in
// progress). Demuxers never assume data is present: a read past what's
// available returns .Pending and the caller retries later. Blocking is opt-in
// (read_wait) and only done on the player's worker thread.





Read_Status :: enum u8 {
	Ok;
	Pending; // not downloaded yet; retry later
	Eof; // offset is past the end of a complete source
	Error;
}

Byte_Source :: struct {
	// Reads up to len(buf) bytes at offset. Short reads only at EOF/pending edge.
	read_at: (user: *void, offset: s64, buf: []u8) -> int, Read_Status;
	// Bytes available now and whether the source is complete (size final).
	extent: (user: *void) -> s64, bool;
	// Optional: block until more than `have` bytes are available, complete, or timeout.
	wait: (user: *void, have: s64, timeout: time.Duration);
	destroy: (user: *void);
	user: *void;
}

source_extent :: (src: *Byte_Source) -> s64, bool {{ __r1, __r2 := src.extent(src.user); return __r1, __r2; }}

// Read exactly len(buf) bytes or report why not.
read_full :: (src: *Byte_Source, offset: s64, buf: []u8) -> Read_Status {
	got := 0;
	while got < len(buf) {
		n, s := src.read_at(src.user, offset + cast(s64)(got), sub_from(buf, got));
		got += n;
		if got == len(buf) { return .Ok; }
		if s != .Ok { return s; }
		if n == 0 { return .Pending; }
	}
	return .Ok;
}

source_destroy :: (src: *Byte_Source) {
	if src.destroy != null { src.destroy(src.user); }
	src.* = .{};
}
#scope_file

// ---- File

File_Src :: struct {
	f: *os.File;
	size: s64;
}
#scope_export

source_from_file :: (path: string) -> Byte_Source, bool {
	f, err := os.open(path);
	if err != null { return .{}, false; }
	size, serr := os.file_size(f);
	if serr != null {
		os.close(f);
		return .{}, false;
	}
	fs := new(File_Src);
	fs.* = .{f, size};
	return Byte_Source.{
		read_at = (user: *void, offset: s64, buf: []u8) -> int, Read_Status {
			fs := cast(*File_Src)(user);
			if offset >= fs.size { return 0, .Eof; }
			want := min(cast(s64)(len(buf)), fs.size - offset);
			n, err := os.read_at(fs.f, sub(buf, 0, want), offset);
			if err != null && n == 0 { return 0, .Error; }
			return n, .Ok;
		},
		extent = (user: *void) -> s64, bool {return cast(*File_Src)(user).size, true;},
		destroy = (user: *void) {
			fs := cast(*File_Src)(user);
			os.close(fs.f);
			free(fs);
		},
		user = fs
	}, true;
}
#scope_file

// ---- Memory (not copied; must outlive the source)

Mem_Src :: struct {
	data: []u8;
}
#scope_export

source_from_memory :: (data: []u8) -> Byte_Source {
	ms := new(Mem_Src);
	ms.data = data;
	return Byte_Source.{
		read_at = (user: *void, offset: s64, buf: []u8) -> int, Read_Status {
			d := cast(*Mem_Src)(user).data;
			if offset >= cast(s64)(len(d)) { return 0, .Eof; }
			return copy(buf, sub_from(d, offset)), .Ok;
		},
		extent = (user: *void) -> s64, bool {return cast(s64)(len(cast(*Mem_Src)(user).data)), true;},
		destroy = (user: *void) {free(cast(*Mem_Src)(user));},
		user = ms
	};
}

// ---- Growing buffer: a downloader appends, the player reads concurrently.

Growing_Buffer :: struct {
	mu: locks.Mutex;
	cond: locks.Cond;
	data: [..]u8;
	complete: bool;
	failed: bool;
	refs: int;
}

growing_create :: (expected_size: int = 0) -> *Growing_Buffer {
	g := new(Growing_Buffer);
	g.data = make_dynamic(u8, 0, expected_size);
	g.refs = 1;
	return g;
}

// Called by the downloader (any thread).
growing_append :: (g: *Growing_Buffer, bytes: []u8) {
	locks.lock(*g.mu);
	append(*g.data, ..bytes);
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
		delete(g.data);
		free(g);
	}
}

// The source holds a reference; the downloader keeps its own (release both).
source_from_growing :: (g: *Growing_Buffer) -> Byte_Source {
	locks.lock(*g.mu);
	g.refs += 1;
	locks.unlock(*g.mu);
	return Byte_Source.{
		read_at = (user: *void, offset: s64, buf: []u8) -> int, Read_Status {
			g := cast(*Growing_Buffer)(user);
			locks.lock(*g.mu);
			defer locks.unlock(*g.mu);
			if offset >= cast(s64)(len(g.data)) {
				if g.failed { return 0, .Error; }
				return 0, ifx g.complete then .Eof else .Pending;
			}
			n := copy(buf, sub_from(g.data, offset));
			return n, .Ok;
		},
		extent = (user: *void) -> s64, bool {
			g := cast(*Growing_Buffer)(user);
			locks.lock(*g.mu);
			defer locks.unlock(*g.mu);
			return cast(s64)(len(g.data)), g.complete;
		},
		wait = (user: *void, have: s64, timeout: time.Duration) {
			g := cast(*Growing_Buffer)(user);
			locks.lock(*g.mu);
			defer locks.unlock(*g.mu);
			if cast(s64)(len(g.data)) <= have && !g.complete {
				locks.cond_wait_with_timeout(*g.cond, *g.mu, timeout);
			}
		},
		destroy = (user: *void) {growing_release(cast(*Growing_Buffer)(user));},
		user = g
	};
}

