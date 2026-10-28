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
MSG_PIN :: 6; // CHANNEL_PINNED_MESSAGE
MSG_FRIEND_ACCEPTED :: 67; // FRIEND_REQUEST_ACCEPTED (DMs)
MSG_RECIPIENT_ADD :: 1; // group DMs: added / removed / left, name and icon changes
MSG_RECIPIENT_REMOVE :: 2;
MSG_NAME_CHANGE :: 4;
MSG_ICON_CHANGE :: 5;
MSG_MEMBER_JOIN :: 7; // USER_JOIN: "Welcome, Name. We hope you brought pizza."

// Drawn as a one-line notice (system_notice), not a message with an avatar.
is_notice :: (kind: int) -> bool {
	return kind == MSG_CALL || kind == MSG_PIN || kind == MSG_MEMBER_JOIN || kind == MSG_FRIEND_ACCEPTED || (kind >= MSG_RECIPIENT_ADD && kind <= MSG_ICON_CHANGE);
}
CALL_ROW_H :: 26; // call notice content row (official item: 2 + 26 + 2)
COMPOSER_H :: 58; // official form height (1px border included): 22px line + 18px padding
GROUP_WINDOW_MS :: 7 * 60 * 1000; // messages from the same author within 7 minutes group

Chat_State :: struct {
	scroll_from_bottom: float32; // 0 = stuck to the newest message
	scroll_target: float32;
	heights: Table(dc.Snowflake, float32); // measured row heights
	height_sum: float32; // of heights: unmeasured rows are estimated at their average
	loading_older: bool;
	editor: ui.Editor;
	hovered_msg: dc.Snowflake;
	unread_after: dc.Snowflake; // read marker when the channel was opened ("NEW" divider)
	opened: bool;
}

chat_state :: (channel_id: dc.Snowflake) -> *Chat_State { return find_or_add(*app.chats, channel_id); }

local_utc_offset_ms :: () -> s64 { return app.utc_offset_ms; }

// "3:04 PM" today, "Yesterday at 3:04 PM", or "10/24/2026 3:04 PM" — the client's calendar format.
format_timestamp :: (id: dc.Snowflake, short := false) -> string {
	ms := dc.snowflake_time_ms(id) + local_utc_offset_ms();
	t := utc_calendar(ms);
	clock := tprint("%:%\u202f%", hour12(t), formatInt(t.minute, minimum_digits = 2), am_pm(t)); // narrow no-break space, as Intl formats it
	if short return clock;
	day := ms / 86_400_000;
	today := (wall_ms() + local_utc_offset_ms()) / 86_400_000;
	if day == today return clock;
	if day == today - 1 return tprint("Yesterday at %", clock);
	return tprint("%/%/% %", t.month_starting_at_0 + 1, t.day_of_month_starting_at_0 + 1, t.year, clock);
}

