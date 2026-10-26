package app

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "fc:gfx"
import "fc:platform"
import "fc:ui"

App :: struct {
	theme:      Theme,
	ui:         ui.State,
	last_time:  f64,
	frame:      u64,
	view:       View_State,
}

app: App

Options :: struct {
	shot:      string, // headless: render N frames and write a PNG here
	width:     int,
	height:    int,
	dpi:       f32,
	theme:     Theme_Name,
	script:    string, // e2e script of injected input (tests/ui/*.txt)
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
	fonts_load()
	theme_load(&app.theme, opt.theme)
	ui.init(&app.ui, ui.Backend{shape = ui_shape})
	view_init(&app.view)

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
		platform.wait_events(-1)
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

	evs := map_events(platform.events())
	ui.begin(platform.window_size(), dt, now, evs)
	build_ui()
	cmds := ui.end()

	gfx.begin_frame(gfx.Color(tok(&app.theme, "--background-base-lowest")))
	render(cmds)
	gfx.end_frame()

	platform.set_cursor(map_cursor(ui.cursor()))
	if ui.needs_frame() do platform.request_frame()
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
