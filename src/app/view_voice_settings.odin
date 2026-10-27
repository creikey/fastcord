package app

import "core:fmt"
import "core:reflect"
import "core:strconv"
import "fc:audio"
import dc "fc:discord"
import "fc:platform"
import "fc:ui"
import "fc:voice"

// Settings > Voice & Video and the per-user voice context menu.
//
// Defaults follow the official client (MediaEngineStore): input volume 100,
// output volume 100 (0-200 %), input sensitivity automatic (manual threshold
// -60 dB), echo cancellation / noise suppression / AGC on. The mic level
// meter only runs while the page is open, and never in headless runs.

settings_page := "Appearance" // selected page of the settings modal

Voice_Settings :: struct {
	input_volume:  f32, // 0..100
	output_volume: f32, // 0..200
	auto_sens:     bool,
	threshold_db:  f32, // -100..0
	processing:    audio.Voice_Processing,
	user_volume:   map[dc.Snowflake]f32, // 0..200 %
	user_muted:    map[dc.Snowflake]bool,
	// UI state
	open_dropdown: int, // 0 none, 1 input, 2 output
	meter_owner:   bool, // the meter started the capture
	meter_vad:     voice.Vad,
	meter_db:      f32,
	meter_open:    bool,
	menu_user:     dc.Snowflake,
	dd_anchor:     ui.Rect, // open dropdown's rect (popup drawn from overlays)
	menu_pos:      ui.Vec2,
	inited:        bool,
	// input mode (MediaEngineStore: mode VOICE_ACTIVITY | PUSH_TO_TALK, delay 20 ms)
	ptt_mode:      bool,
	ptt_key:       platform.Key, // .None = unbound (the client has no default keybind)
	ptt_delay_ms:  f32,
	ptt_held:      bool,
	recording_key: bool,
}

vs: Voice_Settings

@(private = "file")
vs_init :: proc() {
	if vs.inited do return
	vs.inited = true
	vs.input_volume = 100
	vs.output_volume = 100
	vs.auto_sens = true
	vs.threshold_db = voice.VAD_DEFAULT_THRESHOLD
	vs.processing = audio.Voice_Processing{true, true, true}
	vs.meter_db = -127
	vs.ptt_delay_ms = 20
	voice.vad_init(&vs.meter_vad)
}

// ---- persistence (settings_store.odin) ----

vs_reset_for_test :: proc() {
	delete(vs.user_volume)
	delete(vs.user_muted)
	vs = {}
	vs_init()
}

voice_settings_restore :: proc(p: ^Persisted_Voice) {
	vs_init()
	vs.input_volume = clamp(p.input_volume, 0, 100)
	vs.output_volume = clamp(p.output_volume, 0, 200)
	vs.auto_sens = p.auto_sens
	vs.threshold_db = clamp(p.threshold_db, -100, 0)
	vs.processing = audio.Voice_Processing{p.echo, p.noise, p.agc}
	audio.set_voice_processing(vs.processing)
	vs.ptt_mode = p.mode == "PUSH_TO_TALK"
	if k, ok := reflect.enum_from_name(platform.Key, p.ptt_key); ok do vs.ptt_key = k
	vs.ptt_delay_ms = clamp(f32(p.ptt_delay_ms), 0, 2000)
	if id := device_by_uid(true, p.input_device); id != 0 do audio.select_device(true, id)
	if id := device_by_uid(false, p.output_device); id != 0 do audio.select_device(false, id)
	for k, v in p.user_volume {
		if n, ok := strconv.parse_u64(k); ok do vs.user_volume[dc.Snowflake(n)] = clamp(v, 0, 200)
	}
	for k, v in p.user_muted {
		if n, ok := strconv.parse_u64(k); ok && v do vs.user_muted[dc.Snowflake(n)] = true
	}
}

