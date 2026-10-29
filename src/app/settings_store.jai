// Local (device) settings, persisted like the official client's localStorage
// stores (MediaEngineStore, SoundpackStore, NotificationSettingsStore,
// SelectedChannelStore, window bounds) to
// <state>/settings.json, written atomically (tmp + rename) when changed.
//
// Synced to the server instead (settings-proto, library side): theme
// (dc.set_theme on change, server value applied on READY / updates), guild
// folders, status, custom status. Everything below is device-local in the
// official client too.
//
// The file is written as Odin's json.marshal(pretty, sort_maps_by_key) wrote it, byte for byte: struct
// fields in declaration order, tab indents, map keys sorted, floats with 8 decimals.

SETTINGS_FILE :: "settings.json";
SETTINGS_VERSION :: 1;

Persisted_Voice :: struct {
	input_device: string; // CoreAudio UID ("" = system default)
	output_device: string;
	input_volume: float32;
	output_volume: float32;
	auto_sens: bool;
	threshold_db: float32;
	echo: bool;
	noise: bool;
	agc: bool;
	soundboard_volume: float32 = 100;
	soundboard_mic: bool;
	mode: string; // "VOICE_ACTIVITY" | "PUSH_TO_TALK"
	ptt_key: string; // before Keybinds: its shortcut, moved to keybinds on load and no longer written
	ptt_delay_ms: int;
	user_volume: Table(string, float32);
	user_muted: Table(string, bool);
}

Persisted_Sounds :: struct {
	soundpack: string;
	disable_all: bool;
	disabled: []string;
}

// NotificationSettingsStore (desktop notifications, unread badge). Stored as
// "off" flags so a file without them reads as the client's defaults (on).
Persisted_Notify :: struct {
	desktop_off: bool;
	badge_off: bool;
	lotus: bool; // fastcord's Lotus Mode: no sounds, notifications, badges or unread marks
}

Persisted :: struct {
	version: int;
	theme: string;
	theme_follow_os: bool; // Appearance > "Same as Device Theme"
	smooth_scroll_off: bool; // Appearance > "Smooth Scrolling" (fastcord's own), off
	start_minimized: bool; // System > Start Minimized (Windows)
	tray_close_off: bool; // System > Minimize to Tray, off
	install_declined: bool; // Not Now on the Windows install bar (update.jai)
	zoom: int = 100; // Accessibility > Zoom level, percent (ZOOM_SCALES)
	notify: Persisted_Notify;
	voice: Persisted_Voice;
	sounds: Persisted_Sounds;
	nsfw_agreed: []string; // guild ids whose age-restricted channels you agreed to see
	search_history: []string; // recent searches, newest first
	last_channel: Table(string, string); // guild ("0" = home) -> channel
	route_guild: string; // the open route, reopened at the next launch (start_guild / start_channel)
	route_channel: string;
	window_width: int;
	window_height: int;
	sidebar_width: float32;
	member_list_width: float32;
	streamer: Streamer_Settings;
	video_volume: float32 = 1; // the video player's, 0..4
	video_muted: bool;
	members_hidden: bool; // the member list toggle (shown by default)
	dm_profile_hidden: bool;
	window: Persisted_Window; // the restored rect and maximized state (platform.Window_Placement)
	hosted_servers: []string; // fc:// invites of joined self-hosted servers (hosted.jai)
	hosted_names: Table(string, string); // self-hosted server ID (hex) -> its name, shown while it is down
	drafts: Table(string, string); // channel -> unsent composer text, kept across restarts (not encrypted DMs')
	keybinds: []Persisted_Keybind; // Settings > Keybinds (keybinds.jai)
}

DRAFTS_MAX :: 100;
DRAFT_MAX_BYTES :: 16_000;

Persisted_Window :: struct { x, y, width, height: int; maximized: bool; } // screen pixels; width 0 = none

// theme to apply after theme_load at startup (main applies opt.theme first)
app_theme_pending: Theme_Name;
app_theme_pending_set: bool;

