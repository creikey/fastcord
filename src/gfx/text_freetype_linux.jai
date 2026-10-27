// FreeType + HarfBuzz text backend (Linux; vendor/freetype, vendor/harfbuzz).
//
// Fonts come from fontconfig, opened at run time with dlopen so the binary links nothing but glibc;
// without it, well-known files under /usr/share/fonts stand in. A run is split wherever the font
// (per-character fallback, colour emoji first for emoji) or the script changes, and each piece is
// shaped by HarfBuzz. FreeType rasterizes unhinted, as macOS draws, with the subpixel offset applied as
// a transform. Colour glyphs: CBDT bitmaps (Noto Color Emoji; PNG through Wuffs, see
// vendor/freetype/fc_freetype.c) scaled from their strike, and COLRv0 layers.
// Not done: bidi beyond per-script runs (no paragraph reordering), COLRv1 and OT-SVG colour glyphs.

#scope_module

text_backend_init :: () {
    FT_Init_FreeType(*ft.lib);
    array_add(*ft.insts, .{}); // 0 = none
    ft.buf = hb_buffer_create();
    ft.fc = fc_load();
}

text_backend_shutdown :: () {
    for ft.insts if it.hb  hb_font_destroy(it.hb);
    for ft.faces {
        hb_face_destroy(it.hb);
        FT_Done_Face(it.ft); // and its FT_Sizes
        free(it.data.data);
        free(it);
    }
    for ft.sorted if it  fc.FcFontSetDestroy(it);
    for ft.files  free(it_index);
    for ft.paths { free(it_index); free(it); }
    deinit(*ft.files);
    deinit(*ft.paths);
    deinit(*ft.fallback);
    array_free(ft.insts);
    array_free(ft.faces);
    array_free(ft.starts);
    hb_buffer_destroy(ft.buf);
    FT_Done_FreeType(ft.lib);
    ft = .{};
}

// Faces belong to ft.faces (fallbacks share them) and are freed by text_backend_shutdown, which
// text_shutdown calls first.
native_font_free :: (native: *void) {}

native_font_load_memory :: (data: []u8) -> *void {
    bytes := array_copy(data);
    f: FT_Face;
    if FT_New_Memory_Face(ft.lib, bytes.data, bytes.count, 0, *f) != 0 {
        free(bytes.data);
        return null;
    }
    return add_face(f, 0, bytes, 0);
}

native_font_system :: (name: string, weight: Font_Weight, italic: bool) -> *void {
    mono := name == "monospace" || name == "Consolas" || name == "Menlo";
    family := ifx name == "" || name == "system" then "sans-serif" else ifx mono then "monospace" else name;
    nf: *Native_Face;
    if ft.fc {
        p := fc_pattern(family, weight, italic);
        res: s32;
        m := fc.FcFontMatch(null, p, *res);
        fc.FcPatternDestroy(p);
        if m {
            path, index := pattern_file(m);
            if path  nf = open_file(path, index, OT_WEIGHT[weight]);
            fc.FcPatternDestroy(m);
        }
    } else {
        bold := weight >= .Semibold;
        style := ifx bold then (ifx italic then "BoldItalic" else "Bold") else ifx italic then "Italic" else "Regular";
        dv := ifx bold then (ifx italic then "-BoldOblique" else "-Bold") else ifx italic then "-Oblique" else "";
        names: [3]string;
        if mono  names = .[tprint("DejaVuSansMono%.ttf", dv), tprint("NotoSansMono-%.ttf", style), tprint("LiberationMono-%.ttf", style)];
        else names = .[tprint("NotoSans-%.ttf", style), tprint("DejaVuSans%.ttf", dv), tprint("LiberationSans-%.ttf", style)];
        for names {
            path := known_path(it);
            if path { nf = open_file(path, 0, 0); break; }
        }
        if !nf for ft.paths if ends_with(it_index, ".ttf") { nf = open_file(it, 0, 0); break; }
    }
    if nf {
        nf.weight = weight;
        nf.italic = italic;
        // no italic face installed: slant the upright one, as DirectWrite and CoreText do
        nf.oblique = italic && nf.scalable && (fc_ft_style_flags(nf.ft) & 1 /*FT_STYLE_FLAG_ITALIC*/) == 0;
    }
    return nf;
}

