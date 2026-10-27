// Local compat helpers for the Odin port (candidates for fc / etf).

// to_v: Odin's implicit conversion of a variant into the etf.Value union.
to_v :: (x: $T) -> etf.Value {
	#if T == etf.Value return x;
	else #if T == string return etf.vstring(x);
	else #if T == bool return etf.vbool(x);
	else #if T == []etf.Value || T == [..]etf.Value return etf.vlist(x);
	else #if T == []etf.Pair || T == [..]etf.Pair return etf.vmap(x);
	else #if T == etf.Big return etf.vbig(x);
	else #if type_info(T).type == .INTEGER return etf.vint(xx x);
	else #if type_info(T).type == .FLOAT return etf.vfloat(xx x);
	else #if type_info(T).type == .POINTER { assert(x == null); return .{}; }
	else #assert false;
}

// vlist_of: Odin's `etf.List{a, b}` literal, copied to temp so it outlives the statement.
vlist_of :: (items: ..etf.Value) -> etf.Value { return etf.vlist(clone(items, temp)); }

// Maybe: Odin's Maybe(T); maybe_get is `m.?` (value, ok), some wraps a value.
Maybe :: struct(T: Type) { value: T; ok: bool; }
maybe_get :: inline (m: Maybe($T)) -> T, bool { return m.value, m.ok; }
some :: inline (v: $T) -> Maybe(T) { return .{v, true}; }

// is_null: Odin's `x == nil` for any type (slices and strings by data, etf.Value by kind).
is_null :: inline (x: $T) -> bool {
	#if T == etf.Value return x.kind == .Nil;
	else #if type_info(T).type == .ARRAY || type_info(T).type == .STRING return x.data == null;
	else #if type_info(T).type == .STRUCT return x.allocator.proc == null; // Map: made or written to
	else return x == null;
}

// make_map: Odin's make(map[K]V, allocator); the table keeps the allocator (and is non-nil) from here on.
make_map :: ($K: Type, $V: Type, allocator := context.allocator) -> Map(K, V) {
	m: Map(K, V);
	m.allocator = allocator;
	return m;
}
