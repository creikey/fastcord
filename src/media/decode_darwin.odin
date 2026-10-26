#+build darwin
package media

// macOS decoders: VideoToolbox (hardware H.264/HEVC/VP9/AV1 -> NV12
// CVPixelBuffers, wrapped as Metal textures through CVMetalTextureCache, zero
// copy) and AudioToolbox AudioConverter (AAC/MP3/Opus/FLAC/PCM -> f32 @ 48 kHz).

import "base:runtime"
import "core:sync"
import "fc:gfx"
import "fc:audio"

foreign import CoreFoundation "system:CoreFoundation.framework"
foreign import CoreMedia "system:CoreMedia.framework"
foreign import CoreVideo "system:CoreVideo.framework"
foreign import VideoToolbox "system:VideoToolbox.framework"
foreign import AudioToolbox "system:AudioToolbox.framework"

@(private = "file") CFRef :: rawptr
@(private = "file") OSStatus :: i32

CMTime :: struct {
	value:     i64,
	timescale: i32,
	flags:     u32,
	epoch:     i64,
}

@(private = "file")
CMSampleTimingInfo :: struct {
	duration, pts, dts: CMTime,
}

@(private = "file")
VTDecompressionOutputCallbackRecord :: struct {
	callback: proc "c" (ref: rawptr, frame_ref: rawptr, status: OSStatus, flags: u32, image: CFRef, pts: CMTime, dur: CMTime),
	refcon:   rawptr,
}

@(private = "file", default_calling_convention = "c")
foreign CoreFoundation {
	CFRelease :: proc(cf: CFRef) ---
	CFRetain :: proc(cf: CFRef) -> CFRef ---
	CFEqual :: proc(a, b: CFRef) -> b8 ---
	CFDataCreate :: proc(alloc: CFRef, bytes: [^]u8, n: int) -> CFRef ---
	CFStringCreateWithBytes :: proc(alloc: CFRef, bytes: [^]u8, n: int, enc: u32, ext: b8) -> CFRef ---
	CFDictionaryCreate :: proc(alloc: CFRef, keys: [^]CFRef, values: [^]CFRef, n: int, kcb: rawptr, vcb: rawptr) -> CFRef ---
	CFNumberCreate :: proc(alloc: CFRef, type: int, value: rawptr) -> CFRef ---
	kCFTypeDictionaryKeyCallBacks: [6]uintptr
	kCFTypeDictionaryValueCallBacks: [6]uintptr
	kCFBooleanTrue: CFRef
	kCFAllocatorNull: CFRef
}

@(private = "file", default_calling_convention = "c")
foreign CoreMedia {
	CMVideoFormatDescriptionCreate :: proc(alloc: CFRef, codec: u32, w, h: i32, ext: CFRef, out: ^CFRef) -> OSStatus ---
	CMBlockBufferCreateWithMemoryBlock :: proc(alloc: CFRef, mem: rawptr, len: uint, block_alloc: CFRef, custom: rawptr, offset: uint, data_len: uint, flags: u32, out: ^CFRef) -> OSStatus ---
	CMSampleBufferCreateReady :: proc(alloc: CFRef, data: CFRef, fmt: CFRef, nsamples: int, ntiming: int, timing: ^CMSampleTimingInfo, nsizes: int, sizes: ^uint, out: ^CFRef) -> OSStatus ---
	kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: CFRef
}

@(private = "file", default_calling_convention = "c")
foreign CoreVideo {
	CVPixelBufferGetWidth :: proc(pb: CFRef) -> uint ---
	CVPixelBufferGetHeight :: proc(pb: CFRef) -> uint ---
	CVPixelBufferGetWidthOfPlane :: proc(pb: CFRef, plane: uint) -> uint ---
	CVPixelBufferGetHeightOfPlane :: proc(pb: CFRef, plane: uint) -> uint ---
	CVPixelBufferGetPixelFormatType :: proc(pb: CFRef) -> u32 ---
	CVBufferCopyAttachment :: proc(buf: CFRef, key: CFRef, mode: ^u32) -> CFRef ---
	CVMetalTextureCacheCreate :: proc(alloc: CFRef, attrs: CFRef, device: rawptr, tex_attrs: CFRef, out: ^CFRef) -> i32 ---
	CVMetalTextureCacheCreateTextureFromImage :: proc(alloc: CFRef, cache: CFRef, image: CFRef, attrs: CFRef, pf: uint, w, h: uint, plane: uint, out: ^CFRef) -> i32 ---
	CVMetalTextureCacheFlush :: proc(cache: CFRef, flags: u64) ---
	CVMetalTextureGetTexture :: proc(tex: CFRef) -> rawptr ---
	kCVPixelBufferPixelFormatTypeKey: CFRef
	kCVPixelBufferMetalCompatibilityKey: CFRef
	kCVPixelBufferIOSurfacePropertiesKey: CFRef
	kCVImageBufferYCbCrMatrixKey: CFRef
	kCVImageBufferYCbCrMatrix_ITU_R_709_2: CFRef
}