native_font_instance :: (native: *void, size_px: float32) -> u32 {
    nf := cast(*Native_Face) native;
    if !nf return 0;
    for ft.insts if it.face == nf && it.size == size_px return cast(u32) it_index;
    fi := Font_Inst.{face = nf, size = size_px, scale = 1};
    if FT_New_Size(nf.ft, *fi.ft_size) != 0 return 0;
    FT_Activate_Size(fi.ft_size);
    if nf.scalable {
        FT_Set_Char_Size(nf.ft, 0, cast(s64) round(size_px * 64), 0, 0);
    } else {
        // bitmap-only (CBDT emoji): the nearest strike, scaled when drawn
        ppem := fc_ft_select_strike(nf.ft, size_px);
        if ppem > 0  fi.scale = size_px / ppem;
    }
    fi.hb = hb_font_create(nf.hb);
    q := cast(s32) round(size_px * 64); // positions in 1/64 px
    hb_font_set_scale(fi.hb, q, q);
    if nf.named  hb_font_set_var_named_instance(fi.hb, nf.named - 1);
    else if nf.wght > 0 {
        v := hb_variation_t.{TAG_WGHT, nf.wght};
        hb_font_set_variations(fi.hb, *v, 1);
    }
    array_add(*ft.insts, fi);
    return cast(u32) (ft.insts.count - 1);
}

native_font_metrics :: (inst: u32) -> float32, float32, float32 {
    fi := ft.insts[inst];
    if !fi.hb return 0, 0, 0;
    e: hb_font_extents_t;
    hb_font_get_h_extents(fi.hb, *e);
    return cast(float32) e.ascender / 64, cast(float32) -e.descender / 64, cast(float32) e.line_gap / 64;
}

native_font_name :: (inst: u32, allocator: Allocator) -> string {
    fi := ft.insts[inst];
    if !fi.face return "";
    buf: [256]u8;
    n: u32 = buf.count;
    if !hb_ot_name_get_utf8(fi.face.hb, 4 /*full name*/, null, *n, buf.data) return "";
    return copy_string(string.{n, buf.data},, allocator);
}

native_shape :: (inst: u32, text: string, out: *[..]Raw_Glyph) -> float32 {
    base := ft.insts[inst];
    if !base.face return 0;
    // Line breaks and tabs shape as spaces, one glyph each, as on Windows; tabs are widened below.
    s := copy_string(text,, temp);
    for * cast([]u8) s if it.* == #char "\n" || it.* == #char "\r" || it.* == #char "\t"  it.* = #char " ";

    first := out.count;
    ufuncs := hb_unicode_funcs_get_default();
    pen: float32;
    run_face: *Native_Face;
    run_start, strong_end := 0, 0; // strong_end: after the run's last letter of its script
    run_script, prev: u32;
    i := 0;
    while true {
        done := i >= s.count;
        cp, sc: u32;
        n: int;
        f: *Native_Face;
        if !done {
            cp, n = decode_rune(s, i);
            next: u32;
            if i + n < s.count  next = decode_rune(s, i + n);
            f = pick_face(base.face, run_face, cp, prev, next);
            sc = hb_unicode_script(ufuncs, cp);
        }
        strong := !done && sc != SCRIPT_COMMON && sc != SCRIPT_INHERITED && sc != SCRIPT_UNKNOWN;
        if run_face && (done || f != run_face || (strong && run_script && sc != run_script)) {
            // Spaces and punctuation after a right-to-left run read left to right, as in a
            // left-to-right paragraph, so they stay on the run's right.
            end := ifx run_script && hb_script_get_horizontal_direction(run_script) == HB_DIRECTION_RTL then strong_end else i;
            pen = shape_run(s, run_start, end, run_face, run_script, base.size, pen, out);
            if end < i  pen = shape_run(s, end, i, run_face, 0, base.size, pen, out);
            run_start = i;
            run_script = 0;
        }
        if done break;
        run_face = f;
        if strong {
            if !run_script  run_script = sc;
            strong_end = i + n;
        }
        prev = cp;
        i += n;
    }

    // Tab stops every 4 spaces from the start of each hard line (CSS tab-size: 4), as on Windows.
    run := array_view(out.*, first);
    line_x, shift: float32;
    for * gl: run {
        gl.x += shift;
        if gl.cluster_start >= text.count continue;
        c := text[gl.cluster_start];
        if c == #char "\n" {
            line_x = gl.x + gl.advance;
        } else if c == #char "\t" {
            stop := 4 * gl.advance;
            if stop <= 0 continue;
            col := gl.x - line_x;
            adv := (floor(col / stop) + 1) * stop - col;
            shift += adv - gl.advance;
            gl.advance = adv;
        }
    }
    // cluster_end = next distinct cluster start (ligatures, multi-glyph clusters)
    ft.starts.count = 0;
    for run  array_add(*ft.starts, it.cluster_start);
    quick_sort(ft.starts, x => x);
    for * r: run {
        lo, hi := 0, ft.starts.count; // first start > r.cluster_start
        while lo < hi {
            mid := (lo + hi) / 2;
            if ft.starts[mid] > r.cluster_start  hi = mid; else lo = mid + 1;
        }
        r.cluster_end = ifx lo < ft.starts.count then ft.starts[lo] else text.count;
    }
    return pen + shift;
}

