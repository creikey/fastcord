// User Settings pages kept in the synced settings proto (Language & Time, Developer, Messaging
// Permissions) and the ones that load from REST (Logged-in Devices, Connected Apps). Each edit
// goes through dc.set_* (settings_put: the whole category, as the client's updateAsync).

// The client's enabled languages (getAvailableLocales: code, native name, English name), in its order.
LANGUAGES :: [3]string.[
	.["en-US", "English, US", "English, US"], .["en-GB", "English, UK", "English, UK"],
	.["zh-CN", "中文", "Chinese Simplified"], .["zh-TW", "繁體中文", "Traditional Chinese"],
	.["cs", "Čeština", "Czech"], .["da", "Dansk", "Danish"], .["nl", "Nederlands", "Dutch"],
	.["fr", "Français", "French"], .["de", "Deutsch", "German"], .["el", "Ελληνικά", "Greek"],
	.["hu", "Magyar", "Hungarian"], .["it", "Italiano", "Italian"], .["ja", "日本語", "Japanese"],
	.["ko", "한국어", "Korean"], .["pl", "Polski", "Polish"], .["pt-BR", "Português do Brasil", "Portuguese, Brazilian"],
	.["ru", "Русский", "Russian"], .["es-419", "Español, LATAM", "Spanish, LATAM"], .["es-ES", "Español", "Spanish"],
	.["sv-SE", "Svenska", "Swedish"], .["tr", "Türkçe", "Turkish"], .["bg", "български", "Bulgarian"],
	.["uk", "Українська", "Ukrainian"], .["fi", "Suomi", "Finnish"], .["no", "Norsk", "Norwegian"],
	.["hr", "Hrvatski", "Croatian"], .["ro", "Română", "Romanian"], .["lt", "Lietuviškai", "Lithuanian"],
	.["th", "ไทย", "Thai"], .["vi", "Tiếng Việt", "Vietnamese"], .["hi", "हिंदी", "Hindi"]
];

// Language & Time (LANGUAGE_AND_TIME_CATEGORY): Select a Language, then Time format.
language_page :: () {
	if !set_page_begin("langpage") return;
	defer set_page_end();
	s := store();
	set_heading("Language");
	label("Select a Language", .Medium, 16, T("--text-strong"), 20);
	spacer(.Y, 4);
	set_para("langhelp", "Choose the language you want Discord to display. fastcord itself is in English for now.", .Normal, 14, 18, T("--text-muted"));
	spacer(.Y, 12);
	names := NewArray(LANGUAGES.count, string,, temp); // read again by dropdown_list after the page
	cur := 0; // en-US when unset
	for LANGUAGES {
		names[it_index] = ifx it[1] == it[2] then it[1] else tprint("%  ·  %", it[1], it[2]);
		if it[0] == s.settings.locale cur = it_index;
	}
	pick := select_field("lang", names, cur);
	if pick >= 0 && pick != cur {
		if net_action() dc.set_locale(app.client, LANGUAGES[pick][0]);
		else s.settings.locale = LANGUAGES[pick][0]; // offline (fixture) runs: a static string
	}
	spacer(.Y, 40);
	set_heading("Time format");
	FORMATS :: string.["Auto", "12-hour", "24-hour"];
	h := select_field("hourcycle", FORMATS, cast(int) s.settings.hour_cycle);
	if h >= 0 && h != cast(int) s.settings.hour_cycle {
		if net_action() dc.set_hour_cycle(app.client, cast(dc.Hour_Cycle) h);
		else s.settings.hour_cycle = cast(dc.Hour_Cycle) h;
	}
	spacer(.Y, 8);
	set_para("timehelp", tprint("Times show as %.", clock_text(utc_calendar(local_ms(wall_ms())))), .Normal, 14, 18, T("--text-muted"));
}

// Developer (DEVELOPER_PANEL): Developer Mode (AppearanceSettings.developer_mode).
developer_page :: () {
	if !set_page_begin("devpage") return;
	defer set_page_end();
	s := store();
	set_heading("Developer");
	on := s.settings.developer_mode;
	if set_toggle_row("devmode", "Developer Mode", "Developer Mode exposes context menu items helpful for people writing apps using the Discord API.", on) {
		if net_action() dc.set_developer_mode(app.client, !on);
		else s.settings.developer_mode = !on;
	}
}

