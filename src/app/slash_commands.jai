// The composer's "/" commands, like the client's command autocomplete: "/" at the start of the text lists
// the built-in commands the client runs itself (/shrug, /tableflip, /unflip, /me, /spoiler) and the apps'
// commands from the application command index (loaded the first time "/" is typed in a server), matching
// what follows. Up/Down move, Tab/Enter/click insert "/name ". After the name, a command's options show
// as a hint. Sending runs a built-in as plain text, or sends an app's command as an interaction with its
// options typed as "name:value" (a lone value goes to the first option). See traffic/CLIENT_RULES.md
// "Slash commands".

Builtin_Command :: struct { name, description, suffix: string; }

BUILTIN_COMMANDS :: Builtin_Command.[
	.{"shrug", "Appends ¯\\_(ツ)_/¯ to your message.", "¯\\\\\\_(ツ)\\_/¯"}, // i18n; the backslash and both underscores escaped, so markdown shows it as typed
	.{"tableflip", "Appends (╯°□°)╯︵ ┻━┻ to your message.", "(╯°□°)╯︵ ┻━┻"}, // i18n
	.{"unflip", "Appends ┬─┬ノ( º _ ºノ) to your message.", "┬─┬ノ( º _ ºノ)"}, // i18n
	.{"me", "Displays text with emphasis.", ""}, // i18n
	.{"spoiler", "Marks your message as a spoiler.", ""}, // i18n
];

SAC_MAX :: 10;
SAC_ROW_H :: 48;

sac: struct { sel: int; hidden_for: string; last_mouse: ui.Vec2; };

Slash_Action :: enum u8 { Text; Sent; Kept; }

// slash_command: what sending text does. A built-in's output goes out as text; an app command is sent here
// (Sent), or kept with a notice when its options don't parse (Kept). Text that isn't a known command is
// sent as typed.
slash_command :: (ch: *dc.Channel, text: string) -> string, Slash_Action {
	if !begins_with(text, "/") return text, .Text;
	name, rest := first_word(advance(text, 1));
	for BUILTIN_COMMANDS if it.name == name {
		if name == "me" return ifx rest then tprint("_%_", rest) else "", ifx rest then .Text else .Kept;
		if name == "spoiler" return ifx rest then tprint("||%||", rest) else "", ifx rest then .Text else .Kept;
		return ifx rest then tprint("% %", rest, it.suffix) else it.suffix, .Text;
	}
	for cmd: dc.commands_for(ch.guild_id) if cmd.name == name {
		values, err := command_values(ch, cmd, rest);
		if err { toast_show(err, false); return "", .Kept; }
		if net_action() dc.send_command_interaction(app.client, cmd, ch.guild_id, ch.id, values);
		return "", .Sent;
	}
	return text, .Text;
}

