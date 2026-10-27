// Audio/video player for attachments and embeds.
//
//	p := media.player_open(src)            // takes ownership of src
//	media.player_play(p)
//	every frame:
//		img, changed := media.player_update(p)
//		if img.y gfx.video(dst, img.y, img.cbcr, img.yuv)
//		if media.player_is_playing(p) platform.request_frame()
//
// A worker thread per player demuxes and decodes only what's needed: up to
// MAX_FRAMES decoded video frames ahead and AUDIO_AHEAD seconds of audio. When
// paused (or ended) the worker sleeps: no CPU, no GPU.
//
// Clock: audio-driven when there is (unmuted) audio — the device's consumed
// sample position minus output latency — otherwise the wall clock. Video frames
// are presented when their pts <= clock (frame-accurate, B-frame reordered).

MAX_FRAMES :: 5;
AUDIO_AHEAD :: 0.3; // seconds queued in the mixer ring

Player_State :: enum u8 {
	Opening; // waiting for headers
	Ready; // paused / playing normally
	Ended;
	Error;
}

Video_Image :: struct {
	y, cbcr: gfx.Texture; // 0 if no frame yet
	size: [2]int;
	yuv: gfx.Yuv_Matrix;
	pts: float64;
}

Player :: struct {
	src: Byte_Source;
	demux: *Demuxer;
	vtrack, atrack: int;
	vdec: *Video_Decoder;
	adec: *Audio_Decoder;
	thread: Thread;
	mu: locks.Mutex;
	cond: locks.Cond;

	// ---- shared (mu)
	quit: bool;
	state: Player_State;
	playing: bool;
	looping: bool;
	muted: bool;
	volume: float32;
	seek_req: bool;
	seek_to: float64;
	starved: bool; // worker waiting for bytes that haven't downloaded yet (buffering)
	seek_ready: bool; // the frame covering the seek target (or a poster) has been decoded
	since_seek: int; // frames decoded since the last seek
	frames: [..]Video_Frame; // decoded, sorted by pts (global time)
	eos_video: bool;
	eos_audio: bool;
	segments: [4]Segment;
	nseg: int;
	audio_active: bool;
	loop_offset: float64;
	duration: float64;
	stats: Player_Stats;

	// ---- worker only
	vnext, anext: int;
	discard_v: float64;
	discard_a: float64;
	pcm: [..]float32;
	pkt: [..]u8;
	vframes_tmp: [..]Video_Frame;

	// ---- main thread
	asrc: audio.Source;
	anchor_wall: float64;
	anchor_media: float64;
	audio_driving: bool;
	img: Video_Image;
	shown_any: bool;
}

Player_Stats :: struct {
	video_decoded: int;
	video_dropped: int; // decoded but never shown (late or seek-discarded)
	video_shown: int;
	audio_packets: int;
}

// Takes ownership of src. Check player_state for .Error (unsupported format).
player_open :: (src: Byte_Source, autoplay := false, looping := false, muted := false) -> *Player {
	p := New(Player);
	p.src = src;
	p.vtrack = -1;
	p.atrack = -1;
	p.volume = 1;
	p.looping = looping;
	p.muted = muted;
	p.playing = autoplay;
	p.state = .Opening;
	p.anchor_wall = now_s();
	p.asrc = audio.source_create();
	audio.source_set_paused(p.asrc, !autoplay);
	thread_init(*p.thread, worker);
	p.thread.data = p;
	thread_start(*p.thread);
	return p;
}

player_destroy :: (p: *Player) {
	if !p return;
	locks.lock(*p.mu);
	p.quit = true;
	locks.unlock(*p.mu);
	locks.cond_broadcast(*p.cond);
	thread_is_done(*p.thread, -1);
	thread_deinit(*p.thread);
	for * p.frames video_frame_release(it);
	array_free(p.frames);
	array_free(p.vframes_tmp);
	array_free(p.pcm);
	array_free(p.pkt);
	video_decoder_destroy(p.vdec);
	audio_decoder_destroy(p.adec);
	if p.img.y gfx.texture_destroy(p.img.y);
	if p.img.cbcr gfx.texture_destroy(p.img.cbcr);
	audio.source_destroy(p.asrc);
	demux_destroy(p.demux);
	source_destroy(*p.src);
	free(p);
}

player_play :: (p: *Player) {
	locks.lock(*p.mu);
	if p.state == .Ended {
		p.seek_req = true;
		p.seek_to = 0;
		p.state = .Ready;
	}
	if !p.playing {
		p.playing = true;
		p.anchor_wall = now_s();
	}
	locks.unlock(*p.mu);
	audio.source_set_paused(p.asrc, false);
	locks.cond_broadcast(*p.cond);
}

