// Benchmarks and profiling of the UI passes (tests/bench, tools/bench.sh, README "Performance").
// A script marks measured sections with `bench <name>`; every UI pass in a section is timed and its
// ui.Stats kept. Flags:
//   -bench[:<file>]   print a summary per section at exit; with a file, also append one JSON line each
//   -prof:<prefix>    sample the UI thread during UI passes in sections: <prefix>.txt, <prefix>.folded
//   -trace:<file>     Chrome trace of the prof zones in sections (ui.perfetto.dev)
//   -shape:<file>     the account's shape (counts only) as JSON, for tests/bench/make_bench_fixture.py
Bench_Section :: struct {
	name: string;
	pass_ns: [..]s64; // each UI pass
	render_ns: [..]s64; // each frame's draw command translation and gfx submit
	frame_ns: [..]s64; // each whole frame
	latency_ns: [..]s64; // frame start until the GPU finished drawing it
	gpu_ns: [..]s64; // GPU time of each timed frame (gfx timestamp queries; 0 samples if unsupported)
	instances: int; // peak gfx instances (quads) per frame
	batches: int; // peak gfx draw calls per frame
	peak: ui.Stats; // per-pass maximum of each counter
}

Bench :: struct {
	on: bool;
	out_path: string;
	prof_prefix: string;
	trace_path: string;
	shape_path: string;
	shape_written: bool;
	sections: [..]Bench_Section;
	measuring: bool;
	sampling: bool;
	gate: s32; // 1 while a measured UI pass or render runs (the sampler keeps only those samples)
	sampler: prof.Sampler;
	zones: prof.Zones;
	pass_start: time.Tick;
	render_start: time.Tick;
	gpu_frame: u64;
	frame_start: time.Tick;
}

bench: Bench;

bench_parse_flag :: (a: string) -> bool {
	if a == "-bench" {
		bench.on = true;
	} else if strings.has_prefix(a, "-bench:") {
		bench.on = true;
		bench.out_path = sub_from(a, len("-bench:"));
	} else if strings.has_prefix(a, "-prof:") {
		bench.on = true;
		bench.prof_prefix = sub_from(a, len("-prof:"));
	} else if strings.has_prefix(a, "-trace:") {
		bench.on = true;
		bench.trace_path = sub_from(a, len("-trace:"));
	} else if strings.has_prefix(a, "-shape:") {
		bench.on = true;
		bench.shape_path = sub_from(a, len("-shape:"));
	} else {
		return false;
	}
	return true;
}

// Counts that decide how much work a frame does, for matching tests/bench/make_bench_fixture.py to a
// real account (`-shape:<file>` writes it as JSON). Only counts: no names, ids or content.
Bench_Shape :: struct {
	users, users_with_avatar, guilds, guilds_with_icon: int;
	guild_channels, categories, voice, threads, dms, group_dms: int;
	roles, emojis, animated_emojis, members, presences: int;
	friends, other_relationships, read_states: int;
	unread_channels, unread_dms, mention_channels, mention_dms: int;
	guild_settings, muted_guilds, muted_channels, collapsed_categories: int;
	channels_with_messages, messages, max_messages_in_channel: int;
	view_messages, view_reactions, view_attachments, view_embeds: int;
	view_replies, view_mentions, view_content_bytes: int;
	images, images_ready, textures: int;
	avatar_images, icon_images, emoji_images, default_avatar_images: int;
	other_images: int;
	rail: [..]Bench_Rail_Entry; // sidebar order
}

Bench_Rail_Entry :: struct {
	folder: bool;
	guilds: [..]Bench_Guild_Shape;
}

Bench_Guild_Shape :: struct {
	channels, categories, voice, threads, roles, emojis, members, unread, mentions: int;
	muted: bool;
}
#scope_file

bench_guild_shape :: (s: *dc.Store, g: *dc.Guild) -> Bench_Guild_Shape {
	gs := Bench_Guild_Shape.{roles = len(g.roles), emojis = len(g.emojis)};
	{ m, ok := map_find_ptr(*s.members, g.id);
	if ok { gs.members = len(m); } }
	for cid: g.channels {
		c := dc.channel_get(s, cid);
		if c == null { continue; }
		if c.kind == {
		case .Guild_Category;
			gs.categories += 1;
		case .Guild_Voice; #through; case .Guild_Stage_Voice;
			gs.voice += 1;
		case .Announcement_Thread; #through; case .Public_Thread; #through; case .Private_Thread;
			gs.threads += 1;
		case;
			gs.channels += 1;
		}
		r, has := map_find_ptr(*s.read_states, cid);
		if c.last_message_id > (ifx has then r.last_message_id else 0) { gs.unread += 1; }
		if has && r.mention_count > 0 { gs.mentions += 1; }
	}
	{ st, ok := map_find_ptr(*s.guild_settings, g.id);
	if ok { gs.muted = st.muted; } }
	return gs;
}
#scope_export

