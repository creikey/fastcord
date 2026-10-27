#scope_file

// Server menus and notification controls, like the official 0.0.419 client's:
//   - guild header dropdown (icons on the left): Invite to Server, Create Channel
//     (Manage Channels), Notification Settings (modal), Hide Muted Channels, Leave
//     Server (not the owner). Items that would be dead here (Server Boost, Server
//     Settings, Create Category / Event, App Directory, Privacy Settings, Edit
//     Per-server Profile) are left out. Opening it sends guild_dropdown_menu_viewed.
//   - guild icon context menu (rail right-click): Mark As Read | Invite to Server |
//     Mute Server > durations / Unmute Server, Notification Settings > levels,
//     Hide Muted Channels | Create Channel | Leave Server
//   - Notification Settings modal: "Mute <guild>" switch, server level radios,
//     suppress switches, Done (each control saves at once; Done sends nothing)
//   - Leave Server confirm modal; "Invite friends to <server>" modal
//   - channel header bell menu: Mute / Unmute Channel and the channel's level
//   - sidebar thread row right-click: Mark As Read, Copy Link, Delete Thread
//     (thread owner or Manage Threads; confirm in view_guild_admin.odin)
// Library side (requests, science, store updates): src/discord/guild_settings.odin.

Sub :: enum u8 {
	None;
	Mute;
	Notify;
}

Guild_Menu_State :: struct {
	// header dropdown
	menu_guild: dc.Snowflake;
	menu_anchor: ui.Rect;
	sub: Sub;
	sub_y: float32; // top of the item the submenu hangs from
	// Leave Server confirm
	leave_guild: dc.Snowflake;
	leaving: dc.Snowflake; // DELETE sent: go home when its GUILD_DELETE removes the guild
	// invite modal
	inv_guild: dc.Snowflake;
	inv_channel: dc.Snowflake;
	inv_location: string; // static: dc.INVITE_LOC_*
	inv_tag: u64;
	inv_loading: bool;
	inv_failed: bool;
	inv_copied: bool;
	inv_code: [64]u8;
	inv_code_len: int;
	// channel bell popout
	bell_channel: dc.Snowflake;
	bell_anchor: ui.Rect;
	bell_sub: Sub;
	bell_sub_y: float32;
	// guild icon context menu
	ctx_guild: dc.Snowflake;
	ctx_pos: ui.Vec2;
	ctx_sub: Sub;
	ctx_sub_y: float32;
	// Notification Settings modal
	nm_guild: dc.Snowflake;
	// sidebar thread row menu
	thread_menu: dc.Snowflake;
	thread_pos: ui.Vec2;
}

gm: Guild_Menu_State;
#scope_export

GM_MENU_W :: 220; // header dropdown
GM_CTX_W :: 188; // context menus (guild icon, channel bell)
GM_SUB_W :: 220;
GM_ROW_H :: 32;
GM_HDR_ROW_H :: 36;

guild_menu_toggle :: (gid: dc.Snowflake, anchor: ui.Rect) {
	if gm.menu_guild == gid {
		gm.menu_guild = 0;
		return;
	}
	gm.menu_guild = gid;
	gm.menu_anchor = anchor;
	gm.sub = .None;
	if app.client != null { dc.track_guild_dropdown_viewed(app.client, gid); }
}

// Rail guild icon right-click.
guild_context_open :: (gid: dc.Snowflake, at: ui.Vec2) {
	gm.ctx_guild = gid;
	gm.ctx_pos = at;
	gm.ctx_sub = .None;
}

guild_notify_modal_open :: (gid: dc.Snowflake) {gm.nm_guild = gid;}

// "Hide Muted Channels" (device-local, per guild)
hide_muted_toggle :: (gid: dc.Snowflake) {
	at(*app.view.hide_muted, gid).* = !get(app.view.hide_muted, gid); // saved by settings_frame
}

bell_popout_toggle :: (cid: dc.Snowflake, anchor: ui.Rect) {
	if gm.bell_channel == cid {
		gm.bell_channel = 0;
		return;
	}
	gm.bell_channel = cid;
	gm.bell_anchor = anchor;
	gm.bell_sub = .None;
}
#scope_file

// The channel an invite from the server header points at: the open channel when
// it belongs to the guild, else the first text channel.
invite_channel_for :: (gid: dc.Snowflake) -> dc.Snowflake {
	s := store();
	{ ch := dc.channel_get(s, app.view.channel);
	if ch != null && ch.guild_id == gid && !dc.is_thread(ch) && ch.kind != .Guild_Category { return ch.id; } }
	for id: dc.guild_channels_sorted(s, gid) {
		{ c := dc.channel_get(s, id);
		if c != null && (c.kind == .Guild_Text || c.kind == .Guild_Announcement) { return id; } }
	}
	return 0;
}
#scope_export

// Opens the invite modal and asks for an invite to `cid` (0: the server's default).
// location: the entry point (dc.INVITE_LOC_*), a static string.
invite_open :: (gid: dc.Snowflake, cid: dc.Snowflake, location: string) {
	ch := ifx cid != 0 then cid else invite_channel_for(gid);
	gm.inv_guild = gid;
	gm.inv_channel = ch;
	gm.inv_location = location;
	gm.inv_code_len = 0;
	gm.inv_copied = false;
	gm.inv_failed = false;
	gm.inv_tag += 1;
	gm.inv_loading = false;
	if net_action() {
		gm.inv_loading = ch != 0;
		dc.open_invite_modal(app.client, gid, ch, location, gm.inv_tag);
	}
}

invite_modal_open :: () -> bool {return gm.inv_guild != 0 || gm.leave_guild != 0 || gm.nm_guild != 0;}

