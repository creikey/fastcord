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
//   POST   /channels/{cid}/invites                                                           (Invite People: invites.jai)
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

// iso_to_ms parses an RFC 3339 / ISO 8601 time ("2024-05-01T12:34:56.789+00:00") into unix ms; 0 if it is not one.
iso_to_ms :: (s: string) -> s64 {
	i := 0;
	num :: (n: int, sep: string) -> int #expand {
		v := 0;
		for 1..n {
			if `i >= `s.count || !is_digit(`s[`i]) `return 0;
			v = v * 10 + `s[`i] - #char "0";
			`i += 1;
		}
		if sep {
			if `i >= `s.count || !contains(sep, `s[`i]) `return 0;
			`i += 1;
		}
		return v;
	}
	ct: Calendar_Time;
	ct.year = xx num(4, "-");
	month := num(2, "-");
	day := num(2, "Tt ");
	hour := num(2, ":");
	minute := num(2, ":");
	second := num(2, "");
	if month < 1 || month > 12 || day < 1 || day > 31 || hour > 23 || minute > 59 || second > 60 return 0;
	ct.month_starting_at_0 = xx (month - 1);
	ct.day_of_month_starting_at_0 = xx (day - 1);
	ct.hour, ct.minute, ct.second = xx hour, xx minute, xx second;
	ms := 0;
	if i < s.count && s[i] == #char "." {
		i += 1;
		scale := 100;
		while i < s.count && is_digit(s[i]) {
			ms += (s[i] - #char "0") * scale;
			scale /= 10;
			i += 1;
		}
	}
	offset_min := 0;
	if i < s.count && (s[i] == #char "Z" || s[i] == #char "z") {
	} else if i < s.count && (s[i] == #char "+" || s[i] == #char "-") {
		sign := ifx s[i] == #char "-" then -1 else 1;
		i += 1;
		oh := num(2, "");
		if i < s.count && s[i] == #char ":" i += 1;
		offset_min = sign * (oh * 60 + num(2, ""));
	} else {
		return 0;
	}
	return to_milliseconds(calendar_to_apollo(ct) - UNIX_EPOCH) + ms - offset_min * 60_000;
}

// ms_to_iso formats like JS Date.toISOString(): 2026-10-26T13:00:00.000Z.
ms_to_iso :: (ms: s64, allocator := temp) -> string {
	t := to_calendar(UNIX_EPOCH + milliseconds_to_apollo(ms));
	d2 :: (x: s64) -> FormatInt #expand { return formatInt(x, minimum_digits = 2); }
	return sprint("%-%-%T%:%:%.%Z", formatInt(t.year, minimum_digits = 4), d2(t.month_starting_at_0 + 1), d2(t.day_of_month_starting_at_0 + 1),
		d2(t.hour), d2(t.minute), d2(t.second), formatInt(ms % 1000, minimum_digits = 3),, allocator);
}

// Called by apply_guild_settings (Store, UI thread) with the full settings object.
apply_guild_settings_extra :: (s: *Store, gs: *Guild_Settings, m: etf.Map) {
	if !gs.overrides.allocator.proc gs.overrides.allocator = s.allocator;
	gs.overrides.count = 0;
	gs.mute_end_ms = iso_to_ms(fstr(fmap(m, "mute_config"), "end_time"));
	gs.flags = fint(m, "flags");
	gs.mobile_push = !vhas(m, "mobile_push") || fbool(m, "mobile_push");
	gs.notify_highlights = fint(m, "notify_highlights");
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
		v := vget(om, "message_notifications");
		if !vis_null(v) o.message_notifications = vint(v);
		array_add(*gs.overrides, o);
	}
}

mute_active :: (muted: bool, end_ms: s64, now_ms: s64) -> bool {
	return muted && (end_ms == 0 || end_ms > now_ms);
}

guild_settings_get :: (s: *Store, gid: Snowflake) -> *Guild_Settings { return table_find_pointer(*s.guild_settings, gid); }

guild_is_muted :: (s: *Store, gid: Snowflake, now_ms: s64) -> bool {
	gs := guild_settings_get(s, gid);
	return gs && mute_active(gs.muted, gs.mute_end_ms, now_ms);
}

channel_override_get :: (s: *Store, gid: Snowflake, cid: Snowflake) -> *Channel_Override {
	gs := guild_settings_get(s, gid);
	if gs for * gs.overrides if it.channel_id == cid return it;
	return null;
}

// The channel's own mute (not its category's or the server's).
channel_is_muted :: (s: *Store, gid: Snowflake, cid: Snowflake, now_ms: s64) -> bool {
	o := channel_override_get(s, gid, cid);
	return o && mute_active(o.muted, o.mute_end_ms, now_ms);
}

