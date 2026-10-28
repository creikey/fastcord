// Guild management, as in the official client (traffic/create_channel.jsonl,
// .secrets/screens/create_channel): the Create Channel modal (category "+":
// Text / Voice / Forum, name), channel settings (channel row cog: a full-window
// page with Overview — name, topic, slowmode — and Delete Channel; Save sends the
// whole form), the Delete Channel confirm, custom emoji upload (emoji picker
// "Add Emoji"), and a notice for failed requests. Requests go through
// jai/discord/guild_admin.jai; the gateway's CHANNEL_* / GUILD_EMOJIS_UPDATE
// apply the result to the Store.

can_manage_channels :: (gid: dc.Snowflake) -> bool {
	return gid != 0 && (dc.guild_permissions(store(), gid) & dc.PERM_MANAGE_CHANNELS) != 0;
}

can_manage_channel :: (ch: *dc.Channel) -> bool {
	return ch != null && ch.guild_id != 0 && (dc.channel_permissions(store(), ch.id) & dc.PERM_MANAGE_CHANNELS) != 0;
}

can_upload_emoji :: (gid: dc.Snowflake) -> bool {
	return gid != 0 && (dc.guild_permissions(store(), gid) & (dc.PERM_CREATE_GUILD_EXPRESSIONS | dc.PERM_MANAGE_GUILD_EXPRESSIONS)) != 0;
}

// ---- entry points ----

create_category_open :: (gid: dc.Snowflake) {
	create_channel_open(gid, 0);
	adm.kind = .Guild_Category;
}

create_channel_open :: (gid: dc.Snowflake, category_id: dc.Snowflake) {
	adm.modal = .Create_Channel;
	adm.guild = gid;
	adm.channel = category_id;
	adm.kind = .Guild_Text;
	adm.busy = false;
	ui.editor_set_text(*adm.name, "");
	set_error("");
	adm.focus_field = true;
	if app.client != null dc.open_create_channel(app.client, gid);
}

channel_settings_open :: (ch: *dc.Channel) {
	if ch == null return;
	adm.from_menu = false;
	adm.modal = .Channel_Settings;
	adm.guild = ch.guild_id;
	adm.channel = ch.id;
	adm.kind = ch.kind;
	adm.busy = false;
	ui.editor_set_text(*adm.name, ch.name);
	ui.editor_set_text(*adm.topic, ch.topic);
	adm.slowmode = 0;
	for SLOWMODE_SECS if it <= ch.rate_limit_per_user adm.slowmode = it_index;
	set_error("");
	adm.focus_field = false;
	adm.slow_open = false;
	app.ui.focus = 0;
	if app.client != null dc.open_channel_settings(app.client, ch);
}

// channel_delete_open: Delete Channel / Category / Thread from a sidebar row menu. The
// official confirm loads the guild's role member counts as it opens.
channel_delete_open :: (th: *dc.Channel) {
	if th == null return;
	adm.modal = .Delete_Channel;
	adm.guild = th.guild_id;
	adm.channel = th.id;
	adm.kind = th.kind;
	adm.busy = false;
	adm.from_menu = true;
	adm.del_parent = ifx dc.is_thread(th) then th.parent_id else 0;
	set_error("");
	if net_action() dc.fetch_role_member_counts(app.client, th.guild_id);
}

// emoji_upload_pick: "Add Emoji" in the picker. The OS file dialog runs here
// (UI thread); reading and encoding the file happens on a feature worker.
emoji_upload_pick :: (gid: dc.Snowflake) {
	if adm.emoji_busy return;
	paths := pick_files();
	if paths.count == 0 || !net_action() return;
	path := paths[0];
	dc.upload_guild_emoji(app.client, gid, path, dc.emoji_name_from_filename(path));
	adm.emoji_busy = true;
}

emoji_upload_busy :: () -> bool { return adm.emoji_busy; }

guild_admin_modal_open :: () -> bool { return adm.modal != .None; }

// A one-button "Okay" notice (also the message actions' failures: pins).
show_notice :: (title: string, text: string) {
	adm.modal = .Notice;
	adm.notice_title = title;
	free(adm.notice);
	adm.notice = copy_string(text);
}

guild_admin_reset_for_test :: () {
	ui.editor_destroy(*adm.name);
	ui.editor_destroy(*adm.topic);
	free(adm.error);
	free(adm.notice);
	adm = .{};
}

guild_admin_state_for_test :: () -> string { return tprint("% % % %", adm.modal, adm.channel, adm.kind, adm.slowmode); }

