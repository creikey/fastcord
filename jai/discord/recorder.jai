// Recorder: writes our client's traffic in the raw capture format that
// tools/capture produces for the official client (CDP-shaped lines), so the
// same tools/scrub turns it into a fixture and tools/trafficdiff compares it:
//   {"rt":ms,"acct":"a","m":{"method":"Network.requestWillBeSent","params":{...}}}
//   {"rt":ms,"acct":"a","body_for":"<rid>","s":"ours","m":{"result":{"body":..,"base64Encoded":..}}}
//   {"rt":ms,"acct":"a","gw":{"dir":"send"|"recv","ws":"<rid>","len":n},"etf":<decoded>}
//   {"rt":ms,"acct":"a","mark":"<name>"}
// Raw output contains secrets: write it under .secrets/raw only.
//
// `request.headers` reproduces what DevTools reports for Chrome's renderer-side
// header list (JS-set headers + client hints + Referer/User-Agent, in Blink's
// order, JS casing); the ExtraInfo `headers` carry our real wire list.

Recorder :: struct {
	mu: locks.Mutex;
	f: *os.File;
	start: s64;
	next_id: int;
	ws_id: string;
	last_net: s64; // ms of the last recorded network event (settle)
	closed: bool; // retired (session runner): late callbacks write nothing
	// Chrome-netlog-shaped side files (<path>.netlog-a / -b) carrying the true
	// wire header order and session setup facts; tools/scrub -netlog-a:/-b: read them.
	nl_path: string;
	nl: [2]*os.File;
	nl_next: int;
	sessions: Map(string, int); // "h2 host" / "h3 host" -> netlog source id
}

Recorder_Tap :: struct {
	r: *Recorder;
	acct: string;
}

recorder_open :: (path: string) -> *Recorder, bool {
	f, err := os.create(path);
	if err != null { return null, false; }
	r := new(Recorder);
	r.f = f;
	r.start = now_ms();
	r.nl_path = clone(path);
	return r, true;
}

recorder_close :: (r: *Recorder) {
	os.close(r.f);
	netlog_close(r);
	free(r);
}

// recorder_retire closes the files but keeps r valid: a live client may still
// deliver callbacks from requests started before it was re-attached elsewhere.
recorder_retire :: (r: *Recorder) {
	locks.lock(*r.mu);
	defer locks.unlock(*r.mu);
	r.closed = true;
	os.close(r.f);
	netlog_close(r);
}
#scope_module

rec_line :: (r: *Recorder, acct: string, rest: string) {
	locks.lock(*r.mu);
	defer locks.unlock(*r.mu);
	n := now_ms();
	line := fmt.tprintf("{{\"rt\":%.1f,\"acct\":\"%s\",%s}}\n", cast(float64)(n - r.start), acct, rest);
	if !r.closed { os.write_string(r.f, line); }
	if !strings.has_prefix(rest, "\"mark\"") { r.last_net = n; }
}
#scope_export

recorder_last_net :: (r: *Recorder) -> s64 {
	locks.lock(*r.mu);
	defer locks.unlock(*r.mu);
	return r.last_net;
}
#scope_module

rec_line_at :: (r: *Recorder, acct: string, at_ms: float64, rest: string) {
	locks.lock(*r.mu);
	defer locks.unlock(*r.mu);
	line := fmt.tprintf("{{\"rt\":%.3f,\"acct\":\"%s\",%s}}\n", at_ms - cast(float64)(r.start), acct, rest);
	if !r.closed { os.write_string(r.f, line); }
	r.last_net = max(r.last_net, now_ms());
}
#scope_export

recorder_mark :: (r: *Recorder, acct: string, name: string) {
	sb := strings.builder_make(temp);
	strings.write_string(*sb, "\"mark\":");
	json_write_escaped(*sb, name);
	rec_line(r, acct, strings.to_string(sb));
}
#scope_module

rec_next_id :: (r: *Recorder) -> string {
	locks.lock(*r.mu);
	defer locks.unlock(*r.mu);
	r.next_id += 1;
	return fmt.tprintf("ours.%d", r.next_id);
}
#scope_export

