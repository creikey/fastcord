package app

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import dc "fc:discord"
import "fc:ui"

// Full user profile modal ("View Full Profile" from the popout avatar, user
// right-click > Profile): banner, avatar, names, Message / Add Friend / More,
// tabs About Me (bio markdown, Member Since, Note) / Mutual Servers / Mutual
// Friends. Requests as the client's UserProfileModalActionCreators
// (profile?type=modal..., application-identities, relationships for the tab).

PF_W :: 600
PF_BANNER_H :: 212 // with a banner image (106 without)
PF_BANNER_H_PLAIN :: 106
PF_AVATAR :: 120
PF_AVATAR_RING :: 8
PF_PAD :: 16
PF_TAB_H :: 40
PF_BODY_MIN_H :: 240
PF_ROW_H :: 52

Pf_Tab :: enum u8 {
	About,
	Mutual_Servers,
	Mutual_Friends,
}

Pf_Mutual_Guild :: struct {
	id:   dc.Snowflake,
	nick: string,
}

Pf_Friend :: struct {
	id:          dc.Snowflake,
	username:    string,
	global_name: string,
	avatar:      string,
}

Pf_Profile :: struct {
	loaded:        bool,
	friends_req:   bool,
	friends_done:  bool,
	banner:        string,
	accent:        Maybe(u32),
	bio:           string,
	pronouns:      string,
	guild_joined:  string, // guild_member.joined_at in the modal's guild context
	mutual_guilds: [dynamic]Pf_Mutual_Guild,
	mutual_count:  int,
	friends:       [dynamic]Pf_Friend,
}

@(private = "file")
Pf_State :: struct {
	user:     dc.Snowflake,
	guild:    dc.Snowflake,
	tab:      Pf_Tab,
	t:        f32,
	profiles: map[dc.Snowflake]Pf_Profile,
	menu_user: dc.Snowflake, // user context menu
	menu_pos: ui.Vec2,
}

@(private = "file")
pf: Pf_State

profile_full_open :: proc(uid: dc.Snowflake, guild_id: dc.Snowflake = 0) {
	pf.user = uid
	pf.guild = guild_id
	pf.tab = .About
	pf.t = 0
	app.profile_user = 0
	if app.client != nil {
		bot := false
		if u := dc.user_get(store(), uid); u != nil do bot = u.bot
		dc.profile_modal_fetch(app.client, uid, guild_id, bot)
	}
}

// Popout hook: the avatar opens the full profile (with a hint on hover).
profile_full_avatar_hook :: proc(av: ^ui.Box, uid: dc.Snowflake) {
	av.flags += {.Clickable}
	sig := ui.signal(av)
	if sig.hovering {
		if ui.parent(av) {
			shade := ui.box("pfshade", {.Draw_Background, .Floating_X, .Floating_Y, .Draw_Text})
			shade.semantic_size = av.semantic_size
			shade.style.radius = av.style.radius
			shade.style.bg = {0, 0, 0, 0.5}
			shade.text = "View Profile"
			shade.style.font = F(.Bold)
			shade.style.font_size = 10
			shade.style.text_align = .Center
			shade.style.text_color = {1, 1, 1, 1}
		}
	}
	if sig.clicked do profile_full_open(uid, app.view.guild)
}

