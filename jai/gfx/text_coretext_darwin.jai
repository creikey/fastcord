#scope_file

CFRef :: *void;
CFIndex :: int;
CFRange :: struct {location, length: CFIndex;}
CGFloat :: float64;
CGPoint :: struct {x, y: CGFloat;}
CGSize :: struct {width, height: CGFloat;}
CGRect :: struct {origin: CGPoint; size: CGSize;}
	CFRelease :: (cf: CFRef) #foreign CoreFoundation;
	CFRetain :: (cf: CFRef) -> CFRef #foreign CoreFoundation;
	CFEqual :: (a: CFRef, b: CFRef) -> bool #foreign CoreFoundation;
	CFDataCreate :: (alloc: CFRef, bytes: *u8, length: CFIndex) -> CFRef #foreign CoreFoundation;
	CFStringCreateWithCharacters :: (alloc: CFRef, chars: *u16, n: CFIndex) -> CFRef #foreign CoreFoundation;
	CFStringCreateWithBytes :: (alloc: CFRef, bytes: *u8, n: CFIndex, encoding: u32, external: bool) -> CFRef #foreign CoreFoundation;
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

kCTFontColorGlyphsTrait :: 1 << 13;
kCGImageAlphaPremultipliedLast : u32 : 1;
kCGImageAlphaNoneSkipLast : u32 : 5;
kCGBitmapByteOrder32Big : u32 : 4 << 12;
#scope_export

// When true, coverage comes from CoreGraphics' font smoothing (stem darkening),
// matching native macOS / Chrome text weight. When false, plain grayscale AA.
FONT_SMOOTHING :: true;
#scope_file

Native_Face :: struct {
	desc: CFRef; // CTFontDescriptor (nil for the system UI font)
	is_system: bool;
	weight: Font_Weight;
}

Font_Inst :: struct {
	font: CFRef; // CTFont at size
	size: float32; // px
	is_color: bool;
}

CT :: struct {
	insts: [..]Font_Inst;
	u16buf: [..]u16;
	map16: [..]int; // utf16 index -> utf8 byte offset (len16+1)
	starts: [..]int;
	rgb: CFRef;
}

ct: CT;
#scope_module

_text_backend_init :: () {
	ct.rgb = CGColorSpaceCreateDeviceRGB();
	append(*ct.insts, Font_Inst.{}); // 0 = none
}

_text_backend_shutdown :: () {
	for f: ct.insts { if f.font != null { CFRelease(f.font); } }
	delete(ct.insts);
	delete(ct.u16buf);
	delete(ct.map16);
	delete(ct.starts);
	if ct.rgb != null { CGColorSpaceRelease(ct.rgb); }
	ct = .{};
}

_font_free :: (native: *void) {
	nf := cast(*Native_Face)(native);
	if nf == null { return; }
	if nf.desc != null { CFRelease(nf.desc); }
	free(nf);
}
#scope_file

cfstr :: (s: string) -> CFRef {
	return CFStringCreateWithBytes(null, raw_data(s), len(s), 0x08000100, false);
}

weight_value :: (w: Font_Weight) -> float64 {
	if w == {
	case .Regular;  return 0;
	case .Medium;   return 0.23;
	case .Semibold; return 0.3;
	case .Bold;     return 0.4;
	}
	return 0;
}
#scope_module

_font_load_memory :: (data: []u8) -> *void {
	cfd := CFDataCreate(null, raw_data(data), len(data));
	if cfd == null { return null; }
	defer CFRelease(cfd);
	desc := CTFontManagerCreateFontDescriptorFromData(cfd);
	if desc == null { return null; }
	nf := new(Native_Face);
	nf.desc = desc;
	return nf;
}

