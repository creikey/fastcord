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
	sort: dc.Search_Sort; // the results' sort, kept for later searches this session
}

search: Search_State;

// ---- jump to message ----

Jump :: struct {
	channel: dc.Snowflake;
	message: dc.Snowflake;
	frames: int;
	settled: int; // frames the measured target has held
	requested: bool;
}

jump: Jump;
highlight_id: dc.Snowflake;
highlight_until: float64;
#scope_export

search_history: [..]string; // recent searches, newest first (owned; settings.json keeps them)
SEARCH_HISTORY_MAX :: 5;

jump_to_message :: (channel_id: dc.Snowflake, message_id: dc.Snowflake) {
	s := store();
	ch := dc.channel_get(s, channel_id);
	if ch == null { return; }
	if app.view.channel != channel_id { select_channel(ch.guild_id, channel_id); }
	jump = .{channel = channel_id, message = message_id};
	loaded := false;
	l := table_find_pointer(*s.messages, channel_id);
	if l for m: l.messages if m.id == message_id {
		loaded = true;
		if l.gap_after && m.id > l.gap_after dc.drop_jumped_stretch(s, l); // stored on the present side
	}
	if !loaded && app.client != null {
		dc.fetch_messages_around(app.client, channel_id, message_id);
		jump.requested = true;
	}
	highlight_id = message_id;
	highlight_until = app.ui.time + 2.5;
}

// Called by the message list before it settles the scroll: steer
// scroll_target so the jump target sits in the middle of the viewport.
// Centers the jumped-to message, estimating unmeasured rows as the list does (guess), and keeps steering
// until it and the half view below it are measured and the target has held for a few frames.
jump_apply :: (channel_id: dc.Snowflake, cs: *Chat_State, msgs: []dc.Message, view_h: float32, bottom_pad: float32, guess: float32) {
	if jump.channel != channel_id || jump.message == 0 { return; }
	idx := -1;
	for m, i: msgs { if m.id == jump.message { idx = i; } }
	jump.frames += 1;
	if idx < 0 {
		// not loaded yet (around= in flight); give up after a while
		if jump.frames > 600 { jump = .{}; }
		return;
	}
	below := bottom_pad;
	measured := true;
	for i: idx + 1..msgs.count-1 {
		ok, h := table_find(*cs.heights, msgs[i].id);
		if !ok && below < view_h / 2 measured = false;
		below += ifx ok then h else guess;
	}
	ok, h := table_find(*cs.heights, msgs[idx].id);
	if !ok { h = guess; measured = false; }
	target := max(0.0, below + h / 2 - view_h / 2);
	jump.settled = ifx measured && abs(target - cs.scroll_target) < 0.5 then jump.settled + 1 else 0;
	cs.scroll_target = target;
	app.ui.animating = true;
	if jump.settled > 3 || jump.frames > 240 { jump = .{}; }
}

