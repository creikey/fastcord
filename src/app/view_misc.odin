package app

import "core:fmt"
import dc "fc:discord"
import "fc:gfx"
import "fc:platform"
import "fc:ui"

clipboard_get :: proc() -> string {return platform.clipboard_get()}
clipboard_set :: proc(s: string) {platform.clipboard_set(s)}

Field_Draw :: struct {
	ed:      ^ui.Editor,
	blink_t: f64,
}

// Selection highlight and caret for a focused text field. Drawn before the text.
field_draw :: proc(b: ^ui.Box, user: rawptr) {
	d := (^Field_Draw)(user)
	ed := d.ed
	tl := b.text_layout
	if tl == nil do return
	text := ui.editor_text(ed)
	if tl.origin == {} do tl.origin = {b.rect.x0 + b.style.padding.x, b.rect.y0 + b.style.padding.y}
	origin := ui.Vec2{b.rect.x0 + b.style.padding.x, b.rect.y0 + b.style.padding.y}
	if text != "" && ui.editor_has_sel(ed) {
		a, z := ui.editor_sel(ed)
		c := gfx.Color(app.ui.selection_color)
		for l, li in tl.lines {
			s0 := max(a, l.start)
			s1 := min(z, l.end)
			if s0 > s1 || (s0 == s1 && z <= l.end) do continue
			x0 := ui.caret_x_in_line(tl, li, s0)
			x1 := ui.caret_x_in_line(tl, li, s1)
			if z > l.end do x1 += 4
			gfx.rect({origin.x + x0, origin.y + l.y, origin.x + x1, origin.y + l.y + tl.line_h}, c)
		}
	}
	// caret blinks: solid for 0.5 s after any change, then 1 Hz
	pos := text == "" ? 0 : ed.caret
	x := text == "" ? 0 : ui.caret_x(tl, pos)
	li := text == "" ? 0 : ui.line_of(tl, pos)
	y := origin.y + f32(li) * tl.line_h
	// solid for 0.5 s after typing, then toggles every 0.5 s; only wake at toggles
	phase := app.ui.time - app.caret_reset_t
	request_wake(app.caret_reset_t + (f64(int(phase * 2)) + 1) * 0.5)
	if phase < 0.5 || int(phase * 2) % 2 == 0 {
		gfx.rect({origin.x + x, y + 2, origin.x + x + 1.5, y + tl.line_h - 2}, gfx.Color(T("--text-default")))
	}
	platform.set_ime_rect(origin.x + x, y, 1, tl.line_h)
}

open_profile :: proc(uid: dc.Snowflake, anchor: ui.Rect) {
	app.profile_user = uid
	app.profile_anchor = anchor
	app.profile_open_t = 0
	if app.client != nil do dc.fetch_profile(app.client, uid, app.view.guild)
}

