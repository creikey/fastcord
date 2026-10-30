// Decoded video on Windows and Linux: yuv.Nv12 frames, uploaded as R8 + RG8 textures.

Video_Frame :: struct {
	pts: float64; // seconds
	dur: float64;
	pixbuf: *void; // *yuv.Nv12 (one reference)
	width: int;
	height: int;
	yuv: gfx.Yuv_Matrix;
}

// video_frame_from_pixbuf wraps (and retains) a yuv.Nv12 from elsewhere, e.g. a camera.
video_frame_from_pixbuf :: (pixbuf: *void) -> Video_Frame {
	f := yuv.nv12_retain(cast(*yuv.Nv12) pixbuf);
	return .{pixbuf = f, width = f.width, height = f.height, yuv = ifx f.height >= 720 then .BT709 else .BT601};
}

// A decoder's I420 picture (odd sizes rounded down to even) copied into a new NV12 frame.
frame_from_i420 :: (y: *u8, u: *u8, v: *u8, ys: int, uvs: int, w: int, h: int) -> Video_Frame, bool {
	f := yuv.nv12_create(w & ~1, h & ~1);
	for row: 0..f.height - 1 memcpy(f.data.data + row * f.width, y + row * ys, f.width);
	uv := f.data.data + f.width * f.height;
	for row: 0..f.height / 2 - 1 {
		su, sv, d := u + row * uvs, v + row * uvs, uv + row * f.width;
		for x: 0..f.width / 2 - 1 { d[2 * x] = su[x]; d[2 * x + 1] = sv[x]; }
	}
	return .{pixbuf = f, width = f.width, height = f.height, yuv = ifx f.height >= 720 then .BT709 else .BT601}, true;
}

video_frame_release :: (f: *Video_Frame) {
	yuv.nv12_release(cast(*yuv.Nv12) f.pixbuf);
	f.pixbuf = null;
}

// video_frame_rgb: the frame scaled to w x h as RGB8 rows in temp (nv12_to_rgb).
video_frame_rgb :: (f: *Video_Frame, w: int, h: int) -> []u8 {
	n := cast(*yuv.Nv12) f.pixbuf;
	if !n || n.width < 2 || n.height < 2 return .[];
	return nv12_to_rgb(n.data.data, n.width, n.data.data + n.width * n.height, n.width, n.width, n.height, f.yuv, w, h);
}

// Upload the frame's Y and CbCr planes as gfx textures (a copy; the frame stays the caller's).
// Destroy them with gfx.texture_destroy.
video_frame_textures :: (f: *Video_Frame) -> gfx.Texture, gfx.Texture, bool {
	n := cast(*yuv.Nv12) f.pixbuf;
	if !n return 0, 0, false;
	ys := n.width * n.height;
	y := gfx.texture_create(n.width, n.height, .R8, array_view(n.data, 0, ys));
	if !y return 0, 0, false;
	uv := gfx.texture_create(n.width / 2, n.height / 2, .RG8, array_view(n.data, ys, n.data.count - ys));
	if !uv { gfx.texture_destroy(y); return 0, 0, false; }
	return y, uv, true;
}

#scope_module

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
