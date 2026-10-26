package app

import "core:fmt"
import "core:slice"
import "core:strings"
import dc "fc:discord"
import "fc:ui"

// "Select Friends" popout (DM list "+", and "Add Friends to DM" in a 1:1 DM
// header) and the group DM member list.
// Strings from the client: "Select Friends", "You can add N more friends.",
// "Type the username of a friend", "Create DM" / "Create Group DM",
// "You don't have any friends to add!". A group DM holds 10 people (you + 9).

GDM_W :: 440
GDM_PAD :: 16
GDM_ROW_H :: 40
GDM_LIST_MAX_H :: 248
GDM_CHECK :: 22
GDM_MAX_OTHERS :: 9
GDM_BUTTON_H :: 38

@(private = "file")
Gdm_State :: struct {
	open:     bool,
	anchor:   ui.Rect,
	from_dm:  dc.Snowflake, // opened from a 1:1 DM: its recipient is preselected and fixed
	selected: [dynamic]dc.Snowflake,
	search:   ui.Editor,
	scroll:   Pk_Scroll,
	t:        f32,
	rect:     ui.Rect,
}

@(private = "file")
gdm: Gdm_State

// The "+" next to "Direct Messages" (replaces the plain icon in home_sidebar).
dm_create_button :: proc() {
	b := ui.box("dmplus", {.Clickable})
	b.semantic_size = {.X = ui.px(18), .Y = ui.px(18)}
	sig := ui.signal(b)
	set_icon(b, "plus-small", sig.hovering || gdm.open ? T("--interactive-icon-hover") : T("--interactive-icon-default"))
	if sig.hovering && !gdm.open do tooltip_below("Create DM", b.rect)
	if sig.clicked {
		if gdm.open do gdm.open = false
		else do group_dm_popout_open(b.rect, 0)
	}
}

group_dm_popout_open :: proc(anchor: ui.Rect, from_dm: dc.Snowflake) {
	gdm.open = true
	gdm.anchor = anchor
	gdm.from_dm = from_dm
	gdm.t = 0
	gdm.scroll = {}
	clear(&gdm.selected)
	ui.editor_set_text(&gdm.search, "")
}

// Small tooltip under a rect (overlay, window coordinates).
tooltip_below :: proc(text: string, r: ui.Rect) {
	tip := row("tipb###tooltip_below", {.Draw_Background, .Draw_Shadow, .Floating_X, .Floating_Y, .Overlay})
	tip.semantic_size = {.X = ui.children(), .Y = ui.px(32)}
	p := ui.top_parent()
	tip.fixed_pos = {r.x0 - 40 - p.rect.x0, r.y1 + 8 - p.rect.y0}
	tip.style.bg = T("--background-surface-highest")
	tip.style.radius = 8
	tip.style.shadow_color = {0, 0, 0, 0.3}
	tip.style.shadow_blur = 8
	if ui.parent(tip) {
		spacer(.X, 12)
		label(text, .Semibold, 14, T("--text-strong"), 18)
		spacer(.X, 12)
	}
}

@(private = "file")
friends_sorted :: proc() -> []dc.Snowflake {
	s := store()
	out := make([dynamic]dc.Snowflake, context.temp_allocator)
	for uid, rel in s.relationships do if rel.kind == .Friend do append(&out, uid)
	sort_users_by_name(out[:])
	return out[:]
}

