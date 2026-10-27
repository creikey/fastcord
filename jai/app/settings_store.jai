// Local (device) settings, persisted like the official client's localStorage
// stores (MediaEngineStore, SoundpackStore, NotificationSettingsStore,
// collapsed categories, SelectedChannelStore, window bounds) to
// <state>/settings.json, written atomically (tmp + rename) when changed.
//
// Synced to the server instead (settings-proto, library side): theme
// (dc.set_theme on change, server value applied on READY / updates), guild
// folders, status, custom status. Everything below is device-local in the
// official client too.

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
	mode: string; // "VOICE_ACTIVITY" | "PUSH_TO_TALK"
	ptt_key: string; // platform.Key name
	ptt_delay_ms: int;
	user_volume: Map(string, float32);
	user_muted: Map(string, bool);
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
}

Persisted :: struct {
	version: int;
	theme: string;
	theme_follow_os: bool; // Appearance > "Same as Device Theme"
	notify: Persisted_Notify;
	voice: Persisted_Voice;
	sounds: Persisted_Sounds;
	collapsed: []string; // category ids
	hide_muted: []string; // guild ids with "Hide Muted Channels" on
	last_channel: Map(string, string); // guild ("0" = home) -> channel
	window_width: int;
	window_height: int;
	sidebar_width: float32;
	streamer: Streamer_Settings;
}
#scope_file

st: struct {
	dir: string;
	last_json: string; // what is on disk
	loaded: bool;
	next_check: float64;
	server_theme: dc.Theme; // last server-synced value applied
	theme_from_user: bool;
};
#scope_export

app_state_dir :: (allocator := temp) -> string {
	return app_data_dir("state", allocator);
}

// settings_load: called once at startup (before the window opens: it may
// return a saved window size). Never touches the network.
settings_load :: (headless: bool) -> int, int {
	window_w: int;
	window_h: int;
	if headless { return window_w, window_h; } // screenshots / e2e scripts run with defaults (and never save)
	{ __r1, __r2 := settings_load_from(app_state_dir()); return __r1, __r2; }
}

settings_load_from :: (dir: string) -> int, int {
	window_w: int;
	window_h: int;
	delete(st.dir);
	st.dir = clone(dir);
	data, err := os.read_entire_file(strings.concatenate(.{st.dir, "/", SETTINGS_FILE}, temp), temp);
	if err != null { return window_w, window_h; }
	p := Persisted.{streamer = STREAMER_DEFAULTS}; // fields missing from older files keep their defaults
	if json.unmarshal(data, *p, allocator = temp) != null { return window_w, window_h; }
	st.loaded = true;
	st.last_json = clone(as_string(data));
	apply_persisted(*p);
	return p.window_width, p.window_height;
}

theme_by_name :: (s: string) -> Theme_Name, bool {
	{ __r3, __r4 := reflect.enum_from_name(Theme_Name, s); return __r3, __r4; }
}
#scope_file

apply_persisted :: (p: *Persisted) {
	{ t, ok := theme_by_name(p.theme);
	if ok { app_theme_pending = t; } }
	theme_follow_os = p.theme_follow_os;
	notify_prefs = p.notify;
	v := *p.voice;
	voice_settings_restore(v);
	sounds_restore(*p.sounds);
	streamer_settings = p.streamer;
	for id: p.collapsed {
		n, ok := strconv.parse_u64(id);
		if ok { at(*app.view.collapsed, cast(dc.Snowflake)(n)).* = true; }
	}
	for id: p.hide_muted {
		n, ok := strconv.parse_u64(id);
		if ok { at(*app.view.hide_muted, cast(dc.Snowflake)(n)).* = true; }
	}
	for g, c: p.last_channel {
		gn, ok1 := strconv.parse_u64(g);
		cn, ok2 := strconv.parse_u64(c);
		if ok1 && ok2 { at(*app.view.last_channel, cast(dc.Snowflake)(gn)).* = cast(dc.Snowflake)(cn); }
	}
}
#scope_export

// theme to apply after theme_load at startup (main applies opt.theme first)
app_theme_pending: Maybe(Theme_Name);

notify_prefs: Persisted_Notify;
theme_follow_os: bool;

device_uid :: (input: bool) -> string {
	sel := audio.selected_device(input);
	if sel == 0 { return ""; }
	for d: audio.list_devices(input, temp) { if d.id == sel { return d.uid; } }
	return "";
}

