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

// The "+" next to "Direct Messages" (replaces the plain icon in home_sidebar).
dm_create_button :: () {
	b := ui.box("dmplus", .Clickable);
	b.semantic_size = .[ui.px(18), ui.px(18)];
	sig := ui.signal(b);
	set_icon(b, "plus-small", ifx sig.hovering || gdm.open then T("--interactive-icon-hover") else T("--interactive-icon-default"));
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
	array_reset_keeping_memory(*gdm.selected);
	ui.editor_set_text(*gdm.search, "");
}

// Small tooltip under a rect (overlay, window coordinates).
tooltip_below :: (text: string, r: ui.Rect) {
	tip := row("tipb###tooltip_below", .Draw_Background | .Draw_Shadow | .Floating_X | .Floating_Y | .Overlay);
	tip.semantic_size = .[ui.children(), ui.px(32)];
	p := ui.top_parent();
	tip.fixed_pos = .{r.x0 - 40 - p.rect.x0, r.y1 + 8 - p.rect.y0};
	tip.style.bg = T("--background-surface-highest");
	tip.style.radius = all4(8);
	tip.style.shadow_color = .{0, 0, 0, 0.3};
	tip.style.shadow_blur = 8;
	{ ui.parent(tip); defer ui.pop_parent();
		spacer(.X, 12);
		label(text, .Semibold, 14, T("--text-strong"), 18);
		spacer(.X, 12);
	}
}

