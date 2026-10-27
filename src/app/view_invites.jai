// Invite links in messages: a card under the message (the client's invite embed) with the
// guild's icon, name, counts and age, and "Join Server" / "Go to Server". Clicking an invite
// link in the text does the same as the button instead of opening the browser.

INVITE_HOSTS :: string.["discord.gg/", "discord.com/invite/", "discordapp.com/invite/"];

// invite_codes: the distinct invite codes linked in a message's text (temp).
invite_codes :: (content: string) -> []string {
	out: [..]string;
	out.allocator = temp;
	for word: split(content, " \n\t<>()",, temp) {
		for INVITE_HOSTS if contains(word, it) {
			code := invite_link_code(word);
			if code != "" array_add_if_unique(*out, code);
			break;
		}
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

is_invite_link :: (url: string) -> bool { return invite_link_code(url) != ""; }

// invite_follow: the card's button or a click on the link. A guild we're in opens at the
// invite's channel; otherwise the invite is accepted and the library opens it on GUILD_CREATE.
invite_follow :: (code: string) {
	if app.client == null || !net_action() return;
	p := dc.invite_preview(app.client, code);
	if p.state != .Ok return;
	if dc.guild_get(store(), p.guild_id) {
		ch := dc.channel_get(store(), p.channel_id);
		if ch && ch.guild_id == p.guild_id select_channel(p.guild_id, p.channel_id); else select_guild(p.guild_id);
		return;
	}
	dc.join_invite_preview(app.client, code);
}

invite_cards_view :: (m: *dc.Message) {
	if app.client == null || (m.flags & 4) return; // SUPPRESS_EMBEDS
	for code: invite_codes(m.content) invite_card(tprint("invite%", it_index), code, dc.invite_preview(app.client, code));
}

invite_card :: (id: string, code: string, p: dc.Invite_Preview) {
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
	member := p.state == .Ok && dc.guild_get(store(), p.guild_id) != null;
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
		{ ui.parent(frame); defer ui.pop_parent();
			gi := ui.box("icon", .Draw_Background | .Draw_Text | .Floating_X | .Floating_Y);
			gi.semantic_size = .[ui.px(ICON), ui.px(ICON)];
			gi.fixed_pos = .{4, 4};
			gi.style.radius = all4(16);
			gi.style.bg = T("--background-mod-subtle");
			gi.style.text_color = T("--text-default");
			gi.style.text_align = .Center;
			gi.style.font = F(.Medium);
			gi.style.font_size = 20;
			gi.text = guild_initials(p.name);
			if p.icon != "" {
				set_remote_image(gi, dc.guild_icon_url(p.guild_id, p.icon, 128));
				gi.text = "";
			}
		}
	}
	body := row("body");
	body.semantic_size = .[ui.pct(1), ui.children()];
	{ ui.parent(body); defer ui.pop_parent();
		spacer(.X, 16);
		col := ui.box("col");
		col.semantic_size = .[ui.fill(), ui.children()];
		col.layout_axis = .Y;
		{ ui.parent(col); defer ui.pop_parent();
			if p.state == {
			case .Loading;
				spacer(.Y, 16);
				label("Resolving invite…", .Medium, 14, T("--text-muted"), 18);
				spacer(.Y, 16);
				return;
			case .Failed;
				spacer(.Y, 16);
				label("Invalid Invite", .Semibold, 16, T("--text-strong"), 20);
				spacer(.Y, 4);
				label("This invite may be expired, or you might not have permission to join.", .Normal, 14, T("--text-muted"), 18);
				spacer(.Y, 16);
				return;
			}
			spacer(.Y, ICON / 2 + 12);
			label(p.name, .Semibold, 20, T("--text-strong"), 24);
			spacer(.Y, 4);
			counts := row("counts");
			counts.semantic_size = .[ui.children(), ui.px(18)];
			{ ui.parent(counts); defer ui.pop_parent();
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
			spacer(.Y, 2);
			t := to_calendar(dc.UNIX_EPOCH + milliseconds_to_apollo(dc.snowflake_time_ms(p.guild_id)));
			label(tprint("Est. % %", string.["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"][t.month_starting_at_0], t.year), .Normal, 14, T("--text-muted"), 18);
			spacer(.Y, 16);
			b := row("join", .Clickable | .Draw_Background | .Hot_Animation);
			b.semantic_size = .[ui.pct(1), ui.px(40)];
			b.style.radius = all4(8);
			b.style.bg = T("--status-positive-background");
			b.style.bg_hot = with_alpha(b.style.bg, 0.85);
			b.hover_cursor = .Pointer;
			{ ui.parent(b); defer ui.pop_parent();
				text := ifx member then "Go to Server" else ifx p.joining then "Joining…" else "Join Server";
				filler(.X);
				label(text, .Medium, 14, T("--status-positive-text"), 18);
				filler(.X);
			}
			if ui.signal(b).clicked && !p.joining invite_follow(code);
			spacer(.Y, 16);
		}
		spacer(.X, 16);
	}
}
