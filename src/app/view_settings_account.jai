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

// The My Account modals (Change Password, Enable Authenticator App, Disable / Delete Account).
Acct_Modal :: enum u8 { None; Password; Totp; Disable; Delete; }

acct: struct {
	editing: Acct_Edit;
	modal: Acct_Modal;
	new_pass: ui.Editor; // Change Password: new and confirm; Enable Authenticator App: the code
	confirm_pass: ui.Editor;
	totp_secret: string; // heap
	backup_codes: [..]string; // heap: shown once after enabling 2FA
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
	// Per-server Profiles: the server picked and its form
	ps_tab: bool;
	ps_guild: dc.Snowflake;
	ps_nick: ui.Editor;
	ps_bio: ui.Editor;
	ps_pronouns: ui.Editor;
	ps_base: [3]string; // heap: the values the editors started from (nick, bio, pronouns)
};
#scope_export

PROFILE_NAME_MAX :: 32;
PROFILE_PRONOUNS_MAX :: 40;
PROFILE_BIO_MAX :: 190;

account_reset_for_test :: () {
	for e: (*ui.Editor.[*acct.name_ed, *acct.user_ed, *acct.pass_ed, *acct.pf_name, *acct.pf_pronouns, *acct.pf_bio, *acct.pf_hex, *acct.new_pass, *acct.confirm_pass]) { ui.editor_set_text(e, ""); }
	acct.modal = .None;
	for acct.backup_codes free(it);
	array_reset(*acct.backup_codes);
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
		if err == "" { err = ifx r.status == 0 then L("Couldn't reach Discord. Try again.") else tprint(L("Something went wrong (HTTP %)."), r.status); }
	}
	tok := dc.apply_account_result(*app.client.store, r);
	if tok != "" {
		// username, password and 2FA changes rotate the token: use it now and keep it for the next start
		dc.client_set_token(app.client, tok);
		if app.client == app.discord accounts_set_token(tok);
	}
	tag := cast(dc.User_Patch_Tag) r.tag;
	if r.op == .User_Patch && tag >= .Password {
		acct.pending = false;
		set_error(*acct.error, err);
		if !r.ok return;
		if tag == .Totp_Enable {
			for acct.backup_codes free(it);
			array_reset(*acct.backup_codes);
			for dc.flist(dc.vmap(r.body), "backup_codes") array_add(*acct.backup_codes, copy_string(dc.fstr(dc.vmap(it), "code")));
		}
		acct_modal_close();
		if tag == .Disable_Account || tag == .Delete_Account account_logout(); // logoutInternal
		app.ui.animating = true;
		return;
	}
	if r.op == .Banner_Edit {
		if r.status == -1 err = L("That file couldn't be read. Banners must be PNG, JPEG, GIF or WEBP images.");
		if r.status == -2 err = L("That image is too large. Banners must be under 10 MB.");
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
// Only the active account is forgotten; the other saved ones stay (accounts.jai).
account_logout :: (source := "settings") {
	acct.logout_confirm = false;
	voice_leave_channel();
	if net_action() { dc.client_logout(app.client, source); }
	accounts_drop(accts.active);
	accts.adding = accounts.count > 0 && !accts.switch_after_logout; // Back to the next saved account
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
		label(L("Log Out"), .Semibold, 20, T("--text-strong"), 24);
		spacer(.Y, 8);
		set_para("q", L("Are you sure you want to logout?"), .Normal, 16, 20, T("--text-subtle"));
		spacer(.Y, 24);
		btns := row("btns");
		btns.semantic_size = .[ui.pct(1), ui.px(38)];
		{ ui.parent(btns); defer ui.pop_parent();
			filler(.X);
			if set_button(L("Cancel##cancel"), .Secondary) { acct.logout_confirm = false; }
			spacer(.X, 8);
			if set_button(L("Log Out##confirm"), .Danger) { account_logout(); }
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
	set_heading(L("My Account"));
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
			if set_button(L("Edit User Profile##editprofile"), .Primary, true, 32) { settings_page = "Profiles"; }
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
				display := ifx u != null && u.global_name != "" then u.global_name else L("You haven't added a display name yet.");
				account_field("dname", L("Display Name"), display, .Display_Name);
				spacer(.Y, 24);
				account_field("uname", L("Username"), ifx u != null then u.username else "", .Username);
				spacer(.Y, 24);
				email := dc.account.email;
				// Streamer Mode > Hide Personal Information: masked, with no Reveal
				hide := streamer_hide_personal();
				shown := ifx email == "" then L("You haven't added an email yet.") else (ifx acct.reveal_email && !hide then email else mask_email(email));
				account_secret("email", L("Email"), shown, email != "" && !hide, *acct.reveal_email);
				spacer(.Y, 24);
				phone := dc.account.phone;
				pshown := ifx phone == "" then L("You haven't added a phone number yet.") else (ifx acct.reveal_phone && !hide then phone else mask_phone(phone));
				account_secret("phone", L("Phone Number"), pshown, phone != "" && !hide, *acct.reveal_phone);
				inset_end(16, 16);
			}
			spacer(.X, 16);
		}
		spacer(.Y, 16);
	}
	spacer(.Y, 40);
	set_heading(L("Password and Authentication"));
	if set_button(L("Change Password##chpw"), .Primary, true, 32) acct_modal_open(.Password);
	spacer(.Y, 28);
	label(L("AUTHENTICATOR APP"), .Bold, 12, T("--text-muted"), 16);
	spacer(.Y, 8);
	on := dc.account.mfa_enabled;
	set_para("mfa", ifx on then L("Two-factor authentication is enabled on this account.") else L("Protect your Discord account with an extra layer of security. Once configured, you'll be required to enter your password and complete one additional step in order to sign in."), .Normal, 14, 18, T("--text-muted"));
	spacer(.Y, 12);
	if on {
		if set_button(ifx acct.pending then L("Removing…##rmtotp") else L("Remove Authenticator App##rmtotp"), .Danger, !acct.pending, 32) && net_action() {
			acct.pending = true;
			set_error(*acct.error, "");
			dc.totp_disable(app.client); // the multi-factor check asks for a code
		}
	} else {
		if set_button(L("Enable Authenticator App##entotp"), .Primary, true, 32) acct_modal_open(.Totp);
	}
	if acct.modal == .None && acct.error != "" && acct.editing == .None {
		spacer(.Y, 8);
		set_para("mfaerr", acct.error, .Normal, 14, 18, T("--text-feedback-critical"));
	}
	if acct.backup_codes.count {
		spacer(.Y, 16);
		label(L("BACKUP CODES"), .Bold, 12, T("--text-muted"), 16);
		spacer(.Y, 4);
		set_para("bchelp", L("Keep these somewhere safe. Each code signs you in once if you lose your authenticator app; they are shown only now."), .Normal, 14, 18, T("--text-muted"));
		spacer(.Y, 8);
		set_para("codes", join(..acct.backup_codes, separator = "    ",, temp), .Medium, 16, 22, T("--text-strong")).flags |= .Selectable_Text;
	}
	spacer(.Y, 40);
	set_heading(L("Account Removal"));
	set_para("rmhelp", L("Disabling your account means you can recover it at any time after taking this action."), .Normal, 14, 18, T("--text-muted"));
	spacer(.Y, 12);
	rm := row("rmbtns");
	rm.semantic_size = .[ui.pct(1), ui.px(32)];
	{ ui.parent(rm); defer ui.pop_parent();
		if set_button(L("Disable Account##disable"), .Danger, true, 32) acct_modal_open(.Disable);
		spacer(.X, 12);
		if set_button(L("Delete Account##delete"), .Secondary, true, 32) acct_modal_open(.Delete);
	}
}

