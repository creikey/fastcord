// Linux video decoding: H.264 in software (vendor/openh264), I420 out, copied into yuv.Nv12 frames
// (frame_nv12.jai). There is no H.265 decoder, and the voice gateway says so, so calls stay on H.264.
// AAC for decode_none.jai through libfc_aac.so (below).

Video_Decoder :: struct {
	dec: *void;
	nal_len: int;     // input samples: big-endian NAL lengths of this size (AVCC)
	prefix: [..]u8;   // parameter sets, Annex B, sent before the next sample
	annexb: [..]u8;   // reused input
	out: [..]Video_Frame; // decoded, in output order (caller sorts)
	errors: int;
}

video_codec_supported :: (c: Codec) -> bool { return c == .H264; }

video_decoder_create :: (t: *Track, first_packet: []u8 = .[]) -> *Video_Decoder, bool {
	if !video_codec_supported(t.codec) return null, false;
	prefix, nal_len, ok := params_from_config(t.codec, t.extradata);
	vd := ifx ok then decoder_create() else null;
	if !vd { array_free(prefix); return null, false; }
	vd.prefix, vd.nal_len = prefix, nal_len;
	return vd, true;
}

// A decoder for a live stream from its parameter sets (SPS, PPS) as they arrive in-band; samples are then
// AVCC with 4-byte lengths.
video_decoder_create_from_params :: (codec: Codec, params: [][]u8) -> *Video_Decoder, bool {
	if !video_codec_supported(codec) || !params.count return null, false;
	vd := decoder_create();
	if !vd return null, false;
	for params { array_add(*vd.prefix, 0, 0, 0, 1); array_add(*vd.prefix, ..it); }
	vd.nal_len = 4;
	return vd, true;
}

// Decode one access unit (synchronously). Output frames land in vd.out.
video_decode :: (vd: *Video_Decoder, data: []u8, pts: float64, dts: float64, dur: float64) -> bool {
	if !data.count return true;
	vd.annexb.count = 0;
	array_add(*vd.annexb, ..vd.prefix);
	vd.prefix.count = 0;
	i := 0;
	while i + vd.nal_len <= data.count {
		n := 0;
		for 0..vd.nal_len - 1 n = (n << 8) | data[i + it];
		i += vd.nal_len;
		if n <= 0 || i + n > data.count break;
		array_add(*vd.annexb, 0, 0, 0, 1);
		array_add(*vd.annexb, ..array_view(data, i, n));
		i += n;
	}
	y, u, v: *u8;
	ys, uvs, w, h: s32;
	ts: s64;
	r := fc_h264_dec_decode(vd.dec, vd.annexb.data, xx vd.annexb.count, cast(s64) (pts * 1_000_000), *y, *u, *v, *ys, *uvs, *w, *h, *ts);
	if r < 0 { vd.errors += 1; return false; }
	if r == 1 && w >= 2 && h >= 2 {
		f := frame_from_i420(y, u, v, ys, uvs, w, h);
		f.pts, f.dur = cast(float64) ts / 1_000_000, dur;
		array_add(*vd.out, f);
	}
	return true;
}

video_decoder_flush :: (vd: *Video_Decoder) {} // decoding has no delay: every picture came out with its access unit

// Take decoded frames (caller owns them; release with video_frame_release).
video_decoder_take :: (vd: *Video_Decoder, out: *[..]Video_Frame) {
	array_add(out, ..vd.out);
	vd.out.count = 0;
}

video_decoder_destroy :: (vd: *Video_Decoder) {
	if !vd return;
	fc_h264_dec_destroy(vd.dec);
	for * vd.out video_frame_release(it);
	array_free(vd.out);
	array_free(vd.prefix);
	array_free(vd.annexb);
	free(vd);
}

