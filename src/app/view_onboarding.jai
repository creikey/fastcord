// A server's own pages, drawn in place of the chat (the client's static routes, traffic/CLIENT_RULES.md
// "Member onboarding"):
// - Onboarding: on opening a GUILD_ONBOARDING server you joined since onboarding began (2023-04-26) and
//   started but haven't finished it in (member flags STARTED_ONBOARDING, not COMPLETED_ONBOARDING),
//   GET /guilds/{id}/onboarding, then its in_onboarding questions one at a time; Finish
//   POSTs the answers to /guilds/{id}/onboarding-responses, which hands out their roles and channels, and lands
//   in the first default channel.
// - Channels & Roles: every question, each answer changed at once with PUT .../onboarding-responses.
// - Browse Channels: the server's channels by category, each opened on click.
// - Server Guide: GET /guilds/{id}/new-member-welcome (welcome message, new member to-dos, resources) and
//   GET .../new-member-actions (the to-dos done); a "view" to-do is done by opening it
//   (POST /guilds/{id}/new-member-action/{channel}).
// The <id:customize>, <id:browse> and <id:guide> chips in messages open them too.

Server_Page :: enum u8 { None; Onboarding; Customize; Browse; Guide; }

MEMBER_COMPLETED_ONBOARDING :: 2; MEMBER_STARTED_ONBOARDING :: 8; // GuildMemberFlags
ONBOARDING_SINCE_MS :: 1682488800000; // members who joined before this never get onboarding
ONB_GET :: 0; ONB_GUIDE :: 1; ONB_ACTIONS :: 2; ONB_RESPONSES :: 3; ONB_ACTION_DONE :: 4; // Feature_Op.Onboarding tags
ONB_MAX_PROMPTS :: 50; ONB_MAX_OPTIONS :: 50; ONB_MAX_JSON :: 1 << 20;

onb: struct {
	guild: dc.Snowflake; // the server the replies below are for
	page: Server_Page;
	asked: [..]dc.Snowflake; // servers onboarding_check looked at this session
	auto: bool; // the onboarding GET came from onboarding_check: start onboarding if it asks anything
	form: string; // heap: GET /guilds/{id}/onboarding's body as JSON, parsed each frame into temp
	guide: string; // heap: GET /guilds/{id}/new-member-welcome's
	chosen: [..]dc.Snowflake; // your answers (option ids)
	done: [..]dc.Snowflake; // to-do channels done
	step: int;
	loading, failed: bool;
};

// Called by go_to when the open server changes.
onboarding_check :: (gid: dc.Snowflake) {
	s := store();
	g := dc.guild_get(s, gid);
	if !g || !array_find(g.features, "GUILD_ONBOARDING") || array_find(onb.asked, gid) return;
	// as the client: only a member who joined since onboarding began and started it (Discord sets
	// STARTED_ONBOARDING on join); finishing it posts the server's welcome message for you
	m := dc.member_get(s, gid, s.me);
	if !m || dc.iso_to_ms(m.joined_at) < ONBOARDING_SINCE_MS || (m.flags & (MEMBER_STARTED_ONBOARDING | MEMBER_COMPLETED_ONBOARDING)) != MEMBER_STARTED_ONBOARDING return;
	array_add(*onb.asked, gid);
	onb_load(gid);
	onb.auto = true;
}

server_page_open :: (gid: dc.Snowflake, page: Server_Page) {
	if !dc.guild_get(store(), gid) return;
	if app.view.guild != gid select_guild(gid);
	onb.page = page;
	if page == .Customize && (onb.guild != gid || !onb.form) onb_load(gid);
	if page == .Guide {
		onb_reset(gid);
		free(onb.guide);
		onb.guide, onb.loading, onb.failed = "", true, false;
		if net_action() {
			dc.feature_submit(app.client, .Onboarding, "GET", tprint("/guilds/%/new-member-welcome", gid), channel_id = gid, tag = ONB_GUIDE);
			dc.feature_submit(app.client, .Onboarding, "GET", tprint("/guilds/%/new-member-actions", gid), channel_id = gid, tag = ONB_ACTIONS);
		}
	}
}

// The chip of <id:page> in a message.
server_page_chip :: (page: string) {
	gid := app.view.guild;
	if page == {
	case "customize"; server_page_open(gid, .Customize);
	case "browse"; server_page_open(gid, .Browse);
	case "guide"; #through; case "home"; server_page_open(gid, .Guide);
	}
}

