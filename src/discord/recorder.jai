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
//
// The hooks run on every network thread (workers, gateway, h2 service), each
// with its own temporary storage and possibly a pushed context.allocator: the
// recorder's state is touched only under mu and lives on the heap.

Recorder :: struct {
	mu: locks.Mutex;
	f: File;
	start: s64;
	next_id: int;
	ws_id: string; // heap
	last_net: s64; // ms of the last recorded network event (settle)
	closed: bool; // retired (session runner): late callbacks write nothing
	// Chrome-netlog-shaped side files (<path>.netlog-a / -b) carrying the true
	// wire header order and session setup facts; tools/scrub -netlog-a:/-b: read them.
	nl_path: string;
	nl: [2]File;
	nl_open: [2]bool;
	nl_next: int;
	sessions: Table(string, int); // "acct h2 host" / "acct h3 host" -> netlog source id (heap keys)
}

Recorder_Tap :: struct {
	r: *Recorder;
	acct: string;
}

recorder_open :: (path: string) -> *Recorder, bool {
	push_allocator(context.default_allocator);
	f, ok := file_open(path, for_writing = true);
	if !ok return null, false;
	r := New(Recorder);
	r.f = f;
	r.start = now_ms();
	r.nl_path = copy_string(path);
	r.sessions.allocator = context.default_allocator;
	return r, true;
}

recorder_close :: (r: *Recorder) {
	recorder_retire(r);
	push_allocator(context.default_allocator);
	free(r.ws_id);
	free(r.nl_path);
	free(r);
}

// recorder_retire closes the files but keeps r valid: a live client may still
// deliver callbacks from requests started before it was re-attached elsewhere.
recorder_retire :: (r: *Recorder) {
	locks.lock(*r.mu);
	defer locks.unlock(*r.mu);
	if r.closed return;
	r.closed = true;
	file_close(*r.f);
	netlog_close(r);
}

rec_write :: (r: *Recorder, line: string) {
	if !r.closed file_write(*r.f, line);
}

rec_line :: (r: *Recorder, acct: string, rest: string) {
	locks.lock(*r.mu);
	defer locks.unlock(*r.mu);
	n := now_ms();
	rec_write(r, tprint("{\"rt\":%,\"acct\":\"%\",%}\n", formatFloat(cast(float64) (n - r.start), trailing_width = 1, zero_removal = .NO), acct, rest));
	if !begins_with(rest, "\"mark\"") r.last_net = n;
}

recorder_last_net :: (r: *Recorder) -> s64 {
	locks.lock(*r.mu);
	defer locks.unlock(*r.mu);
	return r.last_net;
}

rec_line_at :: (r: *Recorder, acct: string, at_ms: float64, rest: string) {
	locks.lock(*r.mu);
	defer locks.unlock(*r.mu);
	rec_write(r, tprint("{\"rt\":%,\"acct\":\"%\",%}\n", formatFloat(at_ms - cast(float64) r.start, trailing_width = 3, zero_removal = .NO), acct, rest));
	r.last_net = max(r.last_net, now_ms());
}

recorder_mark :: (r: *Recorder, acct: string, name: string) {
	buf: [..]u8;
	buf.allocator = temp;
	append_string(*buf, "\"mark\":");
	json_write_escaped(*buf, name);
	rec_line(r, acct, cast(string) buf);
}

rec_next_id :: (r: *Recorder) -> string {
	locks.lock(*r.mu);
	defer locks.unlock(*r.mu);
	r.next_id += 1;
	return tprint("ours.%", r.next_id);
}

rec_ws_id :: (r: *Recorder) -> string {
	locks.lock(*r.mu);
	defer locks.unlock(*r.mu);
	return copy_string(r.ws_id,, temp);
}