// proto_put: a settings-proto edit from a page (offline runs change only the local copy).
proto_put :: (cat: u32, num: u32, encoded: []u8, sub: u32 = 0) {
	if net_action() dc.settings_put(app.client, cat, num, encoded, sub);
	else dc.settings_proto_edit(store(), cat, num, encoded, sub);
}

// Messaging Permissions (MESSAGING_PERMISSIONS_PANEL, the old Privacy & Safety): Content Filters,
// Spam Filters, DM permissions and Friend Request Permissions, all in the settings proto
// (text_and_images is category 6, privacy 8).
messaging_page :: () {
	if !set_page_begin("msgpage") return;
	defer set_page_end();
	s := store();
	set_heading("Content Filters");
	set_para("cfhelp", "Choose what happens to images and videos Discord detects as explicit.", .Normal, 14, 18, T("--text-muted"));
	spacer(.Y, 16);
	FILTER :: string.["Show", "Blur", "Block"];
	PLACES :: string.["Messages in servers", "Direct messages from friends", "Direct messages from others"];
	for PLACES {
		k := cast(u32) it_index + 1;
		v, set := dc.settings_value(s, 6, 29, k); // explicit_content_settings: 1 guilds, 2 friend DMs, 3 other DMs
		// unset: blur everywhere without NSFW access, else block other DMs (as analytics_events.jai reads it)
		cur := ifx set && v >= 1 && v <= 3 then cast(int) v - 1 else ifx s.settings.nsfw_blocked then 1 else ifx k == 3 then 2 else 0;
		label(it, .Medium, 16, T("--text-strong"), 20);
		spacer(.Y, 8);
		pick := select_field(tprint("explicit%", k), FILTER, cur);
		if pick >= 0 && pick != cur proto_put(6, 29, dc.pb_field_uint(k, xx (pick + 1)), sub = k);
		spacer(.Y, 16);
	}
	spacer(.Y, 24);
	set_heading("Spam Filters");
	label("Automatically filter suspected spam messages", .Medium, 16, T("--text-strong"), 20);
	spacer(.Y, 4);
	set_para("spamhelp", "Discord can filter out some messages that contain spam. These messages go to your Spam inbox.", .Normal, 14, 18, T("--text-muted"));
	spacer(.Y, 8);
	SPAM :: string.["Filter direct messages from everyone", "Filter direct messages from non-friends", "Do not filter direct messages"];
	SPAM_V :: u64.[3, 2, 1]; // DmSpamFilterV2: FRIENDS_AND_NON_FRIENDS, NON_FRIENDS, DISABLED
	sv, sset := dc.settings_value(s, 6, 27);
	if !sset || sv == 0 sv = cast(u64) ifx s.settings.nsfw_blocked then 3 else 2; // DEFAULT_UNSET
	scur := 1;
	for SPAM_V if it == sv scur = it_index;
	spick := select_field("spam", SPAM, scur);
	if spick >= 0 && spick != scur proto_put(6, 27, dc.pb_field_uint(27, SPAM_V[spick]));
	spacer(.Y, 40);
	set_heading("Direct Message (DM) Permissions");
	restricted, _ := dc.settings_value(s, 8, 4); // default_guilds_restricted
	if set_toggle_row("guilddms", "Allow DMs from other members in servers", "This setting is applied when you join a new server. It does not apply retroactively to your existing servers.", restricted == 0) {
		proto_put(8, 4, dc.pb_field_uint(4, xx (restricted == 0)));
	}
	set_divider();
	mr, _ := dc.settings_value(s, 8, 17, 1); // default_message_request_restricted (BoolValue)
	if set_toggle_row("msgreq", "Allow message requests from server members you may not know", "Messages from people you may not know go to Message Requests instead of your DMs.", mr == 0) {
		proto_put(8, 17, dc.pb_field_bool_value(17, mr == 0));
	}
	spacer(.Y, 40);
	set_heading("Friend Request Permissions");
	label("Allow Friend Requests from...", .Semibold, 12, T("--text-muted"), 16);
	spacer(.Y, 12);
	MUTUAL_FRIENDS :: cast(u64) 2; MUTUAL_GUILDS :: cast(u64) 4; NO_RELATION :: cast(u64) 8; ALL :: cast(u64) 14;
	flags, fset := dc.settings_value(s, 8, 11, 1); // friend_source_flags (UInt32Value); unset: everyone
	if !fset flags = ALL;
	everyone := (flags & NO_RELATION) != 0;
	put_flags :: (f: u64) { proto_put(8, 11, dc.pb_field_msg(11, dc.pb_field_uint(1, f))); }
	if set_toggle_row("frall", "Everyone", "", everyone) put_flags(ifx everyone then ALL & ~NO_RELATION else ALL);
	set_divider();
	mf := everyone || (flags & MUTUAL_FRIENDS) != 0;
	if set_toggle_row("frmf", "Friends of friends", "", mf) put_flags(ifx mf then flags & ~(MUTUAL_FRIENDS | NO_RELATION) else flags | MUTUAL_FRIENDS);
	set_divider();
	mg := everyone || (flags & MUTUAL_GUILDS) != 0;
	if set_toggle_row("frmg", "Server members", "Server members can only send you friend requests from servers where you also allow Direct Messages.", mg) {
		put_flags(ifx mg then flags & ~(MUTUAL_GUILDS | NO_RELATION) else flags | MUTUAL_GUILDS);
	}
}

