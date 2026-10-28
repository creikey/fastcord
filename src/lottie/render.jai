Mat :: vector.Mat;

// Player renders frames of any animation at a fixed pixel size. It must not move after player_init.
Player :: struct {
	w, h: int;
	anim: *Animation; // the frame being rendered
	view: Mat; // animation space -> pixels (xMidYMid meet)
	rz: vector.Rasterizer;
	frame: Flat_Pool; // per-frame geometry
	out: []u8; // last rendered frame, straight RGBA8
	depth: int; // precomp nesting guard
	free: [..]Canvas; // layer buffers, all zero
	mask: []float32; // apply_masks' scratch
	scene: *vector.Scene; // set while record runs: draws go to the scene's layers instead of buffers
}

player_init :: (p: *Player, w: int, h: int) {
	p.* = .{w = w, h = h};
	vector.rasterizer_init(*p.rz, w, h);
	p.out = NewArray(w * h * 4, u8);
	p.mask = NewArray(w * h, float32);
	p.free.allocator = context.allocator;
}

player_destroy :: (p: *Player) {
	vector.rasterizer_destroy(*p.rz);
	fini(*p.frame);
	array_free(p.out);
	array_free(p.mask);
	for p.free  array_free(it.px,, p.free.allocator);
	array_free(p.free);
	p.* = .{};
}

// frame_at maps seconds to a (looping, fractional) frame number.
frame_at :: (anim: *Animation, seconds: float64) -> float32 {
	dur := cast(float64) (anim.op - anim.ip);
	if dur <= 0 return anim.ip;
	f := fmod(seconds * cast(float64) anim.fr, dur);
	if f < 0  f += dur;
	return anim.ip + cast(float32) f;
}

// render renders frame number `frame` (fractional allowed) and returns the
// player's straight-alpha RGBA8 buffer (w*h*4, valid until the next call).
render :: (p: *Player, anim: *Animation, frame: float32) -> []u8 {
	p.anim = anim;
	s := min(cast(float32) p.w / anim.w, cast(float32) p.h / anim.h);
	p.view = .[s, 0, 0, s, (cast(float32) p.w - anim.w * s) / 2, (cast(float32) p.h - anim.h * s) / 2];
	vector.rasterizer_reset(*p.rz);
	reset(*p.frame);
	push_allocator(.{flat_pool_allocator_proc, *p.frame}); // all geometry below lives until the next frame
	canvas := take(p);
	render_comp(p, *anim.root, frame, p.view, *canvas);
	vector.premul_to_rgba8(canvas.px, p.out);
	give(p, canvas);
	return p.out;
}

// record is render for the GPU: it records frame `frame` into s (vector.Scene) instead of rasterizing.
// No pixel buffers are used; s gets the player's size. False when the layers nest deeper than a
// scene allows (vector.SCENE_SLOTS): render it instead.
record :: (p: *Player, anim: *Animation, frame: float32, s: *vector.Scene) -> bool {
	p.anim = anim;
	sc := min(cast(float32) p.w / anim.w, cast(float32) p.h / anim.h);
	p.view = .[sc, 0, 0, sc, (cast(float32) p.w - anim.w * sc) / 2, (cast(float32) p.h - anim.h * sc) / 2];
	vector.rasterizer_reset(*p.rz);
	reset(*p.frame);
	vector.scene_begin(s, p.w, p.h); // first: the scene keeps the caller's allocator
	push_allocator(.{flat_pool_allocator_proc, *p.frame});
	p.scene = s;
	defer p.scene = null;
	root := Canvas.{layer = 0};
	render_comp(p, *anim.root, frame, p.view, *root);
	return !s.overflow;
}

#scope_module

mat_mul :: vector.mat_mul;
apply :: vector.mat_apply;

ev1 :: (pr: *Prop, t: float32, def: float32 = 0) -> float32 {
	v: [4]float32;
	if eval(pr, t, v) < 1 return def;
	return v[0];
}

ev2 :: (pr: *Prop, t: float32, def := Vector2.{}) -> Vector2 {
	v: [4]float32;
	n := eval(pr, t, v);
	if n < 1 return def;
	if n < 2 return .{v[0], v[0]};
	return .{v[0], v[1]};
}

