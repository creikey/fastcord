package app

import "core:fmt"
import "core:slice"
import "core:strings"
import "core:time"
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
		// opens the quick switcher, like the client (it used to do nothing)
		if ui.signal(btn).clicked && !sw.open do switcher_toggle()
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
		spacer(.Y, DM_SEP_GAP)
		sep := row("sep")
		sep.semantic_size = {.X = ui.pct(1), .Y = ui.px(1)}
		if ui.parent(sep) {
			spacer(.X, 17)
			l := ui.box("l", {.Draw_Background})
			l.semantic_size = {.X = ui.fill(), .Y = ui.px(1)}
			l.style.bg = T("--border-subtle")
			spacer(.X, 16)
		}
		spacer(.Y, DM_SEP_GAP - 1)
		header := row("dmheader")
		header.semantic_size = {.X = ui.pct(1), .Y = ui.px(DM_HEADER_H)}
		header.cross_align = .Start
		if ui.parent(header) {
			spacer(.X, 17)
			label("Direct Messages", .Medium, 14, T("--channels-default"), 18)
			filler(.X)
			dm_create_button() // view_group_dm.odin: "Select Friends" popout
			spacer(.X, 16)
		}
		dms := dc.private_channels_sorted(s)
		w := ui.list_window(list, DM_ROW_PITCH, len(dms))
		for cid in dms[w.first:w.last] {
			// A missing channel still takes its row, keeping the window's arithmetic exact.
			ch := dc.channel_get(s, cid)
			if ch == nil {
				spacer(.Y, DM_ROW_PITCH)
				continue
			}
			if ui.id_scope(u64(cid)) do dm_row(ch)
		}
		ui.list_window_end(w)
		spacer(.Y, USER_PANEL_H + 16)
	}
}

// Home sidebar geometry (official: nav rows 38px on a 40px pitch at x=81,
// "Direct Messages" heading at y=276, DM rows 42px on a 44px pitch).
DM_NAV_H :: 38
DM_NAV_PITCH :: 40
DM_SEP_GAP :: 13
DM_HEADER_H :: 24
DM_ROW_H :: 42
DM_ROW_PITCH :: 44

dm_nav_item :: proc(name: string, selected: bool) -> ui.Signal {
	outer := row(name)
	outer.semantic_size = {.X = ui.pct(1), .Y = ui.px(DM_NAV_PITCH)}
	sig: ui.Signal
	if ui.parent(outer) {
		spacer(.X, 9)
		item := row("item", {.Clickable, .Draw_Background, .Hot_Animation})
		item.semantic_size = {.X = ui.fill(), .Y = ui.px(DM_NAV_H)}
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
			icon("ic", icon_name, 20, color)
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
	outer.semantic_size = {.X = ui.pct(1), .Y = ui.px(DM_ROW_PITCH)}
	if ui.parent(outer) {
		spacer(.X, 9)
		item := row("item", {.Clickable, .Draw_Background, .Hot_Animation})
		item.semantic_size = {.X = ui.fill(), .Y = ui.px(DM_ROW_H)}
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
				group_dm_icon("gicon", ch, 32)
			}
			spacer(.X, 12)
			col := ui.box("col")
			col.semantic_size = {.X = ui.fill(), .Y = ui.children()}
			if ui.parent(col) {
				label(dm_name(ch), unread ? .Semibold : .Medium, 16, color, 20)
				if ch.kind == .Group_DM {
					n := len(ch.recipient_ids) + 1
					label(fmt.tprintf("%d Member%s", n, n == 1 ? "" : "s"), .Medium, 12, T("--text-muted"), 16)
				}
			}
			if selected || sig.hovering {
				// close DM / leave group: DELETE /channels/{id}
				x := ui.box("close", {.Clickable})
				x.semantic_size = {.X = ui.px(16), .Y = ui.px(16)}
				xs := ui.signal(x)
				set_icon(x, "x-small", xs.hovering ? T("--interactive-icon-hover") : T("--interactive-icon-default"))
				if xs.clicked && net_action() {
					dc.close_private_channel(app.client, ch.id)
					if selected do select_channel(0, 0)
				}
				spacer(.X, 6)
			}
		}
		spacer(.X, 12) // official rows are 282 wide (scrollbar gutter)
	}
}

