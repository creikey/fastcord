// The composer's timestamp generator (fastcord-only): a date and a time typed in local time,
// previewed in every <t:> style; picking one inserts its markup into the composer.

Timestamp_Gen :: struct {
	channel: dc.Snowflake; // the composer it inserts into; 0 when closed
	date: ui.Editor;
	time: ui.Editor;
	on_time: bool; // which field has focus
}

tsg: Timestamp_Gen;

TIMESTAMP_STYLES :: string.["t", "T", "d", "D", "f", "F", "R"];

timestamp_gen_open :: (channel_id: dc.Snowflake) {
	tsg.channel = channel_id;
	tsg.on_time = true;
	t := utc_calendar(local_ms(wall_ms()));
	ui.editor_set_text(*tsg.date, tprint("%-%-%", t.year, formatInt(t.month_starting_at_0 + 1, minimum_digits = 2), formatInt(t.day_of_month_starting_at_0 + 1, minimum_digits = 2)));
	ui.editor_set_text(*tsg.time, tprint("%:% %", hour12(t), formatInt(t.minute, minimum_digits = 2), am_pm(t)));
}

// Unix seconds of a local date ("2026-10-28", "10/28/2026", "10/28") and time ("3pm", "3:05 PM",
// "15:05"), with the UTC offset in force on that date.
parse_local_time :: (date: string, time: string) -> s64, bool {
	nums :: (s: string) -> [3]int, int, string {
		out: [3]int;
		n := 0;
		i := 0;
		while i < s.count && n < 3 {
			if s[i] >= #char "0" && s[i] <= #char "9" {
				v := 0;
				while i < s.count && s[i] >= #char "0" && s[i] <= #char "9" && v < 100000 { v = v * 10 + s[i] - #char "0"; i += 1; }
				out[n] = v;
				n += 1;
			} else if s[i] == #char "-" || s[i] == #char "/" || s[i] == #char ":" || s[i] == #char "." || s[i] == #char " " {
				i += 1;
			} else {
				break;
			}
		}
		return out, n, trim(string.{s.count - i, s.data + i});
	}
	now := utc_calendar(local_ms(wall_ms()));
	d, dn, drest := nums(trim(date));
	y, m, day: int;
	if drest != "" || dn < 2 return 0, false;
	if trim(date).count > 4 && find_index_from_left(date, #char "-") >= 0 {
		if dn != 3 return 0, false;
		y, m, day = d[0], d[1], d[2];
	} else {
		m, day = d[0], d[1];
		y = ifx dn == 3 then d[2] else now.year;
		if y < 100 y += 2000;
	}
	if m < 1 || m > 12 || day < 1 || day > 31 || y < 1970 || y > 9999 return 0, false;
	t, tn, trest := nums(trim(time));
	if tn < 1 || tn > 3 return 0, false;
	h, mi, sec := t[0], t[1], t[2];
	suffix := to_lower_copy(trest,, temp);
	if suffix == "am" || suffix == "a" || suffix == "pm" || suffix == "p" {
		if h < 1 || h > 12 return 0, false;
		h %= 12;
		if suffix[0] == #char "p" h += 12;
	} else if suffix != "" {
		return 0, false;
	}
	if h > 23 || mi > 59 || sec > 59 return 0, false;
	// days_from_civil (Howard Hinnant, "chrono-Compatible Low-Level Date Algorithms")
	yy := y - ifx m <= 2 then 1 else 0;
	era := yy / 400;
	yoe := yy - era * 400;
	doy := (153 * (m + ifx m > 2 then -3 else 9) + 2) / 5 + day - 1;
	days := era * 146097 + yoe * 365 + yoe / 4 - yoe / 100 + doy - 719468;
	return unix_from_local_ms((cast(s64) days * 86400 + h * 3600 + mi * 60 + sec) * 1000) / 1000, true;
}

