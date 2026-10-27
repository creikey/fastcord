package app

import "core:fmt"
import "core:strings"
import "core:time"
import dc "fc:discord"
import "fc:ui"

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
// Requests live in src/discord/guild_admin.odin.

@(private = "file")
Wizard_Step :: enum u8 {
	Location,
	Info,
	Review,
}

@(private = "file")
Events_UI :: struct {
	open:          bool,
	guild:         dc.Snowflake,
	// Create Event wizard
	wiz_open:      bool,
	step:          Wizard_Step,
	entity:        dc.Event_Entity, // .Unknown until a location type is picked
	channel:       dc.Snowflake, // voice
	location:      ui.Editor,
	name:          ui.Editor,
	desc:          ui.Editor,
	start_ms:      i64,
	end_ms:        i64,
	busy:          bool,
	error:         string, // heap
	focus_next:    bool,
	// share dialog
	share_event:   dc.Snowflake,
	share_code:    [32]u8,
	share_len:     int,
	share_loading: bool,
	share_failed:  bool,
	share_copied:  bool,
	share_created: bool, // opened right after Create Event (else from a card's Share)
	// card menu and cancel confirm
	menu_event:    dc.Snowflake,
	menu_pos:      ui.Vec2,
	confirm_event: dc.Snowflake,
	confirm_busy:  bool,
}

@(private = "file")
evu: Events_UI

events_open :: proc(gid: dc.Snowflake) {
	evu.open = true
	evu.guild = gid
	evu.menu_event = 0
	if app.client != nil do dc.open_guild_events(app.client, gid)
}

events_modal_open :: proc() -> bool {return evu.open || evu.wiz_open || evu.share_event != 0 || evu.confirm_event != 0}

events_reset_for_test :: proc() {
	ui.editor_destroy(&evu.location)
	ui.editor_destroy(&evu.name)
	ui.editor_destroy(&evu.desc)
	delete(evu.error)
	evu = {}
	dc.events_destroy() // the sweep reloads fixtures without destroying the Store
}

events_state_for_test :: proc() -> string {
	return fmt.tprint(evu.open, evu.guild, evu.wiz_open, evu.step, evu.entity, evu.channel, evu.share_event, evu.menu_event, evu.confirm_event, dc.events_epoch())
}

// "1 Event" / "3 Events" / "Events": the channel list row.
events_row_label :: proc(gid: dc.Snowflake) -> string {
	n := len(dc.guild_events(gid))
	if n == 0 do return "Events"
	return fmt.tprintf("%d Event%s", n, n == 1 ? "" : "s")
}

@(private = "file")
set_wiz_error :: proc(msg: string) {
	delete(evu.error)
	evu.error = strings.clone(msg)
}

events_receive :: proc(r: ^dc.Feature_Result) {
	if app.client != nil do dc.guild_admin_apply(app.client, r)
	app.ui.animating = true
	#partial switch r.op {
	case .Event_Create:
		if !evu.wiz_open do return
		evu.busy = false
		if !r.ok {
			set_wiz_error(r.status == 0 ? "Couldn't reach Discord. Check your connection and try again." : dc.api_error_message(r.body))
			if evu.error == "" do set_wiz_error(fmt.tprintf("Something went wrong (HTTP %d).", r.status))
			return
		}
		evu.wiz_open = false
		evu.open = true
		// the library already asked for the event's invite (dc.event_share)
		share_open(dc.fsnow(dc.vmap(r.body), "id"), created = true)
	case .Event_Invite:
		if dc.Snowflake(r.tag) != evu.share_event do return
		evu.share_loading = false
		code := r.ok ? dc.fstr(dc.vmap(r.body), "code") : ""
		if code == "" || len(code) > len(evu.share_code) {
			evu.share_failed = true
		} else {
			copy(evu.share_code[:], code)
			evu.share_len = len(code)
		}
	case .Event_Delete:
		if dc.Snowflake(r.tag) == evu.confirm_event {
			evu.confirm_busy = false
			if r.ok do evu.confirm_event = 0
		}
	case .Event_Start:
		e := dc.event_get(dc.Snowflake(r.tag))
		if r.ok && e != nil && e.entity == .Voice && e.channel_id != 0 do join_voice(e.guild_id, e.channel_id)
	}
}

// ---- time ----

@(private = "file")
clock_text :: proc(local_ms: i64) -> string {
	t := time.unix(local_ms / 1000, 0)
	h, mi, _ := time.clock_from_time(t)
	h12 := h % 12
	if h12 == 0 do h12 = 12
	return fmt.tprintf("%d:%02d %s", h12, mi, h >= 12 ? "PM" : "AM")
}

@(private = "file")
MONTHS := [12]string{"Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"}

// "Oct 26, 2026" (local)
@(private = "file")
date_text :: proc(ms: i64) -> string {
	t := time.unix((ms + local_utc_offset_ms()) / 1000, 0)
	y, mo, d := time.date(t)
	return fmt.tprintf("%s %d, %d", MONTHS[int(mo) - 1], d, y)
}