// Sorts user ids by display name, case-insensitively; unknown users last, by id.
sort_users_by_name :: proc(ids: []dc.Snowflake) {
	// The first 8 lowercased bytes, big-endian, decide almost every comparison without touching the strings.
	Named :: struct {
		prefix: u64,
		name:   string,
		id:     dc.Snowflake,
		ok:     bool,
	}
	named := make([]Named, len(ids), context.temp_allocator)
	for id, i in ids {
		u := dc.user_get(store(), id)
		named[i] = {id = id, ok = u != nil}
		if u == nil do continue
		name := dc.display_name(u)
		ascii := true
		for c in transmute([]byte)name do if c >= 0x80 {ascii = false; break}
		if ascii {
			buf := make([]byte, len(name), context.temp_allocator)
			for c, j in transmute([]byte)name do buf[j] = c >= 'A' && c <= 'Z' ? c + 32 : c
			name = string(buf)
		} else {
			name = strings.to_lower(name, context.temp_allocator)
		}
		named[i].name = name
		for j in 0 ..< 8 do named[i].prefix = named[i].prefix << 8 | u64(j < len(name) ? name[j] : 0)
	}
	slice.sort_by(named, proc(a, b: Named) -> bool {
		if a.ok != b.ok do return a.ok
		if a.prefix != b.prefix do return a.prefix < b.prefix
		if a.name != b.name do return a.name < b.name
		return a.id < b.id
	})
	for n, i in named do ids[i] = n.id
}

