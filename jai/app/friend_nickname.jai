// Friend nicknames: names shown through dc.user_name, and the
// "Add / Edit Friend Nickname" modal opened from the user menu.

// name_in: a user's name as shown in a channel (its server's nickname first).
name_in :: (uid: dc.Snowflake, channel_id: dc.Snowflake, unknown := "Unknown") -> string {
	s := store();
	gid: dc.Snowflake;
	{ ch := dc.channel_get(s, channel_id);
	if ch != null { gid = ch.guild_id; } }
	return dc.user_name(s, uid, gid, unknown);
}

// The user menu's item for this user ("" when they aren't a friend).
friend_nick_menu_item :: (uid: dc.Snowflake) -> string {
	r, ok := map_find_ptr(*store().relationships, uid);
	if !ok || r.kind != .Friend { return ""; }
	return ifx r.nickname != "" then "Edit Friend Nickname" else "Add Friend Nickname";
}

// "Change Nickname" in a guild's user menu: our own needs CHANGE_NICKNAME, someone
// else's MANAGE_NICKNAMES and a higher role (dc.can_set_nickname).
server_nick_menu_item :: (uid: dc.Snowflake) -> string {
	if app.view.guild == 0 || !dc.can_set_nickname(store(), app.view.guild, uid) { return ""; }
	// without the member's roles the hierarchy is unknown: only the owner may then
	{ g := dc.guild_get(store(), app.view.guild);
	if dc.member_get(store(), app.view.guild, uid) == null && (g == null || g.owner_id != store().me) { return ""; } }
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
	nick := "";
	{ m := dc.member_get(store(), guild, uid);
	if m != null { nick = m.nick; } }
	ui.editor_set_text(*fnick.ed, nick);
	if app.client != null { dc.open_change_nickname(app.client); }
}
#scope_file

friend_nick_save :: (nick: string) {
	uid, gid := fnick.user, fnick.guild;
	fnick.user = 0;
	n := strings.trim_space(nick);
	if gid != 0 {
		old := "";
		{ m := dc.member_get(store(), gid, uid);
		if m != null { old = m.nick; } }
		if n == old { return; }
		if net_action() { dc.set_server_nickname(app.client, gid, uid, n); } else { dc.store_set_server_nickname(store(), gid, uid, n); }
		return;
	}
	if n == dc.friend_nickname(store(), uid) { return; }
	if net_action() { dc.set_friend_nickname(app.client, uid, n); } else { dc.store_set_friend_nickname(store(), uid, n); } // offline (fixture) runs show the result
}
#scope_export

