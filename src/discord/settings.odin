package discord

import "core:encoding/base64"
import "core:strings"
import "fc:etf"
import "fc:protobuf"

// PreloadedUserSettings writes (UserSettingsProtoStore.updateAsync):
// each change builds a *delta* proto (ProtoClass.create() + the edited
// fields), deltas are merged until the save timer fires, and the save is
//   PATCH /users/@me/settings-proto/1 {"settings":"<base64 delta>"}
// Timer per change kind (UserSettingsDelay): INFREQUENT_USER_ACTION 0 s
// (status, custom status, theme), FREQUENT_USER_ACTION 10 s (guild folders).
// protobuf-ts writes fields in number order and skips defaults.

SETTINGS_DELAY_INFREQUENT_MS :: 0
SETTINGS_DELAY_FREQUENT_MS :: 10_000

Custom_Status :: struct {
	text:          string,
	emoji_id:      Snowflake,
	emoji_name:    string,
	expires_at_ms: i64,
	clear_after:   Clear_After, // the modal's "Clear after" choice (telemetry)
}

Settings_Edit :: struct {
	due:          i64, // 0 = nothing pending
	status:       Maybe(Status),
	status_ms:    i64, // status_created_at_ms
	custom:       Maybe(Custom_Status),
	custom_ms:    i64, // CustomStatus.created_at_ms
	clear_custom: bool,
	theme:        Maybe(Theme),
	friend_online: Maybe(bool), // NotificationSettings.notify_friends_on_launch (12)
	folders:      Maybe([]Guild_Folder),
	inbox_tab:    Maybe(Inbox_Tab),
}

// InboxSettings.current_tab (PreloadedUserSettings field 2): the Inbox popout
// reopens on it.
Inbox_Tab :: enum u8 {
	Unspecified = 0,
	Mentions    = 1,
	Unreads     = 2,
}

@(private)
pb_fixed64 :: proc(w: ^protobuf.Writer, num: u32, v: u64) {
	protobuf.write_tag(w, num, .I64)
	for i in 0 ..< 8 do append(&w.buf, byte(v >> (8 * uint(i))))
}

@(private)
pb_msg :: proc(w: ^protobuf.Writer, num: u32, inner: ^protobuf.Writer) {
	protobuf.write_bytes(w, num, inner.buf[:])
}

@(private)
pb_new :: proc() -> protobuf.Writer {return protobuf.Writer{buf = make([dynamic]byte, context.temp_allocator)}}

// settings_delta_proto encodes the pending edit as a PreloadedUserSettings delta.
settings_delta_proto :: proc(e: ^Settings_Edit) -> []byte {
	root := pb_new()
	if tab, ok := e.inbox_tab.?; ok {
		ib := pb_new() // InboxSettings (2)
		if tab != .Unspecified do protobuf.write_uint(&ib, 1, u64(tab))
		pb_msg(&root, 2, &ib)
	}
	_, has_status := e.status.?
	_, has_custom := e.custom.?
	if has_status || has_custom || e.clear_custom {
		st := pb_new() // StatusSettings (11)
		if s, ok := e.status.?; ok {
			sv := pb_new() // StringValue
			protobuf.write_string(&sv, 1, status_name(s))
			pb_msg(&st, 1, &sv)
		}
		if cs, ok := e.custom.?; ok {
			cm := pb_new() // CustomStatus (2)
			if cs.text != "" do protobuf.write_string(&cm, 1, cs.text)
			if cs.emoji_id != 0 do pb_fixed64(&cm, 2, u64(cs.emoji_id))
			if cs.emoji_name != "" do protobuf.write_string(&cm, 3, cs.emoji_name)
			if cs.expires_at_ms != 0 do pb_fixed64(&cm, 4, u64(cs.expires_at_ms))
			pb_fixed64(&cm, 5, u64(e.custom_ms))
			pb_msg(&st, 2, &cm)
		}
		// clearing: StatusSettings without custom_status (fixture custom_status)
		if has_status && e.status_ms != 0 {
			created := pb_new() // UInt64Value
			protobuf.write_uint(&created, 1, u64(e.status_ms))
			pb_msg(&st, 5, &created)
		}
		pb_msg(&root, 11, &st)
	}
	if on, ok := e.friend_online.?; ok {
		ns := pb_new() // NotificationSettings (7)
		bv := pb_new() // BoolValue: false is the empty message
		if on do protobuf.write_uint(&bv, 1, 1)
		pb_msg(&ns, 12, &bv)
		pb_msg(&root, 7, &ns)
	}
	if th, ok := e.theme.?; ok {
		ap := pb_new() // AppearanceSettings (13): theme + client_theme_settings (3, empty)
		protobuf.write_uint(&ap, 1, u64(th))
		cts := pb_new()
		pb_msg(&ap, 3, &cts)
		pb_msg(&root, 13, &ap)
	}
	if folders, ok := e.folders.?; ok {
		gf := pb_new() // GuildFolders (14)
		for f in folders {
			fm := pb_new()
			if len(f.guild_ids) > 0 {
				ids := pb_new()
				for g in f.guild_ids do for i in 0 ..< 8 do append(&ids.buf, byte(u64(g) >> (8 * uint(i))))
				pb_msg(&fm, 1, &ids)
			}
			if f.id != 0 {
				idm := pb_new() // Int64Value
				protobuf.write_uint(&idm, 1, u64(f.id))
				pb_msg(&fm, 2, &idm)
			}
			if f.name != "" {
				nm := pb_new()
				protobuf.write_string(&nm, 1, f.name)
				pb_msg(&fm, 3, &nm)
			}
			if f.has_color {
				cm := pb_new() // UInt64Value
				protobuf.write_uint(&cm, 1, f.color)
				pb_msg(&fm, 4, &cm)
			}
			pb_msg(&gf, 1, &fm)
		}
		pb_msg(&root, 14, &gf)
	}
	return root.buf[:]
}