player_pause :: (p: *Player) {
	t := player_clock(p, now_s());
	locks.lock(*p.mu);
	p.playing = false;
	p.anchor_media = t;
	locks.unlock(*p.mu);
	audio.source_set_paused(p.asrc, true);
	p.audio_driving = false;
}

player_toggle :: (p: *Player) {
	if player_is_playing(p) player_pause(p);
	else player_play(p);
}

// Frame-accurate seek (seconds). The frame covering `t` is shown next.
player_seek :: (p: *Player, t: float64) {
	locks.lock(*p.mu);
	p.seek_req = true;
	p.seek_to = max(t, 0);
	// Frames decoded for the old position must never be shown.
	for * p.frames video_frame_release(it);
	p.frames.count = 0;
	p.seek_ready = false;
	p.anchor_media = p.seek_to;
	p.anchor_wall = now_s();
	if p.state == .Ended p.state = .Ready;
	locks.unlock(*p.mu);
	p.audio_driving = false;
	p.shown_any = false;
	locks.cond_broadcast(*p.cond);
}

player_set_loop :: (p: *Player, on: bool) {
	locks.lock(*p.mu);
	p.looping = on;
	locks.unlock(*p.mu);
	locks.cond_broadcast(*p.cond);
}

player_set_volume :: (p: *Player, v: float32) {
	p.volume = v;
	audio.source_set_volume(p.asrc, v);
}

// Muting stops audio decoding entirely (battery); unmuting resyncs at the current position.
player_set_muted :: (p: *Player, m: bool) {
	if p.muted == m return;
	t := player_clock(p, now_s());
	p.muted = m;
	player_seek(p, t);
}

player_is_playing :: (p: *Player) -> bool {
	locks.lock(*p.mu);
	defer locks.unlock(*p.mu);
	return p.playing && p.state != .Ended;
}

player_state :: (p: *Player) -> Player_State {
	locks.lock(*p.mu);
	defer locks.unlock(*p.mu);
	return p.state;
}

player_duration :: (p: *Player) -> float64 {
	locks.lock(*p.mu);
	defer locks.unlock(*p.mu);
	return p.duration;
}

// Current position in seconds (wraps when looping).
player_position :: (p: *Player) -> float64 {
	t := player_clock(p, now_s());
	d := player_duration(p);
	if d > 0 {
		if p.looping t = fmod_cycling(t, d); // same as fmod: t >= 0
		t = min(t, d);
	}
	return max(t, 0);
}

player_has_video :: (p: *Player) -> bool { return p.vtrack >= 0; }
player_has_audio :: (p: *Player) -> bool { return p.atrack >= 0; }

player_stats :: (p: *Player) -> Player_Stats {
	locks.lock(*p.mu);
	defer locks.unlock(*p.mu);
	return p.stats;
}

// True while playback is stalled waiting for download.
player_is_buffering :: (p: *Player) -> bool {
	locks.lock(*p.mu);
	defer locks.unlock(*p.mu);
	return p.starved && p.frames.count == 0 && p.state == .Ready;
}

// Call once per app frame. Returns the image to draw and whether it changed.
// (The player keeps its own monotonic clock, independent of platform time overrides.)
player_update :: (p: *Player) -> Video_Image, bool {
	clock := player_clock(p, now_s());
	changed := false;
	locks.lock(*p.mu);
	pick := -1;
	for p.frames {
		if it.pts > clock + 0.0005 break;
		pick = it_index;
	}
	if !p.seek_ready pick = -1;
	else if pick < 0 && !p.shown_any && p.frames.count > 0 pick = 0; // poster frame
	consumed := false;
	if pick >= 0 {
		f := p.frames[pick];
		y, uv, ok := video_frame_textures(*f);
		if ok {
			if p.img.y gfx.texture_destroy(p.img.y);
			if p.img.cbcr gfx.texture_destroy(p.img.cbcr);
			p.img = .{y = y, cbcr = uv, size = .[f.width, f.height], yuv = f.yuv, pts = f.pts};
			changed = true;
			p.shown_any = true;
			p.stats.video_shown += 1;
		}
		p.stats.video_dropped += pick;
		for k: 0..pick video_frame_release(*p.frames[k]);
		remove_range(*p.frames, 0, pick + 1);
		consumed = true;
	}
	// End of stream?
	if p.state == .Ready && p.playing && !p.looping && p.eos_video && p.eos_audio && p.frames.count == 0 && !p.seek_req {
		if !p.audio_active || p.muted || audio.source_queued_frames(p.asrc) == 0 {
			p.state = .Ended;
			p.playing = false;
			p.anchor_media = min(clock, p.duration);
		}
	}
	locks.unlock(*p.mu);
	if consumed locks.cond_broadcast(*p.cond);
	audio.update();
	return p.img, changed;
}

