// Settings > Keybinds: user-defined shortcuts, as the official client's KeybindsStore. Each is an action
// and a shortcut (a key with modifiers, a modifier alone, or a middle or side mouse button) and works while
// fastcord isn't focused, through platform.set_global_input (listen-only: it never posts input). Push to
// talk is one of them: Voice & Video's Shortcut edits the first Push to Talk keybind. Without global input
// (headless, Input Monitoring not granted, no XInput2) they work while the window is focused.

Keybind_Action :: enum u8 { Unassigned; Push_To_Talk; Push_To_Mute; Toggle_Mute; Toggle_Deafen; Toggle_Voice_Mode; Toggle_Streamer_Mode; Toggle_Go_Live; Disconnect; Navigate_Back; Navigate_Forward; }
KEYBIND_LABELS :: string.["Unassigned", "Push to Talk (Normal)", "Push to Mute", "Toggle Mute", "Toggle Deafen", "Toggle Voice Activity Mode", "Toggle Streamer Mode", "Toggle Go Live Streaming", "Disconnect From Voice Channel", "Navigate Back", "Navigate Forward"];
// settings.json's names: the client's KeybindActions
KEYBIND_NAMES :: string.["UNASSIGNED", "PUSH_TO_TALK", "PUSH_TO_MUTE", "TOGGLE_MUTE", "TOGGLE_DEAFEN", "TOGGLE_VOICE_MODE", "TOGGLE_STREAMER_MODE", "TOGGLE_GO_LIVE_STREAMING", "DISCONNECT_FROM_VOICE_CHANNEL", "NAVIGATE_BACK", "NAVIGATE_FORWARD"];
MAX_KEYBINDS :: 64;
ACTION_IDS :: #run -> [MAX_KEYBINDS]string { // select_field keeps its id
	out: [MAX_KEYBINDS]string;
	for * out it.* = sprint("kbaction%", it_index);
	return out;
};

Shortcut :: struct { key: platform.Key; mods: platform.Mod; mouse: platform.Mouse_Button; } // mouse Left = none
Keybind :: struct { action: Keybind_Action; sc: Shortcut; held: bool; }
Persisted_Keybind :: struct { action: string; shortcut: string; } // shortcut_name's text

kb: struct {
	list: [..]Keybind;
	recording := -1; // the entry the next press sets
	pending_mod: platform.Key; // recording: a modifier is down, alone so far
	global: platform.Global_Input;
};

keybinds_reset_for_test :: () { array_reset(*kb.list); kb = .{}; }

// shortcut_name: "Ctrl+Shift+A", "Mouse4", or "" when unbound. shortcut_parse reads it back.
shortcut_name :: (sc: Shortcut) -> string {
	if sc.mouse != .Left return tprint("Mouse%", cast(int) sc.mouse + 1);
	if sc.key == .None return "";
	sb: String_Builder;
	sb.allocator = temp;
	for m: platform.Mod.[.Ctrl, .Alt, .Shift, .Cmd] if sc.mods & m print_to_builder(*sb, "%+", m);
	print_to_builder(*sb, "%", sc.key);
	return builder_to_string(*sb,, temp);
}

shortcut_parse :: (s: string) -> Shortcut {
	sc: Shortcut;
	parts := split(s, "+",, temp);
	for parts {
		if it_index < parts.count - 1 {
			for m: platform.Mod.[.Ctrl, .Alt, .Shift, .Cmd] if it == tprint("%", m) sc.mods |= m;
		} else if begins_with(it, "Mouse") {
			n := string_to_int(advance(it, 5));
			if n >= 3 && n <= 5 sc.mouse = cast(platform.Mouse_Button) (n - 1);
		} else {
			for enum_names(platform.Key) if it == parts[parts.count - 1] sc.key = cast(platform.Key) enum_values_as_s64(platform.Key)[it_index];
		}
	}
	return sc;
}

bound :: (sc: Shortcut) -> bool { return sc.key != .None || sc.mouse != .Left; }

