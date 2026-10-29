// Settings pages that edit local preferences (Notifications), the settings nav's
// search field and Log Out item, and the small widgets the settings pages share
// (page column, toggle rows, inputs, buttons).


settings_nav_reset_for_test :: () {
	ui.editor_set_text(*nav.search, "");
}

// ---- nav ----

// The nav's search box: a text field that filters the nav items.
settings_nav_search :: () {
	sr := row("searchrow");
	sr.semantic_size = .[ui.pct(1), ui.px(40)];
	{ ui.parent(sr); defer ui.pop_parent();
		spacer(.X, 16);
		sb := row("search", .Draw_Background | .Draw_Border | .Clickable);
		sb.semantic_size = .[ui.fill(), ui.px(40)];
		sb.style.bg = T("--input-background-default");
		focused := app.ui.focus == sb.key;
		sb.style.border_color = ifx focused then T("--input-border-active") else T("--input-border-default");
		sb.style.border = 1;
		sb.style.radius = all4(8);
		sb.hover_cursor = .IBeam;
		if ui.signal(sb).pressed { app.ui.focus = sb.key; }
		{ ui.parent(sb); defer ui.pop_parent();
			spacer(.X, 12);
			icon("mag", "magnifying-glass", 16, T("--icon-default"));
			spacer(.X, 8);
			res := text_field("field", *nav.search, "Search", focused, 16, 20, 10, T("--input-placeholder-text-default"));
			if res == .Escape && ui.editor_text(*nav.search) != "" { ui.editor_set_text(*nav.search, ""); }
			if ui.editor_text(*nav.search) != "" {
				x := ui.box("clear", .Clickable);
				x.semantic_size = .[ui.px(16), ui.px(16)];
				xs := ui.signal(x);
				set_icon(x, "x-small", ifx xs.hovering then T("--interactive-icon-hover") else T("--interactive-icon-default"));
				if xs.clicked { ui.editor_set_text(*nav.search, ""); }
			}
			spacer(.X, 12);
		}
		spacer(.X, 16);
	}
}

// Nav item visible under the search text (case-insensitive substring).
settings_nav_match :: (name: string) -> bool {
	q := trim(ui.editor_text(*nav.search));
	if q == "" { return true; }
	return contains(to_lower_copy(name,, temp), to_lower_copy(q,, temp));
}

// "Log Out" at the bottom of the nav (red, like the client), below a divider.
settings_nav_logout :: () {
	if !settings_nav_match("Log Out") { return; }
	spacer(.Y, 8);
	d := row("logoutsep");
	d.semantic_size = .[ui.pct(1), ui.px(1)];
	{ ui.parent(d); defer ui.pop_parent();
		spacer(.X, 24);
		l := ui.box("l", .Draw_Background);
		l.semantic_size = .[ui.fill(), ui.px(1)];
		l.style.bg = T("--border-muted");
		spacer(.X, 24);
	}
	spacer(.Y, 8);
	outer := row("Log Out");
	outer.semantic_size = .[ui.pct(1), ui.px(37)];
	{ ui.parent(outer); defer ui.pop_parent();
		spacer(.X, 16);
		r := row("item", .Clickable | .Draw_Background | .Hot_Animation);
		r.semantic_size = .[ui.fill(), ui.px(33)];
		r.style.radius = all4(8);
		r.style.bg_hot = T("--background-mod-subtle");
		if ui.signal(r).clicked { account_logout_ask(); }
		c := T("--text-feedback-critical");
		{ ui.parent(r); defer ui.pop_parent();
			spacer(.X, 8);
			icon("i", "door-exit", 20, c);
			spacer(.X, 8);
			label("Log Out", .Medium, 16, c, 20);
		}
		spacer(.X, 16);
	}
}

// ---- Notifications ----

#scope_file
SOUND_ROWS :: [2]string.[
	.["message1", "Message"],
	.["deafen", "Deafen"],
	.["undeafen", "Undeafen"],
	.["mute", "Mute"],
	.["unmute", "Unmute"],
	.["disconnect", "Voice Disconnected"],
	.["ptt_start", "PTT Activate"],
	.["ptt_stop", "PTT Deactivate"],
	.["user_join", "User Join"],
	.["user_leave", "User Leave"],
	.["user_moved", "User Moved"]
];
#scope_export

