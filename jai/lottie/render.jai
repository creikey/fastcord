Mat :: vector.Mat;

// Player renders frames of one animation at a fixed pixel size.
Player :: struct {
	anim: *Animation;
	w, h: int;
	view: Mat; // animation space -> pixels (xMidYMid meet)
	rz: vector.Rasterizer;
	frame: virtual.Arena; // per-frame geometry
	falloc: Allocator;
	out: []u8; // last rendered frame, straight RGBA8
	depth: int; // precomp nesting guard
}

player_init :: (p: *Player, anim: *Animation, w: int, h: int, allocator := context.allocator) -> bool {
	p.* = .{anim = anim, w = w, h = h};
	if !vector.rasterizer_init(*p.rz, w, h) { return false; }
	if virtual.arena_init_growing(*p.frame) != null { return false; }
	p.falloc = virtual.arena_allocator(*p.frame);
	s := min(cast(float32)(w) / anim.w, cast(float32)(h) / anim.h);
	p.view = .{s, 0, 0, s, (cast(float32)(w) - anim.w * s) / 2, (cast(float32)(h) - anim.h * s) / 2};
	p.out = make_slice(u8, w * h * 4, allocator);
	return true;
}

player_destroy :: (p: *Player, allocator := context.allocator) {
	vector.rasterizer_destroy(*p.rz);
	virtual.arena_destroy(*p.frame);
	delete(p.out, allocator);
	p.* = .{};
}

// frame_at maps seconds to a (looping, fractional) frame number.
frame_at :: (anim: *Animation, seconds: float64) -> float32 {
	dur := cast(float64)(anim.op - anim.ip);
	if dur <= 0 { return anim.ip; }
	f := math.mod(seconds * cast(float64)(anim.fr), dur);
	if f < 0 { f += dur; }
	return anim.ip + cast(float32)(f);
}

// render renders frame number `frame` (fractional allowed) and returns the
// player's straight-alpha RGBA8 buffer (w*h*4, valid until the next call).
render :: (p: *Player, frame: float32) -> []u8 {
	vector.rasterizer_reset(*p.rz);
	virtual.arena_free_all(*p.frame);
	canvas := vector.rasterizer_buffer(*p.rz, 4);
	render_comp(p, *p.anim.root, frame, p.view, canvas);
	vector.premul_to_rgba8(canvas, p.out);
	return p.out;
}
#scope_module

// ---------------------------------------------------------------------------

mat_mul :: (a: Mat, b: Mat) -> Mat {
	return .{
		a[0] * b[0] + a[2] * b[1],
		a[1] * b[0] + a[3] * b[1],
		a[0] * b[2] + a[2] * b[3],
		a[1] * b[2] + a[3] * b[3],
		a[0] * b[4] + a[2] * b[5] + a[4],
		a[1] * b[4] + a[3] * b[5] + a[5]
	};
}

apply :: inline (m: Mat, p: [2]float32) -> [2]float32 {
	return .{get(m, 0) * p.x + get(m, 2) * p.y + get(m, 4), get(m, 1) * p.x + get(m, 3) * p.y + get(m, 5)};
};

ev1 :: (pr: *Prop, t: float32, def: float32 = 0) -> float32 {
	v: [4]float32;
	if eval(pr, t, view(v)) < 1 { return def; }
	return v[0];
}

ev2 :: (pr: *Prop, t: float32, def: [2]float32 = .{}) -> [2]float32 {
	v: [4]float32;
	n := eval(pr, t, view(v));
	if n < 1 { return def; }
	if n < 2 { return .{v[0], v[0]}; }
	return .{v[0], v[1]};
}

