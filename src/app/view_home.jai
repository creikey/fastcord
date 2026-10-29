home_sidebar :: () {
	s := store();
	search := row("search");
	search.semantic_size = .[ui.pct(1), ui.px(HEADER_H - 1)];
	{ ui.parent(search); defer ui.pop_parent();
		spacer(.X, 8);
		btn := ui.box("Find or start a conversation##btn", .Clickable | .Draw_Background | .Draw_Border | .Draw_Text);
		btn.semantic_size = .[ui.fill(), ui.px(32)];
		btn.style.bg = T("--background-mod-subtle");
		btn.style.border_color = T("--border-muted");
		btn.style.border = 1;
		btn.style.radius = all4(8);
		btn.style.font = F(.Medium);
		btn.style.font_size = 14;
		btn.style.text_color = T("--text-strong");
		btn.style.text_align = .Center;
		// opens the quick switcher, like the client (it used to do nothing)
		if ui.signal(btn).clicked && !sw.open { switcher_toggle(); }
		spacer(.X, 8);
	}
	line := ui.box("hline", .Draw_Background);
	line.semantic_size = .[ui.pct(1), ui.px(1)];
	line.style.bg = T("--border-subtle");

	list := ui.box("dms", .Scroll_Y | .Clip);
	list.semantic_size = .[ui.pct(1), ui.fill()];
	list.bar_inset_bottom = USER_PANEL_H + voice_panel_height() + 16; // the panel floats over the list's end
	list.layout_axis = .Y;
	ui.signal(list);
	{ ui.parent(list); defer ui.pop_parent();
		spacer(.Y, 8);
		if dm_nav_item("Friends", app.view.channel == 0).clicked {
			friends_tab_telemetry("friends_list_clicked");
			select_channel(0, 0);
		}
		spacer(.Y, DM_SEP_GAP);
		sep := row("sep");
		sep.semantic_size = .[ui.pct(1), ui.px(1)];
		{ ui.parent(sep); defer ui.pop_parent();
			spacer(.X, 17);
			l := ui.box("l", .Draw_Background);
			l.semantic_size = .[ui.fill(), ui.px(1)];
			l.style.bg = T("--border-subtle");
			spacer(.X, 16);
		}
		spacer(.Y, DM_SEP_GAP - 1);
		header := row("dmheader");
		header.semantic_size = .[ui.pct(1), ui.px(DM_HEADER_H)];
		header.cross_align = .Start;
		{ ui.parent(header); defer ui.pop_parent();
			spacer(.X, 17);
			label("Direct Messages", .Medium, 14, T("--channels-default"), 18);
			filler(.X);
			dm_create_button(); // view_group_dm.jai: "Select Friends" popout
			spacer(.X, 16);
		}
		if store_loading() {
			// before READY: placeholder rows, not an empty list
			for i: 0..9 {
				ui.id_scope(cast(u64) i); defer ui.pop_seed();
				r := row("skel");
				r.semantic_size = .[ui.pct(1), ui.px(DM_ROW_PITCH)];
				ui.parent(r); defer ui.pop_parent();
				spacer(.X, 18);
				skel("av", 32, 32, true);
				spacer(.X, 12);
				skel("name", cast(float32) (60 + (i * 41) % 80), 14);
			}
		}
		dms := undo_filter(dc.private_channels_sorted(s));
		w := ui.list_window(list, DM_ROW_PITCH, dms.count);
		for cid: array_view(dms, w.first, w.last - w.first) {
			// A missing channel still takes its row, keeping the window's arithmetic exact.
			ch := dc.channel_get(s, cid);
			if ch == null {
				spacer(.Y, DM_ROW_PITCH);
				continue;
			}
			{ ui.id_scope(cast(u64)(cid)); defer ui.pop_seed(); dm_row(ch); }
		}
		ui.list_window_end(w);
		spacer(.Y, USER_PANEL_H + voice_panel_height() + 16);
	}
}

// Home sidebar geometry (official: nav rows 38px on a 40px pitch at x=81,
// "Direct Messages" heading at y=276, DM rows 42px on a 44px pitch).
DM_NAV_H :: 38;
DM_NAV_PITCH :: 40;
DM_SEP_GAP :: 13;
DM_HEADER_H :: 24;
DM_ROW_H :: 42;
DM_ROW_PITCH :: 44;

dm_nav_item :: (name: string, selected: bool) -> ui.Signal {
	outer := row(name);
	outer.semantic_size = .[ui.pct(1), ui.px(DM_NAV_PITCH)];
	sig: ui.Signal;
	{ ui.parent(outer); defer ui.pop_parent();
		spacer(.X, 9);
		item := row("item", .Clickable | .Draw_Background | .Hot_Animation);
		item.semantic_size = .[ui.fill(), ui.px(DM_NAV_H)];
		item.style.radius = all4(8);
		item.style.bg = ifx selected then T("--background-mod-normal") else .{};
		item.style.bg_hot = ifx selected then item.style.bg else T("--background-mod-subtle");
		sig = ui.signal(item);
		icon_name := "friends";
		{ ui.parent(item); defer ui.pop_parent();
			color := ifx selected || sig.hovering then T("--interactive-text-active") else T("--channels-default");
			spacer(.X, 8);
			icon("ic", icon_name, 20, color);
			spacer(.X, 12);
			label(name, .Medium, 16, color, 20);
		}
		spacer(.X, 8);
	}
	return sig;
}

