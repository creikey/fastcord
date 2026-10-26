package app

import "core:fmt"
import "core:slice"
import "core:strings"
import dc "fc:discord"
import "fc:ui"

// Layout constants measured from the official client (tools/probes/layout_geometry.js).
TITLE_BAR_H :: 33
HEADER_TOOL_W :: 40 // channel header icon buttons (20px icons on a 40px pitch)
SEARCH_W :: 244 // header search box (official 1028..1272 at 1280 wide)
TITLE_SIDE_W :: 140 // back/forward on the left, inbox/help on the right
RAIL_W :: 72
SIDEBAR_W :: 303 // includes the 1px left border
HEADER_H :: 49
GUILD_NAME_MAX_W :: SIDEBAR_W - 86 // name ellipsized before the chevron and invite button
CHANNEL_ROW_H :: 32
CHANNEL_ROW_PITCH :: 34
CATEGORY_GAP :: 16
CATEGORY_ROW_H :: 24
GUILD_ICON :: 40
USER_PANEL_H :: 58
MEMBER_LIST_W :: 264

Friends_Tab :: enum u8 {
	Online,
	All,
	Pending,
	Add_Friend,
}

View_State :: struct {
	guild:        dc.Snowflake, // 0 = home (friends / DMs)
	channel:      dc.Snowflake, // selected channel in the current guild, or DM channel at home
	last_channel: map[dc.Snowflake]dc.Snowflake, // guild -> last selected channel
	friends_tab:  Friends_Tab,
	collapsed:    map[dc.Snowflake]bool, // collapsed categories
	show_members: bool,
	hide_dm_profile: bool, // 1:1 DM user profile column (header toggle)
	add_friend:   ui.Editor,
}

view_init :: proc(v: ^View_State) {
	v.friends_tab = .Online
	v.show_members = true
}

store :: proc() -> ^dc.Store {
	if app.client != nil do return &app.client.store
	return &app.offline_store
}

T :: proc(name: string) -> ui.Color {return tok(&app.theme, name)}

with_alpha :: proc(c: ui.Color, a: f32) -> ui.Color {return {c.r, c.g, c.b, c.a * a}}

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

// text cut with "…" to fit max_w (single line).
ellipsize :: proc(text: string, font: Font_Id, size: f32, max_w: f32) -> string {
	tl := ui.layout_text(F(font), size, text, -1)
	if tl.width <= max_w do return text
	dots := ui.layout_text(F(font), size, "…", -1).width
	cut := 0
	for g in tl.run.glyphs {
		if g.x + g.advance + dots > max_w do break
		cut = g.cluster_end
	}
	return strings.concatenate({strings.trim_right_space(text[:cut]), "…"}, context.temp_allocator)
}

label :: proc(text: string, font: Font_Id, size: f32, color: ui.Color, line_h: f32 = 0) -> ^ui.Box {
	st := ui.st()
	saved := st^
	st.font = F(font)
	st.font_size = size
	st.text_color = color
	st.line_height = line_h
	b := ui.box(text, {.Draw_Text})
	b.semantic_size = {.X = ui.text_size(0, 0), .Y = ui.text_size()}
	st^ = saved
	return b
}

go_home :: proc() {
	select_channel(0, app.view.last_channel[0])
}

select_guild :: proc(gid: dc.Snowflake) {
	ch := app.view.last_channel[gid]
	if ch == 0 {
		for id in dc.guild_channels_sorted(store(), gid) {
			c := dc.channel_get(store(), id)
			if c != nil && (c.kind == .Guild_Text || c.kind == .Guild_Announcement) {
				ch = id
				break
			}
		}
	}
	select_channel(gid, ch)
}

select_channel :: proc(gid, cid: dc.Snowflake) {
	app.view.guild = gid
	app.view.channel = cid
	app.view.last_channel[gid] = cid
	if app.client != nil {
		limit := dc.initial_message_limit(int(app.ui.window.y))
		dc.select_channel(app.client, gid, cid, limit)
	}
}