// The server header menu's Privacy Settings: DMs and message requests from that server's members
// (privacy.restricted_guild_ids 8.3 and message_request_restricted_guild_ids 8.16, guild ids).
guild_privacy: dc.Snowflake; // the open modal's server (0: closed)

guild_privacy_modal :: () {
	if !guild_privacy return;
	s := store();
	g := dc.guild_get(s, guild_privacy);
	W :: 440;
	if !g || !adm_modal_begin("gprivacy", W, "Privacy Settings", g.name) {
		guild_privacy = 0;
		return;
	}
	body := row("body");
	body.semantic_size = .[ui.pct(1), ui.children()];
	{ ui.parent(body); defer ui.pop_parent();
		spacer(.X, 25);
		col := ui.box("col");
		col.semantic_size = .[ui.fill(), ui.children()];
		col.layout_axis = .Y;
		{ ui.parent(col); defer ui.pop_parent();
			spacer(.Y, 16);
			for field: u32.[3, 16] {
				ids := dc.settings_ids(s, 8, field);
				on := !array_find(ids, cast(u64) guild_privacy);
				title := ifx field == 3 then "Direct Messages" else "Message Requests";
				help := ifx field == 3 then "Allow direct messages from other members in this server." else "Messages from members you may not know go to Message Requests.";
				if set_toggle_row(tprint("f%", field), title, help, on) {
					list: [..]u64;
					list.allocator = temp;
					for ids if it != guild_privacy array_add(*list, it);
					if on array_add(*list, guild_privacy);
					proto_put(8, field, dc.pb_field_ids(field, list));
				}
				spacer(.Y, 16);
			}
		}
		spacer(.X, 25);
	}
	btns := row("btns");
	btns.semantic_size = .[ui.pct(1), ui.px(40)];
	{ ui.parent(btns); defer ui.pop_parent();
		filler(.X);
		if wide_button("done", "Done", .Primary) guild_privacy = 0;
		spacer(.X, 25);
	}
	spacer(.Y, 24);
	adm_modal_end();
	if adm_escape() guild_privacy = 0;
}

// ---- Pages that load from REST: Logged-in Devices, Connected Apps ----

US_Req :: enum u8 {
	Sessions; // GET /auth/sessions
	Connections; // GET /users/@me/connections
	Tokens; // GET /oauth2/tokens (Authorized Apps)
	Consent; // GET /users/@me/consent (Data & Privacy)
	COUNT;
	Action :: 100; // a change, then `us.after` reloads
	Authorize; // GET /connections/{type}/authorize: the page to finish in the browser
}