native_rasterize :: (inst: u32, glyph: u32, subpx: float32, allocator: Allocator) -> Glyph_Bitmap {
    fi := ft.insts[inst];
    if !fi.face return .{};
    f := fi.face.ft;
    FT_Activate_Size(fi.ft_size);
    delta := FT_Vector.{x = cast(s64) round(subpx * 64)};
    shear := FT_Matrix.{0x10000, 0x366A, 0, 0x10000}; // a shear of about 12 degrees, as FT_GlyphSlot_Oblique
    FT_Set_Transform(f, ifx fi.face.oblique then *shear else null, *delta);
    flags: s32 = FT_LOAD_RENDER | FT_LOAD_NO_HINTING;
    if fi.face.color  flags |= FT_LOAD_COLOR;
    else if fi.face.scalable  flags |= FT_LOAD_NO_BITMAP; // outlines, as macOS, not embedded strikes
    if FT_Load_Glyph(f, glyph, flags) != 0 return .{};
    b: Ft_Bitmap;
    fc_ft_glyph_bitmap(f, *b);
    if b.width <= 0 || b.rows <= 0 return .{};
    row :: (b: Ft_Bitmap, y: s32) -> *u8 {
        return b.buffer + ifx b.pitch >= 0 then y * b.pitch else (b.rows - 1 - y) * -b.pitch; // negative pitch: bottom row first
    }

    if b.pixel_mode == FT_PIXEL_MODE_GRAY || b.pixel_mode == FT_PIXEL_MODE_MONO {
        if b.width > 1024 || b.rows > 1024 return .{};
        out := NewArray(b.width * b.rows, u8, initialized = false,, allocator);
        for y: 0..b.rows-1 {
            r := row(b, y);
            for x: 0..b.width-1 {
                v := r[x];
                if b.pixel_mode == FT_PIXEL_MODE_MONO  v = cast(u8) ifx ((cast(u32) r[x / 8]) >> cast(u32) (7 - x % 8)) & 1 then 255 else 0;
                out[y * b.width + x] = v;
            }
        }
        return .{w = b.width, h = b.rows, left = b.left, top = -b.top, pixels = out};
    }
    if b.pixel_mode != FT_PIXEL_MODE_BGRA return .{};

    // Premultiplied BGRA at the strike's size -> straight RGBA at the instance's: each output pixel
    // averages the source area it covers.
    sc := fi.scale;
    w := max(cast(s32) ceil(b.width * sc), 1);
    h := max(cast(s32) ceil(b.rows * sc), 1);
    if w > 1024 || h > 1024 return .{};
    out := NewArray(w * h * 4, u8,, allocator);
    inv := 1 / sc;
    for y: 0..h-1  for x: 0..w-1 {
        y0, y1 := y * inv, min((y + 1) * inv, cast(float32) b.rows);
        x0, x1 := x * inv, min((x + 1) * inv, cast(float32) b.width);
        acc: [4]float32;
        for sy: cast(s32) y0..cast(s32) ceil(y1) - 1 {
            wy := min(sy + 1.0, y1) - max(cast(float32) sy, y0);
            r := row(b, sy);
            for sx: cast(s32) x0..cast(s32) ceil(x1) - 1 {
                wt := wy * (min(sx + 1.0, x1) - max(cast(float32) sx, x0));
                for c: 0..3  acc[c] += r[sx * 4 + c] * wt;
            }
        }
        if acc[3] <= 0 continue;
        o := out.data + (y * w + x) * 4;
        for c: 0..2  o[c] = cast(u8) min(acc[2 - c] / acc[3] * 255 + 0.5, 255);
        o[3] = cast(u8) min(acc[3] * sc * sc + 0.5, 255);
    }
    return .{w = w, h = h, left = cast(s32) round(b.left * sc), top = -cast(s32) round(b.top * sc), is_color = true, pixels = out};
}