// Transform matrix (lottie-web order: translate(-a), scale, skew, rotate, translate(p)).
transform_matrix :: (tr: *Transform, t: float32) -> Mat, float32 {
	a := ev2(*tr.a, t);
	s := ev2(*tr.s, t, .{100, 100}) / 100;
	r := ev1(*tr.r, t) * math.PI / 180;
	pos: [2]float32;
	if tr.split {
		pos = .{ev1(*tr.px, t), ev1(*tr.py, t)};
	} else {
		pos = ev2(*tr.p, t);
	}
	m := float32.[s.x, 0, 0, s.y, -a.x * s.x, -a.y * s.y];
	sk := ev1(*tr.sk, t);
	if sk != 0 {
		sa := ev1(*tr.sa, t) * math.PI / 180;
		k := math.tan(-sk * math.PI / 180);
		c, sn := math.cos(sa), math.sin(sa);
		rot := float32.[c, sn, -sn, c, 0, 0];
		rinv := float32.[c, -sn, sn, c, 0, 0];
		shear := float32.[1, 0, k, 1, 0, 0];
		m = mat_mul(rot, mat_mul(shear, mat_mul(rinv, m)));
	}
	c, sn := math.cos(r), math.sin(r);
	m = mat_mul(float32.[c, sn, -sn, c, pos.x, pos.y], m);
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
	m, _ := transform_matrix(*l.ks, frame);
	if l.parent >= 0 && depth < 32 {
		for * pl: c.layers {
			if pl.ind == l.parent {
				return mat_mul(layer_world(c, *pl, frame, depth + 1), m);
			}
		}
	}
	return m;
}

composite :: (dst: []float32, src: []float32, alpha: float32) {
	{ i := 0;
	while i < len(dst) {
		a := src[i + 3] * alpha;
		if a <= 0 { { i += 4; continue; } }
		k := 1 - a;
		dst[i] = src[i] * alpha + dst[i] * k;
		dst[i + 1] = src[i + 1] * alpha + dst[i + 1] * k;
		dst[i + 2] = src[i + 2] * alpha + dst[i + 2] * k;
		dst[i + 3] = a + dst[i + 3] * k;
		i += 4;
} }
}

render_comp :: (p: *Player, c: *Comp, frame: float32, m: Mat, dst: []float32) {
	for < i: len(c.layers) - 1..0 {
		l := *c.layers[i];
		if l.td || l.hidden || l.ty == 3 { continue; }
		if !(frame >= l.ip && frame < l.op) { continue; }
		buf, op := render_layer(p, c, l, frame, m);
		if buf == null { continue; }
		if l.tt > 0 && i > 0 && c.layers[i - 1].td {
			ml := *c.layers[i - 1];
			mask_buf: []float32;
			mop: float32 = 1;
			if frame >= ml.ip && frame < ml.op { mask_buf, mop = render_layer(p, c, ml, frame, m); }
			luma := l.tt == 3 || l.tt == 4;
			inv := l.tt == 2 || l.tt == 4;
			{ j := 0;
			while j < len(buf) {
				f: float32 = 0;
				if mask_buf != null {
					if luma {
						f = (0.2125 * mask_buf[j] + 0.7154 * mask_buf[j + 1] + 0.0721 * mask_buf[j + 2]) * mop;
					} else {
						f = mask_buf[j + 3] * mop;
					}
				}
				if inv { f = 1 - f; }
				buf[j] *= f;
				buf[j + 1] *= f;
				buf[j + 2] *= f;
				buf[j + 3] *= f;
				j += 4;
} }
		}
		composite(dst, buf, op);
	}
}

