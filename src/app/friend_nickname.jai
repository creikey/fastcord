// Friend nicknames: names shown through dc.user_name, and the
// "Add / Edit Friend Nickname" modal opened from the user menu.

// name_in: a user's name as shown in a channel (its server's nickname first).
name_in :: (uid: dc.Snowflake, channel_id: dc.Snowflake, unknown := "Unknown") -> string {
	s := store();
	ch := dc.channel_get(s, channel_id);
	return dc.user_name(s, uid, ifx ch then ch.guild_id else 0, unknown);
}

// author_name: a message's author as shown; a webhook post goes by the name it was posted under.
author_name :: (m: *dc.Message, unknown := "Unknown") -> string {
	return ifx m.webhook_name then m.webhook_name else name_in(m.author_id, m.channel_id, unknown);
}
author_name :: (m: *dc.New_Message, unknown := "Unknown") -> string {
	return ifx m.webhook_name then m.webhook_name else name_in(m.author_id, m.channel_id, unknown);
}

// The user menu's item for this user ("" when they aren't a friend).
friend_nick_menu_item :: (uid: dc.Snowflake) -> string {
	r := table_find_pointer(*store().relationships, uid);
	if !r || r.kind != .Friend { return ""; }
	return ifx r.nickname != "" then "Edit Friend Nickname" else "Add Friend Nickname";
}

// "Change Nickname" in a guild's user menu: our own needs CHANGE_NICKNAME, someone
// else's MANAGE_NICKNAMES and a higher role (dc.can_set_nickname).
server_nick_menu_item :: (uid: dc.Snowflake) -> string {
	if app.view.guild == 0 || !dc.can_set_nickname(store(), app.view.guild, uid) { return ""; }
	// without the member's roles the hierarchy is unknown: only the owner may then
	g := dc.guild_get(store(), app.view.guild);
	if dc.member_get(store(), app.view.guild, uid) == null && (g == null || g.owner_id != store().me) { return ""; }
	return "Change Nickname";
}

// One dialog for both: guild == 0 edits the friend nickname, else the server nickname.
Friend_Nick :: struct {
	user: dc.Snowflake;
	guild: dc.Snowflake;
	ed: ui.Editor;
}

fnick: Friend_Nick;

friend_nick_open :: (uid: dc.Snowflake) {
	fnick.user = uid;
	fnick.guild = 0;
	ui.editor_set_text(*fnick.ed, dc.friend_nickname(store(), uid));
}

server_nick_open :: (uid: dc.Snowflake, guild: dc.Snowflake) {
	fnick.user = uid;
	fnick.guild = guild;
	m := dc.member_get(store(), guild, uid);
	ui.editor_set_text(*fnick.ed, ifx m then m.nick else "");
	if app.client != null { dc.open_change_nickname(app.client); }
}
#scope_file

friend_nick_save :: (nick: string) {
	uid, gid := fnick.user, fnick.guild;
	fnick.user = 0;
	n := trim(nick);
	if gid != 0 {
		m := dc.member_get(store(), gid, uid);
		if n == (ifx m then m.nick else "") { return; }
		if net_action() { dc.set_server_nickname(app.client, gid, uid, n); } else { dc.store_set_server_nickname(store(), gid, uid, n); }
		return;
	}
	if n == dc.friend_nickname(store(), uid) { return; }
	if net_action() { dc.set_friend_nickname(app.client, uid, n); } else { dc.store_set_friend_nickname(store(), uid, n); } // offline (fixture) runs show the result
}
#scope_export

// cut_runes: s cut to its first n runes (the limits count runes, not bytes).
cut_runes :: (s: string, n: int) -> string {
	k := 0;
	for i: 0..s.count-1 {
		if (s[i] & 0xC0) == 0x80 continue;
		if k == n return string.{i, s.data};
		k += 1;
	}
	return s;
}

