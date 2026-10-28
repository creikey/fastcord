#scope_file

// Title bar Inbox (top right) and Help buttons.
// The inbox is a 480px popout under its icon (fixture inbox, FEATURES_NEW.md):
//   - Unreads: channels whose last message is newer than their read state
//     (local store; muted guilds/channels and unjoined threads left out),
//     grouped by server, newest first. Clicking a row opens the channel, the
//     check ("Mark As Read") acks it at once (POST .../ack, science
//     inbox_channel_acked + notification_action for the channel's shown
//     notifications); the header's "Mark All as Read" acks every listed
//     channel in one /read-states/ack-bulk.
//   - Mentions: GET /users/@me/mentions (25 per page, more on scroll; the first
//     page is asked for twice, as the client does); "Jump to Message" goes to
//     the message (science jump), "x" ("Mark As Read") deletes the mention
//     (DELETE /users/@me/mentions/{id}).
// The popout reopens on the last used tab (settings-proto/1 inbox.current_tab,
// saved 10 s after the first switch); opening it and each tab switch track
// open_popout ("Inbox" / "Recent Mentions").
// The official popout also has Bookmarks and Reminders tabs (saved messages);
// they are not offered here (no saved-message flows yet).
// The icon carries a red badge with the unread mention count of all channels.

Inbox_Tab :: enum u8 {
	Unreads;
	Mentions;
}

Mention :: struct {
	guild_id: dc.Snowflake;
	msg: dc.Message;
}

Inbox_State :: struct {
	open: bool;
	tab: Inbox_Tab;
	anchor: ui.Rect;
	requested: bool; // first mentions page asked for
	loading: bool;
	has_more: bool;
	items: [..]Mention; // in pool
	pool: Flat_Pool;
}

inbox: Inbox_State;
button_rect: ui.Rect;
UNREAD_PITCH :: 48;
#scope_export

INBOX_W :: 480;

inbox_toggle :: () {
	if inbox.open { inbox.open = false; } else { inbox_open(button_rect); }
}

inbox_button :: () {
	b := ui.box("inbox", .Clickable);
	b.semantic_size = .[ui.px(20), ui.px(20)];
	sig := ui.signal(b);
	set_icon(b, "inbox", ifx sig.hovering || inbox.open then T("--interactive-icon-hover") else T("--icon-muted"));
	if sig.hovering && !inbox.open { tooltip_below("Inbox", b.rect); }
	button_rect = b.rect;
	if sig.clicked inbox_toggle();
	// unread mentions badge at the icon's bottom-right
	// (counted like the rail's badges: read-state counts or loaded unread mentions)
	total := 0;
	for c: inbox_clients() {
		s := ifx c then *c.store else store();
		for * ch, id: s.channels {
			if ch.last_message_id == 0 { continue; }
			rs := table_find_pointer(*s.read_states, id);
			if rs != null && rs.last_message_id >= ch.last_message_id { continue; }
			total += channel_mentions_of(s, ch, rs);
		}
	}
	if total <= 0 || notify_prefs.lotus { return; }
	{ ui.parent(b); defer ui.pop_parent();
		text := ifx total > 99 then "99+" else tprint("%", total);
		w := max(cast(float32)(14), cast(float32)(text.count) * 6 + 6);
		badge := ui.box(tprint("%##inboxbadge", text), .Draw_Background | .Draw_Text | .Floating_X | .Floating_Y);
		badge.semantic_size = .[ui.px(w), ui.px(14)];
		badge.fixed_pos = .{20 - w + 6, 10};
		badge.style.bg = T("--status-danger");
		badge.style.radius = all4(7);
		badge.style.font = F(.Bold);
		badge.style.font_size = 10;
		badge.style.text_color = .{1, 1, 1, 1};
		badge.style.text_align = .Center;
	}
}

help_button :: () {
	b := ui.box("help", .Clickable);
	b.semantic_size = .[ui.px(20), ui.px(20)];
	sig := ui.signal(b);
	set_icon(b, "circle-question", ifx sig.hovering then T("--interactive-icon-hover") else T("--icon-muted"));
	if sig.hovering { tooltip_below("Help", b.rect); }
	if sig.clicked { open_url("https://support.discord.com"); }
}

