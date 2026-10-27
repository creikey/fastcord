package discord

import "core:fmt"
import "core:strings"
import "core:time"
import "fc:etf"
import "fc:locks"

// Per-guild notification settings, server actions and invites (guild header
// menu, channel bell popout, invite modal), shaped like the official client's
// action creators:
//
//   PATCH  /users/@me/guilds/settings {"guilds":{"<gid>":{...}}} (0.0.419; no X-Context-Properties):
//          mute {"muted":true,"mute_config":{"selected_time_window":s,"end_time":iso ms Z|null}},
//          unmute {"muted":false}, {"message_notifications":N}, {"suppress_everyone":b},
//          {"channel_overrides":{"<cid>":{...same keys...}}}; each with science
//          notification_settings_updated (traffic/guild_mute, guild_notifications, channel_notifications)
//   POST   /read-states/ack-bulk {"read_states":[{"channel_id","message_id","read_state_type":0}]}  (Mark As Read,
//          guild icon context menu; science mark_as_read {"type":"guild","source":"Guild List"})
//   DELETE /users/@me/guilds/{gid} {"lurking":false}                                          (Leave Server)
//   POST   /channels/{cid}/invites                                                           (Invite People: invites.odin)
//
// Changes are applied to the Store at once (UI thread) and again when the
// USER_GUILD_SETTINGS_UPDATE dispatch comes back (apply_guild_settings).

NOTIFY_ALL :: 0
NOTIFY_MENTIONS :: 1
NOTIFY_NOTHING :: 2
NOTIFY_INHERIT :: 3 // channel override: use the category / server default (MessageNotifications.NULL)

MUTE_FOREVER :: -1 // selected_time_window for "Until I turn it back on"

Channel_Override :: struct {
	channel_id:            Snowflake,
	muted:                 bool,
	mute_end_ms:           i64, // 0 = until turned back on
	message_notifications: int, // NOTIFY_*
}

@(private)
iso_to_ms :: proc(s: string) -> i64 {
	if s == "" do return 0
	t, n := time.rfc3339_to_time_utc(s)
	if n == 0 do return 0
	return time.time_to_unix_nano(t) / 1e6
}

// ms_to_iso formats like JS Date.toISOString(): 2026-10-26T13:00:00.000Z.
ms_to_iso :: proc(ms: i64, allocator := context.temp_allocator) -> string {
	t := time.unix(ms / 1000, (ms % 1000) * 1e6)
	y, mo, d := time.date(t)
	h, mi, sec := time.clock_from_time(t)
	return fmt.aprintf("%04d-%02d-%02dT%02d:%02d:%02d.%03dZ", y, int(mo), d, h, mi, sec, ms % 1000, allocator = allocator)
}

// Called by apply_guild_settings (Store, UI thread) with the full settings object.
@(private)
apply_guild_settings_extra :: proc(s: ^Store, gs: ^Guild_Settings, m: etf.Map) {
	if gs.overrides.allocator.procedure == nil do gs.overrides = make([dynamic]Channel_Override, s.allocator)
	clear(&gs.overrides)
	gs.mute_end_ms = iso_to_ms(fstr(fmap(m, "mute_config"), "end_time"))
	gs.flags = fint(m, "flags")
	gs.mobile_push = !vhas(m, "mobile_push") || fbool(m, "mobile_push")
	gs.notify_highlights = int(fint(m, "notify_highlights"))
	gs.mute_scheduled_events = fbool(m, "mute_scheduled_events")
	gs.hide_muted_channels = fbool(m, "hide_muted_channels")
	for ov in flist(m, "channel_overrides") {
		om := vmap(ov)
		o := Channel_Override {
			channel_id            = fsnow(om, "channel_id"),
			muted                 = fbool(om, "muted"),
			mute_end_ms           = iso_to_ms(fstr(fmap(om, "mute_config"), "end_time")),
			message_notifications = NOTIFY_INHERIT,
		}
		if v := vget(om, "message_notifications"); v != nil && !vis_null(v) do o.message_notifications = int(vint(v))
		append(&gs.overrides, o)
	}
}

mute_active :: proc(muted: bool, end_ms, now_ms: i64) -> bool {
	return muted && (end_ms == 0 || end_ms > now_ms)
}

guild_settings_get :: proc(s: ^Store, gid: Snowflake) -> ^Guild_Settings {
	if gs, ok := &s.guild_settings[gid]; ok do return gs
	return nil
}

