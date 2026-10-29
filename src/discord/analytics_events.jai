// UI-owned telemetry: one typed helper per /science event, so the app (and the
// library actions it calls) report what the user did at the moment the
// official client would, with the official property keys in their order.
//
// Pattern for a new event (see traffic/PARITY.md "Telemetry"):
//   analytics_<event> :: (c: *Client, ...) {
//       w := aw_begin();
//       json_kstr(*w, "type", ...);          // the event's own properties, in fixture order
//       aw_guild(*w, c, guild_id);           // shared groups (guild / channel / location)
//       aw_track(c, "<event>", *w);
//   }
// Values come from fastcord itself (store state, our own timings, ids we
// generated) wherever it has an equivalent. What only the official client can
// measure (Electron memory, its media engine's internals, web-bundle metrics) is
// synthesized realistically from the fixtures, and listed as synthesized in
// traffic/CLIENT_RULES.md "Analytics". Shop, Nitro and quest promotion telemetry
// is sent as it renders (analytics_events_promo.jai); engagement with sponsored
// content never is (analytics_never in analytics.jai).

// PERMISSIONS_ALL_BUILD: Permissions.ALL of the client build fastcord
// identifies as (client_build_number 649389): owners/administrators report
// this union of every flag the build knows, not all 64 bits.
PERMISSIONS_ALL_BUILD : u64 : 17873661021126655;

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

aw_perms :: (w: *Json, k: string, perms: u64) { json_kstr(w, k, tprint("%", perms & PERMISSIONS_ALL_BUILD)); }

aw_ksnow_or_null :: (w: *Json, k: string, id: Snowflake) {
	if id != 0 json_ksnow(w, k, id); else json_knull(w, k);
}

aw_kf64 :: (w: *Json, k: string, v: float64) {
	json_key(w, k);
	json_raw(w, js_number(v));
}

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
				case .Guild_Text; #through;
				case .Guild_Announcement; #through;
				case .Guild_Forum; #through;
				case .Guild_Media; text += 1;
				case .Guild_Voice; #through;
				case .Guild_Stage_Voice; voice += 1;
			}
		}
		for s.voice_states if it.guild_id == guild_id && it.channel_id != 0 in_voice += 1;
	}
	json_kint(w, "guild_size_total", ifx g then g.member_count else 0);
	json_kint(w, "guild_num_channels", text + voice);
	json_kint(w, "guild_num_text_channels", text);
	json_kint(w, "guild_num_voice_channels", voice);
	json_kint(w, "guild_num_roles", ifx g then g.roles.count else 0);
	roles := my_guild_roles(guild_id).count;
	if !roles {
		m := member_get(s, guild_id, s.me);
		if m roles = m.roles.count;
	}
	json_kint(w, "guild_member_num_roles", roles);
	aw_perms(w, "guild_member_perms", guild_permissions(s, guild_id));
	vip := false;
	if g for g.features if it == "VIP_REGIONS" vip = true;
	json_kbool(w, "guild_is_vip", vip);
	json_kbool(w, "is_member", g != null);
	json_kint(w, "num_voice_channels_active", in_voice); // the guild's voice states (users)
}

// aw_channel: the channel decoration (getChannelAnalyticsProperties): type,
// recipients of a private channel, our permissions, and whether @everyone is
// denied VIEW_CHANNEL (a thread: on its parent).
aw_channel :: (w: *Json, c: *Client, channel_id: Snowflake, with_id := true) {
	s := *c.store;
	ch := channel_get(s, channel_id);
	if with_id { json_ksnow(w, "channel_id", channel_id); }
	json_kint(w, "channel_type", ifx ch then cast(s64) ch.kind else 0);
	private := ch && ch.guild_id == 0;
	json_kint(w, "channel_size_total", ifx private then ch.recipient_ids.count else 0);
	perms: u64 = ifx ch && !private then channel_permissions(s, channel_id) else 0;
	aw_perms(w, "channel_member_perms", perms);
	hidden := false;
	if ch && !private {
		src := ch;
		if is_thread(ch) && ch.parent_id != 0 {
			p := channel_get(s, ch.parent_id);
			if p src = p;
		}
		for src.overwrites if it.kind == 0 && it.id == ch.guild_id && (it.deny & PERM_VIEW_CHANNEL) != 0 hidden = true;
	}
	json_kbool(w, "channel_hidden", hidden);
}

// aw_route_props: the guild decoration, then the channel's when it belongs to
// that guild (trackWithMetadata's location properties for a guild route).
aw_route_props :: (w: *Json, c: *Client, guild_id: Snowflake, channel_id: Snowflake, with_channel_id := true) {
	if !guild_get(*c.store, guild_id) return;
	aw_guild(w, c, guild_id);
	ch := channel_get(*c.store, channel_id);
	if ch && ch.guild_id == guild_id aw_channel(w, c, channel_id, with_channel_id);
}

// aw_route: guild + channel decorations of a known guild / channel (each left
// out when unknown), channel only for DMs.
aw_route :: (w: *Json, c: *Client, guild_id: Snowflake, channel_id: Snowflake) {
	if guild_id != 0 && guild_get(*c.store, guild_id) aw_guild(w, c, guild_id);
	if channel_id != 0 && channel_get(*c.store, channel_id) aw_channel(w, c, channel_id);
}

// analytics_dismissible: dismissible_content_shown for a DismissibleContent type.
// guild: write "guild_id" (null when 0). version: written when >= 0. delay_ms: tracked that much later.
analytics_dismissible :: (c: *Client, kind: string, count: int, guild := false, guild_id: Snowflake = 0, version := -1, delay_ms := 0) {
	w := aw_begin();
	json_kstr(*w, "type", kind);
	json_knull(*w, "unselected_content_types");
	json_kint(*w, "content_count", count);
	json_kint(*w, "fatigable_content_count", 0);
	json_kbool(*w, "bypass_fatigue", true);
	if guild aw_ksnow_or_null(*w, "guild_id", guild_id);
	if version >= 0 json_kint(*w, "version", version);
	if !delay_ms {
		aw_track(c, "dismissible_content_shown", *w);
		return;
	}
	json_obj_end(*w);
	analytics_schedule(c, now_ms() + delay_ms, "dismissible_content_shown", json_body(json_string(*w)));
}

aw_location :: (w: *Json, location: string, page: string, section: string) {
	json_kstr(w, "location", location);
	json_kstr(w, "location_page", page);
	json_kstr(w, "location_section", section);
}

aw_strs :: (w: *Json, k: string, items: []string) {
	json_key(w, k);
	json_arr(w);
	for items json_str(w, it);
	json_arr_end(w);
}

// load_id / session ids: the client's uuid v4 (hex without dashes for load ids).
analytics_load_id :: () -> string {
	id := replace(uuid4(,, temp), "-", "");
	return id;
}

// The page a guild channel or DM is, as analytics locations name it.
route_location :: (guild_id: Snowflake) -> string { return ifx guild_id != 0 then "Guild Channel" else "DM Channel"; }

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
		// a miss is tracked as the index fetch starts (open_message_context_menu's on_start), a hit at once
		if table_contains(*c.command_index_guilds, guild_id) {
			analytics_command_cache_fetch(c, false, c.command_index_guilds.count);
			analytics_command_cache_fetch(c, false, c.command_index_guilds.count);
		}
		open_message_context_menu(c, guild_id, message_menu = true);
	} else {
		open_message_context_menu(c, 0, message_menu = true);
	}
}

// message_menu_item_clicked: the first click on a menu item (time to select).
message_menu_item_clicked :: (c: *Client) {
	m := *c.analytics.menu;
	if m.open && m.first_click == 0 m.first_click = now_ms();
}

// message_menu_closed: the menu went away (an item was chosen or it was dismissed).
message_menu_closed :: (c: *Client) {
	m := *c.analytics.menu;
	if !m.open return;
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
	json_kint(*w, "size", size);
	aw_track(c, "application_command_cache_fetch", *w);
}

// analytics_command_index_loaded: application_command_performance when a
// command index response arrives (worker thread; analytics_track is locked).
analytics_command_index_loaded :: (c: *Client, j: *Job, status: int) {
	if status == 0 return; // network failure: the official tracks an error we don't model
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
	user := begins_with(path, "/users/");
	json_kstr(*w, "target_type", ifx user then "user" else "guild");
	if user {
		json_knull(*w, "target_id");
	} else {
		id := path;
		if begins_with(id, "/guilds/") id = advance(id, "/guilds/".count);
		if ends_with(id, "/application-command-index") id.count -= "/application-command-index".count;
		json_kstr(*w, "target_id", id);
	}
	json_key(*w, "failure_statuses");
	json_arr(*w);
	if status >= 400 json_int(*w, status);
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

search_type_name :: (k: Picker_Kind) -> string {
	NAMES :: string.["EMOJI", "EMOJI_REACTION", "GIF"];
	return NAMES[cast(int) k];
}

aw_search_head :: (w: *Json, c: *Client, p: *Picker_Search) {
	json_kstr(w, "search_type", search_type_name(p.kind));
	json_kstr(w, "load_id", p.load_id);
}

aw_search_tail :: (w: *Json, c: *Client, p: *Picker_Search) {
	aw_route(w, c, p.guild_id, p.channel_id);
	if p.kind != .Gif aw_location(w, route_location(p.guild_id), route_location(p.guild_id), "Emoji Picker Popout");
}

aw_counts :: (w: *Json, n: Expression_Counts) {
	json_kint(w, "num_expressions_favorites", n.favorites);
	json_kint(w, "num_animated_expressions_favorites", n.animated_favorites);
	json_kint(w, "num_custom_expressions_favorites", n.custom_favorites);
	json_kint(w, "num_standard_expressions_favorites", n.standard_favorites);
	json_kint(w, "num_expressions_frecent", n.frecent);
	json_kint(w, "num_animated_expressions_frecent", n.animated_frecent);
	json_kint(w, "num_custom_expressions_frecent", n.custom_frecent);
	json_kint(w, "num_standard_expressions_frecent", n.standard_frecent);
	json_kint(w, "num_current_guild_expressions", n.current_guild);
	json_kint(w, "num_custom_expressions_total", n.custom_total);
	json_kint(w, "num_expressions_top_server", n.top_server);
	json_kint(w, "num_animated_expressions_top_server", n.animated_top_server);
	json_kint(w, "num_expressions_newly_added", n.newly_added);
	json_kint(w, "num_animated_expressions_newly_added", n.animated_newly_added);
}

// expression_picker_opened: a picker opened (telemetry only: the picker's loads
// are open_emoji_picker / gifs_trending). width: the gif picker's CSS width.
expression_picker_opened :: (c: *Client, kind: Picker_Kind, guild_id: Snowflake, channel_id: Snowflake, counts := Expression_Counts.{}, message_id: Snowflake = 0, width := 0) {
	p := *c.analytics.picker;
	picker_reset(c);
	p.* = .{open = true, kind = kind, load_id = analytics_load_id(,, c.allocator), guild_id = guild_id, channel_id = channel_id, message_id = message_id};
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
		analytics_dismissible(c, "WISHLIST_NUX_TOOLTIP_AND_MODAL", 0, guild = true, guild_id = guild_id); // the Shop wishlist tooltip
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
		analytics_dismissible(c, "WISHLIST_NUX_TOOLTIP_AND_MODAL", 0, guild = true, guild_id = guild_id);
	  case .Gif;
		w := aw_begin();
		aw_search_head(*w, c, p);
		aw_route(*w, c, guild_id, channel_id);
		aw_track(c, "search_opened", *w);
		w2 := aw_begin();
		json_kint(*w2, "width", width);
		json_kstr(*w2, "tab", "gif");
		json_kbool(*w2, "badged", false);
		aw_route(*w2, c, guild_id, channel_id);
		aw_track(c, "expression_picker_opened", *w2);
	}
}

picker_reset :: (c: *Client) {
	p := *c.analytics.picker;
	free(p.load_id,, c.allocator);
	free(p.query,, c.allocator);
	p.* = .{};
}

// picker_search_typed: the emoji picker's search text changed to `query`
// (the first character starts the search session).
picker_search_typed :: (c: *Client, query: string) {
	p := *c.analytics.picker;
	if !p.open || p.kind == .Gif || query == "" return;
	free(p.query,, c.allocator);
	p.query = copy_string(query,, c.allocator);
	if p.started return;
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
	if !p.open || p.kind == .Gif || query == "" return;
	picker_search_typed(c, query);
	w := aw_begin();
	json_kstr(*w, "search_type", search_type_name(p.kind));
	json_kint(*w, "total_results", total);
	json_kint(*w, "num_results_locked", locked);
	json_kstr(*w, "query", query);
	json_kstr(*w, "load_id", p.load_id);
	aw_search_tail(*w, c, p);
	aw_track(c, "search_result_viewed", *w);
}

// picker_emoji_selected: an emoji was picked from search results (the picker closes).
// emoji_name is the emoji's name as the picker lists it ("thumbsup", "fastcord_test").
picker_emoji_selected :: (c: *Client, emoji_name: string, emoji_id: Snowflake = 0, emoji_guild: Snowflake = 0, animated := false, locked := false) {
	p := *c.analytics.picker;
	if !p.open return;
	// the pick hides the favourite-emoji tooltip hotspot; a reaction picker's
	// unmount hides it again after the result event (fixtures add_reaction, emoji_picker_reaction)
	if p.kind != .Gif analytics_hotspot_hidden(c, "FAVORITE_EMOJI_TOOLTIP");
	if p.query {
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
		if p.message_id != 0 json_ksnow(*w, "message_id", p.message_id);
		aw_search_tail(*w, c, p);
		json_kstr(*w, "location_object", "Emoji");
		aw_track(c, "search_result_selected", *w);
	}
	if p.kind == .Reaction analytics_hotspot_hidden(c, "FAVORITE_EMOJI_TOOLTIP");
	picker_reset(c);
}

// picker_closed: the picker went away without a pick (fixture emoji_picker_add_emoji/close_add_emoji).
picker_closed :: (c: *Client) {
	p := *c.analytics.picker;
	if p.open && p.kind != .Gif analytics_hotspot_hidden(c, "FAVORITE_EMOJI_TOOLTIP");
	picker_reset(c);
}

// ---- composer autocomplete ----
// channel_autocomplete_open / _selected (the autocomplete's analytics module):
// channel then guild decorations, then the query's counts. Emoji type only.

aw_autocomplete_head :: (w: *Json, c: *Client, channel_id: Snowflake, kind := "EMOJIS_AND_STICKERS") {
	aw_channel(w, c, channel_id);
	ch := channel_get(*c.store, channel_id);
	if ch && guild_get(*c.store, ch.guild_id) aw_guild(w, c, ch.guild_id);
	json_kstr(w, "autocomplete_type", kind);
}

// The "@" popup (fixture inbox): no result counts of its own, the emoji ones are 0.
autocomplete_mentions_open :: (c: *Client, channel_id: Snowflake, kind := "MENTIONS") {
	w := aw_begin();
	aw_autocomplete_head(*w, c, channel_id, kind);
	json_kint(*w, "num_emoji_results", 0);
	json_kint(*w, "num_locked_emoji_results", 0);
	json_kint(*w, "num_sticker_results", 0);
	json_kbool(*w, "game_mentions_available", true);
	aw_track(c, "channel_autocomplete_open", *w);
}

autocomplete_mention_selected :: (c: *Client, channel_id: Snowflake, kind := "MENTIONS", selection := "MENTION") {
	w := aw_begin();
	aw_autocomplete_head(*w, c, channel_id, kind);
	json_kstr(*w, "selection_type", selection);
	json_kint(*w, "num_emoji_results", 0);
	json_kint(*w, "num_sticker_results", 0);
	json_kstr(*w, "emoji_name", "");
	json_kbool(*w, "is_custom", false);
	json_kbool(*w, "is_animated", false);
	aw_track(c, "channel_autocomplete_selected", *w);
}

autocomplete_emoji_open :: (c: *Client, channel_id: Snowflake, results: int, locked: int) {
	w := aw_begin();
	aw_autocomplete_head(*w, c, channel_id);
	json_kint(*w, "num_emoji_results", results);
	json_kint(*w, "num_locked_emoji_results", locked);
	json_kint(*w, "num_sticker_results", 0);
	aw_track(c, "channel_autocomplete_open", *w);
}

