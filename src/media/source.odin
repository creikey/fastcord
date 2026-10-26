package media

// Byte sources: random-access, possibly still growing (HTTP download in
// progress). Demuxers never assume data is present: a read past what's
// available returns .Pending and the caller retries later. Blocking is opt-in
// (read_wait) and only done on the player's worker thread.

import "fc:locks"
import "core:os"
import "core:time"

Read_Status :: enum u8 {
	Ok,
	Pending, // not downloaded yet; retry later
	Eof, // offset is past the end of a complete source
	Error,
}

Byte_Source :: struct {
	// Reads up to len(buf) bytes at offset. Short reads only at EOF/pending edge.
	read_at:  proc(user: rawptr, offset: i64, buf: []u8) -> (int, Read_Status),
	// Bytes available now and whether the source is complete (size final).
	extent:   proc(user: rawptr) -> (available: i64, complete: bool),
	// Optional: block until more than `have` bytes are available, complete, or timeout.
	wait:     proc(user: rawptr, have: i64, timeout: time.Duration),
	destroy:  proc(user: rawptr),
	user:     rawptr,
}

source_extent :: proc(src: ^Byte_Source) -> (i64, bool) {return src.extent(src.user)}

// Read exactly len(buf) bytes or report why not.
read_full :: proc(src: ^Byte_Source, offset: i64, buf: []u8) -> Read_Status {
	got := 0
	for got < len(buf) {
		n, s := src.read_at(src.user, offset + i64(got), buf[got:])
		got += n
		if got == len(buf) do return .Ok
		if s != .Ok do return s
		if n == 0 do return .Pending
	}
	return .Ok
}

source_destroy :: proc(src: ^Byte_Source) {
	if src.destroy != nil do src.destroy(src.user)
	src^ = {}
}

// ---- File

@(private = "file")
File_Src :: struct {
	f:    ^os.File,
	size: i64,
}

source_from_file :: proc(path: string) -> (Byte_Source, bool) {
	f, err := os.open(path)
	if err != nil do return {}, false
	size, serr := os.file_size(f)
	if serr != nil {
		os.close(f)
		return {}, false
	}
	fs := new(File_Src)
	fs^ = {f, size}
	return Byte_Source {
		read_at = proc(user: rawptr, offset: i64, buf: []u8) -> (int, Read_Status) {
			fs := (^File_Src)(user)
			if offset >= fs.size do return 0, .Eof
			want := min(i64(len(buf)), fs.size - offset)
			n, err := os.read_at(fs.f, buf[:want], offset)
			if err != nil && n == 0 do return 0, .Error
			return n, .Ok
		},
		extent = proc(user: rawptr) -> (i64, bool) {return (^File_Src)(user).size, true},
		destroy = proc(user: rawptr) {
			fs := (^File_Src)(user)
			os.close(fs.f)
			free(fs)
		},
		user = fs,
	}, true
}

// ---- Memory (not copied; must outlive the source)

@(private = "file")
Mem_Src :: struct {
	data: []u8,
}

source_from_memory :: proc(data: []u8) -> Byte_Source {
	ms := new(Mem_Src)
	ms.data = data
	return Byte_Source {
		read_at = proc(user: rawptr, offset: i64, buf: []u8) -> (int, Read_Status) {
			d := (^Mem_Src)(user).data
			if offset >= i64(len(d)) do return 0, .Eof
			return copy(buf, d[offset:]), .Ok
		},
		extent = proc(user: rawptr) -> (i64, bool) {return i64(len((^Mem_Src)(user).data)), true},
		destroy = proc(user: rawptr) {free((^Mem_Src)(user))},
		user = ms,
	}
}

// ---- Growing buffer: a downloader appends, the player reads concurrently.

Growing_Buffer :: struct {
	mu:       locks.Mutex,
	cond:     locks.Cond,
	data:     [dynamic]u8,
	complete: bool,
	failed:   bool,
	refs:     int,
}

growing_create :: proc(expected_size: int = 0) -> ^Growing_Buffer {
	g := new(Growing_Buffer)
	g.data = make([dynamic]u8, 0, expected_size)
	g.refs = 1
	return g
}

// Called by the downloader (any thread).
growing_append :: proc(g: ^Growing_Buffer, bytes: []u8) {
	locks.lock(&g.mu)
	append(&g.data, ..bytes)
	locks.unlock(&g.mu)
	locks.cond_broadcast(&g.cond)
}

growing_finish :: proc(g: ^Growing_Buffer, ok := true) {
	locks.lock(&g.mu)
	g.complete = true
	g.failed = !ok
	locks.unlock(&g.mu)
	locks.cond_broadcast(&g.cond)
}

growing_release :: proc(g: ^Growing_Buffer) {
	locks.lock(&g.mu)
	g.refs -= 1
	last := g.refs == 0
	locks.unlock(&g.mu)
	if last {
		delete(g.data)
		free(g)
	}
}

// The source holds a reference; the downloader keeps its own (release both).
source_from_growing :: proc(g: ^Growing_Buffer) -> Byte_Source {
	locks.lock(&g.mu)
	g.refs += 1
	locks.unlock(&g.mu)
	return Byte_Source {
		read_at = proc(user: rawptr, offset: i64, buf: []u8) -> (int, Read_Status) {
			g := (^Growing_Buffer)(user)
			locks.lock(&g.mu)
			defer locks.unlock(&g.mu)
			if offset >= i64(len(g.data)) {
				if g.failed do return 0, .Error
				return 0, g.complete ? .Eof : .Pending
			}
			n := copy(buf, g.data[offset:])
			return n, .Ok
		},
		extent = proc(user: rawptr) -> (i64, bool) {
			g := (^Growing_Buffer)(user)
			locks.lock(&g.mu)
			defer locks.unlock(&g.mu)
			return i64(len(g.data)), g.complete
		},
		wait = proc(user: rawptr, have: i64, timeout: time.Duration) {
			g := (^Growing_Buffer)(user)
			locks.lock(&g.mu)
			defer locks.unlock(&g.mu)
			if i64(len(g.data)) <= have && !g.complete {
				locks.cond_wait_with_timeout(&g.cond, &g.mu, timeout)
			}
		},
		destroy = proc(user: rawptr) {growing_release((^Growing_Buffer)(user))},
		user = g,
	}
}
