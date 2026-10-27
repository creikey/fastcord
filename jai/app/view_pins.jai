#scope_file

// Pinned messages popout (header pin icon), like the client's: 420px wide,
// anchored under the icon, newest pin first; loads 25 at a time
// (GET /channels/{id}/messages/pins?limit=25&before=<pinned_at>) and acks pins
// when opened (POST /channels/{id}/pins/ack). Re-fetched when a
// CHANNEL_PINS_UPDATE arrives for the channel.

Pin :: struct {
	pinned_at: string;
	msg: dc.Message;
}

Pins_State :: struct {
	open: bool;
	channel: dc.Snowflake;
	anchor: ui.Rect;
	loading: bool;
	has_more: bool;
	epoch: int;
	items: [..]Pin;
	arena: virtual.Arena;
	scroll: float32;
}

pins: Pins_State;
#scope_export

pins_toggle :: (channel_id: dc.Snowflake, anchor: ui.Rect) {
	if pins.open && pins.channel == channel_id {
		pins.open = false;
		return;
	}
	pins.open = true;
	pins.anchor = anchor;
	if pins.channel != channel_id || pins.epoch != dc.pins_epoch(channel_id) { pins_reload(channel_id); }
	if app.client != null { dc.ack_pins(app.client, channel_id); }
}
#scope_file

pins_reload :: (channel_id: dc.Snowflake) {
	virtual.arena_destroy(*pins.arena);
	pins.arena = .{};
	pins.items = .{};
	pins.channel = channel_id;
	pins.epoch = dc.pins_epoch(channel_id);
	pins.has_more = false;
	pins.loading = app.client != null;
	if app.client != null { dc.fetch_pins(app.client, channel_id); }
}
#scope_export

pins_receive :: (r: *dc.Feature_Result) {
	if r.channel_id != pins.channel { return; }
	pins.loading = false;
	if !r.ok { return; }
	if pins.items == null {
		if virtual.arena_init_growing(*pins.arena) != null { return; }
		pins.items = make_dynamic(Pin, 0, 0, virtual.arena_allocator(*pins.arena));
	}
	alloc := virtual.arena_allocator(*pins.arena);
	body := dc.vmap(r.body);
	for iv: dc.flist(body, "items") {
		im := dc.vmap(iv);
		append(*pins.items, Pin.{pinned_at = clone(dc.fstr(im, "pinned_at"), alloc), msg = dc.parse_loose_message(store(), dc.fmap(im, "message"), alloc)});
	}
	pins.has_more = dc.fbool(body, "has_more");
	app.ui.animating = true;
}

pins_popout :: () {
	if !pins.open { return; }
	if pins.channel != app.view.channel {
		pins.open = false;
		return;
	}
	if pins.epoch != dc.pins_epoch(pins.channel) { pins_reload(pins.channel); }
	W :: 420;
	scrim := ui.box("pins_scrim", .{.Clickable, .Floating_X, .Floating_Y, .Overlay});
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
	p := ui.box("pins", .{.Draw_Background, .Draw_Border, .Draw_Shadow, .Floating_X, .Floating_Y, .Overlay, .Clickable, .Clip});
	p.semantic_size = .[ui.px(W), ui.px(max_h)];
	p.fixed_pos = .{x, y};
	p.layout_axis = .Y;
	p.style.bg = cast(T)("--background-surface-high");
	p.style.border_color = cast(T)("--border-subtle");
	p.style.border = 1;
	p.style.radius = 8;
	p.style.shadow_color = .{0, 0, 0, 0.35};
	p.style.shadow_blur = 16;
	p.style.shadow_offset = .{0, 8};
	ui.signal(p);
	if ui.parent(p) {
		hdr := row("hdr");
		hdr.semantic_size = .[ui.pct(1), ui.px(48)];
		if ui.parent(hdr) {
			spacer(.X, 16);
			icon("pin", "pin", 20, cast(T)("--interactive-icon-default"));
			spacer(.X, 8);
			label("Pinned Messages", .Semibold, 16, cast(T)("--text-strong"), 20);
		}
		line := ui.box("hl", .{.Draw_Background});
		line.semantic_size = .[ui.pct(1), ui.px(1)];
		line.style.bg = cast(T)("--border-subtle");
		list := ui.box("list", .{.Scroll_Y, .Clip});
		list.semantic_size = .[ui.pct(1), ui.fill()];
		list.layout_axis = .Y;
		sig := ui.signal(list);
		if ui.parent(list) {
			spacer(.Y, 8);
			if len(pins.items) == 0 {
				r := row("empty");
				r.semantic_size = .[ui.pct(1), ui.px(80)];
				if ui.parent(r) {
					filler(.X);
					label(ifx pins.loading then "Loading..." else "This channel doesn't have any pinned messages... yet.", .Medium, 14, cast(T)("--text-muted"), 18);
					filler(.X);
				}
			}
			for * pin, i: pins.items {
				if ui.id_scope(cast(u64)(i + 1)) {
					if loose_message_card(*pin.msg, null, true) { jump_to_message(pin.msg.channel_id, pin.msg.id); }
				}
			}
			spacer(.Y, 8);
		}
		// load more near the end
		if pins.has_more && !pins.loading && app.client != null && len(pins.items) > 0 && sig.hovering {
			if list.content_size.y > 0 && list.view_off.y + (list.rect.y1 - list.rect.y0) > list.content_size.y - 200 {
				pins.loading = true;
				dc.fetch_pins(app.client, pins.channel, pins.items[len(pins.items) - 1].pinned_at);
			}
		}
	}
}

