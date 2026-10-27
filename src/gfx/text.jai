// Text: OS shaping (CoreText / DirectWrite) + dynamic glyph atlas.
//
//	face := gfx.font_load_memory(woff2_bytes)   // or gfx.font_system("system")
//	run  := gfx.shape(face, 16, "hello 👋")     // cached by (face, size, scale, text)
//	gfx.draw_run(run, .{x, baseline_y}, color)
//
// Glyphs are rasterized at the device pixel size (size_pt * dpi_scale) with 4
// horizontal subpixel positions, grayscale coverage into R8 pages and color
// glyphs (emoji) into RGBA8 pages.

Font_Face :: u32; // 0 = invalid

Font_Weight :: enum u8 { Regular; Medium; Semibold; Bold; }

Font_Metrics :: struct {
    ascent: float32;      // points, positive up from baseline
    descent: float32;     // points, positive down from baseline
    line_gap: float32;
    line_height: float32; // ascent + descent + line_gap
}

Shaped_Glyph :: struct {
    pos: Vector2;       // pen position relative to run origin (baseline-left), points; y down
    advance: float32;   // points
    cluster_start: int; // UTF-8 byte range of the grapheme cluster(s) this glyph belongs to
    cluster_end: int;
    atlas_src: Rect;    // texels in tex; empty for blank glyphs (space)
    tex: Texture;
    is_color: bool;
    bitmap_offset: Vector2; // points from pos to the bitmap's top-left
    bitmap_size: Vector2;   // points
}

Shaped_Run :: struct {
    glyphs: []Shaped_Glyph; // visual order (LTR); multiple glyphs may share a cluster
    width: float32;         // points
    text_len: int;          // bytes of the source text
}

Text_Stats :: struct {
    shape_hits, shape_misses: int; // this frame
    cached_runs: int;
    glyphs_rasterized: int; // total
    atlas_pages: int;
}

SUBPIXEL_BINS :: 4;
SHAPE_CACHE_MAX_AGE :: 120; // frames an unused shaped run stays cached
ATLAS_SIZE :: 1024;

text_stats :: () -> Text_Stats { return tx.stats; }

// Load TTF/OTF/WOFF/WOFF2 bytes (CoreText reads WOFF2 directly). Bytes are copied.
font_load_memory :: (data: []u8) -> Font_Face {
    return add_face(native_font_load_memory(data));
}

font_load_file :: (path: string) -> Font_Face {
    data, ok := read_entire_file(path);
    if !ok return 0;
    defer free(data);
    return font_load_memory(cast([]u8) data);
}

// "system" (or "") = the OS UI font (SF Pro on macOS, Segoe UI on Windows); otherwise a family/PostScript name.
font_system :: (name: string, weight := Font_Weight.Regular, italic := false) -> Font_Face {
    return add_face(native_font_system(name, weight, italic));
}

font_metrics :: (face: Font_Face, size_pt: float32) -> Font_Metrics {
    sc := current_scale();
    inst, ok := face_instance(face, size_pt * sc);
    if !ok return .{};
    a, d, l := native_font_metrics(inst);
    m := Font_Metrics.{ascent = a / sc, descent = d / sc, line_gap = l / sc};
    m.line_height = m.ascent + m.descent + m.line_gap;
    return m;
}

