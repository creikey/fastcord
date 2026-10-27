package app

import "core:fmt"
import "core:strings"
import dc "fc:discord"
import "fc:ui"

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

@(private = "file")
TB_Tab :: enum u8 {
	Active,
	Archived,
}

@(private = "file")
Threads_Browser :: struct {
	open:      bool,
	channel:   dc.Snowflake,
	anchor:    ui.Rect,
	requested: bool, // archived threads asked for (this channel)
	loading:   bool,
	has_more:  bool,
	offset:    int,
	tab:       TB_Tab,
	// Create form
	creating:  bool,
	name:      ui.Editor,
	first:     ui.Editor,
	focus:     int, // 1 name, 2 message: focus that field on the next frame
	busy:      bool,
	tag:       u64,
	pending:   string, // heap: first message of the thread being created
}

@(private = "file")
tb: Threads_Browser

THREADS_W :: 480

threads_browser_toggle :: proc(channel_id: dc.Snowflake, anchor: ui.Rect) {
	if tb.open && tb.channel == channel_id {
		tb.open = false
		return
	}
	if tb.channel != channel_id {
		tb.channel = channel_id
		tb.requested, tb.loading, tb.has_more, tb.offset = false, false, false, 0
	}
	tb.open = true
	tb.anchor = anchor
	tb.tab = .Active
	tb.creating = false
	if app.client != nil do dc.track_thread_browser_open(app.client, channel_id)
	if !tb.requested {
		tb.requested = true
		if net_action() {
			tb.loading = true
			dc.fetch_channel_threads(app.client, channel_id, 0)
		}
	}
}

threads_browser_receive :: proc(r: ^dc.Feature_Result) {
	if r.op == .Thread_Create {
		thread_created(r)
		return
	}
	if r.channel_id != tb.channel do return
	tb.loading = false
	if !r.ok do return
	dc.apply_forum_threads(app.client, r.body)
	body := dc.vmap(r.body)
	tb.offset += len(dc.flist(body, "threads"))
	tb.has_more = dc.fbool(body, "has_more")
	app.ui.animating = true
}