bench_shape :: () -> Bench_Shape {
	s := store();
	sh := Bench_Shape.{
		rail = make_dynamic(Bench_Rail_Entry, 0, 0, temp)
	};
	sh.users = len(s.users);
	for * u: s.users { if u.avatar != "" { sh.users_with_avatar += 1; } }
	sh.guilds = len(s.guilds);
	for * g: s.guilds {
		sh.roles += len(g.roles);
		sh.emojis += len(g.emojis);
		for e: g.emojis { if e.animated { sh.animated_emojis += 1; } }
		if g.icon != "" { sh.guilds_with_icon += 1; }
	}
	for e: rail_entries() {
		re := Bench_Rail_Entry.{folder = e.id != 0, guilds = make_dynamic(Bench_Guild_Shape, 0, 0, temp)};
		for gid: e.guilds {
			g := dc.guild_get(s, gid);
			if g == null { continue; }
			append(*re.guilds, bench_guild_shape(s, g));
		}
		append(*sh.rail, re);
	}
	for * c: s.channels {
		if c.kind == {
		case .DM;
			sh.dms += 1;
		case .Group_DM;
			sh.group_dms += 1;
		case .Guild_Category;
			sh.categories += 1;
		case .Guild_Voice; #through; case .Guild_Stage_Voice;
			sh.voice += 1;
		case .Announcement_Thread; #through; case .Public_Thread; #through; case .Private_Thread;
			sh.threads += 1;
		case;
			sh.guild_channels += 1;
		}
		dm := c.kind == .DM || c.kind == .Group_DM;
		r, has := map_find_ptr(*s.read_states, c.id);
		if c.last_message_id > (ifx has then r.last_message_id else 0) {
			sh.unread_channels += 1;
			if dm { sh.unread_dms += 1; }
		}
		if has && r.mention_count > 0 {
			sh.mention_channels += 1;
			if dm { sh.mention_dms += 1; }
		}
	}
	for m: s.members { sh.members += len(m); }
	sh.presences = len(s.presences);
	for r: s.relationships {
		if r.kind == .Friend { sh.friends += 1; } else { sh.other_relationships += 1; }
	}
	sh.read_states = len(s.read_states);
	sh.guild_settings = len(s.guild_settings);
	for gs: s.guild_settings {
		if gs.muted { sh.muted_guilds += 1; }
		sh.muted_channels += len(gs.muted_channels);
		sh.collapsed_categories += len(gs.collapsed_channels);
	}
	sh.images = len(images);
	for im, url: images {
		if im.state == .Ready { sh.images_ready += 1; }
		if strings.contains(url, "/embed/avatars/") { sh.default_avatar_images += 1;
		} else if strings.contains(url, "/avatars/") {       sh.avatar_images += 1;
		} else if strings.contains(url, "/icons/") {         sh.icon_images += 1;
		} else if strings.contains(url, "/emojis/") {        sh.emoji_images += 1;
		} else {                                          sh.other_images += 1;
		}
	}
	sh.textures = gfx.texture_count();
	for * l: s.messages {
		if len(l.messages) == 0 { continue; }
		sh.channels_with_messages += 1;
		sh.messages += len(l.messages);
		sh.max_messages_in_channel = max(sh.max_messages_in_channel, len(l.messages));
	}
	if app.view.channel != 0 {
		for * m: dc.messages_get(s, app.view.channel) {
			sh.view_messages += 1;
			sh.view_reactions += len(m.reactions);
			sh.view_attachments += len(m.attachments);
			sh.view_embeds += len(m.embeds);
			if m.referenced_id != 0 { sh.view_replies += 1; }
			sh.view_mentions += len(m.mentions);
			sh.view_content_bytes += len(m.content);
		}
	}
	return sh;
}
#scope_file

// Writes the account's shape as JSON once, at the first measured section (after the warm-up wait).
bench_write_shape :: () {
	if bench.shape_path == "" || bench.shape_written { return; }
	bench.shape_written = true;
	sh := bench_shape();
	data, err := json.marshal(sh, .{pretty = true}, temp);
	if err != .None || os.write_entire_file(bench.shape_path, data) != null {
		fmt.eprintln("cannot write", bench.shape_path);
		return;
	}
	fmt.println("shape written to", bench.shape_path);
}
#scope_export