// Muted by its own override or its category's (what the sidebar dims).
channel_effectively_muted :: (s: *Store, gid: Snowflake, cid: Snowflake, now_ms: s64) -> bool {
	if channel_is_muted(s, gid, cid, now_ms) return true;
	ch := channel_get(s, cid);
	return ch && ch.parent_id && channel_is_muted(s, gid, ch.parent_id, now_ms);
}

// Server-level level: the user's setting, else the guild's default.
guild_notify_level :: (s: *Store, gid: Snowflake) -> int {
	gs := guild_settings_get(s, gid);
	if gs return gs.message_notifications;
	g := guild_get(s, gid);
	return ifx g then g.default_message_notifications else NOTIFY_ALL;
}

// The channel's own override level (NOTIFY_INHERIT when none).
channel_notify_level :: (s: *Store, gid: Snowflake, cid: Snowflake) -> int {
	o := channel_override_get(s, gid, cid);
	return ifx o then o.message_notifications else NOTIFY_INHERIT;
}

// ---- local (optimistic) updates ----

ensure_settings :: (s: *Store, gid: Snowflake) -> *Guild_Settings {
	gs := table_find_pointer(*s.guild_settings, gid);
	if !gs {
		g := guild_get(s, gid);
		gs = table_set(*s.guild_settings, gid, .{guild_id = gid, message_notifications = ifx g then g.default_message_notifications else NOTIFY_ALL, mobile_push = true});
		gs.muted_channels.allocator = s.allocator;
		gs.collapsed_channels.allocator = s.allocator;
	}
	if !gs.overrides.allocator.proc gs.overrides.allocator = s.allocator;
	return gs;
}

ensure_override :: (gs: *Guild_Settings, cid: Snowflake) -> *Channel_Override {
	for * gs.overrides if it.channel_id == cid return it;
	array_add(*gs.overrides, .{channel_id = cid, message_notifications = NOTIFY_INHERIT});
	return *gs.overrides[gs.overrides.count - 1];
}

rebuild_muted :: (gs: *Guild_Settings) {
	gs.muted_channels.count = 0;
	for gs.overrides if it.muted array_add(*gs.muted_channels, it.channel_id);
}

// ---- REST ----

// submit_json_job queues an authenticated JSON request (body copied into the job).
submit_json_job :: (c: *Client, method: string, path: string, body: string, retries := 0, referer := "") {
	j := job_new(.Api, .None);
	j.method = method;
	j.path = job_str(j, path);
	j.body = cast([]u8) job_str(j, body);
	j.content_type = "application/json";
	j.retries = retries;
	if referer j.referer = job_str(j, referer);
	job_submit(c, j);
}

// All writes go to the bulk endpoint, keyed by guild: {"guilds":{"<gid>":<inner>}}.
patch_guild_settings :: (c: *Client, gid: Snowflake, inner: string) {
	submit_json_job(c, "PATCH", "/users/@me/guilds/settings", tprint("{\"guilds\":{\"%\":%}}", gid, inner), retries = 2);
}

// mute: {"muted":true,"mute_config":{...}}; unmute: {"muted":false} only.
write_mute :: (w: *Json, muted: bool, seconds: int, now_ms: s64) -> s64 {
	json_kbool(w, "muted", muted);
	if !muted return 0;
	end_ms: s64;
	json_key(w, "mute_config");
	json_obj(w);
	json_kint(w, "selected_time_window", seconds);
	if seconds > 0 {
		end_ms = now_ms + seconds * 1000;
		json_kstr(w, "end_time", ms_to_iso(end_ms));
	} else {
		json_knull(w, "end_time");
	}
	json_obj_end(w);
	return end_ms;
}

wall_ms :: now_ms; // for procedures whose now_ms parameter (app passes it by name) hides it

// Mute the server for `seconds` (MUTE_FOREVER: until turned back on), or unmute.
set_guild_muted :: (c: *Client, gid: Snowflake, muted: bool, seconds := MUTE_FOREVER, now_ms: s64 = 0) {
	now := ifx now_ms then now_ms else wall_ms();
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
	if muted gs.mute_end_ms = end;
	c.store.changed += 1;
	patch_guild_settings(c, gid, json_string(*w));
	track_guild_settings(c, gid, ifx muted then "muted" else "unmuted", tprint("\"guild_is_muted_old\":%", old));
}

