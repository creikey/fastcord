// media/audio demo + verification.
//
//	mediademo -probe <files...>              demux + decode every packet, print stats
//	mediademo -wave <file>                   print a 32-bucket waveform
//	mediademo -grab <file> [-png:<dir>]      headless: seek to timestamps, check frame colors
//	mediademo -audio                         play a muted tone, check the device consumed it
//	mediademo <file> [-seconds:N] [-loop]    windowed playback (space pause, arrows seek, L loop, M mute)
//
// Test clips encode the frame number as a solid color:
// rgb = (N*40 % 256, (N*90+30) % 256, (N*20+200) % 256), 30 fps.
package mediademo

import "core:fmt"
import "core:math"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:thread"
import "core:time"
import "fc:audio"
import "fc:gfx"
import "fc:media"
import "fc:platform"

main :: proc() {
	args := os.args[1:]
	if len(args) == 0 {
		fmt.eprintln("usage: see source header")
		os.exit(2)
	}
	switch args[0] {
	case "-probe":
		for f in args[1:] do probe_file(f)
	case "-wave":
		wave(args[1])
	case "-grab":
		png_dir := ""
		for a in args[2:] do if strings.has_prefix(a, "-png:") do png_dir = a[5:]
		os.exit(grab(args[1], png_dir) ? 0 : 1)
	case "-stream":
		chunk := 1024
		if len(args) > 2 do chunk, _ = strconv.parse_int(args[2])
		os.exit(stream_test(args[1], chunk) ? 0 : 1)
	case "-audio":
		os.exit(audio_test() ? 0 : 1)
	case:
		seconds: f64 = 0
		loop := false
		silent := false
		for a in args[1:] {
			if strings.has_prefix(a, "-seconds:") do seconds, _ = strconv.parse_f64(a[9:])
			if a == "-loop" do loop = true
			if a == "-silent" do silent = true
		}
		windowed(args[0], seconds, loop, silent)
	}
}

frame_color :: proc(n: int) -> [3]int {
	return {n * 40 % 256, (n * 90 + 30) % 256, (n * 20 + 200) % 256}
}

nearest_frame :: proc(rgb: [3]int, count: int) -> (int, int) {
	best, best_d := -1, max(int)
	for n in 0 ..< count {
		c := frame_color(n)
		d := abs(c.r - rgb.r) + abs(c.g - rgb.g) + abs(c.b - rgb.b)
		if d < best_d {best, best_d = n, d}
	}
	return best, best_d
}

// ---------------------------------------------------------------------------

