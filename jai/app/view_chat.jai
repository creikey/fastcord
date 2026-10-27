// Cozy message layout, measured from the official client.
MSG_GUTTER :: 72; // content x offset
MSG_AVATAR :: 40;
MSG_GROUP_GAP :: 17; // space above the first message of a group
MSG_LINE_H :: 22;
MSG_FONT :: 16;
MSG_SCROLL_GUTTER :: 16;
MSG_PAD_R :: 48; // content padding-right (room for the hover toolbar)
MSG_EDIT_PAD_R :: 23; // the inline edit form ends 23px from the item edge
MSG_CALL :: 3; // message type CALL
CALL_ROW_H :: 26; // call notice content row (official item: 2 + 26 + 2)
COMPOSER_H :: 58; // official form height (1px border included): 22px line + 18px padding
GROUP_WINDOW_MS :: 7 * 60 * 1000; // messages from the same author within 7 minutes group

Chat_State :: struct {
	scroll_from_bottom: float32; // 0 = stuck to the newest message
	scroll_target: float32;
	heights: Table(dc.Snowflake, float32); // measured row heights
	loading_older: bool;
	editor: ui.Editor;
	hovered_msg: dc.Snowflake;
	unread_after: dc.Snowflake; // read marker when the channel was opened ("NEW" divider)
	opened: bool;
}

chat_state :: (channel_id: dc.Snowflake) -> *Chat_State {
	{ cs, ok := map_find_ptr(*app.chats, channel_id);
	if ok { return cs; } }
	at(*app.chats, channel_id).* = .{};
	return at(*app.chats, channel_id);
}
#scope_file

// Groups with the previous message: same author, within 7 minutes, plain message type, not a reply.
continues_group :: (prev: *dc.Message, m: *dc.Message) -> bool {
	if prev == null { return false; }
	if prev.author_id != m.author_id { return false; }
	if prev.kind == MSG_CALL { return false; }
	if m.referenced_id != 0 || (m.kind != 0 && m.kind != 19) { return false; }
	if dc.snowflake_time_ms(m.id) - dc.snowflake_time_ms(prev.id) > GROUP_WINDOW_MS { return false; }
	return day_of(prev.id) == day_of(m.id);
}

day_of :: (id: dc.Snowflake) -> s64 {
	ms := dc.snowflake_time_ms(id) + local_utc_offset_ms();
	return ms / 86_400_000;
}
#scope_export

local_utc_offset_ms :: () -> s64 {
	return app.utc_offset_ms;
}

// "3:04 PM" today, "Yesterday at 3:04 PM", or "10/24/2026 3:04 PM" — the client's calendar format.
format_timestamp :: (id: dc.Snowflake, short := false) -> string {
	ms := dc.snowflake_time_ms(id) + local_utc_offset_ms();
	now_ms := wall_ms() + local_utc_offset_ms();
	t := time.unix(ms / 1000, 0);
	h, mi, _ := time.clock_from_time(t);
	ampm := ifx h >= 12 then "PM" else "AM";
	h12 := h % 12;
	if h12 == 0 { h12 = 12; }
	clock := fmt.tprintf("%d:%02d\u202f%s", h12, mi, ampm); // narrow no-break space, as Intl formats it
	if short { return clock; }
	day := ms / 86_400_000;
	today := now_ms / 86_400_000;
	if day == today {
		return clock;
	} else if day == today - 1 {
		return fmt.tprintf("Yesterday at %s", clock);
	}
	y, mo, d := time.date(t);
	return fmt.tprintf("%d/%d/%d %s", cast(int)(mo), d, y, clock);
}
#scope_file

// format_timestamp kept alive across frames: header timestamps are selectable,
// and a selection is read (copy, scripts) after the frame's temp memory is gone.
Stamp_Cache :: struct {
	day: s64;
	texts: Table(dc.Snowflake, string);
}
stamps: Stamp_Cache;
#scope_export

// Unix ms now (or the -now: override).
wall_ms :: () -> s64 {
	if app.now_override_ms != 0 { return app.now_override_ms; }
	return time.time_to_unix_nano(time.now()) / 1000000;
}

header_timestamp :: (id: dc.Snowflake) -> string {
	today := (wall_ms() + local_utc_offset_ms()) / 86_400_000;
	if today != stamps.day {
		for v: stamps.texts { delete(v); }
		clear(*stamps.texts);
		stamps.day = today;
	}
	{ s, ok := map_find(stamps.texts, id);
	if ok { return s; } }
	s := clone(format_timestamp(id));
	at(*stamps.texts, id).* = s;
	return s;
}

chat_view :: (channel_id: dc.Snowflake) {
	s := store();
	ch := dc.channel_get(s, channel_id);
	if ch == null { return; }
	cs := chat_state(channel_id);
	if !cs.opened {
		cs.opened = true;
		cs.unread_after = get(s.read_states, channel_id).last_message_id;
	}
	// Ack what's on screen while focused and scrolled to the bottom, like the client.
	msgs := dc.messages_get(s, channel_id);
	if app.client != null && app.focused && len(msgs) > 0 && cs.scroll_from_bottom < 2 {
		last := msgs[len(msgs) - 1].id;
		if last > get(s.read_states, channel_id).last_message_id && !msgs[len(msgs) - 1].pending { dc.ack_message(app.client, channel_id, last); }
	}

	picker_capture_input(); // expression picker owns keys/wheel while open
	col := ui.box("chatcol");
	col.semantic_size = .[ui.fill(), ui.pct(1)];
	col.layout_axis = .Y;
	{ ui.parent(col); defer ui.pop_parent();
		message_list(channel_id, cs);
		typing_line(channel_id);
		composer(ch, cs);
	}
}
#scope_file