// Renders one layer (content + masks) into a new premultiplied buffer; returns
// it with the layer opacity to composite with.
render_layer :: (p: *Player, c: *Comp, l: *Layer, frame: float32, m: Mat) -> []float32, float32 {
	lt := frame;
	_, opacity := transform_matrix(*l.ks, lt);
	if opacity <= 0 { return .{}, 0; }
	lm := mat_mul(m, layer_world(c, l, frame));
	buf := vector.rasterizer_buffer(*p.rz, 4);
	if l.ty == {
	case 0;
		if l.ref < 0 { return .{}, 0; }
		pc := at(*p.anim.assets, l.ref);
		if p.depth > 16 { return .{}, 0; } // self-referencing precomps
		p.depth += 1;
		render_comp(p, pc, precomp_time(l, frame), lm, buf);
		p.depth -= 1;
		// precomps are clipped to their bounds
		w := ifx l.w > 0 then l.w else pc.w;
		h := ifx l.h > 0 then l.h else pc.h;
		path: vector.Path;
		path.verbs = make_dynamic(vector.Verb, 0, 0, p.falloc);
		path.points = make_dynamic([2]float32, 0, 0, p.falloc);
		vector.path_move(*path, .{0, 0});
		vector.path_line(*path, .{w, 0});
		vector.path_line(*path, .{w, h});
		vector.path_line(*path, .{0, h});
		vector.path_close(*path);
		cov := vector.fill_coverage(*p.rz, view(path.verbs), view(path.points), lm, .Nonzero);
		for v, j: cov { for k: 0..3 { buf[j * 4 + k] *= v; } }
	case 1;
		path: vector.Path;
		path.verbs = make_dynamic(vector.Verb, 0, 0, p.falloc);
		path.points = make_dynamic([2]float32, 0, 0, p.falloc);
		vector.path_move(*path, .{0, 0});
		vector.path_line(*path, .{l.w, 0});
		vector.path_line(*path, .{l.w, l.h});
		vector.path_line(*path, .{0, l.h});
		vector.path_close(*path);
		cov := vector.fill_coverage(*p.rz, view(path.verbs), view(path.points), lm, .Nonzero);
		vector.solid_fill_premul(l.solid_color, cov, buf);
	case 4;
		draw_shapes(p, l.shapes, lt, lm, buf);
	case;
		return .{}, 0;
	}
	if len(l.masks) > 0 { apply_masks(p, l, lt, lm, buf); }
	return buf, opacity;
}

apply_masks :: (p: *Player, l: *Layer, t: float32, lm: Mat, buf: []float32) {
	acc: []float32;
	for * mk: l.masks {
		if mk.mode == #char "n" { continue; }
		sd := eval_shape(*mk.path, t, p.falloc);
		path := shape_to_path(p, sd, false);
		cov := vector.fill_coverage(*p.rz, view(path.verbs), view(path.points), lm, .Nonzero);
		o := ev1(*mk.opacity, t, 100) / 100;
		for * v: cov {
			v *= o;
			if mk.inverted { v = 1 - v; }
		}
		if acc == null {
			acc = vector.rasterizer_buffer(*p.rz, 1);
			if mk.mode == #char "s" {
				for * v, j: acc { v = 1 - cov[j]; }
			} else {
				copy(acc, cov);
			}
			continue;
		}
		for * v, j: acc {
			c := cov[j];
			if mk.mode == #char "a" {
				v = v + c - v * c;
			} else if mk.mode == #char "s" {
				v *= 1 - c;
			} else if mk.mode == #char "i" {
				v *= c;
			} else if mk.mode == #char "l" {
				v = max(v, c);
			} else if mk.mode == #char "d" {
				v = min(v, c);
			} else if mk.mode == #char "f" {
				v = abs(v - c);
			}
		}
	}
	if acc == null { return; }
	for v, j: acc { for k: 0..3 { buf[j * 4 + k] *= v; } }
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

new_path :: (p: *Player) -> *vector.Path {
	path := new(vector.Path, p.falloc);
	path.verbs = make_dynamic(vector.Verb, 0, 0, p.falloc);
	path.points = make_dynamic([2]float32, 0, 0, p.falloc);
	return path;
}

// Lottie bezier vertices -> path in local space (reversed if requested).
shape_to_path :: (p: *Player, sd: Shape_Data, reversed: bool, m: Mat = vector.MAT_IDENTITY) -> *vector.Path {
	path := new_path(p);
	n := len(sd.v);
	if n == 0 { return path; }
	idx :: inline (j: int, n: int, rev: bool) -> int {return ifx rev then (n - j % n) % n else j % n;};
	vector.path_move(path, apply(m, sd.v[idx(0, n, reversed)]));
	segs := ifx sd.closed then n else n - 1;
	for k: 0..segs-1 {
		a := idx(k, n, reversed);
		b := idx(k + 1, n, reversed);
		out_t := ifx reversed then sd.i[a] else sd.o[a];
		in_t := ifx reversed then sd.o[b] else sd.i[b];
		p0 := sd.v[a];
		p3 := sd.v[b];
		if out_t == .{} && in_t == .{} {
			vector.path_line(path, apply(m, p3));
		} else {
			vector.path_cubic(path, apply(m, p0 + out_t), apply(m, p3 + in_t), apply(m, p3));
		}
	}
	if sd.closed { vector.path_close(path); }
	return path;
}