grab :: proc(path: string, png_dir: string) -> bool {
	if !platform.init_headless(320, 240, 1) do return false
	if !gfx.init() do return false
	audio.init_null()
	src, ok := media.source_from_file(path)
	if !ok do return false
	p := media.player_open(src)
	defer media.player_destroy(p)
	for media.player_state(p) == .Opening do time.sleep(time.Millisecond)
	if media.player_state(p) == .Error {
		fmt.println("open failed")
		return false
	}
	first_pts := first_video_pts(path)
	times := []f64{0, 0.25, 0.5, 0.51, 0.999, 1.0, 1.034, 1.5, 1.9, 0.1}
	all_ok := true
	for t, ti in times {
		media.player_seek(p, t)
		img: media.Video_Image
		start := time.tick_now()
		for {
			im, changed := media.player_update(p)
			if changed {
				img = im
				break
			}
			if time.duration_seconds(time.tick_since(start)) > 3 do break
			time.sleep(500 * time.Microsecond)
		}
		latency := time.duration_milliseconds(time.tick_since(start))
		if img.y == 0 {
			fmt.printfln("t=%.3f: no frame", t)
			all_ok = false
			continue
		}
		gfx.begin_frame({0, 0, 0, 1})
		gfx.video({0, 0, 320, 240}, img.y, img.cbcr, img.yuv)
		gfx.end_frame()
		pixels, w, h := gfx.read_pixels(context.temp_allocator)
		i := (h / 2 * w + w / 2) * 4
		rgb := [3]int{int(pixels[i]), int(pixels[i + 1]), int(pixels[i + 2])}
		n, dist := nearest_frame(rgb, 60)
		expect := int(math.floor((t - first_pts) * 30 + 1e-6))
		expect = clamp(expect, 0, 59)
		covers := img.pts <= t + 1e-6 || t < first_pts
		ok_frame := n == expect && dist < 24 && covers
		if !ok_frame do all_ok = false
		fmt.printfln("t=%.3f -> pts=%.4f frame %d (expect %d) rgb=%v dist=%d seek->frame %.1fms %s", t, img.pts, n, expect, rgb, dist, latency, ok_frame ? "OK" : "MISMATCH")
		if png_dir != "" && ti == 2 {
			gfx.write_png(fmt.tprintf("%s/grab_%s.png", png_dir, strings.trim_suffix(path[strings.last_index(path, "/") + 1:], ".mp4")), pixels, w, h)
		}
	}
	// Playback without audio device: video-only clock must advance at real time.
	if !media.player_has_audio(p) {
		media.player_seek(p, 0)
		media.player_play(p)
		start := time.tick_now()
		shown := 0
		last_pts := -1.0
		for time.duration_seconds(time.tick_since(start)) < 1.0 {
			im, changed := media.player_update(p)
			if changed && im.pts != last_pts {
				shown += 1
				last_pts = im.pts
			}
			time.sleep(2 * time.Millisecond)
		}
		pos := media.player_position(p)
		fmt.printfln("play 1.0s wall: %d frames shown, position %.3f", shown, pos)
		if shown < 27 || abs(pos - 1.0) > 0.05 do all_ok = false
	}
	st := media.player_stats(p)
	fmt.printfln("stats: %v", st)
	fmt.println(all_ok ? "PASS" : "FAIL")
	return all_ok
}

first_video_pts :: proc(path: string) -> f64 {
	src, _ := media.source_from_file(path)
	defer media.source_destroy(&src)
	d, _ := media.demux_open(&src)
	if d == nil do return 0
	defer media.demux_destroy(d)
	media.demux_scan_all(d)
	v := media.demux_track(d, .Video)
	if v < 0 do return 0
	t := &d.tracks[v]
	m := max(i64)
	for p in t.packets do m = min(m, p.pts)
	return media.track_seconds(t, m)
}

// ---------------------------------------------------------------------------

// Simulated download: 1 KiB every 10 ms (~100 KB/s) from another thread while playing.
stream_test :: proc(path: string, chunk: int) -> bool {
	if !platform.init_headless(320, 240, 1) do return false
	if !gfx.init() do return false
	audio.init_null()
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil do return false
	gb := media.growing_create(len(data))
	Feed :: struct {gb: ^media.Growing_Buffer, data: []u8, chunk: int}
	feed := Feed{gb, data, chunk}
	th := thread.create_and_start_with_data(&feed, proc(user: rawptr) {
		f := (^Feed)(user)
		for off := 0; off < len(f.data); off += f.chunk {
			media.growing_append(f.gb, f.data[off:min(off + f.chunk, len(f.data))])
			time.sleep(10 * time.Millisecond)
		}
		media.growing_finish(f.gb)
	})
	p := media.player_open(media.source_from_growing(gb), autoplay = true, muted = true)
	start := time.tick_now()
	first_frame := -1.0
	shown := 0
	buffering_frames := 0
	for time.duration_seconds(time.tick_since(start)) < 10 {
		if media.player_is_buffering(p) do buffering_frames += 1
		_, changed := media.player_update(p)
		if changed {
			shown += 1
			if first_frame < 0 do first_frame = time.duration_seconds(time.tick_since(start))
		}
		if media.player_state(p) == .Ended || media.player_state(p) == .Error do break
		time.sleep(2 * time.Millisecond)
	}
	total := time.duration_seconds(time.tick_since(start))
	fmt.printfln("%s: %d bytes delivered over %.2fs; first frame after %.3fs; %d frames shown (%d dropped); buffering polls %d; state %v at %.2fs",
		path, len(data), f64(len(data) / chunk) * 0.01, first_frame, shown, media.player_stats(p).video_dropped, buffering_frames, media.player_state(p), total)
	ok := media.player_state(p) == .Ended && shown >= 55
	thread.join(th)
	thread.destroy(th)
	media.player_destroy(p)
	media.growing_release(gb)
	return ok
}

