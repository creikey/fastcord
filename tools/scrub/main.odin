// scrub: raw capture (.secrets/raw/*.jsonl, see tools/capture) -> committable
// fixture (traffic/<scenario>.jsonl, format in traffic/README.md).
//
//   scrub <raw.jsonl> <out.jsonl> [env]   convert (env = tests/scenarios/env, the allowlist)
//   scrub verify <raw.jsonl> <out.jsonl>  fail if any secret from raw survives in out
package scrub

import "core:crypto/sha2"
import "core:encoding/base64"
import "core:encoding/hex"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "fc:etf"

main :: proc() {
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	args := os.args
	if len(args) >= 4 && args[1] == "verify" {
		raw, e1 := os.read_entire_file(args[2], context.allocator)
		out, e2 := os.read_entire_file(args[3], context.allocator)
		if e1 != nil || e2 != nil {
			fmt.eprintln("cannot read inputs")
			os.exit(2)
		}
		problems := verify(string(raw), string(out))
		for p in problems do fmt.eprintln("LEAK:", p)
		if len(problems) > 0 do os.exit(1)
		fmt.println("verify ok:", args[3])
		return
	}
	if len(args) < 3 {
		fmt.eprintln("usage: scrub <raw.jsonl> <out.jsonl> [env] [-netlog-a:FILE] [-netlog-b:FILE] | scrub verify <raw.jsonl> <out.jsonl>")
		os.exit(2)
	}
	raw, err := os.read_entire_file(args[1], context.allocator)
	if err != nil {
		fmt.eprintln("cannot read", args[1])
		os.exit(2)
	}
	env := ""
	envp := "tests/scenarios/env"
	netlogs: [2]string
	for a in args[3:] {
		switch {
		case strings.has_prefix(a, "-netlog-a:"):
			netlogs[0] = a[len("-netlog-a:"):]
		case strings.has_prefix(a, "-netlog-b:"):
			netlogs[1] = a[len("-netlog-b:"):]
		case:
			envp = a
		}
	}
	if data, eerr := os.read_entire_file(envp, context.allocator); eerr == nil do env = string(data)
	out := convert(string(raw), env, netlogs)
	if werr := os.write_entire_file(args[2], transmute([]byte)out); werr != nil {
		fmt.eprintln("cannot write", args[2])
		os.exit(1)
	}
	problems := verify(string(raw), out)
	for p in problems do fmt.eprintln("LEAK:", p)
	if len(problems) > 0 {
		os.remove(args[2])
		fmt.eprintln("refusing to keep", args[2])
		os.exit(1)
	}
	fmt.printfln("%s -> %s (%d lines)", args[1], args[2], strings.count(out, "\n"))
}

b64_decode :: proc(s: string) -> ([]byte, bool) {
	t := strings.trim_space(s)
	if d, err := base64.decode(t); err == nil do return d, true
	// url-safe / unpadded variants
	u, _ := strings.replace_all(t, "-", "+")
	u, _ = strings.replace_all(u, "_", "/")
	for len(u) % 4 != 0 do u = strings.concatenate({u, "="})
	d, err := base64.decode(u)
	return d, err == nil
}

Req :: struct {
	t:            f64,
	resp_t:       f64,
	acct:         string,
	method, url:  string,
	type:         string,
	proto:        string,
	conn:         f64,
	reused:       bool,
	status:       int,
	headers:      etf.Value, // CDP headers object (request)
	wire_headers: etf.Value, // ExtraInfo (actual wire, incl. pseudo/cookie)
	resp_headers: etf.Value,
	resp_wire:    etf.Value,
	post:         string,
	has_post:     bool,
	body:         string,
	body_b64:     bool,
	has_body:     bool,
	has_resp:     bool,
	cached:       bool,
}

Ws :: struct {
	t:       f64,
	acct:    string,
	url:     string,
	headers: etf.Value,
	closed:  f64,
	id:      int,
}

Line :: struct {
	t:   f64,
	seq: int,
	v:   etf.Value,
}

@(private)
get :: proc(v: etf.Value, keys: ..string) -> etf.Value {
	cur := v
	for k in keys {
		m, ok := cur.(etf.Map)
		if !ok do return nil
		cur, _ = etf.map_get(m, k)
	}
	return cur
}

@(private)
gs :: proc(v: etf.Value, keys: ..string) -> string {
	s, _ := get(v, ..keys).(string)
	return s
}