build_ui :: proc() {
	root := ui.top_parent()
	root.layout_axis = .Y
	title_bar()
	body := row("body")
	body.semantic_size = {.X = ui.pct(1), .Y = ui.fill()}
	body.cross_align = .Start
	if ui.parent(body) {
		rail_view() // view_rail_folders.odin (folders, badges, DM unreads, drag)
		sidebar()
		page()
	}
	user_panel()
	overlays()
}

title_bar :: proc() {
	b := row("titlebar")
	b.semantic_size = {.X = ui.pct(1), .Y = ui.px(TITLE_BAR_H)}
	if ui.parent(b) {
		// equal-width sides keep the title centered on the window
		left := row("left")
		left.semantic_size = {.X = ui.px(TITLE_SIDE_W), .Y = ui.pct(1)}
		if ui.parent(left) {
			spacer(.X, 88)
			icon("back", "arrow-large-left", 18, T("--interactive-icon-default"))
			spacer(.X, 6)
			icon("fwd", "arrow-large-right", 18, with_alpha(T("--interactive-icon-default"), 0.3))
		}
		filler(.X)
		title := "Friends"
		glyph := "friends"
		g: ^dc.Guild
		if app.view.guild != 0 {
			g = dc.guild_get(store(), app.view.guild)
			if g != nil do title = g.name
		} else if app.view.channel != 0 {
			title, glyph = "Direct Messages", "clyde"
		}
		if g != nil {
			gi := ui.box("gicon", {.Draw_Background, .Draw_Text})
			gi.semantic_size = {.X = ui.px(16), .Y = ui.px(16)}
			gi.style.radius = 4
			gi.style.bg = T("--background-mod-subtle")
			gi.style.text_color = T("--text-default")
			gi.style.text_align = .Center
			gi.style.font = F(.Medium)
			gi.style.font_size = 6
			gi.text = guild_initials(g.name)
			if g.icon != "" {
				set_remote_image(gi, dc.guild_icon_url(g.id, g.icon, 32))
				gi.text = ""
			}
		} else {
			icon("gicon", glyph, 16, T("--text-default"))
		}
		spacer(.X, 8)
		label(title, .Medium, 14, T("--text-default"), 18)
		filler(.X)
		update_button()
		right := row("right")
		right.semantic_size = {.X = ui.px(TITLE_SIDE_W), .Y = ui.pct(1)}
		if ui.parent(right) {
			filler(.X)
			icon("inbox", "inbox", 20, T("--icon-muted"))
			spacer(.X, 16)
			icon("help", "circle-question", 20, T("--icon-muted"))
			spacer(.X, 14)
		}
	}
}

guild_rail :: proc() {
	s := store()
	rail := ui.box("rail", {.Scroll_Y, .Clip})
	rail.semantic_size = {.X = ui.px(RAIL_W), .Y = ui.pct(1)}
	rail.layout_axis = .Y
	ui.signal(rail)
	if ui.parent(rail) {
		if rail_item("home", app.view.guild == 0, "", "clyde", 0).clicked do go_home()
		sep := ui.box("sep")
		sep.semantic_size = {.X = ui.pct(1), .Y = ui.px(9)}
		if ui.parent(sep) {
			line := ui.box("line", {.Draw_Background, .Floating_X, .Floating_Y})
			line.semantic_size = {.X = ui.px(32), .Y = ui.px(1)}
			line.fixed_pos = {20, 0}
			line.style.bg = T("--background-mod-subtle")
			line.style.radius = 1
		}
		for gid in guild_order() {
			g := dc.guild_get(s, gid)
			if g == nil do continue
			if ui.id_scope(u64(gid)) {
				if rail_item("guild", app.view.guild == gid, guild_initials(g.name), "", gid).clicked do select_guild(gid)
			}
		}
		rail_item("add", false, "", "circle-plus", 0)
		rail_item("discover", false, "", "compass", 0)
	}
}

