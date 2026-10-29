// Set a custom status: the account popout's "Set Custom Status" opens a modal with the text and when it
// clears (Today, 4 hours, 1 hour, 30 minutes or never); Save sends it through dc.set_custom_status, which
// writes the settings proto and the presence. An emoji the status already has is kept.

cstatus: struct {
	open: bool;
	ed: ui.Editor;
	clear_after: dc.Clear_After;
};

CUSTOM_STATUS_MAX :: 128; // characters

CLEAR_AFTER_CHOICES :: struct { k: dc.Clear_After; name: string; }.[
	.{.Today, "Today"}, .{.Hours_4, "4 hours"}, .{.Hour_1, "1 hour"}, .{.Minutes_30, "30 minutes"}, .{.Dont_Clear, "Don't clear"},
];

custom_status_open :: () {
	st := *store().settings;
	ui.editor_set_text(*cstatus.ed, ifx custom_status_active(st) then st.custom_status_text else "");
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
	if st.custom_status_emoji && st.custom_status_text return tprint("% %", st.custom_status_emoji, st.custom_status_text);
	return ifx st.custom_status_text then st.custom_status_text else st.custom_status_emoji;
}

set_my_custom_status :: (text: string, clear_after: dc.Clear_After) {
	st := *store().settings;
	cs := dc.Custom_Status.{text = text, clear_after = clear_after};
	if text != "" || custom_status_active(st) cs.emoji_name, cs.emoji_id = st.custom_status_emoji, st.custom_status_emoji_id;
	if text == "" cs = .{}; // clearing drops the emoji too
	now := wall_ms();
	if cs.text {
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
		r := padded("clear", 32);
		ui.parent(r); defer ui.pop_parent();
		for CLEAR_AFTER_CHOICES {
			if it_index spacer(.X, 8);
			sel := cstatus.clear_after == it.k;
			b := ui.box(tprint("%##ca%", it.name, it_index), .Clickable | .Draw_Background | .Draw_Border | .Draw_Text | .Hot_Animation);
			b.semantic_size = .[ui.text_size(12), ui.px(32)];
			b.style.radius = all4(8);
			b.style.font = F(.Medium);
			b.style.font_size = 14;
			b.style.text_align = .Center;
			b.style.text_color = ifx sel then T("--text-strong") else T("--text-default");
			b.style.bg = ifx sel then T("--background-mod-strong") else T("--input-background-default");
			b.style.bg_hot = T("--background-mod-strong");
			b.style.border = 1;
			b.style.border_color = ifx sel then T("--input-border-active") else T("--border-subtle");
			if ui.signal(b).clicked cstatus.clear_after = it.k;
		}
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
	if save && cstatus.open {
		set_my_custom_status(trim(ui.editor_text(*cstatus.ed)), cstatus.clear_after);
		cstatus.open = false;
	}
}

#scope_file

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
