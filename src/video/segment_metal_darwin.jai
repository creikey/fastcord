// segment.jai's kernel on Metal: the default device with a queue of its own, M and F in shared memory
// that the CPU writes and reads in place. Used under seg.mu only.

// background_apply: a new NV12 CVPixelBuffer (release with pixbuf_release) of pixbuf with the background
// effect, or null when it's off, can't run or the format isn't 420v / 420f.
background_apply :: (pixbuf: *void) -> *void {
	fmt := CVPixelBufferGetPixelFormatType(pixbuf);
	if fmt != fourcc("420v") && fmt != fourcc("420f") return null;
	w, h := cast(int) CVPixelBufferGetWidth(pixbuf), cast(int) CVPixelBufferGetHeight(pixbuf);
	n := w * h * 3 / 2;
	src, dst := NewArray(n, u8,, temp), NewArray(n, u8,, temp);
	CVPixelBufferLockBaseAddress(pixbuf, 1); // read-only
	copy_planes(pixbuf, src, w, h, true);
	CVPixelBufferUnlockBaseAddress(pixbuf, 1);
	pool := objc_autoreleasePoolPush();
	ok := background_frame(src, dst, w, h, fmt == fourcc("420f"));
	objc_autoreleasePoolPop(pool);
	if !ok return null;
	empty := cf_dict(.[], .[]);
	attrs := cf_dict(.[kCVPixelBufferIOSurfacePropertiesKey], .[empty]);
	defer { CFRelease(attrs); CFRelease(empty); }
	out: *void;
	if CVPixelBufferCreate(null, xx w, xx h, fmt, attrs, *out) != 0 || !out return null;
	CVPixelBufferLockBaseAddress(out, 0);
	copy_planes(out, dst, w, h, false);
	CVPixelBufferUnlockBaseAddress(out, 0);
	return out;
}

pixbuf_release :: (pb: *void) { if pb CFRelease(pb); }

#scope_module

cs_init :: (m_floats: int) -> bool {
	cs.device = MTLCreateSystemDefaultDevice();
	if !cs.device return false;
	cs.queue = msg(Id, cs.device, "newCommandQueue");
	err: Id;
	lib := msg(Id, cs.device, "newLibraryWithSource:options:error:", msg(Id, cls("NSString"), "stringWithUTF8String:", temp_c_string(kernel_source(.MSL))), cast(Id) null, *err);
	if !lib {
		if err log_error("video: segment kernel: %", to_string(msg(*u8, msg(Id, err, "localizedDescription"), "UTF8String")));
		return false;
	}
	fn := msg(Id, lib, "newFunctionWithName:", msg(Id, cls("NSString"), "stringWithUTF8String:", temp_c_string("cs_main")));
	cs.pipeline = msg(Id, cs.device, "newComputePipelineStateWithFunction:error:", fn, *err);
	msg(Void, fn, "release");
	msg(Void, lib, "release");
	if !cs.pipeline return false;
	cs.m = msg(Id, cs.device, "newBufferWithLength:options:", cast(u64) (m_floats * 4), cast(u64) 0); // shared
	return cs.m != null;
}

cs_resize :: (bytes: int) -> bool {
	if cs.f msg(Void, cs.f, "release");
	cs.f = msg(Id, cs.device, "newBufferWithLength:options:", cast(u64) bytes, cast(u64) 0);
	return cs.f != null;
}

cs_write_m :: (at: int, data: []float32) { memcpy(msg(*u8, cs.m, "contents") + at * 4, data.data, data.count * 4); }
cs_write_f :: (at: int, data: []u8) { memcpy(msg(*u8, cs.f, "contents") + at, data.data, data.count); }

cs_run :: (passes: []Pass) {
	Size :: struct { w, h, d: u64; }
	cmd := msg(Id, cs.queue, "commandBuffer");
	enc := msg(Id, cmd, "computeCommandEncoder");
	msg(Void, enc, "setComputePipelineState:", cs.pipeline);
	msg(Void, enc, "setBuffer:offset:atIndex:", cs.m, cast(u64) 0, cast(u64) 0);
	msg(Void, enc, "setBuffer:offset:atIndex:", cs.f, cast(u64) 0, cast(u64) 1);
	for * passes {
		msg(Void, enc, "setBytes:length:atIndex:", cast(*void) it.p.data, cast(u64) size_of(type_of(it.p)), cast(u64) 2);
		msg(Void, enc, "dispatchThreadgroups:threadsPerThreadgroup:", Size.{cast(u64) (it.n + 63) / 64, 1, 1}, Size.{64, 1, 1});
	}
	msg(Void, enc, "endEncoding");
	msg(Void, cmd, "commit");
	msg(Void, cmd, "waitUntilCompleted");
	cs.ok = msg(u64, cmd, "status") == 4; // MTLCommandBufferStatusCompleted
}

cs_read_f :: (at: int, out: []u8) -> bool {
	memcpy(out.data, msg(*u8, cs.f, "contents") + at, out.count);
	return cs.ok;
}

#scope_file

cs: struct {
	device, queue, pipeline: Id;
	m, f: Id;
	ok: bool;
};

// copy_planes copies NV12 between a locked CVPixelBuffer (rows with their own stride) and packed bytes.
copy_planes :: (pb: *void, packed: []u8, w: int, h: int, from_pixbuf: bool) {
	at := 0;
	for p: 0..1 {
		base := cast(*u8) CVPixelBufferGetBaseAddressOfPlane(pb, xx p);
		stride := cast(int) CVPixelBufferGetBytesPerRowOfPlane(pb, xx p);
		for y: 0..(ifx p then h / 2 else h) - 1 {
			if from_pixbuf memcpy(packed.data + at, base + y * stride, w);
			else memcpy(base + y * stride, packed.data + at, w);
			at += w;
		}
	}
}

MTLCreateSystemDefaultDevice :: () -> Id #foreign Metal;
CVPixelBufferGetPixelFormatType :: (pb: *void) -> u32 #foreign CoreVideo;
CVPixelBufferUnlockBaseAddress :: (pb: *void, flags: u64) -> s32 #foreign CoreVideo;
CVPixelBufferCreate :: (alloc: CFRef, w: u64, h: u64, fmt: u32, attrs: CFRef, out: **void) -> s32 #foreign CoreVideo;
CVPixelBufferLockBaseAddress :: (pb: *void, flags: u64) -> s32 #foreign CoreVideo;
CVPixelBufferGetBaseAddressOfPlane :: (pb: *void, plane: u64) -> *void #foreign CoreVideo;
CVPixelBufferGetBytesPerRowOfPlane :: (pb: *void, plane: u64) -> u64 #foreign CoreVideo;
kCVPixelBufferIOSurfacePropertiesKey: CFRef #elsewhere CoreVideo;
objc_autoreleasePoolPush :: () -> *void #foreign libobjc;
objc_autoreleasePoolPop :: (pool: *void) #foreign libobjc;
Metal :: #library,system,link_always "Metal";
