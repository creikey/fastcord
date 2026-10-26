#+build windows
package gfx

// DirectWrite text backend. Shaping + fallback via IDWriteTextLayout drawn
// into a custom IDWriteTextRenderer (collects glyph runs), rasterization via
// IDWriteFactory2::CreateGlyphRunAnalysis (grayscale).
//
// COM calls go through raw vtable indices (no DirectWrite bindings ship with Odin).
// Gap: font_load_memory (needs IDWriteFactory5 in-memory loader) returns 0.

import "base:runtime"
import "core:math"
import "core:unicode/utf8"
import win "core:sys/windows"

foreign import dwrite "system:Dwrite.lib"

@(private = "file")
HRESULT :: win.HRESULT

@(private = "file", default_calling_convention = "system")
foreign dwrite {
	DWriteCreateFactory :: proc(factoryType: u32, iid: ^win.GUID, factory: ^rawptr) -> HRESULT ---
}

@(private = "file")
IID_IDWriteFactory2 := win.GUID{0x0439fc60, 0xca44, 0x4994, {0x8d, 0xee, 0x3a, 0x9a, 0xf7, 0xb7, 0x32, 0xec}}
@(private = "file")
IID_IDWriteTextRenderer := win.GUID{0xef8a8135, 0x5cc6, 0x4fe3, {0x8b, 0x6c, 0xd7, 0x3d, 0xd4, 0x0e, 0x4b, 0x2c}}
@(private = "file")
IID_IDWritePixelSnapping := win.GUID{0xeaf3a2da, 0xecf4, 0x4d24, {0xb6, 0x44, 0xb3, 0x4f, 0x68, 0x42, 0x02, 0x4b}}
@(private = "file")
IID_IUnknown := win.GUID{0x00000000, 0x0000, 0x0000, {0xc0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46}}

@(private = "file")
vt :: #force_inline proc "contextless" (obj: rawptr, idx: int) -> rawptr {
	return (^[^]rawptr)(obj)^[idx]
}

@(private = "file")
release :: proc "contextless" (obj: rawptr) {
	if obj == nil do return
	(cast(proc "system" (rawptr) -> u32)vt(obj, 2))(obj)
}

@(private = "file")
add_ref :: proc "contextless" (obj: rawptr) {
	(cast(proc "system" (rawptr) -> u32)vt(obj, 1))(obj)
}

@(private = "file")
DWRITE_GLYPH_OFFSET :: struct {advanceOffset, ascenderOffset: f32}

@(private = "file")
DWRITE_GLYPH_RUN :: struct {
	fontFace:      rawptr,
	fontEmSize:    f32,
	glyphCount:    u32,
	glyphIndices:  [^]u16,
	glyphAdvances: [^]f32,
	glyphOffsets:  [^]DWRITE_GLYPH_OFFSET,
	isSideways:    win.BOOL,
	bidiLevel:     u32,
}

@(private = "file")
DWRITE_GLYPH_RUN_DESCRIPTION :: struct {
	localeName:   [^]u16,
	string:       [^]u16,
	stringLength: u32,
	clusterMap:   [^]u16,
	textPosition: u32,
}

@(private = "file")
DWRITE_FONT_METRICS :: struct {
	designUnitsPerEm:       u16,
	ascent:                 u16,
	descent:                u16,
	lineGap:                i16,
	capHeight:              u16,
	xHeight:                u16,
	underlinePosition:      i16,
	underlineThickness:     u16,
	strikethroughPosition:  i16,
	strikethroughThickness: u16,
}

@(private = "file")
DWRITE_LINE_METRICS :: struct {
	length:                   u32,
	trailingWhitespaceLength: u32,
	newlineLength:            u32,
	height:                   f32,
	baseline:                 f32,
	isTrimmed:                win.BOOL,
}

@(private = "file")
Native_Face :: struct {
	family: []u16, // NUL-terminated
	weight: u32,
	style:  u32, // DWRITE_FONT_STYLE
}