// guild_admin_receive: finished create / edit / delete / emoji requests.
guild_admin_receive :: (r: *dc.Feature_Result) {
	if app.client != null dc.guild_admin_apply(app.client, r);
	app.ui.animating = true;
	if r.op == {
	case .Guild_Aux;
		return;
	case .Emoji_Upload;
		adm.emoji_busy = false;
		if !r.ok show_notice("Couldn't upload emoji", result_error(r));
		return;
	case .Channel_Create;
		if adm.modal != .Create_Channel return;
		if r.ok {
			// the client opens a new text or forum channel (voice: no)
			adm.pending_select = dc.fsnow(dc.vmap(r.body), "id");
			if adm.kind == .Guild_Voice adm.pending_select = 0;
			admin_close();
		}
	case .Channel_Edit;
		if adm.modal != .Channel_Settings || r.channel_id != adm.channel return;
		if r.ok {
			adm.busy = false; // the page stays open, now saved
			return;
		}
	case .Channel_Delete;
		if adm.modal != .Delete_Channel || r.channel_id != adm.channel return;
		if r.ok {
			// a deleted thread returns to its parent channel
			if app.view.channel == r.channel_id select_channel(adm.guild, ifx adm.from_menu then adm.del_parent else 0);
			admin_close();
		}
	}
	if !r.ok {
		adm.busy = false;
		set_error(result_error(r));
	}
}

// ---- shared modal pieces ----

// Scrim + centered dialog, pushed as parent; false when dismissed this frame
// (scrim click, close X). Close with adm_modal_end.
adm_modal_begin :: (id: string, w: float32, title: string, subtitle := "", fixed_h: float32 = 0) -> bool {
	scrim := ui.box(tprint("%_scrim", id), .Draw_Background | .Clickable | .Floating_X | .Floating_Y | .Overlay);
	scrim.semantic_size = .[ui.px(app.ui.window.x), ui.px(app.ui.window.y)];
	scrim.style.bg = .{0, 0, 0, 0.7};
	if ui.signal(scrim).clicked return false;
	d := ui.box(id, .Draw_Background | .Draw_Border | .Floating_X | .Floating_Y | .Overlay | .Clickable | .Clip);
	d.semantic_size = .[ui.px(w), ifx fixed_h > 0 then ui.px(fixed_h) else ui.children()];
	d.fixed_pos = .{(app.ui.window.x - w) / 2, max(16.0, (app.ui.window.y - (d.rect.y1 - d.rect.y0)) / 2)};
	d.style.bg = T("--modal-background");
	d.style.border_color = T("--border-subtle");
	d.style.border = 1;
	d.style.radius = all4(12);
	d.layout_axis = .Y;
	ui.signal(d);
	ui.push_parent(d);
	x := ui.box("close", .Clickable | .Floating_X | .Floating_Y);
	x.semantic_size = .[ui.px(24), ui.px(24)];
	x.fixed_pos = .{w - 17 - 24, 17};
	xs := ui.signal(x);
	set_icon(x, "x-large", ifx xs.hovering then T("--interactive-icon-hover") else T("--interactive-icon-default"));
	if xs.clicked {
		ui.pop_parent();
		return false;
	}
	spacer(.Y, 25);
	t := row("title");
	t.semantic_size = .[ui.pct(1), ui.px(24)];
	{ ui.parent(t); defer ui.pop_parent();
		spacer(.X, 25);
		label(title, .Semibold, 20, T("--text-strong"), 24);
	}
	if subtitle != "" {
		spacer(.Y, 4);
		st := row("subtitle");
		st.semantic_size = .[ui.pct(1), ui.px(18)];
		{ ui.parent(st); defer ui.pop_parent();
			spacer(.X, 25);
			label(subtitle, .Normal, 14, T("--text-muted"), 18);
		}
	}
	return true;
}

adm_modal_end :: () { ui.pop_parent(); }

// Unconsumed Escape this frame.
adm_escape :: () -> bool {
	for * e: app.ui.events {
		if !e.consumed && e.kind == .Key_Down && e.key == .Escape {
			e.consumed = true;
			return true;
		}
	}
	return false;
}

Adm_Button :: enum u8 {
	Primary;
	Secondary;
	Danger;
	Link_Danger; // text-only red ("Delete Channel")
}