notifications_page :: () {
	if set_page_begin("notifpage") {
		set_heading("Notifications");
		if set_toggle_row("lotus", "Lotus Mode", "Silence every sound and notification and hide all badges and unread marks, so fastcord never asks for your attention.", notify_prefs.lotus) {
			notify_prefs.lotus = !notify_prefs.lotus;
		}
		set_divider();
		if set_toggle_row("desktop", "Enable Desktop Notifications", "Show a system notification for messages that would notify you (DMs, mentions, servers set to all messages).", !notify_prefs.desktop_off) {
			notify_prefs.desktop_off = !notify_prefs.desktop_off;
		}
		spacer(.Y, 24);
		label("Notify me when...", .Semibold, 16, T("--text-strong"), 20);
		spacer(.Y, 16);
		// synced (NotificationSettings.notify_friends_on_launch), unlike the local rows here
		friends_on := !store().settings.friend_online_off;
		if set_toggle_row("friendsonline", "Friends come online", "", friends_on) {
			if net_action() { dc.set_friend_online_notifications(app.client, !friends_on); } else { store().settings.friend_online_off = friends_on; } // offline (fixture) runs
		}
		set_divider();
		if set_toggle_row("badge", "Enable Unread Message Badge", "Shows a red badge on the app icon when you have unread mentions.", !notify_prefs.badge_off) {
			notify_prefs.badge_off = !notify_prefs.badge_off;
		}
		spacer(.Y, 40);
		set_heading("Sounds");
		all_off := sounds_all_disabled();
		if set_toggle_row("disableall", "Disable All Notification Sounds", "", all_off) { sounds_set_all_disabled(!all_off); }
		set_divider();
		for s: SOUND_ROWS {
			on := !sound_own_disabled(s[0]) && !all_off;
			if set_toggle_row(s[0], s[1], "", on, all_off) { sound_set_disabled(s[0], on); }
			set_divider();
		}
		set_page_end();
	}
}

// The client's System panel, General category (Windows and Linux; macOS has Login Items instead).
system_page :: () {
	#if OS != .MACOS if set_page_begin("systempage") {
		set_heading("General");
		on := platform.open_at_login();
		if set_toggle_row("openatlogin", "Automatically open fastcord when your computer starts up", "", on) platform.set_open_at_login(!on);
		set_page_end();
	}
}

// ---- shared widgets ----

// A settings page: scrolls, content centered at SET_CONTENT_MAX_W (narrower in small windows).
// Close with set_page_end when it returns true.
set_page_begin :: (id: string) -> bool {
	page := ui.box(id, .Scroll_Y | .Clip);
	page.semantic_size = .[ui.pct(1), ui.fill()];
	page.layout_axis = .Y;
	page.scrollbar = .Auto;
	ui.signal(page);
	ui.push_parent(page);
	spacer(.Y, 32);
	body := row("body");
	body.semantic_size = .[ui.pct(1), ui.children()];
	body.cross_align = .Start;
	ui.push_parent(body);
	filler(.X);
	col := ui.box("col");
	col.semantic_size = .[ui.px(set_content_w()), ui.children()];
	col.layout_axis = .Y;
	ui.push_parent(col);
	return true;
}

set_page_end :: () {
	ui.pop_parent(); // col
	filler(.X);
	ui.pop_parent(); // body
	spacer(.Y, 96);
	ui.pop_parent(); // page
}

// Width of a page's column.
set_content_w :: () -> float32 {
	avail := app.ui.window.x - 2 * SET_INSET - SET_NAV_W - 1 - 80;
	return clamp(avail, 300, SET_CONTENT_MAX_W);
}

set_heading :: (text: string) {
	label(text, .Semibold, 20, T("--text-strong"), 24);
	spacer(.Y, 20);
}

set_divider :: () {
	spacer(.Y, 16);
	d := ui.box("div", .Draw_Background);
	d.semantic_size = .[ui.pct(1), ui.px(1)];
	d.style.bg = T("--border-subtle");
	spacer(.Y, 16);
}

