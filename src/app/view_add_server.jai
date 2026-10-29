// The guild rail's "Add a Server" modal (the client's CreateGuildModal):
//   Create Your Server -> "Create My Own" or a template -> Tell Us More (friends / community, or skip)
//                         -> Customize Your Server (name) -> Create
//                      -> "Join a Server" -> invite link / code -> Join Server
// Create posts /guilds (dc.create_guild with the template's channels); the
// library opens the new guild when its GUILD_CREATE arrives and the view follows.
// Join resolves and accepts the invite on a worker thread (dc.join_invite blocks);
// the library opens the guild at the invite's channel when its GUILD_CREATE
// arrives and the view follows. "Discover" opens discord.com/servers.

Add_Server_Step :: enum u8 {
	Closed;
	Choose;
	Purpose;
	Create;
	Join;
}

add_server_reset_for_test :: () {
	ui.editor_set_text(*asv.name_ed, "");
	ui.editor_set_text(*asv.invite_ed, "");
	set_err("");
	asv.step = .Closed;
	asv.creating = false;
	asv.open_guild = 0;
	asv.job = null; // a test job (none offline) would be leaked, not freed under a worker
}

add_server_is_open :: () -> bool { return asv.step != .Closed; }

add_server_open :: () { add_server_step(.Choose); }

// The client's invite accept errors by code (its d() beside the join failure titles).
invite_error_text :: (code: int) -> string {
	if code == {
	case 30001; return L("You must leave a server first to join.");
	case 30019; return L("This server is currently full. Please try again later.");
	case 50095; return L("This server is not available in your location.");
	case 40069; return L("Invites are currently paused for this server. Please try again later.");
	case 20024; return L("You can't join this server because of your age group.");
	case 20086; return L("Confirm your age to join this server.");
	case 40007; return L("You are banned from this server.");
	}
	return L("Unable to accept invite");
}

// add_server_join_with opens Join a Server filled in with an invite, for the user to confirm.
add_server_join_with :: (invite: string) {
	add_server_step(.Join);
	ui.editor_set_text(*asv.invite_ed, invite);
}

// Rail "Discover": server discovery lives on the website (no in-app directory).
discover_open :: () { open_url("https://discord.com/servers"); }

// Releasing a client (logging out, switching accounts) while a join is in flight on it: the worker
// still uses the client, so its teardown waits for the join (add_server_join_wait, teardown.jai) and
// the join's result is dropped.
add_server_take_join :: (c: *dc.Client) -> *void {
	j := asv.job;
	if j == null || j.client != c return null;
	asv.job = null;
	return j;
}

add_server_join_wait :: (p: *void) {
	if p == null return;
	j := cast(*Join_Job) p;
	while atomic_load(*j.state) != JOIN_DONE sleep_milliseconds(10);
	free_job(j);
}

// Per frame (overlay pass): finished requests, pending navigation, then the modal. Create and Join
// (a Discord invite) are Discord's while a hosted server is open; an fc:// invite joins in hosted.jai.
add_server_overlay :: () {
	keep, g0 := app.client, app.view.guild;
	if app.discord app.client = app.discord;
	add_server_frame();
	if app.view.guild == g0 app.client = keep; // unless it opened the new server
}

#scope_file

add_server_frame :: () {
	j := asv.job;
	if j != null && atomic_load(*j.state) == JOIN_DONE {
		asv.job = null;
		if j.res.ok && j.res.guild_id != 0 {
			asv.open_guild = j.res.guild_id;
			asv.step = .Closed;
			ui.editor_set_text(*asv.invite_ed, "");
		} else if j.res.status == 0 {
			set_err(L("Couldn't reach Discord. Try again."));
		} else if j.res.captcha {
			set_err(tr(CAPTCHA_TEXT));
		} else if j.res.error_code == 10006 || j.res.status == 404 {
			set_err(L("The invite is invalid or has expired."));
		} else {
			set_err(invite_error_text(j.res.error_code));
		}
		free_job(j);
	}
	if asv.open_guild != 0 && app.client != null && dc.guild_get(store(), asv.open_guild) != null {
		// the library opened it on GUILD_CREATE (route = the invite's channel); follow
		// it, or select it here when we were a member already (no GUILD_CREATE)
		locks.lock(*app.client.route_mu);
		g, ch := app.client.route_guild, app.client.route_channel;
		locks.unlock(*app.client.route_mu);
		if g == asv.open_guild select_channel(g, ch);
		else select_guild(asv.open_guild);
		asv.open_guild = 0;
	}
	if asv.creating && app.client != null && !app.client.pending_guild_create {
		// the library selected the new guild on GUILD_CREATE (dc.select_channel); follow it
		locks.lock(*app.client.route_mu);
		g, ch := app.client.route_guild, app.client.route_channel;
		locks.unlock(*app.client.route_mu);
		app.view.guild, app.view.channel = g, ch;
		table_set(*app.view.last_channel, g, ch);
		asv.creating = false;
		asv.step = .Closed;
	}
	if asv.step != .Closed add_server_modal();
}