// A message outside the channel list (pins, search results): avatar, name,
// time and content; `terms` are highlighted. Returns true when "Jump" was clicked.
loose_message_card :: (m: *dc.Message, terms: []string, show_jump: bool) -> bool {
	jump: bool;
	outer := row("card");
	outer.semantic_size = .[ui.pct(1), ui.children()];
	if ui.parent(outer) {
		spacer(.X, 8);
		card := ui.box("c", .{.Draw_Background, .Draw_Border, .Hot_Animation});
		card.semantic_size = .[ui.fill(), ui.children()];
		card.layout_axis = .Y;
		card.style.bg = cast(T)("--background-base-lower");
		card.style.border_color = cast(T)("--border-subtle");
		card.style.border = 1;
		card.style.radius = 8;
		hovered := ui.mouse_over(card);
		if ui.parent(card) {
			spacer(.Y, 8);
			defer spacer(.Y, 8);
			top := row("top");
			top.semantic_size = .[ui.pct(1), ui.children()];
			top.cross_align = .Start;
			if ui.parent(top) {
				spacer(.X, 12);
				avatar_box("av", m.author_id, 40);
				spacer(.X, 12);
				col := ui.box("col");
				col.semantic_size = .[ui.fill(), ui.children()];
				col.layout_axis = .Y;
				if ui.parent(col) {
					nr := row("name");
					nr.semantic_size = .[ui.pct(1), ui.px(22)];
					if ui.parent(nr) {
						label(name_in(m.author_id, m.channel_id, "unknown"), .Medium, 16, author_color(m), 22);
						spacer(.X, 8);
						label(format_timestamp(m.id), .Medium, 12, cast(T)("--text-muted"), 22);
						filler(.X);
						if show_jump && hovered {
							jb := row("jump", .{.Clickable, .Draw_Background, .Hot_Animation});
							jb.semantic_size = .[ui.children(), ui.px(22)];
							jb.style.bg = cast(T)("--background-mod-normal");
							jb.style.bg_hot = cast(T)("--background-mod-strong");
							jb.style.radius = 4;
							if ui.signal(jb).clicked { jump = true; }
							if ui.parent(jb) {
								spacer(.X, 8);
								label("Jump", .Medium, 12, cast(T)("--text-default"), 22);
								spacer(.X, 8);
							}
						}
						spacer(.X, 12);
					}
					content_spans(m, terms);
					for a, ai: m.attachments {
						lr := row(fmt.tprintf("att%d", ai));
						lr.semantic_size = .[ui.pct(1), ui.px(20)];
						if ui.parent(lr) {
							icon("i", "attachment", 16, cast(T)("--text-muted"));
							spacer(.X, 4);
							label(a.filename, .Normal, 14, cast(T)("--text-link"), 18);
						}
					}
				}
			}
		}
		spacer(.X, 8);
	}
	spacer(.Y, 8);
	return jump;
}
#scope_file

// Message content as wrapped rich text with search terms highlighted.
content_spans :: (m: *dc.Message, terms: []string) {
	if m.content == "" { return; }
	blocks := md_parse(m.content);
	for blk, bi: blocks {
		b := ui.box(fmt.tprintf("p%d", bi), .{.Selectable_Text, .Wrap_Text});
		b.semantic_size = .[ui.pct(1), ui.text_size()];
		b.style.text_color = cast(T)("--text-default");
		b.style.line_height = 20;
		spans: []ui.Span;
		if blk.kind == .Code_Block {
			spans = make_slice(ui.Span, 1, temp);
			spans[0] = .{text = blk.code, font = F(.Mono), size = 13};
		} else {
			spans = tokens_to_spans(blk.tokens, .Normal, 15, m);
		}
		if len(terms) > 0 { spans = highlight_spans(spans, terms); }
		ui.set_spans(b, spans);
		b.sel_order = cast(u64)(m.id) * 8 + 2 + cast(u64)(bi) % 4;
	}
}
#scope_export

// Splits text spans so every case-insensitive occurrence of a term gets the
// keyword highlight background.
highlight_spans :: (spans: []ui.Span, terms: []string) -> []ui.Span {
	out := make_dynamic(ui.Span, 0, len(spans), temp);
	for sp: spans {
		if sp.object != .{} || sp.text == "" {
			append(*out, sp);
			continue;
		}
		low := strings.to_lower(sp.text, temp);
		pos := 0;
		while pos < len(sp.text) {
			best, blen := -1, 0;
			for t: terms {
				if t == "" { continue; }
				{ i := strings.index(sub_from(low, pos), t);
				if i >= 0 && (best < 0 || i < best) {
					best = i;
					blen = len(t);
				} }
			}
			if best < 0 { break; }
			if best > 0 {
				a := sp;
				a.text = sub(sp.text, pos, pos + best);
				append(*out, a);
			}
			h := sp;
			h.text = sub(sp.text, pos + best, pos + best + blen);
			h.bg = cast(T)("--keyword-highlight-background");
			h.bg_radius = 2;
			append(*out, h);
			pos += best + blen;
		}
		if pos < len(sp.text) {
			a := sp;
			a.text = sub_from(sp.text, pos);
			append(*out, a);
		}
	}
	return view(out);
}

pins_reset_for_test :: () {
	virtual.arena_destroy(*pins.arena);
	pins = .{};
}
pins_state_for_test :: () -> string {return fmt.tprint(pins.open, pins.channel);}

