// Frames kept per sample, innermost first. Deeper stacks lose their outermost frames.
MAX_FRAMES :: 96;

// Interrupts one thread at a fixed rate and records its call stack. While the sampled thread is
// suspended the sampler only reads its registers and stack into a fixed buffer: the suspended
// thread may hold the heap lock, so nothing may allocate until it resumes.
Sampler :: struct {
	target: Thread_Ref;
	interval: time.Duration;
	gate: *s32; // when set, samples are kept only while gate^ != 0 (read while the target is suspended)
	thr: *thread.Thread;
	stop: bool;
	// Samples, back to back: frame count, then that many return addresses, innermost first.
	data: [..]u64;
	samples: int;
	failed: int; // suspend or unwind failed
	skipped: int; // gate was closed
	elapsed: time.Duration;
}

// Starts sampling target (see current_thread) on a new thread, hz times per second. Windows reaches
// about 2 kHz at most, macOS higher; the real rate is samples / elapsed.
sampler_start :: (s: *Sampler, target: Thread_Ref, hz := 1000, gate: *s32 = null) -> bool {
	assert(s.thr == null, "sampler already running");
	s.target = target;
	s.interval = time.Second / time.Duration(max(hz, 1));
	s.gate = gate;
	s.stop = false;
	s.thr = thread.create_and_start_with_poly_data(s, sampler_loop, context);
	return s.thr != null;
}

sampler_stop :: (s: *Sampler) {
	if s.thr == null { return; }
	sync.atomic_store(*s.stop, true);
	thread.join(s.thr);
	thread.destroy(s.thr);
	s.thr = null;
}

sampler_destroy :: (s: *Sampler) {
	sampler_stop(s);
	delete(s.data);
	s.* = .{};
}
#scope_module

sampler_loop :: (s: *Sampler) {
	start := time.tick_now();
	timer := timer_make();
	defer timer_destroy(timer);
	buf: [MAX_FRAMES]u64;
	while !sync.atomic_load(*s.stop) {
		timer_wait(timer, s.interval);
		n, open := capture_thread_gated(s.target, view(buf), s.gate);
		if !open {
			s.skipped += 1;
		} else if n == 0 {
			s.failed += 1;
		} else {
			append(*s.data, cast(u64)(n));
			append(*s.data, ..sub(buf, 0, n));
			s.samples += 1;
		}
	}
	s.elapsed = time.tick_since(start);
}
#scope_export

// Calls fn with each sample's frames (innermost first) until it returns false.
each_sample :: (s: *Sampler, fn: (frames: []u64, user: *void) -> bool, user: *void) {
	{ i := 0;
	while i < len(s.data) {
		n := cast(int)(s.data[i]);
		if !fn(sub(s.data, i + 1, i + 1 + n), user) { return; }
		i += 1 + n;
	} }
}

Symbol :: struct {
	procedure: string;
	file: string;
	line: int;
}

// Symbols for every distinct address in the samples, resolved in one batch (resolving is slow).
resolve_symbols :: (s: *Sampler, allocator := context.allocator) -> Map(u64, Symbol) {
	syms := Map(u64, Symbol).{};
	addrs := make_dynamic(trace.Capture_Entry, 0, 1024, temp);
	{ i := 0;
	while i < len(s.data) {
		n := cast(int)(s.data[i]);
		for a: sub(s.data, i + 1, i + 1 + n) {
			if has(syms, a) { continue; }
			at(*syms, a).* = .{};
			append(*addrs, trace.Capture_Entry(cast(u64)(a)));
		}
		i += 1 + n;
	} }
	locs, err := trace.resolve(view(addrs), allocator);
	for e, k: addrs {
		a := cast(u64)(cast(u64)(e));
		if err != null || k >= len(locs) || locs[k].procedure == "" || locs[k].procedure == "??" {
			at(*syms, a).* = .{procedure = fmt.aprintf("0x%x", a, allocator = allocator)};
			continue;
		}
		l := locs[k];
		at(*syms, a).* = .{procedure = l.procedure, file = l.file_path, line = cast(int)(l.line)};
	}
	return syms;
}

