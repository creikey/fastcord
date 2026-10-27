// Layout constants measured from the official client (tools/probes/layout_geometry.js).
TITLE_BAR_H :: 33;
HEADER_TOOL_W :: 40; // channel header icon buttons (20px icons on a 40px pitch)
SEARCH_W :: 244; // header search box (official 1028..1272 at 1280 wide)
TITLE_SIDE_W :: 140; // back/forward on the left, inbox/help on the right
RAIL_W :: 72;
SIDEBAR_W :: 303; // default width, includes the 1px left border
// The official client clamps --custom-guild-sidebar-width (rail included) to 264..432 while dragging.
SIDEBAR_MIN_W :: 264 - RAIL_W;
SIDEBAR_MAX_W :: 432 - RAIL_W;
HEADER_H :: 49;
CHANNEL_ROW_H :: 32;
CHANNEL_ROW_PITCH :: 34;
CATEGORY_GAP :: 16;
CATEGORY_ROW_H :: 24;
GUILD_ICON :: 40;
USER_PANEL_H :: 58;
MEMBER_LIST_W :: 264; // default width (--custom-member-list-width), plus the 1px left border
MEMBER_LIST_MIN_W :: 224; // guesses: the official member list is not resizable
MEMBER_LIST_MAX_W :: 400;
CHAT_MIN_W :: 480; // narrower than this, the member list / profile column hides

Friends_Tab :: enum u8 {
	Online;
	All;
	Pending;
	Add_Friend;
}

View_State :: struct {
	guild: dc.Snowflake; // 0 = home (friends / DMs)
	channel: dc.Snowflake; // selected channel in the current guild, or DM channel at home
	last_channel: Table(dc.Snowflake, dc.Snowflake); // guild -> last selected channel
	friends_tab: Friends_Tab;
	collapsed: Table(dc.Snowflake, bool); // collapsed categories
	hide_muted: Table(dc.Snowflake, bool); // guild -> "Hide Muted Channels" (device-local)
	show_members: bool;
	hide_dm_profile: bool; // 1:1 DM user profile column (header toggle)
	add_friend: ui.Editor;
	friends_search: ui.Editor; // Friends page search (filters the list)
	token_input: ui.Editor;
	back, fwd: [..][2]dc.Snowflake; // title-bar history: {guild, channel} places left / gone back from
	sidebar_w, member_w: float32; // dragged column widths (persisted; 0 = default)
	resizing: bool; // a column edge is being dragged
	resize_from: float32;
}

view_init :: (v: *View_State) {
	v.friends_tab = .Online;
	v.show_members = true;
	if v.sidebar_w == 0 v.sidebar_w = SIDEBAR_W;
	if v.member_w == 0 v.member_w = MEMBER_LIST_W;
}

// Drag handle on a column's edge, a floating child of the column at x (official
// .sidebarResizeHandle: 4px wide, ew-resize, --background-mod-strong while hovered or dragged).
// Dragging sets width (clamped, whole points); returns true when the drag ends.
resize_handle :: (id: string, x: float32, width: *float32, lo: float32, hi: float32, grows_left := false) -> bool {
	b := ui.box(id, .Clickable | .Floating_X | .Floating_Y | .Draw_Background | .Hot_Animation | .Active_Animation);
	b.semantic_size = .[ui.px(4), ui.pct(1)];
	b.fixed_pos = .{x, 0};
	b.hover_cursor = .Resize_H;
	strong := T("--background-mod-strong");
	b.style.bg = with_alpha(strong, 0);
	b.style.bg_hot = strong;
	b.style.bg_active = strong;
	sig := ui.signal(b);
	if sig.pressed app.view.resize_from = width.*;
	if sig.dragging {
		d := ifx grows_left then -sig.drag_delta.x else sig.drag_delta.x;
		width.* = clamp(floor(app.view.resize_from + d + 0.5), lo, hi);
		app.view.resizing = true;
	}
	if sig.released app.view.resizing = false;
	return sig.released;
}


// Shortcut modifier: Cmd on macOS, Ctrl elsewhere.
PRIMARY_MOD :: #run ifx OS == .MACOS then ui.Mod.Cmd else ui.Mod.Ctrl;

store :: () -> *dc.Store {
	if app.client != null { return *app.client.store; }
	return *app.offline_store;
}

T :: (name: string) -> ui.Color {return tok(*app.theme, name);}

with_alpha :: (c: ui.Color, a: float32) -> ui.Color {return .{c.x, c.y, c.z, c.w * a};}

sized :: (id: string, w: float32, h: float32, flags: ui.Box_Flags = 0) -> *ui.Box {
	b := ui.box(id, flags);
	b.semantic_size = .[ui.px(w), ui.px(h)];
	return b;
}

row :: (id: string, flags: ui.Box_Flags = 0) -> *ui.Box {
	b := ui.box(id, flags);
	b.layout_axis = .X;
	b.cross_align = .Center;
	return b;
}

spacer :: (axis: ui.Axis, v: float32) {
	b := ui.box("");
	b.semantic_size[axis] = ui.px(v);
	b.semantic_size[ifx axis == .X then ui.Axis.Y else .X] = ui.px(0);
}

filler :: (axis: ui.Axis) {
	b := ui.box("");
	b.semantic_size[axis] = ui.fill();
	b.semantic_size[ifx axis == .X then ui.Axis.Y else .X] = ui.px(0);
}

// text cut with "…" to fit max_w (single line).
ellipsize :: (text: string, font: Font_Id, size: float32, max_w: float32) -> string {
	tl := ui.layout_text(F(font), size, text, -1);
	if tl.width <= max_w { return text; }
	dots := ui.layout_text(F(font), size, "…", -1).width;
	cut := 0;
	for g: tl.run.glyphs {
		if g.x + g.advance + dots > max_w { break; }
		cut = g.cluster_end;
	}
	kept := text;
	kept.count = cut;
	return join(trim_right(kept), "…",, temp);
}

