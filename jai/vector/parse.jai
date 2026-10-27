// parse_svg parses an SVG document into a resolution-independent Icon.
parse_svg :: (src: string, allocator := context.allocator) -> Icon, bool {
	icon: Icon;
	icon.verbs.allocator = allocator;
	icon.points.allocator = allocator;
	icon.ops.allocator = allocator;
	icon.groups.allocator = allocator;
	icon.gradients.allocator = allocator;
	p := Parser.{icon = *icon, allocator = allocator};
	// Scratch for the XML tree and parser state. (After this, `allocator` names push_allocator's argument.)
	pool: Flat_Pool;
	defer fini(*pool);
	push_allocator(.{flat_pool_allocator_proc, *pool});
	if !xml_parse(src, *p.doc) return .{}, false;

	root := p.doc.nodes[0].first_child;
	while root >= 0 && p.doc.nodes[root].name != "svg"  root = p.doc.nodes[root].next;
	if root < 0 return .{}, false;
	vb, has := attr(*p.doc, root, "viewBox");
	if has {
		nums, got := scan_numbers(vb);
		if got == 4 && nums[2] > 0 && nums[3] > 0  icon.view_box = nums;
	}
	if icon.view_box[2] <= 0 {
		w := attr_length(*p, root, "width", 0);
		h := attr_length(*p, root, "height", 0);
		icon.view_box = .{0, 0, ifx w > 0 then w else 24, ifx h > 0 then h else 24};
	}
	st := DEFAULT_STYLE;
	apply_style(*p, root, *st);
	walk_children(*p, root, MAT_IDENTITY, st, -1);
	return icon, true;
}

#scope_module

Paint_Type :: enum u8 {
	None;
	Current;
	Color;
}

Paint :: struct {
	type: Paint_Type;
	color: [4]u8;
	gradient: bool;
	grad: s32; // index into Icon.gradients (valid when gradient)
}

Style :: struct {
	fill, stroke: Paint;
	fill_rule: Fill_Rule;
	clip_rule: Fill_Rule;
	fill_opacity: float32;
	stroke_opacity: float32;
	opacity: float32; // product of ancestor `opacity`
	stroke_width: float32;
	miter_limit: float32;
	cap: Line_Cap;
	join: Line_Join;
	secondary: bool;
	mask, clip: s32; // this element's own mask / clip-path
	anc_mask: s32; // nearest ancestor group's mask / clip-path (applied in anc_ctm space)
	anc_clip: s32;
	anc_ctm: Mat;
}

DEFAULT_STYLE :: Style.{
	fill = .{type = .Color, color = .[0, 0, 0, 255]},
	fill_opacity = 1,
	stroke_opacity = 1,
	opacity = 1,
	stroke_width = 1,
	miter_limit = 4,
	mask = -1,
	clip = -1,
	anc_mask = -1,
	anc_clip = -1,
	anc_ctm = MAT_IDENTITY
};

Parser :: struct {
	doc: Doc;
	icon: *Icon;
	groups: Table(s32, s32); // mask/clip node -> group index (-2 = in progress)
	grads: Table(s32, s32); // gradient node -> index in icon.gradients
	depth: int;
	allocator: Allocator; // the icon's allocator
}

// Odin's strings.trim_space set.
SPACES :: " \t\n\r\x0b\x0c";

// Up to four numbers (a viewBox); returns how many were read.
scan_numbers :: (s: string) -> Vector4, int {
	nums: Vector4;
	sc := Scanner.{s = s};
	got := 0;
	while got < 4 {
		v, ok := scan_number(*sc);
		if !ok break;
		nums[got] = v;
		got += 1;
	}
	return nums, got;
}

walk_children :: (p: *Parser, ni: s32, ctm: Mat, st: Style, group: s32) {
	c := p.doc.nodes[ni].first_child;
	while c >= 0 {
		walk(p, c, ctm, st, group);
		c = p.doc.nodes[c].next;
	}
}

