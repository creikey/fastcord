// Texture holding the icon's coverage at w_pt x h_pt (rasterized at device pixels, view box fit with meet):
// a square texture stretched over a tall box squashed the tall status-mobile phone.
icon_texture :: (name: string, w_pt: float32, h_pt: float32) -> gfx.Texture {
	s := max(gfx.scale(), 1);
	w, h := cast(int) floor(w_pt * s + 0.5), cast(int) floor(h_pt * s + 0.5); // sizes are positive: Odin's math.round
	key := w | (h << 32); // both sides in the cache's one px
	p := table_find_pointer(*icon_cache, .{name, key});
	if p return p.*;
	tex: gfx.Texture;
	for ICON_NAMES if it == name {
		ic, ok := vector.parse_svg(ICON_DATA[it_index], temp);
		if ok tex = gfx.texture_create(w, h, .R8, vector.rasterize(*ic, w, h, temp));
		break;
	}
	if tex == 0 log_error("icon \"%\" is missing or failed to parse (assets/icons)", name);
	table_set(*icon_cache, .{copy_string(name), key}, tex);
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

icon_textures_lost :: () { name_px_drop(*icon_cache); } // a lost GPU device (textures_lost)

#scope_file

// Icons from assets/icons (Phosphor, MIT; see its README), embedded so the binary is
// self-contained: names without ".svg", and the file contents. On the host: a cross-compile can't run the
// target's File module.
ICON_NAMES, ICON_DATA := #run,host -> []string, []string {
	#import "Basic";
	#import "String";
	#import "File";
	#import "File_Utilities";
	Files :: struct { names, data: [..]string; }
	files: Files;
	visit_files(tprint("%/../../assets/icons", #filepath), false, *files, (info: *File_Visit_Info, files: *Files) {
		if !ends_with(info.short_name, ".svg") return;
		data, ok := read_entire_file(info.full_name);
		assert(ok, info.full_name);
		array_add(*files.names, copy_string(slice(info.short_name, 0, info.short_name.count - 4)));
		array_add(*files.data, data);
	});
	return files.names, files.data;
};

icon_cache: Name_Px_Map;

Icon_Draw :: struct {
	name: string;
	color: ui.Color;
}

icon_draw :: (b: *ui.Box, user: *void) {
	d := cast(*Icon_Draw) user;
	tex := icon_texture(d.name, b.rect.x1 - b.rect.x0, b.rect.y1 - b.rect.y0);
	if tex == 0 return;
	c := cast(gfx.Color) d.color;
	c.w *= b.opacity;
	gfx.push_rect(.{dst = cast,force(gfx.Rect) b.rect, tex = tex, colors = .[c, c, c, c]});
}
