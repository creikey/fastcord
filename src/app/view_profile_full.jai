// Full user profile modal ("View Full Profile" from the popout avatar, user
// right-click > Profile): banner, avatar, names, Message / Add Friend / More,
// tabs About Me (bio markdown, Member Since, Note) / Mutual Servers / Mutual
// Friends. Requests as the client's UserProfileModalActionCreators
// (profile?type=modal..., application-identities, relationships for the tab).

PF_W :: 600;
PF_BANNER_H :: 212; // with a banner image (106 without)
PF_BANNER_H_PLAIN :: 106;
PF_AVATAR :: 120;
PF_AVATAR_RING :: 8;
PF_PAD :: 16;
PF_TAB_H :: 40;
PF_BODY_MIN_H :: 240;
PF_ROW_H :: 52;

Pf_Tab :: enum u8 {
	About;
	Mutual_Servers;
	Mutual_Friends;
}

Pf_Mutual_Guild :: struct {
	id: dc.Snowflake;
	nick: string;
}

Pf_Friend :: struct {
	id: dc.Snowflake;
	username: string;
	global_name: string;
	avatar: string;
}

Pf_Profile :: struct {
	loaded: bool;
	friends_req: bool;
	friends_done: bool;
	banner: string;
	accent: u32;
	has_accent: bool;
	bio: string;
	pronouns: string;
	guild_joined: string; // guild_member.joined_at in the modal's guild context
	mutual_guilds: [..]Pf_Mutual_Guild;
	mutual_count: int;
	friends: [..]Pf_Friend;
	badges: [..][2]string; // heap: icon hash, description
	connections: [..][3]string; // heap: type, account name, "1" when verified
}
#scope_file

Pf_State :: struct {
	user: dc.Snowflake;
	guild: dc.Snowflake;
	tab: Pf_Tab;
	t: float32;
	profiles: Table(dc.Snowflake, Pf_Profile);
	menu_user: dc.Snowflake; // user context menu
	menu_pos: ui.Vec2;
	menu_dm: dc.Snowflake; // opened from this 1:1 DM's row: Mark As Read and Close DM too
	note: ui.Editor; // the Note field while focused
	note_focused: bool;
	note_focus_next: bool; // the user menu's Add Note: the next note field drawn takes the focus
	roles_user: dc.Snowflake; // the user menu's Roles list, open for this member of app.view.guild
	roles_pos: ui.Vec2;
}

pf: Pf_State;
#scope_export

// Closes the full profile if it shows uid.
profile_full_close_for :: (uid: dc.Snowflake) { if pf.user == uid pf.user = 0; }

profile_full_open :: (uid: dc.Snowflake, guild_id: dc.Snowflake = 0) {
	pf.user = uid;
	pf.guild = guild_id;
	pf.tab = .About;
	pf.t = 0;
	app.profile_user = 0;
	if app.client != null {
		u := dc.user_get(store(), uid);
		dc.profile_modal_fetch(app.client, uid, guild_id, u != null && u.bot);
	}
}

// Popout hook: the avatar opens the full profile (with a hint on hover).
profile_full_avatar_hook :: (av: *ui.Box, uid: dc.Snowflake) {
	av.flags |= .Clickable;
	sig := ui.signal(av);
	if sig.hovering {
		{ ui.parent(av); defer ui.pop_parent();
			shade := ui.box("pfshade", .Draw_Background | .Floating_X | .Floating_Y | .Draw_Text);
			shade.semantic_size = av.semantic_size;
			shade.style.radius = av.style.radius;
			shade.style.bg = .{0, 0, 0, 0.5};
			shade.text = "View Profile";
			shade.style.font = F(.Bold);
			shade.style.font_size = 10;
			shade.style.text_align = .Center;
			shade.style.text_color = .{1, 1, 1, 1};
		}
	}
	if sig.clicked { profile_full_open(uid, app.view.guild); }
}

