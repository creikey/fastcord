// Windows video decoding: the H.264 / HEVC decoder MFTs (Media Foundation), NV12 out, copied into mf.Nv12
// frames and uploaded as R8 + RG8 textures. Audio stays on decode_none.jai's PCM and MP3.

Video_Frame :: struct {
	pts: float64; // seconds
	dur: float64;
	pixbuf: *void; // *mf.Nv12 (one reference)
	width: int;
	height: int;
	yuv: gfx.Yuv_Matrix;
}

Video_Decoder :: struct {
	mft: *void;
	info: mf.MFT_OUTPUT_STREAM_INFO;
	w, h, frame_h, stride: int; // the output type's
	nal_len: int;     // input samples: big-endian NAL lengths of this size (AVCC / HVCC)
	prefix: [..]u8;   // parameter sets, Annex B, sent before the next sample
	annexb: [..]u8;   // reused input
	out: [..]Video_Frame; // decoded, in output order (caller sorts)
	errors: int;
}

video_codec_supported :: (c: Codec) -> bool {
	if c == .H264 return mf.startup();
	if c == .HEVC {
		if hevc_ok == 0 {
			ok := mf.startup() && has_hevc_decoder();
			hevc_ok = cast(s32) ifx ok then 1 else 2;
		}
		return hevc_ok == 1;
	}
	return false;
}

video_decoder_create :: (t: *Track, first_packet: []u8 = .[]) -> *Video_Decoder, bool {
	if (t.codec != .H264 && t.codec != .HEVC) || !video_codec_supported(t.codec) return null, false;
	prefix, nal_len, ok := params_from_config(t.codec, t.extradata);
	if !ok { array_free(prefix); return null, false; }
	vd := decoder_create(t.codec, t.width, t.height);
	if !vd { array_free(prefix); return null, false; }
	vd.prefix, vd.nal_len = prefix, nal_len;
	return vd, true;
}

// A decoder for a live stream (H.264 or HEVC) from its parameter sets (SPS, PPS;
// HEVC: VPS, SPS, PPS), as they arrive in-band; samples are then AVCC with 4-byte lengths.
video_decoder_create_from_params :: (codec: Codec, params: [][]u8) -> *Video_Decoder, bool {
	if (codec != .H264 && codec != .HEVC) || !params.count || !video_codec_supported(codec) return null, false;
	vd := decoder_create(codec, 0, 0);
	if !vd return null, false;
	for params { array_add(*vd.prefix, 0, 0, 0, 1); array_add(*vd.prefix, ..it); }
	vd.nal_len = 4;
	return vd, true;
}

// Decode one access unit (synchronously). Output frames land in vd.out.
video_decode :: (vd: *Video_Decoder, data: []u8, pts: float64, dts: float64, dur: float64) -> bool {
	if !data.count return true;
	com := mf.com_enter();
	defer mf.com_leave(com);
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
	s := mf.sample_from_bytes(vd.annexb, cast(s64) (pts * 10_000_000), cast(s64) (dur * 10_000_000));
	if !s return false;
	defer mf.release(s);
	hr := mf.mft_input(vd.mft, s);
	if hr == mf.MF_E_NOTACCEPTING {
		drain(vd);
		hr = mf.mft_input(vd.mft, s);
	}
	drain(vd);
	if hr < 0 vd.errors += 1;
	return hr >= 0;
}

video_decoder_flush :: (vd: *Video_Decoder) {
	com := mf.com_enter();
	defer mf.com_leave(com);
	mf.mft_message(vd.mft, mf.MFT_MESSAGE_COMMAND_DRAIN);
	drain(vd);
}

// Take decoded frames (caller owns them; release with video_frame_release).
video_decoder_take :: (vd: *Video_Decoder, out: *[..]Video_Frame) {
	array_add(out, ..vd.out);
	vd.out.count = 0;
}

video_decoder_destroy :: (vd: *Video_Decoder) {
	if !vd return;
	com := mf.com_enter();
	defer mf.com_leave(com);
	mf.release(vd.mft);
	for * vd.out video_frame_release(it);
	array_free(vd.out);
	array_free(vd.prefix);
	array_free(vd.annexb);
	free(vd);
}

// video_frame_from_pixbuf wraps (and retains) an mf.Nv12 from elsewhere, e.g. a camera.
video_frame_from_pixbuf :: (pixbuf: *void) -> Video_Frame {
	f := mf.nv12_retain(cast(*mf.Nv12) pixbuf);
	return .{pixbuf = f, width = f.width, height = f.height, yuv = ifx f.height >= 720 then .BT709 else .BT601};
}

video_frame_release :: (f: *Video_Frame) {
	mf.nv12_release(cast(*mf.Nv12) f.pixbuf);
	f.pixbuf = null;
}

// Upload the frame's Y and CbCr planes as gfx textures (a copy; the frame stays the caller's).
// Destroy them with gfx.texture_destroy.
video_frame_textures :: (f: *Video_Frame) -> gfx.Texture, gfx.Texture, bool {
	n := cast(*mf.Nv12) f.pixbuf;
	if !n return 0, 0, false;
	ys := n.width * n.height;
	y := gfx.texture_create(n.width, n.height, .R8, array_view(n.data, 0, ys));
	if !y return 0, 0, false;
	uv := gfx.texture_create(n.width / 2, n.height / 2, .RG8, array_view(n.data, ys, n.data.count - ys));
	if !uv { gfx.texture_destroy(y); return 0, 0, false; }
	return y, uv, true;
}