inbox_receive :: (r: *dc.Feature_Result) {
	if r.op == {
	case .Mentions;
		if r.tag == dc.MENTIONS_DUP_TAG { return; }
		inbox.loading = false;
		if !r.ok { return; }
		// a reply to an older page after a reset (first page = tag 0) is dropped
		if r.tag != 0 && (inbox.items.count == 0 || cast(u64)(peek(inbox.items).msg.id) != r.tag) { return; }
		alloc := dc.pool_allocator(*inbox.pool);
		inbox.items.allocator = alloc;
		list := dc.vlist(r.body);
		for mv: list {
			mm := dc.vmap(mv);
			array_add(*inbox.items, .{guild_id = dc.fsnow(mm, "guild_id"), msg = dc.parse_loose_message(store(), mm, alloc)});
		}
		inbox.has_more = list.count >= 25;
		app.ui.animating = true;
	case .Mention_Delete;
	}
}

inbox_popout :: () {
	if !inbox.open { return; }
	scrim := ui.box("inbox_scrim", .Clickable | .Floating_X | .Floating_Y | .Overlay);
	scrim.semantic_size = .[ui.px(app.ui.window.x), ui.px(app.ui.window.y)];
	if ui.signal(scrim).clicked {
		inbox.open = false;
		return;
	}
	for * e: app.ui.events {
		if !e.consumed && e.kind == .Key_Down && e.key == .Escape {
			inbox.open = false;
			e.consumed = true;
			return;
		}
	}
	x := clamp(inbox.anchor.x1 - INBOX_W, 8, app.ui.window.x - INBOX_W - 8);
	y := inbox.anchor.y1 + 8;
	h := min(app.ui.window.y * 0.8, app.ui.window.y - y - 16);
	p := ui.box("inboxpop", .Draw_Background | .Draw_Border | .Draw_Shadow | .Floating_X | .Floating_Y | .Overlay | .Clickable | .Clip);
	p.semantic_size = .[ui.px(INBOX_W), ui.px(h)];
	p.fixed_pos = .{x, y};
	p.layout_axis = .Y;
	p.style.bg = T("--background-surface-high");
	p.style.border_color = T("--border-subtle");
	p.style.border = 1;
	p.style.radius = all4(8);
	p.style.shadow_color = .{0, 0, 0, 0.35};
	p.style.shadow_blur = 16;
	p.style.shadow_offset = .{0, 8};
	ui.signal(p);
	{ ui.parent(p); defer ui.pop_parent();
		hdr := row("hdr");
		hdr.semantic_size = .[ui.pct(1), ui.px(48)];
		{ ui.parent(hdr); defer ui.pop_parent();
			spacer(.X, 16);
			icon("i", "inbox", 20, T("--interactive-icon-default"));
			spacer(.X, 8);
			label("Inbox", .Semibold, 16, T("--text-strong"), 20);
			filler(.X);
			if inbox.tab == .Unreads {
				rows := unread_rows();
				if rows.count > 0 {
					mb := row("markall", .Clickable | .Draw_Background | .Hot_Animation);
					mb.semantic_size = .[ui.px(32), ui.px(32)];
					mb.style.radius = all4(8);
					mb.style.bg_hot = T("--background-mod-subtle");
					msig := ui.signal(mb);
					{ ui.parent(mb); defer ui.pop_parent();
						spacer(.X, 6);
						icon("i", "double-checkmark", 20, ifx msig.hovering then T("--interactive-icon-hover") else T("--interactive-icon-default"));
					}
					if msig.hovering { tooltip_below("Mark All as Read", mb.rect); }
					if msig.clicked && net_action() {
						for c: inbox_clients() {
							if !c continue;
							ids: [..]dc.Snowflake;
							ids.allocator = temp;
							for rows { if it.channel != 0 && it.client == c { array_add(*ids, it.channel); } }
							if ids.count dc.ack_channels(c, ids);
						}
					}
				}
				spacer(.X, 12);
			}
		}
		tabs := row("tabs");
		tabs.semantic_size = .[ui.pct(1), ui.px(32)];
		{ ui.parent(tabs); defer ui.pop_parent();
			spacer(.X, 12);
			for t: enum_values_as_enum(Inbox_Tab) {
				name := ifx t == .Unreads then "Unreads" else "Mentions";
				sel := inbox.tab == t;
				tb := row(name, .Clickable | .Draw_Background | .Hot_Animation);
				tb.semantic_size = .[ui.children(), ui.px(28)];
				tb.style.radius = all4(4);
				tb.style.bg = ifx sel then T("--background-mod-normal") else .{};
				tb.style.bg_hot = ifx sel then tb.style.bg else T("--background-mod-subtle");
				sig := ui.signal(tb);
				{ ui.parent(tb); defer ui.pop_parent();
					spacer(.X, 8);
					label(name, .Medium, 14, ifx sel || sig.hovering then T("--text-strong") else T("--text-muted"), 18);
					spacer(.X, 8);
				}
				if sig.clicked && !sel {
					inbox.tab = t;
					if t == .Mentions { mentions_first_page(); }
					track_tab();
					stored: dc.Inbox_Tab = ifx t == .Mentions then .Mentions else .Unreads;
					store().settings.inbox_tab = stored;
					if app.client != null { dc.set_inbox_tab(app.client, stored); }
				}
				spacer(.X, 4);
			}
		}
		spacer(.Y, 8);
		line := ui.box("hl", .Draw_Background);
		line.semantic_size = .[ui.pct(1), ui.px(1)];
		line.style.bg = T("--border-subtle");
		if inbox.tab == {
		case .Unreads;
			unreads_list();
		case .Mentions;
			mentions_list();
		}
	}
}

