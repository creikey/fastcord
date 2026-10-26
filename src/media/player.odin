package media

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

import "core:math"
import "core:sync"
import "core:thread"
import "core:time"
import "fc:audio"
import "fc:gfx"

MAX_FRAMES :: 5
AUDIO_AHEAD :: 0.3 // seconds queued in the mixer ring

Player_State :: enum u8 {
	Opening, // waiting for headers
	Ready, // paused / playing normally
	Ended,
	Error,
}

Video_Image :: struct {
	y, cbcr: gfx.Texture, // 0 if no frame yet
	size:    [2]int,
	yuv:     gfx.Yuv_Matrix,
	pts:     f64,
}

@(private = "file")
Segment :: struct {
	mark: u64, // audio write position (frames) where this segment starts
	base: f64, // global time of that sample
}

Player :: struct {
	src:            Byte_Source,
	demux:          ^Demuxer,
	vtrack, atrack: int,
	vdec:           ^Video_Decoder,
	adec:           ^Audio_Decoder,
	thread:         ^thread.Thread,
	mu:             sync.Mutex,
	cond:           sync.Cond,

	// ---- shared (mu)
	quit:           bool,
	state:          Player_State,
	playing:        bool,
	looping:        bool,
	muted:          bool,
	volume:         f32,
	seek_req:       bool,
	seek_to:        f64,
	starved:        bool, // worker waiting for bytes that haven't downloaded yet (buffering)
	seek_ready:     bool, // the frame covering the seek target (or a poster) has been decoded
	since_seek:     int, // frames decoded since the last seek
	frames:         [dynamic]Video_Frame, // decoded, sorted by pts (global time)
	eos_video:      bool,
	eos_audio:      bool,
	segments:       [4]Segment,
	nseg:           int,
	audio_active:   bool,
	loop_offset:    f64,
	duration:       f64,
	stats:          Player_Stats,

	// ---- worker only
	vnext, anext:   int,
	discard_v:      f64,
	discard_a:      f64,
	pcm:            [dynamic]f32,
	pkt:            [dynamic]u8,
	vframes_tmp:    [dynamic]Video_Frame,
	pending_seek:   bool,

	// ---- main thread
	asrc:           audio.Source,
	anchor_wall:    f64,
	anchor_media:   f64,
	audio_driving:  bool,
	img:            Video_Image,
	shown_any:      bool,
}

Player_Stats :: struct {
	video_decoded: int,
	video_dropped: int, // decoded but never shown (late or seek-discarded)
	video_shown:   int,
	audio_packets: int,
}

// Takes ownership of src. Returns nil only on allocation failure; check
// player_state for .Error (unsupported format).
player_open :: proc(src: Byte_Source, autoplay := false, looping := false, muted := false) -> ^Player {
	p := new(Player)
	p.src = src
	p.vtrack = -1
	p.atrack = -1
	p.volume = 1
	p.looping = looping
	p.muted = muted
	p.playing = autoplay
	p.state = .Opening
	p.anchor_wall = now_s()
	p.asrc = audio.source_create()
	audio.source_set_paused(p.asrc, !autoplay)
	p.thread = thread.create(worker)
	p.thread.data = p
	thread.start(p.thread)
	return p
}

player_destroy :: proc(p: ^Player) {
	if p == nil do return
	sync.mutex_lock(&p.mu)
	p.quit = true
	sync.mutex_unlock(&p.mu)
	sync.cond_broadcast(&p.cond)
	thread.join(p.thread)
	thread.destroy(p.thread)
	for &f in p.frames do video_frame_release(&f)
	delete(p.frames)
	delete(p.vframes_tmp)
	delete(p.pcm)
	delete(p.pkt)
	if p.vdec != nil do video_decoder_destroy(p.vdec)
	if p.adec != nil do audio_decoder_destroy(p.adec)
	if p.img.y != 0 do gfx.texture_destroy(p.img.y)
	if p.img.cbcr != 0 do gfx.texture_destroy(p.img.cbcr)
	audio.source_destroy(p.asrc)
	demux_destroy(p.demux)
	source_destroy(&p.src)
	free(p)
}

