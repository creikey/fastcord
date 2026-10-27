// Video for calls and Go Live: camera and screen capture (NV12 CVPixelBuffers) and a realtime H.264/H.265
// encoder that emits Annex B. macOS only for now; elsewhere every entry point reports unsupported.

// A captured frame: a CVPixelBuffer (NV12, '420v' or '420f'), valid only during the call. Called on a
// capture queue with a context whose temp is the capture's own (reset after each call).
Frame_Proc :: #type (user: *void, pixbuf: *void, width: int, height: int);

// Annex B with a 4-byte start code before every NAL; keyframes lead with the parameter sets (H.264: SPS,
// PPS; H.265: VPS, SPS, PPS). Valid only during the call; called on the encoder's thread with the
// encoder's own temp.
Encoded_Proc :: #type (user: *void, annexb: []u8, keyframe: bool, pts_90k: u32);

Video_Codec :: enum u8 { H264; H265; }

SUPPORTED :: OS == .MACOS; // capture and encoding exist on this platform

Screen_Target :: struct {
	is_window: bool;
	id: u32; // CGDirectDisplayID or CGWindowID
	name: string;
	width, height: int; // points
}

#if OS == .MACOS {
	#load "capture_darwin.jai";
	#load "encode_darwin.jai";
	#load "pattern_darwin.jai";
} else {
	#load "none.jai";
}

#scope_module

#import "Basic";
#import "String";
#import "Thread";
#import "Atomics";
locks :: #import "locks";

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
