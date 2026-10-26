// trafficdiff: compares two traffic fixtures (official vs ours) mark window by
// mark window and exits 1 when they differ.
//
//   trafficdiff [-tol:MS] [-ignore:SUBSTR]... [-recv] official.jsonl ours.jsonl
//
// Per window (events between consecutive marks with the same name):
//   - requests matched by (account, method, URL template); missing/extra listed,
//     out-of-order matches flagged
//   - matched requests: protocol, header names + order, header values (modulo
//     scrub placeholders: "<id:x:3>" == "<id:x:9>"), body shape
//   - start time relative to the window start within -tol (default 1500 ms)
//   - gateway: sent ops + payload values (modulo placeholders); received
//     dispatch names only with -recv (they depend on the server)
// Ids, nonces and other placeholders compare by kind, so two runs diff cleanly.
package trafficdiff

import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "fc:etf"

Event :: struct {
	t:    f64,
	k:    string,
	v:    etf.Value,
	resp: etf.Value, // req: matching resp
}

Window :: struct {
	name:   string,
	start:  f64,
	events: [dynamic]Event,
}

Opts :: struct {
	tol:    f64,
	ignore: [dynamic]string,
	recv:   bool,
}

main :: proc() {
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	opts := Opts{tol = 1500}
	files := make([dynamic]string)
	for a in os.args[1:] {
		switch {
		case strings.has_prefix(a, "-tol:"):
			opts.tol, _ = strconv.parse_f64(a[5:])
		case strings.has_prefix(a, "-ignore:"):
			append(&opts.ignore, a[8:])
		case a == "-recv":
			opts.recv = true
		case:
			append(&files, a)
		}
	}
	if len(files) != 2 {
		fmt.eprintln("usage: trafficdiff [-tol:MS] [-ignore:SUBSTR]... [-recv] official.jsonl ours.jsonl")
		os.exit(2)
	}
	a, aok := load(files[0])
	b, bok := load(files[1])
	if !aok || !bok {
		fmt.eprintln("cannot read fixtures")
		os.exit(2)
	}
	sb := strings.builder_make()
	n := diff(a, b, opts, &sb)
	fmt.print(strings.to_string(sb))
	if n > 0 {
		fmt.printfln("%d difference(s)", n)
		os.exit(1)
	}
	fmt.println("traffic matches")
}

load :: proc(path: string) -> ([]Window, bool) {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil do return nil, false
	return parse_fixture(string(data)), true
}

parse_fixture :: proc(text: string) -> []Window {
	wins := make([dynamic]Window)
	append(&wins, Window{name = "(before first mark)"})
	reqs := make(map[string]int) // "acct/id" -> index in current window
	for line in strings.split_lines(text) {
		if len(line) == 0 do continue
		v, err := etf.from_json(line)
		if err != .None do continue
		k := str(v, "k")
		t := num(v, "t")
		switch k {
		case "mark":
			append(&wins, Window{name = str(v, "name"), start = t})
			clear(&reqs)
		case "resp":
			key := fmt.aprintf("%s/%v", acct(v), num(v, "id"))
			if i, ok := reqs[key]; ok do wins[len(wins) - 1].events[i].resp = v
		case:
			w := &wins[len(wins) - 1]
			if k == "req" do reqs[fmt.aprintf("%s/%v", acct(v), num(v, "id"))] = len(w.events)
			append(&w.events, Event{t = t, k = k, v = v})
		}
	}
	return wins[:]
}

get :: proc(v: etf.Value, key: string) -> etf.Value {
	m, ok := v.(etf.Map)
	if !ok do return nil
	x, _ := etf.map_get(m, key)
	return x
}

str :: proc(v: etf.Value, key: string) -> string {
	s, _ := get(v, key).(string)
	return s
}

num :: proc(v: etf.Value, key: string) -> f64 {
	#partial switch n in get(v, key) {
	case i64:
		return f64(n)
	case f64:
		return n
	}
	return 0
}

acct :: proc(v: etf.Value) -> string {
	a := str(v, "acct")
	return a if a != "" else "a"
}

// norm makes per-run values comparable: "<kind:N>" -> "<kind>", digit runs of
// snowflake length -> "{id}".
norm :: proc(s: string) -> string {
	sb := strings.builder_make(context.temp_allocator)
	i := 0
	for i < len(s) {
		if s[i] == '<' {
			end := strings.index_byte(s[i:], '>')
			if end > 0 {
				inner := s[i + 1:i + end]
				if c := strings.last_index_byte(inner, ':'); c > 0 {
					digits := true
					for ch in transmute([]byte)inner[c + 1:] do if ch < '0' || ch > '9' do digits = false
					if digits {
						fmt.sbprintf(&sb, "<%s>", inner[:c])
						i += end + 1
						continue
					}
				}
			}
		}
		if s[i] >= '0' && s[i] <= '9' {
			j := i
			for j < len(s) && s[j] >= '0' && s[j] <= '9' do j += 1
			if j - i >= 17 && j - i <= 20 {
				strings.write_string(&sb, "{id}")
			} else {
				strings.write_string(&sb, s[i:j])
			}
			i = j
			continue
		}
		strings.write_byte(&sb, s[i])
		i += 1
	}
	return strings.to_string(sb)
}

