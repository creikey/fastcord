// Linux: no video decoder yet (VA-API or FFmpeg would be a large new dependency); Windows has
// decode_windows.jai. Audio on both: PCM (WAV) here, MP3 through vendor/minimp3 (the UI sounds are MP3); other
// codecs report unsupported, as an unknown codec does on macOS, so players open, probe and demux but play no audio.

#if OS != .WINDOWS {
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
}

Audio_Decoder :: struct {
	channels: int;
	rate: int;
	bits: int;
	is_float: bool;
	big: bool;
	pos: float64; // resampler phase
	tmp: [..]float32;
	mp3: []u8; // minimp3 state, MP3 only
}

audio_codec_supported :: (c: Codec) -> bool { return c == .PCM || c == .MP3; }

audio_decoder_create :: (t: *Track) -> *Audio_Decoder, bool {
	if !audio_codec_supported(t.codec) return null, false;
	ad := New(Audio_Decoder);
	ad.* = .{channels = max(t.channels, 1), rate = max(t.sample_rate, 1), bits = max(t.bits, 8), is_float = t.pcm_float, big = t.pcm_big};
	if t.codec == .MP3 {
		ad.mp3 = NewArray(fc_mp3_state_size(), u8);
		fc_mp3_init(ad.mp3.data);
	}
	return ad, true;
}

// PCM or MP3 -> f32, linear-interpolation resample to 48 kHz, -> stereo.
audio_decode :: (ad: *Audio_Decoder, data: []u8, out: *[..]float32) -> bool {
	ch := min(ad.channels, 2);
	ad.tmp.count = 0;
	if ad.mp3 {
		pcm: [MP3_MAX_SAMPLES]float32;
		at := 0;
		while at < data.count {
			nch, hz, used: s32;
			n := fc_mp3_decode(ad.mp3.data, data.data + at, cast(s32) (data.count - at), pcm.data, *nch, *hz, *used);
			if used <= 0 break;
			at += used;
			if n <= 0 continue;
			ad.channels, ad.rate = nch, hz;
			ch = min(nch, 2);
			for f: 0..n - 1 for c: 0..ch - 1 array_add(*ad.tmp, pcm[f * nch + c]);
		}
	} else {
		bps := ad.bits / 8;
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
	array_free(ad.mp3);
	free(ad);
}

#scope_file

MP3_MAX_SAMPLES :: 1152 * 2; // MINIMP3_MAX_SAMPLES_PER_FRAME

vendor :: #library,no_dll "../../build/fc_vendor";
fc_mp3_state_size :: () -> s32 #foreign vendor;
fc_mp3_init :: (state: *void) #foreign vendor;
fc_mp3_decode :: (state: *void, data: *u8, count: s32, pcm: *float32, channels: *s32, hz: *s32, used: *s32) -> s32 #foreign vendor;
