// Settings > Voice & Video and the per-user voice context menu.
//
// Defaults follow the official client (MediaEngineStore): input volume 100,
// output volume 100 (0-200 %), input sensitivity automatic (manual threshold
// -60 dB), echo cancellation / noise suppression / AGC on. The mic level
// meter only runs while the page is open, and never in headless runs.

settings_page := "Appearance"; // selected page of the settings modal

Voice_Settings :: struct {
	input_volume: float32; // 0..100
	output_volume: float32; // 0..200
	auto_sens: bool;
	threshold_db: float32; // -100..0
	processing: audio.Voice_Processing;
	user_volume: Map(dc.Snowflake, float32); // 0..200 %
	user_muted: Map(dc.Snowflake, bool);
	// UI state
	open_dropdown: int; // 0 none, 1 input, 2 output
	meter_owner: bool; // the meter started the capture
	meter_vad: voice.Vad;
	meter_db: float32;
	meter_open: bool;
	menu_user: dc.Snowflake;
	dd_anchor: ui.Rect; // open dropdown's rect (popup drawn from overlays)
	menu_pos: ui.Vec2;
	inited: bool;
	// input mode (MediaEngineStore: mode VOICE_ACTIVITY | PUSH_TO_TALK, delay 20 ms)
	ptt_mode: bool;
	ptt_key: platform.Key; // .None = unbound (the client has no default keybind)
	ptt_delay_ms: float32;
	ptt_held: bool;
	recording_key: bool;
}

vs: Voice_Settings;
#scope_file

vs_init :: () {
	if vs.inited { return; }
	vs.inited = true;
	vs.input_volume = 100;
	vs.output_volume = 100;
	vs.auto_sens = true;
	vs.threshold_db = voice.VAD_DEFAULT_THRESHOLD;
	vs.processing = audio.Voice_Processing.{true, true, true};
	vs.meter_db = -127;
	vs.ptt_delay_ms = 20;
	voice.vad_init(*vs.meter_vad);
}
#scope_export

// ---- persistence (settings_store.odin) ----

vs_reset_for_test :: () {
	delete(vs.user_volume);
	delete(vs.user_muted);
	vs = .{};
	vs_init();
}

voice_settings_restore :: (p: *Persisted_Voice) {
	vs_init();
	vs.input_volume = clamp(p.input_volume, 0, 100);
	vs.output_volume = clamp(p.output_volume, 0, 200);
	vs.auto_sens = p.auto_sens;
	vs.threshold_db = clamp(p.threshold_db, -100, 0);
	vs.processing = audio.Voice_Processing.{p.echo, p.noise, p.agc};
	audio.set_voice_processing(vs.processing);
	vs.ptt_mode = p.mode == "PUSH_TO_TALK";
	{ k, ok := reflect.enum_from_name(platform.Key, p.ptt_key);
	if ok { vs.ptt_key = k; } }
	vs.ptt_delay_ms = clamp(cast(float32)(p.ptt_delay_ms), 0, 2000);
	{ id := device_by_uid(true, p.input_device);
	if id != 0 { audio.select_device(true, id); } }
	{ id := device_by_uid(false, p.output_device);
	if id != 0 { audio.select_device(false, id); } }
	for k, v: p.user_volume {
		{ n, ok := strconv.parse_u64(k);
		if ok { at(*vs.user_volume, cast(dc.Snowflake)(n)).* = clamp(v, 0, 200); } }
	}
	for k, v: p.user_muted {
		{ n, ok := strconv.parse_u64(k);
		if ok && v { at(*vs.user_muted, cast(dc.Snowflake)(n)).* = true; } }
	}
}

