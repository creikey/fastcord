// Header assembly. The orders below are the wire orders Chrome 148 produced
// for the official client (verified with netlog captures of every REST action
// the library performs: HTTP3_HEADERS_SENT). The interleaving of Blink- and
// network-service-added headers is fixed per request shape, so it is encoded
// here as templates rather than derived.

API_ORIGIN :: "https://discord.com";
API_HOST :: "discord.com";
ACCEPT_ENCODING :: "gzip, deflate, br, zstd";
XHR_PRIORITY :: "u=1, i";

Api_Headers_Input :: struct {
	method: string;
	has_body: bool;
	body_len: int;
	content_type: string; // "" = none (application/json for JSON bodies)
	token: string; // "" = no authorization header
	installation_id: string;
	super_props_b64: string;
	context_b64: string; // x-context-properties
	referer: string;
	cookie: string;
	fingerprint: string; // X-Fingerprint (logged out, once /experiments gave one)
	// JS-set headers outside the standard set (if-none-match, cache-control,
	// x-failed-requests, x-audit-log-reason, x-discord-original-md5 ...).
	// Chrome places these first and moves sec-ch-ua-platform after x-installation-id.
	extra: []http.Header;
}

method_sends_content_length :: (method: string) -> bool {
	// Chrome sends Content-Length for POST/PUT/PATCH even with no body; not for GET/HEAD/DELETE.
	return method == "POST" || method == "PUT" || method == "PATCH";
}

method_sends_origin :: (method: string) -> bool {
	return method != "GET" && method != "HEAD";
}

itoa :: (n: int, allocator := temp) -> string {
	buf: [24]u8;
	return clone(strconv.write_int(view(buf), cast(s64)(n), 10), allocator);
}

// api_headers builds the header list for an authenticated discord.com/api request.
api_headers :: (p: Platform_Info, in_: Api_Headers_Input, allocator := temp) -> []http.Header {
	h := make_dynamic(http.Header, 0, 28, allocator);
	if method_sends_content_length(in_.method) || in_.has_body {
		append(*h, http.Header.{"content-length", itoa(in_.body_len, allocator)});
	}
	if len(in_.extra) > 0 {
		for e: in_.extra { append(*h, e); }
		if in_.token != "" { append(*h, http.Header.{"authorization", in_.token}); }
		if in_.installation_id != "" { append(*h, http.Header.{"x-installation-id", in_.installation_id}); }
		append(*h, http.Header.{"sec-ch-ua-platform", p.sec_ch_ua_platform});
	} else {
		append(*h, http.Header.{"sec-ch-ua-platform", p.sec_ch_ua_platform});
		if in_.token != "" { append(*h, http.Header.{"authorization", in_.token}); }
		if in_.installation_id != "" { append(*h, http.Header.{"x-installation-id", in_.installation_id}); }
	}
	if p.debug_options != "" { append(*h, http.Header.{"x-debug-options", p.debug_options}); }
	append(*h, http.Header.{"accept-language", p.accept_language});
	append(*h, http.Header.{"sec-ch-ua", p.sec_ch_ua});
	append(*h, http.Header.{"sec-ch-ua-mobile", "?0"});
	if p.timezone != "" { append(*h, http.Header.{"x-discord-timezone", p.timezone}); }
	if in_.context_b64 != "" { append(*h, http.Header.{"x-context-properties", in_.context_b64}); }
	if in_.super_props_b64 != "" { append(*h, http.Header.{"x-super-properties", in_.super_props_b64}); }
	append(*h, http.Header.{"x-discord-locale", p.locale});
	append(*h, http.Header.{"user-agent", p.browser_user_agent});
	if in_.content_type != "" { append(*h, http.Header.{"content-type", in_.content_type}); }
	// set last by the HTTP util (after Content-Type in DevTools' list; fixture login_submit)
	if in_.fingerprint != "" { append(*h, http.Header.{"x-fingerprint", in_.fingerprint}); }
	append(*h, http.Header.{"accept", "*/*"});
	if method_sends_origin(in_.method) { append(*h, http.Header.{"origin", API_ORIGIN}); }
	append(*h, http.Header.{"sec-fetch-site", "same-origin"});
	append(*h, http.Header.{"sec-fetch-mode", "cors"});
	append(*h, http.Header.{"sec-fetch-dest", "empty"});
	append(*h, http.Header.{"referer", in_.referer});
	append(*h, http.Header.{"accept-encoding", ACCEPT_ENCODING});
	if in_.cookie != "" { append(*h, http.Header.{"cookie", in_.cookie}); }
	append(*h, http.Header.{"priority", XHR_PRIORITY});
	return view(h);
}