dm_row :: (ch: *dc.Channel) {
	selected := app.view.channel == ch.id;
	outer := row("dm");
	outer.semantic_size = .[ui.pct(1), ui.px(DM_ROW_PITCH)];
	{ ui.parent(outer); defer ui.pop_parent();
		spacer(.X, 9);
		item := row("item", .Clickable | .Draw_Background | .Hot_Animation);
		item.semantic_size = .[ui.fill(), ui.px(DM_ROW_H)];
		item.style.radius = all4(8);
		item.style.bg = ifx selected then T("--background-mod-normal") else .{};
		item.style.bg_hot = ifx selected then item.style.bg else T("--background-mod-subtle");
		sig := ui.signal(item);
		if sig.clicked { select_channel(0, ch.id, prefetch = true); }
		// 1:1 DM rows: the user menu (Add Friend, friend nickname, ...)
		if sig.right_clicked && ch.kind == .DM && ch.recipient_ids.count > 0 { open_user_menu(ch.recipient_ids[0], app.ui.mouse, dm = ch.id); }
		if sig.right_clicked && ch.kind == .Group_DM { group_dm_menu_open(ch.id, app.ui.mouse); }
		unread := dc.channel_unread(store(), ch.id);
		color := ifx selected || sig.hovering || unread then T("--interactive-text-active") else T("--channels-default");
		{ ui.parent(item); defer ui.pop_parent();
			spacer(.X, 8);
			if ch.kind == .DM && ch.recipient_ids.count > 0 {
				avatar_with_status("av", ch.recipient_ids[0], 32, T("--background-base-lower"));
			} else {
				group_dm_icon("gicon", ch, 32);
			}
			spacer(.X, 12);
			col := ui.box("col");
			col.semantic_size = .[ui.fill(), ui.children()];
			{ ui.parent(col); defer ui.pop_parent();
				label(dm_name(ch), ifx unread then .Semibold else .Medium, 16, color, 20);
				if ch.kind == .Group_DM {
					n := ch.recipient_ids.count + 1;
					label(tprint("% Member%", n, ifx n == 1 then "" else "s"), .Medium, 12, T("--text-muted"), 16);
				} else if ch.recipient_ids.count > 0 {
					custom := user_custom_status(ch.recipient_ids[0]);
					if custom label(ellipsize(custom, .Medium, 12, item.rect.x1 - item.rect.x0 - 90), .Medium, 12, T("--text-muted"), 16);
				}
			}
			mentions := channel_mentions(ch.id);
			if mentions > 0 && !selected && !ui.mouse_over(item) && !notify_prefs.lotus {
				text := ifx mentions > 99 then "99+" else tprint("%", mentions);
				b := ui.box(tprint("%##count", text), .Draw_Background | .Draw_Text);
				b.semantic_size = .[ui.px(max(16.0, cast(float32) text.count * 7 + 8)), ui.px(16)];
				b.style.bg = T("--status-danger");
				b.style.radius = all4(8);
				b.style.font = F(.Bold);
				b.style.font_size = 12;
				b.style.text_color = .{1, 1, 1, 1};
				b.style.text_align = .Center;
				spacer(.X, 6);
			}
			if selected || ui.mouse_over(item) { // not sig.hovering: that ends while the X itself is hovered
				// close DM or leave the group: DELETE /channels/{id}, behind Undo
				x := ui.box("close", .Clickable);
				x.semantic_size = .[ui.px(16), ui.px(16)];
				xs := ui.signal(x);
				set_icon(x, "x-small", ifx xs.hovering then T("--interactive-icon-hover") else T("--interactive-icon-default"));
				if xs.clicked close_private_now(ch);
				spacer(.X, 6);
			}
		}
		spacer(.X, 12); // official rows are 282 wide (scrollbar gutter)
	}
}

// Sorts user ids by display name, case-insensitively; unknown users last, by id.
sort_users_by_name :: (ids: []dc.Snowflake) {
	// The first 8 lowercased bytes, big-endian, decide almost every comparison without touching the strings.
	Named :: struct {
		prefix: u64;
		name: string;
		id: dc.Snowflake;
		ok: bool;
	}
	named := NewArray(ids.count, Named,, temp);
	for id, i: ids {
		name := to_lower_copy(dc.user_name(store(), id),, temp); // ASCII only (Odin lowered Unicode)
		named[i] = .{id = id, ok = name != "", name = name};
		for j: 0..7 { named[i].prefix = (named[i].prefix << 8) | (cast(u64) ifx j < name.count then name[j] else 0); }
	}
	quick_sort(named, (a: Named, b: Named) -> int {
		if a.ok != b.ok { return ifx a.ok then -1 else 1; }
		if a.prefix != b.prefix { return ifx a.prefix < b.prefix then -1 else 1; }
		if a.name != b.name { return compare(a.name, b.name); }
		return ifx a.id < b.id then -1 else ifx a.id > b.id then 1 else 0;
	});
	for named ids[it_index] = it.id;
}

friends_page :: () {
	s := store();
	h := row("header", .Draw_Background);
	h.semantic_size = .[ui.pct(1), ui.px(HEADER_H - 1)];
	h.style.bg = T("--background-base-lower");
	{ ui.parent(h); defer ui.pop_parent();
		spacer(.X, 22);
		icon("ficon", "friends", 20, T("--channel-icon"));
		spacer(.X, 6);
		label("Friends", .Semibold, 16, T("--text-strong"), 20);
		spacer(.X, 12);
		dot := ui.box("dot", .Draw_Background);
		dot.semantic_size = .[ui.px(4), ui.px(4)];
		dot.style.radius = all4(2);
		dot.style.bg = T("--interactive-muted");
		spacer(.X, 12);
		tabs := struct {
			name: string;
			tab: Friends_Tab;
		}.[.{"Online", .Online}, .{"All", .All}, .{"Pending", .Pending}, .{"Add Friend", .Add_Friend}];
		for t: tabs {
			if t.tab == .Pending && !has_pending() { continue; } // outgoing requests alone keep it, to cancel them
			sel := app.view.friends_tab == t.tab;
			tb := ui.box(t.name, .Clickable | .Draw_Background | .Draw_Text | .Hot_Animation);
			tb.semantic_size = .[ui.text_size(12), ui.px(32)];
			tb.style.radius = all4(8);
			tb.style.font = F(.Medium);
			tb.style.font_size = 16;
			tb.style.text_align = .Center;
			tb.style.text_color = ifx sel then T("--interactive-text-active") else T("--interactive-text-default");
			tb.style.bg = ifx sel then T("--background-mod-normal") else .{};
			tb.style.bg_hot = ifx sel then tb.style.bg else T("--background-mod-subtle");
			if t.tab == .Add_Friend {
				tb.style.bg = ifx sel then T("--interactive-accent-background-default") else T("--background-brand");
				tb.style.text_color = ifx sel then T("--text-brand") else .{1, 1, 1, 1};
				tb.style.bg_hot = tb.style.bg;
			}
			if ui.signal(tb).clicked {
				app.view.friends_tab = t.tab;
				// the tab click, then the tab's view (the library throttles views per
				// tab; the page's first view is dc.friends_page_viewed on the route change)
				friends_tab_telemetry("friends_list_clicked");
				friends_tab_telemetry("friends_list_viewed");
			}
			spacer(.X, 16);
		}
		filler(.X);
		ng := icon("newgroup", "chat-plus", 20, T("--icon-muted"), .Clickable); // New Group DM: the Create DM popout
		ngs := ui.signal(ng);
		if ngs.hovering { set_icon(ng, "chat-plus", T("--interactive-icon-hover")); tooltip_below("New Group DM", ng.rect); }
		if ngs.clicked group_dm_popout_open(ng.rect, 0);
		spacer(.X, 22);
	}
	line := ui.box("hline", .Draw_Background);
	line.semantic_size = .[ui.pct(1), ui.px(1)];
	line.style.bg = T("--border-subtle");

	body := row("fbody");
	body.semantic_size = .[ui.pct(1), ui.fill()];
	body.cross_align = .Start;
	ui.push_parent(body);
	defer ui.pop_parent();
	defer active_now_column();
	if app.view.friends_tab == .Add_Friend {
		add_friend_view();
		return;
	}
	list := ui.box("friends", .Scroll_Y | .Clip);
	list.semantic_size = .[ui.fill(), ui.pct(1)];
	list.layout_axis = .Y;
	ui.signal(list);
	ids: [..]dc.Snowflake;
	ids.allocator = temp;
	for rel, uid: s.relationships {
		if app.view.friends_tab == {
		case .Online;
			if rel.kind == .Friend && user_status(uid) != .Offline { array_add(*ids, uid); }
		case .All;
			if rel.kind == .Friend { array_add(*ids, uid); }
		case .Pending;
			if rel.kind == .Incoming_Request || rel.kind == .Outgoing_Request { array_add(*ids, uid); }
		case .Add_Friend;
		}
	}
	// the search field filters by display name or username, like the client
	q := to_lower_copy(trim(ui.editor_text(*app.view.friends_search)),, temp);
	if q != "" {
		kept := 0;
		for uid: ids {
			u := dc.user_get(s, uid);
			if u == null { continue; }
			if contains(to_lower_copy(dc.user_name(s, uid),, temp), q) || contains(to_lower_copy(dc.display_name(u),, temp), q) || contains(to_lower_copy(u.username,, temp), q) {
				ids[kept] = uid;
				kept += 1;
			}
		}
		ids.count = kept;
	}
	sort_users_by_name(ids);
	{ ui.parent(list); defer ui.pop_parent();
		spacer(.Y, 12);
		sr := row("searchrow");
		sr.semantic_size = .[ui.pct(1), ui.px(40)];
		{ ui.parent(sr); defer ui.pop_parent();
			spacer(.X, FRIENDS_PAD_L);
			// was drawn as an input but took no clicks or typing
			search := row("search", .Draw_Background | .Draw_Border | .Clickable);
			search.semantic_size = .[ui.fill(), ui.px(40)];
			search.style.bg = T("--input-background-default");
			search.style.border_color = ifx app.ui.focus == search.key then T("--input-border-active") else T("--input-border-default");
			search.style.border = 1;
			search.style.radius = all4(8);
			search.hover_cursor = .IBeam;
			if ui.signal(search).pressed { app.ui.focus = search.key; }
			{ ui.parent(search); defer ui.pop_parent();
				spacer(.X, 11);
				icon("mag", "magnifying-glass", 16, T("--icon-strong"));
				spacer(.X, 12);
				res := text_field("field", *app.view.friends_search, "Search", app.ui.focus == search.key && !modal_open(), 16, 20, 9, T("--input-placeholder-text-default"));
				if res == .Escape { ui.editor_set_text(*app.view.friends_search, ""); }
				spacer(.X, 12);
			}
			spacer(.X, FRIENDS_PAD_R);
		}
		spacer(.Y, 24);
		hdr := row("count");
		hdr.semantic_size = .[ui.pct(1), ui.px(18)];
		{ ui.parent(hdr); defer ui.pop_parent();
			spacer(.X, FRIENDS_PAD_L);
			title := "Online";
			if app.view.friends_tab == {
			case .All;
				title = "All friends";
			case .Pending;
				title = "Pending";
			case .Online; #through; case .Add_Friend;
			}
			label(ifx store_loading() then title else tprint("% — %", title, ids.count), .Medium, 14, T("--text-default"), 18); // no count before READY
		}
		spacer(.Y, 16);
		w := ui.list_window(list, FRIEND_ROW_H + 1, ids.count);
		for uid: array_view(ids, w.first, w.last - w.first) {
			ui.id_scope(cast(u64)(uid)); defer ui.pop_seed();
			friend_row(uid, relationship(uid));
		}
		ui.list_window_end(w);
		if store_loading() {
			for i: 0..5 {
				ui.id_scope(cast(u64) i); defer ui.pop_seed();
				r := row("skel");
				r.semantic_size = .[ui.pct(1), ui.px(FRIEND_ROW_H + 1)];
				ui.parent(r); defer ui.pop_parent();
				spacer(.X, 24);
				skel("av", 32, 32, true);
				spacer(.X, 12);
				skel("name", cast(float32) (80 + (i * 41) % 90), 14);
			}
		} else if ids.count == 0 {
			spacer(.Y, 80);
			msg := ifx app.view.friends_tab == .Pending then "There are no pending friend requests." else "No one's around right now.";
			e := row("empty");
			e.semantic_size = .[ui.pct(1), ui.px(24)];
			{ ui.parent(e); defer ui.pop_parent();
				filler(.X);
				label(msg, .Normal, 16, T("--text-muted"), 20);
				filler(.X);
			}
		}
	}
}