friends_page :: proc() {
	s := store()
	h := row("header", {.Draw_Background})
	h.semantic_size = {.X = ui.pct(1), .Y = ui.px(HEADER_H - 1)}
	h.style.bg = T("--background-base-lower")
	if ui.parent(h) {
		spacer(.X, 22)
		icon("ficon", "friends", 20, T("--channel-icon"))
		spacer(.X, 6)
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
			spacer(.X, 16)
		}
		filler(.X)
		icon("newgroup", "chat-plus", 20, T("--icon-muted")) // New Group DM
		spacer(.X, 22)
	}
	line := ui.box("hline", {.Draw_Background})
	line.semantic_size = {.X = ui.pct(1), .Y = ui.px(1)}
	line.style.bg = T("--border-subtle")

	body := row("fbody")
	body.semantic_size = {.X = ui.pct(1), .Y = ui.fill()}
	body.cross_align = .Start
	ui.push_parent(body)
	defer ui.pop_parent()
	defer active_now_column()
	if app.view.friends_tab == .Add_Friend {
		add_friend_view()
		return
	}
	list := ui.box("friends", {.Scroll_Y, .Clip})
	list.semantic_size = {.X = ui.fill(), .Y = ui.pct(1)}
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
	// the search field filters by display name or username, like the client
	if q := strings.to_lower(strings.trim_space(ui.editor_text(&app.view.friends_search)), context.temp_allocator); q != "" {
		kept := 0
		for uid in ids {
			u := dc.user_get(s, uid)
			if u == nil do continue
			if strings.contains(strings.to_lower(dc.display_name(u), context.temp_allocator), q) || strings.contains(strings.to_lower(u.username, context.temp_allocator), q) {
				ids[kept] = uid
				kept += 1
			}
		}
		resize(&ids, kept)
	}
	sort_users_by_name(ids[:])
	if ui.parent(list) {
		spacer(.Y, 12)
		sr := row("searchrow")
		sr.semantic_size = {.X = ui.pct(1), .Y = ui.px(40)}
		if ui.parent(sr) {
			spacer(.X, FRIENDS_PAD_L)
			// was drawn as an input but took no clicks or typing
			search := row("search", {.Draw_Background, .Draw_Border, .Clickable})
			search.semantic_size = {.X = ui.fill(), .Y = ui.px(40)}
			search.style.bg = T("--input-background-default")
			search.style.border_color = app.ui.focus == search.key ? T("--input-border-active") : T("--input-border-default")
			search.style.border = 1
			search.style.radius = 8
			search.hover_cursor = .IBeam
			if ui.signal(search).pressed do app.ui.focus = search.key
			if ui.parent(search) {
				spacer(.X, 11)
				icon("mag", "magnifying-glass", 16, T("--icon-strong"))
				spacer(.X, 12)
				res := text_field("field", &app.view.friends_search, "Search", app.ui.focus == search.key && !modal_open(), 16, 20, 9, T("--input-placeholder-text-default"))
				if res == .Escape do ui.editor_set_text(&app.view.friends_search, "")
				spacer(.X, 12)
			}
			spacer(.X, FRIENDS_PAD_R)
		}
		spacer(.Y, 24)
		hdr := row("count")
		hdr.semantic_size = {.X = ui.pct(1), .Y = ui.px(18)}
		if ui.parent(hdr) {
			spacer(.X, FRIENDS_PAD_L)
			title := "Online"
			switch app.view.friends_tab {
			case .All:
				title = "All friends"
			case .Pending:
				title = "Pending"
			case .Online, .Add_Friend:
			}
			label(fmt.tprintf("%s — %d", title, len(ids)), .Medium, 14, T("--text-default"), 18)
		}
		spacer(.Y, 16)
		w := ui.list_window(list, FRIEND_ROW_H + 1, len(ids))
		for uid in ids[w.first:w.last] {
			if ui.id_scope(u64(uid)) do friend_row(uid, s.relationships[uid].kind)
		}
		ui.list_window_end(w)
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

// Friends list geometry (official: search 399..904 at y=95, rows 389..894, 61px + 1px divider).
FRIENDS_PAD_L :: 24
FRIENDS_PAD_R :: 16
FRIEND_ROW_H :: 61
ACTIVE_NOW_W :: 360 // including its 1px left border

// Opens (or creates) the DM with a friend, like clicking their row.
friend_open_dm :: proc(uid: dc.Snowflake) {
	if !net_action() do return
	if existing := dc.open_dm(app.client, uid, "Friends"); existing != 0 do select_channel(0, existing)
	else do app.pending_dm_user = uid
}

friend_row :: proc(uid: dc.Snowflake, kind: dc.Relationship_Type) {
	s := store()
	div := row("div")
	div.semantic_size = {.X = ui.pct(1), .Y = ui.px(1)}
	if ui.parent(div) {
		spacer(.X, 30)
		l := ui.box("l", {.Draw_Background})
		l.semantic_size = {.X = ui.fill(), .Y = ui.px(1)}
		l.style.bg = T("--border-subtle")
		spacer(.X, 36)
	}
	outer := row("f")
	outer.semantic_size = {.X = ui.pct(1), .Y = ui.px(FRIEND_ROW_H)}
	if ui.parent(outer) {
		spacer(.X, 14)
		item := row("item", {.Clickable, .Draw_Background, .Hot_Animation})
		item.semantic_size = {.X = ui.fill(), .Y = ui.px(FRIEND_ROW_H)}
		item.style.radius = 8
		item.style.bg_hot = T("--background-mod-subtle")
		sig := ui.signal(item)
		if sig.clicked do friend_open_dm(uid)
		if sig.right_clicked do open_user_menu(uid, app.ui.mouse)
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
				if round_icon_button("accept", "check", T("--status-positive")).clicked && net_action() do dc.accept_friend_request(app.client, uid)
				spacer(.X, 10)
			}
			if kind == .Friend {
				// were drawn but did nothing: Message opens the DM, More the user menu
				if round_icon_button("msg", "chat", T("--interactive-icon-hover")).clicked do friend_open_dm(uid)
				spacer(.X, 10)
				more := round_icon_button("more", "more-vertical", T("--interactive-icon-hover"))
				if more.clicked do open_user_menu(uid, {more.box.rect.x0, more.box.rect.y1 + 4})
			} else {
				if round_icon_button("deny", "x-small", T("--status-danger")).clicked && net_action() do dc.remove_relationship(app.client, uid)
			}
			spacer(.X, 10)
		}
		spacer(.X, 26)
	}
}

