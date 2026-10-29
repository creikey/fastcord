// Settings > My Account (user card, display name / username edits, masked email
// and phone, Log Out) and Settings > Profiles (display name, pronouns, avatar, banner,
// banner colour, About Me with a live preview and the client's unsaved-changes bar). Requests go out
// through dc.update_* and come back in account_receive (features_receive).

#scope_file
Acct_Edit :: enum u8 {
	None;
	Display_Name;
	Username;
}

acct: struct {
	editing: Acct_Edit;
	name_ed: ui.Editor;
	user_ed: ui.Editor;
	pass_ed: ui.Editor;
	reveal_email: bool;
	reveal_phone: bool;
	pending: bool;
	error: string; // heap
	logout_confirm: bool;
	// Profiles
	pf_name: ui.Editor;
	pf_pronouns: ui.Editor;
	pf_bio: ui.Editor;
	base_name: string; // heap: the saved values the editors started from
	base_pronouns: string;
	base_bio: string;
	pf_accent: s64 = dc.ACCENT_UNCHANGED; // Banner Color picked and not saved yet (-1: back to the default)
	pf_hex: ui.Editor; // its "#rrggbb" field
	pf_pending: int;
	pf_error: string; // heap
};
#scope_export

PROFILE_NAME_MAX :: 32;
PROFILE_PRONOUNS_MAX :: 40;
PROFILE_BIO_MAX :: 190;

account_reset_for_test :: () {
	for e: (*ui.Editor.[*acct.name_ed, *acct.user_ed, *acct.pass_ed, *acct.pf_name, *acct.pf_pronouns, *acct.pf_bio, *acct.pf_hex]) { ui.editor_set_text(e, ""); }
	acct.pf_accent = dc.ACCENT_UNCHANGED;
	for (*string).[*acct.error, *acct.pf_error, *acct.base_name, *acct.base_pronouns, *acct.base_bio] { free(it.*); it.* = ""; }
	acct.editing = .None;
	acct.reveal_email, acct.reveal_phone, acct.pending, acct.logout_confirm = false, false, false, false;
	acct.pf_pending = 0;
}

// Results of dc.update_global_name / update_username / update_profile (UI thread).
account_receive :: (r: *dc.Feature_Result) {
	if app.client == null { return; }
	err := "";
	if !r.ok {
		err = dc.api_error_text(r.body);
		if err == "" { err = ifx r.status == 0 then "Couldn't reach Discord. Try again." else tprint("Something went wrong (HTTP %).", r.status); }
	}
	tok := dc.apply_account_result(*app.client.store, r);
	if tok != "" && !platform.is_headless() {
		// a username change rotates the token: keep the new one for the next start
		dc.write_file_atomic(tprint("%/token", app_state_dir()), cast([]u8) tok);
	}
	if r.op == .Banner_Edit {
		if r.status == -1 err = "That file couldn't be read. Banners must be PNG, JPEG, GIF or WEBP images.";
		if r.status == -2 err = "That image is too large. Banners must be under 10 MB.";
		set_error(*acct.pf_error, err);
	} else if r.op == .Profile_Patch || r.tag == cast(u64)(dc.User_Patch_Tag.Profile_Name) {
		acct.pf_pending = max(acct.pf_pending - 1, 0);
		if r.op == .Profile_Patch && r.ok acct.pf_accent = dc.ACCENT_UNCHANGED;
		set_error(*acct.pf_error, err);
	} else {
		acct.pending = false;
		set_error(*acct.error, err);
		if r.ok { acct_edit_close(); }
	}
	app.ui.animating = true;
}

// ---- Log Out ----

account_logout_ask :: () {acct.logout_confirm = true;}

// Log Out (AuthenticationActionCreators.logout("settings")): POST /auth/logout
// revokes the session; the same client then shows the login page (auth.jai).
account_logout :: () {
	acct.logout_confirm = false;
	voice_leave_channel();
	if net_action() { dc.client_logout(app.client, "settings"); }
	if !platform.is_headless() && env_var("FASTCORD_TOKEN") == "" {
		file_delete(tprint("%/token", app_state_dir()));
	}
	login_reset();
	app.settings_open = false;
	app.profile_user = 0;
	app.login_error = "";
	app.view.guild, app.view.channel = 0, 0;
	app.ui.focus = 0;
	app.needs_login = true;
}