// legacy_ptt: Voice & Video's own key from before Keybinds, taken when the file has none.
keybinds_restore :: (p: []Persisted_Keybind, legacy_ptt: string) {
	array_reset(*kb.list);
	for p {
		if kb.list.count == MAX_KEYBINDS break;
		a: Keybind_Action;
		for n, i: KEYBIND_NAMES if n == it.action a = xx i;
		array_add(*kb.list, .{action = a, sc = shortcut_parse(it.shortcut)});
	}
	if !p.count && legacy_ptt array_add(*kb.list, .{action = .Push_To_Talk, sc = shortcut_parse(legacy_ptt)});
}

keybinds_snapshot :: () -> []Persisted_Keybind {
	out := NewArray(kb.list.count, Persisted_Keybind,, temp);
	for kb.list out[it_index] = .{KEYBIND_NAMES[it.action], shortcut_name(it.sc)};
	return out;
}

// The first Push to Talk keybind (Voice & Video's Shortcut), made when add and there is none; -1 if none.
ptt_keybind :: (add := false) -> int {
	for kb.list if it.action == .Push_To_Talk return it_index;
	if !add || kb.list.count == MAX_KEYBINDS return -1;
	array_add(*kb.list, .{action = .Push_To_Talk});
	return kb.list.count - 1;
}

// keybinds_frame: global input on while any keybind can act, then this frame's presses: recording, or
// running actions. Global events cover the focused window too, so window events count only without them.
keybinds_frame :: () {
	want := false;
	for kb.list if bound(it.sc) && (it.action != .Push_To_Talk || vs.ptt_mode) want = true;
	kb.global = platform.set_global_input(want);
	global := kb.global == .On;
	if kb.recording >= kb.list.count kb.recording = -1;
	for e: platform.events() {
		if kb.recording >= 0 { record(e); continue; }
		down: bool;
		if e.kind == {
		case .Key_Down; #through; case .Mouse_Down; if global || e.is_repeat continue; down = true;
		case .Key_Up; #through; case .Mouse_Up; if global continue;
		case .Global_Key_Down; #through; case .Global_Mouse_Down; down = true;
		case .Global_Key_Up; #through; case .Global_Mouse_Up;
		case .Focus_Lost; if !global for * kb.list it.held = false; continue;
		case; continue;
		}
		is_mouse := e.kind == .Mouse_Down || e.kind == .Mouse_Up || e.kind == .Global_Mouse_Down || e.kind == .Global_Mouse_Up;
		if is_mouse && e.button < .Middle continue;
		for * kb.list {
			hit := ifx is_mouse then it.sc.mouse != .Left && e.button == it.sc.mouse else it.sc.key != .None && e.key == it.sc.key;
			if !hit continue;
			if !down { it.held = false; continue; }
			if it.held || (!is_mouse && (e.mods & it.sc.mods) != it.sc.mods) continue;
			it.held = true;
			keybind_run(it.action);
		}
	}
	vs.ptt_held, vs.ptm_held = false, false;
	for kb.list if it.held {
		if it.action == .Push_To_Talk vs.ptt_held = true;
		if it.action == .Push_To_Mute vs.ptm_held = true;
	}
}

#scope_file

// Recording: a key sets the shortcut with the modifiers held; a modifier pressed and let go alone sets
// itself; a middle or side button sets itself; Escape stops.
record :: (e: platform.Event) {
	sc := *kb.list[kb.recording].sc;
	if e.kind == {
	case .Key_Down;
		if e.key == .None || e.is_repeat return;
		if e.key == .Shift || e.key == .Ctrl || e.key == .Alt || e.key == .Cmd { kb.pending_mod = e.key; return; }
		if e.key != .Escape sc.* = .{key = e.key, mods = e.mods};
	case .Key_Up;
		if e.key != kb.pending_mod || e.key == .None return;
		sc.* = .{key = e.key};
	case .Mouse_Down;
		if e.button < .Middle return;
		sc.* = .{mouse = e.button};
	case; return;
	}
	kb.recording, kb.pending_mod = -1, platform.Key.None;
}

