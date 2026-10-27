Verb :: enum u8 {
	Move;  // 1 point
	Line;  // 1 point
	Quad;  // 2 points
	Cubic; // 3 points
	Close; // 0 points
}

Fill_Rule :: enum u8 {
	Nonzero;
	Evenodd;
}

Line_Cap :: enum u8 {
	Butt;
	Round;
	Square;
}

Line_Join :: enum u8 {
	Miter;
	Round;
	Bevel;
}

Layer :: enum_flags u8 {
	Primary;
	Secondary; // class="secondary": Discord's secondaryColor shapes
}
Layers :: Layer;

Paint_Kind :: enum u8 {
	Fill;
	Stroke;
}

// Mat is a 2x3 affine: x' = m[0]*x + m[2]*y + m[4], y' = m[1]*x + m[3]*y + m[5].
Mat :: [6]float32;

MAT_IDENTITY :: float32.[1, 0, 0, 1, 0, 0];

// Op is one paint operation: a fill or a stroke of a path.
Op :: struct {
	kind: Paint_Kind;
	rule: Fill_Rule;
	layer: Layer;
	cap: Line_Cap;
	join: Line_Join;
	current_color: bool;  // paint was currentColor (else `color`)
	color: [4]u8; // RGBA of a fixed paint
	first_verb: s32;
	verb_count: s32;
	first_point: s32; // points are in the group's space (element transform applied)
	stroke_width: float32; // local units
	miter_limit: float32;
	alpha: float32; // opacity * fill-/stroke-opacity
	luminance: float32; // paint luminance * alpha basis, used when the op is mask content
	group: s32; // -1: drawn; else the mask/clip group this op belongs to
	mask: s32; // group index or -1
	clip: s32; // group index or -1
	ctm: Mat; // element transform (for the mask/clip of this op)
	bbox: [4]float32; // local (pre-ctm) bounds: min x, min y, max x, max y
	anc_mask: s32; // ancestor <g> mask / clip-path (group index or -1), in anc_ctm space
	anc_clip: s32;
	anc_ctm: Mat;
	gradient: s32; // index into Icon.gradients or -1
	grad_fold: float32; // average gradient alpha folded into `alpha` (undone by rasterize_rgba)
}

Group_Kind :: enum u8 {
	Mask;
	Clip;
}

Group :: struct {
	kind: Group_Kind;
	content_bbox_units: bool; // maskContentUnits / clipPathUnits = objectBoundingBox
	region_bbox_units: bool; // maskUnits = objectBoundingBox
	region: [4]float32; // mask region x, y, w, h
}

// Icon is a parsed, resolution-independent SVG.
Icon :: struct {
	view_box: [4]float32; // x, y, w, h
	verbs: [..]Verb;
	points: [..][2]float32;
	ops: [..]Op;
	groups: [..]Group;
	gradients: [..]Gradient; // stops owned by the icon's allocator
	multicolor: bool; // has fixed (non-currentColor) paints: brand / payment icons
	has_secondary: bool;
}

destroy :: (icon: *Icon) {
	delete(icon.verbs);
	delete(icon.points);
	delete(icon.ops);
	delete(icon.groups);
	for g: icon.gradients { delete(g.stops, icon.gradients.allocator); }
	delete(icon.gradients);
	icon.* = .{};
}
#scope_module

mat_mul :: (a: Mat, b: Mat) -> Mat {
	// a ∘ b: apply b first.
	return .[
		a[0] * b[0] + a[2] * b[1],
		a[1] * b[0] + a[3] * b[1],
		a[0] * b[2] + a[2] * b[3],
		a[1] * b[2] + a[3] * b[3],
		a[0] * b[4] + a[2] * b[5] + a[4],
		a[1] * b[4] + a[3] * b[5] + a[5]
	];
}

mat_apply :: (m: Mat, p: [2]float32) -> [2]float32 {
	return .[get(m, 0) * p.x + get(m, 2) * p.y + get(m, 4), get(m, 1) * p.x + get(m, 3) * p.y + get(m, 5)];
}
#scope_export

