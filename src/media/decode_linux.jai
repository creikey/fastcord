// Linux video decoding: H.264 in software (vendor/openh264), I420 out, copied into yuv.Nv12 frames
// (frame_nv12.jai). There is no H.265 decoder, and the voice gateway says so, so calls stay on H.264.

Video_Decoder :: struct {
	dec: *void;
	nal_len: int;     // input samples: big-endian NAL lengths of this size (AVCC)
	prefix: [..]u8;   // parameter sets, Annex B, sent before the next sample
	annexb: [..]u8;   // reused input
	out: [..]Video_Frame; // decoded, in output order (caller sorts)
	errors: int;
}

video_codec_supported :: (c: Codec) -> bool { return c == .H264; }

video_decoder_create :: (t: *Track, first_packet: []u8 = .[]) -> *Video_Decoder, bool {
	if !video_codec_supported(t.codec) return null, false;
	prefix, nal_len, ok := params_from_config(t.codec, t.extradata);
	vd := ifx ok then decoder_create() else null;
	if !vd { array_free(prefix); return null, false; }
	vd.prefix, vd.nal_len = prefix, nal_len;
	return vd, true;
}

// A decoder for a live stream from its parameter sets (SPS, PPS) as they arrive in-band; samples are then
// AVCC with 4-byte lengths.
video_decoder_create_from_params :: (codec: Codec, params: [][]u8) -> *Video_Decoder, bool {
	if !video_codec_supported(codec) || !params.count return null, false;
	vd := decoder_create();
	if !vd return null, false;
	for params { array_add(*vd.prefix, 0, 0, 0, 1); array_add(*vd.prefix, ..it); }
	vd.nal_len = 4;
	return vd, true;
}

// Decode one access unit (synchronously). Output frames land in vd.out.
video_decode :: (vd: *Video_Decoder, data: []u8, pts: float64, dts: float64, dur: float64) -> bool {
	if !data.count return true;
	vd.annexb.count = 0;
	array_add(*vd.annexb, ..vd.prefix);
	vd.prefix.count = 0;
	i := 0;
	while i + vd.nal_len <= data.count {
		n := 0;
		for 0..vd.nal_len - 1 n = (n << 8) | data[i + it];
		i += vd.nal_len;
		if n <= 0 || i + n > data.count break;
		array_add(*vd.annexb, 0, 0, 0, 1);
		array_add(*vd.annexb, ..array_view(data, i, n));
		i += n;
	}
	y, u, v: *u8;
	ys, uvs, w, h: s32;
	ts: s64;
	r := fc_h264_dec_decode(vd.dec, vd.annexb.data, xx vd.annexb.count, cast(s64) (pts * 1_000_000), *y, *u, *v, *ys, *uvs, *w, *h, *ts);
	if r < 0 { vd.errors += 1; return false; }
	if r == 1 && w >= 2 && h >= 2 {
		f := yuv.nv12_create(w, h);
		for row: 0..f.height - 1 memcpy(f.data.data + row * f.width, y + row * ys, f.width);
		uv := f.data.data + f.width * f.height;
		for row: 0..f.height / 2 - 1 {
			su, sv, d := u + row * uvs, v + row * uvs, uv + row * f.width;
			for x: 0..f.width / 2 - 1 { d[2 * x] = su[x]; d[2 * x + 1] = sv[x]; }
		}
		array_add(*vd.out, .{pts = cast(float64) ts / 1_000_000, dur = dur, pixbuf = f, width = f.width, height = f.height, yuv = ifx f.height >= 720 then .BT709 else .BT601});
	}
	return true;
}

video_decoder_flush :: (vd: *Video_Decoder) {} // decoding has no delay: every picture came out with its access unit

// Take decoded frames (caller owns them; release with video_frame_release).
video_decoder_take :: (vd: *Video_Decoder, out: *[..]Video_Frame) {
	array_add(out, ..vd.out);
	vd.out.count = 0;
}

video_decoder_destroy :: (vd: *Video_Decoder) {
	if !vd return;
	fc_h264_dec_destroy(vd.dec);
	for * vd.out video_frame_release(it);
	array_free(vd.out);
	array_free(vd.prefix);
	array_free(vd.annexb);
	free(vd);
}

#scope_file

decoder_create :: () -> *Video_Decoder {
	d := fc_h264_dec_create();
	if !d return null;
	vd := New(Video_Decoder);
	vd.dec = d;
	return vd;
}

openh264 :: #library,no_dll "../../build/fc_vendor";
fc_h264_dec_create :: () -> *void #foreign openh264;
fc_h264_dec_decode :: (d: *void, annexb: *u8, n: s32, ts: s64, y: **u8, u: **u8, v: **u8, y_stride: *s32, uv_stride: *s32, w: *s32, h: *s32, out_ts: *s64) -> s32 #foreign openh264;
fc_h264_dec_destroy :: (d: *void) #foreign openh264;
