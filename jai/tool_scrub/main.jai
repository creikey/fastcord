main :: () {
	arena: virtual.Arena;
	virtual.arena_init_growing(*arena);
	context.allocator = virtual.arena_allocator(*arena);
	args := get_command_line_arguments();
	if len(args) >= 4 && args[1] == "verify" {
		raw, e1 := os.read_entire_file(args[2], context.allocator);
		out, e2 := os.read_entire_file(args[3], context.allocator);
		if e1 != null || e2 != null {
			fmt.eprintln("cannot read inputs");
			os.exit(2);
		}
		problems := verify(as_string(raw), as_string(out));
		for p: problems { fmt.eprintln("LEAK:", p); }
		if len(problems) > 0 { os.exit(1); }
		fmt.println("verify ok:", args[3]);
		return;
	}
	if len(args) < 3 {
		fmt.eprintln("usage: scrub <raw.jsonl> <out.jsonl> [env] [-netlog-a:FILE] [-netlog-b:FILE] | scrub verify <raw.jsonl> <out.jsonl>");
		os.exit(2);
	}
	raw, err := os.read_entire_file(args[1], context.allocator);
	if err != null {
		fmt.eprintln("cannot read", args[1]);
		os.exit(2);
	}
	env := "";
	envp := "tests/scenarios/env";
	netlogs: [2]string;
	for a: sub_from(args, 3) {
		if strings.has_prefix(a, "-netlog-a:") {
			netlogs[0] = sub_from(a, len("-netlog-a:"));
		} else if strings.has_prefix(a, "-netlog-b:") {
			netlogs[1] = sub_from(a, len("-netlog-b:"));
		} else {
			envp = a;
		}
	}
	{ data, eerr := os.read_entire_file(envp, context.allocator);
	if eerr == null { env = as_string(data); } }
	out := convert(as_string(raw), env, netlogs);
	{ werr := os.write_entire_file(args[2], transmute([]u8, out));
	if werr != null {
		fmt.eprintln("cannot write", args[2]);
		os.exit(1);
	} }
	problems := verify(as_string(raw), out);
	for p: problems { fmt.eprintln("LEAK:", p); }
	if len(problems) > 0 {
		os.remove_(args[2]);
		fmt.eprintln("refusing to keep", args[2]);
		os.exit(1);
	}
	fmt.printfln("%s -> %s (%d lines)", args[1], args[2], strings.count(out, "\n"));
}

b64_decode :: (s: string) -> []u8, bool {
	t := strings.trim_space(s);
	{ d, err := base64.decode(t);
	if err == null { return d, true; } }
	// url-safe / unpadded variants
	u, _ := strings.replace_all(t, "-", "+");
	u, _ = strings.replace_all(u, "_", "/");
	while len(u) % 4 != 0 { u = strings.concatenate(.{u, "="}); }
	d, err := base64.decode(u);
	return d, err == null;
}

Req :: struct {
	t: float64;
	resp_t: float64;
	acct: string;
	method, url: string;
	type: string;
	proto: string;
	conn: float64;
	reused: bool;
	status: int;
	headers: etf.Value; // CDP headers object (request)
	wire_headers: etf.Value; // ExtraInfo (actual wire, incl. pseudo/cookie)
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
	acct: string;
	url: string;
	headers: etf.Value;
	closed: float64;
	id: int;
}

Line :: struct {
	t: float64;
	seq: int;
	v: etf.Value;
}
#scope_module

get :: (v: etf.Value, keys: ..string) -> etf.Value {
	cur := v;
	for k: keys {
		m, ok := cur.map, cur.kind == .Map;
		if !ok { return .{}; }
		cur, _ = etf.map_get(m, k);
	}
	return cur;
}

gs :: (v: etf.Value, keys: ..string) -> string {
	s, _ := get(v, ..keys).s, get(v, ..keys).kind == .String;
	return s;
}

