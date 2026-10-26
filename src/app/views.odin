package app

import "fc:ui"

// Layout constants measured from the official client (tools/probes/layout_geometry.js).
TITLE_BAR_H :: 33
RAIL_W :: 72
SIDEBAR_W :: 303 // includes the 1px left border
HEADER_H :: 49
GUILD_ICON :: 40
USER_PANEL_H :: 58

Screen :: enum u8 {
	Friends,
	Guild,
	DM,
}

Friends_Tab :: enum u8 {
	Online,
	All,
	Pending,
	Add_Friend,
}

View_State :: struct {
	screen:      Screen,
	guild_index: int,
	friends_tab: Friends_Tab,
}

view_init :: proc(v: ^View_State) {
	v.screen = .Friends
	v.friends_tab = .Add_Friend
}

T :: proc(name: string) -> ui.Color {return tok(&app.theme, name)}

with_alpha :: proc(c: ui.Color, a: f32) -> ui.Color {return {c.r, c.g, c.b, c.a * a}}

// A box sized in pixels on both axes.
sized :: proc(id: string, w, h: f32, flags: ui.Box_Flags = {}) -> ^ui.Box {
	b := ui.box(id, flags)
	b.semantic_size = {.X = ui.px(w), .Y = ui.px(h)}
	return b
}

row :: proc(id: string, flags: ui.Box_Flags = {}) -> ^ui.Box {
	b := ui.box(id, flags)
	b.layout_axis = .X
	b.cross_align = .Center
	return b
}

spacer :: proc(axis: ui.Axis, v: f32) {
	b := ui.box("")
	b.semantic_size[axis] = ui.px(v)
	b.semantic_size[axis == .X ? .Y : .X] = ui.px(0)
}

filler :: proc(axis: ui.Axis) {
	b := ui.box("")
	b.semantic_size[axis] = ui.fill()
	b.semantic_size[axis == .X ? .Y : .X] = ui.px(0)
}

label :: proc(text: string, font: Font_Id, size: f32, color: ui.Color, line_h: f32 = 0) -> ^ui.Box {
	st := ui.st()
	saved := st^
	st.font = F(font)
	st.font_size = size
	st.text_color = color
	st.line_height = line_h
	b := ui.box(text, {.Draw_Text})
	b.semantic_size = {.X = ui.text_size(), .Y = ui.text_size()}
	st^ = saved
	return b
}

build_ui :: proc() {
	root := ui.top_parent()
	root.layout_axis = .Y
	title_bar()
	body := row("body")
	body.semantic_size = {.X = ui.pct(1), .Y = ui.fill()}
	if ui.parent(body) {
		guild_rail()
		sidebar()
		page()
	}
	user_panel()
}

title_bar :: proc() {
	b := row("titlebar")
	b.semantic_size = {.X = ui.pct(1), .Y = ui.px(TITLE_BAR_H)}
	if ui.parent(b) {
		filler(.X)
		label("Friends", .Medium, 14, T("--text-default"))
		filler(.X)
	}
}

guild_rail :: proc() {
	rail := ui.box("rail", {.Scroll_Y, .Clip})
	rail.semantic_size = {.X = ui.px(RAIL_W), .Y = ui.pct(1)}
	rail.layout_axis = .Y
	ui.signal(rail)
	if ui.parent(rail) {
		rail_item("home", app.view.screen == .Friends, "", "clyde")
		// separator: 32x1 at y+48, centered
		sep_row := row("sep")
		sep_row.semantic_size = {.X = ui.pct(1), .Y = ui.px(17)}
		if ui.parent(sep_row) {
			spacer(.X, 20)
			s := ui.box("sepline", {.Draw_Background})
			s.semantic_size = {.X = ui.px(32), .Y = ui.px(1)}
			s.fixed_pos = {20, 8}
			s.flags += {.Floating_Y}
			s.style.bg = T("--background-mod-subtle")
			s.style.radius = 1
		}
		guilds := []string{"DB"}
		for name, i in guilds {
			if ui.id_scope(u64(i)) {
				if rail_item(name, app.view.screen == .Guild && app.view.guild_index == i, name).clicked {
					app.view.screen = .Guild
					app.view.guild_index = i
				}
			}
		}
		rail_item("add", false, "", "circle-plus")
		rail_item("discover", false, "", "compass")
	}
}

