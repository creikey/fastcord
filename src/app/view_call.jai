// The call view: everyone in a voice channel (or a DM call) as 16:9 tiles on
// black, laid out in the grid that makes them largest; a camera or stream
// shows its video, otherwise the avatar on the user's banner color, with a green
// border while speaking. Go Live streams get their own tile ("Watch Stream"
// until watched). Clicking a tile focuses it; the bar below holds the mic,
// camera, screen share and disconnect buttons.

CALL_GAP :: 8;
CALL_PAD :: 16;
CALL_BAR_H :: 80;

Call_Tile :: struct {
	user: dc.Snowflake;
	stream: bool;
	absent: bool; // a DM's member who isn't in the call: dimmed, with Ring
}

// In-call emoji (VOICE_CHANNEL_EFFECT_SEND): each floats up over its sender's tile for EFFECT_S.
EFFECT_S :: 3.0;
EFFECT_BAR :: string.["😂", "🔥", "👏", "❤️", "😮", "😢", "🎉", "👍"];
Call_Effect :: struct { user: dc.Snowflake; emoji: dc.Emoji; start: float64; }
call_effects: [..]Call_Effect; // emoji names on the heap
effect_bar_open: bool;

call_effect_show :: (user: dc.Snowflake, e: dc.Emoji) {
	if call_effects.count >= 16 { free(call_effects[0].emoji.name); array_ordered_remove_by_index(*call_effects, 0); }
	em := e;
	em.name = copy_string(e.name);
	array_add(*call_effects, .{user, em, app.ui.time});
}

// call_view fills the parent: the grid for channel cid and its control bar.
call_view :: (cid: dc.Snowflake) {
	s := store();
	for < call_effects if app.ui.time - it.start >= EFFECT_S { free(it.emoji.name); array_ordered_remove_by_index(*call_effects, it_index); }
	tiles: [..]Call_Tile;
	tiles.allocator = temp;
	ids: [..]dc.Snowflake;
	ids.allocator = temp;
	for vs, uid: s.voice_states if vs.channel_id == cid array_add(*ids, uid);
	quick_sort(ids, (a: dc.Snowflake, b: dc.Snowflake) -> s64 { return ifx a < b then -1 else ifx a > b then 1 else 0; });
	// streams first, then cameras / avatars (ours leads each group); a stage's audience goes in a strip below
	ch := dc.channel_get(s, cid);
	stage := ch && ch.kind == .Guild_Stage_Voice;
	audience: [..]dc.Snowflake;
	audience.allocator = temp;
	for pass: 0..1 for ids {
		vs := table_find_pointer(*s.voice_states, it);
		if stage && vs.suppress { if pass == 1 array_add(*audience, it); continue; }
		if pass == 0 && (vs.self_stream || (it == s.me && screen_sharing())) array_add(*tiles, .{user = it, stream = true});
		if pass == 1 array_add(*tiles, .{user = it});
	}
	// a DM call also shows who isn't in it, to ring them
	if ch && ch.guild_id == 0 && app.voice_channel == cid for ch.recipient_ids if !array_find(ids, it) array_add(*tiles, .{user = it, absent = true});
	if cv.focus_user {
		found := false;
		for tiles if it.user == cv.focus_user && it.stream == cv.focus_stream found = true;
		if !found cv.focus_user = 0;
	}
	if cv.focus_user { tiles.count = 0; array_add(*tiles, .{user = cv.focus_user, stream = cv.focus_stream}); }

	root := ui.box("call", .Draw_Background | .Clip);
	root.semantic_size = .[ui.fill(), ui.fill()];
	root.layout_axis = .Y;
	root.style.bg = .{0, 0, 0, 1};
	{ ui.parent(root); defer ui.pop_parent();
		area := ui.box("grid");
		area.semantic_size = .[ui.pct(1), ui.fill()];
		// the area's size from the last pass (the window's, before the first layout)
		aw := area.rect.x1 - area.rect.x0;
		ah := area.rect.y1 - area.rect.y0;
		if aw <= 0 || ah <= 0 {
			aw = app.ui.window.x - RAIL_W - app.view.sidebar_w;
			ah = app.ui.window.y - HEADER_H - CALL_BAR_H;
		}
		{ ui.parent(area); defer ui.pop_parent();
			if !tiles.count {
				spacer(.Y, ah / 2 - 10);
				r := row("empty");
				r.semantic_size = .[ui.pct(1), ui.px(20)];
				ui.parent(r); defer ui.pop_parent();
				filler(.X);
				label(ifx stage && audience.count then L("No one is speaking yet") else L("No one's here yet"), .Medium, 16, T("--text-muted"), 20);
				filler(.X);
			} else {
				place_tiles(tiles, aw, ah);
			}
		}
		if stage {
			stage_invite_banner(ch);
			if audience.count stage_audience(audience);
		}
		call_controls(cid);
	}
}

// DM / group DM: the call above the chat while we are in it.
dm_call_panel :: (cid: dc.Snowflake) {
	p := ui.box("dmcall", .Clip);
	p.semantic_size = .[ui.pct(1), ui.px(max(240.0, app.ui.window.y * 0.45))];
	p.layout_axis = .Y;
	ui.parent(p); defer ui.pop_parent();
	call_view(cid);
}