notify_prefs: Persisted_Notify;
theme_follow_os: bool;
smooth_scroll_off: bool;
start_minimized, tray_close_off: bool;
system_reduce_motion: bool; // polled by settings_frame; implies no smooth scrolling

app_state_dir :: (allocator := temp) -> string {
	if env_var("FASTCORD_STATE") return copy_string(env_var("FASTCORD_STATE"),, allocator); // a test account's state (site videos)
	return app_data_dir("state", allocator);
}

// settings_load: called once at startup (before the window opens: it may
// return a saved window size). Never touches the network.
settings_load :: (headless: bool) -> int, int {
	if headless return 0, 0; // screenshots / e2e scripts run with defaults (and never save)
	w, h := settings_load_from(app_state_dir());
	return w, h;
}

settings_load_from :: (dir: string) -> int, int {
	free(st.dir);
	st.dir = copy_string(dir);
	path := tprint("%/%", st.dir, SETTINGS_FILE);
	// The file, else a write a crash cut short of its rename (write_durable's .new, the old .tmp). One
	// that doesn't parse is moved aside, never replaced by defaults: it may hold the only copy of the
	// joined self-hosted servers.
	data: string;
	v: etf.Value;
	for name: string.[path, tprint("%.new", path), tprint("%.tmp", path)] {
		d, ok := read_entire_file(name, log_errors = false,, temp);
		if !ok continue;
		val, err := etf.from_json(d,, temp);
		if err == .None && val.kind == .Map {
			data, v = d, val;
			break;
		}
		if name == path file_move(path, tprint("%.unreadable-%", path, current_time_consensus().low));
	}
	if !data return 0, 0;
	p := Persisted.{streamer = STREAMER_DEFAULTS}; // fields missing from older files keep their defaults
	{
		push_allocator(temp);
		read_json(v, Any.{type_info(Persisted), *p});
	}
	free(st.last_json);
	st.last_json = copy_string(data);
	apply_persisted(*p);
	return p.window_width, p.window_height;
}

theme_by_name :: (s: string) -> Theme_Name, bool {
	for enum_names(Theme_Name) if it == s return cast(Theme_Name) enum_values_as_s64(Theme_Name)[it_index], true;
	return .Light, false;
}

device_uid :: (input: bool) -> string {
	sel := audio.selected_device(input);
	if sel == 0 return "";
	for audio.list_devices(input, temp) if it.id == sel return it.uid;
	return "";
}

device_by_uid :: (input: bool, uid: string) -> u32 {
	if uid == "" return 0;
	for audio.list_devices(input, temp) if it.uid == uid return it.id;
	return 0;
}

// settings_frame: theme sync + save when something changed (checked twice a second).
settings_frame :: () {
	app.ui.instant_scroll = smooth_scroll_off || system_reduce_motion;
	if platform.is_headless() return;
	theme_sync();
	now := platform.time_now();
	if now < st.next_check return;
	st.next_check = now + 0.5;
	system_reduce_motion = platform.system_a11y().reduce_motion;
	theme_follow_os_check();
	if !app.view.resizing settings_save(); // the official client saves a dragged width when the drag ends
}

// settings_save hands a changed snapshot to the saver thread, which writes it durably (synced, verified,
// renamed into place: keys.write_durable); the UI thread never waits on the disk. wait (quitting): until
// it is written.
settings_save :: (wait := false) {
	if st.dir == "" || platform.is_headless() return;
	js := snapshot();
	locks.lock(*st.mu);
	defer locks.unlock(*st.mu);
	if st.write_failed {
		free(st.last_json); // write it again
		st.last_json, st.write_failed = "", false;
	}
	if js != "" && js != st.last_json {
		free(st.last_json);
		st.last_json = copy_string(js);
		free(st.pending);
		st.pending = copy_string(js);
		if !st.saver st.saver = dc.spawn(st.dir, settings_saver);
		locks.cond_broadcast(*st.cond);
	}
	while wait && (st.pending || st.writing) locks.cond_wait(*st.cond, *st.mu);
}