voice_settings_snapshot :: proc(p: ^Persisted_Voice) {
	vs_init()
	p.input_device = device_uid(true)
	p.output_device = device_uid(false)
	p.input_volume = vs.input_volume
	p.output_volume = vs.output_volume
	p.auto_sens = vs.auto_sens
	p.threshold_db = vs.threshold_db
	p.echo = vs.processing.echo_cancellation
	p.noise = vs.processing.noise_suppression
	p.agc = vs.processing.auto_gain_control
	p.mode = "PUSH_TO_TALK" if vs.ptt_mode else "VOICE_ACTIVITY"
	p.ptt_key, _ = reflect.enum_name_from_value(vs.ptt_key)
	p.ptt_delay_ms = int(vs.ptt_delay_ms)
	p.user_volume = make(map[string]f32, len(vs.user_volume), context.temp_allocator)
	p.user_muted = make(map[string]bool, len(vs.user_muted), context.temp_allocator)
	for k, v in vs.user_volume do if v != 100 do p.user_volume[fmt.tprint(u64(k))] = v
	for k, v in vs.user_muted do if v do p.user_muted[fmt.tprint(u64(k))] = true
}

// push-to-talk key state (focused window only: a global hotkey on macOS
// needs an event tap and the Accessibility permission).
@(private = "file")
ptt_input :: proc() {
	for e in platform.events() {
		#partial switch e.kind {
		case .Key_Down:
			if vs.recording_key {
				if e.key != .Escape && e.key != .None do vs.ptt_key = e.key
				vs.recording_key = false
				continue
			}
			if vs.ptt_key != .None && e.key == vs.ptt_key do vs.ptt_held = true
		case .Key_Up:
			if e.key == vs.ptt_key do vs.ptt_held = false
		case .Focus_Lost:
			vs.ptt_held = false
		}
	}
}

// voice_settings_frame: applies settings to the live connection / devices and
// runs the meter. Called from voice_frame every frame.
voice_settings_frame :: proc(conn: ^voice.Conn, headless: bool, audio_ready: bool) {
	vs_init()
	was_held := vs.ptt_held
	ptt_input()
	if vs.ptt_mode && vs.ptt_held != was_held && conn != nil && !(app.self_mute || app.self_deaf) {
		sound_play("ptt_start" if vs.ptt_held else "ptt_stop")
	}
	if conn != nil {
		voice.set_push_to_talk(conn, vs.ptt_mode, vs.ptt_held, int(vs.ptt_delay_ms))
		voice.set_input_gain(conn, vs.input_volume / 100)
		voice.set_input_sensitivity(conn, vs.auto_sens, vs.threshold_db)
		for uid, v in vs.user_volume do voice.set_user_volume(conn, u64(uid), v / 100)
		for uid, m in vs.user_muted do voice.set_user_mute(conn, u64(uid), m)
	}
	if audio_ready do audio.set_volume(vs.output_volume / 100)

	page_open := app.settings_open && settings_page == "Voice & Video"
	if !page_open || headless {
		if vs.meter_owner && conn == nil do audio.capture_stop()
		vs.meter_owner = false
		return
	}
	if conn != nil {
		// the voice connection owns the mic; read its level
		vs.meter_owner = false
		vs.meter_db, vs.meter_open = voice.input_level(conn)
	} else {
		if !vs.meter_owner {
			if audio.init() && audio.capture_start(true) {
				audio.apply_device_selection()
				vs.meter_owner = true
			}
		}
		if vs.meter_owner {
			buf: [960]f32
			for audio.capture_available() >= 960 {
				audio.capture_read(buf[:])
				g := vs.input_volume / 100
				for &x in buf do x *= g
				vs.meter_vad.auto_threshold = vs.auto_sens
				vs.meter_vad.threshold_db = vs.threshold_db
				vs.meter_open, vs.meter_db = voice.vad_process(&vs.meter_vad, buf[:])
			}
		}
	}
	request_wake(app.last_time + 1.0 / 30)
}

// ---------------------------------------------------------------------------
// Widgets