#scope_file
us: struct {
	replies: [US_Req.COUNT]dc.Feature_Result;
	loading: [US_Req.COUNT]bool;
	page: string; // the page whose loads went out (static)
	busy: bool;
	after: US_Req;
	error: string; // heap
};

US_PATHS :: string.["/auth/sessions", "/users/@me/connections", "/oauth2/tokens", "/users/@me/consent"];

us_load :: (req: US_Req) {
	if us.loading[req] || !net_action() return;
	us.loading[req] = true;
	dc.user_settings_call(app.client, xx req, "GET", US_PATHS[req]);
}

// us_enter: the page's first frame since it was opened loads what it shows.
us_enter :: (page: string, reqs: ..US_Req) {
	if us.page == page return;
	us.page = page;
	us_set_error("");
	for reqs {
		us.loading[it] = false;
		us_load(it);
	}
}

us_action :: (after: US_Req, method: string, path: string, body := "") {
	if us.busy || !net_action() return;
	us.busy, us.after = true, after;
	us_set_error("");
	dc.user_settings_call(app.client, xx US_Req.Action, method, path, body);
}

us_reply :: (req: US_Req) -> dc.V, bool {
	r := *us.replies[req];
	return r.body, r.arena != null && r.ok;
}

us_set_error :: (s: string) {
	free(us.error);
	us.error = copy_string(s);
}

// "Loading..." or the load's error, when the reply isn't there; false then.
us_ready :: (req: US_Req) -> bool {
	_, ok := us_reply(req);
	if ok return true;
	r := *us.replies[req];
	set_para("loading", ifx us.loading[req] || !r.arena then "Loading..." else us_result_error(r), .Normal, 14, 18, T("--text-muted"));
	return false;
}

us_result_error :: (r: *dc.Feature_Result) -> string {
	if r.status == 0 return "Couldn't reach Discord. Check your connection and try again.";
	e := dc.api_error_text(r.body);
	return ifx e then e else tprint("Something went wrong (HTTP %).", r.status);
}

us_error_line :: () {
	if !us.error return;
	spacer(.Y, 8);
	set_para("userr", us.error, .Normal, 14, 18, T("--text-feedback-critical"));
}
#scope_export

user_settings_receive :: (r: *dc.Feature_Result) {
	app.ui.animating = true;
	req := cast(US_Req) r.tag;
	if req < .COUNT {
		us.loading[req] = false;
		dc.feature_result_free(*us.replies[req]);
		us.replies[req] = r.*;
		r.arena = null; // ours now
		return;
	}
	us.busy = false;
	if !r.ok {
		us_set_error(us_result_error(r));
		return;
	}
	if req == .Authorize {
		url := dc.fstr(dc.vmap(r.body), "url");
		if begins_with(url, "https://") open_url(url); // no webview: the platform's sign-in opens in the browser
		us.page = ""; // coming back to the page shows the new account
		return;
	}
	us.loading[us.after] = false;
	us_load(us.after);
}

// user_settings_left: the settings modal closed; the next open loads again.
user_settings_left :: () { us.page = ""; }