player_play :: proc(p: ^Player) {
	sync.mutex_lock(&p.mu)
	if p.state == .Ended {
		p.seek_req = true
		p.seek_to = 0
		p.state = .Ready
	}
	if !p.playing {
		p.playing = true
		p.anchor_wall = now_s()
	}
	sync.mutex_unlock(&p.mu)
	audio.source_set_paused(p.asrc, false)
	sync.cond_broadcast(&p.cond)
}

player_pause :: proc(p: ^Player) {
	t := player_clock(p, now_s())
	sync.mutex_lock(&p.mu)
	p.playing = false
	p.anchor_media = t
	sync.mutex_unlock(&p.mu)
	audio.source_set_paused(p.asrc, true)
	p.audio_driving = false
}

player_toggle :: proc(p: ^Player) {
	if player_is_playing(p) do player_pause(p)
	else do player_play(p)
}

// Frame-accurate seek (seconds). The frame covering `t` is shown next.
player_seek :: proc(p: ^Player, t: f64) {
	sync.mutex_lock(&p.mu)
	p.seek_req = true
	p.seek_to = max(t, 0)
	// Frames decoded for the old position must never be shown.
	for &f in p.frames do video_frame_release(&f)
	clear(&p.frames)
	p.seek_ready = false
	p.anchor_media = p.seek_to
	p.anchor_wall = now_s()
	if p.state == .Ended do p.state = .Ready
	sync.mutex_unlock(&p.mu)
	p.audio_driving = false
	p.shown_any = false
	sync.cond_broadcast(&p.cond)
}

player_set_loop :: proc(p: ^Player, on: bool) {
	sync.mutex_lock(&p.mu)
	p.looping = on
	sync.mutex_unlock(&p.mu)
	sync.cond_broadcast(&p.cond)
}

player_set_volume :: proc(p: ^Player, v: f32) {
	p.volume = v
	audio.source_set_volume(p.asrc, v)
}

// Muting stops audio decoding entirely (battery); unmuting resyncs at the current position.
player_set_muted :: proc(p: ^Player, m: bool) {
	if p.muted == m do return
	t := player_clock(p, now_s())
	p.muted = m
	player_seek(p, t)
}

player_is_playing :: proc(p: ^Player) -> bool {
	sync.mutex_lock(&p.mu)
	defer sync.mutex_unlock(&p.mu)
	return p.playing && p.state != .Ended
}

player_state :: proc(p: ^Player) -> Player_State {
	sync.mutex_lock(&p.mu)
	defer sync.mutex_unlock(&p.mu)
	return p.state
}

player_duration :: proc(p: ^Player) -> f64 {
	sync.mutex_lock(&p.mu)
	defer sync.mutex_unlock(&p.mu)
	return p.duration
}

// Current position in seconds (wraps when looping).
player_position :: proc(p: ^Player) -> f64 {
	t := player_clock(p, now_s())
	d := player_duration(p)
	if d > 0 {
		if p.looping do t = math.mod(t, d)
		t = min(t, d)
	}
	return max(t, 0)
}

player_has_video :: proc(p: ^Player) -> bool {return p.vtrack >= 0}
player_has_audio :: proc(p: ^Player) -> bool {return p.atrack >= 0}
player_stats :: proc(p: ^Player) -> Player_Stats {
	sync.mutex_lock(&p.mu)
	defer sync.mutex_unlock(&p.mu)
	return p.stats
}

@(private)
now_s :: proc() -> f64 {return f64(time.tick_now()._nsec) / 1e9}

