package app

import "core:fmt"
import "core:strings"
import dc "fc:discord"
import "fc:ui"

// Server menus and notification controls, like the official 0.0.419 client's:
//   - guild header dropdown (icons on the left): Invite to Server, Create Channel
//     (Manage Channels), Notification Settings (modal), Hide Muted Channels, Leave
//     Server (not the owner). Items that would be dead here (Server Boost, Server
//     Settings, Create Category / Event, App Directory, Privacy Settings, Edit
//     Per-server Profile) are left out. Opening it sends guild_dropdown_menu_viewed.
//   - guild icon context menu (rail right-click): Mark As Read | Invite to Server |
//     Mute Server > durations / Unmute Server, Notification Settings > levels,
//     Hide Muted Channels | Create Channel | Leave Server
//   - Notification Settings modal: "Mute <guild>" switch, server level radios,
//     suppress switches, Done (each control saves at once; Done sends nothing)
//   - Leave Server confirm modal; "Invite friends to <server>" modal
//   - channel header bell menu: Mute / Unmute Channel and the channel's level
//   - sidebar thread row right-click: Mark As Read, Copy Link, Delete Thread
//     (thread owner or Manage Threads; confirm in view_guild_admin.odin)
// Library side (requests, science, store updates): src/discord/guild_settings.odin.

@(private = "file")
Sub :: enum u8 {
	None,
	Mute,
	Notify,
}

@(private = "file")
Guild_Menu_State :: struct {
	// header dropdown
	menu_guild:   dc.Snowflake,
	menu_anchor:  ui.Rect,
	sub:          Sub,
	sub_y:        f32, // top of the item the submenu hangs from
	// Leave Server confirm
	leave_guild:  dc.Snowflake,
	leaving:      dc.Snowflake, // DELETE sent: go home when its GUILD_DELETE removes the guild
	// invite modal
	inv_guild:    dc.Snowflake,
	inv_channel:  dc.Snowflake,
	inv_location: string, // static: dc.INVITE_LOC_*
	inv_tag:      u64,
	inv_loading:  bool,
	inv_failed:   bool,
	inv_copied:   bool,
	inv_code:     [64]u8,
	inv_code_len: int,
	// channel bell popout
	bell_channel: dc.Snowflake,
	bell_anchor:  ui.Rect,
	bell_sub:     Sub,
	bell_sub_y:   f32,
	// guild icon context menu
	ctx_guild:    dc.Snowflake,
	ctx_pos:      ui.Vec2,
	ctx_sub:      Sub,
	ctx_sub_y:    f32,
	// Notification Settings modal
	nm_guild:     dc.Snowflake,
	// sidebar thread row menu
	thread_menu:  dc.Snowflake,
	thread_pos:   ui.Vec2,
}

@(private = "file")
gm: Guild_Menu_State

GM_MENU_W :: 220 // header dropdown
GM_CTX_W :: 188 // context menus (guild icon, channel bell)
GM_SUB_W :: 220
GM_ROW_H :: 32
GM_HDR_ROW_H :: 36

guild_menu_toggle :: proc(gid: dc.Snowflake, anchor: ui.Rect) {
	if gm.menu_guild == gid {
		gm.menu_guild = 0
		return
	}
	gm.menu_guild = gid
	gm.menu_anchor = anchor
	gm.sub = .None
	if app.client != nil do dc.track_guild_dropdown_viewed(app.client, gid)
}

// Rail guild icon right-click.
guild_context_open :: proc(gid: dc.Snowflake, at: ui.Vec2) {
	gm.ctx_guild = gid
	gm.ctx_pos = at
	gm.ctx_sub = .None
}

guild_notify_modal_open :: proc(gid: dc.Snowflake) {gm.nm_guild = gid}

// "Hide Muted Channels" (device-local, per guild)
hide_muted_toggle :: proc(gid: dc.Snowflake) {
	app.view.hide_muted[gid] = !app.view.hide_muted[gid] // saved by settings_frame
}

bell_popout_toggle :: proc(cid: dc.Snowflake, anchor: ui.Rect) {
	if gm.bell_channel == cid {
		gm.bell_channel = 0
		return
	}
	gm.bell_channel = cid
	gm.bell_anchor = anchor
	gm.bell_sub = .None
}

// The channel an invite from the server header points at: the open channel when
// it belongs to the guild, else the first text channel.
@(private = "file")
invite_channel_for :: proc(gid: dc.Snowflake) -> dc.Snowflake {
	s := store()
	if ch := dc.channel_get(s, app.view.channel); ch != nil && ch.guild_id == gid && !dc.is_thread(ch) && ch.kind != .Guild_Category do return ch.id
	for id in dc.guild_channels_sorted(s, gid) {
		if c := dc.channel_get(s, id); c != nil && (c.kind == .Guild_Text || c.kind == .Guild_Announcement) do return id
	}
	return 0
}

// Opens the invite modal and asks for an invite to `cid` (0: the server's default).
// location: the entry point (dc.INVITE_LOC_*), a static string.
invite_open :: proc(gid, cid: dc.Snowflake, location: string) {
	ch := cid != 0 ? cid : invite_channel_for(gid)
	gm.inv_guild = gid
	gm.inv_channel = ch
	gm.inv_location = location
	gm.inv_code_len = 0
	gm.inv_copied = false
	gm.inv_failed = false
	gm.inv_tag += 1
	gm.inv_loading = false
	if net_action() {
		gm.inv_loading = ch != 0
		dc.open_invite_modal(app.client, gid, ch, location, gm.inv_tag)
	}
}

invite_modal_open :: proc() -> bool {return gm.inv_guild != 0 || gm.leave_guild != 0 || gm.nm_guild != 0}

