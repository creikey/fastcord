#scope_file

// Settings > My Account (user card, display name / username edits, masked email
// and phone, Log Out) and Settings > Profiles (display name, pronouns, About Me
// with a live preview and the client's unsaved-changes bar). Requests go out
// through dc.update_* and come back in account_receive (features_receive).

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
	pf_pending: int;
	pf_error: string; // heap
};
#scope_export

PROFILE_NAME_MAX :: 32;
PROFILE_PRONOUNS_MAX :: 40;
PROFILE_BIO_MAX :: 190;

account_reset_for_test :: () {
	for e: (*ui.Editor.[*acct.name_ed, *acct.user_ed, *acct.pass_ed, *acct.pf_name, *acct.pf_pronouns, *acct.pf_bio]) { ui.editor_set_text(e, ""); }
	delete(acct.error);
	delete(acct.pf_error);
	delete(acct.base_name);
	delete(acct.base_pronouns);
	delete(acct.base_bio);
	acct.editing = .None;
	acct.reveal_email, acct.reveal_phone, acct.pending, acct.logout_confirm = false, false, false, false;
	acct.error, acct.pf_error, acct.base_name, acct.base_pronouns, acct.base_bio = "", "", "", "", "";
	acct.pf_pending = 0;
}
#scope_file

set_error :: (dst: *string, s: string) {
	delete(dst.*);
	dst.* = clone(s);
}
#scope_export

// Results of dc.update_global_name / update_username / update_profile (UI thread).
account_receive :: (r: *dc.Feature_Result) {
	if app.client == null { return; }
	err := "";
	if !r.ok {
		err = dc.api_error_text(r.body);
		if err == "" { err = ifx r.status == 0 then "Couldn't reach Discord. Try again." else fmt.tprintf("Something went wrong (HTTP %d).", r.status); }
	}
	tok := dc.apply_account_result(*app.client.store, r);
	if tok != "" && !platform.is_headless() {
		// a username change rotates the token: keep the new one for the next start
		path := strings.concatenate(.{app_state_dir(), "/token"}, temp);
		dc.write_file_atomic(path, transmute([]u8, tok));
	}
	if r.op == .Profile_Patch || r.tag == cast(u64)(dc.User_Patch_Tag.Profile_Name) {
		acct.pf_pending = max(acct.pf_pending - 1, 0);
		set_error(*acct.pf_error, err);
	} else {
		acct.pending = false;
		set_error(*acct.error, err);
		if r.ok { acct_edit_close(); }
	}
	app.ui.animating = true;
}
#scope_file

acct_edit_close :: () {
	acct.editing = .None;
	ui.editor_set_text(*acct.pass_ed, "");
	set_error(*acct.error, "");
}
#scope_export

// ---- Log Out ----

account_logout_ask :: () {acct.logout_confirm = true;}

