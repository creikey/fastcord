package app

import "core:fmt"
import "core:slice"
import "core:strings"
import dc "fc:discord"
import "fc:ui"

home_sidebar :: proc() {
	s := store()
	search := row("search")
	search.semantic_size = {.X = ui.pct(1), .Y = ui.px(HEADER_H - 1)}
	if ui.parent(search) {
		spacer(.X, 8)
		btn := ui.box("Find or start a conversation##btn", {.Clickable, .Draw_Background, .Draw_Border, .Draw_Text})
		btn.semantic_size = {.X = ui.fill(), .Y = ui.px(32)}
		btn.style.bg = T("--background-mod-subtle")
		btn.style.border_color = T("--border-muted")
		btn.style.border = 1
		btn.style.radius = 8
		btn.style.font = F(.Medium)
		btn.style.font_size = 14
		btn.style.text_color = T("--text-strong")
		btn.style.text_align = .Center
		ui.signal(btn)
		spacer(.X, 8)
	}
	line := ui.box("hline", {.Draw_Background})
	line.semantic_size = {.X = ui.pct(1), .Y = ui.px(1)}
	line.style.bg = T("--border-subtle")

	list := ui.box("dms", {.Scroll_Y, .Clip})
	list.semantic_size = {.X = ui.pct(1), .Y = ui.fill()}
	list.layout_axis = .Y
	ui.signal(list)
	if ui.parent(list) {
		spacer(.Y, 8)
		for name in ([]string{"Friends", "Nitro", "Shop", "Quests"}) {
			if dm_nav_item(name, name == "Friends" && app.view.channel == 0).clicked && name == "Friends" {
				select_channel(0, 0)
			}
		}
		spacer(.Y, 8)
		sep := ui.box("sep", {.Draw_Background})
		sep.semantic_size = {.X = ui.pct(1), .Y = ui.px(1)}
		sep.style.bg = T("--border-subtle")
		header := row("dmheader")
		header.semantic_size = {.X = ui.pct(1), .Y = ui.px(40)}
		if ui.parent(header) {
			spacer(.X, 16)
			label("Direct Messages", .Medium, 14, T("--channels-default"), 18)
			filler(.X)
			icon("plus", "plus-small", 16, T("--interactive-icon-default"))
			spacer(.X, 16)
		}
		for cid in dc.private_channels_sorted(s) {
			ch := dc.channel_get(s, cid)
			if ch == nil do continue
			if ui.id_scope(u64(cid)) do dm_row(ch)
		}
		spacer(.Y, USER_PANEL_H + 16)
	}
}

dm_nav_item :: proc(name: string, selected: bool) -> ui.Signal {
	outer := row(name)
	outer.semantic_size = {.X = ui.pct(1), .Y = ui.px(42)}
	sig: ui.Signal
	if ui.parent(outer) {
		spacer(.X, 8)
		item := row("item", {.Clickable, .Draw_Background, .Hot_Animation})
		item.semantic_size = {.X = ui.fill(), .Y = ui.px(40)}
		item.style.radius = 8
		item.style.bg = selected ? T("--background-mod-normal") : {}
		item.style.bg_hot = selected ? item.style.bg : T("--background-mod-subtle")
		sig = ui.signal(item)
		icon_name := "friends"
		switch name {
		case "Nitro":
			icon_name = "nitro-wheel"
		case "Shop":
			icon_name = "shop"
		case "Quests":
			icon_name = "quests"
		}
		if ui.parent(item) {
			color := selected || sig.hovering ? T("--interactive-text-active") : T("--channels-default")
			spacer(.X, 8)
			icon("ic", icon_name, 24, color)
			spacer(.X, 12)
			label(name, .Medium, 16, color, 20)
		}
		spacer(.X, 8)
	}
	return sig
}

