// Guild scheduled events, as in the official client (traffic/guild_events.jsonl,
// traffic/FEATURES_NEW.md "guild_events"):
// - the Events modal ("Events" row above the channel list): header with the
//   count and Create Event, one card per live / upcoming event (start, interested
//   count, name, place, "..." menu, Share, Interested). Opening it sends science
//   only: the list comes from READY / GUILD_CREATE / GUILD_SCHEDULED_EVENT_*.
// - the Create Event wizard: Location (Voice Channel / Somewhere Else) -> Event
//   Info (topic, start date and time from the next full hour, description; end
//   for external events) -> Review (preview; GET counts for event -1) -> Create.
// - after creating, the share dialog with the event's invite link.
// - the card's menu: Start Event (voice, permitted), Cancel Event (confirm), Copy Event Link.
// Requests live in jai/discord/guild_admin.jai.

events_open :: (gid: dc.Snowflake) {
	evu.open = true;
	evu.guild = gid;
	evu.menu_event = 0;
	if app.client != null dc.open_guild_events(app.client, gid);
}

events_modal_open :: () -> bool { return evu.open || evu.wiz_open || evu.share_event != 0 || evu.confirm_event != 0; }

events_reset_for_test :: () {
	ui.editor_destroy(*evu.location);
	ui.editor_destroy(*evu.name);
	ui.editor_destroy(*evu.desc);
	free(evu.error);
	evu = .{};
	dc.events_destroy(); // the sweep reloads fixtures without destroying the Store
}

events_state_for_test :: () -> string {
	return tprint("% % % % % % % % % %", evu.open, evu.guild, evu.wiz_open, evu.step, evu.entity, evu.channel, evu.share_event, evu.menu_event, evu.confirm_event, dc.events_epoch());
}

// "1 Event" / "3 Events" / "Events": the channel list row.
events_row_label :: (gid: dc.Snowflake) -> string {
	n := dc.guild_events(gid).count;
	if n == 0 return "Events";
	return tprint("% Event%", n, ifx n == 1 then "" else "s");
}

events_receive :: (r: *dc.Feature_Result) {
	if app.client != null dc.guild_admin_apply(app.client, r);
	app.ui.animating = true;
	if r.op == {
	case .Event_Create;
		if !evu.wiz_open return;
		evu.busy = false;
		if !r.ok {
			set_wiz_error(ifx r.status == 0 then "Couldn't reach Discord. Check your connection and try again." else dc.api_error_message(r.body));
			if evu.error == "" set_wiz_error(tprint("Something went wrong (HTTP %).", r.status));
			return;
		}
		evu.wiz_open = false;
		evu.open = true;
		// the library already asked for the event's invite (dc.event_share)
		share_open(dc.fsnow(dc.vmap(r.body), "id"), created = true);
	case .Event_Invite;
		if cast(dc.Snowflake)(r.tag) != evu.share_event return;
		evu.share_loading = false;
		code := ifx r.ok then dc.fstr(dc.vmap(r.body), "code") else "";
		if code == "" || code.count > evu.share_code.count {
			evu.share_failed = true;
		} else {
			memcpy(evu.share_code.data, code.data, code.count);
			evu.share_len = code.count;
		}
	case .Event_Delete;
		if cast(dc.Snowflake)(r.tag) == evu.confirm_event {
			evu.confirm_busy = false;
			if r.ok evu.confirm_event = 0;
		}
	case .Event_Start;
		e := dc.event_get(cast(dc.Snowflake) r.tag);
		if r.ok && e != null && e.entity == .Voice && e.channel_id != 0 join_voice(e.guild_id, e.channel_id);
	}
}

// ---- Events modal ----

events_modal :: () {
	if evu.guild != 0 && (dc.guild_get(store(), evu.guild) == null || app.view.guild != evu.guild) {
		evu.open, evu.wiz_open = false, false;
		evu.share_event, evu.menu_event, evu.confirm_event, evu.guild = 0, 0, 0, 0;
		return;
	}
	if evu.open && !evu.wiz_open events_list_modal();
	if evu.wiz_open wizard_modal();
	if evu.menu_event != 0 event_menu();
	if evu.confirm_event != 0 cancel_confirm();
	if evu.share_event != 0 share_modal();
}

// Equal-width button filling its share of the row.
wide_button :: (id: string, text: string, kind: Adm_Button, enabled := true) -> bool {
	b := ui.box(tprint("%##%", text, id), .Clickable | .Draw_Background | .Draw_Text | .Hot_Animation);
	b.semantic_size = .[ui.fill(), ui.px(40)];
	b.style.radius = all4(8);
	b.style.font = F(.Medium);
	b.style.font_size = 16;
	b.style.text_align = .Center;
	b.hover_cursor = .Pointer;
	if kind == {
	case .Primary;
		b.style.bg = T("--background-brand");
		b.style.text_color = .{1, 1, 1, 1};
	case .Danger;
		b.style.bg = T("--status-danger");
		b.style.text_color = .{1, 1, 1, 1};
	case;
		b.style.bg = T("--background-mod-strong");
		b.style.text_color = T("--text-strong");
	}
	b.style.bg_hot = with_alpha(b.style.bg, 0.85);
	if !enabled {
		b.flags |= .Disabled;
		b.style.bg = with_alpha(b.style.bg, 0.5);
		b.style.bg_hot = b.style.bg;
		b.style.text_color = with_alpha(b.style.text_color, 0.5);
	}
	return ui.signal(b).clicked && enabled;
}