// Script command `bench <name>`: ends the current section and starts a new one.
bench_section :: (name: string) {
	if !bench.on { return; }
	if !bench.measuring {
		bench.measuring = true;
		prof.zones_begin(*bench.zones, trace = bench.trace_path != "");
		if bench.prof_prefix != "" && !bench.sampling {
			bench.sampling = true;
			prof.sampler_start(*bench.sampler, prof.current_thread(), 2000, *bench.gate);
		}
	}
	append(*bench.sections, Bench_Section.{name = clone(name)});
	bench_write_shape();
	s := store();
	kind := "home";
	{ ch := dc.channel_get(s, app.view.channel);
	if ch != null { kind = ifx ch.kind == .DM || ch.kind == .Group_DM then "dm" else "guild channel"; } else if app.view.guild != 0 { kind = "guild"; } }
	fmt.printfln("section %-14s view %s, %d messages loaded, %d images, %d textures", name, kind, len(dc.messages_get(s, app.view.channel)), len(images), gfx.texture_count());
}

// `bench_off`: frames until the next `bench` are not measured (loading, settling, navigation).
bench_pause :: () {
	if !bench.measuring { return; }
	bench.measuring = false;
	prof.zones_end();
}

bench_frame_begin :: () {
	if bench.measuring { bench.frame_start = time.tick_now(); }
}

bench_frame_end :: () {
	if !bench.measuring { return; }
	ns := cast(s64)(time.tick_since(bench.frame_start));
	append(*bench.sections[len(bench.sections) - 1].frame_ns, ns);
	prof.zone_add(*bench.zones, "frame", ns);
}

bench_pass_begin :: () {
	if !bench.measuring { return; }
	atomic_store(*bench.gate, 1);
	bench.pass_start = time.tick_now();
}

bench_pass_end :: () {
	if !bench.measuring { return; }
	ns := cast(s64)(time.tick_since(bench.pass_start));
	atomic_store(*bench.gate, 0);
	sec := *bench.sections[len(bench.sections) - 1];
	append(*sec.pass_ns, ns);
	prof.zone_add(*bench.zones, "ui.pass", ns);
	st := app.ui.stats;
	p := *sec.peak;
	p.boxes = max(p.boxes, st.boxes);
	p.keyed_boxes = max(p.keyed_boxes, st.keyed_boxes);
	p.text_layouts = max(p.text_layouts, st.text_layouts);
	p.shape_calls = max(p.shape_calls, st.shape_calls);
	p.glyphs = max(p.glyphs, st.glyphs);
	p.draw_cmds = max(p.draw_cmds, st.draw_cmds);
	p.arena_bytes = max(p.arena_bytes, st.arena_bytes);
}

bench_render_begin :: () {
	if !bench.measuring { return; }
	atomic_store(*bench.gate, 1);
	bench.render_start = time.tick_now();
}

bench_render_end :: () {
	if !bench.measuring { return; }
	ns := cast(s64)(time.tick_since(bench.render_start));
	atomic_store(*bench.gate, 0);
	sec := *bench.sections[len(bench.sections) - 1];
	append(*sec.render_ns, ns);
	prof.zone_add(*bench.zones, "render", ns);
	// The app sleeps until input, so a frame starts with an idle GPU and what the user feels is
	// latency: frame start to the GPU finishing it. Waiting here also keeps frames from overlapping.
	w := time.tick_now();
	gfx.wait_gpu();
	wait_ns := cast(s64)(time.tick_since(w));
	prof.zone_add(*bench.zones, "gpu.wait", wait_ns);
	append(*sec.latency_ns, cast(s64)(time.tick_since(bench.frame_start)));
	st := gfx.stats();
	sec.instances = max(sec.instances, st.instances);
	sec.batches = max(sec.batches, st.draw_calls);
	if st.gpu_frame != bench.gpu_frame && st.gpu_ns > 0 {
		bench.gpu_frame = st.gpu_frame;
		append(*sec.gpu_ns, st.gpu_ns);
	}
}
#scope_file

Ms :: struct {
	min, median, p95, mean: float64;
}

summarize :: (ns: []s64) -> Ms {
	if len(ns) == 0 { return .{}; }
	s := clone(ns, temp);
	slice.sort(s);
	sum: s64;
	for v: s { sum += v; }
	at :: (s: []s64, q: float64) -> float64 {return cast(float64)(s[min(cast(int)(q * cast(float64)(len(s))), len(s) - 1)]) / 1000000;}
	return .{cast(float64)(s[0]) / 1000000, at(s, 0.5), at(s, 0.95), cast(float64)(sum) / cast(float64)(len(s)) / 1000000};
}
#scope_export

