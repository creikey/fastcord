package gfx

// Text: OS shaping (CoreText / DirectWrite) + dynamic glyph atlas.
//
//	face := gfx.font_load_memory(woff2_bytes)   // or gfx.font_system("system")
//	run  := gfx.shape(face, 16, "hello 👋")     // cached by (face, size, scale, text)
//	gfx.draw_run(run, {x, baseline_y}, color)
//
// Glyphs are rasterized at the device pixel size (size_pt * dpi_scale) with 4
// horizontal subpixel positions, grayscale coverage into R8 pages and color
// glyphs (emoji) into RGBA8 pages.

import "base:runtime"
import "core:hash"
import "core:math"
import "core:slice"
import "fc:platform"

Font_Face :: distinct u32 // 0 = invalid

Font_Weight :: enum u8 {Regular, Medium, Semibold, Bold}

Font_Metrics :: struct {
	ascent:      f32, // points, positive up from baseline
	descent:     f32, // points, positive down from baseline
	line_gap:    f32,
	line_height: f32, // ascent + descent + line_gap
}

Shaped_Glyph :: struct {
	pos:           [2]f32, // pen position relative to run origin (baseline-left), points; y down
	advance:       f32, // points
	cluster_start: int, // UTF-8 byte range of the grapheme cluster(s) this glyph belongs to
	cluster_end:   int,
	atlas_src:     Rect, // texels in tex; empty for blank glyphs (space)
	tex:           Texture,
	is_color:      bool,
	bitmap_offset: [2]f32, // points from pos to the bitmap's top-left
	bitmap_size:   [2]f32, // points
}

Shaped_Run :: struct {
	glyphs: []Shaped_Glyph, // visual order (LTR); multiple glyphs may share a cluster
	width:  f32, // points
	text_len: int, // bytes of the source text
}

SUBPIXEL_BINS :: 4
SHAPE_CACHE_MAX_AGE :: 120 // frames an unused shaped run stays cached
ATLAS_SIZE :: 1024

// ---------------------------------------------------------------------------
// Backend-facing types

@(private)
Raw_Glyph :: struct {
	font:          u32, // backend font instance (sized)
	glyph:         u32,
	x, y:          f32, // pixels, y down
	advance:       f32, // pixels
	cluster_start: int,
	cluster_end:   int,
}

@(private)
Glyph_Bitmap :: struct {
	w, h:     i32,
	left:     i32, // pixel offset from pen to bitmap left
	top:      i32, // pixel offset from pen (baseline) to bitmap top (y down, usually negative)
	is_color: bool,
	pixels:   []u8, // R8 or RGBA8 (straight), tightly packed
}

@(private)
Glyph_Key :: struct {
	font:  u32,
	glyph: u32,
	subpx: u8,
}

@(private)
Glyph_Info :: struct {
	tex:      Texture,
	src:      Rect,
	left:     i32,
	top:      i32,
	w, h:     i32,
	is_color: bool,
}

@(private)
Atlas_Page :: struct {
	tex:                    Texture,
	format:                 Texture_Format,
	cursor_x, cursor_y, row_h: i32,
}

@(private)
Shape_Entry :: struct {
	text:       string,
	face:       Font_Face,
	size_q:     u32,
	scale:      f32,
	glyphs:     []Shaped_Glyph,
	width:      f32,
	last_frame: u64,
}

@(private)
Face :: struct {
	native: rawptr,
	sizes:  map[u32]u32, // size_q (1/64 px) -> backend font instance
}

@(private)
T :: struct {
	faces:       [dynamic]Face,
	glyphs:      map[Glyph_Key]Glyph_Info,
	pages:       [dynamic]Atlas_Page,
	shape_cache: map[u64]Shape_Entry,
	raw:         [dynamic]Raw_Glyph,
	alloc:       runtime.Allocator,
	reset_atlas: bool,
	frame:       u64,
	stats:       Text_Stats,
}

Text_Stats :: struct {
	shape_hits, shape_misses: int, // this frame
	cached_runs:              int,
	glyphs_rasterized:        int, // total
	atlas_pages:              int,
}

@(private)
tx: T

@(private)
text_init :: proc() {
	tx.alloc = context.allocator
	append(&tx.faces, Face{}) // 0 = invalid
	_text_backend_init()
}