// dm_call_banner: a DM with a call going on that we're not in: who is in it and Join Call.
dm_call_banner :: (ch: *dc.Channel) {
	s := store();
	in_call: [..]dc.Snowflake;
	in_call.allocator = temp;
	for v, uid: s.voice_states if v.channel_id == ch.id array_add(*in_call, uid);
	if !in_call.count return;
	r := row("callbanner", .Draw_Background);
	r.semantic_size = .[ui.pct(1), ui.px(56)];
	r.style.bg = .{0, 0, 0, 1};
	ui.parent(r); defer ui.pop_parent();
	spacer(.X, 16);
	icon("ph", "phone-call", 20, T("--status-positive"));
	spacer(.X, 10);
	label(L("Ongoing call"), .Semibold, 15, .{1, 1, 1, 1}, 20);
	spacer(.X, 12);
	for in_call { ui.id_scope(cast(u64) it); defer ui.pop_seed(); avatar_box("av", it, 28); spacer(.X, 4); }
	filler(.X);
	jb := row("join", .Clickable | .Draw_Background | .Hot_Animation);
	jb.semantic_size = .[ui.children(), ui.px(36)];
	jb.style.radius = all4(8);
	jb.style.bg = T("--status-positive");
	jb.style.bg_hot = with_alpha(T("--status-positive"), 0.85);
	if ui.signal(jb).clicked call_join_incoming(ch.id);
	{ ui.parent(jb); defer ui.pop_parent();
		spacer(.X, 16);
		label(L("Join Call"), .Semibold, 14, .{1, 1, 1, 1}, 18);
		spacer(.X, 16);
	}
	spacer(.X, 16);
}

// stage_moderator: Mute Members, Move Members and Manage Channels in the stage, as Discord's stage moderators.
stage_moderator :: (cid: dc.Snowflake) -> bool {
	return dc.has_permission(dc.channel_permissions(call_store(), cid), dc.PERM_MUTE_MEMBERS | dc.PERM_MOVE_MEMBERS | dc.PERM_MANAGE_CHANNELS);
}

// call_pip: picture-in-picture. While in a call with another channel open, the stream we watch (else someone's
// camera) plays in a small player over the app, in a corner it can be dragged to; a click returns to the call.
call_pip :: () {
	if !app.voice_channel || app.view.channel == app.voice_channel || call_fullscreen() return;
	img: media.Video_Image;
	if vid.watches.count img = stream_image(vid.watches[0].user);
	cs := call_store();
	if !img.y for v, uid: cs.voice_states if v.channel_id == app.voice_channel && uid != cs.me && v.self_video {
		img = camera_image(uid);
		if img.y break;
	}
	if !img.y return;
	W :: cast(float32) 320;
	H :: W * 9 / 16;
	M :: cast(float32) 16;
	corner := ui.Vec2.{ifx pip.corner & 1 then M + RAIL_W + app.view.sidebar_w else app.ui.window.x - W - M,
		ifx pip.corner & 2 then TITLE_BAR_H + HEADER_H + M else app.ui.window.y - H - 96};
	b := ui.box("pip", .Clickable | .Click_On_Release | .Draw_Background | .Draw_Shadow | .Floating_X | .Floating_Y | .Overlay | .Clip);
	b.semantic_size = .[ui.px(W), ui.px(H)];
	b.style.bg = .{0, 0, 0, 1};
	b.style.radius = all4(8);
	b.style.shadow_color = .{0, 0, 0, 0.4};
	b.style.shadow_blur = 16;
	sig := ui.signal(b);
	pos := corner;
	if sig.dragging pos += sig.drag_delta;
	b.fixed_pos = pos;
	d := New(Tile_Draw,, temp);
	d.* = .{img, false};
	b.custom_draw = tile_video_draw;
	b.custom_user = d;
	if sig.released {
		moved := abs(sig.drag_delta.x) + abs(sig.drag_delta.y) > 6;
		if !moved { voice_return(); return; }
		// the corner nearest where it was dropped
		mid := pos + .{W / 2, H / 2};
		page_mid := ui.Vec2.{(RAIL_W + app.view.sidebar_w + app.ui.window.x) / 2, app.ui.window.y / 2};
		pip.corner = (ifx mid.x < page_mid.x then 1 else 0) | (ifx mid.y < page_mid.y then 2 else 0);
	}
	if sig.hovering tooltip_below(L("Return to call"), b.rect, above = true);
}

pip: struct { corner: int; }; // 0 bottom right, 1 bottom left, 2 top right, 3 top left

