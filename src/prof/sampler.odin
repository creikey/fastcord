package prof

import "core:debug/trace"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

// Frames kept per sample, innermost first. Deeper stacks lose their outermost frames.
MAX_FRAMES :: 96

// Interrupts one thread at a fixed rate and records its call stack. While the sampled thread is
// suspended the sampler only reads its registers and stack into a fixed buffer: the suspended
// thread may hold the heap lock, so nothing may allocate until it resumes.
Sampler :: struct {
	target:   Thread_Ref,
	interval: time.Duration,
	gate:     ^i32, // when set, samples are kept only while gate^ != 0 (read while the target is suspended)
	thr:      ^thread.Thread,
	stop:     bool,
	// Samples, back to back: frame count, then that many return addresses, innermost first.
	data:     [dynamic]u64,
	samples:  int,
	failed:   int, // suspend or unwind failed
	skipped:  int, // gate was closed
	elapsed:  time.Duration,
}

// Starts sampling target (see current_thread) on a new thread, hz times per second. Windows reaches
// about 2 kHz at most, macOS higher; the real rate is samples / elapsed.
sampler_start :: proc(s: ^Sampler, target: Thread_Ref, hz := 1000, gate: ^i32 = nil) -> bool {
	assert(s.thr == nil, "sampler already running")
	s.target = target
	s.interval = time.Second / time.Duration(max(hz, 1))
	s.gate = gate
	s.stop = false
	s.thr = thread.create_and_start_with_poly_data(s, sampler_loop, context)
	return s.thr != nil
}

sampler_stop :: proc(s: ^Sampler) {
	if s.thr == nil do return
	sync.atomic_store(&s.stop, true)
	thread.join(s.thr)
	thread.destroy(s.thr)
	s.thr = nil
}

sampler_destroy :: proc(s: ^Sampler) {
	sampler_stop(s)
	delete(s.data)
	s^ = {}
}

@(private)
sampler_loop :: proc(s: ^Sampler) {
	start := time.tick_now()
	timer := timer_make()
	defer timer_destroy(timer)
	buf: [MAX_FRAMES]u64
	for !sync.atomic_load(&s.stop) {
		timer_wait(timer, s.interval)
		n, open := capture_thread_gated(s.target, buf[:], s.gate)
		switch {
		case !open:
			s.skipped += 1
		case n == 0:
			s.failed += 1
		case:
			append(&s.data, u64(n))
			append(&s.data, ..buf[:n])
			s.samples += 1
		}
	}
	s.elapsed = time.tick_since(start)
}

// Calls fn with each sample's frames (innermost first) until it returns false.
each_sample :: proc(s: ^Sampler, fn: proc(frames: []u64, user: rawptr) -> bool, user: rawptr) {
	for i := 0; i < len(s.data); {
		n := int(s.data[i])
		if !fn(s.data[i + 1:i + 1 + n], user) do return
		i += 1 + n
	}
}

Symbol :: struct {
	procedure: string,
	file:      string,
	line:      int,
}

// Symbols for every distinct address in the samples, resolved in one batch (resolving is slow).
resolve_symbols :: proc(s: ^Sampler, allocator := context.allocator) -> map[u64]Symbol {
	syms := make(map[u64]Symbol, 1024, allocator)
	addrs := make([dynamic]trace.Capture_Entry, 0, 1024, context.temp_allocator)
	for i := 0; i < len(s.data); {
		n := int(s.data[i])
		for a in s.data[i + 1:i + 1 + n] {
			if a in syms do continue
			syms[a] = {}
			append(&addrs, trace.Capture_Entry(uintptr(a)))
		}
		i += 1 + n
	}
	locs, err := trace.resolve(addrs[:], allocator)
	for e, k in addrs {
		a := u64(uintptr(e))
		if err != nil || k >= len(locs) || locs[k].procedure == "" || locs[k].procedure == "??" {
			syms[a] = {procedure = fmt.aprintf("0x%x", a, allocator = allocator)}
			continue
		}
		l := locs[k]
		syms[a] = {procedure = l.procedure, file = l.file_path, line = int(l.line)}
	}
	return syms
}