threads_browser_popout :: proc() {
	if !tb.open do return
	if tb.channel != app.view.channel {
		tb.open = false
		return
	}
	scrim := ui.box("threads_scrim", {.Clickable, .Floating_X, .Floating_Y, .Overlay})
	scrim.semantic_size = {.X = ui.px(app.ui.window.x), .Y = ui.px(app.ui.window.y)}
	if ui.signal(scrim).clicked {
		tb.open = false
		return
	}
	for &e in app.ui.events {
		if !e.consumed && e.kind == .Key_Down && e.key == .Escape {
			if tb.creating do tb.creating = false
			else do tb.open = false
			e.consumed = true
			if !tb.open do return
		}
	}
	s := store()
	ids := dc.channel_threads(s, tb.channel)
	joined := make([dynamic]dc.Snowflake, context.temp_allocator)
	active := make([dynamic]dc.Snowflake, context.temp_allocator)
	older := make([dynamic]dc.Snowflake, context.temp_allocator)
	for id in ids {
		tm := dc.thread_meta(id)
		switch {
		case tm == nil:
		case tm.archived:
			append(&older, id)
		case tm.joined:
			append(&joined, id)
		case:
			append(&active, id)
		}
	}

	x := clamp(tb.anchor.x1 - THREADS_W, 8, app.ui.window.x - THREADS_W - 8)
	y := tb.anchor.y1 + 8
	max_h := min(app.ui.window.y * 0.7, app.ui.window.y - y - 16)
	p := ui.box("threadspop", {.Draw_Background, .Draw_Border, .Draw_Shadow, .Floating_X, .Floating_Y, .Overlay, .Clickable, .Clip})
	p.semantic_size = {.X = ui.px(THREADS_W), .Y = ui.px(max_h)}
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
	ui.push_parent(p)
	defer ui.pop_parent()
	hdr := row("hdr")
	hdr.semantic_size = {.X = ui.pct(1), .Y = ui.px(48)}
	if ui.parent(hdr) {
		spacer(.X, 16)
		icon("i", "thread", 20, T("--interactive-icon-default"))
		spacer(.X, 8)
		label("Threads", .Semibold, 16, T("--text-strong"), 20)
		if !tb.creating {
			spacer(.X, 12)
			for t in TB_Tab {
				name := t == .Active ? "Active" : "Archived"
				sel := tb.tab == t
				tab := row(name, {.Clickable, .Draw_Background, .Hot_Animation})
				tab.semantic_size = {.X = ui.children(), .Y = ui.px(28)}
				tab.style.radius = 4
				tab.style.bg = sel ? T("--background-mod-normal") : {}
				tab.style.bg_hot = sel ? tab.style.bg : T("--background-mod-subtle")
				tsig := ui.signal(tab)
				if ui.parent(tab) {
					spacer(.X, 8)
					label(name, .Medium, 14, sel || tsig.hovering ? T("--text-strong") : T("--text-muted"), 18)
					spacer(.X, 8)
				}
				if tsig.clicked && !sel {
					tb.tab = t
					if app.client != nil do dc.track_thread_browser_tab_changed(app.client, tb.channel)
				}
				spacer(.X, 4)
			}
		}
		filler(.X)
		if !tb.creating && can_create_thread(tb.channel) {
			cb := row("create", {.Clickable, .Draw_Background, .Hot_Animation})
			cb.semantic_size = {.X = ui.children(), .Y = ui.px(32)}
			cb.style.radius = 8
			cb.style.bg = T("--background-brand")
			cb.style.bg_hot = with_alpha(T("--background-brand"), 0.85)
			csig := ui.signal(cb)
			if ui.parent(cb) {
				spacer(.X, 12)
				label("Create", .Medium, 14, {1, 1, 1, 1}, 18)
				spacer(.X, 12)
			}
			if csig.clicked do create_form_open()
		}
		spacer(.X, 12)
	}
	line := ui.box("hl", {.Draw_Background})
	line.semantic_size = {.X = ui.pct(1), .Y = ui.px(1)}
	line.style.bg = T("--border-subtle")
	if tb.creating {
		create_form()
		return
	}
	list := ui.box("list", {.Scroll_Y, .Clip})
	list.semantic_size = {.X = ui.pct(1), .Y = ui.fill()}
	list.layout_axis = .Y
	sig := ui.signal(list)
	if ui.parent(list) {
		spacer(.Y, 8)
		empty := tb.tab == .Active ? len(joined) + len(active) == 0 : len(older) == 0
		if empty {
			r := row("empty")
			r.semantic_size = {.X = ui.pct(1), .Y = ui.px(80)}
			if ui.parent(r) {
				filler(.X)
				msg := tb.tab == .Active ? "There are no active threads." : "There are no archived threads."
				label(tb.loading && tb.tab == .Archived ? "Loading..." : msg, .Medium, 14, T("--text-muted"), 18)
				filler(.X)
			}
		}
		if tb.tab == .Active {
			thread_section("joined", "Joined Threads", joined[:])
			thread_section("active", "Other Active Threads", active[:])
		} else {
			thread_section("older", "Archived Threads", older[:])
		}
		spacer(.Y, 8)
	}
	// more archived threads near the end
	if tb.tab == .Archived && tb.has_more && !tb.loading && app.client != nil && sig.hovering {
		if list.content_size.y > 0 && list.view_off.y + (list.rect.y1 - list.rect.y0) > list.content_size.y - 200 {
			tb.loading = true
			dc.fetch_channel_threads(app.client, tb.channel, tb.offset)
		}
	}
}

// Public threads need CREATE_PUBLIC_THREADS and SEND_MESSAGES in the parent.
@(private = "file")
can_create_thread :: proc(channel_id: dc.Snowflake) -> bool {
	perms := dc.channel_permissions(store(), channel_id)
	return perms & dc.PERM_CREATE_PUBLIC_THREADS != 0 && perms & dc.PERM_SEND_MESSAGES != 0
}

@(private = "file")
create_form_open :: proc() {
	tb.creating = true
	tb.busy = false
	ui.editor_set_text(&tb.name, "")
	ui.editor_set_text(&tb.first, "")
	tb.focus = 1
	if app.client != nil do dc.track_thread_creation_started(app.client, tb.channel, "Thread Browser Toolbar")
}