@(private = "file")
Font_Inst :: struct {
	face:   rawptr, // IDWriteFontFace (AddRef'd)
	size:   f32, // px (em size)
	family: ^Native_Face,
}

// Custom IDWriteTextRenderer: a COM object whose vtable points at Odin procs.
@(private = "file")
Renderer :: struct {
	vtable: ^[10]rawptr,
}

@(private = "file")
DW :: struct {
	factory:  rawptr, // IDWriteFactory2
	renderer: Renderer,
	vtable:   [10]rawptr,
	insts:    [dynamic]Font_Inst,
	// per-shape state used by the renderer callback
	cur_out:  ^[dynamic]Raw_Glyph,
	cur_map:  []int, // utf16 index -> utf8 byte
	cur_size: f32,
	cur_family: ^Native_Face,
	cur_width: f32,
	ctx:      runtime.Context,
}

@(private = "file")
dw: DW

@(private)
_text_backend_init :: proc() {
	dw.ctx = context
	append(&dw.insts, Font_Inst{})
	DWriteCreateFactory(0 /*SHARED*/, &IID_IDWriteFactory2, &dw.factory)
	dw.vtable = {
		rawptr(r_query_interface), rawptr(r_add_ref), rawptr(r_release),
		rawptr(r_is_pixel_snapping_disabled), rawptr(r_get_current_transform), rawptr(r_get_pixels_per_dip),
		rawptr(r_draw_glyph_run), rawptr(r_draw_underline), rawptr(r_draw_strikethrough), rawptr(r_draw_inline_object),
	}
	dw.renderer.vtable = &dw.vtable
}

@(private)
_text_backend_shutdown :: proc() {
	for f in dw.insts do release(f.face)
	delete(dw.insts)
	release(dw.factory)
	dw = {}
}

@(private)
_font_free :: proc(native: rawptr) {
	nf := (^Native_Face)(native)
	if nf == nil do return
	delete(nf.family)
	free(nf)
}

@(private)
_font_load_memory :: proc(data: []byte) -> rawptr {
	return nil // TODO: IDWriteFactory5::UnpackFontFile (WOFF2) + CreateInMemoryFontFileLoader
}

@(private)
_font_system :: proc(name: string, weight: Font_Weight, italic: bool) -> rawptr {
	nf := new(Native_Face)
	nf.style = italic ? 2 /*ITALIC*/ : 0
	fam := name == "" || name == "system" ? "Segoe UI" : name
	nf.family = win.utf8_to_utf16(fam, context.allocator)
	// utf8_to_utf16 is NUL-terminated in its backing storage; ensure explicitly
	buf := make([]u16, len(nf.family) + 1)
	copy(buf, nf.family)
	delete(nf.family)
	nf.family = buf
	switch weight {
	case .Regular:  nf.weight = 400
	case .Medium:   nf.weight = 500
	case .Semibold: nf.weight = 600
	case .Bold:     nf.weight = 700
	}
	return nf
}

@(private = "file")
register_face :: proc(face: rawptr, size: f32, family: ^Native_Face) -> u32 {
	for f, i in dw.insts {
		if f.face == face && f.size == size do return u32(i)
	}
	add_ref(face)
	append(&dw.insts, Font_Inst{face = face, size = size, family = family})
	return u32(len(dw.insts) - 1)
}