// Right column on the friends page: "Active Now" with the empty-state card.
active_now_column :: proc() {
	edge := ui.box("activenow_edge", {.Draw_Background})
	edge.semantic_size = {.X = ui.px(1), .Y = ui.pct(1)}
	edge.style.bg = T("--border-subtle")
	col := ui.box("activenow")
	col.semantic_size = {.X = ui.px(ACTIVE_NOW_W - 1), .Y = ui.pct(1)}
	col.layout_axis = .Y
	if ui.parent(col) {
		spacer(.Y, 14)
		h := row("h")
		h.semantic_size = {.X = ui.pct(1), .Y = ui.px(24)}
		if ui.parent(h) {
			spacer(.X, 16)
			label("Active Now", .Semibold, 20, T("--text-strong"), 24)
		}
		spacer(.Y, 9)
		cr := row("cardrow")
		cr.semantic_size = {.X = ui.pct(1), .Y = ui.children()}
		cr.cross_align = .Start
		if ui.parent(cr) {
			spacer(.X, 16)
			card := ui.box("card", {.Draw_Background})
			card.semantic_size = {.X = ui.fill(), .Y = ui.children()}
			card.layout_axis = .Y
			card.style.bg = T("--background-base-low")
			card.style.radius = 8
			if ui.parent(card) {
				spacer(.Y, 16)
				t := ui.box("It's quiet for now...##t", {.Draw_Text})
				t.semantic_size = {.X = ui.pct(1), .Y = ui.text_size()}
				t.style.font = F(.Semibold)
				t.style.font_size = 16
				t.style.line_height = 20
				t.style.text_color = T("--text-strong")
				t.style.text_align = .Center
				spacer(.Y, 2)
				b := ui.box("When a friend starts an activity—like playing a game or hanging out on voice—we'll show it here!##b", {.Draw_Text, .Wrap_Text})
				b.semantic_size = {.X = ui.pct(1), .Y = ui.text_size()}
				b.style.font = F(.Normal)
				b.style.font_size = 14
				b.style.line_height = 18
				b.style.padding = {16, 0}
				b.style.text_color = T("--text-muted")
				b.style.text_align = .Center
				spacer(.Y, 16)
			}
			spacer(.X, 16)
		}
	}
}

