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
}
#scope_file

Pf_State :: struct {
	user: dc.Snowflake;
	guild: dc.Snowflake;
	tab: Pf_Tab;
	t: float32;
	profiles: Map(dc.Snowflake, Pf_Profile);
	menu_user: dc.Snowflake; // user context menu
	menu_pos: ui.Vec2;
}

pf: Pf_State;
#scope_export

profile_full_open :: (uid: dc.Snowflake, guild_id: dc.Snowflake = 0) {
	pf.user = uid;
	pf.guild = guild_id;
	pf.tab = .About;
	pf.t = 0;
	app.profile_user = 0;
	if app.client != null {
		bot := false;
		{ u := dc.user_get(store(), uid);
		if u != null { bot = u.bot; } }
		dc.profile_modal_fetch(app.client, uid, guild_id, bot);
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
	p, ok := map_find_ptr(*pf.profiles, uid);
	if !ok {
		at(*pf.profiles, uid).* = .{};
		p = at(*pf.profiles, uid);
	}
	if !r.ok { return; }
	if r.op == {
	case .Profile_Modal;
		m := dc.vmap(r.body);
		u := dc.fmap(m, "user");
		prof := dc.fmap(m, "user_profile");
		p.loaded = true;
		delete(p.banner);
		delete(p.bio);
		delete(p.pronouns);
		delete(p.guild_joined);
		p.banner = clone(dc.fstr(u, "banner"));
		p.bio = clone(dc.fstr(prof, "bio"));
		p.pronouns = clone(dc.fstr(prof, "pronouns"));
		if dc.vhas(u, "accent_color") && !dc.vis_null(dc.vget(u, "accent_color")) { p.accent, p.has_accent = cast(u32) dc.fint(u, "accent_color"), true; }
		p.guild_joined = clone(dc.fstr(dc.fmap(m, "guild_member"), "joined_at"));
		clear(*p.mutual_guilds);
		for gv: dc.flist(m, "mutual_guilds") {
			gm := dc.vmap(gv);
			append(*p.mutual_guilds, Pf_Mutual_Guild.{dc.fsnow(gm, "id"), clone(dc.fstr(gm, "nick"))});
		}
		p.mutual_count = cast(int)(dc.fint(m, "mutual_friends_count"));
	case .Mutual_Friends;
		p.friends_done = true;
		clear(*p.friends);
		for fv: dc.vlist(r.body) {
			f := dc.vmap(fv);
			append(*p.friends, Pf_Friend.{dc.fsnow(f, "id"), clone(dc.fstr(f, "username")), clone(dc.fstr(f, "global_name")), clone(dc.fstr(f, "avatar"))});
		}
		p.mutual_count = len(p.friends);
	}
}

// Overlay entry (views.odin overlays()).
profile_full_overlay :: () {
	defer user_context_menu();
	if !static_debug_done3 && app.view.channel != 0 {
		static_debug_done3 = true;
		{ v := os.get_env("FASTCORD_PROFILE", temp);
		if v != "" {
			id, _ := strconv.parse_u64(v);
			if v == "me" { id = cast(u64)(store().me); }
			if v == "friend" { for rel, uid: store().relationships { if rel.kind == .Friend { id = cast(u64)(uid); } } }
			profile_full_open(cast(dc.Snowflake)(id), app.view.guild);
		} }
	}
	if pf.user == 0 { return; }
	s := store();
	uid := pf.user;
	u := dc.user_get(s, uid);
	if u == null {
		pf.user = 0;
		return;
	}
	prof := get(pf.profiles, uid);
	ui.animate(*pf.t, 1, 25);
	win := app.ui.window;
	scrim := ui.box("pf_scrim###pf_scrim", .Draw_Background | .Clickable | .Floating_X | .Floating_Y | .Overlay);
	scrim.semantic_size = .[ui.px(win.x), ui.px(win.y)];
	scrim.style.bg = with_alpha(T("--background-scrim"), pf.t);
	if ui.signal(scrim).clicked {
		pf.user = 0;
		return;
	}
	banner_url := "";
	banner_hash := ifx prof.banner != "" then prof.banner else u.banner;
	if banner_hash != "" { banner_url = dc.banner_url(uid, banner_hash, 600); }
	banner_h: float32 = ifx banner_url != "" then cast(float32) PF_BANNER_H else cast(float32) PF_BANNER_H_PLAIN;
	body_h := min(win.y - 80 - banner_h - 140 - PF_TAB_H, PF_BODY_MIN_H);
	total_h := banner_h + 140 + PF_TAB_H + body_h;
	x := (win.x - PF_W) / 2;
	y := (win.y - total_h) / 2;
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
				av := avatar_with_status("av", uid, PF_AVATAR, m.style.bg);
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
					if pron != "" { label(fmt.tprintf(" • %s", pron), .Normal, 16, T("--text-default"), 20); }
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

// Message (friends / others) or Add Friend, plus More — top right under the banner.
profile_actions :: (uid: dc.Snowflake) {
	s := store();
	if uid == s.me { return; }
	rel, has_rel := map_find(s.relationships, uid);
	friend := has_rel && rel.kind == .Friend;
	bar := row("actions", .Floating_X | .Floating_Y);
	bar.semantic_size = .[ui.children(), ui.px(32)];
	w: float32 = cast(float32) (ifx friend then 110 + 8 + 32 else 110 + 8 + 120 + 8 + 32);
	bar.fixed_pos = .{PF_W - PF_PAD - w, PF_PAD};
	bar.style.child_gap = 8;
	{ ui.parent(bar); defer ui.pop_parent();
		if !friend {
			pending := has_rel && rel.kind == .Outgoing_Request;
			add := action_button(ifx pending then "Pending" else "Add Friend", "user-plus", 120, false);
			if add && !pending && net_action() { dc.add_relationship(app.client, uid, "User Profile"); }
		}
		if action_button("Message", "chat", 110, true) && net_action() {
			{ existing := dc.open_dm(app.client, uid, "User Profile");
			if existing != 0 { select_channel(0, existing); } else { app.pending_dm_user = uid; } }
			pf.user = 0;
		}
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

action_button :: (text: string, icon_name: string, w: float32, primary: bool) -> bool {
	b := row(text, .Clickable | .Draw_Background | .Hot_Animation);
	b.semantic_size = .[ui.px(w), ui.px(32)];
	b.style.radius = all4(8);
	b.style.bg = ifx primary then T("--background-brand") else T("--control-secondary-background-default");
	b.style.bg_hot = ifx primary then with_alpha(T("--background-brand"), 0.85) else T("--control-secondary-background-hover");
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
				n := len(prof.mutual_guilds);
				text = ifx n == 1 then "1 Mutual Server" else (ifx n > 0 then fmt.tprintf("%d Mutual Servers", n) else "Mutual Servers");
			case .Mutual_Friends;
				n := prof.mutual_count;
				text = ifx n == 1 then "1 Mutual Friend" else (ifx n > 0 then fmt.tprintf("%d Mutual Friends", n) else "Mutual Friends");
			}
			sel := pf.tab == t;
			b := ui.box(fmt.tprintf("%s##tab%d", text, cast(int)(t)), .Clickable);
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
				if t == .Mutual_Friends && app.client != null && !get(pf.profiles, uid).friends_req {
					p := at(*pf.profiles, uid);
					p.friends_req = true;
					dc.mutual_friends_fetch(app.client, uid);
				}
			}
			spacer(.X, 32);
		}
	}
}

