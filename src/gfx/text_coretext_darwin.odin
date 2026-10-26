#+build darwin
package gfx

import "base:runtime"
import "core:math"
import "core:slice"
import "core:unicode/utf8"
import CF "core:sys/darwin/CoreFoundation"

@(private = "file")
CFRef :: rawptr
@(private = "file")
CFIndex :: int
@(private = "file")
CFRange :: struct {location, length: CFIndex}
@(private = "file")
CGFloat :: f64
@(private = "file")
CGPoint :: struct {x, y: CGFloat}
@(private = "file")
CGSize :: struct {width, height: CGFloat}
@(private = "file")
CGRect :: struct {origin: CGPoint, size: CGSize}

foreign import CoreFoundation "system:CoreFoundation.framework"
foreign import CoreText "system:CoreText.framework"
foreign import CoreGraphics "system:CoreGraphics.framework"

@(private = "file", default_calling_convention = "c")
foreign CoreFoundation {
	CFRelease :: proc(cf: CFRef) ---
	CFRetain :: proc(cf: CFRef) -> CFRef ---
	CFEqual :: proc(a, b: CFRef) -> b8 ---
	CFDataCreate :: proc(alloc: CFRef, bytes: [^]u8, length: CFIndex) -> CFRef ---
	CFStringCreateWithCharacters :: proc(alloc: CFRef, chars: [^]u16, n: CFIndex) -> CFRef ---
	CFStringCreateWithBytes :: proc(alloc: CFRef, bytes: [^]u8, n: CFIndex, encoding: u32, external: b8) -> CFRef ---
	CFStringGetRangeOfComposedCharactersAtIndex :: proc(str: CFRef, idx: CFIndex) -> CFRange ---
	CFAttributedStringCreate :: proc(alloc: CFRef, str: CFRef, attrs: CFRef) -> CFRef ---
	CFDictionaryCreate :: proc(alloc: CFRef, keys: [^]CFRef, values: [^]CFRef, n: CFIndex, kcb: rawptr, vcb: rawptr) -> CFRef ---
	CFDictionaryGetValue :: proc(dict: CFRef, key: CFRef) -> CFRef ---
	CFArrayGetCount :: proc(arr: CFRef) -> CFIndex ---
	CFArrayGetValueAtIndex :: proc(arr: CFRef, i: CFIndex) -> CFRef ---
	CFNumberCreate :: proc(alloc: CFRef, type: CFIndex, value: rawptr) -> CFRef ---

	kCFTypeDictionaryKeyCallBacks: [6]uintptr
	kCFTypeDictionaryValueCallBacks: [6]uintptr
}

@(private = "file", default_calling_convention = "c")
foreign CoreText {
	CTFontManagerCreateFontDescriptorFromData :: proc(data: CFRef) -> CFRef ---
	CTFontCreateWithFontDescriptor :: proc(desc: CFRef, size: CGFloat, mtx: rawptr) -> CFRef ---
	CTFontCreateWithName :: proc(name: CFRef, size: CGFloat, mtx: rawptr) -> CFRef ---
	CTFontCreateUIFontForLanguage :: proc(type: u32, size: CGFloat, lang: CFRef) -> CFRef ---
	CTFontCopyFontDescriptor :: proc(font: CFRef) -> CFRef ---
	CTFontCopyFullName :: proc(font: CFRef) -> CFRef ---
	CTFontDescriptorCreateCopyWithAttributes :: proc(desc: CFRef, attrs: CFRef) -> CFRef ---
	CTFontGetAscent :: proc(font: CFRef) -> CGFloat ---
	CTFontGetDescent :: proc(font: CFRef) -> CGFloat ---
	CTFontGetLeading :: proc(font: CFRef) -> CGFloat ---
	CTFontGetSymbolicTraits :: proc(font: CFRef) -> u32 ---
	CTFontGetBoundingRectsForGlyphs :: proc(font: CFRef, orientation: u32, glyphs: [^]u16, rects: [^]CGRect, count: CFIndex) -> CGRect ---
	CTFontDrawGlyphs :: proc(font: CFRef, glyphs: [^]u16, positions: [^]CGPoint, count: uint, ctx: CFRef) ---
	CTLineCreateWithAttributedString :: proc(astr: CFRef) -> CFRef ---
	CTLineGetGlyphRuns :: proc(line: CFRef) -> CFRef ---
	CTLineGetTypographicBounds :: proc(line: CFRef, ascent, descent, leading: ^CGFloat) -> f64 ---
	CTRunGetGlyphCount :: proc(run: CFRef) -> CFIndex ---
	CTRunGetGlyphs :: proc(run: CFRef, r: CFRange, buf: [^]u16) ---
	CTRunGetPositions :: proc(run: CFRef, r: CFRange, buf: [^]CGPoint) ---
	CTRunGetAdvances :: proc(run: CFRef, r: CFRange, buf: [^]CGSize) ---
	CTRunGetStringIndices :: proc(run: CFRef, r: CFRange, buf: [^]CFIndex) ---
	CTRunGetAttributes :: proc(run: CFRef) -> CFRef ---

	kCTFontAttributeName: CFRef
	kCTFontTraitsAttribute: CFRef
	kCTFontWeightTrait: CFRef
}