#scope_module

now_s :: () -> float64 { return to_float64_seconds(current_time_monotonic()); }

// Global media clock (seconds, not wrapped).
player_clock :: (p: *Player, now: float64) -> float64 {
	locks.lock(*p.mu);
	playing := p.playing && p.state == .Ready;
	audio_on := p.audio_active && !p.muted;
	segs := p.segments;
	nseg := p.nseg;
	eos_audio := p.eos_audio;
	buffering := p.starved && p.frames.count == 0;
	locks.unlock(*p.mu);
	if !playing return p.anchor_media;
	if audio_on && nseg > 0 {
		rp := audio.source_read_pos(p.asrc);
		lat := audio.output_latency();
		// latest segment that has started playing
		for < i: 0..nseg - 1 {
			sg := segs[i];
			if rp < sg.mark continue;
			played := cast(float64) (rp - sg.mark) / audio.SAMPLE_RATE - lat;
			if played <= 0 break; // device hasn't reached it yet: hold
			if eos_audio && audio.source_queued_frames(p.asrc) == 0 break; // drained
			t := sg.base + played;
			p.anchor_media = t;
			p.anchor_wall = now;
			p.audio_driving = true;
			return t;
		}
		if !p.audio_driving && !eos_audio {
			// audio hasn't started yet: hold the clock so video waits for it
			p.anchor_wall = now;
			return p.anchor_media;
		}
	}
	if !p.shown_any || buffering {
		// Don't start the wall clock before the first frame is on screen
		// (startup / seek), or the first frames would be skipped.
		p.anchor_wall = now;
		return p.anchor_media;
	}
	return p.anchor_media + (now - p.anchor_wall);
}

// Drops a[lo..hi-1], keeping order.
remove_range :: (a: *[..]$T, lo: int, hi: int) {
	n := hi - lo;
	if n <= 0 return;
	for i: hi..a.count - 1 a.*[i - n] = a.*[i];
	a.count -= n;
}

#scope_file

Segment :: struct {
	mark: u64; // audio write position (frames) where this segment starts
	base: float64; // global time of that sample
}

worker :: (th: *Thread) -> s64 {
	p := cast(*Player) th.data;
	if !worker_open(p) {
		locks.lock(*p.mu);
		p.state = .Error;
		locks.unlock(*p.mu);
		return 0;
	}
	while true {
		reset_temporary_storage(); // everything put on temp dies within one iteration
		locks.lock(*p.mu);
		if p.quit {
			locks.unlock(*p.mu);
			return 0;
		}
		seek := p.seek_req;
		target := p.seek_to;
		p.seek_req = false;
		locks.unlock(*p.mu);
		if seek worker_seek(p, target);

		// Keep the index growing (streaming sources).
		scan_blocked := false;
		if !p.demux.complete {
			for 0..63 {
				s := demux_scan(p.demux);
				if s == .Need_Data {
					scan_blocked = true;
					break;
				}
				if s != .Progress break;
			}
			locks.lock(*p.mu);
			p.duration = max(p.duration, demux_duration(p.demux));
			locks.unlock(*p.mu);
		}

		did := worker_step(p);
		locks.lock(*p.mu);
		if did {
			p.starved = false;
		} else if !p.quit && !p.seek_req {
			// Audio drains continuously: poll while playing it; otherwise sleep until poked.
			if p.playing && p.audio_active && !p.eos_audio {
				locks.cond_wait_with_timeout(*p.cond, *p.mu, 40);
			} else if scan_blocked && p.src.wait {
				locks.unlock(*p.mu);
				p.src.wait(p.src.user, source_extent(*p.src), 100);
				locks.lock(*p.mu);
			} else if scan_blocked {
				locks.cond_wait_with_timeout(*p.cond, *p.mu, 50);
			} else {
				locks.cond_wait(*p.cond, *p.mu);
			}
		}
		locks.unlock(*p.mu);
	}
	return 0;
}

