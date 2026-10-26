package opus

import "core:math"
import "core:math/rand"
import "core:testing"

@(private = "file")
run_frames :: proc(gen: proc(i: int) -> f32, frames: int) -> Analysis_Info {
	st := new(Tonality_Analysis_State)
	defer free(st)
	tonality_analysis_init(st, 48000)
	pcm: [960]f32
	info: Analysis_Info
	for f in 0 ..< frames {
		for i in 0 ..< 960 do pcm[i] = gen(f * 960 + i)
		run_analysis(st, pcm[:], 960, 960, 0, -2, 1, 48000, 24, &info)
	}
	return info
}

@(test)
test_analysis_sine_vs_noise :: proc(t: ^testing.T) {
	sine := run_frames(proc(i: int) -> f32 {return 0.3 * math.sin(2 * math.PI * 1000 * f32(i) / 48000)}, 50)
	noise := run_frames(proc(i: int) -> f32 {return 0.3 * (rand.float32() * 2 - 1)}, 50)
	testing.expect(t, sine.valid && noise.valid)
	testing.expectf(t, sine.tonality > 0.5 && sine.tonality > noise.tonality + 0.3, "sine tonality %v", sine.tonality)
	testing.expectf(t, noise.tonality < 0.3, "noise tonality %v", noise.tonality)
	testing.expectf(t, noise.bandwidth == 20, "noise bandwidth %v", noise.bandwidth)
}

@(test)
test_analysis_silence :: proc(t: ^testing.T) {
	// Digital silence never produces a valid analysis (previous info is copied).
	info := run_frames(proc(i: int) -> f32 {return 0}, 20)
	testing.expect(t, !info.valid)
}