invite_receive :: proc(r: dc.Rest_Result) {
	if r.tag != gm.inv_tag || gm.inv_guild == 0 do return
	gm.inv_loading = false
	code := r.ok ? dc.invite_code_for(app.client, r.channel_id) : ""
	if code == "" || len(code) > len(gm.inv_code) {
		gm.inv_failed = true
	} else {
		copy(gm.inv_code[:], code)
		gm.inv_code_len = len(code)
	}
	app.ui.animating = true
}

@(private = "file")
invite_url :: proc() -> string {
	if gm.inv_code_len == 0 do return ""
	return strings.concatenate({"https://discord.gg/", string(gm.inv_code[:gm.inv_code_len])}, context.temp_allocator)
}

// Overlay pass entry (views.odin overlays()).
thread_menu_open :: proc(tid: dc.Snowflake, at: ui.Vec2) {
	gm.thread_menu = tid
	gm.thread_pos = at
}

guild_menu_overlays :: proc() {
	if gm.thread_menu != 0 do thread_menu()
	if gm.menu_guild != 0 do guild_menu()
	if gm.ctx_guild != 0 do guild_context_menu()
	if gm.bell_channel != 0 do bell_popout()
	if gm.nm_guild != 0 do notify_modal()
	if gm.leaving != 0 && dc.guild_get(store(), gm.leaving) == nil {
		// the client routes to Friends once the guild is gone (fixture join_leave_server)
		if app.view.guild == gm.leaving do go_home()
		gm.leaving = 0
	}
	if gm.leave_guild != 0 do leave_modal()
	if gm.inv_guild != 0 do invite_modal()
}

// ---- shared menu pieces ----

menu_panel :: proc(id: string, pos: ui.Vec2, w: f32) -> ^ui.Box {
	p := ui.box(id, {.Draw_Background, .Draw_Border, .Draw_Shadow, .Floating_X, .Floating_Y, .Overlay, .Clickable})
	p.semantic_size = {.X = ui.px(w), .Y = ui.children()}
	p.fixed_pos = pos
	p.layout_axis = .Y
	p.style.bg = T("--background-surface-higher")
	p.style.border_color = T("--border-subtle")
	p.style.border = 1
	p.style.radius = 8
	p.style.shadow_color = {0, 0, 0, 0.24}
	p.style.shadow_blur = 16
	p.style.shadow_offset = {0, 8}
	ui.signal(p)
	return p
}

Item_Right :: enum u8 {
	None,
	Icon,
	Chevron,
	Radio_Off,
	Radio_On,
	Check_Off,
	Check_On,
}

// One menu row (inside an 8px-padded menu column): label, optional sublabel,
// and an icon / chevron / radio / checkbox on the right.
menu_item :: proc(id, text: string, right: Item_Right = .None, icon_name := "", sub := "", danger := false, brand := false, open := false, disabled := false, lead := "", h: f32 = GM_ROW_H) -> ui.Signal {
	outer := row(id)
	outer.semantic_size = {.X = ui.pct(1), .Y = ui.children()}
	sig: ui.Signal
	if ui.parent(outer) {
		spacer(.X, 8)
		flags := ui.Box_Flags{.Clickable, .Draw_Background, .Hot_Animation}
		if disabled do flags += {.Disabled}
		r := row("it", flags)
		r.semantic_size = {.X = ui.fill(), .Y = ui.px(sub != "" ? 44 : h)}
		r.style.radius = 4
		r.style.bg_hot = danger ? T("--status-danger") : T("--background-mod-normal")
		if open do r.style.bg = T("--background-mod-normal")
		sig = disabled ? {} : ui.signal(r)
		hot := sig.hovering || open
		color := T("--interactive-text-default")
		if hot do color = T("--interactive-text-active")
		if danger do color = hot ? {1, 1, 1, 1} : T("--text-feedback-critical")
		if brand && !hot do color = T("--text-brand")
		if disabled do color = with_alpha(T("--interactive-text-default"), 0.5)
		if ui.parent(r) {
			spacer(.X, 8)
			if lead != "" {
				icon("lead", lead, 20, color)
				spacer(.X, 8)
			}
			col := ui.box("col")
			col.semantic_size = {.X = ui.fill(), .Y = ui.children()}
			col.layout_axis = .Y
			if ui.parent(col) {
				label(text, .Medium, 14, color, 18)
				if sub != "" do label(sub, .Normal, 12, hot && danger ? color : T("--text-muted"), 16)
			}
			brand_c := T("--background-brand")
			switch right {
			case .None:
			case .Icon:
				icon("ic", icon_name, 18, color)
			case .Chevron:
				icon("ic", "chevron-small-right", 18, color)
			case .Radio_Off, .Radio_On:
				on := right == .Radio_On
				rb := ui.box("radio", {.Draw_Border})
				rb.semantic_size = {.X = ui.px(18), .Y = ui.px(18)}
				rb.style.radius = 9
				rb.style.border = 2
				rb.style.border_color = on ? brand_c : T("--interactive-icon-default")
				if on do if ui.parent(rb) {
					dot := ui.box("dot", {.Draw_Background, .Floating_X, .Floating_Y})
					dot.semantic_size = {.X = ui.px(8), .Y = ui.px(8)}
					dot.fixed_pos = {5, 5}
					dot.style.radius = 4
					dot.style.bg = brand_c
				}
			case .Check_Off, .Check_On:
				on := right == .Check_On
				cb := ui.box("cb", {.Draw_Background, .Draw_Border})
				cb.semantic_size = {.X = ui.px(18), .Y = ui.px(18)}
				cb.style.radius = 4
				cb.style.border = on ? 0 : 1.5
				cb.style.border_color = T("--interactive-icon-default")
				cb.style.bg = on ? brand_c : {}
				if on do if ui.parent(cb) do icon("ck", "checkmark-small-bold", 18, {1, 1, 1, 1})
			}
			spacer(.X, 8)
		}
		spacer(.X, 8)
	}
	return sig
}