gn :: (v: etf.Value, keys: ..string) -> float64 {
	{ __v3 := get(v, ..keys);
	if __v3.kind == {
	case .Int; n := __v3.i;
		return cast(float64)(n);
	case .Float; n := __v3.f;
		return n;
	} }
	return 0;
}

obj :: (pairs: ..etf.Pair) -> etf.Value {
	m := make_slice(etf.Pair, len(pairs));
	copy(m, pairs);
	return etf.vmap(m);
}

P :: (k: string, v: etf.Value) -> etf.Pair {return .{key = k, value = v};}

load_allowlist :: (c: *Ctx, env: string) {
	for line: strings.split_lines(env, temp) {
		eq := strings.index_byte(line, #char "=");
		if eq < 0 || strings.has_prefix(strings.trim_space(line), "#") { continue; }
		v := strings.trim_space(sub_from(line, eq + 1));
		if is_snowflake_digits(v) { at(*c.allow, clone(v)).* = true; }
	}
}

// keep_request decides which requests belong in a fixture: real network
// traffic a native client could also produce (no web-app bundle assets, no
// cache hits, no browser-internal schemes).
keep_request :: (r: *Req) -> bool {
	if r.cached { return false; }
	if !strings.has_prefix(r.url, "https://") && !strings.has_prefix(r.url, "http://") { return false; }
	if r.type == {
	case "Script"; #through; case "Stylesheet"; #through; case "Font"; #through; case "Manifest"; #through; case "TextTrack"; #through; case "Document"; #through; case "Media"; #through; case "SignedExchange"; #through; case "CSPViolationReport";
		return false;
	case "Image";
		return strings.contains(r.url, "cdn.discordapp.com/") || strings.contains(r.url, "media.discordapp.net/");
	}
	if strings.contains(r.url, "discord.com/assets/") { return false; }
	return true;
}

headers_list :: (c: *Ctx, h: etf.Value) -> etf.Value {
	m, ok := h.map, h.kind == .Map;
	if !ok { return etf.vlist(null); }
	out := make_dynamic(etf.Value, 0, 0);
	for p: m {
		name, _ := p.key.s, p.key.kind == .String;
		val, _ := p.value.s, p.value.kind == .String;
		// CDP joins repeated headers with '\n'
		for part: strings.split(val, "\n", temp) {
			sv, special := header_rule(c, name, part);
			if !special { sv = scrub_text(c, part); }
			pair := make_slice(etf.Value, 2);
			pair[0] = clone(name);
			pair[1] = sv;
			append(*out, cast(etf.List)(pair));
		}
	}
	return etf.vlist(view(out));
}

wire_list :: (c: *Ctx, hs: [][2]string) -> etf.Value {
	out := make_slice(etf.Value, len(hs));
	for h, i: hs {
		sv, special := header_rule(c, h[0], h[1]);
		if !special { sv = scrub_text(c, h[1]); }
		pair := make_slice(etf.Value, 2);
		pair[0] = h[0];
		pair[1] = sv;
		at(*out, i).* = cast(etf.List)(pair);
	}
	return etf.vlist(out);
}

body_value :: (c: *Ctx, body: string, is_b64: bool) -> etf.Value {
	data := transmute([]u8, body);
	if is_b64 {
		d, ok := b64_decode(body);
		if ok { data = d; }
	}
	// Huge bodies (game detectables, shop catalogs) are static: hash only, keeps the repo small.
	{ v, err := etf.from_json(as_string(data), temp);
	if err == .None && len(data) > 0 && len(data) <= MAX_JSON_BODY {
		if v.kind == {
		case .Map; #through; case .List;
			return scrub_value(c, v, "");
		}
	} }
	if len(data) <= 4096 {
		// small text bodies are scrubbed as text first, then stored as base64
		text := as_string(data);
		if utf8_ok(text) { data = transmute([]u8, scrub_text(c, text)); }
		return obj(P("$b64", base64.encode(data)), P("len", cast(s64)(len(data))));
	}
	sum: [32]u8;
	ctx: sha2.Context_256;
	sha2.init_256(*ctx);
	sha2.update(*ctx, data);
	sha2.final(*ctx, view(sum));
	return obj(P("$sha256", as_string(hex.encode(view(sum)))), P("len", cast(s64)(len(data))));
}
#scope_export

MAX_JSON_BODY :: 256 * 1024;
#scope_module

utf8_ok :: (s: string) -> bool {
	for r: s { if r == 0xfffd { return false; } }
	return true;
}
#scope_export

// convert turns raw capture text into fixture text.
convert :: (raw: string, env: string, netlogs := zero([2]string)) -> string {
	c: Ctx;
	c.allow = Map(string, bool).{};
	c.others = Map(string, bool).{};
	c.ph = Map(string, string).{};
	c.counts = Map(string, int).{};
	load_allowlist(*c, env);
	lines := strings.split_lines(raw);

	// Pass 1: run start time and foreign users.
	for l: lines {
		if len(l) == 0 { continue; }
		v, err := etf.from_json(l, temp);
		if err != .None { continue; }
		{ wt := gn(v, "m", "params", "wallTime");
		if wt > 0 && gs(v, "m", "method") == "Network.requestWillBeSent" {
			start := cast(s64)(wt * 1000 - gn(v, "rt"));
			if c.run_start_ms == 0 || start < c.run_start_ms { c.run_start_ms = start; }
		} }
		collect_foreign(*c, get(v, "etf"));
		{ b := gs(v, "m", "result", "body");
		if len(b) > 0 && len(b) < 8 << 20 {
			{ bv, berr := etf.from_json(b, temp);
			if berr == .None { collect_foreign(*c, bv); } }
		} }
		free_all(temp);
	}

	last_rt := 0.0;
	for l: lines {
		{ i := strings.index(l, "\"rt\":");
		if i >= 0 {
			j := i + 5;
			k := j;
			while k < len(l) && (l[k] == #char "." || (l[k] >= #char "0" && l[k] <= #char "9")) { k += 1; }
			{ v, ok := strconv.parse_f64(sub(l, j, k));
			if ok { last_rt = max(last_rt, v); } }
		} }
	}
	nls: [2]Netlog;
	for path, i: netlogs {
		if path == "" || c.run_start_ms == 0 { continue; }
		start := cast(float64)(c.run_start_ms);
		{ nl, ok := netlog_load(path, start - 5000, start + last_rt + 5000);
		if ok {
			nls[i] = nl;
		} else {
			fmt.eprintln("cannot read netlog", path);
		} }
	}
	conn_ids := Map(int, s64).{};
	conn_id :: (m: *Map(int, s64), id: int) -> s64 {
		{ v, ok := map_find(m, id);
		if ok { return v; } }
		n := cast(s64)(len(m) + 1);
		at(*m, id).* = n;
		return n;
	}
	reqs := Map(string, *Req).{};
	order := make_dynamic(*Req, 0, 0);
	sockets := Map(string, *Ws).{};
	ws_order := make_dynamic(*Ws, 0, 0);
	out := make_dynamic(Line, 0, 0);
	seq := 0;
	emit :: (out: *[..]Line, seq: *int, t: float64, v: etf.Value) {
		append(out, Line.{t = t, seq = seq.*, v = v});
		seq.* += 1;
	}

	for l: lines {
		if len(l) == 0 { continue; }
		v, err := etf.from_json(l, temp);
		if err != .None { continue; }
		rt := gn(v, "rt");
		acct := gs(v, "acct");
		{ name := gs(v, "mark");
		if name != "" {
			if acct == "a" { emit(*out, *seq, rt, obj(P("t", rt), P("k", as_string("mark")), P("name", clone(name)))); }
			continue;
		} }
		{ g := get(v, "gw");
		if g != null {
			ws_key := fmt.aprintf("%s/%s", acct, gs(g, "ws"));
			w := get(sockets, ws_key);
			e := get(v, "etf");
			ev := gs(e, "t");
			pairs := make_dynamic(etf.Pair, 0, 0);
			append(*pairs, P("t", rt), P("k", ifx gs(g, "dir") == "send" then as_string("ws_send") else as_string("ws_recv")));
			if acct != "a" { append(*pairs, P("acct", clone(acct))); }
			append(*pairs, P("id", cast(s64)(ifx w != null then w.id else 0)), P("op", get(e, "op")));
			if ev != "" { append(*pairs, P("ev", clone(ev))); }
			{ s := get(e, "s");
			if s != null { append(*pairs, P("seq", s)); } }
			append(*pairs, P("d", scrub_value(*c, get(e, "d"), "")));
			emit(*out, *seq, rt, cast(etf.Map)(view(pairs)));
			continue;
		} }
		{ rid := gs(v, "body_for");
		if rid != "" {
			k := fmt.tprintf("%s/%s/%s", acct, gs(v, "s"), rid);
			{ r, ok := map_find(reqs, k);
			if ok {
				r.body = clone(gs(v, "m", "result", "body"));
				r.body_b64, _ = get(v, "m", "result", "base64Encoded").b, get(v, "m", "result", "base64Encoded").kind == .Bool;
				r.has_body = true;
			} }
			continue;
		} }
		m := get(v, "m");
		method := gs(m, "method");
		p := get(m, "params");
		session := gs(m, "sessionId");
		rid := gs(p, "requestId");
		key := fmt.aprintf("%s/%s/%s", acct, session, rid);
		if method == {
		case "Network.requestWillBeSent";
			r := new(Req);
			r.t = rt;
			r.acct = clone(acct);
			r.method = clone(gs(p, "request", "method"));
			r.url = clone(gs(p, "request", "url"));
			r.type = clone(gs(p, "type"));
			r.headers = clone_value(get(p, "request", "headers"));
			r.post = clone(gs(p, "request", "postData"));
			r.has_post, _ = get(p, "request", "hasPostData").b, get(p, "request", "hasPostData").kind == .Bool;
			{ old, exists := map_find(reqs, key);
			if exists { old.cached = true; } } // redirect: keep the final hop only
			at(*reqs, key).* = r;
			append(*order, r);
		case "Network.requestWillBeSentExtraInfo";
			{ r, ok := map_find(reqs, key);
			if ok { r.wire_headers = clone_value(get(p, "headers")); } }
		case "Network.requestServedFromCache";
			{ r, ok := map_find(reqs, key);
			if ok { r.cached = true; } }
		case "Network.responseReceived";
			{ r, ok := map_find(reqs, key);
			if ok {
				r.has_resp = true;
				r.resp_t = rt;
				r.status = cast(int)(gn(p, "response", "status"));
				r.proto = clone(gs(p, "response", "protocol"));
				r.conn = gn(p, "response", "connectionId");
				r.reused, _ = get(p, "response", "connectionReused").b, get(p, "response", "connectionReused").kind == .Bool;
				r.resp_headers = clone_value(get(p, "response", "headers"));
				disk, _ := get(p, "response", "fromDiskCache").b, get(p, "response", "fromDiskCache").kind == .Bool;
				pre, _ := get(p, "response", "fromPrefetchCache").b, get(p, "response", "fromPrefetchCache").kind == .Bool;
				sw, _ := get(p, "response", "fromServiceWorker").b, get(p, "response", "fromServiceWorker").kind == .Bool;
				if disk || pre || sw { r.cached = true; }
			} }
		case "Network.responseReceivedExtraInfo";
			{ r, ok := map_find(reqs, key);
			if ok { r.resp_wire = clone_value(get(p, "headers")); } }
		case "Network.webSocketCreated";
			w := new(Ws);
			w.t = rt;
			w.acct = clone(acct);
			w.url = clone(gs(p, "url"));
			w.id = len(ws_order) + 1;
			at(*sockets, fmt.aprintf("%s/%s", acct, rid)).* = w;
			append(*ws_order, w);
		case "Network.webSocketWillSendHandshakeRequest";
			{ w, ok := map_find(sockets, fmt.tprintf("%s/%s", acct, rid));
			if ok { w.headers = clone_value(get(p, "request", "headers")); } }
		case "Network.webSocketHandshakeResponseReceived";
			{ w, ok := map_find(sockets, fmt.tprintf("%s/%s", acct, rid));
			if ok {
				{ rh := get(p, "response", "requestHeaders");
				if rh != null { w.headers = clone_value(rh); } }
			} }
		case "Network.webSocketClosed";
			{ w, ok := map_find(sockets, fmt.tprintf("%s/%s", acct, rid));
			if ok { w.closed = rt; } }
		}
		free_all(temp);
	}

	next_id := 1;
	for r: order {
		if !keep_request(r) { continue; }
		id := cast(s64)(next_id);
		next_id += 1;
		pairs := make_dynamic(etf.Pair, 0, 0);
		append(*pairs, P("t", r.t), P("k", as_string("req")));
		if r.acct != "a" { append(*pairs, P("acct", r.acct)); }
		append(*pairs, P("id", id), P("proto", r.proto), P("method", r.method), P("url", scrub_text(*c, r.url)));
		append(*pairs, P("conn", cast(s64)(r.conn)), P("reused", r.reused));
		// headers: Chrome's request header list in its own order (always present).
		// wire: what the network stack actually sent (pseudo-headers, cookie,
		// accept-encoding...) when CDP reports it; CDP sorts these by name, so
		// the true wire order is only in a netlog.
		append(*pairs, P("headers", headers_list(*c, r.headers)));
		ai := ifx r.acct == "b" then 1 else 0;
		nr: *Net_Req;
		if nls[ai].loaded { nr = netlog_match(*nls[ai], r.method, r.url, cast(float64)(c.run_start_ms) + r.t); }
		if nr != null {
			// true wire order from the netlog (Chrome strips cookie/auth values there)
			append(*pairs, P("wire", wire_list(*c, view(nr.headers))), P("wire_src", as_string("netlog")));
			if nr.proto == "h2" || nr.proto == "h3" { append(*pairs, P("session", conn_id(*conn_ids, nr.session))); }
			if nr.extra != null { append(*pairs, P("h2", nr.extra)); }
			if r.proto == "" {
				for * pp: pairs { if (ifx pp.key.kind == .String then pp.key.s else "") == "proto" { pp.value = nr.proto; } }
			}
		} else if r.wire_headers != null {
			append(*pairs, P("wire", headers_list(*c, r.wire_headers)), P("wire_src", as_string("cdp_sorted")));
		}
		if len(r.post) > 0 {
			append(*pairs, P("body", body_value(*c, r.post, false)));
		} else if r.has_post {
			append(*pairs, P("body", obj(P("$omitted", true))));
		}
		emit(*out, *seq, r.t, cast(etf.Map)(view(pairs)));
		if r.has_resp {
			rp := make_dynamic(etf.Pair, 0, 0);
			append(*rp, P("t", r.resp_t), P("k", as_string("resp")));
			if r.acct != "a" { append(*rp, P("acct", r.acct)); }
			append(*rp, P("id", id), P("status", cast(s64)(r.status)));
			append(*rp, P("headers", headers_list(*c, r.resp_headers)));
			if r.has_body { append(*rp, P("body", body_value(*c, r.body, r.body_b64))); }
			emit(*out, *seq, r.resp_t, cast(etf.Map)(view(rp)));
		}
	}
	for w: ws_order {
		pairs := make_dynamic(etf.Pair, 0, 0);
		append(*pairs, P("t", w.t), P("k", as_string("ws_open")));
		if w.acct != "a" { append(*pairs, P("acct", w.acct)); }
		append(*pairs, P("id", cast(s64)(w.id)), P("url", scrub_text(*c, w.url)), P("headers", headers_list(*c, w.headers)));
		ai := ifx w.acct == "b" then 1 else 0;
		if nls[ai].loaded {
			hu, _ := strings.replace(w.url, "wss://", "https://", 1);
			{ nr := netlog_match(*nls[ai], "GET", hu, cast(float64)(c.run_start_ms) + w.t);
			if nr != null {
				append(*pairs, P("wire", wire_list(*c, view(nr.headers))), P("wire_src", as_string("netlog")));
			} }
		}
		emit(*out, *seq, w.t, cast(etf.Map)(view(pairs)));
		if w.closed > 0 {
			cp := make_dynamic(etf.Pair, 0, 0);
			append(*cp, P("t", w.closed), P("k", as_string("ws_close")));
			if w.acct != "a" { append(*cp, P("acct", w.acct)); }
			append(*cp, P("id", cast(s64)(w.id)), P("code", null));
			emit(*out, *seq, w.closed, cast(etf.Map)(view(cp)));
		}
	}
	for nl, i: nls {
		if !nl.loaded { continue; }
		for cn: nl.order {
			t := cn.wall - cast(float64)(c.run_start_ms);
			pairs := make_dynamic(etf.Pair, 0, 0);
			append(*pairs, P("t", t), P("k", as_string("conn")));
			if i == 1 { append(*pairs, P("acct", as_string("b"))); }
			if cn.kind != "alt_svc" { append(*pairs, P("session", conn_id(*conn_ids, cn.id))); }
			append(*pairs, P("kind", cn.kind), P("host", cn.host));
			// repeated events (priority updates, version notes...) become one list
			grouped := Map(string, [..]etf.Value).{};
			keys := make_dynamic(string, 0, 0, temp);
			for f: cn.facts {
				k := ifx f.key.kind == .String then f.key.s else "";
				{ _, seen := map_find(grouped, k);
				if !seen {
					at(*grouped, k).* = make_dynamic(etf.Value, 0, 0);
					append(*keys, k);
				} }
				append(at(*grouped, k), scrub_value(*c, f.value, k));
			}
			for k: keys {
				vals := get(grouped, k);
				append(*pairs, etf.Pair.{key = clone(k), value = ifx len(vals) == 1 then get(vals, 0) else cast(etf.List)(view(vals))});
			}
			emit(*out, *seq, t, cast(etf.Map)(view(pairs)));
		}
	}
	slice.sort_by(view(out), (a: Line, b: Line) -> bool {return a.t < b.t || (a.t == b.t && a.seq < b.seq);});
	sb := strings.builder_make();
	for ln: out {
		// round t to 0.1 ms
		{ m, ok := ln.v.map, ln.v.kind == .Map;
		if ok && len(m) > 0 { at(*m, 0).*.value = cast(float64)(cast(s64)(ln.t * 10)) / 10; } }
		etf.to_json(ln.v, *sb);
		strings.write_byte(*sb, 10);
	}
	return strings.to_string(sb);
}
#scope_module

clone_value :: (v: etf.Value) -> etf.Value {
	if v.kind == {
	case .Nil; #through; case .Bool; #through; case .Int; #through; case .Float; x := v;
		return v;
	case .Big; x := v.big;
		return etf.vbig(etf.Big.{negative = x.negative, digits = clone(x.digits)});
	case .String; x := v.s;
		return clone(x);
	case .Atom; x := v.s;
		return etf.vatom(clone(as_string(x)));
	case .Charlist; x := v.s;
		return etf.vcharlist(clone(as_string(x)));
	case .List; x := v.list;
		out := make_slice(etf.Value, len(x));
		for e, i: x { at(*out, i).* = clone_value(e); }
		return etf.vlist(out);
	case .Tuple; x := v.list;
		out := make_slice(etf.Value, len(x));
		for e, i: x { at(*out, i).* = clone_value(e); }
		return etf.vtuple(out);
	case .Map; x := v.map;
		out := make_slice(etf.Pair, len(x));
		for p, i: x { at(*out, i).* = .{clone_value(p.key), clone_value(p.value)}; }
		return etf.vmap(out);
	}
	return .{};
}
#scope_export