message_list :: (channel_id: dc.Snowflake, cs: *Chat_State) {
	s := store();
	list := ui.box("messages", .Clip | .Scroll_Y);
	list.semantic_size = .[ui.pct(1), ui.fill()];
	// Scrolling is managed here (anchored to the bottom), not by ui's scroll offset.
	list.flags &= ~ui.Box_Flag.Scroll_Y;
	msgs := dc.messages_get(s, channel_id);
	view_h := list.rect.y1 - list.rect.y0;
	if view_h <= 0 { view_h = app.ui.window.y; }

	// wheel input over the list
	if ui.mouse_over(list) {
		for * e: app.ui.events {
			if e.kind != .Scroll || e.consumed { continue; }
			cs.scroll_target += e.delta.y;
			e.consumed = true;
		}
	}

	// dragging a text selection past the list edges scrolls, faster the further out
	if app.ui.selection.dragging && list.rect.y1 > list.rect.y0 {
		my := app.ui.mouse.y;
		if my < list.rect.y0 + 24 {
			cs.scroll_target += ((list.rect.y0 + 24 - my) * 0.5 + 2) * app.ui.dt * 60;
			app.ui.animating = true;
		} else if my > list.rect.y1 - 24 {
			cs.scroll_target -= ((my - (list.rect.y1 - 24)) * 0.5 + 2) * app.ui.dt * 60;
			app.ui.animating = true;
		}
	}

	// total height from measured rows (estimates for unmeasured)
	TOP_PAD :: 16;
	BOTTOM_PAD :: 8;
	total: float32 = TOP_PAD + BOTTOM_PAD;
	// the start of a 1:1 DM's history carries the welcome header (avatar, names, friend actions);
	// a guild text channel's carries "Welcome to #channel!"
	welcome_ch := dc.channel_get(s, channel_id);
	welcome_h: float32 = 0;
	if welcome_ch != null {
		l, ok := map_find(s.messages, channel_id);
		if !ok || l.has_more_before || l.loading { welcome_ch = null; }
	}
	if welcome_ch != null {
		if welcome_ch.kind == {
		case .DM;
			if len(welcome_ch.recipient_ids) == 1 { welcome_h = DMW_H; }
		case .Guild_Text; #through; case .Guild_Announcement;
			welcome_h = channel_welcome_height(welcome_ch);
		}
		if welcome_h == 0 { welcome_ch = null; }
	}
	if welcome_ch != null { total += welcome_h + DMW_GAP - TOP_PAD; }
	for * m: msgs {
		h, ok := map_find(cs.heights, m.id);
		total += ifx ok then h else MSG_LINE_H + 4;
	}
	max_scroll := max(0.0, total - view_h);
	jump_apply(channel_id, cs, msgs, view_h, BOTTOM_PAD);
	cs.scroll_target = clamp(cs.scroll_target, 0, max_scroll);
	ui.animate(*cs.scroll_from_bottom, cs.scroll_target, 40);
	cs.scroll_from_bottom = clamp(cs.scroll_from_bottom, 0, max_scroll);

	// load older history when within a screen of the top
	if total - cs.scroll_from_bottom - view_h < view_h && len(msgs) > 0 {
		l := get(s.messages, channel_id);
		if !l.loading && l.has_more_before && app.client != null {
			dc.fetch_messages(app.client, channel_id, msgs[0].id);
		}
	}

	// Render the contiguous run of rows near the viewport as one column anchored
	// to the list's bottom edge. Its offset only depends on rows *below* it, so
	// at the bottom (the common case) placement is exact on the first frame and
	// rows never jump while their real heights get measured.
	est :: (cs: *Chat_State, id: dc.Snowflake) -> float32 {
		h, ok := map_find(cs.heights, id);
		return ifx ok then h else MSG_LINE_H + 4;
	}
	MARGIN :: 200;
	i1 := len(msgs) - 1;
	below: float32 = 0; // height of rows after i1
	while i1 >= 0 && below + est(cs, msgs[i1].id) < cs.scroll_from_bottom - MARGIN {
		below += est(cs, msgs[i1].id);
		i1 -= 1;
	}
	i0 := i1;
	span: float32 = 0;
	while i0 >= 0 && below + span < cs.scroll_from_bottom + view_h + MARGIN {
		span += est(cs, msgs[i0].id);
		i0 -= 1;
	}
	i0 += 1;
	{ ui.parent(list); defer ui.pop_parent();
		col := ui.box("rows", .Floating_Y | .Anchor_End_Y);
		col.semantic_size = .[ui.pct(1), ui.children()];
		// items stop short of the scrollbar gutter (official: 375..1264 in a 905px list)
		{ lw := list.rect.x1 - list.rect.x0;
		if lw > MSG_SCROLL_GUTTER { col.semantic_size[ui.Axis.X] = ui.px(lw - MSG_SCROLL_GUTTER); } }
		col.layout_axis = .Y;
		col.fixed_pos = .{0, BOTTOM_PAD + below - cs.scroll_from_bottom};
		{ ui.parent(col); defer ui.pop_parent();
			if i0 == 0 {
				if welcome_ch != null {
					if welcome_ch.kind == .DM { dm_welcome(welcome_ch); } else { channel_welcome(welcome_ch); }
					spacer(.Y, DMW_GAP);
				} else {
					spacer(.Y, TOP_PAD);
				}
			}
			for i: max(i0, 0)..i1 {
				if i < 0 { break; }
				m := *msgs[i];
				prev: *dc.Message = ifx i > 0 then *msgs[i - 1] else null;
				new_day := prev == null || day_of(prev.id) != day_of(m.id);
				show_new := cs.unread_after != 0 && m.id > cs.unread_after && (prev == null || prev.id <= cs.unread_after) && m.author_id != s.me;
				grouped := continues_group(prev, m) && !show_new;
				// consecutive call notices stack with no group gap
				if m.kind == MSG_CALL { grouped = prev != null && prev.kind == MSG_CALL && !new_day && !show_new; }
				{ ui.id_scope(cast(u64)(m.id)); defer ui.pop_seed();
					row := message_row(m, grouped, i, new_day, show_new);
					// remember measured height (from last frame's layout)
					if row.rect.y1 > row.rect.y0 { at(*cs.heights, m.id).* = row.rect.y1 - row.rect.y0; }
				}
			}
		}
	}
}