// Overlay entry (views.odin overlays()).
group_dm_overlay :: proc() {
	if !gdm.open do return
	focus_before := app.ui.focus // a field pressed this frame (the popout's field takes focus below)
	s := store()
	ui.animate(&gdm.t, 1, 30)
	r := ui.Rect{gdm.anchor.x0 - 20, gdm.anchor.y1 + 8, gdm.anchor.x0 - 20 + GDM_W, 0}
	if gdm.from_dm != 0 do r.x0, r.x1 = gdm.anchor.x1 - GDM_W, gdm.anchor.x1
	r.x0 = clamp(r.x0, 8, app.ui.window.x - GDM_W - 8)
	r.x1 = r.x0 + GDM_W
	pop := ui.box("gdm###gdm_popout", {.Draw_Background, .Draw_Border, .Draw_Shadow, .Floating_X, .Floating_Y, .Overlay, .Clickable})
	pop.semantic_size = {.X = ui.px(GDM_W), .Y = ui.children()}
	pop.fixed_pos = {r.x0, r.y0 + (1 - gdm.t) * 8}
	pop.layout_axis = .Y
	pop.style.bg = T("--background-surface-high")
	pop.style.border_color = T("--border-subtle")
	pop.style.border = 1
	pop.style.radius = 8
	pop.style.shadow_color = {0, 0, 0, 0.32}
	pop.style.shadow_blur = 16
	pop.style.shadow_offset = {0, 8}
	ui.signal(pop)
	gdm.rect = pop.rect
	fixed := dc.Snowflake(0)
	if c := dc.channel_get(s, gdm.from_dm); c != nil && c.kind == .DM && len(c.recipient_ids) > 0 do fixed = c.recipient_ids[0]
	friends := friends_sorted()
	q := strings.to_lower(strings.trim_space(ui.editor_text(&gdm.search)), context.temp_allocator)
	shown := make([dynamic]dc.Snowflake, context.temp_allocator)
	for uid in friends {
		if uid == fixed do continue
		u := dc.user_get(s, uid)
		if u == nil do continue
		if q != "" && !strings.contains(strings.to_lower(dc.display_name(u), context.temp_allocator), q) && !strings.contains(strings.to_lower(u.username, context.temp_allocator), q) do continue
		append(&shown, uid)
	}
	others := len(gdm.selected) + (fixed != 0 ? 1 : 0)
	if ui.parent(pop) {
		spacer(.Y, GDM_PAD)
		h := row("title")
		h.semantic_size = {.X = ui.pct(1), .Y = ui.px(24)}
		if ui.parent(h) {
			spacer(.X, GDM_PAD)
			label("Select Friends", .Semibold, 20, T("--text-strong"), 24)
		}
		spacer(.Y, 4)
		sub := row("sub")
		sub.semantic_size = {.X = ui.pct(1), .Y = ui.px(16)}
		if ui.parent(sub) {
			spacer(.X, GDM_PAD)
			left := GDM_MAX_OTHERS - others
			msg := left == 1 ? "You can add 1 more friend." : fmt.tprintf("You can add %d more friends.", left)
			label(msg, .Normal, 12, left <= 0 ? T("--text-feedback-critical") : T("--text-muted"), 16)
		}
		spacer(.Y, 16)
		gdm_search_row()
		spacer(.Y, 8)
		list_h := min(GDM_LIST_MAX_H, max(f32(len(shown)) * (GDM_ROW_H + 2), 56))
		list := ui.box("list", {.Clip})
		list.semantic_size = {.X = ui.pct(1), .Y = ui.px(list_h)}
		view := list.rect
		pk_scroll_update(&gdm.scroll, view, f32(len(shown)) * (GDM_ROW_H + 2))
		if ui.parent(list) {
			if len(friends) == 0 {
				e := ui.box("empty", {.Floating_X, .Floating_Y})
				e.semantic_size = {.X = ui.px(GDM_W), .Y = ui.px(list_h)}
				e.layout_axis = .Y
				e.cross_align = .Center
				if ui.parent(e) {
					spacer(.Y, 18)
					label("You don't have any friends to add!", .Medium, 14, T("--text-muted"), 18)
				}
			}
			for uid, i in shown {
				y := f32(i) * (GDM_ROW_H + 2) - gdm.scroll.y
				if y + GDM_ROW_H < 0 || y > list_h do continue
				if ui.id_scope(u64(uid)) do gdm_friend_row(uid, y, others)
			}
			pk_scrollbar(&gdm.scroll, GDM_W - PK_SCROLLBAR_W - 4)
		}
		spacer(.Y, 8)
		line := ui.box("line", {.Draw_Background})
		line.semantic_size = {.X = ui.pct(1), .Y = ui.px(1)}
		line.style.bg = T("--border-subtle")
		spacer(.Y, 16)
		br := row("btnrow")
		br.semantic_size = {.X = ui.pct(1), .Y = ui.px(GDM_BUTTON_H)}
		if ui.parent(br) {
			spacer(.X, GDM_PAD)
			text := others >= 2 ? "Create Group DM" : "Create DM"
			btn := ui.box(fmt.tprintf("%s##create", text), {.Clickable, .Draw_Background, .Draw_Text, .Hot_Animation})
			btn.semantic_size = {.X = ui.fill(), .Y = ui.px(GDM_BUTTON_H)}
			btn.style.radius = 8
			btn.style.bg = T("--background-brand")
			btn.style.bg_hot = with_alpha(T("--background-brand"), 0.85)
			btn.style.font = F(.Medium)
			btn.style.font_size = 14
			btn.style.text_color = {1, 1, 1, 1}
			btn.style.text_align = .Center
			if ui.signal(btn).clicked do gdm_create(fixed)
			spacer(.X, GDM_PAD)
		}
		spacer(.Y, GDM_PAD)
	}
	for &e in app.ui.events {
		// a press outside closes the popout even when a control under it took the press
		if e.kind == .Mouse_Down && gdm.rect.x1 > gdm.rect.x0 && !pk_contains(gdm.rect, e.pos) && !pk_contains(gdm.anchor, e.pos) do gdm.open = false
		if e.consumed do continue
		if e.kind == .Key_Down && e.key == .Escape {
			e.consumed = true
			gdm.open = false
		}
	}
	// give up the keyboard only if the popout still has it (a press outside may
	// have just focused another field)
	if !gdm.open {
		own := ui.key_from_string("gdmq###gdm_search", 0)
		app.ui.focus = focus_before == own ? 0 : focus_before
	}
	pk_fade(pop, gdm.t)
}

