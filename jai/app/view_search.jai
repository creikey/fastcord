// Message search: the header search box (Cmd/Ctrl+F focuses it), filter
// suggestions (from:, mentions:, has:, in:, pinned:), a results panel on the
// right with highlighted matches, and jump-to-message (scrolls the channel to
// the message, loading ?around= when it isn't in the loaded history).

SEARCH_PANEL_W :: 418;
#scope_file

Result :: struct {
	msg: dc.Message;
}

Search_State :: struct {
	editor: ui.Editor;
	key: ui.Key;
	focused: bool;
	active: bool; // results panel shown
	loading: bool;
	scope: dc.Snowflake; // guild (or DM channel) searched
	query: string;
	terms: [..]string; // lowercase content words for highlighting
	total: int;
	results: [..]Result;
	arena: virtual.Arena;
	seq: u64;
	box_rect: ui.Rect;
	offset: int;
	sq: dc.Search_Query;
}

search: Search_State;

// ---- jump to message ----

Jump :: struct {
	channel: dc.Snowflake;
	message: dc.Snowflake;
	frames: int;
	requested: bool;
}

jump: Jump;
highlight_id: dc.Snowflake;
highlight_until: float64;
#scope_export

jump_to_message :: (channel_id: dc.Snowflake, message_id: dc.Snowflake) {
	s := store();
	ch := dc.channel_get(s, channel_id);
	if ch == null { return; }
	if app.view.channel != channel_id { select_channel(ch.guild_id, channel_id); }
	jump = .{channel = channel_id, message = message_id};
	loaded := false;
	for m: dc.messages_get(s, channel_id) { if m.id == message_id { loaded = true; } }
	if !loaded && app.client != null {
		dc.fetch_messages_around(app.client, channel_id, message_id);
		jump.requested = true;
	}
	highlight_id = message_id;
	highlight_until = app.ui.time + 2.5;
}

// Called by the message list before it settles the scroll: steer
// scroll_target so the jump target sits in the middle of the viewport.
jump_apply :: (channel_id: dc.Snowflake, cs: *Chat_State, msgs: []dc.Message, view_h: float32, bottom_pad: float32) {
	if jump.channel != channel_id || jump.message == 0 { return; }
	idx := -1;
	for m, i: msgs { if m.id == jump.message { idx = i; } }
	if idx < 0 {
		// not loaded yet (around= in flight); give up after a while
		jump.frames += 1;
		if jump.frames > 600 { jump = .{}; }
		return;
	}
	below := bottom_pad;
	for i: idx + 1..len(msgs)-1 {
		h, ok := map_find(cs.heights, msgs[i].id);
		below += ifx ok then h else MSG_LINE_H + 4;
	}
	h, ok := map_find(cs.heights, msgs[idx].id);
	if !ok { h = MSG_LINE_H + 4; }
	cs.scroll_target = max(0, below + h / 2 - view_h / 2);
	app.ui.animating = true;
	// keep steering until the rows around it have been measured
	jump.frames += 1;
	if jump.frames > 8 { jump = .{}; }
}

jump_highlighted :: (id: dc.Snowflake) -> bool {
	if id != highlight_id { return false; }
	if app.ui.time > highlight_until {
		highlight_id = 0;
		return false;
	}
	app.ui.animating = true;
	return true;
}

// ---- header search box ----

// The box's width as laid out last frame (it shrinks on narrow windows).
search_box_w :: (b: *ui.Box) -> float32 {
	w := b.rect.x1 - b.rect.x0;
	return ifx w > 0 then w else SEARCH_W;
}