// The screen share picker: screens and windows as tiles with a thumbnail and their name (ScreenCaptureKit
// lists them, and takes the thumbnails, asynchronously).
screen_picker :: () {
	if !vid.picker_open {
		for pick_thumbs gfx.texture_destroy(it);
		table_reset(*pick_thumbs);
		return;
	}
	targets, ready := video.screen_targets();
	if vid.picker_test targets, ready = picker_test_targets(), true;
	scrim := ui.box("screen_scrim", .Draw_Background | .Floating_X | .Floating_Y | .Overlay | .Clickable);
	scrim.semantic_size = .[ui.px(app.ui.window.x), ui.px(app.ui.window.y)];
	scrim.style.bg = .{0, 0, 0, 0.7};
	if ui.signal(scrim).clicked vid.picker_open = false;
	W :: cast(float32) 440;
	H := min(cast(float32) 520, app.ui.window.y - 80);
	m := ui.box("screen_picker", .Draw_Background | .Draw_Border | .Floating_X | .Floating_Y | .Overlay | .Clickable | .Clip);
	m.semantic_size = .[ui.px(W), ui.px(H)];
	m.fixed_pos = .{(app.ui.window.x - W) / 2, (app.ui.window.y - H) / 2};
	m.layout_axis = .Y;
	m.style.bg = T("--background-surface-high");
	m.style.border = 1;
	m.style.border_color = T("--border-subtle");
	m.style.radius = all4(12);
	ui.signal(m);
	ui.parent(m); defer ui.pop_parent();
	spacer(.Y, 20);
	hdr := row("hdr");
	hdr.semantic_size = .[ui.pct(1), ui.px(24)];
	{ ui.parent(hdr); defer ui.pop_parent();
		spacer(.X, 20);
		label(ifx screen_sharing() then L("Stream Settings") else L("Share Your Screen"), .Semibold, 20, T("--text-strong"), 24);
		filler(.X);
		x := icon("close", "x-large", 20, T("--interactive-icon-default"), .Clickable);
		if ui.signal(x).clicked vid.picker_open = false;
		spacer(.X, 16);
	}
	spacer(.Y, 12);
	go_live_quality();
	if screen_sharing() {
		// while streaming: its settings and Stop Streaming
		spacer(.Y, 16);
		r := row("stop");
		r.semantic_size = .[ui.pct(1), ui.px(40)];
		ui.parent(r); defer ui.pop_parent();
		spacer(.X, 20);
		b := row("stopbtn", .Clickable | .Draw_Background | .Hot_Animation);
		b.semantic_size = .[ui.fill(), ui.px(40)];
		b.style.radius = all4(8);
		b.style.bg = T("--status-danger");
		b.style.bg_hot = with_alpha(T("--status-danger"), 0.85);
		if ui.signal(b).clicked { vid.picker_open = false; go_live_stop(); }
		{ ui.parent(b); defer ui.pop_parent();
			filler(.X);
			label(L("Stop Streaming"), .Semibold, 14, .{1, 1, 1, 1}, 18);
			filler(.X);
		}
		spacer(.X, 20);
		return;
	}
	spacer(.Y, 8);
	list := ui.box("targets", .Scroll_Y | .Clip);
	list.semantic_size = .[ui.pct(1), ui.fill()];
	list.layout_axis = .Y;
	ui.signal(list);
	ui.parent(list); defer ui.pop_parent();
	if !ready {
		r := row("loading");
		r.semantic_size = .[ui.pct(1), ui.px(40)];
		ui.parent(r); defer ui.pop_parent();
		spacer(.X, 20);
		label(ifx video.screen_supported() then L("Looking for screens…") else L("Screen sharing isn't supported on this platform yet."), .Normal, 14, T("--text-muted"), 18);
		return;
	}
	for section: 0..1 {
		label_row := row(tprint("sec%", section));
		label_row.semantic_size = .[ui.pct(1), ui.px(32)];
		{ ui.parent(label_row); defer ui.pop_parent();
			spacer(.X, 20);
			label(ifx section == 0 then "SCREENS" else "APPLICATIONS", .Semibold, 12, T("--text-muted"), 16);
		}
		TW :: (W - 20 * 2 - 12) / 2;
		TH :: TW * 9 / 16;
		line: *ui.Box;
		n := 0;
		for t: targets {
			if t.is_window != (section == 1) continue;
			if n % 2 == 0 {
				if line ui.pop_parent();
				line = row(tprint("line%", n));
				line.semantic_size = .[ui.pct(1), ui.px(TH + 44)];
				line.cross_align = .Start;
				ui.parent(line);
				spacer(.X, 14);
			}
			n += 1;
			ui.id_scope(cast(u64) t.id * 2 + cast(u64) section); defer ui.pop_seed();
			b := ui.box("item", .Clickable | .Draw_Background | .Hot_Animation);
			b.semantic_size = .[ui.px(TW + 12), ui.px(TH + 40)];
			b.layout_axis = .Y;
			b.style.radius = all4(8);
			b.style.bg_hot = T("--background-mod-subtle");
			sig := ui.signal(b);
			{ ui.parent(b); defer ui.pop_parent();
				spacer(.Y, 6);
				r := row("r");
				r.semantic_size = .[ui.pct(1), ui.px(TH)];
				{ ui.parent(r); defer ui.pop_parent();
					spacer(.X, 6);
					th := ui.box("thumb", .Draw_Background);
					th.semantic_size = .[ui.px(TW), ui.px(TH)];
					th.style.bg = T("--background-base-lowest");
					th.style.radius = all4(6);
					tex := pick_thumb(t);
					if tex {
						d := New(Thumb_Draw,, temp);
						d.* = .{tex};
						th.custom_draw = (b: *ui.Box, user: *void) {
							d := cast(*Thumb_Draw) user;
							// contained in the tile, centred
							bw, bh := b.rect.x1 - b.rect.x0, b.rect.y1 - b.rect.y0;
							ts := gfx.texture_size(d.tex);
							s := min(bw / ts[0], bh / ts[1]);
							w, h := ts[0] * s, ts[1] * s;
							x, y := b.rect.x0 + (bw - w) / 2, b.rect.y0 + (bh - h) / 2;
							gfx.image(.{x, y, x + w, y + h}, d.tex, radius = 4);
						};
						th.custom_user = d;
					} else {
						ui.parent(th); defer ui.pop_parent();
						ic := icon("i", ifx t.is_window then "window-launch" else "screen", 32, T("--interactive-icon-default"), .Floating_X | .Floating_Y);
						ic.fixed_pos = .{(TW - 32) / 2, (TH - 32) / 2};
					}
				}
				spacer(.Y, 8);
				nr := row("n");
				nr.semantic_size = .[ui.pct(1), ui.px(20)];
				ui.parent(nr); defer ui.pop_parent();
				spacer(.X, 8);
				label(ellipsize(t.name, .Medium, 14, TW - 4), .Medium, 14, T("--text-default"), 20);
			}
			if sig.hovering tooltip_below(tprint("% (%×%)", t.name, t.width, t.height), b.rect);
			if sig.clicked {
				vid.picker_open = false;
				go_live_start(t);
			}
			spacer(.X, 4);
		}
		if line ui.pop_parent();
	}
}

