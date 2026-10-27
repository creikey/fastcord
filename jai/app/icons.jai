// Texture holding the icon's coverage at size_pt (rasterized at device pixels).
icon_texture :: (name: string, size_pt: float32) -> gfx.Texture {
	px := cast(int) floor(size_pt * max(gfx.scale(), 1) + 0.5); // sizes are positive: Odin's math.round
	p := table_find_pointer(*icon_cache, .{name, px});
	if p return p.*;
	tex: gfx.Texture;
	for ICON_FILES if it.name == name {
		ic, ok := vector.parse_svg(it.data, temp);
		if ok tex = gfx.texture_create(px, px, .R8, vector.rasterize(*ic, px, px, temp));
		break;
	}
	table_set(*icon_cache, .{copy_string(name), px}, tex);
	return tex;
}

// A size x size box drawing the named icon tinted with color.
icon :: (id: string, name: string, size: float32, color: ui.Color, flags: ui.Box_Flags = 0) -> *ui.Box {
	b := ui.box(id, flags);
	b.semantic_size = .[ui.px(size), ui.px(size)];
	set_icon(b, name, color);
	return b;
}

// Draw an icon over any box (fills its rect).
set_icon :: (b: *ui.Box, name: string, color: ui.Color) {
	d := New(Icon_Draw,, temp);
	d.* = .{name, color};
	b.custom_draw = icon_draw;
	b.custom_user = d;
}

// Name of the icon drawn by b (set_icon), or "" (tests describe controls by it).
box_icon_name :: (b: *ui.Box) -> string {
	if b.custom_draw != icon_draw || b.custom_user == null return "";
	return (cast(*Icon_Draw) b.custom_user).name;
}

#scope_file

// Icons extracted from the official client (tools/probes/discord_icons.py), embedded so the binary is
// self-contained: name without ".svg", file contents.
Icon_File :: struct { name, data: string; }
ICON_FILES := #run -> []Icon_File {
	files: [..]Icon_File;
	visit_files(tprint("%/../../assets/icons", #filepath), false, *files, (info: *File_Visit_Info, files: *[..]Icon_File) {
		if !ends_with(info.short_name, ".svg") return;
		data, ok := read_entire_file(info.full_name);
		assert(ok, info.full_name);
		array_add(files, .{copy_string(to_string(info.short_name.data, info.short_name.count - 4)), data});
	});
	return files;
};

icon_cache: Name_Px_Map;

Icon_Draw :: struct {
	name: string;
	color: ui.Color;
}

icon_draw :: (b: *ui.Box, user: *void) {
	d := cast(*Icon_Draw) user;
	tex := icon_texture(d.name, b.rect.x1 - b.rect.x0);
	if tex == 0 return;
	c := cast(gfx.Color) d.color;
	c.w *= b.opacity;
	gfx.push_rect(.{dst = cast,force(gfx.Rect) b.rect, tex = tex, colors = .[c, c, c, c]});
}