profile_full_receive :: (r: *dc.Expr_Result) {
	uid := cast(dc.Snowflake)(r.tag);
	p := find_or_add(*pf.profiles, uid);
	if !r.ok { return; }
	if r.op == {
	case .Profile_Modal;
		m := dc.vmap(r.body);
		u := dc.fmap(m, "user");
		prof := dc.fmap(m, "user_profile");
		p.loaded = true;
		free(p.banner);
		free(p.bio);
		free(p.pronouns);
		free(p.guild_joined);
		p.banner = copy_string(dc.fstr(u, "banner"));
		p.bio = copy_string(dc.fstr(prof, "bio"));
		p.pronouns = copy_string(dc.fstr(prof, "pronouns"));
		if dc.vhas(u, "accent_color") && !dc.vis_null(dc.vget(u, "accent_color")) { p.accent, p.has_accent = cast(u32) dc.fint(u, "accent_color"), true; }
		p.guild_joined = copy_string(dc.fstr(dc.fmap(m, "guild_member"), "joined_at"));
		p.mutual_guilds.count = 0;
		for dc.flist(m, "mutual_guilds") {
			gm := dc.vmap(it);
			array_add(*p.mutual_guilds, .{dc.fsnow(gm, "id"), copy_string(dc.fstr(gm, "nick"))});
		}
		p.mutual_count = cast(int)(dc.fint(m, "mutual_friends_count"));
		for p.badges for it free(it);
		for p.connections for it free(it);
		p.badges.count, p.connections.count = 0, 0;
		for dc.flist(m, "badges") {
			b := dc.vmap(it);
			id, ic := dc.fstr(b, "id"), dc.fstr(b, "icon");
			if !dc.badge_shown(id, ic) || p.badges.count >= 32 continue;
			array_add(*p.badges, .[copy_string(ic), copy_string(dc.fstr(b, "description"))]);
		}
		for dc.flist(m, "connected_accounts") {
			c := dc.vmap(it);
			if p.connections.count >= 32 break;
			array_add(*p.connections, .[copy_string(dc.fstr(c, "type")), copy_string(dc.fstr(c, "name")), copy_string(ifx dc.fbool(c, "verified") then "1" else "")]);
		}
	case .Mutual_Friends;
		p.friends_done = true;
		p.friends.count = 0;
		for dc.vlist(r.body) {
			f := dc.vmap(it);
			array_add(*p.friends, .{dc.fsnow(f, "id"), copy_string(dc.fstr(f, "username")), copy_string(dc.fstr(f, "global_name")), copy_string(dc.fstr(f, "avatar"))});
		}
		p.mutual_count = p.friends.count;
	}
}

// Overlay entry (views.jai overlays()).
profile_full_overlay :: () {
	// FASTCORD_PROFILE=<id>|me|friend opens a profile once the first channel shows (screenshots)
	if !env_profile_done && app.view.channel != 0 {
		env_profile_done = true;
		v := env_var("FASTCORD_PROFILE");
		if v != "" {
			id := dc.parse_u64(v);
			if v == "me" { id = cast(u64) store().me; }
			if v == "friend" { for rel, uid: store().relationships { if rel.kind == .Friend { id = cast(u64) uid; } } }
			profile_full_open(cast(dc.Snowflake) id, app.view.guild);
		}
	}
	if pf.user == 0 { return; }
	s := store();
	uid := pf.user;
	u := dc.user_get(s, uid);
	if u == null {
		pf.user = 0;
		return;
	}
	_, prof := table_find(*pf.profiles, uid);
	ui.animate(*pf.t, 1, 25);
	screen := app.ui.window;
	scrim := ui.box("pf_scrim###pf_scrim", .Draw_Background | .Clickable | .Floating_X | .Floating_Y | .Overlay);
	scrim.semantic_size = .[ui.px(screen.x), ui.px(screen.y)];
	scrim.style.bg = with_alpha(T("--background-scrim"), pf.t);
	if ui.signal(scrim).clicked {
		pf.user = 0;
		return;
	}
	banner_url := user_banner_url(uid, pf.guild, ifx prof.banner != "" then prof.banner else u.banner);
	banner_h: float32 = ifx banner_url != "" then cast(float32) PF_BANNER_H else cast(float32) PF_BANNER_H_PLAIN;
	body_h := min(screen.y - 80 - banner_h - 140 - PF_TAB_H, PF_BODY_MIN_H);
	total_h := banner_h + 140 + PF_TAB_H + body_h;
	x := (screen.x - PF_W) / 2;
	y := (screen.y - total_h) / 2;
	m := ui.box("pf###pf_modal", .Draw_Background | .Draw_Shadow | .Floating_X | .Floating_Y | .Clickable | .Clip | .Overlay);
	m.semantic_size = .[ui.px(PF_W), ui.px(total_h)];
	m.fixed_pos = .{x, y + (1 - pf.t) * 16};
	m.layout_axis = .Y;
	m.style.bg = T("--background-surface-high");
	m.style.radius = all4(8);
	m.style.shadow_color = .{0, 0, 0, 0.4};
	m.style.shadow_blur = 24;
	m.style.shadow_offset = .{0, 8};
	ui.signal(m);
	{ ui.parent(m); defer ui.pop_parent();
		banner := ui.box("banner", .Draw_Background);
		banner.semantic_size = .[ui.pct(1), ui.px(banner_h)];
		banner.style.radius = .[8, 8, 0, 0];
		banner.style.bg = ifx prof.has_accent then rgb_u32(prof.accent) else ifx u.has_accent_color then rgb_u32(u.accent_color) else T("--background-brand");
		if banner_url != "" { set_remote_image(banner, banner_url); }
		head := ui.box("head");
		head.semantic_size = .[ui.pct(1), ui.px(140)];
		{ ui.parent(head); defer ui.pop_parent();
			ring := ui.box("ring", .Draw_Background | .Floating_X | .Floating_Y);
			rs_: float32 = PF_AVATAR + 2 * PF_AVATAR_RING;
			ring.semantic_size = .[ui.px(rs_), ui.px(rs_)];
			ring.fixed_pos = .{PF_PAD + 8 - PF_AVATAR_RING, -PF_AVATAR / 2 - PF_AVATAR_RING};
			ring.style.radius = all4(rs_ / 2);
			ring.style.bg = m.style.bg;
			{ ui.parent(ring); defer ui.pop_parent();
				av := avatar_with_status("av", uid, PF_AVATAR, m.style.bg, animate = true);
				av.flags |= .Floating_X | .Floating_Y;
				av.fixed_pos = .{PF_AVATAR_RING, PF_AVATAR_RING};
			}
			profile_actions(uid);
			names := ui.box("names", .Floating_X | .Floating_Y);
			names.semantic_size = .[ui.px(PF_W - 2 * PF_PAD), ui.children()];
			names.fixed_pos = .{PF_PAD + 8, PF_AVATAR / 2 + 16};
			names.layout_axis = .Y;
			{ ui.parent(names); defer ui.pop_parent();
				n := label(dc.user_name(s, uid, pf.guild), .Bold, 24, T("--text-strong"), 30);
				n.flags |= .Selectable_Text;
				n.sel_order = 1;
				un := row("un");
				un.semantic_size = .[ui.pct(1), ui.px(20)];
				{ ui.parent(un); defer ui.pop_parent();
					l := label(u.username, .Normal, 16, T("--text-default"), 20);
					l.flags |= .Selectable_Text;
					l.sel_order = 2;
					pron := ifx prof.pronouns != "" then prof.pronouns else u.pronouns;
					if pron != "" { label(tprint(" • %", pron), .Normal, 16, T("--text-default"), 20); }
					server_tag(u);
					for prof.badges {
						spacer(.X, ifx it_index then 2.0 else 8.0);
						b := ui.box(tprint("badge%", it_index));
						b.semantic_size = .[ui.px(20), ui.px(20)];
						set_remote_image(b, tprint("%/badge-icons/%.png", dc.CDN, it[0]));
						if ui.mouse_over(b) tooltip_below(it[1], b.rect);
					}
				}
			}
		}
		profile_tabs(uid, prof);
		line := ui.box("tabline", .Draw_Background);
		line.semantic_size = .[ui.pct(1), ui.px(1)];
		line.style.bg = T("--border-subtle");
		body := ui.box("body", .Clip | .Scroll_Y);
		body.semantic_size = .[ui.pct(1), ui.fill()];
		body.layout_axis = .Y;
		ui.signal(body);
		{ ui.parent(body); defer ui.pop_parent();
			if pf.tab == {
			case .About;
				profile_about(uid, u, prof);
			case .Mutual_Servers;
				profile_mutual_servers(prof);
			case .Mutual_Friends;
				profile_mutual_friends(uid, prof);
			}
			spacer(.Y, PF_PAD);
		}
	}
	for * e: app.ui.events {
		if !e.consumed && e.kind == .Key_Down && e.key == .Escape && fnick.user == 0 {
			e.consumed = true;
			pf.user = 0;
		}
	}
	pk_fade(m, pf.t);
}
#scope_file

