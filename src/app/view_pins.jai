// Pinned messages popout (header pin icon), like the client's: 420px wide,
// anchored under the icon, newest pin first; loads 25 at a time
// (GET /channels/{id}/messages/pins?limit=25&before=<pinned_at>) and acks pins
// when opened (POST /channels/{id}/pins/ack). Re-fetched when a
// CHANNEL_PINS_UPDATE arrives for the channel.

pins_toggle :: (channel_id: dc.Snowflake, anchor: ui.Rect) {
	if pins.open && pins.channel == channel_id {
		pins.open = false;
		return;
	}
	pins.open = true;
	pins.anchor = anchor;
	if pins.channel != channel_id || pins.epoch != dc.pins_epoch(channel_id) pins_reload(channel_id);
	if app.client dc.ack_pins(app.client, channel_id);
}

pins_receive :: (r: *dc.Feature_Result) {
	if r.channel_id != pins.channel return;
	pins.loading = false;
	if !r.ok return;
	alloc := dc.pool_allocator(*pins.pool);
	pins.items.allocator = alloc;
	body := dc.vmap(r.body);
	for dc.flist(body, "items") {
		im := dc.vmap(it);
		array_add(*pins.items, .{pinned_at = copy_string(dc.fstr(im, "pinned_at"),, alloc), msg = dc.parse_loose_message(store(), dc.fmap(im, "message"), alloc)});
	}
	pins.has_more = dc.fbool(body, "has_more");
	app.ui.animating = true;
}

pins_popout :: () {
	if !pins.open return;
	if pins.channel != app.view.channel {
		pins.open = false;
		return;
	}
	if pins.epoch != dc.pins_epoch(pins.channel) pins_reload(pins.channel);
	W :: 420;
	scrim := ui.box("pins_scrim", .Clickable | .Floating_X | .Floating_Y | .Overlay);
	scrim.semantic_size = .[ui.px(app.ui.window.x), ui.px(app.ui.window.y)];
	if ui.signal(scrim).clicked {
		pins.open = false;
		return;
	}
	for * e: app.ui.events {
		if !e.consumed && e.kind == .Key_Down && e.key == .Escape {
			pins.open = false;
			e.consumed = true;
			return;
		}
	}
	x := clamp(pins.anchor.x1 - W, 8, app.ui.window.x - W - 8);
	y := pins.anchor.y1 + 8;
	max_h := min(app.ui.window.y * 0.7, app.ui.window.y - y - 16);
	p := ui.box("pins", .Draw_Background | .Draw_Border | .Draw_Shadow | .Floating_X | .Floating_Y | .Overlay | .Clickable | .Clip);
	p.semantic_size = .[ui.px(W), ui.px(max_h)];
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
	ui.parent(p); defer ui.pop_parent();
	hdr := row("hdr");
	hdr.semantic_size = .[ui.pct(1), ui.px(48)];
	{ ui.parent(hdr); defer ui.pop_parent();
		spacer(.X, 16);
		icon("pin", "pin", 20, T("--interactive-icon-default"));
		spacer(.X, 8);
		label("Pinned Messages", .Semibold, 16, T("--text-strong"), 20);
	}
	line := ui.box("hl", .Draw_Background);
	line.semantic_size = .[ui.pct(1), ui.px(1)];
	line.style.bg = T("--border-subtle");
	list := ui.box("list", .Scroll_Y | .Clip);
	list.semantic_size = .[ui.pct(1), ui.fill()];
	list.layout_axis = .Y;
	sig := ui.signal(list);
	{ ui.parent(list); defer ui.pop_parent();
		spacer(.Y, 8);
		if !pins.items {
			r := row("empty");
			r.semantic_size = .[ui.pct(1), ui.px(80)];
			ui.parent(r); defer ui.pop_parent();
			filler(.X);
			label(ifx pins.loading then "Loading..." else "This channel doesn't have any pinned messages... yet.", .Medium, 14, T("--text-muted"), 18);
			filler(.X);
		}
		for * pins.items {
			ui.id_scope(cast(u64) it_index + 1); defer ui.pop_seed();
			if loose_message_card(*it.msg, .[], true) jump_to_message(it.msg.channel_id, it.msg.id);
		}
		spacer(.Y, 8);
	}
	// load more near the end
	if pins.has_more && !pins.loading && app.client && pins.items && sig.hovering
		&& list.content_size.y > 0 && list.view_off.y + (list.rect.y1 - list.rect.y0) > list.content_size.y - 200 {
		pins.loading = true;
		dc.fetch_pins(app.client, pins.channel, peek(pins.items).pinned_at);
	}
}

