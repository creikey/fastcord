// Round-trips synthetic NV12 frames through video's encoder and back through VideoToolbox's decoder.
// jai build.jai - run src/tests/video_encode.jai && build/video_encode
#import "Basic";
video :: #import "video";
locks :: #import "locks";

W :: 640;
H :: 360;
FRAMES :: 60;

Packet :: struct { data: []u8; keyframe: bool; pts: u32; }

Run :: struct {
	mu: locks.Mutex;
	packets: [..]Packet;
}

failures := 0;
expect :: (ok: bool, what: string, args: ..Any) {
	if ok return;
	failures += 1;
	print("FAIL: %\n", tprint(what, ..args));
}

on_output :: (user: *void, annexb: []u8, keyframe: bool, pts_90k: u32) {
	r := cast(*Run) user;
	locks.guard(*r.mu);
	array_add(*r.packets, .{array_copy(annexb), keyframe, pts_90k});
}

make_frame :: (w: int, h: int, t: int, noise := false) -> CFRef {
	empty := dict(.[], .[]);
	attrs := dict(.[kCVPixelBufferIOSurfacePropertiesKey], .[empty]);
	pb: CFRef;
	CVPixelBufferCreate(null, cast(u64) w, cast(u64) h, video_fourcc("420v"), attrs, *pb);
	CFRelease(attrs);
	CFRelease(empty);
	CVPixelBufferLockBaseAddress(pb, 0);
	for plane: 0..1 {
		base := cast(*u8) CVPixelBufferGetBaseAddressOfPlane(pb, cast(u64) plane);
		stride := cast(int) CVPixelBufferGetBytesPerRowOfPlane(pb, cast(u64) plane);
		ph := cast(int) CVPixelBufferGetHeightOfPlane(pb, cast(u64) plane);
		pw := cast(int) CVPixelBufferGetWidthOfPlane(pb, cast(u64) plane) * (plane + 1);
		for y: 0..ph-1 for x: 0..pw-1 base[y * stride + x] = cast,trunc(u8) ifx plane == 0 then 16 + (x + y + t * 4) % 220 else 128 + (x / 2 + t) % 32;
		if noise for y: 0..ph-1 for x: 0..pw-1 base[y * stride + x] ^= cast,trunc(u8) (((x * 73856093) ^ (y * 19349663) ^ (t * 83492791)) >> 7) & 0x07;
	}
	CVPixelBufferUnlockBaseAddress(pb, 0);
	return pb;
}

nal_type :: (codec: video.Video_Codec, b: u8) -> int { return ifx codec == .H264 then b & 0x1f else (b >> 1) & 0x3f; }

// Annex B -> NAL payloads (4-byte start codes only, as the encoder promises).
split_nals :: (data: []u8) -> [..][]u8 {
	out: [..][]u8;
	i := 0;
	starts: [..]int;
	starts.allocator = temp;
	while i + 4 <= data.count {
		if data[i] == 0 && data[i+1] == 0 && data[i+2] == 0 && data[i+3] == 1 { array_add(*starts, i + 4); i += 4; }
		else i += 1;
	}
	for starts {
		end := ifx it_index + 1 < starts.count then starts[it_index + 1] - 4 else data.count;
		array_add(*out, array_view(data, it, end - it));
	}
	return out;
}

Decoded :: struct { count: int; bad_size: int; errors: int; }

decoded_frame :: (ref: *void, frame_ref: *void, status: s32, flags: u32, image: CFRef, pts: CMTime, dur: CMTime) #c_call {
	d := cast(*Decoded) ref;
	if status != 0 || !image { d.errors += 1; return; }
	d.count += 1;
	if CVPixelBufferGetWidth(image) != W || CVPixelBufferGetHeight(image) != H d.bad_size += 1;
}