settings_saver :: (dir: string) {
	locks.lock(*st.mu);
	while true {
		if !st.pending { locks.cond_wait(*st.cond, *st.mu); continue; }
		js := st.pending;
		st.pending, st.writing = "", true;
		locks.unlock(*st.mu);
		make_directory_if_it_does_not_exist(dir);
		ok := keys.write_durable(tprint("%/%", dir, SETTINGS_FILE), cast([]u8) js);
		reset_temporary_storage();
		locks.lock(*st.mu);
		st.writing = false;
		if !ok st.write_failed = true;
		free(js);
		locks.cond_broadcast(*st.cond);
	}
}

// Odin's json.marshal(v, {pretty = true, sort_maps_by_key = true}) of a struct of ints, floats,
// bools, strings, slices, structs and string-keyed Tables, in temp.
marshal_pretty :: (v: Any) -> string {
	b: String_Builder;
	b.allocator = temp;
	write_json(*b, v, 0);
	return builder_to_string(*b,, temp);
}

// ---- theme: local choice <-> settings-proto ----

// The visual refresh renamed the themes: its "Ash" is the classic dark theme
// (proto DARK = 1) and its "Dark" is theme-darker (proto DARKER = 3); see
// tools/probes/theme_tokens.js.
theme_to_proto :: (t: Theme_Name) -> dc.Theme {
	if t == {
	case .Light; return .Light;
	case .Ash;   return .Dark;
	case .Dark;  return .Darker;
	case .Onyx;  return .Midnight;
	}
	return .Darker;
}

theme_from_proto :: (t: dc.Theme) -> Theme_Name, bool {
	if t == {
	case .Light;    return .Light, true;
	case .Dark;     return .Ash, true;
	case .Darker;   return .Dark, true;
	case .Midnight; return .Onyx, true;
	}
	return .Dark, false;
}

// user picked a theme in Settings > Appearance: local + synced (like the client)
theme_set_by_user :: (t: Theme_Name) {
	theme_follow_os = false; // picking a theme turns "Same as Device Theme" off, like the client
	theme_load(*app.theme, t);
	if app.client != null {
		dc.set_theme(app.client, theme_to_proto(t));
		st.server_theme = theme_to_proto(t);
	}
}

// "Same as Device Theme": the OS's light/dark mode picks Light or Dark (local only;
// the synced theme is left as it was). Checked with the save, twice a second.
theme_follow_os_check :: () {
	if !theme_follow_os return;
	dark, ok := platform.system_dark_mode();
	if !ok return;
	want := ifx dark then Theme_Name.Dark else Theme_Name.Light;
	if want != app.theme.name theme_load(*app.theme, want);
}

// The toggle itself: on applies the OS mode at once.
// Turning it on writes the OS theme resolved to the proto (dark -> DARK 1, light -> LIGHT 2;
// fixture settings/appearance_sync_on); the sync flag itself stays local.
theme_follow_os_set :: (on: bool) {
	theme_follow_os = on;
	theme_follow_os_check();
	if on && app.client != null {
		dark, ok := platform.system_dark_mode();
		t := ifx dark || !ok then dc.Theme.Dark else dc.Theme.Light;
		dc.set_theme(app.client, t, system = true);
		st.server_theme = t;
	}
}

#scope_file

st: struct {
	dir: string;
	last_json: string; // the last snapshot handed to the saver (UI thread)
	mu: locks.Mutex; // pending, writing, write_failed
	cond: locks.Cond;
	saver: *Thread; // settings_saver, for the life of the process
	pending: string; // a snapshot the saver hasn't taken yet (its own copy)
	writing: bool;
	write_failed: bool;
	next_check: float64;
	server_theme: dc.Theme; // last server-synced value applied
};