// Message (friends / others) or Add Friend, plus More — top right under the banner; your own
// profile has Edit Profile (Settings > Profiles) instead.
profile_actions :: (uid: dc.Snowflake) {
	s := store();
	if uid == s.me {
		bar := row("actions", .Floating_X | .Floating_Y);
		bar.semantic_size = .[ui.children(), ui.px(32)];
		bar.fixed_pos = .{PF_W - PF_PAD - 120, PF_PAD};
		ui.parent(bar); defer ui.pop_parent();
		if action_button(L("Edit Profile"), "pencil", 120, true) {
			pf.user = 0;
			settings_page = "Profiles";
			app.settings_open = true;
		}
		return;
	}
	rel := table_find_pointer(*s.relationships, uid);
	friend := rel && rel.kind == .Friend;
	bar := row("actions", .Floating_X | .Floating_Y);
	bar.semantic_size = .[ui.children(), ui.px(32)];
	w: float32 = cast(float32) (ifx friend || on_hosted() then 110 + 8 + 32 else 110 + 8 + 120 + 8 + 32);
	bar.fixed_pos = .{PF_W - PF_PAD - w, PF_PAD};
	bar.style.child_gap = 8;
	{ ui.parent(bar); defer ui.pop_parent();
		if !friend && !on_hosted() {
			pending := rel && rel.kind == .Outgoing_Request;
			add := action_button(ifx pending then L("Pending") else L("Add Friend"), "user-plus", 120, false, rel_req("Add Friend", uid));
			if add && !pending && req_begin(rel_req("Add Friend", uid)) { dc.add_relationship(app.client, uid, "User Profile"); req_end(); }
		}
		if action_button(L("Message"), "chat", 110, true, dm_req(uid)) && open_dm_with(uid, "User Profile") { pf.user = 0; }
		more := ui.box("more", .Clickable | .Draw_Background | .Hot_Animation);
		more.semantic_size = .[ui.px(32), ui.px(32)];
		more.style.radius = all4(8);
		more.style.bg = T("--control-secondary-background-default");
		more.style.bg_hot = T("--control-secondary-background-hover");
		more.layout_axis = .X;
		more.cross_align = .Center;
		if ui.signal(more).clicked { open_user_menu(uid, .{more.rect.x0, more.rect.y1 + 4}); }
		{ ui.parent(more); defer ui.pop_parent();
			spacer(.X, 6);
			icon("i", "more-horizontal", 20, T("--interactive-icon-active"));
		}
	}
}