voice_settings_snapshot :: (p: *Persisted_Voice) {
	vs_init();
	p.input_device = device_uid(true);
	p.output_device = device_uid(false);
	p.input_volume = vs.input_volume;
	p.output_volume = vs.output_volume;
	p.auto_sens = vs.auto_sens;
	p.threshold_db = vs.threshold_db;
	p.echo = vs.processing.echo_cancellation;
	p.noise = vs.processing.noise_suppression;
	p.agc = vs.processing.auto_gain_control;
	p.mode = ifx vs.ptt_mode then "PUSH_TO_TALK" else "VOICE_ACTIVITY";
	p.ptt_key, _ = reflect.enum_name_from_value(vs.ptt_key);
	p.ptt_delay_ms = cast(int)(vs.ptt_delay_ms);
	p.user_volume = Map(string, float32).{};
	p.user_muted = Map(string, bool).{};
	for k, v: vs.user_volume { if v != 100 { at(*p.user_volume, fmt.tprint(cast(u64)(k))).* = v; } }
	for k, v: vs.user_muted { if v { at(*p.user_muted, fmt.tprint(cast(u64)(k))).* = true; } }
}
#scope_file

// push-to-talk key state (focused window only: a global hotkey on macOS
// needs an event tap and the Accessibility permission).
ptt_input :: () {
	for e: platform.events() {
		if e.kind == {
		case .Key_Down;
			if vs.recording_key {
				if e.key != .Escape && e.key != .None { vs.ptt_key = e.key; }
				vs.recording_key = false;
				continue;
			}
			if vs.ptt_key != .None && e.key == vs.ptt_key { vs.ptt_held = true; }
		case .Key_Up;
			if e.key == vs.ptt_key { vs.ptt_held = false; }
		case .Focus_Lost;
			vs.ptt_held = false;
		}
	}
}
#scope_export

// voice_settings_frame: applies settings to the live connection / devices and
// runs the meter. Called from voice_frame every frame.
voice_settings_frame :: (conn: *voice.Conn, headless: bool, audio_ready: bool) {
	vs_init();
	was_held := vs.ptt_held;
	ptt_input();
	if vs.ptt_mode && vs.ptt_held != was_held && conn != null && !(app.self_mute || app.self_deaf) {
		sound_play(ifx vs.ptt_held then "ptt_start" else "ptt_stop");
	}
	if conn != null {
		voice.set_push_to_talk(conn, vs.ptt_mode, vs.ptt_held, cast(int)(vs.ptt_delay_ms));
		voice.set_input_gain(conn, vs.input_volume / 100);
		voice.set_input_sensitivity(conn, vs.auto_sens, vs.threshold_db);
		for uid, v: vs.user_volume { voice.set_user_volume(conn, cast(u64)(uid), v / 100); }
		for uid, m: vs.user_muted { voice.set_user_mute(conn, cast(u64)(uid), m); }
	}
	if audio_ready { audio.set_volume(vs.output_volume / 100); }

	page_open := app.settings_open && settings_page == "Voice & Video";
	if !page_open || headless {
		if vs.meter_owner && conn == null { audio.capture_stop(); }
		vs.meter_owner = false;
		return;
	}
	if conn != null {
		// the voice connection owns the mic; read its level
		vs.meter_owner = false;
		vs.meter_db, vs.meter_open = voice.input_level(conn);
	} else {
		if !vs.meter_owner {
			if audio.init() && audio.capture_start(true) {
				audio.apply_device_selection();
				vs.meter_owner = true;
			}
		}
		if vs.meter_owner {
			buf: [960]float32;
			while audio.capture_available() >= 960 {
				audio.capture_read(view(buf));
				g := vs.input_volume / 100;
				for * x: buf { x *= g; }
				vs.meter_vad.auto_threshold = vs.auto_sens;
				vs.meter_vad.threshold_db = vs.threshold_db;
				vs.meter_open, vs.meter_db = voice.vad_process(*vs.meter_vad, view(buf));
			}
		}
	}
	request_wake(app.last_time + 1.0 / 30);
}
#scope_file

// ---------------------------------------------------------------------------
// Widgets

section_title :: (text: string) {
	label(text, .Bold, 12, cast(T)("--text-muted"), 16);
	spacer(.Y, 8);
}