keybind_run :: (a: Keybind_Action) {
	if a == {
	case .Toggle_Mute; toggle_self_mute();
	case .Toggle_Deafen; app.self_deaf = !app.self_deaf;
	case .Toggle_Voice_Mode; vs.ptt_mode = !vs.ptt_mode;
	case .Toggle_Streamer_Mode; streamer_settings.enabled = !streamer_settings.enabled;
	case .Toggle_Go_Live;
		if screen_sharing() go_live_stop();
		else if app.voice_channel { vid.picker_open = true; platform.window_show(); } // the source picker
	case .Disconnect; if app.voice_channel voice_leave_channel();
	case .Navigate_Back; #through; case .Navigate_Forward; history_step(a == .Navigate_Forward, "keybind");
	}
}

#scope_export

// The Keybinds page: Add a Keybind, one card per keybind (action, shortcut, remove), then the built-in
// shortcuts, which can't be changed.
keybinds_page :: () {
	if !set_page_begin("keybindspage") return;
	defer set_page_end();
	h := row("head");
	h.semantic_size = .[ui.pct(1), ui.px(38)];
	{ ui.parent(h); defer ui.pop_parent();
		label("Keybinds", .Semibold, 20, T("--text-strong"), 24);
		filler(.X);
		if set_button("Add a Keybind##kbadd", .Primary, kb.list.count < MAX_KEYBINDS) {
			array_add(*kb.list, .{});
			kb.recording = -1;
		}
	}
	spacer(.Y, 12);
	set_para("kbhelp", "Keybinds work in every app, also while fastcord is in the background.", .Normal, 14, 18, T("--text-muted"));
	global_input_notice();
	spacer(.Y, 20);
	drop_i := -1;
	for * k, i: kb.list {
		ui.id_scope(xx (i + 1)); defer ui.pop_seed();
		card := row("card", .Draw_Background | .Draw_Border);
		card.semantic_size = .[ui.pct(1), ui.children()];
		card.cross_align = .Start;
		card.style.bg = T("--background-base-lower");
		card.style.border = 1;
		card.style.border_color = T("--border-subtle");
		card.style.radius = all4(8);
		{ ui.parent(card); defer ui.pop_parent();
			spacer(.X, 16);
			col_w := (set_content_w() - 16 * 3 - 24) / 2;
			for part: 0..1 {
				c := ui.box(ifx part then "kcol" else "acol");
				c.semantic_size = .[ui.px(col_w), ui.children()];
				c.layout_axis = .Y;
				{ ui.parent(c); defer ui.pop_parent();
					spacer(.Y, 16);
					label(ifx part then "KEYBIND" else "ACTION", .Bold, 12, T("--text-muted"), 16);
					spacer(.Y, 8);
					if part shortcut_field(i, col_w);
					else {
						pick := select_field(ACTION_IDS[i], KEYBIND_LABELS, xx k.action);
						if pick >= 0 { k.action = xx pick; k.held = false; }
					}
					spacer(.Y, 16);
				}
				spacer(.X, 16);
			}
			xc := ui.box("xcol");
			xc.semantic_size = .[ui.px(24), ui.children()];
			xc.layout_axis = .Y;
			ui.parent(xc); defer ui.pop_parent();
			spacer(.Y, 8);
			x := ui.box("remove", .Clickable);
			x.semantic_size = .[ui.px(24), ui.px(24)];
			x.hover_cursor = .Pointer;
			xs := ui.signal(x);
			set_icon(x, "x-small", ifx xs.hovering then T("--status-danger") else T("--interactive-icon-default"));
			if xs.clicked drop_i = i;
		}
		spacer(.Y, 12);
	}
	if drop_i >= 0 {
		array_ordered_remove_by_index(*kb.list, drop_i);
		kb.recording = -1;
		select_close();
	}
	set_divider();
	label("DEFAULT KEYBINDS", .Bold, 12, T("--text-muted"), 16);
	spacer(.Y, 8);
	for i: 0..DEFAULT_SHORTCUTS.count / 2 - 1 {
		r := row(tprint("def%", i));
		r.semantic_size = .[ui.pct(1), ui.px(36)];
		r.cross_align = .Center;
		ui.parent(r); defer ui.pop_parent();
		label(DEFAULT_SHORTCUTS[2 * i], .Normal, 15, T("--text-default"), 20);
		filler(.X);
		key_caps(DEFAULT_SHORTCUTS[2 * i + 1]);
	}
}