device_by_uid :: (input: bool, uid: string) -> u32 {
	if uid == "" { return 0; }
	for d: audio.list_devices(input, temp) { if d.uid == uid { return d.id; } }
	return 0;
}
#scope_file

snapshot :: () -> string {
	p: Persisted;
	p.version = SETTINGS_VERSION;
	p.theme, _ = reflect.enum_name_from_value(app.theme.name);
	p.theme_follow_os = theme_follow_os;
	p.notify = notify_prefs;
	voice_settings_snapshot(*p.voice);
	sounds_snapshot(*p.sounds);
	col := make_dynamic(string, 0, len(app.view.collapsed), temp);
	for id, on: app.view.collapsed { if on { append(*col, snowflake_str(id)); } }
	p.collapsed = view(col);
	hm := make_dynamic(string, 0, len(app.view.hide_muted), temp);
	for id, on: app.view.hide_muted { if on { append(*hm, snowflake_str(id)); } }
	p.hide_muted = view(hm);
	p.last_channel = Map(string, string).{};
	for g, c: app.view.last_channel { if c != 0 { at(*p.last_channel, snowflake_str(g)).* = snowflake_str(c); } }
	ws := platform.window_size();
	p.window_width = cast(int)(ws.x);
	p.window_height = cast(int)(ws.y);
	p.sidebar_width = SIDEBAR_W;
	p.streamer = streamer_settings;
	b, err := json.marshal(p, .{pretty = true, sort_maps_by_key = true}, temp);
	if err != null { return ""; }
	return as_string(b);
}

snowflake_str :: (id: dc.Snowflake) -> string {
	buf: [24]u8;
	return clone(strconv.write_uint(view(buf), cast(u64)(id), 10), temp);
}
#scope_export

// settings_frame: theme sync + save when something changed (checked twice a second).
settings_frame :: () {
	if platform.is_headless() { return; }
	theme_sync();
	now := platform.time_now();
	if now < st.next_check { return; }
	st.next_check = now + 0.5;
	theme_follow_os_check();
	settings_save();
}

settings_save :: () {
	if st.dir == "" || platform.is_headless() { return; }
	js := snapshot();
	if js == "" || js == st.last_json { return; }
	os.make_directory(st.dir);
	path := strings.concatenate(.{st.dir, "/", SETTINGS_FILE}, temp);
	tmp := strings.concatenate(.{path, ".tmp"}, temp);
	if os.write_entire_file(tmp, transmute([]u8, js)) != null { return; }
	if os.rename(tmp, path) != null { return; }
	delete(st.last_json);
	st.last_json = clone(js);
}

// ---- theme: local choice <-> settings-proto ----

// The visual refresh renamed the themes: its "Ash" is the classic dark theme
// (proto DARK = 1) and its "Dark" is theme-darker (proto DARKER = 3); see
// tools/probes/theme_tokens.js.
theme_to_proto :: (t: Theme_Name) -> dc.Theme {
	if t == {
	case .Light;
		return .Light;
	case .Ash;
		return .Dark;
	case .Dark;
		return .Darker;
	case .Onyx;
		return .Midnight;
	}
	return .Darker;
}

theme_from_proto :: (t: dc.Theme) -> Theme_Name, bool {
	if t == {
	case .Light;
		return .Light, true;
	case .Dark;
		return .Ash, true;
	case .Darker;
		return .Dark, true;
	case .Midnight;
		return .Onyx, true;
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
#scope_file

theme_sync :: () {
	if app.client == null || !app.client.store.ready || theme_follow_os { return; }
	srv := app.client.store.settings.theme;
	if srv == st.server_theme { return; }
	st.server_theme = srv;
	{ t, ok := theme_from_proto(srv);
	if ok && t != app.theme.name { theme_load(*app.theme, t); } }
}
#scope_export

// "Same as Device Theme": the OS's light/dark mode picks Light or Dark (local only;
// the synced theme is left as it was). Checked with the save, twice a second.
theme_follow_os_check :: () {
	if !theme_follow_os { return; }
	dark, ok := platform.system_dark_mode();
	if !ok { return; }
	want := ifx dark then Theme_Name.Dark else Theme_Name.Light;
	if want != app.theme.name { theme_load(*app.theme, want); }
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

