// Time-stretch check: jai build.jai - run src/tests/stretch.jai, then build/stretch. Played faster or
// slower, a 440 Hz tone keeps its pitch, lasts its length over the rate and has no clicks.
#import "Basic";
#import "Math";
media :: #import "media";

failed := 0;

check :: (ok: bool, what: string) {
	if !ok { print("FAIL: %\n", what); failed += 1; }
}

main :: () {
	SR :: 48000;
	FRAMES :: SR * 4;
	tone: [..]float32;
	for i: 0..FRAMES - 1 {
		v := cast(float32) (0.5 * sin(TAU64 * 440 * i / SR));
		array_add(*tone, v, v);
	}
	for rate: float64.[0.5, 1.5, 2, 4] {
		s: media.Stretch;
		out: [..]float32;
		at := 0;
		while at < tone.count { // in decoder-sized chunks
			n := min(2048, tone.count - at);
			media.stretch(*s, array_view(tone, at, n), rate, *out);
			at += n;
		}
		frames := out.count / 2;
		f := cast(float64) frames;
		want := FRAMES / rate; // less what's held back for the next window
		short := (media.STRETCH_W + 2 * media.STRETCH_SEEK) / rate + media.STRETCH_HOP;
		check(f <= want && f > want - short, tprint("% x: % frames, want about %", rate, frames, want));
		// Past the first window's fade-in: count rising zero crossings for the pitch, and the largest step.
		crossings := 0;
		step: float32;
		for i: media.STRETCH_W..frames - 1 {
			a, b := out[2 * (i - 1)], out[2 * i];
			if a < 0 && b >= 0 crossings += 1;
			step = max(step, abs(b - a));
		}
		hz := crossings * cast(float64) SR / (frames - media.STRETCH_W);
		check(abs(hz - 440) < 440 * 0.02, tprint("% x plays at % Hz, want 440", rate, hz));
		check(step < 0.06, tprint("% x has a click (a step of %)", rate, step));
		print("% x: % frames, % Hz, largest step %\n", rate, frames, hz, step);
	}
	if failed { print("% failed\n", failed); exit(1); }
	print("stretch: ok\n");
}