@(private)
gn :: proc(v: etf.Value, keys: ..string) -> f64 {
	#partial switch n in get(v, ..keys) {
	case i64:
		return f64(n)
	case f64:
		return n
	}
	return 0
}

@(private)
obj :: proc(pairs: ..etf.Pair) -> etf.Value {
	m := make([]etf.Pair, len(pairs))
	copy(m, pairs)
	return etf.Map(m)
}

@(private)
P :: proc(k: string, v: etf.Value) -> etf.Pair {return {key = k, value = v}}

@(private)
load_allowlist :: proc(c: ^Ctx, env: string) {
	for line in strings.split_lines(env, context.temp_allocator) {
		eq := strings.index_byte(line, '=')
		if eq < 0 || strings.has_prefix(strings.trim_space(line), "#") do continue
		v := strings.trim_space(line[eq + 1:])
		if is_snowflake_digits(v) do c.allow[strings.clone(v)] = true
	}
}

// keep_request decides which requests belong in a fixture: real network
// traffic a native client could also produce (no web-app bundle assets, no
// cache hits, no browser-internal schemes).
@(private)
keep_request :: proc(r: ^Req) -> bool {
	if r.cached do return false
	if !strings.has_prefix(r.url, "https://") && !strings.has_prefix(r.url, "http://") do return false
	switch r.type {
	case "Script", "Stylesheet", "Font", "Manifest", "TextTrack", "Document", "Media", "SignedExchange", "CSPViolationReport":
		return false
	case "Image":
		return strings.contains(r.url, "cdn.discordapp.com/") || strings.contains(r.url, "media.discordapp.net/")
	}
	if strings.contains(r.url, "discord.com/assets/") do return false
	return true
}

@(private)
headers_list :: proc(c: ^Ctx, h: etf.Value) -> etf.Value {
	m, ok := h.(etf.Map)
	if !ok do return etf.List(nil)
	out := make([dynamic]etf.Value)
	for p in m {
		name, _ := p.key.(string)
		val, _ := p.value.(string)
		// CDP joins repeated headers with '\n'
		for part in strings.split(val, "\n", context.temp_allocator) {
			sv, special := header_rule(c, name, part)
			if !special do sv = scrub_text(c, part)
			pair := make([]etf.Value, 2)
			pair[0] = strings.clone(name)
			pair[1] = sv
			append(&out, etf.List(pair))
		}
	}
	return etf.List(out[:])
}

@(private)
wire_list :: proc(c: ^Ctx, hs: [][2]string) -> etf.Value {
	out := make([]etf.Value, len(hs))
	for h, i in hs {
		sv, special := header_rule(c, h[0], h[1])
		if !special do sv = scrub_text(c, h[1])
		pair := make([]etf.Value, 2)
		pair[0] = h[0]
		pair[1] = sv
		out[i] = etf.List(pair)
	}
	return etf.List(out)
}

@(private)
body_value :: proc(c: ^Ctx, body: string, is_b64: bool) -> etf.Value {
	data := transmute([]byte)body
	if is_b64 {
		d, ok := b64_decode(body)
		if ok do data = d
	}
	// Huge bodies (game detectables, shop catalogs) are static: hash only, keeps the repo small.
	if v, err := etf.from_json(string(data), context.temp_allocator); err == .None && len(data) > 0 && len(data) <= MAX_JSON_BODY {
		#partial switch _ in v {
		case etf.Map, etf.List:
			return scrub_value(c, v, "")
		}
	}
	if len(data) <= 4096 {
		// small text bodies are scrubbed as text first, then stored as base64
		text := string(data)
		if utf8_ok(text) do data = transmute([]byte)scrub_text(c, text)
		return obj(P("$b64", base64.encode(data)), P("len", i64(len(data))))
	}
	sum: [32]byte
	ctx: sha2.Context_256
	sha2.init_256(&ctx)
	sha2.update(&ctx, data)
	sha2.final(&ctx, sum[:])
	return obj(P("$sha256", string(hex.encode(sum[:]))), P("len", i64(len(data))))
}

MAX_JSON_BODY :: 256 * 1024

@(private)
utf8_ok :: proc(s: string) -> bool {
	for r in s do if r == 0xfffd do return false
	return true
}