// Guilds in sidebar order, like the client: guilds missing from
// settings.guild_folders first (newest join first), then the folders flattened.
guild_order :: proc() -> []dc.Snowflake {
	s := store()
	out := make([dynamic]dc.Snowflake, context.temp_allocator)
	seen := make(map[dc.Snowflake]bool, allocator = context.temp_allocator)
	for f in s.settings.guild_folders {
		for id in f.guild_ids do seen[id] = true
	}
	for id in s.guild_order {
		if id in s.guilds && !seen[id] do append(&out, id)
	}
	newer :: proc(a, b: dc.Snowflake) -> bool {
		ga, gb := dc.guild_get(store(), a), dc.guild_get(store(), b)
		ja := ga != nil ? ga.joined_at : ""
		jb := gb != nil ? gb.joined_at : ""
		if ja != jb do return ja > jb
		return a > b
	}
	slice.sort_by(out[:], newer)
	clear(&seen)
	for id in out do seen[id] = true
	for f in s.settings.guild_folders {
		for id in f.guild_ids {
			if id in s.guilds && !seen[id] {
				append(&out, id)
				seen[id] = true
			}
		}
	}
	return out[:]
}

guild_initials :: proc(name: string) -> string {
	sb := strings.builder_make(context.temp_allocator)
	for w in strings.fields(name, context.temp_allocator) {
		strings.write_byte(&sb, w[0])
		if strings.builder_len(sb) >= 5 do break
	}
	return strings.to_string(sb)
}

// One 72x48 rail slot: unread/selection pill on the left edge and a 40x40 squircle.
rail_item :: proc(id: string, selected: bool, text: string, icon_name: string, guild_id: dc.Snowflake) -> ui.Signal {
	slot := ui.box(id)
	slot.semantic_size = {.X = ui.pct(1), .Y = ui.px(GUILD_ICON + 8)}
	sig: ui.Signal
	if ui.parent(slot) {
		pill := ui.box("pill", {.Draw_Background, .Floating_X, .Floating_Y})
		ic := ui.box("icon", {.Clickable, .Draw_Background, .Floating_X, .Floating_Y, .Draw_Text, .Hot_Animation})
		ic.semantic_size = {.X = ui.px(GUILD_ICON), .Y = ui.px(GUILD_ICON)}
		ic.fixed_pos = {16, 0}
		ic.style.radius = 12
		ic.style.text_align = .Center
		ic.style.font = F(.Medium)
		ic.style.font_size = guild_acronym_size(len(text))
		ic.text = text
		sig = ui.signal(ic)
		unread := guild_id != 0 && guild_has_unread(guild_id)
		target: f32 = selected ? 40 : (sig.hovering ? 20 : (unread ? 8 : 0))
		ui.animate(&pill.user_t, target, 25)
		h := pill.user_t
		pill.semantic_size = {.X = ui.px(4), .Y = ui.px(h)}
		pill.fixed_pos = {0, (GUILD_ICON - h) / 2}
		pill.style.bg = T("--text-strong")
		pill.style.radius = {0, 4, 0, 4}
		if h < 0.5 do pill.flags -= {.Draw_Background}

		switch id {
		case "home":
			ic.style.bg = selected ? T("--background-brand") : T("--background-mod-subtle")
			ic.style.bg_hot = T("--background-brand")
		case "add", "discover":
			ic.style.bg = T("--background-mod-subtle")
			ic.style.bg_hot = id == "add" ? T("--background-brand") : T("--status-positive")
		case:
			ic.style.bg = selected ? T("--background-brand") : T("--background-mod-subtle")
			ic.style.bg_hot = selected ? ic.style.bg : T("--background-brand")
			if g := dc.guild_get(store(), guild_id); g != nil && g.icon != "" {
				set_remote_image(ic, dc.guild_icon_url(guild_id, g.icon, 96))
				ic.text = ""
			}
		}
		ic.style.text_color = T("--text-default")
		if icon_name != "" {
			ic.layout_axis = .X
			ic.cross_align = .Center
			if ui.parent(ic) {
				spacer(.X, 8)
				g := T("--interactive-icon-default")
				if id == "home" || sig.hovering do g = T("--text-overlay-light")
				icon("glyph", icon_name, 24, g)
			}
		}
		if sig.hovering && guild_id != 0 {
			if g := dc.guild_get(store(), guild_id); g != nil do tooltip_right(g.name)
		}
	}
	return sig
}

