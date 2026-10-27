package app

import "core:testing"
import "fc:imagefmt"
import "fc:platform"

@(test)
upload_limits :: proc(t: ^testing.T) {
	testing.expect_value(t, upload_limit(0, 0), i64(10 * MB))
	testing.expect_value(t, upload_limit(3, 0), i64(50 * MB)) // Nitro Basic
	testing.expect_value(t, upload_limit(1, 0), i64(50 * MB)) // Nitro Classic
	testing.expect_value(t, upload_limit(2, 0), i64(500 * MB)) // Nitro
	testing.expect_value(t, upload_limit(0, 1), i64(10 * MB))
	testing.expect_value(t, upload_limit(0, 2), i64(50 * MB)) // boost level 2
	testing.expect_value(t, upload_limit(0, 3), i64(100 * MB))
	testing.expect_value(t, upload_limit(2, 3), i64(500 * MB))
	testing.expect_value(t, limit_text(10 * MB), "Max file size is 10 MB please.")
	testing.expect_value(t, limit_text(10000), "Max file size is 0.01 MB please.")
	testing.expect(t, !too_many_files(0, 10))
	testing.expect(t, too_many_files(0, 11))
	testing.expect(t, too_many_files(9, 2))
	testing.expect(t, !too_many_files(9, 1))
}

@(test)
attachment_naming :: proc(t: ^testing.T) {
	testing.expect_value(t, clean_filename("  fc_renamed.png ", "x.png"), "fc_renamed.png")
	testing.expect_value(t, clean_filename("a/b\\c.png", "x.png"), "a_b_c.png")
	testing.expect_value(t, clean_filename("   ", "x.png"), "x.png")
	testing.expect_value(t, att_kind_of(mime_for("IMG.PNG")), Att_Kind.Image)
	testing.expect_value(t, att_kind_of(mime_for("clip.mp4")), Att_Kind.Video)
	testing.expect_value(t, att_kind_of(mime_for("notes.txt")), Att_Kind.Other)
	testing.expect_value(t, file_icon_for("song.MP3"), "music")
	testing.expect_value(t, file_icon_for("main.odin"), "angle-brackets")
	testing.expect_value(t, file_icon_for("archive.zip"), "file")
}

@(test)
attachment_thumbnails :: proc(t: ^testing.T) {
	// 4x2 -> fits 2: 2x1, each output pixel the mean of a 2x2 block
	px := []byte{
		0, 0, 0, 255, 100, 100, 100, 255, 10, 10, 10, 255, 10, 10, 10, 255,
		100, 100, 100, 255, 0, 0, 0, 255, 10, 10, 10, 255, 10, 10, 10, 255,
	}
	out, w, h := downscale(px, 4, 2, 2, context.temp_allocator)
	testing.expect_value(t, w, 2)
	testing.expect_value(t, h, 1)
	testing.expect_value(t, out[0], 50)
	testing.expect_value(t, out[4], 10)
	// never upscales
	_, w2, h2 := downscale(px, 4, 2, 400, context.temp_allocator)
	testing.expect_value(t, w2, 4)
	testing.expect_value(t, h2, 2)
}

// A clipboard DIB (Windows screenshots) becomes the RGBA that WIC encodes into image.png.
@(test)
clipboard_dib_to_rgba :: proc(t: ^testing.T) {
	// 2x2, 24 bpp, bottom-up, rows padded to 8 bytes
	dib := make([]byte, 40 + 16, context.temp_allocator)
	put :: proc(b: []byte, v: u32) {b[0], b[1], b[2], b[3] = u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24)}
	put(dib[0:], 40)
	put(dib[4:], 2)
	put(dib[8:], 2)
	dib[12] = 1
	dib[14] = 24
	// bottom row first (BGR): blue, green; then top row: red, white
	copy(dib[40:], []byte{255, 0, 0, 0, 255, 0, 0, 0})
	copy(dib[48:], []byte{0, 0, 255, 255, 255, 255, 0, 0})
	rgba, w, h, ok := platform.dib_to_rgba(dib, context.temp_allocator)
	testing.expect(t, ok && w == 2 && h == 2)
	want := []byte{255, 0, 0, 255, 255, 255, 255, 255, 0, 0, 255, 255, 0, 255, 0, 255}
	testing.expect(t, string(rgba) == string(want))
	// 32 bpp with alpha all zero is opaque
	put(dib[0:], 40)
	dib[14] = 32
	d32 := make([]byte, 40 + 16, context.temp_allocator)
	copy(d32, dib[:40])
	copy(d32[40:], []byte{1, 2, 3, 0, 4, 5, 6, 0, 7, 8, 9, 0, 10, 11, 12, 0})
	r32, _, _, ok32 := platform.dib_to_rgba(d32, context.temp_allocator)
	testing.expect(t, ok32)
	testing.expect_value(t, r32[3], 255)
	testing.expect_value(t, r32[0], 9) // top row = last stored row, BGR -> R
	_, _, _, bad := platform.dib_to_rgba(dib[:30], context.temp_allocator)
	testing.expect(t, !bad)
}