// One message: either a group start (avatar, name, time) or a continuation.
message_row :: (m: *dc.Message, grouped: bool, index: int, new_day: bool, show_new: bool) -> *ui.Box {
	s := store();
	r0 := ui.box("msg");
	r0.semantic_size = .[ui.pct(1), ui.children()];
	r0.layout_axis = .Y;
	editing := ma.editing == m.id;
	{ ui.parent(r0); defer ui.pop_parent();
		if new_day || show_new {
			divider_row(m.id, new_day, show_new);
		} else if !grouped {
			spacer(.Y, MSG_GROUP_GAP - 2);
		}
		// the list item proper: hover/highlight cover it, not the group gap above (a margin in the client)
		li := ui.box("li", .Draw_Background);
		li.semantic_size = .[ui.pct(1), ui.children()];
		li.layout_axis = .Y;
		ui.push_parent(li);
		defer ui.pop_parent();
		hovered := ui.mouse_over(li) && !app.ui.selection.dragging;
		if hovered { app.chat_hover = m.id; }
		if (hovered || ma.menu_msg == m.id) && !editing { li.style.bg = T("--message-background-hover"); }
		highlighted := ma.replying == m.id || jump_highlighted(m.id);
		if highlighted {
			li.style.bg = T("--message-highlight-background-default");
			li.style.radius = .[0, 4, 4, 0];
			bar := ui.box("hlbar", .Draw_Background | .Floating_X | .Floating_Y);
			bar.semantic_size = .[ui.px(2), ui.px(li.rect.y1 - li.rect.y0)];
			bar.style.bg = T("--background-brand");
		}
		for e: app.ui.events {
			// a control under the press (author name → user menu, avatar, …) takes its
			// own right-click; both menus used to open, the message menu on top
			if e.kind == .Mouse_Down && e.button == .Right && hovered && app.ui.hot == 0 { open_message_menu(m, e.pos, "right_click"); }
		}
		if (hovered || ma.menu_msg == m.id) && !editing && m.kind != MSG_CALL {
			// the toolbar hangs 16px above the item's top edge (official: top -16, right 14)
			anchor := ui.box("tbanchor");
			anchor.semantic_size = .[ui.pct(1), ui.px(0)];
			{ ui.parent(anchor); defer ui.pop_parent(); message_toolbar(m); }
		}
		spacer(.Y, 2);
		if m.referenced_id != 0 {
			rr := row("replyrow");
			rr.semantic_size = .[ui.pct(1), ui.px(22)];
			{ ui.parent(rr); defer ui.pop_parent();
				spacer(.X, MSG_GUTTER);
				reply_preview(m);
			}
		}
		if m.kind == MSG_CALL {
			call_notice(m);
			spacer(.Y, 2);
			return r0;
		}
		body := row("body");
		body.semantic_size = .[ui.pct(1), ui.children()];
		body.cross_align = .Start;
		{ ui.parent(body); defer ui.pop_parent();
			gutter := ui.box("gutter");
			gutter.semantic_size = .[ui.px(MSG_GUTTER), ui.px(MSG_LINE_H)];
			if !grouped {
				{ ui.parent(gutter); defer ui.pop_parent();
					av := avatar_box("avatar", m.author_id, MSG_AVATAR);
					av.flags |= .Floating_X | .Floating_Y;
					av.fixed_pos = .{16, 2};
				}
			} else if hovered {
				gutter.layout_axis = .X;
				gutter.cross_align = .Center;
				{ ui.parent(gutter); defer ui.pop_parent();
					filler(.X);
					label(format_timestamp(m.id, true), .Medium, 11, T("--text-muted"), MSG_LINE_H);
					spacer(.X, 8);
				}
			}
			content := ui.box("content");
			content.semantic_size = .[ui.fill(), ui.children()];
			content.layout_axis = .Y;
			{ ui.parent(content); defer ui.pop_parent();
				if !grouped { message_header(m); }
				if editing { edit_box(m); } else { message_body(m); }
				if len(m.sticker_ids) > 0 { message_stickers_view(m); }
				thread_summary_pill(m);
				if len(m.attachments) > 0 { attachments_view(m); }
				if m.pending { upload_progress_view(m); }
				if len(m.embeds) > 0 { embeds_view(m); }
				if len(m.reactions) > 0 { reactions_view(m); }
			}
			spacer(.X, ifx editing then cast(float32) MSG_EDIT_PAD_R else cast(float32) MSG_PAD_R); // the edit form reaches further right

		}
		spacer(.Y, 2);
	}
	return r0;
}

// "Name started a call that lasted a few seconds. 4:43 AM" with a phone icon in the gutter.
call_notice :: (m: *dc.Message) {
	r := row("call");
	r.semantic_size = .[ui.pct(1), ui.children()];
	r.cross_align = .Start;
	{ ui.parent(r); defer ui.pop_parent();
		g := ui.box("gutter");
		g.semantic_size = .[ui.px(MSG_GUTTER), ui.px(CALL_ROW_H)];
		{ ui.parent(g); defer ui.pop_parent();
			ic := icon("phone", "phone", 16, T("--icon-feedback-positive"));
			ic.flags |= .Floating_X | .Floating_Y;
			ic.fixed_pos = .{28, (CALL_ROW_H - 16) / 2};
		}
		name := name_in(m.author_id, m.channel_id);
		what := " started a call.";
		if m.call_ended != "" {
			start, _ := time.rfc3339_to_time_utc(m.timestamp);
			end, _ := time.rfc3339_to_time_utc(m.call_ended);
			what = fmt.tprintf(" started a call that lasted %s.", humanize_duration(time.diff(start, end)));
		}
		spans := make_slice(ui.Span, 3, temp);
		spans[0] = .{text = name, font = F(.Medium), size = MSG_FONT, color = T("--text-strong")};
		spans[1] = .{text = what, font = F(.Normal), size = MSG_FONT, color = T("--text-muted")};
		spans[2] = .{text = fmt.tprintf(" %s", header_timestamp(m.id)), font = F(.Medium), size = 12, color = T("--chat-text-muted")};
		b := ui.box("text", .Selectable_Text | .Wrap_Text);
		b.semantic_size = .[ui.fill(), ui.text_size()];
		b.style.line_height = MSG_LINE_H;
		b.style.padding = .{0, (CALL_ROW_H - MSG_LINE_H) / 2};
		ui.set_spans(b, spans);
		b.sel_order = cast(u64)(m.id) * 8 + 2;
		spacer(.X, 48);
	}
}
#scope_export

