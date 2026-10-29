// Server Settings and Channel Settings: the full-window layer the server menu opens, as the official client's GuildSettings
// (bundle `generateSections`): a sidebar of sections under the server's name and the Expression, People,
// Apps and Moderation headers, then Delete Server; ESC or Escape closes; an unsaved-changes bar with
// Reset / Save Changes holds the page (no closing or switching sections until it's saved or reset).
// Each section shows only to members with the permission it needs. Hosted servers add a Host group.
// Channel Settings (the channel row's cog) is the same layer for one channel (ss.channel): Overview,
// Permissions, Invites, Integrations and Delete Channel.
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
	Insights;
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
	// Channel Settings
	Chan_Overview;
	Chan_Permissions;
	Chan_Invites;
	Chan_Integrations;
	Chan_Delete;
}

can_open_server_settings :: (gid: dc.Snowflake) -> bool {
	return (dc.guild_permissions(store(), gid) & SETTINGS_PERMS) != 0;
}

server_settings_open :: (gid: dc.Snowflake, section := Server_Section.None) {
	g := dc.guild_get(store(), gid);
	if g == null return;
	server_settings_close();
	for * ss.replies dc.feature_result_free(it);
	ss.guild = gid;
	ss.channel = 0;
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

// channel_settings_open: the channel row's cog (and its menu's Edit Channel).
channel_settings_open :: (ch: *dc.Channel) {
	g := ifx ch then dc.guild_get(store(), ch.guild_id) else null;
	if g == null return;
	server_settings_close();
	for * ss.replies dc.feature_result_free(it);
	ss.guild, ss.channel, ss.open, ss.section = g.id, ch.id, true, Server_Section.Chan_Overview;
	if app.client != null dc.open_channel_settings(app.client, ch, xx Req.Regions);
	section_enter(g);
}

// channel_settings_saved: the Overview's PATCH answered (guild_admin.jai sends it, for the replay tests).
channel_settings_saved :: (r: *dc.Feature_Result) {
	if !ss.open || ss.channel != r.channel_id return;
	ss.busy = false;
	if !r.ok ss_error(settings_result_error(r));
}

server_settings_is_open :: () -> bool { return ss.open; }

server_settings_close :: () {
	ss.open = false;
	ss.busy, ss.icon_busy = false, false;
	ss.dd = "";
	for * ss.loading it.* = false;
	ss_error("");
	app.ui.focus = 0;
}

server_settings_reset_for_test :: () {
	server_settings_close();
	for * ss.replies dc.feature_result_free(it);
	ui.editor_destroy(*ss.name);
	ui.editor_destroy(*ss.desc);
	for * ss.traits ui.editor_destroy(it);
	free(ss.error);
	free(ss.chan_region);
	tags_free();
	array_free(ss.ows);
	array_free(ss.cursors);
	array_free(ss.cursor_joined);
	array_free(ss.rule.exempt_roles);
	array_free(ss.rule.exempt_channels);
	ui.editor_destroy(*ss.rule_allow);
	ui.editor_destroy(*ss.rule_limit);
	free(ss.rule_saved);
	free(ss.rule_regex);
	ob_free();
	free(ss.ob_saved);
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
		if ss.section == .Onboarding && r.body.kind == .Map keep_reply(.Onboarding, r);
		if req == .Save_Widget && r.body.kind == .Map keep_reply(.Widget, r);
		ss.saves_left -= 1;
		if ss.saves_left > 0 return;
		ss.busy = false;
		// Drafts of store values stay as saved: the gateway's update makes the store match them.
		if ss.section == .Profile || ss.section == .Tag || ss.section == .Access || ss.section == .Onboarding form_reset(g);
		return;
	}
	if req >= .COUNT return;
	keep_reply(req, r);
	if req == .Profile || req == .Widget || req == .Verification || req == .Vanity || req == .Onboarding form_reset(g); // the forms these replies fill
}

server_settings_layer :: () {
	if !ss.open {
		// freed here, not on close: a close mid-frame leaves boxes pointing into the replies until layout
		for * ss.replies dc.feature_result_free(it);
		return;
	}
	g := dc.guild_get(store(), ss.guild);
	ch := dc.channel_get(store(), ss.channel);
	allowed := ifx ss.channel then can_manage_channel(ch) else g != null && can_open_server_settings(g.id);
	if g == null || !allowed || !section_shown(g, ss.section) {
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
					first := ifx ch then Server_Section.Chan_Overview else .Profile;
					last := ifx ch then Server_Section.Chan_Delete else .Delete;
					for i: cast(int) first..cast(int) last {
						sec := cast(Server_Section) i;
						if !section_shown(g, sec) continue;
						grp := section_group(sec);
						if grp != group {
							if group >= 0 nav_divider(sec);
							head := GROUP_NAMES[grp];
							if grp == 0 head = ifx g.name then g.name else "Server Settings";
							if grp == 8 {
								cat := dc.channel_get(store(), ch.parent_id);
								head = ifx cat then tprint("% %", chan_title(ch), to_upper_copy(cat.name,, temp)) else chan_title(ch);
							}
							if head nav_header(sec, head);
							group = grp;
						}
						if nav_item(sec, g) && !dirty {
							if sec == .Delete ss_confirm_open(.Delete_Server, 0, "");
							else if sec == .Chan_Delete channel_delete_open(ch); // view_guild_admin.jai's confirm
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
	covered := ss.confirm != .None || ss.menu_user != 0 || modr.user != 0 || guild_admin_modal_open() || mfa_is_open();
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
		if app.client != null && ch dc.channel_settings_pane(app.client, section_pane(from), section_pane(go), ch);
		else if app.client != null dc.guild_settings_pane(app.client, section_pane(from), section_pane(go), g.id);
		section_enter(g);
	}
	if save && dirty && !ss.busy && net_action() form_save(g);
}

#scope_file

SETTINGS_PERMS :: dc.PERM_MANAGE_GUILD | dc.PERM_MANAGE_ROLES | dc.PERM_ADMINISTRATOR | dc.PERM_BAN_MEMBERS | dc.PERM_MANAGE_NICKNAMES
	| dc.PERM_CREATE_GUILD_EXPRESSIONS | dc.PERM_MANAGE_GUILD_EXPRESSIONS | dc.PERM_MANAGE_WEBHOOKS | dc.PERM_VIEW_AUDIT_LOG | dc.PERM_VIEW_GUILD_ANALYTICS;

GROUP_NAMES :: string.["", "Expression", "People", "Apps", "Moderation", "", "Host", "", "", ""]; // 8: the channel

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
	Onboarding; // GET /guilds/{id}/onboarding
	Regions; // GET /guilds/{id}/regions (Channel Settings: Region Override)
	COUNT;
	Save :: 100; // a page's Save Changes
	Save_Widget;
	Action; // a list page's change (ss_action), then its list reloads
	Create_Role; // POST /guilds/{id}/roles
}

ss: struct {
	open: bool;
	guild: dc.Snowflake;
	channel: dc.Snowflake; // Channel Settings: the channel (0: Server Settings)
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
	rdrag: dc.Snowflake; // Roles: the row pressed, then dragged
	rdrag_from: ui.Vec2;
	rdrag_active: bool;
	rdrop: int; // the row it would go to this frame (-1: none), below it when rdrop_after
	rdrop_after: bool;
	declined: dc.Snowflake; // the guild whose ownership offer was answered or put off this session
	comm: Community_Form; // Community
	require_rules: bool; // Access
	tag: ui.Editor; // Server Tag; Invites: the custom invite link's code; Stickers: related emoji
	sticker_file: string; // heap: Stickers' chosen file
	ob_channels: [..]dc.Snowflake; // Onboarding: the default channels as edited
	ob_prompts: [..]Ob_Prompt; // and the questions
	ob_open: int; // the question open for editing, from 1 (0: none)
	ob_saved: string; // heap: the loaded questions' prompts_json, what the drafts compare with
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
	// Channel Settings: Overview (ss.name, ss.desc hold the name and topic) and Permissions
	chan: dc.Channel_Form; // the Overview as edited, but for the name and topic
	chan_region: string; // heap: chan.rtc_region's
	chan_tags: [..]dc.Forum_Tag; // a forum's tags as edited (strings on the heap); ss.tag: a new one's name
	ows: [..]dc.Overwrite; // the overwrites as edited
	ow_id: dc.Snowflake; // the role or member whose permissions are shown
	ow_adding: bool; // the Add members or roles search is open
	cursors: [..]dc.Snowflake; // Bans, Audit Log, Members: the cursor each page shown so far loaded from (empty: page 1)
	cursor_joined: [..]s64; // Members: beside each cursor, its member's join time (ms)
	// Safety Setup: the AutoMod rule open for editing (ss.words holds its words) and its draft
	rule_id: dc.Snowflake;
	rule: Rule_Draft;
	rule_allow: ui.Editor;
	rule_limit: ui.Editor;
	rule_saved: string; // heap: rule_body of the rule as loaded, what the draft compares with
	rule_regex: string; // heap: its regex patterns' JSON, kept as they are
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
		if !on_hosted() load(g, .Widget, tprint("/guilds/%/widget", g.id)); // a hosted server has no widget
	case .Members;
		members_search(g);
	case .Invites;
		load(g, .Invites, tprint("/guilds/%/invites", g.id));
		if dc.guild_has_feature(g, "VANITY_URL") load(g, .Vanity, tprint("/guilds/%/vanity-url", g.id));
	case .Bans;
		bans_load(g);
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
	case .Onboarding;
		ss.loading[Req.Onboarding] = false;
		load(g, .Onboarding, tprint("/guilds/%/onboarding", g.id));
	case .Safety;
		ss.loading[Req.Automod] = false;
		load(g, .Automod, tprint("/guilds/%/auto-moderation/rules", g.id));
	case .Roles;
		ss.loading[Req.Role_Counts] = false;
		load(g, .Role_Counts, tprint("/guilds/%/roles/member-counts", g.id));
	case .Chan_Invites;
		ss.loading[Req.Invites] = false;
		load(g, .Invites, tprint("/channels/%/invites", ss.channel));
	case .Chan_Integrations;
		ss.loading[Req.Webhooks] = false;
		load(g, .Webhooks, tprint("/channels/%/webhooks", ss.channel));
	}
	ss.ow_id, ss.ow_adding = g.id, false;
	ss.role_id, ss.pending_role, ss.hook_id, ss.rule_id = 0, 0, 0, 0;
	array_reset(*ss.cursors);
	array_reset(*ss.cursor_joined);
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
	if s == .Chan_Delete return 9;
	if s >= .Chan_Overview return 8;
	if s <= .Engagement return 0;
	if s <= .Soundboard return 1;
	if s <= .Access return 2;
	if s <= .Integrations return 3;
	if s <= .Bans return 4;
	if s <= .Insights return 5;
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
	case .Insights; return "Server Insights";
	case .Host_Storage; return "Storage";
	case .Host_Attachments; return "Attachments";
	case .Host_Limits; return "Limits";
	case .Host_Backups; return "Backups";
	case .Host_Network; return "Network";
	case .Host_Sessions; return "Sessions";
	case .Host_Info; return "Server Info";
	case .Templates; return "Server Template";
	case .Delete; return "Delete Server";
	case .Chan_Overview; return "Overview";
	case .Chan_Permissions; return "Permissions";
	case .Chan_Invites; return "Invites";
	case .Chan_Integrations; return "Integrations";
	case .Chan_Delete;
		ch := dc.channel_get(store(), ss.channel);
		return ifx ch && ch.kind == .Guild_Category then "Delete Category" else "Delete Channel";
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
	case .Insights; return "ANALYTICS";
	case .Chan_Overview; return "OVERVIEW";
	case .Chan_Permissions; return "PERMISSIONS";
	case .Chan_Invites; return "INSTANT_INVITES";
	case .Chan_Integrations; return "INTEGRATIONS";
	}
	return ""; // Host sections: hosted servers send no science
}