label :: (text: string, font: Font_Id, size: float32, color: ui.Color, line_h: float32 = 0) -> *ui.Box {
	st := ui.st();
	saved := st.*;
	st.font = F(font);
	st.font_size = size;
	st.text_color = color;
	st.line_height = line_h;
	b := ui.box(text, .Draw_Text);
	b.semantic_size = .[ui.text_size(0, 0), ui.text_size()];
	st.* = saved;
	return b;
}

go_home :: () {
	_, ch := table_find(*app.view.last_channel, 0);
	select_channel(0, ch);
}

select_guild :: (gid: dc.Snowflake) {
	_, ch := table_find(*app.view.last_channel, gid);
	if ch == 0 {
		for id: dc.guild_channels_sorted(store(), gid) {
			c := dc.channel_get(store(), id);
			if c != null && (c.kind == .Guild_Text || c.kind == .Guild_Announcement) {
				ch = id;
				break;
			}
		}
	}
	select_channel(gid, ch);
}

// source: where the route change came from, as channel_opened reports it ("Thread Browser").
select_channel :: (gid: dc.Snowflake, cid: dc.Snowflake, source := "") {
	if gid != app.view.guild || cid != app.view.channel {
		history_push(*app.view.back, .[app.view.guild, app.view.channel]);
		array_reset_keeping_memory(*app.view.fwd);
	}
	go_to(gid, cid, source);
}

HISTORY_MAX :: 50;

// Back / forward (title bar arrows "Go back" / "Go forward", Cmd/Ctrl+[ and ]):
// places whose guild or channel no longer exists are skipped. The move is a
// normal route change (same requests as opening that place); science
// keyboard_shortcut_used (keys only) and app_back_forward_navigated (fixture history_nav).
history_step :: (forward: bool, keybind := false) {
	from, to := *app.view.back, *app.view.fwd;
	if forward { from, to = to, from; }
	while from.count > 0 {
		place := pop(from);
		if place[0] != 0 && dc.guild_get(store(), place[0]) == null { continue; }
		if place[1] != 0 && dc.channel_get(store(), place[1]) == null { continue; }
		history_push(to, .[app.view.guild, app.view.channel]);
		if app.client != null { dc.track_back_forward(app.client, forward, keybind); }
		go_to(place[0], place[1]);
		return;
	}
}

build_ui :: () {
	root := ui.top_parent();
	root.layout_axis = .Y;
	app.ui.scrollbar_thin_thumb = T("--scrollbar-thin-thumb");
	app.ui.scrollbar_auto_thumb = T("--scrollbar-auto-thumb");
	app.ui.scrollbar_auto_track = T("--scrollbar-auto-track");
	if app.needs_login {
		login_view();
		return;
	}
	prof.zone("app.build_ui");
	title_bar();
	streamer_notice();
	body := row("body");
	body.semantic_size = .[ui.pct(1), ui.fill()];
	body.cross_align = .Start;
	{ ui.parent(body); defer ui.pop_parent();
		{
			prof.zone("app.rail");
			rail_view(); // view_rail_folders.jai (folders, badges, DM unreads, drag)
		}
		{
			prof.zone("app.sidebar");
			sidebar();
		}
		{
			prof.zone("app.page");
			page();
		}
	}
	user_panel();
	{
		prof.zone("app.overlays");
		overlays();
	}
	if app.view.resizing app.ui.cursor = .Resize_H; // also off the handle while dragging
}

title_bar :: () {
	b := row("titlebar");
	b.semantic_size = .[ui.pct(1), ui.px(TITLE_BAR_H)];
	{ ui.parent(b); defer ui.pop_parent();
		// equal-width sides keep the title centered on the window
		left := row("left");
		left.semantic_size = .[ui.px(TITLE_SIDE_W), ui.pct(1)];
		{ ui.parent(left); defer ui.pop_parent();
			spacer(.X, 85);
			for fwd: (bool.[false, true]) {
				n := ifx fwd then app.view.fwd.count else app.view.back.count;
				nb := ui.box(ifx fwd then "fwd" else "back", ifx n > 0 then ui.Box_Flag.Clickable else 0);
				nb.semantic_size = .[ui.px(24), ui.px(24)];
				nb.layout_axis = .X;
				nb.cross_align = .Center;
				sig := ui.signal(nb);
				c := T("--interactive-icon-default");
				if n == 0 { c = with_alpha(c, 0.3); } else if sig.hovering { c = T("--interactive-icon-hover"); }
				{ ui.parent(nb); defer ui.pop_parent();
					spacer(.X, 3);
					icon("i", ifx fwd then "arrow-large-right" else "arrow-large-left", 18, c);
				}
				if sig.hovering { tooltip_below(ifx fwd then "Go forward" else "Go back", nb.rect); }
				if sig.clicked { history_step(fwd); }
			}
		}
		for * e: app.ui.events {
			if e.consumed || e.kind != .Key_Down || e.mods != PRIMARY_MOD { continue; }
			if e.key == .Left_Bracket || e.key == .Right_Bracket {
				history_step(e.key == .Right_Bracket, keybind = true);
				e.consumed = true;
			}
		}
		filler(.X);
		title := "Friends";
		glyph := "friends";
		g: *dc.Guild;
		if app.view.guild != 0 {
			g = dc.guild_get(store(), app.view.guild);
			if g != null { title = g.name; }
		} else if app.view.channel != 0 {
			title, glyph = "Direct Messages", "logo";
		}
		if g != null {
			gi := ui.box("gicon", .Draw_Background | .Draw_Text);
			gi.semantic_size = .[ui.px(16), ui.px(16)];
			gi.style.radius = all4(4);
			gi.style.bg = T("--background-mod-subtle");
			gi.style.text_color = T("--text-default");
			gi.style.text_align = .Center;
			gi.style.font = F(.Medium);
			gi.style.font_size = 6;
			gi.text = guild_initials(g.name);
			if g.icon != "" {
				set_remote_image(gi, dc.guild_icon_url(g.id, g.icon, 32));
				gi.text = "";
			}
		} else {
			icon("gicon", glyph, 16, T("--text-default"));
		}
		spacer(.X, 8);
		label(title, .Medium, 14, T("--text-default"), 18);
		filler(.X);
		update_button();
		right := row("right");
		right.semantic_size = .[ui.px(TITLE_SIDE_W), ui.pct(1)];
		{ ui.parent(right); defer ui.pop_parent();
			filler(.X);
			inbox_button(); // view_inbox.jai
			spacer(.X, 16);
			help_button();
			spacer(.X, 14);
		}
	}
}