// Confirmation over the settings modal (overlay pass).
account_logout_modal :: () {
	if !acct.logout_confirm || !app.settings_open {
		acct.logout_confirm = false;
		return;
	}
	scrim := ui.box("logout_scrim", .Draw_Background | .Clickable | .Floating_X | .Floating_Y | .Overlay);
	scrim.semantic_size = .[ui.px(app.ui.window.x), ui.px(app.ui.window.y)];
	scrim.style.bg = .{0, 0, 0, 0.5};
	if ui.signal(scrim).clicked {
		acct.logout_confirm = false;
		return;
	}
	W :: 440;
	d := ui.box("logout", .Draw_Background | .Draw_Border | .Floating_X | .Floating_Y | .Overlay | .Clickable);
	d.semantic_size = .[ui.px(W), ui.children()];
	d.fixed_pos = .{(app.ui.window.x - W) / 2, (app.ui.window.y - (d.rect.y1 - d.rect.y0)) / 2};
	d.style.bg = T("--modal-background");
	d.style.border_color = T("--border-subtle");
	d.style.border = 1;
	d.style.radius = all4(12);
	d.layout_axis = .Y;
	ui.signal(d);
	{ ui.parent(d); defer ui.pop_parent();
		inset_begin(24, 24);
		label("Log Out", .Semibold, 20, T("--text-strong"), 24);
		spacer(.Y, 8);
		set_para("q", "Are you sure you want to logout?", .Normal, 16, 20, T("--text-subtle"));
		spacer(.Y, 24);
		btns := row("btns");
		btns.semantic_size = .[ui.pct(1), ui.px(38)];
		{ ui.parent(btns); defer ui.pop_parent();
			filler(.X);
			if set_button("Cancel##cancel", .Secondary) { acct.logout_confirm = false; }
			spacer(.X, 8);
			if set_button("Log Out##confirm", .Danger) { account_logout(); }
		}
		inset_end(24, 24);
	}
	for * e: app.ui.events {
		if !e.consumed && e.kind == .Key_Down && e.key == .Escape {
			acct.logout_confirm = false;
			e.consumed = true;
		}
	}
}

// ---- My Account ----

