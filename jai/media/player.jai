// Audio/video player for attachments and embeds.
//
//	p := media.player_open(src)            // takes ownership of src
//	media.player_play(p)
//	every frame:
//		img, changed := media.player_update(p)
//		if img.y != 0 do gfx.video(dst, img.y, img.cbcr, img.yuv)
//		if media.player_is_playing(p) do platform.request_frame()
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
#scope_file

Segment :: struct {
	mark: u64; // audio write position (frames) where this segment starts
	base: float64; // global time of that sample
}
#scope_export

Player :: struct {
	src: Byte_Source;
	demux: *Demuxer;
	vtrack, atrack: int;
	vdec: *Video_Decoder;
	adec: *Audio_Decoder;
	thread: *thread.Thread;
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
	pending_seek: bool;

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

// Takes ownership of src. Returns nil only on allocation failure; check
// player_state for .Error (unsupported format).
player_open :: (src: Byte_Source, autoplay := false, looping := false, muted := false) -> *Player {
	p := new(Player);
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
	p.thread = thread.create(worker);
	p.thread.data = p;
	thread.start(p.thread);
	return p;
}

player_destroy :: (p: *Player) {
	if p == null { return; }
	locks.lock(*p.mu);
	p.quit = true;
	locks.unlock(*p.mu);
	locks.cond_broadcast(*p.cond);
	thread.join(p.thread);
	thread.destroy(p.thread);
	for * f: p.frames { video_frame_release(f); }
	delete(p.frames);
	delete(p.vframes_tmp);
	delete(p.pcm);
	delete(p.pkt);
	if p.vdec != null { video_decoder_destroy(p.vdec); }
	if p.adec != null { audio_decoder_destroy(p.adec); }
	if p.img.y != 0 { gfx.texture_destroy(p.img.y); }
	if p.img.cbcr != 0 { gfx.texture_destroy(p.img.cbcr); }
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
	if player_is_playing(p) { player_pause(p); } else { player_play(p); }
}

// Frame-accurate seek (seconds). The frame covering `t` is shown next.
player_seek :: (p: *Player, t: float64) {
	locks.lock(*p.mu);
	p.seek_req = true;
	p.seek_to = max(t, 0);
	// Frames decoded for the old position must never be shown.
	for * f: p.frames { video_frame_release(f); }
	clear(*p.frames);
	p.seek_ready = false;
	p.anchor_media = p.seek_to;
	p.anchor_wall = now_s();
	if p.state == .Ended { p.state = .Ready; }
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
	if p.muted == m { return; }
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
		if p.looping { t = math.mod(t, d); }
		t = min(t, d);
	}
	return max(t, 0);
}

player_has_video :: (p: *Player) -> bool {return p.vtrack >= 0;}
player_has_audio :: (p: *Player) -> bool {return p.atrack >= 0;}
player_stats :: (p: *Player) -> Player_Stats {
	locks.lock(*p.mu);
	defer locks.unlock(*p.mu);
	return p.stats;
}
#scope_module

now_s :: () -> float64 {return cast(float64)(time.tick_now()._nsec) / 1000000000;}