action_button :: (text: string, icon_name: string, w: float32, primary: bool, req := "") -> bool {
	b := row(text, .Clickable | .Draw_Background | .Hot_Animation);
	b.semantic_size = .[ui.px(w), ui.px(32)];
	b.style.radius = all4(8);
	b.style.bg = ifx primary then T("--background-brand") else T("--control-secondary-background-default");
	b.style.bg_hot = ifx primary then with_alpha(T("--background-brand"), 0.85) else T("--control-secondary-background-hover");
	if req != "" && req_state(req) == .Pending return req_button(b, req, T("--interactive-text-active"));
	sig := ui.signal(b);
	{ ui.parent(b); defer ui.pop_parent();
		filler(.X);
		icon("i", icon_name, 16, ifx primary then ui.Color.{1, 1, 1, 1} else T("--interactive-text-active"));
		spacer(.X, 6);
		label(text, .Medium, 14, ifx primary then ui.Color.{1, 1, 1, 1} else T("--interactive-text-active"), 18);
		filler(.X);
	}
	return sig.clicked;
}

profile_tabs :: (uid: dc.Snowflake, prof: Pf_Profile) {
	tabs := row("tabs");
	tabs.semantic_size = .[ui.pct(1), ui.px(PF_TAB_H)];
	tabs.cross_align = .End;
	{ ui.parent(tabs); defer ui.pop_parent();
		spacer(.X, PF_PAD + 8);
		for t: enum_values_as_enum(Pf_Tab) {
			if uid == store().me && t != .About { continue; }
			text := "About Me";
			if t == {
			case .About;
			case .Mutual_Servers;
				n := prof.mutual_guilds.count;
				text = ifx n == 1 then "1 Mutual Server" else (ifx n > 0 then tprint("% Mutual Servers", n) else "Mutual Servers");
			case .Mutual_Friends;
				n := prof.mutual_count;
				text = ifx n == 1 then "1 Mutual Friend" else (ifx n > 0 then tprint("% Mutual Friends", n) else "Mutual Friends");
			}
			sel := pf.tab == t;
			b := ui.box(tprint("%##tab%", text, cast(int) t), .Clickable);
			b.semantic_size = .[ui.children(), ui.px(PF_TAB_H)];
			b.layout_axis = .Y;
			sig := ui.signal(b);
			{ ui.parent(b); defer ui.pop_parent();
				spacer(.Y, 10);
				lab := label(text, .Medium, 16, ifx sel || sig.hovering then T("--interactive-text-active") else T("--interactive-text-default"), 20);
				filler(.Y);
				ul := ui.box("ul", .Draw_Background);
				ul.semantic_size = .[ui.px(max(0.0, lab.rect.x1 - lab.rect.x0)), ui.px(2)];
				ul.style.bg = ifx sel then T("--text-strong") else .{};
				ul.style.radius = all4(1);
			}
			if sig.clicked {
				pf.tab = t;
				if t == .Mutual_Friends && app.client != null && !prof.friends_req {
					find_or_add(*pf.profiles, uid).friends_req = true;
					dc.mutual_friends_fetch(app.client, uid);
				}
			}
			spacer(.X, 32);
		}
	}
}

// The note about uid, edited in place: a click focuses it, and leaving it (or Enter) saves a
// change, as the official note box does on blur (only you can see it). The DM profile column has its
// own editor (ed, was_focused), as both can show at once.
#scope_export
note_field :: (uid: dc.Snowflake, pad: float32, ed: *ui.Editor, was_focused: *bool) {
	note, loaded := dc.note_get(store(), uid);
	if !loaded && app.client dc.fetch_note(app.client, uid);
	nr := row("note");
	nr.semantic_size = .[ui.pct(1), ui.children()];
	ui.parent(nr); defer ui.pop_parent();
	spacer(.X, pad);
	box := row("notebox", .Clickable | .Draw_Background);
	box.semantic_size = .[ui.fill(), ui.children()];
	box.style.radius = all4(4);
	box.hover_cursor = .IBeam;
	focused := app.ui.focus == box.key;
	if focused box.style.bg = T("--background-mod-normal");
	if (ui.signal(box).pressed || (pf.note_focus_next && ed == *pf.note)) && !focused {
		app.ui.focus = box.key;
		focused = true;
	}
	if ed == *pf.note pf.note_focus_next = false;
	if focused && !was_focused.* ui.editor_set_text(ed, note);
	res: ui.Edit_Result;
	{ ui.parent(box); defer ui.pop_parent();
		spacer(.X, 4);
		if focused {
			res = text_field("f", ed, L("Click to add a note"), true, 14, 18, 4, T("--text-muted"));
			t := ui.editor_text(ed);
			cut := cut_runes(t, dc.NOTE_MAX);
			if cut.count < t.count ui.editor_set_text(ed, copy_string(cut,, temp));
		} else {
			l := label(ifx note then note else L("Click to add a note"), .Normal, 14, ifx note then T("--text-default") else T("--text-muted"), 18);
			l.flags |= .Wrap_Text;
			l.semantic_size[ui.Axis.X] = ui.fill();
			l.style.padding = .{0, 4};
		}
		spacer(.X, 4);
	}
	spacer(.X, pad);
	if res == .Submit || res == .Escape app.ui.focus = 0;
	if was_focused.* && app.ui.focus != box.key {
		t := trim(ui.editor_text(ed));
		if t != note { if net_action() dc.set_note(app.client, uid, t); else dc.note_set_local(store(), uid, t); } // offline (fixtures): shown only
	}
	was_focused.* = app.ui.focus == box.key;
}
#scope_file

