// The guild rail's "Add a Server" modal (the client's CreateGuildModal):
//   Create Your Server -> "Create My Own" -> Customize Your Server (name) -> Create
//                      -> "Join a Server" -> invite link / code -> Join Server
// Create posts /guilds (dc.create_guild, "For me and my friends" template); the
// library opens the new guild when its GUILD_CREATE arrives and the view follows.
// Join resolves and accepts the invite on a worker thread (dc.join_invite blocks);
// the library opens the guild at the invite's channel when its GUILD_CREATE
// arrives and the view follows. "Discover" opens discord.com/servers.

Add_Server_Step :: enum u8 {
	Closed;
	Choose;
	Create;
	Join;
}
#scope_file

JOIN_RUNNING :: 0;
JOIN_DONE :: 1;
JOIN_RELEASE :: 2;
#scope_export
#scope_file // the client was logged out mid-request: the worker releases it

Join_Job :: struct {
	client: *dc.Client;
	input: string; // the invite field as typed (inputValue)
	member_of: []dc.Snowflake; // guilds we're in when the join started (user_is_member)
	state: int; // atomic: JOIN_*
	res: dc.Invite_Result;
}
#scope_file

asv: struct {
	step: Add_Server_Step;
	name_ed: ui.Editor;
	invite_ed: ui.Editor;
	error: string; // heap
	creating: bool; // POST /guilds sent; waiting for its GUILD_CREATE
	job: *Join_Job; // join in flight
	open_guild: dc.Snowflake; // joined: select it once it is in the store
	step_ms: s64; // when the current step was shown (nuo_transition seconds_on_from_step)
};
#scope_export

add_server_reset_for_test :: () {
	ui.editor_set_text(*asv.name_ed, "");
	ui.editor_set_text(*asv.invite_ed, "");
	delete(asv.error);
	asv.error = "";
	asv.step = .Closed;
	asv.creating = false;
	asv.open_guild = 0;
	asv.job = null; // a test job (none offline) would be leaked, not freed under a worker
}

add_server_is_open :: () -> bool {return asv.step != .Closed;}

add_server_open :: () {add_server_step(.Choose);}
#scope_file

add_server_step :: (st: Add_Server_Step) {
	if app.client != null {
		if st == {
		case .Choose;
			dc.guild_add_step(app.client, .Templates, ifx asv.step == .Closed then 0 else asv.step_ms);
		case .Join;
			dc.guild_add_step(app.client, .Join, asv.step_ms);
		}
	}
	asv.step_ms = dc.now_ms();
	asv.step = st;
	asv.step_ms = dc.now_ms();
	set_err("");
	app.ui.focus = 0; // the step's field takes focus
}
#scope_export

// Rail "Discover": server discovery lives on the website (no in-app directory).
discover_open :: () {open_url("https://discord.com/servers");}
#scope_file

set_err :: (s: string) {
	delete(asv.error);
	asv.error = clone(s);
}
#scope_export

// Logging out while a join is in flight: the worker still uses the client, so it
// releases it when done. True when the worker took it over.
add_server_take_client :: (c: *dc.Client) -> bool {
	j := asv.job;
	if j == null || j.client != c { return false; }
	asv.job = null;
	_, ok := sync.atomic_compare_exchange_strong(*j.state, JOIN_RUNNING, JOIN_RELEASE);
	if !ok { free_job(j); } // already done: the caller releases the client
	return ok;
}
#scope_file

free_job :: (j: *Join_Job) {
	delete(j.input);
	delete(j.member_of);
	delete(j.res.code);
	free(j);
}

join_start :: (input: string) {
	j := new(Join_Job);
	j.client = app.client;
	j.input = clone(input);
	j.member_of = clone(view(store().guild_order));
	asv.job = j;
	thread.create_and_start_with_poly_data(j, (j: *Join_Job) {
		j.res = dc.join_invite(j.client, j.input, member_of = j.member_of);
		{ _, ok := sync.atomic_compare_exchange_strong(*j.state, JOIN_RUNNING, JOIN_DONE);
		if !ok {
			client_release(j.client);
			free_job(j);
		} }
		free_all(temp);
		platform.request_frame();
	}, self_cleanup = true);
}
#scope_export