// "Today at 3:00 PM", "Tomorrow at ...", "Mon, Oct 27 at 3:00 PM" in local time.
@(private = "file")
event_when :: proc(ms: i64) -> string {
	off := local_utc_offset_ms()
	local := ms + off
	clock := clock_text(local)
	day := local / 86_400_000
	today := (wall_ms() + off) / 86_400_000
	switch day {
	case today:
		return fmt.tprintf("Today at %s", clock)
	case today + 1:
		return fmt.tprintf("Tomorrow at %s", clock)
	}
	DAYS := [7]string{"Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"}
	t := time.unix(local / 1000, 0)
	_, mo, d := time.date(t)
	return fmt.tprintf("%s, %s %d at %s", DAYS[int(time.weekday(t))], MONTHS[int(mo) - 1], d, clock)
}

// "Starting in 41m" within the hour, else the start time.
@(private = "file")
event_start_text :: proc(ms: i64) -> string {
	diff := ms - wall_ms()
	if diff > 0 && diff < 3_600_000 do return fmt.tprintf("Starting in %dm", max(1, diff / 60_000))
	return event_when(ms)
}

// ---- shared pieces ----

// Scrim + centered dialog (no title row), pushed as parent; false when the scrim was clicked.
@(private = "file")
ev_dialog_begin :: proc(id: string, w: f32, fixed_h: f32 = 0) -> bool {
	scrim := ui.box(fmt.tprintf("%s_scrim", id), {.Draw_Background, .Clickable, .Floating_X, .Floating_Y, .Overlay})
	scrim.semantic_size = {.X = ui.px(app.ui.window.x), .Y = ui.px(app.ui.window.y)}
	scrim.style.bg = {0, 0, 0, 0.7}
	if ui.signal(scrim).clicked do return false
	d := ui.box(id, {.Draw_Background, .Draw_Border, .Floating_X, .Floating_Y, .Overlay, .Clickable, .Clip})
	d.semantic_size = {.X = ui.px(w), .Y = fixed_h > 0 ? ui.px(fixed_h) : ui.children()}
	d.fixed_pos = {(app.ui.window.x - w) / 2, max(16, (app.ui.window.y - (d.rect.y1 - d.rect.y0)) / 2)}
	d.style.bg = T("--modal-background")
	d.style.border_color = T("--border-subtle")
	d.style.border = 1
	d.style.radius = 12
	d.layout_axis = .Y
	ui.signal(d)
	ui.push_parent(d)
	return true
}

@(private = "file")
close_x :: proc(id: string, x, y: f32) -> bool {
	b := ui.box(id, {.Clickable, .Floating_X, .Floating_Y})
	b.semantic_size = {.X = ui.px(24), .Y = ui.px(24)}
	b.fixed_pos = {x, y}
	sig := ui.signal(b)
	set_icon(b, "x-large", sig.hovering ? T("--interactive-icon-hover") : T("--interactive-icon-default"))
	return sig.clicked
}

// Small button with an optional icon (card actions, header Create Event).
@(private = "file")
pill_button :: proc(id, text, icon_name: string, bg, fg: ui.Color, h: f32 = 32) -> bool {
	b := row(id, {.Clickable, .Draw_Background, .Hot_Animation})
	b.semantic_size = {.X = ui.children(), .Y = ui.px(h)}
	b.style.radius = 8
	b.style.bg = bg
	b.style.bg_hot = with_alpha(bg, bg.a * 0.8)
	b.hover_cursor = .Pointer
	sig := ui.signal(b)
	if ui.parent(b) {
		spacer(.X, text == "" ? 8 : 12)
		if icon_name != "" {
			icon("i", icon_name, 16, fg)
			if text != "" do spacer(.X, 6)
		}
		if text != "" do label(text, .Medium, 14, fg, 18)
		spacer(.X, text == "" ? 8 : 12)
	}
	return sig.clicked
}

@(private = "file")
hline :: proc(id: string, pad: f32 = 0) {
	r := row(id)
	r.semantic_size = {.X = ui.pct(1), .Y = ui.px(1)}
	if ui.parent(r) {
		spacer(.X, pad)
		l := ui.box("l", {.Draw_Background})
		l.semantic_size = {.X = ui.fill(), .Y = ui.px(1)}
		l.style.bg = T("--border-subtle")
		spacer(.X, pad)
	}
}

@(private = "file")
place_of :: proc(e: ^dc.Scheduled_Event) -> (text: string, icon_name: string) {
	if e.entity == .Voice || e.entity == .Stage_Instance {
		text = "Unknown channel"
		if ch := dc.channel_get(store(), e.channel_id); ch != nil do text = ch.name
		return text, e.entity == .Voice ? "voice-normal" : "stage"
	}
	return e.location, "location"
}

// ---- Events modal ----

events_modal :: proc() {
	if evu.guild != 0 && (dc.guild_get(store(), evu.guild) == nil || app.view.guild != evu.guild) {
		evu.open, evu.wiz_open = false, false
		evu.share_event, evu.menu_event, evu.confirm_event, evu.guild = 0, 0, 0, 0
		return
	}
	if evu.open && !evu.wiz_open do events_list_modal()
	if evu.wiz_open do wizard_modal()
	if evu.menu_event != 0 do event_menu()
	if evu.confirm_event != 0 do cancel_confirm()
	if evu.share_event != 0 do share_modal()
}

