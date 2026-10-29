// Set a custom status: the account popout's "Set Custom Status" opens a modal with an emoji (the
// emoji picker), the text and when it clears (a select: Today, 4 hours, 1 hour, 30 minutes or never);
// Save sends it through dc.set_custom_status, which writes the settings proto and the presence.

cstatus: struct {
	open: bool;
	ed: ui.Editor;
	clear_after: dc.Clear_After;
	emoji_name: string; // heap: a unicode emoji, or a custom emoji's name
	emoji_id: dc.Snowflake;
};

CUSTOM_STATUS_MAX :: 128; // characters

CLEAR_AFTER_CHOICES :: dc.Clear_After.[.Today, .Hours_4, .Hour_1, .Minutes_30, .Dont_Clear];
CLEAR_AFTER_NAMES :: string.["Today", "4 hours", "1 hour", "30 minutes", "Don't clear"];

custom_status_open :: () {
	st := *store().settings;
	active := custom_status_active(st);
	ui.editor_set_text(*cstatus.ed, ifx active then st.custom_status_text else "");
	custom_status_set_emoji(ifx active then st.custom_status_emoji else "", ifx active then st.custom_status_emoji_id else 0);
	cstatus.clear_after = .Today;
	cstatus.open = true;
	app.profile_user = 0;
}

// The custom status shows until its expiry (the client's CustomStatusManager clears it then).
custom_status_active :: (st: *dc.User_Settings) -> bool {
	if st.custom_status_text == "" && st.custom_status_emoji == "" && !st.custom_status_emoji_id return false;
	if st.custom_status_expires_ms {
		if st.custom_status_expires_ms <= wall_ms() return false;
		request_wake(app.ui.time + cast(float64) (st.custom_status_expires_ms - wall_ms()) / 1000 + 0.05);
	}
	return true;
}

// Your custom status as one line: its unicode emoji, then the text ("" for none).
custom_status_line :: () -> string {
	st := *store().settings;
	if !custom_status_active(st) return "";
	emoji := ifx st.custom_status_emoji_id then "" else st.custom_status_emoji; // a custom emoji's name isn't text to show
	if emoji && st.custom_status_text return tprint("% %", emoji, st.custom_status_text);
	return ifx st.custom_status_text then st.custom_status_text else emoji;
}

custom_status_set_emoji :: (name: string, id: dc.Snowflake) {
	free(cstatus.emoji_name);
	cstatus.emoji_name, cstatus.emoji_id = copy_string(name), id;
}

// set_my_custom_status: the text and emoji (none of both clears it) until clear_after.
set_my_custom_status :: (text: string, clear_after: dc.Clear_After, emoji_name := "", emoji_id: dc.Snowflake = 0) {
	st := *store().settings;
	cs := dc.Custom_Status.{text = text, clear_after = clear_after, emoji_name = emoji_name, emoji_id = emoji_id};
	now := wall_ms();
	if cs.text || cs.emoji_name {
		if clear_after == {
		case .Today;      cs.expires_at_ms = now + 86_400_000 - local_ms(now) % 86_400_000; // local midnight
		case .Hours_4;    cs.expires_at_ms = now + 4 * 3_600_000;
		case .Hour_1;     cs.expires_at_ms = now + 3_600_000;
		case .Minutes_30; cs.expires_at_ms = now + 30 * 60_000;
		}
	}
	if net_action() {
		dc.set_custom_status(app.client, cs);
		return;
	}
	dc.set_str(store(), *st.custom_status_text, cs.text); // offline (fixture) runs
	dc.set_str(store(), *st.custom_status_emoji, cs.emoji_name);
	st.custom_status_emoji_id, st.custom_status_expires_ms = cs.emoji_id, cs.expires_at_ms;
}

