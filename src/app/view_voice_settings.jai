// Settings > Voice & Video and the per-user voice context menu.
//
// Defaults follow the official client (MediaEngineStore): input volume 100,
// output volume 100 (0-200 %; fastcord goes to 400 %), input sensitivity automatic (manual threshold
// -60 dB), echo cancellation / noise suppression / AGC on. The mic level
// meter only runs while the page is open, and never in headless runs.

settings_page := "Appearance"; // selected page of the settings modal

Voice_Settings :: struct {
	input_volume: float32; // 0..400
	output_volume: float32; // 0..400
	auto_sens: bool;
	threshold_db: float32; // -100..0
	processing: audio.Voice_Processing;
	rnnoise: bool;
	user_volume: Table(dc.Snowflake, float32); // 0..400 %
	user_muted: Table(dc.Snowflake, bool);
	// UI state
	open_dropdown: int; // 0 none, 1 input, 2 output
	meter_owner: bool; // the meter started the capture
	meter_vad: voice.Vad;
	meter_db: float32;
	meter_shown: float32; // the bar's level (0..1), smoothed toward meter_db every frame
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

// ---- persistence (settings_store.jai) ----

vs_reset_for_test :: () {
	deinit(*vs.user_volume);
	deinit(*vs.user_muted);
	vs = .{};
	vs_init();
}

voice_settings_restore :: (p: *Persisted_Voice) {
	vs_init();
	vs.input_volume = clamp(p.input_volume, 0, 400);
	vs.output_volume = clamp(p.output_volume, 0, 400);
	vs.auto_sens = p.auto_sens;
	vs.threshold_db = clamp(p.threshold_db, -100, 0);
	vs.processing = .{p.echo, p.noise, p.agc};
	audio.set_voice_processing(vs.processing);
	vs.rnnoise = p.rnnoise;
	vs.ptt_mode = p.mode == "PUSH_TO_TALK";
	for enum_names(platform.Key) if it == p.ptt_key vs.ptt_key = cast(platform.Key) enum_values_as_s64(platform.Key)[it_index];
	vs.ptt_delay_ms = clamp(cast(float32) p.ptt_delay_ms, 0, 2000);
	id := device_by_uid(true, p.input_device);
	if id != 0 audio.select_device(true, id);
	id = device_by_uid(false, p.output_device);
	if id != 0 audio.select_device(false, id);
	for v, k: p.user_volume {
		n, ok := dc.parse_u64(k);
		if ok table_set(*vs.user_volume, cast(dc.Snowflake) n, clamp(v, 0, 400));
	}
	for v, k: p.user_muted {
		n, ok := dc.parse_u64(k);
		if ok && v table_set(*vs.user_muted, cast(dc.Snowflake) n, true);
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
	p.rnnoise = vs.rnnoise;
	p.mode = ifx vs.ptt_mode then "PUSH_TO_TALK" else "VOICE_ACTIVITY";
	p.ptt_key = tprint("%", vs.ptt_key);
	p.ptt_delay_ms = cast(int) vs.ptt_delay_ms;
	p.user_volume, p.user_muted = .{}, .{};
	for v, k: vs.user_volume if v != 100 table_set(*p.user_volume, tprint("%", cast(u64) k), v);
	for v, k: vs.user_muted if v table_set(*p.user_muted, tprint("%", cast(u64) k), true);
}

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
		voice.set_noise_suppression(conn, vs.rnnoise);
		for v, uid: vs.user_volume { voice.set_user_volume(conn, cast(u64)(uid), v / 100); }
		for m, uid: vs.user_muted { voice.set_user_mute(conn, cast(u64)(uid), m); }
	}
	if audio_ready audio.set_volume(vs.output_volume / 100);

	page_open := app.settings_open && settings_page == "Voice & Video";
	if !page_open || headless {
		if vs.meter_owner && conn == null audio.capture_stop();
		vs.meter_owner = false;
		return;
	}
	if conn != null {
		// the voice connection owns the mic; read its level
		vs.meter_owner = false;
		vs.meter_db, vs.meter_open = voice.input_level(conn);
	} else {
		if !vs.meter_owner {
			if audio.init() && audio.capture_start(false) vs.meter_owner = true;
		}
		if vs.meter_owner {
			buf: [960]float32;
			while audio.capture_available() >= 960 {
				audio.capture_read(buf);
				g := vs.input_volume / 100;
				for * x: buf { x.* *= g; }
				vs.meter_vad.auto_threshold = vs.auto_sens;
				vs.meter_vad.threshold_db = vs.threshold_db;
				vs.meter_open, vs.meter_db = voice.vad_process(*vs.meter_vad, buf);
			}
		}
	}
	// every frame while the page is open: the level comes in 20 ms audio frames and is
	// eased toward each frame (fast rise, slower fall), so the bar moves smoothly
	target := clamp((vs.meter_db + 100) / 100, 0, 1);
	tau: float32 = ifx target > vs.meter_shown then 0.03 else 0.15;
	vs.meter_shown += (target - vs.meter_shown) * (1 - exp(-app.dt / tau));
	platform.request_frame();
}

