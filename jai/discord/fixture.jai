// Offline store loading for deterministic UI tests: replays the gateway
// dispatches of a recorded fixture into a Store without any network.
// Accepted line formats:
//   testdata/gw_a.jsonl:  {"rt":..,"dir":"recv","etf":{"op":0,"t":"READY","s":1,"d":{...}}}
//   traffic/*.jsonl:      {"t":..,"k":"ws_recv","op":0,"ev":"READY","seq":1,"d":{...}}
// Atoms written as {"$atom":"x"} are restored.

// de_atom rewrites {"$atom": "x"} maps into etf.Atom in place.
de_atom :: (v: V) -> V {
	if v.kind == {
	case .Map; x := v.map;
		if len(x) == 1 {
			{ k, ok := x[0].key.s, x[0].key.kind == .String;
			if ok && k == "$atom" { return etf.vatom(vstr(x[0].value)); } }
		}
		for * p: x { p.value = de_atom(p.value); }
	case .List; x := v.list;
		for * e: x { e.* = de_atom(e.*); }
	}
	return v;
}

// store_load_fixture_text applies every received dispatch in text; returns the count.
store_load_fixture_text :: (s: *Store, text: string) -> int {
	arena: Flat_Pool;
	defer fini(*arena);
	alloc := pool_allocator(*arena);
	n := 0;
	t := text;
	while true { line, __ok2 := strings.split_lines_iterator(*t); if !__ok2 break;
		if len(line) == 0 { continue; }
		v, err := etf.from_json(line,, alloc);
		if err != .None { continue; }
		m := vmap(v);
		name: string;
		d: V;
		{ e := fmap(m, "etf");
		if !is_null(e) {
			if fstr(m, "dir") == "send" || fint(e, "op") != 0 { continue; }
			name = vstr(de_atom(vget(e, "t")));
			d = vget(e, "d");
		} else if fstr(m, "k") == "ws_recv" && fint(m, "op") == 0 {
			name = fstr(m, "ev");
			d = vget(m, "d");
		} else {
			continue;
		} }
		if store_apply_dispatch(s, name, de_atom(d), 0) { n += 1; }
		extras_dispatch(s, s.allocator, name, de_atom(d));
	}
	if n > 0 { s.changed += 1; }
	return n;
}

// store_load_fixture loads a fixture file (see store_load_fixture_text).
store_load_fixture :: (s: *Store, path: string) -> int, bool {
	applied: int;
	ok: bool;
	data, err := os.read_entire_file(path, temp);
	if err != null { return 0, false; }
	return store_load_fixture_text(s, as_string(data)), true;
}

