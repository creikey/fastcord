// Camera background blur: Vision's person segmentation (macOS 12+, on the Neural Engine where there is
// one) gives a mask of the people in the frame; everything else is replaced by a blurred copy. The blur is
// a box filter at a sixteenth of the size, scaled back up bilinearly, done on the NV12 planes on the
// capture's queue.

blur_supported :: () -> bool { return cls("VNGeneratePersonSegmentationRequest") != null; }

// blur_background: a new NV12 CVPixelBuffer (release with pixbuf_release) of pixbuf with its background
// blurred, or null when Vision found no mask or the format isn't 420v / 420f.
blur_background :: (pixbuf: *void) -> *void {
	fmt := CVPixelBufferGetPixelFormatType(pixbuf);
	if fmt != fourcc("420v") && fmt != fourcc("420f") return null;
	pool := objc_autoreleasePoolPush();
	defer objc_autoreleasePoolPop(pool);
	if !blur.request {
		blur.request = objc.new_obj("VNGeneratePersonSegmentationRequest");
		if !blur.request return null;
		msg(Void, blur.request, "setQualityLevel:", cast(u64) 1); // balanced
		msg(Void, blur.request, "setOutputPixelFormat:", fourcc("L008"));
	}
	handler := msg(Id, msg(Id, cls("VNImageRequestHandler"), "alloc"), "initWithCVPixelBuffer:options:", pixbuf, msg(Id, cls("NSDictionary"), "dictionary"));
	if !handler return null;
	defer msg(Void, handler, "release");
	err: Id;
	if !msg(bool, handler, "performRequests:error:", msg(Id, cls("NSArray"), "arrayWithObject:", blur.request), *err) return null;
	results := msg(Id, blur.request, "results");
	if !results || msg(s64, results, "count") < 1 return null;
	mask := msg(*void, msg(Id, results, "firstObject"), "pixelBuffer");
	if !mask || CVPixelBufferGetPixelFormatType(mask) != fourcc("L008") return null;

	w, h := cast(int) CVPixelBufferGetWidth(pixbuf), cast(int) CVPixelBufferGetHeight(pixbuf);
	empty := cf_dict(.[], .[]);
	attrs := cf_dict(.[kCVPixelBufferIOSurfacePropertiesKey], .[empty]);
	defer { CFRelease(attrs); CFRelease(empty); }
	out: *void;
	if CVPixelBufferCreate(null, xx w, xx h, fmt, attrs, *out) != 0 || !out return null;
	CVPixelBufferLockBaseAddress(pixbuf, 1); // read-only
	CVPixelBufferLockBaseAddress(mask, 1);
	CVPixelBufferLockBaseAddress(out, 0);
	m := Plane.{cast(*u8) CVPixelBufferGetBaseAddress(mask), cast(int) CVPixelBufferGetBytesPerRow(mask), cast(int) CVPixelBufferGetWidth(mask), cast(int) CVPixelBufferGetHeight(mask)};
	for p: 0..1 {
		pw, ph := ifx p == 0 then w else w / 2, ifx p == 0 then h else h / 2;
		src := Plane.{cast(*u8) CVPixelBufferGetBaseAddressOfPlane(pixbuf, xx p), cast(int) CVPixelBufferGetBytesPerRowOfPlane(pixbuf, xx p), pw, ph};
		dst := Plane.{cast(*u8) CVPixelBufferGetBaseAddressOfPlane(out, xx p), cast(int) CVPixelBufferGetBytesPerRowOfPlane(out, xx p), pw, ph};
		blend_plane(src, dst, m, ifx p == 0 then 1 else 2, ifx p == 0 then 16 else 8);
	}
	CVPixelBufferUnlockBaseAddress(out, 0);
	CVPixelBufferUnlockBaseAddress(mask, 1);
	CVPixelBufferUnlockBaseAddress(pixbuf, 1);
	return out;
}

pixbuf_release :: (pb: *void) { if pb CFRelease(pb); }

#scope_file

blur: struct { request: Id; }; // the capture's queue only

Plane :: struct { data: *u8; stride, w, h: int; }

