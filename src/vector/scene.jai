// Scene is a vector drawing recorded for the GPU: gfx.draw_scene renders it into a texture in one pass.
// Recording is plain CPU work (a decode worker builds it); nothing here touches the GPU.
//
// The GPU keeps a stack of layers per pixel: slot 0 is the output, slots 1..SCENE_SLOTS are nested
// layers (offscreen canvases) in tile memory. Instances run in order, each a quad (b, pixels) whose
// fragments read and write that pixel's whole stack:
//  - Fill: one SCENE_BAND-row band of a path. Its fragments sum the exact signed area of the band's
//    lines (segs) right of them: the path's coverage there, as the CPU rasterizer's cells give it. They
//    blend paint * coverage into the top layer (see Scene_Mode). Splitting into bands keeps each
//    fragment's loop to the lines that cross its rows.
//  - Composite: draws the top layer over the one below with an opacity, optionally through a matte
//    layer above it, and clears what it consumed.
//  - Mask_Apply: multiplies the layer below the top by the top layer's alpha, and clears the top.

Scene :: struct {
	w, h: int;
	insts: [..]Scene_Inst;
	segs: [..]Edge; // the lines Fill instances sum, band by band
	grads: [..]Scene_Grad;
	ramps: [..]u8; // SCENE_RAMP straight RGBA8 texels per gradient
	depth: s32; // layers open above the output
	over: s32; // layers opened past SCENE_SLOTS (drawn into the top one instead)
	overflow: bool; // there were some: the scene is wrong, the caller falls back
	edges: [..]Edge; // scratch
	bands: [..][..]Edge; // scratch
	allocator: Allocator; // every array above; the context's at the first scene_begin
}

SCENE_SLOTS :: 6;
SCENE_BAND :: 2;
SCENE_RAMP :: 256;
// Flattening tolerance (pixels) for scenes: 0.1 px is invisible and has a third of the edges of the
// CPU rasterizer's 0.01.
SCENE_TOLERANCE :: 0.1;

// 64 bytes, shared with the shaders: a, b, c, d as float4. b is always the quad (pixels x0 y0 x1 y1).
Scene_Inst :: struct {
	a: [4]float32; // Fill: straight RGB + opacity (masks: opacity, inverted). Composite: opacity, matte kind, matte opacity
	b: [4]float32;
	c: [4]float32; // kind, top slot, then Fill: rule + 2 * mode, gradient (-1 none)
	d: [4]float32; // Fill: first seg, seg count
}

Scene_Kind :: enum u8 {
	Fill;
	Composite;
	Mask_Apply;
}

// How a Fill blends value v (paint * coverage) into the layer's pixel d.
Scene_Mode :: enum u8 {
	Over;     // d = v + d * (1 - v.a)
	Multiply; // d *= coverage (clips: a precomp to its bounds)
	// Mask layers keep one value m in every channel; c = coverage * opacity, or 1 - that when inverted.
	Mask_Set;     // m = c
	Mask_Set_Sub; // m = 1 - c (a first mask that subtracts)
	Mask_Add;     // m = m + c - m * c
	Mask_Sub;     // m *= 1 - c
	Mask_Intersect; // m *= c
	Mask_Lighten; // m = max(m, c)
	Mask_Darken;  // m = min(m, c)
	Mask_Difference; // m = |m - c|
}

// Composite's matte: the source is multiplied by the matte layer's alpha or luma (times its opacity).
Scene_Matte :: enum u8 {
	None;
	Alpha;
	Alpha_Inverted;
	Luma;
	Luma_Inverted;
}

// 64 bytes, shared with the shaders as four float4.
Scene_Grad :: struct {
	inv: [6]float32; // pixel -> gradient space
	radial: float32;
	spread: float32; // Spread
	p0, p1: Vector2;
	r, fr: float32;
	pad: [2]float32;
}

scene_begin :: (s: *Scene, w: int, h: int) {
	if !s.allocator.proc  s.allocator = context.allocator;
	s.w, s.h = w, h;
	s.insts.count, s.segs.count, s.grads.count, s.ramps.count = 0, 0, 0, 0;
	s.depth, s.over = 0, 0;
	s.overflow = false;
}

scene_free :: (s: *Scene) {
	if !s.allocator.proc return; // never begun: nothing allocated
	push_allocator(s.allocator);
	array_free(s.insts);
	array_free(s.segs);
	array_free(s.grads);
	array_free(s.ramps);
	array_free(s.edges);
	for s.bands  array_free(it);
	array_free(s.bands);
	s.* = .{};
}

// A new transparent layer on top; draws go to it until a composite or mask apply consumes it.
scene_layer_begin :: (s: *Scene) {
	if s.depth < SCENE_SLOTS  s.depth += 1;
	else { s.over += 1; s.overflow = true; }
}

