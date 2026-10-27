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

NOTIFY_ALL :: 0;
NOTIFY_MENTIONS :: 1;
NOTIFY_NOTHING :: 2;
NOTIFY_INHERIT :: 3; // channel override: use the category / server default (MessageNotifications.NULL)

MUTE_FOREVER :: -1; // selected_time_window for "Until I turn it back on"

Channel_Override :: struct {
	channel_id: Snowflake;
	muted: bool;
	mute_end_ms: s64; // 0 = until turned back on
	message_notifications: int; // NOTIFY_*
}
#scope_module

iso_to_ms :: (s: string) -> s64 {
	if s == "" { return 0; }
	t, n := time.rfc3339_to_time_utc(s);
	if n == 0 { return 0; }
	return time.time_to_unix_nano(t) / 1000000;
}
#scope_export

// ms_to_iso formats like JS Date.toISOString(): 2026-10-26T13:00:00.000Z.
ms_to_iso :: (ms: s64, allocator := temp) -> string {
	t := time.unix(ms / 1000, (ms % 1000) * 1000000);
	y, mo, d := time.date(t);
	h, mi, sec := time.clock_from_time(t);
	return fmt.aprintf("%04d-%02d-%02dT%02d:%02d:%02d.%03dZ", y, cast(int)(mo), d, h, mi, sec, ms % 1000, allocator = allocator);
}
#scope_module

// Called by apply_guild_settings (Store, UI thread) with the full settings object.
apply_guild_settings_extra :: (s: *Store, gs: *Guild_Settings, m: etf.Map) {
	if gs.overrides.allocator.procedure == null { gs.overrides = make_dynamic(Channel_Override, 0, 0, s.allocator); }
	clear(*gs.overrides);
	gs.mute_end_ms = iso_to_ms(fstr(fmap(m, "mute_config"), "end_time"));
	gs.flags = fint(m, "flags");
	gs.mobile_push = !vhas(m, "mobile_push") || fbool(m, "mobile_push");
	gs.notify_highlights = cast(int)(fint(m, "notify_highlights"));
	gs.mute_scheduled_events = fbool(m, "mute_scheduled_events");
	gs.hide_muted_channels = fbool(m, "hide_muted_channels");
	for ov: flist(m, "channel_overrides") {
		om := vmap(ov);
		o := Channel_Override.{
			channel_id = fsnow(om, "channel_id"),
			muted = fbool(om, "muted"),
			mute_end_ms = iso_to_ms(fstr(fmap(om, "mute_config"), "end_time")),
			message_notifications = NOTIFY_INHERIT
		};
		{ v := vget(om, "message_notifications");
		if v != null && !vis_null(v) { o.message_notifications = cast(int)(vint(v)); } }
		append(*gs.overrides, o);
	}
}
#scope_export

mute_active :: (muted: bool, end_ms: s64, now_ms: s64) -> bool {
	return muted && (end_ms == 0 || end_ms > now_ms);
}

guild_settings_get :: (s: *Store, gid: Snowflake) -> *Guild_Settings {
	{ gs, ok := map_find_ptr(*s.guild_settings, gid);
	if ok { return gs; } }
	return null;
}

guild_is_muted :: (s: *Store, gid: Snowflake, now_ms: s64) -> bool {
	gs := guild_settings_get(s, gid);
	return gs != null && mute_active(gs.muted, gs.mute_end_ms, now_ms);
}

channel_override_get :: (s: *Store, gid: Snowflake, cid: Snowflake) -> *Channel_Override {
	gs := guild_settings_get(s, gid);
	if gs == null { return null; }
	for * o: gs.overrides { if o.channel_id == cid { return *o; } }
	return null;
}

// The channel's own mute (not its category's or the server's).
channel_is_muted :: (s: *Store, gid: Snowflake, cid: Snowflake, now_ms: s64) -> bool {
	o := channel_override_get(s, gid, cid);
	return o != null && mute_active(o.muted, o.mute_end_ms, now_ms);
}

// Muted by its own override or its category's (what the sidebar dims).
channel_effectively_muted :: (s: *Store, gid: Snowflake, cid: Snowflake, now_ms: s64) -> bool {
	if channel_is_muted(s, gid, cid, now_ms) { return true; }
	{ ch := channel_get(s, cid);
	if ch != null && ch.parent_id != 0 { return channel_is_muted(s, gid, ch.parent_id, now_ms); } }
	return false;
}

