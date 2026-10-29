// Server Settings: the full-window layer the server menu opens, as the official client's GuildSettings
// (bundle `generateSections`): a sidebar of sections under the server's name and the Expression, People,
// Apps and Moderation headers, then Delete Server; ESC or Escape closes; an unsaved-changes bar with
// Reset / Save Changes holds the page (no closing or switching sections until it's saved or reset).
// Each section shows only to members with the permission it needs. Hosted servers add a Host group.
//
// Adding a page: give it a Server_Section (in sidebar order), a label in section_label, its permission
// in section_visible, and a case in page_body (and form_dirty / form_reset / form_save when it has a
// form). A section with no case in page_body stays out of the sidebar.

Server_Section :: enum u8 {
	None;
	Profile;
	Tag;
	Engagement;
	// Expression
	Emoji;
	Stickers;
	Soundboard;
	// People
	Members;
	Roles;
	Invites;
	Access;
	// Apps
	Integrations;
	// Moderation
	Safety;
	Audit_Log;
	Bans;
	// Community
	Community;
	Onboarding;
	// Host: hosted servers only (the owner's management of the host itself)
	Host_Storage;
	Host_Attachments;
	Host_Limits;
	Host_Backups;
	Host_Network;
	Host_Sessions;
	Host_Info;
	// last group
	Templates;
	Delete;
}

can_open_server_settings :: (gid: dc.Snowflake) -> bool {
	return (dc.guild_permissions(store(), gid) & SETTINGS_PERMS) != 0;
}

server_settings_open :: (gid: dc.Snowflake, section := Server_Section.None) {
	g := dc.guild_get(store(), gid);
	if g == null return;
	server_settings_close();
	ss.guild = gid;
	ss.open = true;
	ss.section = .None;
	for i: 1..cast(int) Server_Section.Delete {
		it := cast(Server_Section) i;
		if (section == .None || it == section) && section_shown(g, it) {
			ss.section = it;
			break;
		}
	}
	if app.client != null dc.open_guild_settings(app.client, gid, section_pane(ss.section));
	section_enter(g);
}

server_settings_is_open :: () -> bool { return ss.open; }

server_settings_close :: () {
	ss.open = false;
	ss.busy, ss.icon_busy = false, false;
	ss.dd = "";
	for * ss.replies dc.feature_result_free(it);
	for * ss.loading it.* = false;
	ss_error("");
	app.ui.focus = 0;
}

server_settings_reset_for_test :: () {
	server_settings_close();
	ui.editor_destroy(*ss.name);
	ui.editor_destroy(*ss.desc);
	for * ss.traits ui.editor_destroy(it);
	free(ss.error);
	ss = .{};
}

// server_settings_receive: finished requests the pages sent.
server_settings_receive :: (r: *dc.Feature_Result) {
	if !ss.open || r.channel_id != ss.guild return;
	app.ui.animating = true;
	g := dc.guild_get(store(), ss.guild);
	if !g return;
	if r.op == .Guild_Edit {
		ss.icon_busy = false;
		if r.ok return; // GUILD_UPDATE shows it
		if r.status == -1 ss_error("That file couldn't be read. Server icons must be PNG, JPEG, GIF or WEBP images.");
		else if r.status == -2 ss_error("That image is too large. Server icons must be under 512 KB.");
		else ss_error(settings_result_error(r));
		return;
	}
	req := cast(Req) r.tag;
	if req == .Save || req == .Save_Widget {
		if req == .Save && ss.save_widget && r.ok return; // the widget's reply ends the save
		ss.busy = false;
		if !r.ok { ss_error(settings_result_error(r)); return; }
		if ss.section == .Profile && r.body.kind == .Map keep_reply(.Profile, r); // the saved profile
		if req == .Save_Widget && r.body.kind == .Map keep_reply(.Widget, r);
		form_reset(g);
		return;
	}
	if req >= .COUNT return;
	keep_reply(req, r);
	form_reset(g);
}

