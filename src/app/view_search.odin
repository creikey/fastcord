package app

import "core:fmt"
import "core:mem/virtual"
import "core:strings"
import dc "fc:discord"
import "fc:ui"

// Message search: the header search box (Cmd/Ctrl+F focuses it), filter
// suggestions (from:, mentions:, has:, in:, pinned:), a results panel on the
// right with highlighted matches, and jump-to-message (scrolls the channel to
// the message, loading ?around= when it isn't in the loaded history).

SEARCH_PANEL_W :: 418

@(private = "file")
Result :: struct {
	msg: dc.Message,
}

@(private = "file")
Search_State :: struct {
	editor:   ui.Editor,
	key:      ui.Key,
	focused:  bool,
	active:   bool, // results panel shown
	loading:  bool,
	scope:    dc.Snowflake, // guild (or DM channel) searched
	query:    string,
	terms:    [dynamic]string, // lowercase content words for highlighting
	total:    int,
	results:  [dynamic]Result,
	arena:    virtual.Arena,
	seq:      u64,
	box_rect: ui.Rect,
	offset:   int,
	sq:       dc.Search_Query,
}

@(private = "file")
search: Search_State

// ---- jump to message ----

@(private = "file")
Jump :: struct {
	channel:   dc.Snowflake,
	message:   dc.Snowflake,
	frames:    int,
	requested: bool,
}

@(private = "file")
jump: Jump
@(private = "file")
highlight_id: dc.Snowflake
@(private = "file")
highlight_until: f64

jump_to_message :: proc(channel_id, message_id: dc.Snowflake) {
	s := store()
	ch := dc.channel_get(s, channel_id)
	if ch == nil do return
	if app.view.channel != channel_id do select_channel(ch.guild_id, channel_id)
	jump = {channel = channel_id, message = message_id}
	loaded := false
	for m in dc.messages_get(s, channel_id) do if m.id == message_id do loaded = true
	if !loaded && app.client != nil {
		dc.fetch_messages_around(app.client, channel_id, message_id)
		jump.requested = true
	}
	highlight_id = message_id
	highlight_until = app.ui.time + 2.5
}

// Called by the message list before it settles the scroll: steer
// scroll_target so the jump target sits in the middle of the viewport.
jump_apply :: proc(channel_id: dc.Snowflake, cs: ^Chat_State, msgs: []dc.Message, view_h: f32, bottom_pad: f32) {
	if jump.channel != channel_id || jump.message == 0 do return
	idx := -1
	for m, i in msgs do if m.id == jump.message do idx = i
	if idx < 0 {
		// not loaded yet (around= in flight); give up after a while
		jump.frames += 1
		if jump.frames > 600 do jump = {}
		return
	}
	below := bottom_pad
	for i in idx + 1 ..< len(msgs) {
		h, ok := cs.heights[msgs[i].id]
		below += ok ? h : MSG_LINE_H + 4
	}
	h, ok := cs.heights[msgs[idx].id]
	if !ok do h = MSG_LINE_H + 4
	cs.scroll_target = max(0, below + h / 2 - view_h / 2)
	app.ui.animating = true
	// keep steering until the rows around it have been measured
	jump.frames += 1
	if jump.frames > 8 do jump = {}
}

jump_highlighted :: proc(id: dc.Snowflake) -> bool {
	if id != highlight_id do return false
	if app.ui.time > highlight_until {
		highlight_id = 0
		return false
	}
	app.ui.animating = true
	return true
}

// ---- header search box ----