profile_full_receive :: proc(r: ^dc.Expr_Result) {
	uid := dc.Snowflake(r.tag)
	p, ok := &pf.profiles[uid]
	if !ok {
		pf.profiles[uid] = {}
		p = &pf.profiles[uid]
	}
	if !r.ok do return
	#partial switch r.op {
	case .Profile_Modal:
		m := dc.vmap(r.body)
		u := dc.fmap(m, "user")
		prof := dc.fmap(m, "user_profile")
		p.loaded = true
		delete(p.banner)
		delete(p.bio)
		delete(p.pronouns)
		delete(p.guild_joined)
		p.banner = strings.clone(dc.fstr(u, "banner"))
		p.bio = strings.clone(dc.fstr(prof, "bio"))
		p.pronouns = strings.clone(dc.fstr(prof, "pronouns"))
		if dc.vhas(u, "accent_color") && !dc.vis_null(dc.vget(u, "accent_color")) do p.accent = u32(dc.fint(u, "accent_color"))
		p.guild_joined = strings.clone(dc.fstr(dc.fmap(m, "guild_member"), "joined_at"))
		clear(&p.mutual_guilds)
		for gv in dc.flist(m, "mutual_guilds") {
			gm := dc.vmap(gv)
			append(&p.mutual_guilds, Pf_Mutual_Guild{dc.fsnow(gm, "id"), strings.clone(dc.fstr(gm, "nick"))})
		}
		p.mutual_count = int(dc.fint(m, "mutual_friends_count"))
	case .Mutual_Friends:
		p.friends_done = true
		clear(&p.friends)
		for fv in dc.vlist(r.body) {
			f := dc.vmap(fv)
			append(&p.friends, Pf_Friend{dc.fsnow(f, "id"), strings.clone(dc.fstr(f, "username")), strings.clone(dc.fstr(f, "global_name")), strings.clone(dc.fstr(f, "avatar"))})
		}
		p.mutual_count = len(p.friends)
	}
}

