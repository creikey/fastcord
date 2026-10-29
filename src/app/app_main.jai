UI_Rect :: ui.Rect;
UI_Mods :: ui.Mods;
UI_Editor :: ui.Editor;

App :: struct {
	theme: Theme;
	ui: Ui_State;
	last_time: float64;
	dt: float32; // this frame's step (app.ui.dt is 0 after the second, drawn UI pass)
	frame: u64;
	gpu_generation: int; // gfx.device_generation the textures were made on
	view: View_State;
	client: *dc.Client; // nil when offline (fixture / tests); a self-hosted server's while one of its guilds is open
	discord: *dc.Client; // Discord's own client (hosted.jai)
	needs_login: bool; // no token, or Discord rejected it: show the intro (view_login.jai)
	connect_pending: bool; // connect() waits for the previous client's teardown (teardown.jai)
	// The route the window reopens on, as the official client restores its last URL: the saved one
	// (settings.json), or -guild:/-channel: on live runs. The library's startup follows it; the view
	// opens it once READY is in.
	start_guild, start_channel: dc.Snowflake;
	start_pending: bool;
	launch_url: string; // an fc:// or discord:// link from the command line or a later launch, opened once READY is in
	login_error: string;
	offline_store: dc.Store;
	chats: Table(dc.Snowflake, Chat_State);
	chat_hover: dc.Snowflake;
	self_mute: bool;
	self_deaf: bool;
	voice_channel: dc.Snowflake;
	settings_open: bool;
	profile_user: dc.Snowflake;
	profile_webhook: string; // heap; set while the popout shows a webhook post's author, which is no user to fetch
	profile_above: bool; // popout opens above the anchor, left-aligned (own card from the user panel)
	profile_anchor: UI_Rect;
	profile_open_t: float32;
	pending_dm_user: dc.Snowflake;
	caret_reset_t: float64;
	reaction_target: dc.Snowflake; // message whose reaction picker is open
	ui_mods: UI_Mods; // modifier keys as of the latest event
	stats: bool;
	focused: bool; // window has focus (acks, app state)
	focus_gained: bool; // the window gained focus this frame (the "Window Focus" ack) // FASTCORD_STATS=1: print frame rate periodically
	focus_lost: bool; // the window lost focus this frame (a read channel's "NEW" marker goes stale)
	activity_at: float64; // the last mouseup / wheel / keypress, until IdleStore's 500 ms debounce reports it
	copy_selection: bool; // the message menu's "Copy": copy the selection after this pass
	focused_editor: *UI_Editor; // the text field that took keyboard input last frame (tests)
	expect_drawn: string; // script check: text the next frame must draw (tests)
	wake_at: float64; // earliest timed repaint requested this frame (caret blink, timers); 0 = none
	now_override_ms: s64; // -now: wall clock for timestamp formatting; 0 = real time
	focused_field: UI_Rect; // rect of the field box behind focused_editor (tests)
	net_actions: int; // network actions attempted from the UI (counted even offline; the sweep reads it)
	ext_actions: int; // URL opens / file dialogs asked for (headless never shows them)
	last_opened_url: string; // tests: the last URL open_url was asked to open
	no_render: bool; // headless sweep: build and lay out frames without drawing them
	sweep: bool; // headless sweep running: deterministic caret, no OS dialogs
}

// Gate for a user-triggered network action: true when online. Counts the
// attempt so the control sweep can tell an offline-inert action from a dead control.
net_action :: () -> bool {
	app.net_actions += 1;
	return app.client != null;
}

// The text field that takes keyboard input this frame (tests read it).
note_focused_editor :: (ed: *UI_Editor, field: *ui.Box) {
	app.focused_editor = ed;
	app.focused_field = field.rect;
}

// Every link a server sends lands here. Only web pages open: the OS would also launch `file:` apps,
// mount `smb:` shares and hand other schemes to their handlers.
open_url :: (url: string) {
	app.ext_actions += 1;
	free(app.last_opened_url);
	app.last_opened_url = "";
	if !begins_with(url, "https://") && !begins_with(url, "http://") return;
	app.last_opened_url = copy_string(url);
	if !platform.is_headless() platform.open_url(url);
}

pick_files :: (allocator := temp) -> []string {
	app.ext_actions += 1;
	if platform.is_headless() return .[];
	return platform.open_file_dialog(true, allocator);
}

// Ask for a repaint at time t without animating continuously.
request_wake :: (t: float64) {
	if app.wake_at == 0 || t < app.wake_at app.wake_at = t;
}

app: App;

Options :: struct {
	shot: string; // headless: render N frames and write a PNG here
	width: int;
	height: int;
	dpi: float32;
	theme: Theme_Name;
	script: string; // e2e script of injected input (tests/ui/*.txt)
	fixture: string; // offline: load the store from a recorded gateway fixture
	channel: string; // open this channel id at start (with fixture; on live runs the start route)
	guild: string; // live runs: the start route's guild
	live: float64; // headless: connect for real and run this many seconds before the shot
	now: s64; // unix seconds treated as "now" for timestamps (deterministic UI tests)
	sweep: string; // headless: dead-control sweep over the screens in this spec (tests/ui/sweep.txt)
	sweep_only: string; // -sweep-only:<screen> limits the sweep to one screen
	sweep_out: string; // report directory (default build/sweep)
	serve: string; // run a self-hosted server from this file instead of the app
	port: int;
	url: string; // an fc:// or discord:// link to open (the OS's URL handler passes it)
}

