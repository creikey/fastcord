// scrub: raw capture (.secrets/raw/*.jsonl, see tools/capture) -> committable
// fixture (traffic/<scenario>.jsonl, format in traffic/README.md).
//
//   scrub <raw.jsonl> <out.jsonl> [env]   convert (env = tests/scenarios/env, the allowlist)
//   scrub verify <raw.jsonl> <out.jsonl>  fail if any secret from raw survives in out
//
// Kept data lives in context.allocator and is never freed (the process is short-lived); each
// raw line is parsed into temp, which is reset before the next line.

main :: () {
    args := get_command_line_arguments();
    if args.count >= 4 && args[1] == "verify" {
        raw, ok1 := read_entire_file(args[2]);
        out, ok2 := read_entire_file(args[3]);
        if !ok1 || !ok2 fail(2, "cannot read inputs");
        problems := verify(raw, out);
        for problems print("LEAK: %\n", it, to_standard_error = true);
        if problems.count exit(1);
        print("verify ok: %\n", args[3]);
        return;
    }
    if args.count < 3 fail(2, "usage: scrub <raw.jsonl> <out.jsonl> [env] [-netlog-a:FILE] [-netlog-b:FILE] | scrub verify <raw.jsonl> <out.jsonl>");
    raw, ok := read_entire_file(args[1]);
    if !ok fail(2, tprint("cannot read %", args[1]));
    envp := "tests/scenarios/env";
    netlogs: [2]string;
    for args {
        if it_index < 3 continue;
        if begins_with(it, "-netlog-a:")      netlogs[0] = slice(it, 10, it.count - 10);
        else if begins_with(it, "-netlog-b:") netlogs[1] = slice(it, 10, it.count - 10);
        else                                  envp = it;
    }
    env := read_entire_file(envp, log_errors = false);
    out := convert(raw, env, netlogs);
    if !write_entire_file(args[2], out) fail(1, tprint("cannot write %", args[2]));
    problems := verify(raw, out);
    for problems print("LEAK: %\n", it, to_standard_error = true);
    if problems.count {
        file_delete(args[2]);
        fail(1, tprint("refusing to keep %", args[2]));
    }
    lines := 0;
    for cast([]u8) out if it == #char "\n" lines += 1;
    print("% -> % (% lines)\n", args[1], args[2], lines);
}

fail :: (code: s32, msg: string) {
    print("%\n", msg, to_standard_error = true);
    exit(code);
}

lines_of :: (text: string) -> []string {
    lines := split(text, "\n");
    for * lines it.* = trim_right(it.*, "\r");
    return lines;
}

b64_decode :: (s: string) -> string, bool {
    t := trim(s);
    d, ok := base64_decode(t);
    if ok return d, true;
    // url-safe variant (unpadded input is accepted as is)
    u := replace(replace(t, "-", "+"), "_", "/");
    d, ok = base64_decode(u);
    return d, ok;
}

Req :: struct {
    t, resp_t: float64;
    acct, method, url, type, proto: string;
    conn: float64;
    reused: bool;
    status: int;
    headers: etf.Value;       // CDP headers object (request)
    wire_headers: etf.Value;  // ExtraInfo (actual wire, incl. pseudo/cookie)
    resp_headers: etf.Value;
    resp_wire: etf.Value;
    post: string;
    has_post: bool;
    body: string;
    body_b64: bool;
    has_body: bool;
    has_resp: bool;
    cached: bool;
}

Ws :: struct {
    t: float64;
    acct, url: string;
    headers: etf.Value;
    closed: float64;
    id: int;
}

Line :: struct {
    t: float64;
    seq: int;
    v: etf.Value;
}

get :: (v: etf.Value, keys: ..string) -> etf.Value {
    cur := v;
    for keys {
        if cur.kind != .Map return .{};
        cur = etf.map_get(cur.map, it);
    }
    return cur;
}

as_str :: (v: etf.Value) -> string { return ifx v.kind == .String then v.s else ""; }
as_list :: (v: etf.Value) -> []etf.Value { return ifx v.kind == .List then v.list else .[]; }
gs :: (v: etf.Value, keys: ..string) -> string { return as_str(get(v, ..keys)); }
gb :: (v: etf.Value, keys: ..string) -> bool { x := get(v, ..keys); return x.kind == .Bool && x.b; }
gn :: (v: etf.Value, keys: ..string) -> float64 {
    x := get(v, ..keys);
    if x.kind == .Int   return cast(float64) x.i;
    if x.kind == .Float return x.f;
    return 0;
}

