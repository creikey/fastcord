// A keyframe: segment k -> k+1 is shaped by k's out (o) and in (i) easing.
Keyframe :: struct {
	t: float32;
	s: []float32;
	e: []float32; // old-format explicit end value (else the next keyframe's s)
	hold: bool;
	ox, oy: []float32; // easing, per dimension (len 1 = shared)
	ix, iy: []float32;
	to, ti: []float32; // spatial tangents (position paths)
}

Prop :: struct {
	value: []float32; // static value
	kfs: []Keyframe;
}

Shape_Data :: struct {
	v, i, o: []Vector2;
	closed: bool;
}

Shape_Keyframe :: struct {
	t: float32;
	s, e: Shape_Data;
	has_e: bool;
	hold: bool;
	ox, oy: float32;
	ix, iy: float32;
}

Shape_Prop :: struct {
	value: Shape_Data;
	kfs: []Shape_Keyframe;
}

Transform :: struct {
	a, p, s, r, o: Prop;
	px, py: Prop;
	split: bool;
	sk, sa: Prop;
}

Item_Kind :: enum u8 {
	Ignore;
	Group;
	Path;
	Rect;
	Ellipse;
	Star;
	Fill;
	Stroke;
	Gradient_Fill;
	Gradient_Stroke;
	Trim;
}

Item :: struct {
	kind: Item_Kind;
	hidden: bool;
	items: []Item; // group
	tr: Transform; // group transform
	has_tr: bool;
	shape: Shape_Prop; // path
	reversed: bool; // d == 3
	// rect / ellipse / star
	p, size, r: Prop;
	star_type: int;
	pt, ir, or_, is, os: Prop;
	// styles
	color, opacity, width: Prop;
	evenodd: bool;
	cap: int;
	join: int;
	miter: float32;
	// gradients
	grad_type: int; // 1 linear, 2 radial
	g_start, g_end, g_hl, g_ha: Prop;
	g_colors: Prop;
	g_count: int;
	// trim
	t_start, t_end, t_off: Prop;
	t_mode: int; // 1 simultaneously, 2 individually
}

Mask :: struct {
	mode: u8; // 'a' add 's' subtract 'i' intersect 'l' lighten 'd' darken 'f' difference 'n' none
	inverted: bool;
	path: Shape_Prop;
	opacity: Prop;
}

Layer :: struct {
	ty: int; // 0 precomp, 1 solid, 2 image, 3 null, 4 shape, 5 text
	ind: int;
	parent: int; // ind of parent or -1
	ip, op, st: float32;
	sr: float32;
	ks: Transform;
	shapes: []Item;
	ref: int; // precomp asset index or -1
	w, h: float32; // precomp / solid size
	solid_color: Vector4;
	td: bool; // this layer is a track matte for the next layer
	tt: int; // track matte type for this layer: 1 alpha 2 alpha-inv 3 luma 4 luma-inv
	hidden: bool;
	masks: []Mask;
}

Comp :: struct {
	id: string;
	w, h: float32;
	layers: []Layer;
}

Animation :: struct {
	w, h: float32;
	fr: float32;
	ip, op: float32;
	root: Comp;
	assets: []Comp;
	pool: Flat_Pool; // everything the animation holds, the parsed JSON included
}

// load parses a Lottie JSON document; null when it is not valid JSON or not an object.
load :: (data: []u8) -> *Animation {
	anim := New(Animation);
	push_allocator(.{flat_pool_allocator_proc, *anim.pool});
	obj, err := etf.from_json(to_string(data.data, data.count));
	if err != .None || obj.kind != .Map {
		destroy(anim);
		return null;
	}
	anim.w = num(obj, "w", 512);
	anim.h = num(obj, "h", 512);
	anim.fr = num(obj, "fr", 60);
	anim.ip = num(obj, "ip", 0);
	anim.op = num(obj, "op", 60);
	if anim.fr <= 0  anim.fr = 60;
	// assets: precomps (index them first so layers can refer by id)
	assets: Table(string, int);
	arr := list(obj, "assets");
	anim.assets = NewArray(arr.count, Comp);
	for arr {
		id := str(it, "id");
		table_set(*assets, id, it_index);
		anim.assets[it_index].id = id;
	}
	for arr {
		a := *anim.assets[it_index];
		a.w = num(it, "w", anim.w);
		a.h = num(it, "h", anim.h);
		a.layers = load_layers(*assets, list(it, "layers"));
	}
	anim.root.w, anim.root.h = anim.w, anim.h;
	anim.root.layers = load_layers(*assets, list(obj, "layers"));
	return anim;
}

