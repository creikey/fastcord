// Threads and forum channels.
//   - sidebar: active threads we're a member of, under their parent channel
//     (indented rows on the channel pitch, like the client's thread list)
//   - thread starter messages carry the thread summary box
//   - forum channels show the post list; opening a post is a normal channel
//     select of the thread (its messages use the chat view)
// Data: the Store's extras (thread metadata, forum tags) and the feature REST calls.

// ---- sidebar ----

// Rows for the active threads we joined under `ch` (called after channel_row).
sidebar_thread_rows :: (ch: *dc.Channel, gid: dc.Snowflake) {
	s := store();
	ids := dc.joined_threads(s, ch.id);
	for tid, i: ids {
		th := dc.channel_get(s, tid);
		if th == null || undo_hides(tid) continue;
		ui.id_scope(cast(u64) tid);
		defer ui.pop_seed();
		selected := app.view.channel == tid;
		muted := dc.channel_effectively_muted(s, gid, tid, wall_ms()); // its own mute or its channel's
		unread := dc.channel_unread(s, tid) && !muted;
		outer := row("thread");
		outer.semantic_size = .[ui.pct(1), ui.px(CHANNEL_ROW_PITCH)];
		{ ui.parent(outer); defer ui.pop_parent();
			spacer(.X, 8);
			// the spine: a vertical line from the parent row, curving into this row
			spine := ui.box("spine");
			spine.semantic_size = .[ui.px(28), ui.px(CHANNEL_ROW_PITCH)];
			{ ui.parent(spine); defer ui.pop_parent();
				v := ui.box("v", .Draw_Background | .Floating_X | .Floating_Y);
				v.semantic_size = .[ui.px(1.5), ui.px(cast(float32) (ifx i == ids.count - 1 then CHANNEL_ROW_PITCH / 2 else CHANNEL_ROW_PITCH))];
				v.fixed_pos = .{16, -2};
				v.style.bg = T("--border-strong");
				h := ui.box("h", .Draw_Background | .Floating_X | .Floating_Y);
				h.semantic_size = .[ui.px(10), ui.px(1.5)];
				h.fixed_pos = .{16, CHANNEL_ROW_PITCH / 2 - 1};
				h.style.bg = T("--border-strong");
			}
			item := row("item", .Clickable | .Draw_Background | .Hot_Animation);
			item.semantic_size = .[ui.fill(), ui.px(CHANNEL_ROW_H)];
			item.style.radius = all4(8);
			item.style.bg = ifx selected then T("--background-mod-normal") else .{};
			item.style.bg_hot = ifx selected then item.style.bg else T("--background-mod-subtle");
			sig := ui.signal(item);
			if sig.clicked select_channel(gid, tid);
			if sig.right_clicked thread_menu_open(tid, app.ui.mouse);
			color := ifx selected || unread then T("--interactive-text-active")
				else ifx sig.hovering then T("--interactive-text-hover") else ifx muted then T("--interactive-muted") else T("--channels-default");
			{ ui.parent(item); defer ui.pop_parent();
				spacer(.X, 8);
				label(ellipsize(th.name, .Medium, 16, app.view.sidebar_w - 90), ifx unread || selected then .Semibold else .Medium, 16, color, 20);
				filler(.X);
			}
			spacer(.X, 9);
		}
	}
}

// ---- thread summary under the starter message ----