// One 72x48 rail slot: pill on the left edge + 40x40 icon that rounds from
// 12px radius (selected/hovered) — the visual-refresh client uses a squircle at all times.
rail_item :: proc(id: string, selected: bool, text: string, icon_name := "") -> ui.Signal {
	slot := row(id)
	slot.semantic_size = {.X = ui.pct(1), .Y = ui.px(GUILD_ICON + 8)}
	sig: ui.Signal
	if ui.parent(slot) {
		// selection pill: 4px wide, 8 tall on hover, 40 when selected
		pill := ui.box("pill", {.Draw_Background, .Floating_X, .Floating_Y})
		icon := ui.box("icon", {.Clickable, .Draw_Background, .Hot_Animation, .Floating_X, .Floating_Y, .Draw_Text})
		icon.semantic_size = {.X = ui.px(GUILD_ICON), .Y = ui.px(GUILD_ICON)}
		icon.fixed_pos = {16, 0}
		icon.style.radius = 12
		icon.style.text_align = .Center
		icon.style.font = F(.Medium)
		icon.style.font_size = 18
		icon.text = text
		sig = ui.signal(icon)
		target: f32 = selected ? 40 : (sig.hovering ? 20 : 0)
		ui.animate(&pill.user_t, target, 25)
		h := pill.user_t
		pill.semantic_size = {.X = ui.px(4), .Y = ui.px(h)}
		pill.fixed_pos = {0, (GUILD_ICON - h) / 2}
		pill.style.bg = T("--text-strong")
		pill.style.radius = {0, 4, 0, 4}
		if h < 0.5 do pill.flags -= {.Draw_Background}

		if id == "home" {
			icon.style.bg = selected ? T("--background-brand") : T("--background-mod-subtle")
			icon.style.bg_hot = T("--background-brand")
		} else {
			icon.style.bg = selected ? T("--background-brand") : T("--background-mod-subtle")
			icon.style.bg_hot = selected ? icon.style.bg : T("--background-mod-strong")
		}
		icon.style.text_color = T("--text-default")
		if icon_name != "" {
			icon.layout_axis = .X
			icon.cross_align = .Center
			if ui.parent(icon) {
				spacer(.X, 8)
				g := icon_name == "clyde" ? T("--text-overlay-light") : T("--interactive-icon-default")
				if id != "home" && sig.hovering do g = T("--interactive-icon-hover")
				_ = icon_box("glyph", icon_name, 24, g)
			}
		}
	}
	return sig
}

sidebar :: proc() {
	b := ui.box("sidebar", {.Draw_Background, .Draw_Border, .Clip})
	b.semantic_size = {.X = ui.px(SIDEBAR_W), .Y = ui.pct(1)}
	b.style.bg = T("--background-base-lower")
	b.style.border_color = T("--border-subtle")
	b.style.border = 1
	b.style.radius = {12, 0, 0, 0}
	b.layout_axis = .Y
	if ui.parent(b) {
		search := row("search")
		search.semantic_size = {.X = ui.pct(1), .Y = ui.px(49)}
		if ui.parent(search) {
			spacer(.X, 8)
			col := ui.box("searchcol")
			col.semantic_size = {.X = ui.fill(), .Y = ui.pct(1)}
			if ui.parent(col) {
				spacer(.Y, 8)
				btn := ui.box("Find or start a conversation##btn", {.Clickable, .Draw_Background, .Draw_Border, .Draw_Text})
				btn.semantic_size = {.X = ui.pct(1), .Y = ui.px(32)}
				btn.style.bg = T("--background-mod-subtle")
				btn.style.border_color = T("--border-muted")
				btn.style.border = 1
				btn.style.radius = 8
				btn.style.font = F(.Medium)
				btn.style.font_size = 14
				btn.style.text_color = T("--text-strong")
				btn.style.text_align = .Center
				ui.signal(btn)
			}
			spacer(.X, 8)
		}
		nav_items := []string{"Friends", "Nitro", "Shop", "Quests"}
		for name in nav_items {
			dm_nav_item(name, name == "Friends" && app.view.screen == .Friends)
		}
		header := row("dmheader")
		header.semantic_size = {.X = ui.pct(1), .Y = ui.px(40)}
		if ui.parent(header) {
			spacer(.X, 16)
			label("Direct Messages", .Medium, 14, T("--channels-default"), 18)
			filler(.X)
		}
	}
}

