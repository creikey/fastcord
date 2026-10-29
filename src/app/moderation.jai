// Kick, Ban and Timeout from the user menu, each behind a confirm with an optional reason (Remove Timeout
// goes at once). The same requests drive Discord and `fastcord -serve`, which answers kick and ban for its owner.

Moderation :: struct {
	user: dc.Snowflake;
	guild: dc.Snowflake;
	ban: bool;
	timeout: bool; // the Timeout modal (ban false)
	ed: ui.Editor;
	history: int; // Ban: an index into BAN_HISTORY, how much of their recent messages goes too; Timeout: into TIMEOUTS.
	history_open: bool;
	history_anchor: ui.Rect;
}

Mod_Option :: struct { secs: int; name: string; }
TIMEOUTS :: Mod_Option.[.{60, "60 Seconds"}, .{300, "5 Minutes"}, .{600, "10 Minutes"}, .{3600, "1 Hour"}, .{86400, "1 Day"}, .{604800, "1 Week"}];
BAN_HISTORY :: Mod_Option.[
	.{0, "Don't Delete Any"}, .{3600, "Previous Hour"}, .{21600, "Previous 6 Hours"}, .{43200, "Previous 12 Hours"},
	.{86400, "Previous 24 Hours"}, .{259200, "Previous 3 Days"}, .{604800, "Previous 7 Days"},
];

modr: Moderation;

// The user menu's items: "Kick <name>" and "Ban <name>", when we may.
moderation_menu_items :: (uid: dc.Snowflake, items: *[..]string) {
	gid := app.view.guild;
	if gid == 0 return;
	u := dc.user_get(store(), uid);
	if u == null return;
	if dc.can_moderate(store(), gid, uid, dc.PERM_KICK_MEMBERS) array_add(items, tprint("Kick %", u.username));
	if dc.can_moderate(store(), gid, uid, dc.PERM_BAN_MEMBERS) array_add(items, tprint("Ban %", u.username));
	if dc.can_moderate(store(), gid, uid, dc.PERM_MODERATE_MEMBERS) array_add(items, ifx dc.timed_out(store(), gid, uid) then "Remove Timeout" else tprint("Timeout %", u.username));
}

// moderation_menu_click opens the confirm for a clicked item; false if the item isn't one of ours.
moderation_menu_click :: (uid: dc.Snowflake, item: string) -> bool {
	if item == "Remove Timeout" {
		if net_action() dc.timeout_member(app.client, app.view.guild, uid, 0, "");
		return true;
	}
	ban := begins_with(item, "Ban ");
	timeout := begins_with(item, "Timeout ");
	if !ban && !timeout && !begins_with(item, "Kick ") return false;
	modr.user, modr.guild, modr.ban, modr.timeout = uid, app.view.guild, ban, timeout;
	modr.history, modr.history_open = 0, false;
	ui.editor_set_text(*modr.ed, "");
	return true;
}