Thumb_Draw :: struct { tex: gfx.Texture; }

picker_test_targets :: () -> []video.Screen_Target {
	T :: video.Screen_Target.[.{id = 1, name = "Screen 1", width = 1512, height = 982}, .{id = 2, name = "Screen 2", width = 1920, height = 1080},
		.{is_window = true, id = 3, name = "Notes — Shopping list", width = 800, height = 600}];
	return T;
}

pick_thumbs: Table(u64, gfx.Texture); // the open picker's thumbnails, by target

pick_thumb :: (t: video.Screen_Target) -> gfx.Texture {
	key := (ifx t.is_window then (cast(u64) 1) << 32 else 0) | t.id;
	found, tex := table_find(*pick_thumbs, key);
	if found return tex;
	rgba, w, h := video.screen_thumb(t);
	if !rgba return 0;
	tex = gfx.texture_create(w, h, .RGBA8, rgba, premultiplied_alpha = true);
	table_set(*pick_thumbs, key, tex);
	return tex;
}

// go_live_quality: the stream's resolution and frame rate, as chips. Above 720p30 only for who may (go_live_premium).
go_live_quality :: () {
	chip :: (text: string, on: bool) -> bool {
		b := ui.box(text, .Clickable | .Draw_Background | .Draw_Border | .Hot_Animation | .Draw_Text);
		b.semantic_size = .[ui.px(ui.layout_text(F(.Semibold), 14, text, -1).width + 24), ui.px(30)];
		b.style.radius = all4(15);
		b.style.border = 1;
		b.style.border_color = ifx on then T("--background-brand") else T("--border-subtle");
		b.style.bg = ifx on then with_alpha(T("--background-brand"), 0.25) else .{};
		b.style.bg_hot = T("--background-mod-subtle");
		b.style.font = F(.Semibold);
		b.style.font_size = 14;
		b.style.text_color = ifx on then T("--text-strong") else T("--text-default");
		b.style.text_align = .Center;
		return ui.signal(b).clicked;
	}
	all := go_live_premium();
	for section: 0..1 {
		r := row(ifx section == 0 then "res" else "fps");
		r.semantic_size = .[ui.pct(1), ui.px(38)];
		r.style.child_gap = 8;
		ui.parent(r); defer ui.pop_parent();
		spacer(.X, 12);
		l := label(ifx section == 0 then "RESOLUTION" else L("FRAME RATE"), .Semibold, 12, T("--text-muted"), 16);
		l.semantic_size[ui.Axis.X] = ui.px(96);
		if section == 0 {
			for h: int.[720, 1080, 0] {
				if h != 720 && !all continue;
				if chip(ifx h then tprint("%p##h%", h, h) else "Source##h0", vid.go_height == h) go_live_set(h, vid.go_fps);
			}
		} else {
			for f: int.[15, 30, 60] {
				if f == 60 && !all continue;
				if chip(tprint("% FPS##f%", f, f), vid.go_fps == f) go_live_set(vid.go_height, f);
			}
		}
	}
}

Tile_Draw :: struct {
	img: media.Video_Image;
	cover: bool;
}

// Video "cover"-fitted for cameras (cropped to fill), "contain"-fitted for streams.
tile_video_draw :: (b: *ui.Box, user: *void) {
	d := cast(*Tile_Draw) user;
	r := cast,force(gfx.Rect) b.rect;
	bw, bh := r.x1 - r.x0, r.y1 - r.y0;
	iw, ih := cast(float32) d.img.size[0], cast(float32) d.img.size[1];
	if iw <= 0 || ih <= 0 || bw <= 0 || bh <= 0 return;
	white := gfx.Color.{1, 1, 1, b.opacity};
	if d.cover {
		src := gfx.Rect.{0, 0, iw, ih};
		if iw / ih > bw / bh { cw := ih * bw / bh; src.x0 = (iw - cw) / 2; src.x1 = src.x0 + cw; }
		else { ch := iw * bh / bw; src.y0 = (ih - ch) / 2; src.y1 = src.y0 + ch; }
		gfx.push_rect(.{dst = r, src = src, tex = d.img.y, tex2 = d.img.cbcr, yuv = d.img.yuv, colors = .[white, white, white, white], radii = b.style.radius});
		return;
	}
	sc := min(bw / iw, bh / ih);
	w, h := iw * sc, ih * sc;
	x0, y0 := r.x0 + (bw - w) / 2, r.y0 + (bh - h) / 2;
	gfx.video(.{x0, y0, x0 + w, y0 + h}, d.img.y, d.img.cbcr, d.img.yuv, 0, white);
}