#scope_file

Native_Face :: struct {
    ft: FT_Face;
    hb: *void;     // hb_face_t, tables read through FreeType (so WOFF2 works)
    data: []u8;    // the font's bytes for faces loaded from memory
    named: u32;    // named instance + 1 (fontconfig's index >> 16), 0 = none
    wght: float32; // 'wght' axis set on a variable face without a named instance, 0 = none
    color, scalable: bool;
    weight: Font_Weight; // the style fallback fonts are matched in
    italic: bool;
    oblique: bool; // italic asked for, upright face found: glyphs are sheared when drawn
}

Font_Inst :: struct {
    face: *Native_Face;
    size: float32; // px
    ft_size: FT_Size;
    hb: *void;     // hb_font_t at size
    scale: float32; // px per strike pixel (bitmap-only faces), else 1
}

ft: struct {
    lib: FT_Library;
    fc: bool; // fontconfig loaded
    insts: [..]Font_Inst;
    faces: [..]*Native_Face;
    files: Table(string, *Native_Face); // "path:index" -> fallback face (null: failed to open)
    fallback: Table(u32, *Native_Face); // codepoint, style, colour-only -> face (null: none)
    sorted: [8]*FcFontSet;              // fallback order per style (weight * 2 + italic)
    paths: Table(string, string);       // without fontconfig: file name -> path under the font dirs
    scanned: bool;
    buf: *void; // hb_buffer_t
    starts: [..]int;
};

OT_WEIGHT :: float32.[400, 500, 600, 700];
FC_WEIGHT :: s32.[80, 100, 180, 200]; // FC_WEIGHT_REGULAR, MEDIUM, SEMIBOLD, BOLD
TAG_WGHT :: 0x77676874;
SCRIPT_COMMON :: 0x5A797979;    // Zyyy
SCRIPT_INHERITED :: 0x5A696E68; // Zinh
SCRIPT_UNKNOWN :: 0x5A7A7A7A;   // Zzzz
HB_DIRECTION_LTR :: 4;
HB_DIRECTION_RTL :: 5;
// Without fontconfig, per-character fallback tries these files in order.
FALLBACK_FILES :: string.["NotoSansCJK-Regular.ttc", "NotoSansCJKsc-Regular.otf", "DejaVuSans.ttf", "NotoSansSymbols2-Regular.ttf",
    "NotoSansSymbols-Regular.ttf", "NotoColorEmoji.ttf", "Symbola.ttf"];

