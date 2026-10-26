package app

import "core:fmt"
import "core:math"
import dc "fc:discord"
import "fc:gfx"
import "fc:lottie"
import "fc:ui"

// Lottie stickers (format_type 3): the json comes from discord.com/stickers/{id}.json
// (a cors fetch, like the client's lottie loader), rendered with src/lottie into a
// texture that is re-rendered only while animating (hover).

Lottie_State :: enum u8 {
	Loading,
	Ready,
	Failed,
}

Lottie_Sticker :: struct {
	state:  Lottie_State,
	anim:   ^lottie.Animation,
	player: lottie.Player,
	px:     int,
	tex:    gfx.Texture,
	frame:  f32, // last rendered frame (-1 = none)
}

lottie_stickers: map[dc.Snowflake]Lottie_Sticker

@(private = "file")
lottie_get :: proc(id: dc.Snowflake) -> ^Lottie_Sticker {
	if ls, ok := &lottie_stickers[id]; ok do return ls
	lottie_stickers[id] = Lottie_Sticker{state = .Loading, frame = -1}
	if app.client != nil {
		dc.expr_fetch_media(app.client, dc.sticker_url(id, 3), .Fetch, u64(id))
	} else {
		lottie_stickers[id] = Lottie_Sticker{state = .Failed, frame = -1}
	}
	return &lottie_stickers[id]
}

lottie_receive :: proc(r: ^dc.Expr_Result) {
	id := dc.Snowflake(r.tag)
	ls, ok := &lottie_stickers[id]
	if !ok do return
	if !r.ok || len(r.data) == 0 {
		ls.state = .Failed
		return
	}
	anim, err := lottie.load(r.data)
	if pickers_debug() do fmt.eprintfln("[pickers] lottie %d: %d bytes, err=%v", u64(id), len(r.data), err)
	if err != .None || anim == nil {
		ls.state = .Failed
		return
	}
	ls.anim = anim
	ls.state = .Ready
	app.ui.animating = true
}

@(private = "file")
Lottie_Draw :: struct {
	id:      dc.Snowflake,
	animate: bool,
}

lottie_sticker_draw :: proc(b: ^ui.Box, id: dc.Snowflake, animate: bool) {
	ls := lottie_get(id)
	if ls.state != .Ready {
		// placeholder while loading / if it can't render
		b.flags += {.Draw_Background}
		b.style.bg = T("--background-mod-subtle")
		b.style.radius = 8
		return
	}
	d := new(Lottie_Draw, context.temp_allocator)
	d^ = {id, animate}
	b.custom_draw = lottie_draw
	b.custom_user = d
}

@(private = "file")
lottie_draw :: proc(b: ^ui.Box, user: rawptr) {
	d := (^Lottie_Draw)(user)
	ls, ok := &lottie_stickers[d.id]
	if !ok || ls.state != .Ready do return
	px := int(math.round((b.rect.x1 - b.rect.x0) * max(gfx.scale(), 1)))
	if px <= 0 do return
	if ls.px != px {
		if ls.px != 0 do lottie.player_destroy(&ls.player)
		if ls.tex != 0 do gfx.texture_destroy(ls.tex)
		ls.tex = 0
		ls.px = 0
		if !lottie.player_init(&ls.player, ls.anim, px, px) {
			ls.state = .Failed
			return
		}
		ls.px = px
		ls.frame = -1
	}
	frame := d.animate ? lottie.frame_at(ls.anim, app.ui.time) : ls.anim.ip
	if frame != ls.frame || ls.tex == 0 {
		pixels := lottie.render(&ls.player, frame)
		if ls.tex == 0 do ls.tex = gfx.texture_from_rgba(px, px, pixels)
		else do gfx.texture_update(ls.tex, 0, 0, px, px, pixels)
		ls.frame = frame
	}
	if d.animate do app.ui.animating = true
	c := gfx.Color{1, 1, 1, b.opacity}
	gfx.push_rect({dst = gfx.Rect(b.rect), tex = ls.tex, colors = {c, c, c, c}})
}
