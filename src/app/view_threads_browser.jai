// Threads browser (channel header "Threads" icon), like the client's popout
// (fixture threads_browser): anchored under the icon, tabs Active / Archived
// and a "Create" button. Active lists joined threads, then other active
// threads; Archived lists threads fetched 25 at a time with
// GET /channels/{id}/threads/search?archived=true&... (dc.fetch_channel_threads,
// on the first open per channel). Newest activity first. Clicking a row opens
// the thread like the sidebar's thread rows.
// "Create" (science thread_creation_started) shows the thread form: name
// ("New Thread") and the first message; typing there is typing in the parent
// channel; Enter creates it (POST /channels/{id}/threads), then the thread
// opens and the first message is sent with location "thread_creation".
// The official client opens the new thread in a side view next to the parent
// (route /channels/{guild}/{parent}/threads/{thread}); fastcord opens it as the
// main view (route /channels/{guild}/{thread}).

threads_browser_toggle :: (channel_id: dc.Snowflake, anchor: ui.Rect) {
	if tb.open && tb.channel == channel_id {
		tb.open = false;
		return;
	}
	if tb.channel != channel_id {
		tb.channel = channel_id;
		tb.requested, tb.loading, tb.has_more, tb.offset = false, false, false, 0;
	}
	tb.open = true;
	tb.anchor = anchor;
	tb.tab = .Active;
	tb.creating = false;
	if app.client != null dc.track_thread_browser_open(app.client, channel_id);
	if !tb.requested {
		tb.requested = true;
		if net_action() {
			tb.loading = true;
			dc.fetch_channel_threads(app.client, channel_id, 0);
		}
	}
}

// Public threads need CREATE_PUBLIC_THREADS and SEND_MESSAGES in the parent.
can_create_thread :: (channel_id: dc.Snowflake) -> bool {
	perms := dc.channel_permissions(store(), channel_id);
	return (perms & dc.PERM_CREATE_PUBLIC_THREADS) != 0 && (perms & dc.PERM_SEND_MESSAGES) != 0;
}

// The composer "+" menu's Create Thread: the browser's create form, under the header's Threads icon.
threads_browser_create :: (channel_id: dc.Snowflake) {
	if !tb.open || tb.channel != channel_id threads_browser_toggle(channel_id, header_thread_rect);
	create_form_open("Plus Button");
}

