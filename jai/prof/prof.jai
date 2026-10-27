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
	origin: time.Tick;
}

Zone_Mark :: struct {
	name: string;
	start: time.Tick;
}

#add_context zones_on: *Zones;

// Zones opened on the calling thread are recorded into z until zones_end. With trace, every zone
// is also kept as an event for write_chrome_trace.
zones_begin :: (z: *Zones, trace := false) {
	z.trace = trace;
	if z.origin._nsec == 0 { z.origin = time.tick_now(); }
	context.zones_on = z;
}

zones_end :: () {
	context.zones_on = null;
}

zones_destroy :: (z: *Zones) {
	if context.zones_on == z { context.zones_on = null; }
	delete(z.stats);
	delete(z.events);
	z.* = .{};
}

// Times the rest of the enclosing scope. name must outlive the Zones (use a literal).
zone :: (name: string) #expand {
	m := zone_begin(name);
	`defer zone_end(m);
}

// Starts a zone that zone_end closes, for spans that are not a scope.
zone_begin :: inline (name: string) -> Zone_Mark {
	if context.zones_on == null { return .{}; }
	return .{name, time.tick_now()};
}

zone_end :: (m: Zone_Mark) {
	z := context.zones_on;
	if z == null || m.name == "" { return; }
	now := time.tick_now();
	ns := time.tick_diff(m.start, now);
	zone_add(z, m.name, cast(s64)(ns));
	if z.trace { append(*z.events, Trace_Event.{m.name, cast(s64)(time.tick_diff(z.origin, m.start)), cast(s64)(ns)}); }
}

// Adds a measurement taken some other way (e.g. a whole frame) to a zone's totals.
zone_add :: (z: *Zones, name: string, ns: s64) {
	for * st: z.stats {
		if raw_data(st.name) == raw_data(name) || st.name == name {
			st.calls += 1;
			st.ns += ns;
			st.max_ns = max(st.max_ns, ns);
			return;
		}
	}
	append(*z.stats, Zone_Stat.{name, 1, ns, ns});
}

zone_stat :: (z: *Zones, name: string) -> Zone_Stat {
	for st: z.stats { if st.name == name { return st; } }
	return .{name = name};
}

// Totals per zone, largest first: calls, total ms, mean and max per call.
zones_report :: (z: *Zones, allocator := temp) -> string {
	stats := clone(view(z.stats), temp);
	slice.sort_by(stats, (a: Zone_Stat, b: Zone_Stat) -> bool {return a.ns > b.ns;});
	b := strings.builder_make(allocator);
	fmt.sbprintfln(*b, "%-28s %8s %10s %9s %9s", "zone", "calls", "total ms", "mean us", "max us");
	for st: stats {
		fmt.sbprintfln(*b, "%-28s %8s %10s %9s %9s", st.name, num(cast(float64)(st.calls), 0), num(cast(float64)(st.ns) / 1000000, 2), num(cast(float64)(st.ns) / 1000 / cast(float64)(max(st.calls, 1)), 1), num(cast(float64)(st.max_ns) / 1000, 1));
	}
	return strings.to_string(b);
}

// v with the given decimals, for columns: fmt pads numbers with zeros, strings with spaces.
num :: (v: float64, decimals: int) -> string {
	if decimals == {
	case 0;
		return fmt.tprintf("%d", cast(s64)(v));
	case 1;
		return fmt.tprintf("%.1f", v);
	case 2;
		return fmt.tprintf("%.2f", v);
	}
	return fmt.tprintf("%.3f", v);
}

// Chrome trace event format (complete events), readable by ui.perfetto.dev and chrome://tracing.
write_chrome_trace :: (z: *Zones, path: string) -> bool {
	b := strings.builder_make(temp);
	strings.write_string(*b, "{\"traceEvents\":[\n");
	for e, i: z.events {
		if i > 0 { strings.write_string(*b, ",\n"); }
		fmt.sbprintf(*b, "{{\"name\":%q,\"ph\":\"X\",\"pid\":1,\"tid\":1,\"ts\":%.3f,\"dur\":%.3f}}", e.name, cast(float64)(e.start_ns) / 1000, cast(float64)(e.dur_ns) / 1000);
	}
	strings.write_string(*b, "\n]}\n");
	return os.write_entire_file(path, transmute([]u8, strings.to_string(b))) == null;
}

