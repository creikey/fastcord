// Video for calls and Go Live: camera and screen capture (NV12), a realtime H.264/H.265 encoder that
// emits Annex B, and a software VP8 encoder (encode_vp8.jai, every platform). macOS (AVFoundation, ScreenCaptureKit, VideoToolbox), Windows (Media Foundation, DXGI
// desktop duplication; H.264 only) and Linux (V4L2 cameras, openh264; H.264 only, no screen capture yet).

// A captured frame, valid only during the call: macOS a CVPixelBuffer ('420v' or '420f'), Windows an
// yuv.Nv12. Called on the capture's queue or thread with a temp that is reset after each call.
Frame_Proc :: #type (user: *void, pixbuf: *void, width: int, height: int);

// Annex B with a 4-byte start code before every NAL; keyframes lead with the parameter sets (H.264: SPS,
// PPS; H.265: VPS, SPS, PPS). Valid only during the call; called on the encoder's thread (Windows: inside
// encoder_encode, on its caller's) with a temp that thread resets.
Encoded_Proc :: #type (user: *void, annexb: []u8, keyframe: bool, pts_90k: u32);

// A screen capture's sound (soundshare), mono 48 kHz float, on the capture's queue with a temp reset after.
Audio_Proc :: #type (user: *void, pcm: []float32);

Video_Codec :: enum u8 { H264; H265; }

SUPPORTED :: OS == .MACOS || OS == .WINDOWS || OS == .LINUX; // capture and encoding exist on this platform
SOUNDSHARE :: OS == .MACOS; // screen_start can capture the shared screen's sound (macOS 13+)

// A camera for the picker. id: AVCaptureDevice's uniqueID, the Media Foundation symbolic link, or the
// /dev/video path; camera_start takes it ("" = the default camera).
Camera_Device :: struct {
	id: string;
	name: string;
}

// cameras_refresh lists the cameras on a thread of its own, since the OS can take a while; cameras has the
// last list (ready once one is in).
cameras_refresh :: () {
	locks.guard(*cams.mu);
	if cams.busy return;
	if cams.started { thread_is_done(*cams.thread, -1); thread_deinit(*cams.thread); }
	cams.busy, cams.started = true, true;
	thread_init(*cams.thread, (t: *Thread) -> s64 {
		list := list_cameras();
		locks.guard(*cams.mu);
		for cams.list { free(it.id); free(it.name); }
		array_free(cams.list);
		cams.list, cams.ready, cams.busy = list, true, false;
		return 0;
	});
	thread_start(*cams.thread);
}

cameras :: (allocator := temp) -> []Camera_Device, ready: bool {
	locks.guard(*cams.mu);
	out := NewArray(cams.list.count, Camera_Device,, allocator);
	for cams.list out[it_index] = .{copy_string(it.id,, allocator), copy_string(it.name,, allocator)};
	return out, cams.ready;
}

cams: struct {
	mu: locks.Mutex;
	thread: Thread;
	started, busy, ready: bool;
	list: [..]Camera_Device; // heap
};

Screen_Target :: struct {
	is_window: bool;
	id: u32; // CGDirectDisplayID or CGWindowID; Windows: DXGI adapter << 8 | output
	name: string;
	width, height: int; // points
	x, y: int; // Windows: the screen's place on the desktop
}

// A target's thumbnail, THUMB_W wide: RGBA, premultiplied, in allocator; empty until it's taken (macOS:
// asynchronously after screen_targets is ready) or where there is none.
THUMB_W :: 320;
screen_thumb :: (t: Screen_Target, allocator := temp) -> []u8, w: int, h: int {
	locks.guard(*thumbs.mu);
	for thumbs.list if it.is_window == t.is_window && it.id == t.id return array_copy(it.rgba,, allocator), it.w, it.h;
	return .[], 0, 0;
}

thumbs: struct {
	mu: locks.Mutex;
	gen: int; // bumped by each refresh: older thumbnails still on their way are dropped
	list: [..]struct { is_window: bool; id: u32; rgba: []u8; w, h: int; };
};

thumbs_clear :: () {
	locks.guard(*thumbs.mu);
	thumbs.gen += 1;
	for thumbs.list array_free(it.rgba);
	thumbs.list.count = 0;
}

thumb_add :: (is_window: bool, id: u32, rgba: []u8, w: int, h: int) {
	locks.guard(*thumbs.mu);
	array_add(*thumbs.list, .{is_window, id, rgba, w, h});
}

#if OS == .MACOS {
	#load "capture_darwin.jai";
	#load "encode_darwin.jai";
	#load "pattern_darwin.jai";
	#load "blur_darwin.jai";
} else #if OS == .WINDOWS {
	#load "capture_nv12.jai";
	#load "capture_windows.jai";
	#load "encode_windows.jai";
} else #if OS == .LINUX {
	#load "capture_nv12.jai";
	#load "capture_linux.jai";
	#load "encode_linux.jai";
}
#load "encode_vp8.jai";