destroy :: (anim: *Animation) {
	if anim == null return;
	fini(*anim.pool);
	free(anim);
}

#scope_module

Value :: etf.Value;

// The value of an object's key (the last one, as with Odin's JSON maps); Nil when o is not an object.
field :: (o: Value, key: string) -> Value, bool {
	if o.kind == .Map  for < o.map  if it.key.kind == .String && it.key.s == key return it.value, true;
	return .{}, false;
}

list :: (o: Value, key: string) -> []Value {
	v := field(o, key);
	return ifx v.kind == .List then v.list else .[];
}

num :: (o: Value, key: string, def: float32) -> float32 {
	v, ok := field(o, key);
	return ifx ok then value_f32(v, def) else def;
}

value_f32 :: (v: Value, def: float32) -> float32 {
	if v.kind == {
		case .Float; return cast(float32) v.f;
		case .Int;   return cast(float32) v.i;
		case .Bool;  return ifx v.b then 1.0 else 0.0;
		case .List;  if v.list.count  return value_f32(v.list[0], def);
	}
	return def;
}

str :: (o: Value, key: string) -> string {
	v := field(o, key);
	return ifx v.kind == .String then v.s else "";
}

floats :: (v: Value) -> []float32 {
	if v.kind == {
	case .List;
		out := NewArray(v.list.count, float32);
		for v.list  out[it_index] = value_f32(it, 0);
		return out;
	case .Float; #through;
	case .Int;
		out := NewArray(1, float32);
		out[0] = value_f32(v, 0);
		return out;
	}
	return .[];
}

load_prop :: (v: Value, def: []float32 = .[]) -> Prop {
	if v.kind != .Map return .{value = def};
	k := field(v, "k");
	animated := num(v, "a", 0) == 1;
	if k.kind == .List && k.list.count > 0 && k.list[0].kind == .Map  animated = true;
	if !animated return .{value = floats(k)};
	arr := ifx k.kind == .List then k.list else .[];
	kfs := NewArray(arr.count, Keyframe);
	for ko, i: arr {
		kf := *kfs[i];
		kf.t = num(ko, "t", 0);
		kf.s = floats(field(ko, "s"));
		ev, has_e := field(ko, "e");
		if has_e  kf.e = floats(ev);
		kf.hold = num(ko, "h", 0) == 1;
		oo := field(ko, "o");
		if oo.kind == .Map {
			kf.ox = floats(field(oo, "x"));
			kf.oy = floats(field(oo, "y"));
		}
		io := field(ko, "i");
		if io.kind == .Map {
			kf.ix = floats(field(io, "x"));
			kf.iy = floats(field(io, "y"));
		}
		to, has_to := field(ko, "to");
		if has_to  kf.to = floats(to);
		ti, has_ti := field(ko, "ti");
		if has_ti  kf.ti = floats(ti);
	}
	return .{kfs = kfs};
}

load_shape_data :: (v: Value) -> Shape_Data {
	if v.kind != .Map {
		if v.kind == .List && v.list.count > 0  return load_shape_data(v.list[0]);
		return .{};
	}
	pts :: (v: Value) -> []Vector2 {
		arr := ifx v.kind == .List then v.list else .[];
		out := NewArray(arr.count, Vector2);
		for arr  if it.kind == .List && it.list.count >= 2  out[it_index] = .{value_f32(it.list[0], 0), value_f32(it.list[1], 0)};
		return out;
	}
	sd := Shape_Data.{v = pts(field(v, "v")), i = pts(field(v, "i")), o = pts(field(v, "o")), closed = num(v, "c", 0) == 1};
	n := sd.v.count;
	if sd.i.count < n || sd.o.count < n {
		sd.i = NewArray(n, Vector2);
		sd.o = NewArray(n, Vector2);
	}
	return sd;
}