// Server-level level: the user's setting, else the guild's default.
guild_notify_level :: (s: *Store, gid: Snowflake) -> int {
	{ gs := guild_settings_get(s, gid);
	if gs != null { return gs.message_notifications; } }
	{ g := guild_get(s, gid);
	if g != null { return g.default_message_notifications; } }
	return NOTIFY_ALL;
}

// The channel's own override level (NOTIFY_INHERIT when none).
channel_notify_level :: (s: *Store, gid: Snowflake, cid: Snowflake) -> int {
	{ o := channel_override_get(s, gid, cid);
	if o != null { return o.message_notifications; } }
	return NOTIFY_INHERIT;
}
#scope_file

// ---- local (optimistic) updates ----

ensure_settings :: (s: *Store, gid: Snowflake) -> *Guild_Settings {
	{ gs, ok := map_find_ptr(*s.guild_settings, gid);
	if ok {
		if gs.overrides.allocator.procedure == null { gs.overrides = make_dynamic(Channel_Override, 0, 0, s.allocator); }
		return gs;
	} }
	lvl := NOTIFY_ALL;
	{ g := guild_get(s, gid);
	if g != null { lvl = g.default_message_notifications; } }
	at(*s.guild_settings, gid).* = Guild_Settings.{
		guild_id = gid,
		message_notifications = lvl,
		mobile_push = true,
		muted_channels = make_dynamic(Snowflake, 0, 0, s.allocator),
		collapsed_channels = make_dynamic(Snowflake, 0, 0, s.allocator),
		overrides = make_dynamic(Channel_Override, 0, 0, s.allocator)
	};
	return at(*s.guild_settings, gid);
}

ensure_override :: (gs: *Guild_Settings, cid: Snowflake) -> *Channel_Override {
	for * o: gs.overrides { if o.channel_id == cid { return *o; } }
	append(*gs.overrides, Channel_Override.{channel_id = cid, message_notifications = NOTIFY_INHERIT});
	return *gs.overrides[len(gs.overrides) - 1];
}

rebuild_muted :: (gs: *Guild_Settings) {
	clear(*gs.muted_channels);
	for o: gs.overrides { if o.muted { append(*gs.muted_channels, o.channel_id); } }
}

// ---- REST ----

// All writes go to the bulk endpoint, keyed by guild: {"guilds":{"<gid>":<inner>}}.
patch_guild_settings :: (c: *Client, gid: Snowflake, inner: string) {
	body := fmt.tprintf("{{\"guilds\":{{\"%d\":%s}}}}", cast(u64)(gid), inner);
	j := job_new(.Api, .None);
	j.method = "PATCH";
	j.path = "/users/@me/guilds/settings";
	j.body = transmute([]u8, job_str(j, body));
	j.content_type = "application/json";
	j.retries = 2;
	job_submit(c, j);
}

// mute: {"muted":true,"mute_config":{...}}; unmute: {"muted":false} only.
write_mute :: (w: *Json, muted: bool, seconds: int, now_ms: s64) -> s64 {
	end_ms: s64;
	json_kbool(w, "muted", muted);
	if !muted { return 0; }
	json_key(w, "mute_config");
	json_obj(w);
	json_kint(w, "selected_time_window", cast(s64)(seconds));
	if seconds > 0 {
		end_ms = now_ms + cast(s64)(seconds) * 1000;
		json_kstr(w, "end_time", ms_to_iso(end_ms));
	} else {
		json_knull(w, "end_time");
	}
	json_obj_end(w);
	return end_ms;
}
#scope_export

// Mute the server for `seconds` (MUTE_FOREVER: until turned back on), or unmute.
set_guild_muted :: (c: *Client, gid: Snowflake, muted: bool, seconds := MUTE_FOREVER, now_ms: s64 = 0) {
	now := ifx now_ms != 0 then now_ms else now_ms_real();
	w: Json;
	json_init(*w);
	json_obj(*w);
	end := write_mute(*w, muted, seconds, now);
	json_obj_end(*w);
	gs := ensure_settings(*c.store, gid);
	old := mute_active(gs.muted, gs.mute_end_ms, now);
	gs.muted = muted;
	// unmuting keeps the old end time until the server's update clears it (the
	// official event still reports it as guild_muted_until)
	if muted { gs.mute_end_ms = end; }
	c.store.changed += 1;
	patch_guild_settings(c, gid, json_string(*w));
	track_guild_settings(c, gid, ifx muted then "muted" else "unmuted", fmt.tprintf("\"guild_is_muted_old\":%v", old));
}