onboarding_receive :: (r: *dc.Feature_Result) {
	if r.channel_id != onb.guild return;
	if r.tag == {
	case ONB_GET; #through; case ONB_GUIDE;
		onb.loading = false;
		onb.failed = !r.ok || r.body.kind != .Map;
		if onb.failed { onb.auto = false; return; }
		sb: String_Builder;
		sb.allocator = temp;
		etf.to_json(r.body, *sb);
		json := builder_to_string(*sb,, temp);
		if json.count > ONB_MAX_JSON { onb.failed = true; return; }
		if r.tag == ONB_GUIDE { free(onb.guide); onb.guide = copy_string(json); return; }
		free(onb.form);
		onb.form = copy_string(json);
		array_reset_keeping_memory(*onb.chosen);
		for dc.flist(r.body.map, "responses") if it_index < ONB_MAX_PROMPTS * ONB_MAX_OPTIONS array_add_if_unique(*onb.chosen, dc.vsnow(it));
		if onb.auto && dc.fbool(r.body.map, "enabled") && onb_prompts(r.body.map, true).count && app.view.guild == onb.guild && onb.page == .None {
			onb.page, onb.step = Server_Page.Onboarding, 0;
		}
		onb.auto = false;
	case ONB_ACTIONS;
		if !r.ok || r.body.kind != .Map return;
		array_reset_keeping_memory(*onb.done);
		for dc.fmap(r.body.map, "channel_actions") if it_index < 64 && dc.fbool(dc.vmap(it.value), "completed") {
			id, ok := dc.parse_u64(dc.vstr(it.key));
			if ok array_add(*onb.done, id);
		}
	case ONB_RESPONSES;
		if !r.ok toast_show(L("Something went wrong. Please try again."), false);
	}
}

// Per frame: the open page in place of the chat; false when none is open.
server_page :: () -> bool {
	if onb.page == .None || app.view.guild == 0 return false;
	if onb.page != .Browse && onb.guild != app.view.guild { onb.page = .None; return false; }
	if onb.page == {
	case .Onboarding; onboarding_page();
	case .Customize; customize_page();
	case .Browse; browse_page();
	case .Guide; guide_page();
	}
	return true;
}

// Drop the replies of another server.
onb_reset :: (gid: dc.Snowflake) {
	if onb.guild == gid return;
	free(onb.form);
	free(onb.guide);
	onb.form, onb.guide, onb.guild = "", "", gid;
	array_reset_keeping_memory(*onb.chosen);
	array_reset_keeping_memory(*onb.done);
}

onb_load :: (gid: dc.Snowflake) {
	onb_reset(gid);
	onb.loading, onb.failed, onb.auto = true, false, false;
	if app.client dc.feature_submit(app.client, .Onboarding, "GET", tprint("/guilds/%/onboarding", gid), channel_id = gid, tag = ONB_GET);
}

onb_parse :: (json: string) -> etf.Map {
	v, err := etf.from_json(json,, temp);
	return ifx json && err == .None && v.kind == .Map then v.map else .{};
}

// The questions (only those asked while onboarding, or all), capped.
onb_prompts :: (form: etf.Map, onboarding: bool) -> []etf.Map {
	out: [..]etf.Map;
	out.allocator = temp;
	for dc.flist(form, "prompts") {
		if out.count >= ONB_MAX_PROMPTS break;
		if it.kind == .Map && (!onboarding || dc.fbool(it.map, "in_onboarding")) array_add(*out, it.map);
	}
	return out;
}

onb_options :: (p: etf.Map) -> []etf.Value {
	o := dc.flist(p, "options");
	if o.count > ONB_MAX_OPTIONS o.count = ONB_MAX_OPTIONS;
	return o;
}

onb_answered :: (p: etf.Map) -> bool {
	for onb_options(p) if array_find(onb.chosen, dc.fsnow(dc.vmap(it), "id")) return true;
	return false;
}

// Toggle an answer; a single-choice question keeps only it.
onb_toggle :: (p: etf.Map, id: dc.Snowflake) {
	was := array_find(onb.chosen, id);
	if dc.fbool(p, "single_select") for onb_options(p) array_unordered_remove_by_value(*onb.chosen, dc.fsnow(dc.vmap(it), "id"));
	if was array_unordered_remove_by_value(*onb.chosen, id);
	else array_add(*onb.chosen, id);
}

