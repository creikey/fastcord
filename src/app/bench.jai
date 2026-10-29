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
	pass_start: Apollo_Time; // monotonic
	render_start: Apollo_Time;
	gpu_frame: u64;
	frame_start: Apollo_Time;
	// startup.txt: wall time from main() (dc.process_start) to the fixture's READY in the store, to the first
	// frame done on the GPU, and to the first frame that drew the open channel with every image it asked
	// for loaded; then resident memory once idle (`startup_report`).
	ready_ns, first_frame_ns, drawn_ns: s64;
	idle_rss: s64;
}

bench: Bench;

bench_parse_flag :: (a: string) -> bool {
	flag :: (a: string, prefix: string, value: *string) -> bool {
		if !begins_with(a, prefix) return false;
		value.* = advance(a, prefix.count);
		return true;
	}
	if !(a == "-bench" || flag(a, "-bench:", *bench.out_path) || flag(a, "-prof:", *bench.prof_prefix) || flag(a, "-trace:", *bench.trace_path) || flag(a, "-shape:", *bench.shape_path)) return false;
	bench.on = true;
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

bench_shape :: () -> Bench_Shape {
	s := store();
	sh: Bench_Shape;
	sh.rail.allocator = temp;
	sh.users = s.users.count;
	for * u: s.users { if u.avatar != "" { sh.users_with_avatar += 1; } }
	sh.guilds = s.guilds.count;
	for * g: s.guilds {
		sh.roles += g.roles.count;
		sh.emojis += g.emojis.count;
		for e: g.emojis { if e.animated { sh.animated_emojis += 1; } }
		if g.icon != "" sh.guilds_with_icon += 1;
	}
	for e: rail_entries() {
		re := Bench_Rail_Entry.{folder = e.id != 0};
		re.guilds.allocator = temp;
		for gid: e.guilds {
			g := dc.guild_get(s, gid);
			if g == null continue;
			array_add(*re.guilds, bench_guild_shape(s, g));
		}
		array_add(*sh.rail, re);
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
		r := table_find_pointer(*s.read_states, c.id);
		if c.last_message_id > (ifx r then r.last_message_id else 0) {
			sh.unread_channels += 1;
			if dm sh.unread_dms += 1;
		}
		if r && r.mention_count > 0 {
			sh.mention_channels += 1;
			if dm sh.mention_dms += 1;
		}
	}
	for s.members sh.members += it.count;
	sh.presences = s.presences.count;
	for r: s.relationships {
		if r.kind == .Friend { sh.friends += 1; } else { sh.other_relationships += 1; }
	}
	sh.read_states = s.read_states.count;
	sh.guild_settings = s.guild_settings.count;
	for gs: s.guild_settings {
		if gs.muted sh.muted_guilds += 1;
		sh.muted_channels += gs.muted_channels.count;
		sh.collapsed_categories += gs.collapsed_channels.count;
	}
	sh.images = images.count;
	for im, url: images {
		if im.state == .Ready sh.images_ready += 1;
		if contains(url, "/embed/avatars/")  sh.default_avatar_images += 1;
		else if contains(url, "/avatars/")   sh.avatar_images += 1;
		else if contains(url, "/icons/")     sh.icon_images += 1;
		else if contains(url, "/emojis/")    sh.emoji_images += 1;
		else                                 sh.other_images += 1;
	}
	sh.textures = gfx.texture_count();
	for * l: s.messages {
		if l.messages.count == 0 continue;
		sh.channels_with_messages += 1;
		sh.messages += l.messages.count;
		sh.max_messages_in_channel = max(sh.max_messages_in_channel, l.messages.count);
	}
	if app.view.channel != 0 {
		for * m: dc.messages_get(s, app.view.channel) {
			sh.view_messages += 1;
			sh.view_reactions += m.reactions.count;
			sh.view_attachments += m.attachments.count;
			sh.view_embeds += m.embeds.count;
			if m.referenced_id != 0 sh.view_replies += 1;
			sh.view_mentions += m.mentions.count;
			sh.view_content_bytes += m.content.count;
		}
	}
	return sh;
}

// Script command `bench <name>`: ends the current section and starts a new one.
bench_section :: (name: string) {
	if !bench.on return;
	if !bench.measuring {
		bench.measuring = true;
		prof.zones_begin(*bench.zones, trace = bench.trace_path != "");
		if bench.prof_prefix != "" && !bench.sampling {
			bench.sampling = true;
			prof.sampler_start(*bench.sampler, prof.current_thread(), 2000, *bench.gate);
		}
	}
	array_add(*bench.sections, .{name = copy_string(name)});
	bench_write_shape();
	s := store();
	kind := "home";
	ch := dc.channel_get(s, app.view.channel);
	if ch kind = ifx ch.kind == .DM || ch.kind == .Group_DM then "dm" else "guild channel";
	else if app.view.guild != 0 kind = "guild";
	print("section % view %, % messages loaded, % images, % textures\n", left(name, 14), kind, dc.messages_get(s, app.view.channel).count, images.count, gfx.texture_count());
}

// `bench_off`: frames until the next `bench` are not measured (loading, settling, navigation).
bench_pause :: () {
	if !bench.measuring return;
	bench.measuring = false;
	prof.zones_end();
}

bench_frame_begin :: () {
	if bench.measuring bench.frame_start = current_time_monotonic();
}

bench_startup_ready :: () { if bench.on bench.ready_ns = ns_since(dc.process_started()); }

// End of each frame until the open channel is drawn with its images: waits for the GPU, so the times are
// what the window shows.
bench_startup_frame :: () {
	if !bench.on || bench.drawn_ns || app.no_render return;
	gfx.wait_gpu();
	t := ns_since(dc.process_started());
	if !bench.first_frame_ns bench.first_frame_ns = t;
	if app.view.channel && dc.messages_get(store(), app.view.channel).count && images_pending() == 0 bench.drawn_ns = t;
}

bench_frame_end :: () {
	if !bench.measuring return;
	ns := ns_since(bench.frame_start);
	array_add(*peek_pointer(bench.sections).frame_ns, ns);
	prof.zone_add(*bench.zones, "frame", ns);
}

bench_pass_begin :: () {
	if !bench.measuring return;
	atomic_store(*bench.gate, 1);
	bench.pass_start = current_time_monotonic();
}

bench_pass_end :: () {
	if !bench.measuring return;
	ns := ns_since(bench.pass_start);
	atomic_store(*bench.gate, 0);
	sec := peek_pointer(bench.sections);
	array_add(*sec.pass_ns, ns);
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
	if !bench.measuring return;
	atomic_store(*bench.gate, 1);
	bench.render_start = current_time_monotonic();
}

bench_render_end :: () {
	if !bench.measuring return;
	ns := ns_since(bench.render_start);
	atomic_store(*bench.gate, 0);
	sec := peek_pointer(bench.sections);
	array_add(*sec.render_ns, ns);
	prof.zone_add(*bench.zones, "render", ns);
	// The app sleeps until input, so a frame starts with an idle GPU and what the user feels is
	// latency: frame start to the GPU finishing it. Waiting here also keeps frames from overlapping.
	w := current_time_monotonic();
	gfx.wait_gpu();
	prof.zone_add(*bench.zones, "gpu.wait", ns_since(w));
	array_add(*sec.latency_ns, ns_since(bench.frame_start));
	st := gfx.stats();
	sec.instances = max(sec.instances, st.instances);
	sec.batches = max(sec.batches, st.draw_calls);
	if st.gpu_frame != bench.gpu_frame && st.gpu_ns > 0 {
		bench.gpu_frame = st.gpu_frame;
		array_add(*sec.gpu_ns, st.gpu_ns);
	}
}

// Prints the sections and writes the requested files. Called once the script has run.
bench_finish :: () {
	if !bench.on return;
	bench.measuring = false;
	prof.zones_end();
	prof.sampler_stop(*bench.sampler);
	out: String_Builder;
	out.allocator = temp;
	for sec: bench.sections {
		pass := summarize(sec.pass_ns);
		frame := summarize(sec.frame_ns);
		render := summarize(sec.render_ns);
		gpu := summarize(sec.gpu_ns);
		lat := summarize(sec.latency_ns);
		p := sec.peak;
		pad := left("", 14);
		print("bench % latency median % ms  p95 %  min %  (% frames)\n", left(sec.name, 14), num7(lat.median), num7(lat.p95), num7(lat.min), sec.latency_ns.count);
		print("      % ui pass median % ms  p95 %  min %  (% passes, 2 per frame)\n", pad, num7(pass.median), num7(pass.p95), num7(pass.min), sec.pass_ns.count);
		print("      % render (CPU) median % ms  p95 %  GPU median % ms  p95 %  (% timed)\n", pad, num7(render.median), num7(render.p95), num7(gpu.median), num7(gpu.p95), sec.gpu_ns.count);
		print("      % per pass: % boxes (% keyed), % text layouts, % shape calls, % glyphs, % draw cmds, % KB arena\n", pad, p.boxes, p.keyed_boxes, p.text_layouts, p.shape_calls, p.glyphs, p.draw_cmds, p.arena_bytes / 1024);
		print("      % per frame: % quads in % draw calls\n", pad, sec.instances, sec.batches);
		print_to_builder(*out, "{\"name\":\"%\",\"passes\":%,\"latency_ms\":%,\"pass_ms\":%,\"render_ms\":%,\"gpu_ms\":%,\"instances\":%,\"batches\":%,\"frame_ms\":%,\"boxes\":%,\"keyed_boxes\":%,\"text_layouts\":%,\"shape_calls\":%,\"glyphs\":%,\"draw_cmds\":%,\"arena_bytes\":%}\n",
			sec.name, sec.pass_ns.count, ms_json(lat), ms_json(pass), ms_json(render), ms_json(gpu), sec.instances, sec.batches, ms_json(frame),
			p.boxes, p.keyed_boxes, p.text_layouts, p.shape_calls, p.glyphs, p.draw_cmds, p.arena_bytes);
	}
	if bench.idle_rss {
		ms :: (ns: s64) -> string { return tprint("%", formatFloat(cast(float64) ns / 1000000, trailing_width = 1, zero_removal = .NO)); }
		print("startup: READY in % ms, first frame % ms, channel drawn with images % ms, % MB resident once idle\n", ms(bench.ready_ns), ms(bench.first_frame_ns), ms(bench.drawn_ns), bench.idle_rss >> 20);
		print_to_builder(*out, "{\"name\":\"startup\",\"ready_ms\":%,\"first_frame_ms\":%,\"drawn_ms\":%,\"idle_rss_mb\":%}\n", ms(bench.ready_ns), ms(bench.first_frame_ns), ms(bench.drawn_ns), bench.idle_rss >> 20);
	}
	if bench.zones.stats.count > 0 write_string(prof.zones_report(*bench.zones));
	if bench.out_path != "" && !append_file(bench.out_path, builder_to_string(*out,, temp)) print("cannot write %\n", bench.out_path, to_standard_error = true);
	if bench.trace_path != "" && prof.write_chrome_trace(*bench.zones, bench.trace_path) print("trace written to %\n", bench.trace_path);
	if bench.prof_prefix != "" {
		report := prof.sampler_report(*bench.sampler, 30);
		folded := tprint("%.folded", bench.prof_prefix);
		txt := tprint("%.txt", bench.prof_prefix);
		if !prof.write_folded(*bench.sampler, folded) || !write_entire_file(txt, report) print("cannot write % or %\n", txt, folded, to_standard_error = true);
		write_string(report);
		print("profile written to % and % (open the .folded in speedscope.app)\n", txt, folded);
	}
}

#scope_file

bench_guild_shape :: (s: *dc.Store, g: *dc.Guild) -> Bench_Guild_Shape {
	gs := Bench_Guild_Shape.{roles = g.roles.count, emojis = g.emojis.count};
	m := table_find_pointer(*s.members, g.id);
	if m gs.members = m.count;
	for cid: g.channels {
		c := dc.channel_get(s, cid);
		if c == null continue;
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
		r := table_find_pointer(*s.read_states, cid);
		if c.last_message_id > (ifx r then r.last_message_id else 0) gs.unread += 1;
		if r && r.mention_count > 0 gs.mentions += 1;
	}
	st := table_find_pointer(*s.guild_settings, g.id);
	if st gs.muted = st.muted;
	return gs;
}

// Writes the account's shape as JSON once, at the first measured section (after the warm-up wait).
bench_write_shape :: () {
	if bench.shape_path == "" || bench.shape_written return;
	bench.shape_written = true;
	sh := bench_shape();
	if !write_entire_file(bench.shape_path, marshal_pretty(sh)) {
		print("cannot write %\n", bench.shape_path, to_standard_error = true);
		return;
	}
	print("shape written to %\n", bench.shape_path);
}

Ms :: struct {
	min, median, p95, mean: float64;
}

summarize :: (ns: []s64) -> Ms {
	if ns.count == 0 return .{};
	s := array_copy(ns,, temp);
	quick_sort(s, (a: s64, b: s64) -> s64 { return a - b; });
	sum: s64;
	for s sum += it;
	quantile :: (s: []s64, q: float64) -> float64 { return cast(float64) s[min(cast(int) (q * cast(float64) s.count), s.count - 1)] / 1000000; }
	return .{cast(float64) s[0] / 1000000, quantile(s, 0.5), quantile(s, 0.95), cast(float64) sum / cast(float64) s.count / 1000000};
}

// {"min":%.4f,"median":%.4f,"p95":%.4f,"mean":%.4f}
ms_json :: (m: Ms) -> string {
	f :: (x: float64) -> string { return tprint("%", formatFloat(x, trailing_width = 4, zero_removal = .NO)); }
	return tprint("{\"min\":%,\"median\":%,\"p95\":%,\"mean\":%}", f(m.min), f(m.median), f(m.p95), f(m.mean));
}

ns_since :: (t: Apollo_Time) -> s64 { return to_nanoseconds(current_time_monotonic() - t); }

// Odin's %-14s and %7s.
left :: (s: string, n: int) -> string { return ifx s.count >= n then s else tprint("%1%2", s, to_string(SPACES.data, n - s.count)); }
num7 :: (x: float64) -> string { s := prof.num(x, 3); return ifx s.count >= 7 then s else tprint("%1%2", to_string(SPACES.data, 7 - s.count), s); }
SPACES :: "                ";

append_file :: (path: string, data: string) -> bool {
	f, ok := file_open(path, for_writing = true, keep_existing_content = true, log_errors = false);
	if !ok return false;
	file_set_position(f, file_length(f));
	ok = file_write(*f, data);
	file_close(*f);
	return ok;
}