slash_autocomplete :: (ch: *dc.Channel, ed: *ui.Editor, focused: bool) {
	text := ui.editor_text(ed);
	if !focused || !begins_with(text, "/") || ed.caret == 0 return;
	space := find_index_from_left(text, #char " ");
	if space >= 0 && ed.caret > space {
		// past the name: the command's options as a hint
		name := slice(text, 1, space - 1);
		for cmd: dc.commands_for(ch.guild_id) if cmd.name == name && cmd.options.count {
			command_hint(cmd);
			return;
		}
		return;
	}
	q := slice(text, 1, ed.caret - 1);
	if sac.hidden_for == q return;
	free(sac.hidden_for);
	sac.hidden_for = "";
	if app.client != null dc.open_message_context_menu(app.client, ch.guild_id); // loads the index once
	Item :: struct { name, description, app: string; }
	items: [..]Item;
	items.allocator = temp;
	for BUILTIN_COMMANDS if begins_with(it.name, q) array_add(*items, .{it.name, tr(it.description), L("Built-In")});
	for dc.commands_for(ch.guild_id) if items.count < SAC_MAX && begins_with(it.name, q) array_add(*items, .{it.name, it.description, it.app_name});
	if !items return;
	sac.sel = clamp(sac.sel, 0, items.count - 1);
	pick := -1;
	for * e: app.ui.events {
		if e.consumed || e.kind != .Key_Down || e.mods != 0 continue;
		if e.key == {
		case .Up;    sac.sel = (sac.sel + items.count - 1) % items.count;
		case .Down;  sac.sel = (sac.sel + 1) % items.count;
		case .Tab;   pick = sac.sel;
		case .Enter; pick = sac.sel;
		case .Escape; sac.hidden_for = copy_string(q);
		case; continue;
		}
		e.consumed = true;
	}
	h := cast(float32) (8 + 32 + SAC_ROW_H * items.count + 8);
	pop := ui.box("slash_ac", .Floating_X | .Floating_Y | .Overlay | .Draw_Background | .Draw_Border | .Draw_Shadow | .Clickable);
	pop.semantic_size = .[ui.pct(1), ui.px(h)];
	pop.fixed_pos = .{0, -h - 8};
	pop.layout_axis = .Y;
	pop.style.bg = T("--background-surface-higher");
	pop.style.border_color = T("--border-subtle");
	pop.style.border = 1;
	pop.style.radius = all4(8);
	pop.style.shadow_color = .{0, 0, 0, 0.24};
	pop.style.shadow_blur = 8;
	ui.signal(pop);
	moved := app.ui.mouse != sac.last_mouse;
	sac.last_mouse = app.ui.mouse;
	{ ui.parent(pop); defer ui.pop_parent();
		spacer(.Y, 8);
		head := row("head");
		head.semantic_size = .[ui.pct(1), ui.px(32)];
		{ ui.parent(head); defer ui.pop_parent(); spacer(.X, 16); label(ifx q then tprint(L("Commands matching /%"), q) else L("Commands"), .Medium, 14, T("--text-muted"), 18); }
		for item, i: items {
			r := row(tprint("r%", i), .Clickable);
			r.semantic_size = .[ui.pct(1), ui.px(SAC_ROW_H)];
			sig := ui.signal(r);
			if sig.hovering && moved sac.sel = i;
			if sig.clicked pick = i;
			ui.parent(r); defer ui.pop_parent();
			spacer(.X, 8);
			bg := row("bg", .Draw_Background);
			bg.semantic_size = .[ui.fill(), ui.px(SAC_ROW_H)];
			bg.style.radius = all4(4);
			if i == sac.sel bg.style.bg = T("--background-mod-normal");
			{ ui.parent(bg); defer ui.pop_parent();
				spacer(.X, 8);
				col := ui.box("c");
				col.semantic_size = .[ui.fill(), ui.children()];
				col.layout_axis = .Y;
				{ ui.parent(col); defer ui.pop_parent();
					label(tprint("/%", item.name), .Semibold, 16, T(ifx i == sac.sel then "--interactive-text-active" else "--interactive-text-default"), 20);
					label(ellipsize(item.description, .Normal, 13, max(r.rect.x1 - r.rect.x0 - 200, 80)), .Normal, 13, T("--text-muted"), 16);
				}
				label(ellipsize(item.app, .Medium, 13, 160), .Medium, 13, T("--text-muted"), 16);
				spacer(.X, 8);
			}
			spacer(.X, 8);
		}
	}
	if pick < 0 return;
	rest := ifx space >= 0 then advance(text, space + 1) else "";
	ui.editor_set_text(ed, tprint("/% %", items[pick].name, rest));
}

#scope_file

first_word :: (t: string) -> string, string {
	sp := find_index_from_left(t, #char " ");
	if sp < 0 return t, "";
	return slice(t, 0, sp), trim(advance(t, sp + 1));
}

// The values typed for cmd's options: "name:value" pairs, or a lone value for the first option.
command_values :: (ch: *dc.Channel, cmd: dc.App_Command, rest: string) -> []dc.Command_Value, err: string {
	out: [..]dc.Command_Value;
	out.allocator = temp;
	// where each "name:" starts, in order
	Mark :: struct { at: int; opt: int; }
	marks: [..]Mark;
	marks.allocator = temp;
	for o, oi: cmd.options {
		key := tprint("%:", o.name);
		i := 0;
		while true {
			at := find_index_from_left(rest, key, i);
			if at < 0 break;
			if at == 0 || is_space(rest[at - 1]) { array_add(*marks, .{at, oi}); break; }
			i = at + 1;
		}
	}
	quick_sort(marks, (a: Mark, b: Mark) -> s64 { return a.at - b.at; });
	raw: [..]dc.Command_Value;
	raw.allocator = temp;
	if !marks.count && rest && cmd.options.count array_add(*raw, .{cmd.options[0], rest});
	else if !marks.count && rest return .[], tprint(L("/% takes no options."), cmd.name);
	for marks {
		o := cmd.options[it.opt];
		start := it.at + o.name.count + 1;
		end := ifx it_index + 1 < marks.count then marks[it_index + 1].at else rest.count;
		array_add(*raw, .{o, trim(slice(rest, start, end - start))});
	}
	for o: cmd.options if o.required {
		found := false;
		for raw if it.option.name == o.name && it.value found = true;
		if !found return .[], tprint(L("/%1 needs %2:"), cmd.name, o.name);
	}
	for raw {
		v := it.value;
		if !v continue;
		if it.option.kind == {
		case 4;
			_, ok, left := string_to_int(v);
			if !ok || left return .[], tprint(L("%: a whole number"), it.option.name);
		case 10;
			_, ok, left := string_to_float64(v);
			if !ok || left return .[], tprint(L("%: a number"), it.option.name);
		case 5;
			v = to_lower_copy(v,, temp);
			if v != "true" && v != "false" return .[], tprint(L("%: true or false"), it.option.name);
		case 6; #through; case 7; #through; case 8; #through; case 9;
			// "@name", "#channel" or "@Role" as their IDs
			m := trim(mentions_convert(v, ch));
			if begins_with(m, "<@&") m = advance(m, 3);
			else if begins_with(m, "<@") || begins_with(m, "<#") m = advance(m, 2);
			if ends_with(m, ">") m.count -= 1;
			id, ok := dc.parse_u64(m);
			if !ok return .[], tprint(ifx it.option.kind == 7 then L("%: pick a channel") else ifx it.option.kind == 8 then L("%: pick a role") else L("%: pick a member"), it.option.name);
			v = tprint("%", id);
		}
		array_add(*out, .{it.option, v});
	}
	return out, "";
}

command_hint :: (cmd: dc.App_Command) {
	h := cast(float32) (8 + 32 + 22 * cmd.options.count + 8);
	pop := ui.box("slash_hint", .Floating_X | .Floating_Y | .Overlay | .Draw_Background | .Draw_Border | .Draw_Shadow);
	pop.semantic_size = .[ui.pct(1), ui.px(h)];
	pop.fixed_pos = .{0, -h - 8};
	pop.layout_axis = .Y;
	pop.style.bg = T("--background-surface-higher");
	pop.style.border_color = T("--border-subtle");
	pop.style.border = 1;
	pop.style.radius = all4(8);
	ui.parent(pop); defer ui.pop_parent();
	spacer(.Y, 8);
	head := row("head");
	head.semantic_size = .[ui.pct(1), ui.px(32)];
	{ ui.parent(head); defer ui.pop_parent(); spacer(.X, 16); label(tprint("/% · %", cmd.name, cmd.app_name), .Semibold, 14, T("--text-strong"), 18); }
	for o: cmd.options {
		r := row(tprint("o%", it_index));
		r.semantic_size = .[ui.pct(1), ui.px(22)];
		ui.parent(r); defer ui.pop_parent();
		spacer(.X, 16);
		label(tprint("%:", o.name), .Medium, 14, ifx o.required then T("--text-strong") else T("--text-default"), 18);
		spacer(.X, 6);
		label(ifx o.required then tprint(L("% (required)"), o.description) else o.description, .Normal, 13, T("--text-muted"), 18);
	}
}