// template: scheme+host+path with ids normalized, query keys kept, values dropped.
template :: proc(url: string) -> string {
	base := url
	query := ""
	if q := strings.index_byte(url, '?'); q >= 0 {
		base = url[:q]
		query = url[q + 1:]
	}
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, norm(base))
	if query != "" {
		strings.write_byte(&sb, '?')
		it := query
		first := true
		for part in strings.split_iterator(&it, "&") {
			if !first do strings.write_byte(&sb, '&')
			first = false
			eq := strings.index_byte(part, '=')
			strings.write_string(&sb, part[:eq] if eq >= 0 else part)
		}
	}
	return strings.clone(strings.to_string(sb))
}

req_key :: proc(e: Event) -> string {
	return fmt.tprintf("%s %s %s", acct(e.v), str(e.v, "method"), template(str(e.v, "url")))
}

ignored :: proc(e: Event, opts: Opts) -> bool {
	url := str(e.v, "url")
	for s in opts.ignore do if strings.contains(url, s) do return true
	return false
}

header_pairs :: proc(v: etf.Value) -> [][2]etf.Value {
	l, _ := get(v, "headers").(etf.List)
	out := make([dynamic][2]etf.Value, context.temp_allocator)
	for h in l {
		p, _ := h.(etf.List)
		if len(p) == 2 do append(&out, [2]etf.Value{p[0], p[1]})
	}
	return out[:]
}

// value_text renders a JSON value with placeholders/ids normalized.
value_text :: proc(v: etf.Value) -> string {
	sb := strings.builder_make(context.temp_allocator)
	etf.to_json(v, &sb)
	return norm(strings.to_string(sb))
}

// shape renders structure only: object keys (in order) and value types.
shape :: proc(v: etf.Value, sb: ^strings.Builder, depth := 0) {
	switch x in v {
	case nil:
		strings.write_string(sb, "null")
	case bool:
		strings.write_string(sb, "bool")
	case i64, f64, etf.Big:
		strings.write_string(sb, "num")
	case string, etf.Atom, etf.Charlist:
		strings.write_string(sb, "str")
	case etf.List:
		strings.write_byte(sb, '[')
		if len(x) > 0 && depth < 12 do shape(x[0], sb, depth + 1)
		strings.write_byte(sb, ']')
	case etf.Tuple:
		strings.write_string(sb, "tuple")
	case etf.Map:
		if depth >= 12 {
			strings.write_string(sb, "{..}")
			return
		}
		strings.write_byte(sb, '{')
		for p, i in x {
			if i > 0 do strings.write_byte(sb, ',')
			k, _ := p.key.(string)
			strings.write_string(sb, k)
			strings.write_byte(sb, ':')
			shape(p.value, sb, depth + 1)
		}
		strings.write_byte(sb, '}')
	}
}

shape_of :: proc(v: etf.Value) -> string {
	sb := strings.builder_make(context.temp_allocator)
	shape(v, &sb)
	return strings.to_string(sb)
}

// conn_facts: first h2/h3 session per (account, kind, host) and its
// client-side facts, with per-run noise (RTT estimate, GREASE ids) removed.
conn_facts :: proc(wins: []Window) -> map[string]string {
	out := make(map[string]string, allocator = context.temp_allocator)
	for w in wins {
		for e in w.events {
			if e.k != "conn" do continue
			kind := str(e.v, "kind")
			if kind != "h2" && kind != "h3" do continue
			key := fmt.tprintf("%s %s %s", acct(e.v), kind, str(e.v, "host"))
			if key in out do continue
			sb := strings.builder_make(context.temp_allocator)
			for f in ([]string{"send_settings", "send_window_update", "http3_settings_sent", "transport_parameters_sent"}) {
				if v := get(e.v, f); v != nil do fmt.sbprintf(&sb, "%s=%s ", f, value_text(v))
			}
			if t := get(e.v, "tls"); t != nil do fmt.sbprintf(&sb, "alpn=%s ", str(t, "next_proto"))
			txt := strings.to_string(sb)
			// GREASE settings and the RTT estimate differ on every connection
			for {
				i := strings.index(txt, "UNSUPPORTED_SETTINGS_TYPE(")
				if i < 0 do break
				j := strings.index_byte(txt[i:], ',')
				if j < 0 do j = strings.index_byte(txt[i:], '}')
				txt = strings.concatenate({txt[:i], "GREASE", txt[i + j:]}, context.temp_allocator)
			}
			if i := strings.index(txt, "initial_round_trip_time "); i >= 0 {
				j := i + len("initial_round_trip_time ")
				for j < len(txt) && txt[j] >= '0' && txt[j] <= '9' do j += 1
				txt = strings.concatenate({txt[:i], "initial_round_trip_time *", txt[j:]}, context.temp_allocator)
			}
			out[key] = txt
		}
	}
	return out
}