// moment.js-style relative duration ("a few seconds", "a minute", "5 minutes", "an hour").
humanize_duration :: (d: time.Duration) -> string {
	secs := cast(s64)(time.duration_seconds(d));
	mins := (secs + 30) / 60;
	hours := (mins + 30) / 60;
	if secs < 45 {
		return "a few seconds";
	} else if secs < 90 {
		return "a minute";
	} else if mins < 45 {
		return fmt.tprintf("%d minutes", mins);
	} else if mins < 90 {
		return "an hour";
	} else if hours < 22 {
		return fmt.tprintf("%d hours", hours);
	} else if hours < 36 {
		return "a day";
	}
	return fmt.tprintf("%d days", (hours + 12) / 24);
}
#scope_file

message_header :: (m: *dc.Message) {
	name := name_in(m.author_id, m.channel_id);
	h := row("header");
	h.semantic_size = .[ui.pct(1), ui.px(MSG_LINE_H)];
	h.cross_align = .End;
	{ ui.parent(h); defer ui.pop_parent();
		n := label(name, .Medium, 16, author_color(m), MSG_LINE_H);
		n.flags |= .Clickable | .Selectable_Text;
		n.sel_order = cast(u64)(m.id) * 8;
		nsig := ui.signal(n);
		if nsig.clicked { open_profile(m.author_id, n.rect, .Message_Author, m.id); }
		if nsig.right_clicked { open_user_menu(m.author_id, app.ui.mouse); }
		spacer(.X, 8);
		// copies as "Name — 4:56 AM" like the client's hidden separator
		ts := label(header_timestamp(m.id), .Medium, 12, T("--chat-text-muted"), 20);
		ts.flags |= .Selectable_Text;
		ts.sel_order = cast(u64)(m.id) * 8 + 1;
		ts.sel_join = " — ";
	}
}
#scope_export

author_color :: (m: *dc.Message) -> ui.Color {
	s := store();
	ch := dc.channel_get(s, m.channel_id);
	if ch != null && ch.guild_id != 0 {
		{ c, ok := member_color(ch.guild_id, m.author_id);
		if ok { return c; } }
	}
	return T("--text-strong");
}

// Highest-position colored role.
member_color :: (guild_id: dc.Snowflake, user_id: dc.Snowflake) -> ui.Color, bool {
	s := store();
	mem := dc.member_get(s, guild_id, user_id);
	g := dc.guild_get(s, guild_id);
	if mem == null || g == null { return .{}, false; }
	best := -1;
	color: u32;
	for rid: mem.roles {
		for r: g.roles {
			if r.id == rid && r.color != 0 && r.position > best {
				best = r.position;
				color = r.color;
			}
		}
	}
	if best < 0 { return .{}, false; }
	return rgb_u32(color), true;
}

rgb_u32 :: (c: u32) -> ui.Color {
	return .{cast(float32)((c >> 16) & 0xff) / 255, cast(float32)((c >> 8) & 0xff) / 255, cast(float32)(c & 0xff) / 255, 1};
}
#scope_file

