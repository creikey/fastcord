// Windows and Linux: no video or compressed-audio decoder yet (Windows: TODO Media Foundation MFTs; Linux:
// VA-API or FFmpeg would be a large new dependency). Every codec but PCM reports unsupported, as an unknown
// codec does on macOS, so players open, probe and demux but render no frames and play no audio. PCM (WAV)
// is decoded here.

Video_Frame :: struct {
	pts: float64;
	dur: float64;
	pixbuf: *void;
	width: int;
	height: int;
	yuv: gfx.Yuv_Matrix;
}

Video_Decoder :: struct {
	errors: int;
}

video_codec_supported :: (c: Codec) -> bool { return false; }
video_decoder_create :: (t: *Track, first_packet: []u8 = .[]) -> *Video_Decoder, bool { return null, false; }
video_decoder_create_from_params :: (codec: Codec, params: [][]u8) -> *Video_Decoder, bool { return null, false; }
video_decode :: (vd: *Video_Decoder, data: []u8, pts: float64, dts: float64, dur: float64) -> bool { return false; }
video_decoder_flush :: (vd: *Video_Decoder) {}
video_decoder_take :: (vd: *Video_Decoder, out: *[..]Video_Frame) {}
video_decoder_destroy :: (vd: *Video_Decoder) {}
video_frame_release :: (f: *Video_Frame) { f.pixbuf = null; }
video_frame_from_pixbuf :: (pixbuf: *void) -> Video_Frame { return .{}; }
video_frame_textures :: (f: *Video_Frame) -> gfx.Texture, gfx.Texture, bool { return 0, 0, false; }

Audio_Decoder :: struct {
	channels: int;
	rate: int;
	bits: int;
	is_float: bool;
	big: bool;
	pos: float64; // resampler phase
	tmp: [..]float32;
}

audio_codec_supported :: (c: Codec) -> bool { return c == .PCM; }

audio_decoder_create :: (t: *Track) -> *Audio_Decoder, bool {
	if t.codec != .PCM return null, false;
	ad := New(Audio_Decoder);
	ad.* = .{channels = max(t.channels, 1), rate = max(t.sample_rate, 1), bits = max(t.bits, 8), is_float = t.pcm_float, big = t.pcm_big};
	return ad, true;
}

// PCM -> f32, linear-interpolation resample to 48 kHz, -> stereo.
audio_decode :: (ad: *Audio_Decoder, data: []u8, out: *[..]float32) -> bool {
	bps := ad.bits / 8;
	ch := min(ad.channels, 2);
	ad.tmp.count = 0;
	for f: 0..data.count / (bps * ad.channels) - 1 {
		for c: 0..ch - 1 {
			i := (f * ad.channels + c) * bps;
			v: float32;
			if ad.is_float && bps == 4 { u := le32(data, i); v = (cast(*float32) *u).*; }
			else if bps == 1 v = (cast(float32) data[i] - 128) / 128;
			else if bps == 2 v = cast(float32) cast(s16) (ifx ad.big then be16(data, i) else le16(data, i)) / 32768;
			else if bps == 3 v = cast(float32) ((cast(s32) (((cast(u32) data[i]) << 8) | ((cast(u32) data[i + 1]) << 16) | ((cast(u32) data[i + 2]) << 24))) >> 8) / 8388608;
			else if bps == 4 v = cast(float32) cast(s32) le32(data, i) / 2147483648;
			array_add(*ad.tmp, v);
		}
	}
	step := cast(float64) ad.rate / audio.SAMPLE_RATE;
	n := ad.tmp.count / ch;
	while ad.pos < cast(float64) (n - 1) {
		i := cast(int) ad.pos;
		fr := cast(float32) (ad.pos - i);
		l := ad.tmp[i * ch] * (1 - fr) + ad.tmp[(i + 1) * ch] * fr;
		r := ifx ch == 2 then ad.tmp[i * ch + 1] * (1 - fr) + ad.tmp[(i + 1) * ch + 1] * fr else l;
		array_add(out, l, r);
		ad.pos += step;
	}
	ad.pos -= max(n - 1, 0);
	return true;
}

audio_decoder_reset :: (ad: *Audio_Decoder) { ad.pos = 0; }

audio_decoder_destroy :: (ad: *Audio_Decoder) {
	if !ad return;
	array_free(ad.tmp);
	free(ad);
}