thread_summary_pill :: (m: *dc.Message) {
	s := store();
	th := dc.channel_get(s, m.id); // a thread started from a message has the message's id
	if !dc.is_thread(th) || th.parent_id != m.channel_id return;
	tm := dc.thread_meta(store(), th.id);
	count := ifx tm != null then tm.message_count else 0;
	spacer(.Y, 4);
	box := ui.box("threadpill", .Clickable | .Draw_Background | .Draw_Border | .Hot_Animation);
	box.semantic_size = .[ui.px(480), ui.children()];
	box.layout_axis = .Y;
	box.style.bg = T("--background-base-low");
	box.style.bg_hot = T("--background-mod-subtle");
	box.style.border_color = T("--border-subtle");
	box.style.border = 1;
	box.style.radius = all4(8);
	sig := ui.signal(box);
	if sig.clicked select_channel(th.guild_id, th.id);
	{ ui.parent(box); defer ui.pop_parent();
		inset_begin(12, 8);
		defer inset_end(12, 8);
		r := row("top");
		r.semantic_size = .[ui.pct(1), ui.px(20)];
		{ ui.parent(r); defer ui.pop_parent();
			label(th.name, .Semibold, 14, T("--text-strong"), 18);
			spacer(.X, 8);
			label(ifx count == 1 then L("1 Message") else tprint(L("% Messages"), count), .Semibold, 14, T("--text-link"), 18);
			icon("chev", "chevron-small-right", 16, T("--text-link"));
		}
		// the latest message, when it's loaded
		msgs := dc.messages_get(s, th.id);
		if msgs.count {
			last := *msgs[msgs.count - 1];
			spacer(.Y, 4);
			lr := row("last");
			lr.semantic_size = .[ui.pct(1), ui.px(18)];
			{ ui.parent(lr); defer ui.pop_parent();
				avatar_box("av", last.author_id, 16);
				spacer(.X, 6);
				label(author_name(last, "unknown"), .Medium, 14, author_color(last), 18);
				spacer(.X, 6);
				t := label(ellipsize(first_line(last.content), .Normal, 14, 300), .Normal, 14, T("--text-muted"), 18);
				t.flags |= .Clip;
			}
		}
	}
}

// ---- forum channels ----

// A forum: "Search or create a post..." filters the posts by title as you type, and New Post (or Enter)
// opens the post form with the typed title: tags, the first message, Post. Sort (Recent Activity or
// Date Posted) and a tag filter sit above the cards.
FORUM_POST_TAG :: cast(u64) 1 << 62; // Thread_Create tags of forum posts, apart from the threads browser's
FORUM_REQUIRE_TAG :: 1 << 4; // channel flag: a post needs a tag

