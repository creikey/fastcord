package app

import "core:encoding/json"
import "core:os"
import "core:reflect"
import "core:strconv"
import "core:strings"
import "fc:audio"
import dc "fc:discord"
import "fc:platform"

// Local (device) settings, persisted like the official client's localStorage
// stores (MediaEngineStore, SoundpackStore, NotificationSettingsStore,
// collapsed categories, SelectedChannelStore, window bounds) to
// <state>/settings.json, written atomically (tmp + rename) when changed.
//
// Synced to the server instead (settings-proto, library side): theme
// (dc.set_theme on change, server value applied on READY / updates), guild
// folders, status, custom status. Everything below is device-local in the
// official client too.

SETTINGS_FILE :: "settings.json"
SETTINGS_VERSION :: 1

Persisted_Voice :: struct {
	input_device:  string, // CoreAudio UID ("" = system default)
	output_device: string,
	input_volume:  f32,
	output_volume: f32,
	auto_sens:     bool,
	threshold_db:  f32,
	echo:          bool,
	noise:         bool,
	agc:           bool,
	mode:          string, // "VOICE_ACTIVITY" | "PUSH_TO_TALK"
	ptt_key:       string, // platform.Key name
	ptt_delay_ms:  int,
	user_volume:   map[string]f32,
	user_muted:    map[string]bool,
}

Persisted_Sounds :: struct {
	soundpack:    string,
	disable_all:  bool,
	disabled:     []string,
}

Persisted :: struct {
	version:       int,
	theme:         string,
	voice:         Persisted_Voice,
	sounds:        Persisted_Sounds,
	collapsed:     []string, // category ids
	last_channel:  map[string]string, // guild ("0" = home) -> channel
	window_width:  int,
	window_height: int,
	sidebar_width: f32,
}

@(private = "file")
st: struct {
	dir:         string,
	last_json:   string, // what is on disk
	loaded:      bool,
	next_check:  f64,
	server_theme: dc.Theme, // last server-synced value applied
	theme_from_user: bool,
}

app_state_dir :: proc(allocator := context.temp_allocator) -> string {
	return app_data_dir("state", allocator)
}

// settings_load: called once at startup (before the window opens: it may
// return a saved window size). Never touches the network.
settings_load :: proc(headless: bool) -> (window_w, window_h: int) {
	if headless do return // screenshots / e2e scripts run with defaults (and never save)
	return settings_load_from(app_state_dir())
}

settings_load_from :: proc(dir: string) -> (window_w, window_h: int) {
	delete(st.dir)
	st.dir = strings.clone(dir)
	data, err := os.read_entire_file(strings.concatenate({st.dir, "/", SETTINGS_FILE}, context.temp_allocator), context.temp_allocator)
	if err != nil do return
	p: Persisted
	if json.unmarshal(data, &p, allocator = context.temp_allocator) != nil do return
	st.loaded = true
	st.last_json = strings.clone(string(data))
	apply_persisted(&p)
	return p.window_width, p.window_height
}

theme_by_name :: proc(s: string) -> (Theme_Name, bool) {
	return reflect.enum_from_name(Theme_Name, s)
}

@(private = "file")
apply_persisted :: proc(p: ^Persisted) {
	if t, ok := theme_by_name(p.theme); ok do app_theme_pending = t
	v := &p.voice
	voice_settings_restore(v)
	sounds_restore(&p.sounds)
	for id in p.collapsed {
		n, ok := strconv.parse_u64(id)
		if ok do app.view.collapsed[dc.Snowflake(n)] = true
	}
	for g, c in p.last_channel {
		gn, ok1 := strconv.parse_u64(g)
		cn, ok2 := strconv.parse_u64(c)
		if ok1 && ok2 do app.view.last_channel[dc.Snowflake(gn)] = dc.Snowflake(cn)
	}
}

// theme to apply after theme_load at startup (main applies opt.theme first)
app_theme_pending: Maybe(Theme_Name)