invite_receive :: (r: dc.Rest_Result) {
	if r.tag != gm.inv_tag || gm.inv_guild == 0 { return; }
	gm.inv_loading = false;
	code := ifx r.ok then dc.invite_code_for(app.client, r.channel_id) else "";
	if code == "" || len(code) > len(gm.inv_code) {
		gm.inv_failed = true;
	} else {
		copy(view(gm.inv_code), code);
		gm.inv_code_len = len(code);
	}
	app.ui.animating = true;
}
#scope_file

invite_url :: () -> string {
	if gm.inv_code_len == 0 { return ""; }
	return strings.concatenate(string.["https://discord.gg/", as_string(sub(gm.inv_code, 0, gm.inv_code_len))], temp);
}
#scope_export

// Overlay pass entry (views.odin overlays()).
thread_menu_open :: (tid: dc.Snowflake, at: ui.Vec2) {
	gm.thread_menu = tid;
	gm.thread_pos = at;
}

guild_menu_overlays :: () {
	if gm.thread_menu != 0 { thread_menu(); }
	if gm.menu_guild != 0 { guild_menu(); }
	if gm.ctx_guild != 0 { guild_context_menu(); }
	if gm.bell_channel != 0 { bell_popout(); }
	if gm.nm_guild != 0 { notify_modal(); }
	if gm.leaving != 0 && dc.guild_get(store(), gm.leaving) == null {
		// the client routes to Friends once the guild is gone (fixture join_leave_server)
		if app.view.guild == gm.leaving { go_home(); }
		gm.leaving = 0;
	}
	if gm.leave_guild != 0 { leave_modal(); }
	if gm.inv_guild != 0 { invite_modal(); }
}

// ---- shared menu pieces ----

menu_panel :: (id: string, pos: ui.Vec2, w: float32) -> *ui.Box {
	p := ui.box(id, .Draw_Background | .Draw_Border | .Draw_Shadow | .Floating_X | .Floating_Y | .Overlay | .Clickable);
	p.semantic_size = .[ui.px(w), ui.children()];
	p.fixed_pos = pos;
	p.layout_axis = .Y;
	p.style.bg = T("--background-surface-higher");
	p.style.border_color = T("--border-subtle");
	p.style.border = 1;
	p.style.radius = all4(8);
	p.style.shadow_color = .{0, 0, 0, 0.24};
	p.style.shadow_blur = 16;
	p.style.shadow_offset = .{0, 8};
	ui.signal(p);
	return p;
}

Item_Right :: enum u8 {
	None;
	Icon;
	Chevron;
	Radio_Off;
	Radio_On;
	Check_Off;
	Check_On;
}

// One menu row (inside an 8px-padded menu column): label, optional sublabel,
// and an icon / chevron / radio / checkbox on the right.
menu_item :: (id: string, text: string, right: Item_Right = .None, icon_name := "", sub := "", danger := false, brand := false, open := false, disabled := false, lead := "", h: float32 = GM_ROW_H) -> ui.Signal {
	outer := row(id);
	outer.semantic_size = .[ui.pct(1), ui.children()];
	sig: ui.Signal;
	{ ui.parent(outer); defer ui.pop_parent();
		spacer(.X, 8);
		flags := ui.Box_Flags.Clickable | .Draw_Background | .Hot_Animation;
		if disabled { flags |= .Disabled; }
		r := row("it", flags);
		r.semantic_size = .[ui.fill(), ui.px(ifx sub != "" then 44 else h)];
		r.style.radius = all4(4);
		r.style.bg_hot = ifx danger then T("--status-danger") else T("--background-mod-normal");
		if open { r.style.bg = T("--background-mod-normal"); }
		sig = ifx disabled then .{} else ui.signal(r);
		hot := sig.hovering || open;
		color := T("--interactive-text-default");
		if hot { color = T("--interactive-text-active"); }
		if danger { color = ifx hot then .{1, 1, 1, 1} else T("--text-feedback-critical"); }
		if brand && !hot { color = T("--text-brand"); }
		if disabled { color = with_alpha(T("--interactive-text-default"), 0.5); }
		{ ui.parent(r); defer ui.pop_parent();
			spacer(.X, 8);
			if lead != "" {
				icon("lead", lead, 20, color);
				spacer(.X, 8);
			}
			col := ui.box("col");
			col.semantic_size = .[ui.fill(), ui.children()];
			col.layout_axis = .Y;
			{ ui.parent(col); defer ui.pop_parent();
				label(text, .Medium, 14, color, 18);
				if sub != "" { label(sub, .Normal, 12, ifx hot && danger then color else T("--text-muted"), 16); }
			}
			brand_c := T("--background-brand");
			if right == {
			case .None;
			case .Icon;
				icon("ic", icon_name, 18, color);
			case .Chevron;
				icon("ic", "chevron-small-right", 18, color);
			case .Radio_Off; #through; case .Radio_On;
				on := right == .Radio_On;
				rb := ui.box("radio", .Draw_Border);
				rb.semantic_size = .[ui.px(18), ui.px(18)];
				rb.style.radius = all4(9);
				rb.style.border = 2;
				rb.style.border_color = ifx on then brand_c else T("--interactive-icon-default");
				if on { { ui.parent(rb); defer ui.pop_parent();
					dot := ui.box("dot", .Draw_Background | .Floating_X | .Floating_Y);
					dot.semantic_size = .[ui.px(8), ui.px(8)];
					dot.fixed_pos = .{5, 5};
					dot.style.radius = all4(4);
					dot.style.bg = brand_c;
				} }
			case .Check_Off; #through; case .Check_On;
				on := right == .Check_On;
				cb := ui.box("cb", .Draw_Background | .Draw_Border);
				cb.semantic_size = .[ui.px(18), ui.px(18)];
				cb.style.radius = all4(4);
				cb.style.border = ifx on then 0.0 else 1.5;
				cb.style.border_color = T("--interactive-icon-default");
				cb.style.bg = ifx on then brand_c else .{};
				if on { { ui.parent(cb); defer ui.pop_parent(); icon("ck", "checkmark-small-bold", 18, .{1, 1, 1, 1}); } }
			}
			spacer(.X, 8);
		}
		spacer(.X, 8);
	}
	return sig;
}