server_settings_layer :: () {
	if !ss.open return;
	g := dc.guild_get(store(), ss.guild);
	if g == null || !can_open_server_settings(g.id) || !section_shown(g, ss.section) {
		server_settings_close();
		return;
	}
	close, save, reset := false, false, false;
	go := Server_Section.None;
	dirty := form_dirty(g);
	page := row("serversettings", .Draw_Background | .Floating_X | .Floating_Y | .Overlay | .Clickable | .Clip);
	page.semantic_size = .[ui.px(app.ui.window.x), ui.px(app.ui.window.y)];
	page.cross_align = .Start;
	page.style.bg = T("--background-base-low");
	ui.signal(page);
	side_w := max(240.0, app.ui.window.x * 0.29);
	{ ui.parent(page); defer ui.pop_parent();
		nav := ui.box("nav", .Draw_Background | .Scroll_Y | .Clip);
		nav.semantic_size = .[ui.px(side_w), ui.pct(1)];
		nav.layout_axis = .Y;
		nav.style.bg = T("--background-base-lowest");
		nav.scrollbar = .Auto;
		ui.signal(nav);
		{ ui.parent(nav); defer ui.pop_parent();
			spacer(.Y, 60);
			wrap := row("wrap");
			wrap.semantic_size = .[ui.pct(1), ui.children()];
			wrap.cross_align = .Start;
			{ ui.parent(wrap); defer ui.pop_parent();
				filler(.X);
				col := ui.box("col");
				col.semantic_size = .[ui.px(218), ui.children()];
				col.layout_axis = .Y;
				{ ui.parent(col); defer ui.pop_parent();
					group := -1;
					for i: 1..cast(int) Server_Section.Delete {
						sec := cast(Server_Section) i;
						if !section_shown(g, sec) continue;
						grp := section_group(sec);
						if grp != group {
							if group >= 0 nav_divider(sec);
							head := ifx grp == 0 then (ifx g.name then g.name else "Server Settings") else GROUP_NAMES[grp];
							if head nav_header(sec, head);
							group = grp;
						}
						if nav_item(sec, g) && !dirty go = sec;
					}
					spacer(.Y, 60);
				}
				spacer(.X, 6);
			}
		}
		content := ui.box("content", .Scroll_Y | .Clip);
		content.semantic_size = .[ui.fill(), ui.pct(1)];
		content.layout_axis = .Y;
		content.scrollbar = .Auto;
		ui.signal(content);
		form_w := clamp(app.ui.window.x - side_w - 40 - 140, 300, 740);
		{ ui.parent(content); defer ui.pop_parent();
			spacer(.Y, 60);
			body := row("body");
			body.semantic_size = .[ui.pct(1), ui.children()];
			body.cross_align = .Start;
			{ ui.parent(body); defer ui.pop_parent();
				spacer(.X, 40);
				col := ui.box(tprint("form_%", ss.section));
				col.semantic_size = .[ui.px(form_w), ui.children()];
				col.layout_axis = .Y;
				{ ui.parent(col); defer ui.pop_parent();
					label(section_label(ss.section), .Semibold, 20, T("--text-strong"), 24);
					spacer(.Y, 20);
					if page_body(g, ss.section, form_w) save = true;
					if ss.error != "" {
						spacer(.Y, 16);
						set_para("err", ss.error, .Normal, 14, 18, T("--text-feedback-critical"));
					}
					spacer(.Y, 120);
				}
				spacer(.X, 24);
				if esc_button() close = true;
			}
		}
		if dirty {
			bw := min(700.0, app.ui.window.x - side_w - 40);
			bar := row("savebar", .Draw_Background | .Draw_Shadow | .Floating_X | .Floating_Y | .Clickable);
			bar.semantic_size = .[ui.px(bw), ui.px(52)];
			bar.fixed_pos = .{side_w + 20, app.ui.window.y - 52 - 20};
			bar.style.bg = T("--background-surface-highest");
			bar.style.radius = all4(8);
			bar.style.shadow_color = .{0, 0, 0, 0.3};
			bar.style.shadow_blur = 12;
			bar.style.shadow_offset = .{0, 4};
			ui.signal(bar);
			{ ui.parent(bar); defer ui.pop_parent();
				spacer(.X, 16);
				label("Careful — you have unsaved changes!", .Medium, 16, T("--text-strong"), 20);
				filler(.X);
				if set_button("Reset##reset", .Link, !ss.busy, 32) reset = true;
				spacer(.X, 8);
				if set_button(ifx ss.busy then "Saving...##save" else "Save Changes##save", .Positive, !ss.busy, 32) save = true;
				spacer(.X, 12);
			}
		}
	}
	if ss.dd {
		dropdown_list();
		if adm_escape() ss.dd = "";
	}
	if !close && !dirty && (adm_escape() || ss.field_escape) close = true;
	ss.field_escape = false; // with unsaved changes the client keeps the page
	if close && !dirty {
		server_settings_close();
		return;
	}
	if reset form_reset(g);
	if go != .None && go != ss.section {
		from := ss.section;
		ss.section = go;
		ss_error("");
		ss.dd = "";
		if app.client != null dc.guild_settings_pane(app.client, section_pane(from), section_pane(go), g.id);
		section_enter(g);
	}
	if save && dirty && !ss.busy && net_action() form_save(g);
}

#scope_file

SETTINGS_PERMS :: dc.PERM_MANAGE_GUILD | dc.PERM_MANAGE_ROLES | dc.PERM_ADMINISTRATOR | dc.PERM_BAN_MEMBERS | dc.PERM_MANAGE_NICKNAMES
	| dc.PERM_CREATE_GUILD_EXPRESSIONS | dc.PERM_MANAGE_GUILD_EXPRESSIONS | dc.PERM_MANAGE_WEBHOOKS | dc.PERM_VIEW_AUDIT_LOG | dc.PERM_VIEW_GUILD_ANALYTICS;

GROUP_NAMES :: string.["", "Expression", "People", "Apps", "Moderation", "", "Host", ""];

// Requests whose replies the pages read (kept with their arenas until replaced or closed), and saves.
Req :: enum u8 {
	Profile; // GET /guilds/{id}/profile
	Widget; // GET /guilds/{id}/widget
	COUNT;
	Save :: 100; // a page's Save Changes
	Save_Widget;
}

