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
	// byte for byte what Chrome's canvas.toBlob("image/webp", 1) made of it (758 bytes, as in the capture)
	testing.expect(t, string(r.data) == string(read("src/discord/testdata/test.chrome.webp")))
	// by type
	testing.expect_value(t, webp_try_convert(1, "image/jpeg", png).failure, "unsupported_format")
	testing.expect_value(t, webp_try_convert(1, "text/plain", png).failure, "unsupported_format")
	testing.expect_value(t, webp_try_convert(1, "image/webp", png).failure, "already_webp")
	testing.expect_value(t, webp_try_convert(1, "image/png", read("src/imagefmt/testdata/j_rose.base.jpg")).failure, "corrupted_file")
	// PNG analysis
	testing.expect_value(t, webp_try_convert(1, "image/png", read("src/imagefmt/testdata/p_rose.ga16.png")).failure, "") // gray+alpha, all opaque
	// testdata PNGs: 4x4 RGBA, one pixel at alpha 254 / all opaque; 8x8 with an iCCP 'desc'
	testing.expect_value(t, webp_try_convert(1, "image/png", read("src/discord/testdata/alpha254.png")).failure, "has_transparency")
	testing.expect_value(t, webp_try_convert(1, "image/png", read("src/imagefmt/testdata/p_rose.p8.png")).failure, "png8_format")
	testing.expect_value(t, webp_try_convert(1, "image/png", read("src/imagefmt/testdata/apng_hand.png")).failure, "has_transparency") // checked before animation
	testing.expect_value(t, webp_try_convert(1, "image/png", read("src/discord/testdata/opaque_rgba.png")).failure, "insufficient_savings") // RGBA but opaque: passes every check; tiny, so the WebP (with its 456-byte ICC) is larger
	// ICC: sRGB profiles pass (and get to the size check), others don't
	testing.expect_value(t, webp_try_convert(1, "image/png", read("src/discord/testdata/icc_srgb.png")).failure, "insufficient_savings")
	testing.expect_value(t, webp_try_convert(1, "image/png", read("src/discord/testdata/icc_p3.png")).failure, "icc_non_srgb_profile")
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