menu_sep :: (id: string) {
	spacer(.Y, 4);
	r := row(id);
	r.semantic_size = .[ui.pct(1), ui.px(1)];
	{ ui.parent(r); defer ui.pop_parent();
		spacer(.X, 12);
		l := ui.box("l", .Draw_Background);
		l.semantic_size = .[ui.fill(), ui.px(1)];
		l.style.bg = T("--border-subtle");
		spacer(.X, 12);
	}
	spacer(.Y, 4);
}

// Transparent full-window box under a popout: a press outside closes it.
outside_pressed :: (id: string) -> bool {
	scrim := ui.box(id, .Clickable | .Floating_X | .Floating_Y | .Overlay);
	scrim.semantic_size = .[ui.px(app.ui.window.x), ui.px(app.ui.window.y)];
	return ui.signal(scrim).pressed;
}

escape_pressed :: () -> bool {
	// also when the composer took it (it keeps focus under a popout)
	for * e: app.ui.events {
		if e.kind == .Key_Down && e.key == .Escape {
			e.consumed = true;
			return true;
		}
	}
	return false;
}

MUTE_CHOICES := struct {
	text: string;
	seconds: int;
}.[
	.{"For 15 Minutes", 15 * 60},
	.{"For 1 Hour", 3600},
	.{"For 3 Hours", 3 * 3600},
	.{"For 8 Hours", 8 * 3600},
	.{"For 24 Hours", 24 * 3600},
	.{"Until I turn it back on", dc.MUTE_FOREVER}
];

NOTIFY_NAMES := string.["All Messages", "Only @mentions", "Nothing"];
#scope_file

// "Muted until 10/26, 3:23 PM" (local time) or "" for an indefinite mute.
muted_until :: (end_ms: s64) -> string {
	if end_ms == 0 { return ""; }
	local := end_ms + local_offset_ms();
	days := local / 86_400_000;
	if local < 0 { days -= 1; }
	mins := (local - days * 86_400_000) / 60000;
	h := cast(int)(mins / 60);
	m := cast(int)(mins % 60);
	h12 := h % 12;
	if h12 == 0 { h12 = 12; }
	y, mo, d := civil_from_days(days);
	return fmt.tprintf("Muted until %d/%d, %d:%02d %s", mo, d, h12, m, ifx h < 12 then "AM" else "PM");
}