forum_view :: (ch: *dc.Channel) {
	s := store();
	st := find_or_add(*forums, ch.id);
	if app.client != null && !st.requested_archived {
		st.requested_archived = true;
		dc.fetch_archived_forum_threads(app.client, ch.id, 0);
	}
	all := dc.forum_threads(s, ch.id);
	tags := dc.forum_tags(store(), ch.id);
	// the search, tag filter and sort, as shown
	q := to_lower_copy(trim(ui.editor_text(*st.query)),, temp);
	posts: [..]dc.Snowflake;
	posts.allocator = temp;
	for id: all {
		th := dc.channel_get(s, id);
		tm := dc.thread_meta(store(), id);
		if !th continue;
		if q && !contains(to_lower_copy(th.name,, temp), q) continue;
		if st.filter.count {
			hit := false;
			if tm for st.filter if array_find(tm.applied_tags, it) hit = true;
			if !hit continue;
		}
		array_add(*posts, id);
	}
	if st.by_date quick_sort(posts, (a: dc.Snowflake, b: dc.Snowflake) -> s64 { return ifx a > b then -1 else ifx a < b then 1 else 0; });
	// first messages for the cards, 10 at a time like the client
	if app.client != null {
		need: [..]dc.Snowflake;
		need.allocator = temp;
		for id: posts {
			tm := dc.thread_meta(store(), id);
			if tm == null || tm.first_content != "" || table_contains(*st.requested_posts, id) continue;
			table_set(*st.requested_posts, id, true);
			array_add(*need, id);
		}
		if need.count dc.fetch_forum_posts(app.client, ch.id, need);
	}
	can_post := ch.guild_id == 0 || dc.has_permission(dc.channel_permissions(s, ch.id), dc.PERM_SEND_MESSAGES);
	if dc.guild_get(s, ch.guild_id) && !dc.guild_get(s, ch.guild_id).roles.count can_post = true; // roles not known yet

	list := ui.box("forum", .Scroll_Y | .Clip);
	list.semantic_size = .[ui.fill(), ui.pct(1)];
	list.layout_axis = .Y;
	ui.signal(list);
	{ ui.parent(list); defer ui.pop_parent();
		spacer(.Y, 16);
		hdr := row("forumhdr");
		hdr.semantic_size = .[ui.pct(1), ui.px(40)];
		submit := false;
		{ ui.parent(hdr); defer ui.pop_parent();
			spacer(.X, 24);
			sb := row("newpost", .Draw_Background | .Draw_Border | .Clickable);
			sb.semantic_size = .[ui.fill(), ui.px(40)];
			sb.style.bg = T("--background-base-lowest");
			sb.style.border_color = ifx app.ui.focus == sb.key then T("--input-border-active") else T("--border-subtle");
			sb.style.border = 1;
			sb.style.radius = all4(8);
			sb.hover_cursor = .IBeam;
			if ui.signal(sb).pressed app.ui.focus = sb.key;
			{ ui.parent(sb); defer ui.pop_parent();
				spacer(.X, 12);
				icon("s", "magnifying-glass", 16, T("--text-muted"));
				spacer(.X, 8);
				res := text_field("q", *st.query, L("Search or create a post..."), app.ui.focus == sb.key && !st.creating, 14, 18, 11);
				if res == .Submit && can_post submit = true;
				spacer(.X, 12);
			}
			if can_post {
				spacer(.X, 8);
				nb := row("newbtn", .Clickable | .Draw_Background | .Hot_Animation);
				nb.semantic_size = .[ui.children(), ui.px(40)];
				nb.style.radius = all4(8);
				nb.style.bg = T("--background-brand");
				nb.style.bg_hot = with_alpha(T("--background-brand"), 0.85);
				nb.hover_cursor = .Pointer;
				{ ui.parent(nb); defer ui.pop_parent();
					spacer(.X, 12);
					icon("i", "chat-plus", 18, .{1, 1, 1, 1});
					spacer(.X, 6);
					label(L("New Post"), .Medium, 14, .{1, 1, 1, 1}, 18);
					spacer(.X, 12);
				}
				if ui.signal(nb).clicked submit = true;
			}
			spacer(.X, 24);
		}
		if submit && !st.creating {
			st.creating = true;
			ui.editor_set_text(*st.title, trim(ui.editor_text(*st.query)));
			st.focus_body = st.title.buf.count > 0;
			st.focus_title = !st.focus_body;
		}
		if st.creating forum_post_form(ch, st, tags);
		spacer(.Y, 12);
		// sort and the tag filter
		bar := row("bar");
		bar.semantic_size = .[ui.pct(1), ui.px(28)];
		bar.style.child_gap = 6;
		{ ui.parent(bar); defer ui.pop_parent();
			spacer(.X, 24 - 6);
			for t: tags {
				on := array_find(st.filter, t.id);
				if forum_chip(tprint("f%", t.id), t, on) {
					if on array_unordered_remove_by_value(*st.filter, t.id);
					else array_add(*st.filter, t.id);
				}
			}
			filler(.X);
			sort := row("sort", .Clickable | .Draw_Background | .Hot_Animation);
			sort.semantic_size = .[ui.children(), ui.px(28)];
			sort.style.radius = all4(8);
			sort.style.bg_hot = T("--background-mod-subtle");
			sort.hover_cursor = .Pointer;
			{ ui.parent(sort); defer ui.pop_parent();
				spacer(.X, 8);
				label(ifx st.by_date then L("Sort: Date Posted") else L("Sort: Recent Activity"), .Medium, 14, T("--text-default"), 18);
				spacer(.X, 8);
			}
			if ui.signal(sort).clicked st.by_date = !st.by_date;
			spacer(.X, 24 - 6);
		}
		spacer(.Y, 12);
		if !posts.count {
			r := row("empty");
			r.semantic_size = .[ui.pct(1), ui.px(40)];
			{ ui.parent(r); defer ui.pop_parent();
				filler(.X);
				label(ifx all.count then L("No posts match") else L("No posts yet"), .Medium, 14, T("--text-muted"), 18);
				filler(.X);
			}
		}
		if ch.kind == .Guild_Media {
			// the media grid: pictures in columns of at least 220px
			GAP :: 16.0;
			inner := (list.rect.x1 - list.rect.x0) - 48;
			cols := clamp(cast(int) ((inner + GAP) / (220 + GAP)), 1, 6);
			cw := max((inner - (cols - 1) * GAP) / cols, 1);
			for i: 0..(posts.count + cols - 1) / cols - 1 {
				gr := row(tprint("grid%", i));
				gr.semantic_size = .[ui.pct(1), ui.children()];
				gr.cross_align = .Start;
				ui.parent(gr); defer ui.pop_parent();
				spacer(.X, 24);
				for j: 0..cols - 1 {
					k := i * cols + j;
					if k >= posts.count break;
					th := dc.channel_get(s, posts[k]);
					if j spacer(.X, GAP);
					if th == null continue;
					ui.id_scope(cast(u64) th.id);
					media_card(ch, th, cw);
					ui.pop_seed();
				}
			}
		} else for id: posts {
			th := dc.channel_get(s, id);
			if th == null continue;
			ui.id_scope(cast(u64) id);
			forum_card(ch, th, tags);
			ui.pop_seed();
		}
		spacer(.Y, 24);
	}
}