adm_button :: (id: string, text: string, kind: Adm_Button, enabled := true) -> bool {
	b := ui.box(tprint("%##%", text, id), .Clickable | .Draw_Background | .Draw_Text | .Hot_Animation);
	b.semantic_size = .[ui.text_size(16), ui.px(38)];
	b.style.radius = all4(8);
	b.style.font = F(.Medium);
	b.style.font_size = 14;
	b.style.text_align = .Center;
	if kind == {
	case .Primary;
		b.style.bg = T("--background-brand");
		b.style.bg_hot = with_alpha(T("--background-brand"), 0.85);
		b.style.text_color = .{1, 1, 1, 1};
	case .Secondary;
		b.style.bg = T("--background-mod-normal");
		b.style.bg_hot = T("--background-mod-strong");
		b.style.text_color = T("--text-strong");
	case .Danger;
		b.style.bg = T("--status-danger");
		b.style.bg_hot = T("--control-critical-primary-background-hover");
		b.style.text_color = .{1, 1, 1, 1};
		b.flags |= .Click_On_Release;
	case .Link_Danger;
		b.style.bg_hot = T("--background-mod-subtle");
		b.style.text_color = T("--text-feedback-critical");
		b.flags |= .Click_On_Release;
	}
	if !enabled {
		b.flags |= .Disabled;
		b.style.bg = with_alpha(b.style.bg, b.style.bg.w * 0.5);
		b.style.bg_hot = b.style.bg;
		b.style.text_color = with_alpha(b.style.text_color, 0.5);
	}
	return ui.signal(b).clicked && enabled;
}

// Small caps section label ("CHANNEL NAME").
adm_section :: (text: string) {
	r := row(tprint("sec_%", text));
	r.semantic_size = .[ui.pct(1), ui.px(16)];
	{ ui.parent(r); defer ui.pop_parent();
		spacer(.X, 25);
		label(text, .Semibold, 12, T("--text-muted"), 16);
	}
	spacer(.Y, 8);
}

// ---- overlays ----

guild_admin_overlays :: () {
	if adm.pending_select != 0 {
		ch := dc.channel_get(store(), adm.pending_select);
		if ch != null {
			select_channel(ch.guild_id, ch.id);
			adm.pending_select = 0;
		}
	}
	if adm.modal == {
	case .None;
	case .Create_Channel;
		create_channel_modal();
	case .Channel_Settings;
		channel_settings_page();
	case .Delete_Channel;
		if adm.in_settings channel_settings_page();
		delete_channel_modal();
	case .Notice;
		notice_modal();
	}
}

#scope_file

Admin_Modal :: enum u8 {
	None;
	Create_Channel;
	Channel_Settings;
	Delete_Channel;
	Notice;
}

Admin_State :: struct {
	modal: Admin_Modal;
	guild: dc.Snowflake;
	channel: dc.Snowflake; // settings / delete target; create: the category (0 = none)
	kind: dc.Channel_Type; // create: Guild_Text, Guild_Voice or Guild_Forum
	name: ui.Editor;
	topic: ui.Editor;
	slowmode: int; // index into SLOWMODE_SECS
	focus_field: bool; // focus the name field on the next frame
	busy: bool; // a create / save / delete is in flight
	error: string; // heap; shown under the fields
	notice_title: string; // static
	notice: string; // heap
	pending_select: dc.Snowflake; // created channel to open once the gateway delivers it
	emoji_busy: bool;
	from_menu: bool; // delete opened from a context menu: Cancel closes
	del_parent: dc.Snowflake; // a thread being deleted: where to go after
	slow_open: bool; // settings: the Slowmode dropdown is open
	slow_anchor: ui.Rect;
	in_settings: bool; // the delete confirm returns to the settings page
}

adm: Admin_State;

SLOWMODE_SECS := int.[0, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600, 7200, 21600];

// "Off", "5s", "1m", "6h" as the client's slowmode select labels them.
slowmode_label :: (secs: int) -> string {
	if secs == 0 return "Off";
	if secs < 60 return tprint("%s", secs);
	if secs < 3600 return tprint("%m", secs / 60);
	return tprint("%h", secs / 3600);
}

set_error :: (msg: string) {
	free(adm.error);
	adm.error = copy_string(msg);
}

admin_close :: () {
	adm.modal = .None;
	adm.busy = false;
	set_error("");
	app.ui.focus = 0;
}

// Text-like channels take the client's name normalisation (lowercase, dashes).
text_named :: (kind: dc.Channel_Type) -> bool {
	if kind == {
	case .Guild_Voice; #through; case .Guild_Stage_Voice; #through; case .Guild_Category;
		return false;
	}
	return true;
}

delete_open :: () {
	adm.in_settings = adm.modal == .Channel_Settings;
	adm.modal = .Delete_Channel;
	adm.slow_open = false;
	set_error("");
	if app.client != null dc.open_delete_channel(app.client, adm.guild);
}

result_error :: (r: *dc.Feature_Result) -> string {
	if r.status == {
	case 0;
		return "Couldn't reach Discord. Check your connection and try again.";
	case -1;
		return "That file couldn't be read. Emoji must be a PNG, JPEG, GIF, WEBP or AVIF image.";
	case -2;
		return "That file is too large. Emoji must be under 256 KB.";
	case 403;
		return "You don't have permission to do that.";
	}
	msg := dc.api_error_message(r.body);
	if msg != "" return msg;
	return tprint("Something went wrong (HTTP %).", r.status);
}

