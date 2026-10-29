// Audio on Windows and Linux (their video: decode_windows.jai, decode_linux.jai): PCM (WAV) here, MP3 through
// vendor/minimp3 (the UI sounds are MP3), Opus (voice messages, WebM) through libopus, AAC through Media
// Foundation on Windows and FFmpeg's decoder in libfc_aac.so on Linux (decode_windows.jai, decode_linux.jai);
// other codecs report unsupported, as an unknown codec does on macOS, so players open, probe and demux but play
// no audio.

Audio_Decoder :: struct {
	channels: int;
	rate: int;
	bits: int;
	is_float: bool;
	big: bool;
	pos: float64; // resampler phase
	tmp: [..]float32;
	mp3: []u8; // minimp3 state, MP3 only
	opus_dec: *opus.Decoder; // stereo at 48 kHz; the player trims the pre-skip
	aac: *Aac_Decoder;
}

audio_codec_supported :: (c: Codec) -> bool {
	#if OS == .LINUX if c == .AAC return aac_load(); // libfc_aac.so may be missing
	return c == .PCM || c == .MP3 || c == .Opus || c == .AAC;
}

audio_decoder_create :: (t: *Track) -> *Audio_Decoder, bool {
	if !audio_codec_supported(t.codec) return null, false;
	// A file's rate far outside audio's would resample each frame into thousands (or none).
	if t.codec == .PCM && (t.sample_rate < 1000 || t.sample_rate > 768000) return null, false;
	ad := New(Audio_Decoder);
	ad.* = .{channels = max(t.channels, 1), rate = max(t.sample_rate, 1), bits = max(t.bits, 8), is_float = t.pcm_float, big = t.pcm_big};
	if t.codec == .MP3 {
		ad.mp3 = NewArray(fc_mp3_state_size(), u8);
		fc_mp3_init(ad.mp3.data);
	} else if t.codec == .Opus {
		err: opus.Error;
		ad.opus_dec, err = opus.decoder_create(audio.SAMPLE_RATE, 2);
		if err != .None { free(ad); return null, false; }
		ad.channels, ad.rate = 2, audio.SAMPLE_RATE;
	} else if t.codec == .AAC {
		ad.aac = aac_decoder_create(t);
		if !ad.aac { free(ad); return null, false; }
		ad.channels, ad.rate = ad.aac.channels, ad.aac.rate;
	}
	return ad, true;
}

// PCM, MP3, Opus or AAC -> f32, linear-interpolation resample to 48 kHz, -> stereo.
audio_decode :: (ad: *Audio_Decoder, data: []u8, out: *[..]float32) -> bool {
	ch := min(ad.channels, 2);
	ad.tmp.count = 0;
	if ad.opus_dec {
		array_resize(*ad.tmp, 5760 * 2, false); // 120 ms, the longest Opus packet
		n, err := opus.decode(ad.opus_dec, data, ad.tmp);
		ad.tmp.count = ifx err == .None then n * 2 else 0;
	} else if ad.aac {
		aac_decode(ad.aac, data, *ad.tmp);
		ad.channels, ad.rate = ad.aac.channels, ad.aac.rate;
		ch = min(ad.channels, 2);
		// Surround (WAVE order: FL FR FC LFE BL BR) down to stereo in place, centre and back at -3 dB.
		n := ad.tmp.count / ad.channels;
		if ad.channels > 2 for f: 0..n - 1 {
			p := ad.tmp.data + f * ad.channels;
			back := ad.channels >= 6;
			k := 1 / (1 + 0.707 * (ifx back then 2 else 1));
			ad.tmp[f * 2] = (p[0] + 0.707 * p[2] + ifx back then 0.707 * p[4] else 0) * k;
			ad.tmp[f * 2 + 1] = (p[1] + 0.707 * p[2] + ifx back then 0.707 * p[5] else 0) * k;
		}
		ad.tmp.count = n * ch;
	} else if ad.mp3 {
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
	if ad.rate == audio.SAMPLE_RATE { // as is: the resampler below drops each chunk's last frame
		for f: 0..n - 1 array_add(out, ad.tmp[f * ch], ad.tmp[f * ch + ch - 1]);
		return true;
	}
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
	if ad.opus_dec opus.decoder_destroy(ad.opus_dec);
	aac_decoder_destroy(ad.aac);
	free(ad);
}

#scope_file

MP3_MAX_SAMPLES :: 1152 * 2; // MINIMP3_MAX_SAMPLES_PER_FRAME

vendor :: #library,no_dll "../../build/fc_vendor";
fc_mp3_state_size :: () -> s32 #foreign vendor;
fc_mp3_init :: (state: *void) #foreign vendor;
fc_mp3_decode :: (state: *void, data: *u8, count: s32, pcm: *float32, channels: *s32, hz: *s32, used: *s32) -> s32 #foreign vendor;
