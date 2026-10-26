package app

// Dead-control sweep (headless, -sweep:tests/ui/sweep.txt): for every screen
// in the spec, every reachable clickable box is pressed from a fresh fixture
// state and the sweep records whether anything observable changed (pixels,
// app/view state, focus, clipboard, attempted network or OS actions). Controls
// that do nothing, hover states that stick after the mouse leaves, and text
// inputs that don't take typing are reported; tests/ui/sweep_allow.txt lists
// the known inert ones with a reason each, and anything else fails the run.

import "core:fmt"
import "core:hash/xxhash"
import "core:os"
import "core:strconv"
import "core:strings"
import "fc:audio"
import dc "fc:discord"
import "fc:gfx"
import "fc:platform"
import "fc:ui"

@(private = "file")
Sweep_Screen :: struct {
	name:       string,
	fixture:    string,
	channel:    string,
	setup:      [dynamic]string,
	hold_mouse: bool, // the screen needs the mouse where setup left it (hover toolbars)
	login:      bool, // show the intro / token screen
	size:       [2]int,
}

@(private = "file")
Sweep_Box :: struct {
	key:   ui.Key,
	rect:  ui.Rect, // visible rect
	p:     ui.Vec2, // a point where a press reaches this box
	desc:  string,
	input: bool, // text input (I-beam)
}

@(private = "file")
Sweep_Allow :: struct {
	kind, screen, match, reason: string,
	used:                        bool,
}

@(private = "file")
Sweep_Issue :: struct {
	kind, screen, desc, detail, crop, allowed: string,
	rect:                                      ui.Rect,
}

@(private = "file")
Sweep_State :: struct {
	opt:     Options,
	collect: bool,
	boxes:   [dynamic]Sweep_Box,
	anon:    [dynamic]string, // clickable boxes without a key (unreachable)
	geom:    [dynamic]Sweep_Box, // hit area doesn't match what is drawn (desc carries the detail)
	neutral: ui.Vec2,
	issues:  [dynamic]Sweep_Issue,
	allow:   [dynamic]Sweep_Allow,
	out:     string,
	crops:   int,
	capped:  int,
	tested:  map[string]bool, // fixture|overlay|desc already pressed on an earlier screen
	overlay_open: bool, // last collected frame had a popout / modal open
	verbose: bool,
}

@(private = "file")
swp: Sweep_State

// Called by frame() after drawing, while the frame's boxes and strings are alive.
sweep_hook: proc()

SWEEP_OFF :: ui.Vec2{-50, -50} // mouse parked outside the window

// Back to program start, keeping caches (fonts, icons, images, emoji data).
@(private = "file")
app_reset_state :: proc() {
	ui.shutdown(&app.ui)
	ui.init(&app.ui, ui.Backend{shape = ui_shape})
	app.view = {}
	view_init(&app.view)
	app.chats = {}
	app.chat_hover = 0
	app.self_mute, app.self_deaf = false, false
	app.voice_channel = 0
	app.settings_open = false
	app.profile_user = 0
	app.profile_anchor = {}
	app.profile_open_t = 0
	app.pending_dm_user = 0
	app.caret_reset_t = 0
	app.reaction_target = 0
	app.ui_mods = {}
	app.focused_editor = nil
	app.wake_at = 0
	app.last_time = 0
	app.net_actions, app.ext_actions = 0, 0
	theme_load(&app.theme, swp.opt.theme)
	gv = {}
	ev = {}
	sv = {}
	pk = {}
	ma = {}
	sw = {}
	search_reset_for_test()
	rail_reset_for_test()
	pf_reset_for_test()
	vs_reset_for_test()
	audio.select_device(true, 0)
	audio.select_device(false, 0)
	settings_page = "Appearance"
	gdm_reset_for_test()
	pins_reset_for_test()
	forums_reset_for_test()
	block_confirm = {}
	viewer_url, viewer_size, viewer_t = "", {}, 0
	notify_reset_for_test()
	frecency = {}
	voice_reset_for_test()
	platform.clipboard_set("")
	// (old store leaks: store_destroy also tears down the library's feature workers)
	app.offline_store = {}
	dc.store_init(&app.offline_store)
}

