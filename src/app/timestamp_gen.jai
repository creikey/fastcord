// The composer's timestamp generator (fastcord-only): a month calendar and an hour and minute picker
// in local time, with the moment previewed in every <t:> style; Insert puts the chosen style's
// markup in the composer.

Timestamp_Gen :: struct {
	channel: dc.Snowflake; // the composer it inserts into; 0 when closed
	local: s64; // the chosen moment as local wall-clock ms (read as UTC)
	month: int; // the month the calendar shows: year * 12 + month from 0
	style: int; // into TIMESTAMP_STYLES
	wheel: float32; // precise scrolling not yet turned into steps
}

tsg: Timestamp_Gen;

TIMESTAMP_STYLES :: string.["t", "T", "d", "D", "f", "F", "R"];
DAY_MS :: 86_400_000;

timestamp_gen_open :: (channel_id: dc.Snowflake) {
	tsg.channel = channel_id;
	tsg.style = 4; // f
	timestamp_gen_now();
}

timestamp_gen_now :: () {
	tsg.local = local_ms(wall_ms()) / 60_000 * 60_000;
	t := utc_calendar(tsg.local);
	tsg.month = t.year * 12 + t.month_starting_at_0;
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
	return unix_from_local_ms(days_from_civil(y, m, day) * DAY_MS + (h * 3600 + mi * 60 + sec) * 1000) / 1000, true;
}

// Days from 1970-01-01 to a date, month from 1 (Howard Hinnant, "chrono-Compatible Low-Level Date Algorithms").
days_from_civil :: (y: int, m: int, d: int) -> int {
	yy := y - ifx m <= 2 then 1 else 0;
	era := yy / 400;
	yoe := yy - era * 400;
	doy := (153 * (m + ifx m > 2 then -3 else 9) + 2) / 5 + d - 1;
	return era * 146097 + yoe * 365 + yoe / 4 - yoe / 100 + doy - 719468;
}