autocomplete_emoji_selected :: (c: *Client, channel_id: Snowflake, name: string, emoji_id: Snowflake, animated: bool, results: int) {
	w := aw_begin();
	aw_autocomplete_head(*w, c, channel_id);
	json_kstr(*w, "selection_type", "EMOJI");
	if emoji_id != 0 json_ksnow(*w, "emoji_id", emoji_id);
	json_kint(*w, "num_emoji_results", results);
	json_kint(*w, "num_sticker_results", 0);
	json_kstr(*w, "emoji_name", name);
	json_kbool(*w, "is_custom", emoji_id != 0);
	json_kbool(*w, "is_animated", animated);
	aw_track(c, "channel_autocomplete_selected", *w);
}

// ---- explicit media ----

// analytics_redactable_page: explicit_media_redactable_messages_loaded when a page of the current
// channel loads (ExplicitMediaManager LOAD_MESSAGES_SUCCESS). It counts the media of messages
// (and their replied-to messages) with attachments, embeds or components whose author is not us
// and whose media the explicit or gore setting for this kind of channel blurs or blocks. Media
// without a current content scan is pending. Throttled 60 s per channel (SCI_THROTTLES).
analytics_redactable_page :: (c: *Client, channel_id: Snowflake, items: []V) {
	s := *c.store;
	ch := channel_get(s, channel_id);
	if !ch return;
	redacts :: (s: *Store, ch: *Channel, m: etf.Map) -> bool {
		author := fsnow(fmap(m, "author"), "id");
		if !m.count || author == s.me return false;
		if !flist(m, "attachments").count && !flist(m, "embeds").count && !flist(m, "components").count return false;
		kind := 0; // guilds, friend DMs, other DMs
		if !ch.guild_id {
			_, rel := table_find(*s.relationships, author);
			kind = ifx rel.kind == .Friend then 1 else 2;
		}
		// unset: blur everywhere when NSFW isn't allowed, else block other DMs (explicit: the legacy
		// filter's default, gore: always)
		for harm: s.settings.media_redaction {
			v := harm[kind];
			if v == 2 || v == 3 || (v == 0 && (s.settings.nsfw_blocked || kind == 2)) return true;
		}
		return false;
	}
	unscanned :: (m: etf.Map) -> bool { return !vhas(m, "content_scan_version") || fint(m, "content_scan_version") < EXPLICIT_SCAN_VERSION; }
	EXPLICIT_SCAN_VERSION :: 4; // ExplicitMediaStore.validContentScanVersion (READY: 4)
	n: [4]int; // attachments, pending, embeds, pending
	seen: [..]Snowflake;
	seen.allocator = temp;
	for items for m: etf.Map.[vmap(it), fmap(vmap(it), "referenced_message")] {
		if !redacts(s, ch, m) || array_find(seen, fsnow(m, "id")) continue;
		array_add(*seen, fsnow(m, "id"));
		for flist(m, "attachments") {
			n[0] += 1;
			if unscanned(vmap(it)) n[1] += 1;
		}
		for flist(m, "embeds") {
			e := vmap(it);
			n[2] += 1;
			empty := false; // a zero-size image, thumbnail or video is never scanned
			for k: string.["image", "thumbnail", "video"] if vhas(e, k) && !fint(fmap(e, k), "width") && !fint(fmap(e, k), "height") empty = true;
			if unscanned(e) && !empty n[3] += 1;
		}
	}
	if !seen.count return;
	w := aw_begin();
	json_ksnow(*w, "channel_id", channel_id);
	aw_ksnow_or_null(*w, "guild_id", ch.guild_id);
	for k: string.["num_of_attachments", "num_of_attachments_pending_scan", "num_of_embeds", "num_of_embeds_pending_scan"] json_kint(*w, k, n[it_index]);
	aw_track(c, "explicit_media_redactable_messages_loaded", *w);
}

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

profile_layout_name :: (l: Profile_Layout) -> string {
	NAMES :: string.["POPOUT", "MODAL_V2", "ACCOUNT_POPOUT", "SIDEBAR"];
	return NAMES[cast(int) l];
}

profile_view_free :: (c: *Client, v: *Profile_View) {
	free(v.session,, c.allocator);
	free(v.source_session,, c.allocator);
	v.* = .{};
}

// profile_view_begin: a profile surface opened; user_profile_action goes out
// when its profile arrives (analytics_on_profile).
profile_view_begin :: (c: *Client, layout: Profile_Layout, user_id: Snowflake, guild_id: Snowflake, channel_id: Snowflake, message_id: Snowflake, wait := 1) {
	a := *c.analytics;
	src := "";
	if layout == .Modal && a.profile.layout == .Popout && a.profile.session && a.profile.user_id == user_id {
		src = copy_string(a.profile.session,, c.allocator);
	}
	profile_view_free(c, *a.profile);
	u := user_get(*c.store, user_id);
	known := u && u.mutual_guilds >= 0 && u.mutual_friends >= 0;
	a.profile = .{pending = true, layout = layout, user_id = user_id, guild_id = guild_id, channel_id = channel_id, message_id = message_id, session = uuid4(,, c.allocator), source_session = src, wait = wait, mutuals_known = known};
}

// profile_props_apply: a profile response's ProfileProperty bits (NICKNAME 0, PRONOUNS 1, AVATAR 2,
// ANIMATED_AVATAR 3, BANNER 4, ANIMATED_BANNER 5, BIO 6, THEME 7, AVATAR_DECORATION 8,
// PROFILE_EFFECT 9; listed in that order) for the user and the guild member (their nick and guild
// profile, no avatar), and the badge ids of both (UserProfile.getBadges).
profile_props_apply :: (s: *Store, u: *User, m: etf.Map) {
	props :: (user: etf.Map, profile: etf.Map, member: etf.Map) -> u16 {
		b: u16;
		set :: (b: *u16, on: bool, bit: int) { if on b.* |= cast(u16) (1 << bit); }
		set(*b, fstr(member, "nick") != "", 0);
		set(*b, fstr(profile, "pronouns") != "", 1);
		set(*b, fstr(user, "avatar") != "", ifx begins_with(fstr(user, "avatar"), "a_") then 3 else 2);
		set(*b, fstr(profile, "banner") != "", ifx begins_with(fstr(profile, "banner"), "a_") then 5 else 4);
		set(*b, fstr(profile, "bio") != "", 6);
		for flist(profile, "theme_colors") set(*b, it.kind != .Nil, 7);
		set(*b, fmap(user, "avatar_decoration_data").count > 0, 8);
		set(*b, fmap(profile, "profile_effect").count > 0, 9);
		return b;
	}
	u.profile_props = props(fmap(m, "user"), fmap(m, "user_profile"), .{});
	u.guild_profile_props = props(.{}, fmap(m, "guild_member_profile"), fmap(m, "guild_member"));
	w: Json;
	json_init(*w);
	json_arr(*w);
	for k: string.["badges", "guild_badges"] for flist(m, k) json_str(*w, fstr(vmap(it), "id"));
	json_arr_end(*w);
	free_str(u.badges, s.allocator);
	u.badges = clone_str(json_string(*w), s.allocator);
}

// user_status_string: "online-desktop" etc., from the user's presence.
user_status_string :: (c: *Client, user_id: Snowflake) -> string {
	s := *c.store;
	st, plat := Status.Offline, "";
	if user_id == s.me {
		st, plat = s.settings.status, "desktop";
		if st == .Offline st = .Invisible;
	} else {
		p := table_find_pointer(*s.presences, user_id);
		if p {
			st = p.status;
			if p.desktop != .Offline plat = "desktop";
			else if p.mobile != .Offline plat = "mobile";
			else if p.web != .Offline plat = "web";
		}
	}
	if plat == "" || st == .Offline return status_name(st);
	return tprint("%-%", status_name(st), plat);
}

// analytics_on_profile: a profile response arrived (UI thread).
analytics_on_profile :: (c: *Client, user_id: Snowflake) {
	v := *c.analytics.profile;
	if !v.pending || v.user_id != user_id return;
	v.wait -= 1;
	if v.wait > 0 return;
	v.pending = false;
	stack: []string;
	if v.layout == {
		case .Popout;         stack = string.["username", "user profile popout"];
		case .Modal;
			if v.source_session stack = string.["username", "user profile popout", "user profile modal v2"];
			else stack = string.["user profile modal v2"];
		case .Account_Popout; stack = string.["account", "user profile account popout"];
		case .Sidebar;
			stack = string.["user profile sidebar"];
			analytics_user_triggered(c, LEGACY_USER_REPORTING, "user profile overflow menu"); // fixture friend_nickname (setup_b)
	}
	if v.layout != .Sidebar promo_profile_upsells(c, xx (v.layout == .Account_Popout));
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
	// the account popout's Edit Profile "new" badge (display name styles, a Nitro perk)
	if v.layout == .Account_Popout analytics_dismissible(c, "DISPLAY_NAME_STYLES_FLYWHEEL_EDIT_PROFILE_NEW_BADGE", 2, guild = true);
}

profile_action :: (c: *Client, v: *Profile_View, stack: []string, action: string) {
	s := *c.store;
	w := aw_begin();
	if v.layout != .Account_Popout aw_route(*w, c, v.guild_id, v.channel_id);
	json_kstr(*w, "profile_layout", profile_layout_name(v.layout));
	json_kstr(*w, "profile_session_id", v.session);
	if v.source_session json_kstr(*w, "source_profile_session_id", v.source_session);
	u := user_get(s, v.user_id);
	p := table_find_pointer(*s.presences, v.user_id);
	for bits: u16.[ifx u then u.profile_props, ifx u && v.guild_id then u.guild_profile_props] {
		json_key(*w, ifx it_index then "guild_profile_properties" else "profile_properties");
		json_arr(*w);
		for 0..9 if bits & cast(u16) (1 << it) json_int(*w, it);
		json_arr_end(*w);
	}
	// ours: the local presence, whose one activity is the custom status (type 4)
	types := ifx p then p.activity_types;
	if v.user_id == s.me types = xx ifx s.settings.custom_status_text || s.settings.custom_status_emoji then 5;
	json_key(*w, "profile_activity_types");
	json_arr(*w);
	for 0..7 {
		t := (types >> (4 * it)) & 0xF;
		if !t break;
		json_int(*w, t - 1);
	}
	json_arr_end(*w);
	json_key(*w, "profile_badges");
	json_raw(*w, ifx u && u.badges then u.badges else "[]");
	json_kstr(*w, "user_status", user_status_string(c, v.user_id));
	json_kbool(*w, "is_guild_profile", v.guild_id != 0);
	json_kbool(*w, "is_bot_profile", u && u.bot);
	json_kbool(*w, "is_private_to_viewer", false);
	json_ksnow(*w, "related_user_id", v.user_id);
	_, rel := table_find(*s.relationships, v.user_id); // kind 0 when there is none
	json_kint(*w, "relationship_type", xx rel.kind);
	if rel.since json_kstr(*w, "related_since", rel.since);
	aff, has_aff := affinity_get(c, v.user_id);
	if has_aff {
		json_key(*w, "communication_probability"); json_raw(*w, aff.probability);
		json_kint(*w, "communication_rank", aff.rank);
	}
	if v.layout == .Sidebar && v.mutuals_known && u {
		json_kint(*w, "num_mutual_friends", u.mutual_friends);
		json_kint(*w, "num_mutual_guilds", u.mutual_guilds);
	}
	json_knull(*w, "application_linked");
	aw_strs(*w, "location_stack", stack);
	json_kstr(*w, "profile_action", action);
	if v.message_id != 0 json_ksnow(*w, "source_message_id", v.message_id);
	aw_track(c, "user_profile_action", *w);
}

// ---- status, custom status, theme ----

Clear_After :: enum u8 {
	Dont_Clear;
	Today;
	Hours_4;
	Hour_1;
	Minutes_30;
}

clear_after_name :: (k: Clear_After) -> string {
	NAMES :: string.["DONT_CLEAR", "TODAY", "HOURS_4", "HOURS_1", "MINUTES_30"];
	return NAMES[cast(int) k];
}

analytics_status_updated :: (c: *Client, prev: Status, next: Status, duration_ms: s64 = 0, expired := false) {
	a := *c.analytics;
	now := now_ms();
	w := aw_begin();
	json_kstr(*w, "next_status", status_name(next));
	json_kstr(*w, "prev_status", status_name(prev));
	KEYS :: string.["approx_seconds_since_last_notification", "approx_seconds_since_last_mention", "approx_seconds_since_last_role_mention", "approx_seconds_since_last_everyone_mention"];
	for t: s64.[a.last_notification_ms, a.last_mention_ms, a.last_role_mention_ms, a.last_everyone_mention_ms] {
		if t == 0 json_knull(*w, KEYS[it_index]); else json_kint(*w, KEYS[it_index], (now - t) / 1000);
	}
	if duration_ms > 0 json_kint(*w, "expire_duration_minutes", duration_ms / 60_000);
	if expired {
		json_key(*w, "location");
		json_obj(*w);
		json_kstr(*w, "object", "CUSTOM_STATUS_MANAGER");
		json_obj_end(*w);
	}
	aw_track(c, "user_status_updated", *w);
}

// analytics_ack_props: ack_messages' properties (AckMessagesAnalytics: every
// guild's "id,hasUnread,mentions,muted,unreadSetting" in guild list order).
analytics_ack_props :: (c: *Client, channel_id: Snowflake, location: Ack_Location) -> string {
	s := *c.store;
	ch := channel_get(s, channel_id);
	gid := ifx ch then ch.guild_id else 0;
	now := now_ms();
	w := aw_begin();
	json_ksnow(*w, "channel_id", channel_id);
	if gid != 0 json_ksnow(*w, "guild_id", gid);
	json_key(*w, "guild_unread_statuses");
	json_arr(*w);
	for g: s.guild_order {
		unread, mentions := guild_unread_mentions(c, g);
		json_str(*w, tprint("%,%,%,%,%", g, unread, mentions, guild_is_muted(s, g, now), UNREAD_SETTING_ALL_MESSAGES));
	}
	json_arr_end(*w);
	if gid != 0 aw_guild(*w, c, gid, false);
	aw_channel(*w, c, channel_id, false);
	json_kstr(*w, "location_section", location.section);
	json_kstr(*w, "location_object", location.object);
	json_kstr(*w, "location_object_type", location.object_type);
	json_obj_end(*w);
	return json_body(json_string(*w));
}

// analytics_ack_done: ack_messages once the ack's POST completed (worker thread).
analytics_ack_done :: (c: *Client, j: *Job, status: int) {
	if status < 200 || status >= 300 return;
	analytics_track(c, "ack_messages", j.track_props);
}

// analytics_notification_shown: the app showed a desktop notification for a
// message. When the channel's MESSAGE_ACK arrives, each one still shown is
// reported acked (analytics_notifications_acked; fixture inbox).
analytics_notification_shown :: (c: *Client, message_id: Snowflake, channel_id: Snowflake, author_id: Snowflake, kind: int, badge: bool) {
	a := *c.analytics;
	a.last_notification_ms = now_ms();
	if a.shown.count >= 32 array_ordered_remove_by_index(*a.shown, 0);
	array_add(*a.shown, .{message_id, channel_id, author_id, kind, badge});
}

// analytics_notifications_acked: MESSAGE_ACK for a channel (UI thread): notification_action ACK
// for its shown notifications up to the acked message, oldest first.
analytics_notifications_acked :: (c: *Client, channel_id: Snowflake, message_id: Snowflake) {
	a := *c.analytics;
	i := 0;
	while i < a.shown.count {
		n := a.shown[i];
		if n.channel_id != channel_id || n.message_id > message_id {
			i += 1;
			continue;
		}
		array_ordered_remove_by_index(*a.shown, i);
		track_notification_ack(c, n.author_id, n.message_id, n.kind, n.channel_id, n.badge, true);
	}
}

