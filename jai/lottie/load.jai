Error :: enum u8 {
	None;
	Bad_Json;
	Unsupported;
	Out_Of_Memory;
}

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
	arena: virtual.Arena;
}
#scope_module

// ---------------------------------------------------------------------------
// Loading

Loader :: struct {
	alloc: Allocator;
	assets: Map(string, int);
}
#scope_export

load :: (data: []u8) -> *Animation, Error {
	anim: *Animation;
	err: Error;
	anim = new(Animation);
	if virtual.arena_init_growing(*anim.arena) != .None {
		free(anim);
		return null, .Out_Of_Memory;
	}
	alloc := virtual.arena_allocator(*anim.arena);
	root, jerr := json.parse(data, .JSON, false, alloc);
	if jerr != .None {
		destroy(anim);
		return null, .Bad_Json;
	}
	obj, ok := root.map, root.kind == .Map;
	if !ok {
		destroy(anim);
		return null, .Bad_Json;
	}
	L := Loader.{alloc = alloc};
	L.assets = Map(string, int).{};
	anim.w = num(obj, "w", 512);
	anim.h = num(obj, "h", 512);
	anim.fr = num(obj, "fr", 60);
	anim.ip = num(obj, "ip", 0);
	anim.op = num(obj, "op", 60);
	if anim.fr <= 0 { anim.fr = 60; }
	// assets: precomps (index them first so layers can refer by id)
	{ arr, aok := get(obj, "assets").list, get(obj, "assets").kind == .List;
	if aok {
		anim.assets = make_slice(Comp, len(arr), alloc);
		for a, i: arr {
			ao, _ := a.map, a.kind == .Map;
			id := str(ao, "id");
			at(*L.assets, id).* = i;
			at(*anim.assets, i).*.id = id;
		}
		for a, i: arr {
			ao, _ := a.map, a.kind == .Map;
			at(*anim.assets, i).*.w = num(ao, "w", anim.w);
			at(*anim.assets, i).*.h = num(ao, "h", anim.h);
			{ la, lok := get(ao, "layers").list, get(ao, "layers").kind == .List;
			if lok { at(*anim.assets, i).*.layers = load_layers(*L, la); } }
		}
	} }
	anim.root.w, anim.root.h = anim.w, anim.h;
	{ la, lok := get(obj, "layers").list, get(obj, "layers").kind == .List;
	if lok { anim.root.layers = load_layers(*L, la); } }
	return anim, .None;
}

destroy :: (anim: *Animation) {
	if anim == null { return; }
	virtual.arena_destroy(*anim.arena);
	free(anim);
}
#scope_module

num :: (o: json.Object, key: string, def: float32) -> float32 {
	v, ok := map_find(o, key);
	if !ok { return def; }
	return value_f32(v, def);
}

value_f32 :: (v: json.Value, def: float32) -> float32 {
	if v.kind == {
	case .Float; x := v.f;
		return cast(float32)(x);
	case .Int; x := v.i;
		return cast(float32)(x);
	case .Bool; x := v.b;
		return cast(float32) ifx x then 1 else 0;
	case .List; x := v.list;
		if len(x) > 0 { return value_f32(x[0], def); }
	}
	return def;
}

str :: (o: json.Object, key: string) -> string {
	{ s, ok := get(o, key).s, get(o, key).kind == .String;
	if ok { return as_string(s); } }
	return "";
}

floats :: (L: *Loader, v: json.Value) -> []float32 {
	if v.kind == {
	case .List; x := v.list;
		out := make_slice(float32, len(x), L.alloc);
		for e, i: x { at(*out, i).* = value_f32(e, 0); }
		return out;
	case .Float; #through; case .Int; x := v;
		out := make_slice(float32, 1, L.alloc);
		at(*out, 0).* = value_f32(v, 0);
		return out;
	}
	return .{};
}