guild_is_muted :: proc(s: ^Store, gid: Snowflake, now_ms: i64) -> bool {
	gs := guild_settings_get(s, gid)
	return gs != nil && mute_active(gs.muted, gs.mute_end_ms, now_ms)
}

channel_override_get :: proc(s: ^Store, gid, cid: Snowflake) -> ^Channel_Override {
	gs := guild_settings_get(s, gid)
	if gs == nil do return nil
	for &o in gs.overrides do if o.channel_id == cid do return &o
	return nil
}

// The channel's own mute (not its category's or the server's).
channel_is_muted :: proc(s: ^Store, gid, cid: Snowflake, now_ms: i64) -> bool {
	o := channel_override_get(s, gid, cid)
	return o != nil && mute_active(o.muted, o.mute_end_ms, now_ms)
}

// Muted by its own override or its category's (what the sidebar dims).
channel_effectively_muted :: proc(s: ^Store, gid, cid: Snowflake, now_ms: i64) -> bool {
	if channel_is_muted(s, gid, cid, now_ms) do return true
	if ch := channel_get(s, cid); ch != nil && ch.parent_id != 0 do return channel_is_muted(s, gid, ch.parent_id, now_ms)
	return false
}

// Server-level level: the user's setting, else the guild's default.
guild_notify_level :: proc(s: ^Store, gid: Snowflake) -> int {
	if gs := guild_settings_get(s, gid); gs != nil do return gs.message_notifications
	if g := guild_get(s, gid); g != nil do return g.default_message_notifications
	return NOTIFY_ALL
}

// The channel's own override level (NOTIFY_INHERIT when none).
channel_notify_level :: proc(s: ^Store, gid, cid: Snowflake) -> int {
	if o := channel_override_get(s, gid, cid); o != nil do return o.message_notifications
	return NOTIFY_INHERIT
}

// ---- local (optimistic) updates ----

@(private = "file")
ensure_settings :: proc(s: ^Store, gid: Snowflake) -> ^Guild_Settings {
	if gs, ok := &s.guild_settings[gid]; ok {
		if gs.overrides.allocator.procedure == nil do gs.overrides = make([dynamic]Channel_Override, s.allocator)
		return gs
	}
	lvl := NOTIFY_ALL
	if g := guild_get(s, gid); g != nil do lvl = g.default_message_notifications
	s.guild_settings[gid] = Guild_Settings {
		guild_id              = gid,
		message_notifications = lvl,
		mobile_push           = true,
		muted_channels        = make([dynamic]Snowflake, s.allocator),
		collapsed_channels    = make([dynamic]Snowflake, s.allocator),
		overrides             = make([dynamic]Channel_Override, s.allocator),
	}
	return &s.guild_settings[gid]
}

@(private = "file")
ensure_override :: proc(gs: ^Guild_Settings, cid: Snowflake) -> ^Channel_Override {
	for &o in gs.overrides do if o.channel_id == cid do return &o
	append(&gs.overrides, Channel_Override{channel_id = cid, message_notifications = NOTIFY_INHERIT})
	return &gs.overrides[len(gs.overrides) - 1]
}

@(private = "file")
rebuild_muted :: proc(gs: ^Guild_Settings) {
	clear(&gs.muted_channels)
	for o in gs.overrides do if o.muted do append(&gs.muted_channels, o.channel_id)
}

// ---- REST ----

// All writes go to the bulk endpoint, keyed by guild: {"guilds":{"<gid>":<inner>}}.
@(private = "file")
patch_guild_settings :: proc(c: ^Client, gid: Snowflake, inner: string) {
	body := fmt.tprintf(`{{"guilds":{{"%d":%s}}}}`, u64(gid), inner)
	j := job_new(.Api, .None)
	j.method = "PATCH"
	j.path = "/users/@me/guilds/settings"
	j.body = transmute([]byte)job_str(j, body)
	j.content_type = "application/json"
	j.retries = 2
	job_submit(c, j)
}

// mute: {"muted":true,"mute_config":{...}}; unmute: {"muted":false} only.
@(private = "file")
write_mute :: proc(w: ^Json, muted: bool, seconds: int, now_ms: i64) -> (end_ms: i64) {
	json_kbool(w, "muted", muted)
	if !muted do return 0
	json_key(w, "mute_config")
	json_obj(w)
	json_kint(w, "selected_time_window", i64(seconds))
	if seconds > 0 {
		end_ms = now_ms + i64(seconds) * 1000
		json_kstr(w, "end_time", ms_to_iso(end_ms))
	} else {
		json_knull(w, "end_time")
	}
	json_obj_end(w)
	return
}

