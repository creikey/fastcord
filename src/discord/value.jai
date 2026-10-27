// Accessors over etf.Value trees. Gateway payloads (ETF) and REST bodies
// (JSON parsed with etf.from_json) share one representation, so the store's
// parsers serve both: snowflakes arrive as integers over ETF and as strings
// over JSON, atoms over ETF and strings over JSON.

V :: etf.Value;

vmap :: (v: V) -> etf.Map { return ifx v.kind == .Map then v.map else .[]; }

vlist :: (v: V) -> []V { return ifx v.kind == .List || v.kind == .Tuple then v.list else .[]; }

vget :: (m: etf.Map, key: string) -> V {
	v := etf.map_get(m, key);
	return v;
}

vhas :: (m: etf.Map, key: string) -> bool {
	_, ok := etf.map_get(m, key);
	return ok;
}

vstr :: (v: V) -> string { return ifx v.kind == .String || v.kind == .Atom || v.kind == .Charlist then v.s else ""; }

vis_null :: (v: V) -> bool { return v.kind == .Nil; }

vsnow :: (v: V) -> Snowflake {
	if v.kind == {
		case .Int; #through;
		case .Big; u := etf.as_u64(v); return u;
		case .String; return parse_snowflake(v.s);
	}
	return 0;
}

vint :: (v: V) -> s64 {
	if v.kind == {
		case .Int;    return v.i;
		case .Float;  return cast(s64) v.f;
		case .Bool;   return xx v.b;
		case .String; n := parse_s64(v.s); return n;
		case .Big;    u := etf.as_u64(v); return cast(s64) u;
	}
	return 0;
}

vf64 :: (v: V) -> float64 {
	if v.kind == {
		case .Float; return v.f;
		case .Int;   return cast(float64) v.i;
	}
	return 0;
}

vbool :: (v: V) -> bool {
	if v.kind == {
		case .Bool; return v.b;
		case .Int;  return v.i != 0;
	}
	return false;
}

// Field shorthands on maps.
fstr :: (m: etf.Map, k: string) -> string { return vstr(vget(m, k)); }
fsnow :: (m: etf.Map, k: string) -> Snowflake { return vsnow(vget(m, k)); }
fint :: (m: etf.Map, k: string) -> s64 { return vint(vget(m, k)); }
fbool :: (m: etf.Map, k: string) -> bool { return vbool(vget(m, k)); }
fmap :: (m: etf.Map, k: string) -> etf.Map { return vmap(vget(m, k)); }
flist :: (m: etf.Map, k: string) -> []V { return vlist(vget(m, k)); }

// clone_str copies into the store allocator ("" stays a zero-length literal).
clone_str :: (s: string, allocator: Allocator) -> string { return ifx s then copy_string(s,, allocator) else ""; }

free_str :: (s: string, allocator: Allocator) { if s free(s,, allocator); }

// parse_json parses a REST body into a Value tree in context.allocator.
parse_json :: (body: []u8) -> V, bool {
	if !body return .{}, true;
	v, err := etf.from_json(cast(string) body);
	return v, err == .None;
}