worker_open :: (p: *Player) -> bool {
	while true {
		locks.lock(*p.mu);
		q := p.quit;
		locks.unlock(*p.mu);
		if q return false;
		if !p.demux {
			d, s := demux_open(*p.src);
			if !d {
				if s == .Error return false;
				wait_data(p);
				continue;
			}
			p.demux = d;
		}
		if demux_scan_headers(p.demux) == .Error return false;
		if p.demux.ready break;
		wait_data(p);
	}
	d := p.demux;
	p.vtrack = demux_track(d, .Video);
	p.atrack = demux_track(d, .Audio);
	if p.vtrack >= 0 && !video_codec_supported(d.tracks[p.vtrack].codec) p.vtrack = -1;
	if p.atrack >= 0 && !audio_codec_supported(d.tracks[p.atrack].codec) p.atrack = -1;
	if p.vtrack < 0 && p.atrack < 0 return false;
	if p.atrack >= 0 {
		ad, ok := audio_decoder_create(*d.tracks[p.atrack]);
		if ok p.adec = ad;
		else p.atrack = -1;
	}
	locks.lock(*p.mu);
	p.duration = demux_duration(d);
	p.state = .Ready;
	p.eos_video = p.vtrack < 0;
	p.audio_active = p.atrack >= 0 && !p.muted;
	p.eos_audio = !p.audio_active;
	if p.audio_active add_segment(p, 0);
	locks.unlock(*p.mu);
	if p.playing audio.source_set_paused(p.asrc, false);
	return true;
}

wait_data :: (p: *Player) {
	if p.src.wait p.src.wait(p.src.user, source_extent(*p.src), 100);
	else sleep_milliseconds(20);
}

// mu held
add_segment :: (p: *Player, base: float64) {
	if p.nseg == p.segments.count {
		for i: 0..p.nseg - 2 p.segments[i] = p.segments[i + 1];
		p.nseg -= 1;
	}
	p.segments[p.nseg] = .{audio.source_write_pos(p.asrc), base};
	p.nseg += 1;
}

worker_seek :: (p: *Player, target: float64) {
	d := p.demux;
	locks.lock(*p.mu);
	for * p.frames video_frame_release(it);
	p.frames.count = 0;
	p.seek_ready = p.vtrack < 0;
	p.since_seek = 0;
	p.loop_offset = 0;
	p.eos_video = p.vtrack < 0;
	p.audio_active = p.atrack >= 0 && !p.muted;
	p.eos_audio = !p.audio_active;
	p.nseg = 0;
	locks.unlock(*p.mu);

	if p.vtrack >= 0 {
		t := *d.tracks[p.vtrack];
		p.vnext = demux_find_keyframe(t, track_ticks(t, target));
		if p.vdec {
			video_decoder_flush(p.vdec);
			tmp: [..]Video_Frame;
			tmp.allocator = temp;
			video_decoder_take(p.vdec, *tmp);
			for * tmp video_frame_release(it);
		}
		p.discard_v = target;
	}
	if p.audio_active {
		t := *d.tracks[p.atrack];
		// start a little before (decoder pre-roll), trim precisely by pts
		p.anext = demux_find_keyframe(t, track_ticks(t, max(target - 0.1, 0)));
		audio_decoder_reset(p.adec);
		p.pcm.count = 0;
		p.discard_a = target;
		audio.source_flush(p.asrc);
		locks.lock(*p.mu);
		add_segment(p, target);
		locks.unlock(*p.mu);
	} else if p.atrack >= 0 {
		audio.source_flush(p.asrc);
	}
}

// One unit of work; false if nothing needed doing.
worker_step :: (p: *Player) -> bool {
	d := p.demux;
	locks.lock(*p.mu);
	playing := p.playing;
	nframes := p.frames.count;
	need_v := !p.eos_video && nframes < MAX_FRAMES && (playing || nframes == 0 || !p.seek_ready);
	need_a := p.audio_active && !p.eos_audio && (playing || p.pcm.count == 0) &&
		audio.source_queued_frames(p.asrc) + p.pcm.count / 2 < cast(int) (AUDIO_AHEAD * audio.SAMPLE_RATE);
	looping := p.looping;
	both_eos := p.eos_video && p.eos_audio;
	locks.unlock(*p.mu);

	// Flush leftover PCM into the ring first.
	if p.pcm.count > 0 {
		n := audio.source_write(p.asrc, p.pcm);
		if n > 0 remove_range(*p.pcm, 0, n * 2);
		if p.pcm.count > 0 && !need_v return false;
	}

	if both_eos && looping && p.duration > 0 {
		worker_loop(p);
		return true;
	}
	if !need_v && !need_a return false;

	do_video := need_v;
	if need_v && need_a {
		vt := *d.tracks[p.vtrack];
		at := *d.tracks[p.atrack];
		tv := ifx p.vnext < vt.packets.count then track_seconds(vt, vt.packets[p.vnext].dts) else 1.0e18;
		ta := ifx p.anext < at.packets.count then track_seconds(at, at.packets[p.anext].pts) else 1.0e18;
		do_video = tv <= ta;
	}
	return ifx do_video then video_step(p) else audio_step(p);
}