// recorder_attach installs the hooks on a client (before client_start).
recorder_attach :: (r: *Recorder, c: *Client, acct: string) {
	tap := new(Recorder_Tap);
	tap.* = .{r, clone(acct)};
	c.observer_data = tap;
	c.transport.observer_data = tap;
	c.transport.observer = rec_http;
	c.on_gateway_frame = rec_gw;
	c.transport.conn_observer = rec_conn;
	c.on_ws_open = rec_ws_open;
	c.on_ws_close = rec_ws_close;
}
#scope_module

// ---- renderer-view header list (what DevTools shows in requestWillBeSent) ----

js_case :: (n: string) -> string {
	if n == {
	case "authorization";
		return "Authorization";
	case "x-installation-id";
		return "X-Installation-ID";
	case "x-debug-options";
		return "X-Debug-Options";
	case "accept-language";
		return "Accept-Language";
	case "x-discord-timezone";
		return "X-Discord-Timezone";
	case "x-context-properties";
		return "X-Context-Properties";
	case "x-super-properties";
		return "X-Super-Properties";
	case "x-discord-locale";
		return "X-Discord-Locale";
	case "content-type";
		return "Content-Type";
	case "if-none-match";
		return "If-None-Match";
	case "cache-control";
		return "Cache-Control";
	case "x-failed-requests";
		return "X-Failed-Requests";
	case "referer";
		return "Referer";
	case "user-agent";
		return "User-Agent";
	case "accept";
		return "Accept";
	case "access-control-request-headers";
		return "Access-Control-Request-Headers";
	case "access-control-request-method";
		return "Access-Control-Request-Method";
	case "origin";
		return "Origin";
	case "sec-fetch-mode";
		return "Sec-Fetch-Mode";
	}
	return n;
}

hval :: (h: []http.Header, name: string) -> string, bool {
	for x: h { if x.name == name { return x.value, true; } }
	return "", false;
}
#scope_export

// renderer_view derives DevTools' request header object from our wire list.
renderer_view :: (method: string, wire: []http.Header, kind: string) -> []http.Header {
	out := make_dynamic(http.Header, 0, len(wire), temp);
	add :: (out: *[..]http.Header, wire: []http.Header, name: string) {
		{ v, ok := hval(wire, name);
		if ok { append(out, http.Header.{js_case(name), v}); } }
	}
	if method == "OPTIONS" {
		for n: (string.["accept", "access-control-request-headers", "access-control-request-method", "origin", "sec-fetch-mode", "user-agent"]) { add(*out, wire, n); }
		return view(out);
	}
	standard := string.["content-length", "sec-ch-ua-platform", "authorization", "x-installation-id", "x-debug-options", "accept-language", "sec-ch-ua", "sec-ch-ua-mobile", "x-discord-timezone", "x-context-properties", "x-super-properties", "x-discord-locale", "user-agent", "content-type", "accept", "origin", "sec-fetch-site", "sec-fetch-mode", "sec-fetch-dest", "sec-fetch-storage-access", "referer", "accept-encoding", "cookie", "priority", "if-modified-since", "cache-control"];
	is_std :: (standard: []string, n: string) -> bool {
		for s: standard { if s == n { return true; } }
		return false;
	}
	extras := make_dynamic(string, 0, 0, temp);
	for h: wire {
		if !is_std(standard, h.name) { append(*extras, h.name); }
	}
	_, authed := hval(wire, "authorization");
	if authed {
		for e: extras { add(*out, wire, e); }
		if len(extras) > 0 {
			for n: (string.["authorization", "x-installation-id", "sec-ch-ua-platform", "x-debug-options", "accept-language", "sec-ch-ua", "referer", "sec-ch-ua-mobile", "x-discord-timezone", "x-context-properties", "x-super-properties", "x-discord-locale", "user-agent", "content-type"]) { add(*out, wire, n); }
		} else {
			for n: (string.["sec-ch-ua-platform", "authorization", "x-installation-id", "referer", "x-debug-options", "accept-language", "sec-ch-ua", "sec-ch-ua-mobile", "x-discord-timezone", "x-context-properties", "x-super-properties", "x-discord-locale", "user-agent", "content-type"]) { add(*out, wire, n); }
		}
		return view(out);
	}
	// unauthenticated XHR / fetch / image. A JS-set If-None-Match comes before
	// the client hints; one appended by the HTTP cache (at the end) is not renderer-visible.
	inm_js := false;
	for h: wire {
		if h.name == "sec-ch-ua-platform" { break; }
		if h.name == "if-none-match" { inm_js = true; }
	}
	{ v, ok := hval(wire, "if-none-match");
	if ok && inm_js && kind != "Image" { append(*out, http.Header.{"If-None-Match", v}); } }
	for e: extras { if e != "if-none-match" { add(*out, wire, e); } }
	for n: (string.["sec-ch-ua-platform", "referer", "user-agent", "sec-ch-ua", "content-type", "sec-ch-ua-mobile"]) { add(*out, wire, n); }
	return view(out);
}
#scope_module

