// Nv12, the CPU frame that stands in for macOS's CVPixelBuffer on Windows and Linux: cameras and screens
// produce it, encoders take it, decoders return it, the call view uploads it.

#import "Basic";
#import "Atomics";

// An NV12 frame: Y (width * height) then interleaved CbCr (width * height / 2), rows tightly packed,
// even sides. Refcounted; frames cross threads (capture -> encoder and preview, decoder -> UI).
Nv12 :: struct {
	refs: s32;
	width, height: int;
	data: []u8;
	allocator: Allocator;
}

nv12_create :: (width: int, height: int) -> *Nv12 {
	w, h := width & ~1, height & ~1;
	n := w * h * 3 / 2;
	f := cast(*Nv12) alloc(size_of(Nv12) + n);
	f.* = .{refs = 1, width = w, height = h, allocator = context.allocator};
	f.data = .{n, cast(*u8) (f + 1)};
	return f;
}

nv12_retain :: (f: *Nv12) -> *Nv12 { atomic_add(*f.refs, 1); return f; }

nv12_release :: (f: *Nv12) {
	if f && atomic_add(*f.refs, -1) == 1 free(f,, f.allocator);
}

// Copies a w x h picture whose planes start at y and uv with the given row pitch.
nv12_from_planes :: (w: int, h: int, y: *u8, uv: *u8, pitch: int) -> *Nv12 {
	f := nv12_create(w, h);
	dst := f.data.data;
	for r: 0..f.height - 1 memcpy(dst + r * f.width, y + r * pitch, f.width);
	dst += f.width * f.height;
	for r: 0..f.height / 2 - 1 memcpy(dst + r * f.width, uv + r * pitch, f.width);
	return f;
}

// nv12_scaled: f at w x h (even), as a new reference: f itself when it already is, else a copy scaled by
// sampling (each output pixel averages the 2x2 source pixels nearest its centre; chroma the nearest pair).
nv12_scaled :: (f: *Nv12, width: int, height: int) -> *Nv12 {
	w, h := width & ~1, height & ~1;
	if (f.width == w && f.height == h) || f.width < 2 || f.height < 2 || w < 2 || h < 2 return nv12_retain(f);
	o := nv12_create(w, h);
	sw, sh := f.width, f.height;
	src, dst := f.data.data, o.data.data;
	for y: 0..h - 1 {
		sy := min((2 * y + 1) * sh / (2 * h), sh - 2);
		for x: 0..w - 1 {
			sx := min((2 * x + 1) * sw / (2 * w), sw - 2);
			p := src + sy * sw + sx;
			dst[y * w + x] = cast(u8) ((cast(int) p[0] + p[1] + p[sw] + p[sw + 1] + 2) / 4);
		}
	}
	suv, duv := src + sw * sh, dst + w * h;
	for y: 0..h / 2 - 1 {
		sy := min(y * sh / h, sh / 2 - 1);
		for x: 0..w / 2 - 1 {
			sx := min(x * sw / w, sw / 2 - 1);
			duv[y * w + 2 * x] = suv[sy * sw + 2 * sx];
			duv[y * w + 2 * x + 1] = suv[sy * sw + 2 * sx + 1];
		}
	}
	return o;
}
