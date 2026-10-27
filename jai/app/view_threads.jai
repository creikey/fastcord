#scope_file

// Threads and forum channels.
//   - sidebar: active threads we're a member of, under their parent channel
//     (indented rows on the channel pitch, like the client's thread list)
//   - thread starter messages carry the thread summary box
//   - forum channels show the post list; opening a post is a normal channel
//     select of the thread (its messages use the chat view)
// Data: dc.extras (thread metadata, forum tags) and the feature REST calls.

Forum_State :: struct {
	requested_archived: bool;
	requested_posts: Map(dc.Snowflake, bool);
}

forums: Map(dc.Snowflake, Forum_State);
#scope_export

// ---- sidebar ----

// Rows for the active threads we joined under `ch` (called after channel_row).
sidebar_thread_rows :: (ch: *dc.Channel, gid: dc.Snowflake) {
	s := store();
	ids := dc.joined_threads(s, ch.id);
	if len(ids) == 0 { return; }
	for tid, i: ids {
		th := dc.channel_get(s, tid);
		if th == null { continue; }
		if ui.id_scope(cast(u64)(tid)) {
			selected := app.view.channel == tid;
			unread := dc.channel_unread(s, tid);
			outer := row("thread");
			outer.semantic_size = .{__IDX__.X = ui.pct(1), __IDX__.Y = ui.px(CHANNEL_ROW_PITCH)};
			if ui.parent(outer) {
				spacer(.X, 8);
				// the spine: a vertical line from the parent row, curving into this row
				spine := ui.box("spine");
				spine.semantic_size = .{__IDX__.X = ui.px(28), __IDX__.Y = ui.px(CHANNEL_ROW_PITCH)};
				if ui.parent(spine) {
					v := ui.box("v", .{.Draw_Background, .Floating_X, .Floating_Y});
					v.semantic_size = .{__IDX__.X = ui.px(1.5), __IDX__.Y = ui.px(ifx i == len(ids) - 1 then CHANNEL_ROW_PITCH / 2 else CHANNEL_ROW_PITCH)};
					v.fixed_pos = .{16, -2};
					v.style.bg = cast(T)("--border-strong");
					h := ui.box("h", .{.Draw_Background, .Floating_X, .Floating_Y});
					h.semantic_size = .{__IDX__.X = ui.px(10), __IDX__.Y = ui.px(1.5)};
					h.fixed_pos = .{16, CHANNEL_ROW_PITCH / 2 - 1};
					h.style.bg = cast(T)("--border-strong");
				}
				item := row("item", .{.Clickable, .Draw_Background, .Hot_Animation});
				item.semantic_size = .{__IDX__.X = ui.fill(), __IDX__.Y = ui.px(CHANNEL_ROW_H)};
				item.style.radius = 8;
				item.style.bg = ifx selected then cast(T)("--background-mod-normal") else .{};
				item.style.bg_hot = ifx selected then item.style.bg else cast(T)("--background-mod-subtle");
				sig := ui.signal(item);
				if sig.clicked { select_channel(gid, tid); }
				if sig.right_clicked { thread_menu_open(tid, app.ui.mouse); }
				color := cast(T)("--channels-default");
				if selected || unread {
					color = cast(T)("--interactive-text-active");
				} else if sig.hovering {
					color = cast(T)("--interactive-text-hover");
				}
				if ui.parent(item) {
					spacer(.X, 8);
					label(ellipsize(th.name, .Medium, 16, SIDEBAR_W - 90), ifx unread || selected then .Semibold else .Medium, 16, color, 20);
					filler(.X);
				}
				spacer(.X, 9);
			}
		}
	}
}

// ---- thread summary under the starter message ----

