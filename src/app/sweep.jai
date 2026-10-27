// Dead-control sweep (headless, -sweep:tests/ui/sweep.txt): for every screen
// in the spec, every reachable clickable box is pressed from a fresh fixture
// state and the sweep records whether anything observable changed (pixels,
// app/view state, focus, clipboard, attempted network or OS actions). Controls
// that do nothing, that make a request without any visible feedback (silent), hover states that stick after the mouse leaves, and text
// inputs that don't take typing are reported; tests/ui/sweep_allow.txt lists
// the known inert ones with a reason each, and anything else fails the run.

// Called by frame() after drawing, while the frame's boxes and strings are alive.
sweep_hook: ();

SWEEP_OFF :: ui.Vec2.{-50, -50}; // mouse parked outside the window

// Runs the sweep and returns the process exit code.
sweep_run :: (opt: Options) -> int {
	swp.opt = opt;
	swp.verbose = env_var("FASTCORD_SWEEP_VERBOSE") != "";
	swp.out = ifx opt.sweep_out != "" then opt.sweep_out else "build/sweep";
	make_directory_if_it_does_not_exist(swp.out, recursive = true);
	app.sweep = true;
	app.no_render = true;
	sweep_hook = sweep_collect;
	screens := sweep_parse(opt.sweep);
	base := opt.sweep;
	if ends_with(base, ".txt") base.count -= 4;
	sweep_parse_allow(tprint("%_allow.txt", base));
	platform.set_time_override(0);
	for * sc: screens {
		if opt.sweep_only != "" && sc.name != opt.sweep_only continue;
		sweep_screen(sc);
	}

	sb: String_Builder;
	bad := 0;
	for is: swp.issues {
		status := ifx is.allowed != "" then "allowed" else "FAIL";
		if is.allowed == "" bad += 1;
		column(*sb, status, 7);
		column(*sb, is.kind, 16);
		column(*sb, is.screen, 20);
		r := is.rect;
		w, h := r.x1 - r.x0, r.y1 - r.y0;
		// %.0f: formatFloat's Any points at its argument, so pass locals that outlive the print
		f :: (x: Any) -> FormatFloat #expand { return formatFloat(x, trailing_width = 0, zero_removal = .NO); }
		print_to_builder(*sb, "% rect=(%,% %x%)", is.desc, f(r.x0), f(r.y0), f(w), f(h));
		print_to_builder(*sb, " — %", ifx is.allowed != "" then is.allowed else is.detail);
		if is.crop != "" print_to_builder(*sb, " crop=%", is.crop);
		append(*sb, #char "\n");
	}
	if opt.sweep_only == "" {
		for swp.allow if !it.used print_to_builder(*sb, "stale   allowlist entry matched nothing: % % \"%\"\n", it.kind, it.screen, it.match);
	}
	report := builder_to_string(*sb);
	write_entire_file(tprint("%/report.txt", swp.out), report);
	for split(report, "\n",, temp) if begins_with(it, "FAIL") || begins_with(it, "stale") eprint("%\n", it);
	if swp.verbose eprint("sweep: % frames, % settles hit the cap\n", app.frame, swp.capped);
	eprint("sweep: % issues, % not allowlisted (report: %/report.txt)\n", swp.issues.count, bad, swp.out);
	return ifx bad > 0 then 1 else 0;
}

#scope_file

Sweep_Screen :: struct {
	name: string;
	fixture: string;
	channel: string;
	setup: [..]string;
	hold_mouse: bool; // the screen needs the mouse where setup left it (hover toolbars)
	login: bool; // show the intro / token screen
	size: Int2;
}

Sweep_Box :: struct {
	key: ui.Key;
	rect: ui.Rect; // visible rect
	p: ui.Vec2; // a point where a press reaches this box
	desc: string;
	input: bool; // text input (I-beam)
}

Sweep_Allow :: struct {
	kind, screen, match, reason: string;
	used: bool;
}

Sweep_Issue :: struct {
	kind, screen, desc, detail, crop, allowed: string;
	rect: ui.Rect;
}

Sweep_State :: struct {
	opt: Options;
	collect: bool;
	boxes: [..]Sweep_Box;
	anon: [..]string; // clickable boxes without a key (unreachable)
	geom: [..]Sweep_Box; // hit area doesn't match what is drawn (desc carries the detail)
	neutral: ui.Vec2;
	issues: [..]Sweep_Issue;
	allow: [..]Sweep_Allow;
	out: string;
	crops: int;
	capped: int;
	tested: Table(string, bool); // fixture|overlay|desc already pressed on an earlier screen
	overlay_open: bool; // last collected frame had a popout / modal open
	verbose: bool;
	seen: u64; // last sweep_measure without app.net_actions (what the user can see)
}

swp: Sweep_State;

eprint :: (format: string, args: ..Any) { print(format, ..args, to_standard_error = true); }

// s left-aligned in a column of w bytes, then a space
column :: (sb: *String_Builder, s: string, w: int) {
	append(sb, s);
	for s.count..w - 1 append(sb, #char " ");
	append(sb, #char " ");
}

// String's slice() (the app module's fc_slice import shadows that name for now)
cut :: inline (s: string, index: int, count: int) -> string { return .{count, s.data + index}; }

// Whitespace-separated words.
fields :: (s: string) -> [..]string {
	out: [..]string;
	out.allocator = temp;
	rest := trim_left(s);
	while rest {
		i := 0;
		while i < rest.count && !is_space(rest[i]) i += 1;
		array_add(*out, cut(rest, 0, i));
		rest = trim_left(advance(rest, i));
	}
	return out;
}

// Back to program start, keeping caches (fonts, icons, images, emoji data).
app_reset_state :: () {
	ui.shutdown(*app.ui);
	ui.init(*app.ui, ui.Backend.{shape = ui_shape});
	app.view = .{};
	view_init(*app.view);
	app.chats = .{};
	app.chat_hover = 0;
	app.self_mute, app.self_deaf = false, false;
	app.voice_channel = 0;
	app.settings_open = false;
	app.profile_user = 0;
	app.profile_anchor = .{};
	app.profile_open_t = 0;
	app.pending_dm_user = 0;
	app.caret_reset_t = 0;
	app.reaction_target = 0;
	app.ui_mods = 0;
	app.focused_editor = null;
	app.wake_at = 0;
	app.last_time = 0;
	app.net_actions, app.ext_actions = 0, 0;
	theme_load(*app.theme, swp.opt.theme);
	gv = .{};
	ev = .{};
	sv = .{};
	pk = .{};
	ma = .{};
	sw = .{};
	search_reset_for_test();
	login_reset_for_test();
	rail_reset_for_test();
	pf_reset_for_test();
	vs_reset_for_test();
	audio.select_device(true, 0);
	audio.select_device(false, 0);
	settings_page = "Appearance";
	settings_reset_for_test();
	gdm_reset_for_test();
	pins_reset_for_test();
	inbox_reset_for_test();
	threads_browser_reset_for_test();
	guild_menu_reset_for_test();
	forums_reset_for_test();
	events_reset_for_test();
	guild_admin_reset_for_test();
	block_confirm = .{};
	edit_menu_state = .{};
	req_reset_for_test();
	fnick = .{};
	attachments_reset_for_test();
	media_reset_for_test();
	notify_reset_for_test();
	account_reset_for_test();
	add_server_reset_for_test();
	settings_nav_reset_for_test();
	sounds_reset_prefs_for_test();
	notify_prefs, theme_follow_os = .{}, false;
	streamer_reset_for_test();
	frecency = .{};
	voice_reset_for_test();
	platform.clipboard_set("");
	// (old store leaks: store_destroy also tears down the library's feature workers)
	app.offline_store = .{};
	dc.store_init(*app.offline_store);
}

sweep_fresh :: (sc: *Sweep_Screen) {
	app_reset_state();
	w, h := swp.opt.width, swp.opt.height;
	if sc.size != .{} w, h = sc.size.x, sc.size.y;
	platform.set_headless_size(w, h);
	_, ok := dc.store_load_fixture(*app.offline_store, sc.fixture);
	if !ok {
		eprint("sweep: cannot load fixture %\n", sc.fixture);
		exit(2);
	}
	if sc.channel != "" {
		id := dc.parse_u64(sc.channel);
		ch := dc.channel_get(*app.offline_store, cast(dc.Snowflake) id);
		if ch select_channel(ch.guild_id, ch.id);
	}
	app.needs_login = sc.login;
	script_frame(*script_t);
	script_frame(*script_t);
	script_exec(sc.setup, sc.name);
	if !sc.hold_mouse platform.inject_event(.{kind = .Mouse_Move, pos = SWEEP_OFF});
	sweep_settle();
}

sweep_settle :: () {
	for i: 0..89 {
		sweep_frame();
		if i >= 3 && !ui.needs_frame() return;
	}
	swp.capped += 1;
	if swp.verbose eprint("sweep: still animating after 90 frames at %\n", app.ui.animating_loc);
}

// A frame 50 ms after the last (animations settle in a third of the frames;
// under frame()'s 0.1 s dt clamp).
sweep_frame :: () {
	script_t += 0.05;
	platform.set_time_override(script_t);
	platform.wait_events(0);
	frame();
}

sweep_move :: (p: ui.Vec2) {
	platform.inject_event(.{kind = .Mouse_Move, pos = p});
	sweep_settle();
}

sweep_press :: (p: ui.Vec2, button: platform.Mouse_Button) {
	platform.inject_event(.{kind = .Mouse_Move, pos = p});
	platform.inject_event(.{kind = .Mouse_Down, pos = p, button = button, click_count = 1});
	platform.inject_event(.{kind = .Mouse_Up, pos = p, button = button, click_count = 1});
	sweep_settle();
}

sweep_key :: (k: platform.Key) {
	platform.inject_event(.{kind = .Key_Down, key = k});
	sweep_settle();
}

// Everything observable after the frame: pixels plus state that may not show.
sweep_measure :: () -> u64 {
	app.no_render = false;
	swp.collect = true;
	sweep_frame();
	swp.collect = false;
	app.no_render = true;
	pixels := gfx.read_pixels(temp);
	ed := ifx app.focused_editor != null then ui.editor_text(app.focused_editor) else "<none>";
	join :: (args: ..Any) -> string {
		sb: String_Builder;
		sb.allocator = temp;
		for args print_to_builder(*sb, "% ", it);
		return builder_to_string(*sb,, temp);
	}
	state := join(
		app.view.guild, app.view.channel, app.view.friends_tab, app.view.show_members, app.view.hide_dm_profile,
		app.settings_open, app.profile_user, settings_page, app.self_mute, app.self_deaf, app.ui.focus, ed,
		sw.open, ma.menu_msg, ma.confirming, ma.editing, ma.replying, ma.reply_mention, staged_count(app.view.channel), att.mod_key, att.notice, att.drag,
		pk.open, pk.tab, pins_state_for_test(), gdm_state_for_test(), pf_state_for_test(), rail_state_for_test(),
		search_state_for_test(), guild_menu_state_for_test(), viewer_url, block_confirm.user, vs.open_dropdown, vs.menu_user,
		app.theme.name, platform.clipboard_get(), app.ext_actions, app.view.collapsed,
		events_state_for_test(), guild_admin_state_for_test(),
	);
	// without the network-attempt count: a press that only tried the network shows nothing
	swp.seen = fnv1a_hash(pixels.data, pixels.count) ^ (fnv1a_hash(state.data, state.count) * 31);
	return swp.seen ^ (cast(u64) app.net_actions * 0x9e3779b97f4a7c15);
}

sweep_clean :: (s: string, max_runes := 40) -> string {
	sb: String_Builder;
	rest := s;
	n := 0;
	while rest {
		if n >= max_runes {
			append(*sb, "…");
			break;
		}
		start := rest;
		r := utf8_next_character(*rest);
		if r == #char "\n" || r == #char "\t" append(*sb, #char " ");
		else if r == #char "\"" append(*sb, #char "'");
		else append(*sb, cut(start, 0, start.count - rest.count));
		n += 1;
	}
	return builder_to_string(*sb);
}

// "parent/id \"label\" [icon]" from the box's ids, first text and first icon.
sweep_desc :: (b: *ui.Box) -> string {
	names: [3]string;
	n := 0;
	x := b;
	while x != null && n < 3 {
		if x.key != 0 && x.key != 1 && x.text != "" && !(x.flags & .Draw_Text) {
			names[n] = x.text;
			n += 1;
		}
		x = x.parent;
	}
	sb: String_Builder;
	sb.allocator = temp;
	for < i: 0..n - 1 {
		append(*sb, names[i]);
		if i > 0 append(*sb, #char "/");
	}
	first_text :: (b: *ui.Box) -> string {
		if (b.flags & .Draw_Text) && b.text != "" return b.text;
		c := b.first;
		while c != null {
			t := first_text(c);
			if t != "" return t;
			c = c.next;
		}
		return "";
	}
	first_icon :: (b: *ui.Box) -> string {
		nm := box_icon_name(b);
		if nm != "" return nm;
		c := b.first;
		while c != null {
			t := first_icon(c);
			if t != "" return t;
			c = c.next;
		}
		return "";
	}
	t := first_text(b);
	if t != "" print_to_builder(*sb, " \"%\"", t);
	ic := first_icon(b);
	if ic != "" print_to_builder(*sb, " [%]", ic);
	return sweep_clean(builder_to_string(*sb,, temp), 90);
}

// Hit area vs drawn area: a control cut off by its parents or the window
// (outside a scroll view) can't be pressed where it is drawn as being, and a
// control drawing outside its own rect looks clickable where presses miss it.
sweep_geometry :: (b: *ui.Box, vr: ui.Rect) {
	area :: (r: ui.Rect) -> float32 { return max(0.0, r.x1 - r.x0) * max(0.0, r.y1 - r.y0); }
	scrolled := false;
	p := b.parent;
	while p != null {
		if p.flags & (.Scroll_X | .Scroll_Y) scrolled = true;
		p = p.parent;
	}
	// vertical cuts are list viewports (some scroll by hand, without Scroll_Y)
	win := ui.Rect.{0, 0, app.ui.window.x, app.ui.window.y};
	cut_x := (vr.x1 - vr.x0) < 0.9 * (b.rect.x1 - b.rect.x0);
	cut_win := area(ui.intersect(b.rect, win)) < 0.9 * area(b.rect);
	if !scrolled && (cut_x || cut_win) {
		array_add(*swp.geom, .{key = b.key, rect = vr, desc = sprint("%|cut off: drawn rect %, pressable %", sweep_desc(b), b.rect, vr)});
		return;
	}
	outside :: (c: *ui.Box, r: ui.Rect) -> *ui.Box {
		x := c.first;
		while x != null {
			if !(x.flags & .Clickable) { // a clickable child is its own control
				drawn := (x.flags & (.Draw_Text | .Draw_Background | .Draw_Border)) || x.custom_draw != null;
				if drawn && !(x.flags & (.Floating_X | .Floating_Y)) && (x.rect.x0 < r.x0 - 2 || x.rect.y0 < r.y0 - 2 || x.rect.x1 > r.x1 + 2 || x.rect.y1 > r.y1 + 2) return x;
				o := outside(x, r);
				if o != null return o;
			}
			x = x.next;
		}
		return null;
	}
	// a clipping control (a modal panel with scrolled pages) can't draw outside itself
	o := outside(b, b.rect);
	if o != null && !(b.flags & .Clip) {
		array_add(*swp.geom, .{key = b.key, rect = b.rect, desc = sprint("%|draws outside its hit area: % beyond %", sweep_desc(b), o.rect, b.rect)});
	}
}

// The descriptor without its label: look-alike cells share it.
sweep_signature :: (desc: string) -> string {
	q0 := find_index_from_left(desc, #char "'");
	q1 := find_index_from_right(desc, #char "'");
	if q0 < 0 || q1 <= q0 return desc;
	return tprint("%1%2", cut(desc, 0, q0), cut(desc, q1 + 1, desc.count - q1 - 1));
}

sweep_collect :: () {
	if !swp.collect return;
	array_reset_keeping_memory(*swp.boxes);
	array_reset_keeping_memory(*swp.anon);
	array_reset_keeping_memory(*swp.geom);
	swp.overlay_open = false;
	for app.ui.order if (it.flags & .Overlay) && (it.flags & .Clickable) swp.overlay_open = true;
	win := ui.Rect.{0, 0, app.ui.window.x, app.ui.window.y};
	for b: app.ui.order {
		// selectable text needs a key too: the selection anchors on it
		if b.key == 0 && (b.flags & .Selectable_Text) && !(b.flags & .Clickable) && b.text != "" {
			array_add(*swp.anon, sweep_desc(b));
			continue;
		}
		if !(b.flags & .Clickable) || (b.flags & .Disabled) continue;
		if b.is_scrollbar || b.hover_cursor == .Resize_H continue; // dragged, not clicked (scrollbars, column edges)
		vr := ui.intersect(ui.visible_rect(b), win);
		if vr.x1 - vr.x0 < 2 || vr.y1 - vr.y0 < 2 || b.opacity <= 0.01 continue;
		if b.key == 0 {
			array_add(*swp.anon, sweep_desc(b));
			continue;
		}
		sweep_geometry(b, vr);
		// popout / modal panels absorb clicks on their empty parts on purpose
		if (b.flags & .Overlay) && (b.flags & (.Draw_Border | .Draw_Shadow)) continue;
		in_ov := ui.in_overlay(b);
		found := false;
		p: ui.Vec2;
		N :: 9;
		for iy: 0..N - 1 {
			for ix: 0..N - 1 {
				// center first, then a grid
				fx, fy := cast(float32) 0.5, cast(float32) 0.5;
				if iy * N + ix > 0 {
					fx = (cast(float32) ix + 0.5) / N;
					fy = (cast(float32) iy + 0.5) / N;
				}
				q := ui.Vec2.{vr.x0 + (vr.x1 - vr.x0) * fx, vr.y0 + (vr.y1 - vr.y0) * fy};
				if !in_ov && ui.overlay_at(q) continue;
				if ui.hit_box(q) == b.key {
					p = q;
					found = true;
					break iy;
				}
			}
		}
		if !found continue;
		array_add(*swp.boxes, .{key = b.key, rect = vr, p = p, desc = sweep_desc(b), input = b.hover_cursor == .IBeam});
	}
}

sweep_crop :: (screen: string, r: ui.Rect) -> string {
	pixels, w, h := gfx.read_pixels(temp);
	if w == 0 return "";
	sc := cast(float32) w / app.ui.window.x;
	pad: float32 = 24;
	x0 := clamp(cast(int) ((r.x0 - pad) * sc), 0, w);
	y0 := clamp(cast(int) ((r.y0 - pad) * sc), 0, h);
	x1 := clamp(cast(int) ((r.x1 + pad) * sc), 0, w);
	y1 := clamp(cast(int) ((r.y1 + pad) * sc), 0, h);
	cw, ch := x1 - x0, y1 - y0;
	if cw <= 0 || ch <= 0 return "";
	out := NewArray(cw * ch * 4, u8,, temp);
	for y: 0..ch - 1 memcpy(out.data + y * cw * 4, pixels.data + ((y0 + y) * w + x0) * 4, cw * 4);
	// outline the control in red
	for y: 0..ch - 1 {
		for x: 0..cw - 1 {
			px := cast(float32) (x0 + x) / sc;
			py := cast(float32) (y0 + y) / sc;
			on_x := (abs(px - r.x0) < 1 || abs(px - r.x1) < 1) && py >= r.y0 - 1 && py <= r.y1 + 1;
			on_y := (abs(py - r.y0) < 1 || abs(py - r.y1) < 1) && px >= r.x0 - 1 && px <= r.x1 + 1;
			if on_x || on_y {
				o := out.data + (y * cw + x) * 4;
				o[0], o[1], o[2], o[3] = 255, 40, 40, 255;
			}
		}
	}
	swp.crops += 1;
	path := sprint("%/%-%.png", swp.out, screen, swp.crops);
	gfx.write_png(path, out, cw, ch);
	return path;
}

sweep_issue :: (kind: string, screen: string, t: Sweep_Box, detail: string, crop := true) {
	is := Sweep_Issue.{kind = kind, screen = screen, desc = t.desc, detail = detail, rect = t.rect};
	for * a: swp.allow {
		if a.kind != kind || (a.screen != "*" && a.screen != screen) || !contains(t.desc, a.match) continue;
		a.used = true;
		is.allowed = a.reason;
		break;
	}
	if is.allowed == "" && crop is.crop = sweep_crop(screen, t.rect);
	array_add(*swp.issues, is);
}

sweep_find :: (key: ui.Key) -> Sweep_Box, bool {
	for swp.boxes if it.key == key return it, true;
	return .{}, false;
}

// Click, type "abc", Backspace, Escape: the text must land in the clicked field.
sweep_input :: (sc: *Sweep_Screen, t: Sweep_Box) {
	sweep_fresh(sc);
	sweep_press(t.p, .Left);
	platform.inject_event(.{kind = .Text, text = "abc"});
	sweep_settle();
	ed := app.focused_editor;
	if ed == null {
		sweep_issue("input", sc.name, t, "click then typing: no field has keyboard focus");
		return;
	}
	f := app.focused_field;
	fc := ui.Vec2.{(f.x0 + f.x1) / 2, (f.y0 + f.y1) / 2};
	inside := (t.p.x >= f.x0 && t.p.x < f.x1 && t.p.y >= f.y0 && t.p.y < f.y1) || (fc.x >= t.rect.x0 && fc.x < t.rect.x1 && fc.y >= t.rect.y0 && fc.y < t.rect.y1);
	text := copy_string(ui.editor_text(ed));
	if !inside || !ends_with(text, "abc") {
		sweep_issue("input", sc.name, t, sprint("typed \"abc\" went elsewhere: focused field % has \"%\"", f, text));
		return;
	}
	sweep_key(.Backspace);
	want := cut(text, 0, text.count - 1);
	if app.focused_editor != ed || ui.editor_text(ed) != want {
		sweep_issue("input", sc.name, t, sprint("Backspace: want \"%\", got \"%\"", want, ui.editor_text(ed)));
		return;
	}
	sweep_key(.Escape);
	if app.focused_editor == ed && ui.editor_text(ed).count > text.count {
		sweep_issue("input", sc.name, t, "Escape inserted text");
	}
}

sweep_screen :: (sc: *Sweep_Screen) {
	sweep_fresh(sc);
	swp.neutral = ifx sc.hold_mouse then app.ui.mouse else SWEEP_OFF;
	h0 := sweep_measure();
	pixels, w, h := gfx.read_pixels(temp);
	gfx.write_png(tprint("%/%.png", swp.out, sc.name), pixels, w, h);
	// Controls repeated across screens (rail, header, user panel) are pressed once
	// per fixture and overlay context; a grid of look-alike cells (emoji, GIFs)
	// at most SAME_MAX times per screen.
	SAME_MAX :: 3;
	targets: [..]Sweep_Box;
	same: Table(string, int);
	defer { array_free(targets); deinit(*same); }
	for b: swp.boxes {
		k := sprint("%|%|%", sc.fixture, swp.overlay_open, b.desc);
		if table_contains(*swp.tested, k) continue;
		table_set(*swp.tested, k, true);
		n := find_or_add(*same, sweep_signature(b.desc));
		if n.* >= SAME_MAX continue;
		n.* += 1;
		array_add(*targets, b);
	}
	for swp.anon {
		sweep_issue("anon", sc.name, .{desc = it}, "clickable or selectable box has no key (duplicate id in its id scope?): presses and selections can never anchor on it", false);
	}
	for g: swp.geom {
		i := find_index_from_left(g.desc, #char "|");
		desc := cut(g.desc, 0, i);
		k := sprint("geom|%|%", sc.fixture, desc);
		if table_contains(*swp.tested, k) continue;
		table_set(*swp.tested, k, true);
		gb := g;
		gb.desc = desc;
		sweep_issue("hitarea", sc.name, gb, cut(g.desc, i + 1, g.desc.count - i - 1));
	}
	eprint("sweep: %: % controls (% pressed)\n", sc.name, swp.boxes.count, targets.count);
	nondet := false;
	for t: targets {
		if swp.verbose eprint("sweep:   % at %\n", t.desc, t.p);
		sweep_fresh(sc);
		hf := sweep_measure();
		if hf != h0 && !nondet {
			nondet = true;
			sweep_issue("nondeterministic", sc.name, .{desc = "<screen>"}, "fresh state differs between runs (state leaks across sweep resets?)", false);
		}
		cur, ok := sweep_find(t.key);
		if !ok || cur.p != t.p {
			sweep_issue("nondeterministic", sc.name, t, "control moved or vanished between fresh runs", false);
			continue;
		}
		sweep_move(t.p);
		sweep_move(swp.neutral);
		if sweep_measure() != hf sweep_issue("hover", sc.name, t, "hover state stays after the mouse leaves");
		sweep_move(t.p);
		hh := sweep_measure();
		seen := swp.seen;
		sweep_press(t.p, .Left);
		after := sweep_measure();
		if after != hh && swp.seen == seen {
			sweep_issue("silent", sc.name, t, "the press made a network request and showed nothing (use req_button / req_begin: requests.jai)");
		} else if after == hh {
			// right-click-only targets (messages, members) are alive too
			sweep_fresh(sc);
			sweep_move(t.p);
			hr := sweep_measure();
			sweep_press(t.p, .Right);
			if sweep_measure() == hr sweep_issue("dead", sc.name, t, "click changed nothing");
		}
		if t.input sweep_input(sc, t);
	}
}

sweep_parse :: (path: string) -> [..]Sweep_Screen {
	data, ok := read_entire_file(path, log_errors = false);
	if !ok {
		eprint("sweep: cannot read %\n", path);
		exit(2);
	}
	out: [..]Sweep_Screen;
	for line: split(data, "\n") {
		f := fields(line);
		if f.count == 0 || begins_with(f[0], "#") continue;
		if f[0] == "screen" {
			// screen <name> <fixture> [channel=<id>] [size=WxH] [hold_mouse]
			sc := Sweep_Screen.{name = f[1], fixture = f[2]};
			for o: array_view(f, 3) {
				if begins_with(o, "channel=") {
					sc.channel = advance(o, "channel=".count);
				} else if begins_with(o, "size=") {
					wh := split(advance(o, "size=".count), "x");
					sc.size.x = string_to_int(wh[0]);
					sc.size.y = string_to_int(wh[1]);
				} else if o == "hold_mouse" {
					sc.hold_mouse = true;
				} else if o == "login" {
					sc.login = true;
				}
			}
			array_add(*out, sc);
		} else if out.count > 0 {
			array_add(*peek_pointer(out).setup, trim(line));
		}
	}
	return out;
}

// tests/ui/sweep_allow.txt: <kind> <screen|*> "<descriptor substring>" <reason…>
sweep_parse_allow :: (path: string) {
	data, ok := read_entire_file(path, log_errors = false);
	if !ok return;
	for line, i: split(data, "\n") {
		l := trim(line);
		if l == "" || l[0] == #char "#" continue;
		q0 := find_index_from_left(l, #char "\"");
		q1 := ifx q0 >= 0 then find_index_from_left(l, #char "\"", q0 + 1) else -1;
		if q1 < 0 {
			eprint("%:%: want: kind screen \"match\" reason\n", path, i + 1);
			exit(2);
		}
		head := fields(cut(l, 0, q0));
		reason := trim(advance(l, q1 + 1));
		if head.count != 2 || reason == "" {
			eprint("%:%: want: kind screen \"match\" reason (the reason is required)\n", path, i + 1);
			exit(2);
		}
		array_add(*swp.allow, .{kind = head[0], screen = head[1], match = cut(l, q0 + 1, q1 - q0 - 1), reason = reason});
	}
}