// recorder_attach installs the hooks on a client (before client_start).
recorder_attach :: (r: *Recorder, c: *Client, acct: string) {
	push_allocator(context.default_allocator);
	tap := New(Recorder_Tap);
	tap.* = .{r, copy_string(acct)};
	c.observer_data = tap;
	c.transport.observer_data = tap;
	c.transport.observer = rec_http;
	c.on_gateway_frame = rec_gw;
	c.transport.conn_observer = rec_conn;
	c.on_ws_open = rec_ws_open;
	c.on_ws_close = rec_ws_close;
}

// ---- renderer-view header list (what DevTools shows in requestWillBeSent) ----

js_case :: (n: string) -> string {
	if n == {
		case "authorization";        return "Authorization";
		case "x-installation-id";    return "X-Installation-ID";
		case "x-debug-options";      return "X-Debug-Options";
		case "accept-language";      return "Accept-Language";
		case "x-discord-timezone";   return "X-Discord-Timezone";
		case "x-context-properties"; return "X-Context-Properties";
		case "x-super-properties";   return "X-Super-Properties";
		case "x-discord-locale";     return "X-Discord-Locale";
		case "content-type";         return "Content-Type";
		case "if-none-match";        return "If-None-Match";
		case "cache-control";        return "Cache-Control";
		case "x-failed-requests";    return "X-Failed-Requests";
		case "referer";              return "Referer";
		case "user-agent";           return "User-Agent";
		case "accept";               return "Accept";
		case "access-control-request-headers"; return "Access-Control-Request-Headers";
		case "access-control-request-method";  return "Access-Control-Request-Method";
		case "origin";               return "Origin";
		case "sec-fetch-mode";       return "Sec-Fetch-Mode";
	}
	return n;
}

hval :: (h: []http.Header, name: string) -> string, bool {
	for h if it.name == name return it.value, true;
	return "", false;
}

// renderer_view derives DevTools' request header object from our wire list (temp).
renderer_view :: (method: string, wire: []http.Header, kind: string) -> []http.Header {
	out: [..]http.Header;
	out.allocator = temp;
	add :: (names: ..string) #expand {
		for n: names {
			v, ok := hval(`wire, n);
			if ok array_add(*`out, .{js_case(n), v});
		}
	}
	if method == "OPTIONS" {
		add("accept", "access-control-request-headers", "access-control-request-method", "origin", "sec-fetch-mode", "user-agent");
		return out;
	}
	STANDARD :: string.["content-length", "sec-ch-ua-platform", "authorization", "x-installation-id", "x-debug-options", "accept-language", "sec-ch-ua", "sec-ch-ua-mobile", "x-discord-timezone", "x-context-properties", "x-super-properties", "x-discord-locale", "user-agent", "content-type", "accept", "origin", "sec-fetch-site", "sec-fetch-mode", "sec-fetch-dest", "sec-fetch-storage-access", "referer", "accept-encoding", "cookie", "priority", "if-modified-since", "cache-control"];
	extras: [..]string;
	extras.allocator = temp;
	for h: wire if !array_find(STANDARD, h.name) array_add(*extras, h.name);
	_, authed := hval(wire, "authorization");
	if authed {
		add(..extras);
		if extras {
			add("authorization", "x-installation-id", "sec-ch-ua-platform", "x-debug-options", "accept-language", "sec-ch-ua", "referer", "sec-ch-ua-mobile", "x-discord-timezone", "x-context-properties", "x-super-properties", "x-discord-locale", "user-agent", "content-type");
		} else {
			add("sec-ch-ua-platform", "authorization", "x-installation-id", "referer", "x-debug-options", "accept-language", "sec-ch-ua", "sec-ch-ua-mobile", "x-discord-timezone", "x-context-properties", "x-super-properties", "x-discord-locale", "user-agent", "content-type");
		}
		return out;
	}
	// unauthenticated XHR / fetch / image. A JS-set If-None-Match comes before
	// the client hints; one appended by the HTTP cache (at the end) is not renderer-visible.
	inm_js := false;
	for h: wire {
		if h.name == "sec-ch-ua-platform" break;
		if h.name == "if-none-match" inm_js = true;
	}
	inm, has_inm := hval(wire, "if-none-match");
	if has_inm && inm_js && kind != "Image" array_add(*out, .{"If-None-Match", inm});
	for extras if it != "if-none-match" add(it);
	add("sec-ch-ua-platform", "referer", "user-agent", "sec-ch-ua", "content-type", "sec-ch-ua-mobile");
	return out;
}

