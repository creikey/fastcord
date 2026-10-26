package discord

import "core:strconv"
import "core:strings"
import "fc:etf"

// Accessors over etf.Value trees. Gateway payloads (ETF) and REST bodies
// (JSON parsed with etf.from_json) share one representation, so the store's
// parsers serve both: snowflakes arrive as integers over ETF and as strings
// over JSON, atoms over ETF and strings over JSON.

V :: etf.Value

vmap :: proc(v: V) -> etf.Map {
	if m, ok := v.(etf.Map); ok do return m
	return nil
}

vlist :: proc(v: V) -> []V {
	#partial switch x in v {
	case etf.List:
		return ([]V)(x)
	case etf.Tuple:
		return ([]V)(x)
	}
	return nil
}

vget :: proc(m: etf.Map, key: string) -> V {
	v, _ := etf.map_get(m, key)
	return v
}

vhas :: proc(m: etf.Map, key: string) -> bool {
	_, ok := etf.map_get(m, key)
	return ok
}

vstr :: proc(v: V) -> string {
	#partial switch x in v {
	case string:
		return x
	case etf.Atom:
		return string(x)
	case etf.Charlist:
		return string(x)
	}
	return ""
}

vis_null :: proc(v: V) -> bool {
	return v == nil
}

vsnow :: proc(v: V) -> Snowflake {
	#partial switch x in v {
	case i64, etf.Big:
		u, _ := etf.as_u64(v)
		return Snowflake(u)
	case string:
		return parse_snowflake(x)
	}
	return 0
}

vint :: proc(v: V) -> i64 {
	#partial switch x in v {
	case i64:
		return x
	case f64:
		return i64(x)
	case bool:
		return 1 if x else 0
	case string:
		n, _ := strconv.parse_i64(x)
		return n
	case etf.Big:
		u, _ := etf.as_u64(v)
		return i64(u)
	}
	return 0
}

vf64 :: proc(v: V) -> f64 {
	#partial switch x in v {
	case f64:
		return x
	case i64:
		return f64(x)
	}
	return 0
}

vbool :: proc(v: V) -> bool {
	#partial switch x in v {
	case bool:
		return x
	case i64:
		return x != 0
	}
	return false
}

// Field shorthands on maps.
fstr :: proc(m: etf.Map, k: string) -> string {return vstr(vget(m, k))}
fsnow :: proc(m: etf.Map, k: string) -> Snowflake {return vsnow(vget(m, k))}
fint :: proc(m: etf.Map, k: string) -> i64 {return vint(vget(m, k))}
fbool :: proc(m: etf.Map, k: string) -> bool {return vbool(vget(m, k))}
fmap :: proc(m: etf.Map, k: string) -> etf.Map {return vmap(vget(m, k))}
flist :: proc(m: etf.Map, k: string) -> []V {return vlist(vget(m, k))}

// clone_str copies into the store allocator ("" stays a zero-length literal).
clone_str :: proc(s: string, allocator: Allocator) -> string {
	if len(s) == 0 do return ""
	return strings.clone(s, allocator)
}

free_str :: proc(s: string, allocator: Allocator) {
	if len(s) > 0 do delete(s, allocator)
}

// parse_json parses a REST body into a Value tree in allocator.
parse_json :: proc(body: []byte, allocator: Allocator) -> (V, bool) {
	if len(body) == 0 do return nil, true
	v, err := etf.from_json(string(body), allocator)
	return v, err == .None
}