KAPPA :: 0.5519150244935105707435627;

build_primitive :: (p: *Player, it_: *Item, t: float32, m: Mat) -> *vector.Path {
	sd: Shape_Data;
	sd.closed = true;
	if it_.kind == {
	case .Ellipse;
		c := ev2(*it_.p, t);
		s := ev2(*it_.size, t) / 2;
		k := s * KAPPA;
		sd.v = make_slice([2]float32, 4, p.falloc);
		sd.i = make_slice([2]float32, 4, p.falloc);
		sd.o = make_slice([2]float32, 4, p.falloc);
		// lottie-web: top, right, bottom, left (clockwise)
		sd.v[0], sd.i[0], sd.o[0] = .{c.x, c.y - s.y}, .{-k.x, 0}, .{k.x, 0};
		sd.v[1], sd.i[1], sd.o[1] = .{c.x + s.x, c.y}, .{0, -k.y}, .{0, k.y};
		sd.v[2], sd.i[2], sd.o[2] = .{c.x, c.y + s.y}, .{k.x, 0}, .{-k.x, 0};
		sd.v[3], sd.i[3], sd.o[3] = .{c.x - s.x, c.y}, .{0, k.y}, .{0, -k.y};
	case .Rect;
		c := ev2(*it_.p, t);
		hs := ev2(*it_.size, t) / 2;
		r := min(ev1(*it_.r, t), hs.x, hs.y);
		if r <= 0 {
			sd.v = make_slice([2]float32, 4, p.falloc);
			sd.i = make_slice([2]float32, 4, p.falloc);
			sd.o = make_slice([2]float32, 4, p.falloc);
			// lottie-web starts at the top-right corner
			sd.v[0] = .{c.x + hs.x, c.y - hs.y};
			sd.v[1] = .{c.x + hs.x, c.y + hs.y};
			sd.v[2] = .{c.x - hs.x, c.y + hs.y};
			sd.v[3] = .{c.x - hs.x, c.y - hs.y};
		} else {
			k := r * (1 - KAPPA);
			x0, x1, y0, y1 := c.x - hs.x, c.x + hs.x, c.y - hs.y, c.y + hs.y;
			sd.v = make_slice([2]float32, 8, p.falloc);
			sd.i = make_slice([2]float32, 8, p.falloc);
			sd.o = make_slice([2]float32, 8, p.falloc);
			pts := [2]float32.[.[x1, y0 + r], .[x1, y1 - r], .[x1 - r, y1], .[x0 + r, y1], .[x0, y1 - r], .[x0, y0 + r], .[x0 + r, y0], .[x1 - r, y0]];
			for q, j: pts { sd.v[j] = q; }
			cr := r - k;
			sd.o[1] = .{0, cr};sd.i[2] = .{cr, 0};
			sd.o[3] = .{-cr, 0};sd.i[4] = .{0, cr};
			sd.o[5] = .{0, -cr};sd.i[6] = .{-cr, 0};
			sd.o[7] = .{cr, 0};sd.i[0] = .{0, -cr};
		}
	case .Star;
		c := ev2(*it_.p, t);
		pts := ev1(*it_.pt, t);
		if !(pts >= 2) { return new_path(p); } // also rejects NaN
		n := cast(int)(min(pts, 1000));
		rot := ev1(*it_.r, t) * math.PI / 180;
		or_ := ev1(*it_.or_, t);
		ir := ev1(*it_.ir, t);
		star := it_.star_type == 1;
		cnt := ifx star then 2 * n else n;
		sd.v = make_slice([2]float32, cnt, p.falloc);
		sd.i = make_slice([2]float32, cnt, p.falloc);
		sd.o = make_slice([2]float32, cnt, p.falloc);
		for j: 0..cnt-1 {
			rr := ifx star then (ifx j & 1 == 0 then or_ else ir) else or_;
			ang := rot - math.PI / 2 + cast(float32)(j) * 2 * math.PI / cast(float32)(cnt);
			sd.v[j] = c + rr * float32.[math.cos(ang), math.sin(ang)];
		}
	}
	return shape_to_path(p, sd, it_.reversed, m);
}