run :: (codec: video.Video_Codec) {
	print("--- %\n", codec);
	r := New(Run);
	e := video.encoder_create(codec, W, H, 30, 1_000_000, on_output, r);
	expect(e != null, "encoder_create");
	if !e return;
	for t: 0..FRAMES-1 {
		// One frame at another size: the encoder must scale it, not crash.
		pb := ifx t == 45 then make_frame(1280, 720, t) else make_frame(W, H, t);
		video.encoder_encode(e, pb, cast(u32) (t * 3000), force_keyframe = t == 30);
		CFRelease(pb);
	}
	video.encoder_destroy(e);

	p := r.packets;
	print("% packets, keyframes at:", p.count);
	for p if it.keyframe print(" %", it.pts / 3000);
	print("\n");
	expect(p.count >= FRAMES - 2 && p.count <= FRAMES, "output count % (want ~%)", p.count, FRAMES);
	if !p.count return;
	expect(p[0].keyframe, "first output is a keyframe");
	param_types: []int = int.[7, 8];
	idr_types: []int = int.[5];
	if codec == .H265 { param_types = int.[32, 33, 34]; idr_types = int.[19, 20]; }
	for pk: p {
		expect(pk.data.count > 4 && pk.data[0] == 0 && pk.data[1] == 0 && pk.data[2] == 0 && pk.data[3] == 1, "packet % starts with a 4-byte start code", it_index);
		nals := split_nals(pk.data);
		if !pk.keyframe continue;
		for param_types expect(nals.count > it_index && nal_type(codec, nals[it_index][0]) == it, "keyframe % NAL % is type %", pk.pts / 3000, it_index, it);
		has_idr := false;
		for nals for t: idr_types if nal_type(codec, it[0]) == t has_idr = true;
		expect(has_idr, "keyframe % has an IDR NAL", pk.pts / 3000);
	}
	forced := false;
	for p if it.pts == 30 * 3000 forced = it.keyframe;
	expect(forced, "forced keyframe at frame 30");

	// Decode: parameter sets from the first keyframe, then every packet as AVCC/HVCC.
	nals := split_nals(p[0].data);
	ptrs: [3]*u8;
	sizes: [3]u64;
	for 0..param_types.count-1 { ptrs[it] = nals[it].data; sizes[it] = cast(u64) nals[it].count; }
	fmt: CFRef;
	st := ifx codec == .H264
		then CMVideoFormatDescriptionCreateFromH264ParameterSets(null, 2, ptrs.data, sizes.data, 4, *fmt)
		else CMVideoFormatDescriptionCreateFromHEVCParameterSets(null, 3, ptrs.data, sizes.data, 4, null, *fmt);
	expect(st == 0, "format description from parameter sets (%)", st);
	if st != 0 return;
	d: Decoded;
	cb := VTDecompressionOutputCallbackRecord.{decoded_frame, *d};
	session: CFRef;
	st = VTDecompressionSessionCreate(null, fmt, null, null, *cb, *session);
	expect(st == 0, "decompression session (%)", st);
	if st != 0 return;
	for p {
		avcc: [..]u8;
		for n: split_nals(it.data) {
			if (codec == .H264 && nal_type(codec, n[0]) >= 7 && nal_type(codec, n[0]) <= 8) || (codec == .H265 && nal_type(codec, n[0]) >= 32 && nal_type(codec, n[0]) <= 34) continue;
			array_add(*avcc, cast,trunc(u8) (n.count >> 24), cast,trunc(u8) (n.count >> 16), cast,trunc(u8) (n.count >> 8), cast,trunc(u8) n.count);
			array_add(*avcc, ..n);
		}
		bb, sb: CFRef;
		size := cast(u64) avcc.count;
		CMBlockBufferCreateWithMemoryBlock(null, avcc.data, size, kCFAllocatorNull, null, 0, size, 0, *bb);
		timing := CMSampleTimingInfo.{pts = .{it.pts, 90000, 1, 0}, dts = .{it.pts, 90000, 1, 0}};
		CMSampleBufferCreateReady(null, bb, fmt, 1, 1, *timing, 1, *size, *sb);
		info: u32;
		VTDecompressionSessionDecodeFrame(session, sb, 0, null, *info);
		CFRelease(sb);
		CFRelease(bb);
	}
	VTDecompressionSessionWaitForAsynchronousFrames(session);
	VTDecompressionSessionInvalidate(session);
	CFRelease(session);
	CFRelease(fmt);
	print("decoded % frames (% wrong size, % errors)\n", d.count, d.bad_size, d.errors);
	expect(d.count == p.count && d.bad_size == 0 && d.errors == 0, "decoded % of % at %x%", d.count, p.count, W, H);
}

// rate_change: a noisy picture at 2 Mb/s, then encoder_set_bitrate(300 kb/s): the later frames are smaller.
rate_change :: (codec: video.Video_Codec) {
	r := New(Run);
	e := video.encoder_create(codec, W, H, 30, 2_000_000, on_output, r);
	if !e return;
	for t: 0..119 {
		if t == 60 video.encoder_set_bitrate(e, 300_000);
		pb := make_frame(W, H, t, noise = true);
		video.encoder_encode(e, pb, cast(u32) (t * 3000));
		CFRelease(pb);
	}
	video.encoder_destroy(e);
	before, after: int;
	for r.packets if !it.keyframe {
		if it.pts >= 30 * 3000 && it.pts < 60 * 3000 before += it.data.count;
		if it.pts >= 90 * 3000 after += it.data.count;
	}
	print("% bits/s at 2 Mb/s, % bits/s after setting 300 kb/s\n", before * 8, after * 8);
	expect(after * 3 < before, "a lower bitrate takes effect: % then % bytes", before, after);
}

main :: () {
	expect(video.encoder_supported(.H264), "H.264 encoder supported");
	run(.H264);
	rate_change(.H264);
	if video.encoder_supported(.H265) run(.H265);
	else print("H.265 encoder not available; skipped\n");
	print(ifx failures then "FAIL (% failures)\n" else "PASS\n", failures);
	exit(xx ifx failures then 1 else 0);
}

