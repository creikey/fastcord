// What the fuzzer's `ui` target drives (src/tests/fuzz.jai): the app headless and offline, laying out but
// not drawing, on a fixture store that hostile events then change, with input going to whatever is on
// screen. netio.no_network and a private state directory keep it from reaching anything real.

#scope_export

fuzz_ui_start :: (state: string) {
	netio.no_network = true;
	app_state_override = state;
	make_directory_if_it_does_not_exist(state, recursive = true);
	assert(platform.init_headless(1280, 720, 2), "platform init failed");
	assert(gfx.init(), "gfx init failed");
	app.focused = true;
	locks.set_ui_thread();
	voice_set_headless(true);
	fonts_load();
	theme_load(*app.theme, .Dark);
	ui.init(*app.ui, ui.Backend.{shape = ui_shape, split = emoji_split_text});
	view_init(*app.view);
	draw_inline_object = draw_custom_emoji;
	app.sweep, app.no_render = true, true;
	dc.store_init(*app.offline_store);
	platform.set_time_override(0);
}

// fuzz_ui_reset starts an input from the fixture, and returns the IDs in it for events to aim at.
fuzz_ui_reset :: (fixture: string) -> []string {
	sweep_reset_state();
	dc.store_load_fixture_text(*app.offline_store, fixture);
	s := *app.offline_store;
	out: [..]string;
	out.allocator = temp;
	for * s.channels array_add(*out, tprint("%", it.id));
	for * s.guilds array_add(*out, tprint("%", it.id));
	for * l, id: s.messages {
		array_add(*out, tprint("%", id));
		for l.messages array_add(*out, tprint("%", it.id));
	}
	return out;
}

fuzz_ui_store :: () -> *dc.Store { return *app.offline_store; }

fuzz_ui_event :: (name: string, event: etf.Value, now: s64) {
	dc.store_apply_dispatch(*app.offline_store, name, event, now);
}

fuzz_ui_open :: (index: int) {
	s := *app.offline_store;
	if !s.channels.count return;
	i := 0;
	for * s.channels {
		if i == index % s.channels.count { select_channel(it.guild_id, it.id); return; }
		i += 1;
	}
}

fuzz_ui_command :: (line: string) {
	f := split(line, " ",, temp);
	script_command("fuzz", f, *script_t);
}

fuzz_ui_frame :: () { script_frame(*script_t); }
