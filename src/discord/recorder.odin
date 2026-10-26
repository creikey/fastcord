package discord

import "fc:locks"
import "core:encoding/base64"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "fc:etf"
import "fc:http"

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
	mu:      locks.Mutex,
	f:       ^os.File,
	start:   i64,
	next_id: int,
	ws_id:   string,
	last_net: i64, // ms of the last recorded network event (settle)
	// Chrome-netlog-shaped side files (<path>.netlog-a / -b) carrying the true
	// wire header order and session setup facts; tools/scrub -netlog-a:/-b: read them.
	nl_path:  string,
	nl:       [2]^os.File,
	nl_next:  int,
	sessions: map[string]int, // "h2 host" / "h3 host" -> netlog source id
}

Recorder_Tap :: struct {
	r:    ^Recorder,
	acct: string,
}

recorder_open :: proc(path: string) -> (^Recorder, bool) {
	f, err := os.create(path)
	if err != nil do return nil, false
	r := new(Recorder)
	r.f = f
	r.start = now_ms()
	r.nl_path = strings.clone(path)
	return r, true
}

recorder_close :: proc(r: ^Recorder) {
	os.close(r.f)
	netlog_close(r)
	free(r)
}

@(private)
rec_line :: proc(r: ^Recorder, acct, rest: string) {
	locks.lock(&r.mu)
	defer locks.unlock(&r.mu)
	n := now_ms()
	line := fmt.tprintf(`{{"rt":%.1f,"acct":"%s",%s}}`+"\n", f64(n - r.start), acct, rest)
	os.write_string(r.f, line)
	if !strings.has_prefix(rest, `"mark"`) do r.last_net = n
}

recorder_last_net :: proc(r: ^Recorder) -> i64 {
	locks.lock(&r.mu)
	defer locks.unlock(&r.mu)
	return r.last_net
}

@(private)
rec_line_at :: proc(r: ^Recorder, acct: string, at_ms: f64, rest: string) {
	locks.lock(&r.mu)
	defer locks.unlock(&r.mu)
	line := fmt.tprintf(`{{"rt":%.3f,"acct":"%s",%s}}`+"\n", at_ms - f64(r.start), acct, rest)
	os.write_string(r.f, line)
	r.last_net = max(r.last_net, now_ms())
}

recorder_mark :: proc(r: ^Recorder, acct, name: string) {
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, `"mark":`)
	json_write_escaped(&sb, name)
	rec_line(r, acct, strings.to_string(sb))
}

@(private)
rec_next_id :: proc(r: ^Recorder) -> string {
	locks.lock(&r.mu)
	defer locks.unlock(&r.mu)
	r.next_id += 1
	return fmt.tprintf("ours.%d", r.next_id)
}

// recorder_attach installs the hooks on a client (before client_start).
recorder_attach :: proc(r: ^Recorder, c: ^Client, acct: string) {
	tap := new(Recorder_Tap)
	tap^ = {r, strings.clone(acct)}
	c.observer_data = tap
	c.transport.observer_data = tap
	c.transport.observer = rec_http
	c.on_gateway_frame = rec_gw
	c.transport.conn_observer = rec_conn
	c.on_ws_open = rec_ws_open
	c.on_ws_close = rec_ws_close
}

// ---- renderer-view header list (what DevTools shows in requestWillBeSent) ----

@(private)
js_case :: proc(n: string) -> string {
	switch n {
	case "authorization":
		return "Authorization"
	case "x-installation-id":
		return "X-Installation-ID"
	case "x-debug-options":
		return "X-Debug-Options"
	case "accept-language":
		return "Accept-Language"
	case "x-discord-timezone":
		return "X-Discord-Timezone"
	case "x-context-properties":
		return "X-Context-Properties"
	case "x-super-properties":
		return "X-Super-Properties"
	case "x-discord-locale":
		return "X-Discord-Locale"
	case "content-type":
		return "Content-Type"
	case "if-none-match":
		return "If-None-Match"
	case "cache-control":
		return "Cache-Control"
	case "x-failed-requests":
		return "X-Failed-Requests"
	case "referer":
		return "Referer"
	case "user-agent":
		return "User-Agent"
	case "accept":
		return "Accept"
	case "access-control-request-headers":
		return "Access-Control-Request-Headers"
	case "access-control-request-method":
		return "Access-Control-Request-Method"
	case "origin":
		return "Origin"
	case "sec-fetch-mode":
		return "Sec-Fetch-Mode"
	}
	return n
}

@(private)
hval :: proc(h: []http.Header, name: string) -> (string, bool) {
	for x in h do if x.name == name do return x.value, true
	return "", false
}

