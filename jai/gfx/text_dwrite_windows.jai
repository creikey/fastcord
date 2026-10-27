// DirectWrite text backend. Shaping + fallback via IDWriteTextLayout drawn
// into a custom IDWriteTextRenderer (collects glyph runs), rasterization via
// IDWriteFactory2::CreateGlyphRunAnalysis (grayscale).
//
// COM calls go through raw vtable indices (no DirectWrite bindings ship with Odin).
// Gap: font_load_memory (needs IDWriteFactory5 in-memory loader) returns 0.





#scope_file

HRESULT :: win.HRESULT;
	DWriteCreateFactory :: (factoryType: u32, iid: *win.GUID, factory: **void) -> HRESULT #foreign dwrite;

IID_IDWriteFactory2 := win.GUID.{0x0439fc60, 0xca44, 0x4994, .{0x8d, 0xee, 0x3a, 0x9a, 0xf7, 0xb7, 0x32, 0xec}};
IID_IDWriteTextRenderer := win.GUID.{0xef8a8135, 0x5cc6, 0x4fe3, .{0x8b, 0x6c, 0xd7, 0x3d, 0xd4, 0x0e, 0x4b, 0x2c}};
IID_IDWritePixelSnapping := win.GUID.{0xeaf3a2da, 0xecf4, 0x4d24, .{0xb6, 0x44, 0xb3, 0x4f, 0x68, 0x42, 0x02, 0x4b}};
IID_IUnknown := win.GUID.{0x00000000, 0x0000, 0x0000, .{0xc0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46}};

vt :: inline (obj: *void, idx: int) -> *void #no_context {
	return (cast(***void)(obj)).*[idx];
};

