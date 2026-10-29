// decode_sound: a short sound file (UI sounds, soundboard) as stereo 48 kHz, on every OS through the
// vendored decoders: minimp3 for MP3, libopus for Ogg Opus. Other codecs (Ogg Vorbis) fall back to the
// platform's audio decoder where it has one. Stops at max_seconds; empty when nothing decodes.
decode_sound :: (data: []u8, max_seconds := 30) -> []float32 {
	src := source_from_memory(data);
	d, st := demux_open(*src);
	if d == null || st == .Error return .[];
	defer demux_destroy(d);
	while demux_scan(d) == .Progress {}
	track := -1;
	for d.tracks if it.kind == .Audio { track = it_index; break; }
	if track < 0 return .[];
	t := *d.tracks[track];
	cap := max_seconds * audio.SAMPLE_RATE * 2;
	out: [..]float32;
	pkt: [..]u8;
	pkt.allocator = temp;
	if t.codec == .MP3 {
		state := NewArray(fc_mp3_state_size(), u8,, temp);
		fc_mp3_init(state.data);
		raw: [..]float32;
		raw.allocator = temp;
		hz: s32 = 48000;
		frame: [1152 * 2]float32;
		for t.packets {
			if raw.count >= cap * 2 || demux_read(d, it, *pkt) != .Ok break;
			at := 0;
			while at < pkt.count {
				nch, rate, used: s32;
				n := fc_mp3_decode(state.data, pkt.data + at, cast(s32) (pkt.count - at), frame.data, *nch, *rate, *used);
				if used <= 0 break;
				at += used;
				if n <= 0 || nch < 1 || nch > 2 || rate < 8000 || rate > 48000 continue;
				hz = rate;
				for f: 0..n - 1 array_add(*raw, frame[f * nch], frame[f * nch + nch - 1]);
			}
		}
		// linear resample to 48 kHz
		step := cast(float64) hz / audio.SAMPLE_RATE;
		frames := raw.count / 2;
		pos: float64;
		while pos < cast(float64) (frames - 1) && out.count < cap {
			i := cast(int) pos;
			fr := cast(float32) (pos - i);
			array_add(*out, raw[i * 2] * (1 - fr) + raw[i * 2 + 2] * fr, raw[i * 2 + 1] * (1 - fr) + raw[i * 2 + 3] * fr);
			pos += step;
		}
		return out;
	}
	if t.codec == .Opus {
		dec, err := opus.decoder_create(48000, 2);
		if err != .None return .[];
		defer opus.decoder_destroy(dec);
		skip := t.pre_skip;
		frame: [5760 * 2]float32; // 120 ms, the longest Opus packet
		for t.packets {
			if out.count >= cap || demux_read(d, it, *pkt) != .Ok break;
			n, derr := opus.decode(dec, pkt, frame);
			if derr != .None continue;
			from := min(skip, n);
			skip -= from;
			array_add(*out, ..array_view(frame, from * 2, (n - from) * 2));
		}
		return out;
	}
	dec, ok := audio_decoder_create(t);
	if !ok return .[];
	defer audio_decoder_destroy(dec);
	for t.packets {
		if out.count >= cap || demux_read(d, it, *pkt) != .Ok break;
		audio_decode(dec, pkt, *out);
	}
	return out;
}

#scope_file

vendor :: #library,no_dll "../../build/fc_vendor";
fc_mp3_state_size :: () -> s32 #foreign vendor;
fc_mp3_init :: (state: *void) #foreign vendor;
fc_mp3_decode :: (state: *void, data: *u8, count: s32, pcm: *float32, channels: *s32, hz: *s32, used: *s32) -> s32 #foreign vendor;