// Global media clock (seconds, not wrapped).
@(private)
player_clock :: proc(p: ^Player, now: f64) -> f64 {
	sync.mutex_lock(&p.mu)
	playing := p.playing && p.state == .Ready
	audio_on := p.audio_active && !p.muted
	segs := p.segments
	nseg := p.nseg
	eos_audio := p.eos_audio
	buffering := p.starved && len(p.frames) == 0
	sync.mutex_unlock(&p.mu)
	if !playing do return p.anchor_media
	if audio_on && nseg > 0 {
		rp := audio.source_read_pos(p.asrc)
		lat := audio.output_latency()
		// latest segment that has started playing
		for i := nseg - 1; i >= 0; i -= 1 {
			sg := segs[i]
			if rp < sg.mark do continue
			played := f64(rp - sg.mark) / audio.SAMPLE_RATE - lat
			if played <= 0 do break // device hasn't reached it yet: hold
			drained := eos_audio && audio.source_queued_frames(p.asrc) == 0
			if !drained {
				t := sg.base + played
				p.anchor_media = t
				p.anchor_wall = now
				p.audio_driving = true
				return t
			}
			break
		}
		if !p.audio_driving && !eos_audio {
			// audio hasn't started yet: hold the clock so video waits for it
			p.anchor_wall = now
			return p.anchor_media
		}
	}
	if !p.shown_any || buffering {
		// Don't start the wall clock before the first frame is on screen
		// (startup / seek), or the first frames would be skipped.
		p.anchor_wall = now
		return p.anchor_media
	}
	return p.anchor_media + (now - p.anchor_wall)
}

// Call once per app frame. Returns the image to draw and whether it changed.
// (The player keeps its own monotonic clock, independent of platform time overrides.)
player_update :: proc(p: ^Player) -> (Video_Image, bool) {
	clock := player_clock(p, now_s())
	changed := false
	sync.mutex_lock(&p.mu)
	pick := -1
	for f, i in p.frames {
		if f.pts <= clock + 0.0005 do pick = i
		else do break
	}
	if !p.seek_ready do pick = -1 // B-frame reorder: wait for the frame that covers the target
	else if pick < 0 && !p.shown_any && len(p.frames) > 0 do pick = 0 // poster frame
	consumed := false
	if pick >= 0 {
		f := p.frames[pick]
		y, uv, ok := video_frame_textures(&f)
		if ok {
			if p.img.y != 0 do gfx.texture_destroy(p.img.y)
			if p.img.cbcr != 0 do gfx.texture_destroy(p.img.cbcr)
			p.img = {y = y, cbcr = uv, size = {f.width, f.height}, yuv = f.yuv, pts = f.pts}
			changed = true
			p.shown_any = true
			p.stats.video_shown += 1
		}
		p.stats.video_dropped += pick
		for k in 0 ..= pick do video_frame_release(&p.frames[k])
		remove_range(&p.frames, 0, pick + 1)
		consumed = true
	}
	// End of stream?
	if p.state == .Ready && p.playing && !p.looping && p.eos_video && p.eos_audio && len(p.frames) == 0 && !p.seek_req {
		if !p.audio_active || p.muted || audio.source_queued_frames(p.asrc) == 0 {
			p.state = .Ended
			p.playing = false
			p.anchor_media = min(clock, p.duration)
		}
	}
	sync.mutex_unlock(&p.mu)
	if consumed do sync.cond_broadcast(&p.cond)
	audio.update()
	return p.img, changed
}

// ---------------------------------------------------------------------------
// Worker