#scope_file

cv: struct {
	focus_user: dc.Snowflake;
	focus_stream: bool;
};

// The grid shape that makes 16:9 tiles largest; the last row is centered.
place_tiles :: (tiles: []Call_Tile, aw: float32, ah: float32) {
	n := tiles.count;
	W := aw - 2 * CALL_PAD;
	H := ah - 2 * CALL_PAD;
	best_w: float32;
	cols := 1;
	for c: 1..n {
		rows := (n + c - 1) / c;
		w := min((W - CALL_GAP * (c - 1)) / c, (H - CALL_GAP * (rows - 1)) / rows * 16 / 9);
		if w > best_w { best_w = w; cols = c; }
	}
	if best_w <= 0 return;
	th := best_w * 9 / 16;
	rows := (n + cols - 1) / cols;
	y0 := CALL_PAD + (H - (rows * th + (rows - 1) * CALL_GAP)) / 2;
	for tiles {
		r := it_index / cols;
		in_row := min(cols, n - r * cols);
		row_w := in_row * best_w + (in_row - 1) * CALL_GAP;
		x := CALL_PAD + (W - row_w) / 2 + (it_index % cols) * (best_w + CALL_GAP);
		y := y0 + r * (th + CALL_GAP);
		call_tile(it, x, y, best_w, th);
	}
}

