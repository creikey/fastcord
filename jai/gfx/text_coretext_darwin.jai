// When true, coverage comes from CoreGraphics' font smoothing (stem darkening),
// matching native macOS / Chrome text weight. When false, plain grayscale AA.
FONT_SMOOTHING :: true;

// The CFDictionary callback tables, shared with other modules so the foreign
// globals are declared once.
cf_type_dictionary_callbacks :: () -> *void, *void {
    return *kCFTypeDictionaryKeyCallBacks, *kCFTypeDictionaryValueCallBacks;
}

#scope_module

text_backend_init :: () {
    ct.rgb = CGColorSpaceCreateDeviceRGB();
    array_add(*ct.insts, .{}); // 0 = none
}

text_backend_shutdown :: () {
    for ct.insts if it.font  CFRelease(it.font);
    array_free(ct.insts);
    array_free(ct.u16buf);
    array_free(ct.map16);
    array_free(ct.starts);
    if ct.rgb  CGColorSpaceRelease(ct.rgb);
    ct = .{};
}

native_font_free :: (native: *void) {
    nf := cast(*Native_Face) native;
    if nf == null return;
    if nf.desc  CFRelease(nf.desc);
    free(nf);
}

native_font_load_memory :: (data: []u8) -> *void {
    cfd := CFDataCreate(null, data.data, data.count);
    if cfd == null return null;
    defer CFRelease(cfd);
    desc := CTFontManagerCreateFontDescriptorFromData(cfd);
    if desc == null return null;
    nf := New(Native_Face);
    nf.desc = desc;
    return nf;
}

native_font_system :: (name: string, weight: Font_Weight, italic: bool) -> *void {
    nf := New(Native_Face);
    nf.weight = weight;
    if name == "" || name == "system" {
        nf.is_system = true;
    } else {
        n := CFStringCreateWithBytes(null, name.data, name.count, kCFStringEncodingUTF8, false);
        defer CFRelease(n);
        f := CTFontCreateWithName(n, 12, null);
        if f == null {
            free(nf);
            return null;
        }
        nf.desc = CTFontCopyFontDescriptor(f);
        CFRelease(f);
    }
    if (weight != .Regular || italic) && nf.is_system {
        f := CTFontCreateUIFontForLanguage(2, 12, null);
        nf.desc = CTFontCopyFontDescriptor(f);
        CFRelease(f);
        nf.is_system = false;
    }
    if italic {
        kCTFontItalicTrait :: 1 << 0;
        nd := CTFontDescriptorCreateCopyWithSymbolicTraits(nf.desc, kCTFontItalicTrait, kCTFontItalicTrait);
        if nd {
            CFRelease(nf.desc);
            nf.desc = nd;
        }
    }
    if weight != .Regular {
        wv: float64;
        if weight == {
            case .Medium;   wv = 0.23;
            case .Semibold; wv = 0.3;
            case .Bold;     wv = 0.4;
        }
        num := CFNumberCreate(null, 13, *wv); // kCFNumberFloat64Type
        defer CFRelease(num);
        traits := dict(kCTFontWeightTrait, num);
        defer CFRelease(traits);
        attrs := dict(kCTFontTraitsAttribute, traits);
        defer CFRelease(attrs);
        nd := CTFontDescriptorCreateCopyWithAttributes(nf.desc, attrs);
        CFRelease(nf.desc);
        nf.desc = nd;
    }
    return nf;
}

native_font_instance :: (native: *void, size_px: float32) -> u32 {
    nf := cast(*Native_Face) native;
    font := ifx nf.is_system then CTFontCreateUIFontForLanguage(2, size_px, null) else CTFontCreateWithFontDescriptor(nf.desc, size_px, null);
    if font == null return 0;
    defer CFRelease(font);
    return register_font(font, size_px);
}

native_font_metrics :: (inst: u32) -> float32, float32, float32 {
    f := ct.insts[inst].font;
    if f == null return 0, 0, 0;
    return cast(float32) CTFontGetAscent(f), cast(float32) CTFontGetDescent(f), cast(float32) CTFontGetLeading(f);
}

