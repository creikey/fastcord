package discord

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "fc:http"
import "fc:quic/h3"

// Netlog side file for the recorder: the same event shapes Chrome's
// --log-net-log writes, so tools/scrub's netlog reader gives our recordings
// `wire` (true send order) and `conn` lines like the official fixtures.
//   - request headers: rebuilt with the same field order fc:http (h2),
//     fc:quic/h3 and h1_serialize_request put on the wire
//   - h3 transport parameters: decoded from the bytes the session's
//     ClientHello carried (Conn_Event.quic_params)
//   - h3 SETTINGS: h3.control_preamble (what connect writes; GREASE differs)
//   - h2 SETTINGS / WINDOW_UPDATE: the values h2_connect sent
// Cookie and authorization values are stripped like Chrome does.

NETLOG_TYPES := [?]string {
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
	"SSL_CONNECT",
}

@(private = "file")
nl_type :: proc(name: string) -> int {
	for n, i in NETLOG_TYPES do if n == name do return i + 1
	return 0
}

// nl_file opens the account's netlog on first use (caller holds r.mu).
@(private = "file")
nl_file :: proc(r: ^Recorder, acct: string) -> ^os.File {
	i := 1 if acct == "b" else 0
	if r.nl[i] != nil || r.nl_path == "" do return r.nl[i]
	f, err := os.create(fmt.tprintf("%s.netlog-%s", r.nl_path, "b" if i == 1 else "a"))
	if err != nil do return nil
	r.nl[i] = f
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, `{"constants":{"logEventTypes":{`)
	for name, k in NETLOG_TYPES {
		if k > 0 do strings.write_byte(&sb, ',')
		fmt.sbprintf(&sb, `"%s":%d`, name, k + 1)
	}
	strings.write_string(&sb, "},\"timeTickOffset\":0},\n\"events\": [\n")
	os.write_string(f, strings.to_string(sb))
	return f
}

netlog_close :: proc(r: ^Recorder) {
	for &f in r.nl {
		if f == nil do continue
		os.write_string(f, "{}]}\n")
		os.close(f)
		f = nil
	}
	for k in r.sessions do delete(k)
	delete(r.sessions)
	delete(r.nl_path)
}

// nl_event writes one event; caller holds r.mu. params is a JSON object.
@(private = "file")
nl_event :: proc(f: ^os.File, name: string, src, phase: int, at_ms: i64, params: string) {
	if f == nil do return
	line := fmt.tprintf(`{{"params":%s,"phase":%d,"source":{{"id":%d,"type":0}},"time":"%d","type":%d}},`+"\n", params, phase, src, at_ms, nl_type(name))
	os.write_string(f, line)
}

@(private = "file")
nl_source :: proc(r: ^Recorder) -> int {
	r.nl_next += 1
	return r.nl_next
}

// nl_session returns the source id of the latest session for key (caller holds r.mu).
@(private = "file")
nl_session :: proc(r: ^Recorder, key: string) -> int {
	if id, ok := r.sessions[key]; ok do return id
	id := nl_source(r)
	r.sessions[strings.clone(key)] = id
	return id
}

@(private)
rec_conn :: proc(data: rawptr, ev: Conn_Event) {
	tap := cast(^Recorder_Tap)data
	r := tap.r
	sync.mutex_lock(&r.mu)
	defer sync.mutex_unlock(&r.mu)
	f := nl_file(r, tap.acct)
	if f == nil do return
	at := now_ms()
	key := fmt.tprintf("%s %s %s", tap.acct, ev.kind, ev.host)
	id := nl_source(r)
	if key in r.sessions {
		r.sessions[key] = id
	} else {
		r.sessions[strings.clone(key)] = id
	}
	sb := strings.builder_make(context.temp_allocator)
	switch ev.kind {
	case "h3":
		strings.write_string(&sb, `{"host":`)
		json_write_escaped(&sb, ev.host)
		strings.write_string(&sb, `,"port":443,"versions":"RFCv1"}`)
		nl_event(f, "QUIC_SESSION", id, 1, at, strings.to_string(sb))
		strings.builder_reset(&sb)
		strings.write_string(&sb, `{"quic_transport_parameters":`)
		json_write_escaped(&sb, quic_params_text(ev.quic_params, "Client"))
		strings.write_string(&sb, "}")
		nl_event(f, "QUIC_SESSION_TRANSPORT_PARAMETERS_SENT", id, 0, at, strings.to_string(sb))
		nl_event(f, "HTTP3_SETTINGS_SENT", id, 0, at, h3_settings_json())
	case "h2":
		sock := nl_source(r)
		strings.write_string(&sb, `{"next_proto":`)
		json_write_escaped(&sb, ev.alpn)
		strings.write_string(&sb, `,"version":"TLS 1.3"}`)
		nl_event(f, "SSL_CONNECT", sock, 2, at, strings.to_string(sb))
		strings.builder_reset(&sb)
		fmt.sbprintf(&sb, `{{"host":"%s:443","proxy":"DIRECT"}}`, ev.host)
		nl_event(f, "HTTP2_SESSION", id, 1, at, strings.to_string(sb))
		nl_event(f, "HTTP2_SESSION_INITIALIZED", id, 0, at, fmt.tprintf(`{{"protocol":"%s","source_dependency":{{"id":%d,"type":0}}}}`, ev.alpn, sock))
		strings.builder_reset(&sb)
		strings.write_string(&sb, `{"settings":[`)
		for s, i in ev.h2_settings {
			if i > 0 do strings.write_byte(&sb, ',')
			fmt.sbprintf(&sb, `"[id:%d (%s) value:%d]"`, s.id, h2_setting_name(s.id), s.value)
		}
		strings.write_string(&sb, "]}")
		nl_event(f, "HTTP2_SESSION_SEND_SETTINGS", id, 0, at, strings.to_string(sb))
		if ev.h2_window_increment > 0 {
			nl_event(f, "HTTP2_SESSION_SEND_WINDOW_UPDATE", id, 0, at, fmt.tprintf(`{{"delta":%d,"stream_id":0}}`, ev.h2_window_increment))
		}
	}
}