// "*****@domain" (the client's masked email).
mask_email :: (email: string) -> string {
	at := find_index_from_right(email, #char "@");
	if at < 0 { return "*****"; }
	return tprint("*****%", string.{email.count - at, email.data + at});
}

// "*******1234": all but the last four digits hidden.
mask_phone :: (phone: string) -> string {
	if phone.count <= 4 { return "****"; }
	s := copy_string(phone,, temp);
	memset(s.data, #char "*", s.count - 4);
	return s;
}

my_account_page :: () {
	if streamer_settings.enabled {
		streamer_account_page(); // view_streamer.jai
		return;
	}
	s := store();
	u := dc.user_get(s, s.me);
	if !set_page_begin("accountpage") { return; }
	defer set_page_end();
	set_heading("My Account");
	card := ui.box("card", .Draw_Background | .Clip);
	card.semantic_size = .[ui.pct(1), ui.children()];
	card.layout_axis = .Y;
	card.style.bg = T("--background-base-lowest");
	card.style.radius = all4(8);
	{ ui.parent(card); defer ui.pop_parent();
		banner := ui.box("banner", .Draw_Background);
		banner.semantic_size = .[ui.pct(1), ui.px(100)];
		banner.style.bg = profile_banner_color(s.me);
		if u != null && u.banner != "" { set_remote_image(banner, dc.banner_url(s.me, u.banner, 600)); }
		head := row("head");
		head.semantic_size = .[ui.pct(1), ui.px(72)];
		{ ui.parent(head); defer ui.pop_parent();
			ring := ui.box("ring", .Draw_Background | .Floating_X | .Floating_Y);
			ring.semantic_size = .[ui.px(94), ui.px(94)];
			ring.fixed_pos = .{16, -46};
			ring.style.radius = all4(47);
			ring.style.bg = card.style.bg;
			{ ui.parent(ring); defer ui.pop_parent();
				av := avatar_with_status("av", s.me, 80, card.style.bg);
				av.flags |= .Floating_X | .Floating_Y;
				av.fixed_pos = .{7, 7};
			}
			spacer(.X, 126);
			name := ifx u != null then dc.display_name(u) else "…";
			label(name, .Semibold, 20, T("--text-strong"), 24);
			filler(.X);
			if set_button("Edit User Profile##editprofile", .Primary, true, 32) { settings_page = "Profiles"; }
			spacer(.X, 16);
		}
		panel_row := row("panelrow");
		panel_row.semantic_size = .[ui.pct(1), ui.children()];
		{ ui.parent(panel_row); defer ui.pop_parent();
			spacer(.X, 16);
			panel := ui.box("panel", .Draw_Background);
			panel.semantic_size = .[ui.fill(), ui.children()];
			panel.layout_axis = .Y;
			panel.style.bg = T("--background-base-low");
			panel.style.radius = all4(8);
			{ ui.parent(panel); defer ui.pop_parent();
				inset_begin(16, 16);
				display := ifx u != null && u.global_name != "" then u.global_name else "You haven't added a display name yet.";
				account_field("dname", "Display Name", display, .Display_Name);
				spacer(.Y, 24);
				account_field("uname", "Username", ifx u != null then u.username else "", .Username);
				spacer(.Y, 24);
				email := dc.account.email;
				// Streamer Mode > Hide Personal Information: masked, with no Reveal
				hide := streamer_hide_personal();
				shown := ifx email == "" then "You haven't added an email yet." else (ifx acct.reveal_email && !hide then email else mask_email(email));
				account_secret("email", "Email", shown, email != "" && !hide, *acct.reveal_email);
				spacer(.Y, 24);
				phone := dc.account.phone;
				pshown := ifx phone == "" then "You haven't added a phone number yet." else (ifx acct.reveal_phone && !hide then phone else mask_phone(phone));
				account_secret("phone", "Phone Number", pshown, phone != "" && !hide, *acct.reveal_phone);
				inset_end(16, 16);
			}
			spacer(.X, 16);
		}
		spacer(.Y, 16);
	}
	spacer(.Y, 40);
	set_heading("Password and Authentication");
	mfa := ifx dc.account.mfa_enabled then "Two-factor authentication is enabled on this account." else "Two-factor authentication is not enabled on this account.";
	set_para("mfa", mfa, .Normal, 14, 18, T("--text-muted"));
	spacer(.Y, 8);
	set_para("pwnote", "Change your password, email and two-factor settings in the official client or at discord.com.", .Normal, 14, 18, T("--text-muted"));
}
#scope_file

// LABEL / value with an Edit button, or the inline editor while editing.
account_field :: (id: string, title: string, value: string, which: Acct_Edit) {
	r := ui.box(id);
	r.semantic_size = .[ui.pct(1), ui.children()];
	r.layout_axis = .Y;
	ui.push_parent(r);
	defer ui.pop_parent();
	label(to_upper_copy(title,, temp), .Bold, 12, T("--text-muted"), 16);
	spacer(.Y, 4);
	if acct.editing != which {
		vr := row("vrow");
		vr.semantic_size = .[ui.pct(1), ui.px(32)];
		{ ui.parent(vr); defer ui.pop_parent();
			label(value, .Normal, 16, T("--text-default"), 20);
			filler(.X);
			if set_button("Edit##edit", .Secondary, true, 32) { acct_edit_open(which); }
		}
		return;
	}
	spacer(.Y, 4);
	res: ui.Edit_Result;
	enabled := false;
	if which == {
	case .Display_Name;
		res = set_input("in", *acct.name_ed, "Display name", max_runes = PROFILE_NAME_MAX);
		enabled = true; // empty clears it (the username shows instead)
	case .Username;
		res = set_input("in", *acct.user_ed, "Username", max_runes = 32);
		uname := trim(ui.editor_text(*acct.user_ed));
		// availability as you type (debounced in the library: POST pomelo-attempt)
		if res == .Changed && app.client != null { dc.username_input_changed(app.client, uname); }
		msg, col := username_status(uname);
		if msg != "" {
			spacer(.Y, 6);
			set_para("avail", msg, .Normal, 14, 18, col);
		}
		spacer(.Y, 12);
		label("CURRENT PASSWORD", .Bold, 12, T("--text-muted"), 16);
		spacer(.Y, 8);
		pres := set_input("pw", *acct.pass_ed, "Password", password = true);
		if pres == .Submit { res = .Submit; }
		enabled = uname != "" && ui.editor_text(*acct.pass_ed) != "";
	case .None;
	}
	if acct.error != "" {
		spacer(.Y, 8);
		set_para("err", acct.error, .Normal, 14, 18, T("--text-feedback-critical"));
	}
	spacer(.Y, 12);
	br := row("btns");
	br.semantic_size = .[ui.pct(1), ui.px(32)];
	{ ui.parent(br); defer ui.pop_parent();
		filler(.X);
		if set_button("Cancel##cancel", .Link, true, 32) || res == .Escape { acct_edit_close(); }
		spacer(.X, 8);
		enabled = enabled && !acct.pending;
		if (set_button(ifx acct.pending then "Saving…##save" else "Done##save", .Primary, enabled, 32) || res == .Submit && enabled) && net_action() {
			acct.pending = true;
			if which == .Display_Name {
				dc.update_global_name(app.client, trim(ui.editor_text(*acct.name_ed)));
			} else {
				dc.update_username(app.client, trim(ui.editor_text(*acct.user_ed)), ui.editor_text(*acct.pass_ed));
			}
		}
	}
}

acct_edit_open :: (which: Acct_Edit) {
	s := store();
	u := dc.user_get(s, s.me);
	acct.editing = which;
	set_error(*acct.error, "");
	ui.editor_set_text(*acct.pass_ed, "");
	if which == .Display_Name { ui.editor_set_text(*acct.name_ed, ifx u != null then u.global_name else ""); }
	if which == .Username {
		ui.editor_set_text(*acct.user_ed, ifx u != null then u.username else "");
		if app.client != null {
			dc.analytics_ui_setting(app.client, "account_info_username_setting");
			dc.username_input_changed(app.client, ifx u != null then u.username else ""); // the prefilled value is checked too
		}
	}
}

// username_status: the line under the username field (none for the current name).
username_status :: (name: string) -> string, ui.Color {
	s := store();
	u := dc.user_get(s, s.me);
	if app.client == null || name == "" || (u != null && name == u.username) { return "", .{}; }
	chk := dc.username_check(app.client, name);
	if chk.state == {
	case .Available;
		return "Username is available. Nice!", T("--text-feedback-positive");
	case .Taken;
		return "Username is unavailable. Try adding numbers, letters, underscores _ , or periods.", T("--text-feedback-critical");
	case .Error;
		return chk.message, T("--text-feedback-critical");
	case .Rate_Limited;
		return "Too fast! Wait a bit and try again.", T("--text-feedback-critical");
	case .Unknown;
	}
	return "", .{};
}

// LABEL / masked value with Reveal / Hide.
account_secret :: (id: string, title: string, shown: string, has: bool, reveal: *bool) {
	r := ui.box(id);
	r.semantic_size = .[ui.pct(1), ui.children()];
	r.layout_axis = .Y;
	ui.push_parent(r);
	defer ui.pop_parent();
	label(to_upper_copy(title,, temp), .Bold, 12, T("--text-muted"), 16);
	spacer(.Y, 4);
	vr := row("vrow");
	vr.semantic_size = .[ui.pct(1), ui.px(24)];
	{ ui.parent(vr); defer ui.pop_parent();
		label(shown, .Normal, 16, T("--text-default"), 20);
		if has {
			spacer(.X, 4);
			l := ui.box(ifx reveal.* then "Hide##reveal" else "Reveal##reveal", .Clickable | .Draw_Text);
			l.semantic_size = .[ui.text_size(0), ui.px(20)];
			l.style.font = F(.Normal);
			l.style.font_size = 14;
			l.style.text_color = T("--text-link");
			l.hover_cursor = .Pointer;
			if ui.signal(l).clicked { reveal.* = !reveal.*; }
		}
	}
}

// ---- Profiles ----

// Editors follow the saved values until the user changes them.
pf_follow :: (ed: *ui.Editor, base: *string, cur: string) {
	if base.* == cur { return; }
	if ui.editor_text(ed) == base.* { ui.editor_set_text(ed, cur); }
	free(base.*);
	base.* = copy_string(cur);
}

pf_dirty :: () -> bool {
	return ui.editor_text(*acct.pf_name) != acct.base_name || ui.editor_text(*acct.pf_pronouns) != acct.base_pronouns || ui.editor_text(*acct.pf_bio) != acct.base_bio || acct.pf_accent != dc.ACCENT_UNCHANGED;
}

// The banner colour the preview shows: the picked one, else the saved one (or the avatar's).
pf_banner_color :: () -> ui.Color {
	if acct.pf_accent >= 0 return rgb_u32(cast(u32) acct.pf_accent);
	if acct.pf_accent == -1 return profile_banner_color_default();
	return profile_banner_color(store().me);
}

// Change / Remove buttons for the avatar or banner image (sent at once, like the client's upload).
pf_image_row :: (id: string, what: string, has: bool, change: (path: string)) {
	r := row(id);
	r.semantic_size = .[ui.pct(1), ui.px(32)];
	ui.parent(r); defer ui.pop_parent();
	if set_button(tprint("Change %##change", what), .Primary, true, 32) {
		paths := pick_files();
		if paths.count && net_action() change(paths[0]);
	}
	if has {
		spacer(.X, 8);
		if set_button(tprint("Remove %##remove", what), .Link, true, 32) && net_action() change("");
	}
}

// Banner Color: the avatar's colour (Default), the role palette, or any "#rrggbb".
pf_color_picker :: (u: *dc.User) {
	cur := ifx acct.pf_accent != dc.ACCENT_UNCHANGED then acct.pf_accent else ifx u != null && u.has_accent_color then cast(s64) u.accent_color else -1;
	grid := row("bannercolors");
	grid.semantic_size = .[ui.pct(1), ui.children()];
	grid.cross_align = .Start;
	ui.parent(grid); defer ui.pop_parent();
	pick := ACCENT_NONE;
	def := ui.box("def", .Clickable | .Draw_Background | .Draw_Border);
	def.semantic_size = .[ui.px(66), ui.px(50)];
	def.style.radius = all4(4);
	def.style.bg = profile_banner_color_default();
	def.style.border = ifx cur == -1 then 3.0 else 0;
	def.style.border_color = T("--text-strong");
	def.hover_cursor = .Pointer;
	if ui.signal(def).clicked pick = -1;
	spacer(.X, 12);
	col := ui.box("sw");
	col.semantic_size = .[ui.children(), ui.children()];
	col.layout_axis = .Y;
	{ ui.parent(col); defer ui.pop_parent();
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
				sw.style.bg = rgb_u32(c);
				sw.style.border = ifx cur == c then 2.0 else 0;
				sw.style.border_color = T("--text-strong");
				sw.hover_cursor = .Pointer;
				if ui.signal(sw).clicked pick = c;
			}
		}
	}
	spacer(.X, 16);
	hx := ui.box("hex");
	hx.semantic_size = .[ui.px(120), ui.children()];
	{ ui.parent(hx); defer ui.pop_parent();
		res := set_input("hexin", *acct.pf_hex, ifx cur >= 0 then tprint("#%", formatInt(cur, base = 16, minimum_digits = 6)) else "#rrggbb", max_runes = 7);
		if res == .Changed || res == .Submit {
			t := trim(ui.editor_text(*acct.pf_hex));
			if begins_with(t, "#") advance(*t);
			v, ok, rest := string_to_int(t, 16, s64);
			if ok && t.count == 6 && rest.count == 0 pick = v;
		}
	}
	if pick == ACCENT_NONE return;
	saved := ifx u != null && u.has_accent_color then cast(s64) u.accent_color else -1;
	acct.pf_accent = ifx pick == saved then dc.ACCENT_UNCHANGED else pick;
}
ACCENT_NONE :: -3; // nothing picked this frame