// Mute one channel (or category) for `seconds`, or unmute it.
set_channel_muted :: (c: *Client, gid: Snowflake, cid: Snowflake, muted: bool, seconds := MUTE_FOREVER, now_ms: s64 = 0) {
	now := ifx now_ms then now_ms else wall_ms();
	w: Json;
	json_init(*w);
	json_obj(*w);
	json_key(*w, "channel_overrides");
	json_obj(*w);
	json_key(*w, tprint("%", cid));
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
	old := ifx muted
		then tprint("\"channel_is_muted_old\":%,\"channel_muted_until_old\":%,\"channel_is_overridden_old\":%", old_muted, ms_or_null(old_until), old_over)
		else tprint("\"channel_is_muted_old\":%,\"channel_is_overridden_old\":%", old_muted, old_over);
	track_channel_settings(c, gid, cid, ifx muted then "muted" else "unmuted", old);
}

// Server notification level: NOTIFY_ALL / NOTIFY_MENTIONS / NOTIFY_NOTHING.
set_guild_notify_level :: (c: *Client, gid: Snowflake, level: int) {
	patch_guild_settings(c, gid, tprint("{\"message_notifications\":%}", level));
	gs := ensure_settings(*c.store, gid);
	old := gs.message_notifications;
	gs.message_notifications = level;
	c.store.changed += 1;
	track_guild_settings(c, gid, notify_label(level), tprint("\"guild_message_notification_settings_old\":%", notify_name_json(old)));
}

// Channel notification level (NOTIFY_INHERIT: use the category / server default).
set_channel_notify_level :: (c: *Client, gid: Snowflake, cid: Snowflake, level: int) {
	patch_guild_settings(c, gid, tprint("{\"channel_overrides\":{\"%\":{\"message_notifications\":%}}}", cid, level));
	o := ensure_override(ensure_settings(*c.store, gid), cid);
	old_over := override_set(o, now_ms());
	old := o.message_notifications;
	o.message_notifications = level;
	c.store.changed += 1;
	track_channel_settings(c, gid, cid, notify_label(level), tprint("\"channel_is_overridden_old\":%,\"channel_message_notification_settings_old\":%", old_over, notify_name_json(old)));
}

// No capture covers the suppress switches: the write follows the same endpoint;
// no science event is sent (its label is unknown, and values are never invented).
set_guild_suppress_everyone :: (c: *Client, gid: Snowflake, on: bool) {
	patch_guild_settings(c, gid, tprint("{\"suppress_everyone\":%}", on));
	ensure_settings(*c.store, gid).suppress_everyone = on;
	c.store.changed += 1;
}

