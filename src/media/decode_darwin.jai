// macOS decoders: VideoToolbox (hardware H.264/HEVC/VP9/AV1 -> NV12
// CVPixelBuffers, wrapped as Metal textures through CVMetalTextureCache, zero
// copy) and AudioToolbox AudioConverter (AAC/MP3/Opus/FLAC/PCM -> f32 @ 48 kHz).

// ---------------------------------------------------------------------------
// Video

Video_Frame :: struct {
	pts: float64; // seconds
	dur: float64;
	pixbuf: *void; // CVPixelBuffer (retained)
	width: int;
	height: int;
	yuv: gfx.Yuv_Matrix;
}

// OSStatus of the last failed video_decoder_create (diagnostics; e.g. -12910 = unsupported format).
last_video_error: s32;

Video_Decoder :: struct {
	session: CFRef;
	format: CFRef;
	mu: locks.Mutex;
	out: [..]Video_Frame; // decoded, in output order (caller sorts)
	errors: int;
	ctx: #Context; // for vt_callback: the thread driving the session
}

video_codec_supported :: (c: Codec) -> bool {
	if c == {
	case .H264; #through;
	case .HEVC; return true;
	case .VP9;
		VTRegisterSupplementalVideoDecoderIfAvailable(audio.fourcc("vp09"));
		return true;
	case .AV1; return VTIsHardwareDecodeSupported(audio.fourcc("av01"));
	}
	return false;
}

// first_packet: needed for VP9 in WebM (no vpcC in the container).
video_decoder_create :: (t: *Track, first_packet: []u8 = .[]) -> *Video_Decoder, bool {
	codec: u32;
	atom: string;
	extradata := t.extradata;
	owned: []u8;
	defer array_free(owned);
	if t.codec == {
	case .H264; codec, atom = audio.fourcc("avc1"), "avcC";
	case .HEVC; codec, atom = audio.fourcc("hvc1"), "hvcC";
	case .VP9;
		VTRegisterSupplementalVideoDecoderIfAvailable(audio.fourcc("vp09"));
		codec, atom = audio.fourcc("vp09"), "vpcC";
		if extradata.count < 8 {
			owned = vpcc_from_keyframe(first_packet);
			extradata = owned;
		}
	case .AV1;
		if !VTIsHardwareDecodeSupported(audio.fourcc("av01")) return null, false;
		codec, atom = audio.fourcc("av01"), "av1C";
	case; return null, false;
	}
	if !extradata.count return null, false;

	data := CFDataCreate(null, extradata.data, extradata.count);
	defer CFRelease(data);
	akey := CFStringCreateWithBytes(null, atom.data, atom.count, 0x08000100, false);
	defer CFRelease(akey);
	atoms := dict(.[akey], .[data]);
	defer CFRelease(atoms);
	ext := dict(.[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms], .[atoms]);
	defer CFRelease(ext);

	vd := New(Video_Decoder);
	set_callback_context(*vd.ctx);
	st := CMVideoFormatDescriptionCreate(null, codec, cast(s32) t.width, cast(s32) t.height, ext, *vd.format);
	if st != 0 {
		last_video_error = st;
		free(vd);
		return null, false;
	}
	if !video_session_create(vd) {
		CFRelease(vd.format);
		free(vd);
		return null, false;
	}
	return vd, true;
}

video_session_create :: (vd: *Video_Decoder) -> bool {
	pf := cast(s32) audio.fourcc("420v");
	pfn := CFNumberCreate(null, 3, *pf);
	defer CFRelease(pfn);
	empty := dict(.[], .[]);
	defer CFRelease(empty);
	attrs := dict(.[kCVPixelBufferPixelFormatTypeKey, kCVPixelBufferMetalCompatibilityKey, kCVPixelBufferIOSurfacePropertiesKey], .[pfn, kCFBooleanTrue, empty]);
	defer CFRelease(attrs);
	cb := VTDecompressionOutputCallbackRecord.{vt_callback, vd};
	st := VTDecompressionSessionCreate(null, vd.format, null, attrs, *cb, *vd.session);
	if st != 0 last_video_error = st;
	return st == 0;
}