native_shape :: (inst: u32, text: string, out: *[..]Raw_Glyph) -> float32 {
    base := ct.insts[inst];
    if base.font == null return 0;

    // UTF-8 -> UTF-16 with index map back to bytes.
    ct.u16buf.count = 0;
    ct.map16.count = 0;
    i := 0;
    while i < text.count {
        r, w := decode_rune(text, i);
        if r >= 0x10000 {
            rr := r - 0x10000;
            array_add(*ct.u16buf, cast(u16) (0xD800 + (rr >> 10)), cast(u16) (0xDC00 + (rr & 0x3ff)));
            array_add(*ct.map16, i, i);
        } else {
            array_add(*ct.u16buf, cast(u16) r);
            array_add(*ct.map16, i);
        }
        i += w;
    }
    array_add(*ct.map16, text.count);

    str := CFStringCreateWithCharacters(null, ct.u16buf.data, ct.u16buf.count);
    defer CFRelease(str);
    attrs := dict(kCTFontAttributeName, base.font);
    defer CFRelease(attrs);
    astr := CFAttributedStringCreate(null, str, attrs);
    defer CFRelease(astr);
    line := CTLineCreateWithAttributedString(astr);
    defer CFRelease(line);

    width := cast(float32) CTLineGetTypographicBounds(line, null, null, null);
    runs := CTLineGetGlyphRuns(line);
    for ri: 0..CFArrayGetCount(runs)-1 {
        run := CFArrayGetValueAtIndex(runs, ri);
        n := CTRunGetGlyphCount(run);
        if n <= 0 continue;
        rfont := CFDictionaryGetValue(CTRunGetAttributes(run), kCTFontAttributeName);
        finst := ifx rfont then register_font(rfont, base.size) else inst;
        glyphs := NewArray(n, u16,, temp);
        pos := NewArray(n, CGPoint,, temp);
        adv := NewArray(n, CGSize,, temp);
        idx := NewArray(n, CFIndex,, temp);
        all := CFRange.{0, 0};
        CTRunGetGlyphs(run, all, glyphs.data);
        CTRunGetPositions(run, all, pos.data);
        CTRunGetAdvances(run, all, adv.data);
        CTRunGetStringIndices(run, all, idx.data);
        for k: 0..n-1 {
            // Grapheme-correct cluster start: the composed-character sequence containing this glyph's first code unit.
            cr := CFStringGetRangeOfComposedCharactersAtIndex(str, idx[k]);
            array_add(out, .{
                font = finst,
                glyph = glyphs[k],
                x = cast(float32) pos[k].x,
                y = -cast(float32) pos[k].y,
                advance = cast(float32) adv[k].width,
                cluster_start = ct.map16[clamp(cr.location, 0, ct.map16.count - 1)],
            });
        }
    }
    // cluster_end = next distinct cluster start (covers ligatures and multi-glyph clusters).
    ct.starts.count = 0;
    for out.* array_add(*ct.starts, it.cluster_start);
    quick_sort(ct.starts, x => x);
    for * r: out.* {
        lo, hi := 0, ct.starts.count; // first start > r.cluster_start
        while lo < hi {
            mid := (lo + hi) / 2;
            if ct.starts[mid] > r.cluster_start  hi = mid; else lo = mid + 1;
        }
        r.cluster_end = ifx lo < ct.starts.count then ct.starts[lo] else text.count;
    }
    return width;
}