// slider: horizontal track, returns true while the value changes.
slider :: (id: string, value: *float32, lo: float32, hi: float32, w: float32, fmt_value: string = "") -> bool {
	track := ui.box(id, .{.Clickable});
	track.semantic_size = .{__IDX__.X = ui.px(w), __IDX__.Y = ui.px(24)};
	sig := ui.signal(track);
	changed := false;
	if sig.pressed || sig.dragging {
		r := track.rect;
		if r.x1 > r.x0 {
			t := clamp((app.ui.mouse.x - r.x0) / (r.x1 - r.x0), 0, 1);
			nv := lo + t * (hi - lo);
			if nv != value.* {
				value.* = nv;
				changed = true;
			}
		}
	}
	t := (value.* - lo) / (hi - lo);
	if ui.parent(track) {
		bar := ui.box("bar", .{.Draw_Background, .Floating_X, .Floating_Y});
		bar.semantic_size = .{__IDX__.X = ui.px(w), __IDX__.Y = ui.px(8)};
		bar.fixed_pos = .{0, 8};
		bar.style.bg = cast(T)("--background-mod-strong");
		bar.style.radius = 4;
		fill := ui.box("fill", .{.Draw_Background, .Floating_X, .Floating_Y});
		fill.semantic_size = .{__IDX__.X = ui.px(max(w * t, 1)), __IDX__.Y = ui.px(8)};
		fill.fixed_pos = .{0, 8};
		fill.style.bg = cast(T)("--background-brand");
		fill.style.radius = 4;
		knob := ui.box("knob", .{.Draw_Background, .Draw_Shadow, .Floating_X, .Floating_Y});
		knob.semantic_size = .{__IDX__.X = ui.px(10), __IDX__.Y = ui.px(24)};
		knob.fixed_pos = .{w * t - 5, 0};
		knob.style.bg = .{1, 1, 1, 1};
		knob.style.radius = 3;
		knob.style.shadow_color = .{0, 0, 0, 0.3};
		knob.style.shadow_blur = 4;
		if (sig.hovering || sig.dragging) && fmt_value != "" {
			tip := row("tip", .{.Draw_Background, .Floating_X, .Floating_Y, .Overlay});
			tip.semantic_size = .{__IDX__.X = ui.children(), __IDX__.Y = ui.px(26)};
			tip.fixed_pos = .{w * t - 24, -32};
			tip.style.bg = cast(T)("--background-surface-highest");
			tip.style.radius = 6;
			if ui.parent(tip) {
				spacer(.X, 8);
				label(fmt_value, .Semibold, 13, cast(T)("--text-strong"), 16);
				spacer(.X, 8);
			}
		}
	}
	return changed;
}
#scope_export

toggle_row :: (id: string, text: string, help: string, value: *bool) -> bool {
	r := row(id, .{.Clickable});
	r.semantic_size = .{__IDX__.X = ui.px(660), __IDX__.Y = ui.px(ifx help != "" then 52 else 32)};
	sig := ui.signal(r);
	if ui.parent(r) {
		col := ui.box("col");
		col.semantic_size = .{__IDX__.X = ui.fill(), __IDX__.Y = ui.children()};
		if ui.parent(col) {
			label(text, .Medium, 16, cast(T)("--text-strong"), 20);
			if help != "" { label(help, .Normal, 14, cast(T)("--text-muted"), 18); }
		}
		sw := ui.box("switch", .{.Draw_Background});
		sw.semantic_size = .{__IDX__.X = ui.px(40), __IDX__.Y = ui.px(24)};
		sw.style.radius = 12;
		sw.style.bg = ifx value.* then cast(T)("--status-positive") else cast(T)("--background-mod-strong");
		if ui.parent(sw) {
			k := ui.box("k", .{.Draw_Background, .Floating_X, .Floating_Y});
			k.semantic_size = .{__IDX__.X = ui.px(18), __IDX__.Y = ui.px(18)};
			k.fixed_pos = .{ifx value.* then 19 else 3, 3};
			k.style.radius = 9;
			k.style.bg = .{1, 1, 1, 1};
		}
	}
	if sig.clicked { value.* = !value.*; }
	return sig.clicked;
}
#scope_file