@(private)
_font_instance :: proc(native: rawptr, size_px: f32) -> u32 {
	nf := (^Native_Face)(native)
	// system collection -> family -> first matching font -> font face
	coll: rawptr
	(cast(proc "system" (rawptr, ^rawptr, win.BOOL) -> HRESULT)vt(dw.factory, 3))(dw.factory, &coll, false)
	if coll == nil do return 0
	defer release(coll)
	index: u32
	exists: win.BOOL
	(cast(proc "system" (rawptr, [^]u16, ^u32, ^win.BOOL) -> HRESULT)vt(coll, 5))(coll, raw_data(nf.family), &index, &exists)
	if !exists do index = 0
	family: rawptr
	(cast(proc "system" (rawptr, u32, ^rawptr) -> HRESULT)vt(coll, 4))(coll, index, &family)
	if family == nil do return 0
	defer release(family)
	font: rawptr
	(cast(proc "system" (rawptr, u32, u32, u32, ^rawptr) -> HRESULT)vt(family, 7))(family, nf.weight, 5 /*NORMAL stretch*/, nf.style, &font)
	if font == nil do return 0
	defer release(font)
	face: rawptr
	(cast(proc "system" (rawptr, ^rawptr) -> HRESULT)vt(font, 13))(font, &face)
	if face == nil do return 0
	defer release(face)
	return register_face(face, size_px, nf)
}

@(private)
_font_metrics :: proc(inst: u32) -> (ascent, descent, leading: f32) {
	fi := dw.insts[inst]
	if fi.face == nil do return
	m: DWRITE_FONT_METRICS
	(cast(proc "system" (rawptr, ^DWRITE_FONT_METRICS))vt(fi.face, 8))(fi.face, &m)
	k := fi.size / f32(max(m.designUnitsPerEm, 1))
	return f32(m.ascent) * k, f32(m.descent) * k, f32(m.lineGap) * k
}

@(private)
_font_name :: proc(inst: u32, allocator: runtime.Allocator) -> string {
	fi := dw.insts[inst]
	if fi.family == nil do return ""
	s, _ := win.utf16_to_utf8(fi.family.family[:len(fi.family.family) - 1], allocator)
	return s
}

@(private)
_shape :: proc(inst: u32, text: string, out: ^[dynamic]Raw_Glyph) -> f32 {
	fi := dw.insts[inst]
	if fi.face == nil || fi.family == nil do return 0
	wide := make([dynamic]u16, 0, len(text) + 1, context.temp_allocator)
	map16 := make([dynamic]int, 0, len(text) + 1, context.temp_allocator)
	for i := 0; i < len(text); {
		r, n := utf8.decode_rune_in_string(text[i:])
		if r >= 0x10000 {
			rr := r - 0x10000
			append(&wide, u16(0xD800 + (rr >> 10)), u16(0xDC00 + (rr & 0x3ff)))
			append(&map16, i, i)
		} else if r == '\n' || r == '\r' || r == '\t' {
			// DirectWrite would start a new layout line; ui breaks lines itself and needs one glyph here.
			// Tabs are widened below, once line starts are known.
			append(&wide, u16(' '))
			append(&map16, i)
		} else {
			append(&wide, u16(r))
			append(&map16, i)
		}
		i += max(n, 1)
	}
	append(&map16, len(text))
	locale := [6]u16{'e', 'n', '-', 'u', 's', 0}

	format: rawptr
	(cast(proc "system" (rawptr, [^]u16, rawptr, u32, u32, u32, f32, [^]u16, ^rawptr) -> HRESULT)vt(dw.factory, 15))(
		dw.factory, raw_data(fi.family.family), nil, fi.family.weight, fi.family.style, 5, fi.size, &locale[0], &format)
	if format == nil do return 0
	defer release(format)
	(cast(proc "system" (rawptr, u32) -> HRESULT)vt(format, 5))(format, 1 /*NO_WRAP*/)
	layout: rawptr
	(cast(proc "system" (rawptr, [^]u16, u32, rawptr, f32, f32, ^rawptr) -> HRESULT)vt(dw.factory, 18))(
		dw.factory, raw_data(wide), u32(len(wide)), format, 1e7, 1e7, &layout)
	if layout == nil do return 0
	defer release(layout)

	dw.cur_out = out
	dw.cur_map = map16[:]
	dw.cur_size = fi.size
	dw.cur_family = fi.family
	dw.cur_width = 0
	// Draw(context, renderer, originX, originY)
	first := len(out)
	(cast(proc "system" (rawptr, rawptr, rawptr, f32, f32) -> HRESULT)vt(layout, 58))(layout, nil, &dw.renderer, 0, 0)
	dw.cur_out = nil

	// Draw reports y from the layout's top; callers want it from the baseline, as CoreText gives it.
	line: DWRITE_LINE_METRICS
	nlines: u32
	(cast(proc "system" (rawptr, ^DWRITE_LINE_METRICS, u32, ^u32) -> HRESULT)vt(layout, 59))(layout, &line, 1, &nlines)
	for &g in out[first:] do g.y -= line.baseline

	// Tab stops every 4 spaces from the start of each hard line (CSS tab-size: 4).
	line_x, shift: f32
	for &g in out[first:] {
		g.x += shift
		if g.cluster_start >= len(text) do continue
		switch text[g.cluster_start] {
		case '\n':
			line_x = g.x + g.advance
		case '\t':
			stop := 4 * g.advance // the tab was shaped as a space
			if stop <= 0 do continue
			col := g.x - line_x
			adv := (math.floor(col / stop) + 1) * stop - col
			shift += adv - g.advance
			g.advance = adv
		}
	}
	dw.cur_width += shift

	// cluster_end = next distinct cluster start
	for &r, i in out {
		r.cluster_end = len(text)
		for j in 0 ..< len(out) {
			if j != i && out[j].cluster_start > r.cluster_start && out[j].cluster_start < r.cluster_end do r.cluster_end = out[j].cluster_start
		}
	}
	return dw.cur_width
}

