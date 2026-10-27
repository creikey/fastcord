// macOS decoders: VideoToolbox (hardware H.264/HEVC/VP9/AV1 -> NV12
// CVPixelBuffers, wrapped as Metal textures through CVMetalTextureCache, zero
// copy) and AudioToolbox AudioConverter (AAC/MP3/Opus/FLAC/PCM -> f32 @ 48 kHz).





#scope_file

CFRef :: *void;
OSStatus :: s32;
#scope_export

CMTime :: struct {
	value: s64;
	timescale: s32;
	flags: u32;
	epoch: s64;
}
#scope_file

CMSampleTimingInfo :: struct {
	duration, pts, dts: CMTime;
}

VTDecompressionOutputCallbackRecord :: struct {
	callback: (ref: *void, frame_ref: *void, status: OSStatus, flags: u32, image: CFRef, pts: CMTime, dur: CMTime) #c_call;
	refcon: *void;
}
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
	CVPixelBufferGetWidth :: (pb: CFRef) -> u64 #foreign CoreVideo;
	CVPixelBufferGetHeight :: (pb: CFRef) -> u64 #foreign CoreVideo;
	CVPixelBufferGetWidthOfPlane :: (pb: CFRef, plane: u64) -> u64 #foreign CoreVideo;
	CVPixelBufferGetHeightOfPlane :: (pb: CFRef, plane: u64) -> u64 #foreign CoreVideo;
	CVPixelBufferGetPixelFormatType :: (pb: CFRef) -> u32 #foreign CoreVideo;
	CVBufferCopyAttachment :: (buf: CFRef, key: CFRef, mode: *u32) -> CFRef #foreign CoreVideo;
	CVMetalTextureCacheCreate :: (alloc: CFRef, attrs: CFRef, device: *void, tex_attrs: CFRef, out: *CFRef) -> s32 #foreign CoreVideo;
	CVMetalTextureCacheCreateTextureFromImage :: (alloc: CFRef, cache: CFRef, image: CFRef, attrs: CFRef, pf: u64, w: u64, h: u64, plane: u64, out: *CFRef) -> s32 #foreign CoreVideo;
	CVMetalTextureCacheFlush :: (cache: CFRef, flags: u64) #foreign CoreVideo;
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

AudioStreamPacketDescription :: struct {
	mStartOffset: s64;
	mVariableFramesInPacket: u32;
	mDataByteSize: u32;
}

Input_Proc :: #type (conv: *void, n_packets: *u32, data: *audio.AudioBufferList, desc: **AudioStreamPacketDescription, user: *void) -> OSStatus #c_call;
	AudioConverterNew :: (in_fmt: *audio.AudioStreamBasicDescription, out_fmt: *audio.AudioStreamBasicDescription, out: **void) -> OSStatus #foreign AudioToolbox;
	AudioConverterDispose :: (c: *void) -> OSStatus #foreign AudioToolbox;
	AudioConverterReset :: (c: *void) -> OSStatus #foreign AudioToolbox;
	AudioConverterSetProperty :: (c: *void, id: u32, size: u32, data: *void) -> OSStatus #foreign AudioToolbox;
	AudioConverterFillComplexBuffer :: (c: *void, input: Input_Proc, user: *void, out_packets: *u32, out: *audio.AudioBufferList, desc: *void) -> OSStatus #foreign AudioToolbox;
#scope_export

fourcc :: audio.fourcc;
#scope_file

cfstr :: (s: string) -> CFRef {return CFStringCreateWithBytes(null, raw_data(s), len(s), 0x08000100, false);}

dict :: (keys: []CFRef, vals: []CFRef) -> CFRef {
	cf_keys_cb, cf_vals_cb := gfx.cf_type_dictionary_callbacks();
	return CFDictionaryCreate(null, raw_data(keys), raw_data(vals), len(keys), cf_keys_cb, cf_vals_cb);
}
#scope_export

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
	ctx: type_of(context);
}

video_codec_supported :: (c: Codec) -> bool {
	if c == {
	case .H264; #through; case .HEVC; return true;
	case .VP9;
		VTRegisterSupplementalVideoDecoderIfAvailable(fourcc("vp09"));
		return true;
	case .AV1; return cast(bool)(VTIsHardwareDecodeSupported(fourcc("av01")));
	case .VP8; #through; case .Unknown; #through; case .AAC; #through; case .MP3; #through; case .Opus; #through; case .Vorbis; #through; case .FLAC; #through; case .PCM; return false;
	}
	return false;
}
#scope_file