@(private = "file")
sweep_fresh :: proc(sc: ^Sweep_Screen) {
	app_reset_state()
	w, h := swp.opt.width, swp.opt.height
	if sc.size != {} do w, h = sc.size.x, sc.size.y
	platform.set_headless_size(w, h)
	if _, ok := dc.store_load_fixture(&app.offline_store, sc.fixture); !ok {
		fmt.eprintln("sweep: cannot load fixture", sc.fixture)
		os.exit(2)
	}
	if sc.channel != "" {
		id, _ := strconv.parse_u64(sc.channel)
		if ch := dc.channel_get(&app.offline_store, dc.Snowflake(id)); ch != nil do select_channel(ch.guild_id, ch.id)
	}
	app.needs_login = sc.login
	script_frame(&script_t)
	script_frame(&script_t)
	script_exec(sc.setup[:], sc.name)
	if !sc.hold_mouse do platform.inject_event({kind = .Mouse_Move, pos = SWEEP_OFF})
	sweep_settle()
}

@(private = "file")
sweep_settle :: proc() {
	for i in 0 ..< 90 {
		sweep_frame()
		if i >= 3 && !ui.needs_frame() do return
	}
	swp.capped += 1
	if swp.verbose do fmt.eprintln("sweep: still animating after 90 frames at", app.ui.animating_loc)
}

// A frame 50 ms after the last (animations settle in a third of the frames;
// under frame()'s 0.1 s dt clamp).
@(private = "file")
sweep_frame :: proc() {
	script_t += 0.05
	platform.set_time_override(script_t)
	platform.wait_events(0)
	frame()
}

@(private = "file")
sweep_move :: proc(p: ui.Vec2) {
	platform.inject_event({kind = .Mouse_Move, pos = p})
	sweep_settle()
}

@(private = "file")
sweep_press :: proc(p: ui.Vec2, button: platform.Mouse_Button) {
	platform.inject_event({kind = .Mouse_Move, pos = p})
	platform.inject_event({kind = .Mouse_Down, pos = p, button = button, click_count = 1})
	platform.inject_event({kind = .Mouse_Up, pos = p, button = button, click_count = 1})
	sweep_settle()
}

@(private = "file")
sweep_key :: proc(k: platform.Key) {
	platform.inject_event({kind = .Key_Down, key = k})
	sweep_settle()
}

// Everything observable after the frame: pixels plus state that may not show.
@(private = "file")
sweep_measure :: proc() -> u64 {
	app.no_render = false
	swp.collect = true
	sweep_frame()
	swp.collect = false
	app.no_render = true
	pixels, _, _ := gfx.read_pixels(context.temp_allocator)
	ed := app.focused_editor != nil ? ui.editor_text(app.focused_editor) : "<none>"
	state := fmt.tprint(
		app.view.guild, app.view.channel, app.view.friends_tab, app.view.show_members, app.view.hide_dm_profile,
		app.settings_open, app.profile_user, settings_page, app.self_mute, app.self_deaf, app.ui.focus, ed,
		sw.open, ma.menu_msg, ma.deleting, ma.editing, ma.replying, ma.reply_mention, len(ma.uploads),
		pk.open, pk.tab, pins_state_for_test(), gdm_state_for_test(), pf_state_for_test(), rail_state_for_test(),
		search_state_for_test(), viewer_url, block_confirm.user, vs.open_dropdown, vs.menu_user,
		app.theme.name, platform.clipboard_get(), app.net_actions, app.ext_actions, app.view.collapsed,
	)
	return xxhash.XXH3_64(pixels) ~ (xxhash.XXH3_64(transmute([]u8)state) * 31)
}

@(private = "file")
sweep_clean :: proc(s: string, max_runes := 40) -> string {
	sb := strings.builder_make(context.allocator)
	n := 0
	for r in s {
		if n >= max_runes {
			strings.write_string(&sb, "…")
			break
		}
		switch r {
		case '\n', '\t':
			strings.write_byte(&sb, ' ')
		case '"':
			strings.write_byte(&sb, '\'')
		case:
			strings.write_rune(&sb, r)
		}
		n += 1
	}
	return strings.to_string(sb)
}