analytics_custom_status_updated :: (c: *Client, cs: Custom_Status) {
	w := aw_begin();
	json_knull(*w, "location");
	if cs.emoji_name == "" && cs.emoji_id == 0 json_knull(*w, "emoji_type");
	else json_kstr(*w, "emoji_type", ifx cs.emoji_id != 0 then "custom" else "unicode");
	json_kint(*w, "text_len", cs.text.count);
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
			case .Unset; #through;
			case .Darker;   name = "default darker";
			case .Dark;     name = "default dark";
			case .Light;    name = "default light";
			case .Midnight; name = "default midnight";
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
	if level == NOTIFY_MENTIONS return "mentions";
	if level == NOTIFY_NOTHING return "nothing";
	return "all_messages";
}

// fastcord marks channels unread for every message (it has no per-channel
// unread setting), so its resolved unread setting is always ALL_MESSAGES (1).
UNREAD_SETTING_ALL_MESSAGES :: 1;

guild_unread_mentions :: (c: *Client, guild_id: Snowflake) -> unread: bool, mentions: int {
	unread: bool;
	mentions: int;
	s := *c.store;
	g := guild_get(s, guild_id);
	if !g return false, 0;
	for cid: g.channels {
		if channel_unread(s, cid) unread = true;
		_, rs := table_find(*s.read_states, cid);
		mentions += rs.mention_count;
	}
	return unread, mentions;
}

// analytics_channel_opened: the channel view rendered (select_channel / voice join).
// Throttled per channel and view (analytics.jai SCI_THROTTLES). A thread leads
// with its thread properties (ThreadAnalytics: counts, archive state, creation
// date, can_send_message, parent_channel_type); can_send_message keeps that
// first position. view: the split view's channel_view ("Split View"), which has
// no selected_guild_id. location: the route change's source, last (fixture
// threads_browser, open_thread_from_popout).
analytics_channel_opened :: (c: *Client, guild_id: Snowflake, channel_id: Snowflake, selected_guild := true, view := "", location := "") {
	s := *c.store;
	ch := channel_get(s, channel_id);
	if !ch return;
	if !guild_id analytics_guild_triggered(c, LEGACY_PORTKEY, 0, "ChannelRenderer"); // fixture friend_nickname (setup_b)
	now := now_ms();
	w := aw_begin();
	thread := is_thread(ch);
	can_send := has_permission(channel_permissions(s, channel_id), PERM_SEND_MESSAGES);
	if thread {
		tm := thread_meta(channel_id);
		if !tm return; // its counts are not known yet
		json_kint(*w, "thread_approximate_member_count", tm.member_count);
		json_kint(*w, "thread_approximate_message_count", tm.message_count);
		json_kbool(*w, "thread_archived", tm.archived);
		json_kbool(*w, "thread_locked", tm.locked);
		json_kint(*w, "thread_auto_archive_duration_minutes", tm.auto_archive_minutes);
		json_kint(*w, "thread_approximate_creation_date", snowflake_time_ms(channel_id));
		json_kbool(*w, "can_send_message", can_send);
		parent_kind := Channel_Type.Guild_Text;
		p := channel_get(s, ch.parent_id);
		if p parent_kind = p.kind;
		json_kint(*w, "parent_channel_type", xx parent_kind);
	}
	json_ksnow(*w, "channel_id", channel_id);
	if ch.guild_id == 0 {
		json_kbool(*w, "is_app_dm", false);
		friends := count_friends(s, ch.recipient_ids);
		json_kint(*w, "friend_recipient_count", friends);
		json_kint(*w, "non_friend_recipient_count", ch.recipient_ids.count - friends);
		json_knull(*w, "selected_guild_id");
		aw_channel(*w, c, channel_id, false);
		if location json_kstr(*w, "location", location);
		aw_track(c, "channel_opened", *w);
		return;
	}
	gid := ch.guild_id;
	_, rs := table_find(*s.read_states, channel_id);
	json_kbool(*w, "channel_was_unread", channel_unread(s, channel_id));
	json_kint(*w, "channel_mention_count", rs.mention_count);
	json_kbool(*w, "channel_is_muted", channel_is_muted(s, gid, channel_id, now));
	json_kbool(*w, "channel_is_nsfw", ch.nsfw);
	json_kbool(*w, "channel_is_spoiler", false);
	level := channel_notify_level(s, gid, channel_id);
	if level == NOTIFY_INHERIT && ch.parent_id != 0 level = channel_notify_level(s, gid, ch.parent_id);
	if level == NOTIFY_INHERIT level = guild_notify_level(s, gid);
	json_kint(*w, "channel_resolved_unread_setting", UNREAD_SETTING_ALL_MESSAGES);
	json_kstr(*w, "channel_preset", preset_name(level));
	json_ksnow(*w, "guild_id", gid);
	gu, gm := guild_unread_mentions(c, gid);
	json_kbool(*w, "guild_was_unread", gu);
	json_kint(*w, "guild_mention_count", gm);
	json_kbool(*w, "guild_is_muted", guild_is_muted(s, gid, now));
	json_kint(*w, "guild_resolved_unread_setting", UNREAD_SETTING_ALL_MESSAGES);
	json_kstr(*w, "guild_preset", preset_name(guild_notify_level(s, gid)));
	aw_ksnow_or_null(*w, "parent_id", ch.parent_id);
	json_kbool(*w, "has_pending_member_action", false);
	if !thread json_kbool(*w, "can_send_message", can_send);
	json_kbool(*w, "is_app_dm", false);
	if view json_kstr(*w, "channel_view", view);
	else if selected_guild json_ksnow(*w, "selected_guild_id", gid);
	aw_guild(*w, c, gid, false);
	aw_channel(*w, c, channel_id, false);
	if location json_kstr(*w, "location", location);
	aw_track(c, "channel_opened", *w);
}

count_friends :: (s: *Store, users: []Snowflake) -> int {
	n := 0;
	for users {
		rel := table_find_pointer(*s.relationships, it);
		if rel && rel.kind == .Friend n += 1;
	}
	return n;
}

// analytics_guild_viewed: a guild's channel list was shown (entering the guild).
analytics_guild_viewed :: (c: *Client, guild_id: Snowflake, channel_id: Snowflake) {
	s := *c.store;
	g := guild_get(s, guild_id);
	if !g return;
	postable := 0;
	unread: [..]Snowflake;
	unread.allocator = temp;
	for cid: g.channels {
		ch := channel_get(s, cid);
		if !ch || ch.kind == .Guild_Category || is_thread(ch) continue;
		perms := channel_permissions(s, cid);
		if (ch.kind == .Guild_Text || ch.kind == .Guild_Announcement) && has_permission(perms, PERM_VIEW_CHANNEL | PERM_SEND_MESSAGES) postable += 1;
		if channel_unread(s, cid) array_add(*unread, cid); // the viewed channel too, read only after (mark_as_read, inbox)
	}
	w := aw_begin();
	json_kint(*w, "postable_channels", postable);
	json_kbool(*w, "premium_progress_bar_enabled", false);
	json_kbool(*w, "viewing_all_channels", true);
	json_kint(*w, "num_recent_channels", 0);
	json_kint(*w, "num_unread_channels", unread.count);
	json_key(*w, "unread_channel_ids");
	json_arr(*w);
	for unread json_snowflake(*w, it);
	json_arr_end(*w);
	json_kbool(*w, "guild_theme_enabled", false);
	json_kbool(*w, "guild_theme_is_custom", false);
	aw_guild(*w, c, guild_id);
	if channel_id != 0 aw_channel(*w, c, channel_id);
	aw_track(c, "guild_viewed", *w);
}

// ---- voice ----

analytics_join_voice :: (c: *Client, guild_id: Snowflake, channel_id: Snowflake) {
	s := *c.store;
	ch := channel_get(s, channel_id);
	in_channel, custom := 0, 0;
	for vs, uid: s.voice_states {
		if vs.channel_id != channel_id || uid == s.me continue;
		in_channel += 1;
		p := table_find_pointer(*s.presences, uid);
		if p && p.activity custom += 1;
	}
	w := aw_begin();
	json_knull(*w, "location");
	json_ksnow(*w, "channel_id", channel_id);
	json_kint(*w, "channel_type", ifx ch then cast(s64) ch.kind else 2);
	json_kint(*w, "channel_bitrate", ifx ch && ch.bitrate > 0 then ch.bitrate else 64000);
	aw_ksnow_or_null(*w, "guild_id", guild_id);
	// fastcord runs no game detection: no game is reported
	json_kstr(*w, "game_name", "");
	json_knull(*w, "game_platform");
	json_knull(*w, "game_id");
	json_kbool(*w, "was_moved", false);
	free(c.analytics.join_voice_id,, c.allocator);
	c.analytics.join_voice_id = uuid4(,, c.allocator);
	json_kstr(*w, "join_voice_id", c.analytics.join_voice_id);
	json_kint(*w, "custom_status_count", custom);
	json_kint(*w, "voice_state_count", in_channel);
	json_kint(*w, "video_stream_count", 0);
	json_kbool(*w, "video_enabled", false);
	aw_track(c, "join_voice_channel", *w);
	if !guild_id analytics_exposed(c, "PrivateChannelCallDuration", "2026-10-gdm-duration-timer");
	voice_session_reset(*c.analytics);
	c.analytics.voice.guild_id, c.analytics.voice.channel_id, c.analytics.voice.join_ms, c.analytics.voice.ring = guild_id, channel_id, now_ms(), false;
}

// analytics_shelf_fetched: network_action_embedded_activities_fetch_shelf (worker
// thread): guild_id is the ?guild_id= value, "" for a call's shelf without one.
analytics_shelf_fetched :: (c: *Client, j: *Job, status: int) {
	if status == 0 return;
	gid := "";
	i := find_index_from_left(j.path, "guild_id=");
	if i >= 0 gid = advance(j.path, i + "guild_id=".count);
	w := aw_begin();
	json_kint(*w, "status_code", status);
	json_kstr(*w, "url", "/activities/shelf");
	json_kstr(*w, "request_method", "get");
	json_kstr(*w, "guild_id", gid);
	aw_track(c, "network_action_embedded_activities_fetch_shelf", *w);
}

// analytics_shelf_fetched_null: the same for the call's second shelf load, which
// reports guild_id null (fixture dm_call/start_call).
analytics_shelf_fetched_null :: (c: *Client, j: *Job, status: int) {
	if status == 0 return;
	w := aw_begin();
	json_kint(*w, "status_code", status);
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
	if kind == "audio" promo_call_sounds(c); // the voice panel mounts with the call
}

// ---- the voice connection (the official media engine's events) ----
// The app reports src/voice's connection steps (src/app/analytics_env.jai
// voice_analytics_frame). Ids, hosts, ports, packet and byte counts, step
// timings, speech and ping are fastcord's own; the engine's versions, its
// internal timings and audio-processing statistics are synthesized from the
// fixtures (join_voice_channel, voice_with_b, dm_call; CLIENT_RULES "Analytics").

VOICE_BACKEND_VERSION :: "0.22.2";
RTC_WORKER_BACKEND_VERSION :: "1.7.1";

Voice_Devices :: struct {
	input, output, camera: string; // names, "" = none ("Default (<name>)" is the official form)
	inputs, outputs, cameras: int;
}

// Voice_Sample: the connection as the app sees it, once per frame.
Voice_Sample :: struct {
	speaking, hearing, muted, deafened: bool;
	packets_sent, packets_received, packets_lost, bytes_sent, bytes_received: s64;
	ping_ms: int;
	jitter_ms: float64;
	target_frames: int;
	members: int; // E2EE group size
}

Voice_Session :: struct {
	rtc_id, media_session, hostname: string; // owned (Analytics.allocator)
	devices: Voice_Devices; // strings owned
	ring: bool; // joined from an incoming call's ring (no join_voice_id)
	guild_id, channel_id: Snowflake;
	port: int;
	join_ms, created_ms, ws_ms, ready_ms, select_ms, connected_ms: s64;
	last: Voice_Sample;
	last_ms, sampled_ms: s64;
	speaking_ms, listening_ms, participation_ms, muted_ms, deafened_ms: s64;
	speech_start: s64;
	speech_events, speech_100, speech_500: int;
	speech_100_ms, speech_500_ms: s64;
	first_speech: [3]s64; // ms from connect to the first 1 ms / 100 ms / 1000 ms of speech
	ping_sum, ping_n: s64;
	cpu: [..]float64; // one sample per second (UI thread)
	mem: [..]s64;
	max_states, total_states: int;
	seen: [..]Snowflake;
	alone_since: s64; // connected with nobody else in the channel (secure_frames_transition alone_wait_duration)
	members: int;
	peer_left_ms: s64; // a transition began when a peer left and was not executed
	transitions: int;
}

// voice_session_reset: forget the connection (the joined channel is kept).
voice_session_reset :: (a: *Analytics) {
	v := *a.voice;
	g, ch, join, ring := v.guild_id, v.channel_id, v.join_ms, v.ring;
	push_allocator(a.allocator);
	free(v.rtc_id);
	free(v.media_session);
	free(v.hostname);
	free(v.devices.input);
	free(v.devices.output);
	free(v.devices.camera);
	array_free(v.cpu);
	array_free(v.mem);
	array_free(v.seen);
	v.* = .{guild_id = g, channel_id = ch, join_ms = join, ring = ring};
}

aw_voice_ids :: (w: *Json, v: *Voice_Session, ch: *Channel) {
	aw_ksnow_or_null(w, "guild_id", v.guild_id);
	json_ksnow(w, "channel_id", v.channel_id);
	json_kint(w, "channel_type", ifx ch then cast(s64) ch.kind else 2);
	json_kstr(w, "rtc_connection_id", v.rtc_id);
	json_kstr(w, "context", "default");
	json_kstr(w, "voice_backend_version", VOICE_BACKEND_VERSION);
	json_kstr(w, "rtc_worker_backend_version", RTC_WORKER_BACKEND_VERSION);
}

voice_others :: (c: *Client, channel_id: Snowflake) -> int {
	n := 0;
	for vs, uid: c.store.voice_states if vs.channel_id == channel_id && uid != c.store.me n += 1;
	return n;
}

// analytics_voice_connecting: the app opened a voice connection (voice_connection_connecting;
// the caller's video_layout_toggled first, as the official call view mounts).
analytics_voice_connecting :: (c: *Client, rtc_id: string, hostname: string, devices: Voice_Devices, muted: bool) {
	a := *c.analytics;
	v := *a.voice;
	voice_session_reset(a);
	s := *c.store;
	ring := v.ring;
	if !v.join_ms v.join_ms = now_ms();
	v.rtc_id = copy_string(rtc_id,, a.allocator);
	v.hostname = copy_string(hostname,, a.allocator);
	v.devices = devices;
	v.devices.input = copy_string(devices.input,, a.allocator);
	v.devices.output = copy_string(devices.output,, a.allocator);
	v.devices.camera = copy_string(devices.camera,, a.allocator);
	v.created_ms = now_ms();
	v.cpu.allocator, v.mem.allocator, v.seen.allocator = a.allocator, a.allocator, a.allocator;
	ch := channel_get(s, v.channel_id);
	private := v.guild_id == 0;
	if private && !ring {
		l := aw_begin();
		json_kstr(*l, "video_layout", "minimum");
		json_ksnow(*l, "channel_id", v.channel_id);
		json_kint(*l, "channel_type", ifx ch then cast(s64) ch.kind else 1);
		json_knull(*l, "guild_id");
		json_knull(*l, "media_session_id");
		json_kint(*l, "voice_state_count", voice_others(c, v.channel_id));
		json_kint(*l, "video_stream_count", 0);
		json_kbool(*l, "video_enabled", false);
		json_knull(*l, "game_name");
		json_knull(*l, "game_id");
		aw_track(c, "video_layout_toggled", *l);
	}
	dev :: (w: *Json, k: string, name: string, n: int) {
		if name json_kstr(w, k, tprint("Default (%)", name)); else json_knull(w, k);
		json_kint(w, tprint("%_count", k), n);
	}
	w := aw_begin();
	dev(*w, "input_device", devices.input, devices.inputs);
	dev(*w, "output_device", devices.output, devices.outputs);
	if devices.camera json_kstr(*w, "camera_device", devices.camera); else json_knull(*w, "camera_device");
	json_kint(*w, "camera_device_count", devices.cameras);
	aw_ksnow_or_null(*w, "guild_id", v.guild_id);
	json_ksnow(*w, "channel_id", v.channel_id);
	json_kstr(*w, "rtc_connection_id", v.rtc_id);
	json_kstr(*w, "hostname", v.hostname);
	json_kint(*w, "connect_count", 1);
	json_kstr(*w, "context", "default");
	json_kint(*w, "channel_type", ifx ch then cast(s64) ch.kind else 2);
	json_kbool(*w, "is_muted", muted);
	if ring json_knull(*w, "join_voice_id"); else json_kstr(*w, "join_voice_id", a.join_voice_id);
	json_kint(*w, "connection_serial", 0);
	aw_track(c, "voice_connection_connecting", *w);
}