dm_nav_item :: proc(name: string, selected: bool) {
	outer := row(name)
	outer.semantic_size = {.X = ui.pct(1), .Y = ui.px(42)}
	if ui.parent(outer) {
		spacer(.X, 8)
		item := row("item", {.Clickable, .Draw_Background, .Hot_Animation})
		icon_name := "friends"
		switch name {
		case "Nitro":
			icon_name = "nitro-wheel"
		case "Shop":
			icon_name = "shop"
		case "Quests":
			icon_name = "quests"
		}
		item.semantic_size = {.X = ui.fill(), .Y = ui.px(40)}
		item.style.radius = 8
		item.style.bg = selected ? T("--background-mod-normal") : {}
		item.style.bg_hot = selected ? item.style.bg : T("--background-mod-subtle")
		sig := ui.signal(item)
		if ui.parent(item) {
			color := selected || sig.hovering ? T("--interactive-text-active") : T("--channels-default")
			spacer(.X, 8)
			_ = icon_box("ic", icon_name, 24, color)
			spacer(.X, 12)
			l := label(name, .Medium, 16, color, 20)
			l.semantic_size[.Y] = ui.pct(1)
		}
		spacer(.X, 8)
	}
}

page :: proc() {
	p := ui.box("page", {.Draw_Background})
	p.semantic_size = {.X = ui.fill(), .Y = ui.pct(1)}
	p.style.bg = T("--background-base-lower")
	p.layout_axis = .Y
	if ui.parent(p) {
		h := row("header", {.Draw_Background})
		h.semantic_size = {.X = ui.pct(1), .Y = ui.px(HEADER_H)}
		h.style.bg = T("--background-base-lower")
		if ui.parent(h) {
			spacer(.X, 16)
			label("Friends", .Semibold, 16, T("--text-strong"))
			spacer(.X, 16)
			tabs := []string{"Online", "All", "Add Friend"}
			for name in tabs {
				t := ui.box(name, {.Clickable, .Draw_Background, .Draw_Text, .Hot_Animation})
				t.semantic_size = {.X = ui.text_size(12), .Y = ui.px(32)}
				t.style.radius = 8
				t.style.font = F(.Medium)
				t.style.font_size = 16
				t.style.text_color = T("--text-default")
				t.style.bg_hot = T("--background-mod-subtle")
				if name == "Add Friend" {
					t.style.bg = T("--interactive-accent-background-default")
					t.style.text_color = T("--text-brand")
				}
				ui.signal(t)
				spacer(.X, 8)
			}
		}
	}
}

user_panel :: proc() {
	p := row("userpanel", {.Draw_Background, .Draw_Border, .Floating_X, .Floating_Y})
	p.semantic_size = {.X = ui.px(359), .Y = ui.px(USER_PANEL_H)}
	p.fixed_pos = {8, app.ui.window.y - USER_PANEL_H - 8}
	p.style.bg = T("--background-base-low")
	p.style.border_color = T("--border-muted")
	p.style.border = 1
	p.style.radius = 8
	if ui.parent(p) {
		spacer(.X, 12)
		col := ui.box("namecol")
		col.semantic_size = {.X = ui.fill(), .Y = ui.pct(1)}
		col.layout_axis = .Y
		if ui.parent(col) {
			spacer(.Y, 11)
			r := row("av")
			r.semantic_size = {.X = ui.pct(1), .Y = ui.px(32)}
			if ui.parent(r) {
				av := sized("avatar", 32, 32, {.Draw_Background})
				av.style.bg = {0.98, 0.65, 0.1, 1}
				av.style.radius = 16
				spacer(.X, 8)
				names := ui.box("names")
				names.semantic_size = {.X = ui.children(), .Y = ui.pct(1)}
				if ui.parent(names) {
					label("Dingus Battle", .Medium, 14, T("--text-strong"), 18)
					label("Online", .Normal, 12, T("--text-muted"), 14)
				}
			}
		}
	}
}

icon_box :: proc(id, name: string, size: f32, color: ui.Color) -> ^ui.Box {
	return icon(id, name, size, color)
}