// Overlay entry (views.odin overlays()).
profile_full_overlay :: proc() {
	user_context_menu()
	// FASTCORD_PROFILE=<user id|me> opens the modal once a channel shows (headless checks)
	@(static) debug_done: bool
	if !debug_done && app.view.channel != 0 {
		debug_done = true
		if v := os.get_env("FASTCORD_PROFILE", context.temp_allocator); v != "" {
			id, _ := strconv.parse_u64(v)
			if v == "me" do id = u64(store().me)
			if v == "friend" do for uid, rel in store().relationships do if rel.kind == .Friend do id = u64(uid)
			profile_full_open(dc.Snowflake(id), app.view.guild)
		}
	}
	if pf.user == 0 do return
	s := store()
	uid := pf.user
	u := dc.user_get(s, uid)
	if u == nil {
		pf.user = 0
		return
	}
	prof := pf.profiles[uid]
	ui.animate(&pf.t, 1, 25)
	win := app.ui.window
	scrim := ui.box("pf_scrim###pf_scrim", {.Draw_Background, .Clickable, .Floating_X, .Floating_Y, .Overlay})
	scrim.semantic_size = {.X = ui.px(win.x), .Y = ui.px(win.y)}
	scrim.style.bg = with_alpha(T("--background-scrim"), pf.t)
	if ui.signal(scrim).clicked {
		pf.user = 0
		return
	}
	banner_url := ""
	banner_hash := prof.banner != "" ? prof.banner : u.banner
	if banner_hash != "" do banner_url = dc.banner_url(uid, banner_hash, 600)
	banner_h: f32 = banner_url != "" ? PF_BANNER_H : PF_BANNER_H_PLAIN
	body_h := min(win.y - 80 - banner_h - 140 - PF_TAB_H, PF_BODY_MIN_H)
	total_h := banner_h + 140 + PF_TAB_H + body_h
	x := (win.x - PF_W) / 2
	y := (win.y - total_h) / 2
	m := ui.box("pf###pf_modal", {.Draw_Background, .Draw_Shadow, .Floating_X, .Floating_Y, .Clickable, .Clip, .Overlay})
	m.semantic_size = {.X = ui.px(PF_W), .Y = ui.px(total_h)}
	m.fixed_pos = {x, y + (1 - pf.t) * 16}
	m.layout_axis = .Y
	m.style.bg = T("--background-surface-high")
	m.style.radius = 8
	m.style.shadow_color = {0, 0, 0, 0.4}
	m.style.shadow_blur = 24
	m.style.shadow_offset = {0, 8}
	ui.signal(m)
	if ui.parent(m) {
		banner := ui.box("banner", {.Draw_Background})
		banner.semantic_size = {.X = ui.pct(1), .Y = ui.px(banner_h)}
		banner.style.radius = {8, 8, 0, 0}
		accent := prof.accent
		if accent == nil do accent = u.accent_color
		if ac, ok := accent.?; ok do banner.style.bg = rgb_u32(ac)
		else do banner.style.bg = T("--background-brand")
		if banner_url != "" do set_remote_image(banner, banner_url)
		head := ui.box("head")
		head.semantic_size = {.X = ui.pct(1), .Y = ui.px(140)}
		if ui.parent(head) {
			ring := ui.box("ring", {.Draw_Background, .Floating_X, .Floating_Y})
			rs_: f32 = PF_AVATAR + 2 * PF_AVATAR_RING
			ring.semantic_size = {.X = ui.px(rs_), .Y = ui.px(rs_)}
			ring.fixed_pos = {PF_PAD + 8 - PF_AVATAR_RING, -PF_AVATAR / 2 - PF_AVATAR_RING}
			ring.style.radius = rs_ / 2
			ring.style.bg = m.style.bg
			if ui.parent(ring) {
				av := avatar_with_status("av", uid, PF_AVATAR, m.style.bg)
				av.flags += {.Floating_X, .Floating_Y}
				av.fixed_pos = {PF_AVATAR_RING, PF_AVATAR_RING}
			}
			profile_actions(uid)
			names := ui.box("names", {.Floating_X, .Floating_Y})
			names.semantic_size = {.X = ui.px(PF_W - 2 * PF_PAD), .Y = ui.children()}
			names.fixed_pos = {PF_PAD + 8, PF_AVATAR / 2 + 16}
			names.layout_axis = .Y
			if ui.parent(names) {
				n := label(dc.display_name(u), .Bold, 24, T("--text-strong"), 30)
				n.flags += {.Selectable_Text}
				n.sel_order = 1
				un := row("un")
				un.semantic_size = {.X = ui.pct(1), .Y = ui.px(20)}
				if ui.parent(un) {
					l := label(u.username, .Normal, 16, T("--text-default"), 20)
					l.flags += {.Selectable_Text}
					l.sel_order = 2
					pron := prof.pronouns != "" ? prof.pronouns : u.pronouns
					if pron != "" do label(fmt.tprintf(" • %s", pron), .Normal, 16, T("--text-default"), 20)
				}
			}
		}
		profile_tabs(uid, prof)
		line := ui.box("tabline", {.Draw_Background})
		line.semantic_size = {.X = ui.pct(1), .Y = ui.px(1)}
		line.style.bg = T("--border-subtle")
		body := ui.box("body", {.Clip, .Scroll_Y})
		body.semantic_size = {.X = ui.pct(1), .Y = ui.fill()}
		body.layout_axis = .Y
		ui.signal(body)
		if ui.parent(body) {
			switch pf.tab {
			case .About:
				profile_about(uid, u, prof)
			case .Mutual_Servers:
				profile_mutual_servers(prof)
			case .Mutual_Friends:
				profile_mutual_friends(uid, prof)
			}
			spacer(.Y, PF_PAD)
		}
	}
	for &e in app.ui.events {
		if !e.consumed && e.kind == .Key_Down && e.key == .Escape {
			e.consumed = true
			pf.user = 0
		}
	}
	pk_fade(m, pf.t)
}

