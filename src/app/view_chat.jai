// Cozy message layout, measured from the official client.
MSG_GUTTER :: 72; // content x offset
MSG_AVATAR :: 40;
MSG_GROUP_GAP :: 17; // space above the first message of a group (by default: group_gap())
// Accessibility > Space between message groups; Compact's default is 0 (the client's default per display)
group_gap :: () -> float32 { return cast(float32) (ifx message_compact() && a11y.group_spacing == 16 then 0 else a11y.group_spacing) + 1; }
MSG_LINE_H :: 22;
MSG_FONT :: 16;

// Appearance > Chat Font Scaling (settings.json): message text in px; the client's slider marks. Messages'
// text sizes and line heights scale with it (chat_px), as rem does in the client; avatars and the gutter don't.
CHAT_FONT_SIZES :: int.[12, 14, 15, 16, 18, 20, 24];
chat_font_px := 16;
chat_px :: (px: float32) -> float32 { return ifx chat_font_px == 16 then px else floor(px * cast(float32) chat_font_px / 16 + 0.5); }

// Appearance > Message Display: Compact (text_and_images.message_display_compact, 6.17, a BoolValue, off
// while unset): no avatars, each group's first line is "time name text", the time in the gutter.
message_compact :: () -> bool {
	if compact_frame != app.frame {
		v, set := dc.settings_value(store(), 6, 17, 1);
		compact_frame, compact_on = app.frame, set && v != 0;
	}
	return compact_on;
}
compact_frame: u64;
compact_on: bool;
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
MSG_POLL_RESULT :: 46; // "Name's poll Question has closed." with the winner (polls.jai)
MSG_BOOST :: 8; // 8: boosted (content: how many times), 9-11: and reached level 1-3; drawn plainly, with no Boost prompt
MSG_CHANNEL_FOLLOW :: 12; // CHANNEL_FOLLOW_ADD: content is the followed channel's name
MSG_DISCOVERY_FIRST :: 14; // 14-17: removed from / back in Server Discovery, and its two grace-period warnings
MSG_THREAD_CREATED :: 18; // content is the thread's name, message_reference.channel_id the thread
MSG_THREAD_STARTER :: 21; // the thread's first message: the parent message (store.jai), a notice when it's gone
MSG_INVITE_REMINDER :: 22; // GUILD_INVITE_REMINDER: the client doesn't draw it
MSG_AUTOMOD :: 24; // AUTO_MODERATION_ACTION: an auto_moderation_message embed
MSG_ROLE_SUB :: 25; // ROLE_SUBSCRIPTION_PURCHASE
MSG_STAGE_FIRST :: 27; // 27-31: STAGE_START, STAGE_END, STAGE_SPEAKER, STAGE_RAISE_HAND, STAGE_TOPIC
MSG_INCIDENT_FIRST :: 36; // 36-39: security actions enabled / disabled, raid reported, false alarm

// Drawn as a one-line notice (system_notice), not a message with an avatar.
is_notice :: (m: *dc.Message) -> bool {
	kind := m.kind;
	if kind == MSG_THREAD_STARTER return m.referenced_id != 0;
	return kind == MSG_CALL || kind == MSG_PIN || kind == MSG_MEMBER_JOIN || kind == MSG_FRIEND_ACCEPTED || (kind >= MSG_RECIPIENT_ADD && kind <= MSG_ICON_CHANGE) || kind == MSG_POLL_RESULT
		|| (kind >= MSG_BOOST && kind <= MSG_CHANNEL_FOLLOW) || (kind >= MSG_DISCOVERY_FIRST && kind <= MSG_THREAD_CREATED) || (kind >= MSG_STAGE_FIRST && kind <= MSG_STAGE_FIRST + 4)
		|| kind == MSG_AUTOMOD || kind == MSG_ROLE_SUB || (kind >= MSG_INCIDENT_FIRST && kind <= MSG_INCIDENT_FIRST + 3);
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
	marker_stale: bool; // the window lost focus with the channel read: the next unread message moves the marker
	shown_newest: dc.Snowflake; // the newest row last frame: rows added below, scrolled up, don't move the view
	shown_gap: bool;            // and whether a jump's gap was open then
}

chat_state :: (channel_id: dc.Snowflake) -> *Chat_State { return find_or_add(*app.chats, channel_id); }

// Unix ms as local wall-clock ms, with the UTC offset in force at that instant (so DST applies per
// date). Offsets are cached per quarter hour, packed as one s64 so other threads can share it.
local_ms :: (unix_ms: s64) -> s64 {
	Q :: 900_000;
	q := unix_ms / Q - ifx unix_ms % Q < 0 then 1 else 0;
	slot := *tz_cache[cast(u64) q % tz_cache.count];
	v := slot.*;
	if v >> 20 != q + 1 {
		off := clamp(tz_offset_seconds(q * (Q / 1000)), -65535, 65535);
		v = ((q + 1) << 20) | (off + 65536);
		slot.* = v;
	}
	return unix_ms + ((v & 0xf_ffff) - 65536) * 1000;
}
tz_cache: [64]s64;

// The inverse, for a local date typed in: the unix ms whose local time is local_ms.
unix_from_local_ms :: (local: s64) -> s64 {
	guess := local - (local_ms(local) - local);
	return local - (local_ms(guess) - guess);
}

// "3:04 PM" today, "Yesterday at 3:04 PM", or "10/24/2026 3:04 PM" — the client's calendar format.
format_timestamp :: (id: dc.Snowflake, short := false) -> string { return format_time_ms(dc.snowflake_time_ms(id), short); }

format_time_ms :: (unix_ms: s64, short := false) -> string {
	ms := local_ms(unix_ms);
	t := utc_calendar(ms);
	clock := clock_text(t, sep = "\u202f"); // narrow no-break space, as Intl formats it
	if short return clock;
	day := ms / 86_400_000;
	today := local_ms(wall_ms()) / 86_400_000;
	if day == today return clock;
	if day == today - 1 return tprint(L("Yesterday at %"), clock);
	return tprint("% %", date_format(i18n_fmt().numeric, t), clock);
}

// "Tuesday, October 27, 2026 3:04 PM" (moment's LLLL): the tooltip on message times and "(edited)".
full_timestamp :: (unix_ms: s64) -> string {
	t := utc_calendar(local_ms(unix_ms));
	return date_format(i18n_fmt().full, t, clock_text(t));
}

// Unix ms now (or the -now: override).
wall_ms :: () -> s64 { return ifx app.now_override_ms then app.now_override_ms else dc.now_ms(); }