@(private = "file")
section_title :: proc(text: string) {
	label(text, .Bold, 12, T("--text-muted"), 16)
	spacer(.Y, 8)
}

// slider: horizontal track, returns true while the value changes.
@(private = "file")
slider :: proc(id: string, value: ^f32, lo, hi: f32, w: f32, fmt_value: string = "") -> bool {
	track := ui.box(id, {.Clickable})
	track.semantic_size = {.X = ui.px(w), .Y = ui.px(24)}
	sig := ui.signal(track)
	changed := false
	if sig.pressed || sig.dragging {
		r := track.rect
		if r.x1 > r.x0 {
			t := clamp((app.ui.mouse.x - r.x0) / (r.x1 - r.x0), 0, 1)
			nv := lo + t * (hi - lo)
			if nv != value^ {
				value^ = nv
				changed = true
			}
		}
	}
	t := (value^ - lo) / (hi - lo)
	if ui.parent(track) {
		bar := ui.box("bar", {.Draw_Background, .Floating_X, .Floating_Y})
		bar.semantic_size = {.X = ui.px(w), .Y = ui.px(8)}
		bar.fixed_pos = {0, 8}
		bar.style.bg = T("--background-mod-strong")
		bar.style.radius = 4
		fill := ui.box("fill", {.Draw_Background, .Floating_X, .Floating_Y})
		fill.semantic_size = {.X = ui.px(max(w * t, 1)), .Y = ui.px(8)}
		fill.fixed_pos = {0, 8}
		fill.style.bg = T("--background-brand")
		fill.style.radius = 4
		knob := ui.box("knob", {.Draw_Background, .Draw_Shadow, .Floating_X, .Floating_Y})
		knob.semantic_size = {.X = ui.px(10), .Y = ui.px(24)}
		knob.fixed_pos = {w * t - 5, 0}
		knob.style.bg = {1, 1, 1, 1}
		knob.style.radius = 3
		knob.style.shadow_color = {0, 0, 0, 0.3}
		knob.style.shadow_blur = 4
		if (sig.hovering || sig.dragging) && fmt_value != "" {
			tip := row("tip", {.Draw_Background, .Floating_X, .Floating_Y, .Overlay})
			tip.semantic_size = {.X = ui.children(), .Y = ui.px(26)}
			tip.fixed_pos = {w * t - 24, -32}
			tip.style.bg = T("--background-surface-highest")
			tip.style.radius = 6
			if ui.parent(tip) {
				spacer(.X, 8)
				label(fmt_value, .Semibold, 13, T("--text-strong"), 16)
				spacer(.X, 8)
			}
		}
	}
	return changed
}

toggle_row :: proc(id, text, help: string, value: ^bool) -> bool {
	r := row(id, {.Clickable})
	r.semantic_size = {.X = ui.px(660), .Y = ui.px(help != "" ? 52 : 32)}
	sig := ui.signal(r)
	if ui.parent(r) {
		col := ui.box("col")
		col.semantic_size = {.X = ui.fill(), .Y = ui.children()}
		if ui.parent(col) {
			label(text, .Medium, 16, T("--text-strong"), 20)
			if help != "" do label(help, .Normal, 14, T("--text-muted"), 18)
		}
		sw := ui.box("switch", {.Draw_Background})
		sw.semantic_size = {.X = ui.px(40), .Y = ui.px(24)}
		sw.style.radius = 12
		sw.style.bg = value^ ? T("--status-positive") : T("--background-mod-strong")
		if ui.parent(sw) {
			k := ui.box("k", {.Draw_Background, .Floating_X, .Floating_Y})
			k.semantic_size = {.X = ui.px(18), .Y = ui.px(18)}
			k.fixed_pos = {value^ ? 19 : 3, 3}
			k.style.radius = 9
			k.style.bg = {1, 1, 1, 1}
		}
	}
	if sig.clicked do value^ = !value^
	return sig.clicked
}