#scope_file

mf :: #import "mf";

hevc_ok: s32; // 0 unknown, 1 yes, 2 no

has_hevc_decoder :: () -> bool {
	com := mf.com_enter();
	defer mf.com_leave(com);
	m := mf.transform_find(*mf.MFT_CATEGORY_VIDEO_DECODER, *mf.MFVideoFormat_HEVC, null);
	mf.release(m);
	return m != null;
}

decoder_create :: (codec: Codec, width: int, height: int) -> *Video_Decoder {
	com := mf.com_enter();
	defer mf.com_leave(com);
	subtype := ifx codec == .HEVC then *mf.MFVideoFormat_HEVC else *mf.MFVideoFormat_H264;
	m := mf.transform_find(*mf.MFT_CATEGORY_VIDEO_DECODER, subtype, *mf.MFVideoFormat_NV12);
	if !m m = mf.transform_find(*mf.MFT_CATEGORY_VIDEO_DECODER, subtype, null);
	if !m return null;
	attrs := mf.mft_attributes(m);
	if attrs { mf.set_u32(attrs, *mf.MF_LOW_LATENCY, 1); mf.release(attrs); }
	t := mf.video_type(subtype, width, height);
	ok := t && mf.mft_set_input_type(m, t) >= 0;
	mf.release(t);
	if !ok { mf.release(m); return null; }
	vd := New(Video_Decoder);
	vd.mft = m;
	select_output(vd); // may fail until the stream's parameter sets arrive (MF_E_TRANSFORM_STREAM_CHANGE)
	mf.mft_message(m, mf.MFT_MESSAGE_NOTIFY_BEGIN_STREAMING);
	mf.mft_message(m, mf.MFT_MESSAGE_NOTIFY_START_OF_STREAM);
	return vd;
}

select_output :: (vd: *Video_Decoder) -> bool {
	for i: 0..63 {
		t := mf.mft_output_available_type(vd.mft, i);
		if !t return false;
		defer mf.release(t);
		if !mf.has_subtype(t, *mf.MFVideoFormat_NV12) continue;
		if mf.mft_set_output_type(vd.mft, t) < 0 return false;
		vd.w, vd.h, vd.frame_h = mf.visible_size(t);
		stride := mf.get_u32(t, *mf.MF_MT_DEFAULT_STRIDE);
		vd.stride = cast(s32) stride;
		vd.info = mf.mft_output_info(vd.mft);
		return true;
	}
	return false;
}

drain :: (vd: *Video_Decoder) {
	for 0..63 {
		s, hr := mf.mft_output(vd.mft, vd.info);
		if hr == mf.MF_E_TRANSFORM_STREAM_CHANGE {
			if !select_output(vd) return;
			continue;
		}
		if hr < 0 return; // MF_E_TRANSFORM_NEED_MORE_INPUT, or an error
		defer mf.release(s);
		n := mf.nv12_from_sample(s, vd.w, vd.h, vd.frame_h, vd.stride);
		if !n continue;
		pts := cast(float64) mf.sample_time(s) / 10_000_000;
		array_add(*vd.out, .{pts = pts, pixbuf = n, width = n.width, height = n.height, yuv = ifx n.height >= 720 then .BT709 else .BT601});
	}
}

// avcC / hvcC -> the parameter sets as Annex B, and the samples' NAL length size.
params_from_config :: (codec: Codec, cfg: []u8) -> [..]u8, int, bool {
	out: [..]u8;
	// One u16-length-prefixed NAL at cfg[at.*].
	add :: (out: *[..]u8, cfg: []u8, at: *int) -> bool {
		if at.* + 2 > cfg.count return false;
		n := ((cast(int) cfg[at.*]) << 8) | cfg[at.* + 1];
		at.* += 2;
		if at.* + n > cfg.count return false;
		array_add(out, 0, 0, 0, 1);
		array_add(out, ..array_view(cfg, at.*, n));
		at.* += n;
		return true;
	}
	if codec == .H264 {
		if cfg.count < 7 return out, 0, false;
		nal_len := cast(int) (cfg[4] & 3) + 1;
		at := 6;
		for 0..cast(int) (cfg[5] & 0x1f) - 1 if !add(*out, cfg, *at) return out, 0, false;
		if at >= cfg.count return out, 0, false;
		pps := cast(int) cfg[at];
		at += 1;
		for 0..pps - 1 if !add(*out, cfg, *at) return out, 0, false;
		return out, nal_len, true;
	}
	if cfg.count < 23 return out, 0, false;
	nal_len := cast(int) (cfg[21] & 3) + 1;
	at := 23;
	for 0..cast(int) cfg[22] - 1 {
		if at + 3 > cfg.count return out, 0, false;
		count := ((cast(int) cfg[at + 1]) << 8) | cfg[at + 2];
		at += 3;
		for 0..count - 1 if !add(*out, cfg, *at) return out, 0, false;
	}
	return out, nal_len, true;
}
