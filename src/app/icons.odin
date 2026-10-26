package app

import "core:math"
import "core:strings"
import "fc:gfx"
import "fc:ui"
import "fc:vector"

// Icons extracted from the official client (tools/probes/discord_icons.py),
// embedded so the binary is self-contained.
@(private = "file")
ICON_FILES := #load_directory("../../assets/icons")

@(private = "file")
Icon_Key :: struct {
	name: string,
	px:   int,
}

@(private = "file")
icon_cache: map[Icon_Key]gfx.Texture

@(private = "file")
icon_svg :: proc(name: string) -> (string, bool) {
	want := strings.concatenate({name, ".svg"}, context.temp_allocator)
	for f in ICON_FILES {
		if strings.has_suffix(f.name, want) && (len(f.name) == len(want) || f.name[len(f.name) - len(want) - 1] == '/') {
			return string(f.data), true
		}
	}
	return "", false
}

// Texture holding the icon's coverage at size_pt (rasterized at device pixels).
icon_texture :: proc(name: string, size_pt: f32) -> gfx.Texture {
	px := int(math.round(size_pt * max(gfx.scale(), 1)))
	if t, ok := icon_cache[{name, px}]; ok do return t
	src, ok := icon_svg(name)
	tex: gfx.Texture
	if ok {
		if ic, pok := vector.parse_svg(src, context.temp_allocator); pok {
			cov := vector.rasterize(&ic, px, px, context.temp_allocator)
			tex = gfx.texture_create(px, px, .R8, cov)
		}
	}
	icon_cache[{strings.clone(name), px}] = tex
	return tex
}

@(private = "file")
Icon_Draw :: struct {
	name:  string,
	color: ui.Color,
}

@(private = "file")
icon_draw :: proc(b: ^ui.Box, user: rawptr) {
	d := (^Icon_Draw)(user)
	tex := icon_texture(d.name, b.rect.x1 - b.rect.x0)
	if tex == 0 do return
	c := gfx.Color(d.color)
	c.a *= b.opacity
	gfx.push_rect({dst = gfx.Rect(b.rect), tex = tex, colors = {c, c, c, c}})
}

// A size x size box drawing the named icon tinted with color.
icon :: proc(id: string, name: string, size: f32, color: ui.Color) -> ^ui.Box {
	b := ui.box(id)
	b.semantic_size = {.X = ui.px(size), .Y = ui.px(size)}
	set_icon(b, name, color)
	return b
}

// Draw an icon over any box (fills its rect).
set_icon :: proc(b: ^ui.Box, name: string, color: ui.Color) {
	d := new(Icon_Draw, context.temp_allocator)
	d^ = {name, color}
	b.custom_draw = icon_draw
	b.custom_user = d
}

// Name of the icon drawn by b (set_icon), or "" (tests describe controls by it).
box_icon_name :: proc(b: ^ui.Box) -> string {
	if b.custom_draw != icon_draw || b.custom_user == nil do return ""
	return (^Icon_Draw)(b.custom_user).name
}
