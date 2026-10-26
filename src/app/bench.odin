package app

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:time"
import dc "fc:discord"
import "fc:gfx"
import "fc:prof"
import "fc:ui"

// Benchmarks and profiling of the UI passes (tests/bench, tools/bench.sh, README "Performance").
// A script marks measured sections with `bench <name>`; every UI pass in a section is timed and its
// ui.Stats kept. Flags:
//   -bench[:<file>]   print a summary per section at exit; with a file, also append one JSON line each
//   -prof:<prefix>    sample the UI thread during UI passes in sections: <prefix>.txt, <prefix>.folded
//   -trace:<file>     Chrome trace of the prof zones in sections (ui.perfetto.dev)
//   -shape:<file>     the account's shape (counts only) as JSON, for tests/bench/make_bench_fixture.py
Bench_Section :: struct {
	name:     string,
	pass_ns:   [dynamic]i64, // each UI pass
	render_ns: [dynamic]i64, // each frame's draw command translation and gfx submit
	frame_ns:  [dynamic]i64, // each whole frame
	latency_ns: [dynamic]i64, // frame start until the GPU finished drawing it
	gpu_ns:    [dynamic]i64, // GPU time of each timed frame (gfx timestamp queries; 0 samples if unsupported)
	instances: int, // peak gfx instances (quads) per frame
	batches:   int, // peak gfx draw calls per frame
	peak:     ui.Stats, // per-pass maximum of each counter
}

Bench :: struct {
	on:          bool,
	out_path:    string,
	prof_prefix: string,
	trace_path:  string,
	shape_path:  string,
	shape_written: bool,
	sections:    [dynamic]Bench_Section,
	measuring:   bool,
	sampling:    bool,
	gate:       i32, // 1 while a measured UI pass or render runs (the sampler keeps only those samples)
	sampler:     prof.Sampler,
	zones:       prof.Zones,
	pass_start:  time.Tick,
	render_start: time.Tick,
	gpu_frame:   u64,
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
	case strings.has_prefix(a, "-shape:"):
		bench.on = true
		bench.shape_path = a[len("-shape:"):]
	case:
		return false
	}
	return true
}

// Counts that decide how much work a frame does, for matching tests/bench/make_bench_fixture.py to a
// real account (`-shape:<file>` writes it as JSON). Only counts: no names, ids or content.
Bench_Shape :: struct {
	users, users_with_avatar, guilds, guilds_with_icon:                      int,
	guild_channels, categories, voice, threads, dms, group_dms:              int,
	roles, emojis, animated_emojis, members, presences:                      int,
	friends, other_relationships, read_states:                               int,
	unread_channels, unread_dms, mention_channels, mention_dms:              int,
	guild_settings, muted_guilds, muted_channels, collapsed_categories:      int,
	channels_with_messages, messages, max_messages_in_channel:               int,
	view_messages, view_reactions, view_attachments, view_embeds:            int,
	view_replies, view_mentions, view_content_bytes:                         int,
	images, images_ready, textures:                                          int,
	avatar_images, icon_images, emoji_images, default_avatar_images:         int,
	other_images:                                                            int,
	rail:                                                                   [dynamic]Bench_Rail_Entry, // sidebar order
}

Bench_Rail_Entry :: struct {
	folder: bool,
	guilds: [dynamic]Bench_Guild_Shape,
}

Bench_Guild_Shape :: struct {
	channels, categories, voice, threads, roles, emojis, members, unread, mentions: int,
	muted:                                                                          bool,
}

@(private = "file")
bench_guild_shape :: proc(s: ^dc.Store, g: ^dc.Guild) -> Bench_Guild_Shape {
	gs := Bench_Guild_Shape{roles = len(g.roles), emojis = len(g.emojis)}
	if m, ok := &s.members[g.id]; ok do gs.members = len(m)
	for cid in g.channels {
		c := dc.channel_get(s, cid)
		if c == nil do continue
		#partial switch c.kind {
		case .Guild_Category:
			gs.categories += 1
		case .Guild_Voice, .Guild_Stage_Voice:
			gs.voice += 1
		case .Announcement_Thread, .Public_Thread, .Private_Thread:
			gs.threads += 1
		case:
			gs.channels += 1
		}
		r, has := &s.read_states[cid]
		if c.last_message_id > (has ? r.last_message_id : 0) do gs.unread += 1
		if has && r.mention_count > 0 do gs.mentions += 1
	}
	if st, ok := &s.guild_settings[g.id]; ok do gs.muted = st.muted
	return gs
}

