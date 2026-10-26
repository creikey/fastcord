package media

// Probing: duration / tracks without playing, and audio waveforms (voice
// messages are Ogg Opus; the UI draws a bar per bucket).

import "core:math"

Media_Info :: struct {
	format:      Format,
	duration:    f64,
	has_video:   bool,
	has_audio:   bool,
	width:       int,
	height:      int,
	video_codec: Codec,
	audio_codec: Codec,
	sample_rate: int,
	channels:    int,
}

// Scans the whole (available) source. Does not take ownership of src.
probe :: proc(src: ^Byte_Source) -> (info: Media_Info, ok: bool) {
	d, _ := demux_open(src)
	if d == nil do return
	defer demux_destroy(d)
	if demux_scan_all(d) == .Error && !d.ready do return
	info.format = d.format
	info.duration = demux_duration(d)
	if v := demux_track(d, .Video); v >= 0 {
		t := d.tracks[v]
		info.has_video = true
		info.width, info.height, info.video_codec = t.width, t.height, t.codec
	}
	if a := demux_track(d, .Audio); a >= 0 {
		t := d.tracks[a]
		info.has_audio = true
		info.audio_codec, info.sample_rate, info.channels = t.codec, t.sample_rate, t.channels
	}
	return info, true
}

// Decodes the first audio track and returns `buckets` peak levels (0..255,
// like Discord's voice-message waveform) plus the duration in seconds.
audio_waveform :: proc(src: ^Byte_Source, buckets := 256, allocator := context.allocator) -> (wave: []u8, duration: f64, ok: bool) {
	d, _ := demux_open(src)
	if d == nil do return
	defer demux_destroy(d)
	demux_scan_all(d)
	a := demux_track(d, .Audio)
	if a < 0 do return
	t := &d.tracks[a]
	ad, aok := audio_decoder_create(t)
	if !aok do return
	defer audio_decoder_destroy(ad)
	pcm := make([dynamic]f32, context.temp_allocator)
	buf := make([dynamic]u8, context.temp_allocator)
	skip := 0
	for p, i in t.packets {
		if demux_read(d, p, &buf) != .Ok do break
		before := len(pcm)
		audio_decode(ad, buf[:], &pcm)
		if i == 0 && p.pts < 0 {
			skip = min(int(f64(-p.pts) / f64(t.timescale) * 48000) * 2, len(pcm) - before)
		}
	}
	samples := pcm[skip:]
	frames := len(samples) / 2
	duration = f64(frames) / 48000
	if frames == 0 || buckets <= 0 do return nil, duration, true
	wave = make([]u8, buckets, allocator)
	peaks := make([]f32, buckets, context.temp_allocator)
	maxp: f32 = 0
	for b in 0 ..< buckets {
		s0 := b * frames / buckets
		s1 := max((b + 1) * frames / buckets, s0 + 1)
		// RMS per bucket reads closer to perceived loudness than peak
		acc: f32
		for f in s0 ..< min(s1, frames) {
			v := (samples[f * 2] + samples[f * 2 + 1]) * 0.5
			acc += v * v
		}
		peaks[b] = math.sqrt(acc / f32(max(s1 - s0, 1)))
		maxp = max(maxp, peaks[b])
	}
	for b in 0 ..< buckets {
		wave[b] = maxp > 0 ? u8(min(peaks[b] / maxp * 255 + 0.5, 255)) : 0
	}
	return wave, duration, true
}
