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
		gfx.rect(.{origin.x + x, y + 2, origin.x + x + 1.5, y + tl.line_h - 2}, cast(gfx.Color)(cast(T)("--text-default")));
	}
	platform.set_ime_rect(origin.x + x, y, 1, tl.line_h);
}

// Where a profile popout was opened from (telemetry: user_profile_action's
// layout and location stack; .Other sends none, its stack names are not known).
Profile_Source :: enum u8 {
	Other;
	Message_Author; // a message's username (source_message_id)
	Account_Panel; // our own panel at the bottom left (ACCOUNT_POPOUT)
}

open_profile :: (uid: dc.Snowflake, anchor: ui.Rect, source := Profile_Source.Other, message_id: dc.Snowflake = 0) {
	app.profile_user = uid;
	app.profile_anchor = anchor;
	app.profile_above = false;
	app.profile_open_t = 0;
	if app.client == null { return; }
	if source == {
	case .Message_Author;
		dc.profile_view_begin(app.client, .Popout, uid, app.view.guild, app.view.channel, message_id);
	case .Account_Panel;
		dc.profile_view_begin(app.client, .Account_Popout, uid, 0, 0, 0);
	case .Other;
	}
	dc.fetch_profile(app.client, uid, app.view.guild);
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
	W :: 300;
	scrim := ui.box("profile_scrim", .{.Clickable, .Floating_X, .Floating_Y, .Overlay});
	scrim.semantic_size = .{__IDX__.X = ui.px(app.ui.window.x), __IDX__.Y = ui.px(app.ui.window.y)};
	if ui.signal(scrim).clicked {
		app.profile_user = 0;
		return;
	}
	ui.animate(*app.profile_open_t, 1, 25);
	p := ui.box("profile", .{.Draw_Background, .Draw_Border, .Draw_Shadow, .Floating_X, .Floating_Y, .Overlay, .Clickable});
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
	y = clamp(y, 8, max(8, app.ui.window.y - h - 8));
	p.semantic_size = .{__IDX__.X = ui.px(W), __IDX__.Y = ui.children()};
	p.fixed_pos = .{x, y + (1 - app.profile_open_t) * 8};
	p.opacity = app.profile_open_t;
	p.layout_axis = .Y;
	p.style.bg = cast(T)("--background-surface-high");
	p.style.border_color = cast(T)("--border-subtle");
	p.style.border = 1;
	p.style.radius = 8;
	p.style.shadow_color = .{0, 0, 0, 0.35};
	p.style.shadow_blur = 16;
	p.style.shadow_offset = .{0, 8};
	ui.signal(p); // swallow clicks inside
	if ui.parent(p) {
		banner := ui.box("banner", .{.Draw_Background});
		banner.semantic_size = .{__IDX__.X = ui.pct(1), __IDX__.Y = ui.px(105)};
		banner.style.radius = .{8, 8, 0, 0};
		banner.style.bg = profile_banner_color(uid);
		if u.banner != "" { set_remote_image(banner, dc.banner_url(uid, u.banner, 600)); }
		if ui.parent(banner) {
			// "..." on the banner's top-right (official: 28px dark circle, 12px in)
			more := ui.box("more", .{.Clickable, .Draw_Background, .Floating_X, .Floating_Y});
			more.semantic_size = .{__IDX__.X = ui.px(28), __IDX__.Y = ui.px(28)};
			more.fixed_pos = .{W - 12 - 28, 12};
			more.style.radius = 14;
			more.style.bg = .{0, 0, 0, 0.5};
			if ui.signal(more).clicked {
				// the user menu draws below this popout, so hand over to it
				open_user_menu(uid, .{more.rect.x0, more.rect.y1 + 4});
				app.profile_user = 0;
			}
			if ui.parent(more) {
				ic := icon("i", "more-horizontal", 16, .{1, 1, 1, 1});
				ic.flags += .{.Floating_X, .Floating_Y};
				ic.fixed_pos = .{6, 6};
			}
		}
		av_row := ui.box("avrow");
		av_row.semantic_size = .{__IDX__.X = ui.pct(1), __IDX__.Y = ui.px(44)};
		if ui.parent(av_row) {
			ring := ui.box("ring", .{.Draw_Background, .Floating_X, .Floating_Y});
			ring.semantic_size = .{__IDX__.X = ui.px(92), __IDX__.Y = ui.px(92)};
			ring.fixed_pos = .{10, -50};
			ring.style.radius = 46;
			ring.style.bg = p.style.bg;
			if ui.parent(ring) {
				av := avatar_with_status("av", uid, 80, p.style.bg);
				av.flags += .{.Floating_X, .Floating_Y};
				av.fixed_pos = .{6, 6};
				profile_full_avatar_hook(av, uid); // click: full profile modal
			}
		}
		info := ui.box("info");
		info.semantic_size = .{__IDX__.X = ui.pct(1), __IDX__.Y = ui.children()};
		info.layout_axis = .Y;
		if ui.parent(info) {
			pad := row("namepad");
			pad.semantic_size = .{__IDX__.X = ui.pct(1), __IDX__.Y = ui.px(26)};
			if ui.parent(pad) {
				spacer(.X, 16);
				n := label(dc.user_name(s, uid, app.view.guild), .Bold, 20, cast(T)("--text-strong"), 24);
				n.flags += .{.Selectable_Text};
				n.sel_order = 1;
			}
			pad2 := row("userpad");
			pad2.semantic_size = .{__IDX__.X = ui.pct(1), __IDX__.Y = ui.px(20)};
			if ui.parent(pad2) {
				spacer(.X, 16);
				un := label(u.username, .Normal, 14, cast(T)("--text-default"), 18);
				un.flags += .{.Selectable_Text};
				un.sel_order = 2;
				if u.pronouns != "" {
					label(fmt.tprintf(" • %s", u.pronouns), .Normal, 14, cast(T)("--text-default"), 18);
				}
			}
			if u.bio != "" {
				spacer(.Y, 12);
				bio := ui.box("bio", .{.Selectable_Text, .Wrap_Text});
				bio.semantic_size = .{__IDX__.X = ui.pct(1), __IDX__.Y = ui.text_size()};
				bio.style.padding = .{16, 0};
				bio.style.line_height = 18;
				bio.style.text_color = cast(T)("--text-default");
				bio.sel_order = 3;
				blocks := md_parse(u.bio);
				if len(blocks) > 0 { ui.set_spans(bio, tokens_to_spans(blocks[0].tokens, .Normal, 14, null)); }
			}
			spacer(.Y, 16);
			if uid == s.me {
				er := row("editrow");
				er.semantic_size = .{__IDX__.X = ui.pct(1), __IDX__.Y = ui.px(32)};
				if ui.parent(er) {
					spacer(.X, 16);
					eb := row("editprofile", .{.Clickable, .Draw_Background, .Hot_Animation});
					eb.semantic_size = .{__IDX__.X = ui.fill(), __IDX__.Y = ui.px(32)};
					eb.style.radius = 8;
					eb.style.bg = cast(T)("--background-brand");
					eb.style.bg_hot = with_alpha(cast(T)("--background-brand"), 0.85);
					if ui.signal(eb).clicked {
						// opens Settings > Profiles, like the client (it used to do nothing)
						app.profile_user = 0;
						settings_page = "Profiles";
						app.settings_open = true;
					}
					if ui.parent(eb) {
						filler(.X);
						icon("i", "pencil", 16, .{1, 1, 1, 1});
						spacer(.X, 4);
						label("Edit Profile", .Medium, 14, .{1, 1, 1, 1}, 18);
						filler(.X);
					}
					spacer(.X, 16);
				}
				spacer(.Y, 16);
			}
			if uid != s.me {
				mr := row("msgrow");
				mr.semantic_size = .{__IDX__.X = ui.pct(1), __IDX__.Y = ui.px(40)};
				if ui.parent(mr) {
					spacer(.X, 16);
					mb := row(fmt.tprintf("Message @%s##msgbtn", dc.user_name(s, uid)), .{.Clickable, .Draw_Background, .Draw_Border, .Draw_Text});
					mb.semantic_size = .{__IDX__.X = ui.fill(), __IDX__.Y = ui.px(40)};
					mb.style.bg = cast(T)("--input-background-default");
					mb.style.border_color = cast(T)("--border-subtle");
					mb.style.border = 1;
					mb.style.radius = 8;
					mb.style.padding = .{12, 0};
					mb.style.font = F(.Normal);
					mb.style.font_size = 14;
					mb.style.text_color = cast(T)("--text-muted");
					mb.hover_cursor = .IBeam;
					if ui.signal(mb).clicked && net_action() {
						{ existing := dc.open_dm(app.client, uid, "Profile");
						if existing != 0 { select_channel(0, existing); } else { app.pending_dm_user = uid; } }
						app.profile_user = 0;
					}
					spacer(.X, 16);
				}
				spacer(.Y, 16);
			}
		}
	}
	for e: app.ui.events {
		if e.kind == .Key_Down && e.key == .Escape { app.profile_user = 0; }
	}
}