// Transform matrix (lottie-web order: translate(-a), scale, skew, rotate, translate(p)).
transform_matrix :: (tr: *Transform, t: float32) -> Mat, float32 {
	a := ev2(*tr.a, t);
	s := ev2(*tr.s, t, .{100, 100}) / 100;
	r := ev1(*tr.r, t) * PI / 180;
	pos := ifx tr.split then Vector2.{ev1(*tr.px, t), ev1(*tr.py, t)} else ev2(*tr.p, t);
	m: Mat = .[s.x, 0, 0, s.y, -a.x * s.x, -a.y * s.y];
	sk := ev1(*tr.sk, t);
	if sk != 0 {
		sa := ev1(*tr.sa, t) * PI / 180;
		c, sn := cos(sa), sin(sa);
		shear: Mat = .[1, 0, tan(-sk * PI / 180), 1, 0, 0];
		m = mat_mul(.[c, sn, -sn, c, 0, 0], mat_mul(shear, mat_mul(.[c, -sn, sn, c, 0, 0], m)));
	}
	c, sn := cos(r), sin(r);
	m = mat_mul(.[c, sn, -sn, c, pos.x, pos.y], m);
	return m, ev1(*tr.o, t, 100) / 100;
}

// Keyframe times are in the containing comp's time (lottie-web compares
// frame - st against kf.t - st), so layer properties use the comp frame; only a
// precomp's inner time is shifted/stretched.
precomp_time :: (l: *Layer, frame: float32) -> float32 {
	return (frame - l.st) / l.sr;
}

// World matrix of a layer within its comp (own transform composed with parents').
layer_world :: (c: *Comp, l: *Layer, frame: float32, depth := 0) -> Mat {
	m := transform_matrix(*l.ks, frame);
	if l.parent >= 0 && depth < 32 {
		for * pl: c.layers  if pl.ind == l.parent  return mat_mul(layer_world(c, pl, frame, depth + 1), m);
	}
	return m;
}

// A premultiplied RGBA f32 layer buffer, zero outside box; or, recording, a scene layer.
Canvas :: struct {
	px: []float32;
	box: vector.Box;
	layer: s32 = -1;
}

exists :: (c: Canvas) -> bool { return c.px.count > 0 || c.layer >= 0; }

take :: (p: *Player) -> Canvas {
	if p.scene {
		vector.scene_layer_begin(p.scene);
		return .{layer = p.scene.depth};
	}
	if p.free return pop(*p.free);
	return .{px = NewArray(p.w * p.h * 4, float32,, p.free.allocator)};
}

give :: (p: *Player, c: Canvas) {
	if p.scene return; // its layer ended when it was finished
	b := c.box;
	for y: b.y0..b.y1-1  memset(c.px.data + (y * p.w + b.x0) * 4, 0, (b.x1 - b.x0) * 4 * size_of(float32));
	array_add(*p.free, .{px = c.px});
}

// Fills or strokes (stroke != null) path into buf with color (straight RGBA), or gradient g mapped by gm.
paint :: (p: *Player, buf: *Canvas, path: *vector.Path, rule: vector.Fill_Rule, stroke: *vector.Stroke, color: Vector4, g: *vector.Gradient = null, gm := vector.MAT_IDENTITY) {
	if p.scene {
		grad: s32 = -1;
		if g {
			grad = vector.scene_gradient(p.scene, g, gm);
			if grad < 0 return;
		}
		vector.scene_path(p.scene, *p.rz, path.verbs, path.points, vector.MAT_IDENTITY, rule, stroke, .Over, color.component, grad);
		return;
	}
	cov: []float32;
	if stroke  cov = vector.stroke_coverage(*p.rz, path.verbs, path.points, vector.MAT_IDENTITY, stroke.*);
	else       cov = vector.fill_coverage(*p.rz, path.verbs, path.points, vector.MAT_IDENTITY, rule);
	if g {
		vector.gradient_fill_premul(g, gm, cov, buf.px, p.w, p.rz.cov_box);
		buf.box = vector.box_union(buf.box, p.rz.cov_box);
	} else {
		fill(p, buf, color, cov);
	}
}

// Composites cov * color (straight) into buf.
fill :: (p: *Player, buf: *Canvas, color: Vector4, cov: []float32) {
	vector.solid_fill_premul(color, cov, buf.px, p.w, p.rz.cov_box);
	buf.box = vector.box_union(buf.box, p.rz.cov_box);
}