message_body :: (m: *dc.Message) {
	if m.content == "" { return; }
	blocks := md_parse(m.content);
	edited_inline := false;
	for blk, bi: blocks {
		color := T("--text-default");
		if m.pending { color = T("--text-muted"); }
		if m.failed { color = T("--text-feedback-critical"); }
		if blk.kind == {
		case .Code_Block;
			cb := ui.box(fmt.tprintf("code%d", bi), .Draw_Background | .Draw_Border | .Draw_Text | .Selectable_Text | .Wrap_Text);
			cb.text = blk.code;
			cb.semantic_size = .[ui.pct(1), ui.text_size()];
			cb.style.bg = T("--background-base-lowest");
			cb.style.border_color = T("--border-subtle");
			cb.style.border = 1;
			cb.style.radius = all4(4);
			cb.style.font = F(.Mono);
			cb.style.font_size = 14;
			cb.style.line_height = 18;
			cb.style.padding = .{8, 8};
			cb.style.text_color = T("--text-code");
			cb.sel_order = cast(u64)(m.id) * 8 + 2 + cast(u64)(bi) % 4;
		case .Paragraph; #through; case .Quote; #through; case .Heading1; #through; case .Heading2; #through; case .Heading3; #through; case .Subtext; #through; case .List_Item;
			size: float32 = MSG_FONT;
			font := Font_Id.Normal;
			line_h: float32 = MSG_LINE_H;
			if blk.kind == {
			case .Heading1;
				size, font, line_h = 24, Font_Id.Bold, 33;
			case .Heading2;
				size, font, line_h = 20, Font_Id.Bold, 27.5;
			case .Heading3;
				size, font, line_h = 16, Font_Id.Bold, 22;
			case .Subtext;
				size, line_h = 13, 18;
				color = T("--text-muted");
			}
			// quotes get a 4px bar, list items a bullet; both indent the text
			wrap := row(fmt.tprintf("blk%d", bi));
			wrap.semantic_size = .[ui.pct(1), ui.children()];
			wrap.cross_align = .Start;
			b: *ui.Box;
			{ ui.parent(wrap); defer ui.pop_parent();
				if blk.kind == {
				case .Quote;
					bar := ui.box("quotebar", .Draw_Background);
					bar.semantic_size = .[ui.px(4), ui.px(line_h)];
					bar.style.bg = T("--border-strong");
					bar.style.radius = all4(4);
					spacer(.X, 12);
				case .List_Item;
					spacer(.X, 6 + cast(float32)(blk.depth) * 20);
					label(ifx blk.depth == 0 then "•" else "◦", .Normal, size, color, line_h);
					spacer(.X, 8);
				}
				// keyed per block: ids resolve against the message's id_scope, not the
				// row, so a plain "p" collided from the second block on and became an
				// anonymous box (no selection anchor, no link/mention clicks)
				b = ui.box(fmt.tprintf("p%d", bi), .Selectable_Text | .Wrap_Text);
				b.semantic_size = .[ui.fill(), ui.text_size()];
				b.style.text_color = color;
				b.style.line_height = line_h;
				spans := tokens_to_spans(blk.tokens, font, size, m);
				// jumbo: a message of only emoji (up to 27) renders them at 48px
				if len(blocks) == 1 && is_emoji_only(blk.tokens) {
					for * sp: spans {
						if sp.object != .{} { sp.object = .{48, 48}; } else { sp.size = 44; }
					}
					b.style.line_height = 56;
				}
				if bi == len(blocks) - 1 && m.edited_timestamp != "" {
					// "(edited)" rides at the end of the last paragraph, like the client
					edited := make_slice(ui.Span, len(spans) + 1, temp);
					copy(edited, spans);
					edited[len(spans)] = .{text = " (edited)", font = F(.Normal), size = 10, color = T("--text-muted")};
					spans = edited;
					edited_inline = true;
				}
				ui.set_spans(b, spans);
				b.sel_order = cast(u64)(m.id) * 8 + 2 + cast(u64)(bi) % 4;
			}
			if b != null { handle_span_clicks(b, blk.tokens); }
		}
	}
	if m.edited_timestamp != "" && !edited_inline {
		label("(edited)", .Normal, 10, T("--text-muted"), 22);
	}
}
#scope_export

// Mentions, links, emoji and inline styles become rich-text spans.
tokens_to_spans :: (toks: []Token, base: Font_Id, size: float32, m: *dc.Message) -> []ui.Span {
	s := store();
	spans := make_dynamic(ui.Span, 0, len(toks), temp);
	for tk, i: toks {
		sp := ui.Span.{text = tk.text, font = F(base), size = size, id = cast(u64)(i)};
		if has(tk.styles, .Bold) { sp.font = F(.Bold); } else if has(tk.styles, .Italic) && base == .Normal { sp.font = F(.Italic); }
		if has(tk.styles, .Code) {
			sp.font = F(.Mono);
			sp.size = size * 0.85;
			sp.bg = T("--background-code");
			sp.bg_radius = 4;
		}
		if has(tk.styles, .Underline) { sp.underline = true; }
		if has(tk.styles, .Strike) { sp.strike = true; }
		if has(tk.styles, .Spoiler) {
			sp.bg = T("--spoiler-hidden-background");
			sp.color = sp.bg;
			sp.bg_radius = 4;
		}
		if tk.kind == {
		case .Text;
			if !has(tk.styles, .Code) {
				emoji_text_spans(*spans, sp);
				continue;
			}
		case .Link;
			sp.color = T("--text-link");
		case .User_Mention;
			sp.text = fmt.tprintf("@%s", name_in(cast(dc.Snowflake)(tk.id), ifx m != null then m.channel_id else 0, "unknown-user"));
			sp.bg = T("--mention-background");
			sp.color = T("--mention-foreground");
			sp.bg_radius = 3;
			sp.font = F(.Medium);
		case .Role_Mention; #through; case .Everyone;
			sp.bg = T("--mention-background");
			sp.color = T("--mention-foreground");
			sp.bg_radius = 3;
			sp.font = F(.Medium);
			if tk.kind == .Role_Mention { sp.text = "@role"; }
		case .Channel_Mention;
			name := "unknown";
			{ c := dc.channel_get(s, cast(dc.Snowflake)(tk.id));
			if c != null { name = c.name; } }
			sp.text = fmt.tprintf("#%s", name);
			sp.bg = T("--mention-background");
			sp.color = T("--mention-foreground");
			sp.bg_radius = 3;
			sp.font = F(.Medium);
		case .Custom_Emoji;
			sp.object = .{22, 22};
			sp.text = fmt.tprintf(":%s:", tk.name);
			sp.user = cast(*void)(cast(u64)(tk.id));
		case .Timestamp;
			sp.text = format_unix(cast(s64)(tk.id), tk.name);
			sp.bg = T("--background-mod-subtle");
			sp.bg_radius = 3;
		}
		append(*spans, sp);
	}
	return view(spans);
}

format_unix :: (secs: s64, style: string) -> string {
	ms := secs * 1000 + local_utc_offset_ms();
	t := time.unix(ms / 1000, 0);
	y, mo, d := time.date(t);
	h, mi, _ := time.clock_from_time(t);
	h12 := h % 12;
	if h12 == 0 { h12 = 12; }
	ampm := ifx h >= 12 then "PM" else "AM";
	if style == {
	case "t";
		return fmt.tprintf("%d:%02d %s", h12, mi, ampm);
	case "d";
		return fmt.tprintf("%d/%d/%d", cast(int)(mo), d, y);
	}
	return fmt.tprintf("%v %d, %d %d:%02d %s", mo, d, y, h12, mi, ampm);
}