native_rasterize :: (inst: u32, glyph: u32, subpx: float32, allocator: Allocator) -> Glyph_Bitmap {
    fi := ct.insts[inst];
    if fi.font == null return .{};
    gl := cast(u16) glyph;
    rect: CGRect;
    CTFontGetBoundingRectsForGlyphs(fi.font, 0, *gl, *rect, 1);
    if rect.size.width <= 0 || rect.size.height <= 0 return .{};
    left := cast(s32) floor(rect.origin.x) - 1;
    right := cast(s32) ceil(rect.origin.x + rect.size.width + subpx) + 1;
    bottom := cast(s32) floor(rect.origin.y) - 1;
    top := cast(s32) ceil(rect.origin.y + rect.size.height) + 1;
    w, h := right - left, top - bottom;
    if w <= 0 || h <= 0 || w > 1024 || h > 1024 return .{};

    stride := w * 4;
    buf := NewArray(stride * h, u8,, temp);
    info := (ifx fi.is_color then kCGImageAlphaPremultipliedLast else kCGImageAlphaNoneSkipLast) | kCGBitmapByteOrder32Big;
    ctx := CGBitmapContextCreate(buf.data, xx w, xx h, 8, xx stride, ct.rgb, info);
    if ctx == null return .{};
    defer CGContextRelease(ctx);

    CGContextSetAllowsAntialiasing(ctx, true);
    CGContextSetShouldAntialias(ctx, true);
    CGContextSetAllowsFontSubpixelPositioning(ctx, true);
    CGContextSetShouldSubpixelPositionFonts(ctx, true);
    CGContextSetAllowsFontSubpixelQuantization(ctx, false);
    CGContextSetShouldSubpixelQuantizeFonts(ctx, false);
    if !fi.is_color {
        // Black on white, then invert: CG's smoothing is tuned for dark-on-light.
        CGContextSetAllowsFontSmoothing(ctx, FONT_SMOOTHING);
        CGContextSetShouldSmoothFonts(ctx, FONT_SMOOTHING);
        CGContextSetRGBFillColor(ctx, 1, 1, 1, 1);
        CGContextFillRect(ctx, .{.{0, 0}, .{xx w, xx h}});
        CGContextSetRGBFillColor(ctx, 0, 0, 0, 1);
    }
    p := CGPoint.{subpx - cast(CGFloat) left, -cast(CGFloat) bottom};
    CTFontDrawGlyphs(fi.font, *gl, *p, 1, ctx);

    bm := Glyph_Bitmap.{w = w, h = h, left = left, top = -top, is_color = fi.is_color};
    if fi.is_color {
        out := NewArray(w * h * 4, u8,, allocator);
        for 0..w*h-1 {
            i := it * 4;
            a := buf[i + 3];
            if a == 0 continue;
            fa := cast(float32) a / 255;
            for c: 0..2  out[i + c] = cast(u8) min(cast(float32) buf[i + c] / fa + 0.5, 255);
            out[i + 3] = a;
        }
        bm.pixels = out;
    } else {
        out := NewArray(w * h, u8, initialized = false,, allocator);
        for 0..w*h-1 {
            // Average RGB (smoothing may produce slight per-channel differences).
            px := buf.data + it * 4;
            sum := cast(int) px[0] + px[1] + px[2];
            out[it] = cast(u8) (255 - (sum + 1) / 3);
        }
        bm.pixels = out;
    }
    return bm;
}

native_font_name :: (inst: u32, allocator: Allocator) -> string {
    f := ct.insts[inst].font;
    if f == null return "";
    n := CTFontCopyFullName(f);
    if n == null return "";
    defer CFRelease(n);
    buf: [256]u8;
    if !CFStringGetCString(n, buf.data, buf.count, kCFStringEncodingUTF8) return "";
    return copy_string(to_string(buf.data),, allocator);
}

#scope_file

CFRef :: *void;
CFIndex :: int;
CFRange :: struct { location, length: CFIndex; }
CGFloat :: float64;
CGPoint :: struct { x, y: CGFloat; }
CGSize :: struct { width, height: CGFloat; }
CGRect :: struct { origin: CGPoint; size: CGSize; }

kCFStringEncodingUTF8 :u32: 0x08000100;
kCTFontColorGlyphsTrait :: 1 << 13;
kCGImageAlphaPremultipliedLast :u32: 1;
kCGImageAlphaNoneSkipLast :u32: 5;
kCGBitmapByteOrder32Big :u32: 4 << 12;