// ---- IDWriteTextRenderer implementation

@(private = "file")
r_query_interface :: proc "system" (this: rawptr, riid: ^win.GUID, out: ^rawptr) -> HRESULT {
	if riid^ == IID_IUnknown || riid^ == IID_IDWriteTextRenderer || riid^ == IID_IDWritePixelSnapping {
		out^ = this
		return 0
	}
	out^ = nil
	return HRESULT(-2147467262) // E_NOINTERFACE
}
@(private = "file")
r_add_ref :: proc "system" (this: rawptr) -> u32 {return 1}
@(private = "file")
r_release :: proc "system" (this: rawptr) -> u32 {return 1}
@(private = "file")
r_is_pixel_snapping_disabled :: proc "system" (this: rawptr, ctx: rawptr, out: ^win.BOOL) -> HRESULT {
	out^ = true // keep fractional positions; we snap ourselves
	return 0
}
@(private = "file")
r_get_current_transform :: proc "system" (this: rawptr, ctx: rawptr, m: ^[6]f32) -> HRESULT {
	m^ = {1, 0, 0, 1, 0, 0}
	return 0
}
@(private = "file")
r_get_pixels_per_dip :: proc "system" (this: rawptr, ctx: rawptr, out: ^f32) -> HRESULT {
	out^ = 1
	return 0
}
@(private = "file")
r_draw_underline :: proc "system" (this: rawptr, ctx: rawptr, x, y: f32, u: rawptr, effect: rawptr) -> HRESULT {return 0}
@(private = "file")
r_draw_strikethrough :: proc "system" (this: rawptr, ctx: rawptr, x, y: f32, s: rawptr, effect: rawptr) -> HRESULT {return 0}
@(private = "file")
r_draw_inline_object :: proc "system" (this: rawptr, ctx: rawptr, x, y: f32, obj: rawptr, sideways, rtl: win.BOOL, effect: rawptr) -> HRESULT {return 0}

