// User Settings pages kept in the synced settings proto: Language & Time and Developer. Each edit
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

// ---- Pages that load from REST: Logged-in Devices ----

US_Req :: enum u8 {
	Sessions; // GET /auth/sessions
	COUNT;
	Action :: 100; // a change, then `us.after` reloads
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

US_PATHS :: string.["/auth/sessions"];

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