// Mute one channel (or category) for `seconds`, or unmute it.
set_channel_muted :: (c: *Client, gid: Snowflake, cid: Snowflake, muted: bool, seconds := MUTE_FOREVER, now_ms: s64 = 0) {
	now := ifx now_ms != 0 then now_ms else now_ms_real();
	w: Json;
	json_init(*w);
	json_obj(*w);
	json_key(*w, "channel_overrides");
	json_obj(*w);
	json_key(*w, snowflake_string(cid));
	json_obj(*w);
	end := write_mute(*w, muted, seconds, now);
	json_obj_end(*w);
	json_obj_end(*w);
	json_obj_end(*w);
	gs := ensure_settings(*c.store, gid);
	o := ensure_override(gs, cid);
	old_muted := mute_active(o.muted, o.mute_end_ms, now);
	old_until := ifx old_muted then o.mute_end_ms else 0;
	old_over := override_set(o, now);
	o.muted = muted;
	o.mute_end_ms = end;
	rebuild_muted(gs);
	c.store.changed += 1;
	patch_guild_settings(c, gid, json_string(*w));
	old := fmt.tprintf("\"channel_is_muted_old\":%v,\"channel_is_overridden_old\":%v", old_muted, old_over);
	if muted { old = fmt.tprintf("\"channel_is_muted_old\":%v,\"channel_muted_until_old\":%s,\"channel_is_overridden_old\":%v", old_muted, ms_or_null(old_until), old_over); }
	track_channel_settings(c, gid, cid, ifx muted then "muted" else "unmuted", old);
}

// Server notification level: NOTIFY_ALL / NOTIFY_MENTIONS / NOTIFY_NOTHING.
set_guild_notify_level :: (c: *Client, gid: Snowflake, level: int) {
	patch_guild_settings(c, gid, fmt.tprintf("{{\"message_notifications\":%d}}", level));
	gs := ensure_settings(*c.store, gid);
	old := gs.message_notifications;
	gs.message_notifications = level;
	c.store.changed += 1;
	track_guild_settings(c, gid, notify_label(level), fmt.tprintf("\"guild_message_notification_settings_old\":%s", notify_name_json(old)));
}

// Channel notification level (NOTIFY_INHERIT: use the category / server default).
set_channel_notify_level :: (c: *Client, gid: Snowflake, cid: Snowflake, level: int) {
	patch_guild_settings(c, gid, fmt.tprintf("{{\"channel_overrides\":{{\"%d\":{{\"message_notifications\":%d}}}}}}", cast(u64)(cid), level));
	o := ensure_override(ensure_settings(*c.store, gid), cid);
	old_over := override_set(o, now_ms_real());
	old := o.message_notifications;
	o.message_notifications = level;
	c.store.changed += 1;
	track_channel_settings(c, gid, cid, notify_label(level), fmt.tprintf("\"channel_is_overridden_old\":%v,\"channel_message_notification_settings_old\":%s", old_over, notify_name_json(old)));
}

// No capture covers the suppress switches: the write follows the same endpoint;
// no science event is sent (its label is unknown, and values are never invented).
set_guild_suppress_everyone :: (c: *Client, gid: Snowflake, on: bool) {
	patch_guild_settings(c, gid, ifx on then "{\"suppress_everyone\":true}" else "{\"suppress_everyone\":false}");
	ensure_settings(*c.store, gid).suppress_everyone = on;
	c.store.changed += 1;
}

set_guild_suppress_roles :: (c: *Client, gid: Snowflake, on: bool) {
	patch_guild_settings(c, gid, ifx on then "{\"suppress_roles\":true}" else "{\"suppress_roles\":false}");
	ensure_settings(*c.store, gid).suppress_roles = on;
	c.store.changed += 1;
}

