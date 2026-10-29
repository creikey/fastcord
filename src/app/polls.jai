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
	label(ifx p.multiselect then L("Select one or more answers") else L("Select one answer"), .Normal, 12, T("--text-muted"), 16);
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
		if !closed && voted && poll_button("remove", L("Remove Vote"), false) dc.poll_vote(c, m.channel_id, m.id, .[]);
		if !results && picked && poll_button("vote", L("Vote"), true) {
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

// ---- A poll's result message (type 46): its embed "poll_result" carries the question, the winner and the counts ----

poll_result_field :: (m: *dc.Message, name: string) -> string {
	for e: m.embeds if e.kind == "poll_result" for e.fields if it.name == name return it.value;
	return "";
}

// Under the notice: the winning answer with its share, or no winner, and View Poll (jumps to the poll).
poll_result_card :: (m: *dc.Message) {
	total := string_to_int(poll_result_field(m, "total_votes"));
	votes := string_to_int(poll_result_field(m, "victor_answer_votes"));
	winner := poll_result_field(m, "victor_answer_text");
	r := row("pollres");
	r.semantic_size = .[ui.pct(1), ui.children()];
	ui.parent(r); defer ui.pop_parent();
	spacer(.X, MSG_GUTTER);
	card := row("card", .Draw_Background | .Draw_Border);
	card.semantic_size = .[ui.px(POLL_W), ui.px(64)];
	card.style.bg = T("--embed-background");
	card.style.border_color = T("--border-subtle");
	card.style.border = 1;
	card.style.radius = all4(8);
	card.cross_align = .Center;
	{ ui.parent(card); defer ui.pop_parent();
		spacer(.X, 16);
		col := ui.box("col");
		col.semantic_size = .[ui.fill(), ui.children()];
		col.layout_axis = .Y;
		{ ui.parent(col); defer ui.pop_parent();
			if winner && total > 0 {
				t := row("t");
				t.semantic_size = .[ui.pct(1), ui.px(20)];
				{ ui.parent(t); defer ui.pop_parent();
					icon("ck", "checkmark-small-bold", 18, T("--status-positive"));
					spacer(.X, 4);
					emoji := poll_result_field(m, "victor_answer_emoji_name");
					if emoji && !poll_result_field(m, "victor_answer_emoji_id") label(tprint("% ", emoji), .Normal, 16, T("--text-default"), 20);
					label(winner, .Semibold, 16, T("--text-strong"), 20);
				}
				label(tprint(L("Winning answer · %1%2"), (votes * 100 + total / 2) / total, "%"), .Normal, 14, T("--text-muted"), 18);
			} else {
				label(ifx total > 0 then L("The results were tied") else L("There was no winner"), .Semibold, 16, T("--text-strong"), 20);
				label(tprint("% vote%", total, ifx total == 1 then "" else "s"), .Normal, 14, T("--text-muted"), 18);
			}
		}
		if m.referenced_id && poll_button("view", L("View Poll"), false) jump_to_message(m.channel_id, m.referenced_id);
		spacer(.X, 16);
	}
}

// ---- Create a poll:the composer "+" menu's Create Poll, laid out like the client's modal ----
// What was typed stays until the poll is posted, so closing the modal loses nothing.

POLL_DURATIONS :: struct { text: string; hours: int; }.[
	.{"1 hour", 1}, .{"4 hours", 4}, .{"8 hours", 8}, .{"24 hours", 24}, .{"3 days", 72}, .{"1 week", 168}, .{"2 weeks", 336}
];

New_Poll :: struct {
	channel: dc.Snowflake; // the open modal's channel; 0 when closed
	question: ui.Editor;
	answers: [dc.MAX_POLL_ANSWERS]ui.Editor;
	count := 2;
	duration := 3; // POLL_DURATIONS index: 24 hours
	multi: bool;
	picking: bool; // the duration list is open
}
npoll: New_Poll;

poll_create_open :: (channel_id: dc.Snowflake) { npoll.channel, npoll.picking = channel_id, false; }

// Polls need SEND_POLLS in a Discord server; serve has no such permission, so a hosted one needs only Send Messages.
can_send_poll :: (ch: *dc.Channel) -> bool {
	if ch.guild_id == 0 return ch.kind == .DM || ch.kind == .Group_DM;
	perms := dc.channel_permissions(store(), ch.id);
	return dc.has_permission(perms, dc.PERM_SEND_MESSAGES) && (on_hosted() || dc.has_permission(perms, dc.PERM_SEND_POLLS));
}

poll_create_modal :: () {
	if !npoll.channel return;
	W :: 520;
	if !adm_modal_begin("newpoll", W, L("Create a poll")) {
		npoll.channel = 0;
		return;
	}
	heading :: (text: string) {
		spacer(.Y, 20);
		r := row(tprint("h_%", text));
		r.semantic_size = .[ui.pct(1), ui.px(20)];
		{ ui.parent(r); defer ui.pop_parent();
			spacer(.X, 25);
			label(text, .Semibold, 16, T("--text-strong"), 20);
		}
		spacer(.Y, 8);
	}
	cut :: (ed: *ui.Editor, n: int) {
		t := ui.editor_text(ed);
		c := cut_runes(t, n);
		if c.count < t.count ui.editor_set_text(ed, copy_string(c,, temp));
	}
	heading(L("Question"));
	if modal_field("question", *npoll.question, L("What question do you want to ask?")) == .Escape npoll.channel = 0;
	cut(*npoll.question, 300);
	heading(L("Answers"));
	drop := -1;
	for i: 0..npoll.count-1 {
		ui.id_scope(cast(u64) i + 1); defer ui.pop_seed();
		ar := row("arow");
		ar.semantic_size = .[ui.pct(1), ui.children()];
		ui.parent(ar); defer ui.pop_parent();
		f := ui.box("f");
		f.semantic_size = .[ui.fill(), ui.children()];
		f.layout_axis = .Y;
		{ ui.parent(f); defer ui.pop_parent();
			if modal_field("answer", *npoll.answers[i], L("Type your answer")) == .Escape npoll.channel = 0;
		}
		cut(*npoll.answers[i], 55);
		if npoll.count > 1 {
			x := ui.box("drop", .Clickable | .Floating_X | .Floating_Y);
			x.semantic_size = .[ui.px(20), ui.px(20)];
			x.fixed_pos = .{W - 25 - 12 - 20, 10};
			xs := ui.signal(x);
			set_icon(x, "trash", ifx xs.hovering then T("--status-danger") else T("--interactive-icon-default"));
			if xs.clicked drop = i;
		}
		spacer(.Y, 8);
	}
	if drop >= 0 {
		// the later answers move up one, keeping their editors
		tmp := npoll.answers[drop];
		for i: drop..npoll.count-2 npoll.answers[i] = npoll.answers[i + 1];
		npoll.answers[npoll.count - 1] = tmp;
		ui.editor_set_text(*npoll.answers[npoll.count - 1], "");
		npoll.count -= 1;
	}
	if npoll.count < dc.MAX_POLL_ANSWERS {
		r := row("addrow");
		r.semantic_size = .[ui.pct(1), ui.px(36)];
		ui.parent(r); defer ui.pop_parent();
		spacer(.X, 25);
		add := row("add", .Clickable | .Draw_Background | .Hot_Animation);
		add.semantic_size = .[ui.children(), ui.px(36)];
		add.style.radius = all4(8);
		add.style.bg_hot = T("--background-mod-subtle");
		add.hover_cursor = .Pointer;
		{ ui.parent(add); defer ui.pop_parent();
			spacer(.X, 8);
			icon("i", "plus-small", 20, T("--text-link"));
			spacer(.X, 4);
			label(L("Add another answer"), .Medium, 14, T("--text-link"), 18);
			spacer(.X, 8);
		}
		if ui.signal(add).clicked npoll.count += 1;
	}
	heading(L("Duration"));
	dr := row("durrow");
	dr.semantic_size = .[ui.pct(1), ui.px(40)];
	dur_rect: ui.Rect;
	{ ui.parent(dr); defer ui.pop_parent();
		spacer(.X, 25);
		d := row("duration", .Clickable | .Draw_Background | .Draw_Border);
		d.semantic_size = .[ui.px(200), ui.px(40)];
		d.style.bg = T("--input-background-default");
		d.style.border_color = T("--input-border-default");
		d.style.border = 1;
		d.style.radius = all4(8);
		d.hover_cursor = .Pointer;
		if ui.signal(d).clicked npoll.picking = !npoll.picking;
		dur_rect = d.rect;
		ui.parent(d); defer ui.pop_parent();
		spacer(.X, 12);
		label(POLL_DURATIONS[npoll.duration].text, .Normal, 16, T("--text-default"), 20);
		filler(.X);
		icon("i", ifx npoll.picking then "chevron-small-up" else "chevron-small-down", 20, T("--interactive-icon-default"));
		spacer(.X, 8);
	}
	spacer(.Y, 16);
	mr := row("multi", .Clickable);
	mr.semantic_size = .[ui.pct(1), ui.px(24)];
	mr.hover_cursor = .Pointer;
	if ui.signal(mr).clicked npoll.multi = !npoll.multi;
	{ ui.parent(mr); defer ui.pop_parent();
		spacer(.X, 25);
		cb := ui.box("cb", .Draw_Background | .Draw_Border);
		cb.semantic_size = .[ui.px(20), ui.px(20)];
		cb.style.radius = all4(4);
		cb.style.border = ifx npoll.multi then 0.0 else 1.5;
		cb.style.border_color = T("--interactive-icon-default");
		cb.style.bg = ifx npoll.multi then T("--background-brand") else .{};
		if npoll.multi { ui.parent(cb); defer ui.pop_parent(); icon("ck", "checkmark-small-bold", 20, .{1, 1, 1, 1}); }
		spacer(.X, 8);
		label(L("Allow Multiple Answers"), .Normal, 16, T("--text-default"), 20);
	}
	question := trim(ui.editor_text(*npoll.question));
	answers: [..]string;
	answers.allocator = temp;
	for i: 0..npoll.count-1 {
		a := trim(ui.editor_text(*npoll.answers[i]));
		if a array_add(*answers, a);
	}
	spacer(.Y, 24);
	btns := row("btns", .Draw_Background);
	btns.semantic_size = .[ui.pct(1), ui.px(70)];
	btns.style.bg = T("--background-base-lower");
	btns.cross_align = .Center;
	{ ui.parent(btns); defer ui.pop_parent();
		filler(.X);
		post := adm_button("post", L("Post"), .Primary, question != "" && answers.count > 0);
		spacer(.X, 25);
		if post && net_action() {
			draft := dc.Poll_Draft.{question, answers, POLL_DURATIONS[npoll.duration].hours, npoll.multi};
			dc.send_message(app.client, npoll.channel, "", .{poll = *draft, location = "poll_creation"});
			ui.editor_set_text(*npoll.question, "");
			for * npoll.answers ui.editor_set_text(it, "");
			npoll.count, npoll.duration, npoll.multi, npoll.channel = 2, 3, false, 0;
		}
	}
	adm_modal_end();
	if npoll.picking && npoll.channel {
		m := menu_panel("durmenu", .{dur_rect.x0, dur_rect.y1 + 4}, 200);
		ui.parent(m); defer ui.pop_parent();
		spacer(.Y, 8);
		for POLL_DURATIONS if menu_item(tprint("d%", it_index), it.text, ifx it_index == npoll.duration then Item_Right.Radio_On else .Radio_Off).clicked {
			npoll.duration = it_index;
			npoll.picking = false;
		}
		spacer(.Y, 8);
	}
	if adm_escape() {
		if npoll.picking npoll.picking = false;
		else npoll.channel = 0;
	}
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