// Profile popout: banner, avatar with status, names, and a message box like the official one.
profile_popout :: proc() {
	s := store()
	uid := app.profile_user
	u := dc.user_get(s, uid)
	if u == nil {
		app.profile_user = 0
		return
	}
	W :: 300
	scrim := ui.box("profile_scrim", {.Clickable, .Floating_X, .Floating_Y, .Overlay})
	scrim.semantic_size = {.X = ui.px(app.ui.window.x), .Y = ui.px(app.ui.window.y)}
	if ui.signal(scrim).clicked {
		app.profile_user = 0
		return
	}
	ui.animate(&app.profile_open_t, 1, 25)
	a := app.profile_anchor
	x := a.x1 + 8
	if x + W > app.ui.window.x - 8 do x = a.x0 - W - 8
	y := clamp(a.y0, 8, app.ui.window.y - 420)
	p := ui.box("profile", {.Draw_Background, .Draw_Border, .Draw_Shadow, .Floating_X, .Floating_Y, .Overlay, .Clickable})
	p.semantic_size = {.X = ui.px(W), .Y = ui.children()}
	p.fixed_pos = {x, y + (1 - app.profile_open_t) * 8}
	p.opacity = app.profile_open_t
	p.layout_axis = .Y
	p.style.bg = T("--background-surface-high")
	p.style.border_color = T("--border-subtle")
	p.style.border = 1
	p.style.radius = 8
	p.style.shadow_color = {0, 0, 0, 0.35}
	p.style.shadow_blur = 16
	p.style.shadow_offset = {0, 8}
	ui.signal(p) // swallow clicks inside
	if ui.parent(p) {
		banner := ui.box("banner", {.Draw_Background})
		banner.semantic_size = {.X = ui.pct(1), .Y = ui.px(105)}
		banner.style.radius = {8, 8, 0, 0}
		if ac, ok := u.accent_color.?; ok {
			banner.style.bg = rgb_u32(ac)
		} else {
			banner.style.bg = T("--background-brand")
		}
		if u.banner != "" do set_remote_image(banner, dc.banner_url(uid, u.banner, 600))
		av_row := ui.box("avrow")
		av_row.semantic_size = {.X = ui.pct(1), .Y = ui.px(44)}
		if ui.parent(av_row) {
			ring := ui.box("ring", {.Draw_Background, .Floating_X, .Floating_Y})
			ring.semantic_size = {.X = ui.px(92), .Y = ui.px(92)}
			ring.fixed_pos = {10, -50}
			ring.style.radius = 46
			ring.style.bg = p.style.bg
			if ui.parent(ring) {
				av := avatar_with_status("av", uid, 80, p.style.bg)
				av.flags += {.Floating_X, .Floating_Y}
				av.fixed_pos = {6, 6}
			}
		}
		info := ui.box("info")
		info.semantic_size = {.X = ui.pct(1), .Y = ui.children()}
		info.layout_axis = .Y
		if ui.parent(info) {
			pad := row("namepad")
			pad.semantic_size = {.X = ui.pct(1), .Y = ui.px(26)}
			if ui.parent(pad) {
				spacer(.X, 16)
				n := label(dc.display_name(u), .Bold, 20, T("--text-strong"), 24)
				n.flags += {.Selectable_Text}
				n.sel_order = 1
			}
			pad2 := row("userpad")
			pad2.semantic_size = {.X = ui.pct(1), .Y = ui.px(20)}
			if ui.parent(pad2) {
				spacer(.X, 16)
				un := label(u.username, .Normal, 14, T("--text-default"), 18)
				un.flags += {.Selectable_Text}
				un.sel_order = 2
				if u.pronouns != "" {
					label(fmt.tprintf(" • %s", u.pronouns), .Normal, 14, T("--text-default"), 18)
				}
			}
			if u.bio != "" {
				spacer(.Y, 12)
				bio := ui.box("bio", {.Selectable_Text, .Wrap_Text})
				bio.semantic_size = {.X = ui.pct(1), .Y = ui.text_size()}
				bio.style.padding = {16, 0}
				bio.style.line_height = 18
				bio.style.text_color = T("--text-default")
				bio.sel_order = 3
				blocks := md_parse(u.bio)
				if len(blocks) > 0 do ui.set_spans(bio, tokens_to_spans(blocks[0].tokens, .Normal, 14, nil))
			}
			spacer(.Y, 16)
			if uid != s.me {
				mr := row("msgrow")
				mr.semantic_size = {.X = ui.pct(1), .Y = ui.px(40)}
				if ui.parent(mr) {
					spacer(.X, 16)
					mb := row(fmt.tprintf("Message @%s##msgbtn", dc.display_name(u)), {.Clickable, .Draw_Background, .Draw_Border, .Draw_Text})
					mb.semantic_size = {.X = ui.fill(), .Y = ui.px(40)}
					mb.style.bg = T("--input-background-default")
					mb.style.border_color = T("--border-subtle")
					mb.style.border = 1
					mb.style.radius = 8
					mb.style.padding = {12, 0}
					mb.style.font = F(.Normal)
					mb.style.font_size = 14
					mb.style.text_color = T("--text-muted")
					mb.hover_cursor = .IBeam
					if ui.signal(mb).clicked && app.client != nil {
						if existing := dc.open_dm(app.client, uid, "Profile"); existing != 0 do select_channel(0, existing)
						else do app.pending_dm_user = uid
						app.profile_user = 0
					}
					spacer(.X, 16)
				}
				spacer(.Y, 16)
			}
		}
	}
	for e in app.ui.events {
		if e.kind == .Key_Down && e.key == .Escape do app.profile_user = 0
	}
}