@(private = "file")
gdm_search_row :: proc() {
	r := row("searchrow")
	r.semantic_size = {.X = ui.pct(1), .Y = ui.px(36)}
	if ui.parent(r) {
		spacer(.X, GDM_PAD)
		w := row("search", {.Draw_Background, .Draw_Border, .Clickable})
		w.semantic_size = {.X = ui.fill(), .Y = ui.px(36)}
		w.style.bg = T("--input-background-default")
		w.style.border_color = T("--border-focus")
		w.style.border = 1
		w.style.radius = 8
		w.hover_cursor = .IBeam
		if ui.parent(w) {
			spacer(.X, 8)
			// selected friends as chips, like the client's tag input
			for uid in gdm.selected {
				u := dc.user_get(store(), uid)
				if u == nil do continue
				if ui.id_scope(u64(uid)) {
					chip := ui.box(fmt.tprintf("%s##chip", dc.display_name(u)), {.Clickable, .Draw_Background, .Draw_Text, .Hot_Animation})
					chip.semantic_size = {.X = ui.text_size(6), .Y = ui.px(24)}
					chip.style.radius = 4
					chip.style.bg = T("--background-mod-normal")
					chip.style.bg_hot = T("--background-mod-strong")
					chip.style.font = F(.Medium)
					chip.style.font_size = 14
					chip.style.text_color = T("--text-default")
					if ui.signal(chip).clicked do gdm_toggle(uid)
					spacer(.X, 4)
				}
			}
			f := ui.box("gdmq###gdm_search", {.Clickable, .Draw_Text, .Focusable, .Clip})
			f.semantic_size = {.X = ui.fill(), .Y = ui.px(34)}
			f.style.font = F(.Normal)
			f.style.font_size = 16
			f.style.line_height = 20
			f.hover_cursor = .IBeam
			text := ui.editor_text(&gdm.search)
			f.text = text
			f.style.text_color = T("--text-default")
			if text == "" {
				f.text = len(gdm.selected) == 0 ? "Type the username of a friend" : ""
				f.style.text_color = T("--input-placeholder-text-default")
			}
			app.ui.focus = f.key
			tl := f.text_layout
			if text == "" do tl = nil
			for &e in app.ui.events {
				if e.consumed || (e.kind != .Key_Down && e.kind != .Text) do continue
				if e.kind == .Key_Down && e.key == .Escape do continue
				if e.kind == .Key_Down && e.key == .Backspace && text == "" && len(gdm.selected) > 0 {
					pop(&gdm.selected)
					e.consumed = true
					continue
				}
				if ui.editor_event(&gdm.search, e, tl, clipboard_get, clipboard_set) != .None do e.consumed = true
			}
			note_focused_editor(&gdm.search, f)
			d := new(Search_Draw, context.temp_allocator)
			d.ed = &gdm.search
			f.custom_draw = search_caret_draw
			f.custom_user = d
			spacer(.X, 8)
		}
		spacer(.X, GDM_PAD)
	}
}

@(private = "file")
gdm_toggle :: proc(uid: dc.Snowflake) {
	if i, found := slice.linear_search(gdm.selected[:], uid); found {
		ordered_remove(&gdm.selected, i)
	} else if len(gdm.selected) < GDM_MAX_OTHERS {
		append(&gdm.selected, uid)
	}
}