// Mute the server for `seconds` (MUTE_FOREVER: until turned back on), or unmute.
set_guild_muted :: proc(c: ^Client, gid: Snowflake, muted: bool, seconds := MUTE_FOREVER, now_ms: i64 = 0) {
	now := now_ms if now_ms != 0 else now_ms_real()
	w: Json
	json_init(&w)
	json_obj(&w)
	end := write_mute(&w, muted, seconds, now)
	json_obj_end(&w)
	gs := ensure_settings(&c.store, gid)
	old := mute_active(gs.muted, gs.mute_end_ms, now)
	gs.muted = muted
	// unmuting keeps the old end time until the server's update clears it (the
	// official event still reports it as guild_muted_until)
	if muted do gs.mute_end_ms = end
	c.store.changed += 1
	patch_guild_settings(c, gid, json_string(&w))
	track_guild_settings(c, gid, muted ? "muted" : "unmuted", fmt.tprintf(`"guild_is_muted_old":%v`, old))
}

// Mute one channel (or category) for `seconds`, or unmute it.
set_channel_muted :: proc(c: ^Client, gid, cid: Snowflake, muted: bool, seconds := MUTE_FOREVER, now_ms: i64 = 0) {
	now := now_ms if now_ms != 0 else now_ms_real()
	w: Json
	json_init(&w)
	json_obj(&w)
	json_key(&w, "channel_overrides")
	json_obj(&w)
	json_key(&w, snowflake_string(cid))
	json_obj(&w)
	end := write_mute(&w, muted, seconds, now)
	json_obj_end(&w)
	json_obj_end(&w)
	json_obj_end(&w)
	gs := ensure_settings(&c.store, gid)
	o := ensure_override(gs, cid)
	old_muted := mute_active(o.muted, o.mute_end_ms, now)
	old_until := o.mute_end_ms if old_muted else 0
	old_over := override_set(o, now)
	o.muted = muted
	o.mute_end_ms = end
	rebuild_muted(gs)
	c.store.changed += 1
	patch_guild_settings(c, gid, json_string(&w))
	old := fmt.tprintf(`"channel_is_muted_old":%v,"channel_is_overridden_old":%v`, old_muted, old_over)
	if muted do old = fmt.tprintf(`"channel_is_muted_old":%v,"channel_muted_until_old":%s,"channel_is_overridden_old":%v`, old_muted, ms_or_null(old_until), old_over)
	track_channel_settings(c, gid, cid, muted ? "muted" : "unmuted", old)
}

// Server notification level: NOTIFY_ALL / NOTIFY_MENTIONS / NOTIFY_NOTHING.
set_guild_notify_level :: proc(c: ^Client, gid: Snowflake, level: int) {
	patch_guild_settings(c, gid, fmt.tprintf(`{{"message_notifications":%d}}`, level))
	gs := ensure_settings(&c.store, gid)
	old := gs.message_notifications
	gs.message_notifications = level
	c.store.changed += 1
	track_guild_settings(c, gid, notify_label(level), fmt.tprintf(`"guild_message_notification_settings_old":%s`, notify_name_json(old)))
}

// Channel notification level (NOTIFY_INHERIT: use the category / server default).
set_channel_notify_level :: proc(c: ^Client, gid, cid: Snowflake, level: int) {
	patch_guild_settings(c, gid, fmt.tprintf(`{{"channel_overrides":{{"%d":{{"message_notifications":%d}}}}}}`, u64(cid), level))
	o := ensure_override(ensure_settings(&c.store, gid), cid)
	old_over := override_set(o, now_ms_real())
	old := o.message_notifications
	o.message_notifications = level
	c.store.changed += 1
	track_channel_settings(c, gid, cid, notify_label(level), fmt.tprintf(`"channel_is_overridden_old":%v,"channel_message_notification_settings_old":%s`, old_over, notify_name_json(old)))
}

