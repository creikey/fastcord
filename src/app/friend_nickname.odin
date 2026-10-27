package app

import "core:fmt"
import "core:strings"
import "core:unicode/utf8"
import dc "fc:discord"
import "fc:ui"

// Friend nicknames: names shown through dc.user_name, and the
// "Add / Edit Friend Nickname" modal opened from the user menu.

// name_in: a user's name as shown in a channel (its server's nickname first).
name_in :: proc(uid, channel_id: dc.Snowflake, unknown := "Unknown") -> string {
	s := store()
	gid: dc.Snowflake
	if ch := dc.channel_get(s, channel_id); ch != nil do gid = ch.guild_id
	return dc.user_name(s, uid, gid, unknown)
}

// The user menu's item for this user ("" when they aren't a friend).
friend_nick_menu_item :: proc(uid: dc.Snowflake) -> string {
	r, ok := &store().relationships[uid]
	if !ok || r.kind != .Friend do return ""
	return r.nickname != "" ? "Edit Friend Nickname" : "Add Friend Nickname"
}

// "Change Nickname" in a guild's user menu: our own needs CHANGE_NICKNAME, someone
// else's MANAGE_NICKNAMES and a higher role (dc.can_set_nickname).
server_nick_menu_item :: proc(uid: dc.Snowflake) -> string {
	if app.view.guild == 0 || !dc.can_set_nickname(store(), app.view.guild, uid) do return ""
	// without the member's roles the hierarchy is unknown: only the owner may then
	if g := dc.guild_get(store(), app.view.guild); dc.member_get(store(), app.view.guild, uid) == nil && (g == nil || g.owner_id != store().me) do return ""
	return "Change Nickname"
}

// One dialog for both: guild == 0 edits the friend nickname, else the server nickname.
Friend_Nick :: struct {
	user:  dc.Snowflake,
	guild: dc.Snowflake,
	ed:    ui.Editor,
}

fnick: Friend_Nick

friend_nick_open :: proc(uid: dc.Snowflake) {
	fnick.user = uid
	fnick.guild = 0
	ui.editor_set_text(&fnick.ed, dc.friend_nickname(store(), uid))
}

server_nick_open :: proc(uid, guild: dc.Snowflake) {
	fnick.user = uid
	fnick.guild = guild
	nick := ""
	if m := dc.member_get(store(), guild, uid); m != nil do nick = m.nick
	ui.editor_set_text(&fnick.ed, nick)
	if app.client != nil do dc.open_change_nickname(app.client)
}

@(private = "file")
friend_nick_save :: proc(nick: string) {
	uid, gid := fnick.user, fnick.guild
	fnick.user = 0
	n := strings.trim_space(nick)
	if gid != 0 {
		old := ""
		if m := dc.member_get(store(), gid, uid); m != nil do old = m.nick
		if n == old do return
		if net_action() do dc.set_server_nickname(app.client, gid, uid, n)
		else do dc.store_set_server_nickname(store(), gid, uid, n)
		return
	}
	if n == dc.friend_nickname(store(), uid) do return
	if net_action() do dc.set_friend_nickname(app.client, uid, n)
	else do dc.store_set_friend_nickname(store(), uid, n) // offline (fixture) runs show the result
}

