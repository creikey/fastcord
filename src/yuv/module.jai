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
