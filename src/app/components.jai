// A message's components under its content, laid out like the official client's: action rows of buttons
// (primary, secondary, success, danger, link) and select menus, and Components V2's containers, sections,
// text, thumbnails, galleries, files and separators. A click sends the interaction (dc.send_component_
// interaction): the button waits with dots until the gateway answers, and a failure, or no answer in 15 s,
// shows "This interaction failed". Ephemeral messages say only you can see them, with Dismiss.

INTERACTION_TIMEOUT_MS :: 15_000;

comp_select: struct { msg: dc.Snowflake; index: int; }; // the open select menu

message_components_view :: (m: *dc.Message) {
	cs := m.components;
	st := table_find_pointer(*store().interactions, m.id);
	if st && !st.failed && wall_ms() - st.start_ms > INTERACTION_TIMEOUT_MS st.failed = true;
	spacer(.Y, 4);
	for cs.items if it.parent == -1 {
		ui.id_scope(cast(u64) it_index + 1); defer ui.pop_seed();
		component_view(m, it_index, 1);
	}
	if st && st.failed {
		spacer(.Y, 4);
		r := row("ifail");
		r.semantic_size = .[ui.pct(1), ui.px(18)];
		ui.parent(r); defer ui.pop_parent();
		icon("w", "warning", 14, T("--text-feedback-critical"));
		spacer(.X, 4);
		label(L("This interaction failed"), .Normal, 14, T("--text-feedback-critical"), 18);
	} else if st request_wake(app.ui.time + 1);
}

// "Only you can see this · Dismiss message" under an ephemeral message (flag 1 << 6).
ephemeral_note :: (m: *dc.Message) {
	spacer(.Y, 4);
	r := row("ephemeral");
	r.semantic_size = .[ui.pct(1), ui.px(18)];
	ui.parent(r); defer ui.pop_parent();
	icon("eye", "eye", 14, T("--text-muted"));
	spacer(.X, 4);
	label(L("Only you can see this · "), .Normal, 12, T("--text-muted"), 18);
	d := label(L("Dismiss message"), .Normal, 12, T("--text-link"), 18);
	d.flags |= .Clickable;
	d.hover_cursor = .Pointer;
	if ui.signal(d).clicked dc.drop_message(store(), m.channel_id, m.id);
}

#scope_file

component_children :: (cs: *dc.Components, parent: int) -> []int {
	out: [..]int;
	out.allocator = temp;
	for cs.items if it.parent == parent array_add(*out, it_index);
	return out;
}