// Settings: a floating modal like the visual-refresh client's (1200x640 at 1280x720):
// a 252px nav (profile, search, sections) and a content pane with a 48px title bar.
SET_INSET :: 40;
SET_NAV_W :: 252;
SET_TITLE_H :: 48;
SET_CONTENT_MAX_W :: 696;
SET_SWATCH :: 48;
SET_SWATCH_PITCH :: 56;

Settings_Item :: struct {
	name: string;
	icon: string;
}

settings_modal :: () {
	s := store();
	settings_track();
	scrim := ui.box("settings_scrim", .{.Draw_Background, .Floating_X, .Floating_Y, .Overlay, .Clickable});
	scrim.semantic_size = .{__IDX__.X = ui.px(app.ui.window.x), __IDX__.Y = ui.px(app.ui.window.y)};
	scrim.style.bg = .{0, 0, 0, 0.7};
	if ui.signal(scrim).clicked { app.settings_open = false; }
	if ui.parent(scrim) {
		m := row("settings", .{.Draw_Background, .Draw_Border, .Floating_X, .Floating_Y, .Clickable, .Clip});
		m.semantic_size = .{__IDX__.X = ui.px(app.ui.window.x - 2 * SET_INSET), __IDX__.Y = ui.px(app.ui.window.y - 2 * SET_INSET)};
		m.fixed_pos = .{SET_INSET, SET_INSET};
		m.cross_align = .Start;
		m.style.bg = cast(T)("--background-base-lower");
		m.style.border_color = cast(T)("--border-subtle");
		m.style.border = 1;
		m.style.radius = 12;
		ui.signal(m);
		if ui.parent(m) {
			nav := ui.box("nav");
			nav.semantic_size = .{__IDX__.X = ui.px(SET_NAV_W), __IDX__.Y = ui.pct(1)};
			nav.layout_axis = .Y;
			if ui.parent(nav) {
				spacer(.Y, 24);
				me := row("me");
				me.semantic_size = .{__IDX__.X = ui.pct(1), __IDX__.Y = ui.px(48)};
				if ui.parent(me) {
					spacer(.X, 24);
					avatar_box("av", s.me, 48);
					spacer(.X, 10);
					col := ui.box("names");
					col.semantic_size = .{__IDX__.X = ui.fill(), __IDX__.Y = ui.children()};
					if ui.parent(col) {
						name := "…";
						{ u := dc.user_get(s, s.me);
						if u != null { name = dc.display_name(u); } }
						label(name, .Semibold, 16, cast(T)("--text-strong"), 20);
						er := row("edit", .{.Clickable});
						er.semantic_size = .{__IDX__.X = ui.children(), __IDX__.Y = ui.px(18)};
						er.hover_cursor = .Pointer;
						if ui.signal(er).clicked { settings_page = "Profiles"; }
						if ui.parent(er) {
							label("Edit Profiles", .Medium, 14, cast(T)("--text-muted"), 18);
							spacer(.X, 4);
							icon("pen", "pencil", 12, cast(T)("--text-muted"));
						}
					}
				}
				spacer(.Y, 16);
				settings_nav_search(); // view_settings_prefs.odin: filters the items below
				spacer(.Y, 8);
				// 0.0.419: Streamer Mode is a section of Appearance (its sub-nav), not a page
				items := Settings_Item.[.{"Account", "user-circle"}, .{"Profiles", "pencil"}, .{"Appearance", "paint-palette"}, .{"Voice & Video", "microphone"}, .{"Notifications", "bell"}];
				for it_: items {
					if !settings_nav_match(it_.name) && !(it_.name == "Appearance" && settings_nav_match("Streamer Mode")) { continue; }
					sel := it_.name == settings_page;
					outer := row(it_.name);
					outer.semantic_size = .{__IDX__.X = ui.pct(1), __IDX__.Y = ui.px(37)};
					if ui.parent(outer) {
						spacer(.X, 16);
						r := row("item", .{.Clickable, .Draw_Background, .Hot_Animation});
						r.semantic_size = .{__IDX__.X = ui.fill(), __IDX__.Y = ui.px(33)};
						r.style.radius = 8;
						r.style.bg = ifx sel then cast(T)("--background-mod-normal") else .{};
						r.style.bg_hot = ifx sel then r.style.bg else cast(T)("--background-mod-subtle");
						sig := ui.signal(r);
						if sig.clicked { settings_page = it_.name; }
						c := ifx sel || sig.hovering then cast(T)("--interactive-text-active") else cast(T)("--interactive-text-default");
						if ui.parent(r) {
							spacer(.X, 8);
							icon("i", it_.icon, 20, c);
							spacer(.X, 8);
							label(it_.name, .Medium, 16, c, 20);
						}
						spacer(.X, 16);
					}
					if it_.name == "Appearance" && (sel || settings_nav_match("Streamer Mode") && !settings_nav_match("Appearance")) { appearance_subnav(); }
				}
				settings_nav_logout();
			}
			edge := ui.box("navedge", .{.Draw_Background});
			edge.semantic_size = .{__IDX__.X = ui.px(1), __IDX__.Y = ui.pct(1)};
			edge.style.bg = cast(T)("--border-muted");
			content := ui.box("content", .{.Draw_Background});
			content.semantic_size = .{__IDX__.X = ui.fill(), __IDX__.Y = ui.pct(1)};
			content.layout_axis = .Y;
			content.style.bg = cast(T)("--background-base-low");
			if ui.parent(content) {
				t := row("t");
				t.semantic_size = .{__IDX__.X = ui.pct(1), __IDX__.Y = ui.px(SET_TITLE_H)};
				if ui.parent(t) {
					spacer(.X, 20);
					label(settings_page, .Semibold, 16, cast(T)("--text-strong"), 20);
					filler(.X);
					close := ui.box("close", .{.Clickable});
					close.semantic_size = .{__IDX__.X = ui.px(20), __IDX__.Y = ui.px(20)};
					cs := ui.signal(close);
					set_icon(close, "x-large", ifx cs.hovering then cast(T)("--interactive-icon-hover") else cast(T)("--interactive-icon-default"));
					if cs.clicked { app.settings_open = false; }
					spacer(.X, 16);
				}
				tl := ui.box("tline", .{.Draw_Background});
				tl.semantic_size = .{__IDX__.X = ui.pct(1), __IDX__.Y = ui.px(1)};
				tl.style.bg = cast(T)("--border-muted");
				if settings_page == "Voice & Video" {
					voice_settings_page();
				} else if settings_page == "Appearance" {
					appearance_page();
				} else if settings_page == "Account" {
					my_account_page(); // view_settings_account.odin
				} else if settings_page == "Profiles" {
					profiles_page();
				} else if settings_page == "Notifications" {
					notifications_page(); // view_settings_prefs.odin
				}
			}
		}
	}
	for e: app.ui.events {
		if e.kind == .Key_Down && e.key == .Escape { app.settings_open = false; }
	}
}
#scope_file