inbox_reset_for_test :: () {
	fini(*inbox.pool);
	inbox = .{};
}

#scope_file

inbox_open :: (anchor: ui.Rect) {
	inbox.open = true;
	inbox.anchor = anchor;
	inbox.tab = ifx store().settings.inbox_tab == .Mentions then .Mentions else .Unreads;
	if inbox.tab == .Mentions { mentions_first_page(); }
	track_tab();
}

track_tab :: () {
	if app.client != null { dc.track_open_popout(app.client, ifx inbox.tab == .Mentions then "Recent Mentions" else "Inbox"); }
}

mentions_first_page :: () {
	if inbox.requested { return; }
	inbox.requested = true;
	if !net_action() {
		local_mentions();
		return;
	}
	inbox.loading = true;
	dc.open_mentions(app.client);
}

// Offline (fixtures): the loaded messages that mention us, newest first, so
// the tab and its controls work without the REST call.
local_mentions :: () {
	s := store();
	alloc := dc.pool_allocator(*inbox.pool);
	inbox.items.allocator = alloc;
	for * l, cid: s.messages {
		ch := dc.channel_get(s, cid);
		for m: l.messages {
			if m.author_id == s.me || !(m.mention_everyone || array_find(m.mentions, s.me)) { continue; }
			mm := m;
			mm.content = copy_string(m.content,, alloc);
			array_add(*inbox.items, .{guild_id = ifx ch != null then ch.guild_id else 0, msg = mm});
		}
	}
	items := inbox.items;
	for i: 1..items.count-1 {
		j := i;
		while j > 0 && items[j].msg.id > items[j - 1].msg.id {
			swap(*items[j], *items[j - 1]);
			j -= 1;
		}
	}
	if inbox.items.count > 25 { inbox.items.count = 25; }
}

empty_note :: (text: string) {
	r := row("empty");
	r.semantic_size = .[ui.pct(1), ui.px(80)];
	{ ui.parent(r); defer ui.pop_parent();
		filler(.X);
		label(text, .Medium, 14, T("--text-muted"), 18);
		filler(.X);
	}
}

// ---- Unreads ----

Unread_Row :: struct {
	client: *dc.Client; // The connection it is on.
	guild: dc.Snowflake;
	channel: dc.Snowflake; // 0: the guild's header
}

// Every connection, so Unreads and the badge cover self-hosted servers too; null alone when offline.
inbox_clients :: () -> []*dc.Client {
	cs := connections();
	if cs.count return cs;
	return NewArray(1, *dc.Client,, temp);
}