// Global media clock (seconds, not wrapped).
player_clock :: (p: *Player, now: float64) -> float64 {
	locks.lock(*p.mu);
	playing := p.playing && p.state == .Ready;
	audio_on := p.audio_active && !p.muted;
	segs := p.segments;
	nseg := p.nseg;
	eos_audio := p.eos_audio;
	buffering := p.starved && len(p.frames) == 0;
	locks.unlock(*p.mu);
	if !playing { return p.anchor_media; }
	if audio_on && nseg > 0 {
		rp := audio.source_read_pos(p.asrc);
		lat := audio.output_latency();
		// latest segment that has started playing
		for < i: 0..nseg - 1 {
			sg := segs[i];
			if rp < sg.mark { continue; }
			played := cast(float64)(rp - sg.mark) / audio.SAMPLE_RATE - lat;
			if played <= 0 { break; } // device hasn't reached it yet: hold
			drained := eos_audio && audio.source_queued_frames(p.asrc) == 0;
			if !drained {
				t := sg.base + played;
				p.anchor_media = t;
				p.anchor_wall = now;
				p.audio_driving = true;
				return t;
			}
			break;
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
#scope_export

// Call once per app frame. Returns the image to draw and whether it changed.
// (The player keeps its own monotonic clock, independent of platform time overrides.)
player_update :: (p: *Player) -> Video_Image, bool {
	clock := player_clock(p, now_s());
	changed := false;
	locks.lock(*p.mu);
	pick := -1;
	for f, i: p.frames {
		if f.pts <= clock + 0.0005 { pick = i; } else { break; }
	}
	if !p.seek_ready { pick = -1; } else if pick < 0 && !p.shown_any && len(p.frames) > 0 { pick = 0; } // poster frame
	consumed := false;
	if pick >= 0 {
		f := p.frames[pick];
		y, uv, ok := video_frame_textures(*f);
		if ok {
			if p.img.y != 0 { gfx.texture_destroy(p.img.y); }
			if p.img.cbcr != 0 { gfx.texture_destroy(p.img.cbcr); }
			p.img = .{y = y, cbcr = uv, size = .[f.width, f.height], yuv = f.yuv, pts = f.pts};
			changed = true;
			p.shown_any = true;
			p.stats.video_shown += 1;
		}
		p.stats.video_dropped += pick;
		for k: 0..pick { video_frame_release(*p.frames[k]); }
		remove_range(*p.frames, 0, pick + 1);
		consumed = true;
	}
	// End of stream?
	if p.state == .Ready && p.playing && !p.looping && p.eos_video && p.eos_audio && len(p.frames) == 0 && !p.seek_req {
		if !p.audio_active || p.muted || audio.source_queued_frames(p.asrc) == 0 {
			p.state = .Ended;
			p.playing = false;
			p.anchor_media = min(clock, p.duration);
		}
	}
	locks.unlock(*p.mu);
	if consumed { locks.cond_broadcast(*p.cond); }
	audio.update();
	return p.img, changed;
}
#scope_file

// ---------------------------------------------------------------------------
// Worker

worker :: (th: *thread.Thread) {
	p := cast(*Player)(th.data);
	if !worker_open(p) {
		locks.lock(*p.mu);
		p.state = .Error;
		locks.unlock(*p.mu);
		return;
	}
	while true {
		locks.lock(*p.mu);
		if p.quit {
			locks.unlock(*p.mu);
			return;
		}
		seek := p.seek_req;
		target := p.seek_to;
		p.seek_req = false;
		locks.unlock(*p.mu);
		if seek { worker_seek(p, target); }

		// Keep the index growing (streaming sources).
		scan_blocked := false;
		if !p.demux.complete {
			for _: 0..63 {
				s := demux_scan(p.demux);
				if s == .Need_Data {
					scan_blocked = true;
					break;
				}
				if s != .Progress { break; }
			}
			locks.lock(*p.mu);
			p.duration = max(p.duration, demux_duration(p.demux));
			locks.unlock(*p.mu);
		}

		did := worker_step(p);
		if did {
			locks.lock(*p.mu);
			p.starved = false;
			locks.unlock(*p.mu);
		}
		if !did {
			locks.lock(*p.mu);
			if !p.quit && !p.seek_req {
				// Audio drains continuously: poll while playing it; otherwise sleep until poked.
				if p.playing && p.audio_active && !p.eos_audio {
					locks.cond_wait_with_timeout(*p.cond, *p.mu, 40 * time.Millisecond);
				} else if scan_blocked && p.src.wait != null {
					locks.unlock(*p.mu);
					avail, _ := source_extent(*p.src);
					p.src.wait(p.src.user, avail, 100 * time.Millisecond);
					locks.lock(*p.mu);
				} else if scan_blocked {
					locks.cond_wait_with_timeout(*p.cond, *p.mu, 50 * time.Millisecond);
				} else {
					locks.cond_wait(*p.cond, *p.mu);
				}
			}
			locks.unlock(*p.mu);
		}
	}
}

worker_open :: (p: *Player) -> bool {
	while true {
		locks.lock(*p.mu);
		q := p.quit;
		locks.unlock(*p.mu);
		if q { return false; }
		if p.demux == null {
			d, s := demux_open(*p.src);
			if d == null {
				if s == .Error { return false; }
				wait_data(p);
				continue;
			}
			p.demux = d;
		}
		s := demux_scan_headers(p.demux);
		if s == .Error { return false; }
		if p.demux.ready { break; }
		wait_data(p);
	}
	d := p.demux;
	p.vtrack = demux_track(d, .Video);
	p.atrack = demux_track(d, .Audio);
	if p.vtrack >= 0 && !video_codec_supported(d.tracks[p.vtrack].codec) { p.vtrack = -1; }
	if p.atrack >= 0 && !audio_codec_supported(d.tracks[p.atrack].codec) { p.atrack = -1; }
	if p.vtrack < 0 && p.atrack < 0 { return false; }
	if p.atrack >= 0 {
		ad, ok := audio_decoder_create(*d.tracks[p.atrack]);
		if ok { p.adec = ad; } else { p.atrack = -1; }
	}
	locks.lock(*p.mu);
	p.duration = demux_duration(d);
	p.state = .Ready;
	p.eos_video = p.vtrack < 0;
	p.audio_active = p.atrack >= 0 && !p.muted;
	p.eos_audio = !p.audio_active;
	if p.audio_active { add_segment(p, 0); }
	locks.unlock(*p.mu);
	if p.playing { audio.source_set_paused(p.asrc, false); }
	return true;
}

wait_data :: (p: *Player) {
	if p.src.wait != null {
		avail, _ := source_extent(*p.src);
		p.src.wait(p.src.user, avail, 100 * time.Millisecond);
	} else {
		time.sleep(20 * time.Millisecond);
	}
}

// mu held
add_segment :: (p: *Player, base: float64) {
	sg := Segment.{audio.source_write_pos(p.asrc), base};
	if p.nseg == len(p.segments) {
		copy(view(p.segments), sub_from(p.segments, 1));
		p.nseg -= 1;
	}
	p.segments[p.nseg] = sg;
	p.nseg += 1;
}

worker_seek :: (p: *Player, target: float64) {
	d := p.demux;
	locks.lock(*p.mu);
	for * f: p.frames { video_frame_release(f); }
	clear(*p.frames);
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
		if p.vdec != null { video_decoder_flush(p.vdec); }
		tmp := make_dynamic(Video_Frame, 0, 0, temp);
		if p.vdec != null { video_decoder_take(p.vdec, *tmp); }
		for * f: tmp { video_frame_release(f); }
		p.discard_v = target;
	}
	if p.audio_active {
		t := *d.tracks[p.atrack];
		// start a little before (decoder pre-roll), trim precisely by pts
		p.anext = demux_find_keyframe(t, track_ticks(t, max(target - 0.1, 0)));
		audio_decoder_reset(p.adec);
		clear(*p.pcm);
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
	nframes := len(p.frames);
	need_v := !p.eos_video && nframes < MAX_FRAMES && (playing || nframes == 0 || !p.seek_ready);
	need_a := p.audio_active && !p.eos_audio && (playing || len(p.pcm) == 0) &&
		audio.source_queued_frames(p.asrc) + len(p.pcm) / 2 < cast(int)(AUDIO_AHEAD * audio.SAMPLE_RATE);
	looping := p.looping;
	both_eos := p.eos_video && p.eos_audio;
	locks.unlock(*p.mu);

	// Flush leftover PCM into the ring first.
	if len(p.pcm) > 0 {
		n := audio.source_write(p.asrc, view(p.pcm));
		if n > 0 { remove_range(*p.pcm, 0, n * 2); }
		if len(p.pcm) > 0 && !need_v { return false; }
	}

	if both_eos && looping && p.duration > 0 {
		worker_loop(p);
		return true;
	}
	if !need_v && !need_a { return false; }

	do_video := need_v;
	if need_v && need_a {
		vt := *d.tracks[p.vtrack];
		at := *d.tracks[p.atrack];
		tv := ifx p.vnext < len(vt.packets) then track_seconds(vt, vt.packets[p.vnext].dts) else 1000000000000000000;
		ta := ifx p.anext < len(at.packets) then track_seconds(at, at.packets[p.anext].pts) else 1000000000000000000;
		do_video = tv <= ta;
	}
	if do_video { return video_step(p); }
	return audio_step(p);
}

set_starved :: (p: *Player) -> bool {
	locks.lock(*p.mu);
	p.starved = true;
	locks.unlock(*p.mu);
	return false;
}
#scope_export

// True while playback is stalled waiting for download.
player_is_buffering :: (p: *Player) -> bool {
	locks.lock(*p.mu);
	defer locks.unlock(*p.mu);
	return p.starved && len(p.frames) == 0 && p.state == .Ready;
}
#scope_file

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
	if p.vnext >= len(t.packets) {
		if !d.complete { return set_starved(p); }
		if p.vdec != null { video_decoder_flush(p.vdec); }
		collect_frames(p);
		locks.lock(*p.mu);
		p.eos_video = true;
		p.seek_ready = true;
		locks.unlock(*p.mu);
		return true;
	}
	pk := t.packets[p.vnext];
	if demux_read(d, pk, *p.pkt) != .Ok { return set_starved(p); }
	if p.vdec == null {
		vd, ok := video_decoder_create(t, view(p.pkt));
		if !ok {
			p.vtrack = -1;
			locks.lock(*p.mu);
			p.eos_video = true;
			locks.unlock(*p.mu);
			return true;
		}
		p.vdec = vd;
	}
	video_decode(p.vdec, view(p.pkt), track_seconds(t, pk.pts), track_seconds(t, pk.dts), track_seconds(t, cast(s64)(pk.dur)));
	p.vnext += 1;
	collect_frames(p);
	return true;
}

collect_frames :: (p: *Player) {
	clear(*p.vframes_tmp);
	video_decoder_take(p.vdec, *p.vframes_tmp);
	if len(p.vframes_tmp) == 0 { return; }
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
		i := len(p.frames);
		while i > 0 && p.frames[i - 1].pts > f.pts { i -= 1; }
		inject_at(*p.frames, i, f.*);
		p.since_seek += 1;
		// Ready once the covering frame is here, or after the reorder window
		// (target before the first frame: show the first one as a poster).
		if f.pts <= p.discard_v + p.loop_offset + 1.0e-6 || p.since_seek >= 4 { p.seek_ready = true; }
	}
}

audio_step :: (p: *Player) -> bool {
	d := p.demux;
	t := *d.tracks[p.atrack];
	if p.anext >= len(t.packets) {
		if !d.complete { return set_starved(p); }
		locks.lock(*p.mu);
		p.eos_audio = true;
		locks.unlock(*p.mu);
		return true;
	}
	pk := t.packets[p.anext];
	if demux_read(d, pk, *p.pkt) != .Ok { return set_starved(p); }
	p.anext += 1;
	start := len(p.pcm);
	audio_decode(p.adec, view(p.pkt), *p.pcm);
	locks.lock(*p.mu);
	p.stats.audio_packets += 1;
	locks.unlock(*p.mu);
	// Trim samples before the seek target / pre-skip (pts < 0).
	pts := track_seconds(t, pk.pts);
	cut_before := max(p.discard_a, 0);
	if pts < cut_before {
		drop := cast(int)((cut_before - pts) * audio.SAMPLE_RATE) * 2;
		drop = min(drop, len(p.pcm) - start);
		remove_range(*p.pcm, start, start + drop);
	}
	if len(p.pcm) > 0 {
		n := audio.source_write(p.asrc, view(p.pcm));
		remove_range(*p.pcm, 0, n * 2);
	}
	return true;
}
#scope_module

// Odin remove_range (missing from fc): drops a[lo:hi], keeping order.
remove_range :: (a: *[..]$T, lo: int, hi: int) {
	n := hi - lo;
	if n <= 0 { return; }
	for i: hi..a.count-1 { a.*[i - n] = a.*[i]; }
	a.count -= n;
}