// Folded stacks ("outer;...;inner count" per line) for speedscope.app, inferno or flamegraph.pl.
write_folded :: proc(s: ^Sampler, path: string) -> bool {
	syms := resolve_symbols(s, context.temp_allocator)
	counts := make(map[string]int, 1024, context.temp_allocator)
	for i := 0; i < len(s.data); {
		n := int(s.data[i])
		frames := s.data[i + 1:i + 1 + n]
		b := strings.builder_make(context.temp_allocator)
		#reverse for a, k in frames {
			strings.write_string(&b, syms[a].procedure)
			if k > 0 do strings.write_byte(&b, ';')
		}
		counts[strings.to_string(b)] += 1
		i += 1 + n
	}
	out := strings.builder_make(context.temp_allocator)
	for k, v in counts do fmt.sbprintfln(&out, "%s %d", k, v)
	return os.write_entire_file(path, transmute([]byte)strings.to_string(out)) == nil
}

Report_Row :: struct {
	name:      string,
	self, incl: int,
}

// The top procedures by self time (samples where it was the innermost frame) and by inclusive time
// (samples where it was anywhere on the stack), and the hottest source lines.
sampler_report :: proc(s: ^Sampler, top := 25, allocator := context.temp_allocator) -> string {
	syms := resolve_symbols(s, context.temp_allocator)
	rows := make(map[string]Report_Row, 1024, context.temp_allocator)
	lines := make(map[string]int, 1024, context.temp_allocator)
	seen := make(map[string]bool, 64, context.temp_allocator)
	for i := 0; i < len(s.data); {
		n := int(s.data[i])
		frames := s.data[i + 1:i + 1 + n]
		clear(&seen)
		for a, k in frames {
			sym := syms[a]
			r := rows[sym.procedure]
			r.name = sym.procedure
			if k == 0 {
				r.self += 1
				lines[fmt.tprintf("%s:%d (%s)", sym.file, sym.line, sym.procedure)] += 1
			}
			if !seen[sym.procedure] {
				r.incl += 1
				seen[sym.procedure] = true
			}
			rows[sym.procedure] = r
		}
		i += 1 + n
	}
	list := make([dynamic]Report_Row, 0, len(rows), context.temp_allocator)
	for _, r in rows do append(&list, r)
	total := f64(max(s.samples, 1))
	b := strings.builder_make(allocator)
	rate := s.elapsed > 0 ? f64(s.samples + s.skipped + s.failed) / time.duration_seconds(s.elapsed) : 0
	fmt.sbprintfln(&b, "%d samples over %.1f s (%.0f Hz; %d gated out, %d failed)", s.samples, time.duration_seconds(s.elapsed), rate, s.skipped, s.failed)
	slice.sort_by(list[:], proc(a, b: Report_Row) -> bool {return a.self > b.self})
	fmt.sbprintln(&b, "\n  self%   incl%  procedure (by self)")
	for r in list[:min(top, len(list))] do fmt.sbprintfln(&b, "  %5s   %5s  %s", num(100 * f64(r.self) / total, 1), num(100 * f64(r.incl) / total, 1), r.name)
	slice.sort_by(list[:], proc(a, b: Report_Row) -> bool {return a.incl > b.incl})
	fmt.sbprintln(&b, "\n  incl%   self%  procedure (by inclusive)")
	for r in list[:min(top, len(list))] do fmt.sbprintfln(&b, "  %5s   %5s  %s", num(100 * f64(r.incl) / total, 1), num(100 * f64(r.self) / total, 1), r.name)
	Line :: struct {
		at: string,
		n:  int,
	}
	hot := make([dynamic]Line, 0, len(lines), context.temp_allocator)
	for k, v in lines do append(&hot, Line{k, v})
	slice.sort_by(hot[:], proc(a, b: Line) -> bool {return a.n > b.n})
	fmt.sbprintln(&b, "\n  self%  line")
	for l in hot[:min(top, len(hot))] do fmt.sbprintfln(&b, "  %5s  %s", num(100 * f64(l.n) / total, 1), l.at)
	return strings.to_string(b)
}