moderation_modal :: () {
	s := store();
	u := dc.user_get(s, modr.user);
	g := dc.guild_get(s, modr.guild);
	if u == null || g == null {
		modr.user = 0;
		return;
	}
	scrim := ui.box("modr_scrim", .Draw_Background | .Clickable | .Floating_X | .Floating_Y | .Overlay);
	scrim.semantic_size = .[ui.px(app.ui.window.x), ui.px(app.ui.window.y)];
	scrim.style.bg = .{0, 0, 0, 0.7};
	if ui.signal(scrim).clicked {
		modr.user = 0;
		return;
	}
	W :: 440;
	PAD :: 24;
	verb := ifx modr.ban then "Ban" else ifx modr.timeout then "Timeout" else "Kick";
	opts: []Mod_Option = ifx modr.timeout then cast([]Mod_Option) TIMEOUTS else cast([]Mod_Option) BAN_HISTORY;
	d := ui.box("modrmodal", .Draw_Background | .Draw_Border | .Floating_X | .Floating_Y | .Overlay | .Clickable);
	d.semantic_size = .[ui.px(W), ui.children()];
	d.fixed_pos = .{(app.ui.window.x - W) / 2, (app.ui.window.y - (d.rect.y1 - d.rect.y0)) / 2};
	d.style.bg = T("--modal-background");
	d.style.border_color = T("--border-subtle");
	d.style.border = 1;
	d.style.radius = all4(12);
	d.layout_axis = .Y;
	ui.signal(d);
	ui.push_parent(d);
	defer ui.pop_parent();
	text_row :: (id: string, text: string, font: Font_Id, size: float32, lh: float32, color: ui.Color) {
		r := row(id);
		r.semantic_size = .[ui.pct(1), ui.children()];
		{ ui.parent(r); defer ui.pop_parent();
			spacer(.X, PAD);
			p := ui.box(tprint("%##text", text), .Draw_Text | .Wrap_Text);
			p.semantic_size = .[ui.fill(), ui.text_size()];
			p.style.font = F(font);
			p.style.font_size = size;
			p.style.line_height = lh;
			p.style.text_color = color;
			spacer(.X, PAD);
		}
	}
	button :: (id: string, w: float32, bg: ui.Color, bg_hot: ui.Color, fg: ui.Color) -> bool {
		b := ui.box(id, .Clickable | .Draw_Background | .Draw_Text | .Hot_Animation);
		b.semantic_size = .[ui.px(w), ui.px(38)];
		b.style.radius = all4(8);
		b.style.font = F(.Medium);
		b.style.font_size = 14;
		b.style.text_align = .Center;
		b.style.text_color = fg;
		b.style.bg = bg;
		b.style.bg_hot = bg_hot;
		return ui.signal(b).clicked;
	}
	spacer(.Y, PAD);
	text_row("t", ifx modr.timeout then tprint(L("Timeout %"), u.username) else tprint(L("% '%' from Server"), verb, u.username), .Semibold, 20, 24, T("--text-strong"));
	spacer(.Y, 8);
	sub := ifx modr.ban
		then tprint("Are you sure you want to ban @% from %? They won't be able to come back until the ban is lifted.", u.username, g.name)
		else ifx modr.timeout then "Members in timeout can't send messages, react, join voice or start threads until it ends."
		else tprint("Are you sure you want to kick @% from %? They will be able to rejoin again with a new invite.", u.username, g.name);
	text_row("sub", sub, .Normal, 14, 18, T("--text-default"));
	spacer(.Y, 16);
	text_row("lbl", tprint(L("Reason for %"), verb), .Semibold, 14, 18, T("--text-strong"));
	spacer(.Y, 8);
	confirm := false;
	ir := row("inrow");
	ir.semantic_size = .[ui.pct(1), ui.px(40)];
	{ ui.parent(ir); defer ui.pop_parent();
		spacer(.X, PAD);
		field := row("input", .Draw_Background | .Draw_Border | .Clickable);
		field.semantic_size = .[ui.fill(), ui.px(40)];
		field.style.bg = T("--input-background-default");
		field.style.border_color = T("--input-border-active");
		field.style.border = 1;
		field.style.radius = all4(8);
		field.hover_cursor = .IBeam;
		{ ui.parent(field); defer ui.pop_parent();
			spacer(.X, 12);
			res := text_field("field", *modr.ed, "", true, 16, 20, 10, T("--input-placeholder-text-default"));
			if res == .Submit confirm = true;
			if res == .Escape && !modr.history_open modr.user = 0;
			spacer(.X, 12);
		}
		spacer(.X, PAD);
	}
	if modr.ban || modr.timeout {
		spacer(.Y, 16);
		text_row("hlbl", ifx modr.timeout then L("Duration") else L("Delete Message History"), .Semibold, 14, 18, T("--text-strong"));
		spacer(.Y, 8);
		hr := row("histrow");
		hr.semantic_size = .[ui.pct(1), ui.px(40)];
		{ ui.parent(hr); defer ui.pop_parent();
			spacer(.X, PAD);
			dd := row("history", .Draw_Background | .Draw_Border | .Clickable);
			dd.semantic_size = .[ui.fill(), ui.px(40)];
			dd.style.bg = T("--input-background-default");
			dd.style.border = 1;
			dd.style.border_color = ifx modr.history_open then T("--input-border-active") else T("--input-border-default");
			dd.style.radius = all4(8);
			dd.hover_cursor = .Pointer;
			if ui.signal(dd).clicked modr.history_open = !modr.history_open;
			modr.history_anchor = dd.rect;
			{ ui.parent(dd); defer ui.pop_parent();
				spacer(.X, 12);
				label(opts[modr.history].name, .Normal, 16, T("--text-strong"), 20);
				filler(.X);
				icon("chev", ifx modr.history_open then "chevron-small-up" else "chevron-small-down", 20, T("--interactive-icon-default"));
				spacer(.X, 12);
			}
			spacer(.X, PAD);
		}
	}
	spacer(.Y, PAD);
	btns := row("btns", .Draw_Background);
	btns.semantic_size = .[ui.pct(1), ui.px(70)];
	btns.style.bg = T("--background-base-lower");
	btns.style.radius = .[0, 0, 12, 12];
	btns.style.child_gap = 8;
	{ ui.parent(btns); defer ui.pop_parent();
		filler(.X);
		if button(L("Cancel##cancel"), 96, T("--background-mod-normal"), T("--background-mod-strong"), T("--text-strong")) modr.user = 0;
		if button(tprint("%##confirm", verb), 96, T("--status-danger"), with_alpha(T("--status-danger"), 0.85), .{1, 1, 1, 1}) confirm = true;
		spacer(.X, PAD - 8);
	}
	if confirm && modr.user != 0 {
		reason := ui.editor_text(*modr.ed);
		if net_action() {
			if modr.ban dc.ban_member(app.client, modr.guild, modr.user, reason, BAN_HISTORY[modr.history].secs);
			else if modr.timeout dc.timeout_member(app.client, modr.guild, modr.user, dc.now_ms() + TIMEOUTS[modr.history].secs * 1000, reason);
			else dc.kick_member(app.client, modr.guild, modr.user, reason);
		}
		modr.user = 0;
	}
	if !modr.history_open for * e: app.ui.events {
		if !e.consumed && e.kind == .Key_Down && e.key == .Escape {
			e.consumed = true;
			modr.user = 0;
		}
	}
}