section_title :: (text: string) {
	r := row(text);
	r.semantic_size = .[ui.pct(1), ui.px(20)];
	{ ui.parent(r); defer ui.pop_parent();
		spacer(.X, PF_PAD + 8);
		label(text, .Semibold, 12, T("--text-strong"), 16);
	}
	spacer(.Y, 6);
}

profile_about :: (uid: dc.Snowflake, u: *dc.User, prof: Pf_Profile) {
	spacer(.Y, PF_PAD);
	act := rich_activity(uid);
	if act {
		activity_card(act, PF_PAD + 8);
		spacer(.Y, 16);
	}
	bio := ifx prof.bio != "" then prof.bio else u.bio;
	if bio != "" {
		section_title(L("About Me"));
		for blk, bi: md_parse(bio) {
			w := row(tprint("bio%", bi));
			w.semantic_size = .[ui.pct(1), ui.children()];
			{ ui.parent(w); defer ui.pop_parent();
				spacer(.X, PF_PAD + 8);
				b := ui.box("p", .Selectable_Text | .Wrap_Text);
				b.semantic_size = .[ui.fill(), ui.text_size()];
				b.style.line_height = 18;
				b.style.text_color = T("--text-default");
				b.sel_order = 10 + cast(u64)(bi);
				ui.set_spans(b, tokens_to_spans(blk.tokens, .Normal, 14, null));
				spacer(.X, PF_PAD + 8);
			}
		}
		spacer(.Y, 16);
	}
	section_title(L("Member Since"));
	ms := row("since");
	ms.semantic_size = .[ui.pct(1), ui.px(20)];
	{ ui.parent(ms); defer ui.pop_parent();
		spacer(.X, PF_PAD + 8);
		icon("dlogo", "logo", 16, T("--interactive-icon-default"));
		spacer(.X, 8);
		label(short_date(dc.snowflake_time_ms(uid)), .Normal, 14, T("--text-default"), 18);
		if prof.guild_joined != "" && pf.guild != 0 {
			spacer(.X, 12);
			dot := ui.box("dot", .Draw_Background);
			dot.semantic_size = .[ui.px(4), ui.px(4)];
			dot.style.radius = all4(2);
			dot.style.bg = T("--text-muted");
			spacer(.X, 12);
			gi := ui.box("##gi", .Draw_Background | .Draw_Text);
			gi.semantic_size = .[ui.px(16), ui.px(16)];
			gi.style.radius = all4(5);
			gi.style.bg = T("--background-mod-subtle");
			gi.style.font = F(.Medium);
			gi.style.font_size = 7;
			gi.style.text_align = .Center;
			gi.style.text_color = T("--text-default");
			g := dc.guild_get(store(), pf.guild);
			if g != null {
				if g.icon != "" { set_remote_image(gi, guild_icon_url(g.id, g.icon, 32)); } else { gi.text = guild_initials(g.name); }
			}
			spacer(.X, 8);
			label(short_date(dc.iso_to_ms(prof.guild_joined)), .Normal, 14, T("--text-default"), 18);
		}
	}
	spacer(.Y, 16);
	if prof.connections.count && !streamer_hide_personal() {
		section_title(L("Connections"));
		for prof.connections {
			cr := row(tprint("conn%", it_index));
			cr.semantic_size = .[ui.pct(1), ui.px(24)];
			{ ui.parent(cr); defer ui.pop_parent();
				spacer(.X, PF_PAD + 8);
				label(it[1], .Medium, 14, T("--text-strong"), 18);
				if it[2] { spacer(.X, 4); icon("v", "checkmark-small", 14, T("--text-feedback-positive")); }
				spacer(.X, 8);
				label(platform_name(it[0]), .Normal, 12, T("--text-muted"), 16); // view_settings_user.jai
			}
		}
		spacer(.Y, 16);
	}
	if uid != store().me && !streamer_hide_personal() {
		section_title(L("Note"));
		note_field(uid, PF_PAD + 4, *pf.note, *pf.note_focused);
	}
}