// The banner's colour with no Banner Color set: the avatar's dominant colour.
profile_banner_color_default :: () -> ui.Color {
	im := image_get(avatar_url_for(store().me, 80));
	if im != null && im.state == .Ready && im.dominant.w > 0 return im.dominant;
	return T("--background-brand");
}
#scope_export

profiles_page :: () {
	s := store();
	u := dc.user_get(s, s.me);
	if u != null {
		pf_follow(*acct.pf_name, *acct.base_name, u.global_name);
		pf_follow(*acct.pf_pronouns, *acct.base_pronouns, u.pronouns);
		pf_follow(*acct.pf_bio, *acct.base_bio, u.bio);
	}
	wrap := ui.box("profileswrap");
	wrap.semantic_size = .[ui.pct(1), ui.fill()];
	wrap.layout_axis = .Y;
	ui.push_parent(wrap);
	defer ui.pop_parent();
	if set_page_begin("profilespage") {
		set_heading("Profiles");
		cols := row("cols");
		cols.semantic_size = .[ui.pct(1), ui.children()];
		cols.cross_align = .Start;
		{ ui.parent(cols); defer ui.pop_parent();
			form := ui.box("form");
			form.semantic_size = .[ui.fill(), ui.children()];
			form.layout_axis = .Y;
			{ ui.parent(form); defer ui.pop_parent();
				label("Display Name", .Semibold, 16, T("--text-strong"), 20);
				spacer(.Y, 8);
				set_input("name", *acct.pf_name, ifx u != null then u.username else "", max_runes = PROFILE_NAME_MAX);
				set_divider();
				label("Pronouns", .Semibold, 16, T("--text-strong"), 20);
				spacer(.Y, 8);
				set_input("pronouns", *acct.pf_pronouns, "Add your pronouns", max_runes = PROFILE_PRONOUNS_MAX);
				set_divider();
				label("Avatar", .Semibold, 16, T("--text-strong"), 20);
				spacer(.Y, 8);
				pf_image_row("avatar", "Avatar", u != null && u.avatar != "", (path: string) { dc.edit_my_avatar(app.client, path); });
				set_divider();
				if u != null && u.premium_type == 2 { // a custom banner is Nitro's: hidden otherwise, never offered
					label("Profile Banner", .Semibold, 16, T("--text-strong"), 20);
					spacer(.Y, 8);
					pf_image_row("banner", "Banner", u.banner != "", (path: string) { dc.edit_my_banner(app.client, path); });
					set_divider();
				}
				label("Banner Color", .Semibold, 16, T("--text-strong"), 20);
				spacer(.Y, 8);
				pf_color_picker(u);
				set_divider();
				label("About Me", .Semibold, 16, T("--text-strong"), 20);
				spacer(.Y, 4);
				set_para("biohelp", "You can use markdown and links if you'd like.", .Normal, 14, 18, T("--text-muted"));
				spacer(.Y, 8);
				set_input("bio", *acct.pf_bio, "", multiline = true, max_runes = PROFILE_BIO_MAX, min_h = 100);
				spacer(.Y, 4);
				cr := row("count");
				cr.semantic_size = .[ui.pct(1), ui.px(16)];
				{ ui.parent(cr); defer ui.pop_parent();
					filler(.X);
					left := PROFILE_BIO_MAX;
					for ui.editor_text(*acct.pf_bio) if (it & 0xC0) != 0x80 left -= 1; // runes
					label(tprint("%", left), .Normal, 12, T("--text-muted"), 16);
				}
				if acct.pf_error != "" {
					spacer(.Y, 8);
					set_para("err", acct.pf_error, .Normal, 14, 18, T("--text-feedback-critical"));
				}
			}
			spacer(.X, 24);
			pv := ui.box("previewcol");
			pv.semantic_size = .[ui.px(260), ui.children()];
			pv.layout_axis = .Y;
			{ ui.parent(pv); defer ui.pop_parent();
				label("PREVIEW", .Bold, 12, T("--text-muted"), 16);
				spacer(.Y, 8);
				profile_preview_card(u);
			}
		}
		set_page_end();
	}
	if pf_dirty() || acct.pf_pending > 0 { profile_save_bar(); }
}
#scope_file