@(private = "file")
events_list_modal :: proc() {
	evs := dc.guild_events(evu.guild)
	W :: 604
	H :: 400
	top := evu.share_event == 0 && evu.confirm_event == 0 && evu.menu_event == 0
	if !ev_dialog_begin("events", W, H) {
		if top do evu.open = false
		return
	}
	defer ui.pop_parent()
	spacer(.Y, 20)
	hdr := row("hdr")
	hdr.semantic_size = {.X = ui.pct(1), .Y = ui.px(32)}
	if ui.parent(hdr) {
		spacer(.X, 24)
		icon("cal", "calendar", 24, T("--interactive-icon-hover"))
		spacer(.X, 8)
		label(events_row_label(evu.guild), .Semibold, 16, T("--text-strong"), 20)
		if dc.can_create_events(store(), evu.guild) {
			spacer(.X, 16)
			d := ui.box("div", {.Draw_Background})
			d.semantic_size = {.X = ui.px(1), .Y = ui.px(24)}
			d.style.bg = T("--border-subtle")
			spacer(.X, 16)
			if pill_button("create", "Create Event", "", T("--background-brand"), {1, 1, 1, 1}) do wizard_open()
		}
	}
	if close_x("close", W - 24 - 20, 20) && top do evu.open = false
	spacer(.Y, 16)
	if len(evs) == 0 {
		events_empty()
	} else {
		list := ui.box("list", {.Scroll_Y, .Clip})
		list.semantic_size = {.X = ui.pct(1), .Y = ui.fill()}
		list.layout_axis = .Y
		ui.signal(list)
		if ui.parent(list) {
			for e in evs {
				if ui.id_scope(u64(e.id)) do event_card(e)
			}
			spacer(.Y, 8)
		}
	}
	if top && adm_escape() do evu.open = false
}

@(private = "file")
center_line :: proc(id, text: string, font: Font_Id, size, lh: f32, color: ui.Color) {
	r := row(id)
	r.semantic_size = {.X = ui.pct(1), .Y = ui.px(lh)}
	if ui.parent(r) {
		filler(.X)
		label(text, font, size, color, lh)
		filler(.X)
	}
}

@(private = "file")
events_empty :: proc() {
	filler(.Y)
	center_line("t", "There are no upcoming events.", .Bold, 24, 30, T("--text-strong"))
	spacer(.Y, 8)
	center_line("s", "Schedule an event for any planned activity in your server.", .Normal, 14, 20, T("--text-default"))
	filler(.Y)
	spacer(.Y, 60)
}

@(private = "file")
event_card :: proc(e: ^dc.Scheduled_Event) {
	outer := row("card")
	outer.semantic_size = {.X = ui.pct(1), .Y = ui.children()}
	if ui.parent(outer) {
		spacer(.X, 24)
		card := ui.box("c", {.Draw_Background, .Draw_Border, .Clickable})
		card.semantic_size = {.X = ui.fill(), .Y = ui.children()}
		card.layout_axis = .Y
		card.style.bg = T("--background-base-lower")
		card.style.border_color = T("--border-subtle")
		card.style.border = 1
		card.style.radius = 8
		csig := ui.signal(card)
		if csig.right_clicked do menu_open(e.id, app.ui.mouse)
		if ui.parent(card) do event_card_body(e, true)
		spacer(.X, 24)
	}
	spacer(.Y, 12)
}

// The card's content (also the Review step's preview, without actions).
@(private = "file")
event_card_body :: proc(e: ^dc.Scheduled_Event, actions: bool) {
	spacer(.Y, 16)
	wr := row("when")
	wr.semantic_size = {.X = ui.pct(1), .Y = ui.px(22)}
	if ui.parent(wr) {
		spacer(.X, 16)
		if e.status == .Active {
			dot := ui.box("live", {.Draw_Background})
			dot.semantic_size = {.X = ui.px(8), .Y = ui.px(8)}
			dot.style.radius = 4
			dot.style.bg = T("--status-positive")
			spacer(.X, 6)
			label("Happening Now", .Semibold, 14, T("--text-feedback-positive"), 18)
		} else {
			icon("cal", "calendar", 18, T("--text-brand"))
			spacer(.X, 8)
			label(event_start_text(e.start_ms), .Semibold, 14, T("--text-brand"), 18)
		}
		filler(.X)
		if e.creator_id != 0 {
			avatar_box("creator", e.creator_id, 20)
			spacer(.X, 8)
		}
		if e.user_count >= 0 {
			pill := row("count", {.Draw_Background})
			pill.semantic_size = {.X = ui.children(), .Y = ui.px(22)}
			pill.style.radius = 11
			pill.style.bg = T("--background-base-lowest")
			if ui.parent(pill) {
				spacer(.X, 8)
				icon("grp", "group", 14, T("--text-strong"))
				spacer(.X, 4)
				label(fmt.tprint(e.user_count), .Semibold, 14, T("--text-strong"), 18)
				spacer(.X, 8)
			}
		}
		spacer(.X, 16)
	}
	spacer(.Y, 8)
	nr := row("name")
	nr.semantic_size = {.X = ui.pct(1), .Y = ui.children()}
	if ui.parent(nr) {
		spacer(.X, 16)
		b := ui.box("n", {.Draw_Text, .Wrap_Text})
		b.semantic_size = {.X = ui.fill(), .Y = ui.text_size()}
		b.text = e.name
		b.style.font = F(.Semibold)
		b.style.font_size = 20
		b.style.line_height = 24
		b.style.text_color = T("--text-strong")
		spacer(.X, 16)
	}
	if e.description != "" {
		spacer(.Y, 4)
		dr := row("desc")
		dr.semantic_size = {.X = ui.pct(1), .Y = ui.children()}
		if ui.parent(dr) {
			spacer(.X, 16)
			b := ui.box("d", {.Draw_Text, .Wrap_Text})
			b.semantic_size = {.X = ui.fill(), .Y = ui.text_size()}
			b.text = e.description
			b.style.font = F(.Normal)
			b.style.font_size = 14
			b.style.line_height = 18
			b.style.text_color = T("--text-default")
			spacer(.X, 16)
		}
	}
	spacer(.Y, 16)
	hline("hl")
	br := row("bottom")
	br.semantic_size = {.X = ui.pct(1), .Y = ui.px(60)}
	if ui.parent(br) {
		spacer(.X, 16)
		place, place_icon := place_of(e)
		icon("pl", place_icon, 20, T("--text-default"))
		spacer(.X, 6)
		label(ellipsize(place, .Medium, 14, 220), .Medium, 14, T("--text-default"), 18)
		filler(.X)
		if actions {
			if pill_button("more", "", "more-horizontal", T("--background-mod-normal"), T("--text-strong")) {
				menu_open(e.id, app.ui.mouse)
			}
			spacer(.X, 8)
			if pill_button("share", "Share", "share", T("--background-mod-normal"), T("--text-strong")) {
				share_open(e.id)
				if net_action() do dc.event_share(app.client, e.id)
			}
			spacer(.X, 8)
			bg := e.interested ? T("--status-positive") : T("--background-mod-normal")
			fg: ui.Color = e.interested ? {1, 1, 1, 1} : T("--text-strong")
			if pill_button("interested", "Interested", e.interested ? "checkmark-small" : "bell", bg, fg) && !e.interest_pending && net_action() {
				dc.set_event_interest(app.client, e.id, !e.interested)
			}
		}
		spacer(.X, 16)
	}
}