shape :: (face: Font_Face, size_pt: float32, text: string, allocator := temp) -> Shaped_Run {
    sc := current_scale();
    size_px := size_pt * sc;
    q := size_quant(size_px);

    h := fnv1a_hash(text.data, text.count);
    h ^= cast(u64) face * 0x9E3779B97F4A7C15;
    h ^= ((cast(u64) q) << 32) ^ (cast(u64) (cast(*u32) *sc).* * 0xff51afd7ed558ccd);
    e := table_find_pointer(*tx.shape_cache, h);
    if e && e.text == text && e.face == face && e.size_q == q && e.scale == sc {
        e.last_frame = tx.frame;
        tx.stats.shape_hits += 1;
        return .{glyphs = array_copy(e.glyphs,, allocator), width = e.width, text_len = text.count};
    }
    tx.stats.shape_misses += 1;

    inst, ok := face_instance(face, size_px);
    if !ok || !text return .{text_len = text.count};

    tx.raw.count = 0;
    width_px := native_shape(inst, text, *tx.raw);

    glyphs := NewArray(tx.raw.count, Shaped_Glyph,, tx.alloc);
    for r, i: tx.raw {
        sg := *glyphs[i];
        sg.pos = .{r.x / sc, r.y / sc};
        sg.advance = r.advance / sc;
        sg.cluster_start = r.cluster_start;
        sg.cluster_end = r.cluster_end;
        fx := floor(r.x);
        bin := cast(u8) floor((r.x - fx) * SUBPIXEL_BINS) % SUBPIXEL_BINS;
        gi := glyph_get(r.font, r.glyph, bin);
        if gi.w > 0 && gi.h > 0 {
            sg.atlas_src = gi.src;
            sg.tex = gi.tex;
            sg.is_color = gi.is_color;
            // Snapped in pixel space: dst_px = origin_px + floor(x_px) + left
            sg.bitmap_offset = .{(fx - r.x + gi.left) / sc, (round(r.y) - r.y + gi.top) / sc};
            sg.bitmap_size = .{gi.w / sc, gi.h / sc};
        }
    }
    entry := Shape_Entry.{text = copy_string(text,, tx.alloc), face = face, size_q = q, scale = sc,
        glyphs = glyphs, width = width_px / sc, last_frame = tx.frame};
    old := table_find_pointer(*tx.shape_cache, h);
    if old { free_entry(old.*); old.* = entry; }
    else table_add(*tx.shape_cache, h, entry);
    return .{glyphs = array_copy(glyphs,, allocator), width = entry.width, text_len = text.count};
}

// Width only (uses the shape cache).
measure :: (face: Font_Face, size_pt: float32, text: string) -> float32 {
    return shape(face, size_pt, text).width;
}

// origin = left end of the baseline, points.
draw_run :: (run: Shaped_Run, origin: Vector2, color: Color) {
    sc := g.scale;
    ox := round(origin.x * sc);
    oy := round(origin.y * sc);
    white := Color.{1, 1, 1, color.w};
    for gl: run.glyphs {
        if gl.tex == 0 continue;
        x0 := round(ox + (gl.pos.x + gl.bitmap_offset.x) * sc);
        y0 := round(oy + (gl.pos.y + gl.bitmap_offset.y) * sc);
        w := gl.atlas_src.x1 - gl.atlas_src.x0;
        h := gl.atlas_src.y1 - gl.atlas_src.y0;
        c := ifx gl.is_color then white else color;
        push_rect_px(.{src = gl.atlas_src, tex = gl.tex, colors = .[c, c, c, c]}, .{x0, y0, x0 + w, y0 + h});
    }
}

// Convenience: shape + draw. Returns the advance width (points).
draw_text :: (face: Font_Face, size_pt: float32, text: string, origin: Vector2, color: Color) -> float32 {
    run := shape(face, size_pt, text);
    draw_run(run, origin, color);
    return run.width;
}

// x (points, relative to run origin) of the caret placed before byte `offset`.
// Offsets inside a cluster snap to the cluster start; offset >= text_len gives run.width.
run_caret_x :: (run: Shaped_Run, offset: int) -> float32 {
    if offset <= 0 || !run.glyphs return 0;
    if offset >= run.text_len return run.width;
    best_x := run.width;
    found := false;
    for run.glyphs {
        if offset >= it.cluster_start && offset < it.cluster_end {
            // caret at the start of the cluster containing offset
            if !found || it.pos.x < best_x  best_x = it.pos.x;
            found = true;
        }
    }
    if found return best_x;
    for run.glyphs if it.cluster_start >= offset return it.pos.x;
    return run.width;
}

