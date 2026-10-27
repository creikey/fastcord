// UI-owned telemetry: one typed helper per /science event, so the app (and the
// library actions it calls) report what the user did at the moment the
// official client would, with the official property keys in their order.
//
// Pattern for a new event (see traffic/PARITY.md "Telemetry"):
//   analytics_<event> :: proc(c: ^Client, ...) {
//       w := aw_begin()
//       json_kstr(&w, "type", ...)          // the event's own properties, in fixture order
//       aw_guild(&w, c, guild_id)           // shared groups (guild / channel / location)
//       aw_track(c, "<event>", &w)
//   }
// Every value is measured by fastcord itself (store state, our own timings,
// ids we generated). When a value cannot be produced truthfully the event is
// not sent at all, and listed in analytics_unknowable (analytics.odin).

// PERMISSIONS_ALL_BUILD: Permissions.ALL of the client build fastcord
// identifies as (client_build_number 649389): owners/administrators report
// this union of every flag the build knows, not all 64 bits.
PERMISSIONS_ALL_BUILD :: cast(u64)(17873661021126655);

aw_begin :: () -> Json {
	w: Json;
	json_init(*w);
	json_obj(*w);
	return w;
}

aw_track :: (c: *Client, event_type: string, w: *Json) {
	json_obj_end(w);
	analytics_track(c, event_type, json_body(json_string(w)));
}
#scope_module

aw_perms :: (w: *Json, k: string, perms: u64) {
	json_kstr(w, k, fmt.tprintf("%d", perms & PERMISSIONS_ALL_BUILD));
}

aw_ksnow_or_null :: (w: *Json, k: string, id: Snowflake) {
	if id != 0 { json_ksnow(w, k, id); } else { json_knull(w, k); }
}

aw_kf64 :: (w: *Json, k: string, v: float64) {
	sb := strings.builder_make(temp);
	write_js_number(*sb, v);
	json_key(w, k);
	json_raw(w, strings.to_string(sb));
}
#scope_export

// aw_guild: the guild decoration (getGuildAnalyticsProperties: guild_id,
// sizes, our roles and permissions, users in voice).
aw_guild :: (w: *Json, c: *Client, guild_id: Snowflake, with_id := true) {
	s := *c.store;
	g := guild_get(s, guild_id);
	if with_id { json_ksnow(w, "guild_id", guild_id); }
	// GuildChannelStore: SELECTABLE (text-like) and VOCAL channels
	text, voice, in_voice := 0, 0, 0;
	if g != null {
		for cid: g.channels {
			ch := channel_get(s, cid);
			if ch == null { continue; }
			if ch.kind == {
			case .Guild_Text; #through; case .Guild_Announcement; #through; case .Guild_Forum; #through; case .Guild_Media;
				text += 1;
			case .Guild_Voice; #through; case .Guild_Stage_Voice;
				voice += 1;
			}
		}
		for _, vs: s.voice_states { if vs.guild_id == guild_id && vs.channel_id != 0 { in_voice += 1; } }
	}
	json_kint(w, "guild_size_total", ifx g != null then cast(s64)(g.member_count) else 0);
	json_kint(w, "guild_num_channels", cast(s64)(text + voice));
	json_kint(w, "guild_num_text_channels", cast(s64)(text));
	json_kint(w, "guild_num_voice_channels", cast(s64)(voice));
	json_kint(w, "guild_num_roles", ifx g != null then cast(s64)(len(g.roles)) else 0);
	roles := 0;
	{ r := my_guild_roles(guild_id);
	if !is_null(r) { roles = len(r); } else { m := member_get(s, guild_id, s.me);
if !is_null(m) { roles = len(m.roles); } } }
	json_kint(w, "guild_member_num_roles", cast(s64)(roles));
	aw_perms(w, "guild_member_perms", guild_permissions(s, guild_id));
	vip := false;
	if g != null { for f: g.features { if f == "VIP_REGIONS" { vip = true; } } }
	json_kbool(w, "guild_is_vip", vip);
	json_kbool(w, "is_member", g != null);
	json_kint(w, "num_voice_channels_active", cast(s64)(in_voice)); // the guild's voice states (users)
}

// aw_channel: the channel decoration (getChannelAnalyticsProperties): type,
// recipients of a private channel, our permissions, and whether @everyone is
// denied VIEW_CHANNEL (a thread: on its parent).
aw_channel :: (w: *Json, c: *Client, channel_id: Snowflake, with_id := true) {
	s := *c.store;
	ch := channel_get(s, channel_id);
	if with_id { json_ksnow(w, "channel_id", channel_id); }
	json_kint(w, "channel_type", ifx ch != null then cast(s64)(ch.kind) else 0);
	private := ch != null && ch.guild_id == 0;
	json_kint(w, "channel_size_total", ifx private then cast(s64)(len(ch.recipient_ids)) else 0);
	perms: u64 = ifx ch != null && !private then channel_permissions(s, channel_id) else 0;
	aw_perms(w, "channel_member_perms", perms);
	hidden := false;
	if ch != null && !private {
		src := ch;
		if is_thread(ch) && ch.parent_id != 0 { { p := channel_get(s, ch.parent_id);
if !is_null(p) { src = p; } } }
		for o: src.overwrites { if o.kind == 0 && o.id == ch.guild_id && (o.deny & PERM_VIEW_CHANNEL) != 0 { hidden = true; } }
	}
	json_kbool(w, "channel_hidden", hidden);
}

// aw_route_props: the guild decoration, then the channel's when it belongs to
// that guild (trackWithMetadata's location properties for a guild route).
aw_route_props :: (w: *Json, c: *Client, guild_id: Snowflake, channel_id: Snowflake, with_channel_id := true) {
	if guild_get(*c.store, guild_id) == null { return; }
	aw_guild(w, c, guild_id);
	{ ch := channel_get(*c.store, channel_id);
	if ch != null && ch.guild_id == guild_id { aw_channel(w, c, channel_id, with_channel_id); } }
}
#scope_module

// aw_route: guild + channel decorations of a known guild / channel (each left
// out when unknown), channel only for DMs.
aw_route :: (w: *Json, c: *Client, guild_id: Snowflake, channel_id: Snowflake) {
	if guild_id != 0 && guild_get(*c.store, guild_id) != null { aw_guild(w, c, guild_id); }
	if channel_id != 0 && channel_get(*c.store, channel_id) != null { aw_channel(w, c, channel_id); }
}
#scope_export

// analytics_dismissible: dismissible_content_shown for a DismissibleContent type.
// guild: write "guild_id" (null when 0). version: written when > 0.
analytics_dismissible :: (c: *Client, kind: string, count: int, guild := false, guild_id: Snowflake = 0, version := 0) {
	w := aw_begin();
	json_kstr(*w, "type", kind);
	json_knull(*w, "unselected_content_types");
	json_kint(*w, "content_count", cast(s64)(count));
	json_kint(*w, "fatigable_content_count", 0);
	json_kbool(*w, "bypass_fatigue", true);
	if guild { aw_ksnow_or_null(*w, "guild_id", guild_id); }
	if version > 0 { json_kint(*w, "version", cast(s64)(version)); }
	aw_track(c, "dismissible_content_shown", *w);
}
#scope_module