// The shortcut box of entry i: click to record, again to stop.
shortcut_field :: (i: int, w: float32) {
	rec := kb.recording == i;
	b := field_box("rec", rec);
	b.semantic_size[0] = ui.px(w);
	if ui.signal(b).clicked { kb.recording = ifx rec then -1 else i; kb.pending_mod = platform.Key.None; }
	ui.parent(b); defer ui.pop_parent();
	spacer(.X, 12);
	name := shortcut_name(kb.list[i].sc);
	if !name name = "No Keybind Set";
	if rec name = "Press a shortcut…";
	label(name, .Medium, 16, T("--text-default"), 20).flags |= .Clip;
	filler(.X);
	label(ifx rec then "Stop Recording" else "Record Keybind", .Semibold, 14, T("--text-strong"), 18);
	spacer(.X, 12);
}

// Without global input, why, and on macOS how to allow it.
global_input_notice :: () {
	if kb.global != .No_Permission && kb.global != .Unavailable return;
	spacer(.Y, 12);
	n := row("ginotice", .Draw_Background);
	n.semantic_size = .[ui.pct(1), ui.children()];
	n.cross_align = .Center;
	n.style.bg = with_alpha(T("--status-warning"), 0.12);
	n.style.radius = all4(8);
	ui.parent(n); defer ui.pop_parent();
	spacer(.X, 12);
	icon("warn", "warning", 20, T("--status-warning"));
	spacer(.X, 10);
	c := ui.box("t");
	c.semantic_size = .[ui.fill(), ui.children()];
	c.layout_axis = .Y;
	{ ui.parent(c); defer ui.pop_parent();
		spacer(.Y, 10);
		set_para("p", ifx kb.global == .No_Permission
			then "Keybinds only work while fastcord is focused. To use them in other apps, allow fastcord under Input Monitoring in System Settings, then restart fastcord."
			else "Keybinds only work while fastcord is focused: this desktop doesn't let apps see keys pressed in other windows.", .Normal, 14, 18, T("--text-default"));
		spacer(.Y, 10);
	}
	if kb.global == .No_Permission {
		spacer(.X, 12);
		if set_button("Open Settings##giperm", .Secondary, true, 32) platform.request_global_input_permission();
	}
	spacer(.X, 12);
}

keybinds_capturing :: () -> bool { return kb.recording >= 0; } // Escape stops recording

// A 40 px bordered field (the client's select / recorder look); red while recording.
field_box :: (id: string, hot: bool) -> *ui.Box {
	b := row(id, .Clickable | .Draw_Background | .Draw_Border);
	b.semantic_size = .[ui.pct(1), ui.px(40)];
	b.style.radius = all4(8);
	b.style.border = 1;
	b.style.border_color = ifx hot then T("--status-danger") else T("--border-subtle");
	b.style.bg = T("--background-base-lowest");
	b.hover_cursor = .Pointer;
	return b;
}

// A shortcut drawn as a key cap.
key_caps :: (keys: string) {
	k := ui.box(tprint("%##keys", keys), .Draw_Background | .Draw_Text);
	k.semantic_size = .[ui.text_size(16), ui.px(24)];
	k.style.bg = T("--background-mod-strong");
	k.style.radius = all4(4);
	k.style.font = F(.Semibold);
	k.style.font_size = 13;
	k.style.text_color = T("--text-strong");
	k.style.text_align = .Center;
}