friend_nick_modal :: proc() {
	s := store()
	uid := fnick.user
	u := dc.user_get(s, uid)
	if u == nil {
		fnick.user = 0
		return
	}
	scrim := ui.box("fnick_scrim", {.Draw_Background, .Clickable, .Floating_X, .Floating_Y, .Overlay})
	scrim.semantic_size = {.X = ui.px(app.ui.window.x), .Y = ui.px(app.ui.window.y)}
	scrim.style.bg = {0, 0, 0, 0.7}
	if ui.signal(scrim).clicked {
		fnick.user = 0
		return
	}
	W :: 440
	PAD :: 24
	server := fnick.guild != 0
	had := !server && dc.friend_nickname(s, uid) != ""
	d := ui.box("fnickmodal", {.Draw_Background, .Draw_Border, .Floating_X, .Floating_Y, .Overlay, .Clickable})
	d.semantic_size = {.X = ui.px(W), .Y = ui.children()}
	d.fixed_pos = {(app.ui.window.x - W) / 2, (app.ui.window.y - (d.rect.y1 - d.rect.y0)) / 2}
	d.style.bg = T("--modal-background")
	d.style.border_color = T("--border-subtle")
	d.style.border = 1
	d.style.radius = 12
	d.layout_axis = .Y
	ui.signal(d)
	ui.push_parent(d)
	defer ui.pop_parent()
	text_row :: proc(id, text: string, font: Font_Id, size, lh: f32, color: ui.Color) {
		r := row(id)
		r.semantic_size = {.X = ui.pct(1), .Y = ui.px(lh)}
		if ui.parent(r) {
			spacer(.X, PAD)
			label(text, font, size, color, lh)
		}
	}
	button :: proc(id: string, w: f32, bg, bg_hot, fg: ui.Color) -> bool {
		b := ui.box(id, {.Clickable, .Draw_Background, .Draw_Text, .Hot_Animation})
		b.semantic_size = {.X = ui.px(w), .Y = ui.px(38)}
		b.style.radius = 8
		b.style.font = F(.Medium)
		b.style.font_size = 14
		b.style.text_align = .Center
		b.style.text_color = fg
		b.style.bg = bg
		b.style.bg_hot = bg_hot
		return ui.signal(b).clicked
	}
	spacer(.Y, PAD)
	if server {
		text_row("t", "Change Nickname", .Semibold, 20, 24, T("--text-strong"))
		if uid != s.me {
			spacer(.Y, 16)
			wr := row("warnrow")
			wr.semantic_size = {.X = ui.pct(1), .Y = ui.children()}
			if ui.parent(wr) {
				spacer(.X, PAD)
				warn := ui.box("warn", {.Draw_Background})
				warn.semantic_size = {.X = ui.fill(), .Y = ui.children()}
				warn.layout_axis = .Y
				warn.style.bg = T("--background-feedback-warning")
				warn.style.radius = 8
				if ui.parent(warn) {
					spacer(.Y, 10)
					pr := row("p")
					pr.semantic_size = {.X = ui.pct(1), .Y = ui.children()}
					if ui.parent(pr) {
						spacer(.X, 12)
						p := ui.box("Nicknames are visible to everyone on this server. Do not change them unless you are enforcing a naming system or clearing a bad nickname.##warntext", {.Draw_Text, .Wrap_Text})
						p.semantic_size = {.X = ui.fill(), .Y = ui.text_size()}
						p.style.font = F(.Normal)
						p.style.font_size = 14
						p.style.line_height = 18
						p.style.text_color = T("--text-default")
						spacer(.X, 12)
					}
					spacer(.Y, 10)
				}
				spacer(.X, PAD)
			}
		}
		spacer(.Y, 16)
		text_row("lbl", "Nickname", .Semibold, 14, 18, T("--text-strong"))
	} else {
		text_row("t", had ? "Edit Friend Nickname" : "Add Friend Nickname", .Semibold, 20, 24, T("--text-strong"))
		spacer(.Y, 8)
		text_row("sub", fmt.tprintf("Only you can see the nickname you give %s.", dc.display_name(u)), .Normal, 14, 18, T("--text-default"))
		spacer(.Y, 16)
		text_row("lbl", "Friend Nickname", .Semibold, 14, 18, T("--text-strong"))
	}
	spacer(.Y, 8)
	save := false
	ir := row("inrow")
	ir.semantic_size = {.X = ui.pct(1), .Y = ui.px(40)}
	if ui.parent(ir) {
		spacer(.X, PAD)
		field := row("input", {.Draw_Background, .Draw_Border, .Clickable})
		field.semantic_size = {.X = ui.fill(), .Y = ui.px(40)}
		field.style.bg = T("--input-background-default")
		field.style.border_color = T("--input-border-active")
		field.style.border = 1
		field.style.radius = 8
		field.hover_cursor = .IBeam
		if ui.parent(field) {
			spacer(.X, 12)
			res := text_field("field", &fnick.ed, dc.display_name(u), true, 16, 20, 10, T("--input-placeholder-text-default"))
			if t := ui.editor_text(&fnick.ed); utf8.rune_count(t) > dc.FRIEND_NICKNAME_MAX {
				n, cut := 0, 0
				for _, i in t {
					if n == dc.FRIEND_NICKNAME_MAX {cut = i; break}
					n += 1
				}
				ui.editor_set_text(&fnick.ed, strings.clone(t[:cut], context.temp_allocator))
			}
			if res == .Submit do save = true
			if res == .Escape do fnick.user = 0
			spacer(.X, 12)
		}
		spacer(.X, PAD)
	}
	spacer(.Y, PAD)
	btns := row("btns", {.Draw_Background})
	btns.semantic_size = {.X = ui.pct(1), .Y = ui.px(70)}
	btns.style.bg = T("--background-base-lower")
	btns.style.radius = {0, 0, 12, 12}
	btns.style.child_gap = 8
	if ui.parent(btns) {
		spacer(.X, PAD - 8)
		// like the client: Reset only clears the field; Save sends {"nickname":null}
		if had && button("Reset Friend Nickname##reset", 170, {}, T("--background-mod-normal"), T("--text-link")) do ui.editor_set_text(&fnick.ed, "")
		filler(.X)
		if button("Cancel##cancel", 96, T("--background-mod-normal"), T("--background-mod-strong"), T("--text-strong")) do fnick.user = 0
		if button("Save##save", 96, T("--background-brand"), with_alpha(T("--background-brand"), 0.85), {1, 1, 1, 1}) do save = true
		spacer(.X, PAD - 8)
	}
	if save && fnick.user != 0 do friend_nick_save(ui.editor_text(&fnick.ed))
	for &e in app.ui.events {
		if !e.consumed && e.kind == .Key_Down && e.key == .Escape {
			e.consumed = true
			fnick.user = 0
		}
	}
}
