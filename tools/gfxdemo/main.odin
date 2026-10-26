// gfx/platform demo.
//
//	gfxdemo                       windowed; space toggles animation, esc quits
//	gfxdemo -headless:out.png     render one frame offscreen (2x) and write PNG
//	gfxdemo -headless1x:out.png   same at 1x
//	gfxdemo -bench                windowed: 2s animating, 3s idle; prints frame counts, then quits
//	-fonts:<dir>                  load gg sans *.woff2 from dir (else system font)
package gfxdemo

import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "fc:gfx"
import "fc:platform"
import "fc:platform/objc"

_ :: objc

W :: 900
H :: 640

Demo :: struct {
	sans:      [3]gfx.Font_Face, // regular, medium, semibold
	sys:       gfx.Font_Face,
	animating: bool,
	t0:        f64,
	frames:    int,
	frame_times: [dynamic]f64,
	mouse:     [2]f32,
	typed:     [dynamic]u8,
	composition: string,
	last_event: string,
}

d: Demo

load_fonts :: proc(dir: string) {
	d.sys = gfx.font_system("system")
	d.sans = {d.sys, gfx.font_system("system", .Medium), gfx.font_system("system", .Semibold)}
	if dir == "" do return
	files, _ := filepath.glob(strings.concatenate({dir, "/*.woff2"}, context.temp_allocator), context.temp_allocator)
	for f in files {
		face := gfx.font_load_file(f)
		if face == 0 {
			fmt.eprintln("failed to load", f)
			continue
		}
		name := gfx.font_name(face)
		fmt.println("loaded", f, "->", name)
		switch {
		case strings.contains(name, "Semibold") || strings.contains(name, "SemiBold"): d.sans[2] = face
		case strings.contains(name, "Medium"): d.sans[1] = face
		case: d.sans[0] = face
		}
	}
}

main :: proc() {
	headless_out := ""
	headless_dpi: f32 = 2
	bench := false
	selftest := false
	start_idle := false
	font_dir := ""
	for a in os.args[1:] {
		switch {
		case strings.has_prefix(a, "-headless:"):   headless_out = a[len("-headless:"):]
		case strings.has_prefix(a, "-headless1x:"): headless_out = a[len("-headless1x:"):]; headless_dpi = 1
		case strings.has_prefix(a, "-fonts:"):      font_dir = a[len("-fonts:"):]
		case a == "-bench":                         bench = true
		case a == "-selftest":                      selftest = true
		case a == "-idle":                          start_idle = true
		}
	}

	if headless_out != "" {
		if !platform.init_headless(W, H, headless_dpi) do fail("platform.init_headless")
		if !gfx.init() do fail("gfx.init")
		load_fonts(font_dir)
		platform.set_time_override(0.35)
		platform.inject_event({kind = .Text, text = "typed: héllo 👋"})
		platform.wait_events(0)
		handle_events()
		draw()
		// second frame exercises the shape cache
		platform.wait_events(0)
		draw()
		pixels, w, h := gfx.read_pixels()
		if !gfx.write_png(headless_out, pixels, w, h) do fail("write_png")
		st := gfx.stats()
		ts := gfx.text_stats()
		fmt.printfln("wrote %s %dx%d instances=%d draw_calls=%d shape_hits=%d misses=%d glyphs=%d pages=%d",
			headless_out, w, h, st.instances, st.draw_calls, ts.shape_hits, ts.shape_misses, ts.glyphs_rasterized, ts.atlas_pages)
		return
	}

	if !platform.init("gfxdemo", W, H) do fail("platform.init")
	if !gfx.init() do fail("gfx.init")
	load_fonts(font_dir)
	platform.set_frame_callback(frame)
	fmt.printfln("display %.0f Hz, scale %.1f, window id %d", platform.display_refresh_hz(), platform.dpi_scale(), window_number())

	d.animating = !start_idle
	d.t0 = platform.time_now()
	draw()
	if selftest {
		when ODIN_OS == .Darwin do run_selftest()
		return
	}
	if bench {
		// Let the window appear before measuring.
		for i := 0; i < 10; i += 1 {
			platform.request_frame()
			platform.wait_events(-1)
			handle_events()
			draw()
		}
		run_bench()
		return
	}
	for !platform.should_quit() {
		platform.wait_events(-1)
		frame()
	}
}

frame :: proc() {
	defer free_all(context.temp_allocator)
	evs := platform.events()
	handle_events()
	if len(evs) > 0 || d.animating || platform.frame_requested() {
		draw()
	}
}