// Guilds in sidebar order, like the client: guilds missing from
// settings.guild_folders first (newest join first), then the folders flattened.
guild_order :: () -> []dc.Snowflake {
	s := store();
	out: [..]dc.Snowflake;
	out.allocator = temp;
	seen: Table(dc.Snowflake, bool);
	seen.allocator = temp;
	for f: s.settings.guild_folders {
		for f.guild_ids table_set(*seen, it, true);
	}
	Joined :: struct {
		at: string;
		id: dc.Snowflake;
	}
	loose: [..]Joined;
	loose.allocator = temp;
	for id: s.guild_order {
		g := table_find_pointer(*s.guilds, id);
		if g && !table_contains(*seen, id) { array_add(*loose, .{g.joined_at, id}); }
	}
	quick_sort(loose, (a: Joined, b: Joined) -> int {
		if a.at != b.at { return compare(b.at, a.at); }
		return ifx a.id > b.id then -1 else ifx a.id < b.id then 1 else 0;
	});
	for loose array_add(*out, it.id);
	table_reset_keeping_memory(*seen);
	for out table_set(*seen, it, true);
	for f: s.settings.guild_folders {
		for id: f.guild_ids {
			if table_contains(*s.guilds, id) && !table_contains(*seen, id) {
				array_add(*out, id);
				table_set(*seen, id, true);
			}
		}
	}
	return out;
}

// The first byte of each space-separated word, at most 5.
guild_initials :: (name: string) -> string {
	out := talloc_string(5);
	out.count = 0;
	for i: 0..name.count-1 {
		if is_space(name[i]) || (i > 0 && !is_space(name[i-1])) { continue; }
		out.data[out.count] = name[i];
		out.count += 1;
		if out.count >= 5 { break; }
	}
	return out;
}

// One 72x48 rail slot: unread/selection pill on the left edge and a 40x40 squircle.
rail_item :: (id: string, selected: bool, text: string, icon_name: string, guild_id: dc.Snowflake) -> ui.Signal {
	slot := ui.box(id);
	slot.semantic_size = .[ui.pct(1), ui.px(GUILD_ICON + 8)];
	sig: ui.Signal;
	if ui.offscreen(slot) { return sig; } // box nil: the caller skips its own additions too
	{ ui.parent(slot); defer ui.pop_parent();
		pill := ui.box("pill", .Draw_Background | .Floating_X | .Floating_Y);
		ic := ui.box("icon", .Clickable | .Draw_Background | .Floating_X | .Floating_Y | .Draw_Text | .Hot_Animation);
		ic.semantic_size = .[ui.px(GUILD_ICON), ui.px(GUILD_ICON)];
		ic.fixed_pos = .{16, 0};
		ic.style.radius = all4(12);
		ic.style.text_align = .Center;
		ic.style.font = F(.Medium);
		ic.style.font_size = guild_acronym_size(text.count);
		ic.text = text;
		sig = ui.signal(ic);
		unread := guild_id != 0 && guild_unread_shown(guild_id);
		target: float32 = ifx selected then 40 else (ifx sig.hovering then 20 else (ifx unread then 8.0 else 0.0));
		ui.animate(*pill.user_t, target, 25);
		h := pill.user_t;
		pill.semantic_size = .[ui.px(4), ui.px(h)];
		pill.fixed_pos = .{0, (GUILD_ICON - h) / 2};
		pill.style.bg = T("--text-strong");
		pill.style.radius = .[0, 4, 0, 4];
		if h < 0.5 { pill.flags &= ~ui.Box_Flag.Draw_Background; }

		if id == {
		case "home";
			ic.style.bg = ifx selected then T("--background-brand") else T("--background-mod-subtle");
			ic.style.bg_hot = T("--background-brand");
		case "add"; #through; case "discover";
			ic.style.bg = T("--background-mod-subtle");
			ic.style.bg_hot = ifx id == "add" then T("--background-brand") else T("--status-positive");
		case;
			ic.style.bg = ifx selected then T("--background-brand") else T("--background-mod-subtle");
			ic.style.bg_hot = ifx selected then ic.style.bg else T("--background-brand");
			g := dc.guild_get(store(), guild_id);
			if g != null && g.icon != "" {
				set_remote_image(ic, dc.guild_icon_url(guild_id, g.icon, 96));
				ic.text = "";
			}
		}
		ic.style.text_color = T("--text-default");
		if icon_name != "" {
			ic.layout_axis = .X;
			ic.cross_align = .Center;
			{ ui.parent(ic); defer ui.pop_parent();
				spacer(.X, 8);
				g := T("--interactive-icon-default");
				if id == "home" || sig.hovering { g = T("--text-overlay-light"); }
				icon("glyph", icon_name, 24, g);
			}
		}
		if sig.hovering && guild_id != 0 {
			g := dc.guild_get(store(), guild_id);
			if g != null { tooltip_right(g.name); }
		}
	}
	return sig;
}

// Acronym font size on a guild icon without an image (official: "DB" 18px, "DBst" 16px).
guild_acronym_size :: (n: int) -> float32 {
	if n <= 2 {
		return 18;
	} else if n <= 4 {
		return 16;
	}
	return 12;
}

