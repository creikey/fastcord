// Lottie stickers (format_type 3): the json comes from discord.com/stickers/{id}.json
// (a cors fetch, like the client's lottie loader), rendered with the lottie module. Parsing and the
// still first frame (one per drawn size) run on the decode workers (images.jai). An animating sticker
// gets each new frame from them too, one in flight at a time, so frames come as fast as the workers
// allow while the UI never waits: where the GPU draws scenes (gfx.scenes_supported) a worker records
// the frame (lottie.record) and the GPU rasterizes it into the sticker's texture; elsewhere a worker
// rasterizes it and the UI thread uploads it. A sticker not drawn for LOTTIE_KEEP seconds is
// dropped whole (textures, scenes, the parsed animation) and reloads from the disk cache when drawn.

LOTTIE_KEEP :: 3.0;

Lottie_State :: enum u8 {
	Loading;
	Ready;
	Failed;
}

Lottie_Sticker :: struct {
	state: Lottie_State;
	anim: *lottie.Animation;
	stills: [..]Lottie_Still;
	jobs: int; // decode jobs that use anim, in flight
	seen: float64; // app.ui.time it was last drawn
	animators: [..]*Lottie_Animator; // one per size it animates at (the picker and a message can differ)
}

// A sticker animating at one size (heap: the table may move, and a worker writes it while rendering).
Lottie_Animator :: struct {
	px: int;
	seen: float64;
	rendering: bool;
	tex: gfx.Texture; // the GPU's render target, or the CPU's uploaded frames
	shown: bool; // tex holds a frame
	frame: float32 = -1; // last frame asked for
	player: lottie.Player; // CPU
	scenes: [2]vector.Scene; // GPU: the worker records into scenes[next] while the UI draws the other
	next: int;
	ready: bool; // scenes[1 - next] is new: draw it into tex
}

Lottie_Still :: struct {
	px: int;
	tex: gfx.Texture; // 0 while a worker renders it
}

lottie_stickers: Table(dc.Snowflake, Lottie_Sticker);

lottie_receive :: (r: *dc.Expr_Result) {
	ls := table_find_pointer(*lottie_stickers, cast(dc.Snowflake) r.tag);
	if !ls return;
	if !r.ok || r.data.count == 0 {
		ls.state = .Failed;
		return;
	}
	decode_submit(.{kind = .Lottie_Load, id = cast(dc.Snowflake) r.tag, data = array_copy(r.data)});
}

// A decode worker finished parsing a sticker or rendering a still (images.jai decode_upload).
lottie_decoded :: (d: *Decoded) {
	ls := table_find_pointer(*lottie_stickers, d.id);
	if !ls return;
	if d.kind != .Lottie_Load  ls.jobs -= 1;
	if d.kind == .Lottie_Load {
		if pickers_debug() print("[pickers] lottie %: ok=%\n", d.id, d.ok, to_standard_error = true);
		ls.anim = d.anim;
		ls.state = ifx d.ok then .Ready else .Failed;
		return;
	}
	if d.kind == .Lottie_Frame || d.kind == .Lottie_Scene {
		a := animator(ls, d.px);
		if !a return;
		a.rendering = false;
		if d.kind == .Lottie_Scene {
			a.ready = true;
			a.next = 1 - a.next;
		} else if d.ok {
			if a.tex == 0 a.tex = gfx.texture_from_rgba(d.px, d.px, d.frames[0]);
			else gfx.texture_update(a.tex, 0, 0, d.px, d.px, d.frames[0]);
			a.shown = true;
		}
		return;
	}
	for * ls.stills if it.px == d.px && it.tex == 0 && d.ok it.tex = gfx.texture_create(d.px, d.px, .RGBA8, d.frames[0], premultiplied_alpha = true);
}

// Each frame: drops the stickers that weren't drawn for LOTTIE_KEEP seconds and have nothing in flight.
lottie_sweep :: () {
	gone: [..]dc.Snowflake;
	gone.allocator = temp;
	for * ls, id: lottie_stickers {
		// sizes no longer drawn
		i := 0;
		while i < ls.animators.count {
			a := ls.animators[i];
			if a.rendering || app.ui.time - a.seen < LOTTIE_KEEP { i += 1; continue; }
			animator_free(a);
			array_unordered_remove_by_index(*ls.animators, i);
		}
		if ls.state == .Loading || ls.jobs > 0 || ls.animators.count || app.ui.time - ls.seen < LOTTIE_KEEP continue;
		for s: ls.stills  if s.tex  gfx.texture_destroy(s.tex);
		array_free(ls.stills);
		array_free(ls.animators);
		lottie.destroy(ls.anim);
		array_add(*gone, id);
	}
	for gone  table_remove(*lottie_stickers, it);
}