// Acronym font size on a guild icon without an image (official: "DB" 18px, "DBst" 16px).
guild_acronym_size :: proc(n: int) -> f32 {
	switch {
	case n <= 2:
		return 18
	case n <= 4:
		return 16
	}
	return 12
}

PERM_ADMINISTRATOR :: u64(1) << 3
PERM_MANAGE_GUILD_EXPRESSIONS :: u64(1) << 30

// Guild-level permissions of the current user (owner = everything).
my_guild_permissions :: proc(gid: dc.Snowflake) -> u64 {
	s := store()
	g := dc.guild_get(s, gid)
	if g == nil do return 0
	if g.owner_id == s.me do return max(u64)
	perms: u64
	mem := dc.member_get(s, gid, s.me)
	for r in g.roles {
		if r.id == gid do perms |= r.permissions // @everyone
		if mem != nil do for rid in mem.roles do if rid == r.id do perms |= r.permissions
	}
	if perms & PERM_ADMINISTRATOR != 0 do return max(u64)
	return perms
}

guild_has_unread :: proc(gid: dc.Snowflake) -> bool {
	s := store()
	for id in dc.guild_channels_sorted(s, gid) {
		if dc.channel_unread(s, id) do return true
	}
	return false
}

sidebar :: proc() {
	b := ui.box("sidebar", {.Draw_Background, .Draw_Border, .Clip})
	b.semantic_size = {.X = ui.px(SIDEBAR_W), .Y = ui.pct(1)}
	b.style.bg = T("--background-base-lowest") // same as the rail in the visual refresh
	b.style.border_color = T("--border-subtle")
	b.style.border = 1
	b.style.radius = {12, 0, 0, 0}
	b.layout_axis = .Y
	if ui.parent(b) {
		spacer(.Y, 1) // under the top border
		if app.view.guild == 0 {
			home_sidebar()
		} else {
			channel_sidebar(app.view.guild)
		}
	}
}

page :: proc() {
	p := ui.box("page", {.Draw_Background, .Clip})
	p.semantic_size = {.X = ui.fill(), .Y = ui.pct(1)}
	p.style.bg = T("--background-base-lower")
	p.layout_axis = .Y
	if ui.parent(p) {
		ch := app.view.channel != 0 ? dc.channel_get(store(), app.view.channel) : nil
		if ch == nil {
			friends_page()
			return
		}
		chat_header(ch)
		body := row("chatbody")
		body.semantic_size = {.X = ui.pct(1), .Y = ui.fill()}
		body.cross_align = .Start
		if ui.parent(body) {
			if ch.kind == .Guild_Forum || ch.kind == .Guild_Media do forum_view(ch)
			else do chat_view(ch.id)
			if search_panel_open() do search_panel()
			else if ch.guild_id != 0 && app.view.show_members && !dc.is_thread(ch) do member_list(ch)
			else if ch.kind == .Group_DM && app.view.show_members do group_dm_members(ch)
			else if ch.kind == .DM && !app.view.hide_dm_profile && len(ch.recipient_ids) == 1 do dm_profile_panel(ch.recipient_ids[0])
		}
	}
}