PERM_MANAGE_GUILD_EXPRESSIONS :: dc.PERM_MANAGE_GUILD_EXPRESSIONS;

// Guild-level permissions of the current user (owner / administrator = everything).
my_guild_permissions :: (gid: dc.Snowflake) -> u64 {
	return dc.guild_permissions(store(), gid);
}

// What the rail shows: a muted server and muted channels show no unread pill.
guild_unread_shown :: (gid: dc.Snowflake) -> bool {
	s := store();
	g := dc.guild_get(s, gid);
	if g == null { return false; }
	now := wall_ms();
	if dc.guild_is_muted(s, gid, now) { return false; }
	for id: g.channels {
		if dc.channel_unread(s, id) && !dc.channel_effectively_muted(s, gid, id, now) { return true; }
	}
	return false;
}

guild_has_unread :: (gid: dc.Snowflake) -> bool {
	s := store();
	g := dc.guild_get(s, gid);
	if g == null { return false; }
	for id: g.channels {
		if dc.channel_unread(s, id) { return true; }
	}
	return false;
}

sidebar :: () {
	b := ui.box("sidebar", .Draw_Background | .Draw_Border | .Clip);
	b.semantic_size = .[ui.px(app.view.sidebar_w), ui.pct(1)];
	b.style.bg = T("--background-base-lowest"); // same as the rail in the visual refresh
	b.style.border_color = T("--border-subtle");
	b.style.border = 1;
	b.style.radius = .[12, 0, 0, 0];
	b.layout_axis = .Y;
	{ ui.parent(b); defer ui.pop_parent();
		spacer(.Y, 1); // under the top border
		if app.view.guild == 0 {
			home_sidebar();
		} else {
			channel_sidebar(app.view.guild);
		}
		if resize_handle("resize", app.view.sidebar_w - 4, *app.view.sidebar_w, SIDEBAR_MIN_W, SIDEBAR_MAX_W) && app.client != null {
			dc.track_channel_sidebar_resized(app.client, cast(int) app.view.sidebar_w + RAIL_W);
		}
	}
}

page :: () {
	p := ui.box("page", .Draw_Background | .Clip);
	p.semantic_size = .[ui.fill(), ui.pct(1)];
	p.style.bg = T("--background-base-lower");
	p.layout_axis = .Y;
	{ ui.parent(p); defer ui.pop_parent();
		ch := ifx app.view.channel != 0 then dc.channel_get(store(), app.view.channel) else null;
		if ch == null {
			friends_page();
			return;
		}
		chat_header(ch);
		if ch.kind == .Guild_Voice || ch.kind == .Guild_Stage_Voice {
			call_view(ch.id);
			return;
		}
		if ch.guild_id == 0 && app.voice_channel == ch.id { dm_call_panel(ch.id); }
		body := row("chatbody");
		body.semantic_size = .[ui.pct(1), ui.fill()];
		body.cross_align = .Start;
		{ ui.parent(body); defer ui.pop_parent();
			if ch.kind == .Guild_Forum || ch.kind == .Guild_Media { forum_view(ch); } else { chat_view(ch.id); }
			// side columns only when the chat keeps a usable width (narrow windows
			// used to squeeze the composer until its placeholder wrapped per letter)
			room := app.ui.window.x - RAIL_W - app.view.sidebar_w - CHAT_MIN_W;
			if search_panel_open() { search_panel(); } else if room < app.view.member_w + 1 {} else if ch.guild_id != 0 && app.view.show_members && !dc.is_thread(ch) { member_list(ch); } else if ch.kind == .Group_DM && app.view.show_members { group_dm_members(ch); } else if ch.kind == .DM && !app.view.hide_dm_profile && ch.recipient_ids.count == 1 && room >= DMP_COL_W { dm_profile_panel(ch.recipient_ids[0]); }
		}
	}
}