_font_system :: (name: string, weight: Font_Weight, italic: bool) -> *void {
	nf := new(Native_Face);
	nf.weight = weight;
	if name == "" || name == "system" {
		nf.is_system = true;
	} else {
		n := cfstr(name);
		defer CFRelease(n);
		f := CTFontCreateWithName(n, 12, null);
		if f == null {
			free(nf);
			return null;
		}
		nf.desc = CTFontCopyFontDescriptor(f);
		CFRelease(f);
	}
	if weight != .Regular || italic {
		if nf.is_system {
			f := CTFontCreateUIFontForLanguage(2, 12, null);
			nf.desc = CTFontCopyFontDescriptor(f);
			CFRelease(f);
			nf.is_system = false;
		}
	}
	if italic {
		kCTFontItalicTrait :: 1 << 0;
		{ nd := CTFontDescriptorCreateCopyWithSymbolicTraits(nf.desc, kCTFontItalicTrait, kCTFontItalicTrait);
		if nd != null {
			CFRelease(nf.desc);
			nf.desc = nd;
		} }
	}
	if weight != .Regular {
		wv := weight_value(weight);
		num := CFNumberCreate(null, 13, *wv);
		defer CFRelease(num);
		tk := CFRef.[kCTFontWeightTrait];
		tv := CFRef.[num];
		traits := CFDictionaryCreate(null, *tk[0], *tv[0], 1, *kCFTypeDictionaryKeyCallBacks, *kCFTypeDictionaryValueCallBacks);
		defer CFRelease(traits);
		ak := CFRef.[kCTFontTraitsAttribute];
		av := CFRef.[traits];
		attrs := CFDictionaryCreate(null, *ak[0], *av[0], 1, *kCFTypeDictionaryKeyCallBacks, *kCFTypeDictionaryValueCallBacks);
		defer CFRelease(attrs);
		nd := CTFontDescriptorCreateCopyWithAttributes(nf.desc, attrs);
		CFRelease(nf.desc);
		nf.desc = nd;
	}
	return nf;
}
#scope_file

register_font :: (font: CFRef, size: float32) -> u32 {
	for f, i: ct.insts {
		if f.font != null && (f.font == font || CFEqual(f.font, font)) { return cast(u32)(i); }
	}
	CFRetain(font);
	append(*ct.insts, Font_Inst.{font = font, size = size, is_color = CTFontGetSymbolicTraits(font) & kCTFontColorGlyphsTrait != 0});
	return cast(u32)(len(ct.insts) - 1);
}
#scope_module

_font_instance :: (native: *void, size_px: float32) -> u32 {
	nf := cast(*Native_Face)(native);
	font: CFRef;
	if nf.is_system {
		font = CTFontCreateUIFontForLanguage(2, cast(CGFloat)(size_px), null);
	} else {
		font = CTFontCreateWithFontDescriptor(nf.desc, cast(CGFloat)(size_px), null);
	}
	if font == null { return 0; }
	defer CFRelease(font);
	return register_font(font, size_px);
}

_font_metrics :: (inst: u32) -> float32, float32, float32 {
	ascent: float32;
	descent: float32;
	leading: float32;
	f := ct.insts[inst].font;
	if f == null { return ascent, descent, leading; }
	return cast(float32)(CTFontGetAscent(f)), cast(float32)(CTFontGetDescent(f)), cast(float32)(CTFontGetLeading(f));
}

