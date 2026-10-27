// Invite links in messages: a card under the message (the client's invite embed) with the
// guild's icon, name, counts and age, and "Join Server" / "Go to Server". Clicking an invite
// link in the text opens the accept modal (or the guild, when we're in it).
// Errors stay with their widget, as in the client: a failed accept turns the card into its
// "You received an invite, but..." view, and the modal shows the reason above its button.

INVITE_HOSTS :: string.["discord.gg/", "discord.com/invite/", "discordapp.com/invite/"];

// invite_codes: the distinct invite codes linked in a message's text (temp).
invite_codes :: (content: string) -> []string {
	out: [..]string;
	out.allocator = temp;
	rest := content;
	while rest {
		i := find_index_of_any_from_left(rest, " \n\t<>()");
		word := ifx i < 0 then rest else slice(rest, 0, i);
		code := invite_link_code(word);
		if code != "" array_add_if_unique(*out, code);
		if i < 0 break;
		advance(*rest, i + 1);
	}
	return out;
}

// invite_link_code: the code of an invite URL ("" when it isn't one).
invite_link_code :: (url: string) -> string {
	for INVITE_HOSTS {
		i := find_index_from_left(url, it);
		if i >= 0 return dc.invite_code_from_input(slice(url, i, url.count - i));
	}
	return "";
}

invite_preview :: (code: string, message_id: dc.Snowflake) -> dc.Invite_Preview {
	return dc.invite_preview(app.client, code, message_id, store().guild_order);
}

is_member_of :: (p: dc.Invite_Preview) -> bool { return p.guild_id != 0 && dc.guild_get(store(), p.guild_id) != null; }

// go_to_invite: transitionToInvite: the invite's channel, else the guild.
go_to_invite :: (p: dc.Invite_Preview) {
	ch := dc.channel_get(store(), p.channel_id);
	if ch && ch.guild_id == p.guild_id select_channel(p.guild_id, p.channel_id); else select_guild(p.guild_id);
}

// A click on an invite link (markdown link handler): a guild we're in opens directly,
// anything else (to join, unresolved, expired) opens the invite modal.
invite_link_clicked :: (code: string, message_id: dc.Snowflake) {
	if app.client == null || !net_action() return;
	p := invite_preview(code, message_id);
	if p.state == .Ok && is_member_of(p) {
		go_to_invite(p);
		return;
	}
	free(iam.code);
	free(iam.instance);
	iam.code = copy_string(code);
	iam.instance = copy_string(dc.invite_instance_id(message_id, code));
	iam.joined = false;
}

invite_cards_view :: (m: *dc.Message) {
	if app.client == null || (m.flags & 4) return; // SUPPRESS_EMBEDS
	for code: invite_codes(m.content) invite_card(tprint("invite%", it_index), code, invite_preview(code, m.id), m);
}

invite_card :: (id: string, code: string, p: dc.Invite_Preview, m: *dc.Message) {
	W :: 432.0;
	BANNER :: 64.0;
	ICON :: 64.0;
	spacer(.Y, 4);
	card := ui.box(id, .Draw_Background | .Draw_Border);
	card.semantic_size = .[ui.px(W), ui.children()];
	card.layout_axis = .Y;
	card.style.bg = T("--embed-background");
	card.style.border_color = T("--border-subtle");
	card.style.border = 1;
	card.style.radius = all4(12);
	ui.parent(card); defer ui.pop_parent();
	if p.state == .Ok {
		banner := ui.box("banner", .Draw_Background);
		banner.semantic_size = .[ui.pct(1), ui.px(BANNER)];
		banner.style.bg = T("--background-mod-strong");
		banner.style.radius = .[12, 12, 0, 0];
		// the icon overlaps the banner's bottom edge, framed in the card's colour
		frame := ui.box("iconframe", .Draw_Background | .Floating_X | .Floating_Y);
		frame.semantic_size = .[ui.px(ICON + 8), ui.px(ICON + 8)];
		frame.fixed_pos = .{12, BANNER - ICON / 2 - 4};
		frame.style.bg = T("--embed-background");
		frame.style.radius = all4(20);
		{ ui.parent(frame); defer ui.pop_parent(); guild_tile(p, ICON, .{4, 4}); }
	}
	body := row("body");
	body.semantic_size = .[ui.pct(1), ui.children()];
	{ ui.parent(body); defer ui.pop_parent();
		spacer(.X, 16);
		col := ui.box("col");
		col.semantic_size = .[ui.fill(), ui.children()];
		col.layout_axis = .Y;
		{ ui.parent(col); defer ui.pop_parent();
			mine := m.author_id == store().me;
			if p.state != .Ok {
				// header, then a title and line (the client's oU / di / oK views)
				header, title, text: string;
				if p.state == {
				case .Loading; header = "Resolving Invite";
				case .Error;
					header = ifx mine then "You sent an invite, but..." else "You received an invite, but...";
					title, text = invite_error_info(p);
				case;
					header = ifx mine then "You sent an invite, but" else "You've been invited, but";
					title = "Invalid Invite";
					text = ifx mine then "Try sending a new invite" else ifx p.state == .Banned then "Uh-oh. Looks like you've been banned." else "Ask for a new invite";
				}
				spacer(.Y, 16);
				label(header, .Medium, 14, T("--text-muted"), 18);
				if title != "" {
					spacer(.Y, 8);
					label(title, .Semibold, 16, T("--text-feedback-critical"), 20);
					spacer(.Y, 2);
					set_para("text", text, .Normal, 14, 18, T("--text-muted"));
				}
				spacer(.Y, 16);
				return;
			}
			spacer(.Y, ICON / 2 + 12);
			label(p.name, .Semibold, 20, T("--text-strong"), 24);
			spacer(.Y, 4);
			invite_counts(p);
			spacer(.Y, 2);
			t := to_calendar(dc.UNIX_EPOCH + milliseconds_to_apollo(dc.snowflake_time_ms(p.guild_id)));
			label(tprint("Est. % %", string.["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"][t.month_starting_at_0], t.year), .Normal, 14, T("--text-muted"), 18);
			spacer(.Y, 16);
			member := is_member_of(p);
			if wide_button("join", ifx member then "Go to Server" else ifx p.joining then "Joining…" else "Join Server", T("--status-positive-background")) && !p.joining && net_action() {
				if member go_to_invite(p);
				else dc.join_invite_preview(app.client, code, dc.INVITE_LOC_EMBED, dc.invite_instance_id(m.id, code));
			}
			spacer(.Y, 16);
		}
		spacer(.X, 16);
	}
}