#scope_export

centered :: (id: string, text: string, font: Font_Id, size: float32, line_h: float32, color: ui.Color) {
	b := set_para(id, text, font, size, line_h, color);
	b.style.text_align = .Center;
}

#scope_file

JOIN_RUNNING :: 0;
JOIN_DONE :: 1;

Join_Job :: struct {
	client: *dc.Client;
	input: string; // the invite field as typed (inputValue)
	member_of: []dc.Snowflake; // guilds we're in when the join started (user_is_member)
	state: int; // atomic: JOIN_*
	res: dc.Invite_Result;
}

asv: struct {
	step: Add_Server_Step;
	name_ed: ui.Editor;
	invite_ed: ui.Editor;
	error: string; // heap
	creating: bool; // POST /guilds sent; waiting for its GUILD_CREATE
	job: *Join_Job; // join in flight
	open_guild: dc.Snowflake; // joined: select it once it is in the store
	step_ms: s64; // when the current step was shown (nuo_transition seconds_on_from_step)
	template: int; // into dc.GUILD_TEMPLATES
	community: bool; // "For a club or community"
};

add_server_step :: (st: Add_Server_Step) {
	c := ifx app.discord then app.discord else app.client; // the rail's + while a hosted server is open too
	if c != null {
		if st == {
		case .Choose;
			dc.guild_add_step(c, .Templates, ifx asv.step == .Closed then 0 else asv.step_ms);
		case .Join;
			dc.guild_add_step(c, .Join, asv.step_ms);
		}
	}
	asv.step = st;
	asv.step_ms = dc.now_ms();
	set_err("");
	app.ui.focus = 0; // the step's field takes focus
}

set_err :: (s: string) {
	free(asv.error);
	asv.error = copy_string(s);
}

free_job :: (j: *Join_Job) {
	free(j.input);
	array_free(j.member_of);
	free(j.res.code);
	free(j);
}

join_start :: (input: string) {
	j := New(Join_Job);
	j.client = app.client;
	j.input = copy_string(input);
	j.member_of = array_copy(store().guild_order);
	asv.job = j;
	dc.spawn(j, (j: *Join_Job) {
		j.res = dc.join_invite(j.client, j.input, member_of = j.member_of);
		reset_temporary_storage();
		atomic_swap(*j.state, JOIN_DONE); // j may be freed from here (add_server_join_wait)
		platform.request_frame();
	});
}