// renderer_view derives DevTools' request header object from our wire list.
renderer_view :: proc(method: string, wire: []http.Header, kind: string) -> []http.Header {
	out := make([dynamic]http.Header, 0, len(wire), context.temp_allocator)
	add :: proc(out: ^[dynamic]http.Header, wire: []http.Header, name: string) {
		if v, ok := hval(wire, name); ok do append(out, http.Header{js_case(name), v})
	}
	if method == "OPTIONS" {
		for n in ([]string{"accept", "access-control-request-headers", "access-control-request-method", "origin", "sec-fetch-mode", "user-agent"}) do add(&out, wire, n)
		return out[:]
	}
	standard := []string{"content-length", "sec-ch-ua-platform", "authorization", "x-installation-id", "x-debug-options", "accept-language", "sec-ch-ua", "sec-ch-ua-mobile", "x-discord-timezone", "x-context-properties", "x-super-properties", "x-discord-locale", "user-agent", "content-type", "accept", "origin", "sec-fetch-site", "sec-fetch-mode", "sec-fetch-dest", "sec-fetch-storage-access", "referer", "accept-encoding", "cookie", "priority", "if-modified-since", "cache-control"}
	is_std :: proc(standard: []string, n: string) -> bool {
		for s in standard do if s == n do return true
		return false
	}
	extras := make([dynamic]string, context.temp_allocator)
	for h in wire {
		if !is_std(standard, h.name) do append(&extras, h.name)
	}
	_, authed := hval(wire, "authorization")
	if authed {
		for e in extras do add(&out, wire, e)
		if len(extras) > 0 {
			for n in ([]string{"authorization", "x-installation-id", "sec-ch-ua-platform", "x-debug-options", "accept-language", "sec-ch-ua", "referer", "sec-ch-ua-mobile", "x-discord-timezone", "x-context-properties", "x-super-properties", "x-discord-locale", "user-agent", "content-type"}) do add(&out, wire, n)
		} else {
			for n in ([]string{"sec-ch-ua-platform", "authorization", "x-installation-id", "referer", "x-debug-options", "accept-language", "sec-ch-ua", "sec-ch-ua-mobile", "x-discord-timezone", "x-context-properties", "x-super-properties", "x-discord-locale", "user-agent", "content-type"}) do add(&out, wire, n)
		}
		return out[:]
	}
	// unauthenticated XHR / fetch / image. A JS-set If-None-Match comes before
	// the client hints; one appended by the HTTP cache (at the end) is not renderer-visible.
	inm_js := false
	for h in wire {
		if h.name == "sec-ch-ua-platform" do break
		if h.name == "if-none-match" do inm_js = true
	}
	if v, ok := hval(wire, "if-none-match"); ok && inm_js && kind != "Image" do append(&out, http.Header{"If-None-Match", v})
	for e in extras do if e != "if-none-match" do add(&out, wire, e)
	for n in ([]string{"sec-ch-ua-platform", "referer", "user-agent", "sec-ch-ua", "content-type", "sec-ch-ua-mobile"}) do add(&out, wire, n)
	return out[:]
}

@(private)
headers_object :: proc(sb: ^strings.Builder, h: []http.Header) {
	strings.write_byte(sb, '{')
	for x, i in h {
		if i > 0 do strings.write_byte(sb, ',')
		json_write_escaped(sb, x.name)
		strings.write_byte(sb, ':')
		json_write_escaped(sb, x.value)
	}
	strings.write_byte(sb, '}')
}

@(private)
request_kind :: proc(req: http.Request) -> string {
	if req.method == "OPTIONS" do return "Other"
	if v, ok := hval(req.headers, "sec-fetch-dest"); ok {
		switch v {
		case "image":
			return "Image"
		case "font":
			return "Font"
		}
	}
	if strings.contains(req.path, "/bad-domains/") do return "Fetch"
	return "XHR"
}

@(private)
proto_name :: proc(v: http.Version) -> string {
	switch v {
	case .Http3:
		return "h3"
	case .Http2:
		return "h2"
	case .Http1_1, .Http1_0:
		return "http/1.1"
	}
	return ""
}