Fetch_Site :: enum u8 {
	Same_Origin;
	Same_Site;
	Cross_Site;
}

fetch_site_name :: (s: Fetch_Site) -> string {
	if s == {
	case .Same_Origin;
		return "same-origin";
	case .Same_Site;
		return "same-site";
	case .Cross_Site;
		return "cross-site";
	}
	return "";
}

Web_Headers_Input :: struct {
	method: string;
	site: Fetch_Site;
	referer: string; // cross-origin requests get the origin only ("https://discord.com/")
	cookie: string;
	content_type: string;
	body_len: int;
	has_body: bool;
	js_headers: []http.Header; // set by the page (cache-control, if-none-match...)
	cache_validator: []http.Header; // added by Chrome's HTTP cache (if-none-match / if-modified-since)
	accept: string; // "" = */*
}

// web_headers builds an unauthenticated XHR/fetch request (status page,
// cdn json, version.stable.json, latency.discord.media...).
web_headers :: (p: Platform_Info, in_: Web_Headers_Input, allocator := temp) -> []http.Header {
	h := make_dynamic(http.Header, 0, 20, allocator);
	if method_sends_content_length(in_.method) || in_.has_body {
		append(*h, http.Header.{"content-length", itoa(in_.body_len, allocator)});
	}
	for e: in_.js_headers { append(*h, e); }
	append(*h, http.Header.{"sec-ch-ua-platform", p.sec_ch_ua_platform});
	append(*h, http.Header.{"user-agent", p.browser_user_agent});
	append(*h, http.Header.{"sec-ch-ua", p.sec_ch_ua});
	if in_.content_type != "" { append(*h, http.Header.{"content-type", in_.content_type}); }
	append(*h, http.Header.{"sec-ch-ua-mobile", "?0"});
	append(*h, http.Header.{"accept", ifx in_.accept != "" then in_.accept else "*/*"});
	if in_.site != .Same_Origin || method_sends_origin(in_.method) { append(*h, http.Header.{"origin", API_ORIGIN}); }
	append(*h, http.Header.{"sec-fetch-site", fetch_site_name(in_.site)});
	append(*h, http.Header.{"sec-fetch-mode", "cors"});
	append(*h, http.Header.{"sec-fetch-dest", "empty"});
	append(*h, http.Header.{"referer", in_.referer});
	append(*h, http.Header.{"accept-encoding", ACCEPT_ENCODING});
	append(*h, http.Header.{"accept-language", p.accept_language});
	if in_.cookie != "" { append(*h, http.Header.{"cookie", in_.cookie}); }
	for e: in_.cache_validator { append(*h, e); }
	append(*h, http.Header.{"priority", XHR_PRIORITY});
	return view(h);
}

// preflight_headers: CORS preflight Chrome sends before a cross-origin PUT
// (attachment upload to storage.googleapis.com).
// no_cache: the actual request is fetch(cache:'no-cache'), so Chrome sends
// cache-control: max-age=0 first on the preflight too.
preflight_headers :: (p: Platform_Info, method: string, request_headers: string, no_cache: bool, allocator := temp) -> []http.Header {
	h := make_dynamic(http.Header, 0, 13, allocator);
	if no_cache { append(*h, http.Header.{"cache-control", "max-age=0"}); }
	append(*h, http.Header.{"accept", "*/*"});
	append(*h, http.Header.{"access-control-request-method", method});
	if request_headers != "" { append(*h, http.Header.{"access-control-request-headers", request_headers}); }
	append(*h, http.Header.{"origin", API_ORIGIN});
	append(*h, http.Header.{"user-agent", p.browser_user_agent});
	append(*h, http.Header.{"sec-fetch-mode", "cors"});
	append(*h, http.Header.{"sec-fetch-site", "cross-site"});
	append(*h, http.Header.{"sec-fetch-dest", "empty"});
	append(*h, http.Header.{"referer", API_ORIGIN + "/"});
	append(*h, http.Header.{"accept-encoding", ACCEPT_ENCODING});
	append(*h, http.Header.{"accept-language", p.accept_language});
	append(*h, http.Header.{"priority", XHR_PRIORITY});
	return view(h);
}