// Clicks on links / mentions in a paragraph, against last frame's layout of the
// box (spans carry their token index in id).
handle_span_clicks :: (b: *ui.Box, toks: []Token) {
	tl := b.prev_layout;
	if tl == null || is_null(tl.spans) { return; }
	for e: app.ui.events {
		if e.kind != .Mouse_Up || e.button != .Left || e.consumed || ui.has_selection() { continue; }
		if ui.overlay_at(e.pos) { continue; }
		si := ui.span_at(tl, e.pos);
		if si < 0 || si >= len(tl.spans) { continue; }
		ti := cast(int)(tl.spans[si].id);
		if ti < 0 || ti >= len(toks) { continue; }
		tk := toks[ti];
		if tk.kind == {
		case .Link;
			open_url(tk.text);
		case .User_Mention;
			r := ui.Rect.{e.pos.x, e.pos.y - 10, e.pos.x + 1, e.pos.y + 10};
			open_profile(cast(dc.Snowflake)(tk.id), r);
		case .Channel_Mention;
			{ c := dc.channel_get(store(), cast(dc.Snowflake)(tk.id));
			if c != null { select_channel(c.guild_id, c.id); } }
		}
	}
}
#scope_file

attachments_view :: (m: *dc.Message) {
	for * a, i: m.attachments {
		if is_video(a) && a.width > 0 && a.height > 0 {
			w := cast(float32)(a.width);
			h := cast(float32)(a.height);
			sc := min(1.0, min(400 / w, 300 / h));
			video_attachment(a, w * sc, h * sc);
			spacer(.Y, 4);
		} else if is_audio(a) {
			audio_attachment(a);
			spacer(.Y, 4);
		} else if a.width > 0 && a.height > 0 {
			// images scale to fit 400x300 like the client
			w := cast(float32)(a.width);
			h := cast(float32)(a.height);
			sc := min(1.0, min(400 / w, 300 / h));
			img := ui.box(fmt.tprintf("att%d", i), .Draw_Background | .Clickable);
			img.semantic_size = .[ui.px(w * sc), ui.px(h * sc)];
			img.style.radius = all4(8);
			img.style.bg = T("--background-mod-subtle");
			set_remote_image(img, attachment_image_url(a, cast(int)(w * sc), cast(int)(h * sc)));
			if ui.signal(img).clicked { open_viewer(ifx a.proxy_url != "" then a.proxy_url else a.url, .{a.width, a.height}); }
			spacer(.Y, 4);
		} else {
			f := row(fmt.tprintf("file%d", i), .Draw_Background | .Draw_Border);
			f.semantic_size = .[ui.px(432), ui.px(72)];
			f.style.bg = T("--background-surface-high");
			f.style.border_color = T("--border-subtle");
			f.style.border = 1;
			f.style.radius = all4(8);
			{ ui.parent(f); defer ui.pop_parent();
				spacer(.X, 16);
				icon("ficon", "attachment", 30, T("--interactive-icon-default"));
				spacer(.X, 8);
				col := ui.box("fcol");
				col.semantic_size = .[ui.fill(), ui.children()];
				{ ui.parent(col); defer ui.pop_parent();
					label(a.filename, .Normal, 16, T("--text-link"), 20);
					label(human_size(a.size), .Normal, 12, T("--text-muted"), 16);
				}
			}
			spacer(.Y, 4);
		}
	}
}
#scope_export

human_size :: (n: int) -> string {
	if n >= (1 << 20) {
		return fmt.tprintf("%.2f MB", cast(float64)(n) / cast(float64)(1 << 20));
	} else if n >= (1 << 10) {
		return fmt.tprintf("%.2f KB", cast(float64)(n) / cast(float64)(1 << 10));
	}
	return fmt.tprintf("%d bytes", n);
}
#scope_file

reactions_view :: (m: *dc.Message) {
	r := row("reactions");
	r.semantic_size = .[ui.pct(1), ui.px(30)];
	r.style.child_gap = 4;
	{ ui.parent(r); defer ui.pop_parent();
		for * re, i: m.reactions {
			pill := row(fmt.tprintf("re%d", i), .Clickable | .Draw_Background | .Draw_Border | .Hot_Animation);
			pill.semantic_size = .[ui.children(), ui.px(26)];
			pill.style.radius = all4(8);
			pill.style.border = 1;
			if re.me {
				pill.style.bg = T("--reaction-background-reacted-default");
				pill.style.border_color = T("--reaction-border-reacted-default");
			} else {
				pill.style.bg = T("--reaction-background-default");
				pill.style.bg_hot = T("--reaction-background-hover");
				pill.style.border_color = T("--reaction-border-default");
			}
			sig := ui.signal(pill);
			{ ui.parent(pill); defer ui.pop_parent();
				spacer(.X, 6);
				emoji_box("e", re.emoji, 16);
				spacer(.X, 6);
				label(fmt.tprintf("%d", re.count), .Semibold, 14, ifx re.me then T("--reaction-text-reacted-default") else T("--reaction-text-default"), 16);
				spacer(.X, 6);
			}
			if sig.clicked && net_action() {
				if re.me {
					dc.remove_reaction(app.client, m.channel_id, m.id, re.emoji.name, re.emoji.id);
				} else {
					dc.add_reaction(app.client, m.channel_id, m.id, re.emoji.name, re.emoji.id);
				}
			}
		}
		reaction_add_button(m);
	}
	spacer(.Y, 2);
}

