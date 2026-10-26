package app

import "core:os"
import "core:path/filepath"
import "core:strings"
import "fc:gfx"
import "fc:platform"
import "fc:ui"

// ui.Font values index this table.
Font_Id :: enum u32 {
	Normal,
	Medium,
	Semibold,
	Bold,
}

fonts: [Font_Id]gfx.Font_Face

F :: proc(f: Font_Id) -> ui.Font {return ui.Font(f)}

// gg sans is fetched from discord.com/assets at runtime (as the official client
// does) and cached here; until then the system font stands in.
font_cache_dir :: proc(allocator := context.temp_allocator) -> string {
	home := os.get_env("HOME", context.temp_allocator)
	p, _ := filepath.join({home, "Library", "Application Support", "fastcord", "fonts"}, allocator)
	return p
}

fonts_load :: proc() {
	weights := [Font_Id]gfx.Font_Weight {
		.Normal   = .Regular,
		.Medium   = .Medium,
		.Semibold = .Semibold,
		.Bold     = .Bold,
	}
	for id in Font_Id do fonts[id] = gfx.font_system("system", weights[id])
	dir := font_cache_dir()
	fd, err := os.open(dir)
	if err != nil do return
	defer os.close(fd)
	infos, _ := os.read_dir(fd, -1, context.temp_allocator)
	for fi in infos {
		if !strings.has_suffix(fi.name, ".woff2") do continue
		face := gfx.font_load_file(fi.fullpath)
		if face == 0 do continue
		name := gfx.font_name(face)
		switch {
		case strings.contains(name, "SemiBold"):
			fonts[.Semibold] = face
		case strings.contains(name, "Medium"):
			fonts[.Medium] = face
		case strings.contains(name, "Bold"):
			fonts[.Bold] = face
		case strings.contains(name, "Normal"):
			fonts[.Normal] = face
		}
	}
	if fonts[.Bold] == 0 do fonts[.Bold] = fonts[.Semibold]
}

ui_shape :: proc(font: ui.Font, size: f32, text: string) -> ui.Shaped_Run {
	face := fonts[Font_Id(font)]
	run := gfx.shape(face, size, text)
	m := gfx.font_metrics(face, size)
	glyphs := make([]ui.Shaped_Glyph, len(run.glyphs), context.temp_allocator)
	for g, i in run.glyphs {
		glyphs[i] = {x = g.pos.x, advance = g.advance, cluster_start = g.cluster_start, cluster_end = g.cluster_end, handle = u64(i)}
	}
	rp := new_clone(run, context.temp_allocator)
	return ui.Shaped_Run{glyphs = glyphs, width = run.width, ascent = m.ascent, descent = m.descent, line_h = m.line_height, handle = rp}
}

render :: proc(cmds: []ui.Draw_Cmd) {
	for c in cmds {
		switch c.kind {
		case .Rect:
			gfx.push_rect({dst = gfx.Rect(c.rect), colors = transmute([4]gfx.Color)c.colors, radii = c.radii, border = c.border, softness = c.softness})
		case .Text:
			tl := c.layout
			run := (^gfx.Shaped_Run)(tl.run.handle)
			if run == nil do continue
			for l in tl.lines {
				if l.glyph_end <= l.glyph_start do continue
				sub := run^
				sub.glyphs = run.glyphs[l.glyph_start:l.glyph_end]
				gfx.draw_run(sub, {c.origin.x - l.x_shift, c.origin.y + l.y + tl.baseline}, gfx.Color(c.colors[0]))
			}
		case .Clip_Push:
			gfx.push_clip(gfx.Rect(c.rect))
		case .Clip_Pop:
			gfx.pop_clip()
		case .Custom:
			if c.box != nil && c.box.custom_draw != nil do c.box.custom_draw(c.box, c.box.custom_user)
		}
	}
}

map_key :: proc(k: platform.Key) -> ui.Key_Code {
	#partial switch k {
	case .Enter, .Keypad_Enter:
		return .Enter
	case .Escape:
		return .Escape
	case .Backspace:
		return .Backspace
	case .Delete:
		return .Delete
	case .Tab:
		return .Tab
	case .Left:
		return .Left
	case .Right:
		return .Right
	case .Up:
		return .Up
	case .Down:
		return .Down
	case .Home:
		return .Home
	case .End:
		return .End
	case .Page_Up:
		return .Page_Up
	case .Page_Down:
		return .Page_Down
	case .A:
		return .A
	case .C:
		return .C
	case .V:
		return .V
	case .X:
		return .X
	case .Y:
		return .Y
	case .Z:
		return .Z
	case .K:
		return .K
	case .None:
		return .None
	}
	return .Other
}

map_events :: proc(evs: []platform.Event) -> []ui.Input_Event {
	out := make([dynamic]ui.Input_Event, 0, len(evs), context.temp_allocator)
	for e in evs {
		mods := transmute(ui.Mods)e.mods
		ev := ui.Input_Event{pos = e.pos, mods = mods, click_count = e.click_count}
		#partial switch e.kind {
		case .Mouse_Move:
			ev.kind = .Mouse_Move
		case .Mouse_Down, .Mouse_Up:
			ev.kind = e.kind == .Mouse_Down ? .Mouse_Down : .Mouse_Up
			#partial switch e.button {
			case .Left:
				ev.button = .Left
			case .Right:
				ev.button = .Right
			case .Middle:
				ev.button = .Middle
			case:
				continue
			}
		case .Scroll:
			ev.kind = .Scroll
			ev.delta = e.delta
		case .Key_Down:
			ev.kind = .Key_Down
			ev.key = map_key(e.key)
		case .Text:
			ev.kind = .Text
			ev.text = e.text
		case:
			continue
		}
		append(&out, ev)
	}
	return out[:]
}

map_cursor :: proc(c: ui.Cursor) -> platform.Cursor {
	switch c {
	case .Default:
		return .Arrow
	case .Pointer:
		return .Pointer
	case .IBeam:
		return .IBeam
	case .Resize_H:
		return .Resize_H
	case .Resize_V:
		return .Resize_V
	}
	return .Arrow
}
