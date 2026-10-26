package app

import "core:fmt"
import "core:strings"
import "core:time"
import dc "fc:discord"
import "fc:platform"
import "fc:ui"

// Cozy message layout, measured from the official client.
MSG_GUTTER :: 72 // content x offset
MSG_AVATAR :: 40
MSG_GROUP_GAP :: 17 // space above the first message of a group
MSG_LINE_H :: 22
MSG_FONT :: 16
MSG_SCROLL_GUTTER :: 16
MSG_PAD_R :: 48 // content padding-right (room for the hover toolbar)
MSG_EDIT_PAD_R :: 23 // the inline edit form ends 23px from the item edge
MSG_CALL :: 3 // message type CALL
CALL_ROW_H :: 26 // call notice content row (official item: 2 + 26 + 2)
COMPOSER_H :: 58 // official form height (1px border included): 22px line + 18px padding
GROUP_WINDOW_MS :: 7 * 60 * 1000 // messages from the same author within 7 minutes group

Chat_State :: struct {
	scroll_from_bottom: f32, // 0 = stuck to the newest message
	scroll_target:      f32,
	heights:            map[dc.Snowflake]f32, // measured row heights
	loading_older:      bool,
	editor:             ui.Editor,
	hovered_msg:        dc.Snowflake,
	unread_after:       dc.Snowflake, // read marker when the channel was opened ("NEW" divider)
	opened:             bool,
}

chat_state :: proc(channel_id: dc.Snowflake) -> ^Chat_State {
	if cs, ok := &app.chats[channel_id]; ok do return cs
	app.chats[channel_id] = {}
	return &app.chats[channel_id]
}

// Groups with the previous message: same author, within 7 minutes, plain message type, not a reply.
@(private = "file")
continues_group :: proc(prev, m: ^dc.Message) -> bool {
	if prev == nil do return false
	if prev.author_id != m.author_id do return false
	if prev.kind == MSG_CALL do return false
	if m.referenced_id != 0 || (m.kind != 0 && m.kind != 19) do return false
	if dc.snowflake_time_ms(m.id) - dc.snowflake_time_ms(prev.id) > GROUP_WINDOW_MS do return false
	return day_of(prev.id) == day_of(m.id)
}

@(private = "file")
day_of :: proc(id: dc.Snowflake) -> i64 {
	ms := dc.snowflake_time_ms(id) + local_utc_offset_ms()
	return ms / 86_400_000
}

local_utc_offset_ms :: proc() -> i64 {
	return app.utc_offset_ms
}

// "3:04 PM" today, "Yesterday at 3:04 PM", or "10/24/2026 3:04 PM" — the client's calendar format.
format_timestamp :: proc(id: dc.Snowflake, short := false) -> string {
	ms := dc.snowflake_time_ms(id) + local_utc_offset_ms()
	now_ms := wall_ms() + local_utc_offset_ms()
	t := time.unix(ms / 1000, 0)
	h, mi, _ := time.clock_from_time(t)
	ampm := h >= 12 ? "PM" : "AM"
	h12 := h % 12
	if h12 == 0 do h12 = 12
	clock := fmt.tprintf("%d:%02d\u202f%s", h12, mi, ampm) // narrow no-break space, as Intl formats it
	if short do return clock
	day := ms / 86_400_000
	today := now_ms / 86_400_000
	switch day {
	case today:
		return clock
	case today - 1:
		return fmt.tprintf("Yesterday at %s", clock)
	}
	y, mo, d := time.date(t)
	return fmt.tprintf("%d/%d/%d %s", int(mo), d, y, clock)
}

// format_timestamp kept alive across frames: header timestamps are selectable,
// and a selection is read (copy, scripts) after the frame's temp memory is gone.
@(private = "file")
Stamp_Cache :: struct {
	day:   i64,
	texts: map[dc.Snowflake]string,
}
@(private = "file")
stamps: Stamp_Cache

// Unix ms now (or the -now: override).
wall_ms :: proc() -> i64 {
	if app.now_override_ms != 0 do return app.now_override_ms
	return time.time_to_unix_nano(time.now()) / 1e6
}

header_timestamp :: proc(id: dc.Snowflake) -> string {
	today := (wall_ms() + local_utc_offset_ms()) / 86_400_000
	if today != stamps.day {
		for _, v in stamps.texts do delete(v)
		clear(&stamps.texts)
		stamps.day = today
	}
	if s, ok := stamps.texts[id]; ok do return s
	s := strings.clone(format_timestamp(id))
	stamps.texts[id] = s
	return s
}

chat_view :: proc(channel_id: dc.Snowflake) {
	s := store()
	ch := dc.channel_get(s, channel_id)
	if ch == nil do return
	cs := chat_state(channel_id)
	if !cs.opened {
		cs.opened = true
		cs.unread_after = s.read_states[channel_id].last_message_id
	}
	// Ack what's on screen while focused and scrolled to the bottom, like the client.
	msgs := dc.messages_get(s, channel_id)
	if app.client != nil && app.focused && len(msgs) > 0 && cs.scroll_from_bottom < 2 {
		last := msgs[len(msgs) - 1].id
		if last > s.read_states[channel_id].last_message_id && !msgs[len(msgs) - 1].pending do dc.ack_message(app.client, channel_id, last)
	}

	picker_capture_input() // expression picker owns keys/wheel while open
	col := ui.box("chatcol")
	col.semantic_size = {.X = ui.fill(), .Y = ui.pct(1)}
	col.layout_axis = .Y
	if ui.parent(col) {
		message_list(channel_id, cs)
		typing_line(channel_id)
		composer(ch, cs)
	}
}

