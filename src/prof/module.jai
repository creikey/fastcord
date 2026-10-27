// prof measures where time goes: named timing zones (with an optional Chrome trace of them) and a
// sampling profiler that interrupts one thread and records its stacks.
//
// Zones, on the thread that called zones_begin (cheap no-ops everywhere else):
//
//	z: prof.Zones;
//	prof.zones_begin(*z, trace = true);
//	{
//		prof.zone("layout"); // ends at the end of the enclosing scope
//		...
//	}
//	prof.zones_end();
//	print(prof.zones_report(*z));
//	prof.write_chrome_trace(*z, "trace.json"); // open in ui.perfetto.dev or chrome://tracing
//
// Sampling:
//
//	s: prof.Sampler;
//	prof.sampler_start(*s, prof.current_thread()); // called on the thread to be sampled
//	...
//	prof.sampler_stop(*s);
//	prof.write_folded(*s, "out.folded"); // speedscope.app, inferno, flamegraph.pl
//	print(prof.sampler_report(*s, 25));

Zone_Stat :: struct {
	name: string;
	calls: int;
	ns: s64;
	max_ns: s64;
}

Trace_Event :: struct {
	name: string;
	start_ns: s64; // since zones_begin
	dur_ns: s64;
}

Zones :: struct {
	stats: [..]Zone_Stat;
	events: [..]Trace_Event;
	trace: bool;
	origin: Apollo_Time;
}

Zone_Mark :: struct {
	name: string;
	start: Apollo_Time;
}

#add_context zones_on: *Zones;

// Zones opened on the calling thread are recorded into z until zones_end. With trace, every zone
// is also kept as an event for write_chrome_trace.
zones_begin :: (z: *Zones, trace := false) {
	z.trace = trace;
	if z.origin.low == 0 && z.origin.high == 0 z.origin = current_time_monotonic();
	context.zones_on = z;
}

zones_end :: () { context.zones_on = null; }

zones_destroy :: (z: *Zones) {
	if context.zones_on == z context.zones_on = null;
	array_free(z.stats);
	array_free(z.events);
	z.* = .{};
}