// One component and what it holds. depth: the tree level, capped by the parser (options one below).
component_view :: (m: *dc.Message, i: int, depth: int) {
	assert(depth <= dc.MAX_COMPONENT_DEPTH + 1);
	cs := m.components;
	c := *cs.items[i];
	kids := component_children(cs, i);
	if c.kind == {
	case dc.COMP_ACTION_ROW;
		r := row(tprint("row%", i));
		r.semantic_size = .[ui.pct(1), ui.children()];
		r.style.child_gap = 8;
		{ ui.parent(r); defer ui.pop_parent();
			for kids { ui.id_scope(cast(u64) it + 1); defer ui.pop_seed(); component_view(m, it, depth + 1); }
		}
		spacer(.Y, 8);
	case dc.COMP_BUTTON;
		component_button(m, i);
	case dc.COMP_STRING_SELECT; #through;
	case dc.COMP_USER_SELECT; #through;
	case dc.COMP_ROLE_SELECT; #through;
	case dc.COMP_MENTIONABLE_SELECT; #through;
	case dc.COMP_CHANNEL_SELECT;
		component_select(m, i, kids);
	case dc.COMP_TEXT_DISPLAY;
		if c.text markdown_text(m, c.text);
	case dc.COMP_CONTAINER;
		box := row(tprint("ct%", i), .Draw_Background | .Draw_Border);
		box.semantic_size = .[ui.px(min(520.0, max(200.0, app.ui.window.x - 500))), ui.children()];
		box.style.bg = T("--embed-background");
		box.style.border_color = T("--border-subtle");
		box.style.border = 1;
		box.style.radius = all4(8);
		box.cross_align = .Start;
		if c.accent >= 0 {
			// the accent colour as a stripe down the left edge
			col := New(ui.Color,, temp);
			col.* = rgb_u32(cast(u32) c.accent);
			box.custom_user = col;
			box.custom_draw = (b: *ui.Box, user: *void) {
				col := (cast(*ui.Color) user).*;
				gfx.rect(.{b.rect.x0, b.rect.y0, b.rect.x0 + 4, b.rect.y1}, with_alpha(col, col.w * b.opacity), 2);
			};
		}
		{ ui.parent(box); defer ui.pop_parent();
			spacer(.X, 16);
			col := ui.box("col");
			col.semantic_size = .[ui.fill(), ui.children()];
			col.layout_axis = .Y;
			{ ui.parent(col); defer ui.pop_parent();
				spacer(.Y, 16);
				for kids { ui.id_scope(cast(u64) it + 1); defer ui.pop_seed(); component_view(m, it, depth + 1); }
				spacer(.Y, 8);
			}
			spacer(.X, 16);
		}
		spacer(.Y, 8);
	case dc.COMP_SECTION;
		// text on the left, its accessory (the last child: a button or thumbnail) on the right
		r := row(tprint("sec%", i));
		r.semantic_size = .[ui.pct(1), ui.children()];
		r.cross_align = .Start;
		{ ui.parent(r); defer ui.pop_parent();
			col := ui.box("col");
			col.semantic_size = .[ui.fill(), ui.children()];
			col.layout_axis = .Y;
			acc := -1;
			if kids.count && cs.items[peek(kids)].kind != dc.COMP_TEXT_DISPLAY acc = peek(kids);
			{ ui.parent(col); defer ui.pop_parent();
				for kids if it != acc { ui.id_scope(cast(u64) it + 1); defer ui.pop_seed(); component_view(m, it, depth + 1); }
			}
			if acc >= 0 { spacer(.X, 12); ui.id_scope(cast(u64) acc + 1); defer ui.pop_seed(); component_view(m, acc, depth + 1); }
		}
		spacer(.Y, 8);
	case dc.COMP_THUMBNAIL;
		if c.url media_box(tprint("th%", i), c.url, "", 85, 85);
	case dc.COMP_MEDIA_GALLERY;
		r := row(tprint("gal%", i));
		r.semantic_size = .[ui.pct(1), ui.children()];
		r.style.child_gap = 4;
		{ ui.parent(r); defer ui.pop_parent();
			for kids if cs.items[it].url media_box(tprint("g%", it), cs.items[it].url, "", ifx kids.count == 1 then 400.0 else 196.0, ifx kids.count == 1 then 300.0 else 160.0);
		}
		spacer(.Y, 8);
	case dc.COMP_FILE;
		r := row(tprint("file%", i), .Draw_Background | .Draw_Border);
		r.semantic_size = .[ui.px(400), ui.px(56)];
		r.style.bg = T("--embed-background");
		r.style.border_color = T("--border-subtle");
		r.style.border = 1;
		r.style.radius = all4(8);
		{ ui.parent(r); defer ui.pop_parent();
			spacer(.X, 12);
			icon("f", "file", 24, T("--text-muted"));
			spacer(.X, 8);
			name := c.url;
			q := find_index_from_left(name, #char "?");
			if q >= 0 name.count = q;
			slash := find_index_from_right(name, #char "/");
			if slash >= 0 name = advance(name, slash + 1);
			label(ifx name then name else "file", .Medium, 14, T("--text-link"), 18);
		}
		if ui.signal(r).clicked open_url(c.url);
		spacer(.Y, 8);
	case dc.COMP_SEPARATOR;
		gap := ifx c.spacing == 2 then 16.0 else 8.0;
		spacer(.Y, gap);
		if c.divider {
			l := ui.box(tprint("sep%", i), .Draw_Background);
			l.semantic_size = .[ui.pct(1), ui.px(1)];
			l.style.bg = T("--border-subtle");
		}
		spacer(.Y, gap);
	}
}

component_button :: (m: *dc.Message, i: int) {
	c := *m.components.items[i];
	st := table_find_pointer(*store().interactions, m.id);
	pending := st && !st.failed && st.index == i;
	link := c.style == dc.BUTTON_LINK;
	enabled := !c.disabled && !pending && (link || !(st && !st.failed));
	bg := T("--background-mod-strong");
	fg := T("--text-strong");
	if c.style == {
		case 1; bg, fg = T("--background-brand"), .{1, 1, 1, 1};
		case 3; bg, fg = T("--status-positive"), .{1, 1, 1, 1};
		case 4; bg, fg = T("--status-danger"), .{1, 1, 1, 1};
	}
	b := row(tprint("btn%", i), ifx enabled then .Clickable | .Draw_Background | .Hot_Animation else .Draw_Background);
	b.semantic_size = .[ui.children(), ui.px(32)];
	b.style.radius = all4(8);
	b.style.bg = ifx c.disabled then with_alpha(bg, 0.5) else bg;
	b.style.bg_hot = with_alpha(bg, 0.85);
	b.hover_cursor = ifx enabled then .Pointer else .Default;
	b.cross_align = .Center;
	{ ui.parent(b); defer ui.pop_parent();
		spacer(.X, 16);
		col := ifx c.disabled then with_alpha(fg, 0.5) else fg;
		if pending pulsing_dots(col);
		else {
			if c.emoji { label(c.emoji, .Normal, 16, col, 20); if c.label spacer(.X, 6); }
			if c.label label(c.label, .Medium, 14, col, 18);
			if link { spacer(.X, 6); icon("ext", "link-external-small", 16, col); }
		}
		spacer(.X, 16);
	}
	if !enabled || !ui.signal(b).clicked return;
	if link { open_url(c.url); return; }
	ch := dc.channel_get(store(), m.channel_id);
	if net_action() dc.send_component_interaction(app.client, m, ifx ch then ch.guild_id else 0, i);
}

component_select :: (m: *dc.Message, i: int, options: []int) {
	c := *m.components.items[i];
	cs := m.components;
	strings := c.kind == dc.COMP_STRING_SELECT;
	st := table_find_pointer(*store().interactions, m.id);
	pending := st && !st.failed && st.index == i;
	enabled := strings && !c.disabled && !pending;
	open := comp_select.msg == m.id && comp_select.index == i;
	W :: 400.0;
	wrap := ui.box(tprint("selw%", i)); // the menu over its options
	wrap.semantic_size = .[ui.children(), ui.children()];
	wrap.layout_axis = .Y;
	ui.parent(wrap); defer ui.pop_parent();
	b := row(tprint("sel%", i), ifx enabled then .Clickable | .Draw_Background | .Draw_Border else .Draw_Background | .Draw_Border);
	b.semantic_size = .[ui.px(W), ui.px(40)];
	b.style.bg = T("--input-background-default");
	b.style.border_color = ifx open then T("--input-border-active") else T("--input-border-default");
	b.style.border = 1;
	b.style.radius = all4(8);
	b.hover_cursor = ifx enabled then .Pointer else .Default;
	{ ui.parent(b); defer ui.pop_parent();
		spacer(.X, 12);
		if pending pulsing_dots(T("--text-muted"));
		else label(ifx c.placeholder then c.placeholder else L("Make a selection"), .Normal, 14, ifx enabled then T("--text-muted") else with_alpha(T("--text-muted"), 0.5), 18);
		filler(.X);
		icon("chev", ifx open then "chevron-small-up" else "chevron-small-down", 20, T("--interactive-icon-default"));
		spacer(.X, 8);
	}
	if enabled && ui.signal(b).clicked {
		comp_select.msg, comp_select.index = ifx open then 0 else m.id, i;
		open = !open;
	}
	if !open return;
	// the options under it, in the flow (the client floats them; this keeps the list on screen)
	list := ui.box(tprint("opts%", i), .Draw_Background | .Draw_Border);
	list.semantic_size = .[ui.px(W), ui.children()];
	list.layout_axis = .Y;
	list.style.bg = T("--background-surface-higher");
	list.style.border_color = T("--border-subtle");
	list.style.border = 1;
	list.style.radius = all4(8);
	ui.parent(list); defer ui.pop_parent();
	for o: options {
		op := *cs.items[o];
		r := row(tprint("o%", o), .Clickable | .Draw_Background | .Hot_Animation);
		r.semantic_size = .[ui.pct(1), ui.px(ifx op.text then 52.0 else 40.0)];
		r.style.bg_hot = T("--background-mod-normal");
		r.hover_cursor = .Pointer;
		{ ui.parent(r); defer ui.pop_parent();
			spacer(.X, 12);
			if op.emoji { label(op.emoji, .Normal, 18, T("--text-default"), 22); spacer(.X, 8); }
			col := ui.box("c");
			col.semantic_size = .[ui.fill(), ui.children()];
			col.layout_axis = .Y;
			{ ui.parent(col); defer ui.pop_parent();
				label(op.label, .Medium, 14, T("--text-strong"), 18);
				if op.text label(op.text, .Normal, 12, T("--text-muted"), 16);
			}
		}
		if ui.signal(r).clicked {
			comp_select.msg = 0;
			ch := dc.channel_get(store(), m.channel_id);
			if net_action() dc.send_component_interaction(app.client, m, ifx ch then ch.guild_id else 0, i, .[op.custom_id]);
		}
	}
}
