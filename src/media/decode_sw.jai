// Software video decoders for what the OS codecs don't cover in calls: VP8 (vendor/libvpx) and AV1
// (vendor/dav1d), 8-bit 4:2:0 pictures out as Video_Frames (frame_from_i420).

Sw_Decoder :: struct {
	codec: Codec;
	dec: *void;
}

sw_decoder_create :: (codec: Codec) -> *Sw_Decoder {
	dec := ifx codec == .VP8 then fc_vp8_create() else ifx codec == .AV1 then fc_av1_create(4) else null;
	if !dec return null;
	d := New(Sw_Decoder);
	d.* = .{codec, dec};
	return d;
}

// Decodes one frame (VP8) or temporal unit (AV1, OBUs with size fields), adding its pictures to out.
sw_decode :: (d: *Sw_Decoder, data: []u8, out: *[..]Video_Frame) -> bool {
	vp8 := d.codec == .VP8;
	if (ifx vp8 then fc_vp8_decode(d.dec, data.data, xx data.count) else fc_av1_decode(d.dec, data.data, xx data.count)) < 0 return false;
	while true {
		y, u, v: *u8;
		ys, uvs, w, h: s32;
		got := ifx vp8 then fc_vp8_picture(d.dec, *y, *u, *v, *ys, *uvs, *w, *h) else fc_av1_picture(d.dec, *y, *u, *v, *ys, *uvs, *w, *h);
		if got != 1 break;
		if w < 2 || h < 2 || w > 8192 || h > 8192 continue;
		f, ok := frame_from_i420(y, u, v, ys, uvs, w, h);
		if ok array_add(out, f);
	}
	return true;
}

sw_decoder_destroy :: (d: *Sw_Decoder) {
	if !d return;
	if d.codec == .VP8 fc_vp8_destroy(d.dec);
	else fc_av1_destroy(d.dec);
	free(d);
}

#scope_file

fc_vp8_create :: () -> *void #foreign fc_vendor_sw;
fc_vp8_decode :: (d: *void, data: *u8, n: u64) -> s32 #foreign fc_vendor_sw;
fc_vp8_picture :: (d: *void, y: **u8, u: **u8, v: **u8, ys: *s32, uvs: *s32, w: *s32, h: *s32) -> s32 #foreign fc_vendor_sw;
fc_vp8_destroy :: (d: *void) #foreign fc_vendor_sw;
fc_av1_create :: (threads: s32) -> *void #foreign fc_vendor_sw;
fc_av1_decode :: (d: *void, data: *u8, n: u64) -> s32 #foreign fc_vendor_sw;
fc_av1_picture :: (d: *void, y: **u8, u: **u8, v: **u8, ys: *s32, uvs: *s32, w: *s32, h: *s32) -> s32 #foreign fc_vendor_sw;
fc_av1_destroy :: (d: *void) #foreign fc_vendor_sw;
fc_vendor_sw :: #library,no_dll "../../build/fc_vendor";
