package app

import "core:fmt"
import "core:mem/virtual"
import "core:slice"
import "core:strings"
import dc "fc:discord"
import "fc:ui"

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

@(private = "file")
Inbox_Tab :: enum u8 {
	Unreads,
	Mentions,
}

@(private = "file")
Mention :: struct {
	guild_id: dc.Snowflake,
	msg:      dc.Message,
}

@(private = "file")
Inbox_State :: struct {
	open:      bool,
	tab:       Inbox_Tab,
	anchor:    ui.Rect,
	requested: bool, // first mentions page asked for
	loading:   bool,
	has_more:  bool,
	items:     [dynamic]Mention,
	arena:     virtual.Arena,
}

@(private = "file")
inbox: Inbox_State

INBOX_W :: 480
@(private = "file")
UNREAD_PITCH :: 48

inbox_button :: proc() {
	b := ui.box("inbox", {.Clickable})
	b.semantic_size = {.X = ui.px(20), .Y = ui.px(20)}
	sig := ui.signal(b)
	set_icon(b, "inbox", sig.hovering || inbox.open ? T("--interactive-icon-hover") : T("--icon-muted"))
	if sig.hovering && !inbox.open do tooltip_below("Inbox", b.rect)
	if sig.clicked {
		if inbox.open do inbox.open = false
		else do inbox_open(b.rect)
	}
	// unread mentions badge at the icon's bottom-right
	// (counted like the rail's badges: read-state counts or loaded unread mentions)
	s := store()
	total := 0
	for id, &ch in s.channels {
		if ch.last_message_id == 0 do continue
		rs, _ := &s.read_states[id]
		if rs != nil && rs.last_message_id >= ch.last_message_id do continue
		total += channel_mentions_of(s, &ch, rs)
	}
	if total <= 0 do return
	if ui.parent(b) {
		text := total > 99 ? "99+" : fmt.tprint(total)
		w := max(f32(14), f32(len(text)) * 6 + 6)
		badge := ui.box(fmt.tprintf("%s##inboxbadge", text), {.Draw_Background, .Draw_Text, .Floating_X, .Floating_Y})
		badge.semantic_size = {.X = ui.px(w), .Y = ui.px(14)}
		badge.fixed_pos = {20 - w + 6, 10}
		badge.style.bg = T("--status-danger")
		badge.style.radius = 7
		badge.style.font = F(.Bold)
		badge.style.font_size = 10
		badge.style.text_color = {1, 1, 1, 1}
		badge.style.text_align = .Center
	}
}

help_button :: proc() {
	b := ui.box("help", {.Clickable})
	b.semantic_size = {.X = ui.px(20), .Y = ui.px(20)}
	sig := ui.signal(b)
	set_icon(b, "circle-question", sig.hovering ? T("--interactive-icon-hover") : T("--icon-muted"))
	if sig.hovering do tooltip_below("Help", b.rect)
	if sig.clicked do open_url("https://support.discord.com")
}

@(private = "file")
inbox_open :: proc(anchor: ui.Rect) {
	inbox.open = true
	inbox.anchor = anchor
	inbox.tab = store().settings.inbox_tab == .Mentions ? .Mentions : .Unreads
	if inbox.tab == .Mentions do mentions_first_page()
	track_tab()
}

@(private = "file")
track_tab :: proc() {
	if app.client != nil do dc.track_open_popout(app.client, inbox.tab == .Mentions ? "Recent Mentions" : "Inbox")
}

@(private = "file")
mentions_first_page :: proc() {
	if inbox.requested do return
	inbox.requested = true
	if !net_action() {
		local_mentions()
		return
	}
	inbox.loading = true
	dc.open_mentions(app.client)
}

// Offline (fixtures): the loaded messages that mention us, newest first, so
// the tab and its controls work without the REST call.
@(private = "file")
local_mentions :: proc() {
	s := store()
	if virtual.arena_init_growing(&inbox.arena) != nil do return
	alloc := virtual.arena_allocator(&inbox.arena)
	inbox.items = make([dynamic]Mention, alloc)
	for cid, &l in s.messages {
		ch := dc.channel_get(s, cid)
		for &m in l.messages {
			if m.author_id == s.me || !(m.mention_everyone || slice.contains(m.mentions[:], s.me)) do continue
			mm := m
			mm.content = strings.clone(m.content, alloc)
			append(&inbox.items, Mention{guild_id = ch != nil ? ch.guild_id : 0, msg = mm})
		}
	}
	items := inbox.items[:]
	for i in 1 ..< len(items) {
		for j := i; j > 0 && items[j].msg.id > items[j - 1].msg.id; j -= 1 do items[j], items[j - 1] = items[j - 1], items[j]
	}
	if len(inbox.items) > 25 do resize(&inbox.items, 25)
}