// Times the rest of the enclosing scope. name must outlive the Zones (use a literal).
zone :: (name: string) #expand {
	m := zone_begin(name);
	`defer zone_end(m);
}

// Starts a zone that zone_end closes, for spans that are not a scope.
zone_begin :: inline (name: string) -> Zone_Mark {
	if !context.zones_on return .{};
	return .{name, current_time_monotonic()};
}

zone_end :: (m: Zone_Mark) {
	z := context.zones_on;
	if !z || !m.name return;
	ns := to_nanoseconds(current_time_monotonic() - m.start);
	zone_add(z, m.name, ns);
	if z.trace array_add(*z.events, .{m.name, to_nanoseconds(m.start - z.origin), ns});
}

// Adds a measurement taken some other way (e.g. a whole frame) to a zone's totals.
zone_add :: (z: *Zones, name: string, ns: s64) {
	for * z.stats {
		if it.name.data == name.data || it.name == name {
			it.calls += 1;
			it.ns += ns;
			it.max_ns = max(it.max_ns, ns);
			return;
		}
	}
	array_add(*z.stats, .{name, 1, ns, ns});
}

zone_stat :: (z: *Zones, name: string) -> Zone_Stat {
	for z.stats if it.name == name return it;
	return .{name = name};
}

// Totals per zone, largest first: calls, total ms, mean and max per call.
zones_report :: (z: *Zones, allocator := temp) -> string {
	stats := array_copy(z.stats,, temp);
	quick_sort(stats, (a, b) => b.ns - a.ns);
	b: String_Builder;
	b.allocator = temp;
	ZONE_ROW :: "% % % % %\n";
	print_to_builder(*b, ZONE_ROW, rpad("zone", 28), lpad("calls", 8), lpad("total ms", 10), lpad("mean us", 9), lpad("max us", 9));
	for stats {
		print_to_builder(*b, ZONE_ROW, rpad(it.name, 28), lpad(num(xx it.calls, 0), 8), lpad(num(cast(float64) it.ns / 1.0e6, 2), 10), lpad(num(cast(float64) it.ns / 1000.0 / max(it.calls, 1), 1), 9), lpad(num(cast(float64) it.max_ns / 1000.0, 1), 9));
	}
	return builder_to_string(*b,, allocator);
}

// v with the given decimals, for columns.
num :: (v: float64, decimals: int) -> string {
	if decimals == 0 return tprint("%", cast(s64) v);
	return tprint("%", formatFloat(v, trailing_width = ifx decimals == 1 || decimals == 2 then decimals else 3, zero_removal = .NO));
}

// Chrome trace event format (complete events), readable by ui.perfetto.dev and chrome://tracing.
write_chrome_trace :: (z: *Zones, path: string) -> bool {
	b: String_Builder;
	b.allocator = temp;
	append(*b, "{\"traceEvents\":[\n");
	for z.events {
		if it_index > 0 append(*b, ",\n");
		print_to_builder(*b, "{\"name\":\"%\",\"ph\":\"X\",\"pid\":1,\"tid\":1,\"ts\":%,\"dur\":%}", json_escape(it.name), num(cast(float64) it.start_ns / 1000.0, 3), num(cast(float64) it.dur_ns / 1000.0, 3));
	}
	append(*b, "\n]}\n");
	return write_entire_file(path, *b);
}

// Frames kept per sample, innermost first. Deeper stacks lose their outermost frames.
MAX_FRAMES :: 96;

// Interrupts one thread at a fixed rate and records its call stack. While the sampled thread is
// suspended the sampler only reads its registers and stack into a fixed buffer: the suspended
// thread may hold the heap lock, so nothing may allocate until it resumes.
Sampler :: struct {
	target: Thread_Ref;
	interval_ns: s64;
	gate: *s32; // when set, samples are kept only while gate.* != 0 (read while the target is suspended)
	thr: Thread;
	running: bool;
	stop: bool;
	// Samples, back to back: frame count, then that many return addresses, innermost first.
	data: [..]u64;
	samples: int;
	failed: int; // suspend or unwind failed
	skipped: int; // gate was closed
	elapsed_ns: s64;
}

// Starts sampling target (see current_thread) on a new thread, hz times per second. Windows reaches
// about 2 kHz at most, macOS higher; the real rate is samples / elapsed.
sampler_start :: (s: *Sampler, target: Thread_Ref, hz := 1000, gate: *s32 = null) -> bool {
	assert(!s.running, "sampler already running");
	s.target = target;
	s.interval_ns = 1_000_000_000 / max(hz, 1);
	s.gate = gate;
	s.stop = false;
	if !thread_init(*s.thr, (t: *Thread) -> s64 { sampler_loop(t.data); return 0; }) return false;
	s.thr.data = s;
	thread_start(*s.thr);
	s.running = true;
	return true;
}

sampler_stop :: (s: *Sampler) {
	if !s.running return;
	atomic_store(*s.stop, true);
	thread_is_done(*s.thr, -1);
	thread_deinit(*s.thr);
	s.running = false;
}

sampler_destroy :: (s: *Sampler) {
	sampler_stop(s);
	array_free(s.data);
	s.* = .{};
}

// Folded stacks ("outer;...;inner count" per line) for speedscope.app, inferno or flamegraph.pl.
write_folded :: (s: *Sampler, path: string) -> bool {
	push_allocator(temp);
	syms := resolve_symbols(s);
	counts: Table(string, int);
	for frames: s {
		b: String_Builder;
		for < frames {
			append(*b, table_find_pointer(*syms, it).procedure);
			if it_index > 0 append(*b, ";");
		}
		find_or_add(*counts, builder_to_string(*b)).* += 1;
	}
	out: String_Builder;
	for v, k: counts print_to_builder(*out, "% %\n", k, v);
	return write_entire_file(path, *out);
}

// The top procedures by self time (samples where it was the innermost frame) and by inclusive time
// (samples where it was anywhere on the stack), and the hottest source lines.
sampler_report :: (s: *Sampler, top := 25, allocator := temp) -> string {
	push_allocator(temp);
	Row :: struct { name: string; self, incl: int; }
	syms := resolve_symbols(s);
	rows: Table(string, Row);
	lines: Table(string, int);
	seen: Table(string, bool);
	for frames: s {
		table_reset(*seen);
		for frames {
			sym := table_find_pointer(*syms, it);
			r := find_or_add(*rows, sym.procedure);
			r.name = sym.procedure;
			if it_index == 0 {
				r.self += 1;
				find_or_add(*lines, tprint("%:% (%)", sym.file, sym.line, sym.procedure)).* += 1;
			}
			if !table_find_pointer(*seen, sym.procedure) {
				r.incl += 1;
				table_set(*seen, sym.procedure, true);
			}
		}
	}
	list: [..]Row;
	for rows array_add(*list, it);
	Line :: struct { at: string; n: int; }
	hot: [..]Line;
	for v, k: lines array_add(*hot, .{k, v});
	total := cast(float64) max(s.samples, 1);

	b: String_Builder;
	elapsed_s := cast(float64) s.elapsed_ns / 1.0e9;
	rate := ifx s.elapsed_ns > 0 then (s.samples + s.skipped + s.failed) / elapsed_s else 0;
	print_to_builder(*b, "% samples over % s (% Hz; % gated out, % failed)\n", s.samples, num(elapsed_s, 1), cast(s64) (rate + 0.5), s.skipped, s.failed);
	quick_sort(list, (a, b) => b.self - a.self);
	append(*b, "\n  self%   incl%  procedure (by self)\n");
	for array_view(list, 0, min(top, list.count)) print_to_builder(*b, "  %   %  %\n", lpad(num(100 * it.self / total, 1), 5), lpad(num(100 * it.incl / total, 1), 5), it.name);
	quick_sort(list, (a, b) => b.incl - a.incl);
	append(*b, "\n  incl%   self%  procedure (by inclusive)\n");
	for array_view(list, 0, min(top, list.count)) print_to_builder(*b, "  %   %  %\n", lpad(num(100 * it.incl / total, 1), 5), lpad(num(100 * it.self / total, 1), 5), it.name);
	quick_sort(hot, (a, b) => b.n - a.n);
	append(*b, "\n  self%  line\n");
	for array_view(hot, 0, min(top, hot.count)) print_to_builder(*b, "  %  %\n", lpad(num(100 * it.n / total, 1), 5), it.at);
	return builder_to_string(*b,, allocator);
}

#scope_module

#import "Basic";
#import "String";
#import "Hash_Table";
#import "Atomics";
#import "Sort";
#import "File";
#import "Thread";
#if OS != .WINDOWS #import "POSIX";
#if OS == .WINDOWS #import "Windows";

#if OS == .MACOS #load "sampler_darwin.jai";
#if OS == .WINDOWS #load "sampler_windows.jai";
#if OS == .LINUX #load "sampler_linux.jai";

Symbol :: struct {
	procedure: string;
	file: string;
	line: int;
}

// `for frames: sampler` visits each sample's frames (innermost first).
for_expansion :: (s: *Sampler, body: Code, flags: For_Flags) #expand {
	i := 0;
	while i < s.data.count {
		n := cast(int) s.data[i];
		`it := array_view(s.data, i + 1, n);
		`it_index := i;
		i += 1 + n;
		#insert body;
	}
}

sampler_loop :: (s: *Sampler) {
	start := current_time_monotonic();
	timer := timer_make();
	defer timer_destroy(timer);
	buf: [MAX_FRAMES]u64;
	while !atomic_load(*s.stop) {
		timer_wait(timer, s.interval_ns);
		n, open := capture_thread_gated(s.target, buf, s.gate);
		if !open {
			s.skipped += 1;
		} else if n == 0 {
			s.failed += 1;
		} else {
			array_add(*s.data, cast(u64) n);
			array_add(*s.data, ..array_view(buf, 0, n));
			s.samples += 1;
		}
	}
	s.elapsed_ns = to_nanoseconds(current_time_monotonic() - start);
}

// Symbols for every distinct address in the samples, resolved in one batch (resolving is slow).
// Unresolved addresses are named by their hex value.
resolve_symbols :: (s: *Sampler) -> Table(u64, Symbol) {
	syms: Table(u64, Symbol);
	addrs: [..]u64;
	for frames: s {
		for frames {
			if table_find_pointer(*syms, it) continue;
			table_add(*syms, it, .{});
			array_add(*addrs, it);
		}
	}
	for addrs {
		sym := table_find_pointer(*syms, it);
		sym.* = symbolize(it);
		if sym.procedure == "" || sym.procedure == "??" sym.* = .{procedure = tprint("0x%", formatInt(it, base = 16))};
	}
	return syms;
}

// s padded to width w with spaces on the left (lpad) or right (rpad).
lpad :: (s: string, w: int) -> string { return ifx s.count >= w then s else tprint("%1%2", spaces(w - s.count), s); }
rpad :: (s: string, w: int) -> string { return ifx s.count >= w then s else tprint("%1%2", s, spaces(w - s.count)); }
spaces :: (n: int) -> string { return slice("                                                                ", 0, n); }

json_escape :: (s: string) -> string {
	b: String_Builder;
	for 0..s.count-1 {
		c := s[it];
		if c == #char "\"" || c == #char "\\" append(*b, "\\");
		append(*b, c);
	}
	return builder_to_string(*b);
}
