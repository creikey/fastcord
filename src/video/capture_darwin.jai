// Camera capture (AVFoundation) and screen/window capture (ScreenCaptureKit), through the ObjC runtime.

Capture :: struct {
	on_frame: Frame_Proc;
	user: *void;
	ctx: #Context;
	ts: Temporary_Storage;
	frames: *void;   // serial dispatch queue the frame callbacks run on
	delegate: Id;    // our FCVideo*Output instance; its indexed ivar points back here
	// camera
	control: *void;  // serial queue for startRunning/stopRunning, which block
	session: Id;
	output: Id;
	// screen
	stream: Id;
	stop_block: Block;
	mu: locks.Mutex;
	cv: locks.Cond;
	stopped: bool;
	// test pattern (pattern_darwin.jai)
	pattern: *Thread;
	pattern_stop: bool;
	pattern_w, pattern_h, pattern_fps: int;
}

camera_supported :: () -> bool {
	pool := objc_autoreleasePoolPush();
	defer objc_autoreleasePoolPop(pool);
	return msg(Id, cls("AVCaptureDevice"), "defaultDeviceWithMediaType:", AVMediaTypeVideo) != null;
}

camera_start :: (on_frame: Frame_Proc, user: *void, width := 1280, height := 720, fps := 30) -> *Capture {
	pool := objc_autoreleasePoolPush();
	defer objc_autoreleasePoolPop(pool);
	// 1 restricted, 2 denied; 0 (not determined) prompts when the session starts.
	status := msg(s64, cls("AVCaptureDevice"), "authorizationStatusForMediaType:", AVMediaTypeVideo);
	if status == 1 || status == 2 return null;
	device := msg(Id, cls("AVCaptureDevice"), "defaultDeviceWithMediaType:", AVMediaTypeVideo);
	if !device return null;
	err: Id;
	input := msg(Id, cls("AVCaptureDeviceInput"), "deviceInputWithDevice:error:", device, *err);
	if !input return null;

	session := objc.new_obj("AVCaptureSession");
	msg(Void, session, "beginConfiguration");
	preset := ifx height >= 1080 then AVCaptureSessionPreset1920x1080 else ifx height >= 720 then AVCaptureSessionPreset1280x720 else AVCaptureSessionPreset640x480;
	if !msg(bool, session, "canSetSessionPreset:", preset) preset = AVCaptureSessionPresetHigh;
	msg(Void, session, "setSessionPreset:", preset);
	if !msg(bool, session, "canAddInput:", input) {
		msg(Void, session, "release");
		return null;
	}
	msg(Void, session, "addInput:", input);

	c := new_capture(on_frame, user, "FCVideoCameraOutput", "captureOutput:didOutputSampleBuffer:fromConnection:", "v@:@^{opaqueCMSampleBuffer=}@", xx camera_frame);
	c.session = session;
	c.output = objc.new_obj("AVCaptureVideoDataOutput");
	pf := cf_s32(cast(s32) fourcc("420v"));
	settings := cf_dict(.[kCVPixelBufferPixelFormatTypeKey], .[pf]);
	msg(Void, c.output, "setVideoSettings:", settings);
	CFRelease(settings);
	CFRelease(pf);
	msg(Void, c.output, "setAlwaysDiscardsLateVideoFrames:", true);
	msg(Void, c.output, "setSampleBufferDelegate:queue:", c.delegate, c.frames);
	if !msg(bool, session, "canAddOutput:", c.output) {
		msg(Void, session, "commitConfiguration");
		capture_stop(c);
		return null;
	}
	msg(Void, session, "addOutput:", c.output);
	msg(Void, session, "commitConfiguration");

	// Cap the frame rate only when the active format supports it: setting an unsupported duration throws.
	if msg(bool, device, "lockForConfiguration:", *err) {
		ranges := msg(Id, msg(Id, device, "activeFormat"), "videoSupportedFrameRateRanges");
		for 0..msg(s64, ranges, "count") - 1 {
			r := msg(Id, ranges, "objectAtIndex:", cast(u64) it);
			if cast(float64) fps >= msg(float64, r, "minFrameRate") && cast(float64) fps <= msg(float64, r, "maxFrameRate") {
				msg(Void, device, "setActiveVideoMinFrameDuration:", CMTime.{value = 1, timescale = cast(s32) fps, flags = 1});
				break;
			}
		}
		msg(Void, device, "unlockForConfiguration");
	}

	c.control = dispatch_queue_create("fastcord.camera.control", null);
	dispatch_async_f(c.control, session, (s: *void) #c_call { msg(Void, s, "startRunning"); });
	return c;
}

screen_supported :: () -> bool { return cls("SCShareableContent") != null; }

screen_targets_refresh :: () {
	pool := objc_autoreleasePoolPush();
	defer objc_autoreleasePoolPop(pool);
	{
		locks.guard(*targets.mu);
		clear_targets();
		targets.ready = false;
	}
	if !targets.ts.data {
		init_callback_context(*targets.ctx, *targets.ts);
		targets.block = make_block(xx content_ready, null);
	}
	msg(Void, cls("SCShareableContent"), "getShareableContentExcludingDesktopWindows:onScreenWindowsOnly:completionHandler:", true, true, *targets.block);
}

screen_targets :: () -> []Screen_Target, ready: bool {
	locks.guard(*targets.mu);
	return targets.list, targets.ready;
}

screen_start :: (target: Screen_Target, on_frame: Frame_Proc, user: *void, fps := 30, max_height := 1080) -> *Capture {
	pool := objc_autoreleasePoolPush();
	defer objc_autoreleasePoolPop(pool);
	source: Id;
	{
		locks.guard(*targets.mu);
		for targets.list if it.is_window == target.is_window && it.id == target.id source = targets.objs[it_index];
	}
	if !source return null;
	filter := msg(Id, cls("SCContentFilter"), "alloc");
	if target.is_window filter = msg(Id, filter, "initWithDesktopIndependentWindow:", source);
	else filter = msg(Id, filter, "initWithDisplay:excludingWindows:", source, msg(Id, cls("NSArray"), "array"));
	defer msg(Void, filter, "release");

	// Target sizes are in points; capture at pixel resolution, capped to max_height.
	scale := 1.0;
	if msg(bool, filter, "respondsToSelector:", sel("pointPixelScale")) scale = msg(float32, filter, "pointPixelScale");
	w, h := target.width * scale, target.height * scale;
	if h > xx max_height { w *= max_height / h; h = xx max_height; }
	config := objc.new_obj("SCStreamConfiguration");
	defer msg(Void, config, "release");
	msg(Void, config, "setWidth:", cast(u64) ((cast(int) w) & ~1));
	msg(Void, config, "setHeight:", cast(u64) ((cast(int) h) & ~1));
	msg(Void, config, "setMinimumFrameInterval:", CMTime.{value = 1, timescale = cast(s32) fps, flags = 1});
	msg(Void, config, "setPixelFormat:", fourcc("420v"));
	msg(Void, config, "setShowsCursor:", true);
	msg(Void, config, "setQueueDepth:", cast(s64) 5);

	c := new_capture(on_frame, user, "FCVideoScreenOutput", "stream:didOutputSampleBuffer:ofType:", "v@:@^{opaqueCMSampleBuffer=}q", xx screen_frame);
	c.stream = msg(Id, msg(Id, cls("SCStream"), "alloc"), "initWithFilter:configuration:delegate:", filter, config, cast(Id) null);
	err: Id;
	if !c.stream || !msg(bool, c.stream, "addStreamOutput:type:sampleHandlerQueue:error:", c.delegate, cast(s64) 0, c.frames, *err) {
		if c.stream { msg(Void, c.stream, "release"); c.stream = null; }
		capture_stop(c);
		return null;
	}
	msg(Void, c.stream, "startCaptureWithCompletionHandler:", *noop_block);
	return c;
}

capture_stop :: (c: *Capture) {
	if !c return;
	if c.pattern {
		atomic_store(*c.pattern_stop, true);
		thread_is_done(c.pattern, -1);
		thread_deinit(c.pattern);
		free(c.pattern);
		free_callback_context(*c.ts);
		free(c);
		return;
	}
	pool := objc_autoreleasePoolPush();
	defer objc_autoreleasePoolPop(pool);
	if c.session {
		if c.control {
			dispatch_sync_f(c.control, c.session, (s: *void) #c_call { msg(Void, s, "stopRunning"); });
			dispatch_release(c.control);
		}
		msg(Void, c.output, "setSampleBufferDelegate:queue:", cast(Id) null, cast(*void) null);
		msg(Void, c.session, "release");
	}
	if c.output msg(Void, c.output, "release");
	stopped := true;
	if c.stream {
		c.stop_block = make_block(xx stream_stopped, c);
		msg(Void, c.stream, "stopCaptureWithCompletionHandler:", *c.stop_block);
		locks.lock(*c.mu);
		while !c.stopped if !locks.cond_wait_with_timeout(*c.cv, *c.mu, 2000) break;
		stopped = c.stopped;
		locks.unlock(*c.mu);
		err: Id;
		msg(bool, c.stream, "removeStreamOutput:type:error:", c.delegate, cast(s64) 0, *err);
		msg(Void, c.stream, "release");
	}
	// Frame callbacks already queued run before this returns; none start after.
	dispatch_sync_f(c.frames, null, (p: *void) #c_call {});
	dispatch_release(c.frames);
	msg(Void, c.delegate, "release");
	// A stop handler that never came may still arrive and touch c: leak it rather than free under it.
	if !stopped return;
	free_callback_context(*c.ts);
	free(c);
}

#scope_file

// An Objective-C block literal built by hand (clang's Block ABI). BLOCK_IS_GLOBAL makes Block_copy and
// Block_release no-ops, so the framework uses our memory as is and `user`, past the ABI fields, survives.
Block :: struct {
	isa: *void;
	flags: s32;
	reserved: s32;
	invoke: *void;
	descriptor: *Block_Descriptor;
	user: *void;
}
Block_Descriptor :: struct { reserved, size: u64; }
block_descriptor := Block_Descriptor.{0, size_of(Block)};
BLOCK_IS_GLOBAL :: 1 << 28;

make_block :: (invoke: *void, user: *void) -> Block {
	return .{isa = cast(*void) _NSConcreteGlobalBlock, flags = BLOCK_IS_GLOBAL, invoke = invoke, descriptor = *block_descriptor, user = user};
}

noop_block: Block;

new_capture :: (on_frame: Frame_Proc, user: *void, class_name: *u8, selector: *u8, types: *u8, imp: *void) -> *Capture {
	klass := cls(class_name);
	if !klass {
		klass = objc.allocate_class(cls("NSObject"), class_name);
		objc.add_method(klass, selector, imp, types);
		objc.register_class(klass);
	}
	if !noop_block.isa noop_block = make_block(xx (b: *Block, err: Id) #c_call {}, null);
	c := New(Capture);
	c.on_frame, c.user = on_frame, user;
	init_callback_context(*c.ctx, *c.ts);
	c.frames = dispatch_queue_create("fastcord.video.frames", null);
	c.delegate = class_createInstance(klass, size_of(*Capture));
	(cast(**Capture) object_getIndexedIvars(c.delegate)).* = c;
	return c;
}

deliver :: (self: Id, sample: CFRef) #c_call {
	c := (cast(**Capture) object_getIndexedIvars(self)).*;
	pb := CMSampleBufferGetImageBuffer(sample);
	if !pb return;
	push_context c.ctx {
		c.on_frame(c.user, pb, cast(int) CVPixelBufferGetWidth(pb), cast(int) CVPixelBufferGetHeight(pb));
		reset_temporary_storage();
	}
}

camera_frame :: (self: Id, cmd: *void, output: Id, sample: CFRef, connection: Id) #c_call { deliver(self, sample); }

screen_frame :: (self: Id, cmd: *void, stream: Id, sample: CFRef, type: s64) #c_call {
	if type != 0 return; // SCStreamOutputTypeScreen
	// Idle, blank and suspended frames carry no new image.
	atts := CMSampleBufferGetSampleAttachmentsArray(sample, false);
	if !atts || CFArrayGetCount(atts) < 1 return;
	n := CFDictionaryGetValue(CFArrayGetValueAtIndex(atts, 0), SCStreamFrameInfoStatus);
	status: s32 = -1;
	if !n || !CFNumberGetValue(n, 3, *status) || status != 0 return; // SCFrameStatusComplete
	deliver(self, sample);
}

stream_stopped :: (b: *Block, err: Id) #c_call {
	c := cast(*Capture) b.user;
	push_context c.ctx { // the frame queue may be using c.ts concurrently: no temp here
		locks.lock(*c.mu);
		c.stopped = true;
		locks.cond_signal(*c.cv);
		locks.unlock(*c.mu);
	}
}

// The shareable-content listing. Written by content_ready on an arbitrary queue; list and its strings stay
// put from ready until the next refresh, so screen_targets can hand out the slice.
targets: struct {
	mu: locks.Mutex;
	list: [..]Screen_Target;
	objs: [..]Id; // retained SCDisplay / SCWindow, parallel to list
	ready: bool;
	block: Block;
	ctx: #Context;
	ts: Temporary_Storage;
};

clear_targets :: () {
	for targets.list free(it.name);
	for targets.objs msg(Void, it, "release");
	targets.list.count = 0;
	targets.objs.count = 0;
}

content_ready :: (b: *Block, content: Id, err: Id) #c_call {
	push_context targets.ctx {
		defer reset_temporary_storage();
		locks.guard(*targets.mu);
		if targets.ready || !content return; // a later refresh's answer already landed
		displays := msg(Id, content, "displays");
		for 0..msg(s64, displays, "count") - 1 {
			d := msg(Id, displays, "objectAtIndex:", cast(u64) it);
			array_add(*targets.list, .{id = msg(u32, d, "displayID"), name = sprint("Screen %", it + 1),
				width = msg(s64, d, "width"), height = msg(s64, d, "height")});
			array_add(*targets.objs, msg(Id, d, "retain"));
		}
		me := getpid();
		windows := msg(Id, content, "windows");
		for 0..msg(s64, windows, "count") - 1 {
			win := msg(Id, windows, "objectAtIndex:", cast(u64) it);
			title := msg(Id, win, "title");
			app := msg(Id, win, "owningApplication");
			if !title || !msg(s64, title, "length") || msg(s64, win, "windowLayer") != 0 || !msg(bool, win, "isOnScreen") continue;
			if app && msg(s32, app, "processID") == me continue;
			app_name := ifx app then to_string(msg(*u8, msg(Id, app, "applicationName"), "UTF8String")) else "";
			title_s := to_string(msg(*u8, title, "UTF8String"));
			frame := msg(CGRect, win, "frame");
			array_add(*targets.list, .{is_window = true, id = msg(u32, win, "windowID"),
				name = ifx app_name then sprint("% — %", app_name, title_s) else copy_string(title_s),
				width = cast(int) frame.w, height = cast(int) frame.h});
			array_add(*targets.objs, msg(Id, win, "retain"));
		}
		targets.ready = true;
	}
}

