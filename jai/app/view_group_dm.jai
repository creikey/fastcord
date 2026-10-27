// "Select Friends" popout (DM list "+", and "Add Friends to DM" in a 1:1 DM
// header) and the group DM member list.
// Strings from the client: "Select Friends", "You can add N more friends.",
// "Type the username of a friend", "Create DM" / "Create Group DM",
// "You don't have any friends to add!". A group DM holds 10 people (you + 9).

GDM_W :: 440;
GDM_PAD :: 16;
GDM_ROW_H :: 40;
GDM_LIST_MAX_H :: 248;
GDM_CHECK :: 22;
GDM_MAX_OTHERS :: 9;
GDM_BUTTON_H :: 38;
#scope_file

Gdm_State :: struct {
	open: bool;
	anchor: ui.Rect;
	from_dm: dc.Snowflake; // opened from a 1:1 DM: its recipient is preselected and fixed
	selected: [..]dc.Snowflake;
	search: ui.Editor;
	scroll: Pk_Scroll;
	t: float32;
	rect: ui.Rect;
}

gdm: Gdm_State;
#scope_export

// The "+" next to "Direct Messages" (replaces the plain icon in home_sidebar).
dm_create_button :: () {
	b := ui.box("dmplus", .{.Clickable});
	b.semantic_size = .[ui.px(18), ui.px(18)];
	sig := ui.signal(b);
	set_icon(b, "plus-small", ifx sig.hovering || gdm.open then cast(T)("--interactive-icon-hover") else cast(T)("--interactive-icon-default"));
	if sig.hovering && !gdm.open { tooltip_below("Create DM", b.rect); }
	if sig.clicked {
		if gdm.open { gdm.open = false; } else { group_dm_popout_open(b.rect, 0); }
	}
}

group_dm_popout_open :: (anchor: ui.Rect, from_dm: dc.Snowflake) {
	gdm.open = true;
	gdm.anchor = anchor;
	gdm.from_dm = from_dm;
	gdm.t = 0;
	gdm.scroll = .{};
	clear(*gdm.selected);
	ui.editor_set_text(*gdm.search, "");
}

// Small tooltip under a rect (overlay, window coordinates).
tooltip_below :: (text: string, r: ui.Rect) {
	tip := row("tipb###tooltip_below", .{.Draw_Background, .Draw_Shadow, .Floating_X, .Floating_Y, .Overlay});
	tip.semantic_size = .[ui.children(), ui.px(32)];
	p := ui.top_parent();
	tip.fixed_pos = .{r.x0 - 40 - p.rect.x0, r.y1 + 8 - p.rect.y0};
	tip.style.bg = cast(T)("--background-surface-highest");
	tip.style.radius = 8;
	tip.style.shadow_color = .{0, 0, 0, 0.3};
	tip.style.shadow_blur = 8;
	if ui.parent(tip) {
		spacer(.X, 12);
		label(text, .Semibold, 14, cast(T)("--text-strong"), 18);
		spacer(.X, 12);
	}
}
#scope_file

friends_sorted :: () -> []dc.Snowflake {
	s := store();
	out := make_dynamic(dc.Snowflake, 0, 0, temp);
	for uid, rel: s.relationships { if rel.kind == .Friend { append(*out, uid); } }
	sort_users_by_name(view(out));
	return view(out);
}
#scope_export