has_pending :: () -> bool {
	for store().relationships if it.kind == .Incoming_Request || it.kind == .Outgoing_Request return true;
	return false;
}

pending_count :: () -> int {
	n := 0;
	for rel: store().relationships {
		if rel.kind == .Incoming_Request { n += 1; }
	}
	return n;
}

// Friends list geometry (official: search 399..904 at y=95, rows 389..894, 61px + 1px divider).
FRIENDS_PAD_L :: 24;
FRIENDS_PAD_R :: 16;
FRIEND_ROW_H :: 61;
ACTIVE_NOW_W :: 360; // including its 1px left border

// Opens (or creates) the DM with a friend, like clicking their row.
friend_open_dm :: (uid: dc.Snowflake) {
	open_dm_with(uid, "Friends");
}

friend_row :: (uid: dc.Snowflake, kind: dc.Relationship_Type) {
	s := store();
	div := row("div");
	div.semantic_size = .[ui.pct(1), ui.px(1)];
	{ ui.parent(div); defer ui.pop_parent();
		spacer(.X, 30);
		l := ui.box("l", .Draw_Background);
		l.semantic_size = .[ui.fill(), ui.px(1)];
		l.style.bg = T("--border-subtle");
		spacer(.X, 36);
	}
	outer := row("f");
	outer.semantic_size = .[ui.pct(1), ui.px(FRIEND_ROW_H)];
	{ ui.parent(outer); defer ui.pop_parent();
		spacer(.X, 14);
		item := row("item", .Clickable | .Draw_Background | .Hot_Animation);
		item.semantic_size = .[ui.fill(), ui.px(FRIEND_ROW_H)];
		item.style.radius = all4(8);
		item.style.bg_hot = T("--background-mod-subtle");
		sig := ui.signal(item);
		if sig.clicked { friend_open_dm(uid); }
		if sig.right_clicked { open_user_menu(uid, app.ui.mouse); }
		u := dc.user_get(s, uid);
		{ ui.parent(item); defer ui.pop_parent();
			spacer(.X, 10);
			avatar_with_status("av", uid, 32, ifx sig.hovering then T("--background-base-low") else T("--background-base-lower"));
			spacer(.X, 12);
			col := ui.box("col");
			col.semantic_size = .[ui.fill(), ui.children()];
			{ ui.parent(col); defer ui.pop_parent();
				nr := row("nr");
				nr.semantic_size = .[ui.pct(1), ui.px(20)];
				{ ui.parent(nr); defer ui.pop_parent();
					label(dc.user_name(s, uid, 0, "Unknown"), .Semibold, 16, T("--text-strong"), 20);
					if sig.hovering && u != null {
						spacer(.X, 4);
						label(u.username, .Medium, 14, T("--text-muted"), 18);
					}
				}
				sub := user_custom_status(uid);
				if sub == "" sub = status_text(user_status(uid));
				if kind == {
				case .Incoming_Request;
					sub = "Incoming Friend Request";
				case .Outgoing_Request;
					sub = "Outgoing Friend Request";
				}
				label(sub, .Medium, 14, T("--text-muted"), 18);
			}
			if kind == .Incoming_Request {
				if round_icon_button("accept", "checkmark-large", T("--status-positive"), rel_req("Accept", uid)).clicked && req_begin(rel_req("Accept", uid)) { dc.accept_friend_request(app.client, uid); req_end(); }
				spacer(.X, 10);
			}
			if kind == .Friend {
				// were drawn but did nothing: Message opens the DM, More the user menu
				if round_icon_button("msg", "chat", T("--interactive-icon-hover")).clicked { friend_open_dm(uid); }
				spacer(.X, 10);
				more := round_icon_button("more", "more-vertical", T("--interactive-icon-hover"));
				if more.clicked { open_user_menu(uid, .{more.box.rect.x0, more.box.rect.y1 + 4}); }
			} else {
				if round_icon_button("deny", "x-small", T("--status-danger")).clicked rel_change(uid, .Remove);
			}
			spacer(.X, 10);
		}
		spacer(.X, 26);
	}
}

