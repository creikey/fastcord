// Realtime VP8 encoding in software (vendor/libvpx) on every platform, for calls whose codec is VP8. Output
// is delivered inside vp8_encoder_encode, on the caller's thread.

Vp8_Encoder :: struct {
	enc: *void;
	width, height: int;
	on_output: Encoded_Proc;
	user: *void;
}

// screen: Go Live (screen content mode, no frame dropping).
vp8_encoder_create :: (width: int, height: int, fps: int, bitrate: int, screen: bool, on_output: Encoded_Proc, user: *void) -> *Vp8_Encoder {
	h := fc_vp8_enc_create(xx width, xx height, xx max(fps, 1), xx bitrate, xx screen);
	if !h return null;
	e := New(Vp8_Encoder);
	e.* = .{enc = h, width = width, height = height, on_output = on_output, user = user};
	return e;
}

// pixbuf: a captured frame (Frame_Proc) at least the encoder's size; it is cropped to it, smaller ones dropped.
// The output is one VP8 frame, not Annex B.
vp8_encoder_encode :: (e: *Vp8_Encoder, pixbuf: *void, pts_90k: u32, force_keyframe := false) {
	#if OS == .MACOS {
		CVPixelBufferLockBaseAddress(pixbuf, 1); // read-only
		defer CVPixelBufferUnlockBaseAddress(pixbuf, 1);
		w, h := cast(int) CVPixelBufferGetWidth(pixbuf), cast(int) CVPixelBufferGetHeight(pixbuf);
		y, uv := cast(*u8) CVPixelBufferGetBaseAddressOfPlane(pixbuf, 0), cast(*u8) CVPixelBufferGetBaseAddressOfPlane(pixbuf, 1);
		ys, uvs := cast(int) CVPixelBufferGetBytesPerRowOfPlane(pixbuf, 0), cast(int) CVPixelBufferGetBytesPerRowOfPlane(pixbuf, 1);
	} else {
		f := cast(*yuv.Nv12) pixbuf;
		w, h := f.width, f.height;
		y, uv := f.data.data, f.data.data + f.width * f.height;
		ys, uvs := f.width, f.width;
	}
	vp8_encode_nv12(e, y, uv, ys, uvs, w, h, pts_90k, force_keyframe);
}

// vp8_encode_nv12: the same from an NV12 picture's planes (y, uv with row pitches ys, uvs).
vp8_encode_nv12 :: (e: *Vp8_Encoder, y: *u8, uv: *u8, ys: int, uvs: int, w: int, h: int, pts_90k: u32, force_keyframe := false) {
	if w < e.width || h < e.height || !y || !uv return;
	out: *u8;
	n: u64;
	key: s32;
	if fc_vp8_enc_encode(e.enc, y, uv, xx ys, xx uvs, pts_90k, xx force_keyframe, *out, *n, *key) != 0 || !n return;
	e.on_output(e.user, .{xx n, out}, key != 0, pts_90k);
}

vp8_encoder_destroy :: (e: *Vp8_Encoder) {
	if !e return;
	fc_vp8_enc_destroy(e.enc);
	free(e);
}

#scope_file

fc_vp8_enc_create :: (w: s32, h: s32, fps: s32, bitrate: s32, screen: s32) -> *void #foreign fc_vendor_vp8;
fc_vp8_enc_encode :: (e: *void, y: *u8, uv: *u8, ys: s32, uvs: s32, pts_90k: u32, force_key: s32, out: **u8, n: *u64, key: *s32) -> s32 #foreign fc_vendor_vp8;
fc_vp8_enc_destroy :: (e: *void) #foreign fc_vendor_vp8;
fc_vendor_vp8 :: #library,no_dll "../../build/fc_vendor";

#if OS == .MACOS {
	CVPixelBufferLockBaseAddress :: (pb: CFRef, flags: u64) -> s32 #foreign CoreVideo;
	CVPixelBufferUnlockBaseAddress :: (pb: CFRef, flags: u64) -> s32 #foreign CoreVideo;
	CVPixelBufferGetBaseAddressOfPlane :: (pb: CFRef, plane: u64) -> *void #foreign CoreVideo;
	CVPixelBufferGetBytesPerRowOfPlane :: (pb: CFRef, plane: u64) -> u64 #foreign CoreVideo;
}
