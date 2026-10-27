// Cmd+K quick switcher: fuzzy search over DMs, channels and servers.

Switcher :: struct {
	open: bool;
	editor: ui.Editor;
	sel: int;
	t: float32;
}

sw: Switcher;

Switch_Kind :: enum u8 {
	Channel;
	DM;
	Guild;
}

Switch_Item :: struct {
	kind: Switch_Kind;
	id: dc.Snowflake; // channel or guild
	guild: dc.Snowflake;
	name: string;
	sub: string;
	score: int;
}

// Subsequence match with bonuses for prefix and word starts; -1 = no match.
fuzzy_score :: (query: string, text: string) -> int {
	if query == "" { return 1; }
	q := to_lower_copy(query,, temp);
	t := to_lower_copy(text,, temp);
	if begins_with(t, q) { return 1000 - t.count; }
	i := find_index_from_left(t, q);
	if i >= 0 { return 500 - i; }
	score := 0;
	ti := 0;
	for qi: 0..q.count-1 {
		found := false;
		while ti < t.count {
			if t[ti] == q[qi] {
				score += ifx (ti == 0 || t[ti - 1] == #char " " || t[ti - 1] == #char "-") then 10 else 1;
				ti += 1;
				found = true;
				break;
			}
			ti += 1;
		}
		if !found { return -1; }
	}
	return score;
}

switcher_toggle :: () {
	sw.open = !sw.open;
	sw.t = 0;
	sw.sel = 0;
	ui.editor_set_text(*sw.editor, "");
}

// The 12 best matches, best first; equal scores keep DMs, servers, channels order (a stable sort's top 12).
switcher_items :: (query: string) -> []Switch_Item {
	MAX :: 12;
	top: [..]Switch_Item;
	top.allocator = temp;
	array_reserve(*top, MAX + 1);
	add :: (top: *[..]Switch_Item, item: Switch_Item) {
		if item.score < 0 { return; }
		at := top.count;
		while at > 0 && top.*[at - 1].score < item.score { at -= 1; }
		if at >= MAX { return; }
		array_insert_at(top, item, at);
		if top.count > MAX { top.count = MAX; }
	}
	s := store();
	for cid: s.private_channels {
		ch := dc.channel_get(s, cid);
		if ch == null { continue; }
		name := dm_name(ch);
		sc := fuzzy_score(query, name);
		add(*top, .{kind = .DM, id = cid, name = name, score = ifx sc >= 0 then sc + 5 else -1});
	}
	for gid: guild_order() {
		g := dc.guild_get(s, gid);
		if g == null { continue; }
		if query != "" { add(*top, .{kind = .Guild, id = gid, name = g.name, score = fuzzy_score(query, g.name)}); }
		for cid: dc.guild_channels_sorted(s, gid) {
			ch := dc.channel_get(s, cid);
			if ch == null || ch.kind == .Guild_Category { continue; }
			sc := fuzzy_score(query, ch.name);
			add(*top, .{kind = .Channel, id = cid, guild = gid, name = ch.name, sub = g.name, score = ifx sc >= 0 then sc + (ifx dc.channel_unread(s, cid) then 3 else 0) else -1});
		}
	}
	return top;
}

switcher_activate :: (item: Switch_Item) {
	if item.kind == {
	case .DM;
		select_channel(0, item.id);
	case .Channel;
		select_channel(item.guild, item.id);
	case .Guild;
		select_guild(item.id);
	}

	sw.open = false;
}

quick_switcher :: () {
	ui.animate(*sw.t, 1, 30);
	scrim := ui.box("sw_scrim", .Draw_Background | .Clickable | .Floating_X | .Floating_Y | .Overlay);
	scrim.semantic_size = .[ui.px(app.ui.window.x), ui.px(app.ui.window.y)];
	scrim.style.bg = .{0, 0, 0, 0.7 * sw.t};
	if ui.signal(scrim).clicked {
		sw.open = false;
		return;
	}
	query := trim(ui.editor_text(*sw.editor));
	items := switcher_items(query);
	sw.sel = clamp(sw.sel, 0, max(items.count - 1, 0));
	for * e: app.ui.events {
		if e.kind != .Key_Down || e.consumed { continue; }
		if e.key == {
		case .Down;
			sw.sel = min(sw.sel + 1, items.count - 1);
			e.consumed = true;
		case .Up;
			sw.sel = max(sw.sel - 1, 0);
			e.consumed = true;
		case .Escape;
			sw.open = false;
			e.consumed = true;
		}
	}
	W :: 570;
	box := ui.box("switcher", .Draw_Background | .Draw_Shadow | .Floating_X | .Floating_Y | .Overlay | .Clickable);
	box.semantic_size = .[ui.px(W), ui.children()];
	box.fixed_pos = .{(app.ui.window.x - W) / 2, app.ui.window.y * 0.2 - (1 - sw.t) * 8};
	box.opacity = sw.t;
	box.layout_axis = .Y;
	box.style.bg = T("--modal-background");
	box.style.radius = all4(8);
	box.style.shadow_color = .{0, 0, 0, 0.3};
	box.style.shadow_blur = 24;
	ui.signal(box);
	{ ui.parent(box); defer ui.pop_parent();
		spacer(.Y, 20);
		r := row("inrow");
		r.semantic_size = .[ui.pct(1), ui.px(70)];
		{ ui.parent(r); defer ui.pop_parent();
			spacer(.X, 20);
			field := row("field", .Draw_Background);
			field.semantic_size = .[ui.fill(), ui.px(70)];
			field.style.bg = T("--input-background-default");
			field.style.radius = all4(4);
			{ ui.parent(field); defer ui.pop_parent();
				spacer(.X, 12);
				res := text_field("q", *sw.editor, "Where would you like to go?", true, 24, 30);
				if res == .Submit && items.count > 0 { switcher_activate(items[sw.sel]); }
				if res == .Changed { sw.sel = 0; }
				spacer(.X, 12);
			}
			spacer(.X, 20);
		}
		spacer(.Y, 12);
		for item, i: items {
			ir := row(tprint("it%", i), .Clickable | .Draw_Background);
			ir.semantic_size = .[ui.pct(1), ui.px(34)];
			sig := ui.signal(ir);
			if sig.hovering && app.ui.mouse != app.ui.mouse_prev { sw.sel = i; }
			sel := i == sw.sel;
			if sel { ir.style.bg = T("--background-mod-normal"); }
			if sig.clicked { switcher_activate(item); }
			{ ui.parent(ir); defer ui.pop_parent();
				spacer(.X, 28);
				if item.kind == {
				case .DM;
					ch := dc.channel_get(store(), item.id);
					if ch != null && ch.kind == .DM && ch.recipient_ids.count > 0 { avatar_box("av", ch.recipient_ids[0], 20); } else if ch != null { group_dm_icon("ic", ch, 20); }
				case .Channel;
					ch := dc.channel_get(store(), item.id);
					icon("ic", ifx ch != null then channel_icon_name(ch) else "text", 20, T("--interactive-icon-default"));
				case .Guild;
					icon("ic", "server", 20, T("--interactive-icon-default"));
				}
				spacer(.X, 8);
				label(item.name, .Medium, 16, ifx sel then T("--interactive-text-active") else T("--interactive-text-default"), 20);
				if item.sub != "" {
					filler(.X);
					label(item.sub, .Semibold, 12, T("--text-muted"), 16);
				}
				spacer(.X, 28);
			}
		}
		spacer(.Y, 20);
	}
}

