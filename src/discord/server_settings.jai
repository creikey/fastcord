// Server Settings requests (the app's view_server_settings.jai), shaped as the official client's
// GuildSettingsActionCreators and GuildProfile actions send them. Every reply comes back as a
// .Guild_Settings feature result with channel_id = the guild and tag = the caller's request kind.

// guild_settings_call: one Server Settings request. reason rides in X-Audit-Log-Reason.
guild_settings_call :: (c: *Client, guild_id: Snowflake, tag: u64, method: string, path: string, body := "", reason := "", file := "") {
	f_submit(c, .{op = .Guild_Settings, tag = tag, channel_id = guild_id, method = method, path = path, body = body, reason = reason, file = file});
}

// ---- Server Profile: GET / PATCH /guilds/{id}/profile ----

Guild_Profile_Form :: struct {
	name: string;
	description: string;
	icon: string; // the hash the profile came with (unchanged), or "" for none
	custom_banner: string;
	visibility: int; // 1 public, 2 restricted ("Private Profile")
	brand_color: string; // "#rrggbb", "" = the icon's colour (null)
	traits: [5]Trait;
	games: []V; // game_application_ids as the profile gave them
	Trait :: struct { label: string; emoji_id: Snowflake; emoji_name: string; emoji_animated: bool; }
}

// guild_profile_form reads GET /guilds/{id}/profile's reply (the client's `wr`); strings point into it.
guild_profile_form :: (body: V) -> Guild_Profile_Form {
	m := vmap(body);
	f: Guild_Profile_Form;
	f.name = fstr(m, "name");
	f.description = fstr(m, "description");
	f.icon = fstr(m, "icon_hash");
	f.custom_banner = fstr(m, "custom_banner_hash");
	f.visibility = fint(m, "visibility");
	f.brand_color = fstr(m, "brand_color_primary");
	for flist(m, "traits") {
		t := vmap(it);
		pos := fint(t, "position");
		if pos < 0 || pos >= 5 continue;
		f.traits[pos] = .{fstr(t, "label"), fsnow(t, "emoji_id"), fstr(t, "emoji_name"), fbool(t, "emoji_animated")};
	}
	f.games = flist(m, "game_application_ids");
	return f;
}

// The client's `ow`: name, description, icon, custom_banner, visibility, brand_color_primary, traits (the
// set ones, by position), game_application_ids.
guild_profile_body :: (f: Guild_Profile_Form) -> string {
	w: Json;
	json_init(*w);
	json_obj(*w);
	json_kstr(*w, "name", f.name);
	json_kstr(*w, "description", f.description);
	if f.icon json_kstr(*w, "icon", f.icon); else json_knull(*w, "icon");
	if f.custom_banner json_kstr(*w, "custom_banner", f.custom_banner); else json_knull(*w, "custom_banner");
	if f.visibility json_kint(*w, "visibility", f.visibility);
	if f.brand_color json_kstr(*w, "brand_color_primary", f.brand_color); else json_knull(*w, "brand_color_primary");
	json_key(*w, "traits");
	json_arr(*w);
	for f.traits {
		if !it.label continue;
		json_obj(*w);
		json_kstr(*w, "label", it.label);
		json_kint(*w, "position", it_index);
		if it.emoji_id json_ksnow(*w, "emoji_id", it.emoji_id);
		if it.emoji_name json_kstr(*w, "emoji_name", it.emoji_name);
		if it.emoji_id json_kbool(*w, "emoji_animated", it.emoji_animated);
		json_obj_end(*w);
	}
	json_arr_end(*w);
	json_key(*w, "game_application_ids");
	json_arr(*w);
	for f.games json_str(*w, vstr(it));
	json_arr_end(*w);
	json_obj_end(*w);
	return json_string(*w);
}

// ---- Engagement: PATCH /guilds/{id} and /guilds/{id}/widget ----

SYSTEM_SUPPRESS_JOIN :: 1 << 0;
SYSTEM_SUPPRESS_PREMIUM :: 1 << 1;
SYSTEM_SUPPRESS_REMINDERS :: 1 << 2;
SYSTEM_SUPPRESS_JOIN_REPLIES :: 1 << 3;

Engagement_Form :: struct {
	system_channel_id: Snowflake;
	system_channel_flags: int;
	afk_channel_id: Snowflake;
	afk_timeout: int;
	default_message_notifications: int;
}

engagement_form_of :: (g: *Guild) -> Engagement_Form {
	return .{g.system_channel_id, g.system_channel_flags, g.afk_channel_id, ifx g.afk_timeout then g.afk_timeout else 300, g.default_message_notifications};
}

// The Engagement save: saveGuild's keys in its order (afk_channel_id, afk_timeout, system_channel_id,
// default_message_notifications, system_channel_flags).
engagement_body :: (f: Engagement_Form) -> string {
	w: Json;
	json_init(*w);
	json_obj(*w);
	if f.afk_channel_id json_ksnow(*w, "afk_channel_id", f.afk_channel_id); else json_knull(*w, "afk_channel_id");
	json_kint(*w, "afk_timeout", f.afk_timeout);
	if f.system_channel_id json_ksnow(*w, "system_channel_id", f.system_channel_id); else json_knull(*w, "system_channel_id");
	json_kint(*w, "default_message_notifications", f.default_message_notifications);
	json_kint(*w, "system_channel_flags", f.system_channel_flags);
	json_obj_end(*w);
	return json_string(*w);
}

// updateEmbed: {"enabled","channel_id"}.
widget_body :: (enabled: bool, channel_id: Snowflake) -> string {
	return tprint("{\"enabled\":%,\"channel_id\":%}", enabled, ifx channel_id then tprint("\"%\"", channel_id) else "null");
}