aw_location :: (w: *Json, location: string, page: string, section: string) {
	json_kstr(w, "location", location);
	json_kstr(w, "location_page", page);
	json_kstr(w, "location_section", section);
}

aw_strs :: (w: *Json, k: string, items: []string) {
	json_key(w, k);
	json_arr(w);
	for it_: items { json_str(w, it_); }
	json_arr_end(w);
}

// load_id / session ids: the client's uuid v4 (hex without dashes for load ids).
analytics_load_id :: (allocator := context.allocator) -> string {
	u := uuid4(temp);
	out, _ := strings.remove_all(u, "-", allocator);
	return out;
}

// The page a guild channel or DM is, as analytics locations name it.
route_location :: (c: *Client, guild_id: Snowflake) -> string {
	return ifx guild_id != 0 then "Guild Channel" else "DM Channel";
}
#scope_export

// ---- message context menu ----

Message_Menu :: struct {
	open: bool;
	opened_ms: s64;
	first_click: s64;
	channel_id: Snowflake;
	guild_id: Snowflake;
	message_id: Snowflake;
}

// message_menu_opened: right click on a message (MessageContextMenu): the
// popout event, then the guild command index lookups (two reads of the
// application command cache: before and after the index starts loading).
message_menu_opened :: (c: *Client, guild_id: Snowflake, channel_id: Snowflake, message_id: Snowflake, location := "right_click") {
	a := *c.analytics;
	a.menu = .{open = true, opened_ms = now_ms(), channel_id = channel_id, guild_id = guild_id, message_id = message_id};
	w := aw_begin();
	json_ksnow(*w, "message_id", message_id);
	json_ksnow(*w, "channel", channel_id);
	json_kstr(*w, "location", location);
	aw_track(c, "message_popout_menu_opened_desktop", *w);
	if guild_id != 0 {
		miss := !get(c.command_index_guilds, guild_id);
		analytics_command_cache_fetch(c, miss, len(c.command_index_guilds));
		open_message_context_menu(c, guild_id);
		analytics_command_cache_fetch(c, miss, len(c.command_index_guilds));
	} else {
		open_message_context_menu(c, 0);
	}
}

// message_menu_item_clicked: the first click on a menu item (time to select).
message_menu_item_clicked :: (c: *Client) {
	m := *c.analytics.menu;
	if m.open && m.first_click == 0 { m.first_click = now_ms(); }
}

// message_menu_closed: the menu went away (an item was chosen or it was dismissed).
message_menu_closed :: (c: *Client) {
	m := *c.analytics.menu;
	if !m.open { return; }
	m.open = false;
	now := now_ms();
	w := aw_begin();
	json_kint(*w, "time_to_close_ms", now - m.opened_ms);
	json_ksnow(*w, "channel_id", m.channel_id);
	aw_ksnow_or_null(*w, "guild_id", m.guild_id);
	json_ksnow(*w, "message_id", m.message_id);
	aw_track(c, "message_menu_time_to_close", *w);
	if m.first_click != 0 {
		w2 := aw_begin();
		json_kint(*w2, "time_to_first_click_ms", m.first_click - m.opened_ms);
		json_ksnow(*w2, "channel_id", m.channel_id);
		aw_ksnow_or_null(*w2, "guild_id", m.guild_id);
		json_ksnow(*w2, "message_id", m.message_id);
		aw_track(c, "message_menu_time_to_select", *w2);
	}
}

analytics_command_cache_fetch :: (c: *Client, miss: bool, size: int) {
	w := aw_begin();
	json_kbool(*w, "miss", miss);
	json_kint(*w, "size", cast(s64)(size));
	aw_track(c, "application_command_cache_fetch", *w);
}

// analytics_command_index_loaded: application_command_performance when a
// command index response arrives (worker thread; analytics_track is locked).
analytics_command_index_loaded :: (c: *Client, j: *Job, status: int) {
	if status == 0 { return; } // network failure: the official tracks an error we don't model
	w := aw_begin();
	aw_kf64(*w, "duration_ms", now_ms_f() - j.started_ms);
	json_kbool(*w, "error", status >= 400);
	json_kbool(*w, "aborted", false);
	json_kbool(*w, "include_applications", true);
	json_kint(*w, "retries", 0);
	json_knull(*w, "kind");
	json_knull(*w, "command_type");
	path := j.path;
	json_kstr(*w, "url", path);
	user := strings.has_prefix(path, "/users/");
	json_kstr(*w, "target_type", ifx user then "user" else "guild");
	if user { json_knull(*w, "target_id"); } else { json_kstr(*w, "target_id", strings.trim_suffix(strings.trim_prefix(path, "/guilds/"), "/application-command-index")); }
	json_key(*w, "failure_statuses");
	json_arr(*w);
	if status >= 400 { json_int(*w, cast(s64)(status)); }
	json_arr_end(*w);
	aw_track(c, "application_command_performance", *w);
}

// private_channel_menu_opened: right click on a DM in the DM list
// (the menu impression, then the user command index load).
private_channel_menu_opened :: (c: *Client) {
	locks.lock(*c.route_mu);
	route_channel := c.route_channel;
	locks.unlock(*c.route_mu);
	// The impression's location is the page the list is shown on; only the
	// friends page's name is known from the captures.
	if route_channel == 0 {
		w := aw_begin();
		json_kstr(*w, "impression_type", "menu");
		aw_location(*w, "impression_friends", "impression_friends", "impression_dm_list_right_click_menu_shown");
		aw_track(c, "impression_dm_list_right_click_menu_shown", *w);
	}
	open_message_context_menu(c, 0);
}

// ---- expression pickers (emoji / reaction / gif) ----

Picker_Kind :: enum u8 {
	Emoji; // the composer's emoji picker
	Reaction; // a message's reaction picker
	Gif;
}

// Expression_Counts: what the picker shows, counted by the app.
Expression_Counts :: struct {
	favorites, animated_favorites, custom_favorites, standard_favorites: int;
	frecent, animated_frecent, custom_frecent, standard_frecent: int;
	current_guild, custom_total: int;
	top_server, animated_top_server: int;
	newly_added, animated_newly_added: int;
}

Picker_Search :: struct {
	open: bool;
	kind: Picker_Kind;
	load_id: string; // c.allocator
	guild_id: Snowflake;
	channel_id: Snowflake;
	message_id: Snowflake;
	started: bool;
	query: string; // c.allocator
}
#scope_module

search_type_name :: (k: Picker_Kind) -> string {
	if k == {
	case .Emoji;
		return "EMOJI";
	case .Reaction;
		return "EMOJI_REACTION";
	case .Gif;
		return "GIF";
	}
	return "";
}