// AAC (video soundtracks, .m4a) through FFmpeg's native decoder in libfc_aac.so (vendor/ffmpeg, LGPL), a
// separate library a user can swap, opened beside the binary. Without it AAC is unsupported, as before.
Aac_Decoder :: struct {
	dec: *void;
	channels, rate: int; // the last packet's output: HE-AAC doubles the config's rate, PS makes mono stereo
}

aac_decoder_create :: (t: *Track) -> *Aac_Decoder {
	if t.aac_asc.count < 2 || t.aac_asc.count > 64 || !aac_load() return null;
	d := aac.fc_aac_open(t.aac_asc.data, xx t.aac_asc.count);
	if !d return null;
	ad := New(Aac_Decoder);
	ad.* = .{dec = d, channels = clamp(t.channels, 1, 8), rate = clamp(t.sample_rate, 1000, 384000)};
	return ad;
}

// One AAC frame -> interleaved f32 appended to out (ad.channels per frame).
aac_decode :: (ad: *Aac_Decoder, data: []u8, out: *[..]float32) {
	CAP :: 8192 * 8; // twice the longest frame (USAC with 4:1 SBR: 4096) in up to 8 channels
	at := out.count;
	array_resize(out, at + CAP, false);
	ch, rate: s32;
	n := aac.fc_aac_decode(ad.dec, data.data, xx min(data.count, S32_MAX), out.data + at, CAP, *ch, *rate);
	out.count = at;
	if n <= 0 return;
	out.count += n * ch;
	ad.channels, ad.rate = ch, rate;
}

aac_decoder_destroy :: (ad: *Aac_Decoder) {
	if !ad return;
	aac.fc_aac_close(ad.dec);
	free(ad);
}

// Opens libfc_aac.so once: from the binary's directory, else wherever the loader finds it.
aac_load :: () -> bool {
	locks.guard(*aac_mu);
	if aac_tried return aac != null;
	aac_tried = true;
	exe_dir := path_strip_filename(system.get_path_of_running_executable());
	lib := dlopen(temp_c_string(tprint("%libfc_aac.so", exe_dir)), RTLD_NOW);
	if !lib lib = dlopen("libfc_aac.so", RTLD_NOW);
	if !lib return false;
	fns := New(Aac_Lib);
	for type_info(Aac_Lib).members {
		f := dlsym(lib, temp_c_string(it.name));
		if !f { free(fns); return false; }
		(cast(**void) (cast(*u8) fns + it.offset_in_bytes)).* = f;
	}
	aac = fns;
	return true;
}

#scope_file

system :: #import "System";

Aac_Lib :: struct {
	fc_aac_open: (config: *u8, count: s32) -> *void #c_call;
	fc_aac_decode: (d: *void, data: *u8, count: s32, out: *float32, cap: s32, channels: *s32, rate: *s32) -> s32 #c_call;
	fc_aac_close: (d: *void) #c_call;
}
aac: *Aac_Lib; // set once by aac_load
aac_mu: locks.Mutex;
aac_tried: bool;

libc :: #system_library "libc"; // dlopen/dlsym are in libdl before glibc 2.34; the link adds -ldl
dlopen :: (file: *u8, mode: s32) -> *void #foreign libc;
dlsym :: (handle: *void, name: *u8) -> *void #foreign libc;
RTLD_NOW :: 2;

decoder_create :: () -> *Video_Decoder {
	d := fc_h264_dec_create();
	if !d return null;
	vd := New(Video_Decoder);
	vd.dec = d;
	return vd;
}

openh264 :: #library,no_dll "../../build/fc_vendor";
fc_h264_dec_create :: () -> *void #foreign openh264;
fc_h264_dec_decode :: (d: *void, annexb: *u8, n: s32, ts: s64, y: **u8, u: **u8, v: **u8, y_stride: *s32, uv_stride: *s32, w: *s32, h: *s32, out_ts: *s64) -> s32 #foreign openh264;
fc_h264_dec_destroy :: (d: *void) #foreign openh264;