// Byte offset of the caret position (cluster boundary) nearest to x (points).
run_hit_test :: (run: Shaped_Run, x: float32) -> int {
    if !run.glyphs || x <= 0 return 0;
    if x >= run.width return run.text_len;
    // Walk clusters: each glyph starting a new cluster contributes a boundary at its left edge.
    best := 0;
    best_d := abs(x);
    last_start := -1;
    for gl, i: run.glyphs {
        if gl.cluster_start == last_start continue;
        last_start = gl.cluster_start;
        x_end := gl.pos.x + gl.advance;
        for j: i+1..run.glyphs.count-1 {
            if run.glyphs[j].cluster_start != gl.cluster_start break;
            x_end = max(x_end, run.glyphs[j].pos.x + run.glyphs[j].advance);
        }
        d := abs(x - gl.pos.x);
        if d < best_d { best = gl.cluster_start; best_d = d; }
        d = abs(x - x_end);
        if d < best_d { best = gl.cluster_end; best_d = d; }
    }
    return best;
}

// Debug: atlas page textures (for visualizing).
atlas_pages :: (allocator := temp) -> []Texture {
    out := NewArray(tx.pages.count, Texture,, allocator);
    for tx.pages out[it_index] = it.tex;
    return out;
}

// Full name of the face (e.g. "gg sans Medium"), for debugging.
font_name :: (face: Font_Face, allocator := temp) -> string {
    inst, ok := face_instance(face, 16);
    if !ok return "";
    return native_font_name(inst, allocator);
}

#scope_module

// Backend-facing types.
Raw_Glyph :: struct {
    font: u32;        // backend font instance (sized)
    glyph: u32;
    x, y: float32;    // pixels, y down
    advance: float32; // pixels
    cluster_start: int;
    cluster_end: int;
}

Glyph_Bitmap :: struct {
    w, h: s32;
    left: s32; // pixel offset from pen to bitmap left
    top: s32;  // pixel offset from pen (baseline) to bitmap top (y down, usually negative)
    is_color: bool;
    pixels: []u8; // R8 or RGBA8 (straight), tightly packed
}

Glyph_Info :: struct {
    tex: Texture;
    src: Rect;
    left, top: s32;
    w, h: s32;
    is_color: bool;
}

Atlas_Page :: struct {
    tex: Texture;
    format: Texture_Format;
    cursor_x, cursor_y, row_h: s32;
}

Shape_Entry :: struct {
    text: string;
    face: Font_Face;
    size_q: u32;
    scale: float32;
    glyphs: []Shaped_Glyph;
    width: float32;
    last_frame: u64;
}

Face :: struct {
    native: *void;
    sizes: Table(u32, u32); // size_q (1/64 px) -> backend font instance
}

tx: struct {
    faces: [..]Face;
    glyphs: Table(u64, Glyph_Info); // key: glyph_key
    pages: [..]Atlas_Page;
    shape_cache: Table(u64, Shape_Entry);
    raw: [..]Raw_Glyph;
    alloc: Allocator;
    reset_atlas: bool;
    frame: u64;
    stats: Text_Stats;
};

glyph_key :: (font: u32, glyph: u32, subpx: u8) -> u64 { return ((cast(u64) font) << 40) | ((cast(u64) glyph) << 8) | subpx; }

text_init :: () {
    tx.alloc = context.allocator;
    array_add(*tx.faces, .{}); // 0 = invalid
    text_backend_init();
}

text_shutdown :: () {
    text_backend_shutdown();
    for tx.shape_cache free_entry(it);
    deinit(*tx.shape_cache);
    deinit(*tx.glyphs);
    array_free(tx.pages);
    array_free(tx.raw);
    for * tx.faces {
        deinit(*it.sizes);
        native_font_free(it.native);
    }
    array_free(tx.faces);
    tx = .{};
}

text_begin_frame :: () {
    tx.frame += 1;
    tx.stats.shape_hits = 0;
    tx.stats.shape_misses = 0;
}

text_end_frame :: () {
    // The atlas is rebuilt after the frame is submitted, never in begin_frame: the UI shapes text
    // before begin_frame, so a reset there would destroy the pages that frame's glyphs point at.
    if tx.reset_atlas {
        tx.reset_atlas = false;
        for tx.pages texture_destroy(it.tex);
        tx.pages.count = 0;
        table_reset(*tx.glyphs);
        for tx.shape_cache free_entry(it);
        table_reset(*tx.shape_cache);
        g.diag.atlas_resets += 1;
    }
    // LRU sweep: drop runs not drawn/shaped for SHAPE_CACHE_MAX_AGE frames (amortized).
    if tx.frame % 30 == 0 {
        for tx.shape_cache if tx.frame - it.last_frame > SHAPE_CACHE_MAX_AGE {
            free_entry(it);
            remove it;
        }
    }
    tx.stats.cached_runs = tx.shape_cache.count;
    tx.stats.atlas_pages = tx.pages.count;
}

