// Accessors over etf.Value trees. Gateway payloads (ETF) and REST bodies
// (JSON parsed with etf.from_json) share one representation, so the store's
// parsers serve both: snowflakes arrive as integers over ETF and as strings
// over JSON, atoms over ETF and strings over JSON.

V :: etf.Value;

vmap :: (v: V) -> etf.Map {
	{ m, ok := v.map, v.kind == .Map;
	if ok { return m; } }
	return .{};
}

vlist :: (v: V) -> []V {
	if v.kind == {
	case .List; x := v.list;
		return cast([]V)(x);
	case .Tuple; x := v.list;
		return cast([]V)(x);
	}
	return .{};
}

vget :: (m: etf.Map, key: string) -> V {
	v, _ := etf.map_get(m, key);
	return v;
}

vhas :: (m: etf.Map, key: string) -> bool {
	_, ok := etf.map_get(m, key);
	return ok;
}

vstr :: (v: V) -> string {
	if v.kind == {
	case .String; x := v.s;
		return x;
	case .Atom; x := v.s;
		return as_string(x);
	case .Charlist; x := v.s;
		return as_string(x);
	}
	return "";
}

vis_null :: (v: V) -> bool {
	return is_null(v);
}

vsnow :: (v: V) -> Snowflake {
	if v.kind == {
	case .Int; #through; case .Big; x := v;
		u, _ := etf.as_u64(v);
		return cast(Snowflake)(u);
	case .String; x := v.s;
		return parse_snowflake(x);
	}
	return 0;
}

vint :: (v: V) -> s64 {
	if v.kind == {
	case .Int; x := v.i;
		return x;
	case .Float; x := v.f;
		return cast(s64)(x);
	case .Bool; x := v.b;
		return ifx x then 1 else 0;
	case .String; x := v.s;
		n, _ := strconv.parse_i64(x);
		return n;
	case .Big; x := v.big;
		u, _ := etf.as_u64(v);
		return cast(s64)(u);
	}
	return 0;
}

vf64 :: (v: V) -> float64 {
	if v.kind == {
	case .Float; x := v.f;
		return x;
	case .Int; x := v.i;
		return cast(float64)(x);
	}
	return 0;
}

vbool :: (v: V) -> bool {
	if v.kind == {
	case .Bool; x := v.b;
		return x;
	case .Int; x := v.i;
		return x != 0;
	}
	return false;
}

// Field shorthands on maps.
fstr :: (m: etf.Map, k: string) -> string {return vstr(vget(m, k));}
fsnow :: (m: etf.Map, k: string) -> Snowflake {return vsnow(vget(m, k));}
fint :: (m: etf.Map, k: string) -> s64 {return vint(vget(m, k));}
fbool :: (m: etf.Map, k: string) -> bool {return vbool(vget(m, k));}
fmap :: (m: etf.Map, k: string) -> etf.Map {return vmap(vget(m, k));}
flist :: (m: etf.Map, k: string) -> []V {return vlist(vget(m, k));}

// clone_str copies into the store allocator ("" stays a zero-length literal).
clone_str :: (s: string, allocator: Allocator) -> string {
	if len(s) == 0 { return ""; }
	return clone(s, allocator);
}

free_str :: (s: string, allocator: Allocator) {
	if len(s) > 0 { delete(s, allocator); }
}

// parse_json parses a REST body into a Value tree in allocator.
parse_json :: (body: []u8, allocator: Allocator) -> V, bool {
	if len(body) == 0 { return .{}, true; }
	v, err := etf.from_json(as_string(body), allocator);
	return v, err == .None;
}

