package vector

import "core:testing"
import "fc:imagefmt"

// Colour rendering vs headless Chrome drawing the same SVG in an <img> at 72px
// (tools/probes/chrome_color_fixtures.sh): gradients, spread, focal radial,
// href inheritance, <g clip-path>, transformed clip paths, opacity.
@(private = "file")
COLOR_FIXTURES := [?]struct {
	name:   string,
	svg:    string,
	chrome: []byte,
} {
	{"lin", #load("testdata/color/lin.svg", string), #load("testdata/color/lin.chrome72.png")},
	{"rad", #load("testdata/color/rad.svg", string), #load("testdata/color/rad.chrome72.png")},
	{"clip", #load("testdata/color/clip.svg", string), #load("testdata/color/clip.chrome72.png")},
	{"emojiish", #load("testdata/color/emojiish.svg", string), #load("testdata/color/emojiish.chrome72.png")},
}

@(test)
test_rgba_against_chrome :: proc(t: ^testing.T) {
	for f in COLOR_FIXTURES {
		icon, ok := parse_svg(f.svg)
		testing.expect(t, ok)
		defer destroy(&icon)
		mine := rasterize_rgba(&icon, 72, 72)
		defer delete(mine)
		ref, err := imagefmt.decode(f.chrome)
		defer imagefmt.image_destroy(&ref)
		testing.expect_value(t, err, imagefmt.Error.None)
		px := ref.frames[0].pixels
		sum := 0
		for i in 0 ..< 72 * 72 {
			for c in 0 ..< 4 {
				// premultiplied comparison (colour of invisible pixels is irrelevant)
				a := int(mine[i * 4 + c]) * (c == 3 ? 255 : int(mine[i * 4 + 3])) / 255
				b := int(px[i * 4 + c]) * (c == 3 ? 255 : int(px[i * 4 + 3])) / 255
				sum += abs(a - b)
			}
		}
		mean := f64(sum) / (72 * 72 * 4)
		testing.expectf(t, mean < 1.5, "%s: mean abs diff %.3f/255 vs Chrome", f.name, mean)
	}
}

@(test)
test_gradient_math :: proc(t: ^testing.T) {
	stops := []Gradient_Stop{{0, {1, 0, 0, 1}}, {1, {0, 0, 1, 1}}}
	g := Gradient{p0 = {0, 0}, p1 = {10, 0}, stops = stops, transform = MAT_IDENTITY}
	tv, ok := gradient_t(&g, {5, 3})
	testing.expect(t, ok && abs(tv - 0.5) < 1e-5)
	g.spread = .Reflect
	c := gradient_color(&g, 1.25)
	testing.expect(t, abs(c[0] - 0.25) < 1e-5) // reflected back to t=0.75
	r := Gradient{radial = true, p0 = {0, 0}, p1 = {0, 0}, r = 10, stops = stops, transform = MAT_IDENTITY}
	tr, rok := gradient_t(&r, {6, 8})
	testing.expect(t, rok && abs(tr - 1) < 1e-5)
}
