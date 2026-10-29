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
	form_reset(g);
	if app.client != null dc.open_guild_settings(app.client, gid, section_pane(ss.section));
}

server_settings_is_open :: () -> bool { return ss.open; }

server_settings_close :: () {
	ss.open = false;
	ss.busy, ss.icon_busy = false, false;
	ss_error("");
	app.ui.focus = 0;
}

server_settings_reset_for_test :: () {
	ui.editor_destroy(*ss.name);
	free(ss.error);
	ss = .{};
}

// server_settings_receive: finished requests the pages sent.
server_settings_receive :: (r: *dc.Feature_Result) {
	if !ss.open || r.channel_id != ss.guild return;
	app.ui.animating = true;
	if r.op == {
	case .Guild_Edit;
		icon := ss.icon_busy;
		ss.icon_busy = false;
		ss.busy = false;
		if r.ok {
			g := dc.guild_get(store(), ss.guild);
			if g && !icon form_reset(g); // saved: the form now matches (GUILD_UPDATE may follow)
			return;
		}
		if icon && r.status == -1 { ss_error("That file couldn't be read. Server icons must be PNG, JPEG, GIF or WEBP images."); return; }
		if icon && r.status == -2 { ss_error("That image is too large. Server icons must be under 512 KB."); return; }
		ss_error(settings_result_error(r));
	}
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
		form_reset(g);
		if app.client != null dc.guild_settings_pane(app.client, section_pane(from), section_pane(go), g.id);
	}
	if save && dirty && !ss.busy && net_action() form_save(g);
}

#scope_file

SETTINGS_PERMS :: dc.PERM_MANAGE_GUILD | dc.PERM_MANAGE_ROLES | dc.PERM_ADMINISTRATOR | dc.PERM_BAN_MEMBERS | dc.PERM_MANAGE_NICKNAMES
	| dc.PERM_CREATE_GUILD_EXPRESSIONS | dc.PERM_MANAGE_GUILD_EXPRESSIONS | dc.PERM_MANAGE_WEBHOOKS | dc.PERM_VIEW_AUDIT_LOG | dc.PERM_VIEW_GUILD_ANALYTICS;

GROUP_NAMES :: string.["", "Expression", "People", "Apps", "Moderation", "", "Host", ""];

ss: struct {
	open: bool;
	guild: dc.Snowflake;
	section: Server_Section;
	busy: bool; // a save is in flight
	icon_busy: bool; // Server Profile: an icon upload or removal is in flight
	error: string; // heap
	field_escape: bool; // a page's field took Escape this frame
	name: ui.Editor; // Server Profile
};

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
	case .Profile;
		return true;
	}
	return false;
}

// page_body draws a section's page into the form column; true asks to save (Enter in a field).
page_body :: (g: *dc.Guild, s: Server_Section, w: float32) -> bool {
	if s == {
	case .Profile;
		return profile_page(g);
	}
	return false;
}

form_dirty :: (g: *dc.Guild) -> bool {
	if ss.section == {
	case .Profile;
		return trim(ui.editor_text(*ss.name)) != g.name;
	}
	return false;
}

form_reset :: (g: *dc.Guild) {
	ui.editor_set_text(*ss.name, g.name);
	ss_error("");
}

form_save :: (g: *dc.Guild) {
	if ss.section == {
	case .Profile;
		name := trim(ui.editor_text(*ss.name));
		if name.count < 2 || name.count > 100 {
			ss_error("Server name must be between 2 and 100 characters.");
			return;
		}
		ss.busy = true;
		ss_error("");
		dc.edit_guild_name(app.client, g.id, name);
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

// ---- Server Profile ----

profile_page :: (g: *dc.Guild) -> bool {
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
	return save;
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