// Overlay entry (views.odin overlays()).
group_dm_overlay :: () {
	if !gdm.open { return; }
	focus_before := app.ui.focus; // a field pressed this frame (the popout's field takes focus below)
	s := store();
	ui.animate(*gdm.t, 1, 30);
	r := ui.Rect.{gdm.anchor.x0 - 20, gdm.anchor.y1 + 8, gdm.anchor.x0 - 20 + GDM_W, 0};
	if gdm.from_dm != 0 { r.x0, r.x1 = gdm.anchor.x1 - GDM_W, gdm.anchor.x1; }
	r.x0 = clamp(r.x0, 8, app.ui.window.x - GDM_W - 8);
	r.x1 = r.x0 + GDM_W;
	pop := ui.box("gdm###gdm_popout", .{.Draw_Background, .Draw_Border, .Draw_Shadow, .Floating_X, .Floating_Y, .Overlay, .Clickable});
	pop.semantic_size = .[ui.px(GDM_W), ui.children()];
	pop.fixed_pos = .{r.x0, r.y0 + (1 - gdm.t) * 8};
	pop.layout_axis = .Y;
	pop.style.bg = cast(T)("--background-surface-high");
	pop.style.border_color = cast(T)("--border-subtle");
	pop.style.border = 1;
	pop.style.radius = 8;
	pop.style.shadow_color = .{0, 0, 0, 0.32};
	pop.style.shadow_blur = 16;
	pop.style.shadow_offset = .{0, 8};
	ui.signal(pop);
	gdm.rect = pop.rect;
	fixed := cast(dc.Snowflake)(0);
	{ c := dc.channel_get(s, gdm.from_dm);
	if c != null && c.kind == .DM && len(c.recipient_ids) > 0 { fixed = c.recipient_ids[0]; } }
	friends := friends_sorted();
	q := strings.to_lower(strings.trim_space(ui.editor_text(*gdm.search)), temp);
	shown := make_dynamic(dc.Snowflake, 0, 0, temp);
	for uid: friends {
		if uid == fixed { continue; }
		u := dc.user_get(s, uid);
		if u == null { continue; }
		if q != "" && !strings.contains(strings.to_lower(dc.user_name(s, uid), temp), q) && !strings.contains(strings.to_lower(dc.display_name(u), temp), q) && !strings.contains(strings.to_lower(u.username, temp), q) { continue; }
		append(*shown, uid);
	}
	others := len(gdm.selected) + (ifx fixed != 0 then 1 else 0);
	if ui.parent(pop) {
		spacer(.Y, GDM_PAD);
		h := row("title");
		h.semantic_size = .[ui.pct(1), ui.px(24)];
		if ui.parent(h) {
			spacer(.X, GDM_PAD);
			label("Select Friends", .Semibold, 20, cast(T)("--text-strong"), 24);
		}
		spacer(.Y, 4);
		sub := row("sub");
		sub.semantic_size = .[ui.pct(1), ui.px(16)];
		if ui.parent(sub) {
			spacer(.X, GDM_PAD);
			left := GDM_MAX_OTHERS - others;
			msg := ifx left == 1 then "You can add 1 more friend." else fmt.tprintf("You can add %d more friends.", left);
			label(msg, .Normal, 12, ifx left <= 0 then cast(T)("--text-feedback-critical") else cast(T)("--text-muted"), 16);
		}
		spacer(.Y, 16);
		gdm_search_row();
		spacer(.Y, 8);
		list_h := min(GDM_LIST_MAX_H, max(cast(float32)(len(shown)) * (GDM_ROW_H + 2), 56));
		list := ui.box("list", .{.Clip});
		list.semantic_size = .[ui.pct(1), ui.px(list_h)];
		view := list.rect;
		pk_scroll_update(*gdm.scroll, view, cast(float32)(len(shown)) * (GDM_ROW_H + 2));
		if ui.parent(list) {
			if len(friends) == 0 {
				e := ui.box("empty", .{.Floating_X, .Floating_Y});
				e.semantic_size = .[ui.px(GDM_W), ui.px(list_h)];
				e.layout_axis = .Y;
				e.cross_align = .Center;
				if ui.parent(e) {
					spacer(.Y, 18);
					label("You don't have any friends to add!", .Medium, 14, cast(T)("--text-muted"), 18);
				}
			}
			for uid, i: shown {
				y := cast(float32)(i) * (GDM_ROW_H + 2) - gdm.scroll.y;
				if y + GDM_ROW_H < 0 || y > list_h { continue; }
				if ui.id_scope(cast(u64)(uid)) { gdm_friend_row(uid, y, others); }
			}
			pk_scrollbar(*gdm.scroll, GDM_W - PK_SCROLLBAR_W - 4);
		}
		spacer(.Y, 8);
		line := ui.box("line", .{.Draw_Background});
		line.semantic_size = .[ui.pct(1), ui.px(1)];
		line.style.bg = cast(T)("--border-subtle");
		spacer(.Y, 16);
		br := row("btnrow");
		br.semantic_size = .[ui.pct(1), ui.px(GDM_BUTTON_H)];
		if ui.parent(br) {
			spacer(.X, GDM_PAD);
			text := ifx others >= 2 then "Create Group DM" else "Create DM";
			btn := ui.box(fmt.tprintf("%s##create", text), .{.Clickable, .Draw_Background, .Draw_Text, .Hot_Animation});
			btn.semantic_size = .[ui.fill(), ui.px(GDM_BUTTON_H)];
			btn.style.radius = 8;
			btn.style.bg = cast(T)("--background-brand");
			btn.style.bg_hot = with_alpha(cast(T)("--background-brand"), 0.85);
			btn.style.font = F(.Medium);
			btn.style.font_size = 14;
			btn.style.text_color = .{1, 1, 1, 1};
			btn.style.text_align = .Center;
			if ui.signal(btn).clicked { gdm_create(fixed); }
			spacer(.X, GDM_PAD);
		}
		spacer(.Y, GDM_PAD);
	}
	for * e: app.ui.events {
		// a press outside closes the popout even when a control under it took the press
		if e.kind == .Mouse_Down && gdm.rect.x1 > gdm.rect.x0 && !pk_contains(gdm.rect, e.pos) && !pk_contains(gdm.anchor, e.pos) { gdm.open = false; }
		if e.consumed { continue; }
		if e.kind == .Key_Down && e.key == .Escape {
			e.consumed = true;
			gdm.open = false;
		}
	}
	// give up the keyboard only if the popout still has it (a press outside may
	// have just focused another field)
	if !gdm.open {
		own := ui.key_from_string("gdmq###gdm_search", 0);
		app.ui.focus = ifx focus_before == own then 0 else focus_before;
	}
	pk_fade(pop, gdm.t);
}
#scope_file