load_prop :: (L: *Loader, v: json.Value, def: []float32 = .{}) -> Prop {
	o, ok := v.map, v.kind == .Map;
	if !ok { return .{value = def}; }
	k := get(o, "k");
	animated := num(o, "a", 0) == 1;
	{ arr, aok := k.list, k.kind == .List;
	if aok && len(arr) > 0 {
		{ _, isobj := arr[0].map, arr[0].kind == .Map;
		if isobj { animated = true; } }
	} }
	if !animated { return .{value = floats(L, k)}; }
	arr, _ := k.list, k.kind == .List;
	kfs := make_slice(Keyframe, len(arr), L.alloc);
	for e, i: arr {
		ko, _ := e.map, e.kind == .Map;
		kf := *kfs[i];
		kf.t = num(ko, "t", 0);
		kf.s = floats(L, get(ko, "s"));
		{ ev, has := map_find(ko, "e");
		if has { kf.e = floats(L, ev); } }
		kf.hold = num(ko, "h", 0) == 1;
		{ oo, has := get(ko, "o").map, get(ko, "o").kind == .Map;
		if has {
			kf.ox = floats(L, get(oo, "x"));
			kf.oy = floats(L, get(oo, "y"));
		} }
		{ io, has := get(ko, "i").map, get(ko, "i").kind == .Map;
		if has {
			kf.ix = floats(L, get(io, "x"));
			kf.iy = floats(L, get(io, "y"));
		} }
		{ tv, has := map_find(ko, "to");
		if has { kf.to = floats(L, tv); } }
		{ tv, has := map_find(ko, "ti");
		if has { kf.ti = floats(L, tv); } }
	}
	return .{kfs = kfs};
}

load_shape_data :: (L: *Loader, v: json.Value) -> Shape_Data {
	o, ok := v.map, v.kind == .Map;
	if !ok {
		{ arr, aok := v.list, v.kind == .List;
		if aok && len(arr) > 0 { return load_shape_data(L, arr[0]); } }
		return .{};
	}
	pts :: (L: *Loader, v: json.Value) -> []Vector2 {
		arr, _ := v.list, v.kind == .List;
		out := make_slice(Vector2, len(arr), L.alloc);
		for e, i: arr {
			p, _ := e.list, e.kind == .List;
			if len(p) >= 2 { at(*out, i).* = .{value_f32(p[0], 0), value_f32(p[1], 0)}; }
		}
		return out;
	}
	sd := Shape_Data.{
		v = pts(L, get(o, "v")),
		i = pts(L, get(o, "i")),
		o = pts(L, get(o, "o")),
		closed = num(o, "c", 0) == 1
	};
	n := len(sd.v);
	if len(sd.i) < n || len(sd.o) < n {
		sd.i = make_slice(Vector2, n, L.alloc);
		sd.o = make_slice(Vector2, n, L.alloc);
	}
	return sd;
}

load_shape_prop :: (L: *Loader, v: json.Value) -> Shape_Prop {
	o, ok := v.map, v.kind == .Map;
	if !ok { return .{}; }
	k := get(o, "k");
	arr, isarr := k.list, k.kind == .List;
	if !isarr || len(arr) == 0 { return .{value = load_shape_data(L, k)}; }
	first, _ := arr[0].map, arr[0].kind == .Map;
	{ _, has := map_find(first, "t");
	if !has { return .{value = load_shape_data(L, k)}; } }
	kfs := make_slice(Shape_Keyframe, len(arr), L.alloc);
	for e, i: arr {
		ko, _ := e.map, e.kind == .Map;
		kf := *kfs[i];
		kf.t = num(ko, "t", 0);
		kf.s = load_shape_data(L, get(ko, "s"));
		{ ev, has := map_find(ko, "e");
		if has {
			kf.e = load_shape_data(L, ev);
			kf.has_e = true;
		} }
		kf.hold = num(ko, "h", 0) == 1;
		kf.ox, kf.oy, kf.ix, kf.iy = 0, 0, 1, 1;
		{ oo, has := get(ko, "o").map, get(ko, "o").kind == .Map;
		if has {
			kf.ox = value_f32(get(oo, "x"), 0);
			kf.oy = value_f32(get(oo, "y"), 0);
		} }
		{ io, has := get(ko, "i").map, get(ko, "i").kind == .Map;
		if has {
			kf.ix = value_f32(get(io, "x"), 1);
			kf.iy = value_f32(get(io, "y"), 1);
		} }
	}
	return .{kfs = kfs};
}

DEF_ONE := float32.[100, 100, 100];
DEF_OPACITY := float32.[100];
DEF_ZERO := float32.[0, 0, 0];

