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

itoa :: (n: int) -> string { return tprint("%", n); }

// api_headers builds the header list for an authenticated discord.com/api request.
api_headers :: (p: Platform_Info, in_: Api_Headers_Input) -> []http.Header {
	h: [..]http.Header;
	h.allocator = temp;
	array_reserve(*h, 28);
	if method_sends_content_length(in_.method) || in_.has_body {
		array_add(*h, .{"content-length", itoa(in_.body_len)});
	}
	if in_.extra {
		array_add(*h, ..in_.extra);
		if in_.token array_add(*h, .{"authorization", in_.token});
		if in_.installation_id array_add(*h, .{"x-installation-id", in_.installation_id});
		array_add(*h, .{"sec-ch-ua-platform", p.sec_ch_ua_platform});
	} else {
		array_add(*h, .{"sec-ch-ua-platform", p.sec_ch_ua_platform});
		if in_.token array_add(*h, .{"authorization", in_.token});
		if in_.installation_id array_add(*h, .{"x-installation-id", in_.installation_id});
	}
	if p.debug_options array_add(*h, .{"x-debug-options", p.debug_options});
	array_add(*h, .{"accept-language", p.accept_language});
	array_add(*h, .{"sec-ch-ua", p.sec_ch_ua});
	array_add(*h, .{"sec-ch-ua-mobile", "?0"});
	if p.timezone array_add(*h, .{"x-discord-timezone", p.timezone});
	if in_.context_b64 array_add(*h, .{"x-context-properties", in_.context_b64});
	if in_.super_props_b64 array_add(*h, .{"x-super-properties", in_.super_props_b64});
	array_add(*h, .{"x-discord-locale", p.locale});
	array_add(*h, .{"user-agent", p.browser_user_agent});
	if in_.content_type array_add(*h, .{"content-type", in_.content_type});
	// set last by the HTTP util (after Content-Type in DevTools' list; fixture login_submit)
	if in_.fingerprint array_add(*h, .{"x-fingerprint", in_.fingerprint});
	array_add(*h, .{"accept", "*/*"});
	if method_sends_origin(in_.method) { array_add(*h, .{"origin", API_ORIGIN}); }
	array_add(*h, .{"sec-fetch-site", "same-origin"});
	array_add(*h, .{"sec-fetch-mode", "cors"});
	array_add(*h, .{"sec-fetch-dest", "empty"});
	array_add(*h, .{"referer", in_.referer});
	array_add(*h, .{"accept-encoding", ACCEPT_ENCODING});
	if in_.cookie array_add(*h, .{"cookie", in_.cookie});
	array_add(*h, .{"priority", XHR_PRIORITY});
	return h;
}

Fetch_Site :: enum u8 {
	Same_Origin;
	Same_Site;
	Cross_Site;
}

