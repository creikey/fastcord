// trafficdiff: compares two traffic fixtures (official vs ours) mark window by
// mark window and exits 1 when they differ.
//
//   trafficdiff [-tol:MS] [-ignore:SUBSTR]... [-recv] [-actions] official.jsonl ours.jsonl
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
// Everything is allocated and never freed: the process is short-lived.

Event :: struct {
    t: float64;
    k: string;
    v: etf.Value;
    resp: etf.Value;  // req: matching resp
}

Window :: struct {
    name: string;
    start: float64;
    events: [..]Event;
}

Opts :: struct {
    tol: float64 = 1500;
    ignore: [..]string;
    recv: bool;
    actions: bool;  // compare only action windows (session runs: preludes and launches differ)
}

main :: () {
    opts: Opts;
    files: [..]string;
    args := get_command_line_arguments();
    for args {
        if it_index == 0 continue;
        if begins_with(it, "-tol:")         opts.tol = string_to_float64(slice(it, 5, it.count - 5));
        else if begins_with(it, "-ignore:") array_add(*opts.ignore, slice(it, 8, it.count - 8));
        else if it == "-recv"               opts.recv = true;
        else if it == "-actions"            opts.actions = true;
        else                                array_add(*files, it);
    }
    if files.count != 2 {
        print("usage: trafficdiff [-tol:MS] [-ignore:SUBSTR]... [-recv] [-actions] official.jsonl ours.jsonl\n", to_standard_error = true);
        exit(2);
    }
    a, aok := load(files[0]);
    b, bok := load(files[1]);
    if !aok || !bok {
        print("cannot read fixtures\n", to_standard_error = true);
        exit(2);
    }
    sb: String_Builder;
    n := diff(a, b, opts, *sb);
    write_builder(*sb);
    if n > 0 {
        print("% difference(s)\n", n);
        exit(1);
    }
    print("traffic matches\n");
}

load :: (path: string) -> []Window, bool {
    text, ok := read_entire_file(path);
    if !ok return .[], false;
    wins: [..]Window;
    array_add(*wins, .{name = "(before first mark)"});
    reqs: Table(string, int);  // "acct/id" -> index in current window
    for raw: split(text, "\n") {
        line := trim_right(raw, "\r");
        if !line continue;
        v, err := etf.from_json(line);
        if err != .None continue;
        k, t := str(v, "k"), num(v, "t");
        w := *wins[wins.count - 1];
        if k == "mark" {
            array_add(*wins, .{name = str(v, "name"), start = t});
            table_reset(*reqs);
        } else if k == "resp" {
            found, i := table_find(*reqs, sprint("%/%", acct(v), num(v, "id")));
            if found w.events[i].resp = v;
        } else {
            if k == "req" table_set(*reqs, sprint("%/%", acct(v), num(v, "id")), w.events.count);
            array_add(*w.events, .{t = t, k = k, v = v});
        }
    }
    return wins, true;
}

get :: (v: etf.Value, key: string) -> etf.Value {
    if v.kind != .Map return .{};
    x := etf.map_get(v.map, key);
    return x;
}

str :: (v: etf.Value, key: string) -> string {
    x := get(v, key);
    return ifx x.kind == .String then x.s else "";
}

as_str :: (v: etf.Value) -> string { return ifx v.kind == .String then v.s else ""; }

as_list :: (v: etf.Value) -> []etf.Value { return ifx v.kind == .List then v.list else .[]; }

num :: (v: etf.Value, key: string) -> float64 {
    x := get(v, key);
    if x.kind == .Int   return cast(float64) x.i;
    if x.kind == .Float return x.f;
    return 0;
}

acct :: (v: etf.Value) -> string {
    a := str(v, "acct");
    return ifx a then a else "a";
}