call_tile :: (t: Call_Tile, x: float32, y: float32, w: float32, h: float32) {
	s := store();
	ui.id_scope(cast(u64) t.user * 2 + cast(u64) t.stream); defer ui.pop_seed();
	img := ifx t.stream then stream_image(t.user) else camera_image(t.user);
	watching := t.stream && (t.user == s.me || watch_of(t.user) != null);
	b := ui.box("tile", .Draw_Background | .Clickable | .Floating_X | .Floating_Y | .Clip);
	b.semantic_size = .[ui.px(w), ui.px(h)];
	b.fixed_pos = .{x, y};
	b.style.radius = all4(8);
	b.style.bg = ifx t.stream || img.y then T("--background-base-lowest") else profile_banner_color(t.user);
	b.layout_axis = .Y;
	b.cross_align = .Center;
	if img.y {
		d := New(Tile_Draw,, temp);
		d.* = .{img, !t.stream};
		b.custom_draw = tile_video_draw;
		b.custom_user = d;
	}
	preview := "";
	if !img.y && t.stream && !watching && call_client() {
		// a stream we don't watch shows its streamer's last preview, dimmed under Watch Stream
		ch := dc.channel_get(s, app.voice_channel);
		preview = dc.stream_preview(call_client(), dc.stream_key(ifx ch then ch.guild_id else 0, app.voice_channel, t.user));
		set_remote_image(b, preview, cover = true);
	}
	if t.absent { absent_tile(b, t.user, h); return; }
	sig := ui.signal(b);
	if sig.right_clicked open_voice_user_menu(t.user, app.ui.mouse);
	if sig.clicked && (!t.stream || watching) {
		if cv.focus_user { cv.focus_user = 0; } else { cv.focus_user, cv.focus_stream = t.user, t.stream; }
	}
	vs := table_find_pointer(*s.voice_states, t.user);
	gid := ifx vs then vs.guild_id else 0;
	{ ui.parent(b); defer ui.pop_parent();
		if preview {
			dim := ui.box("dim", .Draw_Background | .Floating_X | .Floating_Y);
			dim.semantic_size = .[ui.px(w), ui.px(h)];
			dim.style.bg = .{0, 0, 0, 0.5};
		}
		if !img.y {
			av := min(80.0, h * 0.35);
			spacer(.Y, (h - av) / 2 - (ifx t.stream && !watching then 24.0 else 0));
			avatar_box("av", t.user, av);
			if t.stream && !watching {
				spacer(.Y, 16);
				wb := row("watch", .Clickable | .Draw_Background | .Hot_Animation);
				wb.semantic_size = .[ui.children(), ui.px(32)];
				wb.style.radius = all4(8);
				wb.style.bg = T("--background-surface-highest");
				wb.style.bg_hot = T("--background-mod-normal");
				if ui.signal(wb).clicked watch_stream(t.user);
				ui.parent(wb); defer ui.pop_parent();
				spacer(.X, 14);
				label(L("Watch Stream"), .Semibold, 14, T("--text-strong"), 18);
				spacer(.X, 14);
			}
		}
		if t.stream {
			live := row("live", .Draw_Background | .Floating_X | .Floating_Y);
			live.semantic_size = .[ui.children(), ui.px(18)];
			live.fixed_pos = .{8, 8};
			live.style.bg = T("--status-danger");
			live.style.radius = all4(4);
			ui.parent(live); defer ui.pop_parent();
			spacer(.X, 5);
			label("LIVE", .Bold, 11, .{1, 1, 1, 1}, 14);
			spacer(.X, 5);
		}
		if t.stream && watching && t.user != s.me && (sig.hovering || ui.mouse_over(b)) {
			// each watched stream can be left on its own (several play at once)
			sw := row("stopwatch", .Clickable | .Draw_Background | .Floating_X | .Floating_Y | .Hot_Animation);
			sw.semantic_size = .[ui.children(), ui.px(28)];
			sw.fixed_pos = .{w - 128, 8};
			sw.style.bg = .{0, 0, 0, 0.6};
			sw.style.bg_hot = .{0, 0, 0, 0.8};
			sw.style.radius = all4(6);
			if ui.signal(sw).clicked watch_stop(t.user);
			ui.parent(sw); defer ui.pop_parent();
			spacer(.X, 10);
			label(L("Stop Watching"), .Semibold, 13, .{1, 1, 1, 1}, 16);
			spacer(.X, 10);
		}
		if sig.hovering || t.stream || img.y {
			// name pill, bottom left
			name := dc.user_name(s, t.user, gid, "unknown");
			pill := row("name", .Draw_Background | .Floating_X | .Floating_Y);
			pill.semantic_size = .[ui.children(), ui.px(24)];
			pill.fixed_pos = .{8, h - 32};
			pill.style.bg = .{0, 0, 0, 0.6};
			pill.style.radius = all4(6);
			ui.parent(pill); defer ui.pop_parent();
			spacer(.X, 8);
			label(ellipsize(name, .Medium, 14, w - 60), .Medium, 14, .{1, 1, 1, 1}, 18);
			spacer(.X, 8);
		}
		if vs && !t.stream && (vs.self_mute || vs.mute || vs.self_deaf || vs.deaf) {
			deaf := vs.self_deaf || vs.deaf;
			m := row("muted", .Draw_Background | .Floating_X | .Floating_Y);
			m.semantic_size = .[ui.px(28), ui.px(28)];
			m.fixed_pos = .{w - 36, h - 36};
			m.style.bg = .{0, 0, 0, 0.6};
			m.style.radius = all4(14);
			ui.parent(m); defer ui.pop_parent();
			spacer(.X, 6);
			server := ifx deaf then vs.deaf else vs.mute; // a moderator's, drawn red like the official client
			icon("i", ifx deaf then "headphones-slash" else "microphone-slash", 16, ifx server then T("--status-danger") else .{1, 1, 1, 1});
		}
	}
	for call_effects if it.user == t.user && !t.stream {
		age := cast(float32) (app.ui.time - it.start);
		if age >= EFFECT_S continue;
		ui.id_scope(cast(u64) it_index); defer ui.pop_seed();
		size := min(64.0, h * 0.3);
		e := emoji_box("effect", it.emoji, size);
		e.flags |= .Floating_X | .Floating_Y;
		e.fixed_pos = .{x + w / 2 - size / 2 + 20 * sin(age * 3), y + h - size - (h - size) * age / EFFECT_S};
		request_wake(app.ui.time + 1.0 / 60);
	}
	if !t.stream && voice_is_speaking(t.user) {
		ring := ui.box("speaking", .Draw_Border | .Floating_X | .Floating_Y);
		ring.semantic_size = .[ui.px(w), ui.px(h)];
		ring.fixed_pos = .{x, y};
		ring.style.radius = all4(8);
		ring.style.border = 2;
		ring.style.border_color = T("--status-positive");
	}
}

// absent_tile: someone in the DM who isn't in the call: their avatar dimmed, and Ring (Ringing… while it rings).
absent_tile :: (b: *ui.Box, uid: dc.Snowflake, h: float32) {
	b.style.bg = T("--background-base-lowest");
	b.flags &= ~.Clickable;
	ui.parent(b); defer ui.pop_parent();
	av := min(80.0, h * 0.35);
	spacer(.Y, (h - av) / 2 - 24);
	a := avatar_box("av", uid, av);
	{
		ui.parent(a); defer ui.pop_parent();
		dim := ui.box("dim", .Draw_Background | .Floating_X | .Floating_Y);
		dim.semantic_size = .[ui.px(av), ui.px(av)];
		dim.style.bg = .{0, 0, 0, 0.5};
		dim.style.radius = all4(av / 2);
	}
	spacer(.Y, 16);
	call := ifx app.client then dc.call_get(app.client, app.voice_channel) else null;
	ringing := call && array_find(call.ringing, uid);
	rb := row("ring", ifx ringing then ui.Box_Flags.Draw_Background else .Clickable | .Draw_Background | .Hot_Animation);
	rb.semantic_size = .[ui.children(), ui.px(32)];
	rb.style.radius = all4(8);
	rb.style.bg = ifx ringing then T("--background-mod-subtle") else T("--status-positive");
	rb.style.bg_hot = with_alpha(T("--status-positive"), 0.85);
	if ui.signal(rb).clicked && !ringing && net_action() dc.ring_users(app.client, app.voice_channel, .[uid]);
	ui.parent(rb); defer ui.pop_parent();
	spacer(.X, 14);
	label(ifx ringing then L("Ringing…") else L("Ring"), .Semibold, 14, .{1, 1, 1, 1}, 18);
	spacer(.X, 14);
}