apply_persisted :: (p: *Persisted) {
	t, ok := theme_by_name(p.theme);
	if ok app_theme_pending, app_theme_pending_set = t, true;
	theme_follow_os = p.theme_follow_os;
	smooth_scroll_off = p.smooth_scroll_off;
	start_minimized, tray_close_off = p.start_minimized, p.tray_close_off;
	platform.set_close_to_tray(!tray_close_off);
	install_declined = p.install_declined;
	zoom_set(p.zoom);
	notify_prefs = p.notify;
	voice_settings_restore(*p.voice);
	keybinds_restore(p.keybinds, p.voice.ptt_key);
	sounds_restore(*p.sounds);
	streamer_settings = p.streamer;
	video_volume = clamp(p.video_volume, 0, 4);
	video_muted = p.video_muted;
	app.view.hide_members = p.members_hidden;
	app.view.hide_dm_profile = p.dm_profile_hidden;
	hosted_restore(p.hosted_servers, *p.hosted_names);
	pw := p.window;
	if pw.width > 0 && pw.height > 0 platform.window_placement_restore(.{xx pw.x, xx pw.y, xx pw.width, xx pw.height, pw.maximized});
	if p.sidebar_width > 0 app.view.sidebar_w = clamp(p.sidebar_width, SIDEBAR_MIN_W, SIDEBAR_MAX_W);
	if p.member_list_width > 0 app.view.member_w = clamp(p.member_list_width, MEMBER_LIST_MIN_W, MEMBER_LIST_MAX_W);
	for p.search_history if it_index < SEARCH_HISTORY_MAX array_add(*search_history, copy_string(it));
	for p.nsfw_agreed {
		n, ok := dc.parse_u64(it);
		if ok table_set(*app.view.nsfw_agreed, cast(dc.Snowflake) n, true);
	}
	app.start_guild, app.start_channel = dc.parse_snowflake(p.route_guild), dc.parse_snowflake(p.route_channel);
	for text, c: p.drafts {
		cid := dc.parse_snowflake(c);
		if cid && text.count <= DRAFT_MAX_BYTES ui.editor_set_text(*chat_state(cid).editor, text);
	}
	for c, g: p.last_channel {
		gn, ok1 := dc.parse_u64(g);
		cn, ok2 := dc.parse_u64(c);
		if ok1 && ok2 table_set(*app.view.last_channel, cast(dc.Snowflake) gn, cast(dc.Snowflake) cn);
	}
}

snapshot :: () -> string {
	push_allocator(temp);
	p: Persisted;
	p.version = SETTINGS_VERSION;
	p.theme = tprint("%", app.theme.name);
	p.theme_follow_os = theme_follow_os;
	p.smooth_scroll_off = smooth_scroll_off;
	p.start_minimized, p.tray_close_off = start_minimized, tray_close_off;
	p.install_declined = install_declined;
	p.zoom = zoom_pct;
	p.notify = notify_prefs;
	voice_settings_snapshot(*p.voice);
	sounds_snapshot(*p.sounds);
	na: [..]string;
	for _, id: app.view.nsfw_agreed array_add(*na, tprint("%", cast(u64) id));
	p.nsfw_agreed = na;
	p.search_history = search_history;
	for c, g: app.view.last_channel if c != 0 table_set(*p.last_channel, tprint("%", cast(u64) g), tprint("%", cast(u64) c));
	if app.view.channel p.route_guild, p.route_channel = tprint("%", cast(u64) app.view.guild), tprint("%", cast(u64) app.view.channel);
	ws := platform.window_size();
	p.window_width = cast(int) ws.x;
	p.window_height = cast(int) ws.y;
	p.sidebar_width = app.view.sidebar_w;
	p.member_list_width = app.view.member_w;
	p.streamer = streamer_settings;
	p.video_volume = video_volume;
	p.video_muted = video_muted;
	p.members_hidden = app.view.hide_members;
	p.dm_profile_hidden = app.view.hide_dm_profile;
	p.hosted_servers = hosted_invites();
	p.hosted_names = hosted_names();
	for * cs, cid: app.chats {
		text := ui.editor_text(*cs.editor);
		ch := dc.channel_get(store(), cid);
		if !text || text.count > DRAFT_MAX_BYTES || p.drafts.count >= DRAFTS_MAX || (ch && encrypted_dm(ch)) continue;
		table_set(*p.drafts, tprint("%", cast(u64) cid), text);
	}
	p.keybinds = keybinds_snapshot();
	wp, ok := platform.window_placement();
	if ok p.window = .{wp.x, wp.y, wp.width, wp.height, wp.maximized};
	return marshal_pretty(p);
}

