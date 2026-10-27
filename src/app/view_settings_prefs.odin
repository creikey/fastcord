package app

import "core:strings"
import "core:unicode/utf8"
import dc "fc:discord"
import "fc:gfx"
import "fc:ui"

// Settings pages that edit local preferences (Notifications), the settings nav's
// search field and Log Out item, and the small widgets the settings pages share
// (page column, toggle rows, inputs, buttons).

@(private = "file")
nav: struct {
	search: ui.Editor,
}

settings_nav_reset_for_test :: proc() {
	ui.editor_set_text(&nav.search, "")
}

// ---- nav ----

// The nav's search box: a text field that filters the nav items.
settings_nav_search :: proc() {
	sr := row("searchrow")
	sr.semantic_size = {.X = ui.pct(1), .Y = ui.px(40)}
	if ui.parent(sr) {
		spacer(.X, 16)
		sb := row("search", {.Draw_Background, .Draw_Border, .Clickable})
		sb.semantic_size = {.X = ui.fill(), .Y = ui.px(40)}
		sb.style.bg = T("--input-background-default")
		focused := app.ui.focus == sb.key
		sb.style.border_color = focused ? T("--input-border-active") : T("--input-border-default")
		sb.style.border = 1
		sb.style.radius = 8
		sb.hover_cursor = .IBeam
		if ui.signal(sb).pressed do app.ui.focus = sb.key
		if ui.parent(sb) {
			spacer(.X, 12)
			icon("mag", "magnifying-glass", 16, T("--icon-default"))
			spacer(.X, 8)
			res := text_field("field", &nav.search, "Search", focused, 16, 20, 10, T("--input-placeholder-text-default"))
			if res == .Escape && ui.editor_text(&nav.search) != "" do ui.editor_set_text(&nav.search, "")
			if ui.editor_text(&nav.search) != "" {
				x := ui.box("clear", {.Clickable})
				x.semantic_size = {.X = ui.px(16), .Y = ui.px(16)}
				xs := ui.signal(x)
				set_icon(x, "x-small", xs.hovering ? T("--interactive-icon-hover") : T("--interactive-icon-default"))
				if xs.clicked do ui.editor_set_text(&nav.search, "")
			}
			spacer(.X, 12)
		}
		spacer(.X, 16)
	}
}

// Nav item visible under the search text (case-insensitive substring).
settings_nav_match :: proc(name: string) -> bool {
	q := strings.trim_space(ui.editor_text(&nav.search))
	if q == "" do return true
	return strings.contains(strings.to_lower(name, context.temp_allocator), strings.to_lower(q, context.temp_allocator))
}

// "Log Out" at the bottom of the nav (red, like the client), below a divider.
settings_nav_logout :: proc() {
	if !settings_nav_match("Log Out") do return
	spacer(.Y, 8)
	d := row("logoutsep")
	d.semantic_size = {.X = ui.pct(1), .Y = ui.px(1)}
	if ui.parent(d) {
		spacer(.X, 24)
		l := ui.box("l", {.Draw_Background})
		l.semantic_size = {.X = ui.fill(), .Y = ui.px(1)}
		l.style.bg = T("--border-muted")
		spacer(.X, 24)
	}
	spacer(.Y, 8)
	outer := row("Log Out")
	outer.semantic_size = {.X = ui.pct(1), .Y = ui.px(37)}
	if ui.parent(outer) {
		spacer(.X, 16)
		r := row("item", {.Clickable, .Draw_Background, .Hot_Animation})
		r.semantic_size = {.X = ui.fill(), .Y = ui.px(33)}
		r.style.radius = 8
		r.style.bg_hot = T("--background-mod-subtle")
		if ui.signal(r).clicked do account_logout_ask()
		c := T("--text-feedback-critical")
		if ui.parent(r) {
			spacer(.X, 8)
			icon("i", "door-exit", 20, c)
			spacer(.X, 8)
			label("Log Out", .Medium, 16, c, 20)
		}
		spacer(.X, 16)
	}
}