@(private = "file")
create_form :: proc() {
	submit := false
	spacer(.Y, 16)
	field :: proc(id: string, ed: ^ui.Editor, placeholder: string, want_focus: bool) -> ui.Edit_Result {
		res := ui.Edit_Result.None
		r := row(fmt.tprintf("%s_row", id))
		r.semantic_size = {.X = ui.pct(1), .Y = ui.children()}
		if ui.parent(r) {
			spacer(.X, 16)
			box := row(id, {.Draw_Background, .Draw_Border, .Clickable})
			box.semantic_size = {.X = ui.fill(), .Y = ui.children()}
			box.style.bg = T("--input-background-default")
			box.style.border_color = app.ui.focus == box.key ? T("--input-border-active") : T("--input-border-default")
			box.style.border = 1
			box.style.radius = 8
			box.hover_cursor = .IBeam
			if ui.signal(box).pressed || want_focus do app.ui.focus = box.key
			if ui.parent(box) {
				spacer(.X, 12)
				res = text_field("f", ed, placeholder, app.ui.focus == box.key, 16, 20, 9)
				spacer(.X, 12)
			}
			spacer(.X, 16)
		}
		return res
	}
	sub := row("namelbl")
	sub.semantic_size = {.X = ui.pct(1), .Y = ui.px(20)}
	if ui.parent(sub) {
		spacer(.X, 16)
		label("THREAD NAME", .Bold, 12, T("--text-muted"), 16)
	}
	spacer(.Y, 6)
	r1 := field("name", &tb.name, "New Thread", tb.focus == 1)
	spacer(.Y, 12)
	r2 := field("first", &tb.first, "Enter a message to start the conversation!", tb.focus == 2)
	tb.focus = 0
	// typing in the form is typing in the parent channel
	if (r1 == .Changed || r2 == .Changed) && app.client != nil && net_action() do dc.typing_keystroke(app.client, tb.channel)
	if r1 == .Submit || r2 == .Submit do submit = true
	spacer(.Y, 16)
	btns := row("btns")
	btns.semantic_size = {.X = ui.pct(1), .Y = ui.px(36)}
	btns.style.child_gap = 8
	if ui.parent(btns) {
		filler(.X)
		cancel := row("cancel", {.Clickable, .Draw_Background, .Hot_Animation})
		cancel.semantic_size = {.X = ui.children(), .Y = ui.px(32)}
		cancel.style.radius = 8
		cancel.style.bg_hot = T("--background-mod-subtle")
		if ui.parent(cancel) {
			spacer(.X, 12)
			label("Cancel", .Medium, 14, T("--text-default"), 18)
			spacer(.X, 12)
		}
		if ui.signal(cancel).clicked do tb.creating = false
		name := strings.trim_space(ui.editor_text(&tb.name))
		ok := name != "" && !tb.busy
		go := row("go", ok ? {.Clickable, .Draw_Background, .Hot_Animation} : {.Draw_Background})
		go.semantic_size = {.X = ui.children(), .Y = ui.px(32)}
		go.style.radius = 8
		go.style.bg = ok ? T("--background-brand") : with_alpha(T("--background-brand"), 0.5)
		go.style.bg_hot = with_alpha(T("--background-brand"), 0.85)
		if ui.parent(go) {
			spacer(.X, 12)
			label(tb.busy ? "Creating..." : "Create Thread", .Medium, 14, {1, 1, 1, 1}, 18)
			spacer(.X, 12)
		}
		if ok && ui.signal(go).clicked do submit = true
		spacer(.X, 16)
	}
	if !submit || tb.busy do return
	name := strings.trim_space(ui.editor_text(&tb.name))
	if name == "" {
		tb.focus = 1
		return
	}
	if !net_action() do return
	tb.busy = true
	tb.tag += 1
	delete(tb.pending)
	tb.pending = strings.clone(strings.trim_space(ui.editor_text(&tb.first)))
	dc.create_thread(app.client, tb.channel, name, tag = tb.tag)
}