CGRect :: struct { x, y, w, h: float64; }

objc_autoreleasePoolPush :: () -> *void #foreign libobjc;
objc_autoreleasePoolPop :: (pool: *void) #foreign libobjc;
class_createInstance :: (c: Id, extra: u64) -> Id #foreign libobjc;
object_getIndexedIvars :: (o: Id) -> *void #foreign libobjc;
_NSConcreteGlobalBlock :: () #foreign libSystem;
dispatch_queue_create :: (label: *u8, attr: *void) -> *void #foreign libSystem;
dispatch_async_f :: (q: *void, ctx: *void, f: (ctx: *void) #c_call) #foreign libSystem;
dispatch_sync_f :: (q: *void, ctx: *void, f: (ctx: *void) #c_call) #foreign libSystem;
dispatch_release :: (o: *void) #foreign libSystem;
getpid :: () -> s32 #foreign libSystem;
AVMediaTypeVideo: Id #elsewhere AVFoundation;
AVCaptureSessionPreset640x480: Id #elsewhere AVFoundation;
AVCaptureSessionPreset1280x720: Id #elsewhere AVFoundation;
AVCaptureSessionPreset1920x1080: Id #elsewhere AVFoundation;
AVCaptureSessionPresetHigh: Id #elsewhere AVFoundation;
SCStreamFrameInfoStatus: CFRef #elsewhere ScreenCaptureKit;