// ---- card menu ----

@(private = "file")
menu_open :: proc(id: dc.Snowflake, at: ui.Vec2) {
	evu.menu_event = id
	evu.menu_pos = at
}

@(private = "file")
event_menu :: proc() {
	e := dc.event_get(evu.menu_event)
	if e == nil || outside_pressed("evmenu_out") || escape_pressed() {
		evu.menu_event = 0
		return
	}
	W :: f32(188)
	manage := dc.can_manage_event(store(), e)
	can_start := manage && e.status == .Scheduled && e.entity == .Voice
	n := 1 + int(can_start) + int(manage)
	h := f32(16 + n * GM_ROW_H)
	pos := evu.menu_pos
	pos.x = min(pos.x, app.ui.window.x - W - 8)
	pos.y = min(pos.y, app.ui.window.y - h - 8)
	p := menu_panel("evmenu", pos, W)
	if ui.parent(p) {
		spacer(.Y, 8)
		if can_start {
			if menu_item("start", "Start Event").clicked {
				evu.menu_event = 0
				if net_action() do dc.start_scheduled_event(app.client, e.id)
			}
		}
		if manage {
			if menu_item("cancel", "Cancel Event", danger = true).clicked {
				evu.menu_event = 0
				evu.confirm_event = e.id
				evu.confirm_busy = false
			}
		}
		if menu_item("copylink", "Copy Event Link").clicked {
			clipboard_set(dc.event_link(e))
			evu.menu_event = 0
		}
		spacer(.Y, 8)
	}
}

@(private = "file")
cancel_confirm :: proc() {
	if dc.event_get(evu.confirm_event) == nil {
		evu.confirm_event = 0
		return
	}
	W :: 400
	if !ev_dialog_begin("evcancel", W) {
		evu.confirm_event = 0
		return
	}
	confirm := false
	if body_open := true; body_open { // the dialog is the parent until here
		defer ui.pop_parent()
		if close_x("close", W - 24 - 16, 20) do evu.confirm_event = 0
		spacer(.Y, 24)
		t := row("t")
		t.semantic_size = {.X = ui.pct(1), .Y = ui.px(26)}
		if ui.parent(t) {
			spacer(.X, 24)
			label("Cancel Event?", .Bold, 20, T("--text-strong"), 26)
		}
		spacer(.Y, 8)
		b := row("b")
		b.semantic_size = {.X = ui.pct(1), .Y = ui.px(20)}
		if ui.parent(b) {
			spacer(.X, 24)
			label("Are you sure you want to cancel this event?", .Normal, 16, T("--text-default"), 20)
		}
		spacer(.Y, 24)
		btns := row("btns")
		btns.semantic_size = {.X = ui.pct(1), .Y = ui.px(40)}
		btns.style.child_gap = 8
		if ui.parent(btns) {
			spacer(.X, 24 - 8)
			if wide_button("never", "Never Mind", .Secondary) do evu.confirm_event = 0
			if wide_button("confirm", evu.confirm_busy ? "Cancelling..." : "Cancel Event", .Danger, !evu.confirm_busy) do confirm = true
			spacer(.X, 24 - 8)
		}
		spacer(.Y, 24)
	}
	if adm_escape() do evu.confirm_event = 0
	if confirm && evu.confirm_event != 0 && net_action() {
		evu.confirm_busy = true
		dc.cancel_scheduled_event(app.client, evu.confirm_event)
	}
}