#scope_module

#import "Basic";
#import "String";
#import "Thread";
#import "Atomics";
locks :: #import "locks";

#if OS != .MACOS yuv :: #import "yuv";

#if OS == .WINDOWS {
	#import "Windows";
	#import "Windows_Utf8";
	#import "d3d11";
	#import "dxgi";
	mf :: #import "mf";
}

#if OS == .LINUX {
	#import "POSIX";
	vendor :: #library,no_dll "../../build/fc_vendor";
}

#if OS == .MACOS {
	objc :: #import "platform_objc";
	msg :: objc.msg;
	cls :: objc.cls;
	sel :: objc.sel;
	Id :: objc.Id;
	Void :: objc.Void;
	libSystem :: #system_library "libSystem";
	libobjc :: #system_library "libobjc";
	CoreFoundation :: #library,system,link_always "CoreFoundation";
	CoreMedia :: #library,system,link_always "CoreMedia";
	CoreVideo :: #library,system,link_always "CoreVideo";
	VideoToolbox :: #library,system,link_always "VideoToolbox";
	AVFoundation :: #library,system,link_always "AVFoundation";
	ScreenCaptureKit :: #library,system,link_always "ScreenCaptureKit";
	CoreGraphics :: #library,system,link_always "CoreGraphics";

	CFRef :: *void;
	OSStatus :: s32;

	CMTime :: struct {
		value: s64;
		timescale: s32;
		flags: u32; // 1 = valid
		epoch: s64;
	}

	fourcc :: (s: string) -> u32 {
		return ((cast(u32) s[0]) << 24) | ((cast(u32) s[1]) << 16) | ((cast(u32) s[2]) << 8) | (cast(u32) s[3]);
	}

	// Callbacks arrive on OS threads while the creating thread keeps using its own temp, so each object
	// owns a temporary storage and its callbacks run with it.
	init_callback_context :: (ctx: *#Context, ts: *Temporary_Storage) {
		SIZE :: 256 * 1024;
		ts.data = alloc(SIZE);
		ts.size = SIZE;
		ctx.* = context;
		ctx.temporary_storage = ts;
		// The creator's stack trace lives on its stack: code run under this context would write the
		// current line into those frames (debug info), corrupting the creating thread's stack.
		ctx.stack_trace = null;
	}

	free_callback_context :: (ts: *Temporary_Storage) {
		reset_temporary_storage(ts);
		free(ts.data);
	}

	cf_dict :: (keys: []CFRef, vals: []CFRef) -> CFRef {
		return CFDictionaryCreate(null, keys.data, vals.data, keys.count, *kCFTypeDictionaryKeyCallBacks, *kCFTypeDictionaryValueCallBacks);
	}

	cf_s32 :: (v: s32) -> CFRef { return CFNumberCreate(null, 3, *v); } // kCFNumberSInt32Type

	CFRelease :: (cf: CFRef) #foreign CoreFoundation;
	CFRetain :: (cf: CFRef) -> CFRef #foreign CoreFoundation;
	CFDictionaryCreate :: (alloc: CFRef, keys: *CFRef, values: *CFRef, n: int, kcb: *void, vcb: *void) -> CFRef #foreign CoreFoundation;
	CFDictionaryGetValue :: (d: CFRef, key: CFRef) -> CFRef #foreign CoreFoundation;
	CFArrayCreate :: (alloc: CFRef, values: *CFRef, n: int, cb: *void) -> CFRef #foreign CoreFoundation;
	CFArrayGetCount :: (a: CFRef) -> int #foreign CoreFoundation;
	CFArrayGetValueAtIndex :: (a: CFRef, i: int) -> CFRef #foreign CoreFoundation;
	CFNumberCreate :: (alloc: CFRef, type: int, value: *void) -> CFRef #foreign CoreFoundation;
	CFNumberGetValue :: (n: CFRef, type: int, value: *void) -> bool #foreign CoreFoundation;
	kCFTypeDictionaryKeyCallBacks: [6]u64 #elsewhere CoreFoundation;
	kCFTypeDictionaryValueCallBacks: [5]u64 #elsewhere CoreFoundation;
	kCFTypeArrayCallBacks: [5]u64 #elsewhere CoreFoundation;
	kCFBooleanTrue: CFRef #elsewhere CoreFoundation;
	kCFBooleanFalse: CFRef #elsewhere CoreFoundation;
	CMSampleBufferGetImageBuffer :: (sb: CFRef) -> CFRef #foreign CoreMedia;
	CMSampleBufferGetSampleAttachmentsArray :: (sb: CFRef, create: bool) -> CFRef #foreign CoreMedia;
	CVPixelBufferGetWidth :: (pb: CFRef) -> u64 #foreign CoreVideo;
	CVPixelBufferGetHeight :: (pb: CFRef) -> u64 #foreign CoreVideo;
	kCVPixelBufferPixelFormatTypeKey: CFRef #elsewhere CoreVideo;
}