// Logged-in Devices (SESSIONS_PANEL): this login first, the others by last use, each with Log Out.
devices_page :: () {
	us_enter("Devices", .Sessions);
	if !set_page_begin("devicespage") return;
	defer set_page_end();
	s := store();
	set_heading("Logged-in Devices");
	set_para("devhelp", "These are all the devices that are currently logged-in with your Discord account. Log out of devices that you don't recognize.", .Normal, 14, 18, T("--text-muted"));
	spacer(.Y, 24);
	if !us_ready(.Sessions) return;
	body := us_reply(.Sessions);
	list := dc.flist(dc.vmap(body), "user_sessions");
	cur := -1;
	Dev :: struct { i: int; used: s64; }
	others: [..]Dev;
	others.allocator = temp;
	for list {
		if s.auth_session_hash && dc.fstr(dc.vmap(it), "id_hash") == s.auth_session_hash cur = it_index;
		else array_add(*others, .{it_index, dc.iso_to_ms(dc.fstr(dc.vmap(it), "approx_last_used_time"))});
	}
	quick_sort(others, (a: Dev, b: Dev) -> s64 { return b.used - a.used; });
	if cur >= 0 {
		label("Current Device", .Semibold, 16, T("--text-muted"), 20);
		spacer(.Y, 16);
		device_row(list[cur], cur, true);
		spacer(.Y, 24);
	}
	if others.count || !dc.account.mfa_enabled {
		label("Other Devices", .Semibold, 16, T("--text-muted"), 20);
		spacer(.Y, 16);
		for others device_row(list[it.i], it.i, false);
		if !dc.account.mfa_enabled {
			r := row("older");
			r.semantic_size = .[ui.pct(1), ui.px(44)];
			ui.parent(r); defer ui.pop_parent();
			icon("i", "warning", 24, T("--icon-muted"));
			spacer(.X, 12);
			col := ui.box("col");
			col.semantic_size = .[ui.fill(), ui.children()];
			col.layout_axis = .Y;
			ui.parent(col); defer ui.pop_parent();
			label("Some older devices may not be shown here", .Semibold, 16, T("--text-muted"), 20);
			label("To log them out, please change your password", .Normal, 14, T("--text-muted"), 18);
		}
		spacer(.Y, 24);
	}
	us_error_line();
	if others.count {
		set_divider();
		r := row("logoutall");
		r.semantic_size = .[ui.pct(1), ui.children()];
		ui.parent(r); defer ui.pop_parent();
		col := ui.box("col");
		col.semantic_size = .[ui.fill(), ui.children()];
		col.layout_axis = .Y;
		{ ui.parent(col); defer ui.pop_parent();
			label("Log out of all known devices", .Medium, 16, T("--text-strong"), 20);
			spacer(.Y, 4);
			set_para("allhelp", "You'll have to log back in on all logged out devices.", .Normal, 14, 18, T("--text-muted"));
		}
		spacer(.X, 16);
		if set_button("Log Out All Known Devices##all", .Danger, !us.busy, 32) {
			hashes: [..]string;
			hashes.allocator = temp;
			for others array_add(*hashes, dc.json_quote(dc.fstr(dc.vmap(list[it.i]), "id_hash")));
			us_action(.Sessions, "POST", "/auth/sessions/logout", tprint("{\"session_id_hashes\":[%]}", join(..hashes, separator = ",",, temp)));
		}
	}
}

#scope_file
// One device: OS • platform over "location · last used", and Log Out of Device for the others.
device_row :: (v: dc.V, index: int, current: bool) {
	m := dc.vmap(v);
	ci := dc.fmap(m, "client_info");
	os := dc.fstr(ci, "os");
	plat := dc.fstr(ci, "platform");
	loc := dc.fstr(ci, "location");
	if !loc loc = dc.fstr(ci, "ip");
	hash := dc.fstr(m, "id_hash");
	ui.id_scope(cast(u64) index + 1);
	defer ui.pop_seed();
	r := row("dev");
	r.semantic_size = .[ui.pct(1), ui.px(44)];
	{ ui.parent(r); defer ui.pop_parent();
		low := to_lower_copy(trim(os),, temp);
		icon("i", ifx low == "ios" || low == "android" then "phone" else "screen", 24, T("--icon-default"));
		spacer(.X, 12);
		col := ui.box("col");
		col.semantic_size = .[ui.fill(), ui.children()];
		col.layout_axis = .Y;
		{ ui.parent(col); defer ui.pop_parent();
			head := ifx os then os else "Unknown";
			if plat head = tprint("%  •  %", head, plat);
			label(head, .Semibold, 16, T("--text-strong"), 20);
			parts: [..]string;
			parts.allocator = temp;
			if loc array_add(*parts, loc);
			if !current {
				used := dc.iso_to_ms(dc.fstr(m, "approx_last_used_time"));
				array_add(*parts, ifx wall_ms() - used < 3_600_000 then "less than an hour ago" else relative_time((used - wall_ms()) / 1000));
			}
			label(join(..parts, separator = " · ",, temp), .Normal, 14, T("--text-muted"), 18);
		}
		if !current {
			x := ui.box("logout", .Clickable);
			x.semantic_size = .[ui.px(24), ui.px(24)];
			x.hover_cursor = .Pointer;
			xs := ui.signal(x);
			set_icon(x, "x-large", ifx xs.hovering then T("--interactive-icon-hover") else T("--interactive-icon-default"));
			if xs.clicked us_action(.Sessions, "POST", "/auth/sessions/logout", tprint("{\"session_id_hashes\":[%]}", dc.json_quote(hash)));
		}
	}
	spacer(.Y, 16);
}
#scope_export