@(private = "file")
message_list :: proc(channel_id: dc.Snowflake, cs: ^Chat_State) {
	s := store()
	list := ui.box("messages", {.Clip, .Scroll_Y})
	list.semantic_size = {.X = ui.pct(1), .Y = ui.fill()}
	// Scrolling is managed here (anchored to the bottom), not by ui's scroll offset.
	list.flags -= {.Scroll_Y}
	msgs := dc.messages_get(s, channel_id)
	view_h := list.rect.y1 - list.rect.y0
	if view_h <= 0 do view_h = app.ui.window.y

	// wheel input over the list
	if ui.mouse_over(list) {
		for &e in app.ui.events {
			if e.kind != .Scroll || e.consumed do continue
			cs.scroll_target += e.delta.y
			e.consumed = true
		}
	}

	// dragging a text selection past the list edges scrolls, faster the further out
	if app.ui.selection.dragging && list.rect.y1 > list.rect.y0 {
		my := app.ui.mouse.y
		if my < list.rect.y0 + 24 {
			cs.scroll_target += ((list.rect.y0 + 24 - my) * 0.5 + 2) * app.ui.dt * 60
			app.ui.animating = true
		} else if my > list.rect.y1 - 24 {
			cs.scroll_target -= ((my - (list.rect.y1 - 24)) * 0.5 + 2) * app.ui.dt * 60
			app.ui.animating = true
		}
	}

	// total height from measured rows (estimates for unmeasured)
	TOP_PAD :: 16
	BOTTOM_PAD :: 8
	total: f32 = TOP_PAD + BOTTOM_PAD
	// the start of a 1:1 DM's history carries the welcome header (avatar, names, friend actions);
	// a guild text channel's carries "Welcome to #channel!"
	welcome_ch := dc.channel_get(s, channel_id)
	welcome_h: f32 = 0
	if welcome_ch != nil {
		l, ok := s.messages[channel_id]
		if !ok || l.has_more_before || l.loading do welcome_ch = nil
	}
	if welcome_ch != nil {
		#partial switch welcome_ch.kind {
		case .DM:
			if len(welcome_ch.recipient_ids) == 1 do welcome_h = DMW_H
		case .Guild_Text, .Guild_Announcement:
			welcome_h = channel_welcome_height(welcome_ch)
		}
		if welcome_h == 0 do welcome_ch = nil
	}
	if welcome_ch != nil do total += welcome_h + DMW_GAP - TOP_PAD
	for &m in msgs {
		h, ok := cs.heights[m.id]
		total += ok ? h : MSG_LINE_H + 4
	}
	max_scroll := max(0, total - view_h)
	jump_apply(channel_id, cs, msgs, view_h, BOTTOM_PAD)
	cs.scroll_target = clamp(cs.scroll_target, 0, max_scroll)
	ui.animate(&cs.scroll_from_bottom, cs.scroll_target, 40)
	cs.scroll_from_bottom = clamp(cs.scroll_from_bottom, 0, max_scroll)

	// load older history when within a screen of the top
	if total - cs.scroll_from_bottom - view_h < view_h && len(msgs) > 0 {
		l := s.messages[channel_id]
		if !l.loading && l.has_more_before && app.client != nil {
			dc.fetch_messages(app.client, channel_id, msgs[0].id)
		}
	}

	// Render the contiguous run of rows near the viewport as one column anchored
	// to the list's bottom edge. Its offset only depends on rows *below* it, so
	// at the bottom (the common case) placement is exact on the first frame and
	// rows never jump while their real heights get measured.
	est :: proc(cs: ^Chat_State, id: dc.Snowflake) -> f32 {
		h, ok := cs.heights[id]
		return ok ? h : MSG_LINE_H + 4
	}
	MARGIN :: 200
	i1 := len(msgs) - 1
	below: f32 = 0 // height of rows after i1
	for i1 >= 0 && below + est(cs, msgs[i1].id) < cs.scroll_from_bottom - MARGIN {
		below += est(cs, msgs[i1].id)
		i1 -= 1
	}
	i0 := i1
	span: f32 = 0
	for i0 >= 0 && below + span < cs.scroll_from_bottom + view_h + MARGIN {
		span += est(cs, msgs[i0].id)
		i0 -= 1
	}
	i0 += 1
	if ui.parent(list) {
		col := ui.box("rows", {.Floating_Y, .Anchor_End_Y})
		col.semantic_size = {.X = ui.pct(1), .Y = ui.children()}
		// items stop short of the scrollbar gutter (official: 375..1264 in a 905px list)
		if lw := list.rect.x1 - list.rect.x0; lw > MSG_SCROLL_GUTTER do col.semantic_size[.X] = ui.px(lw - MSG_SCROLL_GUTTER)
		col.layout_axis = .Y
		col.fixed_pos = {0, BOTTOM_PAD + below - cs.scroll_from_bottom}
		if ui.parent(col) {
			if i0 == 0 {
				if welcome_ch != nil {
					if welcome_ch.kind == .DM do dm_welcome(welcome_ch)
					else do channel_welcome(welcome_ch)
					spacer(.Y, DMW_GAP)
				} else {
					spacer(.Y, TOP_PAD)
				}
			}
			for i in max(i0, 0) ..= i1 {
				if i < 0 do break
				m := &msgs[i]
				prev: ^dc.Message = i > 0 ? &msgs[i - 1] : nil
				new_day := prev == nil || day_of(prev.id) != day_of(m.id)
				show_new := cs.unread_after != 0 && m.id > cs.unread_after && (prev == nil || prev.id <= cs.unread_after) && m.author_id != s.me
				grouped := continues_group(prev, m) && !show_new
				// consecutive call notices stack with no group gap
				if m.kind == MSG_CALL do grouped = prev != nil && prev.kind == MSG_CALL && !new_day && !show_new
				if ui.id_scope(u64(m.id)) {
					row := message_row(m, grouped, i, new_day, show_new)
					// remember measured height (from last frame's layout)
					if row.rect.y1 > row.rect.y0 do cs.heights[m.id] = row.rect.y1 - row.rect.y0
				}
			}
		}
	}
}

