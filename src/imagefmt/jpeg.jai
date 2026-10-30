// encode_jpeg writes RGB8 pixels (w * 3 bytes per row) as Chrome's canvas.toDataURL("image/jpeg") does:
// libjpeg-turbo at quality 92, 4:2:0, baseline. Empty on failure.
encode_jpeg :: (rgb: []u8, w: int, h: int, quality := 92, allocator := context.allocator) -> []u8 {
	assert(w > 0 && h > 0 && rgb.count >= w * h * 3);
	p: *u8;
	n := fc_jpeg_encode(rgb.data, xx w, xx h, xx quality, *p);
	if n == 0 return .[];
	defer fc_jpeg_free(p);
	out := NewArray(xx n, u8, false,, allocator);
	memcpy(out.data, p, xx n);
	return out;
}

#scope_module

// vendor/libjpeg-turbo: the encoder (fc_libjpeg_turbo.sources) and its wrapper (fc_libjpeg_turbo.c).
fc_jpeg_encode :: (rgb: *u8, w: s32, h: s32, quality: s32, out: **u8) -> u64 #foreign vendor;
fc_jpeg_free :: (p: *void) #foreign vendor;
