// Offline store loading for deterministic UI tests: replays the gateway
// dispatches of a recorded fixture into a Store without any network.
// Accepted line formats:
//   testdata/gw_a.jsonl:  {"rt":..,"dir":"recv","etf":{"op":0,"t":"READY","s":1,"d":{...}}}
//   traffic/*.jsonl:      {"t":..,"k":"ws_recv","op":0,"ev":"READY","seq":1,"d":{...}}
// Atoms written as {"$atom":"x"} are restored.

// de_atom rewrites {"$atom": "x"} maps into etf.Atom in place.
de_atom :: (v: V) -> V {
	if v.kind == {
		case .Map;
			if v.map.count == 1 && v.map[0].key.kind == .String && v.map[0].key.s == "$atom" return etf.vatom(vstr(v.map[0].value));
			for * v.map it.value = de_atom(it.value);
		case .List;
			for * v.list it.* = de_atom(it.*);
	}
	return v;
}

// store_load_fixture_text applies every received dispatch in text; returns the count.
store_load_fixture_text :: (s: *Store, text: string) -> int {
	pool: Flat_Pool; // the parsed lines; the store copies what it keeps
	defer fini(*pool);
	n := 0;
	t := text;
	while t {
		line := t;
		i := find_index_from_left(t, #char "\n");
		if i >= 0 {
			line.count = i;
			t = advance(t, i + 1);
		} else {
			t = "";
		}
		if ends_with(line, "\r") line.count -= 1;
		if !line continue;
		v, err := etf.from_json(line,, pool_allocator(*pool));
		if err != .None continue;
		m := vmap(v);
		name: string;
		d: V;
		e := fmap(m, "etf");
		if e.data {
			if fstr(m, "dir") == "send" || fint(e, "op") != 0 continue;
			name = vstr(de_atom(vget(e, "t")));
			d = vget(e, "d");
		} else if fstr(m, "k") == "ws_recv" && fint(m, "op") == 0 {
			name = fstr(m, "ev");
			d = vget(m, "d");
		} else {
			continue;
		}
		if store_apply_dispatch(s, name, de_atom(d), 0) n += 1;
		extras_dispatch(s, s.allocator, name, de_atom(d));
	}
	if n s.changed += 1;
	return n;
}

// store_load_fixture loads a fixture file (see store_load_fixture_text).
store_load_fixture :: (s: *Store, path: string) -> int, bool {
	data, ok := read_entire_file(path,, temp);
	if !ok return 0, false;
	return store_load_fixture_text(s, data), true;
}