// One message: either a group start (avatar, name, time) or a continuation.
@(private = "file")
message_row :: proc(m: ^dc.Message, grouped: bool, index: int, new_day, show_new: bool) -> ^ui.Box {
	s := store()
	r0 := ui.box("msg")
	r0.semantic_size = {.X = ui.pct(1), .Y = ui.children()}
	r0.layout_axis = .Y
	editing := ma.editing == m.id
	if ui.parent(r0) {
		if new_day || show_new {
			divider_row(m.id, new_day, show_new)
		} else if !grouped {
			spacer(.Y, MSG_GROUP_GAP - 2)
		}
		// the list item proper: hover/highlight cover it, not the group gap above (a margin in the client)
		li := ui.box("li", {.Draw_Background})
		li.semantic_size = {.X = ui.pct(1), .Y = ui.children()}
		li.layout_axis = .Y
		ui.push_parent(li)
		defer ui.pop_parent()
		hovered := ui.mouse_over(li) && !app.ui.selection.dragging
		if hovered do app.chat_hover = m.id
		if (hovered || ma.menu_msg == m.id) && !editing do li.style.bg = T("--message-background-hover")
		highlighted := ma.replying == m.id || jump_highlighted(m.id)
		if highlighted {
			li.style.bg = T("--message-highlight-background-default")
			li.style.radius = {0, 4, 4, 0}
			bar := ui.box("hlbar", {.Draw_Background, .Floating_X, .Floating_Y})
			bar.semantic_size = {.X = ui.px(2), .Y = ui.px(li.rect.y1 - li.rect.y0)}
			bar.style.bg = T("--background-brand")
		}
		for e in app.ui.events {
			if e.kind == .Mouse_Down && e.button == .Right && hovered do open_message_menu(m, e.pos)
		}
		if (hovered || ma.menu_msg == m.id) && !editing && m.kind != MSG_CALL {
			// the toolbar hangs 16px above the item's top edge (official: top -16, right 14)
			anchor := ui.box("tbanchor")
			anchor.semantic_size = {.X = ui.pct(1), .Y = ui.px(0)}
			if ui.parent(anchor) do message_toolbar(m)
		}
		spacer(.Y, 2)
		if m.referenced_id != 0 {
			rr := row("replyrow")
			rr.semantic_size = {.X = ui.pct(1), .Y = ui.px(22)}
			if ui.parent(rr) {
				spacer(.X, MSG_GUTTER)
				reply_preview(m)
			}
		}
		if m.kind == MSG_CALL {
			call_notice(m)
			spacer(.Y, 2)
			return r0
		}
		body := row("body")
		body.semantic_size = {.X = ui.pct(1), .Y = ui.children()}
		body.cross_align = .Start
		if ui.parent(body) {
			gutter := ui.box("gutter")
			gutter.semantic_size = {.X = ui.px(MSG_GUTTER), .Y = ui.px(MSG_LINE_H)}
			if !grouped {
				if ui.parent(gutter) {
					av := avatar_box("avatar", m.author_id, MSG_AVATAR)
					av.flags += {.Floating_X, .Floating_Y}
					av.fixed_pos = {16, 2}
				}
			} else if hovered {
				gutter.layout_axis = .X
				gutter.cross_align = .Center
				if ui.parent(gutter) {
					filler(.X)
					label(format_timestamp(m.id, true), .Medium, 11, T("--text-muted"), MSG_LINE_H)
					spacer(.X, 8)
				}
			}
			content := ui.box("content")
			content.semantic_size = {.X = ui.fill(), .Y = ui.children()}
			content.layout_axis = .Y
			if ui.parent(content) {
				if !grouped do message_header(m)
				if editing do edit_box(m)
				else do message_body(m)
				if len(m.sticker_ids) > 0 do message_stickers_view(m)
				thread_summary_pill(m)
				if len(m.attachments) > 0 do attachments_view(m)
				if len(m.embeds) > 0 do embeds_view(m)
				if len(m.reactions) > 0 do reactions_view(m)
			}
			spacer(.X, editing ? MSG_EDIT_PAD_R : MSG_PAD_R) // the edit form reaches further right

		}
		spacer(.Y, 2)
	}
	_ = s
	_ = index
	return r0
}