friend_nick_modal :: () {
	s := store();
	uid := fnick.user;
	u := dc.user_get(s, uid);
	if u == null {
		fnick.user = 0;
		return;
	}
	scrim := ui.box("fnick_scrim", .{.Draw_Background, .Clickable, .Floating_X, .Floating_Y, .Overlay});
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
	d := ui.box("fnickmodal", .{.Draw_Background, .Draw_Border, .Floating_X, .Floating_Y, .Overlay, .Clickable});
	d.semantic_size = .[ui.px(W), ui.children()];
	d.fixed_pos = .{(app.ui.window.x - W) / 2, (app.ui.window.y - (d.rect.y1 - d.rect.y0)) / 2};
	d.style.bg = cast(T)("--modal-background");
	d.style.border_color = cast(T)("--border-subtle");
	d.style.border = 1;
	d.style.radius = 12;
	d.layout_axis = .Y;
	ui.signal(d);
	ui.push_parent(d);
	defer ui.pop_parent();
	text_row :: (id: string, text: string, font: Font_Id, size: float32, lh: float32, color: ui.Color) {
		r := row(id);
		r.semantic_size = .[ui.pct(1), ui.px(lh)];
		if ui.parent(r) {
			spacer(.X, PAD);
			label(text, font, size, color, lh);
		}
	}
	button :: (id: string, w: float32, bg: ui.Color, bg_hot: ui.Color, fg: ui.Color) -> bool {
		b := ui.box(id, .{.Clickable, .Draw_Background, .Draw_Text, .Hot_Animation});
		b.semantic_size = .[ui.px(w), ui.px(38)];
		b.style.radius = 8;
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
		text_row("t", "Change Nickname", .Semibold, 20, 24, cast(T)("--text-strong"));
		if uid != s.me {
			spacer(.Y, 16);
			wr := row("warnrow");
			wr.semantic_size = .[ui.pct(1), ui.children()];
			if ui.parent(wr) {
				spacer(.X, PAD);
				warn := ui.box("warn", .{.Draw_Background});
				warn.semantic_size = .[ui.fill(), ui.children()];
				warn.layout_axis = .Y;
				warn.style.bg = cast(T)("--background-feedback-warning");
				warn.style.radius = 8;
				if ui.parent(warn) {
					spacer(.Y, 10);
					pr := row("p");
					pr.semantic_size = .[ui.pct(1), ui.children()];
					if ui.parent(pr) {
						spacer(.X, 12);
						p := ui.box("Nicknames are visible to everyone on this server. Do not change them unless you are enforcing a naming system or clearing a bad nickname.##warntext", .{.Draw_Text, .Wrap_Text});
						p.semantic_size = .[ui.fill(), ui.text_size()];
						p.style.font = F(.Normal);
						p.style.font_size = 14;
						p.style.line_height = 18;
						p.style.text_color = cast(T)("--text-default");
						spacer(.X, 12);
					}
					spacer(.Y, 10);
				}
				spacer(.X, PAD);
			}
		}
		spacer(.Y, 16);
		text_row("lbl", "Nickname", .Semibold, 14, 18, cast(T)("--text-strong"));
	} else {
		text_row("t", ifx had then "Edit Friend Nickname" else "Add Friend Nickname", .Semibold, 20, 24, cast(T)("--text-strong"));
		spacer(.Y, 8);
		text_row("sub", fmt.tprintf("Only you can see the nickname you give %s.", dc.display_name(u)), .Normal, 14, 18, cast(T)("--text-default"));
		spacer(.Y, 16);
		text_row("lbl", "Friend Nickname", .Semibold, 14, 18, cast(T)("--text-strong"));
	}
	spacer(.Y, 8);
	save := false;
	ir := row("inrow");
	ir.semantic_size = .[ui.pct(1), ui.px(40)];
	if ui.parent(ir) {
		spacer(.X, PAD);
		field := row("input", .{.Draw_Background, .Draw_Border, .Clickable});
		field.semantic_size = .[ui.fill(), ui.px(40)];
		field.style.bg = cast(T)("--input-background-default");
		field.style.border_color = cast(T)("--input-border-active");
		field.style.border = 1;
		field.style.radius = 8;
		field.hover_cursor = .IBeam;
		if ui.parent(field) {
			spacer(.X, 12);
			res := text_field("field", *fnick.ed, dc.display_name(u), true, 16, 20, 10, cast(T)("--input-placeholder-text-default"));
			{ t := ui.editor_text(*fnick.ed);
			if utf8.rune_count(t) > dc.FRIEND_NICKNAME_MAX {
				n, cut := 0, 0;
				for _, i: t {
					if n == dc.FRIEND_NICKNAME_MAX {cut = i; break;}
					n += 1;
				}
				ui.editor_set_text(*fnick.ed, clone(sub(t, 0, cut), temp));
			} }
			if res == .Submit { save = true; }
			if res == .Escape { fnick.user = 0; }
			spacer(.X, 12);
		}
		spacer(.X, PAD);
	}
	spacer(.Y, PAD);
	btns := row("btns", .{.Draw_Background});
	btns.semantic_size = .[ui.pct(1), ui.px(70)];
	btns.style.bg = cast(T)("--background-base-lower");
	btns.style.radius = .{0, 0, 12, 12};
	btns.style.child_gap = 8;
	if ui.parent(btns) {
		spacer(.X, PAD - 8);
		// like the client: Reset only clears the field; Save sends {"nickname":null}
		if had && button("Reset Friend Nickname##reset", 170, .{}, cast(T)("--background-mod-normal"), cast(T)("--text-link")) { ui.editor_set_text(*fnick.ed, ""); }
		filler(.X);
		if button("Cancel##cancel", 96, cast(T)("--background-mod-normal"), cast(T)("--background-mod-strong"), cast(T)("--text-strong")) { fnick.user = 0; }
		if button("Save##save", 96, cast(T)("--background-brand"), with_alpha(cast(T)("--background-brand"), 0.85), .{1, 1, 1, 1}) { save = true; }
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