parse_options :: () -> Options {
	o := Options.{width = 1280, height = 720, dpi = 2, theme = .Dark, port = 4433};
	args := get_command_line_arguments();
	for a: array_view(args, 1) {
		v: string;
		flag :: (prefix: string) -> bool #expand {
			if !begins_with(`a, prefix) return false;
			`v = advance(`a, prefix.count);
			return true;
		}
		if flag("-shot:") {
			o.shot = v;
		} else if flag("-size:") {
			parts := split(v, "x",, temp);
			if parts.count == 2 {
				o.width = parse_int_prefix(parts[0]);
				o.height = parse_int_prefix(parts[1]);
			}
		} else if flag("-dpi:") {
			o.dpi = string_to_float(v);
		} else if flag("-theme:") {
			if v == {
			case "light"; o.theme = .Light;
			case "ash";   o.theme = .Ash;
			case "onyx";  o.theme = .Onyx;
			}
		} else if flag("-script:") {
			o.script = v;
		} else if flag("-fixture:") {
			o.fixture = v;
		} else if flag("-live:") {
			o.live = string_to_float64(v);
		} else if flag("-channel:") {
			o.channel = v;
		} else if flag("-guild:") {
			o.guild = v;
		} else if flag("-now:") {
			o.now = parse_int_prefix(v);
		} else if flag("-sweep:") {
			o.sweep = v;
		} else if flag("-sweep-only:") {
			o.sweep_only = v;
		} else if flag("-sweep-out:") {
			o.sweep_out = v;
		} else if flag("-serve:") {
			o.serve = v;
		} else if flag("-port:") {
			o.port = parse_int_prefix(v);
		} else if begins_with_nocase(a, "fc://") || begins_with_nocase(a, "discord:") {
			o.url = a;
		} else {
			bench_parse_flag(a);
		}
	}
	return o;
}

main :: () {
	dc.record_process_start(); // once, before the first client
	opt := parse_options();
	if opt.serve {
		serve_console();
		s, ok := serve.open(opt.serve);
		if !ok fail("could not open the server file %", opt.serve);
		if !serve.listen(s, opt.port) fail("could not listen on port % (TCP, and UDP for voice)", opt.port);
		first := serve.first_invite(s);
		if first say("Serving % on port %. Invite (put your address in place of localhost):\n%\n", opt.serve, s.listener.port, serve.invite_url(s, "localhost", s.listener.port, first));
		else say("Serving % on port %. No invite works any more: members make new ones from the Invite button.\n", opt.serve, s.listener.port);
		owner := serve.owner_invite(s);
		if owner say("Join with this one yourself first, to own the server (it works once):\n%\n", serve.invite_url(s, "localhost", s.listener.port, owner));
		say("Voice uses UDP on the same port number, so forward both TCP and UDP %.\n", s.listener.port);
		say("Webhooks take posts from curl and other tools pinned to this server: curl -k --pinnedpubkey % ...\n", serve.webhook_pin(s));
		say("Press Ctrl-C or close this console to stop the server.\n");
		while true sleep_milliseconds(1000 * 60 * 60);
	}
	headless := opt.shot != "" || bench.on;
	if !headless && !platform.instance_claim(app_state_dir(), opt.url) return; // the running one takes it
	app.launch_url = copy_string(opt.url);
	// macOS: Info.plist's CFBundleURLTypes; Linux: the desktop entry's MimeType (tools/package_linux.py).
	#if OS == .WINDOWS if !headless && FASTCORD_VERSION != "dev" {
		platform.url_handler_register("fc");
		platform.url_handler_register("discord", if_free = true);
	}
	sw, sh := settings_load(headless);
	if sw >= 400 && sh >= 300 {
		// an old save may be below today's minimum window size
		opt.width = max(sw, platform.MIN_WINDOW_W);
		opt.height = max(sh, platform.MIN_WINDOW_H);
	}
	ok := ifx headless then platform.init_headless(opt.width, opt.height, opt.dpi) else platform.init("Fastcord", opt.width, opt.height);
	if !ok fail("platform init failed");
	if !gfx.init() fail("gfx init failed");
	app.focused = true;
	locks.set_ui_thread();
	watchdog_start();
	voice_set_headless(headless);
	app.stats = env_var("FASTCORD_STATS") != "";
	fonts_load();
	theme_load(*app.theme, opt.theme);
	if app_theme_pending_set theme_load(*app.theme, app_theme_pending);
	ui.init(*app.ui, ui.Backend.{shape = ui_shape, split = emoji_split_text});
	view_init(*app.view);
	draw_inline_object = draw_custom_emoji;
	app.now_override_ms = opt.now * 1000;
	dc.store_init(*app.offline_store);
	if opt.fixture != "" {
		_, fok := dc.store_load_fixture(*app.offline_store, opt.fixture);
		if !fok fail("cannot load fixture %", opt.fixture);
		if opt.channel != "" {
			ch := dc.channel_get(*app.offline_store, dc.parse_snowflake(opt.channel));
			if ch select_channel(ch.guild_id, ch.id);
		}
	} else if opt.sweep != "" {
		// every screen loads its own fixture
	} else if !headless || opt.live > 0 {
		if opt.live > 0 && opt.channel != "" app.start_guild, app.start_channel = dc.parse_snowflake(opt.guild), dc.parse_snowflake(opt.channel);
		connect();
	}
	identity_start(keep = !headless);
	if (app.client == null || dc.client_logged_out(app.client)) && opt.fixture == "" app.needs_login = true;

	if headless && opt.sweep != "" exit(cast(s32) sweep_run(opt));
	if headless update_start();
	if headless && opt.live > 0 {
		// Real time: let the gateway connect and REST land, then capture.
		start := platform.time_now();
		while platform.time_now() - start < opt.live {
			platform.wait_events(1.0 / 60);
			frame();
			site_video_frame();
		}
		run_script(opt.script);
		bench_finish();
		if opt.shot != "" {
			pixels, w, h := gfx.read_pixels();
			gfx.write_png(opt.shot, pixels, w, h);
		}
		app_exit();
		return;
	}
	if headless {
		platform.set_time_override(0);
		run_script(opt.script);
		bench_finish();
		if opt.shot == "" return;
		// Settle animations, then capture.
		for i: 0..119 {
			platform.set_time_override(cast(float64)(i + 1) / 60);
			platform.wait_events(0);
			frame();
		}
		pixels, w, h := gfx.read_pixels();
		if !gfx.write_png(opt.shot, pixels, w, h) fail("write_png failed");
		return;
	}

	update_start();
	streamer_start();
	platform.set_exit_callback(() { settings_save(); app_exit(); });
	platform.set_frame_callback(frame);
	#if OS == .WINDOWS platform.set_window_hit_callback(window_hit);
	frame();
	while !platform.should_quit() {
		timeout: float64 = -1.0;
		if app.wake_at > 0 timeout = max(cast(float64) 0, app.wake_at - platform.time_now());
		platform.wait_events(timeout);
		frame();
	}
	if app.stats && app.focused_editor != null print("[input] \"%\"\n", ui.editor_text(app.focused_editor), to_standard_error = true);
	settings_save();
	app_exit();
}

// app_exit leaves voice and closes the gateway (code 1000) before the process ends; a dropped
// socket leaves the session resumable, so Discord keeps us in the call for minutes. Runs once (a
// Windows session end runs it from the window procedure, then the main loop ends).
app_exit :: () {
	if app_exited return;
	app_exited = true;
	voice_leave_channel();
	voice_shutdown();
	client_release(app.discord);
	for hosted if it.client client_release(it.client);
	app.client, app.discord = null, null;
	if e2e_db e2e.stop(e2e_db);
	teardown_wait();
	while e2e_db && !e2e.stopped(e2e_db) sleep_milliseconds(1);
}

app_exited: bool;

frame :: () {
	// Freed at the start, not the end: box texts and layouts of the last frame
	// (often tprint) stay valid until the next one, so scripted tests can
	// read them (click_text, expect_visible) without reading freed memory.
	reset_temporary_storage();
	watchdog_frame_begin();
	defer watchdog_frame_end();
	bench_frame_begin();
	defer bench_frame_end();
	now := platform.time_now();
	dt := cast(float32)(now - app.last_time);
	if app.last_time == 0 || dt <= 0 || dt > 0.1 dt = 1.0 / 60;
	app.last_time = now;
	app.dt = dt;
	app.frame += 1;
	app.wake_at = 0;
	app.focused_editor = null;

	t_poll := platform.time_now();
	if app.connect_pending && !teardown_busy() connect();
	if app.start_pending && app.client && app.client.store.ready {
		app.start_pending = false;
		ch := dc.channel_get(store(), app.start_channel);
		if ch select_channel(ch.guild_id, ch.id);
	}
	if app.launch_url && store().ready && !app.needs_login {
		open_launch_url(app.launch_url);
		free(app.launch_url);
		app.launch_url = "";
	}
	hosted_frame();
	encrypted_frame();
	if app.client != null {
		analytics_env_sync();
		dc.client_poll(app.client);
		handle_results();
		login_events();
		voice_frame();
		login_check_auth();
	}
	video_frame();
	req_frame();
	t_media := platform.time_now();
	watchdog_phase(.Media);
	sounds_frame();
	settings_frame();
	streamer_frame();
	images_receive();
	features_receive();
	notify_tick();
	t_ui := platform.time_now();
	watchdog_phase(.UI);
	attachments_frame();
	drops: [..]string;
	drops.allocator = temp;
	app.focus_gained = false;
	app.focus_lost = false;
	for e: platform.events() {
		if e.kind == {
		case .File_Drop;
			array_add(*drops, e.text);
		case .Drag_Enter; #through; case .Drag_Leave;
			attachments_drag_event(e);
		case .Tray_Mute;
			toggle_self_mute();
		case .Tray_Deafen;
			app.self_deaf = !app.self_deaf;
		case .Open_Url;
			platform.window_show();
			if e.text != "" {
				free(app.launch_url);
				app.launch_url = copy_string(e.text);
			}
		case .Focus_Gained; #through; case .Focus_Lost;
			app.focused = e.kind == .Focus_Gained;
			app.focus_gained = app.focused;
			app.focus_lost = !app.focused;
			if app.client != null dc.client_set_focused(app.client, app.focused);
		}
	}
	platform.set_tray_voice(app.self_mute || app.self_deaf, app.self_deaf);
	// one batch per drop (the 10-file cap applies to the batch)
	taken := drops.count > 0 && server_settings_is_open() && sound_settings_drop(drops); // Add Sound's file
	if !taken && drops.count > 0 && app.view.channel != 0 && !app.needs_login stage_paths(app.view.channel, drops, "drag_and_drop");
	evs := map_events(platform.events());
	for evs app.ui_mods = it.mods;
	for evs if it.kind == .Key_Down || it.kind == .Text app.caret_reset_t = now;
	for evs if it.kind == .Mouse_Up || it.kind == .Scroll || it.kind == .Text { app.activity_at = now; request_wake(now + 0.5); }
	if app.activity_at != 0 && now - app.activity_at >= 0.5 {
		app.activity_at = 0;
		if app.client dc.client_note_activity(app.client);
	}
	bench_pass_begin();
	ui.begin(platform.window_size(), dt, now, evs);
	build_ui();
	ui.end();
	bench_pass_end();
	// Cmd+C with a message selection (a focused field with its own selection copied first).
	// Runs after end(): the selection's boxes are collected during layout.
	for * e: app.ui.events {
		if e.consumed || e.kind != .Key_Down || e.key != .C || !(e.mods & PRIMARY_MOD) continue;
		if ui.has_selection() {
			clipboard_set(ui.selection_text());
			e.consumed = true;
		}
	}
	if app.copy_selection && ui.has_selection() clipboard_set(ui.selection_text());
	app.copy_selection = false;
	// The UI runs twice and only this second pass is drawn. A widget handles input after it has
	// declared what it shows (a text field's text, a list's scroll), so the first pass draws the state
	// from before the input. This pass gets no input and no time step: it draws the new state now
	// instead of on the next event.
	app.focused_editor = null;
	bench_pass_begin();
	ui.begin(platform.window_size(), 0, now, .[]);
	build_ui();
	cmds := ui.end();
	bench_pass_end();
	if app.expect_drawn != "" check_expect_drawn(cmds);

	t_render := platform.time_now();
	watchdog_phase(.Render);
	if !app.no_render {
		bench_render_begin();
		gfx.begin_frame(cast(gfx.Color)(tok(*app.theme, "--background-base-lowest")));
		{
			prof.zone("app.render");
			render(cmds);
		}
		{
			prof.zone("gfx.end_frame");
			gfx.end_frame();
		}
		if !platform.is_headless() watchdog_gfx();
		bench_render_end();
	}
	if sweep_hook != null sweep_hook(); // while this frame's boxes and temp strings are alive
	t_end := platform.time_now();

	platform.set_cursor(map_cursor(ui.cursor()));
	if ui.needs_frame() platform.request_frame();
	if app.ui.wake_at > 0 request_wake(app.ui.wake_at); // a scrollbar about to fade
	if app.stats {
		ms :: (a: float64, b: float64) -> string { return tprint("%", formatFloat((b - a) * 1000, trailing_width = 1, zero_removal = .NO)); }
		if t_end - t_poll > 0.025 {
			print("[slow] % ms: poll %, media %, ui %, render %\n", ms(t_poll, t_end), ms(t_poll, t_media), ms(t_media, t_ui), ms(t_ui, t_render), ms(t_render, t_end), to_standard_error = true);
		}
		if now - stats_reported_at > 2 {
			fps := cast(float64) (app.frame - stats_reported_frame) / (now - stats_reported_at);
			print("[stats] % fps animating=% at %\n", formatFloat(fps, trailing_width = 1, zero_removal = .NO), ui.needs_frame(), app.ui.animating_loc, to_standard_error = true);
			stats_reported_at = now;
			stats_reported_frame = app.frame;
		}
	}
}

key_by_name :: (name: string) -> platform.Key {
	if to_lower_copy(name,, temp) == {
	case "enter";
		return .Enter;
	case "escape";
		return .Escape;
	case "backspace";
		return .Backspace;
	case "delete";
		return .Delete;
	case "tab";
		return .Tab;
	case "left";
		return .Left;
	case "right";
		return .Right;
	case "up";
		return .Up;
	case "down";
		return .Down;
	case "home";
		return .Home;
	case "end";
		return .End;
	case "pageup";
		return .Page_Up;
	case "pagedown";
		return .Page_Down;
	case "[";
		return .Left_Bracket;
	case "]";
		return .Right_Bracket;
	case "/";
		return .Slash;
	}
	if name.count == 1 && name[0] >= #char "a" && name[0] <= #char "z" return cast(platform.Key) (cast(int) platform.Key.A + name[0] - #char "a");
	return .None;
}

// Strips surrounding double quotes and turns \n into newlines, \u202f into U+202F
// (fields() would split on it).
unquote :: (s: string) -> string {
	t := s;
	if t.count >= 2 && t[0] == #char "\"" && t[t.count - 1] == #char "\"" t = to_string(t.data + 1, t.count - 2);
	return replace(replace(t, "\\n", "\n",, temp), "\\u202f", "\u202f",, temp);
}

check_expect_drawn :: (cmds: []ui.Draw_Cmd) {
	want := app.expect_drawn;
	app.expect_drawn = "";
	for c: cmds {
		if c.kind == .Text && c.box != null && c.box.text == want {
			free(want);
			return;
		}
	}
	fail("expect_drawn failed: the frame did not draw \"%\"", want);
}

// Scripted input for headless e2e runs: one command per line, e.g.
//   click 120 300 / move 10 10 / type hello / key enter cmd / scroll 0 -100 / wait 30
run_script :: (path: string) {
	if path == "" return;
	// Not the temp allocator: frames free it, and `repeat` reuses the fields across frames.
	data, ok := read_entire_file(path, log_errors = false);
	if !ok fail("cannot read script %", path);
	t: float64 = 0.0;
	script_exec(split(data, "\n"), path, *t);
}

// Runs one script command; most inject input and run one frame.
script_command :: (path: string, f: []string, t: *float64) {
	num :: (s: string) -> float32 { v := string_to_float(s); return v; }
	if f[0] == {
	case "repeat";
		// repeat <n> <command...>
		for 1..cast(int) num(f[1]) script_command(path, array_view(f, 2), t);
		return;
	case "sweep";
		// sweep x0 y0 x1 y1 n: the mouse moves from one point to the other, one step per frame
		p0, p1 := Vector2.{num(f[1]), num(f[2])}, Vector2.{num(f[3]), num(f[4])};
		n := max(cast(int)(num(f[5])), 1);
		for i: 0..n - 1 {
			platform.inject_event(.{kind = .Mouse_Move, pos = p0 + (p1 - p0) * cast(float32)(i + 1) / cast(float32)(n)});
			script_frame(t);
		}
		return;
	case "bench";
		// bench <name>: frames from here to the next `bench`, `bench_off` or the end are measured (bench.jai)
		bench_section(f[1]);
		return;
	case "bench_off";
		bench_pause();
		return;
	case "move";
		ev := platform.Event.{kind = .Mouse_Move, pos = .{num(f[1]), num(f[2])}};
		if f.count > 3 && f[3] == "shift" ev.mods = .Shift; // move <x> <y> [shift]
		platform.inject_event(ev);
	case "click"; #through; case "dclick"; #through; case "tclick";
		n := ifx f[0] == "click" then 1 else (ifx f[0] == "dclick" then 2 else 3);
		p := Vector2.{num(f[1]), num(f[2])};
		mods: platform.Mod;
		if f.count > 3 && f[3] == "alt" mods = .Alt; // click <x> <y> [alt]
		platform.inject_event(.{kind = .Mouse_Move, pos = p});
		platform.inject_event(.{kind = .Mouse_Down, pos = p, button = .Left, click_count = n, mods = mods});
		platform.inject_event(.{kind = .Mouse_Up, pos = p, button = .Left, click_count = n});
	case "go_home";
		go_home();
	case "open";
		// open <channel id> | open unread_dm (the newest DM on the rail; works on live accounts too)
		id := dc.parse_snowflake(f[1]);
		if f[1] == "unread_dm" {
			dms := unread_dms();
			if dms.count > 0 id = dms[0];
		}
		ch := dc.channel_get(store(), id);
		if !ch fail("%: open: no channel %", path, f[1]);
		select_channel(ch.guild_id, ch.id);
	case "click_text"; #through; case "rclick_text"; #through; case "move_text";
		// clicks (right-clicks, hovers) the center of the last drawn box whose text is exactly the label
		want := unquote(join_args(f));
		b := find_text_box(want);
		if b == null script_fail(path, "%: no box with text \"%\"", f[0], want);
		p := Vector2.{(b.rect.x0 + b.rect.x1) / 2, (b.rect.y0 + b.rect.y1) / 2};
		platform.inject_event(.{kind = .Mouse_Move, pos = p});
		if f[0] != "move_text" {
			btn: platform.Mouse_Button = ifx f[0] == "click_text" then .Left else .Right;
			platform.inject_event(.{kind = .Mouse_Down, pos = p, button = btn, click_count = 1});
			platform.inject_event(.{kind = .Mouse_Up, pos = p, button = btn, click_count = 1});
		}
	case "expect_visible"; #through; case "expect_not_visible";
		want := unquote(join_args(f));
		vis := false;
		for b: app.ui.order {
			if b.text == want && (b.flags & .Draw_Text) && box_visible(b) {
				vis = true;
				break;
			}
		}
		if vis != (f[0] == "expect_visible") script_fail(path, "% failed: \"%\"", f[0], want);
		return;
	case "expect_in_window";
		// the box (by label or id) lies entirely inside the window, unclipped
		want := unquote(join_args(f));
		b := find_text_box(want);
		if b == null script_fail(path, "expect_in_window: no box \"%\"", want);
		r, v := b.rect, ui.visible_rect(b);
		w := app.ui.window;
		if r.x0 < 0 || r.y0 < 0 || r.x1 > w.x || r.y1 > w.y || v != r {
			script_fail(path, "expect_in_window \"%\" failed: rect % visible % window %", want, r, v, w);
		}
		return;
	case "expect_focus_input"; #through; case "expect_no_focus_input";
		has := app.focused_editor != null;
		if has != (f[0] == "expect_focus_input") script_fail(path, "% failed", f[0]);
		return;
	case "resize";
		platform.set_headless_size(cast(int) num(f[1]), cast(int) num(f[2]));
	case "in_voice";
		// in_voice <channel id>: show the voice panel as if joined (fixtures have no voice connection)
		app.voice_channel = dc.parse_snowflake(f[1]);
	case "developer_mode";
		// the account's Developer Mode (off in the fixtures): the menus' Copy ... ID items
		store().settings.developer_mode = true;
	case "theme";
		th, ok := theme_by_name(f[1]);
		if ok theme_load(*app.theme, th);
	case "show_login";
		// the login page (normally shown when there is no token)
		app.needs_login = true;
	case "login_state";
		// the login page in a given state, without a server (view_login.jai login_test_state)
		if !login_test_state(f[1]) script_fail(path, "login_state: unknown state \"%\"", f[1]);
	case "encrypted";
		// encrypted: the open DM has a session and encryption on, as after both sides accepted
		e := find_or_add(*ee.channels, app.view.channel);
		e.loaded, e.encrypted, e.has_session = true, true, true;
		return;
	case "pick";
		// pick gif <url> | pick sticker <id>: choose one in the open picker, as a click on it does
		if f[1] == "gif" gif_select(.{id = "1", url = f[2]}, false);
		else sticker_select(.{id = dc.parse_snowflake(f[2])}, false);
		return;
	case "open_url";
		// open_url <url>: what a click on a link to <url> does
		open_url(f[1]);
		return;
	case "expect_opened_url";
		want := unquote(join_args(f));
		if app.last_opened_url != want script_fail(path, "expect_opened_url failed\n  want \"%\"\n  got  \"%\"", want, app.last_opened_url);
		return;
	case "expect_profile_open"; #through; case "expect_no_profile_open";
		if (app.profile_user != 0) != (f[0] == "expect_profile_open") script_fail(path, "% failed", f[0]);
		return;
	case "expect_cursor";
		if tprint("%", ui.cursor()) != f[1] script_fail(path, "expect_cursor % failed: got %", f[1], ui.cursor());
		return;
	case "expect_theme";
		th, ok := theme_by_name(f[1]);
		if !ok || th != app.theme.name script_fail(path, "expect_theme % failed: got %", f[1], app.theme.name);
		return;
	case "rclick";
		p := Vector2.{num(f[1]), num(f[2])};
		platform.inject_event(.{kind = .Mouse_Move, pos = p});
		platform.inject_event(.{kind = .Mouse_Down, pos = p, button = .Right, click_count = 1});
		platform.inject_event(.{kind = .Mouse_Up, pos = p, button = .Right, click_count = 1});
	case "xbutton";
		// xbutton 1|2: the mouse's back / forward button
		b := ifx f[1] == "2" then platform.Mouse_Button.X2 else .X1;
		platform.inject_event(.{kind = .Mouse_Down, pos = .{640, 360}, button = b, click_count = 1});
		platform.inject_event(.{kind = .Mouse_Up, pos = .{640, 360}, button = b, click_count = 1});
	case "down";
		platform.inject_event(.{kind = .Mouse_Down, pos = .{num(f[1]), num(f[2])}, button = .Left, click_count = 1});
	case "up";
		platform.inject_event(.{kind = .Mouse_Up, pos = .{num(f[1]), num(f[2])}, button = .Left, click_count = 1});
	case "stage";
		// stage <path>...: what the "+" file picker returns
		stage_paths(app.view.channel, array_view(f, 1), "file_picker");
	case "drop";
		// drop <path>...: a drag and drop from Finder / Explorer (enter, files, leave)
		platform.inject_event(.{kind = .Drag_Enter, pos = .{640, 360}});
		for array_view(f, 1) platform.inject_event(.{kind = .File_Drop, text = it, pos = .{640, 360}});
		platform.inject_event(.{kind = .Drag_Leave});
	case "drag_enter";
		platform.inject_event(.{kind = .Drag_Enter, pos = .{640, 360}});
	case "drag_leave";
		platform.inject_event(.{kind = .Drag_Leave});
	case "paste_image";
		// paste_image <png>: the PNG goes on the (headless) clipboard, then Cmd/Ctrl+V
		data, ok := read_entire_file(f[1], log_errors = false,, temp);
		if !ok script_fail(path, "paste_image: can't read %", f[1]);
		platform.set_headless_clipboard_image(cast([]u8) data);
		platform.inject_event(.{kind = .Key_Down, key = .V, mods = platform.PRIMARY_MOD});
	case "paste_files";
		// paste_files <path>...: files copied in Finder / Explorer, then Cmd/Ctrl+V
		platform.set_headless_clipboard_files(array_view(f, 1));
		platform.inject_event(.{kind = .Key_Down, key = .V, mods = platform.PRIMARY_MOD});
	case "wait_attachments";
		// frames until every staged file has been read and thumbnailed (at most 10 s)
		start := current_time_monotonic();
		while attachments_busy() && to_float64_seconds(current_time_monotonic() - start) < 10 {
			script_frame(t);
			sleep_milliseconds(2);
		}
	case "expect_attachments";
		// expect_attachments <count> [<filename> [spoiler] [desc=<text>]]...  (in order)
		l := staged_list(app.view.channel).*;
		want := parse_int_prefix(f[1]);
		if l.count != want script_fail(path, "expect_attachments: want %, got %", want, l.count);
		i := 0;
		for k: 2..f.count - 1 {
			if f[k] == "spoiler" {
				if !l[i - 1].spoiler script_fail(path, "expect_attachments: % is not spoilered", l[i - 1].filename);
				continue;
			}
			if begins_with(f[k], "desc=") {
				if l[i - 1].description != advance(f[k], 5) script_fail(path, "expect_attachments: % description \"%\"", l[i - 1].filename, l[i - 1].description);
				continue;
			}
			if i >= l.count || l[i].filename != f[k] script_fail(path, "expect_attachments: #% want \"%\"", i, f[k]);
			if l[i].loading script_fail(path, "expect_attachments: % still loading", f[k]);
			i += 1;
		}
		return;
	case "upload_limit";
		// upload_limit <bytes>: override the plan's limit (too-large notice without a 10 MB fixture)
		att.limit_override = parse_int_prefix(f[1]);
		return;
	case "expect_notice";
		// expect_notice too_large | too_many | none
		want := Att_Notice.None;
		if f[1] == {
		case "too_large"; want = .Too_Large;
		case "too_many"; want = .Too_Many;
		}
		if att.notice != want script_fail(path, "expect_notice: want %, got %", want, att.notice);
		return;
	case "settings_reply";
		// settings_reply <request> <json>: a Server Settings load's reply (view_server_settings.jai)
		if f.count < 3 || !server_settings_script_reply(f[1], join(..array_view(f, 2), separator = " ",, temp)) script_fail(path, "settings_reply: bad request or JSON");
		return;
	case "hosted_saved";
		// hosted_saved <fc:// invite> <name...>: a server restored from settings.json under its saved name
		names: Table(string, string);
		inv := serve.parse_invite(f[1]);
		table_set(*names, inv.id_hex, join(..array_view(f, 2), separator = " ",, temp));
		hosted_restore(.[f[1]], *names);
		deinit(*names);
		return;
	case "type";
		platform.inject_event(.{kind = .Text, text = join_args(f)});
	case "burst";
		// Every character as a keystroke (key down, text, key up), all within one frame, like
		// typing faster than the frame rate.
		rest := unquote(join_args(f));
		while rest.count {
			ch := rest;
			r := utf8_next_character(*rest);
			ch.count -= rest.count; // the rune's bytes
			k := ifx r == #char " " then platform.Key.Space else key_by_name(ch);
			platform.inject_event(.{kind = .Key_Down, key = k});
			platform.inject_event(.{kind = .Text, text = ch});
			platform.inject_event(.{kind = .Key_Up, key = k});
		}
	case "key";
		// key <name> [shift] [cmd] [alt] [ctrl]
		ev := platform.Event.{kind = .Key_Down, key = key_by_name(f[1])};
		for m: array_view(f, 2) {
			if m == {
			case "shift";
				ev.mods |= .Shift;
			case "cmd";
				ev.mods |= platform.PRIMARY_MOD; // the platform's shortcut key, so scripts run anywhere
			case "alt";
				ev.mods |= .Alt;
			case "ctrl";
				ev.mods |= .Ctrl;
			}
		}
		platform.inject_event(ev);
	case "shot";
		if f.count < 2 return; // A bare shot: the run's -shot capture at the end covers it.
		pixels, w, h := gfx.read_pixels(temp);
		gfx.write_png(f[1], pixels, w, h);
		return;
	case "expect_selection";
		want := unquote(join_args(f));
		got := ui.selection_text();
		if got != want {
			fail("%: expect_selection failed\n  want \"%\"\n  got  \"%\"", path, want, got);
		}
		return;
	case "expect_drawn";
		// The frame run by the next command must draw this exact text (checked in frame()).
		app.expect_drawn = copy_string(unquote(join_args(f)));
		return;
	case "expect_input";
		// text of the field that currently has keyboard focus
		want := unquote(join_args(f));
		got := ifx app.focused_editor != null then ui.editor_text(app.focused_editor) else "<no focused field>";
		if got != want {
			fail("%: expect_input failed\n  want \"%\"\n  got  \"%\"", path, want, got);
		}
		return;
	case "expect_clipboard";
		want := unquote(join_args(f));
		got := platform.clipboard_get();
		if got != want {
			fail("%: expect_clipboard failed\n  want \"%\"\n  got  \"%\"", path, want, got);
		}
		return;
	case "failed_send";
		// failed_send <word>: our own message in the open channel whose send failed (fixtures can't send)
		s := store();
		msg := dc.new_message(s);
		msg.id = 1564185900000000000;
		msg.channel_id = app.view.channel;
		msg.author_id = s.me;
		msg.content = dc.clone_str(f[1], s.allocator);
		msg.failed = true;
		dc.insert_message(dc.message_list(s, app.view.channel), msg);
		s.changed += 1;
		return;
	case "focus";
		// focus out|in: the window loses or gains focus
		platform.inject_event(.{kind = ifx f[1] == "out" then .Focus_Lost else .Focus_Gained});
		return;
	case "incoming";
		// incoming <word>: another user's message arrives in the open channel, a minute after its newest
		s := store();
		ch := dc.channel_get(s, app.view.channel);
		if !ch return;
		msg := dc.new_message(s);
		msg.id = ch.last_message_id + (60_000 << 22);
		msg.channel_id = ch.id;
		for dc.messages_get(s, ch.id) if it.author_id != s.me msg.author_id = it.author_id;
		msg.content = dc.clone_str(f[1], s.allocator);
		dc.insert_message(dc.message_list(s, ch.id), msg);
		ch.last_message_id = msg.id;
		s.changed += 1;
		return;
	case "acked";
		// acked: the open channel is read up to its newest message (an ack, ours or MESSAGE_ACK's)
		s := store();
		ch := dc.channel_get(s, app.view.channel);
		if !ch return;
		rs := find_or_add(*s.read_states, ch.id);
		rs.channel_id = ch.id;
		rs.last_message_id = ch.last_message_id;
		s.changed += 1;
		return;
	case "net";
		// net hold|fail|ok: how offline requests end (requests.jai)
		if f[1] == {
		case "fail"; req_offline = .Fail;
		case "ok"; req_offline = .Ok;
		case; req_offline = .Hold;
		}
		return;
	case "history";
		// history loading|failed|older|gap: the open channel's message list as the network left it
		l := dc.message_list(store(), app.view.channel);
		if f[1] == "gap" {
			// history gap <n>: a jump showed all but the newest n messages, the rest are the present side
			l.gap_after = l.messages[max(0, l.messages.count - 1 - cast(int) num(f[2]))].id;
			return;
		}
		l.loading = f[1] == "loading" || f[1] == "older";
		l.failed = f[1] == "failed";
		l.loaded = f[1] != "loading";
		l.has_more_before = f[1] != "loading";
		if f[1] == "loading" for * l.messages dc.free_message(store(), it);
		if f[1] == "loading" l.messages.count = 0;
		return;
	case "scroll";
		platform.inject_event(.{kind = .Scroll, delta = .{num(f[1]), num(f[2])}, precise = true});
	case "gpu_reset"; // as after a driver update: a new GPU device, every texture empty
		gfx.simulate_device_loss();
	case "wait";
		if env_var("FASTCORD_FRAMES") { // real time: frames that save a PNG run long
			start := current_time_monotonic();
			while to_float64_seconds(current_time_monotonic() - start) < num(f[1]) / 60 script_frame(t);
			return;
		}
		for 1..max(cast(int) num(f[1]), 1) script_frame(t);
		return;
	case "after_ready";
		// after_ready <seconds>: real frames until READY plus that long (live runs: act at the same
		// point of the session as the official recording)
		while !app.client || !app.client.store.ready script_frame(t);
		if !site_video.ready_at site_video.ready_at = dc.now_ms();
		while dc.now_ms() - site_video.ready_at < cast(s64)(num(f[1]) * 1000) script_frame(t);
		return;
	case "mark";
		// mark <name>: an action window in the FASTCORD_RECORD recording
		if site_video.rec dc.recorder_mark(site_video.rec, "a", f[1]);
		return;
	case "settle";
		// Real seconds of 60 Hz frames, so network loads and image decodes can finish (live runs).
		start := current_time_monotonic();
		while to_float64_seconds(current_time_monotonic() - start) < num(f[1]) {
			script_frame(t);
			sleep_milliseconds(16);
		}
		return;
	case;
		script_fail(path, "unknown script command \"%\"", f[0]);
	}
	script_frame(t);
}

// FASTCORD_FRAMES=<dir>: scripts run in real time and ~15 frames a second are saved as
// <dir>/<ms>.png, ms on the FASTCORD_RECORD clock, for the site's side-by-side videos.
site_video: struct { rec: *dc.Recorder; last: s64; ready_at: s64; }

site_video_frame :: () {
	dir := env_var("FASTCORD_FRAMES");
	if !dir || !site_video.rec return;
	ms := dc.now_ms() - site_video.rec.start;
	if ms - site_video.last < 66 return;
	site_video.last = ms;
	pixels, w, h := gfx.read_pixels(temp);
	gfx.write_png(tprint("%/%.png", dir, ms), pixels, w, h);
}

script_frame :: (t: *float64) {
	if env_var("FASTCORD_FRAMES") {
		// real time (live runs set no time override): one frame per 1/60 s, so the video plays at 1x
		start := current_time_monotonic();
		platform.wait_events(0);
		frame();
		site_video_frame();
		left_ns := 1_000_000_000 / 60 - to_nanoseconds(current_time_monotonic() - start);
		if left_ns > 0 sleep_ns(left_ns);
		return;
	}
	t.* += 1.0 / 60;
	platform.set_time_override(t.*);
	decode_settle(); // decodes finish between frames, so runs are deterministic (outside the timing)
	platform.wait_events(0);
	start := current_time_monotonic();
	frame();
	// Measured frames keep a real 60 Hz cadence: the app idles between inputs, so CPU and GPU clocks
	// drop between frames, and back-to-back frames would report better latency than a user sees.
	if bench.measuring && !bench_unpaced() {
		left_ns := 1_000_000_000 / 60 - to_nanoseconds(current_time_monotonic() - start);
		if left_ns > 0 sleep_ns(left_ns);
	}
}

// FASTCORD_BENCH_UNPACED=1: measured frames run back to back. Timings are then meaningless,
// but the counters the budget checks are the same (tests/run_all.sh).
bench_unpaced :: () -> bool {
	if unpaced < 0 unpaced = ifx env_var("FASTCORD_BENCH_UNPACED") != "" then 1 else 0;
	return unpaced == 1;
}

// Last-built box whose text (label, or the id when it draws no text) is exactly want.
// Visible boxes win over hidden ones (a label scrolled out of its page).
find_text_box :: (want: string) -> *ui.Box {
	for < b: app.ui.order {
		if b.text == want && b.rect.x1 > b.rect.x0 && box_visible(b) return b;
	}
	for < b: app.ui.order {
		if b.text == want && b.rect.x1 > b.rect.x0 return b;
	}
	return null;
}

// Visible area of a box: clipped by its Clip ancestors and the window, and not
// under an overlay (popout, modal) unless it is part of one.
box_visible :: (b: *ui.Box) -> bool {
	r := ui.intersect(ui.visible_rect(b), .{0, 0, app.ui.window.x, app.ui.window.y});
	if r.x1 - r.x0 < 1 || r.y1 - r.y0 < 1 || b.opacity <= 0.01 return false;
	if !ui.in_overlay(b) && ui.overlay_at(.{(r.x0 + r.x1) / 2, (r.y0 + r.y1) / 2}) return false;
	return true;
}

script_fail :: (path: string, what: string, args: ..Any) {
	print("%: ", path, to_standard_error = true);
	fail(what, ..args);
}

script_t: float64; // headless clock for scripts run outside run_script (the sweep)

// Runs script lines, by default on the shared clock (the sweep replays per-screen setup this way).
script_exec :: (lines: []string, path: string, t := *script_t) {
	for line: lines {
		f := fields(line);
		defer array_free(f);
		if f.count == 0 || begins_with(f[0], "#") continue;
		script_command(path, f, t);
	}
}

// Token: $FASTCORD_TOKEN, else <state>/token (written by the login flow).
// Without one the client starts logged out and the login page shows.
connect :: () {
	if teardown_busy() {
		// The previous client is still shutting down; frame() retries when it is done.
		app.connect_pending = true;
		return;
	}
	app.connect_pending = false;
	state_dir := app_state_dir(context.allocator);
	make_directory_if_it_does_not_exist(state_dir, recursive = true);
	token := env_var("FASTCORD_TOKEN");
	if token == "" {
		data, ok := read_entire_file(tprint("%/token", state_dir), log_errors = false,, temp);
		if ok token = trim(data);
	}
	app.client = dc.client_create(.{token = copy_string(token), state_dir = state_dir, platform = dc.host_platform(), wakeup = (_: *void) { platform.request_frame(); },
		initial_guild_id = app.start_guild, initial_channel_id = app.start_channel});
	app.start_pending = app.start_channel != 0;
	app.discord = app.client;
	// FASTCORD_RECORD=<.secrets/raw/x.jsonl>: record our traffic like build/parity does (site videos)
	if env_var("FASTCORD_RECORD") {
		ok: bool;
		site_video.rec, ok = dc.recorder_open(env_var("FASTCORD_RECORD"));
		if ok dc.recorder_attach(site_video.rec, app.client, "a");
	}
	analytics_env_sync(force = true); // before the first event (gateway_connected)
	dc.client_start(app.client);
	if token == "" app.needs_login = true;
}

// Opens the DM with uid, creating it first if there is none: the request is tracked under
// dm_req(uid), so the control shows it pending and a failure shows the toast.
// True when the channel is open now.
open_dm_with :: (uid: dc.Snowflake, location: string) -> bool {
	if !req_begin(dm_req(uid)) return false;
	existing := dc.open_dm(app.client, uid, location);
	req_end();
	if existing != 0 { select_channel(0, existing); return true; }
	app.pending_dm_user = uid;
	return false;
}

dm_req :: (uid: dc.Snowflake) -> string { return tprint("dm:%", uid); }

// Every connection's results, with app.client pointing at the one they came on: a menu on a hosted server
// that isn't selected also waits on its replies.
handle_results :: () {
	keep := app.client;
	for c: connections() {
		app.client = c;
		handle_results_of(c);
		if app.client != c keep = app.client; // A result moved the view (an opened DM): keep that.
	}
	app.client = keep;
}

handle_results_of :: (c: *dc.Client) {
	for r: dc.client_take_results(c) {
		if r.op == {
		case .Open_Dm;
			if r.ok && r.id != 0 && app.pending_dm_user != 0 {
				select_channel(0, r.id);
				profile_full_close_for(app.pending_dm_user); // it waited with its Message button pending
				app.pending_dm_user = 0;
			}
		case .Invite;
			invite_receive(r);
		}
		req_result(r);
	}
}

#scope_file

stats_reported_at: float64; // FASTCORD_STATS: last [stats] line
stats_reported_frame: u64;
unpaced := -1; // bench_unpaced, read once

// Prints the message to stderr and exits with status 1.
fail :: (what: string, args: ..Any) {
	#if OS == .WINDOWS if serve_out { say(what, ..args); say("\n"); exit(1); }
	print(what, ..args, to_standard_error = true);
	print("\n", to_standard_error = true);
	exit(1);
}

// A release exe has no console, so -serve's invites would go nowhere: serve_console attaches to the
// terminal it was started from, or opens a console of its own. The runtime looked up its output handles at
// startup, before either existed, so print can't reach them; say writes to the console directly.
#if OS == .WINDOWS serve_out: Windows.HANDLE;

serve_console :: () {
	#if OS == .WINDOWS {
		if Windows.GetStdHandle(Windows.STD_OUTPUT_HANDLE) return; // a console build, or redirected
		if !Windows.AttachConsole(Windows.ATTACH_PARENT_PROCESS) Windows.AllocConsole();
		serve_out = Windows.GetStdHandle(Windows.STD_OUTPUT_HANDLE);
	}
}

say :: (format: string, args: ..Any) {
	s := tprint(format, ..args);
	#if OS == .WINDOWS if serve_out {
		n: u32;
		Windows.WriteFile(serve_out, s.data, xx s.count, *n, null);
		return;
	}
	write_string(s);
}

// Odin's strconv.parse_int: the leading digits ("12px" -> 12, "" -> 0).
parse_int_prefix :: (s: string) -> int { v := string_to_int(s); return v; }

// Script arguments after the command as written, spacing kept (fields are slices of one line).
join_args :: (f: []string) -> string {
	if f.count < 2 return "";
	last := f[f.count - 1];
	return .{last.data + last.count - f[1].data, f[1].data};
}

// Odin's strings.fields: the runs of non-space bytes (heap; free the array).
fields :: (line: string) -> [..]string {
	out: [..]string;
	i := 0;
	while i < line.count {
		while i < line.count && is_blank(line[i]) i += 1;
		start := i;
		while i < line.count && !is_blank(line[i]) i += 1;
		if i > start array_add(*out, to_string(line.data + start, i - start));
	}
	return out;
}

// Basic sleeps whole milliseconds; frame pacing needs finer.
#if OS == .WINDOWS {
	sleep_ns :: (ns: s64) { sleep_milliseconds(cast(s32) (ns / 1_000_000)); }
} else {
	usleep :: (us: u32) -> s32 #foreign libc;
	sleep_ns :: (ns: s64) { usleep(cast(u32) (ns / 1000)); }
}

is_blank :: (c: u8) -> bool { return c == #char " " || c == #char "\t" || c == #char "\n" || c == #char "\r" || c == 0x0b || c == 0x0c; }