menu_sep :: proc(id: string) {
	spacer(.Y, 4)
	r := row(id)
	r.semantic_size = {.X = ui.pct(1), .Y = ui.px(1)}
	if ui.parent(r) {
		spacer(.X, 12)
		l := ui.box("l", {.Draw_Background})
		l.semantic_size = {.X = ui.fill(), .Y = ui.px(1)}
		l.style.bg = T("--border-subtle")
		spacer(.X, 12)
	}
	spacer(.Y, 4)
}

// Transparent full-window box under a popout: a press outside closes it.
outside_pressed :: proc(id: string) -> bool {
	scrim := ui.box(id, {.Clickable, .Floating_X, .Floating_Y, .Overlay})
	scrim.semantic_size = {.X = ui.px(app.ui.window.x), .Y = ui.px(app.ui.window.y)}
	return ui.signal(scrim).pressed
}

escape_pressed :: proc() -> bool {
	// also when the composer took it (it keeps focus under a popout)
	for &e in app.ui.events {
		if e.kind == .Key_Down && e.key == .Escape {
			e.consumed = true
			return true
		}
	}
	return false
}

MUTE_CHOICES := [?]struct {
	text:    string,
	seconds: int,
} {
	{"For 15 Minutes", 15 * 60},
	{"For 1 Hour", 3600},
	{"For 3 Hours", 3 * 3600},
	{"For 8 Hours", 8 * 3600},
	{"For 24 Hours", 24 * 3600},
	{"Until I turn it back on", dc.MUTE_FOREVER},
}

NOTIFY_NAMES := [3]string{"All Messages", "Only @mentions", "Nothing"}

// "Muted until 10/26, 3:23 PM" (local time) or "" for an indefinite mute.
@(private = "file")
muted_until :: proc(end_ms: i64) -> string {
	if end_ms == 0 do return ""
	local := end_ms + local_offset_ms()
	days := local / 86_400_000
	if local < 0 do days -= 1
	mins := (local - days * 86_400_000) / 60000
	h := int(mins / 60)
	m := int(mins % 60)
	h12 := h % 12
	if h12 == 0 do h12 = 12
	y, mo, d := civil_from_days(days)
	_ = y
	return fmt.tprintf("Muted until %d/%d, %d:%02d %s", mo, d, h12, m, h < 12 ? "AM" : "PM")
}