section_title :: (text: string) {
	r := row(text);
	r.semantic_size = .[ui.pct(1), ui.px(20)];
	{ ui.parent(r); defer ui.pop_parent();
		spacer(.X, PF_PAD + 8);
		label(text, .Semibold, 12, T("--text-strong"), 16);
	}
	spacer(.Y, 6);
}

// "Oct 26, 2026"
short_date :: (ms: s64) -> string {
	t := time.unix(ms / 1000, 0);
	y, mo, d := time.date(t);
	MONTHS := string.["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
	return fmt.tprintf("%s %d, %d", MONTHS[cast(int)(mo) - 1], d, y);
}

iso_ms :: (s: string) -> s64 {
	t, _, consumed := time.iso8601_to_time_and_offset(s);
	if consumed == 0 { return 0; }
	return time.time_to_unix_nano(t) / 1000000;
}

profile_about :: (uid: dc.Snowflake, u: *dc.User, prof: Pf_Profile) {
	spacer(.Y, PF_PAD);
	bio := ifx prof.bio != "" then prof.bio else u.bio;
	if bio != "" {
		section_title("About Me");
		for blk, bi: md_parse(bio) {
			w := row(fmt.tprintf("bio%d", bi));
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
	section_title("Member Since");
	ms := row("since");
	ms.semantic_size = .[ui.pct(1), ui.px(20)];
	{ ui.parent(ms); defer ui.pop_parent();
		spacer(.X, PF_PAD + 8);
		icon("dlogo", "clyde", 16, T("--interactive-icon-default"));
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
			{ g := dc.guild_get(store(), pf.guild);
			if g != null {
				if g.icon != "" { set_remote_image(gi, dc.guild_icon_url(g.id, g.icon, 32)); } else { gi.text = guild_initials(g.name); }
			} }
			spacer(.X, 8);
			label(short_date(iso_ms(prof.guild_joined)), .Normal, 14, T("--text-default"), 18);
		}
	}
	spacer(.Y, 16);
	if uid != store().me && !streamer_hide_personal() {
		section_title("Note");
		nr := row("note");
		nr.semantic_size = .[ui.pct(1), ui.px(18)];
		{ ui.parent(nr); defer ui.pop_parent();
			spacer(.X, PF_PAD + 8);
			label("Click to add a note", .Normal, 12, T("--text-muted"), 16);
		}
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
	if len(prof.mutual_guilds) == 0 {
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
				if g.icon != "" { set_remote_image(gi, dc.guild_icon_url(g.id, g.icon, 80)); } else { gi.text = guild_initials(g.name); }
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
	if len(prof.friends) == 0 {
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

// ---- user context menu (right-click on a member / author) ----

// open_user_menu: right-click / "More" on a user. In a guild the menu loads the
// member's popout data (dc.open_user_context_menu); from a DM row only the note and
// the user command index (dm_row: fixture friend_add_context_menu).
open_user_menu :: (uid: dc.Snowflake, at: ui.Vec2, dm_row := false) {
	pf.menu_user = uid;
	pf.menu_pos = at;
	if app.client == null || uid == 0 { return; }
	if dm_row { dc.open_dm_row_menu(app.client, uid); } else if app.view.guild != 0 { dc.open_user_context_menu(app.client, uid, app.view.guild); }
}
#scope_file

user_context_menu :: () {
	if pf.menu_user == 0 { return; }
	uid := pf.menu_user;
	s := store();
	items := make_dynamic(string, 0, 0, temp);
	append(*items, "Profile");
	if uid != s.me { append(*items, "Message"); }
	{ fn := friend_nick_menu_item(uid);
	if fn != "" { append(*items, fn); } }
	if uid != s.me {
		_, has_rel := map_find(s.relationships, uid);
		if !has_rel || get(s.relationships, uid).kind == .None || get(s.relationships, uid).kind == .Implicit { append(*items, "Add Friend"); }
	}
	{ sn := server_nick_menu_item(uid);
	if sn != "" { append(*items, sn); } }
	append(*items, "Copy Username", "Copy User ID");
	W :: cast(float32)(188);
	H := cast(float32)(len(items)) * 32 + 16;
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
		for it_: items {
			r := row(it_, .Clickable | .Draw_Background | .Hot_Animation);
			r.semantic_size = .[ui.pct(1), ui.px(32)];
			r.style.radius = all4(4);
			r.style.bg_hot = T("--background-mod-normal");
			sig := ui.signal(r);
			{ ui.parent(r); defer ui.pop_parent();
				spacer(.X, 8);
				label(it_, .Medium, 14, ifx sig.hovering then T("--interactive-text-active") else T("--interactive-text-default"), 18);
			}
			if sig.clicked {
				if it_ == {
				case "Profile";
					profile_full_open(uid, app.view.guild);
				case "Message";
					if net_action() {
						{ existing := dc.open_dm(app.client, uid, "Context Menu");
						if existing != 0 { select_channel(0, existing); } else { app.pending_dm_user = uid; } }
					}
				case "Add Friend Nickname"; #through; case "Edit Friend Nickname";
					friend_nick_open(uid);
				case "Add Friend";
					if net_action() { dc.add_relationship(app.client, uid, "ContextMenu"); } else { at(*s.relationships, uid).* = .{user_id = uid, kind = .Outgoing_Request}; } // offline (fixture) runs
				case "Change Nickname";
					server_nick_open(uid, app.view.guild);
				case "Copy Username";
					{ u := dc.user_get(s, uid);
					if u != null { clipboard_set(u.username); } }
				case "Copy User ID";
					clipboard_set(fmt.tprint(cast(u64)(uid)));
				}
				pf.menu_user = 0;
			}
		}
	}
	for e: app.ui.events { if e.kind == .Key_Down && e.key == .Escape { pf.menu_user = 0; } }
}
#scope_export

pf_reset_for_test :: () {pf = .{};}
pf_state_for_test :: () -> string {return fmt.tprint(pf.user, pf.tab, pf.menu_user);}

#scope_file static_debug_done3: bool; #scope_export