// chat_pref: a TextAndImages BoolValue (category 6), true while unset (the client's defaults).
chat_pref :: (field: u32) -> bool {
	_, has := dc.settings_value(store(), 6, field);
	v, set := dc.settings_value(store(), 6, field, 1);
	return !has || (set && v != 0);
}

// spoilers_always: TextAndImages.render_spoilers (6.4, a StringValue) is "ALWAYS".
spoilers_always :: () -> bool {
	f, ok := dc.settings_bytes(store(), 6, 4, 1);
	return ok && cast(string) f == "ALWAYS";
}

// Chat: what messages show, synced (text_and_images).
chat_page :: () {
	if !set_page_begin("chatpage") return;
	defer set_page_end();
	set_heading("Display Images, Videos and Lolcats");
	toggle :: (id: string, field: u32, title: string) {
		on := chat_pref(field);
		if set_toggle_row(id, title, "", on) proto_put(6, field, dc.pb_field_bool_value(field, !on));
		set_divider();
	}
	toggle("embeds", 12, "Show embeds and preview website links pasted into chat");
	toggle("reactions", 13, "Show emoji reactions on messages");
	spacer(.Y, 24);
	set_heading("Spoiler Content");
	SPOILERS :: string.["On click", "On servers I moderate", "Always"];
	SPOILER_V :: string.["ON_CLICK", "IF_MODERATOR", "ALWAYS"];
	f, ok := dc.settings_bytes(store(), 6, 4, 1);
	cur := 0;
	if ok for SPOILER_V if it == cast(string) f cur = it_index;
	label("Show spoiler content", .Medium, 16, T("--text-strong"), 20);
	spacer(.Y, 8);
	pick := select_field("spoilers", SPOILERS, cur);
	if pick >= 0 && pick != cur proto_put(6, 4, dc.pb_field_string_value(4, SPOILER_V[pick]));
}

// Data & Privacy (DATA_AND_PRIVACY_PANEL): Use data to improve Discord (a consent on the account) and
// Profile Privacy (privacy.profile_visibility, 8.32).
data_privacy_page :: () {
	us_enter("Data & Privacy", .Consent);
	if !set_page_begin("datapage") return;
	defer set_page_end();
	s := store();
	set_heading("How Discord Uses My Data");
	if us_ready(.Consent) {
		on := dc.fbool(dc.fmap(dc.vmap(us_reply(.Consent)), "usage_statistics"), "consented");
		if set_toggle_row("usage", "Use data to improve Discord", "Allow Discord to use and process my information to understand and improve Discord's services.", on, us.busy) {
			us_action(.Consent, "POST", "/users/@me/consent", ifx on then "{\"grant\":[],\"revoke\":[\"usage_statistics\"]}" else "{\"grant\":[\"usage_statistics\"],\"revoke\":[]}");
		}
	}
	us_error_line();
	spacer(.Y, 40);
	set_heading("Profile Privacy");
	set_para("pphelp", "Control who can see your profile info, like your bio and connected accounts.", .Normal, 14, 18, T("--text-muted"));
	spacer(.Y, 12);
	label("Share my full profile with", .Medium, 16, T("--text-strong"), 20);
	spacer(.Y, 8);
	VIS :: string.["Friends & All Servers", "Friends & Small Servers Only", "Friends Only"];
	VIS_V :: u64.[3, 2, 1]; // ProfileVisibility: FRIENDS_AND_ALL_GUILDS, FRIENDS_AND_SMALL_GUILDS, FRIENDS_ONLY
	HELP :: string.["Your full profile is visible to friends and any server you join.", "Your full profile is visible to friends and any server you join with 200 or fewer members. Everyone else sees a limited version.", "Your full profile is visible to friends. Everyone else sees a limited version."];
	v, _ := dc.settings_value(s, 8, 32);
	cur := 0; // unset: all servers
	for VIS_V if it == v cur = it_index;
	pick := select_field("profilevis", VIS, cur);
	if pick >= 0 && pick != cur proto_put(8, 32, dc.pb_field_uint(32, VIS_V[pick]));
	spacer(.Y, 8);
	set_para("vishelp", HELP[cur], .Normal, 14, 18, T("--text-muted"));
}

