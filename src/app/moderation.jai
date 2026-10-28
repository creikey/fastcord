// Kick and Ban from the user menu, each behind a confirm with an optional reason. The same requests drive
// Discord and `fastcord -serve`, which answers both for its owner.

Moderation :: struct {
	user: dc.Snowflake;
	guild: dc.Snowflake;
	ban: bool;
	ed: ui.Editor;
}

modr: Moderation;

// The user menu's items: "Kick <name>" and "Ban <name>", when we may.
moderation_menu_items :: (uid: dc.Snowflake, items: *[..]string) {
	gid := app.view.guild;
	if gid == 0 return;
	u := dc.user_get(store(), uid);
	if u == null return;
	if dc.can_moderate(store(), gid, uid, dc.PERM_KICK_MEMBERS) array_add(items, tprint("Kick %", u.username));
	if dc.can_moderate(store(), gid, uid, dc.PERM_BAN_MEMBERS) array_add(items, tprint("Ban %", u.username));
}

// moderation_menu_click opens the confirm for a clicked item; false if the item isn't one of ours.
moderation_menu_click :: (uid: dc.Snowflake, item: string) -> bool {
	ban := begins_with(item, "Ban ");
	if !ban && !begins_with(item, "Kick ") return false;
	modr.user, modr.guild, modr.ban = uid, app.view.guild, ban;
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
	verb := ifx modr.ban then "Ban" else "Kick";
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
	text_row("t", tprint("% '%' from Server", verb, u.username), .Semibold, 20, 24, T("--text-strong"));
	spacer(.Y, 8);
	sub := ifx modr.ban
		then tprint("Are you sure you want to ban @% from %? They won't be able to come back until the ban is lifted.", u.username, g.name)
		else tprint("Are you sure you want to kick @% from %? They will be able to rejoin again with a new invite.", u.username, g.name);
	text_row("sub", sub, .Normal, 14, 18, T("--text-default"));
	spacer(.Y, 16);
	text_row("lbl", tprint("Reason for %", verb), .Semibold, 14, 18, T("--text-strong"));
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
			if res == .Escape modr.user = 0;
			spacer(.X, 12);
		}
		spacer(.X, PAD);
	}
	spacer(.Y, PAD);
	btns := row("btns", .Draw_Background);
	btns.semantic_size = .[ui.pct(1), ui.px(70)];
	btns.style.bg = T("--background-base-lower");
	btns.style.radius = .[0, 0, 12, 12];
	btns.style.child_gap = 8;
	{ ui.parent(btns); defer ui.pop_parent();
		filler(.X);
		if button("Cancel##cancel", 96, T("--background-mod-normal"), T("--background-mod-strong"), T("--text-strong")) modr.user = 0;
		if button(tprint("%##confirm", verb), 96, T("--status-danger"), with_alpha(T("--status-danger"), 0.85), .{1, 1, 1, 1}) confirm = true;
		spacer(.X, PAD - 8);
	}
	if confirm && modr.user != 0 {
		reason := ui.editor_text(*modr.ed);
		if net_action() {
			if modr.ban dc.ban_member(app.client, modr.guild, modr.user, reason);
			else dc.kick_member(app.client, modr.guild, modr.user, reason);
		}
		modr.user = 0;
	}
	for * e: app.ui.events {
		if !e.consumed && e.kind == .Key_Down && e.key == .Escape {
			e.consumed = true;
			modr.user = 0;
		}
	}
}
