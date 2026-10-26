package vector

import "core:fmt"
import "core:log"
import "core:math"
import "core:testing"

@(private)
coverage_sum :: proc(c: []u8) -> f64 {
	s := 0
	for v in c do s += int(v)
	return f64(s) / 255
}

@(private)
render :: proc(t: ^testing.T, svg: string, w, h: int, layers := Layers{.Primary}) -> []u8 {
	icon, ok := parse_svg(svg)
	testing.expect(t, ok, "parse failed")
	defer destroy(&icon)
	return rasterize_layers(&icon, w, h, layers)
}

@(test)
test_square_exact :: proc(t: ^testing.T) {
	// Pixel-aligned grid with fractional edges: exact area, exact edge pixels.
	c := render(t, `<svg viewBox="0 0 10 10"><rect x="2.3" y="1.7" width="5.1" height="4.4"/></svg>`, 10, 10)
	defer delete(c)
	testing.expectf(t, abs(coverage_sum(c) - 5.1 * 4.4) < 0.2, "area %v", coverage_sum(c))
	testing.expect_value(t, c[3 * 10 + 4], 255) // interior
	near :: proc(v: u8, want: f64) -> bool {return abs(f64(v) - want * 255) <= 1}
	testing.expect(t, near(c[3 * 10 + 2], 0.7)) // left edge column covers 0.7
	testing.expect(t, near(c[1 * 10 + 4], 0.3)) // top edge row covers 0.3
	testing.expect(t, near(c[1 * 10 + 2], 0.21)) // corner 0.7 * 0.3
	testing.expect_value(t, c[0], 0)
}

@(test)
test_circle_area :: proc(t: ^testing.T) {
	c := render(t, `<svg viewBox="0 0 10 10"><circle cx="5.13" cy="4.91" r="4.2"/></svg>`, 100, 100)
	defer delete(c)
	want := math.PI * 42 * 42
	got := coverage_sum(c)
	testing.expectf(t, abs(got - want) / want < 0.001, "circle %v want %v", got, want)
	// Arc commands: same circle as two half arcs.
	c2 := render(t, `<svg viewBox="0 0 10 10"><path d="M0.93 4.91a4.2 4.2 0 1 0 8.4 0A4.2 4.2 0 1 0 .93 4.91z"/></svg>`, 100, 100)
	defer delete(c2)
	testing.expectf(t, abs(coverage_sum(c2) - want) / want < 0.001, "arc circle %v", coverage_sum(c2))
}

@(test)
test_fill_rules :: proc(t: ^testing.T) {
	ring := `M1 1h8v8H1zM3 3h4v4H3z` // both subpaths clockwise
	ev := render(t, fmt.tprintf(`<svg viewBox="0 0 10 10"><path fill-rule="evenodd" d="%s"/></svg>`, ring), 10, 10)
	nz := render(t, fmt.tprintf(`<svg viewBox="0 0 10 10"><path d="%s"/></svg>`, ring), 10, 10)
	defer delete(ev)
	defer delete(nz)
	testing.expectf(t, abs(coverage_sum(ev) - 48) < 0.01, "evenodd %v", coverage_sum(ev))
	testing.expectf(t, abs(coverage_sum(nz) - 64) < 0.01, "nonzero %v", coverage_sum(nz))
	testing.expect_value(t, ev[5 * 10 + 5], 0)
	// Opposite winding hole works under nonzero too.
	hole := render(t, `<svg viewBox="0 0 10 10"><path d="M1 1h8v8H1zM3 3v4h4V3z"/></svg>`, 10, 10)
	defer delete(hole)
	testing.expectf(t, abs(coverage_sum(hole) - 48) < 0.01, "nonzero hole %v", coverage_sum(hole))
}

@(test)
test_relative_and_smooth :: proc(t: ^testing.T) {
	abs_d := `M2 12C2 6 8 2 12 2S22 6 22 12Q22 18 17 20T12 22H4V12Z`
	rel_d := `m2 12c0-6 6-10 10-10s10 4 10 10q0 6-5 8t-5 2h-8v-10z`
	a := render(t, fmt.tprintf(`<svg viewBox="0 0 24 24"><path d="%s"/></svg>`, abs_d), 48, 48)
	b := render(t, fmt.tprintf(`<svg viewBox="0 0 24 24"><path d="%s"/></svg>`, rel_d), 48, 48)
	defer delete(a)
	defer delete(b)
	maxd := 0
	for i in 0 ..< len(a) do maxd = max(maxd, abs(int(a[i]) - int(b[i])))
	testing.expectf(t, maxd <= 1, "abs vs rel max diff %d", maxd)
	// Compact number syntax: "1.5.5" = 1.5 0.5, "-.5-1" = -0.5 -1, exponents.
	c := render(t, `<svg viewBox="0 0 10 10"><path d="M1 1h4e0v.4e1H1z"/></svg>`, 10, 10)
	defer delete(c)
	testing.expectf(t, abs(coverage_sum(c) - 16) < 0.01, "compact %v", coverage_sum(c))
}