// The platforms the client connects with an OAuth page (type, name); those needing a handle or a DNS
// record (Bluesky, Mastodon, Domain) are left out.
CONNECT_PLATFORMS :: [2]string.[
	.["battlenet", "Battle.net"], .["bungie", "Bungie.net"], .["crunchyroll", "Crunchyroll"], .["ebay", "eBay"],
	.["epicgames", "Epic Games"], .["github", "GitHub"], .["leagueoflegends", "League of Legends"], .["paypal", "PayPal"],
	.["playstation", "PlayStation Network"], .["reddit", "Reddit"], .["riotgames", "Riot Games"], .["roblox", "Roblox"],
	.["spotify", "Spotify"], .["steam", "Steam"], .["tiktok", "TikTok"], .["twitch", "Twitch"], .["twitter", "X"],
	.["xbox", "Xbox"], .["youtube", "YouTube"], .["amazon-music", "Amazon Music"]
];

platform_name :: (kind: string) -> string {
	for CONNECT_PLATFORMS if it[0] == kind return it[1];
	for string.["bluesky", "Bluesky", "mastodon", "Mastodon", "domain", "Domain", "facebook", "Facebook", "instagram", "Instagram", "letterboxd", "Letterboxd", "soundcloud", "SoundCloud"] {
		if it_index % 2 == 0 && it == kind return string.["Bluesky", "Mastodon", "Domain", "Facebook", "Instagram", "Letterboxd", "SoundCloud"][it_index / 2];
	}
	return kind;
}