// Per frame (overlay pass): finished requests, pending navigation, then the modal.
add_server_overlay :: () {
	{ j := asv.job;
	if j != null && atomic_load(*j.state) == JOIN_DONE {
		asv.job = null;
		if j.res.ok && j.res.guild_id != 0 {
			asv.open_guild = j.res.guild_id;
			asv.step = .Closed;
			ui.editor_set_text(*asv.invite_ed, "");
		} else if j.res.status == 0 {
			set_err("Couldn't reach Discord. Try again.");
		} else {
			set_err("The invite is invalid or has expired.");
		}
		free_job(j);
	} }
	if asv.open_guild != 0 && app.client != null && dc.guild_get(store(), asv.open_guild) != null {
		// the library opened it on GUILD_CREATE (route = the invite's channel); follow
		// it, or select it here when we were a member already (no GUILD_CREATE)
		locks.lock(*app.client.route_mu);
		g, ch := app.client.route_guild, app.client.route_channel;
		locks.unlock(*app.client.route_mu);
		if g == asv.open_guild {
			select_channel(g, ch);
		} else {
			select_guild(asv.open_guild);
		}
		asv.open_guild = 0;
	}
	if asv.creating && app.client != null && !app.client.pending_guild_create {
		// the library selected the new guild on GUILD_CREATE (dc.select_channel); follow it
		locks.lock(*app.client.route_mu);
		g, ch := app.client.route_guild, app.client.route_channel;
		locks.unlock(*app.client.route_mu);
		app.view.guild, app.view.channel = g, ch;
		at(*app.view.last_channel, g).* = ch;
		asv.creating = false;
		asv.step = .Closed;
	}
	if asv.step != .Closed { add_server_modal(); }
}
#scope_file

add_server_modal :: () {
	scrim := ui.box("addsrv_scrim", .{.Draw_Background, .Clickable, .Floating_X, .Floating_Y, .Overlay});
	scrim.semantic_size = .[ui.px(app.ui.window.x), ui.px(app.ui.window.y)];
	scrim.style.bg = .{0, 0, 0, 0.7};
	if ui.signal(scrim).clicked {
		asv.step = .Closed;
		return;
	}
	W :: 440;
	d := ui.box("addsrv", .{.Draw_Background, .Draw_Border, .Floating_X, .Floating_Y, .Overlay, .Clickable});
	d.semantic_size = .[ui.px(W), ui.children()];
	d.fixed_pos = .{(app.ui.window.x - W) / 2, max((app.ui.window.y - (d.rect.y1 - d.rect.y0)) / 2, 16)};
	d.style.bg = cast(T)("--modal-background");
	d.style.border_color = cast(T)("--border-subtle");
	d.style.border = 1;
	d.style.radius = 12;
	d.layout_axis = .Y;
	ui.signal(d);
	if ui.parent(d) {
		x := ui.box("close", .{.Clickable, .Floating_X, .Floating_Y});
		x.semantic_size = .[ui.px(24), ui.px(24)];
		x.fixed_pos = .{W - 16 - 24, 16};
		xs := ui.signal(x);
		set_icon(x, "x-large", ifx xs.hovering then cast(T)("--interactive-icon-hover") else cast(T)("--interactive-icon-default"));
		if xs.clicked { asv.step = .Closed; }
		if asv.step == {
		case .Choose;
			step_choose();
		case .Create;
			step_create();
		case .Join;
			step_join();
		case .Closed;
		}
	}
	for * e: app.ui.events {
		if e.kind == .Key_Down && e.key == .Escape {
			asv.step = .Closed;
			e.consumed = true;
		}
	}
}

centered :: (id: string, text: string, font: Font_Id, size: float32, line_h: float32, color: ui.Color) {
	b := set_para(id, text, font, size, line_h, color);
	b.style.text_align = .Center;
}

step_choose :: () {
	inset_begin(16, 0);
	spacer(.Y, 24);
	centered("title", "Create Your Server", .Bold, 24, 30, cast(T)("--text-strong"));
	spacer(.Y, 8);
	centered("sub", "Your server is where you and your friends hang out. Make yours and start talking.", .Normal, 16, 20, cast(T)("--text-subtle"));
	spacer(.Y, 24);
	own := row("own", .{.Clickable, .Draw_Background, .Draw_Border, .Hot_Animation});
	own.semantic_size = .[ui.pct(1), ui.px(64)];
	own.style.radius = 8;
	own.style.border = 1;
	own.style.border_color = cast(T)("--border-subtle");
	own.style.bg = cast(T)("--background-base-low");
	own.style.bg_hot = cast(T)("--background-mod-normal");
	if ui.signal(own).clicked {
		add_server_step(.Create);
		s := store();
		name := "My";
		{ u := dc.user_get(s, s.me);
		if u != null { name = u.username; } }
		ui.editor_set_text(*asv.name_ed, fmt.tprintf("%s's server", name));
		set_err("");
	}
	if ui.parent(own) {
		spacer(.X, 16);
		icon("i", "circle-plus", 32, cast(T)("--text-brand"));
		spacer(.X, 12);
		label("Create My Own", .Semibold, 16, cast(T)("--text-strong"), 20);
		filler(.X);
		icon("chev", "chevron-small-right", 20, cast(T)("--interactive-icon-default"));
		spacer(.X, 12);
	}
	inset_end(16, 0);
	spacer(.Y, 24);
	foot := ui.box("foot", .{.Draw_Background});
	foot.semantic_size = .[ui.pct(1), ui.children()];
	foot.layout_axis = .Y;
	foot.style.bg = cast(T)("--modal-footer-background");
	foot.style.radius = .{0, 0, 12, 12};
	if ui.parent(foot) {
		inset_begin(16, 16);
		centered("have", "Have an invite already?", .Semibold, 20, 24, cast(T)("--text-strong"));
		spacer(.Y, 8);
		jr := row("jr");
		jr.semantic_size = .[ui.pct(1), ui.px(38)];
		if ui.parent(jr) {
			b := ui.box("Join a Server##join", .{.Clickable, .Draw_Background, .Draw_Text, .Hot_Animation});
			b.semantic_size = .[ui.pct(1), ui.px(38)];
			b.style.radius = 8;
			b.style.font = F(.Medium);
			b.style.font_size = 14;
			b.style.text_align = .Center;
			b.style.bg = cast(T)("--background-mod-strong");
			b.style.bg_hot = with_alpha(b.style.bg, 0.85);
			b.style.text_color = cast(T)("--text-strong");
			if ui.signal(b).clicked { add_server_step(.Join); }
		}
		inset_end(16, 16);
	}
}