// Equal-width button filling its share of the row.
wide_button :: proc(id, text: string, kind: Adm_Button, enabled := true) -> bool {
	b := ui.box(fmt.tprintf("%s##%s", text, id), {.Clickable, .Draw_Background, .Draw_Text, .Hot_Animation})
	b.semantic_size = {.X = ui.fill(), .Y = ui.px(40)}
	b.style.radius = 8
	b.style.font = F(.Medium)
	b.style.font_size = 16
	b.style.text_align = .Center
	b.hover_cursor = .Pointer
	#partial switch kind {
	case .Primary:
		b.style.bg = T("--background-brand")
		b.style.text_color = {1, 1, 1, 1}
	case .Danger:
		b.style.bg = T("--status-danger")
		b.style.text_color = {1, 1, 1, 1}
	case:
		b.style.bg = T("--background-mod-strong")
		b.style.text_color = T("--text-strong")
	}
	b.style.bg_hot = with_alpha(b.style.bg, 0.85)
	if !enabled {
		b.flags += {.Disabled}
		b.style.bg = with_alpha(b.style.bg, 0.5)
		b.style.bg_hot = b.style.bg
		b.style.text_color = with_alpha(b.style.text_color, 0.5)
	}
	return ui.signal(b).clicked && enabled
}

// ---- share dialog ----

@(private = "file")
share_open :: proc(id: dc.Snowflake, created := false) {
	evu.share_event = id
	evu.share_created = created
	evu.share_len = 0
	evu.share_loading = true
	evu.share_failed = false
	evu.share_copied = false
}

@(private = "file")
share_modal :: proc() {
	W :: 480
	if !ev_dialog_begin("evshare", W) {
		evu.share_event = 0
		return
	}
	if body_open := true; body_open { // the dialog is the parent until here
		defer ui.pop_parent()
		if close_x("close", W - 24 - 16, 16) do evu.share_event = 0
		spacer(.Y, 24)
		ic := row("ic")
		ic.semantic_size = {.X = ui.pct(1), .Y = ui.px(64)}
		if ui.parent(ic) {
			filler(.X)
			c := ui.box("circle", {.Draw_Background})
			c.semantic_size = {.X = ui.px(64), .Y = ui.px(64)}
			c.style.radius = 32
			c.style.bg = T("--background-base-lowest")
			if ui.parent(c) {
				i := icon("i", "calendar", 28, T("--text-strong"))
				i.flags += {.Floating_X, .Floating_Y}
				i.fixed_pos = {18, 18}
			}
			filler(.X)
		}
		spacer(.Y, 24)
		center_line("t", evu.share_created ? "All set. Now share your event!" : "Share Event", .Bold, 24, 30, T("--text-strong"))
		spacer(.Y, 8)
		pr := row("p")
		pr.semantic_size = {.X = ui.pct(1), .Y = ui.children()}
		if ui.parent(pr) {
			spacer(.X, 24)
			b := ui.box("text", {.Draw_Text, .Wrap_Text})
			b.semantic_size = {.X = ui.fill(), .Y = ui.text_size()}
			b.text = "Copy the event link below to invite people to your event. This also acts as a server invite link."
			b.style.font = F(.Normal)
			b.style.font_size = 16
			b.style.line_height = 20
			b.style.text_align = .Center
			b.style.text_color = T("--text-default")
			spacer(.X, 24)
		}
		spacer(.Y, 24)
		lr := row("linkrow")
		lr.semantic_size = {.X = ui.pct(1), .Y = ui.px(40)}
		if ui.parent(lr) {
			spacer(.X, 24)
			box := row("link", {.Draw_Background, .Draw_Border})
			box.semantic_size = {.X = ui.fill(), .Y = ui.px(40)}
			box.style.bg = T("--input-background-default")
			box.style.border = 1
			box.style.border_color = T("--input-border-default")
			box.style.radius = 8
			if ui.parent(box) {
				spacer(.X, 12)
				url := ""
				if evu.share_len > 0 do url = dc.event_invite_link(string(evu.share_code[:evu.share_len]), evu.share_event)
				shown := url
				color := T("--text-strong")
				if evu.share_loading {
					shown, color = "Creating an invite...", T("--text-muted")
				} else if evu.share_failed {
					shown, color = "Couldn't create an invite.", T("--text-feedback-critical")
				}
				label(ellipsize(shown, .Normal, 16, W - 48 - 110), .Normal, 16, color, 20)
				filler(.X)
				kind := evu.share_copied ? Button_Kind.Positive : Button_Kind.Primary
				if set_button(evu.share_copied ? "Copied##copy" : "Copy##copy", kind, url != "", 32) {
					clipboard_set(url)
					evu.share_copied = true
				}
				spacer(.X, 4)
			}
			spacer(.X, 24)
		}
		spacer(.Y, 8)
		er := row("exp")
		er.semantic_size = {.X = ui.pct(1), .Y = ui.px(16)}
		if ui.parent(er) {
			spacer(.X, 24)
			label("Your invite link expires in 7 days.", .Normal, 12, T("--text-default"), 16)
		}
		spacer(.Y, 24)
	}
	if adm_escape() do evu.share_event = 0
}

// ---- Create Event wizard ----

@(private = "file")
wizard_open :: proc() {
	evu.wiz_open = true
	evu.step = .Location
	evu.entity = .Unknown
	evu.channel = 0
	evu.busy = false
	set_wiz_error("")
	ui.editor_set_text(&evu.location, "")
	ui.editor_set_text(&evu.name, "")
	ui.editor_set_text(&evu.desc, "")
	app.ui.focus = 0
	if app.client != nil do dc.open_create_event(app.client, evu.guild)
}