// Build a vpcC (with version/flags) from a VP9 keyframe's uncompressed header.
vpcc_from_keyframe :: (frame: []u8) -> []u8 {
	profile, bit_depth, chroma, full := 0, 8, 1, 0;
	if len(frame) >= 10 {
		// bit reader
		pos := 0;
		bit :: (b: []u8, pos: *int) -> int {
			if pos.* / 8 >= len(b) { return 0; }
			v := (cast(int)(b[pos.* / 8] >> (cast(u64)(7 - pos.* % 8)))) & 1;
			pos.* += 1;
			return v;
		}
		bits :: (b: []u8, pos: *int, n: int) -> int {
			v := 0;
			for _: 0..cast(int)(n)-1 { v = (v << 1) | bit(b, pos); }
			return v;
		}
		bits(frame, *pos, 2); // frame marker
		lo := bit(frame, *pos);
		hi := bit(frame, *pos);
		profile = (hi << 1) | lo;
		if profile == 3 { pos += 1; }
		if bit(frame, *pos) == 0 { 	// show_existing_frame == 0
			ftype := bit(frame, *pos);
			pos += 2; // show_frame, error_resilient
			if ftype == 0 {
				pos += 24; // sync code
				if profile >= 2 { bit_depth = ifx bit(frame, *pos) == 1 then 12 else 10; }
				cs := bits(frame, *pos, 3);
				if cs != 7 {
					full = bit(frame, *pos);
					if profile == 1 || profile == 3 {
						sx := bit(frame, *pos);
						sy := bit(frame, *pos);
						chroma = ifx sx == 1 && sy == 0 then 2 else (ifx sx == 0 && sy == 0 then 3 else 1);
					}
				} else {
					full = 1;
					chroma = 3;
				}
			}
		}
	}
	out := make_slice(u8, 12);
	out[0] = 1; // version
	out[4] = cast(u8)(profile);
	out[5] = 10; // level 1.0 (unknown; decoder ignores)
	out[6] = cast(u8)((bit_depth << 4) | (chroma << 1) | full);
	out[7] = 1;
	out[8] = 1;
	out[9] = 1;
	return out;
}

vt_callback :: (ref: *void, frame_ref: *void, status: OSStatus, flags: u32, image: CFRef, pts: CMTime, dur: CMTime) #c_call {
	vd := cast(*Video_Decoder)(ref);
	__ctx2 := vd.ctx; push_context,defer_pop __ctx2;
	if status != 0 || image == null {
		vd.errors += 1;
		return;
	}
	CFRetain(image);
	f := Video_Frame.{
		pts = ifx pts.timescale != 0 then cast(float64)(pts.value) / cast(float64)(pts.timescale) else 0,
		dur = ifx dur.timescale != 0 then cast(float64)(dur.value) / cast(float64)(dur.timescale) else 0,
		pixbuf = image,
		width = cast(int)(CVPixelBufferGetWidth(image)),
		height = cast(int)(CVPixelBufferGetHeight(image)),
		yuv = .BT601
	};
	{ m := CVBufferCopyAttachment(image, kCVImageBufferYCbCrMatrixKey, null);
	if m != null {
		if CFEqual(m, kCVImageBufferYCbCrMatrix_ITU_R_709_2) { f.yuv = .BT709; }
		CFRelease(m);
	} else if f.height >= 720 {
		f.yuv = .BT709;
	} }
	if CVPixelBufferGetPixelFormatType(image) == fourcc("420f") {
		f.yuv = ifx f.yuv == .BT709 then .BT709_Full else .BT601_Full;
	}
	locks.lock(*vd.mu);
	append(*vd.out, f);
	locks.unlock(*vd.mu);
}
#scope_export

