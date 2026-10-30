// Realtime H.264 encoding in software (vendor/openh264). Output is delivered inside encoder_encode, on the
// caller's thread.

Encoder :: struct {
	enc: *void;
	width, height: int;
	on_output: Encoded_Proc;
	user: *void;
}

encoder_supported :: (codec: Video_Codec) -> bool { return codec == .H264; }

encoder_create :: (codec: Video_Codec, width: int, height: int, fps: int, bitrate: int, on_output: Encoded_Proc, user: *void) -> *Encoder {
	if !encoder_supported(codec) return null;
	h := fc_h264_enc_create(xx width, xx height, xx max(fps, 1), xx bitrate);
	if !h return null;
	e := New(Encoder);
	e.* = .{enc = h, width = width, height = height, on_output = on_output, user = user};
	return e;
}

// encoder_set_bitrate changes the target bitrate between frames (the bandwidth estimate moved).
encoder_set_bitrate :: (e: *Encoder, bitrate: int) { fc_h264_enc_set_bitrate(e.enc, xx bitrate); }

// pixbuf: a yuv.Nv12, scaled to the encoder's size.
encoder_encode :: (e: *Encoder, pixbuf: *void, pts_90k: u32, force_keyframe := false) {
	f := yuv.nv12_scaled(cast(*yuv.Nv12) pixbuf, e.width, e.height);
	defer yuv.nv12_release(f);
	if f.width != e.width || f.height != e.height return;
	out: *u8;
	n, key: s32;
	if fc_h264_enc_encode(e.enc, f.data.data, pts_90k / 90, xx force_keyframe, *out, *n, *key) != 0 || n <= 0 return;
	e.on_output(e.user, .{n, out}, key != 0, pts_90k);
}

encoder_destroy :: (e: *Encoder) {
	if !e return;
	fc_h264_enc_destroy(e.enc);
	free(e);
}

#scope_file

fc_h264_enc_create :: (w: s32, h: s32, fps: s32, bitrate: s32) -> *void #foreign vendor;
fc_h264_enc_encode :: (e: *void, nv12: *u8, ts_ms: s64, force_keyframe: s32, out: **u8, n: *s32, keyframe: *s32) -> s32 #foreign vendor;
fc_h264_enc_set_bitrate :: (e: *void, bitrate: s32) #foreign vendor;
fc_h264_enc_destroy :: (e: *void) #foreign vendor;