// No capture covers the suppress switches: the write follows the same endpoint;
// no science event is sent (its label is unknown, and values are never invented).
set_guild_suppress_everyone :: proc(c: ^Client, gid: Snowflake, on: bool) {
	patch_guild_settings(c, gid, on ? `{"suppress_everyone":true}` : `{"suppress_everyone":false}`)
	ensure_settings(&c.store, gid).suppress_everyone = on
	c.store.changed += 1
}

set_guild_suppress_roles :: proc(c: ^Client, gid: Snowflake, on: bool) {
	patch_guild_settings(c, gid, on ? `{"suppress_roles":true}` : `{"suppress_roles":false}`)
	ensure_settings(&c.store, gid).suppress_roles = on
	c.store.changed += 1
}

// ---- science (notification_settings_updated, guild_dropdown_menu_viewed) ----

// guild_dropdown_menu_viewed: the server header dropdown opened (traffic/guild_menu).
track_guild_dropdown_viewed :: proc(c: ^Client, gid: Snowflake) {
	w := aw_begin()
	json_ksnow(&w, "guild_id", gid)
	aw_track(c, "guild_dropdown_menu_viewed", &w)
}

@(private = "file")
NOTIFY_NAME := [4]string{"All", "Mentions", "Nothing", "Null"}

@(private = "file")
notify_name_json :: proc(level: int) -> string {
	if level < 0 || level >= NOTIFY_INHERIT do return "null"
	return fmt.tprintf(`"%s"`, NOTIFY_NAME[level])
}

@(private = "file")
notify_label :: proc(level: int) -> string {
	switch level {
	case NOTIFY_ALL:
		return "notifications set to all messages"
	case NOTIFY_MENTIONS:
		return "notifications set to mentions"
	case NOTIFY_NOTHING:
		return "notifications set to nothing"
	}
	return "notifications set to the default"
}

@(private = "file")
ms_or_null :: proc(ms: i64) -> string {
	return ms == 0 ? "null" : fmt.tprint(ms)
}

// An override that changes anything (the official channel_is_overridden).
@(private = "file")
override_set :: proc(o: ^Channel_Override, now: i64) -> bool {
	return mute_active(o.muted, o.mute_end_ms, now) || o.message_notifications != NOTIFY_INHERIT
}

@(private = "file")
NOTIFY_APPROX :: `"approx_seconds_since_last_notification":null,"approx_seconds_since_last_mention":null,"approx_seconds_since_last_role_mention":null,"approx_seconds_since_last_everyone_mention":null,"approx_seconds_since_last_guild_notification":null,"approx_seconds_since_last_guild_mention":null,"approx_seconds_since_last_guild_role_mention":null,"approx_seconds_since_last_guild_everyone_mention":null`

// The guild / current-channel decorations every notification_settings_updated
// carries (the route's channel when it is in the guild); appended to a props body.
@(private = "file")
guild_channel_props :: proc(c: ^Client, sb: ^strings.Builder, gid: Snowflake, with_channel_id: bool) {
	locks.lock(&c.route_mu)
	rcid := c.route_channel
	locks.unlock(&c.route_mu)
	w := aw_begin()
	if guild_get(&c.store, gid) != nil {
		aw_guild(&w, c, gid, false)
		if ch := channel_get(&c.store, rcid); ch != nil && ch.guild_id == gid do aw_channel(&w, c, rcid, with_channel_id)
	}
	json_obj_end(&w)
	if body := json_body(json_string(&w)); body != "" {
		strings.write_byte(sb, ',')
		strings.write_string(sb, body)
	}
}

@(private = "file")
track_guild_settings :: proc(c: ^Client, gid: Snowflake, label, old: string) {
	s := &c.store
	gs := ensure_settings(s, gid)
	now := now_ms_real()
	sb := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&sb, `"guild_muted_until":%s,"guild_flags":%d,"guild_is_muted":%v,"guild_message_notification_settings":%s,"guild_suppress_roles":%v,"guild_receive_mobile_push":%v,"guild_notify_highlights":%d,"guild_suppress_everyone":%v,"guild_scheduled_events_muted":%v,`,
		ms_or_null(gs.mute_end_ms), gs.flags, mute_active(gs.muted, gs.mute_end_ms, now), notify_name_json(gs.message_notifications), gs.suppress_roles, gs.mobile_push, gs.notify_highlights, gs.suppress_everyone, gs.mute_scheduled_events)
	strings.write_string(&sb, NOTIFY_APPROX)
	fmt.sbprintf(&sb, `,"guild_id":"%d","update_type":"guild","label":"%s",%s,"is_opt_in_only_change":true`, u64(gid), label, old)
	guild_channel_props(c, &sb, gid, true)
	analytics_track(c, "notification_settings_updated", strings.to_string(sb))
}