composite :: (p: *Player, dst: *Canvas, src: *Canvas, alpha: float32) {
	dst.box = vector.box_union(dst.box, src.box);
	b := src.box;
	for y: b.y0..b.y1-1  for x: b.x0..b.x1-1 {
		o := (y * p.w + x) * 4;
		a := src.px[o + 3] * alpha;
		if a <= 0 continue;
		k := 1 - a;
		d, s := dst.px.data, src.px.data;
		d[o] = s[o] * alpha + d[o] * k;
		d[o + 1] = s[o + 1] * alpha + d[o + 1] * k;
		d[o + 2] = s[o + 2] * alpha + d[o + 2] * k;
		d[o + 3] = a + d[o + 3] * k;
	}
}

render_comp :: (p: *Player, c: *Comp, frame: float32, m: Mat, dst: *Canvas) {
	for < i: 0..c.layers.count-1 {
		l := *c.layers[i];
		if l.td || l.hidden || l.ty == 3 continue;
		if !(frame >= l.ip && frame < l.op) continue;
		matted := l.tt > 0 && i > 0 && c.layers[i - 1].td;
		buf, op := render_layer(p, c, l, frame, m, ifx matted then null else dst);
		if !exists(buf) continue;
		if matted {
			ml := *c.layers[i - 1];
			mask_buf: Canvas;
			mop: float32 = 1;
			if frame >= ml.ip && frame < ml.op  mask_buf, mop = render_layer(p, c, ml, frame, m);
			luma := l.tt == 3 || l.tt == 4;
			inv := l.tt == 2 || l.tt == 4;
			if p.scene {
				// no matte layer: matted by nothing (inverted: by everything)
				if exists(mask_buf)  vector.scene_composite(p.scene, op, xx l.tt, mop);
				else                 vector.scene_composite(p.scene, ifx inv then op else 0);
				continue;
			}
			mb := mask_buf.px;
			b := buf.box;
			for y: b.y0..b.y1-1  for x: b.x0..b.x1-1 {
				o := (y * p.w + x) * 4;
				f: float32 = 0;
				if mb.count {
					if luma  f = (0.2125 * mb[o] + 0.7154 * mb[o + 1] + 0.0721 * mb[o + 2]) * mop;
					else     f = mb[o + 3] * mop;
				}
				if inv  f = 1 - f;
				for k: 0..3  buf.px[o + k] *= f;
			}
			if mb.count  give(p, mask_buf);
		}
		if p.scene  vector.scene_composite(p.scene, op);
		else        composite(p, dst, *buf, op);
		give(p, buf);
	}
}

// The rectangle (0, 0)-(w, h) under m.
rect_path :: (w: float32, h: float32, m: Mat) -> *vector.Path {
	path := New(vector.Path);
	vector.path_move(path, apply(m, .{0, 0}));
	vector.path_line(path, apply(m, .{w, 0}));
	vector.path_line(path, apply(m, .{w, h}));
	vector.path_line(path, apply(m, .{0, h}));
	vector.path_close(path);
	return path;
}

rect_coverage :: (p: *Player, w: float32, h: float32, m: Mat) -> []float32 {
	path := rect_path(w, h, vector.MAT_IDENTITY);
	return vector.fill_coverage(*p.rz, path.verbs, path.points, m, .Nonzero);
}

// Multiplies the premultiplied RGBA buf by per-pixel coverage.
multiply :: (p: *Player, buf: *Canvas, cov: []float32) {
	b := buf.box;
	for y: b.y0..b.y1-1  for x: b.x0..b.x1-1 {
		i := y * p.w + x;
		for k: 0..3  buf.px[i * 4 + k] *= cov[i];
	}
}