// Wrapped paragraph.
set_para :: (id: string, text: string, font: Font_Id, size: float32, line_h: float32, color: ui.Color) -> *ui.Box {
	b := ui.box(id, .Draw_Text | .Wrap_Text);
	b.text = text;
	b.semantic_size = .[ui.pct(1), ui.text_size()];
	b.style.font = F(font);
	b.style.font_size = size;
	b.style.line_height = line_h;
	b.style.text_color = color;
	return b;
}

// 40x24 switch (the client's toggle).
set_switch :: (on: bool, dim := false) {
	sw := ui.box("switch", .Draw_Background);
	sw.semantic_size = .[ui.px(40), ui.px(24)];
	sw.style.radius = all4(12);
	sw.style.bg = ifx on then T("--status-positive") else T("--background-mod-strong");
	if dim { sw.style.bg = with_alpha(sw.style.bg, 0.5); }
	{ ui.parent(sw); defer ui.pop_parent();
		k := ui.box("k", .Draw_Background | .Floating_X | .Floating_Y);
		k.semantic_size = .[ui.px(18), ui.px(18)];
		k.fixed_pos = .{ifx on then 19.0 else 3.0, 3};
		k.style.radius = all4(9);
		k.style.bg = .{1, 1, 1, 1};
	}
}

// Title (+ help) with a switch on the right; the whole row toggles. Returns true when clicked.
set_toggle_row :: (id: string, text: string, help: string, on: bool, disabled := false) -> bool {
	r := row(id, .Clickable);
	r.semantic_size = .[ui.pct(1), ui.children()];
	if disabled { r.flags |= .Disabled; }
	sig := ui.signal(r);
	{ ui.parent(r); defer ui.pop_parent();
		col := ui.box("col");
		col.semantic_size = .[ui.fill(), ui.children()];
		col.layout_axis = .Y;
		{ ui.parent(col); defer ui.pop_parent();
			label(text, .Medium, 16, ifx disabled then T("--text-muted") else T("--text-strong"), 20);
			if help != "" {
				spacer(.Y, 4);
				set_para("help", help, .Normal, 14, 18, T("--text-muted"));
			}
		}
		spacer(.X, 16);
		set_switch(on, disabled);
	}
	return sig.clicked && !disabled;
}

Button_Kind :: enum u8 {
	Primary;
	Secondary;
	Positive;
	Danger;
	Link;
}

// "Label##id" button. Disabled buttons draw faded and return false.
set_button :: (text: string, kind: Button_Kind, enabled := true, h: float32 = 38) -> bool {
	b := ui.box(text, .Clickable | .Draw_Background | .Draw_Text | .Hot_Animation);
	b.semantic_size = .[ui.text_size(ifx kind == .Link then 8.0 else 32.0), ui.px(h)];
	b.style.radius = all4(8);
	b.style.font = F(.Medium);
	b.style.font_size = 14;
	b.style.text_align = .Center;
	b.hover_cursor = .Pointer;
	if kind == {
	case .Primary;
		b.style.bg = T("--background-brand");
		b.style.text_color = .{1, 1, 1, 1};
	case .Positive;
		b.style.bg = T("--status-positive");
		b.style.text_color = .{1, 1, 1, 1};
	case .Danger;
		b.style.bg = T("--status-danger");
		b.style.text_color = .{1, 1, 1, 1};
	case .Secondary;
		b.style.bg = T("--background-mod-strong");
		b.style.text_color = T("--text-strong");
	case .Link;
		b.style.bg = .{};
		b.style.text_color = T("--text-default");
	}
	b.style.bg_hot = ifx kind == .Link then ui.Color.{} else with_alpha(b.style.bg, 0.85);
	if !enabled {
		b.flags |= .Disabled;
		b.style.bg = with_alpha(b.style.bg, 0.5);
		b.style.bg_hot = b.style.bg;
		b.style.text_color = with_alpha(b.style.text_color, 0.5);
		b.hover_cursor = .Default;
	}
	return ui.signal(b).clicked && enabled;
}