// The failed accept's title and line: module 4274 `g` (title + description) for the codes it
// knows, else "Invalid Invite" and the server's message.
invite_error_info :: (p: dc.Invite_Preview) -> title: string, text: string {
	if p.error_code == {
	case 30001;
		u := dc.user_get(store(), store().me);
		return tprint("You are at the % server limit.", ifx u && u.premium_type > 0 then 200 else 100), "You must leave a server first to join.";
	case 30019; return "This server is currently full.", "Please try again later.";
	case 400002; return "This server's features are limited", "Please try again later.";
	}
	return "Invalid Invite", p.error;
}

// The accept modal's line under a failed accept: module 4274 `d`.
invite_modal_error :: (code: int) -> string {
	if code == {
	case 30001; return "You must leave a server first to join.";
	case 30019; return "This server is currently full. Please try again later.";
	case 50095; return "This server is not available in your location.";
	case 40069; return "Invites are currently paused for this server. Please try again later.";
	}
	return "Unable to accept invite";
}

guild_tile :: (p: dc.Invite_Preview, size: float32, pos: Vector2) {
	gi := ui.box("icon", .Draw_Background | .Draw_Text | .Floating_X | .Floating_Y);
	gi.semantic_size = .[ui.px(size), ui.px(size)];
	gi.fixed_pos = pos;
	gi.style.radius = all4(size / 4);
	gi.style.bg = T("--background-mod-subtle");
	gi.style.text_color = T("--text-default");
	gi.style.text_align = .Center;
	gi.style.font = F(.Medium);
	gi.style.font_size = size * 0.3;
	gi.text = guild_initials(p.name);
	if p.icon != "" {
		set_remote_image(gi, dc.guild_icon_url(p.guild_id, p.icon, 128));
		gi.text = "";
	}
}

invite_counts :: (p: dc.Invite_Preview) {
	counts := row("counts");
	counts.semantic_size = .[ui.children(), ui.px(18)];
	ui.parent(counts); defer ui.pop_parent();
	dot :: (id: string, c: ui.Color) {
		d := ui.box(id, .Draw_Background);
		d.semantic_size = .[ui.px(8), ui.px(8)];
		d.style.bg = c;
		d.style.radius = all4(4);
		spacer(.X, 4);
	}
	dot("on", T("--status-positive"));
	label(tprint("% Online", p.online), .Normal, 14, T("--text-muted"), 18);
	spacer(.X, 12);
	dot("all", T("--text-muted"));
	label(tprint("% Member%", p.members, ifx p.members == 1 then "" else "s"), .Normal, 14, T("--text-muted"), 18);
}

wide_button :: (id: string, text: string, bg: ui.Color) -> bool {
	b := row(id, .Clickable | .Draw_Background | .Hot_Animation);
	b.semantic_size = .[ui.pct(1), ui.px(40)];
	b.style.radius = all4(8);
	b.style.bg = bg;
	b.style.bg_hot = with_alpha(bg, 0.85);
	b.hover_cursor = .Pointer;
	{ ui.parent(b); defer ui.pop_parent();
		filler(.X);
		label(text, .Medium, 14, .{1, 1, 1, 1}, 18);
		filler(.X);
	}
	return ui.signal(b).clicked;
}

// ---- The invite modal (INVITE_MODAL_OPEN from a link click) ----

iam: struct {
	code: string; // heap; "" = closed
	instance: string; // invite_instance_id of the clicked link
	joined: bool; // accepted from the modal: closes when the guild arrives
};

invite_accept_open :: () -> bool { return iam.code != ""; }