unread_rows :: () -> []Unread_Row {
	Keyed :: struct {
		key, guild, id: dc.Snowflake;
		client: *dc.Client;
	}
	list: [..]Keyed;
	list.allocator = temp;
	for c: inbox_clients() {
		s := ifx c then *c.store else store();
		for * ch, id: s.channels {
			if ch.last_message_id == 0 || ch.kind == .Guild_Category { continue; }
			rs := table_find_pointer(*s.read_states, id);
			if rs && rs.last_message_id >= ch.last_message_id { continue; }
			if dc.is_thread(ch) {
				tm := dc.thread_meta(id);
				if tm == null || !tm.joined || tm.archived { continue; }
			}
			if ch.guild_id != 0 {
				gs := table_find_pointer(*s.guild_settings, ch.guild_id);
				if gs {
					if gs.muted { continue; }
					muted := false;
					for m: gs.muted_channels { if m == id || (m == ch.parent_id && m != 0) { muted = true; } }
					if muted { continue; }
				}
			}
			array_add(*list, .{ch.last_message_id, ch.guild_id, id, c});
		}
	}
	for i: 1..list.count-1 {
		j := i;
		while j > 0 && list[j].key > list[j - 1].key {
			swap(*list[j], *list[j - 1]);
			j -= 1;
		}
	}
	// guilds in order of their newest unread channel
	guilds: [..]Unread_Row;
	guilds.allocator = temp;
	for list {
		seen := false;
		for g: guilds if g.guild == it.guild && g.client == it.client seen = true;
		if !seen array_add(*guilds, .{client = it.client, guild = it.guild});
	}
	out: [..]Unread_Row;
	out.allocator = temp;
	for g: guilds {
		array_add(*out, g);
		for list { if it.guild == g.guild && it.client == g.client { array_add(*out, .{client = it.client, guild = it.guild, channel = it.id}); } }
	}
	return out;
}

unreads_list :: () {
	rows := unread_rows();
	list := ui.box("unreads", .Scroll_Y | .Clip);
	list.semantic_size = .[ui.pct(1), ui.fill()];
	list.layout_axis = .Y;
	ui.signal(list);
	ui.push_parent(list);
	defer ui.pop_parent();
	if rows.count == 0 {
		spacer(.Y, 8);
		empty_note("You're all caught up!");
		return;
	}
	w := ui.list_window(list, UNREAD_PITCH, rows.count);
	keep := app.client;
	for i: w.first..w.last-1 {
		r := rows[i];
		ui.id_scope(cast(u64)(ifx r.channel != 0 then r.channel else r.guild) * 2 + cast(u64) (ifx r.channel != 0 then 1 else 0)); defer ui.pop_seed();
		// Each row draws and acks under its own connection; opening one switches to it.
		if r.client app.client = r.client;
		defer app.client = keep;
		if r.channel == 0 {
			unread_header(r.guild);
			continue;
		}
		ch := dc.channel_get(store(), r.channel);
		if ch == null {
			spacer(.Y, UNREAD_PITCH);
			continue;
		}
		if unread_row(ch) {
			keep = app.client;
			select_channel(ch.guild_id, ch.id);
			inbox.open = false;
		}
	}
	ui.list_window_end(w);
}

unread_header :: (gid: dc.Snowflake) {
	h := row("ghdr");
	h.semantic_size = .[ui.pct(1), ui.px(UNREAD_PITCH)];
	ui.push_parent(h);
	defer ui.pop_parent();
	spacer(.X, 16);
	name := "Direct Messages";
	g := dc.guild_get(store(), gid);
	if g != null {
		name = g.name;
		gi := ui.box("gicon", .Draw_Background | .Draw_Text);
		gi.semantic_size = .[ui.px(24), ui.px(24)];
		gi.style.radius = all4(8);
		gi.style.bg = T("--background-mod-subtle");
		gi.style.text_color = T("--text-default");
		gi.style.text_align = .Center;
		gi.style.font = F(.Medium);
		gi.style.font_size = 9;
		gi.text = guild_initials(g.name);
		if g.icon != "" {
			set_remote_image(gi, dc.guild_icon_url(g.id, g.icon, 48));
			gi.text = "";
		}
	} else {
		icon("gicon", "logo", 24, T("--text-muted"));
	}
	spacer(.X, 10);
	label(ellipsize(name, .Semibold, 16, INBOX_W - 80), .Semibold, 16, T("--text-strong"), 20);
}

