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
	pool: Flat_Pool; // results, terms, query and the request's lists
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
	for i: idx + 1..msgs.count-1 {
		ok, h := table_find(*cs.heights, msgs[i].id);
		below += ifx ok then h else MSG_LINE_H + 4;
	}
	ok, h := table_find(*cs.heights, msgs[idx].id);
	if !ok { h = MSG_LINE_H + 4; }
	cs.scroll_target = max(0.0, below + h / 2 - view_h / 2);
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
	b := row("search", .Draw_Background | .Draw_Border | .Clickable);
	b.semantic_size = .[ui.px(SEARCH_W, 0.4), ui.px(32)]; // narrow windows: gives up to 40% before the header overflows
	b.style.bg = T("--input-background-default");
	b.style.border_color = ifx search.focused then T("--input-border-active") else T("--input-border-default");
	b.style.border = 1;
	b.style.radius = all4(8);
	b.hover_cursor = .IBeam;
	search.box_rect = b.rect;
	// Cmd/Ctrl+F focuses search, like the client
	for * e: app.ui.events {
		if !e.consumed && e.kind == .Key_Down && e.key == .F && (e.mods & (ui.Mod.Cmd | .Ctrl)) != 0 && !modal_open() {
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
	{ ui.parent(b); defer ui.pop_parent();
		spacer(.X, 9);
		res := text_field("q", *search.editor, ellipsize(hint, .Medium, 14, search_box_w(b) - 46), search.focused, 14, 18, 6, T("--input-placeholder-text-default"));
		if search.key == 0 || app.ui.focus == 0 {
			// remember the field's key so app.ui.focus keeps the composer quiet
			search.key = b.key;
		}
		if res == {
		case .Submit;
			search_run(ch, trim(ui.editor_text(*search.editor)));
		case .Escape;
			search.focused = false;
			app.ui.focus = 0;
		case .None; #through; case .Changed; #through; case .Moved;
		}
		text := ui.editor_text(*search.editor);
		if text != "" {
			x := ui.box("clear", .Clickable);
			x.semantic_size = .[ui.px(16), ui.px(16)];
			if ui.signal(x).clicked {
				ui.editor_set_text(*search.editor, "");
				search.active = false;
			}
			set_icon(x, "x-small", T("--interactive-icon-default"));
		} else {
			icon("mag", "magnifying-glass", 16, T("--icon-muted"));
		}
		spacer(.X, 8);
	}
	if !search.focused && app.ui.focus == search.key { app.ui.focus = 0; }
}

// ---- suggestions ----

// The filter popout under the focused search box (overlay pass).
search_suggestions :: () {
	sugg_rect = .{};
	if !search.focused { return; }
	ch := dc.channel_get(store(), app.view.channel);
	if ch == null { return; }
	text := ui.editor_text(*search.editor);
	// the token being typed
	last := text;
	i := find_index_from_right(text, #char " ");
	if i >= 0 { advance(*last, i + 1); }
	Item :: struct {
		label, detail, insert: string;
	}
	items: [..]Item;
	items.allocator = temp;
	title := "Search Options";
	s := store();
	if begins_with(last, "from:") || begins_with(last, "mentions:") {
		prefix := ifx begins_with(last, "from:") then "from:" else "mentions:";
		q := to_lower_copy(advance(last, prefix.count),, temp);
		title = ifx prefix == "from:" then "From User" else "Mentions User";
		gm := ifx ch.guild_id != 0 then table_find_pointer(*s.members, ch.guild_id) else null;
		n := 0;
		for * u, uid: s.users {
			if n >= 8 { break; }
			if gm && !table_contains(gm, uid) { continue; }
			name := to_lower_copy(u.username,, temp);
			shown := dc.user_name(s, uid, ch.guild_id);
			if q != "" && !contains(name, q) && !contains(to_lower_copy(shown,, temp), q) { continue; }
			array_add(*items, .{shown, u.username, tprint("%1%2 ", prefix, u.username)});
			n += 1;
		}
	} else if begins_with(last, "has:") {
		title = "Message Contains";
		for h: string.["link", "embed", "poll", "file", "video", "image", "sound", "sticker", "forward"] {
			if begins_with(h, advance(last, 4)) { array_add(*items, .{h, "", tprint("has:% ", h)}); }
		}
	} else if begins_with(last, "in:") {
		title = "In Channel";
		q := to_lower_copy(advance(last, 3),, temp);
		if ch.guild_id != 0 {
			n := 0;
			for cid: dc.guild_channels_sorted(s, ch.guild_id) {
				c := dc.channel_get(s, cid);
				if c == null || c.kind == .Guild_Category || c.kind == .Guild_Voice { continue; }
				if q != "" && !contains(to_lower_copy(c.name,, temp), q) { continue; }
				array_add(*items, .{tprint("#%", c.name), "", tprint("in:% ", c.name)});
				n += 1;
				if n >= 8 { break; }
			}
		}
	} else {
		array_add(*items, .{"from:", "user", "from:"});
		array_add(*items, .{"mentions:", "user", "mentions:"});
		array_add(*items, .{"has:", "link, embed or file", "has:"});
		array_add(*items, .{"in:", "channel", "in:"});
		array_add(*items, .{"pinned:", "true or false", "pinned:true "});
	}
	if items.count == 0 { return; }
	r := search.box_rect;
	W :: 320;
	p := ui.box("search_sugg", .Draw_Background | .Draw_Border | .Draw_Shadow | .Floating_X | .Floating_Y | .Overlay | .Clickable);
	p.semantic_size = .[ui.px(W), ui.children()];
	p.fixed_pos = .{max(8.0, r.x1 - W), r.y1 + 8};
	p.layout_axis = .Y;
	p.style.bg = T("--background-surface-high");
	p.style.border_color = T("--border-subtle");
	p.style.border = 1;
	p.style.radius = all4(8);
	p.style.shadow_color = .{0, 0, 0, 0.3};
	p.style.shadow_blur = 12;
	p.style.shadow_offset = .{0, 6};
	ui.signal(p);
	sugg_rect = p.rect;
	{ ui.parent(p); defer ui.pop_parent();
		inset_begin(8, 8);
		defer inset_end(8, 8);
		label(title, .Semibold, 12, T("--text-muted"), 24);
		for item, i: items {
			ir := row(tprint("s%", i), .Clickable | .Draw_Background | .Hot_Animation);
			ir.semantic_size = .[ui.pct(1), ui.px(32)];
			ir.style.radius = all4(4);
			ir.style.bg_hot = T("--background-mod-subtle");
			if ui.signal(ir).clicked {
				base := text;
				base.count -= last.count;
				ui.editor_set_text(*search.editor, join(base, item.insert,, temp));
			}
			{ ui.parent(ir); defer ui.pop_parent();
				spacer(.X, 8);
				label(item.label, .Medium, 14, T("--text-strong"), 18);
				if item.detail != "" {
					spacer(.X, 6);
					label(item.detail, .Normal, 14, T("--text-muted"), 18);
				}
			}
		}
	}
}

search_receive :: (r: *dc.Feature_Result) {
	if r.tag != search.seq { return; }
	search.loading = false;
	if !r.ok { return; }
	a := dc.pool_allocator(*search.pool);
	body := dc.vmap(r.body);
	search.total = cast(int)(dc.fint(body, "total_results"));
	// messages: [[message], ...]
	for group: dc.flist(body, "messages") {
		for mv: dc.vlist(group) {
			array_add(*search.results, .{msg = dc.parse_loose_message(store(), dc.vmap(mv), a)});
		}
	}
	app.ui.animating = true;
}

search_panel_open :: () -> bool {return search.active;}

// Results panel (replaces the member list while a search is active).
search_panel :: () {
	s := store();
	p := ui.box("searchpanel", .Draw_Background | .Draw_Border);
	p.semantic_size = .[ui.px(SEARCH_PANEL_W), ui.pct(1)];
	p.layout_axis = .Y;
	p.style.bg = T("--background-base-low");
	p.style.border_color = T("--border-subtle");
	p.style.border = 1;
	{ ui.parent(p); defer ui.pop_parent();
		hdr := row("hdr");
		hdr.semantic_size = .[ui.pct(1), ui.px(48)];
		{ ui.parent(hdr); defer ui.pop_parent();
			spacer(.X, 16);
			txt := ifx search.loading then "Searching..." else ifx search.total == 1 then "1 Result" else tprint("% Results", search.total);
			label(txt, .Semibold, 16, T("--text-strong"), 20);
			filler(.X);
			x := ui.box("close", .Clickable);
			x.semantic_size = .[ui.px(24), ui.px(24)];
			if ui.signal(x).clicked { search.active = false; }
			set_icon(x, "x", T("--interactive-icon-default"));
			spacer(.X, 12);
		}
		list := ui.box("list", .Scroll_Y | .Clip);
		list.semantic_size = .[ui.pct(1), ui.fill()];
		list.layout_axis = .Y;
		ui.signal(list);
		{ ui.parent(list); defer ui.pop_parent();
			if !search.loading && search.results.count == 0 {
				r := row("none");
				r.semantic_size = .[ui.pct(1), ui.px(80)];
				{ ui.parent(r); defer ui.pop_parent();
					filler(.X);
					label("No results found", .Medium, 14, T("--text-muted"), 18);
					filler(.X);
				}
			}
			last_ch: dc.Snowflake;
			for * res, i: search.results {
				{ ui.id_scope(cast(u64)(i + 1)); defer ui.pop_seed();
					if res.msg.channel_id != last_ch {
						last_ch = res.msg.channel_id;
						cr := row("chan");
						cr.semantic_size = .[ui.pct(1), ui.px(32)];
						{ ui.parent(cr); defer ui.pop_parent();
							spacer(.X, 16);
							c := dc.channel_get(s, res.msg.channel_id);
							if c != null {
								icon("ci", channel_icon_name(c), 16, T("--channel-icon"));
								spacer(.X, 4);
								label(ifx c.kind == .DM || c.kind == .Group_DM then dm_name(c) else c.name, .Semibold, 14, T("--text-default"), 18);
							}
						}
					}
					if loose_message_card(*res.msg, search.terms, true) {
						search.active = true;
						jump_to_message(res.msg.channel_id, res.msg.id);
					}
				}
			}
			spacer(.Y, 8);
		}
	}
}

// Headless control sweep (sweep.jai): back to program start / what to compare.
search_reset_for_test :: () {
	fini(*search.pool);
	search, jump, highlight_id, highlight_until, sugg_rect = .{}, .{}, 0, 0, .{};
}
search_state_for_test :: () -> string {return tprint("% % % %", search.active, search.focused, search.query, jump.message);}

#scope_file

sugg_rect: ui.Rect;

in_suggestions :: (p: ui.Vec2) -> bool {return rect_has(sugg_rect, p);}

rect_has :: (r: ui.Rect, p: ui.Vec2) -> bool {return p.x >= r.x0 && p.x < r.x1 && p.y >= r.y0 && p.y < r.y1;}

search_run :: (ch: *dc.Channel, text: string) {
	if text == "" { return; }
	s := store();
	array_reset(*search.results);
	array_reset(*search.terms);
	fini(*search.pool);
	a := dc.pool_allocator(*search.pool);
	search.results.allocator = a;
	search.terms.allocator = a;
	search.query = copy_string(text,, a);
	search.active = true;
	search.focused = false;
	search.total = 0;
	search.offset = 0;
	search.scope = ifx ch.guild_id != 0 then ch.guild_id else ch.id;
	authors, mentions, chans: [..]dc.Snowflake;
	has, content: [..]string;
	authors.allocator, mentions.allocator, chans.allocator, has.allocator = a, a, a, a;
	content.allocator = temp;
	pinned := false;
	find_user :: (s: *dc.Store, name: string) -> dc.Snowflake {
		ln := to_lower_copy(name,, temp);
		for * u, uid: s.users {
			if to_lower_copy(u.username,, temp) == ln { return uid; }
		}
		for * u, uid: s.users {
			if to_lower_copy(dc.user_name(s, uid),, temp) == ln || to_lower_copy(dc.display_name(u),, temp) == ln { return uid; }
		}
		return 0;
	}
	rest := text;
	while true {
		// space-separated tokens
		rest = trim_left(rest);
		if !rest { break; }
		n := 0;
		while n < rest.count && !is_space(rest[n]) { n += 1; }
		tok := rest;
		tok.count = n;
		advance(*rest, n);
		if begins_with(tok, "from:") {
			id := find_user(s, advance(tok, 5));
			if id != 0 { array_add(*authors, id); }
		} else if begins_with(tok, "mentions:") {
			id := find_user(s, advance(tok, 9));
			if id != 0 { array_add(*mentions, id); }
		} else if begins_with(tok, "has:") {
			array_add(*has, copy_string(advance(tok, 4),, a));
		} else if begins_with(tok, "in:") {
			name := trim_left(advance(tok, 3), "#");
			for cid: dc.guild_channels_sorted(s, ch.guild_id) {
				c := dc.channel_get(s, cid);
				if c != null && c.name == name {
					array_add(*chans, cid);
					break;
				}
			}
		} else if tok == "pinned:true" {
			pinned = true;
		} else {
			array_add(*content, tok);
			array_add(*search.terms, to_lower_copy(tok,, a));
		}
	}
	search.sq = .{
		content = join(..content, " ",, a),
		author_ids = authors,
		mentions = mentions,
		has = has,
		channel_ids = chans,
		pinned = pinned
	};
	search.seq += 1;
	search.loading = app.client != null;
	if app.client != null { dc.search_messages(app.client, ch.guild_id, ch.id, search.sq, search.seq); }
}