// {"onboarding_responses":[ids],"onboarding_prompts_seen":{id:ms},"onboarding_responses_seen":{id:ms}} over the
// questions shown (POST at the end of onboarding, PUT from Channels & Roles), as the client's.
onb_save :: (prompts: []etf.Map, post: bool) {
	if !net_action() return;
	now := wall_ms();
	ids, seen_p, seen_o: String_Builder;
	ids.allocator, seen_p.allocator, seen_o.allocator = temp, temp, temp;
	n_ids, n_o := 0, 0;
	for p: prompts {
		print_to_builder(*seen_p, "%\"%\":%", ifx it_index then "," else "", dc.fsnow(p, "id"), now);
		for onb_options(p) {
			id := dc.fsnow(dc.vmap(it), "id");
			print_to_builder(*seen_o, "%\"%\":%", ifx n_o then "," else "", id, now);
			n_o += 1;
			if !array_find(onb.chosen, id) continue;
			print_to_builder(*ids, "%\"%\"", ifx n_ids then "," else "", id);
			n_ids += 1;
		}
	}
	body := tprint("{\"onboarding_responses\":[%],\"onboarding_prompts_seen\":{%},\"onboarding_responses_seen\":{%}}",
		builder_to_string(*ids,, temp), builder_to_string(*seen_p,, temp), builder_to_string(*seen_o,, temp));
	dc.feature_submit(app.client, .Onboarding, ifx post then "POST" else "PUT", tprint("/guilds/%/onboarding-responses", onb.guild), body, channel_id = onb.guild, tag = ONB_RESPONSES);
}

// ---- drawing ----

// The page's centred column (at most 660 wide), scrolled; close with page_column_end.
page_column_begin :: (id: string) {
	sc := ui.box(id, .Scroll_Y | .Clip);
	sc.semantic_size = .[ui.pct(1), ui.fill()];
	sc.layout_axis = .Y;
	ui.signal(sc);
	ui.push_parent(sc);
	r := row("cols");
	r.semantic_size = .[ui.pct(1), ui.children()];
	r.cross_align = .Start;
	ui.push_parent(r);
	filler(.X);
	col := ui.box("col");
	col.semantic_size = .[ui.px(min(660.0, max(240.0, app.ui.window.x - RAIL_W - app.view.sidebar_w - 64))), ui.children()];
	col.layout_axis = .Y;
	ui.push_parent(col);
	spacer(.Y, 40);
}

page_column_end :: () {
	spacer(.Y, 40);
	ui.pop_parent();
	filler(.X);
	ui.pop_parent();
	ui.pop_parent();
}

page_header :: (title: string, icon_name: string) {
	h := row("header", .Draw_Background);
	h.semantic_size = .[ui.pct(1), ui.px(HEADER_H - 1)];
	h.style.bg = T("--background-base-lower");
	{ ui.parent(h); defer ui.pop_parent();
		spacer(.X, 16);
		icon("i", icon_name, 20, T("--channel-icon"));
		spacer(.X, 8);
		label(title, .Medium, 16, T("--text-strong"), 20);
	}
	line := ui.box("hline", .Draw_Background);
	line.semantic_size = .[ui.pct(1), ui.px(1)];
	line.style.bg = T("--border-subtle");
}

wrap :: (id: string, text: string, font: Font_Id, size: float32, color: ui.Color) {
	b := ui.box(id, .Wrap_Text | .Selectable_Text);
	b.semantic_size = .[ui.pct(1), ui.text_size()];
	ui.set_spans(b, ui.Span.[.{text = text, font = F(font), size = size, color = color}]);
}

onb_emoji :: (id: string, m: etf.Map, size: float32) -> bool {
	e := dc.Emoji.{id = dc.fsnow(m, "id"), name = dc.fstr(m, "name"), animated = dc.fbool(m, "animated")};
	if !e.id && !e.name return false;
	emoji_box(id, e, size);
	return true;
}

// A clickable card: emoji, title, a muted line; outlined in brand colour when on.
page_card :: (id: string, emoji: etf.Map, title: string, sub: string, on: bool, done := false) -> bool {
	c := ui.box(id, .Clickable | .Draw_Background | .Draw_Border | .Hot_Animation);
	c.semantic_size = .[ui.fill(), ui.children()];
	c.layout_axis = .Y;
	c.style.radius = all4(8);
	c.style.border = ifx on then 2.0 else 1.0;
	c.style.border_color = ifx on then T("--background-brand") else T("--border-subtle");
	c.style.bg = ifx on then T("--background-mod-normal") else T("--background-base-low");
	c.style.bg_hot = T("--background-mod-normal");
	c.hover_cursor = .Pointer;
	clicked := ui.signal(c).clicked;
	ui.parent(c); defer ui.pop_parent();
	spacer(.Y, 12);
	r := row("r");
	r.semantic_size = .[ui.pct(1), ui.children()];
	{ ui.parent(r); defer ui.pop_parent();
		spacer(.X, 12);
		if onb_emoji("e", emoji, 24) spacer(.X, 10);
		t := ui.box("t");
		t.semantic_size = .[ui.fill(), ui.children()];
		t.layout_axis = .Y;
		{ ui.parent(t); defer ui.pop_parent();
			wrap("title", title, .Semibold, 16, T("--text-strong"));
			if sub wrap("sub", sub, .Normal, 14, T("--text-muted"));
		}
		if on || done { spacer(.X, 8); icon("ok", "checkmark-small", 20, ifx done then T("--text-feedback-positive") else T("--background-brand")); }
		spacer(.X, 12);
	}
	spacer(.Y, 12);
	return clicked;
}