@(private = "file")
gdm_friend_row :: proc(uid: dc.Snowflake, y: f32, others: int) {
	u := dc.user_get(store(), uid)
	checked := slice.contains(gdm.selected[:], uid)
	disabled := !checked && others >= GDM_MAX_OTHERS
	r := row("friend", {.Clickable, .Draw_Background, .Hot_Animation, .Floating_X, .Floating_Y})
	r.semantic_size = {.X = ui.px(GDM_W - 2 * 8), .Y = ui.px(GDM_ROW_H)}
	r.fixed_pos = {8, y}
	r.style.radius = 4
	r.style.bg_hot = T("--background-mod-subtle")
	sig := ui.signal(r)
	if sig.clicked && !disabled do gdm_toggle(uid)
	if ui.parent(r) {
		spacer(.X, 8)
		avatar_with_status("av", uid, 32, sig.hovering ? T("--background-surface-higher") : T("--background-surface-high"))
		spacer(.X, 12)
		label(u != nil ? dc.display_name(u) : "unknown", .Medium, 16, T("--interactive-text-active"), 20)
		spacer(.X, 6)
		label(u != nil ? u.username : "", .Normal, 14, T("--text-muted"), 18)
		filler(.X)
		cb := ui.box("check", {.Draw_Background, .Draw_Border})
		cb.semantic_size = {.X = ui.px(GDM_CHECK), .Y = ui.px(GDM_CHECK)}
		cb.style.radius = 6
		cb.style.border = checked ? 0 : 1
		cb.style.border_color = T("--checkbox-border-default")
		cb.style.bg = checked ? T("--background-brand") : {}
		if checked {
			if ui.parent(cb) {
				i := ui.box("i", {.Floating_X, .Floating_Y})
				i.semantic_size = {.X = ui.px(18), .Y = ui.px(18)}
				i.fixed_pos = {2, 2}
				set_icon(i, "checkmark-small", {1, 1, 1, 1})
			}
		}
		spacer(.X, 8)
	}
	if disabled do r.opacity = 0.5
}

// 0 friends: a group DM with just you (as the client does); 1 friend: open
// (or create) the DM; more: POST /users/@me/channels {recipients}.
@(private = "file")
gdm_create :: proc(fixed: dc.Snowflake) {
	ids := make([dynamic]dc.Snowflake, context.temp_allocator)
	if fixed != 0 do append(&ids, fixed)
	append(&ids, ..gdm.selected[:])
	gdm.open = false
	app.ui.focus = 0
	if !net_action() do return
	if len(ids) == 1 {
		if existing := dc.open_dm(app.client, ids[0], "Create DM"); existing != 0 {
			select_channel(0, existing)
			return
		}
	} else {
		dc.create_private_channel(app.client, ids[:], "Create DM")
	}
	app.pending_dm_user = len(ids) > 0 ? ids[0] : store().me
}

// ---- group DM member list ----

group_dm_members :: proc(ch: ^dc.Channel) {
	s := store()
	list := ui.box("gdm_members", {.Scroll_Y, .Clip, .Draw_Background})
	list.semantic_size = {.X = ui.px(MEMBER_LIST_W), .Y = ui.pct(1)}
	list.layout_axis = .Y
	list.style.bg = T("--background-base-lower")
	ui.signal(list)
	ids := make([dynamic]dc.Snowflake, context.temp_allocator)
	append(&ids, s.me)
	for id in ch.recipient_ids do if id != s.me do append(&ids, id)
	if ui.parent(list) {
		spacer(.Y, 8)
		gr := row("group")
		gr.semantic_size = {.X = ui.pct(1), .Y = ui.px(40)}
		gr.cross_align = .End
		if ui.parent(gr) {
			spacer(.X, 16)
			label(fmt.tprintf("Members — %d", len(ids)), .Medium, 12, T("--channels-default"), 16)
		}
		spacer(.Y, 4)
		for uid in ids {
			if ui.id_scope(u64(uid)) {
				member_row(0, uid)
				if uid == ch.owner_id {
					// crown after the name
					item := ui.top_parent().last
					if ui.parent(item) {
						c := ui.box("crown", {.Floating_X, .Floating_Y})
						c.semantic_size = {.X = ui.px(14), .Y = ui.px(14)}
						name_w: f32 = 0
						if u := dc.user_get(s, uid); u != nil do name_w = f32(len(dc.display_name(u))) * 8.2
						c.fixed_pos = {8 + 8 + 32 + 12 + name_w + 4, 15}
						set_icon(c, "crown", T("--text-feedback-warning"))
					}
				}
			}
		}
		spacer(.Y, 16)
	}
}

gdm_reset_for_test :: proc() {gdm = {}}
gdm_state_for_test :: proc() -> string {return fmt.tprint(gdm.open, gdm.selected[:])}