// Walks a group's items top to bottom: paths accumulate in `geo`, groups add
// their (transformed) geometry, trims rewrite geo, styles snapshot geo.
walk_items :: (p: *Player, items: []Item, t: float32, m: Mat, opacity: float32, geo: *[..]*Slot, draws: *[..]Draw) {
	for * it_: items {
		if it_.hidden { continue; }
		if it_.kind == {
		case .Ignore;
		case .Group;
			gm := m;
			go := opacity;
			if it_.has_tr {
				tm, o := transform_matrix(*it_.tr, t);
				gm = mat_mul(m, tm);
				go *= o;
			}
			sub := make_dynamic(*Slot, 0, 0, p.falloc);
			walk_items(p, it_.items, t, gm, go, *sub, draws);
			append(geo, ..view(sub));
		case .Path;
			sd := eval_shape(*it_.shape, t, p.falloc);
			append(geo, new_slot(p, shape_to_path(p, sd, it_.reversed, m)));
		case .Rect; #through; case .Ellipse; #through; case .Star;
			append(geo, new_slot(p, build_primitive(p, *it_, t, m)));
		case .Fill; #through; case .Stroke; #through; case .Gradient_Fill; #through; case .Gradient_Stroke;
			snap := make_slice(*Slot, len(geo), p.falloc);
			copy(snap, view(geo));
			append(draws, Draw.{item = *it_, paths = snap, m = m, opacity = opacity});
		case .Trim;
			apply_trim(p, *it_, t, geo);
		}
	}
}

new_slot :: (p: *Player, path: *vector.Path) -> *Slot {
	sl := new(Slot, p.falloc);
	sl.path = path;
	return sl;
}

draw_shapes :: (p: *Player, items: []Item, t: float32, m: Mat, buf: []float32) {
	geo := make_dynamic(*Slot, 0, 0, p.falloc);
	draws := make_dynamic(Draw, 0, 0, p.falloc);
	walk_items(p, items, t, m, 1, *geo, *draws);
	// the first style in document order is on top
	for < k: len(draws) - 1..0 {
		d := *draws[k];
		it_ := d.item;
		op := ev1(*it_.opacity, t, 100) / 100 * d.opacity;
		if op <= 0 || len(d.paths) == 0 { continue; }
		// merge the snapshot into one path so overlapping sub-paths fill once
		merged := new_path(p);
		for sl: d.paths {
			append(*merged.verbs, ..view(sl.path.verbs));
			append(*merged.points, ..view(sl.path.points));
		}
		if len(merged.verbs) == 0 { continue; }
		cov: []float32;
		if it_.kind == .Fill || it_.kind == .Gradient_Fill {
			cov = vector.fill_coverage(*p.rz, view(merged.verbs), view(merged.points), vector.MAT_IDENTITY, ifx it_.evenodd then .Evenodd else .Nonzero);
		} else {
			w := ev1(*it_.width, t);
			if w <= 0 { continue; }
			scale := math.sqrt(abs(get(d.m, 0) * get(d.m, 3) - get(d.m, 1) * get(d.m, 2)));
			cap := ifx it_.cap == 1 then vector.Line_Cap.Butt else ifx it_.cap == 3 then vector.Line_Cap.Square else vector.Line_Cap.Round;
			join := ifx it_.join == 1 then vector.Line_Join.Miter else ifx it_.join == 3 then vector.Line_Join.Bevel else vector.Line_Join.Round;
			cov = vector.stroke_coverage(*p.rz, view(merged.verbs), view(merged.points), vector.MAT_IDENTITY, .{width = w * scale, cap = cap, join = join, miter_limit = it_.miter});
		}
		if it_.kind == .Fill || it_.kind == .Stroke {
			c: [4]float32 = .{0, 0, 0, 1};
			eval(*it_.color, t, view(c));
			c[3] = op;
			vector.solid_fill_premul(c, cov, buf);
		} else {
			g := build_gradient(p, it_, t, op);
			vector.gradient_fill_premul(*g, d.m, cov, buf, p.w, p.h);
		}
	}
}