@(private = "file")
voice_channels :: proc(gid: dc.Snowflake) -> []dc.Snowflake {
	out := make([dynamic]dc.Snowflake, context.temp_allocator)
	s := store()
	for id in dc.guild_channels_sorted(s, gid) {
		ch := dc.channel_get(s, id)
		if ch != nil && ch.kind == .Guild_Voice do append(&out, id)
	}
	return out[:]
}

@(private = "file")
step_valid :: proc(step: Wizard_Step) -> bool {
	switch step {
	case .Location:
		if evu.entity == .Voice do return evu.channel != 0
		if evu.entity == .External do return strings.trim_space(ui.editor_text(&evu.location)) != ""
		return false
	case .Info:
		if strings.trim_space(ui.editor_text(&evu.name)) == "" || evu.start_ms <= wall_ms() do return false
		return evu.entity != .External || evu.end_ms > evu.start_ms
	case .Review:
		return true
	}
	return false
}

@(private = "file")
wizard_modal :: proc() {
	W :: 480
	if !ev_dialog_begin("evwizard", W) {
		evu.wiz_open = false
		return
	}
	next, back, cancel := false, false, false
	if body_open := true; body_open { // the dialog is the parent until here
		defer ui.pop_parent()
		spacer(.Y, 16)
		// progress: Location / Event Info / Review
		pr := row("progress")
		pr.semantic_size = {.X = ui.pct(1), .Y = ui.px(28)}
		pr.style.child_gap = 8
		if ui.parent(pr) {
			spacer(.X, 16 - 8)
			NAMES := [3]string{"Location", "Event Info", "Review"}
			for name, i in NAMES {
				cur := int(evu.step) == i
				col := ui.box(name)
				col.semantic_size = {.X = ui.fill(), .Y = ui.px(28)}
				col.layout_axis = .Y
				if ui.parent(col) {
					bar := ui.box("bar", {.Draw_Background})
					bar.semantic_size = {.X = ui.pct(1), .Y = ui.px(4)}
					bar.style.radius = 2
					bar.style.bg = cur ? T("--background-brand") : T("--interactive-text-default")
					if !cur do bar.style.bg = with_alpha(bar.style.bg, 0.6)
					spacer(.Y, 8)
					label(name, .Medium, 12, cur ? T("--text-brand") : T("--text-default"), 16)
				}
			}
			spacer(.X, 16 - 8)
		}
		spacer(.Y, 16)
		body := ui.box("body", {.Scroll_Y, .Clip})
		max_h := max(200, app.ui.window.y - 220)
		body.semantic_size = {.X = ui.pct(1), .Y = ui.px(body.content_size.y > 0 ? min(body.content_size.y, max_h) : 240)}
		body.layout_axis = .Y
		ui.signal(body)
		if ui.parent(body) {
			switch evu.step {
			case .Location:
				step_location()
			case .Info:
				step_info()
			case .Review:
				step_review()
			}
			if evu.error != "" {
				spacer(.Y, 8)
				er := row("err")
				er.semantic_size = {.X = ui.pct(1), .Y = ui.children()}
				if ui.parent(er) {
					spacer(.X, 16)
					b := ui.box("t", {.Draw_Text, .Wrap_Text})
					b.semantic_size = {.X = ui.fill(), .Y = ui.text_size()}
					b.text = evu.error
					b.style.font = F(.Normal)
					b.style.font_size = 14
					b.style.line_height = 18
					b.style.text_color = T("--text-feedback-critical")
					spacer(.X, 16)
				}
			}
		}
		spacer(.Y, 16)
		btns := row("btns")
		btns.semantic_size = {.X = ui.pct(1), .Y = ui.px(40)}
		btns.style.child_gap = 8
		if ui.parent(btns) {
			spacer(.X, 16 - 8)
			if evu.step != .Location && set_button("Back##back", .Link, !evu.busy, 40) do back = true
			filler(.X)
			if set_button("Cancel##cancel", .Secondary, true, 40) do cancel = true
			if evu.step == .Review {
				if set_button(evu.busy ? "Creating...##next" : "Create Event##next", .Primary, !evu.busy, 40) do next = true
			} else {
				if set_button("Next##next", .Primary, step_valid(evu.step), 40) do next = true
			}
			spacer(.X, 16 - 8)
		}
		spacer(.Y, 16)
	}
	if adm_escape() do cancel = true
	switch {
	case cancel:
		evu.wiz_open = false
		app.ui.focus = 0
	case back:
		evu.step = Wizard_Step(int(evu.step) - 1)
		set_wiz_error("")
	case next && step_valid(evu.step):
		set_wiz_error("")
		switch evu.step {
		case .Location:
			evu.step = .Info
			// defaults: the next full hour; external events end an hour later
			evu.start_ms = dc.default_event_start_ms(wall_ms(), local_utc_offset_ms())
			evu.end_ms = evu.start_ms + 3_600_000
			evu.focus_next = true
			app.ui.focus = 0 // the topic field takes it
		case .Info:
			evu.step = .Review
			app.ui.focus = 0
			if app.client != nil do dc.event_preview_counts(app.client, evu.guild)
		case .Review:
			if !evu.busy && net_action() {
				evu.busy = true
				dc.create_scheduled_event(app.client, evu.guild, draft())
			}
		}
	}
}

