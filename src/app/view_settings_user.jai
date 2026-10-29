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