@(private = "file", default_calling_convention = "c")
foreign CoreGraphics {
	CGColorSpaceCreateDeviceRGB :: proc() -> CFRef ---
	CGColorSpaceRelease :: proc(cs: CFRef) ---
	CGBitmapContextCreate :: proc(data: rawptr, w, h: uint, bpc: uint, bpr: uint, cs: CFRef, info: u32) -> CFRef ---
	CGContextRelease :: proc(ctx: CFRef) ---
	CGContextSetRGBFillColor :: proc(ctx: CFRef, r, g, b, a: CGFloat) ---
	CGContextFillRect :: proc(ctx: CFRef, r: CGRect) ---
	CGContextSetShouldAntialias :: proc(ctx: CFRef, v: b8) ---
	CGContextSetAllowsAntialiasing :: proc(ctx: CFRef, v: b8) ---
	CGContextSetShouldSmoothFonts :: proc(ctx: CFRef, v: b8) ---
	CGContextSetAllowsFontSmoothing :: proc(ctx: CFRef, v: b8) ---
	CGContextSetShouldSubpixelPositionFonts :: proc(ctx: CFRef, v: b8) ---
	CGContextSetAllowsFontSubpixelPositioning :: proc(ctx: CFRef, v: b8) ---
	CGContextSetShouldSubpixelQuantizeFonts :: proc(ctx: CFRef, v: b8) ---
	CGContextSetAllowsFontSubpixelQuantization :: proc(ctx: CFRef, v: b8) ---
}

@(private = "file")
kCTFontColorGlyphsTrait :: 1 << 13
@(private = "file")
kCGImageAlphaPremultipliedLast :: 1
@(private = "file")
kCGImageAlphaNoneSkipLast :: 5
@(private = "file")
kCGBitmapByteOrder32Big :: 4 << 12

// When true, coverage comes from CoreGraphics' font smoothing (stem darkening),
// matching native macOS / Chrome text weight. When false, plain grayscale AA.
FONT_SMOOTHING :: #config(FC_FONT_SMOOTHING, true)

@(private = "file")
Native_Face :: struct {
	desc:      CFRef, // CTFontDescriptor (nil for the system UI font)
	is_system: bool,
	weight:    Font_Weight,
}

@(private = "file")
Font_Inst :: struct {
	font:     CFRef, // CTFont at size
	size:     f32, // px
	is_color: bool,
}

@(private = "file")
CT :: struct {
	insts:    [dynamic]Font_Inst,
	u16buf:   [dynamic]u16,
	map16:    [dynamic]int, // utf16 index -> utf8 byte offset (len16+1)
	starts:   [dynamic]int,
	rgb:      CFRef,
}

@(private = "file")
ct: CT

@(private)
_text_backend_init :: proc() {
	ct.rgb = CGColorSpaceCreateDeviceRGB()
	append(&ct.insts, Font_Inst{}) // 0 = none
}