// format_timestamp kept alive across frames: header timestamps are selectable,
// and a selection is read (copy, scripts) after the frame's temp memory is gone.
header_timestamp :: (id: dc.Snowflake) -> string {
	today := local_ms(wall_ms()) / 86_400_000;
	if today != stamps.day || use_24h() != stamps.h24 || i18n_fmt() != stamps.fmt {
		for stamps.texts free(it);
		table_reset_keeping_memory(*stamps.texts);
		stamps.day, stamps.h24, stamps.fmt = today, use_24h(), i18n_fmt();
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
	request_wake(platform.time_now() + cast(float64) (86400 - local_ms(wall_ms()) / 1000 % 86400) + 1);
	rs := table_find_pointer(*s.read_states, channel_id);
	last_read := ifx rs then rs.last_message_id else 0;
	held := rs != null && rs.manual; // Mark Unread: the "NEW" line moves there and nothing is acked
	if !cs.opened || held {
		cs.opened = true;
		cs.unread_after = last_read;
	}
	// ReadStateStore: losing focus with the channel read makes its oldest-unread marker stale, and the
	// first message that then stays unread becomes the "NEW" divider (and the bar's count).
	unread := dc.channel_unread(s, channel_id);
	if app.focus_lost && !unread cs.marker_stale = true;
	if cs.marker_stale && unread && rs && !held {
		cs.unread_after = last_read;
		cs.marker_stale = false;
	}
	// Ack what's on screen while focused, not idle and scrolled to the bottom, like the client.
	msgs := dc.messages_get(s, channel_id);
	at_present := cs.scroll_from_bottom < 2 && !(rs_list(channel_id) && rs_list(channel_id).gap_after);
	if app.client dc.set_route_scrolled_up(app.client, !at_present);
	if app.client && app.focused && !app.client.idle_sent && msgs && at_present && !held {
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
	if secs < 45 return L("a few seconds");
	if secs < 90 return L("a minute");
	if mins < 45 return tprint(Lp("% minute", "% minutes", mins), mins);
	if mins < 90 return L("an hour");
	if hours < 22 return tprint(Lp("% hour", "% hours", hours), hours);
	if hours < 36 return L("a day");
	days := (hours + 12) / 24;
	return tprint(Lp("% day", "% days", days), days);
}

author_color :: (m: *dc.Message) -> ui.Color {
	ch := dc.channel_get(store(), m.channel_id);
	if ch && ch.guild_id {
		c, ok := member_color(ch.guild_id, m.author_id);
		if ok return c;
	}
	return T("--text-strong");
}

// Highest-position colored role, unless Accessibility shows role colours next to names or not at all
// (raw: the colour regardless).
member_color :: (guild_id: dc.Snowflake, user_id: dc.Snowflake, raw := false) -> ui.Color, bool {
	if a11y.role_colors != 0 && !raw return .{}, false;
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

// After a member's name (chat and the member list): the icon of their highest role that has one, its
// image else its unicode emoji, in a server with ROLE_ICONS; the role's name on hover.
role_icon :: (guild_id: dc.Snowflake, user_id: dc.Snowflake, size: float32) {
	s := store();
	mem := dc.member_get(s, guild_id, user_id);
	g := dc.guild_get(s, guild_id);
	if !mem || !g || on_hosted() || !dc.guild_has_feature(g, "ROLE_ICONS") return;
	best: *dc.Role;
	for rid: mem.roles for * g.roles if it.id == rid && (it.icon || it.unicode_emoji) && (!best || it.position > best.position) best = it;
	if !best return;
	spacer(.X, 4);
	b: *ui.Box;
	hash := best.icon;
	safe := hash.count > 0 && hash.count <= 64;
	for cast([]u8) hash if !is_alnum(it) && it != #char "_" safe = false;
	if safe {
		b = ui.box("roleicon", .Draw_Background);
		b.semantic_size = .[ui.px(size), ui.px(size)];
		set_remote_image(b, tprint("https://cdn.discordapp.com/role-icons/%/%.webp?size=%&quality=lossless", best.id, hash, cast(int) size * 2));
	} else if best.unicode_emoji {
		b = emoji_box("roleicon", .{name = best.unicode_emoji}, size);
	} else return;
	if ui.mouse_over(b) tooltip_below(best.name, b.rect);
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
			ch, mid := message_link(tk.text);
			if tk.url == "" && ch && ch.guild_id {
				sp.text = ifx mid then tprint("#% › 💬", ch.name) else tprint("#%", ch.name);
				sp.bg = T("--mention-background");
				sp.color = T("--mention-foreground");
				sp.bg_radius = 3;
				sp.font = F(.Medium);
				first := spans.count;
				emoji_text_spans(spans, sp);
				for k: first..spans.count - 1 { e := *(spans.*)[k]; e.bg = sp.bg; e.bg_radius = sp.bg_radius; }
				continue;
			}
		case .User_Mention;
			sp.text = tprint("@%", name_in(tk.id, ifx m then m.channel_id else 0, L("unknown-user")));
			sp.bg = T("--mention-background");
			sp.color = T("--mention-foreground");
			sp.bg_radius = 3;
			sp.font = F(.Medium);
		case .Role_Mention; #through; case .Everyone;
			sp.bg = T("--mention-background");
			sp.color = T("--mention-foreground");
			sp.bg_radius = 3;
			sp.font = F(.Medium);
			if tk.kind == .Role_Mention {
				// the role's name in its colour on a 10% tint of it, like the official RoleMention
				c := ifx m then dc.channel_get(s, m.channel_id);
				g := ifx c && c.guild_id then dc.guild_get(s, c.guild_id);
				r: *dc.Role;
				if g for * g.roles if it.id == tk.id { r = it; break; }
				sp.text = ifx r then tprint("@%", r.name) else "@deleted-role";
				if r && r.color {
					sp.color = rgb_u32(r.color);
					sp.bg = with_alpha(sp.color, 0.1);
				}
			}
		case .Command;
			sp.text = tk.name;
			sp.bg = T("--mention-background");
			sp.color = T("--mention-foreground");
			sp.bg_radius = 3;
			sp.font = F(.Medium);
		case .Channel_Mention;
			c := dc.channel_get(s, tk.id);
			sp.text = tprint("#%", ifx c then c.name else L("unknown"));
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

// The selection wrapped in marker m (**, *, __, ~~, `, ||), or unwrapped when it already is; it stays selected.
toggle_wrap :: (ed: *ui.Editor, m: string) {
	text := ui.editor_text(ed);
	a, b := ui.editor_sel(ed);
	k := m.count;
	at :: (text: string, i: int, s: string) -> bool { return i >= 0 && i + s.count <= text.count && slice(text, i, s.count) == s; }
	// A lone * must not eat half of a bold's **.
	wrapped := at(text, a - k, m) && at(text, b, m) && !(k == 1 && (at(text, a - 2, "**") || at(text, b, "**")));
	if wrapped {
		ui.editor_apply(ed, join(slice(text, 0, a - k), slice(text, a, b - a), slice(text, b + k, text.count - b - k),, temp), b - k, a - k);
	} else {
		ui.editor_apply(ed, join(slice(text, 0, a), m, slice(text, a, b - a), m, slice(text, b, text.count - b),, temp), b + k, a + k);
	}
}

// "> " added at the start of each selected line, or taken off when every one has it.
toggle_quote :: (ed: *ui.Editor) {
	text := ui.editor_text(ed);
	a, b := ui.editor_sel(ed);
	s := a;
	while s > 0 && text[s - 1] != #char "\n" s -= 1;
	lines := split(slice(text, s, b - s), "\n",, temp);
	all := true;
	for lines if !begins_with(it, "> ") all = false;
	for * lines it.* = ifx all then advance(it.*, 2) else join("> ", it.*,, temp);
	mid := join(..lines, separator = "\n",, temp);
	ui.editor_apply(ed, join(slice(text, 0, s), mid, slice(text, b, text.count - b),, temp), s + mid.count, s);
}

// The composer's toolbar over a finished selection (official: bold, italic, strikethrough, code,
// spoiler, quote; each toggles its markdown and keeps the selection).
format_toolbar :: (ed: *ui.Editor, tl: *ui.Text_Layout, f: *ui.Box, selecting: bool) {
	if !tl || !f.parent || !ui.editor_has_sel(ed) || selecting return;
	a, b := ui.editor_sel(ed);
	p0, p1 := ui.caret_pos(tl, a), ui.caret_pos(tl, b);
	TOOLS :: struct { label: string; icon: string; m: string; }.[
		.{"B", "", "**"}, .{"I", "", "*"}, .{"S", "", "~~"}, .{"", "angle-brackets", "`"}, .{"", "spoiler", "||"}, .{"\u201c", "", ">"},
	];
	W :: cast(float32) TOOLS.count * 32 + 8;
	x := ifx p0.y == p1.y then (p0.x + p1.x) / 2 - W / 2 else p0.x;
	pr := f.parent.rect;
	// on the root: the composer clips its children, and a clipped box takes no clicks
	ui.push_parent(app.ui.root);
	defer ui.pop_parent();
	bar := row("fmtbar", .Floating_X | .Floating_Y | .Overlay | .Draw_Background | .Draw_Border | .Draw_Shadow | .Clickable);
	bar.semantic_size = .[ui.px(W), ui.px(40)];
	bar.fixed_pos = .{clamp(x, pr.x0, max(pr.x0, pr.x1 - W)), p0.y - 48};
	bar.style.bg = T("--background-surface-higher");
	bar.style.border_color = T("--border-subtle");
	bar.style.border = 1;
	bar.style.radius = all4(8);
	bar.style.shadow_color = .{0, 0, 0, 0.24};
	bar.style.shadow_blur = 8;
	ui.signal(bar);
	ui.parent(bar); defer ui.pop_parent();
	spacer(.X, 4);
	for TOOLS {
		bt := ui.box(tprint("fmt%", it_index), .Clickable | .Draw_Background | .Hot_Animation);
		bt.semantic_size = .[ui.px(32), ui.px(32)];
		bt.style.radius = all4(4);
		bt.style.bg_hot = T("--background-mod-normal");
		bt.layout_axis = .X;
		bt.cross_align = .Center;
		if ui.signal(bt).clicked {
			if it.m == ">" toggle_quote(ed); else toggle_wrap(ed, it.m);
		}
		ui.parent(bt); defer ui.pop_parent();
		if it.icon {
			spacer(.X, 6);
			icon("ic", it.icon, 20, T("--interactive-icon-default"));
		} else {
			spacer(.X, 11);
			l := ui.box("l", .Wrap_Text);
			l.semantic_size = .[ui.text_size(), ui.px(20)];
			l.style.line_height = 20;
			ui.set_spans(l, ui.Span.[.{text = it.label, font = F(ifx it.m == "**" then .Bold else ifx it.m == "*" then .Italic else .Semibold), size = 16, color = T("--interactive-icon-default"), strike = it.m == "~~"}]);
		}
	}
}

// Enter and Tab in a markdown field, as the official composer handles them: Enter adds a
// newline (instead of sending) inside a ``` block or with Alt; Tab in code lines indents.
markdown_key :: (ed: *ui.Editor, e: ui.Input_Event) -> bool {
	// Ctrl+B / I / U on a selection wraps it in **, * or __, or unwraps it when it already is.
	if (e.key == .B || e.key == .I || e.key == .U) && e.mods == PRIMARY_MOD && ui.editor_has_sel(ed) {
		toggle_wrap(ed, ifx e.key == .B then "**" else ifx e.key == .I then "*" else "__");
		return true;
	}
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
	t := utc_calendar(local_ms(secs * 1000));
	clock := clock_text(t);
	date := date_format(i18n_fmt().long, t);
	if style == {
	case "t";
		return clock;
	case "T";
		return clock_text(t, seconds = true);
	case "d";
		return date_format(i18n_fmt().numeric, t);
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
	in := delta_secs > 0;
	if s < 45 return ifx in then L("in a few seconds") else L("a few seconds ago");
	if s < 90 return ifx in then L("in a minute") else L("a minute ago");
	if m < 45 return tprint(ifx in then Lp("in % minute", "in % minutes", m) else Lp("% minute ago", "% minutes ago", m), m);
	if m < 90 return ifx in then L("in an hour") else L("an hour ago");
	if h < 22 return tprint(ifx in then Lp("in % hour", "in % hours", h) else Lp("% hour ago", "% hours ago", h), h);
	if h < 36 return ifx in then L("in a day") else L("a day ago");
	if d < 26 return tprint(ifx in then Lp("in % day", "in % days", d) else Lp("% day ago", "% days ago", d), d);
	if d < 45 return ifx in then L("in a month") else L("a month ago");
	if d < 320 { n := (d + 15) / 30; return tprint(ifx in then Lp("in % month", "in % months", n) else Lp("% month ago", "% months ago", n), n); }
	if d < 548 return ifx in then L("in a year") else L("a year ago");
	n := (d + 182) / 365;
	return tprint(ifx in then Lp("in % year", "in % years", n) else Lp("% year ago", "% years ago", n), n);
}

// Spoilers revealed by a click, keyed by where their run of tokens starts in the
// message text (stable while the message is kept; an edit hides them again).
revealed_spoilers: Table(u64, bool);

spoiler_key :: (toks: []Token, i: int) -> u64 {
	while i > 0 && (toks[i - 1].styles & .Spoiler) i -= 1;
	return cast(u64) toks[i].text.data;
}

spoiler_revealed :: (toks: []Token, i: int) -> bool {
	return spoilers_always() || table_find_pointer(*revealed_spoilers, spoiler_key(toks, i)) != null; // Chat > Show spoiler content
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
		if id < cast(u64) toks.count && !ui.overlay_at(p) {
			tk := toks[id];
			if tk.kind == .Link && !((tk.styles & .Spoiler) && !spoiler_revealed(toks, cast(int) id)) {
				free(ma.hover_link);
				ma.hover_link, ma.hover_link_frame = copy_string(ifx tk.url then tk.url else tk.text), app.frame;
			}
			if ((tk.styles & .Spoiler) && !spoiler_revealed(toks, cast(int) id)) || tk.kind == .Link || tk.kind == .User_Mention || tk.kind == .Channel_Mention || (tk.kind == .Command && (tk.id || tk.url))
				app.ui.span_cursor = .Pointer;
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
			follow_link(ifx tk.url then tk.url else tk.text, message_id, masked = tk.url != "" && tk.url != tk.text);
		case .User_Mention;
			r := ui.Rect.{e.pos.x, e.pos.y - 10, e.pos.x + 1, e.pos.y + 10};
			open_profile(tk.id, r);
		case .Channel_Mention;
			c := dc.channel_get(store(), tk.id);
			if c select_channel(c.guild_id, c.id);
		case .Command;
			// a slash command's chip (</name sub:id>) puts "/name sub " in the composer, for its options
			ch := dc.channel_get(store(), app.view.channel);
			if tk.url server_page_chip(tk.url); // <id:customize> etc. (view_onboarding.jai)
			else if tk.id && ch && !composer_blocked(ch) ui.editor_insert(*chat_state(ch.id).editor, tprint("% ", tk.name));
		}
	}
}

// A link clicked in a message: invites and channel links open in fastcord, other web links in the browser.
// An fc:// invite opens Join a Server filled in, never joining by itself.
// masked: a [text](url) link whose text isn't its target: an untrusted host asks first ("Leaving Discord").
follow_link :: (url: string, message_id: dc.Snowflake, browser := true, masked := false) {
	code := invite_link_code(url);
	ch, msg := message_link(url);
	if code != "" invite_link_clicked(code, message_id);
	else if open_fc_link(url) {}
	else if begins_with(url, "fc://") add_server_join_with(url);
	else if ch && msg jump_to_message(ch.id, msg);
	else if ch select_channel(ch.guild_id, ch.id);
	else if browser && masked && !host_trusted(url_host(url)) { free(leaving.url); leaving = .{url = copy_string(url)}; }
	else if browser open_url(url);
}

// The host of an http(s) URL, lowercased ("" for anything else). User info goes ("https://discord.com@evil.example"
// is evil.example), as do the port and everything after the authority.
url_host :: (url: string) -> string {
	rest := url;
	if begins_with_nocase(rest, "https://") advance(*rest, 8);
	else if begins_with_nocase(rest, "http://") advance(*rest, 7);
	else return "";
	end := 0;
	while end < rest.count && rest[end] != #char "/" && rest[end] != #char "?" && rest[end] != #char "#" && rest[end] != #char "\\" end += 1;
	auth := slice(rest, 0, end);
	at := find_index_from_right(auth, #char "@");
	if at >= 0 advance(*auth, at + 1);
	colon := find_index_from_left(auth, #char ":");
	if colon >= 0 auth.count = colon;
	return to_lower_copy(auth,, temp);
}

// MaskedLinkStore.isTrustedDomain: Discord's own hosts and the ones you chose to trust.
host_trusted :: (host: string) -> bool {
	if host == "" return false;
	for DISCORD_HOSTS if host == it || ends_with(host, tprint(".%", it)) return true;
	for trusted_domains if host == it return true;
	return false;
}

DISCORD_HOSTS :: string.["discord.com", "discordapp.com", "discord.gg", "discord.gift", "discord.new", "discord.media", "discordapp.net", "discord.co", "discord.dev", "discordstatus.com", "dis.gd"];
TRUSTED_DOMAINS_MAX :: 500;
trusted_domains: [..]string; // hosts trusted from the Leaving Discord dialog (owned; settings.json keeps them)
leaving: struct { url: string; trust: bool; }; // the open Leaving Discord dialog (url heap; "" closed)

// "Leaving Discord": the masked link's real target, "Trust <host> links from now on", Go Back / Visit Site.
leaving_modal :: () {
	if leaving.url == "" return;
	host := url_host(leaving.url);
	close := false;
	if !adm_modal_begin("leaving", 440, L("Leaving Discord")) {
		close = true;
	} else {
		spacer(.Y, 8);
		{ r := row("body"); r.semantic_size = .[ui.pct(1), ui.children()]; ui.parent(r); defer ui.pop_parent();
			spacer(.X, 25);
			label(L("This link is taking you to the following website"), .Normal, 16, T("--text-default"), 20);
		}
		spacer(.Y, 12);
		{ r := row("urlrow"); r.semantic_size = .[ui.pct(1), ui.children()]; ui.parent(r); defer ui.pop_parent();
			spacer(.X, 25);
			b := ui.box("url", .Draw_Background | .Draw_Text | .Wrap_Text);
			b.semantic_size = .[ui.fill(), ui.text_size(12)];
			b.text = leaving.url;
			b.style.bg = T("--background-base-lowest");
			b.style.radius = all4(4);
			b.style.padding = .{8, 8};
			b.style.font = F(.Normal);
			b.style.font_size = 14;
			b.style.line_height = 18;
			b.style.text_color = T("--text-strong");
			spacer(.X, 25);
		}
		spacer(.Y, 12);
		{ r := row("trust", .Clickable); r.semantic_size = .[ui.pct(1), ui.px(24)]; ui.parent(r); defer ui.pop_parent();
			if ui.signal(r).clicked leaving.trust = !leaving.trust;
			spacer(.X, 25);
			cb := ui.box("cb", .Draw_Background | .Draw_Border);
			cb.semantic_size = .[ui.px(20), ui.px(20)];
			cb.style.radius = all4(4);
			cb.style.border = ifx leaving.trust then 0.0 else 1.0;
			cb.style.border_color = T("--checkbox-border-default");
			cb.style.bg = ifx leaving.trust then T("--background-brand") else .{};
			if leaving.trust { ui.parent(cb); defer ui.pop_parent(); i := ui.box("i", .Floating_X | .Floating_Y); i.semantic_size = .[ui.px(18), ui.px(18)]; i.fixed_pos = .{1, 1}; set_icon(i, "checkmark-small", .{1, 1, 1, 1}); }
			spacer(.X, 8);
			label(tprint(L("Trust % links from now on"), host), .Normal, 14, T("--text-default"), 18);
		}
		spacer(.Y, 24);
		btns := row("btns");
		btns.semantic_size = .[ui.pct(1), ui.px(40)];
		btns.style.child_gap = 8;
		{ ui.parent(btns); defer ui.pop_parent();
			spacer(.X, 25 - 8);
			if wide_button("back", L("Go Back"), .Secondary) close = true;
			if wide_button("visit", L("Visit Site"), .Primary) {
				if leaving.trust && host != "" && !host_trusted(host) && trusted_domains.count < TRUSTED_DOMAINS_MAX array_add(*trusted_domains, copy_string(host));
				open_url(leaving.url);
				close = true;
			}
			spacer(.X, 25 - 8);
		}
		spacer(.Y, 24);
		adm_modal_end();
		if adm_escape() close = true;
	}
	if close { free(leaving.url); leaving = .{}; }
}

// A link opened outside fastcord (another app, a second launch): fc:// and discord:// only. A discord://
// link's path is a discord.com route (discord://-/channels/<guild>/<channel>, discord:///invite/<code>).
open_launch_url :: (url: string) {
	u := url;
	if begins_with_nocase(u, "discord:") {
		advance(*u, "discord:".count);
		while begins_with(u, "/") advance(*u, 1);
		if begins_with(u, "-/") advance(*u, 2);
		u = tprint("https://discord.com/%", u);
	} else if !begins_with_nocase(u, "fc://") return;
	follow_link(u, 0, browser = false);
}

// An age-restricted (NSFW) channel, or a thread in one, shows a gate until you agree for its server
// (remembered on this device, as the client's per-guild agreement is), and always when your account
// may not see adult content.
nsfw_gated :: (ch: *dc.Channel) -> bool {
	s := store();
	p := ifx dc.is_thread(ch) then dc.channel_get(s, ch.parent_id) else ch;
	if !p || !p.nsfw return false;
	_, agreed := table_find(*app.view.nsfw_agreed, ch.guild_id);
	return !agreed || s.settings.nsfw_blocked;
}

nsfw_gate :: (ch: *dc.Channel) {
	blocked := store().settings.nsfw_blocked;
	g := ui.box("nsfwgate");
	g.semantic_size = .[ui.fill(), ui.pct(1)];
	g.layout_axis = .Y;
	ui.parent(g); defer ui.pop_parent();
	filler(.Y);
	center :: (id: string, h: float32) -> *ui.Box #expand {
		r := row(id);
		r.semantic_size = .[ui.pct(1), ui.px(h)];
		return r;
	}
	{ r := center("icon", 64); ui.parent(r); defer ui.pop_parent(); filler(.X); icon("i", "warning", 64, T("--text-feedback-warning")); filler(.X); }
	spacer(.Y, 16);
	{ r := center("t", 28); ui.parent(r); defer ui.pop_parent(); filler(.X); label(L("Age-Restricted Channel"), .Semibold, 24, T("--text-strong"), 28); filler(.X); }
	spacer(.Y, 8);
	body := ifx blocked then L("You must be at least 18 years old to view this channel.") else L("This channel contains adult content that may not be suitable for all audiences. You must be 18 or older to view it.");
	{ r := center("b", 20); ui.parent(r); defer ui.pop_parent(); filler(.X); label(body, .Normal, 16, T("--text-default"), 20); filler(.X); }
	spacer(.Y, 24);
	{
		r := center("btns", 38);
		ui.parent(r); defer ui.pop_parent();
		filler(.X);
		if modal_button(L("Nevermind##nsfwno"), 120, T("--background-mod-normal"), T("--background-mod-strong"), T("--text-strong")) {
			if app.view.back.count history_step(false); else go_home();
		}
		if !blocked {
			spacer(.X, 12);
			if modal_button(L("Continue##nsfwyes"), 120, T("--background-brand"), with_alpha(T("--background-brand"), 0.85), .{1, 1, 1, 1}) table_set(*app.view.nsfw_agreed, ch.guild_id, true);
		}
		filler(.X);
	}
	filler(.Y);
}

human_size :: (n: int) -> string {
	if n >= 1 << 20 return tprint(L("% MB"), formatFloat(cast(float64) n / (1 << 20), trailing_width = 2, zero_removal = .NO));
	if n >= 1 << 10 return tprint(L("% KB"), formatFloat(cast(float64) n / (1 << 10), trailing_width = 2, zero_removal = .NO));
	return tprint(Lp("% byte", "% bytes", n), n);
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
		if name return tprint(L("%'s Group"), name);
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
	if markdown && focused format_toolbar(ed, tl, f, sig.dragging);
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
		case .Link; #through; case .User_Mention; #through; case .Role_Mention; #through; case .Channel_Mention; #through; case .Everyone; #through; case .Timestamp; #through; case .Command;
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
			t := utc_calendar(local_ms(dc.snowflake_time_ms(id)));
			label(date_format(i18n_fmt().long, t), .Semibold, 12, ifx show_new then T("--status-danger") else T("--text-muted"), 13);
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
				label(L("NEW"), .Bold, 10, .{1, 1, 1, 1}, 13);
				spacer(.X, 4);
			}
		}
		spacer(.X, 14);
	}
	spacer(.Y, 10); // official: the next item's top sits 18px below the divider line
}

// Any overlay that takes keyboard input away from the composer.
// channel_escape: the official Escape keybind on the open channel, once no layer took it: end an
// edit, else drop the pending reply, else MARK_CHANNEL_READ (ack the newest message and drop the
// "NEW" divider and bar).
channel_escape :: (ch: *dc.Channel) {
	if ma.editing != 0 { edit_stash(); return; }
	if ma.replying != 0 { ma.replying = 0; return; }
	s := store();
	msgs := dc.messages_get(s, ch.id);
	rs := table_find_pointer(*s.read_states, ch.id);
	if msgs && app.client && (!rs || rs.manual || rs.last_message_id < msgs[msgs.count - 1].id) dc.ack_message(app.client, ch.id, msgs[msgs.count - 1].id, true);
	chat_state(ch.id).unread_after = 0;
}

modal_open :: () -> bool {
	return sw.open || leaving.url != "" || attachments_modal_open() || ma.confirming != 0 || app.settings_open || viewer_url != "" || invite_modal_open() || invite_accept_open() || add_server_is_open() || events_modal_open() || guild_admin_modal_open() || server_settings_is_open() || fnick.user != 0 || modr.user != 0 || tsg.channel != 0 || cstatus.open || folder_modal_open() || shortcuts_open || view_reactions.msg != 0 || npoll.channel != 0;
}

// The hover toolbar drawn this pass, and the one from the pass before (rows test the
// mouse against it: it floats above its own row).
Chat_Toolbar :: struct { msg: dc.Snowflake; rect: ui.Rect; }
chat_toolbar, chat_toolbar_prev: Chat_Toolbar;

// A blockquote's 4px rounded bar down the left of its row.
// A discord.com/channels/<guild or @me>/<channel>[/<message>] link to a channel we have, or an fc:// one
// to a channel on a joined server; else null.
message_link :: (url: string) -> *dc.Channel, dc.Snowflake {
	h, fc_cid, fc_mid, fc := parse_fc_link(url);
	if fc {
		if !h || !h.client return null, 0;
		ch := dc.channel_get(*h.client.store, fc_cid);
		return ch, ifx ch then fc_mid else 0;
	}
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
	h24: bool; // the texts' clock (Time format)
	fmt: *Locale_Formats; // and language
	texts: Table(dc.Snowflake, string);
};

// Groups with the previous message: same author, within 7 minutes, plain message type, not a reply.
continues_group :: (prev: *dc.Message, m: *dc.Message) -> bool {
	// A webhook posting under another name starts a new group, as the official client's isGrouped does.
	if prev == null || prev.author_id != m.author_id || prev.webhook_name != m.webhook_name || is_notice(prev) return false;
	if m.referenced_id != 0 || (m.kind != 0 && m.kind != 19) return false;
	if dc.snowflake_time_ms(m.id) - dc.snowflake_time_ms(prev.id) > GROUP_WINDOW_MS return false;
	return day_of(prev.id) == day_of(m.id);
}

day_of :: (id: dc.Snowflake) -> s64 {
	return local_ms(dc.snowflake_time_ms(id)) / 86_400_000;
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
	encrypted_prepare(channel_id, msgs);
	view_h := list.rect.y1 - list.rect.y0;
	if view_h <= 0 view_h = app.ui.window.y;

	cs.scroll_target -= ui.autoscroll_step(list); // middle-click autoscroll
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
			if e.kind == .Key_Down && !e.consumed && e.mods == .Shift && e.key == .Page_Up {
				// Shift+Page Up: the oldest unread message, or the last read one when that isn't loaded.
				first: dc.Snowflake;
				if cs.unread_after != 0 && msgs.count > 0 {
					first = cs.unread_after;
					if msgs[0].id <= cs.unread_after for msgs if it.id > cs.unread_after { first = it.id; break; }
				}
				if first != 0 jump_to_message(channel_id, first);
				e.consumed = true;
			}
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
		case .Group_DM;
			welcome_h = GDW_H;
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
	gap := l && l.gap_after != 0;
	newest := ifx msgs then msgs[msgs.count - 1].id else 0;
	// scrolled up, what is being read stays put: rows added below move the bottom-based scroll with them
	if cs.shown_newest && newest > cs.shown_newest && cs.scroll_target > 0 {
		added: float32;
		for < msgs { if it.id <= cs.shown_newest break; added += est(cs, it.id, guess); }
		cs.scroll_from_bottom += added;
		cs.scroll_target += added;
	}
	cs.shown_newest, cs.shown_gap = newest, gap;
	max_scroll := max(0.0, total - view_h);
	jump_apply(channel_id, cs, msgs, view_h, BOTTOM_PAD, guess);
	steering := jump_steering(channel_id);
	cs.scroll_target = clamp(cs.scroll_target, 0, max_scroll);
	if app.ui.instant_scroll cs.scroll_from_bottom = cs.scroll_target;
	else ui.animate(*cs.scroll_from_bottom, cs.scroll_target, 40);
	cs.scroll_from_bottom = clamp(cs.scroll_from_bottom, 0, max_scroll);

	// load older history when within a screen of the top (not again after a failure:
	// the client waits for Try Again)
	if total - cs.scroll_from_bottom - view_h < view_h && older && !l.loading && app.client {
		dc.fetch_messages(app.client, channel_id, msgs[0].id);
	}
	// a jumped-to stretch: newer pages when within a screen of its bottom
	if gap && cs.scroll_from_bottom < view_h && !l.loading && !failed && app.client {
		dc.fetch_messages(app.client, channel_id, after = l.gap_after);
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
					if welcome_ch.kind == .DM { dm_welcome(welcome_ch); } else if welcome_ch.kind == .Group_DM { group_dm_welcome(welcome_ch); } else { channel_welcome(welcome_ch); }
					spacer(.Y, DMW_GAP);
				} else {
					spacer(.Y, TOP_PAD);
				}
			}
			// where the "NEW" divider is: above the declared rows (older ones not drawn), on one, or below
			new_top = ifx i0 > 0 && msgs[i0].id > cs.unread_after then -FLOAT32_INFINITY else FLOAT32_INFINITY;
			for i: max(i0, 0)..i1 {
				m := *msgs[i];
				ui.id_scope(m.id); defer ui.pop_seed();
				if message_held(m.id) || encrypted_hidden(m) || m.kind == MSG_INVITE_REMINDER { // deleted, behind Undo, an encrypted reaction or delete
					ok, old := table_find(*cs.heights, m.id);
					if ok cs.height_sum -= old;
					table_set(*cs.heights, m.id, 0);
					continue;
				}
				p := i - 1;
				while p >= 0 && (message_held(msgs[p].id) || encrypted_hidden(*msgs[p])) p -= 1;
				prev: *dc.Message = ifx p >= 0 then *msgs[p] else null;
				m = encrypted_view(m); // its reply, files and reactions, from inside the packet
				new_day := prev == null || day_of(prev.id) != day_of(m.id);
				show_new := cs.unread_after != 0 && m.id > cs.unread_after && (prev == null || prev.id <= cs.unread_after) && m.author_id != s.me;
				grouped := continues_group(prev, m) && !show_new;
				// consecutive call notices stack with no group gap
				if is_notice(m) grouped = prev != null && prev.kind == m.kind && !new_day && !show_new;
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
						// Scrolled up, a row starting below the top of the view that grows or shrinks (an
						// embed or reaction landing, a first measure, a new width) would push the text being
						// read: the scroll, measured from the bottom, takes the difference.
						if cs.scroll_target > 0 && !steering && row && row.rect.y0 > list.rect.y0 {
							d := h - ifx ok then old else guess;
							cs.scroll_from_bottom += d;
							cs.scroll_target += d;
						}
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
		if gap && jump_to_present_bar(lw) jump_to_present(channel_id);
	}
}

rs_list :: (channel_id: dc.Snowflake) -> *dc.Message_List { return table_find_pointer(*store().messages, channel_id); }

// "You're Viewing Older Messages ... Jump To Present" over the list's bottom while a jump shows an
// older stretch (the official jumpToPresentBar, shown while hasMoreAfter).
jump_to_present_bar :: (lw: float32) -> bool {
	bar := row("jumppresent", .Floating_X | .Floating_Y | .Anchor_End_Y | .Draw_Background | .Draw_Border | .Draw_Shadow | .Clickable | .Hot_Animation);
	bar.semantic_size = .[ui.px(max(lw - 24, 0)), ui.px(32)];
	bar.fixed_pos = .{8, 0};
	bar.style.bg = T("--background-surface-highest");
	bar.style.bg_hot = T("--background-surface-higher");
	bar.style.border_color = T("--border-subtle");
	bar.style.border = 1;
	bar.style.radius = .[8, 8, 0, 0];
	bar.style.shadow_color = .{0, 0, 0, 0.2};
	bar.style.shadow_offset = .{0, -1};
	ui.parent(bar); defer ui.pop_parent();
	spacer(.X, 16);
	label(L("You're Viewing Older Messages"), .Medium, 14, T("--text-default"), 18);
	filler(.X);
	label(L("Jump To Present"), .Semibold, 14, T("--text-default"), 18);
	spacer(.X, 8);
	icon("ic", "chevron-small-down", 16, T("--text-default"));
	spacer(.X, 16);
	return ui.signal(bar).clicked;
}

// Back to the newest messages from a jumped-to stretch: the stored present side, else the newest page.
jump_to_present :: (channel_id: dc.Snowflake) {
	s := store();
	l := rs_list(channel_id);
	if !l || !l.gap_after return;
	dc.drop_jumped_stretch(s, l);
	if app.client {
		dc.track_jump(app.client, "Present", channel_id, 0);
		if !l.messages dc.fetch_messages(app.client, channel_id);
	}
	cs := chat_state(channel_id);
	cs.scroll_target, cs.scroll_from_bottom, cs.shown_newest = 0, 0, 0;
	s.changed += 1;
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
	else spacer(.Y, group_gap() - 2);
	r := row("hidden");
	r.semantic_size = .[ui.pct(1), ui.px(22)];
	ui.parent(r); defer ui.pop_parent();
	spacer(.X, 72);
	label(tprint(ifx kind == "blocked" then Lp("% blocked message —", "% blocked messages —", n) else Lp("% ignored message —", "% ignored messages —", n), n), .Normal, 14, T("--text-muted"), 18);
	spacer(.X, 4);
	b := ui.box(ifx n == 1 then L("Show message") else L("Show messages"), .Clickable | .Draw_Text);
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
	// official .barBase + .newMessagesBar: inset 8 px left and 16 px right, 32 px tall with a subtle
	// border and the low elevation, 16 px side padding; the main button pads its text 4 px more
	bar := row("newbar", .Floating_X | .Floating_Y | .Draw_Background | .Draw_Border | .Draw_Shadow | .Clickable);
	bar.semantic_size = .[ui.px(max(lw - 24, 0)), ui.px(32)];
	bar.fixed_pos = .{8, 0};
	bar.style.bg = T("--background-brand");
	bar.style.border_color = T("--border-subtle");
	bar.style.border = 1;
	bar.style.radius = .[0, 0, 8, 8];
	bar.style.shadow_color = .{0, 0, 0, 0.2};
	bar.style.shadow_offset = .{0, 1};
	jump := ui.signal(bar).clicked;
	{ ui.parent(bar); defer ui.pop_parent();
		spacer(.X, 20);
		label(tprint(Lp("%1 new message since %2", "%1 new messages since %2", n), ifx n >= 50 then "50+" else tprint("%", n), format_timestamp(first)), .Medium, 14, .{1, 1, 1, 1}, 18);
		filler(.X);
		// .barButtonAlt: 4 x 8 px padding, a hover background, the icon 8 px after the text
		mr := row("read", .Clickable | .Draw_Background | .Hot_Animation);
		mr.semantic_size = .[ui.children(), ui.px(26)];
		mr.style.bg_hot = T("--control-secondary-background-hover");
		mr.style.radius = all4(4);
		if ui.signal(mr).clicked {
			jump = false;
			if app.client dc.ack_message(app.client, channel_id, msgs[msgs.count - 1].id, true, dc.ACK_NEW_MESSAGES_BANNER);
			cs.unread_after = 0;
		}
		{ ui.parent(mr); defer ui.pop_parent();
			spacer(.X, 8);
			label(L("Mark As Read"), .Semibold, 14, .{1, 1, 1, 1}, 18);
			spacer(.X, 8);
			icon("ic", "chat-mark-unread", 16, .{1, 1, 1, 1});
			spacer(.X, 8);
		}
		spacer(.X, 16);
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
	label(L("Messages Failed To Load"), .Medium, 14, .{1, 1, 1, 1}, 18);
	filler(.X);
	if loading { pulsing_dots(.{1, 1, 1, 1}); } else { label(L("Try Again"), .Semibold, 14, .{1, 1, 1, 1}, 18); }
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

// The message pings you: by name, @everyone / @here, or one of your roles in its server.
mentions_me :: (m: *dc.Message) -> bool {
	s := store();
	if m.mention_everyone || array_find(m.mentions, s.me) return true;
	if find_index_from_left(m.content, "<@&") < 0 return false;
	ch := dc.channel_get(s, m.channel_id);
	if !ch || !ch.guild_id return false;
	mem := dc.member_get(s, ch.guild_id, s.me);
	if mem for r: mem.roles if contains(m.content, tprint("<@&%>", r)) return true;
	return false;
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
			spacer(.Y, group_gap() - 2);
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
		if !highlighted && mentions_me(m) {
			li.style.bg = T(ifx hovered then "--message-mentioned-background-hover" else "--message-mentioned-background-default");
			li.style.radius = .[0, 4, 4, 0];
			bar := ui.box("mnbar", .Draw_Background | .Floating_X | .Floating_Y);
			bar.semantic_size = .[ui.px(2), ui.px(li.rect.y1 - li.rect.y0)];
			bar.style.bg = T("--status-warning");
		}
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
		spacer(.Y, 2);
		if m.command_user && !m.referenced_id {
			rr := row("cmdrow");
			rr.semantic_size = .[ui.pct(1), ui.px(22)];
			{ ui.parent(rr); defer ui.pop_parent();
				spacer(.X, MSG_GUTTER);
				command_used_line(m);
			}
		}
		if m.referenced_id != 0 && !is_notice(m) { // a pin notice references the pinned message: no reply line
			rr := row("replyrow");
			rr.semantic_size = .[ui.pct(1), ui.px(22)];
			{ ui.parent(rr); defer ui.pop_parent();
				spacer(.X, MSG_GUTTER);
				reply_preview(m);
			}
		}
		if is_notice(m) {
			system_notice(m);
			if m.kind == MSG_POLL_RESULT poll_result_card(m);
			if m.kind == MSG_MEMBER_JOIN wave_button(m);
			spacer(.Y, 2);
			return r0;
		}
		body := row("body");
		body.semantic_size = .[ui.pct(1), ui.children()];
		body.cross_align = .Start;
		{ ui.parent(body); defer ui.pop_parent();
			compact := message_compact();
			gutter := ui.box("gutter");
			gutter.semantic_size = .[ui.px(MSG_GUTTER), ui.px(chat_px(MSG_LINE_H))];
			if !grouped && !compact {
				// the avatar floats, so the gutter holds its height: a header-only row
				// (a message type with no body) must not let it hang below the row
				gutter.semantic_size[ui.Axis.Y] = ui.px(2 + MSG_AVATAR);
				{ ui.parent(gutter); defer ui.pop_parent();
					av := avatar_box("avatar", m.author_id, MSG_AVATAR, animate = hovered);
					av.flags |= .Floating_X | .Floating_Y;
					av.fixed_pos = .{16, 2};
				}
			} else if hovered || (compact && !grouped) || e2e_mark(m) != .None {
				gutter.layout_axis = .X;
				gutter.cross_align = .Center;
				{ ui.parent(gutter); defer ui.pop_parent();
					filler(.X);
					if hovered || (compact && !grouped) {
						gt := label(format_timestamp(m.id, true), .Medium, chat_px(11), T("--text-muted"), chat_px(MSG_LINE_H));
						if ui.mouse_over(gt) tooltip_below(full_timestamp(dc.snowflake_time_ms(m.id)), gt.rect);
						spacer(.X, 8);
					} else {
						e2e_mark_icon(e2e_mark(m), 14); // the mark stays on follow-ups
						spacer(.X, 12);
					}
				}
			}
			content := ui.box("content");
			content.semantic_size = .[ui.fill(), ui.children()];
			content.layout_axis = .Y;
			{ ui.parent(content); defer ui.pop_parent();
				// compact: the name leads the first paragraph; else (a code block first, no text, editing) its own line
				name_inline := compact && !grouped && !editing && compact_name_inline(m);
				if !grouped && !name_inline message_header(m, with_time = !compact);
				if m.forwarded {
					forward_block(m);
				} else {
					if editing { edit_box(m); } else { message_body(m, name_inline = name_inline); }
					if m.sticker_ids message_stickers_view(m);
				}
				thread_summary_pill(m);
				if m.attachments && !m.forwarded attachments_view(m);
				if m.pending upload_progress_view(m);
				if m.failed failed_send_note(m);
				if m.embeds && !m.forwarded && !(m.flags & 4) && chat_pref(12) { // Chat > Show embeds
					// your own embeds get the client's hover X, "Remove all embeds" (Shift skips the confirm)
					er := row("embeds");
					er.semantic_size = .[ui.pct(1), ui.children()];
					er.cross_align = .Start;
					ui.parent(er); defer ui.pop_parent();
					ec := ui.box("ecol");
					ec.semantic_size = .[ui.children(), ui.children()];
					ec.layout_axis = .Y;
					{ ui.parent(ec); defer ui.pop_parent(); embeds_view(m); }
					if app.chat_hover == m.id && !m.pending && can_manage_message(m) {
						spacer(.X, 4);
						x := ui.box("rmembeds", .Clickable);
						x.semantic_size = .[ui.px(16), ui.px(16)];
						x.hover_cursor = .Pointer;
						xs := ui.signal(x);
						set_icon(x, "x-small", ifx xs.hovering then T("--interactive-icon-hover") else T("--interactive-icon-default"));
						if xs.hovering tooltip_below(L("Remove all embeds"), x.rect);
						if xs.clicked {
							if app.ui_mods & .Shift remove_embeds_now(m);
							else ma.confirming, ma.confirm = m.id, Confirm.Remove_Embeds;
						}
					}
				}
				if m.content && !m.forwarded invite_cards_view(m);
				if m.content && !m.forwarded fc_invite_cards_view(m);
				if m.poll message_poll_view(m);
				if m.components && !m.forwarded message_components_view(m); // components.jai
				if m.flags & dc.MESSAGE_EPHEMERAL ephemeral_note(m);
				if m.reactions && chat_pref(13) reactions_view(m); // Chat > Show emoji reactions
			}
			spacer(.X, ifx editing then cast(float32) MSG_EDIT_PAD_R else cast(float32) MSG_PAD_R); // the edit form reaches further right
		}
		spacer(.Y, 2);
		if (hovered || ma.menu_msg == m.id) && !editing {
			// the toolbar hangs 16px above the item's top edge (official: top -16, right 14); declared
			// last, floating at the top, so it draws over the reply line and the content
			anchor := ui.box("tbanchor", .Floating_X | .Floating_Y);
			anchor.semantic_size = .[ui.px(li.rect.x1 - li.rect.x0), ui.px(0)];
			anchor.fixed_pos = .{0, 0};
			{ ui.parent(anchor); defer ui.pop_parent(); message_toolbar(m); }
		}
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
		// an ended call we weren't in: the client's "You missed a call" (red phone)
		missed := m.kind == MSG_CALL && m.call_ended != "" && !m.call_joined && m.author_id != store().me;
		if missed ic_color = T("--status-danger");
		if m.kind == {
			case MSG_PIN; ic_name, ic_color = "pin", T("--text-muted");
			case MSG_FRIEND_ACCEPTED; ic_name = "user-check";
			case MSG_RECIPIENT_ADD; #through; case MSG_MEMBER_JOIN; ic_name = "arrow-large-right";
			case MSG_RECIPIENT_REMOVE; ic_name, ic_color = "arrow-large-left", T("--status-danger");
			case MSG_NAME_CHANGE; #through; case MSG_ICON_CHANGE; ic_name, ic_color = "pencil", T("--text-muted");
			case MSG_POLL_RESULT; ic_name, ic_color = "analytics", T("--text-muted");
			case MSG_CHANNEL_FOLLOW; ic_name, ic_color = "announcements", T("--text-muted");
			case MSG_THREAD_CREATED; #through; case MSG_THREAD_STARTER; ic_name, ic_color = "thread", T("--text-muted");
			case MSG_AUTOMOD; ic_name, ic_color = "flag", T("--text-muted");
			case MSG_ROLE_SUB; ic_name, ic_color = "star", T("--text-muted");
		}
		if m.kind >= MSG_INCIDENT_FIRST && m.kind <= MSG_INCIDENT_FIRST + 3 then ic_name, ic_color = "flag", T("--text-muted");
		if m.kind >= MSG_BOOST && m.kind <= MSG_BOOST + 3 then ic_name, ic_color = "star", T("--text-muted");
		if m.kind >= MSG_DISCOVERY_FIRST && m.kind <= MSG_DISCOVERY_FIRST + 3 then ic_name, ic_color = ifx m.kind == MSG_DISCOVERY_FIRST + 1 then "compass" else "warning", T("--text-muted");
		if m.kind >= MSG_STAGE_FIRST && m.kind <= MSG_STAGE_FIRST + 4 then ic_name, ic_color = "stage", T("--text-muted");
		{ ui.parent(g); defer ui.pop_parent();
			ic := icon("ic", ic_name, 16, ic_color);
			ic.flags |= .Floating_X | .Floating_Y;
			ic.fixed_pos = .{28, (CALL_ROW_H - 16) / 2};
		}
		spans: [..]ui.Span;
		spans.allocator = temp;
		muted := ui.Span.{font = F(.Normal), size = chat_px(MSG_FONT), color = T("--text-muted")};
		strong := ui.Span.{font = F(.Medium), size = chat_px(MSG_FONT), color = T("--text-strong")};
		add :: (spans: *[..]ui.Span, s: ui.Span, text: string) { x := s; x.text = text; array_add(spans, x); }
		span :: (s: ui.Span, text: string, id := 0) -> ui.Span { x := s; x.text = text; x.id = xx id; return x; }
		// a user's name: clicking it opens their profile, as in the client
		who :: (s: ui.Span, uid: dc.Snowflake, channel_id: dc.Snowflake) -> ui.Span {
			x := s;
			x.text = name_in(uid, channel_id);
			x.user = cast(*void) uid;
			return x;
		}
		// a translated sentence: its text muted, %1 %2 (or % in order) replaced by the given spans
		fill :: (spans: *[..]ui.Span, muted: ui.Span, format: string, args: ..ui.Span) {
			f := format;
			next := 0;
			while f {
				i := find_index_from_left(f, #char "%");
				if i < 0 { add(spans, muted, f); break; }
				if i add(spans, muted, slice(f, 0, i));
				advance(*f, i + 1);
				k := next;
				if f && f[0] >= #char "1" && f[0] <= #char "9" { k = f[0] - #char "1"; advance(*f, 1); }
				next = k + 1;
				if k < args.count array_add(spans, args[k]);
			}
		}
		author := who(strong, m.author_id, m.channel_id);
		if friend {
			// the other user's name, whoever sent it; their note (content) is quoted when there is one
			ch := dc.channel_get(store(), m.channel_id);
			other := ifx ch && ch.recipient_ids.count then ch.recipient_ids[0] else m.author_id;
			mine := m.author_id == store().me;
			fill(*spans, muted, ifx mine then L("You accepted %'s friend request.") else L("% accepted your friend request."), who(strong, other, m.channel_id));
			if m.content != "" {
				add(*spans, muted, " ");
				fill(*spans, muted, ifx mine then L("They said: %") else L("You said: %"), span(strong, m.content));
			}
		} else if m.kind == MSG_RECIPIENT_ADD || m.kind == MSG_RECIPIENT_REMOVE {
			// the other user is the first mention; removing yourself is leaving
			other := ifx m.mentions.count then m.mentions[0] else 0;
			if m.kind == MSG_RECIPIENT_REMOVE && (other == 0 || other == m.author_id) fill(*spans, muted, L("% left the group."), author);
			else fill(*spans, muted, ifx m.kind == MSG_RECIPIENT_ADD then L("%1 added %2 to the group.") else L("%1 removed %2 from the group."), author, who(strong, other, m.channel_id));
		} else if m.kind == MSG_NAME_CHANGE {
			if m.content == "" fill(*spans, muted, L("% removed the custom group name."), author);
			else {
				ch := dc.channel_get(store(), m.channel_id);
				fill(*spans, muted, ifx ch && ch.kind == .Group_DM then L("%1 changed the group name: %2.") else L("%1 changed the channel name: %2."), author, span(strong, m.content));
			}
		} else if m.kind == MSG_MEMBER_JOIN {
			// getSystemMessageUserJoin: the message's snowflake time picks one of 13 lines
			JOIN := string.[L("% joined the party."), L("% is here."), L("Welcome, %. We hope you brought pizza."), L("A wild % appeared."),
				L("% just landed."), L("% just slid into the server."), L("% just showed up!"), L("Welcome %. Say hi!"),
				L("% hopped into the server."), L("Everyone welcome %!"), L("Glad you're here, %."), L("Good to see you, %."),
				L("Yay you made it, %!")];
			fill(*spans, muted, JOIN[dc.snowflake_time_ms(m.id) % JOIN.count], author);
		} else if m.kind == MSG_ICON_CHANGE {
			fill(*spans, muted, L("% changed the group icon."), author);
		} else if m.kind == MSG_POLL_RESULT {
			fill(*spans, muted, L("%1's poll %2 has closed."), author, span(strong, poll_result_field(m, "poll_question_text")));
		} else if pin {
			// "a message" jumps to the pinned message and "pinned messages" opens the pins (span ids 1, 2)
			fill(*spans, muted, L("%1 pinned %2 to this channel. See all %3."), author, span(strong, L("a message"), 1), span(strong, L("pinned messages"), 2));
		} else if m.kind >= MSG_BOOST && m.kind <= MSG_BOOST + 3 {
			// the client's strings, without its "Learn more" about Boosts
			n := string_to_int(m.content);
			if n > 1 fill(*spans, muted, L("%1 just boosted the server %2 times!"), author, span(strong, tprint("%", n)));
			else fill(*spans, muted, L("% just boosted the server!"), author);
			if m.kind > MSG_BOOST {
				ch := dc.channel_get(store(), m.channel_id);
				g := ifx ch then dc.guild_get(store(), ch.guild_id) else null;
				add(*spans, muted, " ");
				fill(*spans, muted, L("%1 has achieved %2"), span(muted, ifx g then g.name else L("The server")), span(strong, tprint(L("Level %!"), m.kind - MSG_BOOST)));
			}
		} else if m.kind == MSG_CHANNEL_FOLLOW {
			fill(*spans, muted, L("%1 has added %2 to this channel. Its most important updates will show up here."), author, span(strong, m.content));
		} else if m.kind >= MSG_DISCOVERY_FIRST && m.kind <= MSG_DISCOVERY_FIRST + 3 {
			DISCOVERY := string.[
				L("This server has been removed from Server Discovery because it no longer passes all the requirements. Check Server Settings for more details."),
				L("This server is eligible for Server Discovery again and has been automatically relisted!"),
				L("This server has failed Discovery activity requirements for 1 week. If this server fails for 4 weeks in a row, it will be automatically removed from Discovery."),
				L("This server has failed Discovery activity requirements for 3 weeks in a row. If this server fails for 1 more week, it will be removed from Discovery.")];
			add(*spans, muted, DISCOVERY[m.kind - MSG_DISCOVERY_FIRST]);
		} else if m.kind == MSG_THREAD_CREATED {
			// the thread's name opens it (span id 4), "threads" the threads browser (5)
			fill(*spans, muted, L("%1 started a thread: %2. See all %3."), author, span(strong, m.content, 4), span(strong, L("threads"), 5));
		} else if m.kind >= MSG_STAGE_FIRST && m.kind <= MSG_STAGE_FIRST + 4 {
			STAGE := string.[L("%1 started %2"), L("%1 ended %2"), L("%1 is now a speaker."), L("%1 requested to speak."), L("%1 changed the Stage topic: %2")];
			fill(*spans, muted, STAGE[m.kind - MSG_STAGE_FIRST], author, span(strong, m.content));
		} else if m.kind == MSG_THREAD_STARTER {
			add(*spans, muted, L("Sorry, we couldn't load the first message in this thread"));
		} else if m.kind == MSG_AUTOMOD {
			// the client's AutoMod alert: the rule's fields ride on the embed (decision_outcome "flagged" or not)
			e := ifx m.embeds.count then *m.embeds[0] else null;
			ch := dc.channel_get(store(), automod_channel(m));
			where := span(strong, ifx ch then tprint("#%", ch.name) else L("a channel"), ifx ch then 6 else 0);
			fill(*spans, muted, ifx automod_field(e, "decision_outcome") == "flagged" then L("%1 has flagged a message in %2") else L("%1 has blocked a message in %2"), span(strong, "AutoMod"), where);
			add(*spans, muted, "\n");
			fill(*spans, muted, L("%1: %2"), author, span(.{font = F(.Normal), size = chat_px(MSG_FONT), color = T("--text-default")}, ifx e then e.description else ""));
			rule, kw := automod_field(e, "rule_name"), automod_field(e, "keyword");
			if rule add(*spans, muted, tprint("\n%", tprint(L("Rule: %"), rule)));
			if kw add(*spans, muted, tprint(" · %", tprint(L("Keyword: %"), kw)));
		} else if m.kind == MSG_ROLE_SUB {
			// the client's lines, with the server's name not a link to its subscriptions page
			ch := dc.channel_get(store(), m.channel_id);
			g := ifx ch then dc.guild_get(store(), ch.guild_id) else null;
			server := span(strong, ifx g then g.name else L("this server"));
			n := m.sub_months;
			if n > 0 fill(*spans, muted, ifx m.sub_renewal then Lp("%1 renewed %2 and has been a subscriber of %3 for %4 month!", "%1 renewed %2 and has been a subscriber of %3 for %4 months!", n)
				else Lp("%1 joined %2 and has been a subscriber of %3 for %4 month!", "%1 joined %2 and has been a subscriber of %3 for %4 months!", n), author, span(strong, m.content), server, span(muted, tprint("%", n)));
			else fill(*spans, muted, ifx m.sub_renewal then L("%1 renewed %2 in their %3 membership!") else L("%1 joined %2 as a subscriber of %3!"), author, span(strong, m.content), server);
		} else if m.kind >= MSG_INCIDENT_FIRST && m.kind <= MSG_INCIDENT_FIRST + 3 {
			// sent as AutoMod: enabling carries the end time as content
			k := m.kind - MSG_INCIDENT_FIRST;
			if k == 0 {
				until := dc.iso_to_ms(m.content);
				if until > 0 fill(*spans, muted, L("%1 enabled security actions until %2."), author, span(muted, format_time_ms(until)));
				else fill(*spans, muted, L("% enabled security actions."), author);
			} else if k == 1 {
				fill(*spans, muted, L("% disabled security actions."), author);
			} else {
				ch := dc.channel_get(store(), m.channel_id);
				g := ifx ch then dc.guild_get(store(), ch.guild_id) else null;
				fill(*spans, muted, ifx k == 2 then L("%1 reported a raid in %2.") else L("%1 resolved an Activity Alert in %2."), author, span(strong, ifx g then g.name else L("this server")));
			}
		} else if missed {
			fill(*spans, muted, L("You missed a call from %1 that lasted %2."), author, span(muted, humanize_duration(dc.iso_to_ms(m.call_ended) - dc.iso_to_ms(m.timestamp))));
		} else {
			if m.call_ended fill(*spans, muted, L("%1 started a call that lasted %2."), author, span(muted, humanize_duration(dc.iso_to_ms(m.call_ended) - dc.iso_to_ms(m.timestamp))));
			else fill(*spans, muted, L("% started a call."), author);
			// the client's "Join the call" (span id 3): this message's call is still going and we aren't in it
			call := ifx app.client then dc.call_get(app.client, m.channel_id) else null;
			if call && call.message_id == m.id && app.voice_channel != m.channel_id {
				add(*spans, muted, " ");
				array_add(*spans, span(.{font = F(.Medium), size = MSG_FONT, color = T("--text-link")}, L("Join the call"), 3));
			}
		}
		add(*spans, .{font = F(.Medium), size = 12, color = T("--chat-text-muted")}, tprint(" %", header_timestamp(m.id)));
		b := ui.box("text", .Selectable_Text | .Wrap_Text);
		b.semantic_size = .[ui.fill(), ui.text_size()];
		b.style.line_height = MSG_LINE_H;
		b.style.padding = .{0, (CALL_ROW_H - MSG_LINE_H) / 2};
		ui.set_spans(b, spans);
		b.sel_order = m.id * 8 + 2;
		tl := b.prev_layout;
		if tl && ui.mouse_over(b) && !ui.overlay_at(app.ui.mouse) {
			si := ui.span_at(tl, app.ui.mouse);
			if si >= 0 && si < tl.spans.count && (tl.spans[si].user || tl.spans[si].id) app.ui.span_cursor = .Pointer;
		}
		if tl for e: app.ui.events {
			if e.kind != .Mouse_Up || e.button != .Left || e.consumed || ui.has_selection() || ui.overlay_at(e.pos) continue;
			si := ui.span_at(tl, e.pos);
			if si < 0 || si >= tl.spans.count continue;
			if tl.spans[si].id == {
				case 1; if m.referenced_id jump_to_message(m.channel_id, m.referenced_id);
				case 2; pins_toggle(m.channel_id, header_pin_rect);
				case 3; call_join_incoming(m.channel_id);
				case 4;
					th := dc.channel_get(store(), m.forward_channel_id);
					if th select_channel(th.guild_id, th.id);
				case 5; threads_browser_toggle(m.channel_id, header_thread_rect);
				case 6;
					ch := dc.channel_get(store(), automod_channel(m));
					if ch select_channel(ch.guild_id, ch.id);
			}
			if tl.spans[si].user == null continue;
			open_profile(cast(dc.Snowflake) tl.spans[si].user, .{e.pos.x, e.pos.y - 10, e.pos.x + 1, e.pos.y + 10});
		}
		spacer(.X, 48);
	}
}

// An AutoMod alert's embed field (rule_name, keyword, channel_id, decision_outcome), "" when absent.
automod_field :: (e: *dc.Embed, name: string) -> string {
	if e for e.fields if it.name == name return it.value;
	return "";
}
automod_channel :: (m: *dc.Message) -> dc.Snowflake {
	v, ok := string_to_int(automod_field(ifx m.embeds.count then *m.embeds[0] else null, "channel_id"), T = u64);
	return ifx ok then v else 0;
}

message_header :: (m: *dc.Message, with_time := true) {
	name := author_name(m);
	h := row("header");
	h.semantic_size = .[ui.pct(1), ui.px(chat_px(MSG_LINE_H))];
	h.cross_align = .End;
	{ ui.parent(h); defer ui.pop_parent();
		n := label(name, .Medium, chat_px(16), author_color(m), chat_px(MSG_LINE_H));
		n.flags |= .Clickable | .Selectable_Text;
		n.sel_order = m.id * 8;
		nsig := ui.signal(n);
		if nsig.clicked open_profile(m.author_id, n.rect, .Message_Author, m.id, m.webhook_name);
		if nsig.right_clicked && !m.webhook_name open_user_menu(m.author_id, app.ui.mouse);
		if a11y.role_colors == 1 { // the role's colour as a dot after the name
			ch := dc.channel_get(store(), m.channel_id);
			rc, ok := member_color(ifx ch then ch.guild_id else 0, m.author_id, raw = true);
			if ok {
				spacer(.X, 4);
				d := ui.box("roledot", .Draw_Background);
				d.semantic_size = .[ui.px(8), ui.px(8)];
				d.style.radius = all4(4);
				d.style.bg = rc;
			}
		}
		u := dc.user_get(store(), m.author_id);
		if !m.webhook_name server_tag(u);
		if u && u.bot app_tag();
		if !m.webhook_name { ch := dc.channel_get(store(), m.channel_id); if ch role_icon(ch.guild_id, m.author_id, 20); }
		new_member_badge(m);
		if with_time {
			spacer(.X, 8);
			// copies as "Name — 4:56 AM" like the client's hidden separator
			ts := label(header_timestamp(m.id), .Medium, chat_px(12), T("--chat-text-muted"), chat_px(20));
			ts.flags |= .Selectable_Text;
			ts.sel_order = m.id * 8 + 1;
			ts.sel_join = " — ";
			if ui.mouse_over(ts) tooltip_below(full_timestamp(dc.snowflake_time_ms(m.id)), ts.rect);
		}
		if m.flags & SUPPRESS_NOTIFICATIONS || encrypted_silent(m.id) {
			spacer(.X, 4);
			bell := icon("silent", "bell-slash", 16, T("--chat-text-muted"), .Clickable);
			if ui.signal(bell).hovering tooltip_below(L("Suppress Notifications"), bell.rect);
		}
		mark := e2e_mark(m);
		if mark != .None { spacer(.X, 4); e2e_mark_icon(mark, 16); }
		if mark == .Plain { spacer(.X, 4); label(L("Not encrypted"), .Medium, 12, T("--text-feedback-warning"), 20); }
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
	b.hover_cursor = .Pointer;
	sig := ui.signal(b);
	if sig.hovering && newcomer.msg != m.id tooltip_below(L("I'm new here, say hi!"), b.rect);
	if sig.clicked {
		newcomer = .{msg = m.id, user = m.author_id, channel = m.channel_id, anchor = b.rect};
		if app.client dc.track_new_member_popout(app.client, ch.guild_id, m.channel_id);
	}
}

#scope_export

// The sprout's popout (the client's NewMemberBadgePopout): "Mention @name" puts their mention in the composer.
Newcomer :: struct { msg, user, channel: dc.Snowflake; anchor: ui.Rect; }
newcomer: Newcomer;

new_member_popout :: () {
	if !newcomer.msg return;
	ch := dc.channel_get(store(), newcomer.channel);
	u := dc.user_get(store(), newcomer.user);
	if !ch || !u || app.view.channel != ch.id || outside_pressed("newcomer_scrim") || escape_pressed() { newcomer = .{}; return; }
	W :: cast(float32) 300;
	p := ui.box("newcomer", .Draw_Background | .Draw_Border | .Draw_Shadow | .Floating_X | .Floating_Y | .Overlay | .Clickable);
	h := p.rect.y1 - p.rect.y0; // last frame's
	p.semantic_size = .[ui.px(W), ui.children()];
	p.fixed_pos = .{min(newcomer.anchor.x0, app.ui.window.x - W - 8), max(8.0, newcomer.anchor.y0 - h - 8)};
	p.layout_axis = .Y;
	p.style.bg = T("--background-surface-higher");
	p.style.border = 1;
	p.style.border_color = T("--border-subtle");
	p.style.radius = all4(8);
	p.style.shadow_color = .{0, 0, 0, 0.3};
	p.style.shadow_blur = 16;
	ui.signal(p);
	ui.parent(p); defer ui.pop_parent();
	inset_begin(16, 16);
	defer inset_end(16, 16);
	top := row("top");
	top.semantic_size = .[ui.pct(1), ui.children()];
	{ ui.parent(top); defer ui.pop_parent();
		icon("sprout", "new-member", 40, T("--text-feedback-positive"));
		spacer(.X, 12);
		col := ui.box("col");
		col.semantic_size = .[ui.fill(), ui.children()];
		col.layout_axis = .Y;
		ui.parent(col); defer ui.pop_parent();
		label(L("I'm new here, say hi!"), .Semibold, 16, T("--text-strong"), 20);
		t := label(L("System icon for new server members."), .Normal, 14, T("--text-default"), 18);
		t.flags |= .Wrap_Text;
		t.semantic_size = .[ui.pct(1), ui.text_size()];
	}
	spacer(.Y, 12);
	if composer_blocked(ch) return; // the client hides the button where you can't send
	b := row("mention", .Clickable | .Draw_Background | .Hot_Animation);
	b.semantic_size = .[ui.pct(1), ui.px(32)];
	b.style.radius = all4(8);
	b.style.bg = T("--background-brand");
	b.style.bg_hot = with_alpha(b.style.bg, 0.85);
	b.hover_cursor = .Pointer;
	{ ui.parent(b); defer ui.pop_parent(); filler(.X); label(tprint(L("Mention %"), u.username), .Medium, 14, .{1, 1, 1, 1}, 18); filler(.X); }
	if ui.signal(b).clicked {
		if app.client dc.track_new_member_mention(app.client, ch.guild_id, ch.id, u.id);
		ui.editor_insert(*chat_state(ch.id).editor, tprint("@% ", u.username));
		newcomer = .{};
	}
}

// An announcement channel's header Follow (servers with NEWS): a modal picks one of your servers and a
// text channel there you have Manage Webhooks in, and the channel's published messages are posted to it.
Follow_UI :: struct { channel: dc.Snowflake; guild, target: int; guilds, targets: [..]dc.Snowflake; }
fol: Follow_UI;
FOLLOW_REQ :: "follow";

follow_button :: (ch: *dc.Channel) {
	g := dc.guild_get(store(), ch.guild_id);
	if ch.kind != .Guild_Announcement || !g || !dc.guild_has_feature(g, "NEWS") || on_hosted() return;
	spacer(.X, 12);
	if ui.signal(fol_button("follow", L("Follow"), false, 24, 12)).clicked {
		fol.channel, fol.guild, fol.target = ch.id, 0, 0;
		req_clear(FOLLOW_REQ);
	}
}

fol_button :: (id: string, text: string, primary: bool, h: float32, pad: float32) -> *ui.Box {
	b := row(id, .Clickable | .Draw_Background | .Hot_Animation);
	b.semantic_size = .[ui.children(), ui.px(h)];
	b.style.radius = all4(8);
	b.style.bg = ifx primary then T("--background-brand") else T("--background-mod-normal");
	b.style.bg_hot = with_alpha(b.style.bg, 0.85);
	b.hover_cursor = .Pointer;
	b.cross_align = .Center;
	ui.parent(b); defer ui.pop_parent();
	spacer(.X, pad);
	if !(primary && req_state(FOLLOW_REQ) == .Pending) label(text, .Medium, 14, ifx primary then ui.Color.{1, 1, 1, 1} else T("--text-default"), 18);
	else spacer(.X, DOTS_W);
	spacer(.X, pad);
	return b;
}

follow_modal :: () {
	if !fol.channel return;
	s := store();
	// your servers with a text channel you can make webhooks in, and those channels in the picked one
	fol.guilds.count, fol.targets.count = 0, 0;
	for gid: guild_order() {
		g := dc.guild_get(s, gid);
		if g for cid: g.channels {
			c := dc.channel_get(s, cid);
			if c && c.kind == .Guild_Text && dc.has_permission(dc.channel_permissions(s, cid), dc.PERM_MANAGE_WEBHOOKS) { array_add(*fol.guilds, gid); break; }
		}
	}
	fol.guild = clamp(fol.guild, 0, max(fol.guilds.count - 1, 0));
	if fol.guilds.count {
		g := dc.guild_get(s, fol.guilds[fol.guild]);
		for cid: g.channels {
			c := dc.channel_get(s, cid);
			if c && c.kind == .Guild_Text && dc.has_permission(dc.channel_permissions(s, cid), dc.PERM_MANAGE_WEBHOOKS) array_add(*fol.targets, cid);
		}
	}
	fol.target = clamp(fol.target, 0, max(fol.targets.count - 1, 0));
	scrim := ui.box("follow_scrim", .Draw_Background | .Clickable | .Floating_X | .Floating_Y | .Overlay);
	scrim.semantic_size = .[ui.px(app.ui.window.x), ui.px(app.ui.window.y)];
	scrim.style.bg = .{0, 0, 0, 0.7};
	if (ui.signal(scrim).clicked && !select_is_open()) || (escape_pressed() && !select_is_open()) { fol.channel = 0; select_close(); return; }
	W :: cast(float32) 440;
	d := ui.box("follow_modal", .Draw_Background | .Draw_Border | .Floating_X | .Floating_Y | .Overlay | .Clickable);
	d.semantic_size = .[ui.px(W), ui.children()];
	d.fixed_pos = .{(app.ui.window.x - W) / 2, max(16.0, (app.ui.window.y - (d.rect.y1 - d.rect.y0)) / 2)};
	d.style.bg = T("--modal-background");
	d.style.border_color = T("--border-subtle");
	d.style.border = 1;
	d.style.radius = all4(12);
	d.layout_axis = .Y;
	ui.signal(d);
	{ ui.parent(d); defer ui.pop_parent();
		inset_begin(16, 16);
		defer inset_end(16, 16);
		st, _ := req_state(FOLLOW_REQ);
		if st == .Done {
			label(L("Followed!"), .Semibold, 20, T("--text-strong"), 24);
			spacer(.Y, 8);
			set_para("fol_done", L("The most important updates from this channel will now show up directly in your server. Enjoy!"), .Normal, 14, 18, T("--text-default"));
			spacer(.Y, 16);
			if ui.signal(fol_button("fol_finish", L("Finish"), true, 32, 16)).clicked fol.channel = 0;
			return;
		}
		label(L("Add this channel's updates to your server!"), .Semibold, 20, T("--text-strong"), 24);
		spacer(.Y, 8);
		set_para("fol_sub", L("Select where you want these updates to go. You can remove this at any time in Server Settings > Integrations > Channels Followed."), .Normal, 14, 18, T("--text-muted"));
		spacer(.Y, 16);
		if !fol.guilds.count {
			set_para("fol_none", L("Uh oh, you don't have webhook permissions in any server you're in. Ask your server admin to give you the permission or ask them to come follow themselves!"), .Normal, 14, 18, T("--text-default"));
			return;
		}
		names :: (ids: []dc.Snowflake, guilds: bool) -> []string {
			out := NewArray(ids.count, string,, temp);
			for ids {
				if guilds { g := dc.guild_get(store(), it); out[it_index] = ifx g then g.name else ""; }
				else { c := dc.channel_get(store(), it); out[it_index] = ifx c then tprint("#%", c.name) else ""; }
			}
			return out;
		}
		label(L("SELECT A SERVER"), .Bold, 12, T("--text-muted"), 16);
		spacer(.Y, 8);
		pick := select_field("fol_guild", names(fol.guilds, true), fol.guild);
		if pick >= 0 && pick != fol.guild { fol.guild, fol.target = pick, 0; req_clear(FOLLOW_REQ); }
		spacer(.Y, 16);
		label(L("SELECT A CHANNEL"), .Bold, 12, T("--text-muted"), 16);
		spacer(.Y, 8);
		pick = select_field("fol_chan", names(fol.targets, false), fol.target);
		if pick >= 0 { fol.target = pick; req_clear(FOLLOW_REQ); }
		spacer(.Y, 8);
		label(L("Only servers and channels you have webhook permissions in are shown."), .Normal, 12, T("--text-muted"), 16);
		if st == .Failed {
			code, _ := req_error(FOLLOW_REQ);
			spacer(.Y, 8);
			set_para("fol_err", ifx code == 30007 then L("The selected channel has too many webhooks. Please remove a webhook or select another channel.") else L("Failed to follow the channel, please try again."), .Normal, 14, 18, T("--text-feedback-critical"));
		}
		spacer(.Y, 16);
		r := row("fol_btns");
		r.semantic_size = .[ui.pct(1), ui.px(32)];
		ui.parent(r); defer ui.pop_parent();
		filler(.X);
		if req_button(fol_button("fol_go", L("Follow"), true, 32, 16), FOLLOW_REQ) && fol.targets.count && req_begin(FOLLOW_REQ, inline_error = true) {
			dc.follow_channel(app.client, fol.channel, fol.targets[fol.target]);
			req_end();
		}
	}
	dropdown_list();
}

#scope_file

// The client's welcome stickers (USER_JOIN's "Wave to say hi!"), picked by our id and the message's.
Wave_Sticker :: struct { id: dc.Snowflake; format: int; }
WAVE_STICKERS :: Wave_Sticker.[
	.{749054660769218631, 3}, .{751606379340365864, 3}, .{754108890559283200, 3},
	.{781291131828699156, 2}, .{816087792291282944, 3}, .{819128604311027752, 3}];

// Under a member's join message: "Wave to say hi!" with a sticker, which replies to the join with it
// (hidden when the server turned off join replies, system channel flag 8, or you can't send there).
// A hosted server has no Discord stickers: its /greet replies with a waving hand.
wave_button :: (m: *dc.Message) {
	s := store();
	ch := dc.channel_get(s, m.channel_id);
	u := dc.user_get(s, m.author_id);
	if !ch || !ch.guild_id || (u && u.bot) || composer_blocked(ch) return;
	g := dc.guild_get(s, ch.guild_id);
	if !g || (g.system_channel_flags & 8) return;
	st := WAVE_STICKERS[(dc.snowflake_time_ms(s.me) + dc.snowflake_time_ms(m.id)) % WAVE_STICKERS.count];
	r := row("waverow");
	r.semantic_size = .[ui.pct(1), ui.px(40)];
	ui.parent(r); defer ui.pop_parent();
	spacer(.X, MSG_GUTTER);
	b := row("wave", .Clickable | .Draw_Background | .Hot_Animation);
	b.semantic_size = .[ui.children(), ui.px(36)];
	b.style.radius = all4(8);
	b.style.bg = T("--background-mod-normal");
	b.style.bg_hot = T("--background-mod-strong");
	b.hover_cursor = .Pointer;
	b.cross_align = .Center;
	sig := ui.signal(b);
	{ ui.parent(b); defer ui.pop_parent();
		spacer(.X, 12);
		if !on_hosted() sticker_box("st", .{id = st.id, format_type = st.format}, 24, sig.hovering && app.focused);
		spacer(.X, 8);
		label(L("Wave to say hi!"), .Medium, 14, T("--text-default"), 18);
		spacer(.X, 12);
	}
	if sig.clicked && net_action() {
		dc.greet_message(app.client, ch.guild_id, ch.id, m.id, st.id);
		if !on_hosted() dc.track_welcome_cta(app.client, st.id, m.author_id);
	}
}

// Under a message whose send failed: why, when Discord said, then Retry sends a fresh copy (same text and
// reply), Delete forgets it locally.
failed_send_note :: (m: *dc.Message) {
	why := send_error_text(m.send_error);
	if why {
		w := ui.box(tprint("%##failedwhy", why), .Draw_Text | .Wrap_Text);
		w.semantic_size = .[ui.pct(1), ui.text_size()];
		w.style.font = F(.Normal);
		w.style.font_size = 12;
		w.style.line_height = 16;
		w.style.text_color = T("--text-feedback-critical");
	}
	r := row("failednote");
	r.semantic_size = .[ui.pct(1), ui.px(20)];
	ui.parent(r); defer ui.pop_parent();
	label(L("Message failed to send."), .Normal, 12, T("--text-feedback-critical"), 16);
	link :: (text: string) -> bool {
		spacer(.X, 6);
		b := label(text, .Medium, 12, T("--text-link"), 16);
		b.flags |= .Clickable;
		b.hover_cursor = .Pointer;
		return ui.signal(b).clicked;
	}
	files := attachments_retry(m.id); // a message with files retries with the ones it uploaded
	retry := ifx m.attachments then files.count > 0 else m.content != "";
	retry = retry && link(L("Retry"));
	discard := link(L("Delete"));
	if discard dc.drop_message(store(), m.channel_id, m.id);
	if !retry || !net_action() return;
	text := copy_string(m.content,, temp);
	cid, reply, old := m.channel_id, m.referenced_id, m.id;
	files = array_copy(files,, temp);
	dc.drop_message(store(), cid, m.id);
	ch := dc.channel_get(store(), cid);
	nonce := dc.send_message(app.client, cid, text, .{reply_to = reply, reply_guild_id = ifx ch then ch.guild_id, attachments = files});
	if files attachments_retry_moved(old, nonce);
}

// send_error_text: what a failed send's error code means ("" when there's nothing more to say).
send_error_text :: (code: s32) -> string {
	if code == {
	case 50007; return L("Your message could not be delivered. This is usually because you don't share a server with the recipient or the recipient is only accepting direct messages from friends.");
	case 50278; return L("Your message could not be delivered because you don't share a server with the recipient. Add them as a friend, or join a server you're both in, to message them.");
	}
	return "";
}

// A message's parsed markdown, kept (on the heap) until no row has drawn that text for MD_KEEP_FRAMES, so
// a visible message is parsed once, not every frame. Keyed by the text itself: an edit is a new entry.
Md_Cached :: struct { text: string; blocks: []Md_Block; used: u64; }
md_cache: Table(u64, Md_Cached);
md_swept: u64;
MD_KEEP_FRAMES :: 600;

md_cached :: (text: string) -> []Md_Block {
	h := fnv1a_hash(text.data, text.count);
	e := table_find_pointer(*md_cache, h);
	if e && e.text == text { e.used = app.frame; return e.blocks; }
	if app.frame - md_swept > MD_KEEP_FRAMES {
		md_swept = app.frame;
		stale: [..]u64;
		stale.allocator = temp;
		for md_cache if app.frame - it.used > MD_KEEP_FRAMES array_add(*stale, it_index);
		for stale { old := table_find_pointer(*md_cache, it); md_free(old); table_remove(*md_cache, it); }
		e = table_find_pointer(*md_cache, h);
	}
	if e md_free(e); // a different text with the same hash: replaced
	entry := Md_Cached.{text = copy_string(text), blocks = md_copy(md_parse(text)), used = app.frame};
	table_set(*md_cache, h, entry);
	return entry.blocks;
}

md_copy :: (blocks: []Md_Block) -> []Md_Block {
	out := array_copy(blocks);
	for * b: out {
		b.lang, b.code = copy_string(b.lang), copy_string(b.code);
		b.tokens = array_copy(b.tokens);
		for * b.tokens { it.text, it.name, it.url = copy_string(it.text), copy_string(it.name), copy_string(it.url); }
	}
	return out;
}

md_free :: (e: *Md_Cached) {
	for b: e.blocks {
		free(b.lang);
		free(b.code);
		for b.tokens { free(it.text); free(it.name); free(it.url); }
		array_free(b.tokens);
	}
	array_free(e.blocks);
	free(e.text);
}

// terms: search words to highlight (search result cards).
// Compact puts the author's name at the start of the first block when that is plain text.
compact_name_inline :: (m: *dc.Message) -> bool {
	if m.content == "" || m.forwarded || begins_with(packet_text(m.content), fc_text.PREFIX) return false;
	blocks := md_cached(m.content);
	return blocks.count > 0 && blocks[0].kind == .Paragraph && !(blocks.count == 1 && is_emoji_only(blocks[0].tokens));
}

NAME_SPAN : u64 : 0xffff_ffff_ffff_ffe0; // compact's name span at the start of the first paragraph

message_body :: (m: *dc.Message, terms: []string = .[], decrypted := false, name_inline := false) {
	if m.content == "" return;
	if !decrypted {
		handled, plaintext := encrypted_body(m);
		if plaintext != "" {
			plain := m.*;
			plain.content = plaintext;
			message_body(*plain, terms, true);
		}
		if handled return;
	}
	blocks := md_cached(m.content);
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
			code := code_spans(blk.code, blk.lang, F(.Mono), chat_px(14));
			ui.set_spans(cb, ifx terms then highlight_spans(code, terms) else code);
			cb.semantic_size = .[ifx blk.quoted then ui.fill() else ui.pct(1), ui.text_size()];
			cb.style.bg = T("--background-base-lowest");
			cb.style.border_color = T("--border-subtle");
			cb.style.border = 1;
			cb.style.radius = all4(4);
			cb.style.font = F(.Mono);
			cb.style.font_size = chat_px(14);
			cb.style.line_height = chat_px(18);
			cb.style.padding = .{8, 8};
			cb.style.text_color = T("--text-code");
			cb.sel_order = m.id * 8 + 2;
			cb.sel_sub = cast(u32) bi;
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
			size, line_h = chat_px(size), chat_px(line_h);
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
					for * spans if it.object != .{} it.object = emoji_object(chat_px(48), size);
					b.style.line_height = chat_px(56);
				}
				if name_inline && bi == 0 {
					named := NewArray(spans.count + 2, ui.Span,, temp);
					named[0] = .{text = author_name(m), font = F(.Medium), size = size, color = author_color(m), id = NAME_SPAN};
					named[1] = .{text = " ", font = F(.Normal), size = size, id = NAME_SPAN + 1};
					memcpy(named.data + 2, spans.data, spans.count * size_of(ui.Span));
					spans = named;
				}
				if bi == blocks.count - 1 && m.edited_timestamp {
					// "(edited)" rides at the end of the last paragraph, like the client
					edited := NewArray(spans.count + 1, ui.Span,, temp);
					memcpy(edited.data, spans.data, spans.count * size_of(ui.Span));
					edited[spans.count] = .{text = tprint(" %", L("(edited)")), font = F(.Normal), size = chat_px(10), color = T("--text-muted"), id = EDITED_SPAN};
					spans = edited;
					edited_inline = true;
				}
				if terms spans = highlight_spans(spans, terms);
				ui.set_spans(b, spans);
				b.sel_order = m.id * 8 + 2;
				b.sel_sub = cast(u32) bi;
			}
			handle_span_clicks(b, blk.tokens, m.id, ifx edited_inline then dc.iso_to_ms(m.edited_timestamp) else 0);
			if name_inline && bi == 0 compact_name_clicks(b, m);
		}
	}
	if m.edited_timestamp && !edited_inline {
		ed := label(L("(edited)"), .Normal, chat_px(10), T("--text-muted"), chat_px(22));
		if ui.mouse_over(ed) tooltip_below(full_timestamp(dc.iso_to_ms(m.edited_timestamp)), ed.rect);
	}
}