load_shape_prop :: (v: Value) -> Shape_Prop {
	if v.kind != .Map return .{};
	k := field(v, "k");
	if k.kind != .List || k.list.count == 0 return .{value = load_shape_data(k)};
	_, keyframed := field(k.list[0], "t");
	if !keyframed return .{value = load_shape_data(k)};
	kfs := NewArray(k.list.count, Shape_Keyframe);
	for ko, i: k.list {
		kf := *kfs[i];
		kf.t = num(ko, "t", 0);
		kf.s = load_shape_data(field(ko, "s"));
		ev, has_e := field(ko, "e");
		if has_e {
			kf.e = load_shape_data(ev);
			kf.has_e = true;
		}
		kf.hold = num(ko, "h", 0) == 1;
		kf.ox, kf.oy, kf.ix, kf.iy = 0, 0, 1, 1;
		oo := field(ko, "o");
		if oo.kind == .Map {
			kf.ox = value_f32(field(oo, "x"), 0);
			kf.oy = value_f32(field(oo, "y"), 0);
		}
		io := field(ko, "i");
		if io.kind == .Map {
			kf.ix = value_f32(field(io, "x"), 1);
			kf.iy = value_f32(field(io, "y"), 1);
		}
	}
	return .{kfs = kfs};
}

DEF_ONE := float32.[100, 100, 100];
DEF_OPACITY := float32.[100];
DEF_ZERO := float32.[0, 0, 0];

zero :: (n: int) -> []float32 { return array_view(DEF_ZERO, 0, n); }

load_transform :: (o: Value) -> Transform {
	t := Transform.{
		a = load_prop(field(o, "a"), DEF_ZERO),
		s = load_prop(field(o, "s"), DEF_ONE),
		o = load_prop(field(o, "o"), DEF_OPACITY),
		sk = load_prop(field(o, "sk"), zero(1)),
		sa = load_prop(field(o, "sa"), zero(1))
	};
	rv, has_r := field(o, "r");
	t.r = load_prop(ifx has_r then rv else field(o, "rz"), zero(1));
	pv := field(o, "p");
	if num(pv, "s", 0) == 1 {
		t.split = true;
		t.px = load_prop(field(pv, "x"), zero(1));
		t.py = load_prop(field(pv, "y"), zero(1));
	} else {
		t.p = load_prop(pv, DEF_ZERO);
	}
	return t;
}

