// Server Settings > Soundboard: the server's sounds with their emoji, volume and uploader, a preview,
// Edit and Delete, and Upload Sound (an mp3 or ogg of at most 512 KB and 5.2 s, with a name, a related
// emoji and a volume). The file comes from the picker or is dropped onto the dialog (fastcord-only). Its
// size and length are checked on a worker before anything is sent. Works the same on hosted servers.

// sound_settings_page draws the page (view_server_settings.jai page_body).
sound_settings_page :: (g: *dc.Guild, w: float32) {
	sbs.drawn_frame = app.frame;
	s := store();
	if sbs.fetched != g.id && net_action() {
		sbs.fetched = g.id;
		dc.soundboard_fetch_guild(app.client, g.id);
	}
	if sbs.modal != .None for * e: app.ui.events if !e.consumed && e.kind == .Key_Down && e.key == .Escape {
		e.consumed = true; // the dialog takes Escape before the layer
		modal_close();
	}
	perms := dc.guild_permissions(s, g.id);
	manage := dc.has_permission(perms, dc.PERM_MANAGE_GUILD_EXPRESSIONS);
	create := manage || dc.has_permission(perms, dc.PERM_CREATE_GUILD_EXPRESSIONS);
	sounds := dc.soundboard_list(s, g.id);
	slots := ifx on_hosted() then 48 else int.[8, 24, 36, 48][clamp(g.premium_tier, 0, 3)];
	set_para("sbhelp", "Upload custom sound reactions that anyone in this server can use. MP3 or OGG files, up to 512 KB and 5.2 seconds.", .Normal, 14, 18, T("--text-muted"));
	spacer(.Y, 16);
	top := row("sbtop");
	top.semantic_size = .[ui.pct(1), ui.px(38)];
	{ ui.parent(top); defer ui.pop_parent();
		if set_button("Upload Sound##sbupload", .Primary, create && sounds.count < slots) modal_open_upload("");
		filler(.X);
		label(tprint("% of % slots used", sounds.count, slots), .Medium, 14, T("--text-muted"), 18);
	}
	spacer(.Y, 20);
	if !sounds.count {
		set_para("sbempty", "No sounds yet.", .Medium, 16, 20, T("--text-muted"));
		return;
	}
	head := row("sbhead");
	head.semantic_size = .[ui.pct(1), ui.px(24)];
	{ ui.parent(head); defer ui.pop_parent();
		spacer(.X, 44);
		col_label("SOUND", w * 0.42);
		col_label("VOLUME", w * 0.16);
		col_label("UPLOADED BY", w * 0.25);
	}
	for snd: sounds {
		ui.id_scope(cast(u64) snd.id); defer ui.pop_seed();
		div := ui.box("div", .Draw_Background);
		div.semantic_size = .[ui.pct(1), ui.px(1)];
		div.style.bg = T("--border-subtle");
		r := row("sbrow");
		r.semantic_size = .[ui.pct(1), ui.px(52)];
		ui.parent(r); defer ui.pop_parent();
		pv := ui.box("play", .Clickable);
		pv.semantic_size = .[ui.px(28), ui.px(28)];
		pvs := ui.signal(pv);
		set_icon(pv, "play", ifx pvs.hovering then T("--interactive-icon-hover") else T("--interactive-icon-default"));
		if pvs.clicked sound_play_url(sound_url(app.client, snd.id), snd.volume * vs.soundboard_volume / 100);
		spacer(.X, 16);
		name_col := row("name");
		name_col.semantic_size = .[ui.px(w * 0.42), ui.px(52)];
		{ ui.parent(name_col); defer ui.pop_parent();
			if snd.emoji_id || snd.emoji_name { emoji_box("e", .{id = snd.emoji_id, name = snd.emoji_name}, 20); spacer(.X, 8); }
			label(ellipsize(snd.name, .Medium, 16, w * 0.42 - 40), .Medium, 16, T("--text-strong"), 20);
		}
		label(tprint("%\%", cast(int) (snd.volume * 100 + 0.5)), .Normal, 14, T("--text-default"), 18).semantic_size[0] = ui.px(w * 0.16);
		label(ellipsize(dc.user_name(s, snd.user_id, g.id, "Unknown"), .Normal, 14, w * 0.25 - 8), .Normal, 14, T("--text-default"), 18).semantic_size[0] = ui.px(w * 0.25);
		filler(.X);
		mine := snd.user_id == s.me;
		if manage || (create && mine) {
			if sbs.confirm_delete == snd.id {
				if set_button("Delete##sbdel", .Danger, !sbs.busy, 32) && net_action() {
					sbs.busy = true;
					dc.soundboard_delete(app.client, g.id, snd.id);
				}
				spacer(.X, 4);
				if set_button("Cancel##sbcancel", .Link, true, 32) sbs.confirm_delete = 0;
			} else {
				ed := icon("edit", "pencil", 18, T("--interactive-icon-default"), .Clickable);
				if ui.signal(ed).clicked modal_open_edit(snd);
				spacer(.X, 12);
				tr := icon("delete", "trash", 18, T("--interactive-icon-default"), .Clickable);
				if ui.signal(tr).clicked sbs.confirm_delete = snd.id;
			}
			spacer(.X, 8);
		}
	}
	if sbs.error {
		spacer(.Y, 12);
		set_para("sberr", sbs.error, .Normal, 14, 18, T("--text-feedback-critical"));
	}
}