typing_line :: (channel_id: dc.Snowflake) {
	s := store();
	t := row("typing");
	t.semantic_size = .[ui.pct(1), ui.px(24)];
	typers := dc.typing_users(s, channel_id);
	if len(typers) == 0 { return; }
	{ ui.parent(t); defer ui.pop_parent();
		spacer(.X, 16);
		names := make_dynamic(string, 0, 0, temp);
		for ty: typers {
			if ty.user_id == s.me { continue; }
			{ name := name_in(ty.user_id, channel_id, "");
			if name != "" { append(*names, name); } }
		}
		if len(names) == 0 { return; }
		msg: string;
		if len(names) == {
		case 1;
			msg = fmt.tprintf("%s is typing...", get(names, 0));
		case 2;
			msg = fmt.tprintf("%s and %s are typing...", get(names, 0), get(names, 1));
		case 3;
			msg = fmt.tprintf("%s, %s, and %s are typing...", get(names, 0), get(names, 1), get(names, 2));
		case;
			msg = "Several people are typing...";
		}
		typing_dots();
		spacer(.X, 4);
		label(msg, .Medium, 14, T("--text-default"), 24);
	}
}

// Three dots pulsing in sequence (the client's typing animation).
typing_dots :: () {
	r := row("dots");
	r.semantic_size = .[ui.px(24), ui.px(8)];
	{ ui.parent(r); defer ui.pop_parent();
		for i: 0..2 {
			phase := cast(float32)(app.ui.time * 1.4) - cast(float32)(i) * 0.15;
			k := 0.5 + 0.5 * cast(float32)(abs(fract(phase) * 2 - 1));
			d := ui.box(fmt.tprintf("d%d", i), .Draw_Background);
			d.semantic_size = .[ui.px(6), ui.px(6)];
			d.style.radius = all4(3);
			d.style.bg = with_alpha(T("--text-default"), 0.3 + 0.7 * k);
			spacer(.X, 2);
		}
	}
	app.ui.animating = true;
}
#scope_export

fract :: (x: float32) -> float32 {return x - cast(float32)(cast(int)(x));}
#scope_file

composer :: (ch: *dc.Channel, cs: *Chat_State) {
	s := store();
	outer := row("composer_outer");
	outer.semantic_size = .[ui.pct(1), ui.children()];
	outer.cross_align = .Start;
	{ ui.parent(outer); defer ui.pop_parent();
		spacer(.X, 8);
		// one bordered form holds the reply bar, staged uploads and the text area
		stack := ui.box("composer_stack", .Draw_Background | .Draw_Border);
		stack.semantic_size = .[ui.fill(), ui.children()];
		stack.layout_axis = .Y;
		stack.style.bg = T("--chat-background-default");
		stack.style.border_color = T("--border-subtle");
		stack.style.border = 1;
		stack.style.radius = all4(8);
		ui.push_parent(stack);
		if ma.replying != 0 { reply_bar(); }
		uploads_bar(ch.id);
		box := row("composer", .Clickable);
		box.semantic_size = .[ui.fill(), ui.children()];
		box.cross_align = .Start;
		box.hover_cursor = .IBeam;
		if ui.signal(box).pressed { app.ui.focus = box.key; }
		{ ui.parent(box); defer ui.pop_parent();
			spacer(.X, 16);
			plus := ui.box("plus", .Clickable);
			if ui.signal(plus).clicked {
				stage_paths(ch.id, pick_files(), "file_picker");
			}
			plus.semantic_size = .[ui.px(24), ui.px(COMPOSER_H)];
			plus.layout_axis = .Y;
			plus.cross_align = .Center;
			plus_hov := ui.signal(plus).hovering;
			{ ui.parent(plus); defer ui.pop_parent();
				spacer(.Y, (COMPOSER_H - 24) / 2);
				icon("i", "plus-large", 24, ifx plus_hov then T("--interactive-icon-hover") else T("--interactive-icon-default"));
			}
			spacer(.X, 24);
			placeholder := ifx ch.kind == .DM then fmt.tprintf("Message @%s", dm_name(ch)) else fmt.tprintf("Message #%s", ch.name);
			if ch.kind == .Group_DM { placeholder = fmt.tprintf("Message %s", dm_name(ch)); }
			// Up in an empty composer edits your last message, like the client
			if ui.editor_text(*cs.editor) == "" && ma.editing == 0 {
				for * e: app.ui.events {
					if e.consumed || e.kind != .Key_Down || e.key != .Up || e.mods != 0 { continue; }
					msgs := dc.messages_get(s, ch.id);
					for < * m: msgs {
						if m.author_id == s.me {
							start_edit(m);
							e.consumed = true;
							break;
						}
					}
				}
			}
			input_focused := (app.ui.focus == box.key || app.ui.focus == 0) && ma.editing == 0 && !sw.open && !modal_open();
			// Cmd/Ctrl+V with files or a bitmap on the clipboard stages them instead of pasting text
			if input_focused {
				for * e: app.ui.events {
					if e.consumed || e.kind != .Key_Down || e.key != .V || (e.mods & (.Shift | .Alt)) != 0 || !has(e.mods, PRIMARY_MOD) { continue; }
					if paste_attachments(ch.id) { e.consumed = true; }
				}
			}
			res := text_field("input", *cs.editor, placeholder, input_focused, pad_y = (COMPOSER_H - MSG_LINE_H) / 2, placeholder_color = T("--channel-text-area-placeholder"));
			if res == .Submit {
				text := strings.trim_space(ui.editor_text(*cs.editor));
				if composer_send(ch, emoji_convert_shortcodes(text)) { cs.scroll_target = 0; }
				ui.editor_set_text(*cs.editor, "");
			} else if res == .Escape {
				ma.replying = 0;
			} else if res == .Changed && app.client != null && ui.editor_text(*cs.editor) != "" {
				dc.typing_keystroke(app.client, ch.id);
			}
			for name: (string.["gif", "sticker", "reaction"]) {
				b := ui.box(name, .Clickable);
				b.semantic_size = .[ui.px(40), ui.px(COMPOSER_H)];
				b.layout_axis = .Y;
				b.cross_align = .Center;
				hov := picker_composer_button(name, ui.signal(b), b.rect, ch.id);
				{ ui.parent(b); defer ui.pop_parent();
					spacer(.Y, (COMPOSER_H - 24) / 2);
					icon("i", name, 24, ifx hov then T("--interactive-icon-hover") else T("--interactive-icon-default"));
				}
			}
			spacer(.X, 8);
		}
		ui.pop_parent(); // composer_stack
		spacer(.X, 8);
	}
	spacer(.Y, 8);
}
#scope_export

