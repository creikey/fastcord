// Windows decoders: TODO Media Foundation (H.264/HEVC/VP9/AV1 MFTs -> NV12
// ID3D11Texture2D, AAC/MP3/Opus/FLAC audio MFTs). Until then this backend
// reports every codec unsupported, so players on Windows open, probe and
// demux but render no frames and play no audio. PCM (WAV) is decoded here.




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

video_codec_supported :: (c: Codec) -> bool {return false;}
video_decoder_create :: (t: *Track, first_packet: []u8 = .{}) -> *Video_Decoder, bool {return null, false;}
video_decode :: (vd: *Video_Decoder, data: []u8, pts: float64, dts: float64, dur: float64) -> bool {return false;}
video_decoder_flush :: (vd: *Video_Decoder) {}
video_decoder_take :: (vd: *Video_Decoder, out: *[..]Video_Frame) {}
video_decoder_destroy :: (vd: *Video_Decoder) {}
video_frame_release :: (f: *Video_Frame) {f.pixbuf = null;}
video_frame_textures :: (f: *Video_Frame) -> gfx.Texture, gfx.Texture, bool {
	y: gfx.Texture;
	cbcr: gfx.Texture;
	ok: bool;return y, cbcr, ok;}

Audio_Decoder :: struct {
	channels: int;
	rate: int;
	bits: int;
	is_float: bool;
	big: bool;
	pos: float64; // resampler phase
	tmp: [..]float32;
}

audio_codec_supported :: (c: Codec) -> bool {return c == .PCM;}

audio_decoder_create :: (t: *Track) -> *Audio_Decoder, bool {
	if t.codec != .PCM { return null, false; }
	ad := new(Audio_Decoder);
	ad.* = .{channels = max(t.channels, 1), rate = max(t.sample_rate, 1), bits = max(t.bits, 8), is_float = t.pcm_float, big = t.pcm_big};
	return ad, true;
}

// PCM -> f32, linear-interpolation resample to 48 kHz, -> stereo.
audio_decode :: (ad: *Audio_Decoder, data: []u8, out: *[..]float32) -> bool {
	bps := ad.bits / 8;
	frames := len(data) / (bps * ad.channels);
	clear(*ad.tmp);
	for f: 0..cast(int)(frames)-1 {
		for c: 0..cast(int)((min(ad.channels, 2)))-1 {
			b := sub_from(data, (f * ad.channels + c) * bps);
			v: float32;
			if ad.is_float && bps == 4 { v = transmute(float32, le32(b));
			} else if bps == 1 { v = (cast(float32)(b[0]) - 128) / 128;
			} else if bps == 2 { v = cast(float32)(cast(s16)(ifx ad.big then be16(b) else le16(b))) / 32768;
			} else if bps == 3 { v = cast(float32)((cast(s32)(((cast(u32)(b[0])) << 8) | ((cast(u32)(b[1])) << 16) | ((cast(u32)(b[2])) << 24))) >> 8) / 8388608;
			} else if bps == 4 { v = cast(float32)(cast(s32)(le32(b))) / 2147483648;
			}
			append(*ad.tmp, v);
		}
	}
	ch := min(ad.channels, 2);
	step := cast(float64)(ad.rate) / audio.SAMPLE_RATE;
	n := len(ad.tmp) / ch;
	while ad.pos < cast(float64)(n - 1) {
		i := cast(int)(ad.pos);
		fr := cast(float32)(ad.pos - cast(float64)(i));
		l := ad.tmp[i * ch] * (1 - fr) + ad.tmp[(i + 1) * ch] * fr;
		r := ifx ch == 2 then ad.tmp[i * ch + 1] * (1 - fr) + ad.tmp[(i + 1) * ch + 1] * fr else l;
		append(out, l, r);
		ad.pos += step;
	}
	ad.pos -= cast(float64)(max(n - 1, 0));
	return true;
}

audio_decoder_reset :: (ad: *Audio_Decoder) {ad.pos = 0;}
audio_decoder_destroy :: (ad: *Audio_Decoder) {
	if ad == null { return; }
	delete(ad.tmp);
	free(ad);
}