@(private = "file", default_calling_convention = "c")
foreign VideoToolbox {
	VTDecompressionSessionCreate :: proc(alloc: CFRef, fmt: CFRef, decoder_spec: CFRef, image_attrs: CFRef, cb: ^VTDecompressionOutputCallbackRecord, out: ^CFRef) -> OSStatus ---
	VTDecompressionSessionDecodeFrame :: proc(s: CFRef, sample: CFRef, flags: u32, frame_ref: rawptr, info_out: ^u32) -> OSStatus ---
	VTDecompressionSessionWaitForAsynchronousFrames :: proc(s: CFRef) -> OSStatus ---
	VTDecompressionSessionInvalidate :: proc(s: CFRef) ---
	VTRegisterSupplementalVideoDecoderIfAvailable :: proc(codec: u32) ---
	VTIsHardwareDecodeSupported :: proc(codec: u32) -> b8 ---
}

@(private = "file")
AudioStreamPacketDescription :: struct {
	mStartOffset:           i64,
	mVariableFramesInPacket: u32,
	mDataByteSize:          u32,
}

@(private = "file")
Input_Proc :: #type proc "c" (conv: rawptr, n_packets: ^u32, data: ^audio.AudioBufferList, desc: ^^AudioStreamPacketDescription, user: rawptr) -> OSStatus

@(private = "file", default_calling_convention = "c")
foreign AudioToolbox {
	AudioConverterNew :: proc(in_fmt, out_fmt: ^audio.AudioStreamBasicDescription, out: ^rawptr) -> OSStatus ---
	AudioConverterDispose :: proc(c: rawptr) -> OSStatus ---
	AudioConverterReset :: proc(c: rawptr) -> OSStatus ---
	AudioConverterSetProperty :: proc(c: rawptr, id: u32, size: u32, data: rawptr) -> OSStatus ---
	AudioConverterFillComplexBuffer :: proc(c: rawptr, input: Input_Proc, user: rawptr, out_packets: ^u32, out: ^audio.AudioBufferList, desc: rawptr) -> OSStatus ---
}

fourcc :: audio.fourcc

@(private = "file")
cfstr :: proc(s: string) -> CFRef {return CFStringCreateWithBytes(nil, raw_data(s), len(s), 0x08000100, false)}

@(private = "file")
dict :: proc(keys: []CFRef, vals: []CFRef) -> CFRef {
	return CFDictionaryCreate(nil, raw_data(keys), raw_data(vals), len(keys), &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks)
}

// ---------------------------------------------------------------------------
// Video

Video_Frame :: struct {
	pts:     f64, // seconds
	dur:     f64,
	pixbuf:  rawptr, // CVPixelBuffer (retained)
	width:   int,
	height:  int,
	yuv:     gfx.Yuv_Matrix,
}

// OSStatus of the last failed video_decoder_create (diagnostics; e.g. -12910 = unsupported format).
last_video_error: i32

Video_Decoder :: struct {
	session:   CFRef,
	format:    CFRef,
	mu:        sync.Mutex,
	out:       [dynamic]Video_Frame, // decoded, in output order (caller sorts)
	errors:    int,
	ctx:       runtime.Context,
}

video_codec_supported :: proc(c: Codec) -> bool {
	switch c {
	case .H264, .HEVC: return true
	case .VP9:
		VTRegisterSupplementalVideoDecoderIfAvailable(fourcc("vp09"))
		return true
	case .AV1: return bool(VTIsHardwareDecodeSupported(fourcc("av01")))
	case .VP8, .Unknown, .AAC, .MP3, .Opus, .Vorbis, .FLAC, .PCM: return false
	}
	return false
}