@(test)
test_transform :: proc(t: ^testing.T) {
	c := render(t, `<svg viewBox="0 0 20 20"><g transform="translate(10 10)"><rect transform="rotate(45) scale(2 1)" x="-3" y="-3" width="3" height="6"/></g></svg>`, 80, 80)
	defer delete(c)
	want := 6.0 * 6 * 16 // 6x6 user units, 4px per unit
	testing.expectf(t, abs(coverage_sum(c) - want) / want < 0.002, "rotated %v want %v", coverage_sum(c), want)
}

@(test)
test_strokes :: proc(t: ^testing.T) {
	area :: proc(t: ^testing.T, attrs: string) -> f64 {
		c := render(t, fmt.tprintf(`<svg viewBox="0 0 10 10"><path fill="none" stroke="#000" stroke-width="2" %s d="M2 5H8"/></svg>`, attrs), 100, 100)
		defer delete(c)
		return coverage_sum(c) / 100
	}
	butt := area(t, "")
	square := area(t, `stroke-linecap="square"`)
	round := area(t, `stroke-linecap="round"`)
	testing.expectf(t, abs(butt - 12) < 0.01, "butt %v", butt)
	testing.expectf(t, abs(square - 16) < 0.01, "square %v", square)
	testing.expectf(t, abs(round - (12 + math.PI)) < 0.02, "round %v", round)
	// Closed square outline, miter joins: outer 8x8 minus inner 4x4.
	c := render(t, `<svg viewBox="0 0 10 10"><rect x="2" y="2" width="6" height="6" fill="none" stroke="black" stroke-width="2"/></svg>`, 100, 100)
	defer delete(c)
	testing.expectf(t, abs(coverage_sum(c) / 100 - 48) < 0.02, "rect outline %v", coverage_sum(c) / 100)
}

@(test)
test_mask_and_opacity :: proc(t: ^testing.T) {
	// White half / black half mask over a full rect.
	c := render(t, `<svg viewBox="0 0 10 10"><mask id="m" maskUnits="userSpaceOnUse" x="0" y="0" width="10" height="10"><rect width="10" height="10" fill="white"/><rect width="5" height="10" fill="black"/></mask><rect width="10" height="10" fill="currentColor" mask="url(#m)"/></svg>`, 10, 10)
	defer delete(c)
	testing.expectf(t, abs(coverage_sum(c) - 50) < 0.01, "mask %v", coverage_sum(c))
	// Status idle: unit circle minus offset circle, objectBoundingBox content units.
	idle := render(t, `<svg viewBox="0 0 1 1"><mask id="i" maskContentUnits="objectBoundingBox"><circle fill="white" cx="0.5" cy="0.5" r="0.5"/><circle fill="black" cx="0.25" cy="0.25" r="0.375"/></mask><rect width="1" height="1" mask="url(#i)"/></svg>`, 200, 200)
	defer delete(idle)
	// Lens area of circles r1=.5, r2=.375, distance d=.25*sqrt2.
	r1, r2, d := 0.5, 0.375, 0.25 * math.SQRT_TWO
	a1 := r1 * r1 * math.acos((d * d + r1 * r1 - r2 * r2) / (2 * d * r1))
	a2 := r2 * r2 * math.acos((d * d + r2 * r2 - r1 * r1) / (2 * d * r2))
	a3 := 0.5 * math.sqrt((-d + r1 + r2) * (d + r1 - r2) * (d - r1 + r2) * (d + r1 + r2))
	want := (math.PI * r1 * r1 - (a1 + a2 - a3)) * 200 * 200
	testing.expectf(t, abs(coverage_sum(idle) - want) / want < 0.003, "idle %v want %v", coverage_sum(idle), want)
	// fill-opacity and group opacity multiply.
	o := render(t, `<svg viewBox="0 0 10 10"><g opacity="0.5"><rect width="10" height="10" fill-opacity="0.5"/></g></svg>`, 10, 10)
	defer delete(o)
	testing.expectf(t, abs(coverage_sum(o) - 25) < 0.5, "opacity %v", coverage_sum(o))
}