// Message (friends / others) or Add Friend, plus More — top right under the banner.
@(private = "file")
profile_actions :: proc(uid: dc.Snowflake) {
	s := store()
	if uid == s.me do return
	rel, has_rel := s.relationships[uid]
	friend := has_rel && rel.kind == .Friend
	bar := row("actions", {.Floating_X, .Floating_Y})
	bar.semantic_size = {.X = ui.children(), .Y = ui.px(32)}
	w: f32 = friend ? 110 + 8 + 32 : 110 + 8 + 120 + 8 + 32
	bar.fixed_pos = {PF_W - PF_PAD - w, PF_PAD}
	bar.style.child_gap = 8
	if ui.parent(bar) {
		if !friend {
			pending := has_rel && rel.kind == .Outgoing_Request
			add := action_button(pending ? "Pending" : "Add Friend", "user-plus", 120, false)
			if add && !pending && net_action() do dc.add_relationship(app.client, uid, "User Profile")
		}
		if action_button("Message", "chat", 110, true) && net_action() {
			if existing := dc.open_dm(app.client, uid, "User Profile"); existing != 0 do select_channel(0, existing)
			else do app.pending_dm_user = uid
			pf.user = 0
		}
		more := ui.box("more", {.Clickable, .Draw_Background, .Hot_Animation})
		more.semantic_size = {.X = ui.px(32), .Y = ui.px(32)}
		more.style.radius = 8
		more.style.bg = T("--control-secondary-background-default")
		more.style.bg_hot = T("--control-secondary-background-hover")
		more.layout_axis = .X
		more.cross_align = .Center
		if ui.signal(more).clicked do open_user_menu(uid, {more.rect.x0, more.rect.y1 + 4})
		if ui.parent(more) {
			spacer(.X, 6)
			icon("i", "more-horizontal", 20, T("--interactive-icon-active"))
		}
	}
}

@(private = "file")
action_button :: proc(text, icon_name: string, w: f32, primary: bool) -> bool {
	b := row(text, {.Clickable, .Draw_Background, .Hot_Animation})
	b.semantic_size = {.X = ui.px(w), .Y = ui.px(32)}
	b.style.radius = 8
	b.style.bg = primary ? T("--background-brand") : T("--control-secondary-background-default")
	b.style.bg_hot = primary ? with_alpha(T("--background-brand"), 0.85) : T("--control-secondary-background-hover")
	sig := ui.signal(b)
	if ui.parent(b) {
		filler(.X)
		icon("i", icon_name, 16, primary ? ui.Color{1, 1, 1, 1} : T("--interactive-text-active"))
		spacer(.X, 6)
		label(text, .Medium, 14, primary ? ui.Color{1, 1, 1, 1} : T("--interactive-text-active"), 18)
		filler(.X)
	}
	return sig.clicked
}

@(private = "file")
profile_tabs :: proc(uid: dc.Snowflake, prof: Pf_Profile) {
	tabs := row("tabs")
	tabs.semantic_size = {.X = ui.pct(1), .Y = ui.px(PF_TAB_H)}
	tabs.cross_align = .End
	if ui.parent(tabs) {
		spacer(.X, PF_PAD + 8)
		for t in Pf_Tab {
			if uid == store().me && t != .About do continue
			text := "About Me"
			switch t {
			case .About:
			case .Mutual_Servers:
				n := len(prof.mutual_guilds)
				text = n == 1 ? "1 Mutual Server" : (n > 0 ? fmt.tprintf("%d Mutual Servers", n) : "Mutual Servers")
			case .Mutual_Friends:
				n := prof.mutual_count
				text = n == 1 ? "1 Mutual Friend" : (n > 0 ? fmt.tprintf("%d Mutual Friends", n) : "Mutual Friends")
			}
			sel := pf.tab == t
			b := ui.box(fmt.tprintf("%s##tab%d", text, int(t)), {.Clickable})
			b.semantic_size = {.X = ui.children(), .Y = ui.px(PF_TAB_H)}
			b.layout_axis = .Y
			sig := ui.signal(b)
			if ui.parent(b) {
				spacer(.Y, 10)
				lab := label(text, .Medium, 16, sel || sig.hovering ? T("--interactive-text-active") : T("--interactive-text-default"), 20)
				filler(.Y)
				ul := ui.box("ul", {.Draw_Background})
				ul.semantic_size = {.X = ui.px(max(0, lab.rect.x1 - lab.rect.x0)), .Y = ui.px(2)}
				ul.style.bg = sel ? T("--text-strong") : {}
				ul.style.radius = 1
			}
			if sig.clicked {
				pf.tab = t
				if t == .Mutual_Friends && app.client != nil && !pf.profiles[uid].friends_req {
					p := &pf.profiles[uid]
					p.friends_req = true
					dc.mutual_friends_fetch(app.client, uid)
				}
			}
			spacer(.X, 32)
		}
	}
}

