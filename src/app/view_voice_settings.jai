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
	echo, noise, agc: bool; // Voice Processing
	soundboard_volume: float32 = 100; // 0..100 %, the sounds others play (soundboard.jai)
	soundboard_mic: bool; // our sounds go out through the mic instead of Discord's soundboard
	user_volume: Table(dc.Snowflake, float32); // 0..400 %
	user_muted: Table(dc.Snowflake, bool);
	// UI state
	open_dropdown: int; // 0 none, 1 input, 2 output
	meter_owner: bool; // the meter started the capture
	meter_vad: voice.Vad;
	meter_db: float32;
	meter_shown: float32; // the bar's level (0..1), smoothed toward meter_db every frame
	meter_open: bool;
	proc: voice.Mic_Processing; // the meter's and mic test's processing outside a call
	mic_test: bool; // Let's Check: the processed mic played back
	test_src: audio.Source;
	reset_armed: bool; // Reset Voice Settings was clicked once
	menu_user: dc.Snowflake; // a call participant's menu
	menu_move: bool; // its Move To list is open
	dd_anchor: ui.Rect; // open dropdown's rect (popup drawn from overlays)
	menu_pos: ui.Vec2;
	inited: bool;
	// input mode (MediaEngineStore: mode VOICE_ACTIVITY | PUSH_TO_TALK, delay 20 ms)
	ptt_mode: bool;
	ptt_key: platform.Key; // .None = unbound (the client has no default keybind)
	ptt_mods: platform.Mod; // held with ptt_key: a combo
	ptt_mouse: platform.Mouse_Button; // a mouse button instead (Middle, X1, X2; Left = none)
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
	vs.echo, vs.noise, vs.agc = p.echo, p.noise, p.agc;
	vs.soundboard_volume, vs.soundboard_mic = clamp(p.soundboard_volume, 0, 100), p.soundboard_mic;
	vs.ptt_mode = p.mode == "PUSH_TO_TALK";
	ptt_parse(p.ptt_key);
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
	p.echo, p.noise, p.agc = vs.echo, vs.noise, vs.agc;
	p.soundboard_volume, p.soundboard_mic = vs.soundboard_volume, vs.soundboard_mic;
	p.mode = ifx vs.ptt_mode then "PUSH_TO_TALK" else "VOICE_ACTIVITY";
	p.ptt_key = ptt_name();
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
		voice.set_processing(conn, vs.echo, vs.noise, vs.agc);
		for v, uid: vs.user_volume { voice.set_user_volume(conn, cast(u64)(uid), v / 100); }
		for m, uid: vs.user_muted { voice.set_user_mute(conn, cast(u64)(uid), m); }
	}
	if audio_ready audio.set_volume(vs.output_volume / 100);

	page_open := app.settings_open && settings_page == "Voice & Video";
	if !page_open || headless || conn != null mic_test_stop();
	if !page_open || headless {
		if vs.meter_owner && conn == null audio.capture_stop();
		vs.meter_owner = false;
		if !page_open vs.reset_armed = false;
		voice.mic_processing_free(*vs.proc);
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
				// processed as a call's mic is (voice.mic_process), so the switches can be heard and seen here
				voice.mic_process(*vs.proc, buf, vs.echo, vs.noise, vs.agc);
				g := vs.input_volume / 100;
				for * x: buf { x.* *= g; }
				if vs.mic_test {
					// Let's Check: what the mic sends, played back
					if !vs.test_src vs.test_src = audio.source_create();
					st: [1920]float32;
					for buf { st[it_index * 2], st[it_index * 2 + 1] = it, it; }
					if vs.test_src audio.source_write(vs.test_src, st);
				}
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

// ptt_name: the push-to-talk binding as settings.json keeps it and the page shows it: "Ctrl+Shift+A",
// "Mouse4", or "" when unbound. ptt_parse reads it back (a bare key name from before combos too).
ptt_name :: () -> string {
	if vs.ptt_mouse != .Left return tprint("Mouse%", cast(int) vs.ptt_mouse + 1);
	if vs.ptt_key == .None return "";
	sb: String_Builder;
	sb.allocator = temp;
	for m: platform.Mod.[.Ctrl, .Alt, .Shift, .Cmd] if vs.ptt_mods & m print_to_builder(*sb, "%+", m);
	print_to_builder(*sb, "%", vs.ptt_key);
	return builder_to_string(*sb,, temp);
}

ptt_parse :: (s: string) {
	vs.ptt_key, vs.ptt_mods, vs.ptt_mouse = platform.Key.None, 0, platform.Mouse_Button.Left;
	parts := split(s, "+",, temp);
	for parts {
		last := it_index == parts.count - 1;
		if !last {
			for m: platform.Mod.[.Ctrl, .Alt, .Shift, .Cmd] if it == tprint("%", m) vs.ptt_mods |= m;
		} else if begins_with(it, "Mouse") {
			n := string_to_int(advance(it, 5));
			if n >= 3 && n <= 5 vs.ptt_mouse = cast(platform.Mouse_Button) (n - 1);
		} else {
			for enum_names(platform.Key) if it == parts[parts.count - 1] vs.ptt_key = cast(platform.Key) enum_values_as_s64(platform.Key)[it_index];
		}
	}
}

mic_test_stop :: () {
	vs.mic_test = false;
	if vs.test_src audio.source_destroy(vs.test_src);
	vs.test_src = 0;
}

// voice_settings_reset: Reset Voice Settings: devices, volumes, input mode, sensitivity and processing back to
// their defaults. Per-user volumes and mutes stay.
voice_settings_reset :: () {
	mic_test_stop();
	voice.mic_processing_free(*vs.proc);
	audio.select_device(true, 0);
	audio.select_device(false, 0);
	keep_vol, keep_mute := vs.user_volume, vs.user_muted;
	vs.user_volume, vs.user_muted = .{}, .{};
	vs_reset_for_test();
	deinit(*vs.user_volume);
	deinit(*vs.user_muted);
	vs.user_volume, vs.user_muted = keep_vol, keep_mute;
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
				if !voice_conn() {
					// MIC TEST: Let's Check plays the processed mic back
					spacer(.Y, 12);
					if set_button(ifx vs.mic_test then "Stop Testing##mictest" else "Let's Check##mictest", ifx vs.mic_test then .Danger else .Primary, true, 32) {
						if vs.mic_test mic_test_stop(); else vs.mic_test = true;
					}
				}
				if !vs.auto_sens {
					spacer(.Y, 8);
					slider("thresh", *vs.threshold_db, -100, 0, 660, tprint("%dB", formatFloat(vs.threshold_db, trailing_width = 0, zero_removal = .NO)));
				}
				spacer(.Y, 32);
				section_title("VOICE PROCESSING");
				toggle_row("echo", "Echo Cancellation", "", *vs.echo);
				spacer(.Y, 8);
				toggle_row("noise", "Noise Suppression", "Suppress background noise from your mic.", *vs.noise);
				spacer(.Y, 8);
				toggle_row("agc", "Automatic Gain Control", "", *vs.agc);
				spacer(.Y, 32);
				section_title("SOUNDBOARD VOLUME");
				slider("sbvol", *vs.soundboard_volume, 0, 100, 660, percent(vs.soundboard_volume));
				spacer(.Y, 16);
				toggle_row("sbmic", "Play Soundboard Through My Mic", "Your sounds go out with your voice, mixed into your microphone, instead of as soundboard sounds.", *vs.soundboard_mic);
				if video.SUPPORTED {
					spacer(.Y, 32);
					camera_test_section();
				}
				spacer(.Y, 32);
				// Reset Voice Settings, with a second click to confirm
				if set_button(ifx vs.reset_armed then "Click Again to Reset##vreset" else "Reset Voice Settings##vreset", .Danger, true, 32) {
					if vs.reset_armed voice_settings_reset();
					else vs.reset_armed = true;
				}
				spacer(.Y, 40);
			}
		}
	}
}