walk :: (p: *Parser, ni: s32, parent_ctm: Mat, parent_st: Style, group: s32) {
	if p.depth > 64 return;
	p.depth += 1;
	defer p.depth -= 1;
	name := local_name(p.doc.nodes[ni].name);
	if name == {
		case "defs"; #through; case "mask"; #through; case "clipPath"; #through; case "linearGradient"; #through;
		case "radialGradient"; #through; case "symbol"; #through; case "style"; #through; case "title"; #through;
		case "desc"; #through; case "metadata"; #through; case "pattern"; #through; case "filter"; #through;
		case "marker"; #through; case "text";
			return;
	}
	display, has_display := attr(*p.doc, ni, "display");
	if has_display && display == "none" return;
	st := parent_st;
	apply_style(p, ni, *st);
	ctm := parent_ctm;
	tr, has_tr := attr(*p.doc, ni, "transform");
	if has_tr  ctm = mat_mul(ctm, parse_transform(tr));

	if name == {
	case "svg"; #through; case "g"; #through; case "a"; #through; case "switch";
		if name == "svg" && ni != p.doc.nodes[0].first_child {
			// Nested viewport: translate(x, y) then map its viewBox onto width x height.
			x := attr_length(p, ni, "x", 0);
			y := attr_length(p, ni, "y", 0);
			ctm = mat_mul(ctm, .[1, 0, 0, 1, x, y]);
			vb, has := attr(*p.doc, ni, "viewBox");
			if has {
				nums, got := scan_numbers(vb);
				w := attr_length(p, ni, "width", nums[2]);
				h := attr_length(p, ni, "height", nums[3]);
				if got == 4 && nums[2] > 0 && nums[3] > 0 {
					sx := w / nums[2];
					sy := h / nums[3];
					tx, ty: float32;
					par := attr(*p.doc, ni, "preserveAspectRatio");
					if !begins_with(par, "none") {
						s := min(sx, sy); // xMidYMid meet
						tx = (w - nums[2] * s) / 2;
						ty = (h - nums[3] * s) / 2;
						sx = s;
						sy = s;
					}
					ctm = mat_mul(ctm, .[sx, 0, 0, sy, tx - nums[0] * sx, ty - nums[1] * sy]);
				}
			}
		}
		cst := st;
		if st.clip >= 0 || st.mask >= 0 {
			// a group's clip/mask applies to every descendant, in the group's user space
			if st.clip >= 0  cst.anc_clip = st.clip;
			if st.mask >= 0  cst.anc_mask = st.mask;
			cst.anc_ctm = ctm;
		}
		walk_children(p, ni, ctm, cst, group);
	case "use";
		ref, found := href_target(p, ni);
		if !found return;
		x := attr_length(p, ni, "x", 0);
		y := attr_length(p, ni, "y", 0);
		walk(p, ref, mat_mul(ctm, .[1, 0, 0, 1, x, y]), st, group);
	case "path"; #through; case "rect"; #through; case "circle"; #through; case "ellipse"; #through;
	case "line"; #through; case "polyline"; #through; case "polygon";
		emit_shape(p, ni, name, ctm, st, group);
	}
}

// The node an href / xlink:href="#id" points at.
href_target :: (p: *Parser, ni: s32) -> s32, bool {
	href, has := attr(*p.doc, ni, "href");
	if !has  href, has = attr(*p.doc, ni, "xlink:href");
	if !has || !begins_with(href, "#") return -1, false;
	found, ref := table_find(*p.doc.ids, advance(href, 1));
	return ref, found;
}