@(private = "file")
section_title :: proc(text: string) {
	r := row(text)
	r.semantic_size = {.X = ui.pct(1), .Y = ui.px(20)}
	if ui.parent(r) {
		spacer(.X, PF_PAD + 8)
		label(text, .Semibold, 12, T("--text-strong"), 16)
	}
	spacer(.Y, 6)
}

// "Oct 26, 2026"
@(private = "file")
short_date :: proc(ms: i64) -> string {
	t := time.unix(ms / 1000, 0)
	y, mo, d := time.date(t)
	MONTHS := [12]string{"Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"}
	return fmt.tprintf("%s %d, %d", MONTHS[int(mo) - 1], d, y)
}

@(private = "file")
iso_ms :: proc(s: string) -> i64 {
	t, _, consumed := time.iso8601_to_time_and_offset(s)
	if consumed == 0 do return 0
	return time.time_to_unix_nano(t) / 1e6
}

@(private = "file")
profile_about :: proc(uid: dc.Snowflake, u: ^dc.User, prof: Pf_Profile) {
	spacer(.Y, PF_PAD)
	bio := prof.bio != "" ? prof.bio : u.bio
	if bio != "" {
		section_title("About Me")
		for blk, bi in md_parse(bio) {
			w := row(fmt.tprintf("bio%d", bi))
			w.semantic_size = {.X = ui.pct(1), .Y = ui.children()}
			if ui.parent(w) {
				spacer(.X, PF_PAD + 8)
				b := ui.box("p", {.Selectable_Text, .Wrap_Text})
				b.semantic_size = {.X = ui.fill(), .Y = ui.text_size()}
				b.style.line_height = 18
				b.style.text_color = T("--text-default")
				b.sel_order = 10 + u64(bi)
				ui.set_spans(b, tokens_to_spans(blk.tokens, .Normal, 14, nil))
				spacer(.X, PF_PAD + 8)
			}
		}
		spacer(.Y, 16)
	}
	section_title("Member Since")
	ms := row("since")
	ms.semantic_size = {.X = ui.pct(1), .Y = ui.px(20)}
	if ui.parent(ms) {
		spacer(.X, PF_PAD + 8)
		icon("dlogo", "clyde", 16, T("--interactive-icon-default"))
		spacer(.X, 8)
		label(short_date(dc.snowflake_time_ms(uid)), .Normal, 14, T("--text-default"), 18)
		if prof.guild_joined != "" && pf.guild != 0 {
			spacer(.X, 12)
			dot := ui.box("dot", {.Draw_Background})
			dot.semantic_size = {.X = ui.px(4), .Y = ui.px(4)}
			dot.style.radius = 2
			dot.style.bg = T("--text-muted")
			spacer(.X, 12)
			gi := ui.box("##gi", {.Draw_Background, .Draw_Text})
			gi.semantic_size = {.X = ui.px(16), .Y = ui.px(16)}
			gi.style.radius = 5
			gi.style.bg = T("--background-mod-subtle")
			gi.style.font = F(.Medium)
			gi.style.font_size = 7
			gi.style.text_align = .Center
			gi.style.text_color = T("--text-default")
			if g := dc.guild_get(store(), pf.guild); g != nil {
				if g.icon != "" do set_remote_image(gi, dc.guild_icon_url(g.id, g.icon, 32))
				else do gi.text = guild_initials(g.name)
			}
			spacer(.X, 8)
			label(short_date(iso_ms(prof.guild_joined)), .Normal, 14, T("--text-default"), 18)
		}
	}
	spacer(.Y, 16)
	if uid != store().me {
		section_title("Note")
		nr := row("note")
		nr.semantic_size = {.X = ui.pct(1), .Y = ui.px(18)}
		if ui.parent(nr) {
			spacer(.X, PF_PAD + 8)
			label("Click to add a note", .Normal, 12, T("--text-muted"), 16)
		}
	}
}