// Log Out (AuthenticationActionCreators.logout("settings")): POST /auth/logout
// revokes the session; the same client then shows the login page (auth.odin).
account_logout :: () {
	acct.logout_confirm = false;
	voice_leave_channel();
	if net_action() { dc.client_logout(app.client, "settings"); }
	if !platform.is_headless() && os.get_env("FASTCORD_TOKEN", temp) == "" {
		os.remove_(strings.concatenate(.{app_state_dir(), "/token"}, temp));
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
	scrim := ui.box("logout_scrim", .{.Draw_Background, .Clickable, .Floating_X, .Floating_Y, .Overlay});
	scrim.semantic_size = .[ui.px(app.ui.window.x), ui.px(app.ui.window.y)];
	scrim.style.bg = .{0, 0, 0, 0.5};
	if ui.signal(scrim).clicked {
		acct.logout_confirm = false;
		return;
	}
	W :: 440;
	d := ui.box("logout", .{.Draw_Background, .Draw_Border, .Floating_X, .Floating_Y, .Overlay, .Clickable});
	d.semantic_size = .[ui.px(W), ui.children()];
	d.fixed_pos = .{(app.ui.window.x - W) / 2, (app.ui.window.y - (d.rect.y1 - d.rect.y0)) / 2};
	d.style.bg = cast(T)("--modal-background");
	d.style.border_color = cast(T)("--border-subtle");
	d.style.border = 1;
	d.style.radius = 12;
	d.layout_axis = .Y;
	ui.signal(d);
	if ui.parent(d) {
		inner := inset_begin(24, 24);
		label("Log Out", .Semibold, 20, cast(T)("--text-strong"), 24);
		spacer(.Y, 8);
		set_para("q", "Are you sure you want to logout?", .Normal, 16, 20, cast(T)("--text-subtle"));
		spacer(.Y, 24);
		btns := row("btns");
		btns.semantic_size = .[ui.pct(1), ui.px(38)];
		if ui.parent(btns) {
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
	at := strings.last_index_byte(email, #char "@");
	if at < 0 { return "*****"; }
	return strings.concatenate(.{"*****", sub_from(email, at)}, temp);
}

// "*******1234": all but the last four digits hidden.
mask_phone :: (phone: string) -> string {
	if len(phone) <= 4 { return "****"; }
	return strings.concatenate(.{strings.repeat("*", len(phone) - 4, temp), sub_from(phone, len(phone) - 4)}, temp);
}

my_account_page :: () {
	if streamer_settings.enabled {
		streamer_account_page(); // view_streamer.odin
		return;
	}
	s := store();
	u := dc.user_get(s, s.me);
	if !set_page_begin("accountpage") { return; }
	defer set_page_end();
	set_heading("My Account");
	card := ui.box("card", .{.Draw_Background, .Clip});
	card.semantic_size = .[ui.pct(1), ui.children()];
	card.layout_axis = .Y;
	card.style.bg = cast(T)("--background-base-lowest");
	card.style.radius = 8;
	if ui.parent(card) {
		banner := ui.box("banner", .{.Draw_Background});
		banner.semantic_size = .[ui.pct(1), ui.px(100)];
		banner.style.bg = profile_banner_color(s.me);
		if u != null && u.banner != "" { set_remote_image(banner, dc.banner_url(s.me, u.banner, 600)); }
		head := row("head");
		head.semantic_size = .[ui.pct(1), ui.px(72)];
		if ui.parent(head) {
			ring := ui.box("ring", .{.Draw_Background, .Floating_X, .Floating_Y});
			ring.semantic_size = .[ui.px(94), ui.px(94)];
			ring.fixed_pos = .{16, -46};
			ring.style.radius = 47;
			ring.style.bg = card.style.bg;
			if ui.parent(ring) {
				av := avatar_with_status("av", s.me, 80, card.style.bg);
				av.flags += .{.Floating_X, .Floating_Y};
				av.fixed_pos = .{7, 7};
			}
			spacer(.X, 126);
			name := ifx u != null then dc.display_name(u) else "…";
			label(name, .Semibold, 20, cast(T)("--text-strong"), 24);
			filler(.X);
			if set_button("Edit User Profile##editprofile", .Primary, true, 32) { settings_page = "Profiles"; }
			spacer(.X, 16);
		}
		panel_row := row("panelrow");
		panel_row.semantic_size = .[ui.pct(1), ui.children()];
		if ui.parent(panel_row) {
			spacer(.X, 16);
			panel := ui.box("panel", .{.Draw_Background});
			panel.semantic_size = .[ui.fill(), ui.children()];
			panel.layout_axis = .Y;
			panel.style.bg = cast(T)("--background-base-low");
			panel.style.radius = 8;
			if ui.parent(panel) {
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
	set_para("mfa", mfa, .Normal, 14, 18, cast(T)("--text-muted"));
	spacer(.Y, 8);
	set_para("pwnote", "Change your password, email and two-factor settings in the official client or at discord.com.", .Normal, 14, 18, cast(T)("--text-muted"));
}
#scope_file

// LABEL / value with an Edit button, or the inline editor while editing.
account_field :: (id: string, title: string, value: string, which: Acct_Edit) {
	r := ui.box(id);
	r.semantic_size = .[ui.pct(1), ui.children()];
	r.layout_axis = .Y;
	ui.push_parent(r);
	defer ui.pop_parent();
	label(strings.to_upper(title, temp), .Bold, 12, cast(T)("--text-muted"), 16);
	spacer(.Y, 4);
	if acct.editing != which {
		vr := row("vrow");
		vr.semantic_size = .[ui.pct(1), ui.px(32)];
		if ui.parent(vr) {
			label(value, .Normal, 16, cast(T)("--text-default"), 20);
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
		uname := strings.trim_space(ui.editor_text(*acct.user_ed));
		// availability as you type (debounced in the library: POST pomelo-attempt)
		if res == .Changed && app.client != null { dc.username_input_changed(app.client, uname); }
		{ msg, col := username_status(uname);
		if msg != "" {
			spacer(.Y, 6);
			set_para("avail", msg, .Normal, 14, 18, col);
		} }
		spacer(.Y, 12);
		label("CURRENT PASSWORD", .Bold, 12, cast(T)("--text-muted"), 16);
		spacer(.Y, 8);
		pres := set_input("pw", *acct.pass_ed, "Password", password = true);
		if pres == .Submit { res = .Submit; }
		enabled = strings.trim_space(ui.editor_text(*acct.user_ed)) != "" && ui.editor_text(*acct.pass_ed) != "";
	case .None;
	}
	if acct.error != "" {
		spacer(.Y, 8);
		set_para("err", acct.error, .Normal, 14, 18, cast(T)("--text-feedback-critical"));
	}
	spacer(.Y, 12);
	br := row("btns");
	br.semantic_size = .[ui.pct(1), ui.px(32)];
	if ui.parent(br) {
		filler(.X);
		if set_button("Cancel##cancel", .Link, true, 32) || res == .Escape { acct_edit_close(); }
		spacer(.X, 8);
		enabled = enabled && !acct.pending;
		if (set_button(ifx acct.pending then "Saving…##save" else "Done##save", .Primary, enabled, 32) || res == .Submit && enabled) && net_action() {
			acct.pending = true;
			if which == .Display_Name {
				dc.update_global_name(app.client, strings.trim_space(ui.editor_text(*acct.name_ed)));
			} else {
				dc.update_username(app.client, strings.trim_space(ui.editor_text(*acct.user_ed)), ui.editor_text(*acct.pass_ed));
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
		return "Username is available. Nice!", cast(T)("--text-feedback-positive");
	case .Taken;
		return "Username is unavailable. Try adding numbers, letters, underscores _ , or periods.", cast(T)("--text-feedback-critical");
	case .Error;
		return chk.message, cast(T)("--text-feedback-critical");
	case .Rate_Limited;
		return "Too fast! Wait a bit and try again.", cast(T)("--text-feedback-critical");
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
	label(strings.to_upper(title, temp), .Bold, 12, cast(T)("--text-muted"), 16);
	spacer(.Y, 4);
	vr := row("vrow");
	vr.semantic_size = .[ui.pct(1), ui.px(24)];
	if ui.parent(vr) {
		label(shown, .Normal, 16, cast(T)("--text-default"), 20);
		if has {
			spacer(.X, 4);
			l := ui.box(ifx reveal.* then "Hide##reveal" else "Reveal##reveal", .{.Clickable, .Draw_Text});
			l.semantic_size = .[ui.text_size(0), ui.px(20)];
			l.style.font = F(.Normal);
			l.style.font_size = 14;
			l.style.text_color = cast(T)("--text-link");
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
	delete(base.*);
	base.* = clone(cur);
}

pf_dirty :: () -> bool {
	return ui.editor_text(*acct.pf_name) != acct.base_name || ui.editor_text(*acct.pf_pronouns) != acct.base_pronouns || ui.editor_text(*acct.pf_bio) != acct.base_bio;
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
		if ui.parent(cols) {
			form := ui.box("form");
			form.semantic_size = .[ui.fill(), ui.children()];
			form.layout_axis = .Y;
			if ui.parent(form) {
				label("Display Name", .Semibold, 16, cast(T)("--text-strong"), 20);
				spacer(.Y, 8);
				set_input("name", *acct.pf_name, ifx u != null then u.username else "", max_runes = PROFILE_NAME_MAX);
				set_divider();
				label("Pronouns", .Semibold, 16, cast(T)("--text-strong"), 20);
				spacer(.Y, 8);
				set_input("pronouns", *acct.pf_pronouns, "Add your pronouns", max_runes = PROFILE_PRONOUNS_MAX);
				set_divider();
				label("About Me", .Semibold, 16, cast(T)("--text-strong"), 20);
				spacer(.Y, 4);
				set_para("biohelp", "You can use markdown and links if you'd like.", .Normal, 14, 18, cast(T)("--text-muted"));
				spacer(.Y, 8);
				set_input("bio", *acct.pf_bio, "", multiline = true, max_runes = PROFILE_BIO_MAX, min_h = 100);
				spacer(.Y, 4);
				cr := row("count");
				cr.semantic_size = .[ui.pct(1), ui.px(16)];
				if ui.parent(cr) {
					filler(.X);
					left := PROFILE_BIO_MAX - utf8.rune_count_in_string(ui.editor_text(*acct.pf_bio));
					label(fmt.tprintf("%d", left), .Normal, 12, cast(T)("--text-muted"), 16);
				}
				if acct.pf_error != "" {
					spacer(.Y, 8);
					set_para("err", acct.pf_error, .Normal, 14, 18, cast(T)("--text-feedback-critical"));
				}
			}
			spacer(.X, 24);
			pv := ui.box("previewcol");
			pv.semantic_size = .[ui.px(260), ui.children()];
			pv.layout_axis = .Y;
			if ui.parent(pv) {
				label("PREVIEW", .Bold, 12, cast(T)("--text-muted"), 16);
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
	card := ui.box("preview", .{.Draw_Background, .Draw_Border, .Clip});
	card.semantic_size = .[ui.px(W), ui.children()];
	card.layout_axis = .Y;
	card.style.bg = cast(T)("--background-surface-high");
	card.style.border_color = cast(T)("--border-subtle");
	card.style.border = 1;
	card.style.radius = 8;
	ui.push_parent(card);
	defer ui.pop_parent();
	banner := ui.box("banner", .{.Draw_Background});
	banner.semantic_size = .[ui.pct(1), ui.px(90)];
	banner.style.bg = profile_banner_color(s.me);
	if u != null && u.banner != "" { set_remote_image(banner, dc.banner_url(s.me, u.banner, 600)); }
	avr := ui.box("avrow");
	avr.semantic_size = .[ui.pct(1), ui.px(40)];
	if ui.parent(avr) {
		ring := ui.box("ring", .{.Draw_Background, .Floating_X, .Floating_Y});
		ring.semantic_size = .[ui.px(80), ui.px(80)];
		ring.fixed_pos = .{10, -40};
		ring.style.radius = 40;
		ring.style.bg = card.style.bg;
		if ui.parent(ring) {
			av := avatar_with_status("av", s.me, 68, card.style.bg);
			av.flags += .{.Floating_X, .Floating_Y};
			av.fixed_pos = .{6, 6};
		}
	}
	inset_begin(16, 0);
	name := strings.trim_space(ui.editor_text(*acct.pf_name));
	if name == "" && u != null { name = u.username; }
	label(fmt.tprintf("%s##pvname", name), .Bold, 20, cast(T)("--text-strong"), 24);
	sub := ifx u != null then u.username else "";
	{ p := strings.trim_space(ui.editor_text(*acct.pf_pronouns));
	if p != "" { sub = fmt.tprintf("%s • %s", sub, p); } }
	label(fmt.tprintf("%s##pvsub", sub), .Normal, 14, cast(T)("--text-default"), 18);
	bio := ui.editor_text(*acct.pf_bio);
	if bio != "" {
		spacer(.Y, 12);
		b := ui.box("pvbio", .{.Wrap_Text});
		b.semantic_size = .[ui.pct(1), ui.text_size()];
		b.style.line_height = 18;
		b.style.text_color = cast(T)("--text-default");
		blocks := md_parse(bio);
		if len(blocks) > 0 { ui.set_spans(b, tokens_to_spans(blocks[0].tokens, .Normal, 14, null)); }
	}
	inset_end(16, 16);
}

// "Careful — you have unsaved changes!" with Reset / Save Changes, floating at the bottom.
profile_save_bar :: () {
	W :: 600;
	cw := app.ui.window.x - 2 * SET_INSET - SET_NAV_W - 1;
	ch := app.ui.window.y - 2 * SET_INSET - SET_TITLE_H - 1;
	w := min(cast(float32)(W), cw - 32);
	bar := row("savebar", .{.Draw_Background, .Draw_Shadow, .Floating_X, .Floating_Y});
	bar.semantic_size = .[ui.px(w), ui.px(52)];
	bar.fixed_pos = .{(cw - w) / 2, ch - 52 - 20};
	bar.style.bg = cast(T)("--background-surface-highest");
	bar.style.radius = 8;
	bar.style.shadow_color = .{0, 0, 0, 0.3};
	bar.style.shadow_blur = 12;
	bar.style.shadow_offset = .{0, 4};
	ui.push_parent(bar);
	defer ui.pop_parent();
	spacer(.X, 16);
	label("Careful — you have unsaved changes!", .Medium, 15, cast(T)("--text-strong"), 20);
	filler(.X);
	busy := acct.pf_pending > 0;
	if set_button("Reset##reset", .Link, !busy, 32) {
		ui.editor_set_text(*acct.pf_name, acct.base_name);
		ui.editor_set_text(*acct.pf_pronouns, acct.base_pronouns);
		ui.editor_set_text(*acct.pf_bio, acct.base_bio);
		set_error(*acct.pf_error, "");
	}
	spacer(.X, 8);
	if set_button(ifx busy then "Saving…##save" else "Save Changes##save", .Positive, !busy, 32) && net_action() {
		set_error(*acct.pf_error, "");
		name := strings.trim_space(ui.editor_text(*acct.pf_name));
		if name != acct.base_name {
			dc.update_global_name(app.client, name, .Profile_Name);
			acct.pf_pending += 1;
		}
		if ui.editor_text(*acct.pf_pronouns) != acct.base_pronouns || ui.editor_text(*acct.pf_bio) != acct.base_bio {
			dc.update_profile(app.client, ui.editor_text(*acct.pf_pronouns), ui.editor_text(*acct.pf_bio));
			acct.pf_pending += 1;
		}
	}
	spacer(.X, 12);
}
#scope_export

