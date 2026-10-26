package app

import "core:fmt"
import dc "fc:discord"
import "fc:ui"

// Threads and forum channels.
//   - sidebar: active threads we're a member of, under their parent channel
//     (indented rows on the channel pitch, like the client's thread list)
//   - thread starter messages carry the thread summary box
//   - forum channels show the post list; opening a post is a normal channel
//     select of the thread (its messages use the chat view)
// Data: dc.extras (thread metadata, forum tags) and the feature REST calls.

@(private = "file")
Forum_State :: struct {
	requested_archived: bool,
	requested_posts:    map[dc.Snowflake]bool,
}

@(private = "file")
forums: map[dc.Snowflake]Forum_State

// ---- sidebar ----

// Rows for the active threads we joined under `ch` (called after channel_row).
sidebar_thread_rows :: proc(ch: ^dc.Channel, gid: dc.Snowflake) {
	s := store()
	ids := dc.joined_threads(s, ch.id)
	if len(ids) == 0 do return
	for tid, i in ids {
		th := dc.channel_get(s, tid)
		if th == nil do continue
		if ui.id_scope(u64(tid)) {
			selected := app.view.channel == tid
			unread := dc.channel_unread(s, tid)
			outer := row("thread")
			outer.semantic_size = {.X = ui.pct(1), .Y = ui.px(CHANNEL_ROW_PITCH)}
			if ui.parent(outer) {
				spacer(.X, 8)
				// the spine: a vertical line from the parent row, curving into this row
				spine := ui.box("spine")
				spine.semantic_size = {.X = ui.px(28), .Y = ui.px(CHANNEL_ROW_PITCH)}
				if ui.parent(spine) {
					v := ui.box("v", {.Draw_Background, .Floating_X, .Floating_Y})
					v.semantic_size = {.X = ui.px(1.5), .Y = ui.px(i == len(ids) - 1 ? CHANNEL_ROW_PITCH / 2 : CHANNEL_ROW_PITCH)}
					v.fixed_pos = {16, -2}
					v.style.bg = T("--border-strong")
					h := ui.box("h", {.Draw_Background, .Floating_X, .Floating_Y})
					h.semantic_size = {.X = ui.px(10), .Y = ui.px(1.5)}
					h.fixed_pos = {16, CHANNEL_ROW_PITCH / 2 - 1}
					h.style.bg = T("--border-strong")
				}
				item := row("item", {.Clickable, .Draw_Background, .Hot_Animation})
				item.semantic_size = {.X = ui.fill(), .Y = ui.px(CHANNEL_ROW_H)}
				item.style.radius = 8
				item.style.bg = selected ? T("--background-mod-normal") : {}
				item.style.bg_hot = selected ? item.style.bg : T("--background-mod-subtle")
				sig := ui.signal(item)
				if sig.clicked do select_channel(gid, tid)
				color := T("--channels-default")
				if selected || unread {
					color = T("--interactive-text-active")
				} else if sig.hovering {
					color = T("--interactive-text-hover")
				}
				if ui.parent(item) {
					spacer(.X, 8)
					label(ellipsize(th.name, .Medium, 16, SIDEBAR_W - 90), unread || selected ? .Semibold : .Medium, 16, color, 20)
					filler(.X)
				}
				spacer(.X, 9)
			}
		}
	}
}

// ---- thread summary under the starter message ----

thread_summary_pill :: proc(m: ^dc.Message) {
	s := store()
	th := dc.channel_get(s, m.id) // a thread started from a message has the message's id
	if !dc.is_thread(th) || th.parent_id != m.channel_id do return
	tm := dc.thread_meta(th.id)
	count := tm != nil ? tm.message_count : 0
	spacer(.Y, 4)
	box := ui.box("threadpill", {.Clickable, .Draw_Background, .Draw_Border, .Hot_Animation})
	box.semantic_size = {.X = ui.px(480), .Y = ui.children()}
	box.layout_axis = .Y
	box.style.bg = T("--background-base-low")
	box.style.bg_hot = T("--background-mod-subtle")
	box.style.border_color = T("--border-subtle")
	box.style.border = 1
	box.style.radius = 8
	sig := ui.signal(box)
	if sig.clicked do select_channel(th.guild_id, th.id)
	if ui.parent(box) {
		inset_begin(12, 8)
		defer inset_end(12, 8)
		r := row("top")
		r.semantic_size = {.X = ui.pct(1), .Y = ui.px(20)}
		if ui.parent(r) {
			label(th.name, .Semibold, 14, T("--text-strong"), 18)
			spacer(.X, 8)
			label(count == 1 ? "1 Message" : fmt.tprintf("%d Messages", count), .Semibold, 14, T("--text-link"), 18)
			icon("chev", "chevron-small-right", 16, T("--text-link"))
		}
		// the latest message, when it's loaded
		msgs := dc.messages_get(s, th.id)
		if len(msgs) > 0 {
			last := &msgs[len(msgs) - 1]
			spacer(.Y, 4)
			lr := row("last")
			lr.semantic_size = {.X = ui.pct(1), .Y = ui.px(18)}
			if ui.parent(lr) {
				avatar_box("av", last.author_id, 16)
				spacer(.X, 6)
				name := "unknown"
				if u := dc.user_get(s, last.author_id); u != nil do name = dc.display_name(u)
				label(name, .Medium, 14, author_color(last), 18)
				spacer(.X, 6)
				t := label(ellipsize(first_line(last.content), .Normal, 14, 300), .Normal, 14, T("--text-muted"), 18)
				t.flags += {.Clip}
			}
		}
	}
}