// Right column on the friends page: "Active Now" with the empty-state card.
active_now_column :: () {
	edge := ui.box("activenow_edge", .Draw_Background);
	edge.semantic_size = .[ui.px(1), ui.pct(1)];
	edge.style.bg = T("--border-subtle");
	col := ui.box("activenow");
	col.semantic_size = .[ui.px(ACTIVE_NOW_W - 1), ui.pct(1)];
	col.layout_axis = .Y;
	{ ui.parent(col); defer ui.pop_parent();
		spacer(.Y, 14);
		h := row("h");
		h.semantic_size = .[ui.pct(1), ui.px(24)];
		{ ui.parent(h); defer ui.pop_parent();
			spacer(.X, 16);
			label("Active Now", .Semibold, 20, T("--text-strong"), 24);
		}
		spacer(.Y, 9);
		cr := row("cardrow");
		cr.semantic_size = .[ui.pct(1), ui.children()];
		cr.cross_align = .Start;
		{ ui.parent(cr); defer ui.pop_parent();
			spacer(.X, 16);
			card := ui.box("card", .Draw_Background);
			card.semantic_size = .[ui.fill(), ui.children()];
			card.layout_axis = .Y;
			card.style.bg = T("--background-base-low");
			card.style.radius = all4(8);
			{ ui.parent(card); defer ui.pop_parent();
				spacer(.Y, 16);
				t := ui.box("It's quiet for now...##t", .Draw_Text);
				t.semantic_size = .[ui.pct(1), ui.text_size()];
				t.style.font = F(.Semibold);
				t.style.font_size = 16;
				t.style.line_height = 20;
				t.style.text_color = T("--text-strong");
				t.style.text_align = .Center;
				spacer(.Y, 2);
				b := ui.box("When a friend starts an activity—like playing a game or hanging out on voice—we'll show it here!##b", .Draw_Text | .Wrap_Text);
				b.semantic_size = .[ui.pct(1), ui.text_size()];
				b.style.font = F(.Normal);
				b.style.font_size = 14;
				b.style.line_height = 18;
				b.style.padding = .{16, 0};
				b.style.text_color = T("--text-muted");
				b.style.text_align = .Center;
				spacer(.Y, 16);
			}
			spacer(.X, 16);
		}
	}
}

// req: the request this button makes (pulsing dots replace the icon while it runs).
round_icon_button :: (id: string, icon_name: string, hover_color: ui.Color, req := "") -> ui.Signal {
	b := ui.box(id, .Clickable | .Draw_Background | .Hot_Animation);
	b.semantic_size = .[ui.px(36), ui.px(36)];
	b.style.radius = all4(18);
	b.style.bg_hot = T("--background-mod-subtle");
	b.layout_axis = .X;
	b.cross_align = .Center;
	sig := ui.signal(b);
	if req != "" && req_state(req) == .Pending {
		req_button(b, req, T("--interactive-icon-default"));
		sig.clicked = false;
		return sig;
	}
	{ ui.parent(b); defer ui.pop_parent();
		spacer(.X, 8);
		icon("i", icon_name, 20, ifx sig.hovering then hover_color else T("--interactive-icon-default"));
	}
	return sig;
}

// The request key of a relationship button (one per action and user).
rel_req :: (action: string, uid: dc.Snowflake) -> string { return tprint("rel:%:%", action, uid); }

// Remove Friend, Unblock, Ignore or cancel a request (.Remove: DELETE /users/@me/relationships/{id}),
// and Block (PUT with type 2): shown at once, sent after the undo window (undo.jai) instead of the
// client's Block confirm.
Rel_Change :: enum u8 { Remove; Block; }
rel_change :: (uid: dc.Snowflake, op: Rel_Change, location := "Friends") {
	s := store();
	rel := table_find_pointer(*s.relationships, uid);
	old := ifx rel then rel.kind else .None;
	text := "Friend removed";
	if op == .Block text = "User blocked";
	else if old == .Blocked text = "User unblocked";
	else if old == .Incoming_Request text = "Friend request ignored";
	else if old == .Outgoing_Request text = "Friend request cancelled";
	if undo_held(rel_send, uid) return;
	undo_push(text, rel_send, (u: *Undo) {
		s := ifx u.client then *u.client.store else store();
		rel := table_find_pointer(*s.relationships, u.a);
		if !rel return;
		if u.c == xx dc.Relationship_Type.None table_remove(*s.relationships, u.a);
		else rel.kind = xx u.c;
	}, a = uid, c = xx old, s = location, n = xx op);
	if rel rel.kind = ifx op == .Block then .Blocked else .None;
	else if op == .Block table_set(*s.relationships, uid, .{user_id = uid, kind = .Blocked});
}

#scope_file
rel_send :: (u: *Undo) {
	if !u.client return;
	if u.n == xx Rel_Change.Block dc.block_user(u.client, u.a, u.s);
	else dc.remove_relationship(u.client, u.a, u.s);
}
#scope_export

ADD_FRIEND_REQ :: "add_friend";
add_friend_sent: string; // the name of the last request sent from the Add Friend page