dm_row :: proc(ch: ^dc.Channel) {
	selected := app.view.channel == ch.id
	outer := row("dm")
	outer.semantic_size = {.X = ui.pct(1), .Y = ui.px(44)}
	if ui.parent(outer) {
		spacer(.X, 8)
		item := row("item", {.Clickable, .Draw_Background, .Hot_Animation})
		item.semantic_size = {.X = ui.fill(), .Y = ui.px(42)}
		item.style.radius = 8
		item.style.bg = selected ? T("--background-mod-normal") : {}
		item.style.bg_hot = selected ? item.style.bg : T("--background-mod-subtle")
		sig := ui.signal(item)
		if sig.clicked do select_channel(0, ch.id)
		unread := dc.channel_unread(store(), ch.id)
		color := selected || sig.hovering || unread ? T("--interactive-text-active") : T("--channels-default")
		if ui.parent(item) {
			spacer(.X, 8)
			if ch.kind == .DM && len(ch.recipient_ids) > 0 {
				avatar_with_status("av", ch.recipient_ids[0], 32, item.style.bg.a > 0 ? T("--background-base-lower") : T("--background-base-lower"))
			} else {
				g := ui.box("gicon", {.Draw_Background})
				g.semantic_size = {.X = ui.px(32), .Y = ui.px(32)}
				g.style.radius = 16
				g.style.bg = T("--background-brand")
				if ui.parent(g) {
					inner := ui.box("i", {.Floating_X, .Floating_Y})
					inner.semantic_size = {.X = ui.px(20), .Y = ui.px(20)}
					inner.fixed_pos = {6, 6}
					set_icon(inner, "group", {1, 1, 1, 1})
				}
			}
			spacer(.X, 12)
			col := ui.box("col")
			col.semantic_size = {.X = ui.fill(), .Y = ui.children()}
			if ui.parent(col) {
				label(dm_name(ch), unread ? .Semibold : .Medium, 16, color, 20)
				if ch.kind == .Group_DM {
					label(fmt.tprintf("%d Members", len(ch.recipient_ids) + 1), .Medium, 12, T("--text-muted"), 16)
				}
			}
		}
		spacer(.X, 8)
	}
}