// A decoder for a live stream (H.264 or HEVC) from its parameter sets (SPS, PPS;
// HEVC: VPS, SPS, PPS), as they arrive in-band; samples are then AVCC with 4-byte lengths.
video_decoder_create_from_params :: (codec: Codec, params: [][]u8) -> *Video_Decoder, bool {
	if (codec != .H264 && codec != .HEVC) || !params.count return null, false;
	ptrs := NewArray(params.count, *u8,, temp);
	sizes := NewArray(params.count, u64,, temp);
	for params { ptrs[it_index] = it.data; sizes[it_index] = xx it.count; }
	vd := New(Video_Decoder);
	set_callback_context(*vd.ctx);
	st: OSStatus;
	if codec == .H264 st = CMVideoFormatDescriptionCreateFromH264ParameterSets(null, xx params.count, ptrs.data, sizes.data, 4, *vd.format);
	else st = CMVideoFormatDescriptionCreateFromHEVCParameterSets(null, xx params.count, ptrs.data, sizes.data, 4, null, *vd.format);
	if st == 0 && video_session_create(vd) return vd, true;
	last_video_error = st;
	if vd.format CFRelease(vd.format);
	free(vd);
	return null, false;
}

// Decode one access unit (synchronously). Output frames land in vd.out.
video_decode :: (vd: *Video_Decoder, data: []u8, pts: float64, dts: float64, dur: float64) -> bool {
	if !data.count return true;
	set_callback_context(*vd.ctx);
	bb: CFRef;
	size := cast(u64) data.count;
	if CMBlockBufferCreateWithMemoryBlock(null, data.data, size, kCFAllocatorNull, null, 0, size, 0, *bb) != 0 return false;
	defer CFRelease(bb);
	us :: (s: float64) -> CMTime { return .{cast(s64) (s * 1_000_000), 1_000_000, 1, 0}; }
	timing := CMSampleTimingInfo.{duration = us(dur), pts = us(pts), dts = us(dts)};
	sb: CFRef;
	if CMSampleBufferCreateReady(null, bb, vd.format, 1, 1, *timing, 1, *size, *sb) != 0 return false;
	defer CFRelease(sb);
	info: u32;
	return VTDecompressionSessionDecodeFrame(vd.session, sb, 0, null, *info) == 0;
}

video_decoder_flush :: (vd: *Video_Decoder) {
	set_callback_context(*vd.ctx);
	VTDecompressionSessionWaitForAsynchronousFrames(vd.session);
}

// Take decoded frames (caller owns them; release with video_frame_release).
video_decoder_take :: (vd: *Video_Decoder, out: *[..]Video_Frame) {
	locks.lock(*vd.mu);
	array_add(out, ..vd.out);
	vd.out.count = 0;
	locks.unlock(*vd.mu);
}

video_decoder_destroy :: (vd: *Video_Decoder) {
	if !vd return;
	set_callback_context(*vd.ctx);
	VTDecompressionSessionWaitForAsynchronousFrames(vd.session);
	VTDecompressionSessionInvalidate(vd.session);
	CFRelease(vd.session);
	CFRelease(vd.format);
	for vd.out CFRelease(it.pixbuf);
	array_free(vd.out);
	free(vd);
}

// video_frame_from_pixbuf wraps (and retains) an NV12 CVPixelBuffer from elsewhere, e.g. a camera.
video_frame_from_pixbuf :: (pixbuf: *void) -> Video_Frame {
	f := Video_Frame.{pixbuf = CFRetain(pixbuf), width = xx CVPixelBufferGetWidth(pixbuf), height = xx CVPixelBufferGetHeight(pixbuf)};
	full := CVPixelBufferGetPixelFormatType(pixbuf) == audio.fourcc("420f");
	f.yuv = ifx f.height >= 720 then (ifx full then .BT709_Full else .BT709) else (ifx full then .BT601_Full else .BT601);
	return f;
}