inbox_receive :: proc(r: ^dc.Feature_Result) {
	#partial switch r.op {
	case .Mentions:
		if r.tag == dc.MENTIONS_DUP_TAG do return
		inbox.loading = false
		if !r.ok do return
		// a reply to an older page after a reset (first page = tag 0) is dropped
		if r.tag != 0 && (len(inbox.items) == 0 || u64(inbox.items[len(inbox.items) - 1].msg.id) != r.tag) do return
		if inbox.items == nil {
			if virtual.arena_init_growing(&inbox.arena) != nil do return
			inbox.items = make([dynamic]Mention, virtual.arena_allocator(&inbox.arena))
		}
		alloc := virtual.arena_allocator(&inbox.arena)
		list := dc.vlist(r.body)
		for mv in list {
			mm := dc.vmap(mv)
			append(&inbox.items, Mention{guild_id = dc.fsnow(mm, "guild_id"), msg = dc.parse_loose_message(store(), mm, alloc)})
		}
		inbox.has_more = len(list) >= 25
		app.ui.animating = true
	case .Mention_Delete:
	}
}

inbox_popout :: proc() {
	if !inbox.open do return
	scrim := ui.box("inbox_scrim", {.Clickable, .Floating_X, .Floating_Y, .Overlay})
	scrim.semantic_size = {.X = ui.px(app.ui.window.x), .Y = ui.px(app.ui.window.y)}
	if ui.signal(scrim).clicked {
		inbox.open = false
		return
	}
	for &e in app.ui.events {
		if !e.consumed && e.kind == .Key_Down && e.key == .Escape {
			inbox.open = false
			e.consumed = true
			return
		}
	}
	x := clamp(inbox.anchor.x1 - INBOX_W, 8, app.ui.window.x - INBOX_W - 8)
	y := inbox.anchor.y1 + 8
	h := min(app.ui.window.y * 0.8, app.ui.window.y - y - 16)
	p := ui.box("inboxpop", {.Draw_Background, .Draw_Border, .Draw_Shadow, .Floating_X, .Floating_Y, .Overlay, .Clickable, .Clip})
	p.semantic_size = {.X = ui.px(INBOX_W), .Y = ui.px(h)}
	p.fixed_pos = {x, y}
	p.layout_axis = .Y
	p.style.bg = T("--background-surface-high")
	p.style.border_color = T("--border-subtle")
	p.style.border = 1
	p.style.radius = 8
	p.style.shadow_color = {0, 0, 0, 0.35}
	p.style.shadow_blur = 16
	p.style.shadow_offset = {0, 8}
	ui.signal(p)
	if ui.parent(p) {
		hdr := row("hdr")
		hdr.semantic_size = {.X = ui.pct(1), .Y = ui.px(48)}
		if ui.parent(hdr) {
			spacer(.X, 16)
			icon("i", "inbox", 20, T("--interactive-icon-default"))
			spacer(.X, 8)
			label("Inbox", .Semibold, 16, T("--text-strong"), 20)
			filler(.X)
			if inbox.tab == .Unreads {
				rows := unread_rows()
				if len(rows) > 0 {
					mb := row("markall", {.Clickable, .Draw_Background, .Hot_Animation})
					mb.semantic_size = {.X = ui.px(32), .Y = ui.px(32)}
					mb.style.radius = 8
					mb.style.bg_hot = T("--background-mod-subtle")
					msig := ui.signal(mb)
					if ui.parent(mb) {
						spacer(.X, 6)
						icon("i", "double-checkmark", 20, msig.hovering ? T("--interactive-icon-hover") : T("--interactive-icon-default"))
					}
					if msig.hovering do tooltip_below("Mark All as Read", mb.rect)
					if msig.clicked && net_action() {
						ids := make([dynamic]dc.Snowflake, 0, len(rows), context.temp_allocator)
						for r in rows do if r.channel != 0 do append(&ids, r.channel)
						dc.ack_channels(app.client, ids[:])
					}
				}
				spacer(.X, 12)
			}
		}
		tabs := row("tabs")
		tabs.semantic_size = {.X = ui.pct(1), .Y = ui.px(32)}
		if ui.parent(tabs) {
			spacer(.X, 12)
			for t in Inbox_Tab {
				name := t == .Unreads ? "Unreads" : "Mentions"
				sel := inbox.tab == t
				tb := row(name, {.Clickable, .Draw_Background, .Hot_Animation})
				tb.semantic_size = {.X = ui.children(), .Y = ui.px(28)}
				tb.style.radius = 4
				tb.style.bg = sel ? T("--background-mod-normal") : {}
				tb.style.bg_hot = sel ? tb.style.bg : T("--background-mod-subtle")
				sig := ui.signal(tb)
				if ui.parent(tb) {
					spacer(.X, 8)
					label(name, .Medium, 14, sel || sig.hovering ? T("--text-strong") : T("--text-muted"), 18)
					spacer(.X, 8)
				}
				if sig.clicked && !sel {
					inbox.tab = t
					if t == .Mentions do mentions_first_page()
					track_tab()
					stored: dc.Inbox_Tab = t == .Mentions ? .Mentions : .Unreads
					store().settings.inbox_tab = stored
					if app.client != nil do dc.set_inbox_tab(app.client, stored)
				}
				spacer(.X, 4)
			}
		}
		spacer(.Y, 8)
		line := ui.box("hl", {.Draw_Background})
		line.semantic_size = {.X = ui.pct(1), .Y = ui.px(1)}
		line.style.bg = T("--border-subtle")
		switch inbox.tab {
		case .Unreads:
			unreads_list()
		case .Mentions:
			mentions_list()
		}
	}
}