add_friend_view :: () {
	sent := req_state(ADD_FRIEND_REQ);
	col := ui.box("addfriend");
	col.semantic_size = .[ui.fill(), ui.pct(1)];
	col.layout_axis = .Y;
	{ ui.parent(col); defer ui.pop_parent();
		spacer(.Y, 20);
		r := row("title");
		r.semantic_size = .[ui.pct(1), ui.px(24)];
		{ ui.parent(r); defer ui.pop_parent();
			spacer(.X, 30);
			label("Add Friend", .Semibold, 20, T("--text-strong"), 24);
		}
		spacer(.Y, 8);
		r2 := row("sub");
		r2.semantic_size = .[ui.pct(1), ui.px(20)];
		{ ui.parent(r2); defer ui.pop_parent();
			spacer(.X, 30);
			label("You can add friends with their Discord username.", .Normal, 16, T("--text-default"), 20);
		}
		spacer(.Y, 16);
		r3 := row("inputrow");
		r3.semantic_size = .[ui.pct(1), ui.px(52)];
		{ ui.parent(r3); defer ui.pop_parent();
			spacer(.X, 30);
			box := row("input", .Draw_Background | .Draw_Border | .Clickable);
			box.semantic_size = .[ui.fill(), ui.px(52)];
			box.style.bg = T("--input-background-default");
			box.style.border_color = ifx app.ui.focus == box.key then T("--input-border-active") else T("--input-border-default");
			if sent == .Done box.style.border_color = T("--status-positive");
			if sent == .Failed box.style.border_color = T("--status-danger");
			box.style.border = 1;
			box.style.radius = all4(8);
			box.hover_cursor = .IBeam;
			if ui.signal(box).pressed { app.ui.focus = box.key; }
			{ ui.parent(box); defer ui.pop_parent();
				spacer(.X, 16);
				res := text_field("field", *app.view.add_friend, "You can add friends with their Discord username.", app.ui.focus == box.key && !modal_open());
				name := trim(ui.editor_text(*app.view.add_friend));
				if res == .Changed && sent != .Pending req_clear(ADD_FRIEND_REQ); // editing drops the last result
				spacer(.X, 12);
				btn := ui.box("Send Friend Request##send", .Clickable | .Draw_Background | .Draw_Text | .Hot_Animation);
				btn.semantic_size = .[ui.text_size(16), ui.px(32)];
				btn.style.radius = all4(8);
				btn.style.font = F(.Medium);
				btn.style.font_size = 14;
				btn.style.text_align = .Center;
				enabled := name != "";
				btn.style.bg = ifx enabled then T("--background-brand") else with_alpha(T("--background-brand"), 0.5);
				btn.style.bg_hot = btn.style.bg;
				btn.style.text_color = ifx enabled then ui.Color.{1, 1, 1, 1} else .{1, 1, 1, 0.5};
				if !enabled { btn.flags |= .Disabled; }
				if (req_button(btn, ADD_FRIEND_REQ) || res == .Submit) && enabled && sent != .Pending {
					free(add_friend_sent);
					add_friend_sent = copy_string(name);
					if req_begin(ADD_FRIEND_REQ, inline_error = true) {
						dc.send_friend_request(app.client, name);
						req_end();
					}
				}
				spacer(.X, 12);
			}
			spacer(.X, 30);
		}
		// the result under the field, as the client shows it (green / red, the field keeps the name)
		if sent == .Done || sent == .Failed {
			spacer(.Y, 8);
			r4 := row("result");
			r4.semantic_size = .[ui.pct(1), ui.px(18)];
			{ ui.parent(r4); defer ui.pop_parent();
				spacer(.X, 30);
				if sent == .Failed {
					code, captcha := req_error(ADD_FRIEND_REQ);
					label(ifx captcha then CAPTCHA_TEXT else ifx code == 50096 then "You cannot friend yourself" else "Hm, didn’t work. Double check that the username is correct.", .Normal, 14, T("--text-feedback-critical"), 18);
				} else {
					t := ui.box("ok");
					t.semantic_size = .[ui.text_size(0, 0), ui.px(18)];
					t.style.line_height = 18;
					t.style.text_color = T("--text-feedback-positive");
					spans := NewArray(3, ui.Span,, temp);
					spans[0] = .{text = "Success! Your friend request to ", font = F(.Normal), size = 14};
					spans[1] = .{text = add_friend_sent, font = F(.Bold), size = 14};
					spans[2] = .{text = " was sent.", font = F(.Normal), size = 14};
					ui.set_spans(t, spans);
				}
			}
		}
	}
}

// Right-hand member column (guild and group DM): the official .container has a 1px --border-subtle
// left border before the --custom-member-list-width list. Its left edge drags to resize it.
// Returns the scrolling list (signalled); declare the rows inside it.
members_column :: (id: string) -> *ui.Box {
	col := row(id);
	col.semantic_size = .[ui.px(app.view.member_w + 1), ui.pct(1)];
	{ ui.parent(col); defer ui.pop_parent();
		line := ui.box("border", .Draw_Background);
		line.semantic_size = .[ui.px(1), ui.pct(1)];
		line.style.bg = T("--border-subtle");
		list := ui.box("list", .Scroll_Y | .Clip | .Draw_Background);
		list.semantic_size = .[ui.fill(), ui.pct(1)];
		list.layout_axis = .Y;
		list.style.bg = T("--background-base-lower");
		ui.signal(list);
		resize_handle("resize", 0, *app.view.member_w, MEMBER_LIST_MIN_W, MEMBER_LIST_MAX_W, grows_left = true);
		return list;
	}
}

MEMBER_ROW_PITCH :: 44;

member_list :: (ch: *dc.Channel) {
	s := store();
	list := members_column("members");
	// the channel's own list (a private channel has its own; serve keeps one), following the scroll
	ml := dc.member_list_get(s, ch.guild_id, ifx on_hosted() then "everyone" else dc.member_list_id(s, ch));
	if app.client != null {
		dc.subscribe_member_list(app.client, ch.guild_id, ch.id, dc.member_list_ranges(list.view_off_target.y, list.rect.y1 - list.rect.y0, MEMBER_ROW_PITCH));
	}
	{ ui.parent(list); defer ui.pop_parent();
		spacer(.Y, 8);
		skel_row :: (i: int) {
			r := row("skel");
			r.semantic_size = .[ui.pct(1), ui.px(MEMBER_ROW_PITCH)];
			ui.parent(r); defer ui.pop_parent();
			spacer(.X, 16);
			skel("av", 32, 32, true);
			spacer(.X, 12);
			skel("name", cast(float32) (60 + (i * 37) % 70), 12);
		}
		if app.client != null && (!ml || ml.items.count == 0) {
			// the first GUILD_MEMBER_LIST_UPDATE is on its way: placeholder rows
			for i: 0..11 { ui.id_scope(cast(u64) i); defer ui.pop_seed(); skel_row(i); }
		}
		// groups and members are one pitch apart (a header is 40 + 4), so only the visible rows are declared
		w := ui.list_window(list, MEMBER_ROW_PITCH, ifx ml then ml.items.count else 0);
		if ml for item, j: array_view(ml.items, w.first, w.last - w.first) {
			i := w.first + j;
			{ ui.id_scope(cast(u64)(i)); defer ui.pop_seed();
				if !item.is_group && !item.user_id {
					skel_row(i); // a range not synced yet (or invalidated)
				} else if item.is_group {
					gr := row("group");
					gr.semantic_size = .[ui.pct(1), ui.px(40)];
					gr.cross_align = .End;
					{ ui.parent(gr); defer ui.pop_parent();
						spacer(.X, 16);
						name := item.group_id;
						if item.group_id == {
						case "online";
							name = "Online";
						case "offline";
							name = "Offline";
						case;
							g := dc.guild_get(s, ch.guild_id);
							if g != null {
								for r: g.roles { if tprint("%", cast(u64) r.id) == item.group_id { name = r.name; } }
							}
						}
						label(tprint("% — %", name, item.count), .Medium, 12, T("--channels-default"), 16);
					}
					spacer(.Y, 4);
				} else {
					g := dc.guild_get(store(), ch.guild_id);
					member_row(ch.guild_id, item.user_id, g && g.owner_id == item.user_id);
				}
			}
		}
		ui.list_window_end(w);
		spacer(.Y, 16);
	}
}