aw_search_head :: (w: *Json, c: *Client, p: *Picker_Search) {
	json_kstr(w, "search_type", search_type_name(p.kind));
	json_kstr(w, "load_id", p.load_id);
}

aw_search_tail :: (w: *Json, c: *Client, p: *Picker_Search) {
	aw_route(w, c, p.guild_id, p.channel_id);
	if p.kind != .Gif { aw_location(w, route_location(c, p.guild_id), route_location(c, p.guild_id), "Emoji Picker Popout"); }
}

aw_counts :: (w: *Json, n: Expression_Counts) {
	json_kint(w, "num_expressions_favorites", cast(s64)(n.favorites));
	json_kint(w, "num_animated_expressions_favorites", cast(s64)(n.animated_favorites));
	json_kint(w, "num_custom_expressions_favorites", cast(s64)(n.custom_favorites));
	json_kint(w, "num_standard_expressions_favorites", cast(s64)(n.standard_favorites));
	json_kint(w, "num_expressions_frecent", cast(s64)(n.frecent));
	json_kint(w, "num_animated_expressions_frecent", cast(s64)(n.animated_frecent));
	json_kint(w, "num_custom_expressions_frecent", cast(s64)(n.custom_frecent));
	json_kint(w, "num_standard_expressions_frecent", cast(s64)(n.standard_frecent));
	json_kint(w, "num_current_guild_expressions", cast(s64)(n.current_guild));
	json_kint(w, "num_custom_expressions_total", cast(s64)(n.custom_total));
	json_kint(w, "num_expressions_top_server", cast(s64)(n.top_server));
	json_kint(w, "num_animated_expressions_top_server", cast(s64)(n.animated_top_server));
	json_kint(w, "num_expressions_newly_added", cast(s64)(n.newly_added));
	json_kint(w, "num_animated_expressions_newly_added", cast(s64)(n.animated_newly_added));
}
#scope_export

// expression_picker_opened: a picker opened (telemetry only: the picker's loads
// are open_emoji_picker / gifs_trending). width: the gif picker's CSS width.
expression_picker_opened :: (c: *Client, kind: Picker_Kind, guild_id: Snowflake, channel_id: Snowflake, counts := Expression_Counts.{}, message_id: Snowflake = 0, width := 0) {
	p := *c.analytics.picker;
	picker_reset(c);
	p.* = .{open = true, kind = kind, load_id = analytics_load_id(c.allocator), guild_id = guild_id, channel_id = channel_id, message_id = message_id};
	if kind == {
	case .Reaction;
		w := aw_begin();
		json_kstr(*w, "tab", "emoji");
		json_kbool(*w, "badged", false);
		aw_counts(*w, counts);
		json_kbool(*w, "is_burst", false);
		aw_route(*w, c, guild_id, channel_id);
		aw_track(c, "reaction_picker_opened", *w);
		w2 := aw_begin();
		json_kstr(*w2, "type", "message_reaction_emoji_picker");
		aw_ksnow_or_null(*w2, "guild_id", guild_id);
		aw_channel(*w2, c, channel_id);
		aw_track(c, "open_popout", *w2);
		w3 := aw_begin();
		aw_search_head(*w3, c, p);
		aw_search_tail(*w3, c, p);
		aw_track(c, "search_opened", *w3);
	case .Emoji;
		w := aw_begin();
		aw_search_head(*w, c, p);
		aw_search_tail(*w, c, p);
		aw_track(c, "search_opened", *w);
		w2 := aw_begin();
		json_kstr(*w2, "tab", "emoji");
		json_kbool(*w2, "badged", false);
		aw_counts(*w2, counts);
		aw_route(*w2, c, guild_id, channel_id);
		aw_track(c, "expression_picker_opened", *w2);
	case .Gif;
		w := aw_begin();
		aw_search_head(*w, c, p);
		aw_route(*w, c, guild_id, channel_id);
		aw_track(c, "search_opened", *w);
		w2 := aw_begin();
		json_kint(*w2, "width", cast(s64)(width));
		json_kstr(*w2, "tab", "gif");
		json_kbool(*w2, "badged", false);
		aw_route(*w2, c, guild_id, channel_id);
		aw_track(c, "expression_picker_opened", *w2);
	}
}
#scope_module

picker_reset :: (c: *Client) {
	p := *c.analytics.picker;
	delete(p.load_id, c.allocator);
	delete(p.query, c.allocator);
	p.* = .{};
}
#scope_export

// picker_search_typed: the emoji picker's search text changed to `query`
// (the first character starts the search session).
picker_search_typed :: (c: *Client, query: string) {
	p := *c.analytics.picker;
	if !p.open || p.kind == .Gif || query == "" { return; }
	delete(p.query, c.allocator);
	p.query = clone(query, c.allocator);
	if p.started { return; }
	p.started = true;
	w := aw_begin();
	aw_search_head(*w, c, p);
	aw_search_tail(*w, c, p);
	aw_track(c, "search_started", *w);
}

// picker_search_results: the emoji picker's results for `query` rendered.
// total: results shown; locked: results the user cannot use (not Nitro).
picker_search_results :: (c: *Client, query: string, total: int, locked := 0) {
	p := *c.analytics.picker;
	if !p.open || p.kind == .Gif || query == "" { return; }
	picker_search_typed(c, query);
	w := aw_begin();
	json_kstr(*w, "search_type", search_type_name(p.kind));
	json_kint(*w, "total_results", cast(s64)(total));
	json_kint(*w, "num_results_locked", cast(s64)(locked));
	json_kstr(*w, "query", query);
	json_kstr(*w, "load_id", p.load_id);
	aw_search_tail(*w, c, p);
	aw_track(c, "search_result_viewed", *w);
}

// picker_emoji_selected: an emoji was picked from search results (the picker closes).
// emoji_name is the emoji's name as the picker lists it ("thumbsup", "fastcord_test").
picker_emoji_selected :: (c: *Client, emoji_name: string, emoji_id: Snowflake = 0, emoji_guild: Snowflake = 0, animated := false, locked := false) {
	p := *c.analytics.picker;
	if !p.open { return; }
	if p.query != "" {
		w := aw_begin();
		json_kstr(*w, "search_type", search_type_name(p.kind));
		if emoji_id != 0 {
			json_ksnow(*w, "expression_guild_id", emoji_guild);
			json_ksnow(*w, "emoji_id", emoji_id);
		}
		json_kstr(*w, "emoji_name", emoji_name);
		json_kbool(*w, "is_custom", emoji_id != 0);
		json_kbool(*w, "is_animated", animated);
		json_kbool(*w, "is_locked", locked);
		json_kstr(*w, "query", p.query);
		json_kstr(*w, "load_id", p.load_id);
		if p.message_id != 0 { json_ksnow(*w, "message_id", p.message_id); }
		aw_search_tail(*w, c, p);
		json_kstr(*w, "location_object", "Emoji");
		aw_track(c, "search_result_selected", *w);
	}
	picker_reset(c);
}