// The new post's reply: open it, and clear the form.
forum_post_created :: (r: *dc.Feature_Result) {
	st := table_find_pointer(*forums, r.channel_id);
	if !st || r.tag != st.tag return;
	st.busy = false;
	app.ui.animating = true;
	if !r.ok {
		free(st.error);
		st.error = copy_string(ifx dc.api_error_message(r.body) then dc.api_error_message(r.body) else L("Something went wrong. Try again."));
		return;
	}
	id := dc.apply_created_thread(app.client, r.body);
	ch := dc.channel_get(store(), id);
	st.creating = false;
	ui.editor_set_text(*st.query, ""); ui.editor_set_text(*st.title, ""); ui.editor_set_text(*st.body, "");
	st.tags.count = 0;
	if ch select_channel(ch.guild_id, id);
}

#scope_file


Forum_State :: struct {
	requested_archived: bool;
	requested_posts: Table(dc.Snowflake, bool);
	query: ui.Editor; // the search box, also the new post's title
	filter: [..]dc.Snowflake; // tags shown (any of them); none: all
	by_date: bool; // Date Posted, else Recent Activity
	creating: bool;
	title, body: ui.Editor;
	tags: [..]dc.Snowflake; // the new post's
	focus_title, focus_body: bool;
	busy: bool;
	tag: u64;
	error: string;
}

forums: Table(dc.Snowflake, Forum_State);

// A tag chip: its emoji and name, filled while on.
forum_chip :: (id: string, t: dc.Forum_Tag, on: bool) -> bool {
	chip := row(id, .Clickable | .Draw_Background | .Draw_Border | .Hot_Animation);
	chip.semantic_size = .[ui.children(), ui.px(28)];
	chip.style.radius = all4(14);
	chip.style.border = 1;
	chip.style.border_color = ifx on then T("--background-brand") else T("--border-subtle");
	chip.style.bg = ifx on then with_alpha(T("--background-brand"), 0.2) else .{};
	chip.style.bg_hot = T("--background-mod-subtle");
	chip.hover_cursor = .Pointer;
	{ ui.parent(chip); defer ui.pop_parent();
		spacer(.X, 10);
		if t.emoji_name { label(t.emoji_name, .Medium, 14, T("--text-default"), 18); spacer(.X, 4); }
		label(t.name, .Medium, 14, ifx on then T("--text-strong") else T("--text-default"), 18);
		spacer(.X, 10);
	}
	return ui.signal(chip).clicked;
}

