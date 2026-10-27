// ui.Font values index this table.
Font_Id :: enum u32 {
	Normal;
	Medium;
	Semibold;
	Bold;
	Mono;
	Italic;
}

fonts: [#run enum_highest_value(Font_Id) + 1]gfx.Font_Face;

F :: (f: Font_Id) -> ui.Font { return cast(ui.Font) f; }

// Per-user app data: ~/Library/Application Support/fastcord on macOS,
// %LOCALAPPDATA%\fastcord on Windows.
app_data_dir :: (sub: string, allocator := temp) -> string {
	#if OS == .WINDOWS return tprint("%\\fastcord\\%", env_var("LOCALAPPDATA"), sub,, allocator);
	else return tprint("%/Library/Application Support/fastcord/%", env_var("HOME"), sub,, allocator);
}

// Environment variable, "" when unset (not copied).
env_var :: (name: string) -> string {
	p := getenv(temp_c_string(name));
	return ifx p then to_string(p) else "";
}

fonts_load :: () {
	weights := gfx.Font_Weight.[.Regular, .Medium, .Semibold, .Bold, .Regular, .Regular];
	for * fonts it.* = gfx.font_system("system", weights[it_index]);
	fonts[Font_Id.Mono] = gfx.font_system(ifx OS == .WINDOWS then "Consolas" else "Menlo");
	fonts[Font_Id.Italic] = gfx.font_system("system", .Regular, italic = true);
	// gg sans is fetched from discord.com/assets at runtime (as the official client does) and cached
	// here; until then the system font stands in.
	visit_files(app_data_dir("fonts"), false, null, (info: *File_Visit_Info, _: *void) {
		if !ends_with(info.short_name, ".woff2") return;
		face := gfx.font_load_file(info.full_name);
		if face == 0 return;
		name := gfx.font_name(face);
		if contains(name, "Italic") {
			if contains(name, "NormalItalic") fonts[Font_Id.Italic] = face;
		} else if contains(name, "SemiBold") {
			fonts[Font_Id.Semibold] = face;
		} else if contains(name, "Medium") {
			fonts[Font_Id.Medium] = face;
		} else if contains(name, "Bold") {
			fonts[Font_Id.Bold] = face;
		} else if contains(name, "Normal") {
			fonts[Font_Id.Normal] = face;
		}
	});
	if fonts[Font_Id.Bold] == 0 fonts[Font_Id.Bold] = fonts[Font_Id.Semibold];
}

ui_shape :: (font: ui.Font, size: float32, text: string) -> ui.Shaped_Run {
	face := fonts[cast(Font_Id)(font)];
	run := gfx.shape(face, size, text);
	m := gfx.font_metrics(face, size);
	glyphs := NewArray(run.glyphs.count, ui.Shaped_Glyph,, temp);
	for run.glyphs glyphs[it_index] = .{x = it.pos.x, advance = it.advance, cluster_start = it.cluster_start, cluster_end = it.cluster_end, handle = cast(u64) it_index};
	rp := New(gfx.Shaped_Run,, temp);
	rp.* = run;
	return ui.Shaped_Run.{glyphs = glyphs, width = run.width, ascent = m.ascent, descent = m.descent, line_h = m.line_height, handle = rp};
}

render :: (cmds: []ui.Draw_Cmd) {
	for c: cmds {
		if c.kind == {
		case .Rect;
			gfx.push_rect(.{dst = cast,force(gfx.Rect)(c.rect), colors = (cast(*[4]gfx.Color) *c.colors).*, radii = c.radii, border = c.border, softness = c.softness});
		case .Text;
			tl := c.layout;
			if tl.spans.data != null {
				render_rich(tl, c.origin, c.colors[0]);
				continue;
			}
			run := cast(*gfx.Shaped_Run)(tl.run.handle);
			if run == null continue;
			for l: tl.lines {
				if l.glyph_end <= l.glyph_start continue;
				part := run.*;
				part.glyphs = array_view(run.glyphs, l.glyph_start, l.glyph_end - l.glyph_start);
				gfx.draw_run(part, .{c.origin.x - l.x_shift, c.origin.y + l.y + tl.baseline}, cast(gfx.Color)(c.colors[0]));
			}
		case .Clip_Push;
			gfx.push_clip(cast,force(gfx.Rect)(c.rect));
		case .Clip_Pop;
			gfx.pop_clip();
		case .Custom;
			if c.box != null && c.box.custom_draw != null c.box.custom_draw(c.box, c.box.custom_user);
		}
	}
}

map_key :: (k: platform.Key) -> ui.Key_Code {
	if k == {
	case .Enter; #through; case .Keypad_Enter;
		return .Enter;
	case .Escape;
		return .Escape;
	case .Left_Bracket;
		return .Left_Bracket;
	case .Right_Bracket;
		return .Right_Bracket;
	case .Backspace;
		return .Backspace;
	case .Delete;
		return .Delete;
	case .Tab;
		return .Tab;
	case .Left;
		return .Left;
	case .Right;
		return .Right;
	case .Up;
		return .Up;
	case .Down;
		return .Down;
	case .Home;
		return .Home;
	case .End;
		return .End;
	case .Page_Up;
		return .Page_Up;
	case .Page_Down;
		return .Page_Down;
	case .A;
		return .A;
	case .C;
		return .C;
	case .V;
		return .V;
	case .X;
		return .X;
	case .Y;
		return .Y;
	case .Z;
		return .Z;
	case .K;
		return .K;
	case .F;
		return .F;
	case .None;
		return .None;
	}
	return .Other;
}

map_events :: (evs: []platform.Event) -> []ui.Input_Event {
	out: [..]ui.Input_Event;
	out.allocator = temp;
	array_reserve(*out, evs.count);
	for e: evs {
		ev := ui.Input_Event.{pos = e.pos, mods = cast,force(ui.Mods) e.mods, click_count = e.click_count};
		if e.kind == {
		case .Mouse_Move;
			ev.kind = .Mouse_Move;
		case .Mouse_Down; #through; case .Mouse_Up;
			ev.kind = ifx e.kind == .Mouse_Down then .Mouse_Down else .Mouse_Up;
			if e.button == {
			case .Left;
				ev.button = .Left;
			case .Right;
				ev.button = .Right;
			case .Middle;
				ev.button = .Middle;
			case;
				continue;
			}
		case .Scroll;
			ev.kind = .Scroll;
			ev.delta = e.delta;
		case .Key_Down;
			ev.kind = .Key_Down;
			ev.key = map_key(e.key);
		case .Text;
			ev.kind = .Text;
			ev.text = e.text;
		case;
			continue;
		}
		array_add(*out, ev);
	}
	return out;
}

map_cursor :: (c: ui.Cursor) -> platform.Cursor {
	if c == {
	case .Default;
		return .Arrow;
	case .Pointer;
		return .Pointer;
	case .IBeam;
		return .IBeam;
	case .Resize_H;
		return .Resize_H;
	case .Resize_V;
		return .Resize_V;
	}
	return .Arrow;
}

// Inline objects in rich text (custom emoji etc.) are drawn by this hook.
draw_inline_object: (sp: ui.Span, r: ui.Rect, opacity: float32);

render_rich :: (tl: *ui.Text_Layout, origin: ui.Vec2, box_color: ui.Color) {
	for l: tl.lines {
		gi := l.glyph_start;
		while gi < l.glyph_end {
			si := tl.run.glyphs[gi].span;
			start := gi;
			while gi < l.glyph_end && tl.run.glyphs[gi].span == si gi += 1;
			sp := tl.spans[si];
			g0 := tl.run.glyphs[start];
			g1 := tl.run.glyphs[gi - 1];
			x := origin.x + g0.x - l.x_shift;
			y := origin.y + l.y;
			if sp.object != .{} {
				oy := y + (tl.line_h - sp.object.y) / 2;
				r := ui.Rect.{x, oy, x + sp.object.x, oy + sp.object.y};
				if draw_inline_object != null draw_inline_object(sp, r, box_color.w);
				continue;
			}
			color := ifx sp.color.w > 0 then sp.color else box_color;
			color.w *= ifx box_color.w > 0 then 1 else 0;
			run := cast(*gfx.Shaped_Run)(tl.span_runs[si].handle);
			if run == null continue;
			h0 := cast(int)(g0.handle);
			h1 := cast(int)(g1.handle);
			part := run.*;
			part.glyphs = array_view(run.glyphs, h0, h1 + 1 - h0);
			gfx.draw_run(part, .{x - run.glyphs[h0].pos.x, y + tl.baseline}, cast(gfx.Color)(color));
			if sp.underline {
				w := g1.x + g1.advance - g0.x;
				gfx.rect(.{x, y + tl.baseline + 2, x + w, y + tl.baseline + 3}, cast(gfx.Color)(color));
			}
			if sp.strike {
				w := g1.x + g1.advance - g0.x;
				sy := round(y + tl.baseline - sp.size * 0.3);
				gfx.rect(.{x, sy, x + w, sy + 1}, cast(gfx.Color)(color));
			}
		}
	}
}


#scope_file

// Odin's math.round: halves away from zero.
round :: (x: float32) -> float32 { return ifx x < 0 then -floor(-x + 0.5) else floor(x + 0.5); }

#if OS == .WINDOWS {
	crt :: #system_library "msvcrt";
	getenv :: (name: *u8) -> *u8 #foreign crt;
} else {
	getenv :: (name: *u8) -> *u8 #foreign libc;
}