is_digit :: (c: u8) -> bool { return c >= #char "0" && c <= #char "9"; }

// norm makes per-run values comparable: "<kind:N>" -> "<kind>", digit runs of
// snowflake length -> "{id}".
norm :: (s: string) -> string {
    sb: String_Builder;
    sb.allocator = temp;
    i := 0;
    while i < s.count {
        if s[i] == #char "<" {
            end := find_index_from_left(s, #char ">", i) - i;
            if end > 0 {
                inner := slice(s, i + 1, end - 1);
                c := find_index_from_right(inner, #char ":");
                if c > 0 {
                    digits := true;
                    for cast([]u8) slice(inner, c + 1, inner.count - c - 1) if !is_digit(it) digits = false;
                    if digits {
                        print_to_builder(*sb, "<%>", slice(inner, 0, c));
                        i += end + 1;
                        continue;
                    }
                }
            }
        }
        if is_digit(s[i]) {
            j := i;
            while j < s.count && is_digit(s[j]) j += 1;
            append(*sb, ifx j - i >= 17 && j - i <= 20 then "{id}" else slice(s, i, j - i));
            i = j;
            continue;
        }
        append(*sb, s[i]);
        i += 1;
    }
    return builder_to_string(*sb,, temp);
}

// template: scheme+host+path with ids normalized, query keys kept, values dropped.
template :: (url: string) -> string {
    found, base, query := split_from_left(url, #char "?");
    sb: String_Builder;
    append(*sb, norm(base));
    if found && query {
        append(*sb, "?");
        parts := split(query, "&",, temp);
        if !parts[parts.count - 1] parts.count -= 1;  // a trailing "&" adds no key
        for part, i: parts {
            if i append(*sb, "&");
            _, key := split_from_left(part, #char "=");
            append(*sb, key);
        }
    }
    return builder_to_string(*sb);
}

req_key :: (e: Event) -> string {
    return tprint("% % %", acct(e.v), str(e.v, "method"), template(str(e.v, "url")));
}

ignored :: (e: Event, opts: Opts) -> bool {
    url := str(e.v, "url");
    for opts.ignore if contains(url, it) return true;
    return false;
}

// pairs: the [name, value] two-item lists of a headers array.
pairs :: (v: etf.Value) -> [][]etf.Value {
    out: [..][]etf.Value;
    out.allocator = temp;
    for as_list(v) if it.kind == .List && it.list.count == 2 array_add(*out, it.list);
    return out;
}

// value_text renders a JSON value with placeholders/ids normalized.
value_text :: (v: etf.Value) -> string {
    sb: String_Builder;
    sb.allocator = temp;
    etf.to_json(v, *sb);
    return norm(builder_to_string(*sb,, temp));
}

// shape renders structure only: object keys (in order) and value types.
shape :: (v: etf.Value, sb: *String_Builder, depth := 0) {
    if v.kind == {
      case .Nil;   append(sb, "null");
      case .Bool;  append(sb, "bool");
      case .Int; #through;
      case .Float; #through;
      case .Big;   append(sb, "num");
      case .String; #through;
      case .Atom; #through;
      case .Charlist; append(sb, "str");
      case .Tuple; append(sb, "tuple");
      case .List;
        append(sb, "[");
        if v.list.count && depth < 12 shape(v.list[0], sb, depth + 1);
        append(sb, "]");
      case .Map;
        if depth >= 12 { append(sb, "{..}"); return; }
        append(sb, "{");
        for v.map {
            if it_index append(sb, ",");
            append(sb, as_str(it.key));
            append(sb, ":");
            shape(it.value, sb, depth + 1);
        }
        append(sb, "}");
    }
}

shape_of :: (v: etf.Value) -> string {
    sb: String_Builder;
    sb.allocator = temp;
    shape(v, *sb);
    return builder_to_string(*sb,, temp);
}

// conn_facts: first h2/h3 session per (account, kind, host) and its
// client-side facts, with per-run noise (RTT estimate, GREASE ids) removed.
conn_facts :: (wins: []Window) -> Table(string, string) {
    out: Table(string, string);
    for w: wins for e: w.events {
        if e.k != "conn" continue;
        kind := str(e.v, "kind");
        if kind != "h2" && kind != "h3" continue;
        key := sprint("% % %", acct(e.v), kind, str(e.v, "host"));
        if table_find_pointer(*out, key) continue;
        sb: String_Builder;
        for f: string.["send_settings", "send_window_update", "http3_settings_sent", "transport_parameters_sent"] {
            v := get(e.v, f);
            if !etf.is_nil(v) print_to_builder(*sb, "%=% ", f, value_text(v));
        }
        tls := get(e.v, "tls");
        if !etf.is_nil(tls) print_to_builder(*sb, "alpn=% ", str(tls, "next_proto"));
        txt := builder_to_string(*sb);
        // GREASE settings and the RTT estimate differ on every connection
        while true {
            i := find_index_from_left(txt, "UNSUPPORTED_SETTINGS_TYPE(");
            if i < 0 break;
            j := find_index_from_left(txt, #char ",", i);
            if j < 0 j = find_index_from_left(txt, #char "}", i);
            txt = join(slice(txt, 0, i), "GREASE", slice(txt, j, txt.count - j));
        }
        RTT :: "initial_round_trip_time ";
        i := find_index_from_left(txt, RTT);
        if i >= 0 {
            j := i + RTT.count;
            while j < txt.count && is_digit(txt[j]) j += 1;
            txt = join(slice(txt, 0, i), "initial_round_trip_time *", slice(txt, j, txt.count - j));
        }
        table_set(*out, key, txt);
    }
    return out;
}

diff :: (a: []Window, b: []Window, opts: Opts, sb: *String_Builder) -> int {
    n := 0;
    if !opts.actions {  // sessions are compared once, in cold_start
        ca, cb := conn_facts(a), conn_facts(b);
        for va, k: ca {
            found, vb := table_find(*cb, k);
            if found && va != vb {
                print_to_builder(sb, "== connection %\n      official: %\n      ours:     %\n", k, va, vb);
                n += 1;
            }
        }
    }
    used := NewArray(b.count, bool);
    prelude :: (name: string) -> bool { return name == "setup" || name == "setup_b" || name == "(before first mark)"; }
    if opts.actions for b if prelude(it.name) used[it_index] = true;
    for wa: a {
        if opts.actions && prelude(wa.name) continue;
        bi := -1;
        for b if !used[it_index] && it.name == wa.name { bi = it_index; break; }
        if bi < 0 {
            print_to_builder(sb, "== window %: missing in ours\n", quote(wa.name));
            n += 1;
            continue;
        }
        used[bi] = true;
        body: String_Builder;
        n += diff_window(wa, b[bi], opts, *body);
        if builder_string_length(*body) {
            print_to_builder(sb, "== window %\n", quote(wa.name));
            append(sb, builder_to_string(*body));
        }
    }
    for b if !used[it_index] {
        print_to_builder(sb, "== window %: extra in ours\n", quote(it.name));
        n += 1;
    }
    return n;
}

quote :: (s: string) -> string {
    q, _ := replace(replace(s, "\\", "\\\\"), "\"", "\\\"");
    return tprint("\"%\"", q);
}

diff_window :: (wa: Window, wb: Window, opts: Opts, sb: *String_Builder) -> int {
    n := 0;
    ra, rb: [..]Event;
    for wa.events if it.k == "req" && !ignored(it, opts) array_add(*ra, it);
    for wb.events if it.k == "req" && !ignored(it, opts) array_add(*rb, it);
    taken := NewArray(rb.count, bool);
    // A window that restarts the app is timed from its gateway open: how long
    // the official app took to boot varies run to run (1-2 s), and every
    // request after it would otherwise carry that offset.
    // Requests after READY are timed from READY (the server's READY latency
    // varies 0.6-2.3 s), earlier ones from the gateway open.
    first :: (w: Window, k: string, ev := "") -> float64 {
        for w.events if it.k == k && (!ev || str(it.v, "ev") == ev) return it.t;
        return -1;
    }
    sa, sbs := wa.start, wb.start;
    oa, ob := first(wa, "ws_open"), first(wb, "ws_open");
    if oa >= 0 && ob >= 0 sa, sbs = oa, ob;
    ready_a, ready_b := first(wa, "ws_recv", "READY"), first(wb, "ws_recv", "READY");
    anchors :: (ea: Event, eb: Event, sa: float64, sbs: float64, ra: float64, rb: float64) -> float64, float64 {
        if ra >= 0 && rb >= 0 && ea.t >= ra && eb.t >= rb return ra, rb;
        return sa, sbs;
    }
    // matched (official t, ours index) pairs, to detect order changes between
    // requests that are not part of the same burst (> ORDER_SLACK ms apart)
    ORDER_SLACK :: 100.0;
    Seen :: struct { t: float64; match: int; key: string; }
    seen: [..]Seen;
    for e: ra {
        key := req_key(e);
        // same-key requests (science batches, repeated GETs): the unused one
        // closest in window time, so one early/late batch does not shift the rest
        match := -1;
        best := FLOAT64_MAX;
        for f, j: rb {
            if taken[j] || req_key(f) != key continue;
            x, y := anchors(e, f, sa, sbs, ready_a, ready_b);
            d := abs((f.t - y) - (e.t - x));
            if d < best { best = d; match = j; }
        }
        if match < 0 {
            print_to_builder(sb, "  - missing  %\n", key);
            n += 1;
            continue;
        }
        taken[match] = true;
        for seen if match < it.match && (e.t - wa.start) - it.t > ORDER_SLACK {
            print_to_builder(sb, "  ~ order    % comes earlier in ours (than %)\n", key, it.key);
            n += 1;
            break;
        }
        array_add(*seen, .{e.t - wa.start, match, key});
        xa, xb := anchors(e, rb[match], sa, sbs, ready_a, ready_b);
        n += diff_request(e, rb[match], xa, xb, opts, sb);
    }
    for rb if !taken[it_index] {
        print_to_builder(sb, "  + extra    %\n", req_key(it));
        n += 1;
    }
    return n + diff_gateway(wa, wb, opts, sb);
}

diff_request :: (a: Event, b: Event, sa: float64, sb_start: float64, opts: Opts, sb: *String_Builder) -> int {
    n := 0;
    key := req_key(a);
    pa, pb := str(a.v, "proto"), str(b.v, "proto");
    if pa != pb {
        print_to_builder(sb, "  ~ %: proto % vs %\n", key, quote(pa), quote(pb));
        n += 1;
    }
    ha, hb := pairs(get(a.v, "headers")), pairs(get(b.v, "headers"));
    names_a, names_b: [..]string;
    for ha array_add(*names_a, as_str(it[0]));
    for hb array_add(*names_b, as_str(it[0]));
    if join(..names_a, ",") != join(..names_b, ",") {
        print_to_builder(sb, "  ~ %: header names/order\n      official: %\n      ours:     %\n", key, names_a, names_b);
        n += 1;
    }
    for h: ha {
        name := as_str(h[0]);
        for g: hb {
            if as_str(g[0]) != name continue;
            va, vb := value_text(h[1]), value_text(g[1]);
            if va != vb {
                print_to_builder(sb, "  ~ %: header %\n      official: %\n      ours:     %\n", key, name, va, vb);
                n += 1;
            }
            break;
        }
    }
    // wire headers: from a netlog the order is real and is compared; from
    // DevTools (sorted) only the set of names is compared
    wa, wb := get(a.v, "wire"), get(b.v, "wire");
    if !etf.is_nil(wa) && !etf.is_nil(wb) {
        ordered := str(a.v, "wire_src") == "netlog" && str(b.v, "wire_src") == "netlog";
        names :: (v: etf.Value, sorted: bool) -> string {
            out: [..]string;
            for pairs(v) array_add(*out, to_lower_copy(as_str(it[0])));
            if sorted quick_sort(out, compare);
            return join(..out, ",");
        }
        x, y := names(wa, !ordered), names(wb, !ordered);
        if x != y {
            print_to_builder(sb, "  ~ %: wire headers (%)\n      official: %\n      ours:     %\n", key, ifx ordered then "order" else "set", x, y);
            n += 1;
        }
        if ordered {
            la, lb := as_list(wa), as_list(wb);
            for h, i: la {
                if i >= lb.count break;
                if h.kind != .List || h.list.count != 2 || lb[i].kind != .List || lb[i].list.count != 2 continue;
                va, vb := value_text(h.list[1]), value_text(lb[i].list[1]);
                if va != vb && !contains(va, "bytes were stripped") {
                    print_to_builder(sb, "  ~ %: wire %\n      official: %\n      ours:     %\n", key, as_str(h.list[0]), va, vb);
                    n += 1;
                }
            }
        }
    }
    ba, bb := shape_of(get(a.v, "body")), shape_of(get(b.v, "body"));
    if ba != bb {
        print_to_builder(sb, "  ~ %: body shape\n      official: %\n      ours:     %\n", key, ba, bb);
        n += 1;
    }
    if !etf.is_nil(a.resp) && !etf.is_nil(b.resp) {
        x, y := num(a.resp, "status"), num(b.resp, "status");
        if x != y {
            print_to_builder(sb, "  ~ %: status % vs %\n", key, x, y);
            n += 1;
        }
    }
    dt := (b.t - sb_start) - (a.t - sa);
    if abs(dt) > opts.tol {
        // whole ms, halves to even (as the Odin tool printed them)
        whole :: (x: float64) -> s64 {
            r := floor(x);
            if x - r > 0.5 || (x - r == 0.5 && fmod_cycling(r, 2) != 0) r += 1;
            return cast(s64) r;
        }
        print_to_builder(sb, "  ~ %: timing %0% ms (tolerance %)\n", key, ifx dt >= 0 then "+" else "", whole(dt), whole(opts.tol));
        n += 1;
    }
    return n;
}

diff_gateway :: (wa: Window, wb: Window, opts: Opts, sb: *String_Builder) -> int {
    n := 0;
    collect :: (w: Window, k: string) -> [..]Event {
        out: [..]Event;
        for w.events if it.k == k array_add(*out, it);
        return out;
    }
    sa, sbb := collect(wa, "ws_send"), collect(wb, "ws_send");
    for i: 0..max(sa.count, sbb.count)-1 {
        if i >= sa.count {
            print_to_builder(sb, "  + extra    gateway send op %\n", num(sbb[i].v, "op"));
            n += 1;
            continue;
        }
        if i >= sbb.count {
            print_to_builder(sb, "  - missing  gateway send op %\n", num(sa[i].v, "op"));
            n += 1;
            continue;
        }
        oa, ob := num(sa[i].v, "op"), num(sbb[i].v, "op");
        if oa != ob {
            print_to_builder(sb, "  ~ gateway send #%: op % vs %\n", i + 1, oa, ob);
            n += 1;
            continue;
        }
        da, db := value_text(get(sa[i].v, "d")), value_text(get(sbb[i].v, "d"));
        if oa != 1 && da != db {  // heartbeats carry the sequence number
            print_to_builder(sb, "  ~ gateway send #% op % payload\n      official: %\n      ours:     %\n", i + 1, oa, da, db);
            n += 1;
        }
    }
    if opts.recv {
        names :: (l: []Event) -> string {
            parts: [..]string;
            for l {
                ev := str(it.v, "ev");
                array_add(*parts, ifx ev then ev else tprint("op%", num(it.v, "op")));
            }
            return join(..parts, ",");
        }
        x, y := names(collect(wa, "ws_recv")), names(collect(wb, "ws_recv"));
        if x != y {
            print_to_builder(sb, "  ~ gateway recv sequence\n      official: %\n      ours:     %\n", x, y);
            n += 1;
        }
    }
    return n;
}