@(private = "file")
draft :: proc() -> dc.Event_Draft {
	return {
		name = strings.trim_space(ui.editor_text(&evu.name)),
		description = strings.trim_space(ui.editor_text(&evu.desc)),
		start_ms = evu.start_ms,
		end_ms = evu.end_ms,
		entity = evu.entity,
		channel_id = evu.channel,
		location = strings.trim_space(ui.editor_text(&evu.location)),
	}
}

@(private = "file")
step_heading :: proc(title, sub: string) {
	t := row("h")
	t.semantic_size = {.X = ui.pct(1), .Y = ui.px(30)}
	if ui.parent(t) {
		spacer(.X, 16)
		label(title, .Bold, 24, T("--text-strong"), 30)
	}
	spacer(.Y, 4)
	s := row("sub")
	s.semantic_size = {.X = ui.pct(1), .Y = ui.px(18)}
	if ui.parent(s) {
		spacer(.X, 16)
		label(sub, .Normal, 14, T("--text-default"), 18)
	}
	spacer(.Y, 20)
}

// Radio row: circle, icon + title, description below.
@(private = "file")
radio_row :: proc(id, icon_name, title, desc: string, on: bool) -> bool {
	r := row(id, {.Clickable})
	r.semantic_size = {.X = ui.pct(1), .Y = ui.px(58)}
	r.cross_align = .Start
	r.hover_cursor = .Pointer
	sig := ui.signal(r)
	if ui.parent(r) {
		spacer(.X, 16)
		rb := ui.box("radio", {.Draw_Border})
		rb.semantic_size = {.X = ui.px(20), .Y = ui.px(20)}
		rb.style.radius = 10
		rb.style.border = 2
		rb.style.border_color = on ? T("--background-brand") : T("--interactive-icon-default")
		if on do if ui.parent(rb) {
			dot := ui.box("dot", {.Draw_Background, .Floating_X, .Floating_Y})
			dot.semantic_size = {.X = ui.px(10), .Y = ui.px(10)}
			dot.fixed_pos = {5, 5}
			dot.style.radius = 5
			dot.style.bg = T("--background-brand")
		}
		spacer(.X, 12)
		col := ui.box("col")
		col.semantic_size = {.X = ui.fill(), .Y = ui.children()}
		col.layout_axis = .Y
		if ui.parent(col) {
			tr := row("t")
			tr.semantic_size = {.X = ui.pct(1), .Y = ui.px(20)}
			if ui.parent(tr) {
				icon("i", icon_name, 20, T("--text-strong"))
				spacer(.X, 6)
				label(title, .Medium, 16, T("--text-strong"), 20)
			}
			spacer(.Y, 4)
			label(desc, .Normal, 14, T("--text-default"), 18)
		}
	}
	return sig.clicked
}

@(private = "file")
field_label :: proc(text: string, required: bool) {
	r := row(fmt.tprintf("lbl_%s", text))
	r.semantic_size = {.X = ui.pct(1), .Y = ui.px(20)}
	if ui.parent(r) {
		label(text, .Semibold, 16, T("--text-strong"), 20)
		if required {
			spacer(.X, 4)
			label("*", .Semibold, 16, T("--text-feedback-critical"), 20)
		}
	}
	spacer(.Y, 8)
}

// Column with 16px side padding (wizard fields).
@(private = "file")
pad_begin :: proc(id: string) -> ^ui.Box {
	r := row(id)
	r.semantic_size = {.X = ui.pct(1), .Y = ui.children()}
	ui.push_parent(r)
	spacer(.X, 16)
	c := ui.box("c")
	c.semantic_size = {.X = ui.fill(), .Y = ui.children()}
	c.layout_axis = .Y
	ui.push_parent(c)
	return c
}

@(private = "file")
pad_end :: proc() {
	ui.pop_parent()
	spacer(.X, 16)
	ui.pop_parent()
}

@(private = "file")
step_location :: proc() {
	step_heading("Where is your event?", "So no one gets lost on where to go.")
	if radio_row("voice", "voice-normal", "Voice Channel", "Hang out with voice, video, screenshare, and Go Live.", evu.entity == .Voice) && evu.entity != .Voice {
		evu.entity = .Voice
		vcs := voice_channels(evu.guild)
		if evu.channel == 0 && len(vcs) > 0 do evu.channel = vcs[0]
	}
	if radio_row("external", "location", "Somewhere Else", "Text channel, external link, or in-person location.", evu.entity == .External) && evu.entity != .External {
		evu.entity = .External
		evu.focus_next = true
	}
	#partial switch evu.entity {
	case .Voice:
		spacer(.Y, 8)
		pad_begin("chans")
		field_label("Select a channel", true)
		vcs := voice_channels(evu.guild)
		if len(vcs) == 0 do label("This server has no voice channels.", .Normal, 14, T("--text-muted"), 18)
		for id in vcs {
			ch := dc.channel_get(store(), id)
			if ui.id_scope(u64(id)) {
				sel := evu.channel == id
				it := row("ch", {.Clickable, .Draw_Background, .Draw_Border, .Hot_Animation})
				it.semantic_size = {.X = ui.pct(1), .Y = ui.px(40)}
				it.style.radius = 8
				it.style.bg = sel ? T("--background-mod-strong") : T("--input-background-default")
				it.style.bg_hot = sel ? it.style.bg : T("--background-mod-normal")
				it.style.border = 1
				it.style.border_color = sel ? T("--input-border-active") : T("--input-border-default")
				if ui.signal(it).clicked do evu.channel = id
				if ui.parent(it) {
					spacer(.X, 12)
					icon("i", "voice-normal", 18, T("--text-strong"))
					spacer(.X, 8)
					label(ch.name, .Medium, 16, T("--text-strong"), 20)
				}
				spacer(.Y, 6)
			}
		}
		pad_end()
	case .External:
		spacer(.Y, 8)
		pad_begin("loc")
		field_label("Enter a location", true)
		set_input("locin", &evu.location, "Add a location, link, or something.", max_runes = 100, autofocus = evu.focus_next)
		evu.focus_next = false
		pad_end()
	}
}