footer_begin :: () -> *ui.Box {
	foot := row("foot", .{.Draw_Background});
	foot.semantic_size = .[ui.pct(1), ui.px(70)];
	foot.style.bg = cast(T)("--modal-footer-background");
	foot.style.radius = .{0, 0, 12, 12};
	return foot;
}

step_create :: () {
	inset_begin(16, 0);
	spacer(.Y, 24);
	centered("title", "Customize Your Server", .Bold, 24, 30, cast(T)("--text-strong"));
	spacer(.Y, 8);
	centered("sub", "Give your new server a personality with a name. You can always change it later.", .Normal, 16, 20, cast(T)("--text-subtle"));
	spacer(.Y, 24);
	label("SERVER NAME", .Bold, 12, cast(T)("--text-default"), 16);
	spacer(.Y, 8);
	res := set_input("name", *asv.name_ed, "", max_runes = 100, autofocus = true);
	spacer(.Y, 8);
	set_para("terms", "By creating a server, you agree to Discord's Community Guidelines.", .Normal, 12, 16, cast(T)("--text-muted"));
	if asv.error != "" {
		spacer(.Y, 8);
		set_para("err", asv.error, .Normal, 14, 18, cast(T)("--text-feedback-critical"));
	}
	inset_end(16, 0);
	spacer(.Y, 24);
	name := strings.trim_space(ui.editor_text(*asv.name_ed));
	if ui.parent(footer_begin()) {
		spacer(.X, 16);
		if set_button("Back##back", .Link) { add_server_step(.Choose); }
		filler(.X);
		ok := name != "" && !asv.creating;
		if (set_button(ifx asv.creating then "Creating…##create" else "Create##create", .Primary, ok) || res == .Submit && ok) && net_action() {
			dc.create_guild(app.client, name, step_shown_ms = asv.step_ms);
			asv.creating = true;
		}
		spacer(.X, 16);
	}
}

step_join :: () {
	inset_begin(16, 0);
	spacer(.Y, 24);
	centered("title", "Join a Server", .Bold, 24, 30, cast(T)("--text-strong"));
	spacer(.Y, 8);
	centered("sub", "Enter an invite below to join an existing server", .Normal, 16, 20, cast(T)("--text-subtle"));
	spacer(.Y, 24);
	lr := row("lr");
	lr.semantic_size = .[ui.pct(1), ui.px(16)];
	if ui.parent(lr) {
		label("INVITE LINK", .Bold, 12, ifx asv.error != "" then cast(T)("--text-feedback-critical") else cast(T)("--text-default"), 16);
		label(" *##req", .Bold, 12, cast(T)("--text-feedback-critical"), 16);
		if asv.error != "" { label(fmt.tprintf(" - %s##err", asv.error), .Medium, 12, cast(T)("--text-feedback-critical"), 16); }
	}
	spacer(.Y, 8);
	res := set_input("invite", *asv.invite_ed, "https://discord.gg/hTKzmak", autofocus = true);
	spacer(.Y, 16);
	label("INVITES SHOULD LOOK LIKE", .Bold, 12, cast(T)("--text-default"), 16);
	spacer(.Y, 8);
	for ex: (string.["hTKzmak", "https://discord.gg/hTKzmak", "https://discord.gg/cool-people"]) {
		label(ex, .Normal, 14, cast(T)("--text-default"), 20);
	}
	inset_end(16, 0);
	spacer(.Y, 24);
	busy := asv.job != null;
	if ui.parent(footer_begin()) {
		spacer(.X, 16);
		if set_button("Back##back", .Link) { add_server_step(.Choose); }
		filler(.X);
		if (set_button(ifx busy then "Joining…##joinsrv" else "Join Server##joinsrv", .Primary, !busy) || res == .Submit && !busy) {
			input := ui.editor_text(*asv.invite_ed);
			if dc.invite_code_from_input(input) == "" {
				set_err("Please enter a valid invite link or invite code.");
			} else if net_action() {
				set_err("");
				join_start(input);
			}
		}
		spacer(.X, 16);
	}
}
#scope_export