// convert turns raw capture text into fixture text.
convert :: proc(raw: string, env: string, netlogs := [2]string{}) -> string {
	c: Ctx
	c.allow = make(map[string]bool)
	c.others = make(map[string]bool)
	c.ph = make(map[string]string)
	c.counts = make(map[string]int)
	load_allowlist(&c, env)
	lines := strings.split_lines(raw)

	// Pass 1: run start time and foreign users.
	for l in lines {
		if len(l) == 0 do continue
		v, err := etf.from_json(l, context.temp_allocator)
		if err != .None do continue
		if wt := gn(v, "m", "params", "wallTime"); wt > 0 && gs(v, "m", "method") == "Network.requestWillBeSent" {
			start := i64(wt * 1000 - gn(v, "rt"))
			if c.run_start_ms == 0 || start < c.run_start_ms do c.run_start_ms = start
		}
		collect_foreign(&c, get(v, "etf"))
		if b := gs(v, "m", "result", "body"); len(b) > 0 && len(b) < 8 << 20 {
			if bv, berr := etf.from_json(b, context.temp_allocator); berr == .None do collect_foreign(&c, bv)
		}
		free_all(context.temp_allocator)
	}

	last_rt := 0.0
	for l in lines {
		if i := strings.index(l, `"rt":`); i >= 0 {
			j := i + 5
			k := j
			for k < len(l) && (l[k] == '.' || (l[k] >= '0' && l[k] <= '9')) do k += 1
			if v, ok := strconv.parse_f64(l[j:k]); ok do last_rt = max(last_rt, v)
		}
	}
	nls: [2]Netlog
	for path, i in netlogs {
		if path == "" || c.run_start_ms == 0 do continue
		start := f64(c.run_start_ms)
		if nl, ok := netlog_load(path, start - 5000, start + last_rt + 5000); ok {
			nls[i] = nl
		} else {
			fmt.eprintln("cannot read netlog", path)
		}
	}
	conn_ids := make(map[int]i64)
	conn_id :: proc(m: ^map[int]i64, id: int) -> i64 {
		if v, ok := m[id]; ok do return v
		n := i64(len(m) + 1)
		m[id] = n
		return n
	}
	reqs := make(map[string]^Req)
	order := make([dynamic]^Req)
	sockets := make(map[string]^Ws)
	ws_order := make([dynamic]^Ws)
	out := make([dynamic]Line)
	seq := 0
	emit :: proc(out: ^[dynamic]Line, seq: ^int, t: f64, v: etf.Value) {
		append(out, Line{t = t, seq = seq^, v = v})
		seq^ += 1
	}

	for l in lines {
		if len(l) == 0 do continue
		v, err := etf.from_json(l, context.temp_allocator)
		if err != .None do continue
		rt := gn(v, "rt")
		acct := gs(v, "acct")
		if name := gs(v, "mark"); name != "" {
			if acct == "a" do emit(&out, &seq, rt, obj(P("t", rt), P("k", string("mark")), P("name", strings.clone(name))))
			continue
		}
		if g := get(v, "gw"); g != nil {
			ws_key := fmt.aprintf("%s/%s", acct, gs(g, "ws"))
			w := sockets[ws_key]
			e := get(v, "etf")
			ev := gs(e, "t")
			pairs := make([dynamic]etf.Pair)
			append(&pairs, P("t", rt), P("k", string("ws_send") if gs(g, "dir") == "send" else string("ws_recv")))
			if acct != "a" do append(&pairs, P("acct", strings.clone(acct)))
			append(&pairs, P("id", i64(w.id if w != nil else 0)), P("op", get(e, "op")))
			if ev != "" do append(&pairs, P("ev", strings.clone(ev)))
			if s := get(e, "s"); s != nil do append(&pairs, P("seq", s))
			append(&pairs, P("d", scrub_value(&c, get(e, "d"), "")))
			emit(&out, &seq, rt, etf.Map(pairs[:]))
			continue
		}
		if rid := gs(v, "body_for"); rid != "" {
			k := fmt.tprintf("%s/%s/%s", acct, gs(v, "s"), rid)
			if r, ok := reqs[k]; ok {
				r.body = strings.clone(gs(v, "m", "result", "body"))
				r.body_b64, _ = get(v, "m", "result", "base64Encoded").(bool)
				r.has_body = true
			}
			continue
		}
		m := get(v, "m")
		method := gs(m, "method")
		p := get(m, "params")
		session := gs(m, "sessionId")
		rid := gs(p, "requestId")
		key := fmt.aprintf("%s/%s/%s", acct, session, rid)
		switch method {
		case "Network.requestWillBeSent":
			r := new(Req)
			r.t = rt
			r.acct = strings.clone(acct)
			r.method = strings.clone(gs(p, "request", "method"))
			r.url = strings.clone(gs(p, "request", "url"))
			r.type = strings.clone(gs(p, "type"))
			r.headers = clone_value(get(p, "request", "headers"))
			r.post = strings.clone(gs(p, "request", "postData"))
			r.has_post, _ = get(p, "request", "hasPostData").(bool)
			if old, exists := reqs[key]; exists do old.cached = true // redirect: keep the final hop only
			reqs[key] = r
			append(&order, r)
		case "Network.requestWillBeSentExtraInfo":
			if r, ok := reqs[key]; ok do r.wire_headers = clone_value(get(p, "headers"))
		case "Network.requestServedFromCache":
			if r, ok := reqs[key]; ok do r.cached = true
		case "Network.responseReceived":
			if r, ok := reqs[key]; ok {
				r.has_resp = true
				r.resp_t = rt
				r.status = int(gn(p, "response", "status"))
				r.proto = strings.clone(gs(p, "response", "protocol"))
				r.conn = gn(p, "response", "connectionId")
				r.reused, _ = get(p, "response", "connectionReused").(bool)
				r.resp_headers = clone_value(get(p, "response", "headers"))
				disk, _ := get(p, "response", "fromDiskCache").(bool)
				pre, _ := get(p, "response", "fromPrefetchCache").(bool)
				sw, _ := get(p, "response", "fromServiceWorker").(bool)
				if disk || pre || sw do r.cached = true
			}
		case "Network.responseReceivedExtraInfo":
			if r, ok := reqs[key]; ok do r.resp_wire = clone_value(get(p, "headers"))
		case "Network.webSocketCreated":
			w := new(Ws)
			w.t = rt
			w.acct = strings.clone(acct)
			w.url = strings.clone(gs(p, "url"))
			w.id = len(ws_order) + 1
			sockets[fmt.aprintf("%s/%s", acct, rid)] = w
			append(&ws_order, w)
		case "Network.webSocketWillSendHandshakeRequest":
			if w, ok := sockets[fmt.tprintf("%s/%s", acct, rid)]; ok do w.headers = clone_value(get(p, "request", "headers"))
		case "Network.webSocketHandshakeResponseReceived":
			if w, ok := sockets[fmt.tprintf("%s/%s", acct, rid)]; ok {
				if rh := get(p, "response", "requestHeaders"); rh != nil do w.headers = clone_value(rh)
			}
		case "Network.webSocketClosed":
			if w, ok := sockets[fmt.tprintf("%s/%s", acct, rid)]; ok do w.closed = rt
		}
		free_all(context.temp_allocator)
	}

	next_id := 1
	for r in order {
		if !keep_request(r) do continue
		id := i64(next_id)
		next_id += 1
		pairs := make([dynamic]etf.Pair)
		append(&pairs, P("t", r.t), P("k", string("req")))
		if r.acct != "a" do append(&pairs, P("acct", r.acct))
		append(&pairs, P("id", id), P("proto", r.proto), P("method", r.method), P("url", scrub_text(&c, r.url)))
		append(&pairs, P("conn", i64(r.conn)), P("reused", r.reused))
		// headers: Chrome's request header list in its own order (always present).
		// wire: what the network stack actually sent (pseudo-headers, cookie,
		// accept-encoding...) when CDP reports it; CDP sorts these by name, so
		// the true wire order is only in a netlog.
		append(&pairs, P("headers", headers_list(&c, r.headers)))
		ai := 1 if r.acct == "b" else 0
		nr: ^Net_Req
		if nls[ai].loaded do nr = netlog_match(&nls[ai], r.method, r.url, f64(c.run_start_ms) + r.t)
		if nr != nil {
			// true wire order from the netlog (Chrome strips cookie/auth values there)
			append(&pairs, P("wire", wire_list(&c, nr.headers[:])), P("wire_src", string("netlog")))
			if nr.proto == "h2" || nr.proto == "h3" do append(&pairs, P("session", conn_id(&conn_ids, nr.session)))
			if nr.extra != nil do append(&pairs, P("h2", nr.extra))
			if r.proto == "" {
				for &pp in pairs do if (pp.key.(string) or_else "") == "proto" do pp.value = nr.proto
			}
		} else if r.wire_headers != nil {
			append(&pairs, P("wire", headers_list(&c, r.wire_headers)), P("wire_src", string("cdp_sorted")))
		}
		if len(r.post) > 0 {
			append(&pairs, P("body", body_value(&c, r.post, false)))
		} else if r.has_post {
			append(&pairs, P("body", obj(P("$omitted", true))))
		}
		emit(&out, &seq, r.t, etf.Map(pairs[:]))
		if r.has_resp {
			rp := make([dynamic]etf.Pair)
			append(&rp, P("t", r.resp_t), P("k", string("resp")))
			if r.acct != "a" do append(&rp, P("acct", r.acct))
			append(&rp, P("id", id), P("status", i64(r.status)))
			append(&rp, P("headers", headers_list(&c, r.resp_headers)))
			if r.has_body do append(&rp, P("body", body_value(&c, r.body, r.body_b64)))
			emit(&out, &seq, r.resp_t, etf.Map(rp[:]))
		}
	}
	for w in ws_order {
		pairs := make([dynamic]etf.Pair)
		append(&pairs, P("t", w.t), P("k", string("ws_open")))
		if w.acct != "a" do append(&pairs, P("acct", w.acct))
		append(&pairs, P("id", i64(w.id)), P("url", scrub_text(&c, w.url)), P("headers", headers_list(&c, w.headers)))
		ai := 1 if w.acct == "b" else 0
		if nls[ai].loaded {
			hu, _ := strings.replace(w.url, "wss://", "https://", 1)
			if nr := netlog_match(&nls[ai], "GET", hu, f64(c.run_start_ms) + w.t); nr != nil {
				append(&pairs, P("wire", wire_list(&c, nr.headers[:])), P("wire_src", string("netlog")))
			}
		}
		emit(&out, &seq, w.t, etf.Map(pairs[:]))
		if w.closed > 0 {
			cp := make([dynamic]etf.Pair)
			append(&cp, P("t", w.closed), P("k", string("ws_close")))
			if w.acct != "a" do append(&cp, P("acct", w.acct))
			append(&cp, P("id", i64(w.id)), P("code", nil))
			emit(&out, &seq, w.closed, etf.Map(cp[:]))
		}
	}
	for nl, i in nls {
		if !nl.loaded do continue
		for cn in nl.order {
			t := cn.wall - f64(c.run_start_ms)
			pairs := make([dynamic]etf.Pair)
			append(&pairs, P("t", t), P("k", string("conn")))
			if i == 1 do append(&pairs, P("acct", string("b")))
			if cn.kind != "alt_svc" do append(&pairs, P("session", conn_id(&conn_ids, cn.id)))
			append(&pairs, P("kind", cn.kind), P("host", cn.host))
			// repeated events (priority updates, version notes...) become one list
			grouped := make(map[string][dynamic]etf.Value, context.temp_allocator)
			keys := make([dynamic]string, context.temp_allocator)
			for f in cn.facts {
				k := f.key.(string) or_else ""
				if _, seen := grouped[k]; !seen {
					grouped[k] = make([dynamic]etf.Value)
					append(&keys, k)
				}
				append(&grouped[k], scrub_value(&c, f.value, k))
			}
			for k in keys {
				vals := grouped[k]
				append(&pairs, etf.Pair{key = strings.clone(k), value = vals[0] if len(vals) == 1 else etf.List(vals[:])})
			}
			emit(&out, &seq, t, etf.Map(pairs[:]))
		}
	}
	slice.sort_by(out[:], proc(a, b: Line) -> bool {return a.t < b.t || (a.t == b.t && a.seq < b.seq)})
	sb := strings.builder_make()
	for ln in out {
		// round t to 0.1 ms
		if m, ok := ln.v.(etf.Map); ok && len(m) > 0 do m[0].value = f64(i64(ln.t * 10)) / 10
		etf.to_json(ln.v, &sb)
		strings.write_byte(&sb, '\n')
	}
	return strings.to_string(sb)
}

@(private)
clone_value :: proc(v: etf.Value) -> etf.Value {
	switch x in v {
	case nil, bool, i64, f64:
		return v
	case etf.Big:
		return etf.Big{negative = x.negative, digits = slice.clone(x.digits)}
	case string:
		return strings.clone(x)
	case etf.Atom:
		return etf.Atom(strings.clone(string(x)))
	case etf.Charlist:
		return etf.Charlist(strings.clone(string(x)))
	case etf.List:
		out := make([]etf.Value, len(x))
		for e, i in x do out[i] = clone_value(e)
		return etf.List(out)
	case etf.Tuple:
		out := make([]etf.Value, len(x))
		for e, i in x do out[i] = clone_value(e)
		return etf.Tuple(out)
	case etf.Map:
		out := make([]etf.Pair, len(x))
		for p, i in x do out[i] = {clone_value(p.key), clone_value(p.value)}
		return etf.Map(out)
	}
	return nil
}