// "Name started a call that lasted a few seconds. 4:43 AM" with a phone icon in the gutter.
@(private = "file")
call_notice :: proc(m: ^dc.Message) {
	s := store()
	r := row("call")
	r.semantic_size = {.X = ui.pct(1), .Y = ui.children()}
	r.cross_align = .Start
	if ui.parent(r) {
		g := ui.box("gutter")
		g.semantic_size = {.X = ui.px(MSG_GUTTER), .Y = ui.px(CALL_ROW_H)}
		if ui.parent(g) {
			ic := icon("phone", "phone", 16, T("--icon-feedback-positive"))
			ic.flags += {.Floating_X, .Floating_Y}
			ic.fixed_pos = {28, (CALL_ROW_H - 16) / 2}
		}
		name := "Unknown"
		if u := dc.user_get(s, m.author_id); u != nil do name = dc.display_name(u)
		what := " started a call."
		if m.call_ended != "" {
			start, _ := time.rfc3339_to_time_utc(m.timestamp)
			end, _ := time.rfc3339_to_time_utc(m.call_ended)
			what = fmt.tprintf(" started a call that lasted %s.", humanize_duration(time.diff(start, end)))
		}
		spans := make([]ui.Span, 3, context.temp_allocator)
		spans[0] = {text = name, font = F(.Medium), size = MSG_FONT, color = T("--text-strong")}
		spans[1] = {text = what, font = F(.Normal), size = MSG_FONT, color = T("--text-muted")}
		spans[2] = {text = fmt.tprintf(" %s", header_timestamp(m.id)), font = F(.Medium), size = 12, color = T("--chat-text-muted")}
		b := ui.box("text", {.Selectable_Text, .Wrap_Text})
		b.semantic_size = {.X = ui.fill(), .Y = ui.text_size()}
		b.style.line_height = MSG_LINE_H
		b.style.padding = {0, (CALL_ROW_H - MSG_LINE_H) / 2}
		ui.set_spans(b, spans)
		b.sel_order = u64(m.id) * 8 + 2
		spacer(.X, 48)
	}
}

// moment.js-style relative duration ("a few seconds", "a minute", "5 minutes", "an hour").
humanize_duration :: proc(d: time.Duration) -> string {
	secs := i64(time.duration_seconds(d))
	mins := (secs + 30) / 60
	hours := (mins + 30) / 60
	switch {
	case secs < 45:
		return "a few seconds"
	case secs < 90:
		return "a minute"
	case mins < 45:
		return fmt.tprintf("%d minutes", mins)
	case mins < 90:
		return "an hour"
	case hours < 22:
		return fmt.tprintf("%d hours", hours)
	case hours < 36:
		return "a day"
	}
	return fmt.tprintf("%d days", (hours + 12) / 24)
}

@(private = "file")
message_header :: proc(m: ^dc.Message) {
	s := store()
	u := dc.user_get(s, m.author_id)
	name := u != nil ? dc.display_name(u) : "Unknown"
	h := row("header")
	h.semantic_size = {.X = ui.pct(1), .Y = ui.px(MSG_LINE_H)}
	h.cross_align = .End
	if ui.parent(h) {
		n := label(name, .Medium, 16, author_color(m), MSG_LINE_H)
		n.flags += {.Clickable, .Selectable_Text}
		n.sel_order = u64(m.id) * 8
		nsig := ui.signal(n)
		if nsig.clicked do open_profile(m.author_id, n.rect)
		if nsig.right_clicked do open_user_menu(m.author_id, app.ui.mouse)
		spacer(.X, 8)
		// copies as "Name — 4:56 AM" like the client's hidden separator
		ts := label(header_timestamp(m.id), .Medium, 12, T("--chat-text-muted"), 20)
		ts.flags += {.Selectable_Text}
		ts.sel_order = u64(m.id) * 8 + 1
		ts.sel_join = " — "
	}
}

author_color :: proc(m: ^dc.Message) -> ui.Color {
	s := store()
	ch := dc.channel_get(s, m.channel_id)
	if ch != nil && ch.guild_id != 0 {
		if c, ok := member_color(ch.guild_id, m.author_id); ok do return c
	}
	return T("--text-strong")
}

// Highest-position colored role.
member_color :: proc(guild_id, user_id: dc.Snowflake) -> (ui.Color, bool) {
	s := store()
	mem := dc.member_get(s, guild_id, user_id)
	g := dc.guild_get(s, guild_id)
	if mem == nil || g == nil do return {}, false
	best := -1
	color: u32
	for rid in mem.roles {
		for r in g.roles {
			if r.id == rid && r.color != 0 && r.position > best {
				best = r.position
				color = r.color
			}
		}
	}
	if best < 0 do return {}, false
	return rgb_u32(color), true
}

rgb_u32 :: proc(c: u32) -> ui.Color {
	return {f32((c >> 16) & 0xff) / 255, f32((c >> 8) & 0xff) / 255, f32(c & 0xff) / 255, 1}
}