search_box :: proc(ch: ^dc.Channel, hint: string) {
	b := row("search", {.Draw_Background, .Draw_Border, .Clickable})
	b.semantic_size = {.X = ui.px(SEARCH_W), .Y = ui.px(32)}
	b.style.bg = T("--input-background-default")
	b.style.border_color = search.focused ? T("--input-border-active") : T("--input-border-default")
	b.style.border = 1
	b.style.radius = 8
	b.hover_cursor = .IBeam
	search.box_rect = b.rect
	// Cmd/Ctrl+F focuses search, like the client
	for &e in app.ui.events {
		if !e.consumed && e.kind == .Key_Down && e.key == .F && (.Cmd in e.mods || .Ctrl in e.mods) {
			search.focused = true
			e.consumed = true
		}
	}
	// a press on the box itself (icon, padding) or on the field child focuses it
	if ui.signal(b).pressed do search.focused = true
	for e in app.ui.events {
		if !e.consumed && e.kind == .Mouse_Down && e.button == .Left && rect_has(search.box_rect, e.pos) do search.focused = true
	}
	if search.focused {
		app.ui.focus = search.key
		for &e in app.ui.events {
			if e.consumed do continue
			if e.kind == .Mouse_Down && !rect_has(search.box_rect, e.pos) && !in_suggestions(e.pos) do search.focused = false
		}
	}
	if ui.parent(b) {
		spacer(.X, 9)
		res := text_field("q", &search.editor, ellipsize(hint, .Medium, 14, SEARCH_W - 46), search.focused, 14, 18, 6, T("--input-placeholder-text-default"))
		if search.key == 0 || app.ui.focus == 0 {
			// remember the field's key so app.ui.focus keeps the composer quiet
			search.key = b.key
		}
		switch res {
		case .Submit:
			search_run(ch, strings.trim_space(ui.editor_text(&search.editor)))
		case .Escape:
			search.focused = false
			app.ui.focus = 0
		case .None, .Changed, .Moved:
		}
		text := ui.editor_text(&search.editor)
		if text != "" {
			x := ui.box("clear", {.Clickable})
			x.semantic_size = {.X = ui.px(16), .Y = ui.px(16)}
			if ui.signal(x).clicked {
				ui.editor_set_text(&search.editor, "")
				search.active = false
			}
			set_icon(x, "x-small", T("--interactive-icon-default"))
		} else {
			icon("mag", "magnifying-glass", 16, T("--icon-muted"))
		}
		spacer(.X, 8)
	}
	if !search.focused && app.ui.focus == search.key do app.ui.focus = 0
}

// ---- suggestions ----

@(private = "file")
sugg_rect: ui.Rect

@(private = "file")
in_suggestions :: proc(p: ui.Vec2) -> bool {return rect_has(sugg_rect, p)}

// The filter popout under the focused search box (overlay pass).
search_suggestions :: proc() {
	sugg_rect = {}
	if !search.focused do return
	ch := dc.channel_get(store(), app.view.channel)
	if ch == nil do return
	text := ui.editor_text(&search.editor)
	// the token being typed
	last := text
	if i := strings.last_index_byte(text, ' '); i >= 0 do last = text[i + 1:]
	Item :: struct {
		label, detail, insert: string,
	}
	items := make([dynamic]Item, context.temp_allocator)
	title := "Search Options"
	s := store()
	switch {
	case strings.has_prefix(last, "from:") || strings.has_prefix(last, "mentions:"):
		prefix := last[:strings.index_byte(last, ':') + 1]
		q := strings.to_lower(last[len(prefix):], context.temp_allocator)
		title = prefix == "from:" ? "From User" : "Mentions User"
		n := 0
		for uid, &u in s.users {
			if n >= 8 do break
			if ch.guild_id != 0 {
				if gm, ok := s.members[ch.guild_id]; ok && uid not_in gm do continue
			}
			name := strings.to_lower(u.username, context.temp_allocator)
			if q != "" && !strings.contains(name, q) && !strings.contains(strings.to_lower(dc.display_name(&u), context.temp_allocator), q) do continue
			append(&items, Item{dc.display_name(&u), u.username, fmt.tprintf("%s%s ", prefix, u.username)})
			n += 1
		}
	case strings.has_prefix(last, "has:"):
		title = "Message Contains"
		for h in ([]string{"link", "embed", "poll", "file", "video", "image", "sound", "sticker", "forward"}) {
			if strings.has_prefix(h, last[4:]) do append(&items, Item{h, "", fmt.tprintf("has:%s ", h)})
		}
	case strings.has_prefix(last, "in:"):
		title = "In Channel"
		q := strings.to_lower(last[3:], context.temp_allocator)
		if ch.guild_id != 0 {
			n := 0
			for cid in dc.guild_channels_sorted(s, ch.guild_id) {
				c := dc.channel_get(s, cid)
				if c == nil || c.kind == .Guild_Category || c.kind == .Guild_Voice do continue
				if q != "" && !strings.contains(strings.to_lower(c.name, context.temp_allocator), q) do continue
				append(&items, Item{fmt.tprintf("#%s", c.name), "", fmt.tprintf("in:%s ", c.name)})
				n += 1
				if n >= 8 do break
			}
		}
	case:
		append(&items, Item{"from:", "user", "from:"})
		append(&items, Item{"mentions:", "user", "mentions:"})
		append(&items, Item{"has:", "link, embed or file", "has:"})
		append(&items, Item{"in:", "channel", "in:"})
		append(&items, Item{"pinned:", "true or false", "pinned:true "})
	}
	if len(items) == 0 do return
	r := search.box_rect
	W :: 320
	p := ui.box("search_sugg", {.Draw_Background, .Draw_Border, .Draw_Shadow, .Floating_X, .Floating_Y, .Overlay, .Clickable})
	p.semantic_size = {.X = ui.px(W), .Y = ui.children()}
	p.fixed_pos = {max(8, r.x1 - W), r.y1 + 8}
	p.layout_axis = .Y
	p.style.bg = T("--background-surface-high")
	p.style.border_color = T("--border-subtle")
	p.style.border = 1
	p.style.radius = 8
	p.style.shadow_color = {0, 0, 0, 0.3}
	p.style.shadow_blur = 12
	p.style.shadow_offset = {0, 6}
	ui.signal(p)
	sugg_rect = p.rect
	if ui.parent(p) {
		inset_begin(8, 8)
		defer inset_end(8, 8)
		label(title, .Semibold, 12, T("--text-muted"), 24)
		for it, i in items {
			ir := row(fmt.tprintf("s%d", i), {.Clickable, .Draw_Background, .Hot_Animation})
			ir.semantic_size = {.X = ui.pct(1), .Y = ui.px(32)}
			ir.style.radius = 4
			ir.style.bg_hot = T("--background-mod-subtle")
			if ui.signal(ir).clicked {
				base := text[:len(text) - len(last)]
				ui.editor_set_text(&search.editor, strings.concatenate({base, it.insert}, context.temp_allocator))
			}
			if ui.parent(ir) {
				spacer(.X, 8)
				label(it.label, .Medium, 14, T("--text-strong"), 18)
				if it.detail != "" {
					spacer(.X, 6)
					label(it.detail, .Normal, 14, T("--text-muted"), 18)
				}
			}
		}
	}
}