// audio_input_initialized: the official engine opens the microphone while the
// connection authenticates; fastcord reports it as its voice socket opens (and
// opens the microphone at SESSION_DESCRIPTION).
analytics_audio_input_initialized :: (c: *Client) {
	v := *c.analytics.voice;
	if !v.rtc_id || !v.devices.input return;
	// the official engine's state names run a step ahead of our connection's here
	client_set_rtc_state(c, .Rtc_Connecting);
	// the media engine reads these as it connects (0.0.420: fixture join_voice_channel)
	analytics_exposed(c, "media_engine_connect", "2026-02-process-boost-on-voice");
	analytics_exposed(c, "updateVoiceFidelityCaps", "2026-08-audio-fidelity");
	analytics_exposed(c, "RTCConnection", "2026-09-single-cpu-copy");
	m := aw_begin();
	json_kstr(*m, "device_name", tprint("default (%)", v.devices.input));
	json_kint(*m, "time_to_initialized_ms", 0);
	json_kstr(*m, "rtc_connection_id", v.rtc_id);
	aw_track(c, "audio_input_initialized", *m);
}

// analytics_voice_ready: the voice gateway's READY (voice_connection_remote_streams_created).
analytics_voice_ready :: (c: *Client, ws_ms: s64, ready_ms: s64, port: int) {
	v := *c.analytics.voice;
	if !v.rtc_id return;
	v.ws_ms, v.ready_ms, v.port = ws_ms, ready_ms, port;
	client_set_rtc_state(c, .Rtc_Connected);
	w := aw_begin();
	aw_voice_ids(*w, v, channel_get(*c.store, v.channel_id));
	json_kint(*w, "number_of_users", voice_others(c, v.channel_id));
	json_kint(*w, "duration_ms", ready_ms - v.created_ms);
	aw_track(c, "voice_connection_remote_streams_created", *w);
	promo_voice_invite_entrypoint(c, v.channel_id);
}

// analytics_voice_connected: SESSION_DESCRIPTION (voice_connection_success,
// voice_connection_ttc_collected, media_session_joined). RTC states map to our
// steps: awaiting endpoint = join to connection, authenticating = socket open,
// connecting = to READY, rtc connecting = to SESSION_DESCRIPTION.
analytics_voice_connected :: (c: *Client, select_ms: s64, connected_ms: s64, media_session_id: string) {
	a := *c.analytics;
	v := *a.voice;
	if !v.rtc_id return;
	v.select_ms, v.connected_ms = select_ms, connected_ms;
	v.media_session = copy_string(media_session_id,, a.allocator);
	v.alone_since = ifx voice_others(c, v.channel_id) == 0 then connected_ms else 0;
	ch := channel_get(*c.store, v.channel_id);
	locks.lock(*c.id.mu);
	region := copy_string(c.rtc_regions,, temp); // the latency probe's order, best first
	locks.unlock(*c.id.mu);
	found, best := split_from_left(region, #char ",");
	if found region = best;
	if !region region = "us-west";
	w := aw_begin();
	aw_voice_ids(*w, v, ch);
	json_kstr(*w, "hostname", v.hostname);
	json_kint(*w, "port", v.port);
	json_kstr(*w, "protocol", "udp");
	json_kstr(*w, "address_family", "ipv4");
	json_kstr(*w, "cloudflare_best_region", region);
	json_kint(*w, "connect_time", connected_ms - v.join_ms);
	json_kint(*w, "connect_count", 1);
	json_kstr(*w, "audio_subsystem", "standard");
	json_kstr(*w, "audio_layer", "platformDefaultAudio");
	json_kbool(*w, "automatic_audio_subsystem", true);
	json_knull(*w, "media_session_id");
	if v.ring json_knull(*w, "join_voice_id"); else json_kstr(*w, "join_voice_id", a.join_voice_id);
	json_kbool(*w, "is_camera_enabled", false);
	json_kbool(*w, "video_supported", true);
	json_kint(*w, "state_awaiting_endpoint_ms", v.created_ms - v.join_ms);
	json_kint(*w, "state_authenticating_ms", max(v.ws_ms - v.created_ms, 0));
	json_kint(*w, "state_connecting_ms", max(v.ready_ms - v.ws_ms, 0));
	json_kint(*w, "state_disconnected_ms", 0);
	json_kint(*w, "state_ice_checking_ms", 0);
	json_kint(*w, "state_no_route_ms", 0);
	json_kint(*w, "state_rtc_connecting_ms", max(connected_ms - v.ready_ms, 0));
	json_kint(*w, "state_rtc_disconnected_ms", 0);
	aw_track(c, "voice_connection_success", *w);
	locks.lock(*a.mu);
	r: [5]float64;
	for * r it.* = synth_between(*a.synth, 0, 1);
	locks.unlock(*a.mu);
	t := aw_begin();
	json_kstr(*t, "rtc_connection_id", v.rtc_id);
	json_kstr(*t, "hostname", v.hostname);
	json_kstr(*t, "address_family", "ipv4");
	json_kint(*t, "time_1_creation_to_connect", v.created_ms - v.join_ms);
	json_kint(*t, "time_2_media_engine_connect", 5 + cast(s64) (4 * r[0]));
	json_kint(*t, "time_3_media_engine_create_native_connection", cast(s64) (1.5 * r[1]));
	json_kint(*t, "time_4_media_engine_connect_to_socket", max(v.ws_ms - v.created_ms, 0));
	json_knull(*t, "time_5_scheduling_connected_callback");
	aw_kf64(*t, "time_6_state_connected_to_end_measure", cast(float64) (connected_ms - select_ms) + 0.1 * floor(10 * r[2]));
	json_kint(*t, "connect_count", 1);
	aw_kf64(*t, "rtc_connecting_native_connect", cast(float64) (select_ms - v.ready_ms) + 0.1 * floor(10 * r[3]));
	aw_kf64(*t, "rtc_connecting_native_codecs", 14 + floor(80 * r[4]) / 10);
	aw_kf64(*t, "rtc_connecting_native_crypto_modes", 0.5);
	aw_kf64(*t, "select_protocol_duration_ms", cast(float64) (connected_ms - select_ms) + 0.1 * floor(10 * r[0]));
	aw_track(c, "voice_connection_ttc_collected", *t);
	m := aw_begin();
	aw_voice_ids(*m, v, ch);
	json_kstr(*m, "media_session_id", v.media_session);
	aw_track(c, "media_session_joined", *m);
}

// start_speaking / start_listening: the first time we speak or hear someone in
// the channel (throttled per server, SCI_THROTTLES).
analytics_voice_speech :: (c: *Client, listening: bool) {
	v := *c.analytics.voice;
	if !v.rtc_id return;
	s := *c.store;
	w := aw_begin();
	if listening {
		json_kbool(*w, "mute", v.last.muted);
		json_kbool(*w, "anyone_priority", false);
	} else {
		json_kstr(*w, "mode", "VOICE_ACTIVITY");
		json_kbool(*w, "priority", false);
	}
	json_ksnow(*w, "channel", v.channel_id);
	aw_ksnow_or_null(*w, "server", v.guild_id);
	json_ksnow(*w, "channel_id", v.channel_id);
	aw_ksnow_or_null(*w, "guild_id", v.guild_id);
	json_kstr(*w, "rtc_connection_id", v.rtc_id);
	json_kstr(*w, "media_session_id", v.media_session);
	json_kint(*w, "voice_state_count", voice_others(c, v.channel_id) + 1);
	for string.["game_platform", "game_name", "game_exe_name", "game_id", "game_distributor", "game_distributor_game_id", "game_metadata"] json_knull(*w, it);
	if !listening {
		json_kint(*w, "packets_sent", v.last.packets_sent);
		json_kint(*w, "packets_sent_lost", 0);
		json_kint(*w, "packets_received", v.last.packets_received);
		json_kint(*w, "packets_received_lost", v.last.packets_lost);
		for string.["num_nacks_sent", "fec_packets_received", "fec_packets_discarded"] json_kint(*w, it, 0);
	}
	if v.guild_id && guild_get(s, v.guild_id) aw_guild(*w, c, v.guild_id, with_id = false);
	aw_channel(*w, c, v.channel_id, with_id = false);
	aw_track(c, ifx listening then "start_listening" else "start_speaking", *w);
}

// analytics_voice_frame: the app's per-frame sample; speech and presence
// statistics for voice_disconnect / leave_voice_channel, and the E2EE group's
// transitions (secure_frames_transition: we joined others (commit) or others
// joined us (welcome); sizes and durations synthesized around our timings).
analytics_voice_frame :: (c: *Client, x: Voice_Sample) {
	a := *c.analytics;
	v := *a.voice;
	if !v.rtc_id || !v.connected_ms return;
	now := now_ms();
	dt := ifx v.last_ms then now - v.last_ms else 0;
	if v.last.speaking v.speaking_ms += dt;
	if v.last.hearing v.listening_ms += dt;
	if v.last.speaking || v.last.hearing v.participation_ms += dt;
	if v.last.muted v.muted_ms += dt;
	if v.last.deafened v.deafened_ms += dt;
	if x.speaking && !v.last.speaking v.speech_start = now;
	if !x.speaking && v.last.speaking && v.speech_start {
		len := now - v.speech_start;
		v.speech_events += 1;
		if len >= 100 { v.speech_100 += 1; v.speech_100_ms += len; }
		if len >= 500 { v.speech_500 += 1; v.speech_500_ms += len; }
	}
	if x.speaking && v.speech_start {
		spoken := v.speaking_ms + now - v.speech_start;
		for ms, i: s64.[1, 100, 1000] if !v.first_speech[i] && spoken >= ms v.first_speech[i] = now - v.connected_ms;
	}
	if x.speaking && !v.last.speaking && v.speech_events == 0 analytics_voice_speech(c, false);
	if x.hearing && !v.last.hearing && v.listening_ms == 0 analytics_voice_speech(c, true);
	if now - v.sampled_ms >= 1000 {
		v.sampled_ms = now;
		cpu, ok := process_cpu_percent();
		if ok array_add(*v.cpu, cpu);
		locks.lock(*a.mu);
		array_add(*v.mem, synth_memory(*a.synth, now, true));
		locks.unlock(*a.mu);
		if x.ping_ms > 0 { v.ping_sum += x.ping_ms; v.ping_n += 1; }
		states := 1;
		for vs, uid: c.store.voice_states if vs.channel_id == v.channel_id && uid != c.store.me {
			states += 1;
			if !array_find(v.seen, uid) array_add(*v.seen, uid);
		}
		v.max_states = max(v.max_states, states);
	}
	if x.members > v.members && x.members >= 2 {
		analytics_secure_frames(c, x.members);
		v.peer_left_ms = 0;
	} else if x.members < v.members && v.members >= 2 {
		v.peer_left_ms = now;
	}
	v.members = max(x.members, ifx v.peer_left_ms then v.members else x.members);
	v.last, v.last_ms = x, now;
}

// secure_frames_transition: an E2EE group change (members >= 2), or members
// == 0 for the one left unexecuted when we leave.
analytics_secure_frames :: (c: *Client, members: int) {
	a := *c.analytics;
	v := *a.voice;
	now := now_ms();
	locks.lock(*a.mu);
	r: [4]float64;
	for * r it.* = synth_between(*a.synth, 0, 1);
	locks.unlock(*a.mu);
	w := aw_begin();
	aw_voice_ids(*w, v, channel_get(*c.store, v.channel_id));
	json_kstr(*w, "media_session_id", v.media_session);
	json_ksnow(*w, "sender_user_id", c.store.me);
	json_kint(*w, "transition_id", 0);
	json_kint(*w, "protocol_version", 1);
	if members == 0 {
		json_kint(*w, "prepare_wait_duration", cast(s64) (2 * r[0]));
		json_kint(*w, "prepare_duration", 1);
		json_kbool(*w, "incomplete", true);
		json_kint(*w, "active_transition_count", 1);
		json_kint(*w, "time_since_creation", now - v.peer_left_ms);
		aw_track(c, "secure_frames_transition", *w);
		return;
	}
	alone := v.alone_since != 0; // others joined us (welcome), else we joined them (commit)
	wait := ifx alone then now - v.alone_since else 0;
	since := ifx alone then wait + cast(s64) (8 * r[0]) else 25 + cast(s64) (10 * r[0]);
	json_kint(*w, "start_to_init_duration", v.connected_ms - v.join_ms - 300 + cast(s64) (60 * r[1]));
	json_kint(*w, "init_duration", cast(s64) (2 * r[2]));
	json_kint(*w, "last_proposals_duration", 1 + cast(s64) (2 * r[3]));
	proposals := 497 + cast(s64) (3 * r[0]);
	json_kint(*w, "total_proposals_size", proposals);
	json_kint(*w, "total_commit_welcome_size", 1159 + cast(s64) (4 * r[1]));
	if alone { // others joined: their commit came with a welcome for us
		json_kint(*w, "welcome_wait_duration", since - 1);
		json_kint(*w, "welcome_duration", 1 + cast(s64) (2 * r[2]));
		json_kint(*w, "welcome_size", 956 + cast(s64) (3 * r[3]));
		json_kbool(*w, "welcome_error", false);
	} else {
		json_kint(*w, "commit_wait_duration", since - 2);
		json_kint(*w, "commit_duration", 1);
		json_kint(*w, "commit_size", 203 + cast(s64) (2 * r[2]));
		json_kbool(*w, "commit_error", false);
	}
	json_kint(*w, "active_transition_count", 1);
	json_kint(*w, "time_since_creation", since);
	json_kint(*w, "users_added_count", members);
	json_kint(*w, "users_removed_count", 0);
	json_kint(*w, "roster_size_after", members);
	json_kint(*w, "alone_wait_duration", wait);
	json_kint(*w, "time_to_dave_group_excluding_wait", v.connected_ms - v.join_ms + cast(s64) (40 * r[3]));
	aw_track(c, "secure_frames_transition", *w);
	v.transitions += 1;
	v.alone_since = 0;
}

// analytics_voice_leave: VOICE_CHANNEL_SELECT null (hotspot_hidden), then the
// connection's summary: leave_voice_channel, voice_codec_detected, voice_disconnect.
analytics_voice_leave :: (c: *Client) {
	a := *c.analytics;
	v := *a.voice;
	if v.rtc_id && v.peer_left_ms analytics_secure_frames(c, 0);
	client_set_rtc_state(c, .Disconnected); // RTCConnectionStore resets on VOICE_CHANNEL_SELECT
	analytics_hotspot_hidden(c, "VOICE_PANEL_INTRODUCTION");
	if !v.rtc_id {
		voice_session_reset(a);
		return;
	}
	now := now_ms();
	ch := channel_get(*c.store, v.channel_id);
	duration := now - v.created_ms;
	others := voice_others(c, v.channel_id);
	total := 1 + v.seen.count;
	locks.lock(*a.mu);
	extra := cast(s64) synth_between(*a.synth, 400, 1400);
	bwe := cast(s64) synth_between(*a.synth, 700_000, 2_300_000);
	level := synth_between(*a.synth, -135, -75);
	locks.unlock(*a.mu);
	l := aw_begin();
	json_ksnow(*l, "channel_id", v.channel_id);
	json_kint(*l, "channel_type", ifx ch then cast(s64) ch.kind else 2);
	json_kint(*l, "channel_bitrate", ifx ch && ch.bitrate > 0 then ch.bitrate else 64000);
	aw_ksnow_or_null(*l, "guild_id", v.guild_id);
	json_kstr(*l, "rtc_connection_id", v.rtc_id);
	json_kstr(*l, "game_name", "");
	json_kint(*l, "duration", duration);
	json_knull(*l, "game_platform");
	json_knull(*l, "game_id");
	json_kstr(*l, "media_session_id", v.media_session);
	json_kint(*l, "voice_state_count", others);
	json_kint(*l, "video_stream_count", 0);
	json_kbool(*l, "video_enabled", false);
	json_kint(*l, "max_voice_state_count", max(v.max_states, 1));
	json_kint(*l, "total_voice_state_count", total);
	json_kint(*l, "max_listener_count", max(v.max_states, 1));
	json_kint(*l, "total_listener_count", total);
	json_kint(*l, "max_speaker_count", max(v.max_states, 1));
	json_kint(*l, "total_speaker_count", total);
	// the call view: a guild voice channel shows the grid, a DM call its focus view
	json_kint(*l, "view_mode_grid_duration_ms", ifx v.guild_id then duration + extra else 2);
	json_kint(*l, "view_mode_focus_duration_ms", ifx v.guild_id then 0 else duration + extra);
	json_kint(*l, "view_mode_toggle_count", ifx v.guild_id then 0 else 2);
	aw_track(c, "leave_voice_channel", *l);
	k := aw_begin();
	#if OS == .MACOS {
		DECODERS :: string.["Webrtc VP8 libvpx", "Webrtc AV1 dav1d", "Apple H.264 (HW)", "Apple HEVC (HW)", "Apple AV1 (HW)"];
		ENCODERS :: string.["Apple 24-bit RGB", "Apple 32-bit ARGB", "Apple ProRes 422", "Apple ProRes 422 HQ", "Apple ProRes 422 LT", "Apple ProRes 422 Proxy", "Apple ProRes 4444", "Apple ProRes 4444 XQ", "AppleProResHW 422", "AppleProResHW 422 HQ", "AppleProResHW 422 LT", "AppleProResHW 422 Proxy", "AppleProResHW 4444", "AppleProResHW 4444 XQ", "Apple Depth (HEVC)-Apple HEVC (HW)", "Apple Depth (HEVC)-Apple HEVC (SW)", "Apple Disparity (HEVC)-Apple HEVC (HW)", "Apple Disparity (HEVC)-Apple HEVC (SW)", "Apple H.263 (SW)", "Apple H.264 (HW)", "Apple H.264 (SW)", "Apple HEVC (HW)", "Apple HEVC (SW)", "Apple JPEG", "JPEG (HW)", "Apple Muxed Alpha-Apple HEVC (HW)", "Apple Muxed Alpha-Apple HEVC (SW)"];
	} else { // guess: WebRTC's software codecs and the OS's hardware H.264
		DECODERS :: string.["Webrtc VP8 libvpx", "Webrtc AV1 dav1d", "Webrtc H.264 (HW)"];
		ENCODERS :: string.["Webrtc VP8 libvpx", "Webrtc H.264 (HW)"];
	}
	aw_strs(*k, "available_video_decoders", DECODERS);
	aw_strs(*k, "available_video_encoders", ENCODERS);
	json_kstr(*k, "rtc_connection_id", v.rtc_id);
	json_kstr(*k, "media_session_id", v.media_session);
	aw_track(c, "voice_codec_detected", *k);
	analytics_voice_disconnect(c, ch, duration, bwe, level);
	voice_session_reset(a);
}