@(private)
_text_backend_shutdown :: proc() {
	for f in ct.insts do if f.font != nil do CFRelease(f.font)
	delete(ct.insts)
	delete(ct.u16buf)
	delete(ct.map16)
	delete(ct.starts)
	if ct.rgb != nil do CGColorSpaceRelease(ct.rgb)
	ct = {}
}

@(private)
_font_free :: proc(native: rawptr) {
	nf := (^Native_Face)(native)
	if nf == nil do return
	if nf.desc != nil do CFRelease(nf.desc)
	free(nf)
}

@(private = "file")
cfstr :: proc(s: string) -> CFRef {
	return CFStringCreateWithBytes(nil, raw_data(s), len(s), 0x08000100 /*UTF8*/, false)
}

@(private = "file")
weight_value :: proc(w: Font_Weight) -> f64 {
	switch w {
	case .Regular:  return 0
	case .Medium:   return 0.23
	case .Semibold: return 0.3
	case .Bold:     return 0.4
	}
	return 0
}

@(private)
_font_load_memory :: proc(data: []byte) -> rawptr {
	cfd := CFDataCreate(nil, raw_data(data), len(data))
	if cfd == nil do return nil
	defer CFRelease(cfd)
	desc := CTFontManagerCreateFontDescriptorFromData(cfd)
	if desc == nil do return nil
	nf := new(Native_Face)
	nf.desc = desc
	return nf
}

@(private)
_font_system :: proc(name: string, weight: Font_Weight) -> rawptr {
	nf := new(Native_Face)
	nf.weight = weight
	if name == "" || name == "system" {
		nf.is_system = true
	} else {
		n := cfstr(name)
		defer CFRelease(n)
		f := CTFontCreateWithName(n, 12, nil)
		if f == nil {
			free(nf)
			return nil
		}
		nf.desc = CTFontCopyFontDescriptor(f)
		CFRelease(f)
	}
	if weight != .Regular {
		if nf.is_system {
			f := CTFontCreateUIFontForLanguage(2 /*kCTFontUIFontSystem*/, 12, nil)
			nf.desc = CTFontCopyFontDescriptor(f)
			CFRelease(f)
			nf.is_system = false
		}
		wv := weight_value(weight)
		num := CFNumberCreate(nil, 13 /*kCFNumberDoubleType*/, &wv)
		defer CFRelease(num)
		tk := [1]CFRef{kCTFontWeightTrait}
		tv := [1]CFRef{num}
		traits := CFDictionaryCreate(nil, &tk[0], &tv[0], 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks)
		defer CFRelease(traits)
		ak := [1]CFRef{kCTFontTraitsAttribute}
		av := [1]CFRef{traits}
		attrs := CFDictionaryCreate(nil, &ak[0], &av[0], 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks)
		defer CFRelease(attrs)
		nd := CTFontDescriptorCreateCopyWithAttributes(nf.desc, attrs)
		CFRelease(nf.desc)
		nf.desc = nd
	}
	return nf
}

@(private = "file")
register_font :: proc(font: CFRef, size: f32) -> u32 {
	for f, i in ct.insts {
		if f.font != nil && (f.font == font || CFEqual(f.font, font)) do return u32(i)
	}
	CFRetain(font)
	append(&ct.insts, Font_Inst{font = font, size = size, is_color = CTFontGetSymbolicTraits(font) & kCTFontColorGlyphsTrait != 0})
	return u32(len(ct.insts) - 1)
}

@(private)
_font_instance :: proc(native: rawptr, size_px: f32) -> u32 {
	nf := (^Native_Face)(native)
	font: CFRef
	if nf.is_system {
		font = CTFontCreateUIFontForLanguage(2 /*kCTFontUIFontSystem*/, CGFloat(size_px), nil)
	} else {
		font = CTFontCreateWithFontDescriptor(nf.desc, CGFloat(size_px), nil)
	}
	if font == nil do return 0
	defer CFRelease(font)
	return register_font(font, size_px)
}