load_transform :: (L: *Loader, v: json.Value) -> Transform {
	o, _ := v.map, v.kind == .Map;
	t := Transform.{
		a = load_prop(L, get(o, "a"), view(DEF_ZERO)),
		s = load_prop(L, get(o, "s"), view(DEF_ONE)),
		o = load_prop(L, get(o, "o"), view(DEF_OPACITY)),
		sk = load_prop(L, get(o, "sk"), sub(DEF_ZERO, 0, 1)),
		sa = load_prop(L, get(o, "sa"), sub(DEF_ZERO, 0, 1))
	};
	{ rv, has := map_find(o, "r");
	if has {
		t.r = load_prop(L, rv, sub(DEF_ZERO, 0, 1));
	} else {
		t.r = load_prop(L, get(o, "rz"), sub(DEF_ZERO, 0, 1));
	} }
	pv, _ := get(o, "p").map, get(o, "p").kind == .Map;
	if num(pv, "s", 0) == 1 {
		t.split = true;
		t.px = load_prop(L, get(pv, "x"), sub(DEF_ZERO, 0, 1));
		t.py = load_prop(L, get(pv, "y"), sub(DEF_ZERO, 0, 1));
	} else {
		t.p = load_prop(L, get(o, "p"), view(DEF_ZERO));
	}
	return t;
}

load_items :: (L: *Loader, arr: json.Array) -> []Item {
	out := make_dynamic(Item, 0, len(arr), L.alloc);
	for e: arr {
		o, ok := e.map, e.kind == .Map;
		if !ok { continue; }
		it_ := Item.{
			hidden = num(o, "hd", 0) == 1
		};
		if str(o, "ty") == {
		case "gr";
			it_.kind = .Group;
			sub, _ := get(o, "it").list, get(o, "it").kind == .List;
			// the group transform is the 'tr' item
			for s: sub {
				so, _ := s.map, s.kind == .Map;
				if str(so, "ty") == "tr" {
					it_.tr = load_transform(L, s);
					it_.has_tr = true;
				}
			}
			it_.items = load_items(L, sub);
		case "sh";
			it_.kind = .Path;
			it_.shape = load_shape_prop(L, get(o, "ks"));
			it_.reversed = num(o, "d", 1) == 3;
		case "rc";
			it_.kind = .Rect;
			it_.p = load_prop(L, get(o, "p"), sub(DEF_ZERO, 0, 2));
			it_.size = load_prop(L, get(o, "s"), sub(DEF_ZERO, 0, 2));
			it_.r = load_prop(L, get(o, "r"), sub(DEF_ZERO, 0, 1));
			it_.reversed = num(o, "d", 1) == 3;
		case "el";
			it_.kind = .Ellipse;
			it_.p = load_prop(L, get(o, "p"), sub(DEF_ZERO, 0, 2));
			it_.size = load_prop(L, get(o, "s"), sub(DEF_ZERO, 0, 2));
			it_.reversed = num(o, "d", 1) == 3;
		case "sr";
			it_.kind = .Star;
			it_.star_type = cast(int)(num(o, "sy", 1));
			it_.p = load_prop(L, get(o, "p"), sub(DEF_ZERO, 0, 2));
			it_.pt = load_prop(L, get(o, "pt"), sub(DEF_ZERO, 0, 1));
			it_.r = load_prop(L, get(o, "r"), sub(DEF_ZERO, 0, 1));
			it_.or_ = load_prop(L, get(o, "or"), sub(DEF_ZERO, 0, 1));
			it_.os = load_prop(L, get(o, "os"), sub(DEF_ZERO, 0, 1));
			it_.ir = load_prop(L, get(o, "ir"), sub(DEF_ZERO, 0, 1));
			it_.is = load_prop(L, get(o, "is"), sub(DEF_ZERO, 0, 1));
			it_.reversed = num(o, "d", 1) == 3;
		case "fl"; #through; case "st"; #through; case "gf"; #through; case "gs";
			ty := str(o, "ty");
			it_.kind = ifx ty == "fl" then .Fill else ifx ty == "st" then .Stroke else ifx ty == "gf" then .Gradient_Fill else .Gradient_Stroke;
			it_.color = load_prop(L, get(o, "c"), view(DEF_ZERO));
			it_.opacity = load_prop(L, get(o, "o"), view(DEF_OPACITY));
			it_.width = load_prop(L, get(o, "w"), sub(DEF_ZERO, 0, 1));
			it_.evenodd = num(o, "r", 1) == 2;
			it_.cap = cast(int)(num(o, "lc", 2));
			it_.join = cast(int)(num(o, "lj", 2));
			it_.miter = num(o, "ml", 4);
			if ty == "gf" || ty == "gs" {
				it_.grad_type = cast(int)(num(o, "t", 1));
				it_.g_start = load_prop(L, get(o, "s"), sub(DEF_ZERO, 0, 2));
				it_.g_end = load_prop(L, get(o, "e"), sub(DEF_ZERO, 0, 2));
				it_.g_hl = load_prop(L, get(o, "h"), sub(DEF_ZERO, 0, 1));
				it_.g_ha = load_prop(L, get(o, "a"), sub(DEF_ZERO, 0, 1));
				{ go, has := get(o, "g").map, get(o, "g").kind == .Map;
				if has {
					it_.g_count = cast(int)(num(go, "p", 0));
					it_.g_colors = load_prop(L, get(go, "k"));
				} }
			}
		case "tm";
			it_.kind = .Trim;
			it_.t_start = load_prop(L, get(o, "s"), sub(DEF_ZERO, 0, 1));
			it_.t_end = load_prop(L, get(o, "e"), view(DEF_OPACITY));
			it_.t_off = load_prop(L, get(o, "o"), sub(DEF_ZERO, 0, 1));
			it_.t_mode = cast(int)(num(o, "m", 1));
		case;
			continue; // tr (handled by the group), mm, rp, ...
		}
		append(*out, it_);
	}
	return view(out);
}