analytics_voice_disconnect :: (c: *Client, ch: *Channel, duration: s64, bwe: s64, level: float64) {
	v := *c.analytics.voice;
	x := v.last;
	heard := x.packets_received > 0;
	pct :: (xs: []$T, p: int) -> T { return ifx xs then xs[min(xs.count * p / 100, xs.count - 1)] else 0; }
	cpu := array_copy(v.cpu,, temp);
	quick_sort(cpu, (a: float64, b: float64) -> s64 { return ifx a < b then -1 else ifx a > b then 1 else 0; });
	mem := array_copy(v.mem,, temp);
	quick_sort(mem, (a: s64, b: s64) -> s64 { return a - b; });
	w := aw_begin();
	aw_voice_ids(*w, v, ch);
	json_kstr(*w, "hostname", v.hostname);
	json_kint(*w, "port", v.port);
	json_kstr(*w, "protocol", "udp");
	json_kbool(*w, "reconnect", false);
	json_kstr(*w, "reason", "Force Close");
	json_kint(*w, "duration", duration + 1);
	json_kint(*w, "num_local_voice_user_mutes", 0);
	json_kint(*w, "num_local_voice_volumes", 0);
	json_kint(*w, "packets_sent", x.packets_sent);
	json_kint(*w, "packets_sent_lost", 0);
	json_kint(*w, "packets_received", x.packets_received);
	json_kint(*w, "packets_received_lost", x.packets_lost);
	json_kint(*w, "num_nacks_sent", 0);
	fec := x.packets_received / 12;
	json_kint(*w, "fec_packets_received", fec);
	json_kint(*w, "fec_packets_discarded", fec * 15 / 16);
	json_kint(*w, "bytes_sent", x.bytes_sent);
	json_kint(*w, "bytes_received", x.bytes_received);
	json_kint(*w, "outbound_bandwidth_estimate", bwe);
	json_kint(*w, "audio_target_bitrate", 64000);
	// jitter buffer statistics: from our jitter buffer when audio came in, else null
	jb := cast(s64) x.jitter_ms;
	target := x.target_frames * 20;
	stat :: (w: *Json, prefix: string, heard: bool, mean: s64, p75: s64, p95: s64, p99: s64, mx: s64) {
		values := s64.[mean, p75, p95, p99, mx];
		for string.["mean", "p75", "p95", "p99", "max"] {
			k := tprint("%_%", prefix, it);
			if heard json_kint(w, k, values[it_index]); else json_knull(w, k);
		}
	}
	stat(*w, "audio_jitter_buffer", heard, jb / 4, jb / 20, jb * 7 / 4, jb * 2, jb * 9 / 4);
	stat(*w, "audio_jitter_target", heard, target, target, target, target * 2, target * 2);
	stat(*w, "audio_jitter_delay", heard, target + 80, target + 85, target + 90, target + 130, target + 150);
	stat(*w, "relative_reception_delay", heard, 0, 0, 0, 0, 0);
	stat(*w, "relative_playout_delay", heard, 0, 0, 0, 0, 0);
	secs := (duration + 500) / 1000;
	for string.["wifi", "cellular", "ethernet", "bluetooth", "other", "unknown", "none"] json_kint(*w, tprint("duration_connection_type_%", it), ifx it == "unknown" then secs else 0);
	for string.["2g", "3g", "4g", "5g", "unknown"] json_kint(*w, tprint("duration_effective_connection_speed_%", it), ifx it == "4g" then secs else 0);
	for p: int.[25, 50, 75, 90, 95] aw_kf64(*w, tprint("client_performance_cpu_percentile%", p), pct(cpu, p));
	cpu_sum: float64;
	for cpu cpu_sum += it;
	aw_kf64(*w, "client_performance_cpu_mean", ifx cpu then cpu_sum / cast(float64) cpu.count else 0);
	for p: int.[25, 50, 75, 90, 95] json_kint(*w, tprint("client_performance_memory_percentile%", p), pct(mem, p));
	mem_sum: s64;
	for mem mem_sum += it;
	json_kint(*w, "client_performance_memory_min", ifx mem then mem[0] else 0);
	json_kint(*w, "client_performance_memory_max", ifx mem then mem[mem.count - 1] else 0);
	aw_kf64(*w, "client_performance_memory_mean", ifx mem then cast(float64) mem_sum / cast(float64) mem.count else 0);
	// NetEq frame operations (20 ms frames of received audio)
	frames := ifx heard then duration / 12 else 0;
	normal := x.packets_received * 85 / 100;
	ops := s64.[max(frames - normal, 0), normal, normal / 40, normal / 80, normal / 3, normal / 40, 0];
	for string.["silent", "normal", "merged", "expanded", "accelerated", "preemptive_expanded", "cng"] json_kint(*w, tprint("frame_op_%", it), ops[it_index]);
	json_kint(*w, "decryption_failures", 0);
	json_kint(*w, "routing_failures", 0);
	dave := v.transitions > 0;
	dec := ifx dave then x.packets_received * 2 / 3 else 0;
	enc := ifx dave then x.packets_sent * 9 / 2 else 0;
	json_kint(*w, "decrypt_passthrough_count", 0);
	json_kint(*w, "decrypt_success_count", dec);
	json_kint(*w, "decrypt_failure_count", dec / 5);
	json_kint(*w, "decrypt_duration", dec * 5);
	json_kint(*w, "decrypt_attempts", dec);
	for string.["decrypt_missing_key_count", "decrypt_invalid_nonce_count", "decrypt_failure_after_success_count", "encrypt_passthrough_count"] json_kint(*w, it, 0);
	json_kint(*w, "encrypt_success_count", enc);
	json_kint(*w, "encrypt_failure_count", 0);
	json_kint(*w, "encrypt_duration", enc * 4);
	json_kint(*w, "encrypt_attempts", enc);
	json_kint(*w, "encrypt_max_attempts", ifx dave then 1 else 0);
	json_kint(*w, "encrypt_missing_key_count", 0);
	json_kint(*w, "input_device_time_from_connect_to_first_audio_ms", 60 + v.port % 50);
	json_kint(*w, "output_device_time_from_connect_to_first_audio_ms", 3 + v.port % 5);
	// our microphone's level distribution: quiet floor to speech peaks (synthesized around level)
	for p: string.["p1", "p5", "p10", "p25", "p50", "p75", "p90", "p95", "p99", "max", "mean"] {
		db := level - 50;
		if p == "mean" db = level - 30;
		else if it_index >= 4 db += 60 * min(cast(float64) (it_index - 3) / 3, 1);
		aw_kf64(*w, tprint("outbound_audio_level_db_%", p), db);
	}
	json_kint(*w, "duration_listening_ms", v.listening_ms);
	json_kint(*w, "duration_speaking_ms", v.speaking_ms);
	json_kint(*w, "duration_participation_ms", v.participation_ms);
	json_kint(*w, "duration_connected_ms", duration);
	json_kint(*w, "duration_muted_ms", v.muted_ms);
	json_kint(*w, "duration_deafened_ms", v.deafened_ms);
	json_kint(*w, "duration_noise_cancellation_enabled_ms", duration);
	json_kint(*w, "duration_spatial_ms", 0);
	json_kint(*w, "speech_event_count", v.speech_events);
	for string.["time_to_first_1ms_speech_ms", "time_to_first_100ms_speech_ms", "time_to_first_1000ms_speech_ms"] {
		if v.first_speech[it_index] json_kint(*w, it, v.first_speech[it_index]); else json_knull(*w, it);
	}
	json_kint(*w, "duration_speaking_gte_100ms_ms", v.speech_100_ms);
	json_kint(*w, "speech_event_count_gte_100ms", v.speech_100);
	if v.speech_500 {
		json_kint(*w, "duration_speaking_gte_500ms_ms", v.speech_500_ms);
		json_kint(*w, "speech_event_count_gte_500ms", v.speech_500);
	}
	json_kint(*w, "duration_listening", (v.listening_ms + 500) / 1000);
	json_kint(*w, "duration_speaking", (v.speaking_ms + 500) / 1000);
	json_kint(*w, "duration_participation", (v.participation_ms + 500) / 1000);
	json_kint(*w, "duration_connected", secs);
	used :: (w: *Json, k: string, ms: s64) {
		json_key(w, tprint("%_ids", k));
		json_raw(w, ifx ms then "[\"default\"]" else "[]");
		json_key(w, tprint("%_ms", k));
		json_raw(w, ifx ms then tprint("[%]", ms) else "[]");
	}
	used(*w, "duration_input_device_used", v.speaking_ms);
	used(*w, "duration_output_device_used", v.listening_ms);
	dev :: (w: *Json, k: string, name: string, n: int) {
		if name json_kstr(w, k, tprint("Default (%)", name)); else json_knull(w, k);
		json_kint(w, tprint("%_count", k), n);
	}
	dev(*w, "input_device", v.devices.input, v.devices.inputs);
	dev(*w, "output_device", v.devices.output, v.devices.outputs);
	for string.["ptt_queue_latency_max", "ptt_queue_latency_mean", "ptt_queue_latency_p50", "ptt_queue_latency_p95", "ptt_queue_latency_samples", "num_noise_cancellation_changes"] json_kint(*w, it, 0);
	json_kstr(*w, "media_session_id", v.media_session);
	json_kint(*w, "channel_bitrate", ifx ch && ch.bitrate > 0 then ch.bitrate else 64000);
	json_kstr(*w, "cloudflare_best_region", "us-west");
	json_kint(*w, "connect_count", 1);
	json_kint(*w, "ping_average", ifx v.ping_n then v.ping_sum / v.ping_n else 0);
	json_kint(*w, "ping_bad_count", 0);
	json_kint(*w, "ping_timeout", 0);
	json_kbool(*w, "input_detected", v.speech_events > 0 || x.speaking);
	json_kbool(*w, "no_input_detected_notice", false);
	json_kstr(*w, "audio_input_mode", "VOICE_ACTIVITY");
	json_kbool(*w, "automatic_audio_input_sensitivity_enabled", true);
	json_kint(*w, "audio_input_sensitivity", -60);
	json_kbool(*w, "echo_cancellation_enabled", true);
	json_kbool(*w, "sidechain_compression_enabled", true);
	json_kbool(*w, "noise_suppression_enabled", false);
	json_kbool(*w, "noise_cancellation_enabled", true);
	json_kint(*w, "noise_canceller_error", 0);
	json_kbool(*w, "automatic_gain_control_enabled", true);
	json_kint(*w, "voice_output_volume", 100);
	json_kint(*w, "voice_input_volume", 100);
	json_kstr(*w, "encryption_mode", "aead_aes256_gcm_rtpsize");
	json_kint(*w, "channel_count", 1);
	json_knull(*w, "device_performance_class");
	json_kint(*w, "num_fast_udp_reconnects", 0);
	json_kstr(*w, "audio_subsystem", "standard");
	json_kstr(*w, "audio_layer", "platformDefaultAudio");
	json_kbool(*w, "automatic_audio_subsystem", true);
	json_kint(*w, "audio_capture_sample_rate_mismatch_percent", 0);
	json_kstr(*w, "krisp_sdk_version", "9.9.3.891");
	json_kint(*w, "secure_frames_max_concurrent_transitions", ifx dave then 1 else 0);
	json_kint(*w, "secure_frames_transition_prepare_count", ifx v.peer_left_ms then 1 else 0);
	json_kint(*w, "secure_frames_transition_execute_count", 0);
	json_kbool(*w, "vad_use_advanced_voice_activity", true);
	json_kbool(*w, "soundshare_experimental", false);
	if v.ring json_knull(*w, "join_voice_id"); else json_kstr(*w, "join_voice_id", c.analytics.join_voice_id);
	json_kbool(*w, "bypass_system_input_processing", true);
	json_kstr(*w, "system_microphone_mode", "standard");
	json_kstr(*w, "output_audio_route_type", "unknown");
	json_knull(*w, "battery_usage");
	json_kstr(*w, "krisp_nc_model", "krisp-nc-o-med-v7.kef");
	aw_track(c, "voice_disconnect", *w);
}

// ---- guild creation ----

