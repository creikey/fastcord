// Netlog side file for the recorder: the same event shapes Chrome's
// --log-net-log writes, so tools/scrub's netlog reader gives our recordings
// `wire` (true send order) and `conn` lines like the official fixtures.
//   - request headers: rebuilt with the same field order http (h2),
//     quic and h1_serialize_request put on the wire
//   - h3 transport parameters: decoded from the bytes the session's
//     ClientHello carried (Conn_Event.quic_params)
//   - h3 SETTINGS: quic.H3_SETTINGS plus a GREASE setting (what the patched nghttp3 writes)
//   - h2 SETTINGS / WINDOW_UPDATE: the values h2_connect sent
// Cookie and authorization values are stripped like Chrome does.

NETLOG_TYPES :: string.[
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

nl_type :: (name: string) -> int {
	_, i := array_find(NETLOG_TYPES, name);
	return i + 1;
}

// nl_file opens the account's netlog on first use (caller holds r.mu); null when closed.
nl_file :: (r: *Recorder, acct: string) -> *File {
	i := ifx acct == "b" then 1 else 0;
	if r.closed return null;
	if r.nl_open[i] return *r.nl[i];
	if !r.nl_path return null;
	f, ok := file_open(tprint("%.netlog-%", r.nl_path, ifx i == 1 then "b" else "a"), for_writing = true);
	if !ok return null;
	r.nl[i] = f;
	r.nl_open[i] = true;
	b := temp_buffer();
	append_string(*b, "{\"constants\":{\"logEventTypes\":{");
	for NETLOG_TYPES {
		if it_index > 0 array_add(*b, #char ",");
		append_string(*b, tprint("\"%\":%", it, it_index + 1));
	}
	append_string(*b, "},\"timeTickOffset\":0},\n\"events\": [\n");
	file_write(*r.nl[i], cast(string) b);
	return *r.nl[i];
}

// netlog_close ends both side files and forgets the sessions (caller holds r.mu).
netlog_close :: (r: *Recorder) {
	for * r.nl {
		if !r.nl_open[it_index] continue;
		file_write(it, "{}]}\n");
		file_close(it);
		r.nl_open[it_index] = false;
	}
	for r.sessions free(it_index,, context.default_allocator);
	deinit(*r.sessions);
}

// nl_event writes one event; caller holds r.mu. params is a JSON object.
nl_event :: (f: *File, name: string, src: int, phase: int, at_ms: s64, params: string) {
	if f file_write(f, tprint("{\"params\":%,\"phase\":%,\"source\":{\"id\":%,\"type\":0},\"time\":\"%\",\"type\":%},\n", params, phase, src, at_ms, nl_type(name)));
}

nl_source :: (r: *Recorder) -> int {
	r.nl_next += 1;
	return r.nl_next;
}

// nl_set_session: key's latest session is id (caller holds r.mu).
nl_set_session :: (r: *Recorder, key: string, id: int) {
	p := table_find_pointer(*r.sessions, key);
	if p p.* = id;
	else table_add(*r.sessions, copy_string(key,, context.default_allocator), id);
}

// nl_session returns the source id of the latest session for key (caller holds r.mu).
nl_session :: (r: *Recorder, key: string) -> int {
	ok, id := table_find(*r.sessions, key);
	if ok return id;
	id = nl_source(r);
	nl_set_session(r, key, id);
	return id;
}

rec_conn :: (data: *void, ev: Conn_Event) {
	tap := cast(*Recorder_Tap) data;
	r := tap.r;
	locks.lock(*r.mu);
	defer locks.unlock(*r.mu);
	f := nl_file(r, tap.acct);
	if !f return;
	at_ms := now_ms();
	id := nl_source(r);
	nl_set_session(r, tprint("% % %", tap.acct, ev.kind, ev.host), id);
	b := temp_buffer();
	if ev.kind == {
		case "h3";
			append_string(*b, "{\"host\":");
			json_write_escaped(*b, ev.host);
			append_string(*b, ",\"port\":443,\"versions\":\"RFCv1\"}");
			nl_event(f, "QUIC_SESSION", id, 1, at_ms, cast(string) b);
			b.count = 0;
			append_string(*b, "{\"quic_transport_parameters\":");
			json_write_escaped(*b, quic_params_text(ev.quic_params, "Client"));
			append_string(*b, "}");
			nl_event(f, "QUIC_SESSION_TRANSPORT_PARAMETERS_SENT", id, 0, at_ms, cast(string) b);
			nl_event(f, "HTTP3_SETTINGS_SENT", id, 0, at_ms, h3_settings_json());
		case "h2";
			sock := nl_source(r);
			append_string(*b, "{\"next_proto\":");
			json_write_escaped(*b, ev.alpn);
			append_string(*b, ",\"version\":\"TLS 1.3\"}");
			nl_event(f, "SSL_CONNECT", sock, 2, at_ms, cast(string) b);
			nl_event(f, "HTTP2_SESSION", id, 1, at_ms, tprint("{\"host\":\"%:443\",\"proxy\":\"DIRECT\"}", ev.host));
			nl_event(f, "HTTP2_SESSION_INITIALIZED", id, 0, at_ms, tprint("{\"protocol\":\"%\",\"source_dependency\":{\"id\":%,\"type\":0}}", ev.alpn, sock));
			b.count = 0;
			append_string(*b, "{\"settings\":[");
			for ev.h2_settings {
				if it_index > 0 array_add(*b, #char ",");
				append_string(*b, tprint("\"[id:% (%) value:%]\"", it.id, h2_setting_name(cast(u16) it.id), it.value));
			}
			append_string(*b, "]}");
			nl_event(f, "HTTP2_SESSION_SEND_SETTINGS", id, 0, at_ms, cast(string) b);
			if ev.h2_window_increment > 0 {
				nl_event(f, "HTTP2_SESSION_SEND_WINDOW_UPDATE", id, 0, at_ms, tprint("{\"delta\":%,\"stream_id\":0}", ev.h2_window_increment));
			}
	}
}

// nl_request_headers writes the request's header block in send order.
nl_request_headers :: (r: *Recorder, acct: string, host: string, req: http.Request, version: http.Version, at_ms: s64) {
	locks.lock(*r.mu);
	defer locks.unlock(*r.mu);
	f := nl_file(r, acct);
	if !f return;
	fields: [..]http.Header;
	fields.allocator = temp;
	scheme := ifx req.scheme then req.scheme else "https";
	authority := ifx req.authority then req.authority else host;
	name := "HTTP_TRANSACTION_SEND_REQUEST_HEADERS";
	src := 0;
	if version == {
		case .Http3;
			// quic.request: pseudo-headers, the request's fields, then priority
			// unless the request carries one
			name = "HTTP3_HEADERS_SENT";
			src = nl_session(r, tprint("% h3 %", acct, host));
			array_add(*fields, .{":method", req.method}, .{":authority", authority}, .{":scheme", scheme}, .{":path", req.path});
			array_add(*fields, ..req.headers);
			_, has_priority := hval(req.headers, "priority");
			if !has_priority array_add(*fields, .{"priority", tprint("u=%, i", quic.urgency(req.priority))});
		case .Http2;
			name = "HTTP2_SESSION_SEND_HEADERS";
			src = nl_session(r, tprint("% h2 %", acct, host));
			array_add(*fields, .{":method", req.method}, .{":authority", authority}, .{":scheme", req.scheme}, .{":path", req.path});
			array_add(*fields, ..req.headers);
		case .Http1_1; #through;
		case .Http1_0;
			src = nl_source(r);
			// h1_serialize_request: Host first unless the caller placed one
			has_host := false;
			for req.headers if equal_nocase(it.name, "host") has_host = true;
			if !has_host array_add(*fields, .{"Host", authority});
			array_add(*fields, ..req.headers);
	}
	b := temp_buffer();
	append_string(*b, "{\"headers\":[");
	for fields {
		if it_index > 0 array_add(*b, #char ",");
		v := it.value;
		if equal_nocase(it.name, "cookie") || equal_nocase(it.name, "authorization") v = tprint("[% bytes were stripped]", it.value.count);
		json_write_escaped(*b, tprint("%: %", it.name, v));
	}
	array_add(*b, #char "]");
	if version == .Http1_1 || version == .Http1_0 {
		append_string(*b, ",\"line\":");
		json_write_escaped(*b, tprint("% % HTTP/1.1\r\n", req.method, req.path));
	}
	array_add(*b, #char "}");
	nl_event(f, name, src, 0, at_ms, cast(string) b);
}

h2_setting_name :: (id: u16) -> string {
	if id == {
		case 1; return "SETTINGS_HEADER_TABLE_SIZE";
		case 2; return "SETTINGS_ENABLE_PUSH";
		case 3; return "SETTINGS_MAX_CONCURRENT_STREAMS";
		case 4; return "SETTINGS_INITIAL_WINDOW_SIZE";
		case 5; return "SETTINGS_MAX_FRAME_SIZE";
		case 6; return "SETTINGS_MAX_HEADER_LIST_SIZE";
		case 8; return "SETTINGS_ENABLE_CONNECT_PROTOCOL";
		case 9; return "SETTINGS_NO_RFC7540_PRIORITIES";
	}
	return "SETTINGS_UNKNOWN";
}

// get_varint reads one QUIC variable-length integer at pos.
get_varint :: (b: []u8, pos: *int) -> u64, bool {
	if pos.* >= b.count return 0, false;
	n := 1 << (b[pos.*] >> 6);
	if pos.* + n > b.count return 0, false;
	v := cast(u64) (b[pos.*] & 0x3f);
	for i: 1..n - 1 v = (v << 8) | b[pos.* + i];
	pos.* += n;
	return v, true;
}

// h3_settings_json: our control stream SETTINGS as Chrome logs them
// (names sorted, as Chrome's dictionary prints).
h3_settings_json :: () -> string {
	Pair :: struct { name: string; value: u64; }
	pairs: [..]Pair;
	pairs.allocator = temp;
	for s: quic.H3_SETTINGS {
		nm: string;
		if s[0] == {
			case 0x01; nm = "SETTINGS_QPACK_MAX_TABLE_CAPACITY";
			case 0x06; nm = "SETTINGS_MAX_FIELD_SECTION_SIZE";
			case 0x07; nm = "SETTINGS_QPACK_BLOCKED_STREAMS";
			case 0x33; nm = "SETTINGS_H3_DATAGRAM";
		}
		array_add(*pairs, .{nm, xx s[1]});
	}
	// The patched nghttp3's GREASE setting: its id and value are random (tools/trafficdiff folds them).
	array_add(*pairs, .{"UNSUPPORTED_SETTINGS_TYPE(33)", 0});
	quick_sort(pairs, (a: Pair, b: Pair) -> int { return compare(a.name, b.name); });
	b := temp_buffer();
	array_add(*b, #char "{");
	for pairs {
		if it_index > 0 array_add(*b, #char ",");
		append_string(*b, tprint("\"%\":%", it.name, it.value));
	}
	array_add(*b, #char "}");
	return cast(string) b;
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
	ORDER :: Known.[
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
	vals: Table(u64, []u8);
	vals.allocator = temp;
	pos := 0;
	while pos < b.count {
		id, ok1 := get_varint(b, *pos);
		l, ok2 := get_varint(b, *pos);
		if !ok1 || !ok2 || pos + cast(int) l > b.count break;
		table_set(*vals, id, array_view(b, pos, xx l));
		pos += cast(int) l;
	}
	hex8 :: (x: []u8) -> string { return tprint("%", formatInt(be32(x, 0), base = 16, minimum_digits = 8)); }
	out := temp_buffer();
	append_string(*out, tprint("[%", perspective));
	ok, vi := table_find(*vals, 0x11);
	if ok && vi.count >= 4 {
		append_string(*out, tprint(" [chosen_version % other_versions", hex8(vi)));
		for i: 1..vi.count / 4 - 1 {
			v := be32(vi, i * 4);
			if (v & 0x0f0f0f0f) == 0x0a0a0a0a continue; // GREASE
			append_string(*out, tprint(" %", hex8(array_view(vi, i * 4, 4))));
		}
		array_add(*out, #char "]");
	}
	for k: ORDER {
		found, v := table_find(*vals, k.id);
		if !found continue;
		append_string(*out, tprint(" %", k.name));
		if k.kind == #char "i" {
			p := 0;
			n := get_varint(v, *p);
			append_string(*out, tprint(" %", n));
		} else if k.kind == #char "c" {
			if !v append_string(*out, " 0");
			else {
				array_add(*out, #char " ");
				for v append_string(*out, tprint("%", formatInt(it, base = 16, minimum_digits = 2)));
			}
		}
	}
	array_add(*out, #char "]");
	return cast(string) out;
}