// ---------------------------------------------------------------------------
// Right-click on a voice participant: volume 0-400 % and mute.

open_voice_user_menu :: (uid: dc.Snowflake, at: ui.Vec2) {
	vs_init();
	vs.menu_user = uid;
	vs.menu_move = false;
	vs.menu_pos = at;
}

voice_dropdown_open :: () -> bool { return vs.open_dropdown != 0; }

voice_user_menu :: () {
	// device dropdown popup: drawn here so it lands above the settings modal
	// (closes on a press outside it, Escape, or leaving the page)
	if !app.settings_open || settings_page != "Voice & Video" vs.open_dropdown = 0;
	if vs.open_dropdown != 0 && vs.dd_anchor.x1 > vs.dd_anchor.x0 {
		if outside_pressed("dd_scrim") || escape_pressed() {
			vs.open_dropdown = 0;
		} else {
			input := vs.open_dropdown == 1;
			r := vs.dd_anchor;
			device_list(vs_list_devices(input), audio.selected_device(input), input, r.x1 - r.x0, .{r.x0, r.y1 + 4});
		}
	}
	if vs.menu_user == 0 return;
	uid := vs.menu_user;
	st := store();
	v := table_find_pointer(*st.voice_states, uid);
	if outside_pressed("vmenu_scrim") || !v {
		vs.menu_user = 0;
		return;
	}
	W :: cast(float32) 220;
	p := vs.menu_pos;
	menu := menu_panel("vmenu", p, W);
	h := menu.rect.y1 - menu.rect.y0; // last frame's
	if p.y + h > app.ui.window.y - 8 p.y = max(8.0, app.ui.window.y - 8 - h);
	if p.x + W > app.ui.window.x - 8 p.x = app.ui.window.x - 8 - W;
	menu.fixed_pos = p;
	perms := ifx v.guild_id then dc.channel_permissions(st, v.channel_id) else 0;
	{ ui.parent(menu); defer ui.pop_parent();
		spacer(.Y, 8);
		if menu_item("profile", "Profile").clicked {
			vs.menu_user = 0;
			open_profile(uid, .{p.x, p.y, p.x + W, p.y + 1});
			return;
		}
		if uid != st.me {
			menu_sep("s0");
			hdr := row("hdr");
			hdr.semantic_size = .[ui.pct(1), ui.px(24)];
			{ ui.parent(hdr); defer ui.pop_parent();
				spacer(.X, 16);
				label("User Volume", .Medium, 14, T("--interactive-text-default"), 18);
			}
			sr := row("sl");
			sr.semantic_size = .[ui.pct(1), ui.px(32)];
			{ ui.parent(sr); defer ui.pop_parent();
				spacer(.X, 16);
				vp := table_find_pointer(*vs.user_volume, uid);
				vol := ifx vp then vp.* else 100.0;
				if slider("uvol", *vol, 0, 400, W - 32, percent(vol)) table_set(*vs.user_volume, uid, vol);
			}
			_, m := table_find(*vs.user_muted, uid);
			if menu_item("mute", "Mute", ifx m then .Check_On else .Check_Off).clicked table_set(*vs.user_muted, uid, !m);
		}
		// a moderator's tools, each with its permission (PATCH /guilds/{id}/members/{user})
		can_mute := dc.has_permission(perms, dc.PERM_MUTE_MEMBERS);
		can_deafen := dc.has_permission(perms, dc.PERM_DEAFEN_MEMBERS);
		can_move := dc.has_permission(perms, dc.PERM_MOVE_MEMBERS);
		if can_mute || can_deafen || can_move menu_sep("s1");
		if can_mute && menu_item("smute", "Server Mute", ifx v.mute then .Check_On else .Check_Off, danger = true).clicked && net_action()
			dc.set_member_voice(app.client, v.guild_id, uid, tprint("{\"mute\":%}", !v.mute));
		if can_deafen && menu_item("sdeaf", "Server Deafen", ifx v.deaf then .Check_On else .Check_Off, danger = true).clicked && net_action()
			dc.set_member_voice(app.client, v.guild_id, uid, tprint("{\"deaf\":%}", !v.deaf));
		ch := dc.channel_get(st, v.channel_id);
		if ch && ch.kind == .Guild_Stage_Voice && stage_moderator(v.channel_id) {
			// a stage's audience is invited to speak; a speaker goes back to the audience
			if menu_item("stage", ifx v.suppress then "Invite to Speak" else "Move to Audience").clicked {
				vs.menu_user = 0;
				if net_action() dc.stage_set_suppress(app.client, v.guild_id, v.channel_id, uid, !v.suppress);
				return;
			}
		}
		if can_move {
			if menu_item("disconnect", "Disconnect", danger = true).clicked {
				vs.menu_user = 0;
				if net_action() dc.set_member_voice(app.client, v.guild_id, uid, "{\"channel_id\":null}");
				return;
			}
			if menu_item("move", "Move To", .Chevron, open = vs.menu_move).clicked vs.menu_move = !vs.menu_move;
			if vs.menu_move for cid: dc.guild_channels_sorted(st, v.guild_id) {
				ch := dc.channel_get(st, cid);
				if !ch || (ch.kind != .Guild_Voice && ch.kind != .Guild_Stage_Voice) || cid == v.channel_id continue;
				if !dc.has_permission(dc.channel_permissions(st, cid), dc.PERM_CONNECT) continue;
				ui.id_scope(cast(u64) cid); defer ui.pop_seed();
				if menu_item("to", ch.name, icon_name = channel_icon_name(ch)).clicked {
					vs.menu_user = 0;
					if net_action() dc.set_member_voice(app.client, v.guild_id, uid, tprint("{\"channel_id\":\"%\"}", cid));
					return;
				}
			}
		}
		spacer(.Y, 8);
	}
	for * e: app.ui.events { if e.kind == .Key_Down && e.key == .Escape { vs.menu_user = 0; e.consumed = true; } }
}

