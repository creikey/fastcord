// Saved Discord accounts and switching between them: the account popout's Switch Accounts, its
// Manage Accounts modal and Add an Account, like the official client's multi-account switcher (at most
// 5). Every account lives in <state>/token, the only file that holds tokens, one line each in the order
// they were added: "token\tid\tusername\tglobal_name\tavatar\tactive" (active "1" on one line; a file
// from before holds the token alone). Switching drops the Discord client and starts one for the other
// token; hosted servers log in with fastcord's own key, not the Discord account, and stay connected
// (traffic/CLIENT_RULES.md "Account switching").

MAX_ACCOUNTS :: 5;

Saved_Account :: struct {
	token: string;
	id: dc.Snowflake;
	username: string;
	global_name: string;
	avatar: string;
}

accounts: [..]Saved_Account; // heap

accts: struct {
	active := -1; // the account the Discord client runs as
	menu_open: bool; // the popout's Switch Accounts submenu
	menu_y: float32;
	manage_open: bool; // the Manage Accounts modal
	adding: bool; // Add an Account: the login page, the other accounts kept
	switch_after_logout: bool; // the active account logged out from Manage Accounts: the next one comes up
	// a switch waiting for the new session's READY (multi_account_switch_success)
	switch_from: dc.Snowflake;
	switch_to: dc.Snowflake;
	switch_origin: string;
	ever_connected: bool; // a Discord READY was seen in this process
};

accounts_load :: (state_dir: string) {
	accounts_clear();
	data, ok := read_entire_file(tprint("%/token", state_dir), log_errors = false,, temp);
	if !ok return;
	for line: split(data, "\n",, temp) {
		f := split(trim(line, "\r"), "\t",, temp);
		if accounts.count >= MAX_ACCOUNTS || trim(f[0]) == "" continue;
		a := array_add(*accounts);
		a.token = copy_string(trim(f[0]));
		if f.count > 1 a.id = dc.parse_snowflake(f[1]);
		if f.count > 2 a.username = copy_string(f[2]);
		if f.count > 3 a.global_name = copy_string(f[3]);
		if f.count > 4 a.avatar = copy_string(f[4]);
		if (f.count < 6 || f[5] == "1") && accts.active < 0 accts.active = accounts.count - 1;
	}
}

accounts_save :: () -> bool {
	if platform.is_headless() || env_var("FASTCORD_TOKEN") != "" return true;
	dir := app_state_dir();
	make_directory_if_it_does_not_exist(dir, recursive = true);
	path := tprint("%/token", dir);
	if !accounts.count return file_delete(path) || !file_exists(path);
	field :: (s: string) -> string { return replace(replace(replace(s, "\t", " ",, temp), "\n", " ",, temp), "\r", " ",, temp); }
	b: String_Builder;
	b.allocator = temp;
	for accounts print_to_builder(*b, "%\t%\t%\t%\t%\t%\n", field(it.token), it.id, field(it.username), field(it.global_name), field(it.avatar), cast(int)(it_index == accts.active));
	return dc.write_file_atomic(path, cast([]u8) builder_to_string(*b,, temp));
}

// accounts_set_token: a login (or a rotated token) for the active account; after Add an Account, a new
// one after the others.
accounts_set_token :: (token: string) -> bool {
	if accts.adding || accts.active < 0 {
		if accounts.count >= MAX_ACCOUNTS accounts_drop(0);
		array_add(*accounts, .{});
		accts.active = accounts.count - 1;
	}
	accts.adding = false;
	a := *accounts[accts.active];
	free(a.token);
	a.token = copy_string(token);
	return accounts_save();
}

// accounts_drop: forgets account i (its token too).
accounts_drop :: (i: int) {
	if i < 0 || i >= accounts.count return;
	account_free(*accounts[i]);
	array_ordered_remove_by_index(*accounts, i);
	if accts.active == i accts.active = -1;
	else if accts.active > i accts.active -= 1;
	accounts_save();
}

account_free :: (a: *Saved_Account) {
	crypto.zero(cast([]u8) a.token);
	for (*string).[*a.token, *a.username, *a.global_name, *a.avatar] free(it.*);
}

accounts_clear :: () {
	for * accounts account_free(it);
	array_reset(*accounts);
	accts.active = -1;
}

// The saved accounts' tokens in order (the popout checks each, dc.open_account_popout).
account_tokens :: () -> []string {
	out := NewArray(accounts.count, string,, temp);
	for accounts out[it_index] = it.token;
	return out;
}