// ---- Notifications ----

@(private = "file")
SOUND_ROWS := [?][2]string {
	{"message1", "Message"},
	{"deafen", "Deafen"},
	{"undeafen", "Undeafen"},
	{"mute", "Mute"},
	{"unmute", "Unmute"},
	{"disconnect", "Voice Disconnected"},
	{"ptt_start", "PTT Activate"},
	{"ptt_stop", "PTT Deactivate"},
	{"user_join", "User Join"},
	{"user_leave", "User Leave"},
	{"user_moved", "User Moved"},
}

notifications_page :: proc() {
	if set_page_begin("notifpage") {
		set_heading("Notifications")
		if set_toggle_row("desktop", "Enable Desktop Notifications", "Show a system notification for messages that would notify you (DMs, mentions, servers set to all messages).", !notify_prefs.desktop_off) {
			notify_prefs.desktop_off = !notify_prefs.desktop_off
		}
		spacer(.Y, 24)
		label("Notify me when...", .Semibold, 16, T("--text-strong"), 20)
		spacer(.Y, 16)
		// synced (NotificationSettings.notify_friends_on_launch), unlike the local rows here
		friends_on := !store().settings.friend_online_off
		if set_toggle_row("friendsonline", "Friends come online", "", friends_on) {
			if net_action() do dc.set_friend_online_notifications(app.client, !friends_on)
			else do store().settings.friend_online_off = friends_on // offline (fixture) runs
		}
		set_divider()
		if set_toggle_row("badge", "Enable Unread Message Badge", "Shows a red badge on the app icon when you have unread mentions.", !notify_prefs.badge_off) {
			notify_prefs.badge_off = !notify_prefs.badge_off
		}
		spacer(.Y, 40)
		set_heading("Sounds")
		all_off := sounds_all_disabled()
		if set_toggle_row("disableall", "Disable All Notification Sounds", "", all_off) do sounds_set_all_disabled(!all_off)
		set_divider()
		for s in SOUND_ROWS {
			on := !sound_own_disabled(s[0]) && !all_off
			if set_toggle_row(s[0], s[1], "", on, all_off) do sound_set_disabled(s[0], on)
			set_divider()
		}
		set_page_end()
	}
}

// ---- shared widgets ----

// A settings page: scrolls, content centered at SET_CONTENT_MAX_W (narrower in small windows).
// Close with set_page_end when it returns true.
set_page_begin :: proc(id: string) -> bool {
	page := ui.box(id, {.Scroll_Y, .Clip})
	page.semantic_size = {.X = ui.pct(1), .Y = ui.fill()}
	page.layout_axis = .Y
	ui.signal(page)
	ui.push_parent(page)
	spacer(.Y, 32)
	body := row("body")
	body.semantic_size = {.X = ui.pct(1), .Y = ui.children()}
	body.cross_align = .Start
	ui.push_parent(body)
	filler(.X)
	col := ui.box("col")
	col.semantic_size = {.X = ui.px(set_content_w()), .Y = ui.children()}
	col.layout_axis = .Y
	ui.push_parent(col)
	return true
}

set_page_end :: proc() {
	ui.pop_parent() // col
	filler(.X)
	ui.pop_parent() // body
	spacer(.Y, 96)
	ui.pop_parent() // page
}

// Width of a page's column.
set_content_w :: proc() -> f32 {
	avail := app.ui.window.x - 2 * SET_INSET - SET_NAV_W - 1 - 80
	return clamp(avail, 300, SET_CONTENT_MAX_W)
}

set_heading :: proc(text: string) {
	label(text, .Semibold, 20, T("--text-strong"), 24)
	spacer(.Y, 20)
}

set_divider :: proc() {
	spacer(.Y, 16)
	d := ui.box("div", {.Draw_Background})
	d.semantic_size = {.X = ui.pct(1), .Y = ui.px(1)}
	d.style.bg = T("--border-subtle")
	spacer(.Y, 16)
}

