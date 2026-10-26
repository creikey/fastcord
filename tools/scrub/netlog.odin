package scrub

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "fc:etf"

// Chrome netlog (--log-net-log, default capture mode) -> true wire header
// order for h2/h3/http1.1 requests and connection-level facts.
// The file is one event per line after a constants line; it may be truncated
// (the browser is still running), so every line is parsed independently.

Net_Req :: struct {
	wall:    f64, // unix ms
	proto:   string,
	method:  string,
	url:     string, // scheme://authority/path for matching
	headers: [dynamic][2]string,
	extra:   etf.Value, // h2 priority fields
	session: int,
	used:    bool,
}

Net_Conn :: struct {
	id:    int,
	wall:  f64,
	kind:  string, // "h3" | "h2" | "alt_svc"
	host:  string,
	facts: [dynamic]etf.Pair,
}

Netlog :: struct {
	reqs:   [dynamic]Net_Req,
	conns:  map[int]^Net_Conn,
	order:  [dynamic]^Net_Conn,
	tls:    map[int]etf.Value, // socket id -> SSL_CONNECT end params
	jobs:   map[int]etf.Value, // stream job id -> begin params
	alt:    map[string]^Net_Conn, // host -> alt-svc / race summary
	loaded: bool,
}

@(private = "file")
WANT := [?]string {
	"HTTP3_HEADERS_SENT", "HTTP2_SESSION_SEND_HEADERS", "HTTP_TRANSACTION_SEND_REQUEST_HEADERS",
	"QUIC_SESSION", "QUIC_SESSION_TRANSPORT_PARAMETERS_SENT", "QUIC_SESSION_TRANSPORT_PARAMETERS_RECEIVED",
	"QUIC_SESSION_TRANSPORT_PARAMETERS_RESUMED", "HTTP3_SETTINGS_SENT", "HTTP3_SETTINGS_RECEIVED", "HTTP3_SETTINGS_RESUMED",
	"QUIC_SESSION_ZERO_RTT_STATE", "QUIC_SESSION_VERSION_NEGOTIATED", "QUIC_SESSION_CLOSED", "HTTP3_PRIORITY_UPDATE_SENT",
	"HTTP2_SESSION", "HTTP2_SESSION_INITIALIZED", "HTTP2_SESSION_SEND_SETTINGS", "HTTP2_SESSION_SEND_WINDOW_UPDATE",
	"HTTP2_SESSION_RECV_SETTING", "HTTP2_SESSION_RECV_WINDOW_UPDATE", "HTTP2_SESSION_RECV_GOAWAY", "SSL_CONNECT",
	"HTTP_STREAM_JOB", "HTTP_STREAM_JOB_BOUND_TO_REQUEST", "HTTP_STREAM_JOB_CONTROLLER_ALT_SVC_FOUND", "HTTP_STREAM_JOB_CONTROLLER",
}