@(private = "file")
r_draw_glyph_run :: proc "system" (this: rawptr, ctx: rawptr, x, y: f32, mode: u32, run: ^DWRITE_GLYPH_RUN, desc: ^DWRITE_GLYPH_RUN_DESCRIPTION, effect: rawptr) -> HRESULT {
	context = dw.ctx
	if dw.cur_out == nil do return 0
	finst := register_face(run.fontFace, run.fontEmSize, dw.cur_family)
	n := int(run.glyphCount)
	// glyph -> first utf16 char of its cluster (within this run)
	glyph_char := make([]int, n, context.temp_allocator)
	for &gc in glyph_char do gc = -1
	for ci in 0 ..< int(desc.stringLength) {
		gi := int(desc.clusterMap[ci])
		if gi < n && glyph_char[gi] < 0 do glyph_char[gi] = ci
	}
	last := 0
	for gi in 0 ..< n {
		if glyph_char[gi] < 0 do glyph_char[gi] = last
		last = glyph_char[gi]
	}
	pen := x
	rtl := run.bidiLevel & 1 != 0
	for gi in 0 ..< n {
		adv := run.glyphAdvances != nil ? run.glyphAdvances[gi] : 0
		off := run.glyphOffsets != nil ? run.glyphOffsets[gi] : DWRITE_GLYPH_OFFSET{}
		gx := rtl ? pen - adv - off.advanceOffset : pen + off.advanceOffset
		u16i := int(desc.textPosition) + glyph_char[gi]
		start := dw.cur_map[clamp(u16i, 0, len(dw.cur_map) - 1)]
		append(dw.cur_out, Raw_Glyph{font = finst, glyph = u32(run.glyphIndices[gi]), x = gx, y = y - off.ascenderOffset, advance = adv, cluster_start = start})
		pen += rtl ? -adv : adv
	}
	dw.cur_width = max(dw.cur_width, pen)
	return 0
}

// ---- Rasterization

@(private = "file")
DWRITE_COLOR_GLYPH_RUN :: struct {
	glyphRun:            DWRITE_GLYPH_RUN,
	glyphRunDescription: ^DWRITE_GLYPH_RUN_DESCRIPTION,
	baselineOriginX:     f32,
	baselineOriginY:     f32,
	runColor:            [4]f32,
	paletteIndex:        u16,
}

// Grayscale coverage of a glyph run with its baseline origin at (x, y); r is in pixels, y down.
@(private = "file")
rasterize_alpha :: proc(run: ^DWRITE_GLYPH_RUN, x, y: f32, allocator: runtime.Allocator) -> (pixels: []u8, r: win.RECT) {
	analysis: rawptr
	// IDWriteFactory2::CreateGlyphRunAnalysis(run, transform, renderingMode, measuringMode, gridFitMode, antialiasMode, x, y, out)
	hr := (cast(proc "system" (rawptr, ^DWRITE_GLYPH_RUN, rawptr, u32, u32, u32, u32, f32, f32, ^rawptr) -> HRESULT)vt(dw.factory, 30))(
		dw.factory, run, nil, 5 /*NATURAL_SYMMETRIC*/, 0 /*NATURAL*/, 1 /*GRID_FIT_DISABLED*/, 1 /*GRAYSCALE*/, x, y, &analysis)
	if hr < 0 || analysis == nil do return
	defer release(analysis)
	(cast(proc "system" (rawptr, u32, ^win.RECT) -> HRESULT)vt(analysis, 3))(analysis, 0 /*ALIASED_1x1*/, &r)
	w, h := r.right - r.left, r.bottom - r.top
	if w <= 0 || h <= 0 do return nil, {}
	pixels = make([]u8, int(w * h), allocator)
	(cast(proc "system" (rawptr, u32, ^win.RECT, [^]u8, u32) -> HRESULT)vt(analysis, 4))(analysis, 0, &r, raw_data(pixels), u32(len(pixels)))
	return
}