lottie_sticker_draw :: (b: *ui.Box, id: dc.Snowflake, animate: bool) {
	ls := lottie_get(id);
	if ls.state != .Ready {
		// placeholder while loading / if it can't render
		b.flags |= .Draw_Background;
		b.style.bg = T("--background-mod-subtle");
		b.style.radius = all4(8);
		return;
	}
	d := New(Lottie_Draw,, temp);
	d.* = .{id, animate};
	b.custom_draw = lottie_draw;
	b.custom_user = d;
}

#scope_file

animator :: (ls: *Lottie_Sticker, px: int) -> *Lottie_Animator {
	for ls.animators  if it.px == px return it;
	return null;
}

animator_free :: (a: *Lottie_Animator) {
	if a.tex  gfx.texture_destroy(a.tex);
	if a.player.w  lottie.player_destroy(*a.player);
	for * a.scenes  vector.scene_free(it);
	free(a);
}

lottie_get :: (id: dc.Snowflake) -> *Lottie_Sticker {
	ls, added := find_or_add(*lottie_stickers, id);
	if !added return ls;
	ls.* = .{state = .Loading, seen = app.ui.time};
	// offline: a worker reads the json from FASTCORD_MEDIA_DIR
	if app.client != null dc.expr_fetch_media(app.client, dc.sticker_url(id, 3), .Fetch, id);
	else decode_submit(.{kind = .Lottie_Load, id = id, url = dc.sticker_url(id, 3, allocator = context.allocator)});
	return ls;
}

Lottie_Draw :: struct {
	id: dc.Snowflake;
	animate: bool;
}

lottie_draw :: (b: *ui.Box, user: *void) {
	d := cast(*Lottie_Draw) user;
	ls := table_find_pointer(*lottie_stickers, d.id);
	if !ls || ls.state != .Ready return;
	px := cast(int) floor((b.rect.x1 - b.rect.x0) * max(gfx.scale(), 1) + 0.5);
	if px <= 0 return;
	c := gfx.Color.{1, 1, 1, b.opacity};
	ls.seen = app.ui.time;
	if d.animate {
		app.ui.animating = true;
		gpu := gfx.scenes_supported();
		a := animator(ls, px);
		if !a {
			a = New(Lottie_Animator);
			a.px = px;
			if gpu  a.tex = gfx.target_create(px, px);
			else    lottie.player_init(*a.player, px, px);
			array_add(*ls.animators, a);
		}
		a.seen = app.ui.time;
		if a.ready && a.tex {
			gfx.draw_scene(a.tex, *a.scenes[1 - a.next]);
			a.ready = false;
			a.shown = true;
		}
		if !a.rendering {
			frame := lottie.frame_at(ls.anim, app.ui.time);
			if frame != a.frame {
				a.frame = frame;
				a.rendering = true;
				ls.jobs += 1;
				if gpu  decode_submit(.{kind = .Lottie_Scene, id = d.id, px = px, anim = ls.anim, scene = *a.scenes[a.next], frame = frame});
				else    decode_submit(.{kind = .Lottie_Frame, id = d.id, px = px, anim = ls.anim, player = *a.player, frame = frame});
			}
		}
		if a.shown {
			gfx.push_rect(.{dst = cast,force(gfx.Rect) b.rect, tex = a.tex, colors = .[c, c, c, c]});
			return;
		}
	}
	// still, and the animation's stand-in until its first frame is in
	for ls.stills if it.px == px {
		if it.tex gfx.push_rect(.{dst = cast,force(gfx.Rect) b.rect, tex = it.tex, colors = .[c, c, c, c]});
		return;
	}
	array_add(*ls.stills, .{px = px});
	ls.jobs += 1;
	decode_submit(.{kind = .Lottie_Still, id = d.id, px = px, anim = ls.anim});
}