free_entry :: (e: Shape_Entry) {
    free(e.text,, tx.alloc);
    free(e.glyphs.data,, tx.alloc);
}

current_scale :: () -> float32 { return ifx g.scale > 0 then g.scale else platform.dpi_scale(); }

add_face :: (native: *void) -> Font_Face {
    if native == null return 0;
    array_add(*tx.faces, .{native = native});
    return cast(Font_Face) (tx.faces.count - 1);
}

// Odin's utf8.decode_rune_in_string: an invalid sequence is U+FFFD, one byte wide.
decode_rune :: (s: string, i: int) -> u32, int {
    c := s[i];
    if c < 0x80 return c, 1;
    r, n, res := character_utf8_to_utf32(s.data + i, s.count - i, strict = true);
    if res != .CONVERSION_OK || c < 0xC0 return 0xFFFD, 1;
    return r, n;
}

size_quant :: (size_px: float32) -> u32 { return cast(u32) round(size_px * 64); }

face_instance :: (face: Font_Face, size_px: float32) -> u32, bool {
    if face == 0 || face >= tx.faces.count return 0, false;
    f := *tx.faces[face];
    q := size_quant(size_px);
    ok, inst := table_find(*f.sizes, q);
    if ok return inst, true;
    inst = native_font_instance(f.native, cast(float32) q / 64);
    table_set(*f.sizes, q, inst);
    return inst, true;
}

glyph_get :: (font: u32, glyph: u32, bin: u8) -> Glyph_Info {
    key := glyph_key(font, glyph, bin);
    found, gi := table_find(*tx.glyphs, key);
    if found return gi;
    bm := native_rasterize(font, glyph, cast(float32) bin / SUBPIXEL_BINS, temp);
    gi = .{left = bm.left, top = bm.top, w = bm.w, h = bm.h, is_color = bm.is_color};
    if bm.w > 0 && bm.h > 0 {
        tex, x, y := atlas_alloc(ifx bm.is_color then .RGBA8 else .R8, bm.w, bm.h);
        if tex {
            texture_update(tex, x, y, bm.w, bm.h, bm.pixels);
            gi.tex = tex;
            gi.src = .{cast(float32) x, cast(float32) y, cast(float32) (x + bm.w), cast(float32) (y + bm.h)};
        } else {
            gi.w = 0;
            gi.h = 0;
        }
    }
    tx.stats.glyphs_rasterized += 1;
    table_set(*tx.glyphs, key, gi);
    return gi;
}

atlas_alloc :: (format: Texture_Format, w: s32, h: s32) -> Texture, s32, s32 {
    PAD :: 1;
    if w + PAD > ATLAS_SIZE || h + PAD > ATLAS_SIZE return 0, 0, 0;
    for * p: tx.pages {
        if p.format != format continue;
        if p.cursor_x + w + PAD > ATLAS_SIZE {
            p.cursor_x = PAD;
            p.cursor_y += p.row_h + PAD;
            p.row_h = 0;
        }
        if p.cursor_y + h + PAD > ATLAS_SIZE continue;
        x, y := p.cursor_x, p.cursor_y;
        p.cursor_x += w + PAD;
        p.row_h = max(p.row_h, h);
        return p.tex, x, y;
    }
    if tx.pages.count >= 16  tx.reset_atlas = true; // too many pages: rebuild next frame
    bpp := ifx format == .R8 then 1 else 4;
    zero := NewArray(ATLAS_SIZE * ATLAS_SIZE * bpp, u8,, temp);
    tex := texture_create(ATLAS_SIZE, ATLAS_SIZE, format, zero);
    array_add(*tx.pages, .{tex = tex, format = format, cursor_x = PAD + w + PAD, cursor_y = PAD, row_h = h});
    return tex, PAD, PAD;
}