timestamp_gen_modal :: () {
	scrim := ui.box("tsg_scrim", .Draw_Background | .Clickable | .Floating_X | .Floating_Y | .Overlay);
	scrim.semantic_size = .[ui.px(app.ui.window.x), ui.px(app.ui.window.y)];
	scrim.style.bg = .{0, 0, 0, 0.7};
	if ui.signal(scrim).clicked {
		tsg.channel = 0;
		return;
	}
	W :: 664;
	PAD :: 24;
	CELL :: 36;
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

	// Steps of the wheel over b: up is +1, a notch at a time, or every 30 px of precise scrolling.
	wheel :: (b: *ui.Box) -> int {
		n := 0;
		for * e: app.ui.events {
			if e.kind != .Scroll || e.consumed || e.delta.y == 0 || !ui.contains(b.rect, app.ui.mouse) continue;
			e.consumed = true;
			if !e.precise { n += ifx e.delta.y > 0 then 1 else -1; continue; }
			tsg.wheel += e.delta.y;
			while tsg.wheel >= 30 { n += 1; tsg.wheel -= 30; }
			while tsg.wheel <= -30 { n -= 1; tsg.wheel += 30; }
		}
		return n;
	}
	// A square button with an icon (the calendar's month arrows, the spinners' steps).
	icon_button :: (id: string, name: string, w: float32, h: float32) -> bool {
		b := ui.box(id, .Clickable | .Draw_Background | .Hot_Animation);
		b.semantic_size = .[ui.px(w), ui.px(h)];
		b.style.radius = all4(6);
		b.style.bg_hot = T("--background-mod-normal");
		sig := ui.signal(b);
		set_icon(b, name, ifx sig.hovering then T("--interactive-icon-hover") else T("--interactive-icon-default"));
		return sig.clicked;
	}
	// Text centred in a w x h box.
	centred :: (text: string, w: float32, h: float32, font: Font_Id, size: float32, fg: ui.Color, flags: ui.Box_Flags = 0) -> *ui.Box {
		b := ui.box(text, .Draw_Text | flags);
		b.semantic_size = .[ui.px(w), ui.px(h)];
		b.style.font = F(font);
		b.style.font_size = size;
		b.style.text_align = .Center;
		b.style.text_color = fg;
		return b;
	}
	// The month shown follows the chosen day.
	month_of :: (day: int) -> int { t := utc_calendar(day * DAY_MS); return t.year * 12 + t.month_starting_at_0; }
	MIN_DAY :: 7; // keeps the first week of January 1970 drawable
	MAX_DAY :: 2932896 - 1; // 9999-12-31

	today := local_ms(wall_ms()) / DAY_MS;
	day := tsg.local / DAY_MS;
	hour := (tsg.local % DAY_MS) / 3_600_000;
	minute := (tsg.local % 3_600_000) / 60_000;
	pick := false;

	// arrows move the day as in the grid, Enter inserts, Escape closes
	for * e: app.ui.events {
		if e.consumed || e.kind != .Key_Down || e.mods continue;
		step := 0;
		if e.key == {
			case .Left; step = -1;
			case .Right; step = 1;
			case .Up; step = -7;
			case .Down; step = 7;
			case .Enter; pick = true;
			case .Escape; tsg.channel = 0;
			case; continue;
		}
		e.consumed = true;
		if step {
			day = clamp(day + step, MIN_DAY, MAX_DAY);
			tsg.month = month_of(day);
		}
	}

	spacer(.Y, PAD);
	tr := row("t");
	tr.semantic_size = .[ui.pct(1), ui.px(24)];
	{ ui.parent(tr); defer ui.pop_parent();
		spacer(.X, PAD);
		label(L("Insert Timestamp"), .Semibold, 20, T("--text-strong"), 24);
	}
	spacer(.Y, 20);
	body := row("body");
	body.semantic_size = .[ui.pct(1), ui.children()];
	body.cross_align = .Start;
	{ ui.parent(body); defer ui.pop_parent();
		spacer(.X, PAD);
		left := ui.box("left");
		left.semantic_size = .[ui.px(7 * CELL), ui.children()];
		left.layout_axis = .Y;
		{ ui.parent(left); defer ui.pop_parent();
			y, m0 := tsg.month / 12, tsg.month % 12;
			// the month and the year each step with their arrows, the year also with the wheel over it
			hdr := row("month");
			hdr.semantic_size = .[ui.pct(1), ui.px(32)];
			{ ui.parent(hdr); defer ui.pop_parent();
				if icon_button("prev", "chevron-small-left", 24, 28) tsg.month -= 1;
				centred(tprint("%##m", month_name(m0)), 92, 28, .Semibold, 16, T("--text-strong"));
				if icon_button("next", "chevron-small-right", 24, 28) tsg.month += 1;
				filler(.X);
				yr := row("year");
				yr.semantic_size = .[ui.children(), ui.px(28)];
				ui.parent(yr); defer ui.pop_parent();
				tsg.month += wheel(yr) * 12;
				if icon_button("prevy", "chevron-small-left", 24, 28) tsg.month -= 12;
				centred(tprint("%##y", y), 48, 28, .Semibold, 16, T("--text-strong"));
				if icon_button("nexty", "chevron-small-right", 24, 28) tsg.month += 12;
			}
			spacer(.Y, 8);
			wk := row("weekdays");
			wk.semantic_size = .[ui.pct(1), ui.px(20)];
			{ ui.parent(wk); defer ui.pop_parent();
				for 0..6 centred(tprint("%##wd%", weekday_name(it, short = true), it), CELL, 20, .Semibold, 12, T("--text-muted"));
			}
			spacer(.Y, 4);
			grid := ui.box("grid");
			grid.semantic_size = .[ui.pct(1), ui.children()];
			grid.layout_axis = .Y;
			tsg.month = clamp(tsg.month + wheel(grid) * -1, 1970 * 12, 9999 * 12 + 11);
			y, m0 = tsg.month / 12, tsg.month % 12;
			first := days_from_civil(y, m0 + 1, 1);
			start := first - (first + 4) % 7; // the Sunday on or before the 1st (1970-01-01 was a Thursday)
			{ ui.parent(grid); defer ui.pop_parent();
				for r: 0..5 {
					wr := row(tprint("w%", r));
					wr.semantic_size = .[ui.pct(1), ui.px(CELL)];
					ui.parent(wr); defer ui.pop_parent();
					for c: 0..6 {
						dd := start + r * 7 + c;
						ct := utc_calendar(dd * DAY_MS);
						in_month := ct.month_starting_at_0 == m0;
						sel := dd == day;
						fg := ifx sel then ui.Color.{1, 1, 1, 1} else ifx dd == today then T("--text-brand") else ifx in_month then T("--text-default") else T("--text-muted");
						b := centred(tprint("%##%", ct.day_of_month_starting_at_0 + 1, dd), CELL, CELL, ifx sel || dd == today then .Semibold else .Normal, 14, fg, .Clickable | .Draw_Background | .Hot_Animation);
						b.style.radius = all4(CELL / 2);
						if sel b.style.bg = T("--background-brand");
						b.style.bg_hot = ifx sel then T("--background-brand") else T("--background-mod-normal");
						if ui.signal(b).clicked && dd >= MIN_DAY && dd <= MAX_DAY {
							day = dd;
							if !in_month tsg.month = month_of(dd);
						}
					}
				}
			}
			spacer(.Y, 20);
			th := row("timehdr");
			th.semantic_size = .[ui.pct(1), ui.px(28)];
			{ ui.parent(th); defer ui.pop_parent();
				label(L("Time"), .Semibold, 14, T("--text-strong"), 18);
				filler(.X);
				now := ui.box(L("Now##now"), .Clickable | .Draw_Text | .Draw_Background | .Hot_Animation);
				now.semantic_size = .[ui.text_size(10), ui.px(28)];
				now.style.font = F(.Medium);
				now.style.font_size = 14;
				now.style.text_align = .Center;
				now.style.text_color = T("--text-link");
				now.style.radius = all4(6);
				now.style.bg_hot = T("--background-mod-normal");
				if ui.signal(now).clicked {
					timestamp_gen_now();
					day = tsg.local / DAY_MS;
					hour = (tsg.local % DAY_MS) / 3_600_000;
					minute = (tsg.local % 3_600_000) / 60_000;
				}
			}
			spacer(.Y, 8);
			// Up and down arrows over a value, wrapping within n; the wheel turns it too.
			spinner :: (id: string, v: *int, n: int) -> *ui.Box {
				col := ui.box(id);
				col.semantic_size = .[ui.px(64), ui.children()];
				col.layout_axis = .Y;
				col.cross_align = .Center;
				ui.parent(col); defer ui.pop_parent();
				step := wheel(col);
				if icon_button("up", "chevron-small-up", 64, 24) step += 1;
				b := centred("##value", 64, 44, .Semibold, 22, T("--text-strong"), .Draw_Background | .Draw_Border);
				b.style.bg = T("--input-background-default");
				b.style.border = 1;
				b.style.border_color = T("--border-subtle");
				b.style.radius = all4(8);
				if icon_button("down", "chevron-small-down", 64, 24) step -= 1;
				v.* = ((v.* + step) % n + n) % n;
				return b;
			}
			tm := row("time");
			tm.semantic_size = .[ui.pct(1), ui.children()];
			{ ui.parent(tm); defer ui.pop_parent();
				twelve := !use_24h();
				pm := hour / 12;
				h := ifx twelve then hour % 12 else hour;
				hb := spinner("hour", *h, ifx twelve then 12 else 24);
				hb.text = ifx twelve then tprint("%", ifx h then h else 12) else tprint("%", formatInt(h, minimum_digits = 2));
				centred(tprint("%##colon", i18n_fmt().tsep), 16, 44, .Semibold, 22, T("--text-strong"));
				mb := spinner("minute", *minute, 60);
				mb.text = tprint("%", formatInt(minute, minimum_digits = 2));
				hour = h;
				if twelve {
					spacer(.X, 12);
					ab := spinner("ampm", *pm, 2);
					ab.style.font_size = 18;
					ab.text = ifx pm then L("PM") else L("AM");
					hour += pm * 12;
				}
			}
		}
		spacer(.X, 32);
		right := ui.box("right");
		right.semantic_size = .[ui.fill(), ui.children()];
		right.layout_axis = .Y;
		{ ui.parent(right); defer ui.pop_parent();
			fh := row("fmthdr");
			fh.semantic_size = .[ui.pct(1), ui.px(32)];
			{ ui.parent(fh); defer ui.pop_parent();
				label(L("Format"), .Semibold, 14, T("--text-strong"), 18);
			}
			spacer(.Y, 8);
			tsg.local = day * DAY_MS + hour * 3_600_000 + minute * 60_000;
			secs := unix_from_local_ms(tsg.local) / 1000;
			for style, i: TIMESTAMP_STYLES {
				on := i == tsg.style;
				r := row(tprint("style_%", style), .Clickable | .Draw_Background | .Draw_Border | .Hot_Animation);
				r.semantic_size = .[ui.pct(1), ui.px(40)];
				r.style.radius = all4(8);
				r.style.border = 1;
				r.style.border_color = ifx on then T("--background-brand") else .{0, 0, 0, 0};
				r.style.bg = ifx on then with_alpha(T("--background-brand"), 0.12) else .{0, 0, 0, 0};
				r.style.bg_hot = ifx on then r.style.bg else T("--background-mod-normal");
				{ ui.parent(r); defer ui.pop_parent();
					spacer(.X, 12);
					dot := ui.box("dot", .Draw_Border | .Draw_Background);
					dot.semantic_size = .[ui.px(18), ui.px(18)];
					dot.style.radius = all4(9);
					dot.style.border = ifx on then 5.0 else 2.0;
					dot.style.border_color = ifx on then T("--background-brand") else T("--interactive-icon-default");
					dot.style.bg = ifx on then ui.Color.{1, 1, 1, 1} else .{0, 0, 0, 0};
					spacer(.X, 12);
					label(format_unix(secs, style), .Normal, 15, ifx on then T("--text-strong") else T("--text-default"), 20);
				}
				sig := ui.signal(r);
				if sig.clicked tsg.style = i;
				if sig.double_clicked pick = true;
			}
		}
		spacer(.X, PAD);
	}
	secs := unix_from_local_ms(tsg.local) / 1000;
	markup := tprint("<t:%:%>", secs, TIMESTAMP_STYLES[tsg.style]);
	spacer(.Y, 24);
	ft := row("footer");
	ft.semantic_size = .[ui.pct(1), ui.px(38)];
	ft.style.child_gap = 8;
	{ ui.parent(ft); defer ui.pop_parent();
		spacer(.X, PAD - 8);
		label(tprint("%##markup", markup), .Normal, 14, T("--text-muted"), 18);
		filler(.X);
		if modal_button(L("Cancel##cancel"), 96, T("--background-mod-normal"), T("--background-mod-strong"), T("--text-strong")) tsg.channel = 0;
		if modal_button(L("Insert##insert"), 96, T("--background-brand"), with_alpha(T("--background-brand"), 0.85), .{1, 1, 1, 1}) pick = true;
		spacer(.X, PAD - 8);
	}
	spacer(.Y, PAD);
	if pick && tsg.channel != 0 {
		ui.editor_insert(*chat_state(tsg.channel).editor, markup);
		tsg.channel = 0;
		app.ui.focus = 0; // back to the composer
	}
}