// picker_closed: the picker went away without a pick.
picker_closed :: (c: *Client) {picker_reset(c);}

// ---- profiles ----

Profile_Layout :: enum u8 {
	Popout;
	Modal;
	Account_Popout;
	Sidebar;
}

// Profile_View: a profile surface waiting for its profile to load before it
// reports what it shows (user_profile_action VIEW).
Profile_View :: struct {
	pending: bool;
	layout: Profile_Layout;
	user_id: Snowflake;
	guild_id: Snowflake;
	channel_id: Snowflake;
	message_id: Snowflake;
	session: string; // c.allocator
	source_session: string; // c.allocator (the popout a modal was opened from)
	wait: int; // profile responses still to come before it renders
	mutuals_known: bool; // mutual counts were loaded before it opened (sidebars show them)
}
#scope_module

profile_layout_name :: (l: Profile_Layout) -> string {
	if l == {
	case .Popout;
		return "POPOUT";
	case .Modal;
		return "MODAL_V2";
	case .Account_Popout;
		return "ACCOUNT_POPOUT";
	case .Sidebar;
		return "SIDEBAR";
	}
	return "";
}

profile_view_free :: (c: *Client, v: *Profile_View) {
	delete(v.session, c.allocator);
	delete(v.source_session, c.allocator);
	v.* = .{};
}
#scope_export

// profile_view_begin: a profile surface opened; user_profile_action goes out
// when its profile arrives (analytics_on_profile).
profile_view_begin :: (c: *Client, layout: Profile_Layout, user_id: Snowflake, guild_id: Snowflake, channel_id: Snowflake, message_id: Snowflake, wait := 1) {
	a := *c.analytics;
	src := "";
	if layout == .Modal && a.profile.layout == .Popout && a.profile.session != "" && a.profile.user_id == user_id {
		src = clone(a.profile.session, c.allocator);
	}
	profile_view_free(c, *a.profile);
	u := user_get(*c.store, user_id);
	known := u != null && u.mutual_guilds >= 0 && u.mutual_friends >= 0;
	a.profile = .{pending = true, layout = layout, user_id = user_id, guild_id = guild_id, channel_id = channel_id, message_id = message_id, session = uuid4(c.allocator), source_session = src, wait = wait, mutuals_known = known};
}
#scope_module

// profile_shows_nothing_extra: true when the profile has none of the optional
// sections (bio, pronouns, badges, activity, guild identity). Then the
// properties lists are truthfully empty; otherwise fastcord does not know the
// official enum values for them and the event is not sent.
profile_shows_nothing_extra :: (c: *Client, user_id: Snowflake, guild_id: Snowflake) -> bool {
	s := *c.store;
	u := user_get(s, user_id);
	if u == null { return false; }
	if u.bio != "" || u.pronouns != "" || u.flags != 0 || u.premium_type != 0 { return false; }
	{ p, ok := map_find(s.presences, user_id);
	if ok && p.activity != "" { return false; } }
	if guild_id != 0 {
		{ m := member_get(s, guild_id, user_id);
		if !is_null(m) && (m.nick != "" || m.avatar != "") { return false; } }
	}
	return true;
}

// user_status_string: "online-desktop" etc., from the user's presence.
user_status_string :: (c: *Client, user_id: Snowflake) -> string {
	s := *c.store;
	st, plat := Status.Offline, "";
	if user_id == s.me {
		st, plat = s.settings.status, "desktop";
		if st == .Offline || st == .Invisible { st = .Invisible; }
	} else { p, ok := map_find(s.presences, user_id);
if ok {
		st = p.status;
		if p.desktop != .Offline { plat = "desktop"; } else if p.mobile != .Offline { plat = "mobile"; } else if p.web != .Offline { plat = "web"; }
	} }
	if plat == "" || st == .Offline { return status_name(st); }
	return fmt.tprintf("%s-%s", status_name(st), plat);
}
#scope_export

// analytics_on_profile: a profile response arrived (UI thread).
analytics_on_profile :: (c: *Client, user_id: Snowflake) {
	v := *c.analytics.profile;
	if !v.pending || v.user_id != user_id { return; }
	v.wait -= 1;
	if v.wait > 0 { return; }
	v.pending = false;
	if !profile_shows_nothing_extra(c, user_id, v.guild_id) { return; }
	stack: []string;
	if v.layout == {
	case .Popout;
		stack = string.["username", "user profile popout"];
	case .Modal;
		if v.source_session != "" { stack = string.["username", "user profile popout", "user profile modal v2"]; } else { stack = string.["user profile modal v2"]; }
	case .Account_Popout;
		stack = string.["account", "user profile account popout"];
	case .Sidebar;
		stack = string.["user profile sidebar"];
	}
	if v.layout == .Modal {
		w := aw_begin();
		json_kstr(*w, "impression_type", "page");
		aw_route(*w, c, v.guild_id, v.channel_id);
		json_kstr(*w, "variant", "UserProfileModalV2");
		json_kstr(*w, "location", "impression_modal_root_legacy");
		json_kstr(*w, "location_page", "impression_modal_root_legacy");
		aw_track(c, "impression_modal_root_legacy", *w);
	}
	profile_action(c, v, stack, "VIEW");
}
#scope_module

profile_action :: (c: *Client, v: *Profile_View, stack: []string, action: string) {
	s := *c.store;
	w := aw_begin();
	if v.layout != .Account_Popout { aw_route(*w, c, v.guild_id, v.channel_id); }
	json_kstr(*w, "profile_layout", profile_layout_name(v.layout));
	json_kstr(*w, "profile_session_id", v.session);
	if v.source_session != "" { json_kstr(*w, "source_profile_session_id", v.source_session); }
	for k: (string.["profile_properties", "guild_profile_properties", "profile_activity_types", "profile_badges"]) {
		json_key(*w, k);
		json_raw(*w, "[]");
	}
	json_kstr(*w, "user_status", user_status_string(c, v.user_id));
	u := user_get(s, v.user_id);
	json_kbool(*w, "is_guild_profile", v.guild_id != 0);
	json_kbool(*w, "is_bot_profile", u != null && u.bot);
	json_kbool(*w, "is_private_to_viewer", false);
	json_ksnow(*w, "related_user_id", v.user_id);
	rel, has_rel := map_find(s.relationships, v.user_id);
	json_kint(*w, "relationship_type", ifx has_rel then cast(s64)(rel.kind) else 0);
	if has_rel && rel.since != "" { json_kstr(*w, "related_since", rel.since); }
	if v.layout == .Sidebar && v.mutuals_known && u != null {
		json_kint(*w, "num_mutual_friends", cast(s64)(u.mutual_friends));
		json_kint(*w, "num_mutual_guilds", cast(s64)(u.mutual_guilds));
	}
	json_knull(*w, "application_linked");
	aw_strs(*w, "location_stack", stack);
	json_kstr(*w, "profile_action", action);
	if v.message_id != 0 { json_ksnow(*w, "source_message_id", v.message_id); }
	aw_track(c, "user_profile_action", *w);
}
#scope_export