profile_preview_card :: (u: *dc.User) {
	s := store();
	W :: 260;
	card := ui.box("preview", .Draw_Background | .Draw_Border | .Clip);
	card.semantic_size = .[ui.px(W), ui.children()];
	card.layout_axis = .Y;
	card.style.bg = T("--background-surface-high");
	card.style.border_color = T("--border-subtle");
	card.style.border = 1;
	card.style.radius = all4(8);
	ui.push_parent(card);
	defer ui.pop_parent();
	banner := ui.box("banner", .Draw_Background);
	banner.semantic_size = .[ui.pct(1), ui.px(90)];
	banner.style.bg = pf_banner_color();
	if u != null && u.banner != "" { set_remote_image(banner, dc.banner_url(s.me, u.banner, 600)); }
	avr := ui.box("avrow");
	avr.semantic_size = .[ui.pct(1), ui.px(40)];
	{ ui.parent(avr); defer ui.pop_parent();
		ring := ui.box("ring", .Draw_Background | .Floating_X | .Floating_Y);
		ring.semantic_size = .[ui.px(80), ui.px(80)];
		ring.fixed_pos = .{10, -40};
		ring.style.radius = all4(40);
		ring.style.bg = card.style.bg;
		{ ui.parent(ring); defer ui.pop_parent();
			av := avatar_with_status("av", s.me, 68, card.style.bg);
			av.flags |= .Floating_X | .Floating_Y;
			av.fixed_pos = .{6, 6};
		}
	}
	inset_begin(16, 0);
	name := trim(ui.editor_text(*acct.pf_name));
	if name == "" && u != null { name = u.username; }
	label(tprint("%##pvname", name), .Bold, 20, T("--text-strong"), 24);
	sub := ifx u != null then u.username else "";
	p := trim(ui.editor_text(*acct.pf_pronouns));
	if p != "" { sub = tprint("% • %", sub, p); }
	label(tprint("%##pvsub", sub), .Normal, 14, T("--text-default"), 18);
	bio := ui.editor_text(*acct.pf_bio);
	if bio != "" {
		spacer(.Y, 12);
		b := ui.box("pvbio", .Wrap_Text);
		b.semantic_size = .[ui.pct(1), ui.text_size()];
		b.style.line_height = 18;
		b.style.text_color = T("--text-default");
		blocks := md_parse(bio);
		if blocks.count > 0 { ui.set_spans(b, tokens_to_spans(blocks[0].tokens, .Normal, 14, null)); }
	}
	inset_end(16, 16);
}