chat_header :: (ch: *dc.Channel) {
	h := row("header", .Draw_Background);
	h.semantic_size = .[ui.pct(1), ui.px(HEADER_H - 1)];
	h.style.bg = T("--background-base-lower");
	{ ui.parent(h); defer ui.pop_parent();
		spacer(.X, 16);
		if ch.kind == .DM || ch.kind == .Group_DM {
			if ch.kind == .DM && ch.recipient_ids.count > 0 {
				avatar_box("av", ch.recipient_ids[0], 20);
				spacer(.X, 8);
			}
			label(dm_name(ch), .Medium, 16, T("--text-strong"), 20);
		} else {
			thread_header_prefix(ch);
			icon("hash", channel_icon_name(ch), 20, T("--channel-icon"));
			spacer(.X, 8);
			label(ch.name, .Medium, 16, T("--text-strong"), 20).semantic_size[ui.Axis.X].strictness = 1;
			if ch.topic != "" {
				spacer(.X, 12);
				d := ui.box("div", .Draw_Background);
				d.semantic_size = .[ui.px(1), ui.px(24)];
				d.style.bg = T("--border-subtle");
				spacer(.X, 12);
				// the topic gives way first on narrow windows (clipped by its wrapper;
				// a label can't clip its own text)
				topic := first_line(ch.topic);
				tw := ui.box("topic", .Clip);
				tw.semantic_size = .[ui.px(ui.layout_text(F(.Medium), 14, topic, -1).width, 0), ui.px(18)];
				{ ui.parent(tw); defer ui.pop_parent();
					t := label(topic, .Medium, 14, T("--text-muted"), 18);
					t.semantic_size[ui.Axis.X].strictness = 1;
				}
			}
		}
		filler(.X);
		tools := string.["thread", "bell", "pin", "group"];
		if ch.guild_id == 0 { tools = .["phone-call", "pin", "group-plus", "user-circle"]; }
		if ch.kind == .Group_DM { tools = .["phone-call", "pin", "group-plus", "group"]; } // member list toggle
		for name: tools {
			b := ui.box(name, .Clickable);
			b.semantic_size = .[ui.px(HEADER_TOOL_W), ui.px(24)];
			b.layout_axis = .X;
			b.cross_align = .Center;
			sig := ui.signal(b);
			active := (name == "group" && app.view.show_members) || (name == "user-circle" && !app.view.hide_dm_profile) || (name == "phone-call" && app.voice_channel == ch.id);
			color := ifx sig.hovering || active then T("--interactive-icon-hover") else T("--icon-muted");
			{ ui.parent(b); defer ui.pop_parent();
				spacer(.X, (HEADER_TOOL_W - 20) / 2);
				icon("i", ifx name == "bell" then bell_icon_name(ch) else name, 20, color);
			}
			if sig.clicked && name == "bell" && !dc.is_thread(ch) { bell_popout_toggle(ch.id, b.rect); }
			if sig.clicked && name == "group" { app.view.show_members = !app.view.show_members; }
			if sig.clicked && name == "user-circle" { app.view.hide_dm_profile = !app.view.hide_dm_profile; }
			if sig.clicked && name == "pin" { pins_toggle(ch.id, b.rect); }
			if sig.clicked && name == "phone-call" { dm_call_toggle(ch); }
			if sig.clicked && name == "thread" { threads_browser_toggle(ch.id, b.rect); }
			if sig.clicked && name == "group-plus" && ch.kind == .DM { group_dm_popout_open(b.rect, ch.id); }
		}
		spacer(.X, 8);
		search_hint := ch.name;
		if ch.guild_id != 0 {
			g := dc.guild_get(store(), ch.guild_id);
			if g != null { search_hint = g.name; }
		} else if ch.kind == .DM && ch.recipient_ids.count > 0 {
			u := dc.user_get(store(), ch.recipient_ids[0]);
			if u != null { search_hint = u.username; }
		} else {
			search_hint = dm_name(ch);
		}
		search_box(ch, tprint("Search %", search_hint));
		spacer(.X, 8);
	}
	line := ui.box("hline", .Draw_Background);
	line.semantic_size = .[ui.pct(1), ui.px(1)];
	line.style.bg = T("--border-subtle");
}