// Renders one layer (content + masks) into a taken buffer (give it back); returns
// it with the layer opacity to composite with. Recording, a plain layer (opaque, no masks) is drawn
// straight into dst when given, since src-over composites associatively, and nothing is returned.
render_layer :: (p: *Player, c: *Comp, l: *Layer, frame: float32, m: Mat, dst: *Canvas = null) -> Canvas, float32 {
	_, opacity := transform_matrix(*l.ks, frame);
	if opacity <= 0 return .{}, 0;
	if l.ty != 0 && l.ty != 1 && l.ty != 4 return .{}, 0;
	if l.ty == 0 && (l.ref < 0 || p.depth > 16) return .{}, 0; // depth: self-referencing precomps
	lm := mat_mul(m, layer_world(c, l, frame));
	pc: *Comp;
	pw, ph: float32;
	if l.ty == 0 {
		pc = *p.anim.assets[l.ref];
		pw, ph = ifx l.w > 0 then l.w else pc.w, ifx l.h > 0 then l.h else pc.h;
	}
	// a precomp's clip to its bounds is a no-op when they hold the whole canvas
	direct := p.scene && dst && opacity >= 1 && !l.masks.count && (l.ty != 0 || covers_canvas(p, pw, ph, lm));
	buf: Canvas;
	if !direct  buf = take(p);
	into := ifx direct then dst else *buf;
	if l.ty == {
	case 0;
		p.depth += 1;
		render_comp(p, pc, precomp_time(l, frame), lm, into);
		p.depth -= 1;
		// precomps are clipped to their bounds
		w, h := pw, ph;
		if p.scene {
			if !direct && !covers_canvas(p, w, h, lm) {
				r := rect_path(w, h, lm);
				vector.scene_path(p.scene, *p.rz, r.verbs, r.points, vector.MAT_IDENTITY, .Nonzero, null, .Multiply, .[1, 1, 1, 1], quad_all = true);
			}
		} else {
			multiply(p, *buf, rect_coverage(p, w, h, lm));
		}
	case 1;
		paint(p, into, rect_path(l.w, l.h, lm), .Nonzero, null, l.solid_color);
	case 4;
		draw_shapes(p, l.shapes, frame, lm, into);
	}
	if l.masks.count  apply_masks(p, l, frame, lm, *buf);
	if direct return .{}, 0;
	return buf, opacity;
}

// Whether the rectangle (0, 0)-(w, h) under m contains the whole canvas (so clipping to it is a no-op).
covers_canvas :: (p: *Player, w: float32, h: float32, m: Mat) -> bool {
	if m[1] != 0 || m[2] != 0 return false;
	a, b := apply(m, .{0, 0}), apply(m, .{w, h});
	return min(a.x, b.x) <= 0 && min(a.y, b.y) <= 0 && max(a.x, b.x) >= xx p.w && max(a.y, b.y) >= xx p.h;
}

mask_mode :: (m: u8, first: bool) -> vector.Scene_Mode {
	if first  return ifx m == #char "s" then .Mask_Set_Sub else .Mask_Set;
	if m == {
		case #char "s"; return .Mask_Sub;
		case #char "i"; return .Mask_Intersect;
		case #char "l"; return .Mask_Lighten;
		case #char "d"; return .Mask_Darken;
		case #char "f"; return .Mask_Difference;
	}
	return .Mask_Add;
}

// Only buf's box matters: it is zero elsewhere.
apply_masks :: (p: *Player, l: *Layer, t: float32, lm: Mat, buf: *Canvas) {
	if p.scene {
		any := false;
		for l.masks  if it.mode != #char "n"  any = true;
		if !any return;
		vector.scene_layer_begin(p.scene);
		first := true;
		for * mk: l.masks {
			if mk.mode == #char "n" continue;
			path := shape_to_path(eval_shape(*mk.path, t), false);
			mode := mask_mode(mk.mode, first);
			o := ev1(*mk.opacity, t, 100) / 100;
			vector.scene_path(p.scene, *p.rz, path.verbs, path.points, lm, .Nonzero, null, mode, .[o, xx mk.inverted, 0, 0], quad_all = true);
			first = false;
		}
		vector.scene_mask_apply(p.scene);
		return;
	}
	acc := p.mask;
	b := buf.box;
	first := true;
	for * mk: l.masks {
		if mk.mode == #char "n" continue;
		path := shape_to_path(eval_shape(*mk.path, t), false);
		cov := vector.fill_coverage(*p.rz, path.verbs, path.points, lm, .Nonzero);
		o := ev1(*mk.opacity, t, 100) / 100;
		for y: b.y0..b.y1-1  for x: b.x0..b.x1-1 {
			i := y * p.w + x;
			c := cov[i] * o;
			if mk.inverted  c = 1 - c;
			v := *acc[i];
			if first {
				v.* = ifx mk.mode == #char "s" then 1 - c else c;
				continue;
			}
			if mk.mode == {
				case #char "a"; v.* = v.* + c - v.* * c;
				case #char "s"; v.* *= 1 - c;
				case #char "i"; v.* *= c;
				case #char "l"; v.* = max(v.*, c);
				case #char "d"; v.* = min(v.*, c);
				case #char "f"; v.* = abs(v.* - c);
			}
		}
		first = false;
	}
	if !first  multiply(p, buf, acc);
}