@(private = "file")
worker :: proc(th: ^thread.Thread) {
	p := (^Player)(th.data)
	if !worker_open(p) {
		sync.mutex_lock(&p.mu)
		p.state = .Error
		sync.mutex_unlock(&p.mu)
		return
	}
	for {
		sync.mutex_lock(&p.mu)
		if p.quit {
			sync.mutex_unlock(&p.mu)
			return
		}
		seek := p.seek_req
		target := p.seek_to
		p.seek_req = false
		sync.mutex_unlock(&p.mu)
		if seek do worker_seek(p, target)

		// Keep the index growing (streaming sources).
		scan_blocked := false
		if !p.demux.complete {
			for _ in 0 ..< 64 {
				s := demux_scan(p.demux)
				if s == .Need_Data {
					scan_blocked = true
					break
				}
				if s != .Progress do break
			}
			sync.mutex_lock(&p.mu)
			p.duration = max(p.duration, demux_duration(p.demux))
			sync.mutex_unlock(&p.mu)
		}

		did := worker_step(p)
		if did {
			sync.mutex_lock(&p.mu)
			p.starved = false
			sync.mutex_unlock(&p.mu)
		}
		if !did {
			sync.mutex_lock(&p.mu)
			if !p.quit && !p.seek_req {
				// Audio drains continuously: poll while playing it; otherwise sleep until poked.
				if p.playing && p.audio_active && !p.eos_audio {
					sync.cond_wait_with_timeout(&p.cond, &p.mu, 40 * time.Millisecond)
				} else if scan_blocked && p.src.wait != nil {
					sync.mutex_unlock(&p.mu)
					avail, _ := source_extent(&p.src)
					p.src.wait(p.src.user, avail, 100 * time.Millisecond)
					sync.mutex_lock(&p.mu)
				} else if scan_blocked {
					sync.cond_wait_with_timeout(&p.cond, &p.mu, 50 * time.Millisecond)
				} else {
					sync.cond_wait(&p.cond, &p.mu)
				}
			}
			sync.mutex_unlock(&p.mu)
		}
	}
}

@(private = "file")
worker_open :: proc(p: ^Player) -> bool {
	for {
		sync.mutex_lock(&p.mu)
		q := p.quit
		sync.mutex_unlock(&p.mu)
		if q do return false
		if p.demux == nil {
			d, s := demux_open(&p.src)
			if d == nil {
				if s == .Error do return false
				wait_data(p)
				continue
			}
			p.demux = d
		}
		s := demux_scan_headers(p.demux)
		if s == .Error do return false
		if p.demux.ready do break
		wait_data(p)
	}
	d := p.demux
	p.vtrack = demux_track(d, .Video)
	p.atrack = demux_track(d, .Audio)
	if p.vtrack >= 0 && !video_codec_supported(d.tracks[p.vtrack].codec) do p.vtrack = -1
	if p.atrack >= 0 && !audio_codec_supported(d.tracks[p.atrack].codec) do p.atrack = -1
	if p.vtrack < 0 && p.atrack < 0 do return false
	if p.atrack >= 0 {
		ad, ok := audio_decoder_create(&d.tracks[p.atrack])
		if ok do p.adec = ad
		else do p.atrack = -1
	}
	sync.mutex_lock(&p.mu)
	p.duration = demux_duration(d)
	p.state = .Ready
	p.eos_video = p.vtrack < 0
	p.audio_active = p.atrack >= 0 && !p.muted
	p.eos_audio = !p.audio_active
	if p.audio_active do add_segment(p, 0)
	sync.mutex_unlock(&p.mu)
	if p.playing do audio.source_set_paused(p.asrc, false)
	return true
}

@(private = "file")
wait_data :: proc(p: ^Player) {
	if p.src.wait != nil {
		avail, _ := source_extent(&p.src)
		p.src.wait(p.src.user, avail, 100 * time.Millisecond)
	} else {
		time.sleep(20 * time.Millisecond)
	}
}

// mu held
@(private = "file")
add_segment :: proc(p: ^Player, base: f64) {
	sg := Segment{audio.source_write_pos(p.asrc), base}
	if p.nseg == len(p.segments) {
		copy(p.segments[:], p.segments[1:])
		p.nseg -= 1
	}
	p.segments[p.nseg] = sg
	p.nseg += 1
}