// A decoder's I420 picture (odd sizes rounded down to even) copied into a new Metal-compatible NV12
// CVPixelBuffer.
frame_from_i420 :: (y: *u8, u: *u8, v: *u8, ys: int, uvs: int, w: int, h: int) -> Video_Frame, bool {
	pf := cast(s32) audio.fourcc("420v");
	pfn := CFNumberCreate(null, 3, *pf);
	empty := dict(.[], .[]);
	attrs := dict(.[kCVPixelBufferPixelFormatTypeKey, kCVPixelBufferMetalCompatibilityKey, kCVPixelBufferIOSurfacePropertiesKey], .[pfn, kCFBooleanTrue, empty]);
	defer { CFRelease(attrs); CFRelease(empty); CFRelease(pfn); }
	w, h = w & ~1, h & ~1;
	pb: CFRef;
	if CVPixelBufferCreate(null, xx w, xx h, xx pf, attrs, *pb) != 0 || !pb return .{}, false;
	CVPixelBufferLockBaseAddress(pb, 0);
	dy := cast(*u8) CVPixelBufferGetBaseAddressOfPlane(pb, 0);
	dys := cast(int) CVPixelBufferGetBytesPerRowOfPlane(pb, 0);
	for row: 0..h - 1 memcpy(dy + row * dys, y + row * ys, w);
	duv := cast(*u8) CVPixelBufferGetBaseAddressOfPlane(pb, 1);
	duvs := cast(int) CVPixelBufferGetBytesPerRowOfPlane(pb, 1);
	for row: 0..h / 2 - 1 {
		su, sv, d := u + row * uvs, v + row * uvs, duv + row * duvs;
		for x: 0..w / 2 - 1 { d[2 * x] = su[x]; d[2 * x + 1] = sv[x]; }
	}
	CVPixelBufferUnlockBaseAddress(pb, 0);
	return .{pixbuf = pb, width = w, height = h, yuv = ifx h >= 720 then .BT709 else .BT601}, true;
}

CVPixelBufferCreate :: (alloc: CFRef, w: u64, h: u64, fmt: u32, attrs: CFRef, out: *CFRef) -> s32 #foreign CoreVideo;
CVPixelBufferLockBaseAddress :: (pb: CFRef, flags: u64) -> s32 #foreign CoreVideo;
CVPixelBufferUnlockBaseAddress :: (pb: CFRef, flags: u64) -> s32 #foreign CoreVideo;
CVPixelBufferGetBaseAddressOfPlane :: (pb: CFRef, plane: u64) -> *void #foreign CoreVideo;
CVPixelBufferGetPlaneCount :: (pb: CFRef) -> u64 #foreign CoreVideo;
CVPixelBufferGetBytesPerRowOfPlane :: (pb: CFRef, plane: u64) -> u64 #foreign CoreVideo;

video_frame_release :: (f: *Video_Frame) {
	if f.pixbuf CFRelease(f.pixbuf);
	f.pixbuf = null;
}

// video_frame_rgb: the frame scaled to w x h as RGB8 rows in temp (nv12_to_rgb), empty when not NV12.
video_frame_rgb :: (f: *Video_Frame, w: int, h: int) -> []u8 {
	pb := f.pixbuf;
	if !pb || CVPixelBufferGetPlaneCount(pb) != 2 || f.width < 2 || f.height < 2 return .[];
	CVPixelBufferLockBaseAddress(pb, 1); // read-only
	defer CVPixelBufferUnlockBaseAddress(pb, 1);
	return nv12_to_rgb(CVPixelBufferGetBaseAddressOfPlane(pb, 0), xx CVPixelBufferGetBytesPerRowOfPlane(pb, 0),
		CVPixelBufferGetBaseAddressOfPlane(pb, 1), xx CVPixelBufferGetBytesPerRowOfPlane(pb, 1), f.width, f.height, f.yuv, w, h);
}