@(private = "file")
list_row :: proc(id: string) -> (^ui.Box, ui.Signal) {
	outer := row(id)
	outer.semantic_size = {.X = ui.pct(1), .Y = ui.px(PF_ROW_H)}
	r: ^ui.Box
	sig: ui.Signal
	if ui.parent(outer) {
		spacer(.X, 8)
		r = row("item", {.Clickable, .Draw_Background, .Hot_Animation})
		r.semantic_size = {.X = ui.fill(), .Y = ui.px(PF_ROW_H)}
		r.style.radius = 8
		r.style.bg_hot = T("--background-mod-subtle")
		sig = ui.signal(r)
		spacer(.X, 8)
	}
	return r, sig
}

@(private = "file")
empty_state :: proc(text: string) {
	spacer(.Y, 48)
	r := ui.box(text)
	r.semantic_size = {.X = ui.pct(1), .Y = ui.px(20)}
	r.layout_axis = .X
	r.cross_align = .Center
	if ui.parent(r) {
		filler(.X)
		label(text, .Medium, 16, T("--text-muted"), 20)
		filler(.X)
	}
}

@(private = "file")
profile_mutual_servers :: proc(prof: Pf_Profile) {
	spacer(.Y, 8)
	if len(prof.mutual_guilds) == 0 {
		empty_state(prof.loaded || app.client == nil ? "No servers in common" : "Loading…")
		return
	}
	for mg in prof.mutual_guilds {
		g := dc.guild_get(store(), mg.id)
		if g == nil do continue
		if ui.id_scope(u64(mg.id)) {
			r, sig := list_row("mg")
			if ui.parent(r) {
				spacer(.X, 8)
				gi := ui.box("##gi", {.Draw_Background, .Draw_Text})
				gi.semantic_size = {.X = ui.px(40), .Y = ui.px(40)}
				gi.style.radius = 12
				gi.style.bg = T("--background-mod-normal")
				gi.style.font = F(.Medium)
				gi.style.font_size = 14
				gi.style.text_align = .Center
				gi.style.text_color = T("--text-default")
				if g.icon != "" do set_remote_image(gi, dc.guild_icon_url(g.id, g.icon, 80))
				else do gi.text = guild_initials(g.name)
				spacer(.X, 12)
				col := ui.box("col")
				col.semantic_size = {.X = ui.fill(), .Y = ui.children()}
				col.layout_axis = .Y
				if ui.parent(col) {
					label(g.name, .Medium, 16, T("--interactive-text-active"), 20)
					if mg.nick != "" do label(mg.nick, .Normal, 14, T("--text-muted"), 18)
				}
			}
			if sig.clicked {
				pf.user = 0
				select_guild(mg.id)
			}
		}
	}
}