load_items :: (arr: []Value) -> []Item {
	out: [..]Item;
	array_reserve(*out, arr.count);
	for o: arr {
		if o.kind != .Map continue;
		item := Item.{hidden = num(o, "hd", 0) == 1};
		ty := str(o, "ty");
		if ty == {
		case "gr";
			item.kind = .Group;
			sub := list(o, "it");
			// the group transform is the 'tr' item
			for s: sub  if str(s, "ty") == "tr" {
				item.tr = load_transform(s);
				item.has_tr = true;
			}
			item.items = load_items(sub);
		case "sh";
			item.kind = .Path;
			item.shape = load_shape_prop(field(o, "ks"));
			item.reversed = num(o, "d", 1) == 3;
		case "rc";
			item.kind = .Rect;
			item.p = load_prop(field(o, "p"), zero(2));
			item.size = load_prop(field(o, "s"), zero(2));
			item.r = load_prop(field(o, "r"), zero(1));
			item.reversed = num(o, "d", 1) == 3;
		case "el";
			item.kind = .Ellipse;
			item.p = load_prop(field(o, "p"), zero(2));
			item.size = load_prop(field(o, "s"), zero(2));
			item.reversed = num(o, "d", 1) == 3;
		case "sr";
			item.kind = .Star;
			item.star_type = cast(int) num(o, "sy", 1);
			item.p = load_prop(field(o, "p"), zero(2));
			item.pt = load_prop(field(o, "pt"), zero(1));
			item.r = load_prop(field(o, "r"), zero(1));
			item.or_ = load_prop(field(o, "or"), zero(1));
			item.os = load_prop(field(o, "os"), zero(1));
			item.ir = load_prop(field(o, "ir"), zero(1));
			item.is = load_prop(field(o, "is"), zero(1));
			item.reversed = num(o, "d", 1) == 3;
		case "fl"; #through; case "st"; #through; case "gf"; #through; case "gs";
			item.kind = ifx ty == "fl" then .Fill else ifx ty == "st" then .Stroke else ifx ty == "gf" then .Gradient_Fill else .Gradient_Stroke;
			item.color = load_prop(field(o, "c"), DEF_ZERO);
			item.opacity = load_prop(field(o, "o"), DEF_OPACITY);
			item.width = load_prop(field(o, "w"), zero(1));
			item.evenodd = num(o, "r", 1) == 2;
			item.cap = cast(int) num(o, "lc", 2);
			item.join = cast(int) num(o, "lj", 2);
			item.miter = num(o, "ml", 4);
			if ty == "gf" || ty == "gs" {
				item.grad_type = cast(int) num(o, "t", 1);
				item.g_start = load_prop(field(o, "s"), zero(2));
				item.g_end = load_prop(field(o, "e"), zero(2));
				item.g_hl = load_prop(field(o, "h"), zero(1));
				item.g_ha = load_prop(field(o, "a"), zero(1));
				go := field(o, "g");
				if go.kind == .Map {
					item.g_count = cast(int) num(go, "p", 0);
					item.g_colors = load_prop(field(go, "k"));
				}
			}
		case "tm";
			item.kind = .Trim;
			item.t_start = load_prop(field(o, "s"), zero(1));
			item.t_end = load_prop(field(o, "e"), DEF_OPACITY);
			item.t_off = load_prop(field(o, "o"), zero(1));
			item.t_mode = cast(int) num(o, "m", 1);
		case;
			continue; // tr (handled by the group), mm, rp, ...
		}
		array_add(*out, item);
	}
	return out;
}

load_layers :: (assets: *Table(string, int), arr: []Value) -> []Layer {
	out := NewArray(arr.count, Layer);
	for o, i: arr {
		l := *out[i];
		l.ty = cast(int) num(o, "ty", 3);
		l.ind = cast(int) num(o, "ind", cast(float32) (i + 1));
		pv, has_parent := field(o, "parent");
		l.parent = ifx has_parent then cast(int) value_f32(pv, -1) else -1;
		l.ip = num(o, "ip", 0);
		l.op = num(o, "op", 1000000000);
		l.st = num(o, "st", 0);
		l.sr = num(o, "sr", 1);
		if l.sr == 0  l.sr = 1;
		l.ks = load_transform(field(o, "ks"));
		l.hidden = num(o, "hd", 0) == 1;
		l.td = num(o, "td", 0) != 0;
		l.tt = cast(int) num(o, "tt", 0);
		l.ref = -1;
		l.w = num(o, "w", 0);
		l.h = num(o, "h", 0);
		ref := str(o, "refId");
		if ref != "" {
			found, idx := table_find(assets, ref);
			if found  l.ref = idx;
		}
		if l.ty == 1 {
			l.w = num(o, "sw", 0);
			l.h = num(o, "sh", 0);
			l.solid_color = parse_hex(str(o, "sc"));
		}
		l.shapes = load_items(list(o, "shapes"));
		masks := list(o, "masksProperties");
		l.masks = NewArray(masks.count, Mask);
		for m, j: masks {
			mode := str(m, "mode");
			l.masks[j] = .{
				mode = ifx mode.count > 0 then mode[0] else #char "a",
				inverted = num(m, "inv", 0) == 1,
				path = load_shape_prop(field(m, "pt")),
				opacity = load_prop(field(m, "o"), DEF_OPACITY)
			};
		}
	}
	return out;
}

