// Lottie stickers (format_type 3): the json comes from discord.com/stickers/{id}.json
// (a cors fetch, like the client's lottie loader), rendered with src/lottie into a
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

lottie_stickers: Map(dc.Snowflake, Lottie_Sticker);
#scope_file

lottie_get :: (id: dc.Snowflake) -> *Lottie_Sticker {
	{ ls, ok := map_find_ptr(*lottie_stickers, id);
	if ok { return ls; } }
	at(*lottie_stickers, id).* = Lottie_Sticker.{state = .Loading, frame = -1};
	if app.client != null {
		dc.expr_fetch_media(app.client, dc.sticker_url(id, 3), .Fetch, cast(u64)(id));
	} else {
		at(*lottie_stickers, id).* = Lottie_Sticker.{state = .Failed, frame = -1};
	}
	return at(*lottie_stickers, id);
}
#scope_export

lottie_receive :: (r: *dc.Expr_Result) {
	id := cast(dc.Snowflake)(r.tag);
	ls, ok := map_find_ptr(*lottie_stickers, id);
	if !ok { return; }
	if !r.ok || len(r.data) == 0 {
		ls.state = .Failed;
		return;
	}
	anim := lottie.load(r.data);
	if pickers_debug() { fmt.eprintfln("[pickers] lottie %d: %d bytes, ok=%v", cast(u64)(id), len(r.data), anim != null); }
	if anim == null {
		ls.state = .Failed;
		return;
	}
	ls.anim = anim;
	ls.state = .Ready;
	app.ui.animating = true;
}
#scope_file

Lottie_Draw :: struct {
	id: dc.Snowflake;
	animate: bool;
}
#scope_export

lottie_sticker_draw :: (b: *ui.Box, id: dc.Snowflake, animate: bool) {
	ls := lottie_get(id);
	if ls.state != .Ready {
		// placeholder while loading / if it can't render
		b.flags |= .Draw_Background;
		b.style.bg = T("--background-mod-subtle");
		b.style.radius = all4(8);
		return;
	}
	d := new(Lottie_Draw, temp);
	d.* = .{id, animate};
	b.custom_draw = lottie_draw;
	b.custom_user = d;
}
#scope_file

lottie_draw :: (b: *ui.Box, user: *void) {
	d := cast(*Lottie_Draw)(user);
	ls, ok := map_find_ptr(*lottie_stickers, d.id);
	if !ok || ls.state != .Ready { return; }
	px := cast(int)(math.round((b.rect.x1 - b.rect.x0) * max(gfx.scale(), 1)));
	if px <= 0 { return; }
	if ls.px != px {
		if ls.px != 0 { lottie.player_destroy(*ls.player); }
		if ls.tex != 0 { gfx.texture_destroy(ls.tex); }
		ls.tex = 0;
		ls.px = 0;
		lottie.player_init(*ls.player, ls.anim, px, px);
		ls.px = px;
		ls.frame = -1;
	}
	frame := ifx d.animate then lottie.frame_at(ls.anim, app.ui.time) else ls.anim.ip;
	if frame != ls.frame || ls.tex == 0 {
		pixels := lottie.render(*ls.player, frame);
		if ls.tex == 0 { ls.tex = gfx.texture_from_rgba(px, px, pixels); } else { gfx.texture_update(ls.tex, 0, 0, px, px, pixels); }
		ls.frame = frame;
	}
	if d.animate { app.ui.animating = true; }
	c := gfx.Color.{1, 1, 1, b.opacity};
	gfx.push_rect(.{dst = cast,force(gfx.Rect)(b.rect), tex = ls.tex, colors = .[c, c, c, c]});
}
#scope_export