ss: struct {
	open: bool;
	guild: dc.Snowflake;
	section: Server_Section;
	busy: bool; // a save is in flight
	icon_busy: bool; // Server Profile: an icon upload or removal is in flight
	error: string; // heap
	field_escape: bool; // a page's field took Escape this frame
	replies: [Req.COUNT]dc.Feature_Result;
	loading: [Req.COUNT]bool;
	// Server Profile
	name: ui.Editor;
	desc: ui.Editor;
	traits: [5]ui.Editor;
	brand: string; // "#rrggbb" or "" (static: BRAND_COLORS, or the profile reply's arena)
	private: bool;
	// Engagement
	eng: dc.Engagement_Form;
	widget_on: bool;
	widget_channel: dc.Snowflake;
	save_widget: bool; // the save in flight also saves the widget
	// The open select (dropdown_list): its id, anchor, this frame's options, and the pick it made.
	dd: string;
	dd_anchor: ui.Rect;
	dd_options: []string;
	dd_current: int;
	dd_pick: int = -1;
	dd_pick_id: string;
};

keep_reply :: (req: Req, r: *dc.Feature_Result) {
	ss.loading[req] = false;
	dc.feature_result_free(*ss.replies[req]);
	ss.replies[req] = r.*;
	r.arena = null; // ours now
}

reply :: (req: Req) -> *dc.Feature_Result {
	r := *ss.replies[req];
	return ifx r.arena != null && r.ok then r else null;
}

load :: (g: *dc.Guild, req: Req, path: string) {
	if ss.loading[req] || !net_action() return;
	ss.loading[req] = true;
	dc.guild_settings_call(app.client, g.id, xx req, "GET", path);
}

// A section shown: load what its page reads.
section_enter :: (g: *dc.Guild) {
	if ss.section == {
	case .Profile;
		load(g, .Profile, tprint("/guilds/%/profile", g.id));
	case .Engagement;
		load(g, .Widget, tprint("/guilds/%/widget", g.id));
	}
	form_reset(g);
}

ss_error :: (msg: string) {
	free(ss.error);
	ss.error = copy_string(msg);
}

section_group :: (s: Server_Section) -> int {
	if s <= .Engagement return 0;
	if s <= .Soundboard return 1;
	if s <= .Access return 2;
	if s <= .Integrations return 3;
	if s <= .Bans return 4;
	if s <= .Onboarding return 5;
	if s <= .Host_Info return 6;
	return 7;
}

section_label :: (s: Server_Section) -> string {
	if s == {
	case .Profile; return "Server Profile";
	case .Tag; return "Server Tag";
	case .Engagement; return "Engagement";
	case .Emoji; return "Emoji";
	case .Stickers; return "Stickers";
	case .Soundboard; return "Soundboard";
	case .Members; return "Members";
	case .Roles; return "Roles";
	case .Invites; return "Invites";
	case .Access; return "Access";
	case .Integrations; return "Integrations";
	case .Safety; return "Safety Setup";
	case .Audit_Log; return "Audit Log";
	case .Bans; return "Bans";
	case .Community; return "Enable Community";
	case .Onboarding; return "Onboarding";
	case .Host_Storage; return "Storage";
	case .Host_Attachments; return "Attachments";
	case .Host_Limits; return "Limits";
	case .Host_Backups; return "Backups";
	case .Host_Network; return "Network";
	case .Host_Sessions; return "Sessions";
	case .Host_Info; return "Server Info";
	case .Templates; return "Server Template";
	case .Delete; return "Delete Server";
	}
	return "";
}

// The pane name science's settings_pane_viewed gives each section (the client's GuildSettingsSections).
section_pane :: (s: Server_Section) -> string {
	if s == {
	case .Profile; return "PROFILE";
	case .Tag; return "TAG";
	case .Engagement; return "ENGAGEMENT";
	case .Emoji; return "EMOJI";
	case .Stickers; return "STICKERS";
	case .Soundboard; return "SOUNDBOARD";
	case .Members; return "MEMBERS";
	case .Roles; return "ROLES";
	case .Invites; return "INVITES";
	case .Access; return "ACCESS";
	case .Integrations; return "INTEGRATIONS";
	case .Safety; return "MODERATION";
	case .Audit_Log; return "AUDIT_LOG";
	case .Bans; return "BANS";
	case .Community; return "COMMUNITY";
	case .Onboarding; return "ONBOARDING";
	case .Templates; return "GUILD_TEMPLATES";
	}
	return ""; // Host sections: hosted servers send no science
}