parse_hex :: (s: string) -> Vector4 {
	h := s;
	if h.count > 0 && h[0] == #char "#"  advance(*h);
	if h.count < 6 return .{0, 0, 0, 1};
	// strconv.parse_int(s, 16): 0 unless both characters parse
	byte :: (h: string, i: int) -> float32 {
		v, ok, rest := string_to_int(slice(h, i, 2), 16);
		return cast(float32) (ifx ok && rest.count == 0 then v else 0) / 255;
	}
	return .{byte(h, 0), byte(h, 2), byte(h, 4), 1};
}

// ---------------------------------------------------------------------------
// Keyframe evaluation

// bezier_ease solves the CSS-style cubic bezier (0,0)-(x1,y1)-(x2,y2)-(1,1) at x.
bezier_ease :: (x1: float32, y1: float32, x2: float32, y2: float32, x: float32) -> float32 {
	if x <= 0 { return 0; }
	if x >= 1 { return 1; }
	if x1 == y1 && x2 == y2 { return x; }
	bx :: (a: float32, b: float32, u: float32) -> float32 {return 3 * a * u * (1 - u) * (1 - u) + 3 * b * u * u * (1 - u) + u * u * u;}
	dbx :: (a: float32, b: float32, u: float32) -> float32 {return 3 * a * (1 - u) * (1 - u) + 6 * (b - a) * u * (1 - u) + 3 * (1 - b) * u * u;}
	u := x;
	for 0..7 {
		d := dbx(x1, x2, u);
		if abs(d) < 1.0e-6 { break; }
		e := bx(x1, x2, u) - x;
		if abs(e) < 1.0e-7 { return bx(y1, y2, u); }
		u -= e / d;
	}
	if u < 0 || u > 1 || abs(bx(x1, x2, u) - x) > 1.0e-5 {
		lo, hi: float32 = 0, 1;
		u = x;
		for 0..39 {
			v := bx(x1, x2, u);
			if abs(v - x) < 1.0e-7 { break; }
			if v < x { lo = u; } else { hi = u; }
			u = (lo + hi) / 2;
		}
	}
	return bx(y1, y2, u);
}

pick :: inline (a: []float32, i: int, def: float32) -> float32 {
	return ifx a.count == 0 then def else a[min(i, a.count - 1)];
}

// Copies as much of src as fits into out; returns how much.
put :: (out: []float32, src: []float32) -> int {
	n := min(src.count, out.count);
	memcpy(out.data, src.data, n * size_of(float32));
	return n;
}

// eval writes the property value at frame t into out (returns dims).
eval :: (p: *Prop, t: float32, out: []float32) -> int {
	if p.kfs.count == 0 return put(out, p.value);
	kfs := p.kfs;
	if t <= kfs[0].t || kfs.count == 1 return put(out, kfs[0].s);
	k := 0;
	while k + 1 < kfs.count && t >= kfs[k + 1].t  k += 1;
	a := *kfs[k];
	if k + 1 >= kfs.count {
		// past the last keyframe: its start value (or the previous end value)
		if a.s.count > 0 return put(out, a.s);
		return put(out, ifx k > 0 && kfs[k - 1].e.count > 0 then kfs[k - 1].e else kfs[k - 1].s);
	}
	b := *kfs[k + 1];
	s := a.s;
	e := ifx a.e.count > 0 then a.e else b.s;
	n := min(s.count, out.count);
	if a.hold || e.count < n return put(out, s);
	x := (t - a.t) / max(b.t - a.t, 1.0e-6);
	spatial := a.to.count >= 2 && a.ti.count >= 2 && n >= 2 && (a.to[0] != 0 || a.to[1] != 0 || a.ti[0] != 0 || a.ti[1] != 0);
	if spatial {
		u := bezier_ease(pick(a.ox, 0, 0), pick(a.oy, 0, 0), pick(a.ix, 0, 1), pick(a.iy, 0, 1), x);
		pt := spatial_point(s, e, a.to, a.ti, u);
		out[0], out[1] = pt.x, pt.y;
		for d: 2..n-1 { out[d] = s[d] + (e[d] - s[d]) * u; }
		return n;
	}
	for d: 0..n-1 {
		u := bezier_ease(pick(a.ox, d, 0), pick(a.oy, d, 0), pick(a.ix, d, 1), pick(a.iy, d, 1), x);
		out[d] = s[d] + (e[d] - s[d]) * u;
	}
	return n;
}

