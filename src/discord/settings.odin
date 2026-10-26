package discord

import "core:encoding/base64"
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
}

Settings_Edit :: struct {
	due:          i64, // 0 = nothing pending
	status:       Maybe(Status),
	status_ms:    i64, // status_created_at_ms
	custom:       Maybe(Custom_Status),
	clear_custom: bool,
	theme:        Maybe(Theme),
	folders:      Maybe([]Guild_Folder),
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
			pb_fixed64(&cm, 5, u64(e.status_ms))
			pb_msg(&st, 2, &cm)
		} else if e.clear_custom {
			cm := pb_new()
			pb_msg(&st, 2, &cm)
		}
		if has_status {
			created := pb_new() // UInt64Value
			protobuf.write_uint(&created, 1, u64(e.status_ms))
			pb_msg(&st, 5, &created)
		}
		pb_msg(&root, 11, &st)
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
	c.settings_edit.status = s
	c.settings_edit.status_ms = now_ms()
	c.store.settings.status = s
	c.store.changed += 1
	settings_mark(c, SETTINGS_DELAY_INFREQUENT_MS)
}

// set_custom_status; empty text and emoji clears it.
set_custom_status :: proc(c: ^Client, cs: Custom_Status) {
	e := &c.settings_edit
	if cs.text == "" && cs.emoji_name == "" && cs.emoji_id == 0 {
		e.custom = nil
		e.clear_custom = true
	} else {
		if old, ok := e.custom.?; ok {
			free_str(old.text, c.allocator)
			free_str(old.emoji_name, c.allocator)
		}
		e.custom = Custom_Status{clone_str(cs.text, c.allocator), cs.emoji_id, clone_str(cs.emoji_name, c.allocator), cs.expires_at_ms}
		e.clear_custom = false
	}
	if e.status_ms == 0 do e.status_ms = now_ms()
	settings_mark(c, SETTINGS_DELAY_INFREQUENT_MS)
}

set_theme :: proc(c: ^Client, t: Theme) {
	c.settings_edit.theme = t
	c.store.settings.theme = t
	c.store.changed += 1
	settings_mark(c, SETTINGS_DELAY_INFREQUENT_MS)
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