invite_accept_close :: (dismissed: bool, p: dc.Invite_Preview) {
	// onCloseRequest (Escape, the X, outside) tracks the dismissal; closing after a join doesn't
	if dismissed && app.client != null {
		dc.analytics_track(app.client, "invite_accept_dismissed", tprint("\"invite_code\":%,\"guild_id\":%", dc.json_quote(iam.code), ifx p.guild_id then tprint("\"%\"", p.guild_id) else "null"));
	}
	free(iam.code);
	free(iam.instance);
	iam = .{};
}

// Per frame (overlay pass).
invite_accept_overlay :: () {
	if !invite_accept_open() return;
	if app.client == null {
		invite_accept_close(false, .{});
		return;
	}
	p := invite_preview(iam.code, 0);
	if is_member_of(p) {
		// joined here (the library opens the channel on GUILD_CREATE), or already a member
		if !iam.joined go_to_invite(p);
		invite_accept_close(false, p);
		return;
	}
	scrim := ui.box("iam_scrim", .Draw_Background | .Clickable | .Floating_X | .Floating_Y | .Overlay);
	scrim.semantic_size = .[ui.px(app.ui.window.x), ui.px(app.ui.window.y)];
	scrim.style.bg = .{0, 0, 0, 0.7};
	if ui.signal(scrim).clicked {
		invite_accept_close(true, p);
		return;
	}
	for * e: app.ui.events if e.kind == .Key_Down && e.key == .Escape && !e.consumed {
		e.consumed = true;
		invite_accept_close(true, p);
		return;
	}
	W :: 440.0;
	d := ui.box("iam", .Draw_Background | .Draw_Border | .Floating_X | .Floating_Y | .Overlay | .Clickable);
	d.semantic_size = .[ui.px(W), ui.children()];
	d.fixed_pos = .{(app.ui.window.x - W) / 2, max((app.ui.window.y - (d.rect.y1 - d.rect.y0)) / 2, 16)};
	d.style.bg = T("--modal-background");
	d.style.border_color = T("--border-subtle");
	d.style.border = 1;
	d.style.radius = all4(12);
	d.layout_axis = .Y;
	ui.signal(d);
	ui.parent(d); defer ui.pop_parent();
	x := ui.box("close", .Clickable | .Floating_X | .Floating_Y);
	x.semantic_size = .[ui.px(24), ui.px(24)];
	x.fixed_pos = .{W - 16 - 24, 16};
	xs := ui.signal(x);
	set_icon(x, "x-large", ifx xs.hovering then T("--interactive-icon-hover") else T("--interactive-icon-default"));
	if xs.clicked {
		invite_accept_close(true, p);
		return;
	}
	body := row("body");
	body.semantic_size = .[ui.pct(1), ui.children()];
	ui.parent(body); defer ui.pop_parent();
	spacer(.X, 24);
	col := ui.box("col");
	col.semantic_size = .[ui.fill(), ui.children()];
	col.layout_axis = .Y;
	{ ui.parent(col); defer ui.pop_parent();
		spacer(.Y, 32);
		if p.state == .Loading || p.state == .Expired || p.state == .Banned {
			centered("title", ifx p.state == .Loading then "Resolving Invite" else "Invite Invalid", .Semibold, 24, 30, T("--text-strong"));
			if p.state != .Loading {
				spacer(.Y, 8);
				centered("text", ifx p.state == .Banned then "Uh-oh. Looks like you've been banned." else "This invite may be expired, or you might not have permission to join.", .Normal, 16, 20, T("--text-muted"));
				spacer(.Y, 24);
				if wide_button("ok", "Okay", T("--background-brand")) invite_accept_close(true, p);
			}
			spacer(.Y, 24);
			return;
		}
		tile := ui.box("tile");
		tile.semantic_size = .[ui.pct(1), ui.px(64)];
		{ ui.parent(tile); defer ui.pop_parent(); guild_tile(p, 64, .{(W - 48 - 64) / 2, 0}); }
		spacer(.Y, 16);
		centered("sub", "You've been invited to join", .Normal, 16, 20, T("--text-muted"));
		spacer(.Y, 4);
		centered("name", p.name, .Semibold, 24, 30, T("--text-strong"));
		spacer(.Y, 8);
		cr := row("countsrow");
		cr.semantic_size = .[ui.pct(1), ui.px(18)];
		{ ui.parent(cr); defer ui.pop_parent(); filler(.X); invite_counts(p); filler(.X); }
		spacer(.Y, 24);
		if p.state == .Error {
			// INVITE_MODAL_ERROR: the reason above the button
			centered("err", invite_modal_error(p.error_code), .Normal, 14, 18, T("--text-feedback-critical"));
			spacer(.Y, 8);
		}
		if wide_button("accept", ifx p.joining then "Joining…" else "Accept Invite", T("--background-brand")) && !p.joining && net_action() {
			iam.joined = true;
			dc.join_invite_preview(app.client, iam.code, dc.INVITE_LOC_MODAL, iam.instance);
		}
		spacer(.Y, 24);
	}
	spacer(.X, 24);
}
