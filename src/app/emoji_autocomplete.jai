// Emoji autocomplete above the composer, like the client's EMOJIS_AND_STICKERS
// autocomplete: ":do" (a word starting with ':' and 2+ more characters before
// the caret) lists matching emoji (EmojiStore.searchWithoutFetchingLatest, up to
// 10, usable ones only); Up/Down move, Tab/Enter/click insert "<emoji> ",
// Escape hides it until the query changes. Typing the closing ':' of a known
// ":name:" converts it in place. See traffic/CLIENT_RULES.md "Composer emoji".

AC_MAX :: 10; // queryEmojiResults maxCount
AC_ROW_H :: 32;
AC_HEADER_H :: 32;
AC_PAD :: 8;
AC_EMOJI :: 20;
AC_GAP :: 8; // between the popup and the composer

Emoji_Autocomplete :: struct {
	channel: dc.Snowflake;
	query: string; // owned: last query shown, to reset the selection when it changes
	dismissed: string; // owned: query Escape hid
	sel: int;
	visible: bool; // shown last frame (channel_autocomplete_open fires on show)
	last_mouse: ui.Vec2; // hover selects only when the mouse moves (not under a still mouse while arrowing)
}

eac: Emoji_Autocomplete;

// The ":query" word ending at the caret: byte of its ':' and the query.
emoji_ac_query :: (text: string, caret: int) -> colon: int, q: string, ok: bool {
	if caret <= 0 || caret > text.count return 0, "", false;
	i := caret;
	while i > 0 {
		c := text[i - 1];
		if c == #char ":" || c == #char " " || c == #char "\n" || c == #char "\t" break;
		i -= 1;
	}
	if i == 0 || text[i - 1] != #char ":" return 0, "", false;
	colon := i - 1;
	if colon > 0 && !is_space(text[colon - 1]) return 0, "", false;
	return colon, string.{caret - i, text.data + i}, true;
}

// The popup for the composer of ch (inside its bordered stack, before the text
// field so its keys win). focused: the composer has keyboard focus.
emoji_autocomplete :: (ch: *dc.Channel, ed: *ui.Editor, focused: bool) {
	shown := false;
	defer if !shown eac.visible = false;
	if !focused || ui.editor_has_sel(ed) return;
	text := ui.editor_text(ed);
	colon, q, ok := emoji_ac_query(text, ed.caret);
	if !ok || q.count < 2 return;
	if eac.channel != ch.id || eac.query != q {
		free(eac.query);
		eac.query = copy_string(q);
		eac.channel = ch.id;
		eac.sel = 0;
	}
	if eac.dismissed == q return;
	all := emoji_search(q, ch.guild_id, emoji_reach(ch.id), false);
	n := 0;
	while n < all.count && !all[n].locked n += 1;
	locked := all.count - n;
	items := array_view(all, 0, min(n, AC_MAX));
	if !items return;
	shown = true;
	if !eac.visible && app.client != null dc.autocomplete_emoji_open(app.client, ch.id, items.count, locked);
	eac.visible = true;
	eac.sel = clamp(eac.sel, 0, items.count - 1);
	pick := -1;
	for * e: app.ui.events {
		if e.consumed || e.kind != .Key_Down || e.mods != 0 continue;
		if e.key == {
		case .Up;     eac.sel = (eac.sel + items.count - 1) % items.count;
		case .Down;   eac.sel = (eac.sel + 1) % items.count;
		case .Tab;    pick = eac.sel;
		case .Enter;  pick = eac.sel;
		case .Escape;
			free(eac.dismissed);
			eac.dismissed = copy_string(q);
		case; continue;
		}
		e.consumed = true;
	}

	h := cast(float32) (AC_HEADER_H + AC_ROW_H * items.count + AC_PAD);
	pop := ui.box("emoji_ac", .Floating_X | .Floating_Y | .Overlay | .Draw_Background | .Draw_Border | .Draw_Shadow | .Clickable);
	pop.semantic_size = .[ui.pct(1), ui.px(h)];
	pop.fixed_pos = .{0, -h - AC_GAP};
	pop.layout_axis = .Y;
	pop.style.bg = T("--background-surface-higher");
	pop.style.border_color = T("--border-subtle");
	pop.style.border = 1;
	pop.style.radius = all4(8);
	pop.style.shadow_color = .{0, 0, 0, 0.24};
	pop.style.shadow_blur = 8;
	ui.signal(pop);
	moved := app.ui.mouse != eac.last_mouse;
	eac.last_mouse = app.ui.mouse;
	{ ui.parent(pop); defer ui.pop_parent();
		head := row("head");
		head.semantic_size = .[ui.pct(1), ui.px(AC_HEADER_H)];
		{ ui.parent(head); defer ui.pop_parent();
			spacer(.X, 16);
			label("EMOJI MATCHING", .Semibold, 12, T("--text-muted"), 16);
			spacer(.X, 4);
			label(tprint(":%", q), .Semibold, 12, T("--text-strong"), 16);
		}
		for item, i: items {
			r := row(tprint("r%", i), .Clickable);
			r.semantic_size = .[ui.pct(1), ui.px(AC_ROW_H)];
			sig := ui.signal(r);
			if sig.hovering && moved eac.sel = i;
			if sig.clicked pick = i;
			{ ui.parent(r); defer ui.pop_parent();
				spacer(.X, AC_PAD);
				bg := ui.box("bg", .Draw_Background);
				bg.semantic_size = .[ui.fill(), ui.px(AC_ROW_H)];
				bg.layout_axis = .X;
				bg.cross_align = .Center;
				bg.style.radius = all4(4);
				if i == eac.sel bg.style.bg = T("--background-mod-normal");
				{ ui.parent(bg); defer ui.pop_parent();
					spacer(.X, 8);
					e := ui.box("e");
					e.semantic_size = .[ui.px(AC_EMOJI), ui.px(AC_EMOJI)];
					if item.uni >= 0 set_twemoji(e, emoji_toned(item.uni, frecency.skin_tone));
					else set_remote_image(e, emoji_url(item.id, false, 48));
					spacer(.X, 12);
					label(tprint(":%:", item.name), .Medium, 14, T(ifx i == eac.sel then "--interactive-text-active" else "--interactive-text-default"), 18);
					fill := ui.box("fill");
					fill.semantic_size = .[ui.fill(), ui.px(1)];
					if item.uni < 0 {
						g := dc.guild_get(store(), item.guild);
						if g label(g.name, .Normal, 12, T("--text-muted"), 16);
					}
					spacer(.X, 8);
				}
				spacer(.X, AC_PAD);
			}
		}
	}
	if pick < 0 return;
	item := items[pick];
	ed.mark = colon;
	ui.editor_insert(ed, tprint("% ", emoji_item_text(item)), .Other); // counted once sent (track_sent_emoji)
	if app.client != null dc.autocomplete_emoji_selected(app.client, ch.id, item.name, item.id, item.animated, items.count);
	eac.visible = false;
}

// After an edit: a typed closing ':' turns ":name:" into its emoji.
emoji_autocomplete_close_colon :: (ch: *dc.Channel, ed: *ui.Editor) {
	text := ui.editor_text(ed);
	c := ed.caret;
	if ui.editor_has_sel(ed) || c < 3 || text[c - 1] != #char ":" return;
	colon, q, ok := emoji_ac_query(text, c - 1);
	if !ok || !is_shortcode_name(q) return;
	e := emoji_for_name(q, ch.id);
	if !e return;
	ed.mark = colon;
	ui.editor_insert(ed, e, .Other);
}