// Whether the member may see a section (the client's predicates) and fastcord has its page.
section_shown :: (g: *dc.Guild, s: Server_Section) -> bool {
	if !page_exists(s) return false;
	p := dc.guild_permissions(store(), g.id);
	has :: (p: u64, f: u64) -> bool #expand { return (p & f) != 0; }
	owner := g.owner_id == store().me;
	if s == {
	case .Profile; #through;
	case .Engagement;
		return has(p, dc.PERM_MANAGE_GUILD);
	case .Tag;
		return has(p, dc.PERM_MANAGE_GUILD) && dc.guild_has_feature(g, "GUILD_TAGS");
	case .Emoji; #through; case .Stickers; #through; case .Soundboard;
		return has(p, dc.PERM_MANAGE_GUILD_EXPRESSIONS | dc.PERM_CREATE_GUILD_EXPRESSIONS);
	case .Members;
		return has(p, dc.PERM_MANAGE_GUILD | dc.PERM_MANAGE_ROLES | dc.PERM_KICK_MEMBERS | dc.PERM_BAN_MEMBERS | dc.PERM_MODERATE_MEMBERS | dc.PERM_MANAGE_NICKNAMES);
	case .Roles;
		return has(p, dc.PERM_MANAGE_ROLES);
	case .Invites; #through; case .Access; #through; case .Safety; #through; case .Community; #through; case .Onboarding; #through; case .Templates;
		return has(p, dc.PERM_MANAGE_GUILD);
	case .Integrations;
		return has(p, dc.PERM_MANAGE_GUILD | dc.PERM_MANAGE_WEBHOOKS);
	case .Audit_Log;
		return has(p, dc.PERM_VIEW_AUDIT_LOG);
	case .Bans;
		return has(p, dc.PERM_BAN_MEMBERS | dc.PERM_VIEW_AUDIT_LOG);
	case .Delete;
		return owner;
	}
	return on_hosted() && owner; // Host
}

// The sections fastcord has a page for (see the note at the top).
page_exists :: (s: Server_Section) -> bool {
	if s == {
	case .Profile; #through; case .Engagement; #through; case .Soundboard;
		return true;
	}
	return false;
}

// page_body draws a section's page into the form column; true asks to save (Enter in a field).
page_body :: (g: *dc.Guild, s: Server_Section, w: float32) -> bool {
	if s == {
	case .Profile;
		return profile_page(g, w);
	case .Engagement;
		engagement_page(g);
	case .Soundboard;
		sound_settings_page(g, w); // view_server_soundboard.jai
	}
	return false;
}

form_dirty :: (g: *dc.Guild) -> bool {
	if ss.section == {
	case .Profile;
		r := reply(.Profile);
		if !r return false;
		a, b := dc.guild_profile_form(r.body), profile_form(r);
		if a.name != b.name || a.description != b.description || a.brand_color != b.brand_color || a.visibility != b.visibility return true;
		for a.traits if it.label != b.traits[it_index].label return true;
	case .Engagement;
		return engagement_dirty(g) || widget_dirty();
	}
	return false;
}

engagement_dirty :: (g: *dc.Guild) -> bool {
	base := dc.engagement_form_of(g);
	return memcmp(*ss.eng, *base, size_of(dc.Engagement_Form)) != 0;
}

widget_dirty :: () -> bool {
	w := reply(.Widget);
	return w && (ss.widget_on != dc.fbool(dc.vmap(w.body), "enabled") || ss.widget_channel != dc.fsnow(dc.vmap(w.body), "channel_id"));
}

form_reset :: (g: *dc.Guild) {
	ss_error("");
	r := reply(.Profile);
	if r {
		f := dc.guild_profile_form(r.body);
		ui.editor_set_text(*ss.name, f.name);
		ui.editor_set_text(*ss.desc, f.description);
		for f.traits ui.editor_set_text(*ss.traits[it_index], it.label);
		ss.brand = f.brand_color;
		ss.private = f.visibility == 2;
	}
	ss.eng = dc.engagement_form_of(g);
	w := reply(.Widget);
	if w {
		ss.widget_on = dc.fbool(dc.vmap(w.body), "enabled");
		ss.widget_channel = dc.fsnow(dc.vmap(w.body), "channel_id");
	}
}

// The Server Profile form as edited, on top of the loaded profile.
profile_form :: (r: *dc.Feature_Result) -> dc.Guild_Profile_Form {
	f := dc.guild_profile_form(r.body);
	f.name = trim(ui.editor_text(*ss.name));
	f.description = ui.editor_text(*ss.desc);
	for * f.traits it.label = trim(ui.editor_text(*ss.traits[it_index]));
	f.brand_color = ss.brand;
	if f.visibility || ss.private f.visibility = ifx ss.private then 2 else 1;
	return f;
}

form_save :: (g: *dc.Guild) {
	if ss.section == {
	case .Profile;
		r := reply(.Profile);
		if !r return;
		f := profile_form(r);
		if f.name.count < 2 || f.name.count > 100 {
			ss_error("Server name must be between 2 and 100 characters.");
			return;
		}
		ss.busy = true;
		ss_error("");
		dc.guild_settings_call(app.client, g.id, xx Req.Save, "PATCH", tprint("/guilds/%/profile", g.id), dc.guild_profile_body(f));
	case .Engagement;
		ss.busy = true;
		ss_error("");
		ss.save_widget = widget_dirty();
		if engagement_dirty(g) dc.guild_settings_call(app.client, g.id, xx Req.Save, "PATCH", tprint("/guilds/%", g.id), dc.engagement_body(ss.eng));
		if ss.save_widget dc.guild_settings_call(app.client, g.id, xx Req.Save_Widget, "PATCH", tprint("/guilds/%/widget", g.id), dc.widget_body(ss.widget_on, ss.widget_channel));
	}
}

// ---- sidebar ----

