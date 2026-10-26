package app

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:time"
import "fc:prof"
import "fc:ui"

// Benchmarks and profiling of the UI passes (tests/bench, tools/bench.sh, README "Performance").
// A script marks measured sections with `bench <name>`; every UI pass in a section is timed and its
// ui.Stats kept. Flags:
//   -bench[:<file>]   print a summary per section at exit; with a file, also append one JSON line each
//   -prof:<prefix>    sample the UI thread during UI passes in sections: <prefix>.txt, <prefix>.folded
//   -trace:<file>     Chrome trace of the prof zones in sections (ui.perfetto.dev)
Bench_Section :: struct {
	name:     string,
	pass_ns:  [dynamic]i64, // each UI pass
	frame_ns: [dynamic]i64, // each whole frame
	peak:     ui.Stats, // per-pass maximum of each counter
}

Bench :: struct {
	on:          bool,
	out_path:    string,
	prof_prefix: string,
	trace_path:  string,
	sections:    [dynamic]Bench_Section,
	measuring:   bool,
	gate:        i32, // 1 while a measured UI pass runs (the sampler keeps only those samples)
	sampler:     prof.Sampler,
	zones:       prof.Zones,
	pass_start:  time.Tick,
	frame_start: time.Tick,
}

bench: Bench

bench_parse_flag :: proc(a: string) -> bool {
	switch {
	case a == "-bench":
		bench.on = true
	case strings.has_prefix(a, "-bench:"):
		bench.on = true
		bench.out_path = a[len("-bench:"):]
	case strings.has_prefix(a, "-prof:"):
		bench.on = true
		bench.prof_prefix = a[len("-prof:"):]
	case strings.has_prefix(a, "-trace:"):
		bench.on = true
		bench.trace_path = a[len("-trace:"):]
	case:
		return false
	}
	return true
}

// Script command `bench <name>`: ends the current section and starts a new one.
bench_section :: proc(name: string) {
	if !bench.on do return
	if !bench.measuring {
		bench.measuring = true
		prof.zones_begin(&bench.zones, trace = bench.trace_path != "")
		if bench.prof_prefix != "" do prof.sampler_start(&bench.sampler, prof.current_thread(), 2000, &bench.gate)
	}
	append(&bench.sections, Bench_Section{name = strings.clone(name)})
}

bench_frame_begin :: proc() {
	if bench.measuring do bench.frame_start = time.tick_now()
}

bench_frame_end :: proc() {
	if !bench.measuring do return
	ns := i64(time.tick_since(bench.frame_start))
	append(&bench.sections[len(bench.sections) - 1].frame_ns, ns)
	prof.zone_add(&bench.zones, "frame", ns)
}

bench_pass_begin :: proc() {
	if !bench.measuring do return
	sync.atomic_store(&bench.gate, 1)
	bench.pass_start = time.tick_now()
}

bench_pass_end :: proc() {
	if !bench.measuring do return
	ns := i64(time.tick_since(bench.pass_start))
	sync.atomic_store(&bench.gate, 0)
	sec := &bench.sections[len(bench.sections) - 1]
	append(&sec.pass_ns, ns)
	prof.zone_add(&bench.zones, "ui.pass", ns)
	st := app.ui.stats
	p := &sec.peak
	p.boxes = max(p.boxes, st.boxes)
	p.keyed_boxes = max(p.keyed_boxes, st.keyed_boxes)
	p.text_layouts = max(p.text_layouts, st.text_layouts)
	p.shape_calls = max(p.shape_calls, st.shape_calls)
	p.glyphs = max(p.glyphs, st.glyphs)
	p.draw_cmds = max(p.draw_cmds, st.draw_cmds)
	p.arena_bytes = max(p.arena_bytes, st.arena_bytes)
}

@(private = "file")
Ms :: struct {
	min, median, p95, mean: f64,
}

@(private = "file")
summarize :: proc(ns: []i64) -> Ms {
	if len(ns) == 0 do return {}
	s := slice.clone(ns, context.temp_allocator)
	slice.sort(s)
	sum: i64
	for v in s do sum += v
	at :: proc(s: []i64, q: f64) -> f64 {return f64(s[min(int(q * f64(len(s))), len(s) - 1)]) / 1e6}
	return {f64(s[0]) / 1e6, at(s, 0.5), at(s, 0.95), f64(sum) / f64(len(s)) / 1e6}
}

// Prints the sections and writes the requested files. Called once the script has run.
bench_finish :: proc() {
	if !bench.on do return
	bench.measuring = false
	prof.zones_end()
	prof.sampler_stop(&bench.sampler)
	out := strings.builder_make(context.temp_allocator)
	for sec in bench.sections {
		pass := summarize(sec.pass_ns[:])
		frame := summarize(sec.frame_ns[:])
		p := sec.peak
		fmt.printfln("bench %-14s ui pass median %7s ms  p95 %7s  min %7s  (%d passes)  frame median %7s ms", sec.name, prof.num(pass.median, 3), prof.num(pass.p95, 3), prof.num(pass.min, 3), len(sec.pass_ns), prof.num(frame.median, 3))
		fmt.printfln("      %-14s per pass: %d boxes (%d keyed), %d text layouts, %d shape calls, %d glyphs, %d draw cmds, %d KB arena", "", p.boxes, p.keyed_boxes, p.text_layouts, p.shape_calls, p.glyphs, p.draw_cmds, p.arena_bytes / 1024)
		fmt.sbprintfln(&out, `{{"name":%q,"passes":%d,"pass_ms":{{"min":%.4f,"median":%.4f,"p95":%.4f,"mean":%.4f}},"frame_ms":{{"min":%.4f,"median":%.4f,"p95":%.4f,"mean":%.4f}},"boxes":%d,"keyed_boxes":%d,"text_layouts":%d,"shape_calls":%d,"glyphs":%d,"draw_cmds":%d,"arena_bytes":%d}}`,
			sec.name, len(sec.pass_ns), pass.min, pass.median, pass.p95, pass.mean, frame.min, frame.median, frame.p95, frame.mean,
			p.boxes, p.keyed_boxes, p.text_layouts, p.shape_calls, p.glyphs, p.draw_cmds, p.arena_bytes)
	}
	if len(bench.zones.stats) > 0 do fmt.print(prof.zones_report(&bench.zones))
	if bench.out_path != "" {
		f, err := os.open(bench.out_path, {.Write, .Create, .Append}, os.Permissions_Default_File)
		if err == nil {
			os.write_string(f, strings.to_string(out))
			os.close(f)
		} else {
			fmt.eprintln("cannot write", bench.out_path)
		}
	}
	if bench.trace_path != "" && prof.write_chrome_trace(&bench.zones, bench.trace_path) do fmt.println("trace written to", bench.trace_path)
	if bench.prof_prefix != "" {
		report := prof.sampler_report(&bench.sampler, 30)
		folded := strings.concatenate({bench.prof_prefix, ".folded"}, context.temp_allocator)
		txt := strings.concatenate({bench.prof_prefix, ".txt"}, context.temp_allocator)
		ok := prof.write_folded(&bench.sampler, folded) && os.write_entire_file(txt, transmute([]byte)report) == nil
		if !ok do fmt.eprintln("cannot write", txt, "or", folded)
		fmt.print(report)
		fmt.printfln("profile written to %s and %s (open the .folded in speedscope.app)", txt, folded)
	}
}