headers_object :: (sb: *strings.Builder, h: []http.Header) {
	strings.write_byte(sb, #char "{");
	for x, i: h {
		if i > 0 { strings.write_byte(sb, #char ","); }
		json_write_escaped(sb, x.name);
		strings.write_byte(sb, #char ":");
		json_write_escaped(sb, x.value);
	}
	strings.write_byte(sb, #char "}");
}

request_kind :: (req: http.Request) -> string {
	if req.method == "OPTIONS" { return "Other"; }
	{ v, ok := hval(req.headers, "sec-fetch-dest");
	if ok {
		if v == {
		case "image";
			return "Image";
		case "font";
			return "Font";
		}
	} }
	if strings.contains(req.path, "/bad-domains/") { return "Fetch"; }
	return "XHR";
}

proto_name :: (v: http.Version) -> string {
	if v == {
	case .Http3;
		return "h3";
	case .Http2;
		return "h2";
	case .Http1_1; #through; case .Http1_0;
		return "http/1.1";
	}
	return "";
}

rec_http :: (data: *void, host: string, req: http.Request, resp: *http.Response, err: http.Error, start_ms: float64) {
	tap := cast(*Recorder_Tap)data;
	r := tap.r;
	rid := rec_next_id(r);
	url := strings.concatenate(string.["https://", host, req.path], temp);
	kind := request_kind(req);
	// requestWillBeSent
	sb := strings.builder_make(temp);
	fmt.sbprintf(*sb, "\"m\":{{\"method\":\"Network.requestWillBeSent\",\"params\":{{\"requestId\":\"%s\",\"type\":\"%s\",\"wallTime\":%.6f,\"request\":{{\"url\":", rid, kind, start_ms / 1000);
	json_write_escaped(*sb, url);
	strings.write_string(*sb, ",\"method\":");
	json_write_escaped(*sb, req.method);
	strings.write_string(*sb, ",\"headers\":");
	rv := renderer_view(req.method, req.headers, kind);
	if context.tl_js_lower_auth { for * h: rv { if h.name == "Authorization" { h.name = "authorization"; } } }
	headers_object(*sb, rv);
	if len(req.body) > 0 {
		strings.write_string(*sb, ",\"hasPostData\":true,\"postData\":");
		json_write_escaped(*sb, as_string(req.body));
	}
	strings.write_string(*sb, "}}}");
	rec_line_at(r, tap.acct, start_ms, strings.to_string(sb));
	// ExtraInfo: the real wire list (pseudo-headers first, as DevTools shows them)
	sb2 := strings.builder_make(temp);
	fmt.sbprintf(*sb2, "\"m\":{{\"method\":\"Network.requestWillBeSentExtraInfo\",\"params\":{{\"requestId\":\"%s\",\"headers\":", rid);
	wire := make_dynamic(http.Header, 0, len(req.headers) + 4, temp);
	if !is_null(resp) && resp.version != .Http1_1 {
		append(*wire, http.Header.{":authority", host}, http.Header.{":method", req.method}, http.Header.{":path", req.path}, http.Header.{":scheme", "https"});
	}
	for h: req.headers { append(*wire, h); }
	// DevTools reports ExtraInfo headers sorted by name.
	slice.sort_by(view(wire), (a: http.Header, b: http.Header) -> bool {return compare(a.name, b.name) < 0;});
	headers_object(*sb2, view(wire));
	strings.write_string(*sb2, "}}");
	rec_line_at(r, tap.acct, start_ms, strings.to_string(sb2));
	if !is_null(resp) { nl_request_headers(r, tap.acct, host, req, resp.version, cast(s64)(start_ms)); }
	if err != .None || is_null(resp) {
		rec_line(r, tap.acct, fmt.tprintf("\"m\":{{\"method\":\"Network.loadingFailed\",\"params\":{{\"requestId\":\"%s\"}}}}", rid));
		return;
	}
	sb3 := strings.builder_make(temp);
	fmt.sbprintf(*sb3, "\"m\":{{\"method\":\"Network.responseReceived\",\"params\":{{\"requestId\":\"%s\",\"type\":\"%s\",\"response\":{{\"url\":", rid, kind);
	json_write_escaped(*sb3, url);
	fmt.sbprintf(*sb3, ",\"status\":%d,\"protocol\":\"%s\",\"connectionId\":0,\"connectionReused\":false,\"headers\":", resp.status, proto_name(resp.version));
	headers_object(*sb3, view(resp.headers));
	strings.write_string(*sb3, "}}}");
	rec_line(r, tap.acct, strings.to_string(sb3));
	if len(resp.body) > 0 {
		sb4 := strings.builder_make(temp);
		fmt.sbprintf(*sb4, "\"body_for\":\"%s\",\"s\":\"\",\"m\":{{\"result\":{{\"body\":", rid);
		ct, _ := http.header_get(view(resp.headers), "content-type");
		if strings.contains(ct, "json") || strings.has_prefix(ct, "text/") {
			json_write_escaped(*sb4, as_string(view(resp.body)));
			strings.write_string(*sb4, ",\"base64Encoded\":false}}");
		} else {
			json_write_escaped(*sb4, base64.encode(view(resp.body), allocator = temp));
			strings.write_string(*sb4, ",\"base64Encoded\":true}}");
		}
		rec_line(r, tap.acct, strings.to_string(sb4));
	}
	rec_line(r, tap.acct, fmt.tprintf("\"m\":{{\"method\":\"Network.loadingFinished\",\"params\":{{\"requestId\":\"%s\"}}}}", rid));
}

rec_ws_open :: (data: *void, url: string, headers: []http.Header) {
	tap := cast(*Recorder_Tap)data;
	r := tap.r;
	rid := rec_next_id(r);
	locks.lock(*r.mu);
	r.ws_id = clone(rid);
	locks.unlock(*r.mu);
	full := strings.concatenate(string.["wss://", sub_from(url, len("wss://"))], temp);
	sb := strings.builder_make(temp);
	fmt.sbprintf(*sb, "\"m\":{{\"method\":\"Network.webSocketCreated\",\"params\":{{\"requestId\":\"%s\",\"url\":", rid);
	json_write_escaped(*sb, full);
	strings.write_string(*sb, "}}");
	rec_line(r, tap.acct, strings.to_string(sb));
	sb2 := strings.builder_make(temp);
	fmt.sbprintf(*sb2, "\"m\":{{\"method\":\"Network.webSocketWillSendHandshakeRequest\",\"params\":{{\"requestId\":\"%s\",\"request\":{{\"headers\":", rid);
	headers_object(*sb2, headers);
	strings.write_string(*sb2, "}}}");
	rec_line(r, tap.acct, strings.to_string(sb2));
	// the upgrade request goes out over HTTP/1.1 exactly in this order
	rest := sub_from(url, len("wss://"));
	host, path := rest, "/";
	{ i := strings.index_byte(rest, #char "/");
	if i >= 0 { host, path = sub(rest, 0, i), sub_from(rest, i); } }
	nl_request_headers(r, tap.acct, host, http.Request.{method = "GET", scheme = "https", authority = host, path = path, headers = headers}, .Http1_1, now_ms());
}

rec_ws_close :: (data: *void, code: int) {
	tap := cast(*Recorder_Tap)data;
	rec_line(tap.r, tap.acct, fmt.tprintf("\"m\":{{\"method\":\"Network.webSocketClosed\",\"params\":{{\"requestId\":\"%s\"}}}}", tap.r.ws_id));
}

rec_gw :: (data: *void, sent: bool, payload: V, wire_len: int) {
	tap := cast(*Recorder_Tap)data;
	sb := strings.builder_make(temp);
	fmt.sbprintf(*sb, "\"gw\":{{\"dir\":\"%s\",\"ws\":\"%s\",\"len\":%d}},\"etf\":", ifx sent then "send" else "recv", tap.r.ws_id, wire_len);
	etf.to_json(payload, *sb);
	rec_line(tap.r, tap.acct, strings.to_string(sb));
}
#scope_export