load_layers :: (L: *Loader, arr: json.Array) -> []Layer {
	out := make_slice(Layer, len(arr), L.alloc);
	for e, i: arr {
		o, _ := e.map, e.kind == .Map;
		l := at(*out, i);
		l.ty = cast(int)(num(o, "ty", 3));
		l.ind = cast(int)(num(o, "ind", cast(float32)(i + 1)));
		l.parent = -1;
		{ pv, has := map_find(o, "parent");
		if has { l.parent = cast(int)(value_f32(pv, -1)); } }
		l.ip = num(o, "ip", 0);
		l.op = num(o, "op", 1000000000);
		l.st = num(o, "st", 0);
		l.sr = num(o, "sr", 1);
		if l.sr == 0 { l.sr = 1; }
		l.ks = load_transform(L, get(o, "ks"));
		l.hidden = num(o, "hd", 0) == 1;
		l.td = num(o, "td", 0) != 0;
		l.tt = cast(int)(num(o, "tt", 0));
		l.ref = -1;
		l.w = num(o, "w", 0);
		l.h = num(o, "h", 0);
		{ r := str(o, "refId");
		if r != "" {
			{ idx, ok := map_find(L.assets, r);
			if ok { l.ref = idx; } }
		} }
		if l.ty == 1 {
			l.w = num(o, "sw", 0);
			l.h = num(o, "sh", 0);
			l.solid_color = parse_hex(str(o, "sc"));
		}
		{ sh, ok := get(o, "shapes").list, get(o, "shapes").kind == .List;
		if ok { l.shapes = load_items(L, sh); } }
		{ ma, ok := get(o, "masksProperties").list, get(o, "masksProperties").kind == .List;
		if ok {
			l.masks = make_slice(Mask, len(ma), L.alloc);
			for m, j: ma {
				mo, _ := m.map, m.kind == .Map;
				mode := str(mo, "mode");
				l.masks[j] = Mask.{
					mode = ifx len(mode) > 0 then mode[0] else #char "a",
					inverted = num(mo, "inv", 0) == 1,
					path = load_shape_prop(L, get(mo, "pt")),
					opacity = load_prop(L, get(mo, "o"), view(DEF_OPACITY))
				};
			}
		} }
	}
	return out;
}

parse_hex :: (s: string) -> Vector4 {
	h := s;
	if len(h) > 0 && h[0] == #char "#" { h = sub_from(h, 1); }
	if len(h) < 6 { return .{0, 0, 0, 1}; }
	r, _ := strconv.parse_int(sub(h, 0, 2), 16);
	g, _ := strconv.parse_int(sub(h, 2, 4), 16);
	b, _ := strconv.parse_int(sub(h, 4, 6), 16);
	return .{cast(float32)(r) / 255, cast(float32)(g) / 255, cast(float32)(b) / 255, 1};
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
	for _: 0..7 {
		d := dbx(x1, x2, u);
		if abs(d) < 1.0e-6 { break; }
		e := bx(x1, x2, u) - x;
		if abs(e) < 1.0e-7 { return bx(y1, y2, u); }
		u -= e / d;
	}
	if u < 0 || u > 1 || abs(bx(x1, x2, u) - x) > 1.0e-5 {
		lo, hi: float32 = 0, 1;
		u = x;
		for _: 0..39 {
			v := bx(x1, x2, u);
			if abs(v - x) < 1.0e-7 { break; }
			if v < x { lo = u; } else { hi = u; }
			u = (lo + hi) / 2;
		}
	}
	return bx(y1, y2, u);
}

