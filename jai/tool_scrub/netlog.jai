// Chrome netlog (--log-net-log, default capture mode) -> true wire header
// order for h2/h3/http1.1 requests and connection-level facts.
// The file is one event per line after a constants line; it may be truncated
// (the browser is still running), so every line is parsed independently.

Net_Req :: struct {
	wall: float64; // unix ms
	proto: string;
	method: string;
	url: string; // scheme://authority/path for matching
	headers: [..][2]string;
	extra: etf.Value; // h2 priority fields
	session: int;
	used: bool;
}

Net_Conn :: struct {
	id: int;
	wall: float64;
	kind: string; // "h3" | "h2" | "alt_svc"
	host: string;
	facts: [..]etf.Pair;
}

Netlog :: struct {
	reqs: [..]Net_Req;
	conns: Map(int, *Net_Conn);
	order: [..]*Net_Conn;
	tls: Map(int, etf.Value); // socket id -> SSL_CONNECT end params
	jobs: Map(int, etf.Value); // stream job id -> begin params
	alt: Map(string, *Net_Conn); // host -> alt-svc / race summary
	loaded: bool;
}
#scope_file

WANT := string.[
	"HTTP3_HEADERS_SENT", "HTTP2_SESSION_SEND_HEADERS", "HTTP_TRANSACTION_SEND_REQUEST_HEADERS",
	"QUIC_SESSION", "QUIC_SESSION_TRANSPORT_PARAMETERS_SENT", "QUIC_SESSION_TRANSPORT_PARAMETERS_RECEIVED",
	"QUIC_SESSION_TRANSPORT_PARAMETERS_RESUMED", "HTTP3_SETTINGS_SENT", "HTTP3_SETTINGS_RECEIVED", "HTTP3_SETTINGS_RESUMED",
	"QUIC_SESSION_ZERO_RTT_STATE", "QUIC_SESSION_VERSION_NEGOTIATED", "QUIC_SESSION_CLOSED", "HTTP3_PRIORITY_UPDATE_SENT",
	"HTTP2_SESSION", "HTTP2_SESSION_INITIALIZED", "HTTP2_SESSION_SEND_SETTINGS", "HTTP2_SESSION_SEND_WINDOW_UPDATE",
	"HTTP2_SESSION_RECV_SETTING", "HTTP2_SESSION_RECV_WINDOW_UPDATE", "HTTP2_SESSION_RECV_GOAWAY", "SSL_CONNECT",
	"HTTP_STREAM_JOB", "HTTP_STREAM_JOB_BOUND_TO_REQUEST", "HTTP_STREAM_JOB_CONTROLLER_ALT_SVC_FOUND", "HTTP_STREAM_JOB_CONTROLLER"
];
#scope_export