// Settings: appearance (theme) for now; mirrors the client's modal layout.
settings_modal :: proc() {
	scrim := ui.box("settings_scrim", {.Draw_Background, .Floating_X, .Floating_Y, .Overlay, .Clickable})
	scrim.semantic_size = {.X = ui.px(app.ui.window.x), .Y = ui.px(app.ui.window.y)}
	scrim.style.bg = T("--background-base-lowest")
	ui.signal(scrim)
	if ui.parent(scrim) {
		layout := row("layout")
		layout.semantic_size = {.X = ui.pct(1), .Y = ui.pct(1)}
		layout.cross_align = .Start
		if ui.parent(layout) {
			nav := ui.box("nav", {.Draw_Background})
			nav.semantic_size = {.X = ui.pct(0.3), .Y = ui.pct(1)}
			nav.style.bg = T("--background-base-lower")
			nav.layout_axis = .Y
			if ui.parent(nav) {
				spacer(.Y, 60)
				for name in ([]string{"My Account", "Profiles", "Appearance", "Voice & Video", "Notifications"}) {
					sel := name == settings_page
					it := row(name, {.Clickable, .Draw_Background, .Hot_Animation})
					it.semantic_size = {.X = ui.pct(1), .Y = ui.px(32)}
					it.style.radius = 6
					it.style.bg = sel ? T("--background-mod-normal") : {}
					it.style.bg_hot = T("--background-mod-subtle")
					if ui.signal(it).clicked do settings_page = name
					if ui.parent(it) {
						spacer(.X, 20)
						label(name, .Medium, 16, sel ? T("--interactive-text-active") : T("--interactive-text-default"), 20)
					}
				}
			}
			content := ui.box("content")
			content.semantic_size = {.X = ui.fill(), .Y = ui.pct(1)}
			content.layout_axis = .Y
			if ui.parent(content) {
				spacer(.Y, 60)
				t := row("t")
				t.semantic_size = {.X = ui.pct(1), .Y = ui.px(28)}
				if ui.parent(t) {
					spacer(.X, 40)
					label(settings_page, .Semibold, 20, T("--text-strong"), 24)
					filler(.X)
					close := ui.box("close", {.Clickable, .Draw_Border})
					close.semantic_size = {.X = ui.px(36), .Y = ui.px(36)}
					close.style.radius = 18
					close.style.border = 2
					close.style.border_color = T("--interactive-icon-default")
					close.layout_axis = .X
					close.cross_align = .Center
					if ui.parent(close) {
						spacer(.X, 8)
						icon("x", "x-small", 20, T("--interactive-icon-default"))
					}
					if ui.signal(close).clicked do app.settings_open = false
					spacer(.X, 40)
				}
				spacer(.Y, 24)
				if settings_page == "Voice & Video" do voice_settings_page()
				th := row("themes")
				th.semantic_size = {.X = ui.pct(1), .Y = ui.px(60 if settings_page == "Appearance" else 0)}
				if settings_page == "Appearance" {
					if ui.parent(th) {
						spacer(.X, 40)
						for name in Theme_Name {
							tokens: Theme
							defer delete(tokens.tokens)
							theme_load(&tokens, name)
							sw := ui.box(fmt.tprint(name), {.Clickable, .Draw_Background, .Draw_Border})
							sw.semantic_size = {.X = ui.px(60), .Y = ui.px(60)}
							sw.style.radius = 30
							sw.style.bg = tok(&tokens, "--background-base-lower")
							sw.style.border = app.theme.name == name ? 2 : 1
							sw.style.border_color = app.theme.name == name ? T("--background-brand") : T("--border-strong")
							if ui.signal(sw).clicked do theme_load(&app.theme, name)
							spacer(.X, 16)
						}
					}
				}

			}
		}
	}
	for e in app.ui.events {
		if e.kind == .Key_Down && e.key == .Escape do app.settings_open = false
	}
}