@(private = "file")
message_body :: proc(m: ^dc.Message) {
	if m.content == "" do return
	blocks := md_parse(m.content)
	edited_inline := false
	for blk, bi in blocks {
		color := T("--text-default")
		if m.pending do color = T("--text-muted")
		if m.failed do color = T("--text-feedback-critical")
		switch blk.kind {
		case .Code_Block:
			cb := ui.box(fmt.tprintf("code%d", bi), {.Draw_Background, .Draw_Border, .Draw_Text, .Selectable_Text, .Wrap_Text})
			cb.text = blk.code
			cb.semantic_size = {.X = ui.pct(1), .Y = ui.text_size()}
			cb.style.bg = T("--background-base-lowest")
			cb.style.border_color = T("--border-subtle")
			cb.style.border = 1
			cb.style.radius = 4
			cb.style.font = F(.Mono)
			cb.style.font_size = 14
			cb.style.line_height = 18
			cb.style.padding = {8, 8}
			cb.style.text_color = T("--text-code")
			cb.sel_order = u64(m.id) * 8 + 2 + u64(bi) % 4
		case .Paragraph, .Quote, .Heading1, .Heading2, .Heading3, .Subtext, .List_Item:
			size: f32 = MSG_FONT
			font := Font_Id.Normal
			line_h: f32 = MSG_LINE_H
			#partial switch blk.kind {
			case .Heading1:
				size, font, line_h = 24, .Bold, 33
			case .Heading2:
				size, font, line_h = 20, .Bold, 27.5
			case .Heading3:
				size, font, line_h = 16, .Bold, 22
			case .Subtext:
				size, line_h = 13, 18
				color = T("--text-muted")
			}
			// quotes get a 4px bar, list items a bullet; both indent the text
			wrap := row(fmt.tprintf("blk%d", bi))
			wrap.semantic_size = {.X = ui.pct(1), .Y = ui.children()}
			wrap.cross_align = .Start
			b: ^ui.Box
			if ui.parent(wrap) {
				#partial switch blk.kind {
				case .Quote:
					bar := ui.box("quotebar", {.Draw_Background})
					bar.semantic_size = {.X = ui.px(4), .Y = ui.px(line_h)}
					bar.style.bg = T("--border-strong")
					bar.style.radius = 4
					spacer(.X, 12)
				case .List_Item:
					spacer(.X, 6 + f32(blk.depth) * 20)
					label(blk.depth == 0 ? "•" : "◦", .Normal, size, color, line_h)
					spacer(.X, 8)
				}
				b = ui.box("p", {.Selectable_Text, .Wrap_Text})
				b.semantic_size = {.X = ui.fill(), .Y = ui.text_size()}
				b.style.text_color = color
				b.style.line_height = line_h
				spans := tokens_to_spans(blk.tokens, font, size, m)
				// jumbo: a message of only emoji (up to 27) renders them at 48px
				if len(blocks) == 1 && is_emoji_only(blk.tokens) {
					for &sp in spans {
						if sp.object != {} do sp.object = {48, 48}
						else do sp.size = 44
					}
					b.style.line_height = 56
				}
				if bi == len(blocks) - 1 && m.edited_timestamp != "" {
					// "(edited)" rides at the end of the last paragraph, like the client
					edited := make([]ui.Span, len(spans) + 1, context.temp_allocator)
					copy(edited, spans)
					edited[len(spans)] = {text = " (edited)", font = F(.Normal), size = 10, color = T("--text-muted")}
					spans = edited
					edited_inline = true
				}
				ui.set_spans(b, spans)
				b.sel_order = u64(m.id) * 8 + 2 + u64(bi) % 4
			}
			if b != nil && b.text_layout != nil do handle_span_clicks(b)
		}
	}
	if m.edited_timestamp != "" && !edited_inline {
		label("(edited)", .Normal, 10, T("--text-muted"), 22)
	}
}

// Mentions, links, emoji and inline styles become rich-text spans.
tokens_to_spans :: proc(toks: []Token, base: Font_Id, size: f32, m: ^dc.Message) -> []ui.Span {
	s := store()
	spans := make([dynamic]ui.Span, 0, len(toks), context.temp_allocator)
	for tk, i in toks {
		sp := ui.Span{text = tk.text, font = F(base), size = size, id = u64(i)}
		if .Bold in tk.styles do sp.font = F(.Bold)
		else if .Italic in tk.styles && base == .Normal do sp.font = F(.Italic)
		if .Code in tk.styles {
			sp.font = F(.Mono)
			sp.size = size * 0.85
			sp.bg = T("--background-code")
			sp.bg_radius = 4
		}
		if .Underline in tk.styles do sp.underline = true
		if .Strike in tk.styles do sp.strike = true
		if .Spoiler in tk.styles {
			sp.bg = T("--spoiler-hidden-background")
			sp.color = sp.bg
			sp.bg_radius = 4
		}
		switch tk.kind {
		case .Text:
			if .Code not_in tk.styles {
				emoji_text_spans(&spans, sp)
				continue
			}
		case .Link:
			sp.color = T("--text-link")
		case .User_Mention:
			name := "unknown-user"
			if u := dc.user_get(s, dc.Snowflake(tk.id)); u != nil do name = dc.display_name(u)
			sp.text = fmt.tprintf("@%s", name)
			sp.bg = T("--mention-background")
			sp.color = T("--mention-foreground")
			sp.bg_radius = 3
			sp.font = F(.Medium)
		case .Role_Mention, .Everyone:
			sp.bg = T("--mention-background")
			sp.color = T("--mention-foreground")
			sp.bg_radius = 3
			sp.font = F(.Medium)
			if tk.kind == .Role_Mention do sp.text = "@role"
		case .Channel_Mention:
			name := "unknown"
			if c := dc.channel_get(s, dc.Snowflake(tk.id)); c != nil do name = c.name
			sp.text = fmt.tprintf("#%s", name)
			sp.bg = T("--mention-background")
			sp.color = T("--mention-foreground")
			sp.bg_radius = 3
			sp.font = F(.Medium)
		case .Custom_Emoji:
			sp.object = {22, 22}
			sp.text = fmt.tprintf(":%s:", tk.name)
			sp.user = rawptr(uintptr(tk.id))
		case .Timestamp:
			sp.text = format_unix(i64(tk.id), tk.name)
			sp.bg = T("--background-mod-subtle")
			sp.bg_radius = 3
		}
		append(&spans, sp)
	}
	_ = m
	return spans[:]
}