@(private = "file")
device_dropdown :: proc(which: int, input: bool, w: f32) {
	devs := vs_list_devices(input)
	sel := audio.selected_device(input)
	current := "Default"
	for d in devs do if sel != 0 && d.id == sel do current = d.name
	box := row(input ? "indev" : "outdev", {.Clickable, .Draw_Background, .Draw_Border})
	box.semantic_size = {.X = ui.px(w), .Y = ui.px(40)}
	box.style.bg = T("--background-base-lowest")
	if tok_has("--input-background") do box.style.bg = T("--input-background")
	box.style.border = 1
	box.style.border_color = T("--border-subtle")
	box.style.radius = 8
	sig := ui.signal(box)
	if sig.clicked do vs.open_dropdown = 0 if vs.open_dropdown == which else which
	if ui.parent(box) {
		spacer(.X, 12)
		t := label(current, .Medium, 16, T("--text-default"), 20)
		t.flags += {.Clip}
		filler(.X)
		icon("chev", vs.open_dropdown == which ? "chevron-small-up" : "chevron-small-down", 20, T("--interactive-icon-default"))
		spacer(.X, 8)
	}
	if vs.open_dropdown == which do vs.dd_anchor = box.rect
}

// popup list under the dropdown (overlay, like the client's select menu)
@(private = "file")
device_list :: proc(devs: []audio.Device_Info, sel: u32, input: bool, w: f32, at: ui.Vec2) {
	list := ui.box(input ? "inlist" : "outlist", {.Draw_Background, .Draw_Border, .Draw_Shadow, .Floating_X, .Floating_Y, .Overlay, .Clickable})
	list.semantic_size = {.X = ui.px(w), .Y = ui.children()}
	list.fixed_pos = at
	list.layout_axis = .Y
	list.style.bg = T("--background-surface-higher")
	list.style.border = 1
	list.style.border_color = T("--border-subtle")
	list.style.radius = 8
	list.style.shadow_color = {0, 0, 0, 0.24}
	list.style.shadow_blur = 16
	list.style.shadow_offset = {0, 8}
	ui.signal(list)
	if ui.parent(list) {
		opt :: proc(name: string, id: u32, input: bool, selected: bool) {
			it := row(name, {.Clickable, .Draw_Background, .Hot_Animation})
			it.semantic_size = {.X = ui.pct(1), .Y = ui.px(36)}
			it.style.bg_hot = T("--background-mod-normal")
			if ui.parent(it) {
				spacer(.X, 12)
				label(name, selected ? .Semibold : .Medium, 15, selected ? T("--text-strong") : T("--text-default"), 20)
			}
			if ui.signal(it).clicked {
				audio.select_device(input, id)
				vs.open_dropdown = 0
			}
		}
		opt("Default", 0, input, sel == 0)
		for d in devs do if ui.id_scope(u64(d.id) + 1) do opt(d.name, d.id, input, d.id == sel)
	}
}

@(private = "file")
tok_has :: proc(name: string) -> bool {
	_, ok := app.theme.tokens[name]
	return ok
}

// ---------------------------------------------------------------------------
// Settings > Voice & Video