device_dropdown :: (which: int, input: bool, w: float32) {
	devs := vs_list_devices(input);
	sel := audio.selected_device(input);
	current := "Default";
	for d: devs { if sel != 0 && d.id == sel { current = d.name; } }
	box := row(ifx input then "indev" else "outdev", .{.Clickable, .Draw_Background, .Draw_Border});
	box.semantic_size = .{__IDX__.X = ui.px(w), __IDX__.Y = ui.px(40)};
	box.style.bg = cast(T)("--background-base-lowest");
	if tok_has("--input-background") { box.style.bg = cast(T)("--input-background"); }
	box.style.border = 1;
	box.style.border_color = cast(T)("--border-subtle");
	box.style.radius = 8;
	sig := ui.signal(box);
	if sig.clicked { vs.open_dropdown = ifx vs.open_dropdown == which then 0 else which; }
	if ui.parent(box) {
		spacer(.X, 12);
		t := label(current, .Medium, 16, cast(T)("--text-default"), 20);
		t.flags += .{.Clip};
		filler(.X);
		icon("chev", ifx vs.open_dropdown == which then "chevron-small-up" else "chevron-small-down", 20, cast(T)("--interactive-icon-default"));
		spacer(.X, 8);
	}
	if vs.open_dropdown == which { vs.dd_anchor = box.rect; }
}

// popup list under the dropdown (overlay, like the client's select menu)
device_list :: (devs: []audio.Device_Info, sel: u32, input: bool, w: float32, at: ui.Vec2) {
	list := ui.box(ifx input then "inlist" else "outlist", .{.Draw_Background, .Draw_Border, .Draw_Shadow, .Floating_X, .Floating_Y, .Overlay, .Clickable});
	list.semantic_size = .{__IDX__.X = ui.px(w), __IDX__.Y = ui.children()};
	list.fixed_pos = at;
	list.layout_axis = .Y;
	list.style.bg = cast(T)("--background-surface-higher");
	list.style.border = 1;
	list.style.border_color = cast(T)("--border-subtle");
	list.style.radius = 8;
	list.style.shadow_color = .{0, 0, 0, 0.24};
	list.style.shadow_blur = 16;
	list.style.shadow_offset = .{0, 8};
	ui.signal(list);
	if ui.parent(list) {
		opt :: (name: string, id: u32, input: bool, selected: bool) {
			it_ := row(name, .{.Clickable, .Draw_Background, .Hot_Animation});
			it_.semantic_size = .{__IDX__.X = ui.pct(1), __IDX__.Y = ui.px(36)};
			it_.style.bg_hot = cast(T)("--background-mod-normal");
			if ui.parent(it_) {
				spacer(.X, 12);
				label(name, ifx selected then .Semibold else .Medium, 15, ifx selected then cast(T)("--text-strong") else cast(T)("--text-default"), 20);
			}
			if ui.signal(it_).clicked {
				audio.select_device(input, id);
				vs.open_dropdown = 0;
			}
		}
		opt("Default", 0, input, sel == 0);
		for d: devs { if ui.id_scope(cast(u64)(d.id) + 1) { opt(d.name, d.id, input, d.id == sel); } }
	}
}

tok_has :: (name: string) -> bool {
	_, ok := map_find(app.theme.tokens, name);
	return ok;
}
#scope_export

// ---------------------------------------------------------------------------
// Settings > Voice & Video