video_fourcc :: (s: string) -> u32 {
	return ((cast(u32) s[0]) << 24) | ((cast(u32) s[1]) << 16) | ((cast(u32) s[2]) << 8) | (cast(u32) s[3]);
}

dict :: (keys: []CFRef, vals: []CFRef) -> CFRef {
	return CFDictionaryCreate(null, keys.data, vals.data, keys.count, *kCFTypeDictionaryKeyCallBacks, *kCFTypeDictionaryValueCallBacks);
}

CFRef :: *void;
CMTime :: struct { value: s64; timescale: s32; flags: u32; epoch: s64; }
CMSampleTimingInfo :: struct { duration, pts, dts: CMTime; }
VTDecompressionOutputCallbackRecord :: struct {
	callback: (ref: *void, frame_ref: *void, status: s32, flags: u32, image: CFRef, pts: CMTime, dur: CMTime) #c_call;
	refcon: *void;
}

CoreFoundation :: #library,system,link_always "CoreFoundation";
CoreMedia :: #library,system,link_always "CoreMedia";
CoreVideo :: #library,system,link_always "CoreVideo";
VideoToolbox :: #library,system,link_always "VideoToolbox";
CFRelease :: (cf: CFRef) #foreign CoreFoundation;
CFDictionaryCreate :: (alloc: CFRef, keys: *CFRef, values: *CFRef, n: int, kcb: *void, vcb: *void) -> CFRef #foreign CoreFoundation;
kCFTypeDictionaryKeyCallBacks: [6]u64 #elsewhere CoreFoundation;
kCFTypeDictionaryValueCallBacks: [5]u64 #elsewhere CoreFoundation;
kCFAllocatorNull: CFRef #elsewhere CoreFoundation;
CVPixelBufferCreate :: (alloc: CFRef, w: u64, h: u64, fmt: u32, attrs: CFRef, out: *CFRef) -> s32 #foreign CoreVideo;
CVPixelBufferLockBaseAddress :: (pb: CFRef, flags: u64) -> s32 #foreign CoreVideo;
CVPixelBufferUnlockBaseAddress :: (pb: CFRef, flags: u64) -> s32 #foreign CoreVideo;
CVPixelBufferGetBaseAddressOfPlane :: (pb: CFRef, plane: u64) -> *void #foreign CoreVideo;
CVPixelBufferGetBytesPerRowOfPlane :: (pb: CFRef, plane: u64) -> u64 #foreign CoreVideo;
CVPixelBufferGetWidthOfPlane :: (pb: CFRef, plane: u64) -> u64 #foreign CoreVideo;
CVPixelBufferGetHeightOfPlane :: (pb: CFRef, plane: u64) -> u64 #foreign CoreVideo;
CVPixelBufferGetWidth :: (pb: CFRef) -> u64 #foreign CoreVideo;
CVPixelBufferGetHeight :: (pb: CFRef) -> u64 #foreign CoreVideo;
kCVPixelBufferIOSurfacePropertiesKey: CFRef #elsewhere CoreVideo;
CMVideoFormatDescriptionCreateFromH264ParameterSets :: (alloc: CFRef, n: u64, ptrs: **u8, sizes: *u64, nal_len: s32, out: *CFRef) -> s32 #foreign CoreMedia;
CMVideoFormatDescriptionCreateFromHEVCParameterSets :: (alloc: CFRef, n: u64, ptrs: **u8, sizes: *u64, nal_len: s32, ext: CFRef, out: *CFRef) -> s32 #foreign CoreMedia;
CMBlockBufferCreateWithMemoryBlock :: (alloc: CFRef, mem: *void, size: u64, block_alloc: CFRef, custom: *void, offset: u64, len: u64, flags: u32, out: *CFRef) -> s32 #foreign CoreMedia;
CMSampleBufferCreateReady :: (alloc: CFRef, bb: CFRef, fmt: CFRef, n: s64, n_timing: s64, timing: *CMSampleTimingInfo, n_sizes: s64, sizes: *u64, out: *CFRef) -> s32 #foreign CoreMedia;
VTDecompressionSessionCreate :: (alloc: CFRef, fmt: CFRef, spec: CFRef, attrs: CFRef, cb: *VTDecompressionOutputCallbackRecord, out: *CFRef) -> s32 #foreign VideoToolbox;
VTDecompressionSessionDecodeFrame :: (s: CFRef, sample: CFRef, flags: u32, frame_ref: *void, info: *u32) -> s32 #foreign VideoToolbox;
VTDecompressionSessionWaitForAsynchronousFrames :: (s: CFRef) -> s32 #foreign VideoToolbox;
VTDecompressionSessionInvalidate :: (s: CFRef) #foreign VideoToolbox;