_shape :: (inst: u32, text: string, out: *[..]Raw_Glyph) -> float32 {
	base := ct.insts[inst];
	if base.font == null { return 0; }

	// UTF-8 -> UTF-16 with index map back to bytes.
	clear(*ct.u16buf);
	clear(*ct.map16);
	{ i := 0;
	while i < len(text) {
		r, w := utf8.decode_rune_in_string(sub_from(text, i));
		if r >= 0x10000 {
			rr := r - 0x10000;
			append(*ct.u16buf, cast(u16)(0xD800 + (rr >> 10)), cast(u16)(0xDC00 + (rr & 0x3ff)));
			append(*ct.map16, i, i);
		} else {
			append(*ct.u16buf, cast(u16)(r));
			append(*ct.map16, i);
		}
		i += max(w, 1);
	} }
	append(*ct.map16, len(text));

	str := CFStringCreateWithCharacters(null, raw_data(ct.u16buf), len(ct.u16buf));
	defer CFRelease(str);
	keys := CFRef.[kCTFontAttributeName];
	vals := CFRef.[base.font];
	attrs := CFDictionaryCreate(null, *keys[0], at(*vals, 0), 1, *kCFTypeDictionaryKeyCallBacks, *kCFTypeDictionaryValueCallBacks);
	defer CFRelease(attrs);
	astr := CFAttributedStringCreate(null, str, attrs);
	defer CFRelease(astr);
	line := CTLineCreateWithAttributedString(astr);
	defer CFRelease(line);

	width := cast(float32)(CTLineGetTypographicBounds(line, null, null, null));
	runs := CTLineGetGlyphRuns(line);
	nruns := CFArrayGetCount(runs);
	for ri: 0..nruns-1 {
		run := CFArrayGetValueAtIndex(runs, ri);
		n := CTRunGetGlyphCount(run);
		if n <= 0 { continue; }
		ra := CTRunGetAttributes(run);
		rfont := CFDictionaryGetValue(ra, kCTFontAttributeName);
		finst := ifx rfont != null then register_font(rfont, base.size) else inst;
		glyphs := make_slice(u16, n, temp);
		pos := make_slice(CGPoint, n, temp);
		adv := make_slice(CGSize, n, temp);
		idx := make_slice(CFIndex, n, temp);
		all := CFRange.{0, 0};
		CTRunGetGlyphs(run, all, raw_data(glyphs));
		CTRunGetPositions(run, all, raw_data(pos));
		CTRunGetAdvances(run, all, raw_data(adv));
		CTRunGetStringIndices(run, all, raw_data(idx));
		for k: 0..n-1 {
			// Grapheme-correct cluster start: the composed-character sequence containing this glyph's first code unit.
			cr := CFStringGetRangeOfComposedCharactersAtIndex(str, idx[k]);
			start := ct.map16[clamp(cr.location, 0, len(ct.map16) - 1)];
			append(out, Raw_Glyph.{
				font = finst,
				glyph = cast(u32)(get(glyphs, k)),
				x = cast(float32)(pos[k].x),
				y = -cast(float32)(pos[k].y),
				advance = cast(float32)(adv[k].width),
				cluster_start = start
			});
		}
	}
	// cluster_end = next distinct cluster start (covers ligatures and multi-glyph clusters).
	clear(*ct.starts);
	for r: out.* { append(*ct.starts, r.cluster_start); }
	slice.sort(view(ct.starts));
	for * r: out.* {
		r.cluster_end = len(text);
		i, _ := slice.binary_search(view(ct.starts), r.cluster_start);
		for j: i..len(ct.starts)-1 {
			if ct.starts[j] > r.cluster_start {
				r.cluster_end = ct.starts[j];
				break;
			}
		}
	}
	return width;
}

