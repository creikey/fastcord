package discord

import "core:mem/virtual"
import "core:os"
import "core:strings"
import "fc:etf"

// Offline store loading for deterministic UI tests: replays the gateway
// dispatches of a recorded fixture into a Store without any network.
// Accepted line formats:
//   testdata/gw_a.jsonl:  {"rt":..,"dir":"recv","etf":{"op":0,"t":"READY","s":1,"d":{...}}}
//   traffic/*.jsonl:      {"t":..,"k":"ws_recv","op":0,"ev":"READY","seq":1,"d":{...}}
// Atoms written as {"$atom":"x"} are restored.

// de_atom rewrites {"$atom": "x"} maps into etf.Atom in place.
de_atom :: proc(v: V) -> V {
	#partial switch x in v {
	case etf.Map:
		if len(x) == 1 {
			if k, ok := x[0].key.(string); ok && k == "$atom" do return etf.Atom(vstr(x[0].value))
		}
		for &p in x do p.value = de_atom(p.value)
	case etf.List:
		for &e in x do e = de_atom(e)
	}
	return v
}

// store_load_fixture_text applies every received dispatch in text; returns the count.
store_load_fixture_text :: proc(s: ^Store, text: string) -> int {
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil do return 0
	defer virtual.arena_destroy(&arena)
	alloc := virtual.arena_allocator(&arena)
	n := 0
	t := text
	for line in strings.split_lines_iterator(&t) {
		if len(line) == 0 do continue
		v, err := etf.from_json(line, alloc)
		if err != .None do continue
		m := vmap(v)
		name: string
		d: V
		if e := fmap(m, "etf"); e != nil {
			if fstr(m, "dir") == "send" || fint(e, "op") != 0 do continue
			name = vstr(de_atom(vget(e, "t")))
			d = vget(e, "d")
		} else if fstr(m, "k") == "ws_recv" && fint(m, "op") == 0 {
			name = fstr(m, "ev")
			d = vget(m, "d")
		} else {
			continue
		}
		if store_apply_dispatch(s, name, de_atom(d), 0) do n += 1
		extras_dispatch(s, s.allocator, name, de_atom(d))
	}
	if n > 0 do s.changed += 1
	return n
}

// store_load_fixture loads a fixture file (see store_load_fixture_text).
store_load_fixture :: proc(s: ^Store, path: string) -> (applied: int, ok: bool) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil do return 0, false
	return store_load_fixture_text(s, string(data)), true
}