// "Tuesday, October 27, 2026 3:04 PM" (moment's LLLL): the tooltip on message times and "(edited)".
full_timestamp :: (unix_ms: s64) -> string {
	DAYS :: string.["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];
	t := utc_calendar(unix_ms + local_utc_offset_ms());
	return tprint("%, % %, % %:% %", DAYS[t.day_of_week_starting_at_0], MONTHS[t.month_starting_at_0], t.day_of_month_starting_at_0 + 1, t.year, hour12(t), formatInt(t.minute, minimum_digits = 2), am_pm(t));
}

// Unix ms now (or the -now: override).
wall_ms :: () -> s64 { return ifx app.now_override_ms then app.now_override_ms else dc.now_ms(); }

// format_timestamp kept alive across frames: header timestamps are selectable,
// and a selection is read (copy, scripts) after the frame's temp memory is gone.
header_timestamp :: (id: dc.Snowflake) -> string {
	today := (wall_ms() + local_utc_offset_ms()) / 86_400_000;
	if today != stamps.day {
		for stamps.texts free(it);
		table_reset_keeping_memory(*stamps.texts);
		stamps.day = today;
	}
	p, added := find_or_add(*stamps.texts, id);
	if added p.* = copy_string(format_timestamp(id));
	return p.*;
}

chat_view :: (channel_id: dc.Snowflake) {
	s := store();
	ch := dc.channel_get(s, channel_id);
	if ch == null return;
	cs := chat_state(channel_id);
	// at local midnight "3:04 PM" becomes "Yesterday at 3:04 PM" and the day dividers move on
	request_wake(platform.time_now() + cast(float64) (86400 - (wall_ms() + local_utc_offset_ms()) / 1000 % 86400) + 1);
	rs := table_find_pointer(*s.read_states, channel_id);
	last_read := ifx rs then rs.last_message_id else 0;
	held := rs != null && rs.manual; // Mark Unread: the "NEW" line moves there and nothing is acked
	if !cs.opened || held {
		cs.opened = true;
		cs.unread_after = last_read;
	}
	// Ack what's on screen while focused, not idle and scrolled to the bottom, like the client.
	msgs := dc.messages_get(s, channel_id);
	if app.client && app.focused && !app.client.idle_sent && msgs && cs.scroll_from_bottom < 2 && !held {
		// ack({messageId: undefined}) acks the read state's lastMessageId: the channel's newest
		newest := ch.last_message_id;
		for < msgs if !it.pending { newest = max(newest, it.id); break; }
		if newest > last_read dc.ack_message(app.client, channel_id, newest, location = ifx app.focus_gained then dc.ACK_WINDOW_FOCUS else dc.ACK_CHANNEL_SCROLL);
	}

	picker_capture_input(); // expression picker owns keys/wheel while open
	col := ui.box("chatcol");
	col.semantic_size = .[ui.fill(), ui.pct(1)];
	col.layout_axis = .Y;
	{ ui.parent(col); defer ui.pop_parent();
		message_list(channel_id, cs);
		composer(ch, cs);
	}
}

// moment.js-style relative duration ("a few seconds", "a minute", "5 minutes", "an hour").
humanize_duration :: (ms: s64) -> string {
	secs := ms / 1000;
	mins := (secs + 30) / 60;
	hours := (mins + 30) / 60;
	if secs < 45 return "a few seconds";
	if secs < 90 return "a minute";
	if mins < 45 return tprint("% minutes", mins);
	if mins < 90 return "an hour";
	if hours < 22 return tprint("% hours", hours);
	if hours < 36 return "a day";
	return tprint("% days", (hours + 12) / 24);
}

author_color :: (m: *dc.Message) -> ui.Color {
	ch := dc.channel_get(store(), m.channel_id);
	if ch && ch.guild_id {
		c, ok := member_color(ch.guild_id, m.author_id);
		if ok return c;
	}
	return T("--text-strong");
}

// Highest-position colored role.
member_color :: (guild_id: dc.Snowflake, user_id: dc.Snowflake) -> ui.Color, bool {
	s := store();
	mem := dc.member_get(s, guild_id, user_id);
	g := dc.guild_get(s, guild_id);
	if mem == null || g == null return .{}, false;
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
	if best < 0 return .{}, false;
	return rgb_u32(color), true;
}

rgb_u32 :: (c: u32) -> ui.Color {
	return .{cast(float32) ((c >> 16) & 0xff) / 255, cast(float32) ((c >> 8) & 0xff) / 255, cast(float32) (c & 0xff) / 255, 1};
}

// Mentions, links, emoji and inline styles become rich-text spans. raw (the composer) keeps
// every token's source text, styles only, and appends to `into`.
tokens_to_spans :: (toks: []Token, base: Font_Id, size: float32, m: *dc.Message, raw := false, into: *[..]ui.Span = null) -> []ui.Span {
	s := store();
	own: [..]ui.Span;
	own.allocator = temp;
	spans := ifx into then into else *own;
	array_reserve(spans, spans.count + toks.count);
	for tk, i: toks {
		sp := ui.Span.{text = tk.text, font = F(base), size = size, id = cast(u64) i};
		hidden := false;
		if tk.styles & .Bold sp.font = F(.Bold);
		else if (tk.styles & .Italic) && base == .Normal sp.font = F(.Italic);
		if tk.styles & .Code {
			sp.font = F(.Mono);
			sp.size = size * 0.85;
			sp.bg = T("--background-code");
			sp.bg_radius = 4;
		}
		if tk.styles & .Underline sp.underline = true;
		if tk.styles & .Strike sp.strike = true;
		if tk.styles & .Spoiler {
			sp.bg_radius = 4;
			if raw || spoiler_revealed(toks, i) {
				sp.bg = T("--spoiler-revealed-background");
			} else {
				sp.bg = T("--spoiler-hidden-background");
				sp.color = sp.bg;
				hidden = true;
			}
		}
		if raw && tk.kind != .Text {
			if tk.kind == .Link sp.color = T("--text-link");
			array_add(spans, sp);
			continue;
		}
		if tk.kind == {
		case .Text;
			if !(tk.styles & .Code) {
				first := spans.count;
				emoji_text_spans(spans, sp);
				// hidden emoji keep their place but draw nothing (only the spoiler's block shows)
				if hidden for k: first..spans.count - 1 { e := *(spans.*)[k]; e.user = null; e.id &= ~EMOJI_SPAN_FLAG; e.bg = sp.bg; e.bg_radius = sp.bg_radius; }
				continue;
			}
		case .Link;
			sp.color = T("--text-link");
		case .User_Mention;
			sp.text = tprint("@%", name_in(tk.id, ifx m then m.channel_id else 0, "unknown-user"));
			sp.bg = T("--mention-background");
			sp.color = T("--mention-foreground");
			sp.bg_radius = 3;
			sp.font = F(.Medium);
		case .Role_Mention; #through; case .Everyone;
			sp.bg = T("--mention-background");
			sp.color = T("--mention-foreground");
			sp.bg_radius = 3;
			sp.font = F(.Medium);
			if tk.kind == .Role_Mention sp.text = "@role";
		case .Channel_Mention;
			c := dc.channel_get(s, tk.id);
			sp.text = tprint("#%", ifx c then c.name else "unknown");
			sp.bg = T("--mention-background");
			sp.color = T("--mention-foreground");
			sp.bg_radius = 3;
			sp.font = F(.Medium);
		case .Custom_Emoji;
			sp.object = emoji_object(22, size);
			sp.text = tprint(":%:", tk.name);
			if !hidden sp.user = cast(*void) tk.id;
		case .Timestamp;
			sp.text = format_unix(cast(s64) tk.id, tk.name);
			sp.bg = T("--background-mod-subtle");
			sp.bg_radius = 3;
		}
		array_add(spans, sp);
	}
	return spans.*;
}

// Span id of a quote line's "> ": drawn as the quote bar (draw_custom_emoji).
QUOTE_BAR_SPAN_FLAG :: (cast(u64) 1) << 61;

// The composer's text styled the way the official (Slate) composer decorates markdown while
// typing: markers stay, dimmed; ``` lines dim their ticks and show the language in green;
// lines inside a block are code (highlighted); "> " lines become quotes. Headings, lists and
// masked links stay plain there. The span texts concatenate to exactly the editor's text, so
// the caret, selection and hit tests work on its bytes.
composer_spans :: (text: string) -> []ui.Span {
	spans: [..]ui.Span;
	spans.allocator = temp;
	base := ui.Span.{font = F(.Normal), size = MSG_FONT};
	lines := md_code_lines(text);
	for ln, li: lines {
		prev_inside := li > 0 && lines[li - 1].inside;
		if li > 0 && !(ln.inside && prev_inside) {
			nl := base;
			nl.text = slice(text, ln.start - 1, 1);
			array_add(*spans, nl);
		}
		line := slice(text, ln.start, ln.end - ln.start);
		if ln.inside {
			// a block's lines are highlighted together (comments and strings span lines)
			if prev_inside continue;
			last := li;
			while last + 1 < lines.count && lines[last + 1].inside last += 1;
			o := Hl_Out.{keep_escapes = true};
			hl_begin(*o, text, *spans, .{font = F(.Mono), size = MSG_FONT * 0.85});
			hl_range(*o, hl_lang(ln.lang), ln.start, lines[last].end);
			continue;
		}
		if ln.ticks {
			// ``` in the syntax colour, the language after the last one in green
			i, seg := 0, 0;
			while i < line.count {
				if line[i] == #char "\\" { i += 2; continue; }
				if !begins_with(slice(line, i, line.count - i), "```") { i += 1; continue; }
				composer_inline(*spans, slice(line, seg, i - seg), base);
				t := base;
				t.text = slice(line, i, 3);
				t.color = T("--textbox-markdown-syntax");
				array_add(*spans, t);
				i += 3;
				seg = i;
			}
			tail := slice(line, seg, line.count - seg);
			if is_lang_name(tail) {
				t := base;
				t.text = tail;
				t.color = T("--text-feedback-positive");
				array_add(*spans, t);
			} else {
				composer_inline(*spans, tail, base);
			}
			continue;
		}
		t := trim_left(line, " \t");
		if begins_with(t, "> ") {
			n := line.count - t.count + 2;
			q := base;
			q.text = slice(line, 0, n);
			q.object = .{16, MSG_LINE_H};
			q.id = QUOTE_BAR_SPAN_FLAG;
			array_add(*spans, q);
			line = slice(line, n, line.count - n);
		}
		if begins_with(line, "-# ") {
			// subtext: a bold marker and the line in muted 13px
			n := 3;
			while n < line.count && line[n] == #char " " n += 1;
			mk := base;
			mk.text = slice(line, 0, n);
			mk.font = F(.Bold);
			mk.size = 13;
			mk.color = T("--text-muted");
			array_add(*spans, mk);
			sub := base;
			sub.size = 13;
			sub.color = T("--text-muted");
			composer_inline(*spans, slice(line, n, line.count - n), sub);
		} else {
			composer_inline(*spans, line, base);
		}
	}
	return spans;
}

// Inline markdown of one line: tokens styled as in messages (raw text), and the bytes between
// them (the markers) in the syntax colour: semibold, except ~~ || __ (normal weight, __
// underlined) and ` (code font and background).
composer_inline :: (out: *[..]ui.Span, seg: string, base: ui.Span) {
	if !seg return;
	first := out.count;
	toks := md_inline(seg, merge = false);
	markers :: (g: string) #expand {
		i := 0;
		while i < g.count {
			j := i + 1;
			while j < g.count && g[j] == g[i] j += 1;
			sp := `base;
			sp.text = slice(g, i, j - i);
			c := g[i];
			if c != #char " " && c != #char "\t" {
				sp.color = T("--textbox-markdown-syntax");
				sp.font = F(.Semibold);
				if c == #char "`" {
					sp.font = F(.Mono);
					sp.size = `base.size * 0.85;
					sp.bg = T("--background-code");
					sp.bg_radius = 4;
				} else if c == #char "~" || c == #char "|" {
					sp.font = F(.Normal);
				} else if c == #char "_" && j - i == 2 {
					sp.font = F(.Normal);
					sp.underline = true;
				}
			}
			array_add(`out, sp);
			i = j;
		}
	}
	pos := 0;
	for tk, ti: toks {
		off := tk.text.data - seg.data;
		if off < pos || off + tk.text.count > seg.count {
			// not slices in order (never expected): the line as plain text
			out.count = first;
			sp := base;
			sp.text = seg;
			array_add(out, sp);
			return;
		}
		if off > pos markers(slice(seg, pos, off - pos));
		tokens_to_spans(array_view(toks, ti, 1), .Normal, base.size, null, raw = true, into = out);
		pos = off + tk.text.count;
	}
	if pos < seg.count markers(slice(seg, pos, seg.count - pos));
	if base.color.w > 0 for first..out.count - 1 {
		sp := *(out.*)[it];
		if sp.color.w == 0 sp.color = base.color;
	}
}

// Enter and Tab in a markdown field, as the official composer handles them: Enter adds a
// newline (instead of sending) inside a ``` block or with Alt; Tab in code lines indents.
markdown_key :: (ed: *ui.Editor, e: ui.Input_Event) -> bool {
	if e.key == .Enter {
		if e.mods & .Shift return false; // the editor's own newline
		a := ui.editor_sel(ed);
		if !(e.mods & .Alt) && !md_in_code_block(ui.editor_text(ed), a) return false;
		ui.editor_insert(ed, "\n");
		return true;
	}
	if e.key != .Tab || (e.mods & ~ui.Mod.Shift) return false;
	shift := (e.mods & .Shift) != 0;
	text := ui.editor_text(ed);
	a, b := ui.editor_sel(ed);
	lines := md_code_lines(text);
	first, last := -1, -1;
	for lines {
		if first < 0 && a <= it.end first = it_index;
		if b <= it.end { last = it_index; break; }
	}
	if first < 0 || last < 0 return false;
	for first..last if !lines[it].inside return false;
	// collapsed: two spaces at the caret; else each line indents (or outdents) by two spaces
	if !shift && a == b {
		ui.editor_insert(ed, "  ");
		return true;
	}
	sb: String_Builder;
	sb.allocator = temp;
	caret, mark := ed.caret, ed.mark;
	pos := 0;
	for k: first..last {
		ln := lines[k];
		append(*sb, slice(text, pos, ln.start - pos));
		pos = ln.start;
		if !shift {
			append(*sb, "  ");
			if ed.caret > ln.start caret += 2;
			if ed.mark > ln.start mark += 2;
		} else if begins_with(slice(text, ln.start, ln.end - ln.start), "  ") {
			pos += 2;
			caret -= clamp(ed.caret - ln.start, 0, 2);
			mark -= clamp(ed.mark - ln.start, 0, 2);
		}
	}
	append(*sb, slice(text, pos, text.count - pos));
	ui.editor_apply(ed, builder_to_string(*sb,, temp), caret, mark);
	return true;
}