analytics_guild_create_result :: (c: *Client, status: int, step_shown_ms: s64) {
	w := aw_begin();
	json_kint(*w, "status_code", status);
	json_kstr(*w, "url", "/guilds");
	json_kstr(*w, "request_method", "post");
	json_kstr(*w, "template_name", "CREATE");
	json_kbool(*w, "is_community_intent", false);
	aw_track(c, "network_action_guild_create", *w);
	if status < 200 || status >= 300 return;
	w2 := aw_begin();
	json_kstr(*w2, "flow_type", "create_guild");
	json_kstr(*w2, "from_step", "guild_create");
	json_kstr(*w2, "to_step", "create_success");
	aw_kf64(*w2, "seconds_on_from_step", ifx step_shown_ms != 0 then cast(float64) (now_ms() - step_shown_ms) / 1000 else 0);
	aw_track(c, "nuo_transition", *w2);
}

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
	if channel_id != 0 aw_channel(*w, c, channel_id);
	json_kstr(*w, "type", entry.type);
	json_kbool(*w, "is_friend", true);
	json_kstr(*w, "source", entry.source);
	aw_track(c, "open_popout", *w);
	w2 := aw_begin();
	if channel_id != 0 aw_channel(*w2, c, channel_id);
	json_kint(*w2, "default_results_count", friends + non_friends);
	json_kint(*w2, "default_results_friend_count", friends);
	json_kint(*w2, "default_results_non_friend_count", non_friends);
	json_kstr(*w2, "entry_point_type", entry.type);
	json_kstr(*w2, "entry_point_source", entry.source);
	aw_track(c, "private_channel_invite_modal_opened", *w2);
}

// group_dm_picker_searched: the user typed a search in the picker.
group_dm_picker_searched :: (c: *Client) { c.analytics.gdm_searches += 1; }

analytics_create_dm_clicked :: (c: *Client, user_ids: []Snowflake) {
	a := *c.analytics;
	friends := count_friends(*c.store, user_ids);
	w := aw_begin();
	json_kbool(*w, "is_new_dm", true);
	json_kstr(*w, "entry_point_type", a.gdm_entry.type);
	json_kstr(*w, "entry_point_source", a.gdm_entry.source);
	json_key(*w, "recipient_ids");
	json_arr(*w);
	for user_ids json_snowflake(*w, it);
	json_arr_end(*w);
	json_kint(*w, "num_searches", a.gdm_searches);
	json_key(*w, "affinity_score");
	json_raw(*w, "[]"); // fastcord ranks no affinity
	json_kbool(*w, "name_is_set", false);
	json_kbool(*w, "icon_is_set", false);
	json_kint(*w, "friend_recipient_count", friends);
	json_kint(*w, "non_friend_recipient_count", user_ids.count - friends);
	aw_track(c, "create_dm_user_list_clicked", *w);
	a.gdm_pending = true;
}

// analytics_group_dm_created: the new group DM opened (Open_Dm result).
analytics_group_dm_created :: (c: *Client, channel_id: Snowflake) {
	a := *c.analytics;
	if !a.gdm_pending return;
	a.gdm_pending = false;
	analytics_channel_opened(c, 0, channel_id);
	ch := channel_get(*c.store, channel_id);
	w := aw_begin();
	json_ksnow(*w, "channel_id", channel_id);
	json_kint(*w, "channel_type", ifx ch then cast(s64) ch.kind else 3);
	json_kbool(*w, "new_name_set", false);
	json_kbool(*w, "new_icon_set", false);
	json_kstr(*w, "location", "new group dm invite modal");
	aw_track(c, "gdm_edit_interacted", *w);
}

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
	for rel, uid: s.relationships {
		if rel.kind == {
			case .Friend;
				friends += 1;
				p := table_find_pointer(*s.presences, uid);
				if p {
					if p.status == {
						case .Online; online += 1;
						case .Idle;   idle += 1;
						case .Dnd;    dnd += 1;
					}
				}
			case .Incoming_Request; incoming += 1;
			case .Outgoing_Request; outgoing += 1;
		}
	}
	NAMES :: string.["ONLINE", "ALL", "PENDING", "ADD_FRIEND"];
	w := aw_begin();
	json_kstr(*w, "tab_opened", NAMES[cast(int) tab]);
	json_kint(*w, "num_friends", friends);
	json_kint(*w, "num_friends_online", online);
	json_kint(*w, "num_friends_idle", idle);
	json_kint(*w, "num_friends_dnd", dnd);
	json_kint(*w, "num_outgoing_requests", outgoing);
	json_kint(*w, "num_incoming_requests", incoming);
	// game friends (Discord's game relationships) are not shown by fastcord
	json_kint(*w, "num_game_friends", 0);
	json_kint(*w, "num_game_outgoing_requests", 0);
	json_kint(*w, "num_game_incoming_requests", 0);
	json_kbool(*w, "now_playing_visible", true);
	json_kint(*w, "now_playing_num_cards", now_playing_cards);
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
		json_kint(*w, "current_channel_type", ifx ch then cast(s64) ch.kind else 0);
	}
	json_kstr(*w, "source", "KEYBIND");
	aw_track(c, "quickswitcher_opened", *w);
}

// Quick switcher results as the official QuickSwitcher types them.
Qs_Kind :: enum u8 { User; Group_Dm; Text_Channel; Voice_Channel; Guild; }
Qs_Result :: struct {
	kind: Qs_Kind;
	id: Snowflake; // the DM's user, the channel or the guild
	guild_id: Snowflake;
	score: float64; // fastcord's own match score, mapped below
}

// analytics_quickswitcher_closed: quickswitcher_closed, then
// quickswitcher_result_selected when a result was chosen (selected >= 0).
// The official search scores are synthesized: each type's empty-query score
// from the fixtures (USER 12000-15099, TEXT_CHANNEL 20000) raised by our own
// match score; result counts are reported only for a typed query, as officially.
analytics_quickswitcher_closed :: (c: *Client, guild_id: Snowflake, channel_id: Snowflake, query: string, max_query: int, results: []Qs_Result, selected := -1) {
	TYPES :: string.["USER", "GROUP_DM", "TEXT_CHANNEL", "VOICE_CHANNEL", "GUILD"];
	BASE :: float64.[12000, 12000, 20000, 20000, 10000];
	score :: (r: Qs_Result) -> float64 #expand { return BASE[r.kind] + 1000 * r.score; }
	digits := 0;
	for cast([]u8) query if is_digit(it) digits += 1;
	w := aw_begin();
	if channel_id {
		json_ksnow(*w, "current_channel_id", channel_id);
		aw_ksnow_or_null(*w, "current_guild_id", guild_id);
	} else {
		aw_ksnow_or_null(*w, "current_guild_id", guild_id);
	}
	json_kstr(*w, "query_mode", "GENERAL");
	json_kint(*w, "query_length", query.count);
	json_kint(*w, "max_query_length", max_query);
	json_kbool(*w, "is_email_like", contains(query, "@") && contains(query, "."));
	json_kbool(*w, "is_phone_like", query.count >= 7 && digits * 10 >= query.count * 7);
	json_kbool(*w, "is_username_like", query.count >= 2 && !contains(query, " ") && !begins_with(query, "#"));
	json_kstr(*w, "query", query);
	top := ifx results then results[0] else .{kind = .User};
	json_kstr(*w, "top_result_type", TYPES[top.kind]);
	aw_kf64(*w, "top_result_score", ifx results then score(top) else 0);
	counts: [5]int;
	if query for results counts[it.kind] += 1;
	json_kint(*w, "num_results_total", ifx query then results.count else 0);
	json_kint(*w, "num_results_users", counts[0]);
	json_kint(*w, "num_results_text_channels", counts[2]);
	json_kint(*w, "num_results_voice_channels", counts[3]);
	json_kint(*w, "num_results_guilds", counts[4]);
	json_kint(*w, "num_results_group_dms", counts[1]);
	if channel_id {
		ch := channel_get(*c.store, channel_id);
		json_kint(*w, "current_channel_type", ifx ch then cast(s64) ch.kind else 0);
	}
	json_obj_end(*w);
	props := json_body(json_string(*w));
	analytics_track(c, "quickswitcher_closed", props);
	if selected < 0 || selected >= results.count return;
	r := results[selected];
	s := aw_begin();
	json_kstr(*s, "selected_type", TYPES[r.kind]);
	aw_kf64(*s, "selected_score", score(r));
	json_kint(*s, "selected_index", selected);
	if r.kind == {
		case .User;  json_ksnow(*s, "selected_user_id", r.id);
		case .Guild; json_ksnow(*s, "selected_guild_id", r.id);
		case;
			if r.guild_id json_ksnow(*s, "selected_guild_id", r.guild_id);
			json_ksnow(*s, "selected_channel_id", r.id);
	}
	json_obj_end(*s);
	analytics_track(c, "quickswitcher_result_selected", tprint("%,%", props, json_body(json_string(*s))));
}

// keyboard_shortcut_used: a global keybind (Escape closes a layer: "CLOSE_*").
analytics_keyboard_shortcut :: (c: *Client, name: string, combo: string) {
	w := aw_begin();
	json_kstr(*w, "shortcut_name", name);
	json_kstr(*w, "shortcut_combo", combo);
	aw_track(c, "keyboard_shortcut_used", *w);
}

// mentions seen (user_status_updated reports how long ago).
analytics_note_message :: (c: *Client, d: V) {
	s := *c.store;
	m := vmap(d);
	if fsnow(fmap(m, "author"), "id") == s.me return;
	now := now_ms();
	a := *c.analytics;
	if fbool(m, "mention_everyone") a.last_everyone_mention_ms = now;
	for flist(m, "mentions") if fsnow(vmap(it), "id") == s.me a.last_mention_ms = now;
	gid := fsnow(m, "guild_id");
	if gid != 0 {
		mine := my_guild_roles(gid);
		for r: flist(m, "mention_roles") {
			found := array_find(mine, vsnow(r));
			if found a.last_role_mention_ms = now;
		}
	}
}

// ---- Streamer Mode, app notices (app/view_streamer.jai) ----

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
		json_kbool(w, tprint("%enabled", prefix), x.enabled);
		json_kbool(w, tprint("%automatic", prefix), x.automatic);
		json_kbool(w, tprint("%disable_notifications", prefix), x.disable_notifications);
		json_kbool(w, tprint("%disable_sounds", prefix), x.disable_sounds);
		json_kbool(w, tprint("%hide_instant_invites", prefix), x.hide_instant_invites);
		json_kbool(w, tprint("%hide_personal_info", prefix), x.hide_personal_info);
		json_kbool(w, tprint("%enable_content_protection", prefix), x.enable_content_protection);
		json_kstr(w, tprint("%disabled_overlay_widgets", prefix), ""); // fastcord has no overlay
	}
	put(*w, "", n);
	put(*w, "old_", o);
	aw_track(c, "update_streamer_mode_settings", *w);
}

// analytics_app_notice: app_notice_viewed / app_notice_primary_cta_opened /
// app_notice_closed for a notice bar (notice_type "STREAMER_MODE",
// "UNVERIFIED_ACCOUNT"...); guild_id: the route's guild, 0 for none (key left out); then the
// account's trial offer, when it has one (fixture streamer_mode).
analytics_app_notice :: (c: *Client, event: string, notice_type: string, guild_id: Snowflake = 0) {
	w := aw_begin();
	json_kstr(*w, "notice_type", notice_type);
	if guild_id != 0 json_ksnow(*w, "guild_id", guild_id);
	trial := atomic_load(*c.promo.trial_id);
	if trial json_ksnow(*w, "trial_id", trial);
	aw_track(c, event, *w);
}

// ---- experiment exposures ----
// The official client tracks an exposure when a store or component reads an
// experiment (apex: experiment_*_evaluation_exposed). Only experiments READY
// assigns us are reported, with READY's evaluation id and variation (murmur3 of
// the name, the entry's second element), once per evaluation id, location and
// experiment, remembered across launches (identity.tsv): the fixtures' launches
// show them only after a login or a new evaluation. Ad, Nitro marketing and Orbs
// experiments are exposed like the rest, where their (unshown) components render.

// analytics_ready_experiments: READY's apex_experiments (unit 1 = user, 2 = installation).
analytics_ready_experiments :: (c: *Client, data: V) {
	a := *c.analytics;
	locks.lock(*a.mu);
	table_reset(*a.variations);
	for unit: fmap(fmap(vmap(data), "apex_experiments"), "assignments") {
		for e: vmap(unit.value) {
			m := vmap(e.value);
			id := fstr(m, "evaluation_id");
			if vstr(unit.key) == "2" { free(a.eval_installation,, a.allocator); a.eval_installation = copy_string(id,, a.allocator); continue; }
			free(a.eval_user,, a.allocator);
			a.eval_user = copy_string(id,, a.allocator);
			for flist(m, "assignments") {
				x := vlist(it);
				if x.count >= 2 table_set(*a.variations, cast(u32) vint(x[0]), vint(x[1]));
			}
		}
	}
	locks.unlock(*a.mu);
	legacy_ready(a, data);
	// the stores that read experiments as CONNECTION_OPEN is handled (fixture account_edits/login_submit)
	analytics_exposed(c, "app open");
	analytics_exposed(c, "app open", installation = true);
	analytics_exposed(c, "MediaEngineStore.getSettings", "2026-09-stream-zero-vad-leading");
	analytics_exposed(c, "OnlineFriendsStore", "2026-09-friends-sidebar");
	analytics_exposed(c, "FriendRequestsStore", "2026-09-friends-sidebar");
}

// the components that read experiments on the first render after READY
analytics_exposures_after_ready :: (c: *Client) {
	analytics_exposed(c, "getDcfNewUserCooldown", "2026-08-dcf-new-user-cooldown");
	analytics_exposed(c, "OverlayTextChatAutomaticLifecycleManager", "2025-11-overlay-chat");
	analytics_exposed(c, "useActiveGuildTheme", "2026-05-server-theme-user");
	analytics_exposed(c, "useDcfNewUserCooldown", "2026-08-dcf-new-user-cooldown");
	analytics_exposed(c, "AppTitleBar", "2026-09-friends-sidebar");
	analytics_exposed(c, "GuildTooltip", "2026-10-guild-tooltip-lazy-content");
	locks.lock(*c.route_mu);
	home := c.route_guild == 0 && c.route_channel == 0;
	locks.unlock(*c.route_mu);
	if home {
		analytics_exposed(c, "dm/gdm list rendered");
		analytics_exposed(c, "dm/gdm list rendered", installation = true);
		analytics_exposed(c, "useNoFillAd", "2026-08-no-fill-logging");
	}
	analytics_exposed(c, "ActivityPanelGameCard", "2026-02-join-game-community-cta");
	analytics_exposed(c, "Account", "2026-07-orbchievements");
	if home for string.["2026-10-macaron", "2026-10-macaron-non-sub-marketing", "2026-10-code-blurple", "2026-10-code-blurple-marketing-holdout", "2026-09-non-nitro-file-upload-marketing"] analytics_exposed(c, "NitroTabButton", it);
}

// analytics_exposed: experiment_user_evaluation_exposed (or the installation's)
// at location; experiment "" = the evaluation itself (no variation).
analytics_exposed :: (c: *Client, location: string, experiment := "", installation := false, delay_ms := 0) {
	a := *c.analytics;
	locks.lock(*a.mu);
	id := copy_string(ifx installation then a.eval_installation else a.eval_user,, temp);
	assigned, variation := table_find(*a.variations, murmur3_32(experiment));
	key := tprint("%|%|%", id, location, experiment);
	seen := table_contains(*a.exposed, key);
	if id && !seen && (!experiment || assigned) table_set(*a.exposed, copy_string(key,, a.allocator), true);
	locks.unlock(*a.mu);
	if !id || seen || (experiment && !assigned) return;
	w := aw_begin();
	json_kstr(*w, "evaluation_id", id);
	if experiment json_kstr(*w, "experiment", experiment);
	json_kstr(*w, "exposure_location", location);
	json_kstr(*w, "unit_type", ifx installation then "installation" else "user");
	if installation {
		locks.lock(*c.id.mu);
		inst := copy_string(c.id.installation_id,, temp);
		locks.unlock(*c.id.mu);
		json_kstr(*w, "installation_id", inst);
	}
	if experiment json_kint(*w, "tracked_variation_id", variation);
	event := ifx installation then "experiment_installation_evaluation_exposed" else "experiment_user_evaluation_exposed";
	if !delay_ms {
		aw_track(c, event, *w);
		return;
	}
	json_obj_end(*w);
	analytics_schedule(c, now_ms() + delay_ms, event, json_body(json_string(*w)));
}