MAX_POST_TAGS :: 5;

forum_post_form :: (ch: *dc.Channel, st: *Forum_State, tags: []dc.Forum_Tag) {
	spacer(.Y, 12);
	outer := row("postform");
	outer.semantic_size = .[ui.pct(1), ui.children()];
	ui.parent(outer); defer ui.pop_parent();
	spacer(.X, 24);
	card := ui.box("card", .Draw_Background | .Draw_Border);
	card.semantic_size = .[ui.fill(), ui.children()];
	card.layout_axis = .Y;
	card.style.bg = T("--card-background-default");
	card.style.border_color = T("--card-border-default");
	card.style.border = 1;
	card.style.radius = all4(8);
	spacer(.X, 24);
	ui.parent(card); defer ui.pop_parent();
	inset_begin(16, 16);
	defer inset_end(16, 16);
	field :: (id: string, ed: *ui.Editor, placeholder: string, focus: *bool, size: float32) -> ui.Edit_Result {
		b := row(id, .Draw_Background | .Draw_Border | .Clickable);
		b.semantic_size = .[ui.pct(1), ui.children()];
		b.style.bg = T("--input-background-default");
		b.style.border_color = ifx app.ui.focus == b.key then T("--input-border-active") else T("--input-border-default");
		b.style.border = 1;
		b.style.radius = all4(8);
		b.hover_cursor = .IBeam;
		if ui.signal(b).pressed || focus.* app.ui.focus = b.key;
		focus.* = false;
		ui.parent(b); defer ui.pop_parent();
		spacer(.X, 12);
		res := text_field("f", ed, placeholder, app.ui.focus == b.key, size, size + 4, 9);
		spacer(.X, 12);
		return res;
	}
	r1 := field("title", *st.title, L("Post title"), *st.focus_title, 16);
	t := ui.editor_text(*st.title);
	cut := cut_runes(t, 100);
	if cut.count < t.count ui.editor_set_text(*st.title, copy_string(cut,, temp));
	if tags.count {
		spacer(.Y, 12);
		need := (ch.flags & FORUM_REQUIRE_TAG) != 0;
		label(ifx need then L("Tags (pick at least one)") else L("Tags"), .Semibold, 12, T("--text-muted"), 16);
		spacer(.Y, 6);
		tr := row("tags");
		tr.semantic_size = .[ui.pct(1), ui.px(28)];
		tr.style.child_gap = 6;
		ui.parent(tr); defer ui.pop_parent();
		for tg: tags {
			on := array_find(st.tags, tg.id);
			if forum_chip(tprint("t%", tg.id), tg, on) {
				if on array_unordered_remove_by_value(*st.tags, tg.id);
				else if st.tags.count < MAX_POST_TAGS array_add(*st.tags, tg.id);
			}
		}
	}
	spacer(.Y, 12);
	r2 := field("body", *st.body, L("Enter a message to start the conversation!"), *st.focus_body, 16);
	if (r1 == .Changed || r2 == .Changed) && app.client != null && net_action() dc.typing_keystroke(app.client, ch.id);
	if st.error {
		spacer(.Y, 8);
		label(st.error, .Normal, 14, T("--text-feedback-critical"), 18);
	}
	spacer(.Y, 12);
	title := trim(ui.editor_text(*st.title));
	body := trim(ui.editor_text(*st.body));
	ok := title != "" && body != "" && !st.busy && (!(ch.flags & FORUM_REQUIRE_TAG) || st.tags.count > 0 || !tags.count);
	btns := row("btns");
	btns.semantic_size = .[ui.pct(1), ui.px(36)];
	btns.style.child_gap = 8;
	ui.parent(btns); defer ui.pop_parent();
	filler(.X);
	cancel := row("cancel", .Clickable | .Draw_Background | .Hot_Animation);
	cancel.semantic_size = .[ui.children(), ui.px(36)];
	cancel.style.radius = all4(8);
	cancel.style.bg_hot = T("--background-mod-subtle");
	{ ui.parent(cancel); defer ui.pop_parent(); spacer(.X, 12); label(L("Cancel"), .Medium, 14, T("--text-default"), 18); spacer(.X, 12); }
	if ui.signal(cancel).clicked st.creating = false; // what was typed stays for the next New Post
	go := row("post", ifx ok then .Clickable | .Draw_Background | .Hot_Animation else .Draw_Background);
	go.semantic_size = .[ui.children(), ui.px(36)];
	go.style.radius = all4(8);
	go.style.bg = ifx ok then T("--background-brand") else with_alpha(T("--background-brand"), 0.5);
	go.style.bg_hot = with_alpha(T("--background-brand"), 0.85);
	{ ui.parent(go); defer ui.pop_parent(); spacer(.X, 16); label(ifx st.busy then L("Posting...") else L("Post"), .Medium, 14, .{1, 1, 1, 1}, 18); spacer(.X, 16); }
	if ok && (ui.signal(go).clicked || r1 == .Submit || r2 == .Submit) && net_action() {
		st.busy = true;
		st.tag = FORUM_POST_TAG | (st.tag + 1);
		free(st.error);
		st.error = "";
		dc.create_forum_post(app.client, ch.id, title, mentions_convert(emoji_convert_shortcodes(body, ch.id), ch), st.tags, st.tag);
	}
}