// Wrap the frame's Y and CbCr planes as gfx textures (no copy). Destroy them
// with gfx.texture_destroy; the pixel buffer stays alive until the GPU is done.
video_frame_textures :: (f: *Video_Frame) -> gfx.Texture, gfx.Texture, bool {
	if !f.pixbuf return 0, 0, false;
	if !tex_cache && CVMetalTextureCacheCreate(null, null, gfx.native_device(), null, *tex_cache) != 0 return 0, 0, false;
	planes: [2]gfx.Texture;
	for p: 0..1 {
		w := CVPixelBufferGetWidthOfPlane(f.pixbuf, xx p);
		h := CVPixelBufferGetHeightOfPlane(f.pixbuf, xx p);
		pf := cast(u64) ifx p == 0 then 10 else 30; // R8Unorm, RG8Unorm
		cv: CFRef;
		if CVMetalTextureCacheCreateTextureFromImage(null, tex_cache, f.pixbuf, null, pf, w, h, xx p, *cv) != 0 || !cv {
			if p == 1 gfx.texture_destroy(planes[0]);
			return 0, 0, false;
		}
		hold := New(Tex_Hold);
		hold.* = .{cv, CFRetain(f.pixbuf)};
		release :: (user: *void) {
			h := cast(*Tex_Hold) user;
			CFRelease(h.cvtex);
			CFRelease(h.pixbuf);
			free(h);
		}
		planes[p] = gfx.texture_wrap_native(CVMetalTextureGetTexture(cv), xx w, xx h, ifx p == 0 then gfx.Texture_Format.R8 else .RG8, release, hold);
	}
	return planes[0], planes[1], true;
}

// ---------------------------------------------------------------------------
// Audio

Audio_Decoder :: struct {
	conv: *void;
	in_fmt: audio.AudioStreamBasicDescription;
	out_ch: int;
	codec: Codec;
	// current input packet for the input proc
	pkt: []u8;
	pkt_desc: AudioStreamPacketDescription;
	pkt_given: bool;
	scratch: []float32;
}

audio_codec_supported :: (c: Codec) -> bool {
	return c == .AAC || c == .MP3 || c == .Opus || c == .FLAC || c == .PCM;
}