// Wrapped paragraph.
set_para :: proc(id, text: string, font: Font_Id, size, line_h: f32, color: ui.Color) -> ^ui.Box {
	b := ui.box(id, {.Draw_Text, .Wrap_Text})
	b.text = text
	b.semantic_size = {.X = ui.pct(1), .Y = ui.text_size()}
	b.style.font = F(font)
	b.style.font_size = size
	b.style.line_height = line_h
	b.style.text_color = color
	return b
}

// 40x24 switch (the client's toggle).
set_switch :: proc(on: bool, dim := false) {
	sw := ui.box("switch", {.Draw_Background})
	sw.semantic_size = {.X = ui.px(40), .Y = ui.px(24)}
	sw.style.radius = 12
	sw.style.bg = on ? T("--status-positive") : T("--background-mod-strong")
	if dim do sw.style.bg = with_alpha(sw.style.bg, 0.5)
	if ui.parent(sw) {
		k := ui.box("k", {.Draw_Background, .Floating_X, .Floating_Y})
		k.semantic_size = {.X = ui.px(18), .Y = ui.px(18)}
		k.fixed_pos = {on ? 19 : 3, 3}
		k.style.radius = 9
		k.style.bg = {1, 1, 1, 1}
	}
}

// Title (+ help) with a switch on the right; the whole row toggles. Returns true when clicked.
set_toggle_row :: proc(id, text, help: string, on: bool, disabled := false) -> bool {
	r := row(id, {.Clickable})
	r.semantic_size = {.X = ui.pct(1), .Y = ui.children()}
	if disabled do r.flags += {.Disabled}
	sig := ui.signal(r)
	if ui.parent(r) {
		col := ui.box("col")
		col.semantic_size = {.X = ui.fill(), .Y = ui.children()}
		col.layout_axis = .Y
		if ui.parent(col) {
			label(text, .Medium, 16, disabled ? T("--text-muted") : T("--text-strong"), 20)
			if help != "" {
				spacer(.Y, 4)
				set_para("help", help, .Normal, 14, 18, T("--text-muted"))
			}
		}
		spacer(.X, 16)
		set_switch(on, disabled)
	}
	return sig.clicked && !disabled
}

Button_Kind :: enum u8 {
	Primary,
	Secondary,
	Positive,
	Danger,
	Link,
}

// "Label##id" button. Disabled buttons draw faded and return false.
set_button :: proc(text: string, kind: Button_Kind, enabled := true, h: f32 = 38) -> bool {
	b := ui.box(text, {.Clickable, .Draw_Background, .Draw_Text, .Hot_Animation})
	b.semantic_size = {.X = ui.text_size(kind == .Link ? 8 : 32), .Y = ui.px(h)}
	b.style.radius = 8
	b.style.font = F(.Medium)
	b.style.font_size = 14
	b.style.text_align = .Center
	b.hover_cursor = .Pointer
	switch kind {
	case .Primary:
		b.style.bg = T("--background-brand")
		b.style.text_color = {1, 1, 1, 1}
	case .Positive:
		b.style.bg = T("--status-positive")
		b.style.text_color = {1, 1, 1, 1}
	case .Danger:
		b.style.bg = T("--status-danger")
		b.style.text_color = {1, 1, 1, 1}
	case .Secondary:
		b.style.bg = T("--background-mod-strong")
		b.style.text_color = T("--text-strong")
	case .Link:
		b.style.bg = {}
		b.style.text_color = T("--text-default")
	}
	b.style.bg_hot = kind == .Link ? ui.Color{} : with_alpha(b.style.bg, 0.85)
	if !enabled {
		b.flags += {.Disabled}
		b.style.bg = with_alpha(b.style.bg, 0.5)
		b.style.bg_hot = b.style.bg
		b.style.text_color = with_alpha(b.style.text_color, 0.5)
		b.hover_cursor = .Default
	}
	return ui.signal(b).clicked && enabled
}

