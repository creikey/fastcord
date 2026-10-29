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
	if r.op == .Sticker_Upload {
		ss.busy = false;
		if r.ok {
			ui.editor_set_text(*ss.hook_name, "");
			ui.editor_set_text(*ss.tag, "");
			ui.editor_set_text(*ss.words, "");
			ss_set(*ss.sticker_file, "");
		} else if r.status == -1 ss_error("Stickers must be PNG, APNG, GIF or Lottie JSON files.");
		else if r.status == -2 ss_error("That file is too large. Stickers must be under 512 KB.");
		else ss_error(settings_result_error(r));
		return;
	}
	if r.op == .Guild_Edit {
		ss.icon_busy = false;
		if r.ok return; // GUILD_UPDATE shows it
		if r.status == -1 ss_error("That file couldn't be read. Server icons must be PNG, JPEG, GIF or WEBP images.");
		else if r.status == -2 ss_error("That image is too large. Server icons must be under 512 KB.");
		else ss_error(settings_result_error(r));
		return;
	}
	req := cast(Req) r.tag;
	if req == .Action {
		ss.busy = false;
		if !r.ok { ss_error(settings_result_error(r)); return; }
		if ss.confirm == .Delete_Server { server_settings_close(); return; }
		if ss.confirm == .Delete_Role ss.role_id = 0;
		ss.confirm = .None;
		if ss.after == .Members members_search(g);
		else if ss.after == .Role_Members role_members_load(g);
		else if ss.after < .COUNT { ss.loading[ss.after] = false; section_enter(g); }
		return;
	}
	if req == .Create_Role {
		ss.busy = false;
		if !r.ok { ss_error(settings_result_error(r)); return; }
		ss.pending_role = dc.fsnow(dc.vmap(r.body), "id");
		return;
	}
	if req == .Save || req == .Save_Widget {
		if !r.ok {
			ss.busy, ss.saves_left = false, 0;
			ss_error(settings_result_error(r));
			return;
		}
		if (ss.section == .Profile || ss.section == .Tag) && r.body.kind == .Map keep_reply(.Profile, r); // the saved profile
		if ss.section == .Access && r.body.kind == .Map keep_reply(.Verification, r);
		if req == .Save_Widget && r.body.kind == .Map keep_reply(.Widget, r);
		ss.saves_left -= 1;
		if ss.saves_left > 0 return;
		ss.busy = false;
		// Drafts of store values stay as saved: the gateway's update makes the store match them.
		if ss.section == .Profile || ss.section == .Tag || ss.section == .Access form_reset(g);
		return;
	}
	if req >= .COUNT return;
	keep_reply(req, r);
	if req == .Profile || req == .Widget || req == .Verification || req == .Vanity form_reset(g); // the forms these replies fill
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
						if nav_item(sec, g) && !dirty {
							if sec == .Delete ss_confirm_open(.Delete_Server, 0, "");
							else go = sec;
						}
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
					label(section_title(g, ss.section), .Semibold, 20, T("--text-strong"), 24);
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
	if ss.menu_user member_menu(g);
	if ss.confirm != .None ss_confirm_modal(g);
	if ss.dd {
		dropdown_list();
		if adm_escape() ss.dd = "";
	}
	if ss.reload_after_modr && modr.user == 0 {
		ss.reload_after_modr = false;
		ss.search_at = wall_ms() + 700; // after the kick or ban lands
	}
	covered := ss.confirm != .None || ss.menu_user != 0 || modr.user != 0 || guild_admin_modal_open();
	if ss.menu_user && escape_pressed() ss.menu_user = 0;
	if !close && !dirty && !covered && (adm_escape() || ss.field_escape) close = true;
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
	Members; // POST /guilds/{id}/members-search
	Invites; // GET /guilds/{id}/invites
	Bans; // GET /guilds/{id}/bans
	Emojis; // GET /guilds/{id}/emojis (who uploaded each)
	Audit; // GET /guilds/{id}/audit-logs
	Role_Counts; // GET /guilds/{id}/roles/member-counts
	Role_Members; // POST /guilds/{id}/members-search for one role
	Automod; // GET /guilds/{id}/auto-moderation/rules
	Webhooks; // GET /guilds/{id}/webhooks
	Integrations; // GET /guilds/{id}/integrations
	Templates; // GET /guilds/{id}/templates
	Verification; // GET /guilds/{id}/member-verification (Access: the server rules)
	Vanity; // GET /guilds/{id}/vanity-url
	COUNT;
	Save :: 100; // a page's Save Changes
	Save_Widget;
	Action; // a list page's change (ss_action), then its list reloads
	Create_Role; // POST /guilds/{id}/roles
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
	saves_left: int; // requests of the save in flight still to answer
	// The open select (dropdown_list): its id, anchor, this frame's options, and the pick it made.
	dd: string;
	dd_anchor: ui.Rect;
	dd_options: []string;
	dd_current: int;
	dd_pick: int = -1;
	dd_pick_id: string;
	after: Req; // what the action in flight reloads
	form_w: float32; // this frame's page column width
	col_unit: float32; // a table's width per column weight
	// Members and Bans
	search: ui.Editor;
	search_at: s64; // Members: when the search text changed (searched 300 ms later)
	menu_user: dc.Snowflake; // the member row menu
	menu_pos: ui.Vec2;
	menu_name: string; // heap
	menu_timed_out: bool;
	reload_after_modr: bool; // Kick / Ban went to moderation.jai's confirm
	// Emoji
	rename_emoji: dc.Snowflake;
	rename: ui.Editor;
	// Audit Log
	audit_user: dc.Snowflake;
	audit_action: int; // index into AUDIT_ACTIONS
	// Roles: the role being edited (0: the list) and its draft
	role_id: dc.Snowflake;
	pending_role: dc.Snowflake; // created, waiting for GUILD_ROLE_CREATE
	role_tab: int; // index into ROLE_TABS
	role_name: ui.Editor;
	role_color: u32;
	role_hoist: bool;
	role_mentionable: bool;
	role_perms: u64;
	role_order: [..]dc.Snowflake; // the list as reordered, top first; empty when untouched
	declined: dc.Snowflake; // the guild whose ownership offer was answered or put off this session
	comm: Community_Form; // Community
	require_rules: bool; // Access
	tag: ui.Editor; // Server Tag; Invites: the custom invite link's code; Stickers: related emoji
	sticker_file: string; // heap: Stickers' chosen file
	words: ui.Editor; // Safety Setup: Block Custom Words; Server Template: its description
	hook_id: dc.Snowflake; // Integrations: the webhook open for editing
	hook_name: ui.Editor; // its name; Server Template: the title
	hook_channel: dc.Snowflake;
	// the open confirm
	confirm: SS_Confirm;
	confirm_id: dc.Snowflake;
	confirm_text: string; // heap
	reason: ui.Editor; // a reason, or the server's name (Delete Server)
	confirm_pick: int;
	confirm_ack: bool;
};

ss_set :: (dst: *string, v: string) {
	free(dst.*);
	dst.* = copy_string(v);
}

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

load :: (g: *dc.Guild, req: Req, path: string) { load_body(g, req, "GET", path); }

load_body :: (g: *dc.Guild, req: Req, method: string, path: string, body := "") {
	if ss.loading[req] || !net_action() return;
	ss.loading[req] = true;
	dc.guild_settings_call(app.client, g.id, xx req, method, path, body);
}

// A section shown: load what its page reads.
section_enter :: (g: *dc.Guild) {
	if ss.section == {
	case .Profile;
		load(g, .Profile, tprint("/guilds/%/profile", g.id));
	case .Engagement;
		load(g, .Widget, tprint("/guilds/%/widget", g.id));
	case .Members;
		members_search(g);
	case .Invites;
		load(g, .Invites, tprint("/guilds/%/invites", g.id));
		if dc.guild_has_feature(g, "VANITY_URL") load(g, .Vanity, tprint("/guilds/%/vanity-url", g.id));
	case .Bans;
		load(g, .Bans, tprint("/guilds/%/bans?limit=1000", g.id));
	case .Emoji;
		load(g, .Emojis, tprint("/guilds/%/emojis", g.id));
	case .Audit_Log;
		audit_load(g);
	case .Integrations;
		ss.loading[Req.Webhooks] = false;
		load(g, .Webhooks, tprint("/guilds/%/webhooks", g.id));
		if !on_hosted() load(g, .Integrations, tprint("/guilds/%/integrations?include_applications=true&include_role_connections_metadata=true", g.id));
	case .Templates;
		ss.loading[Req.Templates] = false;
		load(g, .Templates, tprint("/guilds/%/templates", g.id));
	case .Access;
		ss.loading[Req.Verification] = false;
		load(g, .Verification, tprint("/guilds/%/member-verification?with_guild=false", g.id));
	case .Tag;
		load(g, .Profile, tprint("/guilds/%/profile", g.id));
	case .Safety;
		ss.loading[Req.Automod] = false;
		load(g, .Automod, tprint("/guilds/%/auto-moderation/rules", g.id));
	case .Roles;
		ss.loading[Req.Role_Counts] = false;
		load(g, .Role_Counts, tprint("/guilds/%/roles/member-counts", g.id));
	}
	ss.role_id, ss.pending_role, ss.hook_id = 0, 0, 0;
	ui.editor_set_text(*ss.hook_name, "");
	ui.editor_set_text(*ss.words, "");
	array_reset(*ss.role_order);
	ui.editor_set_text(*ss.search, "");
	ss.rename_emoji = 0;
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

// Community reads "Community Overview" once the server is one.
section_title :: (g: *dc.Guild, s: Server_Section) -> string {
	if s == .Community && dc.guild_has_feature(g, "COMMUNITY") return "Community Overview";
	return section_label(s);
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
		return has(p, dc.PERM_MANAGE_GUILD) && dc.guild_has_feature(g, "GUILD_TAGS") && !on_hosted();
	case .Stickers;
		return has(p, dc.PERM_MANAGE_GUILD_EXPRESSIONS | dc.PERM_CREATE_GUILD_EXPRESSIONS) && !on_hosted(); // serve keeps no stickers yet
	case .Emoji; #through; case .Soundboard;
		return has(p, dc.PERM_MANAGE_GUILD_EXPRESSIONS | dc.PERM_CREATE_GUILD_EXPRESSIONS);
	case .Members;
		return has(p, dc.PERM_MANAGE_GUILD | dc.PERM_MANAGE_ROLES | dc.PERM_KICK_MEMBERS | dc.PERM_BAN_MEMBERS | dc.PERM_MODERATE_MEMBERS | dc.PERM_MANAGE_NICKNAMES);
	case .Roles;
		return has(p, dc.PERM_MANAGE_ROLES) && !on_hosted(); // hosted servers have only @everyone so far
	case .Safety;
		return has(p, dc.PERM_MANAGE_GUILD) && !on_hosted(); // a hosted server has no verification levels, filters or AutoMod
	case .Templates; #through; case .Access; #through; case .Community; #through; case .Onboarding;
		return has(p, dc.PERM_MANAGE_GUILD) && !on_hosted(); // Discord's: templates, member verification, Community
	case .Invites;
		return has(p, dc.PERM_MANAGE_GUILD);
	case .Integrations;
		return has(p, dc.PERM_MANAGE_GUILD | dc.PERM_MANAGE_WEBHOOKS);
	case .Audit_Log;
		return has(p, dc.PERM_VIEW_AUDIT_LOG);
	case .Bans;
		return has(p, dc.PERM_BAN_MEMBERS | dc.PERM_VIEW_AUDIT_LOG);
	case .Delete;
		return owner && !on_hosted(); // hosted: the Host group's Server Info
	}
	return on_hosted() && owner; // Host
}

// The sections fastcord has a page for (see the note at the top).
page_exists :: (s: Server_Section) -> bool {
	if s == {
	case .Profile; #through; case .Engagement; #through; case .Members; #through; case .Invites; #through; case .Bans; #through;
	case .Emoji; #through; case .Audit_Log; #through; case .Delete; #through; case .Soundboard; #through; case .Roles; #through; case .Safety; #through; case .Integrations; #through; case .Templates; #through;
	case .Community; #through; case .Access; #through; case .Tag; #through; case .Stickers;
		return true;
	}
	return false;
}

