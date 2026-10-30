clipboard_get :: () -> string {return platform.clipboard_get();}
clipboard_set :: (s: string) {platform.clipboard_set(s);}

Field_Draw :: struct {
	ed: *ui.Editor;
	blink_t: float64;
}

// Selection highlight and caret for a focused text field. Drawn before the text.
field_draw :: (b: *ui.Box, user: *void) {
	d := cast(*Field_Draw)(user);
	ed := d.ed;
	tl := b.text_layout;
	if tl == null { return; }
	text := ui.editor_text(ed);
	if tl.origin == .{} { tl.origin = .{b.rect.x0 + b.style.padding.x, b.rect.y0 + b.style.padding.y}; }
	origin := ui.Vec2.{b.rect.x0 + b.style.padding.x, b.rect.y0 + b.style.padding.y};
	if text != "" && ui.editor_has_sel(ed) {
		a, z := ui.editor_sel(ed);
		c := cast(gfx.Color)(app.ui.selection_color);
		for l, li: tl.lines {
			s0 := max(a, l.start);
			s1 := min(z, l.end);
			if s0 > s1 || (s0 == s1 && z <= l.end) { continue; }
			x0 := ui.caret_x_in_line(tl, li, s0);
			x1 := ui.caret_x_in_line(tl, li, s1);
			if z > l.end { x1 += 4; }
			gfx.rect(.{origin.x + x0, origin.y + l.y, origin.x + x1, origin.y + l.y + tl.line_h}, c);
		}
	}
	// caret blinks: solid for 0.5 s after any change, then 1 Hz
	pos := ifx text == "" then 0 else ed.caret;
	x := ifx text == "" then 0 else ui.caret_x(tl, pos);
	li := ifx text == "" then 0 else ui.line_of(tl, pos);
	y := origin.y + cast(float32)(li) * tl.line_h;
	// solid for 0.5 s after typing, then toggles every 0.5 s; only wake at toggles
	phase := app.ui.time - app.caret_reset_t;
	request_wake(app.caret_reset_t + (cast(float64)(cast(int)(phase * 2)) + 1) * 0.5);
	if app.sweep || phase < 0.5 || cast(int)(phase * 2) % 2 == 0 {
		gfx.rect(.{origin.x + x, y + 2, origin.x + x + 1.5, y + tl.line_h - 2}, cast(gfx.Color)(T("--text-default")));
	}
	platform.set_ime_rect(origin.x + x, y, 1, tl.line_h);
}

// Right-click menu of a text field: Cut / Copy with a selection, Paste. Items send the
// shortcut, so the focused field (and the composer's file paste) handles them as keys.
edit_menu_state: struct { open: bool; has_sel: bool; pos: ui.Vec2; };

open_edit_menu :: (ed: *ui.Editor, f: *ui.Box) {
	if f.parent app.ui.focus = f.parent.key;
	edit_menu_state.open = true;
	edit_menu_state.has_sel = ui.editor_has_sel(ed);
	edit_menu_state.pos = app.ui.mouse;
}

edit_menu :: () {
	em := *edit_menu_state;
	if outside_pressed("edit_scrim") || escape_pressed() {
		em.open = false;
		return;
	}
	W :: 188.0;
	menu := menu_panel("editmenu", em.pos, W);
	h := menu.rect.y1 - menu.rect.y0;
	menu.fixed_pos = .{clamp(em.pos.x, 8, app.ui.window.x - W - 8), clamp(em.pos.y, 8, max(8.0, app.ui.window.y - h - 8))};
	key: platform.Key;
	{ ui.parent(menu); defer ui.pop_parent();
		spacer(.Y, 8);
		if em.has_sel && menu_item("cut", L("Cut")).clicked key = .X;
		if em.has_sel && menu_item("copy", L("Copy")).clicked key = .C;
		if menu_item("paste", L("Paste")).clicked key = .V;
		spacer(.Y, 8);
	}
	if key != .None {
		platform.inject_event(.{kind = .Key_Down, key = key, mods = platform.PRIMARY_MOD});
		em.open = false;
	}
}

// Where a profile popout was opened from (telemetry: user_profile_action's
// layout and location stack; .Other sends none, its stack names are not known).
Profile_Source :: enum u8 {
	Other;
	Message_Author; // a message's username (source_message_id)
	Account_Panel; // our own panel at the bottom left (ACCOUNT_POPOUT)
}

open_profile :: (uid: dc.Snowflake, anchor: ui.Rect, source := Profile_Source.Other, message_id: dc.Snowflake = 0, webhook_name := "") {
	app.profile_user = uid;
	app.profile_anchor = anchor;
	app.profile_above = false;
	app.profile_open_t = 0;
	sm = .{};
	accts.menu_open = false;
	free(app.profile_webhook);
	app.profile_webhook = copy_string(webhook_name);
	if app.client == null || webhook_name { return; }
	if source == {
	case .Message_Author;
		dc.profile_view_begin(app.client, .Popout, uid, app.view.guild, app.view.channel, message_id);
	case .Account_Panel;
		dc.open_account_popout(app.client, account_tokens()); // its own profile fetch and follow-ups (fixture status_change)
		return;
	case .Other;
	}
	dc.fetch_profile(app.client, uid, app.view.guild);
}

// ---- rich presence ----