// ---- legacy experiment triggers ----
// READY's legacy experiments: `experiments` (the user's: [hash, revision, bucket,
// override, population, hash_result, aa_mode, trigger_debugging, holdout_name,
// holdout_revision, holdout_bucket]) and `guild_experiments` (rollouts each guild
// is bucketed into: [hash, hash_key, revision, populations, overrides,
// overrides_formatted, holdout_name, holdout_bucket, aa_mode, trigger_debugging]).
// A read is tracked as experiment_user_triggered / experiment_guild_triggered
// (exposure "auto" or "manual"), or experiment_guild_triggered_fallback where a
// manually exposed experiment is read elsewhere; once per experiment, guild and
// location until logout, like the exposures. Only the experiments fastcord reads
// are kept.

LEGACY_PORTKEY :: "2025-08_portkey_enabled";
LEGACY_MASS_MENTION :: "2022-11_default_disable_mass_mention";
LEGACY_USER_REPORTING :: "2023-09_iar_user_reporting";
LEGACY_NAMES :: string.[LEGACY_PORTKEY, LEGACY_MASS_MENTION, LEGACY_USER_REPORTING];
LEGACY_MAX_ENTRIES :: 4096; // READY lists about 25 of each
LEGACY_MAX_POPULATIONS :: 64;
LEGACY_MAX_FILTERS :: 32;

// legacy_ready: keep READY's entries for LEGACY_NAMES, and its session id.
legacy_ready :: (a: *Analytics, data: V) {
	d := vmap(data);
	keep :: (list: []V) -> []u8 {
		if list.count > LEGACY_MAX_ENTRIES return .[];
		mine: [..]V;
		mine.allocator = temp;
		for list {
			e := vlist(it);
			if !e.count || e[0].kind != .Int continue;
			for name: LEGACY_NAMES if e[0].i == cast(s64) murmur3_32(name) array_add(*mine, it);
		}
		bytes, err := etf.encode(etf.vlist(mine));
		return ifx err == .None then bytes else .[];
	}
	user := keep(flist(d, "experiments"),, a.allocator);
	guild := keep(flist(d, "guild_experiments"),, a.allocator);
	session := copy_string(fstr(d, "session_id"),, a.allocator);
	locks.lock(*a.mu);
	free(a.legacy_user.data,, a.allocator);
	free(a.legacy_guild.data,, a.allocator);
	free(a.ready_session,, a.allocator);
	a.legacy_user, a.legacy_guild, a.ready_session = user, guild, session;
	locks.unlock(*a.mu);
}

// legacy_entry: READY's entry for experiment name (temp), empty when READY has none.
legacy_entry :: (a: *Analytics, guild: bool, name: string) -> []V {
	locks.lock(*a.mu);
	bytes := array_copy(ifx guild then a.legacy_guild else a.legacy_user,, temp);
	locks.unlock(*a.mu);
	if !bytes.count return .[];
	v, err := etf.decode(bytes,, temp);
	if err != .None return .[];
	for vlist(v) {
		e := vlist(it);
		if e.count && e[0].kind == .Int && e[0].i == cast(s64) murmur3_32(name) return e;
	}
	return .[];
}

// legacy_guild_bucket: the guild's bucket in a guild_experiments entry and the
// hash it was placed by (murmur3 of "<hash_key or name>:<guild id>" % 10000; a
// DM hashes an empty id). An override's guild list decides first, then the first
// overrides_formatted group whose population puts the hash in a range, then the
// first population whose filters pass (a hash in none of its ranges: bucket 0).
// -1 = not eligible: no population passes, a -1 range, or a malformed entry.
legacy_guild_bucket :: (c: *Client, e: []V, name: string, guild_id: Snowflake) -> bucket: s64, hash: s64 {
	if e.count < 8 || e[2].kind != .Int return -1, 0;
	if e[1].kind != .Nil && e[1].kind != .String return -1, 0;
	if e[6].kind != .Nil return -1, 0; // a holdout's rule is not captured: not tracked
	key := ifx e[1].kind == .String then e[1].s else name;
	h := cast(s64) (murmur3_32(tprint("%:%", key, ifx guild_id then tprint("%", guild_id) else "")) % 10000);
	for vlist(e[4]) {
		m := vmap(it);
		b := vget(m, "b");
		if b.kind != .Int || b.i < -1 return -1, h;
		for flist(m, "k") if guild_id && vsnow(it) == guild_id return b.i, h;
	}
	for group: vlist(e[5]) {
		passed, b := legacy_populations(c, vlist(group), h, guild_id);
		if passed && b != LEGACY_NO_RANGE return b, h;
	}
	passed, b := legacy_populations(c, vlist(e[3]), h, guild_id);
	if !passed return -1, h;
	if b == LEGACY_NO_RANGE return 0, h;
	return b, h;
}

LEGACY_NO_RANGE :: -2;

// legacy_populations: [[[bucket, [{s, e}...]]...], filters] each; the first
// whose filters all pass places the hash (s <= hash < e), else LEGACY_NO_RANGE.
legacy_populations :: (c: *Client, pops: []V, h: s64, guild_id: Snowflake) -> passed: bool, bucket: s64 {
	if pops.count > LEGACY_MAX_POPULATIONS return false, 0;
	for pops {
		p := vlist(it);
		if p.count < 2 return false, 0;
		filters := vlist(p[1]);
		if filters.count > LEGACY_MAX_FILTERS return false, 0;
		pass := true;
		for filters if !legacy_filter(c, vlist(it), guild_id) { pass = false; break; }
		if !pass continue;
		for r: vlist(p[0]) {
			rb := vlist(r);
			if rb.count < 2 || rb[0].kind != .Int || rb[0].i < -1 return false, 0;
			for vlist(rb[1]) {
				s, e := vget(vmap(it), "s"), vget(vmap(it), "e");
				if s.kind == .Int && e.kind == .Int && s.i <= h && h < e.i return true, rb[0].i;
			}
		}
		return true, LEGACY_NO_RANGE;
	}
	return false, 0;
}

// legacy_filter: [filter, [[key, value]...]], filters and keys named by murmur3
// of their names. Unknown filters fail.
legacy_filter :: (c: *Client, f: []V, guild_id: Snowflake) -> bool {
	if f.count < 2 || f[0].kind != .Int return false;
	arg :: (f: []V, key: s64) -> V {
		for vlist(f[1]) {
			kv := vlist(it);
			if kv.count == 2 && kv[0].kind == .Int && kv[0].i == key return kv[1];
		}
		return .{};
	}
	// min_id / max_id: inclusive, null = open; anything but a non-negative integer fails
	in_range :: (f: []V, x: u64) -> bool {
		lo, hi := arg(f, 3399957344), arg(f, 1238858341);
		l, lok := etf.as_u64(lo);
		u, uok := etf.as_u64(hi);
		return (lo.kind == .Nil || (lok && x >= l)) && (hi.kind == .Nil || (uok && x <= u));
	}
	g := guild_get(*c.store, guild_id);
	if f[0].i == {
		case 1604612045; // guild_has_feature {guild_features}
			if g for want: vlist(arg(f, 1183251248)) for g.features if it == vstr(want) return true;
			return false;
		case 2404720969; // guild_id_range
			return guild_id != 0 && in_range(f, guild_id);
		case 2918402255; // guild_member_count_range
			return in_range(f, cast(u64) ifx g then max(g.member_count, 0) else 0);
		case 3013771838; // guild_ids
			for vlist(arg(f, 3013771838)) if guild_id && vsnow(it) == guild_id return true;
			return false;
		case 188952590; // guild_has_vanity_url {target}: fastcord keeps no vanity codes (a new guild has none)
			t := arg(f, 188952590);
			return t.kind == .Bool && !t.b;
	}
	return false;
}

// legacy_first: true the first time key is tracked (until logout).
legacy_first :: (a: *Analytics, key: string) -> bool {
	locks.lock(*a.mu);
	defer locks.unlock(*a.mu);
	if table_contains(*a.exposed, key) return false;
	table_set(*a.exposed, copy_string(key,, a.allocator), true);
	return true;
}

// legacy_assignment: the properties every legacy trigger shares after its hash.
legacy_assignment :: (w: *Json, a: *Analytics, exposure: string) {
	locks.lock(*a.mu);
	session := copy_string(a.ready_session,, temp);
	locks.unlock(*a.mu);
	json_kbool(w, "excluded", false);
	json_kstr(w, "exposure_type", exposure);
	json_kstr(w, "assignment_source", "ready_payload");
	json_kstr(w, "assignment_session_id", session);
	json_kbool(w, "assignment_loaded_from_cache", false);
}

// analytics_guild_triggered: a read of guild experiment name for guild_id (0: a
// DM) at location. exposure "auto" / "manual" track experiment_guild_triggered,
// "auto_fallback" its _fallback.
analytics_guild_triggered :: (c: *Client, name: string, guild_id: Snowflake, location: string, exposure := "auto_fallback", delay_ms := 0) {
	a := *c.analytics;
	e := legacy_entry(a, true, name);
	if !e.count return;
	bucket, h := legacy_guild_bucket(c, e, name, guild_id);
	if bucket < 0 || !legacy_first(a, tprint("guild|%|%|%", name, guild_id, location)) return;
	w := aw_begin();
	json_kstr(*w, "name", name);
	json_kint(*w, "revision", e[2].i);
	json_kint(*w, "bucket", bucket);
	json_kstr(*w, "guild_id", ifx guild_id then tprint("%", guild_id) else "");
	aw_strs(*w, "location_stack", string.[]);
	json_kint(*w, "hash_result", h);
	legacy_assignment(*w, a, exposure);
	json_knull(*w, "holdout_name");
	json_kstr(*w, "location", location);
	event := ifx exposure == "auto_fallback" then "experiment_guild_triggered_fallback" else "experiment_guild_triggered";
	if !delay_ms {
		aw_track(c, event, *w);
		return;
	}
	json_obj_end(*w);
	analytics_schedule(c, now_ms() + delay_ms, event, json_body(json_string(*w)));
}

// analytics_user_triggered: a read of the user's experiment name at location
// (exposure "auto"), with READY's assignment.
analytics_user_triggered :: (c: *Client, name: string, location: string) {
	a := *c.analytics;
	e := legacy_entry(a, false, name);
	if e.count < 6 return;
	for 1..5 if e[it].kind != .Int return;
	if e[2].i < 0 || !legacy_first(a, tprint("user|%|%", name, location)) return;
	opt :: (w: *Json, e: []V, i: int, k: string) {
		v: V;
		if i < e.count v = e[i];
		if v.kind == .Int json_kint(w, k, v.i);
		else if v.kind == .String json_kstr(w, k, v.s);
		else json_knull(w, k);
	}
	w := aw_begin();
	json_kstr(*w, "name", name);
	json_kint(*w, "revision", e[1].i);
	json_kint(*w, "population", e[4].i);
	json_kint(*w, "bucket", e[2].i);
	aw_strs(*w, "location_stack", string.[]);
	json_kint(*w, "hash_result", e[5].i);
	legacy_assignment(*w, a, "auto");
	opt(*w, e, 8, "holdout_name");
	opt(*w, e, 9, "holdout_revision");
	opt(*w, e, 10, "holdout_bucket");
	json_kstr(*w, "location", location);
	aw_track(c, "experiment_user_triggered", *w);
}

// murmur3_32: MurmurHash3 x86 32-bit, seed 0 (the apex assignment key of an experiment name).
murmur3_32 :: (s: string) -> u32 {
	rotl :: (x: u32, r: u32) -> u32 { return (x << r) | (x >> (32 - r)); }
	C1 :: 0xcc9e2d51;
	C2 :: 0x1b873593;
	h: u32;
	n := s.count / 4 * 4;
	i := 0;
	while i < n {
		k := (cast(u32) s[i]) | ((cast(u32) s[i + 1]) << 8) | ((cast(u32) s[i + 2]) << 16) | ((cast(u32) s[i + 3]) << 24);
		k = rotl(k * C1, 15) * C2;
		h = rotl(h ^ k, 13) * 5 + 0xe6546b64;
		i += 4;
	}
	k: u32;
	for < j: n..s.count - 1 k = (k << 8) | cast(u32) s[j];
	if s.count > n h ^= rotl(k * C1, 15) * C2;
	h ^= cast(u32) s.count;
	h ^= h >> 16;
	h *= 0x85ebca6b;
	h ^= h >> 13;
	h *= 0xc2b2ae35;
	h ^= h >> 16;
	return h;
}

// ---- launch and session ----
// The official client's startup telemetry (fixture cold_start and every setup
// window). Electron, crash-reporter and web-bundle values are synthesized
// (traffic/CLIENT_RULES.md "Analytics"); timings and sizes are fastcord's own.

// analytics_launch_begin: the launch's socket was created (gateway.jai LAUNCH_*). The scripts load
// at scripts_at whatever the socket does, and the app takes the socket over at takeover_at.
analytics_launch_begin :: (c: *Client, scripts_at: s64, takeover_at: s64) {
	locks.lock(*c.analytics.mu);
	c.analytics.takeover_pending, c.analytics.launch_focused = true, true;
	locks.unlock(*c.analytics.mu);
	analytics_schedule(c, scripts_at, "@scripts", "");
	analytics_schedule(c, takeover_at, "@takeover", "");
}

// analytics_launch_identify: the launch's IDENTIFY went out, fast-connect.js's or the app's.
analytics_launch_identify :: (c: *Client, fast: bool) {
	locks.lock(*c.analytics.mu);
	c.analytics.identify_ms, c.analytics.launch_fast = now_ms(), fast;
	locks.unlock(*c.analytics.mu);
}

// analytics_launch_scripts: libdiscore has loaded and the app reads the crash
// reporter, then starts the heartbeat scheduler (fixtures: fast-connect's
// IDENTIFY -6, +15, +22 ms; the same on a socket the app identifies on).
analytics_launch_scripts :: (c: *Client) {
	a := *c.analytics;
	now := now_ms();
	locks.lock(*a.mu);
	synth_memory(*a.synth, now, false);
	s := a.synth;
	locks.unlock(*a.mu);
	w := aw_begin();
	json_kbool(*w, "success", true);
	json_key(*w, "experimental_features");
	json_raw(*w, "[]");
	aw_track(c, "libdiscore_loaded", *w);
	// app_native_crash: no crash; the memory sampler's last and highest sample
	n := aw_begin();
	json_kbool(*n, "electron_crash_reporter_did_crash", false);
	for string.["minidump_exception_type", "minidump_exception_module_name", "minidump_relative_crash_address", "minidump_exception_module_version", "minidump_exception_module_code_id", "minidump_exception_thread_name", "minidump_exception_stacktrace", "minidump_code_integrity_bytes_different", "minidump_code_integrity_bytes_compared", "minidump_code_integrity_flags", "minidump_code_integrity_reloc_bytes_different", "minidump_code_integrity_nearest_difference_from_instruction_pointer"] json_knull(*n, it);
	json_kbool(*n, "did_crash", false);
	for string.["renderer_crash_reason", "renderer_crash_exit_code", "child_process_crash_type", "child_process_crash_reason", "child_process_crash_exit_code"] json_knull(*n, it);
	for string.["had_rtc_connection", "was_sending_video", "was_sending_stream", "was_receiving_video", "was_receiving_stream"] json_kbool(*n, it, false);
	for string.["video_media_session_id", "stream_media_session_id", "intentional_crash_reason", "crashed_build_number"] json_knull(*n, it);
	json_kint(*n, "last_memory_usage_kb", synth_total(*s));
	json_kint(*n, "last_used_js_heap_size_kb", s.heap);
	json_kint(*n, "last_memory_usage_uptime", s.sampled_uptime);
	json_kint(*n, "highest_memory_usage_kb", s.high_total);
	json_kint(*n, "highest_used_js_heap_size_kb", s.high_heap);
	json_kint(*n, "highest_memory_usage_uptime", s.high_uptime);
	aw_track(c, "app_native_crash", *n);
	analytics_client_heartbeat(c);
}