// ---------------------------------------------------------------------------
// Shape items

// A path slot: trims replace slot.path in place, so (as in lottie-web, where
// modifiers rewrite the shared shape data) they also affect styles listed
// above the trim.
Slot :: struct {
	path: *vector.Path;
}

Draw :: struct {
	item: *Item;
	paths: []*Slot; // pixel space
	m: Mat; // the style's group matrix (gradients, stroke width)
	opacity: float32;
}

// Lottie bezier vertices -> path in local space (reversed if requested).
shape_to_path :: (sd: Shape_Data, reversed: bool, m := vector.MAT_IDENTITY) -> *vector.Path {
	path := New(vector.Path);
	n := sd.v.count;
	if n == 0 return path;
	idx :: (j: int, n: int, rev: bool) -> int { return ifx rev then (n - j % n) % n else j % n; }
	vector.path_move(path, apply(m, sd.v[idx(0, n, reversed)]));
	segs := ifx sd.closed then n else n - 1;
	for k: 0..segs-1 {
		a := idx(k, n, reversed);
		b := idx(k + 1, n, reversed);
		out_t := ifx reversed then sd.i[a] else sd.o[a];
		in_t := ifx reversed then sd.o[b] else sd.i[b];
		p0 := sd.v[a];
		p3 := sd.v[b];
		if out_t == .{} && in_t == .{}  vector.path_line(path, apply(m, p3));
		else vector.path_cubic(path, apply(m, p0 + out_t), apply(m, p3 + in_t), apply(m, p3));
	}
	if sd.closed  vector.path_close(path);
	return path;
}

KAPPA :: 0.5519150244935105707435627;

build_primitive :: (item: *Item, t: float32, m: Mat) -> *vector.Path {
	sd: Shape_Data;
	sd.closed = true;
	alloc_vertices :: (sd: *Shape_Data, n: int) {
		sd.v = NewArray(n, Vector2);
		sd.i = NewArray(n, Vector2);
		sd.o = NewArray(n, Vector2);
	}
	if item.kind == {
	case .Ellipse;
		c := ev2(*item.p, t);
		s := ev2(*item.size, t) / 2;
		k := s * cast(float32) KAPPA;
		alloc_vertices(*sd, 4);
		// lottie-web: top, right, bottom, left (clockwise)
		sd.v[0], sd.i[0], sd.o[0] = .{c.x, c.y - s.y}, .{-k.x, 0}, .{k.x, 0};
		sd.v[1], sd.i[1], sd.o[1] = .{c.x + s.x, c.y}, .{0, -k.y}, .{0, k.y};
		sd.v[2], sd.i[2], sd.o[2] = .{c.x, c.y + s.y}, .{k.x, 0}, .{-k.x, 0};
		sd.v[3], sd.i[3], sd.o[3] = .{c.x - s.x, c.y}, .{0, k.y}, .{0, -k.y};
	case .Rect;
		c := ev2(*item.p, t);
		hs := ev2(*item.size, t) / 2;
		r := min(ev1(*item.r, t), hs.x, hs.y);
		if r <= 0 {
			alloc_vertices(*sd, 4);
			// lottie-web starts at the top-right corner
			sd.v[0] = .{c.x + hs.x, c.y - hs.y};
			sd.v[1] = .{c.x + hs.x, c.y + hs.y};
			sd.v[2] = .{c.x - hs.x, c.y + hs.y};
			sd.v[3] = .{c.x - hs.x, c.y - hs.y};
		} else {
			k := r * cast(float32) (1 - KAPPA);
			x0, x1, y0, y1 := c.x - hs.x, c.x + hs.x, c.y - hs.y, c.y + hs.y;
			alloc_vertices(*sd, 8);
			pts := Vector2.[.{x1, y0 + r}, .{x1, y1 - r}, .{x1 - r, y1}, .{x0 + r, y1}, .{x0, y1 - r}, .{x0, y0 + r}, .{x0 + r, y0}, .{x1 - r, y0}];
			for pts  sd.v[it_index] = it;
			cr := r - k;
			sd.o[1] = .{0, cr};  sd.i[2] = .{cr, 0};
			sd.o[3] = .{-cr, 0}; sd.i[4] = .{0, cr};
			sd.o[5] = .{0, -cr}; sd.i[6] = .{-cr, 0};
			sd.o[7] = .{cr, 0};  sd.i[0] = .{0, -cr};
		}
	case .Star;
		c := ev2(*item.p, t);
		pts := ev1(*item.pt, t);
		if !(pts >= 2) return New(vector.Path); // also rejects NaN
		n := cast(int) min(pts, 1000);
		rot := ev1(*item.r, t) * PI / 180;
		or_ := ev1(*item.or_, t);
		ir := ev1(*item.ir, t);
		star := item.star_type == 1;
		cnt := ifx star then 2 * n else n;
		alloc_vertices(*sd, cnt);
		for j: 0..cnt-1 {
			rr := ifx star && (j & 1) == 1 then ir else or_;
			ang := rot - PI / 2 + cast(float32) j * 2 * PI / cast(float32) cnt;
			sd.v[j] = c + rr * Vector2.{cos(ang), sin(ang)};
		}
	}
	return shape_to_path(sd, item.reversed, m);
}