build_gradient :: (p: *Player, it_: *Item, t: float32, opacity: float32) -> vector.Gradient {
	g := vector.Gradient.{
		radial = it_.grad_type == 2,
		transform = vector.MAT_IDENTITY
	};
	vals: [256]float32;
	n := eval(*it_.g_colors, t, view(vals));
	cnt := clamp(it_.g_count, 0, n / 4);
	stops := make_slice(vector.Gradient_Stop, cnt, p.falloc);
	nop := (n - cnt * 4) / 2; // opacity stops follow the colour stops
	for k: 0..cnt-1 {
		off := get(vals, k * 4);
		stops[k] = .{off, .{get(vals, k * 4 + 1), get(vals, k * 4 + 2), get(vals, k * 4 + 3), 1}};
		if nop > 0 {
			// opacity at this offset (linear between opacity stops)
			ob := cnt * 4;
			a := get(vals, ob + 1);
			for q: 0..nop-1 {
				o0, a0 := map_find(vals|ob + q * 2), __MAPIDX__(vals, ob + q * 2 + 1);
				if off <= o0 {
					if q == 0 {
						a = a0;
					} else {
						o1, a1 := map_find(vals|ob + q * 2 - 2), __MAPIDX__(vals, ob + q * 2 - 1);
						f := ifx o0 > o1 then (off - o1) / (o0 - o1) else 0;
						a = a1 + (a0 - a1) * f;
					}
					break;
				}
				a = a0;
			}
			stops[k].color[3] = a;
		}
		stops[k].color[3] *= opacity;
	}
	g.stops = stops;
	s := ev2(*it_.g_start, t);
	e := ev2(*it_.g_end, t);
	if !g.radial {
		g.p0, g.p1 = s, e;
	} else {
		r := math.sqrt((e.x - s.x) * (e.x - s.x) + (e.y - s.y) * (e.y - s.y));
		hl := clamp(ev1(*it_.g_hl, t) / 100, -0.99, 0.99);
		ha := ev1(*it_.g_ha, t) * math.PI / 180;
		base := math.atan2(e.y - s.y, e.x - s.x);
		g.p0 = s;
		g.r = r;
		g.p1 = s + r * hl * float32.[math.cos(base + ha), math.sin(base + ha)];
	}
	return g;
}

// ---------------------------------------------------------------------------
// Trim paths

Seg :: struct {
	p: [4][2]float32;
	l: float32;
}

cubic_len :: (s: [4][2]float32) -> float32 {
	N :: 24;
	l: float32;
	prev := s[0];
	for i: 1..N {
		t := cast(float32)(i) / N;
		m := 1 - t;
		q := m * m * m * s[0] + 3 * m * m * t * s[1] + 3 * m * t * t * s[2] + t * t * t * s[3];
		d := q - prev;
		l += math.sqrt(d.x * d.x + d.y * d.y);
		prev = q;
	}
	return l;
}

// parameter u where the arc length from 0 reaches `target` (by sampling)
cubic_param :: (s: [4][2]float32, target: float32) -> float32 {
	N :: 48;
	l: float32;
	prev := s[0];
	for i: 1..N {
		t := cast(float32)(i) / N;
		m := 1 - t;
		q := m * m * m * s[0] + 3 * m * m * t * s[1] + 3 * m * t * t * s[2] + t * t * t * s[3];
		d := q - prev;
		dl := math.sqrt(d.x * d.x + d.y * d.y);
		if l + dl >= target {
			f := ifx dl > 0 then (target - l) / dl else 0;
			return (cast(float32)(i - 1) + f) / N;
		}
		l += dl;
		prev = q;
	}
	return 1;
}

split_cubic :: (s: [4][2]float32, u0: float32, u1: float32) -> [4][2]float32 {
	// de Casteljau: keep [u0, u1]
	sub :: (s: [4][2]float32, t: float32) -> [4][2]float32, [4][2]float32 {
		left: [4][2]float32;
		right: [4][2]float32;
		a := s[0] + (s[1] - s[0]) * t;
		b := s[1] + (s[2] - s[1]) * t;
		c := s[2] + (s[3] - s[2]) * t;
		d := a + (b - a) * t;
		e := b + (c - b) * t;
		f := d + (e - d) * t;
		return .{s[0], a, d, f}, .{f, e, c, s[3]};
	}
	_, r := sub(s, u0);
	if u0 >= 1 { return .{s[3], s[3], s[3], s[3]}; }
	t := (u1 - u0) / (1 - u0);
	l, _ := sub(r, clamp(t, 0, 1));
	return l;
}