// sound_settings_drop: files dropped while Server Settings is open go to the Soundboard page's dialog
// (opening Upload Sound when it isn't); true when the page took them.
sound_settings_drop :: (paths: []string) -> bool {
	if !paths.count || sbs.drawn_frame + 1 < app.frame return false;
	if sbs.modal == .Edit return true;
	if sbs.modal == .None modal_open_upload(paths[0]);
	else probe_start(paths[0]);
	return true;
}

// sound_settings_receive: the page's finished uploads, edits and deletes.
sound_settings_receive :: (r: *dc.Feature_Result) {
	sbs.busy = false;
	app.ui.animating = true;
	if r.ok {
		if r.op == .Sound_Delete sbs.confirm_delete = 0;
		else modal_close();
		set_error(*sbs.error, "");
		return;
	}
	msg := ifx r.status == -1 then "That file couldn't be read as an MP3 or OGG sound." else ifx r.status == -2 then "Sounds must be under 512 KB." else settings_result_error(r);
	set_error(ifx r.op == .Sound_Delete then *sbs.error else *sbs.modal_error, msg);
}

// sound_settings_modal: Upload Sound / Edit Sound, over the layer (views.jai overlays).
sound_settings_modal :: () {
	if sbs.modal == .None return;
	if !server_settings_is_open() || sbs.drawn_frame + 1 < app.frame { modal_close(); return; }
	probe_poll();
	scrim := ui.box("sb_modal_scrim", .Draw_Background | .Floating_X | .Floating_Y | .Overlay | .Clickable);
	scrim.semantic_size = .[ui.px(app.ui.window.x), ui.px(app.ui.window.y)];
	scrim.style.bg = .{0, 0, 0, 0.7};
	if ui.signal(scrim).clicked && !sbs.busy { modal_close(); return; }
	W :: cast(float32) 440;
	m := ui.box("sb_modal", .Draw_Background | .Floating_X | .Floating_Y | .Overlay | .Clickable);
	m.semantic_size = .[ui.px(W), ui.children()];
	m.fixed_pos = .{(app.ui.window.x - W) / 2, max(20.0, app.ui.window.y / 2 - 230)};
	m.layout_axis = .Y;
	m.style.bg = T("--background-surface-high");
	m.style.radius = all4(12);
	ui.signal(m);
	ui.parent(m); defer ui.pop_parent();
	upload := sbs.modal == .Upload;
	res: ui.Edit_Result;
	body := row("body");
	body.semantic_size = .[ui.pct(1), ui.children()];
	body.cross_align = .Start;
	{ ui.parent(body); defer ui.pop_parent();
		spacer(.X, 24);
		col := ui.box("col");
		col.semantic_size = .[ui.fill(), ui.children()];
		col.layout_axis = .Y;
		{ ui.parent(col); defer ui.pop_parent();
			spacer(.Y, 24);
			label(ifx upload then "Upload a Sound" else "Edit Sound", .Semibold, 20, T("--text-strong"), 24);
			spacer(.Y, 20);
			if upload {
				title("File");
				fr := row("filerow", .Draw_Background | .Draw_Border);
				fr.semantic_size = .[ui.pct(1), ui.px(44)];
				fr.style.bg = T("--input-background-default");
				fr.style.border = 1;
				fr.style.border_color = T("--input-border-default");
				fr.style.radius = all4(8);
				{ ui.parent(fr); defer ui.pop_parent();
					spacer(.X, 12);
					name := ifx sbs.path then path_filename(sbs.path) else "Drop a file here, or browse";
					label(ellipsize(name, .Normal, 14, W - 160), .Normal, 14, ifx sbs.path then T("--text-default") else T("--text-muted"), 18);
					filler(.X);
					if set_button("Browse##sbbrowse", .Secondary, !sbs.busy, 32) {
						paths := pick_files();
						if paths.count probe_start(paths[0]);
					}
					spacer(.X, 6);
				}
				if sbs.probing { spacer(.Y, 6); label("Checking the file…", .Normal, 12, T("--text-muted"), 16); }
				else if sbs.path && sbs.seconds > 0 { spacer(.Y, 6); label(tprint("% seconds", formatFloat(sbs.seconds, trailing_width = 1, zero_removal = .NO)), .Normal, 12, T("--text-muted"), 16); }
				spacer(.Y, 16);
			}
			title("Sound Name");
			res = set_input("sbname", *sbs.name, "Name your sound", max_runes = 32, autofocus = true);
			spacer(.Y, 16);
			title("Related Emoji");
			set_input("sbemoji", *sbs.emoji, "Paste an emoji (optional)", max_runes = 8);
			spacer(.Y, 16);
			title("Volume");
			vr := row("sbvolrow");
			vr.semantic_size = .[ui.pct(1), ui.px(20)];
			{ ui.parent(vr); defer ui.pop_parent();
				f := slider("sbvolume", sbs.volume / 100, ui.fill());
				if f >= 0 sbs.volume = cast(float32) cast(int) (f * 100 + 0.5);
				spacer(.X, 12);
				label(tprint("%\%", cast(int) sbs.volume), .Medium, 14, T("--text-default"), 18);
			}
			if sbs.modal_error {
				spacer(.Y, 12);
				set_para("sbmerr", sbs.modal_error, .Normal, 14, 18, T("--text-feedback-critical"));
			}
			spacer(.Y, 24);
		}
		spacer(.X, 24);
	}
	foot := row("foot", .Draw_Background);
	foot.semantic_size = .[ui.pct(1), ui.px(68)];
	foot.style.bg = T("--background-base-lower");
	foot.style.radius = .[0, 0, 12, 12];
	{ ui.parent(foot); defer ui.pop_parent();
		filler(.X);
		if set_button("Cancel##sbmcancel", .Link, !sbs.busy) modal_close();
		spacer(.X, 8);
		ready := !sbs.busy && !sbs.probing && (!upload || (sbs.path && sbs.seconds > 0));
		label_text := ifx sbs.busy then (ifx upload then "Uploading...##sbsubmit" else "Saving...##sbsubmit") else (ifx upload then "Upload##sbsubmit" else "Save Changes##sbsubmit");
		if (set_button(label_text, .Primary, ready) || (res == .Submit && ready)) && net_action() submit();
		spacer(.X, 16);
	}
}