// "Careful — you have unsaved changes!" with Reset / Save Changes, floating at the bottom.
profile_save_bar :: () {
	W :: 600;
	cw := app.ui.window.x - 2 * SET_INSET - SET_NAV_W - 1;
	ch := app.ui.window.y - 2 * SET_INSET - SET_TITLE_H - 1;
	w := min(cast(float32)(W), cw - 32);
	bar := row("savebar", .Draw_Background | .Draw_Shadow | .Floating_X | .Floating_Y);
	bar.semantic_size = .[ui.px(w), ui.px(52)];
	bar.fixed_pos = .{(cw - w) / 2, ch - 52 - 20};
	bar.style.bg = T("--background-surface-highest");
	bar.style.radius = all4(8);
	bar.style.shadow_color = .{0, 0, 0, 0.3};
	bar.style.shadow_blur = 12;
	bar.style.shadow_offset = .{0, 4};
	ui.push_parent(bar);
	defer ui.pop_parent();
	spacer(.X, 16);
	label("Careful — you have unsaved changes!", .Medium, 15, T("--text-strong"), 20);
	filler(.X);
	busy := acct.pf_pending > 0;
	if set_button("Reset##reset", .Link, !busy, 32) {
		ui.editor_set_text(*acct.pf_name, acct.base_name);
		ui.editor_set_text(*acct.pf_pronouns, acct.base_pronouns);
		ui.editor_set_text(*acct.pf_bio, acct.base_bio);
		ui.editor_set_text(*acct.pf_hex, "");
		acct.pf_accent = dc.ACCENT_UNCHANGED;
		set_error(*acct.pf_error, "");
	}
	spacer(.X, 8);
	if set_button(ifx busy then "Saving…##save" else "Save Changes##save", .Positive, !busy, 32) && net_action() {
		set_error(*acct.pf_error, "");
		name := trim(ui.editor_text(*acct.pf_name));
		if name != acct.base_name {
			dc.update_global_name(app.client, name, .Profile_Name);
			acct.pf_pending += 1;
		}
		if ui.editor_text(*acct.pf_pronouns) != acct.base_pronouns || ui.editor_text(*acct.pf_bio) != acct.base_bio || acct.pf_accent != dc.ACCENT_UNCHANGED {
			dc.update_profile(app.client, ui.editor_text(*acct.pf_pronouns), ui.editor_text(*acct.pf_bio), acct.pf_accent);
			acct.pf_pending += 1;
		}
	}
	spacer(.X, 12);
}


