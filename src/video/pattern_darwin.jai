// A synthetic source for live tests (FASTCORD_VIDEO_TEST): moving bars and a box at fps, as NV12
// CVPixelBuffers, on its own thread. Never touches a camera or the screen, so no permission prompts.

pattern_start :: (on_frame: Frame_Proc, user: *void, width := 1280, height := 720, fps := 30) -> *Capture {
	c := New(Capture);
	c.on_frame, c.user = on_frame, user;
	c.pattern_w, c.pattern_h, c.pattern_fps = width & ~1, height & ~1, max(fps, 1);
	init_callback_context(*c.ctx, *c.ts);
	c.pattern = New(Thread);
	thread_init(c.pattern, (t: *Thread) -> s64 {
		c := cast(*Capture) t.data;
		empty := cf_dict(.[], .[]);
		attrs := cf_dict(.[kCVPixelBufferIOSurfacePropertiesKey], .[empty]);
		defer { CFRelease(attrs); CFRelease(empty); }
		next := current_time_monotonic();
		n := 0;
		while !atomic_load(*c.pattern_stop) {
			pb: CFRef;
			if CVPixelBufferCreate(null, xx c.pattern_w, xx c.pattern_h, fourcc("420v"), attrs, *pb) == 0 {
				paint(pb, n);
				push_context c.ctx {
					c.on_frame(c.user, pb, c.pattern_w, c.pattern_h);
					reset_temporary_storage();
				}
				CFRelease(pb);
			}
			n += 1;
			next += milliseconds_to_apollo(1000 / c.pattern_fps);
			left := to_milliseconds(next - current_time_monotonic());
			if left > 0 sleep_milliseconds(xx left);
		}
		return 0;
	});
	c.pattern.data = c;
	thread_start(c.pattern);
	return c;
}

#scope_file

// Eight vertical colour bars scrolling left, and a white square bouncing across.
paint :: (pb: CFRef, n: int) {
	BARS :: [3]u8.[.[235, 128, 128], .[210, 16, 146], .[170, 166, 16], .[145, 54, 34], .[106, 202, 222], .[81, 90, 240], .[41, 240, 110], .[16, 128, 128]]; // Y Cb Cr
	CVPixelBufferLockBaseAddress(pb, 0);
	defer CVPixelBufferUnlockBaseAddress(pb, 0);
	w := cast(int) CVPixelBufferGetWidth(pb);
	h := cast(int) CVPixelBufferGetHeight(pb);
	shift := n * 8;
	bx := (n * 12) % max(w - h / 4, 1);
	by := h / 2 - h / 8;
	for plane: 0..1 {
		base := cast(*u8) CVPixelBufferGetBaseAddressOfPlane(pb, xx plane);
		stride := cast(int) CVPixelBufferGetBytesPerRowOfPlane(pb, xx plane);
		sub := plane + 1; // the CbCr plane is half size
		for y: 0..h / sub - 1 {
			row := base + y * stride;
			for x: 0..w / sub - 1 {
				px, py := x * sub, y * sub;
				bar := BARS[((px + shift) * 8 / w) % 8];
				box := px >= bx && px < bx + h / 4 && py >= by && py < by + h / 4;
				if plane == 0 row[x] = ifx box then 235 else bar[0];
				else { row[2 * x] = ifx box then 128 else bar[1]; row[2 * x + 1] = ifx box then 128 else bar[2]; }
			}
		}
	}
}

CVPixelBufferCreate :: (alloc: CFRef, w: u64, h: u64, fmt: u32, attrs: CFRef, out: *CFRef) -> s32 #foreign CoreVideo;
CVPixelBufferLockBaseAddress :: (pb: CFRef, flags: u64) -> s32 #foreign CoreVideo;
CVPixelBufferUnlockBaseAddress :: (pb: CFRef, flags: u64) -> s32 #foreign CoreVideo;
CVPixelBufferGetBaseAddressOfPlane :: (pb: CFRef, plane: u64) -> *void #foreign CoreVideo;
CVPixelBufferGetBytesPerRowOfPlane :: (pb: CFRef, plane: u64) -> u64 #foreign CoreVideo;
kCVPixelBufferIOSurfacePropertiesKey: CFRef #elsewhere CoreVideo;