call_controls :: (cid: dc.Snowflake) {
	bar := row("controls");
	bar.semantic_size = .[ui.pct(1), ui.px(CALL_BAR_H)];
	ui.parent(bar); defer ui.pop_parent();
	filler(.X);
	if app.voice_channel != cid {
		jb := row("join", .Clickable | .Draw_Background | .Hot_Animation);
		jb.semantic_size = .[ui.children(), ui.px(48)];
		jb.style.radius = all4(12);
		jb.style.bg = T("--status-positive");
		jb.style.bg_hot = with_alpha(T("--status-positive"), 0.85);
		if ui.signal(jb).clicked {
			ch := dc.channel_get(store(), cid);
			if ch && ch.guild_id voice_join_channel(ch.guild_id, cid);
			else if ch dm_call_toggle(ch);
		}
		{ ui.parent(jb); defer ui.pop_parent();
			spacer(.X, 20);
			label(L("Join Voice"), .Semibold, 16, .{1, 1, 1, 1}, 20);
			spacer(.X, 20);
		}
		filler(.X);
		return;
	}
	spacer(.X, 72); // balances the fullscreen button on the right
	can_video := voice_conn() != null && voice.state(voice_conn()) == .Connected;
	smute, sdeaf := server_muted();
	mic_off := app.self_mute || app.self_deaf || smute || sdeaf;
	if control("mic", ifx mic_off then "microphone-slash" else "microphone", mic_off, false, true) toggle_self_mute();
	stage_controls(cid);
	spacer(.X, 8);
	// video.camera_supported asks AVFoundation, which TCC may kill us for: only on click
	if control("camera", "video", false, camera_on(), can_video && video.SUPPORTED) camera_toggle();
	spacer(.X, 8);
	if control("screen", "screen-stream", false, screen_sharing(), can_video && video.SUPPORTED) {
		if !screen_sharing() video.screen_targets_refresh();
		vid.picker_open = true; // while streaming: its settings and Stop Streaming
	}
	spacer(.X, 8);
	sbc := control("soundboard", "music", false, sb.open, soundboard_available());
	if sbc soundboard_toggle(control_rect);
	spacer(.X, 8);
	if control("effects", "reaction", false, effect_bar_open, can_video) effect_bar_open = !effect_bar_open;
	if effect_bar_open && can_video effect_bar(control_rect);
	spacer(.X, 8);
	if control("leave", "phone-hang-up", true, false, true) voice_hang_up();
	filler(.X);
	if control("full", "fullscreen", false, app.view.call_full, true) app.view.call_full = !app.view.call_full; // Escape also leaves
	spacer(.X, 16);
}

// effect_bar: a row of emoji above the effects button; a click floats one over our tile for the call.
effect_bar :: (anchor: ui.Rect) {
	W := cast(float32) EFFECT_BAR.count * 40 + 16;
	p := ui.box("effectbar", .Draw_Background | .Draw_Border | .Draw_Shadow | .Floating_X | .Floating_Y | .Overlay | .Clickable);
	p.semantic_size = .[ui.px(W), ui.px(52)];
	pr := ui.top_parent().rect;
	p.fixed_pos = .{(anchor.x0 + anchor.x1) / 2 - W / 2 - pr.x0, anchor.y0 - 60 - pr.y0};
	p.layout_axis = .X;
	p.cross_align = .Center;
	p.style.bg = T("--background-surface-higher");
	p.style.border = 1;
	p.style.border_color = T("--border-subtle");
	p.style.radius = all4(12);
	p.style.shadow_color = .{0, 0, 0, 0.3};
	p.style.shadow_blur = 12;
	ui.signal(p);
	ui.parent(p); defer ui.pop_parent();
	spacer(.X, 8);
	for EFFECT_BAR {
		ui.id_scope(cast(u64) it_index); defer ui.pop_seed();
		b := ui.box("e", .Clickable | .Draw_Background | .Hot_Animation);
		b.semantic_size = .[ui.px(40), ui.px(40)];
		b.style.radius = all4(8);
		b.style.bg_hot = T("--background-mod-normal");
		b.layout_axis = .Y;
		b.cross_align = .Center;
		if ui.signal(b).clicked && net_action() {
			dc.send_voice_effect(call_client(), app.voice_channel, it);
			call_effect_show(call_store().me, .{name = it});
		}
		ui.parent(b); defer ui.pop_parent();
		spacer(.Y, 6);
		emoji_box("em", .{name = it}, 28);
	}
}

