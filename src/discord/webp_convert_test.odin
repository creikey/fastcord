package discord

import "core:os"
import "core:testing"
import "fc:etf"
import "fc:imagefmt"

@(private = "file")
read :: proc(path: string) -> []byte {
	d, err := os.read_entire_file(path, context.temp_allocator)
	return err == nil ? d : nil
}

// PNG with an iCCP chunk holding a minimal ICC profile whose 'desc' tag says desc.
@(private = "file")
png_with_icc :: proc(desc: string) -> []byte {
	be :: proc(b: []byte, v: int) {b[0], b[1], b[2], b[3] = u8(v >> 24), u8(v >> 16), u8(v >> 8), u8(v)}
	px := make([]byte, 8 * 8 * 4, context.temp_allocator)
	for i in 0 ..< 64 do px[i * 4], px[i * 4 + 3] = u8(i * 4), 255
	png := imagefmt.encode_png(px, 8, 8, context.temp_allocator)
	tag_off := 144
	tag := make([]byte, 12 + len(desc) + 1, context.temp_allocator)
	copy(tag, "desc")
	be(tag[8:], len(desc) + 1)
	copy(tag[12:], desc)
	icc := make([]byte, tag_off + len(tag), context.temp_allocator)
	be(icc[0:], len(icc))
	be(icc[128:], 1)
	copy(icc[132:], "desc")
	be(icc[136:], tag_off)
	be(icc[140:], len(tag))
	copy(icc[tag_off:], tag)
	z := imagefmt.zlib_compress(icc, context.temp_allocator)
	body := make([dynamic]byte, context.temp_allocator)
	append(&body, ..transmute([]byte)string("ICC Profile\x00\x00"))
	append(&body, ..z)
	// insert after IHDR (8 + 25 bytes)
	out := make([dynamic]byte, context.temp_allocator)
	append(&out, ..png[:33])
	l: [4]byte
	be(l[:], len(body))
	append(&out, ..l[:])
	start := len(out)
	append(&out, ..transmute([]byte)string("iCCP"))
	append(&out, ..body[:])
	crc := crc32_of(out[start:])
	be(l[:], int(crc))
	append(&out, ..l[:])
	append(&out, ..png[33:])
	return out[:]
}

@(private = "file")
crc32_of :: proc(b: []byte) -> u32 {
	c := ~u32(0)
	for x in b {
		c ~= u32(x)
		for _ in 0 ..< 8 do c = (c >> 1) ~ (0xEDB88320 & (0 - (c & 1)))
	}
	return ~c
}

@(test)
webp_conversion_rules :: proc(t: ^testing.T) {
	png := read("tests/scenarios/assets/test.png")
	if !testing.expect(t, png != nil) do return
	// experiment off / file over the variation's limit: not attempted, no science fields
	testing.expect(t, !webp_try_convert(0, "image/png", png).attempted)
	big := make([]byte, 524288 + 1, context.temp_allocator)
	testing.expect(t, !webp_try_convert(1, "image/png", big).attempted)
	testing.expect(t, webp_try_convert(1, "image/png", big[:300000]).attempted)
	testing.expect(t, !webp_try_convert(2, "image/png", big[:300000]).attempted)
	// the capture's file: converted, smaller, pixels intact
	r := webp_try_convert(1, "image/png", png)
	testing.expect(t, r.attempted && r.converted)
	testing.expect_value(t, r.failure, "")
	testing.expect(t, len(r.data) < len(png))
	back, err := imagefmt.decode(r.data, context.temp_allocator)
	src, _ := imagefmt.decode(png, context.temp_allocator)
	testing.expect(t, err == .None && string(back.frames[0].pixels) == string(src.frames[0].pixels))
	// by type
	testing.expect_value(t, webp_try_convert(1, "image/jpeg", png).failure, "unsupported_format")
	testing.expect_value(t, webp_try_convert(1, "text/plain", png).failure, "unsupported_format")
	testing.expect_value(t, webp_try_convert(1, "image/webp", png).failure, "already_webp")
	testing.expect_value(t, webp_try_convert(1, "image/png", read("src/imagefmt/testdata/j_rose.base.jpg")).failure, "corrupted_file")
	// PNG analysis
	testing.expect_value(t, webp_try_convert(1, "image/png", read("src/imagefmt/testdata/p_rose.ga16.png")).failure, "") // gray+alpha, all opaque
	see := make([]byte, 4 * 4 * 4, context.temp_allocator)
	for i in 0 ..< 16 do see[i * 4 + 3] = i == 5 ? 254 : 255
	testing.expect_value(t, webp_try_convert(1, "image/png", imagefmt.encode_png(see, 4, 4, context.temp_allocator)).failure, "has_transparency")
	testing.expect_value(t, webp_try_convert(1, "image/png", read("src/imagefmt/testdata/p_rose.p8.png")).failure, "png8_format")
	testing.expect_value(t, webp_try_convert(1, "image/png", read("src/imagefmt/testdata/apng_hand.png")).failure, "has_transparency") // checked before animation
	opaque := make([]byte, 4 * 4 * 4, context.temp_allocator)
	for i in 0 ..< 16 do opaque[i * 4 + 3] = 255
	testing.expect_value(t, webp_try_convert(1, "image/png", imagefmt.encode_png(opaque, 4, 4, context.temp_allocator)).failure, "") // RGBA but opaque: converts
	// ICC: sRGB profiles convert, others don't
	testing.expect_value(t, webp_try_convert(1, "image/png", png_with_icc("sRGB IEC61966-2.1")).failure, "")
	testing.expect_value(t, webp_try_convert(1, "image/png", png_with_icc("Display P3")).failure, "icc_non_srgb_profile")
	// a PNG that is already tiny: the WebP is not smaller
	g1 := webp_try_convert(1, "image/png", read("src/imagefmt/testdata/p_rose.g1.png"))
	testing.expect(t, g1.converted || g1.failure == "insufficient_savings")
}

@(test)
webp_experiment_from_ready :: proc(t: ^testing.T) {
	c := new(Client)
	defer free(c)
	ready, perr := etf.from_json(`{"apex_experiments":{"assignments":{"1":{"42":{"assignments":[[5,0,0,1],[881712821,2,0,4]]}}}}}`, context.temp_allocator)
	testing.expect_value(t, perr, etf.Error.None)
	note_webp_experiment(c, ready)
	testing.expect_value(t, c.webp_variation, 2)
	testing.expect_value(t, webp_max_bytes(1), 524288)
	testing.expect_value(t, webp_max_bytes(0), 0)
}

@(test)
science_ms_format :: proc(t: ^testing.T) {
	testing.expect_value(t, js_ms(231), "231")
	testing.expect_value(t, js_ms(766.24), "766.2")
	testing.expect_value(t, js_ms(0.04), "0")
	testing.expect_value(t, js_ms(-3), "0")
}
