// Package vector parses the SVG subset used by the official client's icons and
// rasterizes it to 8-bit coverage with exact-area anti-aliasing.
//
// Supported: <svg viewBox>, <g>, <path d> (M L H V C S Q T A Z, abs + rel),
// <rect rx ry>, <circle>, <ellipse>, <line>, <polyline>, <polygon>, <use href>,
// transform (matrix translate scale rotate skewX skewY), fill / stroke (paint,
// -opacity, -rule, -width, -linecap, -linejoin, -miterlimit), opacity, style="",
// <mask> (luminance, maskUnits / maskContentUnits) and <clipPath> (clip-rule,
// clipPathUnits). Gradients are treated as a flat color (average of stops).
//
// Icons are recolored at draw time, so the output is coverage only. Shapes with
// class="secondary" (Discord's secondaryColor slot, e.g. the dot behind
// circle-x) form a second layer that rasterize skips; see rasterize_layers.
//
// Rasterizer: curves are flattened in pixel space (0.01px tolerance), lines are
// accumulated as signed area + cover per cell (the font-rs / stb_truetype v2
// scheme), and a prefix sum per row yields the winding integral per pixel.
// Nonzero = min(|w|, 1); evenodd = triangle wave of w. Strokes are expanded to
// positively-oriented polygons (segment quads + joins + caps) filled nonzero.
package vector

Verb :: enum u8 {
	Move,  // 1 point
	Line,  // 1 point
	Quad,  // 2 points
	Cubic, // 3 points
	Close, // 0 points
}

Fill_Rule :: enum u8 {
	Nonzero,
	Evenodd,
}

Line_Cap :: enum u8 {
	Butt,
	Round,
	Square,
}

Line_Join :: enum u8 {
	Miter,
	Round,
	Bevel,
}

Layer :: enum u8 {
	Primary,
	Secondary, // class="secondary": Discord's secondaryColor shapes
}
Layers :: bit_set[Layer]

Paint_Kind :: enum u8 {
	Fill,
	Stroke,
}

// Mat is a 2x3 affine: x' = m[0]*x + m[2]*y + m[4], y' = m[1]*x + m[3]*y + m[5].
Mat :: [6]f32

MAT_IDENTITY :: Mat{1, 0, 0, 1, 0, 0}

// Op is one paint operation: a fill or a stroke of a path.
Op :: struct {
	kind:          Paint_Kind,
	rule:          Fill_Rule,
	layer:         Layer,
	cap:           Line_Cap,
	join:          Line_Join,
	current_color: bool,  // paint was currentColor (else `color`)
	color:         [4]u8, // RGBA of a fixed paint
	first_verb:    i32,
	verb_count:    i32,
	first_point:   i32, // points are in the group's space (element transform applied)
	stroke_width:  f32, // local units
	miter_limit:   f32,
	alpha:         f32, // opacity * fill-/stroke-opacity
	luminance:     f32, // paint luminance * alpha basis, used when the op is mask content
	group:         i32, // -1: drawn; else the mask/clip group this op belongs to
	mask:          i32, // group index or -1
	clip:          i32, // group index or -1
	ctm:           Mat, // element transform (for the mask/clip of this op)
	bbox:          [4]f32, // local (pre-ctm) bounds: min x, min y, max x, max y
}

Group_Kind :: enum u8 {
	Mask,
	Clip,
}

Group :: struct {
	kind:               Group_Kind,
	content_bbox_units: bool, // maskContentUnits / clipPathUnits = objectBoundingBox
	region_bbox_units:  bool, // maskUnits = objectBoundingBox
	region:             [4]f32, // mask region x, y, w, h
}

// Icon is a parsed, resolution-independent SVG.
Icon :: struct {
	view_box:      [4]f32, // x, y, w, h
	verbs:         [dynamic]Verb,
	points:        [dynamic][2]f32,
	ops:           [dynamic]Op,
	groups:        [dynamic]Group,
	multicolor:    bool, // has fixed (non-currentColor) paints: brand / payment icons
	has_secondary: bool,
}

destroy :: proc(icon: ^Icon) {
	delete(icon.verbs)
	delete(icon.points)
	delete(icon.ops)
	delete(icon.groups)
	icon^ = {}
}

@(private)
mat_mul :: proc(a, b: Mat) -> Mat {
	// a ∘ b: apply b first.
	return {
		a[0] * b[0] + a[2] * b[1],
		a[1] * b[0] + a[3] * b[1],
		a[0] * b[2] + a[2] * b[3],
		a[1] * b[2] + a[3] * b[3],
		a[0] * b[4] + a[2] * b[5] + a[4],
		a[1] * b[4] + a[3] * b[5] + a[5],
	}
}

@(private)
mat_apply :: proc(m: Mat, p: [2]f32) -> [2]f32 {
	return {m[0] * p.x + m[2] * p.y + m[4], m[1] * p.x + m[3] * p.y + m[5]}
}