chat_header :: proc(ch: ^dc.Channel) {
	h := row("header", {.Draw_Background})
	h.semantic_size = {.X = ui.pct(1), .Y = ui.px(HEADER_H - 1)}
	h.style.bg = T("--background-base-lower")
	if ui.parent(h) {
		spacer(.X, 16)
		if ch.kind == .DM || ch.kind == .Group_DM {
			if ch.kind == .DM && len(ch.recipient_ids) > 0 {
				avatar_box("av", ch.recipient_ids[0], 20)
				spacer(.X, 8)
			}
			label(dm_name(ch), .Medium, 16, T("--text-strong"), 20)
		} else {
			thread_header_prefix(ch)
			icon("hash", channel_icon_name(ch), 20, T("--channel-icon"))
			spacer(.X, 8)
			label(ch.name, .Medium, 16, T("--text-strong"), 20)
			if ch.topic != "" {
				spacer(.X, 12)
				d := ui.box("div", {.Draw_Background})
				d.semantic_size = {.X = ui.px(1), .Y = ui.px(24)}
				d.style.bg = T("--border-subtle")
				spacer(.X, 12)
				t := label(first_line(ch.topic), .Medium, 14, T("--text-muted"), 18)
				t.flags += {.Clip}
			}
		}
		filler(.X)
		tools := []string{"thread", "bell", "pin", "group"}
		if ch.guild_id == 0 do tools = {"phone-call", "video", "pin", "group-plus", "user-circle"}
		if ch.kind == .Group_DM do tools = {"phone-call", "video", "pin", "group-plus", "group"} // member list toggle
		for name in tools {
			b := ui.box(name, {.Clickable})
			b.semantic_size = {.X = ui.px(HEADER_TOOL_W), .Y = ui.px(24)}
			b.layout_axis = .X
			b.cross_align = .Center
			sig := ui.signal(b)
			active := (name == "group" && app.view.show_members) || (name == "user-circle" && !app.view.hide_dm_profile)
			color := sig.hovering || active ? T("--interactive-icon-hover") : T("--icon-muted")
			if ui.parent(b) {
				spacer(.X, (HEADER_TOOL_W - 20) / 2)
				icon("i", name, 20, color)
			}
			if sig.clicked && name == "group" do app.view.show_members = !app.view.show_members
			if sig.clicked && name == "user-circle" do app.view.hide_dm_profile = !app.view.hide_dm_profile
			if sig.clicked && name == "pin" do pins_toggle(ch.id, b.rect)
			if sig.clicked && name == "group-plus" && ch.kind == .DM do group_dm_popout_open(b.rect, ch.id)
		}
		spacer(.X, 8)
		search_hint := ch.name
		if ch.guild_id != 0 {
			if g := dc.guild_get(store(), ch.guild_id); g != nil do search_hint = g.name
		} else if ch.kind == .DM && len(ch.recipient_ids) > 0 {
			if u := dc.user_get(store(), ch.recipient_ids[0]); u != nil do search_hint = u.username
		} else {
			search_hint = dm_name(ch)
		}
		search_box(ch, fmt.tprintf("Search %s", search_hint))
		spacer(.X, 8)
	}
	line := ui.box("hline", {.Draw_Background})
	line.semantic_size = {.X = ui.pct(1), .Y = ui.px(1)}
	line.style.bg = T("--border-subtle")
}

first_line :: proc(s: string) -> string {
	if i := strings.index_byte(s, '\n'); i >= 0 do return s[:i]
	return s
}

channel_icon_name :: proc(ch: ^dc.Channel) -> string {
	#partial switch ch.kind {
	case .Guild_Voice:
		return "voice-normal"
	case .Guild_Announcement:
		return "announcements"
	case .Guild_Forum, .Guild_Media:
		return "forum"
	case .Guild_Stage_Voice:
		return "stage"
	case .Public_Thread, .Private_Thread, .Announcement_Thread:
		return "thread"
	}
	return "text"
}

