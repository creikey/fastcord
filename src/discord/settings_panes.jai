// User Settings traffic per pane (fixtures settings, streamer_mode; 0.0.419's
// settings modal). Each pane fetches what it shows when it mounts and tracks
// settings_pane_viewed; the first pane of an open has no origin_pane.
//
//   Account        build_overrides, billing/payment-sources, billing/location-info,
//                  auth/sessions, safety-hub/@me; dismissible PINOT_MEMBER_SETTING_NEW_BADGE, TINY_BRONCO_NOTICE.
//                  With Streamer Mode on the page is replaced by an illustration:
//                  no fetches, no notice.
//   Notifications  email-settings (+ network_action_email_settings_fetch when it
//                  arrives), family-center/@me
//   Appearance     custom-themes; banner impression, CUSTOM_THEME_ENTRYPOINT_NEW_BADGE,
//                  two premium upsells (first time in a session only)
//   Voice & Video  not captured: settings_pane_viewed only

Settings_Pane :: enum u8 {
	None;
	Account;
	Appearance;
	Voice;
	Notifications;
}

settings_pane_name :: (p: Settings_Pane) -> string {
	if p == {
		case .Account;       return "account_panel";
		case .Appearance;    return "appearance_panel";
		case .Voice;         return "voice_and_video_panel";
		case .Notifications; return "notifications_panel";
	}
	return "";
}

// Session-scoped UI analytics state (fatigue counters).
Social_State :: struct {
	upsells_shown: bool; // Appearance's premium upsells (once per session)
	theme_badge_count: int; // CUSTOM_THEME_ENTRYPOINT_NEW_BADGE content_count
	ring_on_create: Snowflake; // DM call we started: ring when its CALL_CREATE arrives
	calls: Table(Snowflake, Call);
	nick_mod_props: string; // moderation_action of the server nickname PATCH in flight (social_mu)
	menu_loaded: Table(Snowflake, bool); // user menus whose once-per-user data was loaded
	notes_loaded: Table(Snowflake, bool);
	cmd_index_at: s64;
	cmd_index_guild: Snowflake;
	profile_sid: [64]u8; // the editor's profile_session_id (read by the profile fetch's worker)
	profile_sid_len: int;
}

social_destroy :: (c: *Client) {
	for c.social.calls array_free(it.ringing);
	deinit(*c.social.calls);
	deinit(*c.social.menu_loaded);
	deinit(*c.social.notes_loaded);
	free(c.social.nick_mod_props,, c.allocator);
	c.social = .{};
}

// route_now: the route the UI shows (location properties of UI events).
route_now :: (c: *Client) -> Snowflake, Snowflake {
	locks.lock(*c.route_mu);
	defer locks.unlock(*c.route_mu);
	return c.route_guild, c.route_channel;
}

// settings_pane_shown: the pane `dest` mounted (origin .None = the modal opened).
// guild_id / channel_id: the route behind the modal (location properties).
settings_pane_shown :: (c: *Client, origin: Settings_Pane, dest: Settings_Pane, guild_id: Snowflake, channel_id: Snowflake, streamer_mode := false) {
	s := *c.store;
	if dest == {
	case .Account;
		if !streamer_mode {
			open_user_settings(c);
			// 0.0.420 badges the member settings item first (fixtures settings, streamer_mode)
			analytics_dismissible(c, "PINOT_MEMBER_SETTING_NEW_BADGE", 0, guild = true, guild_id = guild_id);
			analytics_dismissible(c, "TINY_BRONCO_NOTICE", 0, guild = true, guild_id = guild_id);
		}
		settings_pane_viewed(c, origin, dest, guild_id, channel_id);
	case .Notifications;
		j := job_new(.Api, .None);
		j.method = "GET";
		j.path = "/users/@me/email-settings";
		j.on_body = (c: *Client, body: V) {
			w := aw_begin();
			json_kint(*w, "status_code", 200);
			json_kstr(*w, "url", "/users/@me/email-settings");
			json_kstr(*w, "request_method", "get");
			json_kbool(*w, "initialized", true);
			aw_track(c, "network_action_email_settings_fetch", *w);
		};
		job_submit(c, j);
		api_get_later(c, "/family-center/@me", 0);
		settings_pane_viewed(c, origin, dest, guild_id, channel_id);
	case .Appearance;
		api_get_later(c, "/users/@me/custom-themes", 0);
		{
			w := aw_begin();
			json_kstr(*w, "impression_type", "view");
			aw_route(*w, c, guild_id, channel_id);
			aw_strs(*w, "location_stack", .{});
			json_kstr(*w, "location_section", "impression_custom_themes_appearance_settings_banner");
			aw_track(c, "impression_custom_themes_appearance_settings_banner", *w);
		}
		analytics_dismissible(c, "CUSTOM_THEME_ENTRYPOINT_NEW_BADGE", c.social.theme_badge_count);
		c.social.theme_badge_count = 1;
		if !c.social.upsells_shown {
			c.social.upsells_shown = true;
			for kind: string.["premium_client_theme_try_it_out", "app_icon_upsell"] {
				w := aw_begin();
				json_kstr(*w, "type", kind);
				aw_strs(*w, "location_stack", string.["user settings"]);
				aw_track(c, "premium_upsell_viewed", *w);
			}
		}
		settings_pane_viewed(c, origin, dest, guild_id, channel_id);
	case .Voice;
		settings_pane_viewed(c, origin, dest, guild_id, channel_id);
	case .None;
	}
}

