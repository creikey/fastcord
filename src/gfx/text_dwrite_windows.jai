// DirectWrite text backend. Shaping + fallback via IDWriteTextLayout drawn
// into a custom IDWriteTextRenderer (collects glyph runs), rasterization via
// IDWriteFactory2::CreateGlyphRunAnalysis (grayscale).
//
// COM calls go through raw vtable indices (Jai ships no DirectWrite bindings).
// font_load_memory unpacks WOFF/WOFF2 and gives each font its own collection (IDWriteFactory5, Windows 10).

#scope_module

text_backend_init :: () {
    array_add(*dw.insts, .{});
    DWriteCreateFactory(0, *IID_IDWriteFactory2, *dw.factory);
    dw.vtable = .[
        xx r_query_interface, xx r_add_ref, xx r_release,
        xx r_is_pixel_snapping_disabled, xx r_get_current_transform, xx r_get_pixels_per_dip,
        xx r_draw_glyph_run, xx r_draw_underline, xx r_draw_strikethrough, xx r_draw_inline_object,
    ];
    dw.renderer.vtable = *dw.vtable;
}

text_backend_shutdown :: () {
    for dw.insts release(it.face);
    array_free(dw.insts);
    if dw.mem_loader { (cast(#type (*void, *void) -> HRESULT #c_call) vt(dw.factory, 14))(dw.factory, dw.mem_loader); } // UnregisterFontFileLoader
    release(dw.mem_loader);
    release(dw.factory);
    dw = .{};
}

native_font_free :: (native: *void) {
    nf := cast(*Native_Face) native;
    if nf == null return;
    release(nf.collection);
    free(nf.family);
    free(nf.name);
    free(nf);
}

native_font_load_memory :: (data: []u8) -> *void {
    HR :: HRESULT;
    f5, stream, file, builder, set, coll, family, font, names: *void;
    defer { release(names); release(font); release(family); release(set); release(builder); release(file); release(stream); release(f5); }
    IID_IDWriteFactory5 := GUID.{0x958DB99A, 0xBE2A, 0x4F09, .[0xAF, 0x7D, 0x65, 0x18, 0x98, 0x03, 0xD1, 0xD3]};
    if !dw.factory || FAILED((cast(#type (*void, *GUID, **void) -> HR #c_call) vt(dw.factory, 0))(dw.factory, *IID_IDWriteFactory5, *f5)) return null;
    if !dw.mem_loader {
        // IDWriteFactory5::CreateInMemoryFontFileLoader, IDWriteFactory::RegisterFontFileLoader
        if FAILED((cast(#type (*void, **void) -> HR #c_call) vt(f5, 44))(f5, *dw.mem_loader)) return null;
        (cast(#type (*void, *void) -> HR #c_call) vt(dw.factory, 13))(dw.factory, dw.mem_loader);
    }
    bytes := data;
    // IDWriteFactory5::AnalyzeContainerType; UnpackFontFile into a stream, read whole (IDWriteFontFileStream
    // GetFileSize, ReadFileFragment, ReleaseFileFragment)
    container := (cast(#type (*void, *u8, u32) -> u32 #c_call) vt(f5, 46))(f5, data.data, xx data.count);
    frag_ctx: *void;
    if container != 0 {
        size: u64;
        p: *u8;
        if FAILED((cast(#type (*void, u32, *u8, u32, **void) -> HR #c_call) vt(f5, 47))(f5, container, data.data, xx data.count, *stream)) ||
            FAILED((cast(#type (*void, *u64) -> HR #c_call) vt(stream, 5))(stream, *size)) ||
            FAILED((cast(#type (*void, **u8, u64, u64, **void) -> HR #c_call) vt(stream, 3))(stream, *p, 0, size, *frag_ctx)) return null;
        bytes = .{xx size, p};
    }
    // IDWriteInMemoryFontFileLoader::CreateInMemoryFontFileReference copies the bytes (no owner);
    // IDWriteFactory5::CreateFontSetBuilder; IDWriteFontSetBuilder1::AddFontFile, CreateFontSet;
    // IDWriteFactory3::CreateFontCollectionFromFontSet; IDWriteFontCollection::GetFontFamily; IDWriteFontList::GetFont
    ok := SUCCEEDED((cast(#type (*void, *void, *u8, u32, *void, **void) -> HR #c_call) vt(dw.mem_loader, 4))(dw.mem_loader, dw.factory, bytes.data, xx bytes.count, null, *file));
    if frag_ctx { (cast(#type (*void, *void) #c_call) vt(stream, 4))(stream, frag_ctx); }
    ok = ok && SUCCEEDED((cast(#type (*void, **void) -> HR #c_call) vt(f5, 43))(f5, *builder)) &&
        SUCCEEDED((cast(#type (*void, *void) -> HR #c_call) vt(builder, 7))(builder, file)) &&
        SUCCEEDED((cast(#type (*void, **void) -> HR #c_call) vt(builder, 6))(builder, *set)) &&
        SUCCEEDED((cast(#type (*void, *void, **void) -> HR #c_call) vt(f5, 37))(f5, set, *coll)) &&
        SUCCEEDED((cast(#type (*void, u32, **void) -> HR #c_call) vt(coll, 4))(coll, 0, *family)) &&
        SUCCEEDED((cast(#type (*void, u32, **void) -> HR #c_call) vt(family, 5))(family, 0, *font));
    if !ok { release(coll); return null; }
    nf := New(Native_Face);
    nf.collection = coll;
    nf.weight = (cast(#type (*void) -> u32 #c_call) vt(font, 4))(font); // IDWriteFont::GetWeight, GetStyle
    nf.style = (cast(#type (*void) -> u32 #c_call) vt(font, 6))(font);
    // IDWriteFontFamily::GetFamilyNames; IDWriteFont::GetInformationalStrings(FULL_NAME), as CoreText's full name
    if SUCCEEDED((cast(#type (*void, **void) -> HR #c_call) vt(family, 6))(family, *names)) nf.family = localized(names);
    release(names);
    names = null;
    exists: BOOL;
    if SUCCEEDED((cast(#type (*void, u32, **void, *BOOL) -> HR #c_call) vt(font, 9))(font, 16, *names, *exists)) && exists && names {
        w := localized(names);
        if w nf.name = wide_to_utf8(w);
        free(w);
    }
    if !nf.family { native_font_free(nf); return null; }
    return nf;
}

native_font_system :: (name: string, weight: Font_Weight, italic: bool) -> *void {
    nf := New(Native_Face);
    nf.style = cast(u32) ifx italic then 2 else 0;
    nf.family = utf8_to_wide(ifx name == "" || name == "system" then "Segoe UI" else name); // NUL-terminated
    nf.weight = 400;
    if weight == {
        case .Medium;   nf.weight = 500;
        case .Semibold; nf.weight = 600;
        case .Bold;     nf.weight = 700;
    }
    return nf;
}

native_font_instance :: (native: *void, size_px: float32) -> u32 {
    nf := cast(*Native_Face) native;
    // collection (the system's, or a loaded font's own) -> family -> first matching font -> font face
    coll := nf.collection;
    if coll add_ref(coll);
    else (cast(#type (*void, **void, BOOL) -> HRESULT #c_call) vt(dw.factory, 3))(dw.factory, *coll, 0);
    if coll == null return 0;
    defer release(coll);
    index: u32;
    exists: BOOL;
    (cast(#type (*void, *u16, *u32, *BOOL) -> HRESULT #c_call) vt(coll, 5))(coll, nf.family, *index, *exists);
    if !exists  index = 0;
    family: *void;
    (cast(#type (*void, u32, **void) -> HRESULT #c_call) vt(coll, 4))(coll, index, *family);
    if family == null return 0;
    defer release(family);
    font: *void;
    (cast(#type (*void, u32, u32, u32, **void) -> HRESULT #c_call) vt(family, 7))(family, nf.weight, 5, nf.style, *font);
    if font == null return 0;
    defer release(font);
    face: *void;
    (cast(#type (*void, **void) -> HRESULT #c_call) vt(font, 13))(font, *face);
    if face == null return 0;
    defer release(face);
    return register_face(face, size_px, nf);
}

native_font_metrics :: (inst: u32) -> float32, float32, float32 {
    fi := dw.insts[inst];
    if fi.face == null return 0, 0, 0;
    m: DWRITE_FONT_METRICS;
    (cast(#type (*void, *DWRITE_FONT_METRICS) #c_call) vt(fi.face, 8))(fi.face, *m);
    k := fi.size / cast(float32) max(m.designUnitsPerEm, 1);
    return m.ascent * k, m.descent * k, m.lineGap * k;
}

native_font_name :: (inst: u32, allocator: Allocator) -> string {
    fi := dw.insts[inst];
    if fi.family == null return "";
    push_allocator(allocator);
    if fi.family.name return copy_string(fi.family.name);
    s := wide_to_utf8(fi.family.family);
    return s;
}

native_shape :: (inst: u32, text: string, out: *[..]Raw_Glyph) -> float32 {
    fi := dw.insts[inst];
    if fi.face == null || fi.family == null return 0;
    wide: [..]u16;
    map16: [..]int;
    wide.allocator = temp;
    map16.allocator = temp;
    array_reserve(*wide, text.count + 1);
    array_reserve(*map16, text.count + 1);
    i := 0;
    while i < text.count {
        r, n := decode_rune(text, i);
        if r >= 0x10000 {
            rr := r - 0x10000;
            array_add(*wide, cast(u16) (0xD800 + (rr >> 10)), cast(u16) (0xDC00 + (rr & 0x3ff)));
            array_add(*map16, i, i);
        } else if r == #char "\n" || r == #char "\r" || r == #char "\t" {
            // DirectWrite would start a new layout line; ui breaks lines itself and needs one glyph here.
            // Tabs are widened to their stops by text.jai's widen_tabs.
            array_add(*wide, #char " ");
            array_add(*map16, i);
        } else {
            array_add(*wide, cast(u16) r);
            array_add(*map16, i);
        }
        i += n;
    }
    array_add(*map16, text.count);
    locale := u16.[#char "e", #char "n", #char "-", #char "u", #char "s", 0];

    format: *void;
    (cast(#type (*void, *u16, *void, u32, u32, u32, float32, *u16, **void) -> HRESULT #c_call) vt(dw.factory, 15))(
        dw.factory, fi.family.family, fi.family.collection, fi.family.weight, fi.family.style, 5, fi.size, locale.data, *format);
    if format == null return 0;
    defer release(format);
    (cast(#type (*void, u32) -> HRESULT #c_call) vt(format, 5))(format, 1 /*NO_WRAP*/);
    layout: *void;
    (cast(#type (*void, *u16, u32, *void, float32, float32, **void) -> HRESULT #c_call) vt(dw.factory, 18))(
        dw.factory, wide.data, cast(u32) wide.count, format, 10000000, 10000000, *layout);
    if layout == null return 0;
    defer release(layout);

    dw.renderer.ctx = *context;
    dw.cur_out = out;
    dw.cur_map = map16;
    dw.cur_family = fi.family;
    dw.cur_width = 0;
    first := out.count;
    // Draw(context, renderer, originX, originY)
    (cast(#type (*void, *void, *void, float32, float32) -> HRESULT #c_call) vt(layout, 58))(layout, null, *dw.renderer, 0, 0);
    dw.cur_out = null;

    // Draw reports y from the layout's top; callers want it from the baseline, as CoreText gives it.
    line: DWRITE_LINE_METRICS;
    nlines: u32;
    (cast(#type (*void, *DWRITE_LINE_METRICS, u32, *u32) -> HRESULT #c_call) vt(layout, 59))(layout, *line, 1, *nlines);
    run := array_view(out.*, first);
    for * run  it.y -= line.baseline;

    // cluster_end = next distinct cluster start
    for * r, i: out.* {
        r.cluster_end = text.count;
        for o, j: out.* if j != i && o.cluster_start > r.cluster_start && o.cluster_start < r.cluster_end  r.cluster_end = o.cluster_start;
    }
    return dw.cur_width;
}

native_rasterize :: (inst: u32, glyph: u32, subpx: float32, allocator: Allocator) -> Glyph_Bitmap {
    fi := dw.insts[inst];
    if fi.face == null return .{};
    idx := cast(u16) glyph;
    adv: float32 = 0;
    off: DWRITE_GLYPH_OFFSET;
    run := DWRITE_GLYPH_RUN.{fontFace = fi.face, fontEmSize = fi.size, glyphCount = 1, glyphIndices = *idx, glyphAdvances = *adv, glyphOffsets = *off};

    // Color fonts (Segoe UI Emoji's COLR layers): IDWriteFactory2::TranslateColorGlyphRun fails with
    // DWRITE_E_NOCOLOR for plain glyphs, which then take the grayscale path.
    layers: *void;
    hr := (cast(#type (*void, float32, float32, *DWRITE_GLYPH_RUN, *void, u32, *void, u32, **void) -> HRESULT #c_call) vt(dw.factory, 28))(
        dw.factory, subpx, 0, *run, null, 0, null, 0, *layers);
    if SUCCEEDED(hr) && layers {
        defer release(layers);
        return rasterize_color(layers, allocator);
    }

    pixels, r := rasterize_alpha(*run, subpx, 0, allocator);
    if !pixels return .{};
    return .{w = r.right - r.left, h = r.bottom - r.top, left = r.left, top = r.top, pixels = pixels};
}

#scope_file

DWriteCreateFactory :: (factoryType: u32, iid: *GUID, factory: **void) -> HRESULT #foreign dwrite;

IID_IDWriteFactory2      :: GUID.{0x0439fc60, 0xca44, 0x4994, .[0x8d, 0xee, 0x3a, 0x9a, 0xf7, 0xb7, 0x32, 0xec]};
IID_IDWriteTextRenderer  :: GUID.{0xef8a8135, 0x5cc6, 0x4fe3, .[0x8b, 0x6c, 0xd7, 0x3d, 0xd4, 0x0e, 0x4b, 0x2c]};
IID_IDWritePixelSnapping :: GUID.{0xeaf3a2da, 0xecf4, 0x4d24, .[0xb6, 0x44, 0xb3, 0x4f, 0x68, 0x42, 0x02, 0x4b]};
IID_IUnknown             :: GUID.{0x00000000, 0x0000, 0x0000, .[0xc0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46]};

vt :: inline (obj: *void, idx: int) -> *void { return (cast(***void) obj).*[idx]; }

release :: (obj: *void) {
    if obj { (cast(#type (*void) -> u32 #c_call) vt(obj, 2))(obj); }
}

add_ref :: (obj: *void) {
    (cast(#type (*void) -> u32 #c_call) vt(obj, 1))(obj);
}

DWRITE_GLYPH_OFFSET :: struct { advanceOffset, ascenderOffset: float32; }

DWRITE_GLYPH_RUN :: struct {
    fontFace: *void;
    fontEmSize: float32;
    glyphCount: u32;
    glyphIndices: *u16;
    glyphAdvances: *float32;
    glyphOffsets: *DWRITE_GLYPH_OFFSET;
    isSideways: BOOL;
    bidiLevel: u32;
}

DWRITE_GLYPH_RUN_DESCRIPTION :: struct {
    localeName: *u16;
    string_: *u16;
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
    isTrimmed: BOOL;
}

DWRITE_COLOR_GLYPH_RUN :: struct {
    glyphRun: DWRITE_GLYPH_RUN;
    glyphRunDescription: *DWRITE_GLYPH_RUN_DESCRIPTION;
    baselineOriginX: float32;
    baselineOriginY: float32;
    runColor: [4]float32;
    paletteIndex: u16;
}

Native_Face :: struct {
    family: *u16; // NUL-terminated
    name: string; // a loaded font's full name ("" for system fonts)
    collection: *void; // IDWriteFontCollection holding only a loaded font; null for system fonts
    weight: u32;
    style: u32; // DWRITE_FONT_STYLE
}

Font_Inst :: struct {
    face: *void;   // IDWriteFontFace (AddRef'd)
    size: float32; // px (em size)
    family: *Native_Face;
}

// Custom IDWriteTextRenderer: a COM object whose vtable points at the r_* procs; ctx is the context of
// the thread calling IDWriteTextLayout::Draw, which runs the callbacks.
Renderer :: struct {
    vtable: *[10]*void;
    ctx: *#Context;
}

dw: struct {
    factory: *void; // IDWriteFactory2
    mem_loader: *void; // IDWriteInMemoryFontFileLoader, registered on first font_load_memory
    renderer: Renderer;
    vtable: [10]*void;
    insts: [..]Font_Inst;
    // per-shape state used by the renderer callback
    cur_out: *[..]Raw_Glyph;
    cur_map: []int; // utf16 index -> utf8 byte
    cur_family: *Native_Face;
    cur_width: float32;
};

register_face :: (face: *void, size: float32, family: *Native_Face) -> u32 {
    for dw.insts if it.face == face && it.size == size return cast(u32) it_index;
    add_ref(face);
    array_add(*dw.insts, .{face = face, size = size, family = family});
    return cast(u32) (dw.insts.count - 1);
}

// IDWriteTextRenderer implementation.
r_query_interface :: (this: *void, riid: *GUID, out: **void) -> HRESULT #c_call {
    if guid_equal(riid, *IID_IUnknown) || guid_equal(riid, *IID_IDWriteTextRenderer) || guid_equal(riid, *IID_IDWritePixelSnapping) {
        out.* = this;
        return S_OK;
    }
    out.* = null;
    return cast,no_check(HRESULT) 0x80004002; // E_NOINTERFACE
}
r_add_ref :: (this: *void) -> u32 #c_call { return 1; }
r_release :: (this: *void) -> u32 #c_call { return 1; }
r_is_pixel_snapping_disabled :: (this: *void, ctx: *void, out: *BOOL) -> HRESULT #c_call {
    out.* = 1; // keep fractional positions; we snap ourselves
    return S_OK;
}
r_get_current_transform :: (this: *void, ctx: *void, m: *[6]float32) -> HRESULT #c_call {
    m.* = .[1, 0, 0, 1, 0, 0];
    return S_OK;
}
r_get_pixels_per_dip :: (this: *void, ctx: *void, out: *float32) -> HRESULT #c_call {
    out.* = 1;
    return S_OK;
}
r_draw_underline :: (this: *void, ctx: *void, x: float32, y: float32, u: *void, effect: *void) -> HRESULT #c_call { return S_OK; }
r_draw_strikethrough :: (this: *void, ctx: *void, x: float32, y: float32, s: *void, effect: *void) -> HRESULT #c_call { return S_OK; }
r_draw_inline_object :: (this: *void, ctx: *void, x: float32, y: float32, obj: *void, sideways: BOOL, rtl: BOOL, effect: *void) -> HRESULT #c_call { return S_OK; }

r_draw_glyph_run :: (this: *void, ctx: *void, x: float32, y: float32, mode: u32, run: *DWRITE_GLYPH_RUN, desc: *DWRITE_GLYPH_RUN_DESCRIPTION, effect: *void) -> HRESULT #c_call {
    push_context (cast(*Renderer) this).ctx.* {
        if dw.cur_out == null return S_OK;
        finst := register_face(run.fontFace, run.fontEmSize, dw.cur_family);
        n := cast(int) run.glyphCount;
        // glyph -> first utf16 char of its cluster (within this run)
        glyph_char := NewArray(n, int, initialized = false,, temp);
        for * glyph_char  it.* = -1;
        for ci: 0..cast(int) desc.stringLength - 1 {
            gi := cast(int) desc.clusterMap[ci];
            if gi < n && glyph_char[gi] < 0  glyph_char[gi] = ci;
        }
        last := 0;
        for * glyph_char {
            if it.* < 0  it.* = last;
            last = it.*;
        }
        pen := x;
        rtl := (run.bidiLevel & 1) != 0;
        for gi: 0..n-1 {
            adv := ifx run.glyphAdvances then run.glyphAdvances[gi] else 0;
            off := ifx run.glyphOffsets then run.glyphOffsets[gi] else DWRITE_GLYPH_OFFSET.{};
            gx := ifx rtl then pen - adv - off.advanceOffset else pen + off.advanceOffset;
            u16i := cast(int) desc.textPosition + glyph_char[gi];
            start := dw.cur_map[clamp(u16i, 0, dw.cur_map.count - 1)];
            array_add(dw.cur_out, .{font = finst, glyph = run.glyphIndices[gi], x = gx, y = y - off.ascenderOffset, advance = adv, cluster_start = start});
            pen += ifx rtl then -adv else adv;
        }
        dw.cur_width = max(dw.cur_width, pen);
    }
    return S_OK;
}

// String 0 of an IDWriteLocalizedStrings (GetStringLength, GetString), NUL-terminated, heap.
localized :: (names: *void) -> *u16 {
    n: u32;
    if FAILED((cast(#type (*void, u32, *u32) -> HRESULT #c_call) vt(names, 7))(names, 0, *n)) || n > 1024 return null;
    buf := NewArray(n + 1, u16);
    if FAILED((cast(#type (*void, u32, *u16, u32) -> HRESULT #c_call) vt(names, 8))(names, 0, buf.data, n + 1)) { free(buf.data); return null; }
    return buf.data;
}

guid_equal :: (a: *GUID, b: *GUID) -> bool #no_context {
    return memcmp(a, b, size_of(GUID)) == 0;
}

// Grayscale coverage of a glyph run with its baseline origin at (x, y); r is in pixels, y down.
rasterize_alpha :: (run: *DWRITE_GLYPH_RUN, x: float32, y: float32, allocator: Allocator) -> []u8, RECT {
    r: RECT;
    analysis: *void;
    // IDWriteFactory2::CreateGlyphRunAnalysis(run, transform, renderingMode, measuringMode, gridFitMode, antialiasMode, x, y, out)
    hr := (cast(#type (*void, *DWRITE_GLYPH_RUN, *void, u32, u32, u32, u32, float32, float32, **void) -> HRESULT #c_call) vt(dw.factory, 30))(
        dw.factory, run, null, 5, 0, 1, 1, x, y, *analysis);
    if FAILED(hr) || analysis == null return .[], r;
    defer release(analysis);
    (cast(#type (*void, u32, *RECT) -> HRESULT #c_call) vt(analysis, 3))(analysis, 0, *r);
    w, h := r.right - r.left, r.bottom - r.top;
    if w <= 0 || h <= 0 return .[], .{};
    pixels := NewArray(w * h, u8,, allocator);
    (cast(#type (*void, u32, *RECT, *u8, u32) -> HRESULT #c_call) vt(analysis, 4))(analysis, 0, *r, pixels.data, cast(u32) pixels.count);
    return pixels, r;
}

// Composites each color layer over the previous ones; output is straight-alpha RGBA like the CoreText path.
rasterize_color :: (layers: *void, allocator: Allocator) -> Glyph_Bitmap {
    Layer :: struct {
        pixels: []u8;
        r: RECT;
        color: [4]float32;
    }
    list: [..]Layer;
    list.allocator = temp;
    bounds := RECT.{S32_MAX, S32_MAX, S32_MIN, S32_MIN};
    while true {
        has_run: BOOL;
        if FAILED((cast(#type (*void, *BOOL) -> HRESULT #c_call) vt(layers, 3))(layers, *has_run)) || !has_run break;
        cr: *DWRITE_COLOR_GLYPH_RUN;
        if FAILED((cast(#type (*void, **DWRITE_COLOR_GLYPH_RUN) -> HRESULT #c_call) vt(layers, 4))(layers, *cr)) || cr == null break;
        pixels, r := rasterize_alpha(*cr.glyphRun, cr.baselineOriginX, cr.baselineOriginY, temp);
        if !pixels continue;
        // Palette index 0xFFFF means "the text color"; emoji are drawn untinted, so use black as CoreText does.
        color := ifx cr.paletteIndex == 0xFFFF then float32.[0, 0, 0, 1] else cr.runColor;
        array_add(*list, .{pixels, r, color});
        bounds.left = min(bounds.left, r.left);
        bounds.top = min(bounds.top, r.top);
        bounds.right = max(bounds.right, r.right);
        bounds.bottom = max(bounds.bottom, r.bottom);
    }
    if !list return .{};
    w, h := bounds.right - bounds.left, bounds.bottom - bounds.top;
    if w <= 0 || h <= 0 || w > 1024 || h > 1024 return .{};

    acc := NewArray(w * h, [4]float32,, temp); // premultiplied
    for l: list {
        lw := l.r.right - l.r.left;
        for y: l.r.top..l.r.bottom-1  for x: l.r.left..l.r.right-1 {
            a := cast(float32) l.pixels[(y - l.r.top) * lw + (x - l.r.left)] / 255 * l.color[3];
            if a == 0 continue;
            d := *acc[(y - bounds.top) * w + (x - bounds.left)];
            for c: 0..2  d.*[c] = l.color[c] * a + d.*[c] * (1 - a);
            d.*[3] = a + d.*[3] * (1 - a);
        }
    }
    out := NewArray(w * h * 4, u8,, allocator);
    for p, i: acc {
        if p[3] <= 0 continue;
        for c: 0..2  out[i * 4 + c] = cast(u8) min(p[c] / p[3] * 255 + 0.5, 255);
        out[i * 4 + 3] = cast(u8) min(p[3] * 255 + 0.5, 255);
    }
    return .{w = w, h = h, left = bounds.left, top = bounds.top, pixels = out, is_color = true};
}