toggle_row :: (id: string, text: string, help: string, value: *bool) -> bool {
	r := row(id, .Clickable);
	r.semantic_size = .[ui.px(660), ui.px(ifx help != "" then 52.0 else 32.0)];
	sig := ui.signal(r);
	{ ui.parent(r); defer ui.pop_parent();
		col := ui.box("col");
		col.semantic_size = .[ui.fill(), ui.children()];
		{ ui.parent(col); defer ui.pop_parent();
			label(text, .Medium, 16, T("--text-strong"), 20);
			if help != "" label(help, .Normal, 14, T("--text-muted"), 18);
		}
		sw := ui.box("switch", .Draw_Background);
		sw.semantic_size = .[ui.px(40), ui.px(24)];
		sw.style.radius = all4(12);
		sw.style.bg = ifx value.* then T("--status-positive") else T("--background-mod-strong");
		{ ui.parent(sw); defer ui.pop_parent();
			k := ui.box("k", .Draw_Background | .Floating_X | .Floating_Y);
			k.semantic_size = .[ui.px(18), ui.px(18)];
			k.fixed_pos = .{ifx value.* then 19.0 else 3.0, 3};
			k.style.radius = all4(9);
			k.style.bg = .{1, 1, 1, 1};
		}
	}
	if sig.clicked value.* = !value.*;
	return sig.clicked;
}

// ---------------------------------------------------------------------------
// Settings > Voice & Video