format_unix :: (secs: s64, style: string) -> string {
	t := utc_calendar(secs * 1000 + local_utc_offset_ms());
	clock := tprint("%:% %", hour12(t), formatInt(t.minute, minimum_digits = 2), am_pm(t));
	date := tprint("% %, %", MONTHS[t.month_starting_at_0], t.day_of_month_starting_at_0 + 1, t.year);
	if style == {
	case "t";
		return clock;
	case "T";
		return tprint("%:%:% %", hour12(t), formatInt(t.minute, minimum_digits = 2), formatInt(t.second, minimum_digits = 2), am_pm(t));
	case "d";
		return tprint("%/%/%", t.month_starting_at_0 + 1, t.day_of_month_starting_at_0 + 1, t.year);
	case "D";
		return date;
	case "F";
		return full_timestamp(secs * 1000);
	case "R";
		request_wake(platform.time_now() + 30); // "in 4 hours" moves on while the window is idle
		return relative_time(secs - wall_ms() / 1000);
	}
	return tprint("% %", date, clock);
}

// moment's fromNow, which the client's "R" style uses: "in 3 hours", "a minute ago".
relative_time :: (delta_secs: s64) -> string {
	s := abs(delta_secs);
	m, h, d := (s + 30) / 60, (s + 1800) / 3600, (s + 43200) / 86400;
	text: string;
	if s < 45 text = "a few seconds";
	else if s < 90 text = "a minute";
	else if m < 45 text = tprint("% minutes", m);
	else if m < 90 text = "an hour";
	else if h < 22 text = tprint("% hours", h);
	else if h < 36 text = "a day";
	else if d < 26 text = tprint("% days", d);
	else if d < 45 text = "a month";
	else if d < 320 text = tprint("% months", (d + 15) / 30);
	else if d < 548 text = "a year";
	else text = tprint("% years", (d + 182) / 365);
	return ifx delta_secs > 0 then tprint("in %", text) else tprint("% ago", text);
}

// Spoilers revealed by a click, keyed by where their run of tokens starts in the
// message text (stable while the message is kept; an edit hides them again).
revealed_spoilers: Table(u64, bool);

spoiler_key :: (toks: []Token, i: int) -> u64 {
	while i > 0 && (toks[i - 1].styles & .Spoiler) i -= 1;
	return cast(u64) toks[i].text.data;
}

spoiler_revealed :: (toks: []Token, i: int) -> bool {
	return table_find_pointer(*revealed_spoilers, spoiler_key(toks, i)) != null;
}

EDITED_SPAN : u64 : 0xffff_ffff_ffff_fff0; // the trailing " (edited)" span's id; no token index reaches it

// Clicks on links / mentions in a paragraph, and the hover tooltips of <t:> times and
// "(edited)", against last frame's layout of the box (spans carry their token index in id).
handle_span_clicks :: (b: *ui.Box, toks: []Token, message_id: dc.Snowflake = 0, edited_ms: s64 = 0) {
	tl := b.prev_layout;
	if tl == null || !tl.spans return;
	if ui.mouse_over(b) {
		si := ui.span_at(tl, app.ui.mouse);
		id := ifx si >= 0 && si < tl.spans.count then tl.spans[si].id else EDITED_SPAN + 1;
		p := app.ui.mouse;
		r := ui.Rect.{p.x, p.y, p.x, p.y + 8};
		if id == EDITED_SPAN && edited_ms {
			tooltip_below(full_timestamp(edited_ms), r);
		} else if id < cast(u64) toks.count && toks[id].kind == .Timestamp {
			tooltip_below(full_timestamp(cast(s64) toks[id].id * 1000), r);
		}
	}
	for e: app.ui.events {
		if e.kind != .Mouse_Up || e.button != .Left || e.consumed || ui.has_selection() || ui.overlay_at(e.pos) continue;
		si := ui.span_at(tl, e.pos);
		if si < 0 || si >= tl.spans.count continue;
		ti := cast(int) tl.spans[si].id;
		if ti < 0 || ti >= toks.count continue;
		tk := toks[ti];
		if (tk.styles & .Spoiler) && !spoiler_revealed(toks, ti) {
			// the first click only reveals (a link inside isn't followed)
			table_set(*revealed_spoilers, spoiler_key(toks, ti), true);
			platform.request_frame();
			continue;
		}
		if tk.kind == {
		case .Link;
			url := ifx tk.url then tk.url else tk.text;
			code := invite_link_code(url);
			ch, msg := message_link(url);
			if code != "" invite_link_clicked(code, message_id);
			else if ch && msg jump_to_message(ch.id, msg);
			else if ch select_channel(ch.guild_id, ch.id);
			else open_url(url);
		case .User_Mention;
			r := ui.Rect.{e.pos.x, e.pos.y - 10, e.pos.x + 1, e.pos.y + 10};
			open_profile(tk.id, r);
		case .Channel_Mention;
			c := dc.channel_get(store(), tk.id);
			if c select_channel(c.guild_id, c.id);
		}
	}
}

human_size :: (n: int) -> string {
	if n >= 1 << 20 return tprint("% MB", formatFloat(cast(float64) n / (1 << 20), trailing_width = 2, zero_removal = .NO));
	if n >= 1 << 10 return tprint("% KB", formatFloat(cast(float64) n / (1 << 10), trailing_width = 2, zero_removal = .NO));
	return tprint("% bytes", n);
}

fract :: (x: float32) -> float32 { return x - cast(float32) cast(int) x; }

dm_name :: (ch: *dc.Channel) -> string {
	s := store();
	if ch.name return ch.name;
	names: [..]string;
	names.allocator = temp;
	for ch.recipient_ids {
		name := dc.user_name(s, it);
		if name array_add(*names, name);
	}
	if !names && ch.kind == .Group_DM {
		// an unnamed group with nobody else in it: "<owner>'s Group", like the client
		name := dc.user_name(s, ifx ch.owner_id then ch.owner_id else s.me);
		if name return tprint("%'s Group", name);
	}
	return join(..names, separator = ", ",, temp);
}