// ---- status, custom status, theme ----

Clear_After :: enum u8 {
	Dont_Clear;
	Today;
	Hours_4;
	Hour_1;
	Minutes_30;
}
#scope_module

clear_after_name :: (k: Clear_After) -> string {
	if k == {
	case .Dont_Clear;
		return "DONT_CLEAR";
	case .Today;
		return "TODAY";
	case .Hours_4;
		return "HOURS_4";
	case .Hour_1;
		return "HOURS_1";
	case .Minutes_30;
		return "MINUTES_30";
	}
	return "";
}

analytics_status_updated :: (c: *Client, prev: Status, next: Status) {
	a := *c.analytics;
	now := now_ms();
	w := aw_begin();
	json_kstr(*w, "next_status", status_name(next));
	json_kstr(*w, "prev_status", status_name(prev));
	keys := string.["approx_seconds_since_last_notification", "approx_seconds_since_last_mention", "approx_seconds_since_last_role_mention", "approx_seconds_since_last_everyone_mention"];
	for t, i: (s64.[a.last_notification_ms, a.last_mention_ms, a.last_role_mention_ms, a.last_everyone_mention_ms]) {
		k := keys[i];
		if t == 0 { json_knull(*w, k); } else { json_kint(*w, k, (now - t) / 1000); }
	}
	aw_track(c, "user_status_updated", *w);
}

// analytics_ack_props: ack_messages' properties (AckMessagesAnalytics: every
// guild's "id,hasUnread,mentions,muted,unreadSetting" in guild list order).
analytics_ack_props :: (c: *Client, channel_id: Snowflake, location: Ack_Location) -> string {
	s := *c.store;
	ch := channel_get(s, channel_id);
	gid := ifx ch != null then ch.guild_id else 0;
	now := now_ms();
	w := aw_begin();
	json_ksnow(*w, "channel_id", channel_id);
	if gid != 0 { json_ksnow(*w, "guild_id", gid); }
	json_key(*w, "guild_unread_statuses");
	json_arr(*w);
	for g: s.guild_order {
		unread, mentions := guild_unread_mentions(c, g);
		json_str(*w, fmt.tprintf("%d,%v,%d,%v,%d", cast(u64)(g), unread, mentions, guild_is_muted(s, g, now), UNREAD_SETTING_ALL_MESSAGES));
	}
	json_arr_end(*w);
	if gid != 0 { aw_guild(*w, c, gid, false); }
	aw_channel(*w, c, channel_id, false);
	json_kstr(*w, "location_section", location.section);
	json_kstr(*w, "location_object", location.object);
	json_kstr(*w, "location_object_type", location.object_type);
	json_obj_end(*w);
	return json_body(json_string(*w));
}

// analytics_ack_done: ack_messages once the ack's POST completed (worker thread).
analytics_ack_done :: (c: *Client, j: *Job, status: int) {
	if status < 200 || status >= 300 { return; }
	analytics_track(c, "ack_messages", j.track_props);
}
#scope_export

// analytics_notification_shown: the app showed a desktop notification for a
// message. When the channel's MESSAGE_ACK arrives, each one still shown is
// reported acked (analytics_notifications_acked; fixture inbox).
analytics_notification_shown :: (c: *Client, message_id: Snowflake, channel_id: Snowflake, author_id: Snowflake, kind: int, badge: bool) {
	a := *c.analytics;
	a.last_notification_ms = now_ms();
	if len(a.shown) >= 32 { ordered_remove(*a.shown, 0); }
	append(*a.shown, Shown_Notification.{message_id, channel_id, author_id, kind, badge});
}
#scope_module

// analytics_notifications_acked: MESSAGE_ACK for a channel (UI thread): notification_action ACK
// for its shown notifications up to the acked message, oldest first.
analytics_notifications_acked :: (c: *Client, channel_id: Snowflake, message_id: Snowflake) {
	a := *c.analytics;
	{ i := 0;
	while i < len(a.shown) {
		n := a.shown[i];
		if n.channel_id != channel_id || n.message_id > message_id {
			i += 1;
			continue;
		}
		ordered_remove(*a.shown, i);
		track_notification_ack(c, n.author_id, n.message_id, n.kind, n.channel_id, n.badge, true);
	} }
}

analytics_custom_status_updated :: (c: *Client, cs: Custom_Status) {
	w := aw_begin();
	json_knull(*w, "location");
	if cs.emoji_name == "" && cs.emoji_id == 0 { json_knull(*w, "emoji_type"); } else { json_kstr(*w, "emoji_type", ifx cs.emoji_id != 0 then "custom" else "unicode"); }
	json_kint(*w, "text_len", cast(s64)(len(cs.text)));
	json_kstr(*w, "clear_after", clear_after_name(cs.clear_after));
	// fastcord's modal shows no prompt (placeholder suggestion)
	json_knull(*w, "prompt_type");
	aw_strs(*w, "location_stack", string.["account", "user profile account popout", "user profile custom status bubble", "custom status modal"]);
	aw_track(c, "custom_status_updated", *w);
}

analytics_theme_updated :: (c: *Client, t: Theme, system: bool) {
	name := "default system";
	if !system {
		if t == {
		case .Unset; #through; case .Darker;
			name = "default darker";
		case .Dark;
			name = "default dark";
		case .Light;
			name = "default light";
		case .Midnight;
			name = "default midnight";
		}
	}
	w := aw_begin();
	json_kstr(*w, "feature_name", "client_theme");
	json_kstr(*w, "theme_name", name);
	json_kbool(*w, "is_persisted", true);
	aw_strs(*w, "location_stack", string.["client themes theme selector"]);
	aw_track(c, "client_theme_updated", *w);
}

// ---- navigation ----

preset_name :: (level: int) -> string {
	if level == {
	case NOTIFY_MENTIONS;
		return "mentions";
	case NOTIFY_NOTHING;
		return "nothing";
	}
	return "all_messages";
}
#scope_export

// fastcord marks channels unread for every message (it has no per-channel
// unread setting), so its resolved unread setting is always ALL_MESSAGES (1).
UNREAD_SETTING_ALL_MESSAGES :: 1;
#scope_module

guild_unread_mentions :: (c: *Client, guild_id: Snowflake) -> bool, int {
	unread: bool;
	mentions: int;
	s := *c.store;
	g := guild_get(s, guild_id);
	if g == null { return unread, mentions; }
	for cid: g.channels {
		if channel_unread(s, cid) { unread = true; }
		{ rs, ok := map_find(s.read_states, cid);
		if ok { mentions += rs.mention_count; } }
	}
	return unread, mentions;
}
#scope_export