// Headless runs (UI scripts, the control sweep) list fixed devices instead of
// this machine's, so screenshots and sweep descriptors match everywhere.
vs_list_devices :: (input: bool) -> []audio.Device_Info {
	if !platform.is_headless() return audio.list_devices(input, temp);
	out := NewArray(1, audio.Device_Info,, temp);
	out[0] = .{id = 1001, name = ifx input then "Test Microphone" else "Test Speakers", uid = "test", is_default = true};
	return out;
}

// slider: horizontal track, returns true while the value changes (also Accessibility's Zoom level).
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

#scope_file

vs_init :: () {
	if vs.inited return;
	vs.inited = true;
	vs.input_volume = 100;
	vs.output_volume = 100;
	vs.auto_sens = true;
	vs.threshold_db = voice.VAD_DEFAULT_THRESHOLD;
	vs.echo, vs.noise, vs.agc = true, true, true;
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
				if e.key != .Escape && e.key != .None vs.ptt_key, vs.ptt_mods, vs.ptt_mouse = e.key, e.mods, platform.Mouse_Button.Left;
				vs.recording_key = false;
				continue;
			}
			if vs.ptt_key != .None && e.key == vs.ptt_key && (e.mods & vs.ptt_mods) == vs.ptt_mods vs.ptt_held = true;
		case .Key_Up;
			if e.key == vs.ptt_key vs.ptt_held = false;
		case .Mouse_Down;
			// the middle and side buttons can be bound; left and right stay the UI's
			if e.button < .Middle continue;
			if vs.recording_key { vs.ptt_key, vs.ptt_mods, vs.ptt_mouse = platform.Key.None, 0, e.button; vs.recording_key = false; continue; }
			if e.button == vs.ptt_mouse vs.ptt_held = true;
		case .Mouse_Up;
			if vs.ptt_mouse != .Left && e.button == vs.ptt_mouse vs.ptt_held = false;
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
				name := ptt_name();
				if !name name = "No Keybind Set";
				if vs.recording_key name = "Press a shortcut…";
				label(name, .Medium, 16, T("--text-default"), 20);
				filler(.X);
				label(ifx vs.recording_key then "Stop Recording" else "Record Keybind", .Semibold, 14, T("--text-strong"), 18);
				spacer(.X, 12);
			}
			spacer(.Y, 6);
			label("A key with Ctrl, Alt, Shift or Cmd, or a middle or side mouse button. Works while Fastcord is focused.", .Normal, 12, T("--text-muted"), 16).flags |= .Wrap_Text;
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