// A media channel post: its first picture (cropped square, a placeholder without one) and its title.
media_card :: (forum: *dc.Channel, th: *dc.Channel, w: float32) {
	tm := dc.thread_meta(store(), th.id);
	card := ui.box("mcard", .Clickable | .Draw_Background | .Hot_Animation);
	card.semantic_size = .[ui.px(w), ui.children()];
	card.layout_axis = .Y;
	card.style.radius = all4(8);
	card.style.bg_hot = T("--background-mod-subtle");
	if ui.signal(card).clicked select_channel(forum.guild_id, th.id);
	ui.parent(card); defer ui.pop_parent();
	pic := ui.box("pic", .Draw_Background | .Clip);
	pic.semantic_size = .[ui.px(w), ui.px(w)];
	pic.style.radius = all4(8);
	pic.style.bg = T("--background-mod-normal");
	if tm && tm.first_media set_remote_image(pic, tm.first_media, cover = true);
	else { ui.parent(pic); defer ui.pop_parent(); ic := icon("i", "image", 40, T("--text-muted"), .Floating_X | .Floating_Y); ic.fixed_pos = .{(w - 40) / 2, (w - 40) / 2}; }
	spacer(.Y, 8);
	label(ellipsize(th.name, .Semibold, 16, w - 8), .Semibold, 16, T("--text-strong"), 20);
	spacer(.Y, 4);
	mr := row("meta");
	mr.semantic_size = .[ui.pct(1), ui.px(18)];
	{ ui.parent(mr); defer ui.pop_parent();
		icon("ic", "chat", 16, T("--text-muted"));
		spacer(.X, 4);
		label(tprint("%", ifx tm then tm.message_count else 0), .Medium, 14, T("--text-muted"), 18);
		spacer(.X, 8);
		label(relative_age(ifx tm && tm.last_message_id > th.id then tm.last_message_id else th.id), .Normal, 14, T("--text-muted"), 18);
	}
	spacer(.Y, 16);
}