// ---- science (notification_settings_updated, guild_dropdown_menu_viewed) ----

// guild_dropdown_menu_viewed: the server header dropdown opened (traffic/guild_menu).
track_guild_dropdown_viewed :: (c: *Client, gid: Snowflake) {
	w := aw_begin();
	json_ksnow(*w, "guild_id", gid);
	aw_track(c, "guild_dropdown_menu_viewed", *w);
}
#scope_file

NOTIFY_NAME := string.["All", "Mentions", "Nothing", "Null"];

notify_name_json :: (level: int) -> string {
	if level < 0 || level >= NOTIFY_INHERIT { return "null"; }
	return fmt.tprintf("\"%s\"", NOTIFY_NAME[level]);
}

notify_label :: (level: int) -> string {
	if level == {
	case NOTIFY_ALL;
		return "notifications set to all messages";
	case NOTIFY_MENTIONS;
		return "notifications set to mentions";
	case NOTIFY_NOTHING;
		return "notifications set to nothing";
	}
	return "notifications set to the default";
}

ms_or_null :: (ms: s64) -> string {
	return ifx ms == 0 then "null" else fmt.tprint(ms);
}

// An override that changes anything (the official channel_is_overridden).
override_set :: (o: *Channel_Override, now: s64) -> bool {
	return mute_active(o.muted, o.mute_end_ms, now) || o.message_notifications != NOTIFY_INHERIT;
}

NOTIFY_APPROX :: "\"approx_seconds_since_last_notification\":null,\"approx_seconds_since_last_mention\":null,\"approx_seconds_since_last_role_mention\":null,\"approx_seconds_since_last_everyone_mention\":null,\"approx_seconds_since_last_guild_notification\":null,\"approx_seconds_since_last_guild_mention\":null,\"approx_seconds_since_last_guild_role_mention\":null,\"approx_seconds_since_last_guild_everyone_mention\":null";