nav_header :: (s: Server_Section, text: string) {
	r := row(tprint("hdr_%", s));
	r.semantic_size = .[ui.pct(1), ui.px(28)];
	{ ui.parent(r); defer ui.pop_parent();
		spacer(.X, 10);
		label(ellipsize(text, .Bold, 12, 190), .Bold, 12, T("--text-muted"), 16);
	}
}

nav_divider :: (s: Server_Section) {
	spacer(.Y, 8);
	d := ui.box(tprint("div_%", s), .Draw_Background);
	d.semantic_size = .[ui.pct(1), ui.px(1)];
	d.style.bg = T("--border-subtle");
	spacer(.Y, 8);
}

// One sidebar row; true when clicked. Delete Server is red with a trash icon.
nav_item :: (s: Server_Section, g: *dc.Guild) -> bool {
	sel := s == ss.section;
	r := row(tprint("nav_%", s), .Clickable | .Draw_Background | .Hot_Animation);
	r.semantic_size = .[ui.pct(1), ui.px(32)];
	r.style.radius = all4(6);
	r.style.bg = ifx sel then T("--background-mod-normal") else .{};
	r.style.bg_hot = ifx sel then r.style.bg else T("--background-mod-subtle");
	r.hover_cursor = .Pointer;
	sig := ui.signal(r);
	danger := s == .Delete;
	c := ifx danger then T("--text-feedback-critical") else ifx sel || sig.hovering then T("--interactive-text-active") else T("--interactive-text-default");
	{ ui.parent(r); defer ui.pop_parent();
		spacer(.X, 10);
		label(section_label(s), .Medium, 16, c, 20);
		filler(.X);
		if danger icon("trash", "trash", 16, c);
		spacer(.X, 10);
	}
	spacer(.Y, 2);
	return sig.clicked;
}

// The circled X with "ESC" under it; true when clicked.
esc_button :: () -> bool {
	cc := ui.box("closecol");
	cc.semantic_size = .[ui.px(36), ui.children()];
	cc.layout_axis = .Y;
	ui.parent(cc); defer ui.pop_parent();
	xb := ui.box("close", .Clickable | .Draw_Border);
	xb.semantic_size = .[ui.px(36), ui.px(36)];
	xb.style.radius = all4(18);
	xb.style.border = 2;
	xb.style.border_color = T("--interactive-icon-default");
	xb.hover_cursor = .Pointer;
	xs := ui.signal(xb);
	{ ui.parent(xb); defer ui.pop_parent();
		i := icon("x", "x-large", 18, ifx xs.hovering then T("--interactive-icon-hover") else T("--interactive-icon-default"));
		i.flags |= .Floating_X | .Floating_Y;
		i.fixed_pos = .{7, 7};
	}
	spacer(.Y, 8);
	er := row("esc");
	er.semantic_size = .[ui.pct(1), ui.px(16)];
	{ ui.parent(er); defer ui.pop_parent();
		filler(.X);
		label("ESC", .Semibold, 13, T("--text-muted"), 16);
		filler(.X);
	}
	return xs.clicked;
}

// Small field title ("Name") above an input.
field_title :: (text: string) {
	label(text, .Semibold, 16, T("--text-strong"), 20);
	spacer(.Y, 8);
}

// ---- widgets shared by the pages ----

page_subtitle :: (text: string) {
	set_para("subtitle", text, .Normal, 14, 18, T("--text-default"));
	spacer(.Y, 24);
}

section_heading :: (id: string, title: string, help := "") {
	label(title, .Semibold, 16, T("--text-strong"), 20);
	if help {
		spacer(.Y, 4);
		set_para(tprint("%_help", id), help, .Normal, 14, 18, T("--text-muted"));
	}
	spacer(.Y, 12);
}

// A select field showing current; returns the option picked this frame (-1 for none). The option list
// is drawn by dropdown_list at the end of the layer.
select_field :: (id: string, options: []string, current: int) -> int {
	open := ss.dd == id;
	dd := row(id, .Clickable | .Draw_Background | .Draw_Border);
	dd.semantic_size = .[ui.pct(1), ui.px(40)];
	dd.style.bg = T("--input-background-default");
	dd.style.border = 1;
	dd.style.border_color = ifx open then T("--input-border-active") else T("--input-border-default");
	dd.style.radius = all4(8);
	dd.hover_cursor = .Pointer;
	if ui.signal(dd).clicked ss.dd = ifx open then "" else id;
	if ss.dd == id {
		ss.dd_anchor = dd.rect;
		ss.dd_options = options;
		ss.dd_current = current;
	}
	{ ui.parent(dd); defer ui.pop_parent();
		spacer(.X, 12);
		label(ifx current >= 0 && current < options.count then options[current] else "", .Normal, 16, T("--text-strong"), 20);
		filler(.X);
		icon("chev", ifx open then "chevron-small-up" else "chevron-small-down", 20, T("--interactive-icon-default"));
		spacer(.X, 12);
	}
	if ss.dd_pick >= 0 && ss.dd_pick_id == id {
		pick := ss.dd_pick;
		ss.dd_pick = -1;
		return pick;
	}
	return -1;
}