@(private)
_font_metrics :: proc(inst: u32) -> (ascent, descent, leading: f32) {
	f := ct.insts[inst].font
	if f == nil do return
	return f32(CTFontGetAscent(f)), f32(CTFontGetDescent(f)), f32(CTFontGetLeading(f))
}

@(private)
_shape :: proc(inst: u32, text: string, out: ^[dynamic]Raw_Glyph) -> f32 {
	base := ct.insts[inst]
	if base.font == nil do return 0

	// UTF-8 -> UTF-16 with index map back to bytes.
	clear(&ct.u16buf)
	clear(&ct.map16)
	for i := 0; i < len(text); {
		r, w := utf8.decode_rune_in_string(text[i:])
		if r >= 0x10000 {
			rr := r - 0x10000
			append(&ct.u16buf, u16(0xD800 + (rr >> 10)), u16(0xDC00 + (rr & 0x3ff)))
			append(&ct.map16, i, i)
		} else {
			append(&ct.u16buf, u16(r))
			append(&ct.map16, i)
		}
		i += max(w, 1)
	}
	append(&ct.map16, len(text))

	str := CFStringCreateWithCharacters(nil, raw_data(ct.u16buf), len(ct.u16buf))
	defer CFRelease(str)
	keys := [1]CFRef{kCTFontAttributeName}
	vals := [1]CFRef{base.font}
	attrs := CFDictionaryCreate(nil, &keys[0], &vals[0], 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks)
	defer CFRelease(attrs)
	astr := CFAttributedStringCreate(nil, str, attrs)
	defer CFRelease(astr)
	line := CTLineCreateWithAttributedString(astr)
	defer CFRelease(line)

	width := f32(CTLineGetTypographicBounds(line, nil, nil, nil))
	runs := CTLineGetGlyphRuns(line)
	nruns := CFArrayGetCount(runs)
	for ri in 0 ..< nruns {
		run := CFArrayGetValueAtIndex(runs, ri)
		n := CTRunGetGlyphCount(run)
		if n <= 0 do continue
		ra := CTRunGetAttributes(run)
		rfont := CFDictionaryGetValue(ra, kCTFontAttributeName)
		finst := rfont != nil ? register_font(rfont, base.size) : inst
		glyphs := make([]u16, n, context.temp_allocator)
		pos := make([]CGPoint, n, context.temp_allocator)
		adv := make([]CGSize, n, context.temp_allocator)
		idx := make([]CFIndex, n, context.temp_allocator)
		all := CFRange{0, 0}
		CTRunGetGlyphs(run, all, raw_data(glyphs))
		CTRunGetPositions(run, all, raw_data(pos))
		CTRunGetAdvances(run, all, raw_data(adv))
		CTRunGetStringIndices(run, all, raw_data(idx))
		for k in 0 ..< n {
			// Grapheme-correct cluster start: the composed-character sequence containing this glyph's first code unit.
			cr := CFStringGetRangeOfComposedCharactersAtIndex(str, idx[k])
			start := ct.map16[clamp(cr.location, 0, len(ct.map16) - 1)]
			append(out, Raw_Glyph{
				font = finst,
				glyph = u32(glyphs[k]),
				x = f32(pos[k].x),
				y = -f32(pos[k].y),
				advance = f32(adv[k].width),
				cluster_start = start,
			})
		}
	}
	// cluster_end = next distinct cluster start (covers ligatures and multi-glyph clusters).
	clear(&ct.starts)
	for r in out do append(&ct.starts, r.cluster_start)
	slice.sort(ct.starts[:])
	for &r in out {
		r.cluster_end = len(text)
		i, _ := slice.binary_search(ct.starts[:], r.cluster_start)
		for j := i; j < len(ct.starts); j += 1 {
			if ct.starts[j] > r.cluster_start {
				r.cluster_end = ct.starts[j]
				break
			}
		}
	}
	return width
}

