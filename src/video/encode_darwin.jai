// Realtime H.264 / H.265 encoding with VideoToolbox (hardware where available).

Encoder :: struct {
	session: CFRef;
	codec: Video_Codec;
	width, height: int;
	on_output: Encoded_Proc;
	user: *void;
	ctx: #Context;
	ts: Temporary_Storage;
	out: [..]u8; // reused per output; only touched on VT's output thread
	pts_hi: s64; // pts_90k wraps every 13 h; VT needs increasing timestamps
	last_pts: u32;
	xfer: CFRef; // scales frames whose size differs from the session's
}

encoder_supported :: (codec: Video_Codec) -> bool {
	id, props: CFRef;
	if VTCopySupportedPropertyDictionaryForEncoder(1280, 720, codec_type(codec), null, *id, *props) != 0 return false;
	CFRelease(id);
	CFRelease(props);
	return true;
}

encoder_create :: (codec: Video_Codec, width: int, height: int, fps: int, bitrate: int, on_output: Encoded_Proc, user: *void) -> *Encoder {
	e := New(Encoder);
	e.codec, e.width, e.height, e.on_output, e.user = codec, width, height, on_output, user;
	init_callback_context(*e.ctx, *e.ts);
	if VTCompressionSessionCreate(null, cast(s32) width, cast(s32) height, codec_type(codec), null, null, null, vt_output, e, *e.session) != 0 {
		free_callback_context(*e.ts);
		free(e);
		return null;
	}
	set :: (key: CFRef, v: CFRef) -> bool #expand { return VTSessionSetProperty(e.session, key, v) == 0; }
	set_int :: (key: CFRef, v: int) #expand { n := cf_s32(cast(s32) v); set(key, n); CFRelease(n); }
	set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
	set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);
	if codec == .H264 {
		if !set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_ConstrainedBaseline_AutoLevel)
			set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_Baseline_AutoLevel);
	} else {
		set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_HEVC_Main_AutoLevel);
	}
	set_int(kVTCompressionPropertyKey_MaxKeyFrameInterval, fps * 2);
	set_int(kVTCompressionPropertyKey_ExpectedFrameRate, fps);
	encoder_set_bitrate(e, bitrate);
	VTCompressionSessionPrepareToEncodeFrames(e.session);
	return e;
}

// encoder_set_bitrate changes the average bitrate between frames (the bandwidth estimate moved).
encoder_set_bitrate :: (e: *Encoder, bitrate: int) {
	n := cf_s32(cast(s32) bitrate);
	VTSessionSetProperty(e.session, kVTCompressionPropertyKey_AverageBitRate, n);
	// Bytes per second, as [bytes, seconds]: caps bursts at 1.5x the average.
	limit := cf_s32(cast(s32) (bitrate * 3 / 16));
	one := cf_s32(1);
	vals := CFRef.[limit, one];
	limits := CFArrayCreate(null, vals.data, 2, *kCFTypeArrayCallBacks);
	VTSessionSetProperty(e.session, kVTCompressionPropertyKey_DataRateLimits, limits);
	CFRelease(limits); CFRelease(limit); CFRelease(one); CFRelease(n);
}

encoder_encode :: (e: *Encoder, pixbuf: *void, pts_90k: u32, force_keyframe := false) {
	if pts_90k < e.last_pts && e.last_pts - pts_90k > 0x8000_0000 e.pts_hi += 0x1_0000_0000;
	e.last_pts = pts_90k;
	frame := pixbuf;
	scaled: CFRef;
	if cast(int) CVPixelBufferGetWidth(pixbuf) != e.width || cast(int) CVPixelBufferGetHeight(pixbuf) != e.height {
		pool := VTCompressionSessionGetPixelBufferPool(e.session);
		if !pool || CVPixelBufferPoolCreatePixelBuffer(null, pool, *scaled) != 0 return;
		if !e.xfer {
			VTPixelTransferSessionCreate(null, *e.xfer);
			VTSessionSetProperty(e.xfer, kVTPixelTransferPropertyKey_ScalingMode, kVTScalingMode_Letterbox);
		}
		if VTPixelTransferSessionTransferImage(e.xfer, pixbuf, scaled) != 0 { CFRelease(scaled); return; }
		frame = scaled;
	}
	props: CFRef;
	if force_keyframe props = cf_dict(.[kVTEncodeFrameOptionKey_ForceKeyFrame], .[kCFBooleanTrue]);
	pts := CMTime.{value = e.pts_hi + pts_90k, timescale = 90000, flags = 1};
	VTCompressionSessionEncodeFrame(e.session, frame, pts, .{}, props, null, null);
	if props CFRelease(props);
	if scaled CFRelease(scaled);
}