audio_test :: proc() -> bool {
	if !audio.init() {
		fmt.println("no audio device")
		return false
	}
	audio.set_volume(0) // silent: we only check the device pulls samples
	s := audio.source_create()
	tone := make([]f32, 48000 * 2)
	for i in 0 ..< 48000 {
		v := f32(math.sin(f64(i) * 2 * math.PI * 440 / 48000)) * 0.1
		tone[i * 2], tone[i * 2 + 1] = v, v
	}
	start := time.tick_now()
	written := 0
	for written < 48000 {
		written += audio.source_write(s, tone[written * 2:])
		time.sleep(5 * time.Millisecond)
	}
	for audio.source_queued_frames(s) > 0 && time.duration_seconds(time.tick_since(start)) < 3 {
		time.sleep(5 * time.Millisecond)
	}
	el := time.duration_seconds(time.tick_since(start))
	st := audio.stats()
	fmt.printfln("1.000s of audio consumed in %.3fs; %d callbacks (%.0f frames each); latency %.1fms; running=%v",
		el, st.callbacks, f64(st.frames_out) / f64(max(st.callbacks, 1)), audio.output_latency() * 1000, st.running)
	time.sleep(3000 * time.Millisecond)
	cb1 := audio.stats().callbacks
	time.sleep(500 * time.Millisecond)
	cb2 := audio.stats().callbacks
	fmt.printfln("after 2.5s idle: device running=%v, callbacks in next 0.5s: %d", audio.is_running(), cb2 - cb1)
	audio.source_destroy(s)
	audio.shutdown()
	return el > 0.9 && el < 1.3 && cb2 == cb1
}

// ---------------------------------------------------------------------------

probe_file :: proc(path: string) {
	src, ok := media.source_from_file(path)
	if !ok do return
	defer media.source_destroy(&src)
	info, pok := media.probe(&src)
	fmt.printfln("%s: ok=%v %v", path, pok, info)
}

wave :: proc(path: string) {
	src, ok := media.source_from_file(path)
	if !ok do return
	defer media.source_destroy(&src)
	w, dur, wok := media.audio_waveform(&src, 32)
	fmt.printfln("ok=%v duration=%.3fs waveform=%v", wok, dur, w)
}

// ---------------------------------------------------------------------------

App :: struct {
	p:         ^media.Player,
	img:       media.Video_Image,
	face:      gfx.Font_Face,
	shows:     [dynamic][2]f64, // (wall, pts) per new frame
	first_pts: f64,
}

app: App

windowed :: proc(path: string, seconds: f64, loop: bool, silent: bool) {
	if !platform.init("mediademo", 800, 600) do return
	if !gfx.init() do return
	audio.init()
	if silent do audio.set_volume(0) // clock still driven by the device
	app.face = gfx.font_system("system")
	app.first_pts = first_video_pts(path)
	src, ok := media.source_from_file(path)
	if !ok do return
	app.p = media.player_open(src, autoplay = true, looping = loop)
	platform.set_frame_callback(frame)
	start := platform.time_now()
	for !platform.should_quit() {
		platform.wait_events(seconds > 0 ? 0.1 : -1)
		frame()
		if seconds > 0 && platform.time_now() - start > seconds do break
	}
	report()
	fmt.printfln("final position %.3f, audio-driven=%v, stats %v", media.player_position(app.p), app.p.audio_driving, media.player_stats(app.p))
	media.player_destroy(app.p)
	audio.shutdown()
}