@(private)
_rasterize :: proc(inst: u32, glyph: u32, subpx: f32, allocator: runtime.Allocator) -> Glyph_Bitmap {
	fi := ct.insts[inst]
	if fi.font == nil do return {}
	gl := u16(glyph)
	rect: CGRect
	CTFontGetBoundingRectsForGlyphs(fi.font, 0, &gl, &rect, 1)
	if rect.size.width <= 0 || rect.size.height <= 0 do return {}
	left := i32(math.floor(rect.origin.x)) - 1
	right := i32(math.ceil(rect.origin.x + rect.size.width + f64(subpx))) + 1
	bottom := i32(math.floor(rect.origin.y)) - 1
	top := i32(math.ceil(rect.origin.y + rect.size.height)) + 1
	w, h := right - left, top - bottom
	if w <= 0 || h <= 0 || w > 1024 || h > 1024 do return {}

	stride := int(w) * 4
	buf := make([]u8, stride * int(h), context.temp_allocator)
	info: u32 = fi.is_color ? kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big : kCGImageAlphaNoneSkipLast | kCGBitmapByteOrder32Big
	ctx := CGBitmapContextCreate(raw_data(buf), uint(w), uint(h), 8, uint(stride), ct.rgb, info)
	if ctx == nil do return {}
	defer CGContextRelease(ctx)

	CGContextSetAllowsAntialiasing(ctx, true)
	CGContextSetShouldAntialias(ctx, true)
	CGContextSetAllowsFontSubpixelPositioning(ctx, true)
	CGContextSetShouldSubpixelPositionFonts(ctx, true)
	CGContextSetAllowsFontSubpixelQuantization(ctx, false)
	CGContextSetShouldSubpixelQuantizeFonts(ctx, false)
	if !fi.is_color {
		// Black on white, then invert: CG's smoothing is tuned for dark-on-light.
		CGContextSetAllowsFontSmoothing(ctx, b8(FONT_SMOOTHING))
		CGContextSetShouldSmoothFonts(ctx, b8(FONT_SMOOTHING))
		CGContextSetRGBFillColor(ctx, 1, 1, 1, 1)
		CGContextFillRect(ctx, {{0, 0}, {CGFloat(w), CGFloat(h)}})
		CGContextSetRGBFillColor(ctx, 0, 0, 0, 1)
	}
	p := CGPoint{CGFloat(subpx) - CGFloat(left), -CGFloat(bottom)}
	CTFontDrawGlyphs(fi.font, &gl, &p, 1, ctx)

	bm := Glyph_Bitmap{w = w, h = h, left = left, top = -top, is_color = fi.is_color}
	if fi.is_color {
		out := make([]u8, int(w * h) * 4, allocator)
		for i := 0; i < len(out); i += 4 {
			a := buf[i + 3]
			if a == 0 do continue
			fa := f32(a) / 255
			out[i + 0] = u8(min(f32(buf[i + 0]) / fa + 0.5, 255))
			out[i + 1] = u8(min(f32(buf[i + 1]) / fa + 0.5, 255))
			out[i + 2] = u8(min(f32(buf[i + 2]) / fa + 0.5, 255))
			out[i + 3] = a
		}
		bm.pixels = out
	} else {
		out := make([]u8, int(w * h), allocator)
		for i in 0 ..< int(w * h) {
			// Average RGB (smoothing may produce slight per-channel differences).
			px := buf[i * 4:]
			sum := int(px[0]) + int(px[1]) + int(px[2])
			out[i] = u8(255 - (sum + 1) / 3)
		}
		bm.pixels = out
	}
	return bm
}

@(private)
_font_name :: proc(inst: u32, allocator: runtime.Allocator) -> string {
	f := ct.insts[inst].font
	if f == nil do return ""
	n := CTFontCopyFullName(f)
	if n == nil do return ""
	defer CFRelease(n)
	buf: [256]u8
	if !CF.StringGetCString(CF.String(n), &buf[0], len(buf), CF.StringEncoding(0x08000100)) do return ""
	l := 0
	for l < len(buf) && buf[l] != 0 do l += 1
	return clone_str(string(buf[:l]), allocator)
}

// The CFDictionary callback tables, shared with other packages so the foreign
// globals are declared once (two declarations break -o:speed links).
cf_type_dictionary_callbacks :: proc() -> (keys, values: rawptr) {
	return &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks
}