// "parent/id \"label\" [icon]" from the box's ids, first text and first icon.
@(private = "file")
sweep_desc :: proc(b: ^ui.Box) -> string {
	names: [3]string
	n := 0
	for x := b; x != nil && n < 3; x = x.parent {
		if x.key == 0 || x.key == 1 || x.text == "" || .Draw_Text in x.flags do continue
		names[n] = x.text
		n += 1
	}
	sb := strings.builder_make(context.temp_allocator)
	for i := n - 1; i >= 0; i -= 1 {
		strings.write_string(&sb, names[i])
		if i > 0 do strings.write_byte(&sb, '/')
	}
	first_text :: proc(b: ^ui.Box) -> string {
		if .Draw_Text in b.flags && b.text != "" do return b.text
		for c := b.first; c != nil; c = c.next {
			if t := first_text(c); t != "" do return t
		}
		return ""
	}
	first_icon :: proc(b: ^ui.Box) -> string {
		if nm := box_icon_name(b); nm != "" do return nm
		for c := b.first; c != nil; c = c.next {
			if t := first_icon(c); t != "" do return t
		}
		return ""
	}
	if t := first_text(b); t != "" do fmt.sbprintf(&sb, " \"%s\"", t)
	if ic := first_icon(b); ic != "" do fmt.sbprintf(&sb, " [%s]", ic)
	return sweep_clean(strings.to_string(sb), 90)
}

// Hit area vs drawn area: a control cut off by its parents or the window
// (outside a scroll view) can't be pressed where it is drawn as being, and a
// control drawing outside its own rect looks clickable where presses miss it.
@(private = "file")
sweep_geometry :: proc(b: ^ui.Box, vr: ui.Rect) {
	area :: proc(r: ui.Rect) -> f32 {return max(0, r.x1 - r.x0) * max(0, r.y1 - r.y0)}
	_ = vr
	scrolled := false
	for p := b.parent; p != nil; p = p.parent do if p.flags & {.Scroll_X, .Scroll_Y} != {} do scrolled = true
	// vertical cuts are list viewports (some scroll by hand, without Scroll_Y)
	win := ui.Rect{0, 0, app.ui.window.x, app.ui.window.y}
	cut_x := (vr.x1 - vr.x0) < 0.9 * (b.rect.x1 - b.rect.x0)
	cut_win := area(ui.intersect(b.rect, win)) < 0.9 * area(b.rect)
	if !scrolled && (cut_x || cut_win) {
		append(&swp.geom, Sweep_Box{key = b.key, rect = vr, desc = fmt.aprintf("%s|cut off: drawn rect %v, pressable %v", sweep_desc(b), b.rect, vr)})
		return
	}
	outside :: proc(c: ^ui.Box, r: ui.Rect) -> ^ui.Box {
		for x := c.first; x != nil; x = x.next {
			if .Clickable in x.flags do continue // its own control
			drawn := x.flags & {.Draw_Text, .Draw_Background, .Draw_Border} != {} || x.custom_draw != nil
			if drawn && x.flags & {.Floating_X, .Floating_Y} == {} && (x.rect.x0 < r.x0 - 2 || x.rect.y0 < r.y0 - 2 || x.rect.x1 > r.x1 + 2 || x.rect.y1 > r.y1 + 2) do return x
			if o := outside(x, r); o != nil do return o
		}
		return nil
	}
	if o := outside(b, b.rect); o != nil {
		append(&swp.geom, Sweep_Box{key = b.key, rect = b.rect, desc = fmt.aprintf("%s|draws outside its hit area: %v beyond %v", sweep_desc(b), o.rect, b.rect)})
	}
}

// The descriptor without its label: look-alike cells share it.
@(private = "file")
sweep_signature :: proc(desc: string) -> string {
	q0 := strings.index_byte(desc, '\'')
	q1 := strings.last_index_byte(desc, '\'')
	if q0 < 0 || q1 <= q0 do return desc
	return strings.concatenate({desc[:q0], desc[q1 + 1:]}, context.temp_allocator)
}