@(private)
text_shutdown :: proc() {
	_text_backend_shutdown()
	for _, e in tx.shape_cache do free_entry(e)
	delete(tx.shape_cache)
	delete(tx.glyphs)
	delete(tx.pages)
	delete(tx.raw)
	for &f in tx.faces {
		delete(f.sizes)
		_font_free(f.native)
	}
	delete(tx.faces)
	tx = {}
}

@(private)
text_begin_frame :: proc() {
	tx.frame += 1
	tx.stats.shape_hits = 0
	tx.stats.shape_misses = 0
}

@(private)
text_end_frame :: proc() {
	// The atlas is rebuilt after the frame is submitted, never in begin_frame: the UI shapes text
	// before begin_frame, so a reset there would destroy the pages that frame's glyphs point at.
	if tx.reset_atlas {
		tx.reset_atlas = false
		for p in tx.pages do texture_destroy(p.tex)
		clear(&tx.pages)
		clear(&tx.glyphs)
		for _, e in tx.shape_cache do free_entry(e)
		clear(&tx.shape_cache)
		g.diag.atlas_resets += 1
	}
	// LRU sweep: drop runs not drawn/shaped for SHAPE_CACHE_MAX_AGE frames (amortized).
	if tx.frame % 30 == 0 {
		for k, e in tx.shape_cache {
			if tx.frame - e.last_frame > SHAPE_CACHE_MAX_AGE {
				free_entry(e)
				delete_key(&tx.shape_cache, k)
			}
		}
	}
	tx.stats.cached_runs = len(tx.shape_cache)
	tx.stats.atlas_pages = len(tx.pages)
}

text_stats :: proc() -> Text_Stats {return tx.stats}

@(private)
free_entry :: proc(e: Shape_Entry) {
	delete(e.text, tx.alloc)
	delete(e.glyphs, tx.alloc)
}

// ---------------------------------------------------------------------------
// Fonts

// Load TTF/OTF/WOFF/WOFF2 bytes (CoreText reads WOFF2 directly). Bytes are copied.
font_load_memory :: proc(data: []byte) -> Font_Face {
	native := _font_load_memory(data)
	if native == nil do return 0
	append(&tx.faces, Face{native = native})
	return Font_Face(len(tx.faces) - 1)
}

font_load_file :: proc(path: string) -> Font_Face {
	data, ok := read_entire_file(path)
	if !ok do return 0
	defer delete(data)
	return font_load_memory(data)
}

// "system" (or "") = the OS UI font (SF Pro on macOS, Segoe UI on Windows); otherwise a family/PostScript name.
font_system :: proc(name: string, weight: Font_Weight = .Regular, italic := false) -> Font_Face {
	native := _font_system(name, weight, italic)
	if native == nil do return 0
	append(&tx.faces, Face{native = native})
	return Font_Face(len(tx.faces) - 1)
}

@(private)
size_quant :: proc(size_px: f32) -> u32 {return u32(math.round(size_px * 64))}

@(private)
face_instance :: proc(face: Font_Face, size_px: f32) -> (u32, bool) {
	if face == 0 || int(face) >= len(tx.faces) do return 0, false
	f := &tx.faces[face]
	q := size_quant(size_px)
	if inst, ok := f.sizes[q]; ok do return inst, true
	inst := _font_instance(f.native, f32(q) / 64)
	f.sizes[q] = inst
	return inst, true
}

font_metrics :: proc(face: Font_Face, size_pt: f32) -> Font_Metrics {
	sc := g.scale > 0 ? g.scale : platform.dpi_scale()
	inst, ok := face_instance(face, size_pt * sc)
	if !ok do return {}
	a, d, l := _font_metrics(inst)
	m := Font_Metrics{ascent = a / sc, descent = d / sc, line_gap = l / sc}
	m.line_height = m.ascent + m.descent + m.line_gap
	return m
}

// ---------------------------------------------------------------------------
// Shaping