list_row :: (id: string) -> *ui.Box, ui.Signal {
	outer := row(id);
	outer.semantic_size = .[ui.pct(1), ui.px(PF_ROW_H)];
	r: *ui.Box;
	sig: ui.Signal;
	{ ui.parent(outer); defer ui.pop_parent();
		spacer(.X, 8);
		r = row("item", .Clickable | .Draw_Background | .Hot_Animation);
		r.semantic_size = .[ui.fill(), ui.px(PF_ROW_H)];
		r.style.radius = all4(8);
		r.style.bg_hot = T("--background-mod-subtle");
		sig = ui.signal(r);
		spacer(.X, 8);
	}
	return r, sig;
}

empty_state :: (text: string) {
	spacer(.Y, 48);
	r := ui.box(text);
	r.semantic_size = .[ui.pct(1), ui.px(20)];
	r.layout_axis = .X;
	r.cross_align = .Center;
	{ ui.parent(r); defer ui.pop_parent();
		filler(.X);
		label(text, .Medium, 16, T("--text-muted"), 20);
		filler(.X);
	}
}

profile_mutual_servers :: (prof: Pf_Profile) {
	spacer(.Y, 8);
	if prof.mutual_guilds.count == 0 {
		empty_state(ifx prof.loaded || app.client == null then "No servers in common" else "Loading…");
		return;
	}
	for mg: prof.mutual_guilds {
		g := dc.guild_get(store(), mg.id);
		if g == null { continue; }
		{ ui.id_scope(cast(u64)(mg.id)); defer ui.pop_seed();
			r, sig := list_row("mg");
			{ ui.parent(r); defer ui.pop_parent();
				spacer(.X, 8);
				gi := ui.box("##gi", .Draw_Background | .Draw_Text);
				gi.semantic_size = .[ui.px(40), ui.px(40)];
				gi.style.radius = all4(12);
				gi.style.bg = T("--background-mod-normal");
				gi.style.font = F(.Medium);
				gi.style.font_size = 14;
				gi.style.text_align = .Center;
				gi.style.text_color = T("--text-default");
				if g.icon != "" { set_remote_image(gi, guild_icon_url(g.id, g.icon, 80)); } else { gi.text = guild_initials(g.name); }
				spacer(.X, 12);
				col := ui.box("col");
				col.semantic_size = .[ui.fill(), ui.children()];
				col.layout_axis = .Y;
				{ ui.parent(col); defer ui.pop_parent();
					label(g.name, .Medium, 16, T("--interactive-text-active"), 20);
					if mg.nick != "" { label(mg.nick, .Normal, 14, T("--text-muted"), 18); }
				}
			}
			if sig.clicked {
				pf.user = 0;
				select_guild(mg.id);
			}
		}
	}
}

profile_mutual_friends :: (uid: dc.Snowflake, prof: Pf_Profile) {
	spacer(.Y, 8);
	if prof.friends.count == 0 {
		empty_state(ifx prof.friends_done || app.client == null then "No friends in common" else "Loading…");
		return;
	}
	for f: prof.friends {
		{ ui.id_scope(cast(u64)(f.id)); defer ui.pop_seed();
			r, sig := list_row("mf");
			{ ui.parent(r); defer ui.pop_parent();
				spacer(.X, 8);
				av := ui.box("av", .Draw_Background);
				av.semantic_size = .[ui.px(40), ui.px(40)];
				av.style.radius = all4(20);
				av.style.bg = T("--background-mod-normal");
				set_remote_image(av, ifx f.avatar != "" then dc.avatar_url(f.id, f.avatar, 80) else dc.default_avatar_url(f.id, "0"));
				spacer(.X, 12);
				col := ui.box("col");
				col.semantic_size = .[ui.fill(), ui.children()];
				col.layout_axis = .Y;
				{ ui.parent(col); defer ui.pop_parent();
					label(dc.user_name(store(), f.id, 0, ifx f.global_name != "" then f.global_name else f.username), .Medium, 16, T("--interactive-text-active"), 20);
					label(f.username, .Normal, 14, T("--text-muted"), 18);
				}
			}
			if sig.clicked { profile_full_open(f.id); }
		}
	}
}
#scope_export

// "Oct 26, 2026"
short_date :: (ms: s64) -> string {
	t := utc_calendar(local_ms(ms));
	return date_medium(t);
}

// ---- user context menu (right-click on a member / author) ----

// open_user_menu: right-click / "More" on a user. In a guild the menu loads the
// member's popout data (dc.open_user_context_menu); from a DM row only the note and
// the user command index (dm_row: fixture friend_add_context_menu).
// dm: the 1:1 DM whose row was right-clicked (0 elsewhere).
open_user_menu :: (uid: dc.Snowflake, at: ui.Vec2, dm: dc.Snowflake = 0) {
	pf.menu_user = uid;
	pf.menu_pos = at;
	pf.menu_dm = dm;
	if app.client == null || uid == 0 { return; }
	if dm { dc.open_dm_row_menu(app.client, uid); } else if app.view.guild != 0 { dc.open_user_context_menu(app.client, uid, app.view.guild); }
}

user_menu_open :: () -> bool { return pf.menu_user != 0; }