friends_page :: proc() {
	s := store()
	h := row("header", {.Draw_Background})
	h.semantic_size = {.X = ui.pct(1), .Y = ui.px(HEADER_H - 1)}
	h.style.bg = T("--background-base-lower")
	if ui.parent(h) {
		spacer(.X, 16)
		icon("ficon", "friends", 24, T("--channel-icon"))
		spacer(.X, 8)
		label("Friends", .Semibold, 16, T("--text-strong"), 20)
		spacer(.X, 12)
		dot := ui.box("dot", {.Draw_Background})
		dot.semantic_size = {.X = ui.px(4), .Y = ui.px(4)}
		dot.style.radius = 2
		dot.style.bg = T("--interactive-muted")
		spacer(.X, 12)
		tabs := [?]struct {
			name: string,
			tab:  Friends_Tab,
		}{{"Online", .Online}, {"All", .All}, {"Pending", .Pending}, {"Add Friend", .Add_Friend}}
		for t in tabs {
			if t.tab == .Pending && pending_count() == 0 do continue
			sel := app.view.friends_tab == t.tab
			tb := ui.box(t.name, {.Clickable, .Draw_Background, .Draw_Text, .Hot_Animation})
			tb.semantic_size = {.X = ui.text_size(12), .Y = ui.px(32)}
			tb.style.radius = 8
			tb.style.font = F(.Medium)
			tb.style.font_size = 16
			tb.style.text_align = .Center
			tb.style.text_color = sel ? T("--interactive-text-active") : T("--interactive-text-default")
			tb.style.bg = sel ? T("--background-mod-normal") : {}
			tb.style.bg_hot = sel ? tb.style.bg : T("--background-mod-subtle")
			if t.tab == .Add_Friend {
				tb.style.bg = sel ? T("--interactive-accent-background-default") : T("--background-brand")
				tb.style.text_color = sel ? T("--text-brand") : {1, 1, 1, 1}
				tb.style.bg_hot = tb.style.bg
			}
			if ui.signal(tb).clicked do app.view.friends_tab = t.tab
			spacer(.X, 8)
		}
		filler(.X)
	}
	line := ui.box("hline", {.Draw_Background})
	line.semantic_size = {.X = ui.pct(1), .Y = ui.px(1)}
	line.style.bg = T("--border-subtle")

	if app.view.friends_tab == .Add_Friend {
		add_friend_view()
		return
	}
	list := ui.box("friends", {.Scroll_Y, .Clip})
	list.semantic_size = {.X = ui.pct(1), .Y = ui.fill()}
	list.layout_axis = .Y
	ui.signal(list)
	ids := make([dynamic]dc.Snowflake, context.temp_allocator)
	for uid, rel in s.relationships {
		switch app.view.friends_tab {
		case .Online:
			if rel.kind == .Friend && user_status(uid) != .Offline do append(&ids, uid)
		case .All:
			if rel.kind == .Friend do append(&ids, uid)
		case .Pending:
			if rel.kind == .Incoming_Request || rel.kind == .Outgoing_Request do append(&ids, uid)
		case .Add_Friend:
		}
	}
	slice.sort_by(ids[:], proc(a, b: dc.Snowflake) -> bool {
		ua := dc.user_get(store(), a)
		ub := dc.user_get(store(), b)
		if ua == nil || ub == nil do return a < b
		return strings.to_lower(dc.display_name(ua), context.temp_allocator) < strings.to_lower(dc.display_name(ub), context.temp_allocator)
	})
	if ui.parent(list) {
		hdr := row("count")
		hdr.semantic_size = {.X = ui.pct(1), .Y = ui.px(52)}
		if ui.parent(hdr) {
			spacer(.X, 30)
			title := "Online"
			switch app.view.friends_tab {
			case .All:
				title = "All friends"
			case .Pending:
				title = "Pending"
			case .Online, .Add_Friend:
			}
			label(fmt.tprintf("%s — %d", title, len(ids)), .Medium, 14, T("--text-muted"), 18)
		}
		for uid in ids {
			if ui.id_scope(u64(uid)) do friend_row(uid, s.relationships[uid].kind)
		}
		if len(ids) == 0 {
			spacer(.Y, 80)
			msg := app.view.friends_tab == .Pending ? "There are no pending friend requests." : "No one's around to play with Wumpus."
			e := row("empty")
			e.semantic_size = {.X = ui.pct(1), .Y = ui.px(24)}
			if ui.parent(e) {
				filler(.X)
				label(msg, .Normal, 16, T("--text-muted"), 20)
				filler(.X)
			}
		}
	}
}

pending_count :: proc() -> int {
	n := 0
	for _, rel in store().relationships {
		if rel.kind == .Incoming_Request do n += 1
	}
	return n
}