path_segments :: (p: *Player, path: *vector.Path) -> [..][..]Seg {
	out := make_dynamic([..]Seg, 0, 0, p.falloc);
	pi := 0;
	cur, start: [2]float32;
	segs: *[..]Seg;
	for v: path.verbs {
		if v == {
		case .Move;
			cur = path.points[pi];
			start = cur;
			pi += 1;
			append(*out, make_dynamic(Seg, 0, 0, p.falloc));
			segs = at(*out, len(out) - 1);
		case .Line;
			q := path.points[pi];
			pi += 1;
			if segs != null { append(segs, Seg.{p = .{cur, cur + (q - cur) / 3, cur + (q - cur) * 2 / 3, q}}); }
			cur = q;
		case .Quad;
			c, q := path.points[pi], path.points[pi + 1];
			pi += 2;
			if segs != null { append(segs, Seg.{p = .{cur, cur + (c - cur) * 2 / 3, q + (c - q) * 2 / 3, q}}); }
			cur = q;
		case .Cubic;
			if segs != null { append(segs, Seg.{p = .{cur, path.points[pi], path.points[pi + 1], path.points[pi + 2]}}); }
			cur = path.points[pi + 2];
			pi += 3;
		case .Close;
			if segs != null && cur != start { append(segs, Seg.{p = .{cur, cur + (start - cur) / 3, cur + (start - cur) * 2 / 3, start}}); }
			cur = start;
		}
	}
	for * sl: out { for * s: sl { s.l = cubic_len(s.p); } }
	return out;
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
			if hi < lo || s.l <= 0 { continue; }
			u0 := cubic_param(s.p, lo - s0);
			u1 := cubic_param(s.p, hi - s0);
			piece := split_cubic(s.p, u0, u1);
			if !started {
				vector.path_move(dst, piece[0]);
				started = true;
			}
			vector.path_cubic(dst, piece[1], piece[2], piece[3]);
		}
	}
}

apply_trim :: (p: *Player, it_: *Item, t: float32, geo: *[..]*Slot) {
	s := ev1(*it_.t_start, t) / 100;
	e := ev1(*it_.t_end, t, 100) / 100;
	o := ev1(*it_.t_off, t) / 360;
	if s > e { s, e = e, s; }
	s += o;
	e += o;
	if e - s >= 1 { return; } // full
	if e - s <= 0 {
		for sl: geo { sl.path = new_path(p); }
		return;
	}
	k := math.floor(s);
	s -= k;
	e -= k;
	// keep [lo, hi] (absolute lengths) of a contour list whose run is [base, base+len] of total
	keep :: (p: *Player, cs: [][..]Seg, base: float32, length: float32, a: float32, b: float32, dst: *vector.Path) {
		lo := max(a, base);
		hi := min(b, base + length);
		if hi > lo { emit_range(dst, cs, lo - base, hi - base); }
	}
	if it_.t_mode == 2 {
		// individually: the paths form one sequence
		segs := make_slice([..][..]Seg, len(geo), p.falloc);
		lens := make_slice(float32, len(geo), p.falloc);
		total: float32;
		for sl, i: geo {
			segs[i] = path_segments(p, sl.path);
			for c: segs[i] { for sg: c { lens[i] += sg.l; } }
			total += lens[i];
		}
		base: float32;
		for sl, i: geo {
			dst := new_path(p);
			keep(p, view(segs[i]), base, lens[i], s * total, min(e, 1) * total, dst);
			if e > 1 { keep(p, view(segs[i]), base, lens[i], 0, (e - 1) * total, dst); }
			sl.path = dst;
			base += lens[i];
		}
		return;
	}
	for sl: geo {
		cs := path_segments(p, sl.path);
		total: float32;
		for c: cs { for sg: c { total += sg.l; } }
		dst := new_path(p);
		keep(p, view(cs), 0, total, s * total, min(e, 1) * total, dst);
		if e > 1 { keep(p, view(cs), 0, total, 0, (e - 1) * total, dst); }
		sl.path = dst;
	}
}
#scope_export

