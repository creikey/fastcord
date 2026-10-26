package app

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import dc "fc:discord"
import "fc:gfx"
import "fc:platform"
import "fc:ui"

UI_Rect :: ui.Rect
UI_Mods :: ui.Mods

App :: struct {
	theme:           Theme,
	ui:              ui.State,
	last_time:       f64,
	frame:           u64,
	view:            View_State,
	client:          ^dc.Client, // nil when offline (fixture / tests)
	offline_store:   dc.Store,
	chats:           map[dc.Snowflake]Chat_State,
	chat_hover:      dc.Snowflake,
	utc_offset_ms:   i64,
	self_mute:       bool,
	self_deaf:       bool,
	voice_channel:   dc.Snowflake,
	settings_open:   bool,
	profile_user:    dc.Snowflake,
	profile_anchor:  UI_Rect,
	profile_open_t:  f32,
	pending_dm_user: dc.Snowflake,
	caret_reset_t:   f64,
	reaction_target: dc.Snowflake, // message whose reaction picker is open
	ui_mods:         UI_Mods, // modifier keys as of the latest event
	stats:           bool, // FASTCORD_STATS=1: print frame rate periodically
	wake_at:         f64, // earliest timed repaint requested this frame (caret blink, timers); 0 = none
}

// Ask for a repaint at time t without animating continuously.
request_wake :: proc(t: f64) {
	if app.wake_at == 0 || t < app.wake_at do app.wake_at = t
}

app: App

Options :: struct {
	shot:      string, // headless: render N frames and write a PNG here
	width:     int,
	height:    int,
	dpi:       f32,
	theme:     Theme_Name,
	script:    string, // e2e script of injected input (tests/ui/*.txt)
	fixture:   string, // offline: load the store from a recorded gateway fixture
	channel:   string, // open this channel id at start (with fixture)
	live:      f64, // headless: connect for real and run this many seconds before the shot
}

parse_options :: proc() -> Options {
	o := Options{width = 1280, height = 720, dpi = 2, theme = .Dark}
	for a in os.args[1:] {
		switch {
		case strings.has_prefix(a, "-shot:"):
			o.shot = a[len("-shot:"):]
		case strings.has_prefix(a, "-size:"):
			parts := strings.split(a[len("-size:"):], "x", context.temp_allocator)
			if len(parts) == 2 {
				o.width, _ = strconv.parse_int(parts[0])
				o.height, _ = strconv.parse_int(parts[1])
			}
		case strings.has_prefix(a, "-dpi:"):
			v, _ := strconv.parse_f32(a[len("-dpi:"):])
			o.dpi = v
		case strings.has_prefix(a, "-theme:"):
			switch a[len("-theme:"):] {
			case "light":
				o.theme = .Light
			case "ash":
				o.theme = .Ash
			case "onyx":
				o.theme = .Onyx
			}
		case strings.has_prefix(a, "-script:"):
			o.script = a[len("-script:"):]
		case strings.has_prefix(a, "-fixture:"):
			o.fixture = a[len("-fixture:"):]
		case strings.has_prefix(a, "-live:"):
			o.live, _ = strconv.parse_f64(a[len("-live:"):])
		case strings.has_prefix(a, "-channel:"):
			o.channel = a[len("-channel:"):]
		}
	}
	return o
}