diff :: proc(a, b: []Window, opts: Opts, sb: ^strings.Builder) -> int {
	n := 0
	ca, cb := conn_facts(a), conn_facts(b)
	for k, va in ca {
		if vb, ok := cb[k]; ok && va != vb {
			fmt.sbprintfln(sb, "== connection %s\n      official: %s\n      ours:     %s", k, va, vb)
			n += 1
		}
	}
	used := make([]bool, len(b))
	for wa in a {
		bi := -1
		for wb, j in b {
			if !used[j] && wb.name == wa.name {
				bi = j
				break
			}
		}
		if bi < 0 {
			fmt.sbprintfln(sb, "== window %q: missing in ours", wa.name)
			n += 1
			continue
		}
		used[bi] = true
		before := len(sb.buf)
		n += diff_window(wa, b[bi], opts, sb)
		if len(sb.buf) > before {
			// prepend a header for this window
			body := strings.clone(string(sb.buf[before:]))
			resize(&sb.buf, before)
			fmt.sbprintfln(sb, "== window %q", wa.name)
			strings.write_string(sb, body)
		}
	}
	for wb, j in b {
		if !used[j] {
			fmt.sbprintfln(sb, "== window %q: extra in ours", wb.name)
			n += 1
		}
	}
	return n
}

diff_window :: proc(wa, wb: Window, opts: Opts, sb: ^strings.Builder) -> int {
	n := 0
	ra := make([dynamic]Event, context.temp_allocator)
	rb := make([dynamic]Event, context.temp_allocator)
	for e in wa.events do if e.k == "req" && !ignored(e, opts) do append(&ra, e)
	for e in wb.events do if e.k == "req" && !ignored(e, opts) do append(&rb, e)
	taken := make([]bool, len(rb), context.temp_allocator)
	// matched (official t, ours index) pairs, to detect order changes between
	// requests that are not part of the same burst (> ORDER_SLACK ms apart)
	ORDER_SLACK :: 100.0
	seen := make([dynamic][2]f64, context.temp_allocator)
	for e in ra {
		key := req_key(e)
		match := -1
		for f, j in rb {
			if !taken[j] && req_key(f) == key {
				match = j
				break
			}
		}
		if match < 0 {
			fmt.sbprintfln(sb, "  - missing  %s", key)
			n += 1
			continue
		}
		taken[match] = true
		for prev in seen {
			if f64(match) < prev[1] && (e.t - wa.start) - prev[0] > ORDER_SLACK {
				fmt.sbprintfln(sb, "  ~ order    %s comes earlier in ours", key)
				n += 1
				break
			}
		}
		append(&seen, [2]f64{e.t - wa.start, f64(match)})
		n += diff_request(e, rb[match], wa.start, wb.start, opts, sb)
	}
	for f, j in rb do if !taken[j] {
		fmt.sbprintfln(sb, "  + extra    %s", req_key(f))
		n += 1
	}
	n += diff_gateway(wa, wb, opts, sb)
	return n
}