// The open select's option list, under (or over) its field.
dropdown_list :: () {
	r := ss.dd_anchor;
	if r.x1 <= r.x0 || !ss.dd_options.count return;
	if outside_pressed("dd_out") {
		ss.dd = "";
		return;
	}
	full := cast(float32)(ss.dd_options.count * 36 + 8);
	h := min(full, app.ui.window.y - r.y1 - 16);
	up := h < min(full, 180);
	if up h = min(full, r.y0 - 16);
	list := ui.box("ddlist", .Draw_Background | .Draw_Border | .Draw_Shadow | .Floating_X | .Floating_Y | .Overlay | .Clickable | .Scroll_Y | .Clip);
	list.semantic_size = .[ui.px(r.x1 - r.x0), ui.px(h)];
	list.fixed_pos = .{r.x0, ifx up then r.y0 - 4 - h else r.y1 + 4};
	list.layout_axis = .Y;
	list.style.bg = T("--background-surface-higher");
	list.style.border = 1;
	list.style.border_color = T("--border-subtle");
	list.style.radius = all4(8);
	list.style.shadow_color = .{0, 0, 0, 0.24};
	list.style.shadow_blur = 16;
	list.style.shadow_offset = .{0, 8};
	ui.signal(list);
	ui.parent(list); defer ui.pop_parent();
	spacer(.Y, 4);
	for ss.dd_options {
		ui.id_scope(cast(u64) it_index + 1);
		defer ui.pop_seed();
		sel := it_index == ss.dd_current;
		item := row("opt", .Clickable | .Draw_Background | .Hot_Animation);
		item.semantic_size = .[ui.pct(1), ui.px(36)];
		item.style.bg = ifx sel then T("--background-mod-normal") else .{};
		item.style.bg_hot = T("--background-mod-normal");
		if ui.signal(item).clicked {
			ss.dd_pick, ss.dd_pick_id = it_index, ss.dd;
			ss.dd = "";
		}
		{ ui.parent(item); defer ui.pop_parent();
			spacer(.X, 12);
			label(it, ifx sel then .Semibold else .Normal, 16, T("--text-strong"), 20);
		}
	}
	spacer(.Y, 4);
}

// A radio row ("All Messages"); true when clicked.
radio_row :: (id: string, text: string, on: bool) -> bool {
	r := row(id, .Clickable | .Draw_Background | .Hot_Animation);
	r.semantic_size = .[ui.pct(1), ui.px(44)];
	r.style.radius = all4(8);
	r.style.bg = ifx on then T("--background-mod-normal") else T("--background-mod-subtle");
	r.style.bg_hot = T("--background-mod-normal");
	r.hover_cursor = .Pointer;
	sig := ui.signal(r);
	{ ui.parent(r); defer ui.pop_parent();
		spacer(.X, 12);
		radio_dot(on);
		spacer(.X, 10);
		label(text, .Medium, 16, T("--text-strong"), 20);
	}
	spacer(.Y, 8);
	return sig.clicked && !on;
}

// Channels of the guild of the given types, in sidebar order, as select options after `none`.
channel_options :: (g: *dc.Guild, none: string, voice: bool) -> []string, []dc.Snowflake {
	names: [..]string;
	ids: [..]dc.Snowflake;
	names.allocator, ids.allocator = temp, temp;
	array_add(*names, none);
	array_add(*ids, 0);
	for g.channels {
		ch := dc.channel_get(store(), it);
		if !ch continue;
		is_voice := ch.kind == .Guild_Voice || ch.kind == .Guild_Stage_Voice;
		if voice != is_voice || (!voice && ch.kind != .Guild_Text) continue;
		array_add(*names, ifx voice then ch.name else tprint("#%", ch.name));
		array_add(*ids, ch.id);
	}
	return names, ids;
}

index_of :: (ids: []dc.Snowflake, id: dc.Snowflake) -> int {
	for ids if it == id return it_index;
	return 0;
}

// A read-only value with a Copy button ("Server ID").
copy_field :: (id: string, value: string) {
	r := row(id, .Draw_Background | .Draw_Border);
	r.semantic_size = .[ui.pct(1), ui.px(40)];
	r.style.bg = T("--input-background-default");
	r.style.border = 1;
	r.style.border_color = T("--input-border-default");
	r.style.radius = all4(8);
	ui.parent(r); defer ui.pop_parent();
	spacer(.X, 12);
	label(value, .Normal, 16, T("--text-default"), 20);
	filler(.X);
	if set_button(tprint("Copy##%", id), .Primary, h = 32) clipboard_set(value);
	spacer(.X, 4);
}

// ---- Server Profile ----

BRAND_COLORS :: string.["#ff1c90", "#e81d1e", "#e86e1d", "#e8c02f", "#71368a", "#029FFC", "#4fe2ca", "#406601", "#272727"];
BRAND_NAMES :: string.["Soul", "Volcano", "Marsh", "Thunder", "Rising", "Zephyr", "Cascade", "Earth", "Boulder"];