#scope_file

Sound_Modal :: enum u8 { None; Upload; Edit; }

Sound_Probe :: struct {
	path: string; // heap
	seconds: float32; // out: the decoded length, 0 when it isn't a sound
	status: int; // out: 0 ok, -1 not mp3 / ogg or unreadable, -2 too large
}

sbs: struct {
	fetched: dc.Snowflake; // the guild whose list was fetched since the page opened
	drawn_frame: u64;
	confirm_delete: dc.Snowflake;
	busy: bool;
	error: string; // heap
	modal: Sound_Modal;
	editing: dc.Snowflake;
	name, emoji: ui.Editor;
	volume: float32 = 100;
	path: string; // heap: the checked file
	seconds: float32;
	probing: bool;
	probe: Sound_Probe;
	probe_thread: Thread;
	modal_error: string; // heap
};

col_label :: (text: string, w: float32) {
	label(text, .Bold, 12, T("--text-muted"), 16).semantic_size[0] = ui.px(w);
}

title :: (text: string) {
	label(text, .Semibold, 14, T("--text-strong"), 18);
	spacer(.Y, 8);
}

set_error :: (dst: *string, msg: string) {
	free(dst.*);
	dst.* = copy_string(msg);
}

modal_open_upload :: (path: string) {
	sbs.modal, sbs.editing, sbs.volume = Sound_Modal.Upload, 0, 100;
	ui.editor_set_text(*sbs.name, "");
	ui.editor_set_text(*sbs.emoji, "");
	set_error(*sbs.modal_error, "");
	app.ui.focus = 0;
	if path probe_start(path);
}