// Connected Apps (CONNECTED_APPS_PANEL): the accounts linked to the profile, adding one (its sign-in
// opens in the browser), and the apps authorized with the account.
connected_apps_page :: () {
	us_enter("Connected Apps", .Connections, .Tokens);
	if !set_page_begin("connpage") return;
	defer set_page_end();
	set_heading("Connections");
	set_para("connhelp", "Connect these accounts and unlock special Discord integrations. The sign-in opens in your browser.", .Normal, 14, 18, T("--text-muted"));
	spacer(.Y, 12);
	PER_ROW :: 5;
	for line: 0..(CONNECT_PLATFORMS.count - 1) / PER_ROW {
		pills := row(tprint("add%", line));
		pills.semantic_size = .[ui.pct(1), ui.px(32)];
		pills.style.child_gap = 8;
		{ ui.parent(pills); defer ui.pop_parent();
			for k: line * PER_ROW..min(CONNECT_PLATFORMS.count, (line + 1) * PER_ROW) - 1 {
				p := CONNECT_PLATFORMS[k];
				if set_button(tprint("%##add_%", p[1], p[0]), .Secondary, !us.busy, 32) && net_action() {
					us_set_error("");
					dc.user_settings_call(app.client, xx US_Req.Authorize, "GET", tprint("/connections/%/authorize?", p[0]));
				}
			}
		}
		spacer(.Y, 8);
	}
	us_error_line();
	spacer(.Y, 24);
	if us_ready(.Connections) {
		body := us_reply(.Connections);
		list := dc.vlist(body);
		if !list.count set_para("noconn", "You haven't connected any accounts yet.", .Normal, 14, 18, T("--text-muted"));
		for list {
			m := dc.vmap(it);
			if dc.fbool(m, "revoked") continue;
			ui.id_scope(cast(u64) it_index + 1);
			defer ui.pop_seed();
			card := ui.box("conn", .Draw_Background);
			card.semantic_size = .[ui.pct(1), ui.children()];
			card.layout_axis = .Y;
			card.style.bg = T("--background-base-lowest");
			card.style.radius = all4(8);
			{ ui.parent(card); defer ui.pop_parent();
				inset_begin(16, 12);
				kind, id := dc.fstr(m, "type"), dc.fstr(m, "id");
				r := row("head");
				r.semantic_size = .[ui.pct(1), ui.px(32)];
				{ ui.parent(r); defer ui.pop_parent();
					col := ui.box("col");
					col.semantic_size = .[ui.fill(), ui.children()];
					col.layout_axis = .Y;
					{ ui.parent(col); defer ui.pop_parent();
						label(dc.fstr(m, "name"), .Semibold, 16, T("--text-strong"), 20);
						label(platform_name(kind), .Normal, 12, T("--text-muted"), 16);
					}
					if set_button("Remove##rm", .Link, !us.busy, 32) us_action(.Connections, "DELETE", tprint("/users/@me/connections/%/%", kind, id));
				}
				spacer(.Y, 8);
				shown := dc.fint(m, "visibility") == 1;
				if set_toggle_row("vis", "Display on profile", "", shown, us.busy) {
					us_action(.Connections, "PATCH", tprint("/users/@me/connections/%/%", kind, id), tprint("{\"visibility\":%}", ifx shown then 0 else 1));
				}
				inset_end(16, 12);
			}
			spacer(.Y, 8);
		}
	}
	spacer(.Y, 40);
	set_heading("Authorized Apps");
	if !us_ready(.Tokens) return;
	apps := dc.vlist(us_reply(.Tokens));
	if !apps.count set_para("noapps", "You haven't authorized any apps.", .Normal, 14, 18, T("--text-muted"));
	for apps {
		m := dc.vmap(it);
		a := dc.fmap(m, "application");
		ui.id_scope(cast(u64) it_index + 1000);
		defer ui.pop_seed();
		card := ui.box("app", .Draw_Background);
		card.semantic_size = .[ui.pct(1), ui.children()];
		card.layout_axis = .Y;
		card.style.bg = T("--background-base-lowest");
		card.style.radius = all4(8);
		{ ui.parent(card); defer ui.pop_parent();
			inset_begin(16, 12);
			r := row("head");
			r.semantic_size = .[ui.pct(1), ui.px(32)];
			{ ui.parent(r); defer ui.pop_parent();
				label(dc.fstr(a, "name"), .Semibold, 16, T("--text-strong"), 20);
				filler(.X);
				if set_button("Deauthorize##deauth", .Danger, !us.busy, 32) us_action(.Tokens, "DELETE", tprint("/oauth2/tokens/%", dc.fstr(m, "id")));
			}
			desc := dc.fstr(a, "description");
			if desc {
				spacer(.Y, 4);
				set_para("desc", desc, .Normal, 14, 18, T("--text-default"));
			}
			scopes: [..]string;
			scopes.allocator = temp;
			for dc.flist(m, "scopes") array_add(*scopes, dc.vstr(it));
			if scopes.count {
				spacer(.Y, 8);
				set_para("scopes", tprint("Permissions: %", join(..scopes, separator = ", ",, temp)), .Normal, 12, 16, T("--text-muted"));
			}
			inset_end(16, 12);
		}
		spacer(.Y, 8);
	}
}

// Script command `settings_reply <Request> <json>` for the pages here (tests).
user_settings_script_reply :: (name: string, json: string) -> bool {
	for i: 0..cast(int) US_Req.COUNT - 1 {
		if tprint("%", cast(US_Req) i) != name continue;
		arena := New(Flat_Pool,, context.default_allocator);
		body, err := etf.from_json(json,, dc.pool_allocator(arena));
		if err != .None {
			fini(arena);
			free(arena,, context.default_allocator);
			return false;
		}
		r := dc.Feature_Result.{op = .User_Settings, tag = xx i, ok = true, status = 200, body = body, arena = arena};
		user_settings_receive(*r);
		dc.feature_result_free(*r);
		return true;
	}
	return false;
}