audio_decoder_create :: (t: *Track) -> *Audio_Decoder, bool {
	if !audio_codec_supported(t.codec) return null, false;
	ad := New(Audio_Decoder);
	ad.codec = t.codec;
	ch := max(t.channels, 1);
	rate := ifx t.sample_rate > 0 then t.sample_rate else 48000;
	f := *ad.in_fmt;
	f.mSampleRate = cast(float64) rate;
	f.mChannelsPerFrame = cast(u32) ch;
	cookie: []u8;
	owned: []u8;
	defer array_free(owned);
	if t.codec == {
	case .AAC;
		f.mFormatID = audio.fourcc("aac ");
		f.mFramesPerPacket = 1024;
		if t.aac_asc.count >= 2 {
			owned = esds_from_asc(t.aac_asc);
			cookie = owned;
			// sample rate from ASC
			idx := ((t.aac_asc[0] & 7) << 1) | (t.aac_asc[1] >> 7);
			RATES :: int.[96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350];
			if idx < 13 f.mSampleRate = cast(float64) RATES[idx];
		} else {
			cookie = t.extradata;
		}
	case .MP3;
		f.mFormatID = audio.fourcc(".mp3");
		f.mFramesPerPacket = cast(u32) ifx rate < 32000 then 576 else 1152;
	case .Opus;
		f.mFormatID = audio.fourcc("opus");
		f.mSampleRate = 48000;
		f.mFramesPerPacket = 960;
		cookie = t.extradata;
	case .FLAC;
		f.mFormatID = audio.fourcc("flac");
		if t.extradata.count >= 4 + 34 f.mFramesPerPacket = be16(t.extradata, 4 + 2); // max block size
		cookie = t.extradata;
	case .PCM;
		bits := max(t.bits, 8);
		f.mFormatID = audio.kAudioFormatLinearPCM;
		f.mFormatFlags = audio.kAudioFormatFlagIsPacked;
		if t.pcm_float f.mFormatFlags |= audio.kAudioFormatFlagIsFloat;
		else if bits > 8 f.mFormatFlags |= audio.kAudioFormatFlagIsSignedInteger;
		if t.pcm_big f.mFormatFlags |= 2; // kAudioFormatFlagIsBigEndian
		f.mBitsPerChannel = cast(u32) bits;
		f.mBytesPerFrame = cast(u32) (bits / 8 * ch);
		f.mBytesPerPacket = f.mBytesPerFrame;
		f.mFramesPerPacket = 1;
	}
	ad.out_ch = min(ch, 2);
	out := audio.AudioStreamBasicDescription.{
		mSampleRate = audio.SAMPLE_RATE,
		mFormatID = audio.kAudioFormatLinearPCM,
		mFormatFlags = audio.kAudioFormatFlagIsFloat | audio.kAudioFormatFlagIsPacked,
		mBytesPerPacket = cast(u32) (4 * ad.out_ch),
		mFramesPerPacket = 1,
		mBytesPerFrame = cast(u32) (4 * ad.out_ch),
		mChannelsPerFrame = cast(u32) ad.out_ch,
		mBitsPerChannel = 32
	};
	if AudioConverterNew(*ad.in_fmt, *out, *ad.conv) != 0 {
		free(ad);
		return null, false;
	}
	if cookie.count AudioConverterSetProperty(ad.conv, audio.fourcc("dmgc"), cast(u32) cookie.count, cookie.data);
	ad.scratch = NewArray(8192 * 2, float32);
	return ad, true;
}

// Decode one packet; appends interleaved stereo f32 @48 kHz to out.
audio_decode :: (ad: *Audio_Decoder, data: []u8, out: *[..]float32) -> bool {
	ad.pkt = data;
	ad.pkt_given = false;
	defer ad.pkt = .[];
	while true {
		frames := cast(u32) (ad.scratch.count / ad.out_ch);
		abl := audio.AudioBufferList.{mNumberBuffers = 1};
		abl.mBuffers[0] = .{cast(u32) ad.out_ch, cast(u32) (ad.scratch.count * 4), ad.scratch.data};
		st := AudioConverterFillComplexBuffer(ad.conv, input_proc, ad, *frames, *abl, null);
		if frames > 0 audio.to_stereo(out, array_view(ad.scratch, 0, frames * ad.out_ch), ad.out_ch);
		if st != 0 && st != NO_DATA return false;
		if frames == 0 || st == NO_DATA break;
	}
	return true;
}

audio_decoder_reset :: (ad: *Audio_Decoder) { AudioConverterReset(ad.conv); }

audio_decoder_destroy :: (ad: *Audio_Decoder) {
	if !ad return;
	AudioConverterDispose(ad.conv);
	array_free(ad.scratch);
	free(ad);
}

#scope_file

CFRef :: *void;
OSStatus :: s32;

NO_DATA :: cast(OSStatus) 0x6e6f6474; // 'nodt'

tex_cache: CFRef;

Tex_Hold :: struct {
	cvtex: CFRef;
	pixbuf: CFRef;
}

dict :: (keys: []CFRef, vals: []CFRef) -> CFRef {
	kcb, vcb := gfx.cf_type_dictionary_callbacks();
	return CFDictionaryCreate(null, keys.data, vals.data, keys.count, kcb, vcb);
}