@(private = "file")
track_channel_settings :: proc(c: ^Client, gid, cid: Snowflake, label, old: string) {
	s := &c.store
	o := ensure_override(ensure_settings(s, gid), cid)
	now := now_ms_real()
	muted := mute_active(o.muted, o.mute_end_ms, now)
	ch := channel_get(s, cid)
	sb := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&sb, `"channel_is_muted":%v,"channel_is_overridden":%v,"channel_flags":%d,"channel_message_notification_settings":%s,"channel_muted_until":%s,`,
		muted, override_set(o, now), ch != nil ? ch.flags : 0, notify_name_json(o.message_notifications), ms_or_null(muted ? o.mute_end_ms : 0))
	strings.write_string(&sb, NOTIFY_APPROX)
	fmt.sbprintf(&sb, `,"guild_id":"%d","channel_id":"%d","update_type":"channel","label":"%s"`, u64(gid), u64(cid), label)
	if ch != nil && ch.parent_id != 0 do fmt.sbprintf(&sb, `,"parent_id":"%d"`, u64(ch.parent_id))
	fmt.sbprintf(&sb, `,%s,"is_opt_in_only_change":true`, old)
	// last_message_type: the type of the channel's last loaded message
	if ch != nil {
		if msgs := messages_get(s, cid); len(msgs) > 0 && msgs[len(msgs) - 1].id == ch.last_message_id do fmt.sbprintf(&sb, `,"last_message_type":%d`, int(msgs[len(msgs) - 1].kind))
	}
	guild_channel_props(c, &sb, gid, false)
	analytics_track(c, "notification_settings_updated", strings.to_string(sb))
}

// Mark As Read: every unread channel of the guild in one ack-bulk; read states
// move to each channel's last message at once.
ack_guild :: proc(c: ^Client, gid: Snowflake) -> (n: int) {
	g := guild_get(&c.store, gid)
	if g == nil do return 0
	return ack_channels(c, g.channels[:])
}

// ack_channels: one POST /read-states/ack-bulk for the unread channels among
// ids (guild Mark As Read; the Inbox's Mark All as Read).
ack_channels :: proc(c: ^Client, ids: []Snowflake) -> (n: int) {
	s := &c.store
	w: Json
	json_init(&w)
	json_obj(&w)
	json_key(&w, "read_states")
	json_arr(&w)
	for cid in ids {
		ch := channel_get(s, cid)
		if ch == nil || !channel_unread(s, cid) do continue
		json_obj(&w)
		json_ksnow(&w, "channel_id", cid)
		json_ksnow(&w, "message_id", ch.last_message_id)
		json_kint(&w, "read_state_type", 0)
		json_obj_end(&w)
		rs := s.read_states[cid]
		rs.channel_id = cid
		rs.last_message_id = ch.last_message_id
		rs.mention_count = 0
		s.read_states[cid] = rs
		n += 1
	}
	json_arr_end(&w)
	json_obj_end(&w)
	if n == 0 do return
	s.changed += 1
	defer analytics_track(c, "mark_as_read", `"type":"guild","source":"Guild List"`)
	j := job_new(.Api, .None)
	j.method = "POST"
	j.path = "/read-states/ack-bulk"
	j.body = transmute([]byte)job_str(j, json_string(&w))
	j.content_type = "application/json"
	j.retries = 2
	job_submit(c, j)
	return
}

// Leave Server: DELETE /users/@me/guilds/{id} {"lurking":false}; the guild goes
// away with the GUILD_DELETE dispatch that follows.
leave_guild :: proc(c: ^Client, gid: Snowflake) {
	j := job_new(.Api, .None)
	j.method = "DELETE"
	j.path = job_str(j, strings.concatenate({"/users/@me/guilds/", snowflake_string(gid)}, context.temp_allocator))
	j.referer = job_str(j, client_route_referer(c)) // the app routes home only on GUILD_DELETE
	j.body = transmute([]byte)job_str(j, `{"lurking":false}`)
	j.content_type = "application/json"
	job_submit(c, j)
}

@(private = "file")
now_ms_real :: proc() -> i64 {return time.time_to_unix_nano(time.now()) / 1e6}
