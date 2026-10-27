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
	d := demux_open(src);
	if !d return info, false;
	defer demux_destroy(d);
	if demux_scan_all(d) == .Error && !d.ready return info, false;
	info.format = d.format;
	info.duration = demux_duration(d);
	v := demux_track(d, .Video);
	if v >= 0 {
		t := d.tracks[v];
		info.has_video = true;
		info.width, info.height, info.video_codec = t.width, t.height, t.codec;
	}
	a := demux_track(d, .Audio);
	if a >= 0 {
		t := d.tracks[a];
		info.has_audio = true;
		info.audio_codec, info.sample_rate, info.channels = t.codec, t.sample_rate, t.channels;
	}
	return info, true;
}

// Decodes the first audio track and returns `buckets` peak levels (0..255,
// like Discord's voice-message waveform) plus the duration in seconds.
audio_waveform :: (src: *Byte_Source, buckets := 256, allocator := context.allocator) -> []u8, float64, bool {
	d := demux_open(src);
	if !d return .[], 0, false;
	defer demux_destroy(d);
	demux_scan_all(d);
	a := demux_track(d, .Audio);
	if a < 0 return .[], 0, false;
	t := *d.tracks[a];
	ad, aok := audio_decoder_create(t);
	if !aok return .[], 0, false;
	defer audio_decoder_destroy(ad);
	pcm: [..]float32;
	buf: [..]u8;
	pcm.allocator = temp;
	buf.allocator = temp;
	skip := 0;
	for p: t.packets {
		if demux_read(d, p, *buf) != .Ok break;
		before := pcm.count;
		audio_decode(ad, buf, *pcm);
		if it_index == 0 && p.pts < 0 {
			skip = min(cast(int) (cast(float64) -p.pts / cast(float64) t.timescale * 48000) * 2, pcm.count - before);
		}
	}
	samples := array_view(pcm, skip);
	frames := samples.count / 2;
	duration := cast(float64) frames / 48000;
	if frames == 0 || buckets <= 0 return .[], duration, true;
	wave := NewArray(buckets, u8,, allocator);
	peaks := NewArray(buckets, float32,, temp);
	maxp: float32 = 0;
	for b: 0..buckets - 1 {
		s0 := b * frames / buckets;
		s1 := max((b + 1) * frames / buckets, s0 + 1);
		// RMS per bucket reads closer to perceived loudness than peak
		acc: float32;
		for f: s0..min(s1, frames) - 1 {
			v := (samples[f * 2] + samples[f * 2 + 1]) * 0.5;
			acc += v * v;
		}
		peaks[b] = sqrt(acc / cast(float32) max(s1 - s0, 1));
		maxp = max(maxp, peaks[b]);
	}
	for b: 0..buckets - 1 wave[b] = ifx maxp > 0 then cast(u8) min(peaks[b] / maxp * 255 + 0.5, 255) else 0;
	return wave, duration, true;
}