// A question's answers, two to a row; true when one changed.
answer_grid :: (p: etf.Map) -> bool {
	changed := false;
	opts := onb_options(p);
	for i: 0..(opts.count + 1) / 2 - 1 {
		r := row(tprint("ar%", i));
		r.semantic_size = .[ui.pct(1), ui.children()];
		r.cross_align = .Start;
		r.style.child_gap = 12;
		{ ui.parent(r); defer ui.pop_parent();
			for j: i * 2..min(i * 2 + 1, opts.count - 1) {
				o := dc.vmap(opts[j]);
				id := dc.fsnow(o, "id");
				if page_card(tprint("o%", id), dc.fmap(o, "emoji"), dc.fstr(o, "title"), dc.fstr(o, "description"), array_find(onb.chosen, id)) {
					onb_toggle(p, id);
					changed = true;
				}
			}
			if opts.count % 2 && i * 2 + 1 >= opts.count filler(.X);
		}
		spacer(.Y, 12);
	}
	return changed;
}

page_state :: () -> bool {
	if !onb.loading && !onb.failed return false;
	wrap("state", ifx onb.loading then L("Loading…") else L("Couldn't load this page."), .Normal, 16, T("--text-muted"));
	return true;
}

onboarding_page :: () {
	g := dc.guild_get(store(), onb.guild);
	prompts := onb_prompts(onb_parse(onb.form), true);
	onb.step = clamp(onb.step, 0, max(prompts.count - 1, 0));
	finish := false;
	page_column_begin("onb");
	{
		label(tprint(L("Welcome to %"), g.name), .Medium, 14, T("--text-muted"), 18);
		spacer(.Y, 8);
		if !page_state() && prompts {
			p := prompts[onb.step];
			wrap("q", dc.fstr(p, "title"), .Bold, 24, T("--text-strong"));
			spacer(.Y, 4);
			hint := ifx dc.fbool(p, "single_select") then L("Pick one.") else L("Pick as many as you like.");
			if dc.fbool(p, "required") hint = tprint("% %", hint, L("Required."));
			label(tprint("%  ·  %", tprint(L("Question % of %"), onb.step + 1, prompts.count), hint), .Normal, 14, T("--text-muted"), 18);
			spacer(.Y, 20);
			answer_grid(p);
			spacer(.Y, 12);
			br := row("btns");
			br.semantic_size = .[ui.pct(1), ui.px(38)];
			{ ui.parent(br); defer ui.pop_parent();
				if onb.step > 0 && adm_button("back", L("Back"), .Secondary) onb.step -= 1;
				filler(.X);
				last := onb.step == prompts.count - 1;
				ok := !dc.fbool(p, "required") || onb_answered(p);
				text := ifx last then L("Finish") else ifx onb_answered(p) then L("Next") else L("Skip");
				if adm_button("next", text, .Primary, ok) {
					if last finish = true;
					else onb.step += 1;
				}
			}
		} else if !onb.loading {
			finish = true;
		}
	}
	page_column_end();
	if !finish return;
	// the answers go in, the member is done, and the first default channel opens
	if prompts onb_save(prompts, post = true);
	m := dc.member_get(store(), onb.guild, store().me);
	if m m.flags |= MEMBER_COMPLETED_ONBOARDING; // GUILD_MEMBER_UPDATE says so too
	onb.page = .None;
	for dc.flist(onb_parse(onb.form), "default_channel_ids") {
		ch := dc.channel_get(store(), dc.vsnow(it));
		if ch && ch.guild_id == onb.guild && ch.kind != .Guild_Category { select_channel(onb.guild, ch.id); break; }
	}
}