friend_row :: proc(uid: dc.Snowflake, kind: dc.Relationship_Type) {
	s := store()
	outer := row("f")
	outer.semantic_size = {.X = ui.pct(1), .Y = ui.px(62)}
	if ui.parent(outer) {
		spacer(.X, 20)
		item := row("item", {.Clickable, .Draw_Background, .Hot_Animation})
		item.semantic_size = {.X = ui.fill(), .Y = ui.px(62)}
		item.style.radius = 8
		item.style.bg_hot = T("--background-mod-subtle")
		sig := ui.signal(item)
		if sig.clicked && app.client != nil {
			if existing := dc.open_dm(app.client, uid, "Friends"); existing != 0 do select_channel(0, existing)
			else do app.pending_dm_user = uid
		}
		u := dc.user_get(s, uid)
		if ui.parent(item) {
			spacer(.X, 10)
			avatar_with_status("av", uid, 32, sig.hovering ? T("--background-base-low") : T("--background-base-lower"))
			spacer(.X, 12)
			col := ui.box("col")
			col.semantic_size = {.X = ui.fill(), .Y = ui.children()}
			if ui.parent(col) {
				nr := row("nr")
				nr.semantic_size = {.X = ui.pct(1), .Y = ui.px(20)}
				if ui.parent(nr) {
					label(u != nil ? dc.display_name(u) : "Unknown", .Semibold, 16, T("--text-strong"), 20)
					if sig.hovering && u != nil {
						spacer(.X, 4)
						label(u.username, .Medium, 14, T("--text-muted"), 18)
					}
				}
				sub := status_text(user_status(uid))
				#partial switch kind {
				case .Incoming_Request:
					sub = "Incoming Friend Request"
				case .Outgoing_Request:
					sub = "Outgoing Friend Request"
				}
				label(sub, .Medium, 14, T("--text-muted"), 18)
			}
			if kind == .Incoming_Request {
				if round_icon_button("accept", "check", T("--status-positive")).clicked && app.client != nil do dc.accept_friend_request(app.client, uid)
				spacer(.X, 10)
			}
			if kind == .Friend {
				round_icon_button("msg", "chat", T("--interactive-icon-hover"))
				spacer(.X, 10)
				round_icon_button("more", "more-vertical", T("--interactive-icon-hover"))
			} else {
				if round_icon_button("deny", "x-small", T("--status-danger")).clicked && app.client != nil do dc.remove_relationship(app.client, uid)
			}
			spacer(.X, 10)
		}
		spacer(.X, 20)
	}
}

round_icon_button :: proc(id, icon_name: string, hover_color: ui.Color) -> ui.Signal {
	b := ui.box(id, {.Clickable, .Draw_Background, .Hot_Animation})
	b.semantic_size = {.X = ui.px(36), .Y = ui.px(36)}
	b.style.radius = 18
	b.style.bg = T("--background-base-lowest")
	b.style.bg_hot = T("--background-base-lowest")
	b.layout_axis = .X
	b.cross_align = .Center
	sig := ui.signal(b)
	if ui.parent(b) {
		spacer(.X, 8)
		icon("i", icon_name, 20, sig.hovering ? hover_color : T("--interactive-icon-default"))
	}
	return sig
}

add_friend_view :: proc() {
	col := ui.box("addfriend")
	col.semantic_size = {.X = ui.pct(1), .Y = ui.fill()}
	col.layout_axis = .Y
	if ui.parent(col) {
		spacer(.Y, 20)
		r := row("title")
		r.semantic_size = {.X = ui.pct(1), .Y = ui.px(24)}
		if ui.parent(r) {
			spacer(.X, 30)
			label("Add Friend", .Semibold, 20, T("--text-strong"), 24)
		}
		spacer(.Y, 8)
		r2 := row("sub")
		r2.semantic_size = {.X = ui.pct(1), .Y = ui.px(20)}
		if ui.parent(r2) {
			spacer(.X, 30)
			label("You can add friends with their Discord username.", .Normal, 16, T("--text-default"), 20)
		}
		spacer(.Y, 16)
		r3 := row("inputrow")
		r3.semantic_size = {.X = ui.pct(1), .Y = ui.px(52)}
		if ui.parent(r3) {
			spacer(.X, 30)
			box := row("input", {.Draw_Background, .Draw_Border, .Clickable})
			box.semantic_size = {.X = ui.fill(), .Y = ui.px(52)}
			box.style.bg = T("--input-background-default")
			box.style.border_color = app.ui.focus == box.key ? T("--input-border-active") : T("--input-border-default")
			box.style.border = 1
			box.style.radius = 8
			box.hover_cursor = .IBeam
			if ui.signal(box).pressed do app.ui.focus = box.key
			if ui.parent(box) {
				spacer(.X, 16)
				res := text_field("field", &app.view.add_friend, "You can add friends with their Discord username.", app.ui.focus == box.key)
				name := strings.trim_space(ui.editor_text(&app.view.add_friend))
				spacer(.X, 12)
				btn := ui.box("Send Friend Request##send", {.Clickable, .Draw_Background, .Draw_Text, .Hot_Animation})
				btn.semantic_size = {.X = ui.text_size(16), .Y = ui.px(32)}
				btn.style.radius = 8
				btn.style.font = F(.Medium)
				btn.style.font_size = 14
				btn.style.text_align = .Center
				enabled := name != ""
				btn.style.bg = enabled ? T("--background-brand") : with_alpha(T("--background-brand"), 0.5)
				btn.style.bg_hot = btn.style.bg
				btn.style.text_color = enabled ? {1, 1, 1, 1} : {1, 1, 1, 0.5}
				if (ui.signal(btn).clicked || res == .Submit) && enabled && app.client != nil {
					dc.send_friend_request(app.client, name)
					ui.editor_set_text(&app.view.add_friend, "")
				}
				spacer(.X, 12)
			}
			spacer(.X, 30)
		}
	}
}