voice_settings_page :: () {
	vs_init();
	page := ui.box("voicepage", .{.Scroll_Y, .Clip});
	page.semantic_size = .{__IDX__.X = ui.pct(1), __IDX__.Y = ui.fill()};
	page.layout_axis = .Y;
	ui.signal(page);
	if ui.parent(page) {
		body := row("vbody");
		body.semantic_size = .{__IDX__.X = ui.pct(1), __IDX__.Y = ui.children()};
		body.cross_align = .Start;
		if ui.parent(body) {
			spacer(.X, 40);
			col := ui.box("vcol");
			col.semantic_size = .{__IDX__.X = ui.px(660), __IDX__.Y = ui.children()};
			col.layout_axis = .Y;
			if ui.parent(col) {
				devices := row("devices");
				devices.semantic_size = .{__IDX__.X = ui.pct(1), __IDX__.Y = ui.children()};
				devices.cross_align = .Start;
				if ui.parent(devices) {
					for input: (bool.[true, false]) {
						c := ui.box(ifx input then "inputcol" else "outputcol");
						c.semantic_size = .{__IDX__.X = ui.px(320), __IDX__.Y = ui.children()};
						c.layout_axis = .Y;
						if ui.parent(c) {
							section_title(ifx input then "INPUT DEVICE" else "OUTPUT DEVICE");
							device_dropdown(ifx input then 1 else 2, input, 320);
							spacer(.Y, 20);
							section_title(ifx input then "INPUT VOLUME" else "OUTPUT VOLUME");
							if input {
								slider("invol", *vs.input_volume, 0, 100, 320, fmt.tprintf("%.0f%%", vs.input_volume));
							} else {
								slider("outvol", *vs.output_volume, 0, 200, 320, fmt.tprintf("%.0f%%", vs.output_volume));
							}
						}
						if input { spacer(.X, 20); }
					}
				}
				spacer(.Y, 32);
				section_title("INPUT MODE");
				mode_radio();
				if vs.ptt_mode {
					spacer(.Y, 16);
					keybind_row();
				}
				spacer(.Y, 32);
				section_title("INPUT SENSITIVITY");
				toggle_row("autosens", "Automatically determine input sensitivity", "", *vs.auto_sens);
				spacer(.Y, 12);
				meter_bar();
				if !vs.auto_sens {
					spacer(.Y, 8);
					slider("thresh", *vs.threshold_db, -100, 0, 660, fmt.tprintf("%.0fdB", vs.threshold_db));
				}
				spacer(.Y, 32);
				section_title("VOICE PROCESSING");
				p := vs.processing;
				changed := toggle_row("echo", "Echo Cancellation", "", *p.echo_cancellation);
				spacer(.Y, 8);
				changed |= toggle_row("noise", "Noise Suppression", "Suppress background noise from your mic.", *p.noise_suppression);
				spacer(.Y, 8);
				changed |= toggle_row("agc", "Automatic Gain Control", "", *p.auto_gain_control);
				if changed {
					vs.processing = p;
					audio.set_voice_processing(p);
				}
				spacer(.Y, 40);
			}
		}
	}
}
#scope_file

mode_radio :: () {
	for ptt: (bool.[false, true]) {
		r := row(ifx ptt then "mode_ptt" else "mode_va", .{.Clickable, .Draw_Background, .Hot_Animation});
		r.semantic_size = .{__IDX__.X = ui.px(660), __IDX__.Y = ui.px(44)};
		r.style.radius = 4;
		r.style.bg = ifx vs.ptt_mode == ptt then cast(T)("--background-mod-normal") else .{};
		r.style.bg_hot = cast(T)("--background-mod-subtle");
		if ui.signal(r).clicked { vs.ptt_mode = ptt; }
		if ui.parent(r) {
			spacer(.X, 12);
			dot := ui.box("dot", .{.Draw_Border});
			dot.semantic_size = .{__IDX__.X = ui.px(20), __IDX__.Y = ui.px(20)};
			dot.style.radius = 10;
			dot.style.border = 2;
			dot.style.border_color = ifx vs.ptt_mode == ptt then cast(T)("--background-brand") else cast(T)("--interactive-icon-default");
			if vs.ptt_mode == ptt {
				if ui.parent(dot) {
					in_ := ui.box("in", .{.Draw_Background, .Floating_X, .Floating_Y});
					in_.semantic_size = .{__IDX__.X = ui.px(10), __IDX__.Y = ui.px(10)};
					in_.fixed_pos = .{5, 5};
					in_.style.radius = 5;
					in_.style.bg = cast(T)("--background-brand");
				}
			}
			spacer(.X, 12);
			label(ifx ptt then "Push to Talk" else "Voice Activity", .Medium, 16, cast(T)("--text-strong"), 20);
		}
		spacer(.Y, 8);
	}
}