@(private)
settings_mark :: proc(c: ^Client, delay_ms: i64) {
	due := now_ms() + delay_ms
	e := &c.settings_edit
	// A pending timer with a longer delay is replaced by a shorter one (markDirty).
	if e.due == 0 || due < e.due do e.due = due
}

// set_status: online / idle / dnd / invisible.
set_status :: proc(c: ^Client, s: Status) {
	if s != c.store.settings.status do analytics_status_updated(c, c.store.settings.status, s)
	now := now_ms()
	c.settings_edit.status = s
	c.settings_edit.status_ms = now
	c.store.settings.status = s
	c.store.settings.status_created_ms = now
	c.store.changed += 1
	settings_mark(c, SETTINGS_DELAY_INFREQUENT_MS)
}

// set_custom_status; empty text and emoji clears it.
set_custom_status :: proc(c: ^Client, cs: Custom_Status) {
	if cs.text != "" || cs.emoji_name != "" || cs.emoji_id != 0 do analytics_custom_status_updated(c, cs)
	e := &c.settings_edit
	if cs.text == "" && cs.emoji_name == "" && cs.emoji_id == 0 {
		e.custom = nil
		e.clear_custom = true
	} else {
		if old, ok := e.custom.?; ok {
			free_str(old.text, c.allocator)
			free_str(old.emoji_name, c.allocator)
		}
		e.custom = Custom_Status{text = clone_str(cs.text, c.allocator), emoji_id = cs.emoji_id, emoji_name = clone_str(cs.emoji_name, c.allocator), expires_at_ms = cs.expires_at_ms}
		e.custom_ms = now_ms()
		e.clear_custom = false
	}
	// The whole StatusSettings is written: current status and its created time.
	if _, has := e.status.?; !has {
		e.status = c.store.settings.status
		e.status_ms = c.store.settings.status_created_ms
	}
	st := &c.store.settings
	free_str(st.custom_status_text, c.allocator)
	free_str(st.custom_status_emoji, c.allocator)
	st.custom_status_text = clone_str(cs.text, c.allocator)
	st.custom_status_emoji = clone_str(cs.emoji_name, c.allocator)
	st.custom_status_emoji_id = cs.emoji_id
	st.custom_status_expires_ms = cs.expires_at_ms
	c.store.changed += 1
	settings_mark(c, SETTINGS_DELAY_INFREQUENT_MS)
}