// Bordered single-field input; returns its edit result.
modal_field :: (id: string, ed: *ui.Editor, placeholder: string, icon_name := "") -> ui.Edit_Result {
	res := ui.Edit_Result.None;
	r := row(tprint("%_row", id));
	r.semantic_size = .[ui.pct(1), ui.children()];
	{ ui.parent(r); defer ui.pop_parent();
		spacer(.X, 25);
		box := row(id, .Draw_Background | .Draw_Border | .Clickable);
		box.semantic_size = .[ui.fill(), ui.children()];
		box.style.bg = T("--input-background-default");
		box.style.border_color = ifx app.ui.focus == box.key then T("--input-border-active") else T("--input-border-default");
		box.style.border = 1;
		box.style.radius = all4(8);
		box.hover_cursor = .IBeam;
		if ui.signal(box).pressed app.ui.focus = box.key;
		if adm.focus_field && id == "name" {
			app.ui.focus = box.key;
			adm.focus_field = false;
		}
		{ ui.parent(box); defer ui.pop_parent();
			spacer(.X, 12);
			if icon_name != "" {
				icon("ic", icon_name, 16, T("--text-muted"));
				spacer(.X, 6);
			}
			res = text_field("f", ed, placeholder, app.ui.focus == box.key, 16, 20, 9);
			spacer(.X, 12);
		}
		spacer(.X, 25);
	}
	return res;
}

// Keeps a text channel name normalised while typing.
normalize_name_field :: (kind: dc.Channel_Type) {
	if !text_named(kind) return;
	cur := ui.editor_text(*adm.name);
	norm := dc.channel_name_normalize(cur, true);
	if norm != cur ui.editor_set_text(*adm.name, norm);
}

error_line :: () {
	if adm.error == "" return;
	spacer(.Y, 8);
	r := row("err");
	r.semantic_size = .[ui.pct(1), ui.children()];
	{ ui.parent(r); defer ui.pop_parent();
		spacer(.X, 25);
		b := ui.box("errtext", .Draw_Text | .Wrap_Text);
		b.semantic_size = .[ui.fill(), ui.text_size()];
		b.text = adm.error;
		b.style.font = F(.Normal);
		b.style.font_size = 14;
		b.style.line_height = 18;
		b.style.text_color = T("--text-feedback-critical");
		spacer(.X, 25);
	}
}

// Radio dot (20px), selected = brand ring + dot.
radio_dot :: (on: bool) {
	rad := ui.box("radio", .Draw_Border);
	rad.semantic_size = .[ui.px(20), ui.px(20)];
	rad.style.radius = all4(10);
	rad.style.border = 2;
	rad.style.border_color = ifx on then T("--background-brand") else T("--interactive-icon-default");
	if on {
		ui.parent(rad); defer ui.pop_parent();
		dot := ui.box("dot", .Draw_Background | .Floating_X | .Floating_Y);
		dot.semantic_size = .[ui.px(10), ui.px(10)];
		dot.fixed_pos = .{5, 5};
		dot.style.radius = all4(5);
		dot.style.bg = T("--background-brand");
	}
}