// page_body draws a section's page into the form column; true asks to save (Enter in a field).
page_body :: (g: *dc.Guild, s: Server_Section, w: float32) -> bool {
	ss.form_w = w;
	if s == {
	case .Profile;
		return profile_page(g, w);
	case .Engagement;
		engagement_page(g);
	case .Members;
		members_page(g);
	case .Invites;
		invites_page(g);
	case .Bans;
		bans_page(g);
	case .Emoji;
		emoji_page(g);
	case .Audit_Log;
		audit_page(g);
	case .Roles;
		roles_page(g);
	case .Safety;
		safety_page(g);
	case .Integrations;
		integrations_page(g);
	case .Templates;
		templates_page(g);
	case .Community;
		community_page(g);
	case .Access;
		access_page(g);
	case .Tag;
		tag_page(g);
	case .Stickers;
		stickers_page(g);
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
	case .Roles;
		return role_dirty(g);
	case .Integrations;
		return hook_dirty();
	case .Community;
		return community_dirty(g);
	case .Access;
		return access_dirty();
	case .Tag;
		return tag_dirty();
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
	if ss.section == .Roles role_reset(g);
	ss.comm = community_form_of(g);
	saved, on := saved_rules();
	if ss.section == .Access && reply(.Verification) { ui.editor_set_text(*ss.words, saved); ss.require_rules = on; }
	if ss.section == .Tag && r ui.editor_set_text(*ss.tag, dc.fstr(dc.vmap(r.body), "tag"));
	v := reply(.Vanity);
	if ss.section == .Invites ui.editor_set_text(*ss.tag, ifx v then dc.fstr(dc.vmap(v.body), "code") else g.vanity_url_code);
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

// One request of a page's save; the save ends when every one has answered.
save_call :: (g: *dc.Guild, req: Req, method: string, path: string, body: string) {
	ss.busy = true;
	ss.saves_left += 1;
	dc.guild_settings_call(app.client, g.id, xx req, method, path, body);
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
		save_call(g, .Save, "PATCH", tprint("/guilds/%/profile", g.id), dc.guild_profile_body(f));
	case .Engagement;
		ss.busy = true;
		ss_error("");
		if engagement_dirty(g) save_call(g, .Save, "PATCH", tprint("/guilds/%", g.id), dc.engagement_body(ss.eng));
		if widget_dirty() save_call(g, .Save_Widget, "PATCH", tprint("/guilds/%/widget", g.id), dc.widget_body(ss.widget_on, ss.widget_channel));
	case .Roles;
		roles_save(g);
	case .Community;
		community_save(g);
	case .Access;
		access_save(g);
	case .Tag;
		ss_error("");
		save_call(g, .Save, "PATCH", tprint("/guilds/%/profile", g.id), tprint("{\"tag\":%}", dc.json_quote(trim(ui.editor_text(*ss.tag)))));
	case .Integrations;
		name := trim(ui.editor_text(*ss.hook_name));
		if !name { ss_error("A webhook needs a name."); return; }
		ss_action(g, .Webhooks, "PATCH", tprint("/webhooks/%", ss.hook_id), tprint("{\"name\":%,\"channel_id\":\"%\"}", dc.json_quote(name), ss.hook_channel));
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
		label(section_title(g, s), .Medium, 16, c, 20);
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

// ---- list pages: shared ----

// A table header row ("NAME", "MEMBER SINCE", ...), the columns sized by weight like the rows under it.
table_header :: (id: string, cols: []string, weights: []float32) {
	table_units(weights);
	r := row(id);
	r.semantic_size = .[ui.pct(1), ui.px(28)];
	ui.parent(r); defer ui.pop_parent();
	for cols {
		c := row(tprint("h%", it_index));
		c.semantic_size = .[ui.px(ss.col_unit * weights[it_index]), ui.px(28)];
		ui.parent(c); defer ui.pop_parent();
		label(it, .Bold, 12, T("--text-muted"), 16);
	}
	spacer(.X, 36);
}

// A table row; returns it (pushed as parent: close with ui.pop_parent).
table_row_begin :: (id: string) -> *ui.Box, ui.Signal {
	r := row(id, .Clickable | .Draw_Background | .Hot_Animation);
	r.semantic_size = .[ui.pct(1), ui.px(52)];
	r.style.radius = all4(8);
	r.style.bg_hot = T("--background-mod-subtle");
	sig := ui.signal(r);
	ui.push_parent(r);
	return r, sig;
}

// The columns share the form's width (less a row's end button) by weight.
table_units :: (weights: []float32) {
	sum: float32;
	for weights sum += it;
	ss.col_unit = (ss.form_w - 36) / sum;
}

table_cell :: (i: int, weight: float32) -> *ui.Box {
	c := row(tprint("c%", i));
	c.semantic_size = .[ui.px(ss.col_unit * weight), ui.px(52)];
	c.flags |= .Clip;
	return c;
}

// A small icon button at a row's end ("...", "x"); true when clicked.
row_icon_button :: (id: string, name: string, danger := false) -> bool {
	b := ui.box(id, .Clickable | .Draw_Background | .Hot_Animation);
	b.semantic_size = .[ui.px(28), ui.px(28)];
	b.style.radius = all4(14);
	b.style.bg_hot = T("--background-mod-normal");
	b.hover_cursor = .Pointer;
	sig := ui.signal(b);
	{ ui.parent(b); defer ui.pop_parent();
		i := icon("i", name, 16, ifx danger && sig.hovering then T("--text-feedback-critical") else T("--interactive-icon-default"));
		i.flags |= .Floating_X | .Floating_Y;
		i.fixed_pos = .{6, 6};
	}
	return sig.clicked;
}

user_display :: (u: etf.Map) -> string {
	n := dc.fstr(u, "global_name");
	return ifx n then n else dc.fstr(u, "username");
}

// A user cell: avatar, display name and username under it.
user_cell :: (u: etf.Map) {
	uid := dc.fsnow(u, "id");
	avatar_box("av", uid, 32);
	spacer(.X, 10);
	col := ui.box("names");
	col.semantic_size = .[ui.fill(), ui.children()];
	col.layout_axis = .Y;
	ui.parent(col); defer ui.pop_parent();
	label(user_display(u), .Medium, 14, T("--text-strong"), 18);
	label(dc.fstr(u, "username"), .Normal, 12, T("--text-muted"), 16);
}

// "Oct 26, 2026" (local time)
ss_date :: (ms: s64) -> string {
	t := utc_calendar(local_ms(ms));
	MONTHS :: string.["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
	return tprint("% %, %", MONTHS[t.month_starting_at_0], t.day_of_month_starting_at_0 + 1, t.year);
}

snowflake_date :: (id: dc.Snowflake) -> string { return ss_date(cast(s64)(id >> 22) + 1420070400000); }

ss_empty :: (text: string) {
	spacer(.Y, 24);
	r := row("empty");
	r.semantic_size = .[ui.pct(1), ui.px(20)];
	ui.parent(r); defer ui.pop_parent();
	filler(.X);
	label(text, .Normal, 14, T("--text-muted"), 18);
	filler(.X);
}

loading_or :: (req: Req, failed: string) -> bool {
	if reply(req) return true;
	label(ifx ss.loading[req] then "Loading..." else failed, .Normal, 14, T("--text-muted"), 18);
	return false;
}

// ---- Members ----

TIMEOUTS :: struct { secs: int; name: string; }.[
	.{60, "60 seconds"}, .{300, "5 minutes"}, .{600, "10 minutes"}, .{3600, "1 hour"}, .{86400, "1 day"}, .{604800, "1 week"},
];

members_search :: (g: *dc.Guild) {
	q := trim(ui.editor_text(*ss.search));
	or := ifx q.count > 1 then tprint("{\"usernames\":{\"or_query\":[%]}}", dc.json_quote(q)) else "{}";
	ss.loading[Req.Members] = false;
	if !net_action() return;
	ss.loading[Req.Members] = true;
	dc.guild_settings_call(app.client, g.id, xx Req.Members, "POST", tprint("/guilds/%/members-search", g.id), tprint("{\"or_query\":%,\"and_query\":{},\"limit\":250}", or));
}

members_page :: (g: *dc.Guild) {
	res := set_input("search", *ss.search, "Search by username or id");
	if res == .Changed ss.search_at = wall_ms();
	if res == .Escape ss.field_escape = true;
	if ss.search_at {
		app.ui.animating = true;
		if wall_ms() - ss.search_at > 300 || res == .Submit {
			ss.search_at = 0;
			members_search(g);
		}
	}
	spacer(.Y, 16);
	if !loading_or(.Members, "Couldn't load the members.") return;
	m := dc.vmap(reply(.Members).body);
	label(tprint("% members", dc.fint(m, "total_result_count")), .Semibold, 14, T("--text-default"), 18);
	spacer(.Y, 8);
	W :: float32.[4, 2, 2, 1];
	table_header("mhead", .["NAME", "MEMBER SINCE", "JOINED DISCORD", "ROLES"], W);
	list := dc.flist(m, "members");
	if !list.count ss_empty("No members found");
	for list {
		mm := dc.fmap(dc.vmap(it), "member");
		u := dc.fmap(mm, "user");
		uid := dc.fsnow(u, "id");
		ui.id_scope(cast(u64) uid);
		defer ui.pop_seed();
		r := table_row_begin("m");
		defer ui.pop_parent();
		{ c := table_cell(0, W[0]); ui.parent(c); defer ui.pop_parent(); user_cell(u); }
		{ c := table_cell(1, W[1]); ui.parent(c); defer ui.pop_parent(); label(ss_date(dc.iso_to_ms(dc.fstr(mm, "joined_at"))), .Normal, 14, T("--text-default"), 18); }
		{ c := table_cell(2, W[2]); ui.parent(c); defer ui.pop_parent(); label(snowflake_date(uid), .Normal, 14, T("--text-default"), 18); }
		{ c := table_cell(3, W[3]); ui.parent(c); defer ui.pop_parent(); label(tprint("%", dc.flist(mm, "roles").count), .Normal, 14, T("--text-default"), 18); }
		if uid != store().me && uid != g.owner_id && row_icon_button("more", "more-horizontal") {
			ss.menu_user = uid;
			ss.menu_pos = .{r.rect.x1 - 220, r.rect.y1};
			ss.menu_timed_out = dc.iso_to_ms(dc.fstr(mm, "communication_disabled_until")) > wall_ms();
			ss_set(*ss.menu_name, dc.fstr(u, "username"));
		}
	}
}

// The member row's menu: Kick, Ban, Timeout / Remove Timeout, Transfer Ownership (the owner).
member_menu :: (g: *dc.Guild) {
	if outside_pressed("mmenu_out") {
		ss.menu_user = 0;
		return;
	}
	menu := menu_panel("mmenu", ss.menu_pos, 220);
	ui.parent(menu); defer ui.pop_parent();
	spacer(.Y, 8);
	uid := ss.menu_user;
	name := ss.menu_name;
	pick := "";
	if dc.can_moderate(store(), g.id, uid, dc.PERM_MODERATE_MEMBERS) {
		if ss.menu_timed_out {
			if menu_item("untimeout", "Remove Timeout").clicked pick = "untimeout";
		} else if menu_item("timeout", tprint("Timeout %", name), danger = true).clicked pick = "timeout";
	}
	if dc.can_moderate(store(), g.id, uid, dc.PERM_KICK_MEMBERS) && menu_item("kick", tprint("Kick %", name), danger = true).clicked pick = "kick";
	if dc.can_moderate(store(), g.id, uid, dc.PERM_BAN_MEMBERS) && menu_item("ban", tprint("Ban %", name), danger = true).clicked pick = "ban";
	if g.owner_id == store().me && menu_item("transfer", "Transfer Ownership", danger = true).clicked pick = "transfer";
	spacer(.Y, 8);
	if pick == "" return;
	ss.menu_user = 0;
	if pick == {
	case "kick"; #through; case "ban";
		modr.user, modr.guild, modr.ban = uid, g.id, pick == "ban";
		modr.history, modr.history_open = 0, false;
		ui.editor_set_text(*modr.ed, "");
		ss.reload_after_modr = true;
	case "timeout";
		ss_confirm_open(.Timeout, uid, name);
	case "untimeout";
		ss_action(g, .Members, "PATCH", tprint("/guilds/%/members/%", g.id, uid), "{\"communication_disabled_until\":null}");
	case "transfer";
		ss_confirm_open(.Transfer, uid, name);
	}
}

// ---- Invites ----

invites_page :: (g: *dc.Guild) {
	paused := dc.iso_to_ms(g.invites_disabled_until) > wall_ms() || dc.guild_has_feature(g, "INVITES_DISABLED");
	if !loading_or(.Invites, "Couldn't load the invites.") return;
	list := dc.vlist(reply(.Invites).body);
	hr := row("ihead");
	hr.semantic_size = .[ui.pct(1), ui.px(40)];
	{ ui.parent(hr); defer ui.pop_parent();
		label(ifx list.count then "ACTIVE INVITE LINKS" else "NO ACTIVE INVITE LINKS", .Bold, 12, T("--text-muted"), 16);
		filler(.X);
		if paused {
			if set_button("Enable Invites##resume", .Primary, !ss.busy) ss_action(g, .COUNT, "PUT", tprint("/guilds/%/incident-actions", g.id), "{\"invites_disabled_until\":null,\"dms_disabled_until\":null,\"lockdown_duration_hours\":null}");
		} else if set_button("Pause Invites##pause", .Danger, !ss.busy) ss_confirm_open(.Pause_Invites, 0, "");
	}
	if paused {
		spacer(.Y, 8);
		set_para("pausednote", "Invites are paused: nobody can join with an invite link until they're enabled again.", .Normal, 14, 18, T("--text-feedback-warning"));
	}
	spacer(.Y, 12);
	W :: float32.[3, 2, 1, 2];
	table_header("ithead", .["INVITER", "INVITE CODE", "USES", "EXPIRES"], W);
	for list {
		inv := dc.vmap(it);
		code := dc.fstr(inv, "code");
		ui.id_scope(get_hash(code));
		defer ui.pop_seed();
		table_row_begin("i");
		defer ui.pop_parent();
		{
			c := table_cell(0, W[0]); ui.parent(c); defer ui.pop_parent();
			u := dc.fmap(inv, "inviter");
			if u.count user_cell(u);
			else {
				uid := dc.fsnow(inv, "inviter_id");
				iu := dc.user_get(store(), uid);
				avatar_box("av", uid, 32);
				spacer(.X, 10);
				label(ifx iu then dc.display_name(iu) else "", .Medium, 14, T("--text-strong"), 18);
			}
		}
		{ c := table_cell(1, W[1]); ui.parent(c); defer ui.pop_parent(); label(code, .Normal, 14, T("--text-default"), 18); }
		uses := dc.fint(inv, "uses");
		max_uses := dc.fint(inv, "max_uses");
		{ c := table_cell(2, W[2]); ui.parent(c); defer ui.pop_parent(); label(ifx max_uses then tprint("%/%", uses, max_uses) else tprint("%", uses), .Normal, 14, T("--text-default"), 18); }
		exp := dc.iso_to_ms(dc.fstr(inv, "expires_at"));
		{ c := table_cell(3, W[3]); ui.parent(c); defer ui.pop_parent(); label(ifx exp then duration_left(exp - wall_ms()) else "∞", .Normal, 14, T("--text-default"), 18); }
		if row_icon_button("revoke", "x-small", danger = true) ss_confirm_open(.Revoke_Invite, 0, code);
	}
	vanity_block(g);
}

// "6:23:41" until expiry, or days ("6 days").
duration_left :: (ms: s64) -> string {
	if ms <= 0 return "Expired";
	s := ms / 1000;
	if s >= 86400 * 2 return tprint("% days", s / 86400);
	return tprint("%:%:%", s / 3600, formatInt((s / 60) % 60, minimum_digits = 2), formatInt(s % 60, minimum_digits = 2));
}

// ---- Bans ----

bans_page :: (g: *dc.Guild) {
	if set_input("bsearch", *ss.search, "Search Bans by User ID or Username") == .Escape ss.field_escape = true;
	spacer(.Y, 16);
	if !loading_or(.Bans, "Couldn't load the bans.") return;
	list := dc.vlist(reply(.Bans).body);
	q := to_lower_copy(trim(ui.editor_text(*ss.search)),, temp);
	label(tprint("% Bans", list.count), .Semibold, 14, T("--text-default"), 18);
	spacer(.Y, 8);
	shown := 0;
	table_units(.[3, 4]);
	for list {
		b := dc.vmap(it);
		u := dc.fmap(b, "user");
		uid := dc.fsnow(u, "id");
		if q && !contains(to_lower_copy(dc.fstr(u, "username"),, temp), q) && !contains(to_lower_copy(user_display(u),, temp), q) && tprint("%", uid) != q continue;
		shown += 1;
		ui.id_scope(cast(u64) uid);
		defer ui.pop_seed();
		_, sig := table_row_begin("b");
		defer ui.pop_parent();
		{ c := table_cell(0, 3); ui.parent(c); defer ui.pop_parent(); user_cell(u); }
		reason := dc.fstr(b, "reason");
		{ c := table_cell(1, 4); ui.parent(c); defer ui.pop_parent(); label(ifx reason then reason else "No reason given", .Normal, 14, T("--text-muted"), 18); }
		spacer(.X, 36);
		if sig.clicked ss_confirm_open(.Revoke_Ban, uid, dc.fstr(u, "username"));
	}
	if !shown ss_empty(ifx list.count then "No bans match your search" else "No bans");
}

// ---- Emoji ----

emoji_page :: (g: *dc.Guild) {
	page_subtitle("Add up to 50 custom emoji that anyone can use in this server. Animated GIF emoji may be used by members with Discord Nitro. Emoji names must be at least 2 characters long and can only contain alphanumeric characters and underscores. Emoji must be under 256 KB in size.");
	if set_button(ifx emoji_upload_busy() then "Uploading...##upload" else "Upload Emoji##upload", .Primary, !emoji_upload_busy()) emoji_upload_pick(g.id);
	spacer(.Y, 20);
	uploaders: Table(dc.Snowflake, etf.Map);
	uploaders.allocator = temp;
	r := reply(.Emojis);
	if r for dc.vlist(r.body) table_set(*uploaders, dc.fsnow(dc.vmap(it), "id"), dc.fmap(dc.vmap(it), "user"));
	for animated: bool.[false, true] {
		n := 0;
		for g.emojis if it.animated == animated n += 1;
		label(tprint("% EMOJI — % SLOTS AVAILABLE", ifx animated then "ANIMATED" else "STATIC", max(0, 50 - n)), .Bold, 12, T("--text-muted"), 16);
		spacer(.Y, 8);
		W :: float32.[1, 3, 3];
		if n table_header(tprint("ehead%", animated), .["IMAGE", "NAME", "UPLOADED BY"], W);
		for e: g.emojis {
			if e.animated != animated continue;
			ui.id_scope(cast(u64) e.id);
			defer ui.pop_seed();
			table_row_begin("e");
			defer ui.pop_parent();
			{
				c := table_cell(0, W[0]); ui.parent(c); defer ui.pop_parent();
				img := ui.box("img");
				img.semantic_size = .[ui.px(32), ui.px(32)];
				set_remote_image(img, emoji_url(e.id, e.animated, 64));
			}
			{
				c := table_cell(1, W[1]); ui.parent(c); defer ui.pop_parent();
				if ss.rename_emoji == e.id {
					col := ui.box("ed");
					col.semantic_size = .[ui.fill(), ui.children()];
					col.layout_axis = .Y;
					ui.parent(col); defer ui.pop_parent();
					res := set_input("name", *ss.rename, e.name, max_runes = 32, autofocus = true);
					if res == .Escape ss.rename_emoji = 0;
					if res == .Submit {
						name := trim(ui.editor_text(*ss.rename));
						if name != e.name ss_action(g, .Emojis, "PATCH", tprint("/guilds/%/emojis/%", g.id, e.id), tprint("{\"name\":%}", dc.json_quote(name)));
						ss.rename_emoji = 0;
					}
				} else {
					nb := row("name", .Clickable);
					nb.semantic_size = .[ui.fill(), ui.px(52)];
					nb.hover_cursor = .IBeam;
					if ui.signal(nb).clicked {
						ss.rename_emoji = e.id;
						ui.editor_set_text(*ss.rename, e.name);
						app.ui.focus = 0;
					}
					ui.parent(nb); defer ui.pop_parent();
					label(tprint(":%:", e.name), .Normal, 14, T("--text-default"), 18);
				}
			}
			{
				c := table_cell(2, W[2]); ui.parent(c); defer ui.pop_parent();
				found, u := table_find(*uploaders, e.id);
				if found && u.count user_cell(u);
			}
			if row_icon_button("del", "x-small", danger = true) ss_confirm_open(.Delete_Emoji, e.id, e.name);
		}
		spacer(.Y, 24);
	}
}

// ---- Audit Log ----

AUDIT_ACTIONS :: struct { type: int; name: string; verb: string; }.[
	.{0, "All Actions", ""},
	.{1, "Update Server", "updated the server"},
	.{10, "Create Channel", "created a channel"},
	.{11, "Update Channel", "updated a channel"},
	.{12, "Delete Channel", "deleted a channel"},
	.{20, "Kick Member", "kicked"},
	.{22, "Ban Member", "banned"},
	.{23, "Unban Member", "unbanned"},
	.{24, "Update Member", "updated"},
	.{25, "Update Member Roles", "updated the roles of"},
	.{30, "Create Role", "created a role"},
	.{31, "Update Role", "updated a role"},
	.{32, "Delete Role", "deleted a role"},
	.{40, "Create Invite", "created an invite"},
	.{42, "Delete Invite", "deleted an invite"},
	.{50, "Create Webhook", "created a webhook"},
	.{51, "Update Webhook", "updated a webhook"},
	.{52, "Delete Webhook", "deleted a webhook"},
	.{60, "Create Emoji", "created an emoji"},
	.{61, "Update Emoji", "updated an emoji"},
	.{62, "Delete Emoji", "deleted an emoji"},
	.{72, "Delete Message", "deleted a message by"},
];

audit_load :: (g: *dc.Guild) {
	q := "";
	if ss.audit_user q = tprint("&user_id=%", ss.audit_user);
	if ss.audit_action q = tprint("%&action_type=%", q, AUDIT_ACTIONS[ss.audit_action].type);
	ss.loading[Req.Audit] = false;
	load(g, .Audit, tprint("/guilds/%/audit-logs?limit=50%", g.id, q));
}

audit_page :: (g: *dc.Guild) {
	r := reply(.Audit);
	users: [..]string;
	uids: [..]dc.Snowflake;
	users.allocator, uids.allocator = temp, temp;
	array_add(*users, "All Users");
	array_add(*uids, 0);
	names: Table(dc.Snowflake, etf.Map);
	names.allocator = temp;
	if r for dc.flist(dc.vmap(r.body), "users") {
		u := dc.vmap(it);
		table_set(*names, dc.fsnow(u, "id"), u);
		array_add(*users, user_display(u));
		array_add(*uids, dc.fsnow(u, "id"));
	}
	fr := row("filters");
	fr.semantic_size = .[ui.pct(1), ui.children()];
	fr.style.child_gap = 12;
	{ ui.parent(fr); defer ui.pop_parent();
		c1 := ui.box("fu");
		c1.semantic_size = .[ui.fill(), ui.children()];
		c1.layout_axis = .Y;
		{ ui.parent(c1); defer ui.pop_parent();
			field_title("Filter by User");
			pick := select_field("audituser", users, index_of(uids, ss.audit_user));
			if pick >= 0 { ss.audit_user = uids[pick]; audit_load(g); }
		}
		c2 := ui.box("fa");
		c2.semantic_size = .[ui.fill(), ui.children()];
		c2.layout_axis = .Y;
		{ ui.parent(c2); defer ui.pop_parent();
			field_title("Filter by Action");
			acts: [..]string;
			acts.allocator = temp;
			for AUDIT_ACTIONS array_add(*acts, it.name);
			pick := select_field("auditaction", acts, ss.audit_action);
			if pick >= 0 { ss.audit_action = pick; audit_load(g); }
		}
	}
	spacer(.Y, 20);
	if !loading_or(.Audit, "Couldn't load the audit log.") return;
	list := dc.flist(dc.vmap(r.body), "audit_log_entries");
	if !list.count ss_empty("No logs yet");
	for list {
		e := dc.vmap(it);
		ui.id_scope(cast(u64) dc.fsnow(e, "id"));
		defer ui.pop_seed();
		box := ui.box("entry", .Draw_Background);
		box.semantic_size = .[ui.pct(1), ui.children()];
		box.layout_axis = .Y;
		box.style.radius = all4(8);
		box.style.bg = T("--background-mod-subtle");
		ui.parent(box); defer ui.pop_parent();
		spacer(.Y, 10);
		hr := row("head");
		hr.semantic_size = .[ui.pct(1), ui.px(32)];
		_, actor := table_find(*names, dc.fsnow(e, "user_id"));
		target_id := dc.fsnow(e, "target_id");
		has_target, target := table_find(*names, target_id);
		type := dc.fint(e, "action_type");
		verb := tprint("action %", type);
		for AUDIT_ACTIONS if it.type == type && type verb = it.verb;
		{ ui.parent(hr); defer ui.pop_parent();
			spacer(.X, 12);
			avatar_box("av", dc.fsnow(e, "user_id"), 32);
			spacer(.X, 10);
			text := tprint("% %", ifx actor.count then user_display(actor) else "Someone", verb);
			if has_target && target.count text = tprint("% %", text, user_display(target));
			label(text, .Medium, 14, T("--text-strong"), 18);
			filler(.X);
			label(snowflake_date(dc.fsnow(e, "id")), .Normal, 12, T("--text-muted"), 16);
			spacer(.X, 12);
		}
		for ch: dc.flist(e, "changes") {
			cm := dc.vmap(ch);
			line := tprint("%: % → %", dc.fstr(cm, "key"), value_text(dc.vget(cm, "old_value")), value_text(dc.vget(cm, "new_value")));
			lr := row(tprint("ch%", it_index));
			lr.semantic_size = .[ui.pct(1), ui.children()];
			ui.parent(lr); defer ui.pop_parent();
			spacer(.X, 54);
			set_para("t", line, .Normal, 13, 18, T("--text-default"));
			spacer(.X, 12);
		}
		reason := dc.fstr(e, "reason");
		if reason {
			lr := row("reason");
			lr.semantic_size = .[ui.pct(1), ui.children()];
			ui.parent(lr); defer ui.pop_parent();
			spacer(.X, 54);
			set_para("t", tprint("Reason: %", reason), .Normal, 13, 18, T("--text-muted"));
			spacer(.X, 12);
		}
		spacer(.Y, 10);
	}
}

value_text :: (v: dc.V) -> string {
	if v.kind == {
	case .Nil; return "none";
	case .String; return ifx v.s then v.s else "\"\"";
	case .Int; return tprint("%", v.i);
	case .Atom; return v.s;
	}
	sb: String_Builder;
	sb.allocator = temp;
	etf.to_json(v, *sb);
	return builder_to_string(*sb,, temp);
}

// ---- actions and their confirms ----

// action sends one change, then reloads `after` (a page's list) when it succeeds.
ss_action :: (g: *dc.Guild, after: Req, method: string, path: string, body := "", reason := "") {
	if ss.busy || !net_action() return;
	ss.busy = true;
	ss.after = after;
	ss_error("");
	dc.guild_settings_call(app.client, g.id, xx Req.Action, method, path, body, reason);
}

SS_Confirm :: enum u8 { None; Revoke_Invite; Revoke_Ban; Delete_Emoji; Timeout; Transfer; Delete_Server; Pause_Invites; Delete_Role; Delete_Rule; Delete_Webhook; Delete_Template; Delete_Sticker; }

ss_confirm_open :: (kind: SS_Confirm, id: dc.Snowflake, text: string) {
	ss.confirm, ss.confirm_id = kind, id;
	ss_set(*ss.confirm_text, text);
	ui.editor_set_text(*ss.reason, "");
	ss.confirm_pick = ifx kind == .Pause_Invites then 1 else 0;
	ss.confirm_ack = false;
	ss_error("");
}

PAUSE_HOURS :: int.[1, 2, 4, 6, 12, 24];
PAUSE_LABELS :: string.["1 hour", "2 hours", "4 hours", "6 hours", "12 hours", "24 hours"];

ss_confirm_modal :: (g: *dc.Guild) {
	title, body, button: string;
	danger := true;
	t := ss.confirm_text;
	if ss.confirm == {
	case .Revoke_Invite; title, body, button = "Revoke Invite", tprint("Are you sure you want to revoke the invite %? Nobody will be able to join with it.", t), "Revoke";
	case .Revoke_Ban; title, body, button = tprint("'%'", t), "Revoke the ban? They will be able to join again with an invite.", "Revoke Ban";
	case .Delete_Emoji; title, body, button = "Delete Emoji", tprint("Are you sure you want to delete :%:? This cannot be undone.", t), "Delete";
	case .Timeout; title, body, button = tprint("Timeout %", t), "Members in timeout can't send messages, react, join voice or speak until it ends.", "Timeout";
	case .Transfer; title, body, button = "Transfer Ownership", ifx on_hosted() then tprint("% becomes the owner once they accept on their device. You'll stay a member.", t) else tprint("This will transfer ownership of % to %. This cannot be undone!", g.name, t), "Transfer Ownership";
	case .Delete_Server; title, body, button = tprint("Delete '%'", g.name), tprint("Are you sure you want to delete %? This action cannot be undone.", g.name), "Delete Server";
	case .Pause_Invites; title, body, button = "Pause Invites", "Nobody can join this server with an invite link until the pause ends or you enable invites again.", "Pause Invites";
	case .Delete_Role; title, body, button = tprint("Delete '%'", t), "Are you sure you want to delete this role? This action cannot be undone.", "Delete";
	case .Delete_Rule; title, body, button = "Delete Rule", tprint("Are you sure you want to delete the rule %? This cannot be undone.", t), "Delete";
	case .Delete_Webhook; title, body, button = "Delete Webhook", tprint("Are you sure you want to delete %? This action cannot be undone.", t), "Delete";
	case .Delete_Template; title, body, button = "Delete Template", "Are you sure you want to delete this template? Its link will stop working.", "Delete Template";
	case .Delete_Sticker; title, body, button = "Delete Sticker", tprint("Are you sure you want to delete %? This cannot be undone.", t), "Delete";
	}
	if !adm_modal_begin("ssconfirm", 440, title) {
		ss.confirm = .None;
		return;
	}
	go := false;
	spacer(.Y, 8);
	inset := row("body");
	inset.semantic_size = .[ui.pct(1), ui.children()];
	{ ui.parent(inset); defer ui.pop_parent();
		spacer(.X, 25);
		col := ui.box("col");
		col.semantic_size = .[ui.fill(), ui.children()];
		col.layout_axis = .Y;
		{ ui.parent(col); defer ui.pop_parent();
			set_para("text", body, .Normal, 16, 20, T("--text-default"));
			if ss.confirm == .Timeout || ss.confirm == .Pause_Invites {
				spacer(.Y, 16);
				field_title("Duration");
				pick: int;
				if ss.confirm == .Timeout {
					opts: [..]string;
					opts.allocator = temp;
					for TIMEOUTS array_add(*opts, it.name);
					pick = select_field("cdur", opts, ss.confirm_pick);
				} else pick = select_field("cdur", PAUSE_LABELS, ss.confirm_pick);
				if pick >= 0 ss.confirm_pick = pick;
			}
			if ss.confirm == .Timeout {
				spacer(.Y, 16);
				field_title("Reason");
				if set_input("reason", *ss.reason, "", max_runes = 512) == .Escape ss.confirm = .None;
			}
			if ss.confirm == .Delete_Server {
				spacer(.Y, 16);
				field_title("Enter server name");
				res := set_input("sname", *ss.reason, "", max_runes = 100, autofocus = true);
				if res == .Escape ss.confirm = .None;
				if res == .Submit go = true;
			}
			if ss.confirm == .Transfer {
				spacer(.Y, 16);
				if set_toggle_row("ack", tprint("I acknowledge that by transferring ownership of this server to %, it officially belongs to them.", t), "", ss.confirm_ack) ss.confirm_ack = !ss.confirm_ack;
			}
			if ss.error {
				spacer(.Y, 12);
				set_para("err", ss.error, .Normal, 14, 18, T("--text-feedback-critical"));
			}
		}
		spacer(.X, 25);
	}
	spacer(.Y, 24);
	ok := !ss.busy;
	if ss.confirm == .Delete_Server ok &&= trim(ui.editor_text(*ss.reason)) == g.name;
	if ss.confirm == .Transfer ok &&= ss.confirm_ack;
	btns := row("btns");
	btns.semantic_size = .[ui.pct(1), ui.px(40)];
	btns.style.child_gap = 8;
	{ ui.parent(btns); defer ui.pop_parent();
		spacer(.X, 25 - 8);
		if wide_button("cancel", "Cancel", .Secondary) ss.confirm = .None;
		if wide_button("go", button, ifx danger then Adm_Button.Danger else .Primary, ok) go = true;
		spacer(.X, 25 - 8);
	}
	spacer(.Y, 24);
	adm_modal_end();
	if ss.dd == "" && adm_escape() ss.confirm = .None;
	if !go || !ok return;
	reason := trim(ui.editor_text(*ss.reason));
	id := ss.confirm_id;
	if ss.confirm == {
	case .Revoke_Invite; ss_action(g, .Invites, "DELETE", tprint("/invites/%", t));
	case .Revoke_Ban; ss_action(g, .Bans, "DELETE", tprint("/guilds/%/bans/%", g.id, id));
	case .Delete_Emoji; ss_action(g, .Emojis, "DELETE", tprint("/guilds/%/emojis/%", g.id, id));
	case .Timeout;
		until := dc.ms_to_iso(wall_ms() + TIMEOUTS[ss.confirm_pick].secs * 1000);
		ss_action(g, .Members, "PATCH", tprint("/guilds/%/members/%", g.id, id), tprint("{\"communication_disabled_until\":\"%\"}", until), reason);
	case .Transfer; ss_action(g, .COUNT, "PATCH", tprint("/guilds/%", g.id), tprint("{\"owner_id\":\"%\",\"code\":null}", id));
	case .Delete_Server; ss_action(g, .COUNT, "POST", tprint("/guilds/%/delete", g.id));
	case .Delete_Role; ss_action(g, .Role_Counts, "DELETE", tprint("/guilds/%/roles/%", g.id, id));
	case .Delete_Rule; ss_action(g, .Automod, "DELETE", tprint("/guilds/%/auto-moderation/rules/%", g.id, id));
	case .Delete_Webhook; ss.hook_id = 0; ss_action(g, .Webhooks, "DELETE", tprint("/webhooks/%", id));
	case .Delete_Template; ss_action(g, .Templates, "DELETE", tprint("/guilds/%/templates/%", g.id, t));
	case .Delete_Sticker; ss_action(g, .COUNT, "DELETE", tprint("/guilds/%/stickers/%", g.id, id));
	case .Pause_Invites;
		hours := PAUSE_HOURS[ss.confirm_pick];
		ss_action(g, .COUNT, "PUT", tprint("/guilds/%/incident-actions", g.id), tprint("{\"invites_disabled_until\":\"%\",\"dms_disabled_until\":null,\"lockdown_duration_hours\":%}", dc.ms_to_iso(wall_ms() + hours * 3600_000), hours));
	}
}

// ---- Roles ----

ROLE_COLORS :: u32.[0x1abc9c, 0x2ecc71, 0x3498db, 0x9b59b6, 0xe91e63, 0xf1c40f, 0xe67e22, 0xe74c3c, 0x95a5a6, 0x607d8b,
	0x11806a, 0x1f8b4c, 0x206694, 0x71368a, 0xad1457, 0xc27c0e, 0xa84300, 0x992d22, 0x979c9f, 0x546e7a];

Perm :: struct { flag: u64; title: string; desc: string; }
Perm_Section :: struct { title: string; perms: []Perm; }

bit :: (n: int) -> u64 #expand { return (cast(u64) 1) << n; }

// The role editor's permissions, in the client's sections and order (Use Activities left out: AGENTS.md).
PERM_SECTIONS :: Perm_Section.[
	.{"General Server Permissions", .[
		.{1 << 10, "View Channels", "Allows members to view channels by default (excluding private channels)."},
		.{1 << 4, "Manage Channels", "Allows members to create, edit, or delete channels."},
		.{1 << 28, "Manage Roles", "Allows members to create new roles and edit or delete roles lower than their highest role. Also allows members to change permissions of individual channels that they have access to."},
		.{1 << 43, "Create Expressions", "Allows members to add custom emoji, stickers, and sounds in this server."},
		.{1 << 30, "Manage Expressions", "Allows members to edit or remove custom emoji, stickers, and sounds in this server."},
		.{1 << 7, "View Audit Log", "Allows members to view a record of who made which changes in this server."},
		.{1 << 19, "View Server Insights", "Allows members to view Server Insights, which shows data on community growth, engagement, and more. This will allow them to see certain data about channel activity, even for channels they cannot access."},
		.{1 << 29, "Manage Webhooks", "Allows members to create, edit, or delete webhooks, which can post messages from other apps or sites into this server."},
		.{1 << 5, "Manage Server", "Allow members to change this server's name, switch regions, view all invites, add apps to this server and create and update AutoMod rules."},
	]},
	.{"Membership Permissions", .[
		.{1 << 0, "Create Invite", "Allows members to invite new people to this server."},
		.{1 << 26, "Change Nickname", "Allows members to change their own nickname, a custom name for just this server."},
		.{1 << 27, "Manage Nicknames", "Allows members to change the nicknames of other members."},
		.{1 << 1, "Kick, Approve, and Reject Members", "Allows members to remove other members from this server. Kicked members will be able to rejoin if they have another invite."},
		.{1 << 2, "Ban Members", "Allows members to permanently ban and delete the message history of other members from this server."},
		.{1 << 40, "Timeout Members", "When you put a user in timeout they will not be able to send messages in chat, reply within threads, react to messages, or speak in voice or Stage channels."},
	]},
	.{"Text Channel Permissions", .[
		.{1 << 11, "Send Messages and Create Posts", "Allow members to send messages in text channels and create posts in forum channels."},
		.{1 << 38, "Send Messages in Threads and Posts", "Allow members to send messages in threads and in posts on forum channels."},
		.{1 << 35, "Create Public Threads", "Allow members to create threads that everyone in a channel can view."},
		.{1 << 36, "Create Private Threads", "Allow members to create invite-only threads."},
		.{1 << 14, "Embed Links", "Allows links that members share to show embedded content in text channels."},
		.{1 << 15, "Attach Files", "Allows members to upload files or media in text channels."},
		.{1 << 6, "Add Reactions", "Allows members to add new emoji reactions to a message. If this permission is disabled, members can still react using any existing reactions on a message."},
		.{1 << 18, "Use External Emoji", "Allows members to use emoji from other servers, if they're a Discord Nitro member."},
		.{1 << 37, "Use External Stickers", "Allows members to use stickers from other servers, if they're a Discord Nitro member."},
		.{1 << 17, "Mention @everyone, @here, and All Roles", "Allows members to use @everyone (everyone in the server) or @here (only online members in that channel). They can also @mention all roles, even if the role's \"Allow anyone to mention this role\" permission is disabled."},
		.{1 << 13, "Manage Messages", "Allows members to delete or remove embeds from messages by other members."},
		.{1 << 51, "Pin Messages", "Allows members to pin or unpin any message."},
		.{1 << 52, "Bypass Slowmode", "Allows members to send messages without being affected by slowmode."},
		.{1 << 34, "Manage Threads and Posts", "Allows members to rename, delete, close, and turn on slow mode for threads and posts. They can also view private threads."},
		.{1 << 16, "Read Message History", "Allows members to read previous messages sent in channels. If this permission is disabled, members only see messages sent when they are online. This does not fully apply to threads and forum posts."},
		.{1 << 12, "Send Text-to-Speech Messages", "Allows members to send text-to-speech messages by starting a message with /tts. These messages can be heard by anyone focused on the channel."},
		.{1 << 46, "Send Voice Messages", "Allows members to send voice messages."},
		.{1 << 49, "Create Polls", "Allows members to create polls."},
	]},
	.{"Voice Channel Permissions", .[
		.{1 << 20, "Connect", "Allows members to join voice channels and hear others."},
		.{1 << 21, "Speak", "Allows members to talk in voice channels. If this permission is disabled, members are default muted until somebody with the \"Mute Members\" permission un-mutes them."},
		.{1 << 9, "Video", "Allows members to share their video, screen share, or stream a game in this server."},
		.{1 << 42, "Use Soundboard", "Allows members to send sounds from server soundboard."},
		.{1 << 45, "Use External Sounds", "Allows members to use sounds from other servers, if they're a Discord Nitro member."},
		.{1 << 25, "Use Voice Activity", "Allows members to speak in voice channels by simply talking. If this permission is disabled, members are required to use Push-to-talk. Good for controlling background noise or noisy members."},
		.{1 << 8, "Priority Speaker", "Allows members to be more easily heard in voice channels. When activated, the volume of others without this permission will be automatically lowered."},
		.{1 << 22, "Mute Members", "Allows members to mute other members in voice channels for everyone."},
		.{1 << 23, "Deafen Members", "Allows members to deafen other members in voice channels, which means they won't be able to speak or hear others."},
		.{1 << 24, "Move Members", "Allows members to disconnect or move other members between voice channels that the member with this permission has access to."},
		.{1 << 48, "Set Voice Channel Status", "Allows members to create and edit voice channel status."},
	]},
	.{"Apps Permissions", .[
		.{1 << 31, "Use Application Commands", "Allows members to use commands from applications, including slash commands and context menu commands."},
		.{1 << 50, "Use External Apps", "Allows apps that members have added to their account to post messages. When disabled, the messages will be private."},
	]},
	.{"Events Permissions", .[
		.{1 << 44, "Create Events", "Allows members to create events."},
		.{1 << 33, "Manage Events", "Allows members to edit and cancel events."},
	]},
	.{"Advanced Permissions", .[
		.{1 << 3, "Administrator", "Members with this permission will have every permission and will also bypass all channel specific permissions or restrictions (for example, these members would get access to all private channels). This is a dangerous permission to grant."},
	]},
];

// The guild's roles top first, @everyone last (the order the list shows and positions count from).
roles_sorted :: (g: *dc.Guild) -> []*dc.Role {
	out := NewArray(g.roles.count, *dc.Role,, temp);
	for * g.roles out[it_index] = it;
	key :: (r: *dc.Role) -> s64 { return -(cast(s64) r.position << 32) + (cast(s64) r.id & 0xFFFF_FFFF); }
	quick_sort(out, (a: *dc.Role, b: *dc.Role) -> s64 { return key(a) - key(b); });
	return out;
}

role_of :: (g: *dc.Guild, id: dc.Snowflake) -> *dc.Role {
	for * g.roles if it.id == id return it;
	return null;
}

// The order as edited (ss.role_order, top first, @everyone left out), or the guild's when untouched.
role_order :: (g: *dc.Guild) -> []dc.Snowflake {
	if ss.role_order.count return ss.role_order;
	out: [..]dc.Snowflake;
	out.allocator = temp;
	for roles_sorted(g) if it.id != g.id array_add(*out, it.id);
	return out;
}

order_dirty :: (g: *dc.Guild) -> bool {
	if !ss.role_order.count return false;
	i := 0;
	for roles_sorted(g) {
		if it.id == g.id continue;
		if i >= ss.role_order.count || ss.role_order[i] != it.id return true;
		i += 1;
	}
	return false;
}

role_dirty :: (g: *dc.Guild) -> bool {
	r := role_of(g, ss.role_id);
	if !r return order_dirty(g);
	return order_dirty(g) || (r.id != g.id && (trim(ui.editor_text(*ss.role_name)) != r.name || ss.role_color != r.color || ss.role_hoist != r.hoist || ss.role_mentionable != r.mentionable)) || ss.role_perms != r.permissions;
}

role_reset :: (g: *dc.Guild) {
	array_reset(*ss.role_order);
	r := role_of(g, ss.role_id);
	if !r return;
	ui.editor_set_text(*ss.role_name, r.name);
	ss.role_color, ss.role_hoist, ss.role_mentionable, ss.role_perms = r.color, r.hoist, r.mentionable, r.permissions;
}

// Save Changes: the new order first (PATCH /guilds/{id}/roles [{id, position}]), then the role being edited
// (PATCH /guilds/{id}/roles/{role} with updateRole's keys).
roles_save :: (g: *dc.Guild) {
	ss_error("");
	if order_dirty(g) {
		sb: String_Builder;
		sb.allocator = temp;
		append(*sb, "[");
		order := ss.role_order;
		for order print_to_builder(*sb, "%{\"id\":\"%\",\"position\":%}", ifx it_index then "," else "", it, order.count - it_index);
		append(*sb, "]");
		save_call(g, .Save, "PATCH", tprint("/guilds/%/roles", g.id), builder_to_string(*sb,, temp));
	}
	r := role_of(g, ss.role_id);
	if !r || !role_dirty(g) || (r.permissions == ss.role_perms && r.id == g.id) return;
	name := trim(ui.editor_text(*ss.role_name));
	if r.id != g.id && !name {
		ss_error("A role needs a name.");
		return;
	}
	body := tprint("{\"name\":%,\"permissions\":\"%\",\"color\":%,\"colors\":{\"primary_color\":%,\"secondary_color\":null,\"tertiary_color\":null},\"hoist\":%,\"mentionable\":%,\"unicode_emoji\":%}",
		dc.json_quote(ifx r.id == g.id then r.name else name), ss.role_perms, ss.role_color, ss.role_color, ss.role_hoist, ss.role_mentionable, ifx r.unicode_emoji then dc.json_quote(r.unicode_emoji) else "null");
	save_call(g, .Save, "PATCH", tprint("/guilds/%/roles/%", g.id, r.id), body);
}

color_of :: (c: u32) -> ui.Color {
	if !c return T("--text-muted");
	return .{((c >> 16) & 0xFF) / 255.0, ((c >> 8) & 0xFF) / 255.0, (c & 0xFF) / 255.0, 1};
}

roles_page :: (g: *dc.Guild) {
	if ss.pending_role && role_of(g, ss.pending_role) {
		role_open(g, ss.pending_role);
		ss.pending_role = 0;
	}
	r := role_of(g, ss.role_id);
	if r { role_edit(g, r); return; }
	page_subtitle("Use roles to group your server members and assign permissions.");
	ev := role_of(g, g.id);
	if ev {
		d := row("default", .Clickable | .Draw_Background | .Hot_Animation);
		d.semantic_size = .[ui.pct(1), ui.px(64)];
		d.style.radius = all4(8);
		d.style.bg = T("--background-mod-subtle");
		d.style.bg_hot = T("--background-mod-normal");
		d.hover_cursor = .Pointer;
		if ui.signal(d).clicked role_open(g, g.id);
		ui.parent(d); defer ui.pop_parent();
		spacer(.X, 16);
		icon("ic", "group", 24, T("--interactive-icon-default"));
		spacer(.X, 12);
		col := ui.box("t");
		col.semantic_size = .[ui.fill(), ui.children()];
		col.layout_axis = .Y;
		{ ui.parent(col); defer ui.pop_parent();
			label("Default Permissions", .Semibold, 16, T("--text-strong"), 20);
			label("@everyone · applies to all server members", .Normal, 14, T("--text-muted"), 18);
		}
		icon("chev", "chevron-small-right", 20, T("--interactive-icon-default"));
		spacer(.X, 12);
	}
	spacer(.Y, 20);
	hr := row("rhead");
	hr.semantic_size = .[ui.pct(1), ui.px(40)];
	{ ui.parent(hr); defer ui.pop_parent();
		set_para("rnote", "Members use the colour of the highest role they have on this list. Use the arrows to reorder roles.", .Normal, 14, 18, T("--text-muted"));
		spacer(.X, 16);
		if set_button("Create Role##create", .Primary, !ss.busy && !role_dirty(g)) && net_action() {
			ss.busy = true;
			ss.after = .COUNT;
			dc.guild_settings_call(app.client, g.id, xx Req.Create_Role, "POST", tprint("/guilds/%/roles", g.id), "{\"name\":\"new role\",\"color\":0,\"colors\":{\"primary_color\":0,\"secondary_color\":null,\"tertiary_color\":null},\"permissions\":\"0\"}");
		}
	}
	spacer(.Y, 12);
	counts := reply(.Role_Counts);
	order := role_order(g);
	W :: float32.[5, 2];
	table_header("rth", .[tprint("ROLES — %", order.count), "MEMBERS"], W);
	top := highest_position(g);
	for id, i: order {
		role := role_of(g, id);
		if !role continue;
		ui.id_scope(cast(u64) id);
		defer ui.pop_seed();
		_, sig := table_row_begin("r");
		defer ui.pop_parent();
		{
			c := table_cell(0, W[0]); ui.parent(c); defer ui.pop_parent();
			dot := ui.box("dot", .Draw_Background);
			dot.semantic_size = .[ui.px(12), ui.px(12)];
			dot.style.radius = all4(6);
			dot.style.bg = color_of(role.color);
			spacer(.X, 10);
			label(role.name, .Medium, 15, T("--text-strong"), 20);
			if role.managed { spacer(.X, 8); icon("lock", "lock", 14, T("--text-muted")); }
		}
		{
			c := table_cell(1, W[1]); ui.parent(c); defer ui.pop_parent();
			n := ifx counts then dc.fint(dc.vmap(counts.body), tprint("%", id)) else 0;
			icon("ppl", "user", 14, T("--text-muted"));
			spacer(.X, 6);
			label(tprint("%", n), .Normal, 14, T("--text-default"), 18);
		}
		movable := role.position < top || g.owner_id == store().me;
		if movable && i > 0 && row_icon_button("up", "chevron-small-up") role_move(g, i, -1);
		else if movable && i + 1 < order.count && row_icon_button("down", "chevron-small-down") role_move(g, i, 1);
		if sig.clicked && !role_dirty(g) role_open(g, id);
	}
}

// Our highest role's position: roles at or above it can't be edited or moved (the owner may do anything).
highest_position :: (g: *dc.Guild) -> int {
	me := dc.member_get(store(), g.id, store().me);
	top := 0;
	if me for g.roles if it.position > top && array_find(me.roles, it.id) top = it.position;
	return top;
}

role_move :: (g: *dc.Guild, i: int, d: int) {
	if !ss.role_order.count for role_order(g) array_add(*ss.role_order, it);
	j := i + d;
	if j < 0 || j >= ss.role_order.count return;
	ss.role_order[i], ss.role_order[j] = ss.role_order[j], ss.role_order[i];
}

role_open :: (g: *dc.Guild, id: dc.Snowflake) {
	ss.role_id = id;
	ss.role_tab = ifx id == g.id then 1 else 0;
	role_reset(g);
	ui.editor_set_text(*ss.search, "");
	if id != g.id role_members_load(g);
}

role_members_load :: (g: *dc.Guild) {
	ss.loading[Req.Role_Members] = false;
	load_body(g, .Role_Members, "POST", tprint("/guilds/%/members-search", g.id), tprint("{\"or_query\":{},\"and_query\":{\"role_ids\":{\"and_query\":[\"%\"]}},\"limit\":250}", ss.role_id));
}

ROLE_TABS :: string.["Display", "Permissions", "Manage Members"];

role_edit :: (g: *dc.Guild, r: *dc.Role) {
	everyone := r.id == g.id;
	editable := !r.managed && (r.position < highest_position(g) || g.owner_id == store().me);
	br := row("back", .Clickable);
	br.semantic_size = .[ui.children(), ui.px(24)];
	br.hover_cursor = .Pointer;
	if ui.signal(br).clicked && !role_dirty(g) ss.role_id = 0;
	{ ui.parent(br); defer ui.pop_parent();
		icon("ic", "arrow-large-left", 16, T("--interactive-icon-default"));
		spacer(.X, 6);
		label("BACK", .Bold, 12, T("--text-muted"), 16);
	}
	spacer(.Y, 12);
	hr := row("title");
	hr.semantic_size = .[ui.pct(1), ui.px(28)];
	{ ui.parent(hr); defer ui.pop_parent();
		label(tprint("EDIT ROLE — %", ifx everyone then "@everyone" else r.name), .Bold, 14, T("--text-strong"), 18);
		filler(.X);
		if !everyone && editable && set_button("Delete Role##delrole", .Danger, !ss.busy, 32) ss_confirm_open(.Delete_Role, r.id, r.name);
	}
	spacer(.Y, 12);
	tabs := row("tabs");
	tabs.semantic_size = .[ui.pct(1), ui.px(36)];
	tabs.style.child_gap = 24;
	{ ui.parent(tabs); defer ui.pop_parent();
		for ROLE_TABS {
			if everyone && it_index != 1 continue;
			sel := ss.role_tab == it_index;
			t := ui.box(tprint("tab%", it_index), .Clickable);
			t.semantic_size = .[ui.children(), ui.px(36)];
			t.layout_axis = .Y;
			t.hover_cursor = .Pointer;
			if ui.signal(t).clicked ss.role_tab = it_index;
			ui.parent(t); defer ui.pop_parent();
			label(it, .Medium, 16, ifx sel then T("--text-strong") else T("--text-muted"), 20);
			spacer(.Y, 8);
			if sel {
				u := ui.box("u", .Draw_Background);
				u.semantic_size = .[ui.px(ui.layout_text(F(.Medium), 16, it, -1).width), ui.px(2)];
				u.style.bg = T("--background-brand");
			}
		}
	}
	set_divider();
	if !editable {
		set_para("locked", ifx r.managed then "This role is managed by an integration and can't be edited here." else "You can only edit roles below your highest role.", .Normal, 14, 18, T("--text-feedback-warning"));
		spacer(.Y, 16);
	}
	if ss.role_tab == {
	case 0;
		field_title("Role name");
		if set_input("rname", *ss.role_name, "", max_runes = 100) == .Escape ss.field_escape = true;
		spacer(.Y, 24);
		field_title("Role Color");
		set_para("chelp", "Members use the colour of the highest role they have on the roles list.", .Normal, 14, 18, T("--text-muted"));
		spacer(.Y, 12);
		grid := row("colors");
		grid.semantic_size = .[ui.pct(1), ui.children()];
		grid.cross_align = .Start;
		{ ui.parent(grid); defer ui.pop_parent();
			def := ui.box("c0", .Clickable | .Draw_Background | .Draw_Border);
			def.semantic_size = .[ui.px(66), ui.px(50)];
			def.style.radius = all4(4);
			def.style.bg = rgb(0x99aab5);
			def.style.border = ifx ss.role_color == 0 then 3.0 else 0;
			def.style.border_color = T("--text-strong");
			if ui.signal(def).clicked && editable ss.role_color = 0;
			spacer(.X, 12);
			col := ui.box("sw");
			col.semantic_size = .[ui.children(), ui.children()];
			col.layout_axis = .Y;
			ui.parent(col); defer ui.pop_parent();
			for line: 0..1 {
				lr := row(tprint("l%", line));
				lr.semantic_size = .[ui.children(), ui.px(28)];
				lr.style.child_gap = 8;
				ui.parent(lr); defer ui.pop_parent();
				for k: 0..9 {
					c := ROLE_COLORS[line * 10 + k];
					sw := ui.box(tprint("s%", k), .Clickable | .Draw_Background | .Draw_Border);
					sw.semantic_size = .[ui.px(20), ui.px(20)];
					sw.style.radius = all4(4);
					sw.style.bg = rgb(c);
					sw.style.border = ifx ss.role_color == c then 2.0 else 0;
					sw.style.border_color = T("--text-strong");
					sw.hover_cursor = .Pointer;
					if ui.signal(sw).clicked && editable ss.role_color = c;
				}
			}
		}
		set_divider();
		if set_toggle_row("hoist", "Display role members separately from online members", "", ss.role_hoist, !editable) ss.role_hoist = !ss.role_hoist;
		set_divider();
		if set_toggle_row("mention", "Allow anyone to @mention this role", "Note: Members with the \"Mention @everyone, @here, and All Roles\" permission will always be able to ping this role.", ss.role_mentionable, !editable) ss.role_mentionable = !ss.role_mentionable;
	case 1;
		cr := row("clear");
		cr.semantic_size = .[ui.pct(1), ui.px(32)];
		{ ui.parent(cr); defer ui.pop_parent();
			filler(.X);
			if set_button("Clear permissions##clear", .Link, editable && ss.role_perms != 0, 32) ss.role_perms = 0;
		}
		mine := dc.guild_permissions(store(), g.id);
		for sec: PERM_SECTIONS {
			spacer(.Y, 16);
			label(sec.title, .Bold, 12, T("--text-muted"), 16);
			spacer(.Y, 12);
			for p: sec.perms {
				on := (ss.role_perms & p.flag) != 0;
				// a member can't grant what they don't have (the owner and administrators can)
				can := editable && (mine & (p.flag | dc.PERM_ADMINISTRATOR)) != 0;
				if set_toggle_row(tprint("p%", p.flag), p.title, p.desc, on, !can) ss.role_perms ^= p.flag;
				set_divider();
			}
		}
	case 2;
		role_members_tab(g, r, editable);
	}
}

rgb :: (c: u32) -> ui.Color { return .{((c >> 16) & 0xFF) / 255.0, ((c >> 8) & 0xFF) / 255.0, (c & 0xFF) / 255.0, 1}; }

role_members_tab :: (g: *dc.Guild, r: *dc.Role, editable: bool) {
	res := set_input("addsearch", *ss.search, "Search members to add (press Enter)");
	if res == .Escape ss.field_escape = true;
	if res == .Submit && trim(ui.editor_text(*ss.search)) {
		ss.loading[Req.Members] = false;
		members_search(g);
	}
	found := reply(.Members);
	if found && trim(ui.editor_text(*ss.search)) {
		spacer(.Y, 8);
		for dc.flist(dc.vmap(found.body), "members") {
			mm := dc.fmap(dc.vmap(it), "member");
			u := dc.fmap(mm, "user");
			uid := dc.fsnow(u, "id");
			has := false;
			for dc.flist(mm, "roles") if dc.vsnow(it) == r.id has = true;
			if has continue;
			ui.id_scope(cast(u64) uid);
			defer ui.pop_seed();
			table_units(.[1]);
			table_row_begin("add");
			defer ui.pop_parent();
			{ c := table_cell(0, 1); ui.parent(c); defer ui.pop_parent(); user_cell(u); }
			if editable && row_icon_button("add", "plus-small") ss_action(g, .Role_Members, "PATCH", tprint("/guilds/%/roles/%/members", g.id, r.id), tprint("{\"member_ids\":[\"%\"]}", uid));
		}
		set_divider();
	}
	spacer(.Y, 12);
	if !loading_or(.Role_Members, "Couldn't load the role's members.") return;
	list := dc.flist(dc.vmap(reply(.Role_Members).body), "members");
	if !list.count ss_empty("No members have this role yet.");
	table_units(.[1]);
	for list {
		mm := dc.fmap(dc.vmap(it), "member");
		u := dc.fmap(mm, "user");
		uid := dc.fsnow(u, "id");
		ui.id_scope(cast(u64) uid);
		defer ui.pop_seed();
		table_row_begin("m");
		defer ui.pop_parent();
		{ c := table_cell(0, 1); ui.parent(c); defer ui.pop_parent(); user_cell(u); }
		if editable && row_icon_button("remove", "x-small", danger = true) {
			roles: [..]string;
			roles.allocator = temp;
			for dc.flist(mm, "roles") if dc.vsnow(it) != r.id array_add(*roles, tprint("\"%\"", dc.vsnow(it)));
			ss_action(g, .Role_Members, "PATCH", tprint("/guilds/%/members/%", g.id, uid), tprint("{\"roles\":[%]}", join(..roles, ",",, temp)));
		}
	}
}

// ---- Safety Setup ----

VERIFICATION :: struct { name: string; desc: string; }.[
	.{"None", "Unrestricted"},
	.{"Low", "Must have a verified email on their Discord account."},
	.{"Medium", "Must also be registered on Discord for longer than 5 minutes."},
	.{"High", "Must also be a member of this server for longer than 10 minutes."},
	.{"Highest", "Must have a verified phone on their Discord account."},
];

// Explicit image filter choices, as the client lists them: value then wording.
EXPLICIT :: struct { value: int; name: string; desc: string; }.[
	.{2, "Filter messages from all members", "All messages will be filtered for sensitive image-based media."},
	.{1, "Filter messages from server members without roles", "Messages from server members without a role will be filtered for sensitive image-based media."},
	.{0, "Do not filter", "Messages will not be filtered for sensitive image-based media."},
];

// A choice with a description under it (radio on the left); true when picked.
radio_choice :: (id: string, title: string, desc: string, on: bool, enabled := true) -> bool {
	r := row(id, .Clickable | .Draw_Background | .Hot_Animation);
	r.semantic_size = .[ui.pct(1), ui.children()];
	r.style.radius = all4(8);
	r.style.bg = ifx on then T("--background-mod-normal") else T("--background-mod-subtle");
	r.style.bg_hot = T("--background-mod-normal");
	r.hover_cursor = .Pointer;
	if !enabled r.flags |= .Disabled;
	sig := ui.signal(r);
	{ ui.parent(r); defer ui.pop_parent();
		spacer(.X, 12);
		radio_dot(on);
		spacer(.X, 12);
		col := ui.box("col");
		col.semantic_size = .[ui.fill(), ui.children()];
		col.layout_axis = .Y;
		ui.parent(col); defer ui.pop_parent();
		spacer(.Y, 10);
		label(title, .Medium, 16, T("--text-strong"), 20);
		spacer(.Y, 2);
		set_para("d", desc, .Normal, 14, 18, T("--text-muted"));
		spacer(.Y, 10);
	}
	spacer(.Y, 8);
	return sig.clicked && !on && enabled;
}

AUTOMOD_KEYWORD :: 1;
AUTOMOD_SPAM :: 3;
AUTOMOD_MENTION_SPAM :: 5;

safety_page :: (g: *dc.Guild) {
	community := dc.guild_has_feature(g, "COMMUNITY");
	section_heading("verif", "Verification Level", "Members of the server must meet the following criteria before they can send messages in text channels or initiate a direct message conversation. If a member has an assigned role this does not apply.");
	for VERIFICATION {
		if radio_choice(tprint("v%", it_index), it.name, ifx community && it_index == 0 then "This option is not available for Community Servers." else it.desc, g.verification_level == it_index, !ss.busy && !(community && it_index == 0))
			ss_action(g, .COUNT, "PATCH", tprint("/guilds/%", g.id), tprint("{\"verification_level\":%}", it_index));
	}
	set_divider();
	section_heading("explicit", "Explicit image filter", "Automatically scan and delete messages sent in this server that contain explicit media.");
	for EXPLICIT {
		if radio_choice(tprint("x%", it.value), it.name, ifx community && it.value != 2 then "This option is not available for Community Servers." else it.desc, g.explicit_content_filter == it.value, !ss.busy && !(community && it.value != 2))
			ss_action(g, .COUNT, "PATCH", tprint("/guilds/%", g.id), tprint("{\"explicit_content_filter\":%}", it.value));
	}
	if g.owner_id == store().me {
		set_divider();
		if set_toggle_row("mfa", "Require 2FA for moderator actions", "Moderators must have two-factor authentication enabled to ban, kick, or timeout members and delete messages.", g.mfa_level == 1, ss.busy)
			ss_action(g, .COUNT, "POST", tprint("/guilds/%/mfa", g.id), tprint("{\"level\":%}", ifx g.mfa_level == 1 then 0 else 1));
	}
	set_divider();
	automod_section(g);
}

automod_section :: (g: *dc.Guild) {
	section_heading("automod", "AutoMod", "Set up AutoMod to automatically filter messages in this server with the rules below. Members with Manage Server or Administrator are exempt.");
	if !loading_or(.Automod, "Couldn't load the AutoMod rules.") return;
	rules := dc.vlist(reply(.Automod).body);
	has: [7]bool;
	for rules {
		r := dc.vmap(it);
		t := dc.fint(r, "trigger_type");
		if t >= 0 && t < has.count has[t] = true;
		ui.id_scope(cast(u64) dc.fsnow(r, "id"));
		defer ui.pop_seed();
		card := ui.box("rule", .Draw_Background);
		card.semantic_size = .[ui.pct(1), ui.children()];
		card.layout_axis = .Y;
		card.style.radius = all4(8);
		card.style.bg = T("--background-mod-subtle");
		{ ui.parent(card); defer ui.pop_parent();
			spacer(.Y, 12);
			hr := row("h");
			hr.semantic_size = .[ui.pct(1), ui.children()];
			{ ui.parent(hr); defer ui.pop_parent();
				spacer(.X, 16);
				col := ui.box("t");
				col.semantic_size = .[ui.fill(), ui.children()];
				col.layout_axis = .Y;
				{ ui.parent(col); defer ui.pop_parent();
					label(dc.fstr(r, "name"), .Semibold, 16, T("--text-strong"), 20);
					meta := dc.fmap(r, "trigger_metadata");
					desc := "";
					if t == {
					case AUTOMOD_KEYWORD; desc = tprint("Blocks messages containing % word%.", dc.flist(meta, "keyword_filter").count, ifx dc.flist(meta, "keyword_filter").count == 1 then "" else "s");
					case AUTOMOD_SPAM; desc = "Blocks messages suspected to be spam.";
					case AUTOMOD_MENTION_SPAM; desc = tprint("Blocks messages with more than % mentions.", dc.fint(meta, "mention_total_limit"));
					case 4; desc = "Blocks words from Discord's commonly flagged lists.";
					case 6; desc = "Blocks words in member profile names.";
					}
					if desc { spacer(.Y, 2); set_para("d", desc, .Normal, 14, 18, T("--text-muted")); }
				}
				spacer(.X, 12);
				on := dc.fbool(r, "enabled");
				sw := ui.box("sw", .Clickable);
				sw.semantic_size = .[ui.px(40), ui.px(24)];
				sw.hover_cursor = .Pointer;
				if ui.signal(sw).clicked && !ss.busy ss_action(g, .Automod, "PATCH", tprint("/guilds/%/auto-moderation/rules/%", g.id, dc.fsnow(r, "id")), automod_rule_body(r, !on, true));
				{ ui.parent(sw); defer ui.pop_parent(); set_switch(on); }
				spacer(.X, 8);
				if row_icon_button("del", "trash", danger = true) ss_confirm_open(.Delete_Rule, dc.fsnow(r, "id"), dc.fstr(r, "name"));
				spacer(.X, 12);
			}
			spacer(.Y, 12);
		}
		spacer(.Y, 8);
	}
	spacer(.Y, 8);
	if !has[AUTOMOD_KEYWORD] {
		field_title("Block Custom Words");
		if set_input("words", *ss.words, "Words to block, separated by commas", multiline = true, max_runes = 6000, min_h = 60) == .Escape ss.field_escape = true;
		spacer(.Y, 8);
		words := split_words(ui.editor_text(*ss.words));
		if set_button("Create Rule##kw", .Primary, words.count > 0 && !ss.busy) {
			list: [..]string;
			list.allocator = temp;
			for words array_add(*list, dc.json_quote(it));
			ss_action(g, .Automod, "POST", tprint("/guilds/%/auto-moderation/rules", g.id), automod_new_body(g, "Block Custom Words", AUTOMOD_KEYWORD, tprint("{\"keyword_filter\":[%],\"regex_patterns\":[],\"allow_list\":[]}", join(..list, ",",, temp))));
			ui.editor_set_text(*ss.words, "");
		}
		spacer(.Y, 16);
	}
	br := row("addrules");
	br.semantic_size = .[ui.pct(1), ui.px(38)];
	br.style.child_gap = 8;
	ui.parent(br); defer ui.pop_parent();
	if !has[AUTOMOD_MENTION_SPAM] && set_button("Block Mention Spam##ms", .Secondary, !ss.busy)
		ss_action(g, .Automod, "POST", tprint("/guilds/%/auto-moderation/rules", g.id), automod_new_body(g, "Block Mention Spam", AUTOMOD_MENTION_SPAM, "{\"mention_total_limit\":20,\"mention_raid_protection_enabled\":true}"));
	if !has[AUTOMOD_SPAM] && set_button("Block Suspected Spam Content##sp", .Secondary, !ss.busy)
		ss_action(g, .Automod, "POST", tprint("/guilds/%/auto-moderation/rules", g.id), automod_new_body(g, "Block Suspected Spam Content", AUTOMOD_SPAM, "{}"));
}

// Comma or newline separated words, trimmed, at most 1000 (Discord's keyword_filter cap).
split_words :: (text: string) -> []string {
	out: [..]string;
	out.allocator = temp;
	for part: split(text, ",",, temp) for w: split(part, "\n",, temp) {
		t := trim(w);
		if t && out.count < 1000 array_add(*out, t);
	}
	return out;
}

// A rule as the client sends it (`T`): id, name, guild_id, event_type, trigger_type, trigger_metadata,
// actions, enabled, creator_id, position, exempt_channels, exempt_roles.
automod_rule_body :: (r: etf.Map, enabled: bool, with_id: bool) -> string {
	sb: String_Builder;
	sb.allocator = temp;
	json :: (sb: *String_Builder, v: dc.V) {
		if v.kind == .Nil { append(sb, "null"); return; }
		etf.to_json(v, sb);
	}
	append(*sb, "{");
	if with_id print_to_builder(*sb, "\"id\":\"%\",", dc.fsnow(r, "id"));
	print_to_builder(*sb, "\"name\":%,\"guild_id\":\"%\",\"event_type\":%,\"trigger_type\":%,\"trigger_metadata\":", dc.json_quote(dc.fstr(r, "name")), dc.fsnow(r, "guild_id"), dc.fint(r, "event_type"), dc.fint(r, "trigger_type"));
	json(*sb, dc.vget(r, "trigger_metadata"));
	append(*sb, ",\"actions\":");
	json(*sb, dc.vget(r, "actions"));
	print_to_builder(*sb, ",\"enabled\":%,\"creator_id\":\"%\",\"position\":%,\"exempt_channels\":", enabled, dc.fsnow(r, "creator_id"), dc.fint(r, "position"));
	json(*sb, dc.vget(r, "exempt_channels"));
	append(*sb, ",\"exempt_roles\":");
	json(*sb, dc.vget(r, "exempt_roles"));
	append(*sb, "}");
	return builder_to_string(*sb,, temp);
}

// A new rule that blocks the message (action type 1), enabled, exempting nobody.
automod_new_body :: (g: *dc.Guild, name: string, trigger: int, metadata: string) -> string {
	return tprint("{\"name\":%,\"guild_id\":\"%\",\"event_type\":1,\"trigger_type\":%,\"trigger_metadata\":%,\"actions\":[{\"type\":1,\"metadata\":{}}],\"enabled\":true,\"exempt_channels\":[],\"exempt_roles\":[]}",
		dc.json_quote(name), g.id, trigger, metadata);
}

// ---- Integrations ----

WEBHOOK_NAMES :: string.["Spidey Bot", "Captain Hook"];

webhook_url :: (h: etf.Map) -> string {
	if on_hosted() {
		cfg := app.client.cfg.hosted;
		return tprint("https://%:%/api/webhooks/%/%", cfg.host, cfg.port, dc.fsnow(h, "id"), dc.fstr(h, "token"));
	}
	return tprint("https://discord.com/api/webhooks/%/%", dc.fsnow(h, "id"), dc.fstr(h, "token"));
}

hook_of :: (id: dc.Snowflake) -> etf.Map {
	r := reply(.Webhooks);
	if r for dc.vlist(r.body) if dc.fsnow(dc.vmap(it), "id") == id return dc.vmap(it);
	return .[];
}

hook_dirty :: () -> bool {
	h := hook_of(ss.hook_id);
	return h.count > 0 && (trim(ui.editor_text(*ss.hook_name)) != dc.fstr(h, "name") || ss.hook_channel != dc.fsnow(h, "channel_id"));
}

hook_open :: (h: etf.Map) {
	ss.hook_id = dc.fsnow(h, "id");
	ui.editor_set_text(*ss.hook_name, dc.fstr(h, "name"));
	ss.hook_channel = dc.fsnow(h, "channel_id");
}

integrations_page :: (g: *dc.Guild) {
	page_subtitle("Customize your server with integrations. Manage webhooks, followed channels and apps.");
	if !loading_or(.Webhooks, "Couldn't load the webhooks.") return;
	hooks := dc.vlist(reply(.Webhooks).body);
	hr := row("whead");
	hr.semantic_size = .[ui.pct(1), ui.px(40)];
	{ ui.parent(hr); defer ui.pop_parent();
		n := 0;
		for hooks if dc.fint(dc.vmap(it), "type") == 1 n += 1;
		label(tprint("Webhooks (%)", n), .Semibold, 16, T("--text-strong"), 20);
		filler(.X);
		names, ids := channel_options(g, "", false);
		if ids.count > 1 && set_button("New Webhook##new", .Primary, !ss.busy && !hook_dirty())
			ss_action(g, .Webhooks, "POST", tprint("/channels/%/webhooks", ifx g.system_channel_id then g.system_channel_id else ids[1]), tprint("{\"name\":%}", dc.json_quote(WEBHOOK_NAMES[random_get() % 2])));
	}
	set_para("whelp", "Webhooks are a simple way to post messages from other apps and websites into this server.", .Normal, 14, 18, T("--text-muted"));
	spacer(.Y, 12);
	for hooks {
		h := dc.vmap(it);
		if dc.fint(h, "type") != 1 continue;
		id := dc.fsnow(h, "id");
		ui.id_scope(cast(u64) id);
		defer ui.pop_seed();
		open := ss.hook_id == id;
		card := ui.box("hook", .Draw_Background);
		card.semantic_size = .[ui.pct(1), ui.children()];
		card.layout_axis = .Y;
		card.style.radius = all4(8);
		card.style.bg = T("--background-mod-subtle");
		ui.parent(card); defer ui.pop_parent();
		head := row("h", .Clickable);
		head.semantic_size = .[ui.pct(1), ui.px(64)];
		head.hover_cursor = .Pointer;
		if ui.signal(head).clicked && !hook_dirty() {
			if open ss.hook_id = 0; else hook_open(h);
		}
		{ ui.parent(head); defer ui.pop_parent();
			spacer(.X, 16);
			avatar_box("av", id, 40);
			spacer(.X, 12);
			col := ui.box("t");
			col.semantic_size = .[ui.fill(), ui.children()];
			col.layout_axis = .Y;
			{ ui.parent(col); defer ui.pop_parent();
				label(dc.fstr(h, "name"), .Semibold, 16, T("--text-strong"), 20);
				u := dc.fmap(h, "user");
				label(tprint("Created on % by %", snowflake_date(id), ifx u.count then user_display(u) else "someone"), .Normal, 12, T("--text-muted"), 16);
			}
			icon("chev", ifx open then "chevron-small-up" else "chevron-small-down", 20, T("--interactive-icon-default"));
			spacer(.X, 16);
		}
		if !open continue;
		inner := row("edit");
		inner.semantic_size = .[ui.pct(1), ui.children()];
		{ ui.parent(inner); defer ui.pop_parent();
			spacer(.X, 16);
			col := ui.box("f");
			col.semantic_size = .[ui.fill(), ui.children()];
			col.layout_axis = .Y;
			{ ui.parent(col); defer ui.pop_parent();
				field_title("Name");
				if set_input("hname", *ss.hook_name, "", max_runes = 80) == .Escape ss.field_escape = true;
				spacer(.Y, 16);
				field_title("Channel");
				names, ids := channel_options(g, "", false);
				pick := select_field("hchan", array_view(names, 1, names.count - 1), max(0, index_of(ids, ss.hook_channel) - 1));
				if pick >= 0 ss.hook_channel = ids[pick + 1];
				spacer(.Y, 16);
				br := row("btns");
				br.semantic_size = .[ui.pct(1), ui.px(38)];
				br.style.child_gap = 8;
				{ ui.parent(br); defer ui.pop_parent();
					if set_button("Copy Webhook URL##copy", .Secondary) clipboard_set(webhook_url(h));
					filler(.X);
					if set_button("Delete Webhook##del", .Danger, !ss.busy) ss_confirm_open(.Delete_Webhook, id, dc.fstr(h, "name"));
				}
				spacer(.Y, 16);
			}
			spacer(.X, 16);
		}
		spacer(.Y, 8);
	}
	followed := 0;
	for hooks if dc.fint(dc.vmap(it), "type") == 2 followed += 1;
	if followed {
		set_divider();
		label(tprint("Channels Followed (%)", followed), .Semibold, 16, T("--text-strong"), 20);
		spacer(.Y, 12);
		table_units(.[1]);
		for hooks {
			h := dc.vmap(it);
			if dc.fint(h, "type") != 2 continue;
			id := dc.fsnow(h, "id");
			ui.id_scope(cast(u64) id);
			defer ui.pop_seed();
			table_row_begin("f");
			defer ui.pop_parent();
			{
				c := table_cell(0, 1); ui.parent(c); defer ui.pop_parent();
				src := dc.fmap(h, "source_guild");
				ch := dc.channel_get(store(), dc.fsnow(h, "channel_id"));
				label(tprint("% #% → #%", dc.fstr(src, "name"), dc.fstr(dc.fmap(h, "source_channel"), "name"), ifx ch then ch.name else "?"), .Medium, 14, T("--text-strong"), 18);
			}
			if row_icon_button("unfollow", "x-small", danger = true) ss_confirm_open(.Delete_Webhook, id, dc.fstr(h, "name"));
		}
	}
	if on_hosted() return;
	set_divider();
	label("Bots and Apps", .Semibold, 16, T("--text-strong"), 20);
	spacer(.Y, 12);
	r := reply(.Integrations);
	n := 0;
	if r for dc.vlist(r.body) {
		it_m := dc.vmap(it);
		app_m := dc.fmap(it_m, "application");
		if !app_m.count continue;
		n += 1;
		ui.id_scope(cast(u64) dc.fsnow(it_m, "id"));
		defer ui.pop_seed();
		rr := row("app");
		rr.semantic_size = .[ui.pct(1), ui.px(40)];
		ui.parent(rr); defer ui.pop_parent();
		label(dc.fstr(app_m, "name"), .Medium, 14, T("--text-strong"), 18);
		filler(.X);
		label(tprint("Added %", ss_date(dc.iso_to_ms(dc.fstr(it_m, "synced_at")))), .Normal, 12, T("--text-muted"), 16);
	}
	if !n set_para("noapps", "No apps have been added to this server.", .Normal, 14, 18, T("--text-muted"));
	spacer(.Y, 16);
	if set_button("App Directory##appdir", .Secondary) open_url("https://discord.com/discovery/applications");
}

// ---- Server Template ----

templates_page :: (g: *dc.Guild) {
	page_subtitle("Templates are an easy way to share your server setup and help anyone create a server instantly. When someone uses your server template link, they create a new server pre-filled with the same channels, roles, permissions, and settings as yours. Messages, members and your server's icon aren't copied.");
	if !loading_or(.Templates, "Couldn't load the template.") return;
	list := dc.vlist(reply(.Templates).body);
	if !list.count {
		field_title("Template Title");
		if set_input("ttitle", *ss.hook_name, "Who is this server for? E.g. School Club, Artists' Community", max_runes = 100) == .Escape ss.field_escape = true;
		spacer(.Y, 16);
		field_title("Template Description");
		if set_input("tdesc", *ss.words, "What can people do in this server?", multiline = true, max_runes = 120, min_h = 80) == .Escape ss.field_escape = true;
		spacer(.Y, 16);
		name := trim(ui.editor_text(*ss.hook_name));
		if set_button("Generate Template##gen", .Primary, name.count >= 2 && !ss.busy)
			ss_action(g, .Templates, "POST", tprint("/guilds/%/templates", g.id), tprint("{\"name\":%,\"description\":%}", dc.json_quote(name), dc.json_quote(trim(ui.editor_text(*ss.words)))));
		return;
	}
	t := dc.vmap(list[0]);
	code := dc.fstr(t, "code");
	field_title(dc.fstr(t, "name"));
	desc := dc.fstr(t, "description");
	if desc { set_para("tdesc", desc, .Normal, 14, 18, T("--text-default")); spacer(.Y, 8); }
	field_title("Template Link");
	copy_field("tlink", tprint("https://discord.new/%", code));
	spacer(.Y, 8);
	set_para("tsync", tprint("Last sync: %", ss_date(dc.iso_to_ms(dc.fstr(t, "updated_at")))), .Normal, 12, 16, T("--text-muted"));
	if dc.fbool(t, "is_dirty") {
		spacer(.Y, 8);
		set_para("tdirty", "This template has unsynced changes.", .Normal, 14, 18, T("--text-feedback-warning"));
	}
	spacer(.Y, 16);
	br := row("tbtns");
	br.semantic_size = .[ui.pct(1), ui.px(38)];
	br.style.child_gap = 8;
	ui.parent(br); defer ui.pop_parent();
	if set_button("Sync Template##sync", .Primary, dc.fbool(t, "is_dirty") && !ss.busy) ss_action(g, .Templates, "PUT", tprint("/guilds/%/templates/%", g.id, code));
	if set_button("Delete Template##deltpl", .Danger, !ss.busy) ss_confirm_open(.Delete_Template, 0, code);
}

// ---- Community ----

LOCALES :: [2]string.[
	.["en-US", "English, USA"], .["en-GB", "English, UK"], .["bg", "Bulgarian"], .["zh-CN", "Chinese, China"], .["zh-TW", "Chinese, Taiwan"],
	.["hr", "Croatian"], .["cs", "Czech"], .["da", "Danish"], .["nl", "Dutch"], .["fi", "Finnish"], .["fr", "French"], .["de", "German"],
	.["el", "Greek"], .["hi", "Hindi"], .["hu", "Hungarian"], .["id", "Indonesian"], .["it", "Italian"], .["ja", "Japanese"], .["ko", "Korean"],
	.["lt", "Lithuanian"], .["no", "Norwegian"], .["pl", "Polish"], .["pt-BR", "Portuguese, Brazilian"], .["ro", "Romanian, Romania"],
	.["ru", "Russian"], .["es-ES", "Spanish"], .["es-419", "Spanish, LATAM"], .["sv-SE", "Swedish"], .["th", "Thai"], .["tr", "Turkish"],
	.["uk", "Ukrainian"], .["vi", "Vietnamese"],
];

Community_Form :: struct {
	rules: dc.Snowflake; // 1: "Create one for me" (Enable Community)
	updates: dc.Snowflake;
	safety: dc.Snowflake;
	locale: int; // index into LOCALES
	agree: bool;
}

community_form_of :: (g: *dc.Guild) -> Community_Form {
	f := Community_Form.{rules = g.rules_channel_id, updates = g.public_updates_channel_id, safety = g.safety_alerts_channel_id};
	for LOCALES if it[0] == g.preferred_locale f.locale = it_index;
	if !dc.guild_has_feature(g, "COMMUNITY") {
		if !f.rules f.rules = 1;
		if !f.updates f.updates = 1;
	}
	return f;
}

community_dirty :: (g: *dc.Guild) -> bool {
	if !dc.guild_has_feature(g, "COMMUNITY") return false; // Enable Community is a button, not a form
	a, b := ss.comm, community_form_of(g);
	return a.rules != b.rules || a.updates != b.updates || a.safety != b.safety || a.locale != b.locale;
}

// The guild's features as a JSON list, with add added and drop left out.
features_json :: (g: *dc.Guild, add := "", drop := "") -> string {
	list: [..]string;
	list.allocator = temp;
	for g.features if it != drop && it != add array_add(*list, dc.json_quote(it));
	if add array_add(*list, dc.json_quote(add));
	return tprint("[%]", join(..list, ",",, temp));
}

channel_or_create :: (id: dc.Snowflake) -> string { return ifx id then tprint("\"%\"", id) else "null"; }

community_page :: (g: *dc.Guild) {
	if !dc.guild_has_feature(g, "COMMUNITY") {
		page_subtitle("Are you building a Community? Convert to a Community Server to access additional administrative tools that can help you moderate, run, and grow your server.");
		section_heading("csafety", "Safety checks", "To protect your members, Community servers need these, and enabling sets them:");
		set_para("c1", "• Members must have a verified email on their Discord account.", .Normal, 14, 18, T("--text-default"));
		set_para("c2", "• Media from all members is scanned by the explicit image filter.", .Normal, 14, 18, T("--text-default"));
		set_divider();
		community_channels(g, true);
		set_divider();
		section_heading("cfinish", "Finishing touches", "Default notifications become Only @mentions.");
		if set_toggle_row("agree", "I agree and understand", "Community servers follow Discord's Community Guidelines.", ss.comm.agree) ss.comm.agree = !ss.comm.agree;
		spacer(.Y, 16);
		if set_button("Enable Community##enable", .Primary, ss.comm.agree && !ss.busy) {
			body := tprint("{\"features\":%,\"verification_level\":%,\"default_message_notifications\":1,\"explicit_content_filter\":2,\"rules_channel_id\":%,\"public_updates_channel_id\":%}",
				features_json(g, add = "COMMUNITY"), max(1, g.verification_level), channel_or_create(ss.comm.rules), channel_or_create(ss.comm.updates));
			ss_action(g, .COUNT, "PATCH", tprint("/guilds/%", g.id), body);
		}
		return;
	}
	page_subtitle("Community servers have more tools to help you moderate and grow your server.");
	community_channels(g, false);
	spacer(.Y, 24);
	field_title("Server Primary Language");
	names: [..]string;
	names.allocator = temp;
	for LOCALES array_add(*names, it[1]);
	pick := select_field("locale", names, ss.comm.locale);
	if pick >= 0 ss.comm.locale = pick;
	spacer(.Y, 8);
	set_para("lhelp", "Discord will prioritize this server in search to users who speak the selected language.", .Normal, 12, 16, T("--text-muted"));
	set_divider();
	section_heading("cdisable", "Disable Community", "Turns this back into a regular server. Community-only features stop working.");
	if set_button("Disable Community##disable", .Danger, !ss.busy && !community_dirty(g)) ss_action(g, .COUNT, "PATCH", tprint("/guilds/%", g.id), tprint("{\"features\":%}", features_json(g, drop = "COMMUNITY")));
}

community_channels :: (g: *dc.Guild, enabling: bool) {
	names, ids := channel_options(g, ifx enabling then "Create one for me" else "None", false);
	if enabling ids[0] = 1;
	field_title("Rules or Guidelines Channel");
	pick := select_field("crules", names, index_of(ids, ss.comm.rules));
	if pick >= 0 ss.comm.rules = ids[pick];
	spacer(.Y, 8);
	set_para("rhelp", "This is where you'll show members your server rules or guidelines.", .Normal, 12, 16, T("--text-muted"));
	spacer(.Y, 16);
	field_title("Community Updates Channel");
	pick = select_field("cupdates", names, index_of(ids, ss.comm.updates));
	if pick >= 0 ss.comm.updates = ids[pick];
	spacer(.Y, 8);
	set_para("uhelp", "This is where Discord sends updates for moderators and admins of Community servers.", .Normal, 12, 16, T("--text-muted"));
	if enabling return;
	spacer(.Y, 16);
	field_title("Safety Notifications Channel");
	pick = select_field("csafety", names, index_of(ids, ss.comm.safety));
	if pick >= 0 ss.comm.safety = ids[pick];
	spacer(.Y, 8);
	set_para("shelp", "Anyone with access to this text channel will be able to see the notifications.", .Normal, 12, 16, T("--text-muted"));
}

// Community Overview's save: saveGuild's keys in its order.
community_save :: (g: *dc.Guild) {
	f := ss.comm;
	save_call(g, .Save, "PATCH", tprint("/guilds/%", g.id), tprint("{\"preferred_locale\":\"%\",\"rules_channel_id\":%,\"public_updates_channel_id\":%,\"safety_alerts_channel_id\":%}",
		LOCALES[f.locale][0], channel_or_create(f.rules), channel_or_create(f.updates), channel_or_create(f.safety)));
}

// ---- Access ----

access_rules :: () -> []string {
	out: [..]string;
	out.allocator = temp;
	for split(ui.editor_text(*ss.words), "\n",, temp) {
		t := trim(it);
		if t && out.count < 16 array_add(*out, t);
	}
	return out;
}

// The server rules members agree to, from GET /guilds/{id}/member-verification (its TERMS field).
saved_rules :: () -> string, bool {
	r := reply(.Verification);
	if !r return "", false;
	m := dc.vmap(r.body);
	sb: String_Builder;
	sb.allocator = temp;
	for dc.flist(m, "form_fields") {
		f := dc.vmap(it);
		if dc.fstr(f, "field_type") != "TERMS" continue;
		for dc.flist(f, "values") print_to_builder(*sb, "%\n", dc.vstr(it));
	}
	return trim(builder_to_string(*sb,, temp)), dc.fbool(m, "enabled") || dc.flist(m, "form_fields").count > 0;
}

access_dirty :: () -> bool {
	saved, on := saved_rules();
	if !reply(.Verification) return false;
	return trim(join(..access_rules(), "\n",, temp)) != saved || ss.require_rules != on;
}

access_page :: (g: *dc.Guild) {
	page_subtitle("Keep your server private, or open it up for more people to join.");
	section_heading("join", "How can people join your server?", "");
	radio_choice("invite", "Invite Only", "People can join your server directly with an invite", true);
	radio_choice("apply", "Apply to Join", "People must submit an application and be approved to join", false, false);
	radio_choice("disc", "Discoverable", ifx dc.guild_has_feature(g, "COMMUNITY") then "Anyone can join your server directly through Server Discovery" else "Enable Community to access Server Discovery", false, false);
	set_divider();
	if !loading_or(.Verification, "Couldn't load the server rules.") return;
	if set_toggle_row("require", "Require members to agree to the server rules", "New members must read and agree to these before they can talk.", ss.require_rules) ss.require_rules = !ss.require_rules;
	spacer(.Y, 16);
	field_title("Server Rules");
	if set_input("rules", *ss.words, "One rule per line, for example: Be respectful", multiline = true, max_runes = 4000, min_h = 120) == .Escape ss.field_escape = true;
}

access_save :: (g: *dc.Guild) {
	rules := access_rules();
	if ss.require_rules && !rules.count { ss_error("You need to add one or more rules."); return; }
	fields := "[]";
	if rules.count {
		vals: [..]string;
		vals.allocator = temp;
		for rules array_add(*vals, dc.json_quote(it));
		fields = tprint("[{\"field_type\":\"TERMS\",\"label\":\"Read and agree to the server rules\",\"values\":[%],\"required\":true}]", join(..vals, ",",, temp));
	}
	save_call(g, .Save, "PATCH", tprint("/guilds/%/member-verification", g.id), tprint("{\"form_fields\":%,\"enabled\":%}", fields, ss.require_rules));
}

// ---- Server Tag (GUILD_TAGS) and Custom Invite Link (VANITY_URL) ----

tag_dirty :: () -> bool {
	r := reply(.Profile);
	return r && trim(ui.editor_text(*ss.tag)) != dc.fstr(dc.vmap(r.body), "tag");
}

tag_page :: (g: *dc.Guild) {
	page_subtitle("Members can wear your server's tag next to their name across Discord.");
	if !loading_or(.Profile, "Couldn't load the server's tag.") return;
	field_title("Tag");
	if set_input("tag", *ss.tag, "2 to 4 letters or numbers", max_runes = 4) == .Escape ss.field_escape = true;
	spacer(.Y, 8);
	set_para("taghelp", "The badge chosen in the official client stays as it is.", .Normal, 12, 16, T("--text-muted"));
}

vanity_block :: (g: *dc.Guild) {
	if !dc.guild_has_feature(g, "VANITY_URL") return;
	set_divider();
	section_heading("vanity", "Custom Invite Link", "Choose a link people can use to join, discord.gg/<code>.");
	r := reply(.Vanity);
	if r {
		uses := dc.fint(dc.vmap(r.body), "uses");
		if uses { set_para("vuses", tprint("Used % times.", uses), .Normal, 12, 16, T("--text-muted")); spacer(.Y, 8); }
	}
	vr := row("vrow");
	vr.semantic_size = .[ui.pct(1), ui.children()];
	vr.style.child_gap = 8;
	ui.parent(vr); defer ui.pop_parent();
	label("discord.gg/", .Medium, 16, T("--text-default"), 20);
	c := ui.box("in");
	c.semantic_size = .[ui.fill(), ui.children()];
	c.layout_axis = .Y;
	{ ui.parent(c); defer ui.pop_parent(); if set_input("vcode", *ss.tag, "", max_runes = 25) == .Escape ss.field_escape = true; }
	code := trim(ui.editor_text(*ss.tag));
	saved := ifx r then dc.fstr(dc.vmap(r.body), "code") else g.vanity_url_code;
	if set_button("Save##vsave", .Primary, code != saved && !ss.busy) ss_action(g, .Vanity, "PATCH", tprint("/guilds/%/vanity-url", g.id), tprint("{\"code\":%}", ifx code then dc.json_quote(code) else "null"));
}

// ---- Stickers ----

stickers_page :: (g: *dc.Guild) {
	page_subtitle("Stickers can be used by anyone in this server. Upload a PNG, APNG, GIF or Lottie JSON file of up to 512 KB; it shows at 320x320.");
	section_heading("upload", "Upload Sticker", "");
	field_title("Name");
	if set_input("sname", *ss.hook_name, "Name your sticker", max_runes = 30) == .Escape ss.field_escape = true;
	spacer(.Y, 12);
	field_title("Related Emoji");
	if set_input("stags", *ss.tag, "An emoji name, like smile", max_runes = 200) == .Escape ss.field_escape = true;
	spacer(.Y, 12);
	field_title("Description");
	if set_input("sdesc", *ss.words, "Describe your sticker", max_runes = 100) == .Escape ss.field_escape = true;
	spacer(.Y, 12);
	fr := row("file");
	fr.semantic_size = .[ui.pct(1), ui.px(38)];
	fr.style.child_gap = 12;
	{ ui.parent(fr); defer ui.pop_parent();
		if set_button("Browse##browse", .Secondary, !ss.busy) {
			paths := pick_files();
			if paths.count ss_set(*ss.sticker_file, paths[0]);
		}
		f := ss.sticker_file;
		slash := find_index_of_any_from_right(f, "/\\");
		label(ifx f then advance(f, slash + 1) else "No file chosen", .Normal, 14, T("--text-muted"), 18);
	}
	spacer(.Y, 12);
	one_line :: (s: string) -> string { return trim(replace(s, "\n", " ",, temp)); }
	name, tags := one_line(ui.editor_text(*ss.hook_name)), one_line(ui.editor_text(*ss.tag));
	if set_button(ifx ss.busy then "Uploading...##up" else "Upload##up", .Primary, name.count >= 2 && tags.count > 0 && ss.sticker_file != "" && !ss.busy) && net_action() {
		ss.busy = true;
		ss_error("");
		dc.upload_sticker(app.client, g.id, ss.sticker_file, name, tags, one_line(ui.editor_text(*ss.words)));
	}
	set_divider();
	label(tprint("% STICKERS — % SLOTS AVAILABLE", g.stickers.count, max(0, 5 - g.stickers.count)), .Bold, 12, T("--text-muted"), 16);
	spacer(.Y, 12);
	if !g.stickers.count { ss_empty("No stickers yet"); return; }
	table_units(.[1, 3, 4]);
	for s: g.stickers {
		ui.id_scope(cast(u64) s.id);
		defer ui.pop_seed();
		table_row_begin("s");
		defer ui.pop_parent();
		{ c := table_cell(0, 1); ui.parent(c); defer ui.pop_parent(); sticker_box("img", .{id = s.id, name = s.name, format_type = s.format_type, guild = g.id}, 44, false); }
		{
			c := table_cell(1, 3); ui.parent(c); defer ui.pop_parent();
			if ss.rename_emoji == s.id {
				col := ui.box("ed");
				col.semantic_size = .[ui.fill(), ui.children()];
				col.layout_axis = .Y;
				ui.parent(col); defer ui.pop_parent();
				res := set_input("name", *ss.rename, s.name, max_runes = 30, autofocus = true);
				if res == .Escape ss.rename_emoji = 0;
				if res == .Submit {
					name := trim(ui.editor_text(*ss.rename));
					if name != s.name && name.count >= 2 ss_action(g, .COUNT, "PATCH", tprint("/guilds/%/stickers/%", g.id, s.id), tprint("{\"name\":%}", dc.json_quote(name)));
					ss.rename_emoji = 0;
				}
			} else {
				nb := row("name", .Clickable);
				nb.semantic_size = .[ui.fill(), ui.px(52)];
				nb.hover_cursor = .IBeam;
				if ui.signal(nb).clicked {
					ss.rename_emoji = s.id;
					ui.editor_set_text(*ss.rename, s.name);
					app.ui.focus = 0;
				}
				ui.parent(nb); defer ui.pop_parent();
				label(s.name, .Medium, 14, T("--text-strong"), 18);
			}
		}
		{ c := table_cell(2, 4); ui.parent(c); defer ui.pop_parent(); label(s.description, .Normal, 14, T("--text-muted"), 18); }
		if row_icon_button("del", "x-small", danger = true) ss_confirm_open(.Delete_Sticker, s.id, s.name);
	}
}

#scope_export

// ownership_prompt: on a hosted server, the member the owner offered the server to accepts or declines
// (PUT / DELETE /guilds/{id}/owner-transfer). Shown over everything until answered.
ownership_prompt :: () {
	if !on_hosted() return;
	g := dc.guild_get(store(), app.view.guild);
	if !g || g.pending_owner_id != store().me || ss.declined == g.id || modal_open() return;
	owner := dc.user_get(store(), g.owner_id);
	if !adm_modal_begin("ownerprompt", 440, "Accept Server Ownership") {
		ss.declined = g.id;
		return;
	}
	spacer(.Y, 8);
	r := row("body");
	r.semantic_size = .[ui.pct(1), ui.children()];
	{ ui.parent(r); defer ui.pop_parent();
		spacer(.X, 25);
		set_para("t", tprint("% wants to make you the owner of %. You'll be able to manage everything about it, and they'll stay a member.", ifx owner then dc.display_name(owner) else "The owner", g.name), .Normal, 16, 20, T("--text-default"));
		spacer(.X, 25);
	}
	spacer(.Y, 24);
	btns := row("btns");
	btns.semantic_size = .[ui.pct(1), ui.px(40)];
	btns.style.child_gap = 8;
	answer := "";
	{ ui.parent(btns); defer ui.pop_parent();
		spacer(.X, 25 - 8);
		if wide_button("decline", "Decline", .Secondary) answer = "DELETE";
		if wide_button("accept", "Accept", .Primary) answer = "PUT";
		spacer(.X, 25 - 8);
	}
	spacer(.Y, 24);
	adm_modal_end();
	if adm_escape() ss.declined = g.id;
	if answer && net_action() {
		ss.declined = g.id;
		dc.guild_settings_call(app.client, g.id, xx Req.COUNT, answer, tprint("/guilds/%/owner-transfer", g.id));
	}
}

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