// A jump still placing its message (the list must not shift the scroll under it).
jump_steering :: (channel_id: dc.Snowflake) -> bool { return jump.channel == channel_id && jump.message != 0; }

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
	title := L("Search Options");
	s := store();
	if begins_with(last, "from:") || begins_with(last, "mentions:") {
		prefix := ifx begins_with(last, "from:") then "from:" else "mentions:";
		q := to_lower_copy(advance(last, prefix.count),, temp);
		title = ifx prefix == "from:" then L("From User") else L("Mentions User");
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
		title = L("Message Contains");
		for h: string.["link", "embed", "poll", "file", "video", "image", "sound", "sticker", "forward"] {
			if begins_with(h, advance(last, 4)) { array_add(*items, .{h, "", tprint("has:% ", h)}); }
		}
	} else if begins_with(last, "in:") {
		title = L("In Channel");
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
		array_add(*items, .{"from:", L("user"), "from:"});
		array_add(*items, .{"mentions:", L("user"), "mentions:"});
		array_add(*items, .{"has:", L("link, embed or file"), "has:"});
		array_add(*items, .{"in:", L("channel"), "in:"});
		array_add(*items, .{"pinned:", L("true or false"), "pinned:true "});
		array_add(*items, .{"before:", L("specific date"), "before:"});
		array_add(*items, .{"during:", L("specific date"), "during:"});
		array_add(*items, .{"after:", L("specific date"), "after:"});
	}
	history := last == "" && text == "" && search_history.count > 0; // the client's History section under the options
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
		if history {
			spacer(.Y, 8);
			hr := row("histhdr");
			hr.semantic_size = .[ui.pct(1), ui.px(24)];
			run := "";
			{ ui.parent(hr); defer ui.pop_parent();
				label(L("History"), .Semibold, 12, T("--text-muted"), 24);
				filler(.X);
				cl := ui.box(L("Clear##histclear"), .Clickable | .Draw_Text);
				cl.semantic_size = .[ui.text_size(), ui.px(24)];
				cl.style.font = F(.Medium);
				cl.style.font_size = 12;
				cs := ui.signal(cl);
				cl.style.text_color = ifx cs.hovering then T("--text-strong") else T("--text-muted");
				cl.hover_cursor = .Pointer;
				if cs.clicked { for search_history free(it); array_reset(*search_history); }
			}
			for q, i: search_history {
				ir := row(tprint("h%", i), .Clickable | .Draw_Background | .Hot_Animation);
				ir.semantic_size = .[ui.pct(1), ui.px(32)];
				ir.style.radius = all4(4);
				ir.style.bg_hot = T("--background-mod-subtle");
				if ui.signal(ir).clicked run = q;
				ui.parent(ir); defer ui.pop_parent();
				spacer(.X, 8);
				icon("ic", "clock", 16, T("--text-muted"));
				spacer(.X, 8);
				label(ellipsize(q, .Medium, 14, W - 60), .Medium, 14, T("--text-default"), 18);
			}
			if run {
				q := copy_string(run,, temp);
				ui.editor_set_text(*search.editor, q);
				search_run(ch, q);
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
	sort_results();
	app.ui.animating = true;
}

search_panel_open :: () -> bool {return search.active;}

// Results panel (replaces the member list while a search is active).
search_panel :: () {
	s := store();
	p := ui.box("searchpanel", .Draw_Background);
	p.semantic_size = .[ui.px(SEARCH_PANEL_W), ui.pct(1)];
	p.layout_axis = .Y;
	p.style.bg = T("--background-base-low");
	{ ui.parent(p); defer ui.pop_parent();
		// official .searchResultsWrap: left border only (1px --app-frame-border)
		edge := ui.box("edge", .Draw_Background | .Floating_X | .Floating_Y);
		edge.semantic_size = .[ui.px(1), ui.pct(1)];
		edge.style.bg = T("--app-frame-border");
		hdr := row("hdr");
		hdr.semantic_size = .[ui.pct(1), ui.px(48)];
		{ ui.parent(hdr); defer ui.pop_parent();
			spacer(.X, 16);
			txt := ifx search.loading then L("Searching...") else tprint(Lp("% Result", "% Results", search.total), search.total);
			label(txt, .Semibold, 16, T("--text-strong"), 20);
			filler(.X);
			// Newest / Oldest / Most Relevant: the search again in that order
			for name, k: string.[L("Newest"), L("Oldest"), L("Relevant")] {
				sel := cast(int) search.sort == k;
				b := ui.box(tprint("%##sort%", name, k), .Clickable | .Draw_Text | .Hot_Animation);
				b.semantic_size = .[ui.text_size(4), ui.px(20)];
				b.style.font = F(ifx sel then .Semibold else .Medium);
				b.style.font_size = 13;
				bs := ui.signal(b);
				b.style.text_color = ifx sel then T("--text-strong") else ifx bs.hovering then T("--interactive-text-hover") else T("--text-muted");
				b.hover_cursor = .Pointer;
				if bs.clicked && !sel {
					search.sort = cast(dc.Search_Sort) k;
					search.sq.sort, search.sq.offset, search.offset = search.sort, 0, 0;
					search.seq += 1;
					search.loading = app.client != null;
					ch := dc.channel_get(s, app.view.channel);
					if app.client != null && ch dc.search_messages(app.client, ch.guild_id, ch.id, search.sq, search.seq);
				}
			}
			spacer(.X, 8);
			x := ui.box("close", .Clickable);
			x.semantic_size = .[ui.px(24), ui.px(24)];
			if ui.signal(x).clicked { search.active = false; }
			set_icon(x, "x-large", T("--interactive-icon-default"));
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
					label(L("No results found"), .Medium, 14, T("--text-muted"), 18);
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
	for search_history free(it);
	array_reset(*search_history);
}
search_state_for_test :: () -> string {return tprint("% % % %", search.active, search.focused, search.query, jump.message);}

#scope_file

sugg_rect: ui.Rect;

in_suggestions :: (p: ui.Vec2) -> bool {return rect_has(sugg_rect, p);}

rect_has :: (r: ui.Rect, p: ui.Vec2) -> bool {return p.x >= r.x0 && p.x < r.x1 && p.y >= r.y0 && p.y < r.y1;}

search_run :: (ch: *dc.Channel, text: string) {
	if text == "" { return; }
	// the history: this search first, once
	for search_history if it == text { free(it); remove it; }
	array_insert_at(*search_history, copy_string(text), 0);
	while search_history.count > SEARCH_HISTORY_MAX { free(pop(*search_history)); }
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
	min_id, max_id: dc.Snowflake;
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
		} else if begins_with(tok, "before:") || begins_with(tok, "after:") || begins_with(tok, "during:") || begins_with(tok, "on:") {
			// a local date: before its midnight, after its end, or during that day (min_id / max_id)
			colon := find_index_from_left(tok, #char ":");
			day, ok := parse_local_time(advance(tok, colon + 1), "12am");
			if ok {
				start := dc.snowflake_from_ms(day * 1000);
				next := dc.snowflake_from_ms(unix_from_local_ms(local_ms(day * 1000) + 86_400_000));
				if begins_with(tok, "before:") max_id = start;
				else if begins_with(tok, "after:") min_id = next;
				else { min_id = start; max_id = next; }
			} else {
				array_add(*content, tok);
			}
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
		pinned = pinned,
		min_id = min_id,
		max_id = max_id,
		sort = search.sort
	};
	search.seq += 1;
	search.loading = app.client != null;
	if app.client != null { dc.search_messages(app.client, ch.guild_id, ch.id, search.sq, search.seq); }
	// The carrier holds only ciphertext, so a DM's encrypted texts are searched here too, for plain words.
	plain := !authors.count && !mentions.count && !has.count && !chans.count && !pinned && !min_id && !max_id;
	if plain encrypted_search(ch, search.sq.content);
}

#scope_export

// search_add_decrypted puts an encrypted DM's matching texts (encrypted_search) among the results, in
// the results' order, for the first page of the search they were asked for.
search_add_decrypted :: (r: *e2e.Request) {
	if !search.active || search.offset != 0 || r.text != search.sq.content || dc.parse_snowflake(r.conv.id) != search.scope || !r.hits.count return;
	a := dc.pool_allocator(*search.pool);
	for r.hits {
		m: dc.Message;
		m.id, m.channel_id, m.author_id = dc.parse_snowflake(it.delivery), search.scope, dc.parse_snowflake(it.author);
		m.content = copy_string(it.text,, a);
		array_add(*search.results, .{msg = m});
	}
	search.total += r.hits.count;
	sort_results();
	app.ui.animating = true;
}

#scope_file

// sort_results keeps the carrier's results and the decrypted ones in one order, whichever came first.
sort_results :: () {
	if search.sort == .Oldest quick_sort(search.results, (x: Result, y: Result) -> int { return ifx x.msg.id < y.msg.id then -1 else ifx x.msg.id > y.msg.id then 1 else 0; });
	else if search.sort == .Newest quick_sort(search.results, (x: Result, y: Result) -> int { return ifx x.msg.id > y.msg.id then -1 else ifx x.msg.id < y.msg.id then 1 else 0; });
}