// Build a vpcC (with version/flags) from a VP9 keyframe's uncompressed header.
@(private = "file")
vpcc_from_keyframe :: proc(frame: []u8) -> []u8 {
	profile, bit_depth, chroma, full := 0, 8, 1, 0
	if len(frame) >= 10 {
		// bit reader
		pos := 0
		bit :: proc(b: []u8, pos: ^int) -> int {
			if pos^ / 8 >= len(b) do return 0
			v := int(b[pos^ / 8] >> uint(7 - pos^ % 8)) & 1
			pos^ += 1
			return v
		}
		bits :: proc(b: []u8, pos: ^int, n: int) -> int {
			v := 0
			for _ in 0 ..< n do v = v << 1 | bit(b, pos)
			return v
		}
		_ = bits(frame, &pos, 2) // frame marker
		lo := bit(frame, &pos)
		hi := bit(frame, &pos)
		profile = hi << 1 | lo
		if profile == 3 do pos += 1
		if bit(frame, &pos) == 0 { 	// show_existing_frame == 0
			ftype := bit(frame, &pos)
			pos += 2 // show_frame, error_resilient
			if ftype == 0 {
				pos += 24 // sync code
				if profile >= 2 do bit_depth = bit(frame, &pos) == 1 ? 12 : 10
				cs := bits(frame, &pos, 3)
				if cs != 7 {
					full = bit(frame, &pos)
					if profile == 1 || profile == 3 {
						sx := bit(frame, &pos)
						sy := bit(frame, &pos)
						chroma = sx == 1 && sy == 0 ? 2 : (sx == 0 && sy == 0 ? 3 : 1)
					}
				} else {
					full = 1
					chroma = 3
				}
			}
		}
	}
	out := make([]u8, 12)
	out[0] = 1 // version
	out[4] = u8(profile)
	out[5] = 10 // level 1.0 (unknown; decoder ignores)
	out[6] = u8(bit_depth << 4 | chroma << 1 | full)
	out[7] = 1
	out[8] = 1
	out[9] = 1
	return out
}

@(private = "file")
vt_callback :: proc "c" (ref: rawptr, frame_ref: rawptr, status: OSStatus, flags: u32, image: CFRef, pts: CMTime, dur: CMTime) {
	vd := (^Video_Decoder)(ref)
	context = vd.ctx
	if status != 0 || image == nil {
		vd.errors += 1
		return
	}
	CFRetain(image)
	f := Video_Frame {
		pts    = pts.timescale != 0 ? f64(pts.value) / f64(pts.timescale) : 0,
		dur    = dur.timescale != 0 ? f64(dur.value) / f64(dur.timescale) : 0,
		pixbuf = image,
		width  = int(CVPixelBufferGetWidth(image)),
		height = int(CVPixelBufferGetHeight(image)),
		yuv    = .BT601,
	}
	if m := CVBufferCopyAttachment(image, kCVImageBufferYCbCrMatrixKey, nil); m != nil {
		if CFEqual(m, kCVImageBufferYCbCrMatrix_ITU_R_709_2) do f.yuv = .BT709
		CFRelease(m)
	} else if f.height >= 720 {
		f.yuv = .BT709
	}
	if CVPixelBufferGetPixelFormatType(image) == fourcc("420f") {
		f.yuv = f.yuv == .BT709 ? .BT709_Full : .BT601_Full
	}
	sync.mutex_lock(&vd.mu)
	append(&vd.out, f)
	sync.mutex_unlock(&vd.mu)
}