set_error :: (dst: *string, s: string) {
	free(dst.*);
	dst.* = copy_string(s);
}

acct_edit_close :: () {
	acct.editing = .None;
	ui.editor_set_text(*acct.pass_ed, "");
	set_error(*acct.error, "");
}

// ---- Multi-Factor Authentication (openMFAModal) ----
// A request answered MFA_REQUIRED waits in the feature worker; this modal asks for a code or the
// password, POST /mfa/finish turns it into a token, and the request goes again (dc.mfa_retry). Cancel
// hands the 401 to the request's own handler, which shows its error. SMS and security keys aren't offered.

#scope_file
mfa: struct {
	open: bool;
	ticket: string; // heap
	methods: [..]string; // heap: "totp", "backup", "password" in the order offered
	method: int;
	code: ui.Editor;
	busy: bool;
	error: string; // heap
	held: dc.Feature_Result; // the 401, routed to its handler on Cancel
};

mfa_close :: (cancelled: bool) {
	held := mfa.held;
	mfa.held = .{};
	mfa.open, mfa.busy = false, false;
	free(mfa.ticket);
	mfa.ticket = "";
	for mfa.methods free(it);
	array_reset(*mfa.methods);
	ui.editor_set_text(*mfa.code, "");
	set_error(*mfa.error, "");
	if cancelled && held.arena feature_route(*held);
	dc.feature_result_free(*held);
}
#scope_export

// mfa_open: r asks for a multi-factor check; true when the modal took it (it keeps r's body).
mfa_open :: (r: *dc.Feature_Result) -> bool {
	m := dc.fmap(dc.vmap(r.body), "mfa");
	methods: [..]string;
	methods.allocator = temp;
	for dc.flist(m, "methods") {
		t := dc.fstr(dc.vmap(it), "type");
		if t == "totp" || t == "password" array_add(*methods, t);
		if t == "totp" && dc.fbool(dc.vmap(it), "backup_codes_allowed") array_add(*methods, "backup");
	}
	if !methods.count return false;
	if mfa.open mfa_close(true);
	mfa.open = true;
	mfa.ticket = copy_string(dc.fstr(m, "ticket"));
	for methods array_add(*mfa.methods, copy_string(it));
	mfa.method = 0;
	mfa.held = r.*;
	r.arena = null; // ours now
	app.ui.focus = 0;
	return true;
}