// The message menu's Create Thread: the browser's create form, named after the message's first line.
thread_from_message :: (m: *dc.Message, anchor: ui.Rect) {
	if tb.channel != m.channel_id {
		tb.channel = m.channel_id;
		tb.requested, tb.loading, tb.has_more, tb.offset = false, false, false, 0;
	}
	tb.open = true;
	tb.anchor = anchor;
	tb.tab = .Active;
	create_form_open("Message");
	tb.from_msg = m.id;
	name := m.content;
	nl := find_index_from_left(name, #char "\n");
	if nl >= 0 name.count = nl;
	if name.count > 40 {
		name.count = 40;
		while name.count > 0 && (name[name.count] & 0xC0) == 0x80 name.count -= 1;
	}
	ui.editor_set_text(*tb.name, name);
}

threads_browser_receive :: (r: *dc.Feature_Result) {
	if r.op == .Thread_Create {
		thread_created(r);
		return;
	}
	if r.channel_id != tb.channel return;
	tb.loading = false;
	if !r.ok return;
	dc.apply_forum_threads(app.client, r.body);
	body := dc.vmap(r.body);
	tb.offset += dc.flist(body, "threads").count;
	tb.has_more = dc.fbool(body, "has_more");
	app.ui.animating = true;
}

threads_browser_popout :: () {
	if !tb.open return;
	if tb.channel != app.view.channel {
		tb.open = false;
		return;
	}
	scrim := ui.box("threads_scrim", .Clickable | .Floating_X | .Floating_Y | .Overlay);
	scrim.semantic_size = .[ui.px(app.ui.window.x), ui.px(app.ui.window.y)];
	if ui.signal(scrim).clicked {
		tb.open = false;
		return;
	}
	for * e: app.ui.events {
		if !e.consumed && e.kind == .Key_Down && e.key == .Escape {
			if tb.creating tb.creating = false;
			else tb.open = false;
			e.consumed = true;
			if !tb.open return;
		}
	}
	s := store();
	ids := dc.channel_threads(s, tb.channel);
	joined, active, older: [..]dc.Snowflake;
	joined.allocator, active.allocator, older.allocator = temp, temp, temp;
	for id: ids {
		tm := dc.thread_meta(id);
		if tm == null continue;
		array_add(ifx tm.archived then *older else ifx tm.joined then *joined else *active, id);
	}

	x := clamp(tb.anchor.x1 - THREADS_W, 8, app.ui.window.x - THREADS_W - 8);
	y := tb.anchor.y1 + 8;
	max_h := min(app.ui.window.y * 0.7, app.ui.window.y - y - 16);
	p := ui.box("threadspop", .Draw_Background | .Draw_Border | .Draw_Shadow | .Floating_X | .Floating_Y | .Overlay | .Clickable | .Clip);
	p.semantic_size = .[ui.px(THREADS_W), ui.px(max_h)];
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
	ui.push_parent(p);
	defer ui.pop_parent();
	hdr := row("hdr");
	hdr.semantic_size = .[ui.pct(1), ui.px(48)];
	{ ui.parent(hdr); defer ui.pop_parent();
		spacer(.X, 16);
		icon("i", "thread", 20, T("--interactive-icon-default"));
		spacer(.X, 8);
		label("Threads", .Semibold, 16, T("--text-strong"), 20);
		if !tb.creating {
			spacer(.X, 12);
			for t: enum_values_as_enum(TB_Tab) {
				name := ifx t == .Active then "Active" else "Archived";
				sel := tb.tab == t;
				tab := row(name, .Clickable | .Draw_Background | .Hot_Animation);
				tab.semantic_size = .[ui.children(), ui.px(28)];
				tab.style.radius = all4(4);
				tab.style.bg = ifx sel then T("--background-mod-normal") else .{};
				tab.style.bg_hot = ifx sel then tab.style.bg else T("--background-mod-subtle");
				tsig := ui.signal(tab);
				{ ui.parent(tab); defer ui.pop_parent();
					spacer(.X, 8);
					label(name, .Medium, 14, ifx sel || tsig.hovering then T("--text-strong") else T("--text-muted"), 18);
					spacer(.X, 8);
				}
				if tsig.clicked && !sel {
					tb.tab = t;
					if app.client != null dc.track_thread_browser_tab_changed(app.client, tb.channel);
				}
				spacer(.X, 4);
			}
		}
		filler(.X);
		if !tb.creating && can_create_thread(tb.channel) {
			cb := row("create", .Clickable | .Draw_Background | .Hot_Animation);
			cb.semantic_size = .[ui.children(), ui.px(32)];
			cb.style.radius = all4(8);
			cb.style.bg = T("--background-brand");
			cb.style.bg_hot = with_alpha(T("--background-brand"), 0.85);
			csig := ui.signal(cb);
			{ ui.parent(cb); defer ui.pop_parent();
				spacer(.X, 12);
				label("Create", .Medium, 14, .{1, 1, 1, 1}, 18);
				spacer(.X, 12);
			}
			if csig.clicked create_form_open();
		}
		spacer(.X, 12);
	}
	line := ui.box("hl", .Draw_Background);
	line.semantic_size = .[ui.pct(1), ui.px(1)];
	line.style.bg = T("--border-subtle");
	if tb.creating {
		create_form();
		return;
	}
	list := ui.box("list", .Scroll_Y | .Clip);
	list.semantic_size = .[ui.pct(1), ui.fill()];
	list.layout_axis = .Y;
	sig := ui.signal(list);
	{ ui.parent(list); defer ui.pop_parent();
		spacer(.Y, 8);
		empty := ifx tb.tab == .Active then joined.count + active.count == 0 else older.count == 0;
		if empty {
			r := row("empty");
			r.semantic_size = .[ui.pct(1), ui.px(80)];
			{ ui.parent(r); defer ui.pop_parent();
				filler(.X);
				msg := ifx tb.tab == .Active then "There are no active threads." else "There are no archived threads.";
				label(ifx tb.loading && tb.tab == .Archived then "Loading..." else msg, .Medium, 14, T("--text-muted"), 18);
				filler(.X);
			}
		}
		if tb.tab == .Active {
			thread_section("joined", "Joined Threads", joined);
			thread_section("active", "Other Active Threads", active);
		} else {
			thread_section("older", "Archived Threads", older);
		}
		spacer(.Y, 8);
	}
	// more archived threads near the end
	if tb.tab == .Archived && tb.has_more && !tb.loading && app.client != null && sig.hovering
		&& list.content_size.y > 0 && list.view_off.y + (list.rect.y1 - list.rect.y0) > list.content_size.y - 200 {
		tb.loading = true;
		dc.fetch_channel_threads(app.client, tb.channel, tb.offset);
	}
}

threads_browser_reset_for_test :: () {
	ui.editor_destroy(*tb.name);
	ui.editor_destroy(*tb.first);
	free(tb.pending);
	tb = .{};
}


#scope_file

THREADS_W :: 480;

TB_Tab :: enum u8 {
	Active;
	Archived;
}

Threads_Browser :: struct {
	open: bool;
	channel: dc.Snowflake;
	anchor: ui.Rect;
	requested: bool; // archived threads asked for (this channel)
	loading: bool;
	has_more: bool;
	offset: int;
	tab: TB_Tab;
	// Create form
	creating: bool;
	name: ui.Editor;
	first: ui.Editor;
	focus: int; // 1 name, 2 message: focus that field on the next frame
	busy: bool;
	tag: u64;
	pending: string; // heap: first message of the thread being created
	from_msg: dc.Snowflake; // the message the thread starts from (message menu), or 0
}

tb: Threads_Browser;

create_form_open :: (location := "Thread Browser Toolbar") {
	tb.creating = true;
	tb.from_msg = 0;
	tb.busy = false;
	ui.editor_set_text(*tb.name, "");
	ui.editor_set_text(*tb.first, "");
	tb.focus = 1;
	if app.client != null dc.track_thread_creation_started(app.client, tb.channel, location);
}

create_form :: () {
	spacer(.Y, 16);
	field :: (id: string, ed: *ui.Editor, placeholder: string, want_focus: bool) -> ui.Edit_Result {
		res := ui.Edit_Result.None;
		r := row(tprint("%_row", id));
		r.semantic_size = .[ui.pct(1), ui.children()];
		{ ui.parent(r); defer ui.pop_parent();
			spacer(.X, 16);
			box := row(id, .Draw_Background | .Draw_Border | .Clickable);
			box.semantic_size = .[ui.fill(), ui.children()];
			box.style.bg = T("--input-background-default");
			box.style.border_color = ifx app.ui.focus == box.key then T("--input-border-active") else T("--input-border-default");
			box.style.border = 1;
			box.style.radius = all4(8);
			box.hover_cursor = .IBeam;
			if ui.signal(box).pressed || want_focus app.ui.focus = box.key;
			{ ui.parent(box); defer ui.pop_parent();
				spacer(.X, 12);
				res = text_field("f", ed, placeholder, app.ui.focus == box.key, 16, 20, 9);
				spacer(.X, 12);
			}
			spacer(.X, 16);
		}
		return res;
	}
	sub := row("namelbl");
	sub.semantic_size = .[ui.pct(1), ui.px(20)];
	{ ui.parent(sub); defer ui.pop_parent();
		spacer(.X, 16);
		label("THREAD NAME", .Bold, 12, T("--text-muted"), 16);
	}
	spacer(.Y, 6);
	r1 := field("name", *tb.name, "New Thread", tb.focus == 1);
	spacer(.Y, 12);
	r2 := field("first", *tb.first, "Enter a message to start the conversation!", tb.focus == 2);
	tb.focus = 0;
	// typing in the form is typing in the parent channel
	if (r1 == .Changed || r2 == .Changed) && app.client != null && net_action() dc.typing_keystroke(app.client, tb.channel);
	submit := r1 == .Submit || r2 == .Submit;
	spacer(.Y, 16);
	btns := row("btns");
	btns.semantic_size = .[ui.pct(1), ui.px(36)];
	btns.style.child_gap = 8;
	{ ui.parent(btns); defer ui.pop_parent();
		filler(.X);
		cancel := row("cancel", .Clickable | .Draw_Background | .Hot_Animation);
		cancel.semantic_size = .[ui.children(), ui.px(32)];
		cancel.style.radius = all4(8);
		cancel.style.bg_hot = T("--background-mod-subtle");
		{ ui.parent(cancel); defer ui.pop_parent();
			spacer(.X, 12);
			label("Cancel", .Medium, 14, T("--text-default"), 18);
			spacer(.X, 12);
		}
		if ui.signal(cancel).clicked tb.creating = false;
		name := trim(ui.editor_text(*tb.name));
		ok := name != "" && !tb.busy;
		go := row("go", ifx ok then .Clickable | .Draw_Background | .Hot_Animation else .Draw_Background);
		go.semantic_size = .[ui.children(), ui.px(32)];
		go.style.radius = all4(8);
		go.style.bg = ifx ok then T("--background-brand") else with_alpha(T("--background-brand"), 0.5);
		go.style.bg_hot = with_alpha(T("--background-brand"), 0.85);
		{ ui.parent(go); defer ui.pop_parent();
			spacer(.X, 12);
			label(ifx tb.busy then "Creating..." else "Create Thread", .Medium, 14, .{1, 1, 1, 1}, 18);
			spacer(.X, 12);
		}
		if ok && ui.signal(go).clicked submit = true;
		spacer(.X, 16);
	}
	if !submit || tb.busy return;
	name := trim(ui.editor_text(*tb.name));
	if name == "" {
		tb.focus = 1;
		return;
	}
	if !net_action() return;
	tb.busy = true;
	tb.tag += 1;
	free(tb.pending);
	tb.pending = copy_string(trim(ui.editor_text(*tb.first)));
	dc.create_thread(app.client, tb.channel, name, location = ifx tb.from_msg then "Message" else "Thread Browser Toolbar", tag = tb.tag, message_id = tb.from_msg);
}

// The thread exists (201): open it and send the first message.
thread_created :: (r: *dc.Feature_Result) {
	if r.tag != tb.tag return;
	tb.busy = false;
	app.ui.animating = true;
	if !r.ok return;
	id := dc.apply_created_thread(app.client, r.body);
	ch := dc.channel_get(store(), id);
	if ch == null return;
	tb.creating = false;
	tb.open = false;
	select_channel(ch.guild_id, id);
	if tb.pending != "" dc.send_message(app.client, id, tb.pending, .{location = "thread_creation"});
	free(tb.pending);
	tb.pending = "";
}

thread_section :: (id: string, title: string, ids: []dc.Snowflake) {
	if !ids.count return;
	sec := ui.box(id);
	sec.semantic_size = .[ui.pct(1), ui.children()];
	sec.layout_axis = .Y;
	ui.push_parent(sec);
	defer ui.pop_parent();
	h := row("title");
	h.semantic_size = .[ui.pct(1), ui.px(28)];
	{ ui.parent(h); defer ui.pop_parent();
		spacer(.X, 16);
		label(tprint("% — %", title, ids.count), .Semibold, 12, T("--text-muted"), 16);
	}
	for ids {
		ui.id_scope(cast(u64) it);
		thread_browser_row(it);
		ui.pop_seed();
	}
	spacer(.Y, 8);
}

thread_browser_row :: (tid: dc.Snowflake) {
	s := store();
	th := dc.channel_get(s, tid);
	tm := dc.thread_meta(tid);
	if th == null || tm == null return;
	outer := row("tr");
	outer.semantic_size = .[ui.pct(1), ui.px(56)];
	ui.push_parent(outer);
	defer ui.pop_parent();
	spacer(.X, 8);
	item := row("item", .Clickable | .Draw_Background | .Hot_Animation);
	item.semantic_size = .[ui.fill(), ui.px(52)];
	item.style.radius = all4(8);
	item.style.bg = T("--background-base-lower");
	item.style.bg_hot = T("--background-mod-subtle");
	sig := ui.signal(item);
	{ ui.parent(item); defer ui.pop_parent();
		spacer(.X, 12);
		col := ui.box("col");
		col.semantic_size = .[ui.fill(), ui.children()];
		col.layout_axis = .Y;
		{ ui.parent(col); defer ui.pop_parent();
			nr := row("name");
			nr.semantic_size = .[ui.pct(1), ui.px(20)];
			{ ui.parent(nr); defer ui.pop_parent();
				if tm.locked || th.kind == .Private_Thread {
					icon("lock", "thread-lock", 16, T("--text-muted"));
					spacer(.X, 4);
				}
				unread := dc.channel_unread(s, tid);
				label(ellipsize(th.name, .Semibold, 15, THREADS_W - 60), .Semibold, 15, ifx unread then T("--text-strong") else T("--text-default"), 20);
			}
			mr := row("meta");
			mr.semantic_size = .[ui.pct(1), ui.px(18)];
			{ ui.parent(mr); defer ui.pop_parent();
				if tm.owner_id != 0 {
					avatar_box("av", tm.owner_id, 16);
					spacer(.X, 6);
					if dc.user_get(s, tm.owner_id) != null {
						label(ellipsize(name_in(tm.owner_id, tid), .Medium, 13, 160), .Medium, 13, T("--text-muted"), 18);
						spacer(.X, 6);
					}
				}
				n := tm.message_count;
				label(ifx n == 1 then "1 Message" else tprint("% Messages", n), .Medium, 13, T("--text-link"), 18);
				spacer(.X, 6);
				label(tprint("· %", relative_age(max(tm.last_message_id, tid))), .Normal, 13, T("--text-muted"), 18);
			}
		}
		spacer(.X, 12);
	}
	spacer(.X, 8);
	if sig.clicked {
		select_channel(th.guild_id, tid, "Thread Browser");
		tb.open = false;
	}
}