bench_shape :: proc() -> Bench_Shape {
	s := store()
	sh := Bench_Shape {
		rail = make([dynamic]Bench_Rail_Entry, context.temp_allocator),
	}
	sh.users = len(s.users)
	for _, &u in s.users do if u.avatar != "" do sh.users_with_avatar += 1
	sh.guilds = len(s.guilds)
	for _, &g in s.guilds {
		sh.roles += len(g.roles)
		sh.emojis += len(g.emojis)
		for e in g.emojis do if e.animated do sh.animated_emojis += 1
		if g.icon != "" do sh.guilds_with_icon += 1
	}
	for e in rail_entries() {
		re := Bench_Rail_Entry{folder = e.id != 0, guilds = make([dynamic]Bench_Guild_Shape, context.temp_allocator)}
		for gid in e.guilds {
			g := dc.guild_get(s, gid)
			if g == nil do continue
			append(&re.guilds, bench_guild_shape(s, g))
		}
		append(&sh.rail, re)
	}
	for _, &c in s.channels {
		#partial switch c.kind {
		case .DM:
			sh.dms += 1
		case .Group_DM:
			sh.group_dms += 1
		case .Guild_Category:
			sh.categories += 1
		case .Guild_Voice, .Guild_Stage_Voice:
			sh.voice += 1
		case .Announcement_Thread, .Public_Thread, .Private_Thread:
			sh.threads += 1
		case:
			sh.guild_channels += 1
		}
		dm := c.kind == .DM || c.kind == .Group_DM
		r, has := &s.read_states[c.id]
		if c.last_message_id > (has ? r.last_message_id : 0) {
			sh.unread_channels += 1
			if dm do sh.unread_dms += 1
		}
		if has && r.mention_count > 0 {
			sh.mention_channels += 1
			if dm do sh.mention_dms += 1
		}
	}
	for _, m in s.members do sh.members += len(m)
	sh.presences = len(s.presences)
	for _, r in s.relationships {
		if r.kind == .Friend do sh.friends += 1
		else do sh.other_relationships += 1
	}
	sh.read_states = len(s.read_states)
	sh.guild_settings = len(s.guild_settings)
	for _, gs in s.guild_settings {
		if gs.muted do sh.muted_guilds += 1
		sh.muted_channels += len(gs.muted_channels)
		sh.collapsed_categories += len(gs.collapsed_channels)
	}
	sh.images = len(images)
	for url, im in images {
		if im.state == .Ready do sh.images_ready += 1
		switch {
		case strings.contains(url, "/embed/avatars/"): sh.default_avatar_images += 1
		case strings.contains(url, "/avatars/"):       sh.avatar_images += 1
		case strings.contains(url, "/icons/"):         sh.icon_images += 1
		case strings.contains(url, "/emojis/"):        sh.emoji_images += 1
		case:                                          sh.other_images += 1
		}
	}
	sh.textures = gfx.texture_count()
	for _, &l in s.messages {
		if len(l.messages) == 0 do continue
		sh.channels_with_messages += 1
		sh.messages += len(l.messages)
		sh.max_messages_in_channel = max(sh.max_messages_in_channel, len(l.messages))
	}
	if app.view.channel != 0 {
		for &m in dc.messages_get(s, app.view.channel) {
			sh.view_messages += 1
			sh.view_reactions += len(m.reactions)
			sh.view_attachments += len(m.attachments)
			sh.view_embeds += len(m.embeds)
			if m.referenced_id != 0 do sh.view_replies += 1
			sh.view_mentions += len(m.mentions)
			sh.view_content_bytes += len(m.content)
		}
	}
	return sh
}

// Writes the account's shape as JSON once, at the first measured section (after the warm-up wait).
@(private = "file")
bench_write_shape :: proc() {
	if bench.shape_path == "" || bench.shape_written do return
	bench.shape_written = true
	sh := bench_shape()
	data, err := json.marshal(sh, {pretty = true}, context.temp_allocator)
	if err != nil || os.write_entire_file(bench.shape_path, data) != nil {
		fmt.eprintln("cannot write", bench.shape_path)
		return
	}
	fmt.println("shape written to", bench.shape_path)
}

// Script command `bench <name>`: ends the current section and starts a new one.
bench_section :: proc(name: string) {
	if !bench.on do return
	if !bench.measuring {
		bench.measuring = true
		prof.zones_begin(&bench.zones, trace = bench.trace_path != "")
		if bench.prof_prefix != "" && !bench.sampling {
			bench.sampling = true
			prof.sampler_start(&bench.sampler, prof.current_thread(), 2000, &bench.gate)
		}
	}
	append(&bench.sections, Bench_Section{name = strings.clone(name)})
	bench_write_shape()
	s := store()
	kind := "home"
	if ch := dc.channel_get(s, app.view.channel); ch != nil do kind = ch.kind == .DM || ch.kind == .Group_DM ? "dm" : "guild channel"
	else if app.view.guild != 0 do kind = "guild"
	fmt.printfln("section %-14s view %s, %d messages loaded, %d images, %d textures", name, kind, len(dc.messages_get(s, app.view.channel)), len(images), gfx.texture_count())
}