pick :: inline (a: []float32, i: int, def: float32) -> float32 {
	if len(a) == 0 { return def; }
	return a[min(i, len(a) - 1)];
};
#scope_export

// eval writes the property value at frame t into out (returns dims).
eval :: (p: *Prop, t: float32, out: []float32) -> int {
	if len(p.kfs) == 0 {
		n := min(len(p.value), len(out));
		copy(out, sub(p.value, 0, n));
		return n;
	}
	kfs := p.kfs;
	if t <= kfs[0].t || len(kfs) == 1 {
		n := min(len(kfs[0].s), len(out));
		copy(out, sub(kfs[0].s, 0, n));
		return n;
	}
	k := 0;
	while k + 1 < len(kfs) && t >= kfs[k + 1].t { k += 1; }
	a := *kfs[k];
	if k + 1 >= len(kfs) {
		// past the last keyframe: its start value (or the previous end value)
		src := ifx len(a.s) > 0 then a.s else (ifx k > 0 && len(kfs[k - 1].e) > 0 then kfs[k - 1].e else kfs[k - 1].s);
		n := min(len(src), len(out));
		copy(out, sub(src, 0, n));
		return n;
	}
	b := *kfs[k + 1];
	s := a.s;
	e := ifx len(a.e) > 0 then a.e else b.s;
	n := min(len(s), len(out));
	if a.hold || len(e) < n {
		copy(out, sub(s, 0, n));
		return n;
	}
	x := (t - a.t) / max(b.t - a.t, 1.0e-6);
	spatial := len(a.to) >= 2 && len(a.ti) >= 2 && n >= 2 && (a.to[0] != 0 || a.to[1] != 0 || a.ti[0] != 0 || a.ti[1] != 0);
	if spatial {
		u := bezier_ease(pick(a.ox, 0, 0), pick(a.oy, 0, 0), pick(a.ix, 0, 1), pick(a.iy, 0, 1), x);
		pt := spatial_point(s, e, a.to, a.ti, u);
		at(*out, 0).*, at(*out, 1).* = pt.x, pt.y;
		for d: 2..n-1 { at(*out, d).* = s[d] + (e[d] - s[d]) * u; }
		return n;
	}
	for d: 0..cast(int)(n)-1 {
		u := bezier_ease(pick(a.ox, d, 0), pick(a.oy, d, 0), pick(a.ix, d, 1), pick(a.iy, d, 1), x);
		at(*out, d).* = s[d] + (e[d] - s[d]) * u;
	}
	return n;
}
#scope_module

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
		lens[i] = lens[i - 1] + math.sqrt(d.x * d.x + d.y * d.y);
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
#scope_export

// eval_shape returns the path at frame t (vertex arrays allocated with alloc when interpolated).
eval_shape :: (p: *Shape_Prop, t: float32, alloc: Allocator) -> Shape_Data {
	if len(p.kfs) == 0 { return p.value; }
	kfs := p.kfs;
	if t <= kfs[0].t || len(kfs) == 1 { return kfs[0].s; }
	k := 0;
	while k + 1 < len(kfs) && t >= kfs[k + 1].t { k += 1; }
	a := *kfs[k];
	if k + 1 >= len(kfs) {
		if len(a.s.v) > 0 { return a.s; }
		return ifx k > 0 && kfs[k - 1].has_e then kfs[k - 1].e else kfs[k - 1].s;
	}
	b := *kfs[k + 1];
	e := ifx a.has_e then a.e else b.s;
	s := a.s;
	if a.hold || len(e.v) != len(s.v) { return s; }
	x := (t - a.t) / max(b.t - a.t, 1.0e-6);
	u := bezier_ease(a.ox, a.oy, a.ix, a.iy, x);
	n := len(s.v);
	out := Shape_Data.{
		v = make_slice(Vector2, n, alloc),
		i = make_slice(Vector2, n, alloc),
		o = make_slice(Vector2, n, alloc),
		closed = s.closed
	};
	for j: 0..cast(int)(n)-1 {
		out.v[j] = s.v[j] + (e.v[j] - s.v[j]) * u;
		out.i[j] = s.i[j] + (e.i[j] - s.i[j]) * u;
		out.o[j] = s.o[j] + (e.o[j] - s.o[j]) * u;
	}
	return out;
}