handle_events :: proc() {
	for e in platform.events() {
		#partial switch e.kind {
		case .Key_Down:
			if e.key == .Escape do platform.request_quit()
			if e.key == .Space && e.mods == {} do d.animating = !d.animating
			if e.key == .Backspace && len(d.typed) > 0 do resize(&d.typed, len(d.typed) - 1)
			if e.key == .V && platform.PRIMARY_MOD in e.mods {
				append(&d.typed, platform.clipboard_get())
			}
			d.last_event = set_last(fmt.tprintf("key %v mods %v repeat %v", e.key, e.mods, e.is_repeat))
		case .Text:
			append(&d.typed, e.text)
		case .Composition:
			delete(d.composition)
			d.composition = strings.clone(e.text)
		case .Mouse_Move:
			d.mouse = e.pos
			platform.set_cursor(e.pos.x > 40 && e.pos.x < 300 && e.pos.y > 560 && e.pos.y < 600 ? .IBeam : .Arrow)
		case .Mouse_Down:
			d.last_event = set_last(fmt.tprintf("mouse %v x%d at %.0f,%.0f", e.button, e.click_count, e.pos.x, e.pos.y))
		case .Scroll:
			d.last_event = set_last(fmt.tprintf("scroll %.1f,%.1f %v momentum=%v", e.delta.x, e.delta.y, e.scroll_phase, e.momentum))
		case .File_Drop:
			d.last_event = set_last(fmt.tprintf("drop %s", e.text))
		}
	}
}

run_bench :: proc() {
	// 2s animating at display rate
	d.animating = true
	start := platform.time_now()
	n0 := gfx.stats().frames
	clear(&d.frame_times)
	for platform.time_now() - start < 2 && !platform.should_quit() {
		platform.request_frame()
		platform.wait_events(-1)
		handle_events()
		draw()
		free_all(context.temp_allocator)
		append(&d.frame_times, platform.time_now())
	}
	anim_frames := gfx.stats().frames - n0
	dts := make([dynamic]f64, context.temp_allocator)
	for i in 1 ..< len(d.frame_times) do append(&dts, (d.frame_times[i] - d.frame_times[i - 1]) * 1000)
	slice.sort(dts[:])
	p50 := len(dts) > 0 ? dts[len(dts) / 2] : 0
	p99 := len(dts) > 0 ? dts[len(dts) * 99 / 100] : 0
	fmt.printfln("animating: %d frames in 2s (%.1f fps), frame dt p50 %.2fms p99 %.2fms", anim_frames, f64(anim_frames) / 2, p50, p99)

	// 3s idle: only redraw on events; nothing should render.
	d.animating = false
	draw()
	n1 := gfx.stats().frames
	wakeups := 0
	idle_start := platform.time_now()
	for platform.time_now() - idle_start < 3 && !platform.should_quit() {
		platform.wait_events(3 - (platform.time_now() - idle_start))
		wakeups += 1
		frame()
	}
	fmt.printfln("idle: %d frames rendered in 3s, %d wait_events returns (1 = the timeout)", gfx.stats().frames - n1, wakeups)
}

window_number :: proc() -> int {
	when ODIN_OS == .Darwin {
		return objc.msg(int, objc.Id(platform.native_window()), "windowNumber")
	} else {
		return 0
	}
}

set_last :: proc(s: string) -> string {
	delete(d.last_event)
	return strings.clone(s)
}

fail :: proc(what: string) -> ! {
	fmt.eprintln("failed:", what)
	os.exit(1)
}

// ---------------------------------------------------------------------------

BG :: 0x313338
CARD :: 0x2b2d31
TEXT :: 0xdbdee1
MUTED :: 0x949ba4
BLURPLE :: 0x5865f2