// ---- running a search ----

@(private = "file")
search_run :: proc(ch: ^dc.Channel, text: string) {
	if text == "" do return
	s := store()
	virtual.arena_destroy(&search.arena)
	search.arena = {}
	if virtual.arena_init_growing(&search.arena) != nil do return
	a := virtual.arena_allocator(&search.arena)
	search.results = make([dynamic]Result, a)
	search.terms = make([dynamic]string, a)
	search.query = strings.clone(text, a)
	search.active = true
	search.focused = false
	search.total = 0
	search.offset = 0
	search.scope = ch.guild_id != 0 ? ch.guild_id : ch.id
	authors := make([dynamic]dc.Snowflake, a)
	mentions := make([dynamic]dc.Snowflake, a)
	has := make([dynamic]string, a)
	chans := make([dynamic]dc.Snowflake, a)
	content := make([dynamic]string, a)
	pinned := false
	find_user :: proc(s: ^dc.Store, name: string) -> dc.Snowflake {
		ln := strings.to_lower(name, context.temp_allocator)
		for uid, &u in s.users {
			if strings.to_lower(u.username, context.temp_allocator) == ln do return uid
		}
		for uid, &u in s.users {
			if strings.to_lower(dc.display_name(&u), context.temp_allocator) == ln do return uid
		}
		return 0
	}
	rest := text
	for tok in strings.fields_iterator(&rest) {
		switch {
		case strings.has_prefix(tok, "from:"):
			if id := find_user(s, tok[5:]); id != 0 do append(&authors, id)
		case strings.has_prefix(tok, "mentions:"):
			if id := find_user(s, tok[9:]); id != 0 do append(&mentions, id)
		case strings.has_prefix(tok, "has:"):
			append(&has, strings.clone(tok[4:], a))
		case strings.has_prefix(tok, "in:"):
			name := strings.trim_left(tok[3:], "#")
			for cid in dc.guild_channels_sorted(s, ch.guild_id) {
				c := dc.channel_get(s, cid)
				if c != nil && c.name == name {
					append(&chans, cid)
					break
				}
			}
		case tok == "pinned:true":
			pinned = true
		case:
			append(&content, tok)
			append(&search.terms, strings.to_lower(tok, a))
		}
	}
	search.sq = {
		content     = strings.join(content[:], " ", a),
		author_ids  = authors[:],
		mentions    = mentions[:],
		has         = has[:],
		channel_ids = chans[:],
		pinned      = pinned,
	}
	search.seq += 1
	search.loading = app.client != nil
	if app.client != nil do dc.search_messages(app.client, ch.guild_id, ch.id, search.sq, search.seq)
}