CFRelease :: (cf: CFRef) #foreign CoreFoundation;
CFRetain :: (cf: CFRef) -> CFRef #foreign CoreFoundation;
CFEqual :: (a: CFRef, b: CFRef) -> bool #foreign CoreFoundation;
CFDataCreate :: (alloc: CFRef, bytes: *u8, length: CFIndex) -> CFRef #foreign CoreFoundation;
CFStringCreateWithCharacters :: (alloc: CFRef, chars: *u16, n: CFIndex) -> CFRef #foreign CoreFoundation;
CFStringCreateWithBytes :: (alloc: CFRef, bytes: *u8, n: CFIndex, encoding: u32, external: bool) -> CFRef #foreign CoreFoundation;
CFStringGetCString :: (s: CFRef, buf: *u8, n: CFIndex, encoding: u32) -> bool #foreign CoreFoundation;
CFStringGetRangeOfComposedCharactersAtIndex :: (str: CFRef, idx: CFIndex) -> CFRange #foreign CoreFoundation;
CFAttributedStringCreate :: (alloc: CFRef, str: CFRef, attrs: CFRef) -> CFRef #foreign CoreFoundation;
CFDictionaryCreate :: (alloc: CFRef, keys: *CFRef, values: *CFRef, n: CFIndex, kcb: *void, vcb: *void) -> CFRef #foreign CoreFoundation;
CFDictionaryGetValue :: (dict: CFRef, key: CFRef) -> CFRef #foreign CoreFoundation;
CFArrayGetCount :: (arr: CFRef) -> CFIndex #foreign CoreFoundation;
CFArrayGetValueAtIndex :: (arr: CFRef, i: CFIndex) -> CFRef #foreign CoreFoundation;
CFNumberCreate :: (alloc: CFRef, type: CFIndex, value: *void) -> CFRef #foreign CoreFoundation;
kCFTypeDictionaryKeyCallBacks: [6]u64 #elsewhere CoreFoundation;
kCFTypeDictionaryValueCallBacks: [6]u64 #elsewhere CoreFoundation;

CTFontManagerCreateFontDescriptorFromData :: (data: CFRef) -> CFRef #foreign CoreText;
CTFontCreateWithFontDescriptor :: (desc: CFRef, size: CGFloat, mtx: *void) -> CFRef #foreign CoreText;
CTFontCreateWithName :: (name: CFRef, size: CGFloat, mtx: *void) -> CFRef #foreign CoreText;
CTFontCreateUIFontForLanguage :: (type: u32, size: CGFloat, lang: CFRef) -> CFRef #foreign CoreText;
CTFontCopyFontDescriptor :: (font: CFRef) -> CFRef #foreign CoreText;
CTFontCopyFullName :: (font: CFRef) -> CFRef #foreign CoreText;
CTFontDescriptorCreateCopyWithAttributes :: (desc: CFRef, attrs: CFRef) -> CFRef #foreign CoreText;
CTFontDescriptorCreateCopyWithSymbolicTraits :: (desc: CFRef, value: u32, mask: u32) -> CFRef #foreign CoreText;
CTFontGetAscent :: (font: CFRef) -> CGFloat #foreign CoreText;
CTFontGetDescent :: (font: CFRef) -> CGFloat #foreign CoreText;
CTFontGetLeading :: (font: CFRef) -> CGFloat #foreign CoreText;
CTFontGetSymbolicTraits :: (font: CFRef) -> u32 #foreign CoreText;
CTFontGetBoundingRectsForGlyphs :: (font: CFRef, orientation: u32, glyphs: *u16, rects: *CGRect, count: CFIndex) -> CGRect #foreign CoreText;
CTFontDrawGlyphs :: (font: CFRef, glyphs: *u16, positions: *CGPoint, count: u64, ctx: CFRef) #foreign CoreText;
CTLineCreateWithAttributedString :: (astr: CFRef) -> CFRef #foreign CoreText;
CTLineGetGlyphRuns :: (line: CFRef) -> CFRef #foreign CoreText;
CTLineGetTypographicBounds :: (line: CFRef, ascent: *CGFloat, descent: *CGFloat, leading: *CGFloat) -> float64 #foreign CoreText;
CTRunGetGlyphCount :: (run: CFRef) -> CFIndex #foreign CoreText;
CTRunGetGlyphs :: (run: CFRef, r: CFRange, buf: *u16) #foreign CoreText;
CTRunGetPositions :: (run: CFRef, r: CFRange, buf: *CGPoint) #foreign CoreText;
CTRunGetAdvances :: (run: CFRef, r: CFRange, buf: *CGSize) #foreign CoreText;
CTRunGetStringIndices :: (run: CFRef, r: CFRange, buf: *CFIndex) #foreign CoreText;
CTRunGetAttributes :: (run: CFRef) -> CFRef #foreign CoreText;
kCTFontAttributeName: CFRef #elsewhere CoreText;
kCTFontTraitsAttribute: CFRef #elsewhere CoreText;
kCTFontWeightTrait: CFRef #elsewhere CoreText;

