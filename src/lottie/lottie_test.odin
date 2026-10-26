package lottie

import "core:testing"
import "fc:imagefmt"

// testdata/synthetic.json (generated, no Discord assets) covers precomps with
// start offset, parenting through a null, spatial bezier position, hold +
// bezier easing, alpha track matte, add mask, linear + radial (highlight)
// gradients, trim paths with offset wrap-around, rect/ellipse/star, solid
// layer, layer opacity. lottie_web_64.png is the official client's lottie-web
// 5.12.2 (SVG renderer) drawing frames 0 7 15 20 26 33 41 52 at 64px.
@(private = "file")
SYN := #load("testdata/synthetic.json")
@(private = "file")
REF := #load("testdata/lottie_web_64.png")

@(test)
test_against_lottie_web :: proc(t: ^testing.T) {
	anim, err := load(SYN)
	testing.expect_value(t, err, Error.None)
	defer destroy(anim)
	ref, rerr := imagefmt.decode(REF)
	testing.expect_value(t, rerr, imagefmt.Error.None)
	defer imagefmt.image_destroy(&ref)
	frames := [8]f32{0, 7, 15, 20, 26, 33, 41, 52}
	p: Player
	testing.expect(t, player_init(&p, anim, 64, 64))
	defer player_destroy(&p)
	for f, c in frames {
		px := render(&p, f)
		sum := 0
		for y in 0 ..< 64 {
			for x in 0 ..< 64 {
				o := (y * ref.width + c * 64 + x) * 4
				for k in 0 ..< 4 {
					a := int(px[(y * 64 + x) * 4 + k]) * (k == 3 ? 255 : int(px[(y * 64 + x) * 4 + 3])) / 255
					b := int(ref.frames[0].pixels[o + k]) * (k == 3 ? 255 : int(ref.frames[0].pixels[o + 3])) / 255
					sum += abs(a - b)
				}
			}
		}
		mean := f64(sum) / (64 * 64 * 4)
		testing.expectf(t, mean < 1.0, "frame %v: mean abs diff %.3f/255 vs lottie-web", f, mean)
	}
}

@(test)
test_timing_and_errors :: proc(t: ^testing.T) {
	anim, _ := load(SYN)
	defer destroy(anim)
	testing.expect_value(t, anim.fr, f32(30))
	testing.expect_value(t, frame_at(anim, 0.5), f32(15))
	testing.expect_value(t, frame_at(anim, 2.5), f32(15)) // loops after op=60
	_, e := load(transmute([]byte)string("{not json"))
	testing.expect_value(t, e, Error.Bad_Json)
	// easing: linear handles, ease-in-out midpoint
	testing.expect(t, abs(bezier_ease(0, 0, 1, 1, 0.3) - 0.3) < 1e-5)
	testing.expect(t, abs(bezier_ease(0.42, 0, 0.58, 1, 0.5) - 0.5) < 1e-4)
}