// analytics_channel_opened: the channel view rendered (select_channel / voice join).
// Throttled per channel and view (analytics.odin SCI_THROTTLES). A thread leads
// with its thread properties (ThreadAnalytics: counts, archive state, creation
// date, can_send_message, parent_channel_type); can_send_message keeps that
// first position. view: the split view's channel_view ("Split View"), which has
// no selected_guild_id. location: the route change's source, last (fixture
// threads_browser, open_thread_from_popout).
analytics_channel_opened :: (c: *Client, guild_id: Snowflake, channel_id: Snowflake, selected_guild := true, view := "", location := "") {
	s := *c.store;
	ch := channel_get(s, channel_id);
	if ch == null { return; }
	now := now_ms();
	w := aw_begin();
	thread := is_thread(ch);
	can_send := has_permission(channel_permissions(s, channel_id), PERM_SEND_MESSAGES);
	if thread {
		tm := thread_meta(channel_id);
		if is_null(tm) { return; } // its counts are not known yet
		json_kint(*w, "thread_approximate_member_count", cast(s64)(tm.member_count));
		json_kint(*w, "thread_approximate_message_count", cast(s64)(tm.message_count));
		json_kbool(*w, "thread_archived", tm.archived);
		json_kbool(*w, "thread_locked", tm.locked);
		json_kint(*w, "thread_auto_archive_duration_minutes", cast(s64)(tm.auto_archive_minutes));
		json_kint(*w, "thread_approximate_creation_date", snowflake_time_ms(channel_id));
		json_kbool(*w, "can_send_message", can_send);
		parent_kind := Channel_Type.Guild_Text;
		{ p := channel_get(s, ch.parent_id);
		if !is_null(p) { parent_kind = p.kind; } }
		json_kint(*w, "parent_channel_type", cast(s64)(parent_kind));
	}
	json_ksnow(*w, "channel_id", channel_id);
	if ch.guild_id == 0 {
		json_kbool(*w, "is_app_dm", false);
		friends := 0;
		for r: ch.recipient_ids { { rel, ok := map_find(s.relationships, r);
if ok && rel.kind == .Friend { friends += 1; } } }
		json_kint(*w, "friend_recipient_count", cast(s64)(friends));
		json_kint(*w, "non_friend_recipient_count", cast(s64)(len(ch.recipient_ids) - friends));
		json_knull(*w, "selected_guild_id");
		aw_channel(*w, c, channel_id, false);
		if location != "" { json_kstr(*w, "location", location); }
		aw_track(c, "channel_opened", *w);
		return;
	}
	gid := ch.guild_id;
	rs := get(s.read_states, channel_id);
	json_kbool(*w, "channel_was_unread", channel_unread(s, channel_id));
	json_kint(*w, "channel_mention_count", cast(s64)(rs.mention_count));
	json_kbool(*w, "channel_is_muted", channel_is_muted(s, gid, channel_id, now));
	json_kbool(*w, "channel_is_nsfw", ch.nsfw);
	json_kbool(*w, "channel_is_spoiler", false);
	level := channel_notify_level(s, gid, channel_id);
	if level == NOTIFY_INHERIT && ch.parent_id != 0 { level = channel_notify_level(s, gid, ch.parent_id); }
	if level == NOTIFY_INHERIT { level = guild_notify_level(s, gid); }
	json_kint(*w, "channel_resolved_unread_setting", UNREAD_SETTING_ALL_MESSAGES);
	json_kstr(*w, "channel_preset", preset_name(level));
	json_ksnow(*w, "guild_id", gid);
	gu, gm := guild_unread_mentions(c, gid);
	json_kbool(*w, "guild_was_unread", gu);
	json_kint(*w, "guild_mention_count", cast(s64)(gm));
	json_kbool(*w, "guild_is_muted", guild_is_muted(s, gid, now));
	json_kint(*w, "guild_resolved_unread_setting", UNREAD_SETTING_ALL_MESSAGES);
	json_kstr(*w, "guild_preset", preset_name(guild_notify_level(s, gid)));
	aw_ksnow_or_null(*w, "parent_id", ch.parent_id);
	json_kbool(*w, "has_pending_member_action", false);
	if !thread { json_kbool(*w, "can_send_message", can_send); }
	json_kbool(*w, "is_app_dm", false);
	if view != "" { json_kstr(*w, "channel_view", view); } else if selected_guild { json_ksnow(*w, "selected_guild_id", gid); }
	aw_guild(*w, c, gid, false);
	aw_channel(*w, c, channel_id, false);
	if location != "" { json_kstr(*w, "location", location); }
	aw_track(c, "channel_opened", *w);
}

// analytics_guild_viewed: a guild's channel list was shown (entering the guild).
analytics_guild_viewed :: (c: *Client, guild_id: Snowflake, channel_id: Snowflake) {
	s := *c.store;
	g := guild_get(s, guild_id);
	if g == null { return; }
	postable, unread := 0, make_dynamic(Snowflake, 0, 0, temp);
	for cid: g.channels {
		ch := channel_get(s, cid);
		if ch == null || ch.kind == .Guild_Category || is_thread(ch) { continue; }
		perms := channel_permissions(s, cid);
		if (ch.kind == .Guild_Text || ch.kind == .Guild_Announcement) && has_permission(perms, PERM_VIEW_CHANNEL | PERM_SEND_MESSAGES) { postable += 1; }
		if cid != channel_id && channel_unread(s, cid) { append(*unread, cid); } // the viewed channel is read
	}
	w := aw_begin();
	json_kint(*w, "postable_channels", cast(s64)(postable));
	json_kbool(*w, "premium_progress_bar_enabled", false);
	json_kbool(*w, "viewing_all_channels", true);
	json_kint(*w, "num_recent_channels", 0);
	json_kint(*w, "num_unread_channels", cast(s64)(len(unread)));
	json_key(*w, "unread_channel_ids");
	json_arr(*w);
	for id: unread { json_snowflake(*w, id); }
	json_arr_end(*w);
	json_kbool(*w, "guild_theme_enabled", false);
	json_kbool(*w, "guild_theme_is_custom", false);
	aw_guild(*w, c, guild_id);
	if channel_id != 0 { aw_channel(*w, c, channel_id); }
	aw_track(c, "guild_viewed", *w);
}
#scope_module

// ---- voice ----

