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
	q := strings.to_lower(query, temp);
	t := strings.to_lower(text, temp);
	if strings.has_prefix(t, q) { return 1000 - len(t); }
	{ i := strings.index(t, q);
	if i >= 0 { return 500 - i; } }
	score := 0;
	ti := 0;
	for qi: 0..len(q)-1 {
		found := false;
		while ti < len(t) {
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

switcher_items :: (query: string) -> []Switch_Item {
	s := store();
	items := make_dynamic(Switch_Item, 0, 0, temp);
	for cid: s.private_channels {
		ch := dc.channel_get(s, cid);
		if ch == null { continue; }
		name := dm_name(ch);
		{ sc := fuzzy_score(query, name);
		if sc >= 0 { append(*items, Switch_Item.{kind = .DM, id = cid, name = name, score = sc + 5}); } }
	}
	for gid: guild_order() {
		g := dc.guild_get(s, gid);
		if g == null { continue; }
		{ sc := fuzzy_score(query, g.name);
		if sc >= 0 && query != "" { append(*items, Switch_Item.{kind = .Guild, id = gid, name = g.name, score = sc}); } }
		for cid: dc.guild_channels_sorted(s, gid) {
			ch := dc.channel_get(s, cid);
			if ch == null || ch.kind == .Guild_Category { continue; }
			{ sc := fuzzy_score(query, ch.name);
			if sc >= 0 {
				append(*items, Switch_Item.{kind = .Channel, id = cid, guild = gid, name = ch.name, sub = g.name, score = sc + (ifx dc.channel_unread(s, cid) then 3 else 0)});
			} }
		}
	}
	slice.stable_sort_by(view(items), (a: Switch_Item, b: Switch_Item) -> bool {return a.score > b.score;});
	if len(items) > 12 { resize(*items, 12); }
	return view(items);
}

switcher_activate :: (it_: Switch_Item) {
	if it_.kind == {
	case .DM;
		select_channel(0, it_.id);
	case .Channel;
		select_channel(it_.guild, it_.id);
	case .Guild;
		select_guild(it_.id);
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
	query := strings.trim_space(ui.editor_text(*sw.editor));
	items := switcher_items(query);
	sw.sel = clamp(sw.sel, 0, max(len(items) - 1, 0));
	for * e: app.ui.events {
		if e.kind != .Key_Down || e.consumed { continue; }
		if e.key == {
		case .Down;
			sw.sel = min(sw.sel + 1, len(items) - 1);
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
				if res == .Submit && len(items) > 0 { switcher_activate(items[sw.sel]); }
				if res == .Changed { sw.sel = 0; }
				spacer(.X, 12);
			}
			spacer(.X, 20);
		}
		spacer(.Y, 12);
		for it_, i: items {
			ir := row(fmt.tprintf("it%d", i), .Clickable | .Draw_Background);
			ir.semantic_size = .[ui.pct(1), ui.px(34)];
			sig := ui.signal(ir);
			if sig.hovering && app.ui.mouse != app.ui.mouse_prev { sw.sel = i; }
			sel := i == sw.sel;
			if sel { ir.style.bg = T("--background-mod-normal"); }
			if sig.clicked { switcher_activate(it_); }
			{ ui.parent(ir); defer ui.pop_parent();
				spacer(.X, 28);
				if it_.kind == {
				case .DM;
					ch := dc.channel_get(store(), it_.id);
					if ch != null && ch.kind == .DM && len(ch.recipient_ids) > 0 { avatar_box("av", ch.recipient_ids[0], 20); } else if ch != null { group_dm_icon("ic", ch, 20); }
				case .Channel;
					ch := dc.channel_get(store(), it_.id);
					icon("ic", ifx ch != null then channel_icon_name(ch) else "text", 20, T("--interactive-icon-default"));
				case .Guild;
					icon("ic", "server", 20, T("--interactive-icon-default"));
				}
				spacer(.X, 8);
				label(it_.name, .Medium, 16, ifx sel then T("--interactive-text-active") else T("--interactive-text-default"), 20);
				if it_.sub != "" {
					filler(.X);
					label(it_.sub, .Semibold, 12, T("--text-muted"), 16);
				}
				spacer(.X, 28);
			}
		}
		spacer(.Y, 20);
	}
}