format_unix :: proc(secs: i64, style: string) -> string {
	ms := secs * 1000 + local_utc_offset_ms()
	t := time.unix(ms / 1000, 0)
	y, mo, d := time.date(t)
	h, mi, _ := time.clock_from_time(t)
	h12 := h % 12
	if h12 == 0 do h12 = 12
	ampm := h >= 12 ? "PM" : "AM"
	switch style {
	case "t":
		return fmt.tprintf("%d:%02d %s", h12, mi, ampm)
	case "d":
		return fmt.tprintf("%d/%d/%d", int(mo), d, y)
	}
	return fmt.tprintf("%v %d, %d %d:%02d %s", mo, d, y, h12, mi, ampm)
}

@(private = "file")
handle_span_clicks :: proc(b: ^ui.Box) {
	// Clicks on links/mentions: resolved against last frame's layout position.
	for e in app.ui.events {
		if e.kind != .Mouse_Up || e.button != .Left || ui.has_selection() do continue
		si := ui.span_at(b.text_layout, e.pos)
		if si < 0 do continue
		_ = si
	}
}

@(private = "file")
attachments_view :: proc(m: ^dc.Message) {
	for &a, i in m.attachments {
		if is_video(&a) && a.width > 0 && a.height > 0 {
			w := f32(a.width)
			h := f32(a.height)
			sc := min(1, min(400 / w, 300 / h))
			video_attachment(&a, w * sc, h * sc)
			spacer(.Y, 4)
		} else if is_audio(&a) {
			audio_attachment(&a)
			spacer(.Y, 4)
		} else if a.width > 0 && a.height > 0 {
			// images scale to fit 400x300 like the client
			w := f32(a.width)
			h := f32(a.height)
			sc := min(1, min(400 / w, 300 / h))
			img := ui.box(fmt.tprintf("att%d", i), {.Draw_Background, .Clickable})
			img.semantic_size = {.X = ui.px(w * sc), .Y = ui.px(h * sc)}
			img.style.radius = 8
			img.style.bg = T("--background-mod-subtle")
			set_remote_image(img, attachment_image_url(&a, int(w * sc), int(h * sc)))
			if ui.signal(img).clicked do open_viewer(a.proxy_url != "" ? a.proxy_url : a.url, {a.width, a.height})
			spacer(.Y, 4)
		} else {
			f := row(fmt.tprintf("file%d", i), {.Draw_Background, .Draw_Border})
			f.semantic_size = {.X = ui.px(432), .Y = ui.px(72)}
			f.style.bg = T("--background-surface-high")
			f.style.border_color = T("--border-subtle")
			f.style.border = 1
			f.style.radius = 8
			if ui.parent(f) {
				spacer(.X, 16)
				icon("ficon", "attachment", 30, T("--interactive-icon-default"))
				spacer(.X, 8)
				col := ui.box("fcol")
				col.semantic_size = {.X = ui.fill(), .Y = ui.children()}
				if ui.parent(col) {
					label(a.filename, .Normal, 16, T("--text-link"), 20)
					label(human_size(a.size), .Normal, 12, T("--text-muted"), 16)
				}
			}
			spacer(.Y, 4)
		}
	}
}

human_size :: proc(n: int) -> string {
	switch {
	case n >= 1 << 20:
		return fmt.tprintf("%.2f MB", f64(n) / f64(1 << 20))
	case n >= 1 << 10:
		return fmt.tprintf("%.2f KB", f64(n) / f64(1 << 10))
	}
	return fmt.tprintf("%d bytes", n)
}

@(private = "file")
reactions_view :: proc(m: ^dc.Message) {
	r := row("reactions")
	r.semantic_size = {.X = ui.pct(1), .Y = ui.px(30)}
	r.style.child_gap = 4
	if ui.parent(r) {
		for &re, i in m.reactions {
			pill := row(fmt.tprintf("re%d", i), {.Clickable, .Draw_Background, .Draw_Border, .Hot_Animation})
			pill.semantic_size = {.X = ui.children(), .Y = ui.px(26)}
			pill.style.radius = 8
			pill.style.border = 1
			if re.me {
				pill.style.bg = T("--reaction-background-reacted-default")
				pill.style.border_color = T("--reaction-border-reacted-default")
			} else {
				pill.style.bg = T("--reaction-background-default")
				pill.style.bg_hot = T("--reaction-background-hover")
				pill.style.border_color = T("--reaction-border-default")
			}
			sig := ui.signal(pill)
			if ui.parent(pill) {
				spacer(.X, 6)
				emoji_box("e", re.emoji, 16)
				spacer(.X, 6)
				label(fmt.tprintf("%d", re.count), .Semibold, 14, re.me ? T("--reaction-text-reacted-default") : T("--reaction-text-default"), 16)
				spacer(.X, 6)
			}
			if sig.clicked && net_action() {
				if re.me {
					dc.remove_reaction(app.client, m.channel_id, m.id, re.emoji.name, re.emoji.id)
				} else {
					dc.add_reaction(app.client, m.channel_id, m.id, re.emoji.name, re.emoji.id)
				}
			}
		}
		reaction_add_button(m)
	}
	spacer(.Y, 2)
}