@(test)
test_clip_and_secondary :: proc(t: ^testing.T) {
	c := render(t, `<svg viewBox="0 0 10 10"><clipPath id="c"><rect x="0" y="0" width="10" height="3"/></clipPath><rect width="10" height="10" clip-path="url(#c)"/></svg>`, 10, 10)
	defer delete(c)
	testing.expectf(t, abs(coverage_sum(c) - 30) < 0.01, "clip %v", coverage_sum(c))
	svg := `<svg viewBox="0 0 10 10"><rect width="5" height="10" fill="currentColor" class="secondary"/><rect x="5" width="5" height="10" fill="currentColor"/></svg>`
	p := render(t, svg, 10, 10)
	both := render(t, svg, 10, 10, {.Primary, .Secondary})
	defer delete(p)
	defer delete(both)
	testing.expect(t, abs(coverage_sum(p) - 50) < 0.01 && abs(coverage_sum(both) - 100) < 0.01)
}

@(test)
test_offscreen_geometry :: proc(t: ^testing.T) {
	// Shapes crossing every edge of the bitmap: only the visible part counts.
	c := render(t, `<svg viewBox="0 0 10 10"><rect x="-5" y="-5" width="8" height="20"/><circle cx="10" cy="5" r="3"/></svg>`, 10, 10)
	defer delete(c)
	want := 3.0 * 10 + math.PI * 9 / 2
	testing.expectf(t, abs(coverage_sum(c) - want) < 0.1, "offscreen %v want %v", coverage_sum(c), want)
}

@(private)
diff_stats :: proc(got, ref: []u8) -> (mean: f64, maxd: int, dcov: f64) {
	sum := 0
	for i in 0 ..< len(got) {
		d := abs(int(got[i]) - int(ref[i]))
		sum += d
		maxd = max(maxd, d)
	}
	mean = f64(sum) / f64(len(got))
	dcov = (coverage_sum(got) - coverage_sum(ref)) / max(coverage_sum(ref), 1)
	return
}

// Geometry check: our exact-area output vs Chrome's render supersampled 8x8 / 16x16
// (Chrome's SVG interpretation of every path, arc, mask, transform and stroke).
@(test)
test_against_chrome_supersampled :: proc(t: ^testing.T) {
	worst: f64
	for fx in CHROME_FIXTURES {
		icon, ok := parse_svg(fx.svg)
		if !testing.expectf(t, ok, "%s: parse", fx.name) do continue
		for size in ([2]int{48, 24}) {
			ref := size == 48 ? fx.ss48 : fx.ss24
			got := rasterize_layers(&icon, size, size, {.Primary, .Secondary})
			mean, maxd, dcov := diff_stats(got, ref)
			worst = max(worst, mean)
			log.debugf("%-28s ss%2d mean %.3f max %3d coverage %+.4f", fx.name, size, mean, maxd, dcov)
			// The synthetic fixtures overlap separate shapes (composited per shape, as a
			// browser does, but the supersampled reference resolves the exact union) and
			// stroke a curve tighter than its half width (overlap slivers on edge pixels).
			max_allowed := fx.name == "stroke_shapes" || fx.name == "misc_shapes" ? 128 : 16
			testing.expectf(t, mean < 0.75, "%s %dpx: mean abs diff %.3f", fx.name, size, mean)
			testing.expectf(t, maxd <= max_allowed, "%s %dpx: max diff %d", fx.name, size, maxd)
			testing.expectf(t, abs(dcov) < 0.01, "%s %dpx: coverage differs by %.4f", fx.name, size, dcov)
			delete(got)
		}
		destroy(&icon)
	}
	log.infof("vs Chrome supersampled: %d svgs at 48 and 24px, worst mean abs diff %.3f/255", len(CHROME_FIXTURES), worst)
}

// Chrome's direct (Skia) 48px render is not exact-area (thin diagonals gain or lose
// several % of coverage), so this only bounds the visible difference.
@(test)
test_against_chrome_direct :: proc(t: ^testing.T) {
	worst: f64
	for fx in CHROME_FIXTURES {
		icon, ok := parse_svg(fx.svg)
		if !testing.expectf(t, ok, "%s: parse", fx.name) do continue
		got := rasterize_layers(&icon, 48, 48, {.Primary, .Secondary})
		mean, maxd, dcov := diff_stats(got, fx.a48)
		worst = max(worst, mean)
		log.debugf("%-28s 48 mean %.3f max %3d coverage %+.4f", fx.name, mean, maxd, dcov)
		testing.expectf(t, mean < 6, "%s: mean abs diff %.3f", fx.name, mean)
		delete(got)
		destroy(&icon)
	}
	log.infof("vs Chrome direct 48px: worst mean abs diff %.3f/255", worst)
}
