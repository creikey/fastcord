Event :: struct {
	t: float64;
	k: string;
	v: etf.Value;
	resp: etf.Value; // req: matching resp
}

Window :: struct {
	name: string;
	start: float64;
	events: [..]Event;
}

Opts :: struct {
	tol: float64;
	ignore: [..]string;
	recv: bool;
	actions: bool; // compare only action windows (session runs: preludes and launches differ)
}

main :: () {
	arena: virtual.Arena;
	virtual.arena_init_growing(*arena);
	push_allocator(virtual.arena_allocator(*arena));
	opts := Opts.{tol = 1500};
	files := make_dynamic(string, 0, 0);
	for a: sub_from(get_command_line_arguments(), 1) {
		if strings.has_prefix(a, "-tol:") {
			opts.tol, _ = strconv.parse_f64(sub_from(a, 5));
		} else if strings.has_prefix(a, "-ignore:") {
			append(*opts.ignore, sub_from(a, 8));
		} else if a == "-recv" {
			opts.recv = true;
		} else if a == "-actions" {
			opts.actions = true;
		} else {
			append(*files, a);
		}
	}
	if len(files) != 2 {
		fmt.eprintln("usage: trafficdiff [-tol:MS] [-ignore:SUBSTR]... [-recv] [-actions] official.jsonl ours.jsonl");
		os.exit(2);
	}
	a, aok := load(files[0]);
	b, bok := load(files[1]);
	if !aok || !bok {
		fmt.eprintln("cannot read fixtures");
		os.exit(2);
	}
	sb := strings.builder_make();
	n := diff(a, b, opts, *sb);
	fmt.print(strings.to_string(sb));
	if n > 0 {
		fmt.printfln("%d difference(s)", n);
		os.exit(1);
	}
	fmt.println("traffic matches");
}

load :: (path: string) -> []Window, bool {
	data, err := os.read_entire_file(path, context.allocator);
	if err != null { return .{}, false; }
	return parse_fixture(as_string(data)), true;
}

parse_fixture :: (text: string) -> []Window {
	wins := make_dynamic(Window, 0, 0);
	append(*wins, Window.{name = "(before first mark)"});
	reqs := Map(string, int).{}; // "acct/id" -> index in current window
	for line: strings.split_lines(text) {
		if len(line) == 0 { continue; }
		v, err := etf.from_json(line);
		if err != .None { continue; }
		k := str(v, "k");
		t := num(v, "t");
		if k == {
		case "mark";
			append(*wins, Window.{name = str(v, "name"), start = t});
			clear(*reqs);
		case "resp";
			key := fmt.aprintf("%s/%v", acct(v), num(v, "id"));
			{ i, ok := map_find(reqs, key);
			if ok { wins[len(wins) - 1].events[i].resp = v; } }
		case;
			w := *wins[len(wins) - 1];
			if k == "req" { at(*reqs, fmt.aprintf("%s/%v", acct(v), num(v, "id"))).* = len(w.events); }
			append(*w.events, Event.{t = t, k = k, v = v});
		}
	}
	return view(wins);
}

get :: (v: etf.Value, key: string) -> etf.Value {
	if v.kind != .Map { return .{}; }
	x := etf.map_get(v.map, key);
	return x;
}

str :: (v: etf.Value, key: string) -> string {
	x := get(v, key);
	return ifx x.kind == .String then x.s else "";
}

num :: (v: etf.Value, key: string) -> float64 {
	{ __v4 := get(v, key);
	if __v4.kind == {
	case .Int; n := __v4.i;
		return cast(float64)(n);
	case .Float; n := __v4.f;
		return n;
	} }
	return 0;
}

acct :: (v: etf.Value) -> string {
	a := str(v, "acct");
	return ifx a != "" then a else "a";
}

