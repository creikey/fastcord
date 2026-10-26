/// Package prof measures where time goes: named timing zones (with an optional Chrome trace of
/// them) and a sampling profiler that interrupts one thread and records its stacks.
///
/// Zones, on the thread that called zones_begin (cheap no-ops everywhere else):
///
///	z: prof.Zones
///	prof.zones_begin(&z, trace = true)
///	{
///		prof.zone("layout")       // ends at the end of the enclosing scope
///		...
///	}
///	prof.zones_end()
///	fmt.print(prof.zones_report(&z))
///	prof.write_chrome_trace(&z, "trace.json")   // open in ui.perfetto.dev or chrome://tracing
///
/// Sampling (see sampler.odin):
///
///	s: prof.Sampler
///	prof.sampler_start(&s, prof.current_thread())   // called on the thread to be sampled
///	...
///	prof.sampler_stop(&s)
///	prof.write_folded(&s, "out.folded")            // speedscope.app, inferno, flamegraph.pl
///	fmt.print(prof.sampler_report(&s, 25))
package prof

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"

Zone_Stat :: struct {
	name:   string,
	calls:  int,
	ns:     i64,
	max_ns: i64,
}

Trace_Event :: struct {
	name:     string,
	start_ns: i64, // since zones_begin
	dur_ns:   i64,
}

Zones :: struct {
	stats:  [dynamic]Zone_Stat,
	events: [dynamic]Trace_Event,
	trace:  bool,
	origin: time.Tick,
}

Zone_Mark :: struct {
	name:  string,
	start: time.Tick,
}

@(thread_local, private)
zones_on: ^Zones

// Zones opened on the calling thread are recorded into z until zones_end. With trace, every zone
// is also kept as an event for write_chrome_trace.
zones_begin :: proc(z: ^Zones, trace := false) {
	z.trace = trace
	if z.origin == {} do z.origin = time.tick_now()
	zones_on = z
}

zones_end :: proc() {
	zones_on = nil
}

zones_destroy :: proc(z: ^Zones) {
	if zones_on == z do zones_on = nil
	delete(z.stats)
	delete(z.events)
	z^ = {}
}

// Times the rest of the enclosing scope. name must outlive the Zones (use a literal).
@(deferred_out = zone_end)
zone :: #force_inline proc(name: string) -> Zone_Mark {
	return zone_begin(name)
}

// Starts a zone that zone_end closes, for spans that are not a scope.
zone_begin :: #force_inline proc(name: string) -> Zone_Mark {
	if zones_on == nil do return {}
	return {name, time.tick_now()}
}

zone_end :: proc(m: Zone_Mark) {
	z := zones_on
	if z == nil || m.name == "" do return
	now := time.tick_now()
	ns := time.tick_diff(m.start, now)
	zone_add(z, m.name, i64(ns))
	if z.trace do append(&z.events, Trace_Event{m.name, i64(time.tick_diff(z.origin, m.start)), i64(ns)})
}

// Adds a measurement taken some other way (e.g. a whole frame) to a zone's totals.
zone_add :: proc(z: ^Zones, name: string, ns: i64) {
	for &st in z.stats {
		if raw_data(st.name) == raw_data(name) || st.name == name {
			st.calls += 1
			st.ns += ns
			st.max_ns = max(st.max_ns, ns)
			return
		}
	}
	append(&z.stats, Zone_Stat{name, 1, ns, ns})
}

zone_stat :: proc(z: ^Zones, name: string) -> Zone_Stat {
	for st in z.stats do if st.name == name do return st
	return {name = name}
}

// Totals per zone, largest first: calls, total ms, mean and max per call.
zones_report :: proc(z: ^Zones, allocator := context.temp_allocator) -> string {
	stats := slice.clone(z.stats[:], context.temp_allocator)
	slice.sort_by(stats, proc(a, b: Zone_Stat) -> bool {return a.ns > b.ns})
	b := strings.builder_make(allocator)
	fmt.sbprintfln(&b, "%-28s %8s %10s %9s %9s", "zone", "calls", "total ms", "mean us", "max us")
	for st in stats {
		fmt.sbprintfln(&b, "%-28s %8s %10s %9s %9s", st.name, num(f64(st.calls), 0), num(f64(st.ns) / 1e6, 2), num(f64(st.ns) / 1e3 / f64(max(st.calls, 1)), 1), num(f64(st.max_ns) / 1e3, 1))
	}
	return strings.to_string(b)
}

// v with the given decimals, for columns: fmt pads numbers with zeros, strings with spaces.
num :: proc(v: f64, decimals: int) -> string {
	switch decimals {
	case 0:
		return fmt.tprintf("%d", i64(v))
	case 1:
		return fmt.tprintf("%.1f", v)
	case 2:
		return fmt.tprintf("%.2f", v)
	}
	return fmt.tprintf("%.3f", v)
}

// Chrome trace event format (complete events), readable by ui.perfetto.dev and chrome://tracing.
write_chrome_trace :: proc(z: ^Zones, path: string) -> bool {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "{\"traceEvents\":[\n")
	for e, i in z.events {
		if i > 0 do strings.write_string(&b, ",\n")
		fmt.sbprintf(&b, "{{\"name\":%q,\"ph\":\"X\",\"pid\":1,\"tid\":1,\"ts\":%.3f,\"dur\":%.3f}}", e.name, f64(e.start_ns) / 1e3, f64(e.dur_ns) / 1e3)
	}
	strings.write_string(&b, "\n]}\n")
	return os.write_entire_file(path, transmute([]byte)strings.to_string(b)) == nil
}