dm_name :: (ch: *dc.Channel) -> string {
	s := store();
	if ch.name != "" { return ch.name; }
	names := make_dynamic(string, 0, 0, temp);
	for id: ch.recipient_ids {
		{ name := dc.user_name(s, id);
		if name != "" { append(*names, name); } }
	}
	if len(names) == 0 && ch.kind == .Group_DM {
		// an unnamed group with nobody else in it: "<owner>'s Group", like the client
		owner := ifx ch.owner_id != 0 then ch.owner_id else s.me;
		{ name := dc.user_name(s, owner);
		if name != "" { return fmt.tprintf("%s's Group", name); } }
	}
	return strings.join(view(names), ", ", temp);
}

// Multi-line text field; grows with content. Returns the editor result of this frame's events.
text_field :: (id: string, ed: *ui.Editor, placeholder: string, focused: bool, font_size: float32 = 16, line_h: float32 = 22, pad_y: float32 = 15, placeholder_color: ui.Color = .{}) -> ui.Edit_Result {
	// Not .Focusable: callers decide focus by their container's key (the bordered
	// input box), so a click on the text itself must focus that container.
	f := ui.box(id, .Clickable | .Draw_Text | .Wrap_Text);
	f.semantic_size = .[ui.fill(), ui.text_size()];
	f.style.font = F(.Normal);
	f.style.font_size = font_size;
	f.style.line_height = line_h;
	f.style.padding = .{0, pad_y};
	f.hover_cursor = .IBeam;
	text := ui.editor_text(ed);
	f.text = text;
	f.style.text_color = T("--text-default");
	if text == "" {
		f.text = placeholder;
		f.style.text_color = ifx placeholder_color.w > 0 then placeholder_color else T("--text-muted");
	}
	result := ui.Edit_Result.None;
	sig := ui.signal(f);
	tl := f.text_layout;
	if text == "" { tl = null; }
	if sig.pressed {
		if f.parent != null { app.ui.focus = f.parent.key; }
		for e: app.ui.events {
			if e.kind == .Mouse_Down && e.button == .Left {
				ui.editor_mouse_down(ed, tl, e.pos, e.click_count, has(e.mods, .Shift));
				break;
			}
		}
	} else if sig.dragging {
		ui.editor_mouse_drag(ed, tl, app.ui.mouse);
	}
	if focused {
		note_focused_editor(ed, f);
		for * e: app.ui.events {
			if e.consumed { continue; }
			if e.kind != .Key_Down && e.kind != .Text { continue; }
			r := ui.editor_event(ed, e, tl, clipboard_get, clipboard_set);
			if r != .None {
				e.consumed = true;
				if r != .Moved || result == .None { result = r; }
			}
		}
		// caret + selection drawn over the field
		draw := new(Field_Draw, temp);
		draw.* = .{ed = ed, blink_t = app.ui.time};
		f.custom_draw = field_draw;
		f.custom_user = draw;
	}
	return result;
}

// True when tokens are only emoji (custom or unicode) and whitespace, at most 27.
is_emoji_only :: (toks: []Token) -> bool {
	n := 0;
	for tk: toks {
		if tk.kind == {
		case .Custom_Emoji;
			n += 1;
		case .Text;
			k, only := emoji_count(tk.text);
			if !only { return false; }
			n += k;
		case .Link; #through; case .User_Mention; #through; case .Role_Mention; #through; case .Channel_Mention; #through; case .Everyone; #through; case .Timestamp;
			return false;
		}
	}
	return n > 0 && n <= 27;
}

// Date separator ("October 25, 2026") and/or the red "NEW" unread line above a message.
divider_row :: (id: dc.Snowflake, new_day: bool, show_new: bool) {
	spacer(.Y, 8);
	d := row("divider");
	d.semantic_size = .[ui.pct(1), ui.px(16)];
	line_color := ifx show_new then T("--status-danger") else T("--border-subtle");
	{ ui.parent(d); defer ui.pop_parent();
		spacer(.X, 16);
		l1 := ui.box("l1", .Draw_Background);
		l1.semantic_size = .[ui.fill(), ui.px(1)];
		l1.style.bg = line_color;
		if new_day {
			spacer(.X, 8);
			ms := dc.snowflake_time_ms(id) + local_utc_offset_ms();
			t := time.unix(ms / 1000, 0);
			y, mo, dd := time.date(t);
			label(fmt.tprintf("%v %d, %d", mo, dd, y), .Semibold, 12, ifx show_new then T("--status-danger") else T("--text-muted"), 13);
			spacer(.X, 8);
			l2 := ui.box("l2", .Draw_Background);
			l2.semantic_size = .[ui.fill(), ui.px(1)];
			l2.style.bg = line_color;
		}
		if show_new {
			pill := row("new", .Draw_Background);
			pill.semantic_size = .[ui.children(), ui.px(14)];
			pill.style.bg = T("--status-danger");
			pill.style.radius = .[0, 4, 0, 4];
			{ ui.parent(pill); defer ui.pop_parent();
				spacer(.X, 4);
				label("NEW", .Bold, 10, .{1, 1, 1, 1}, 13);
				spacer(.X, 4);
			}
		}
		spacer(.X, 14);
	}
	spacer(.Y, 10); // official: the next item's top sits 18px below the divider line
}

// Any overlay that takes keyboard input away from the composer.
modal_open :: () -> bool {
	return sw.open || attachments_modal_open() || ma.deleting != 0 || app.settings_open || viewer_url != "" || block_confirm.user != 0 || invite_modal_open() || add_server_is_open() || events_modal_open() || guild_admin_modal_open() || fnick.user != 0;
}

