package gfx

import "core:testing"
import "fc:platform"

@(private = "file")
setup :: proc(t: ^testing.T) -> bool {
	if !platform.init_headless(200, 100, 2) do return false
	return init()
}

@(private = "file")
px :: proc(pixels: []u8, w, x, y: int) -> [4]u8 {
	i := (y * w + x) * 4
	return {pixels[i], pixels[i + 1], pixels[i + 2], pixels[i + 3]}
}

@(test)
test_render_and_clusters :: proc(t: ^testing.T) {
	testing.expect(t, setup(t), "init")

	begin_frame({0, 0, 0, 1})
	rect({10, 10, 50, 50}, {1, 0, 0, 1})
	push_clip({60, 10, 80, 30})
	rect({60, 10, 120, 60}, {0, 1, 0, 1}) // clipped to 60..80 x 10..30
	pop_clip()
	rect_border({100, 10, 140, 50}, {0, 0, 1, 1}, 1)
	end_frame()
	pixels, w, h := read_pixels(context.temp_allocator)
	testing.expect_value(t, w, 400)
	testing.expect_value(t, h, 200)
	testing.expect_value(t, px(pixels, w, 60, 60), [4]u8{255, 0, 0, 255}) // fill
	testing.expect_value(t, px(pixels, w, 20, 20), [4]u8{255, 0, 0, 255}) // exact pixel edge (10pt*2)
	testing.expect_value(t, px(pixels, w, 19, 19), [4]u8{0, 0, 0, 255}) // crisp: no AA fringe
	testing.expect_value(t, px(pixels, w, 150, 40), [4]u8{0, 255, 0, 255}) // inside clip
	testing.expect_value(t, px(pixels, w, 170, 40), [4]u8{0, 0, 0, 255}) // outside clip
	testing.expect_value(t, px(pixels, w, 200, 40), [4]u8{0, 0, 255, 255}) // 1pt border = 2px at 2x
	testing.expect_value(t, px(pixels, w, 201, 40), [4]u8{0, 0, 255, 255})
	testing.expect_value(t, px(pixels, w, 202, 40), [4]u8{0, 0, 0, 255})

	face := font_system("system")
	testing.expect(t, face != 0, "system font")
	begin_frame({0, 0, 0, 1})

	// combining mark: "e" + U+0301 is one grapheme (bytes 0..3)
	run := shape(face, 16, "éx")
	testing.expect(t, len(run.glyphs) >= 2)
	testing.expect_value(t, run.glyphs[0].cluster_start, 0)
	testing.expect_value(t, run.glyphs[0].cluster_end, 3)
	testing.expect_value(t, run.glyphs[len(run.glyphs) - 1].cluster_start, 3)
	testing.expect_value(t, run_hit_test(run, run.width), 4)

	// ZWJ family is a single cluster; flags are one cluster each
	fam := "👨‍👩‍👧"
	run = shape(face, 16, fam)
	for g in run.glyphs {
		testing.expect_value(t, g.cluster_start, 0)
		testing.expect_value(t, g.cluster_end, len(fam))
	}
	testing.expect(t, len(run.glyphs) > 0 && run.glyphs[0].is_color, "emoji is color")
	run = shape(face, 16, "🇺🇸🇯🇵")
	testing.expect_value(t, len(run.glyphs), 2)
	if len(run.glyphs) == 2 {
		testing.expect_value(t, run.glyphs[1].cluster_start, 8)
		testing.expect_value(t, run_caret_x(run, 8), run.glyphs[1].pos.x)
	}

	// cache hit
	_ = shape(face, 16, "hello")
	hits := text_stats().shape_hits
	_ = shape(face, 16, "hello")
	testing.expect_value(t, text_stats().shape_hits, hits + 1)
	end_frame()
	shutdown()
	platform.shutdown()
}