first_line :: (s: string) -> string {
	line := s;
	i := find_index_from_left(s, #char "\n");
	if i >= 0 { line.count = i; }
	return line;
}

channel_icon_name :: (ch: *dc.Channel) -> string {
	if ch.kind == {
	case .Guild_Voice;
		return "voice-normal";
	case .Guild_Announcement;
		return "announcements";
	case .Guild_Forum; #through; case .Guild_Media;
		return "forum";
	case .Guild_Stage_Voice;
		return "stage";
	case .Public_Thread; #through; case .Private_Thread; #through; case .Announcement_Thread;
		return "thread";
	}
	return "text";
}

channel_sidebar :: (gid: dc.Snowflake) {
	s := store();
	g := dc.guild_get(s, gid);
	if g == null { return; }
	hdr := row("guildheader", .Clickable | .Draw_Background | .Hot_Animation);
	hdr.semantic_size = .[ui.pct(1), ui.px(HEADER_H - 1)];
	hdr.style.bg_hot = T("--background-mod-subtle");
	if ui.signal(hdr).clicked { guild_menu_toggle(gid, hdr.rect); }
	if ui.mouse_over(hdr) { hdr.style.bg = hdr.style.bg_hot; } // also while over the invite button
	{ ui.parent(hdr); defer ui.pop_parent();
		spacer(.X, 16);
		label(ellipsize(g.name, .Semibold, 16, app.view.sidebar_w - 86), .Semibold, 16, T("--text-strong"), 20);
		spacer(.X, 5);
		icon("chev", "chevron-small-down", 18, T("--interactive-icon-hover"));
		filler(.X);
		if ui.signal(icon("invite", "group-plus", 20, T("--interactive-icon-hover"), .Clickable)).clicked { invite_open(gid, 0, dc.INVITE_LOC_HEADER_BUTTON); }
		spacer(.X, 14);
	}
	line := ui.box("hline", .Draw_Background);
	line.semantic_size = .[ui.pct(1), ui.px(1)];
	line.style.bg = T("--border-subtle");

	list := ui.box("channels", .Scroll_Y | .Clip);
	list.semantic_size = .[ui.pct(1), ui.fill()];
	list.bar_inset_bottom = USER_PANEL_H + voice_panel_height() + 16; // the panel floats over the list's end
	list.layout_axis = .Y;
	ui.signal(list);
	{ ui.parent(list); defer ui.pop_parent();
		spacer(.Y, 12);
		if guild_action_row("events", "calendar", events_row_label(gid)).clicked { events_open(gid); }
		spacer(.Y, 11);
		sep := row("sep");
		sep.semantic_size = .[ui.pct(1), ui.px(1)];
		{ ui.parent(sep); defer ui.pop_parent();
			spacer(.X, 16);
			l := ui.box("l", .Draw_Background);
			l.semantic_size = .[ui.fill(), ui.px(1)];
			l.style.bg = T("--border-subtle");
			spacer(.X, 16);
		}
		now := wall_ms();
		_, hide_muted := table_find(*app.view.hide_muted, gid);
		for cid: dc.guild_channels_sorted(s, gid) {
			ch := dc.channel_get(s, cid);
			if ch == null { continue; }
			// Hide Muted Channels: muted channels (own or category mute) go, the open one stays
			if hide_muted && cid != app.view.channel && dc.channel_effectively_muted(s, gid, cid, now) { continue; }
			{ ui.id_scope(cast(u64)(cid)); defer ui.pop_seed();
				if ch.kind == .Guild_Category {
					category_row(ch);
					continue;
				}
				_, parent_collapsed := table_find(*app.view.collapsed, ch.parent_id);
				if ch.parent_id != 0 && parent_collapsed && cid != app.view.channel { continue; }
				if dc.is_thread(ch) { continue; } // drawn under their parent
				channel_row(ch, gid);
				sidebar_thread_rows(ch, gid);
			}
		}
		spacer(.Y, USER_PANEL_H + voice_panel_height() + 16);
	}
}

// "Events" row above the channel list (32px on a 34px pitch).
guild_action_row :: (id: string, icon_name: string, text: string) -> ui.Signal {
	sig: ui.Signal;
	outer := row(id);
	outer.semantic_size = .[ui.pct(1), ui.px(CHANNEL_ROW_PITCH)];
	{ ui.parent(outer); defer ui.pop_parent();
		spacer(.X, 8);
		item := row("item", .Clickable | .Draw_Background | .Hot_Animation);
		item.semantic_size = .[ui.fill(), ui.px(CHANNEL_ROW_H)];
		item.style.radius = all4(8);
		item.style.bg_hot = T("--background-mod-subtle");
		sig = ui.signal(item);
		color := ifx sig.hovering then T("--interactive-text-hover") else T("--channels-default");
		{ ui.parent(item); defer ui.pop_parent();
			spacer(.X, 8);
			icon("ic", icon_name, 20, color);
			spacer(.X, 8);
			label(text, .Medium, 16, color, 20);
		}
		spacer(.X, 9);
	}
	return sig;
}

// Category: 16px gap, then a 24px row (14px medium name, chevron, "create channel" plus).
category_row :: (ch: *dc.Channel) {
	spacer(.Y, CATEGORY_GAP);
	r := row("cat", .Clickable);
	r.semantic_size = .[ui.pct(1), ui.px(CATEGORY_ROW_H)];
	sig := ui.signal(r);
	_, collapsed := table_find(*app.view.collapsed, ch.id);
	if sig.clicked { table_set(*app.view.collapsed, ch.id, !collapsed); }
	color := ifx sig.hovering then T("--interactive-text-hover") else T("--channels-default");
	{ ui.parent(r); defer ui.pop_parent();
		spacer(.X, 16);
		label(ch.name, .Medium, 14, color, 18);
		spacer(.X, 4);
		icon("chev", ifx collapsed then "chevron-small-right" else "chevron-small-down", 12, color);
		filler(.X);
		if can_manage_channels(ch.guild_id) {
			// "Create Channel" in this category (not a collapse toggle)
			plus := ui.box("createchan", .Clickable);
			plus.semantic_size = .[ui.px(18), ui.px(18)];
			ps := ui.signal(plus);
			set_icon(plus, "plus-small", ifx ps.hovering then T("--interactive-icon-hover") else T("--interactive-icon-default"));
			if ps.clicked { create_channel_open(ch.guild_id, ch.id); }
		}
		spacer(.X, 16);
	}
}

channel_row :: (ch: *dc.Channel, gid: dc.Snowflake) {
	selected := app.view.channel == ch.id;
	// muted channels are drawn dimmed and show no unread state (official --interactive-muted)
	muted := dc.channel_effectively_muted(store(), gid, ch.id, wall_ms());
	unread := dc.channel_unread(store(), ch.id) && !muted;
	outer := row("chan");
	outer.semantic_size = .[ui.pct(1), ui.px(CHANNEL_ROW_PITCH)];
	{ ui.parent(outer); defer ui.pop_parent();
		spacer(.X, 8);
		item := row("item", .Clickable | .Draw_Background | .Hot_Animation);
		item.semantic_size = .[ui.fill(), ui.px(CHANNEL_ROW_H)];
		item.style.radius = all4(8);
		item.style.bg = ifx selected then T("--background-mod-normal") else .{};
		item.style.bg_hot = ifx selected then item.style.bg else T("--background-mod-subtle");
		sig := ui.signal(item);
		sig.hovering ||= ui.mouse_over(item); // stays hovered over its invite / settings buttons
		if sig.hovering && !selected { item.style.bg = item.style.bg_hot; }
		if sig.clicked {
			if ch.kind == .Guild_Voice || ch.kind == .Guild_Stage_Voice {
				join_voice(gid, ch.id);
			} else {
				select_channel(gid, ch.id);
			}
		}
		color := T("--channels-default");
		if selected || unread {
			color = T("--interactive-text-active");
		} else if sig.hovering {
			color = T("--interactive-text-hover");
		} else if muted {
			color = T("--interactive-muted");
		}
		{ ui.parent(item); defer ui.pop_parent();
			spacer(.X, 8);
			icon("ic", channel_icon_name(ch), 20, ifx selected || sig.hovering || muted then color else T("--channel-icon"));
			spacer(.X, 8);
			label(ch.name, ifx unread || selected then .Semibold else .Medium, 16, color, 20);
			filler(.X);
			if selected || sig.hovering || ui.mouse_over(item) {
				// invite / settings, shown on the selected or hovered row
				if ui.signal(icon("invite", "group-plus", 16, T("--interactive-icon-hover"), .Clickable)).clicked { invite_open(gid, ch.id, dc.INVITE_LOC_CHANNELS); }
				if can_manage_channel(ch) {
					spacer(.X, 4);
					cog := ui.box("chansettings", .Clickable);
					cog.semantic_size = .[ui.px(16), ui.px(16)];
					cs := ui.signal(cog); // its own click: the row doesn't select the channel
					set_icon(cog, "settings", ifx cs.hovering then T("--interactive-icon-active") else T("--interactive-icon-hover"));
					if cs.clicked { channel_settings_open(ch); }
				}
			}
			spacer(.X, 8);
		}
		if unread && !selected {
			dot := ui.box("unread", .Draw_Background | .Floating_X | .Floating_Y);
			dot.semantic_size = .[ui.px(4), ui.px(8)];
			dot.fixed_pos = .{0, 13};
			dot.style.bg = T("--text-strong");
			dot.style.radius = .[0, 4, 0, 4];
		}
		spacer(.X, 9);
	}
	if ch.kind == .Guild_Voice {
		s := store();
		for vs, uid: s.voice_states {
			if vs.channel_id != ch.id { continue; }
			{ ui.id_scope(cast(u64)(uid)); defer ui.pop_seed();
				vr := row("voiceuser", .Clickable);
				vr.semantic_size = .[ui.pct(1), ui.px(32)];
				if ui.signal(vr).right_clicked { open_voice_user_menu(uid, app.ui.mouse); }
				{ ui.parent(vr); defer ui.pop_parent();
					spacer(.X, 44);
					voice_avatar("av", uid, 24, T("--background-base-lower"));
					spacer(.X, 8);
					label(dc.user_name(s, uid, ch.guild_id, "unknown"), .Medium, 14, T("--channels-default"), 18);
					filler(.X);
					if vs.self_video { icon("cam", "video", 16, T("--channels-default")); spacer(.X, 4); }
					if vs.self_stream {
						live := row("live", .Draw_Background);
						live.semantic_size = .[ui.children(), ui.px(16)];
						live.style.bg = T("--status-danger");
						live.style.radius = all4(8);
						{ ui.parent(live); defer ui.pop_parent();
							spacer(.X, 6);
							label("LIVE", .Bold, 11, .{1, 1, 1, 1}, 14);
							spacer(.X, 6);
						}
					}
					spacer(.X, 16);
				}
			}
		}
	}
}

user_panel :: () {
	s := store();
	vh := voice_panel_height();
	panel := ui.box("userpanel", .Draw_Background | .Draw_Border | .Floating_X | .Floating_Y);
	panel.layout_axis = .Y;
	panel.semantic_size = .[ui.px(RAIL_W + app.view.sidebar_w - 16), ui.px(USER_PANEL_H + vh)]; // spans the rail and sidebar, 8px inset
	panel.fixed_pos = .{8, app.ui.window.y - USER_PANEL_H - vh - 8};
	panel.style.bg = T("--background-base-low");
	panel.style.border_color = T("--border-muted");
	panel.style.border = 1;
	panel.style.radius = all4(8);
	{ ui.parent(panel); defer ui.pop_parent();
		if vh > 0 { voice_panel(); }
		p := row("userrow");
		p.semantic_size = .[ui.pct(1), ui.px(USER_PANEL_H)];
		{ ui.parent(p); defer ui.pop_parent();
			spacer(.X, 8);
			who := row("who", .Clickable | .Draw_Background | .Hot_Animation);
			who.semantic_size = .[ui.fill(), ui.px(42)];
			who.style.radius = all4(8);
			who.style.bg_hot = T("--background-mod-subtle");
			// your own profile card (the client also lists status options there)
			if ui.signal(who).clicked && dc.user_get(s, s.me) != null {
				open_profile(s.me, panel.rect, .Account_Panel);
				app.profile_above = true;
			}
			u := dc.user_get(s, s.me);
			if u == null { // before READY: placeholders, not a made-up name and status
				who.flags &= ~.Clickable;
				ui.parent(who); defer ui.pop_parent();
				spacer(.X, 4);
				skel("av", 32, 32, true);
				spacer(.X, 8);
				names := ui.box("names");
				names.semantic_size = .[ui.fill(), ui.children()];
				ui.parent(names); defer ui.pop_parent();
				skel("name", 90, 12);
				spacer(.Y, 6);
				skel("status", 50, 10);
			} else { ui.parent(who); defer ui.pop_parent();
				spacer(.X, 4);
				avatar_with_status("av", s.me, 32, T("--background-base-low"));
				spacer(.X, 8);
				names := ui.box("names");
				names.semantic_size = .[ui.fill(), ui.children()];
				{ ui.parent(names); defer ui.pop_parent();
					label(dc.display_name(u), .Medium, 14, T("--text-strong"), 18);
					status := ifx s.settings.status == .Invisible then "Invisible" else status_text(user_status(s.me));
					// a timed status ends in the client's tick: wake for it
					if s.settings.status_expires_ms request_wake(app.ui.time + cast(float64) max(0, s.settings.status_expires_ms - wall_ms()) / 1000 + 0.05);
					if s.settings.custom_status_text != "" { status = s.settings.custom_status_text; }
					label(status, .Normal, 12, T("--text-muted"), 14);
				}
			}
			for name: (string.["microphone", "headphones", "settings"]) {
				// mic / headphones carry a device-menu chevron (official: 54px wide, 3px apart)
				has_chev := name != "settings";
				b := ui.box(name, .Clickable | .Draw_Background | .Hot_Animation);
				b.semantic_size = .[ui.px(ifx has_chev then 54.0 else 32.0), ui.px(32)];
				b.style.radius = all4(8);
				b.style.bg_hot = T("--background-mod-subtle");
				b.layout_axis = .X;
				b.cross_align = .Center;
				sig := ui.signal(b);
				ic := name;
				muted := (name == "microphone" && app.self_mute) || (name == "headphones" && app.self_deaf);
				if muted { ic = tprint("%-slash", name); }
				{ ui.parent(b); defer ui.pop_parent();
					spacer(.X, 6);
					color := ifx muted then T("--status-danger") else (ifx sig.hovering then T("--interactive-icon-hover") else T("--interactive-icon-default"));
					icon("i", ic, 20, color);
					if has_chev {
						// the chevron is its own button: input / output device settings
						spacer(.X, 3);
						cb := ui.box("chev", .Clickable);
						cb.semantic_size = .[ui.px(24), ui.px(32)];
						cb.layout_axis = .X;
						cb.cross_align = .Center;
						csig := ui.signal(cb);
						{ ui.parent(cb); defer ui.pop_parent();
							spacer(.X, 4);
							icon("i", "chevron-small-down", 16, ifx sig.hovering || csig.hovering then T("--interactive-icon-hover") else T("--interactive-icon-default"));
						}
						if csig.clicked {
							settings_page = "Voice & Video";
							app.settings_open = true;
						}
					}
				}
				if has_chev { spacer(.X, 3); }
				if sig.clicked {
					if name == {
					case "microphone";
						app.self_mute = !app.self_mute;
					case "headphones";
						app.self_deaf = !app.self_deaf;
					case "settings";
						settings_page = "Account"; // the gear opens on Account, like the client
						app.settings_open = true;
					}
				}
			}
			spacer(.X, 13);
		}
	}
}

status_text :: (st: dc.Status) -> string {
	if st == {
	case .Online;
		return "Online";
	case .Idle;
		return "Idle";
	case .Dnd;
		return "Do Not Disturb";
	case .Invisible;
		return "Invisible";
	case .Offline;
		return "Offline";
	}
	return "Online";
}

status_color :: (st: dc.Status) -> ui.Color {
	if st == {
	case .Online;
		return T("--icon-status-online");
	case .Idle;
		return T("--icon-status-idle");
	case .Dnd;
		return T("--icon-status-dnd");
	case .Offline; #through; case .Invisible;
		return T("--icon-status-offline");
	}
	return T("--icon-status-offline");
}

user_status :: (uid: dc.Snowflake) -> dc.Status {
	s := store();
	if uid == s.me {
		if s.settings.status == {
		case .Invisible;
			return .Offline;
		case .Idle; #through; case .Dnd;
			return s.settings.status;
		}
		return .Online;
	}
	p := table_find_pointer(*s.presences, uid);
	return ifx p then p.status else .Offline;
}

// Tooltip to the right of the current parent (guild names on the rail).
tooltip_right :: (text: string) {
	tip := row("tooltip", .Draw_Background | .Draw_Shadow | .Floating_X | .Floating_Y | .Overlay);
	tip.semantic_size = .[ui.children(), ui.px(36)];
	tip.fixed_pos = .{16 + GUILD_ICON + 12, (GUILD_ICON - 36) / 2};
	tip.style.bg = T("--background-surface-highest");
	tip.style.radius = all4(8);
	tip.style.shadow_color = .{0, 0, 0, 0.3};
	tip.style.shadow_blur = 8;
	tip.style.shadow_offset = .{0, 4};
	{ ui.parent(tip); defer ui.pop_parent();
		spacer(.X, 12);
		label(text, .Semibold, 16, T("--text-strong"), 20);
		spacer(.X, 12);
	}
}

// A voice channel's row joins it and opens its call view (the join already loads
// the channel's text page, so no channel select goes out).
join_voice :: (gid: dc.Snowflake, cid: dc.Snowflake) {
	voice_join_channel(gid, cid);
	app.view.guild = gid;
	app.view.channel = cid;
}

overlays :: () {
	// Escape is a global keybind in the official client (MARK_CHANNEL_READ, or
	// POP_LAYER over settings); it is tracked whatever layer it closes
	if app.client != null { for e: app.ui.events { if e.kind == .Key_Down && e.key == .Escape {
		dc.analytics_keyboard_shortcut(app.client, ifx app.settings_open then "POP_LAYER" else "MARK_CHANNEL_READ", "esc");
	} } }
	picker_overlay();
	group_dm_overlay();
	profile_full_overlay();
	for * e: app.ui.events {
		if !e.consumed && e.kind == .Key_Down && e.key == .K && (e.mods & PRIMARY_MOD) != 0 {
			if !sw.open && app.client != null {
				dc.analytics_keyboard_shortcut(app.client, "QUICKSWITCHER_SHOW", "mod+k");
				dc.analytics_quickswitcher_opened(app.client, app.view.guild, app.view.channel);
			}
			switcher_toggle();
			e.consumed = true;
		}
	}
	if sw.open { quick_switcher(); }
	if ma.menu_msg != 0 { message_menu(); }
	if edit_menu_state.open { edit_menu(); }
	if ma.confirming != 0 { confirm_modal(); }
	if block_confirm.user != 0 { block_confirm_modal(); }
	if fnick.user != 0 { friend_nick_modal(); }
	if app.profile_user != 0 { profile_popout(); }
	user_context_menu(); // view_profile_full.jai: above the profile popout it may come from
	media_overlays(); // view_media.jai: image viewer, media context menu
	incoming_call_popout(); // view_voice.jai
	if app.settings_open { settings_modal(); } else { settings_closed(); }
	account_logout_modal(); // view_settings_account.jai
	add_server_overlay(); // view_add_server.jai
	invite_accept_overlay(); // view_invites.jai
	voice_user_menu();
	screen_picker(); // view_call.jai
	pins_popout();
	threads_browser_popout();
	inbox_popout();
	guild_menu_overlays();
	search_suggestions();
	events_modal();
	guild_admin_overlays();
	attachments_overlays(); // attachments.jai: Modify modal, drag target, limit notices
	req_toast(); // requests.jai: a failed request, on top
}

#scope_file

history_push :: (h: *[..][2]dc.Snowflake, place: [2]dc.Snowflake) {
	if h.count >= HISTORY_MAX { array_ordered_remove_by_index(h, 0); }
	array_add(h, place);
}

go_to :: (gid: dc.Snowflake, cid: dc.Snowflake, source := "") {
	was_home := app.view.guild == 0 && app.view.channel == 0;
	if cid != app.view.channel {
		// the "NEW" divider and new-messages bar start again from the read state on every visit
		cs := table_find_pointer(*app.chats, cid);
		if cs cs.opened = false;
	}
	app.view.guild = gid;
	app.view.channel = cid;
	table_set(*app.view.last_channel, gid, cid);
	if app.client != null {
		limit := dc.initial_message_limit(cast(int)(app.ui.window.y));
		dc.select_channel(app.client, gid, cid, limit, source = source);
		if gid == 0 && cid == 0 && !was_home { dc.friends_page_viewed(app.client); } // the Friends page renders
	}
}