customize_page :: () {
	page_header(L("Channels & Roles"), "user-check");
	prompts := onb_prompts(onb_parse(onb.form), false);
	page_column_begin("cr");
	wrap("t", L("Channels & Roles"), .Bold, 24, T("--text-strong"));
	spacer(.Y, 4);
	wrap("s", L("Answer questions to get roles and see channels."), .Normal, 16, T("--text-muted"));
	spacer(.Y, 24);
	if !page_state() {
		if !prompts wrap("none", L("This server has no questions."), .Normal, 16, T("--text-muted"));
		for p, i: prompts {
			ui.id_scope(cast(u64) i + 1); defer ui.pop_seed();
			wrap("q", dc.fstr(p, "title"), .Semibold, 18, T("--text-strong"));
			spacer(.Y, 12);
			if answer_grid(p) onb_save(prompts, post = false);
			spacer(.Y, 20);
		}
	}
	page_column_end();
}

browse_page :: () {
	page_header(L("Browse Channels"), "menu");
	s := store();
	page_column_begin("bc");
	wrap("t", L("Browse Channels"), .Bold, 24, T("--text-strong"));
	spacer(.Y, 20);
	for cid: dc.guild_channels_sorted(s, app.view.guild) {
		ch := dc.channel_get(s, cid);
		if !ch || dc.is_thread(ch) continue;
		ui.id_scope(cast(u64) cid); defer ui.pop_seed();
		if ch.kind == .Guild_Category {
			spacer(.Y, 16);
			label(to_upper_copy(ch.name,, temp), .Semibold, 12, T("--text-muted"), 16);
			spacer(.Y, 6);
			continue;
		}
		r := row("ch", .Clickable | .Draw_Background | .Hot_Animation);
		r.semantic_size = .[ui.pct(1), ui.children()];
		r.style.radius = all4(8);
		r.style.bg_hot = T("--background-mod-subtle");
		r.hover_cursor = .Pointer;
		if ui.signal(r).clicked select_channel(ch.guild_id, ch.id);
		{ ui.parent(r); defer ui.pop_parent();
			spacer(.X, 8);
			icon("i", channel_icon_name(ch), 20, T("--channel-icon"));
			spacer(.X, 8);
			t := ui.box("t");
			t.semantic_size = .[ui.fill(), ui.children()];
			t.layout_axis = .Y;
			{ ui.parent(t); defer ui.pop_parent();
				spacer(.Y, 8);
				label(ch.name, .Medium, 16, T("--text-strong"), 20);
				if ch.topic wrap("topic", ch.topic, .Normal, 14, T("--text-muted"));
				spacer(.Y, 8);
			}
			spacer(.X, 8);
		}
	}
	page_column_end();
}

guide_page :: () {
	g := dc.guild_get(store(), onb.guild);
	page_header(L("Server Guide"), "flag");
	guide := onb_parse(onb.guide);
	page_column_begin("sg");
	wrap("t", tprint(L("Welcome to %!"), g.name), .Bold, 24, T("--text-strong"));
	spacer(.Y, 12);
	if !page_state() {
		wm := dc.fmap(guide, "welcome_message");
		authors := dc.flist(wm, "author_ids");
		if authors {
			ar := row("authors");
			ar.semantic_size = .[ui.pct(1), ui.px(24)];
			ui.parent(ar); defer ui.pop_parent();
			for authors {
				if it_index >= 5 break;
				avatar_box(tprint("a%", it_index), dc.vsnow(it), 24);
				spacer(.X, 4);
			}
		}
		if authors spacer(.Y, 8);
		if dc.fstr(wm, "message") wrap("msg", dc.fstr(wm, "message"), .Normal, 16, T("--text-default"));
		for key, ki: string.["new_member_actions", "resource_channels"] {
			todo := ki == 0;
			list := dc.flist(guide, key);
			if !list continue;
			spacer(.Y, 28);
			label(ifx todo then L("NEW MEMBER TO-DOS") else L("RESOURCES"), .Semibold, 12, T("--text-muted"), 16);
			spacer(.Y, 8);
			for list {
				if it_index >= 20 break;
				a := dc.vmap(it);
				cid := dc.fsnow(a, "channel_id");
				ch := dc.channel_get(store(), cid);
				if !ch || ch.guild_id != onb.guild continue;
				sub := ifx dc.fstr(a, "description") then dc.fstr(a, "description") else tprint("#%", ch.name);
				if page_card(tprint("%1%2", key, cid), dc.fmap(a, "emoji"), dc.fstr(a, "title"), sub, false, todo && array_find(onb.done, cid)) {
					if todo && dc.fint(a, "action_type") == 0 && !array_find(onb.done, cid) && net_action() {
						array_add(*onb.done, cid);
						dc.feature_submit(app.client, .Onboarding, "POST", tprint("/guilds/%/new-member-action/%", onb.guild, cid), channel_id = onb.guild, tag = ONB_ACTION_DONE);
					}
					select_channel(onb.guild, cid);
				}
				spacer(.Y, 8);
			}
		}
	}
	page_column_end();
}