// ---- forum channels ----

forum_view :: proc(ch: ^dc.Channel) {
	s := store()
	st, ok := &forums[ch.id]
	if !ok {
		forums[ch.id] = {}
		st = &forums[ch.id]
	}
	if app.client != nil && !st.requested_archived {
		st.requested_archived = true
		dc.fetch_archived_forum_threads(app.client, ch.id, 0)
	}
	posts := dc.forum_threads(s, ch.id)
	// first messages for the cards, 10 at a time like the client
	if app.client != nil {
		need := make([dynamic]dc.Snowflake, context.temp_allocator)
		for id in posts {
			tm := dc.thread_meta(id)
			if tm == nil || tm.first_content != "" || st.requested_posts[id] do continue
			st.requested_posts[id] = true
			append(&need, id)
		}
		if len(need) > 0 do dc.fetch_forum_posts(app.client, ch.id, need[:])
	}

	list := ui.box("forum", {.Scroll_Y, .Clip})
	list.semantic_size = {.X = ui.fill(), .Y = ui.pct(1)}
	list.layout_axis = .Y
	ui.signal(list)
	if ui.parent(list) {
		spacer(.Y, 16)
		hdr := row("forumhdr")
		hdr.semantic_size = {.X = ui.pct(1), .Y = ui.px(40)}
		if ui.parent(hdr) {
			spacer(.X, 24)
			sb := row("newpost", {.Draw_Background, .Draw_Border})
			sb.semantic_size = {.X = ui.fill(), .Y = ui.px(40)}
			sb.style.bg = T("--background-base-lowest")
			sb.style.border_color = T("--border-subtle")
			sb.style.border = 1
			sb.style.radius = 8
			if ui.parent(sb) {
				spacer(.X, 12)
				icon("s", "magnifying-glass", 16, T("--text-muted"))
				spacer(.X, 8)
				label("Search or create a post...", .Normal, 14, T("--text-muted"), 18)
			}
			spacer(.X, 24)
		}
		spacer(.Y, 16)
		if len(posts) == 0 {
			r := row("empty")
			r.semantic_size = {.X = ui.pct(1), .Y = ui.px(40)}
			if ui.parent(r) {
				filler(.X)
				label("No posts yet", .Medium, 14, T("--text-muted"), 18)
				filler(.X)
			}
		}
		tags := dc.forum_tags(ch.id)
		for id in posts {
			th := dc.channel_get(s, id)
			if th == nil do continue
			if ui.id_scope(u64(id)) do forum_card(ch, th, tags)
		}
		spacer(.Y, 24)
	}
}