// Compact's inline name opens the profile like the header's (right-click gives the message menu).
compact_name_clicks :: (b: *ui.Box, m: *dc.Message) {
	tl := b.prev_layout;
	if !tl return;
	on_name :: (p: ui.Vec2) -> bool #expand {
		si := ui.span_at(`tl, p);
		return si >= 0 && si < `tl.spans.count && `tl.spans[si].id == NAME_SPAN && !ui.overlay_at(p);
	}
	if ui.mouse_over(b) && on_name(app.ui.mouse) app.ui.span_cursor = .Pointer;
	for e: app.ui.events {
		if e.kind != .Mouse_Up || e.button != .Left || e.consumed || ui.has_selection() || !on_name(e.pos) continue;
		open_profile(m.author_id, .{e.pos.x, e.pos.y - 10, e.pos.x + 1, e.pos.y + 10}, .Message_Author, m.id, m.webhook_name);
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
		label(L("Forwarded"), .Italic, 14, T("--text-muted"), 18);
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

// A pill's count width for wrapping, from one digit's, measured once: shaping every count each frame
// cost a text layout per reaction (gg sans digits are tabular).
reaction_count_w :: (n: int) -> float32 {
	if reaction_digit_w == 0 reaction_digit_w = ui.layout_text(F(.Semibold), 14, "0", -1).width;
	digits := 1;
	while n >= 10 { n /= 10; digits += 1; }
	return cast(float32) digits * reaction_digit_w;
}
reaction_digit_w: float32;

reactions_view :: (m: *dc.Message) {
	col := ui.box("reactions");
	col.semantic_size = .[ui.pct(1), ui.children()];
	col.layout_axis = .Y;
	ui.parent(col); defer ui.pop_parent();
	// Pills wrap onto new lines; the width comes from last frame's layout, so the first frame is one line.
	avail := col.rect.x1 - col.rect.x0;
	x: float32;
	lines: int;
	place :: (w: float32) #expand {
		if !`lines || (`x > 0 && `avail > 0 && `x + w > `avail) {
			if `lines ui.pop_parent();
			line := row(tprint("rl%", `lines), 0);
			line.semantic_size = .[ui.pct(1), ui.px(30)];
			line.style.child_gap = 4;
			ui.parent(line);
			`lines += 1;
			`x = 0;
		}
		`x += w + 4;
	}
	{
		// Super reactions get their own pill, tinted by the emoji's burst colour, ahead of the normal ones.
		// Clicking one only takes back your own: adding one is a Nitro feature, and we show no upsell.
		for burst: bool.[true, false] for * re, i: m.reactions {
			count := ifx burst then re.burst_count else re.count;
			if count <= 0 continue;
			me := ifx burst then re.me_burst else re.me;
			place(34 + reaction_count_w(count));
			pill := row(tprint("re%_%", i, burst), .Clickable | .Draw_Background | .Draw_Border | .Hot_Animation);
			pill.semantic_size = .[ui.children(), ui.px(26)];
			pill.style.radius = all4(8);
			pill.style.border = 1;
			if burst {
				c := ifx re.burst_color then rgb_u32(re.burst_color) else T("--reaction-border-reacted-default");
				pill.style.bg = with_alpha(c, ifx me then 0.3 else 0.15);
				pill.style.bg_hot = with_alpha(c, 0.3);
				pill.style.border_color = c;
			} else if me {
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
				label(tprint("%", count), .Semibold, 14, ifx me then T("--reaction-text-reacted-default") else T("--reaction-text-default"), 16);
				spacer(.X, 6);
			}
			if sig.hovering reactors_tooltip(m, re, burst, count, pill);
			if sig.clicked {
				if !burst react(m, re.emoji, "Message Inline Button", toggle = true);
				else if me && net_action() dc.remove_reaction(app.client, m.channel_id, m.id, re.emoji.name, re.emoji.id, burst = true, location = "Message Inline Button");
			}
		}
		if can_add_reactions(m) {
			if app.chat_hover == m.id || (picker_is_open() && pk.mode == .Reaction && pk.message == m.id) place(34);
			reaction_add_button(m);
		}
		if lines ui.pop_parent();
	}
	spacer(.Y, 2);
}

// Who reacted, under a hovered reaction pill: the first page of reactors is fetched once per
// hovered pill; the tooltip shows when it arrives.
reactors: struct {
	seq: u64;
	msg: dc.Snowflake;
	emoji_id: dc.Snowflake;
	emoji_name: string; // heap
	burst: bool;
	users: [..]dc.Snowflake;
	loaded: bool;
	paging: bool; // a later page is on its way
	hover_key: u64; // the pill hovered, and since when: the fetch waits for a short hover
	hover_since: float64;
};

// Fetch the first page of who reacted with emoji (burst: super reactions) unless it's the one held.
reactors_want :: (channel_id: dc.Snowflake, msg: dc.Snowflake, emoji: dc.Emoji, burst: bool) {
	if reactors.msg == msg && reactors.emoji_id == emoji.id && reactors.emoji_name == emoji.name && reactors.burst == burst return;
	reactors.seq += 1;
	reactors.msg, reactors.emoji_id, reactors.burst = msg, emoji.id, burst;
	free(reactors.emoji_name);
	reactors.emoji_name = copy_string(emoji.name);
	array_reset_keeping_memory(*reactors.users);
	reactors.loaded = false;
	if app.client dc.fetch_reactors(app.client, channel_id, msg, emoji.name, emoji.id, burst, reactors.seq);
}

reactors_tooltip :: (m: *dc.Message, re: *dc.Reaction, burst: bool, count: int, pill: *ui.Box) {
	if reactors.hover_key != pill.key {
		reactors.hover_key = pill.key;
		reactors.hover_since = app.ui.time;
	}
	if app.ui.time - reactors.hover_since < 0.3 {
		app.ui.animating = true;
		return;
	}
	// Encrypted reactions are known here only: Discord never saw them.
	users := encrypted_reactors(m.id, re.emoji);
	if !users {
		reactors_want(m.channel_id, m.id, re.emoji, burst);
		if !reactors.loaded || !reactors.users return;
		users = reactors.users;
	}
	shown := min(users.count, 3);
	names: [3]string;
	for i: 0..shown - 1 names[i] = name_in(users[i], m.channel_id);
	who_text: string;
	if count > shown {
		k := count - shown;
		who_text = tprint(Lp("%1 and %2 other", "%1 and %2 others", k), join(..array_view(names, 0, shown), separator = ", ",, temp), k);
	} else if shown == 3 who_text = tprint(L("%1, %2 and %3"), names[0], names[1], names[2]);
	else if shown == 2 who_text = tprint(L("%1 and %2"), names[0], names[1]);
	else who_text = names[0];
	r := pill.rect;
	tip := row("reactorstip", .Draw_Background | .Draw_Shadow | .Floating_X | .Floating_Y | .Overlay);
	tip.semantic_size = .[ui.children(), ui.px(40)];
	tip.cross_align = .Center;
	p := ui.top_parent();
	tip.fixed_pos = .{r.x0 - p.rect.x0, r.y1 + 8 - p.rect.y0};
	tip.style.bg = T("--background-surface-highest");
	tip.style.radius = all4(8);
	tip.style.shadow_color = .{0, 0, 0, 0.3};
	tip.style.shadow_blur = 8;
	ui.parent(tip); defer ui.pop_parent();
	spacer(.X, 10);
	emoji_box("e", re.emoji, 24);
	spacer(.X, 8);
	label(tprint(L("%1 reacted with %2"), who_text, ifx re.emoji.id then tprint(":%:", re.emoji.name) else re.emoji.name), .Semibold, 14, T("--text-strong"), 18);
	spacer(.X, 12);
}

#scope_export

reactors_receive :: (r: *dc.Feature_Result) {
	if r.tag != reactors.seq return;
	reactors.paging = false;
	if !r.ok return;
	for dc.vlist(r.body) array_add(*reactors.users, dc.parse_user_into(store(), dc.vmap(it)));
	reactors.loaded = true;
}

// The message menu's View Reactions: the message's reactions down the left (super reactions first),
// who reacted with the selected one on the right.
view_reactions: struct {
	msg: dc.Snowflake;
	sel: int;
};

view_reactions_modal :: () {
	m := find_message(view_reactions.msg);
	if !m || !m.reactions {
		view_reactions.msg = 0;
		return;
	}
	scrim := ui.box("vr_scrim", .Draw_Background | .Clickable | .Floating_X | .Floating_Y | .Overlay);
	scrim.semantic_size = .[ui.px(app.ui.window.x), ui.px(app.ui.window.y)];
	scrim.style.bg = .{0, 0, 0, 0.7};
	if ui.signal(scrim).clicked {
		view_reactions.msg = 0;
		return;
	}
	W :: 520;
	H :: 440;
	d := ui.box("vrmodal", .Draw_Background | .Draw_Border | .Floating_X | .Floating_Y | .Overlay | .Clickable | .Clip);
	d.semantic_size = .[ui.px(W), ui.px(H)];
	d.fixed_pos = .{(app.ui.window.x - W) / 2, (app.ui.window.y - H) / 2};
	d.style.bg = T("--modal-background");
	d.style.border_color = T("--border-subtle");
	d.style.border = 1;
	d.style.radius = all4(12);
	d.layout_axis = .X;
	ui.signal(d);
	ui.push_parent(d);
	defer ui.pop_parent();
	left := ui.box("emojis", .Scroll_Y | .Clip | .Draw_Background);
	left.semantic_size = .[ui.px(150), ui.pct(1)];
	left.layout_axis = .Y;
	left.style.bg = T("--background-base-lower");
	ui.signal(left);
	n := 0;
	sel_emoji: dc.Emoji;
	sel_burst: bool;
	{ ui.parent(left); defer ui.pop_parent();
		spacer(.Y, 8);
		for burst: bool.[true, false] for * re, i: m.reactions {
			count := ifx burst then re.burst_count else re.count;
			if count <= 0 continue;
			selected := n == view_reactions.sel;
			if selected sel_emoji, sel_burst = re.emoji, burst;
			r := row(tprint("vr%_%", i, burst), .Clickable | .Draw_Background | .Hot_Animation);
			r.semantic_size = .[ui.pct(1), ui.px(36)];
			r.cross_align = .Center;
			r.style.bg = ifx selected then T("--background-mod-strong") else .{};
			r.style.bg_hot = ifx selected then r.style.bg else T("--background-mod-subtle");
			if ui.signal(r).clicked view_reactions.sel = n;
			{ ui.parent(r); defer ui.pop_parent();
				spacer(.X, 16);
				emoji_box("e", re.emoji, 20);
				spacer(.X, 8);
				label(tprint("%", count), .Semibold, 14, ifx burst then rgb_u32(re.burst_color) else T("--text-default"), 18);
			}
			n += 1;
		}
	}
	if view_reactions.sel >= n {
		view_reactions.sel = 0;
		return;
	}
	reactors_want(m.channel_id, m.id, sel_emoji, sel_burst);
	right := ui.box("users", .Scroll_Y | .Clip);
	right.semantic_size = .[ui.fill(), ui.pct(1)];
	right.layout_axis = .Y;
	ui.signal(right);
	// The next 100 once scrolled near the end of a full page.
	if reactors.loaded && !reactors.paging && reactors.users.count > 0 && reactors.users.count % 100 == 0 && app.client && right.content_size.y > 0 && right.view_off.y + (right.rect.y1 - right.rect.y0) > right.content_size.y - 200 {
		reactors.paging = true;
		dc.fetch_reactors(app.client, m.channel_id, m.id, sel_emoji.name, sel_emoji.id, sel_burst, reactors.seq, after = peek(reactors.users));
	}
	moderate := can_manage_message(m) && dc.channel_get(store(), m.channel_id) && dc.channel_get(store(), m.channel_id).guild_id != 0;
	drop := -1;
	ui.parent(right); defer ui.pop_parent();
	spacer(.Y, 8);
	if !reactors.loaded {
		r := row("loading");
		r.semantic_size = .[ui.pct(1), ui.px(40)];
		ui.parent(r); defer ui.pop_parent();
		spacer(.X, 16);
		label(L("Loading..."), .Normal, 14, T("--text-muted"), 18);
	}
	for uid, i: reactors.users {
		r := row(tprint("vu%", i), .Clickable | .Draw_Background | .Hot_Animation);
		r.semantic_size = .[ui.pct(1), ui.px(44)];
		r.cross_align = .Center;
		r.style.bg_hot = T("--background-mod-subtle");
		hovered := ui.signal(r).hovering;
		ui.parent(r); defer ui.pop_parent();
		spacer(.X, 16);
		avatar_box("av", uid, 24);
		spacer(.X, 12);
		label(name_in(uid, m.channel_id), .Medium, 15, T("--text-strong"), 20);
		u := dc.user_get(store(), uid);
		if u {
			spacer(.X, 6);
			label(u.username, .Normal, 13, T("--text-muted"), 18);
		}
		if moderate && hovered {
			filler(.X);
			x := ui.box("remove", .Clickable);
			x.semantic_size = .[ui.px(16), ui.px(16)];
			xs := ui.signal(x);
			set_icon(x, "x-small", ifx xs.hovering then T("--status-danger") else T("--interactive-icon-default"));
			if xs.hovering tooltip_below(L("Remove Reaction"), x.rect);
			if xs.clicked drop = i;
			spacer(.X, 16);
		}
	}
	if drop >= 0 && net_action() {
		dc.remove_user_reaction(app.client, m.channel_id, m.id, sel_emoji.name, sel_emoji.id, sel_burst, reactors.users[drop]);
		array_ordered_remove_by_index(*reactors.users, drop);
	}
	for * e: app.ui.events {
		if !e.consumed && e.kind == .Key_Down && e.key == .Escape {
			e.consumed = true;
			view_reactions.msg = 0;
		}
	}
}

#scope_file

TYPING_H :: 24;

// "Name is typing..." over the bottom of the message list (messages scroll under it).
typing_line :: (channel_id: dc.Snowflake) {
	s := store();
	t := row("typing", .Floating_X | .Floating_Y | .Anchor_End_Y);
	t.semantic_size = .[ui.pct(1), ui.px(TYPING_H)];
	names: [..]string;
	names.allocator = temp;
	for dc.typing_users(s, channel_id) {
		if it.user_id == s.me continue;
		name := name_in(it.user_id, channel_id, "");
		if name array_add(*names, name);
	}
	ch := dc.channel_get(s, channel_id);
	slow := ifx ch then slowmode_secs(ch) else 0;
	if !names && !slow return;
	ui.parent(t); defer ui.pop_parent();
	spacer(.X, 16);
	if names {
		msg: string;
		if names.count == {
		case 1;
			msg = tprint(L("% is typing..."), names[0]);
		case 2;
			msg = tprint(L("%1 and %2 are typing..."), names[0], names[1]);
		case 3;
			msg = tprint(L("%1, %2, and %3 are typing..."), names[0], names[1], names[2]);
		case;
			msg = L("Several people are typing...");
		}
		pulsing_dots(T("--text-default")); // requests.jai
		spacer(.X, 4);
		label(msg, .Medium, 14, T("--text-default"), 24);
	}
	if slow {
		// the client's slowmode notice: the cooldown left after a send, else that it's on
		filler(.X);
		left := slowmode_left_ms(ch);
		icon("clk", "clock", 16, T("--text-muted"));
		spacer(.X, 4);
		text := ifx left > 0 then tprint("%:%", left / 60_000, formatInt((left / 1000) % 60, minimum_digits = 2)) else L("Slowmode is enabled");
		b := label(text, .Medium, 12, T("--text-muted"), 24);
		if ui.mouse_over(b) {
			n := ifx slow < 60 then slow else ifx slow < 3600 then slow / 60 else slow / 3600;
			every := ifx slow < 60 then Lp("Slowmode is enabled. Members can send one message every % second.", "Slowmode is enabled. Members can send one message every % seconds.", n)
				else ifx slow < 3600 then Lp("Slowmode is enabled. Members can send one message every % minute.", "Slowmode is enabled. Members can send one message every % minutes.", n)
				else Lp("Slowmode is enabled. Members can send one message every % hour.", "Slowmode is enabled. Members can send one message every % hours.", n);
			tooltip_below(tprint(every, n), b.rect, above = true);
		}
		if left > 0 request_wake(app.ui.time + (left % 1000 + 1) / 1000.0);
		spacer(.X, 16);
	}
}

// The length Discord checks: JavaScript's, in UTF-16 units (an emoji outside the BMP counts 2).
utf16_length :: (s: string) -> int {
	n := 0;
	for i: 0..s.count-1 {
		c := s[i];
		if (c & 0xC0) == 0x80 continue;
		n += ifx c >= 0xF0 then 2 else 1;
	}
	return n;
}

composer :: (ch: *dc.Channel, cs: *Chat_State) {
	blocked := composer_blocked(ch);
	if blocked {
		// the form's frame with the reason in place of the text area, and no buttons
		outer := row("composer_outer");
		outer.semantic_size = .[ui.pct(1), ui.children()];
		{ ui.parent(outer); defer ui.pop_parent();
			spacer(.X, 8);
			b := row("composer_blocked", .Draw_Background | .Draw_Border);
			b.semantic_size = .[ui.fill(), ui.px(COMPOSER_H + 2)];
			b.style.bg = with_alpha(T("--chat-background-default"), 0.5);
			b.style.border_color = T("--border-subtle");
			b.style.border = 1;
			b.style.radius = all4(8);
			{ ui.parent(b); defer ui.pop_parent();
				spacer(.X, 16);
				label(blocked, .Normal, 16, T("--text-muted"), MSG_LINE_H);
				if rules_pending(ch.guild_id) {
					filler(.X);
					if adm_button("rules", L("Complete"), .Primary) rules_open(ch.guild_id);
					spacer(.X, 12);
				}
			}
			spacer(.X, 8);
		}
		spacer(.Y, 8);
		return;
	}
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
		encrypted_warning(ch);
		encrypted_unreached_bar(ch);
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
			psig := ui.signal(plus);
			// A click opens the menu, a double-click the file picker, as in the client.
			if psig.double_clicked {
				plus_menu.channel = 0;
				if can_attach(ch) stage_paths(ch.id, pick_files(), "file_picker");
			} else if psig.clicked {
				plus_menu.channel = ifx plus_menu.channel == ch.id then 0 else ch.id;
				plus_menu.anchor = plus.rect;
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
			// The text scrolls inside the form once it is half the window high, like the client's max-height: 50vh.
			sc := ui.box("inscroll", .Scroll_Y | .Clip);
			sc.semantic_size = .[ui.fill(), ui.px(clamp(sc.content_size.y, cast(float32) COMPOSER_H, max(cast(float32) COMPOSER_H, app.ui.window.y / 2)))];
			sc.layout_axis = .Y;
			ui.signal(sc);
			placeholder := ifx ch.kind == .DM then tprint(L("Message @%"), dm_name(ch)) else tprint(L("Message #%"), ch.name);
			if ch.kind == .Group_DM placeholder = tprint(L("Message %"), dm_name(ch));
			if encrypting(ch) placeholder = tprint(L("Message @% (encrypted)"), dm_name(ch));
			else if encrypted_dm(ch) && encrypted_channel(ch.id).has_session placeholder = tprint(L("Message @% (not encrypted)"), dm_name(ch));
			// An edit whose message left this channel (switched away, deleted) would hold the composer forever.
			if ma.editing != 0 && find_message(ma.editing) == null ma.editing = 0;
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
			input_focused := (app.ui.focus == box.key || app.ui.focus == sc.key || app.ui.focus == 0) && ma.editing == 0 && !sw.open && !modal_open();
			// Cmd/Ctrl+V with files or a bitmap on the clipboard stages them instead of pasting text
			if input_focused {
				for * e: app.ui.events {
					if e.consumed || e.kind != .Key_Down || e.key != .V || (e.mods & (.Shift | .Alt)) || !(e.mods & PRIMARY_MOD) continue;
					if paste_attachments(ch.id) e.consumed = true;
				}
				for * e: app.ui.events {
					if e.consumed || e.kind != .Key_Down || e.key != .U || e.mods != PRIMARY_MOD | .Shift continue;
					e.consumed = true;
					if can_attach(ch) stage_paths(ch.id, pick_files(), "file_picker");
				}
			}
			// the emoji and mention autocompletes float over the whole form and take their keys first
			ui.push_parent(stack);
			emoji_autocomplete(ch, *cs.editor, input_focused);
			mention_autocomplete(ch, *cs.editor, input_focused);
			slash_autocomplete(ch, *cs.editor, input_focused); // slash_commands.jai
			ui.pop_parent();
			ui.push_parent(sc);
			res := text_field("input", *cs.editor, placeholder, input_focused, pad_y = (COMPOSER_H - MSG_LINE_H) / 2, placeholder_color = T("--channel-text-area-placeholder"), markdown = true);
			ui.pop_parent();
			if res != .None {
				// Keep the caret in view: last frame's layout places its line (the end of the text: the bottom).
				ed := *cs.editor;
				tl := sc.last.prev_layout;
				h := sc.rect.y1 - sc.rect.y0;
				if ed.caret >= ed.buf.count {
					sc.view_off_target.y = sc.content_size.y;
				} else if tl {
					y := (COMPOSER_H - MSG_LINE_H) / 2 + cast(float32) ui.line_of(tl, ed.caret) * tl.line_h;
					if y < sc.view_off_target.y sc.view_off_target.y = y;
					if y + tl.line_h > sc.view_off_target.y + h sc.view_off_target.y = y + tl.line_h - h + (COMPOSER_H - MSG_LINE_H) / 2;
				}
			}
			if res == .Changed emoji_autocomplete_close_colon(ch, *cs.editor);
			// The length limit: 4000 with Nitro, else 2000; the count shows in the last 200 and an over-long send is held.
			me := dc.user_get(s, s.me);
			limit := ifx me && me.premium_type == 2 then 4000 else 2000;
			length := utf16_length(ui.editor_text(*cs.editor));
			if res == .Submit && slowmode_left_ms(ch) > 0 {
				// still cooling down: the text stays for when it can go
			} else if res == .Submit && length > limit {
				toast_show(tprint(L("Your message is too long (% / %)."), length, limit), false);
			} else if res == .Submit {
				text := trim(ui.editor_text(*cs.editor), " \t\n\r\x0b\x0c");
				jump_to_present(ch.id);
				// a send that can't go yet (offline, a file still being read) keeps the text; "/" commands first
				out, act := slash_command(ch, text);
				if act != .Kept && (act == .Sent || composer_send(ch, mentions_convert(emoji_convert_shortcodes(out, ch.id), ch))) {
					cs.scroll_target = 0;
					ui.editor_set_text(*cs.editor, "");
					length = 0;
				}
			} else if res == .Escape {
				// handed on: a popout or menu over the chat takes it first, else the end of
				// overlays() runs channel_escape, the official keybind's order
				for * app.ui.events if it.kind == .Key_Down && it.key == .Escape it.consumed = false;
			} else if res == .Changed && app.client != null && ui.editor_text(*cs.editor) != "" {
				dc.typing_keystroke(app.client, ch.id);
			}
			if limit - length < 200 {
				left := limit - length;
				label(tprint("%##charcount", left), .Medium, 14, ifx left < 0 then T("--text-feedback-critical") else T("--text-muted"), 18);
				spacer(.X, 4);
			}
			clk := ui.box("clock", .Clickable);
			clk.semantic_size = .[ui.px(40), ui.px(COMPOSER_H)];
			clk.layout_axis = .Y;
			clk.cross_align = .Center;
			{ ui.parent(clk); defer ui.pop_parent();
				csig := ui.signal(clk);
				if csig.clicked timestamp_gen_open(ch.id);
				if csig.hovering tooltip_below(L("Insert Timestamp"), clk.rect);
				spacer(.Y, (COMPOSER_H - 24) / 2);
				icon("i", "clock", 24, ifx csig.hovering then T("--interactive-icon-hover") else T("--interactive-icon-default"));
			}
			for name: (string.["gif", "sticker", "reaction"]) {
				if name == "gif" && !expr_client() && app.client continue; // GIFs come through Discord.
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

#scope_export

// Markdown text drawn as message content of m (a component's text display).
markdown_text :: (m: *dc.Message, text: string) {
	plain := m.*;
	plain.content = text;
	plain.edited_timestamp = "";
	message_body(*plain, decrypted = true);
}

// The composer's "+" menu: Upload a File, Create Thread, Create Poll, each where it's allowed.
plus_menu: struct { channel: dc.Snowflake; anchor: ui.Rect; };

// Slowmode: seconds between a member's messages here, or 0 when it's off or they bypass it (Manage
// Messages or Manage Channels; Manage Threads in a thread). The cooldown starts at each send.
slow_until: Table(dc.Snowflake, s64);

slowmode_secs :: (ch: *dc.Channel) -> int {
	if ch.rate_limit_per_user <= 0 || ch.guild_id == 0 return 0;
	g := dc.guild_get(store(), ch.guild_id);
	if !g || !g.roles.count return 0;
	perms := dc.channel_permissions(store(), ch.id);
	bypass := dc.PERM_MANAGE_MESSAGES | dc.PERM_MANAGE_CHANNELS | ifx dc.is_thread(ch) then dc.PERM_MANAGE_THREADS else 0;
	return ifx perms & bypass then 0 else min(ch.rate_limit_per_user, 21600);
}

slowmode_left_ms :: (ch: *dc.Channel) -> s64 {
	_, until := table_find(*slow_until, ch.id);
	return ifx slowmode_secs(ch) then max(0, until - wall_ms()) else 0;
}

// Why the composer can't send here, or "" when it can: Send Messages (in a thread, Send Messages in Threads),
// and a locked thread needs Manage Threads. A server whose roles haven't arrived blocks nothing.
composer_blocked :: (ch: *dc.Channel) -> string {
	if ch.msg_request || ch.spam return L("Accept this message request (Friends, Message Requests) to reply.");
	g := dc.guild_get(store(), ch.guild_id);
	if !g return "";
	if rules_pending(g.id) return L("You must complete a few more steps before you can talk.");
	until := dc.timed_out(store(), ch.guild_id, store().me);
	if until && g.owner_id != store().me && !(dc.guild_permissions(store(), ch.guild_id) & dc.PERM_ADMINISTRATOR) {
		request_wake(app.ui.time + cast(float64) (until - dc.now_ms()) / 1000 + 0.05);
		return tprint(L("You're timed out until %."), format_time_ms(until));
	}
	if !g.roles.count return "";
	perms := dc.channel_permissions(store(), ch.id);
	if dc.is_thread(ch) {
		tm := dc.thread_meta(store(), ch.id);
		if tm && tm.locked && !(perms & dc.PERM_MANAGE_THREADS) return L("This thread is locked.");
		if !(perms & dc.PERM_SEND_MESSAGES_IN_THREADS) return L("You do not have permission to send messages in this channel.");
	} else if !(perms & dc.PERM_SEND_MESSAGES) return L("You do not have permission to send messages in this channel.");
	return "";
}

// Files need Attach Files in a server (unknown until its roles arrive), and a composer that can send.
can_attach :: (ch: *dc.Channel) -> bool {
	g := dc.guild_get(store(), ch.guild_id);
	return composer_blocked(ch) == "" && (!g || !g.roles.count || dc.has_permission(dc.channel_permissions(store(), ch.id), dc.PERM_ATTACH_FILES));
}

attach_allowed :: (channel_id: dc.Snowflake) -> bool {
	ch := dc.channel_get(store(), channel_id);
	return !ch || can_attach(ch);
}

composer_plus_menu :: () {
	ch := dc.channel_get(store(), plus_menu.channel);
	if !ch || ch.id != app.view.channel || outside_pressed("plus_scrim") || escape_pressed() {
		plus_menu.channel = 0;
		return;
	}
	W :: 220.0;
	thread := (ch.kind == .Guild_Text || ch.kind == .Guild_Announcement) && can_create_thread(ch.id);
	n := cast(int) can_attach(ch) + cast(int) thread + cast(int) can_send_poll(ch);
	if !n {
		plus_menu.channel = 0;
		return;
	}
	m := menu_panel("plusmenu", .{plus_menu.anchor.x0 - 8, plus_menu.anchor.y0 - 16 - n * GM_ROW_H - 12}, W);
	ui.parent(m); defer ui.pop_parent();
	spacer(.Y, 8);
	if can_attach(ch) && menu_item("upload", L("Upload a File"), lead = "file-up").clicked {
		plus_menu.channel = 0;
		stage_paths(ch.id, pick_files(), "file_picker");
	}
	if thread && menu_item("thread", L("Create Thread"), lead = "thread").clicked {
		plus_menu.channel = 0;
		threads_browser_create(ch.id);
	}
	if can_send_poll(ch) && menu_item("poll", L("Create Poll"), lead = "analytics").clicked {
		plus_menu.channel = 0;
		poll_create_open(ch.id);
	}
	spacer(.Y, 8);
}