round_icon_button :: proc(id, icon_name: string, hover_color: ui.Color) -> ui.Signal {
	b := ui.box(id, {.Clickable, .Draw_Background, .Hot_Animation})
	b.semantic_size = {.X = ui.px(36), .Y = ui.px(36)}
	b.style.radius = 18
	b.style.bg_hot = T("--background-mod-subtle")
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
	col.semantic_size = {.X = ui.fill(), .Y = ui.pct(1)}
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
				res := text_field("field", &app.view.add_friend, "You can add friends with their Discord username.", app.ui.focus == box.key && !modal_open())
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
				if !enabled do btn.flags += {.Disabled}
				if (ui.signal(btn).clicked || res == .Submit) && enabled && net_action() {
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
		if sig.right_clicked do open_user_menu(uid, app.ui.mouse)
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

// Banner color for a profile without a banner image: the user's accent color,
// else the avatar's dominant color (as the client does), else brand.
profile_banner_color :: proc(uid: dc.Snowflake) -> ui.Color {
	if u := dc.user_get(store(), uid); u != nil {
		if ac, ok := u.accent_color.?; ok do return rgb_u32(ac)
	}
	if im := image_get(avatar_url_for(uid, 80)); im != nil && im.state == .Ready && im.dominant.a > 0 do return im.dominant
	return T("--background-brand")
}

// 1:1 DM user profile column (official: 306x(h-14) card inset 7px, banner 105,
// 80px avatar in a 6px ring, name/username, Member Since, View Full Profile).
DMP_COL_W :: 320
MONTH_SHORT := [12]string{"Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"}
DMP_INSET :: 7
DMP_BANNER_H :: 105
DMP_PAD :: 19
DMP_BTN :: 32

dm_profile_panel :: proc(uid: dc.Snowflake) {
	s := store()
	u := dc.user_get(s, uid)
	if u == nil do return
	col := ui.box("dmprofile")
	col.semantic_size = {.X = ui.px(DMP_COL_W), .Y = ui.pct(1)}
	col.layout_axis = .Y
	if ui.parent(col) {
		spacer(.Y, DMP_INSET)
		r := row("r")
		r.semantic_size = {.X = ui.pct(1), .Y = ui.fill()}
		r.cross_align = .Start
		if ui.parent(r) {
			spacer(.X, DMP_INSET)
			card := ui.box("card", {.Draw_Background, .Draw_Border, .Clip})
			card.semantic_size = {.X = ui.fill(), .Y = ui.pct(1)}
			card.layout_axis = .Y
			card.style.bg = T("--chat-background-default")
			card.style.border_color = T("--border-subtle")
			card.style.border = 1
			card.style.radius = 8
			surface := card.style.bg
			if ui.parent(card) {
				bw := row("bannerrow")
				bw.semantic_size = {.X = ui.pct(1), .Y = ui.px(DMP_BANNER_H + 3)}
				bw.cross_align = .End
				if ui.parent(bw) {
					spacer(.X, 2)
					banner := ui.box("banner", {.Draw_Background})
					banner.semantic_size = {.X = ui.fill(), .Y = ui.px(DMP_BANNER_H)}
					banner.style.radius = {6, 6, 0, 0}
					banner.style.bg = profile_banner_color(uid)
					if u.banner != "" do set_remote_image(banner, dc.banner_url(uid, u.banner, 600))
					if ui.parent(banner) {
						btns := row("btns", {.Floating_X, .Floating_Y})
						btns.semantic_size = {.X = ui.children(), .Y = ui.px(DMP_BTN)}
						btns.fixed_pos = {DMP_COL_W - 2 * DMP_INSET - 4 - 9 - 2 * DMP_BTN - 8, 8}
						if ui.parent(btns) {
							rel := s.relationships[uid].kind
							names := []string{rel == .Friend ? "user-check" : "user-plus", "more-horizontal"}
							for name, i in names {
								b := ui.box(name, {.Clickable, .Draw_Background, .Hot_Animation})
								b.semantic_size = {.X = ui.px(DMP_BTN), .Y = ui.px(DMP_BTN)}
								b.style.radius = DMP_BTN / 2
								b.style.bg = {0, 0, 0, 0.36}
								b.style.bg_hot = {0, 0, 0, 0.5}
								sig := ui.signal(b)
								if ui.parent(b) {
									ic := icon("i", name, 18, {1, 1, 1, 1})
									ic.flags += {.Floating_X, .Floating_Y}
									ic.fixed_pos = {7, 7}
								}
								if sig.clicked && i == 0 && rel == .None && net_action() do dc.add_relationship(app.client, uid, "User Profile")
								// "…" and the friends check open the user menu (Remove Friend, Block, …)
								if sig.clicked && (i == 1 || rel == .Friend) do open_user_menu(uid, {b.rect.x0, b.rect.y1 + 4})
								if i == 0 do spacer(.X, 8)
							}
						}
					}
					spacer(.X, 2)
				}
				av := ui.box("avrow")
				av.semantic_size = {.X = ui.pct(1), .Y = ui.px(48)}
				if ui.parent(av) {
					ring := ui.box("ring", {.Draw_Background, .Floating_X, .Floating_Y})
					ring.semantic_size = {.X = ui.px(92), .Y = ui.px(92)}
					ring.fixed_pos = {13, -52}
					ring.style.radius = 46
					ring.style.bg = surface
					if ui.parent(ring) {
						a := avatar_with_status("av", uid, 80, surface)
						a.flags += {.Floating_X, .Floating_Y}
						a.fixed_pos = {6, 6}
					}
				}
				line :: proc(id, text: string, font: Font_Id, size, lh: f32, color: ui.Color) {
					r := row(id)
					r.semantic_size = {.X = ui.pct(1), .Y = ui.px(lh)}
					if ui.parent(r) {
						spacer(.X, DMP_PAD)
						l := label(text, font, size, color, lh)
						l.flags += {.Selectable_Text}
					}
				}
				line("name", dc.display_name(u), .Semibold, 20, 24, T("--text-strong"))
				spacer(.Y, 2)
				line("user", u.username, .Normal, 14, 18, T("--text-strong"))
				spacer(.Y, 20)
				line("since_h", "Member Since", .Semibold, 12, 16, T("--text-strong"))
				spacer(.Y, 6)
				created := dc.snowflake_time_ms(uid) + local_utc_offset_ms()
				t := time.unix(created / 1000, 0)
				y, mo, d := time.date(t)
				line("since", fmt.tprintf("%s %d, %d", MONTH_SHORT[int(mo) - 1], d, y), .Normal, 14, 18, T("--text-default"))
				filler(.Y)
				br := row("viewfull")
				br.semantic_size = {.X = ui.pct(1), .Y = ui.px(40)}
				if ui.parent(br) {
					spacer(.X, DMP_PAD)
					b := ui.box("View Full Profile##vfp", {.Clickable, .Draw_Background, .Draw_Text, .Hot_Animation})
					b.semantic_size = {.X = ui.fill(), .Y = ui.px(40)}
					b.style.radius = 8
					b.style.bg = T("--background-mod-subtle")
					b.style.bg_hot = T("--background-mod-normal")
					b.style.font = F(.Medium)
					b.style.font_size = 16
					b.style.text_align = .Center
					b.style.text_color = T("--text-strong")
					if ui.signal(b).clicked do profile_full_open(uid)
					spacer(.X, 16)
				}
				spacer(.Y, 18)
			}
			spacer(.X, DMP_INSET)
		}
		spacer(.Y, DMP_INSET)
	}
}

// Top of a DM's history: big avatar, names, "This is the beginning of your
// direct message history with **name**.", mutual servers and friend actions.
DMW_AVATAR :: 80
DMW_GAP :: 8 // welcome header to the first date divider
DMW_H :: 16 + DMW_AVATAR + 12 + 40 + 8 + 32 + 20 + 20 + 8 + 32 // see dm_welcome

dm_welcome :: proc(ch: ^dc.Channel) -> ^ui.Box {
	s := store()
	uid := ch.recipient_ids[0]
	u := dc.user_get(s, uid)
	w := ui.box("dmwelcome")
	w.semantic_size = {.X = ui.pct(1), .Y = ui.px(DMW_H)}
	w.layout_axis = .Y
	if u == nil do return w
	if ui.parent(w) {
		pad :: proc(id: string, h: f32) -> ^ui.Box {
			r := row(id)
			r.semantic_size = {.X = ui.pct(1), .Y = ui.px(h)}
			return r
		}
		spacer(.Y, 16)
		if r := pad("av", DMW_AVATAR); ui.parent(r) {
			spacer(.X, 16)
			avatar_box("a", uid, DMW_AVATAR)
		}
		spacer(.Y, 12)
		if r := pad("name", 40); ui.parent(r) {
			spacer(.X, 16)
			label(dc.display_name(u), .Bold, 32, T("--text-strong"), 40)
		}
		spacer(.Y, 8)
		if r := pad("user", 32); ui.parent(r) {
			spacer(.X, 16)
			label(u.username, .Medium, 24, T("--text-strong"), 32)
		}
		spacer(.Y, 20)
		if r := pad("begin", 20); ui.parent(r) {
			spacer(.X, 16)
			t := ui.box("t")
			t.semantic_size = {.X = ui.text_size(0, 0), .Y = ui.px(20)}
			t.style.line_height = 20
			t.style.text_color = T("--text-default")
			spans := make([]ui.Span, 3, context.temp_allocator)
			spans[0] = {text = "This is the beginning of your direct message history with ", font = F(.Normal), size = 16}
			spans[1] = {text = dc.display_name(u), font = F(.Bold), size = 16}
			spans[2] = {text = ".", font = F(.Normal), size = 16}
			ui.set_spans(t, spans)
		}
		spacer(.Y, 8)
		if r := pad("actions", 32); ui.parent(r) {
			spacer(.X, 16)
			mutual := "No servers in common"
			if u.mutual_guilds > 0 do mutual = fmt.tprintf("%d Mutual Server%s", u.mutual_guilds, u.mutual_guilds == 1 ? "" : "s")
			label(mutual, .Normal, 14, T("--text-default"), 18)
			spacer(.X, 12)
			dot := ui.box("dot", {.Draw_Background})
			dot.semantic_size = {.X = ui.px(4), .Y = ui.px(4)}
			dot.style.radius = 2
			dot.style.bg = T("--interactive-muted")
			spacer(.X, 12)
			rel := s.relationships[uid].kind
			btn :: proc(text: string, primary: bool) -> bool {
				b := ui.box(text, {.Clickable, .Draw_Background, .Draw_Text, .Hot_Animation})
				b.semantic_size = {.X = ui.text_size(12), .Y = ui.px(32)}
				b.style.radius = 8
				b.style.font = F(.Medium)
				b.style.font_size = 14
				b.style.text_align = .Center
				b.style.text_color = primary ? ui.Color{1, 1, 1, 1} : T("--text-strong")
				b.style.bg = primary ? T("--background-brand") : T("--background-mod-normal")
				b.style.bg_hot = primary ? with_alpha(T("--background-brand"), 0.85) : T("--background-mod-strong")
				clicked := ui.signal(b).clicked
				spacer(.X, 8)
				return clicked
			}
			switch rel {
			case .Friend:
				if btn("Remove Friend", false) && net_action() do dc.remove_relationship(app.client, uid, "DM Header")
				if btn("Block", false) do block_confirm = {uid, "DM Header"}
			case .Blocked:
				if btn("Unblock", false) && net_action() do dc.remove_relationship(app.client, uid, "DM Header")
			case .Outgoing_Request:
				btn("Friend Request Sent", false)
				if btn("Block", false) do block_confirm = {uid, "DM Header"}
			case .Incoming_Request:
				if btn("Accept", true) && net_action() do dc.accept_friend_request(app.client, uid)
				if btn("Ignore", false) && net_action() do dc.ignore_friend_request(app.client, uid)
				if btn("Block", false) do block_confirm = {uid, "DM Header"}
			case .None, .Implicit:
				if btn("Add Friend", true) && net_action() do dc.add_relationship(app.client, uid, "DM Header")
				if btn("Block", false) do block_confirm = {uid, "DM Header"}
			}
		}
	}
	return w
}

// Icon-less group DMs get one of 8 default icons by snowflake timestamp
// ((id >> 22) % 8). Colors measured from the client; unmeasured slots fall back to brand.
group_icon_color :: proc(cid: dc.Snowflake) -> ui.Color {
	switch (u64(cid) >> 22) % 8 {
	case 0:
		return {0xd3 / 255.0, 0x78 / 255.0, 0x37 / 255.0, 1}
	case 5:
		return {0x88 / 255.0, 0x52 / 255.0, 0xa8 / 255.0, 1}
	case 7:
		return {0xd3 / 255.0, 0x4f / 255.0, 0x3f / 255.0, 1}
	}
	return T("--background-brand")
}

// A group DM's round icon: its custom icon, else the default colored one.
group_dm_icon :: proc(id: string, ch: ^dc.Channel, size: f32) -> ^ui.Box {
	g := ui.box(id, {.Draw_Background})
	g.semantic_size = {.X = ui.px(size), .Y = ui.px(size)}
	g.style.radius = size / 2
	g.style.bg = group_icon_color(ch.id)
	if ch.icon != "" {
		set_remote_image(g, fmt.tprintf("https://cdn.discordapp.com/channel-icons/%d/%s.webp?size=%d", u64(ch.id), ch.icon, int(size * 2)))
	} else if ui.parent(g) {
		inner := ui.box("i", {.Floating_X, .Floating_Y})
		inner.semantic_size = {.X = ui.px(size * 0.625), .Y = ui.px(size * 0.625)}
		inner.fixed_pos = {size * 0.1875, size * 0.1875}
		set_icon(inner, "group", {1, 1, 1, 1})
	}
	return g
}

// "Block <name>?" confirmation (the client's confirm modal, same frame as Delete Message).
Block_Confirm :: struct {
	user:     dc.Snowflake,
	location: string, // X-Context-Properties location of the button that asked
}
block_confirm: Block_Confirm

block_confirm_modal :: proc() {
	uid := block_confirm.user
	u := dc.user_get(store(), uid)
	if u == nil {
		block_confirm = {}
		return
	}
	name := dc.display_name(u)
	scrim := ui.box("block_scrim", {.Draw_Background, .Clickable, .Floating_X, .Floating_Y, .Overlay})
	scrim.semantic_size = {.X = ui.px(app.ui.window.x), .Y = ui.px(app.ui.window.y)}
	scrim.style.bg = {0, 0, 0, 0.7}
	if ui.signal(scrim).clicked {
		block_confirm = {}
		return
	}
	W :: 480
	PAD :: 24
	confirm := false
	d := ui.box("blockmodal", {.Draw_Background, .Draw_Border, .Floating_X, .Floating_Y, .Overlay, .Clickable})
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
		if xs.clicked do block_confirm = {}
		spacer(.Y, PAD + 1)
		t := row("t")
		t.semantic_size = {.X = ui.pct(1), .Y = ui.px(24)}
		if ui.parent(t) {
			spacer(.X, PAD + 1)
			label(fmt.tprintf("Block %s?", name), .Semibold, 20, T("--text-strong"), 24)
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
			spans[0] = {text = "Are you sure you want to block ", font = F(.Normal), size = 16}
			spans[1] = {text = name, font = F(.Bold), size = 16}
			spans[2] = {text = "? Blocking this user will also remove them from your friends list.", font = F(.Normal), size = 16}
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
			if ui.signal(cancel).clicked do block_confirm = {}
			ok := ui.box("Block##b", {.Clickable, .Draw_Background, .Draw_Text, .Hot_Animation})
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
	for e in app.ui.events {
		if e.kind == .Key_Down && e.key == .Escape do block_confirm = {}
		if e.kind == .Key_Down && e.key == .Enter do confirm = true
	}
	if confirm {
		if net_action() do dc.block_user(app.client, uid, block_confirm.location)
		block_confirm = {}
	}
}

// Top of a guild text channel's history: a 68px circle with the channel icon,
// "Welcome to #name!" and "This is the start of the #name channel." (+ the
// topic), and "Edit Channel" for members who can manage channels.
CHW_ICON :: 68
PERM_MANAGE_CHANNELS :: u64(1) << 4

channel_welcome_height :: proc(ch: ^dc.Channel) -> f32 {
	h: f32 = 16 + CHW_ICON + 8 + 40 + 8 + 20
	if my_guild_permissions(ch.guild_id) & PERM_MANAGE_CHANNELS != 0 do h += 8 + 20
	return h
}

channel_welcome :: proc(ch: ^dc.Channel) {
	w := ui.box("chwelcome")
	w.semantic_size = {.X = ui.pct(1), .Y = ui.px(channel_welcome_height(ch))}
	w.layout_axis = .Y
	if ui.parent(w) {
		spacer(.Y, 16)
		r := row("icon")
		r.semantic_size = {.X = ui.pct(1), .Y = ui.px(CHW_ICON)}
		if ui.parent(r) {
			spacer(.X, 16)
			c := ui.box("circle", {.Draw_Background})
			c.semantic_size = {.X = ui.px(CHW_ICON), .Y = ui.px(CHW_ICON)}
			c.style.radius = CHW_ICON / 2
			c.style.bg = T("--background-mod-normal")
			if ui.parent(c) {
				ic := icon("i", channel_icon_name(ch), 42, T("--text-strong"))
				ic.flags += {.Floating_X, .Floating_Y}
				ic.fixed_pos = {(CHW_ICON - 42) / 2, (CHW_ICON - 42) / 2}
			}
		}
		spacer(.Y, 8)
		h := row("h")
		h.semantic_size = {.X = ui.pct(1), .Y = ui.px(40)}
		if ui.parent(h) {
			spacer(.X, 16)
			label(fmt.tprintf("Welcome to #%s!", ch.name), .Bold, 32, T("--text-strong"), 40)
		}
		spacer(.Y, 8)
		t := row("t")
		t.semantic_size = {.X = ui.pct(1), .Y = ui.px(20)}
		if ui.parent(t) {
			spacer(.X, 16)
			label(fmt.tprintf("This is the start of the #%s channel.", ch.name), .Normal, 16, T("--text-muted"), 20)
		}
		if my_guild_permissions(ch.guild_id) & PERM_MANAGE_CHANNELS != 0 {
			spacer(.Y, 8)
			e := row("edit")
			e.semantic_size = {.X = ui.pct(1), .Y = ui.px(20)}
			if ui.parent(e) {
				spacer(.X, 16)
				b := row("editbtn", {.Clickable})
				b.semantic_size = {.X = ui.children(), .Y = ui.px(20)}
				ui.signal(b)
				if ui.parent(b) {
					icon("i", "pencil", 16, T("--text-link"))
					spacer(.X, 4)
					label("Edit Channel", .Medium, 14, T("--text-link"), 18)
				}
			}
		}
	}
}