add_face :: (f: FT_Face, index: s64, data: []u8, wght: float32) -> *Native_Face {
    nf := New(Native_Face);
    nf.ft = f;
    nf.data = data;
    nf.hb = hb_face_create_for_tables(cast(*void) reference_table, f, null);
    flags := fc_ft_face_flags(f);
    nf.color = (flags & FT_FACE_FLAG_COLOR) != 0;
    nf.scalable = (flags & FT_FACE_FLAG_SCALABLE) != 0;
    nf.named = cast(u32) (index >> 16);
    if wght > 0 && !nf.named && (flags & FT_FACE_FLAG_MULTIPLE_MASTERS) {
        fc_ft_set_axis(f, TAG_WGHT, wght);
        nf.wght = wght;
    }
    array_add(*ft.faces, nf);
    return nf;
}

open_file :: (path: string, index: s64, wght: float32) -> *Native_Face {
    f: FT_Face;
    if FT_New_Face(ft.lib, temp_c_string(path), index, *f) != 0 return null;
    return add_face(f, index, .[], wght);
}

// HarfBuzz reads each table through FreeType, which has already unpacked WOFF2.
reference_table :: (face: *void, tag: u32, user_data: *void) -> *void #c_call {
    len: u64;
    if tag == 0 || FT_Load_Sfnt_Table(user_data, tag, 0, null, *len) != 0 || len == 0 return null;
    buf := c_malloc(len);
    if !buf return null;
    if FT_Load_Sfnt_Table(user_data, tag, 0, buf, *len) != 0 { c_free(buf); return null; }
    return hb_blob_create(buf, cast(u32) len, 2 /*HB_MEMORY_MODE_WRITABLE*/, buf, cast(*void) c_free);
}

has :: (f: *Native_Face, cp: u32) -> bool { return FT_Get_Char_Index(f.ft, cp) != 0; }

// The face for cp in a run currently set in run_face: joiners, modifiers and selectors stay with it,
// emoji go to a colour font first, then the primary face, then fontconfig's fallback order.
pick_face :: (primary: *Native_Face, run_face: *Native_Face, cp: u32, prev: u32, next: u32) -> *Native_Face {
    joiner := cp == 0x200C || cp == 0x200D || (cp >= 0xFE00 && cp <= 0xFE0F) || cp == 0x20E3 || (cp >= 0x1F3FB && cp <= 0x1F3FF)
        || (cp >= 0xE0020 && cp <= 0xE007F) || (cp >= 0x300 && cp <= 0x36F);
    if run_face && (joiner || (prev == 0x200D && has(run_face, cp))) return run_face;
    style := cast(u32) primary.weight * 2 + cast(u32) primary.italic;
    if (cp >= 0x1F000 && cp <= 0x1FAFF) || next == 0xFE0F {
        f := fallback(cp, style, true);
        if f return f;
    }
    if has(primary, cp) return primary;
    f := fallback(cp, style, false);
    return ifx f then f else primary;
}

fallback :: (cp: u32, style: u32, color: bool) -> *Native_Face {
    key := cp | (style << 21) | ((cast(u32) color) << 24);
    found, f := table_find(*ft.fallback, key);
    if found return f;
    f = null;
    if ft.fc {
        set := ft.sorted[style];
        if !set {
            p := fc_pattern("sans-serif", cast(Font_Weight) (style / 2), (style & 1) != 0);
            res: s32;
            set = fc.FcFontSort(null, p, 0, null, *res);
            fc.FcPatternDestroy(p);
            ft.sorted[style] = set;
        }
        if set for i: 0..set.nfont-1 {
            p := set.fonts[i];
            b: s32;
            if color && (fc.FcPatternGetBool(p, "color", 0, *b) != 0 || !b) continue;
            cs: *void;
            if fc.FcPatternGetCharSet(p, "charset", 0, *cs) != 0 || !fc.FcCharSetHasChar(cs, cp) continue;
            path, index := pattern_file(p);
            g := cached_file(path, index);
            if g && has(g, cp) { f = g; break; }
        }
    } else {
        for FALLBACK_FILES {
            g := cached_file(known_path(it), 0);
            if g && (!color || g.color) && has(g, cp) { f = g; break; }
        }
    }
    table_add(*ft.fallback, key, f);
    return f;
}

