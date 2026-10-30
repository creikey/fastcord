// Go Live capture on Linux, end to end: the ScreenCast portal (or a stand-in, tools/fake_screencast_portal.py),
// PipeWire's video and soundshare. Writes the last frame to build/screen_linux.ppm. "self" also plays a
// louder tone through fastcord's own output, which soundshare must leave out; "small" caps the height at 100.
// jai build.jai - run src/tests/screen_linux.jai linux, then on Linux: build/screen_linux [seconds] [self|small]
#import "Basic";
#import "File";
#import "Atomics";
#import "Math";
video :: #import "video";
yuv :: #import "yuv";
audio :: #import "audio";

frames, samples: s64;
size: [2]int;
energy: float64;
last: *yuv.Nv12;

main :: () {
	args := get_command_line_arguments();
	seconds := 5;
	if args.count > 1 seconds = string_to_int(args[1]);
	tone: audio.Source;
	if args.count > 2 && args[2] == "self" {
		if !audio.init() { print("FAIL: no audio output\n"); exit(1); }
		tone = audio.source_create();
	}
	phase := 0;
	c := video.screen_start(video.screen_targets()[0], (user: *void, pixbuf: *void, width: int, height: int) {
		atomic_add(*frames, 1);
		size = .[width, height];
		f := yuv.nv12_retain(cast(*yuv.Nv12) pixbuf);
		old := atomic_swap(*last, f);
		yuv.nv12_release(old);
	}, null, 30, ifx args.count > 2 && args[2] == "small" then 100 else 1080, (user: *void, pcm: []float32) {
		samples += pcm.count;
		for pcm energy += it * it;
	});
	for 1..seconds * 10 {
		if tone { // 0.5 amplitude at 1 kHz, kept 200 ms ahead
			buf: [9600]float32;
			n := 4800 - audio.source_queued_frames(tone);
			for i: 0..n - 1 { v := 0.5 * sin(phase * TAU / 48); phase += 1; buf[2 * i], buf[2 * i + 1] = v, v; }
			if n > 0 audio.source_write(tone, array_view(buf, 0, 2 * n));
		}
		sleep_milliseconds(100);
		err := video.capture_error(c);
		if err { print("capture ended: %\n", err); break; }
	}
	video.capture_stop(c);
	print("frames % (% fps) at %x%; soundshare % samples (% s), rms %\n", frames, frames / seconds, size[0], size[1], samples, samples / 48000.0, sqrt(energy / max(samples, 1)));
	f := atomic_swap(*last, null);
	if f {
		// NV12 -> RGB (BT.709 from 720 lines up, as encoded)
		w, h := f.width, f.height;
		out: String_Builder;
		print_to_builder(*out, "P6\n% %\n255\n", w, h);
		hd := h >= 720;
		for y: 0..h - 1 for x: 0..w - 1 {
			Y := cast(float) f.data[y * w + x] - 16;
			cb := cast(float) f.data[w * h + (y / 2) * w + (x & ~1)] - 128;
			cr := cast(float) f.data[w * h + (y / 2) * w + (x & ~1) + 1] - 128;
			r := ifx hd then 1.164 * Y + 1.793 * cr else 1.164 * Y + 1.596 * cr;
			g := ifx hd then 1.164 * Y - 0.213 * cb - 0.533 * cr else 1.164 * Y - 0.392 * cb - 0.813 * cr;
			b := ifx hd then 1.164 * Y + 2.112 * cb else 1.164 * Y + 2.017 * cb;
			append(*out, cast(u8) clamp(r, 0, 255));
			append(*out, cast(u8) clamp(g, 0, 255));
			append(*out, cast(u8) clamp(b, 0, 255));
		}
		write_entire_file("build/screen_linux.ppm", builder_to_string(*out));
		yuv.nv12_release(f);
	}
	exit(cast(s32) ifx frames > 0 then 0 else 1);
}