// upload_put_headers: the cross-site XHR PUT of the file body to the upload_url.
upload_put_headers :: (p: Platform_Info, body_len: int, allocator := temp) -> []http.Header {
	h := make_dynamic(http.Header, 0, 16, allocator);
	append(*h, http.Header.{"content-length", itoa(body_len, allocator)});
	append(*h, http.Header.{"sec-ch-ua-platform", p.sec_ch_ua_platform});
	append(*h, http.Header.{"user-agent", p.browser_user_agent});
	append(*h, http.Header.{"sec-ch-ua", p.sec_ch_ua});
	append(*h, http.Header.{"content-type", "application/octet-stream"});
	append(*h, http.Header.{"sec-ch-ua-mobile", "?0"});
	append(*h, http.Header.{"accept", "*/*"});
	append(*h, http.Header.{"origin", API_ORIGIN});
	append(*h, http.Header.{"sec-fetch-site", "cross-site"});
	append(*h, http.Header.{"sec-fetch-mode", "cors"});
	append(*h, http.Header.{"sec-fetch-dest", "empty"});
	append(*h, http.Header.{"referer", API_ORIGIN + "/"});
	append(*h, http.Header.{"accept-encoding", ACCEPT_ENCODING});
	append(*h, http.Header.{"accept-language", p.accept_language});
	append(*h, http.Header.{"priority", XHR_PRIORITY});
	return view(h);
}

// gateway_ws_headers: the HTTP/1.1 upgrade request exactly as Chrome writes it.
// Sec-WebSocket-Key is filled by http.ws_connect (empty value = generate).
gateway_ws_headers :: (p: Platform_Info, host: string, cookie: string, allocator := temp) -> []http.Header {
	h := make_dynamic(http.Header, 0, 14, allocator);
	append(*h, http.Header.{"Host", host});
	append(*h, http.Header.{"Connection", "Upgrade"});
	append(*h, http.Header.{"Pragma", "no-cache"});
	append(*h, http.Header.{"Cache-Control", "no-cache"});
	append(*h, http.Header.{"User-Agent", p.browser_user_agent});
	append(*h, http.Header.{"Upgrade", "websocket"});
	append(*h, http.Header.{"Origin", API_ORIGIN});
	append(*h, http.Header.{"Sec-WebSocket-Version", "13"});
	append(*h, http.Header.{"Accept-Encoding", ACCEPT_ENCODING});
	append(*h, http.Header.{"Accept-Language", p.accept_language});
	if cookie != "" { append(*h, http.Header.{"Cookie", cookie}); }
	append(*h, http.Header.{"Sec-WebSocket-Key", ""});
	append(*h, http.Header.{"Sec-WebSocket-Extensions", "permessage-deflate; client_max_window_bits"});
	return view(h);
}

// referer_for_route: the client's referer is the current window location.
referer_for_route :: (guild_id: Snowflake, channel_id: Snowflake, allocator := temp) -> string {
	if channel_id == 0 && guild_id == 0 { return API_ORIGIN + "/channels/@me"; }
	g := ifx guild_id == 0 then "@me" else snowflake_string(guild_id);
	if channel_id == 0 { return strings.concatenate(.{API_ORIGIN, "/channels/", g}, allocator); }
	return strings.concatenate(.{API_ORIGIN, "/channels/", g, "/", snowflake_string(channel_id)}, allocator);
}