// `bench_off`: frames until the next `bench` are not measured (loading, settling, navigation).
bench_pause :: proc() {
	if !bench.measuring do return
	bench.measuring = false
	prof.zones_end()
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

bench_render_begin :: proc() {
	if !bench.measuring do return
	sync.atomic_store(&bench.gate, 1)
	bench.render_start = time.tick_now()
}

bench_render_end :: proc() {
	if !bench.measuring do return
	ns := i64(time.tick_since(bench.render_start))
	sync.atomic_store(&bench.gate, 0)
	sec := &bench.sections[len(bench.sections) - 1]
	append(&sec.render_ns, ns)
	prof.zone_add(&bench.zones, "render", ns)
	// The app sleeps until input, so a frame starts with an idle GPU and what the user feels is
	// latency: frame start to the GPU finishing it. Waiting here also keeps frames from overlapping.
	w := time.tick_now()
	gfx.wait_gpu()
	wait_ns := i64(time.tick_since(w))
	prof.zone_add(&bench.zones, "gpu.wait", wait_ns)
	append(&sec.latency_ns, i64(time.tick_since(bench.frame_start)))
	st := gfx.stats()
	sec.instances = max(sec.instances, st.instances)
	sec.batches = max(sec.batches, st.draw_calls)
	if st.gpu_frame != bench.gpu_frame && st.gpu_ns > 0 {
		bench.gpu_frame = st.gpu_frame
		append(&sec.gpu_ns, st.gpu_ns)
	}
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
		render := summarize(sec.render_ns[:])
		gpu := summarize(sec.gpu_ns[:])
		lat := summarize(sec.latency_ns[:])
		p := sec.peak
		fmt.printfln("bench %-14s latency median %7s ms  p95 %7s  min %7s  (%d frames)", sec.name, prof.num(lat.median, 3), prof.num(lat.p95, 3), prof.num(lat.min, 3), len(sec.latency_ns))
		fmt.printfln("      %-14s ui pass median %7s ms  p95 %7s  min %7s  (%d passes, 2 per frame)", "", prof.num(pass.median, 3), prof.num(pass.p95, 3), prof.num(pass.min, 3), len(sec.pass_ns))
		fmt.printfln("      %-14s render (CPU) median %7s ms  p95 %7s  GPU median %7s ms  p95 %7s  (%d timed)", "", prof.num(render.median, 3), prof.num(render.p95, 3), prof.num(gpu.median, 3), prof.num(gpu.p95, 3), len(sec.gpu_ns))
		fmt.printfln("      %-14s per pass: %d boxes (%d keyed), %d text layouts, %d shape calls, %d glyphs, %d draw cmds, %d KB arena", "", p.boxes, p.keyed_boxes, p.text_layouts, p.shape_calls, p.glyphs, p.draw_cmds, p.arena_bytes / 1024)
		fmt.printfln("      %-14s per frame: %d quads in %d draw calls", "", sec.instances, sec.batches)
		fmt.sbprintfln(&out, `{{"name":%q,"passes":%d,"latency_ms":{{"min":%.4f,"median":%.4f,"p95":%.4f,"mean":%.4f}},"pass_ms":{{"min":%.4f,"median":%.4f,"p95":%.4f,"mean":%.4f}},"render_ms":{{"min":%.4f,"median":%.4f,"p95":%.4f,"mean":%.4f}},"gpu_ms":{{"min":%.4f,"median":%.4f,"p95":%.4f,"mean":%.4f}},"instances":%d,"batches":%d,"frame_ms":{{"min":%.4f,"median":%.4f,"p95":%.4f,"mean":%.4f}},"boxes":%d,"keyed_boxes":%d,"text_layouts":%d,"shape_calls":%d,"glyphs":%d,"draw_cmds":%d,"arena_bytes":%d}}`,
			sec.name, len(sec.pass_ns), lat.min, lat.median, lat.p95, lat.mean, pass.min, pass.median, pass.p95, pass.mean, render.min, render.median, render.p95, render.mean, gpu.min, gpu.median, gpu.p95, gpu.mean, sec.instances, sec.batches, frame.min, frame.median, frame.p95, frame.mean,
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
