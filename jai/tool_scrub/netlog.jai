// Chrome netlog (--log-net-log, default capture mode) -> true wire header
// order for h2/h3/http1.1 requests and connection-level facts.
// The file is one event per line after a constants line; it may be truncated
// (the browser is still running), so every line is parsed independently.

Header :: struct { name, value: string; }

Net_Req :: struct {
    wall: float64;  // unix ms
    proto: string;
    method: string;
    url: string;    // scheme://authority/path for matching
    headers: [..]Header;
    extra: etf.Value;  // h2 priority fields
    session: int;
    used: bool;
}

Net_Conn :: struct {
    id: int;
    wall: float64;
    kind: string;  // "h3" | "h2" | "alt_svc"
    host: string;
    facts: [..]etf.Pair;
}

Netlog :: struct {
    reqs: [..]Net_Req;
    conns: Table(int, *Net_Conn);
    order: [..]*Net_Conn;
    tls: Table(int, etf.Value);    // socket id -> SSL_CONNECT end params
    jobs: Table(int, etf.Value);   // stream job id -> begin params
    alt: Table(string, *Net_Conn); // host -> alt-svc / race summary
    loaded: bool;
}

WANT :: string.[
    "HTTP3_HEADERS_SENT", "HTTP2_SESSION_SEND_HEADERS", "HTTP_TRANSACTION_SEND_REQUEST_HEADERS",
    "QUIC_SESSION", "QUIC_SESSION_TRANSPORT_PARAMETERS_SENT", "QUIC_SESSION_TRANSPORT_PARAMETERS_RECEIVED",
    "QUIC_SESSION_TRANSPORT_PARAMETERS_RESUMED", "HTTP3_SETTINGS_SENT", "HTTP3_SETTINGS_RECEIVED", "HTTP3_SETTINGS_RESUMED",
    "QUIC_SESSION_ZERO_RTT_STATE", "QUIC_SESSION_VERSION_NEGOTIATED", "QUIC_SESSION_CLOSED", "HTTP3_PRIORITY_UPDATE_SENT",
    "HTTP2_SESSION", "HTTP2_SESSION_INITIALIZED", "HTTP2_SESSION_SEND_SETTINGS", "HTTP2_SESSION_SEND_WINDOW_UPDATE",
    "HTTP2_SESSION_RECV_SETTING", "HTTP2_SESSION_RECV_WINDOW_UPDATE", "HTTP2_SESSION_RECV_GOAWAY", "SSL_CONNECT",
    "HTTP_STREAM_JOB", "HTTP_STREAM_JOB_BOUND_TO_REQUEST", "HTTP_STREAM_JOB_CONTROLLER_ALT_SVC_FOUND", "HTTP_STREAM_JOB_CONTROLLER",
];