// norm makes per-run values comparable: "<kind:N>" -> "<kind>", digit runs of
// snowflake length -> "{id}".
norm :: (s: string) -> string {
	sb := strings.builder_make(temp);
	i := 0;
	while i < len(s) {
		if s[i] == #char "<" {
			end := strings.index_byte(sub_from(s, i), #char ">");
			if end > 0 {
				inner := sub(s, i + 1, i + end);
				{ c := strings.last_index_byte(inner, #char ":");
				if c > 0 {
					digits := true;
					for ch: transmute([]u8, sub_from(inner, c + 1)) { if ch < #char "0" || ch > #char "9" { digits = false; } }
					if digits {
						fmt.sbprintf(*sb, "<%s>", sub(inner, 0, c));
						i += end + 1;
						continue;
					}
				} }
			}
		}
		if s[i] >= #char "0" && s[i] <= #char "9" {
			j := i;
			while j < len(s) && s[j] >= #char "0" && s[j] <= #char "9" { j += 1; }
			if j - i >= 17 && j - i <= 20 {
				strings.write_string(*sb, "{id}");
			} else {
				strings.write_string(*sb, sub(s, i, j));
			}
			i = j;
			continue;
		}
		strings.write_byte(*sb, s[i]);
		i += 1;
	}
	return strings.to_string(sb);
}

// template: scheme+host+path with ids normalized, query keys kept, values dropped.
template :: (url: string) -> string {
	base := url;
	query := "";
	{ q := strings.index_byte(url, #char "?");
	if q >= 0 {
		base = sub(url, 0, q);
		query = sub_from(url, q + 1);
	} }
	sb := strings.builder_make(temp);
	strings.write_string(*sb, norm(base));
	if query != "" {
		strings.write_byte(*sb, #char "?");
		it_ := query;
		first := true;
		while true { part, __ok5 := strings.split_iterator(*it_, "&"); if !__ok5 break;
			if !first { strings.write_byte(*sb, #char "&"); }
			first = false;
			eq := strings.index_byte(part, #char "=");
			strings.write_string(*sb, ifx eq >= 0 then sub(part, 0, eq) else part);
		}
	}
	return clone(strings.to_string(sb));
}

req_key :: (e: Event) -> string {
	return fmt.tprintf("%s %s %s", acct(e.v), str(e.v, "method"), template(str(e.v, "url")));
}

ignored :: (e: Event, opts: Opts) -> bool {
	url := str(e.v, "url");
	for s: opts.ignore { if strings.contains(url, s) { return true; } }
	return false;
}

header_pairs :: (v: etf.Value) -> [][2]etf.Value {
	hs := get(v, "headers");
	l := ifx hs.kind == .List then hs.list else .[];
	out := make_dynamic([2]etf.Value, 0, 0, temp);
	for h: l {
		if h.kind == .List && len(h.list) == 2 { append(*out, etf.Value.[h.list[0], h.list[1]]); }
	}
	return view(out);
}

// value_text renders a JSON value with placeholders/ids normalized.
value_text :: (v: etf.Value) -> string {
	sb := strings.builder_make(temp);
	etf.to_json(v, *sb);
	return norm(strings.to_string(sb));
}

// shape renders structure only: object keys (in order) and value types.
shape :: (v: etf.Value, sb: *strings.Builder, depth := 0) {
	if v.kind == {
	case .Nil;
		strings.write_string(sb, "null");
	case .Bool; x := v.b;
		strings.write_string(sb, "bool");
	case .Int; #through; case .Float; #through; case .Big; x := v;
		strings.write_string(sb, "num");
	case .String; #through; case .Atom; #through; case .Charlist; x := v;
		strings.write_string(sb, "str");
	case .List; x := v.list;
		strings.write_byte(sb, #char "[");
		if len(x) > 0 && depth < 12 { shape(x[0], sb, depth + 1); }
		strings.write_byte(sb, #char "]");
	case .Tuple; x := v.list;
		strings.write_string(sb, "tuple");
	case .Map; x := v.map;
		if depth >= 12 {
			strings.write_string(sb, "{..}");
			return;
		}
		strings.write_byte(sb, #char "{");
		for p, i: x {
			if i > 0 { strings.write_byte(sb, #char ","); }
			strings.write_string(sb, ifx p.key.kind == .String then p.key.s else "");
			strings.write_byte(sb, #char ":");
			shape(p.value, sb, depth + 1);
		}
		strings.write_byte(sb, #char "}");
	}
}

shape_of :: (v: etf.Value) -> string {
	sb := strings.builder_make(temp);
	shape(v, *sb);
	return strings.to_string(sb);
}

// conn_facts: first h2/h3 session per (account, kind, host) and its
// client-side facts, with per-run noise (RTT estimate, GREASE ids) removed.
conn_facts :: (wins: []Window) -> Map(string, string) {
	out := Map(string, string).{};
	for w: wins {
		for e: w.events {
			if e.k != "conn" { continue; }
			kind := str(e.v, "kind");
			if kind != "h2" && kind != "h3" { continue; }
			key := fmt.tprintf("%s %s %s", acct(e.v), kind, str(e.v, "host"));
			if has(out, key) { continue; }
			sb := strings.builder_make(temp);
			for f: (string.["send_settings", "send_window_update", "http3_settings_sent", "transport_parameters_sent"]) {
				{ v := get(e.v, f);
				if !etf.is_nil(v) { fmt.sbprintf(*sb, "%s=%s ", f, value_text(v)); } }
			}
			{ t := get(e.v, "tls");
			if !etf.is_nil(t) { fmt.sbprintf(*sb, "alpn=%s ", str(t, "next_proto")); } }
			txt := strings.to_string(sb);
			// GREASE settings and the RTT estimate differ on every connection
			while true {
				i := strings.index(txt, "UNSUPPORTED_SETTINGS_TYPE(");
				if i < 0 { break; }
				j := strings.index_byte(sub_from(txt, i), #char ",");
				if j < 0 { j = strings.index_byte(sub_from(txt, i), #char "}"); }
				txt = strings.concatenate(string.[sub(txt, 0, i), "GREASE", sub_from(txt, i + j)], temp);
			}
			{ i := strings.index(txt, "initial_round_trip_time ");
			if i >= 0 {
				j := i + len("initial_round_trip_time ");
				while j < len(txt) && txt[j] >= #char "0" && txt[j] <= #char "9" { j += 1; }
				txt = strings.concatenate(string.[sub(txt, 0, i), "initial_round_trip_time *", sub_from(txt, j)], temp);
			} }
			at(*out, key).* = txt;
		}
	}
	return out;
}

diff :: (a: []Window, b: []Window, opts: Opts, sb: *strings.Builder) -> int {
	n := 0;
	ca, cb := conn_facts(a), conn_facts(b);
	if opts.actions { clear(*ca); } // sessions are compared once, in cold_start
	for k, va: ca {
		{ vb, ok := map_find(cb, k);
		if ok && va != vb {
			fmt.sbprintfln(sb, "== connection %s\n      official: %s\n      ours:     %s", k, va, vb);
			n += 1;
		} }
	}
	used := make_slice(bool, len(b));
	prelude :: (name: string) -> bool {return name == "setup" || name == "setup_b" || name == "(before first mark)";}
	if opts.actions {
		for wb, j: b { if prelude(wb.name) { used[j] = true; } }
	}
	for wa: a {
		if opts.actions && prelude(wa.name) { continue; }
		bi := -1;
		for wb, j: b {
			if !used[j] && wb.name == wa.name {
				bi = j;
				break;
			}
		}
		if bi < 0 {
			fmt.sbprintfln(sb, "== window %q: missing in ours", wa.name);
			n += 1;
			continue;
		}
		used[bi] = true;
		before := len(sb.buf);
		n += diff_window(wa, b[bi], opts, sb);
		if len(sb.buf) > before {
			// prepend a header for this window
			body := clone(as_string(sub_from(sb.buf, before)));
			resize(*sb.buf, before);
			fmt.sbprintfln(sb, "== window %q", wa.name);
			strings.write_string(sb, body);
		}
	}
	for wb, j: b {
		if !used[j] {
			fmt.sbprintfln(sb, "== window %q: extra in ours", wb.name);
			n += 1;
		}
	}
	return n;
}

diff_window :: (wa: Window, wb: Window, opts: Opts, sb: *strings.Builder) -> int {
	n := 0;
	ra := make_dynamic(Event, 0, 0, temp);
	rb := make_dynamic(Event, 0, 0, temp);
	for e: wa.events { if e.k == "req" && !ignored(e, opts) { append(*ra, e); } }
	for e: wb.events { if e.k == "req" && !ignored(e, opts) { append(*rb, e); } }
	taken := make_slice(bool, len(rb), temp);
	// A window that restarts the app is timed from its gateway open: how long
	// the official app took to boot varies run to run (1-2 s), and every
	// request after it would otherwise carry that offset.
	// Requests after READY are timed from READY (the server's READY latency
	// varies 0.6-2.3 s), earlier ones from the gateway open.
	sa, sbs := wa.start, wb.start;
	ready_a, ready_b: float64 = -1, -1;
	{
		oa, ob: float64 = -1, -1;
		for e: wa.events { if e.k == "ws_open" {oa = e.t; break;} }
		for e: wb.events { if e.k == "ws_open" {ob = e.t; break;} }
		if oa >= 0 && ob >= 0 {
			sa, sbs = oa, ob;
		}
		for e: wa.events { if e.k == "ws_recv" && str(e.v, "ev") == "READY" {ready_a = e.t; break;} }
		for e: wb.events { if e.k == "ws_recv" && str(e.v, "ev") == "READY" {ready_b = e.t; break;} }
	}
	anchors :: (ea: Event, eb: Event, sa: float64, sbs: float64, ra: float64, rb_: float64) -> float64, float64 {
		if ra >= 0 && rb_ >= 0 && ea.t >= ra && eb.t >= rb_ { return ra, rb_; }
		return sa, sbs;
	}
	// matched (official t, ours index) pairs, to detect order changes between
	// requests that are not part of the same burst (> ORDER_SLACK ms apart)
	ORDER_SLACK :: 100.0;
	seen := make_dynamic([2]float64, 0, 0, temp);
	seen_key := make_dynamic(string, 0, 0, temp);
	for e: ra {
		key := req_key(e);
		// same-key requests (science batches, repeated GETs): the unused one
		// closest in window time, so one early/late batch does not shift the rest
		match := -1;
		best := FLOAT64_MAX;
		for f, j: rb {
			if !taken[j] && req_key(f) == key {
				x, y := anchors(e, f, sa, sbs, ready_a, ready_b);
				d := abs((f.t - y) - (e.t - x));
				if d < best {
					best = d;
					match = j;
				}
			}
		}
		if match < 0 {
			fmt.sbprintfln(sb, "  - missing  %s", key);
			n += 1;
			continue;
		}
		taken[match] = true;
		for prev, pi: seen {
			if cast(float64)(match) < prev[1] && (e.t - wa.start) - prev[0] > ORDER_SLACK {
				fmt.sbprintfln(sb, "  ~ order    %s comes earlier in ours (than %s)", key, seen_key[pi]);
				n += 1;
				break;
			}
		}
		append(*seen, float64.[e.t - wa.start, cast(float64)(match)]);
		append(*seen_key, key);
		xa, xb := anchors(e, rb[match], sa, sbs, ready_a, ready_b);
		n += diff_request(e, rb[match], xa, xb, opts, sb);
	}
	for f, j: rb { if !taken[j] {
		fmt.sbprintfln(sb, "  + extra    %s", req_key(f));
		n += 1;
	} }
	n += diff_gateway(wa, wb, opts, sb);
	return n;
}

diff_request :: (a: Event, b: Event, sa: float64, sb_start: float64, opts: Opts, sb: *strings.Builder) -> int {
	n := 0;
	key := req_key(a);
	{ pa, pb := str(a.v, "proto"), str(b.v, "proto");
	if pa != pb {
		fmt.sbprintfln(sb, "  ~ %s: proto %q vs %q", key, pa, pb);
		n += 1;
	} }
	ha, hb := header_pairs(a.v), header_pairs(b.v);
	names_a := make_dynamic(string, 0, 0, temp);
	names_b := make_dynamic(string, 0, 0, temp);
	for h: ha { append(*names_a, ifx h[0].kind == .String then h[0].s else ""); }
	for h: hb { append(*names_b, ifx h[0].kind == .String then h[0].s else ""); }
	if strings.join(view(names_a), ",", temp) != strings.join(view(names_b), ",", temp) {
		fmt.sbprintfln(sb, "  ~ %s: header names/order\n      official: %v\n      ours:     %v", key, view(names_a), view(names_b));
		n += 1;
	}
	for h: ha {
		name := ifx h[0].kind == .String then h[0].s else "";
		for g: hb {
			if (ifx g[0].kind == .String then g[0].s else "") != name { continue; }
			va, vb := value_text(h[1]), value_text(g[1]);
			if va != vb {
				fmt.sbprintfln(sb, "  ~ %s: header %s\n      official: %s\n      ours:     %s", key, name, va, vb);
				n += 1;
			}
			break;
		}
	}
	// wire headers: from a netlog the order is real and is compared; from
	// DevTools (sorted) only the set of names is compared
	{ wa, wb := get(a.v, "wire"), get(b.v, "wire");
	if !etf.is_nil(wa) && !etf.is_nil(wb) {
		ordered := str(a.v, "wire_src") == "netlog" && str(b.v, "wire_src") == "netlog";
		names :: (v: etf.Value, sorted: bool) -> string {
			l := ifx v.kind == .List then v.list else .[];
			out := make_dynamic(string, 0, 0, temp);
			for h: l {
				if h.kind == .List && len(h.list) == 2 { append(*out, strings.to_lower(ifx h.list[0].kind == .String then h.list[0].s else "", temp)); }
			}
			if sorted { slice.sort_by(view(out), (x: string, y: string) -> bool { return compare(x, y) < 0; }); }
			return strings.join(view(out), ",", temp);
		}
		{ x, y := names(wa, !ordered), names(wb, !ordered);
		if x != y {
			fmt.sbprintfln(sb, "  ~ %s: wire headers (%s)\n      official: %s\n      ours:     %s", key, ifx ordered then "order" else "set", x, y);
			n += 1;
		} }
		if ordered {
			la := ifx wa.kind == .List then wa.list else .[];
			lb := ifx wb.kind == .List then wb.list else .[];
			for h, i: la {
				if i >= len(lb) { break; }
				pa := ifx h.kind == .List then h.list else .[];
				pb := ifx lb[i].kind == .List then lb[i].list else .[];
				if len(pa) != 2 || len(pb) != 2 { continue; }
				{ va, vb := value_text(pa[1]), value_text(pb[1]);
				if va != vb && !strings.contains(va, "bytes were stripped") {
					fmt.sbprintfln(sb, "  ~ %s: wire %v\n      official: %s\n      ours:     %s", key, ifx pa[0].kind == .String then pa[0].s else "", va, vb);
					n += 1;
				} }
			}
		}
	} }
	{ ba, bb := shape_of(get(a.v, "body")), shape_of(get(b.v, "body"));
	if ba != bb {
		fmt.sbprintfln(sb, "  ~ %s: body shape\n      official: %s\n      ours:     %s", key, ba, bb);
		n += 1;
	} }
	if !etf.is_nil(a.resp) && !etf.is_nil(b.resp) {
		{ x, y := num(a.resp, "status"), num(b.resp, "status");
		if x != y {
			fmt.sbprintfln(sb, "  ~ %s: status %v vs %v", key, x, y);
			n += 1;
		} }
	}
	dt := (b.t - sb_start) - (a.t - sa);
	if abs(dt) > opts.tol {
		fmt.sbprintfln(sb, "  ~ %s: timing %+.0f ms (tolerance %.0f)", key, dt, opts.tol);
		n += 1;
	}
	return n;
}

diff_gateway :: (wa: Window, wb: Window, opts: Opts, sb: *strings.Builder) -> int {
	n := 0;
	collect :: (w: Window, k: string) -> [..]Event {
		out := make_dynamic(Event, 0, 0, temp);
		for e: w.events { if e.k == k { append(*out, e); } }
		return out;
	}
	sa, sbb := collect(wa, "ws_send"), collect(wb, "ws_send");
	for i: 0..cast(int)((max(len(sa), len(sbb))))-1 {
		if i >= len(sa) {
			fmt.sbprintfln(sb, "  + extra    gateway send op %v", num(sbb[i].v, "op"));
			n += 1;
			continue;
		}
		if i >= len(sbb) {
			fmt.sbprintfln(sb, "  - missing  gateway send op %v", num(sa[i].v, "op"));
			n += 1;
			continue;
		}
		oa, ob := num(sa[i].v, "op"), num(sbb[i].v, "op");
		if oa != ob {
			fmt.sbprintfln(sb, "  ~ gateway send #%d: op %v vs %v", i + 1, oa, ob);
			n += 1;
			continue;
		}
		da, db := value_text(get(sa[i].v, "d")), value_text(get(sbb[i].v, "d"));
		if oa != 1 && da != db { // heartbeats carry the sequence number
			fmt.sbprintfln(sb, "  ~ gateway send #%d op %v payload\n      official: %s\n      ours:     %s", i + 1, oa, da, db);
			n += 1;
		}
	}
	if opts.recv {
		ra, rb := collect(wa, "ws_recv"), collect(wb, "ws_recv");
		names :: (l: [..]Event) -> string {
			parts := make_dynamic(string, 0, 0, temp);
			for e: l { append(*parts, ifx str(e.v, "ev") != "" then str(e.v, "ev") else fmt.tprintf("op%v", num(e.v, "op"))); }
			return strings.join(view(parts), ",", temp);
		}
		{ x, y := names(ra), names(rb);
		if x != y {
			fmt.sbprintfln(sb, "  ~ gateway recv sequence\n      official: %s\n      ours:     %s", x, y);
			n += 1;
		} }
	}
	return n;
}

