// Probing: duration / tracks without playing, and audio waveforms (voice
// messages are Ogg Opus; the UI draws a bar per bucket).



Media_Info :: struct {
	format: Format;
	duration: float64;
	has_video: bool;
	has_audio: bool;
	width: int;
	height: int;
	video_codec: Codec;
	audio_codec: Codec;
	sample_rate: int;
	channels: int;
}

// Scans the whole (available) source. Does not take ownership of src.
probe :: (src: *Byte_Source) -> Media_Info, bool {
	info: Media_Info;
	ok: bool;
	d, _ := demux_open(src);
	if d == null { return info, ok; }
	defer demux_destroy(d);
	if demux_scan_all(d) == .Error && !d.ready { return info, ok; }
	info.format = d.format;
	info.duration = demux_duration(d);
	{ v := demux_track(d, .Video);
	if v >= 0 {
		t := d.tracks[v];
		info.has_video = true;
		info.width, info.height, info.video_codec = t.width, t.height, t.codec;
	} }
	{ a := demux_track(d, .Audio);
	if a >= 0 {
		t := d.tracks[a];
		info.has_audio = true;
		info.audio_codec, info.sample_rate, info.channels = t.codec, t.sample_rate, t.channels;
	} }
	return info, true;
}

// Decodes the first audio track and returns `buckets` peak levels (0..255,
// like Discord's voice-message waveform) plus the duration in seconds.
audio_waveform :: (src: *Byte_Source, buckets := 256, allocator := context.allocator) -> []u8, float64, bool {
	wave: []u8;
	duration: float64;
	ok: bool;
	d, _ := demux_open(src);
	if d == null { return wave, duration, ok; }
	defer demux_destroy(d);
	demux_scan_all(d);
	a := demux_track(d, .Audio);
	if a < 0 { return wave, duration, ok; }
	t := *d.tracks[a];
	ad, aok := audio_decoder_create(t);
	if !aok { return wave, duration, ok; }
	defer audio_decoder_destroy(ad);
	pcm := make_dynamic(float32, 0, 0, temp);
	buf := make_dynamic(u8, 0, 0, temp);
	skip := 0;
	for p, i: t.packets {
		if demux_read(d, p, *buf) != .Ok { break; }
		before := len(pcm);
		audio_decode(ad, view(buf), *pcm);
		if i == 0 && p.pts < 0 {
			skip = min(cast(int)(cast(float64)(-p.pts) / cast(float64)(t.timescale) * 48000) * 2, len(pcm) - before);
		}
	}
	samples := sub_from(pcm, skip);
	frames := len(samples) / 2;
	duration = cast(float64)(frames) / 48000;
	if frames == 0 || buckets <= 0 { return .{}, duration, true; }
	wave = make_slice(u8, buckets, allocator);
	peaks := make_slice(float32, buckets, temp);
	maxp: float32 = 0;
	for b: 0..buckets-1 {
		s0 := b * frames / buckets;
		s1 := max((b + 1) * frames / buckets, s0 + 1);
		// RMS per bucket reads closer to perceived loudness than peak
		acc: float32;
		for f: s0..(min(s1, frames))-1 {
			v := (samples[f * 2] + samples[f * 2 + 1]) * 0.5;
			acc += v * v;
		}
		peaks[b] = math.sqrt(acc / cast(float32)(max(s1 - s0, 1)));
		maxp = max(maxp, peaks[b]);
	}
	for b: 0..buckets-1 {
		wave[b] = ifx maxp > 0 then cast(u8)(min(peaks[b] / maxp * 255 + 0.5, 255)) else 0;
	}
	return wave, duration, true;
}