@(private)
_rasterize :: proc(inst: u32, glyph: u32, subpx: f32, allocator: runtime.Allocator) -> Glyph_Bitmap {
	fi := dw.insts[inst]
	if fi.face == nil do return {}
	idx := u16(glyph)
	adv: f32 = 0
	off := DWRITE_GLYPH_OFFSET{}
	run := DWRITE_GLYPH_RUN{fontFace = fi.face, fontEmSize = fi.size, glyphCount = 1, glyphIndices = &idx, glyphAdvances = &adv, glyphOffsets = &off}

	// Color fonts (Segoe UI Emoji's COLR layers): IDWriteFactory2::TranslateColorGlyphRun fails with
	// DWRITE_E_NOCOLOR for plain glyphs, which then take the grayscale path.
	layers: rawptr
	hr := (cast(proc "system" (rawptr, f32, f32, ^DWRITE_GLYPH_RUN, rawptr, u32, rawptr, u32, ^rawptr) -> HRESULT)vt(dw.factory, 28))(
		dw.factory, subpx, 0, &run, nil, 0 /*NATURAL*/, nil, 0, &layers)
	if hr >= 0 && layers != nil {
		defer release(layers)
		return rasterize_color(layers, allocator)
	}

	pixels, r := rasterize_alpha(&run, subpx, 0, allocator)
	if pixels == nil do return {}
	return {w = r.right - r.left, h = r.bottom - r.top, left = r.left, top = r.top, pixels = pixels}
}

// Composites each color layer over the previous ones; output is straight-alpha RGBA like the CoreText path.
@(private = "file")
rasterize_color :: proc(layers: rawptr, allocator: runtime.Allocator) -> Glyph_Bitmap {
	Layer :: struct {
		pixels: []u8,
		r:      win.RECT,
		color:  [4]f32,
	}
	list := make([dynamic]Layer, 0, 8, context.temp_allocator)
	bounds := win.RECT{max(i32), max(i32), min(i32), min(i32)}
	for {
		has_run: win.BOOL
		if (cast(proc "system" (rawptr, ^win.BOOL) -> HRESULT)vt(layers, 3))(layers, &has_run) < 0 || !has_run do break
		cr: ^DWRITE_COLOR_GLYPH_RUN
		if (cast(proc "system" (rawptr, ^^DWRITE_COLOR_GLYPH_RUN) -> HRESULT)vt(layers, 4))(layers, &cr) < 0 || cr == nil do break
		pixels, r := rasterize_alpha(&cr.glyphRun, cr.baselineOriginX, cr.baselineOriginY, context.temp_allocator)
		if pixels == nil do continue
		// Palette index 0xFFFF means "the text color"; emoji are drawn untinted, so use black as CoreText does.
		color := cr.paletteIndex == 0xFFFF ? [4]f32{0, 0, 0, 1} : cr.runColor
		append(&list, Layer{pixels, r, color})
		bounds.left, bounds.top = min(bounds.left, r.left), min(bounds.top, r.top)
		bounds.right, bounds.bottom = max(bounds.right, r.right), max(bounds.bottom, r.bottom)
	}
	if len(list) == 0 do return {}
	w, h := bounds.right - bounds.left, bounds.bottom - bounds.top
	if w <= 0 || h <= 0 || w > 1024 || h > 1024 do return {}

	acc := make([][4]f32, int(w * h), context.temp_allocator) // premultiplied
	for l in list {
		lw := l.r.right - l.r.left
		for y in l.r.top ..< l.r.bottom {
			for x in l.r.left ..< l.r.right {
				a := f32(l.pixels[(y - l.r.top) * lw + (x - l.r.left)]) / 255 * l.color.a
				if a == 0 do continue
				d := &acc[(y - bounds.top) * w + (x - bounds.left)]
				d^ = {l.color.r * a, l.color.g * a, l.color.b * a, a} + d^ * (1 - a)
			}
		}
	}
	out := make([]u8, int(w * h) * 4, allocator)
	for p, i in acc {
		if p.a <= 0 do continue
		out[i * 4 + 0] = u8(min(p.r / p.a * 255 + 0.5, 255))
		out[i * 4 + 1] = u8(min(p.g / p.a * 255 + 0.5, 255))
		out[i * 4 + 2] = u8(min(p.b / p.a * 255 + 0.5, 255))
		out[i * 4 + 3] = u8(min(p.a * 255 + 0.5, 255))
	}
	return {w = w, h = h, left = bounds.left, top = bounds.top, pixels = out, is_color = true}
}