mfa_is_open :: () -> bool { return mfa.open; }

// Script command `mfa_challenge`: a change answered MFA_REQUIRED (tests).
mfa_script_challenge :: () {
	arena := New(Flat_Pool,, context.default_allocator);
	body := etf.from_json("{\"code\":60003,\"message\":\"Two factor is required for this operation\",\"mfa\":{\"ticket\":\"t\",\"methods\":[{\"type\":\"totp\",\"backup_codes_allowed\":true},{\"type\":\"password\"}]}}",, dc.pool_allocator(arena));
	r := dc.Feature_Result.{op = .User_Settings, tag = xx US_Req.Action, status = 401, body = body, arena = arena};
	if !mfa_open(*r) dc.feature_result_free(*r);
}

// Result of dc.mfa_finish: the token sends the waiting request again.
mfa_receive :: (r: *dc.Feature_Result) {
	if !mfa.open return;
	mfa.busy = false;
	app.ui.animating = true;
	tok := dc.fstr(dc.vmap(r.body), "token");
	if !r.ok || tok == "" {
		e := dc.api_error_text(r.body);
		set_error(*mfa.error, ifx e then e else "An error occurred. Please try again.");
		return;
	}
	if app.client != null dc.mfa_retry(app.client, tok);
	mfa_close(false);
}

mfa_modal :: () {
	if !mfa.open return;
	W :: 440;
	if !adm_modal_begin("mfa", W, "Multi-Factor Authentication", "This extra step shows it's really you.") {
		mfa_close(true);
		return;
	}
	kind := mfa.methods[mfa.method];
	submit := false;
	body := row("body");
	body.semantic_size = .[ui.pct(1), ui.children()];
	{ ui.parent(body); defer ui.pop_parent();
		spacer(.X, 25);
		col := ui.box("col");
		col.semantic_size = .[ui.fill(), ui.children()];
		col.layout_axis = .Y;
		{ ui.parent(col); defer ui.pop_parent();
			spacer(.Y, 16);
			title, hint := "Enter Discord Auth Code", "6-digit authentication code";
			if kind == "backup" title, hint = "Enter Discord Backup Code", "8-digit backup code";
			if kind == "password" title, hint = "Password", "";
			label(to_upper_copy(title,, temp), .Bold, 12, T("--text-muted"), 16);
			spacer(.Y, 8);
			res := set_input(tprint("code_%", kind), *mfa.code, hint, password = kind == "password", max_runes = ifx kind == "password" then 0 else 11, autofocus = true);
			if res == .Submit submit = true;
			if mfa.error {
				spacer(.Y, 8);
				set_para("err", mfa.error, .Normal, 14, 18, T("--text-feedback-critical"));
			}
			if mfa.methods.count > 1 {
				spacer(.Y, 12);
				l := label("Verify with something else", .Medium, 14, T("--text-link"), 18);
				l.flags |= .Clickable;
				l.hover_cursor = .Pointer;
				if ui.signal(l).clicked {
					mfa.method = (mfa.method + 1) % mfa.methods.count;
					ui.editor_set_text(*mfa.code, "");
					set_error(*mfa.error, "");
				}
			}
		}
		spacer(.X, 25);
	}
	spacer(.Y, 24);
	btns := row("btns");
	btns.semantic_size = .[ui.pct(1), ui.px(40)];
	btns.style.child_gap = 8;
	cancel := false;
	{ ui.parent(btns); defer ui.pop_parent();
		spacer(.X, 25 - 8);
		if wide_button("cancel", "Cancel", .Secondary) cancel = true;
		if wide_button("confirm", ifx mfa.busy then "Confirming..." else "Confirm", .Primary, !mfa.busy && trim(ui.editor_text(*mfa.code)) != "") submit = true;
		spacer(.X, 25 - 8);
	}
	spacer(.Y, 24);
	adm_modal_end();
	if adm_escape() cancel = true;
	if cancel {
		mfa_close(true);
		return;
	}
	data := trim(ui.editor_text(*mfa.code));
	if submit && data != "" && !mfa.busy && net_action() {
		mfa.busy = true;
		set_error(*mfa.error, "");
		code := ifx kind == "password" then data else replace(data, " ", "",, temp);
		if kind == "backup" code = replace(code, "-", "",, temp);
		dc.mfa_finish(app.client, mfa.ticket, kind, code);
	}
}