account_modal_is_open :: () -> bool { return acct.modal != .None; }

acct_modal_open :: (m: Acct_Modal) {
	acct_edit_close();
	acct.modal = m;
	for e: (*ui.Editor.[*acct.pass_ed, *acct.new_pass, *acct.confirm_pass]) ui.editor_set_text(e, "");
	free(acct.totp_secret);
	acct.totp_secret = ifx m == .Totp then copy_string(dc.totp_secret()) else "";
}

acct_modal_close :: () {
	acct.modal = .None;
	for e: (*ui.Editor.[*acct.pass_ed, *acct.new_pass, *acct.confirm_pass]) ui.editor_set_text(e, "");
}

// The open My Account modal (overlay pass). Requests go out on Done; MFA_REQUIRED replies go
// through mfa_modal first.
account_modal :: () {
	if acct.modal == .None return;
	if !app.settings_open {
		acct_modal_close();
		return;
	}
	W :: 440;
	m := acct.modal;
	title, sub := L("Update your password"), L("Enter your current password and a new password.");
	if m == .Totp title, sub = L("Enable Authenticator App"), L("Add this key to an authenticator app, then enter the code it shows.");
	if m == .Disable title, sub = L("Disable Account"), L("Are you sure that you want to disable your account? This will immediately log you out and make your account inaccessible to anyone.");
	if m == .Delete title, sub = L("Delete Account"), L("Are you sure that you want to delete your account? This will immediately log you out of your account and you will not be able to log in again.");
	if !adm_modal_begin("acctmodal", W, title) {
		acct_modal_close();
		return;
	}
	submit, cancel := false, false;
	body := row("body");
	body.semantic_size = .[ui.pct(1), ui.children()];
	{ ui.parent(body); defer ui.pop_parent();
		spacer(.X, 25);
		col := ui.box("col");
		col.semantic_size = .[ui.fill(), ui.children()];
		col.layout_axis = .Y;
		{ ui.parent(col); defer ui.pop_parent();
			spacer(.Y, 8);
			set_para("sub", sub, .Normal, 14, 18, T("--text-muted"));
			spacer(.Y, 16);
			field :: (id: string, title: string, ed: *ui.Editor, submit: *bool, cancel: *bool, password := true, first := false) {
				label(title, .Bold, 12, T("--text-muted"), 16);
				spacer(.Y, 8);
				res := set_input(id, ed, "", password = password, autofocus = first);
				spacer(.Y, 16);
				if res == .Submit submit.* = true;
				if res == .Escape cancel.* = true;
			}
			if m == .Totp {
				label("KEY", .Bold, 12, T("--text-muted"), 16);
				spacer(.Y, 8);
				k := acct.totp_secret;
				grouped := tprint("% % % %", slice(k, 0, 4), slice(k, 4, 4), slice(k, 8, 4), slice(k, 12, 4));
				label(to_lower_copy(grouped,, temp), .Semibold, 18, T("--text-strong"), 24).flags |= .Selectable_Text;
				spacer(.Y, 16);
				field("code", L("ENTER THE 6-DIGIT CODE"), *acct.new_pass, *submit, *cancel, password = false, first = true);
			} else {
				field("pw", L("CURRENT PASSWORD"), *acct.pass_ed, *submit, *cancel, first = true);
				if m == .Password {
					field("newpw", L("NEW PASSWORD"), *acct.new_pass, *submit, *cancel);
					field("confirmpw", L("CONFIRM NEW PASSWORD"), *acct.confirm_pass, *submit, *cancel);
				}
			}
			if acct.error {
				set_para("err", acct.error, .Normal, 14, 18, T("--text-feedback-critical"));
				spacer(.Y, 8);
			}
		}
		spacer(.X, 25);
	}
	spacer(.Y, 8);
	btns := row("btns");
	btns.semantic_size = .[ui.pct(1), ui.px(40)];
	btns.style.child_gap = 8;
	ready := ifx m == .Totp then trim(ui.editor_text(*acct.new_pass)) != "" else ui.editor_text(*acct.pass_ed) != "" && (m != .Password || ui.editor_text(*acct.new_pass) != "");
	{ ui.parent(btns); defer ui.pop_parent();
		spacer(.X, 25 - 8);
		if wide_button("cancel", L("Cancel"), .Secondary) cancel = true;
		verb := ifx m == .Totp then L("Activate") else ifx m == .Disable then L("Disable Account") else ifx m == .Delete then L("Delete Account") else L("Done");
		if wide_button("ok", ifx acct.pending then L("Saving…") else verb, ifx m == .Disable || m == .Delete then .Danger else .Primary, ready && !acct.pending) submit = true;
		spacer(.X, 25 - 8);
	}
	spacer(.Y, 24);
	adm_modal_end();
	if adm_escape() cancel = true;
	if cancel {
		acct_modal_close();
		set_error(*acct.error, "");
		return;
	}
	if !submit || !ready || acct.pending || !net_action() return;
	pw := ui.editor_text(*acct.pass_ed);
	if m == .Password && ui.editor_text(*acct.new_pass) != ui.editor_text(*acct.confirm_pass) {
		set_error(*acct.error, L("Passwords do not match!"));
		return;
	}
	acct.pending = true;
	set_error(*acct.error, "");
	if m == {
	case .Password; dc.change_password(app.client, pw, ui.editor_text(*acct.new_pass));
	case .Totp; dc.totp_enable(app.client, replace(trim(ui.editor_text(*acct.new_pass)), " ", "",, temp), acct.totp_secret);
	case .Disable; dc.remove_account(app.client, pw, false);
	case .Delete; dc.remove_account(app.client, pw, true);
	}
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
			if set_button(L("Edit##edit"), .Secondary, true, 32) { acct_edit_open(which); }
		}
		return;
	}
	spacer(.Y, 4);
	res: ui.Edit_Result;
	enabled := false;
	if which == {
	case .Display_Name;
		res = set_input("in", *acct.name_ed, L("Display name"), max_runes = PROFILE_NAME_MAX);
		enabled = true; // empty clears it (the username shows instead)
	case .Username;
		res = set_input("in", *acct.user_ed, L("Username"), max_runes = 32);
		uname := trim(ui.editor_text(*acct.user_ed));
		// availability as you type (debounced in the library: POST pomelo-attempt)
		if res == .Changed && app.client != null { dc.username_input_changed(app.client, uname); }
		msg, col := username_status(uname);
		if msg != "" {
			spacer(.Y, 6);
			set_para("avail", msg, .Normal, 14, 18, col);
		}
		spacer(.Y, 12);
		label(L("CURRENT PASSWORD"), .Bold, 12, T("--text-muted"), 16);
		spacer(.Y, 8);
		pres := set_input("pw", *acct.pass_ed, L("Password"), password = true);
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
		if set_button(L("Cancel##cancel"), .Link, true, 32) || res == .Escape { acct_edit_close(); }
		spacer(.X, 8);
		enabled = enabled && !acct.pending;
		if (set_button(ifx acct.pending then L("Saving…##save") else L("Done##save"), .Primary, enabled, 32) || res == .Submit && enabled) && net_action() {
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
		return L("Username is available. Nice!"), T("--text-feedback-positive");
	case .Taken;
		return L("Username is unavailable. Try adding numbers, letters, underscores _ , or periods."), T("--text-feedback-critical");
	case .Error;
		return chk.message, T("--text-feedback-critical");
	case .Rate_Limited;
		return L("Too fast! Wait a bit and try again."), T("--text-feedback-critical");
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
			l := ui.box(ifx reveal.* then L("Hide##reveal") else L("Reveal##reveal"), .Clickable | .Draw_Text);
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
	if set_button(tprint(L("Change %##change"), what), .Primary, true, 32) {
		paths := pick_files();
		if paths.count && net_action() change(paths[0]);
	}
	if has {
		spacer(.X, 8);
		if set_button(tprint(L("Remove %##remove"), what), .Link, true, 32) && net_action() change("");
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
		set_heading(L("Profiles"));
		tabs := row("pftabs");
		tabs.semantic_size = .[ui.pct(1), ui.px(32)];
		tabs.style.child_gap = 24;
		{ ui.parent(tabs); defer ui.pop_parent();
			for name, i: string.[L("Main Profile"), L("Per-server Profiles")] {
				on := acct.ps_tab == (i == 1);
				t := label(name, .Medium, 16, ifx on then T("--text-strong") else T("--text-muted"), 24);
				t.flags |= .Clickable;
				t.hover_cursor = .Pointer;
				if ui.signal(t).clicked acct.ps_tab = i == 1;
			}
		}
		spacer(.Y, 20);
		if acct.ps_tab per_server_form(u);
		else { // the main profile: the form and its preview
		cols := row("cols");
		cols.semantic_size = .[ui.pct(1), ui.children()];
		cols.cross_align = .Start;
		{ ui.parent(cols); defer ui.pop_parent();
			form := ui.box("form");
			form.semantic_size = .[ui.fill(), ui.children()];
			form.layout_axis = .Y;
			{ ui.parent(form); defer ui.pop_parent();
				label(L("Display Name"), .Semibold, 16, T("--text-strong"), 20);
				spacer(.Y, 8);
				set_input("name", *acct.pf_name, ifx u != null then u.username else "", max_runes = PROFILE_NAME_MAX);
				set_divider();
				label(L("Pronouns"), .Semibold, 16, T("--text-strong"), 20);
				spacer(.Y, 8);
				set_input("pronouns", *acct.pf_pronouns, L("Add your pronouns"), max_runes = PROFILE_PRONOUNS_MAX);
				set_divider();
				label(L("Avatar"), .Semibold, 16, T("--text-strong"), 20);
				spacer(.Y, 8);
				pf_image_row("avatar", L("Avatar"), u != null && u.avatar != "", (path: string) { dc.edit_my_avatar(app.client, path); });
				set_divider();
				if u != null && u.premium_type == 2 { // a custom banner is Nitro's: hidden otherwise, never offered
					label(L("Profile Banner"), .Semibold, 16, T("--text-strong"), 20);
					spacer(.Y, 8);
					pf_image_row("banner", L("Banner"), u.banner != "", (path: string) { dc.edit_my_banner(app.client, path); });
					set_divider();
				}
				label(L("Banner Color"), .Semibold, 16, T("--text-strong"), 20);
				spacer(.Y, 8);
				pf_color_picker(u);
				set_divider();
				label(L("About Me"), .Semibold, 16, T("--text-strong"), 20);
				spacer(.Y, 4);
				set_para("biohelp", L("You can use markdown and links if you'd like."), .Normal, 14, 18, T("--text-muted"));
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
		}
		set_page_end();
	}
	if acct.ps_tab {
		if ps_dirty() per_server_save_bar();
	} else if pf_dirty() || acct.pf_pending > 0 { profile_save_bar(); }
}

// Per-server Profiles: a server, then your nickname there; with Nitro also its avatar, About Me and
// pronouns (hidden, not locked, without it).
per_server_form :: (u: *dc.User) {
	s := store();
	names: [..]string;
	ids: [..]dc.Snowflake;
	names.allocator, ids.allocator = temp, temp;
	cur := -1;
	for guild_order() {
		g := dc.guild_get(s, it);
		if !g continue;
		if it == acct.ps_guild cur = ids.count;
		array_add(*names, g.name);
		array_add(*ids, it);
	}
	if !ids.count {
		set_para("noservers", L("You're not in any servers yet."), .Normal, 14, 18, T("--text-muted"));
		return;
	}
	label(L("Choose a server"), .Semibold, 16, T("--text-strong"), 20);
	spacer(.Y, 8);
	pick := select_field("psguild", names, cur);
	if pick >= 0 && ids[pick] != acct.ps_guild per_server_profile_open(ids[pick]); // and its bio and pronouns
	if !acct.ps_guild return;
	// the editors follow the server's values (the profile fetch brings bio and pronouns) until edited
	m0 := dc.member_get(s, acct.ps_guild, s.me);
	if m0 {
		pf_follow(*acct.ps_nick, *acct.ps_base[0], m0.nick);
		pf_follow(*acct.ps_bio, *acct.ps_base[1], m0.bio);
		pf_follow(*acct.ps_pronouns, *acct.ps_base[2], m0.pronouns);
	}
	set_divider();
	label(L("Server Nickname"), .Semibold, 16, T("--text-strong"), 20);
	spacer(.Y, 8);
	set_input("psnick", *acct.ps_nick, ifx u then dc.display_name(u) else "", max_runes = 32);
	if u == null || u.premium_type == 0 return;
	set_divider();
	label(L("Server Avatar"), .Semibold, 16, T("--text-strong"), 20);
	spacer(.Y, 8);
	mem := dc.member_get(s, acct.ps_guild, s.me);
	pf_image_row("psavatar", L("Avatar"), mem != null && mem.avatar != "", (path: string) { dc.edit_my_avatar(app.client, path, acct.ps_guild); });
	set_divider();
	label(L("Pronouns"), .Semibold, 16, T("--text-strong"), 20);
	spacer(.Y, 8);
	set_input("pspronouns", *acct.ps_pronouns, L("Add your pronouns"), max_runes = PROFILE_PRONOUNS_MAX);
	set_divider();
	label(L("About Me"), .Semibold, 16, T("--text-strong"), 20);
	spacer(.Y, 8);
	set_input("psbio", *acct.ps_bio, "", multiline = true, max_runes = PROFILE_BIO_MAX, min_h = 100);
}

// The server header menu's Edit Per-server Profile: Settings > Profiles on that server.
per_server_profile_open :: (gid: dc.Snowflake) {
	settings_page = "Profiles";
	app.settings_open = true;
	acct.ps_tab = true;
	if acct.ps_guild == gid return;
	acct.ps_guild = gid;
	for e, i: (*ui.Editor.[*acct.ps_nick, *acct.ps_bio, *acct.ps_pronouns]) {
		ui.editor_set_text(e, "");
		set_error(*acct.ps_base[i], "");
	}
	if app.client != null dc.fetch_profile(app.client, store().me, gid);
}

ps_dirty :: () -> bool {
	if !acct.ps_guild return false;
	for e, i: (*ui.Editor.[*acct.ps_nick, *acct.ps_bio, *acct.ps_pronouns]) if ui.editor_text(e) != acct.ps_base[i] return true;
	return false;
}

per_server_save_bar :: () {
	W :: 600;
	cw := app.ui.window.x - 2 * SET_INSET - SET_NAV_W - 1;
	ch := app.ui.window.y - 2 * SET_INSET - SET_TITLE_H - 1;
	w := min(cast(float32)(W), cw - 32);
	bar := row("pssavebar", .Draw_Background | .Draw_Shadow | .Floating_X | .Floating_Y);
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
	label(L("Careful — you have unsaved changes!"), .Medium, 15, T("--text-strong"), 20);
	filler(.X);
	eds := (*ui.Editor).[*acct.ps_nick, *acct.ps_bio, *acct.ps_pronouns];
	if set_button(L("Reset##psreset"), .Link, true, 32) for e, i: eds ui.editor_set_text(e, acct.ps_base[i]);
	spacer(.X, 8);
	if set_button(L("Save Changes##pssave"), .Positive, true, 32) {
		nick, bio, pron := trim(ui.editor_text(*acct.ps_nick)), ui.editor_text(*acct.ps_bio), ui.editor_text(*acct.ps_pronouns);
		if net_action() {
			if nick != acct.ps_base[0] dc.set_server_nickname(app.client, acct.ps_guild, store().me, nick);
			if bio != acct.ps_base[1] || pron != acct.ps_base[2] dc.update_guild_profile(app.client, acct.ps_guild, pron, bio);
		}
		for e, i: eds set_error(*acct.ps_base[i], ui.editor_text(e)); // saved: the form is clean (errors come back as notices)
	}
	spacer(.X, 12);
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
	label(L("Careful — you have unsaved changes!"), .Medium, 15, T("--text-strong"), 20);
	filler(.X);
	busy := acct.pf_pending > 0;
	if set_button(L("Reset##reset"), .Link, !busy, 32) {
		ui.editor_set_text(*acct.pf_name, acct.base_name);
		ui.editor_set_text(*acct.pf_pronouns, acct.base_pronouns);
		ui.editor_set_text(*acct.pf_bio, acct.base_bio);
		ui.editor_set_text(*acct.pf_hex, "");
		acct.pf_accent = dc.ACCENT_UNCHANGED;
		set_error(*acct.pf_error, "");
	}
	spacer(.X, 8);
	if set_button(ifx busy then L("Saving…##save") else L("Save Changes##save"), .Positive, !busy, 32) && net_action() {
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
		set_error(*mfa.error, ifx e then e else L("An error occurred. Please try again."));
		return;
	}
	if app.client != null dc.mfa_retry(app.client, tok);
	mfa_close(false);
}

mfa_modal :: () {
	if !mfa.open return;
	W :: 440;
	if !adm_modal_begin("mfa", W, L("Multi-Factor Authentication"), L("This extra step shows it's really you.")) {
		mfa_close(true);
		return;
	}
	kind := mfa.methods[mfa.method];
	submit, mfa_escape := false, false;
	body := row("body");
	body.semantic_size = .[ui.pct(1), ui.children()];
	{ ui.parent(body); defer ui.pop_parent();
		spacer(.X, 25);
		col := ui.box("col");
		col.semantic_size = .[ui.fill(), ui.children()];
		col.layout_axis = .Y;
		{ ui.parent(col); defer ui.pop_parent();
			spacer(.Y, 16);
			title, hint := L("Enter Discord Auth Code"), L("6-digit authentication code");
			if kind == "backup" title, hint = L("Enter Discord Backup Code"), L("8-digit backup code");
			if kind == "password" title, hint = L("Password"), "";
			label(to_upper_copy(title,, temp), .Bold, 12, T("--text-muted"), 16);
			spacer(.Y, 8);
			res := set_input(tprint("code_%", kind), *mfa.code, hint, password = kind == "password", max_runes = ifx kind == "password" then 0 else 11, autofocus = true);
			if res == .Submit submit = true;
			if res == .Escape mfa_escape = true;
			if mfa.error {
				spacer(.Y, 8);
				set_para("err", mfa.error, .Normal, 14, 18, T("--text-feedback-critical"));
			}
			if mfa.methods.count > 1 {
				spacer(.Y, 12);
				l := label(L("Verify with something else"), .Medium, 14, T("--text-link"), 18);
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
		if wide_button("cancel", L("Cancel"), .Secondary) cancel = true;
		if wide_button("confirm", ifx mfa.busy then L("Confirming...") else L("Confirm"), .Primary, !mfa.busy && trim(ui.editor_text(*mfa.code)) != "") submit = true;
		spacer(.X, 25 - 8);
	}
	spacer(.Y, 24);
	adm_modal_end();
	if adm_escape() || mfa_escape cancel = true;
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