voice_settings_page :: proc() {
	vs_init()
	page := ui.box("voicepage", {.Scroll_Y, .Clip})
	page.semantic_size = {.X = ui.pct(1), .Y = ui.fill()}
	page.layout_axis = .Y
	ui.signal(page)
	if ui.parent(page) {
		body := row("vbody")
		body.semantic_size = {.X = ui.pct(1), .Y = ui.children()}
		body.cross_align = .Start
		if ui.parent(body) {
			spacer(.X, 40)
			col := ui.box("vcol")
			col.semantic_size = {.X = ui.px(660), .Y = ui.children()}
			col.layout_axis = .Y
			if ui.parent(col) {
				devices := row("devices")
				devices.semantic_size = {.X = ui.pct(1), .Y = ui.children()}
				devices.cross_align = .Start
				if ui.parent(devices) {
					for input in ([]bool{true, false}) {
						c := ui.box(input ? "inputcol" : "outputcol")
						c.semantic_size = {.X = ui.px(320), .Y = ui.children()}
						c.layout_axis = .Y
						if ui.parent(c) {
							section_title(input ? "INPUT DEVICE" : "OUTPUT DEVICE")
							device_dropdown(1 if input else 2, input, 320)
							spacer(.Y, 20)
							section_title(input ? "INPUT VOLUME" : "OUTPUT VOLUME")
							if input {
								slider("invol", &vs.input_volume, 0, 100, 320, fmt.tprintf("%.0f%%", vs.input_volume))
							} else {
								slider("outvol", &vs.output_volume, 0, 200, 320, fmt.tprintf("%.0f%%", vs.output_volume))
							}
						}
						if input do spacer(.X, 20)
					}
				}
				spacer(.Y, 32)
				section_title("INPUT MODE")
				mode_radio()
				if vs.ptt_mode {
					spacer(.Y, 16)
					keybind_row()
				}
				spacer(.Y, 32)
				section_title("INPUT SENSITIVITY")
				toggle_row("autosens", "Automatically determine input sensitivity", "", &vs.auto_sens)
				spacer(.Y, 12)
				meter_bar()
				if !vs.auto_sens {
					spacer(.Y, 8)
					slider("thresh", &vs.threshold_db, -100, 0, 660, fmt.tprintf("%.0fdB", vs.threshold_db))
				}
				spacer(.Y, 32)
				section_title("VOICE PROCESSING")
				p := vs.processing
				changed := toggle_row("echo", "Echo Cancellation", "", &p.echo_cancellation)
				spacer(.Y, 8)
				changed |= toggle_row("noise", "Noise Suppression", "Suppress background noise from your mic.", &p.noise_suppression)
				spacer(.Y, 8)
				changed |= toggle_row("agc", "Automatic Gain Control", "", &p.auto_gain_control)
				if changed {
					vs.processing = p
					audio.set_voice_processing(p)
				}
				spacer(.Y, 40)
			}
		}
	}
}

@(private = "file")
mode_radio :: proc() {
	for ptt in ([]bool{false, true}) {
		r := row("mode_ptt" if ptt else "mode_va", {.Clickable, .Draw_Background, .Hot_Animation})
		r.semantic_size = {.X = ui.px(660), .Y = ui.px(44)}
		r.style.radius = 4
		r.style.bg = vs.ptt_mode == ptt ? T("--background-mod-normal") : {}
		r.style.bg_hot = T("--background-mod-subtle")
		if ui.signal(r).clicked do vs.ptt_mode = ptt
		if ui.parent(r) {
			spacer(.X, 12)
			dot := ui.box("dot", {.Draw_Border})
			dot.semantic_size = {.X = ui.px(20), .Y = ui.px(20)}
			dot.style.radius = 10
			dot.style.border = 2
			dot.style.border_color = vs.ptt_mode == ptt ? T("--background-brand") : T("--interactive-icon-default")
			if vs.ptt_mode == ptt {
				if ui.parent(dot) {
					in_ := ui.box("in", {.Draw_Background, .Floating_X, .Floating_Y})
					in_.semantic_size = {.X = ui.px(10), .Y = ui.px(10)}
					in_.fixed_pos = {5, 5}
					in_.style.radius = 5
					in_.style.bg = T("--background-brand")
				}
			}
			spacer(.X, 12)
			label("Push to Talk" if ptt else "Voice Activity", .Medium, 16, T("--text-strong"), 20)
		}
		spacer(.Y, 8)
	}
}