// Walks a group's items top to bottom: paths accumulate in `geo`, groups add
// their (transformed) geometry, trims rewrite geo, styles snapshot geo.
walk_items :: (items: []Item, t: float32, m: Mat, opacity: float32, geo: *[..]*Slot, draws: *[..]Draw) {
	new_slot :: (path: *vector.Path) -> *Slot {
		sl := New(Slot);
		sl.path = path;
		return sl;
	}
	for * item: items {
		if item.hidden continue;
		if item.kind == {
		case .Ignore;
		case .Group;
			gm := m;
			go := opacity;
			if item.has_tr {
				tm, o := transform_matrix(*item.tr, t);
				gm = mat_mul(m, tm);
				go *= o;
			}
			sub: [..]*Slot;
			walk_items(item.items, t, gm, go, *sub, draws);
			array_add(geo, ..sub);
		case .Path;
			array_add(geo, new_slot(shape_to_path(eval_shape(*item.shape, t), item.reversed, m)));
		case .Rect; #through; case .Ellipse; #through; case .Star;
			array_add(geo, new_slot(build_primitive(item, t, m)));
		case .Fill; #through; case .Stroke; #through; case .Gradient_Fill; #through; case .Gradient_Stroke;
			array_add(draws, Draw.{item = item, paths = array_copy(geo.*), m = m, opacity = opacity});
		case .Trim;
			apply_trim(item, t, geo);
		}
	}
}

draw_shapes :: (p: *Player, items: []Item, t: float32, m: Mat, buf: *Canvas) {
	geo: [..]*Slot;
	draws: [..]Draw;
	walk_items(items, t, m, 1, *geo, *draws);
	// the first style in document order is on top
	for < * d: draws {
		item := d.item;
		op := ev1(*item.opacity, t, 100) / 100 * d.opacity;
		if op <= 0 || d.paths.count == 0 continue;
		// merge the snapshot into one path so overlapping sub-paths fill once
		merged: vector.Path;
		for d.paths {
			array_add(*merged.verbs, ..it.path.verbs);
			array_add(*merged.points, ..it.path.points);
		}
		if merged.verbs.count == 0 continue;
		stroke: vector.Stroke;
		st: *vector.Stroke;
		if item.kind == .Stroke || item.kind == .Gradient_Stroke {
			w := ev1(*item.width, t);
			if w <= 0 continue;
			scale := sqrt(abs(d.m[0] * d.m[3] - d.m[1] * d.m[2]));
			cap := ifx item.cap == 1 then vector.Line_Cap.Butt else ifx item.cap == 3 then vector.Line_Cap.Square else .Round;
			join := ifx item.join == 1 then vector.Line_Join.Miter else ifx item.join == 3 then vector.Line_Join.Bevel else .Round;
			stroke = .{width = w * scale, cap = cap, join = join, miter_limit = item.miter};
			st = *stroke;
		}
		rule := ifx item.evenodd && !st then vector.Fill_Rule.Evenodd else .Nonzero;
		if item.kind == .Fill || item.kind == .Stroke {
			c := Vector4.{0, 0, 0, 1};
			eval(*item.color, t, c.component);
			c[3] = op;
			paint(p, buf, *merged, rule, st, c);
		} else {
			g := build_gradient(item, t, op);
			paint(p, buf, *merged, rule, st, .{1, 1, 1, 1}, *g, d.m);
		}
	}
}