// Drawn after the profile popout (overlays()): a menu opened from a profile's
// "..." sits on top of it, and pressing outside the menu closes only the menu.
user_context_menu :: () {
	if pf.menu_user == 0 { return; }
	uid := pf.menu_user;
	s := store();
	items: [..]string;
	items.allocator = temp;
	dm := dc.channel_get(s, pf.menu_dm);
	if dm && dc.channel_unread(s, dm.id) { array_add(*items, "Mark As Read"); }
	array_add(*items, "Profile");
	ch := dc.channel_get(s, app.view.channel);
	if ch && !dm && !composer_blocked(ch) { array_add(*items, "Mention"); }
	rel := table_find_pointer(*s.relationships, uid);
	kind := ifx rel then rel.kind else .None;
	if uid != s.me && !dm { array_add(*items, "Message"); }
	if uid != s.me && !on_hosted() {
		if kind != .Blocked { array_add(*items, "Call"); }
		array_add(*items, "Add Note");
	}
	fn := friend_nick_menu_item(uid);
	if fn != "" { array_add(*items, fn); }
	if dm { array_add(*items, "Close DM"); }
	gdm_ch := dc.channel_get(s, app.view.channel);
	if gdm_ch && gdm_ch.kind == .Group_DM && gdm_ch.owner_id == s.me && uid != s.me && array_find(gdm_ch.recipient_ids, uid) { array_add(*items, "Remove From Group"); }
	if uid != s.me && !on_hosted() {
		if kind == .None || kind == .Implicit { array_add(*items, "Add Friend"); }
		if kind == .Friend { array_add(*items, "Remove Friend"); }
		if kind == .Incoming_Request { array_add(*items, "Accept Friend Request", "Ignore Friend Request"); }
		if kind == .Outgoing_Request { array_add(*items, "Cancel Friend Request"); }
		if kind != .Blocked { array_add(*items, ifx rel && rel.ignored then "Unignore" else "Ignore"); }
		array_add(*items, ifx kind == .Blocked then "Unblock" else "Block");
	}
	sn := server_nick_menu_item(uid);
	if sn != "" { array_add(*items, sn); }
	if uid == s.me && on_hosted() {
		array_add(*items, "Change Avatar");
		u := dc.user_get(s, uid);
		if u && u.avatar { array_add(*items, "Remove Avatar"); }
	}
	moderation_menu_items(uid, *items);
	if app.view.guild && dc.member_get(s, app.view.guild, uid) && roles_assignable(app.view.guild).count && (dc.guild_permissions(s, app.view.guild) & dc.PERM_MANAGE_ROLES) { array_add(*items, "Roles"); }
	array_add(*items, "Copy Username");
	if s.settings.developer_mode { array_add(*items, "Copy User ID"); }
	W :: cast(float32) 188;
	H := cast(float32) items.count * 32 + 16;
	p := pf.menu_pos;
	p.x = min(p.x, app.ui.window.x - W - 8);
	p.y = min(p.y, app.ui.window.y - H - 8);
	scrim := ui.box("umenu_scrim###umenu_scrim", .Clickable | .Floating_X | .Floating_Y | .Overlay);
	scrim.semantic_size = .[ui.px(app.ui.window.x), ui.px(app.ui.window.y)];
	if ui.signal(scrim).pressed {
		pf.menu_user = 0;
		return;
	}
	menu := ui.box("umenu###umenu", .Draw_Background | .Draw_Border | .Draw_Shadow | .Floating_X | .Floating_Y | .Overlay | .Clickable);
	menu.semantic_size = .[ui.px(W), ui.px(H)];
	menu.fixed_pos = p;
	menu.layout_axis = .Y;
	menu.style.bg = T("--background-surface-higher");
	menu.style.border_color = T("--border-subtle");
	menu.style.border = 1;
	menu.style.radius = all4(8);
	menu.style.shadow_color = .{0, 0, 0, 0.24};
	menu.style.shadow_blur = 16;
	ui.signal(menu);
	{ ui.parent(menu); defer ui.pop_parent();
		spacer(.Y, 8);
		for items {
			r := row(it, .Clickable | .Draw_Background | .Hot_Animation);
			r.semantic_size = .[ui.pct(1), ui.px(32)];
			r.style.radius = all4(4);
			r.style.bg_hot = T("--background-mod-normal");
			sig := ui.signal(r);
			{ ui.parent(r); defer ui.pop_parent();
				spacer(.X, 8);
				danger := begins_with(it, "Kick ") || begins_with(it, "Ban ") || begins_with(it, "Timeout ");
				label(it, .Medium, 14, ifx danger then T("--text-feedback-critical") else ifx sig.hovering then T("--interactive-text-active") else T("--interactive-text-default"), 18);
			}
			if sig.clicked && moderation_menu_click(uid, it) {
				pf.menu_user = 0;
			} else if sig.clicked {
				if it == {
				case "Mark As Read";
					mark_read_now(app.client, .[dm.id], ack_loc = 0);
				case "Remove From Group";
					// DELETE /channels/{id}/recipients/{user}; CHANNEL_RECIPIENT_REMOVE follows
					if net_action() dc.remove_group_recipient(app.client, gdm_ch.id, uid);
				case "Close DM";
					close_private_now(dm);
				case "Profile";
					profile_full_open(uid, app.view.guild);
				case "Roles";
					pf.roles_user, pf.roles_pos = uid, .{r.rect.x1 + 4, r.rect.y0};
				case "Mention";
					u := dc.user_get(s, uid);
					if u { ed := *chat_state(ch.id).editor; ui.editor_insert(ed, tprint("@% ", u.username)); }
				case "Message";
					open_dm_with(uid, "Context Menu");
				case "Call";
					// the DM's call, once the DM is open (a new one opens first: handle_results_of)
					app.pending_dm_call = true;
					if open_dm_with(uid, "Context Menu") { app.pending_dm_call = false; c := dc.channel_get(s, app.view.channel); if c dm_call_toggle(c); }
				case "Add Note";
					profile_full_open(uid, app.view.guild);
					pf.note_focus_next = true;
				case "Remove Friend"; #through; case "Ignore Friend Request"; #through; case "Cancel Friend Request"; #through; case "Unblock";
					rel_change(uid, .Remove, "ContextMenu");
				case "Block";
					rel_change(uid, .Block, "ContextMenu");
				case "Accept Friend Request";
					if req_begin(rel_req("Accept", uid)) { dc.accept_friend_request(app.client, uid); req_end(); }
				case "Ignore"; #through; case "Unignore";
					if net_action() dc.ignore_user(app.client, uid, it == "Ignore", "ContextMenu");
					if rel rel.ignored = it == "Ignore";
				case "Add Friend Nickname"; #through; case "Edit Friend Nickname";
					friend_nick_open(uid);
				case "Add Friend";
					if req_begin(rel_req("Add Friend", uid)) { dc.add_relationship(app.client, uid, "ContextMenu"); req_end(); } else { table_set(*s.relationships, uid, .{user_id = uid, kind = .Outgoing_Request}); } // offline (fixture) runs
				case "Change Nickname";
					server_nick_open(uid, app.view.guild);
				case "Change Avatar";
					paths := pick_files();
					if paths.count && net_action() { dc.edit_my_avatar(app.client, paths[0]); }
				case "Remove Avatar";
					if net_action() { dc.edit_my_avatar(app.client, ""); }
				case "Copy Username";
					u := dc.user_get(s, uid);
					if u != null { clipboard_set(u.username); }
				case "Copy User ID";
					clipboard_set(tprint("%", cast(u64) uid));
				}
				pf.menu_user = 0;
			}
		}
	}
	for * e: app.ui.events { if e.kind == .Key_Down && e.key == .Escape { pf.menu_user = 0; e.consumed = true; } }
}