thread_summary_pill :: (m: *dc.Message) {
	s := store();
	th := dc.channel_get(s, m.id); // a thread started from a message has the message's id
	if !dc.is_thread(th) || th.parent_id != m.channel_id { return; }
	tm := dc.thread_meta(th.id);
	count := ifx tm != null then tm.message_count else 0;
	spacer(.Y, 4);
	box := ui.box("threadpill", .{.Clickable, .Draw_Background, .Draw_Border, .Hot_Animation});
	box.semantic_size = .{__IDX__.X = ui.px(480), __IDX__.Y = ui.children()};
	box.layout_axis = .Y;
	box.style.bg = cast(T)("--background-base-low");
	box.style.bg_hot = cast(T)("--background-mod-subtle");
	box.style.border_color = cast(T)("--border-subtle");
	box.style.border = 1;
	box.style.radius = 8;
	sig := ui.signal(box);
	if sig.clicked { select_channel(th.guild_id, th.id); }
	if ui.parent(box) {
		inset_begin(12, 8);
		defer inset_end(12, 8);
		r := row("top");
		r.semantic_size = .{__IDX__.X = ui.pct(1), __IDX__.Y = ui.px(20)};
		if ui.parent(r) {
			label(th.name, .Semibold, 14, cast(T)("--text-strong"), 18);
			spacer(.X, 8);
			label(ifx count == 1 then "1 Message" else fmt.tprintf("%d Messages", count), .Semibold, 14, cast(T)("--text-link"), 18);
			icon("chev", "chevron-small-right", 16, cast(T)("--text-link"));
		}
		// the latest message, when it's loaded
		msgs := dc.messages_get(s, th.id);
		if len(msgs) > 0 {
			last := *msgs[len(msgs) - 1];
			spacer(.Y, 4);
			lr := row("last");
			lr.semantic_size = .{__IDX__.X = ui.pct(1), __IDX__.Y = ui.px(18)};
			if ui.parent(lr) {
				avatar_box("av", last.author_id, 16);
				spacer(.X, 6);
				label(name_in(last.author_id, last.channel_id, "unknown"), .Medium, 14, author_color(last), 18);
				spacer(.X, 6);
				t := label(ellipsize(first_line(last.content), .Normal, 14, 300), .Normal, 14, cast(T)("--text-muted"), 18);
				t.flags += .{.Clip};
			}
		}
	}
}

// ---- forum channels ----

forum_view :: (ch: *dc.Channel) {
	s := store();
	st, ok := map_find_ptr(*forums, ch.id);
	if !ok {
		at(*forums, ch.id).* = .{};
		st = at(*forums, ch.id);
	}
	if app.client != null && !st.requested_archived {
		st.requested_archived = true;
		dc.fetch_archived_forum_threads(app.client, ch.id, 0);
	}
	posts := dc.forum_threads(s, ch.id);
	// first messages for the cards, 10 at a time like the client
	if app.client != null {
		need := make_dynamic(dc.Snowflake, 0, 0, temp);
		for id: posts {
			tm := dc.thread_meta(id);
			if tm == null || tm.first_content != "" || __MAPIDX__(st.requested_posts|id) { continue; }
			at(*st.requested_posts, id).* = true;
			append(*need, id);
		}
		if len(need) > 0 { dc.fetch_forum_posts(app.client, ch.id, view(need)); }
	}

	list := ui.box("forum", .{.Scroll_Y, .Clip});
	list.semantic_size = .{__IDX__.X = ui.fill(), __IDX__.Y = ui.pct(1)};
	list.layout_axis = .Y;
	ui.signal(list);
	if ui.parent(list) {
		spacer(.Y, 16);
		hdr := row("forumhdr");
		hdr.semantic_size = .{__IDX__.X = ui.pct(1), __IDX__.Y = ui.px(40)};
		if ui.parent(hdr) {
			spacer(.X, 24);
			sb := row("newpost", .{.Draw_Background, .Draw_Border});
			sb.semantic_size = .{__IDX__.X = ui.fill(), __IDX__.Y = ui.px(40)};
			sb.style.bg = cast(T)("--background-base-lowest");
			sb.style.border_color = cast(T)("--border-subtle");
			sb.style.border = 1;
			sb.style.radius = 8;
			if ui.parent(sb) {
				spacer(.X, 12);
				icon("s", "magnifying-glass", 16, cast(T)("--text-muted"));
				spacer(.X, 8);
				label("Search or create a post...", .Normal, 14, cast(T)("--text-muted"), 18);
			}
			spacer(.X, 24);
		}
		spacer(.Y, 16);
		if len(posts) == 0 {
			r := row("empty");
			r.semantic_size = .{__IDX__.X = ui.pct(1), __IDX__.Y = ui.px(40)};
			if ui.parent(r) {
				filler(.X);
				label("No posts yet", .Medium, 14, cast(T)("--text-muted"), 18);
				filler(.X);
			}
		}
		tags := dc.forum_tags(ch.id);
		for id: posts {
			th := dc.channel_get(s, id);
			if th == null { continue; }
			if ui.id_scope(cast(u64)(id)) { forum_card(ch, th, tags); }
		}
		spacer(.Y, 24);
	}
}
#scope_file