fetch_site_name :: (s: Fetch_Site) -> string {
	return string.["same-origin", "same-site", "cross-site"][s];
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
web_headers :: (p: Platform_Info, in_: Web_Headers_Input) -> []http.Header {
	h: [..]http.Header;
	h.allocator = temp;
	array_reserve(*h, 20);
	if method_sends_content_length(in_.method) || in_.has_body {
		array_add(*h, .{"content-length", itoa(in_.body_len)});
	}
	array_add(*h, ..in_.js_headers);
	array_add(*h, .{"sec-ch-ua-platform", p.sec_ch_ua_platform});
	array_add(*h, .{"user-agent", p.browser_user_agent});
	array_add(*h, .{"sec-ch-ua", p.sec_ch_ua});
	if in_.content_type array_add(*h, .{"content-type", in_.content_type});
	array_add(*h, .{"sec-ch-ua-mobile", "?0"});
	array_add(*h, .{"accept", ifx in_.accept then in_.accept else "*/*"});
	if in_.site != .Same_Origin || method_sends_origin(in_.method) { array_add(*h, .{"origin", API_ORIGIN}); }
	array_add(*h, .{"sec-fetch-site", fetch_site_name(in_.site)});
	array_add(*h, .{"sec-fetch-mode", "cors"});
	array_add(*h, .{"sec-fetch-dest", "empty"});
	array_add(*h, .{"referer", in_.referer});
	array_add(*h, .{"accept-encoding", ACCEPT_ENCODING});
	array_add(*h, .{"accept-language", p.accept_language});
	if in_.cookie array_add(*h, .{"cookie", in_.cookie});
	array_add(*h, ..in_.cache_validator);
	array_add(*h, .{"priority", XHR_PRIORITY});
	return h;
}

// preflight_headers: CORS preflight Chrome sends before a cross-origin PUT
// (attachment upload to storage.googleapis.com).
// no_cache: the actual request is fetch(cache:'no-cache'), so Chrome sends
// cache-control: max-age=0 first on the preflight too.
preflight_headers :: (p: Platform_Info, method: string, request_headers: string, no_cache: bool) -> []http.Header {
	h: [..]http.Header;
	h.allocator = temp;
	array_reserve(*h, 13);
	if no_cache { array_add(*h, .{"cache-control", "max-age=0"}); }
	array_add(*h, .{"accept", "*/*"});
	array_add(*h, .{"access-control-request-method", method});
	if request_headers array_add(*h, .{"access-control-request-headers", request_headers});
	array_add(*h, .{"origin", API_ORIGIN});
	array_add(*h, .{"user-agent", p.browser_user_agent});
	array_add(*h, .{"sec-fetch-mode", "cors"});
	array_add(*h, .{"sec-fetch-site", "cross-site"});
	array_add(*h, .{"sec-fetch-dest", "empty"});
	array_add(*h, .{"referer", #run join(API_ORIGIN, "/")});
	array_add(*h, .{"accept-encoding", ACCEPT_ENCODING});
	array_add(*h, .{"accept-language", p.accept_language});
	array_add(*h, .{"priority", XHR_PRIORITY});
	return h;
}

// upload_put_headers: the cross-site XHR PUT of the file body to the upload_url.
upload_put_headers :: (p: Platform_Info, body_len: int) -> []http.Header {
	h: [..]http.Header;
	h.allocator = temp;
	array_reserve(*h, 16);
	array_add(*h, .{"content-length", itoa(body_len)});
	array_add(*h, .{"sec-ch-ua-platform", p.sec_ch_ua_platform});
	array_add(*h, .{"user-agent", p.browser_user_agent});
	array_add(*h, .{"sec-ch-ua", p.sec_ch_ua});
	array_add(*h, .{"content-type", "application/octet-stream"});
	array_add(*h, .{"sec-ch-ua-mobile", "?0"});
	array_add(*h, .{"accept", "*/*"});
	array_add(*h, .{"origin", API_ORIGIN});
	array_add(*h, .{"sec-fetch-site", "cross-site"});
	array_add(*h, .{"sec-fetch-mode", "cors"});
	array_add(*h, .{"sec-fetch-dest", "empty"});
	array_add(*h, .{"referer", #run join(API_ORIGIN, "/")});
	array_add(*h, .{"accept-encoding", ACCEPT_ENCODING});
	array_add(*h, .{"accept-language", p.accept_language});
	array_add(*h, .{"priority", XHR_PRIORITY});
	return h;
}

// gateway_ws_headers: the HTTP/1.1 upgrade request exactly as Chrome writes it.
// Sec-WebSocket-Key is filled by http.ws_connect (empty value = generate).
gateway_ws_headers :: (p: Platform_Info, host: string, cookie: string) -> []http.Header {
	h: [..]http.Header;
	h.allocator = temp;
	array_reserve(*h, 14);
	array_add(*h, .{"Host", host});
	array_add(*h, .{"Connection", "Upgrade"});
	array_add(*h, .{"Pragma", "no-cache"});
	array_add(*h, .{"Cache-Control", "no-cache"});
	array_add(*h, .{"User-Agent", p.browser_user_agent});
	array_add(*h, .{"Upgrade", "websocket"});
	array_add(*h, .{"Origin", API_ORIGIN});
	array_add(*h, .{"Sec-WebSocket-Version", "13"});
	array_add(*h, .{"Accept-Encoding", ACCEPT_ENCODING});
	array_add(*h, .{"Accept-Language", p.accept_language});
	if cookie array_add(*h, .{"Cookie", cookie});
	array_add(*h, .{"Sec-WebSocket-Key", ""});
	array_add(*h, .{"Sec-WebSocket-Extensions", "permessage-deflate; client_max_window_bits"});
	return h;
}

// referer_for_route: the client's referer is the current window location.
referer_for_route :: (guild_id: Snowflake, channel_id: Snowflake, allocator := temp) -> string {
	if channel_id == 0 && guild_id == 0 return #run join(API_ORIGIN, "/channels/@me");
	g := ifx guild_id == 0 then "@me" else snowflake_string(guild_id);
	if channel_id == 0 return join(API_ORIGIN, "/channels/", g,, allocator);
	return join(API_ORIGIN, "/channels/", g, "/", snowflake_string(channel_id),, allocator);
}