@(private = "file")
empty_note :: proc(text: string) {
	r := row("empty")
	r.semantic_size = {.X = ui.pct(1), .Y = ui.px(80)}
	if ui.parent(r) {
		filler(.X)
		label(text, .Medium, 14, T("--text-muted"), 18)
		filler(.X)
	}
}

// ---- Unreads ----

@(private = "file")
Unread_Row :: struct {
	guild:   dc.Snowflake,
	channel: dc.Snowflake, // 0: the guild's header
}

@(private = "file")
unread_rows :: proc() -> []Unread_Row {
	s := store()
	Keyed :: struct {
		key, guild, id: dc.Snowflake,
	}
	list := make([dynamic]Keyed, context.temp_allocator)
	for id, &ch in s.channels {
		if ch.last_message_id == 0 || ch.kind == .Guild_Category do continue
		if rs, ok := &s.read_states[id]; ok && rs.last_message_id >= ch.last_message_id do continue
		if dc.is_thread(&ch) {
			tm := dc.thread_meta(id)
			if tm == nil || !tm.joined || tm.archived do continue
		}
		if ch.guild_id != 0 {
			if gs, ok := &s.guild_settings[ch.guild_id]; ok {
				if gs.muted do continue
				muted := false
				for m in gs.muted_channels do if m == id || (m == ch.parent_id && m != 0) do muted = true
				if muted do continue
			}
		}
		append(&list, Keyed{ch.last_message_id, ch.guild_id, id})
	}
	for i in 1 ..< len(list) {
		for j := i; j > 0 && list[j].key > list[j - 1].key; j -= 1 do list[j], list[j - 1] = list[j - 1], list[j]
	}
	// guilds in order of their newest unread channel
	guilds := make([dynamic]dc.Snowflake, context.temp_allocator)
	for k in list {
		seen := false
		for g in guilds do if g == k.guild do seen = true
		if !seen do append(&guilds, k.guild)
	}
	out := make([dynamic]Unread_Row, 0, len(list) + len(guilds), context.temp_allocator)
	for g in guilds {
		append(&out, Unread_Row{guild = g})
		for k in list do if k.guild == g do append(&out, Unread_Row{guild = g, channel = k.id})
	}
	return out[:]
}

@(private = "file")
unreads_list :: proc() {
	s := store()
	rows := unread_rows()
	list := ui.box("unreads", {.Scroll_Y, .Clip})
	list.semantic_size = {.X = ui.pct(1), .Y = ui.fill()}
	list.layout_axis = .Y
	ui.signal(list)
	ui.push_parent(list)
	defer ui.pop_parent()
	if len(rows) == 0 {
		spacer(.Y, 8)
		empty_note("You're all caught up!")
		return
	}
	w := ui.list_window(list, UNREAD_PITCH, len(rows))
	for i in w.first ..< w.last {
		r := rows[i]
		if ui.id_scope(u64(r.channel != 0 ? r.channel : r.guild) * 2 + (r.channel != 0 ? 1 : 0)) {
			if r.channel == 0 {
				unread_header(r.guild)
				continue
			}
			ch := dc.channel_get(s, r.channel)
			if ch == nil {
				spacer(.Y, UNREAD_PITCH)
				continue
			}
			unread_row(ch)
		}
	}
	ui.list_window_end(w)
}

