// Lottie stickers (format_type 3): the json comes from discord.com/stickers/{id}.json
// (a cors fetch, like the client's lottie loader), rendered with the lottie module. Parsing and the
// still first frame (one per drawn size) run on the decode workers (images.jai). An animating sticker
// (hover, or in a message) renders its next frame there too, one at a time, so the UI thread only uploads it.

Lottie_State :: enum u8 {
	Loading;
	Ready;
	Failed;
}

Lottie_Sticker :: struct {
	state: Lottie_State;
	anim: *lottie.Animation;
	stills: [..]Lottie_Still;
	player: *lottie.Player; // the animating copy (heap: the table may move); a worker's while rendering
	rendering: bool;
	px: int;
	tex: gfx.Texture;
	frame: float32; // last rendered frame (-1 = none)
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
	if d.kind == .Lottie_Load {
		if pickers_debug() print("[pickers] lottie %: ok=%\n", d.id, d.ok, to_standard_error = true);
		ls.anim = d.anim;
		ls.state = ifx d.ok then .Ready else .Failed;
		return;
	}
	if d.kind == .Lottie_Frame {
		ls.rendering = false;
		if !d.ok || d.px != ls.px return;
		if ls.tex == 0 ls.tex = gfx.texture_from_rgba(d.px, d.px, d.frames[0]);
		else gfx.texture_update(ls.tex, 0, 0, d.px, d.px, d.frames[0]);
		ls.frame = d.frame;
		return;
	}
	for * ls.stills if it.px == d.px && it.tex == 0 && d.ok it.tex = gfx.texture_create(d.px, d.px, .RGBA8, d.frames[0], premultiplied_alpha = true);
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

lottie_get :: (id: dc.Snowflake) -> *Lottie_Sticker {
	ls, added := find_or_add(*lottie_stickers, id);
	if !added return ls;
	ls.* = .{state = .Loading, frame = -1};
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
	if d.animate {
		app.ui.animating = true;
		if !ls.rendering {
			if ls.px != px {
				if ls.player lottie.player_destroy(ls.player);
				else ls.player = New(lottie.Player);
				if ls.tex != 0 gfx.texture_destroy(ls.tex);
				ls.tex = 0;
				lottie.player_init(ls.player, px, px);
				ls.px = px;
				ls.frame = -1;
			}
			frame := lottie.frame_at(ls.anim, app.ui.time);
			if frame != ls.frame {
				ls.rendering = true;
				decode_submit(.{kind = .Lottie_Frame, id = d.id, px = px, anim = ls.anim, player = ls.player, frame = frame});
			}
		}
		if ls.tex != 0 && ls.px == px {
			gfx.push_rect(.{dst = cast,force(gfx.Rect) b.rect, tex = ls.tex, colors = .[c, c, c, c]});
			return;
		}
	}
	// still, and the animation's stand-in until its first frame is in
	for ls.stills if it.px == px {
		if it.tex gfx.push_rect(.{dst = cast,force(gfx.Rect) b.rect, tex = it.tex, colors = .[c, c, c, c]});
		return;
	}
	array_add(*ls.stills, .{px = px});
	decode_submit(.{kind = .Lottie_Still, id = d.id, px = px, anim = ls.anim});
}