// first_packet: needed for VP9 in WebM (no vpcC in the container).
video_decoder_create :: proc(t: ^Track, first_packet: []u8 = nil) -> (^Video_Decoder, bool) {
	if !video_codec_supported(t.codec) do return nil, false
	codec: u32
	atom: string
	extradata := t.extradata
	owned: []u8
	defer delete(owned)
	switch t.codec {
	case .H264: codec, atom = fourcc("avc1"), "avcC"
	case .HEVC: codec, atom = fourcc("hvc1"), "hvcC"
	case .VP9:
		codec, atom = fourcc("vp09"), "vpcC"
		if len(extradata) < 8 {
			owned = vpcc_from_keyframe(first_packet)
			extradata = owned
		}
	case .AV1: codec, atom = fourcc("av01"), "av1C"
	case .VP8, .Unknown, .AAC, .MP3, .Opus, .Vorbis, .FLAC, .PCM: return nil, false
	}
	if len(extradata) == 0 do return nil, false

	data := CFDataCreate(nil, raw_data(extradata), len(extradata))
	defer CFRelease(data)
	akey := cfstr(atom)
	defer CFRelease(akey)
	atoms := dict({akey}, {data})
	defer CFRelease(atoms)
	ext := dict({kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms}, {atoms})
	defer CFRelease(ext)

	vd := new(Video_Decoder)
	vd.ctx = context
	if st := CMVideoFormatDescriptionCreate(nil, codec, i32(t.width), i32(t.height), ext, &vd.format); st != 0 {
		last_video_error = st
		free(vd)
		return nil, false
	}
	pf: i32 = i32(fourcc("420v"))
	pfn := CFNumberCreate(nil, 3 /*SInt32*/, &pf)
	defer CFRelease(pfn)
	empty := dict({}, {})
	defer CFRelease(empty)
	attrs := dict({kCVPixelBufferPixelFormatTypeKey, kCVPixelBufferMetalCompatibilityKey, kCVPixelBufferIOSurfacePropertiesKey}, {pfn, kCFBooleanTrue, empty})
	defer CFRelease(attrs)
	cb := VTDecompressionOutputCallbackRecord{vt_callback, vd}
	if st := VTDecompressionSessionCreate(nil, vd.format, nil, attrs, &cb, &vd.session); st != 0 {
		last_video_error = st
		CFRelease(vd.format)
		free(vd)
		return nil, false
	}
	return vd, true
}

// Decode one access unit (synchronously). Output frames land in vd.out.
video_decode :: proc(vd: ^Video_Decoder, data: []u8, pts, dts, dur: f64) -> bool {
	if len(data) == 0 do return true
	bb: CFRef
	if CMBlockBufferCreateWithMemoryBlock(nil, raw_data(data), uint(len(data)), kCFAllocatorNull, nil, 0, uint(len(data)), 0, &bb) != 0 do return false
	defer CFRelease(bb)
	timing := CMSampleTimingInfo {
		duration = {i64(dur * 1_000_000), 1_000_000, 1, 0},
		pts      = {i64(pts * 1_000_000), 1_000_000, 1, 0},
		dts      = {i64(dts * 1_000_000), 1_000_000, 1, 0},
	}
	size := uint(len(data))
	sb: CFRef
	if CMSampleBufferCreateReady(nil, bb, vd.format, 1, 1, &timing, 1, &size, &sb) != 0 do return false
	defer CFRelease(sb)
	info: u32
	st := VTDecompressionSessionDecodeFrame(vd.session, sb, 0, nil, &info)
	return st == 0
}

video_decoder_flush :: proc(vd: ^Video_Decoder) {
	VTDecompressionSessionWaitForAsynchronousFrames(vd.session)
}

// Take decoded frames (caller owns them; release with video_frame_release).
video_decoder_take :: proc(vd: ^Video_Decoder, out: ^[dynamic]Video_Frame) {
	sync.mutex_lock(&vd.mu)
	append(out, ..vd.out[:])
	clear(&vd.out)
	sync.mutex_unlock(&vd.mu)
}

video_decoder_destroy :: proc(vd: ^Video_Decoder) {
	if vd == nil do return
	VTDecompressionSessionWaitForAsynchronousFrames(vd.session)
	VTDecompressionSessionInvalidate(vd.session)
	CFRelease(vd.session)
	CFRelease(vd.format)
	for f in vd.out do CFRelease(f.pixbuf)
	delete(vd.out)
	free(vd)
}

video_frame_release :: proc(f: ^Video_Frame) {
	if f.pixbuf != nil do CFRelease(f.pixbuf)
	f.pixbuf = nil
}

// ---- Zero-copy textures

@(private = "file")
tex_cache: CFRef

@(private = "file")
Tex_Hold :: struct {
	cvtex:  CFRef,
	pixbuf: CFRef,
}

@(private = "file")
release_hold :: proc(user: rawptr) {
	h := (^Tex_Hold)(user)
	CFRelease(h.cvtex)
	CFRelease(h.pixbuf)
	free(h)
}