// Bordered text input filling the width. multiline: wraps, Enter adds a line (min_h tall).
// password: shows bullets. max_runes > 0 caps the length.
set_input :: proc(id: string, ed: ^ui.Editor, placeholder: string, multiline := false, password := false, max_runes := 0, min_h: f32 = 40, autofocus := false) -> ui.Edit_Result {
	box := row(id, {.Draw_Background, .Draw_Border, .Clickable})
	box.semantic_size = {.X = ui.pct(1), .Y = multiline ? ui.children() : ui.px(min_h)}
	if multiline do box.cross_align = .Start
	box.style.bg = T("--input-background-default")
	box.style.border_color = app.ui.focus == box.key || autofocus && app.ui.focus == 0 ? T("--input-border-active") : T("--input-border-default")
	box.style.border = 1
	box.style.radius = 8
	box.hover_cursor = .IBeam
	if autofocus && app.ui.focus == 0 do app.ui.focus = box.key
	focused := app.ui.focus == box.key
	if ui.signal(box).pressed do app.ui.focus = box.key
	res: ui.Edit_Result
	if ui.parent(box) {
		spacer(.X, 12)
		if password {
			res = password_field("field", ed, placeholder, focused)
		} else {
			res = text_field("field", ed, placeholder, focused, 16, 20, 10, T("--input-placeholder-text-default"))
		}
		if multiline {
			spacer(.Y, min_h) // minimum height
			if res == .Submit {
				ui.editor_insert(ed, "\n")
				res = .Changed
			}
		}
		spacer(.X, 12)
	}
	if max_runes > 0 && utf8.rune_count_in_string(ui.editor_text(ed)) > max_runes {
		t := ui.editor_text(ed)
		n := 0
		for _, i in t {
			if n == max_runes {
				ui.editor_set_text(ed, strings.clone(t[:i], context.temp_allocator))
				break
			}
			n += 1
		}
	}
	return res
}

// Single-line field showing bullets; never copies its text out.
password_field :: proc(id: string, ed: ^ui.Editor, placeholder: string, focused: bool) -> ui.Edit_Result {
	text := ui.editor_text(ed)
	n := utf8.rune_count_in_string(text)
	f := ui.box(id, {.Clickable, .Draw_Text})
	f.semantic_size = {.X = ui.fill(), .Y = ui.text_size()}
	f.style.font = F(.Normal)
	f.style.font_size = 16
	f.style.line_height = 20
	f.style.padding = {0, 10}
	f.hover_cursor = .IBeam
	f.text = n > 0 ? strings.repeat("•", n, context.temp_allocator) : placeholder
	f.style.text_color = n > 0 ? T("--text-default") : T("--input-placeholder-text-default")
	if ui.signal(f).pressed && f.parent != nil do app.ui.focus = f.parent.key
	result := ui.Edit_Result.None
	if focused {
		note_focused_editor(ed, f)
		for &e in app.ui.events {
			if e.consumed || (e.kind != .Key_Down && e.kind != .Text) do continue
			r := ui.editor_event(ed, e, nil, clipboard_get, proc(_: string) {}, multiline = false)
			if r != .None {
				e.consumed = true
				if r != .Moved || result == .None do result = r
			}
		}
		f.custom_draw = password_caret
		f.custom_user = transmute(rawptr)uintptr(n)
	}
	return result
}

@(private = "file")
password_caret :: proc(b: ^ui.Box, user: rawptr) {
	n := int(uintptr(user))
	x := b.rect.x0 + b.style.padding.x
	if n > 0 && b.text_layout != nil do x += b.text_layout.width
	y := b.rect.y0 + b.style.padding.y
	gfx.rect({x, y + 2, x + 1.5, y + 18}, gfx.Color(T("--text-default")))
}