custom_status_modal :: () {
	scrim := ui.box("cs_scrim", .Draw_Background | .Clickable | .Floating_X | .Floating_Y | .Overlay);
	scrim.semantic_size = .[ui.px(app.ui.window.x), ui.px(app.ui.window.y)];
	scrim.style.bg = .{0, 0, 0, 0.7};
	if ui.signal(scrim).clicked {
		cstatus.open = false;
		return;
	}
	W :: 440;
	PAD :: 24;
	d := ui.box("csmodal", .Draw_Background | .Draw_Border | .Floating_X | .Floating_Y | .Overlay | .Clickable);
	d.semantic_size = .[ui.px(W), ui.children()];
	d.fixed_pos = .{(app.ui.window.x - W) / 2, (app.ui.window.y - (d.rect.y1 - d.rect.y0)) / 2};
	d.style.bg = T("--modal-background");
	d.style.border_color = T("--border-subtle");
	d.style.border = 1;
	d.style.radius = all4(12);
	d.layout_axis = .Y;
	ui.signal(d);
	ui.push_parent(d);
	defer ui.pop_parent();
	padded :: (id: string, h: float32) -> *ui.Box {
		r := row(id);
		r.semantic_size = .[ui.pct(1), ui.px(h)];
		ui.parent(r);
		spacer(.X, PAD); // the row's content starts after it
		ui.pop_parent();
		return r;
	}
	spacer(.Y, PAD);
	{ r := padded("t", 24); ui.parent(r); defer ui.pop_parent(); label("Set a custom status", .Semibold, 20, T("--text-strong"), 24); }
	spacer(.Y, 20);
	{ r := padded("lbl", 18); ui.parent(r); defer ui.pop_parent(); label("What's cookin'?", .Semibold, 14, T("--text-strong"), 18); }
	spacer(.Y, 8);
	save := false;
	{
		r := padded("inrow", 40);
		ui.parent(r); defer ui.pop_parent();
		// the emoji button: the chosen emoji, or the smiley; it opens the emoji picker over the modal
		eb := ui.box("emoji", .Clickable | .Draw_Background | .Hot_Animation);
		eb.semantic_size = .[ui.px(40), ui.px(40)];
		eb.style.radius = all4(8);
		eb.style.bg_hot = T("--background-mod-subtle");
		eb.hover_cursor = .Pointer;
		if ui.signal(eb).clicked picker_open(.Status, .Emoji, app.view.channel, 0, eb.rect);
		{ ui.parent(eb); defer ui.pop_parent();
			if cstatus.emoji_name {
				spacer(.X, 8);
				g := ui.box("glyph", .Wrap_Text);
				g.semantic_size = .[ui.px(24), ui.px(40)];
				g.style.line_height = 40;
				blocks := md_parse(ifx cstatus.emoji_id then tprint("<:%:%>", cstatus.emoji_name, cstatus.emoji_id) else cstatus.emoji_name);
				if blocks.count ui.set_spans(g, tokens_to_spans(blocks[0].tokens, .Normal, 22, null));
			} else {
				spacer(.X, 10);
				icon("smile", "reaction", 20, T("--interactive-icon-default"));
			}
		}
		spacer(.X, 8);
		field := row("input", .Draw_Background | .Draw_Border | .Clickable);
		field.semantic_size = .[ui.fill(), ui.px(40)];
		field.style.bg = T("--input-background-default");
		field.style.border_color = T("--input-border-active");
		field.style.border = 1;
		field.style.radius = all4(8);
		field.hover_cursor = .IBeam;
		{ ui.parent(field); defer ui.pop_parent();
			spacer(.X, 12);
			res := text_field("field", *cstatus.ed, "Support has arrived!", true, 16, 20, 10, T("--input-placeholder-text-default"));
			t := ui.editor_text(*cstatus.ed);
			cut := cut_runes(t, CUSTOM_STATUS_MAX);
			if cut.count < t.count ui.editor_set_text(*cstatus.ed, copy_string(cut,, temp));
			if res == .Submit save = true;
			if res == .Escape cstatus.open = false;
			spacer(.X, 12);
		}
		spacer(.X, PAD);
	}
	spacer(.Y, 20);
	{ r := padded("clbl", 18); ui.parent(r); defer ui.pop_parent(); label("Clear after", .Semibold, 14, T("--text-strong"), 18); }
	spacer(.Y, 8);
	{
		r := padded("clear", 40);
		ui.parent(r); defer ui.pop_parent();
		cur := 0;
		for CLEAR_AFTER_CHOICES if it == cstatus.clear_after cur = it_index;
		col := ui.box("sel");
		col.semantic_size = .[ui.fill(), ui.px(40)];
		{ ui.parent(col); defer ui.pop_parent();
			pick := select_field("clearafter", CLEAR_AFTER_NAMES, cur);
			if pick >= 0 cstatus.clear_after = CLEAR_AFTER_CHOICES[pick];
		}
		spacer(.X, PAD);
	}
	spacer(.Y, PAD);
	btns := row("btns", .Draw_Background);
	btns.semantic_size = .[ui.pct(1), ui.px(70)];
	btns.style.bg = T("--background-base-lower");
	btns.style.radius = .[0, 0, 12, 12];
	btns.style.child_gap = 8;
	{ ui.parent(btns); defer ui.pop_parent();
		filler(.X);
		if modal_button("Cancel##cancel", 96, T("--background-mod-normal"), T("--background-mod-strong"), T("--text-strong")) cstatus.open = false;
		if modal_button("Save##save", 96, T("--background-brand"), with_alpha(T("--background-brand"), 0.85), .{1, 1, 1, 1}) save = true;
		spacer(.X, PAD - 8);
	}
	if select_is_open() dropdown_list(); // the Clear after list, over the modal
	if save && cstatus.open {
		set_my_custom_status(trim(ui.editor_text(*cstatus.ed)), cstatus.clear_after, cstatus.emoji_name, cstatus.emoji_id);
		cstatus.open = false;
	}
	if !cstatus.open select_close();
}

// A modal's footer button (Cancel, Save...): w wide, 38 tall.
modal_button :: (id: string, w: float32, bg: ui.Color, bg_hot: ui.Color, fg: ui.Color) -> bool {
	b := ui.box(id, .Clickable | .Draw_Background | .Draw_Text | .Hot_Animation);
	b.semantic_size = .[ui.px(w), ui.px(38)];
	b.style.radius = all4(8);
	b.style.font = F(.Medium);
	b.style.font_size = 14;
	b.style.text_align = .Center;
	b.style.text_color = fg;
	b.style.bg = bg;
	b.style.bg_hot = bg_hot;
	return ui.signal(b).clicked;
}
