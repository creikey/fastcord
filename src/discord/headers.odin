package discord

import "core:strconv"
import "core:strings"
import "fc:http"

// Header assembly. The orders below are the wire orders Chrome 148 produced
// for the official client (verified with netlog captures of every REST action
// the library performs: HTTP3_HEADERS_SENT). The interleaving of Blink- and
// network-service-added headers is fixed per request shape, so it is encoded
// here as templates rather than derived.

API_ORIGIN :: "https://discord.com"
API_HOST :: "discord.com"
ACCEPT_ENCODING :: "gzip, deflate, br, zstd"
XHR_PRIORITY :: "u=1, i"

Api_Headers_Input :: struct {
	method:          string,
	has_body:        bool,
	body_len:        int,
	content_type:    string, // "" = none (application/json for JSON bodies)
	token:           string, // "" = no authorization header
	installation_id: string,
	super_props_b64: string,
	context_b64:     string, // x-context-properties
	referer:         string,
	cookie:          string,
	// JS-set headers outside the standard set (if-none-match, cache-control,
	// x-failed-requests, x-audit-log-reason, x-discord-original-md5 ...).
	// Chrome places these first and moves sec-ch-ua-platform after x-installation-id.
	extra:           []http.Header,
}

method_sends_content_length :: proc(method: string) -> bool {
	// Chrome sends Content-Length for POST/PUT/PATCH even with no body; not for GET/HEAD/DELETE.
	return method == "POST" || method == "PUT" || method == "PATCH"
}

method_sends_origin :: proc(method: string) -> bool {
	return method != "GET" && method != "HEAD"
}

itoa :: proc(n: int, allocator := context.temp_allocator) -> string {
	buf: [24]byte
	return strings.clone(strconv.write_int(buf[:], i64(n), 10), allocator)
}

// api_headers builds the header list for an authenticated discord.com/api request.
api_headers :: proc(p: Platform_Info, in_: Api_Headers_Input, allocator := context.temp_allocator) -> []http.Header {
	h := make([dynamic]http.Header, 0, 28, allocator)
	if method_sends_content_length(in_.method) || in_.has_body {
		append(&h, http.Header{"content-length", itoa(in_.body_len, allocator)})
	}
	if len(in_.extra) > 0 {
		for e in in_.extra do append(&h, e)
		if in_.token != "" do append(&h, http.Header{"authorization", in_.token})
		if in_.installation_id != "" do append(&h, http.Header{"x-installation-id", in_.installation_id})
		append(&h, http.Header{"sec-ch-ua-platform", p.sec_ch_ua_platform})
	} else {
		append(&h, http.Header{"sec-ch-ua-platform", p.sec_ch_ua_platform})
		if in_.token != "" do append(&h, http.Header{"authorization", in_.token})
		if in_.installation_id != "" do append(&h, http.Header{"x-installation-id", in_.installation_id})
	}
	if p.debug_options != "" do append(&h, http.Header{"x-debug-options", p.debug_options})
	append(&h, http.Header{"accept-language", p.accept_language})
	append(&h, http.Header{"sec-ch-ua", p.sec_ch_ua})
	append(&h, http.Header{"sec-ch-ua-mobile", "?0"})
	if p.timezone != "" do append(&h, http.Header{"x-discord-timezone", p.timezone})
	if in_.context_b64 != "" do append(&h, http.Header{"x-context-properties", in_.context_b64})
	if in_.super_props_b64 != "" do append(&h, http.Header{"x-super-properties", in_.super_props_b64})
	append(&h, http.Header{"x-discord-locale", p.locale})
	append(&h, http.Header{"user-agent", p.browser_user_agent})
	if in_.content_type != "" do append(&h, http.Header{"content-type", in_.content_type})
	append(&h, http.Header{"accept", "*/*"})
	if method_sends_origin(in_.method) do append(&h, http.Header{"origin", API_ORIGIN})
	append(&h, http.Header{"sec-fetch-site", "same-origin"})
	append(&h, http.Header{"sec-fetch-mode", "cors"})
	append(&h, http.Header{"sec-fetch-dest", "empty"})
	append(&h, http.Header{"referer", in_.referer})
	append(&h, http.Header{"accept-encoding", ACCEPT_ENCODING})
	if in_.cookie != "" do append(&h, http.Header{"cookie", in_.cookie})
	append(&h, http.Header{"priority", XHR_PRIORITY})
	return h[:]
}

Fetch_Site :: enum u8 {
	Same_Origin,
	Same_Site,
	Cross_Site,
}

fetch_site_name :: proc(s: Fetch_Site) -> string {
	switch s {
	case .Same_Origin:
		return "same-origin"
	case .Same_Site:
		return "same-site"
	case .Cross_Site:
		return "cross-site"
	}
	return ""
}

Web_Headers_Input :: struct {
	method:         string,
	site:           Fetch_Site,
	referer:        string, // cross-origin requests get the origin only ("https://discord.com/")
	cookie:         string,
	content_type:   string,
	body_len:       int,
	has_body:       bool,
	js_headers:     []http.Header, // set by the page (cache-control, if-none-match...)
	cache_validator: []http.Header, // added by Chrome's HTTP cache (if-none-match / if-modified-since)
	accept:         string, // "" = */*
}