// Build a vpcC (with version/flags) from a VP9 keyframe's uncompressed header.
vpcc_from_keyframe :: (frame: []u8) -> []u8 {
	profile, bit_depth, chroma, full := 0, 8, 1, 0;
	if frame.count >= 10 {
		pos := 0;
		bit :: () -> int #expand {
			b := `frame;
			if `pos / 8 >= b.count return 0;
			v := (b[`pos / 8] >> (7 - `pos % 8)) & 1;
			`pos += 1;
			return v;
		}
		bit(); bit(); // frame marker
		lo := bit();
		hi := bit();
		profile = (hi << 1) | lo;
		if profile == 3 pos += 1;
		if bit() == 0 { // show_existing_frame == 0
			ftype := bit();
			pos += 2; // show_frame, error_resilient
			if ftype == 0 {
				pos += 24; // sync code
				if profile >= 2 bit_depth = ifx bit() == 1 then 12 else 10;
				cs := bit() << 2;
				cs |= bit() << 1;
				cs |= bit();
				if cs != 7 {
					full = bit();
					if profile == 1 || profile == 3 {
						sx := bit();
						sy := bit();
						chroma = ifx sx == 1 && sy == 0 then 2 else ifx sx == 0 && sy == 0 then 3 else 1;
					}
				} else {
					full = 1;
					chroma = 3;
				}
			}
		}
	}
	out := NewArray(12, u8);
	out[0] = 1; // version
	out[4] = cast(u8) profile;
	out[5] = 10; // level 1.0 (unknown; decoder ignores)
	out[6] = cast(u8) ((bit_depth << 4) | (chroma << 1) | full);
	out[7] = 1;
	out[8] = 1;
	out[9] = 1;
	return out;
}

// The context vt_callback runs under, on VideoToolbox's threads: without the creator's stack trace, which
// lives on a stack that may be gone by then.
set_callback_context :: (ctx: *#Context) {
	ctx.* = context;
	ctx.stack_trace = null;
}

vt_callback :: (ref: *void, frame_ref: *void, status: OSStatus, flags: u32, image: CFRef, pts: CMTime, dur: CMTime) #c_call {
	vd := cast(*Video_Decoder) ref;
	push_context vd.ctx {
		if status != 0 || !image {
			vd.errors += 1;
			return;
		}
		CFRetain(image);
		f := Video_Frame.{
			pts = ifx pts.timescale != 0 then cast(float64) pts.value / cast(float64) pts.timescale else 0,
			dur = ifx dur.timescale != 0 then cast(float64) dur.value / cast(float64) dur.timescale else 0,
			pixbuf = image,
			width = cast(int) CVPixelBufferGetWidth(image),
			height = cast(int) CVPixelBufferGetHeight(image),
			yuv = .BT601
		};
		m := CVBufferCopyAttachment(image, kCVImageBufferYCbCrMatrixKey, null);
		if m {
			if CFEqual(m, kCVImageBufferYCbCrMatrix_ITU_R_709_2) f.yuv = .BT709;
			CFRelease(m);
		} else if f.height >= 720 {
			f.yuv = .BT709;
		}
		if CVPixelBufferGetPixelFormatType(image) == audio.fourcc("420f") f.yuv = ifx f.yuv == .BT709 then .BT709_Full else .BT601_Full;
		locks.lock(*vd.mu);
		array_add(*vd.out, f);
		locks.unlock(*vd.mu);
	}
}

// Wrap an AudioSpecificConfig in an MPEG-4 ES_Descriptor (AudioToolbox's AAC magic cookie).
esds_from_asc :: (asc: []u8) -> []u8 {
	b: [..]u8;
	dsi_len := asc.count;
	dcd_len := 13 + 2 + dsi_len;
	es_len := 3 + 2 + dcd_len + 3;
	array_add(*b, 0x03, cast,trunc(u8) es_len, 0, 1, 0);
	array_add(*b, 0x04, cast,trunc(u8) dcd_len, 0x40, 0x15, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
	array_add(*b, 0x05, cast,trunc(u8) dsi_len);
	array_add(*b, ..asc);
	array_add(*b, 0x06, 0x01, 0x02);
	return b;
}

input_proc :: (conv: *void, n_packets: *u32, data: *audio.AudioBufferList, desc: **AudioStreamPacketDescription, user: *void) -> OSStatus #c_call {
	ad := cast(*Audio_Decoder) user;
	if ad.pkt_given || !ad.pkt.count {
		n_packets.* = 0;
		data.mBuffers[0].mDataByteSize = 0;
		data.mBuffers[0].mData = null;
		return NO_DATA;
	}
	ad.pkt_given = true;
	data.mNumberBuffers = 1;
	data.mBuffers[0].mData = ad.pkt.data;
	data.mBuffers[0].mDataByteSize = cast(u32) ad.pkt.count;
	data.mBuffers[0].mNumberChannels = ad.in_fmt.mChannelsPerFrame;
	if ad.in_fmt.mFormatID == audio.kAudioFormatLinearPCM {
		n_packets.* = (cast(u32) ad.pkt.count) / (ifx ad.in_fmt.mBytesPerPacket > 1 then ad.in_fmt.mBytesPerPacket else 1);
	} else {
		n_packets.* = 1;
		ad.pkt_desc = .{0, 0, cast(u32) ad.pkt.count};
		if desc desc.* = *ad.pkt_desc;
	}
	return 0;
}

CMTime :: struct {
	value: s64;
	timescale: s32;
	flags: u32;
	epoch: s64;
}

CMSampleTimingInfo :: struct {
	duration, pts, dts: CMTime;
}

VTDecompressionOutputCallbackRecord :: struct {
	callback: (ref: *void, frame_ref: *void, status: OSStatus, flags: u32, image: CFRef, pts: CMTime, dur: CMTime) #c_call;
	refcon: *void;
}

AudioStreamPacketDescription :: struct {
	mStartOffset: s64;
	mVariableFramesInPacket: u32;
	mDataByteSize: u32;
}

Input_Proc :: #type (conv: *void, n_packets: *u32, data: *audio.AudioBufferList, desc: **AudioStreamPacketDescription, user: *void) -> OSStatus #c_call;

CFRelease :: (cf: CFRef) #foreign CoreFoundation;
CFRetain :: (cf: CFRef) -> CFRef #foreign CoreFoundation;
CFEqual :: (a: CFRef, b: CFRef) -> bool #foreign CoreFoundation;
CFDataCreate :: (alloc: CFRef, bytes: *u8, n: int) -> CFRef #foreign CoreFoundation;
CFStringCreateWithBytes :: (alloc: CFRef, bytes: *u8, n: int, enc: u32, ext: bool) -> CFRef #foreign CoreFoundation;
CFDictionaryCreate :: (alloc: CFRef, keys: *CFRef, values: *CFRef, n: int, kcb: *void, vcb: *void) -> CFRef #foreign CoreFoundation;
CFNumberCreate :: (alloc: CFRef, type: int, value: *void) -> CFRef #foreign CoreFoundation;
kCFBooleanTrue: CFRef #elsewhere CoreFoundation;
kCFAllocatorNull: CFRef #elsewhere CoreFoundation;
CMVideoFormatDescriptionCreate :: (alloc: CFRef, codec: u32, w: s32, h: s32, ext: CFRef, out: *CFRef) -> OSStatus #foreign CoreMedia;
CMBlockBufferCreateWithMemoryBlock :: (alloc: CFRef, mem: *void, len: u64, block_alloc: CFRef, custom: *void, offset: u64, data_len: u64, flags: u32, out: *CFRef) -> OSStatus #foreign CoreMedia;
CMSampleBufferCreateReady :: (alloc: CFRef, data: CFRef, fmt: CFRef, nsamples: int, ntiming: int, timing: *CMSampleTimingInfo, nsizes: int, sizes: *u64, out: *CFRef) -> OSStatus #foreign CoreMedia;
kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: CFRef #elsewhere CoreMedia;
CMVideoFormatDescriptionCreateFromH264ParameterSets :: (alloc: CFRef, n: u64, ptrs: **u8, sizes: *u64, nal_len: s32, out: *CFRef) -> OSStatus #foreign CoreMedia;
CMVideoFormatDescriptionCreateFromHEVCParameterSets :: (alloc: CFRef, n: u64, ptrs: **u8, sizes: *u64, nal_len: s32, ext: CFRef, out: *CFRef) -> OSStatus #foreign CoreMedia;
CVPixelBufferGetWidth :: (pb: CFRef) -> u64 #foreign CoreVideo;
CVPixelBufferGetHeight :: (pb: CFRef) -> u64 #foreign CoreVideo;
CVPixelBufferGetWidthOfPlane :: (pb: CFRef, plane: u64) -> u64 #foreign CoreVideo;
CVPixelBufferGetHeightOfPlane :: (pb: CFRef, plane: u64) -> u64 #foreign CoreVideo;
CVPixelBufferGetPixelFormatType :: (pb: CFRef) -> u32 #foreign CoreVideo;
CVBufferCopyAttachment :: (buf: CFRef, key: CFRef, mode: *u32) -> CFRef #foreign CoreVideo;
CVMetalTextureCacheCreate :: (alloc: CFRef, attrs: CFRef, device: *void, tex_attrs: CFRef, out: *CFRef) -> s32 #foreign CoreVideo;
CVMetalTextureCacheCreateTextureFromImage :: (alloc: CFRef, cache: CFRef, image: CFRef, attrs: CFRef, pf: u64, w: u64, h: u64, plane: u64, out: *CFRef) -> s32 #foreign CoreVideo;
CVMetalTextureGetTexture :: (tex: CFRef) -> *void #foreign CoreVideo;
kCVPixelBufferPixelFormatTypeKey: CFRef #elsewhere CoreVideo;
kCVPixelBufferMetalCompatibilityKey: CFRef #elsewhere CoreVideo;
kCVPixelBufferIOSurfacePropertiesKey: CFRef #elsewhere CoreVideo;
kCVImageBufferYCbCrMatrixKey: CFRef #elsewhere CoreVideo;
kCVImageBufferYCbCrMatrix_ITU_R_709_2: CFRef #elsewhere CoreVideo;
VTDecompressionSessionCreate :: (alloc: CFRef, fmt: CFRef, decoder_spec: CFRef, image_attrs: CFRef, cb: *VTDecompressionOutputCallbackRecord, out: *CFRef) -> OSStatus #foreign VideoToolbox;
VTDecompressionSessionDecodeFrame :: (s: CFRef, sample: CFRef, flags: u32, frame_ref: *void, info_out: *u32) -> OSStatus #foreign VideoToolbox;
VTDecompressionSessionWaitForAsynchronousFrames :: (s: CFRef) -> OSStatus #foreign VideoToolbox;
VTDecompressionSessionInvalidate :: (s: CFRef) #foreign VideoToolbox;
VTRegisterSupplementalVideoDecoderIfAvailable :: (codec: u32) #foreign VideoToolbox;
VTIsHardwareDecodeSupported :: (codec: u32) -> bool #foreign VideoToolbox;
AudioConverterNew :: (in_fmt: *audio.AudioStreamBasicDescription, out_fmt: *audio.AudioStreamBasicDescription, out: **void) -> OSStatus #foreign AudioToolbox;
AudioConverterDispose :: (c: *void) -> OSStatus #foreign AudioToolbox;
AudioConverterReset :: (c: *void) -> OSStatus #foreign AudioToolbox;
AudioConverterSetProperty :: (c: *void, id: u32, size: u32, data: *void) -> OSStatus #foreign AudioToolbox;
AudioConverterFillComplexBuffer :: (c: *void, input: Input_Proc, user: *void, out_packets: *u32, out: *audio.AudioBufferList, desc: *void) -> OSStatus #foreign AudioToolbox;