create_channel_modal :: () {
	W :: 480;
	cat := dc.channel_get(store(), adm.channel);
	sub := ifx cat then tprint("in %", cat.name) else "";
	is_cat := adm.kind == .Guild_Category;
	if !adm_modal_begin("createchan", W, ifx is_cat then "Create Category" else "Create Channel", sub) {
		admin_close();
		return;
	}
	submit := false;
	spacer(.Y, 24);
	if !is_cat {
		lr := row("typelbl");
		lr.semantic_size = .[ui.pct(1), ui.px(20)];
		{ ui.parent(lr); defer ui.pop_parent();
			spacer(.X, 25);
			label("Channel Type", .Semibold, 16, T("--text-strong"), 20);
		}
		spacer(.Y, 8);
		Opt :: struct {
			kind: dc.Channel_Type;
			icon, title: string;
			desc: string;
		}
		opts := Opt.[
			.{.Guild_Text, "hashmark", "Text", "Send messages, images, GIFs, emoji, opinions, and puns"},
			.{.Guild_Voice, "voice-normal", "Voice", "Hang out together with voice, video, and screen share"},
			.{.Guild_Forum, "forum", "Forum", "Create a space for organized discussions"}
		];
		for o: opts {
			if app.client && app.client.cfg.hosted.host && o.kind != .Guild_Text continue; // -serve has no voice or forums yet.
			selected := adm.kind == o.kind;
			r := row(tprint("type_%", o.title), .Clickable);
			r.semantic_size = .[ui.pct(1), ui.px(58)];
			r.cross_align = .Start;
			r.hover_cursor = .Pointer;
			if ui.signal(r).clicked && !selected {
				adm.kind = o.kind;
				normalize_name_field(adm.kind);
			}
			{ ui.parent(r); defer ui.pop_parent();
				spacer(.X, 25);
				radio_dot(selected);
				spacer(.X, 12);
				col := ui.box("col");
				col.semantic_size = .[ui.fill(), ui.children()];
				col.layout_axis = .Y;
				{ ui.parent(col); defer ui.pop_parent();
					tr := row("t");
					tr.semantic_size = .[ui.pct(1), ui.px(20)];
					{ ui.parent(tr); defer ui.pop_parent();
						icon("ic", o.icon, 20, T("--text-strong"));
						spacer(.X, 6);
						label(o.title, .Medium, 16, T("--text-strong"), 20);
					}
					spacer(.Y, 4);
					label(o.desc, .Normal, 14, T("--text-default"), 18);
				}
				spacer(.X, 25);
			}
		}
		spacer(.Y, 8);
	}
	nl := row("namelbl");
	nl.semantic_size = .[ui.pct(1), ui.px(20)];
	{ ui.parent(nl); defer ui.pop_parent();
		spacer(.X, 25);
		label(ifx is_cat then "Category Name" else "Channel Name", .Semibold, 16, T("--text-strong"), 20);
	}
	spacer(.Y, 8);
	icon_name := ifx adm.kind == .Guild_Voice then "voice-normal" else ifx adm.kind == .Guild_Forum then "forum" else ifx is_cat then "" else "hashmark";
	res := modal_field("name", *adm.name, ifx is_cat then "New Category" else "new-channel", icon_name);
	if res == .Changed normalize_name_field(adm.kind);
	if res == .Submit submit = true;
	if res == .Escape adm.modal = .None;
	error_line();
	spacer(.Y, 24);
	name := trim(ui.editor_text(*adm.name), "- ");
	btns := row("btns");
	btns.semantic_size = .[ui.pct(1), ui.px(40)];
	btns.style.child_gap = 8;
	{ ui.parent(btns); defer ui.pop_parent();
		spacer(.X, 25 - 8);
		if wide_button("cancel", "Cancel", .Secondary) adm.modal = .None;
		if wide_button("create", ifx adm.busy then "Creating..." else ifx is_cat then "Create Category" else "Create Channel", .Primary, name != "" && !adm.busy) submit = true;
		spacer(.X, 25 - 8);
	}
	spacer(.Y, 24);
	adm_modal_end();
	if adm_escape() adm.modal = .None;
	if adm.modal == .None {
		admin_close();
		return;
	}
	if submit && name != "" && !adm.busy && net_action() {
		adm.busy = true;
		set_error("");
		dc.create_channel(app.client, adm.guild, adm.kind, dc.channel_name_normalize(name, text_named(adm.kind)), adm.channel);
	}
}

TOPIC_MAX :: 1024;

// The settings Overview form as edited (the PATCH body).
settings_form :: (ch: *dc.Channel) -> dc.Channel_Form {
	f := dc.channel_form_of(ch);
	name := trim(ui.editor_text(*adm.name), "- ");
	if name != "" f.name = dc.channel_name_normalize(name, text_named(ch.kind));
	if has_topic(ch) f.topic = ui.editor_text(*adm.topic);
	if has_slowmode(ch) f.rate_limit_per_user = SLOWMODE_SECS[adm.slowmode];
	return f;
}

has_topic :: (ch: *dc.Channel) -> bool {
	return ch.kind == .Guild_Text || ch.kind == .Guild_Announcement || ch.kind == .Guild_Forum || ch.kind == .Guild_Media;
}

has_slowmode :: (ch: *dc.Channel) -> bool {
	return ch.kind == .Guild_Text || ch.kind == .Guild_Forum || ch.kind == .Guild_Media || ch.kind == .Guild_Voice || ch.kind == .Guild_Stage_Voice;
}

settings_dirty :: (ch: *dc.Channel) -> bool {
	f := settings_form(ch);
	return f.name != ch.name || f.topic != ch.topic || f.rate_limit_per_user != ch.rate_limit_per_user;
}

settings_reset :: (ch: *dc.Channel) {
	ui.editor_set_text(*adm.name, ch.name);
	ui.editor_set_text(*adm.topic, ch.topic);
	adm.slowmode = 0;
	for SLOWMODE_SECS if it <= ch.rate_limit_per_user adm.slowmode = it_index;
	set_error("");
}