search_box :: (ch: *dc.Channel, hint: string) {
	b := row("search", .{.Draw_Background, .Draw_Border, .Clickable});
	b.semantic_size = .[ui.px(SEARCH_W, 0.4), ui.px(32)]; // narrow windows: gives up to 40% before the header overflows
	b.style.bg = cast(T)("--input-background-default");
	b.style.border_color = ifx search.focused then cast(T)("--input-border-active") else cast(T)("--input-border-default");
	b.style.border = 1;
	b.style.radius = 8;
	b.hover_cursor = .IBeam;
	search.box_rect = b.rect;
	// Cmd/Ctrl+F focuses search, like the client
	for * e: app.ui.events {
		if !e.consumed && e.kind == .Key_Down && e.key == .F && (has(e.mods, .Cmd) || has(e.mods, .Ctrl)) && !modal_open() {
			search.focused = true;
			e.consumed = true;
		}
	}
	// a press on the box itself (icon, padding) or on the field child focuses it,
	// unless a modal or popout drawn over the header took the press
	if ui.signal(b).pressed { search.focused = true; }
	if !app.ui.overlay_under_mouse && !modal_open() {
		for e: app.ui.events {
			if !e.consumed && e.kind == .Mouse_Down && e.button == .Left && rect_has(search.box_rect, e.pos) { search.focused = true; }
		}
	}
	if search.focused {
		app.ui.focus = search.key;
		for * e: app.ui.events {
			if e.consumed { continue; }
			if e.kind == .Mouse_Down && !rect_has(search.box_rect, e.pos) && !in_suggestions(e.pos) { search.focused = false; }
		}
	}
	if ui.parent(b) {
		spacer(.X, 9);
		res := text_field("q", *search.editor, ellipsize(hint, .Medium, 14, search_box_w(b) - 46), search.focused, 14, 18, 6, cast(T)("--input-placeholder-text-default"));
		if search.key == 0 || app.ui.focus == 0 {
			// remember the field's key so app.ui.focus keeps the composer quiet
			search.key = b.key;
		}
		if res == {
		case .Submit;
			search_run(ch, strings.trim_space(ui.editor_text(*search.editor)));
		case .Escape;
			search.focused = false;
			app.ui.focus = 0;
		case .None; #through; case .Changed; #through; case .Moved;
		}
		text := ui.editor_text(*search.editor);
		if text != "" {
			x := ui.box("clear", .{.Clickable});
			x.semantic_size = .[ui.px(16), ui.px(16)];
			if ui.signal(x).clicked {
				ui.editor_set_text(*search.editor, "");
				search.active = false;
			}
			set_icon(x, "x-small", cast(T)("--interactive-icon-default"));
		} else {
			icon("mag", "magnifying-glass", 16, cast(T)("--icon-muted"));
		}
		spacer(.X, 8);
	}
	if !search.focused && app.ui.focus == search.key { app.ui.focus = 0; }
}
#scope_file

// ---- suggestions ----

// ---- suggestions ----

sugg_rect: ui.Rect;

in_suggestions :: (p: ui.Vec2) -> bool {return rect_has(sugg_rect, p);}
#scope_export