analytics_join_voice :: (c: *Client, guild_id: Snowflake, channel_id: Snowflake) {
	s := *c.store;
	ch := channel_get(s, channel_id);
	in_channel, custom := 0, 0;
	for uid, vs: s.voice_states {
		if vs.channel_id != channel_id || uid == s.me { continue; }
		in_channel += 1;
		{ p, ok := map_find(s.presences, uid);
		if ok && p.activity != "" { custom += 1; } }
	}
	w := aw_begin();
	json_knull(*w, "location");
	json_ksnow(*w, "channel_id", channel_id);
	json_kint(*w, "channel_type", ifx ch != null then cast(s64)(ch.kind) else 2);
	json_kint(*w, "channel_bitrate", ifx ch != null && ch.bitrate > 0 then cast(s64)(ch.bitrate) else 64000);
	aw_ksnow_or_null(*w, "guild_id", guild_id);
	// fastcord runs no game detection: no game is reported
	json_kstr(*w, "game_name", "");
	json_knull(*w, "game_platform");
	json_knull(*w, "game_id");
	json_kbool(*w, "was_moved", false);
	delete(c.analytics.join_voice_id, c.allocator);
	c.analytics.join_voice_id = uuid4(c.allocator);
	json_kstr(*w, "join_voice_id", c.analytics.join_voice_id);
	json_kint(*w, "custom_status_count", cast(s64)(custom));
	json_kint(*w, "voice_state_count", cast(s64)(in_channel));
	json_kint(*w, "video_stream_count", 0);
	json_kbool(*w, "video_enabled", false);
	aw_track(c, "join_voice_channel", *w);
}
#scope_export

// analytics_shelf_fetched: network_action_embedded_activities_fetch_shelf (worker
// thread): guild_id is the ?guild_id= value, "" for a call's shelf without one.
analytics_shelf_fetched :: (c: *Client, j: *Job, status: int) {
	if status == 0 { return; }
	gid := "";
	{ i := strings.index(j.path, "guild_id=");
	if i >= 0 { gid = sub_from(j.path, i + len("guild_id=")); } }
	w := aw_begin();
	json_kint(*w, "status_code", cast(s64)(status));
	json_kstr(*w, "url", "/activities/shelf");
	json_kstr(*w, "request_method", "get");
	json_kstr(*w, "guild_id", gid);
	aw_track(c, "network_action_embedded_activities_fetch_shelf", *w);
}

// analytics_shelf_fetched_null: the same for the call's second shelf load, which
// reports guild_id null (fixture dm_call/start_call).
analytics_shelf_fetched_null :: (c: *Client, j: *Job, status: int) {
	if status == 0 { return; }
	w := aw_begin();
	json_kint(*w, "status_code", cast(s64)(status));
	json_kstr(*w, "url", "/activities/shelf");
	json_kstr(*w, "request_method", "get");
	json_knull(*w, "guild_id");
	aw_track(c, "network_action_embedded_activities_fetch_shelf", *w);
}

// analytics_permissions_requested: the voice engine asked the OS for a device ("audio", "video").
analytics_permissions_requested :: (c: *Client, kind: string) {
	w := aw_begin();
	json_kstr(*w, "type", kind);
	aw_track(c, "permissions_requested", *w);
}
#scope_module

// ---- guild creation ----

analytics_guild_create_result :: (c: *Client, status: int, step_shown_ms: s64) {
	w := aw_begin();
	json_kint(*w, "status_code", cast(s64)(status));
	json_kstr(*w, "url", "/guilds");
	json_kstr(*w, "request_method", "post");
	json_kstr(*w, "template_name", "CREATE");
	json_kbool(*w, "is_community_intent", false);
	aw_track(c, "network_action_guild_create", *w);
	if status < 200 || status >= 300 { return; }
	w2 := aw_begin();
	json_kstr(*w2, "flow_type", "create_guild");
	json_kstr(*w2, "from_step", "guild_create");
	json_kstr(*w2, "to_step", "create_success");
	aw_kf64(*w2, "seconds_on_from_step", ifx step_shown_ms != 0 then cast(float64)(now_ms() - step_shown_ms) / 1000 else 0);
	aw_track(c, "nuo_transition", *w2);
}
#scope_export

// ---- group DMs ----

Gdm_Entry :: struct {
	type: string; // "New Group DM", "Add Friends to DM"
	source: string; // "Friends List", "Group DM"
}

// group_dm_picker_opened: the "New Group DM" / "Add Friends to DM" popout
// opened, listing `friends` + `non_friends` suggested users.
group_dm_picker_opened :: (c: *Client, entry: Gdm_Entry, friends: int, non_friends: int, channel_id: Snowflake = 0) {
	a := *c.analytics;
	a.gdm_entry = entry;
	a.gdm_searches = 0;
	w := aw_begin();
	if channel_id != 0 { aw_channel(*w, c, channel_id); }
	json_kstr(*w, "type", entry.type);
	json_kbool(*w, "is_friend", true);
	json_kstr(*w, "source", entry.source);
	aw_track(c, "open_popout", *w);
	w2 := aw_begin();
	if channel_id != 0 { aw_channel(*w2, c, channel_id); }
	json_kint(*w2, "default_results_count", cast(s64)(friends + non_friends));
	json_kint(*w2, "default_results_friend_count", cast(s64)(friends));
	json_kint(*w2, "default_results_non_friend_count", cast(s64)(non_friends));
	json_kstr(*w2, "entry_point_type", entry.type);
	json_kstr(*w2, "entry_point_source", entry.source);
	aw_track(c, "private_channel_invite_modal_opened", *w2);
}

// group_dm_picker_searched: the user typed a search in the picker.
group_dm_picker_searched :: (c: *Client) {c.analytics.gdm_searches += 1;}
#scope_module

analytics_create_dm_clicked :: (c: *Client, user_ids: []Snowflake) {
	a := *c.analytics;
	s := *c.store;
	friends := 0;
	for u: user_ids { { rel, ok := map_find(s.relationships, u);
if ok && rel.kind == .Friend { friends += 1; } } }
	w := aw_begin();
	json_kbool(*w, "is_new_dm", true);
	json_kstr(*w, "entry_point_type", a.gdm_entry.type);
	json_kstr(*w, "entry_point_source", a.gdm_entry.source);
	json_key(*w, "recipient_ids");
	json_arr(*w);
	for u: user_ids { json_snowflake(*w, u); }
	json_arr_end(*w);
	json_kint(*w, "num_searches", cast(s64)(a.gdm_searches));
	json_key(*w, "affinity_score");
	json_raw(*w, "[]"); // fastcord ranks no affinity
	json_kbool(*w, "name_is_set", false);
	json_kbool(*w, "icon_is_set", false);
	json_kint(*w, "friend_recipient_count", cast(s64)(friends));
	json_kint(*w, "non_friend_recipient_count", cast(s64)(len(user_ids) - friends));
	aw_track(c, "create_dm_user_list_clicked", *w);
	a.gdm_pending = true;
}

// analytics_group_dm_created: the new group DM opened (Open_Dm result).
analytics_group_dm_created :: (c: *Client, channel_id: Snowflake) {
	a := *c.analytics;
	if !a.gdm_pending { return; }
	a.gdm_pending = false;
	analytics_channel_opened(c, 0, channel_id);
	ch := channel_get(*c.store, channel_id);
	w := aw_begin();
	json_ksnow(*w, "channel_id", channel_id);
	json_kint(*w, "channel_type", ifx ch != null then cast(s64)(ch.kind) else 3);
	json_kbool(*w, "new_name_set", false);
	json_kbool(*w, "new_icon_set", false);
	json_kstr(*w, "location", "new group dm invite modal");
	aw_track(c, "gdm_edit_interacted", *w);
}
#scope_export