@(private = "file")
sweep_collect :: proc() {
	if !swp.collect do return
	clear(&swp.boxes)
	clear(&swp.anon)
	clear(&swp.geom)
	swp.overlay_open = false
	for b in app.ui.order do if .Overlay in b.flags && .Clickable in b.flags do swp.overlay_open = true
	win := ui.Rect{0, 0, app.ui.window.x, app.ui.window.y}
	for b in app.ui.order {
		// selectable text needs a key too: the selection anchors on it
		if b.key == 0 && .Selectable_Text in b.flags && .Clickable not_in b.flags && b.text != "" {
			append(&swp.anon, sweep_desc(b))
			continue
		}
		if .Clickable not_in b.flags || .Disabled in b.flags do continue
		vr := ui.intersect(ui.visible_rect(b), win)
		if vr.x1 - vr.x0 < 2 || vr.y1 - vr.y0 < 2 || b.opacity <= 0.01 do continue
		if b.key == 0 {
			append(&swp.anon, sweep_desc(b))
			continue
		}
		sweep_geometry(b, vr)
		// popout / modal panels absorb clicks on their empty parts on purpose
		if .Overlay in b.flags && b.flags & {.Draw_Border, .Draw_Shadow} != {} do continue
		in_ov := ui.in_overlay(b)
		found := false
		p: ui.Vec2
		N :: 9
		search: for iy in 0 ..< N {
			for ix in 0 ..< N {
				// center first, then a grid
				fx, fy := f32(0.5), f32(0.5)
				if iy * N + ix > 0 {
					fx = (f32(ix) + 0.5) / N
					fy = (f32(iy) + 0.5) / N
				}
				q := ui.Vec2{vr.x0 + (vr.x1 - vr.x0) * fx, vr.y0 + (vr.y1 - vr.y0) * fy}
				if !in_ov && ui.overlay_at(q) do continue
				if ui.hit_box(q) == b.key {
					p = q
					found = true
					break search
				}
			}
		}
		if !found do continue
		append(&swp.boxes, Sweep_Box{key = b.key, rect = vr, p = p, desc = sweep_desc(b), input = b.hover_cursor == .IBeam})
	}
}

@(private = "file")
sweep_crop :: proc(screen: string, r: ui.Rect) -> string {
	pixels, w, h := gfx.read_pixels(context.temp_allocator)
	if w == 0 do return ""
	sc := f32(w) / app.ui.window.x
	pad: f32 = 24
	x0 := clamp(int((r.x0 - pad) * sc), 0, w)
	y0 := clamp(int((r.y0 - pad) * sc), 0, h)
	x1 := clamp(int((r.x1 + pad) * sc), 0, w)
	y1 := clamp(int((r.y1 + pad) * sc), 0, h)
	cw, ch := x1 - x0, y1 - y0
	if cw <= 0 || ch <= 0 do return ""
	out := make([]u8, cw * ch * 4, context.temp_allocator)
	for y in 0 ..< ch {
		copy(out[y * cw * 4:(y + 1) * cw * 4], pixels[((y0 + y) * w + x0) * 4:][:cw * 4])
	}
	// outline the control in red
	for y in 0 ..< ch {
		for x in 0 ..< cw {
			px := f32(x0 + x) / sc
			py := f32(y0 + y) / sc
			on_x := (abs(px - r.x0) < 1 || abs(px - r.x1) < 1) && py >= r.y0 - 1 && py <= r.y1 + 1
			on_y := (abs(py - r.y0) < 1 || abs(py - r.y1) < 1) && px >= r.x0 - 1 && px <= r.x1 + 1
			if on_x || on_y {
				o := out[(y * cw + x) * 4:]
				o[0], o[1], o[2], o[3] = 255, 40, 40, 255
			}
		}
	}
	swp.crops += 1
	path := fmt.aprintf("%s/%s-%d.png", swp.out, screen, swp.crops)
	gfx.write_png(path, out, cw, ch)
	return path
}

@(private = "file")
sweep_issue :: proc(kind, screen: string, t: Sweep_Box, detail: string, crop := true) {
	is := Sweep_Issue{kind = kind, screen = screen, desc = t.desc, detail = detail, rect = t.rect}
	for &a in swp.allow {
		if a.kind != kind || (a.screen != "*" && a.screen != screen) || !strings.contains(t.desc, a.match) do continue
		a.used = true
		is.allowed = a.reason
		break
	}
	if is.allowed == "" && crop do is.crop = sweep_crop(screen, t.rect)
	append(&swp.issues, is)
}

@(private = "file")
sweep_find :: proc(key: ui.Key) -> (Sweep_Box, bool) {
	for b in swp.boxes do if b.key == key do return b, true
	return {}, false
}