headers_object :: (buf: *[..]u8, h: []http.Header) {
	array_add(buf, #char "{");
	for h {
		if it_index > 0 array_add(buf, #char ",");
		json_write_escaped(buf, it.name);
		array_add(buf, #char ":");
		json_write_escaped(buf, it.value);
	}
	array_add(buf, #char "}");
}

request_kind :: (req: http.Request) -> string {
	if req.method == "OPTIONS" return "Other";
	v := hval(req.headers, "sec-fetch-dest");
	if v == "image" return "Image";
	if v == "font" return "Font";
	if contains(req.path, "/bad-domains/") return "Fetch";
	return "XHR";
}

proto_name :: (v: http.Version) -> string {
	if v == {
		case .Http3; return "h3";
		case .Http2; return "h2";
		case .Http1_1; #through;
		case .Http1_0; return "http/1.1";
	}
	return "";
}

// temp_buffer: the bytes of one recorded line.
temp_buffer :: () -> [..]u8 {
	b: [..]u8;
	b.allocator = temp;
	return b;
}

rec_http :: (data: *void, host: string, req: http.Request, resp: *http.Response, err: http.Error, start_ms: float64) {
	tap := cast(*Recorder_Tap) data;
	r := tap.r;
	rid := rec_next_id(r);
	url := join("https://", host, req.path,, temp);
	kind := request_kind(req);
	// requestWillBeSent
	b := temp_buffer();
	append_string(*b, tprint("\"m\":{\"method\":\"Network.requestWillBeSent\",\"params\":{\"requestId\":\"%\",\"type\":\"%\",\"wallTime\":%,\"request\":{\"url\":", rid, kind, formatFloat(start_ms / 1000, trailing_width = 6, zero_removal = .NO)));
	json_write_escaped(*b, url);
	append_string(*b, ",\"method\":");
	json_write_escaped(*b, req.method);
	append_string(*b, ",\"headers\":");
	rv := renderer_view(req.method, req.headers, kind);
	if context.tl_js_lower_auth for * rv if it.name == "Authorization" it.name = "authorization";
	headers_object(*b, rv);
	if req.body {
		append_string(*b, ",\"hasPostData\":true,\"postData\":");
		json_write_escaped(*b, cast(string) req.body);
	}
	append_string(*b, "}}}");
	rec_line_at(r, tap.acct, start_ms, cast(string) b);
	// ExtraInfo: the real wire list (pseudo-headers first, as DevTools shows them)
	b2 := temp_buffer();
	append_string(*b2, tprint("\"m\":{\"method\":\"Network.requestWillBeSentExtraInfo\",\"params\":{\"requestId\":\"%\",\"headers\":", rid));
	wire: [..]http.Header;
	wire.allocator = temp;
	if resp && resp.version != .Http1_1 {
		array_add(*wire, .{":authority", host}, .{":method", req.method}, .{":path", req.path}, .{":scheme", "https"});
	}
	array_add(*wire, ..req.headers);
	// DevTools reports ExtraInfo headers sorted by name (a stable sort: equal names keep their order).
	stable_sort_by_name(wire);
	headers_object(*b2, wire);
	append_string(*b2, "}}");
	rec_line_at(r, tap.acct, start_ms, cast(string) b2);
	if resp nl_request_headers(r, tap.acct, host, req, resp.version, cast(s64) start_ms);
	if err != .None || !resp {
		rec_line(r, tap.acct, tprint("\"m\":{\"method\":\"Network.loadingFailed\",\"params\":{\"requestId\":\"%\"}}", rid));
		return;
	}
	b3 := temp_buffer();
	append_string(*b3, tprint("\"m\":{\"method\":\"Network.responseReceived\",\"params\":{\"requestId\":\"%\",\"type\":\"%\",\"response\":{\"url\":", rid, kind));
	json_write_escaped(*b3, url);
	append_string(*b3, tprint(",\"status\":%,\"protocol\":\"%\",\"connectionId\":0,\"connectionReused\":false,\"headers\":", resp.status, proto_name(resp.version)));
	headers_object(*b3, resp.headers);
	append_string(*b3, "}}}");
	rec_line(r, tap.acct, cast(string) b3);
	if resp.body {
		b4 := temp_buffer();
		append_string(*b4, tprint("\"body_for\":\"%\",\"s\":\"\",\"m\":{\"result\":{\"body\":", rid));
		ct := http.header_get(resp.headers, "content-type");
		if contains(ct, "json") || begins_with(ct, "text/") {
			json_write_escaped(*b4, cast(string) resp.body);
			append_string(*b4, ",\"base64Encoded\":false}}");
		} else {
			json_write_escaped(*b4, base64_encode(cast(string) resp.body,, temp));
			append_string(*b4, ",\"base64Encoded\":true}}");
		}
		rec_line(r, tap.acct, cast(string) b4);
	}
	rec_line(r, tap.acct, tprint("\"m\":{\"method\":\"Network.loadingFinished\",\"params\":{\"requestId\":\"%\"}}", rid));
}

// stable_sort_by_name: insertion sort (header lists are short).
stable_sort_by_name :: (h: []http.Header) {
	for i: 1..h.count - 1 {
		x := h[i];
		j := i;
		while j > 0 && compare(h[j - 1].name, x.name) > 0 {
			h[j] = h[j - 1];
			j -= 1;
		}
		h[j] = x;
	}
}

rec_ws_open :: (data: *void, url: string, headers: []http.Header) {
	tap := cast(*Recorder_Tap) data;
	r := tap.r;
	rid := rec_next_id(r);
	locks.lock(*r.mu);
	free(r.ws_id,, context.default_allocator);
	r.ws_id = copy_string(rid,, context.default_allocator);
	locks.unlock(*r.mu);
	rest := advance(url, "wss://".count);
	b := temp_buffer();
	append_string(*b, tprint("\"m\":{\"method\":\"Network.webSocketCreated\",\"params\":{\"requestId\":\"%\",\"url\":", rid));
	json_write_escaped(*b, join("wss://", rest,, temp));
	append_string(*b, "}}");
	rec_line(r, tap.acct, cast(string) b);
	b2 := temp_buffer();
	append_string(*b2, tprint("\"m\":{\"method\":\"Network.webSocketWillSendHandshakeRequest\",\"params\":{\"requestId\":\"%\",\"request\":{\"headers\":", rid));
	headers_object(*b2, headers);
	append_string(*b2, "}}}");
	rec_line(r, tap.acct, cast(string) b2);
	// the upgrade request goes out over HTTP/1.1 exactly in this order
	found, host := split_from_left(rest, #char "/");
	path := ifx found then advance(rest, host.count) else "/";
	nl_request_headers(r, tap.acct, host, .{method = "GET", scheme = "https", authority = host, path = path, headers = headers}, .Http1_1, now_ms());
}

rec_ws_close :: (data: *void, code: int) {
	tap := cast(*Recorder_Tap) data;
	rec_line(tap.r, tap.acct, tprint("\"m\":{\"method\":\"Network.webSocketClosed\",\"params\":{\"requestId\":\"%\"}}", rec_ws_id(tap.r)));
}

rec_gw :: (data: *void, sent: bool, payload: V, wire_len: int) {
	tap := cast(*Recorder_Tap) data;
	sb: String_Builder;
	sb.allocator = temp;
	print_to_builder(*sb, "\"gw\":{\"dir\":\"%\",\"ws\":\"%\",\"len\":%},\"etf\":", ifx sent then "send" else "recv", rec_ws_id(tap.r), wire_len);
	etf.to_json(payload, *sb);
	rec_line(tap.r, tap.acct, builder_to_string(*sb,, temp));
}