@(private = "file")
keybind_row :: proc() {
	r := row("ptt")
	r.semantic_size = {.X = ui.px(660), .Y = ui.children()}
	r.cross_align = .Start
	if ui.parent(r) {
		c := ui.box("kb")
		c.semantic_size = {.X = ui.px(320), .Y = ui.children()}
		c.layout_axis = .Y
		if ui.parent(c) {
			section_title("SHORTCUT")
			b := row("rec", {.Clickable, .Draw_Background, .Draw_Border})
			b.semantic_size = {.X = ui.px(320), .Y = ui.px(40)}
			b.style.radius = 8
			b.style.border = 1
			b.style.border_color = vs.recording_key ? T("--status-danger") : T("--border-subtle")
			b.style.bg = T("--background-base-lowest")
			if ui.signal(b).clicked do vs.recording_key = !vs.recording_key
			if ui.parent(b) {
				spacer(.X, 12)
				name := "No Keybind Set"
				if vs.ptt_key != .None do name, _ = reflect.enum_name_from_value(vs.ptt_key)
				if vs.recording_key do name = "Press a key…"
				label(name, .Medium, 16, T("--text-default"), 20)
				filler(.X)
				label("Stop Recording" if vs.recording_key else "Record Keybind", .Semibold, 14, T("--text-strong"), 18)
				spacer(.X, 12)
			}
			spacer(.Y, 6)
			label("Works while Discord is focused.", .Normal, 12, T("--text-muted"), 16)
		}
		spacer(.X, 20)
		d := ui.box("delay")
		d.semantic_size = {.X = ui.px(320), .Y = ui.children()}
		d.layout_axis = .Y
		if ui.parent(d) {
			section_title("PUSH TO TALK RELEASE DELAY")
			spacer(.Y, 8)
			slider("pttdelay", &vs.ptt_delay_ms, 0, 2000, 320, fmt.tprintf("%.0fms", vs.ptt_delay_ms))
		}
	}
}

// meter_bar: live mic level against the sensitivity threshold (green when the
// gate is open, like the client's input sensitivity meter).
@(private = "file")
meter_bar :: proc() {
	W :: f32(660)
	bar := ui.box("meter", {.Draw_Background})
	bar.semantic_size = {.X = ui.px(W), .Y = ui.px(8)}
	bar.style.bg = T("--background-mod-strong")
	bar.style.radius = 4
	level := clamp((vs.meter_db + 100) / 100, 0, 1)
	if !app.settings_open do level = 0
	if ui.parent(bar) {
		f := ui.box("lvl", {.Draw_Background, .Floating_X, .Floating_Y})
		f.semantic_size = {.X = ui.px(max(W * level, 0.5)), .Y = ui.px(8)}
		f.style.radius = 4
		f.style.bg = T("--text-feedback-warning")
		if vs.meter_open do f.style.bg = T("--status-positive")
		if !vs.auto_sens {
			th := clamp((vs.threshold_db + 100) / 100, 0, 1)
			m := ui.box("th", {.Draw_Background, .Floating_X, .Floating_Y})
			m.semantic_size = {.X = ui.px(2), .Y = ui.px(14)}
			m.fixed_pos = {W * th - 1, -3}
			m.style.bg = T("--text-strong")
		}
	}
}

// ---------------------------------------------------------------------------
// Right-click on a voice participant: volume 0-200 % and mute.

open_voice_user_menu :: proc(uid: dc.Snowflake, at: ui.Vec2) {
	if uid == store().me do return
	vs_init()
	vs.menu_user = uid
	vs.menu_pos = at
}