channel_sidebar :: proc(gid: dc.Snowflake) {
	s := store()
	g := dc.guild_get(s, gid)
	if g == nil do return
	hdr := row("guildheader", {.Clickable, .Draw_Background, .Hot_Animation})
	hdr.semantic_size = {.X = ui.pct(1), .Y = ui.px(HEADER_H - 1)}
	hdr.style.bg_hot = T("--background-mod-subtle")
	ui.signal(hdr)
	if ui.parent(hdr) {
		spacer(.X, 16)
		label(ellipsize(g.name, .Semibold, 16, GUILD_NAME_MAX_W), .Semibold, 16, T("--text-strong"), 20)
		spacer(.X, 5)
		icon("chev", "chevron-small-down", 18, T("--interactive-icon-hover"))
		filler(.X)
		icon("invite", "group-plus", 20, T("--interactive-icon-hover"))
		spacer(.X, 14)
	}
	line := ui.box("hline", {.Draw_Background})
	line.semantic_size = {.X = ui.pct(1), .Y = ui.px(1)}
	line.style.bg = T("--border-subtle")

	list := ui.box("channels", {.Scroll_Y, .Clip})
	list.semantic_size = {.X = ui.pct(1), .Y = ui.fill()}
	list.layout_axis = .Y
	ui.signal(list)
	if ui.parent(list) {
		spacer(.Y, 12)
		guild_action_row("events", "calendar", "Events")
		guild_action_row("boosts", "boost-gem", "Server Boosts")
		spacer(.Y, 11)
		sep := row("sep")
		sep.semantic_size = {.X = ui.pct(1), .Y = ui.px(1)}
		if ui.parent(sep) {
			spacer(.X, 16)
			l := ui.box("l", {.Draw_Background})
			l.semantic_size = {.X = ui.fill(), .Y = ui.px(1)}
			l.style.bg = T("--border-subtle")
			spacer(.X, 16)
		}
		for cid in dc.guild_channels_sorted(s, gid) {
			ch := dc.channel_get(s, cid)
			if ch == nil do continue
			if ui.id_scope(u64(cid)) {
				if ch.kind == .Guild_Category {
					category_row(ch)
					continue
				}
				if ch.parent_id != 0 && app.view.collapsed[ch.parent_id] && cid != app.view.channel do continue
				if dc.is_thread(ch) do continue // drawn under their parent
				channel_row(ch, gid)
				sidebar_thread_rows(ch, gid)
			}
		}
		spacer(.Y, USER_PANEL_H + voice_panel_height() + 16)
	}
}

// "Events" / "Server Boosts" rows above the channel list (32px on a 34px pitch).
guild_action_row :: proc(id, icon_name, text: string) {
	outer := row(id)
	outer.semantic_size = {.X = ui.pct(1), .Y = ui.px(CHANNEL_ROW_PITCH)}
	if ui.parent(outer) {
		spacer(.X, 8)
		item := row("item", {.Clickable, .Draw_Background, .Hot_Animation})
		item.semantic_size = {.X = ui.fill(), .Y = ui.px(CHANNEL_ROW_H)}
		item.style.radius = 8
		item.style.bg_hot = T("--background-mod-subtle")
		sig := ui.signal(item)
		color := sig.hovering ? T("--interactive-text-hover") : T("--channels-default")
		if ui.parent(item) {
			spacer(.X, 8)
			icon("ic", icon_name, 20, color)
			spacer(.X, 8)
			label(text, .Medium, 16, color, 20)
		}
		spacer(.X, 9)
	}
}

// Category: 16px gap, then a 24px row (14px medium name, chevron, "create channel" plus).
category_row :: proc(ch: ^dc.Channel) {
	spacer(.Y, CATEGORY_GAP)
	r := row("cat", {.Clickable})
	r.semantic_size = {.X = ui.pct(1), .Y = ui.px(CATEGORY_ROW_H)}
	sig := ui.signal(r)
	collapsed := app.view.collapsed[ch.id]
	if sig.clicked do app.view.collapsed[ch.id] = !collapsed
	color := sig.hovering ? T("--interactive-text-hover") : T("--channels-default")
	if ui.parent(r) {
		spacer(.X, 16)
		label(ch.name, .Medium, 14, color, 18)
		spacer(.X, 4)
		icon("chev", collapsed ? "chevron-small-right" : "chevron-small-down", 12, color)
		filler(.X)
		icon("plus", "plus-small", 18, T("--interactive-icon-default"))
		spacer(.X, 16)
	}
}

