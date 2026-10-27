// vendor/libwebp: the library (fc_libwebp.sources) and its wrapper (fc_libwebp.c).
	fc_webp_lossless :: (rgba: *u8, w: s32, h: s32, icc: *u8, icc_len: u64, out: **u8) -> u64 #foreign webp;
	fc_webp_free :: (p: *void) #foreign webp;

// encode_webp_lossless writes RGBA8 pixels (straight alpha) as Chrome's canvas.toBlob("image/webp", 1)
// does: libwebp lossless, quality 75, method 0, plus icc (the canvas's colour profile) in an ICCP
// chunk when given. Fully transparent pixels lose their colour (exact = 0, as in Chrome); Chrome's
// canvas would also premultiply other translucent pixels, which this doesn't (uploads are opaque).
// nil on failure.
encode_webp_lossless :: (rgba: []u8, w: int, h: int, icc: []u8 = .{}, allocator := context.allocator) -> []u8 {
	assert(len(rgba) >= w * h * 4);
	p: *u8;
	n := fc_webp_lossless(raw_data(rgba), cast(s32)(w), cast(s32)(h), raw_data(icc), cast(u64) len(icc), *p);
	if n == 0 { return .{}; }
	defer fc_webp_free(p);
	return clone(sub(p, 0, cast(int) n), allocator);
}