shape :: proc(face: Font_Face, size_pt: f32, text: string, allocator := context.temp_allocator) -> Shaped_Run {
	sc := g.scale > 0 ? g.scale : platform.dpi_scale()
	size_px := size_pt * sc
	q := size_quant(size_px)

	h := hash.fnv64a(transmute([]u8)text)
	h ~= u64(face) * 0x9E3779B97F4A7C15
	h ~= u64(q) << 32 ~ u64(transmute(u32)sc) * 0xff51afd7ed558ccd
	if e, ok := &tx.shape_cache[h]; ok && e.text == text && e.face == face && e.size_q == q && e.scale == sc {
		e.last_frame = tx.frame
		tx.stats.shape_hits += 1
		return {glyphs = slice.clone(e.glyphs, allocator), width = e.width, text_len = len(text)}
	}
	tx.stats.shape_misses += 1

	inst, ok := face_instance(face, size_px)
	if !ok || len(text) == 0 do return {text_len = len(text)}

	clear(&tx.raw)
	width_px := _shape(inst, text, &tx.raw)

	glyphs := make([]Shaped_Glyph, len(tx.raw), tx.alloc)
	for r, i in tx.raw {
		sg := &glyphs[i]
		sg.pos = {r.x / sc, r.y / sc}
		sg.advance = r.advance / sc
		sg.cluster_start = r.cluster_start
		sg.cluster_end = r.cluster_end
		fx := math.floor(r.x)
		bin := u8(math.floor((r.x - fx) * SUBPIXEL_BINS)) % SUBPIXEL_BINS
		gi := glyph_get(r.font, r.glyph, bin)
		if gi.w > 0 && gi.h > 0 {
			sg.atlas_src = gi.src
			sg.tex = gi.tex
			sg.is_color = gi.is_color
			// Snapped in pixel space: dst_px = origin_px + floor(x_px) + left
			sg.bitmap_offset = {(fx - r.x + f32(gi.left)) / sc, (math.round(r.y) - r.y + f32(gi.top)) / sc}
			sg.bitmap_size = {f32(gi.w) / sc, f32(gi.h) / sc}
		}
	}
	e := Shape_Entry {
		text       = clone_str(text, tx.alloc),
		face       = face,
		size_q     = q,
		scale      = sc,
		glyphs     = glyphs,
		width      = width_px / sc,
		last_frame = tx.frame,
	}
	if old, exists := tx.shape_cache[h]; exists do free_entry(old)
	tx.shape_cache[h] = e
	return {glyphs = slice.clone(glyphs, allocator), width = e.width, text_len = len(text)}
}

// Width only (uses the shape cache).
measure :: proc(face: Font_Face, size_pt: f32, text: string) -> f32 {
	return shape(face, size_pt, text).width
}

// origin = left end of the baseline, points.
draw_run :: proc(run: Shaped_Run, origin: [2]f32, color: Color) {
	sc := g.scale
	ox := math.round(origin.x * sc)
	oy := math.round(origin.y * sc)
	white := Color{1, 1, 1, color.a}
	for gl in run.glyphs {
		if gl.tex == 0 do continue
		x0 := math.round(ox + (gl.pos.x + gl.bitmap_offset.x) * sc)
		y0 := math.round(oy + (gl.pos.y + gl.bitmap_offset.y) * sc)
		w := gl.atlas_src.x1 - gl.atlas_src.x0
		h := gl.atlas_src.y1 - gl.atlas_src.y0
		c := gl.is_color ? white : color
		push_rect_px({src = gl.atlas_src, tex = gl.tex, colors = {c, c, c, c}}, {x0, y0, x0 + w, y0 + h})
	}
}

// Convenience: shape + draw. Returns the advance width (points).
draw_text :: proc(face: Font_Face, size_pt: f32, text: string, origin: [2]f32, color: Color) -> f32 {
	run := shape(face, size_pt, text)
	draw_run(run, origin, color)
	return run.width
}

// x (points, relative to run origin) of the caret placed before byte `offset`.
// Offsets inside a cluster snap to the cluster start; offset >= text_len gives run.width.
run_caret_x :: proc(run: Shaped_Run, offset: int) -> f32 {
	if offset <= 0 || len(run.glyphs) == 0 do return 0
	if offset >= run.text_len do return run.width
	best_x: f32 = run.width
	found := false
	for gl in run.glyphs {
		if offset >= gl.cluster_start && offset < gl.cluster_end {
			// caret at the start of the cluster containing offset
			if !found || gl.pos.x < best_x do best_x = gl.pos.x
			found = true
		}
	}
	if found do return best_x
	for gl in run.glyphs {
		if gl.cluster_start >= offset do return gl.pos.x
	}
	return run.width
}