cached_file :: (path: string, index: s64) -> *Native_Face {
    if !path return null;
    key := tprint("%:%", path, index);
    found, f := table_find(*ft.files, key);
    if found return f;
    f = open_file(path, index, 0);
    table_add(*ft.files, copy_string(key), f);
    return f;
}

// Without fontconfig: the path of a font file by name under the usual font directories, "" if none.
known_path :: (name: string) -> string {
    if !ft.scanned {
        ft.scanned = true;
        home := getenv("HOME");
        dirs: [4]string;
        dirs[0] = "/usr/share/fonts";
        dirs[1] = "/usr/local/share/fonts";
        if home {
            dirs[2] = tprint("%/.local/share/fonts", to_string(home));
            dirs[3] = tprint("%/.fonts", to_string(home));
        }
        for dirs if it && is_directory(it)  visit_files(it, true, null, (info: *File_Visit_Info, _: *void) {
            if !table_find_pointer(*ft.paths, info.short_name)  table_add(*ft.paths, copy_string(info.short_name), copy_string(info.full_name));
        });
    }
    found, path := table_find(*ft.paths, name);
    return path;
}

// ---- fontconfig, through dlopen

fc_load :: () -> bool {
    h := dlopen("libfontconfig.so.1", 2 /*RTLD_NOW*/);
    if !h return false;
    for type_info(Fc).members {
        p := dlsym(h, temp_c_string(it.name));
        if !p return false;
        (cast(**void) ((cast(*u8) *fc) + it.offset_in_bytes)).* = p;
    }
    return fc.FcInit() != 0;
}

fc_pattern :: (family: string, weight: Font_Weight, italic: bool) -> *void {
    p := fc.FcPatternCreate();
    fc.FcPatternAddString(p, "family", temp_c_string(family));
    fc.FcPatternAddInteger(p, "weight", FC_WEIGHT[weight]);
    fc.FcPatternAddInteger(p, "slant", cast(s32) ifx italic then 100 else 0); // FC_SLANT_ITALIC, ROMAN
    fc.FcConfigSubstitute(null, p, 0 /*FcMatchPattern*/);
    fc.FcDefaultSubstitute(p);
    return p;
}

// The font file and face index of a matched pattern; the path points into the pattern.
pattern_file :: (p: *void) -> string, s64 {
    s: *u8;
    i: s32;
    if fc.FcPatternGetString(p, "file", 0, *s) != 0 return "", 0;
    fc.FcPatternGetInteger(p, "index", 0, *i);
    return to_string(s), i;
}

FcFontSet :: struct {
    nfont, sfont: s32;
    fonts: **void;
}

// Filled by name with dlsym. FcBool is int; FcResult 0 is FcResultMatch.
Fc :: struct {
    FcInit: () -> s32 #c_call;
    FcPatternCreate: () -> *void #c_call;
    FcPatternDestroy: (p: *void) #c_call;
    FcPatternAddString: (p: *void, object: *u8, s: *u8) -> s32 #c_call;
    FcPatternAddInteger: (p: *void, object: *u8, i: s32) -> s32 #c_call;
    FcPatternGetString: (p: *void, object: *u8, n: s32, s: **u8) -> s32 #c_call;
    FcPatternGetInteger: (p: *void, object: *u8, n: s32, i: *s32) -> s32 #c_call;
    FcPatternGetBool: (p: *void, object: *u8, n: s32, b: *s32) -> s32 #c_call;
    FcPatternGetCharSet: (p: *void, object: *u8, n: s32, c: **void) -> s32 #c_call;
    FcCharSetHasChar: (c: *void, ucs4: u32) -> s32 #c_call;
    FcConfigSubstitute: (config: *void, p: *void, kind: s32) -> s32 #c_call;
    FcDefaultSubstitute: (p: *void) #c_call;
    FcFontMatch: (config: *void, p: *void, result: *s32) -> *void #c_call;
    FcFontSort: (config: *void, p: *void, trim: s32, csp: **void, result: *s32) -> *FcFontSet #c_call;
    FcFontSetDestroy: (s: *FcFontSet) #c_call;
}
fc: Fc;