voice_settings_page :: () {
	vs_init();
	page := ui.box("voicepage", .Scroll_Y | .Clip);
	page.semantic_size = .[ui.pct(1), ui.fill()];
	page.layout_axis = .Y;
	page.scrollbar = .Auto;
	ui.signal(page);
	{ ui.parent(page); defer ui.pop_parent();
		spacer(.Y, 32); // as set_page_begin
		body := row("vbody");
		body.semantic_size = .[ui.pct(1), ui.children()];
		body.cross_align = .Start;
		{ ui.parent(body); defer ui.pop_parent();
			spacer(.X, 40);
			col := ui.box("vcol");
			col.semantic_size = .[ui.px(660), ui.children()];
			col.layout_axis = .Y;
			{ ui.parent(col); defer ui.pop_parent();
				devices := row("devices");
				devices.semantic_size = .[ui.pct(1), ui.children()];
				devices.cross_align = .Start;
				{ ui.parent(devices); defer ui.pop_parent();
					for input: (bool.[true, false]) {
						c := ui.box(ifx input then "inputcol" else "outputcol");
						c.semantic_size = .[ui.px(320), ui.children()];
						c.layout_axis = .Y;
						{ ui.parent(c); defer ui.pop_parent();
							section_title(ifx input then "INPUT DEVICE" else "OUTPUT DEVICE");
							device_dropdown(ifx input then 1 else 2, input, 320);
							spacer(.Y, 20);
							section_title(ifx input then "INPUT VOLUME" else "OUTPUT VOLUME");
							if input {
								slider("invol", *vs.input_volume, 0, 400, 320, percent(vs.input_volume));
							} else {
								slider("outvol", *vs.output_volume, 0, 400, 320, percent(vs.output_volume));
							}
						}
						if input spacer(.X, 20);
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
					slider("thresh", *vs.threshold_db, -100, 0, 660, tprint("%dB", formatFloat(vs.threshold_db, trailing_width = 0, zero_removal = .NO)));
				}
				spacer(.Y, 32);
				section_title("VOICE PROCESSING");
				p := vs.processing;
				changed := toggle_row("echo", "Echo Cancellation", "", *p.echo_cancellation);
				spacer(.Y, 8);
				changed |= toggle_row("noise", "Noise Suppression", "Suppress background noise from your mic.", *p.noise_suppression);
				spacer(.Y, 8);
				changed |= toggle_row("agc", "Automatic Gain Control", "", *p.auto_gain_control);
				spacer(.Y, 8);
				toggle_row("rnnoise", "RNNoise", "Open-source noise suppression run by fastcord. Works with the switches above off.", *vs.rnnoise);
				if changed {
					vs.processing = p;
					audio.set_voice_processing(p);
				}
				if video.SUPPORTED {
					spacer(.Y, 32);
					camera_test_section();
				}
				spacer(.Y, 40);
			}
		}
	}
}

// ---------------------------------------------------------------------------
// Right-click on a voice participant: volume 0-400 % and mute.

open_voice_user_menu :: (uid: dc.Snowflake, at: ui.Vec2) {
	if uid == store().me return;
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
	if vs.menu_user == 0 return;
	uid := vs.menu_user;
	scrim := ui.box("vmenu_scrim", .Clickable | .Floating_X | .Floating_Y | .Overlay);
	scrim.semantic_size = .[ui.px(app.ui.window.x), ui.px(app.ui.window.y)];
	if ui.signal(scrim).pressed {
		vs.menu_user = 0;
		return;
	}
	W :: cast(float32)(220);
	H :: cast(float32)(124);
	p := vs.menu_pos;
	if p.y + H > app.ui.window.y - 8 p.y = app.ui.window.y - 8 - H;
	if p.x + W > app.ui.window.x - 8 p.x = app.ui.window.x - 8 - W;
	menu := ui.box("vmenu", .Draw_Background | .Draw_Border | .Draw_Shadow | .Floating_X | .Floating_Y | .Overlay | .Clickable);
	menu.semantic_size = .[ui.px(W), ui.px(H)];
	menu.fixed_pos = p;
	menu.layout_axis = .Y;
	menu.style.bg = T("--background-surface-higher");
	menu.style.border_color = T("--border-subtle");
	menu.style.border = 1;
	menu.style.radius = all4(8);
	menu.style.shadow_color = .{0, 0, 0, 0.24};
	menu.style.shadow_blur = 16;
	menu.style.shadow_offset = .{0, 8};
	ui.signal(menu);
	{ ui.parent(menu); defer ui.pop_parent();
		spacer(.Y, 8);
		hdr := row("hdr");
		hdr.semantic_size = .[ui.pct(1), ui.px(24)];
		{ ui.parent(hdr); defer ui.pop_parent();
			spacer(.X, 12);
			label("User Volume", .Medium, 14, T("--interactive-text-default"), 18);
		}
		sr := row("sl");
		sr.semantic_size = .[ui.pct(1), ui.px(32)];
		{ ui.parent(sr); defer ui.pop_parent();
			spacer(.X, 12);
			p := table_find_pointer(*vs.user_volume, uid);
			v := ifx p then p.* else 100.0;
			if slider("uvol", *v, 0, 400, W - 24, percent(v)) table_set(*vs.user_volume, uid, v);
		}
		spacer(.Y, 4);
		sep := ui.box("sep", .Draw_Background);
		sep.semantic_size = .[ui.pct(1), ui.px(1)];
		sep.style.bg = T("--border-subtle");
		spacer(.Y, 4);
		_, m := table_find(*vs.user_muted, uid);
		mr := row("mute", .Clickable | .Draw_Background | .Hot_Animation);
		mr.semantic_size = .[ui.pct(1), ui.px(32)];
		mr.style.radius = all4(4);
		mr.style.bg_hot = T("--background-mod-normal");
		sig := ui.signal(mr);
		{ ui.parent(mr); defer ui.pop_parent();
			spacer(.X, 12);
			label("Mute", .Medium, 14, ifx sig.hovering then T("--interactive-text-active") else T("--interactive-text-default"), 18);
			filler(.X);
			cb := ui.box("cb", .Draw_Background | .Draw_Border);
			cb.semantic_size = .[ui.px(18), ui.px(18)];
			cb.style.radius = all4(4);
			cb.style.border = ifx m then 0.0 else 1.5;
			cb.style.border_color = T("--interactive-icon-default");
			cb.style.bg = ifx m then T("--background-brand") else .{};
			if m {
				{ ui.parent(cb); defer ui.pop_parent(); icon("ck", "checkmark-large", 18, .{1, 1, 1, 1}); }
			}
			spacer(.X, 12);
		}
		if sig.clicked table_set(*vs.user_muted, uid, !m);
	}
	for e: app.ui.events { if e.kind == .Key_Down && e.key == .Escape { vs.menu_user = 0; } }
}

// Headless runs (UI scripts, the control sweep) list fixed devices instead of
// this machine's, so screenshots and sweep descriptors match everywhere.
vs_list_devices :: (input: bool) -> []audio.Device_Info {
	if !platform.is_headless() return audio.list_devices(input, temp);
	out := NewArray(1, audio.Device_Info,, temp);
	out[0] = .{id = 1001, name = ifx input then "Test Microphone" else "Test Speakers", uid = "test", is_default = true};
	return out;
}

#scope_file

vs_init :: () {
	if vs.inited return;
	vs.inited = true;
	vs.input_volume = 100;
	vs.output_volume = 100;
	vs.auto_sens = true;
	vs.threshold_db = voice.VAD_DEFAULT_THRESHOLD;
	vs.processing = audio.Voice_Processing.{true, true, true};
	vs.meter_db = -127;
	vs.meter_shown = 0;
	vs.ptt_delay_ms = 20;
	voice.vad_init(*vs.meter_vad);
}

// push-to-talk key state (focused window only: a global hotkey on macOS
// needs an event tap and the Accessibility permission).
ptt_input :: () {
	for e: platform.events() {
		if e.kind == {
		case .Key_Down;
			if vs.recording_key {
				if e.key != .Escape && e.key != .None vs.ptt_key = e.key;
				vs.recording_key = false;
				continue;
			}
			if vs.ptt_key != .None && e.key == vs.ptt_key vs.ptt_held = true;
		case .Key_Up;
			if e.key == vs.ptt_key vs.ptt_held = false;
		case .Focus_Lost;
			vs.ptt_held = false;
		}
	}
}

// ---------------------------------------------------------------------------
// Widgets

camera_test_section :: () {
	section_title("CAMERA");
	img := camera_test_image();
	pv := ui.box("campreview", .Draw_Background);
	pv.semantic_size = .[ui.px(660), ui.px(660 * 9 / 16)];
	pv.style.radius = all4(8);
	pv.style.bg = T("--background-base-lowest");
	pv.layout_axis = .Y;
	pv.cross_align = .Center;
	if img.y {
		d := New(Tile_Draw,, temp);
		d.* = .{img, false};
		pv.custom_draw = tile_video_draw;
		pv.custom_user = d;
	}
	if camera_on() return;
	{ ui.parent(pv); defer ui.pop_parent();
		filler(.Y);
		on := vid.preview.capture != null;
		b := row("camtest", .Clickable | .Draw_Background | .Hot_Animation);
		b.semantic_size = .[ui.children(), ui.px(38)];
		b.style.radius = all4(8);
		b.style.bg = ifx on then T("--background-surface-highest") else T("--background-brand");
		b.style.bg_hot = with_alpha(b.style.bg, 0.85);
		if ui.signal(b).clicked camera_test_toggle();
		{ ui.parent(b); defer ui.pop_parent();
			spacer(.X, 16);
			label(ifx on then "Stop Video" else "Test Video", .Semibold, 14, .{1, 1, 1, 1}, 18);
			spacer(.X, 16);
		}
		spacer(.Y, ifx on then 16.0 else 0);
		if !on filler(.Y);
	}
}

section_title :: (text: string) {
	label(text, .Bold, 12, T("--text-muted"), 16);
	spacer(.Y, 8);
}

// slider: horizontal track, returns true while the value changes.
slider :: (id: string, value: *float32, lo: float32, hi: float32, w: float32, fmt_value: string = "") -> bool {
	track := ui.box(id, .Clickable);
	track.semantic_size = .[ui.px(w), ui.px(24)];
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
	{ ui.parent(track); defer ui.pop_parent();
		bar := ui.box("bar", .Draw_Background | .Floating_X | .Floating_Y);
		bar.semantic_size = .[ui.px(w), ui.px(8)];
		bar.fixed_pos = .{0, 8};
		bar.style.bg = T("--background-mod-strong");
		bar.style.radius = all4(4);
		fill := ui.box("fill", .Draw_Background | .Floating_X | .Floating_Y);
		fill.semantic_size = .[ui.px(max(w * t, 1)), ui.px(8)];
		fill.fixed_pos = .{0, 8};
		fill.style.bg = T("--background-brand");
		fill.style.radius = all4(4);
		knob := ui.box("knob", .Draw_Background | .Draw_Shadow | .Floating_X | .Floating_Y);
		knob.semantic_size = .[ui.px(10), ui.px(24)];
		knob.fixed_pos = .{w * t - 5, 0};
		knob.style.bg = .{1, 1, 1, 1};
		knob.style.radius = all4(3);
		knob.style.shadow_color = .{0, 0, 0, 0.3};
		knob.style.shadow_blur = 4;
		if (sig.hovering || sig.dragging) && fmt_value != "" {
			tip := row("tip", .Draw_Background | .Floating_X | .Floating_Y | .Overlay);
			tip.semantic_size = .[ui.children(), ui.px(26)];
			tip.fixed_pos = .{w * t - 24, -32};
			tip.style.bg = T("--background-surface-highest");
			tip.style.radius = all4(6);
			{ ui.parent(tip); defer ui.pop_parent();
				spacer(.X, 8);
				label(fmt_value, .Semibold, 13, T("--text-strong"), 16);
				spacer(.X, 8);
			}
		}
	}
	return changed;
}

device_dropdown :: (which: int, input: bool, w: float32) {
	devs := vs_list_devices(input);
	sel := audio.selected_device(input);
	current := "Default";
	for d: devs { if sel != 0 && d.id == sel { current = d.name; } }
	hint := ifx current == "Default" then default_name(devs) else "";
	box := row(ifx input then "indev" else "outdev", .Clickable | .Draw_Background | .Draw_Border);
	box.semantic_size = .[ui.px(w), ui.px(40)];
	box.style.bg = T("--background-base-lowest");
	if tok_has("--input-background") box.style.bg = T("--input-background");
	box.style.border = 1;
	box.style.border_color = T("--border-subtle");
	box.style.radius = all4(8);
	sig := ui.signal(box);
	if sig.clicked vs.open_dropdown = ifx vs.open_dropdown == which then 0 else which;
	{ ui.parent(box); defer ui.pop_parent();
		spacer(.X, 12);
		t := label(current, .Medium, 16, T("--text-default"), 20);
		if hint != "" {
			spacer(.X, 6);
			t = label(hint, .Normal, 14, T("--text-muted"), 20);
		}
		t.flags |= .Clip;
		filler(.X);
		icon("chev", ifx vs.open_dropdown == which then "chevron-small-up" else "chevron-small-down", 20, T("--interactive-icon-default"));
		spacer(.X, 8);
	}
	if vs.open_dropdown == which vs.dd_anchor = box.rect;
}

// popup list under the dropdown (overlay, like the client's select menu)
device_list :: (devs: []audio.Device_Info, sel: u32, input: bool, w: float32, at: ui.Vec2) {
	list := ui.box(ifx input then "inlist" else "outlist", .Draw_Background | .Draw_Border | .Draw_Shadow | .Floating_X | .Floating_Y | .Overlay | .Clickable);
	list.semantic_size = .[ui.px(w), ui.children()];
	list.fixed_pos = at;
	list.layout_axis = .Y;
	list.style.bg = T("--background-surface-higher");
	list.style.border = 1;
	list.style.border_color = T("--border-subtle");
	list.style.radius = all4(8);
	list.style.shadow_color = .{0, 0, 0, 0.24};
	list.style.shadow_blur = 16;
	list.style.shadow_offset = .{0, 8};
	ui.signal(list);
	{ ui.parent(list); defer ui.pop_parent();
		opt :: (name: string, id: u32, input: bool, selected: bool, hint := "") {
			it_ := row(name, .Clickable | .Draw_Background | .Hot_Animation);
			it_.semantic_size = .[ui.pct(1), ui.px(36)];
			it_.style.bg_hot = T("--background-mod-normal");
			{ ui.parent(it_); defer ui.pop_parent();
				spacer(.X, 12);
				label(name, ifx selected then .Semibold else .Medium, 15, ifx selected then T("--text-strong") else T("--text-default"), 20);
				if hint != "" {
					spacer(.X, 6);
					label(hint, .Normal, 14, T("--text-muted"), 20).flags |= .Clip;
				}
			}
			if ui.signal(it_).clicked {
				audio.select_device(input, id);
				vs.open_dropdown = 0;
			}
		}
		opt("Default", 0, input, sel == 0, default_name(devs));
		for d: devs { { ui.id_scope(cast(u64)(d.id) + 1); defer ui.pop_seed(); opt(d.name, d.id, input, d.id == sel); } }
	}
}

// default_name: the device "Default" resolves to right now, as a hint next to it.
default_name :: (devs: []audio.Device_Info) -> string {
	for devs if it.is_default && it.id != 0 return it.name;
	return "";
}

tok_has :: (name: string) -> bool { return table_contains(*app.theme.tokens, name); }
mode_radio :: () {
	for ptt: (bool.[false, true]) {
		r := row(ifx ptt then "mode_ptt" else "mode_va", .Clickable | .Draw_Background | .Hot_Animation);
		r.semantic_size = .[ui.px(660), ui.px(44)];
		r.style.radius = all4(4);
		r.style.bg = ifx vs.ptt_mode == ptt then T("--background-mod-normal") else .{};
		r.style.bg_hot = T("--background-mod-subtle");
		if ui.signal(r).clicked vs.ptt_mode = ptt;
		{ ui.parent(r); defer ui.pop_parent();
			spacer(.X, 12);
			dot := ui.box("dot", .Draw_Border);
			dot.semantic_size = .[ui.px(20), ui.px(20)];
			dot.style.radius = all4(10);
			dot.style.border = 2;
			dot.style.border_color = ifx vs.ptt_mode == ptt then T("--background-brand") else T("--interactive-icon-default");
			if vs.ptt_mode == ptt {
				{ ui.parent(dot); defer ui.pop_parent();
					in_ := ui.box("in", .Draw_Background | .Floating_X | .Floating_Y);
					in_.semantic_size = .[ui.px(10), ui.px(10)];
					in_.fixed_pos = .{5, 5};
					in_.style.radius = all4(5);
					in_.style.bg = T("--background-brand");
				}
			}
			spacer(.X, 12);
			label(ifx ptt then "Push to Talk" else "Voice Activity", .Medium, 16, T("--text-strong"), 20);
		}
		spacer(.Y, 8);
	}
}

keybind_row :: () {
	r := row("ptt");
	r.semantic_size = .[ui.px(660), ui.children()];
	r.cross_align = .Start;
	{ ui.parent(r); defer ui.pop_parent();
		c := ui.box("kb");
		c.semantic_size = .[ui.px(320), ui.children()];
		c.layout_axis = .Y;
		{ ui.parent(c); defer ui.pop_parent();
			section_title("SHORTCUT");
			b := row("rec", .Clickable | .Draw_Background | .Draw_Border);
			b.semantic_size = .[ui.px(320), ui.px(40)];
			b.style.radius = all4(8);
			b.style.border = 1;
			b.style.border_color = ifx vs.recording_key then T("--status-danger") else T("--border-subtle");
			b.style.bg = T("--background-base-lowest");
			if ui.signal(b).clicked vs.recording_key = !vs.recording_key;
			{ ui.parent(b); defer ui.pop_parent();
				spacer(.X, 12);
				name := "No Keybind Set";
				if vs.ptt_key != .None name = tprint("%", vs.ptt_key);
				if vs.recording_key name = "Press a key…";
				label(name, .Medium, 16, T("--text-default"), 20);
				filler(.X);
				label(ifx vs.recording_key then "Stop Recording" else "Record Keybind", .Semibold, 14, T("--text-strong"), 18);
				spacer(.X, 12);
			}
			spacer(.Y, 6);
			label("Works while Fastcord is focused.", .Normal, 12, T("--text-muted"), 16);
		}
		spacer(.X, 20);
		d := ui.box("delay");
		d.semantic_size = .[ui.px(320), ui.children()];
		d.layout_axis = .Y;
		{ ui.parent(d); defer ui.pop_parent();
			section_title("PUSH TO TALK RELEASE DELAY");
			spacer(.Y, 8);
			slider("pttdelay", *vs.ptt_delay_ms, 0, 2000, 320, tprint("%ms", formatFloat(vs.ptt_delay_ms, trailing_width = 0, zero_removal = .NO)));
		}
	}
}

// meter_bar: live mic level against the sensitivity threshold (green when the
// gate is open, like the client's input sensitivity meter).
meter_bar :: () {
	W :: cast(float32)(660);
	bar := ui.box("meter", .Draw_Background);
	bar.semantic_size = .[ui.px(W), ui.px(8)];
	bar.style.bg = T("--background-mod-strong");
	bar.style.radius = all4(4);
	level := vs.meter_shown;
	if !app.settings_open level = 0;
	{ ui.parent(bar); defer ui.pop_parent();
		f := ui.box("lvl", .Draw_Background | .Floating_X | .Floating_Y);
		f.semantic_size = .[ui.px(max(W * level, 0.5)), ui.px(8)];
		f.style.radius = all4(4);
		f.style.bg = T("--text-feedback-warning");
		if vs.meter_open f.style.bg = T("--status-positive");
		if !vs.auto_sens {
			th := clamp((vs.threshold_db + 100) / 100, 0, 1);
			m := ui.box("th", .Draw_Background | .Floating_X | .Floating_Y);
			m.semantic_size = .[ui.px(2), ui.px(14)];
			m.fixed_pos = .{W * th - 1, -3};
			m.style.bg = T("--text-strong");
		}
	}
}

percent :: (v: float32) -> string { return tprint("%\%", formatFloat(v, trailing_width = 0, zero_removal = .NO)); }