draw :: proc() {
	gfx.begin_frame(gfx.rgb(BG))
	defer gfx.end_frame()
	t := platform.time_now() - d.t0
	if platform.is_headless() do t = platform.time_now()
	size := platform.window_size()
	reg, med, semi := d.sans[0], d.sans[1], d.sans[2]

	// Sidebar strip with gradient
	gfx.push_rect({dst = {0, 0, 72, size.y}, colors = {gfx.rgb(0x1e1f22), gfx.rgb(0x1e1f22), gfx.rgb(0x111214), gfx.rgb(0x111214)}})
	for i in 0 ..< 6 {
		y := f32(12 + i * 56)
		r: f32 = i == 0 ? 16 : 24
		gfx.rect({12, y, 60, y + 48}, i == 0 ? gfx.rgb(BLURPLE) : gfx.rgb(0x313338), r)
	}

	// Card with drop shadow
	card := gfx.Rect{96, 24, 456, 214}
	gfx.rect_shadow({card.x0, card.y0 + 4, card.x1, card.y1 + 4}, {0, 0, 0, 0.55}, 12, 8)
	gfx.rect(card, gfx.rgb(CARD), 8)
	gfx.rect_border(card, {1, 1, 1, 0.08}, 1, 8)
	gfx.draw_text(semi, 20, "Rounded rects & shadows", {116, 56}, gfx.rgb(0xf2f3f5))
	gfx.draw_text(reg, 16, "Body 16px gg sans: The quick brown fox", {116, 84}, gfx.rgb(TEXT))
	gfx.draw_text(med, 14, "14px medium — jumps over the lazy dog", {116, 106}, gfx.rgb(MUTED))
	gfx.draw_text(semi, 12, "12PX SEMIBOLD LABEL · 0123456789", {116, 126}, gfx.rgb(MUTED))

	// Per-corner radii, borders, gradient pill
	gfx.push_rect({dst = {116, 144, 196, 196}, colors = {gfx.rgb(0xeb459e), gfx.rgb(0xfee75c), gfx.rgb(0x57f287), gfx.rgb(0x5865f2)}, radii = {0, 12, 24, 4}})
	gfx.rect_border({212, 144, 292, 196}, gfx.rgb(0xf2f3f5), 1, 0)
	gfx.rect_border({304, 144, 384, 196}, gfx.rgb(BLURPLE), 2, 10)
	gfx.rect({396, 152, 440, 188}, gfx.rgb(0x23a55a), 18)

	// Text sizes + emoji + fallback
	y: f32 = 250
	for sz in ([]f32{11, 13, 16, 20, 28}) {
		run := gfx.shape(reg, sz, "Hello, fastcord 👋🏽 👨‍👩‍👧 éñü 日本語 한국어")
		gfx.draw_run(run, {96, y}, gfx.rgb(TEXT))
		m := gfx.font_metrics(reg, sz)
		y += m.line_height + 6
	}
	gfx.draw_text(d.sys, 16, "System font (SF Pro) fallback · ✓ ★ → ∑ 🎉", {96, y + 4}, gfx.rgb(TEXT))

	// Clip test: nested clips with overflowing content
	clip := gfx.Rect{480, 24, 860, 214}
	gfx.rect(clip, gfx.rgb(CARD), 8)
	gfx.push_clip({clip.x0 + 10, clip.y0 + 10, clip.x1 - 10, clip.y1 - 10})
	for i in 0 ..< 9 {
		yy := clip.y0 + 34 + f32(i) * 22 - f32(math.mod(t * 20, 22))
		gfx.draw_text(reg, 16, "clipped line of text that runs off the right edge of the box ->", {clip.x0 + 14, yy}, gfx.rgb(TEXT))
	}
	gfx.push_clip({620, 100, 900, 300}) // intersects with parent
	gfx.rect({600, 80, 900, 300}, {0.35, 0.4, 0.95, 0.35})
	gfx.pop_clip()
	gfx.pop_clip()
	gfx.rect_border(clip, {1, 1, 1, 0.1}, 1, 8)

	// Animated element: proves vsync-rate smoothness
	track := gfx.Rect{480, 240, 860, 300}
	gfx.rect(track, gfx.rgb(0x1e1f22), 10)
	phase := f32(0.5 + 0.5 * math.sin(t * 2.4))
	bx := track.x0 + 10 + phase * (track.x1 - track.x0 - 60)
	gfx.rect_shadow({bx, track.y0 + 14, bx + 40, track.y0 + 54}, {0, 0, 0, 0.5}, 6, 20)
	gfx.push_rect({dst = {bx, track.y0 + 10, bx + 40, track.y0 + 50}, colors = {gfx.rgb(0x5865f2), gfx.rgb(0xeb459e), gfx.rgb(0x5865f2), gfx.rgb(0xeb459e)}, radii = 20})
	st := gfx.stats()
	info := fmt.tprintf("%s · %.0f Hz · frame %d · %d inst / %d draws", d.animating ? "animating (space)" : "idle (space)", platform.display_refresh_hz(), st.frames, st.instances, st.draw_calls)
	gfx.draw_text(med, 12, info, {480, 320}, gfx.rgb(MUTED))

	// Thin lines (pixel snapping)
	for i in 0 ..< 8 {
		x := f32(480 + i * 12) + f32(i) * 0.25
		gfx.rect({x, 420, x + 1, 480}, gfx.rgb(TEXT))
	}
	gfx.rect({590, 420, 860, 421}, gfx.rgb(TEXT))
	gfx.rect({590, 430, 860, 430.5}, gfx.rgb(TEXT))
	gfx.rect_border({590, 440, 700, 480}, gfx.rgb(TEXT), 1, 0)
	gfx.rect_border({710, 440, 860, 480}, gfx.rgb(TEXT), 1, 6)

	// Input echo
	gfx.rect({40 + 56, 540, 860, 600}, gfx.rgb(0x383a40), 8)
	typed := string(d.typed[:])
	run := gfx.shape(reg, 16, typed)
	gfx.draw_run(run, {112, 576}, gfx.rgb(TEXT))
	cx := 112 + gfx.run_caret_x(run, len(typed))
	if len(d.composition) > 0 {
		crun := gfx.shape(reg, 16, d.composition)
		gfx.draw_run(crun, {cx, 576}, gfx.rgb(0xfee75c))
		gfx.rect({cx, 580, cx + crun.width, 581}, gfx.rgb(0xfee75c))
		cx += crun.width
	}
	gfx.rect({cx, 560, cx + 1, 582}, gfx.rgb(TEXT))
	platform.set_ime_rect(cx, 560, 1, 22)
	gfx.draw_text(reg, 12, d.last_event, {112, 620}, gfx.rgb(MUTED))

	if d.animating do platform.request_frame()
}