// first_packet: needed for VP9 in WebM (no vpcC in the container).
video_decoder_create :: (t: *Track, first_packet: []u8 = .{}) -> *Video_Decoder, bool {
	if !video_codec_supported(t.codec) { return null, false; }
	codec: u32;
	atom: string;
	extradata := t.extradata;
	owned: []u8;
	defer delete(owned);
	if t.codec == {
	case .H264; codec, atom = fourcc("avc1"), "avcC";
	case .HEVC; codec, atom = fourcc("hvc1"), "hvcC";
	case .VP9;
		codec, atom = fourcc("vp09"), "vpcC";
		if len(extradata) < 8 {
			owned = vpcc_from_keyframe(first_packet);
			extradata = owned;
		}
	case .AV1; codec, atom = fourcc("av01"), "av1C";
	case .VP8; #through; case .Unknown; #through; case .AAC; #through; case .MP3; #through; case .Opus; #through; case .Vorbis; #through; case .FLAC; #through; case .PCM; return null, false;
	}
	if len(extradata) == 0 { return null, false; }

	data := CFDataCreate(null, raw_data(extradata), len(extradata));
	defer CFRelease(data);
	akey := cfstr(atom);
	defer CFRelease(akey);
	atoms := dict(CFRef.[akey], CFRef.[data]);
	defer CFRelease(atoms);
	ext := dict(CFRef.[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms], CFRef.[atoms]);
	defer CFRelease(ext);

	vd := new(Video_Decoder);
	vd.ctx = context;
	{ st := CMVideoFormatDescriptionCreate(null, codec, cast(s32)(t.width), cast(s32)(t.height), ext, *vd.format);
	if st != 0 {
		last_video_error = st;
		free(vd);
		return null, false;
	} }
	pf: s32 = cast(s32)(fourcc("420v"));
	pfn := CFNumberCreate(null, 3, *pf);
	defer CFRelease(pfn);
	empty := dict(.{}, .{});
	defer CFRelease(empty);
	attrs := dict(CFRef.[kCVPixelBufferPixelFormatTypeKey, kCVPixelBufferMetalCompatibilityKey, kCVPixelBufferIOSurfacePropertiesKey], CFRef.[pfn, kCFBooleanTrue, empty]);
	defer CFRelease(attrs);
	cb := VTDecompressionOutputCallbackRecord.{vt_callback, vd};
	{ st := VTDecompressionSessionCreate(null, vd.format, null, attrs, *cb, *vd.session);
	if st != 0 {
		last_video_error = st;
		CFRelease(vd.format);
		free(vd);
		return null, false;
	} }
	return vd, true;
}

// Decode one access unit (synchronously). Output frames land in vd.out.
video_decode :: (vd: *Video_Decoder, data: []u8, pts: float64, dts: float64, dur: float64) -> bool {
	if len(data) == 0 { return true; }
	bb: CFRef;
	if CMBlockBufferCreateWithMemoryBlock(null, raw_data(data), cast(u64)(len(data)), kCFAllocatorNull, null, 0, cast(u64)(len(data)), 0, *bb) != 0 { return false; }
	defer CFRelease(bb);
	timing := CMSampleTimingInfo.{
		duration = .{cast(s64)(dur * 1_000_000), 1_000_000, 1, 0},
		pts = .{cast(s64)(pts * 1_000_000), 1_000_000, 1, 0},
		dts = .{cast(s64)(dts * 1_000_000), 1_000_000, 1, 0}
	};
	size := cast(u64)(len(data));
	sb: CFRef;
	if CMSampleBufferCreateReady(null, bb, vd.format, 1, 1, *timing, 1, *size, *sb) != 0 { return false; }
	defer CFRelease(sb);
	info: u32;
	st := VTDecompressionSessionDecodeFrame(vd.session, sb, 0, null, *info);
	return st == 0;
}

video_decoder_flush :: (vd: *Video_Decoder) {
	VTDecompressionSessionWaitForAsynchronousFrames(vd.session);
}

// Take decoded frames (caller owns them; release with video_frame_release).
video_decoder_take :: (vd: *Video_Decoder, out: *[..]Video_Frame) {
	locks.lock(*vd.mu);
	append(out, ..view(vd.out));
	clear(*vd.out);
	locks.unlock(*vd.mu);
}

video_decoder_destroy :: (vd: *Video_Decoder) {
	if vd == null { return; }
	VTDecompressionSessionWaitForAsynchronousFrames(vd.session);
	VTDecompressionSessionInvalidate(vd.session);
	CFRelease(vd.session);
	CFRelease(vd.format);
	for f: vd.out { CFRelease(f.pixbuf); }
	delete(vd.out);
	free(vd);
}

video_frame_release :: (f: *Video_Frame) {
	if f.pixbuf != null { CFRelease(f.pixbuf); }
	f.pixbuf = null;
}
#scope_file

// ---- Zero-copy textures

// ---- Zero-copy textures

tex_cache: CFRef;

