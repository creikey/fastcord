Message_Actions :: struct {
	replying: dc.Snowflake; // message being replied to (composer bar)
	reply_mention: bool; // "@ ON" toggle
	parked_replies: Table(dc.Snowflake, Parked_Reply); // other channels' pending replies, by channel
	editing: dc.Snowflake; // message in inline edit mode
	edit_editor: ui.Editor;
	confirming: dc.Snowflake; // message of the confirmation modal (delete / pin / unpin)
	confirm: Confirm;
	menu_msg: dc.Snowflake; // context menu target
	// A search, pins or inbox card's message, for find_message (not in the chat's list). Only read when
	// loose_id matches: the card's list may since have been freed.
	loose: *dc.Message;
	loose_id: dc.Snowflake;
	menu_pos: ui.Vec2;
	menu_t: float32;
	menu_link: string; // the link right-clicked in the message (owned): the menu opens with Copy / Open Link
	hover_link: string; // the link under the mouse in a message, with the frame it was seen (owned)
	hover_link_frame: u64;
}

Parked_Reply :: struct {
	id: dc.Snowflake;
	mention: bool;
}

ma: Message_Actions;

// On a channel switch: park the open channel's pending reply and bring back the new one's.
replies_switch :: (from: dc.Snowflake, to: dc.Snowflake) {
	if ma.replying != 0 table_set(*ma.parked_replies, from, .{ma.replying, ma.reply_mention});
	else table_remove(*ma.parked_replies, from);
	_, r := table_find(*ma.parked_replies, to);
	ma.replying = r.id;
	ma.reply_mention = r.mention;
	table_remove(*ma.parked_replies, to);
}