modal_open_edit :: (snd: *dc.Soundboard_Sound) {
	sbs.modal, sbs.editing, sbs.volume = Sound_Modal.Edit, snd.id, snd.volume * 100;
	ui.editor_set_text(*sbs.name, snd.name);
	ui.editor_set_text(*sbs.emoji, snd.emoji_name);
	set_error(*sbs.modal_error, "");
	app.ui.focus = 0;
}

modal_close :: () {
	sbs.modal = .None;
	set_error(*sbs.path, "");
	sbs.seconds = 0;
	app.ui.focus = 0;
}

// probe_start: reads and decodes the file on a worker (the UI thread never waits on disk).
probe_start :: (path: string) {
	if sbs.probing return;
	set_error(*sbs.probe.path, path);
	set_error(*sbs.modal_error, "");
	sbs.probing = true;
	thread_init(*sbs.probe_thread, (t: *Thread) -> s64 {
		p := cast(*Sound_Probe) t.data;
		p.seconds, p.status = 0, -1;
		data, ok := read_entire_file(p.path, log_errors = false);
		defer free(data);
		if !ok return 0;
		if data.count > dc.SOUNDBOARD_MAX_BYTES { p.status = -2; return 0; }
		if !dc.sound_mime(cast([]u8) data) return 0;
		pcm := media.decode_sound(cast([]u8) data, max_seconds = 10);
		defer array_free(pcm);
		p.seconds = cast(float32) pcm.count / 2 / audio.SAMPLE_RATE;
		if pcm.count p.status = 0;
		return 0;
	});
	sbs.probe_thread.data = *sbs.probe;
	thread_start(*sbs.probe_thread);
}

probe_poll :: () {
	if !sbs.probing return;
	if !thread_is_done(*sbs.probe_thread) { request_wake(platform.time_now() + 0.05); return; }
	thread_deinit(*sbs.probe_thread);
	sbs.probing = false;
	p := *sbs.probe;
	if p.status == -2 { set_error(*sbs.modal_error, "Sounds must be under 512 KB."); return; }
	if p.status != 0 { set_error(*sbs.modal_error, "That file couldn't be read as an MP3 or OGG sound."); return; }
	if p.seconds > dc.SOUNDBOARD_MAX_SECONDS + 0.05 { set_error(*sbs.modal_error, "Sounds must be 5.2 seconds or shorter."); return; }
	set_error(*sbs.path, p.path);
	sbs.seconds = p.seconds;
	if !trim(ui.editor_text(*sbs.name)) {
		// the file's name, as the official dialog fills it in
		base := path_strip_extension(path_filename(p.path));
		if base.count > 32 base.count = 32;
		ui.editor_set_text(*sbs.name, base);
	}
}

submit :: () {
	name := trim(ui.editor_text(*sbs.name));
	if name.count < 2 || name.count > 32 { set_error(*sbs.modal_error, "Sound names must be between 2 and 32 characters."); return; }
	emoji := trim(ui.editor_text(*sbs.emoji));
	if emoji && emoji_lookup_surrogates(emoji) < 0 { set_error(*sbs.modal_error, "The related emoji must be one emoji."); return; }
	gid := sbs.fetched;
	sbs.busy = true;
	set_error(*sbs.modal_error, "");
	if sbs.modal == .Upload dc.soundboard_upload(app.client, gid, sbs.path, name, emoji, 0, sbs.volume / 100);
	else dc.soundboard_edit(app.client, gid, sbs.editing, name, emoji, 0, sbs.volume / 100);
}