// An invite link to an event ("discord.gg/<code>?event=<id>"): the event's start, creator,
// interested count, name and description, then the guild and the place, and the button
// (GuildScheduledEventInviteEmbed): Join outside the guild; inside it Interested before the
// start, Join / Go To Channel / View Details while live, "Event is over" after. Clicking the
// card opens the guild's Events (the client opens the event's details).
event_invite_card :: (id: string, key: string, p: dc.Invite_Preview, m: *dc.Message) {
	W :: 432.0;
	ICON :: 48.0;
	member := is_member_of(p);
	// a guild we're in has the live event (interest, counts) in the events table; the count
	// comes from its counts request (0 until then, and outside the guild)
	e := ifx member then dc.event_get(p.event.id);
	if e && e.user_count < 0 && app.client != null dc.event_ask_counts(app.client, e.id);
	shown := ifx e then e.* else p.event;
	shown.user_count = max(shown.user_count, 0);
	spacer(.Y, 4);
	card := ui.box(id, .Draw_Background | .Draw_Border | .Clickable);
	card.semantic_size = .[ui.px(W), ui.children()];
	card.layout_axis = .Y;
	card.style.bg = T("--embed-background");
	card.style.border_color = T("--border-subtle");
	card.style.border = 1;
	card.style.radius = all4(8);
	card.hover_cursor = .Pointer;
	if ui.signal(card).clicked && member events_open(p.guild_id);
	ui.parent(card); defer ui.pop_parent();
	ui.id_scope(cast(u64) p.event.id); defer ui.pop_seed();
	event_card_head(*shown);
	spacer(.Y, 16);
	br := row("bottom");
	br.semantic_size = .[ui.pct(1), ui.px(ICON)];
	{ ui.parent(br); defer ui.pop_parent();
		spacer(.X, 16);
		gi := ui.box("gicon", .Draw_Background | .Draw_Text);
		gi.semantic_size = .[ui.px(ICON), ui.px(ICON)];
		gi.style.radius = all4(16);
		gi.style.bg = T("--background-mod-subtle");
		gi.style.text_color = T("--text-default");
		gi.style.text_align = .Center;
		gi.style.font = F(.Medium);
		gi.style.font_size = 16;
		gi.text = guild_initials(p.name);
		if p.icon != "" {
			set_remote_image(gi, dc.guild_icon_url(p.guild_id, p.icon, 128));
			gi.text = "";
		}
		spacer(.X, 12);
		col := ui.box("col");
		col.semantic_size = .[ui.fill(), ui.children()];
		col.layout_axis = .Y;
		{ ui.parent(col); defer ui.pop_parent();
			spacer(.Y, 4);
			label(ellipsize(p.name, .Medium, 16, 200), .Medium, 16, T("--text-strong"), 20);
			pr := row("place");
			pr.semantic_size = .[ui.pct(1), ui.px(20)];
			{ ui.parent(pr); defer ui.pop_parent();
				place, place_icon := place_of(*shown);
				icon("pl", place_icon, 16, T("--text-default"));
				spacer(.X, 4);
				label(ellipsize(place, .Normal, 14, 180), .Normal, 14, T("--text-default"), 18);
			}
		}
		secondary, fg := T("--background-mod-normal"), T("--text-strong");
		if !member || (e && e.status == .Active && e.entity != .External && app.voice_channel != e.channel_id) {
			if pill_button("join", ifx p.joining then "Joining…" else "Join", "", T("--status-positive-background"), T("--status-positive-text"), 40) && !p.joining && net_action() {
				if member go_to_invite(p);
				else dc.join_invite_preview(app.client, key, dc.INVITE_LOC_EMBED, invite_instance(m.id, key));
			}
		} else if e && e.status == .Scheduled {
			interested_button(e, 40);
		} else if e && e.status == .Active && e.entity == .External {
			if pill_button("details", "View Details", "", secondary, fg, 40) events_open(p.guild_id);
		} else if e && e.status == .Active {
			if pill_button("go", "Go To Channel", "", secondary, fg, 40) select_channel(p.guild_id, e.channel_id);
		} else if e {
			pill_button("over", "Event is over", "", secondary, T("--text-muted"), 40);
		}
		spacer(.X, 16);
	}
	spacer(.Y, 16);
}

#scope_file

Wizard_Step :: enum u8 {
	Location;
	Info;
	Review;
}

Events_UI :: struct {
	open: bool;
	guild: dc.Snowflake;
	// Create Event wizard
	wiz_open: bool;
	step: Wizard_Step;
	entity: dc.Event_Entity; // .Unknown until a location type is picked
	channel: dc.Snowflake; // voice
	location: ui.Editor;
	name: ui.Editor;
	desc: ui.Editor;
	start_ms: s64;
	end_ms: s64;
	busy: bool;
	error: string; // heap
	focus_next: bool;
	// share dialog
	share_event: dc.Snowflake;
	share_code: [32]u8;
	share_len: int;
	share_loading: bool;
	share_failed: bool;
	share_copied: bool;
	share_created: bool; // opened right after Create Event (else from a card's Share)
	// card menu and cancel confirm
	menu_event: dc.Snowflake;
	menu_pos: ui.Vec2;
	confirm_event: dc.Snowflake;
	confirm_busy: bool;
}

evu: Events_UI;

set_wiz_error :: (msg: string) {
	free(evu.error);
	evu.error = copy_string(msg);
}

// ---- time ----

// Calendar fields of a unix ms time already shifted to local time (read as UTC).
calendar :: (local_ms: s64) -> Calendar_Time { return to_calendar(dc.UNIX_EPOCH + milliseconds_to_apollo(local_ms)); }

clock_text :: (local_ms: s64) -> string {
	t := calendar(local_ms);
	h12 := ifx t.hour % 12 then t.hour % 12 else 12;
	return tprint("%:% %", h12, formatInt(t.minute, minimum_digits = 2), ifx t.hour >= 12 then "PM" else "AM");
}