// Whether the member may see a section (the client's predicates) and fastcord has its page.
section_shown :: (g: *dc.Guild, s: Server_Section) -> bool {
	if !page_exists(s) return false;
	p := dc.guild_permissions(store(), g.id);
	has :: (p: u64, f: u64) -> bool #expand { return (p & f) != 0; }
	owner := g.owner_id == store().me;
	if s >= .Chan_Overview {
		ch := dc.channel_get(store(), ss.channel);
		if !ch return false;
		cp := dc.channel_permissions(store(), ch.id);
		cat := ch.kind == .Guild_Category;
		if s == {
		case .Chan_Permissions; return has(cp, dc.PERM_MANAGE_ROLES);
		case .Chan_Invites; return !cat;
		case .Chan_Integrations;
			// a hosted server's webhooks post only to text and announcement channels
			return has(cp, dc.PERM_MANAGE_WEBHOOKS) && (ch.kind == .Guild_Text || ch.kind == .Guild_Announcement || (!on_hosted() && (ch.kind == .Guild_Forum || ch.kind == .Guild_Voice)));
		}
		return true;
	}
	if s == {
	case .Profile; #through;
	case .Engagement;
		return has(p, dc.PERM_MANAGE_GUILD);
	case .Tag;
		return has(p, dc.PERM_MANAGE_GUILD) && dc.guild_has_feature(g, "GUILD_TAGS") && !on_hosted();
	case .Stickers; #through; case .Emoji; #through; case .Soundboard;
		return has(p, dc.PERM_MANAGE_GUILD_EXPRESSIONS | dc.PERM_CREATE_GUILD_EXPRESSIONS);
	case .Members;
		return has(p, dc.PERM_MANAGE_GUILD | dc.PERM_MANAGE_ROLES | dc.PERM_KICK_MEMBERS | dc.PERM_BAN_MEMBERS | dc.PERM_MODERATE_MEMBERS | dc.PERM_MANAGE_NICKNAMES);
	case .Roles;
		return has(p, dc.PERM_MANAGE_ROLES);
	case .Safety;
		return has(p, dc.PERM_MANAGE_GUILD) && !on_hosted(); // a hosted server has no verification levels, filters or AutoMod
	case .Onboarding;
		return has(p, dc.PERM_MANAGE_GUILD) && dc.guild_has_feature(g, "COMMUNITY") && !on_hosted();
	case .Insights;
		return has(p, dc.PERM_VIEW_GUILD_ANALYTICS) && dc.guild_has_feature(g, "COMMUNITY") && !on_hosted();
	case .Templates; #through; case .Access; #through; case .Community;
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
	case .Community; #through; case .Access; #through; case .Tag; #through; case .Stickers; #through; case .Onboarding; #through; case .Insights; #through;
	case .Chan_Overview; #through; case .Chan_Permissions; #through; case .Chan_Invites; #through; case .Chan_Integrations; #through; case .Chan_Delete;
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
	case .Onboarding;
		onboarding_page(g);
	case .Insights;
		// the client's page is a link out too: Insights lives on the developer site, opened in the browser
		page_subtitle("Server Insights is hosted on a separate website so that it's easier to share links and browse cross platform.");
		if set_button("Open Server Insights##insights", .Primary) open_url(tprint("https://discord.com/developers/servers/%", g.id));
	case .Soundboard;
		sound_settings_page(g, w); // view_server_soundboard.jai
	case .Chan_Overview;
		return chan_overview_page(g);
	case .Chan_Permissions;
		chan_permissions_page(g);
	case .Chan_Invites;
		invites_page(g);
	case .Chan_Integrations;
		integrations_page(g);
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
	case .Onboarding;
		return onboarding_dirty();
	case .Safety;
		return rule_dirty();
	case .Chan_Overview;
		return chan_overview_dirty();
	case .Chan_Permissions;
		return ows_dirty();
	case .Chan_Integrations;
		return hook_dirty();
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
	if ss.section == .Safety && ss.rule_id rule_open(rule_of_id(ss.rule_id));
	if ss.channel chan_reset();
	if ss.section == .Onboarding onboarding_reset();
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
	case .Onboarding;
		onboarding_save(g);
	case .Access;
		access_save(g);
	case .Tag;
		ss_error("");
		save_call(g, .Save, "PATCH", tprint("/guilds/%/profile", g.id), tprint("{\"tag\":%}", dc.json_quote(trim(ui.editor_text(*ss.tag)))));
	case .Safety;
		rule_save(g);
	case .Chan_Overview;
		chan_overview_save();
	case .Chan_Permissions;
		ows_save(g);
	case .Integrations; #through;
	case .Chan_Integrations;
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
	danger := s == .Delete || s == .Chan_Delete;
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

#scope_export
// A select field showing current; returns the option picked this frame (-1 for none). The option list
// is drawn by dropdown_list at the end of the layer (here and in User Settings).
select_field ::(id: string, options: []string, current: int) -> int {
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

select_close :: () {ss.dd = "";}
select_is_open :: () -> bool { return ss.dd != ""; }

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
#scope_file

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

// A table row; returns it (pushed as parent: close with ui.pop_parent). release: it acts on release, so a
// press can start a drag.
table_row_begin :: (id: string, release := false) -> *ui.Box, ui.Signal {
	r := row(id, .Clickable | .Draw_Background | .Hot_Animation);
	if release r.flags |= .Click_On_Release;
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
	// a later page: after the last member of the one before, by join time (the client's cursor)
	after := "";
	if ss.section == .Members && ss.cursors.count && ss.cursor_joined.count == ss.cursors.count
		after = tprint(",\"after\":{\"guild_joined_at\":%,\"user_id\":\"%\"}", peek(ss.cursor_joined), peek(ss.cursors));
	ss.loading[Req.Members] = false;
	if !net_action() return;
	ss.loading[Req.Members] = true;
	dc.guild_settings_call(app.client, g.id, xx Req.Members, "POST", tprint("/guilds/%/members-search", g.id), join(tprint("{\"or_query\":%,\"and_query\":{},\"limit\":%", or, MEMBERS_PAGE), after, "}",, temp));
}

members_page :: (g: *dc.Guild) {
	res := set_input("search", *ss.search, "Search by username or id");
	if res == .Changed {
		ss.search_at = wall_ms();
		array_reset(*ss.cursors);
		array_reset(*ss.cursor_joined);
	}
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
	last := ifx list.count == MEMBERS_PAGE then dc.fmap(dc.vmap(list[list.count - 1]), "member") else .[];
	defer pager(g, dc.fsnow(dc.fmap(last, "user"), "id"), members_search, dc.iso_to_ms(dc.fstr(last, "joined_at")));
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
		if ss.channel {} // Channel Settings lists the channel's invites; pausing is the server's
		else if paused {
			if set_button("Enable Invites##resume", .Primary, !ss.busy) ss_action(g, .COUNT, "PUT", tprint("/guilds/%/incident-actions", g.id), "{\"invites_disabled_until\":null,\"dms_disabled_until\":null,\"lockdown_duration_hours\":null}");
		} else if set_button("Pause Invites##pause", .Danger, !ss.busy) ss_confirm_open(.Pause_Invites, 0, "");
	}
	if paused && !ss.channel {
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
	if !ss.channel vanity_block(g);
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
	defer pager(g, ifx list.count == BANS_PAGE then dc.fsnow(dc.fmap(dc.vmap(list[list.count - 1]), "user"), "id") else 0, bans_load);
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

BANS_PAGE :: 1000;
MEMBERS_PAGE :: 250;
AUDIT_PAGE :: 50;

// GET /guilds/{id}/bans?limit=1000, after the last ban of the page before.
bans_load :: (g: *dc.Guild) {
	ss.loading[Req.Bans] = false;
	after := ifx ss.cursors.count then tprint("&after=%", peek(ss.cursors)) else "";
	load(g, .Bans, join(tprint("/guilds/%/bans?limit=%", g.id, BANS_PAGE), after,, temp));
}

// Previous / Next under a paged list; next is the cursor of the page after this one (0: it's the last), and
// for Members its member's join time.
pager :: (g: *dc.Guild, next: dc.Snowflake, reload: (*dc.Guild), next_joined: s64 = 0) {
	if !ss.cursors.count && !next return;
	spacer(.Y, 12);
	r := row("pager");
	r.semantic_size = .[ui.pct(1), ui.px(38)];
	r.style.child_gap = 8;
	ui.parent(r); defer ui.pop_parent();
	label(tprint("Page %", ss.cursors.count + 1), .Medium, 14, T("--text-muted"), 18);
	filler(.X);
	if set_button("Previous##prev", .Secondary, ss.cursors.count > 0) {
		pop(*ss.cursors);
		if ss.cursor_joined.count pop(*ss.cursor_joined);
		reload(g);
	}
	if set_button("Next##next", .Secondary, next != 0) {
		array_add(*ss.cursors, next);
		if next_joined array_add(*ss.cursor_joined, next_joined);
		reload(g);
	}
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
	if ss.cursors.count q = tprint("%&before=%", q, peek(ss.cursors)); // the page after: older entries
	ss.loading[Req.Audit] = false;
	load(g, .Audit, join(tprint("/guilds/%/audit-logs?limit=%", g.id, AUDIT_PAGE), q,, temp));
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
			if pick >= 0 { ss.audit_user = uids[pick]; array_reset(*ss.cursors); audit_load(g); }
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
			if pick >= 0 { ss.audit_action = pick; array_reset(*ss.cursors); audit_load(g); }
		}
	}
	spacer(.Y, 20);
	if !loading_or(.Audit, "Couldn't load the audit log.") return;
	list := dc.flist(dc.vmap(r.body), "audit_log_entries");
	if !list.count ss_empty("No logs yet");
	defer pager(g, ifx list.count == AUDIT_PAGE then dc.fsnow(dc.vmap(list[list.count - 1]), "id") else 0, audit_load);
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
	if ss.dd == "" && !mfa_is_open() && adm_escape() ss.confirm = .None;
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

#scope_export
ROLE_COLORS :: u32.[0x1abc9c, 0x2ecc71, 0x3498db, 0x9b59b6, 0xe91e63, 0xf1c40f, 0xe67e22, 0xe74c3c, 0x95a5a6, 0x607d8b,
	0x11806a, 0x1f8b4c, 0x206694, 0x71368a, 0xad1457, 0xc27c0e, 0xa84300, 0x992d22, 0x979c9f, 0x546e7a];
#scope_file

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
		set_para("rnote", "Members use the colour of the highest role they have on this list. Drag roles, or use the arrows, to reorder them.", .Normal, 14, 18, T("--text-muted"));
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
	ss.rdrop = -1;
	for id, i: order {
		role := role_of(g, id);
		if !role continue;
		ui.id_scope(cast(u64) id);
		defer ui.pop_seed();
		rb, sig := table_row_begin("r", release = true);
		defer ui.pop_parent();
		if sig.pressed && (role.position < top || g.owner_id == store().me) ss.rdrag, ss.rdrag_from, ss.rdrag_active = id, app.ui.mouse, false;
		if ss.rdrag_active && id != ss.rdrag && (role.position < top || g.owner_id == store().me) && app.ui.mouse.y >= rb.rect.y0 && app.ui.mouse.y < rb.rect.y1 {
			ss.rdrop, ss.rdrop_after = i, app.ui.mouse.y >= (rb.rect.y0 + rb.rect.y1) / 2;
			line := ui.box("dropline", .Draw_Background | .Floating_X | .Floating_Y);
			line.semantic_size = .[ui.px(rb.rect.x1 - rb.rect.x0), ui.px(2)];
			line.fixed_pos = .{0, ifx ss.rdrop_after then rb.rect.y1 - rb.rect.y0 - 1 else -1};
			line.style.bg = T("--background-brand");
		}
		if ss.rdrag_active && id == ss.rdrag rb.opacity = 0.5;
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
		if sig.clicked && !role_dirty(g) && !ss.rdrag_active role_open(g, id);
	}
	role_drag(g, order);
}

// After the rows: the threshold, and on release the dragged role moves to the marked place (a draft:
// Save Changes sends the order, as the arrows' does).
role_drag :: (g: *dc.Guild, order: []dc.Snowflake) {
	if !ss.rdrag return;
	released := false;
	for app.ui.events if it.kind == .Mouse_Up && it.button == .Left released = true;
	d := app.ui.mouse - ss.rdrag_from;
	if !ss.rdrag_active && d.x * d.x + d.y * d.y > DRAG_THRESHOLD * DRAG_THRESHOLD ss.rdrag_active = true;
	if ss.rdrag_active app.ui.animating = true;
	if !released return;
	if ss.rdrag_active && ss.rdrop >= 0 {
		if !ss.role_order.count for order array_add(*ss.role_order, it);
		from := -1;
		for ss.role_order if it == ss.rdrag from = it_index;
		if from >= 0 {
			to := ss.rdrop + cast(int) ss.rdrop_after;
			if from < to to -= 1;
			array_ordered_remove_by_index(*ss.role_order, from);
			array_insert_at(*ss.role_order, ss.rdrag, to);
		}
	}
	ss.rdrag, ss.rdrag_active = 0, false;
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
			if editable && row_icon_button("add", "plus-small") {
				// serve gives one member a role at a time; Discord takes the client's bulk add
				if on_hosted() ss_action(g, .Role_Members, "PUT", tprint("/guilds/%/members/%/roles/%", g.id, uid, r.id));
				else ss_action(g, .Role_Members, "PATCH", tprint("/guilds/%/roles/%/members", g.id, r.id), tprint("{\"member_ids\":[\"%\"]}", uid));
			}
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
		id := dc.fsnow(r, "id");
		ui.id_scope(cast(u64) id);
		defer ui.pop_seed();
		card := ui.box("rule", .Draw_Background);
		card.semantic_size = .[ui.pct(1), ui.children()];
		card.layout_axis = .Y;
		card.style.radius = all4(8);
		card.style.bg = T("--background-mod-subtle");
		{ ui.parent(card); defer ui.pop_parent();
			spacer(.Y, 12);
			hr := row("h", .Clickable);
			hr.semantic_size = .[ui.pct(1), ui.children()];
			hr.hover_cursor = .Pointer;
			if ui.signal(hr).clicked && !rule_dirty() {
				if ss.rule_id == id ss.rule_id = 0;
				else rule_open(r);
			}
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
			if ss.rule_id == id rule_editor(g, r);
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
	ui.pop_parent();
	spacer(.Y, 8);
	br = row("addrules2");
	br.semantic_size = .[ui.pct(1), ui.px(38)];
	br.style.child_gap = 8;
	ui.push_parent(br);
	if !has[AUTOMOD_PRESET] && set_button("Block Commonly Flagged Words##pr", .Secondary, !ss.busy)
		ss_action(g, .Automod, "POST", tprint("/guilds/%/auto-moderation/rules", g.id), automod_new_body(g, "Block Commonly Flagged Words", AUTOMOD_PRESET, "{\"presets\":[1,2,3],\"allow_list\":[]}"));
	if !has[AUTOMOD_PROFILE] && set_button("Block Words in Member Profile Names##pn", .Secondary, !ss.busy)
		ss_action(g, .Automod, "POST", tprint("/guilds/%/auto-moderation/rules", g.id), tprint("{\"name\":\"Block Words in Member Profile Names\",\"guild_id\":\"%\",\"event_type\":2,\"trigger_type\":6,\"trigger_metadata\":{\"keyword_filter\":[\"*nitro*\"],\"regex_patterns\":[],\"allow_list\":[]},\"actions\":[{\"type\":4,\"metadata\":{}}],\"enabled\":true,\"exempt_channels\":[],\"exempt_roles\":[]}", g.id));
}

AUTOMOD_PRESET :: 4;
AUTOMOD_PROFILE :: 6;
PRESETS :: struct { id: int; name: string; }.[.{3, "Insults and Slurs"}, .{2, "Sexual Content"}, .{1, "Severe Profanity"}];

// An AutoMod rule's editable parts (ss.words: its words; ss.rule_allow: allowed words; ss.rule_limit: mentions).
Rule_Draft :: struct {
	trigger: int;
	block, alert, timeout, raid: bool;
	alert_channel: dc.Snowflake;
	timeout_secs: int;
	presets: [4]bool; // by preset id
	exempt_roles, exempt_channels: [..]dc.Snowflake;
}

rule_of_id :: (id: dc.Snowflake) -> etf.Map {
	r := reply(.Automod);
	if r for dc.vlist(r.body) if dc.fsnow(dc.vmap(it), "id") == id return dc.vmap(it);
	return .[];
}

words_of :: (list: []dc.V) -> string {
	parts := NewArray(list.count, string,, temp);
	for list parts[it_index] = dc.vstr(it);
	return join(..parts, ", ",, temp);
}

rule_open :: (r: etf.Map) {
	ss.rule_id = dc.fsnow(r, "id");
	if !ss.rule_id return;
	meta := dc.fmap(r, "trigger_metadata");
	d := *ss.rule;
	array_reset(*d.exempt_roles);
	array_reset(*d.exempt_channels);
	ex_roles, ex_channels := d.exempt_roles, d.exempt_channels;
	d.* = .{trigger = dc.fint(r, "trigger_type"), exempt_roles = ex_roles, exempt_channels = ex_channels, timeout_secs = 60};
	for dc.flist(r, "exempt_roles") if it_index < 20 array_add(*d.exempt_roles, dc.vsnow(it));
	for dc.flist(r, "exempt_channels") if it_index < 50 array_add(*d.exempt_channels, dc.vsnow(it));
	for dc.flist(r, "actions") {
		a := dc.vmap(it);
		m := dc.fmap(a, "metadata");
		if dc.fint(a, "type") == {
		case 1; d.block = true;
		case 2; d.alert, d.alert_channel = true, dc.fsnow(m, "channel_id");
		case 3; d.timeout, d.timeout_secs = true, dc.fint(m, "duration_seconds");
		}
	}
	for dc.flist(meta, "presets") { p := dc.vint(it); if p >= 1 && p <= 3 d.presets[p] = true; }
	d.raid = dc.fbool(meta, "mention_raid_protection_enabled");
	ui.editor_set_text(*ss.words, words_of(dc.flist(meta, "keyword_filter")));
	ui.editor_set_text(*ss.rule_allow, words_of(dc.flist(meta, "allow_list")));
	ui.editor_set_text(*ss.rule_limit, tprint("%", dc.fint(meta, "mention_total_limit")));
	sb: String_Builder;
	sb.allocator = temp;
	rx := dc.vget(meta, "regex_patterns");
	if rx.kind == .List etf.to_json(rx, *sb); else append(*sb, "[]");
	ss_set(*ss.rule_regex, builder_to_string(*sb,, temp));
	ss_set(*ss.rule_saved, rule_body(r));
}

rule_dirty :: () -> bool {
	if !ss.rule_id return false;
	r := rule_of_id(ss.rule_id);
	return r.count > 0 && rule_body(r) != ss.rule_saved;
}

// The rule with the draft's trigger metadata, actions and exemptions, in the client's keys (automod_rule_body).
rule_body :: (r: etf.Map) -> string {
	d := *ss.rule;
	q :: (text: string) -> string {
		words := split_words(text);
		for * words it.* = dc.json_quote(it.*);
		return join(..words, ",",, temp);
	}
	ids :: (list: []dc.Snowflake) -> string {
		parts := NewArray(list.count, string,, temp);
		for list parts[it_index] = tprint("\"%\"", it);
		return join(..parts, ",",, temp);
	}
	meta: string;
	if d.trigger == {
	case AUTOMOD_KEYWORD; #through; case AUTOMOD_PROFILE;
		meta = tprint("{\"keyword_filter\":[%],\"regex_patterns\":%,\"allow_list\":[%]}", q(ui.editor_text(*ss.words)), ss.rule_regex, q(ui.editor_text(*ss.rule_allow)));
	case AUTOMOD_PRESET;
		ps: [..]string;
		ps.allocator = temp;
		for 1..3 if d.presets[it] array_add(*ps, tprint("%", it));
		meta = tprint("{\"presets\":[%],\"allow_list\":[%]}", join(..ps, ",",, temp), q(ui.editor_text(*ss.rule_allow)));
	case AUTOMOD_MENTION_SPAM;
		n, ok := string_to_int(trim(ui.editor_text(*ss.rule_limit)));
		meta = tprint("{\"mention_total_limit\":%,\"mention_raid_protection_enabled\":%}", ifx ok then n else 0, d.raid);
	case;
		meta = "{}";
	}
	acts: [..]string;
	acts.allocator = temp;
	if d.trigger == AUTOMOD_PROFILE array_add(*acts, "{\"type\":4,\"metadata\":{}}");
	else if d.block array_add(*acts, "{\"type\":1,\"metadata\":{}}");
	if d.alert array_add(*acts, tprint("{\"type\":2,\"metadata\":{\"channel_id\":\"%\"}}", d.alert_channel));
	if d.timeout array_add(*acts, tprint("{\"type\":3,\"metadata\":{\"duration_seconds\":%}}", d.timeout_secs));
	return tprint("{\"id\":\"%\",\"name\":%,\"guild_id\":\"%\",\"event_type\":%,\"trigger_type\":%,\"trigger_metadata\":%,\"actions\":[%],\"enabled\":%,\"creator_id\":\"%\",\"position\":%,\"exempt_channels\":[%],\"exempt_roles\":[%]}",
		dc.fsnow(r, "id"), dc.json_quote(dc.fstr(r, "name")), dc.fsnow(r, "guild_id"), dc.fint(r, "event_type"), d.trigger, meta, join(..acts, ",",, temp),
		dc.fbool(r, "enabled"), dc.fsnow(r, "creator_id"), dc.fint(r, "position"), ids(d.exempt_channels), ids(d.exempt_roles));
}

// Save Changes: PATCH .../auto-moderation/rules/{id} with the whole rule, then the list reloads.
rule_save :: (g: *dc.Guild) {
	r := rule_of_id(ss.rule_id);
	if !r.count return;
	d := *ss.rule;
	if (d.trigger == AUTOMOD_KEYWORD || d.trigger == AUTOMOD_PROFILE) && !split_words(ui.editor_text(*ss.words)).count && ss.rule_regex == "[]" { ss_error("Add at least one word to block."); return; }
	if d.trigger == AUTOMOD_MENTION_SPAM {
		n, ok := string_to_int(trim(ui.editor_text(*ss.rule_limit)));
		if !ok || n < 1 || n > 50 { ss_error("The mention limit is between 1 and 50."); return; }
	}
	if d.trigger != AUTOMOD_PROFILE && !d.block && !d.alert && !d.timeout { ss_error("Pick at least one response."); return; }
	if d.alert && !d.alert_channel { ss_error("Pick a channel for the alerts."); return; }
	ss_action(g, .Automod, "PATCH", tprint("/guilds/%/auto-moderation/rules/%", g.id, ss.rule_id), rule_body(r));
}

rule_editor :: (g: *dc.Guild, r: etf.Map) {
	d := *ss.rule;
	inner := row("edit");
	inner.semantic_size = .[ui.pct(1), ui.children()];
	ui.parent(inner); defer ui.pop_parent();
	spacer(.X, 16);
	col := ui.box("f");
	col.semantic_size = .[ui.fill(), ui.children()];
	col.layout_axis = .Y;
	{ ui.parent(col); defer ui.pop_parent();
		if d.trigger == AUTOMOD_KEYWORD || d.trigger == AUTOMOD_PROFILE {
			field_title(ifx d.trigger == AUTOMOD_PROFILE then "Blocked words in names" else "Blocked words");
			if set_input("words", *ss.words, "Words to block, separated by commas (* matches anything)", multiline = true, max_runes = 6000, min_h = 60) == .Escape ss.field_escape = true;
			spacer(.Y, 12);
		}
		if d.trigger == AUTOMOD_PRESET {
			for PRESETS if set_toggle_row(tprint("pr%", it.id), it.name, "", d.presets[it.id]) d.presets[it.id] = !d.presets[it.id];
			spacer(.Y, 12);
		}
		if d.trigger == AUTOMOD_KEYWORD || d.trigger == AUTOMOD_PROFILE || d.trigger == AUTOMOD_PRESET {
			field_title("Allowed words");
			if set_input("allow", *ss.rule_allow, "Words that are never blocked, separated by commas", multiline = true, max_runes = 6000, min_h = 40) == .Escape ss.field_escape = true;
			spacer(.Y, 12);
		}
		if d.trigger == AUTOMOD_MENTION_SPAM {
			field_title("Mention limit");
			if set_input("limit", *ss.rule_limit, "20", max_runes = 2) == .Escape ss.field_escape = true;
			spacer(.Y, 8);
			if set_toggle_row("raid", "Mention raid protection", "Detects a burst of mention spam across the server and locks it down.", d.raid) d.raid = !d.raid;
			spacer(.Y, 12);
		}
		field_title("Responses");
		if d.trigger == AUTOMOD_PROFILE set_para("blocknote", "Members with a matching name can't talk or interact until they change it.", .Normal, 14, 18, T("--text-muted"));
		else if set_toggle_row("block", "Block message", "", d.block) d.block = !d.block;
		spacer(.Y, 10);
		if set_toggle_row("alert", "Send an alert", "", d.alert) d.alert = !d.alert;
		spacer(.Y, 10);
		if d.alert {
			names, cids := channel_options(g, "Pick a channel", false);
			pick := select_field("alertch", names, index_of(cids, d.alert_channel));
			if pick >= 0 d.alert_channel = cids[pick];
			spacer(.Y, 8);
		}
		if d.trigger == AUTOMOD_KEYWORD || d.trigger == AUTOMOD_MENTION_SPAM {
			if set_toggle_row("timeout", "Timeout member", "", d.timeout) d.timeout = !d.timeout;
			spacer(.Y, 10);
			if d.timeout {
				opts := NewArray(TIMEOUTS.count, string,, temp);
				cur := 0;
				for TIMEOUTS { opts[it_index] = it.name; if it.secs == d.timeout_secs cur = it_index; }
				pick := select_field("tdur", opts, cur);
				if pick >= 0 d.timeout_secs = TIMEOUTS[pick].secs;
				spacer(.Y, 8);
			}
		}
		spacer(.Y, 12);
		field_title("Exemptions");
		chips := row("ex");
		chips.semantic_size = .[ui.pct(1), ui.children()];
		chips.style.child_gap = 6;
		drop_role, drop_ch: dc.Snowflake;
		{ ui.parent(chips); defer ui.pop_parent();
			for d.exempt_roles { role := role_of(g, it); if chip(tprint("r%", it), ifx role then tprint("@%", role.name) else "deleted-role") drop_role = it; }
			for d.exempt_channels { ch := dc.channel_get(store(), it); if chip(tprint("c%", it), ifx ch then tprint("#%", ch.name) else "deleted-channel") drop_ch = it; }
		}
		if drop_role for d.exempt_roles if it == drop_role { array_ordered_remove_by_index(*d.exempt_roles, it_index); break; }
		if drop_ch for d.exempt_channels if it == drop_ch { array_ordered_remove_by_index(*d.exempt_channels, it_index); break; }
		if d.exempt_roles.count || d.exempt_channels.count spacer(.Y, 8);
		picks := row("picks");
		picks.semantic_size = .[ui.pct(1), ui.px(40)];
		picks.style.child_gap = 8;
		{ ui.parent(picks); defer ui.pop_parent();
			rnames: [..]string;
			rnames.allocator = temp;
			rids: [..]dc.Snowflake;
			rids.allocator = temp;
			array_add(*rnames, "Exempt a role");
			array_add(*rids, 0);
			for roles_sorted(g) if it.id != g.id && !array_find(d.exempt_roles, it.id) { array_add(*rnames, it.name); array_add(*rids, it.id); }
			w := ui.box("rw");
			w.semantic_size = .[ui.fill(), ui.children()];
			{ ui.parent(w); defer ui.pop_parent(); pick := select_field("exrole", rnames, 0); if pick > 0 && d.exempt_roles.count < 20 array_add(*d.exempt_roles, rids[pick]); }
			if d.trigger != AUTOMOD_PROFILE {
				names, cids := channel_options(g, "Exempt a channel", false);
				w = ui.box("cw");
				w.semantic_size = .[ui.fill(), ui.children()];
				{ ui.parent(w); defer ui.pop_parent(); pick := select_field("exch", names, 0); if pick > 0 && !array_find(d.exempt_channels, cids[pick]) && d.exempt_channels.count < 50 array_add(*d.exempt_channels, cids[pick]); }
			}
		}
		spacer(.Y, 16);
	}
	spacer(.X, 16);
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

// A hosted webhook's ready-to-run curl line: serve sends its key's pin (`fc_curl_pin`, curl's
// --pinnedpubkey) with the token, checked here as sha256// and base64 before it goes in a command.
webhook_curl :: (h: etf.Map) -> string {
	pin := dc.fstr(h, "fc_curl_pin");
	if !on_hosted() || !begins_with(pin, "sha256//") || pin.count > 60 || !dc.fstr(h, "token") return "";
	for cast([]u8) advance(pin, 8) if !((it >= #char "A" && it <= #char "Z") || (it >= #char "a" && it <= #char "z") || (it >= #char "0" && it <= #char "9") || it == #char "+" || it == #char "/" || it == #char "=") return "";
	return tprint("curl -k --pinnedpubkey '%' -H 'Content-Type: application/json' -d '{\"content\":\"hi\"}' %", pin, webhook_url(h));
}

// A webhook's avatar: its own image, or the default one.
hook_avatar :: (h: etf.Map, size: float32) {
	id, hash := dc.fsnow(h, "id"), dc.fstr(h, "avatar");
	if !hash || hash.count > 64 { avatar_box("av", id, size); return; }
	b := ui.box("av", .Draw_Background);
	b.semantic_size = .[ui.px(size), ui.px(size)];
	b.style.radius = all4(size / 2);
	b.style.bg = T("--background-mod-normal");
	url := dc.avatar_url(id, hash, 128);
	for hosted if it.client && it.client == app.client url = tprint("https://%/avatars/%/%.png?size=128", it.inv.id_hex, id, hash);
	set_remote_image(b, url, cover = true);
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
	if !ss.channel page_subtitle("Customize your server with integrations. Manage webhooks, followed channels and apps.");
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
		target := ifx ss.channel then ss.channel else ifx g.system_channel_id then g.system_channel_id else ifx ids.count > 1 then ids[1] else 0;
		if target && set_button("New Webhook##new", .Primary, !ss.busy && !hook_dirty())
			ss_action(g, .Webhooks, "POST", tprint("/channels/%/webhooks", target), tprint("{\"name\":%}", dc.json_quote(WEBHOOK_NAMES[random_get() % 2])));
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
			hook_avatar(h, 40);
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
				ar := row("avrow");
				ar.semantic_size = .[ui.pct(1), ui.px(80)];
				ar.style.child_gap = 12;
				{ ui.parent(ar); defer ui.pop_parent();
					hook_avatar(h, 80);
					// saved at once, as the client's avatar upload is
					if set_button("Change Avatar##hav", .Secondary, !ss.busy) {
						paths := pick_files();
						if paths.count && net_action() {
							ss.busy, ss.after = true, Req.Webhooks;
							ss_error("");
							dc.guild_settings_call(app.client, g.id, xx Req.Action, "PATCH", tprint("/webhooks/%", id), file = paths[0]);
						}
					}
					if dc.fstr(h, "avatar") && set_button("Remove##hrm", .Link, !ss.busy) ss_action(g, .Webhooks, "PATCH", tprint("/webhooks/%", id), "{\"avatar\":null}");
				}
				spacer(.Y, 16);
				field_title("Name");
				if set_input("hname", *ss.hook_name, "", max_runes = 80) == .Escape ss.field_escape = true;
				spacer(.Y, 16);
				field_title("Channel");
				names, ids := channel_options(g, "", false);
				pick := select_field("hchan", array_view(names, 1, names.count - 1), max(0, index_of(ids, ss.hook_channel) - 1));
				if pick >= 0 ss.hook_channel = ids[pick + 1];
				spacer(.Y, 16);
				curl := webhook_curl(h);
				if curl {
					// tools outside fastcord reach a hosted webhook pinned to the server's key (its certificate is self-signed)
					field_title("Post from a script");
					set_para("curl", curl, .Normal, 13, 17, T("--text-default"));
					spacer(.Y, 16);
				}
				br := row("btns");
				br.semantic_size = .[ui.pct(1), ui.px(38)];
				br.style.child_gap = 8;
				{ ui.parent(br); defer ui.pop_parent();
					if set_button("Copy Webhook URL##copy", .Secondary) clipboard_set(webhook_url(h));
					if curl && set_button("Copy curl Command##copycurl", .Secondary) clipboard_set(curl);
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
	if on_hosted() || ss.channel return;
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

// ---- Onboarding ----

onboarding_saved_channels :: () -> []dc.Snowflake {
	out: [..]dc.Snowflake;
	out.allocator = temp;
	r := reply(.Onboarding);
	if r for dc.flist(dc.vmap(r.body), "default_channel_ids") array_add(*out, dc.vsnow(it));
	return out;
}

onboarding_dirty :: () -> bool { return channels_dirty() || prompts_dirty(); }

channels_dirty :: () -> bool {
	if !reply(.Onboarding) return false;
	saved := onboarding_saved_channels();
	if saved.count != ss.ob_channels.count return true;
	for saved if !array_find(ss.ob_channels, it) return true;
	return false;
}

prompts_dirty :: () -> bool { return reply(.Onboarding) && prompts_json(ss.ob_prompts) != ss.ob_saved; }

onboarding_reset :: () {
	array_reset(*ss.ob_channels);
	for onboarding_saved_channels() array_add(*ss.ob_channels, it);
	ob_free();
	r := reply(.Onboarding);
	if r ss.ob_prompts = ob_drafts_of(r);
	ss_set(*ss.ob_saved, prompts_json(ss.ob_prompts));
	ss.ob_open = 0;
}

// An onboarding question and its answers as edited (the client's prompt and option shapes).
Ob_Option :: struct {
	id: string;
	title, desc: ui.Editor;
	channels, roles: [..]dc.Snowflake;
	has_emoji, emoji_animated: bool;
	emoji_id: dc.Snowflake;
	emoji_name: string;
}

Ob_Prompt :: struct {
	id: string;
	title: ui.Editor;
	single, required, in_onboarding: bool;
	type: int;
	options: [..]Ob_Option;
}

MAX_PROMPTS :: 15; // Discord's caps
MAX_PROMPT_OPTIONS :: 50;

// The loaded questions as drafts (ob_free frees them).
ob_drafts_of :: (r: *dc.Feature_Result) -> [..]Ob_Prompt {
	out: [..]Ob_Prompt;
	for dc.flist(dc.vmap(r.body), "prompts") {
		if out.count >= MAX_PROMPTS break;
		pm := dc.vmap(it);
		p := array_add(*out);
		p.id = copy_string(dc.fstr(pm, "id"));
		ui.editor_set_text(*p.title, dc.fstr(pm, "title"));
		p.single, p.required, p.in_onboarding, p.type = dc.fbool(pm, "single_select"), dc.fbool(pm, "required"), dc.fbool(pm, "in_onboarding"), dc.fint(pm, "type");
		for dc.flist(pm, "options") {
			if p.options.count >= MAX_PROMPT_OPTIONS break;
			om := dc.vmap(it);
			o := array_add(*p.options);
			o.id = copy_string(dc.fstr(om, "id"));
			ui.editor_set_text(*o.title, dc.fstr(om, "title"));
			ui.editor_set_text(*o.desc, dc.fstr(om, "description"));
			for dc.flist(om, "channel_ids") if it_index < 50 array_add(*o.channels, dc.vsnow(it));
			for dc.flist(om, "role_ids") if it_index < 50 array_add(*o.roles, dc.vsnow(it));
			e := dc.fmap(om, "emoji");
			if dc.fstr(e, "name") || dc.fsnow(e, "id") {
				o.has_emoji, o.emoji_id, o.emoji_animated = true, dc.fsnow(e, "id"), dc.fbool(e, "animated");
				o.emoji_name = copy_string(dc.fstr(e, "name"));
			}
		}
	}
	return out;
}

ob_free :: () {
	for * p: ss.ob_prompts {
		for * p.options {
			ui.editor_destroy(*it.title);
			ui.editor_destroy(*it.desc);
			array_free(it.channels);
			array_free(it.roles);
			free(it.id);
			free(it.emoji_name);
		}
		array_free(p.options);
		ui.editor_destroy(*p.title);
		free(p.id);
	}
	array_reset(*ss.ob_prompts);
}

// {"prompts":[...]} with the client's keys (its prompt serializer): id, options (id, channel_ids, role_ids,
// emoji, emoji_id, emoji_name, emoji_animated, title, description), title, single_select, required,
// in_onboarding, type.
prompts_json :: (prompts: []Ob_Prompt) -> string {
	ids :: (list: []dc.Snowflake) -> string {
		parts := NewArray(list.count, string,, temp);
		for list parts[it_index] = tprint("\"%\"", it);
		return join(..parts, ",",, temp);
	}
	sb: String_Builder;
	sb.allocator = temp;
	append(*sb, "{\"prompts\":[");
	for p, pi: prompts {
		print_to_builder(*sb, "%{\"id\":%,\"options\":[", ifx pi then "," else "", dc.json_quote(p.id));
		for o, oi: p.options {
			print_to_builder(*sb, "%{\"id\":%,\"channel_ids\":[%],\"role_ids\":[%],", ifx oi then "," else "", dc.json_quote(o.id), ids(o.channels), ids(o.roles));
			if o.has_emoji {
				eid := ifx o.emoji_id then tprint("\"%\"", o.emoji_id) else "null";
				print_to_builder(*sb, "\"emoji\":{\"id\":%,\"name\":%,\"animated\":%},\"emoji_id\":%,\"emoji_name\":%,\"emoji_animated\":%,", eid, dc.json_quote(o.emoji_name), o.emoji_animated, eid, dc.json_quote(o.emoji_name), o.emoji_animated);
			} else append(*sb, "\"emoji\":null,");
			print_to_builder(*sb, "\"title\":%,\"description\":%}", dc.json_quote(trim(ui.editor_text(*o.title))), dc.json_quote(trim(ui.editor_text(*o.desc))));
		}
		print_to_builder(*sb, "],\"title\":%,\"single_select\":%,\"required\":%,\"in_onboarding\":%,\"type\":%}", dc.json_quote(trim(ui.editor_text(*p.title))), p.single, p.required, p.in_onboarding, p.type);
	}
	append(*sb, "]}");
	return builder_to_string(*sb,, temp);
}

// A new question or answer's ID, as the client makes them (String(Date.now())), kept unique.
ob_new_id :: () -> string {
	id := wall_ms();
	for p: ss.ob_prompts {
		if p.id == tprint("%", id) id += 1;
		for p.options if it.id == tprint("%", id) id += 1;
	}
	return sprint("%", id);
}

onboarding_page :: (g: *dc.Guild) {
	page_subtitle("Give new members a quick way to find the channels and roles that matter to them.");
	if !loading_or(.Onboarding, "Couldn't load onboarding.") return;
	m := dc.vmap(reply(.Onboarding).body);
	on := dc.fbool(m, "enabled");
	if set_toggle_row("obon", "Enable Onboarding", "New members pick channels and roles from your questions when they join.", on, ss.busy)
		ss_action(g, .Onboarding, "PUT", tprint("/guilds/%/onboarding", g.id), tprint("{\"enabled\":%}", !on));
	set_divider();
	section_heading("obdefault", "Default Channels", "Everyone who joins sees these channels, whatever they answer.");
	for g.channels {
		ch := dc.channel_get(store(), it);
		if !ch || (ch.kind != .Guild_Text && ch.kind != .Guild_Announcement && ch.kind != .Guild_Forum && ch.kind != .Guild_Voice) continue;
		ui.id_scope(cast(u64) ch.id);
		defer ui.pop_seed();
		found, i := array_find(ss.ob_channels, ch.id);
		r := row("ch", .Clickable | .Draw_Background | .Hot_Animation);
		r.semantic_size = .[ui.pct(1), ui.px(40)];
		r.style.radius = all4(6);
		r.style.bg_hot = T("--background-mod-subtle");
		r.hover_cursor = .Pointer;
		if ui.signal(r).clicked {
			if found array_unordered_remove_by_index(*ss.ob_channels, i);
			else array_add(*ss.ob_channels, ch.id);
		}
		ui.parent(r); defer ui.pop_parent();
		spacer(.X, 8);
		box := ui.box("check", .Draw_Background | .Draw_Border);
		box.semantic_size = .[ui.px(20), ui.px(20)];
		box.style.radius = all4(4);
		box.style.border = 2;
		box.style.border_color = ifx found then T("--background-brand") else T("--interactive-icon-default");
		box.style.bg = ifx found then T("--background-brand") else .{};
		if found { ui.parent(box); defer ui.pop_parent(); i := icon("ok", "checkmark-small", 16, .{1, 1, 1, 1}); i.flags |= .Floating_X | .Floating_Y; i.fixed_pos = .{0, 0}; }
		spacer(.X, 10);
		label(ifx ch.kind == .Guild_Voice then ch.name else tprint("#%", ch.name), .Medium, 15, T("--text-strong"), 20);
	}
	set_divider();
	section_heading("obq", "Questions", "Ask new members what they're here for; each answer gives them channels and roles.");
	if !ss.ob_prompts.count set_para("noq", "No questions yet.", .Normal, 14, 18, T("--text-muted"));
	gone := -1;
	for * p, pi: ss.ob_prompts {
		ui.id_scope(cast(u64) pi + 1);
		defer ui.pop_seed();
		if prompt_card(g, p, pi) gone = pi;
	}
	if gone >= 0 {
		p := ss.ob_prompts[gone];
		for * p.options { ui.editor_destroy(*it.title); ui.editor_destroy(*it.desc); array_free(it.channels); array_free(it.roles); free(it.id); free(it.emoji_name); }
		array_free(p.options);
		ui.editor_destroy(*p.title);
		free(p.id);
		array_ordered_remove_by_index(*ss.ob_prompts, gone);
		ss.ob_open = 0;
	}
	spacer(.Y, 8);
	if ss.ob_prompts.count < MAX_PROMPTS && set_button("Add a Question##addq", .Secondary) {
		p := array_add(*ss.ob_prompts);
		p.id = ob_new_id();
		p.in_onboarding = true;
		ss.ob_open = ss.ob_prompts.count;
	}
}

// One question: its title and answer count, opened to edit (true: Delete Question).
prompt_card :: (g: *dc.Guild, p: *Ob_Prompt, pi: int) -> bool {
	open := ss.ob_open == pi + 1;
	card := ui.box("q", .Draw_Background);
	card.semantic_size = .[ui.pct(1), ui.children()];
	card.layout_axis = .Y;
	card.style.radius = all4(8);
	card.style.bg = T("--background-mod-subtle");
	ui.parent(card); defer ui.pop_parent();
	head := row("h", .Clickable);
	head.semantic_size = .[ui.pct(1), ui.px(56)];
	head.hover_cursor = .Pointer;
	if ui.signal(head).clicked ss.ob_open = ifx open then 0 else pi + 1;
	{ ui.parent(head); defer ui.pop_parent();
		spacer(.X, 16);
		col := ui.box("t");
		col.semantic_size = .[ui.fill(), ui.children()];
		col.layout_axis = .Y;
		{ ui.parent(col); defer ui.pop_parent();
			title := trim(ui.editor_text(*p.title));
			label(ifx title then title else "Untitled question", .Semibold, 15, T("--text-strong"), 20);
			label(tprint("% answer%%", p.options.count, ifx p.options.count == 1 then "" else "s", ifx p.required then " · required" else ""), .Normal, 13, T("--text-muted"), 16);
		}
		icon("chev", ifx open then "chevron-small-up" else "chevron-small-down", 20, T("--interactive-icon-default"));
		spacer(.X, 16);
	}
	spacer(.Y, 8);
	if !open return false;
	inner := row("e");
	inner.semantic_size = .[ui.pct(1), ui.children()];
	ui.parent(inner); defer ui.pop_parent();
	spacer(.X, 16);
	gone := false;
	col := ui.box("f");
	col.semantic_size = .[ui.fill(), ui.children()];
	col.layout_axis = .Y;
	{ ui.parent(col); defer ui.pop_parent();
		field_title("Question");
		if set_input("qtitle", *p.title, "What brings you here?", max_runes = 100) == .Escape ss.field_escape = true;
		spacer(.Y, 8);
		if set_toggle_row("multi", "Members can pick more than one answer", "", !p.single) p.single = !p.single;
		spacer(.Y, 12);
		if set_toggle_row("req", "Required", "Members must answer this question to join.", p.required) p.required = !p.required;
		spacer(.Y, 8);
		removed := -1;
		for * o, oi: p.options {
			ui.id_scope(cast(u64) oi + 1);
			defer ui.pop_seed();
			if option_editor(g, o) removed = oi;
			spacer(.Y, 8);
		}
		if removed >= 0 {
			o := *p.options[removed];
			ui.editor_destroy(*o.title); ui.editor_destroy(*o.desc); array_free(o.channels); array_free(o.roles); free(o.id); free(o.emoji_name);
			array_ordered_remove_by_index(*p.options, removed);
		}
		br := row("btns");
		br.semantic_size = .[ui.pct(1), ui.px(38)];
		{ ui.parent(br); defer ui.pop_parent();
			if p.options.count < MAX_PROMPT_OPTIONS && set_button("Add Answer##adda", .Secondary) {
				o := array_add(*p.options);
				o.id = ob_new_id();
			}
			filler(.X);
			if set_button("Delete Question##delq", .Danger) gone = true;
		}
		spacer(.Y, 16);
	}
	spacer(.X, 16);
	return gone;
}

// One answer: title, description, and the channels and roles it gives (true: Remove).
option_editor :: (g: *dc.Guild, o: *Ob_Option) -> bool {
	box := ui.box("o", .Draw_Border);
	box.semantic_size = .[ui.pct(1), ui.children()];
	box.layout_axis = .Y;
	box.style.radius = all4(8);
	box.style.border = 1;
	box.style.border_color = T("--border-subtle");
	ui.parent(box); defer ui.pop_parent();
	inner := row("i");
	inner.semantic_size = .[ui.pct(1), ui.children()];
	ui.parent(inner); defer ui.pop_parent();
	spacer(.X, 12);
	col := ui.box("c");
	col.semantic_size = .[ui.fill(), ui.children()];
	col.layout_axis = .Y;
	drop := false;
	{ ui.parent(col); defer ui.pop_parent();
		spacer(.Y, 12);
		if set_input("atitle", *o.title, "Answer", max_runes = 50) == .Escape ss.field_escape = true;
		spacer(.Y, 8);
		if set_input("adesc", *o.desc, "Description (optional)", max_runes = 100) == .Escape ss.field_escape = true;
		spacer(.Y, 8);
		chips := row("chips");
		chips.semantic_size = .[ui.pct(1), ui.children()];
		chips.style.child_gap = 6;
		drop_ch, drop_role: dc.Snowflake;
		{ ui.parent(chips); defer ui.pop_parent();
			for o.channels {
				ch := dc.channel_get(store(), it);
				if chip(tprint("c%", it), ifx ch then tprint("#%", ch.name) else "deleted-channel") drop_ch = it;
			}
			for o.roles {
				r := role_of(g, it);
				if chip(tprint("r%", it), ifx r then tprint("@%", r.name) else "deleted-role") drop_role = it;
			}
		}
		if drop_ch for o.channels if it == drop_ch { array_ordered_remove_by_index(*o.channels, it_index); break; }
		if drop_role for o.roles if it == drop_role { array_ordered_remove_by_index(*o.roles, it_index); break; }
		spacer(.Y, 8);
		pick_row := row("picks");
		pick_row.semantic_size = .[ui.pct(1), ui.px(40)];
		pick_row.style.child_gap = 8;
		{ ui.parent(pick_row); defer ui.pop_parent();
			names: [..]string;
			names.allocator = temp;
			chan_ids: [..]dc.Snowflake;
			chan_ids.allocator = temp;
			array_add(*names, "Add a channel");
			array_add(*chan_ids, 0);
			for g.channels {
				ch := dc.channel_get(store(), it);
				if !ch || array_find(o.channels, it) || (ch.kind != .Guild_Text && ch.kind != .Guild_Announcement && ch.kind != .Guild_Forum && ch.kind != .Guild_Voice) continue;
				array_add(*names, ifx ch.kind == .Guild_Voice then ch.name else tprint("#%", ch.name));
				array_add(*chan_ids, it);
			}
			w := ui.box("cw");
			w.semantic_size = .[ui.fill(), ui.children()];
			{ ui.parent(w); defer ui.pop_parent(); pick := select_field("addch", names, 0); if pick > 0 && o.channels.count < 50 array_add(*o.channels, chan_ids[pick]); }
			rnames: [..]string;
			rnames.allocator = temp;
			rids: [..]dc.Snowflake;
			rids.allocator = temp;
			array_add(*rnames, "Add a role");
			array_add(*rids, 0);
			for roles_sorted(g) if it.id != g.id && !it.managed && !array_find(o.roles, it.id) { array_add(*rnames, it.name); array_add(*rids, it.id); }
			w = ui.box("rw");
			w.semantic_size = .[ui.fill(), ui.children()];
			{ ui.parent(w); defer ui.pop_parent(); pick := select_field("addrole", rnames, 0); if pick > 0 && o.roles.count < 50 array_add(*o.roles, rids[pick]); }
		}
		spacer(.Y, 4);
		rr := row("rm");
		rr.semantic_size = .[ui.pct(1), ui.px(32)];
		{ ui.parent(rr); defer ui.pop_parent(); filler(.X); if set_button("Remove Answer##rma", .Link, true, 28) drop = true; }
		spacer(.Y, 8);
	}
	spacer(.X, 12);
	return drop;
}

// A small removable tag ("#general", "@mods"); true when its x is clicked.
chip :: (id: string, text: string) -> bool {
	c := row(id, .Draw_Background);
	c.semantic_size = .[ui.children(), ui.px(26)];
	c.style.radius = all4(13);
	c.style.bg = T("--background-mod-normal");
	ui.parent(c); defer ui.pop_parent();
	spacer(.X, 10);
	label(text, .Medium, 13, T("--text-strong"), 16);
	spacer(.X, 2);
	x := row_icon_button("x", "x-small");
	return x;
}

// Save Changes: each changed part as its own PUT, as the client sends them ({default_channel_ids}, {prompts}).
onboarding_save :: (g: *dc.Guild) {
	for p: ss.ob_prompts {
		if !trim(ui.editor_text(*p.title)) || !p.options.count { ss_error("Every question needs a title and at least one answer."); return; }
		for p.options if !trim(ui.editor_text(*it.title)) { ss_error("Every answer needs a title."); return; }
	}
	ss_error("");
	if channels_dirty() {
		ids: [..]string;
		ids.allocator = temp;
		for ss.ob_channels array_add(*ids, tprint("\"%\"", it));
		save_call(g, .Save, "PUT", tprint("/guilds/%/onboarding", g.id), tprint("{\"default_channel_ids\":[%]}", join(..ids, ",",, temp)));
	}
	if prompts_dirty() save_call(g, .Save, "PUT", tprint("/guilds/%/onboarding", g.id), prompts_json(ss.ob_prompts));
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
	signing := osign.thread != null;
	{ ui.parent(btns); defer ui.pop_parent();
		spacer(.X, 25 - 8);
		if wide_button("decline", "Decline", .Secondary, !signing) answer = "DELETE";
		if wide_button("accept", ifx signing then "Accepting..." else "Accept", .Primary, !signing && g.owner_offer != "") answer = "PUT";
		spacer(.X, 25 - 8);
	}
	spacer(.Y, 24);
	adm_modal_end();
	if signing {
		// the signature (about half a second of SLH-DSA) is made off the UI thread, then the accept goes
		app.ui.animating = true;
		if !thread_is_done(osign.thread) return;
		thread_deinit(osign.thread);
		free(osign.thread);
		osign.thread = null;
		ss.declined = g.id;
		if osign.sig && net_action() dc.guild_settings_call(app.client, g.id, xx Req.COUNT, "PUT", tprint("/guilds/%/owner-transfer", g.id), tprint("{\"sig\":\"%\"}", osign.sig));
		free(osign.sig);
		osign.sig = "";
		return;
	}
	if adm_escape() ss.declined = g.id;
	if answer == "DELETE" && net_action() {
		ss.declined = g.id;
		dc.guild_settings_call(app.client, g.id, xx Req.COUNT, answer, tprint("/guilds/%/owner-transfer", g.id));
	}
	if answer == "PUT" && atomic_load(*idk.done) && idk.list.count {
		// accepting is signed with our identity key over the offer (serve's owner_accept_message)
		for hosted if it.client && it.client == app.client osign.server_id = it.inv.id;
		osign.key = idk.list[0];
		free(osign.msg);
		osign.msg = copy_string(cast(string) serve.owner_accept_message(osign.server_id, g.owner_offer, cast(s64) store().me));
		osign.thread = dc.spawn(*osign, (o: *Owner_Sign) {
			sig := crypto.slhdsa_sign(o.key.signing, serve.OWNER_CONTEXT, cast([]u8) o.msg,, temp);
			o.sig = base64_encode(cast(string) sig);
			platform.request_frame();
		});
	}
}

Owner_Sign :: struct {
	thread: *Thread; // signing, until done
	server_id: [16]u8;
	key: keys.Keypair;
	msg: string; // heap
	sig: string; // heap, base64: the thread's result
}
osign: Owner_Sign;

// Shared by the settings pages: the readable reason a request failed.
settings_result_error :: (r: *dc.Feature_Result) -> string {
	if r.status == {
	case 0;
		return "Couldn't reach the server. Check your connection and try again.";
	case -1;
		return "That file couldn't be read. Images must be PNG, JPEG, GIF or WEBP files.";
	case -2;
		return "That image is too large.";
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

#scope_file

// ---- Channel Settings ----

chan_texty :: (k: dc.Channel_Type) -> bool { return k != .Guild_Voice && k != .Guild_Stage_Voice && k != .Guild_Category; }
chan_voice :: (k: dc.Channel_Type) -> bool { return k == .Guild_Voice || k == .Guild_Stage_Voice; }
chan_title :: (ch: *dc.Channel) -> string { return ifx chan_texty(ch.kind) then tprint("# %", ch.name) else ch.name; }

has_topic :: (ch: *dc.Channel) -> bool {
	return ch.kind == .Guild_Text || ch.kind == .Guild_Announcement || ch.kind == .Guild_Forum || ch.kind == .Guild_Media;
}

has_slowmode :: (ch: *dc.Channel) -> bool {
	return ch.kind == .Guild_Text || ch.kind == .Guild_Forum || ch.kind == .Guild_Media || chan_voice(ch.kind);
}

SLOWMODE_SECS :: int.[0, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600, 7200, 21600];
TOPIC_MAX :: 1024;

// "Off", "5s", "1m", "6h" as the client's slowmode select labels them.
slowmode_label :: (secs: int) -> string {
	if secs == 0 return "Off";
	if secs < 60 return tprint("%s", secs);
	if secs < 3600 return tprint("%m", secs / 60);
	return tprint("%h", secs / 3600);
}

// The bitrate cap by boost level (VIP servers 384 kbps); a hosted server takes up to 96 kbps.
max_bitrate :: (g: *dc.Guild) -> int {
	if on_hosted() return 96000;
	if dc.guild_has_feature(g, "VIP_REGIONS") return 384000;
	CAPS :: int.[96000, 128000, 256000, 384000];
	return CAPS[clamp(g.premium_tier, 0, 3)];
}

// The Overview as edited: the drafts in ss.chan, the name and the topic.
chan_form :: (ch: *dc.Channel) -> dc.Channel_Form {
	f := ss.chan;
	name := trim(ui.editor_text(*ss.name), "- ");
	f.name = ifx name then dc.channel_name_normalize(name, chan_texty(ch.kind)) else ch.name;
	f.topic = ifx has_topic(ch) then ui.editor_text(*ss.desc) else ch.topic;
	if is_forum(ch) f.available_tags = tags_json(ss.chan_tags);
	return f;
}

is_forum :: (ch: *dc.Channel) -> bool { return ch.kind == .Guild_Forum || ch.kind == .Guild_Media; }

// A forum's tags as saveChannel sends them: {id (kept ones), name, emoji_id, emoji_name, moderated}.
tags_json :: (tags: []dc.Forum_Tag) -> string {
	parts := NewArray(tags.count, string,, temp);
	for tags {
		id := ifx it.id then tprint("\"id\":\"%\",", it.id) else "";
		parts[it_index] = tprint("{%\"name\":%,\"emoji_id\":%,\"emoji_name\":%,\"moderated\":%}", id, dc.json_quote(it.name),
			ifx it.emoji_id then tprint("\"%\"", it.emoji_id) else "null", ifx it.emoji_name then dc.json_quote(it.emoji_name) else "null", it.moderated);
	}
	return tprint("[%]", join(..parts, ",",, temp));
}

tags_free :: () {
	for ss.chan_tags { free(it.name); free(it.emoji_name); }
	array_reset(*ss.chan_tags);
}

ARCHIVE_MINUTES :: int.[60, 1440, 4320, 10080];
ARCHIVE_LABELS :: string.["1 Hour", "24 Hours", "3 Days", "1 Week"];
MAX_FORUM_TAGS :: 20;

chan_overview_dirty :: () -> bool {
	ch := dc.channel_get(store(), ss.channel);
	if !ch return false;
	a, b := chan_form(ch), dc.channel_form_of(ch);
	return a.name != b.name || a.topic != b.topic || a.kind != b.kind || a.nsfw != b.nsfw || a.rate_limit_per_user != b.rate_limit_per_user
		|| a.bitrate != b.bitrate || a.user_limit != b.user_limit || a.rtc_region != b.rtc_region || a.video_quality_mode != b.video_quality_mode
		|| a.flags != b.flags || a.default_auto_archive_duration != b.default_auto_archive_duration || a.default_forum_layout != b.default_forum_layout
		|| a.default_sort_order != b.default_sort_order || (is_forum(ch) && a.available_tags != tags_json(dc.forum_tags(ch.id)));
}

chan_reset :: () {
	ch := dc.channel_get(store(), ss.channel);
	if !ch return;
	ui.editor_set_text(*ss.name, ch.name);
	ui.editor_set_text(*ss.desc, ch.topic);
	ss.chan = dc.channel_form_of(ch);
	ss.chan.name, ss.chan.topic = "", ""; // the store's strings: chan_form takes the editors'
	ss_set(*ss.chan_region, ch.rtc_region);
	ss.chan.rtc_region = ss.chan_region;
	array_reset(*ss.ows);
	for ch.overwrites array_add(*ss.ows, it);
	tags_free();
	for dc.forum_tags(ch.id) array_add(*ss.chan_tags, .{id = it.id, name = copy_string(it.name), emoji_name = copy_string(it.emoji_name), emoji_id = it.emoji_id, moderated = it.moderated});
	ui.editor_set_text(*ss.tag, "");
}

// Save Changes: PATCH /channels/{id} with the whole form (guild_admin.jai; channel_settings_saved answers).
chan_overview_save :: () {
	ch := dc.channel_get(store(), ss.channel);
	if !ch return;
	ss.busy = true;
	ss_error("");
	dc.edit_channel(app.client, ch.id, chan_form(ch));
}

chan_overview_page :: (g: *dc.Guild) -> bool {
	ch := dc.channel_get(store(), ss.channel);
	if !ch return false;
	save := false;
	field_title(ifx ch.kind == .Guild_Category then "Category Name" else "Channel Name");
	res := set_input("name", *ss.name, ch.name, max_runes = 100);
	if res == .Changed && chan_texty(ch.kind) {
		cur := ui.editor_text(*ss.name);
		norm := dc.channel_name_normalize(cur, true);
		if norm != cur ui.editor_set_text(*ss.name, norm);
	}
	if res == .Submit save = true;
	if res == .Escape ss.field_escape = true;
	if has_topic(ch) {
		spacer(.Y, 24);
		field_title(ifx ch.kind == .Guild_Forum || ch.kind == .Guild_Media then "Post Guidelines" else "Channel Topic");
		tw := ui.box("topicwrap");
		tw.semantic_size = .[ui.pct(1), ui.children()];
		tw.layout_axis = .Y;
		ui.parent(tw); defer ui.pop_parent();
		if set_input("topic", *ss.desc, "Let everyone know how to use this channel!", multiline = true, max_runes = TOPIC_MAX, min_h = 170) == .Escape ss.field_escape = true;
		left, t := TOPIC_MAX, ui.editor_text(*ss.desc);
		while t.count { utf8_next_character(*t); left -= 1; } // the client counts characters
		cnt := label(tprint("%", left), .Semibold, 14, T("--text-strong"), 18);
		cnt.flags |= .Floating_X | .Floating_Y;
		cnt.fixed_pos = .{ss.form_w - 14 - cnt.content_size.x, (tw.rect.y1 - tw.rect.y0) - 18 - 10};
	}
	if has_slowmode(ch) {
		spacer(.Y, 24);
		field_title("Slowmode");
		labels := NewArray(SLOWMODE_SECS.count, string,, temp);
		cur := 0;
		for SLOWMODE_SECS {
			labels[it_index] = slowmode_label(it);
			if it <= ss.chan.rate_limit_per_user cur = it_index;
		}
		pick := select_field("slowmode", labels, cur);
		if pick >= 0 ss.chan.rate_limit_per_user = SLOWMODE_SECS[pick];
		spacer(.Y, 8);
		set_para("slowhelp", "Members will be restricted to sending one message and creating one thread per this interval, unless they have the Bypass Slowmode permission.", .Normal, 12, 16, T("--text-default"));
	}
	if ch.kind == .Guild_Text || ch.kind == .Guild_Announcement || is_forum(ch) {
		spacer(.Y, 24);
		field_title("Hide After Inactivity");
		cur := 2; // Discord's default, 3 days
		for ARCHIVE_MINUTES if it == ss.chan.default_auto_archive_duration cur = it_index;
		pick := select_field("archive", ARCHIVE_LABELS, cur);
		if pick >= 0 ss.chan.default_auto_archive_duration = ARCHIVE_MINUTES[pick];
		spacer(.Y, 8);
		set_para("archivehelp", "New threads will stop showing in the channel list after being inactive for the specified duration.", .Normal, 12, 16, T("--text-default"));
	}
	if is_forum(ch) forum_fields(ch);
	if (ch.kind == .Guild_Text || ch.kind == .Guild_Announcement) && !on_hosted() && (dc.guild_has_feature(g, "NEWS") || dc.guild_has_feature(g, "COMMUNITY")) {
		set_divider();
		news := ss.chan.kind == .Guild_Announcement;
		if set_toggle_row("news", "Announcement Channel", "Post messages that reach servers outside your own. Members can follow this channel, so the posts you publish here appear in their servers.", news)
			ss.chan.kind = ifx news then .Guild_Text else .Guild_Announcement;
	}
	if ch.kind != .Guild_Category && ch.kind != .Guild_Stage_Voice && (chan_texty(ch.kind) || !on_hosted()) {
		set_divider();
		if set_toggle_row("nsfw", "Age-Restricted Channel", "Users will need to confirm they are of over the legal age to view in the content in this channel.\nAge-restricted channels are exempt from the explicit content filter.", ss.chan.nsfw)
			ss.chan.nsfw = !ss.chan.nsfw;
	}
	if !chan_voice(ch.kind) return save;
	set_divider();
	field_title("Bitrate");
	kbps := cast(float32) ss.chan.bitrate / 1000;
	if slider("bitrate", *kbps, 8, cast(float32) max_bitrate(g) / 1000, ss.form_w, tprint("%kbps", cast(int)(kbps + 0.5))) ss.chan.bitrate = cast(int)(kbps + 0.5) * 1000;
	spacer(.Y, 4);
	label(tprint("%kbps", ss.chan.bitrate / 1000), .Medium, 14, T("--text-default"), 18);
	if ss.chan.bitrate > 64000 {
		spacer(.Y, 8);
		set_para("bithelp", "ALL THE BITS! Going above 64 kbps may adversely affect people on poor connections.", .Normal, 14, 18, T("--text-feedback-warning"));
	}
	if !on_hosted() {
		set_divider();
		field_title("Video Quality");
		hd := ss.chan.video_quality_mode == 2;
		if radio_row("vq_auto", "Auto", !hd) ss.chan.video_quality_mode = 1;
		if radio_row("vq_720", "720p", hd) ss.chan.video_quality_mode = 2;
		set_para("vqhelp", "Sets camera video quality for all channel participants. Choose Auto for optimal performance.", .Normal, 14, 18, T("--text-muted"));
	}
	set_divider();
	field_title("User Limit");
	n := cast(float32) ss.chan.user_limit;
	if slider("limit", *n, 0, 99, ss.form_w) ss.chan.user_limit = cast(int)(n + 0.5);
	spacer(.Y, 4);
	label(ifx ss.chan.user_limit then tprint("% users", ss.chan.user_limit) else "No limit", .Medium, 14, T("--text-default"), 18);
	spacer(.Y, 8);
	set_para("limithelp", "Limits the number of users that can connect to this voice channel. Users with the Move Members permission ignore this limit and can move other users into the channel.", .Normal, 14, 18, T("--text-muted"));
	if on_hosted() return save;
	set_divider();
	field_title("Region Override");
	names, ids: [..]string;
	names.allocator, ids.allocator = temp, temp;
	array_add(*names, "Automatic");
	array_add(*ids, "");
	r := reply(.Regions);
	if r for dc.vlist(r.body) {
		m := dc.vmap(it);
		id := dc.fstr(m, "id");
		if id && dc.fstr(m, "name") && (!dc.fbool(m, "deprecated") || id == ss.chan.rtc_region) {
			array_add(*names, dc.fstr(m, "name"));
			array_add(*ids, id);
		}
	}
	cur := 0;
	for ids if it == ss.chan.rtc_region cur = it_index;
	pick := select_field("region", names, cur);
	if pick >= 0 {
		ss_set(*ss.chan_region, ids[pick]);
		ss.chan.rtc_region = ss.chan_region;
	}
	spacer(.Y, 8);
	set_para("regionhelp", "Everyone in this channel connects to the selected region. Automatic picks the best one for whoever starts the call.", .Normal, 14, 18, T("--text-muted"));
	return save;
}

// A forum's own Overview: tags, required tags, default layout and sort order.
forum_fields :: (ch: *dc.Channel) {
	REQUIRE_TAG :: 1 << 4;
	set_divider();
	section_heading("tags", "Tags", "Tags let members organize their posts. Members pick them when they post; moderated tags only moderators can apply.");
	gone := -1;
	for * ss.chan_tags {
		ui.id_scope(cast(u64) it_index + 1);
		defer ui.pop_seed();
		r := row("tag", .Draw_Background);
		r.semantic_size = .[ui.pct(1), ui.px(40)];
		r.style.radius = all4(6);
		r.style.bg = T("--background-mod-subtle");
		ui.parent(r); defer ui.pop_parent();
		spacer(.X, 12);
		label(it.name, .Medium, 15, T("--text-strong"), 20);
		if it.moderated { spacer(.X, 8); icon("lock", "lock", 14, T("--text-muted")); }
		filler(.X);
		if set_button(ifx it.moderated then "Anyone can use##mod" else "Moderators only##mod", .Link, true, 28) it.moderated = !it.moderated;
		if row_icon_button("x", "x-small", danger = true) gone = it_index;
		spacer(.X, 6);
	}
	if gone >= 0 {
		free(ss.chan_tags[gone].name);
		free(ss.chan_tags[gone].emoji_name);
		array_ordered_remove_by_index(*ss.chan_tags, gone);
	}
	spacer(.Y, 8);
	ar := row("addtag");
	ar.semantic_size = .[ui.pct(1), ui.children()];
	ar.style.child_gap = 8;
	{ ui.parent(ar); defer ui.pop_parent();
		w := ui.box("in");
		w.semantic_size = .[ui.fill(), ui.children()];
		res: ui.Edit_Result;
		{ ui.parent(w); defer ui.pop_parent(); res = set_input("tagname", *ss.tag, "New tag", max_runes = 20); }
		if res == .Escape ss.field_escape = true;
		name := trim(ui.editor_text(*ss.tag));
		if (set_button("Add Tag##addtag", .Secondary, name != "" && ss.chan_tags.count < MAX_FORUM_TAGS) || (res == .Submit && name)) && ss.chan_tags.count < MAX_FORUM_TAGS {
			array_add(*ss.chan_tags, .{name = copy_string(name)});
			ui.editor_set_text(*ss.tag, "");
		}
	}
	spacer(.Y, 12);
	if set_toggle_row("reqtag", "Require people to select tags when posting", "", (ss.chan.flags & REQUIRE_TAG) != 0) ss.chan.flags ^= REQUIRE_TAG;
	if ch.kind == .Guild_Forum {
		set_divider();
		field_title("Default Layout");
		gallery := ss.chan.default_forum_layout == 2;
		if radio_row("list", "List view", !gallery) ss.chan.default_forum_layout = 1;
		if radio_row("gallery", "Gallery view", gallery) ss.chan.default_forum_layout = 2;
	}
	set_divider();
	field_title("Default Sort Order");
	by_date := ss.chan.default_sort_order == 1;
	if radio_row("recent", "Recently Active", !by_date) ss.chan.default_sort_order = 0;
	if radio_row("created", "Creation Date", by_date) ss.chan.default_sort_order = 1;
}

// ---- Channel Settings: Permissions ----

// What making a channel private denies @everyone (the client's accessPermissions).
chan_access :: (k: dc.Channel_Type) -> u64 { return ifx chan_voice(k) then dc.PERM_VIEW_CHANNEL | dc.PERM_CONNECT else dc.PERM_VIEW_CHANNEL; }

ow_find :: (list: []dc.Overwrite, id: dc.Snowflake) -> *dc.Overwrite {
	for * list if it.id == id return it;
	return null;
}

// Whether the draft d differs from the channel's (an @everyone allowing and denying nothing is no change).
ow_changed :: (ch: *dc.Channel, d: dc.Overwrite) -> bool {
	o := ow_find(ch.overwrites, d.id);
	if !o return d.allow || d.deny || d.id != ch.guild_id;
	return o.allow != d.allow || o.deny != d.deny;
}

ows_dirty :: () -> bool {
	ch := dc.channel_get(store(), ss.channel);
	if !ch return false;
	for ss.ows if ow_changed(ch, it) return true;
	for ch.overwrites if !ow_find(ss.ows, it.id) return true;
	return false;
}

ow_body :: (o: dc.Overwrite) -> string {
	return tprint("{\"id\":\"%\",\"type\":%,\"allow\":\"%\",\"deny\":\"%\"}", o.id, o.kind, o.allow, o.deny);
}

// Save Changes: PUT /channels/{id}/permissions/{target} for each changed overwrite, then DELETE for each
// removed one (the client's updatePermissionOverwrite / clearPermissionOverwrite).
ows_save :: (g: *dc.Guild) {
	ch := dc.channel_get(store(), ss.channel);
	if !ch return;
	ss_error("");
	for ss.ows if ow_changed(ch, it) save_call(g, .Save, "PUT", tprint("/channels/%/permissions/%", ch.id, it.id), ow_body(it));
	for ch.overwrites if !ow_find(ss.ows, it.id) save_call(g, .Save, "DELETE", tprint("/channels/%/permissions/%", ch.id, it.id), "");
}

// The draft overwrite of id, added (allowing and denying nothing) when missing.
ow_draft :: (id: dc.Snowflake, kind: u8) -> *dc.Overwrite {
	o := ow_find(ss.ows, id);
	if o return o;
	array_add(*ss.ows, .{id = id, kind = kind});
	return *ss.ows[ss.ows.count - 1];
}

ow_name :: (g: *dc.Guild, o: dc.Overwrite) -> string {
	if o.kind == 0 {
		if o.id == g.id return "@everyone";
		r := role_of(g, o.id);
		return ifx r then r.name else "deleted-role";
	}
	u := dc.user_get(store(), o.id);
	return ifx u then dc.display_name(u) else tprint("%", o.id);
}

// The overwrite list as the client shows it: roles top first, then members, @everyone last.
ows_sorted :: (g: *dc.Guild) -> []dc.Overwrite {
	out: [..]dc.Overwrite;
	out.allocator = temp;
	for roles_sorted(g) {
		if it.id == g.id continue;
		o := ow_find(ss.ows, it.id);
		if o array_add(*out, o.*);
	}
	for ss.ows if it.kind == 1 array_add(*out, it);
	ev := ow_find(ss.ows, g.id);
	array_add(*out, ifx ev then ev.* else .{id = g.id});
	return out;
}

// The role permission sections (PERM_SECTIONS) a channel of type k has, as masks.
chan_section_mask :: (k: dc.Channel_Type, i: int) -> u64 {
	ALL : u64 : 0xFFFF_FFFF_FFFF_FFFF;
	vocal := chan_voice(k) || k == .Guild_Category;
	if i == {
	case 0; return dc.PERM_VIEW_CHANNEL | dc.PERM_MANAGE_CHANNELS | dc.PERM_MANAGE_ROLES | dc.PERM_MANAGE_WEBHOOKS;
	case 1; return dc.PERM_CREATE_INSTANT_INVITE;
	case 2; #through; case 4; return ALL;
	case 3; #through; case 5; return ifx vocal then ALL else 0;
	}
	return 0;
}

// The channel's names for the general ones.
chan_perm_text :: (p: Perm, cat: bool) -> string, string {
	if p.flag == {
	case dc.PERM_VIEW_CHANNEL;
		if cat return "View Channels", "Allows members to view these channels by default. Disabling this for @everyone will make the category private.";
		return "View Channel", "Allows members to view this channel by default. Disabling this for @everyone will make this channel private.";
	case dc.PERM_MANAGE_CHANNELS;
		return ifx cat then "Manage Channels" else "Manage Channel", "Allows members to change this channel's name, description, and settings. They can also delete it.";
	case dc.PERM_MANAGE_ROLES;
		return "Manage Permissions", "Allows members to change this channel's permissions.";
	}
	return p.title, p.desc;
}

// Deny / neutral / allow (0, 1, 2); the state picked this frame, else -1.
tri_state :: (id: string, state: int, enabled: bool) -> int {
	r := row(id, .Draw_Border | .Clip);
	r.semantic_size = .[ui.children(), ui.px(28)];
	r.style.border = 1;
	r.style.border_color = T("--border-subtle");
	r.style.radius = all4(6);
	ui.parent(r); defer ui.pop_parent();
	pick := -1;
	for k: 0..2 {
		on := state == k;
		b := ui.box(tprint("s%", k), .Clickable | .Draw_Background | .Hot_Animation);
		b.semantic_size = .[ui.px(30), ui.px(26)];
		b.style.bg = ifx !on then ui.Color.{} else ifx k == 0 then T("--status-danger") else ifx k == 2 then T("--status-positive") else T("--background-mod-strong");
		b.style.bg_hot = ifx on then b.style.bg else T("--background-mod-subtle");
		if enabled b.hover_cursor = .Pointer;
		else b.flags |= .Disabled;
		if ui.signal(b).clicked && enabled && !on pick = k;
		ui.parent(b); defer ui.pop_parent();
		c := ifx on then ui.Color.{1, 1, 1, 1} else T("--interactive-icon-default");
		if !enabled c = with_alpha(c, 0.4);
		if k == 1 {
			l := label("/", .Bold, 14, c, 26);
			l.flags |= .Floating_X | .Floating_Y;
			l.fixed_pos = .{12, 0};
		} else {
			i := icon("i", ifx k == 0 then "x-small" else "checkmark-small", 16, c);
			i.flags |= .Floating_X | .Floating_Y;
			i.fixed_pos = .{7, 5};
		}
	}
	return pick;
}

chan_permissions_page :: (g: *dc.Guild) {
	ch := dc.channel_get(store(), ss.channel);
	if !ch return;
	is_cat := ch.kind == .Guild_Category;
	cat := dc.channel_get(store(), ch.parent_id);
	if cat && !is_cat {
		synced := dc.overwrites_equal(ch.overwrites, cat.overwrites);
		b := row("sync", .Draw_Background);
		b.semantic_size = .[ui.pct(1), ui.px(52)];
		b.style.bg = T("--background-mod-subtle");
		b.style.radius = all4(8);
		{ ui.parent(b); defer ui.pop_parent();
			spacer(.X, 16);
			icon("ic", ifx synced then "link" else "warning", 16, T("--interactive-icon-default"));
			spacer(.X, 10);
			t := ui.box("t", .Wrap_Text);
			t.semantic_size = .[ui.fill(), ui.text_size()];
			t.style.line_height = 18;
			t.style.text_color = T("--text-default");
			spans := NewArray(2, ui.Span,, temp);
			spans[0] = .{text = ifx synced then "Permissions synced with category: " else "Permissions not synced with category: ", font = F(.Normal), size = 14};
			spans[1] = .{text = cat.name, font = F(.Bold), size = 14};
			ui.set_spans(t, spans);
			if !synced {
				spacer(.X, 12);
				if set_button("Sync Now##sync", .Primary, !ss.busy && !ows_dirty(), 32) {
					list: [..]string;
					list.allocator = temp;
					for cat.overwrites array_add(*list, ow_body(it));
					ss_action(g, .COUNT, "PATCH", tprint("/channels/%", ch.id), tprint("{\"permission_overwrites\":[%]}", join(..list, ",",, temp)));
				}
			}
			spacer(.X, 12);
		}
		spacer(.Y, 20);
	}
	access := chan_access(ch.kind);
	ev := ow_find(ss.ows, g.id);
	private := ev && (ev.deny & access) == access;
	help := ifx is_cat then "By making a category private, only select members and roles will be able to view this category. Linked channels in this category will automatically match to this setting."
		else ifx chan_voice(ch.kind) then "By making a channel private, only select members and roles will have access to view or connect to this channel."
		else "By making a channel private, only select members and roles will be able to view this channel.";
	if set_toggle_row("private", ifx is_cat then "Private Category" else "Private Channel", help, private) {
		o := ow_draft(g.id, 0);
		o.allow &= ~access;
		if private o.deny &= ~access;
		else o.deny |= access;
	}
	set_divider();
	label("Advanced permissions", .Semibold, 16, T("--text-strong"), 20);
	spacer(.Y, 16);
	if !ow_find(ss.ows, ss.ow_id) ss.ow_id = g.id;
	cols := row("adv");
	cols.semantic_size = .[ui.pct(1), ui.children()];
	cols.cross_align = .Start;
	ui.parent(cols); defer ui.pop_parent();
	left := ui.box("targets");
	left.semantic_size = .[ui.px(200), ui.children()];
	left.layout_axis = .Y;
	{ ui.parent(left); defer ui.pop_parent();
		hr := row("thead");
		hr.semantic_size = .[ui.pct(1), ui.px(28)];
		{ ui.parent(hr); defer ui.pop_parent();
			label("ROLES/MEMBERS", .Bold, 12, T("--text-muted"), 16);
			filler(.X);
			if row_icon_button("add", "plus-small") ss.ow_adding = !ss.ow_adding;
		}
		spacer(.Y, 4);
		if ss.ow_adding ow_add_list(g);
		for ows_sorted(g) {
			ui.id_scope(cast(u64) it.id);
			defer ui.pop_seed();
			sel := it.id == ss.ow_id;
			r := row("t", .Clickable | .Draw_Background | .Hot_Animation);
			r.semantic_size = .[ui.pct(1), ui.px(32)];
			r.style.radius = all4(6);
			r.style.bg = ifx sel then T("--background-mod-normal") else .{};
			r.style.bg_hot = ifx sel then r.style.bg else T("--background-mod-subtle");
			r.hover_cursor = .Pointer;
			if ui.signal(r).clicked ss.ow_id = it.id;
			ui.parent(r); defer ui.pop_parent();
			spacer(.X, 8);
			if it.kind == 1 avatar_box("av", it.id, 20);
			else {
				role := role_of(g, it.id);
				dot := ui.box("dot", .Draw_Background);
				dot.semantic_size = .[ui.px(12), ui.px(12)];
				dot.style.radius = all4(6);
				dot.style.bg = color_of(ifx role then role.color else 0);
			}
			spacer(.X, 8);
			label(ellipsize(ow_name(g, it), .Medium, 14, 150), .Medium, 14, ifx sel then T("--interactive-text-active") else T("--interactive-text-default"), 18);
		}
	}
	spacer(.X, 24);
	right := ui.box("perms");
	right.semantic_size = .[ui.fill(), ui.children()];
	right.layout_axis = .Y;
	ui.parent(right); defer ui.pop_parent();
	cur := ow_find(ss.ows, ss.ow_id);
	shown := ifx cur then cur.* else dc.Overwrite.{id = g.id};
	th := row("ptitle");
	th.semantic_size = .[ui.pct(1), ui.px(28)];
	{ ui.parent(th); defer ui.pop_parent();
		label(ow_name(g, shown), .Semibold, 16, T("--text-strong"), 20);
		filler(.X);
		if shown.id != g.id && set_button("Remove##rmow", .Link, true, 28) {
			for ss.ows if it.id == shown.id { array_ordered_remove_by_index(*ss.ows, it_index); break; }
			ss.ow_id = g.id;
		}
	}
	// what we may grant or deny: what we hold here (the owner and administrators: everything)
	mine := dc.channel_permissions(store(), ch.id);
	if g.owner_id == store().me || (dc.guild_permissions(store(), g.id) & dc.PERM_ADMINISTRATOR) mine = 0xFFFF_FFFF_FFFF_FFFF;
	for sec, si: PERM_SECTIONS {
		mask := chan_section_mask(ch.kind, si);
		any := false;
		for sec.perms if it.flag & mask any = true;
		if !any continue;
		spacer(.Y, 16);
		label(ifx si == 0 then (ifx is_cat then "General Category Permissions" else "General Channel Permissions") else sec.title, .Bold, 12, T("--text-muted"), 16);
		spacer(.Y, 8);
		for p: sec.perms {
			if !(p.flag & mask) continue;
			ui.id_scope(p.flag);
			defer ui.pop_seed();
			title, desc := chan_perm_text(p, is_cat);
			pr := row("p");
			pr.semantic_size = .[ui.pct(1), ui.children()];
			pr.cross_align = .Start;
			{ ui.parent(pr); defer ui.pop_parent();
				col := ui.box("t");
				col.semantic_size = .[ui.fill(), ui.children()];
				col.layout_axis = .Y;
				{ ui.parent(col); defer ui.pop_parent();
					label(title, .Medium, 15, T("--text-strong"), 20);
					spacer(.Y, 2);
					set_para("d", desc, .Normal, 13, 17, T("--text-muted"));
				}
				spacer(.X, 16);
				state := ifx shown.deny & p.flag then 0 else ifx shown.allow & p.flag then 2 else 1;
				pick := tri_state("tri", state, (mine & p.flag) != 0);
				if pick >= 0 {
					o := ow_draft(shown.id, shown.kind);
					o.allow &= ~p.flag;
					o.deny &= ~p.flag;
					if pick == 0 o.deny |= p.flag;
					if pick == 2 o.allow |= p.flag;
				}
			}
			set_divider();
		}
	}
}

// Add members or roles: the roles not listed yet, filtered by the search, then the members it finds
// (Enter searches, as Manage Members does).
ow_add_list :: (g: *dc.Guild) {
	res := set_input("owsearch", *ss.search, "Add members or roles");
	if res == .Escape ss.ow_adding = false;
	q := to_lower_copy(trim(ui.editor_text(*ss.search)),, temp);
	if res == .Submit && q { ss.loading[Req.Members] = false; members_search(g); }
	spacer(.Y, 4);
	pick_row :: (id: dc.Snowflake, name: string) -> bool {
		ui.id_scope(cast(u64) id);
		defer ui.pop_seed();
		r := row("a", .Clickable | .Draw_Background | .Hot_Animation);
		r.semantic_size = .[ui.pct(1), ui.px(28)];
		r.style.radius = all4(6);
		r.style.bg_hot = T("--background-mod-subtle");
		r.hover_cursor = .Pointer;
		clicked := ui.signal(r).clicked;
		ui.parent(r); defer ui.pop_parent();
		spacer(.X, 8);
		icon("p", "plus-small", 14, T("--interactive-icon-default"));
		spacer(.X, 6);
		label(ellipsize(name, .Normal, 14, 150), .Normal, 14, T("--text-default"), 18);
		return clicked;
	}
	picked: dc.Snowflake;
	kind: u8;
	for roles_sorted(g) {
		if it.id == g.id || ow_find(ss.ows, it.id) || (q && !contains(to_lower_copy(it.name,, temp), q)) continue;
		if pick_row(it.id, it.name) picked, kind = it.id, 0;
	}
	found := reply(.Members);
	if found && q for dc.flist(dc.vmap(found.body), "members") {
		u := dc.fmap(dc.fmap(dc.vmap(it), "member"), "user");
		uid := dc.fsnow(u, "id");
		if !uid || ow_find(ss.ows, uid) continue;
		if pick_row(uid, user_display(u)) picked, kind = uid, 1;
	}
	set_divider();
	if !picked return;
	ow_draft(picked, kind);
	ss.ow_id, ss.ow_adding = picked, false;
	ui.editor_set_text(*ss.search, "");
}