channel_row :: proc(ch: ^dc.Channel, gid: dc.Snowflake) {
	selected := app.view.channel == ch.id
	unread := dc.channel_unread(store(), ch.id)
	outer := row("chan")
	outer.semantic_size = {.X = ui.pct(1), .Y = ui.px(CHANNEL_ROW_PITCH)}
	if ui.parent(outer) {
		spacer(.X, 8)
		item := row("item", {.Clickable, .Draw_Background, .Hot_Animation})
		item.semantic_size = {.X = ui.fill(), .Y = ui.px(CHANNEL_ROW_H)}
		item.style.radius = 8
		item.style.bg = selected ? T("--background-mod-normal") : {}
		item.style.bg_hot = selected ? item.style.bg : T("--background-mod-subtle")
		sig := ui.signal(item)
		if sig.clicked {
			if ch.kind == .Guild_Voice || ch.kind == .Guild_Stage_Voice {
				join_voice(gid, ch.id)
			} else {
				select_channel(gid, ch.id)
			}
		}
		color := T("--channels-default")
		if selected || unread {
			color = T("--interactive-text-active")
		} else if sig.hovering {
			color = T("--interactive-text-hover")
		}
		if ui.parent(item) {
			spacer(.X, 8)
			icon("ic", channel_icon_name(ch), 20, selected || sig.hovering ? color : T("--channel-icon"))
			spacer(.X, 8)
			label(ch.name, unread || selected ? .Semibold : .Medium, 16, color, 20)
			filler(.X)
			if selected || sig.hovering {
				// invite / settings, shown on the selected or hovered row
				icon("invite", "group-plus", 16, T("--interactive-icon-hover"))
				spacer(.X, 4)
				icon("settings", "settings", 16, T("--interactive-icon-hover"))
			}
			spacer(.X, 8)
		}
		if unread && !selected {
			dot := ui.box("unread", {.Draw_Background, .Floating_X, .Floating_Y})
			dot.semantic_size = {.X = ui.px(4), .Y = ui.px(8)}
			dot.fixed_pos = {0, 13}
			dot.style.bg = T("--text-strong")
			dot.style.radius = {0, 4, 0, 4}
		}
		spacer(.X, 9)
	}
	if ch.kind == .Guild_Voice {
		s := store()
		for uid, vs in s.voice_states {
			if vs.channel_id != ch.id do continue
			if ui.id_scope(u64(uid)) {
				vr := row("voiceuser", {.Clickable})
				vr.semantic_size = {.X = ui.pct(1), .Y = ui.px(32)}
				if ui.signal(vr).right_clicked do open_voice_user_menu(uid, app.ui.mouse)
				if ui.parent(vr) {
					spacer(.X, 44)
					voice_avatar("av", uid, 24, T("--background-base-lower"))
					spacer(.X, 8)
					name := "unknown"
					if u := dc.user_get(s, uid); u != nil do name = dc.display_name(u)
					label(name, .Medium, 14, T("--channels-default"), 18)
				}
			}
		}
	}
}

user_panel :: proc() {
	s := store()
	vh := voice_panel_height()
	panel := ui.box("userpanel", {.Draw_Background, .Draw_Border, .Floating_X, .Floating_Y})
	panel.layout_axis = .Y
	panel.semantic_size = {.X = ui.px(359), .Y = ui.px(USER_PANEL_H + vh)}
	panel.fixed_pos = {8, app.ui.window.y - USER_PANEL_H - vh - 8}
	panel.style.bg = T("--background-base-low")
	panel.style.border_color = T("--border-muted")
	panel.style.border = 1
	panel.style.radius = 8
	if ui.parent(panel) {
		if vh > 0 do voice_panel()
		p := row("userrow")
		p.semantic_size = {.X = ui.pct(1), .Y = ui.px(USER_PANEL_H)}
		if ui.parent(p) {
			spacer(.X, 8)
			who := row("who", {.Clickable, .Draw_Background, .Hot_Animation})
			who.semantic_size = {.X = ui.fill(), .Y = ui.px(42)}
			who.style.radius = 8
			who.style.bg_hot = T("--background-mod-subtle")
			ui.signal(who)
			if ui.parent(who) {
				spacer(.X, 4)
				avatar_with_status("av", s.me, 32, T("--background-base-low"))
				spacer(.X, 8)
				names := ui.box("names")
				names.semantic_size = {.X = ui.fill(), .Y = ui.children()}
				if ui.parent(names) {
					name := "…"
					if u := dc.user_get(s, s.me); u != nil do name = dc.display_name(u)
					label(name, .Medium, 14, T("--text-strong"), 18)
					status := status_text(user_status(s.me))
					if s.settings.custom_status_text != "" do status = s.settings.custom_status_text
					label(status, .Normal, 12, T("--text-muted"), 14)
				}
			}
			for name in ([]string{"microphone", "headphones", "settings"}) {
				// mic / headphones carry a device-menu chevron (official: 54px wide, 3px apart)
				has_chev := name != "settings"
				b := ui.box(name, {.Clickable, .Draw_Background, .Hot_Animation})
				b.semantic_size = {.X = ui.px(has_chev ? 54 : 32), .Y = ui.px(32)}
				b.style.radius = 8
				b.style.bg_hot = T("--background-mod-subtle")
				b.layout_axis = .X
				b.cross_align = .Center
				sig := ui.signal(b)
				ic := name
				muted := (name == "microphone" && app.self_mute) || (name == "headphones" && app.self_deaf)
				if muted do ic = strings.concatenate({name, "-slash"}, context.temp_allocator)
				if ui.parent(b) {
					spacer(.X, 6)
					color := muted ? T("--status-danger") : (sig.hovering ? T("--interactive-icon-hover") : T("--interactive-icon-default"))
					icon("i", ic, 20, color)
					if has_chev {
						spacer(.X, 7)
						icon("chev", "chevron-small-down", 16, sig.hovering ? T("--interactive-icon-hover") : T("--interactive-icon-default"))
					}
				}
				if has_chev do spacer(.X, 3)
				if sig.clicked {
					switch name {
					case "microphone":
						app.self_mute = !app.self_mute
					case "headphones":
						app.self_deaf = !app.self_deaf
					case "settings":
						app.settings_open = true
					}
				}
			}
			spacer(.X, 13)
		}
	}
}