@(private = "file")
unread_header :: proc(gid: dc.Snowflake) {
	h := row("ghdr")
	h.semantic_size = {.X = ui.pct(1), .Y = ui.px(UNREAD_PITCH)}
	ui.push_parent(h)
	defer ui.pop_parent()
	spacer(.X, 16)
	name := "Direct Messages"
	if g := dc.guild_get(store(), gid); g != nil {
		name = g.name
		gi := ui.box("gicon", {.Draw_Background, .Draw_Text})
		gi.semantic_size = {.X = ui.px(24), .Y = ui.px(24)}
		gi.style.radius = 8
		gi.style.bg = T("--background-mod-subtle")
		gi.style.text_color = T("--text-default")
		gi.style.text_align = .Center
		gi.style.font = F(.Medium)
		gi.style.font_size = 9
		gi.text = guild_initials(g.name)
		if g.icon != "" {
			set_remote_image(gi, dc.guild_icon_url(g.id, g.icon, 48))
			gi.text = ""
		}
	} else {
		icon("gicon", "clyde", 24, T("--text-muted"))
	}
	spacer(.X, 10)
	label(ellipsize(name, .Semibold, 16, INBOX_W - 80), .Semibold, 16, T("--text-strong"), 20)
}

@(private = "file")
unread_row :: proc(ch: ^dc.Channel) {
	s := store()
	outer := row("ur")
	outer.semantic_size = {.X = ui.pct(1), .Y = ui.px(UNREAD_PITCH)}
	ui.push_parent(outer)
	defer ui.pop_parent()
	spacer(.X, 8)
	item := row("item", {.Clickable, .Draw_Background, .Hot_Animation})
	item.semantic_size = {.X = ui.fill(), .Y = ui.px(UNREAD_PITCH - 4)}
	item.style.radius = 8
	item.style.bg_hot = T("--background-mod-subtle")
	sig := ui.signal(item)
	if ui.parent(item) {
		spacer(.X, 12)
		name: string
		switch {
		case ch.kind == .DM && len(ch.recipient_ids) > 0:
			avatar_box("av", ch.recipient_ids[0], 24)
			name = dm_name(ch)
		case ch.kind == .Group_DM:
			group_dm_icon("av", ch, 24)
			name = dm_name(ch)
		case:
			icon("ci", channel_icon_name(ch), 20, T("--channel-icon"))
			spacer(.X, 4)
			name = ch.name
		}
		spacer(.X, 8)
		col := ui.box("col")
		col.semantic_size = {.X = ui.fill(), .Y = ui.children()}
		col.layout_axis = .Y
		if ui.parent(col) {
			label(ellipsize(name, .Semibold, 15, INBOX_W - 180), .Semibold, 15, T("--text-strong"), 19)
			// the newest loaded message, when there is one
			if msgs := dc.messages_get(s, ch.id); len(msgs) > 0 {
				m := &msgs[len(msgs) - 1]
				author := name_in(m.author_id, ch.id, "unknown")
				snippet := fmt.tprintf("%s: %s", author, snippet_text(s, first_line(m.content)))
				t := label(ellipsize(snippet, .Normal, 13, INBOX_W - 180), .Normal, 13, T("--text-muted"), 17)
				t.flags += {.Clip}
			}
		}
		rs, _ := &s.read_states[ch.id]
		if n := channel_mentions_of(s, ch, rs); n > 0 {
			bt := n > 99 ? "99+" : fmt.tprint(n)
			bw := max(f32(16), f32(len(bt)) * 7 + 8)
			b := ui.box(fmt.tprintf("%s##mb", bt), {.Draw_Background, .Draw_Text})
			b.semantic_size = {.X = ui.px(bw), .Y = ui.px(16)}
			b.style.bg = T("--status-danger")
			b.style.radius = 8
			b.style.font = F(.Bold)
			b.style.font_size = 12
			b.style.text_color = {1, 1, 1, 1}
			b.style.text_align = .Center
			spacer(.X, 8)
		}
		ack := ui.box("ack", {.Clickable, .Draw_Background, .Hot_Animation})
		ack.semantic_size = {.X = ui.px(28), .Y = ui.px(28)}
		ack.style.radius = 14
		ack.style.bg = T("--background-mod-subtle")
		ack.style.bg_hot = T("--background-mod-strong")
		ack.layout_axis = .X
		ack.cross_align = .Center
		asig := ui.signal(ack)
		if ui.parent(ack) {
			spacer(.X, 4)
			icon("i", "checkmark-small", 20, asig.hovering ? T("--interactive-icon-hover") : T("--interactive-icon-default"))
		}
		if asig.hovering do tooltip_below("Mark As Read", ack.rect)
		if asig.clicked && net_action() {
			dc.ack_message(app.client, ch.id, ch.last_message_id, true, dc.ACK_INBOX)
			dc.track_inbox_channel_acked(app.client, ch.id)
		}
		spacer(.X, 10)
	}
	spacer(.X, 8)
	if sig.clicked {
		select_channel(ch.guild_id, ch.id)
		inbox.open = false
	}
}