search_receive :: proc(r: ^dc.Feature_Result) {
	if r.tag != search.seq do return
	search.loading = false
	if !r.ok do return
	a := virtual.arena_allocator(&search.arena)
	body := dc.vmap(r.body)
	search.total = int(dc.fint(body, "total_results"))
	// messages: [[message], ...]
	for group in dc.flist(body, "messages") {
		for mv in dc.vlist(group) {
			append(&search.results, Result{msg = dc.parse_loose_message(store(), dc.vmap(mv), a)})
		}
	}
	app.ui.animating = true
}

search_panel_open :: proc() -> bool {return search.active}

// Results panel (replaces the member list while a search is active).
search_panel :: proc() {
	s := store()
	p := ui.box("searchpanel", {.Draw_Background, .Draw_Border})
	p.semantic_size = {.X = ui.px(SEARCH_PANEL_W), .Y = ui.pct(1)}
	p.layout_axis = .Y
	p.style.bg = T("--background-base-low")
	p.style.border_color = T("--border-subtle")
	p.style.border = 1
	if ui.parent(p) {
		hdr := row("hdr")
		hdr.semantic_size = {.X = ui.pct(1), .Y = ui.px(48)}
		if ui.parent(hdr) {
			spacer(.X, 16)
			txt := search.loading ? "Searching..." : search.total == 1 ? "1 Result" : fmt.tprintf("%d Results", search.total)
			label(txt, .Semibold, 16, T("--text-strong"), 20)
			filler(.X)
			x := ui.box("close", {.Clickable})
			x.semantic_size = {.X = ui.px(24), .Y = ui.px(24)}
			if ui.signal(x).clicked do search.active = false
			set_icon(x, "x", T("--interactive-icon-default"))
			spacer(.X, 12)
		}
		list := ui.box("list", {.Scroll_Y, .Clip})
		list.semantic_size = {.X = ui.pct(1), .Y = ui.fill()}
		list.layout_axis = .Y
		ui.signal(list)
		if ui.parent(list) {
			if !search.loading && len(search.results) == 0 {
				r := row("none")
				r.semantic_size = {.X = ui.pct(1), .Y = ui.px(80)}
				if ui.parent(r) {
					filler(.X)
					label("No results found", .Medium, 14, T("--text-muted"), 18)
					filler(.X)
				}
			}
			last_ch: dc.Snowflake
			for &res, i in search.results {
				if ui.id_scope(u64(i + 1)) {
					if res.msg.channel_id != last_ch {
						last_ch = res.msg.channel_id
						cr := row("chan")
						cr.semantic_size = {.X = ui.pct(1), .Y = ui.px(32)}
						if ui.parent(cr) {
							spacer(.X, 16)
							c := dc.channel_get(s, res.msg.channel_id)
							if c != nil {
								icon("ci", channel_icon_name(c), 16, T("--channel-icon"))
								spacer(.X, 4)
								label(c.kind == .DM || c.kind == .Group_DM ? dm_name(c) : c.name, .Semibold, 14, T("--text-default"), 18)
							}
						}
					}
					if loose_message_card(&res.msg, search.terms[:], true) {
						search.active = true
						jump_to_message(res.msg.channel_id, res.msg.id)
					}
				}
			}
			spacer(.Y, 8)
		}
	}
}

@(private = "file")
rect_has :: proc(r: ui.Rect, p: ui.Vec2) -> bool {return p.x >= r.x0 && p.x < r.x1 && p.y >= r.y0 && p.y < r.y1}

// Headless control sweep (sweep.odin): back to program start / what to compare.
search_reset_for_test :: proc() {
	virtual.arena_destroy(&search.arena)
	search, jump, highlight_id, highlight_until, sugg_rect = {}, {}, 0, 0, {}
}
search_state_for_test :: proc() -> string {return fmt.tprint(search.active, search.focused, search.query, jump.message)}