settings_pane_viewed :: (c: *Client, origin: Settings_Pane, dest: Settings_Pane, guild_id: Snowflake, channel_id: Snowflake) {
	w := aw_begin();
	json_kstr(*w, "settings_type", "user");
	if origin != .None json_kstr(*w, "origin_pane", settings_pane_name(origin));
	json_kstr(*w, "destination_pane", settings_pane_name(dest));
	aw_strs(*w, "location_stack", .{});
	json_knull(*w, "search_session_id");
	aw_route(*w, c, guild_id, channel_id);
	aw_track(c, "settings_pane_viewed", *w);
}

// analytics_ui_setting: ui_setting_interacted for a settings control.
analytics_ui_setting :: (c: *Client, key: string) {
	w := aw_begin();
	json_kstr(*w, "key", key);
	json_kstr(*w, "setting_type", "user_settings");
	json_knull(*w, "search_session_id");
	aw_track(c, "ui_setting_interacted", *w);
}

// set_friend_online_notifications: Notifications > "Friends come online"
// (NotificationSettings field 12, a BoolValue written explicitly both ways).
set_friend_online_notifications :: (c: *Client, on: bool) {
	c.settings_edit.friend_online = on;
	c.settings_edit.has_friend_online = true;
	c.store.settings.friend_online_off = !on;
	c.store.changed += 1;
	analytics_ui_setting(c, "friend_online_notifications");
	w := aw_begin();
	json_kstr(*w, "update_type", "account");
	json_kbool(*w, "friend_online_notifications", on);
	aw_track(c, "notification_settings_updated", *w);
	settings_mark(c, SETTINGS_DELAY_INFREQUENT_MS);
}

// theme_analytics_name: client_theme_updated's theme_name.
theme_analytics_name :: (t: Theme, system: bool) -> string {
	if system return "default system";
	if t == {
		case .Light;    return "default light";
		case .Dark;     return "default dark";
		case .Midnight; return "default midnight";
	}
	return "default darker";
}

// ---- Edit Profiles (the full-screen profile editor) ----

