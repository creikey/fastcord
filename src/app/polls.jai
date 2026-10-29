// A poll under its message, laid out like the official client's: the question, one row per answer to
// pick (one, or several with allow_multiselect), Vote; once you've voted or it has closed, each answer's
// share as a bar with its percentage, the total and the time left, and Remove Vote while it's open.

POLL_W :: 440;
POLL_ROW_H :: 44;

poll_picks: Table(dc.Snowflake, u16); // per message, the answers picked but not yet voted (bit = answer id)

message_poll_view :: (m: *dc.Message) {
	p := m.poll;
	voted := false;
	total := 0;
	for p.answers { if it.me voted = true; total += it.count; }
	closed := p.finalized || (p.expiry && dc.iso_to_ms(p.expiry) <= dc.now_ms());
	results := voted || closed;
	picks := table_find_pointer(*poll_picks, m.id);
	picked := ifx picks then picks.* else 0;

	spacer(.Y, 4);
	card := ui.box(tprint("poll%", m.id), .Draw_Background | .Draw_Border);
	card.semantic_size = .[ui.px(POLL_W), ui.children()];
	card.layout_axis = .Y;
	card.style.bg = T("--embed-background");
	card.style.border_color = T("--border-subtle");
	card.style.border = 1;
	card.style.radius = all4(12);
	ui.parent(card); defer ui.pop_parent();
	body := row("body");
	body.semantic_size = .[ui.pct(1), ui.children()];
	ui.parent(body); defer ui.pop_parent();
	spacer(.X, 16);
	col := ui.box("col");
	col.semantic_size = .[ui.fill(), ui.children()];
	col.layout_axis = .Y;
	ui.parent(col); defer ui.pop_parent();
	spacer(.Y, 16);
	set_para("q", p.question, .Semibold, 16, 20, T("--text-strong"));
	spacer(.Y, 4);
	label(ifx p.multiselect then "Select one or more answers" else "Select one answer", .Normal, 12, T("--text-muted"), 16);
	spacer(.Y, 12);
	top := 0;
	for p.answers top = max(top, it.count);
	for a: p.answers {
		bit := cast(u16) (1 << clamp(a.id, 0, 15));
		on := ifx results then a.me else (picked & bit) != 0;
		r := row(tprint("a%", a.id), ifx results then .Draw_Background | .Draw_Border else .Clickable | .Draw_Background | .Draw_Border | .Hot_Animation);
		r.semantic_size = .[ui.pct(1), ui.px(POLL_ROW_H)];
		r.style.radius = all4(8);
		r.style.border = 1;
		r.style.border_color = ifx on then T("--background-brand") else T("--border-subtle");
		r.style.bg = T("--background-mod-subtle");
		r.style.bg_hot = T("--background-mod-normal");
		if !results r.hover_cursor = .Pointer;
		share := ifx total then cast(float32) a.count / total else 0;
		if results {
			// The share as a fill behind the row, drawn over its background.
			d := New(Poll_Bar,, temp);
			d.share, d.color = share, ifx closed && a.count == top && top then with_alpha(T("--status-positive-background"), 0.35) else T("--background-mod-strong");
			r.custom_draw = poll_bar_draw;
			r.custom_user = d;
		}
		{ ui.parent(r); defer ui.pop_parent();
			spacer(.X, 12);
			if a.emoji { label(a.emoji, .Normal, 16, T("--text-default"), 20); spacer(.X, 8); }
			label(a.text, .Medium, 14, T("--text-default"), 18);
			filler(.X);
			if results label(tprint("%1%2", cast(int) (share * 100 + 0.5), "%"), .Semibold, 14, T("--text-strong"), 18);
			else {
				mark := ui.box("mark", .Draw_Border);
				mark.semantic_size = .[ui.px(20), ui.px(20)];
				mark.style.border = 2;
				mark.style.radius = all4(ifx p.multiselect then 4.0 else 10.0);
				mark.style.border_color = ifx on then T("--background-brand") else T("--interactive-icon-default");
			}
			spacer(.X, 12);
		}
		if !results && ui.signal(r).clicked {
			next := ifx p.multiselect then picked ^ bit else ifx on then 0 else bit;
			table_set(*poll_picks, m.id, next);
		}
		spacer(.Y, 8);
	}
	foot := row("foot");
	foot.semantic_size = .[ui.pct(1), ui.px(36)];
	{ ui.parent(foot); defer ui.pop_parent();
		left := ifx closed then "Poll closed" else poll_time_left(dc.iso_to_ms(p.expiry) - dc.now_ms());
		label(tprint("% vote% · %", total, ifx total == 1 then "" else "s", left), .Normal, 14, T("--text-muted"), 18);
		filler(.X);
		c := app.client; // the connection whose messages are on screen
		if !closed && voted && poll_button("remove", "Remove Vote", false) dc.poll_vote(c, m.channel_id, m.id, .[]);
		if !results && picked && poll_button("vote", "Vote", true) {
			ids: [..]int;
			ids.allocator = temp;
			for p.answers if picked & cast(u16) (1 << clamp(it.id, 0, 15)) array_add(*ids, it.id);
			dc.poll_vote(c, m.channel_id, m.id, ids);
			table_remove(*poll_picks, m.id);
		}
	}
	spacer(.Y, 12);
}

poll_time_left :: (ms: s64) -> string {
	if ms >= 86_400_000 return tprint("%d left", ms / 86_400_000);
	if ms >= 3_600_000 return tprint("%h left", ms / 3_600_000);
	return tprint("%m left", max(1, ms / 60_000));
}

#scope_file

Poll_Bar :: struct { share: float32; color: ui.Color; }

poll_bar_draw :: (b: *ui.Box, user: *void) {
	d := cast(*Poll_Bar) user;
	if d.share <= 0 return;
	r := b.rect;
	c := with_alpha(d.color, d.color.w * b.opacity);
	gfx.rect(.{r.x0, r.y0, r.x0 + (r.x1 - r.x0) * d.share, r.y1}, c, 8);
}

poll_button :: (id: string, text: string, primary: bool) -> bool {
	b := row(id, .Clickable | .Draw_Background | .Hot_Animation);
	b.semantic_size = .[ui.children(), ui.px(32)];
	b.style.radius = all4(8);
	b.style.bg = ifx primary then T("--background-brand") else T("--background-mod-normal");
	b.style.bg_hot = with_alpha(b.style.bg, 0.85);
	b.hover_cursor = .Pointer;
	{ ui.parent(b); defer ui.pop_parent();
		spacer(.X, 16);
		label(text, .Medium, 14, ifx primary then ui.Color.{1, 1, 1, 1} else T("--text-default"), 18);
		spacer(.X, 16);
	}
	return ui.signal(b).clicked;
}