// netlog_load reads events whose wall time is within [from, to] (unix ms).
netlog_load :: proc(path: string, from, to: f64) -> (nl: Netlog, ok: bool) {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil do return {}, false
	text := string(data)
	nl.conns = make(map[int]^Net_Conn)
	nl.tls = make(map[int]etf.Value)
	nl.jobs = make(map[int]etf.Value)
	nl.alt = make(map[string]^Net_Conn)
	nl_line := strings.index_byte(text, '\n')
	if nl_line < 0 do return {}, false
	first := strings.trim_right(text[:nl_line], ",\r")
	cv, cerr := etf.from_json(strings.concatenate({first, "}"}, context.temp_allocator), context.temp_allocator)
	if cerr != .None do return {}, false
	consts := get(cv, "constants")
	offset := gn(consts, "timeTickOffset")
	names := make(map[i64]string)
	if types, is_map := get(consts, "logEventTypes").(etf.Map); is_map {
		for p in types {
			k, _ := p.key.(string)
			for w in WANT do if w == k do names[p.value.(i64) or_else -1] = w
		}
	}
	controller_host := make(map[int]string)
	rest := text[nl_line + 1:]
	for line in strings.split_lines_iterator(&rest) {
		// cheap filter: the event type is the last "type": in the line
		ti := strings.last_index(line, `"type":`)
		if ti < 0 do continue
		j := ti + 7
		k := j
		for k < len(line) && line[k] >= '0' && line[k] <= '9' do k += 1
		tn, _ := strconv.parse_i64(line[j:k])
		name, wanted := names[tn]
		if !wanted do continue
		l := strings.trim_right(strings.trim_space(line), ",")
		ev, perr := etf.from_json(l, context.temp_allocator)
		if perr != .None do continue
		tstr := gs(ev, "time")
		tv, _ := strconv.parse_f64(tstr)
		wall := offset + tv
		if wall < from || wall > to {
			free_all(context.temp_allocator)
			continue
		}
		src := int(gn(ev, "source", "id"))
		phase := int(gn(ev, "phase"))
		params := get(ev, "params")
		switch name {
		case "HTTP3_HEADERS_SENT", "HTTP2_SESSION_SEND_HEADERS", "HTTP_TRANSACTION_SEND_REQUEST_HEADERS":
			r: Net_Req
			r.wall = wall
			r.session = src
			r.proto = "h3" if name == "HTTP3_HEADERS_SENT" else ("h2" if name == "HTTP2_SESSION_SEND_HEADERS" else "http/1.1")
			hl, _ := get(params, "headers").(etf.List)
			authority, rpath, scheme := "", "", "https"
			for h in hl {
				s, _ := h.(string)
				// h1 lines are "Name: value"; h2/h3 pseudo-headers start with ':'
				c := strings.index(s[1:], ": ") + 1 if len(s) > 1 else -1
				if c <= 0 do continue
				hn, hv := s[:c], s[c + 2:]
				append(&r.headers, [2]string{strings.clone(hn), strings.clone(hv)})
				switch hn {
				case ":method":
					r.method = strings.clone(hv)
				case ":authority", "Host":
					authority = hv
				case ":path":
					rpath = hv
				case ":scheme":
					scheme = hv
				}
			}
			if r.proto == "http/1.1" {
				line0 := gs(params, "line") // "GET /path HTTP/1.1\r\n"
				parts := strings.fields(line0, context.temp_allocator)
				if len(parts) >= 2 {
					r.method = strings.clone(parts[0])
					rpath = parts[1]
				}
			}
			r.url = fmt.aprintf("%s://%s%s", scheme, authority, rpath)
			if r.proto == "h2" {
				r.extra = clone_value(
					obj(P("stream_id", get(params, "stream_id")), P("exclusive", get(params, "exclusive")), P("parent_stream_id", get(params, "parent_stream_id")), P("weight", get(params, "weight"))),
				)
			}
			append(&nl.reqs, r)
		case "QUIC_SESSION", "HTTP2_SESSION":
			if phase != 1 do break
			c := new(Net_Conn)
			c.id = src
			c.wall = wall
			c.kind = "h3" if name == "QUIC_SESSION" else "h2"
			c.host = strings.clone(gs(params, "host"))
			if name == "QUIC_SESSION" do append(&c.facts, P("quic_versions", clone_value(get(params, "versions"))))
			nl.conns[src] = c
			append(&nl.order, c)
		case "SSL_CONNECT":
			if phase == 2 do nl.tls[src] = clone_value(params)
		case "HTTP2_SESSION_INITIALIZED":
			if c, has := nl.conns[src]; has {
				sock := int(gn(params, "source_dependency", "id"))
				if t, ht := nl.tls[sock]; ht do append(&c.facts, P("tls", t))
			}
		case "HTTP_STREAM_JOB_CONTROLLER":
			if phase == 1 {
				u := gs(params, "url")
				h := u
				if i := strings.index(u, "://"); i >= 0 do h = u[i + 3:]
				if i := strings.index_byte(h, '/'); i >= 0 do h = h[:i]
				controller_host[src] = strings.clone(h)
			}
		case "HTTP_STREAM_JOB":
			if phase == 1 do nl.jobs[src] = clone_value(params)
		case "HTTP_STREAM_JOB_CONTROLLER_ALT_SVC_FOUND":
			host := controller_host[src]
			a := alt_entry(&nl, host, wall)
			add_unique(a, "alt_svc", gs(params, "alt_svc"))
		case "HTTP_STREAM_JOB_BOUND_TO_REQUEST":
			// a job (not the controller) bound to the request = race winner
			if job, is_job := nl.jobs[src]; is_job {
				ctrl := int(gn(job, "source_dependency", "id"))
				host := controller_host[ctrl]
				a := alt_entry(&nl, host, wall)
				winner := fmt.tprintf("%s(%s)", gs(job, "type"), "quic" if (get(job, "using_quic").(bool) or_else false) else "tcp")
				bump(a, winner)
			}
		case:
			if c, has := nl.conns[src]; has {
				key := strings.to_lower(name)
				if strings.has_prefix(key, "quic_session_") do key = key[len("quic_session_"):]
				if strings.has_prefix(key, "http2_session_") do key = key[len("http2_session_"):]
				append(&c.facts, P(strings.clone(key), clone_value(params)))
			}
		}
		free_all(context.temp_allocator)
	}
	nl.loaded = true
	return nl, true
}

@(private = "file")
alt_entry :: proc(nl: ^Netlog, host: string, wall: f64) -> ^Net_Conn {
	if a, ok := nl.alt[host]; ok do return a
	a := new(Net_Conn)
	a.kind = "alt_svc"
	a.host = strings.clone(host)
	a.wall = wall
	a.id = -(len(nl.alt) + 1)
	nl.alt[a.host] = a
	append(&nl.order, a)
	return a
}

@(private = "file")
add_unique :: proc(c: ^Net_Conn, key, value: string) {
	for p in c.facts do if (p.key.(string) or_else "") == key && (p.value.(string) or_else "") == value do return
	append(&c.facts, P(key, strings.clone(value)))
}

@(private = "file")
bump :: proc(c: ^Net_Conn, key: string) {
	for &p in c.facts {
		if (p.key.(string) or_else "") == key {
			p.value = (p.value.(i64) or_else 0) + 1
			return
		}
	}
	append(&c.facts, P(strings.clone(key), i64(1)))
}

// netlog_match finds the netlog request for a CDP request (same method + URL,
// sent at or after the CDP request time, earliest unused).
netlog_match :: proc(nl: ^Netlog, method, url: string, wall: f64) -> ^Net_Req {
	u := url
	if i := strings.index_byte(u, '#'); i >= 0 do u = u[:i]
	best: ^Net_Req
	for &r in nl.reqs {
		if r.used || r.method != method do continue
		if r.wall < wall - 1000 || r.wall > wall + 15000 do continue
		if r.url != u do continue
		if best == nil || r.wall < best.wall do best = &r
	}
	if best != nil do best.used = true
	return best
}