set_guild_suppress_roles :: (c: *Client, gid: Snowflake, on: bool) {
	patch_guild_settings(c, gid, tprint("{\"suppress_roles\":%}", on));
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

NOTIFY_NAME :: string.["All", "Mentions", "Nothing"];

notify_name_json :: (level: int) -> string {
	return ifx level < 0 || level >= NOTIFY_INHERIT then "null" else tprint("\"%\"", NOTIFY_NAME[level]);
}

notify_label :: (level: int) -> string {
	if level == {
		case NOTIFY_ALL;      return "notifications set to all messages";
		case NOTIFY_MENTIONS; return "notifications set to mentions";
		case NOTIFY_NOTHING;  return "notifications set to nothing";
	}
	return "notifications set to the default";
}

ms_or_null :: (ms: s64) -> string { return ifx ms == 0 then "null" else tprint("%", ms); }

// An override that changes anything (the official channel_is_overridden).
override_set :: (o: *Channel_Override, now: s64) -> bool {
	return mute_active(o.muted, o.mute_end_ms, now) || o.message_notifications != NOTIFY_INHERIT;
}

NOTIFY_APPROX :: "\"approx_seconds_since_last_notification\":null,\"approx_seconds_since_last_mention\":null,\"approx_seconds_since_last_role_mention\":null,\"approx_seconds_since_last_everyone_mention\":null,\"approx_seconds_since_last_guild_notification\":null,\"approx_seconds_since_last_guild_mention\":null,\"approx_seconds_since_last_guild_role_mention\":null,\"approx_seconds_since_last_guild_everyone_mention\":null";

// The guild / current-channel decorations every notification_settings_updated
// carries (the route's channel when it is in the guild); appended to a props body.
guild_channel_props :: (c: *Client, sb: *String_Builder, gid: Snowflake, with_channel_id: bool) {
	locks.lock(*c.route_mu);
	rcid := c.route_channel;
	locks.unlock(*c.route_mu);
	w := aw_begin();
	if guild_get(*c.store, gid) {
		aw_guild(*w, c, gid, false);
		ch := channel_get(*c.store, rcid);
		if ch && ch.guild_id == gid aw_channel(*w, c, rcid, with_channel_id);
	}
	json_obj_end(*w);
	body := json_body(json_string(*w));
	if body print_to_builder(sb, ",%", body);
}

track_guild_settings :: (c: *Client, gid: Snowflake, label: string, old: string) {
	gs := ensure_settings(*c.store, gid);
	sb: String_Builder;
	sb.allocator = temp;
	print_to_builder(*sb, "\"guild_muted_until\":%,\"guild_flags\":%,\"guild_is_muted\":%,\"guild_message_notification_settings\":%,\"guild_suppress_roles\":%,\"guild_receive_mobile_push\":%,\"guild_notify_highlights\":%,\"guild_suppress_everyone\":%,\"guild_scheduled_events_muted\":%,",
		ms_or_null(gs.mute_end_ms), gs.flags, mute_active(gs.muted, gs.mute_end_ms, now_ms()), notify_name_json(gs.message_notifications), gs.suppress_roles, gs.mobile_push, gs.notify_highlights, gs.suppress_everyone, gs.mute_scheduled_events);
	append(*sb, NOTIFY_APPROX);
	print_to_builder(*sb, ",\"guild_id\":\"%\",\"update_type\":\"guild\",\"label\":\"%\",%,\"is_opt_in_only_change\":true", gid, label, old);
	guild_channel_props(c, *sb, gid, true);
	analytics_track(c, "notification_settings_updated", builder_to_string(*sb,, temp));
}

track_channel_settings :: (c: *Client, gid: Snowflake, cid: Snowflake, label: string, old: string) {
	s := *c.store;
	o := ensure_override(ensure_settings(s, gid), cid);
	now := now_ms();
	muted := mute_active(o.muted, o.mute_end_ms, now);
	ch := channel_get(s, cid);
	sb: String_Builder;
	sb.allocator = temp;
	print_to_builder(*sb, "\"channel_is_muted\":%,\"channel_is_overridden\":%,\"channel_flags\":%,\"channel_message_notification_settings\":%,\"channel_muted_until\":%,",
		muted, override_set(o, now), ifx ch then ch.flags else 0, notify_name_json(o.message_notifications), ms_or_null(ifx muted then o.mute_end_ms else 0));
	append(*sb, NOTIFY_APPROX);
	print_to_builder(*sb, ",\"guild_id\":\"%\",\"channel_id\":\"%\",\"update_type\":\"channel\",\"label\":\"%\"", gid, cid, label);
	if ch && ch.parent_id print_to_builder(*sb, ",\"parent_id\":\"%\"", ch.parent_id);
	print_to_builder(*sb, ",%,\"is_opt_in_only_change\":true", old);
	// last_message_type: the type of the channel's last loaded message
	if ch {
		msgs := messages_get(s, cid);
		if msgs && msgs[msgs.count - 1].id == ch.last_message_id print_to_builder(*sb, ",\"last_message_type\":%", cast(int) msgs[msgs.count - 1].kind);
	}
	guild_channel_props(c, *sb, gid, false);
	analytics_track(c, "notification_settings_updated", builder_to_string(*sb,, temp));
}

// Mark As Read: every unread channel of the guild in one ack-bulk; read states
// move to each channel's last message at once.
ack_guild :: (c: *Client, gid: Snowflake) -> int {
	g := guild_get(*c.store, gid);
	return ifx g then ack_channels(c, g.channels) else 0;
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
		if !ch || !channel_unread(s, cid) continue;
		json_obj(*w);
		json_ksnow(*w, "channel_id", cid);
		json_ksnow(*w, "message_id", ch.last_message_id);
		json_kint(*w, "read_state_type", 0);
		json_obj_end(*w);
		rs := find_or_add(*s.read_states, cid);
		rs.channel_id = cid;
		rs.last_message_id = ch.last_message_id;
		rs.mention_count = 0;
		n += 1;
	}
	json_arr_end(*w);
	json_obj_end(*w);
	if n == 0 return 0;
	s.changed += 1;
	submit_json_job(c, "POST", "/read-states/ack-bulk", json_string(*w), retries = 2);
	analytics_track(c, "mark_as_read", "\"type\":\"guild\",\"source\":\"Guild List\"");
	return n;
}

// Leave Server: DELETE /users/@me/guilds/{id} {"lurking":false}; the guild goes
// away with the GUILD_DELETE dispatch that follows.
leave_guild :: (c: *Client, gid: Snowflake) {
	// the app routes home only on GUILD_DELETE
	submit_json_job(c, "DELETE", tprint("/users/@me/guilds/%", gid), "{\"lurking\":false}", referer = client_route_referer(c));
}