gdm_search_row :: () {
	r := row("searchrow");
	r.semantic_size = .[ui.pct(1), ui.px(36)];
	if ui.parent(r) {
		spacer(.X, GDM_PAD);
		w := row("search", .{.Draw_Background, .Draw_Border, .Clickable});
		w.semantic_size = .[ui.fill(), ui.px(36)];
		w.style.bg = cast(T)("--input-background-default");
		w.style.border_color = cast(T)("--border-focus");
		w.style.border = 1;
		w.style.radius = 8;
		w.hover_cursor = .IBeam;
		if ui.parent(w) {
			spacer(.X, 8);
			// selected friends as chips, like the client's tag input
			for uid: gdm.selected {
				u := dc.user_get(store(), uid);
				if u == null { continue; }
				if ui.id_scope(cast(u64)(uid)) {
					chip := ui.box(fmt.tprintf("%s##chip", dc.user_name(store(), uid)), .{.Clickable, .Draw_Background, .Draw_Text, .Hot_Animation});
					chip.semantic_size = .[ui.text_size(6), ui.px(24)];
					chip.style.radius = 4;
					chip.style.bg = cast(T)("--background-mod-normal");
					chip.style.bg_hot = cast(T)("--background-mod-strong");
					chip.style.font = F(.Medium);
					chip.style.font_size = 14;
					chip.style.text_color = cast(T)("--text-default");
					if ui.signal(chip).clicked { gdm_toggle(uid); }
					spacer(.X, 4);
				}
			}
			f := ui.box("gdmq###gdm_search", .{.Clickable, .Draw_Text, .Focusable, .Clip});
			f.semantic_size = .[ui.fill(), ui.px(34)];
			f.style.font = F(.Normal);
			f.style.font_size = 16;
			f.style.line_height = 20;
			f.hover_cursor = .IBeam;
			text := ui.editor_text(*gdm.search);
			f.text = text;
			f.style.text_color = cast(T)("--text-default");
			if text == "" {
				f.text = ifx len(gdm.selected) == 0 then "Type the username of a friend" else "";
				f.style.text_color = cast(T)("--input-placeholder-text-default");
			}
			app.ui.focus = f.key;
			tl := f.text_layout;
			if text == "" { tl = null; }
			for * e: app.ui.events {
				if e.consumed || (e.kind != .Key_Down && e.kind != .Text) { continue; }
				if e.kind == .Key_Down && e.key == .Escape { continue; }
				if e.kind == .Key_Down && e.key == .Backspace && text == "" && len(gdm.selected) > 0 {
					pop(*gdm.selected);
					e.consumed = true;
					continue;
				}
				if ui.editor_event(*gdm.search, e, tl, clipboard_get, clipboard_set) != .None { e.consumed = true; }
			}
			note_focused_editor(*gdm.search, f);
			d := new(Search_Draw, temp);
			d.ed = *gdm.search;
			f.custom_draw = search_caret_draw;
			f.custom_user = d;
			spacer(.X, 8);
		}
		spacer(.X, GDM_PAD);
	}
}

gdm_toggle :: (uid: dc.Snowflake) {
	{ i, found := slice.linear_search(view(gdm.selected), uid);
	if found {
		ordered_remove(*gdm.selected, i);
	} else if len(gdm.selected) < GDM_MAX_OTHERS {
		append(*gdm.selected, uid);
	} }
}