diff_request :: proc(a, b: Event, sa, sb_start: f64, opts: Opts, sb: ^strings.Builder) -> int {
	n := 0
	key := req_key(a)
	if pa, pb := str(a.v, "proto"), str(b.v, "proto"); pa != pb {
		fmt.sbprintfln(sb, "  ~ %s: proto %q vs %q", key, pa, pb)
		n += 1
	}
	ha, hb := header_pairs(a.v), header_pairs(b.v)
	names_a := make([dynamic]string, context.temp_allocator)
	names_b := make([dynamic]string, context.temp_allocator)
	for h in ha do append(&names_a, h[0].(string) or_else "")
	for h in hb do append(&names_b, h[0].(string) or_else "")
	if strings.join(names_a[:], ",", context.temp_allocator) != strings.join(names_b[:], ",", context.temp_allocator) {
		fmt.sbprintfln(sb, "  ~ %s: header names/order\n      official: %v\n      ours:     %v", key, names_a[:], names_b[:])
		n += 1
	}
	for h in ha {
		name := h[0].(string) or_else ""
		for g in hb {
			if (g[0].(string) or_else "") != name do continue
			va, vb := value_text(h[1]), value_text(g[1])
			if va != vb {
				fmt.sbprintfln(sb, "  ~ %s: header %s\n      official: %s\n      ours:     %s", key, name, va, vb)
				n += 1
			}
			break
		}
	}
	// wire headers: from a netlog the order is real and is compared; from
	// DevTools (sorted) only the set of names is compared
	if wa, wb := get(a.v, "wire"), get(b.v, "wire"); wa != nil && wb != nil {
		ordered := str(a.v, "wire_src") == "netlog" && str(b.v, "wire_src") == "netlog"
		names :: proc(v: etf.Value, sorted: bool) -> string {
			l, _ := v.(etf.List)
			out := make([dynamic]string, context.temp_allocator)
			for h in l {
				p, _ := h.(etf.List)
				if len(p) == 2 do append(&out, strings.to_lower(p[0].(string) or_else "", context.temp_allocator))
			}
			if sorted do slice.sort(out[:])
			return strings.join(out[:], ",", context.temp_allocator)
		}
		if x, y := names(wa, !ordered), names(wb, !ordered); x != y {
			fmt.sbprintfln(sb, "  ~ %s: wire headers (%s)\n      official: %s\n      ours:     %s", key, "order" if ordered else "set", x, y)
			n += 1
		}
		if ordered {
			la, _ := wa.(etf.List)
			lb, _ := wb.(etf.List)
			for h, i in la {
				if i >= len(lb) do break
				pa, _ := h.(etf.List)
				pb, _ := lb[i].(etf.List)
				if len(pa) != 2 || len(pb) != 2 do continue
				if va, vb := value_text(pa[1]), value_text(pb[1]); va != vb && !strings.contains(va, "bytes were stripped") {
					fmt.sbprintfln(sb, "  ~ %s: wire %v\n      official: %s\n      ours:     %s", key, pa[0], va, vb)
					n += 1
				}
			}
		}
	}
	if ba, bb := shape_of(get(a.v, "body")), shape_of(get(b.v, "body")); ba != bb {
		fmt.sbprintfln(sb, "  ~ %s: body shape\n      official: %s\n      ours:     %s", key, ba, bb)
		n += 1
	}
	if a.resp != nil && b.resp != nil {
		if x, y := num(a.resp, "status"), num(b.resp, "status"); x != y {
			fmt.sbprintfln(sb, "  ~ %s: status %v vs %v", key, x, y)
			n += 1
		}
	}
	dt := (b.t - sb_start) - (a.t - sa)
	if abs(dt) > opts.tol {
		fmt.sbprintfln(sb, "  ~ %s: timing %+.0f ms (tolerance %.0f)", key, dt, opts.tol)
		n += 1
	}
	return n
}

diff_gateway :: proc(wa, wb: Window, opts: Opts, sb: ^strings.Builder) -> int {
	n := 0
	collect :: proc(w: Window, k: string) -> [dynamic]Event {
		out := make([dynamic]Event, context.temp_allocator)
		for e in w.events do if e.k == k do append(&out, e)
		return out
	}
	sa, sbb := collect(wa, "ws_send"), collect(wb, "ws_send")
	for i in 0 ..< max(len(sa), len(sbb)) {
		if i >= len(sa) {
			fmt.sbprintfln(sb, "  + extra    gateway send op %v", num(sbb[i].v, "op"))
			n += 1
			continue
		}
		if i >= len(sbb) {
			fmt.sbprintfln(sb, "  - missing  gateway send op %v", num(sa[i].v, "op"))
			n += 1
			continue
		}
		oa, ob := num(sa[i].v, "op"), num(sbb[i].v, "op")
		if oa != ob {
			fmt.sbprintfln(sb, "  ~ gateway send #%d: op %v vs %v", i + 1, oa, ob)
			n += 1
			continue
		}
		da, db := value_text(get(sa[i].v, "d")), value_text(get(sbb[i].v, "d"))
		if oa != 1 && da != db { // heartbeats carry the sequence number
			fmt.sbprintfln(sb, "  ~ gateway send #%d op %v payload\n      official: %s\n      ours:     %s", i + 1, oa, da, db)
			n += 1
		}
	}
	if opts.recv {
		ra, rb := collect(wa, "ws_recv"), collect(wb, "ws_recv")
		names :: proc(l: [dynamic]Event) -> string {
			parts := make([dynamic]string, context.temp_allocator)
			for e in l do append(&parts, str(e.v, "ev") if str(e.v, "ev") != "" else fmt.tprintf("op%v", num(e.v, "op")))
			return strings.join(parts[:], ",", context.temp_allocator)
		}
		if x, y := names(ra), names(rb); x != y {
			fmt.sbprintfln(sb, "  ~ gateway recv sequence\n      official: %s\n      ours:     %s", x, y)
			n += 1
		}
	}
	return n
}