CGColorSpaceCreateDeviceRGB :: () -> CFRef #foreign CoreGraphics;
CGColorSpaceRelease :: (cs: CFRef) #foreign CoreGraphics;
CGBitmapContextCreate :: (data: *void, w: u64, h: u64, bpc: u64, bpr: u64, cs: CFRef, info: u32) -> CFRef #foreign CoreGraphics;
CGContextRelease :: (ctx: CFRef) #foreign CoreGraphics;
CGContextSetRGBFillColor :: (ctx: CFRef, r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) #foreign CoreGraphics;
CGContextFillRect :: (ctx: CFRef, r: CGRect) #foreign CoreGraphics;
CGContextSetShouldAntialias :: (ctx: CFRef, v: bool) #foreign CoreGraphics;
CGContextSetAllowsAntialiasing :: (ctx: CFRef, v: bool) #foreign CoreGraphics;
CGContextSetShouldSmoothFonts :: (ctx: CFRef, v: bool) #foreign CoreGraphics;
CGContextSetAllowsFontSmoothing :: (ctx: CFRef, v: bool) #foreign CoreGraphics;
CGContextSetShouldSubpixelPositionFonts :: (ctx: CFRef, v: bool) #foreign CoreGraphics;
CGContextSetAllowsFontSubpixelPositioning :: (ctx: CFRef, v: bool) #foreign CoreGraphics;
CGContextSetShouldSubpixelQuantizeFonts :: (ctx: CFRef, v: bool) #foreign CoreGraphics;
CGContextSetAllowsFontSubpixelQuantization :: (ctx: CFRef, v: bool) #foreign CoreGraphics;

Native_Face :: struct {
    desc: CFRef; // CTFontDescriptor (null for the system UI font)
    is_system: bool;
    weight: Font_Weight;
}

Font_Inst :: struct {
    font: CFRef;   // CTFont at size
    size: float32; // px
    is_color: bool;
}

ct: struct {
    insts: [..]Font_Inst;
    u16buf: [..]u16;
    map16: [..]int; // utf16 index -> utf8 byte offset (len16+1)
    starts: [..]int;
    rgb: CFRef;
};

// One-entry CFDictionary with CFType callbacks.
dict :: (key: CFRef, value: CFRef) -> CFRef {
    k, v := key, value;
    return CFDictionaryCreate(null, *k, *v, 1, *kCFTypeDictionaryKeyCallBacks, *kCFTypeDictionaryValueCallBacks);
}

register_font :: (font: CFRef, size: float32) -> u32 {
    for ct.insts if it.font && (it.font == font || CFEqual(it.font, font)) return cast(u32) it_index;
    CFRetain(font);
    array_add(*ct.insts, .{font = font, size = size, is_color = (CTFontGetSymbolicTraits(font) & kCTFontColorGlyphsTrait) != 0});
    return cast(u32) (ct.insts.count - 1);
}