// ---- settings traffic: which pane is showing (dc.settings_pane_shown) ----

// ---- settings traffic: which pane is showing (dc.settings_pane_shown) ----

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
settings_closed :: () {set_tr.open = false;}

settings_reset_for_test :: () {set_tr = .{};}
#scope_file

// Appearance's sub-nav (shown under it while selected, or while the search matches
// a section): clicking a section scrolls the page to it.
appearance_subnav :: () {
	for sub: (string.["Theme", "Streamer Mode"]) {
		r := row(fmt.tprintf("sub_%s", sub), .{.Clickable, .Hot_Animation});
		r.semantic_size = .{__IDX__.X = ui.pct(1), __IDX__.Y = ui.px(33)};
		sig := ui.signal(r);
		if ui.parent(r) {
			spacer(.X, 28);
			bar := ui.box("bar", .{.Draw_Background});
			bar.semantic_size = .{__IDX__.X = ui.px(2), __IDX__.Y = ui.pct(1)};
			bar.style.bg = cast(T)("--border-subtle");
			spacer(.X, 14);
			label(sub, .Medium, 16, ifx sig.hovering then cast(T)("--interactive-text-active") else cast(T)("--interactive-text-default"), 20);
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

// Appearance > Theme: heading, "Same as Device Theme" row, the default theme swatches.
appearance_page :: () {
	scroll := ui.box("appearance_scroll", .{.Scroll_Y, .Clip});
	scroll.semantic_size = .{__IDX__.X = ui.pct(1), __IDX__.Y = ui.fill()};
	scroll.layout_axis = .Y;
	ui.signal(scroll);
	ui.push_parent(scroll);
	defer ui.pop_parent();
	page := row("appearance");
	page.semantic_size = .{__IDX__.X = ui.pct(1), __IDX__.Y = ui.children()};
	page.cross_align = .Start;
	if ui.parent(page) {
		filler(.X);
		col := ui.box("col");
		col.semantic_size = .{__IDX__.X = ui.px(SET_CONTENT_MAX_W), __IDX__.Y = ui.children()};
		col.layout_axis = .Y;
		if ui.parent(col) {
			spacer(.Y, 64);
			th := label("Theme", .Medium, 24, cast(T)("--text-strong"), 32);
			appearance_scroll_target(scroll, th, "Theme");
			spacer(.Y, 30);
			dr := row("device", .{.Clickable});
			dr.semantic_size = .{__IDX__.X = ui.pct(1), __IDX__.Y = ui.px(40)};
			if ui.signal(dr).clicked { theme_follow_os_set(!theme_follow_os); }
			if ui.parent(dr) {
				c := ui.box("c");
				c.semantic_size = .{__IDX__.X = ui.fill(), __IDX__.Y = ui.children()};
				if ui.parent(c) {
					label("Same as Device Theme", .Medium, 16, cast(T)("--text-strong"), 20);
					spacer(.Y, 2);
					label("Match your device's light or dark mode.", .Normal, 14, cast(T)("--text-subtle"), 18);
				}
				set_switch(theme_follow_os);
			}
			spacer(.Y, 32);
			label("Default Themes", .Semibold, 16, cast(T)("--text-default"), 20);
			spacer(.Y, 24);
			sw := row("swatches");
			sw.semantic_size = .{__IDX__.X = ui.pct(1), __IDX__.Y = ui.px(SET_SWATCH)};
			if ui.parent(sw) {
				for name: Theme_Name {
					tokens: Theme;
					defer delete(tokens.tokens);
					theme_load(*tokens, name);
					sel := app.theme.name == name && !theme_follow_os;
					b := ui.box(fmt.tprint(name), .{.Clickable, .Draw_Background, .Draw_Border});
					b.semantic_size = .{__IDX__.X = ui.px(SET_SWATCH), __IDX__.Y = ui.px(SET_SWATCH)};
					b.style.radius = 8;
					b.style.bg = ifx name == .Light then ui.Color.{1, 1, 1, 1} else tok(*tokens, "--background-base-lower");
					b.style.border = ifx sel then 2 else 1;
					b.style.border_color = ifx sel then cast(T)("--background-brand") else cast(T)("--interactive-icon-default");
					if ui.signal(b).clicked { theme_set_by_user(name); }
					if sel {
						if ui.parent(b) {
							// check badge on the selected swatch's top-right corner
							badge := ui.box("check", .{.Draw_Background, .Floating_X, .Floating_Y});
							badge.semantic_size = .{__IDX__.X = ui.px(20), __IDX__.Y = ui.px(20)};
							badge.fixed_pos = .{SET_SWATCH - 14, -6};
							badge.style.radius = 10;
							badge.style.bg = cast(T)("--background-brand");
							if ui.parent(badge) {
								ic := icon("i", "checkmark-small-bold", 16, .{1, 1, 1, 1});
								ic.flags += .{.Floating_X, .Floating_Y};
								ic.fixed_pos = .{2, 2};
							}
						}
					}
					spacer(.X, SET_SWATCH_PITCH - SET_SWATCH);
				}
			}
			spacer(.Y, 48);
			div := ui.box("smdiv", .{.Draw_Background});
			div.semantic_size = .{__IDX__.X = ui.pct(1), __IDX__.Y = ui.px(1)};
			div.style.bg = cast(T)("--border-subtle");
			spacer(.Y, 48);
			sh := label("Streamer Mode", .Medium, 24, cast(T)("--text-strong"), 32);
			appearance_scroll_target(scroll, sh, "Streamer Mode");
			spacer(.Y, 24);
			streamer_settings_section(); // view_streamer.odin
			spacer(.Y, 64);
		}
		filler(.X);
	}
}
#scope_export