// owner: the server's (or group DM's) owner, crowned after the name; bots get the APP tag.
member_row :: (gid: dc.Snowflake, uid: dc.Snowflake, owner := false) {
	s := store();
	outer := row("m");
	outer.semantic_size = .[ui.pct(1), ui.px(MEMBER_ROW_PITCH)];
	{ ui.parent(outer); defer ui.pop_parent();
		spacer(.X, 8);
		item := row("item", .Clickable | .Draw_Background | .Hot_Animation);
		item.semantic_size = .[ui.fill(), ui.px(42)];
		item.style.radius = all4(8);
		item.style.bg_hot = T("--background-mod-subtle");
		sig := ui.signal(item);
		if sig.clicked { open_profile(uid, item.rect); }
		if sig.right_clicked { open_user_menu(uid, app.ui.mouse); }
		offline := user_status(uid) == .Offline;
		{ ui.parent(item); defer ui.pop_parent();
			spacer(.X, 8);
			// offline members: a dimmed avatar with no status dot, as the official client draws them
			av := ifx offline then avatar_box("av", uid, 32) else avatar_with_status("av", uid, 32, ifx sig.hovering then T("--background-base-low") else T("--background-base-lower"));
			if offline { av.opacity = 0.3; }
			spacer(.X, 12);
			name := dc.user_name(s, uid, gid, "unknown");
			color, ok := member_color(gid, uid);
			if !ok { color = T("--interactive-text-default"); }
			if offline { color = with_alpha(color, 0.3); }
			custom := user_custom_status(uid);
			u := dc.user_get(s, uid);
			bot := u && u.bot;
			col := ui.box("col");
			col.semantic_size = .[ui.fill(), ui.children()];
			col.layout_axis = .Y;
			ui.parent(col); defer ui.pop_parent();
			w := item.rect.x1 - item.rect.x0 - 60 - (ifx owner then 18 else 0) - (ifx bot then 34 else 0) - (ifx u && u.tag then 56 else 0);
			nr := row("nr");
			nr.semantic_size = .[ui.pct(1), ui.px(20)];
			{ ui.parent(nr); defer ui.pop_parent();
				label(ellipsize(name, .Medium, 16, w), .Medium, 16, color, 20);
				if owner {
					spacer(.X, 4);
					icon("crown", "crown", 14, T("--text-feedback-warning"));
				}
				server_tag(u);
				if bot app_tag();
			}
			if custom label(ellipsize(custom, .Medium, 12, w), .Medium, 12, T("--text-muted"), 16);
		}
		spacer(.X, 8);
	}
}

// Banner color for a profile without a banner image: the user's accent color,
// else the avatar's dominant color (as the client does), else brand.
profile_banner_color :: (uid: dc.Snowflake) -> ui.Color {
	u := dc.user_get(store(), uid);
	if u != null && u.has_accent_color { return rgb_u32(u.accent_color); }
	im := image_get(avatar_url_for(uid, 80));
	if im != null && im.state == .Ready && im.dominant.w > 0 { return im.dominant; }
	return T("--background-brand");
}