keybind_row :: () {
	r := row("ptt");
	r.semantic_size = .{__IDX__.X = ui.px(660), __IDX__.Y = ui.children()};
	r.cross_align = .Start;
	if ui.parent(r) {
		c := ui.box("kb");
		c.semantic_size = .{__IDX__.X = ui.px(320), __IDX__.Y = ui.children()};
		c.layout_axis = .Y;
		if ui.parent(c) {
			section_title("SHORTCUT");
			b := row("rec", .{.Clickable, .Draw_Background, .Draw_Border});
			b.semantic_size = .{__IDX__.X = ui.px(320), __IDX__.Y = ui.px(40)};
			b.style.radius = 8;
			b.style.border = 1;
			b.style.border_color = ifx vs.recording_key then cast(T)("--status-danger") else cast(T)("--border-subtle");
			b.style.bg = cast(T)("--background-base-lowest");
			if ui.signal(b).clicked { vs.recording_key = !vs.recording_key; }
			if ui.parent(b) {
				spacer(.X, 12);
				name := "No Keybind Set";
				if vs.ptt_key != .None { name, _ = reflect.enum_name_from_value(vs.ptt_key); }
				if vs.recording_key { name = "Press a key…"; }
				label(name, .Medium, 16, cast(T)("--text-default"), 20);
				filler(.X);
				label(ifx vs.recording_key then "Stop Recording" else "Record Keybind", .Semibold, 14, cast(T)("--text-strong"), 18);
				spacer(.X, 12);
			}
			spacer(.Y, 6);
			label("Works while Discord is focused.", .Normal, 12, cast(T)("--text-muted"), 16);
		}
		spacer(.X, 20);
		d := ui.box("delay");
		d.semantic_size = .{__IDX__.X = ui.px(320), __IDX__.Y = ui.children()};
		d.layout_axis = .Y;
		if ui.parent(d) {
			section_title("PUSH TO TALK RELEASE DELAY");
			spacer(.Y, 8);
			slider("pttdelay", *vs.ptt_delay_ms, 0, 2000, 320, fmt.tprintf("%.0fms", vs.ptt_delay_ms));
		}
	}
}

// meter_bar: live mic level against the sensitivity threshold (green when the
// gate is open, like the client's input sensitivity meter).
meter_bar :: () {
	W :: cast(float32)(660);
	bar := ui.box("meter", .{.Draw_Background});
	bar.semantic_size = .{__IDX__.X = ui.px(W), __IDX__.Y = ui.px(8)};
	bar.style.bg = cast(T)("--background-mod-strong");
	bar.style.radius = 4;
	level := clamp((vs.meter_db + 100) / 100, 0, 1);
	if !app.settings_open { level = 0; }
	if ui.parent(bar) {
		f := ui.box("lvl", .{.Draw_Background, .Floating_X, .Floating_Y});
		f.semantic_size = .{__IDX__.X = ui.px(max(W * level, 0.5)), __IDX__.Y = ui.px(8)};
		f.style.radius = 4;
		f.style.bg = cast(T)("--text-feedback-warning");
		if vs.meter_open { f.style.bg = cast(T)("--status-positive"); }
		if !vs.auto_sens {
			th := clamp((vs.threshold_db + 100) / 100, 0, 1);
			m := ui.box("th", .{.Draw_Background, .Floating_X, .Floating_Y});
			m.semantic_size = .{__IDX__.X = ui.px(2), __IDX__.Y = ui.px(14)};
			m.fixed_pos = .{W * th - 1, -3};
			m.style.bg = cast(T)("--text-strong");
		}
	}
}
#scope_export

// ---------------------------------------------------------------------------
// Right-click on a voice participant: volume 0-200 % and mute.

open_voice_user_menu :: (uid: dc.Snowflake, at: ui.Vec2) {
	if uid == store().me { return; }
	vs_init();
	vs.menu_user = uid;
	vs.menu_pos = at;
}