// Click, type "abc", Backspace, Escape: the text must land in the clicked field.
@(private = "file")
sweep_input :: proc(sc: ^Sweep_Screen, t: Sweep_Box) {
	sweep_fresh(sc)
	sweep_press(t.p, .Left)
	platform.inject_event({kind = .Text, text = "abc"})
	sweep_settle()
	ed := app.focused_editor
	if ed == nil {
		sweep_issue("input", sc.name, t, "click then typing: no field has keyboard focus")
		return
	}
	f := app.focused_field
	fc := ui.Vec2{(f.x0 + f.x1) / 2, (f.y0 + f.y1) / 2}
	inside := (t.p.x >= f.x0 && t.p.x < f.x1 && t.p.y >= f.y0 && t.p.y < f.y1) || (fc.x >= t.rect.x0 && fc.x < t.rect.x1 && fc.y >= t.rect.y0 && fc.y < t.rect.y1)
	text := strings.clone(ui.editor_text(ed))
	if !inside || !strings.has_suffix(text, "abc") {
		sweep_issue("input", sc.name, t, fmt.aprintf("typed \"abc\" went elsewhere: focused field %v has %q", f, text))
		return
	}
	sweep_key(.Backspace)
	if app.focused_editor != ed || ui.editor_text(ed) != text[:len(text) - 1] {
		sweep_issue("input", sc.name, t, fmt.aprintf("Backspace: want %q, got %q", text[:len(text) - 1], ui.editor_text(ed)))
		return
	}
	sweep_key(.Escape)
	if app.focused_editor == ed && len(ui.editor_text(ed)) > len(text) {
		sweep_issue("input", sc.name, t, "Escape inserted text")
	}
}

@(private = "file")
sweep_screen :: proc(sc: ^Sweep_Screen) {
	sweep_fresh(sc)
	swp.neutral = sc.hold_mouse ? app.ui.mouse : SWEEP_OFF
	h0 := sweep_measure()
	{
		pixels, w, h := gfx.read_pixels(context.temp_allocator)
		gfx.write_png(fmt.tprintf("%s/%s.png", swp.out, sc.name), pixels, w, h)
	}
	// Controls repeated across screens (rail, header, user panel) are pressed once
	// per fixture and overlay context; a grid of look-alike cells (emoji, GIFs)
	// at most SAME_MAX times per screen.
	SAME_MAX :: 3
	targets := make([dynamic]Sweep_Box, context.allocator)
	same := make(map[string]int, allocator = context.temp_allocator)
	for b in swp.boxes {
		k := fmt.aprintf("%s|%v|%s", sc.fixture, swp.overlay_open, b.desc)
		if k in swp.tested do continue
		swp.tested[k] = true
		sig := sweep_signature(b.desc)
		if same[sig] >= SAME_MAX do continue
		same[sig] += 1
		append(&targets, b)
	}
	for a in swp.anon {
		sweep_issue("anon", sc.name, Sweep_Box{desc = a}, "clickable or selectable box has no key (duplicate id in its id scope?): presses and selections can never anchor on it", false)
	}
	for g in swp.geom {
		i := strings.index_byte(g.desc, '|')
		k := fmt.aprintf("geom|%s|%s", sc.fixture, g.desc[:i])
		if k in swp.tested do continue
		swp.tested[k] = true
		gb := g
		gb.desc = g.desc[:i]
		sweep_issue("hitarea", sc.name, gb, g.desc[i + 1:])
	}
	fmt.eprintfln("sweep: %s: %d controls (%d pressed)", sc.name, len(swp.boxes), len(targets))
	nondet := false
	for t in targets {
		if swp.verbose do fmt.eprintfln("sweep:   %s at %v", t.desc, t.p)
		sweep_fresh(sc)
		hf := sweep_measure()
		if hf != h0 && !nondet {
			nondet = true
			sweep_issue("nondeterministic", sc.name, {desc = "<screen>"}, "fresh state differs between runs (state leaks across sweep resets?)", false)
		}
		cur, ok := sweep_find(t.key)
		if !ok || cur.p != t.p {
			sweep_issue("nondeterministic", sc.name, t, "control moved or vanished between fresh runs", false)
			continue
		}
		sweep_move(t.p)
		sweep_move(swp.neutral)
		if sweep_measure() != hf do sweep_issue("hover", sc.name, t, "hover state stays after the mouse leaves")
		sweep_move(t.p)
		hh := sweep_measure()
		sweep_press(t.p, .Left)
		if sweep_measure() == hh {
			// right-click-only targets (messages, members) are alive too
			sweep_fresh(sc)
			sweep_move(t.p)
			hr := sweep_measure()
			sweep_press(t.p, .Right)
			if sweep_measure() == hr do sweep_issue("dead", sc.name, t, "click changed nothing")
		}
		if t.input do sweep_input(sc, t)
	}
}