release :: (obj: *void) #no_context {
	if obj == null { return; }
	(cast((*void) -> u32 #c_call)vt(obj, 2))(obj);
}

add_ref :: (obj: *void) #no_context {
	(cast((*void) -> u32 #c_call)vt(obj, 1))(obj);
}

DWRITE_GLYPH_OFFSET :: struct {advanceOffset, ascenderOffset: float32;}

DWRITE_GLYPH_RUN :: struct {
	fontFace: *void;
	fontEmSize: float32;
	glyphCount: u32;
	glyphIndices: *u16;
	glyphAdvances: *float32;
	glyphOffsets: *DWRITE_GLYPH_OFFSET;
	isSideways: win.BOOL;
	bidiLevel: u32;
}

DWRITE_GLYPH_RUN_DESCRIPTION :: struct {
	localeName: *u16;
	string: *u16;
	stringLength: u32;
	clusterMap: *u16;
	textPosition: u32;
}

DWRITE_FONT_METRICS :: struct {
	designUnitsPerEm: u16;
	ascent: u16;
	descent: u16;
	lineGap: s16;
	capHeight: u16;
	xHeight: u16;
	underlinePosition: s16;
	underlineThickness: u16;
	strikethroughPosition: s16;
	strikethroughThickness: u16;
}

DWRITE_LINE_METRICS :: struct {
	length: u32;
	trailingWhitespaceLength: u32;
	newlineLength: u32;
	height: float32;
	baseline: float32;
	isTrimmed: win.BOOL;
}

Native_Face :: struct {
	family: []u16; // NUL-terminated
	weight: u32;
	style: u32; // DWRITE_FONT_STYLE
}

Font_Inst :: struct {
	face: *void; // IDWriteFontFace (AddRef'd)
	size: float32; // px (em size)
	family: *Native_Face;
}

// Custom IDWriteTextRenderer: a COM object whose vtable points at Odin procs.
Renderer :: struct {
	vtable: *[10]*void;
}

DW :: struct {
	factory: *void; // IDWriteFactory2
	renderer: Renderer;
	vtable: [10]*void;
	insts: [..]Font_Inst;
	// per-shape state used by the renderer callback
	cur_out: *[..]Raw_Glyph;
	cur_map: []int; // utf16 index -> utf8 byte
	cur_size: float32;
	cur_family: *Native_Face;
	cur_width: float32;
	ctx: type_of(context);
}

dw: DW;
#scope_module

_text_backend_init :: () {
	dw.ctx = context;
	append(*dw.insts, Font_Inst.{});
	DWriteCreateFactory(0, *IID_IDWriteFactory2, *dw.factory);
	dw.vtable = .{
		cast(*void)(r_query_interface), cast(*void)(r_add_ref), cast(*void)(r_release),
		cast(*void)(r_is_pixel_snapping_disabled), cast(*void)(r_get_current_transform), cast(*void)(r_get_pixels_per_dip),
		cast(*void)(r_draw_glyph_run), cast(*void)(r_draw_underline), cast(*void)(r_draw_strikethrough), cast(*void)(r_draw_inline_object)
	};
	dw.renderer.vtable = *dw.vtable;
}

_text_backend_shutdown :: () {
	for f: dw.insts { release(f.face); }
	delete(dw.insts);
	release(dw.factory);
	dw = .{};
}

_font_free :: (native: *void) {
	nf := cast(*Native_Face)(native);
	if nf == null { return; }
	delete(nf.family);
	free(nf);
}

_font_load_memory :: (data: []u8) -> *void {
	return null; // TODO: IDWriteFactory5::UnpackFontFile (WOFF2) + CreateInMemoryFontFileLoader
}

_font_system :: (name: string, weight: Font_Weight, italic: bool) -> *void {
	nf := new(Native_Face);
	nf.style = ifx italic then 2 else 0;
	fam := ifx name == "" || name == "system" then "Segoe UI" else name;
	nf.family = win.utf8_to_utf16(fam, context.allocator);
	// utf8_to_utf16 is NUL-terminated in its backing storage; ensure explicitly
	buf := make_slice(u16, len(nf.family) + 1);
	copy(buf, nf.family);
	delete(nf.family);
	nf.family = buf;
	if weight == {
	case .Regular;  nf.weight = 400;
	case .Medium;   nf.weight = 500;
	case .Semibold; nf.weight = 600;
	case .Bold;     nf.weight = 700;
	}
	return nf;
}
#scope_file

register_face :: (face: *void, size: float32, family: *Native_Face) -> u32 {
	for f, i: dw.insts {
		if f.face == face && f.size == size { return cast(u32)(i); }
	}
	add_ref(face);
	append(*dw.insts, Font_Inst.{face = face, size = size, family = family});
	return cast(u32)(len(dw.insts) - 1);
}
#scope_module

_font_instance :: (native: *void, size_px: float32) -> u32 {
	nf := cast(*Native_Face)(native);
	// system collection -> family -> first matching font -> font face
	coll: *void;
	(cast((*void, **void, win.BOOL) -> HRESULT #c_call)vt(dw.factory, 3))(dw.factory, *coll, false);
	if coll == null { return 0; }
	defer release(coll);
	index: u32;
	exists: win.BOOL;
	(cast((*void, *u16, *u32, *win.BOOL) -> HRESULT #c_call)vt(coll, 5))(coll, raw_data(nf.family), *index, *exists);
	if !exists { index = 0; }
	family: *void;
	(cast((*void, u32, **void) -> HRESULT #c_call)vt(coll, 4))(coll, index, *family);
	if family == null { return 0; }
	defer release(family);
	font: *void;
	(cast((*void, u32, u32, u32, **void) -> HRESULT #c_call)vt(family, 7))(family, nf.weight, 5, nf.style, *font);
	if font == null { return 0; }
	defer release(font);
	face: *void;
	(cast((*void, **void) -> HRESULT #c_call)vt(font, 13))(font, *face);
	if face == null { return 0; }
	defer release(face);
	return register_face(face, size_px, nf);
}

_font_metrics :: (inst: u32) -> float32, float32, float32 {
	ascent: float32;
	descent: float32;
	leading: float32;
	fi := dw.insts[inst];
	if fi.face == null { return ascent, descent, leading; }
	m: DWRITE_FONT_METRICS;
	(cast((*void, *DWRITE_FONT_METRICS) #c_call)vt(fi.face, 8))(fi.face, *m);
	k := fi.size / cast(float32)(max(m.designUnitsPerEm, 1));
	return cast(float32)(m.ascent) * k, cast(float32)(m.descent) * k, cast(float32)(m.lineGap) * k;
}

_font_name :: (inst: u32, allocator: Allocator) -> string {
	fi := dw.insts[inst];
	if fi.family == null { return ""; }
	s, _ := win.utf16_to_utf8(sub(fi.family.family, 0, len(fi.family.family) - 1), allocator);
	return s;
}

_shape :: (inst: u32, text: string, out: *[..]Raw_Glyph) -> float32 {
	fi := dw.insts[inst];
	if fi.face == null || fi.family == null { return 0; }
	wide := make_dynamic(u16, 0, len(text) + 1, temp);
	map16 := make_dynamic(int, 0, len(text) + 1, temp);
	{ i := 0;
	while i < len(text) {
		r, n := utf8.decode_rune_in_string(sub_from(text, i));
		if r >= 0x10000 {
			rr := r - 0x10000;
			append(*wide, cast(u16)(0xD800 + (rr >> 10)), cast(u16)(0xDC00 + (rr & 0x3ff)));
			append(*map16, i, i);
		} else if r == 10 || r == 13 || r == 9 {
			// DirectWrite would start a new layout line; ui breaks lines itself and needs one glyph here.
			// Tabs are widened below, once line starts are known.
			append(*wide, cast(u16)(#char " "));
			append(*map16, i);
		} else {
			append(*wide, cast(u16)(r));
			append(*map16, i);
		}
		i += max(n, 1);
	} }
	append(*map16, len(text));
	locale := u16.[#char "e", #char "n", #char "-", #char "u", #char "s", 0];

	format: *void;
	(cast((*void, *u16, *void, u32, u32, u32, float32, *u16, **void) -> HRESULT #c_call)vt(dw.factory, 15))(
		dw.factory, raw_data(fi.family.family), null, fi.family.weight, fi.family.style, 5, fi.size, *locale[0], *format);
	if format == null { return 0; }
	defer release(format);
	(cast((*void, u32) -> HRESULT #c_call)vt(format, 5))(format, 1 /*NO_WRAP*/);
	layout: *void;
	(cast((*void, *u16, u32, *void, float32, float32, **void) -> HRESULT #c_call)vt(dw.factory, 18))(
		dw.factory, raw_data(wide), cast(u32)(len(wide)), format, 10000000, 10000000, *layout);
	if layout == null { return 0; }
	defer release(layout);

	dw.cur_out = out;
	dw.cur_map = view(map16);
	dw.cur_size = fi.size;
	dw.cur_family = fi.family;
	dw.cur_width = 0;
	// Draw(context, renderer, originX, originY)
	first := len(out);
	(cast((*void, *void, *void, float32, float32) -> HRESULT #c_call)vt(layout, 58))(layout, null, *dw.renderer, 0, 0);
	dw.cur_out = null;

	// Draw reports y from the layout's top; callers want it from the baseline, as CoreText gives it.
	line: DWRITE_LINE_METRICS;
	nlines: u32;
	(cast((*void, *DWRITE_LINE_METRICS, u32, *u32) -> HRESULT #c_call)vt(layout, 59))(layout, *line, 1, *nlines);
	for * g: sub_from(out, first) { g.y -= line.baseline; }

	// Tab stops every 4 spaces from the start of each hard line (CSS tab-size: 4).
	line_x, shift: float32;
	for * g: sub_from(out, first) {
		g.x += shift;
		if g.cluster_start >= len(text) { continue; }
		{ __sw3 := text[g.cluster_start];
		if __sw3 == 10 {
			line_x = g.x + g.advance;
		} else if __sw3 == 9 {
			stop := 4 * g.advance; // the tab was shaped as a space
			if stop <= 0 { continue; }
			col := g.x - line_x;
			adv := (math.floor(col / stop) + 1) * stop - col;
			shift += adv - g.advance;
			g.advance = adv;
		} }
	}
	dw.cur_width += shift;

	// cluster_end = next distinct cluster start
	for * r, i: out {
		r.cluster_end = len(text);
		for j: 0..len(out)-1 {
			if j != i && get(out, j).cluster_start > r.cluster_start && get(out, j).cluster_start < r.cluster_end { r.cluster_end = get(out, j).cluster_start; }
		}
	}
	return dw.cur_width;
}
#scope_file

// ---- IDWriteTextRenderer implementation

r_query_interface :: (this: *void, riid: *win.GUID, out: **void) -> HRESULT #c_call {
	if riid.* == IID_IUnknown || riid.* == IID_IDWriteTextRenderer || riid.* == IID_IDWritePixelSnapping {
		out.* = this;
		return 0;
	}
	out.* = null;
	return cast(HRESULT)(-2147467262); // E_NOINTERFACE
}
r_add_ref :: (this: *void) -> u32 #c_call {return 1;}
r_release :: (this: *void) -> u32 #c_call {return 1;}
r_is_pixel_snapping_disabled :: (this: *void, ctx: *void, out: *win.BOOL) -> HRESULT #c_call {
	out.* = true; // keep fractional positions; we snap ourselves
	return 0;
}
r_get_current_transform :: (this: *void, ctx: *void, m: *[6]float32) -> HRESULT #c_call {
	m.* = .{1, 0, 0, 1, 0, 0};
	return 0;
}
r_get_pixels_per_dip :: (this: *void, ctx: *void, out: *float32) -> HRESULT #c_call {
	out.* = 1;
	return 0;
}
r_draw_underline :: (this: *void, ctx: *void, x: float32, y: float32, u: *void, effect: *void) -> HRESULT #c_call {return 0;}
r_draw_strikethrough :: (this: *void, ctx: *void, x: float32, y: float32, s: *void, effect: *void) -> HRESULT #c_call {return 0;}
r_draw_inline_object :: (this: *void, ctx: *void, x: float32, y: float32, obj: *void, sideways: win.BOOL, rtl: win.BOOL, effect: *void) -> HRESULT #c_call {return 0;}

r_draw_glyph_run :: (this: *void, ctx: *void, x: float32, y: float32, mode: u32, run: *DWRITE_GLYPH_RUN, desc: *DWRITE_GLYPH_RUN_DESCRIPTION, effect: *void) -> HRESULT #c_call {
	__ctx4 := dw.ctx; push_context,defer_pop __ctx4;
	if dw.cur_out == null { return 0; }
	finst := register_face(run.fontFace, run.fontEmSize, dw.cur_family);
	n := cast(int)(run.glyphCount);
	// glyph -> first utf16 char of its cluster (within this run)
	glyph_char := make_slice(int, n, temp);
	for * gc: glyph_char { gc = -1; }
	for ci: 0..cast(int)(desc.stringLength)-1 {
		gi := cast(int)(desc.clusterMap[ci]);
		if gi < n && glyph_char[gi] < 0 { glyph_char[gi] = ci; }
	}
	last := 0;
	for gi: 0..cast(int)(n)-1 {
		if glyph_char[gi] < 0 { glyph_char[gi] = last; }
		last = glyph_char[gi];
	}
	pen := x;
	rtl := (run.bidiLevel & 1) != 0;
	for gi: 0..cast(int)(n)-1 {
		adv := ifx run.glyphAdvances != null then run.glyphAdvances[gi] else 0;
		off := ifx run.glyphOffsets != null then run.glyphOffsets[gi] else DWRITE_GLYPH_OFFSET.{};
		gx := ifx rtl then pen - adv - off.advanceOffset else pen + off.advanceOffset;
		u16i := cast(int)(desc.textPosition) + glyph_char[gi];
		start := dw.cur_map[clamp(u16i, 0, len(dw.cur_map) - 1)];
		append(dw.cur_out, Raw_Glyph.{font = finst, glyph = cast(u32)(run.glyphIndices[gi]), x = gx, y = y - off.ascenderOffset, advance = adv, cluster_start = start});
		pen += ifx rtl then -adv else adv;
	}
	dw.cur_width = max(dw.cur_width, pen);
	return 0;
}

// ---- Rasterization

DWRITE_COLOR_GLYPH_RUN :: struct {
	glyphRun: DWRITE_GLYPH_RUN;
	glyphRunDescription: *DWRITE_GLYPH_RUN_DESCRIPTION;
	baselineOriginX: float32;
	baselineOriginY: float32;
	runColor: [4]float32;
	paletteIndex: u16;
}

// Grayscale coverage of a glyph run with its baseline origin at (x, y); r is in pixels, y down.
rasterize_alpha :: (run: *DWRITE_GLYPH_RUN, x: float32, y: float32, allocator: Allocator) -> []u8, win.RECT {
	pixels: []u8;
	r: win.RECT;
	analysis: *void;
	// IDWriteFactory2::CreateGlyphRunAnalysis(run, transform, renderingMode, measuringMode, gridFitMode, antialiasMode, x, y, out)
	hr := (cast((*void, *DWRITE_GLYPH_RUN, *void, u32, u32, u32, u32, float32, float32, **void) -> HRESULT #c_call)vt(dw.factory, 30))(
		dw.factory, run, null, 5, 0, 1, 1, x, y, *analysis);
	if hr < 0 || analysis == null { return pixels, r; }
	defer release(analysis);
	(cast((*void, u32, *win.RECT) -> HRESULT #c_call)vt(analysis, 3))(analysis, 0, *r);
	w, h := r.right - r.left, r.bottom - r.top;
	if w <= 0 || h <= 0 { return .{}, .{}; }
	pixels = make_slice(u8, cast(int)(w * h), allocator);
	(cast((*void, u32, *win.RECT, *u8, u32) -> HRESULT #c_call)vt(analysis, 4))(analysis, 0, *r, raw_data(pixels), cast(u32)(len(pixels)));
	return pixels, r;
}
#scope_module

_rasterize :: (inst: u32, glyph: u32, subpx: float32, allocator: Allocator) -> Glyph_Bitmap {
	fi := dw.insts[inst];
	if fi.face == null { return .{}; }
	idx := cast(u16)(glyph);
	adv: float32 = 0;
	off := DWRITE_GLYPH_OFFSET.{};
	run := DWRITE_GLYPH_RUN.{fontFace = fi.face, fontEmSize = fi.size, glyphCount = 1, glyphIndices = *idx, glyphAdvances = *adv, glyphOffsets = *off};

	// Color fonts (Segoe UI Emoji's COLR layers): IDWriteFactory2::TranslateColorGlyphRun fails with
	// DWRITE_E_NOCOLOR for plain glyphs, which then take the grayscale path.
	layers: *void;
	hr := (cast((*void, float32, float32, *DWRITE_GLYPH_RUN, *void, u32, *void, u32, **void) -> HRESULT #c_call)vt(dw.factory, 28))(
		dw.factory, subpx, 0, *run, null, 0, null, 0, *layers);
	if hr >= 0 && layers != null {
		defer release(layers);
		return rasterize_color(layers, allocator);
	}

	pixels, r := rasterize_alpha(*run, subpx, 0, allocator);
	if pixels == null { return .{}; }
	return .{w = r.right - r.left, h = r.bottom - r.top, left = r.left, top = r.top, pixels = pixels};
}
#scope_file

// Composites each color layer over the previous ones; output is straight-alpha RGBA like the CoreText path.
rasterize_color :: (layers: *void, allocator: Allocator) -> Glyph_Bitmap {
	Layer :: struct {
		pixels: []u8;
		r: win.RECT;
		color: [4]float32;
	}
	list := make_dynamic(Layer, 0, 8, temp);
	bounds := win.RECT.{S32_MAX, S32_MAX, S32_MIN, S32_MIN};
	while true {
		has_run: win.BOOL;
		if (cast((*void, *win.BOOL) -> HRESULT #c_call)vt(layers, 3))(layers, *has_run) < 0 || !has_run { break; }
		cr: *DWRITE_COLOR_GLYPH_RUN;
		if (cast((*void, **DWRITE_COLOR_GLYPH_RUN) -> HRESULT #c_call)vt(layers, 4))(layers, *cr) < 0 || cr == null { break; }
		pixels, r := rasterize_alpha(*cr.glyphRun, cr.baselineOriginX, cr.baselineOriginY, temp);
		if pixels == null { continue; }
		// Palette index 0xFFFF means "the text color"; emoji are drawn untinted, so use black as CoreText does.
		color := ifx cr.paletteIndex == 0xFFFF then float32.[0, 0, 0, 1] else cr.runColor;
		append(*list, Layer.{pixels, r, color});
		bounds.left, bounds.top = min(bounds.left, r.left), min(bounds.top, r.top);
		bounds.right, bounds.bottom = max(bounds.right, r.right), max(bounds.bottom, r.bottom);
	}
	if len(list) == 0 { return .{}; }
	w, h := bounds.right - bounds.left, bounds.bottom - bounds.top;
	if w <= 0 || h <= 0 || w > 1024 || h > 1024 { return .{}; }

	acc := make_slice([4]float32, cast(int)(w * h), temp); // premultiplied
	for l: list {
		lw := l.r.right - l.r.left;
		for y: l.r.top..l.r.bottom-1 {
			for x: l.r.left..l.r.right-1 {
				a := cast(float32)(l.pixels[(y - l.r.top) * lw + (x - l.r.left)]) / 255 * l.color.a;
				if a == 0 { continue; }
				d := *acc[(y - bounds.top) * w + (x - bounds.left)];
				d.* = .{l.color.r * a, l.color.g * a, l.color.b * a, a} + d.* * (1 - a);
			}
		}
	}
	out := make_slice(u8, cast(int)(w * h) * 4, allocator);
	for p, i: acc {
		if p.a <= 0 { continue; }
		at(*out, i * 4 + 0).* = cast(u8)(min(p.r / p.a * 255 + 0.5, 255));
		at(*out, i * 4 + 1).* = cast(u8)(min(p.g / p.a * 255 + 0.5, 255));
		at(*out, i * 4 + 2).* = cast(u8)(min(p.b / p.a * 255 + 0.5, 255));
		at(*out, i * 4 + 3).* = cast(u8)(min(p.a * 255 + 0.5, 255));
	}
	return .{w = w, h = h, left = bounds.left, top = bounds.top, pixels = out, is_color = true};
}
#scope_export