// Wrap the frame's Y and CbCr planes as gfx textures (no copy). Destroy them
// with gfx.texture_destroy; the pixel buffer stays alive until the GPU is done.
video_frame_textures :: proc(f: ^Video_Frame) -> (y, cbcr: gfx.Texture, ok: bool) {
	if f.pixbuf == nil do return
	if tex_cache == nil {
		if CVMetalTextureCacheCreate(nil, nil, gfx.native_device(), nil, &tex_cache) != 0 do return
	}
	planes: [2]gfx.Texture
	for p in 0 ..< 2 {
		w := CVPixelBufferGetWidthOfPlane(f.pixbuf, uint(p))
		h := CVPixelBufferGetHeightOfPlane(f.pixbuf, uint(p))
		pf: uint = p == 0 ? 10 /*R8Unorm*/ : 30 /*RG8Unorm*/
		cv: CFRef
		if CVMetalTextureCacheCreateTextureFromImage(nil, tex_cache, f.pixbuf, nil, pf, w, h, uint(p), &cv) != 0 || cv == nil {
			if p == 1 do gfx.texture_destroy(planes[0])
			return
		}
		hold := new(Tex_Hold)
		hold^ = {cv, CFRetain(f.pixbuf)}
		planes[p] = gfx.texture_wrap_native(CVMetalTextureGetTexture(cv), int(w), int(h), p == 0 ? .R8 : .RG8, release_hold, hold)
	}
	return planes[0], planes[1], true
}

// ---------------------------------------------------------------------------
// Audio

Audio_Decoder :: struct {
	conv:      rawptr,
	in_fmt:    audio.AudioStreamBasicDescription,
	out_ch:    int,
	codec:     Codec,
	// current input packet for the input proc
	pkt:       []u8,
	pkt_desc:  AudioStreamPacketDescription,
	pkt_given: bool,
	scratch:   []f32,
}

@(private = "file")
NO_DATA :: OSStatus(0x6e6f6474) // 'nodt'

// Wrap an AudioSpecificConfig in an MPEG-4 ES_Descriptor (AudioToolbox's AAC magic cookie).
@(private = "file")
esds_from_asc :: proc(asc: []u8) -> []u8 {
	b := make([dynamic]u8)
	dsi_len := len(asc)
	dcd_len := 13 + 2 + dsi_len
	es_len := 3 + 2 + dcd_len + 3
	append(&b, 0x03, u8(es_len), 0, 1, 0)
	append(&b, 0x04, u8(dcd_len), 0x40, 0x15, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	append(&b, 0x05, u8(dsi_len))
	append(&b, ..asc)
	append(&b, 0x06, 0x01, 0x02)
	return b[:]
}

@(private = "file")
input_proc :: proc "c" (conv: rawptr, n_packets: ^u32, data: ^audio.AudioBufferList, desc: ^^AudioStreamPacketDescription, user: rawptr) -> OSStatus {
	ad := (^Audio_Decoder)(user)
	if ad.pkt_given || len(ad.pkt) == 0 {
		n_packets^ = 0
		data.mBuffers[0].mDataByteSize = 0
		data.mBuffers[0].mData = nil
		return NO_DATA
	}
	ad.pkt_given = true
	data.mNumberBuffers = 1
	data.mBuffers[0].mData = raw_data(ad.pkt)
	data.mBuffers[0].mDataByteSize = u32(len(ad.pkt))
	data.mBuffers[0].mNumberChannels = ad.in_fmt.mChannelsPerFrame
	if ad.in_fmt.mFormatID == audio.kAudioFormatLinearPCM {
		n_packets^ = u32(len(ad.pkt)) / max(ad.in_fmt.mBytesPerPacket, 1)
	} else {
		n_packets^ = 1
		ad.pkt_desc = {0, 0, u32(len(ad.pkt))}
		if desc != nil do desc^ = &ad.pkt_desc
	}
	return 0
}

audio_codec_supported :: proc(c: Codec) -> bool {
	#partial switch c {
	case .AAC, .MP3, .Opus, .FLAC, .PCM: return true
	}
	return false
}