when ODIN_OS == .Darwin {
	// Synthesizes NSEvents and feeds them through the real NSWindow/NSView path
	// (keyDown -> interpretKeyEvents -> NSTextInputClient), then prints what came out.
	run_selftest :: proc() {
		win := objc.Id(platform.native_window())
		wn := objc.msg(int, win, "windowNumber")
		NSPoint :: struct {x, y: f64}
		NSSize :: struct {w, h: f64}
		NSRect :: struct {o: NSPoint, s: NSSize}
		nsstr :: proc(s: cstring) -> objc.Id {
			return objc.msg(objc.Id, objc.cls("NSString"), "stringWithUTF8String:", s)
		}
		key :: proc(win: objc.Id, wn: int, chars, chars_nomod: cstring, code: u16, flags: uint) {
			for type in ([]uint{10, 11}) {
				ev := objc.msg(objc.Id, objc.cls("NSEvent"), "keyEventWithType:location:modifierFlags:timestamp:windowNumber:context:characters:charactersIgnoringModifiers:isARepeat:keyCode:",
					type, NSPoint{}, flags, f64(0), wn, objc.Id(nil), nsstr(chars), nsstr(chars_nomod), false, code)
				objc.msg(objc.Void, win, "sendEvent:", ev)
			}
		}
		CMD :: uint(1 << 20)
		ALT :: uint(1 << 19)
		key(win, wn, "a", "a", 0x00, 0)
		key(win, wn, "A", "a", 0x00, 1 << 17)
		key(win, wn, "v", "v", 0x09, CMD)
		key(win, wn, "\uf702", "\uf702", 0x7B, ALT | (1 << 23))
		key(win, wn, "\r", "\r", 0x24, 0)
		key(win, wn, "\x7f", "\x7f", 0x33, 0)
		key(win, wn, "é", "é", 0x0E, 0)
		// IME path directly through NSTextInputClient
		view := objc.Id(platform.native_view())
		Range :: struct {loc, len: uint}
		objc.msg(objc.Void, view, "setMarkedText:selectedRange:replacementRange:", nsstr("にほ"), Range{2, 0}, Range{max(uint) >> 1, 0})
		objc.msg(objc.Void, view, "insertText:replacementRange:", nsstr("日本"), Range{max(uint) >> 1, 0})
		// double click
		for type in ([]uint{1, 2}) {
			ev := objc.msg(objc.Id, objc.cls("NSEvent"), "mouseEventWithType:location:modifierFlags:timestamp:windowNumber:context:eventNumber:clickCount:pressure:",
				type, NSPoint{100, 100}, uint(0), f64(0), wn, objc.Id(nil), int(0), int(2), f32(1))
			objc.msg(objc.Void, win, "sendEvent:", ev)
		}
		// programmatic resize
		objc.msg(objc.Void, win, "setContentSize:", NSSize{1000, 700})

		platform.wait_events(0)
		for e in platform.events() {
			#partial switch e.kind {
			case .Key_Down, .Key_Up: fmt.printfln("%v key=%v mods=%v", e.kind, e.key, e.mods)
			case .Text, .Composition: fmt.printfln("%v %q sel=%v", e.kind, e.text, e.composition_sel)
			case .Mouse_Down, .Mouse_Up: fmt.printfln("%v %v clicks=%d pos=%v", e.kind, e.button, e.click_count, e.pos)
			case .Resize: fmt.printfln("Resize size=%v scale=%v", platform.window_size(), platform.dpi_scale())
			case: fmt.printfln("%v", e.kind)
			}
		}
		draw()
		// Live-resize present path (presentsWithTransaction) must not stall.
		layer := objc.Id(platform.native_metal_layer())
		objc.msg(objc.Void, layer, "setPresentsWithTransaction:", true)
		t0 := platform.time_now()
		for _ in 0 ..< 5 do draw()
		objc.msg(objc.Void, layer, "setPresentsWithTransaction:", false)
		fmt.printfln("presentsWithTransaction: 5 frames in %.1fms", (platform.time_now() - t0) * 1000)
		fmt.println("frames:", gfx.stats().frames)
	}
}