// Channel settings: a full-window page (the client's channel settings layer).
channel_settings_page :: () {
	ch := dc.channel_get(store(), adm.channel);
	if ch == null {
		admin_close();
		return;
	}
	interactive := adm.modal == .Channel_Settings;
	close, save, del, esc := false, false, false, false;
	dirty := settings_dirty(ch);
	page := row("chansettings", .Draw_Background | .Floating_X | .Floating_Y | .Overlay | .Clickable | .Clip);
	page.semantic_size = .[ui.px(app.ui.window.x), ui.px(app.ui.window.y)];
	page.cross_align = .Start;
	page.style.bg = T("--background-base-low");
	ui.signal(page);
	side_w := max(240.0, app.ui.window.x * 0.29);
	{ ui.parent(page); defer ui.pop_parent();
		nav := row("nav", .Draw_Background);
		nav.semantic_size = .[ui.px(side_w), ui.pct(1)];
		nav.cross_align = .Start;
		nav.style.bg = T("--background-base-lowest");
		{ ui.parent(nav); defer ui.pop_parent();
			filler(.X);
			col := ui.box("col");
			col.semantic_size = .[ui.px(238), ui.children()];
			col.layout_axis = .Y;
			{ ui.parent(col); defer ui.pop_parent();
				spacer(.Y, 60);
				hr := row("hdr");
				hr.semantic_size = .[ui.pct(1), ui.px(18)];
				{ ui.parent(hr); defer ui.pop_parent();
					spacer(.X, 10);
					label(ellipsize(ifx text_named(ch.kind) then tprint("# %", ch.name) else ch.name, .Normal, 14, 140), .Normal, 14, T("--text-muted"), 18);
					cat := dc.channel_get(store(), ch.parent_id);
					if cat != null {
						spacer(.X, 4);
						label(ellipsize(cat.name, .Bold, 12, 110), .Bold, 12, T("--text-strong"), 18);
					}
				}
				spacer(.Y, 6);
				ov := row("overview", .Draw_Background);
				ov.semantic_size = .[ui.pct(1), ui.px(32)];
				ov.style.radius = all4(6);
				ov.style.bg = T("--background-mod-normal");
				{ ui.parent(ov); defer ui.pop_parent();
					spacer(.X, 10);
					label("Overview", .Medium, 16, T("--interactive-text-active"), 20);
				}
				spacer(.Y, 12);
				hl := ui.box("div", .Draw_Background);
				hl.semantic_size = .[ui.pct(1), ui.px(1)];
				hl.style.bg = T("--border-subtle");
				spacer(.Y, 12);
				dr := row("delete", .Clickable | .Draw_Background | .Hot_Animation);
				dr.semantic_size = .[ui.pct(1), ui.px(32)];
				dr.style.radius = all4(6);
				dr.style.bg_hot = T("--background-mod-subtle");
				dr.hover_cursor = .Pointer;
				if ui.signal(dr).clicked && interactive && !adm.busy del = true;
				{ ui.parent(dr); defer ui.pop_parent();
					spacer(.X, 10);
					label(ifx ch.kind == .Guild_Category then "Delete Category" else "Delete Channel", .Medium, 16, T("--text-feedback-critical"), 20);
					filler(.X);
					icon("trash", "trash", 16, T("--text-feedback-critical"));
					spacer(.X, 10);
				}
			}
			spacer(.X, 14);
		}
		content := ui.box("content", .Scroll_Y | .Clip);
		content.semantic_size = .[ui.fill(), ui.pct(1)];
		content.layout_axis = .Y;
		ui.signal(content);
		form_w := clamp(app.ui.window.x - side_w - 40 - 140, 300, 660);
		{ ui.parent(content); defer ui.pop_parent();
			spacer(.Y, 60);
			body := row("body");
			body.semantic_size = .[ui.pct(1), ui.children()];
			body.cross_align = .Start;
			{ ui.parent(body); defer ui.pop_parent();
				spacer(.X, 40);
				col := ui.box("form");
				col.semantic_size = .[ui.px(form_w), ui.children()];
				col.layout_axis = .Y;
				{ ui.parent(col); defer ui.pop_parent();
					label("Overview", .Semibold, 20, T("--text-strong"), 24);
					spacer(.Y, 20);
					label(ifx ch.kind == .Guild_Category then "Category Name" else "Channel Name", .Semibold, 16, T("--text-strong"), 20);
					spacer(.Y, 8);
					res := set_input("name", *adm.name, ch.name, max_runes = 100);
					if res == .Changed normalize_name_field(ch.kind);
					if res == .Submit save = true;
					if res == .Escape esc = true;
					if has_topic(ch) {
						spacer(.Y, 24);
						label("Channel Topic", .Semibold, 16, T("--text-strong"), 20);
						spacer(.Y, 8);
						tw := ui.box("topicwrap");
						tw.semantic_size = .[ui.pct(1), ui.children()];
						tw.layout_axis = .Y;
						{ ui.parent(tw); defer ui.pop_parent();
							if set_input("topic", *adm.topic, "Let everyone know how to use this channel!", multiline = true, max_runes = TOPIC_MAX, min_h = 170) == .Escape esc = true;
							left := TOPIC_MAX - utf8_len(ui.editor_text(*adm.topic));
							cnt := label(tprint("%", left), .Semibold, 14, T("--text-strong"), 18);
							cnt.flags |= .Floating_X | .Floating_Y;
							cnt.fixed_pos = .{form_w - 14 - cnt.content_size.x, (tw.rect.y1 - tw.rect.y0) - 18 - 10};
						}
					}
					if has_slowmode(ch) {
						spacer(.Y, 24);
						label("Slowmode", .Semibold, 16, T("--text-strong"), 20);
						spacer(.Y, 8);
						dd := row("slowmode", .Clickable | .Draw_Background | .Draw_Border);
						dd.semantic_size = .[ui.pct(1), ui.px(40)];
						dd.style.bg = T("--input-background-default");
						dd.style.border = 1;
						dd.style.border_color = ifx adm.slow_open then T("--input-border-active") else T("--input-border-default");
						dd.style.radius = all4(8);
						dd.hover_cursor = .Pointer;
						if ui.signal(dd).clicked && interactive adm.slow_open = !adm.slow_open;
						adm.slow_anchor = dd.rect;
						{ ui.parent(dd); defer ui.pop_parent();
							spacer(.X, 12);
							label(slowmode_label(SLOWMODE_SECS[adm.slowmode]), .Normal, 16, T("--text-strong"), 20);
							filler(.X);
							icon("chev", ifx adm.slow_open then "chevron-small-up" else "chevron-small-down", 20, T("--interactive-icon-default"));
							spacer(.X, 12);
						}
						spacer(.Y, 8);
						set_para("slowhelp", "Members will be restricted to sending one message and creating one thread per this interval, unless they have the Bypass Slowmode permission.", .Normal, 12, 16, T("--text-default"));
					}
					if adm.error != "" {
						spacer(.Y, 16);
						set_para("err", adm.error, .Normal, 14, 18, T("--text-feedback-critical"));
					}
					spacer(.Y, 120);
				}
				spacer(.X, 24);
				// close: the circled X with "ESC" under it
				cc := ui.box("closecol");
				cc.semantic_size = .[ui.px(36), ui.children()];
				cc.layout_axis = .Y;
				{ ui.parent(cc); defer ui.pop_parent();
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
					if xs.clicked && interactive close = true;
					spacer(.Y, 8);
					er := row("esc");
					er.semantic_size = .[ui.pct(1), ui.px(16)];
					{ ui.parent(er); defer ui.pop_parent();
						filler(.X);
						label("ESC", .Semibold, 13, T("--text-muted"), 16);
						filler(.X);
					}
				}
			}
		}
		if dirty {
			// "Careful — you have unsaved changes!" bar at the bottom of the content
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
				if set_button("Reset##reset", .Link, !adm.busy, 32) && interactive settings_reset(ch);
				spacer(.X, 8);
				if set_button(ifx adm.busy then "Saving...##save" else "Save Changes##save", .Positive, !adm.busy, 32) && interactive save = true;
				spacer(.X, 12);
			}
		}
	}
	if adm.slow_open && interactive slowmode_list();
	if !interactive return;
	if adm.slow_open {
		if adm_escape() adm.slow_open = false;
	} else if (adm_escape() || esc) && !dirty {
		close = true; // with unsaved changes the client keeps the page (and flashes the bar)
	}
	if close {
		admin_close();
		return;
	}
	if del {
		delete_open();
		return;
	}
	if save && dirty && !adm.busy && net_action() {
		adm.busy = true;
		set_error("");
		dc.edit_channel(app.client, ch.id, settings_form(ch));
	}
}