@(private = "file")
typing_line :: proc(channel_id: dc.Snowflake) {
	s := store()
	t := row("typing")
	t.semantic_size = {.X = ui.pct(1), .Y = ui.px(24)}
	typers := dc.typing_users(s, channel_id)
	if len(typers) == 0 do return
	if ui.parent(t) {
		spacer(.X, 16)
		names := make([dynamic]string, context.temp_allocator)
		for ty in typers {
			if ty.user_id == s.me do continue
			if u := dc.user_get(s, ty.user_id); u != nil do append(&names, dc.display_name(u))
		}
		if len(names) == 0 do return
		msg: string
		switch len(names) {
		case 1:
			msg = fmt.tprintf("%s is typing...", names[0])
		case 2:
			msg = fmt.tprintf("%s and %s are typing...", names[0], names[1])
		case 3:
			msg = fmt.tprintf("%s, %s, and %s are typing...", names[0], names[1], names[2])
		case:
			msg = "Several people are typing..."
		}
		typing_dots()
		spacer(.X, 4)
		label(msg, .Medium, 14, T("--text-default"), 24)
	}
}

// Three dots pulsing in sequence (the client's typing animation).
@(private = "file")
typing_dots :: proc() {
	r := row("dots")
	r.semantic_size = {.X = ui.px(24), .Y = ui.px(8)}
	if ui.parent(r) {
		for i in 0 ..< 3 {
			phase := f32(app.ui.time * 1.4) - f32(i) * 0.15
			k := 0.5 + 0.5 * f32(abs(fract(phase) * 2 - 1))
			d := ui.box(fmt.tprintf("d%d", i), {.Draw_Background})
			d.semantic_size = {.X = ui.px(6), .Y = ui.px(6)}
			d.style.radius = 3
			d.style.bg = with_alpha(T("--text-default"), 0.3 + 0.7 * k)
			spacer(.X, 2)
		}
	}
	app.ui.animating = true
}

fract :: proc(x: f32) -> f32 {return x - f32(int(x))}

@(private = "file")
composer :: proc(ch: ^dc.Channel, cs: ^Chat_State) {
	s := store()
	outer := row("composer_outer")
	outer.semantic_size = {.X = ui.pct(1), .Y = ui.children()}
	outer.cross_align = .Start
	if ui.parent(outer) {
		spacer(.X, 8)
		// one bordered form holds the reply bar, staged uploads and the text area
		stack := ui.box("composer_stack", {.Draw_Background, .Draw_Border})
		stack.semantic_size = {.X = ui.fill(), .Y = ui.children()}
		stack.layout_axis = .Y
		stack.style.bg = T("--chat-background-default")
		stack.style.border_color = T("--border-subtle")
		stack.style.border = 1
		stack.style.radius = 8
		ui.push_parent(stack)
		if ma.replying != 0 do reply_bar()
		uploads_bar()
		box := row("composer", {.Clickable})
		box.semantic_size = {.X = ui.fill(), .Y = ui.children()}
		box.cross_align = .Start
		box.hover_cursor = .IBeam
		if ui.signal(box).pressed do app.ui.focus = box.key
		if ui.parent(box) {
			spacer(.X, 16)
			plus := ui.box("plus", {.Clickable})
			if ui.signal(plus).clicked {
				for path in pick_files() do stage_upload(path)
			}
			plus.semantic_size = {.X = ui.px(24), .Y = ui.px(COMPOSER_H)}
			plus.layout_axis = .Y
			plus.cross_align = .Center
			plus_hov := ui.signal(plus).hovering
			if ui.parent(plus) {
				spacer(.Y, (COMPOSER_H - 24) / 2)
				icon("i", "plus-large", 24, plus_hov ? T("--interactive-icon-hover") : T("--interactive-icon-default"))
			}
			spacer(.X, 24)
			placeholder := ch.kind == .DM ? fmt.tprintf("Message @%s", dm_name(ch)) : fmt.tprintf("Message #%s", ch.name)
			if ch.kind == .Group_DM do placeholder = fmt.tprintf("Message %s", dm_name(ch))
			// Up in an empty composer edits your last message, like the client
			if ui.editor_text(&cs.editor) == "" && ma.editing == 0 {
				for &e in app.ui.events {
					if e.consumed || e.kind != .Key_Down || e.key != .Up || e.mods != {} do continue
					msgs := dc.messages_get(s, ch.id)
					#reverse for &m in msgs {
						if m.author_id == s.me {
							start_edit(&m)
							e.consumed = true
							break
						}
					}
				}
			}
			res := text_field("input", &cs.editor, placeholder, (app.ui.focus == box.key || app.ui.focus == 0) && ma.editing == 0 && !sw.open && !modal_open(), pad_y = (COMPOSER_H - MSG_LINE_H) / 2, placeholder_color = T("--channel-text-area-placeholder"))
			if res == .Submit {
				text := strings.trim_space(ui.editor_text(&cs.editor))
				if composer_send(ch, emoji_convert_shortcodes(text)) do cs.scroll_target = 0
				ui.editor_set_text(&cs.editor, "")
			} else if res == .Escape {
				ma.replying = 0
			} else if res == .Changed && app.client != nil && ui.editor_text(&cs.editor) != "" {
				dc.typing_keystroke(app.client, ch.id)
			}
			for name in ([]string{"gift", "gif", "sticker", "reaction", "apps"}) {
				b := ui.box(name, {.Clickable})
				b.semantic_size = {.X = ui.px(40), .Y = ui.px(COMPOSER_H)}
				b.layout_axis = .Y
				b.cross_align = .Center
				hov := picker_composer_button(name, ui.signal(b), b.rect, ch.id)
				if ui.parent(b) {
					spacer(.Y, (COMPOSER_H - 24) / 2)
					icon("i", name, 24, hov ? T("--interactive-icon-hover") : T("--interactive-icon-default"))
				}
			}
			spacer(.X, 8)
		}
		ui.pop_parent() // composer_stack
		spacer(.X, 8)
	}
	spacer(.Y, 8)
	_ = s
}