unread_row :: (ch: *dc.Channel) -> clicked: bool {
	s := store();
	outer := row("ur");
	outer.semantic_size = .[ui.pct(1), ui.px(UNREAD_PITCH)];
	ui.push_parent(outer);
	defer ui.pop_parent();
	spacer(.X, 8);
	item := row("item", .Clickable | .Draw_Background | .Hot_Animation);
	item.semantic_size = .[ui.fill(), ui.px(UNREAD_PITCH - 4)];
	item.style.radius = all4(8);
	item.style.bg_hot = T("--background-mod-subtle");
	sig := ui.signal(item);
	{ ui.parent(item); defer ui.pop_parent();
		spacer(.X, 12);
		name: string;
		if ch.kind == .DM && ch.recipient_ids.count > 0 {
			avatar_box("av", ch.recipient_ids[0], 24);
			name = dm_name(ch);
		} else if ch.kind == .Group_DM {
			group_dm_icon("av", ch, 24);
			name = dm_name(ch);
		} else {
			icon("ci", channel_icon_name(ch), 20, T("--channel-icon"));
			spacer(.X, 4);
			name = ch.name;
		}
		spacer(.X, 8);
		col := ui.box("col");
		col.semantic_size = .[ui.fill(), ui.children()];
		col.layout_axis = .Y;
		{ ui.parent(col); defer ui.pop_parent();
			label(ellipsize(name, .Semibold, 15, INBOX_W - 180), .Semibold, 15, T("--text-strong"), 19);
			// the newest loaded message, when there is one
			msgs := dc.messages_get(s, ch.id);
			if msgs.count > 0 {
				m := *msgs[msgs.count - 1];
				author := name_in(m.author_id, ch.id, "unknown");
				snippet := tprint("%: %", author, snippet_text(s, first_line(m.content)));
				t := label(ellipsize(snippet, .Normal, 13, INBOX_W - 180), .Normal, 13, T("--text-muted"), 17);
				t.flags |= .Clip;
			}
		}
		n := channel_mentions_of(s, ch, table_find_pointer(*s.read_states, ch.id));
		if n > 0 {
			bt := ifx n > 99 then "99+" else tprint("%", n);
			bw := max(cast(float32)(16), cast(float32)(bt.count) * 7 + 8);
			b := ui.box(tprint("%##mb", bt), .Draw_Background | .Draw_Text);
			b.semantic_size = .[ui.px(bw), ui.px(16)];
			b.style.bg = T("--status-danger");
			b.style.radius = all4(8);
			b.style.font = F(.Bold);
			b.style.font_size = 12;
			b.style.text_color = .{1, 1, 1, 1};
			b.style.text_align = .Center;
			spacer(.X, 8);
		}
		ack := ui.box("ack", .Clickable | .Draw_Background | .Hot_Animation);
		ack.semantic_size = .[ui.px(28), ui.px(28)];
		ack.style.radius = all4(14);
		ack.style.bg = T("--background-mod-subtle");
		ack.style.bg_hot = T("--background-mod-strong");
		ack.layout_axis = .X;
		ack.cross_align = .Center;
		asig := ui.signal(ack);
		{ ui.parent(ack); defer ui.pop_parent();
			spacer(.X, 4);
			icon("i", "checkmark-small", 20, ifx asig.hovering then T("--interactive-icon-hover") else T("--interactive-icon-default"));
		}
		if asig.hovering { tooltip_below("Mark As Read", ack.rect); }
		if asig.clicked && net_action() {
			dc.ack_message(app.client, ch.id, ch.last_message_id, true, dc.ACK_INBOX);
			dc.track_inbox_channel_acked(app.client, ch.id);
		}
		spacer(.X, 10);
	}
	spacer(.X, 8);
	return sig.clicked;
}

