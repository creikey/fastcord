// Lottie stickers (format_type 3): the json comes from discord.com/stickers/{id}.json
// (a cors fetch, like the client's lottie loader), rendered with the lottie module into a
// texture that is re-rendered only while animating (hover).

Lottie_State :: enum u8 {
	Loading;
	Ready;
	Failed;
}

Lottie_Sticker :: struct {
	state: Lottie_State;
	anim: *lottie.Animation;
	player: lottie.Player;
	px: int;
	tex: gfx.Texture;
	frame: float32; // last rendered frame (-1 = none)
}

lottie_stickers: Table(dc.Snowflake, Lottie_Sticker);

lottie_receive :: (r: *dc.Expr_Result) {
	ls := table_find_pointer(*lottie_stickers, cast(dc.Snowflake) r.tag);
	if !ls return;
	if !r.ok || r.data.count == 0 {
		ls.state = .Failed;
		return;
	}
	anim := lottie.load(r.data);
	if pickers_debug() print("[pickers] lottie %: % bytes, ok=%\n", r.tag, r.data.count, anim != null, to_standard_error = true);
	if anim == null {
		ls.state = .Failed;
		return;
	}
	ls.anim = anim;
	ls.state = .Ready;
	app.ui.animating = true;
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
	if app.client != null {
		dc.expr_fetch_media(app.client, dc.sticker_url(id, 3), .Fetch, id);
	} else {
		ls.state = .Failed;
	}
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
	if ls.px != px {
		if ls.px != 0 lottie.player_destroy(*ls.player);
		if ls.tex != 0 gfx.texture_destroy(ls.tex);
		ls.tex = 0;
		lottie.player_init(*ls.player, ls.anim, px, px);
		ls.px = px;
		ls.frame = -1;
	}
	frame := ifx d.animate then lottie.frame_at(ls.anim, app.ui.time) else ls.anim.ip;
	if frame != ls.frame || ls.tex == 0 {
		pixels := lottie.render(*ls.player, frame);
		if ls.tex == 0 ls.tex = gfx.texture_from_rgba(px, px, pixels);
		else gfx.texture_update(ls.tex, 0, 0, px, px, pixels);
		ls.frame = frame;
	}
	if d.animate app.ui.animating = true;
	c := gfx.Color.{1, 1, 1, b.opacity};
	gfx.push_rect(.{dst = cast,force(gfx.Rect) b.rect, tex = ls.tex, colors = .[c, c, c, c]});
}