@(private = "file")
forum_card :: proc(forum: ^dc.Channel, th: ^dc.Channel, tags: []dc.Forum_Tag) {
	s := store()
	tm := dc.thread_meta(th.id)
	outer := row("cardrow")
	outer.semantic_size = {.X = ui.pct(1), .Y = ui.children()}
	if ui.parent(outer) {
		spacer(.X, 24)
		card := ui.box("card", {.Clickable, .Draw_Background, .Draw_Border, .Hot_Animation})
		card.semantic_size = {.X = ui.fill(), .Y = ui.children()}
		card.layout_axis = .Y
		card.style.bg = T("--card-background-default")
		card.style.bg_hot = T("--background-mod-subtle")
		card.style.border_color = T("--card-border-default")
		card.style.border = 1
		card.style.radius = 8
		if ui.signal(card).clicked do select_channel(forum.guild_id, th.id)
		if ui.parent(card) {
			inset_begin(16, 12)
			defer inset_end(16, 12)
			// tags
			if tm != nil && len(tm.applied_tags) > 0 {
				tr := row("tags")
				tr.semantic_size = {.X = ui.pct(1), .Y = ui.px(22)}
				tr.style.child_gap = 4
				if ui.parent(tr) {
					for tid, i in tm.applied_tags {
						for t in tags {
							if t.id != tid do continue
							chip := row(fmt.tprintf("tag%d", i), {.Draw_Background})
							chip.semantic_size = {.X = ui.children(), .Y = ui.px(20)}
							chip.style.bg = T("--background-mod-normal")
							chip.style.radius = 10
							if ui.parent(chip) {
								spacer(.X, 8)
								if t.emoji_name != "" {
									emoji_label(t.emoji_name, .Medium, 12, T("--text-default"), 16)
									spacer(.X, 4)
								}
								label(t.name, .Medium, 12, T("--text-default"), 16)
								spacer(.X, 8)
							}
						}
					}
				}
				spacer(.Y, 6)
			}
			label(th.name, .Semibold, 16, T("--text-strong"), 20)
			spacer(.Y, 4)
			if tm != nil && tm.first_content != "" {
				pr := row("preview")
				pr.semantic_size = {.X = ui.pct(1), .Y = ui.px(18)}
				if ui.parent(pr) {
					name := ""
					if u := dc.user_get(s, tm.first_author); u != nil do name = dc.display_name(u)
					if name != "" {
						label(fmt.tprintf("%s:", name), .Medium, 14, T("--text-default"), 18)
						spacer(.X, 4)
					}
					t := label(ellipsize(first_line(tm.first_content), .Normal, 14, 600), .Normal, 14, T("--text-muted"), 18)
					t.flags += {.Clip}
				}
				spacer(.Y, 6)
			}
			mr := row("meta")
			mr.semantic_size = {.X = ui.pct(1), .Y = ui.px(18)}
			if ui.parent(mr) {
				icon("ic", "chat", 16, T("--text-muted"))
				spacer(.X, 4)
				n := tm != nil ? tm.message_count : 0
				label(fmt.tprintf("%d", n), .Medium, 14, T("--text-muted"), 18)
				spacer(.X, 8)
				last := th.last_message_id != 0 ? th.last_message_id : th.id
				if tm != nil && tm.last_message_id > last do last = tm.last_message_id
				label(relative_age(last), .Normal, 14, T("--text-muted"), 18)
				if tm != nil && tm.archived {
					spacer(.X, 8)
					icon("arch", "lock", 14, T("--text-muted"))
				}
			}
		}
		spacer(.X, 24)
	}
	spacer(.Y, 8)
}

// "5m ago" / "3h ago" / "2d ago" from a snowflake.
relative_age :: proc(id: dc.Snowflake) -> string {
	dt := (wall_ms() - dc.snowflake_time_ms(id)) / 1000
	switch {
	case dt < 60:
		return "just now"
	case dt < 3600:
		return fmt.tprintf("%dm ago", dt / 60)
	case dt < 86400:
		return fmt.tprintf("%dh ago", dt / 3600)
	case dt < 86400 * 30:
		return fmt.tprintf("%dd ago", dt / 86400)
	}
	return fmt.tprintf("%dmo ago", dt / (86400 * 30))
}

// Header prefix for threads: "parent ›" before the thread name.
thread_header_prefix :: proc(ch: ^dc.Channel) {
	if !dc.is_thread(ch) do return
	p := dc.channel_get(store(), ch.parent_id)
	if p == nil do return
	b := row("parent", {.Clickable})
	b.semantic_size = {.X = ui.children(), .Y = ui.px(24)}
	sig := ui.signal(b)
	if sig.clicked do select_channel(p.guild_id, p.id)
	if ui.parent(b) {
		icon("pi", channel_icon_name(p), 20, T("--channel-icon"))
		spacer(.X, 6)
		label(p.name, .Semibold, 16, sig.hovering ? T("--text-strong") : T("--text-muted"), 20)
		spacer(.X, 4)
		icon("chev", "chevron-small-right", 16, T("--text-muted"))
		spacer(.X, 4)
	}
}

// ---- feature results (pins, search, forum, jumps) ----

features_receive :: proc() {
	if app.client == nil do return
	for &r in dc.feature_take(app.client) {
		defer dc.feature_result_free(&r)
		switch r.op {
		case .Forum_Posts, .Thread_Search:
			if r.ok do dc.apply_forum_threads(app.client, r.body)
			app.ui.animating = true
		case .Pins:
			pins_receive(&r)
		case .Pins_Ack:
		case .Around:
			dc.apply_around(app.client, &r)
			app.ui.animating = true
		case .Search:
			search_receive(&r)
		}
	}
}


// Container padding (ui's style.padding only pads text): call inside a Y box;
// returns the inner column. Close with inset_end.
inset_begin :: proc(px, py: f32) -> ^ui.Box {
	spacer(.Y, py)
	r := row("inset")
	r.semantic_size = {.X = ui.pct(1), .Y = ui.children()}
	ui.push_parent(r)
	spacer(.X, px)
	inner := ui.box("inner")
	inner.semantic_size = {.X = ui.fill(), .Y = ui.children()}
	inner.layout_axis = .Y
	ui.push_parent(inner)
	return inner
}

inset_end :: proc(px, py: f32) {
	ui.pop_parent() // inner
	spacer(.X, px)
	ui.pop_parent() // row
	spacer(.Y, py)
}

forums_reset_for_test :: proc() {forums = {}}
