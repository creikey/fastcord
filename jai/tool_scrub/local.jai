// Odin's `x, _ := v.(T)` on etf values: the variant, or its zero value on a kind mismatch.
#scope_module
vs :: (v: etf.Value) -> string { return ifx v.kind == .String then v.s else ""; }
vl :: (v: etf.Value) -> []etf.Value { if v.kind == .List return v.list; return .[]; }
gb :: (v: etf.Value, keys: ..string) -> bool { x := get(v, ..keys); return x.kind == .Bool && x.b; }

// Odin's implicit conversions into the etf.Value union.
P :: (k: string, v: etf.Value) -> etf.Pair { return .{key = etf.vstring(k), value = v}; }
P :: (k: string, v: string) -> etf.Pair { return P(k, etf.vstring(v)); }
P :: (k: string, v: s64) -> etf.Pair { return P(k, etf.vint(v)); }
P :: (k: string, v: float64) -> etf.Pair { return P(k, etf.vfloat(v)); }
P :: (k: string, v: bool) -> etf.Pair { return P(k, etf.vbool(v)); }

// Odin's "%v" of a union: the variant's own text.
vtext :: (v: etf.Value) -> string {
	if v.kind == .String || v.kind == .Atom || v.kind == .Charlist return v.s;
	sb := strings.builder_make(temp);
	etf.to_json(v, *sb);
	return strings.to_string(sb);
}
