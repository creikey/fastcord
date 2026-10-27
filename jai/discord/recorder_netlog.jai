// Netlog side file for the recorder: the same event shapes Chrome's
// --log-net-log writes, so tools/scrub's netlog reader gives our recordings
// `wire` (true send order) and `conn` lines like the official fixtures.
//   - request headers: rebuilt with the same field order fc:http (h2),
//     fc:quic and h1_serialize_request put on the wire
//   - h3 transport parameters: decoded from the bytes the session's
//     ClientHello carried (Conn_Event.quic_params)
//   - h3 SETTINGS: quic.H3_SETTINGS (what nghttp3 writes)
//   - h2 SETTINGS / WINDOW_UPDATE: the values h2_connect sent
// Cookie and authorization values are stripped like Chrome does.

NETLOG_TYPES := string.[
	"HTTP3_HEADERS_SENT",
	"HTTP2_SESSION_SEND_HEADERS",
	"HTTP_TRANSACTION_SEND_REQUEST_HEADERS",
	"QUIC_SESSION",
	"QUIC_SESSION_TRANSPORT_PARAMETERS_SENT",
	"HTTP3_SETTINGS_SENT",
	"HTTP2_SESSION",
	"HTTP2_SESSION_INITIALIZED",
	"HTTP2_SESSION_SEND_SETTINGS",
	"HTTP2_SESSION_SEND_WINDOW_UPDATE",
	"SSL_CONNECT"
];
#scope_file

nl_type :: (name: string) -> int {
	for n, i: NETLOG_TYPES { if n == name { return i + 1; } }
	return 0;
}