// A message outside the channel list (pins, search results): avatar, name,
// time and content; `terms` are highlighted. Returns true when "Jump" was clicked.
loose_message_card :: (m: *dc.Message, terms: []string, show_jump: bool) -> bool {
	jump: bool;
	outer := row("card");
	outer.semantic_size = .[ui.pct(1), ui.children()];
	{ ui.parent(outer); defer ui.pop_parent();
		spacer(.X, 8);
		card := ui.box("c", .Draw_Background | .Draw_Border | .Hot_Animation);
		card.semantic_size = .[ui.fill(), ui.children()];
		card.layout_axis = .Y;
		card.style.bg = T("--background-base-lower");
		card.style.border_color = T("--border-subtle");
		card.style.border = 1;
		card.style.radius = all4(8);
		hovered := ui.mouse_over(card);
		// The popup or panel around the card is clickable too, so only a hot box inside the card (a link,
		// an image) keeps its own right-click.
		hot := ui.box_lookup(app.ui.hot);
		inner := hot && hot.rect.x0 >= card.rect.x0 && hot.rect.y0 >= card.rect.y0 && hot.rect.x1 <= card.rect.x1 && hot.rect.y1 <= card.rect.y1;
		for e: app.ui.events if e.kind == .Mouse_Down && e.button == .Right && hovered && !inner {
			ma.loose, ma.loose_id = m, m.id;
			open_message_menu(m, e.pos, "right_click");
		}
		{ ui.parent(card); defer ui.pop_parent();
			spacer(.Y, 8);
			defer spacer(.Y, 8);
			top := row("top");
			top.semantic_size = .[ui.pct(1), ui.children()];
			top.cross_align = .Start;
			ui.parent(top); defer ui.pop_parent();
			spacer(.X, 12);
			avatar_box("av", m.author_id, 40);
			spacer(.X, 12);
			col := ui.box("col");
			col.semantic_size = .[ui.fill(), ui.children()];
			col.layout_axis = .Y;
			ui.parent(col); defer ui.pop_parent();
			nr := row("name");
			nr.semantic_size = .[ui.pct(1), ui.px(22)];
			{ ui.parent(nr); defer ui.pop_parent();
				label(name_in(m.author_id, m.channel_id, "unknown"), .Medium, 16, author_color(m), 22);
				spacer(.X, 8);
				label(format_timestamp(m.id), .Medium, 12, T("--text-muted"), 22);
				filler(.X);
				if show_jump && hovered {
					jb := row("jump", .Clickable | .Draw_Background | .Hot_Animation);
					jb.semantic_size = .[ui.children(), ui.px(22)];
					jb.style.bg = T("--background-mod-normal");
					jb.style.bg_hot = T("--background-mod-strong");
					jb.style.radius = all4(4);
					if ui.signal(jb).clicked jump = true;
					ui.parent(jb); defer ui.pop_parent();
					spacer(.X, 8);
					label("Jump", .Medium, 12, T("--text-default"), 22);
					spacer(.X, 8);
				}
				spacer(.X, 12);
			}
			card_body(m, terms);
			// media as in the chat, narrowed to the card (its width from the last layout)
			mw := ifx col.rect.x1 > col.rect.x0 then min(400.0, col.rect.x1 - col.rect.x0 - 12) else 300.0;
			if m.sticker_ids message_stickers_view(m);
			if m.attachments attachments_view(m, mw);
			if m.embeds embeds_view(m, mw - 32); // an embed card pads its content 16px each side
		}
		spacer(.X, 8);
	}
	spacer(.Y, 8);
	return jump;
}

// Splits text spans so every case-insensitive occurrence of a term gets the
// keyword highlight background. Hidden spoilers (`tokens_to_spans` draws their
// text in the block's colour) are left alone, so a match can't reveal them.
highlight_spans :: (spans: []ui.Span, terms: []string) -> []ui.Span {
	out: [..]ui.Span;
	out.allocator = temp;
	array_reserve(*out, spans.count);
	for sp: spans {
		if sp.object != .{} || sp.text == "" || (sp.bg.w > 0 && sp.color == sp.bg) {
			array_add(*out, sp);
			continue;
		}
		low := to_lower_copy(sp.text,, temp);
		pos := 0;
		while pos < sp.text.count {
			best, blen := -1, 0;
			for t: terms {
				i := find_index_from_left(low, t, pos); // -1 for ""
				if i >= 0 && (best < 0 || i < best) best, blen = i, t.count;
			}
			if best < 0 break;
			if best > pos {
				a := sp;
				a.text = span(sp.text, pos, best);
				array_add(*out, a);
			}
			h := sp;
			h.text = span(sp.text, best, best + blen);
			h.bg = T("--keyword-highlight-background");
			h.bg_radius = 2;
			array_add(*out, h);
			pos = best + blen;
		}
		if pos < sp.text.count {
			a := sp;
			a.text = span(sp.text, pos, sp.text.count);
			array_add(*out, a);
		}
	}
	return out;
}

pins_reset_for_test :: () {
	fini(*pins.pool);
	pins = .{};
}

pins_state_for_test :: () -> string { return tprint("% %", pins.open, pins.channel); }

#scope_file

Pin :: struct {
	pinned_at: string;
	msg: dc.Message;
}

pins: struct {
	open: bool;
	channel: dc.Snowflake;
	anchor: ui.Rect;
	loading: bool;
	has_more: bool;
	epoch: int;
	items: [..]Pin;
	pool: Flat_Pool; // items and their messages
};

pins_reload :: (channel_id: dc.Snowflake) {
	fini(*pins.pool);
	none: [..]Pin;
	pins.items = none;
	pins.channel = channel_id;
	pins.epoch = dc.pins_epoch(channel_id);
	pins.has_more = false;
	pins.loading = app.client != null;
	if app.client dc.fetch_pins(app.client, channel_id);
}

span :: (s: string, lo: int, hi: int) -> string {
	r := s;
	r.data += lo;
	r.count = hi - lo;
	return r;
}