// 1:1 DM user profile column (official: 306x(h-14) card inset 7px, banner 105,
// 80px avatar in a 6px ring, name/username, Member Since, View Full Profile).
DMP_COL_W :: 320;
MONTH_SHORT := string.["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
DMP_INSET :: 7;
DMP_BANNER_H :: 105;
DMP_PAD :: 19;
DMP_BTN :: 32;

dm_profile_panel :: (uid: dc.Snowflake) {
	s := store();
	u := dc.user_get(s, uid);
	if u == null { return; }
	col := ui.box("dmprofile");
	col.semantic_size = .[ui.px(DMP_COL_W), ui.pct(1)];
	col.layout_axis = .Y;
	{ ui.parent(col); defer ui.pop_parent();
		spacer(.Y, DMP_INSET);
		r := row("r");
		r.semantic_size = .[ui.pct(1), ui.fill()];
		r.cross_align = .Start;
		{ ui.parent(r); defer ui.pop_parent();
			spacer(.X, DMP_INSET);
			card := ui.box("card", .Draw_Background | .Draw_Border | .Clip);
			card.semantic_size = .[ui.fill(), ui.pct(1)];
			card.layout_axis = .Y;
			card.style.bg = T("--chat-background-default");
			card.style.border_color = T("--border-subtle");
			card.style.border = 1;
			card.style.radius = all4(8);
			surface := card.style.bg;
			{ ui.parent(card); defer ui.pop_parent();
				bw := row("bannerrow");
				bw.semantic_size = .[ui.pct(1), ui.px(DMP_BANNER_H + 3)];
				bw.cross_align = .End;
				{ ui.parent(bw); defer ui.pop_parent();
					spacer(.X, 2);
					banner := ui.box("banner", .Draw_Background);
					banner.semantic_size = .[ui.fill(), ui.px(DMP_BANNER_H)];
					banner.style.radius = .[6, 6, 0, 0];
					banner.style.bg = profile_banner_color(uid);
					if u.banner != "" { set_remote_image(banner, dc.banner_url(uid, u.banner, 600)); }
					{ ui.parent(banner); defer ui.pop_parent();
						btns := row("btns", .Floating_X | .Floating_Y);
						btns.semantic_size = .[ui.children(), ui.px(DMP_BTN)];
						btns.fixed_pos = .{DMP_COL_W - 2 * DMP_INSET - 4 - 9 - 2 * DMP_BTN - 8, 8};
						{ ui.parent(btns); defer ui.pop_parent();
							rel := relationship(uid);
							names := string.[ifx rel == .Friend then "user-check" else "user-plus", "more-horizontal"];
							for name, i: names {
								b := ui.box(name, .Clickable | .Draw_Background | .Hot_Animation);
								b.semantic_size = .[ui.px(DMP_BTN), ui.px(DMP_BTN)];
								b.style.radius = all4(DMP_BTN / 2);
								b.style.bg = .{0, 0, 0, 0.36};
								b.style.bg_hot = .{0, 0, 0, 0.5};
								sig := ui.signal(b);
								if i == 0 && req_state(rel_req("Add Friend", uid)) == .Pending {
									req_button(b, rel_req("Add Friend", uid));
								} else { ui.parent(b); defer ui.pop_parent();
									ic := icon("i", name, 18, .{1, 1, 1, 1});
									ic.flags |= .Floating_X | .Floating_Y;
									ic.fixed_pos = .{7, 7};
								}
								if sig.clicked && i == 0 && rel == .None && req_state(rel_req("Add Friend", uid)) != .Pending && req_begin(rel_req("Add Friend", uid)) { dc.add_relationship(app.client, uid, "User Profile"); req_end(); }
								// "…" and the friends check open the user menu (Remove Friend, Block, …)
								if sig.clicked && (i == 1 || rel == .Friend) { open_user_menu(uid, .{b.rect.x0, b.rect.y1 + 4}); }
								if i == 0 { spacer(.X, 8); }
							}
						}
					}
					spacer(.X, 2);
				}
				av := ui.box("avrow");
				av.semantic_size = .[ui.pct(1), ui.px(48)];
				{ ui.parent(av); defer ui.pop_parent();
					ring := ui.box("ring", .Draw_Background | .Floating_X | .Floating_Y);
					ring.semantic_size = .[ui.px(92), ui.px(92)];
					ring.fixed_pos = .{13, -52};
					ring.style.radius = all4(46);
					ring.style.bg = surface;
					{ ui.parent(ring); defer ui.pop_parent();
						a := avatar_with_status("av", uid, 80, surface);
						a.flags |= .Floating_X | .Floating_Y;
						a.fixed_pos = .{6, 6};
					}
				}
				line :: (id: string, text: string, font: Font_Id, size: float32, lh: float32, color: ui.Color) {
					r := row(id);
					r.semantic_size = .[ui.pct(1), ui.px(lh)];
					{ ui.parent(r); defer ui.pop_parent();
						spacer(.X, DMP_PAD);
						l := label(text, font, size, color, lh);
						l.flags |= .Selectable_Text;
					}
				}
				line("name", dc.user_name(s, uid), .Semibold, 20, 24, T("--text-strong"));
				spacer(.Y, 2);
				line("user", u.username, .Normal, 14, 18, T("--text-strong"));
				spacer(.Y, 20);
				line("since_h", "Member Since", .Semibold, 12, 16, T("--text-strong"));
				spacer(.Y, 6);
				created := local_ms(dc.snowflake_time_ms(uid));
				t := to_calendar(APOLLO_TIME_FOR_JAN_1_1970 + milliseconds_to_apollo(created), .UTC);
				line("since", tprint("% %, %", MONTH_SHORT[t.month_starting_at_0], t.day_of_month_starting_at_0 + 1, t.year), .Normal, 14, 18, T("--text-default"));
				encrypted_profile(dc.channel_get(s, app.view.channel), DMP_PAD);
				filler(.Y);
				br := row("viewfull");
				br.semantic_size = .[ui.pct(1), ui.px(40)];
				{ ui.parent(br); defer ui.pop_parent();
					spacer(.X, DMP_PAD);
					b := ui.box("View Full Profile##vfp", .Clickable | .Draw_Background | .Draw_Text | .Hot_Animation);
					b.semantic_size = .[ui.fill(), ui.px(40)];
					b.style.radius = all4(8);
					b.style.bg = T("--background-mod-subtle");
					b.style.bg_hot = T("--background-mod-normal");
					b.style.font = F(.Medium);
					b.style.font_size = 16;
					b.style.text_align = .Center;
					b.style.text_color = T("--text-strong");
					if ui.signal(b).clicked { profile_full_open(uid); }
					spacer(.X, 16);
				}
				spacer(.Y, 18);
			}
			spacer(.X, DMP_INSET);
		}
		spacer(.Y, DMP_INSET);
	}
}

// Top of a DM's history: big avatar, names, "This is the beginning of your
// direct message history with **name**.", mutual servers and friend actions.
DMW_AVATAR :: 80;
DMW_GAP :: 8; // welcome header to the first date divider
DMW_H :: 16 + DMW_AVATAR + 12 + 40 + 8 + 32 + 20 + 20 + 8 + 32; // see dm_welcome

dm_welcome :: (ch: *dc.Channel) -> *ui.Box {
	s := store();
	uid := ch.recipient_ids[0];
	u := dc.user_get(s, uid);
	w := ui.box("dmwelcome");
	w.semantic_size = .[ui.pct(1), ui.px(DMW_H)];
	w.layout_axis = .Y;
	if u == null { return w; }
	{ ui.parent(w); defer ui.pop_parent();
		pad :: (id: string, h: float32) -> *ui.Box {
			r := row(id);
			r.semantic_size = .[ui.pct(1), ui.px(h)];
			return r;
		}
		spacer(.Y, 16);
		{ ui.parent(pad("av", DMW_AVATAR)); defer ui.pop_parent();
			spacer(.X, 16);
			avatar_box("a", uid, DMW_AVATAR);
		}
		spacer(.Y, 12);
		{ ui.parent(pad("name", 40)); defer ui.pop_parent();
			spacer(.X, 16);
			label(dc.user_name(store(), uid), .Bold, 32, T("--text-strong"), 40);
		}
		spacer(.Y, 8);
		{ ui.parent(pad("user", 32)); defer ui.pop_parent();
			spacer(.X, 16);
			label(u.username, .Medium, 24, T("--text-strong"), 32);
		}
		spacer(.Y, 20);
		{ ui.parent(pad("begin", 20)); defer ui.pop_parent();
			spacer(.X, 16);
			t := ui.box("t");
			t.semantic_size = .[ui.text_size(0, 0), ui.px(20)];
			t.style.line_height = 20;
			t.style.text_color = T("--text-default");
			spans := NewArray(3, ui.Span,, temp);
			spans[0] = .{text = "This is the beginning of your direct message history with ", font = F(.Normal), size = 16};
			spans[1] = .{text = dc.user_name(store(), uid), font = F(.Bold), size = 16};
			spans[2] = .{text = ".", font = F(.Normal), size = 16};
			ui.set_spans(t, spans);
		}
		spacer(.Y, 8);
		{ ui.parent(pad("actions", 32)); defer ui.pop_parent();
			spacer(.X, 16);
			mutual := "No servers in common";
			if u.mutual_guilds > 0 { mutual = tprint("% Mutual Server%", u.mutual_guilds, ifx u.mutual_guilds == 1 then "" else "s"); }
			label(mutual, .Normal, 14, T("--text-default"), 18);
			spacer(.X, 12);
			dot := ui.box("dot", .Draw_Background);
			dot.semantic_size = .[ui.px(4), ui.px(4)];
			dot.style.radius = all4(2);
			dot.style.bg = T("--interactive-muted");
			spacer(.X, 12);
			rel := relationship(uid);
			btn :: (text: string, primary: bool, uid: dc.Snowflake = 0) -> bool {
				b := ui.box(text, .Clickable | .Draw_Background | .Draw_Text | .Hot_Animation);
				b.semantic_size = .[ui.text_size(12), ui.px(32)];
				b.style.radius = all4(8);
				b.style.font = F(.Medium);
				b.style.font_size = 14;
				b.style.text_align = .Center;
				b.style.text_color = ifx primary then ui.Color.{1, 1, 1, 1} else T("--text-strong");
				b.style.bg = ifx primary then T("--background-brand") else T("--background-mod-normal");
				b.style.bg_hot = ifx primary then with_alpha(T("--background-brand"), 0.85) else T("--background-mod-strong");
				clicked := ifx uid then req_button(b, rel_req(text, uid), b.style.text_color) else ui.signal(b).clicked;
				spacer(.X, 8);
				return clicked;
			}
			if rel == {
			case .Friend;
				if btn("Remove Friend", false) rel_change(uid, .Remove, "DM Header");
				if btn("Block", false) rel_change(uid, .Block, "DM Header");
			case .Blocked;
				if btn("Unblock", false) rel_change(uid, .Remove, "DM Header");
			case .Outgoing_Request;
				btn("Friend Request Sent", false);
				if btn("Block", false) rel_change(uid, .Block, "DM Header");
			case .Incoming_Request;
				if btn("Accept", true, uid) && req_begin(rel_req("Accept", uid)) { dc.accept_friend_request(app.client, uid); req_end(); }
				if btn("Ignore", false) rel_change(uid, .Remove);
				if btn("Block", false) rel_change(uid, .Block, "DM Header");
			case .None; #through; case .Implicit;
				if btn("Add Friend", true, uid) && req_begin(rel_req("Add Friend", uid)) { dc.add_relationship(app.client, uid, "DM Header"); req_end(); }
				if btn("Block", false) rel_change(uid, .Block, "DM Header");
			}
		}
	}
	return w;
}

// Icon-less group DMs get one of 8 default icons by snowflake timestamp
// ((id >> 22) % 8). Colors measured from the client; unmeasured slots fall back to brand.
group_icon_color :: (cid: dc.Snowflake) -> ui.Color {
	if ((cast(u64)(cid)) >> 22) % 8 == {
	case 0;
		return .{0xd3 / 255.0, 0x78 / 255.0, 0x37 / 255.0, 1};
	case 5;
		return .{0x88 / 255.0, 0x52 / 255.0, 0xa8 / 255.0, 1};
	case 7;
		return .{0xd3 / 255.0, 0x4f / 255.0, 0x3f / 255.0, 1};
	}
	return T("--background-brand");
}

// A group DM's round icon: its custom icon, else the default colored one.
group_dm_icon :: (id: string, ch: *dc.Channel, size: float32) -> *ui.Box {
	g := ui.box(id, .Draw_Background);
	g.semantic_size = .[ui.px(size), ui.px(size)];
	g.style.radius = all4(size / 2);
	g.style.bg = group_icon_color(ch.id);
	if ch.icon != "" {
		set_remote_image(g, tprint("https://cdn.discordapp.com/channel-icons/%/%.webp?size=%", cast(u64) ch.id, ch.icon, cast(int)(size * 2)));
	} else { ui.parent(g); defer ui.pop_parent();
		inner := ui.box("i", .Floating_X | .Floating_Y);
		inner.semantic_size = .[ui.px(size * 0.625), ui.px(size * 0.625)];
		inner.fixed_pos = .{size * 0.1875, size * 0.1875};
		set_icon(inner, "group", .{1, 1, 1, 1});
	}
	return g;
}

// Top of a guild text channel's history: a 68px circle with the channel icon,
// "Welcome to #name!" and "This is the start of the #name channel." (+ the
// topic), and "Edit Channel" for members who can manage channels.
CHW_ICON :: 68;
PERM_MANAGE_CHANNELS :: (cast(u64)(1)) << 4;

// The start of a group DM's history: its icon, name and "Welcome to the beginning of the <name> group."
GDW_H :: 16 + 80 + 8 + 40 + 8 + 20;

group_dm_welcome :: (ch: *dc.Channel) {
	w := ui.box("gdwelcome");
	w.semantic_size = .[ui.pct(1), ui.px(GDW_H)];
	w.layout_axis = .Y;
	ui.parent(w); defer ui.pop_parent();
	spacer(.Y, 16);
	r := row("icon");
	r.semantic_size = .[ui.pct(1), ui.px(80)];
	{ ui.parent(r); defer ui.pop_parent(); spacer(.X, 16); group_dm_icon("gi", ch, 80); }
	spacer(.Y, 8);
	name := dm_name(ch);
	h := row("h");
	h.semantic_size = .[ui.pct(1), ui.px(40)];
	{ ui.parent(h); defer ui.pop_parent(); spacer(.X, 16); label(name, .Bold, 32, T("--text-strong"), 40); }
	spacer(.Y, 8);
	t := row("t");
	t.semantic_size = .[ui.pct(1), ui.px(20)];
	{ ui.parent(t); defer ui.pop_parent();
		spacer(.X, 16);
		b := ui.box("text", .Wrap_Text);
		b.semantic_size = .[ui.fill(), ui.text_size()];
		b.style.line_height = 20;
		ui.set_spans(b, ui.Span.[
			.{text = "Welcome to the beginning of the ", font = F(.Normal), size = 16, color = T("--text-muted")},
			.{text = name, font = F(.Semibold), size = 16, color = T("--text-muted")},
			.{text = " group.", font = F(.Normal), size = 16, color = T("--text-muted")},
		]);
	}
}

channel_welcome_height :: (ch: *dc.Channel) -> float32 {
	h: float32 = 16 + CHW_ICON + 8 + 40 + 8 + 20;
	if (my_guild_permissions(ch.guild_id) & PERM_MANAGE_CHANNELS) != 0 { h += 8 + 20; }
	return h;
}

channel_welcome :: (ch: *dc.Channel) {
	w := ui.box("chwelcome");
	w.semantic_size = .[ui.pct(1), ui.px(channel_welcome_height(ch))];
	w.layout_axis = .Y;
	{ ui.parent(w); defer ui.pop_parent();
		spacer(.Y, 16);
		r := row("icon");
		r.semantic_size = .[ui.pct(1), ui.px(CHW_ICON)];
		{ ui.parent(r); defer ui.pop_parent();
			spacer(.X, 16);
			c := ui.box("circle", .Draw_Background);
			c.semantic_size = .[ui.px(CHW_ICON), ui.px(CHW_ICON)];
			c.style.radius = all4(CHW_ICON / 2);
			c.style.bg = T("--background-mod-normal");
			{ ui.parent(c); defer ui.pop_parent();
				ic := icon("i", channel_icon_name(ch), 42, T("--text-strong"));
				ic.flags |= .Floating_X | .Floating_Y;
				ic.fixed_pos = .{(CHW_ICON - 42) / 2, (CHW_ICON - 42) / 2};
			}
		}
		spacer(.Y, 8);
		h := row("h");
		h.semantic_size = .[ui.pct(1), ui.px(40)];
		{ ui.parent(h); defer ui.pop_parent();
			spacer(.X, 16);
			label(tprint("Welcome to #%!", ch.name), .Bold, 32, T("--text-strong"), 40);
		}
		spacer(.Y, 8);
		t := row("t");
		t.semantic_size = .[ui.pct(1), ui.px(20)];
		{ ui.parent(t); defer ui.pop_parent();
			spacer(.X, 16);
			label(tprint("This is the start of the #% channel.", ch.name), .Normal, 16, T("--text-muted"), 20);
		}
		if (my_guild_permissions(ch.guild_id) & PERM_MANAGE_CHANNELS) != 0 {
			spacer(.Y, 8);
			e := row("edit");
			e.semantic_size = .[ui.pct(1), ui.px(20)];
			{ ui.parent(e); defer ui.pop_parent();
				spacer(.X, 16);
				b := row("editbtn", .Clickable);
				b.semantic_size = .[ui.children(), ui.px(20)];
				if ui.signal(b).clicked { channel_settings_open(ch); }
				{ ui.parent(b); defer ui.pop_parent();
					icon("i", "pencil", 16, T("--text-link"));
					spacer(.X, 4);
					label("Edit Channel", .Medium, 14, T("--text-link"), 18);
				}
			}
		}
	}
}

#scope_file

friends_tab_telemetry :: (event: string) {
	if app.client == null { return; }
	tabs := dc.Friends_List_Tab.[.Online, .All, .Pending, .Add_Friend];
	dc.analytics_friends_list(app.client, event, tabs[app.view.friends_tab]);
}

relationship :: (uid: dc.Snowflake) -> dc.Relationship_Type {
	r := table_find_pointer(*store().relationships, uid);
	return ifx r then r.kind else .None;
}