encoder_destroy :: (e: *Encoder) {
	if !e return;
	VTCompressionSessionCompleteFrames(e.session, .{}); // invalid time: all pending frames
	VTCompressionSessionInvalidate(e.session);
	CFRelease(e.session);
	if e.xfer { VTPixelTransferSessionInvalidate(e.xfer); CFRelease(e.xfer); }
	array_free(e.out);
	free_callback_context(*e.ts);
	free(e);
}

#scope_file

codec_type :: (c: Video_Codec) -> u32 { return fourcc(ifx c == .H264 then "avc1" else "hvc1"); }

vt_output :: (ref: *void, frame_ref: *void, status: OSStatus, flags: u32, sample: CFRef) #c_call {
	e := cast(*Encoder) ref;
	if status != 0 || !sample return;
	push_context e.ctx {
		keyframe := true;
		atts := CMSampleBufferGetSampleAttachmentsArray(sample, false);
		if atts && CFArrayGetCount(atts) > 0 {
			not_sync := CFDictionaryGetValue(CFArrayGetValueAtIndex(atts, 0), kCMSampleAttachmentKey_NotSync);
			keyframe = !not_sync || not_sync == kCFBooleanFalse;
		}
		e.out.count = 0;
		start_code :: u8.[0, 0, 0, 1];
		if keyframe {
			fmt := CMSampleBufferGetFormatDescription(sample);
			get := ifx e.codec == .H264 then CMVideoFormatDescriptionGetH264ParameterSetAtIndex else CMVideoFormatDescriptionGetHEVCParameterSetAtIndex;
			n: u64;
			get(fmt, 0, null, null, *n, null);
			for 0..cast(int) n - 1 {
				p: *u8;
				size: u64;
				if get(fmt, cast(u64) it, *p, *size, null, null) != 0 break;
				array_add(*e.out, ..start_code);
				array_add(*e.out, ..([]u8).{cast(int) size, p});
			}
		}
		// AVCC/HVCC: 4-byte big-endian lengths -> start codes.
		bb := CMSampleBufferGetDataBuffer(sample);
		total := cast(int) CMBlockBufferGetDataLength(bb);
		base := e.out.count;
		array_resize(*e.out, base + total, initialize = false);
		if CMBlockBufferCopyDataBytes(bb, 0, cast(u64) total, e.out.data + base) != 0 return;
		i := base;
		while i + 4 <= e.out.count {
			p := e.out.data + i;
			len := ((cast(int) p[0]) << 24) | ((cast(int) p[1]) << 16) | ((cast(int) p[2]) << 8) | (cast(int) p[3]);
			memcpy(p, start_code.data, 4);
			i += 4 + len;
		}
		pts := CMSampleBufferGetPresentationTimeStamp(sample);
		e.on_output(e.user, e.out, keyframe, cast,trunc(u32) pts.value);
		reset_temporary_storage();
	}
}