// nl_request_headers writes the request's header block in send order.
nl_request_headers :: proc(r: ^Recorder, acct, host: string, req: http.Request, version: http.Version, at_ms: i64) {
	sync.mutex_lock(&r.mu)
	defer sync.mutex_unlock(&r.mu)
	f := nl_file(r, acct)
	if f == nil do return
	fields := make([dynamic]http.Header, 0, len(req.headers) + 5, context.temp_allocator)
	scheme := req.scheme if req.scheme != "" else "https"
	authority := req.authority if req.authority != "" else host
	name := "HTTP_TRANSACTION_SEND_REQUEST_HEADERS"
	src := 0
	switch version {
	case .Http3:
		// fc:quic/h3 open: pseudo-headers, the request's fields, then priority
		// unless the request carries one
		name = "HTTP3_HEADERS_SENT"
		src = nl_session(r, fmt.tprintf("%s h3 %s", acct, host))
		append(&fields, http.Header{":method", req.method}, http.Header{":authority", authority}, http.Header{":scheme", scheme}, http.Header{":path", req.path})
		has := false
		for h in req.headers {
			if h.name == "priority" do has = true
			append(&fields, h)
		}
		if !has do append(&fields, http.Header{"priority", fmt.tprintf("u=%d, i", h3.urgency(req.priority))})
	case .Http2:
		name = "HTTP2_SESSION_SEND_HEADERS"
		src = nl_session(r, fmt.tprintf("%s h2 %s", acct, host))
		append(&fields, http.Header{":method", req.method}, http.Header{":authority", authority}, http.Header{":scheme", req.scheme}, http.Header{":path", req.path})
		append(&fields, ..req.headers)
	case .Http1_1, .Http1_0:
		src = nl_source(r)
		// h1_serialize_request: Host first unless the caller placed one
		has_host := false
		for h in req.headers do if strings.equal_fold(h.name, "host") do has_host = true
		if !has_host do append(&fields, http.Header{"Host", authority})
		append(&fields, ..req.headers)
	}
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, `{"headers":[`)
	for h, i in fields {
		if i > 0 do strings.write_byte(&sb, ',')
		v := h.value
		lname := strings.to_lower(h.name, context.temp_allocator)
		if lname == "cookie" || lname == "authorization" do v = fmt.tprintf("[%d bytes were stripped]", len(h.value))
		json_write_escaped(&sb, fmt.tprintf("%s: %s", h.name, v))
	}
	strings.write_string(&sb, "]")
	if version == .Http1_1 || version == .Http1_0 {
		strings.write_string(&sb, `,"line":`)
		json_write_escaped(&sb, fmt.tprintf("%s %s HTTP/1.1\r\n", req.method, req.path))
	}
	strings.write_string(&sb, "}")
	nl_event(f, name, src, 0, at_ms, strings.to_string(sb))
}

@(private = "file")
h2_setting_name :: proc(id: u16) -> string {
	switch id {
	case 1:
		return "SETTINGS_HEADER_TABLE_SIZE"
	case 2:
		return "SETTINGS_ENABLE_PUSH"
	case 3:
		return "SETTINGS_MAX_CONCURRENT_STREAMS"
	case 4:
		return "SETTINGS_INITIAL_WINDOW_SIZE"
	case 5:
		return "SETTINGS_MAX_FRAME_SIZE"
	case 6:
		return "SETTINGS_MAX_HEADER_LIST_SIZE"
	case 8:
		return "SETTINGS_ENABLE_CONNECT_PROTOCOL"
	case 9:
		return "SETTINGS_NO_RFC7540_PRIORITIES"
	}
	return "SETTINGS_UNKNOWN"
}

@(private = "file")
get_varint :: proc(b: []byte, pos: ^int) -> (v: u64, ok: bool) {
	if pos^ >= len(b) do return 0, false
	n := 1 << (b[pos^] >> 6)
	if pos^ + n > len(b) do return 0, false
	v = u64(b[pos^] & 0x3f)
	for i in 1 ..< n do v = v << 8 | u64(b[pos^ + i])
	pos^ += n
	return v, true
}

