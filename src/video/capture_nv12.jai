// What Windows and Linux capture share: each capture runs on its own thread, which opens the device too,
// so starting one never blocks the caller. Frames are yuv.Nv12.

Capture :: struct {
	on_frame: Frame_Proc;
	on_audio: Audio_Proc; // screens: soundshare (Windows: on audio's thread, under mu)
	user: *void;
	thread: Thread;
	mu: locks.Mutex; // held around on_frame, so capture_stop knows no callback runs after it returns
	quit: bool; // atomic
	width, height, fps: int; // camera: requested; screen: output (Linux: width 0 and the cap on height until the stream starts)
	target: Screen_Target;
	error: string; // set by the thread before it gives up; a literal
	camera: bool;
	device: string; // camera_start's device id, heap ("" = the first real camera)
	got_frame: bool; // atomic
	started: Apollo_Time;
	audio: Thread; // Windows soundshare
	audio_on: bool;
}

// A synthetic source for live tests (FASTCORD_VIDEO_TEST): eight colour bars scrolling left and a white
// square moving across, at fps. Never touches a camera or the screen.
pattern_start :: (on_frame: Frame_Proc, user: *void, width := 1280, height := 720, fps := 30) -> *Capture {
	c := New(Capture);
	c.* = .{on_frame = on_frame, user = user, width = width & ~1, height = height & ~1, fps = max(fps, 1)};
	start(c, (t: *Thread) -> s64 {
		c := cast(*Capture) t.data;
		BARS :: [3]u8.[.[235, 128, 128], .[210, 16, 146], .[170, 166, 16], .[145, 54, 34], .[106, 202, 222], .[81, 90, 240], .[41, 240, 110], .[16, 128, 128]]; // Y Cb Cr
		w, h := c.width, c.height;
		next := current_time_monotonic();
		n := 0;
		while !atomic_load(*c.quit) {
			f := yuv.nv12_create(w, h);
			shift, bx, by := n * 8, (n * 12) % max(w - h / 4, 1), h / 2 - h / 8;
			uv := f.data.data + w * h;
			for y: 0..h - 1 for x: 0..w - 1 {
				bar := BARS[((x + shift) * 8 / w) % 8];
				box := x >= bx && x < bx + h / 4 && y >= by && y < by + h / 4;
				f.data[y * w + x] = ifx box then 235 else bar[0];
				if (x | y) & 1 continue;
				uv[(y / 2) * w + x] = ifx box then 128 else bar[1];
				uv[(y / 2) * w + x + 1] = ifx box then 128 else bar[2];
			}
			emit(c, f);
			yuv.nv12_release(f);
			n += 1;
			next += milliseconds_to_apollo(1000 / c.fps);
			left := to_milliseconds(next - current_time_monotonic());
			if left > 0 sleep_milliseconds(xx left);
		}
		return 0;
	});
	return c;
}

// Why the capture ended on its own ("" while it runs, or once capture_stop asked it to).
capture_error :: (c: *Capture) -> string {
	if !c || atomic_load(*c.quit) return "";
	// Some cameras (an idle NDI source) open fine, then block in ReadSample forever.
	if c.camera && !atomic_load(*c.got_frame) && current_time_monotonic() - c.started > seconds_to_apollo(8) return "The camera isn't sending any video.";
	if !thread_is_done(*c.thread) return "";
	return ifx c.error then c.error else ifx c.camera then "The camera stopped." else SCREEN_STOPPED;
}

// Waits at most for a frame callback already running. The thread itself can stay blocked for long (a
// camera's ReadSample, opening or shutting down the device), so it is freed later, once it has exited.
capture_stop :: (c: *Capture) {
	if !c return;
	locks.lock(*c.mu);
	atomic_store(*c.quit, true);
	locks.unlock(*c.mu);
	array_add(*stopped, c);
	reap();
}

// Background blur is macOS-only (Vision, blur_darwin.jai).
blur_supported :: () -> bool { return false; }
blur_background :: (pixbuf: *void) -> *void { return null; }
pixbuf_release :: (pb: *void) {}

#scope_module

stopped: [..]*Capture; // threads still exiting; UI thread only

reap :: () {
	i := 0;
	while i < stopped.count {
		c := stopped[i];
		if thread_is_done(*c.thread) && (!c.audio_on || thread_is_done(*c.audio)) {
			thread_deinit(*c.thread);
			if c.audio_on thread_deinit(*c.audio);
			free(c.device);
			free(c);
			array_unordered_remove_by_index(*stopped, i);
		} else {
			i += 1;
		}
	}
}

start :: (c: *Capture, proc: Thread_Proc) {
	reap();
	c.started = current_time_monotonic();
	thread_init(*c.thread, proc);
	c.thread.data = c;
	thread_start(*c.thread);
}

emit :: (c: *Capture, f: *yuv.Nv12) {
	locks.lock(*c.mu);
	if !atomic_load(*c.quit) c.on_frame(c.user, f, f.width, f.height);
	atomic_store(*c.got_frame, true);
	locks.unlock(*c.mu);
	reset_temporary_storage();
}