// activity_asset_url: an activity's image key as a URL: an app asset id (app-assets), "mp:<path>" (an outside
// image through the media proxy) or "spotify:<id>" (album art); "" for anything else.
activity_asset_url :: (app_id: dc.Snowflake, key: string, size: int) -> string {
	safe :: (s: string, slash: bool) -> bool {
		if !s return false;
		for cast([]u8) s if !(is_alnum(it) || it == #char "_" || it == #char "-" || it == #char "." || (slash && it == #char "/")) return false;
		return true;
	}
	if begins_with(key, "mp:") && safe(slice(key, 3, key.count - 3), true) && !contains(key, "..") return tprint("%/%", dc.MEDIA_PROXY, slice(key, 3, key.count - 3));
	if begins_with(key, "spotify:") && safe(slice(key, 8, key.count - 8), false) return tprint("https://i.scdn.co/image/%", slice(key, 8, key.count - 8));
	_, ok := dc.parse_u64(key);
	if ok && app_id return tprint("%/app-assets/%/%.png?size=%", dc.CDN, app_id, key, size);
	return "";
}

// "1:05" / "1:02:05" for a duration.
clock_span :: (ms: s64) -> string {
	t := max(ms, 0) / 1000;
	if t >= 3600 return tprint("%:%:%", t / 3600, formatInt((t / 60) % 60, minimum_digits = 2), formatInt(t % 60, minimum_digits = 2));
	return tprint("%:%", t / 60, formatInt(t % 60, minimum_digits = 2));
}

// The profile's rich presence card (popout and full profile): what the user is playing, listening to or
// watching, with its art, details, state, party and time; Spotify's with a progress bar, its song opening
// in Spotify. pad: the card's side margin.
activity_card :: (a: *dc.Activity, pad: float32) {
	spotify := a.kind == 2 && a.name == "Spotify";
	HEADS :: string.["Playing", "Live on", "Listening to", "Watching", "", "Competing in"];
	head := ifx a.kind == 1 || a.kind == 2 then tprint("% %", HEADS[a.kind], a.name) else HEADS[a.kind];
	now := wall_ms();
	if a.start_ms || a.end_ms request_wake(platform.time_now() + 1); // the time moves each second
	outer := row("activity");
	outer.semantic_size = .[ui.pct(1), ui.children()];
	ui.parent(outer); defer ui.pop_parent();
	spacer(.X, pad);
	card := ui.box("card", .Draw_Background);
	card.semantic_size = .[ui.fill(), ui.children()];
	card.layout_axis = .X;
	card.style.bg = T("--background-mod-subtle");
	card.style.radius = all4(8);
	{ ui.parent(card); defer ui.pop_parent();
		spacer(.X, 12);
		inner := ui.box("inner");
		inner.semantic_size = .[ui.fill(), ui.children()];
		inner.layout_axis = .Y;
		spacer(.X, 12);
		ui.parent(inner); defer ui.pop_parent();
		spacer(.Y, 10);
		defer spacer(.Y, 12);
		label(head, .Semibold, 12, T("--text-muted"), 16);
		spacer(.Y, 8);
		body := row("body");
		body.semantic_size = .[ui.pct(1), ui.children()];
		body.cross_align = .Center;
		{ ui.parent(body); defer ui.pop_parent();
			art := ui.box("art", .Draw_Background);
			art.semantic_size = .[ui.px(64), ui.px(64)];
			art.style.radius = all4(8);
			art.style.bg = T("--background-mod-normal");
			set_remote_image(art, activity_asset_url(a.app_id, a.large_image, 128));
			if a.large_text && ui.mouse_over(art) tooltip_below(a.large_text, art.rect);
			small := activity_asset_url(a.app_id, a.small_image, 64);
			if small { ui.parent(art); defer ui.pop_parent();
				sm := ui.box("small", .Floating_X | .Floating_Y | .Draw_Background);
				sm.semantic_size = .[ui.px(22), ui.px(22)];
				sm.fixed_pos = .{48, 48};
				sm.style.radius = all4(11);
				sm.style.bg = card.style.bg;
				set_remote_image(sm, small);
				if a.small_text && ui.mouse_over(sm) tooltip_below(a.small_text, sm.rect);
			}
			spacer(.X, 12);
			col := ui.box("col");
			col.semantic_size = .[ui.fill(), ui.children()];
			col.layout_axis = .Y;
			ui.parent(col); defer ui.pop_parent();
			line :: (id: string, text: string, font: Font_Id, color: ui.Color) -> *ui.Box {
				l := label(tprint("%##%", text, id), font, 14, color, 18);
				l.semantic_size[ui.Axis.X] = ui.pct(1);
				l.flags |= .Selectable_Text;
				return l;
			}
			party := ifx a.party[1] > 0 then tprint(" (% of %)", a.party[0], a.party[1]) else "";
			if spotify {
				song := line("song", a.details, .Semibold, T("--text-strong"));
				if a.sync_id && dc.is_hash(a.sync_id) {
					song.flags |= .Clickable;
					song.hover_cursor = .Pointer;
					if ui.signal(song).clicked open_url(tprint("https://open.spotify.com/track/%", a.sync_id));
				}
				if a.state line("artist", tprint(L("by %"), a.state), .Normal, T("--text-default"));
				if a.large_text line("album", tprint(L("on %"), a.large_text), .Normal, T("--text-default"));
			} else {
				line("name", a.name, .Semibold, T("--text-strong"));
				if a.details line("details", a.details, .Normal, T("--text-default"));
				if a.state || party line("state", tprint("%1%2", a.state, party), .Normal, T("--text-default"));
				if a.end_ms > now line("time", tprint("% left", clock_span(a.end_ms - now)), .Normal, T("--text-default"));
				else if a.start_ms && a.start_ms <= now line("time", tprint("% elapsed", clock_span(now - a.start_ms)), .Normal, T("--text-default"));
			}
		}
		if spotify && a.start_ms && a.end_ms > a.start_ms {
			// the song's progress, with the time played and its length
			spacer(.Y, 10);
			total := a.end_ms - a.start_ms;
			done := clamp(now - a.start_ms, 0, total);
			bar := ui.box("bar", .Draw_Background);
			bar.semantic_size = .[ui.pct(1), ui.px(4)];
			bar.style.radius = all4(2);
			bar.style.bg = T("--background-mod-strong");
			{ ui.parent(bar); defer ui.pop_parent();
				fill := ui.box("fill", .Draw_Background);
				fill.semantic_size = .[ui.pct(cast(float32) done / cast(float32) total), ui.px(4)];
				fill.style.radius = all4(2);
				fill.style.bg = T("--text-strong");
			}
			spacer(.Y, 4);
			times := row("times");
			times.semantic_size = .[ui.pct(1), ui.px(16)];
			ui.parent(times); defer ui.pop_parent();
			label(clock_span(done), .Normal, 12, T("--text-muted"), 16);
			filler(.X);
			label(clock_span(total), .Normal, 12, T("--text-muted"), 16);
		}
	}
	spacer(.X, pad);
}

// The user's rich presence activity while they're online, else null.
rich_activity :: (uid: dc.Snowflake) -> *dc.Activity {
	p := table_find_pointer(*store().presences, uid);
	return ifx p && p.rich.kind >= 0 && p.status != .Offline then *p.rich else null;
}

// user_banner_url: in a server, the member's per-server banner replaces theirs ("" for none).
user_banner_url :: (uid: dc.Snowflake, guild: dc.Snowflake, hash_: string) -> string {
	mem := ifx guild then dc.member_get(store(), guild, uid) else null;
	if mem && mem.banner && dc.is_hash(mem.banner) return dc.guild_member_banner_url(guild, uid, mem.banner);
	return ifx hash_ && dc.is_hash(hash_) then dc.banner_url(uid, hash_, 600) else "";
}

// Profile popout: banner, avatar with status, names, and a message box like the official one.
profile_popout :: () {
	s := store();
	uid := app.profile_user;
	u := dc.user_get(s, uid);
	if u == null {
		app.profile_user = 0;
		return;
	}
	hook := app.profile_webhook != "";
	W :: 300;
	scrim := ui.box("profile_scrim", .Clickable | .Floating_X | .Floating_Y | .Overlay);
	scrim.semantic_size = .[ui.px(app.ui.window.x), ui.px(app.ui.window.y)];
	if ui.signal(scrim).clicked {
		app.profile_user = 0;
		return;
	}
	ui.animate(*app.profile_open_t, 1, 25);
	p := ui.box("profile", .Draw_Background | .Draw_Border | .Draw_Shadow | .Floating_X | .Floating_Y | .Overlay | .Clickable);
	// clamp with the card's real height (last frame's layout; 420 before the first)
	h := p.rect.y1 - p.rect.y0;
	if h <= 0 { h = 420; }
	a := app.profile_anchor;
	x := a.x1 + 8;
	if x + W > app.ui.window.x - 8 { x = a.x0 - W - 8; }
	y := a.y0;
	if app.profile_above {
		// the client's account popout: above the user panel, aligned with its left edge
		x = a.x0;
		y = a.y0 - 8 - h;
	}
	x = clamp(x, 8, app.ui.window.x - W - 8);
	y = clamp(y, 8, max(8.0, app.ui.window.y - h - 8));
	p.semantic_size = .[ui.px(W), ui.children()];
	p.fixed_pos = .{x, y + (1 - app.profile_open_t) * 8};
	p.opacity = app.profile_open_t;
	p.layout_axis = .Y;
	p.style.bg = T("--background-surface-high");
	p.style.border_color = T("--border-subtle");
	p.style.border = 1;
	p.style.radius = all4(8);
	p.style.shadow_color = .{0, 0, 0, 0.35};
	p.style.shadow_blur = 16;
	p.style.shadow_offset = .{0, 8};
	ui.signal(p); // swallow clicks inside
	{ ui.parent(p); defer ui.pop_parent();
		banner := ui.box("banner", .Draw_Background);
		banner.semantic_size = .[ui.pct(1), ui.px(105)];
		banner.style.radius = .[8, 8, 0, 0];
		banner.style.bg = profile_banner_color(uid);
		set_remote_image(banner, user_banner_url(uid, app.view.guild, u.banner));
		if !hook { ui.parent(banner); defer ui.pop_parent();
			// "..." on the banner's top-right (official: 28px dark circle, 12px in)
			more := ui.box("more", .Clickable | .Draw_Background | .Floating_X | .Floating_Y);
			more.semantic_size = .[ui.px(28), ui.px(28)];
			more.fixed_pos = .{W - 12 - 28, 12};
			more.style.radius = all4(14);
			more.style.bg = .{0, 0, 0, 0.5};
			if ui.signal(more).clicked {
				open_user_menu(uid, .{more.rect.x0, more.rect.y1 + 4});
				sm.open = false;
			}
			{ ui.parent(more); defer ui.pop_parent();
				ic := icon("i", "more-horizontal", 16, .{1, 1, 1, 1});
				ic.flags |= .Floating_X | .Floating_Y;
				ic.fixed_pos = .{6, 6};
			}
		}
		av_row := ui.box("avrow");
		av_row.semantic_size = .[ui.pct(1), ui.px(44)];
		{ ui.parent(av_row); defer ui.pop_parent();
			ring := ui.box("ring", .Draw_Background | .Floating_X | .Floating_Y);
			ring.semantic_size = .[ui.px(92), ui.px(92)];
			ring.fixed_pos = .{10, -50};
			ring.style.radius = all4(46);
			ring.style.bg = p.style.bg;
			{ ui.parent(ring); defer ui.pop_parent();
				av := ifx hook then avatar_box("av", uid, 80) else avatar_with_status("av", uid, 80, p.style.bg, animate = true);
				av.flags |= .Floating_X | .Floating_Y;
				av.fixed_pos = .{6, 6};
				if !hook profile_full_avatar_hook(av, uid); // click: full profile modal
			}
		}
		info := ui.box("info");
		info.semantic_size = .[ui.pct(1), ui.children()];
		info.layout_axis = .Y;
		{ ui.parent(info); defer ui.pop_parent();
			pad := row("namepad");
			pad.semantic_size = .[ui.pct(1), ui.px(26)];
			{ ui.parent(pad); defer ui.pop_parent();
				spacer(.X, 16);
				n := label(ifx hook then app.profile_webhook else dc.user_name(s, uid, app.view.guild), .Bold, 20, T("--text-strong"), 24);
				n.flags |= .Selectable_Text;
				n.sel_order = 1;
				if hook app_tag();
				else server_tag(u);
			}
			if !hook {
				pad2 := row("userpad");
				pad2.semantic_size = .[ui.pct(1), ui.px(20)];
				ui.parent(pad2); defer ui.pop_parent();
				spacer(.X, 16);
				un := label(u.username, .Normal, 14, T("--text-default"), 18);
				un.flags |= .Selectable_Text;
				un.sel_order = 2;
				mem := dc.member_get(s, app.view.guild, uid);
				pron := ifx mem && mem.pronouns then mem.pronouns else u.pronouns; // the server's profile first
				if pron != "" {
					label(tprint(" • %", pron), .Normal, 14, T("--text-default"), 18);
				}
			}
			if !hook && u.badge_icons {
				// the profile's badges under the names, each with its description on hover
				spacer(.Y, 8);
				br := row("badgepad");
				br.semantic_size = .[ui.pct(1), ui.px(22)];
				ui.parent(br); defer ui.pop_parent();
				spacer(.X, 14);
				for line, i: split(u.badge_icons, "\n",, temp) {
					tab := find_index_from_left(line, #char "\t");
					if tab < 0 continue;
					b := ui.box(tprint("badge%", i));
					b.semantic_size = .[ui.px(22), ui.px(22)];
					set_remote_image(b, tprint("%/badge-icons/%.png", dc.CDN, slice(line, 0, tab)));
					if ui.mouse_over(b) tooltip_below(slice(line, tab + 1, line.count - tab - 1), b.rect);
					spacer(.X, 2);
				}
			}
			custom := ifx hook then "" else user_custom_status(uid);
			if custom {
				spacer(.Y, 8);
				cr := row("custompad");
				cr.semantic_size = .[ui.pct(1), ui.children()];
				ui.parent(cr); defer ui.pop_parent();
				spacer(.X, 16);
				cl := label(custom, .Normal, 14, T("--text-default"), 18);
				cl.flags |= .Wrap_Text | .Selectable_Text;
				cl.semantic_size[ui.Axis.X] = ui.fill();
				cl.sel_order = 3;
				spacer(.X, 16);
			}
			act := ifx hook then null else rich_activity(uid);
			if act {
				spacer(.Y, 12);
				activity_card(act, 16);
			}
			gm := dc.member_get(s, app.view.guild, uid);
			about := ifx gm && gm.bio then gm.bio else u.bio; // the server's profile first
			if about != "" && !hook {
				spacer(.Y, 12);
				bio := ui.box("bio", .Selectable_Text | .Wrap_Text);
				bio.semantic_size = .[ui.pct(1), ui.text_size()];
				bio.style.padding = .{16, 0};
				bio.style.line_height = 18;
				bio.style.text_color = T("--text-default");
				bio.sel_order = 3;
				blocks := md_parse(about);
				if blocks.count > 0 { ui.set_spans(bio, tokens_to_spans(blocks[0].tokens, .Normal, 14, null)); }
			}
			spacer(.Y, 16);
			if uid == s.me {
				account_actions();
				if app.client == app.discord account_switch_group(); // accounts.jai: Discord accounts only
			}
			if uid != s.me && !hook {
				mr := row("msgrow");
				mr.semantic_size = .[ui.pct(1), ui.px(40)];
				{ ui.parent(mr); defer ui.pop_parent();
					spacer(.X, 16);
					mb := row(tprint(L("Message @%##msgbtn"), dc.user_name(s, uid)), .Clickable | .Draw_Background | .Draw_Border | .Draw_Text);
					mb.semantic_size = .[ui.fill(), ui.px(40)];
					mb.style.bg = T("--input-background-default");
					mb.style.border_color = T("--border-subtle");
					mb.style.border = 1;
					mb.style.radius = all4(8);
					mb.style.padding = .{12, 0};
					mb.style.font = F(.Normal);
					mb.style.font_size = 14;
					mb.style.text_color = T("--text-muted");
					mb.hover_cursor = .IBeam;
					if ui.signal(mb).clicked {
						open_dm_with(uid, "Profile");
						app.profile_user = 0;
					}
					spacer(.X, 16);
				}
				spacer(.Y, 16);
			}
		}
	}
	if uid == s.me && sm.open { status_menu(p); }
	if uid == s.me && accts.menu_open accounts_menu(p);
	if user_menu_open() return; // its own Escape and outside press close only the menu
	for * e: app.ui.events {
		if e.kind == .Key_Down && e.key == .Escape { app.profile_user = 0; e.consumed = true; }
	}
}

// ---- account popout (own card): Edit Profile and the status menu ----

// Status menu state: open while the status row was hovered last; sub is the
// status whose duration submenu is open (.Offline = none).
sm: struct {
	open: bool;
	row_y: float32;
	sub: dc.Status;
	sub_y: float32;
};

STATUS_DURATIONS :: struct { text: string; ms: s64; }.[
	.{"For 15 Minutes", 15 * 60_000}, // i18n
	.{"For 1 Hour", 3_600_000}, // i18n
	.{"For 8 Hours", 8 * 3_600_000}, // i18n
	.{"For 24 Hours", 24 * 3_600_000}, // i18n
	.{"For 3 Days", 3 * 24 * 3_600_000}, // i18n
	.{"Forever", 0} // i18n
];

// The client's group under the names: Edit Profile, then "Your Status" with
// its expiry ("Until 3:45 PM") opening the status menu on hover.
account_actions :: () {
	s := store();
	gr := row("acctgrp");
	gr.semantic_size = .[ui.pct(1), ui.children()];
	{ ui.parent(gr); defer ui.pop_parent();
		spacer(.X, 12);
		g := ui.box("grp", .Draw_Background);
		g.semantic_size = .[ui.fill(), ui.children()];
		g.layout_axis = .Y;
		g.style.bg = T("--background-mod-subtle");
		g.style.radius = all4(8);
		{ ui.parent(g); defer ui.pop_parent();
			spacer(.Y, 4);
			ep := menu_item("editprofile", L("Edit Profile"), lead = "pencil");
			if ep.hovering sm.open, accts.menu_open = false, false;
			if ep.clicked {
				// opens Settings > Profiles, like the client
				app.profile_user = 0;
				settings_page = "Profiles";
				app.settings_open = true;
			}
			menu_sep("s1");
			st := ifx s.settings.status == .Offline then dc.Status.Online else s.settings.status; // before READY
			ss := menu_item("setstatus", status_text(st), .Chevron, sub = status_until(s.settings.status_expires_ms), open = sm.open, lead_status = st, warn = st == .Invisible);
			if ss.hovering || ss.clicked {
				sm.open, accts.menu_open = true, false;
				sm.row_y = ss.box.rect.y0;
			}
			menu_sep("s2");
			custom := custom_status_line();
			cs := menu_item("customstatus", ifx custom then custom else L("Set Custom Status"), lead = "emoji-people");
			if cs.hovering sm.open, accts.menu_open = false, false;
			if cs.clicked custom_status_open();
			if custom {
				cl := menu_item("clearcustom", L("Clear Custom Status"), lead = "circle-x");
				if cl.hovering sm.open, accts.menu_open = false, false;
				if cl.clicked set_my_custom_status("", .Dont_Clear);
			}
			spacer(.Y, 4);
		}
		spacer(.X, 12);
	}
	spacer(.Y, 12);
}

// status_menu: Online, then Idle / Do Not Disturb / Invisible, each with a
// duration submenu (bundle: set-status-submenu). Choosing keeps the menus
// open (dontCloseOnAction), as the client does.
status_menu :: (card: *ui.Box) {
	s := store();
	cur := s.settings.status;
	W :: cast(float32) 280;
	x := card.rect.x1 + 8;
	if x + W > app.ui.window.x - 8 x = card.rect.x0 - 8 - W;
	menu := menu_panel("statusmenu", .{x, clamp(sm.row_y - 8, 8, max(8.0, app.ui.window.y - (3 * 44 + GM_ROW_H + 25) - 8))}, W);
	{ ui.parent(menu); defer ui.pop_parent();
		spacer(.Y, 8);
		on := menu_item("online", L("Online"), lead_status = .Online);
		if on.hovering sm.sub = .Offline;
		if on.clicked set_my_status(.Online);
		menu_sep("s1");
		for st: dc.Status.[.Idle, .Dnd, .Invisible] {
			desc := "";
			if st == cur desc = status_until(s.settings.status_expires_ms);
			if desc == "" && st == .Dnd desc = L("You will not receive desktop notifications");
			if desc == "" && st == .Invisible desc = L("You will appear offline");
			it := menu_item(status_text(st), status_text(st), .Chevron, sub = desc, open = sm.sub == st, lead_status = st);
			if it.hovering || it.clicked {
				sm.sub = st;
				sm.sub_y = it.box.rect.y0;
			}
			if it.clicked set_my_status(st);
		}
		spacer(.Y, 8);
	}
	if sm.sub == .Offline return;
	sx := menu.rect.x1 + 4;
	if sx + 188 > app.ui.window.x - 8 sx = menu.rect.x0 - 4 - 188;
	sub := menu_panel("statusdur", .{sx, clamp(sm.sub_y - 8, 8, max(8.0, app.ui.window.y - (6 * GM_ROW_H + 16) - 8))}, 188);
	{ ui.parent(sub); defer ui.pop_parent();
		spacer(.Y, 8);
		for STATUS_DURATIONS if menu_item(it.text, tr(it.text)).clicked set_my_status(sm.sub, it.ms);
		spacer(.Y, 8);
	}
}

// set_my_status: online / idle / dnd / invisible, optionally for duration_ms.
set_my_status :: (st: dc.Status, duration_ms: s64 = 0) {
	if net_action() {
		dc.set_status(app.client, st, duration_ms);
		return;
	}
	s := store(); // offline (fixture) runs
	s.settings.status = st;
	s.settings.status_expires_ms = ifx duration_ms > 0 then wall_ms() + duration_ms else 0;
}

// status_until: "Until 3:45 PM", "Until tomorrow at 3:45 PM", "Until 10/30/26 at 3:45 PM" ("" for none).
status_until :: (end_ms: s64) -> string {
	if end_ms == 0 return "";
	cal :: (ms: s64) -> Calendar_Time { return to_calendar(dc.UNIX_EPOCH + milliseconds_to_apollo(local_ms(ms))); }
	same_day :: (a: Calendar_Time, b: Calendar_Time) -> bool { return a.year == b.year && a.month_starting_at_0 == b.month_starting_at_0 && a.day_of_month_starting_at_0 == b.day_of_month_starting_at_0; }
	t := cal(end_ms);
	now := wall_ms();
	tm := clock_text(t);
	if same_day(t, cal(now)) return tprint(L("Until %"), tm);
	if same_day(t, cal(now + 86_400_000)) return tprint(L("Until tomorrow at %"), tm);
	return tprint(L("Until %1 at %2"), date_format(i18n_fmt().numeric, t), tm);
}

// Settings: a floating modal like the visual-refresh client's (1200x640 at 1280x720):
// a 252px nav (profile, search, sections) and a content pane with a 48px title bar.
SET_INSET :: 40;
SET_NAV_W :: 252;
set_nav_need: float32;
SET_TITLE_H :: 48;
SET_CONTENT_MAX_W :: 696;
SET_SWATCH :: 48;
SET_SWATCH_PITCH :: 56;

Settings_Item :: struct {
	name: string; // English: the page's id
	icon: string;
	shown: string;
}

settings_modal :: () {
	s := store();
	settings_track();
	scrim := ui.box("settings_scrim", .Draw_Background | .Floating_X | .Floating_Y | .Overlay | .Clickable);
	scrim.semantic_size = .[ui.px(app.ui.window.x), ui.px(app.ui.window.y)];
	scrim.style.bg = .{0, 0, 0, 0.7};
	if ui.signal(scrim).clicked { app.settings_open = false; }
	{ ui.parent(scrim); defer ui.pop_parent();
		m := row("settings", .Draw_Background | .Draw_Border | .Floating_X | .Floating_Y | .Clickable | .Clip);
		m.semantic_size = .[ui.px(app.ui.window.x - 2 * SET_INSET), ui.px(app.ui.window.y - 2 * SET_INSET)];
		m.fixed_pos = .{SET_INSET, SET_INSET};
		m.cross_align = .Start;
		m.style.bg = T("--background-base-lower");
		m.style.border_color = T("--border-subtle");
		m.style.border = 1;
		m.style.radius = all4(12);
		ui.signal(m);
		{ ui.parent(m); defer ui.pop_parent();
			nav := ui.box("nav", .Scroll_Y | .Clip);
			// wider for a language whose page names don't fit (the widest name, measured on the last layout)
			nav.semantic_size = .[ui.px(clamp(set_nav_need, SET_NAV_W, SET_NAV_W + 100)), ui.pct(1)];
			set_nav_need = 0;
			nav.layout_axis = .Y;
			ui.signal(nav);
			{ ui.parent(nav); defer ui.pop_parent();
				spacer(.Y, 24);
				me := row("me");
				me.semantic_size = .[ui.pct(1), ui.px(48)];
				{ ui.parent(me); defer ui.pop_parent();
					spacer(.X, 24);
					avatar_box("av", s.me, 48);
					spacer(.X, 10);
					col := ui.box("names");
					col.semantic_size = .[ui.fill(), ui.children()];
					{ ui.parent(col); defer ui.pop_parent();
						u := dc.user_get(s, s.me);
						label(ifx u then dc.display_name(u) else "…", .Semibold, 16, T("--text-strong"), 20);
						er := row("edit", .Clickable);
						er.semantic_size = .[ui.children(), ui.px(18)];
						er.hover_cursor = .Pointer;
						if ui.signal(er).clicked { settings_page = "Profiles"; }
						{ ui.parent(er); defer ui.pop_parent();
							label(L("Edit Profiles"), .Medium, 14, T("--text-muted"), 18);
							spacer(.X, 4);
							icon("pen", "pencil", 12, T("--text-muted"));
						}
					}
				}
				spacer(.Y, 16);
				settings_nav_search(); // view_settings_prefs.jai: filters the items below
				spacer(.Y, 8);
				// 0.0.419: Streamer Mode is a section of Appearance (its sub-nav), not a page
				items := Settings_Item.[.{"Account", "user-circle", L("Account")}, .{"Profiles", "pencil", L("Profiles")}, .{"Data & Privacy", "eye-slash", L("Data & Privacy")}, .{"Messaging Permissions", "lock", L("Messaging Permissions")}, .{"Appearance", "paint-palette", L("Appearance")}, .{"Voice & Video", "microphone", L("Voice & Video")}, .{"Chat", "chat", L("Chat")}, .{"Notifications", "bell", L("Notifications")}, .{"Keybinds", "key", L("Keybinds")}, .{"Accessibility", "eye", L("Accessibility")}, .{"System", "screen", L("System")}, .{"Language & Time", "clock", L("Language & Time")}, .{"Devices", "phone", L("Devices")}, .{"Connected Apps", "link", L("Connected Apps")}, .{"Activity Privacy", "game-controller", L("Activity Privacy")}, .{"Developer", "angle-brackets", L("Developer")}];
				for items {
					if it.name == "System" && OS == .MACOS continue; // the client's System panel: Windows and Linux
					if !settings_nav_match(it.name) && !(it.name == "Appearance" && settings_nav_match("Streamer Mode")) { continue; }
					sel := it.name == settings_page;
					outer := row(it.name);
					outer.semantic_size = .[ui.pct(1), ui.px(37)];
					{ ui.parent(outer); defer ui.pop_parent();
						spacer(.X, 16);
						r := row("item", .Clickable | .Draw_Background | .Hot_Animation);
						r.semantic_size = .[ui.fill(), ui.px(33)];
						r.style.radius = all4(8);
						r.style.bg = ifx sel then T("--background-mod-normal") else .{};
						r.style.bg_hot = ifx sel then r.style.bg else T("--background-mod-subtle");
						sig := ui.signal(r);
						if sig.clicked { settings_page = it.name; }
						c := ifx sel || sig.hovering then T("--interactive-text-active") else T("--interactive-text-default");
						{ ui.parent(r); defer ui.pop_parent();
							spacer(.X, 8);
							icon("i", it.icon, 20, c);
							spacer(.X, 8);
							lb := label(it.shown, .Medium, 16, c, 20);
							if lb.prev_layout set_nav_need = max(set_nav_need, lb.prev_layout.width + 16 + 8 + 20 + 8 + 12 + 16);
						}
						spacer(.X, 16);
					}
					if it.name == "Appearance" && (sel || settings_nav_match("Streamer Mode") && !settings_nav_match("Appearance")) { appearance_subnav(); }
				}
				settings_nav_logout();
			}
			edge := ui.box("navedge", .Draw_Background);
			edge.semantic_size = .[ui.px(1), ui.pct(1)];
			edge.style.bg = T("--border-muted");
			content := ui.box("content", .Draw_Background);
			content.semantic_size = .[ui.fill(), ui.pct(1)];
			content.layout_axis = .Y;
			content.style.bg = T("--background-base-low");
			content.style.radius = .[0, 11, 0, 11]; // inside the modal's 1px border and 12 radius
			{ ui.parent(content); defer ui.pop_parent();
				t := row("t");
				t.semantic_size = .[ui.pct(1), ui.px(SET_TITLE_H)];
				{ ui.parent(t); defer ui.pop_parent();
					spacer(.X, 20);
					label(tr(settings_page), .Semibold, 16, T("--text-strong"), 20);
					filler(.X);
					close := ui.box("close", .Clickable);
					close.semantic_size = .[ui.px(20), ui.px(20)];
					cs := ui.signal(close);
					set_icon(close, "x-large", ifx cs.hovering then T("--interactive-icon-hover") else T("--interactive-icon-default"));
					if cs.clicked { app.settings_open = false; }
					spacer(.X, 16);
				}
				tl := ui.box("tline", .Draw_Background);
				tl.semantic_size = .[ui.pct(1), ui.px(1)];
				tl.style.bg = T("--border-muted");
				if settings_page == "Voice & Video" {
					voice_settings_page();
				} else if settings_page == "Appearance" {
					appearance_page();
				} else if settings_page == "Account" {
					my_account_page(); // view_settings_account.jai
				} else if settings_page == "Profiles" {
					profiles_page();
				} else if settings_page == "Notifications" {
					notifications_page(); // view_settings_prefs.jai
				} else if settings_page == "Keybinds" {
					keybinds_page(); // keybinds.jai
				} else if settings_page == "Accessibility" {
					accessibility_page();
				} else if settings_page == "System" {
					system_page();
				} else if settings_page == "Language & Time" {
					language_page(); // view_settings_user.jai
				} else if settings_page == "Developer" {
					developer_page();
				} else if settings_page == "Devices" {
					devices_page();
				} else if settings_page == "Messaging Permissions" {
					messaging_page();
				} else if settings_page == "Activity Privacy" {
					activity_page(); // view_settings_user.jai
				} else if settings_page == "Data & Privacy" {
					data_privacy_page();
				} else if settings_page == "Chat" {
					chat_page();
				} else if settings_page == "Connected Apps" {
					connected_apps_page();
				}
			}
		}
		if select_is_open() dropdown_list(); // a select_field's open list (view_server_settings.jai), over the modal
	}
	for * e: app.ui.events {
		if e.kind == .Key_Down && e.key == .Escape && !voice_dropdown_open() && !keybinds_capturing() && !mfa_is_open() && !account_modal_is_open() { // the dropdown's own Escape closes only it
			if select_is_open() select_close(); else app.settings_open = false;
			e.consumed = true;
		}
	}
}

// ---- settings traffic: which pane is showing (dc.settings_pane_shown) ----

#scope_file
set_tr: struct {
	open: bool;
	pane: dc.Settings_Pane;
	profiles: bool;
	jump: string; // Appearance sub-nav: section to scroll to ("" = none)
};

pane_of :: (page: string) -> dc.Settings_Pane {
	if page == {
	case "Account";
		return .Account;
	case "Appearance";
		return .Appearance;
	case "Voice & Video";
		return .Voice;
	case "Notifications";
		return .Notifications;
	case "Language & Time";
		return .Language_And_Time;
	case "Developer";
		return .Developer;
	case "Data & Privacy";
		return .Data_And_Privacy;
	case "Messaging Permissions";
		return .Messaging_Permissions;
	case "Accessibility";
		return .Accessibility;
	case "System"; #through;
	case "Keybinds"; // the client's keybinds are a category of System
		return .System;
	case "Chat"; // a category of the client's Appearance
		return .Appearance;
	case "Devices"; // the client's sessions are nested in Account
		return .Account;
	case "Activity Privacy";
		return .Activity_Privacy;
	case "Connected Apps";
		return .Connected_Apps;
	}
	return .None; // Profiles: the profile editor opens over the settings
}

// settings_track runs each frame the modal is open: a newly shown pane loads what
// it shows and tracks settings_pane_viewed; "Edit Profiles" opening loads the editor.
settings_track :: () {
	opening := !set_tr.open;
	if opening { set_tr = .{open = true}; }
	pane := pane_of(settings_page);
	if pane != .None && (opening || pane != set_tr.pane) {
		if app.client != null { dc.settings_pane_shown(app.client, set_tr.pane, pane, app.view.guild, app.view.channel, streamer_settings.enabled); }
		set_tr.pane = pane;
	}
	in_profiles := settings_page == "Profiles";
	if in_profiles && !set_tr.profiles && app.client != null { dc.open_profile_editor(app.client); }
	set_tr.profiles = in_profiles;
}
#scope_export

// settings_closed: the modal is not shown this frame (the next open starts over).
settings_closed :: () {
	if set_tr.open {
		select_close(); // a select left open here (the list is shared with Server Settings)
		user_settings_left();
	}
	set_tr.open = false;
}

settings_reset_for_test :: () {set_tr = .{};}
#scope_file

// Appearance's sub-nav (shown under it while selected, or while the search matches
// a section): clicking a section scrolls the page to it.
appearance_subnav :: () {
	for sub: (string.["Theme", "Message Display", "Streamer Mode"]) {
		r := row(tprint("sub_%", sub), .Clickable | .Hot_Animation);
		r.semantic_size = .[ui.pct(1), ui.px(33)];
		sig := ui.signal(r);
		{ ui.parent(r); defer ui.pop_parent();
			spacer(.X, 28);
			bar := ui.box("bar", .Draw_Background);
			bar.semantic_size = .[ui.px(2), ui.pct(1)];
			bar.style.bg = T("--border-subtle");
			spacer(.X, 14);
			label(tr(sub), .Medium, 16, ifx sig.hovering then T("--interactive-text-active") else T("--interactive-text-default"), 20);
		}
		if sig.clicked {
			settings_page = "Appearance";
			set_tr.jump = sub;
		}
	}
}

// appearance_scroll_target: scroll the Appearance page to this section when the sub-nav asked.
appearance_scroll_target :: (scroll: *ui.Box, heading: *ui.Box, name: string) {
	if set_tr.jump != name || heading.rect.y1 <= heading.rect.y0 { return; }
	set_tr.jump = "";
	scroll.view_off_target.y = heading.rect.y0 - scroll.rect.y0 + scroll.view_off.y - 24;
}

chat_font_drag: float32;
chat_font_snap :: (v: float32) -> int {
	best := 16;
	for CHAT_FONT_SIZES if abs(it - v) < abs(best - v) best = it;
	return best;
}

// Appearance > Theme: heading, "Same as Device Theme" row, the default theme swatches.
appearance_page :: () {
	scroll := ui.box("appearance_scroll", .Scroll_Y | .Clip);
	scroll.semantic_size = .[ui.pct(1), ui.fill()];
	scroll.layout_axis = .Y;
	scroll.scrollbar = .Auto;
	ui.signal(scroll);
	ui.push_parent(scroll);
	defer ui.pop_parent();
	page := row("appearance");
	page.semantic_size = .[ui.pct(1), ui.children()];
	page.cross_align = .Start;
	{ ui.parent(page); defer ui.pop_parent();
		filler(.X);
		col := ui.box("col");
		col.semantic_size = .[ui.px(SET_CONTENT_MAX_W), ui.children()];
		col.layout_axis = .Y;
		{ ui.parent(col); defer ui.pop_parent();
			spacer(.Y, 64);
			th := label(L("Theme"), .Medium, 24, T("--text-strong"), 32);
			appearance_scroll_target(scroll, th, "Theme");
			spacer(.Y, 30);
			dr := row("device", .Clickable);
			dr.semantic_size = .[ui.pct(1), ui.px(40)];
			if ui.signal(dr).clicked { theme_follow_os_set(!theme_follow_os); }
			{ ui.parent(dr); defer ui.pop_parent();
				c := ui.box("c");
				c.semantic_size = .[ui.fill(), ui.children()];
				{ ui.parent(c); defer ui.pop_parent();
					label(L("Same as Device Theme"), .Medium, 16, T("--text-strong"), 20);
					spacer(.Y, 2);
					label(L("Match your device's light or dark mode."), .Normal, 14, T("--text-subtle"), 18);
				}
				set_switch(theme_follow_os);
			}
			spacer(.Y, 32);
			label(L("Default Themes"), .Semibold, 16, T("--text-default"), 20);
			spacer(.Y, 24);
			sw := row("swatches");
			sw.semantic_size = .[ui.pct(1), ui.px(SET_SWATCH)];
			{ ui.parent(sw); defer ui.pop_parent();
				for name: enum_values_as_enum(Theme_Name) {
					tokens: Theme;
					defer deinit(*tokens.tokens);
					theme_load(*tokens, name);
					sel := app.theme.name == name && !theme_follow_os;
					b := ui.box(tprint("%", name), .Clickable | .Draw_Background | .Draw_Border);
					b.semantic_size = .[ui.px(SET_SWATCH), ui.px(SET_SWATCH)];
					b.style.radius = all4(8);
					b.style.bg = ifx name == .Light then ui.Color.{1, 1, 1, 1} else tok(*tokens, "--background-base-lower");
					b.style.border = ifx sel then 2.0 else 1.0;
					b.style.border_color = ifx sel then T("--background-brand") else T("--interactive-icon-default");
					if ui.signal(b).clicked { theme_set_by_user(name); }
					if sel {
						{ ui.parent(b); defer ui.pop_parent();
							// check badge on the selected swatch's top-right corner
							badge := ui.box("check", .Draw_Background | .Floating_X | .Floating_Y);
							badge.semantic_size = .[ui.px(20), ui.px(20)];
							badge.fixed_pos = .{SET_SWATCH - 14, -6};
							badge.style.radius = all4(10);
							badge.style.bg = T("--background-brand");
							{ ui.parent(badge); defer ui.pop_parent();
								ic := icon("i", "checkmark-small-bold", 16, .{1, 1, 1, 1});
								ic.flags |= .Floating_X | .Floating_Y;
								ic.fixed_pos = .{2, 2};
							}
						}
					}
					spacer(.X, SET_SWATCH_PITCH - SET_SWATCH);
				}
			}
			spacer(.Y, 48);
			md := label(L("Message Display"), .Semibold, 16, T("--text-default"), 20);
			appearance_scroll_target(scroll, md, "Message Display");
			spacer(.Y, 16);
			compact := message_compact();
			if radio_choice("cozy", L("Cozy"), L("Modern, beautiful, and easy on your eyes."), !compact) || radio_choice("compact", L("Compact"), L("Fit more messages on screen at one time. #IRC"), compact)
				proto_put(6, 17, dc.pb_field_bool_value(17, !compact));
			spacer(.Y, 32);
			label(L("Chat Font Scaling"), .Semibold, 16, T("--text-default"), 20);
			spacer(.Y, 16);
			// snaps to the marks on release, like Zoom level
			w := set_content_w();
			v := ifx chat_font_drag > 0 then chat_font_drag else cast(float32) chat_font_px;
			if slider("chatfont", *v, xx CHAT_FONT_SIZES[0], xx peek(CHAT_FONT_SIZES), w, tprint("%px", chat_font_snap(v))) chat_font_drag = v;
			if chat_font_drag > 0 && !app.ui.mouse_down[0] {
				chat_font_px = chat_font_snap(chat_font_drag);
				chat_font_drag = 0;
			}
			marks := row("fontmarks");
			marks.semantic_size = .[ui.px(w), ui.px(20)];
			{ ui.parent(marks); defer ui.pop_parent();
				lo, hi := cast(float32) CHAT_FONT_SIZES[0], cast(float32) peek(CHAT_FONT_SIZES);
				for CHAT_FONT_SIZES {
					mk := label(tprint("%px", it), .Medium, 12, ifx it == chat_font_px then T("--text-strong") else T("--text-muted"), 16);
					mk.flags |= .Floating_X;
					mk.fixed_pos.x = w * (it - lo) / (hi - lo) - 12;
				}
			}
			spacer(.Y, 48);
			if set_toggle_row("smooth", L("Smooth Scrolling"), L("Ease the chat and lists toward where you scroll. Off, they jump there at once (always, when your device asks for reduced motion)."), !smooth_scroll_off) {
				smooth_scroll_off = !smooth_scroll_off;
			}
			spacer(.Y, 48);
			div := ui.box("smdiv", .Draw_Background);
			div.semantic_size = .[ui.pct(1), ui.px(1)];
			div.style.bg = T("--border-subtle");
			spacer(.Y, 48);
			sh := label(L("Streamer Mode"), .Medium, 24, T("--text-strong"), 32);
			appearance_scroll_target(scroll, sh, "Streamer Mode");
			spacer(.Y, 24);
			streamer_settings_section(); // view_streamer.jai
			spacer(.Y, 64);
		}
		filler(.X);
	}
}