VTCopySupportedPropertyDictionaryForEncoder :: (w: s32, h: s32, codec: u32, spec: CFRef, id: *CFRef, props: *CFRef) -> OSStatus #foreign VideoToolbox;
VTCompressionSessionCreate :: (alloc: CFRef, w: s32, h: s32, codec: u32, spec: CFRef, src_attrs: CFRef, data_alloc: CFRef,
	cb: (ref: *void, frame_ref: *void, status: OSStatus, flags: u32, sample: CFRef) #c_call, ref: *void, out: *CFRef) -> OSStatus #foreign VideoToolbox;
VTSessionSetProperty :: (s: CFRef, key: CFRef, value: CFRef) -> OSStatus #foreign VideoToolbox;
VTCompressionSessionPrepareToEncodeFrames :: (s: CFRef) -> OSStatus #foreign VideoToolbox;
VTCompressionSessionEncodeFrame :: (s: CFRef, image: CFRef, pts: CMTime, dur: CMTime, props: CFRef, frame_ref: *void, info: *u32) -> OSStatus #foreign VideoToolbox;
VTCompressionSessionCompleteFrames :: (s: CFRef, until: CMTime) -> OSStatus #foreign VideoToolbox;
VTCompressionSessionInvalidate :: (s: CFRef) #foreign VideoToolbox;
VTCompressionSessionGetPixelBufferPool :: (s: CFRef) -> CFRef #foreign VideoToolbox;
VTPixelTransferSessionCreate :: (alloc: CFRef, out: *CFRef) -> OSStatus #foreign VideoToolbox;
VTPixelTransferSessionTransferImage :: (s: CFRef, src: CFRef, dst: CFRef) -> OSStatus #foreign VideoToolbox;
VTPixelTransferSessionInvalidate :: (s: CFRef) #foreign VideoToolbox;
CVPixelBufferPoolCreatePixelBuffer :: (alloc: CFRef, pool: CFRef, out: *CFRef) -> s32 #foreign CoreVideo;
CMSampleBufferGetFormatDescription :: (sb: CFRef) -> CFRef #foreign CoreMedia;
CMSampleBufferGetDataBuffer :: (sb: CFRef) -> CFRef #foreign CoreMedia;
CMSampleBufferGetPresentationTimeStamp :: (sb: CFRef) -> CMTime #foreign CoreMedia;
CMBlockBufferGetDataLength :: (bb: CFRef) -> u64 #foreign CoreMedia;
CMBlockBufferCopyDataBytes :: (bb: CFRef, offset: u64, n: u64, dst: *void) -> OSStatus #foreign CoreMedia;
CMVideoFormatDescriptionGetH264ParameterSetAtIndex :: (fmt: CFRef, i: u64, p: **u8, size: *u64, count: *u64, nal_header_len: *s32) -> OSStatus #foreign CoreMedia;
CMVideoFormatDescriptionGetHEVCParameterSetAtIndex :: (fmt: CFRef, i: u64, p: **u8, size: *u64, count: *u64, nal_header_len: *s32) -> OSStatus #foreign CoreMedia;
kCMSampleAttachmentKey_NotSync: CFRef #elsewhere CoreMedia;
kVTCompressionPropertyKey_RealTime: CFRef #elsewhere VideoToolbox;
kVTCompressionPropertyKey_AllowFrameReordering: CFRef #elsewhere VideoToolbox;
kVTCompressionPropertyKey_ProfileLevel: CFRef #elsewhere VideoToolbox;
kVTCompressionPropertyKey_MaxKeyFrameInterval: CFRef #elsewhere VideoToolbox;
kVTCompressionPropertyKey_ExpectedFrameRate: CFRef #elsewhere VideoToolbox;
kVTCompressionPropertyKey_AverageBitRate: CFRef #elsewhere VideoToolbox;
kVTCompressionPropertyKey_DataRateLimits: CFRef #elsewhere VideoToolbox;
kVTProfileLevel_H264_ConstrainedBaseline_AutoLevel: CFRef #elsewhere VideoToolbox;
kVTProfileLevel_H264_Baseline_AutoLevel: CFRef #elsewhere VideoToolbox;
kVTProfileLevel_HEVC_Main_AutoLevel: CFRef #elsewhere VideoToolbox;
kVTEncodeFrameOptionKey_ForceKeyFrame: CFRef #elsewhere VideoToolbox;
kVTPixelTransferPropertyKey_ScalingMode: CFRef #elsewhere VideoToolbox;
kVTScalingMode_Letterbox: CFRef #elsewhere VideoToolbox;