// One line of content with <@id> user mentions shown as @name.
snippet_text :: (s: *dc.Store, line: string) -> string {
	if find_index_from_left(line, "<@") < 0 { return line; }
	sb: String_Builder;
	sb.allocator = temp;
	c := line;
	while c.count > 0 {
		i := find_index_from_left(c, "<@");
		end := ifx i >= 0 then find_index_from_left(c, #char ">", i) - i else -1;
		if i < 0 || end < 0 {
			append(*sb, c);
			break;
		}
		before := c;
		before.count = i;
		append(*sb, before);
		tag := advance(c, i + 2);
		tag.count = end - 2;
		advance(*c, i + end + 1);
		if begins_with(tag, "&") {
			append(*sb, "@role");
			continue;
		}
		print_to_builder(*sb, "@%", dc.user_name(s, dc.parse_snowflake(trim_left(tag, "!")), 0, "unknown-user"));
	}
	return builder_to_string(*sb,, temp);
}

// ---- Mentions ----

mentions_list :: () {
	s := store();
	list := ui.box("mentions", .Scroll_Y | .Clip);
	list.semantic_size = .[ui.pct(1), ui.fill()];
	list.layout_axis = .Y;
	sig := ui.signal(list);
	{ ui.parent(list); defer ui.pop_parent();
		spacer(.Y, 8);
		if inbox.items.count == 0 { empty_note(ifx inbox.loading then "Loading..." else "Nobody has mentioned you recently."); }
		removed := -1;
		for * item, i: inbox.items {
			{ ui.id_scope(cast(u64)(item.msg.id)); defer ui.pop_seed();
				ch := dc.channel_get(s, item.msg.channel_id);
				hr := row("mhdr");
				hr.semantic_size = .[ui.pct(1), ui.px(32)];
				{ ui.parent(hr); defer ui.pop_parent();
					spacer(.X, 16);
					cname := "unknown channel";
					gname := "";
					if ch != null {
						cname = ifx ch.kind == .DM || ch.kind == .Group_DM then dm_name(ch) else tprint("#%", ch.name);
					}
					gid := item.guild_id;
					if gid == 0 && ch != null { gid = ch.guild_id; }
					g := dc.guild_get(s, gid);
					if g != null { gname = g.name; }
					label(ellipsize(cname, .Semibold, 14, 220), .Semibold, 14, T("--text-strong"), 18);
					if gname != "" {
						spacer(.X, 6);
						label(ellipsize(gname, .Medium, 12, 160), .Medium, 12, T("--text-muted"), 16);
					}
					filler(.X);
					x := ui.box("x", .Clickable | .Draw_Background | .Hot_Animation);
					x.semantic_size = .[ui.px(24), ui.px(24)];
					x.style.radius = all4(12);
					x.style.bg_hot = T("--background-mod-strong");
					x.layout_axis = .X;
					x.cross_align = .Center;
					xs := ui.signal(x);
					{ ui.parent(x); defer ui.pop_parent();
						spacer(.X, 2);
						icon("i", "x-small", 20, ifx xs.hovering then T("--interactive-icon-hover") else T("--interactive-icon-default"));
					}
					if xs.hovering { tooltip_below("Mark As Read", x.rect); }
					if xs.clicked && net_action() {
						dc.delete_mention(app.client, item.msg.id);
						removed = i;
					}
					spacer(.X, 12);
				}
				if loose_message_card(*item.msg, .[], true) {
					jump_to_message(item.msg.channel_id, item.msg.id);
					if app.client != null { dc.track_jump(app.client, "Recent Mentions", item.msg.channel_id, item.msg.id); }
					inbox.open = false;
				}
			}
		}
		if removed >= 0 { array_ordered_remove_by_index(*inbox.items, removed); }
		spacer(.Y, 8);
	}
	// load more near the end
	if inbox.has_more && !inbox.loading && app.client != null && inbox.items.count > 0 && sig.hovering {
		if list.content_size.y > 0 && list.view_off.y + (list.rect.y1 - list.rect.y0) > list.content_size.y - 200 {
			inbox.loading = true;
			dc.fetch_mentions(app.client, peek(inbox.items).msg.id);
		}
	}
}