set_starved :: (p: *Player) -> bool {
	locks.lock(*p.mu);
	p.starved = true;
	locks.unlock(*p.mu);
	return false;
}

worker_loop :: (p: *Player) {
	locks.lock(*p.mu);
	p.loop_offset += p.duration;
	p.eos_video = p.vtrack < 0;
	p.eos_audio = !p.audio_active;
	locks.unlock(*p.mu);
	p.vnext = 0;
	p.anext = 0;
	p.discard_v = 0;
	p.discard_a = 0;
}

video_step :: (p: *Player) -> bool {
	d := p.demux;
	t := *d.tracks[p.vtrack];
	if p.vnext >= t.packets.count {
		if !d.complete return set_starved(p);
		if p.vdec video_decoder_flush(p.vdec);
		collect_frames(p);
		locks.lock(*p.mu);
		p.eos_video = true;
		p.seek_ready = true;
		locks.unlock(*p.mu);
		return true;
	}
	pk := t.packets[p.vnext];
	if demux_read(d, pk, *p.pkt) != .Ok return set_starved(p);
	if !p.vdec {
		vd, ok := video_decoder_create(t, p.pkt);
		if !ok {
			p.vtrack = -1;
			locks.lock(*p.mu);
			p.eos_video = true;
			locks.unlock(*p.mu);
			return true;
		}
		p.vdec = vd;
	}
	video_decode(p.vdec, p.pkt, track_seconds(t, pk.pts), track_seconds(t, pk.dts), track_seconds(t, pk.dur));
	p.vnext += 1;
	collect_frames(p);
	return true;
}

collect_frames :: (p: *Player) {
	p.vframes_tmp.count = 0;
	video_decoder_take(p.vdec, *p.vframes_tmp);
	if !p.vframes_tmp.count return;
	locks.lock(*p.mu);
	defer locks.unlock(*p.mu);
	stale := p.seek_req; // a seek arrived while decoding: these belong to the old position
	for * f: p.vframes_tmp {
		p.stats.video_decoded += 1;
		if stale {
			video_frame_release(f);
			continue;
		}
		end := f.pts + max(f.dur, 0.001);
		if end <= p.discard_v + 1.0e-6 {
			video_frame_release(f);
			p.stats.video_dropped += 1;
			continue;
		}
		f.pts += p.loop_offset;
		// insert sorted by pts
		i := p.frames.count;
		while i > 0 && p.frames[i - 1].pts > f.pts i -= 1;
		array_insert_at(*p.frames, f.*, i);
		p.since_seek += 1;
		// Ready once the covering frame is here, or after the reorder window
		// (target before the first frame: show the first one as a poster).
		if f.pts <= p.discard_v + p.loop_offset + 1.0e-6 || p.since_seek >= 4 p.seek_ready = true;
	}
}

audio_step :: (p: *Player) -> bool {
	d := p.demux;
	t := *d.tracks[p.atrack];
	if p.anext >= t.packets.count {
		if !d.complete return set_starved(p);
		locks.lock(*p.mu);
		p.eos_audio = true;
		locks.unlock(*p.mu);
		return true;
	}
	pk := t.packets[p.anext];
	if demux_read(d, pk, *p.pkt) != .Ok return set_starved(p);
	p.anext += 1;
	start := p.pcm.count;
	audio_decode(p.adec, p.pkt, *p.pcm);
	locks.lock(*p.mu);
	p.stats.audio_packets += 1;
	locks.unlock(*p.mu);
	// Trim samples before the seek target / pre-skip (pts < 0).
	pts := track_seconds(t, pk.pts);
	cut_before := max(p.discard_a, 0);
	if pts < cut_before {
		drop := cast(int) ((cut_before - pts) * audio.SAMPLE_RATE) * 2;
		remove_range(*p.pcm, start, start + min(drop, p.pcm.count - start));
	}
	if p.pcm.count > 0 remove_range(*p.pcm, 0, audio.source_write(p.asrc, p.pcm) * 2);
	return true;
}