theme_sync :: () {
	if app.client == null || !app.client.store.ready || theme_follow_os return;
	srv := app.client.store.settings.theme;
	if srv == st.server_theme return;
	st.server_theme = srv;
	t, ok := theme_from_proto(srv);
	if ok && t != app.theme.name theme_load(*app.theme, t);
}

// ---- JSON <-> struct, by type info ----

write_json :: (b: *String_Builder, v: Any, depth: int) {
	p := v.value_pointer;
	if v.type.type == {
	case .INTEGER; print_to_builder(b, "%", v);
	case .BOOL;    append(b, ifx (cast(*bool) p).* then "true" else "false");
	case .STRING;  write_quoted(b, (cast(*string) p).*);
	case .FLOAT;
		// Odin writes a float as %.<2 * size>f of its exact value (C's printf rounds the same way).
		buf: [512]u8;
		if v.type.runtime_size == 4 snprintf(buf.data, buf.count, "%.8f", cast(float64) (cast(*float32) p).*);
		else snprintf(buf.data, buf.count, "%.16f", (cast(*float64) p).*);
		append(b, to_string(buf.data));
	case .ARRAY;
		ai := cast(*Type_Info_Array) v.type;
		count, data := ai.array_count, p;
		if ai.array_type != .FIXED count, data = (cast(*[]u8) p).count, (cast(*[]u8) p).data;
		append(b, "[\n");
		for 0..count - 1 {
			if it append(b, ",\n");
			indent(b, depth + 1);
			write_json(b, Any.{ai.element_type, data + it * ai.element_type.runtime_size}, depth + 1);
		}
		close(b, "]", depth);
	case .STRUCT;
		if v.type == cast(*Type_Info) type_info(Table(string, float32)) { write_table(b, cast(*Table(string, float32)) p, depth); return; }
		if v.type == cast(*Type_Info) type_info(Table(string, bool))    { write_table(b, cast(*Table(string, bool)) p, depth); return; }
		if v.type == cast(*Type_Info) type_info(Table(string, string))  { write_table(b, cast(*Table(string, string)) p, depth); return; }
		append(b, "{\n");
		n := 0;
		for m: (cast(*Type_Info_Struct) v.type).members {
			if m.flags & .CONSTANT continue;
			if n append(b, ",\n");
			n += 1;
			indent(b, depth + 1);
			write_quoted(b, m.name);
			append(b, ": ");
			write_json(b, Any.{m.type, p + m.offset_in_bytes}, depth + 1);
		}
		close(b, "}", depth);
	case; append(b, "null");
	}
}

write_table :: (b: *String_Builder, t: *Table(string, $V), depth: int) {
	keys: [..]string;
	keys.allocator = temp;
	for t.* array_add(*keys, it_index);
	quick_sort(keys, compare_strings);
	append(b, "{\n");
	for keys {
		if it_index append(b, ",\n");
		indent(b, depth + 1);
		write_quoted(b, it);
		append(b, ": ");
		write_json(b, table_find_pointer(t, it).*, depth + 1);
	}
	close(b, "}", depth);
}