// Bordered text input filling the width. multiline: wraps, Enter adds a line (min_h tall).
// password: shows bullets. max_runes > 0 caps the length.
set_input :: (id: string, ed: *ui.Editor, placeholder: string, multiline := false, password := false, max_runes := 0, min_h: float32 = 40, autofocus := false) -> ui.Edit_Result {
	box := row(id, .Draw_Background | .Draw_Border | .Clickable);
	// Even a single-line field wraps, so it grows with its text instead of drawing over what's below.
	box.semantic_size = .[ui.pct(1), ui.children()];
	if multiline { box.cross_align = .Start; }
	box.style.bg = T("--input-background-default");
	box.style.border_color = ifx app.ui.focus == box.key || autofocus && app.ui.focus == 0 then T("--input-border-active") else T("--input-border-default");
	box.style.border = 1;
	box.style.radius = all4(8);
	box.hover_cursor = .IBeam;
	if autofocus && app.ui.focus == 0 { app.ui.focus = box.key; }
	focused := app.ui.focus == box.key;
	if ui.signal(box).pressed { app.ui.focus = box.key; }
	res: ui.Edit_Result;
	{ ui.parent(box); defer ui.pop_parent();
		spacer(.X, 12);
		if password {
			res = password_field("field", ed, placeholder, focused);
		} else {
			res = text_field("field", ed, placeholder, focused, 16, 20, 10, T("--input-placeholder-text-default"));
		}
		spacer(.Y, min_h); // minimum height
		if multiline {
			if res == .Submit {
				ui.editor_insert(ed, "\n");
				res = .Changed;
			}
		}
		spacer(.X, 12);
	}
	if max_runes > 0 {
		t := ui.editor_text(ed);
		k := 0;
		for i: 0..t.count-1 {
			if (t[i] & 0xC0) == 0x80 continue; // count runes, not bytes
			if k == max_runes {
				ui.editor_set_text(ed, copy_string(string.{i, t.data},, temp));
				break;
			}
			k += 1;
		}
	}
	return res;
}

// Single-line field showing bullets; never copies its text out.
password_field :: (id: string, ed: *ui.Editor, placeholder: string, focused: bool) -> ui.Edit_Result {
	text := ui.editor_text(ed);
	n := 0;
	for i: 0..text.count-1 if (text[i] & 0xC0) != 0x80 n += 1; // runes
	f := ui.box(id, .Clickable | .Draw_Text);
	f.semantic_size = .[ui.fill(), ui.text_size()];
	f.style.font = F(.Normal);
	f.style.font_size = 16;
	f.style.line_height = 20;
	f.style.padding = .{0, 10};
	f.hover_cursor = .IBeam;
	f.text = placeholder;
	if n > 0 {
		f.text = talloc_string(n * BULLET.count);
		for 0..n-1 memcpy(f.text.data + it * BULLET.count, BULLET.data, BULLET.count);
	}
	f.style.text_color = ifx n > 0 then T("--text-default") else T("--input-placeholder-text-default");
	if ui.signal(f).pressed && f.parent != null { app.ui.focus = f.parent.key; }
	result := ui.Edit_Result.None;
	if focused {
		note_focused_editor(ed, f);
		for * e: app.ui.events {
			if e.consumed || (e.kind != .Key_Down && e.kind != .Text) { continue; }
			r := ui.editor_event(ed, e, null, clipboard_get, (_: string) {}, multiline = false);
			if r != .None {
				e.consumed = true;
				if r != .Moved || result == .None { result = r; }
			}
		}
		f.custom_draw = password_caret;
		f.custom_user = cast(*void) n;
	}
	return result;
}
#scope_file

BULLET :: "•";

nav: struct {
	search: ui.Editor;
};

password_caret :: (b: *ui.Box, user: *void) {
	n := cast(int) user;
	x := b.rect.x0 + b.style.padding.x;
	if n > 0 && b.text_layout != null { x += b.text_layout.width; }
	y := b.rect.y0 + b.style.padding.y;
	gfx.rect(.{x, y + 2, x + 1.5, y + 18}, cast(gfx.Color)(T("--text-default")));
}