text_libc :: #system_library "libc";
dlopen :: (file: *u8, mode: s32) -> *void #foreign text_libc;
dlsym :: (handle: *void, name: *u8) -> *void #foreign text_libc;
getenv :: (name: *u8) -> *u8 #foreign text_libc;
c_malloc :: (size: u64) -> *void #foreign text_libc "malloc";
c_free :: (p: *void) #foreign text_libc "free";

// ---- FreeType and HarfBuzz (build/fc_vendor; fc_ft_* are vendor/freetype/fc_freetype.c's)

ft_vendor :: #library,no_dll "../../build/fc_vendor";

FT_Library :: *void;
FT_Face :: *void;
FT_Size :: *void;
FT_Vector :: struct { x, y: s64; }
FT_Matrix :: struct { m_xx, m_xy, m_yx, m_yy: s64; } // FT_Fixed 16.16 in a C long
Ft_Bitmap :: struct {
    width, rows, pitch, pixel_mode: s32;
    left, top: s32;
    buffer: *u8;
}

FT_LOAD_NO_HINTING :: 1 << 1;
FT_LOAD_RENDER :: 1 << 2;
FT_LOAD_NO_BITMAP :: 1 << 3;
FT_LOAD_COLOR :: 1 << 20;
FT_FACE_FLAG_SCALABLE :: 1 << 0;
FT_FACE_FLAG_MULTIPLE_MASTERS :: 1 << 8;
FT_FACE_FLAG_COLOR :: 1 << 14;
FT_PIXEL_MODE_MONO :: 1;
FT_PIXEL_MODE_GRAY :: 2;
FT_PIXEL_MODE_BGRA :: 7;

FT_Init_FreeType :: (lib: *FT_Library) -> s32 #foreign ft_vendor;
FT_Done_FreeType :: (lib: FT_Library) -> s32 #foreign ft_vendor;
FT_New_Face :: (lib: FT_Library, path: *u8, index: s64, face: *FT_Face) -> s32 #foreign ft_vendor;
FT_New_Memory_Face :: (lib: FT_Library, data: *u8, size: s64, index: s64, face: *FT_Face) -> s32 #foreign ft_vendor;
FT_Done_Face :: (face: FT_Face) -> s32 #foreign ft_vendor;
FT_New_Size :: (face: FT_Face, size: *FT_Size) -> s32 #foreign ft_vendor;
FT_Activate_Size :: (size: FT_Size) -> s32 #foreign ft_vendor;
FT_Set_Char_Size :: (face: FT_Face, width: s64, height: s64, hres: u32, vres: u32) -> s32 #foreign ft_vendor;
FT_Set_Transform :: (face: FT_Face, matrix: *void, delta: *FT_Vector) #foreign ft_vendor;
FT_Load_Glyph :: (face: FT_Face, glyph: u32, flags: s32) -> s32 #foreign ft_vendor;
FT_Get_Char_Index :: (face: FT_Face, charcode: u64) -> u32 #foreign ft_vendor;
FT_Load_Sfnt_Table :: (face: FT_Face, tag: u64, offset: s64, buffer: *u8, length: *u64) -> s32 #foreign ft_vendor;
fc_ft_glyph_bitmap :: (face: FT_Face, b: *Ft_Bitmap) #foreign ft_vendor;
fc_ft_face_flags :: (face: FT_Face) -> s32 #foreign ft_vendor;
fc_ft_style_flags :: (face: FT_Face) -> s32 #foreign ft_vendor;
fc_ft_select_strike :: (face: FT_Face, px: float32) -> float32 #foreign ft_vendor;
fc_ft_set_axis :: (face: FT_Face, tag: u64, value: float64) #foreign ft_vendor;

hb_variation_t :: struct { tag: u32; value: float32; }
hb_font_extents_t :: struct {
    ascender, descender, line_gap: s32; // descender is negative
    reserved: [9]s32;
}
hb_glyph_info_t :: struct { codepoint, mask, cluster, var1, var2: u32; }
hb_glyph_position_t :: struct {
    x_advance, y_advance, x_offset, y_offset: s32;
    var: u32;
}