@(private = "file")
profile_mutual_friends :: proc(uid: dc.Snowflake, prof: Pf_Profile) {
	spacer(.Y, 8)
	if len(prof.friends) == 0 {
		empty_state(prof.friends_done || app.client == nil ? "No friends in common" : "Loading…")
		return
	}
	for f in prof.friends {
		if ui.id_scope(u64(f.id)) {
			r, sig := list_row("mf")
			if ui.parent(r) {
				spacer(.X, 8)
				av := ui.box("av", {.Draw_Background})
				av.semantic_size = {.X = ui.px(40), .Y = ui.px(40)}
				av.style.radius = 20
				av.style.bg = T("--background-mod-normal")
				set_remote_image(av, f.avatar != "" ? dc.avatar_url(f.id, f.avatar, 80) : dc.default_avatar_url(f.id, "0"))
				spacer(.X, 12)
				col := ui.box("col")
				col.semantic_size = {.X = ui.fill(), .Y = ui.children()}
				col.layout_axis = .Y
				if ui.parent(col) {
					label(f.global_name != "" ? f.global_name : f.username, .Medium, 16, T("--interactive-text-active"), 20)
					label(f.username, .Normal, 14, T("--text-muted"), 18)
				}
			}
			if sig.clicked do profile_full_open(f.id)
		}
	}
	_ = uid
}

// ---- user context menu (right-click on a member / author) ----

open_user_menu :: proc(uid: dc.Snowflake, at: ui.Vec2) {
	pf.menu_user = uid
	pf.menu_pos = at
}

@(private = "file")
user_context_menu :: proc() {
	if pf.menu_user == 0 do return
	uid := pf.menu_user
	s := store()
	items := make([dynamic]string, context.temp_allocator)
	append(&items, "Profile")
	if uid != s.me do append(&items, "Message")
	append(&items, "Copy Username", "Copy User ID")
	W :: f32(188)
	H := f32(len(items)) * 32 + 16
	p := pf.menu_pos
	p.x = min(p.x, app.ui.window.x - W - 8)
	p.y = min(p.y, app.ui.window.y - H - 8)
	scrim := ui.box("umenu_scrim###umenu_scrim", {.Clickable, .Floating_X, .Floating_Y, .Overlay})
	scrim.semantic_size = {.X = ui.px(app.ui.window.x), .Y = ui.px(app.ui.window.y)}
	if ui.signal(scrim).pressed {
		pf.menu_user = 0
		return
	}
	menu := ui.box("umenu###umenu", {.Draw_Background, .Draw_Border, .Draw_Shadow, .Floating_X, .Floating_Y, .Overlay, .Clickable})
	menu.semantic_size = {.X = ui.px(W), .Y = ui.px(H)}
	menu.fixed_pos = p
	menu.layout_axis = .Y
	menu.style.bg = T("--background-surface-higher")
	menu.style.border_color = T("--border-subtle")
	menu.style.border = 1
	menu.style.radius = 8
	menu.style.shadow_color = {0, 0, 0, 0.24}
	menu.style.shadow_blur = 16
	ui.signal(menu)
	if ui.parent(menu) {
		spacer(.Y, 8)
		for it in items {
			r := row(it, {.Clickable, .Draw_Background, .Hot_Animation})
			r.semantic_size = {.X = ui.pct(1), .Y = ui.px(32)}
			r.style.radius = 4
			r.style.bg_hot = T("--background-mod-normal")
			sig := ui.signal(r)
			if ui.parent(r) {
				spacer(.X, 8)
				label(it, .Medium, 14, sig.hovering ? T("--interactive-text-active") : T("--interactive-text-default"), 18)
			}
			if sig.clicked {
				switch it {
				case "Profile":
					profile_full_open(uid, app.view.guild)
				case "Message":
					if net_action() {
						if existing := dc.open_dm(app.client, uid, "Context Menu"); existing != 0 do select_channel(0, existing)
						else do app.pending_dm_user = uid
					}
				case "Copy Username":
					if u := dc.user_get(s, uid); u != nil do clipboard_set(u.username)
				case "Copy User ID":
					clipboard_set(fmt.tprint(u64(uid)))
				}
				pf.menu_user = 0
			}
		}
	}
	for e in app.ui.events do if e.kind == .Key_Down && e.key == .Escape do pf.menu_user = 0
}

pf_reset_for_test :: proc() {pf = {}}
pf_state_for_test :: proc() -> string {return fmt.tprint(pf.user, pf.tab, pf.menu_user)}