// The guild / current-channel decorations every notification_settings_updated
// carries (the route's channel when it is in the guild); appended to a props body.
guild_channel_props :: (c: *Client, sb: *strings.Builder, gid: Snowflake, with_channel_id: bool) {
	locks.lock(*c.route_mu);
	rcid := c.route_channel;
	locks.unlock(*c.route_mu);
	w := aw_begin();
	if guild_get(*c.store, gid) != null {
		aw_guild(*w, c, gid, false);
		{ ch := channel_get(*c.store, rcid);
		if ch != null && ch.guild_id == gid { aw_channel(*w, c, rcid, with_channel_id); } }
	}
	json_obj_end(*w);
	{ body := json_body(json_string(*w));
	if body != "" {
		strings.write_byte(sb, #char ",");
		strings.write_string(sb, body);
	} }
}

track_guild_settings :: (c: *Client, gid: Snowflake, label: string, old: string) {
	s := *c.store;
	gs := ensure_settings(s, gid);
	now := now_ms_real();
	sb := strings.builder_make(temp);
	fmt.sbprintf(*sb, "\"guild_muted_until\":%s,\"guild_flags\":%d,\"guild_is_muted\":%v,\"guild_message_notification_settings\":%s,\"guild_suppress_roles\":%v,\"guild_receive_mobile_push\":%v,\"guild_notify_highlights\":%d,\"guild_suppress_everyone\":%v,\"guild_scheduled_events_muted\":%v,",
		ms_or_null(gs.mute_end_ms), gs.flags, mute_active(gs.muted, gs.mute_end_ms, now), notify_name_json(gs.message_notifications), gs.suppress_roles, gs.mobile_push, gs.notify_highlights, gs.suppress_everyone, gs.mute_scheduled_events);
	strings.write_string(*sb, NOTIFY_APPROX);
	fmt.sbprintf(*sb, ",\"guild_id\":\"%d\",\"update_type\":\"guild\",\"label\":\"%s\",%s,\"is_opt_in_only_change\":true", cast(u64)(gid), label, old);
	guild_channel_props(c, *sb, gid, true);
	analytics_track(c, "notification_settings_updated", strings.to_string(sb));
}

track_channel_settings :: (c: *Client, gid: Snowflake, cid: Snowflake, label: string, old: string) {
	s := *c.store;
	o := ensure_override(ensure_settings(s, gid), cid);
	now := now_ms_real();
	muted := mute_active(o.muted, o.mute_end_ms, now);
	ch := channel_get(s, cid);
	sb := strings.builder_make(temp);
	fmt.sbprintf(*sb, "\"channel_is_muted\":%v,\"channel_is_overridden\":%v,\"channel_flags\":%d,\"channel_message_notification_settings\":%s,\"channel_muted_until\":%s,",
		muted, override_set(o, now), ifx ch != null then ch.flags else 0, notify_name_json(o.message_notifications), ms_or_null(ifx muted then o.mute_end_ms else 0));
	strings.write_string(*sb, NOTIFY_APPROX);
	fmt.sbprintf(*sb, ",\"guild_id\":\"%d\",\"channel_id\":\"%d\",\"update_type\":\"channel\",\"label\":\"%s\"", cast(u64)(gid), cast(u64)(cid), label);
	if ch != null && ch.parent_id != 0 { fmt.sbprintf(*sb, ",\"parent_id\":\"%d\"", cast(u64)(ch.parent_id)); }
	fmt.sbprintf(*sb, ",%s,\"is_opt_in_only_change\":true", old);
	// last_message_type: the type of the channel's last loaded message
	if ch != null {
		{ msgs := messages_get(s, cid);
		if len(msgs) > 0 && msgs[len(msgs) - 1].id == ch.last_message_id { fmt.sbprintf(*sb, ",\"last_message_type\":%d", cast(int)(msgs[len(msgs) - 1].kind)); } }
	}
	guild_channel_props(c, *sb, gid, false);
	analytics_track(c, "notification_settings_updated", strings.to_string(sb));
}
#scope_export

// Mark As Read: every unread channel of the guild in one ack-bulk; read states
// move to each channel's last message at once.
ack_guild :: (c: *Client, gid: Snowflake) -> int {
	n: int;
	g := guild_get(*c.store, gid);
	if g == null { return 0; }
	return ack_channels(c, view(g.channels));
}

// ack_channels: one POST /read-states/ack-bulk for the unread channels among
// ids (guild Mark As Read; the Inbox's Mark All as Read).
ack_channels :: (c: *Client, ids: []Snowflake) -> int {
	n: int;
	s := *c.store;
	w: Json;
	json_init(*w);
	json_obj(*w);
	json_key(*w, "read_states");
	json_arr(*w);
	for cid: ids {
		ch := channel_get(s, cid);
		if ch == null || !channel_unread(s, cid) { continue; }
		json_obj(*w);
		json_ksnow(*w, "channel_id", cid);
		json_ksnow(*w, "message_id", ch.last_message_id);
		json_kint(*w, "read_state_type", 0);
		json_obj_end(*w);
		rs := get(s.read_states, cid);
		rs.channel_id = cid;
		rs.last_message_id = ch.last_message_id;
		rs.mention_count = 0;
		at(*s.read_states, cid).* = rs;
		n += 1;
	}
	json_arr_end(*w);
	json_obj_end(*w);
	if n == 0 { return n; }
	s.changed += 1;
	defer analytics_track(c, "mark_as_read", "\"type\":\"guild\",\"source\":\"Guild List\"");
	j := job_new(.Api, .None);
	j.method = "POST";
	j.path = "/read-states/ack-bulk";
	j.body = transmute([]u8, job_str(j, json_string(*w)));
	j.content_type = "application/json";
	j.retries = 2;
	job_submit(c, j);
	return n;
}

// Leave Server: DELETE /users/@me/guilds/{id} {"lurking":false}; the guild goes
// away with the GUILD_DELETE dispatch that follows.
leave_guild :: (c: *Client, gid: Snowflake) {
	j := job_new(.Api, .None);
	j.method = "DELETE";
	j.path = job_str(j, strings.concatenate(.{"/users/@me/guilds/", snowflake_string(gid)}, temp));
	j.referer = job_str(j, client_route_referer(c)); // the app routes home only on GUILD_DELETE
	j.body = transmute([]u8, job_str(j, "{\"lurking\":false}"));
	j.content_type = "application/json";
	job_submit(c, j);
}
#scope_file

now_ms_real :: () -> s64 {return time.time_to_unix_nano(time.now()) / 1000000;}
#scope_export