// Point at fraction u of the arc length of the bezier s -> e (lottie-web: 150-sample LUT).
spatial_point :: (s: []float32, e: []float32, to: []float32, ti: []float32, u: float32) -> Vector2 {
	p0 := Vector2.{s[0], s[1]};
	p3 := Vector2.{e[0], e[1]};
	p1 := p0 + .{to[0], to[1]};
	p2 := p3 + .{ti[0], ti[1]};
	bez :: (p0: Vector2, p1: Vector2, p2: Vector2, p3: Vector2, t: float32) -> Vector2 {
		m := 1 - t;
		return m * m * m * p0 + 3 * m * m * t * p1 + 3 * m * t * t * p2 + t * t * t * p3;
	}
	N :: 150;
	lens: [N + 1]float32;
	prev := p0;
	for i: 1..N {
		q := bez(p0, p1, p2, p3, cast(float32)(i) / N);
		d := q - prev;
		lens[i] = lens[i - 1] + sqrt(d.x * d.x + d.y * d.y);
		prev = q;
	}
	total := lens[N];
	if total <= 0 { return p0 + (p3 - p0) * u; }
	target := clamp(u, 0, 1) * total;
	if u >= 1 { return p3; }
	if u <= 0 { return p0; }
	for i: 1..N {
		if lens[i] >= target {
			seg := lens[i] - lens[i - 1];
			f := ifx seg > 0 then (target - lens[i - 1]) / seg else 0;
			a := bez(p0, p1, p2, p3, cast(float32)(i - 1) / N);
			b := bez(p0, p1, p2, p3, cast(float32)(i) / N);
			return a + (b - a) * f;
		}
	}
	return p3;
}

// eval_shape returns the path at frame t (vertex arrays allocated with context.allocator when interpolated).
eval_shape :: (p: *Shape_Prop, t: float32) -> Shape_Data {
	if p.kfs.count == 0 { return p.value; }
	kfs := p.kfs;
	if t <= kfs[0].t || kfs.count == 1 { return kfs[0].s; }
	k := 0;
	while k + 1 < kfs.count && t >= kfs[k + 1].t  k += 1;
	a := *kfs[k];
	if k + 1 >= kfs.count {
		if a.s.v.count > 0 { return a.s; }
		return ifx k > 0 && kfs[k - 1].has_e then kfs[k - 1].e else kfs[k - 1].s;
	}
	b := *kfs[k + 1];
	e := ifx a.has_e then a.e else b.s;
	s := a.s;
	if a.hold || e.v.count != s.v.count { return s; }
	x := (t - a.t) / max(b.t - a.t, 1.0e-6);
	u := bezier_ease(a.ox, a.oy, a.ix, a.iy, x);
	n := s.v.count;
	out := Shape_Data.{
		v = NewArray(n, Vector2),
		i = NewArray(n, Vector2),
		o = NewArray(n, Vector2),
		closed = s.closed
	};
	for j: 0..n-1 {
		out.v[j] = s.v[j] + (e.v[j] - s.v[j]) * u;
		out.i[j] = s.i[j] + (e.i[j] - s.i[j]) * u;
		out.o[j] = s.o[j] + (e.o[j] - s.o[j]) * u;
	}
	return out;
}