timestamp_gen_modal :: () {
	scrim := ui.box("tsg_scrim", .Draw_Background | .Clickable | .Floating_X | .Floating_Y | .Overlay);
	scrim.semantic_size = .[ui.px(app.ui.window.x), ui.px(app.ui.window.y)];
	scrim.style.bg = .{0, 0, 0, 0.7};
	if ui.signal(scrim).clicked {
		tsg.channel = 0;
		return;
	}
	W :: 440;
	PAD :: 24;
	d := ui.box("tsgmodal", .Draw_Background | .Draw_Border | .Floating_X | .Floating_Y | .Overlay | .Clickable);
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

	for * e: app.ui.events {
		if e.consumed || e.kind != .Key_Down || e.key != .Tab continue;
		tsg.on_time = !tsg.on_time;
		e.consumed = true;
	}
	secs, ok := parse_local_time(ui.editor_text(*tsg.date), ui.editor_text(*tsg.time));
	pick := "";

	spacer(.Y, PAD);
	tr := row("t");
	tr.semantic_size = .[ui.pct(1), ui.px(24)];
	{ ui.parent(tr); defer ui.pop_parent();
		spacer(.X, PAD);
		label("Insert Timestamp", .Semibold, 20, T("--text-strong"), 24);
	}
	spacer(.Y, 16);
	fields := row("fields");
	fields.semantic_size = .[ui.pct(1), ui.children()];
	fields.style.child_gap = 12;
	{ ui.parent(fields); defer ui.pop_parent();
		spacer(.X, PAD - 12);
		for which: 0..1 {
			is_time := which == 1;
			col := ui.box(ifx is_time then "timecol" else "datecol");
			col.semantic_size = .[ui.fill(), ui.children()];
			col.layout_axis = .Y;
			ui.parent(col); defer ui.pop_parent();
			label(ifx is_time then "Time" else "Date", .Semibold, 14, T("--text-strong"), 18);
			spacer(.Y, 8);
			field := row("input", .Draw_Background | .Draw_Border | .Clickable);
			field.semantic_size = .[ui.pct(1), ui.px(40)];
			field.style.bg = T("--input-background-default");
			focused := tsg.on_time == is_time;
			field.style.border_color = ifx !ok then T("--text-feedback-critical") else ifx focused then T("--input-border-active") else T("--border-subtle");
			field.style.border = 1;
			field.style.radius = all4(8);
			field.hover_cursor = .IBeam;
			if ui.signal(field).pressed tsg.on_time = is_time;
			// the text inside is clickable too, so a press on it never reaches the field
			for e: app.ui.events if e.kind == .Mouse_Down && ui.contains(field.rect, e.pos) tsg.on_time = is_time;
			{ ui.parent(field); defer ui.pop_parent();
				spacer(.X, 12);
				ed := ifx is_time then *tsg.time else *tsg.date;
				res := text_field("field", ed, ifx is_time then "3:00 PM" else "2026-10-28", focused, 16, 20, 10, T("--input-placeholder-text-default"));
				if res == .Submit && ok pick = "f";
				if res == .Escape tsg.channel = 0;
				spacer(.X, 12);
			}
		}
		spacer(.X, PAD - 12);
	}
	spacer(.Y, 16);
	for style: TIMESTAMP_STYLES {
		r := row(tprint("style_%", style), .Clickable | .Draw_Background | .Hot_Animation);
		r.semantic_size = .[ui.pct(1), ui.px(36)];
		r.style.bg_hot = T("--background-mod-normal");
		{ ui.parent(r); defer ui.pop_parent();
			spacer(.X, PAD);
			label(ifx ok then format_unix(secs, style) else "Invalid date or time", .Normal, 16, ifx ok then T("--text-default") else T("--text-muted"), 20);
			filler(.X);
			label(tprint("<t:%>", style), .Normal, 14, T("--text-muted"), 20);
			spacer(.X, PAD);
		}
		if ui.signal(r).clicked && ok pick = style;
	}
	spacer(.Y, PAD - 8);
	for * e: app.ui.events {
		if !e.consumed && e.kind == .Key_Down && e.key == .Escape {
			e.consumed = true;
			tsg.channel = 0;
		}
	}
	if pick != "" && tsg.channel != 0 {
		ui.editor_insert(*chat_state(tsg.channel).editor, tprint("<t:%:%>", secs, pick));
		tsg.channel = 0;
		app.ui.focus = 0; // back to the composer
	}
}