forum_card :: (forum: *dc.Channel, th: *dc.Channel, tags: []dc.Forum_Tag) {
	tm := dc.thread_meta(th.id);
	outer := row("cardrow");
	outer.semantic_size = .{__IDX__.X = ui.pct(1), __IDX__.Y = ui.children()};
	if ui.parent(outer) {
		spacer(.X, 24);
		card := ui.box("card", .{.Clickable, .Draw_Background, .Draw_Border, .Hot_Animation});
		card.semantic_size = .{__IDX__.X = ui.fill(), __IDX__.Y = ui.children()};
		card.layout_axis = .Y;
		card.style.bg = cast(T)("--card-background-default");
		card.style.bg_hot = cast(T)("--background-mod-subtle");
		card.style.border_color = cast(T)("--card-border-default");
		card.style.border = 1;
		card.style.radius = 8;
		if ui.signal(card).clicked { select_channel(forum.guild_id, th.id); }
		if ui.parent(card) {
			inset_begin(16, 12);
			defer inset_end(16, 12);
			// tags
			if tm != null && len(tm.applied_tags) > 0 {
				tr := row("tags");
				tr.semantic_size = .{__IDX__.X = ui.pct(1), __IDX__.Y = ui.px(22)};
				tr.style.child_gap = 4;
				if ui.parent(tr) {
					for tid, i: tm.applied_tags {
						for t: tags {
							if t.id != tid { continue; }
							chip := row(fmt.tprintf("tag%d", i), .{.Draw_Background});
							chip.semantic_size = .{__IDX__.X = ui.children(), __IDX__.Y = ui.px(20)};
							chip.style.bg = cast(T)("--background-mod-normal");
							chip.style.radius = 10;
							if ui.parent(chip) {
								spacer(.X, 8);
								if t.emoji_name != "" {
									emoji_label(t.emoji_name, .Medium, 12, cast(T)("--text-default"), 16);
									spacer(.X, 4);
								}
								label(t.name, .Medium, 12, cast(T)("--text-default"), 16);
								spacer(.X, 8);
							}
						}
					}
				}
				spacer(.Y, 6);
			}
			label(th.name, .Semibold, 16, cast(T)("--text-strong"), 20);
			spacer(.Y, 4);
			if tm != null && tm.first_content != "" {
				pr := row("preview");
				pr.semantic_size = .{__IDX__.X = ui.pct(1), __IDX__.Y = ui.px(18)};
				if ui.parent(pr) {
					name := name_in(tm.first_author, th.id, "");
					if name != "" {
						label(fmt.tprintf("%s:", name), .Medium, 14, cast(T)("--text-default"), 18);
						spacer(.X, 4);
					}
					t := label(ellipsize(first_line(tm.first_content), .Normal, 14, 600), .Normal, 14, cast(T)("--text-muted"), 18);
					t.flags += .{.Clip};
				}
				spacer(.Y, 6);
			}
			mr := row("meta");
			mr.semantic_size = .{__IDX__.X = ui.pct(1), __IDX__.Y = ui.px(18)};
			if ui.parent(mr) {
				icon("ic", "chat", 16, cast(T)("--text-muted"));
				spacer(.X, 4);
				n := ifx tm != null then tm.message_count else 0;
				label(fmt.tprintf("%d", n), .Medium, 14, cast(T)("--text-muted"), 18);
				spacer(.X, 8);
				last := ifx th.last_message_id != 0 then th.last_message_id else th.id;
				if tm != null && tm.last_message_id > last { last = tm.last_message_id; }
				label(relative_age(last), .Normal, 14, cast(T)("--text-muted"), 18);
				if tm != null && tm.archived {
					spacer(.X, 8);
					icon("arch", "lock", 14, cast(T)("--text-muted"));
				}
			}
		}
		spacer(.X, 24);
	}
	spacer(.Y, 8);
}
#scope_export

