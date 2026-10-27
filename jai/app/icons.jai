#scope_file

// Icons extracted from the official client (tools/probes/discord_icons.py),
// embedded so the binary is self-contained.
// Icons extracted from the official client (tools/probes/discord_icons.py),
// embedded so the binary is self-contained.
ICON_FILES := #run load_directory("../../assets/icons", #filepath);

Icon_Key :: struct {
	name: string;
	px: int;
}

icon_cache: Map(Icon_Key, gfx.Texture);

icon_svg :: (name: string) -> string, bool {
	want := strings.concatenate(.{name, ".svg"}, temp);
	for f: ICON_FILES {
		if strings.has_suffix(f.name, want) && (len(f.name) == len(want) || f.name[len(f.name) - len(want) - 1] == #char "/") {
			return as_string(f.data), true;
		}
	}
	return "", false;
}
#scope_export

// Texture holding the icon's coverage at size_pt (rasterized at device pixels).
icon_texture :: (name: string, size_pt: float32) -> gfx.Texture {
	px := cast(int)(math.round(size_pt * max(gfx.scale(), 1)));
	{ t, ok := map_find(icon_cache, .{name, px});
	if ok { return t; } }
	src, ok := icon_svg(name);
	tex: gfx.Texture;
	if ok {
		{ ic, pok := vector.parse_svg(src, temp);
		if pok {
			cov := vector.rasterize(*ic, px, px, temp);
			tex = gfx.texture_create(px, px, .R8, cov);
		} }
	}
	at(*icon_cache, .{clone(name), px}).* = tex;
	return tex;
}
#scope_file

Icon_Draw :: struct {
	name: string;
	color: ui.Color;
}

icon_draw :: (b: *ui.Box, user: *void) {
	d := cast(*Icon_Draw)(user);
	tex := icon_texture(d.name, b.rect.x1 - b.rect.x0);
	if tex == 0 { return; }
	c := cast(gfx.Color)(d.color);
	c.a *= b.opacity;
	gfx.push_rect(.{dst = cast(gfx.Rect)(b.rect), tex = tex, colors = .{c, c, c, c}});
}
#scope_export

// A size x size box drawing the named icon tinted with color.
icon :: (id: string, name: string, size: float32, color: ui.Color, flags: ui.Box_Flags = .{}) -> *ui.Box {
	b := ui.box(id, flags);
	b.semantic_size = .[ui.px(size), ui.px(size)];
	set_icon(b, name, color);
	return b;
}

// Draw an icon over any box (fills its rect).
set_icon :: (b: *ui.Box, name: string, color: ui.Color) {
	d := new(Icon_Draw, temp);
	d.* = .{name, color};
	b.custom_draw = icon_draw;
	b.custom_user = d;
}

// Name of the icon drawn by b (set_icon), or "" (tests describe controls by it).
box_icon_name :: (b: *ui.Box) -> string {
	if b.custom_draw != icon_draw || b.custom_user == null { return ""; }
	return cast(*Icon_Draw)(b.custom_user).name;
}