// days since 1970-01-01 -> (year, month 1-12, day 1-31) (H. Hinnant's algorithm)
@(private = "file")
civil_from_days :: proc(z_in: i64) -> (y, m, d: int) {
	z := z_in + 719468
	era := (z >= 0 ? z : z - 146096) / 146097
	doe := z - era * 146097
	yoe := (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
	doy := doe - (365 * yoe + yoe / 4 - yoe / 100)
	mp := (5 * doy + 2) / 153
	d = int(doy - (153 * mp + 2) / 5 + 1)
	m = int(mp < 10 ? mp + 3 : mp - 9)
	y = int(yoe + era * 400 + (m <= 2 ? 1 : 0))
	return
}

// Mute duration list; returns the chosen seconds (0 = none).
@(private = "file")
mute_submenu :: proc(id: string, pos: ui.Vec2) -> (seconds: int) {
	p := menu_panel(id, pos, 220)
	if ui.parent(p) {
		spacer(.Y, 8)
		for c in MUTE_CHOICES {
			if menu_item(c.text, c.text).clicked do seconds = c.seconds
		}
		spacer(.Y, 8)
	}
	return
}

// Submenu x: right of the menu, or left of it near the window edge.
@(private = "file")
sub_x :: proc(menu: ^ui.Box) -> f32 {
	x := menu.rect.x1 + 4
	if x + GM_SUB_W > app.ui.window.x - 8 do x = menu.rect.x0 - 4 - GM_SUB_W
	return x
}

@(private = "file")
sub_y :: proc(y: f32, h: f32) -> f32 {
	return clamp(y - 8, 8, max(8, app.ui.window.y - h - 8))
}

// ---- guild header dropdown ----

@(private = "file")
guild_menu :: proc() {
	s := store()
	gid := gm.menu_guild
	g := dc.guild_get(s, gid)
	if g == nil || app.view.guild != gid {
		gm.menu_guild = 0
		return
	}
	if outside_pressed("gmenu_scrim") || escape_pressed() {
		gm.menu_guild = 0
		return
	}
	close := false
	W :: f32(GM_MENU_W)
	a := gm.menu_anchor
	pos := ui.Vec2{a.x0 + ((a.x1 - a.x0) - W) / 2, a.y1 + 4}
	menu := menu_panel("gmenu", pos, W)
	if ui.parent(menu) {
		spacer(.Y, 8)
		if menu_item("invite", "Invite to Server", lead = "user-plus", h = GM_HDR_ROW_H).clicked {
			invite_open(gid, 0, dc.INVITE_LOC_HEADER)
			close = true
		}
		if can_manage_channels(gid) {
			if menu_item("createchan", "Create Channel", lead = "circle-plus", h = GM_HDR_ROW_H).clicked {
				create_channel_open(gid, 0)
				close = true
			}
		}
		menu_sep("s1")
		if menu_item("notify", "Notification Settings", lead = "bell", h = GM_HDR_ROW_H).clicked {
			gm.nm_guild = gid
			close = true
		}
		menu_sep("s2")
		hide := app.view.hide_muted[gid]
		if menu_item("hidemuted", "Hide Muted Channels", hide ? .Check_On : .Check_Off, lead = "eye-slash", h = GM_HDR_ROW_H).clicked {
			hide_muted_toggle(gid)
		}
		if g.owner_id != s.me {
			menu_sep("s3")
			if menu_item("leave", "Leave Server", lead = "door-exit", danger = true, h = GM_HDR_ROW_H).clicked {
				gm.leave_guild = gid
				close = true
			}
		}
		spacer(.Y, 8)
	}
	if close do gm.menu_guild = 0
}

// ---- guild icon context menu (rail) ----

@(private = "file")
guild_context_menu :: proc() {
	s := store()
	gid := gm.ctx_guild
	g := dc.guild_get(s, gid)
	if g == nil {
		gm.ctx_guild = 0
		return
	}
	if outside_pressed("gctx_scrim") || escape_pressed() {
		gm.ctx_guild = 0
		return
	}
	now := wall_ms()
	close := false
	gs := dc.guild_settings_get(s, gid)
	muted := dc.guild_is_muted(s, gid, now)
	level := dc.guild_notify_level(s, gid)
	W :: f32(GM_CTX_W)
	// below-right of the pointer, kept inside the window (height from last frame)
	pos := gm.ctx_pos
	menu := menu_panel("gctx", pos, W)
	h := menu.rect.y1 - menu.rect.y0
	menu.fixed_pos = {clamp(pos.x, 8, app.ui.window.x - W - 8), clamp(pos.y, 8, max(8, app.ui.window.y - h - 8))}
	hover_sub := Sub.None
	hover_any := false
	if ui.parent(menu) {
		spacer(.Y, 8)
		if sig := menu_item("read", "Mark As Read", disabled = !guild_has_unread(gid)); sig.clicked {
			if net_action() do dc.ack_guild(app.client, gid)
			close = true
		} else if sig.hovering do hover_any = true
		menu_sep("s1")
		if sig := menu_item("invite", "Invite to Server"); sig.clicked {
			// not captured from the rail menu: the header menu's location is the closest known one
			invite_open(gid, 0, dc.INVITE_LOC_HEADER)
			close = true
		} else if sig.hovering do hover_any = true
		menu_sep("s2")
		if muted {
			end: i64 = gs != nil ? gs.mute_end_ms : 0
			if sig := menu_item("mute", "Unmute Server", sub = muted_until(end)); sig.clicked {
				if net_action() do dc.set_guild_muted(app.client, gid, false, now_ms = now)
				close = true
			} else if sig.hovering do hover_any = true
		} else {
			it := menu_item("mute", "Mute Server", .Chevron, open = gm.ctx_sub == .Mute)
			if it.hovering do hover_sub = .Mute
			if it.clicked do gm.ctx_sub = .Mute
			if it.hovering || it.clicked do gm.ctx_sub_y = it.box.rect.y0
		}
		nt := menu_item("notify", "Notification Settings", .Chevron, sub = NOTIFY_NAMES[clamp(level, 0, 2)], open = gm.ctx_sub == .Notify)
		if nt.hovering do hover_sub = .Notify
		if nt.clicked do gm.ctx_sub = .Notify
		if nt.hovering || nt.clicked do gm.ctx_sub_y = nt.box.rect.y0
		hide := app.view.hide_muted[gid]
		if sig := menu_item("hidemuted", "Hide Muted Channels", hide ? .Check_On : .Check_Off); sig.clicked {
			hide_muted_toggle(gid)
		} else if sig.hovering do hover_any = true
		if can_manage_channels(gid) {
			menu_sep("s3")
			if sig := menu_item("createchan", "Create Channel"); sig.clicked {
				create_channel_open(gid, 0)
				close = true
			} else if sig.hovering do hover_any = true
		}
		if g.owner_id != s.me {
			menu_sep("s4")
			if sig := menu_item("leave", "Leave Server", danger = true); sig.clicked {
				gm.leave_guild = gid
				close = true
			} else if sig.hovering do hover_any = true
		}
		spacer(.Y, 8)
	}
	// hovering a submenu row opens it; hovering another row closes it
	if hover_sub != .None && hover_sub != gm.ctx_sub do gm.ctx_sub = hover_sub
	if hover_any do gm.ctx_sub = .None
	switch gm.ctx_sub {
	case .None:
	case .Mute:
		if secs := mute_submenu("gmute", {sub_x(menu), sub_y(gm.ctx_sub_y, 6 * GM_ROW_H + 16)}); secs != 0 {
			if net_action() do dc.set_guild_muted(app.client, gid, true, secs, now)
			close = true
		}
	case .Notify:
		p := menu_panel("gnotify", {sub_x(menu), sub_y(gm.ctx_sub_y, 5 * GM_ROW_H + 25)}, GM_SUB_W)
		if ui.parent(p) {
			spacer(.Y, 8)
			for name, i in NOTIFY_NAMES {
				if menu_item(name, name, level == i ? .Radio_On : .Radio_Off).clicked && level != i {
					if net_action() do dc.set_guild_notify_level(app.client, gid, i)
					close = true
				}
			}
			menu_sep("ns")
			sup := gs != nil && gs.suppress_everyone
			if menu_item("suppress", "Suppress @everyone and @here", sup ? .Check_On : .Check_Off).clicked {
				if net_action() do dc.set_guild_suppress_everyone(app.client, gid, !sup)
			}
			supr := gs != nil && gs.suppress_roles
			if menu_item("suppressroles", "Suppress All Role @mentions", supr ? .Check_On : .Check_Off).clicked {
				if net_action() do dc.set_guild_suppress_roles(app.client, gid, !supr)
			}
			spacer(.Y, 8)
		}
	}
	if close do gm.ctx_guild = 0
}

// ---- Notification Settings modal (header menu) ----

@(private = "file")
notify_modal :: proc() {
	s := store()
	gid := gm.nm_guild
	g := dc.guild_get(s, gid)
	if g == nil {
		gm.nm_guild = 0
		return
	}
	scrim := ui.box("nm_scrim", {.Draw_Background, .Clickable, .Floating_X, .Floating_Y, .Overlay})
	scrim.semantic_size = {.X = ui.px(app.ui.window.x), .Y = ui.px(app.ui.window.y)}
	scrim.style.bg = {0, 0, 0, 0.7}
	if ui.signal(scrim).clicked || escape_pressed() {
		gm.nm_guild = 0
		return
	}
	now := wall_ms()
	gs := dc.guild_settings_get(s, gid)
	muted := dc.guild_is_muted(s, gid, now)
	level := dc.guild_notify_level(s, gid)
	W :: 480
	PAD :: 24
	d := ui.box("nmodal", {.Draw_Background, .Draw_Border, .Floating_X, .Floating_Y, .Overlay, .Clickable})
	d.semantic_size = {.X = ui.px(W), .Y = ui.children()}
	d.fixed_pos = {(app.ui.window.x - W) / 2, max(8, (app.ui.window.y - (d.rect.y1 - d.rect.y0)) / 2)}
	d.style.bg = T("--modal-background")
	d.style.border_color = T("--border-subtle")
	d.style.border = 1
	d.style.radius = 12
	d.layout_axis = .Y
	ui.signal(d)
	padded :: proc(id: string) -> ^ui.Box {
		r := row(id)
		r.semantic_size = {.X = ui.pct(1), .Y = ui.children()}
		return r
	}
	hline :: proc(id: string) {
		r := row(id)
		r.semantic_size = {.X = ui.pct(1), .Y = ui.px(1)}
		if ui.parent(r) {
			spacer(.X, PAD)
			l := ui.box("l", {.Draw_Background})
			l.semantic_size = {.X = ui.fill(), .Y = ui.px(1)}
			l.style.bg = T("--border-subtle")
			spacer(.X, PAD)
		}
	}
	if ui.parent(d) {
		x := ui.box("close", {.Clickable, .Floating_X, .Floating_Y})
		x.semantic_size = {.X = ui.px(24), .Y = ui.px(24)}
		x.fixed_pos = {W - 16 - 24, 20}
		xs := ui.signal(x)
		set_icon(x, "x-large", xs.hovering ? T("--interactive-icon-hover") : T("--interactive-icon-default"))
		if xs.clicked do gm.nm_guild = 0
		spacer(.Y, 24)
		if t := padded("t"); ui.parent(t) {
			spacer(.X, PAD)
			label("Notification Settings", .Semibold, 20, T("--text-strong"), 24)
		}
		spacer(.Y, 24)
		hline("h0")
		spacer(.Y, 20)
		if m := padded("mute"); ui.parent(m) {
			spacer(.X, PAD)
			c := ui.box("c")
			c.semantic_size = {.X = ui.fill(), .Y = ui.children()}
			if ui.parent(c) {
				if set_toggle_row("mutetoggle", ellipsize(fmt.tprintf("Mute %s", g.name), .Medium, 16, W - 2 * PAD - 60), "Muting a server prevents unread indicators and notifications from appearing unless you are mentioned.", muted) {
					if net_action() do dc.set_guild_muted(app.client, gid, !muted, now_ms = now)
				}
			}
			spacer(.X, PAD)
		}
		spacer(.Y, 20)
		hline("h1")
		spacer(.Y, 24)
		if hd := padded("lvlhdr"); ui.parent(hd) {
			spacer(.X, PAD)
			label("Server Notification Settings", .Semibold, 16, T("--text-strong"), 20)
		}
		spacer(.Y, 12)
		for name, i in NOTIFY_NAMES {
			if ui.id_scope(u64(i + 1)) {
				r := row("radio", {.Clickable})
				r.semantic_size = {.X = ui.pct(1), .Y = ui.px(36)}
				sig := ui.signal(r)
				if ui.parent(r) {
					spacer(.X, PAD)
					on := level == i
					rb := ui.box("rb", {.Draw_Border})
					rb.semantic_size = {.X = ui.px(20), .Y = ui.px(20)}
					rb.style.radius = 10
					rb.style.border = 2
					rb.style.border_color = on ? T("--background-brand") : (sig.hovering ? T("--interactive-icon-hover") : T("--interactive-icon-default"))
					if on do if ui.parent(rb) {
						dot := ui.box("dot", {.Draw_Background, .Floating_X, .Floating_Y})
						dot.semantic_size = {.X = ui.px(10), .Y = ui.px(10)}
						dot.fixed_pos = {5, 5}
						dot.style.radius = 5
						dot.style.bg = T("--background-brand")
					}
					spacer(.X, 12)
					label(name, .Medium, 16, on || sig.hovering ? T("--text-strong") : T("--text-default"), 20)
				}
				if sig.clicked && level != i && net_action() do dc.set_guild_notify_level(app.client, gid, i)
			}
		}
		spacer(.Y, 20)
		hline("h2")
		spacer(.Y, 20)
		sup := gs != nil && gs.suppress_everyone
		supr := gs != nil && gs.suppress_roles
		if r := padded("sup"); ui.parent(r) {
			spacer(.X, PAD)
			c := ui.box("c")
			c.semantic_size = {.X = ui.fill(), .Y = ui.children()}
			c.layout_axis = .Y
			if ui.parent(c) {
				if set_toggle_row("supall", "Suppress @everyone and @here", "", sup) && net_action() do dc.set_guild_suppress_everyone(app.client, gid, !sup)
				spacer(.Y, 16)
				if set_toggle_row("suproles", "Suppress All Role @mentions", "", supr) && net_action() do dc.set_guild_suppress_roles(app.client, gid, !supr)
			}
			spacer(.X, PAD)
		}
		spacer(.Y, 24)
		if br := padded("done"); ui.parent(br) {
			spacer(.X, PAD)
			done := ui.box("Done##done", {.Clickable, .Draw_Background, .Draw_Text, .Hot_Animation})
			done.semantic_size = {.X = ui.fill(), .Y = ui.px(40)}
			done.style.radius = 8
			done.style.font = F(.Medium)
			done.style.font_size = 16
			done.style.text_align = .Center
			done.style.text_color = {1, 1, 1, 1}
			done.style.bg = T("--background-brand")
			done.style.bg_hot = with_alpha(T("--background-brand"), 0.85)
			if ui.signal(done).clicked do gm.nm_guild = 0
			spacer(.X, PAD)
		}
		spacer(.Y, PAD)
	}
}

// ---- Leave Server confirm ----

@(private = "file")
leave_modal :: proc() {
	gid := gm.leave_guild
	g := dc.guild_get(store(), gid)
	if g == nil {
		gm.leave_guild = 0
		return
	}
	scrim := ui.box("leave_scrim", {.Draw_Background, .Clickable, .Floating_X, .Floating_Y, .Overlay})
	scrim.semantic_size = {.X = ui.px(app.ui.window.x), .Y = ui.px(app.ui.window.y)}
	scrim.style.bg = {0, 0, 0, 0.7}
	if ui.signal(scrim).clicked || escape_pressed() {
		gm.leave_guild = 0
		return
	}
	W :: 480
	PAD :: 24
	confirm := false
	d := ui.box("leavemodal", {.Draw_Background, .Draw_Border, .Floating_X, .Floating_Y, .Overlay, .Clickable})
	d.semantic_size = {.X = ui.px(W), .Y = ui.children()}
	d.fixed_pos = {(app.ui.window.x - W) / 2, (app.ui.window.y - (d.rect.y1 - d.rect.y0)) / 2}
	d.style.bg = T("--modal-background")
	d.style.border_color = T("--border-subtle")
	d.style.border = 1
	d.style.radius = 12
	d.layout_axis = .Y
	ui.signal(d)
	if ui.parent(d) {
		x := ui.box("close", {.Clickable, .Floating_X, .Floating_Y})
		x.semantic_size = {.X = ui.px(24), .Y = ui.px(24)}
		x.fixed_pos = {W - 17 - 24, 17}
		xs := ui.signal(x)
		set_icon(x, "x-large", xs.hovering ? T("--interactive-icon-hover") : T("--interactive-icon-default"))
		if xs.clicked do gm.leave_guild = 0
		spacer(.Y, PAD + 1)
		t := row("t")
		t.semantic_size = {.X = ui.pct(1), .Y = ui.px(24)}
		if ui.parent(t) {
			spacer(.X, PAD + 1)
			label(ellipsize(fmt.tprintf("Leave '%s'", g.name), .Semibold, 20, W - 2 * PAD - 40), .Semibold, 20, T("--text-strong"), 24)
		}
		spacer(.Y, 8)
		br := row("body")
		br.semantic_size = {.X = ui.pct(1), .Y = ui.children()}
		if ui.parent(br) {
			spacer(.X, PAD + 1)
			b := ui.box("text", {.Wrap_Text})
			b.semantic_size = {.X = ui.fill(), .Y = ui.text_size()}
			b.style.line_height = 20
			b.style.text_color = T("--text-subtle")
			spans := make([]ui.Span, 3, context.temp_allocator)
			spans[0] = {text = "Are you sure you want to leave ", font = F(.Normal), size = 16}
			spans[1] = {text = g.name, font = F(.Bold), size = 16}
			spans[2] = {text = "? You won't be able to rejoin this server unless you are re-invited.", font = F(.Normal), size = 16}
			ui.set_spans(b, spans)
			spacer(.X, PAD + 1)
		}
		spacer(.Y, 24)
		btns := row("btns")
		btns.semantic_size = {.X = ui.pct(1), .Y = ui.px(40)}
		btns.style.child_gap = 8
		if ui.parent(btns) {
			spacer(.X, PAD + 1 - 8)
			cancel := ui.box("Cancel##c", {.Clickable, .Draw_Background, .Draw_Text, .Hot_Animation})
			cancel.semantic_size = {.X = ui.fill(), .Y = ui.px(40)}
			cancel.style.radius = 8
			cancel.style.font = F(.Medium)
			cancel.style.font_size = 16
			cancel.style.text_align = .Center
			cancel.style.text_color = T("--text-strong")
			cancel.style.bg = T("--background-mod-normal")
			cancel.style.bg_hot = T("--background-mod-strong")
			if ui.signal(cancel).clicked do gm.leave_guild = 0
			ok := ui.box("Leave Server##l", {.Clickable, .Draw_Background, .Draw_Text, .Hot_Animation})
			ok.semantic_size = {.X = ui.fill(), .Y = ui.px(40)}
			ok.style.radius = 8
			ok.style.font = F(.Medium)
			ok.style.font_size = 16
			ok.style.text_align = .Center
			ok.style.text_color = {1, 1, 1, 1}
			ok.style.bg = T("--status-danger")
			ok.style.bg_hot = T("--control-critical-primary-background-hover")
			if ui.signal(ok).clicked do confirm = true
			spacer(.X, PAD + 1 - 8)
		}
		spacer(.Y, PAD + 1)
	}
	if confirm {
		gm.leave_guild = 0
		if net_action() {
			dc.leave_guild(app.client, gid)
			gm.leaving = gid
		}
	}
}

// ---- invite modal ----

@(private = "file")
invite_modal :: proc() {
	s := store()
	g := dc.guild_get(s, gm.inv_guild)
	if g == nil {
		gm.inv_guild = 0
		return
	}
	scrim := ui.box("inv_scrim", {.Draw_Background, .Clickable, .Floating_X, .Floating_Y, .Overlay})
	scrim.semantic_size = {.X = ui.px(app.ui.window.x), .Y = ui.px(app.ui.window.y)}
	scrim.style.bg = {0, 0, 0, 0.7}
	esc := escape_pressed()
	if ui.signal(scrim).clicked || esc {
		if esc && app.client != nil do dc.escape_shortcut_used(app.client)
		gm.inv_guild = 0
		return
	}
	W :: 440
	PAD :: 16
	d := ui.box("invmodal", {.Draw_Background, .Draw_Border, .Floating_X, .Floating_Y, .Overlay, .Clickable})
	d.semantic_size = {.X = ui.px(W), .Y = ui.children()}
	d.fixed_pos = {(app.ui.window.x - W) / 2, (app.ui.window.y - (d.rect.y1 - d.rect.y0)) / 2}
	d.style.bg = T("--modal-background")
	d.style.border_color = T("--border-subtle")
	d.style.border = 1
	d.style.radius = 12
	d.layout_axis = .Y
	ui.signal(d)
	if ui.parent(d) {
		x := ui.box("close", {.Clickable, .Floating_X, .Floating_Y})
		x.semantic_size = {.X = ui.px(24), .Y = ui.px(24)}
		x.fixed_pos = {W - 12 - 24, 12}
		xs := ui.signal(x)
		set_icon(x, "x-large", xs.hovering ? T("--interactive-icon-hover") : T("--interactive-icon-default"))
		if xs.clicked do gm.inv_guild = 0
		spacer(.Y, 16)
		t := row("t")
		t.semantic_size = {.X = ui.pct(1), .Y = ui.px(24)}
		if ui.parent(t) {
			spacer(.X, PAD)
			label(ellipsize(fmt.tprintf("Invite friends to %s", g.name), .Semibold, 20, W - 2 * PAD - 32), .Semibold, 20, T("--text-strong"), 24)
		}
		if ch := dc.channel_get(s, gm.inv_channel); ch != nil {
			spacer(.Y, 4)
			cr := row("chan")
			cr.semantic_size = {.X = ui.pct(1), .Y = ui.px(20)}
			if ui.parent(cr) {
				spacer(.X, PAD)
				icon("ic", channel_icon_name(ch), 16, T("--text-muted"))
				spacer(.X, 4)
				label(ch.name, .Medium, 14, T("--text-muted"), 18)
			}
		}
		spacer(.Y, 20)
		lr := row("lbl")
		lr.semantic_size = {.X = ui.pct(1), .Y = ui.px(18)}
		if ui.parent(lr) {
			spacer(.X, PAD)
			label("Send a server invite link to a friend", .Semibold, 14, T("--text-default"), 18)
		}
		spacer(.Y, 8)
		fr := row("fieldrow")
		fr.semantic_size = {.X = ui.pct(1), .Y = ui.px(44)}
		if ui.parent(fr) {
			spacer(.X, PAD)
			field := row("field", {.Draw_Background, .Draw_Border})
			field.semantic_size = {.X = ui.fill(), .Y = ui.px(44)}
			field.style.bg = T("--input-background-default")
			field.style.border_color = T("--input-border-default")
			field.style.border = 1
			field.style.radius = 8
			if ui.parent(field) {
				spacer(.X, 12)
				url := invite_url()
				text, color := url, T("--text-default")
				// Streamer Mode > Hide Invite Links: the code is masked, Copy still copies it
				if url != "" && streamer_hide_invites() do text = "https://discord.gg/••••••••"
				if url == "" {
					color = T("--text-muted")
					text = "Creating an invite link…"
					if gm.inv_failed do text = "Couldn't create an invite link."
					else if !gm.inv_loading do text = "You're offline: no invite link."
				}
				tw := ui.box("tw", {.Clip})
				tw.semantic_size = {.X = ui.fill(), .Y = ui.px(20)}
				if ui.parent(tw) do label(text, .Normal, 16, color, 20)
				flags := ui.Box_Flags{.Clickable, .Draw_Background, .Draw_Text, .Hot_Animation}
				if url == "" do flags += {.Disabled}
				cb := ui.box(gm.inv_copied ? "Copied##copy" : "Copy##copy", flags)
				cb.semantic_size = {.X = ui.px(75), .Y = ui.px(32)}
				cb.style.radius = 8
				cb.style.font = F(.Medium)
				cb.style.font_size = 14
				cb.style.text_align = .Center
				cb.style.text_color = {1, 1, 1, url == "" ? 0.5 : 1}
				cb.style.bg = gm.inv_copied ? T("--status-positive") : T("--background-brand")
				cb.style.bg_hot = gm.inv_copied ? cb.style.bg : with_alpha(T("--background-brand"), 0.85)
				if url == "" do cb.style.bg = with_alpha(cb.style.bg, 0.5)
				if url != "" && ui.signal(cb).clicked {
					clipboard_set(url)
					gm.inv_copied = true
					if app.client != nil do dc.invite_copied(app.client, gm.inv_guild, gm.inv_channel, string(gm.inv_code[:gm.inv_code_len]), gm.inv_location)
				}
				spacer(.X, 6)
			}
			spacer(.X, PAD)
		}
		spacer(.Y, 8)
		ft := row("foot")
		ft.semantic_size = {.X = ui.pct(1), .Y = ui.px(16)}
		if ui.parent(ft) {
			spacer(.X, PAD)
			label("Your invite link expires in 30 days.", .Normal, 12, T("--text-muted"), 16)
		}
		spacer(.Y, 20)
	}
}

// ---- channel header bell popout ----

@(private = "file")
bell_popout :: proc() {
	s := store()
	cid := gm.bell_channel
	ch := dc.channel_get(s, cid)
	if ch == nil || cid != app.view.channel || ch.guild_id == 0 {
		gm.bell_channel = 0
		return
	}
	if outside_pressed("bell_scrim") || escape_pressed() {
		gm.bell_channel = 0
		return
	}
	gid := ch.guild_id
	now := wall_ms()
	close := false
	muted := dc.channel_is_muted(s, gid, cid, now)
	level := dc.channel_notify_level(s, gid, cid)
	// what "default" resolves to: the category's override, else the server's level
	def := dc.guild_notify_level(s, gid)
	has_cat := ch.parent_id != 0
	if has_cat {
		if cl := dc.channel_notify_level(s, gid, ch.parent_id); cl != dc.NOTIFY_INHERIT do def = cl
	}
	W :: f32(GM_CTX_W)
	a := gm.bell_anchor
	pos := ui.Vec2{clamp(a.x1 - W, 8, app.ui.window.x - W - 8), a.y1 + 8}
	menu := menu_panel("bell", pos, W)
	hover_any := false
	hover_mute := false
	if ui.parent(menu) {
		spacer(.Y, 8)
		if muted {
			end: i64
			if o := dc.channel_override_get(s, gid, cid); o != nil do end = o.mute_end_ms
			if sig := menu_item("mute", "Unmute Channel", sub = muted_until(end)); sig.clicked {
				if net_action() do dc.set_channel_muted(app.client, gid, cid, false, now_ms = now)
				close = true
			} else if sig.hovering do hover_any = true
		} else {
			it := menu_item("mute", "Mute Channel", .Chevron, open = gm.bell_sub == .Mute)
			if it.hovering do hover_mute = true
			if it.clicked do gm.bell_sub = .Mute
			if it.hovering || it.clicked do gm.bell_sub_y = it.box.rect.y0
		}
		menu_sep("s1")
		def_text := has_cat ? "Use Category Default" : "Use Server Default"
		if sig := menu_item("default", def_text, level == dc.NOTIFY_INHERIT ? .Radio_On : .Radio_Off, sub = NOTIFY_NAMES[clamp(def, 0, 2)]); sig.clicked {
			if level != dc.NOTIFY_INHERIT && net_action() do dc.set_channel_notify_level(app.client, gid, cid, dc.NOTIFY_INHERIT)
			close = level != dc.NOTIFY_INHERIT
		} else if sig.hovering do hover_any = true
		for name, i in NOTIFY_NAMES {
			if sig := menu_item(name, name, level == i ? .Radio_On : .Radio_Off); sig.clicked {
				if level != i && net_action() do dc.set_channel_notify_level(app.client, gid, cid, i)
				close = level != i
			} else if sig.hovering do hover_any = true
		}
		spacer(.Y, 8)
	}
	if hover_mute do gm.bell_sub = .Mute
	if hover_any do gm.bell_sub = .None
	if gm.bell_sub == .Mute {
		if secs := mute_submenu("bmute", {sub_x(menu), sub_y(gm.bell_sub_y, 6 * GM_ROW_H + 16)}); secs != 0 {
			if net_action() do dc.set_channel_muted(app.client, gid, cid, true, secs, now)
			close = true
		}
	}
	if close do gm.bell_channel = 0
}

// The bell icon for a channel header: crossed out while the channel is muted.
bell_icon_name :: proc(ch: ^dc.Channel) -> string {
	return dc.channel_is_muted(store(), ch.guild_id, ch.id, wall_ms()) ? "bell-slash" : "bell"
}

guild_menu_reset_for_test :: proc() {gm = {}}
guild_menu_state_for_test :: proc() -> string {
	return fmt.tprint(gm.menu_guild, gm.sub, gm.leave_guild, gm.leaving, gm.inv_guild, gm.inv_copied, gm.bell_channel, gm.bell_sub, gm.ctx_guild, gm.ctx_sub, gm.nm_guild, app.view.hide_muted)
}

// ---- sidebar thread row menu ----

can_delete_thread :: proc(th: ^dc.Channel) -> bool {
	if th == nil || !dc.is_thread(th) do return false
	if th.owner_id == store().me do return true
	return dc.channel_permissions(store(), th.id) & dc.PERM_MANAGE_THREADS != 0
}

@(private = "file")
thread_menu :: proc() {
	s := store()
	th := dc.channel_get(s, gm.thread_menu)
	if th == nil || outside_pressed("tmenu_scrim") || escape_pressed() {
		gm.thread_menu = 0
		return
	}
	W :: f32(GM_MENU_W)
	pos := gm.thread_pos
	if pos.x + W > app.ui.window.x - 8 do pos.x = app.ui.window.x - 8 - W
	if pos.y + 150 > app.ui.window.y - 8 do pos.y = app.ui.window.y - 8 - 150
	close := false
	menu := menu_panel("tmenu", pos, W)
	if ui.parent(menu) {
		spacer(.Y, 8)
		if dc.channel_unread(s, th.id) {
			if menu_item("read", "Mark As Read").clicked {
				if net_action() do dc.ack_message(app.client, th.id, th.last_message_id, true)
				close = true
			}
			menu_sep("s1")
		}
		if menu_item("link", "Copy Link", .Icon, "link").clicked {
			clipboard_set(fmt.tprintf("https://discord.com/channels/%d/%d", u64(th.guild_id), u64(th.id)))
			close = true
		}
		if can_delete_thread(th) {
			menu_sep("s2")
			if menu_item("delete", "Delete Thread", .Icon, "trash", danger = true).clicked {
				thread_delete_open(th)
				close = true
			}
		}
		spacer(.Y, 8)
	}
	if close do gm.thread_menu = 0
}