// days since 1970-01-01 -> (year, month 1-12, day 1-31) (H. Hinnant's algorithm)
civil_from_days :: (z_in: s64) -> int, int, int {
	y: int;
	m: int;
	d: int;
	z := z_in + 719468;
	era := (ifx z >= 0 then z else z - 146096) / 146097;
	doe := z - era * 146097;
	yoe := (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
	doy := doe - (365 * yoe + yoe / 4 - yoe / 100);
	mp := (5 * doy + 2) / 153;
	d = cast(int)(doy - (153 * mp + 2) / 5 + 1);
	m = cast(int)(ifx mp < 10 then mp + 3 else mp - 9);
	y = cast(int)(yoe + era * 400 + (ifx m <= 2 then 1 else 0));
	return y, m, d;
}

// Mute duration list; returns the chosen seconds (0 = none).
mute_submenu :: (id: string, pos: ui.Vec2) -> int {
	seconds: int;
	p := menu_panel(id, pos, 220);
	{ ui.parent(p); defer ui.pop_parent();
		spacer(.Y, 8);
		for c: MUTE_CHOICES {
			if menu_item(c.text, c.text).clicked { seconds = c.seconds; }
		}
		spacer(.Y, 8);
	}
	return seconds;
}

// Submenu x: right of the menu, or left of it near the window edge.
sub_x :: (menu: *ui.Box) -> float32 {
	x := menu.rect.x1 + 4;
	if x + GM_SUB_W > app.ui.window.x - 8 { x = menu.rect.x0 - 4 - GM_SUB_W; }
	return x;
}

sub_y :: (y: float32, h: float32) -> float32 {
	return clamp(y - 8, 8, max(8.0, app.ui.window.y - h - 8));
}

// ---- guild header dropdown ----

guild_menu :: () {
	s := store();
	gid := gm.menu_guild;
	g := dc.guild_get(s, gid);
	if g == null || app.view.guild != gid {
		gm.menu_guild = 0;
		return;
	}
	if outside_pressed("gmenu_scrim") || escape_pressed() {
		gm.menu_guild = 0;
		return;
	}
	close := false;
	W :: cast(float32)(GM_MENU_W);
	a := gm.menu_anchor;
	pos := ui.Vec2.{a.x0 + ((a.x1 - a.x0) - W) / 2, a.y1 + 4};
	menu := menu_panel("gmenu", pos, W);
	{ ui.parent(menu); defer ui.pop_parent();
		spacer(.Y, 8);
		if menu_item("invite", "Invite to Server", lead = "user-plus", h = GM_HDR_ROW_H).clicked {
			invite_open(gid, 0, dc.INVITE_LOC_HEADER);
			close = true;
		}
		if can_manage_channels(gid) {
			if menu_item("createchan", "Create Channel", lead = "circle-plus", h = GM_HDR_ROW_H).clicked {
				create_channel_open(gid, 0);
				close = true;
			}
		}
		menu_sep("s1");
		if menu_item("notify", "Notification Settings", lead = "bell", h = GM_HDR_ROW_H).clicked {
			gm.nm_guild = gid;
			close = true;
		}
		menu_sep("s2");
		hide := get(app.view.hide_muted, gid);
		if menu_item("hidemuted", "Hide Muted Channels", ifx hide then .Check_On else .Check_Off, lead = "eye-slash", h = GM_HDR_ROW_H).clicked {
			hide_muted_toggle(gid);
		}
		if g.owner_id != s.me {
			menu_sep("s3");
			if menu_item("leave", "Leave Server", lead = "door-exit", danger = true, h = GM_HDR_ROW_H).clicked {
				gm.leave_guild = gid;
				close = true;
			}
		}
		spacer(.Y, 8);
	}
	if close { gm.menu_guild = 0; }
}

// ---- guild icon context menu (rail) ----

guild_context_menu :: () {
	s := store();
	gid := gm.ctx_guild;
	g := dc.guild_get(s, gid);
	if g == null {
		gm.ctx_guild = 0;
		return;
	}
	if outside_pressed("gctx_scrim") || escape_pressed() {
		gm.ctx_guild = 0;
		return;
	}
	now := wall_ms();
	close := false;
	gs := dc.guild_settings_get(s, gid);
	muted := dc.guild_is_muted(s, gid, now);
	level := dc.guild_notify_level(s, gid);
	W :: cast(float32)(GM_CTX_W);
	// below-right of the pointer, kept inside the window (height from last frame)
	pos := gm.ctx_pos;
	menu := menu_panel("gctx", pos, W);
	h := menu.rect.y1 - menu.rect.y0;
	menu.fixed_pos = .{clamp(pos.x, 8, app.ui.window.x - W - 8), clamp(pos.y, 8, max(8.0, app.ui.window.y - h - 8))};
	hover_sub := Sub.None;
	hover_any := false;
	{ ui.parent(menu); defer ui.pop_parent();
		spacer(.Y, 8);
		{ sig := menu_item("read", "Mark As Read", disabled = !guild_has_unread(gid));
		if sig.clicked {
			if net_action() { dc.ack_guild(app.client, gid); }
			close = true;
		} else if sig.hovering { hover_any = true; } }
		menu_sep("s1");
		{ sig := menu_item("invite", "Invite to Server");
		if sig.clicked {
			// not captured from the rail menu: the header menu's location is the closest known one
			invite_open(gid, 0, dc.INVITE_LOC_HEADER);
			close = true;
		} else if sig.hovering { hover_any = true; } }
		menu_sep("s2");
		if muted {
			end: s64 = ifx gs != null then gs.mute_end_ms else 0;
			{ sig := menu_item("mute", "Unmute Server", sub = muted_until(end));
			if sig.clicked {
				if net_action() { dc.set_guild_muted(app.client, gid, false, now_ms = now); }
				close = true;
			} else if sig.hovering { hover_any = true; } }
		} else {
			it_ := menu_item("mute", "Mute Server", .Chevron, open = gm.ctx_sub == .Mute);
			if it_.hovering { hover_sub = .Mute; }
			if it_.clicked { gm.ctx_sub = .Mute; }
			if it_.hovering || it_.clicked { gm.ctx_sub_y = it_.box.rect.y0; }
		}
		nt := menu_item("notify", "Notification Settings", .Chevron, sub = NOTIFY_NAMES[clamp(level, 0, 2)], open = gm.ctx_sub == .Notify);
		if nt.hovering { hover_sub = .Notify; }
		if nt.clicked { gm.ctx_sub = .Notify; }
		if nt.hovering || nt.clicked { gm.ctx_sub_y = nt.box.rect.y0; }
		hide := get(app.view.hide_muted, gid);
		{ sig := menu_item("hidemuted", "Hide Muted Channels", ifx hide then .Check_On else .Check_Off);
		if sig.clicked {
			hide_muted_toggle(gid);
		} else if sig.hovering { hover_any = true; } }
		if can_manage_channels(gid) {
			menu_sep("s3");
			{ sig := menu_item("createchan", "Create Channel");
			if sig.clicked {
				create_channel_open(gid, 0);
				close = true;
			} else if sig.hovering { hover_any = true; } }
		}
		if g.owner_id != s.me {
			menu_sep("s4");
			{ sig := menu_item("leave", "Leave Server", danger = true);
			if sig.clicked {
				gm.leave_guild = gid;
				close = true;
			} else if sig.hovering { hover_any = true; } }
		}
		spacer(.Y, 8);
	}
	// hovering a submenu row opens it; hovering another row closes it
	if hover_sub != .None && hover_sub != gm.ctx_sub { gm.ctx_sub = hover_sub; }
	if hover_any { gm.ctx_sub = .None; }
	if gm.ctx_sub == {
	case .None;
	case .Mute;
		{ secs := mute_submenu("gmute", .{sub_x(menu), sub_y(gm.ctx_sub_y, 6 * GM_ROW_H + 16)});
		if secs != 0 {
			if net_action() { dc.set_guild_muted(app.client, gid, true, secs, now); }
			close = true;
		} }
	case .Notify;
		p := menu_panel("gnotify", .{sub_x(menu), sub_y(gm.ctx_sub_y, 5 * GM_ROW_H + 25)}, GM_SUB_W);
		{ ui.parent(p); defer ui.pop_parent();
			spacer(.Y, 8);
			for name, i: NOTIFY_NAMES {
				if menu_item(name, name, ifx level == i then .Radio_On else .Radio_Off).clicked && level != i {
					if net_action() { dc.set_guild_notify_level(app.client, gid, i); }
					close = true;
				}
			}
			menu_sep("ns");
			sup := gs != null && gs.suppress_everyone;
			if menu_item("suppress", "Suppress @everyone and @here", ifx sup then .Check_On else .Check_Off).clicked {
				if net_action() { dc.set_guild_suppress_everyone(app.client, gid, !sup); }
			}
			supr := gs != null && gs.suppress_roles;
			if menu_item("suppressroles", "Suppress All Role @mentions", ifx supr then .Check_On else .Check_Off).clicked {
				if net_action() { dc.set_guild_suppress_roles(app.client, gid, !supr); }
			}
			spacer(.Y, 8);
		}
	}
	if close { gm.ctx_guild = 0; }
}

// ---- Notification Settings modal (header menu) ----

notify_modal :: () {
	s := store();
	gid := gm.nm_guild;
	g := dc.guild_get(s, gid);
	if g == null {
		gm.nm_guild = 0;
		return;
	}
	scrim := ui.box("nm_scrim", .Draw_Background | .Clickable | .Floating_X | .Floating_Y | .Overlay);
	scrim.semantic_size = .[ui.px(app.ui.window.x), ui.px(app.ui.window.y)];
	scrim.style.bg = .{0, 0, 0, 0.7};
	if ui.signal(scrim).clicked || escape_pressed() {
		gm.nm_guild = 0;
		return;
	}
	now := wall_ms();
	gs := dc.guild_settings_get(s, gid);
	muted := dc.guild_is_muted(s, gid, now);
	level := dc.guild_notify_level(s, gid);
	W :: 480;
	PAD :: 24;
	d := ui.box("nmodal", .Draw_Background | .Draw_Border | .Floating_X | .Floating_Y | .Overlay | .Clickable);
	d.semantic_size = .[ui.px(W), ui.children()];
	d.fixed_pos = .{(app.ui.window.x - W) / 2, max(8.0, (app.ui.window.y - (d.rect.y1 - d.rect.y0)) / 2)};
	d.style.bg = T("--modal-background");
	d.style.border_color = T("--border-subtle");
	d.style.border = 1;
	d.style.radius = all4(12);
	d.layout_axis = .Y;
	ui.signal(d);
	padded :: (id: string) -> *ui.Box {
		r := row(id);
		r.semantic_size = .[ui.pct(1), ui.children()];
		return r;
	}
	hline :: (id: string) {
		r := row(id);
		r.semantic_size = .[ui.pct(1), ui.px(1)];
		{ ui.parent(r); defer ui.pop_parent();
			spacer(.X, PAD);
			l := ui.box("l", .Draw_Background);
			l.semantic_size = .[ui.fill(), ui.px(1)];
			l.style.bg = T("--border-subtle");
			spacer(.X, PAD);
		}
	}
	{ ui.parent(d); defer ui.pop_parent();
		x := ui.box("close", .Clickable | .Floating_X | .Floating_Y);
		x.semantic_size = .[ui.px(24), ui.px(24)];
		x.fixed_pos = .{W - 16 - 24, 20};
		xs := ui.signal(x);
		set_icon(x, "x-large", ifx xs.hovering then T("--interactive-icon-hover") else T("--interactive-icon-default"));
		if xs.clicked { gm.nm_guild = 0; }
		spacer(.Y, 24);
		{ t := padded("t");
		{ ui.parent(t); defer ui.pop_parent();
			spacer(.X, PAD);
			label("Notification Settings", .Semibold, 20, T("--text-strong"), 24);
		} }
		spacer(.Y, 24);
		hline("h0");
		spacer(.Y, 20);
		{ m := padded("mute");
		{ ui.parent(m); defer ui.pop_parent();
			spacer(.X, PAD);
			c := ui.box("c");
			c.semantic_size = .[ui.fill(), ui.children()];
			{ ui.parent(c); defer ui.pop_parent();
				if set_toggle_row("mutetoggle", ellipsize(fmt.tprintf("Mute %s", g.name), .Medium, 16, W - 2 * PAD - 60), "Muting a server prevents unread indicators and notifications from appearing unless you are mentioned.", muted) {
					if net_action() { dc.set_guild_muted(app.client, gid, !muted, now_ms = now); }
				}
			}
			spacer(.X, PAD);
		} }
		spacer(.Y, 20);
		hline("h1");
		spacer(.Y, 24);
		{ hd := padded("lvlhdr");
		{ ui.parent(hd); defer ui.pop_parent();
			spacer(.X, PAD);
			label("Server Notification Settings", .Semibold, 16, T("--text-strong"), 20);
		} }
		spacer(.Y, 12);
		for name, i: NOTIFY_NAMES {
			{ ui.id_scope(cast(u64)(i + 1)); defer ui.pop_seed();
				r := row("radio", .Clickable);
				r.semantic_size = .[ui.pct(1), ui.px(36)];
				sig := ui.signal(r);
				{ ui.parent(r); defer ui.pop_parent();
					spacer(.X, PAD);
					on := level == i;
					rb := ui.box("rb", .Draw_Border);
					rb.semantic_size = .[ui.px(20), ui.px(20)];
					rb.style.radius = all4(10);
					rb.style.border = 2;
					rb.style.border_color = ifx on then T("--background-brand") else (ifx sig.hovering then T("--interactive-icon-hover") else T("--interactive-icon-default"));
					if on { { ui.parent(rb); defer ui.pop_parent();
						dot := ui.box("dot", .Draw_Background | .Floating_X | .Floating_Y);
						dot.semantic_size = .[ui.px(10), ui.px(10)];
						dot.fixed_pos = .{5, 5};
						dot.style.radius = all4(5);
						dot.style.bg = T("--background-brand");
					} }
					spacer(.X, 12);
					label(name, .Medium, 16, ifx on || sig.hovering then T("--text-strong") else T("--text-default"), 20);
				}
				if sig.clicked && level != i && net_action() { dc.set_guild_notify_level(app.client, gid, i); }
			}
		}
		spacer(.Y, 20);
		hline("h2");
		spacer(.Y, 20);
		sup := gs != null && gs.suppress_everyone;
		supr := gs != null && gs.suppress_roles;
		{ r := padded("sup");
		{ ui.parent(r); defer ui.pop_parent();
			spacer(.X, PAD);
			c := ui.box("c");
			c.semantic_size = .[ui.fill(), ui.children()];
			c.layout_axis = .Y;
			{ ui.parent(c); defer ui.pop_parent();
				if set_toggle_row("supall", "Suppress @everyone and @here", "", sup) && net_action() { dc.set_guild_suppress_everyone(app.client, gid, !sup); }
				spacer(.Y, 16);
				if set_toggle_row("suproles", "Suppress All Role @mentions", "", supr) && net_action() { dc.set_guild_suppress_roles(app.client, gid, !supr); }
			}
			spacer(.X, PAD);
		} }
		spacer(.Y, 24);
		{ br := padded("done");
		{ ui.parent(br); defer ui.pop_parent();
			spacer(.X, PAD);
			done := ui.box("Done##done", .Clickable | .Draw_Background | .Draw_Text | .Hot_Animation);
			done.semantic_size = .[ui.fill(), ui.px(40)];
			done.style.radius = all4(8);
			done.style.font = F(.Medium);
			done.style.font_size = 16;
			done.style.text_align = .Center;
			done.style.text_color = .{1, 1, 1, 1};
			done.style.bg = T("--background-brand");
			done.style.bg_hot = with_alpha(T("--background-brand"), 0.85);
			if ui.signal(done).clicked { gm.nm_guild = 0; }
			spacer(.X, PAD);
		} }
		spacer(.Y, PAD);
	}
}

// ---- Leave Server confirm ----

leave_modal :: () {
	gid := gm.leave_guild;
	g := dc.guild_get(store(), gid);
	if g == null {
		gm.leave_guild = 0;
		return;
	}
	scrim := ui.box("leave_scrim", .Draw_Background | .Clickable | .Floating_X | .Floating_Y | .Overlay);
	scrim.semantic_size = .[ui.px(app.ui.window.x), ui.px(app.ui.window.y)];
	scrim.style.bg = .{0, 0, 0, 0.7};
	if ui.signal(scrim).clicked || escape_pressed() {
		gm.leave_guild = 0;
		return;
	}
	W :: 480;
	PAD :: 24;
	confirm := false;
	d := ui.box("leavemodal", .Draw_Background | .Draw_Border | .Floating_X | .Floating_Y | .Overlay | .Clickable);
	d.semantic_size = .[ui.px(W), ui.children()];
	d.fixed_pos = .{(app.ui.window.x - W) / 2, (app.ui.window.y - (d.rect.y1 - d.rect.y0)) / 2};
	d.style.bg = T("--modal-background");
	d.style.border_color = T("--border-subtle");
	d.style.border = 1;
	d.style.radius = all4(12);
	d.layout_axis = .Y;
	ui.signal(d);
	{ ui.parent(d); defer ui.pop_parent();
		x := ui.box("close", .Clickable | .Floating_X | .Floating_Y);
		x.semantic_size = .[ui.px(24), ui.px(24)];
		x.fixed_pos = .{W - 17 - 24, 17};
		xs := ui.signal(x);
		set_icon(x, "x-large", ifx xs.hovering then T("--interactive-icon-hover") else T("--interactive-icon-default"));
		if xs.clicked { gm.leave_guild = 0; }
		spacer(.Y, PAD + 1);
		t := row("t");
		t.semantic_size = .[ui.pct(1), ui.px(24)];
		{ ui.parent(t); defer ui.pop_parent();
			spacer(.X, PAD + 1);
			label(ellipsize(fmt.tprintf("Leave '%s'", g.name), .Semibold, 20, W - 2 * PAD - 40), .Semibold, 20, T("--text-strong"), 24);
		}
		spacer(.Y, 8);
		br := row("body");
		br.semantic_size = .[ui.pct(1), ui.children()];
		{ ui.parent(br); defer ui.pop_parent();
			spacer(.X, PAD + 1);
			b := ui.box("text", .Wrap_Text);
			b.semantic_size = .[ui.fill(), ui.text_size()];
			b.style.line_height = 20;
			b.style.text_color = T("--text-subtle");
			spans := make_slice(ui.Span, 3, temp);
			spans[0] = .{text = "Are you sure you want to leave ", font = F(.Normal), size = 16};
			spans[1] = .{text = g.name, font = F(.Bold), size = 16};
			spans[2] = .{text = "? You won't be able to rejoin this server unless you are re-invited.", font = F(.Normal), size = 16};
			ui.set_spans(b, spans);
			spacer(.X, PAD + 1);
		}
		spacer(.Y, 24);
		btns := row("btns");
		btns.semantic_size = .[ui.pct(1), ui.px(40)];
		btns.style.child_gap = 8;
		{ ui.parent(btns); defer ui.pop_parent();
			spacer(.X, PAD + 1 - 8);
			cancel := ui.box("Cancel##c", .Clickable | .Draw_Background | .Draw_Text | .Hot_Animation);
			cancel.semantic_size = .[ui.fill(), ui.px(40)];
			cancel.style.radius = all4(8);
			cancel.style.font = F(.Medium);
			cancel.style.font_size = 16;
			cancel.style.text_align = .Center;
			cancel.style.text_color = T("--text-strong");
			cancel.style.bg = T("--background-mod-normal");
			cancel.style.bg_hot = T("--background-mod-strong");
			if ui.signal(cancel).clicked { gm.leave_guild = 0; }
			ok := ui.box("Leave Server##l", .Clickable | .Draw_Background | .Draw_Text | .Hot_Animation);
			ok.semantic_size = .[ui.fill(), ui.px(40)];
			ok.style.radius = all4(8);
			ok.style.font = F(.Medium);
			ok.style.font_size = 16;
			ok.style.text_align = .Center;
			ok.style.text_color = .{1, 1, 1, 1};
			ok.style.bg = T("--status-danger");
			ok.style.bg_hot = T("--control-critical-primary-background-hover");
			if ui.signal(ok).clicked { confirm = true; }
			spacer(.X, PAD + 1 - 8);
		}
		spacer(.Y, PAD + 1);
	}
	if confirm {
		gm.leave_guild = 0;
		if net_action() {
			dc.leave_guild(app.client, gid);
			gm.leaving = gid;
		}
	}
}

// ---- invite modal ----

invite_modal :: () {
	s := store();
	g := dc.guild_get(s, gm.inv_guild);
	if g == null {
		gm.inv_guild = 0;
		return;
	}
	scrim := ui.box("inv_scrim", .Draw_Background | .Clickable | .Floating_X | .Floating_Y | .Overlay);
	scrim.semantic_size = .[ui.px(app.ui.window.x), ui.px(app.ui.window.y)];
	scrim.style.bg = .{0, 0, 0, 0.7};
	esc := escape_pressed();
	if ui.signal(scrim).clicked || esc {
		if esc && app.client != null { dc.escape_shortcut_used(app.client); }
		gm.inv_guild = 0;
		return;
	}
	W :: 440;
	PAD :: 16;
	d := ui.box("invmodal", .Draw_Background | .Draw_Border | .Floating_X | .Floating_Y | .Overlay | .Clickable);
	d.semantic_size = .[ui.px(W), ui.children()];
	d.fixed_pos = .{(app.ui.window.x - W) / 2, (app.ui.window.y - (d.rect.y1 - d.rect.y0)) / 2};
	d.style.bg = T("--modal-background");
	d.style.border_color = T("--border-subtle");
	d.style.border = 1;
	d.style.radius = all4(12);
	d.layout_axis = .Y;
	ui.signal(d);
	{ ui.parent(d); defer ui.pop_parent();
		x := ui.box("close", .Clickable | .Floating_X | .Floating_Y);
		x.semantic_size = .[ui.px(24), ui.px(24)];
		x.fixed_pos = .{W - 12 - 24, 12};
		xs := ui.signal(x);
		set_icon(x, "x-large", ifx xs.hovering then T("--interactive-icon-hover") else T("--interactive-icon-default"));
		if xs.clicked { gm.inv_guild = 0; }
		spacer(.Y, 16);
		t := row("t");
		t.semantic_size = .[ui.pct(1), ui.px(24)];
		{ ui.parent(t); defer ui.pop_parent();
			spacer(.X, PAD);
			label(ellipsize(fmt.tprintf("Invite friends to %s", g.name), .Semibold, 20, W - 2 * PAD - 32), .Semibold, 20, T("--text-strong"), 24);
		}
		{ ch := dc.channel_get(s, gm.inv_channel);
		if ch != null {
			spacer(.Y, 4);
			cr := row("chan");
			cr.semantic_size = .[ui.pct(1), ui.px(20)];
			{ ui.parent(cr); defer ui.pop_parent();
				spacer(.X, PAD);
				icon("ic", channel_icon_name(ch), 16, T("--text-muted"));
				spacer(.X, 4);
				label(ch.name, .Medium, 14, T("--text-muted"), 18);
			}
		} }
		spacer(.Y, 20);
		lr := row("lbl");
		lr.semantic_size = .[ui.pct(1), ui.px(18)];
		{ ui.parent(lr); defer ui.pop_parent();
			spacer(.X, PAD);
			label("Send a server invite link to a friend", .Semibold, 14, T("--text-default"), 18);
		}
		spacer(.Y, 8);
		fr := row("fieldrow");
		fr.semantic_size = .[ui.pct(1), ui.px(44)];
		{ ui.parent(fr); defer ui.pop_parent();
			spacer(.X, PAD);
			field := row("field", .Draw_Background | .Draw_Border);
			field.semantic_size = .[ui.fill(), ui.px(44)];
			field.style.bg = T("--input-background-default");
			field.style.border_color = T("--input-border-default");
			field.style.border = 1;
			field.style.radius = all4(8);
			{ ui.parent(field); defer ui.pop_parent();
				spacer(.X, 12);
				url := invite_url();
				text, color := url, T("--text-default");
				// Streamer Mode > Hide Invite Links: the code is masked, Copy still copies it
				if url != "" && streamer_hide_invites() { text = "https://discord.gg/••••••••"; }
				if url == "" {
					color = T("--text-muted");
					text = "Creating an invite link…";
					if gm.inv_failed { text = "Couldn't create an invite link."; } else if !gm.inv_loading { text = "You're offline: no invite link."; }
				}
				tw := ui.box("tw", .Clip);
				tw.semantic_size = .[ui.fill(), ui.px(20)];
				{ ui.parent(tw); defer ui.pop_parent(); label(text, .Normal, 16, color, 20); }
				flags := ui.Box_Flags.Clickable | .Draw_Background | .Draw_Text | .Hot_Animation;
				if url == "" { flags |= .Disabled; }
				cb := ui.box(ifx gm.inv_copied then "Copied##copy" else "Copy##copy", flags);
				cb.semantic_size = .[ui.px(75), ui.px(32)];
				cb.style.radius = all4(8);
				cb.style.font = F(.Medium);
				cb.style.font_size = 14;
				cb.style.text_align = .Center;
				cb.style.text_color = .{1, 1, 1, ifx url == "" then 0.5 else 1};
				cb.style.bg = ifx gm.inv_copied then T("--status-positive") else T("--background-brand");
				cb.style.bg_hot = ifx gm.inv_copied then cb.style.bg else with_alpha(T("--background-brand"), 0.85);
				if url == "" { cb.style.bg = with_alpha(cb.style.bg, 0.5); }
				if url != "" && ui.signal(cb).clicked {
					clipboard_set(url);
					gm.inv_copied = true;
					if app.client != null { dc.invite_copied(app.client, gm.inv_guild, gm.inv_channel, as_string(sub(gm.inv_code, 0, gm.inv_code_len)), gm.inv_location); }
				}
				spacer(.X, 6);
			}
			spacer(.X, PAD);
		}
		spacer(.Y, 8);
		ft := row("foot");
		ft.semantic_size = .[ui.pct(1), ui.px(16)];
		{ ui.parent(ft); defer ui.pop_parent();
			spacer(.X, PAD);
			label("Your invite link expires in 30 days.", .Normal, 12, T("--text-muted"), 16);
		}
		spacer(.Y, 20);
	}
}

// ---- channel header bell popout ----

bell_popout :: () {
	s := store();
	cid := gm.bell_channel;
	ch := dc.channel_get(s, cid);
	if ch == null || cid != app.view.channel || ch.guild_id == 0 {
		gm.bell_channel = 0;
		return;
	}
	if outside_pressed("bell_scrim") || escape_pressed() {
		gm.bell_channel = 0;
		return;
	}
	gid := ch.guild_id;
	now := wall_ms();
	close := false;
	muted := dc.channel_is_muted(s, gid, cid, now);
	level := dc.channel_notify_level(s, gid, cid);
	// what "default" resolves to: the category's override, else the server's level
	def := dc.guild_notify_level(s, gid);
	has_cat := ch.parent_id != 0;
	if has_cat {
		{ cl := dc.channel_notify_level(s, gid, ch.parent_id);
		if cl != dc.NOTIFY_INHERIT { def = cl; } }
	}
	W :: cast(float32)(GM_CTX_W);
	a := gm.bell_anchor;
	pos := ui.Vec2.{clamp(a.x1 - W, 8, app.ui.window.x - W - 8), a.y1 + 8};
	menu := menu_panel("bell", pos, W);
	hover_any := false;
	hover_mute := false;
	{ ui.parent(menu); defer ui.pop_parent();
		spacer(.Y, 8);
		if muted {
			end: s64;
			{ o := dc.channel_override_get(s, gid, cid);
			if o != null { end = o.mute_end_ms; } }
			{ sig := menu_item("mute", "Unmute Channel", sub = muted_until(end));
			if sig.clicked {
				if net_action() { dc.set_channel_muted(app.client, gid, cid, false, now_ms = now); }
				close = true;
			} else if sig.hovering { hover_any = true; } }
		} else {
			it_ := menu_item("mute", "Mute Channel", .Chevron, open = gm.bell_sub == .Mute);
			if it_.hovering { hover_mute = true; }
			if it_.clicked { gm.bell_sub = .Mute; }
			if it_.hovering || it_.clicked { gm.bell_sub_y = it_.box.rect.y0; }
		}
		menu_sep("s1");
		def_text := ifx has_cat then "Use Category Default" else "Use Server Default";
		{ sig := menu_item("default", def_text, ifx level == dc.NOTIFY_INHERIT then .Radio_On else .Radio_Off, sub = NOTIFY_NAMES[clamp(def, 0, 2)]);
		if sig.clicked {
			if level != dc.NOTIFY_INHERIT && net_action() { dc.set_channel_notify_level(app.client, gid, cid, dc.NOTIFY_INHERIT); }
			close = level != dc.NOTIFY_INHERIT;
		} else if sig.hovering { hover_any = true; } }
		for name, i: NOTIFY_NAMES {
			{ sig := menu_item(name, name, ifx level == i then .Radio_On else .Radio_Off);
			if sig.clicked {
				if level != i && net_action() { dc.set_channel_notify_level(app.client, gid, cid, i); }
				close = level != i;
			} else if sig.hovering { hover_any = true; } }
		}
		spacer(.Y, 8);
	}
	if hover_mute { gm.bell_sub = .Mute; }
	if hover_any { gm.bell_sub = .None; }
	if gm.bell_sub == .Mute {
		{ secs := mute_submenu("bmute", .{sub_x(menu), sub_y(gm.bell_sub_y, 6 * GM_ROW_H + 16)});
		if secs != 0 {
			if net_action() { dc.set_channel_muted(app.client, gid, cid, true, secs, now); }
			close = true;
		} }
	}
	if close { gm.bell_channel = 0; }
}
#scope_export

// The bell icon for a channel header: crossed out while the channel is muted.
bell_icon_name :: (ch: *dc.Channel) -> string {
	return ifx dc.channel_is_muted(store(), ch.guild_id, ch.id, wall_ms()) then "bell-slash" else "bell";
}

guild_menu_reset_for_test :: () {gm = .{};}
guild_menu_state_for_test :: () -> string {
	return fmt.tprint(gm.menu_guild, gm.sub, gm.leave_guild, gm.leaving, gm.inv_guild, gm.inv_copied, gm.bell_channel, gm.bell_sub, gm.ctx_guild, gm.ctx_sub, gm.nm_guild, app.view.hide_muted);
}

// ---- sidebar thread row menu ----

can_delete_thread :: (th: *dc.Channel) -> bool {
	if th == null || !dc.is_thread(th) { return false; }
	if th.owner_id == store().me { return true; }
	return (dc.channel_permissions(store(), th.id) & dc.PERM_MANAGE_THREADS) != 0;
}
#scope_file

thread_menu :: () {
	s := store();
	th := dc.channel_get(s, gm.thread_menu);
	if th == null || outside_pressed("tmenu_scrim") || escape_pressed() {
		gm.thread_menu = 0;
		return;
	}
	W :: cast(float32)(GM_MENU_W);
	pos := gm.thread_pos;
	if pos.x + W > app.ui.window.x - 8 { pos.x = app.ui.window.x - 8 - W; }
	if pos.y + 150 > app.ui.window.y - 8 { pos.y = app.ui.window.y - 8 - 150; }
	close := false;
	menu := menu_panel("tmenu", pos, W);
	{ ui.parent(menu); defer ui.pop_parent();
		spacer(.Y, 8);
		if dc.channel_unread(s, th.id) {
			if menu_item("read", "Mark As Read").clicked {
				if net_action() { dc.ack_message(app.client, th.id, th.last_message_id, true); }
				close = true;
			}
			menu_sep("s1");
		}
		if menu_item("link", "Copy Link", .Icon, "link").clicked {
			clipboard_set(fmt.tprintf("https://discord.com/channels/%d/%d", cast(u64)(th.guild_id), cast(u64)(th.id)));
			close = true;
		}
		if can_delete_thread(th) {
			menu_sep("s2");
			if menu_item("delete", "Delete Thread", .Icon, "trash", danger = true).clicked {
				thread_delete_open(th);
				close = true;
			}
		}
		spacer(.Y, 8);
	}
	if close { gm.thread_menu = 0; }
}
#scope_export