// Overlay entry (views.jai overlays()).
group_dm_overlay :: () {
	if !gdm.open { return; }
	focus_before := app.ui.focus; // a field pressed this frame (the popout's field takes focus below)
	s := store();
	ui.animate(*gdm.t, 1, 30);
	r := ui.Rect.{gdm.anchor.x0 - 20, gdm.anchor.y1 + 8, gdm.anchor.x0 - 20 + GDM_W, 0};
	if gdm.from_dm != 0 { r.x0, r.x1 = gdm.anchor.x1 - GDM_W, gdm.anchor.x1; }
	r.x0 = clamp(r.x0, 8, app.ui.window.x - GDM_W - 8);
	r.x1 = r.x0 + GDM_W;
	pop := ui.box("gdm###gdm_popout", .Draw_Background | .Draw_Border | .Draw_Shadow | .Floating_X | .Floating_Y | .Overlay | .Clickable);
	pop.semantic_size = .[ui.px(GDM_W), ui.children()];
	pop.fixed_pos = .{r.x0, r.y0 + (1 - gdm.t) * 8};
	pop.layout_axis = .Y;
	pop.style.bg = T("--background-surface-high");
	pop.style.border_color = T("--border-subtle");
	pop.style.border = 1;
	pop.style.radius = all4(8);
	pop.style.shadow_color = .{0, 0, 0, 0.32};
	pop.style.shadow_blur = 16;
	pop.style.shadow_offset = .{0, 8};
	ui.signal(pop);
	gdm.rect = pop.rect;
	fixed: dc.Snowflake;
	c := dc.channel_get(s, gdm.from_dm);
	if c && c.kind == .DM && c.recipient_ids.count > 0 fixed = c.recipient_ids[0];
	friends := friends_sorted();
	q := to_lower_copy(trim(ui.editor_text(*gdm.search)),, temp);
	has_q :: (text: string, q: string) -> bool { return contains(to_lower_copy(text,, temp), q); }
	shown: [..]dc.Snowflake;
	shown.allocator = temp;
	for uid: friends {
		if uid == fixed continue;
		u := dc.user_get(s, uid);
		if u == null continue;
		if q != "" && !has_q(dc.user_name(s, uid), q) && !has_q(dc.display_name(u), q) && !has_q(u.username, q) continue;
		array_add(*shown, uid);
	}
	others := gdm.selected.count + (ifx fixed != 0 then 1 else 0);
	{ ui.parent(pop); defer ui.pop_parent();
		spacer(.Y, GDM_PAD);
		h := row("title");
		h.semantic_size = .[ui.pct(1), ui.px(24)];
		{ ui.parent(h); defer ui.pop_parent();
			spacer(.X, GDM_PAD);
			label("Select Friends", .Semibold, 20, T("--text-strong"), 24);
		}
		spacer(.Y, 4);
		sub := row("sub");
		sub.semantic_size = .[ui.pct(1), ui.px(16)];
		{ ui.parent(sub); defer ui.pop_parent();
			spacer(.X, GDM_PAD);
			left := GDM_MAX_OTHERS - others;
			msg := ifx left == 1 then "You can add 1 more friend." else tprint("You can add % more friends.", left);
			label(msg, .Normal, 12, ifx left <= 0 then T("--text-feedback-critical") else T("--text-muted"), 16);
		}
		spacer(.Y, 16);
		gdm_search_row();
		spacer(.Y, 8);
		list_h := min(cast(float32) GDM_LIST_MAX_H, max(cast(float32) shown.count * (GDM_ROW_H + 2), 56));
		list := ui.box("list", .Clip);
		list.semantic_size = .[ui.pct(1), ui.px(list_h)];
		view := list.rect;
		pk_scroll_update(*gdm.scroll, view, cast(float32) shown.count * (GDM_ROW_H + 2));
		{ ui.parent(list); defer ui.pop_parent();
			if friends.count == 0 {
				e := ui.box("empty", .Floating_X | .Floating_Y);
				e.semantic_size = .[ui.px(GDM_W), ui.px(list_h)];
				e.layout_axis = .Y;
				e.cross_align = .Center;
				{ ui.parent(e); defer ui.pop_parent();
					spacer(.Y, 18);
					label("You don't have any friends to add!", .Medium, 14, T("--text-muted"), 18);
				}
			}
			for uid, i: shown {
				y := cast(float32) i * (GDM_ROW_H + 2) - gdm.scroll.y;
				if y + GDM_ROW_H < 0 || y > list_h continue;
				{ ui.id_scope(cast(u64)(uid)); defer ui.pop_seed(); gdm_friend_row(uid, y, others); }
			}
			pk_scrollbar(*gdm.scroll);
		}
		spacer(.Y, 8);
		line := ui.box("line", .Draw_Background);
		line.semantic_size = .[ui.pct(1), ui.px(1)];
		line.style.bg = T("--border-subtle");
		spacer(.Y, 16);
		br := row("btnrow");
		br.semantic_size = .[ui.pct(1), ui.px(GDM_BUTTON_H)];
		{ ui.parent(br); defer ui.pop_parent();
			spacer(.X, GDM_PAD);
			text := ifx others >= 2 then "Create Group DM" else "Create DM";
			btn := ui.box(tprint("%##create", text), .Clickable | .Draw_Background | .Draw_Text | .Hot_Animation);
			btn.semantic_size = .[ui.fill(), ui.px(GDM_BUTTON_H)];
			btn.style.radius = all4(8);
			btn.style.bg = T("--background-brand");
			btn.style.bg_hot = with_alpha(T("--background-brand"), 0.85);
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

// ---- group DM member list ----

group_dm_members :: (ch: *dc.Channel) {
	s := store();
	list := members_column("gdm_members");
	ids: [..]dc.Snowflake;
	ids.allocator = temp;
	array_add(*ids, s.me);
	for ch.recipient_ids if it != s.me array_add(*ids, it);
	{ ui.parent(list); defer ui.pop_parent();
		spacer(.Y, 8);
		gr := row("group");
		gr.semantic_size = .[ui.pct(1), ui.px(40)];
		gr.cross_align = .End;
		{ ui.parent(gr); defer ui.pop_parent();
			spacer(.X, 16);
			label(tprint("Members — %", ids.count), .Medium, 12, T("--channels-default"), 16);
		}
		spacer(.Y, 4);
		for uid: ids {
			{ ui.id_scope(cast(u64)(uid)); defer ui.pop_seed();
				member_row(0, uid);
				if uid == ch.owner_id {
					// crown after the name
					item := ui.top_parent().last;
					{ ui.parent(item); defer ui.pop_parent();
						c := ui.box("crown", .Floating_X | .Floating_Y);
						c.semantic_size = .[ui.px(14), ui.px(14)];
						name_w := cast(float32) dc.user_name(s, uid).count * 8.2;
						c.fixed_pos = .{8 + 8 + 32 + 12 + name_w + 4, 15};
						set_icon(c, "crown", T("--text-feedback-warning"));
					}
				}
			}
		}
		spacer(.Y, 16);
	}
}

gdm_reset_for_test :: () { gdm = .{}; }
gdm_state_for_test :: () -> string { return tprint("% %", gdm.open, gdm.selected); }

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

friends_sorted :: () -> []dc.Snowflake {
	s := store();
	out: [..]dc.Snowflake;
	out.allocator = temp;
	for rel, uid: s.relationships if rel.kind == .Friend array_add(*out, uid);
	sort_users_by_name(out);
	return out;
}

gdm_search_row :: () {
	r := row("searchrow");
	r.semantic_size = .[ui.pct(1), ui.px(36)];
	{ ui.parent(r); defer ui.pop_parent();
		spacer(.X, GDM_PAD);
		w := row("search", .Draw_Background | .Draw_Border | .Clickable);
		w.semantic_size = .[ui.fill(), ui.px(36)];
		w.style.bg = T("--input-background-default");
		w.style.border_color = T("--border-focus");
		w.style.border = 1;
		w.style.radius = all4(8);
		w.hover_cursor = .IBeam;
		{ ui.parent(w); defer ui.pop_parent();
			spacer(.X, 8);
			// selected friends as chips, like the client's tag input
			for uid: gdm.selected {
				u := dc.user_get(store(), uid);
				if u == null continue;
				{ ui.id_scope(cast(u64)(uid)); defer ui.pop_seed();
					chip := ui.box(tprint("%##chip", dc.user_name(store(), uid)), .Clickable | .Draw_Background | .Draw_Text | .Hot_Animation);
					chip.semantic_size = .[ui.text_size(6), ui.px(24)];
					chip.style.radius = all4(4);
					chip.style.bg = T("--background-mod-normal");
					chip.style.bg_hot = T("--background-mod-strong");
					chip.style.font = F(.Medium);
					chip.style.font_size = 14;
					chip.style.text_color = T("--text-default");
					if ui.signal(chip).clicked { gdm_toggle(uid); }
					spacer(.X, 4);
				}
			}
			f := ui.box("gdmq###gdm_search", .Clickable | .Draw_Text | .Focusable | .Clip);
			f.semantic_size = .[ui.fill(), ui.px(34)];
			f.style.font = F(.Normal);
			f.style.font_size = 16;
			f.style.line_height = 20;
			f.hover_cursor = .IBeam;
			text := ui.editor_text(*gdm.search);
			f.text = text;
			f.style.text_color = T("--text-default");
			if text == "" {
				f.text = ifx gdm.selected.count == 0 then "Type the username of a friend" else "";
				f.style.text_color = T("--input-placeholder-text-default");
			}
			app.ui.focus = f.key;
			tl := f.prev_layout; // this frame's is laid out after the events are handled
			if text == "" { tl = null; }
			for * e: app.ui.events {
				if e.consumed || (e.kind != .Key_Down && e.kind != .Text) { continue; }
				if e.kind == .Key_Down && e.key == .Escape { continue; }
				if e.kind == .Key_Down && e.key == .Backspace && text == "" && gdm.selected.count > 0 {
					pop(*gdm.selected);
					e.consumed = true;
					continue;
				}
				if ui.editor_event(*gdm.search, e, tl, clipboard_get, clipboard_set) != .None { e.consumed = true; }
			}
			note_focused_editor(*gdm.search, f);
			d := New(Search_Draw,, temp);
			d.ed = *gdm.search;
			f.custom_draw = search_caret_draw;
			f.custom_user = d;
			spacer(.X, 8);
		}
		spacer(.X, GDM_PAD);
	}
}

gdm_toggle :: (uid: dc.Snowflake) {
	found, i := array_find(gdm.selected, uid);
	if found array_ordered_remove_by_index(*gdm.selected, i);
	else if gdm.selected.count < GDM_MAX_OTHERS array_add(*gdm.selected, uid);
}

gdm_friend_row :: (uid: dc.Snowflake, y: float32, others: int) {
	u := dc.user_get(store(), uid);
	checked := array_find(gdm.selected, uid);
	disabled := !checked && others >= GDM_MAX_OTHERS;
	r := row("friend", .Clickable | .Draw_Background | .Hot_Animation | .Floating_X | .Floating_Y);
	r.semantic_size = .[ui.px(GDM_W - 2 * 8), ui.px(GDM_ROW_H)];
	r.fixed_pos = .{8, y};
	r.style.radius = all4(4);
	r.style.bg_hot = T("--background-mod-subtle");
	sig := ui.signal(r);
	if sig.clicked && !disabled { gdm_toggle(uid); }
	{ ui.parent(r); defer ui.pop_parent();
		spacer(.X, 8);
		avatar_with_status("av", uid, 32, ifx sig.hovering then T("--background-surface-higher") else T("--background-surface-high"));
		spacer(.X, 12);
		label(dc.user_name(store(), uid, 0, "unknown"), .Medium, 16, T("--interactive-text-active"), 20);
		spacer(.X, 6);
		label(ifx u != null then u.username else "", .Normal, 14, T("--text-muted"), 18);
		filler(.X);
		cb := ui.box("check", .Draw_Background | .Draw_Border);
		cb.semantic_size = .[ui.px(GDM_CHECK), ui.px(GDM_CHECK)];
		cb.style.radius = all4(6);
		cb.style.border = ifx checked then 0.0 else 1.0;
		cb.style.border_color = T("--checkbox-border-default");
		cb.style.bg = ifx checked then T("--background-brand") else .{};
		if checked {
			{ ui.parent(cb); defer ui.pop_parent();
				i := ui.box("i", .Floating_X | .Floating_Y);
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
	ids: [..]dc.Snowflake;
	ids.allocator = temp;
	if fixed != 0 array_add(*ids, fixed);
	array_add(*ids, ..gdm.selected);
	gdm.open = false;
	app.ui.focus = 0;
	if !net_action() return;
	if ids.count == 1 {
		existing := dc.open_dm(app.client, ids[0], "Create DM");
		if existing != 0 {
			select_channel(0, existing);
			return;
		}
	} else {
		dc.create_private_channel(app.client, ids, "Create DM");
	}
	app.pending_dm_user = ifx ids.count > 0 then ids[0] else store().me;
}