gdm_friend_row :: (uid: dc.Snowflake, y: float32, others: int) {
	u := dc.user_get(store(), uid);
	checked := slice.contains(view(gdm.selected), uid);
	disabled := !checked && others >= GDM_MAX_OTHERS;
	r := row("friend", .{.Clickable, .Draw_Background, .Hot_Animation, .Floating_X, .Floating_Y});
	r.semantic_size = .[ui.px(GDM_W - 2 * 8), ui.px(GDM_ROW_H)];
	r.fixed_pos = .{8, y};
	r.style.radius = 4;
	r.style.bg_hot = cast(T)("--background-mod-subtle");
	sig := ui.signal(r);
	if sig.clicked && !disabled { gdm_toggle(uid); }
	if ui.parent(r) {
		spacer(.X, 8);
		avatar_with_status("av", uid, 32, ifx sig.hovering then cast(T)("--background-surface-higher") else cast(T)("--background-surface-high"));
		spacer(.X, 12);
		label(dc.user_name(store(), uid, 0, "unknown"), .Medium, 16, cast(T)("--interactive-text-active"), 20);
		spacer(.X, 6);
		label(ifx u != null then u.username else "", .Normal, 14, cast(T)("--text-muted"), 18);
		filler(.X);
		cb := ui.box("check", .{.Draw_Background, .Draw_Border});
		cb.semantic_size = .[ui.px(GDM_CHECK), ui.px(GDM_CHECK)];
		cb.style.radius = 6;
		cb.style.border = ifx checked then 0 else 1;
		cb.style.border_color = cast(T)("--checkbox-border-default");
		cb.style.bg = ifx checked then cast(T)("--background-brand") else .{};
		if checked {
			if ui.parent(cb) {
				i := ui.box("i", .{.Floating_X, .Floating_Y});
				i.semantic_size = .[ui.px(18), ui.px(18)];
				i.fixed_pos = .{2, 2};
				set_icon(i, "checkmark-small", .{1, 1, 1, 1});
			}
		}
		spacer(.X, 8);
	}
	if disabled { r.opacity = 0.5; }
}

// 0 friends: a group DM with just you (as the client does); 1 friend: open
// (or create) the DM; more: POST /users/@me/channels {recipients}.
gdm_create :: (fixed: dc.Snowflake) {
	ids := make_dynamic(dc.Snowflake, 0, 0, temp);
	if fixed != 0 { append(*ids, fixed); }
	append(*ids, ..view(gdm.selected));
	gdm.open = false;
	app.ui.focus = 0;
	if !net_action() { return; }
	if len(ids) == 1 {
		{ existing := dc.open_dm(app.client, get(ids, 0), "Create DM");
		if existing != 0 {
			select_channel(0, existing);
			return;
		} }
	} else {
		dc.create_private_channel(app.client, view(ids), "Create DM");
	}
	app.pending_dm_user = ifx len(ids) > 0 then get(ids, 0) else store().me;
}
#scope_export

// ---- group DM member list ----

group_dm_members :: (ch: *dc.Channel) {
	s := store();
	list := ui.box("gdm_members", .{.Scroll_Y, .Clip, .Draw_Background});
	list.semantic_size = .[ui.px(MEMBER_LIST_W), ui.pct(1)];
	list.layout_axis = .Y;
	list.style.bg = cast(T)("--background-base-lower");
	ui.signal(list);
	ids := make_dynamic(dc.Snowflake, 0, 0, temp);
	append(*ids, s.me);
	for id: ch.recipient_ids { if id != s.me { append(*ids, id); } }
	if ui.parent(list) {
		spacer(.Y, 8);
		gr := row("group");
		gr.semantic_size = .[ui.pct(1), ui.px(40)];
		gr.cross_align = .End;
		if ui.parent(gr) {
			spacer(.X, 16);
			label(fmt.tprintf("Members — %d", len(ids)), .Medium, 12, cast(T)("--channels-default"), 16);
		}
		spacer(.Y, 4);
		for uid: ids {
			if ui.id_scope(cast(u64)(uid)) {
				member_row(0, uid);
				if uid == ch.owner_id {
					// crown after the name
					item := ui.top_parent().last;
					if ui.parent(item) {
						c := ui.box("crown", .{.Floating_X, .Floating_Y});
						c.semantic_size = .[ui.px(14), ui.px(14)];
						name_w: float32 = 0;
						name_w = cast(float32)(len(dc.user_name(s, uid))) * 8.2;
						c.fixed_pos = .{8 + 8 + 32 + 12 + name_w + 4, 15};
						set_icon(c, "crown", cast(T)("--text-feedback-warning"));
					}
				}
			}
		}
		spacer(.Y, 16);
	}
}

gdm_reset_for_test :: () {gdm = .{};}
gdm_state_for_test :: () -> string {return fmt.tprint(gdm.open, view(gdm.selected));}