@(private)
rec_http :: proc(data: rawptr, host: string, req: http.Request, resp: ^http.Response, err: http.Error, start_ms: f64) {
	tap := cast(^Recorder_Tap)data
	r := tap.r
	rid := rec_next_id(r)
	url := strings.concatenate({"https://", host, req.path}, context.temp_allocator)
	kind := request_kind(req)
	// requestWillBeSent
	sb := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&sb, `"m":{{"method":"Network.requestWillBeSent","params":{{"requestId":"%s","type":"%s","wallTime":%.6f,"request":{{"url":`, rid, kind, start_ms / 1000)
	json_write_escaped(&sb, url)
	strings.write_string(&sb, `,"method":`)
	json_write_escaped(&sb, req.method)
	strings.write_string(&sb, `,"headers":`)
	headers_object(&sb, renderer_view(req.method, req.headers, kind))
	if len(req.body) > 0 {
		strings.write_string(&sb, `,"hasPostData":true,"postData":`)
		json_write_escaped(&sb, string(req.body))
	}
	strings.write_string(&sb, "}}}")
	rec_line_at(r, tap.acct, start_ms, strings.to_string(sb))
	// ExtraInfo: the real wire list (pseudo-headers first, as DevTools shows them)
	sb2 := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&sb2, `"m":{{"method":"Network.requestWillBeSentExtraInfo","params":{{"requestId":"%s","headers":`, rid)
	wire := make([dynamic]http.Header, 0, len(req.headers) + 4, context.temp_allocator)
	if resp != nil && resp.version != .Http1_1 {
		append(&wire, http.Header{":authority", host}, http.Header{":method", req.method}, http.Header{":path", req.path}, http.Header{":scheme", "https"})
	}
	for h in req.headers do append(&wire, h)
	// DevTools reports ExtraInfo headers sorted by name.
	slice.sort_by(wire[:], proc(a, b: http.Header) -> bool {return a.name < b.name})
	headers_object(&sb2, wire[:])
	strings.write_string(&sb2, "}}")
	rec_line_at(r, tap.acct, start_ms, strings.to_string(sb2))
	if resp != nil do nl_request_headers(r, tap.acct, host, req, resp.version, i64(start_ms))
	if err != .None || resp == nil {
		rec_line(r, tap.acct, fmt.tprintf(`"m":{{"method":"Network.loadingFailed","params":{{"requestId":"%s"}}}}`, rid))
		return
	}
	sb3 := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&sb3, `"m":{{"method":"Network.responseReceived","params":{{"requestId":"%s","type":"%s","response":{{"url":`, rid, kind)
	json_write_escaped(&sb3, url)
	fmt.sbprintf(&sb3, `,"status":%d,"protocol":"%s","connectionId":0,"connectionReused":false,"headers":`, resp.status, proto_name(resp.version))
	headers_object(&sb3, resp.headers[:])
	strings.write_string(&sb3, "}}}")
	rec_line(r, tap.acct, strings.to_string(sb3))
	if len(resp.body) > 0 {
		sb4 := strings.builder_make(context.temp_allocator)
		fmt.sbprintf(&sb4, `"body_for":"%s","s":"","m":{{"result":{{"body":`, rid)
		ct, _ := http.header_get(resp.headers[:], "content-type")
		if strings.contains(ct, "json") || strings.has_prefix(ct, "text/") {
			json_write_escaped(&sb4, string(resp.body[:]))
			strings.write_string(&sb4, `,"base64Encoded":false}}`)
		} else {
			json_write_escaped(&sb4, base64.encode(resp.body[:], allocator = context.temp_allocator))
			strings.write_string(&sb4, `,"base64Encoded":true}}`)
		}
		rec_line(r, tap.acct, strings.to_string(sb4))
	}
	rec_line(r, tap.acct, fmt.tprintf(`"m":{{"method":"Network.loadingFinished","params":{{"requestId":"%s"}}}}`, rid))
}

@(private)
rec_ws_open :: proc(data: rawptr, url: string, headers: []http.Header) {
	tap := cast(^Recorder_Tap)data
	r := tap.r
	rid := rec_next_id(r)
	locks.lock(&r.mu)
	r.ws_id = strings.clone(rid)
	locks.unlock(&r.mu)
	full := strings.concatenate({"wss://", url[len("wss://"):]}, context.temp_allocator)
	sb := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&sb, `"m":{{"method":"Network.webSocketCreated","params":{{"requestId":"%s","url":`, rid)
	json_write_escaped(&sb, full)
	strings.write_string(&sb, "}}")
	rec_line(r, tap.acct, strings.to_string(sb))
	sb2 := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&sb2, `"m":{{"method":"Network.webSocketWillSendHandshakeRequest","params":{{"requestId":"%s","request":{{"headers":`, rid)
	headers_object(&sb2, headers)
	strings.write_string(&sb2, "}}}")
	rec_line(r, tap.acct, strings.to_string(sb2))
	// the upgrade request goes out over HTTP/1.1 exactly in this order
	rest := url[len("wss://"):]
	host, path := rest, "/"
	if i := strings.index_byte(rest, '/'); i >= 0 do host, path = rest[:i], rest[i:]
	nl_request_headers(r, tap.acct, host, http.Request{method = "GET", scheme = "https", authority = host, path = path, headers = headers}, .Http1_1, now_ms())
}

@(private)
rec_ws_close :: proc(data: rawptr, code: int) {
	tap := cast(^Recorder_Tap)data
	rec_line(tap.r, tap.acct, fmt.tprintf(`"m":{{"method":"Network.webSocketClosed","params":{{"requestId":"%s"}}}}`, tap.r.ws_id))
}

@(private)
rec_gw :: proc(data: rawptr, sent: bool, payload: V, wire_len: int) {
	tap := cast(^Recorder_Tap)data
	sb := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&sb, `"gw":{{"dir":"%s","ws":"%s","len":%d}},"etf":`, "send" if sent else "recv", tap.r.ws_id, wire_len)
	etf.to_json(payload, &sb)
	rec_line(tap.r, tap.acct, strings.to_string(sb))
}