hb_blob_create :: (data: *u8, length: u32, mode: s32, user_data: *void, destroy: *void) -> *void #foreign ft_vendor;
hb_face_create_for_tables :: (reference_table: *void, user_data: *void, destroy: *void) -> *void #foreign ft_vendor;
hb_face_destroy :: (face: *void) #foreign ft_vendor;
hb_font_create :: (face: *void) -> *void #foreign ft_vendor;
hb_font_destroy :: (font: *void) #foreign ft_vendor;
hb_font_set_scale :: (font: *void, x: s32, y: s32) #foreign ft_vendor;
hb_font_set_var_named_instance :: (font: *void, index: u32) #foreign ft_vendor;
hb_font_set_variations :: (font: *void, variations: *hb_variation_t, count: u32) #foreign ft_vendor;
hb_font_get_h_extents :: (font: *void, extents: *hb_font_extents_t) -> s32 #foreign ft_vendor;
hb_ot_name_get_utf8 :: (face: *void, name_id: u32, language: *void, size: *u32, text: *u8) -> u32 #foreign ft_vendor;
hb_buffer_create :: () -> *void #foreign ft_vendor;
hb_buffer_destroy :: (buf: *void) #foreign ft_vendor;
hb_buffer_clear_contents :: (buf: *void) #foreign ft_vendor;
hb_buffer_add_utf8 :: (buf: *void, text: *u8, text_length: s32, item_offset: u32, item_length: s32) #foreign ft_vendor;
hb_buffer_set_direction :: (buf: *void, direction: u32) #foreign ft_vendor;
hb_buffer_set_script :: (buf: *void, script: u32) #foreign ft_vendor;
hb_buffer_guess_segment_properties :: (buf: *void) #foreign ft_vendor;
hb_buffer_get_glyph_infos :: (buf: *void, length: *u32) -> *hb_glyph_info_t #foreign ft_vendor;
hb_buffer_get_glyph_positions :: (buf: *void, length: *u32) -> *hb_glyph_position_t #foreign ft_vendor;
hb_shape :: (font: *void, buf: *void, features: *void, num_features: u32) #foreign ft_vendor;
hb_unicode_funcs_get_default :: () -> *void #foreign ft_vendor;
hb_unicode_script :: (ufuncs: *void, cp: u32) -> u32 #foreign ft_vendor;
hb_script_get_horizontal_direction :: (script: u32) -> u32 #foreign ft_vendor;

// Shapes s[start..end) (s is the whole text, for context) in face f; glyphs go to out from pen x, and
// the pen after them is returned. Clusters are byte offsets into s.
shape_run :: (s: string, start: int, end: int, f: *Native_Face, script: u32, size: float32, pen: float32, out: *[..]Raw_Glyph) -> float32 {
    finst := native_font_instance(f, size);
    fi := ft.insts[finst];
    if !fi.hb return pen;
    hb_buffer_clear_contents(ft.buf);
    hb_buffer_add_utf8(ft.buf, s.data, cast(s32) s.count, cast(u32) start, cast(s32) (end - start));
    dir: u32 = HB_DIRECTION_LTR;
    if script {
        hb_buffer_set_script(ft.buf, script);
        if hb_script_get_horizontal_direction(script) == HB_DIRECTION_RTL  dir = HB_DIRECTION_RTL;
    }
    hb_buffer_set_direction(ft.buf, dir);
    hb_buffer_guess_segment_properties(ft.buf); // the language
    hb_shape(fi.hb, ft.buf, null, 0);
    n: u32;
    infos := hb_buffer_get_glyph_infos(ft.buf, *n);
    pos := hb_buffer_get_glyph_positions(ft.buf, null);
    for 0..cast(s64) n - 1 {
        p := pos[it];
        array_add(out, .{font = finst, glyph = infos[it].codepoint, x = pen + cast(float32) p.x_offset / 64, y = cast(float32) -p.y_offset / 64,
            advance = cast(float32) p.x_advance / 64, cluster_start = infos[it].cluster});
        pen += cast(float32) p.x_advance / 64;
    }
    return pen;
}