// presence_value: op 3 as the client sends it after a status change.
presence_value :: proc(c: ^Client, allocator := context.temp_allocator) -> V {
	context.allocator = allocator
	st := &c.store.settings
	acts := make([dynamic]V, 0, 1)
	if st.custom_status_text != "" || st.custom_status_emoji != "" {
		a := etf.map_builder(8)
		etf.map_put(&a, "name", string("Custom Status"))
		etf.map_put(&a, "type", i64(4))
		if st.custom_status_text != "" do etf.map_put(&a, "state", V(strings.clone(st.custom_status_text)))
		if st.custom_status_expires_ms != 0 {
			ts := etf.map_builder(1)
			etf.map_put(&ts, "end", st.custom_status_expires_ms)
			etf.map_put(&a, "timestamps", etf.map_done(&ts))
		}
		if st.custom_status_emoji != "" {
			em := etf.map_builder(3)
			etf.map_put(&em, "name", V(strings.clone(st.custom_status_emoji)))
			etf.map_put(&em, "id", nil if st.custom_status_emoji_id == 0 else V(snowflake_string(st.custom_status_emoji_id)))
			etf.map_put(&em, "animated", false)
			etf.map_put(&a, "emoji", etf.map_done(&em))
		} else {
			etf.map_put(&a, "emoji", nil)
		}
		etf.map_put(&a, "details", nil)
		md := etf.map_builder(1)
		etf.map_put(&md, "label", nil)
		etf.map_put(&a, "metadata", etf.map_done(&md))
		append(&acts, etf.map_done(&a))
	}
	b := etf.map_builder(4)
	etf.map_put(&b, "status", V(status_name(st.status)))
	etf.map_put(&b, "since", i64(0))
	etf.map_put(&b, "activities", etf.List(acts[:]))
	etf.map_put(&b, "afk", false)
	return etf.map_done(&b)
}

// set_theme: the user picked a theme (system: "Sync with computer", t resolved from the OS).
set_theme :: proc(c: ^Client, t: Theme, system := false) {
	analytics_theme_updated(c, t, system)
	c.settings_edit.theme = t
	c.store.settings.theme = t
	c.store.changed += 1
	settings_mark(c, SETTINGS_DELAY_INFREQUENT_MS)
}

// set_inbox_tab: switching the Inbox tab (FREQUENT_USER_ACTION: the 10 s
// timer starts at the first switch and saves the tab current then; fixture
// inbox: Unreads at +0, Mentions at +6 s, one PATCH with MENTIONS at +10 s).
set_inbox_tab :: proc(c: ^Client, tab: Inbox_Tab) {
	c.settings_edit.inbox_tab = tab
	c.store.settings.inbox_tab = tab
	c.store.changed += 1
	settings_mark(c, SETTINGS_DELAY_FREQUENT_MS)
}

// set_guild_folders replaces the sidebar folders (copied).
set_guild_folders :: proc(c: ^Client, folders: []Guild_Folder) {
	cp := make([]Guild_Folder, len(folders), c.allocator)
	for f, i in folders {
		cp[i] = f
		cp[i].name = clone_str(f.name, c.allocator)
		cp[i].guild_ids = make([dynamic]Snowflake, 0, len(f.guild_ids), c.allocator)
		append(&cp[i].guild_ids, ..f.guild_ids[:])
	}
	free_folders(c, &c.settings_edit)
	c.settings_edit.folders = cp
	settings_mark(c, SETTINGS_DELAY_FREQUENT_MS)
}

@(private)
free_folders :: proc(c: ^Client, e: ^Settings_Edit) {
	if old, ok := e.folders.?; ok {
		for f in old {
			free_str(f.name, c.allocator)
			delete(f.guild_ids)
		}
		delete(old, c.allocator)
	}
	e.folders = nil
}

// flush_settings: persistChanges when the save timer fires.
flush_settings :: proc(c: ^Client, now: i64) {
	e := &c.settings_edit
	if e.due == 0 || now < e.due do return
	delta := settings_delta_proto(e)
	_, status_part := e.status.?
	if _, cp := e.custom.?; cp || e.clear_custom do status_part = true
	// PresenceStore: the gateway presence goes out with the settings write
	if status_part && c.gw != nil do gateway_send(c.gw, .Presence_Update, presence_value(c))
	if cus, ok := e.custom.?; ok {
		free_str(cus.text, c.allocator)
		free_str(cus.emoji_name, c.allocator)
	}
	free_folders(c, e)
	e^ = {}
	if len(delta) == 0 do return
	w: Json
	json_init(&w)
	json_obj(&w)
	json_kstr(&w, "settings", base64.encode(delta, allocator = context.temp_allocator))
	json_obj_end(&w)
	j := job_new(.Api, .Settings)
	j.method = "PATCH"
	j.path = "/users/@me/settings-proto/1"
	j.body = transmute([]byte)job_str(j, json_string(&w))
	j.content_type = "application/json"
	j.retry_429 = 1 // retried after min(30 s, Retry-After)
	job_submit(c, j)
}