main :: proc() {
	opt := parse_options()
	headless := opt.shot != ""
	ok := headless ? platform.init_headless(opt.width, opt.height, opt.dpi) : platform.init("Discord", opt.width, opt.height)
	if !ok {
		fmt.eprintln("platform init failed")
		os.exit(1)
	}
	if !gfx.init() {
		fmt.eprintln("gfx init failed")
		os.exit(1)
	}
	app.stats = os.get_env("FASTCORD_STATS", context.temp_allocator) != ""
	fonts_load()
	theme_load(&app.theme, opt.theme)
	ui.init(&app.ui, ui.Backend{shape = ui_shape})
	view_init(&app.view)
	draw_inline_object = draw_custom_emoji
	app.utc_offset_ms = local_offset_ms()
	dc.store_init(&app.offline_store)
	if opt.fixture != "" {
		if _, fok := dc.store_load_fixture(&app.offline_store, opt.fixture); !fok {
			fmt.eprintln("cannot load fixture", opt.fixture)
			os.exit(1)
		}
		if opt.channel != "" {
			id, _ := strconv.parse_u64(opt.channel)
			if ch := dc.channel_get(&app.offline_store, dc.Snowflake(id)); ch != nil do select_channel(ch.guild_id, ch.id)
		}
	} else if !headless || opt.live > 0 {
		connect()
	}

	if headless && opt.live > 0 {
		// Real time: let the gateway connect and REST land, then capture.
		start := platform.time_now()
		opened := false
		for platform.time_now() - start < opt.live {
			platform.wait_events(1.0 / 60)
			frame()
			if !opened && opt.channel != "" && app.client != nil && app.client.store.ready {
				id, _ := strconv.parse_u64(opt.channel)
				if ch := dc.channel_get(store(), dc.Snowflake(id)); ch != nil do select_channel(ch.guild_id, ch.id)
				opened = true
			}
		}
		run_script(opt.script)
		pixels, w, h := gfx.read_pixels()
		gfx.write_png(opt.shot, pixels, w, h)
		if app.client != nil do dc.client_destroy(app.client)
		return
	}
	if headless {
		platform.set_time_override(0)
		run_script(opt.script)
		// Settle animations, then capture.
		for i in 0 ..< 120 {
			platform.set_time_override(f64(i + 1) / 60)
			platform.wait_events(0)
			frame()
		}
		pixels, w, h := gfx.read_pixels()
		if !gfx.write_png(opt.shot, pixels, w, h) {
			fmt.eprintln("write_png failed")
			os.exit(1)
		}
		return
	}

	platform.set_frame_callback(frame)
	frame()
	for !platform.should_quit() {
		timeout := -1.0
		if app.wake_at > 0 do timeout = max(0, app.wake_at - platform.time_now())
		platform.wait_events(timeout)
		frame()
	}
}

frame :: proc() {
	defer free_all(context.temp_allocator)
	now := platform.time_now()
	dt := f32(now - app.last_time)
	if app.last_time == 0 || dt > 0.1 do dt = 1.0 / 60
	app.last_time = now
	app.frame += 1
	app.wake_at = 0

	if app.client != nil {
		dc.client_poll(app.client)
		handle_results()
	}
	images_receive()
	for e in platform.events() {
		if e.kind == .File_Drop && app.view.channel != 0 do stage_upload(e.text)
	}
	evs := map_events(platform.events())
	for e in evs do app.ui_mods = e.mods
	for e in evs do if e.kind == .Key_Down || e.kind == .Text do app.caret_reset_t = now
	ui.begin(platform.window_size(), dt, now, evs)
	build_ui()
	cmds := ui.end()
	// Cmd+C with a message selection (a focused field with its own selection copied first).
	// Runs after end(): the selection's boxes are collected during layout.
	for &e in app.ui.events {
		if e.consumed || e.kind != .Key_Down || e.key != .C || .Cmd not_in e.mods do continue
		if ui.has_selection() {
			clipboard_set(ui.selection_text())
			e.consumed = true
		}
	}

	gfx.begin_frame(gfx.Color(tok(&app.theme, "--background-base-lowest")))
	render(cmds)
	gfx.end_frame()

	platform.set_cursor(map_cursor(ui.cursor()))
	if ui.needs_frame() do platform.request_frame()
	if app.stats {
		@(static) last_report: f64
		@(static) last_frame: u64
		if now - last_report > 2 {
			fmt.eprintfln("[stats] %.1f fps animating=%v at %v", f64(app.frame - last_frame) / (now - last_report), ui.needs_frame(), app.ui.animating_loc)
			last_report = now
			last_frame = app.frame
		}
	}
}

key_by_name :: proc(name: string) -> platform.Key {
	switch strings.to_lower(name, context.temp_allocator) {
	case "enter":
		return .Enter
	case "escape":
		return .Escape
	case "backspace":
		return .Backspace
	case "delete":
		return .Delete
	case "tab":
		return .Tab
	case "left":
		return .Left
	case "right":
		return .Right
	case "up":
		return .Up
	case "down":
		return .Down
	case "home":
		return .Home
	case "end":
		return .End
	}
	if len(name) == 1 && name[0] >= 'a' && name[0] <= 'z' do return platform.Key(int(platform.Key.A) + int(name[0] - 'a'))
	return .None
}

// Strips surrounding double quotes and turns \n into newlines.
unquote :: proc(s: string) -> string {
	t := s
	if len(t) >= 2 && t[0] == '"' && t[len(t) - 1] == '"' do t = t[1:len(t) - 1]
	out, _ := strings.replace_all(t, "\\n", "\n", context.temp_allocator)
	return out
}