// One line of content with <@id> user mentions shown as @name.
@(private = "file")
snippet_text :: proc(s: ^dc.Store, line: string) -> string {
	if strings.index(line, "<@") < 0 do return line
	sb := strings.builder_make(context.temp_allocator)
	c := line
	for len(c) > 0 {
		i := strings.index(c, "<@")
		end := i >= 0 ? strings.index_byte(c[i:], '>') : -1
		if i < 0 || end < 0 {
			strings.write_string(&sb, c)
			break
		}
		strings.write_string(&sb, c[:i])
		tag := c[i + 2:i + end]
		c = c[i + end + 1:]
		if strings.has_prefix(tag, "&") {
			strings.write_string(&sb, "@role")
			continue
		}
		name := dc.user_name(s, dc.parse_snowflake(strings.trim_left(tag, "!")), 0, "unknown-user")
		strings.write_byte(&sb, '@')
		strings.write_string(&sb, name)
	}
	return strings.to_string(sb)
}

// ---- Mentions ----

@(private = "file")
mentions_list :: proc() {
	s := store()
	list := ui.box("mentions", {.Scroll_Y, .Clip})
	list.semantic_size = {.X = ui.pct(1), .Y = ui.fill()}
	list.layout_axis = .Y
	sig := ui.signal(list)
	if ui.parent(list) {
		spacer(.Y, 8)
		if len(inbox.items) == 0 do empty_note(inbox.loading ? "Loading..." : "Nobody has mentioned you recently.")
		remove := -1
		for &it, i in inbox.items {
			if ui.id_scope(u64(it.msg.id)) {
				ch := dc.channel_get(s, it.msg.channel_id)
				hr := row("mhdr")
				hr.semantic_size = {.X = ui.pct(1), .Y = ui.px(32)}
				if ui.parent(hr) {
					spacer(.X, 16)
					cname := "unknown channel"
					gname := ""
					if ch != nil {
						cname = ch.kind == .DM || ch.kind == .Group_DM ? dm_name(ch) : fmt.tprintf("#%s", ch.name)
					}
					gid := it.guild_id
					if gid == 0 && ch != nil do gid = ch.guild_id
					if g := dc.guild_get(s, gid); g != nil do gname = g.name
					label(ellipsize(cname, .Semibold, 14, 220), .Semibold, 14, T("--text-strong"), 18)
					if gname != "" {
						spacer(.X, 6)
						label(ellipsize(gname, .Medium, 12, 160), .Medium, 12, T("--text-muted"), 16)
					}
					filler(.X)
					x := ui.box("x", {.Clickable, .Draw_Background, .Hot_Animation})
					x.semantic_size = {.X = ui.px(24), .Y = ui.px(24)}
					x.style.radius = 12
					x.style.bg_hot = T("--background-mod-strong")
					x.layout_axis = .X
					x.cross_align = .Center
					xs := ui.signal(x)
					if ui.parent(x) {
						spacer(.X, 2)
						icon("i", "x-small", 20, xs.hovering ? T("--interactive-icon-hover") : T("--interactive-icon-default"))
					}
					if xs.hovering do tooltip_below("Mark As Read", x.rect)
					if xs.clicked && net_action() {
						dc.delete_mention(app.client, it.msg.id)
						remove = i
					}
					spacer(.X, 12)
				}
				if loose_message_card(&it.msg, nil, true) {
					jump_to_message(it.msg.channel_id, it.msg.id)
					if app.client != nil do dc.track_jump(app.client, "Recent Mentions", it.msg.channel_id, it.msg.id)
					inbox.open = false
				}
			}
		}
		if remove >= 0 do ordered_remove(&inbox.items, remove)
		spacer(.Y, 8)
	}
	// load more near the end
	if inbox.has_more && !inbox.loading && app.client != nil && len(inbox.items) > 0 && sig.hovering {
		if list.content_size.y > 0 && list.view_off.y + (list.rect.y1 - list.rect.y0) > list.content_size.y - 200 {
			inbox.loading = true
			dc.fetch_mentions(app.client, inbox.items[len(inbox.items) - 1].msg.id)
		}
	}
}

inbox_reset_for_test :: proc() {
	virtual.arena_destroy(&inbox.arena)
	inbox = {}
}