add_server_modal :: () {
	scrim := ui.box("addsrv_scrim", .Draw_Background | .Clickable | .Floating_X | .Floating_Y | .Overlay);
	scrim.semantic_size = .[ui.px(app.ui.window.x), ui.px(app.ui.window.y)];
	scrim.style.bg = .{0, 0, 0, 0.7};
	if ui.signal(scrim).clicked {
		asv.step = .Closed;
		return;
	}
	W :: 440;
	d := ui.box("addsrv", .Draw_Background | .Draw_Border | .Floating_X | .Floating_Y | .Overlay | .Clickable);
	d.semantic_size = .[ui.px(W), ui.children()];
	d.fixed_pos = .{(app.ui.window.x - W) / 2, max((app.ui.window.y - (d.rect.y1 - d.rect.y0)) / 2, 16)};
	d.style.bg = T("--modal-background");
	d.style.border_color = T("--border-subtle");
	d.style.border = 1;
	d.style.radius = all4(12);
	d.layout_axis = .Y;
	ui.signal(d);
	{ ui.parent(d); defer ui.pop_parent();
		x := ui.box("close", .Clickable | .Floating_X | .Floating_Y);
		x.semantic_size = .[ui.px(24), ui.px(24)];
		x.fixed_pos = .{W - 16 - 24, 16};
		xs := ui.signal(x);
		set_icon(x, "x-large", ifx xs.hovering then T("--interactive-icon-hover") else T("--interactive-icon-default"));
		if xs.clicked { asv.step = .Closed; }
		if asv.step == {
		case .Choose;
			step_choose();
		case .Purpose;
			step_purpose();
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


step_choose :: () {
	inset_begin(16, 0);
	spacer(.Y, 24);
	centered("title", L("Create Your Server"), .Bold, 24, 30, T("--text-strong"));
	spacer(.Y, 8);
	centered("sub", L("Your server is where you and your friends hang out. Make yours and start talking."), .Normal, 16, 20, T("--text-subtle"));
	spacer(.Y, 24);
	for t: dc.GUILD_TEMPLATES {
		if it_index == 1 {
			spacer(.Y, 8);
			label(L("START FROM A TEMPLATE"), .Bold, 12, T("--text-default"), 16);
			spacer(.Y, 8);
		}
		if it_index > 1 spacer(.Y, 8);
		b := choice_row(tprint("tpl%", it_index), t.icon, t.label, ifx it_index then 56.0 else 64.0);
		if ui.signal(b).clicked {
			asv.template = it_index;
			add_server_step(.Purpose);
			s := store();
			u := dc.user_get(s, s.me);
			ui.editor_set_text(*asv.name_ed, ifx u then tprint(L("%'s server"), u.username) else L("My server"));
		}
	}
	inset_end(16, 0);
	spacer(.Y, 24);
	foot := ui.box("foot", .Draw_Background);
	foot.semantic_size = .[ui.pct(1), ui.children()];
	foot.layout_axis = .Y;
	foot.style.bg = T("--modal-footer-background");
	foot.style.radius = .[0, 0, 12, 12];
	{ ui.parent(foot); defer ui.pop_parent();
		inset_begin(16, 16);
		centered("have", L("Have an invite already?"), .Semibold, 20, 24, T("--text-strong"));
		spacer(.Y, 8);
		jr := row("jr");
		jr.semantic_size = .[ui.pct(1), ui.px(38)];
		{ ui.parent(jr); defer ui.pop_parent();
			b := ui.box(L("Join a Server##join"), .Clickable | .Draw_Background | .Draw_Text | .Hot_Animation);
			b.semantic_size = .[ui.pct(1), ui.px(38)];
			b.style.radius = all4(8);
			b.style.font = F(.Medium);
			b.style.font_size = 14;
			b.style.text_align = .Center;
			b.style.bg = T("--background-mod-strong");
			b.style.bg_hot = with_alpha(b.style.bg, 0.85);
			b.style.text_color = T("--text-strong");
			if ui.signal(b).clicked { add_server_step(.Join); }
		}
		inset_end(16, 16);
	}
}

// A row of the template list or the purpose step: icon, label, chevron.
choice_row :: (id: string, icon_name: string, text: string, h: float32) -> *ui.Box {
	b := row(id, .Clickable | .Draw_Background | .Draw_Border | .Hot_Animation);
	b.semantic_size = .[ui.pct(1), ui.px(h)];
	b.style.radius = all4(8);
	b.style.border = 1;
	b.style.border_color = T("--border-subtle");
	b.style.bg = T("--background-base-low");
	b.style.bg_hot = T("--background-mod-normal");
	b.cross_align = .Center;
	ui.parent(b); defer ui.pop_parent();
	spacer(.X, 16);
	icon("i", icon_name, 32, T("--text-brand"));
	spacer(.X, 12);
	label(text, .Semibold, 16, T("--text-strong"), 20);
	filler(.X);
	icon("chev", "chevron-small-right", 20, T("--interactive-icon-default"));
	spacer(.X, 12);
	return b;
}

// Tell Us More About Your Server: the answer only goes to telemetry (is_community_intent).
step_purpose :: () {
	inset_begin(16, 0);
	spacer(.Y, 24);
	centered("title", L("Tell Us More About Your Server"), .Bold, 24, 30, T("--text-strong"));
	spacer(.Y, 8);
	centered("sub", L("In order to help you with your setup, is your new server for just a few friends or a larger community?"), .Normal, 16, 20, T("--text-subtle"));
	spacer(.Y, 24);
	if ui.signal(choice_row("club", "group", L("For a club or community"), 64)).clicked { asv.community = true; add_server_step(.Create); }
	spacer(.Y, 8);
	if ui.signal(choice_row("friends", "friends", L("For me and my friends"), 64)).clicked { asv.community = false; add_server_step(.Create); }
	spacer(.Y, 16);
	sk := ui.box("skip", .Wrap_Text);
	sk.semantic_size = .[ui.pct(1), ui.text_size()];
	sk.style.text_align = .Center;
	ui.set_spans(sk, ui.Span.[.{text = L("Not sure? You can "), font = F(.Normal), size = 14, color = T("--text-subtle")},
		.{text = L("skip this question"), font = F(.Normal), size = 14, color = T("--text-link"), id = 1}, .{text = L(" for now."), font = F(.Normal), size = 14, color = T("--text-subtle")}]);
	if sk.prev_layout && ui.mouse_over(sk) && ui.span_at(sk.prev_layout, app.ui.mouse) == 1 app.ui.span_cursor = .Pointer;
	if sk.prev_layout for e: app.ui.events {
		if e.kind != .Mouse_Up || e.button != .Left || e.consumed || ui.span_at(sk.prev_layout, e.pos) != 1 continue;
		asv.community = false;
		add_server_step(.Create);
	}
	inset_end(16, 0);
	spacer(.Y, 24);
	{ ui.parent(footer_begin()); defer ui.pop_parent();
		spacer(.X, 16);
		if set_button(L("Back##back"), .Link) { add_server_step(.Choose); }
		filler(.X);
	}
}

footer_begin :: () -> *ui.Box {
	foot := row("foot", .Draw_Background);
	foot.semantic_size = .[ui.pct(1), ui.px(70)];
	foot.style.bg = T("--modal-footer-background");
	foot.style.radius = .[0, 0, 12, 12];
	return foot;
}

step_create :: () {
	inset_begin(16, 0);
	spacer(.Y, 24);
	centered("title", L("Customize Your Server"), .Bold, 24, 30, T("--text-strong"));
	spacer(.Y, 8);
	centered("sub", L("Give your new server a personality with a name. You can always change it later."), .Normal, 16, 20, T("--text-subtle"));
	spacer(.Y, 24);
	label(L("SERVER NAME"), .Bold, 12, T("--text-default"), 16);
	spacer(.Y, 8);
	res := set_input("name", *asv.name_ed, "", max_runes = 100, autofocus = true);
	spacer(.Y, 8);
	set_para("terms", L("By creating a server, you agree to Discord's Community Guidelines."), .Normal, 12, 16, T("--text-muted"));
	if asv.error != "" {
		spacer(.Y, 8);
		set_para("err", asv.error, .Normal, 14, 18, T("--text-feedback-critical"));
	}
	inset_end(16, 0);
	spacer(.Y, 24);
	name := trim(ui.editor_text(*asv.name_ed));
	{ ui.parent(footer_begin()); defer ui.pop_parent();
		spacer(.X, 16);
		if set_button(L("Back##back"), .Link) { add_server_step(.Purpose); }
		filler(.X);
		ok := name != "" && !asv.creating;
		if (set_button(ifx asv.creating then L("Creating…##create") else L("Create##create"), .Primary, ok) || res == .Submit && ok) && net_action() {
			dc.create_guild(app.client, name, template = dc.GUILD_TEMPLATES[asv.template], community = asv.community, step_shown_ms = asv.step_ms);
			asv.creating = true;
		}
		spacer(.X, 16);
	}
}

step_join :: () {
	inset_begin(16, 0);
	spacer(.Y, 24);
	centered("title", L("Join a Server"), .Bold, 24, 30, T("--text-strong"));
	spacer(.Y, 8);
	centered("sub", L("Enter an invite below to join an existing server"), .Normal, 16, 20, T("--text-subtle"));
	spacer(.Y, 24);
	lr := row("lr");
	lr.semantic_size = .[ui.pct(1), ui.px(16)];
	{ ui.parent(lr); defer ui.pop_parent();
		label(L("INVITE LINK"), .Bold, 12, ifx asv.error != "" then T("--text-feedback-critical") else T("--text-default"), 16);
		label(" *##req", .Bold, 12, T("--text-feedback-critical"), 16);
		if asv.error != "" { label(tprint(" - %##err", asv.error), .Medium, 12, T("--text-feedback-critical"), 16); }
	}
	spacer(.Y, 8);
	res := set_input("invite", *asv.invite_ed, "https://discord.gg/hTKzmak", autofocus = true);
	spacer(.Y, 16);
	label(L("INVITES SHOULD LOOK LIKE"), .Bold, 12, T("--text-default"), 16);
	spacer(.Y, 8);
	for ex: (string.["hTKzmak", "https://discord.gg/hTKzmak", "https://discord.gg/cool-people"]) {
		label(ex, .Normal, 14, T("--text-default"), 20);
	}
	inset_end(16, 0);
	spacer(.Y, 24);
	busy := asv.job != null;
	{ ui.parent(footer_begin()); defer ui.pop_parent();
		spacer(.X, 16);
		if set_button(L("Back##back"), .Link) { add_server_step(.Choose); }
		filler(.X);
		if (set_button(ifx busy then L("Joining…##joinsrv") else L("Join Server##joinsrv"), .Primary, !busy) || res == .Submit && !busy) {
			input := ui.editor_text(*asv.invite_ed);
			if begins_with(trim(input), "fc://") {
				ok, why := hosted_join(trim(input));
				if ok {
					add_server_step(.Closed);
					ui.editor_set_text(*asv.invite_ed, "");
				} else {
					set_err(why);
				}
			} else if dc.invite_code_from_input(input) == "" {
				set_err(L("Please enter a valid invite link or invite code."));
			} else if net_action() {
				set_err("");
				join_start(input);
			}
		}
		spacer(.X, 16);
	}
}