// A date or time value with earlier / later steps.
@(private = "file")
stepper :: proc(id, text, icon_name: string, step_ms: i64, value: ^i64) {
	box := row(id, {.Draw_Background, .Draw_Border})
	box.semantic_size = {.X = ui.fill(), .Y = ui.px(40)}
	box.style.bg = T("--input-background-default")
	box.style.border = 1
	box.style.border_color = T("--input-border-default")
	box.style.radius = 8
	if ui.parent(box) {
		spacer(.X, 12)
		label(text, .Normal, 16, T("--text-strong"), 20)
		filler(.X)
		if icon_name != "" {
			icon("ic", icon_name, 18, T("--interactive-icon-default"))
			spacer(.X, 8)
		}
		step :: proc(id, icon_name: string) -> bool {
			b := ui.box(id, {.Clickable, .Draw_Background, .Hot_Animation})
			b.semantic_size = {.X = ui.px(24), .Y = ui.px(24)}
			b.style.radius = 4
			b.style.bg_hot = T("--background-mod-normal")
			sig := ui.signal(b)
			set_icon(b, icon_name, sig.hovering ? T("--interactive-icon-hover") : T("--interactive-icon-default"))
			return sig.clicked
		}
		if step("earlier", "chevron-small-left") do value^ -= step_ms
		if step("later", "chevron-small-right") do value^ += step_ms
		spacer(.X, 8)
	}
}

@(private = "file")
date_time_row :: proc(id, date_label, time_label: string, value: ^i64) {
	r := row(id)
	r.semantic_size = {.X = ui.pct(1), .Y = ui.children()}
	r.style.child_gap = 16
	if ui.parent(r) {
		dc_ := ui.box("date")
		dc_.semantic_size = {.X = ui.fill(), .Y = ui.children()}
		dc_.layout_axis = .Y
		if ui.parent(dc_) {
			field_label(date_label, true)
			stepper("d", date_text(value^), "calendar", 86_400_000, value)
		}
		tc := ui.box("time")
		tc.semantic_size = {.X = ui.fill(), .Y = ui.children()}
		tc.layout_axis = .Y
		if ui.parent(tc) {
			field_label(time_label, true)
			stepper("t", clock_text(value^ + local_utc_offset_ms()), "", 30 * 60_000, value)
		}
	}
	spacer(.Y, 20)
}

@(private = "file")
step_info :: proc() {
	step_heading("What's your event about?", "Fill out the details of your event.")
	pad_begin("info")
	field_label("Event Topic", true)
	set_input("topic", &evu.name, "What's your event?", max_runes = 100, autofocus = evu.focus_next)
	evu.focus_next = false
	spacer(.Y, 20)
	date_time_row("start", "Start Date", "Start Time", &evu.start_ms)
	if evu.entity == .External {
		if evu.end_ms <= evu.start_ms do evu.end_ms = evu.start_ms + 3_600_000
		date_time_row("end", "End Date", "End Time", &evu.end_ms)
	}
	if evu.start_ms <= wall_ms() {
		label("The start time must be in the future.", .Normal, 14, T("--text-feedback-critical"), 18)
		spacer(.Y, 12)
	}
	field_label("Description", false)
	set_input("desc", &evu.desc, "Tell people a little more about your event. Markdown, new lines, and links are supported.", multiline = true, max_runes = 1000, min_h = 70)
	pad_end()
}

@(private = "file")
step_review :: proc() {
	preview := dc.Scheduled_Event {
		guild_id    = evu.guild,
		channel_id  = evu.entity == .Voice ? evu.channel : 0,
		creator_id  = store().me,
		name        = strings.trim_space(ui.editor_text(&evu.name)),
		description = strings.trim_space(ui.editor_text(&evu.desc)),
		location    = strings.trim_space(ui.editor_text(&evu.location)),
		start_ms    = evu.start_ms,
		end_ms      = evu.end_ms,
		status      = .Scheduled,
		entity      = evu.entity,
		user_count  = 0,
	}
	cr := row("preview")
	cr.semantic_size = {.X = ui.pct(1), .Y = ui.children()}
	if ui.parent(cr) {
		spacer(.X, 16)
		card := ui.box("c", {.Draw_Background, .Draw_Border})
		card.semantic_size = {.X = ui.fill(), .Y = ui.children()}
		card.layout_axis = .Y
		card.style.bg = T("--background-base-lower")
		card.style.border_color = T("--border-subtle")
		card.style.border = 1
		card.style.radius = 8
		if ui.parent(card) do event_card_body(&preview, false)
		spacer(.X, 16)
	}
	spacer(.Y, 32)
	center_line("t", "Here's a preview of your event.", .Bold, 24, 30, T("--text-strong"))
	spacer(.Y, 8)
	center_line("s", "This event will auto start when it's time.", .Normal, 16, 20, T("--text-default"))
	spacer(.Y, 16)
}