// Each frame: the active account's id and names follow its user, logging in to an account that was
// already saved keeps one entry, and a switch's READY is tracked.
accounts_frame :: () {
	c := app.discord;
	if c == null || !c.store.ready || accts.adding || accts.active < 0 return;
	u := dc.user_get(*c.store, c.store.me);
	if u == null return;
	if accts.switch_to {
		linked := NewArray(accounts.count, dc.Snowflake,, temp);
		for accounts linked[it_index] = ifx it_index == accts.active then u.id else it.id;
		dc.analytics_multi_account_switched(c, accts.switch_from, accts.switch_to, linked, accts.ever_connected, accts.switch_origin);
		accts.switch_from, accts.switch_to = 0, 0;
	}
	accts.ever_connected = true;
	a := *accounts[accts.active];
	if a.id == u.id && a.username == u.username && a.global_name == u.global_name && a.avatar == u.avatar return;
	a.id = u.id;
	for (*string).[*a.username, *a.global_name, *a.avatar] free(it.*);
	a.username, a.global_name, a.avatar = copy_string(u.username), copy_string(u.global_name), copy_string(u.avatar);
	for accounts if it.id == u.id && it_index != accts.active {
		accounts_drop(it_index);
		break;
	}
	accounts_save();
}

account_name :: (a: Saved_Account) -> string {
	if a.global_name return a.global_name;
	if a.username return a.username;
	return L("Discord account");
}

// account_switch: account i becomes the active one. section and origin name where it was picked.
account_switch :: (i: int, section: string, origin: string) {
	if i < 0 || i >= accounts.count || i == accts.active return;
	if app.discord {
		dc.analytics_multi_account_attempt(app.discord, section);
		accts.switch_from, accts.switch_to, accts.switch_origin = app.discord.store.me, accounts[i].id, origin;
	}
	accts.active = i;
	accounts_save();
	accts.adding = false;
	discord_restart();
}

// account_add: the login page for another account; the saved ones stay (Back returns to the active one).
account_add :: () {
	if accounts.count >= MAX_ACCOUNTS return;
	accts.adding = true;
	discord_restart();
}

account_add_cancel :: () {
	accts.adding = false;
	discord_restart();
}

// Manage Accounts' Log Out: the active account logs out (POST /auth/logout) and the next saved one comes
// up; another one is only forgotten here.
account_remove :: (i: int) {
	if i != accts.active {
		accounts_drop(i);
		return;
	}
	accts.manage_open = false;
	accts.switch_after_logout = accounts.count > 1;
	account_logout("multi_accounts_list");
}

// Called on Logged_Out (login_events): after Manage Accounts' Log Out of the active account.
accounts_logged_out :: () {
	if !accts.switch_after_logout return;
	accts.switch_after_logout = false;
	if accounts.count discord_restart();
}

// discord_restart drops the Discord client (teardown.jai) and connects with the active account, or with
// none while adding one. Offline (fixture) runs only change the list.
discord_restart :: () {
	accts.menu_open, accts.manage_open = false, false;
	if accts.active < 0 && accounts.count && !accts.adding accts.active = 0;
	if platform.is_headless() && app.discord == null return; // offline: no Discord client to replace
	voice_leave_channel();
	login_reset();
	app.settings_open = false;
	app.profile_user = 0;
	app.login_error = "";
	app.view.guild, app.view.channel = 0, 0;
	if app.discord != null {
		client_release(app.discord);
		if app.client == app.discord app.client = null;
		app.discord = null;
	}
	app.client = null;
	app.needs_login = accts.adding;
	connect();
}

// ---- UI ----


saved_avatar :: (id: string, a: Saved_Account, size: float32) -> *ui.Box {
	url := ifx a.avatar && dc.is_hash(a.avatar) then dc.avatar_url(a.id, a.avatar, 64) else dc.default_avatar_url(a.id, "0");
	return url_avatar_box(id, url, cast(int)((cast(u64) a.id >> 22) % 6), size);
}

// The account popout's second group: Switch Accounts, opening its submenu on hover.
account_switch_group :: () {
	gr := row("acctgrp2");
	gr.semantic_size = .[ui.pct(1), ui.children()];
	{ ui.parent(gr); defer ui.pop_parent();
		spacer(.X, 12);
		g := ui.box("grp", .Draw_Background);
		g.semantic_size = .[ui.fill(), ui.children()];
		g.layout_axis = .Y;
		g.style.bg = T("--background-mod-subtle");
		g.style.radius = all4(8);
		{ ui.parent(g); defer ui.pop_parent();
			spacer(.Y, 4);
			sw := menu_item("switchacct", L("Switch Accounts"), .Chevron, open = accts.menu_open, lead = "user-circle");
			if sw.hovering || sw.clicked {
				accts.menu_open = true;
				accts.menu_y = sw.box.rect.y0;
				sm.open = false;
			}
			spacer(.Y, 4);
		}
		spacer(.X, 12);
	}
	spacer(.Y, 12);
}

// The submenu: each saved account (a click switches to it; the active one is checked), then Manage
// Accounts.
accounts_menu :: (card: *ui.Box) {
	W :: cast(float32) 240;
	x := card.rect.x1 + 8;
	if x + W > app.ui.window.x - 8 x = card.rect.x0 - 8 - W;
	h := cast(float32)(max(accounts.count, 1) * 40 + GM_ROW_H + 25);
	menu := menu_panel("acctmenu", .{x, clamp(accts.menu_y - 8, 8, max(8.0, app.ui.window.y - h - 8))}, W);
	{ ui.parent(menu); defer ui.pop_parent();
		spacer(.Y, 8);
		for accounts {
			if account_row(tprint("acct%", it_index), it, it_index == accts.active).clicked account_switch(it_index, "User Profile", "multi_account_menu");
		}
		menu_sep("s1");
		if menu_item("manageacct", L("Manage Accounts")).clicked {
			accts.menu_open = false;
			accts.manage_open = true;
			app.profile_user = 0;
			if app.discord dc.analytics_multi_account_landing(app.discord);
		}
		spacer(.Y, 8);
	}
}