// h3_settings_json: our control stream SETTINGS as Chrome logs them
// (names sorted, as Chrome's dictionary prints).
h3_settings_json :: proc() -> string {
	pre := make([dynamic]byte, 0, 64, context.temp_allocator)
	h3.control_preamble(&pre)
	b := pre[:]
	pos := 0
	_, _ = get_varint(b, &pos) // stream type
	_, _ = get_varint(b, &pos) // frame type (SETTINGS)
	n, _ := get_varint(b, &pos)
	end := min(pos + int(n), len(b))
	pairs := make([dynamic][2]string, 0, 8, context.temp_allocator)
	for pos < end {
		id, ok1 := get_varint(b[:end], &pos)
		v, ok2 := get_varint(b[:end], &pos)
		if !ok1 || !ok2 do break
		nm: string
		switch id {
		case 0x01:
			nm = "SETTINGS_QPACK_MAX_TABLE_CAPACITY"
		case 0x06:
			nm = "SETTINGS_MAX_FIELD_SECTION_SIZE"
		case 0x07:
			nm = "SETTINGS_QPACK_BLOCKED_STREAMS"
		case 0x33:
			nm = "SETTINGS_H3_DATAGRAM"
		case:
			nm = fmt.tprintf("UNSUPPORTED_SETTINGS_TYPE(%d)", id)
		}
		append(&pairs, [2]string{nm, fmt.tprintf("%d", i64(i32(u32(v))))})
	}
	slice.sort_by(pairs[:], proc(a, c: [2]string) -> bool {return a[0] < c[0]})
	sb := strings.builder_make(context.temp_allocator)
	strings.write_byte(&sb, '{')
	for p, i in pairs {
		if i > 0 do strings.write_byte(&sb, ',')
		fmt.sbprintf(&sb, `"%s":%s`, p[0], p[1])
	}
	strings.write_byte(&sb, '}')
	return strings.to_string(sb)
}

// quic_params_text formats encoded transport parameters the way QUICHE's
// TransportParameters::ToString does (canonical order; GREASE parameters and
// GREASE versions are added at serialization, so they are not listed).
quic_params_text :: proc(b: []byte, perspective: string) -> string {
	Known :: struct {
		id:   u64,
		name: string,
		kind: u8, // 'i' int, 'c' connection id, 'f' flag
	}
	ORDER := [?]Known {
		{0x00, "original_destination_connection_id", 'c'},
		{0x01, "max_idle_timeout", 'i'},
		{0x02, "stateless_reset_token", 'c'},
		{0x03, "max_udp_payload_size", 'i'},
		{0x04, "initial_max_data", 'i'},
		{0x05, "initial_max_stream_data_bidi_local", 'i'},
		{0x06, "initial_max_stream_data_bidi_remote", 'i'},
		{0x07, "initial_max_stream_data_uni", 'i'},
		{0x08, "initial_max_streams_bidi", 'i'},
		{0x09, "initial_max_streams_uni", 'i'},
		{0x0a, "ack_delay_exponent", 'i'},
		{0x0b, "max_ack_delay", 'i'},
		{0x0c, "disable_active_migration", 'f'},
		{0x0e, "active_connection_id_limit", 'i'},
		{0x0f, "initial_source_connection_id", 'c'},
		{0x10, "retry_source_connection_id", 'c'},
		{0x20, "max_datagram_frame_size", 'i'},
		{0x3127, "initial_round_trip_time", 'i'},
	}
	vals := make(map[u64][]byte, 16, context.temp_allocator)
	pos := 0
	for pos < len(b) {
		id, ok1 := get_varint(b, &pos)
		l, ok2 := get_varint(b, &pos)
		if !ok1 || !ok2 || pos + int(l) > len(b) do break
		vals[id] = b[pos:pos + int(l)]
		pos += int(l)
	}
	sb := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&sb, "[%s", perspective)
	if vi, ok := vals[0x11]; ok && len(vi) >= 4 {
		be :: proc(x: []byte) -> u32 {return u32(x[0]) << 24 | u32(x[1]) << 16 | u32(x[2]) << 8 | u32(x[3])}
		fmt.sbprintf(&sb, " [chosen_version %08x other_versions", be(vi[:4]))
		for i := 4; i + 4 <= len(vi); i += 4 {
			v := be(vi[i:i + 4])
			if v & 0x0f0f0f0f == 0x0a0a0a0a do continue // GREASE
			fmt.sbprintf(&sb, " %08x", v)
		}
		strings.write_byte(&sb, ']')
	}
	for k in ORDER {
		v, ok := vals[k.id]
		if !ok do continue
		fmt.sbprintf(&sb, " %s", k.name)
		switch k.kind {
		case 'i':
			p := 0
			n, _ := get_varint(v, &p)
			fmt.sbprintf(&sb, " %d", n)
		case 'c':
			if len(v) == 0 {
				strings.write_string(&sb, " 0")
			} else {
				strings.write_byte(&sb, ' ')
				for x in v do fmt.sbprintf(&sb, "%02x", x)
			}
		}
	}
	strings.write_byte(&sb, ']')
	return strings.to_string(sb)
}