indent :: (b: *String_Builder, depth: int) { for 1..depth append(b, #char "\t"); }

// Odin ends every object and array, even an empty one, with a newline and the closing indent.
close :: (b: *String_Builder, bracket: string, depth: int) {
	append(b, #char "\n");
	indent(b, depth);
	append(b, bracket);
}

// Quoted like Odin's marshal for ASCII (\" \\ \b \f \n \r \t, other controls and DEL as \u00xx).
// Bytes >= 0x80 are copied (Odin also escapes non-printable runes; both read back the same).
write_quoted :: (b: *String_Builder, s: string) {
	append(b, #char "\"");
	for cast([]u8) s {
		if it == {
		case #char "\""; append(b, "\\\"");
		case #char "\\"; append(b, "\\\\");
		case 8;          append(b, "\\b");
		case 12;         append(b, "\\f");
		case #char "\n"; append(b, "\\n");
		case #char "\r"; append(b, "\\r");
		case #char "\t"; append(b, "\\t");
		case;
			if it < 0x20 || it == 0x7f print_to_builder(b, "\\u%", formatInt(it, base = 16, minimum_digits = 4));
			else append(b, it);
		}
	}
	append(b, #char "\"");
}

// Fills what the JSON has; anything missing or of another kind keeps its value. Allocates in context.
read_json :: (v: etf.Value, dst: Any, depth := 0) {
	assert(depth < 16); // follows Persisted's own nesting, whatever the file holds
	p := dst.value_pointer;
	if dst.type.type == {
	case .INTEGER;
		if v.kind != .Int && v.kind != .Float return;
		n := ifx v.kind == .Int then v.i else cast(s64) v.f;
		memcpy(p, *n, dst.type.runtime_size);
	case .FLOAT;
		if v.kind != .Int && v.kind != .Float return;
		f := ifx v.kind == .Float then v.f else cast(float64) v.i;
		if dst.type.runtime_size == 4 { (cast(*float32) p).* = cast(float32) f; }
		else { (cast(*float64) p).* = f; }
	case .BOOL;
		if v.kind == .Bool { (cast(*bool) p).* = v.b; }
	case .STRING;
		if v.kind == .String { (cast(*string) p).* = copy_string(v.s); }
	case .ARRAY;
		ai := cast(*Type_Info_Array) dst.type;
		if v.kind != .List || ai.array_type == .FIXED return;
		size := ai.element_type.runtime_size;
		data := alloc(v.list.count * size);
		memset(data, 0, v.list.count * size);
		for v.list read_json(it, Any.{ai.element_type, data + it_index * size}, depth + 1);
		a := cast(*Resizable_Array) p;
		a.data, a.count = data, v.list.count;
		if ai.array_type == .RESIZABLE a.allocated, a.allocator = v.list.count, context.allocator;
	case .STRUCT;
		if v.kind != .Map return;
		if dst.type == cast(*Type_Info) type_info(Table(string, float32)) { read_table(v, cast(*Table(string, float32)) p, depth); return; }
		if dst.type == cast(*Type_Info) type_info(Table(string, bool))    { read_table(v, cast(*Table(string, bool)) p, depth); return; }
		if dst.type == cast(*Type_Info) type_info(Table(string, string))  { read_table(v, cast(*Table(string, string)) p, depth); return; }
		for m: (cast(*Type_Info_Struct) dst.type).members {
			if m.flags & .CONSTANT continue;
			x, ok := etf.map_get(v.map, m.name);
			if ok read_json(x, Any.{m.type, p + m.offset_in_bytes}, depth + 1);
		}
	}
}

read_table :: (v: etf.Value, t: *Table(string, $V), depth: int) {
	for v.map {
		if it.key.kind != .String continue;
		x: V;
		read_json(it.value, Any.{type_info(V), *x}, depth + 1);
		table_set(t, copy_string(it.key.s), x);
	}
}

#if OS == .WINDOWS {
    legacy_stdio :: #library,system,no_dll,link_always "legacy_stdio_definitions"; // _snprintf on the UCRT
    legacy_wide :: #library,system,no_dll,link_always "legacy_stdio_wide_specifiers";
    snprintf :: (buf: *u8, n: u64, format: *u8, args: ..Any) -> s32 #foreign legacy_stdio "_snprintf";
} else {
    snprintf :: (buf: *u8, n: u64, format: *u8, args: ..Any) -> s32 #foreign libc;
}