// netlog_load reads events whose wall time is within [from, to] (unix ms).
netlog_load :: (path: string, from: float64, to: float64) -> Netlog, bool {
	nl: Netlog;
	ok: bool;
	data, err := os.read_entire_file(path, context.allocator);
	if err != null { return .{}, false; }
	text := as_string(data);
	nl.conns = Map(int, *Net_Conn).{};
	nl.tls = Map(int, etf.Value).{};
	nl.jobs = Map(int, etf.Value).{};
	nl.alt = Map(string, *Net_Conn).{};
	nl_line := strings.index_byte(text, 10);
	if nl_line < 0 { return .{}, false; }
	first := strings.trim_right(sub(text, 0, nl_line), ",\r");
	cv, cerr := etf.from_json(strings.concatenate(string.[first, "}"], temp), temp);
	if cerr != .None { return .{}, false; }
	consts := get(cv, "constants");
	offset := gn(consts, "timeTickOffset");
	names := Map(s64, string).{};
	{ types, is_map := get(consts, "logEventTypes").map, get(consts, "logEventTypes").kind == .Map;
	if is_map {
		for p: types {
			k := vs(p.key);
			for w: WANT { if w == k { at(*names, ifx p.value.kind == .Int then p.value.i else -1).* = w; } }
		}
	} }
	controller_host := Map(int, string).{};
	rest := sub_from(text, nl_line + 1);
	while true { line, __ok1 := strings.split_lines_iterator(*rest); if !__ok1 break;
		// cheap filter: the event type is the last "type": in the line
		ti := strings.last_index(line, "\"type\":");
		if ti < 0 { continue; }
		j := ti + 7;
		k := j;
		while k < len(line) && line[k] >= #char "0" && line[k] <= #char "9" { k += 1; }
		tn, _ := strconv.parse_i64(sub(line, j, k));
		name, wanted := map_find(names, tn);
		if !wanted { continue; }
		l := strings.trim_right(strings.trim_space(line), ",");
		ev, perr := etf.from_json(l, temp);
		if perr != .None { continue; }
		tstr := gs(ev, "time");
		tv, _ := strconv.parse_f64(tstr);
		wall := offset + tv;
		if wall < from || wall > to {
			reset_temporary_storage();
			continue;
		}
		src := cast(int)(gn(ev, "source", "id"));
		phase := cast(int)(gn(ev, "phase"));
		params := get(ev, "params");
		for __sw2: 0..0 { if name == {
		case "HTTP3_HEADERS_SENT"; #through; case "HTTP2_SESSION_SEND_HEADERS"; #through; case "HTTP_TRANSACTION_SEND_REQUEST_HEADERS";
			r: Net_Req;
			r.wall = wall;
			r.session = src;
			r.proto = ifx name == "HTTP3_HEADERS_SENT" then "h3" else (ifx name == "HTTP2_SESSION_SEND_HEADERS" then "h2" else "http/1.1");
			hl := vl(get(params, "headers"));
			authority, rpath, scheme := "", "", "https";
			for h: hl {
				s := vs(h);
				// h1 lines are "Name: value"; h2/h3 pseudo-headers start with ':'
				c := ifx len(s) > 1 then strings.index(sub_from(s, 1), ": ") + 1 else -1;
				if c <= 0 { continue; }
				hn, hv := sub(s, 0, c), sub_from(s, c + 2);
				append(*r.headers, string.[clone(hn), clone(hv)]);
				if hn == {
				case ":method";
					r.method = clone(hv);
				case ":authority"; #through; case "Host";
					authority = hv;
				case ":path";
					rpath = hv;
				case ":scheme";
					scheme = hv;
				}
			}
			if r.proto == "http/1.1" {
				line0 := gs(params, "line"); // "GET /path HTTP/1.1\r\n"
				parts := strings.fields(line0, temp);
				if len(parts) >= 2 {
					r.method = clone(parts[0]);
					rpath = parts[1];
				}
			}
			r.url = fmt.aprintf("%s://%s%s", scheme, authority, rpath);
			if r.proto == "h2" {
				r.extra = clone_value(
					obj(P("stream_id", get(params, "stream_id")), P("exclusive", get(params, "exclusive")), P("parent_stream_id", get(params, "parent_stream_id")), P("weight", get(params, "weight"))),
				);
			}
			append(*nl.reqs, r);
		case "QUIC_SESSION"; #through; case "HTTP2_SESSION";
			if phase != 1 { break __sw2; }
			c := new(Net_Conn);
			c.id = src;
			c.wall = wall;
			c.kind = ifx name == "QUIC_SESSION" then "h3" else "h2";
			c.host = clone(gs(params, "host"));
			if name == "QUIC_SESSION" { append(*c.facts, P("quic_versions", clone_value(get(params, "versions")))); }
			at(*nl.conns, src).* = c;
			append(*nl.order, c);
		case "SSL_CONNECT";
			if phase == 2 { at(*nl.tls, src).* = clone_value(params); }
		case "HTTP2_SESSION_INITIALIZED";
			{ c, has := map_find(nl.conns, src);
			if has {
				sock := cast(int)(gn(params, "source_dependency", "id"));
				{ t, ht := map_find(nl.tls, sock);
				if ht { append(*c.facts, P("tls", t)); } }
			} }
		case "HTTP_STREAM_JOB_CONTROLLER";
			if phase == 1 {
				u := gs(params, "url");
				h := u;
				{ i := strings.index(u, "://");
				if i >= 0 { h = sub_from(u, i + 3); } }
				{ i := strings.index_byte(h, #char "/");
				if i >= 0 { h = sub(h, 0, i); } }
				at(*controller_host, src).* = clone(h);
			}
		case "HTTP_STREAM_JOB";
			if phase == 1 { at(*nl.jobs, src).* = clone_value(params); }
		case "HTTP_STREAM_JOB_CONTROLLER_ALT_SVC_FOUND";
			host := get(controller_host, src);
			a := alt_entry(*nl, host, wall);
			// drop the per-response expiry so repeated advertisements collapse
			adv := gs(params, "alt_svc");
			{ i := strings.index(adv, ", expires");
			if i >= 0 { adv = sub(adv, 0, i); } }
			add_unique(a, "alt_svc", adv);
		case "HTTP_STREAM_JOB_BOUND_TO_REQUEST";
			// a job (not the controller) bound to the request = race winner
			{ job, is_job := map_find(nl.jobs, src);
			if is_job {
				ctrl := cast(int)(gn(job, "source_dependency", "id"));
				host := get(controller_host, ctrl);
				a := alt_entry(*nl, host, wall);
				winner := fmt.tprintf("%s(%s)", gs(job, "type"), ifx (ifx get(job, "using_quic").kind == .Bool then get(job, "using_quic").b else false) then "quic" else "tcp");
				bump(a, winner);
			} }
		case;
			{ c, has := map_find(nl.conns, src);
			if has {
				key := strings.to_lower(name);
				if strings.has_prefix(key, "quic_session_") { key = sub_from(key, len("quic_session_")); }
				if strings.has_prefix(key, "http2_session_") { key = sub_from(key, len("http2_session_")); }
				append(*c.facts, P(clone(key), clone_value(params)));
			} }
		} }
		reset_temporary_storage();
	}
	nl.loaded = true;
	return nl, true;
}
#scope_file

alt_entry :: (nl: *Netlog, host: string, wall: float64) -> *Net_Conn {
	{ a, ok := map_find(nl.alt, host);
	if ok { return a; } }
	a := new(Net_Conn);
	a.kind = "alt_svc";
	a.host = clone(host);
	a.wall = wall;
	a.id = -(len(nl.alt) + 1);
	at(*nl.alt, a.host).* = a;
	append(*nl.order, a);
	return a;
}

add_unique :: (c: *Net_Conn, key: string, value: string) {
	for p: c.facts { if (ifx p.key.kind == .String then p.key.s else "") == key && (ifx p.value.kind == .String then p.value.s else "") == value { return; } }
	append(*c.facts, P(key, clone(value)));
}

bump :: (c: *Net_Conn, key: string) {
	for * p: c.facts {
		if (ifx p.key.kind == .String then p.key.s else "") == key {
			p.value = etf.vint((ifx p.value.kind == .Int then p.value.i else 0) + 1);
			return;
		}
	}
	append(*c.facts, P(clone(key), cast(s64)(1)));
}
#scope_export

// netlog_match finds the netlog request for a CDP request (same method + URL,
// sent at or after the CDP request time, earliest unused).
netlog_match :: (nl: *Netlog, method: string, url: string, wall: float64) -> *Net_Req {
	u := url;
	{ i := strings.index_byte(u, #char "#");
	if i >= 0 { u = sub(u, 0, i); } }
	best: *Net_Req;
	for * r: nl.reqs {
		if r.used || r.method != method { continue; }
		if r.wall < wall - 1000 || r.wall > wall + 15000 { continue; }
		if r.url != u { continue; }
		if best == null || r.wall < best.wall { best = r; }
	}
	if best != null { best.used = true; }
	return best;
}