// "5m ago" / "3h ago" / "2d ago" from a snowflake.
relative_age :: (id: dc.Snowflake) -> string {
	dt := (wall_ms() - dc.snowflake_time_ms(id)) / 1000;
	if dt < 60 {
		return "just now";
	} else if dt < 3600 {
		return fmt.tprintf("%dm ago", dt / 60);
	} else if dt < 86400 {
		return fmt.tprintf("%dh ago", dt / 3600);
	} else if dt < 86400 * 30 {
		return fmt.tprintf("%dd ago", dt / 86400);
	}
	return fmt.tprintf("%dmo ago", dt / (86400 * 30));
}

// Header prefix for threads: "parent ›" before the thread name.
thread_header_prefix :: (ch: *dc.Channel) {
	if !dc.is_thread(ch) { return; }
	p := dc.channel_get(store(), ch.parent_id);
	if p == null { return; }
	b := row("parent", .{.Clickable});
	b.semantic_size = .{__IDX__.X = ui.children(), __IDX__.Y = ui.px(24)};
	sig := ui.signal(b);
	if sig.clicked { select_channel(p.guild_id, p.id); }
	if ui.parent(b) {
		icon("pi", channel_icon_name(p), 20, cast(T)("--channel-icon"));
		spacer(.X, 6);
		label(p.name, .Semibold, 16, ifx sig.hovering then cast(T)("--text-strong") else cast(T)("--text-muted"), 20);
		spacer(.X, 4);
		icon("chev", "chevron-small-right", 16, cast(T)("--text-muted"));
		spacer(.X, 4);
	}
}

// ---- feature results (pins, search, forum, jumps) ----

features_receive :: () {
	if app.client == null { return; }
	for * r: dc.feature_take(app.client) {
		defer dc.feature_result_free(*r);
		if r.op == {
		case .Forum_Posts; #through; case .Thread_Search;
			if r.ok { dc.apply_forum_threads(app.client, r.body); }
			app.ui.animating = true;
		case .Pins;
			pins_receive(*r);
		case .Pins_Ack;
		case .Around;
			dc.apply_around(app.client, *r);
			app.ui.animating = true;
		case .Search;
			search_receive(*r);
		case .Thread_Browse; #through; case .Thread_Create;
			threads_browser_receive(*r);
		case .Mentions; #through; case .Mention_Delete;
			inbox_receive(*r);
		case .User_Patch; #through; case .Profile_Patch;
			account_receive(*r); // view_settings_account.odin
		case .Event_Create; #through; case .Event_Counts; #through; case .Event_Rsvps; #through; case .Event_Interest; #through; case .Event_Invite; #through; case .Event_Delete; #through; case .Event_Start;
			events_receive(*r); // view_events.odin (dc.guild_admin_apply first)
		case .Guild_Aux; #through; case .Channel_Create; #through; case .Channel_Edit; #through; case .Channel_Delete; #through; case .Emoji_Upload;
			guild_admin_receive(*r);
		}
	}
}


// Container padding (ui's style.padding only pads text): call inside a Y box;
// returns the inner column. Close with inset_end.
inset_begin :: (px: float32, py: float32) -> *ui.Box {
	spacer(.Y, py);
	r := row("inset");
	r.semantic_size = .{__IDX__.X = ui.pct(1), __IDX__.Y = ui.children()};
	ui.push_parent(r);
	spacer(.X, px);
	inner := ui.box("inner");
	inner.semantic_size = .{__IDX__.X = ui.fill(), __IDX__.Y = ui.children()};
	inner.layout_axis = .Y;
	ui.push_parent(inner);
	return inner;
}

inset_end :: (px: float32, py: float32) {
	ui.pop_parent(); // inner
	spacer(.X, px);
	ui.pop_parent(); // row
	spacer(.Y, py);
}

forums_reset_for_test :: () {forums = .{};}