// Folded stacks ("outer;...;inner count" per line) for speedscope.app, inferno or flamegraph.pl.
write_folded :: (s: *Sampler, path: string) -> bool {
	syms := resolve_symbols(s, temp);
	counts := Map(string, int).{};
	{ i := 0;
	while i < len(s.data) {
		n := cast(int)(s.data[i]);
		frames := sub(s.data, i + 1, i + 1 + n);
		b := strings.builder_make(temp);
		for < a, k: frames {
			strings.write_string(*b, get(syms, a).procedure);
			if k > 0 { strings.write_byte(*b, #char ";"); }
		}
		at(*counts, strings.to_string(b)).* += 1;
		i += 1 + n;
	} }
	out := strings.builder_make(temp);
	for k, v: counts { fmt.sbprintfln(*out, "%s %d", k, v); }
	return os.write_entire_file(path, transmute([]u8, strings.to_string(out))) == null;
}

Report_Row :: struct {
	name: string;
	self, incl: int;
}

// The top procedures by self time (samples where it was the innermost frame) and by inclusive time
// (samples where it was anywhere on the stack), and the hottest source lines.
sampler_report :: (s: *Sampler, top := 25, allocator := temp) -> string {
	syms := resolve_symbols(s, temp);
	rows := Map(string, Report_Row).{};
	lines := Map(string, int).{};
	seen := Map(string, bool).{};
	{ i := 0;
	while i < len(s.data) {
		n := cast(int)(s.data[i]);
		frames := sub(s.data, i + 1, i + 1 + n);
		clear(*seen);
		for a, k: frames {
			sym := get(syms, a);
			r := get(rows, sym.procedure);
			r.name = sym.procedure;
			if k == 0 {
				r.self += 1;
				__MAPIDX__(lines|fmt.tprintf("%s:%d (%s)", sym.file, sym.line, sym.procedure)) += 1;
			}
			if !__MAPIDX__(seen|sym.procedure) {
				r.incl += 1;
				at(*seen, sym.procedure).* = true;
			}
			at(*rows, sym.procedure).* = r;
		}
		i += 1 + n;
	} }
	list := make_dynamic(Report_Row, 0, len(rows), temp);
	for _, r: rows { append(*list, r); }
	total := cast(float64)(max(s.samples, 1));
	b := strings.builder_make(allocator);
	rate := ifx s.elapsed > 0 then cast(float64)(s.samples + s.skipped + s.failed) / time.duration_seconds(s.elapsed) else 0;
	fmt.sbprintfln(*b, "%d samples over %.1f s (%.0f Hz; %d gated out, %d failed)", s.samples, time.duration_seconds(s.elapsed), rate, s.skipped, s.failed);
	slice.sort_by(view(list), (a: Report_Row, b: Report_Row) -> bool {return a.self > b.self;});
	fmt.sbprintln(*b, "\n  self%   incl%  procedure (by self)");
	for r: sub(list, 0, min(top, len(list))) { fmt.sbprintfln(*b, "  %5s   %5s  %s", num(100 * cast(float64)(r.self) / total, 1), num(100 * cast(float64)(r.incl) / total, 1), r.name); }
	slice.sort_by(view(list), (a: Report_Row, b: Report_Row) -> bool {return a.incl > b.incl;});
	fmt.sbprintln(*b, "\n  incl%   self%  procedure (by inclusive)");
	for r: sub(list, 0, min(top, len(list))) { fmt.sbprintfln(*b, "  %5s   %5s  %s", num(100 * cast(float64)(r.incl) / total, 1), num(100 * cast(float64)(r.self) / total, 1), r.name); }
	Line :: struct {
		at: string;
		n: int;
	}
	hot := make_dynamic(Line, 0, len(lines), temp);
	for k, v: lines { append(*hot, Line.{k, v}); }
	slice.sort_by(view(hot), (a: Line, b: Line) -> bool {return a.n > b.n;});
	fmt.sbprintln(*b, "\n  self%  line");
	for l: sub(hot, 0, min(top, len(hot))) { fmt.sbprintfln(*b, "  %5s  %s", num(100 * cast(float64)(l.n) / total, 1), l.at); }
	return strings.to_string(b);
}