// nl_file opens the account's netlog on first use (caller holds r.mu).
nl_file :: (r: *Recorder, acct: string) -> *os.File {
	i := ifx acct == "b" then 1 else 0;
	if r.closed { return null; }
	if r.nl[i] != null || r.nl_path == "" { return r.nl[i]; }
	f, err := os.create(fmt.tprintf("%s.netlog-%s", r.nl_path, ifx i == 1 then "b" else "a"));
	if err != null { return null; }
	r.nl[i] = f;
	sb := strings.builder_make(temp);
	strings.write_string(*sb, "{\"constants\":{\"logEventTypes\":{");
	for name, k: NETLOG_TYPES {
		if k > 0 { strings.write_byte(*sb, #char ","); }
		fmt.sbprintf(*sb, "\"%s\":%d", name, k + 1);
	}
	strings.write_string(*sb, "},\"timeTickOffset\":0},\n\"events\": [\n");
	os.write_string(f, strings.to_string(sb));
	return f;
}
#scope_export

netlog_close :: (r: *Recorder) {
	for * f: r.nl {
		if f.* == null { continue; }
		os.write_string(f.*, "{}]}\n");
		os.close(f.*);
		f.* = null;
	}
	for k: r.sessions { delete(k); }
	delete(r.sessions);
	delete(r.nl_path);
}
#scope_file

// nl_event writes one event; caller holds r.mu. params is a JSON object.
nl_event :: (f: *os.File, name: string, src: int, phase: int, at_ms: s64, params: string) {
	if is_null(f) { return; }
	line := fmt.tprintf("{{\"params\":%s,\"phase\":%d,\"source\":{{\"id\":%d,\"type\":0}},\"time\":\"%d\",\"type\":%d}},\n", params, phase, src, at_ms, nl_type(name));
	os.write_string(f, line);
}

nl_source :: (r: *Recorder) -> int {
	r.nl_next += 1;
	return r.nl_next;
}

// nl_session returns the source id of the latest session for key (caller holds r.mu).
nl_session :: (r: *Recorder, key: string) -> int {
	{ id, ok := map_find(r.sessions, key);
	if ok { return id; } }
	id := nl_source(r);
	at(*r.sessions, clone(key)).* = id;
	return id;
}
#scope_module

rec_conn :: (data: *void, ev: Conn_Event) {
	tap := cast(*Recorder_Tap)data;
	r := tap.r;
	locks.lock(*r.mu);
	defer locks.unlock(*r.mu);
	f := nl_file(r, tap.acct);
	if is_null(f) { return; }
	at_ms := now_ms();
	key := fmt.tprintf("%s %s %s", tap.acct, ev.kind, ev.host);
	id := nl_source(r);
	if has(r.sessions, key) {
		at(*r.sessions, key).* = id;
	} else {
		at(*r.sessions, clone(key)).* = id;
	}
	sb := strings.builder_make(temp);
	if ev.kind == {
	case "h3";
		strings.write_string(*sb, "{\"host\":");
		json_write_escaped(*sb, ev.host);
		strings.write_string(*sb, ",\"port\":443,\"versions\":\"RFCv1\"}");
		nl_event(f, "QUIC_SESSION", id, 1, at_ms, strings.to_string(sb));
		strings.builder_reset(*sb);
		strings.write_string(*sb, "{\"quic_transport_parameters\":");
		json_write_escaped(*sb, quic_params_text(ev.quic_params, "Client"));
		strings.write_string(*sb, "}");
		nl_event(f, "QUIC_SESSION_TRANSPORT_PARAMETERS_SENT", id, 0, at_ms, strings.to_string(sb));
		nl_event(f, "HTTP3_SETTINGS_SENT", id, 0, at_ms, h3_settings_json());
	case "h2";
		sock := nl_source(r);
		strings.write_string(*sb, "{\"next_proto\":");
		json_write_escaped(*sb, ev.alpn);
		strings.write_string(*sb, ",\"version\":\"TLS 1.3\"}");
		nl_event(f, "SSL_CONNECT", sock, 2, at_ms, strings.to_string(sb));
		strings.builder_reset(*sb);
		fmt.sbprintf(*sb, "{{\"host\":\"%s:443\",\"proxy\":\"DIRECT\"}}", ev.host);
		nl_event(f, "HTTP2_SESSION", id, 1, at_ms, strings.to_string(sb));
		nl_event(f, "HTTP2_SESSION_INITIALIZED", id, 0, at_ms, fmt.tprintf("{{\"protocol\":\"%s\",\"source_dependency\":{{\"id\":%d,\"type\":0}}}}", ev.alpn, sock));
		strings.builder_reset(*sb);
		strings.write_string(*sb, "{\"settings\":[");
		for s, i: ev.h2_settings {
			if i > 0 { strings.write_byte(*sb, #char ","); }
			fmt.sbprintf(*sb, "\"[id:%d (%s) value:%d]\"", s.id, h2_setting_name(cast(u16)(s.id)), s.value);
		}
		strings.write_string(*sb, "]}");
		nl_event(f, "HTTP2_SESSION_SEND_SETTINGS", id, 0, at_ms, strings.to_string(sb));
		if ev.h2_window_increment > 0 {
			nl_event(f, "HTTP2_SESSION_SEND_WINDOW_UPDATE", id, 0, at_ms, fmt.tprintf("{{\"delta\":%d,\"stream_id\":0}}", ev.h2_window_increment));
		}
	}
}
#scope_export

// nl_request_headers writes the request's header block in send order.
nl_request_headers :: (r: *Recorder, acct: string, host: string, req: http.Request, version: http.Version, at_ms: s64) {
	locks.lock(*r.mu);
	defer locks.unlock(*r.mu);
	f := nl_file(r, acct);
	if is_null(f) { return; }
	fields := make_dynamic(http.Header, 0, len(req.headers) + 5, temp);
	scheme := ifx req.scheme != "" then req.scheme else "https";
	authority := ifx req.authority != "" then req.authority else host;
	name := "HTTP_TRANSACTION_SEND_REQUEST_HEADERS";
	src := 0;
	if version == {
	case .Http3;
		// quic.request: pseudo-headers, the request's fields, then priority
		// unless the request carries one
		name = "HTTP3_HEADERS_SENT";
		src = nl_session(r, fmt.tprintf("%s h3 %s", acct, host));
		append(*fields, http.Header.{":method", req.method}, http.Header.{":authority", authority}, http.Header.{":scheme", scheme}, http.Header.{":path", req.path});
		has := false;
		for h: req.headers {
			if h.name == "priority" { has = true; }
			append(*fields, h);
		}
		if !has { append(*fields, http.Header.{"priority", fmt.tprintf("u=%d, i", quic.urgency(req.priority))}); }
	case .Http2;
		name = "HTTP2_SESSION_SEND_HEADERS";
		src = nl_session(r, fmt.tprintf("%s h2 %s", acct, host));
		append(*fields, http.Header.{":method", req.method}, http.Header.{":authority", authority}, http.Header.{":scheme", req.scheme}, http.Header.{":path", req.path});
		append(*fields, ..req.headers);
	case .Http1_1; #through; case .Http1_0;
		src = nl_source(r);
		// h1_serialize_request: Host first unless the caller placed one
		has_host := false;
		for h: req.headers { if strings.equal_fold(h.name, "host") { has_host = true; } }
		if !has_host { append(*fields, http.Header.{"Host", authority}); }
		append(*fields, ..req.headers);
	}
	sb := strings.builder_make(temp);
	strings.write_string(*sb, "{\"headers\":[");
	for h, i: fields {
		if i > 0 { strings.write_byte(*sb, #char ","); }
		v := h.value;
		lname := strings.to_lower(h.name, temp);
		if lname == "cookie" || lname == "authorization" { v = fmt.tprintf("[%d bytes were stripped]", len(h.value)); }
		json_write_escaped(*sb, fmt.tprintf("%s: %s", h.name, v));
	}
	strings.write_string(*sb, "]");
	if version == .Http1_1 || version == .Http1_0 {
		strings.write_string(*sb, ",\"line\":");
		json_write_escaped(*sb, fmt.tprintf("%s %s HTTP/1.1\r\n", req.method, req.path));
	}
	strings.write_string(*sb, "}");
	nl_event(f, name, src, 0, at_ms, strings.to_string(sb));
}
#scope_file

h2_setting_name :: (id: u16) -> string {
	if id == {
	case 1;
		return "SETTINGS_HEADER_TABLE_SIZE";
	case 2;
		return "SETTINGS_ENABLE_PUSH";
	case 3;
		return "SETTINGS_MAX_CONCURRENT_STREAMS";
	case 4;
		return "SETTINGS_INITIAL_WINDOW_SIZE";
	case 5;
		return "SETTINGS_MAX_FRAME_SIZE";
	case 6;
		return "SETTINGS_MAX_HEADER_LIST_SIZE";
	case 8;
		return "SETTINGS_ENABLE_CONNECT_PROTOCOL";
	case 9;
		return "SETTINGS_NO_RFC7540_PRIORITIES";
	}
	return "SETTINGS_UNKNOWN";
}

get_varint :: (b: []u8, pos: *int) -> u64, bool {
	v: u64;
	ok: bool;
	if pos.* >= len(b) { return 0, false; }
	n := 1 << (b[pos.*] >> 6);
	if pos.* + n > len(b) { return 0, false; }
	v = cast(u64)(b[pos.*] & 0x3f);
	for i: 1..n-1 { v = (v << 8) | (cast(u64)(b[pos.* + i])); }
	pos.* += n;
	return v, true;
}
#scope_export

// h3_settings_json: our control stream SETTINGS as Chrome logs them
// (names sorted, as Chrome's dictionary prints).
h3_settings_json :: () -> string {
	pairs := make_dynamic([2]string, 0, 8, temp);
	for s: quic.H3_SETTINGS {
		nm: string;
		if s[0] == {
		case 0x01;
			nm = "SETTINGS_QPACK_MAX_TABLE_CAPACITY";
		case 0x06;
			nm = "SETTINGS_MAX_FIELD_SECTION_SIZE";
		case 0x07;
			nm = "SETTINGS_QPACK_BLOCKED_STREAMS";
		case 0x33;
			nm = "SETTINGS_H3_DATAGRAM";
		}
		append(*pairs, string.[nm, fmt.tprintf("%d", s[1])]);
	}
	slice.sort_by(view(pairs), (a: [2]string, c: [2]string) -> bool {return compare(a[0], c[0]) < 0;});
	sb := strings.builder_make(temp);
	strings.write_byte(*sb, #char "{");
	for p, i: pairs {
		if i > 0 { strings.write_byte(*sb, #char ","); }
		fmt.sbprintf(*sb, "\"%s\":%s", p[0], p[1]);
	}
	strings.write_byte(*sb, #char "}");
	return strings.to_string(sb);
}

// quic_params_text formats encoded transport parameters the way QUICHE's
// TransportParameters::ToString does (canonical order; GREASE parameters and
// GREASE versions are added at serialization, so they are not listed).
quic_params_text :: (b: []u8, perspective: string) -> string {
	Known :: struct {
		id: u64;
		name: string;
		kind: u8; // 'i' int, 'c' connection id, 'f' flag
	}
	ORDER := Known.[
		.{0x00, "original_destination_connection_id", #char "c"},
		.{0x01, "max_idle_timeout", #char "i"},
		.{0x02, "stateless_reset_token", #char "c"},
		.{0x03, "max_udp_payload_size", #char "i"},
		.{0x04, "initial_max_data", #char "i"},
		.{0x05, "initial_max_stream_data_bidi_local", #char "i"},
		.{0x06, "initial_max_stream_data_bidi_remote", #char "i"},
		.{0x07, "initial_max_stream_data_uni", #char "i"},
		.{0x08, "initial_max_streams_bidi", #char "i"},
		.{0x09, "initial_max_streams_uni", #char "i"},
		.{0x0a, "ack_delay_exponent", #char "i"},
		.{0x0b, "max_ack_delay", #char "i"},
		.{0x0c, "disable_active_migration", #char "f"},
		.{0x0e, "active_connection_id_limit", #char "i"},
		.{0x0f, "initial_source_connection_id", #char "c"},
		.{0x10, "retry_source_connection_id", #char "c"},
		.{0x20, "max_datagram_frame_size", #char "i"},
		.{0x3127, "initial_round_trip_time", #char "i"}
	];
	vals := make_map(u64, []u8, temp);
	pos := 0;
	while pos < len(b) {
		id, ok1 := get_varint(b, *pos);
		l, ok2 := get_varint(b, *pos);
		if !ok1 || !ok2 || pos + cast(int)(l) > len(b) { break; }
		at(*vals, id).* = sub(b, pos, pos + cast(int)(l));
		pos += cast(int)(l);
	}
	sb := strings.builder_make(temp);
	fmt.sbprintf(*sb, "[%s", perspective);
	{ vi, ok := map_find(vals, 0x11);
	if ok && len(vi) >= 4 {
		be :: (x: []u8) -> u32 {return ((cast(u32)(x[0])) << 24) | ((cast(u32)(x[1])) << 16) | ((cast(u32)(x[2])) << 8) | (cast(u32)(x[3]));}
		fmt.sbprintf(*sb, " [chosen_version %08x other_versions", be(sub(vi, 0, 4)));
		{ i := 4;
		while i + 4 <= len(vi) {
			v := be(sub(vi, i, i + 4));
			if (v & 0x0f0f0f0f) == 0x0a0a0a0a { { i += 4; continue; } } // GREASE
			fmt.sbprintf(*sb, " %08x", v);
			i += 4;
} }
		strings.write_byte(*sb, #char "]");
	} }
	for k: ORDER {
		v, ok := map_find(vals, k.id);
		if !ok { continue; }
		fmt.sbprintf(*sb, " %s", k.name);
		if k.kind == #char "i" {
			p := 0;
			n, _ := get_varint(v, *p);
			fmt.sbprintf(*sb, " %d", n);
		} else if k.kind == #char "c" {
			if len(v) == 0 {
				strings.write_string(*sb, " 0");
			} else {
				strings.write_byte(*sb, #char " ");
				for x: v { fmt.sbprintf(*sb, "%02x", x); }
			}
		}
	}
	strings.write_byte(*sb, #char "]");
	return strings.to_string(sb);
}