// Multi-line text field; grows with content. Returns the editor result of this frame's events.
// markdown: styled as the composer (composer_spans) with its Enter / Tab rules (markdown_key).
text_field :: (id: string, ed: *ui.Editor, placeholder: string, focused: bool, font_size: float32 = 16, line_h: float32 = 22, pad_y: float32 = 15, placeholder_color: ui.Color = .{}, markdown := false) -> ui.Edit_Result {
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
	tl := f.prev_layout; // this frame's is laid out after the events are handled
	if text == "" tl = null;
	if sig.pressed {
		if f.parent app.ui.focus = f.parent.key;
		ui.selection_clear(); // a press in a field drops the page's selection, as in a browser
		for e: app.ui.events {
			if e.kind == .Mouse_Down && e.button == .Left {
				ui.editor_mouse_down(ed, tl, e.pos, e.click_count, (e.mods & .Shift) != 0);
				break;
			}
		}
	} else if sig.dragging {
		ui.editor_mouse_drag(ed, tl, app.ui.mouse);
	}
	if sig.right_clicked open_edit_menu(ed, f);
	if focused {
		note_focused_editor(ed, f);
		for * e: app.ui.events {
			if e.consumed || (e.kind != .Key_Down && e.kind != .Text) continue;
			if markdown && e.kind == .Key_Down && markdown_key(ed, e) {
				e.consumed = true;
				result = .Changed;
				continue;
			}
			r := ui.editor_event(ed, e, tl, clipboard_get, clipboard_set);
			if r != .None {
				e.consumed = true;
				if r != .Moved || result == .None result = r;
			}
		}
		// caret + selection drawn over the field
		draw := New(Field_Draw,, temp);
		draw.* = .{ed = ed, blink_t = app.ui.time};
		f.custom_draw = field_draw;
		f.custom_user = draw;
	}
	// styled from the text as this frame's events left it
	if markdown && ui.editor_text(ed) != "" {
		ui.set_spans(f, composer_spans(ui.editor_text(ed)));
		f.style.text_color = T("--text-default");
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
			if !only return false;
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
			t := utc_calendar(dc.snowflake_time_ms(id) + local_utc_offset_ms());
			label(tprint("% %, %", MONTHS[t.month_starting_at_0], t.day_of_month_starting_at_0 + 1, t.year), .Semibold, 12, ifx show_new then T("--status-danger") else T("--text-muted"), 13);
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
	return sw.open || attachments_modal_open() || ma.confirming != 0 || app.settings_open || viewer_url != "" || block_confirm.user != 0 || invite_modal_open() || invite_accept_open() || add_server_is_open() || events_modal_open() || guild_admin_modal_open() || fnick.user != 0 || tsg.channel != 0;
}

// The hover toolbar drawn this pass, and the one from the pass before (rows test the
// mouse against it: it floats above its own row).
Chat_Toolbar :: struct { msg: dc.Snowflake; rect: ui.Rect; }
chat_toolbar, chat_toolbar_prev: Chat_Toolbar;

// A blockquote's 4px rounded bar down the left of its row.
// A discord.com/channels/<guild or @me>/<channel>[/<message>] link to a channel we have; else null.
message_link :: (url: string) -> *dc.Channel, dc.Snowflake {
	u := url;
	if !(begins_with_nocase(u, "https://") || begins_with_nocase(u, "http://")) return null, 0;
	advance(*u, find_index_from_left(u, "//") + 2);
	slash := find_index_from_left(u, #char "/");
	if slash < 0 return null, 0;
	host := to_lower_copy(slice(u, 0, slash),, temp);
	if begins_with(host, "ptb.") advance(*host, 4);
	else if begins_with(host, "canary.") advance(*host, 7);
	if host != "discord.com" && host != "discordapp.com" return null, 0;
	advance(*u, slash);
	if !begins_with(u, "/channels/") return null, 0;
	parts := split(advance(u, "/channels/".count), "/",, temp);
	if parts.count < 2 return null, 0;
	cid, ok := string_to_int(parts[1], T = u64);
	if !ok return null, 0;
	ch := dc.channel_get(store(), cid);
	if !ch return null, 0;
	mid: u64;
	if parts.count >= 3 mid = string_to_int(parts[2], T = u64);
	return ch, mid;
}

quote_bar_draw :: (b: *ui.Box, user: *void) {
	c := T("--border-strong");
	c.w *= b.opacity;
	gfx.rect(.{b.rect.x0, b.rect.y0, b.rect.x0 + 4, b.rect.y1}, cast(gfx.Color) c, 2);
}

// ms is already shifted to local time, so the UTC breakdown is the local one.
utc_calendar :: (ms: s64) -> Calendar_Time { return to_calendar(dc.UNIX_EPOCH + seconds_to_apollo(ms / 1000)); }
hour12 :: (t: Calendar_Time) -> int { h := t.hour % 12; return ifx h then h else 12; }
am_pm :: (t: Calendar_Time) -> string { return ifx t.hour >= 12 then "PM" else "AM"; }

// A search, pins or inbox card's text: the chat's blocks, with the search terms highlighted.
card_body :: (m: *dc.Message, terms: []string) { message_body(m, terms); }

shown_hidden: Table(dc.Snowflake, bool); // blocked or ignored authors' messages revealed this session

// "blocked" or "ignored" while m's author is and the message isn't revealed, else "".
hidden_kind :: (m: *dc.Message) -> string {
	r := table_find_pointer(*store().relationships, m.author_id);
	if !r || table_contains(*shown_hidden, m.id) return "";
	if r.kind == .Blocked return "blocked";
	if r.ignored return "ignored";
	return "";
}

#scope_file

stamps: struct {
	day: s64;
	texts: Table(dc.Snowflake, string);
};

MONTHS :: string.["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"];

// Groups with the previous message: same author, within 7 minutes, plain message type, not a reply.
continues_group :: (prev: *dc.Message, m: *dc.Message) -> bool {
	if prev == null || prev.author_id != m.author_id || is_notice(prev.kind) return false;
	if m.referenced_id != 0 || (m.kind != 0 && m.kind != 19) return false;
	if dc.snowflake_time_ms(m.id) - dc.snowflake_time_ms(prev.id) > GROUP_WINDOW_MS return false;
	return day_of(prev.id) == day_of(m.id);
}

day_of :: (id: dc.Snowflake) -> s64 {
	return (dc.snowflake_time_ms(id) + local_utc_offset_ms()) / 86_400_000;
}

message_list :: (channel_id: dc.Snowflake, cs: *Chat_State) {
	s := store();
	chat_toolbar_prev = chat_toolbar;
	chat_toolbar = .{};
	list := ui.box("messages", .Clip | .Scroll_Y);
	list.semantic_size = .[ui.pct(1), ui.fill()];
	// Scrolling is managed here (anchored to the bottom), not by ui's scroll offset.
	list.flags &= ~ui.Box_Flag.Scroll_Y;
	msgs := dc.messages_get(s, channel_id);
	view_h := list.rect.y1 - list.rect.y0;
	if view_h <= 0 view_h = app.ui.window.y;

	// wheel input over the list
	if ui.mouse_over(list) {
		for * e: app.ui.events {
			if e.kind != .Scroll || e.consumed continue;
			cs.scroll_target += e.delta.y;
			e.consumed = true;
		}
	}
	// Page Up / Page Down scroll the list from anywhere in the channel, the composer included
	if !modal_open() && !picker_is_open() {
		for * e: app.ui.events {
			if e.kind != .Key_Down || e.consumed || e.mods != 0 || (e.key != .Page_Up && e.key != .Page_Down) continue;
			page := view_h * 0.875; // Chromium's page step
			cs.scroll_target += ifx e.key == .Page_Up then page else -page;
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
	BOTTOM_PAD :: 8 + TYPING_H; // the typing line overlays the list's bottom, as in the client
	total: float32 = TOP_PAD + BOTTOM_PAD;
	// the start of a 1:1 DM's history carries the welcome header (avatar, names, friend actions);
	// a guild text channel's carries "Welcome to #channel!"
	// What the network has given so far: the first page still loading shows
	// placeholder messages, a failed page the client's "Messages Failed To Load"
	// bar, older history still to come placeholders above the oldest message.
	// Offline (fixtures) a channel without a list has nothing to load.
	l := table_find_pointer(*s.messages, channel_id);
	failed := l && l.failed;
	first_loading := !msgs && !failed && ifx l then (l.loading || !l.loaded) else app.client != null;
	older := l && l.has_more_before && msgs && !failed;
	welcome_ch := dc.channel_get(s, channel_id);
	welcome_h: float32 = 0;
	if welcome_ch {
		if ifx l then l.has_more_before || l.loading || failed else app.client != null welcome_ch = null;
	}
	if welcome_ch {
		if welcome_ch.kind == {
		case .DM;
			if welcome_ch.recipient_ids.count == 1 welcome_h = DMW_H;
		case .Guild_Text; #through; case .Guild_Announcement;
			welcome_h = channel_welcome_height(welcome_ch);
		}
		if welcome_h == 0 welcome_ch = null;
	}
	if welcome_ch total += welcome_h + DMW_GAP - TOP_PAD;
	if older total += SKEL_OLDER_H;
	// measured row heights, estimates for unmeasured ones
	guess := ifx cs.heights.count then cs.height_sum / cs.heights.count else MSG_LINE_H + 4;
	est :: (cs: *Chat_State, id: dc.Snowflake, guess: float32) -> float32 {
		ok, h := table_find(*cs.heights, id);
		return ifx ok then h else guess;
	}
	for msgs total += est(cs, it.id, guess);
	max_scroll := max(0.0, total - view_h);
	jump_apply(channel_id, cs, msgs, view_h, BOTTOM_PAD);
	cs.scroll_target = clamp(cs.scroll_target, 0, max_scroll);
	if app.ui.instant_scroll cs.scroll_from_bottom = cs.scroll_target;
	else ui.animate(*cs.scroll_from_bottom, cs.scroll_target, 40);
	cs.scroll_from_bottom = clamp(cs.scroll_from_bottom, 0, max_scroll);

	// load older history when within a screen of the top (not again after a failure:
	// the client waits for Try Again)
	if total - cs.scroll_from_bottom - view_h < view_h && older && !l.loading && app.client {
		dc.fetch_messages(app.client, channel_id, msgs[0].id);
	}
	if failed && history_failed_bar(l.loading) history_retry(channel_id, l);
	if first_loading {
		ui.parent(list); defer ui.pop_parent();
		sk := ui.box("skeleton", .Floating_Y | .Anchor_End_Y);
		sk.semantic_size = .[ui.pct(1), ui.children()];
		sk.layout_axis = .Y;
		sk.fixed_pos = .{0, BOTTOM_PAD};
		ui.parent(sk); defer ui.pop_parent();
		for i: 0..cast(int) (view_h / 70) skeleton_message(i);
		return;
	}

	// Render the contiguous run of rows near the viewport as one column anchored
	// to the list's bottom edge. Its offset only depends on rows *below* it, so
	// at the bottom (the common case) placement is exact on the first frame and
	// rows never jump while their real heights get measured.
	MARGIN :: 200;
	i1 := msgs.count - 1;
	below: float32 = 0; // height of rows after i1
	while i1 >= 0 && below + est(cs, msgs[i1].id, guess) < cs.scroll_from_bottom - MARGIN {
		below += est(cs, msgs[i1].id, guess);
		i1 -= 1;
	}
	i0 := i1;
	span: float32 = 0;
	while i0 >= 0 && below + span < cs.scroll_from_bottom + view_h + MARGIN {
		span += est(cs, msgs[i0].id, guess);
		i0 -= 1;
	}
	i0 += 1;
	new_top: float32;
	{ ui.parent(list); defer ui.pop_parent();
		col := ui.box("rows", .Floating_Y | .Anchor_End_Y);
		col.semantic_size = .[ui.pct(1), ui.children()];
		// items stop short of the scrollbar gutter (official: 375..1264 in a 905px list)
		lw := list.rect.x1 - list.rect.x0;
		if lw > MSG_SCROLL_GUTTER col.semantic_size[ui.Axis.X] = ui.px(lw - MSG_SCROLL_GUTTER);
		col.layout_axis = .Y;
		col.fixed_pos = .{0, BOTTOM_PAD + below - cs.scroll_from_bottom};
		{ ui.parent(col); defer ui.pop_parent();
			if i0 == 0 {
				if older {
					spacer(.Y, SKEL_OLDER_H - 3 * SKEL_MSG_H);
					for k: 0..2 skeleton_message(k);
				} else if welcome_ch != null {
					if welcome_ch.kind == .DM { dm_welcome(welcome_ch); } else { channel_welcome(welcome_ch); }
					spacer(.Y, DMW_GAP);
				} else {
					spacer(.Y, TOP_PAD);
				}
			}
			// where the "NEW" divider is: above the declared rows (older ones not drawn), on one, or below
			new_top = ifx i0 > 0 && msgs[i0].id > cs.unread_after then -FLOAT32_INFINITY else FLOAT32_INFINITY;
			for i: max(i0, 0)..i1 {
				m := *msgs[i];
				prev: *dc.Message = ifx i > 0 then *msgs[i - 1] else null;
				new_day := prev == null || day_of(prev.id) != day_of(m.id);
				show_new := cs.unread_after != 0 && m.id > cs.unread_after && (prev == null || prev.id <= cs.unread_after) && m.author_id != s.me;
				grouped := continues_group(prev, m) && !show_new;
				// consecutive call notices stack with no group gap
				if is_notice(m.kind) grouped = prev != null && prev.kind == m.kind && !new_day && !show_new;
				ui.id_scope(m.id); defer ui.pop_seed();
				// a run of blocked or ignored authors' messages is one collapsed row, measured on its first
				hide := hidden_kind(m);
				row: *ui.Box;
				if hide == "" {
					row = message_row(m, grouped, new_day, show_new);
				} else if new_day || show_new || prev == null || hidden_kind(prev) != hide {
					row = hidden_row(msgs, i, hide, new_day, show_new, cs.unread_after);
				}
				if row && show_new new_top = row.rect.y0;
				// remember measured height (from last frame's layout); a changed height moves the
				// rows and the scroll range, so lay out again rather than idle on a stale frame
				// (a short DM used to stay drawn with its newest message pushed under the list).
				// Not before the list has a width: a zero-width row wraps every character.
				if !row || (row.rect.y1 > row.rect.y0 && row.rect.x1 > row.rect.x0) {
					h := ifx row then row.rect.y1 - row.rect.y0 else 0;
					ok, old := table_find(*cs.heights, m.id);
					if !ok || abs(old - h) > 0.5 {
						cs.height_sum += h;
						if ok cs.height_sum -= old;
						table_set(*cs.heights, m.id, h);
						app.ui.animating = true;
					}
				}
			}
		}
		ui.scrollbar(list, .Auto, *cs.scroll_from_bottom, *cs.scroll_target, total, from_end = true);
		typing_line(channel_id);
		new_messages_bar(channel_id, msgs, lw, cs, new_top < list.rect.y0);
	}
}

// "3 blocked messages — Show messages" in place of the run of hidden messages starting at msgs[i].
hidden_row :: (msgs: []dc.Message, i: int, kind: string, new_day: bool, show_new: bool, unread_after: dc.Snowflake) -> *ui.Box {
	n := 1;
	while i + n < msgs.count {
		a, b := *msgs[i + n - 1], *msgs[i + n];
		if hidden_kind(b) != kind || day_of(a.id) != day_of(b.id) || (unread_after && a.id <= unread_after && b.id > unread_after) break;
		n += 1;
	}
	r0 := ui.box("msg");
	r0.semantic_size = .[ui.pct(1), ui.children()];
	r0.layout_axis = .Y;
	ui.parent(r0); defer ui.pop_parent();
	if new_day || show_new divider_row(msgs[i].id, new_day, show_new);
	else spacer(.Y, MSG_GROUP_GAP - 2);
	r := row("hidden");
	r.semantic_size = .[ui.pct(1), ui.px(22)];
	ui.parent(r); defer ui.pop_parent();
	spacer(.X, 72);
	s := ifx n == 1 then "" else "s";
	label(tprint("% % message% —", n, kind, s), .Normal, 14, T("--text-muted"), 18);
	spacer(.X, 4);
	b := ui.box(tprint("Show message%", s), .Clickable | .Draw_Text);
	b.semantic_size = .[ui.text_size(0), ui.px(18)];
	b.style.font = F(.Normal);
	b.style.font_size = 14;
	b.style.text_color = T("--text-link");
	b.hover_cursor = .Pointer;
	if ui.signal(b).clicked for j: i..i + n - 1 table_set(*shown_hidden, msgs[j].id, true);
	return r0;
}

// "N new messages since 3:04 PM ... Mark As Read" over the list's top: the messages after the
// read marker the channel was opened with, while its "NEW" divider is scrolled above the view
// (the channel itself is acked meanwhile), or while Mark Unread holds it. Mark As Read acks
// and drops the divider; the rest of the bar jumps to the first new message.
new_messages_bar :: (channel_id: dc.Snowflake, msgs: []dc.Message, lw: float32, cs: *Chat_State, divider_above: bool) {
	rs := table_find_pointer(*store().read_states, channel_id);
	held := rs != null && rs.manual;
	if !cs.unread_after || !msgs || !(divider_above || held) return;
	n, first := 0, cast(dc.Snowflake) 0;
	for < msgs {
		if it.id <= cs.unread_after break;
		n += 1;
		first = it.id;
	}
	if n == 0 return;
	bar := row("newbar", .Floating_X | .Floating_Y | .Draw_Background | .Clickable);
	bar.semantic_size = .[ui.px(max(lw - MSG_SCROLL_GUTTER - 16, 0)), ui.px(24)];
	bar.fixed_pos = .{16, 0};
	bar.style.bg = T("--background-brand");
	bar.style.radius = .[0, 0, 8, 8];
	jump := ui.signal(bar).clicked;
	{ ui.parent(bar); defer ui.pop_parent();
		spacer(.X, 12);
		label(tprint("% new message% since %", ifx n >= 50 then "50+" else tprint("%", n), ifx n == 1 then "" else "s", format_timestamp(first)), .Medium, 14, .{1, 1, 1, 1}, 18);
		filler(.X);
		mr := row("read", .Clickable);
		mr.semantic_size = .[ui.children(), ui.px(24)];
		if ui.signal(mr).clicked {
			jump = false;
			if app.client dc.ack_message(app.client, channel_id, msgs[msgs.count - 1].id, true, dc.ACK_NEW_MESSAGES_BANNER);
			cs.unread_after = 0;
		}
		{ ui.parent(mr); defer ui.pop_parent();
			label("Mark As Read", .Semibold, 14, .{1, 1, 1, 1}, 18);
			spacer(.X, 4);
			icon("ic", "chat-mark-unread", 16, .{1, 1, 1, 1});
		}
		spacer(.X, 12);
	}
	if jump jump_to_message(channel_id, first);
}

SKEL_MSG_H :: MSG_GROUP_GAP + 4 + 18 + 10 + 18; // a placeholder group with one line
SKEL_OLDER_H :: 3 * SKEL_MSG_H + 16 + 2 * 26; // the three placeholders above the oldest message

// A placeholder message group (the client's loading placeholders): avatar circle,
// name bar and 1-3 lines of varying width, the same for the same i.
skeleton_message :: (i: int) {
	ui.id_scope(cast(u64) i); defer ui.pop_seed();
	r := row("skel");
	r.semantic_size = .[ui.pct(1), ui.children()];
	r.cross_align = .Start;
	ui.parent(r); defer ui.pop_parent();
	spacer(.X, 16);
	c0 := ui.box("avc");
	c0.semantic_size = .[ui.px(40), ui.children()];
	c0.layout_axis = .Y;
	{ ui.parent(c0); defer ui.pop_parent(); spacer(.Y, MSG_GROUP_GAP); skel("av", 40, 40, true); }
	spacer(.X, 16);
	c := ui.box("lines");
	c.semantic_size = .[ui.fill(), ui.children()];
	c.layout_axis = .Y;
	ui.parent(c); defer ui.pop_parent();
	spacer(.Y, MSG_GROUP_GAP + 4);
	skel("name", cast(float32) (70 + (i * 37) % 90), 14);
	lines := ifx i < 3 then 1 else 1 + (i * 5) % 3; // the first (and the "older" ones) stay one line
	for k: 0..lines - 1 {
		spacer(.Y, 10);
		skel(tprint("l%", k), cast(float32) (140 + ((i * 7 + k * 13) * 53) % 320), 14);
	}
}

// The client's bar over the top of the messages when a page failed:
// "Messages Failed To Load" and Try Again (the pulsing ellipsis while it reloads).
history_failed_bar :: (loading: bool) -> bool {
	bar := row("loadfailed", .Clickable | .Draw_Background | .Floating_X | .Floating_Y | .Hot_Animation);
	bar.semantic_size = .[ui.pct(1), ui.px(32)];
	bar.style.bg = T("--status-danger");
	bar.style.bg_hot = with_alpha(T("--status-danger"), 0.9);
	bar.style.radius = .[0, 0, 8, 8];
	ui.parent(bar); defer ui.pop_parent();
	spacer(.X, 16);
	label("Messages Failed To Load", .Medium, 14, .{1, 1, 1, 1}, 18);
	filler(.X);
	if loading { pulsing_dots(.{1, 1, 1, 1}); } else { label("Try Again", .Semibold, 14, .{1, 1, 1, 1}, 18); }
	spacer(.X, 16);
	return ui.signal(bar).clicked && !loading;
}

// Try Again: the page that failed (the first, or the one before the oldest loaded).
history_retry :: (channel_id: dc.Snowflake, l: *dc.Message_List) {
	before := ifx l.messages.count then l.messages[0].id else 0;
	if net_action() {
		dc.fetch_messages(app.client, channel_id, before);
	} else {
		l.loading = true; // offline: as if the request went out (scripts end it with `history`)
	}
}

// One message: either a group start (avatar, name, time) or a continuation.
message_row :: (m: *dc.Message, grouped: bool, new_day: bool, show_new: bool) -> *ui.Box {
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
		// over a message's toolbar (it hangs over the row above) that message stays hovered
		tb := chat_toolbar_prev;
		mp := app.ui.mouse;
		over_tb := tb.msg != 0 && mp.x >= tb.rect.x0 && mp.x < tb.rect.x1 && mp.y >= tb.rect.y0 && mp.y < tb.rect.y1;
		hovered := ifx over_tb then tb.msg == m.id else ui.mouse_over(li);
		hovered = hovered && !app.ui.selection.dragging;
		if hovered app.chat_hover = m.id;
		if (hovered || ma.menu_msg == m.id) && !editing li.style.bg = T("--message-background-hover");
		highlighted := ma.replying == m.id || jump_highlighted(m.id);
		if highlighted {
			li.style.bg = T("--message-highlight-background-default");
			li.style.radius = .[0, 4, 4, 0];
			bar := ui.box("hlbar", .Draw_Background | .Floating_X | .Floating_Y);
			bar.semantic_size = .[ui.px(2), ui.px(li.rect.y1 - li.rect.y0)];
			bar.style.bg = T("--background-brand");
		}
		for * e: app.ui.events {
			// a control under the press (author name → user menu, avatar, …) takes its
			// own right-click; both menus used to open, the message menu on top
			if e.kind == .Mouse_Down && e.button == .Right && hovered && app.ui.hot == 0 open_message_menu(m, e.pos, "right_click");
			if !e.consumed && e.kind == .Mouse_Down && e.button == .Left && e.mods == .Alt && hovered && app.ui.hot == 0 && !m.pending {
				if net_action() dc.mark_unread(app.client, m.channel_id, m.id);
				e.consumed = true;
			}
		}
		if (hovered || ma.menu_msg == m.id) && !editing && !is_notice(m.kind) {
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
		if is_notice(m.kind) {
			system_notice(m);
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
				// the avatar floats, so the gutter holds its height: a header-only row
				// (a message type with no body) must not let it hang below the row
				gutter.semantic_size[ui.Axis.Y] = ui.px(2 + MSG_AVATAR);
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
					gt := label(format_timestamp(m.id, true), .Medium, 11, T("--text-muted"), MSG_LINE_H);
					if ui.mouse_over(gt) tooltip_below(full_timestamp(dc.snowflake_time_ms(m.id)), gt.rect);
					spacer(.X, 8);
				}
			}
			content := ui.box("content");
			content.semantic_size = .[ui.fill(), ui.children()];
			content.layout_axis = .Y;
			{ ui.parent(content); defer ui.pop_parent();
				if !grouped message_header(m);
				if m.forwarded {
					forward_block(m);
				} else {
					if editing { edit_box(m); } else { message_body(m); }
					if m.sticker_ids message_stickers_view(m);
				}
				thread_summary_pill(m);
				if m.attachments && !m.forwarded attachments_view(m);
				if m.pending upload_progress_view(m);
				if m.embeds && !m.forwarded embeds_view(m);
				if m.content && !m.forwarded invite_cards_view(m);
				if m.reactions reactions_view(m);
			}
			spacer(.X, ifx editing then cast(float32) MSG_EDIT_PAD_R else cast(float32) MSG_PAD_R); // the edit form reaches further right
		}
		spacer(.Y, 2);
	}
	return r0;
}

// System notices: "Name started a call that lasted a few seconds. 4:43 AM" (phone icon),
// "Name pinned a message to this channel. See all pinned messages. 4:43 AM" (pin icon).
system_notice :: (m: *dc.Message) {
	r := row("call");
	r.semantic_size = .[ui.pct(1), ui.children()];
	r.cross_align = .Start;
	{ ui.parent(r); defer ui.pop_parent();
		g := ui.box("gutter");
		g.semantic_size = .[ui.px(MSG_GUTTER), ui.px(CALL_ROW_H)];
		pin := m.kind == MSG_PIN;
		friend := m.kind == MSG_FRIEND_ACCEPTED;
		ic_name, ic_color := "phone", T("--icon-feedback-positive");
		if m.kind == {
			case MSG_PIN; ic_name, ic_color = "pin", T("--text-muted");
			case MSG_FRIEND_ACCEPTED; ic_name = "user-check";
			case MSG_RECIPIENT_ADD; #through; case MSG_MEMBER_JOIN; ic_name = "arrow-large-right";
			case MSG_RECIPIENT_REMOVE; ic_name, ic_color = "arrow-large-left", T("--status-danger");
			case MSG_NAME_CHANGE; #through; case MSG_ICON_CHANGE; ic_name, ic_color = "pencil", T("--text-muted");
		}
		{ ui.parent(g); defer ui.pop_parent();
			ic := icon("ic", ic_name, 16, ic_color);
			ic.flags |= .Floating_X | .Floating_Y;
			ic.fixed_pos = .{28, (CALL_ROW_H - 16) / 2};
		}
		spans: [..]ui.Span;
		spans.allocator = temp;
		muted := ui.Span.{font = F(.Normal), size = MSG_FONT, color = T("--text-muted")};
		strong := ui.Span.{font = F(.Medium), size = MSG_FONT, color = T("--text-strong")};
		add :: (spans: *[..]ui.Span, s: ui.Span, text: string) { x := s; x.text = text; array_add(spans, x); }
		// a user's name: clicking it opens their profile, as in the client
		name :: (spans: *[..]ui.Span, s: ui.Span, uid: dc.Snowflake, channel_id: dc.Snowflake) {
			x := s;
			x.text = name_in(uid, channel_id);
			x.user = cast(*void) uid;
			array_add(spans, x);
		}
		if friend {
			// the other user's name, whoever sent it; their note (content) is quoted when there is one
			ch := dc.channel_get(store(), m.channel_id);
			other := ifx ch && ch.recipient_ids.count then ch.recipient_ids[0] else m.author_id;
			mine := m.author_id == store().me;
			if mine { add(*spans, muted, "You accepted "); name(*spans, strong, other, m.channel_id); add(*spans, muted, "'s friend request."); }
			else { name(*spans, strong, other, m.channel_id); add(*spans, muted, " accepted your friend request."); }
			if m.content != "" {
				add(*spans, muted, ifx mine then " They said: " else " You said: ");
				add(*spans, strong, m.content);
			}
		} else if m.kind == MSG_RECIPIENT_ADD || m.kind == MSG_RECIPIENT_REMOVE {
			// the other user is the first mention; removing yourself is leaving
			name(*spans, strong, m.author_id, m.channel_id);
			other := ifx m.mentions.count then m.mentions[0] else 0;
			if m.kind == MSG_RECIPIENT_REMOVE && (other == 0 || other == m.author_id) {
				add(*spans, muted, " left the group.");
			} else {
				add(*spans, muted, ifx m.kind == MSG_RECIPIENT_ADD then " added " else " removed ");
				name(*spans, strong, other, m.channel_id);
				add(*spans, muted, ifx m.kind == MSG_RECIPIENT_ADD then " to the group." else " from the group.");
			}
		} else if m.kind == MSG_NAME_CHANGE {
			name(*spans, strong, m.author_id, m.channel_id);
			if m.content == "" { add(*spans, muted, " removed the custom group name."); }
			else {
				ch := dc.channel_get(store(), m.channel_id);
				add(*spans, muted, ifx ch && ch.kind == .Group_DM then " changed the group name: " else " changed the channel name: ");
				add(*spans, strong, m.content);
				add(*spans, muted, ".");
			}
		} else if m.kind == MSG_MEMBER_JOIN {
			// getSystemMessageUserJoin: the message's snowflake time picks one of 13 lines
			JOIN :: string.[
				"", " joined the party.", "", " is here.", "Welcome, ", ". We hope you brought pizza.", "A wild ", " appeared.",
				"", " just landed.", "", " just slid into the server.", "", " just showed up!", "Welcome ", ". Say hi!",
				"", " hopped into the server.", "Everyone welcome ", "!", "Glad you're here, ", ".", "Good to see you, ", ".",
				"Yay you made it, ", "!"];
			i := (dc.snowflake_time_ms(m.id) % (JOIN.count / 2)) * 2;
			add(*spans, muted, JOIN[i]);
			name(*spans, strong, m.author_id, m.channel_id);
			add(*spans, muted, JOIN[i + 1]);
		} else if m.kind == MSG_ICON_CHANGE {
			name(*spans, strong, m.author_id, m.channel_id);
			add(*spans, muted, " changed the group icon.");
		} else if pin {
			name(*spans, strong, m.author_id, m.channel_id);
			add(*spans, muted, " pinned ");
			add(*spans, strong, "a message");
			add(*spans, muted, " to this channel. See all ");
			add(*spans, strong, "pinned messages");
			add(*spans, muted, ".");
		} else {
			name(*spans, strong, m.author_id, m.channel_id);
			add(*spans, muted, ifx m.call_ended then tprint(" started a call that lasted %.", humanize_duration(dc.iso_to_ms(m.call_ended) - dc.iso_to_ms(m.timestamp))) else " started a call.");
		}
		add(*spans, .{font = F(.Medium), size = 12, color = T("--chat-text-muted")}, tprint(" %", header_timestamp(m.id)));
		b := ui.box("text", .Selectable_Text | .Wrap_Text);
		b.semantic_size = .[ui.fill(), ui.text_size()];
		b.style.line_height = MSG_LINE_H;
		b.style.padding = .{0, (CALL_ROW_H - MSG_LINE_H) / 2};
		ui.set_spans(b, spans);
		b.sel_order = m.id * 8 + 2;
		tl := b.prev_layout;
		if tl for e: app.ui.events {
			if e.kind != .Mouse_Up || e.button != .Left || e.consumed || ui.has_selection() || ui.overlay_at(e.pos) continue;
			si := ui.span_at(tl, e.pos);
			if si < 0 || si >= tl.spans.count || tl.spans[si].user == null continue;
			open_profile(cast(dc.Snowflake) tl.spans[si].user, .{e.pos.x, e.pos.y - 10, e.pos.x + 1, e.pos.y + 10});
		}
		spacer(.X, 48);
	}
}

message_header :: (m: *dc.Message) {
	name := name_in(m.author_id, m.channel_id);
	h := row("header");
	h.semantic_size = .[ui.pct(1), ui.px(MSG_LINE_H)];
	h.cross_align = .End;
	{ ui.parent(h); defer ui.pop_parent();
		n := label(name, .Medium, 16, author_color(m), MSG_LINE_H);
		n.flags |= .Clickable | .Selectable_Text;
		n.sel_order = m.id * 8;
		nsig := ui.signal(n);
		if nsig.clicked open_profile(m.author_id, n.rect, .Message_Author, m.id);
		if nsig.right_clicked open_user_menu(m.author_id, app.ui.mouse);
		new_member_badge(m);
		spacer(.X, 8);
		// copies as "Name — 4:56 AM" like the client's hidden separator
		ts := label(header_timestamp(m.id), .Medium, 12, T("--chat-text-muted"), 20);
		ts.flags |= .Selectable_Text;
		ts.sel_order = m.id * 8 + 1;
		ts.sel_join = " — ";
		if ui.mouse_over(ts) tooltip_below(full_timestamp(dc.snowflake_time_ms(m.id)), ts.rect);
	}
}

// The sprout after a new member's name (official useIsNewMember): joined at most 7 days ago,
// not a rejoin, not a bot, in a guild at least 7 days old.
new_member_badge :: (m: *dc.Message) {
	s := store();
	ch := dc.channel_get(s, m.channel_id);
	if !ch || !ch.guild_id return;
	mem := dc.member_get(s, ch.guild_id, m.author_id);
	u := dc.user_get(s, m.author_id);
	if !mem || mem.joined_at == "" || (mem.flags & 1) || (u && u.bot) return;
	DAY :: 86_400_000;
	now := dc.now_ms();
	if now - dc.snowflake_time_ms(ch.guild_id) < 7 * DAY || now - dc.iso_to_ms(mem.joined_at) > 7 * DAY return;
	spacer(.X, 4);
	b := icon("newmember", "new-member", 20, T("--text-feedback-positive"), .Clickable);
	if ui.signal(b).hovering tooltip_below("I'm new here, say hi!", b.rect);
}

// terms: search words to highlight (search result cards).
message_body :: (m: *dc.Message, terms: []string = .[]) {
	if m.content == "" return;
	blocks := md_parse(m.content);
	edited_inline := false;
	for blk, bi: blocks {
		color := T("--text-default");
		if m.pending color = T("--text-muted");
		if m.failed color = T("--text-feedback-critical");
		if blk.kind == {
		case .Code_Block;
			if blk.quoted {
				wrap := row(tprint("blk%", bi));
				wrap.semantic_size = .[ui.pct(1), ui.children()];
				wrap.custom_draw = quote_bar_draw;
				ui.parent(wrap);
				spacer(.X, 16);
			}
			cb :=ui.box(tprint("code%", bi), .Draw_Background | .Draw_Border | .Draw_Text | .Selectable_Text | .Wrap_Text);
			code := code_spans(blk.code, blk.lang, F(.Mono), 14);
			ui.set_spans(cb, ifx terms then highlight_spans(code, terms) else code);
			cb.semantic_size = .[ifx blk.quoted then ui.fill() else ui.pct(1), ui.text_size()];
			cb.style.bg = T("--background-base-lowest");
			cb.style.border_color = T("--border-subtle");
			cb.style.border = 1;
			cb.style.radius = all4(4);
			cb.style.font = F(.Mono);
			cb.style.font_size = 14;
			cb.style.line_height = 18;
			cb.style.padding = .{8, 8};
			cb.style.text_color = T("--text-code");
			cb.sel_order = m.id * 8 + 2 + cast(u64) bi % 4;
			if blk.quoted ui.pop_parent();
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
			wrap := row(tprint("blk%", bi));
			wrap.semantic_size = .[ui.pct(1), ui.children()];
			wrap.cross_align = .Start;
			b: *ui.Box;
			{ ui.parent(wrap); defer ui.pop_parent();
				if blk.quoted {
					// the bar spans the whole (wrapped, multi-line) quote: drawn over the row's rect
					wrap.custom_draw = quote_bar_draw;
					spacer(.X, 16);
				}
				if blk.kind == .List_Item {
					spacer(.X, 6 + cast(float32) blk.depth * 20);
					marker := ifx blk.number then tprint("%.", blk.number) else ifx blk.depth == 0 then "•" else "◦";
					label(marker, .Normal, size, color, line_h);
					spacer(.X, 8);
				}
				// keyed per block: ids resolve against the message's id_scope, not the
				// row, so a plain "p" collided from the second block on and became an
				// anonymous box (no selection anchor, no link/mention clicks)
				b = ui.box(tprint("p%", bi), .Selectable_Text | .Wrap_Text);
				b.semantic_size = .[ui.fill(), ui.text_size()];
				b.style.text_color = color;
				b.style.line_height = line_h;
				spans := tokens_to_spans(blk.tokens, font, size, m);
				// jumbo: a message of only emoji (up to 27) renders them at 3rem; the
				// spaces between keep the text size (.emoji.jumboable sizes only the img)
				if blocks.count == 1 && is_emoji_only(blk.tokens) {
					for * spans if it.object != .{} it.object = emoji_object(48, size);
					b.style.line_height = 56;
				}
				if bi == blocks.count - 1 && m.edited_timestamp {
					// "(edited)" rides at the end of the last paragraph, like the client
					edited := NewArray(spans.count + 1, ui.Span,, temp);
					memcpy(edited.data, spans.data, spans.count * size_of(ui.Span));
					edited[spans.count] = .{text = " (edited)", font = F(.Normal), size = 10, color = T("--text-muted"), id = EDITED_SPAN};
					spans = edited;
					edited_inline = true;
				}
				if terms spans = highlight_spans(spans, terms);
				ui.set_spans(b, spans);
				b.sel_order = m.id * 8 + 2 + cast(u64) bi % 4;
			}
			handle_span_clicks(b, blk.tokens, m.id, ifx edited_inline then dc.iso_to_ms(m.edited_timestamp) else 0);
		}
	}
	if m.edited_timestamp && !edited_inline {
		ed := label("(edited)", .Normal, 10, T("--text-muted"), 22);
		if ui.mouse_over(ed) tooltip_below(full_timestamp(dc.iso_to_ms(m.edited_timestamp)), ed.rect);
	}
}

// A forwarded message: the snapshot's content behind a quote bar, under "Forwarded", and
// the origin ("#channel • time", jumps there) below it.
forward_block :: (m: *dc.Message) {
	s := store();
	wrap := row("fwd");
	wrap.semantic_size = .[ui.pct(1), ui.children()];
	wrap.cross_align = .Start;
	wrap.custom_draw = quote_bar_draw;
	ui.parent(wrap); defer ui.pop_parent();
	spacer(.X, 16);
	col := ui.box("fwdcol");
	col.semantic_size = .[ui.fill(), ui.children()];
	col.layout_axis = .Y;
	ui.parent(col); defer ui.pop_parent();
	h := row("fwdhead");
	h.semantic_size = .[ui.pct(1), ui.px(MSG_LINE_H)];
	h.cross_align = .Center;
	{ ui.parent(h); defer ui.pop_parent();
		icon("ic", "arrow-angle-right-up", 16, T("--text-muted"));
		spacer(.X, 4);
		label("Forwarded", .Italic, 14, T("--text-muted"), 18);
	}
	message_body(m);
	if m.sticker_ids message_stickers_view(m);
	if m.attachments attachments_view(m);
	if m.embeds embeds_view(m);
	ch := dc.channel_get(s, m.forward_channel_id);
	if ch == null || ch.name == "" return;
	spacer(.Y, 2);
	f := row("fwdfoot", .Clickable);
	f.semantic_size = .[ui.children(), ui.px(18)];
	sig := ui.signal(f);
	{ ui.parent(f); defer ui.pop_parent();
		c := ifx sig.hovering then T("--text-default") else T("--text-muted");
		label(tprint("#% • %", ch.name, format_timestamp(m.forward_message_id)), .Medium, 12, c, 18);
	}
	if sig.clicked jump_to_message(m.forward_channel_id, m.forward_message_id);
}

reactions_view :: (m: *dc.Message) {
	r := row("reactions");
	r.semantic_size = .[ui.pct(1), ui.px(30)];
	r.style.child_gap = 4;
	{ ui.parent(r); defer ui.pop_parent();
		for * re, i: m.reactions {
			pill := row(tprint("re%", i), .Clickable | .Draw_Background | .Draw_Border | .Hot_Animation);
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
				label(tprint("%", re.count), .Semibold, 14, ifx re.me then T("--reaction-text-reacted-default") else T("--reaction-text-default"), 16);
				spacer(.X, 6);
			}
			if sig.clicked react(m, re.emoji, "Message Inline Button", toggle = true);
		}
		reaction_add_button(m);
	}
	spacer(.Y, 2);
}

TYPING_H :: 24;

// "Name is typing..." over the bottom of the message list (messages scroll under it).
typing_line :: (channel_id: dc.Snowflake) {
	s := store();
	t := row("typing", .Floating_X | .Floating_Y | .Anchor_End_Y);
	t.semantic_size = .[ui.pct(1), ui.px(TYPING_H)];
	typers := dc.typing_users(s, channel_id);
	if !typers return;
	ui.parent(t); defer ui.pop_parent();
	spacer(.X, 16);
	names: [..]string;
	names.allocator = temp;
	for typers {
		if it.user_id == s.me continue;
		name := name_in(it.user_id, channel_id, "");
		if name array_add(*names, name);
	}
	if !names return;
	msg: string;
	if names.count == {
	case 1;
		msg = tprint("% is typing...", names[0]);
	case 2;
		msg = tprint("% and % are typing...", names[0], names[1]);
	case 3;
		msg = tprint("%, %, and % are typing...", names[0], names[1], names[2]);
	case;
		msg = "Several people are typing...";
	}
	pulsing_dots(T("--text-default")); // requests.jai
	spacer(.X, 4);
	label(msg, .Medium, 14, T("--text-default"), 24);
}

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
		if ma.replying != 0 reply_bar();
		uploads_bar(ch.id);
		box := row("composer", .Clickable);
		box.semantic_size = .[ui.fill(), ui.children()];
		box.cross_align = .Start;
		box.hover_cursor = .IBeam;
		if ui.signal(box).pressed app.ui.focus = box.key;
		{ ui.parent(box); defer ui.pop_parent();
			spacer(.X, 16);
			plus := ui.box("plus", .Clickable);
			if ui.signal(plus).clicked stage_paths(ch.id, pick_files(), "file_picker");
			plus.semantic_size = .[ui.px(24), ui.px(COMPOSER_H)];
			plus.layout_axis = .Y;
			plus.cross_align = .Center;
			plus_hov := ui.signal(plus).hovering;
			{ ui.parent(plus); defer ui.pop_parent();
				spacer(.Y, (COMPOSER_H - 24) / 2);
				icon("i", "plus-large", 24, ifx plus_hov then T("--interactive-icon-hover") else T("--interactive-icon-default"));
			}
			spacer(.X, 24);
			placeholder := ifx ch.kind == .DM then tprint("Message @%", dm_name(ch)) else tprint("Message #%", ch.name);
			if ch.kind == .Group_DM placeholder = tprint("Message %", dm_name(ch));
			// Up in an empty composer edits your last message, like the client
			if ui.editor_text(*cs.editor) == "" && ma.editing == 0 {
				for * e: app.ui.events {
					if e.consumed || e.kind != .Key_Down || e.key != .Up || e.mods != 0 continue;
					for < * dc.messages_get(s, ch.id) {
						if can_edit(it) {
							start_edit(it);
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
					if e.consumed || e.kind != .Key_Down || e.key != .V || (e.mods & (.Shift | .Alt)) || !(e.mods & PRIMARY_MOD) continue;
					if paste_attachments(ch.id) e.consumed = true;
				}
				for * e: app.ui.events {
					if e.consumed || e.kind != .Key_Down || e.key != .U || e.mods != PRIMARY_MOD | .Shift continue;
					e.consumed = true;
					stage_paths(ch.id, pick_files(), "file_picker");
				}
			}
			// the emoji and mention autocompletes float over the whole form and take their keys first
			ui.push_parent(stack);
			emoji_autocomplete(ch, *cs.editor, input_focused);
			mention_autocomplete(ch, *cs.editor, input_focused);
			ui.pop_parent();
			res := text_field("input", *cs.editor, placeholder, input_focused, pad_y = (COMPOSER_H - MSG_LINE_H) / 2, placeholder_color = T("--channel-text-area-placeholder"), markdown = true);
			if res == .Changed emoji_autocomplete_close_colon(ch, *cs.editor);
			if res == .Submit {
				text := trim(ui.editor_text(*cs.editor), " \t\n\r\x0b\x0c");
				if composer_send(ch, mentions_convert(emoji_convert_shortcodes(text, ch.id), ch)) cs.scroll_target = 0;
				ui.editor_set_text(*cs.editor, "");
			} else if res == .Escape {
				ma.replying = 0;
			} else if res == .Changed && app.client != null && ui.editor_text(*cs.editor) != "" {
				dc.typing_keystroke(app.client, ch.id);
			}
			clk := ui.box("clock", .Clickable);
			clk.semantic_size = .[ui.px(40), ui.px(COMPOSER_H)];
			clk.layout_axis = .Y;
			clk.cross_align = .Center;
			{ ui.parent(clk); defer ui.pop_parent();
				csig := ui.signal(clk);
				if csig.clicked timestamp_gen_open(ch.id);
				if csig.hovering tooltip_below("Insert Timestamp", clk.rect);
				spacer(.Y, (COMPOSER_H - 24) / 2);
				icon("i", "clock", 24, ifx csig.hovering then T("--interactive-icon-hover") else T("--interactive-icon-default"));
			}
			for name: (string.["gif", "sticker", "reaction"]) {
				b := ui.box(name, .Clickable);
				b.semantic_size = .[ui.px(40), ui.px(COMPOSER_H)];
				b.layout_axis = .Y;
				b.cross_align = .Center;
				hov := picker_composer_button(name, ui.signal(b), b.rect, ch.id, input_focused || (picker_is_open() && pk.mode == .Composer && pk.channel == ch.id));
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
