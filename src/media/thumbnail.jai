// nv12_to_rgb: an NV12 picture (sw x sh; rows ys and uvs bytes apart) scaled to w x h, bilinear like a
// canvas drawImage, as RGB8 rows in temp. The matrix says how its YUV maps to RGB.
nv12_to_rgb :: (y: *u8, ys: int, uv: *u8, uvs: int, sw: int, sh: int, m: gfx.Yuv_Matrix, w: int, h: int) -> []u8 {
	assert(sw >= 2 && sh >= 2 && w > 0 && h > 0);
	full := m == .BT601_Full || m == .BT709_Full;
	bt709 := m == .BT709 || m == .BT709_Full;
	kr, kgb, kgr, kb := ifx bt709 then 1.5748 else 1.402, ifx bt709 then 0.187324 else 0.344136,
		ifx bt709 then 0.468124 else 0.714136, ifx bt709 then 1.8556 else 1.772;
	ky, kc, y0 := ifx full then 1.0 else 255.0 / 219, ifx full then 1.0 else 255.0 / 224, ifx full then 0.0 else 16.0;
	// bilinear sample of plane p (pw x ph, pitch, step bytes per sample) at the centre of output (x, y)
	sample :: (p: *u8, pitch: int, step: int, pw: int, ph: int, fx: float, fy: float) -> float {
		x := clamp(fx, 0, cast(float) (pw - 1));
		y := clamp(fy, 0, cast(float) (ph - 1));
		x0, y0 := cast(int) x, cast(int) y;
		x1, y1 := min(x0 + 1, pw - 1), min(y0 + 1, ph - 1);
		ax, ay := x - x0, y - y0;
		r0 := p + y0 * pitch;
		r1 := p + y1 * pitch;
		top := r0[x0 * step] * (1 - ax) + r0[x1 * step] * ax;
		bot := r1[x0 * step] * (1 - ax) + r1[x1 * step] * ax;
		return top * (1 - ay) + bot * ay;
	}
	out := NewArray(w * h * 3, u8, false,, temp);
	sx, sy := cast(float) sw / w, cast(float) sh / h;
	byte :: (v: float) -> u8 { return cast(u8) clamp(v + 0.5, 0, 255); }
	for oy: 0..h - 1 {
		fy := (oy + 0.5) * sy - 0.5;
		for ox: 0..w - 1 {
			fx := (ox + 0.5) * sx - 0.5;
			l := (sample(y, ys, 1, sw, sh, fx, fy) - y0) * ky;
			cfx, cfy := (fx - 0.5) / 2, (fy - 0.5) / 2;
			cb := (sample(uv, uvs, 2, sw / 2, sh / 2, cfx, cfy) - 128) * kc;
			cr := (sample(uv + 1, uvs, 2, sw / 2, sh / 2, cfx, cfy) - 128) * kc;
			o := out.data + (oy * w + ox) * 3;
			o[0] = byte(l + kr * cr);
			o[1] = byte(l - kgb * cb - kgr * cr);
			o[2] = byte(l + kb * cb);
		}
	}
	return out;
}