// open_profile_editor: the requests and events of opening "Edit Profiles"
// (fixture settings/open_profiles). The games / applications/public /
// oauth2/tokens follow-ups depend on profile widget data and are not issued.
open_profile_editor :: (c: *Client) {
	me := c.store.me;
	us := snowflake_string(me);
	api_get_later(c, tprint("/content-inventory/users/%/outbox", us), 0);
	sid := uuid4(,, temp);
	{
		q: Query;
		query_init(*q, tprint("/users/%/profile", us));
		query_add(*q, "type", "modal");
		query_add_bool(*q, "with_mutual_guilds", true);
		query_add_bool(*q, "with_mutual_friends", false);
		query_add_bool(*q, "with_mutual_friends_count", true);
		j := job_new(.Api, .Fetch_Profile);
		j.method = "GET";
		j.path = job_str(j, query_string(*q));
		j.result = .{op = .Fetch_Profile, user_id = me};
		// the worker reads the session id from this fixed buffer (no allocation shared across threads)
		c.social.profile_sid_len = min(sid.count, c.social.profile_sid.count);
		memcpy(c.social.profile_sid.data, sid.data, c.social.profile_sid_len);
		j.on_body = (c: *Client, body: V) {
			m := vmap(body);
			sid := string.{c.social.profile_sid_len, c.social.profile_sid.data};
			profile_action(c, sid, "VIEW", fint(m, "mutual_friends_count"), flist(m, "mutual_guilds").count, true);
			promo_editor_held(c, body);
		};
		job_submit(c, j);
	}
	api_get_later(c, "/users/@me/referrals/eligibility", 75);
	atomic_store(*c.promo.editor_held, 0);
	j := job_new(.Api, .None); // the empty fields preview Shop items from it
	j.method = "GET";
	j.path = job_str(j, "/collectibles-categories/v2?include_bundles=true&variants_return_style=2&skip_num_categories=0");
	j.not_before = now_ms() + 75;
	j.on_body = promo_editor_previews;
	job_submit(c, j);
	api_get_later(c, "/users/@me/collectibles-purchases?variants_return_style=2", 75);
	fetch_note(c, me, 75);
	api_get_later(c, tprint("/users/%/application-identities?with_profiles=true", us), 75);
	api_get_later(c, "/widget-configs/featured", 75);
	api_get_later(c, "/users/@me/widgets/suggested-games", 75);
	api_get_later(c, "/users/@me/activities/statistics/applications", 265);
	// the editor's Nitro preview (profile effect presets) and Shop / Nitro entry points render
	w := aw_begin();
	json_kstr(*w, "feature_name", "preset");
	json_kstr(*w, "feature_tier", "premium-standard");
	aw_track(c, "premium_feature_try_out", *w);
	promo_profile_upsells(c, 1);
	profile_action(c, sid, "VIEW_WIDGETS_EMPTY_STATE", 0, 0, false);
	g, ch := route_now(c);
	impression_modal_root(c, "UserProfileModalV2", g, ch);
}

// impression_modal_root_legacy for a modal (variant = the modal's component).
impression_modal_root :: (c: *Client, variant: string, guild_id: Snowflake, channel_id: Snowflake) {
	w := aw_begin();
	json_kstr(*w, "impression_type", "page");
	aw_route(*w, c, guild_id, channel_id);
	json_kstr(*w, "variant", variant);
	json_kstr(*w, "location", "impression_modal_root_legacy");
	json_kstr(*w, "location_page", "impression_modal_root_legacy");
	aw_track(c, "impression_modal_root_legacy", *w);
}
#scope_file

// user_profile_action for our own profile in the editor (MODAL_V2).
profile_action :: (c: *Client, sid: string, action: string, mutual_friends: s64, mutual_guilds: s64, counts: bool) {
	w := aw_begin();
	json_kstr(*w, "profile_layout", "MODAL_V2");
	json_kstr(*w, "profile_session_id", sid);
	aw_strs(*w, "profile_properties", .{});
	aw_strs(*w, "guild_profile_properties", .{});
	aw_strs(*w, "profile_activity_types", .{});
	aw_strs(*w, "profile_badges", .{});
	json_kstr(*w, "user_status", tprint("%-desktop", status_name(c.store.settings.status)));
	json_kbool(*w, "is_guild_profile", false);
	json_kbool(*w, "is_bot_profile", false);
	json_kbool(*w, "is_private_to_viewer", false);
	json_ksnow(*w, "related_user_id", c.store.me);
	json_kint(*w, "relationship_type", 0);
	if counts {
		json_kint(*w, "num_mutual_friends", mutual_friends);
		json_kint(*w, "num_mutual_guilds", mutual_guilds);
	}
	json_knull(*w, "application_linked");
	aw_strs(*w, "location_stack", string.["user profile modal v2"]);
	json_kstr(*w, "profile_action", action);
	aw_track(c, "user_profile_action", *w);
}
#scope_export