// Runes, not bytes (the client counts characters).
utf8_len :: (s: string) -> int {
	t, n := s, 0;
	while t.count {
		utf8_next_character(*t);
		n += 1;
	}
	return n;
}

// The Slowmode select's option list (overlay under the field).
slowmode_list :: () {
	r := adm.slow_anchor;
	if r.x1 <= r.x0 return;
	if outside_pressed("slow_out") {
		adm.slow_open = false;
		return;
	}
	h := min(cast(float32)(SLOWMODE_SECS.count * 36 + 8), app.ui.window.y - r.y1 - 16);
	up := h < 180;
	if up h = min(cast(float32)(SLOWMODE_SECS.count * 36 + 8), r.y0 - 16);
	list := ui.box("slowlist", .Draw_Background | .Draw_Border | .Draw_Shadow | .Floating_X | .Floating_Y | .Overlay | .Clickable | .Scroll_Y | .Clip);
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
	{ ui.parent(list); defer ui.pop_parent();
		spacer(.Y, 4);
		for secs, i: SLOWMODE_SECS {
			ui.id_scope(cast(u64) i + 1);
			defer ui.pop_seed();
			sel := i == adm.slowmode;
			item := row("opt", .Clickable | .Draw_Background | .Hot_Animation);
			item.semantic_size = .[ui.pct(1), ui.px(36)];
			item.style.bg = ifx sel then T("--background-mod-normal") else .{};
			item.style.bg_hot = T("--background-mod-normal");
			if ui.signal(item).clicked {
				adm.slowmode = i;
				adm.slow_open = false;
			}
			{ ui.parent(item); defer ui.pop_parent();
				spacer(.X, 12);
				label(slowmode_label(secs), ifx sel then .Semibold else .Normal, 16, T("--text-strong"), 20);
			}
		}
		spacer(.Y, 4);
	}
}