// Fills or strokes a path into the top layer (stroke: null fills with rule). quad_all covers the whole
// layer, for modes that change pixels the path doesn't cover (inverted masks, intersect, clips).
scene_path :: (s: *Scene, rz: *Rasterizer, verbs: []Verb, points: []Vector2, m: Mat, rule: Fill_Rule, stroke: *Stroke,
               mode: Scene_Mode, a: [4]float32, grad: s32 = -1, quad_all := false) {
	push_allocator(s.allocator);
	s.edges.count = 0;
	lo, hi: Vector2;
	ok: bool;
	tol := rz.tolerance;
	rz.tolerance = SCENE_TOLERANCE;
	if stroke  lo, hi, ok = stroke_edges(rz, verbs, points, m, stroke.*, *s.edges);
	else       lo, hi, ok = fill_edges(rz, verbs, points, m, *s.edges);
	rz.tolerance = tol;
	W, H := cast(float32) s.w, cast(float32) s.h;
	// pixels the path can cover: its bounds; left of it nothing, right of the canvas nothing drawn
	x0 := clamp(floor(lo.x), 0, W);
	y0 := clamp(floor(lo.y), 0, H);
	x1 := clamp(ceil(hi.x), 0, W);
	y1 := clamp(ceil(hi.y), 0, H);
	if !ok || x1 <= x0 || y1 <= y0 {
		if !quad_all return;
		ok = false;
		y0, y1 = 0, H;
	}
	if quad_all  x0, x1 = 0, W;
	// each band's lines; a line may be in several
	b0 := cast(int) y0 / SCENE_BAND;
	b1 := (cast(int) y1 + SCENE_BAND - 1) / SCENE_BAND;
	if quad_all  b0, b1 = 0, (s.h + SCENE_BAND - 1) / SCENE_BAND;
	if s.bands.count < b1  array_resize(*s.bands, b1);
	for b: b0..b1-1  s.bands[b].count = 0;
	if ok for e: s.edges {
		if min(e[0], e[2]) >= x1 continue; // right of every pixel drawn: adds nothing
		ey0 := min(e[1], e[3]);
		ey1 := max(e[1], e[3]);
		eb0 := max(cast(int) floor(ey0) / SCENE_BAND, b0);
		eb1 := min((cast(int) ceil(ey1) + SCENE_BAND - 1) / SCENE_BAND, b1);
		for b: eb0..eb1-1  array_add(*s.bands[b], e);
	}
	slot := cast(float32) s.depth;
	for b: b0..b1-1 {
		lines := s.bands[b];
		if !lines.count && !quad_all continue; // no coverage: nothing changes
		first := s.segs.count;
		array_add(*s.segs, ..lines);
		by0 := cast(float32) (b * SCENE_BAND);
		by1 := min(by0 + SCENE_BAND, H);
		q := float32.[x0, max(by0, ifx quad_all then 0 else y0), x1, min(by1, ifx quad_all then H else y1)];
		array_add(*s.insts, .{a = a, b = q, c = .[xx Scene_Kind.Fill, slot, cast(float32) rule + 2 * cast(float32) mode, xx grad], d = .[xx first, xx lines.count, 0, 0]});
	}
}

// A gradient for scene_path's grad: m maps gradient space to pixels.
scene_gradient :: (s: *Scene, g: *Gradient, m: Mat) -> s32 {
	push_allocator(s.allocator);
	inv, ok := mat_invert(m);
	if !ok || !g.stops.count return -1;
	array_add(*s.grads, .{inv = inv, radial = xx g.radial, spread = xx g.spread, p0 = g.p0, p1 = g.p1, r = g.r, fr = g.fr});
	for i: 0..SCENE_RAMP-1 {
		c := gradient_color(g, (cast(float32) i + 0.5) / SCENE_RAMP);
		for k: 0..3  array_add(*s.ramps, cast(u8) (clamp(c.component[k], 0, 1) * 255 + 0.5));
	}
	return cast(s32) s.grads.count - 1;
}

// Draws the top layer over the one below, times opacity, and pops it. With a matte, the top layer is
// the matte and the one below it the source; both are popped. Opacity 0 just discards.
scene_composite :: (s: *Scene, opacity: float32, matte_kind := Scene_Matte.None, matte_opacity: float32 = 1) {
	push_allocator(s.allocator);
	array_add(*s.insts, .{a = .[opacity, xx matte_kind, matte_opacity, 0], b = .[0, 0, xx s.w, xx s.h], c = .[xx Scene_Kind.Composite, xx s.depth, 0, 0]});
	pop_layers(s, ifx matte_kind == .None then 1 else 2);
}

// Multiplies the layer below the top by the top layer's alpha, and pops the top.
scene_mask_apply :: (s: *Scene) {
	push_allocator(s.allocator);
	array_add(*s.insts, .{b = .[0, 0, xx s.w, xx s.h], c = .[xx Scene_Kind.Mask_Apply, xx s.depth, 0, 0]});
	pop_layers(s, 1);
}

#scope_file

pop_layers :: (s: *Scene, n: int) {
	for 1..n {
		if s.over > 0  s.over -= 1;
		else if s.depth > 0  s.depth -= 1;
	}
}