Tex_Hold :: struct {
	cvtex: CFRef;
	pixbuf: CFRef;
}

release_hold :: (user: *void) {
	h := cast(*Tex_Hold)(user);
	CFRelease(h.cvtex);
	CFRelease(h.pixbuf);
	free(h);
}
#scope_export

// Wrap the frame's Y and CbCr planes as gfx textures (no copy). Destroy them
// with gfx.texture_destroy; the pixel buffer stays alive until the GPU is done.
video_frame_textures :: (f: *Video_Frame) -> gfx.Texture, gfx.Texture, bool {
	y: gfx.Texture;
	cbcr: gfx.Texture;
	ok: bool;
	if f.pixbuf == null { return y, cbcr, ok; }
	if tex_cache == null {
		if CVMetalTextureCacheCreate(null, null, gfx.native_device(), null, *tex_cache) != 0 { return y, cbcr, ok; }
	}
	planes: [2]gfx.Texture;
	for p: 0..1 {
		w := CVPixelBufferGetWidthOfPlane(f.pixbuf, cast(u64)(p));
		h := CVPixelBufferGetHeightOfPlane(f.pixbuf, cast(u64)(p));
		pf: u64 = cast(u64) ifx p == 0 then 10 else 30; /*RG8Unorm*/
		cv: CFRef;
		if CVMetalTextureCacheCreateTextureFromImage(null, tex_cache, f.pixbuf, null, pf, w, h, cast(u64)(p), *cv) != 0 || cv == null {
			if p == 1 { gfx.texture_destroy(planes[0]); }
			return y, cbcr, ok;
		}
		hold := new(Tex_Hold);
		hold.* = .{cv, CFRetain(f.pixbuf)};
		planes[p] = gfx.texture_wrap_native(CVMetalTextureGetTexture(cv), cast(int)(w), cast(int)(h), ifx p == 0 then gfx.Texture_Format.R8 else .RG8, release_hold, hold);
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
#scope_file

NO_DATA :: cast(OSStatus)(0x6e6f6474);
#scope_export
#scope_file // 'nodt'

// Wrap an AudioSpecificConfig in an MPEG-4 ES_Descriptor (AudioToolbox's AAC magic cookie).
esds_from_asc :: (asc: []u8) -> []u8 {
	b := make_dynamic(u8, 0, 0);
	dsi_len := len(asc);
	dcd_len := 13 + 2 + dsi_len;
	es_len := 3 + 2 + dcd_len + 3;
	append(*b, 0x03, cast(u8)(es_len), 0, 1, 0);
	append(*b, 0x04, cast(u8)(dcd_len), 0x40, 0x15, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
	append(*b, 0x05, cast(u8)(dsi_len));
	append(*b, ..asc);
	append(*b, 0x06, 0x01, 0x02);
	return view(b);
}
#scope_file

input_proc :: (conv: *void, n_packets: *u32, data: *audio.AudioBufferList, desc: **AudioStreamPacketDescription, user: *void) -> OSStatus #c_call {
	ad := cast(*Audio_Decoder)(user);
	if ad.pkt_given || ad.pkt.count == 0 {
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
		n_packets.* = cast(u32) ad.pkt.count / (ifx ad.in_fmt.mBytesPerPacket > 1 then ad.in_fmt.mBytesPerPacket else 1);
	} else {
		n_packets.* = 1;
		ad.pkt_desc = .{0, 0, cast(u32) ad.pkt.count};
		if desc != null { desc.* = *ad.pkt_desc; }
	}
	return 0;
}
#scope_export

audio_codec_supported :: (c: Codec) -> bool {
	if c == {
	case .AAC; #through; case .MP3; #through; case .Opus; #through; case .FLAC; #through; case .PCM; return true;
	}
	return false;
}

audio_decoder_create :: (t: *Track) -> *Audio_Decoder, bool {
	if !audio_codec_supported(t.codec) { return null, false; }
	ad := new(Audio_Decoder);
	ad.codec = t.codec;
	ch := max(t.channels, 1);
	rate := ifx t.sample_rate > 0 then t.sample_rate else 48000;
	f := *ad.in_fmt;
	f.mSampleRate = cast(float64)(rate);
	f.mChannelsPerFrame = cast(u32)(ch);
	cookie: []u8;
	owned: []u8;
	defer delete(owned);
	if t.codec == {
	case .AAC;
		f.mFormatID = fourcc("aac ");
		f.mFramesPerPacket = 1024;
		if len(t.aac_asc) >= 2 {
			owned = esds_from_asc(t.aac_asc);
			cookie = owned;
			// sample rate from ASC
			idx := cast(int)(((t.aac_asc[0] & 7) << 1) | (t.aac_asc[1] >> 7));
			RATES := int.[96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350];
			if idx < 13 { f.mSampleRate = cast(float64)(RATES[idx]); }
		} else {
			cookie = t.extradata;
		}
	case .MP3;
		f.mFormatID = fourcc(".mp3");
		f.mFramesPerPacket = cast(u32) ifx rate < 32000 then 576 else 1152;
	case .Opus;
		f.mFormatID = fourcc("opus");
		f.mSampleRate = 48000;
		f.mFramesPerPacket = 960;
		cookie = t.extradata;
	case .FLAC;
		f.mFormatID = fourcc("flac");
		if len(t.extradata) >= 4 + 34 {
			f.mFramesPerPacket = cast(u32)(be16(sub_from(t.extradata, 4 + 2))); // max block size
			f.mBitsPerChannel = 0;
		}
		cookie = t.extradata;
	case .PCM;
		bits := max(t.bits, 8);
		f.mFormatID = audio.kAudioFormatLinearPCM;
		f.mFormatFlags = (cast(u32) audio.kAudioFormatFlagIsPacked) | cast(u32) (ifx t.pcm_float then audio.kAudioFormatFlagIsFloat else (ifx bits > 8 then audio.kAudioFormatFlagIsSignedInteger else 0));
		if t.pcm_big { f.mFormatFlags |= 2; }
		f.mBitsPerChannel = cast(u32)(bits);
		f.mBytesPerFrame = cast(u32)(bits / 8 * ch);
		f.mBytesPerPacket = f.mBytesPerFrame;
		f.mFramesPerPacket = 1;
	case .Unknown; #through; case .H264; #through; case .HEVC; #through; case .VP8; #through; case .VP9; #through; case .AV1; #through; case .Vorbis;
		free(ad);
		return null, false;
	}
	ad.out_ch = min(ch, 2);
	out := audio.AudioStreamBasicDescription.{
		mSampleRate = audio.SAMPLE_RATE,
		mFormatID = audio.kAudioFormatLinearPCM,
		mFormatFlags = audio.kAudioFormatFlagIsFloat | audio.kAudioFormatFlagIsPacked,
		mBytesPerPacket = cast(u32)(4 * ad.out_ch),
		mFramesPerPacket = 1,
		mBytesPerFrame = cast(u32)(4 * ad.out_ch),
		mChannelsPerFrame = cast(u32)(ad.out_ch),
		mBitsPerChannel = 32
	};
	if AudioConverterNew(*ad.in_fmt, *out, *ad.conv) != 0 {
		free(ad);
		return null, false;
	}
	if len(cookie) > 0 {
		AudioConverterSetProperty(ad.conv, fourcc("dmgc"), cast(u32)(len(cookie)), raw_data(cookie));
	}
	ad.scratch = make_slice(float32, 8192 * 2);
	return ad, true;
}

// Decode one packet; appends interleaved stereo f32 @48 kHz to out.
audio_decode :: (ad: *Audio_Decoder, data: []u8, out: *[..]float32) -> bool {
	ad.pkt = data;
	ad.pkt_given = false;
	while true {
		frames := cast(u32)(len(ad.scratch) / ad.out_ch);
		abl := audio.AudioBufferList.{mNumberBuffers = 1};
		abl.mBuffers[0] = .{cast(u32)(ad.out_ch), cast(u32)(len(ad.scratch) * 4), raw_data(ad.scratch)};
		st := AudioConverterFillComplexBuffer(ad.conv, input_proc, ad, *frames, *abl, null);
		if frames > 0 { audio.to_stereo(out, sub(ad.scratch, 0, cast(int)(frames) * ad.out_ch), ad.out_ch); }
		if st != 0 && st != NO_DATA { return false; }
		if frames == 0 || st == NO_DATA { break; }
	}
	ad.pkt = .{};
	return true;
}

audio_decoder_reset :: (ad: *Audio_Decoder) {
	AudioConverterReset(ad.conv);
}

audio_decoder_destroy :: (ad: *Audio_Decoder) {
	if ad == null { return; }
	AudioConverterDispose(ad.conv);
	delete(ad.scratch);
	free(ad);
}