profile_page :: (g: *dc.Guild, w: float32) -> bool {
	page_subtitle("Customize how your server appears in invite links and, if enabled, in Server Discovery and Announcement Channel messages");
	r := reply(.Profile);
	if !r {
		if ss.loading[Req.Profile] {
			label("Loading...", .Normal, 16, T("--text-muted"), 20);
			return false;
		}
		label("Something went wrong", .Semibold, 16, T("--text-strong"), 20);
		spacer(.Y, 4);
		set_para("loadfail", "We couldn't load the profile for this server.", .Normal, 14, 18, T("--text-default"));
		spacer(.Y, 12);
		if set_button("Retry##retry", .Primary) load(g, .Profile, tprint("/guilds/%/profile", g.id));
		return false;
	}
	save := false;
	field_title("Name");
	res := set_input("name", *ss.name, g.name, max_runes = 100);
	if res == .Submit save = true;
	if res == .Escape ss.field_escape = true;
	spacer(.Y, 24);
	field_title("Icon");
	set_para("iconhelp", "We recommend an image of at least 512x512.", .Normal, 14, 18, T("--text-muted"));
	spacer(.Y, 12);
	ir := row("iconrow");
	ir.semantic_size = .[ui.pct(1), ui.px(80)];
	{ ui.parent(ir); defer ui.pop_parent();
		ic := ui.box("icon", .Draw_Background | .Draw_Text);
		ic.semantic_size = .[ui.px(80), ui.px(80)];
		ic.style.radius = all4(24);
		ic.style.bg = T("--background-mod-subtle");
		ic.style.text_color = T("--text-default");
		ic.style.text_align = .Center;
		ic.style.font = F(.Medium);
		ic.style.font_size = 20;
		ic.text = guild_initials(g.name);
		if g.icon {
			set_remote_image(ic, guild_icon_url(g.id, g.icon, 160));
			ic.text = "";
		}
		spacer(.X, 16);
		if set_button(ifx ss.icon_busy then "Uploading...##upload" else "Change Server Icon##upload", .Primary, !ss.icon_busy && !ss.busy) {
			paths := pick_files();
			if paths.count && net_action() {
				ss.icon_busy = true;
				ss_error("");
				dc.edit_guild_icon(app.client, g.id, paths[0]);
			}
		}
		spacer(.X, 8);
		if g.icon && set_button("Remove Icon##removeicon", .Link, !ss.icon_busy && !ss.busy) && net_action() {
			ss.icon_busy = true;
			ss_error("");
			dc.edit_guild_icon(app.client, g.id, "");
		}
	}
	spacer(.Y, 24);
	field_title("Banner");
	br := row("banner");
	br.semantic_size = .[ui.pct(1), ui.px(44)];
	br.style.child_gap = 8;
	{ ui.parent(br); defer ui.pop_parent();
		for -1..BRAND_COLORS.count-1 {
			color := ifx it < 0 then "" else BRAND_COLORS[it];
			sel := ss.brand == color || (it >= 0 && to_lower_copy(ss.brand,, temp) == to_lower_copy(color,, temp));
			sw := ui.box(tprint("sw%", it + 1), .Clickable | .Draw_Background | .Draw_Border);
			sw.semantic_size = .[ui.px(44), ui.px(44)];
			sw.style.radius = all4(8);
			sw.style.bg = ifx it < 0 then T("--background-mod-strong") else hex_color(color);
			sw.style.border = ifx sel then 3.0 else 0;
			sw.style.border_color = T("--text-strong");
			sw.hover_cursor = .Pointer;
			if ui.signal(sw).clicked ss.brand = color;
		}
	}
	spacer(.Y, 24);
	section_heading("traits", "Traits", "Add up to 5 traits to show off your server's interests and personality.");
	tr := row("traits");
	tr.semantic_size = .[ui.pct(1), ui.children()];
	tr.style.child_gap = 8;
	{ ui.parent(tr); defer ui.pop_parent();
		for * ss.traits {
			c := ui.box(tprint("t%", it_index + 1));
			c.semantic_size = .[ui.fill(), ui.children()];
			c.layout_axis = .Y;
			ui.parent(c); defer ui.pop_parent();
			if set_input("in", it, tprint("Trait %", it_index + 1), max_runes = 24) == .Escape ss.field_escape = true;
		}
	}
	spacer(.Y, 24);
	section_heading("desc", "Description", "How did your server get started? Why should people join?");
	if set_input("desc", *ss.desc, "Tell the world a bit about this server.", multiline = true, max_runes = 300, min_h = 100) == .Escape ss.field_escape = true;
	spacer(.Y, 24);
	if set_toggle_row("private", "Private Profile", "When enabled, only server members can view profile content. Non-members won't be able to see this content unless they have an invite.", ss.private) ss.private = !ss.private;
	return save;
}

// "#rrggbb" as a colour (black when malformed).
hex_color :: (hex: string) -> ui.Color {
	h := hex;
	if h.count && h[0] == #char "#" advance(*h, 1);
	if h.count != 6 return .{0, 0, 0, 1};
	v, ok := string_to_int(h, 16);
	if !ok return .{0, 0, 0, 1};
	return .{((v >> 16) & 0xFF) / 255.0, ((v >> 8) & 0xFF) / 255.0, (v & 0xFF) / 255.0, 1};
}

// ---- Engagement ----

AFK_TIMEOUTS :: int.[60, 300, 900, 1800, 3600];
AFK_LABELS :: string.["1 minute", "5 minutes", "15 minutes", "30 minutes", "1 hour"];