@(private = "file")
sweep_parse :: proc(path: string) -> [dynamic]Sweep_Screen {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		fmt.eprintln("sweep: cannot read", path)
		os.exit(2)
	}
	out := make([dynamic]Sweep_Screen)
	for line in strings.split_lines(string(data)) {
		f := strings.fields(line)
		if len(f) == 0 || strings.has_prefix(f[0], "#") do continue
		if f[0] == "screen" {
			// screen <name> <fixture> [channel=<id>] [size=WxH] [hold_mouse]
			sc := Sweep_Screen{name = f[1], fixture = f[2]}
			for o in f[3:] {
				switch {
				case strings.has_prefix(o, "channel="):
					sc.channel = o[len("channel="):]
				case strings.has_prefix(o, "size="):
					wh := strings.split(o[len("size="):], "x")
					sc.size.x, _ = strconv.parse_int(wh[0])
					sc.size.y, _ = strconv.parse_int(wh[1])
				case o == "hold_mouse":
					sc.hold_mouse = true
				case o == "login":
					sc.login = true
				}
			}
			append(&out, sc)
		} else if len(out) > 0 {
			append(&out[len(out) - 1].setup, strings.trim_space(line))
		}
	}
	return out
}

// tests/ui/sweep_allow.txt: <kind> <screen|*> "<descriptor substring>" <reason…>
@(private = "file")
sweep_parse_allow :: proc(path: string) {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil do return
	for line, i in strings.split_lines(string(data)) {
		l := strings.trim_space(line)
		if l == "" || l[0] == '#' do continue
		q0 := strings.index_byte(l, '"')
		q1 := q0 >= 0 ? strings.index_byte(l[q0 + 1:], '"') : -1
		if q1 < 0 {
			fmt.eprintfln("%s:%d: want: kind screen \"match\" reason", path, i + 1)
			os.exit(2)
		}
		head := strings.fields(l[:q0])
		reason := strings.trim_space(l[q0 + 1 + q1 + 1:])
		if len(head) != 2 || reason == "" {
			fmt.eprintfln("%s:%d: want: kind screen \"match\" reason (the reason is required)", path, i + 1)
			os.exit(2)
		}
		append(&swp.allow, Sweep_Allow{kind = head[0], screen = head[1], match = l[q0 + 1:][:q1], reason = reason})
	}
}

// Runs the sweep and returns the process exit code.
sweep_run :: proc(opt: Options) -> int {
	swp.opt = opt
	swp.verbose = os.get_env("FASTCORD_SWEEP_VERBOSE", context.temp_allocator) != ""
	swp.out = opt.sweep_out != "" ? opt.sweep_out : "build/sweep"
	os.make_directory_all(swp.out)
	app.sweep = true
	app.no_render = true
	sweep_hook = sweep_collect
	screens := sweep_parse(opt.sweep)
	allow_path := fmt.tprintf("%s_allow.txt", strings.trim_suffix(opt.sweep, ".txt"))
	sweep_parse_allow(allow_path)
	platform.set_time_override(0)
	for &sc in screens {
		if opt.sweep_only != "" && sc.name != opt.sweep_only do continue
		sweep_screen(&sc)
	}

	sb := strings.builder_make()
	bad := 0
	for is in swp.issues {
		status := is.allowed != "" ? "allowed" : "FAIL"
		if is.allowed == "" do bad += 1
		fmt.sbprintf(&sb, "%-7s %-16s %-20s %s rect=(%.0f,%.0f %.0fx%.0f)", status, is.kind, is.screen, is.desc, is.rect.x0, is.rect.y0, is.rect.x1 - is.rect.x0, is.rect.y1 - is.rect.y0)
		if is.allowed != "" do fmt.sbprintf(&sb, " — %s", is.allowed)
		else do fmt.sbprintf(&sb, " — %s", is.detail)
		if is.crop != "" do fmt.sbprintf(&sb, " crop=%s", is.crop)
		strings.write_byte(&sb, '\n')
	}
	if opt.sweep_only == "" {
		for a in swp.allow {
			if !a.used do fmt.sbprintf(&sb, "stale   allowlist entry matched nothing: %s %s \"%s\"\n", a.kind, a.screen, a.match)
		}
	}
	report := strings.to_string(sb)
	_ = os.write_entire_file(fmt.tprintf("%s/report.txt", swp.out), transmute([]u8)report)
	for line in strings.split_lines(report) {
		if strings.has_prefix(line, "FAIL") || strings.has_prefix(line, "stale") do fmt.eprintln(line)
	}
	if swp.verbose do fmt.eprintfln("sweep: %d frames, %d settles hit the cap", app.frame, swp.capped)
	fmt.eprintfln("sweep: %d issues, %d not allowlisted (report: %s/report.txt)", len(swp.issues), bad, swp.out)
	return bad > 0 ? 1 : 0
}