// stage_controls: on a stage, the audience's Request to Speak (Lower Hand once raised; a moderator speaks at
// once), and a speaker's Move to Audience.
stage_controls :: (cid: dc.Snowflake) {
	ch := dc.channel_get(call_store(), cid);
	if !ch || ch.kind != .Guild_Stage_Voice return;
	me := table_find_pointer(*call_store().voice_states, call_store().me);
	if !me || me.channel_id != cid return;
	text := "Move to Audience";
	if me.suppress text = ifx stage_moderator(cid) then "Speak" else ifx me.requested_to_speak then "Lower Hand" else "Request to Speak";
	if !me.suppress || stage_moderator(cid) || dc.has_permission(dc.channel_permissions(call_store(), cid), dc.PERM_REQUEST_TO_SPEAK) {
		spacer(.X, 8);
		b := row("stage", .Clickable | .Draw_Background | .Hot_Animation);
		b.semantic_size = .[ui.children(), ui.px(48)];
		b.style.radius = all4(12);
		b.style.bg = ifx me.requested_to_speak && me.suppress then T("--background-brand") else T("--background-surface-highest");
		b.style.bg_hot = T("--background-mod-normal");
		if ui.signal(b).clicked && net_action() {
			if !me.suppress || stage_moderator(cid) dc.stage_set_suppress(call_client(), ch.guild_id, cid, call_store().me, !me.suppress);
			else { dc.stage_request_to_speak(call_client(), ch.guild_id, cid, !me.requested_to_speak); vc_hand_raised(!me.requested_to_speak); }
		}
		ui.parent(b); defer ui.pop_parent();
		spacer(.X, 16);
		label(text, .Semibold, 14, T("--text-strong"), 18);
		spacer(.X, 16);
	}
}

// stage_audience: the stage's listeners as small avatars, a raised hand marked, under the speakers.
stage_audience :: (ids: []dc.Snowflake) {
	r := row("audience");
	r.semantic_size = .[ui.pct(1), ui.px(56)];
	ui.parent(r); defer ui.pop_parent();
	spacer(.X, CALL_PAD);
	label(tprint(L("AUDIENCE — %"), ids.count), .Semibold, 12, T("--text-muted"), 16);
	spacer(.X, 12);
	for ids {
		ui.id_scope(cast(u64) it); defer ui.pop_seed();
		vs := table_find_pointer(*store().voice_states, it);
		b := ui.box("a", .Clickable);
		b.semantic_size = .[ui.px(40), ui.px(40)];
		sig := ui.signal(b);
		if sig.right_clicked open_voice_user_menu(it, app.ui.mouse);
		if sig.clicked open_profile(it, b.rect);
		{
			ui.parent(b); defer ui.pop_parent();
			voice_avatar("av", it, 40, .{0, 0, 0, 1});
			if vs && vs.requested_to_speak {
				// a raised hand
				h := ui.box("hand", .Draw_Background | .Floating_X | .Floating_Y);
				h.semantic_size = .[ui.px(14), ui.px(14)];
				h.fixed_pos = .{28, -2};
				h.style.bg = T("--background-brand");
				h.style.radius = all4(7);
			}
		}
		if sig.hovering tooltip_below(tprint("%%", dc.user_name(store(), it, vs.guild_id, "unknown"), ifx vs && vs.requested_to_speak then " (requested to speak)" else ""), b.rect, above = true);
		spacer(.X, 8);
	}
}

// stage_invite_banner: a moderator invited us to speak (our hand is up, but we didn't raise it): Accept or Decline.
stage_invite_banner :: (ch: *dc.Channel) {
	me := table_find_pointer(*call_store().voice_states, call_store().me);
	if !me || me.channel_id != ch.id || !me.suppress || !me.requested_to_speak || vc_hand_raised_get() return;
	r := row("invite", .Draw_Background);
	r.semantic_size = .[ui.pct(1), ui.px(48)];
	r.style.bg = T("--background-surface-high");
	ui.parent(r); defer ui.pop_parent();
	spacer(.X, 16);
	label(L("You've been invited to speak"), .Semibold, 14, T("--text-strong"), 18);
	filler(.X);
	if set_button(L("Decline##stdecline"), .Secondary, true, 32) && net_action() dc.stage_request_to_speak(call_client(), ch.guild_id, ch.id, false);
	spacer(.X, 8);
	if set_button(L("Accept##staccept"), .Positive, true, 32) && net_action() dc.stage_set_suppress(call_client(), ch.guild_id, ch.id, call_store().me, false);
	spacer(.X, 16);
}

// A 56x48 control: red when danger (muted / disconnect), white when on.
control_rect: ui.Rect; // the last control()'s, for a popout it opens
control :: (id: string, ic: string, danger: bool, on: bool, enabled: bool) -> bool {
	b := ui.box(id, .Clickable | .Draw_Background | .Hot_Animation);
	b.semantic_size = .[ui.px(56), ui.px(48)];
	control_rect = b.rect;
	b.style.radius = all4(12);
	bg := T("--background-surface-highest");
	fg := T("--interactive-icon-hover");
	if danger { bg = T("--status-danger"); fg = .{1, 1, 1, 1}; }
	if on { bg = .{1, 1, 1, 1}; fg = .{0, 0, 0, 1}; }
	if !enabled { b.flags &= ~.Clickable; fg = with_alpha(fg, 0.4); }
	b.style.bg = bg;
	b.style.bg_hot = with_alpha(bg, 0.85);
	b.layout_axis = .X;
	b.cross_align = .Center;
	sig := ui.signal(b);
	{ ui.parent(b); defer ui.pop_parent();
		filler(.X);
		icon("i", ic, 22, fg);
		filler(.X);
	}
	return enabled && sig.clicked;
}