engagement_page :: (g: *dc.Guild) {
	page_subtitle("Manage settings that help keep your server active.");
	section_heading("sys", "System Messages", "Configure system event messages sent to your server.");
	field_title("System Messages Channel");
	names, ids := channel_options(g, "No System Messages", false);
	pick := select_field("syschan", names, index_of(ids, ss.eng.system_channel_id));
	if pick >= 0 ss.eng.system_channel_id = ids[pick];
	spacer(.Y, 8);
	set_para("syshelp", "This is the channel we send system event messages to.", .Normal, 12, 16, T("--text-muted"));
	spacer(.Y, 16);
	Flag :: struct { bit: int; text: string; }
	// Boost messages (SUPPRESS_PREMIUM_SUBSCRIPTIONS) stay as they are: no boost surfaces (AGENTS.md).
	flags :: Flag.[
		.{dc.SYSTEM_SUPPRESS_JOIN, "Send a random welcome message when someone joins this server."},
		.{dc.SYSTEM_SUPPRESS_JOIN_REPLIES, "Prompt members to reply to welcome messages with a sticker."},
		.{dc.SYSTEM_SUPPRESS_REMINDERS, "Send helpful tips for server setup."}
	];
	for flags {
		on := (ss.eng.system_channel_flags & it.bit) == 0;
		if set_toggle_row(tprint("sysflag%", it.bit), it.text, "", on) ss.eng.system_channel_flags ^= it.bit;
		spacer(.Y, 12);
	}
	set_divider();
	section_heading("notif", "Default Notification Settings", "This will determine whether members who have not explicitly set their notification settings receive a notification for every message sent in this server or not.");
	if radio_row("notif0", "All Messages", ss.eng.default_message_notifications == 0) ss.eng.default_message_notifications = 0;
	if radio_row("notif1", "Only @mentions", ss.eng.default_message_notifications == 1) ss.eng.default_message_notifications = 1;
	if !on_hosted() { // hosted servers have no voice channels yet
		set_divider();
		field_title("Inactive Channel");
		vn, vids := channel_options(g, "No Inactive Channel", true);
		pick = select_field("afkchan", vn, index_of(vids, ss.eng.afk_channel_id));
		if pick >= 0 ss.eng.afk_channel_id = vids[pick];
		spacer(.Y, 16);
		field_title("Inactive Timeout");
		cur := 1;
		for AFK_TIMEOUTS if it == ss.eng.afk_timeout cur = it_index;
		pick = select_field("afktime", AFK_LABELS, cur);
		if pick >= 0 ss.eng.afk_timeout = AFK_TIMEOUTS[pick];
		spacer(.Y, 8);
		set_para("afkhelp", "Automatically move members to this channel and mute them when they have been idle for longer than the inactive timeout. This does not affect browsers.", .Normal, 12, 16, T("--text-muted"));
	}
	if reply(.Widget) && !on_hosted() {
		set_divider();
		section_heading("widget", "Server Widget", "Embed an HTML widget on your website to display your online members, voice channels, and invite link.");
		if set_toggle_row("widgeton", "Enable Server Widget", "By enabling the widget, your server profile will be visible to others outside of your server members. You can control Profile privacy in Server Settings > Profile.", ss.widget_on) ss.widget_on = !ss.widget_on;
		spacer(.Y, 16);
		field_title("Invite Channel");
		wn, wids := channel_options(g, "No Invite", false);
		pick = select_field("widgetchan", wn, index_of(wids, ss.widget_channel));
		if pick >= 0 ss.widget_channel = wids[pick];
		spacer(.Y, 16);
		field_title("Server ID");
		copy_field("serverid", tprint("%", g.id));
		spacer(.Y, 16);
		field_title("JSON API");
		copy_field("jsonapi", tprint("https://discord.com/api/guilds/%/widget.json", g.id));
	}
}

#scope_export

// Shared by the settings pages: the readable reason a request failed.
settings_result_error :: (r: *dc.Feature_Result) -> string {
	if r.status == {
	case 0;
		return "Couldn't reach the server. Check your connection and try again.";
	case 403;
		return "You don't have permission to do that.";
	}
	msg := dc.api_error_message(r.body);
	if msg != "" return msg;
	return tprint("Something went wrong (HTTP %).", r.status);
}

// Script command `settings_reply <request> <json>`: a reply to one of the pages' loads, for UI tests
// (fixtures carry no REST). false for an unknown request name or bad JSON.
server_settings_script_reply :: (name: string, json: string) -> bool {
	for i: 0..cast(int) Req.COUNT - 1 {
		if tprint("%", cast(Req) i) != name continue;
		arena := New(Flat_Pool,, context.default_allocator);
		body, err := etf.from_json(json,, dc.pool_allocator(arena));
		if err != .None {
			fini(arena);
			free(arena,, context.default_allocator);
			return false;
		}
		r := dc.Feature_Result.{op = .Guild_Settings, tag = xx i, channel_id = ss.guild, ok = true, status = 200, body = body, arena = arena};
		server_settings_receive(*r);
		dc.feature_result_free(*r);
		return true;
	}
	return false;
}