@(private = "file")
worker_seek :: proc(p: ^Player, target: f64) {
	d := p.demux
	sync.mutex_lock(&p.mu)
	for &f in p.frames do video_frame_release(&f)
	clear(&p.frames)
	p.seek_ready = p.vtrack < 0
	p.since_seek = 0
	p.loop_offset = 0
	p.eos_video = p.vtrack < 0
	p.audio_active = p.atrack >= 0 && !p.muted
	p.eos_audio = !p.audio_active
	p.nseg = 0
	sync.mutex_unlock(&p.mu)

	if p.vtrack >= 0 {
		t := &d.tracks[p.vtrack]
		p.vnext = demux_find_keyframe(t, track_ticks(t, target))
		if p.vdec != nil do video_decoder_flush(p.vdec)
		tmp := make([dynamic]Video_Frame, context.temp_allocator)
		if p.vdec != nil do video_decoder_take(p.vdec, &tmp)
		for &f in tmp do video_frame_release(&f)
		p.discard_v = target
	}
	if p.audio_active {
		t := &d.tracks[p.atrack]
		// start a little before (decoder pre-roll), trim precisely by pts
		p.anext = demux_find_keyframe(t, track_ticks(t, max(target - 0.1, 0)))
		audio_decoder_reset(p.adec)
		clear(&p.pcm)
		p.discard_a = target
		audio.source_flush(p.asrc)
		sync.mutex_lock(&p.mu)
		add_segment(p, target)
		sync.mutex_unlock(&p.mu)
	} else if p.atrack >= 0 {
		audio.source_flush(p.asrc)
	}
}

// One unit of work; false if nothing needed doing.
@(private = "file")
worker_step :: proc(p: ^Player) -> bool {
	d := p.demux
	sync.mutex_lock(&p.mu)
	playing := p.playing
	nframes := len(p.frames)
	need_v := !p.eos_video && nframes < MAX_FRAMES && (playing || nframes == 0 || !p.seek_ready)
	need_a := p.audio_active && !p.eos_audio && (playing || len(p.pcm) == 0) &&
		audio.source_queued_frames(p.asrc) + len(p.pcm) / 2 < int(AUDIO_AHEAD * audio.SAMPLE_RATE)
	looping := p.looping
	both_eos := p.eos_video && p.eos_audio
	sync.mutex_unlock(&p.mu)

	// Flush leftover PCM into the ring first.
	if len(p.pcm) > 0 {
		n := audio.source_write(p.asrc, p.pcm[:])
		if n > 0 do remove_range(&p.pcm, 0, n * 2)
		if len(p.pcm) > 0 && !need_v do return false
	}

	if both_eos && looping && p.duration > 0 {
		worker_loop(p)
		return true
	}
	if !need_v && !need_a do return false

	do_video := need_v
	if need_v && need_a {
		vt := &d.tracks[p.vtrack]
		at := &d.tracks[p.atrack]
		tv := p.vnext < len(vt.packets) ? track_seconds(vt, vt.packets[p.vnext].dts) : 1e18
		ta := p.anext < len(at.packets) ? track_seconds(at, at.packets[p.anext].pts) : 1e18
		do_video = tv <= ta
	}
	if do_video do return video_step(p)
	return audio_step(p)
}

@(private = "file")
set_starved :: proc(p: ^Player) -> bool {
	sync.mutex_lock(&p.mu)
	p.starved = true
	sync.mutex_unlock(&p.mu)
	return false
}

// True while playback is stalled waiting for download.
player_is_buffering :: proc(p: ^Player) -> bool {
	sync.mutex_lock(&p.mu)
	defer sync.mutex_unlock(&p.mu)
	return p.starved && len(p.frames) == 0 && p.state == .Ready
}

@(private = "file")
worker_loop :: proc(p: ^Player) {
	sync.mutex_lock(&p.mu)
	p.loop_offset += p.duration
	p.eos_video = p.vtrack < 0
	p.eos_audio = !p.audio_active
	sync.mutex_unlock(&p.mu)
	p.vnext = 0
	p.anext = 0
	p.discard_v = 0
	p.discard_a = 0
}