// Byte offset of the caret position (cluster boundary) nearest to x (points).
run_hit_test :: proc(run: Shaped_Run, x: f32) -> int {
	if len(run.glyphs) == 0 || x <= 0 do return 0
	if x >= run.width do return run.text_len
	// Walk clusters: each glyph starting a new cluster contributes a boundary at its left edge.
	best := 0
	best_d := abs(x)
	last_start := -1
	for gl, i in run.glyphs {
		if gl.cluster_start == last_start do continue
		last_start = gl.cluster_start
		// cluster extent
		x_end := gl.pos.x + gl.advance
		for j := i + 1; j < len(run.glyphs) && run.glyphs[j].cluster_start == gl.cluster_start; j += 1 {
			x_end = max(x_end, run.glyphs[j].pos.x + run.glyphs[j].advance)
		}
		if d := abs(x - gl.pos.x); d < best_d {best, best_d = gl.cluster_start, d}
		if d := abs(x - x_end); d < best_d {best, best_d = gl.cluster_end, d}
	}
	return best
}

// ---------------------------------------------------------------------------
// Glyph cache + atlas

@(private)
glyph_get :: proc(font, glyph: u32, bin: u8) -> Glyph_Info {
	key := Glyph_Key{font, glyph, bin}
	if gi, ok := tx.glyphs[key]; ok do return gi
	bm := _rasterize(font, glyph, f32(bin) / SUBPIXEL_BINS, context.temp_allocator)
	gi := Glyph_Info{left = bm.left, top = bm.top, w = bm.w, h = bm.h, is_color = bm.is_color}
	if bm.w > 0 && bm.h > 0 {
		fmt_ := bm.is_color ? Texture_Format.RGBA8 : .R8
		tex, x, y := atlas_alloc(fmt_, bm.w, bm.h)
		if tex != 0 {
			texture_update(tex, int(x), int(y), int(bm.w), int(bm.h), bm.pixels)
			gi.tex = tex
			gi.src = {f32(x), f32(y), f32(x + bm.w), f32(y + bm.h)}
		} else {
			gi.w, gi.h = 0, 0
		}
	}
	tx.stats.glyphs_rasterized += 1
	tx.glyphs[key] = gi
	return gi
}

@(private)
atlas_alloc :: proc(format: Texture_Format, w, h: i32) -> (Texture, i32, i32) {
	PAD :: 1
	if w + PAD > ATLAS_SIZE || h + PAD > ATLAS_SIZE do return 0, 0, 0
	for &p in tx.pages {
		if p.format != format do continue
		if p.cursor_x + w + PAD > ATLAS_SIZE {
			p.cursor_x = PAD
			p.cursor_y += p.row_h + PAD
			p.row_h = 0
		}
		if p.cursor_y + h + PAD > ATLAS_SIZE do continue
		x, y := p.cursor_x, p.cursor_y
		p.cursor_x += w + PAD
		p.row_h = max(p.row_h, h)
		return p.tex, x, y
	}
	if len(tx.pages) >= 16 do tx.reset_atlas = true // too many pages: rebuild next frame
	bpp := format == .R8 ? 1 : 4
	zero := make([]u8, ATLAS_SIZE * ATLAS_SIZE * bpp, context.temp_allocator)
	tex := texture_create(ATLAS_SIZE, ATLAS_SIZE, format, zero)
	append(&tx.pages, Atlas_Page{tex = tex, format = format, cursor_x = PAD + w + PAD, cursor_y = PAD, row_h = h})
	return tex, PAD, PAD
}

// Debug: atlas page textures (for visualizing).
atlas_pages :: proc(allocator := context.temp_allocator) -> []Texture {
	out := make([]Texture, len(tx.pages), allocator)
	for p, i in tx.pages do out[i] = p.tex
	return out
}

@(private)
clone_str :: proc(s: string, allocator: runtime.Allocator) -> string {
	b := make([]u8, len(s), allocator)
	copy(b, s)
	return string(b)
}

// Full name of the face (e.g. "gg sans Medium"), for debugging.
font_name :: proc(face: Font_Face, allocator := context.temp_allocator) -> string {
	if face == 0 || int(face) >= len(tx.faces) do return ""
	inst, ok := face_instance(face, 16)
	if !ok do return ""
	return _font_name(inst, allocator)
}