// ---- home ----

Friends_List_Tab :: enum u8 {
	Online;
	All;
	Pending;
	Add_Friend;
}

// analytics_friends_list: friends_list_viewed (the friends page shown) or
// friends_list_clicked (a tab / the Friends item clicked). now_playing_cards:
// the cards the page's "Active Now" column shows (0: its empty state).
analytics_friends_list :: (c: *Client, event: string, tab: Friends_List_Tab, now_playing_cards := 0) {
	s := *c.store;
	friends, online, idle, dnd, outgoing, incoming := 0, 0, 0, 0, 0, 0;
	for uid, rel: s.relationships {
		if rel.kind == {
		case .Friend;
			friends += 1;
			{ p, ok := map_find(s.presences, uid);
			if ok {
				if p.status == {
				case .Online;
					online += 1;
				case .Idle;
					idle += 1;
				case .Dnd;
					dnd += 1;
				}
			} }
		case .Incoming_Request;
			incoming += 1;
		case .Outgoing_Request;
			outgoing += 1;
		}
	}
	names := string.["ONLINE", "ALL", "PENDING", "ADD_FRIEND"];
	w := aw_begin();
	json_kstr(*w, "tab_opened", get(names, tab));
	json_kint(*w, "num_friends", cast(s64)(friends));
	json_kint(*w, "num_friends_online", cast(s64)(online));
	json_kint(*w, "num_friends_idle", cast(s64)(idle));
	json_kint(*w, "num_friends_dnd", cast(s64)(dnd));
	json_kint(*w, "num_outgoing_requests", cast(s64)(outgoing));
	json_kint(*w, "num_incoming_requests", cast(s64)(incoming));
	// game friends (Discord's game relationships) are not shown by fastcord
	json_kint(*w, "num_game_friends", 0);
	json_kint(*w, "num_game_outgoing_requests", 0);
	json_kint(*w, "num_game_incoming_requests", 0);
	json_kbool(*w, "now_playing_visible", true);
	json_kint(*w, "now_playing_num_cards", cast(s64)(now_playing_cards));
	json_key(*w, "now_playing_games_detected");
	json_raw(*w, "[]"); // fastcord runs no game detection
	aw_track(c, event, *w);
}

// ---- small UI events ----

// analytics_quickswitcher_opened: the quick switcher opened by its keybind.
analytics_quickswitcher_opened :: (c: *Client, guild_id: Snowflake, channel_id: Snowflake) {
	w := aw_begin();
	aw_ksnow_or_null(*w, "current_guild_id", guild_id);
	if channel_id != 0 {
		json_ksnow(*w, "current_channel_id", channel_id);
		ch := channel_get(*c.store, channel_id);
		json_kint(*w, "current_channel_type", ifx ch != null then cast(s64)(ch.kind) else 0);
	}
	json_kstr(*w, "source", "KEYBIND");
	aw_track(c, "quickswitcher_opened", *w);
}

// keyboard_shortcut_used: a global keybind (Escape closes a layer: "CLOSE_*").
analytics_keyboard_shortcut :: (c: *Client, name: string, combo: string) {
	w := aw_begin();
	json_kstr(*w, "shortcut_name", name);
	json_kstr(*w, "shortcut_combo", combo);
	aw_track(c, "keyboard_shortcut_used", *w);
}
#scope_module

// mentions seen (user_status_updated reports how long ago).
analytics_note_message :: (c: *Client, d: V) {
	s := *c.store;
	m := vmap(d);
	if fsnow(fmap(m, "author"), "id") == s.me { return; }
	now := now_ms();
	a := *c.analytics;
	if fbool(m, "mention_everyone") { a.last_everyone_mention_ms = now; }
	for u: flist(m, "mentions") { if fsnow(vmap(u), "id") == s.me { a.last_mention_ms = now; } }
	{ gid := fsnow(m, "guild_id");
	if gid != 0 {
		mine := my_guild_roles(gid);
		for r: flist(m, "mention_roles") {
			rid := vsnow(r);
			for x: mine { if x == rid { a.last_role_mention_ms = now; } }
		}
	} }
}
#scope_export

// ---- Streamer Mode, app notices (src/app/view_streamer.odin) ----

// analytics_streamer_mode_toggle: Streamer Mode switched on / off, by the user
// or by streamer-tool detection (automatic).
analytics_streamer_mode_toggle :: (c: *Client, enabled: bool, automatic: bool) {
	w := aw_begin();
	json_kbool(*w, "enabled", enabled);
	json_kbool(*w, "automatic", automatic);
	aw_track(c, "streamer_mode_toggle", *w);
}

// Streamer_Mode_Analytics: the StreamerModeStore fields update_streamer_mode_settings reports.
Streamer_Mode_Analytics :: struct {
	enabled, automatic, disable_notifications, disable_sounds, hide_instant_invites, hide_personal_info, enable_content_protection: bool;
}

// analytics_streamer_settings_updated: one of Streamer Mode's other options changed.
analytics_streamer_settings_updated :: (c: *Client, n: Streamer_Mode_Analytics, o: Streamer_Mode_Analytics) {
	w := aw_begin();
	put :: (w: *Json, prefix: string, x: Streamer_Mode_Analytics) {
		json_kbool(w, fmt.tprintf("%senabled", prefix), x.enabled);
		json_kbool(w, fmt.tprintf("%sautomatic", prefix), x.automatic);
		json_kbool(w, fmt.tprintf("%sdisable_notifications", prefix), x.disable_notifications);
		json_kbool(w, fmt.tprintf("%sdisable_sounds", prefix), x.disable_sounds);
		json_kbool(w, fmt.tprintf("%shide_instant_invites", prefix), x.hide_instant_invites);
		json_kbool(w, fmt.tprintf("%shide_personal_info", prefix), x.hide_personal_info);
		json_kbool(w, fmt.tprintf("%senable_content_protection", prefix), x.enable_content_protection);
		json_kstr(w, fmt.tprintf("%sdisabled_overlay_widgets", prefix), ""); // fastcord has no overlay
	}
	put(*w, "", n);
	put(*w, "old_", o);
	aw_track(c, "update_streamer_mode_settings", *w);
}

// analytics_app_notice: app_notice_viewed / app_notice_primary_cta_opened /
// app_notice_closed for a notice bar (notice_type "STREAMER_MODE",
// "UNVERIFIED_ACCOUNT"...); guild_id: the route's guild, 0 for none (key left out).
analytics_app_notice :: (c: *Client, event: string, notice_type: string, guild_id: Snowflake = 0) {
	w := aw_begin();
	json_kstr(*w, "notice_type", notice_type);
	if guild_id != 0 { json_ksnow(*w, "guild_id", guild_id); }
	aw_track(c, event, *w);
}