obj :: (pairs: ..etf.Pair) -> etf.Value { return etf.vmap(array_copy(pairs)); }
P :: (k: string, v: etf.Value) -> etf.Pair { return .{etf.vstring(k), v}; }
P :: (k: string, v: string) -> etf.Pair { return P(k, etf.vstring(v)); }
P :: (k: string, v: s64) -> etf.Pair { return P(k, etf.vint(v)); }
P :: (k: string, v: float64) -> etf.Pair { return P(k, etf.vfloat(v)); }
P :: (k: string, v: bool) -> etf.Pair { return P(k, etf.vbool(v)); }

load_allowlist :: (c: *Ctx, env: string) {
    for line: lines_of(env,, temp) {
        found, _, value := split_from_left(line, #char "=");
        if !found || begins_with(trim(line), "#") continue;
        v := trim(value);
        if is_snowflake_digits(v) table_set(*c.allow, copy_string(v), true);
    }
}

// keep_request decides which requests belong in a fixture: real network
// traffic a native client could also produce (no web-app bundle assets, no
// cache hits, no browser-internal schemes).
keep_request :: (r: *Req) -> bool {
    if r.cached return false;
    if !begins_with(r.url, "https://") && !begins_with(r.url, "http://") return false;
    if array_find(string.["Script", "Stylesheet", "Font", "Manifest", "TextTrack", "Document", "Media", "SignedExchange", "CSPViolationReport"], r.type) return false;
    if r.type == "Image" return contains(r.url, "cdn.discordapp.com/") || contains(r.url, "media.discordapp.net/");
    // fastcord's launch navigation (/app?_=) is a Document officially, and the official cold start is a reload
    return !contains(r.url, "discord.com/assets/") && !contains(r.url, "discord.com/app?_=");
}

header_pair :: (c: *Ctx, name: string, value: string) -> etf.Value {
    sv, special := header_rule(c, name, value);
    if !special sv = etf.vstring(scrub_text(c, value));
    pair := NewArray(2, etf.Value);
    pair[0] = etf.vstring(name);
    pair[1] = sv;
    return etf.vlist(pair);
}

headers_list :: (c: *Ctx, h: etf.Value) -> etf.Value {
    if h.kind != .Map return etf.vlist(.[]);
    out: [..]etf.Value;
    for h.map {
        name := copy_string(as_str(it.key));
        // CDP joins repeated headers with '\n'
        for part: split(as_str(it.value), "\n",, temp) array_add(*out, header_pair(c, name, part));
    }
    return etf.vlist(out);
}

wire_list :: (c: *Ctx, hs: []Header) -> etf.Value {
    out := NewArray(hs.count, etf.Value);
    for hs out[it_index] = header_pair(c, it.name, it.value);
    return etf.vlist(out);
}

MAX_JSON_BODY :: 256 * 1024;

body_value :: (c: *Ctx, body: string, is_b64: bool) -> etf.Value {
    data := body;
    if is_b64 {
        d, ok := b64_decode(body);
        if ok data = d;
    }
    // Huge bodies (game detectables, shop catalogs) are static: hash only, keeps the repo small.
    v, err := etf.from_json(data,, temp);
    if err == .None && data.count > 0 && data.count <= MAX_JSON_BODY && (v.kind == .Map || v.kind == .List) return scrub_value(c, v, "");
    if data.count <= 4096 {
        // small text bodies are scrubbed as text first, then stored as base64
        if utf8_ok(data) data = scrub_text(c, data);
        return obj(P("$b64", base64_encode(data)), P("len", data.count));
    }
    sb: String_Builder;
    for crypto.sha256(cast([]u8) data) print_to_builder(*sb, "%", formatInt(it, base = 16, minimum_digits = 2));
    return obj(P("$sha256", builder_to_string(*sb)), P("len", data.count));
}

// utf8_ok: well-formed UTF-8 without U+FFFD (what decoding rune by rune would report as errors).
utf8_ok :: (s: string) -> bool {
    i := 0;
    while i < s.count {
        c := s[i];
        if c < 0x80 { i += 1; continue; }
        n, lo, hi := 0, 0x80, 0xBF;
        if c >= 0xC2 && c <= 0xDF n = 2;
        else if c >= 0xE0 && c <= 0xEF { n = 3; if c == 0xE0 lo = 0xA0; if c == 0xED hi = 0x9F; }
        else if c >= 0xF0 && c <= 0xF4 { n = 4; if c == 0xF0 lo = 0x90; if c == 0xF4 hi = 0x8F; }
        else return false;
        if i + n > s.count || s[i + 1] < lo || s[i + 1] > hi return false;
        for k: 2..n-1 if s[i + k] < 0x80 || s[i + k] > 0xBF return false;
        if c == 0xEF && s[i + 1] == 0xBF && s[i + 2] == 0xBD return false;
        i += n;
    }
    return true;
}

// convert turns raw capture text into fixture text.
convert :: (raw: string, env: string, netlogs := string.["", ""]) -> string {
    c: Ctx;
    load_allowlist(*c, env);
    lines := lines_of(raw);

    // Pass 1: run start time and foreign users.
    for l: lines {
        reset_temporary_storage();
        if !l continue;
        v, err := etf.from_json(l,, temp);
        if err != .None continue;
        wt := gn(v, "m", "params", "wallTime");
        if wt > 0 && gs(v, "m", "method") == "Network.requestWillBeSent" {
            start := cast(s64) (wt * 1000 - gn(v, "rt"));
            if c.run_start_ms == 0 || start < c.run_start_ms c.run_start_ms = start;
        }
        collect_foreign(*c, get(v, "etf"));
        b := gs(v, "m", "result", "body");
        if b.count > 0 && b.count < 8 << 20 {
            bv, berr := etf.from_json(b,, temp);
            if berr == .None collect_foreign(*c, bv);
        }
    }
    reset_temporary_storage();

    last_rt: float64;
    for l: lines {
        i := find_index_from_left(l, "\"rt\":");
        if i < 0 continue;
        k := i + 5;
        while k < l.count && (l[k] == #char "." || (l[k] >= #char "0" && l[k] <= #char "9")) k += 1;
        v, ok, rest := string_to_float64(slice(l, i + 5, k - i - 5));
        if ok && !rest last_rt = max(last_rt, v);
    }
    nls: [2]Netlog;
    for path, i: netlogs {
        if !path || c.run_start_ms == 0 continue;
        start := cast(float64) c.run_start_ms;
        ok := netlog_load(*nls[i], path, start - 5000, start + last_rt + 5000);
        if !ok print("cannot read netlog %\n", path, to_standard_error = true);
    }
    conn_ids: Table(int, s64);
    conn_id :: (m: *Table(int, s64), id: int) -> s64 {
        found, v := table_find(m, id);
        if found return v;
        n := m.count + 1;
        table_add(m, id, n);
        return n;
    }
    reqs: Table(string, *Req);
    order: [..]*Req;
    sockets: Table(string, *Ws);
    ws_order: [..]*Ws;
    out: [..]Line;

    for l: lines {
        reset_temporary_storage();
        if !l continue;
        v, err := etf.from_json(l,, temp);
        if err != .None continue;
        rt := gn(v, "rt");
        acct := gs(v, "acct");
        name := gs(v, "mark");
        if name {
            if acct == "a" emit(*out, rt, obj(P("t", rt), P("k", "mark"), P("name", copy_string(name))).map);
            continue;
        }
        g := get(v, "gw");
        if !etf.is_nil(g) {
            _, w := table_find(*sockets, tprint("%/%", acct, gs(g, "ws")));
            e := get(v, "etf");
            ev := gs(e, "t");
            pairs: [..]etf.Pair;
            array_add(*pairs, P("t", rt), P("k", ifx gs(g, "dir") == "send" then "ws_send" else "ws_recv"));
            if acct != "a" array_add(*pairs, P("acct", copy_string(acct)));
            array_add(*pairs, P("id", ifx w then w.id else 0), P("op", get(e, "op")));
            if ev array_add(*pairs, P("ev", copy_string(ev)));
            s := get(e, "s");
            if !etf.is_nil(s) array_add(*pairs, P("seq", s));
            array_add(*pairs, P("d", scrub_value(*c, get(e, "d"), "")));
            emit(*out, rt, pairs);
            continue;
        }
        rid := gs(v, "body_for");
        if rid {
            found, r := table_find(*reqs, tprint("%/%/%", acct, gs(v, "s"), rid));
            if found {
                r.body = copy_string(gs(v, "m", "result", "body"));
                r.body_b64 = gb(v, "m", "result", "base64Encoded");
                r.has_body = true;
            }
            continue;
        }
        m := get(v, "m");
        method := gs(m, "method");
        p := get(m, "params");
        rid = gs(p, "requestId");
        key := tprint("%/%/%", acct, gs(m, "sessionId"), rid);
        _, r := table_find(*reqs, key);
        _, w := table_find(*sockets, tprint("%/%", acct, rid));
        if method == {
          case "Network.requestWillBeSent";
            if r r.cached = true;  // redirect: keep the final hop only
            r = New(Req);
            r.t = rt;
            r.acct = copy_string(acct);
            r.method = copy_string(gs(p, "request", "method"));
            r.url = copy_string(gs(p, "request", "url"));
            r.type = copy_string(gs(p, "type"));
            r.headers = clone_value(get(p, "request", "headers"));
            r.post = copy_string(gs(p, "request", "postData"));
            r.has_post = gb(p, "request", "hasPostData");
            table_set(*reqs, copy_string(key), r);
            array_add(*order, r);
          case "Network.requestWillBeSentExtraInfo";
            if r r.wire_headers = clone_value(get(p, "headers"));
          case "Network.requestServedFromCache";
            if r r.cached = true;
          case "Network.responseReceived";
            if r {
                r.has_resp = true;
                r.resp_t = rt;
                r.status = cast(int) gn(p, "response", "status");
                r.proto = copy_string(gs(p, "response", "protocol"));
                r.conn = gn(p, "response", "connectionId");
                r.reused = gb(p, "response", "connectionReused");
                r.resp_headers = clone_value(get(p, "response", "headers"));
                if gb(p, "response", "fromDiskCache") || gb(p, "response", "fromPrefetchCache") || gb(p, "response", "fromServiceWorker") r.cached = true;
            }
          case "Network.responseReceivedExtraInfo";
            if r r.resp_wire = clone_value(get(p, "headers"));
          case "Network.webSocketCreated";
            w = New(Ws);
            w.t = rt;
            w.acct = copy_string(acct);
            w.url = copy_string(gs(p, "url"));
            w.id = ws_order.count + 1;
            table_set(*sockets, sprint("%/%", acct, rid), w);
            array_add(*ws_order, w);
          case "Network.webSocketWillSendHandshakeRequest";
            if w w.headers = clone_value(get(p, "request", "headers"));
          case "Network.webSocketHandshakeResponseReceived";
            rh := get(p, "response", "requestHeaders");
            if w && !etf.is_nil(rh) w.headers = clone_value(rh);
          case "Network.webSocketClosed";
            if w w.closed = rt;
        }
    }
    reset_temporary_storage();

    next_id := 0;
    for r: order {
        if !keep_request(r) continue;
        next_id += 1;
        id := next_id;
        pairs: [..]etf.Pair;
        array_add(*pairs, P("t", r.t), P("k", "req"));
        if r.acct != "a" array_add(*pairs, P("acct", r.acct));
        array_add(*pairs, P("id", id), P("proto", r.proto), P("method", r.method), P("url", scrub_text(*c, r.url)));
        array_add(*pairs, P("conn", cast(s64) r.conn), P("reused", r.reused));
        // headers: Chrome's request header list in its own order (always present).
        // wire: what the network stack actually sent (pseudo-headers, cookie,
        // accept-encoding...) when CDP reports it; CDP sorts these by name, so
        // the true wire order is only in a netlog.
        array_add(*pairs, P("headers", headers_list(*c, r.headers)));
        nl := *nls[ifx r.acct == "b" then 1 else 0];
        nr := ifx nl.loaded then netlog_match(nl, r.method, r.url, cast(float64) c.run_start_ms + r.t) else null;
        if nr {
            // true wire order from the netlog (Chrome strips cookie/auth values there)
            array_add(*pairs, P("wire", wire_list(*c, nr.headers)), P("wire_src", "netlog"));
            if nr.proto == "h2" || nr.proto == "h3" array_add(*pairs, P("session", conn_id(*conn_ids, nr.session)));
            if !etf.is_nil(nr.extra) array_add(*pairs, P("h2", nr.extra));
            if !r.proto for *pairs if as_str(it.key) == "proto" it.value = etf.vstring(nr.proto);
        } else if !etf.is_nil(r.wire_headers) {
            array_add(*pairs, P("wire", headers_list(*c, r.wire_headers)), P("wire_src", "cdp_sorted"));
        }
        if r.post array_add(*pairs, P("body", body_value(*c, r.post, false)));
        else if r.has_post array_add(*pairs, P("body", obj(P("$omitted", true))));
        emit(*out, r.t, pairs);
        if r.has_resp {
            rp: [..]etf.Pair;
            array_add(*rp, P("t", r.resp_t), P("k", "resp"));
            if r.acct != "a" array_add(*rp, P("acct", r.acct));
            array_add(*rp, P("id", id), P("status", r.status));
            array_add(*rp, P("headers", headers_list(*c, r.resp_headers)));
            if r.has_body array_add(*rp, P("body", body_value(*c, r.body, r.body_b64)));
            emit(*out, r.resp_t, rp);
        }
    }
    for w: ws_order {
        pairs: [..]etf.Pair;
        array_add(*pairs, P("t", w.t), P("k", "ws_open"));
        if w.acct != "a" array_add(*pairs, P("acct", w.acct));
        array_add(*pairs, P("id", w.id), P("url", scrub_text(*c, w.url)), P("headers", headers_list(*c, w.headers)));
        nl := *nls[ifx w.acct == "b" then 1 else 0];
        if nl.loaded {
            hu := replace(w.url, "wss://", "https://");  // the scheme only occurs once
            nr := netlog_match(nl, "GET", hu, cast(float64) c.run_start_ms + w.t);
            if nr array_add(*pairs, P("wire", wire_list(*c, nr.headers)), P("wire_src", "netlog"));
        }
        emit(*out, w.t, pairs);
        if w.closed > 0 {
            cp: [..]etf.Pair;
            array_add(*cp, P("t", w.closed), P("k", "ws_close"));
            if w.acct != "a" array_add(*cp, P("acct", w.acct));
            array_add(*cp, P("id", w.id), P("code", etf.Value.{}));
            emit(*out, w.closed, cp);
        }
    }
    for nl, i: nls {
        if !nl.loaded continue;
        for cn: nl.order {
            t := cn.wall - cast(float64) c.run_start_ms;
            pairs: [..]etf.Pair;
            array_add(*pairs, P("t", t), P("k", "conn"));
            if i == 1 array_add(*pairs, P("acct", "b"));
            if cn.kind != "alt_svc" array_add(*pairs, P("session", conn_id(*conn_ids, cn.id)));
            array_add(*pairs, P("kind", cn.kind), P("host", cn.host));
            // repeated events (priority updates, version notes...) become one list, in first-seen order
            Group :: struct { k: string; vals: [..]etf.Value; }
            groups: [..]Group;
            for f: cn.facts {
                k := as_str(f.key);
                g: *Group;
                for * groups if it.k == k { g = it; break; }
                if !g { g = array_add(*groups); g.k = k; }
                array_add(*g.vals, scrub_value(*c, f.value, k));
            }
            for groups array_add(*pairs, P(it.k, ifx it.vals.count == 1 then it.vals[0] else etf.vlist(it.vals)));
            emit(*out, t, pairs);
        }
    }
    quick_sort(out, (a: Line, b: Line) -> s64 {
        if a.t != b.t return ifx a.t < b.t then -1 else 1;
        return a.seq - b.seq;
    });
    sb: String_Builder;
    for out {
        // round t to 0.1 ms
        if it.v.map.count it.v.map[0].value = etf.vfloat(cast(float64) (cast(s64) (it.t * 10)) / 10);
        etf.to_json(it.v, *sb);
        append(*sb, "\n");
    }
    return builder_to_string(*sb);
}

emit :: (out: *[..]Line, t: float64, pairs: []etf.Pair) { array_add(out, .{t, out.count, etf.vmap(pairs)}); }

clone_value :: (v: etf.Value) -> etf.Value {
    r := v;
    if v.kind == {
      case .Big;    r.big.digits = array_copy(v.big.digits);
      case .String; #through;
      case .Atom; #through;
      case .Charlist; r.s = copy_string(v.s);
      case .List; #through;
      case .Tuple;
        r.list = NewArray(v.list.count, etf.Value);
        for v.list r.list[it_index] = clone_value(it);
      case .Map;
        r.map = NewArray(v.map.count, etf.Pair);
        for v.map r.map[it_index] = .{clone_value(it.key), clone_value(it.value)};
    }
    return r;
}