build_gradient :: (it: *Item, t: float32, opacity: float32) -> vector.Gradient {
	g := vector.Gradient.{radial = it.grad_type == 2, transform = vector.MAT_IDENTITY};
	vals: [256]float32;
	n := eval(*it.g_colors, t, vals);
	cnt := clamp(it.g_count, 0, n / 4);
	g.stops = NewArray(cnt, vector.Gradient_Stop);
	nop := (n - cnt * 4) / 2; // opacity stops follow the colour stops
	ob := cnt * 4;
	for * stop, k: g.stops {
		off := vals[k * 4];
		stop.* = .{off, .{vals[k * 4 + 1], vals[k * 4 + 2], vals[k * 4 + 3], 1}};
		if nop > 0 {
			// opacity at this offset (linear between opacity stops)
			a := vals[ob + 1];
			for q: 0..nop-1 {
				o0, a0 := vals[ob + q * 2], vals[ob + q * 2 + 1];
				if off <= o0 {
					if q == 0 {
						a = a0;
					} else {
						o1, a1 := vals[ob + q * 2 - 2], vals[ob + q * 2 - 1];
						f := ifx o0 > o1 then (off - o1) / (o0 - o1) else 0;
						a = a1 + (a0 - a1) * f;
					}
					break;
				}
				a = a0;
			}
			stop.color[3] = a;
		}
		stop.color[3] *= opacity;
	}
	s := ev2(*it.g_start, t);
	e := ev2(*it.g_end, t);
	if !g.radial {
		g.p0, g.p1 = s, e;
	} else {
		r := sqrt((e.x - s.x) * (e.x - s.x) + (e.y - s.y) * (e.y - s.y));
		hl := clamp(ev1(*it.g_hl, t) / 100, -0.99, 0.99);
		ha := ev1(*it.g_ha, t) * PI / 180;
		base := atan2(e.y - s.y, e.x - s.x);
		g.p0 = s;
		g.r = r;
		g.p1 = s + r * hl * Vector2.{cos(base + ha), sin(base + ha)};
	}
	return g;
}

// ---------------------------------------------------------------------------
// Trim paths

Seg :: struct {
	p: [4]Vector2;
	l: float32;
}

cubic_at :: (s: [4]Vector2, t: float32) -> Vector2 {
	m := 1 - t;
	return m * m * m * s[0] + 3 * m * m * t * s[1] + 3 * m * t * t * s[2] + t * t * t * s[3];
}

cubic_len :: (s: [4]Vector2) -> float32 {
	N :: 24;
	l: float32;
	prev := s[0];
	for i: 1..N {
		q := cubic_at(s, cast(float32) i / N);
		d := q - prev;
		l += sqrt(d.x * d.x + d.y * d.y);
		prev = q;
	}
	return l;
}

// parameter u where the arc length from 0 reaches `target` (by sampling)
cubic_param :: (s: [4]Vector2, target: float32) -> float32 {
	N :: 48;
	l: float32;
	prev := s[0];
	for i: 1..N {
		q := cubic_at(s, cast(float32) i / N);
		d := q - prev;
		dl := sqrt(d.x * d.x + d.y * d.y);
		if l + dl >= target {
			f := ifx dl > 0 then (target - l) / dl else 0;
			return (cast(float32) (i - 1) + f) / N;
		}
		l += dl;
		prev = q;
	}
	return 1;
}

// de Casteljau: the part [u0, u1] of s.
split_cubic :: (s: [4]Vector2, u0: float32, u1: float32) -> [4]Vector2 {
	halves :: (s: [4]Vector2, t: float32) -> [4]Vector2, [4]Vector2 {
		a := s[0] + (s[1] - s[0]) * t;
		b := s[1] + (s[2] - s[1]) * t;
		c := s[2] + (s[3] - s[2]) * t;
		d := a + (b - a) * t;
		e := b + (c - b) * t;
		f := d + (e - d) * t;
		return .[s[0], a, d, f], .[f, e, c, s[3]];
	}
	_, r := halves(s, u0);
	if u0 >= 1 return .[s[3], s[3], s[3], s[3]];
	l := halves(r, clamp((u1 - u0) / (1 - u0), 0, 1));
	return l;
}