// The roles we may give or take: not @everyone, not a bot's or integration's, below our highest (the
// owner: all), highest first.
roles_assignable :: (gid: dc.Snowflake) -> []*dc.Role {
	s := store();
	g := dc.guild_get(s, gid);
	out: [..]*dc.Role;
	out.allocator = temp;
	if !g return out;
	top := 0;
	for g.roles if array_find(dc.my_roles(s, gid), it.id) top = max(top, it.position);
	for * g.roles if it.id != gid && !it.managed && (g.owner_id == s.me || it.position < top) array_add(*out, it);
	quick_sort(out, (a: *dc.Role, b: *dc.Role) -> s64 { return b.position - a.position; });
	return out;
}

// The user menu's Roles: a checkbox per assignable role; a click adds or removes it (dc.set_member_role).
user_roles_popout :: () {
	if pf.roles_user == 0 return;
	s := store();
	m := dc.member_get(s, app.view.guild, pf.roles_user);
	roles := roles_assignable(app.view.guild);
	if !m || !roles.count || outside_pressed("roles_out") || escape_pressed() { pf.roles_user = 0; return; }
	W :: cast(float32) 220;
	h := min(cast(float32) roles.count * 32 + 16, 400);
	p := pf.roles_pos;
	p.x = min(p.x, app.ui.window.x - W - 8);
	p.y = min(p.y, app.ui.window.y - h - 8);
	menu := menu_panel("rolesmenu", p, W);
	menu.semantic_size[ui.Axis.Y] = ui.px(h);
	menu.flags |= .Scroll_Y | .Clip;
	ui.parent(menu); defer ui.pop_parent();
	spacer(.Y, 8);
	for r: roles {
		ui.id_scope(cast(u64) r.id); defer ui.pop_seed();
		has := array_find(m.roles, r.id);
		sig := menu_item("role", r.name, ifx has then .Check_On else .Check_Off);
		if sig.clicked && net_action() dc.set_member_role(app.client, app.view.guild, pf.roles_user, r.id, !has);
	}
	spacer(.Y, 8);
}

pf_reset_for_test :: () {pf = .{};}
pf_state_for_test :: () -> string {return tprint("% % %", pf.user, pf.tab, pf.menu_user);}

#scope_file
env_profile_done: bool;