// Prints the sections and writes the requested files. Called once the script has run.
bench_finish :: () {
	if !bench.on { return; }
	bench.measuring = false;
	prof.zones_end();
	prof.sampler_stop(*bench.sampler);
	out := strings.builder_make(temp);
	for sec: bench.sections {
		pass := summarize(view(sec.pass_ns));
		frame := summarize(view(sec.frame_ns));
		render := summarize(view(sec.render_ns));
		gpu := summarize(view(sec.gpu_ns));
		lat := summarize(view(sec.latency_ns));
		p := sec.peak;
		fmt.printfln("bench %-14s latency median %7s ms  p95 %7s  min %7s  (%d frames)", sec.name, prof.num(lat.median, 3), prof.num(lat.p95, 3), prof.num(lat.min, 3), len(sec.latency_ns));
		fmt.printfln("      %-14s ui pass median %7s ms  p95 %7s  min %7s  (%d passes, 2 per frame)", "", prof.num(pass.median, 3), prof.num(pass.p95, 3), prof.num(pass.min, 3), len(sec.pass_ns));
		fmt.printfln("      %-14s render (CPU) median %7s ms  p95 %7s  GPU median %7s ms  p95 %7s  (%d timed)", "", prof.num(render.median, 3), prof.num(render.p95, 3), prof.num(gpu.median, 3), prof.num(gpu.p95, 3), len(sec.gpu_ns));
		fmt.printfln("      %-14s per pass: %d boxes (%d keyed), %d text layouts, %d shape calls, %d glyphs, %d draw cmds, %d KB arena", "", p.boxes, p.keyed_boxes, p.text_layouts, p.shape_calls, p.glyphs, p.draw_cmds, p.arena_bytes / 1024);
		fmt.printfln("      %-14s per frame: %d quads in %d draw calls", "", sec.instances, sec.batches);
		fmt.sbprintfln(*out, "{{\"name\":%q,\"passes\":%d,\"latency_ms\":{{\"min\":%.4f,\"median\":%.4f,\"p95\":%.4f,\"mean\":%.4f}},\"pass_ms\":{{\"min\":%.4f,\"median\":%.4f,\"p95\":%.4f,\"mean\":%.4f}},\"render_ms\":{{\"min\":%.4f,\"median\":%.4f,\"p95\":%.4f,\"mean\":%.4f}},\"gpu_ms\":{{\"min\":%.4f,\"median\":%.4f,\"p95\":%.4f,\"mean\":%.4f}},\"instances\":%d,\"batches\":%d,\"frame_ms\":{{\"min\":%.4f,\"median\":%.4f,\"p95\":%.4f,\"mean\":%.4f}},\"boxes\":%d,\"keyed_boxes\":%d,\"text_layouts\":%d,\"shape_calls\":%d,\"glyphs\":%d,\"draw_cmds\":%d,\"arena_bytes\":%d}}",
			sec.name, len(sec.pass_ns), lat.min, lat.median, lat.p95, lat.mean, pass.min, pass.median, pass.p95, pass.mean, render.min, render.median, render.p95, render.mean, gpu.min, gpu.median, gpu.p95, gpu.mean, sec.instances, sec.batches, frame.min, frame.median, frame.p95, frame.mean,
			p.boxes, p.keyed_boxes, p.text_layouts, p.shape_calls, p.glyphs, p.draw_cmds, p.arena_bytes);
	}
	if len(bench.zones.stats) > 0 { fmt.print(prof.zones_report(*bench.zones)); }
	if bench.out_path != "" {
		f, err := os.open(bench.out_path, .Write | .Create | .Append, os.Permissions_Default_File);
		if err == null {
			os.write_string(f, strings.to_string(out));
			os.close(f);
		} else {
			fmt.eprintln("cannot write", bench.out_path);
		}
	}
	if bench.trace_path != "" && prof.write_chrome_trace(*bench.zones, bench.trace_path) { fmt.println("trace written to", bench.trace_path); }
	if bench.prof_prefix != "" {
		report := prof.sampler_report(*bench.sampler, 30);
		folded := strings.concatenate(string.[bench.prof_prefix, ".folded"], temp);
		txt := strings.concatenate(string.[bench.prof_prefix, ".txt"], temp);
		ok := prof.write_folded(*bench.sampler, folded) && os.write_entire_file(txt, transmute([]u8, report)) == null;
		if !ok { fmt.eprintln("cannot write", txt, "or", folded); }
		fmt.print(report);
		fmt.printfln("profile written to %s and %s (open the .folded in speedscope.app)", txt, folded);
	}
}