friend_nick_modal :: () {
	s := store();
	uid := fnick.user;
	u := dc.user_get(s, uid);
	if u == null {
		fnick.user = 0;
		return;
	}
	scrim := ui.box("fnick_scrim", .Draw_Background | .Clickable | .Floating_X | .Floating_Y | .Overlay);
	scrim.semantic_size = .[ui.px(app.ui.window.x), ui.px(app.ui.window.y)];
	scrim.style.bg = .{0, 0, 0, 0.7};
	if ui.signal(scrim).clicked {
		fnick.user = 0;
		return;
	}
	W :: 440;
	PAD :: 24;
	server := fnick.guild != 0;
	had := !server && dc.friend_nickname(s, uid) != "";
	d := ui.box("fnickmodal", .Draw_Background | .Draw_Border | .Floating_X | .Floating_Y | .Overlay | .Clickable);
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
		r.semantic_size = .[ui.pct(1), ui.px(lh)];
		{ ui.parent(r); defer ui.pop_parent();
			spacer(.X, PAD);
			label(text, font, size, color, lh);
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
	if server {
		text_row("t", L("Change Nickname"), .Semibold, 20, 24, T("--text-strong"));
		if uid != s.me {
			spacer(.Y, 16);
			wr := row("warnrow");
			wr.semantic_size = .[ui.pct(1), ui.children()];
			{ ui.parent(wr); defer ui.pop_parent();
				spacer(.X, PAD);
				warn := ui.box("warn", .Draw_Background);
				warn.semantic_size = .[ui.fill(), ui.children()];
				warn.layout_axis = .Y;
				warn.style.bg = T("--background-feedback-warning");
				warn.style.radius = all4(8);
				{ ui.parent(warn); defer ui.pop_parent();
					spacer(.Y, 10);
					pr := row("p");
					pr.semantic_size = .[ui.pct(1), ui.children()];
					{ ui.parent(pr); defer ui.pop_parent();
						spacer(.X, 12);
						p := ui.box(L("Nicknames are visible to everyone on this server. Do not change them unless you are enforcing a naming system or clearing a bad nickname.##warntext"), .Draw_Text | .Wrap_Text);
						p.semantic_size = .[ui.fill(), ui.text_size()];
						p.style.font = F(.Normal);
						p.style.font_size = 14;
						p.style.line_height = 18;
						p.style.text_color = T("--text-default");
						spacer(.X, 12);
					}
					spacer(.Y, 10);
				}
				spacer(.X, PAD);
			}
		}
		spacer(.Y, 16);
		text_row("lbl", L("Nickname"), .Semibold, 14, 18, T("--text-strong"));
	} else {
		text_row("t", ifx had then L("Edit Friend Nickname") else L("Add Friend Nickname"), .Semibold, 20, 24, T("--text-strong"));
		spacer(.Y, 8);
		text_row("sub", tprint(L("Only you can see the nickname you give %."), dc.display_name(u)), .Normal, 14, 18, T("--text-default"));
		spacer(.Y, 16);
		text_row("lbl", L("Friend Nickname"), .Semibold, 14, 18, T("--text-strong"));
	}
	spacer(.Y, 8);
	save := false;
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
			res := text_field("field", *fnick.ed, dc.display_name(u), true, 16, 20, 10, T("--input-placeholder-text-default"));
			t := ui.editor_text(*fnick.ed);
			cut := cut_runes(t, dc.FRIEND_NICKNAME_MAX);
			if cut.count < t.count { ui.editor_set_text(*fnick.ed, copy_string(cut,, temp)); }
			if res == .Submit { save = true; }
			if res == .Escape { fnick.user = 0; }
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
		spacer(.X, PAD - 8);
		// like the client: Reset only clears the field; Save sends {"nickname":null}
		if had && button(L("Reset Friend Nickname##reset"), 170, .{}, T("--background-mod-normal"), T("--text-link")) { ui.editor_set_text(*fnick.ed, ""); }
		filler(.X);
		if button(L("Cancel##cancel"), 96, T("--background-mod-normal"), T("--background-mod-strong"), T("--text-strong")) { fnick.user = 0; }
		if button(L("Save##save"), 96, T("--background-brand"), with_alpha(T("--background-brand"), 0.85), .{1, 1, 1, 1}) { save = true; }
		spacer(.X, PAD - 8);
	}
	if save && fnick.user != 0 { friend_nick_save(ui.editor_text(*fnick.ed)); }
	for * e: app.ui.events {
		if !e.consumed && e.kind == .Key_Down && e.key == .Escape {
			e.consumed = true;
			fnick.user = 0;
		}
	}
}