voice_user_menu :: () {
	// device dropdown popup: drawn here so it lands above the settings modal
	if app.settings_open && settings_page == "Voice & Video" && vs.open_dropdown != 0 && vs.dd_anchor.x1 > vs.dd_anchor.x0 {
		input := vs.open_dropdown == 1;
		r := vs.dd_anchor;
		device_list(vs_list_devices(input), audio.selected_device(input), input, r.x1 - r.x0, .{r.x0, r.y1 + 4});
	}
	if vs.menu_user == 0 { return; }
	uid := vs.menu_user;
	scrim := ui.box("vmenu_scrim", .{.Clickable, .Floating_X, .Floating_Y, .Overlay});
	scrim.semantic_size = .{__IDX__.X = ui.px(app.ui.window.x), __IDX__.Y = ui.px(app.ui.window.y)};
	if ui.signal(scrim).pressed {
		vs.menu_user = 0;
		return;
	}
	W :: cast(float32)(220);
	H :: cast(float32)(124);
	p := vs.menu_pos;
	if p.y + H > app.ui.window.y - 8 { p.y = app.ui.window.y - 8 - H; }
	if p.x + W > app.ui.window.x - 8 { p.x = app.ui.window.x - 8 - W; }
	menu := ui.box("vmenu", .{.Draw_Background, .Draw_Border, .Draw_Shadow, .Floating_X, .Floating_Y, .Overlay, .Clickable});
	menu.semantic_size = .{__IDX__.X = ui.px(W), __IDX__.Y = ui.px(H)};
	menu.fixed_pos = p;
	menu.layout_axis = .Y;
	menu.style.bg = cast(T)("--background-surface-higher");
	menu.style.border_color = cast(T)("--border-subtle");
	menu.style.border = 1;
	menu.style.radius = 8;
	menu.style.shadow_color = .{0, 0, 0, 0.24};
	menu.style.shadow_blur = 16;
	menu.style.shadow_offset = .{0, 8};
	ui.signal(menu);
	if ui.parent(menu) {
		spacer(.Y, 8);
		hdr := row("hdr");
		hdr.semantic_size = .{__IDX__.X = ui.pct(1), __IDX__.Y = ui.px(24)};
		if ui.parent(hdr) {
			spacer(.X, 12);
			label("User Volume", .Medium, 14, cast(T)("--interactive-text-default"), 18);
		}
		sr := row("sl");
		sr.semantic_size = .{__IDX__.X = ui.pct(1), __IDX__.Y = ui.px(32)};
		if ui.parent(sr) {
			spacer(.X, 12);
			v := or_else(get(vs.user_volume, uid), 100);
			if slider("uvol", *v, 0, 200, W - 24, fmt.tprintf("%.0f%%", v)) { at(*vs.user_volume, uid).* = v; }
		}
		spacer(.Y, 4);
		sep := ui.box("sep", .{.Draw_Background});
		sep.semantic_size = .{__IDX__.X = ui.pct(1), __IDX__.Y = ui.px(1)};
		sep.style.bg = cast(T)("--border-subtle");
		spacer(.Y, 4);
		m := get(vs.user_muted, uid);
		mr := row("mute", .{.Clickable, .Draw_Background, .Hot_Animation});
		mr.semantic_size = .{__IDX__.X = ui.pct(1), __IDX__.Y = ui.px(32)};
		mr.style.radius = 4;
		mr.style.bg_hot = cast(T)("--background-mod-normal");
		sig := ui.signal(mr);
		if ui.parent(mr) {
			spacer(.X, 12);
			label("Mute", .Medium, 14, ifx sig.hovering then cast(T)("--interactive-text-active") else cast(T)("--interactive-text-default"), 18);
			filler(.X);
			cb := ui.box("cb", .{.Draw_Background, .Draw_Border});
			cb.semantic_size = .{__IDX__.X = ui.px(18), __IDX__.Y = ui.px(18)};
			cb.style.radius = 4;
			cb.style.border = ifx m then 0 else 1.5;
			cb.style.border_color = cast(T)("--interactive-icon-default");
			cb.style.bg = ifx m then cast(T)("--background-brand") else .{};
			if m {
				if ui.parent(cb) { icon("ck", "checkmark-large", 18, .{1, 1, 1, 1}); }
			}
			spacer(.X, 12);
		}
		if sig.clicked { at(*vs.user_muted, uid).* = !m; }
	}
	for e: app.ui.events { if e.kind == .Key_Down && e.key == .Escape { vs.menu_user = 0; } }
}

// Headless runs (UI scripts, the control sweep) list fixed devices instead of
// this machine's, so screenshots and sweep descriptors match everywhere.
vs_list_devices :: (input: bool) -> []audio.Device_Info {
	if !platform.is_headless() { return audio.list_devices(input, temp); }
	out := make_slice(audio.Device_Info, 2, temp);
	at(*out, 0).* = .{id = 0, name = "Default", is_default = true};
	at(*out, 1).* = .{id = 1001, name = ifx input then "Test Microphone" else "Test Speakers", uid = "test"};
	return out;
}