// The Delete Message History dropdown's list, over the modal. Drawn after it, outside its box, since a
// floating box's position is relative to its parent.
ban_history_list :: () {
	r := modr.history_anchor;
	if r.x1 <= r.x0 return;
	for * e: app.ui.events {
		if !e.consumed && e.kind == .Key_Down && e.key == .Escape {
			e.consumed = true;
			modr.history_open = false;
		}
	}
	if outside_pressed("hist_out") {
		modr.history_open = false;
		return;
	}
	opts: []Mod_Option = ifx modr.timeout then cast([]Mod_Option) TIMEOUTS else cast([]Mod_Option) BAN_HISTORY;
	h := cast(float32) opts.count * 36 + 8;
	list := ui.box("histlist", .Draw_Background | .Draw_Border | .Draw_Shadow | .Floating_X | .Floating_Y | .Overlay | .Clickable);
	list.semantic_size = .[ui.px(r.x1 - r.x0), ui.px(h)];
	list.fixed_pos = .{r.x0, ifx r.y1 + 4 + h > app.ui.window.y then r.y0 - 4 - h else r.y1 + 4};
	list.layout_axis = .Y;
	list.style.bg = T("--background-surface-higher");
	list.style.border = 1;
	list.style.border_color = T("--border-subtle");
	list.style.radius = all4(8);
	list.style.shadow_color = .{0, 0, 0, 0.24};
	list.style.shadow_blur = 16;
	list.style.shadow_offset = .{0, 8};
	ui.signal(list);
	ui.parent(list); defer ui.pop_parent();
	spacer(.Y, 4);
	for opt, i: opts {
		ui.id_scope(cast(u64) i + 1);
		defer ui.pop_seed();
		sel := i == modr.history;
		item := row("opt", .Clickable | .Draw_Background | .Hot_Animation);
		item.semantic_size = .[ui.pct(1), ui.px(36)];
		item.style.bg = ifx sel then T("--background-mod-normal") else .{};
		item.style.bg_hot = T("--background-mod-normal");
		if ui.signal(item).clicked {
			modr.history = i;
			modr.history_open = false;
		}
		ui.parent(item); defer ui.pop_parent();
		spacer(.X, 12);
		label(opt.name, ifx sel then .Semibold else .Normal, 16, T("--text-strong"), 20);
	}
}