dm_name :: proc(ch: ^dc.Channel) -> string {
	s := store()
	if ch.name != "" do return ch.name
	names := make([dynamic]string, context.temp_allocator)
	for id in ch.recipient_ids {
		if u := dc.user_get(s, id); u != nil do append(&names, dc.display_name(u))
	}
	if len(names) == 0 && ch.kind == .Group_DM {
		// an unnamed group with nobody else in it: "<owner>'s Group", like the client
		owner := ch.owner_id != 0 ? ch.owner_id : s.me
		if u := dc.user_get(s, owner); u != nil do return fmt.tprintf("%s's Group", dc.display_name(u))
	}
	return strings.join(names[:], ", ", context.temp_allocator)
}

// Multi-line text field; grows with content. Returns the editor result of this frame's events.
text_field :: proc(id: string, ed: ^ui.Editor, placeholder: string, focused: bool, font_size: f32 = 16, line_h: f32 = 22, pad_y: f32 = 15, placeholder_color: ui.Color = {}) -> ui.Edit_Result {
	// Not .Focusable: callers decide focus by their container's key (the bordered
	// input box), so a click on the text itself must focus that container.
	f := ui.box(id, {.Clickable, .Draw_Text, .Wrap_Text})
	f.semantic_size = {.X = ui.fill(), .Y = ui.text_size()}
	f.style.font = F(.Normal)
	f.style.font_size = font_size
	f.style.line_height = line_h
	f.style.padding = {0, pad_y}
	f.hover_cursor = .IBeam
	text := ui.editor_text(ed)
	f.text = text
	f.style.text_color = T("--text-default")
	if text == "" {
		f.text = placeholder
		f.style.text_color = placeholder_color.a > 0 ? placeholder_color : T("--text-muted")
	}
	result := ui.Edit_Result.None
	sig := ui.signal(f)
	tl := f.text_layout
	if text == "" do tl = nil
	if sig.pressed {
		if f.parent != nil do app.ui.focus = f.parent.key
		for e in app.ui.events {
			if e.kind == .Mouse_Down && e.button == .Left {
				ui.editor_mouse_down(ed, tl, e.pos, e.click_count, .Shift in e.mods)
				break
			}
		}
	} else if sig.dragging {
		ui.editor_mouse_drag(ed, tl, app.ui.mouse)
	}
	if focused {
		note_focused_editor(ed, f)
		for &e in app.ui.events {
			if e.consumed do continue
			if e.kind != .Key_Down && e.kind != .Text do continue
			r := ui.editor_event(ed, e, tl, clipboard_get, clipboard_set)
			if r != .None {
				e.consumed = true
				if r != .Moved || result == .None do result = r
			}
		}
		// caret + selection drawn over the field
		draw := new(Field_Draw, context.temp_allocator)
		draw^ = {ed = ed, blink_t = app.ui.time}
		f.custom_draw = field_draw
		f.custom_user = draw
	}
	return result
}

// True when tokens are only emoji (custom or unicode) and whitespace, at most 27.
is_emoji_only :: proc(toks: []Token) -> bool {
	n := 0
	for tk in toks {
		switch tk.kind {
		case .Custom_Emoji:
			n += 1
		case .Text:
			k, only := emoji_count(tk.text)
			if !only do return false
			n += k
		case .Link, .User_Mention, .Role_Mention, .Channel_Mention, .Everyone, .Timestamp:
			return false
		}
	}
	return n > 0 && n <= 27
}

// Date separator ("October 25, 2026") and/or the red "NEW" unread line above a message.
divider_row :: proc(id: dc.Snowflake, new_day, show_new: bool) {
	spacer(.Y, 8)
	d := row("divider")
	d.semantic_size = {.X = ui.pct(1), .Y = ui.px(16)}
	line_color := show_new ? T("--status-danger") : T("--border-subtle")
	if ui.parent(d) {
		spacer(.X, 16)
		l1 := ui.box("l1", {.Draw_Background})
		l1.semantic_size = {.X = ui.fill(), .Y = ui.px(1)}
		l1.style.bg = line_color
		if new_day {
			spacer(.X, 8)
			ms := dc.snowflake_time_ms(id) + local_utc_offset_ms()
			t := time.unix(ms / 1000, 0)
			y, mo, dd := time.date(t)
			label(fmt.tprintf("%v %d, %d", mo, dd, y), .Semibold, 12, show_new ? T("--status-danger") : T("--text-muted"), 13)
			spacer(.X, 8)
			l2 := ui.box("l2", {.Draw_Background})
			l2.semantic_size = {.X = ui.fill(), .Y = ui.px(1)}
			l2.style.bg = line_color
		}
		if show_new {
			pill := row("new", {.Draw_Background})
			pill.semantic_size = {.X = ui.children(), .Y = ui.px(14)}
			pill.style.bg = T("--status-danger")
			pill.style.radius = {0, 4, 0, 4}
			if ui.parent(pill) {
				spacer(.X, 4)
				label("NEW", .Bold, 10, {1, 1, 1, 1}, 13)
				spacer(.X, 4)
			}
		}
		spacer(.X, 14)
	}
	spacer(.Y, 10) // official: the next item's top sits 18px below the divider line
}

// Any overlay that takes keyboard input away from the composer.
modal_open :: proc() -> bool {
	return sw.open || ma.deleting != 0 || app.settings_open || viewer_url != "" || block_confirm.user != 0
}