@(private = "file")
video_step :: proc(p: ^Player) -> bool {
	d := p.demux
	t := &d.tracks[p.vtrack]
	if p.vnext >= len(t.packets) {
		if !d.complete do return set_starved(p)
		if p.vdec != nil do video_decoder_flush(p.vdec)
		collect_frames(p)
		sync.mutex_lock(&p.mu)
		p.eos_video = true
		p.seek_ready = true
		sync.mutex_unlock(&p.mu)
		return true
	}
	pk := t.packets[p.vnext]
	if demux_read(d, pk, &p.pkt) != .Ok do return set_starved(p)
	if p.vdec == nil {
		vd, ok := video_decoder_create(t, p.pkt[:])
		if !ok {
			p.vtrack = -1
			sync.mutex_lock(&p.mu)
			p.eos_video = true
			sync.mutex_unlock(&p.mu)
			return true
		}
		p.vdec = vd
	}
	video_decode(p.vdec, p.pkt[:], track_seconds(t, pk.pts), track_seconds(t, pk.dts), track_seconds(t, i64(pk.dur)))
	p.vnext += 1
	collect_frames(p)
	return true
}

@(private = "file")
collect_frames :: proc(p: ^Player) {
	clear(&p.vframes_tmp)
	video_decoder_take(p.vdec, &p.vframes_tmp)
	if len(p.vframes_tmp) == 0 do return
	sync.mutex_lock(&p.mu)
	defer sync.mutex_unlock(&p.mu)
	stale := p.seek_req // a seek arrived while decoding: these belong to the old position
	for &f in p.vframes_tmp {
		p.stats.video_decoded += 1
		if stale {
			video_frame_release(&f)
			continue
		}
		end := f.pts + max(f.dur, 0.001)
		if end <= p.discard_v + 1e-6 {
			video_frame_release(&f)
			p.stats.video_dropped += 1
			continue
		}
		f.pts += p.loop_offset
		// insert sorted by pts
		i := len(p.frames)
		for i > 0 && p.frames[i - 1].pts > f.pts do i -= 1
		inject_at(&p.frames, i, f)
		p.since_seek += 1
		// Ready once the covering frame is here, or after the reorder window
		// (target before the first frame: show the first one as a poster).
		if f.pts <= p.discard_v + p.loop_offset + 1e-6 || p.since_seek >= 4 do p.seek_ready = true
	}
}

@(private = "file")
audio_step :: proc(p: ^Player) -> bool {
	d := p.demux
	t := &d.tracks[p.atrack]
	if p.anext >= len(t.packets) {
		if !d.complete do return set_starved(p)
		sync.mutex_lock(&p.mu)
		p.eos_audio = true
		sync.mutex_unlock(&p.mu)
		return true
	}
	pk := t.packets[p.anext]
	if demux_read(d, pk, &p.pkt) != .Ok do return set_starved(p)
	p.anext += 1
	start := len(p.pcm)
	audio_decode(p.adec, p.pkt[:], &p.pcm)
	sync.mutex_lock(&p.mu)
	p.stats.audio_packets += 1
	sync.mutex_unlock(&p.mu)
	// Trim samples before the seek target / pre-skip (pts < 0).
	pts := track_seconds(t, pk.pts)
	cut_before := max(p.discard_a, 0)
	if pts < cut_before {
		drop := int((cut_before - pts) * audio.SAMPLE_RATE) * 2
		drop = min(drop, len(p.pcm) - start)
		remove_range(&p.pcm, start, start + drop)
	}
	if len(p.pcm) > 0 {
		n := audio.source_write(p.asrc, p.pcm[:])
		remove_range(&p.pcm, 0, n * 2)
	}
	return true
}