// The path's contours as cubic segments with their lengths.
path_segments :: (path: *vector.Path) -> [..][..]Seg {
	out: [..][..]Seg;
	pi := 0;
	cur, start: Vector2;
	segs: *[..]Seg;
	line :: (a: Vector2, b: Vector2) -> Seg { return .{p = .[a, a + (b - a) / 3, a + (b - a) * 2 / 3, b]}; }
	for v: path.verbs {
		if v == {
		case .Move;
			cur = path.points[pi];
			start = cur;
			pi += 1;
			segs = array_add(*out);
		case .Line;
			q := path.points[pi];
			pi += 1;
			if segs  array_add(segs, line(cur, q));
			cur = q;
		case .Quad;
			c, q := path.points[pi], path.points[pi + 1];
			pi += 2;
			if segs  array_add(segs, .{p = .[cur, cur + (c - cur) * 2 / 3, q + (c - q) * 2 / 3, q]});
			cur = q;
		case .Cubic;
			if segs  array_add(segs, .{p = .[cur, path.points[pi], path.points[pi + 1], path.points[pi + 2]]});
			cur = path.points[pi + 2];
			pi += 3;
		case .Close;
			if segs && cur != start  array_add(segs, line(cur, start));
			cur = start;
		}
	}
	for * sl: out  for * sl.*  it.l = cubic_len(it.p);
	return out;
}

contours_length :: (cs: [][..]Seg) -> float32 {
	total: float32;
	for c: cs  for c  total += it.l;
	return total;
}

// Emits the arc-length range [a, b] of the contour list (as one continuous run).
emit_range :: (dst: *vector.Path, contours: [][..]Seg, a: float32, b: float32) {
	pos: float32;
	for sl: contours {
		started := false;
		for s: sl {
			s0, s1 := pos, pos + s.l;
			pos = s1;
			lo := max(a, s0);
			hi := min(b, s1);
			if hi < lo || s.l <= 0 continue;
			piece := split_cubic(s.p, cubic_param(s.p, lo - s0), cubic_param(s.p, hi - s0));
			if !started {
				vector.path_move(dst, piece[0]);
				started = true;
			}
			vector.path_cubic(dst, piece[1], piece[2], piece[3]);
		}
	}
}

apply_trim :: (item: *Item, t: float32, geo: *[..]*Slot) {
	s := ev1(*item.t_start, t) / 100;
	e := ev1(*item.t_end, t, 100) / 100;
	o := ev1(*item.t_off, t) / 360;
	if s > e  s, e = e, s;
	s += o;
	e += o;
	if e - s >= 1 return; // full
	if e - s <= 0 {
		for geo.*  it.path = New(vector.Path);
		return;
	}
	k := floor(s);
	s -= k;
	e -= k;
	// keep [a, b] (absolute lengths) of a contour list whose run is [base, base + length] of the total
	keep :: (cs: [][..]Seg, base: float32, length: float32, a: float32, b: float32, dst: *vector.Path) {
		lo := max(a, base);
		hi := min(b, base + length);
		if hi > lo  emit_range(dst, cs, lo - base, hi - base);
	}
	// keeps [s, e] of total, wrapping past 1 to the start
	trim :: (cs: [][..]Seg, base: float32, length: float32, total: float32, s: float32, e: float32) -> *vector.Path {
		dst := New(vector.Path);
		keep(cs, base, length, s * total, min(e, 1) * total, dst);
		if e > 1  keep(cs, base, length, 0, (e - 1) * total, dst);
		return dst;
	}
	if item.t_mode == 2 {
		// individually: the paths form one sequence
		segs := NewArray(geo.count, [..][..]Seg);
		lens := NewArray(geo.count, float32);
		total: float32;
		for geo.* {
			segs[it_index] = path_segments(it.path);
			lens[it_index] = contours_length(segs[it_index]);
			total += lens[it_index];
		}
		base: float32;
		for geo.* {
			it.path = trim(segs[it_index], base, lens[it_index], total, s, e);
			base += lens[it_index];
		}
		return;
	}
	for geo.* {
		cs := path_segments(it.path);
		total := contours_length(cs);
		it.path = trim(cs, 0, total, total, s, e);
	}
}