// netlog_load reads events whose wall time is within [from, to] (unix ms).
netlog_load :: (nl: *Netlog, path: string, from: float64, to: float64) -> bool {
    text, ok := read_entire_file(path);
    if !ok return false;
    found, first, rest := split_from_left(text, #char "\n");
    if !found return false;
    cv, cerr := etf.from_json(join(trim_right(first, ",\r"), "}",, temp),, temp);
    if cerr != .None return false;
    consts := get(cv, "constants");
    offset := gn(consts, "timeTickOffset");
    names: Table(s64, string);
    types := get(consts, "logEventTypes");
    if types.kind == .Map for types.map {
        if !array_find(WANT, as_str(it.key)) continue;
        table_set(*names, ifx it.value.kind == .Int then it.value.i else -1, copy_string(it.key.s));
    }
    controller_host: Table(int, string);
    for line: lines_of(rest) {
        reset_temporary_storage();
        // cheap filter: the event type is the last "type": in the line
        ti := find_index_from_right(line, "\"type\":");
        if ti < 0 continue;
        k := ti + 7;
        while k < line.count && line[k] >= #char "0" && line[k] <= #char "9" k += 1;
        tn := string_to_int(slice(line, ti + 7, k - ti - 7));
        wanted, name := table_find(*names, tn);
        if !wanted continue;
        ev, perr := etf.from_json(trim_right(trim(line), ","),, temp);
        if perr != .None continue;
        wall := offset + string_to_float64(gs(ev, "time"));
        if wall < from || wall > to continue;
        src := cast(int) gn(ev, "source", "id");
        phase := cast(int) gn(ev, "phase");
        params := get(ev, "params");
        _, conn := table_find(*nl.conns, src);
        if name == "HTTP3_HEADERS_SENT" || name == "HTTP2_SESSION_SEND_HEADERS" || name == "HTTP_TRANSACTION_SEND_REQUEST_HEADERS" {
            r := array_add(*nl.reqs);
            r.wall = wall;
            r.session = src;
            r.proto = ifx name == "HTTP3_HEADERS_SENT" then "h3" else ifx name == "HTTP2_SESSION_SEND_HEADERS" then "h2" else "http/1.1";
            authority, rpath, scheme := "", "", "https";
            for h: as_list(get(params, "headers")) {
                s := as_str(h);
                // h1 lines are "Name: value"; h2/h3 pseudo-headers start with ':'
                c := ifx s.count > 1 then find_index_from_left(slice(s, 1, s.count - 1), ": ") + 1 else -1;
                if c <= 0 continue;
                hn, hv := copy_string(slice(s, 0, c)), copy_string(slice(s, c + 2, s.count - c - 2));
                array_add(*r.headers, .{hn, hv});
                if hn == ":method" r.method = hv;
                else if hn == ":authority" || hn == "Host" authority = hv;
                else if hn == ":path" rpath = hv;
                else if hn == ":scheme" scheme = hv;
            }
            if r.proto == "http/1.1" {
                parts: [..]string;  // the fields of "GET /path HTTP/1.1\r\n"
                parts.allocator = temp;
                for split(gs(params, "line"), " ",, temp) { f := trim(it); if f array_add(*parts, f); }
                if parts.count >= 2 {
                    r.method = copy_string(parts[0]);
                    rpath = parts[1];
                }
            }
            r.url = join(scheme, "://", authority, rpath);
            if r.proto == "h2" r.extra = clone_value(obj(P("stream_id", get(params, "stream_id")), P("exclusive", get(params, "exclusive")),
                P("parent_stream_id", get(params, "parent_stream_id")), P("weight", get(params, "weight"))));
        } else if name == "QUIC_SESSION" || name == "HTTP2_SESSION" {
            if phase != 1 continue;
            c := New(Net_Conn);
            c.id = src;
            c.wall = wall;
            c.kind = ifx name == "QUIC_SESSION" then "h3" else "h2";
            c.host = copy_string(gs(params, "host"));
            if name == "QUIC_SESSION" array_add(*c.facts, P("quic_versions", clone_value(get(params, "versions"))));
            table_set(*nl.conns, src, c);
            array_add(*nl.order, c);
        } else if name == "SSL_CONNECT" {
            if phase == 2 table_set(*nl.tls, src, clone_value(params));
        } else if name == "HTTP2_SESSION_INITIALIZED" {
            if !conn continue;
            has, t := table_find(*nl.tls, cast(int) gn(params, "source_dependency", "id"));
            if has array_add(*conn.facts, P("tls", t));
        } else if name == "HTTP_STREAM_JOB_CONTROLLER" {
            if phase != 1 continue;
            u := gs(params, "url");
            found, _, after := split_from_left(u, "://");
            _, h := split_from_left(ifx found then after else u, #char "/");
            table_set(*controller_host, src, copy_string(h));
        } else if name == "HTTP_STREAM_JOB" {
            if phase == 1 table_set(*nl.jobs, src, clone_value(params));
        } else if name == "HTTP_STREAM_JOB_CONTROLLER_ALT_SVC_FOUND" {
            _, host := table_find(*controller_host, src);
            a := alt_entry(nl, host, wall);
            // drop the per-response expiry so repeated advertisements collapse
            _, adv := split_from_left(gs(params, "alt_svc"), ", expires");
            for a.facts if as_str(it.key) == "alt_svc" && as_str(it.value) == adv continue line;
            array_add(*a.facts, P("alt_svc", copy_string(adv)));
        } else if name == "HTTP_STREAM_JOB_BOUND_TO_REQUEST" {
            // a job (not the controller) bound to the request = race winner
            is_job, job := table_find(*nl.jobs, src);
            if !is_job continue;
            _, host := table_find(*controller_host, cast(int) gn(job, "source_dependency", "id"));
            a := alt_entry(nl, host, wall);
            winner := tprint("%(%)", gs(job, "type"), ifx gb(job, "using_quic") then "quic" else "tcp");
            for * a.facts if as_str(it.key) == winner {
                it.value = etf.vint((ifx it.value.kind == .Int then it.value.i else 0) + 1);
                continue line;
            }
            array_add(*a.facts, P(copy_string(winner), 1));
        } else if conn {
            key := to_lower_copy(name);
            if begins_with(key, "quic_session_") advance(*key, "quic_session_".count);
            if begins_with(key, "http2_session_") advance(*key, "http2_session_".count);
            array_add(*conn.facts, P(key, clone_value(params)));
        }
    }
    nl.loaded = true;
    return true;
}

alt_entry :: (nl: *Netlog, host: string, wall: float64) -> *Net_Conn {
    found, a := table_find(*nl.alt, host);
    if found return a;
    a = New(Net_Conn);
    a.kind = "alt_svc";
    a.host = copy_string(host);
    a.wall = wall;
    a.id = -(nl.alt.count + 1);
    table_add(*nl.alt, a.host, a);
    array_add(*nl.order, a);
    return a;
}

// netlog_match finds the netlog request for a CDP request (same method + URL,
// sent at or after the CDP request time, earliest unused).
netlog_match :: (nl: *Netlog, method: string, url: string, wall: float64) -> *Net_Req {
    _, u := split_from_left(url, #char "#");
    best: *Net_Req;
    for * nl.reqs {
        if it.used || it.method != method continue;
        if it.wall < wall - 1000 || it.wall > wall + 15000 continue;
        if it.url != u continue;
        if !best || it.wall < best.wall best = it;
    }
    if best best.used = true;
    return best;
}