// The filter popout under the focused search box (overlay pass).
search_suggestions :: () {
	sugg_rect = .{};
	if !search.focused { return; }
	ch := dc.channel_get(store(), app.view.channel);
	if ch == null { return; }
	text := ui.editor_text(*search.editor);
	// the token being typed
	last := text;
	{ i := strings.last_index_byte(text, #char " ");
	if i >= 0 { last = sub_from(text, i + 1); } }
	Item :: struct {
		label, detail, insert: string;
	}
	items := make_dynamic(Item, 0, 0, temp);
	title := "Search Options";
	s := store();
	if strings.has_prefix(last, "from:") || strings.has_prefix(last, "mentions:") {
		prefix := sub(last, 0, strings.index_byte(last, #char ":") + 1);
		q := strings.to_lower(sub_from(last, len(prefix)), temp);
		title = ifx prefix == "from:" then "From User" else "Mentions User";
		n := 0;
		for * uid, u: s.users {
			if n >= 8 { break; }
			if ch.guild_id != 0 {
				{ gm, ok := map_find(s.members, ch.guild_id);
				if ok && !has(gm, uid) { continue; } }
			}
			name := strings.to_lower(u.username, temp);
			shown := dc.user_name(s, uid, ch.guild_id);
			if q != "" && !strings.contains(name, q) && !strings.contains(strings.to_lower(shown, temp), q) { continue; }
			append(*items, Item.{shown, u.username, fmt.tprintf("%s%s ", prefix, u.username)});
			n += 1;
		}
	} else if strings.has_prefix(last, "has:") {
		title = "Message Contains";
		for h: (string.["link", "embed", "poll", "file", "video", "image", "sound", "sticker", "forward"]) {
			if strings.has_prefix(h, sub_from(last, 4)) { append(*items, Item.{h, "", fmt.tprintf("has:%s ", h)}); }
		}
	} else if strings.has_prefix(last, "in:") {
		title = "In Channel";
		q := strings.to_lower(sub_from(last, 3), temp);
		if ch.guild_id != 0 {
			n := 0;
			for cid: dc.guild_channels_sorted(s, ch.guild_id) {
				c := dc.channel_get(s, cid);
				if c == null || c.kind == .Guild_Category || c.kind == .Guild_Voice { continue; }
				if q != "" && !strings.contains(strings.to_lower(c.name, temp), q) { continue; }
				append(*items, Item.{fmt.tprintf("#%s", c.name), "", fmt.tprintf("in:%s ", c.name)});
				n += 1;
				if n >= 8 { break; }
			}
		}
	} else {
		append(*items, Item.{"from:", "user", "from:"});
		append(*items, Item.{"mentions:", "user", "mentions:"});
		append(*items, Item.{"has:", "link, embed or file", "has:"});
		append(*items, Item.{"in:", "channel", "in:"});
		append(*items, Item.{"pinned:", "true or false", "pinned:true "});
	}
	if len(items) == 0 { return; }
	r := search.box_rect;
	W :: 320;
	p := ui.box("search_sugg", .{.Draw_Background, .Draw_Border, .Draw_Shadow, .Floating_X, .Floating_Y, .Overlay, .Clickable});
	p.semantic_size = .[ui.px(W), ui.children()];
	p.fixed_pos = .{max(8, r.x1 - W), r.y1 + 8};
	p.layout_axis = .Y;
	p.style.bg = cast(T)("--background-surface-high");
	p.style.border_color = cast(T)("--border-subtle");
	p.style.border = 1;
	p.style.radius = 8;
	p.style.shadow_color = .{0, 0, 0, 0.3};
	p.style.shadow_blur = 12;
	p.style.shadow_offset = .{0, 6};
	ui.signal(p);
	sugg_rect = p.rect;
	if ui.parent(p) {
		inset_begin(8, 8);
		defer inset_end(8, 8);
		label(title, .Semibold, 12, cast(T)("--text-muted"), 24);
		for it_, i: items {
			ir := row(fmt.tprintf("s%d", i), .{.Clickable, .Draw_Background, .Hot_Animation});
			ir.semantic_size = .[ui.pct(1), ui.px(32)];
			ir.style.radius = 4;
			ir.style.bg_hot = cast(T)("--background-mod-subtle");
			if ui.signal(ir).clicked {
				base := sub(text, 0, len(text) - len(last));
				ui.editor_set_text(*search.editor, strings.concatenate(.{base, it_.insert}, temp));
			}
			if ui.parent(ir) {
				spacer(.X, 8);
				label(it_.label, .Medium, 14, cast(T)("--text-strong"), 18);
				if it_.detail != "" {
					spacer(.X, 6);
					label(it_.detail, .Normal, 14, cast(T)("--text-muted"), 18);
				}
			}
		}
	}
}
#scope_file

// ---- running a search ----

search_run :: (ch: *dc.Channel, text: string) {
	if text == "" { return; }
	s := store();
	virtual.arena_destroy(*search.arena);
	search.arena = .{};
	if virtual.arena_init_growing(*search.arena) != null { return; }
	a := virtual.arena_allocator(*search.arena);
	search.results = make_dynamic(Result, a, a);
	search.terms = make_dynamic(string, a, a);
	search.query = clone(text, a);
	search.active = true;
	search.focused = false;
	search.total = 0;
	search.offset = 0;
	search.scope = ifx ch.guild_id != 0 then ch.guild_id else ch.id;
	authors := make_dynamic(dc.Snowflake, a, a);
	mentions := make_dynamic(dc.Snowflake, a, a);
	has := make_dynamic(string, a, a);
	chans := make_dynamic(dc.Snowflake, a, a);
	content := make_dynamic(string, a, a);
	pinned := false;
	find_user :: (s: *dc.Store, name: string) -> dc.Snowflake {
		ln := strings.to_lower(name, temp);
		for * uid, u: s.users {
			if strings.to_lower(u.username, temp) == ln { return uid; }
		}
		for * uid, u: s.users {
			if strings.to_lower(dc.user_name(s, uid), temp) == ln || strings.to_lower(dc.display_name(*u), temp) == ln { return uid; }
		}
		return 0;
	}
	rest := text;
	while true { tok, __ok3 := strings.fields_iterator(*rest); if !__ok3 break;
		if strings.has_prefix(tok, "from:") {
			{ id := find_user(s, sub_from(tok, 5));
			if id != 0 { append(*authors, id); } }
		} else if strings.has_prefix(tok, "mentions:") {
			{ id := find_user(s, sub_from(tok, 9));
			if id != 0 { append(*mentions, id); } }
		} else if strings.has_prefix(tok, "has:") {
			append(*has, clone(sub_from(tok, 4), a));
		} else if strings.has_prefix(tok, "in:") {
			name := strings.trim_left(sub_from(tok, 3), "#");
			for cid: dc.guild_channels_sorted(s, ch.guild_id) {
				c := dc.channel_get(s, cid);
				if c != null && c.name == name {
					append(*chans, cid);
					break;
				}
			}
		} else if tok == "pinned:true" {
			pinned = true;
		} else {
			append(*content, tok);
			append(*search.terms, strings.to_lower(tok, a));
		}
	}
	search.sq = .{
		content = strings.join(view(content), " ", a),
		author_ids = view(authors),
		mentions = view(mentions),
		has = view(has),
		channel_ids = view(chans),
		pinned = pinned
	};
	search.seq += 1;
	search.loading = app.client != null;
	if app.client != null { dc.search_messages(app.client, ch.guild_id, ch.id, search.sq, search.seq); }
}
#scope_export

search_receive :: (r: *dc.Feature_Result) {
	if r.tag != search.seq { return; }
	search.loading = false;
	if !r.ok { return; }
	a := virtual.arena_allocator(*search.arena);
	body := dc.vmap(r.body);
	search.total = cast(int)(dc.fint(body, "total_results"));
	// messages: [[message], ...]
	for group: dc.flist(body, "messages") {
		for mv: dc.vlist(group) {
			append(*search.results, Result.{msg = dc.parse_loose_message(store(), dc.vmap(mv), a)});
		}
	}
	app.ui.animating = true;
}

search_panel_open :: () -> bool {return search.active;}

// Results panel (replaces the member list while a search is active).
search_panel :: () {
	s := store();
	p := ui.box("searchpanel", .{.Draw_Background, .Draw_Border});
	p.semantic_size = .[ui.px(SEARCH_PANEL_W), ui.pct(1)];
	p.layout_axis = .Y;
	p.style.bg = cast(T)("--background-base-low");
	p.style.border_color = cast(T)("--border-subtle");
	p.style.border = 1;
	if ui.parent(p) {
		hdr := row("hdr");
		hdr.semantic_size = .[ui.pct(1), ui.px(48)];
		if ui.parent(hdr) {
			spacer(.X, 16);
			txt := ifx search.loading then "Searching..." else ifx search.total == 1 then "1 Result" else fmt.tprintf("%d Results", search.total);
			label(txt, .Semibold, 16, cast(T)("--text-strong"), 20);
			filler(.X);
			x := ui.box("close", .{.Clickable});
			x.semantic_size = .[ui.px(24), ui.px(24)];
			if ui.signal(x).clicked { search.active = false; }
			set_icon(x, "x", cast(T)("--interactive-icon-default"));
			spacer(.X, 12);
		}
		list := ui.box("list", .{.Scroll_Y, .Clip});
		list.semantic_size = .[ui.pct(1), ui.fill()];
		list.layout_axis = .Y;
		ui.signal(list);
		if ui.parent(list) {
			if !search.loading && len(search.results) == 0 {
				r := row("none");
				r.semantic_size = .[ui.pct(1), ui.px(80)];
				if ui.parent(r) {
					filler(.X);
					label("No results found", .Medium, 14, cast(T)("--text-muted"), 18);
					filler(.X);
				}
			}
			last_ch: dc.Snowflake;
			for * res, i: search.results {
				if ui.id_scope(cast(u64)(i + 1)) {
					if res.msg.channel_id != last_ch {
						last_ch = res.msg.channel_id;
						cr := row("chan");
						cr.semantic_size = .[ui.pct(1), ui.px(32)];
						if ui.parent(cr) {
							spacer(.X, 16);
							c := dc.channel_get(s, res.msg.channel_id);
							if c != null {
								icon("ci", channel_icon_name(c), 16, cast(T)("--channel-icon"));
								spacer(.X, 4);
								label(ifx c.kind == .DM || c.kind == .Group_DM then dm_name(c) else c.name, .Semibold, 14, cast(T)("--text-default"), 18);
							}
						}
					}
					if loose_message_card(*res.msg, view(search.terms), true) {
						search.active = true;
						jump_to_message(res.msg.channel_id, res.msg.id);
					}
				}
			}
			spacer(.Y, 8);
		}
	}
}
#scope_file

rect_has :: (r: ui.Rect, p: ui.Vec2) -> bool {return p.x >= r.x0 && p.x < r.x1 && p.y >= r.y0 && p.y < r.y1;}
#scope_export

// Headless control sweep (sweep.odin): back to program start / what to compare.
search_reset_for_test :: () {
	virtual.arena_destroy(*search.arena);
	search, jump, highlight_id, highlight_until, sugg_rect = .{}, .{}, 0, 0, .{};
}
search_state_for_test :: () -> string {return fmt.tprint(search.active, search.focused, search.query, jump.message);}