member_list :: proc(ch: ^dc.Channel) {
	s := store()
	list := ui.box("members", {.Scroll_Y, .Clip, .Draw_Background})
	list.semantic_size = {.X = ui.px(MEMBER_LIST_W), .Y = ui.pct(1)}
	list.layout_axis = .Y
	list.style.bg = T("--background-base-lower")
	ui.signal(list)
	ml, ok := s.member_lists[ch.guild_id]
	if app.client != nil && (!ok || len(ml.items) == 0) {
		dc.subscribe_member_list(app.client, ch.guild_id, ch.id, {{0, 99}})
	}
	if ui.parent(list) {
		spacer(.Y, 8)
		for it, i in ml.items {
			if ui.id_scope(u64(i)) {
				if it.is_group {
					gr := row("group")
					gr.semantic_size = {.X = ui.pct(1), .Y = ui.px(40)}
					gr.cross_align = .End
					if ui.parent(gr) {
						spacer(.X, 16)
						name := it.group_id
						switch it.group_id {
						case "online":
							name = "Online"
						case "offline":
							name = "Offline"
						case:
							if g := dc.guild_get(s, ch.guild_id); g != nil {
								for r in g.roles do if fmt.tprint(u64(r.id)) == it.group_id do name = r.name
							}
						}
						label(fmt.tprintf("%s — %d", name, it.count), .Medium, 12, T("--channels-default"), 16)
					}
					spacer(.Y, 4)
				} else {
					member_row(ch.guild_id, it.user_id)
				}
			}
		}
		spacer(.Y, 16)
	}
}

member_row :: proc(gid, uid: dc.Snowflake) {
	s := store()
	outer := row("m")
	outer.semantic_size = {.X = ui.pct(1), .Y = ui.px(44)}
	if ui.parent(outer) {
		spacer(.X, 8)
		item := row("item", {.Clickable, .Draw_Background, .Hot_Animation})
		item.semantic_size = {.X = ui.fill(), .Y = ui.px(42)}
		item.style.radius = 8
		item.style.bg_hot = T("--background-mod-subtle")
		sig := ui.signal(item)
		if sig.clicked do open_profile(uid, item.rect)
		offline := user_status(uid) == .Offline
		if ui.parent(item) {
			spacer(.X, 8)
			av := avatar_with_status("av", uid, 32, sig.hovering ? T("--background-base-low") : T("--background-base-lower"))
			if offline do av.opacity = 0.3
			spacer(.X, 12)
			name := "unknown"
			if m := dc.member_get(s, gid, uid); m != nil && m.nick != "" {
				name = m.nick
			} else if u := dc.user_get(s, uid); u != nil {
				name = dc.display_name(u)
			}
			color, has := member_color(gid, uid)
			if !has do color = T("--interactive-text-default")
			if offline do color = with_alpha(color, 0.3)
			label(name, .Medium, 16, color, 20)
		}
		spacer(.X, 8)
	}
}