device_uid :: proc(input: bool) -> string {
	sel := audio.selected_device(input)
	if sel == 0 do return ""
	for d in audio.list_devices(input, context.temp_allocator) do if d.id == sel do return d.uid
	return ""
}

device_by_uid :: proc(input: bool, uid: string) -> u32 {
	if uid == "" do return 0
	for d in audio.list_devices(input, context.temp_allocator) do if d.uid == uid do return d.id
	return 0
}

@(private = "file")
snapshot :: proc() -> string {
	p: Persisted
	p.version = SETTINGS_VERSION
	p.theme, _ = reflect.enum_name_from_value(app.theme.name)
	voice_settings_snapshot(&p.voice)
	sounds_snapshot(&p.sounds)
	col := make([dynamic]string, 0, len(app.view.collapsed), context.temp_allocator)
	for id, on in app.view.collapsed do if on do append(&col, snowflake_str(id))
	p.collapsed = col[:]
	p.last_channel = make(map[string]string, len(app.view.last_channel), context.temp_allocator)
	for g, c in app.view.last_channel do if c != 0 do p.last_channel[snowflake_str(g)] = snowflake_str(c)
	ws := platform.window_size()
	p.window_width = int(ws.x)
	p.window_height = int(ws.y)
	p.sidebar_width = SIDEBAR_W
	b, err := json.marshal(p, {pretty = true, sort_maps_by_key = true}, context.temp_allocator)
	if err != nil do return ""
	return string(b)
}

@(private = "file")
snowflake_str :: proc(id: dc.Snowflake) -> string {
	buf: [24]byte
	return strings.clone(strconv.write_uint(buf[:], u64(id), 10), context.temp_allocator)
}

// settings_frame: theme sync + save when something changed (checked twice a second).
settings_frame :: proc() {
	if platform.is_headless() do return
	theme_sync()
	now := platform.time_now()
	if now < st.next_check do return
	st.next_check = now + 0.5
	settings_save()
}

settings_save :: proc() {
	if st.dir == "" || platform.is_headless() do return
	js := snapshot()
	if js == "" || js == st.last_json do return
	os.make_directory(st.dir)
	path := strings.concatenate({st.dir, "/", SETTINGS_FILE}, context.temp_allocator)
	tmp := strings.concatenate({path, ".tmp"}, context.temp_allocator)
	if os.write_entire_file(tmp, transmute([]byte)js) != nil do return
	if os.rename(tmp, path) != nil do return
	delete(st.last_json)
	st.last_json = strings.clone(js)
}

// ---- theme: local choice <-> settings-proto ----

// The visual refresh renamed the themes: its "Ash" is the classic dark theme
// (proto DARK = 1) and its "Dark" is theme-darker (proto DARKER = 3); see
// tools/probes/theme_tokens.js.
theme_to_proto :: proc(t: Theme_Name) -> dc.Theme {
	switch t {
	case .Light:
		return .Light
	case .Ash:
		return .Dark
	case .Dark:
		return .Darker
	case .Onyx:
		return .Midnight
	}
	return .Darker
}

theme_from_proto :: proc(t: dc.Theme) -> (Theme_Name, bool) {
	#partial switch t {
	case .Light:
		return .Light, true
	case .Dark:
		return .Ash, true
	case .Darker:
		return .Dark, true
	case .Midnight:
		return .Onyx, true
	}
	return .Dark, false
}

// user picked a theme in Settings > Appearance: local + synced (like the client)
theme_set_by_user :: proc(t: Theme_Name) {
	theme_load(&app.theme, t)
	if app.client != nil {
		dc.set_theme(app.client, theme_to_proto(t))
		st.server_theme = theme_to_proto(t)
	}
}

@(private = "file")
theme_sync :: proc() {
	if app.client == nil || !app.client.store.ready do return
	srv := app.client.store.settings.theme
	if srv == st.server_theme do return
	st.server_theme = srv
	if t, ok := theme_from_proto(srv); ok && t != app.theme.name do theme_load(&app.theme, t)
}