audio_decoder_create :: proc(t: ^Track) -> (^Audio_Decoder, bool) {
	if !audio_codec_supported(t.codec) do return nil, false
	ad := new(Audio_Decoder)
	ad.codec = t.codec
	ch := max(t.channels, 1)
	rate := t.sample_rate > 0 ? t.sample_rate : 48000
	f := &ad.in_fmt
	f.mSampleRate = f64(rate)
	f.mChannelsPerFrame = u32(ch)
	cookie: []u8
	owned: []u8
	defer delete(owned)
	switch t.codec {
	case .AAC:
		f.mFormatID = fourcc("aac ")
		f.mFramesPerPacket = 1024
		if len(t.aac_asc) >= 2 {
			owned = esds_from_asc(t.aac_asc)
			cookie = owned
			// sample rate from ASC
			idx := int((t.aac_asc[0] & 7) << 1 | t.aac_asc[1] >> 7)
			RATES := [13]int{96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350}
			if idx < 13 do f.mSampleRate = f64(RATES[idx])
		} else {
			cookie = t.extradata
		}
	case .MP3:
		f.mFormatID = fourcc(".mp3")
		f.mFramesPerPacket = rate < 32000 ? 576 : 1152
	case .Opus:
		f.mFormatID = fourcc("opus")
		f.mSampleRate = 48000
		f.mFramesPerPacket = 960
		cookie = t.extradata
	case .FLAC:
		f.mFormatID = fourcc("flac")
		if len(t.extradata) >= 4 + 34 {
			f.mFramesPerPacket = u32(be16(t.extradata[4 + 2:])) // max block size
			f.mBitsPerChannel = 0
		}
		cookie = t.extradata
	case .PCM:
		bits := max(t.bits, 8)
		f.mFormatID = audio.kAudioFormatLinearPCM
		f.mFormatFlags = audio.kAudioFormatFlagIsPacked | (t.pcm_float ? audio.kAudioFormatFlagIsFloat : (bits > 8 ? audio.kAudioFormatFlagIsSignedInteger : 0))
		if t.pcm_big do f.mFormatFlags |= 2
		f.mBitsPerChannel = u32(bits)
		f.mBytesPerFrame = u32(bits / 8 * ch)
		f.mBytesPerPacket = f.mBytesPerFrame
		f.mFramesPerPacket = 1
	case .Unknown, .H264, .HEVC, .VP8, .VP9, .AV1, .Vorbis:
		free(ad)
		return nil, false
	}
	ad.out_ch = min(ch, 2)
	out := audio.AudioStreamBasicDescription {
		mSampleRate       = audio.SAMPLE_RATE,
		mFormatID         = audio.kAudioFormatLinearPCM,
		mFormatFlags      = audio.kAudioFormatFlagIsFloat | audio.kAudioFormatFlagIsPacked,
		mBytesPerPacket   = u32(4 * ad.out_ch),
		mFramesPerPacket  = 1,
		mBytesPerFrame    = u32(4 * ad.out_ch),
		mChannelsPerFrame = u32(ad.out_ch),
		mBitsPerChannel   = 32,
	}
	if AudioConverterNew(&ad.in_fmt, &out, &ad.conv) != 0 {
		free(ad)
		return nil, false
	}
	if len(cookie) > 0 {
		AudioConverterSetProperty(ad.conv, fourcc("dmgc"), u32(len(cookie)), raw_data(cookie))
	}
	ad.scratch = make([]f32, 8192 * 2)
	return ad, true
}

// Decode one packet; appends interleaved stereo f32 @48 kHz to out.
audio_decode :: proc(ad: ^Audio_Decoder, data: []u8, out: ^[dynamic]f32) -> bool {
	ad.pkt = data
	ad.pkt_given = false
	for {
		frames := u32(len(ad.scratch) / ad.out_ch)
		abl := audio.AudioBufferList{mNumberBuffers = 1}
		abl.mBuffers[0] = {u32(ad.out_ch), u32(len(ad.scratch) * 4), raw_data(ad.scratch)}
		st := AudioConverterFillComplexBuffer(ad.conv, input_proc, ad, &frames, &abl, nil)
		if frames > 0 do audio.to_stereo(out, ad.scratch[:int(frames) * ad.out_ch], ad.out_ch)
		if st != 0 && st != NO_DATA do return false
		if frames == 0 || st == NO_DATA do break
	}
	ad.pkt = nil
	return true
}

audio_decoder_reset :: proc(ad: ^Audio_Decoder) {
	AudioConverterReset(ad.conv)
}

audio_decoder_destroy :: proc(ad: ^Audio_Decoder) {
	if ad == nil do return
	AudioConverterDispose(ad.conv)
	delete(ad.scratch)
	free(ad)
}