MONTHS :: string.["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

// "Oct 26, 2026" (local)
date_text :: (ms: s64) -> string {
	t := calendar(ms + local_utc_offset_ms());
	return tprint("% %, %", MONTHS[t.month_starting_at_0], t.day_of_month_starting_at_0 + 1, t.year);
}

// "Today at 3:00 PM", "Tomorrow at ...", "Mon, Oct 27 at 3:00 PM" in local time.
event_when :: (ms: s64) -> string {
	off := local_utc_offset_ms();
	local := ms + off;
	clock := clock_text(local);
	day := local / 86_400_000;
	today := (wall_ms() + off) / 86_400_000;
	if day == today return tprint("Today at %", clock);
	if day == today + 1 return tprint("Tomorrow at %", clock);
	DAYS :: string.["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
	t := calendar(local);
	return tprint("%, % % at %", DAYS[t.day_of_week_starting_at_0], MONTHS[t.month_starting_at_0], t.day_of_month_starting_at_0 + 1, clock);
}

// "Starting in 41m" within the hour, else the start time.
event_start_text :: (ms: s64) -> string {
	diff := ms - wall_ms();
	if diff > 0 && diff < 3_600_000 return tprint("Starting in %m", max(1, diff / 60_000));
	return event_when(ms);
}

// ---- shared pieces ----

// Scrim + centered dialog (no title row), pushed as parent; false when the scrim was clicked.
ev_dialog_begin :: (id: string, w: float32, fixed_h: float32 = 0) -> bool {
	scrim := ui.box(tprint("%_scrim", id), .Draw_Background | .Clickable | .Floating_X | .Floating_Y | .Overlay);
	scrim.semantic_size = .[ui.px(app.ui.window.x), ui.px(app.ui.window.y)];
	scrim.style.bg = .{0, 0, 0, 0.7};
	if ui.signal(scrim).clicked return false;
	d := ui.box(id, .Draw_Background | .Draw_Border | .Floating_X | .Floating_Y | .Overlay | .Clickable | .Clip);
	d.semantic_size = .[ui.px(w), ifx fixed_h > 0 then ui.px(fixed_h) else ui.children()];
	d.fixed_pos = .{(app.ui.window.x - w) / 2, max(16.0, (app.ui.window.y - (d.rect.y1 - d.rect.y0)) / 2)};
	d.style.bg = T("--modal-background");
	d.style.border_color = T("--border-subtle");
	d.style.border = 1;
	d.style.radius = all4(12);
	d.layout_axis = .Y;
	ui.signal(d);
	ui.push_parent(d);
	return true;
}

close_x :: (id: string, x: float32, y: float32) -> bool {
	b := ui.box(id, .Clickable | .Floating_X | .Floating_Y);
	b.semantic_size = .[ui.px(24), ui.px(24)];
	b.fixed_pos = .{x, y};
	sig := ui.signal(b);
	set_icon(b, "x-large", ifx sig.hovering then T("--interactive-icon-hover") else T("--interactive-icon-default"));
	return sig.clicked;
}

// Small button with an optional icon (card actions, header Create Event).
pill_button :: (id: string, text: string, icon_name: string, bg: ui.Color, fg: ui.Color, h: float32 = 32) -> bool {
	b := row(id, .Clickable | .Draw_Background | .Hot_Animation);
	b.semantic_size = .[ui.children(), ui.px(h)];
	b.style.radius = all4(8);
	b.style.bg = bg;
	b.style.bg_hot = with_alpha(bg, bg.w * 0.8);
	b.hover_cursor = .Pointer;
	sig := ui.signal(b);
	{ ui.parent(b); defer ui.pop_parent();
		spacer(.X, ifx text == "" then 8.0 else 12.0);
		if icon_name != "" {
			icon("i", icon_name, 16, fg);
			if text != "" spacer(.X, 6);
		}
		if text != "" label(text, .Medium, 14, fg, 18);
		spacer(.X, ifx text == "" then 8.0 else 12.0);
	}
	return sig.clicked;
}

hline :: (id: string, pad: float32 = 0) {
	r := row(id);
	r.semantic_size = .[ui.pct(1), ui.px(1)];
	{ ui.parent(r); defer ui.pop_parent();
		spacer(.X, pad);
		l := ui.box("l", .Draw_Background);
		l.semantic_size = .[ui.fill(), ui.px(1)];
		l.style.bg = T("--border-subtle");
		spacer(.X, pad);
	}
}

place_of :: (e: *dc.Scheduled_Event) -> string, string {
	if e.entity == .Voice || e.entity == .Stage_Instance {
		ch := dc.channel_get(store(), e.channel_id);
		return ifx ch then ch.name else "Unknown channel", ifx e.entity == .Voice then "voice-normal" else "stage";
	}
	return e.location, "location";
}

events_list_modal :: () {
	evs := dc.guild_events(evu.guild);
	W :: 604;
	H :: 400;
	top := evu.share_event == 0 && evu.confirm_event == 0 && evu.menu_event == 0;
	if !ev_dialog_begin("events", W, H) {
		if top evu.open = false;
		return;
	}
	defer ui.pop_parent();
	spacer(.Y, 20);
	hdr := row("hdr");
	hdr.semantic_size = .[ui.pct(1), ui.px(32)];
	{ ui.parent(hdr); defer ui.pop_parent();
		spacer(.X, 24);
		icon("cal", "calendar", 24, T("--interactive-icon-hover"));
		spacer(.X, 8);
		label(events_row_label(evu.guild), .Semibold, 16, T("--text-strong"), 20);
		if dc.can_create_events(store(), evu.guild) {
			spacer(.X, 16);
			d := ui.box("div", .Draw_Background);
			d.semantic_size = .[ui.px(1), ui.px(24)];
			d.style.bg = T("--border-subtle");
			spacer(.X, 16);
			if pill_button("create", "Create Event", "", T("--background-brand"), .{1, 1, 1, 1}) { wizard_open(); }
		}
	}
	if close_x("close", W - 24 - 20, 20) && top evu.open = false;
	spacer(.Y, 16);
	if evs.count == 0 {
		events_empty();
	} else {
		list := ui.box("list", .Scroll_Y | .Clip);
		list.semantic_size = .[ui.pct(1), ui.fill()];
		list.layout_axis = .Y;
		ui.signal(list);
		{ ui.parent(list); defer ui.pop_parent();
			for evs {
				ui.id_scope(cast(u64) it.id);
				event_card(it);
				ui.pop_seed();
			}
			spacer(.Y, 8);
		}
	}
	if top && adm_escape() evu.open = false;
}

center_line :: (id: string, text: string, font: Font_Id, size: float32, lh: float32, color: ui.Color) {
	r := row(id);
	r.semantic_size = .[ui.pct(1), ui.px(lh)];
	{ ui.parent(r); defer ui.pop_parent();
		filler(.X);
		label(text, font, size, color, lh);
		filler(.X);
	}
}

events_empty :: () {
	filler(.Y);
	center_line("t", "There are no upcoming events.", .Bold, 24, 30, T("--text-strong"));
	spacer(.Y, 8);
	center_line("s", "Schedule an event for any planned activity in your server.", .Normal, 14, 20, T("--text-default"));
	filler(.Y);
	spacer(.Y, 60);
}

event_card :: (e: *dc.Scheduled_Event) {
	outer := row("card");
	outer.semantic_size = .[ui.pct(1), ui.children()];
	{ ui.parent(outer); defer ui.pop_parent();
		spacer(.X, 24);
		card := ui.box("c", .Draw_Background | .Draw_Border | .Clickable);
		card.semantic_size = .[ui.fill(), ui.children()];
		card.layout_axis = .Y;
		card.style.bg = T("--background-base-lower");
		card.style.border_color = T("--border-subtle");
		card.style.border = 1;
		card.style.radius = all4(8);
		csig := ui.signal(card);
		if csig.right_clicked menu_open(e.id, app.ui.mouse);
		{ ui.parent(card); defer ui.pop_parent(); event_card_body(e, true); }
		spacer(.X, 24);
	}
	spacer(.Y, 12);
}

// The card's content (also the Review step's preview, without actions).
event_card_body :: (e: *dc.Scheduled_Event, actions: bool) {
	event_card_head(e);
	spacer(.Y, 16);
	hline("hl");
	br := row("bottom");
	br.semantic_size = .[ui.pct(1), ui.px(60)];
	{ ui.parent(br); defer ui.pop_parent();
		spacer(.X, 16);
		place, place_icon := place_of(e);
		icon("pl", place_icon, 20, T("--text-default"));
		spacer(.X, 6);
		label(ellipsize(place, .Medium, 14, 220), .Medium, 14, T("--text-default"), 18);
		filler(.X);
		if actions {
			if pill_button("more", "", "more-horizontal", T("--background-mod-normal"), T("--text-strong")) {
				menu_open(e.id, app.ui.mouse);
			}
			spacer(.X, 8);
			if pill_button("share", "Share", "share", T("--background-mod-normal"), T("--text-strong")) {
				share_open(e.id);
				if net_action() dc.event_share(app.client, e.id);
			}
			spacer(.X, 8);
			interested_button(e);
		}
		spacer(.X, 16);
	}
}

interested_button :: (e: *dc.Scheduled_Event, h: float32 = 32) {
	bg := ifx e.interested then T("--status-positive") else T("--background-mod-normal");
	fg: ui.Color = ifx e.interested then .{1, 1, 1, 1} else T("--text-strong");
	if pill_button("interested", "Interested", ifx e.interested then "checkmark-small" else "bell", bg, fg, h) && !e.interest_pending && net_action() {
		dc.set_event_interest(app.client, e.id, !e.interested);
	}
}

// Start, creator, interested count, name and description.
event_card_head :: (e: *dc.Scheduled_Event) {
	spacer(.Y, 16);
	wr := row("when");
	wr.semantic_size = .[ui.pct(1), ui.px(22)];
	{ ui.parent(wr); defer ui.pop_parent();
		spacer(.X, 16);
		if e.status == .Active {
			dot := ui.box("live", .Draw_Background);
			dot.semantic_size = .[ui.px(8), ui.px(8)];
			dot.style.radius = all4(4);
			dot.style.bg = T("--status-positive");
			spacer(.X, 6);
			label(ifx e.entity == .External then "Happening Now" else "Live Now", .Semibold, 14, T("--text-feedback-positive"), 18);
		} else {
			icon("cal", "calendar", 18, T("--text-brand"));
			spacer(.X, 8);
			label(event_start_text(e.start_ms), .Semibold, 14, T("--text-brand"), 18);
		}
		filler(.X);
		if e.creator_id != 0 {
			avatar_box("creator", e.creator_id, 20);
			spacer(.X, 8);
		}
		if e.user_count >= 0 {
			pill := row("count", .Draw_Background);
			pill.semantic_size = .[ui.children(), ui.px(22)];
			pill.style.radius = all4(11);
			pill.style.bg = T("--background-base-lowest");
			{ ui.parent(pill); defer ui.pop_parent();
				spacer(.X, 8);
				icon("grp", "group", 14, T("--text-strong"));
				spacer(.X, 4);
				label(tprint("%", e.user_count), .Semibold, 14, T("--text-strong"), 18);
				spacer(.X, 8);
			}
		}
		spacer(.X, 16);
	}
	spacer(.Y, 8);
	nr := row("name");
	nr.semantic_size = .[ui.pct(1), ui.children()];
	{ ui.parent(nr); defer ui.pop_parent();
		spacer(.X, 16);
		b := ui.box("n", .Draw_Text | .Wrap_Text);
		b.semantic_size = .[ui.fill(), ui.text_size()];
		b.text = e.name;
		b.style.font = F(.Semibold);
		b.style.font_size = 20;
		b.style.line_height = 24;
		b.style.text_color = T("--text-strong");
		spacer(.X, 16);
	}
	if e.description != "" {
		spacer(.Y, 4);
		dr := row("desc");
		dr.semantic_size = .[ui.pct(1), ui.children()];
		{ ui.parent(dr); defer ui.pop_parent();
			spacer(.X, 16);
			b := ui.box("d", .Draw_Text | .Wrap_Text);
			b.semantic_size = .[ui.fill(), ui.text_size()];
			b.text = e.description;
			b.style.font = F(.Normal);
			b.style.font_size = 14;
			b.style.line_height = 18;
			b.style.text_color = T("--text-default");
			spacer(.X, 16);
		}
	}
}

// ---- card menu ----

menu_open :: (id: dc.Snowflake, at: ui.Vec2) {
	evu.menu_event = id;
	evu.menu_pos = at;
}

event_menu :: () {
	e := dc.event_get(evu.menu_event);
	if e == null || outside_pressed("evmenu_out") || escape_pressed() {
		evu.menu_event = 0;
		return;
	}
	W :: 188.0;
	manage := dc.can_manage_event(store(), e);
	can_start := manage && e.status == .Scheduled && e.entity == .Voice;
	n := 1 + cast(int) can_start + cast(int) manage;
	h := cast(float32)(16 + n * GM_ROW_H);
	pos := evu.menu_pos;
	pos.x = min(pos.x, app.ui.window.x - W - 8);
	pos.y = min(pos.y, app.ui.window.y - h - 8);
	p := menu_panel("evmenu", pos, W);
	{ ui.parent(p); defer ui.pop_parent();
		spacer(.Y, 8);
		if can_start {
			if menu_item("start", "Start Event").clicked {
				evu.menu_event = 0;
				if net_action() dc.start_scheduled_event(app.client, e.id);
			}
		}
		if manage {
			if menu_item("cancel", "Cancel Event", danger = true).clicked {
				evu.menu_event = 0;
				evu.confirm_event = e.id;
				evu.confirm_busy = false;
			}
		}
		if menu_item("copylink", "Copy Event Link").clicked {
			clipboard_set(dc.event_link(e));
			evu.menu_event = 0;
		}
		spacer(.Y, 8);
	}
}

cancel_confirm :: () {
	if dc.event_get(evu.confirm_event) == null {
		evu.confirm_event = 0;
		return;
	}
	W :: 400;
	if !ev_dialog_begin("evcancel", W) {
		evu.confirm_event = 0;
		return;
	}
	confirm := false;
	{ // the dialog is the parent until here
		defer ui.pop_parent();
		if close_x("close", W - 24 - 16, 20) evu.confirm_event = 0;
		spacer(.Y, 24);
		t := row("t");
		t.semantic_size = .[ui.pct(1), ui.px(26)];
		{ ui.parent(t); defer ui.pop_parent();
			spacer(.X, 24);
			label("Cancel Event?", .Bold, 20, T("--text-strong"), 26);
		}
		spacer(.Y, 8);
		b := row("b");
		b.semantic_size = .[ui.pct(1), ui.px(20)];
		{ ui.parent(b); defer ui.pop_parent();
			spacer(.X, 24);
			label("Are you sure you want to cancel this event?", .Normal, 16, T("--text-default"), 20);
		}
		spacer(.Y, 24);
		btns := row("btns");
		btns.semantic_size = .[ui.pct(1), ui.px(40)];
		btns.style.child_gap = 8;
		{ ui.parent(btns); defer ui.pop_parent();
			spacer(.X, 24 - 8);
			if wide_button("never", "Never Mind", .Secondary) evu.confirm_event = 0;
			if wide_button("confirm", ifx evu.confirm_busy then "Cancelling..." else "Cancel Event", .Danger, !evu.confirm_busy) confirm = true;
			spacer(.X, 24 - 8);
		}
		spacer(.Y, 24);
	}
	if adm_escape() evu.confirm_event = 0;
	if confirm && evu.confirm_event != 0 && net_action() {
		evu.confirm_busy = true;
		dc.cancel_scheduled_event(app.client, evu.confirm_event);
	}
}

// ---- share dialog ----

share_open :: (id: dc.Snowflake, created := false) {
	evu.share_event = id;
	evu.share_created = created;
	evu.share_len = 0;
	evu.share_loading = true;
	evu.share_failed = false;
	evu.share_copied = false;
}

share_modal :: () {
	W :: 480;
	if !ev_dialog_begin("evshare", W) {
		evu.share_event = 0;
		return;
	}
	{ // the dialog is the parent until here
		defer ui.pop_parent();
		if close_x("close", W - 24 - 16, 16) evu.share_event = 0;
		spacer(.Y, 24);
		ic := row("ic");
		ic.semantic_size = .[ui.pct(1), ui.px(64)];
		{ ui.parent(ic); defer ui.pop_parent();
			filler(.X);
			c := ui.box("circle", .Draw_Background);
			c.semantic_size = .[ui.px(64), ui.px(64)];
			c.style.radius = all4(32);
			c.style.bg = T("--background-base-lowest");
			{ ui.parent(c); defer ui.pop_parent();
				i := icon("i", "calendar", 28, T("--text-strong"));
				i.flags |= .Floating_X | .Floating_Y;
				i.fixed_pos = .{18, 18};
			}
			filler(.X);
		}
		spacer(.Y, 24);
		center_line("t", ifx evu.share_created then "All set. Now share your event!" else "Share Event", .Bold, 24, 30, T("--text-strong"));
		spacer(.Y, 8);
		pr := row("p");
		pr.semantic_size = .[ui.pct(1), ui.children()];
		{ ui.parent(pr); defer ui.pop_parent();
			spacer(.X, 24);
			b := ui.box("text", .Draw_Text | .Wrap_Text);
			b.semantic_size = .[ui.fill(), ui.text_size()];
			b.text = "Copy the event link below to invite people to your event. This also acts as a server invite link.";
			b.style.font = F(.Normal);
			b.style.font_size = 16;
			b.style.line_height = 20;
			b.style.text_align = .Center;
			b.style.text_color = T("--text-default");
			spacer(.X, 24);
		}
		spacer(.Y, 24);
		lr := row("linkrow");
		lr.semantic_size = .[ui.pct(1), ui.px(40)];
		{ ui.parent(lr); defer ui.pop_parent();
			spacer(.X, 24);
			box := row("link", .Draw_Background | .Draw_Border);
			box.semantic_size = .[ui.fill(), ui.px(40)];
			box.style.bg = T("--input-background-default");
			box.style.border = 1;
			box.style.border_color = T("--input-border-default");
			box.style.radius = all4(8);
			{ ui.parent(box); defer ui.pop_parent();
				spacer(.X, 12);
				url := "";
				if evu.share_len > 0 url = dc.event_invite_link(string.{evu.share_len, evu.share_code.data}, evu.share_event);
				shown := url;
				color := T("--text-strong");
				if evu.share_loading {
					shown, color = "Creating an invite...", T("--text-muted");
				} else if evu.share_failed {
					shown, color = "Couldn't create an invite.", T("--text-feedback-critical");
				}
				label(ellipsize(shown, .Normal, 16, W - 48 - 110), .Normal, 16, color, 20);
				filler(.X);
				kind := ifx evu.share_copied then Button_Kind.Positive else Button_Kind.Primary;
				if set_button(ifx evu.share_copied then "Copied##copy" else "Copy##copy", kind, url != "", 32) {
					clipboard_set(url);
					evu.share_copied = true;
				}
				spacer(.X, 4);
			}
			spacer(.X, 24);
		}
		spacer(.Y, 8);
		er := row("exp");
		er.semantic_size = .[ui.pct(1), ui.px(16)];
		{ ui.parent(er); defer ui.pop_parent();
			spacer(.X, 24);
			label("Your invite link expires in 7 days.", .Normal, 12, T("--text-default"), 16);
		}
		spacer(.Y, 24);
	}
	if adm_escape() evu.share_event = 0;
}

// ---- Create Event wizard ----

wizard_open :: () {
	evu.wiz_open = true;
	evu.step = .Location;
	evu.entity = .Unknown;
	evu.channel = 0;
	evu.busy = false;
	set_wiz_error("");
	ui.editor_set_text(*evu.location, "");
	ui.editor_set_text(*evu.name, "");
	ui.editor_set_text(*evu.desc, "");
	app.ui.focus = 0;
	if app.client != null dc.open_create_event(app.client, evu.guild);
}

voice_channels :: (gid: dc.Snowflake) -> []dc.Snowflake {
	out: [..]dc.Snowflake;
	out.allocator = temp;
	s := store();
	for id: dc.guild_channels_sorted(s, gid) {
		ch := dc.channel_get(s, id);
		if ch != null && ch.kind == .Guild_Voice array_add(*out, id);
	}
	return out;
}

step_valid :: (step: Wizard_Step) -> bool {
	if step == {
	case .Location;
		if evu.entity == .Voice return evu.channel != 0;
		if evu.entity == .External return trim(ui.editor_text(*evu.location)) != "";
		return false;
	case .Info;
		if trim(ui.editor_text(*evu.name)) == "" || evu.start_ms <= wall_ms() return false;
		return evu.entity != .External || evu.end_ms > evu.start_ms;
	case .Review;
		return true;
	}
	return false;
}

wizard_modal :: () {
	W :: 480;
	if !ev_dialog_begin("evwizard", W) {
		evu.wiz_open = false;
		return;
	}
	next, back, cancel := false, false, false;
	{ // the dialog is the parent until here
		defer ui.pop_parent();
		spacer(.Y, 16);
		// progress: Location / Event Info / Review
		pr := row("progress");
		pr.semantic_size = .[ui.pct(1), ui.px(28)];
		pr.style.child_gap = 8;
		{ ui.parent(pr); defer ui.pop_parent();
			spacer(.X, 16 - 8);
			NAMES := string.["Location", "Event Info", "Review"];
			for name, i: NAMES {
				cur := cast(int) evu.step == i;
				col := ui.box(name);
				col.semantic_size = .[ui.fill(), ui.px(28)];
				col.layout_axis = .Y;
				{ ui.parent(col); defer ui.pop_parent();
					bar := ui.box("bar", .Draw_Background);
					bar.semantic_size = .[ui.pct(1), ui.px(4)];
					bar.style.radius = all4(2);
					bar.style.bg = ifx cur then T("--background-brand") else T("--interactive-text-default");
					if !cur bar.style.bg = with_alpha(bar.style.bg, 0.6);
					spacer(.Y, 8);
					label(name, .Medium, 12, ifx cur then T("--text-brand") else T("--text-default"), 16);
				}
			}
			spacer(.X, 16 - 8);
		}
		spacer(.Y, 16);
		body := ui.box("body", .Scroll_Y | .Clip);
		max_h := max(200.0, app.ui.window.y - 220);
		body.semantic_size = .[ui.pct(1), ui.px(ifx body.content_size.y > 0 then min(body.content_size.y, max_h) else 240)];
		body.layout_axis = .Y;
		ui.signal(body);
		{ ui.parent(body); defer ui.pop_parent();
			if evu.step == {
			case .Location;
				step_location();
			case .Info;
				step_info();
			case .Review;
				step_review();
			}
			if evu.error != "" {
				spacer(.Y, 8);
				er := row("err");
				er.semantic_size = .[ui.pct(1), ui.children()];
				{ ui.parent(er); defer ui.pop_parent();
					spacer(.X, 16);
					b := ui.box("t", .Draw_Text | .Wrap_Text);
					b.semantic_size = .[ui.fill(), ui.text_size()];
					b.text = evu.error;
					b.style.font = F(.Normal);
					b.style.font_size = 14;
					b.style.line_height = 18;
					b.style.text_color = T("--text-feedback-critical");
					spacer(.X, 16);
				}
			}
		}
		spacer(.Y, 16);
		btns := row("btns");
		btns.semantic_size = .[ui.pct(1), ui.px(40)];
		btns.style.child_gap = 8;
		{ ui.parent(btns); defer ui.pop_parent();
			spacer(.X, 16 - 8);
			if evu.step != .Location && set_button("Back##back", .Link, !evu.busy, 40) back = true;
			filler(.X);
			if set_button("Cancel##cancel", .Secondary, true, 40) cancel = true;
			if evu.step == .Review {
				if set_button(ifx evu.busy then "Creating...##next" else "Create Event##next", .Primary, !evu.busy, 40) next = true;
			} else {
				if set_button("Next##next", .Primary, step_valid(evu.step), 40) next = true;
			}
			spacer(.X, 16 - 8);
		}
		spacer(.Y, 16);
	}
	if adm_escape() cancel = true;
	if cancel {
		evu.wiz_open = false;
		app.ui.focus = 0;
	} else if back {
		evu.step -= 1;
		set_wiz_error("");
	} else if next && step_valid(evu.step) {
		set_wiz_error("");
		if evu.step == {
		case .Location;
			evu.step = .Info;
			// defaults: the next full hour; external events end an hour later
			evu.start_ms = dc.default_event_start_ms(wall_ms(), local_utc_offset_ms());
			evu.end_ms = evu.start_ms + 3_600_000;
			evu.focus_next = true;
			app.ui.focus = 0; // the topic field takes it
		case .Info;
			evu.step = .Review;
			app.ui.focus = 0;
			if app.client != null dc.event_preview_counts(app.client, evu.guild);
		case .Review;
			if !evu.busy && net_action() {
				evu.busy = true;
				dc.create_scheduled_event(app.client, evu.guild, draft());
			}
		}
	}
}

draft :: () -> dc.Event_Draft {
	return .{
		name = trim(ui.editor_text(*evu.name)),
		description = trim(ui.editor_text(*evu.desc)),
		start_ms = evu.start_ms,
		end_ms = evu.end_ms,
		entity = evu.entity,
		channel_id = evu.channel,
		location = trim(ui.editor_text(*evu.location))
	};
}

step_heading :: (title: string, sub: string) {
	t := row("h");
	t.semantic_size = .[ui.pct(1), ui.px(30)];
	{ ui.parent(t); defer ui.pop_parent();
		spacer(.X, 16);
		label(title, .Bold, 24, T("--text-strong"), 30);
	}
	spacer(.Y, 4);
	s := row("sub");
	s.semantic_size = .[ui.pct(1), ui.px(18)];
	{ ui.parent(s); defer ui.pop_parent();
		spacer(.X, 16);
		label(sub, .Normal, 14, T("--text-default"), 18);
	}
	spacer(.Y, 20);
}

// Radio row: circle, icon + title, description below.
radio_row :: (id: string, icon_name: string, title: string, desc: string, on: bool) -> bool {
	r := row(id, .Clickable);
	r.semantic_size = .[ui.pct(1), ui.px(58)];
	r.cross_align = .Start;
	r.hover_cursor = .Pointer;
	sig := ui.signal(r);
	{ ui.parent(r); defer ui.pop_parent();
		spacer(.X, 16);
		rb := ui.box("radio", .Draw_Border);
		rb.semantic_size = .[ui.px(20), ui.px(20)];
		rb.style.radius = all4(10);
		rb.style.border = 2;
		rb.style.border_color = ifx on then T("--background-brand") else T("--interactive-icon-default");
		if on {
			ui.parent(rb); defer ui.pop_parent();
			dot := ui.box("dot", .Draw_Background | .Floating_X | .Floating_Y);
			dot.semantic_size = .[ui.px(10), ui.px(10)];
			dot.fixed_pos = .{5, 5};
			dot.style.radius = all4(5);
			dot.style.bg = T("--background-brand");
		}
		spacer(.X, 12);
		col := ui.box("col");
		col.semantic_size = .[ui.fill(), ui.children()];
		col.layout_axis = .Y;
		{ ui.parent(col); defer ui.pop_parent();
			tr := row("t");
			tr.semantic_size = .[ui.pct(1), ui.px(20)];
			{ ui.parent(tr); defer ui.pop_parent();
				icon("i", icon_name, 20, T("--text-strong"));
				spacer(.X, 6);
				label(title, .Medium, 16, T("--text-strong"), 20);
			}
			spacer(.Y, 4);
			label(desc, .Normal, 14, T("--text-default"), 18);
		}
	}
	return sig.clicked;
}

field_label :: (text: string, required: bool) {
	r := row(tprint("lbl_%", text));
	r.semantic_size = .[ui.pct(1), ui.px(20)];
	{ ui.parent(r); defer ui.pop_parent();
		label(text, .Semibold, 16, T("--text-strong"), 20);
		if required {
			spacer(.X, 4);
			label("*", .Semibold, 16, T("--text-feedback-critical"), 20);
		}
	}
	spacer(.Y, 8);
}

// Column with 16px side padding (wizard fields).
pad_begin :: (id: string) -> *ui.Box {
	r := row(id);
	r.semantic_size = .[ui.pct(1), ui.children()];
	ui.push_parent(r);
	spacer(.X, 16);
	c := ui.box("c");
	c.semantic_size = .[ui.fill(), ui.children()];
	c.layout_axis = .Y;
	ui.push_parent(c);
	return c;
}

pad_end :: () {
	ui.pop_parent();
	spacer(.X, 16);
	ui.pop_parent();
}

step_location :: () {
	step_heading("Where is your event?", "So no one gets lost on where to go.");
	if radio_row("voice", "voice-normal", "Voice Channel", "Hang out with voice, video, screenshare, and Go Live.", evu.entity == .Voice) && evu.entity != .Voice {
		evu.entity = .Voice;
		vcs := voice_channels(evu.guild);
		if evu.channel == 0 && vcs.count > 0 evu.channel = vcs[0];
	}
	if radio_row("external", "location", "Somewhere Else", "Text channel, external link, or in-person location.", evu.entity == .External) && evu.entity != .External {
		evu.entity = .External;
		evu.focus_next = true;
	}
	if evu.entity == {
	case .Voice;
		spacer(.Y, 8);
		pad_begin("chans");
		field_label("Select a channel", true);
		vcs := voice_channels(evu.guild);
		if vcs.count == 0 label("This server has no voice channels.", .Normal, 14, T("--text-muted"), 18);
		for id: vcs {
			ch := dc.channel_get(store(), id);
			ui.id_scope(cast(u64) id);
			defer ui.pop_seed();
			sel := evu.channel == id;
			item := row("ch", .Clickable | .Draw_Background | .Draw_Border | .Hot_Animation);
			item.semantic_size = .[ui.pct(1), ui.px(40)];
			item.style.radius = all4(8);
			item.style.bg = ifx sel then T("--background-mod-strong") else T("--input-background-default");
			item.style.bg_hot = ifx sel then item.style.bg else T("--background-mod-normal");
			item.style.border = 1;
			item.style.border_color = ifx sel then T("--input-border-active") else T("--input-border-default");
			if ui.signal(item).clicked evu.channel = id;
			{ ui.parent(item); defer ui.pop_parent();
				spacer(.X, 12);
				icon("i", "voice-normal", 18, T("--text-strong"));
				spacer(.X, 8);
				label(ch.name, .Medium, 16, T("--text-strong"), 20);
			}
			spacer(.Y, 6);
		}
		pad_end();
	case .External;
		spacer(.Y, 8);
		pad_begin("loc");
		field_label("Enter a location", true);
		set_input("locin", *evu.location, "Add a location, link, or something.", max_runes = 100, autofocus = evu.focus_next);
		evu.focus_next = false;
		pad_end();
	}
}

// A date or time value with earlier / later steps.
stepper :: (id: string, text: string, icon_name: string, step_ms: s64, value: *s64) {
	box := row(id, .Draw_Background | .Draw_Border);
	box.semantic_size = .[ui.fill(), ui.px(40)];
	box.style.bg = T("--input-background-default");
	box.style.border = 1;
	box.style.border_color = T("--input-border-default");
	box.style.radius = all4(8);
	{ ui.parent(box); defer ui.pop_parent();
		spacer(.X, 12);
		label(text, .Normal, 16, T("--text-strong"), 20);
		filler(.X);
		if icon_name != "" {
			icon("ic", icon_name, 18, T("--interactive-icon-default"));
			spacer(.X, 8);
		}
		step :: (id: string, icon_name: string) -> bool {
			b := ui.box(id, .Clickable | .Draw_Background | .Hot_Animation);
			b.semantic_size = .[ui.px(24), ui.px(24)];
			b.style.radius = all4(4);
			b.style.bg_hot = T("--background-mod-normal");
			sig := ui.signal(b);
			set_icon(b, icon_name, ifx sig.hovering then T("--interactive-icon-hover") else T("--interactive-icon-default"));
			return sig.clicked;
		}
		if step("earlier", "chevron-small-left") value.* -= step_ms;
		if step("later", "chevron-small-right") value.* += step_ms;
		spacer(.X, 8);
	}
}

date_time_row :: (id: string, date_label: string, time_label: string, value: *s64) {
	r := row(id);
	r.semantic_size = .[ui.pct(1), ui.children()];
	r.style.child_gap = 16;
	{ ui.parent(r); defer ui.pop_parent();
		dc_ := ui.box("date");
		dc_.semantic_size = .[ui.fill(), ui.children()];
		dc_.layout_axis = .Y;
		{ ui.parent(dc_); defer ui.pop_parent();
			field_label(date_label, true);
			stepper("d", date_text(value.*), "calendar", 86_400_000, value);
		}
		tc := ui.box("time");
		tc.semantic_size = .[ui.fill(), ui.children()];
		tc.layout_axis = .Y;
		{ ui.parent(tc); defer ui.pop_parent();
			field_label(time_label, true);
			stepper("t", clock_text(value.* + local_utc_offset_ms()), "", 30 * 60_000, value);
		}
	}
	spacer(.Y, 20);
}

step_info :: () {
	step_heading("What's your event about?", "Fill out the details of your event.");
	pad_begin("info");
	field_label("Event Topic", true);
	set_input("topic", *evu.name, "What's your event?", max_runes = 100, autofocus = evu.focus_next);
	evu.focus_next = false;
	spacer(.Y, 20);
	date_time_row("start", "Start Date", "Start Time", *evu.start_ms);
	if evu.entity == .External {
		if evu.end_ms <= evu.start_ms evu.end_ms = evu.start_ms + 3_600_000;
		date_time_row("end", "End Date", "End Time", *evu.end_ms);
	}
	if evu.start_ms <= wall_ms() {
		label("The start time must be in the future.", .Normal, 14, T("--text-feedback-critical"), 18);
		spacer(.Y, 12);
	}
	field_label("Description", false);
	set_input("desc", *evu.desc, "Tell people a little more about your event. Markdown, new lines, and links are supported.", multiline = true, max_runes = 1000, min_h = 70);
	pad_end();
}

step_review :: () {
	preview := dc.Scheduled_Event.{
		guild_id = evu.guild,
		channel_id = ifx evu.entity == .Voice then evu.channel else 0,
		creator_id = store().me,
		name = trim(ui.editor_text(*evu.name)),
		description = trim(ui.editor_text(*evu.desc)),
		location = trim(ui.editor_text(*evu.location)),
		start_ms = evu.start_ms,
		end_ms = evu.end_ms,
		status = .Scheduled,
		entity = evu.entity,
		user_count = 0
	};
	cr := row("preview");
	cr.semantic_size = .[ui.pct(1), ui.children()];
	{ ui.parent(cr); defer ui.pop_parent();
		spacer(.X, 16);
		card := ui.box("c", .Draw_Background | .Draw_Border);
		card.semantic_size = .[ui.fill(), ui.children()];
		card.layout_axis = .Y;
		card.style.bg = T("--background-base-lower");
		card.style.border_color = T("--border-subtle");
		card.style.border = 1;
		card.style.radius = all4(8);
		{ ui.parent(card); defer ui.pop_parent(); event_card_body(*preview, false); }
		spacer(.X, 16);
	}
	spacer(.Y, 32);
	center_line("t", "Here's a preview of your event.", .Bold, 24, 30, T("--text-strong"));
	spacer(.Y, 8);
	center_line("s", "This event will auto start when it's time.", .Normal, 16, 20, T("--text-default"));
	spacer(.Y, 16);
}