account_row :: (id: string, a: Saved_Account, active: bool) -> ui.Signal {
	outer := row(id);
	outer.semantic_size = .[ui.pct(1), ui.px(40)];
	sig: ui.Signal;
	{ ui.parent(outer); defer ui.pop_parent();
		spacer(.X, 8);
		r := row("it", .Clickable | .Draw_Background | .Hot_Animation);
		r.semantic_size = .[ui.fill(), ui.px(40)];
		r.style.radius = all4(4);
		r.style.bg_hot = T("--background-mod-normal");
		sig = ui.signal(r);
		ui.parent(r); defer ui.pop_parent();
		spacer(.X, 8);
		saved_avatar("av", a, 24);
		spacer(.X, 8);
		label(ifx a.username then a.username else account_name(a), .Normal, 14, T("--interactive-text-active"), 18);
		filler(.X);
		if active icon("ck", "checkmark-small-bold", 18, T("--text-brand"));
		spacer(.X, 8);
	}
	return sig;
}

// Manage Accounts: every saved account with Log In (switch) or Active, and Log Out; Add an Account.
manage_accounts_modal :: () {
	close := false;
	scrim := ui.box("acct_scrim", .Draw_Background | .Clickable | .Floating_X | .Floating_Y | .Overlay);
	scrim.semantic_size = .[ui.px(app.ui.window.x), ui.px(app.ui.window.y)];
	scrim.style.bg = .{0, 0, 0, 0.7};
	if ui.signal(scrim).clicked close = true;
	W :: 440;
	PAD :: 24;
	d := ui.box("acctmodal", .Draw_Background | .Draw_Border | .Floating_X | .Floating_Y | .Overlay | .Clickable);
	d.semantic_size = .[ui.px(W), ui.children()];
	d.fixed_pos = .{(app.ui.window.x - W) / 2, (app.ui.window.y - (d.rect.y1 - d.rect.y0)) / 2};
	d.style.bg = T("--modal-background");
	d.style.border_color = T("--border-subtle");
	d.style.border = 1;
	d.style.radius = all4(12);
	d.layout_axis = .Y;
	d.cross_align = .Center;
	ui.signal(d);
	{ ui.parent(d); defer ui.pop_parent();
		spacer(.Y, PAD);
		label(L("Manage Accounts"), .Semibold, 20, T("--text-strong"), 24);
		spacer(.Y, 8);
		label(L("Switch between accounts on this device."), .Normal, 14, T("--text-default"), 18);
		spacer(.Y, 16);
		log_out := -1;
		switch_to := -1;
		for accounts {
			r := row(tprint("a%", it_index));
			r.semantic_size = .[ui.pct(1), ui.px(56)];
			ui.parent(r); defer ui.pop_parent();
			spacer(.X, PAD);
			saved_avatar("av", it, 40);
			spacer(.X, 12);
			col := ui.box("col");
			col.semantic_size = .[ui.fill(), ui.children()];
			col.layout_axis = .Y;
			{ ui.parent(col); defer ui.pop_parent();
				label(account_name(it), .Semibold, 16, T("--text-strong"), 20);
				if it.username label(it.username, .Normal, 14, T("--text-muted"), 18);
			}
			if it_index == accts.active label(L("Active"), .Medium, 14, T("--text-feedback-positive"), 18);
			else if set_button(tprint(L("Log In##in%"), it_index), .Primary, true, 32) switch_to = it_index;
			spacer(.X, 8);
			if set_button(tprint(L("Log Out##out%"), it_index), .Secondary, true, 32) log_out = it_index;
			spacer(.X, PAD);
		}
		spacer(.Y, 16);
		full := accounts.count >= MAX_ACCOUNTS;
		br := row("addrow");
		br.semantic_size = .[ui.pct(1), ui.px(40)];
		{ ui.parent(br); defer ui.pop_parent();
			spacer(.X, PAD);
			filler(.X);
			if set_button(L("Add an Account##add"), .Primary, !full, 40) account_add();
			filler(.X);
			spacer(.X, PAD);
		}
		if full {
			spacer(.Y, 8);
			label(L("You can add up to 5 accounts."), .Normal, 12, T("--text-muted"), 16);
		}
		spacer(.Y, PAD);
		if switch_to >= 0 account_switch(switch_to, "Manage Accounts Modal", "multi_accounts_list");
		else if log_out >= 0 account_remove(log_out);
	}
	for * e: app.ui.events if !e.consumed && e.kind == .Key_Down && e.key == .Escape {
		e.consumed = true;
		close = true;
	}
	if close accts.manage_open = false;
}