// analytics_takeover: the launch's app takes the socket over (UI thread; at the latest at READY,
// which the gateway holds until then). AdSessionStore beats, the app handles a HELLO fast-connect's
// socket received, checks the pre-CONNECTION_OPEN coachmarks and renders a channel ~295 ms later
// (fixture launches: app_ui_viewed takeover +274-300 ms, before READY when READY is late; Home
// renders after READY instead).
analytics_takeover :: (c: *Client) {
	a := *c.analytics;
	now := now_ms();
	locks.lock(*a.mu);
	if !a.takeover_pending {
		locks.unlock(*a.mu);
		return;
	}
	a.takeover_pending = false;
	pending := a.pending_connected;
	a.pending_connected = "";
	start := pending && a.session_start;
	if start a.session_start = false;
	locks.unlock(*a.mu);
	locks.lock(*c.route_mu);
	home := client_route_kind(c.route_guild, c.route_channel) == .Home;
	locks.unlock(*c.route_mu);
	a.ui_at = ifx home then 0 else now + 295;
	analytics_ad_heartbeat(c, now, force = true);
	if start analytics_track(c, "session_start_client", "");
	if pending analytics_track(c, "gateway_connected", pending);
	free(pending,, a.allocator);
	analytics_before_connection_open(c);
	locks.lock(*a.mu);
	a.launch_focused = false;
	locks.unlock(*a.mu);
}

// analytics_login: a login's response carried the token. The heartbeat scheduler
// starts with the session (fixtures account_edits/login_submit).
analytics_login :: (c: *Client) {
	analytics_client_heartbeat(c);
}

// analytics_identify: GatewaySocket._doIdentify tracks session_start_client after
// every IDENTIFY the app sends: a login, a launch whose socket opened after the app
// took it over, a session the gateway invalidated. fast-connect.js's IDENTIFY and
// RESUME track nothing. Sent before HELLO it lands just before that socket's
// gateway_connected (fixtures typing, account_edits); after HELLO, at once (open_dm).
analytics_identify :: (c: *Client, after_hello: bool) {
	locks.lock(*c.analytics.mu);
	c.analytics.identify_start = now_ms(); // identifyStartTime (ready_payload_received)
	locks.unlock(*c.analytics.mu);
	if after_hello {
		analytics_track(c, "session_start_client", "");
		return;
	}
	locks.lock(*c.analytics.mu);
	c.analytics.session_start = true;
	locks.unlock(*c.analytics.mu);
}

// client_heartbeat: ClientHeartbeatScheduler, at launch, on login and every 15 min.
analytics_client_heartbeat :: (c: *Client) {
	a := *c.analytics;
	now := now_ms();
	hb := identity_heartbeat_snapshot(*c.id);
	locks.lock(*a.mu);
	synth_memory(*a.synth, now, a.rtc_state == .Rtc_Connected);
	m := a.synth;
	a.next_client_hb = now + CLIENT_HEARTBEAT_INTERVAL_MS;
	locks.unlock(*a.mu);
	idle := atomic_load(*c.idle_since); // IdleStore: 0 while active, so the "duration" is the epoch time
	w := aw_begin();
	json_kint(*w, "client_heartbeat_initialization_timestamp", ifx hb.created_at then hb.created_at else now);
	json_kint(*w, "client_heartbeat_version", 31);
	json_kint(*w, "client_heartbeat_renderer_memory", m.proc[1]);
	json_kint(*w, "client_heartbeat_renderer_memory_used_heap", m.heap);
	json_key(*w, "electron_process_memory_private");
	json_raw(*w, "[-1,-1,-1,-1,-1,-1,-1]");
	json_key(*w, "electron_process_memory_private_and_shared");
	json_raw(*w, tprint("[-1,%,%,%,-1,%,-1]", m.proc[0], m.proc[1], m.proc[2], m.proc[3]));
	json_kbool(*w, "is_idle", idle != 0);
	json_kint(*w, "idle_duration_ms", now - idle);
	json_kbool(*w, "is_afk", false);
	json_kbool(*w, "is_system_suspended", false);
	json_kbool(*w, "is_system_locked", false);
	aw_track(c, "client_heartbeat", *w);
}

// dismissible_content_shown_before_connection_open: on a private route, the DM list's Orbs and Shop
// button popovers, checked before CONNECTION_OPEN (verified accounts). 0.0.420 no longer checks the
// "For Later" coachmark (0.0.419: on every route, first).
analytics_before_connection_open :: (c: *Client) {
	locks.lock(*c.route_mu);
	g := c.route_guild;
	locks.unlock(*c.route_mu);
	if g || !c.account_verified return;
	for string.["PREMIUM_ORBS_UPSELL_POPOVER", "WISHLIST_SHOP_BUTTON_POPOVER"] {
		w := aw_begin();
		json_kstr(*w, "content_type", it);
		json_knull(*w, "group_name");
		json_knull(*w, "latest_version");
		aw_ksnow_or_null(*w, "guild_id", g);
		json_knull(*w, "snowflake_id");
		aw_track(c, "dismissible_content_shown_before_connection_open", *w);
	}
}

// ready_payload_received: READY's sizes and timings. Wire sizes and the unpack
// time are the gateway reader's (Analytics.ready_frame; READY's ETF size when
// injected), server timings come from READY's _trace, section sizes are their
// JSON lengths. The identify timings repeat the official arithmetic, which mixes
// performance.now() (our launch standing for the page load) with Date.now().
analytics_ready_payload :: (c: *Client, data: V, is_reconnect: bool) {
	a := *c.analytics;
	now := now_ms();
	d := vmap(data);
	locks.lock(*a.mu);
	f := a.ready_frame;
	a.ready_frame = .{};
	a.ready_unpack_ms = f.unpack_ms;
	fast := a.identify_ms != 0 && a.launch_fast; // the launch's fast-connect IDENTIFY
	start := a.identify_start;
	a.identify_ms, a.launch_fast, a.identify_start = 0, false, 0;
	ident_bytes := cast(s64) synth_between(*a.synth, 1020, 1110);
	lag := cast(s64) synth_between(*a.synth, cast(float64) ifx fast then 15 else 55, cast(float64) ifx fast then 50 else 90);
	locks.unlock(*a.mu);
	// a channel route's READY handlers render the channel first: ~105 ms more (0.0.420 fixtures: READY -
	// socket creation - the sum is 554-668 ms on channel routes, 386-460 at Home)
	locks.lock(*c.route_mu);
	if c.route_channel lag += 105;
	locks.unlock(*c.route_mu);
	if f.raw == 0 {
		bytes, err := etf.encode(data,, temp);
		if err == .None f.raw = bytes.count + 1;
		f.wire = f.raw * 33 / 100; // the fixtures' zstd-stream ratio
	}
	jlen :: (v: V) -> int {
		sb: String_Builder;
		sb.allocator = temp;
		etf.to_json(v, *sb);
		return builder_string_length(*sb);
	}
	// _trace: JSON strings of ["gateway-...", {micros, calls: [name, {micros, calls}, ...]}]
	find :: (calls: []V, name: string) -> int {
		for i: 0..calls.count - 2 {
			if calls[i].kind == .String && calls[i].s == name return fint(vmap(calls[i + 1]), "micros");
			if calls[i + 1].kind == .Map {
				r := find(flist(vmap(calls[i + 1]), "calls"), name);
				if r >= 0 return r;
			}
		}
		return -1;
	}
	total, api, guilds := 0, -1, -1;
	for flist(d, "_trace") {
		t, err := etf.from_json(vstr(it),, temp);
		if err != .None || t.kind != .List || t.list.count < 2 continue;
		if total == 0 total = fint(vmap(t.list[1]), "micros");
		if api < 0 api = find(t.list, "start_session");
		if guilds < 0 guilds = find(t.list, "guilds_connect");
	}
	TOP :: string.["presences", "users", "read_state", "private_channels", "user_settings_proto", "experiments", "user_guild_settings", "relationships"];
	TOP_NAMES :: string.["presences_size", "users_size", "read_states_size", "private_channels_size", "user_settings_size", "experiments_size", "user_guild_settings_size", "relationships_size"];
	GUILD :: string.["channels", "members", "presences", "roles", "emojis", "threads", "stickers", "guild_scheduled_events", "features"];
	GUILD_NAMES :: string.["guild_channels_size", "guild_members_size", "guild_presences_size", "guild_roles_size", "guild_emojis_size", "guild_threads_size", "guild_stickers_size", "guild_events_size", "guild_features_size"];
	top: [TOP.count]int;
	for TOP top[it_index] = jlen(vget(d, it));
	top[5] += jlen(vget(d, "guild_experiments"));
	gs: [GUILD.count]int;
	guilds_len, channels, categories := 0, 0, 0;
	for g: flist(d, "guilds") {
		gm := vmap(g);
		guilds_len += jlen(g);
		for GUILD gs[it_index] += jlen(vget(gm, it));
		for flist(gm, "channels") {
			channels += 1;
			if fint(vmap(it), "type") == 4 categories += 1;
		}
	}
	rest, grest := jlen(data) - guilds_len, guilds_len;
	for top rest -= it;
	for gs grest -= it;
	conn := ifx c.gw then c.gw.attempt_start else 0;
	if conn == 0 conn = now - 1000;
	if fast start = conn; // _doFastConnectIdentify at the takeover, right after _connect
	if !start start = conn + 160; // sent on HELLO
	frac := 0.1 * cast(float64) (mono_ms() % 10);
	o := cast(float64) (now - c.launch_ms) + frac; // performance.now() as READY's dispatch starts
	w := aw_begin();
	json_kint(*w, "compressed_byte_size", f.wire);
	json_kint(*w, "uncompressed_byte_size", f.raw);
	json_kstr(*w, "compression_algorithm", "zstd-stream");
	json_kstr(*w, "packing_algorithm", "etf");
	json_kint(*w, "unpack_duration_ms", f.unpack_ms);
	json_kint(*w, "identify_total_server_duration_ms", total / 1000);
	json_kint(*w, "identify_api_duration_ms", max(api, 0) / 1000);
	json_kint(*w, "identify_guilds_duration_ms", max(guilds, 0) / 1000);
	json_kint(*w, "num_guilds", flist(d, "guilds").count);
	json_kint(*w, "num_guild_channels", channels);
	json_kint(*w, "num_guild_category_channels", categories);
	for TOP_NAMES json_kint(*w, it, top[it_index]);
	json_kint(*w, "remaining_data_size", max(rest, 0));
	for GUILD_NAMES json_kint(*w, it, gs[it_index]);
	json_kint(*w, "guild_remaining_data_size", max(grest, 0));
	json_kint(*w, "size_metrics_duration_ms", now_ms() - now);
	// The official mix: o - identifyStartTime, o - connectionStartTime (Date.now()), Date.now() - o after
	// the READY handlers. Their sum (READY handled - identify start) runs `lag` short of this event's
	// track time against the identify's (fixtures: 57-87 ms after session_start_client, 8-92 after a
	// fast launch's takeover).
	aw_kf64(*w, "duration_ms_since_identify_start", o - cast(float64) start);
	aw_kf64(*w, "duration_ms_since_connection_start", o - cast(float64) conn);
	aw_kf64(*w, "duration_ms_since_emit_start", cast(float64) (now_ms() - lag) - o);
	json_kbool(*w, "is_reconnect", is_reconnect);
	json_kbool(*w, "is_fast_connect", fast);
	json_kbool(*w, "did_force_clear_guild_hashes", false);
	// the fast-connect IDENTIFY is sent before the app loads: no sizes; otherwise its JSON and packed sizes
	json_kint(*w, "identify_uncompressed_byte_size", ifx fast then 0 else ident_bytes);
	json_kint(*w, "identify_compressed_byte_size", ifx fast then 0 else ident_bytes * 63 / 100);
	json_kbool(*w, "had_cache_at_startup", false);
	json_kbool(*w, "used_cache_at_startup", false);
	aw_track(c, "ready_payload_received", *w);
}

// app_ui_viewed (ui): the app's first render (analytics_takeover, client_after_dispatch READY);
// app_web_perf_startup_metrics ("tti", perf): READY +60 ms (fixtures). The web
// bundle's sizes and script costs are synthesized from build 649389's fixtures
// (web.057e7776e1c6251b.js...); duration_ms_since_app_opened is our launch to now.
analytics_first_render :: (c: *Client, guild_id: Snowflake, channel_id: Snowflake, ui: bool, perf: bool) {
	a := *c.analytics;
	locks.lock(*a.mu);
	j := synth_between(*a.synth, 0.97, 1.03);
	render := cast(s64) synth_between(*a.synth, 650, 1250);
	evals := cast(s64) synth_between(*a.synth, 75, 95);
	unpack := a.ready_unpack_ms;
	locks.unlock(*a.mu);
	home := guild_id == 0 && channel_id == 0;
	if !a.load_id a.load_id = copy_string(analytics_load_id(),, a.allocator);
	load_id := a.load_id;
	if ui {
		w := aw_begin();
		json_kint(*w, "total_compressed_byte_size", cast(s64) (5_170_000 * j));
		json_kint(*w, "total_uncompressed_byte_size", cast(s64) (19_130_000 * j));
		json_kint(*w, "total_transfer_byte_size", 0);
		json_kint(*w, "js_compressed_byte_size", ifx home then 760625 else 701207);
		json_kint(*w, "js_uncompressed_byte_size", ifx home then 2348196 else 2033590);
		json_kint(*w, "js_transfer_byte_size", 0);
		json_kint(*w, "css_compressed_byte_size", ifx home then 27091 else 42125);
		json_kint(*w, "css_uncompressed_byte_size", ifx home then 87044 else 251265);
		json_kint(*w, "css_transfer_byte_size", 0);
		json_kstr(*w, "load_id", load_id);
		json_kstr(*w, "screen_name", ifx home then "friends" else ifx guild_id then "guild_channel" else "private_channel");
		json_kint(*w, "duration_ms_since_app_opened", now_ms() - c.launch_ms);
		json_kbool(*w, "app_hardware_acceleration_enabled", true);
		aw_track(c, "app_ui_viewed", *w);
	}
	if !perf return;
	p := aw_begin();
	json_kstr(*p, "load_id", load_id);
	json_kstr(*p, "metric_name", "tti");
	json_kstr(*p, "url_root_path", ifx guild_id || channel_id then "channels" else "channels/@me");
	json_kstr(*p, "ready_packing_algorithm", "etf");
	json_kint(*p, "ready_unpack_duration_ms", unpack);
	json_kbool(*p, "was_authenticated", true);
	json_kint(*p, "time_first_render_after_ready_end", render);
	json_kbool(*p, "script_cost_loaf_supported", true);
	json_kint(*p, "script_cost_unattributed_eval_ms", 0);
	json_kint(*p, "script_cost_total_count", ifx home then 437 else 1120);
	n := ifx home then 3 else 4;
	json_kint(*p, "script_cost_reported_count", n);
	nums :: (w: *Json, k: string, v: []s64) { json_key(w, k); json_arr(w); for v json_int(w, it); json_arr_end(w); }
	bools :: (w: *Json, k: string, v: []bool) { json_key(w, k); json_arr(w); for v json_bool(w, it); json_arr_end(w); }
	aw_strs(*p, "script_cost_url", array_view(string.["/assets/web.057e7776e1c6251b.js", "/assets/556707.bb1a25f3c212ce8f.js", "/assets/b3931ca213b9d0ec.js", "/assets/f1f07381693dcba1.js"], 0, n));
	nums(*p, "script_cost_download_ms", array_view(s64.[evals * 2 + 20, 0, 0, 0], 0, n));
	nums(*p, "script_cost_transfer_size_bytes", array_view(s64.[0, 0, 0, 0], 0, n));
	bools(*p, "script_cost_from_cache", array_view(bool.[true, false, true, true], 0, n));
	nums(*p, "script_cost_initial_eval_ms", array_view(s64.[0, 0, evals / 2, evals * 4 / 9], 0, n));
	nums(*p, "script_cost_total_eval_ms", array_view(s64.[evals, evals * 2 + 25, evals / 2, evals * 4 / 9], 0, n));
	bools(*p, "script_cost_eval_attributed", array_view(bool.[true, true, true, true], 0, n));
	aw_track(c, "app_web_perf_startup_metrics", *p);
}