frame :: proc() {
	defer free_all(context.temp_allocator)
	p := app.p
	for e in platform.events() {
		if e.kind != .Key_Down do continue
		#partial switch e.key {
		case .Space: media.player_toggle(p)
		case .Left: media.player_seek(p, media.player_position(p) - 0.5)
		case .Right: media.player_seek(p, media.player_position(p) + 0.5)
		case .Comma: media.player_seek(p, media.player_position(p) - 1.0 / 30)
		case .Period: media.player_seek(p, media.player_position(p) + 1.0 / 30)
		case .L: media.player_set_loop(p, !p.looping)
		case .M: media.player_set_muted(p, !p.muted)
		case .Escape: platform.request_quit()
		}
	}
	img, changed := media.player_update(p)
	if changed do append(&app.shows, [2]f64{platform.time_now(), img.pts})
	app.img = img

	size := platform.window_size()
	gfx.begin_frame(gfx.rgb(0x1e1f22))
	if img.y != 0 {
		aspect := f32(img.size.x) / f32(max(img.size.y, 1))
		w := min(size.x - 40, (size.y - 120) * aspect)
		h := w / aspect
		x := (size.x - w) / 2
		gfx.video({x, 20, x + w, 20 + h}, img.y, img.cbcr, img.yuv, 8)
	}
	pos := media.player_position(p)
	dur := media.player_duration(p)
	bar := gfx.Rect{20, size.y - 70, size.x - 20, size.y - 64}
	gfx.rect(bar, gfx.rgb(0x4e5058), 3)
	if dur > 0 do gfx.rect({bar.x0, bar.y0, bar.x0 + (bar.x1 - bar.x0) * f32(pos / dur), bar.y1}, gfx.rgb(0x5865f2), 3)
	n := int(math.floor((img.pts - app.first_pts) * 30 + 0.5))
	info := fmt.tprintf("%.3f / %.3f  frame pts %.3f (#%d)  %s%s%s  [space] pause  [←/→] seek  [,/.] step  [L]oop  [M]ute",
		pos, dur, img.pts, n, media.player_is_playing(p) ? "playing" : "paused", p.looping ? " loop" : "", p.muted ? " muted" : "")
	gfx.draw_text(app.face, 13, info, {20, size.y - 36}, gfx.rgb(0xdbdee1))
	gfx.end_frame()
	if media.player_is_playing(p) do platform.request_frame()
}

report :: proc() {
	if len(app.shows) < 3 do return
	// offset between wall time and pts per shown frame; jitter = deviation from median
	offs := make([]f64, len(app.shows), context.temp_allocator)
	for s, i in app.shows do offs[i] = s[0] - s[1]
	sorted := slice.clone(offs, context.temp_allocator)
	slice.sort(sorted)
	med := sorted[len(sorted) / 2]
	maxdev, sum: f64
	skipped := 0
	for s, i in app.shows {
		dv := i == 0 ? 0 : abs(offs[i] - med) // first frame is the poster shown before the clock starts
		maxdev = max(maxdev, dv)
		sum += dv
		if i > 0 && s[1] - app.shows[i - 1][1] > 1.5 / 30 && s[1] > app.shows[i - 1][1] {
			skipped += 1
			fmt.printfln("  gap: pts %.4f -> %.4f at wall +%.3fs", app.shows[i - 1][1], s[1], s[0] - app.shows[0][0])
		}
	}
	fmt.printfln("shown %d frames; presentation jitter mean %.2fms max %.2fms (display %.0fHz); skipped %d",
		len(app.shows), sum / f64(len(app.shows)) * 1000, maxdev * 1000, platform.display_refresh_hz(), skipped)
}