local_name :: (s: string) -> string {
	found, _, right := split_from_left(s, #char ":");
	return ifx found then right else s;
}

Decl :: struct {
	key, value: string;
}

// The "key: value" declarations of a style attribute.
style_decls :: (s: string) -> [..]Decl {
	out: [..]Decl;
	for split(s, ";") {
		found, k, v := split_from_left(it, #char ":");
		if found  array_add(*out, .{trim(k, SPACES), trim(v, SPACES)});
	}
	return out;
}

apply_style :: (p: *Parser, ni: s32, st: *Style) {
	st.mask = -1; // mask/clip-path are not inherited; groups pass theirs down below
	st.clip = -1;
	for p.doc.nodes[ni].attrs  style_prop(p, st, it.name, it.value);
	s, has := attr(*p.doc, ni, "style");
	if has  for style_decls(s)  style_prop(p, st, it.key, it.value);
}

style_prop :: (p: *Parser, st: *Style, name: string, value: string) {
	if name == {
	case "fill";           st.fill = parse_paint(p, value, st.fill);
	case "stroke";         st.stroke = parse_paint(p, value, st.stroke);
	case "fill-rule";      st.fill_rule = ifx value == "evenodd" then .Evenodd else .Nonzero;
	case "clip-rule";      st.clip_rule = ifx value == "evenodd" then .Evenodd else .Nonzero;
	case "fill-opacity";   st.fill_opacity = parse_opacity(value);
	case "stroke-opacity"; st.stroke_opacity = parse_opacity(value);
	case "opacity";        st.opacity *= parse_opacity(value);
	case "stroke-width";
		sc := Scanner.{s = value};
		v, ok := scan_number(*sc);
		if ok  st.stroke_width = v;
	case "stroke-miterlimit";
		sc := Scanner.{s = value};
		v, ok := scan_number(*sc);
		if ok  st.miter_limit = max(v, 1);
	case "stroke-linecap";
		st.cap = ifx value == "round" then .Round else ifx value == "square" then .Square else .Butt;
	case "stroke-linejoin";
		st.join = ifx value == "round" then .Round else ifx value == "bevel" then .Bevel else .Miter;
	case "class";
		// whitespace-separated class names
		i := 0;
		while i < value.count {
			while i < value.count && is_any(value[i], SPACES)  i += 1;
			j := i;
			while j < value.count && !is_any(value[j], SPACES)  j += 1;
			if slice(value, i, j - i) == "secondary"  st.secondary = true;
			i = j;
		}
	case "mask";      st.mask = resolve_group(p, value, .Mask);
	case "clip-path"; st.clip = resolve_group(p, value, .Clip);
	}
}

is_any :: inline (c: u8, set: string) -> bool {
	for cast([]u8) set if it == c return true;
	return false;
}

// A number with an optional trailing %: the number, whether it had the %, ok.
scan_percent :: (v: string) -> float32, bool, bool {
	sc := Scanner.{s = v};
	x, ok := scan_number(*sc);
	return x, ok && sc.i < v.count && v[sc.i] == #char "%", ok;
}

parse_opacity :: (v: string) -> float32 {
	x, pct, ok := scan_percent(v);
	if !ok return 1;
	if pct  x /= 100;
	return clamp(x, 0, 1);
}

url_id :: (v: string) -> string, bool {
	s := trim(v, SPACES);
	if !begins_with(s, "url(") return "", false;
	e := find_index_from_left(s, #char ")");
	if e < 0 return "", false;
	id := trim(slice(s, 4, e - 4), " '\"");
	if !begins_with(id, "#") return "", false;
	return advance(id, 1), true;
}

parse_paint :: (p: *Parser, v: string, inherited: Paint) -> Paint {
	s := trim(v, SPACES);
	if s == {
		case "none"; #through;
		case "transparent";  return .{type = .None};
		case "currentColor"; #through;
		case "currentcolor"; return .{type = .Current};
		case "inherit";      return inherited;
	}
	id, ok := url_id(s);
	if !ok return .{type = .Color, color = parse_color(s)};
	found, ref := table_find(*p.doc.ids, id);
	if !found return .{type = .None};
	gi := build_gradient(p, ref);
	if gi < 0 return .{type = .None};
	g := *p.icon.gradients[gi];
	if g.stops.count == 0 return .{type = .None};
	sum: Vector4;
	for g.stops  sum += it.color;
	avg := sum / cast(float32) g.stops.count;
	out := Paint.{type = .Color, gradient = true, grad = gi};
	for j: 0..3  out.color[j] = cast(u8) (clamp(avg[j], 0, 1) * 255 + 0.5);
	return out;
}

parse_color :: (v: string) -> [4]u8 {
	s := trim(v, SPACES);
	hex :: (c: u8) -> u8 {
		if c >= #char "0" && c <= #char "9" return c - #char "0";
		if c >= #char "a" && c <= #char "f" return c - #char "a" + 10;
		if c >= #char "A" && c <= #char "F" return c - #char "A" + 10;
		return 0;
	}
	out := u8.[0, 0, 0, 255];
	if begins_with(s, "#") {
		h := advance(s, 1);
		if h.count == {
			case 3; #through;
			case 4; for j: 0..h.count-1  out[j] = hex(h[j]) * 17;
			case 6; #through;
			case 8; for j: 0..h.count/2-1  out[j] = (hex(h[2 * j]) << 4) | hex(h[2 * j + 1]);
		}
		return out;
	}
	if begins_with(s, "rgb") {
		o := find_index_from_left(s, #char "(");
		if o >= 0 {
			sc := Scanner.{s = advance(s, o + 1)};
			for j: 0..3 {
				x, ok := scan_number(*sc);
				if !ok break;
				pct := sc.i < sc.s.count && sc.s[sc.i] == #char "%";
				if pct  sc.i += 1;
				if j == 3  out[3] = cast(u8) (clamp(ifx pct then x / 100 else x, 0, 1) * 255 + 0.5);
				else       out[j] = cast(u8) (clamp(ifx pct then x * 2.55 else x, 0, 255) + 0.5);
			}
			return out;
		}
	}
	if to_lower_copy(s) == {
		case "white"; return .[255, 255, 255, 255];
		case "red";   return .[255, 0, 0, 255];
		case "green"; return .[0, 128, 0, 255];
		case "blue";  return .[0, 0, 255, 255];
		case "gray"; #through;
		case "grey";  return .[128, 128, 128, 255];
	}
	return out;
}

luminance :: (c: [4]u8) -> float32 {
	// mask-type: luminance (linearRGB coefficients on sRGB values, as browsers do).
	return (0.2125 * cast(float32) c[0] + 0.7154 * cast(float32) c[1] + 0.0721 * cast(float32) c[2]) / 255 * cast(float32) c[3] / 255;
}

// attr_length parses a length attribute; % is relative to the root view box.
attr_length :: (p: *Parser, ni: s32, name: string, def: float32 = 0) -> float32 {
	v, has := attr(*p.doc, ni, name);
	if !has return def;
	x, pct, ok := scan_percent(v);
	if !ok return def;
	if !pct return x;
	vb := p.icon.view_box;
	horizontal := name == "x" || name == "width" || name == "cx" || name == "rx" || name == "x1" || name == "x2";
	ref := ifx vb[2] > 0 then (ifx horizontal then vb[2] else vb[3]) else 0;
	return x / 100 * ref;
}

resolve_group :: (p: *Parser, v: string, kind: Group_Kind) -> s32 {
	id, ok := url_id(v);
	if !ok return -1;
	found, ni := table_find(*p.doc.ids, id);
	if !found return -1;
	want := ifx kind == .Mask then "mask" else "clipPath";
	if local_name(p.doc.nodes[ni].name) != want return -1;
	cached, cgi := table_find(*p.groups, ni);
	if cached return ifx cgi < 0 then -1 else cgi;
	table_set(*p.groups, ni, -2); // recursion guard
	gi := cast(s32) p.icon.groups.count;
	g := Group.{kind = kind};
	if kind == .Mask {
		g.region_bbox_units = attr(*p.doc, ni, "maskUnits") != "userSpaceOnUse";
		g.content_bbox_units = attr(*p.doc, ni, "maskContentUnits") == "objectBoundingBox";
		frac :: (p: *Parser, ni: s32, name: string, def: float32) -> float32 {
			v, has := attr(*p.doc, ni, name);
			if !has return def;
			x, pct, ok := scan_percent(v);
			if !ok return def;
			return ifx pct then x / 100 else x;
		}
		vb := p.icon.view_box;
		if g.region_bbox_units {
			g.region = .{frac(p, ni, "x", -0.1), frac(p, ni, "y", -0.1), frac(p, ni, "width", 1.2), frac(p, ni, "height", 1.2)};
		} else {
			g.region = .{
				attr_length(p, ni, "x", vb[0] - 0.1 * vb[2]),
				attr_length(p, ni, "y", vb[1] - 0.1 * vb[3]),
				attr_length(p, ni, "width", 1.2 * vb[2]),
				attr_length(p, ni, "height", 1.2 * vb[3])
			};
		}
	} else {
		g.content_bbox_units = attr(*p.doc, ni, "clipPathUnits") == "objectBoundingBox";
	}
	array_add(*p.icon.groups, g);
	ctm := MAT_IDENTITY;
	t, has := attr(*p.doc, ni, "transform");
	if has && kind == .Clip  ctm = parse_transform(t);
	saved := p.depth;
	walk_children(p, ni, ctm, DEFAULT_STYLE, gi);
	p.depth = saved;
	table_set(*p.groups, ni, gi);
	return gi;
}

emit_shape :: (p: *Parser, ni: s32, name: string, ctm: Mat, st: Style, group: s32) {
	icon := p.icon;
	fv := cast(s32) icon.verbs.count;
	fp := cast(s32) icon.points.count;
	b := Builder.{icon = icon};
	if name == {
	case "path";
		d, has := attr(*p.doc, ni, "d");
		if has  parse_path(*b, d);
	case "rect";
		x, y := attr_length(p, ni, "x"), attr_length(p, ni, "y");
		w, h := attr_length(p, ni, "width"), attr_length(p, ni, "height");
		if w <= 0 || h <= 0 return;
		_, has_rx := attr(*p.doc, ni, "rx");
		_, has_ry := attr(*p.doc, ni, "ry");
		rx, ry := attr_length(p, ni, "rx"), attr_length(p, ni, "ry");
		if has_rx && !has_ry  ry = rx;
		if has_ry && !has_rx  rx = ry;
		add_round_rect(*b, x, y, w, h, clamp(rx, 0, w / 2), clamp(ry, 0, h / 2));
	case "circle";
		r := attr_length(p, ni, "r");
		if r <= 0 return;
		add_ellipse(*b, attr_length(p, ni, "cx"), attr_length(p, ni, "cy"), r, r);
	case "ellipse";
		rx, ry := attr_length(p, ni, "rx"), attr_length(p, ni, "ry");
		if rx <= 0 || ry <= 0 return;
		add_ellipse(*b, attr_length(p, ni, "cx"), attr_length(p, ni, "cy"), rx, ry);
	case "line";
		move_to(*b, .{attr_length(p, ni, "x1"), attr_length(p, ni, "y1")});
		line_to(*b, .{attr_length(p, ni, "x2"), attr_length(p, ni, "y2")});
	case "polyline"; #through; case "polygon";
		sc := Scanner.{s = attr(*p.doc, ni, "points")};
		first := true;
		while true {
			x, okx := scan_number(*sc);
			if !okx break;
			y, oky := scan_number(*sc);
			if !oky break;
			if first  move_to(*b, .{x, y});
			else      line_to(*b, .{x, y});
			first = false;
		}
		if name == "polygon" && !first  close_path(*b);
	}
	vc := cast(s32) icon.verbs.count - fv;
	if vc == 0 return;
	bbox := Vector4.{FLOAT32_MAX, FLOAT32_MAX, -FLOAT32_MAX, -FLOAT32_MAX};
	for * pt: array_view(icon.points, fp) {
		bbox = .{min(bbox[0], pt.x), min(bbox[1], pt.y), max(bbox[2], pt.x), max(bbox[3], pt.y)};
		pt.* = mat_apply(ctm, pt.*);
	}
	if bbox[0] > bbox[2]  bbox = .{};
	base := Op.{
		first_verb = fv,
		verb_count = vc,
		first_point = fp,
		layer = ifx st.secondary then .Secondary else .Primary,
		cap = st.cap,
		join = st.join,
		miter_limit = st.miter_limit,
		group = group,
		mask = st.mask,
		clip = st.clip,
		ctm = ctm,
		bbox = bbox,
		gradient = -1,
		anc_mask = st.anc_mask,
		anc_clip = st.anc_clip,
		anc_ctm = st.anc_ctm
	};
	if st.secondary  icon.has_secondary = true;
	if group >= 0 && icon.groups[group].kind == .Clip {
		op := base;
		op.kind = .Fill;
		op.rule = st.clip_rule;
		op.alpha = 1;
		op.luminance = 1;
		op.current_color = true;
		array_add(*icon.ops, op);
		return;
	}
	add_paint :: (icon: *Icon, base: Op, kind: Paint_Kind, paint: Paint, alpha: float32, st: Style) {
		if paint.type == .None || alpha <= 0 return;
		op := base;
		op.kind = kind;
		op.rule = st.fill_rule;
		op.alpha = alpha;
		op.stroke_width = st.stroke_width;
		if paint.type == .Current {
			op.current_color = true;
			op.luminance = 0; // currentColor defaults to black
		} else {
			op.color = paint.color;
			op.alpha *= cast(float32) paint.color[3] / 255;
			if paint.gradient {
				op.gradient = paint.grad;
				op.grad_fold = cast(float32) paint.color[3] / 255;
			}
			c := paint.color;
			c[3] = 255;
			op.luminance = luminance(c);
			if op.group < 0  icon.multicolor = true;
		}
		array_add(*icon.ops, op);
	}
	add_paint(icon, base, .Fill, st.fill, st.fill_opacity * st.opacity, st);
	if st.stroke_width > 0  add_paint(icon, base, .Stroke, st.stroke, st.stroke_opacity * st.opacity, st);
}

// ---- path building ----

Builder :: struct {
	icon: *Icon;
	start: Vector2;
	cur: Vector2;
	ctrl: Vector2; // last control point (for S / T reflection)
	last: u8; // last command, upper-cased
	open: bool; // a subpath has been started
	need_move: bool; // after Z: implicit moveto to start
}

move_to :: (b: *Builder, p: Vector2) {
	array_add(*b.icon.verbs, Verb.Move);
	array_add(*b.icon.points, p);
	b.start = p;
	b.cur = p;
	b.open = true;
	b.need_move = false;
}

add_verb :: (b: *Builder, v: Verb, pts: ..Vector2) {
	if !b.open || b.need_move  move_to(b, b.cur);
	array_add(*b.icon.verbs, v);
	array_add(*b.icon.points, ..pts);
	b.cur = peek(pts);
}

line_to :: (b: *Builder, p: Vector2) { add_verb(b, .Line, p); }
quad_to :: (b: *Builder, c: Vector2, p: Vector2) { add_verb(b, .Quad, c, p); }
cubic_to :: (b: *Builder, c1: Vector2, c2: Vector2, p: Vector2) { add_verb(b, .Cubic, c1, c2, p); }

close_path :: (b: *Builder) {
	if !b.open || b.need_move return;
	array_add(*b.icon.verbs, Verb.Close);
	b.cur = b.start;
	b.need_move = true;
}

KAPPA :: 0.5522847498;

add_ellipse :: (b: *Builder, cx: float32, cy: float32, rx: float32, ry: float32) {
	kx := rx * cast(float32) KAPPA;
	ky := ry * cast(float32) KAPPA;
	move_to(b, .{cx + rx, cy});
	cubic_to(b, .{cx + rx, cy + ky}, .{cx + kx, cy + ry}, .{cx, cy + ry});
	cubic_to(b, .{cx - kx, cy + ry}, .{cx - rx, cy + ky}, .{cx - rx, cy});
	cubic_to(b, .{cx - rx, cy - ky}, .{cx - kx, cy - ry}, .{cx, cy - ry});
	cubic_to(b, .{cx + kx, cy - ry}, .{cx + rx, cy - ky}, .{cx + rx, cy});
	close_path(b);
}

add_round_rect :: (b: *Builder, x: float32, y: float32, w: float32, h: float32, rx: float32, ry: float32) {
	if rx <= 0 || ry <= 0 {
		move_to(b, .{x, y});
		line_to(b, .{x + w, y});
		line_to(b, .{x + w, y + h});
		line_to(b, .{x, y + h});
		close_path(b);
		return;
	}
	kx := rx * cast(float32) (1 - KAPPA);
	ky := ry * cast(float32) (1 - KAPPA);
	r := x + w;
	btm := y + h;
	move_to(b, .{x + rx, y});
	line_to(b, .{r - rx, y});
	cubic_to(b, .{r - kx, y}, .{r, y + ky}, .{r, y + ry});
	line_to(b, .{r, btm - ry});
	cubic_to(b, .{r, btm - ky}, .{r - kx, btm}, .{r - rx, btm});
	line_to(b, .{x + rx, btm});
	cubic_to(b, .{x + kx, btm}, .{x, btm - ky}, .{x, btm - ry});
	line_to(b, .{x, y + ry});
	cubic_to(b, .{x, y + ky}, .{x + kx, y}, .{x + rx, y});
	close_path(b);
}

// arc_to appends an SVG elliptical arc (endpoint parameterization) as cubics.
arc_to :: (b: *Builder, rx_in: float32, ry_in: float32, phi_deg: float32, large: bool, sweep: bool, p: Vector2) {
	p0 := b.cur;
	if p0 == p return;
	rx := abs(cast(float64) rx_in);
	ry := abs(cast(float64) ry_in);
	if rx == 0 || ry == 0 {
		line_to(b, p);
		return;
	}
	phi := cast(float64) phi_deg * PI64 / 180;
	cs := cos(phi);
	sn := sin(phi);
	x1, y1 := cast(float64) p0.x, cast(float64) p0.y;
	x2, y2 := cast(float64) p.x, cast(float64) p.y;
	dx2 := (x1 - x2) / 2;
	dy2 := (y1 - y2) / 2;
	x1p := cs * dx2 + sn * dy2;
	y1p := -sn * dx2 + cs * dy2;
	lambda := x1p * x1p / (rx * rx) + y1p * y1p / (ry * ry);
	if lambda > 1 {
		s := sqrt(lambda);
		rx *= s;
		ry *= s;
	}
	num := rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p;
	den := rx * rx * y1p * y1p + ry * ry * x1p * x1p;
	coef := ifx den > 0 then sqrt(max(num / den, 0)) else 0;
	if large == sweep  coef = -coef;
	cxp := coef * rx * y1p / ry;
	cyp := -coef * ry * x1p / rx;
	cx := cs * cxp - sn * cyp + (x1 + x2) / 2;
	cy := sn * cxp + cs * cyp + (y1 + y2) / 2;
	angle :: (ux: float64, uy: float64, vx: float64, vy: float64) -> float64 {
		return atan2(ux * vy - uy * vx, ux * vx + uy * vy);
	}
	ux := (x1p - cxp) / rx;
	uy := (y1p - cyp) / ry;
	vx := (-x1p - cxp) / rx;
	vy := (-y1p - cyp) / ry;
	theta1 := angle(1, 0, ux, uy);
	dtheta := angle(ux, uy, vx, vy);
	if !sweep && dtheta > 0  dtheta -= 2 * PI64;
	if sweep && dtheta < 0   dtheta += 2 * PI64;
	n := max(1, cast(int) ceil(abs(dtheta) / (PI64 / 2) - 1.0e-9));
	d := dtheta / cast(float64) n;
	k := 4.0 / 3.0 * tan(d / 4);
	for i: 0..n-1 {
		t1 := theta1 + cast(float64) i * d;
		t2 := t1 + d;
		// the ellipse's points (a, e) and derivatives (da, de) at t1, t2
		ax, ay := cx + rx * cos(t1) * cs - ry * sin(t1) * sn, cy + rx * cos(t1) * sn + ry * sin(t1) * cs;
		ex, ey := cx + rx * cos(t2) * cs - ry * sin(t2) * sn, cy + rx * cos(t2) * sn + ry * sin(t2) * cs;
		dax, day := -rx * sin(t1) * cs - ry * cos(t1) * sn, -rx * sin(t1) * sn + ry * cos(t1) * cs;
		dex, dey := -rx * sin(t2) * cs - ry * cos(t2) * sn, -rx * sin(t2) * sn + ry * cos(t2) * cs;
		end := ifx i == n - 1 then p else Vector2.{xx ex, xx ey};
		cubic_to(b, .{xx (ax + k * dax), xx (ay + k * day)}, .{xx (ex - k * dex), xx (ey - k * dey)}, end);
	}
}

// ---- number scanning ----

Scanner :: struct {
	s: string;
	i: int;
}

skip_sep :: (sc: *Scanner) {
	while sc.i < sc.s.count && is_space(sc.s[sc.i])  sc.i += 1;
	if sc.i < sc.s.count && sc.s[sc.i] == #char "," {
		sc.i += 1;
		while sc.i < sc.s.count && is_space(sc.s[sc.i])  sc.i += 1;
	}
}

scan_number :: (sc: *Scanner) -> float32, bool {
	skip_sep(sc);
	s := sc.s;
	i := sc.i;
	st := i;
	is_digit :: (s: string, i: int) -> bool { return i < s.count && s[i] >= #char "0" && s[i] <= #char "9"; }
	if i < s.count && (s[i] == #char "+" || s[i] == #char "-")  i += 1;
	digits := 0;
	while is_digit(s, i) { i += 1; digits += 1; }
	if i < s.count && s[i] == #char "." {
		i += 1;
		while is_digit(s, i) { i += 1; digits += 1; }
	}
	if digits == 0 return 0, false;
	if i < s.count && (s[i] == #char "e" || s[i] == #char "E") {
		j := i + 1;
		if j < s.count && (s[j] == #char "+" || s[j] == #char "-")  j += 1;
		if is_digit(s, j) {
			while is_digit(s, j)  j += 1;
			i = j;
		}
	}
	v, ok, rest := string_to_float64(slice(s, st, i - st));
	if !ok || rest.count return 0, false;
	sc.i = i;
	return cast(float32) v, true;
}

scan_flag :: (sc: *Scanner) -> bool, bool {
	skip_sep(sc);
	if sc.i < sc.s.count && (sc.s[sc.i] == #char "0" || sc.s[sc.i] == #char "1") {
		f := sc.s[sc.i] == #char "1";
		sc.i += 1;
		return f, true;
	}
	return false, false;
}

// parse_path appends path data; on a syntax error the path so far is kept (as browsers do).
parse_path :: (b: *Builder, d: string) {
	sc := Scanner.{s = d};
	cmd: u8 = 0;
	// Reads n numbers into a; false when one is missing.
	nums :: (sc: *Scanner, a: []float32) -> bool {
		for * a {
			v, ok := scan_number(sc);
			if !ok return false;
			it.* = v;
		}
		return true;
	}
	a: [6]float32;
	while true {
		skip_sep(*sc);
		if sc.i >= d.count return;
		c := d[sc.i];
		if (c >= #char "A" && c <= #char "Z") || (c >= #char "a" && c <= #char "z") {
			cmd = c;
			sc.i += 1;
		} else if cmd == 0 || cmd == #char "Z" || cmd == #char "z" {
			return;
		}
		rel := cmd >= #char "a";
		up := ifx rel then cmd - 32 else cmd;
		o := ifx rel then b.cur else Vector2.{0, 0};
		if up == {
		case #char "M";
			if !nums(*sc, array_view(a, 0, 2)) return;
			move_to(b, o + Vector2.{a[0], a[1]});
			cmd = cast(u8) ifx rel then #char "l" else #char "L";
		case #char "L";
			if !nums(*sc, array_view(a, 0, 2)) return;
			line_to(b, o + Vector2.{a[0], a[1]});
		case #char "H";
			if !nums(*sc, array_view(a, 0, 1)) return;
			line_to(b, .{ifx rel then b.cur.x + a[0] else a[0], b.cur.y});
		case #char "V";
			if !nums(*sc, array_view(a, 0, 1)) return;
			line_to(b, .{b.cur.x, ifx rel then b.cur.y + a[0] else a[0]});
		case #char "C";
			if !nums(*sc, a) return;
			c2 := o + Vector2.{a[2], a[3]};
			cubic_to(b, o + Vector2.{a[0], a[1]}, c2, o + Vector2.{a[4], a[5]});
			b.ctrl = c2;
		case #char "S";
			if !nums(*sc, array_view(a, 0, 4)) return;
			c1 := ifx b.last == #char "C" || b.last == #char "S" then 2 * b.cur - b.ctrl else b.cur;
			c2 := o + Vector2.{a[0], a[1]};
			cubic_to(b, c1, c2, o + Vector2.{a[2], a[3]});
			b.ctrl = c2;
		case #char "Q";
			if !nums(*sc, array_view(a, 0, 4)) return;
			c1 := o + Vector2.{a[0], a[1]};
			quad_to(b, c1, o + Vector2.{a[2], a[3]});
			b.ctrl = c1;
		case #char "T";
			if !nums(*sc, array_view(a, 0, 2)) return;
			c1 := ifx b.last == #char "Q" || b.last == #char "T" then 2 * b.cur - b.ctrl else b.cur;
			quad_to(b, c1, o + Vector2.{a[0], a[1]});
			b.ctrl = c1;
		case #char "A";
			ok := nums(*sc, array_view(a, 0, 3));
			large, lok := scan_flag(*sc);
			sweep, sok := scan_flag(*sc);
			ok = nums(*sc, array_view(a, 3, 2)) && ok;
			if !ok || !lok || !sok return;
			arc_to(b, a[0], a[1], a[2], large, sweep, o + Vector2.{a[3], a[4]});
		case #char "Z";
			close_path(b);
		case;
			return;
		}
		b.last = up;
	}
}

// parse_transform parses an SVG transform list into one matrix.
parse_transform :: (s: string) -> Mat {
	m := MAT_IDENTITY;
	i := 0;
	while i < s.count {
		while i < s.count && (is_space(s[i]) || s[i] == #char ",")  i += 1;
		ns := i;
		while i < s.count && ((s[i] >= #char "a" && s[i] <= #char "z") || (s[i] >= #char "A" && s[i] <= #char "Z"))  i += 1;
		name := slice(s, ns, i - ns);
		while i < s.count && is_space(s[i])  i += 1;
		if i >= s.count || s[i] != #char "(" return m;
		e := find_index_from_left(s, #char ")", i) - i;
		if e < 0 return m;
		sc := Scanner.{s = slice(s, i + 1, e - 1)};
		i += e + 1;
		a: [6]float32;
		n := 0;
		while n < 6 {
			v, ok := scan_number(*sc);
			if !ok break;
			a[n] = v;
			n += 1;
		}
		t := MAT_IDENTITY;
		if name == {
		case "matrix";    if n == 6  t = a;
		case "translate"; t = .[1, 0, 0, 1, a[0], ifx n > 1 then a[1] else 0];
		case "scale";     t = .[a[0], 0, 0, ifx n > 1 then a[1] else a[0], 0, 0];
		case "rotate";
			r := a[0] * PI / 180;
			c := cos(r);
			sn := sin(r);
			t = .[c, sn, -sn, c, 0, 0];
			if n == 3  t = mat_mul(mat_mul(.[1, 0, 0, 1, a[1], a[2]], t), .[1, 0, 0, 1, -a[1], -a[2]]);
		case "skewX"; t = .[1, 0, tan(a[0] * PI / 180), 1, 0, 0];
		case "skewY"; t = .[1, tan(a[0] * PI / 180), 0, 1, 0, 0];
		case; return m;
		}
		m = mat_mul(m, t);
	}
	return m;
}

// Gradient attribute chain: own attribute, else inherited through href.
grad_attr :: (p: *Parser, ni: s32, name: string) -> string, bool {
	n := ni;
	for 0..7 {
		v, has := attr(*p.doc, n, name);
		if has return v, true;
		next, found := href_target(p, n);
		if !found break;
		n = next;
	}
	return "", false;
}

build_gradient :: (p: *Parser, ni: s32) -> s32 {
	cached, cgi := table_find(*p.grads, ni);
	if cached return cgi;
	kind := local_name(p.doc.nodes[ni].name);
	if kind != "linearGradient" && kind != "radialGradient" return -1;
	g := Gradient.{radial = kind == "radialGradient", transform = MAT_IDENTITY};
	g.bbox_units = grad_attr(p, ni, "gradientUnits") != "userSpaceOnUse";
	t, has_t := grad_attr(p, ni, "gradientTransform");
	if has_t  g.transform = parse_transform(t);
	sm, has_sm := grad_attr(p, ni, "spreadMethod");
	if has_sm  g.spread = ifx sm == "reflect" then .Reflect else ifx sm == "repeat" then .Repeat else .Pad;
	bb := g.bbox_units;
	vb := p.icon.view_box;
	diag := sqrt((vb[2] * vb[2] + vb[3] * vb[3]) / 2);
	// A coordinate; % is relative to the bbox (bbox units) or else to ref (view box width, height or diagonal).
	coord :: (p: *Parser, ni: s32, name: string, def: float32, bb: bool, ref: float32) -> float32 {
		v, has := grad_attr(p, ni, name);
		if !has return def;
		x, pct, ok := scan_percent(v);
		if !ok return def;
		if pct {
			x /= 100;
			if !bb  x *= ref;
		}
		return x;
	}
	pct :: (bb: bool, v: float32, ref: float32) -> float32 { return ifx bb then v else v * ref; }
	W, H := vb[2], vb[3];
	if !g.radial {
		g.p0 = .{coord(p, ni, "x1", 0, bb, W), coord(p, ni, "y1", 0, bb, H)};
		g.p1 = .{coord(p, ni, "x2", pct(bb, 1, W), bb, W), coord(p, ni, "y2", 0, bb, H)};
	} else {
		g.p0 = .{coord(p, ni, "cx", pct(bb, 0.5, W), bb, W), coord(p, ni, "cy", pct(bb, 0.5, H), bb, H)};
		g.r = coord(p, ni, "r", pct(bb, 0.5, diag), bb, diag);
		g.p1 = .{coord(p, ni, "fx", g.p0.x, bb, W), coord(p, ni, "fy", g.p0.y, bb, H)};
		g.fr = coord(p, ni, "fr", 0, bb, diag);
	}
	// stops: first gradient in the href chain that has any
	stops: [..]Gradient_Stop;
	stops.allocator = p.allocator;
	n := ni;
	for 0..7 {
		c := p.doc.nodes[n].first_child;
		while c >= 0 {
			defer c = p.doc.nodes[c].next;
			if local_name(p.doc.nodes[c].name) != "stop" continue;
			col := u8.[0, 0, 0, 255];
			op: float32 = 1;
			off: float32 = 0;
			ov, has_off := attr(*p.doc, c, "offset");
			if has_off {
				x, pct, ok := scan_percent(ov);
				if ok  off = ifx pct then x / 100 else x;
			}
			sc, has_sc := attr(*p.doc, c, "stop-color");
			if has_sc  col = parse_color(sc);
			so, has_so := attr(*p.doc, c, "stop-opacity");
			if has_so  op = parse_opacity(so);
			sv, has_style := attr(*p.doc, c, "style");
			if has_style  for style_decls(sv) {
				if it.key == "stop-color"    col = parse_color(it.value);
				if it.key == "stop-opacity"  op = parse_opacity(it.value);
			}
			off = clamp(off, 0, 1);
			if stops.count > 0  off = max(off, peek(stops).offset);
			array_add(*stops, .{off, .{cast(float32) col[0] / 255, cast(float32) col[1] / 255, cast(float32) col[2] / 255, cast(float32) col[3] / 255 * op}});
		}
		if stops.count > 0 break;
		next, found := href_target(p, n);
		if !found break;
		n = next;
	}
	g.stops = stops;
	gi := cast(s32) p.icon.gradients.count;
	array_add(*p.icon.gradients, g);
	table_set(*p.grads, ni, gi);
	return gi;
}