// Scripted input for headless e2e runs: one command per line, e.g.
//   click 120 300 / move 10 10 / type hello / key enter cmd / scroll 0 -100 / wait 30
run_script :: proc(path: string) {
	if path == "" do return
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		fmt.eprintln("cannot read script", path)
		os.exit(1)
	}
	t := 0.0
	for line in strings.split_lines(string(data), context.allocator) {
		f := strings.fields(line, context.temp_allocator)
		if len(f) == 0 || strings.has_prefix(f[0], "#") do continue
		num :: proc(s: string) -> f32 {v, _ := strconv.parse_f32(s); return v}
		switch f[0] {
		case "move":
			platform.inject_event({kind = .Mouse_Move, pos = {num(f[1]), num(f[2])}})
		case "click", "dclick", "tclick":
			n := f[0] == "click" ? 1 : (f[0] == "dclick" ? 2 : 3)
			p := [2]f32{num(f[1]), num(f[2])}
			platform.inject_event({kind = .Mouse_Move, pos = p})
			platform.inject_event({kind = .Mouse_Down, pos = p, button = .Left, click_count = n})
			platform.inject_event({kind = .Mouse_Up, pos = p, button = .Left, click_count = n})
		case "rclick":
			p := [2]f32{num(f[1]), num(f[2])}
			platform.inject_event({kind = .Mouse_Move, pos = p})
			platform.inject_event({kind = .Mouse_Down, pos = p, button = .Right, click_count = 1})
			platform.inject_event({kind = .Mouse_Up, pos = p, button = .Right, click_count = 1})
		case "down":
			platform.inject_event({kind = .Mouse_Down, pos = {num(f[1]), num(f[2])}, button = .Left, click_count = 1})
		case "up":
			platform.inject_event({kind = .Mouse_Up, pos = {num(f[1]), num(f[2])}, button = .Left, click_count = 1})
		case "type":
			platform.inject_event({kind = .Text, text = strings.join(f[1:], " ", context.temp_allocator)})
		case "key":
			// key <name> [shift] [cmd] [alt] [ctrl]
			ev := platform.Event{kind = .Key_Down, key = key_by_name(f[1])}
			for m in f[2:] {
				switch m {
				case "shift":
					ev.mods += {.Shift}
				case "cmd":
					ev.mods += {.Cmd}
				case "alt":
					ev.mods += {.Alt}
				case "ctrl":
					ev.mods += {.Ctrl}
				}
			}
			platform.inject_event(ev)
		case "shot":
			pixels, w, h := gfx.read_pixels(context.temp_allocator)
			gfx.write_png(f[1], pixels, w, h)
			continue
		case "expect_selection":
			want := unquote(strings.join(f[1:], " ", context.temp_allocator))
			got := ui.selection_text()
			if got != want {
				fmt.eprintfln("%s: expect_selection failed\n  want %q\n  got  %q", path, want, got)
				os.exit(1)
			}
			continue
		case "expect_clipboard":
			want := unquote(strings.join(f[1:], " ", context.temp_allocator))
			got := platform.clipboard_get()
			if got != want {
				fmt.eprintfln("%s: expect_clipboard failed\n  want %q\n  got  %q", path, want, got)
				os.exit(1)
			}
			continue
		case "scroll":
			platform.inject_event({kind = .Scroll, delta = {num(f[1]), num(f[2])}, precise = true})
		case "wait":
			n := int(num(f[1]))
			for _ in 0 ..< max(n, 1) {
				t += 1.0 / 60
				platform.set_time_override(t)
				platform.wait_events(0)
				frame()
			}
			continue
		}
		t += 1.0 / 60
		platform.set_time_override(t)
		platform.wait_events(0)
		frame()
	}
}

// Token: $FASTCORD_TOKEN, else <state>/token (written by the login flow).
connect :: proc() {
	home := os.get_env("HOME", context.temp_allocator)
	state_dir := strings.concatenate({home, "/Library/Application Support/fastcord/state"})
	os.make_directory(state_dir)
	token := os.get_env("FASTCORD_TOKEN", context.temp_allocator)
	if token == "" {
		data, err := os.read_entire_file(strings.concatenate({state_dir, "/token"}, context.temp_allocator), context.temp_allocator)
		if err == nil do token = strings.trim_space(string(data))
	}
	if token == "" do return
	app.client = dc.client_create({token = strings.clone(token), state_dir = state_dir, wakeup = proc(_: rawptr) {platform.request_frame()}})
	dc.client_start(app.client)
}

handle_results :: proc() {
	for r in dc.client_take_results(app.client) {
		#partial switch r.op {
		case .Open_Dm:
			if r.ok && r.id != 0 && app.pending_dm_user != 0 {
				select_channel(0, r.id)
				app.pending_dm_user = 0
			}
		}
	}
}

local_offset_ms :: proc() -> i64 {
	return tz_offset_seconds() * 1000
}