voice_user_menu :: proc() {
	// device dropdown popup: drawn here so it lands above the settings modal
	if app.settings_open && settings_page == "Voice & Video" && vs.open_dropdown != 0 && vs.dd_anchor.x1 > vs.dd_anchor.x0 {
		input := vs.open_dropdown == 1
		r := vs.dd_anchor
		device_list(vs_list_devices(input), audio.selected_device(input), input, r.x1 - r.x0, {r.x0, r.y1 + 4})
	}
	if vs.menu_user == 0 do return
	uid := vs.menu_user
	scrim := ui.box("vmenu_scrim", {.Clickable, .Floating_X, .Floating_Y, .Overlay})
	scrim.semantic_size = {.X = ui.px(app.ui.window.x), .Y = ui.px(app.ui.window.y)}
	if ui.signal(scrim).pressed {
		vs.menu_user = 0
		return
	}
	W :: f32(220)
	H :: f32(124)
	p := vs.menu_pos
	if p.y + H > app.ui.window.y - 8 do p.y = app.ui.window.y - 8 - H
	if p.x + W > app.ui.window.x - 8 do p.x = app.ui.window.x - 8 - W
	menu := ui.box("vmenu", {.Draw_Background, .Draw_Border, .Draw_Shadow, .Floating_X, .Floating_Y, .Overlay, .Clickable})
	menu.semantic_size = {.X = ui.px(W), .Y = ui.px(H)}
	menu.fixed_pos = p
	menu.layout_axis = .Y
	menu.style.bg = T("--background-surface-higher")
	menu.style.border_color = T("--border-subtle")
	menu.style.border = 1
	menu.style.radius = 8
	menu.style.shadow_color = {0, 0, 0, 0.24}
	menu.style.shadow_blur = 16
	menu.style.shadow_offset = {0, 8}
	ui.signal(menu)
	if ui.parent(menu) {
		spacer(.Y, 8)
		hdr := row("hdr")
		hdr.semantic_size = {.X = ui.pct(1), .Y = ui.px(24)}
		if ui.parent(hdr) {
			spacer(.X, 12)
			label("User Volume", .Medium, 14, T("--interactive-text-default"), 18)
		}
		sr := row("sl")
		sr.semantic_size = {.X = ui.pct(1), .Y = ui.px(32)}
		if ui.parent(sr) {
			spacer(.X, 12)
			v := vs.user_volume[uid] or_else 100
			if slider("uvol", &v, 0, 200, W - 24, fmt.tprintf("%.0f%%", v)) do vs.user_volume[uid] = v
		}
		spacer(.Y, 4)
		sep := ui.box("sep", {.Draw_Background})
		sep.semantic_size = {.X = ui.pct(1), .Y = ui.px(1)}
		sep.style.bg = T("--border-subtle")
		spacer(.Y, 4)
		m := vs.user_muted[uid]
		mr := row("mute", {.Clickable, .Draw_Background, .Hot_Animation})
		mr.semantic_size = {.X = ui.pct(1), .Y = ui.px(32)}
		mr.style.radius = 4
		mr.style.bg_hot = T("--background-mod-normal")
		sig := ui.signal(mr)
		if ui.parent(mr) {
			spacer(.X, 12)
			label("Mute", .Medium, 14, sig.hovering ? T("--interactive-text-active") : T("--interactive-text-default"), 18)
			filler(.X)
			cb := ui.box("cb", {.Draw_Background, .Draw_Border})
			cb.semantic_size = {.X = ui.px(18), .Y = ui.px(18)}
			cb.style.radius = 4
			cb.style.border = m ? 0 : 1.5
			cb.style.border_color = T("--interactive-icon-default")
			cb.style.bg = m ? T("--background-brand") : {}
			if m {
				if ui.parent(cb) do icon("ck", "checkmark-large", 18, {1, 1, 1, 1})
			}
			spacer(.X, 12)
		}
		if sig.clicked do vs.user_muted[uid] = !m
	}
	for e in app.ui.events do if e.kind == .Key_Down && e.key == .Escape do vs.menu_user = 0
}

// Headless runs (UI scripts, the control sweep) list fixed devices instead of
// this machine's, so screenshots and sweep descriptors match everywhere.
vs_list_devices :: proc(input: bool) -> []audio.Device_Info {
	if !platform.is_headless() do return audio.list_devices(input, context.temp_allocator)
	out := make([]audio.Device_Info, 2, context.temp_allocator)
	out[0] = {id = 0, name = "Default", is_default = true}
	out[1] = {id = 1001, name = input ? "Test Microphone" : "Test Speakers", uid = "test"}
	return out
}