// web_headers builds an unauthenticated XHR/fetch request (status page,
// cdn json, version.stable.json, latency.discord.media...).
web_headers :: proc(p: Platform_Info, in_: Web_Headers_Input, allocator := context.temp_allocator) -> []http.Header {
	h := make([dynamic]http.Header, 0, 20, allocator)
	if method_sends_content_length(in_.method) || in_.has_body {
		append(&h, http.Header{"content-length", itoa(in_.body_len, allocator)})
	}
	for e in in_.js_headers do append(&h, e)
	append(&h, http.Header{"sec-ch-ua-platform", p.sec_ch_ua_platform})
	append(&h, http.Header{"user-agent", p.browser_user_agent})
	append(&h, http.Header{"sec-ch-ua", p.sec_ch_ua})
	if in_.content_type != "" do append(&h, http.Header{"content-type", in_.content_type})
	append(&h, http.Header{"sec-ch-ua-mobile", "?0"})
	append(&h, http.Header{"accept", in_.accept if in_.accept != "" else "*/*"})
	if in_.site != .Same_Origin || method_sends_origin(in_.method) do append(&h, http.Header{"origin", API_ORIGIN})
	append(&h, http.Header{"sec-fetch-site", fetch_site_name(in_.site)})
	append(&h, http.Header{"sec-fetch-mode", "cors"})
	append(&h, http.Header{"sec-fetch-dest", "empty"})
	append(&h, http.Header{"referer", in_.referer})
	append(&h, http.Header{"accept-encoding", ACCEPT_ENCODING})
	append(&h, http.Header{"accept-language", p.accept_language})
	if in_.cookie != "" do append(&h, http.Header{"cookie", in_.cookie})
	for e in in_.cache_validator do append(&h, e)
	append(&h, http.Header{"priority", XHR_PRIORITY})
	return h[:]
}

// preflight_headers: CORS preflight Chrome sends before a cross-origin PUT
// (attachment upload to storage.googleapis.com).
preflight_headers :: proc(p: Platform_Info, method, request_headers: string, allocator := context.temp_allocator) -> []http.Header {
	h := make([dynamic]http.Header, 0, 12, allocator)
	append(&h, http.Header{"accept", "*/*"})
	append(&h, http.Header{"access-control-request-method", method})
	if request_headers != "" do append(&h, http.Header{"access-control-request-headers", request_headers})
	append(&h, http.Header{"origin", API_ORIGIN})
	append(&h, http.Header{"user-agent", p.browser_user_agent})
	append(&h, http.Header{"sec-fetch-mode", "cors"})
	append(&h, http.Header{"sec-fetch-site", "cross-site"})
	append(&h, http.Header{"sec-fetch-dest", "empty"})
	append(&h, http.Header{"referer", API_ORIGIN + "/"})
	append(&h, http.Header{"accept-encoding", ACCEPT_ENCODING})
	append(&h, http.Header{"accept-language", p.accept_language})
	append(&h, http.Header{"priority", XHR_PRIORITY})
	return h[:]
}

// upload_put_headers: the cross-site XHR PUT of the file body to the upload_url.
upload_put_headers :: proc(p: Platform_Info, body_len: int, allocator := context.temp_allocator) -> []http.Header {
	h := make([dynamic]http.Header, 0, 16, allocator)
	append(&h, http.Header{"content-length", itoa(body_len, allocator)})
	append(&h, http.Header{"sec-ch-ua-platform", p.sec_ch_ua_platform})
	append(&h, http.Header{"user-agent", p.browser_user_agent})
	append(&h, http.Header{"sec-ch-ua", p.sec_ch_ua})
	append(&h, http.Header{"content-type", "application/octet-stream"})
	append(&h, http.Header{"sec-ch-ua-mobile", "?0"})
	append(&h, http.Header{"accept", "*/*"})
	append(&h, http.Header{"origin", API_ORIGIN})
	append(&h, http.Header{"sec-fetch-site", "cross-site"})
	append(&h, http.Header{"sec-fetch-mode", "cors"})
	append(&h, http.Header{"sec-fetch-dest", "empty"})
	append(&h, http.Header{"referer", API_ORIGIN + "/"})
	append(&h, http.Header{"accept-encoding", ACCEPT_ENCODING})
	append(&h, http.Header{"accept-language", p.accept_language})
	append(&h, http.Header{"priority", XHR_PRIORITY})
	return h[:]
}

// gateway_ws_headers: the HTTP/1.1 upgrade request exactly as Chrome writes it.
// Sec-WebSocket-Key is filled by http.ws_connect (empty value = generate).
gateway_ws_headers :: proc(p: Platform_Info, host, cookie: string, allocator := context.temp_allocator) -> []http.Header {
	h := make([dynamic]http.Header, 0, 14, allocator)
	append(&h, http.Header{"Host", host})
	append(&h, http.Header{"Connection", "Upgrade"})
	append(&h, http.Header{"Pragma", "no-cache"})
	append(&h, http.Header{"Cache-Control", "no-cache"})
	append(&h, http.Header{"User-Agent", p.browser_user_agent})
	append(&h, http.Header{"Upgrade", "websocket"})
	append(&h, http.Header{"Origin", API_ORIGIN})
	append(&h, http.Header{"Sec-WebSocket-Version", "13"})
	append(&h, http.Header{"Accept-Encoding", ACCEPT_ENCODING})
	append(&h, http.Header{"Accept-Language", p.accept_language})
	if cookie != "" do append(&h, http.Header{"Cookie", cookie})
	append(&h, http.Header{"Sec-WebSocket-Key", ""})
	append(&h, http.Header{"Sec-WebSocket-Extensions", "permessage-deflate; client_max_window_bits"})
	return h[:]
}

// referer_for_route: the client's referer is the current window location.
referer_for_route :: proc(guild_id, channel_id: Snowflake, allocator := context.temp_allocator) -> string {
	if channel_id == 0 && guild_id == 0 do return API_ORIGIN + "/channels/@me"
	g := "@me" if guild_id == 0 else snowflake_string(guild_id)
	if channel_id == 0 do return strings.concatenate({API_ORIGIN, "/channels/", g}, allocator)
	return strings.concatenate({API_ORIGIN, "/channels/", g, "/", snowflake_string(channel_id)}, allocator)
}