delete_channel_modal :: () {
	ch := dc.channel_get(store(), adm.channel);
	if ch == null {
		// a thread gone before the reply (THREAD_DELETE first): leave it as the reply would
		if adm.from_menu && adm.busy && app.view.channel == adm.channel select_channel(adm.guild, adm.del_parent);
		admin_close();
		return;
	}
	W :: 400;
	what := ifx ch.kind == .Guild_Category then "Category" else ifx dc.is_thread(ch) then "Thread" else "Channel";
	back: Admin_Modal = ifx adm.in_settings && !adm.from_menu then .Channel_Settings else .None;
	if !adm_modal_begin("chandelete", W, tprint("Delete %", what)) {
		adm.modal = back;
		if back == .None admin_close();
		return;
	}
	confirm := false;
	spacer(.Y, 8);
	br := row("body");
	br.semantic_size = .[ui.pct(1), ui.children()];
	{ ui.parent(br); defer ui.pop_parent();
		spacer(.X, 25);
		b := ui.box("text", .Wrap_Text);
		b.semantic_size = .[ui.fill(), ui.text_size()];
		b.style.line_height = 20;
		b.style.text_color = T("--text-default");
		spans := NewArray(3, ui.Span,, temp);
		spans[0] = .{text = "Are you sure you want to delete ", font = F(.Normal), size = 16};
		spans[1] = .{text = ifx text_named(ch.kind) && !dc.is_thread(ch) then tprint("#%", ch.name) else ch.name, font = F(.Bold), size = 16};
		spans[2] = .{text = "? This cannot be undone.", font = F(.Normal), size = 16};
		ui.set_spans(b, spans);
		spacer(.X, 25);
	}
	error_line();
	spacer(.Y, 24);
	btns := row("btns");
	btns.semantic_size = .[ui.pct(1), ui.px(40)];
	btns.style.child_gap = 8;
	{ ui.parent(btns); defer ui.pop_parent();
		spacer(.X, 25 - 8);
		if wide_button("cancel", "Cancel", .Secondary) adm.modal = back;
		if wide_button("confirm", ifx adm.busy then "Deleting..." else tprint("Delete %", what), .Danger, !adm.busy) confirm = true;
		spacer(.X, 25 - 8);
	}
	spacer(.Y, 24);
	adm_modal_end();
	if adm_escape() adm.modal = back;
	if adm.modal == .None {
		admin_close();
		return;
	}
	if adm.modal != .Delete_Channel {
		set_error("");
		return;
	}
	if confirm && !adm.busy && net_action() {
		adm.busy = true;
		set_error("");
		dc.delete_channel(app.client, ch.id);
	}
}

notice_modal :: () {
	W :: 440;
	if !adm_modal_begin("notice", W, adm.notice_title) {
		admin_close();
		return;
	}
	ok := false;
	spacer(.Y, 12);
	br := row("body");
	br.semantic_size = .[ui.pct(1), ui.children()];
	{ ui.parent(br); defer ui.pop_parent();
		spacer(.X, 25);
		b := ui.box("text", .Draw_Text | .Wrap_Text);
		b.semantic_size = .[ui.fill(), ui.text_size()];
		b.text = adm.notice;
		b.style.font = F(.Normal);
		b.style.font_size = 16;
		b.style.line_height = 20;
		b.style.text_color = T("--text-subtle");
		spacer(.X, 25);
	}
	spacer(.Y, 24);
	btns := row("btns", .Draw_Background);
	btns.semantic_size = .[ui.pct(1), ui.px(70)];
	btns.style.bg = T("--background-base-lower");
	btns.style.radius = .[0, 0, 11, 11];
	{ ui.parent(btns); defer ui.pop_parent();
		filler(.X);
		if adm_button("ok", "Okay", .Primary) ok = true;
		spacer(.X, 25);
	}
	adm_modal_end();
	if adm_escape() ok = true;
	for app.ui.events if !it.consumed && it.kind == .Key_Down && it.key == .Enter ok = true;
	if ok admin_close();
}
