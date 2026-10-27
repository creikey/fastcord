// ui.Font values index this table.
Font_Id :: enum u32 {
	Normal;
	Medium;
	Semibold;
	Bold;
	Mono;
	Italic;
}

fonts: [#run enum_count(Font_Id)]gfx.Font_Face;

F :: (f: Font_Id) -> ui.Font {return cast(ui.Font)(f);}

// gg sans is fetched from discord.com/assets at runtime (as the official client
// does) and cached here; until then the system font stands in.
font_cache_dir :: (allocator := temp) -> string {
	return app_data_dir("fonts", allocator);
}

// Per-user app data: ~/Library/Application Support/fastcord on macOS,
// %LOCALAPPDATA%\fastcord on Windows.
app_data_dir :: (sub: string, allocator := temp) -> string {
	#if OS == .WINDOWS {
		base := os.get_env("LOCALAPPDATA", temp);
		p, _ := filepath.join(.{base, "fastcord", sub}, allocator);
	} else {
		home := os.get_env("HOME", temp);
		p, _ := filepath.join(.{home, "Library", "Application Support", "fastcord", sub}, allocator);
	}
	return p;
}

fonts_load :: () {
	weights := ([#run enum_count(Font_Id)]gfx.Font_Weight).{
		__IDX__.Normal = .Regular,
		__IDX__.Medium = .Medium,
		__IDX__.Semibold = .Semibold,
		__IDX__.Bold = .Bold,
		__IDX__.Mono = .Regular,
		__IDX__.Italic = .Regular
	};
	for id: Font_Id { fonts[id] = gfx.font_system("system", weights[id]); }
	fonts[.Mono] = gfx.font_system(ifx OS == .WINDOWS then "Consolas" else "Menlo");
	fonts[.Italic] = gfx.font_system("system", .Regular, italic = true);
	dir := font_cache_dir();
	fd, err := os.open(dir);
	if err != null { return; }
	defer os.close(fd);
	infos, _ := os.read_dir(fd, -1, temp);
	for fi: infos {
		if !strings.has_suffix(fi.name, ".woff2") { continue; }
		face := gfx.font_load_file(fi.fullpath);
		if face == 0 { continue; }
		name := gfx.font_name(face);
		if strings.contains(name, "Italic") {
			if strings.contains(name, "NormalItalic") { fonts[.Italic] = face; }
		} else if strings.contains(name, "SemiBold") {
			fonts[.Semibold] = face;
		} else if strings.contains(name, "Medium") {
			fonts[.Medium] = face;
		} else if strings.contains(name, "Bold") {
			fonts[.Bold] = face;
		} else if strings.contains(name, "Normal") {
			fonts[.Normal] = face;
		}
	}
	if fonts[.Bold] == 0 { fonts[.Bold] = fonts[.Semibold]; }
}

ui_shape :: (font: ui.Font, size: float32, text: string) -> ui.Shaped_Run {
	face := fonts[cast(Font_Id)(font)];
	run := gfx.shape(face, size, text);
	m := gfx.font_metrics(face, size);
	glyphs := make_slice(ui.Shaped_Glyph, len(run.glyphs), temp);
	for g, i: run.glyphs {
		at(*glyphs, i).* = .{x = g.pos.x, advance = g.advance, cluster_start = g.cluster_start, cluster_end = g.cluster_end, handle = cast(u64)(i)};
	}
	rp := new_clone(run, temp);
	return ui.Shaped_Run.{glyphs = glyphs, width = run.width, ascent = m.ascent, descent = m.descent, line_h = m.line_height, handle = rp};
}

render :: (cmds: []ui.Draw_Cmd) {
	for c: cmds {
		if c.kind == {
		case .Rect;
			gfx.push_rect(.{dst = cast(gfx.Rect)(c.rect), colors = transmute([4]gfx.Color, c.colors), radii = c.radii, border = c.border, softness = c.softness});
		case .Text;
			tl := c.layout;
			if tl.spans != null {
				render_rich(tl, c.origin, c.colors[0]);
				continue;
			}
			run := cast(*gfx.Shaped_Run)(tl.run.handle);
			if run == null { continue; }
			for l: tl.lines {
				if l.glyph_end <= l.glyph_start { continue; }
				sub := run.*;
				sub.glyphs = sub(run.glyphs, l.glyph_start, l.glyph_end);
				gfx.draw_run(sub, .{c.origin.x - l.x_shift, c.origin.y + l.y + tl.baseline}, cast(gfx.Color)(c.colors[0]));
			}
		case .Clip_Push;
			gfx.push_clip(cast(gfx.Rect)(c.rect));
		case .Clip_Pop;
			gfx.pop_clip();
		case .Custom;
			if c.box != null && c.box.custom_draw != null { c.box.custom_draw(c.box, c.box.custom_user); }
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
	out := make_dynamic(ui.Input_Event, 0, len(evs), temp);
	for e: evs {
		mods := transmute(ui.Mods, e.mods);
		ev := ui.Input_Event.{pos = e.pos, mods = mods, click_count = e.click_count};
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
		append(*out, ev);
	}
	return view(out);
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
			si := get(tl.run.glyphs, gi).span;
			start := gi;
			while gi < l.glyph_end && get(tl.run.glyphs, gi).span == si { gi += 1; }
			sp := tl.spans[si];
			g0 := get(tl.run.glyphs, start);
			g1 := get(tl.run.glyphs, gi - 1);
			x := origin.x + g0.x - l.x_shift;
			y := origin.y + l.y;
			if sp.object != .{} {
				oy := y + (tl.line_h - sp.object.y) / 2;
				r := ui.Rect.{x, oy, x + sp.object.x, oy + sp.object.y};
				if draw_inline_object != null { draw_inline_object(sp, r, box_color.a); }
				continue;
			}
			color := ifx sp.color.a > 0 then sp.color else box_color;
			color.a *= ifx box_color.a > 0 then 1 else 0;
			run := cast(*gfx.Shaped_Run)(tl.span_runs[si].handle);
			if run == null { continue; }
			h0 := cast(int)(g0.handle);
			h1 := cast(int)(g1.handle);
			sub := run.*;
			sub.glyphs = sub(run.glyphs, h0, h1 + 1);
			gfx.draw_run(sub, .{x - get(run.glyphs, h0).pos.x, y + tl.baseline}, cast(gfx.Color)(color));
			if sp.underline {
				w := g1.x + g1.advance - g0.x;
				gfx.rect(.{x, y + tl.baseline + 2, x + w, y + tl.baseline + 3}, cast(gfx.Color)(color));
			}
			if sp.strike {
				w := g1.x + g1.advance - g0.x;
				sy := math.round(y + tl.baseline - sp.size * 0.3);
				gfx.rect(.{x, sy, x + w, sy + 1}, cast(gfx.Color)(color));
			}
		}
	}
}