mime_for :: (name: string) -> string {
	ext := name;
	dot := find_index_from_right(name, #char ".");
	if dot < 0 || find_index_from_left(name, #char "/", dot) >= 0 ext = "";
	else advance(*ext, dot);
	if to_lower_copy(ext,, temp) == {
	case ".png";
		return "image/png";
	case ".jpg"; #through; case ".jpeg";
		return "image/jpeg";
	case ".gif";
		return "image/gif";
	case ".webp";
		return "image/webp";
	case ".mp4";
		return "video/mp4";
	case ".mov";
		return "video/quicktime";
	case ".webm";
		return "video/webm";
	case ".mp3";
		return "audio/mpeg";
	case ".ogg";
		return "audio/ogg";
	case ".wav";
		return "audio/wav";
	case ".txt";
		return "text/plain";
	}
	return "application/octet-stream";
}

// Hover toolbar at the message's top-right: react, reply, (edit), more.
message_toolbar :: (m: *dc.Message) {
	s := store();
	own := can_edit(m);
	quick := quick_reactions();
	names: [..]string;
	names.allocator = temp;
	array_add(*names, "reaction", ifx own then "pencil" else "arrow-angle-left-up");
	if can_forward(m) array_add(*names, "arrow-angle-right-up");
	if can_thread_from(m) array_add(*names, "thread");
	array_add(*names, "more-horizontal");
	// Shift adds a red trash can that deletes without asking
	if (app.ui_mods & .Shift) && can_manage_message(m) && !m.pending array_add(*names, "trash");
	// official: 3px padding, 28px buttons, a 1px divider with 4px gaps after the quick reactions
	w := 2 * TOOLBAR_PAD + cast(float32) (quick.count + names.count) * TOOLBAR_BTN + (ifx quick then 9 else 0);
	bar := row("toolbar", .Draw_Background | .Draw_Border | .Draw_Shadow | .Floating_X | .Floating_Y | .Clickable);
	bar.semantic_size = .[ui.px(w), ui.px(TOOLBAR_BTN + 2 * TOOLBAR_PAD)];
	bar.fixed_pos = .{ui.top_parent().rect.x1 - ui.top_parent().rect.x0 - w - 14, -16};
	chat_toolbar = .{m.id, bar.rect};
	bar.style.bg = T("--background-surface-higher");
	bar.style.border_color = T("--border-subtle");
	bar.style.border = 1;
	bar.style.radius = all4(8);
	bar.style.shadow_color = .{0, 0, 0, 0.16};
	bar.style.shadow_blur = 4;
	ui.signal(bar);
	{ ui.parent(bar); defer ui.pop_parent();
		spacer(.X, TOOLBAR_PAD);
		for e, i: quick {
			b := ui.box(tprint("q%", i), .Clickable | .Draw_Background | .Hot_Animation);
			b.semantic_size = .[ui.px(TOOLBAR_BTN), ui.px(TOOLBAR_BTN)];
			b.style.radius = all4(6);
			b.style.bg_hot = T("--background-mod-subtle");
			b.layout_axis = .X;
			b.cross_align = .Center;
			if ui.signal(b).clicked react(m, e, "Message Hover Bar", toggle = true);
			{ ui.parent(b); defer ui.pop_parent();
				spacer(.X, 4);
				emoji_box("e", e, 20);
			}
		}
		if quick {
			spacer(.X, 4);
			d := ui.box("div", .Draw_Background);
			d.semantic_size = .[ui.px(1), ui.px(24)];
			d.style.bg = T("--border-subtle");
			spacer(.X, 4);
		}
		for name: names {
			b := ui.box(name, .Clickable | .Draw_Background | .Hot_Animation);
			b.semantic_size = .[ui.px(TOOLBAR_BTN), ui.px(TOOLBAR_BTN)];
			b.style.radius = all4(6);
			b.style.bg_hot = T("--background-mod-subtle");
			b.layout_axis = .X;
			b.cross_align = .Center;
			sig := ui.signal(b);
			{ ui.parent(b); defer ui.pop_parent();
				spacer(.X, 4);
				c := ifx sig.hovering then T("--interactive-icon-hover") else T("--interactive-icon-default");
				if name == "trash" c = T("--status-danger");
				icon("i", name, 20, c);
			}
			if name == "trash" && sig.hovering tooltip_below("Delete", b.rect);
			if name == "thread" && sig.hovering tooltip_below("Create Thread", b.rect);
			if name == "arrow-angle-right-up" && sig.hovering tooltip_below("Forward", b.rect);
			if sig.clicked {
				if name == {
				case "arrow-angle-left-up";
					start_reply(m);
				case "arrow-angle-right-up";
					forward_open(m);
				case "pencil";
					start_edit(m);
				case "more-horizontal";
					open_message_menu(m, .{b.rect.x0, b.rect.y1 + 4});
				case "reaction";
					app.reaction_target = m.id;
				case "trash";
					delete_now(m);
				case "thread";
					thread_from_message(m, header_thread_rect);
				}
			}
		}
	}
}

// A thread can start from this message: a guild text or announcement channel, no thread on it yet (HAS_THREAD).
can_thread_from :: (m: *dc.Message) -> bool {
	ch := dc.channel_get(store(), m.channel_id);
	return ch && ch.guild_id && !dc.is_thread(ch) && (ch.kind == .Guild_Text || ch.kind == .Guild_Announcement) && !(m.flags & 32) && !m.pending && can_create_thread(m.channel_id);
}

TOOLBAR_PAD :: 3;
TOOLBAR_BTN :: 28;

// The three most-used reactions (frecency), topped up with the client's defaults.
quick_reactions :: () -> []dc.Emoji {
	if app.client != null dc.frecency_reactions_shown(app.client);
	out: [..]dc.Emoji;
	out.allocator = temp;
	add :: (out: *[..]dc.Emoji, key: string) {
		if out.count >= 3 return;
		e: dc.Emoji;
		id, ok := dc.parse_u64(key);
		if ok {
			found := false;
			for * g: store().guilds {
				for g.emojis if it.id == id e, found = it, true;
			}
			if !found return;
		} else {
			idx := emoji_lookup_name(key);
			if idx < 0 return;
			e.name = emoji_db.emojis[idx].surr;
		}
		for out.* if it.id == e.id && it.name == e.name return;
		array_add(out, e);
	}
	for frec_top(frecency.reaction, 3) add(*out, it);
	for emoji_db.default_reaction add(*out, it);
	return out;
}

start_reply :: (m: *dc.Message) {
	ma.replying = m.id;
	ma.reply_mention = m.author_id != store().me; // no ping for your own message (CLIENT_RULES "Replies")
	app.ui.focus = 0;
}

// Yours, sent, not a forward, and a plain message or reply (type 0 or 19), not a system notice.
can_edit :: (m: *dc.Message) -> bool {
	return m.author_id == store().me && !m.forwarded && !m.pending && (m.kind == 0 || m.kind == 19) && !encrypted_packet(m.channel_id, m.content);
}

start_edit :: (m: *dc.Message) {
	edit_stash();
	ma.editing = m.id;
	ch := dc.channel_get(store(), m.channel_id);
	if edit_draft.msg == m.id ui.editor_set_text(*ma.edit_editor, edit_draft.text);
	else ui.editor_set_text(*ma.edit_editor, ifx ch then mentions_readable(m.content, ch) else m.content);
}

// An edit closed without saving (Escape, Cancel, editing another message) keeps its text: editing that
// message again brings it back, so no typing is lost.
edit_draft: struct { msg: dc.Snowflake; text: string; };

edit_stash :: () {
	if ma.editing == 0 return;
	m := find_message(ma.editing);
	text := ui.editor_text(*ma.edit_editor);
	ch := ifx m then dc.channel_get(store(), m.channel_id) else null;
	if m && text != (ifx ch then mentions_readable(m.content, ch) else m.content) {
		free(edit_draft.text);
		edit_draft.msg, edit_draft.text = m.id, copy_string(text);
	}
	ma.editing = 0;
}

// location: how it was opened, as message_popout_menu_opened_desktop names it
// ("right_click"); "" sends no telemetry (the "More" button's name is not known).
open_message_menu :: (m: *dc.Message, at: ui.Vec2, location := "") {
	ma.menu_msg = m.id;
	ma.menu_pos = at;
	ma.menu_t = 0;
	free(ma.menu_link);
	ma.menu_link = ifx ma.hover_link_frame + 1 >= app.frame then copy_string(ma.hover_link) else "";
	if app.client {
		ch := dc.channel_get(store(), m.channel_id);
		gid := ifx ch then ch.guild_id else 0;
		if location dc.message_menu_opened(app.client, gid, m.channel_id, m.id, location);
		else dc.open_message_context_menu(app.client, gid);
	}
}
// react: add a reaction, or with toggle remove one we have (hover bar, reaction pills).
// The store shows it at once (dc.add_reaction predicts); location as the client reports it.
// Removing our own reaction (toggle) shows at once and holds the DELETE (undo.jai, no toast): adding it
// again within the window cancels the removal with nothing sent.
react :: (m: *dc.Message, e: dc.Emoji, location: string, toggle := false) {
	if !net_action() return;
	if toggle for m.reactions if it.me && dc.emoji_matches(it.emoji, e.id, e.name) {
		// pushed first: it copies the name, which the store frees with the reaction
		u := undo_push("", send_unreact, (u: *Undo) {
			if u.client dc.store_reaction(*u.client.store, u.b, u.a, .{id = u.c, name = u.s, animated = u.n != 0, available = true}, true, true, false);
		}, a = m.id, b = m.channel_id, c = e.id, s = e.name, t = location, n = xx e.animated);
		dc.store_reaction(store(), m.channel_id, m.id, .{id = u.c, name = u.s, animated = e.animated, available = true}, true, false, false);
		return;
	}
	for undos if it.send == send_unreact && it.a == m.id && dc.emoji_matches(.{id = it.c, name = it.s}, e.id, e.name) {
		undo_cancel(it);
		return;
	}
	dc.add_reaction(app.client, m.channel_id, m.id, e.name, e.id, location = location, animated = e.animated);
}

send_unreact :: (u: *Undo) { if u.client dc.remove_reaction(u.client, u.b, u.a, u.s, u.c, location = u.t); }

find_message :: (id: dc.Snowflake) -> *dc.Message {
	if id == 0 return null;
	s := store();
	l := table_find_pointer(*s.messages, app.view.channel);
	if l for * l.messages if it.id == id return it;
	if ma.loose_id == id return ma.loose;
	return null;
}

// Inline editor replacing the message body. Enter saves, Escape cancels.
edit_box :: (m: *dc.Message) {
	// official: same form as the composer (58px, 1px border), emoji button on the right
	box := row("editbox", .Draw_Background | .Draw_Border | .Clickable);
	box.semantic_size = .[ui.pct(1), ui.children()];
	box.style.bg = T("--chat-background-default");
	box.style.border_color = T("--border-subtle");
	box.style.border = 1;
	box.style.radius = all4(8);
	box.cross_align = .Start;
	res: ui.Edit_Result;
	ch := dc.channel_get(store(), m.channel_id);
	{ ui.parent(box); defer ui.pop_parent();
		spacer(.X, 16);
		// the open emoji picker has the keyboard (its search field)
		open := picker_is_open() && pk.mode == .Edit;
		// the composer's autocompletes, floating over the box and taking their keys first
		if ch {
			emoji_autocomplete(ch, *ma.edit_editor, !open);
			mention_autocomplete(ch, *ma.edit_editor, !open);
		}
		res = text_field("edit", *ma.edit_editor, "", !open, pad_y = (COMPOSER_H - MSG_LINE_H) / 2, markdown = true);
		if res == .Changed && ch emoji_autocomplete_close_colon(ch, *ma.edit_editor);
		emo := ui.box("emoji", .Clickable);
		emo.semantic_size = .[ui.px(20), ui.px(COMPOSER_H)];
		emo.layout_axis = .Y;
		esig := ui.signal(emo);
		{ ui.parent(emo); defer ui.pop_parent();
			spacer(.Y, (COMPOSER_H - 20) / 2);
			icon("i", "reaction", 20, ifx esig.hovering || open then T("--interactive-icon-hover") else T("--interactive-icon-default"));
		}
		if esig.clicked {
			if open picker_close();
			else picker_open(.Edit, .Emoji, m.channel_id, m.id, emo.rect);
		}
		spacer(.X, 10);
	}
	save, cancel := res == .Submit, res == .Escape;
	hint := row("edithint");
	hint.semantic_size = .[ui.pct(1), ui.px(22)];
	{ ui.parent(hint); defer ui.pop_parent();
		// one rich-text run so the spaces between the parts survive; "cancel" and "save" are spans 1 and 3
		h := ui.box("hint");
		h.semantic_size = .[ui.text_size(0, 0), ui.text_size()];
		h.style.line_height = 16;
		h.style.text_color = T("--text-default");
		spans := NewArray(4, ui.Span,, temp);
		spans[0] = .{text = "escape to ", font = F(.Normal), size = 12};
		spans[1] = .{text = "cancel", font = F(.Normal), size = 12, color = T("--text-link")};
		spans[2] = .{text = " • enter to ", font = F(.Normal), size = 12};
		spans[3] = .{text = "save", font = F(.Normal), size = 12, color = T("--text-link")};
		ui.set_spans(h, spans);
		if !app.ui.overlay_under_mouse {
			over := ui.span_at(h.prev_layout, app.ui.mouse);
			if over == 1 || over == 3 app.ui.cursor = .Pointer;
			for * e: app.ui.events {
				if e.consumed || e.kind != .Mouse_Down || e.button != .Left continue;
				si := ui.span_at(h.prev_layout, e.pos);
				if si == 1 cancel = true;
				if si == 3 save = true;
				if si == 1 || si == 3 e.consumed = true;
			}
		}
	}
	if save {
		text := trim(ui.editor_text(*ma.edit_editor), " \t\n\r\x0b\x0c");
		if text != "" && ch text = mentions_convert(emoji_convert_shortcodes(text, ch.id), ch);
		if text == "" {
			delete_now(m);
		} else if text != m.content && req_begin(EDIT_REQ) {
			dc.edit_message(app.client, m.channel_id, m.id, text);
			req_end();
		}
		// the typed text stays a draft until the edit lands: a failed one reopens with it (edit_result)
		edit_stash();
	} else if cancel {
		edit_stash();
	}
}

// The referenced message preview above a reply: curved spine, small avatar, name, one line of content.
// An app command's reply: the reply spine, then "<avatar> name used /command" (a context-menu
// command without the slash), as the client's interaction header.
command_used_line :: (m: *dc.Message) {
	r := row("cmdused");
	r.semantic_size = .[ui.pct(1), ui.px(22)];
	ui.parent(r); defer ui.pop_parent();
	clip := ui.box("spineclip", .Clip | .Floating_X | .Floating_Y);
	clip.semantic_size = .[ui.px(33), ui.px(12)];
	clip.fixed_pos = .{-MSG_GUTTER + 36, 8};
	{ ui.parent(clip); defer ui.pop_parent();
		spine := ui.box("spine", .Draw_Border | .Floating_X | .Floating_Y);
		spine.semantic_size = .[ui.px(33 + 8), ui.px(12 + 8)];
		spine.style.border = 2;
		spine.style.border_color = T("--border-strong");
		spine.style.radius = .[6, 0, 0, 0];
	}
	avatar_box("av", m.command_user, 16);
	spacer(.X, 4);
	n := label(name_in(m.command_user, m.channel_id), .Medium, 14, T("--text-muted"), 18);
	n.flags |= .Clickable;
	if ui.signal(n).clicked open_profile(m.command_user, n.rect);
	spacer(.X, 4);
	label("used", .Normal, 14, T("--text-muted"), 18);
	spacer(.X, 4);
	if m.command_name label(ifx m.kind == 23 then m.command_name else tprint("/%", m.command_name), .Medium, 14, T("--text-link"), 18);
	else label("a command", .Normal, 14, T("--text-muted"), 18);
}

reply_preview :: (m: *dc.Message) {
	s := store();
	ref := find_message(m.referenced_id);
	r := row("replyref", ifx ref then ui.Box_Flags.Clickable else 0);
	r.semantic_size = .[ui.pct(1), ui.px(22)];
	if ref {
		r.hover_cursor = .Pointer;
		if ui.signal(r).clicked jump_to_message(ref.channel_id, ref.id);
	}
	{ ui.parent(r); defer ui.pop_parent();
		// the spine: only the top and left edges of a rounded box (clipped)
		clip := ui.box("spineclip", .Clip | .Floating_X | .Floating_Y);
		clip.semantic_size = .[ui.px(33), ui.px(12)];
		clip.fixed_pos = .{-MSG_GUTTER + 36, 8};
		{ ui.parent(clip); defer ui.pop_parent();
			spine := ui.box("spine", .Draw_Border | .Floating_X | .Floating_Y);
			spine.semantic_size = .[ui.px(33 + 8), ui.px(12 + 8)];
			spine.style.border = 2;
			spine.style.border_color = T("--border-strong");
			spine.style.radius = .[6, 0, 0, 0];
		}
		if ref == null {
			label("Original message was deleted", .Normal, 14, T("--text-muted"), 18);
			return;
		}
		hide := hidden_kind(ref);
		if hide != "" {
			label(ifx hide == "blocked" then "Blocked message" else "Ignored message", .Normal, 14, T("--text-muted"), 18);
			return;
		}
		avatar_box("av", ref.author_id, 16);
		spacer(.X, 4);
		name := author_name(ref);
		// "@" only when the reply pinged the author; role color, else muted
		pinged := false;
		for id: m.mentions { if id == ref.author_id { pinged = true; } }
		name_color := T("--text-muted");
		ch := dc.channel_get(s, ref.channel_id);
		if ch && ch.guild_id {
			c, ok := member_color(ch.guild_id, ref.author_id);
			if ok name_color = c;
		}
		shown := ifx pinged then tprint("@%", name) else name;
		nb := label(shown, .Medium, 14, name_color, 18);
		nb.semantic_size[ui.Axis.X] = ui.text_size();
		spacer(.X, 4);
		content := first_line(shown_text(ref.id, ref.channel_id, ref.content));
		if content == "" && ref.attachments content = "Click to see attachment";
		// Last frame's row width; the avatar, name and spacers are fixed, so the rest is the content's.
		avail := r.rect.x1 - r.rect.x0 - 16 - 4 - ui.layout_text(F(.Medium), 14, shown, -1).width - 4;
		if r.rect.x1 > r.rect.x0 content = ellipsize(content, .Normal, 14, max(avail, 0));
		c := label(content, .Normal, 14, T("--text-default"), 18);
		c.flags |= .Clip;
		c.semantic_size[ui.Axis.X] = ui.text_size(0, 0);
	}
}

// Bar above the composer while replying.
reply_bar :: () {
	m := find_message(ma.replying);
	if m == null {
		ma.replying = 0;
		return;
	}
	s := store();
	// official: inside the composer form, 3px + 32px row, then a divider
	spacer(.Y, 3);
	bar := row("replybar");
	bar.semantic_size = .[ui.pct(1), ui.px(32)];
	{ ui.parent(bar); defer ui.pop_parent();
		spacer(.X, 16);
		// "Replying to <name>" goes to the message (the official bar's transitionTo its link)
		who := row("replyto", .Clickable);
		who.semantic_size = .[ui.children(), ui.px(32)];
		if ui.signal(who).clicked jump_to_message(m.channel_id, m.id);
		{ ui.parent(who); defer ui.pop_parent();
			label("Replying to", .Normal, 14, T("--text-default"), 18);
			spacer(.X, 4);
			label(author_name(m), .Semibold, 14, T("--text-default"), 18);
		}
		filler(.X);
		if m.author_id != s.me {
			at := ui.box(ifx ma.reply_mention then "@ ON##at" else "@ OFF##at", .Clickable | .Draw_Text);
			at.semantic_size = .[ui.text_size(), ui.px(18)];
			at.style.font = F(.Bold);
			at.style.font_size = 14;
			at.style.text_color = ifx ma.reply_mention then T("--text-brand") else T("--text-muted");
			if ui.signal(at).clicked ma.reply_mention = !ma.reply_mention;
			spacer(.X, 12);
		}
		x := ui.box("close", .Clickable);
		x.semantic_size = .[ui.px(16), ui.px(16)];
		xs := ui.signal(x); // once: a second signal() finds the click already consumed
		set_icon(x, "circle-x", ifx xs.hovering then T("--interactive-icon-hover") else T("--interactive-icon-default"));
		if xs.clicked ma.replying = 0;
		spacer(.X, 17);
	}
	sep := ui.box("replysep", .Draw_Background);
	sep.semantic_size = .[ui.pct(1), ui.px(1)];
	sep.style.bg = T("--border-subtle");
}

// Send what's in the composer: text, reply, staged files.
composer_send :: (ch: *dc.Channel, text: string) -> bool {
	if ma.replying != 0 && encrypting(ch) { toast_show("Replies can't be sent encrypted yet.", false); return false; } // until E2E 7
	if !net_action() return false;
	atts, ready := attachments_for_send(ch.id);
	if !ready { return false; } // a file is still being read
	if text == "" && !atts return false;
	opts: dc.Send_Options;
	// "@silent " in front sends it without a sound or push for anyone; the prefix itself isn't sent.
	body := text;
	if begins_with(body, "@silent ") || body == "@silent" {
		body = trim_left(advance(body, "@silent".count));
		opts.flags |= SUPPRESS_NOTIFICATIONS;
		if body == "" && !atts return false;
	}
	if encrypting(ch) {
		if !encrypted_send(ch, body, atts.count > 0, opts.flags != 0) return false;
		ma.replying = 0;
		return true;
	}
	if ma.replying != 0 {
		opts.reply_to = ma.replying;
		opts.reply_guild_id = ch.guild_id;
		opts.mention_replied = ma.reply_mention;
	}
	opts.attachments = atts;
	nonce := dc.send_message(app.client, ch.id, body, opts);
	if slowmode_secs(ch) table_set(*slow_until, ch.id, wall_ms() + slowmode_secs(ch) * 1000);
	ma.replying = 0;
	attachments_sent(ch.id, ifx atts then nonce else 0);
	return true;
}

// Context menu (right click / "More"): quick reactions, add reaction, edit, reply, copy text, copy link, delete.
MENU_W :: 222;
MENU_PAD :: 8;
MENU_ROW_H :: 36;
MENU_SEP_H :: 17;
MENU_QUICK :: 44;
message_menu :: () {
	m := find_message(ma.menu_msg);
	if m == null {
		ma.menu_msg = 0;
		message_menu_gone();
		return;
	}
	s := store();
	own := m.author_id == s.me;
	scrim := ui.box("menu_scrim", .Clickable | .Floating_X | .Floating_Y | .Overlay);
	scrim.semantic_size = .[ui.px(app.ui.window.x), ui.px(app.ui.window.y)];
	if ui.signal(scrim).pressed {
		ma.menu_msg = 0;
		message_menu_gone();
		return;
	}
	ui.animate(*ma.menu_t, 1, 30);
	Item :: struct {
		label: string;
		icon: string;
		danger: bool;
		sub: bool; // has a submenu chevron
		sep: bool; // divider above
	}
	items: [..]Item;
	items.allocator = temp;
	// official (MessageContextMenu): with text selected, "Copy" heads the menu and the quick reactions go
	sel := ui.has_selection();
	// a right-clicked link: its native items first (the client's copy-native-link / open-native-link)
	if ma.menu_link array_add(*items, .{label = "Copy Link", icon = "link"}, .{label = "Open Link", icon = "window-launch"});
	if sel array_add(*items, .{label = "Copy", icon = "copy", sep = ma.menu_link != ""});
	array_add(*items, .{label = "Add Reaction", icon = "reaction", sub = true, sep = sel || ma.menu_link != ""});
	if m.reactions array_add(*items, .{label = "View Reactions", icon = "reaction"});
	// a card outside the chat (search, pins) has no inline editor or composer to reply from
	in_chat := m != ma.loose;
	if in_chat && can_edit(m) array_add(*items, .{label = "Edit Message", icon = "pencil", sep = true});
	if in_chat array_add(*items, .{label = "Reply", icon = "arrow-angle-left-up", sep = !own});
	if can_forward(m) array_add(*items, .{label = "Forward", icon = "arrow-angle-right-up", sep = !in_chat});
	if in_chat && can_thread_from(m) array_add(*items, .{label = "Create Thread", icon = "thread"});
	if can_publish(m) array_add(*items, .{label = "Publish", icon = "announcements"});
	if m.poll && m.author_id == s.me && !m.poll.finalized array_add(*items, .{label = "End Poll Now", icon = "clock"});
	// official group order: Copy Text, Pin / Unpin Message, Apps, Mark Unread, Copy Message Link
	array_add(*items, .{label = "Copy Text", icon = "copy", sep = true});
	if dc.can_pin_message(s, m) array_add(*items, .{label = ifx m.pinned then "Unpin Message" else "Pin Message", icon = "pin"});
	array_add(*items, .{label = "Mark Unread", icon = "chat-mark-unread"}, .{label = "Copy Message Link", icon = "link"});
	// MessageContextMenu's last group: Remove All Reactions (MANAGE_MESSAGES in a server channel), then Delete
	ch := dc.channel_get(s, m.channel_id);
	remove_all := m.reactions && ch && ch.guild_id && (dc.channel_permissions(s, ch.id) & dc.PERM_MANAGE_MESSAGES);
	if remove_all array_add(*items, .{label = "Remove All Reactions", icon = "reaction", sep = true});
	if can_manage_message(m) array_add(*items, .{label = "Delete Message", icon = "trash", danger = true, sep = !remove_all});
	if s.settings.developer_mode array_add(*items, .{label = "Copy Message ID", icon = "id", sep = true});
	quick := ifx sel then .[] else quick_reactions();
	// official: 222 wide, 8px padding, 44px quick-reaction squares, 36px rows, 17px dividers
	h := 2 * MENU_PAD + 2 + cast(float32) items.count * MENU_ROW_H + (ifx quick then MENU_QUICK + 8 else 0);
	for items if it.sep h += MENU_SEP_H;
	p := ma.menu_pos;
	if p.y + h > app.ui.window.y - 8 p.y = app.ui.window.y - 8 - h;
	if p.x + MENU_W > app.ui.window.x - 8 p.x = app.ui.window.x - 8 - MENU_W;
	menu := ui.box("menu", .Draw_Background | .Draw_Border | .Draw_Shadow | .Floating_X | .Floating_Y | .Overlay | .Clickable);
	menu.semantic_size = .[ui.px(MENU_W), ui.px(h)];
	menu.fixed_pos = p;
	menu.opacity = ma.menu_t;
	menu.layout_axis = .Y;
	menu.style.bg = T("--background-surface-higher");
	menu.style.border_color = T("--border-subtle");
	menu.style.border = 1;
	menu.style.radius = all4(8);
	menu.style.shadow_color = .{0, 0, 0, 0.24};
	menu.style.shadow_blur = 16;
	menu.style.shadow_offset = .{0, 8};
	ui.signal(menu);
	{ ui.parent(menu); defer ui.pop_parent();
		spacer(.Y, MENU_PAD + 1);
		if quick {
			qr := row("quick");
			qr.semantic_size = .[ui.pct(1), ui.px(MENU_QUICK)];
			{ ui.parent(qr); defer ui.pop_parent();
				spacer(.X, MENU_PAD + 1 + 8);
				for e, i: quick {
					b := ui.box(tprint("q%", i), .Clickable | .Draw_Background | .Hot_Animation);
					b.semantic_size = .[ui.px(MENU_QUICK), ui.px(MENU_QUICK)];
					b.style.radius = all4(8);
					b.style.bg = T("--background-mod-subtle");
					b.style.bg_hot = T("--background-mod-normal");
					b.layout_axis = .X;
					b.cross_align = .Center;
					if ui.signal(b).clicked {
						if app.client dc.message_menu_item_clicked(app.client);
						react(m, e, "Message Context Menu");
						ma.menu_msg = 0;
					}
					{ ui.parent(b); defer ui.pop_parent();
						spacer(.X, (MENU_QUICK - 20) / 2);
						emoji_box("e", e, 20);
					}
					spacer(.X, 4);
				}
			}
			spacer(.Y, 8);
		}
		for it_: items {
			if it_.sep {
				sr := row(tprint("sep_%", it_.label));
				sr.semantic_size = .[ui.pct(1), ui.px(MENU_SEP_H)];
				{ ui.parent(sr); defer ui.pop_parent();
					spacer(.X, MENU_PAD + 1 + 8);
					l := ui.box("l", .Draw_Background);
					l.semantic_size = .[ui.fill(), ui.px(1)];
					l.style.bg = T("--border-subtle");
					spacer(.X, MENU_PAD + 1 + 8);
				}
			}
			outer := row(tprint("o_%", it_.label));
			outer.semantic_size = .[ui.pct(1), ui.px(MENU_ROW_H)];
			sig: ui.Signal;
			{ ui.parent(outer); defer ui.pop_parent();
				spacer(.X, MENU_PAD + 1);
				r := row(it_.label, .Clickable | .Draw_Background | .Hot_Animation);
				r.semantic_size = .[ui.fill(), ui.px(MENU_ROW_H)];
				r.style.radius = all4(4);
				r.style.bg_hot = ifx it_.danger then T("--status-danger") else T("--background-mod-normal");
				sig = ui.signal(r);
				{ ui.parent(r); defer ui.pop_parent();
					spacer(.X, 8);
					c := ifx it_.danger then T("--text-feedback-critical") else T("--interactive-text-default");
					if sig.hovering { c = ifx it_.danger then ui.Color.{1, 1, 1, 1} else T("--interactive-text-active"); }
					icon("ic", it_.icon, 20, c);
					spacer(.X, 8);
					label(it_.label, .Medium, 14, c, 18);
					filler(.X);
					if it_.sub icon("chev", "chevron-small-right", 16, c);
					spacer(.X, 8);
				}
				spacer(.X, MENU_PAD + 1);
			}
			if sig.clicked {
				if app.client != null dc.message_menu_item_clicked(app.client);
				if it_.label == {
				case "Copy";
					app.copy_selection = true; // after end(): the selection text needs this frame's boxes
				case "Copy Link";
					clipboard_set(ma.menu_link);
				case "Open Link";
					open_url(ma.menu_link);
				case "Add Reaction";
					app.reaction_target = m.id;
				case "Create Thread";
					thread_from_message(m, header_thread_rect);
				case "View Reactions";
					view_reactions.msg, view_reactions.sel = m.id, 0;
				case "Edit Message";
					start_edit(m);
				case "Reply";
					start_reply(m);
				case "Forward";
					forward_open(m);
				case "Copy Text";
					clipboard_set(shown_text(m.id, m.channel_id, m.content));
				case "Pin Message"; #through;
				case "Unpin Message";
					// Unpin is undone rather than confirmed; shift skips Pin's confirmation
					if m.pinned || (app.ui_mods & .Shift) pin_now(m, !m.pinned); else ma.confirming, ma.confirm = m.id, Confirm.Pin;
				case "Mark Unread";
					if net_action() dc.mark_unread(app.client, m.channel_id, m.id);
				case "Copy Message Link";
					ch := dc.channel_get(s, m.channel_id);
					clipboard_set(channel_link(ifx ch then ch.guild_id else 0, m.channel_id, m.id));
				case "Copy Message ID";
					clipboard_set(tprint("%", cast(u64) m.id));
				case "Delete Message";
					delete_now(m);
				case "Publish";
					if net_action() dc.crosspost_message(app.client, m.channel_id, m.id);
					else m.flags |= 1; // offline (fixture) runs: CROSSPOSTED
				case "End Poll Now";
					if net_action() dc.poll_expire(app.client, m.channel_id, m.id);
					else m.poll.finalized = true; // offline (fixture) runs
				case "Remove All Reactions";
					if app.ui_mods & .Shift remove_reactions_now(m); else ma.confirming, ma.confirm = m.id, Confirm.Remove_Reactions;
				}
				ma.menu_msg = 0;
			}
		}
	}
	for * e: app.ui.events { if e.kind == .Key_Down && e.key == .Escape { ma.menu_msg = 0; e.consumed = true; } }
	if ma.menu_msg == 0 message_menu_gone();
}

// Delete Message: hidden at once (message_held), DELETE after the undo window (undo.jai).
delete_now :: (m: *dc.Message) {
	if !undo_held(send_delete, m.id) undo_push("Message deleted", send_delete, a = m.id, b = m.channel_id);
}

EDIT_REQ :: "edit_message";
DELETE_REQ :: "delete_message"; // a failed delete toasts

// An edit's result: done, its draft goes; failed (after a toast), the edit opens again with the text.
edit_result :: (r: dc.Rest_Result) {
	if edit_draft.msg != r.message_id return;
	if r.ok edit_draft.msg = 0;
	else if ma.editing == 0 { m := find_message(r.message_id); if m start_edit(m); }
}

// A message whose Delete (or, for pins, Unpin) is held: lists leave it out.
message_held :: (id: dc.Snowflake, unpin := false) -> bool { return undo_held(send_delete, id) || (unpin && undo_held(send_unpin, id)); }

Confirm :: enum u8 { Pin; Remove_Embeds; Remove_Reactions; }

// DELETE .../reactions: gone for everyone once MESSAGE_REACTION_REMOVE_ALL comes.
remove_reactions_now :: (m: *dc.Message) {
	if net_action() dc.remove_all_reactions(app.client, m.channel_id, m.id);
	else array_reset(*m.reactions); // offline (fixture) runs
}

// Publish: a sent message in an announcement channel not yet crossposted (flag 1), yours or with
// MANAGE_MESSAGES.
can_publish :: (m: *dc.Message) -> bool {
	ch := dc.channel_get(store(), m.channel_id);
	return ch && ch.kind == .Guild_Announcement && !(m.flags & 1) && !m.pending && !m.failed && (m.kind == 0 || m.kind == 19) && can_manage_message(m);
}

// Yours, or in a server channel where you have MANAGE_MESSAGES.
can_manage_message :: (m: *dc.Message) -> bool {
	s := store();
	if m.author_id == s.me return true;
	ch := dc.channel_get(s, m.channel_id);
	return ch && ch.guild_id && (dc.channel_permissions(s, ch.id) & dc.PERM_MANAGE_MESSAGES);
}

// The hover X's "Remove all embeds": hidden at once, for everyone once the PATCH lands.
remove_embeds_now :: (m: *dc.Message) {
	if net_action() dc.suppress_embeds(app.client, m.channel_id, m.id, m.flags);
	m.flags |= 4;
}

// PUT / DELETE .../messages/pins/{id}; a failure shows the client's notice (features_receive). Unpin
// clears the flag at once and its DELETE waits behind Undo.
pin_now :: (m: *dc.Message, pin: bool) {
	if pin { if net_action() dc.pin_message(app.client, m.channel_id, m.id, true); return; }
	if undo_held(send_unpin, m.id) return;
	set_pinned(m.channel_id, m.id, false);
	m.pinned = false; // a pins card's copy
	undo_push("Message unpinned", send_unpin, (u: *Undo) { set_pinned(u.b, u.a, true); }, a = m.id, b = m.channel_id);
}

#scope_file

send_delete :: (u: *Undo) {
	if u.client { req_begin(DELETE_REQ); dc.delete_message(u.client, u.b, u.a); req_end(); return; }
	l := table_find_pointer(*store().messages, u.b); // offline (fixture) runs: gone as MESSAGE_DELETE would make it
	i := ifx l then dc.message_index(l, u.a) else -1;
	if i < 0 return;
	dc.free_message(store(), *l.messages[i]);
	array_ordered_remove_by_index(*l.messages, i);
}

send_unpin :: (u: *Undo) { if u.client dc.pin_message(u.client, u.b, u.a, false); }

set_pinned :: (channel: dc.Snowflake, id: dc.Snowflake, pinned: bool) {
	l := table_find_pointer(*store().messages, channel);
	i := ifx l then dc.message_index(l, id) else -1;
	if i >= 0 l.messages[i].pinned = pinned;
}

#scope_export

confirm_now :: (m: *dc.Message) {
	if ma.confirm == {
	case .Remove_Embeds; remove_embeds_now(m);
	case .Remove_Reactions; remove_reactions_now(m);
	case; pin_now(m, ma.confirm == .Pin);
	}
}

// The message confirmations (MessageActionCreators.confirmDelete / confirmPin / confirmUnpin):
// title, question, a preview of the message, a protip (delete, unpin) and two equal buttons.
confirm_modal :: () {
	m := find_message(ma.confirming);
	if m == null {
		ma.confirming = 0;
		return;
	}
	title, question, tip, ok := "Delete Message", "Are you sure you want to delete this message?", "delete message", "Delete";
	if ma.confirm == .Pin {
		ch := dc.channel_get(store(), m.channel_id);
		title, tip, ok = "Pin It. Pin It Good.", "", "Oh yeah. Pin it";
		question = ifx ch && ch.guild_id then tprint("Hey, just double checking that you want to pin this message to #% for posterity and greatness?", ch.name) else "Hey, just double checking that you want to pin this message to the current channel for posterity and greatness?";
	} else if ma.confirm == .Remove_Reactions {
		title, question, tip, ok = "Remove All Reactions", "Are you sure you want to remove all the reactions on this message?", "", "Remove";
	} else if ma.confirm == .Remove_Embeds {
		title, question, tip, ok = "Remove Embeds", "Are you sure you want to remove all embeds on this message? This will remove them for everyone.", "remove embeds", "Remove All Embeds";
	}
	scrim := ui.box("del_scrim", .Draw_Background | .Clickable | .Floating_X | .Floating_Y | .Overlay);
	scrim.semantic_size = .[ui.px(app.ui.window.x), ui.px(app.ui.window.y)];
	scrim.style.bg = .{0, 0, 0, 0.7};
	if ui.signal(scrim).clicked {
		ma.confirming = 0;
		return;
	}
	// official: 480 wide, 24px padding, close X, a preview card, protip, two equal buttons
	W :: 480;
	PAD :: 24;
	d := ui.box("del", .Draw_Background | .Draw_Border | .Floating_X | .Floating_Y | .Overlay | .Clickable);
	d.semantic_size = .[ui.px(W), ui.children()];
	d.fixed_pos = .{(app.ui.window.x - W) / 2, (app.ui.window.y - (d.rect.y1 - d.rect.y0)) / 2};
	d.style.bg = T("--modal-background");
	d.style.border_color = T("--border-subtle");
	d.style.border = 1;
	d.style.radius = all4(12);
	d.layout_axis = .Y;
	ui.signal(d);
	{ ui.parent(d); defer ui.pop_parent();
		x := ui.box("close", .Clickable | .Floating_X | .Floating_Y);
		x.semantic_size = .[ui.px(24), ui.px(24)];
		x.fixed_pos = .{W - 17 - 24, 17};
		xs := ui.signal(x);
		set_icon(x, "x-large", ifx xs.hovering then T("--interactive-icon-hover") else T("--interactive-icon-default"));
		if xs.clicked ma.confirming = 0;
		spacer(.Y, PAD + 1);
		t := row("t");
		t.semantic_size = .[ui.pct(1), ui.px(24)];
		{ ui.parent(t); defer ui.pop_parent();
			spacer(.X, PAD + 1);
			label(title, .Semibold, 20, T("--text-strong"), 24);
		}
		spacer(.Y, 8);
		q := row("q");
		q.semantic_size = .[ui.pct(1), ui.children()];
		{ ui.parent(q); defer ui.pop_parent();
			spacer(.X, PAD + 1);
			qb := ui.box("qt", .Draw_Text | .Wrap_Text);
			qb.semantic_size = .[ui.fill(), ui.text_size()];
			qb.text = question;
			qb.style.font = F(.Normal);
			qb.style.font_size = 16;
			qb.style.line_height = 20;
			qb.style.text_color = T("--text-subtle");
			spacer(.X, PAD + 1);
		}
		spacer(.Y, 24);
		pr := row("prow");
		pr.semantic_size = .[ui.pct(1), ui.children()];
		{ ui.parent(pr); defer ui.pop_parent();
			spacer(.X, PAD + 1);
			pv := row("preview", .Draw_Background);
			pv.semantic_size = .[ui.fill(), ui.children()];
			pv.style.bg = T("--background-base-low");
			pv.style.radius = all4(8);
			pv.cross_align = .Start;
			{ ui.parent(pv); defer ui.pop_parent();
				spacer(.X, 16);
				col0 := ui.box("avcol");
				col0.semantic_size = .[ui.px(40), ui.children()];
				{ ui.parent(col0); defer ui.pop_parent();
					spacer(.Y, 12);
					avatar_box("av", m.author_id, 40);
					spacer(.Y, 12);
				}
				spacer(.X, 16);
				col := ui.box("col");
				col.semantic_size = .[ui.fill(), ui.children()];
				{ ui.parent(col); defer ui.pop_parent();
					spacer(.Y, 10);
					hr := row("hdr");
					hr.semantic_size = .[ui.pct(1), ui.px(22)];
					hr.cross_align = .End;
					{ ui.parent(hr); defer ui.pop_parent();
						label(author_name(m), .Medium, 16, author_color(m), 22);
						spacer(.X, 8);
						label(header_timestamp(m.id), .Medium, 12, T("--chat-text-muted"), 20);
					}
					c := ui.box("content", .Draw_Text | .Wrap_Text);
					c.semantic_size = .[ui.pct(1), ui.text_size()];
					c.text = shown_text(m.id, m.channel_id, m.content);
					c.style.font = F(.Normal);
					c.style.font_size = 16;
					c.style.line_height = 22;
					c.style.text_color = T("--text-default");
					spacer(.Y, 10);
				}
				spacer(.X, 16);
			}
			spacer(.X, PAD + 1);
		}
		if tip {
		spacer(.Y, 20);
		tr := row("tip");
		tr.semantic_size = .[ui.pct(1), ui.children()];
		tr.cross_align = .Start;
		ui.parent(tr); defer ui.pop_parent();
			spacer(.X, PAD + 1);
			tc := ui.box("tc");
			tc.semantic_size = .[ui.fill(), ui.children()];
			{ ui.parent(tc); defer ui.pop_parent();
				label("Protip:", .Semibold, 14, T("--text-feedback-positive"), 18);
				body := ui.box("tipbody", .Wrap_Text);
				body.semantic_size = .[ui.pct(1), ui.text_size()];
				body.style.line_height = 16;
				body.style.text_color = T("--text-default");
				spans := NewArray(3, ui.Span,, temp);
				spans[0] = .{text = "You can hold down shift when clicking ", font = F(.Normal), size = 14};
				spans[1] = .{text = tip, font = F(.Bold), size = 14};
				spans[2] = .{text = " to bypass this confirmation entirely.", font = F(.Normal), size = 14};
				ui.set_spans(body, spans);
			}
			spacer(.X, PAD + 1);
		}
		spacer(.Y, 19);
		btns := row("btns");
		btns.semantic_size = .[ui.pct(1), ui.px(40)];
		btns.style.child_gap = 8;
		{ ui.parent(btns); defer ui.pop_parent();
			spacer(.X, PAD + 1 - 8);
			cancel := ui.box("Cancel##c", .Clickable | .Draw_Background | .Draw_Text | .Hot_Animation);
			cancel.semantic_size = .[ui.fill(), ui.px(40)];
			cancel.style.radius = all4(8);
			cancel.style.font = F(.Medium);
			cancel.style.font_size = 16;
			cancel.style.text_align = .Center;
			cancel.style.text_color = T("--text-strong");
			cancel.style.bg = T("--background-mod-normal");
			cancel.style.bg_hot = T("--background-mod-strong");
			if ui.signal(cancel).clicked ma.confirming = 0;
			del := ui.box(tprint("%##d", ok), .Clickable | .Draw_Background | .Draw_Text | .Hot_Animation);
			del.semantic_size = .[ui.fill(), ui.px(40)];
			del.style.radius = all4(8);
			del.style.font = F(.Medium);
			del.style.font_size = 16;
			del.style.text_align = .Center;
			del.style.text_color = .{1, 1, 1, 1};
			// pin is the primary (brand) variant, delete and unpin critical
			del.style.bg = ifx ma.confirm == .Pin then T("--control-primary-background-default") else T("--status-danger");
			del.style.bg_hot = ifx ma.confirm == .Pin then T("--control-primary-background-hover") else T("--control-critical-primary-background-hover");
			if ui.signal(del).clicked {
				confirm_now(m);
				ma.confirming = 0;
			}
			spacer(.X, PAD + 1 - 8);
		}
		spacer(.Y, PAD + 1);
	}
	for * e: app.ui.events {
		if e.kind == .Key_Down && e.key == .Escape { ma.confirming = 0; e.consumed = true; }
		if e.kind == .Key_Down && e.key == .Enter {
			confirm_now(m);
			ma.confirming = 0;
		}
	}
}

#scope_file

// the menu went away this frame (item, scrim, Escape)
message_menu_gone :: () {
	if app.client dc.message_menu_closed(app.client);
}
