// Media Foundation and COM for Windows video: the codec MFTs (media's decoders, video's encoder) and camera
// capture, which trade yuv.Nv12 frames; and the AAC decoder MFT for media's audio. Windows only.

#import "Basic";
#import "Atomics";
#import "Windows";
#import "yuv";

// startup: MFStartup once per process (never shut down). Any thread.
startup :: () -> bool {
	if atomic_load(*started) == 0 {
		v := cast(s32) ifx SUCCEEDED(MFStartup(MF_VERSION, MFSTARTUP_NOSOCKET)) then 1 else 2;
		compare_and_swap(*started, 0, v);
	}
	return atomic_load(*started) == 1;
}

// COM on the calling thread for one call: com_leave(com_enter()). A thread that is already STA keeps it.
com_enter :: () -> bool { return CoInitializeEx(null, COINIT_MULTITHREADED) >= 0; }
com_leave :: (entered: bool) { if entered CoUninitialize(); }

// COM method i of obj's vtable, called as a C procedure of type T.
com :: inline (obj: *void, i: int, $T: Type) -> T #no_context { return cast(T) (cast(***void) obj).*[i]; }

release :: (obj: *void) #no_context {
	if obj com(obj, 2, #type (*void) -> u32 #c_call)(obj);
}

query :: (obj: *void, iid: *GUID) -> *void {
	out: *void;
	if com(obj, 0, #type (*void, *GUID, **void) -> HRESULT #c_call)(obj, iid, *out) < 0 return null;
	return out;
}

// IMFAttributes (IMFMediaType, IMFSample, IMFActivate inherit it).
get_u32 :: (a: *void, key: *GUID) -> u32, bool {
	v: u32;
	ok := com(a, 7, #type (*void, *GUID, *u32) -> HRESULT #c_call)(a, key, *v) >= 0;
	return v, ok;
}
get_u64 :: (a: *void, key: *GUID) -> u64, bool {
	v: u64;
	ok := com(a, 8, #type (*void, *GUID, *u64) -> HRESULT #c_call)(a, key, *v) >= 0;
	return v, ok;
}
get_guid :: (a: *void, key: *GUID) -> GUID {
	v: GUID;
	com(a, 10, #type (*void, *GUID, *GUID) -> HRESULT #c_call)(a, key, *v);
	return v;
}
has_subtype :: (t: *void, subtype: *GUID) -> bool {
	g := get_guid(t, *MF_MT_SUBTYPE);
	return memcmp(*g, subtype, size_of(GUID)) == 0;
}
get_blob ::(a: *void, key: *GUID, buf: []u8) -> int {
	n: u32;
	if com(a, 15, #type (*void, *GUID, *u8, u32, *u32) -> HRESULT #c_call)(a, key, buf.data, xx buf.count, *n) < 0 return 0;
	return n;
}
set_u32 :: (a: *void, key: *GUID, v: u32) -> bool { return com(a, 21, #type (*void, *GUID, u32) -> HRESULT #c_call)(a, key, v) >= 0; }
set_u64 :: (a: *void, key: *GUID, v: u64) -> bool { return com(a, 22, #type (*void, *GUID, u64) -> HRESULT #c_call)(a, key, v) >= 0; }
set_guid :: (a: *void, key: *GUID, v: *GUID) -> bool { return com(a, 24, #type (*void, *GUID, *GUID) -> HRESULT #c_call)(a, key, v) >= 0; }
set_blob :: (a: *void, key: *GUID, v: []u8) -> bool { return com(a, 26, #type (*void, *GUID, *u8, u32) -> HRESULT #c_call)(a, key, v.data, xx v.count) >= 0; }
set_unknown :: (a: *void, key: *GUID, v: *void) -> bool { return com(a, 27, #type (*void, *GUID, *void) -> HRESULT #c_call)(a, key, v) >= 0; }

// MF_MT_FRAME_SIZE, MF_MT_FRAME_RATE and friends pack two u32s, the first in the high half.
pair :: (hi: int, lo: int) -> u64 { return ((cast(u64) hi) << 32) | cast(u64) lo; }
unpair :: (v: u64) -> int, int { return cast(int) (v >> 32), cast(int) (v & 0xFFFF_FFFF); }

// A video media type: major type Video, the given subtype, progressive.
video_type :: (subtype: *GUID, width := 0, height := 0, fps := 0) -> *void {
	t: *void;
	if MFCreateMediaType(*t) < 0 return null;
	set_guid(t, *MF_MT_MAJOR_TYPE, *MFMediaType_Video);
	set_guid(t, *MF_MT_SUBTYPE, subtype);
	set_u32(t, *MF_MT_INTERLACE_MODE, 2);
	if width set_u64(t, *MF_MT_FRAME_SIZE, pair(width, height));
	if fps set_u64(t, *MF_MT_FRAME_RATE, pair(fps, 1));
	return t;
}

subtype_guid :: (fourcc: string) -> GUID {
	g := MFMediaType_Video;
	g.Data1 = (cast(u32) fourcc[0]) | ((cast(u32) fourcc[1]) << 8) | ((cast(u32) fourcc[2]) << 16) | ((cast(u32) fourcc[3]) << 24);
	return g;
}

// IMFSample holding a copy of data, time and duration in 100 ns units.
sample_from_bytes :: (data: []u8, time: s64, duration: s64 = 0) -> *void {
	buf: *void;
	if MFCreateMemoryBuffer(xx data.count, *buf) < 0 return null;
	defer release(buf);
	p: *u8;
	if com(buf, 3, #type (*void, **u8, *u32, *u32) -> HRESULT #c_call)(buf, *p, null, null) < 0 return null;
	memcpy(p, data.data, data.count);
	com(buf, 4, #type (*void) -> HRESULT #c_call)(buf);
	com(buf, 6, #type (*void, u32) -> HRESULT #c_call)(buf, xx data.count);
	s: *void;
	if MFCreateSample(*s) < 0 return null;
	com(s, 42, #type (*void, *void) -> HRESULT #c_call)(s, buf);
	sample_set_time(s, time, duration);
	return s;
}

sample_set_time :: (s: *void, time: s64, duration: s64) {
	com(s, 36, #type (*void, s64) -> HRESULT #c_call)(s, time);
	if duration com(s, 38, #type (*void, s64) -> HRESULT #c_call)(s, duration);
}

sample_time :: (s: *void) -> s64 {
	t: s64;
	com(s, 35, #type (*void, *s64) -> HRESULT #c_call)(s, *t);
	return t;
}

// An empty sample with one buffer of n bytes, for MFTs that don't provide their own output samples.
sample_alloc :: (n: int) -> *void {
	buf: *void;
	if MFCreateMemoryBuffer(xx n, *buf) < 0 return null;
	defer release(buf);
	s: *void;
	if MFCreateSample(*s) < 0 return null;
	com(s, 42, #type (*void, *void) -> HRESULT #c_call)(s, buf);
	return s;
}

// The sample's bytes, contiguous and locked until sample_unlock(buf).
sample_lock :: (s: *void) -> buf: *void, bytes: []u8 {
	buf: *void;
	if com(s, 41, #type (*void, **void) -> HRESULT #c_call)(s, *buf) < 0 || !buf return null, .[];
	p: *u8;
	n: u32;
	if com(buf, 3, #type (*void, **u8, *u32, *u32) -> HRESULT #c_call)(buf, *p, null, *n) < 0 { release(buf); return null, .[]; }
	return buf, .{n, p};
}

sample_unlock :: (buf: *void) {
	if !buf return;
	com(buf, 4, #type (*void) -> HRESULT #c_call)(buf);
	release(buf);
}

// Copies an NV12 sample's visible w x h picture. frame_h is the type's MF_MT_FRAME_SIZE height (the decoder
// pads it, 1088 for 1080p), which places the CbCr plane; stride is MF_MT_DEFAULT_STRIDE or 0 for width.
nv12_from_sample :: (s: *void, w: int, h: int, frame_h: int, stride: int) -> *Nv12 {
	buf: *void;
	if com(s, 41, #type (*void, **void) -> HRESULT #c_call)(s, *buf) < 0 || !buf return null;
	defer release(buf);
	f: *Nv12;
	b2 := query(buf, *IID_IMF2DBuffer);
	if b2 {
		defer release(b2);
		p: *u8;
		pitch: s32;
		if com(b2, 3, #type (*void, **u8, *s32) -> HRESULT #c_call)(b2, *p, *pitch) < 0 return null;
		if pitch > 0 f = nv12_from_planes(w, h, p, p + pitch * frame_h, pitch);
		com(b2, 4, #type (*void) -> HRESULT #c_call)(b2);
		return f;
	}
	p: *u8;
	n: u32;
	if com(buf, 3, #type (*void, **u8, *u32, *u32) -> HRESULT #c_call)(buf, *p, null, *n) < 0 return null;
	pitch := ifx stride > 0 then stride else w;
	if pitch * frame_h * 3 / 2 <= cast(int) n f = nv12_from_planes(w, h, p, p + pitch * frame_h, pitch);
	com(buf, 4, #type (*void) -> HRESULT #c_call)(buf);
	return f;
}

// The visible size of a video type: MF_MT_MINIMUM_DISPLAY_APERTURE if set, else MF_MT_FRAME_SIZE.
visible_size :: (t: *void) -> w: int, h: int, frame_h: int {
	v := get_u64(t, *MF_MT_FRAME_SIZE);
	w, h := unpair(v);
	area: [16]u8; // MFVideoArea: OffsetX, OffsetY (MFOffset, 4 bytes each), Area (SIZE: two s32)
	if get_blob(t, *MF_MT_MINIMUM_DISPLAY_APERTURE, area) == 16 {
		aw := (cast(*s32) *area[8]).*;
		ah := (cast(*s32) *area[12]).*;
		if aw > 0 && ah > 0 && aw <= w && ah <= h return aw, ah, h;
	}
	return w, h, h;
}

// The first synchronous MFT in category that takes in_subtype and produces out_subtype (either may be null).
// hardware: the GPU's (asynchronous) MFTs instead of the software ones; an async MFT must be unlocked
// (MF_TRANSFORM_ASYNC_UNLOCK) and driven by its events (mft_event).
transform_find :: (category: *GUID, in_subtype: *GUID, out_subtype: *GUID, audio := false, hardware := false) -> *void {
	major := ifx audio then MFMediaType_Audio else MFMediaType_Video;
	inp := MFT_REGISTER_TYPE_INFO.{major, ifx in_subtype then in_subtype.* else .{}};
	out := MFT_REGISTER_TYPE_INFO.{major, ifx out_subtype then out_subtype.* else .{}};
	acts: **void;
	n: u32;
	flags := ifx hardware then MFT_ENUM_FLAG_HARDWARE | MFT_ENUM_FLAG_SORTANDFILTER else MFT_ENUM_FLAG_SYNCMFT | MFT_ENUM_FLAG_LOCALMFT | MFT_ENUM_FLAG_SORTANDFILTER;
	if MFTEnumEx(category, xx flags,
		ifx in_subtype then *inp else null, ifx out_subtype then *out else null, *acts, *n) < 0 return null;
	mft: *void;
	for 0..cast(int) n - 1 {
		if !mft && com(acts[it], 33, #type (*void, *GUID, **void) -> HRESULT #c_call)(acts[it], *IID_IMFTransform, *mft) < 0 mft = null;
		release(acts[it]);
	}
	CoTaskMemFree(acts);
	return mft;
}

// IMFTransform, stream 0.
MFT_OUTPUT_STREAM_INFO :: struct { flags, size, alignment: u32; }
MFT_OUTPUT_DATA_BUFFER :: struct { stream_id: u32; sample: *void; status: u32; events: *void; }
MFT_OUTPUT_STREAM_PROVIDES_SAMPLES :: 0x100;
MFT_OUTPUT_STREAM_CAN_PROVIDE_SAMPLES :: 0x200;

mft_output_info :: (m: *void) -> MFT_OUTPUT_STREAM_INFO {
	info: MFT_OUTPUT_STREAM_INFO;
	com(m, 7, #type (*void, u32, *MFT_OUTPUT_STREAM_INFO) -> HRESULT #c_call)(m, 0, *info);
	return info;
}
mft_attributes :: (m: *void) -> *void {
	a: *void;
	if com(m, 8, #type (*void, **void) -> HRESULT #c_call)(m, *a) < 0 return null;
	return a;
}
mft_output_available_type :: (m: *void, i: int) -> *void {
	t: *void;
	if com(m, 14, #type (*void, u32, u32, **void) -> HRESULT #c_call)(m, 0, xx i, *t) < 0 return null;
	return t;
}
mft_set_input_type :: (m: *void, t: *void) -> HRESULT { return com(m, 15, #type (*void, u32, *void, u32) -> HRESULT #c_call)(m, 0, t, 0); }
mft_set_output_type :: (m: *void, t: *void) -> HRESULT { return com(m, 16, #type (*void, u32, *void, u32) -> HRESULT #c_call)(m, 0, t, 0); }
mft_output_current_type :: (m: *void) -> *void {
	t: *void;
	if com(m, 18, #type (*void, u32, **void) -> HRESULT #c_call)(m, 0, *t) < 0 return null;
	return t;
}
mft_message :: (m: *void, msg: u32, param: u64 = 0) -> HRESULT { return com(m, 23, #type (*void, u32, u64) -> HRESULT #c_call)(m, msg, param); }
mft_input :: (m: *void, sample: *void) -> HRESULT { return com(m, 24, #type (*void, u32, *void, u32) -> HRESULT #c_call)(m, 0, sample, 0); }

// An async MFT's next event without waiting (IMFMediaEventGenerator::GetEvent, MF_EVENT_FLAG_NO_WAIT): its
// MediaEventType (METransformNeedInput, METransformHaveOutput...), or 0 when none is waiting.
mft_event :: (gen: *void) -> u32 {
	ev: *void;
	if com(gen, 3, #type (*void, u32, **void) -> HRESULT #c_call)(gen, 1, *ev) < 0 || !ev return 0;
	defer release(ev);
	t: u32;
	com(ev, 33, #type (*void, *u32) -> HRESULT #c_call)(ev, *t); // IMFMediaEvent::GetType
	return t;
}
METransformNeedInput :: 601;
METransformHaveOutput :: 602;

// One output sample (the caller releases it), or the HRESULT: MF_E_TRANSFORM_NEED_MORE_INPUT when empty.
mft_output :: (m: *void, info: MFT_OUTPUT_STREAM_INFO) -> *void, HRESULT {
	b: MFT_OUTPUT_DATA_BUFFER;
	if !(info.flags & (MFT_OUTPUT_STREAM_PROVIDES_SAMPLES | MFT_OUTPUT_STREAM_CAN_PROVIDE_SAMPLES)) {
		b.sample = sample_alloc(max(info.size, 1));
		if !b.sample return null, E_OUTOFMEMORY;
	}
	status: u32;
	hr := com(m, 25, #type (*void, u32, u32, *MFT_OUTPUT_DATA_BUFFER, *u32) -> HRESULT #c_call)(m, 0, 1, *b, *status);
	release(b.events);
	if hr < 0 { release(b.sample); return null, hr; }
	return b.sample, hr;
}

// ICodecAPI::SetValue with a VT_UI4 or VT_BOOL VARIANT.
codec_set_u32 :: (api: *void, key: *GUID, v: u32) -> bool {
	var: [24]u8;
	(cast(*u16) var.data).* = 19; // VT_UI4
	(cast(*u32) *var[8]).* = v;
	return com(api, 9, #type (*void, *GUID, *u8) -> HRESULT #c_call)(api, key, var.data) >= 0;
}
codec_set_bool :: (api: *void, key: *GUID, v: bool) -> bool {
	var: [24]u8;
	(cast(*u16) var.data).* = 11; // VT_BOOL
	(cast(*s16) *var[8]).* = cast(s16) ifx v then -1 else 0;
	return com(api, 9, #type (*void, *GUID, *u8) -> HRESULT #c_call)(api, key, var.data) >= 0;
}

// Appends Annex B data (3- or 4-byte start codes) to out with a 4-byte start code before every NAL.
annexb_append :: (out: *[..]u8, data: []u8) {
	start, i := -1, 0;
	while i <= data.count {
		at_code := i + 3 <= data.count && data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 1;
		if !at_code && i < data.count { i += 1; continue; }
		if start >= 0 {
			e := i;
			while e > start && data[e - 1] == 0 e -= 1; // zero_byte and trailing_zero_8bits belong to the start code
			if e > start {
				array_add(out, 0, 0, 0, 1);
				array_add(out, ..array_view(data, start, e - start));
			}
		}
		if !at_code break;
		i += 3;
		start = i;
	}
}

S_OK :: 0;
E_OUTOFMEMORY :: cast(HRESULT) 0x8007000E;
MF_E_NOTACCEPTING :: cast(HRESULT) 0xC00D36B5;
MF_E_TRANSFORM_STREAM_CHANGE :: cast(HRESULT) 0xC00D6D61;
MF_E_TRANSFORM_NEED_MORE_INPUT :: cast(HRESULT) 0xC00D6D72;

MFT_MESSAGE_COMMAND_FLUSH :: 0;
MFT_MESSAGE_COMMAND_DRAIN :: 1;
MFT_MESSAGE_NOTIFY_BEGIN_STREAMING :: 0x1000_0000;
MFT_MESSAGE_NOTIFY_END_STREAMING :: 0x1000_0001;
MFT_MESSAGE_NOTIFY_END_OF_STREAM :: 0x1000_0002;
MFT_MESSAGE_NOTIFY_START_OF_STREAM :: 0x1000_0003;

MFT_REGISTER_TYPE_INFO :: struct { major: GUID; sub: GUID; }
MFT_ENUM_FLAG_SYNCMFT :: 0x1;
MFT_ENUM_FLAG_LOCALMFT :: 0x8;
MFT_ENUM_FLAG_SORTANDFILTER :: 0x40;
MFT_ENUM_FLAG_HARDWARE :: 0x4;

MF_SOURCE_READER_FIRST_VIDEO_STREAM :: 0xFFFF_FFFC;
MF_SOURCE_READERF_ERROR :: 0x1;
MF_SOURCE_READERF_ENDOFSTREAM :: 0x2;
MF_SOURCE_READERF_CURRENTMEDIATYPECHANGED :: 0x20;

MF_VERSION :: 0x0002_0070;
MFSTARTUP_NOSOCKET :: 1;
COINIT_MULTITHREADED :: 0;

// GUIDs from the Windows SDK (mfapi.h, mftransform.h, mfidl.h, mfreadwrite.h, codecapi.h, mfobjects.h).
MFMediaType_Video := GUID.{0x73646976, 0x0000, 0x0010, .[0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71]};
MFVideoFormat_NV12 := #run subtype_guid("NV12");
MFVideoFormat_H264 := #run subtype_guid("H264");
MFVideoFormat_HEVC := #run subtype_guid("HEVC");
MFMediaType_Audio := GUID.{0x73647561, 0x0000, 0x0010, .[0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71]};
MFAudioFormat_AAC := GUID.{0x00001610, 0x0000, 0x0010, .[0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71]};
MFAudioFormat_Float := GUID.{0x00000003, 0x0000, 0x0010, .[0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71]};
MFAudioFormat_PCM := GUID.{0x00000001, 0x0000, 0x0010, .[0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71]};
MFT_CATEGORY_AUDIO_DECODER := GUID.{0x9ea73fb4, 0xef7a, 0x4559, .[0x8d, 0x5d, 0x71, 0x9d, 0x8f, 0x04, 0x26, 0xc7]};
MF_MT_AUDIO_NUM_CHANNELS := GUID.{0x37e48bf5, 0x645e, 0x4c5b, .[0x89, 0xde, 0xad, 0xa9, 0xe2, 0x9b, 0x69, 0x6a]};
MF_MT_AUDIO_SAMPLES_PER_SECOND := GUID.{0x5faeeae7, 0x0290, 0x4c31, .[0x9e, 0x8a, 0xc5, 0x34, 0xf6, 0x8d, 0x9d, 0xba]};
MF_MT_AUDIO_BITS_PER_SAMPLE := GUID.{0xf2deb57f, 0x40fa, 0x4764, .[0xaa, 0x33, 0xed, 0x4f, 0x2d, 0x1f, 0xf6, 0x69]};
MF_MT_AAC_PAYLOAD_TYPE := GUID.{0xbfbabe79, 0x7434, 0x4d1c, .[0x94, 0xf0, 0x72, 0xa3, 0xb9, 0xe1, 0x71, 0x88]};
MF_MT_USER_DATA := GUID.{0xb6bc765f, 0x4c3b, 0x40a4, .[0xbd, 0x51, 0x25, 0x35, 0xb6, 0x6f, 0xe0, 0x9d]};
MFT_CATEGORY_VIDEO_DECODER := GUID.{0xd6c02d4b, 0x6833, 0x45b4, .[0x97, 0x1a, 0x05, 0xa4, 0xb0, 0x4b, 0xab, 0x91]};
MFT_CATEGORY_VIDEO_ENCODER := GUID.{0xf79eac7d, 0xe545, 0x4387, .[0xbd, 0xee, 0xd6, 0x47, 0xd7, 0xbd, 0xe4, 0x2a]};
MF_MT_MAJOR_TYPE := GUID.{0x48eba18e, 0xf8c9, 0x4687, .[0xbf, 0x11, 0x0a, 0x74, 0xc9, 0xf9, 0x6a, 0x8f]};
MF_MT_SUBTYPE := GUID.{0xf7e34c9a, 0x42e8, 0x4714, .[0xb7, 0x4b, 0xcb, 0x29, 0xd7, 0x2c, 0x35, 0xe5]};
MF_MT_FRAME_SIZE := GUID.{0x1652c33d, 0xd6b2, 0x4012, .[0xb8, 0x34, 0x72, 0x03, 0x08, 0x49, 0xa3, 0x7d]};
MF_MT_FRAME_RATE := GUID.{0xc459a2e8, 0x3d2c, 0x4e44, .[0xb1, 0x32, 0xfe, 0xe5, 0x15, 0x6c, 0x7b, 0xb0]};
MF_MT_INTERLACE_MODE := GUID.{0xe2724bb8, 0xe676, 0x4806, .[0xb4, 0xb2, 0xa8, 0xd6, 0xef, 0xb4, 0x4c, 0xcd]};
MF_MT_MINIMUM_DISPLAY_APERTURE := GUID.{0xd7388766, 0x18fe, 0x48c6, .[0xa1, 0x77, 0xee, 0x89, 0x48, 0x67, 0xc8, 0xc4]};
MF_MT_AVG_BITRATE := GUID.{0x20332624, 0xfb0d, 0x4d9e, .[0xbd, 0x0d, 0xcb, 0xf6, 0x78, 0x6c, 0x10, 0x2e]};
MF_MT_DEFAULT_STRIDE := GUID.{0x644b4e48, 0x1e02, 0x4516, .[0xb0, 0xeb, 0xc0, 0x1c, 0xa9, 0xd4, 0x9a, 0xc6]};
MF_MT_MPEG2_PROFILE := GUID.{0xad76a80b, 0x2d5c, 0x4e0b, .[0xb3, 0x75, 0x64, 0xe5, 0x20, 0x13, 0x70, 0x36]};
MF_MT_MPEG_SEQUENCE_HEADER := GUID.{0x3c036de7, 0x3ad0, 0x4c9e, .[0x92, 0x16, 0xee, 0x6d, 0x6a, 0xc2, 0x1c, 0xb3]};
MF_TRANSFORM_ASYNC_UNLOCK := GUID.{0xe5666d6b, 0x3422, 0x4eb6, .[0xa4, 0x21, 0xda, 0x7d, 0xb1, 0xf8, 0xe2, 0x07]};
IID_IMFMediaEventGenerator := GUID.{0x2cd0bd52, 0xbcd5, 0x4b89, .[0xb6, 0x2c, 0xea, 0xdc, 0x0c, 0x03, 0x1e, 0x7d]};
MF_LOW_LATENCY := GUID.{0x9c27891a, 0xed7a, 0x40e1, .[0x88, 0xe8, 0xb2, 0x27, 0x27, 0xa0, 0x24, 0xee]}; // = CODECAPI_AVLowLatencyMode
MFSampleExtension_CleanPoint := GUID.{0x9cdf01d8, 0xa0f0, 0x43ba, .[0xb0, 0x77, 0xea, 0xa0, 0x6c, 0xbd, 0x72, 0x8a]};
MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE := GUID.{0xc60ac5fe, 0x252a, 0x478f, .[0xa0, 0xef, 0xbc, 0x8f, 0xa5, 0xf7, 0xca, 0xd3]};
MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_GUID := GUID.{0x8ac3587a, 0x4ae7, 0x42d8, .[0x99, 0xe0, 0x0a, 0x60, 0x13, 0xee, 0xf9, 0x0f]};
MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_SYMBOLIC_LINK := GUID.{0x58f0aad8, 0x22bf, 0x4f8a, .[0xbb, 0x3d, 0xd2, 0xc4, 0x97, 0x8c, 0x6e, 0x2f]};
MF_DEVSOURCE_ATTRIBUTE_FRIENDLY_NAME := GUID.{0x60d0e559, 0x52f8, 0x4fa2, .[0xbb, 0xce, 0xac, 0xdb, 0x34, 0xa8, 0xec, 0x01]};
MF_SOURCE_READER_ENABLE_ADVANCED_VIDEO_PROCESSING := GUID.{0x0f81da2c, 0xb537, 0x4672, .[0xa8, 0xb2, 0xa6, 0x81, 0xb1, 0x73, 0x07, 0xa3]};
CODECAPI_AVEncCommonRateControlMode := GUID.{0x1c0608e9, 0x370c, 0x4710, .[0x8a, 0x58, 0xcb, 0x61, 0x81, 0xc4, 0x24, 0x23]};
CODECAPI_AVEncCommonMeanBitRate := GUID.{0xf7222374, 0x2144, 0x4815, .[0xb5, 0x50, 0xa3, 0x7f, 0x8e, 0x12, 0xee, 0x52]};
CODECAPI_AVEncMPVGOPSize := GUID.{0x95f31b26, 0x95a4, 0x41aa, .[0x93, 0x03, 0x24, 0x6a, 0x7f, 0xc6, 0xee, 0xf1]};
CODECAPI_AVEncMPVDefaultBPictureCount := GUID.{0x8d390aac, 0xdc5c, 0x4200, .[0xb5, 0x7f, 0x81, 0x4d, 0x04, 0xba, 0xba, 0xb2]};
CODECAPI_AVEncVideoForceKeyFrame := GUID.{0x398c1b98, 0x8353, 0x475a, .[0x9e, 0xf2, 0x8f, 0x26, 0x5d, 0x26, 0x03, 0x45]};
IID_IMFTransform := GUID.{0xbf94c121, 0x5b05, 0x4e6f, .[0x80, 0x00, 0xba, 0x59, 0x89, 0x61, 0x41, 0x4d]};
IID_IMFMediaSource := GUID.{0x279a808d, 0xaec7, 0x40c8, .[0x9c, 0x6b, 0xa6, 0xb4, 0x92, 0xc7, 0x8a, 0x66]};
IID_IMF2DBuffer := GUID.{0x7dc9d5f9, 0x9ed9, 0x44ec, .[0x9b, 0xbf, 0x06, 0x00, 0xbb, 0x58, 0x9f, 0xbb]};
IID_ICodecAPI := GUID.{0x901db4c7, 0x31ce, 0x41a2, .[0x85, 0xdc, 0x8f, 0xa0, 0xbf, 0x41, 0xb8, 0xda]};

mfplat :: #system_library "mfplat";
mf :: #system_library "mf";
mfreadwrite :: #system_library "mfreadwrite";
ole32 :: #system_library "ole32";
MFStartup :: (version: u32, flags: u32) -> HRESULT #foreign mfplat;
MFCreateMediaType :: (out: **void) -> HRESULT #foreign mfplat;
MFCreateSample :: (out: **void) -> HRESULT #foreign mfplat;
MFCreateMemoryBuffer :: (max_length: u32, out: **void) -> HRESULT #foreign mfplat;
MFCreateAttributes :: (out: **void, initial_size: u32) -> HRESULT #foreign mfplat;
// guidCategory is a GUID by value, which the x64 ABI passes by reference.
MFTEnumEx :: (category: *GUID, flags: u32, input: *MFT_REGISTER_TYPE_INFO, output: *MFT_REGISTER_TYPE_INFO, activates: ***void, count: *u32) -> HRESULT #foreign mfplat;
MFEnumDeviceSources :: (attrs: *void, activates: ***void, count: *u32) -> HRESULT #foreign mf;
MFCreateSourceReaderFromMediaSource :: (source: *void, attrs: *void, out: **void) -> HRESULT #foreign mfreadwrite;
CoInitializeEx :: (reserved: *void, coinit: u32) -> HRESULT #foreign ole32;
CoUninitialize :: () #foreign ole32;
CoTaskMemFree :: (p: *void) #foreign ole32;

#scope_file

started: s32; // 0 not tried, 1 ok, 2 failed