// blend_plane writes src with its background (where the mask says no one is) blurred: a box average over
// cells of `cell` pixels, smoothed once more, scaled back up bilinearly and mixed in by the mask. comps: 1
// for luma, 2 for interleaved CbCr.
blend_plane :: (src: Plane, dst: Plane, mask: Plane, comps: int, cell: int) {
	sw, sh := (src.w + cell - 1) / cell, (src.h + cell - 1) / cell;
	small := NewArray(sw * sh * comps, float32,, temp);
	for cy: 0..sh - 1 for cx: 0..sw - 1 for c: 0..comps - 1 {
		sum, n := 0, 0;
		for y: cy * cell..min((cy + 1) * cell, src.h) - 1 {
			row := src.data + y * src.stride;
			for x: cx * cell..min((cx + 1) * cell, src.w) - 1 { sum += row[x * comps + c]; n += 1; }
		}
		small[(cy * sw + cx) * comps + c] = cast(float32) sum / max(n, 1);
	}
	soft := NewArray(small.count, float32,, temp);
	for cy: 0..sh - 1 for cx: 0..sw - 1 for c: 0..comps - 1 {
		sum: float32;
		n: float32;
		for dy: -1..1 for dx: -1..1 {
			x, y := cx + dx, cy + dy;
			if x < 0 || y < 0 || x >= sw || y >= sh continue;
			sum += small[(y * sw + x) * comps + c];
			n += 1;
		}
		soft[(cy * sw + cx) * comps + c] = sum / n;
	}
	for y: 0..src.h - 1 {
		srow, drow := src.data + y * src.stride, dst.data + y * dst.stride;
		fy := (y + 0.5) / cell - 0.5;
		y0 := clamp(cast(int) fy, 0, sh - 1);
		y1 := min(y0 + 1, sh - 1);
		ty := clamp(fy - y0, 0, 1);
		mrow := mask.data + min(y * mask.h / src.h, mask.h - 1) * mask.stride;
		for x: 0..src.w - 1 {
			k := cast(float32) mrow[min(x * mask.w / src.w, mask.w - 1)] / 255; // 1: a person
			fx := (x + 0.5) / cell - 0.5;
			x0 := clamp(cast(int) fx, 0, sw - 1);
			x1 := min(x0 + 1, sw - 1);
			tx := clamp(fx - x0, 0, 1);
			for c: 0..comps - 1 {
				a := soft[(y0 * sw + x0) * comps + c] * (1 - tx) + soft[(y0 * sw + x1) * comps + c] * tx;
				b := soft[(y1 * sw + x0) * comps + c] * (1 - tx) + soft[(y1 * sw + x1) * comps + c] * tx;
				bg := a * (1 - ty) + b * ty;
				drow[x * comps + c] = cast(u8) clamp(srow[x * comps + c] * k + bg * (1 - k) + 0.5, 0, 255);
			}
		}
	}
}

CVPixelBufferGetPixelFormatType :: (pb: *void) -> u32 #foreign CoreVideo;
CVPixelBufferGetBaseAddress :: (pb: *void) -> *void #foreign CoreVideo;
CVPixelBufferGetBytesPerRow :: (pb: *void) -> u64 #foreign CoreVideo;
CVPixelBufferUnlockBaseAddress :: (pb: *void, flags: u64) -> s32 #foreign CoreVideo;
CVPixelBufferCreate :: (alloc: CFRef, w: u64, h: u64, fmt: u32, attrs: CFRef, out: **void) -> s32 #foreign CoreVideo;
CVPixelBufferLockBaseAddress :: (pb: *void, flags: u64) -> s32 #foreign CoreVideo;
CVPixelBufferGetBaseAddressOfPlane :: (pb: *void, plane: u64) -> *void #foreign CoreVideo;
CVPixelBufferGetBytesPerRowOfPlane :: (pb: *void, plane: u64) -> u64 #foreign CoreVideo;
kCVPixelBufferIOSurfacePropertiesKey: CFRef #elsewhere CoreVideo;
objc_autoreleasePoolPush :: () -> *void #foreign libobjc;
objc_autoreleasePoolPop :: (pool: *void) #foreign libobjc;
Vision :: #library,system,link_always "Vision";