// The thread exists (201): open it and send the first message.
@(private = "file")
thread_created :: proc(r: ^dc.Feature_Result) {
	if r.tag != tb.tag do return
	tb.busy = false
	app.ui.animating = true
	if !r.ok do return
	id := dc.apply_created_thread(app.client, r.body)
	ch := dc.channel_get(store(), id)
	if ch == nil do return
	tb.creating = false
	tb.open = false
	select_channel(ch.guild_id, id)
	if tb.pending != "" do dc.send_message(app.client, id, tb.pending, {location = "thread_creation"})
	delete(tb.pending)
	tb.pending = ""
}

@(private = "file")
thread_section :: proc(id, title: string, ids: []dc.Snowflake) {
	if len(ids) == 0 do return
	sec := ui.box(id)
	sec.semantic_size = {.X = ui.pct(1), .Y = ui.children()}
	sec.layout_axis = .Y
	ui.push_parent(sec)
	defer ui.pop_parent()
	h := row("title")
	h.semantic_size = {.X = ui.pct(1), .Y = ui.px(28)}
	if ui.parent(h) {
		spacer(.X, 16)
		label(fmt.tprintf("%s — %d", title, len(ids)), .Semibold, 12, T("--text-muted"), 16)
	}
	for tid in ids {
		if ui.id_scope(u64(tid)) do thread_browser_row(tid)
	}
	spacer(.Y, 8)
}

@(private = "file")
thread_browser_row :: proc(tid: dc.Snowflake) {
	s := store()
	th := dc.channel_get(s, tid)
	tm := dc.thread_meta(tid)
	if th == nil || tm == nil do return
	outer := row("tr")
	outer.semantic_size = {.X = ui.pct(1), .Y = ui.px(56)}
	ui.push_parent(outer)
	defer ui.pop_parent()
	spacer(.X, 8)
	item := row("item", {.Clickable, .Draw_Background, .Hot_Animation})
	item.semantic_size = {.X = ui.fill(), .Y = ui.px(52)}
	item.style.radius = 8
	item.style.bg = T("--background-base-lower")
	item.style.bg_hot = T("--background-mod-subtle")
	sig := ui.signal(item)
	if ui.parent(item) {
		spacer(.X, 12)
		col := ui.box("col")
		col.semantic_size = {.X = ui.fill(), .Y = ui.children()}
		col.layout_axis = .Y
		if ui.parent(col) {
			nr := row("name")
			nr.semantic_size = {.X = ui.pct(1), .Y = ui.px(20)}
			if ui.parent(nr) {
				if tm.locked || th.kind == .Private_Thread {
					icon("lock", "thread-lock", 16, T("--text-muted"))
					spacer(.X, 4)
				}
				unread := dc.channel_unread(s, tid)
				label(ellipsize(th.name, .Semibold, 15, THREADS_W - 60), .Semibold, 15, unread ? T("--text-strong") : T("--text-default"), 20)
			}
			mr := row("meta")
			mr.semantic_size = {.X = ui.pct(1), .Y = ui.px(18)}
			if ui.parent(mr) {
				if tm.owner_id != 0 {
					avatar_box("av", tm.owner_id, 16)
					spacer(.X, 6)
					if u := dc.user_get(s, tm.owner_id); u != nil {
						label(ellipsize(name_in(tm.owner_id, tid), .Medium, 13, 160), .Medium, 13, T("--text-muted"), 18)
						spacer(.X, 6)
					}
				}
				n := tm.message_count
				label(n == 1 ? "1 Message" : fmt.tprintf("%d Messages", n), .Medium, 13, T("--text-link"), 18)
				spacer(.X, 6)
				label(fmt.tprintf("· %s", relative_age(max(tm.last_message_id, tid))), .Normal, 13, T("--text-muted"), 18)
			}
		}
		spacer(.X, 12)
	}
	spacer(.X, 8)
	if sig.clicked {
		select_channel(th.guild_id, tid, "Thread Browser")
		tb.open = false
	}
}

threads_browser_reset_for_test :: proc() {
	ui.editor_destroy(&tb.name)
	ui.editor_destroy(&tb.first)
	delete(tb.pending)
	tb = {}
}