forum_card :: (forum: *dc.Channel, th: *dc.Channel, tags: []dc.Forum_Tag) {
	tm := dc.thread_meta(store(), th.id);
	outer := row("cardrow");
	outer.semantic_size = .[ui.pct(1), ui.children()];
	{ ui.parent(outer); defer ui.pop_parent();
		spacer(.X, 24);
		card := ui.box("card", .Clickable | .Draw_Background | .Draw_Border | .Hot_Animation);
		card.semantic_size = .[ui.fill(), ui.children()];
		card.layout_axis = .Y;
		card.style.bg = T("--card-background-default");
		card.style.bg_hot = T("--background-mod-subtle");
		card.style.border_color = T("--card-border-default");
		card.style.border = 1;
		card.style.radius = all4(8);
		if ui.signal(card).clicked select_channel(forum.guild_id, th.id);
		{ ui.parent(card); defer ui.pop_parent();
			inset_begin(16, 12);
			defer inset_end(16, 12);
			// tags
			if tm != null && tm.applied_tags.count {
				tr := row("tags");
				tr.semantic_size = .[ui.pct(1), ui.px(22)];
				tr.style.child_gap = 4;
				{ ui.parent(tr); defer ui.pop_parent();
					for tid, i: tm.applied_tags {
						for t: tags {
							if t.id != tid continue;
							chip := row(tprint("tag%", i), .Draw_Background);
							chip.semantic_size = .[ui.children(), ui.px(20)];
							chip.style.bg = T("--background-mod-normal");
							chip.style.radius = all4(10);
							{ ui.parent(chip); defer ui.pop_parent();
								spacer(.X, 8);
								if t.emoji_name != "" {
									label(t.emoji_name, .Medium, 12, T("--text-default"), 16);
									spacer(.X, 4);
								}
								label(t.name, .Medium, 12, T("--text-default"), 16);
								spacer(.X, 8);
							}
						}
					}
				}
				spacer(.Y, 6);
			}
			label(th.name, .Semibold, 16, T("--text-strong"), 20);
			spacer(.Y, 4);
			if tm != null && tm.first_content != "" {
				pr := row("preview");
				pr.semantic_size = .[ui.pct(1), ui.px(18)];
				{ ui.parent(pr); defer ui.pop_parent();
					name := name_in(tm.first_author, th.id, "");
					if name != "" {
						label(tprint("%:", name), .Medium, 14, T("--text-default"), 18);
						spacer(.X, 4);
					}
					t := label(ellipsize(first_line(tm.first_content), .Normal, 14, 600), .Normal, 14, T("--text-muted"), 18);
					t.flags |= .Clip;
				}
				spacer(.Y, 6);
			}
			mr := row("meta");
			mr.semantic_size = .[ui.pct(1), ui.px(18)];
			{ ui.parent(mr); defer ui.pop_parent();
				icon("ic", "chat", 16, T("--text-muted"));
				spacer(.X, 4);
				n := ifx tm != null then tm.message_count else 0;
				label(tprint("%", n), .Medium, 14, T("--text-muted"), 18);
				spacer(.X, 8);
				last := ifx th.last_message_id != 0 then th.last_message_id else th.id;
				if tm != null && tm.last_message_id > last last = tm.last_message_id;
				label(relative_age(last), .Normal, 14, T("--text-muted"), 18);
				if tm != null && tm.archived {
					spacer(.X, 8);
					icon("arch", "lock", 14, T("--text-muted"));
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
	if dt < 60 return L("just now");
	if dt < 3600 return tprint(L("%m ago"), dt / 60);
	if dt < 86400 return tprint(L("%h ago"), dt / 3600);
	if dt < 86400 * 30 return tprint(L("%d ago"), dt / 86400);
	return tprint(L("%mo ago"), dt / (86400 * 30));
}

// Header prefix for threads: "parent ›" before the thread name.
thread_header_prefix :: (ch: *dc.Channel) {
	if !dc.is_thread(ch) return;
	p := dc.channel_get(store(), ch.parent_id);
	if p == null return;
	b := row("parent", .Clickable);
	b.semantic_size = .[ui.children(), ui.px(24)];
	sig := ui.signal(b);
	if sig.clicked select_channel(p.guild_id, p.id);
	{ ui.parent(b); defer ui.pop_parent();
		icon("pi", channel_icon_name(p), 20, T("--channel-icon"));
		spacer(.X, 6);
		label(p.name, .Semibold, 16, ifx sig.hovering then T("--text-strong") else T("--text-muted"), 20);
		spacer(.X, 4);
		icon("chev", "chevron-small-right", 16, T("--text-muted"));
		spacer(.X, 4);
	}
}

// ---- feature results (pins, search, forum, jumps) ----

// Every connection's, with app.client pointing at the one they came on (as handle_results does), so an
// unselected server's replies, such as its Recent Mentions, are taken too.
features_receive :: () {
	keep := app.client;
	for c: connections() {
		app.client = c;
		features_receive_of(c);
		if app.client != c keep = app.client;
	}
	app.client = keep;
}

features_receive_of :: (c: *dc.Client) {
	for * r: dc.feature_take(c) {
		defer dc.feature_result_free(r);
		if dc.mfa_required(r) && mfa_open(r) continue; // asks for a code first (view_settings_account.jai)
		feature_route(r);
	}
}

// feature_route hands a finished feature request to the view that sent it.
feature_route :: (r: *dc.Feature_Result) {
	if r.op == {
	case .Forum_Posts; #through; case .Thread_Search;
		if r.ok dc.apply_forum_threads(app.client, r.body);
		app.ui.animating = true;
	case .Pins;
		pins_receive(r);
	case .Pins_Ack; #through; case .Mark_Unread;
	case .Pin;
		if !r.ok show_notice(L("Error"), L("An error occurred, please try again."));
	case .Reactors;
		reactors_receive(r); // view_chat.jai
	case .Unpin;
		if !r.ok show_notice(L("The Pin Is Stuck!"), L("Discord failed to unpin that message for some reason. Sorry about that."));
	case .Around;
		dc.apply_around(app.client, r);
		app.ui.animating = true;
	case .Search;
		search_receive(r);
	case .Thread_Browse; #through; case .Thread_Create;
		threads_browser_receive(r);
	case .Mentions; #through; case .Mention_Delete;
		inbox_receive(r);
	case .User_Patch; #through; case .Profile_Patch; #through; case .Banner_Edit;
		account_receive(r); // view_settings_account.jai
	case .Event_Create; #through; case .Event_Edit; #through; case .Event_Counts; #through; case .Event_Rsvps; #through; case .Event_Interest; #through; case .Event_Invite; #through; case .Event_Delete; #through; case .Event_Start;
		events_receive(r); // view_events.jai (dc.guild_admin_apply first)
	case .Guild_Aux; #through; case .Channel_Order; #through; case .Channel_Create; #through; case .Channel_Edit; #through; case .Channel_Delete; #through; case .Avatar_Edit; #through; case .Emoji_Upload;
		guild_admin_receive(r);
	case .Sound_Upload; #through; case .Sound_Edit; #through; case .Sound_Delete;
		sound_settings_receive(r); // view_server_soundboard.jai
	case .Guild_Edit; #through; case .Sticker_Upload; #through; case .Guild_Settings;
		if app.client != null dc.guild_admin_apply(app.client, r);
		server_settings_receive(r); // view_server_settings.jai
	case .User_Settings;
		user_settings_receive(r); // view_settings_user.jai
	case .Mfa_Finish;
		mfa_receive(r); // view_settings_account.jai
	case .E2E_Bundle;
		encrypted_bundle_receive(r); // encrypted.jai
	case .Member_Verify;
		rules_receive(r); // view_invites.jai
	case .Onboarding;
		onboarding_receive(r); // view_onboarding.jai
	}
}

// Container padding (ui's style.padding only pads text): call inside a Y box;
// returns the inner column. Close with inset_end.
inset_begin :: (px: float32, py: float32) -> *ui.Box {
	spacer(.Y, py);
	r := row("inset");
	r.semantic_size = .[ui.pct(1), ui.children()];
	ui.push_parent(r);
	spacer(.X, px);
	inner := ui.box("inner");
	inner.semantic_size = .[ui.fill(), ui.children()];
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

forums_reset_for_test :: () { forums = .{}; }