status_text :: proc(st: dc.Status) -> string {
	switch st {
	case .Online:
		return "Online"
	case .Idle:
		return "Idle"
	case .Dnd:
		return "Do Not Disturb"
	case .Invisible:
		return "Invisible"
	case .Offline:
		return "Offline"
	}
	return "Online"
}

status_color :: proc(st: dc.Status) -> ui.Color {
	switch st {
	case .Online:
		return T("--icon-status-online")
	case .Idle:
		return T("--icon-status-idle")
	case .Dnd:
		return T("--icon-status-dnd")
	case .Offline, .Invisible:
		return T("--icon-status-offline")
	}
	return T("--icon-status-offline")
}

user_status :: proc(uid: dc.Snowflake) -> dc.Status {
	s := store()
	if uid == s.me {
		#partial switch s.settings.status {
		case .Invisible:
			return .Offline
		case .Idle, .Dnd:
			return s.settings.status
		}
		return .Online
	}
	if p, ok := s.presences[uid]; ok do return p.status
	return .Offline
}

// Tooltip to the right of the current parent (guild names on the rail).
tooltip_right :: proc(text: string) {
	tip := row("tooltip", {.Draw_Background, .Draw_Shadow, .Floating_X, .Floating_Y, .Overlay})
	tip.semantic_size = {.X = ui.children(), .Y = ui.px(36)}
	tip.fixed_pos = {16 + GUILD_ICON + 12, (GUILD_ICON - 36) / 2}
	tip.style.bg = T("--background-surface-highest")
	tip.style.radius = 8
	tip.style.shadow_color = {0, 0, 0, 0.3}
	tip.style.shadow_blur = 8
	tip.style.shadow_offset = {0, 4}
	if ui.parent(tip) {
		spacer(.X, 12)
		label(text, .Semibold, 16, T("--text-strong"), 20)
		spacer(.X, 12)
	}
}

join_voice :: proc(gid, cid: dc.Snowflake) {
	voice_join_channel(gid, cid)
}

overlays :: proc() {
	picker_overlay()
	group_dm_overlay()
	profile_full_overlay()
	for &e in app.ui.events {
		if !e.consumed && e.kind == .Key_Down && e.key == .K && .Cmd in e.mods {
			switcher_toggle()
			e.consumed = true
		}
	}
	if sw.open do quick_switcher()
	if ma.menu_msg != 0 do message_menu()
	if ma.deleting != 0 do delete_modal()
	if app.profile_user != 0 do profile_popout()
	if viewer_url != "" do image_viewer()
	if app.settings_open do settings_modal()
	voice_user_menu()
	pins_popout()
	search_suggestions()
}