_rasterize :: (inst: u32, glyph: u32, subpx: float32, allocator: Allocator) -> Glyph_Bitmap {
	fi := ct.insts[inst];
	if fi.font == null { return .{}; }
	gl := cast(u16)(glyph);
	rect: CGRect;
	CTFontGetBoundingRectsForGlyphs(fi.font, 0, *gl, *rect, 1);
	if rect.size.width <= 0 || rect.size.height <= 0 { return .{}; }
	left := cast(s32)(math.floor(rect.origin.x)) - 1;
	right := cast(s32)(math.ceil(rect.origin.x + rect.size.width + cast(float64)(subpx))) + 1;
	bottom := cast(s32)(math.floor(rect.origin.y)) - 1;
	top := cast(s32)(math.ceil(rect.origin.y + rect.size.height)) + 1;
	w, h := right - left, top - bottom;
	if w <= 0 || h <= 0 || w > 1024 || h > 1024 { return .{}; }

	stride := cast(int)(w) * 4;
	buf := make_slice(u8, stride * cast(int)(h), temp);
	info: u32 = ifx fi.is_color then kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big else kCGImageAlphaNoneSkipLast | kCGBitmapByteOrder32Big;
	ctx := CGBitmapContextCreate(raw_data(buf), cast(u64)(w), cast(u64)(h), 8, cast(u64)(stride), ct.rgb, info);
	if ctx == null { return .{}; }
	defer CGContextRelease(ctx);

	CGContextSetAllowsAntialiasing(ctx, true);
	CGContextSetShouldAntialias(ctx, true);
	CGContextSetAllowsFontSubpixelPositioning(ctx, true);
	CGContextSetShouldSubpixelPositionFonts(ctx, true);
	CGContextSetAllowsFontSubpixelQuantization(ctx, false);
	CGContextSetShouldSubpixelQuantizeFonts(ctx, false);
	if !fi.is_color {
		// Black on white, then invert: CG's smoothing is tuned for dark-on-light.
		CGContextSetAllowsFontSmoothing(ctx, cast(bool)(FONT_SMOOTHING));
		CGContextSetShouldSmoothFonts(ctx, cast(bool)(FONT_SMOOTHING));
		CGContextSetRGBFillColor(ctx, 1, 1, 1, 1);
		CGContextFillRect(ctx, .{.{0, 0}, .{cast(CGFloat)(w), cast(CGFloat)(h)}});
		CGContextSetRGBFillColor(ctx, 0, 0, 0, 1);
	}
	p := CGPoint.{cast(CGFloat)(subpx) - cast(CGFloat)(left), -cast(CGFloat)(bottom)};
	CTFontDrawGlyphs(fi.font, *gl, *p, 1, ctx);

	bm := Glyph_Bitmap.{w = w, h = h, left = left, top = -top, is_color = fi.is_color};
	if fi.is_color {
		out := make_slice(u8, cast(int)(w * h) * 4, allocator);
		{ i := 0;
		while i < len(out) {
			a := buf[i + 3];
			if a == 0 { { i += 4; continue; } }
			fa := cast(float32)(a) / 255;
			at(*out, i + 0).* = cast(u8)(min(cast(float32)(buf[i + 0]) / fa + 0.5, 255));
			at(*out, i + 1).* = cast(u8)(min(cast(float32)(buf[i + 1]) / fa + 0.5, 255));
			at(*out, i + 2).* = cast(u8)(min(cast(float32)(buf[i + 2]) / fa + 0.5, 255));
			at(*out, i + 3).* = a;
			i += 4;
} }
		bm.pixels = out;
	} else {
		out := make_slice(u8, cast(int)(w * h), allocator);
		for i: 0..(cast(int)(w * h))-1 {
			// Average RGB (smoothing may produce slight per-channel differences).
			px := sub_from(buf, i * 4);
			sum := cast(int)(px[0]) + cast(int)(px[1]) + cast(int)(px[2]);
			at(*out, i).* = cast(u8)(255 - (sum + 1) / 3);
		}
		bm.pixels = out;
	}
	return bm;
}

_font_name :: (inst: u32, allocator: Allocator) -> string {
	f := ct.insts[inst].font;
	if f == null { return ""; }
	n := CTFontCopyFullName(f);
	if n == null { return ""; }
	defer CFRelease(n);
	buf: [256]u8;
	if !CFStringGetCString(n, *buf[0], buf.count, 0x08000100) { return ""; }
	l := 0;
	while l < len(buf) && buf[l] != 0 { l += 1; }
	return clone_str(as_string(sub(buf, 0, l)), allocator);
}
#scope_export

// The CFDictionary callback tables, shared with other packages so the foreign
// globals are declared once (two declarations break -o:speed links).
cf_type_dictionary_callbacks :: () -> *void, *void {
	keys: *void;
	values: *void;
	return *kCFTypeDictionaryKeyCallBacks, *kCFTypeDictionaryValueCallBacks;
}

