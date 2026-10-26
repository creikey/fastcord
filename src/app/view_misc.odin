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
	if app.sweep || phase < 0.5 || int(phase * 2) % 2 == 0 {
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
		banner.style.bg = profile_banner_color(uid)
		if u.banner != "" do set_remote_image(banner, dc.banner_url(uid, u.banner, 600))
		if ui.parent(banner) {
			// "..." on the banner's top-right (official: 28px dark circle, 12px in)
			more := ui.box("more", {.Clickable, .Draw_Background, .Floating_X, .Floating_Y})
			more.semantic_size = {.X = ui.px(28), .Y = ui.px(28)}
			more.fixed_pos = {W - 12 - 28, 12}
			more.style.radius = 14
			more.style.bg = {0, 0, 0, 0.5}
			if ui.signal(more).clicked {
				// the user menu draws below this popout, so hand over to it
				open_user_menu(uid, {more.rect.x0, more.rect.y1 + 4})
				app.profile_user = 0
			}
			if ui.parent(more) {
				ic := icon("i", "more-horizontal", 16, {1, 1, 1, 1})
				ic.flags += {.Floating_X, .Floating_Y}
				ic.fixed_pos = {6, 6}
			}
		}
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
				profile_full_avatar_hook(av, uid) // click: full profile modal
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
			if uid == s.me {
				er := row("editrow")
				er.semantic_size = {.X = ui.pct(1), .Y = ui.px(32)}
				if ui.parent(er) {
					spacer(.X, 16)
					eb := row("editprofile", {.Clickable, .Draw_Background, .Hot_Animation})
					eb.semantic_size = {.X = ui.fill(), .Y = ui.px(32)}
					eb.style.radius = 8
					eb.style.bg = T("--background-brand")
					eb.style.bg_hot = with_alpha(T("--background-brand"), 0.85)
					if ui.signal(eb).clicked {
						// opens Settings > Profiles, like the client (it used to do nothing)
						app.profile_user = 0
						settings_page = "Profiles"
						app.settings_open = true
					}
					if ui.parent(eb) {
						filler(.X)
						icon("i", "pencil", 16, {1, 1, 1, 1})
						spacer(.X, 4)
						label("Edit Profile", .Medium, 14, {1, 1, 1, 1}, 18)
						filler(.X)
					}
					spacer(.X, 16)
				}
				spacer(.Y, 16)
			}
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
					if ui.signal(mb).clicked && net_action() {
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

// Settings: a floating modal like the visual-refresh client's (1200x640 at 1280x720):
// a 252px nav (profile, search, sections) and a content pane with a 48px title bar.
SET_INSET :: 40
SET_NAV_W :: 252
SET_TITLE_H :: 48
SET_CONTENT_MAX_W :: 696
SET_SWATCH :: 48
SET_SWATCH_PITCH :: 56

Settings_Item :: struct {
	name: string,
	icon: string,
}

settings_modal :: proc() {
	s := store()
	scrim := ui.box("settings_scrim", {.Draw_Background, .Floating_X, .Floating_Y, .Overlay, .Clickable})
	scrim.semantic_size = {.X = ui.px(app.ui.window.x), .Y = ui.px(app.ui.window.y)}
	scrim.style.bg = {0, 0, 0, 0.7}
	if ui.signal(scrim).clicked do app.settings_open = false
	if ui.parent(scrim) {
		m := row("settings", {.Draw_Background, .Draw_Border, .Floating_X, .Floating_Y, .Clickable, .Clip})
		m.semantic_size = {.X = ui.px(app.ui.window.x - 2 * SET_INSET), .Y = ui.px(app.ui.window.y - 2 * SET_INSET)}
		m.fixed_pos = {SET_INSET, SET_INSET}
		m.cross_align = .Start
		m.style.bg = T("--background-base-lower")
		m.style.border_color = T("--border-subtle")
		m.style.border = 1
		m.style.radius = 12
		ui.signal(m)
		if ui.parent(m) {
			nav := ui.box("nav")
			nav.semantic_size = {.X = ui.px(SET_NAV_W), .Y = ui.pct(1)}
			nav.layout_axis = .Y
			if ui.parent(nav) {
				spacer(.Y, 24)
				me := row("me")
				me.semantic_size = {.X = ui.pct(1), .Y = ui.px(48)}
				if ui.parent(me) {
					spacer(.X, 24)
					avatar_box("av", s.me, 48)
					spacer(.X, 10)
					col := ui.box("names")
					col.semantic_size = {.X = ui.fill(), .Y = ui.children()}
					if ui.parent(col) {
						name := "…"
						if u := dc.user_get(s, s.me); u != nil do name = dc.display_name(u)
						label(name, .Semibold, 16, T("--text-strong"), 20)
						er := row("edit")
						er.semantic_size = {.X = ui.pct(1), .Y = ui.px(18)}
						if ui.parent(er) {
							label("Edit Profiles", .Medium, 14, T("--text-muted"), 18)
							spacer(.X, 4)
							icon("pen", "pencil", 12, T("--text-muted"))
						}
					}
				}
				spacer(.Y, 16)
				sr := row("searchrow")
				sr.semantic_size = {.X = ui.pct(1), .Y = ui.px(40)}
				if ui.parent(sr) {
					spacer(.X, 16)
					sb := row("search", {.Draw_Background, .Draw_Border})
					sb.semantic_size = {.X = ui.fill(), .Y = ui.px(40)}
					sb.style.bg = T("--input-background-default")
					sb.style.border_color = T("--input-border-default")
					sb.style.border = 1
					sb.style.radius = 8
					if ui.parent(sb) {
						spacer(.X, 12)
						icon("mag", "magnifying-glass", 16, T("--icon-default"))
						spacer(.X, 8)
						label("Search", .Normal, 16, T("--input-placeholder-text-default"), 20)
					}
					spacer(.X, 16)
				}
				spacer(.Y, 8)
				items := []Settings_Item{{"My Account", "user-circle"}, {"Profiles", "pencil"}, {"Appearance", "paint-palette"}, {"Voice & Video", "microphone"}, {"Notifications", "bell"}}
				for it in items {
					sel := it.name == settings_page
					outer := row(it.name)
					outer.semantic_size = {.X = ui.pct(1), .Y = ui.px(37)}
					if ui.parent(outer) {
						spacer(.X, 16)
						r := row("item", {.Clickable, .Draw_Background, .Hot_Animation})
						r.semantic_size = {.X = ui.fill(), .Y = ui.px(33)}
						r.style.radius = 8
						r.style.bg = sel ? T("--background-mod-normal") : {}
						r.style.bg_hot = sel ? r.style.bg : T("--background-mod-subtle")
						sig := ui.signal(r)
						if sig.clicked do settings_page = it.name
						c := sel || sig.hovering ? T("--interactive-text-active") : T("--interactive-text-default")
						if ui.parent(r) {
							spacer(.X, 8)
							icon("i", it.icon, 20, c)
							spacer(.X, 8)
							label(it.name, .Medium, 16, c, 20)
						}
						spacer(.X, 16)
					}
				}
			}
			edge := ui.box("navedge", {.Draw_Background})
			edge.semantic_size = {.X = ui.px(1), .Y = ui.pct(1)}
			edge.style.bg = T("--border-muted")
			content := ui.box("content", {.Draw_Background})
			content.semantic_size = {.X = ui.fill(), .Y = ui.pct(1)}
			content.layout_axis = .Y
			content.style.bg = T("--background-base-low")
			if ui.parent(content) {
				t := row("t")
				t.semantic_size = {.X = ui.pct(1), .Y = ui.px(SET_TITLE_H)}
				if ui.parent(t) {
					spacer(.X, 20)
					label(settings_page, .Semibold, 16, T("--text-strong"), 20)
					filler(.X)
					close := ui.box("close", {.Clickable})
					close.semantic_size = {.X = ui.px(20), .Y = ui.px(20)}
					cs := ui.signal(close)
					set_icon(close, "x-large", cs.hovering ? T("--interactive-icon-hover") : T("--interactive-icon-default"))
					if cs.clicked do app.settings_open = false
					spacer(.X, 16)
				}
				tl := ui.box("tline", {.Draw_Background})
				tl.semantic_size = {.X = ui.pct(1), .Y = ui.px(1)}
				tl.style.bg = T("--border-muted")
				if settings_page == "Voice & Video" {
					voice_settings_page()
				} else if settings_page == "Appearance" {
					appearance_page()
				}
			}
		}
	}
	for e in app.ui.events {
		if e.kind == .Key_Down && e.key == .Escape do app.settings_open = false
	}
}

// Appearance > Theme: heading, "Same as Device Theme" row, the default theme swatches.
@(private = "file")
appearance_page :: proc() {
	page := row("appearance")
	page.semantic_size = {.X = ui.pct(1), .Y = ui.fill()}
	page.cross_align = .Start
	if ui.parent(page) {
		filler(.X)
		col := ui.box("col")
		col.semantic_size = {.X = ui.px(SET_CONTENT_MAX_W), .Y = ui.children()}
		col.layout_axis = .Y
		if ui.parent(col) {
			spacer(.Y, 64)
			label("Theme", .Medium, 24, T("--text-strong"), 32)
			spacer(.Y, 30)
			dr := row("device")
			dr.semantic_size = {.X = ui.pct(1), .Y = ui.px(40)}
			if ui.parent(dr) {
				c := ui.box("c")
				c.semantic_size = {.X = ui.fill(), .Y = ui.children()}
				if ui.parent(c) {
					label("Same as Device Theme", .Medium, 16, T("--text-strong"), 20)
					spacer(.Y, 2)
					label("Match your device's light or dark mode.", .Normal, 14, T("--text-subtle"), 18)
				}
				// toggle (off): 40x24 track with a white knob
				tr := ui.box("toggle", {.Draw_Background, .Draw_Border})
				tr.semantic_size = {.X = ui.px(40), .Y = ui.px(24)}
				tr.style.radius = 12
				tr.style.bg = T("--background-mod-strong")
				tr.style.border = 1
				tr.style.border_color = T("--border-subtle")
				if ui.parent(tr) {
					k := ui.box("knob", {.Draw_Background, .Floating_X, .Floating_Y})
					k.semantic_size = {.X = ui.px(16), .Y = ui.px(16)}
					k.fixed_pos = {4, 4}
					k.style.radius = 8
					k.style.bg = {1, 1, 1, 1}
				}
			}
			spacer(.Y, 32)
			label("Default Themes", .Semibold, 16, T("--text-default"), 20)
			spacer(.Y, 24)
			sw := row("swatches")
			sw.semantic_size = {.X = ui.pct(1), .Y = ui.px(SET_SWATCH)}
			if ui.parent(sw) {
				for name in Theme_Name {
					tokens: Theme
					defer delete(tokens.tokens)
					theme_load(&tokens, name)
					sel := app.theme.name == name
					b := ui.box(fmt.tprint(name), {.Clickable, .Draw_Background, .Draw_Border})
					b.semantic_size = {.X = ui.px(SET_SWATCH), .Y = ui.px(SET_SWATCH)}
					b.style.radius = 8
					b.style.bg = name == .Light ? ui.Color{1, 1, 1, 1} : tok(&tokens, "--background-base-lower")
					b.style.border = sel ? 2 : 1
					b.style.border_color = sel ? T("--background-brand") : T("--interactive-icon-default")
					if ui.signal(b).clicked do theme_set_by_user(name)
					if sel {
						if ui.parent(b) {
							// check badge on the selected swatch's top-right corner
							badge := ui.box("check", {.Draw_Background, .Floating_X, .Floating_Y})
							badge.semantic_size = {.X = ui.px(20), .Y = ui.px(20)}
							badge.fixed_pos = {SET_SWATCH - 14, -6}
							badge.style.radius = 10
							badge.style.bg = T("--background-brand")
							if ui.parent(badge) {
								ic := icon("i", "checkmark-small-bold", 16, {1, 1, 1, 1})
								ic.flags += {.Floating_X, .Floating_Y}
								ic.fixed_pos = {2, 2}
							}
						}
					}
					spacer(.X, SET_SWATCH_PITCH - SET_SWATCH)
				}
			}
		}
		filler(.X)
	}
}
