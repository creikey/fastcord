// Media loading, the way Chromium loads the official client's <img>, CSS
// fonts and fetch()ed media: no auth headers, per-origin pools
// (cdn.discordapp.com, media.discordapp.net, discord.com/assets ...) via the
// shared Transport, and an on-disk HTTP cache with Cache-Control / Expires
// freshness and ETag / Last-Modified revalidation (so repeated launches don't
// refetch). Header orders are from netlog captures (see media_headers).

Media_Kind :: enum u8 {
	Image; // <img>: no-cors, dest image
	Font; // @font-face from the app CSS: cors, dest font
	Fetch; // fetch()/XHR of media json/text (lottie stickers, .riv): cors, dest empty
	Audio; // new Audio(url) (UI sounds): no-cors, dest audio, identity encoding, range bytes=0- (206)
}

Media_Request :: struct {
	url: string;
	kind: Media_Kind;
	visible: bool; // in-viewport images are boosted to priority "u=1, i"; others "i"
	referer: string; // fonts: the stylesheet URL; "" -> https://discord.com/ (cross-site) or route
	tag: u64;
}

Media_Result :: struct {
	tag: u64;
	url: string; // owned (client allocator)
	status: int; // 200 (also for cache hits / 304 revalidations), 0 network error
	from_cache: bool;
	content_type: string; // owned
	data: []u8; // owned
}

media_result_free :: (c: *Client, r: *Media_Result) {
	delete(r.url, c.allocator);
	delete(r.content_type, c.allocator);
	delete(r.data, c.allocator);
	r.* = .{};
}

IMAGE_ACCEPT :: "image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8";

// media_headers: captured orders.
//   image cross-site: sec-ch-ua-platform,user-agent,sec-ch-ua,sec-ch-ua-mobile,accept,sec-fetch-site,
//     sec-fetch-mode(no-cors),sec-fetch-dest(image),sec-fetch-storage-access,referer,accept-encoding,
//     accept-language,cookie,if-none-match,if-modified-since,priority
//   image same-origin: same without sec-fetch-storage-access; cookie after accept-language
//   font: origin first, then platform..accept(*/*),site,cors,font,referer(css),..,cookie,priority u=0
//   fetch cross-site: ...,accept,origin,site,cors,empty,referer,...
media_headers :: (p: Platform_Info, kind: Media_Kind, site: Fetch_Site, visible: bool, referer: string, cookie: string, etag: string, last_modified: string, allocator := temp) -> []http.Header {
	h := make_dynamic(http.Header, 0, 20, allocator);
	if kind == .Audio {
		// netlog (join_voice_channel): /assets/<hash>.mp3 played by WebAudioSound
		append(*h, http.Header.{"sec-ch-ua-platform", p.sec_ch_ua_platform});
		append(*h, http.Header.{"accept-encoding", "identity;q=1, *;q=0"});
		append(*h, http.Header.{"user-agent", p.browser_user_agent});
		append(*h, http.Header.{"sec-ch-ua", p.sec_ch_ua});
		append(*h, http.Header.{"sec-ch-ua-mobile", "?0"});
		append(*h, http.Header.{"accept", "*/*"});
		append(*h, http.Header.{"sec-fetch-site", fetch_site_name(site)});
		append(*h, http.Header.{"sec-fetch-mode", "no-cors"});
		append(*h, http.Header.{"sec-fetch-dest", "audio"});
		append(*h, http.Header.{"referer", referer});
		append(*h, http.Header.{"accept-language", p.accept_language});
		if cookie != "" { append(*h, http.Header.{"cookie", cookie}); }
		append(*h, http.Header.{"range", "bytes=0-"});
		append(*h, http.Header.{"priority", "i"});
		return view(h);
	}
	if kind == .Font { append(*h, http.Header.{"origin", API_ORIGIN}); }
	append(*h, http.Header.{"sec-ch-ua-platform", p.sec_ch_ua_platform});
	append(*h, http.Header.{"user-agent", p.browser_user_agent});
	append(*h, http.Header.{"sec-ch-ua", p.sec_ch_ua});
	append(*h, http.Header.{"sec-ch-ua-mobile", "?0"});
	if kind == {
	case .Image;
		append(*h, http.Header.{"accept", IMAGE_ACCEPT});
		append(*h, http.Header.{"sec-fetch-site", fetch_site_name(site)});
		append(*h, http.Header.{"sec-fetch-mode", "no-cors"});
		append(*h, http.Header.{"sec-fetch-dest", "image"});
		if site == .Cross_Site { append(*h, http.Header.{"sec-fetch-storage-access", ifx cookie != "" then "active" else "none"}); }
	case .Font;
		append(*h, http.Header.{"accept", "*/*"});
		append(*h, http.Header.{"sec-fetch-site", fetch_site_name(site)});
		append(*h, http.Header.{"sec-fetch-mode", "cors"});
		append(*h, http.Header.{"sec-fetch-dest", "font"});
	case .Audio;
	case .Fetch;
		append(*h, http.Header.{"accept", "*/*"});
		if site != .Same_Origin { append(*h, http.Header.{"origin", API_ORIGIN}); }
		append(*h, http.Header.{"sec-fetch-site", fetch_site_name(site)});
		append(*h, http.Header.{"sec-fetch-mode", "cors"});
		append(*h, http.Header.{"sec-fetch-dest", "empty"});
	}
	append(*h, http.Header.{"referer", referer});
	append(*h, http.Header.{"accept-encoding", ACCEPT_ENCODING});
	append(*h, http.Header.{"accept-language", p.accept_language});
	if cookie != "" { append(*h, http.Header.{"cookie", cookie}); }
	if etag != "" { append(*h, http.Header.{"if-none-match", etag}); }
	if last_modified != "" { append(*h, http.Header.{"if-modified-since", last_modified}); }
	prio := "i";
	if kind == .Font { prio = "u=0"; } else if kind == .Fetch || visible { prio = XHR_PRIORITY; }
	append(*h, http.Header.{"priority", prio});
	return view(h);
}
#scope_module

site_for_host :: (host: string) -> Fetch_Site {
	if host == API_HOST { return .Same_Origin; }
	if strings.has_suffix(host, ".discord.com") { return .Same_Site; }
	return .Cross_Site;
}
#scope_export

// fetch_media queues a media load; the result arrives via client_take_media
// after client_poll (or the wakeup).
fetch_media :: (c: *Client, req: Media_Request) {
	j := job_new(.Web, .Media);
	j.media = Media_Request.{url = job_str(j, req.url), kind = req.kind, visible = req.visible, referer = job_str(j, req.referer), tag = req.tag};
	j.result.tag = req.tag;
	job_submit(c, j);
}
#scope_module

// ---- disk cache ----

Cache_Entry :: struct {
	status: int;
	content_type: string;
	etag: string;
	last_modified: string;
	fresh_until: s64; // unix ms; 0 = must revalidate
}

cache_key :: (url: string) -> string {
	d := hash.hash_string(.SHA256, url, temp);
	return as_string(hex.encode(sub(d, 0, 16), temp));
}

cache_dir :: (c: *Client) -> string {
	if c.cfg.state_dir == "" { return ""; }
	return strings.concatenate(string.[c.cfg.state_dir, "/cache"], temp);
}

cache_read :: (c: *Client, url: string) -> Cache_Entry, []u8, bool {
	e: Cache_Entry;
	body: []u8;
	ok: bool;
	dir := cache_dir(c);
	if dir == "" { return e, body, ok; }
	k := cache_key(url);
	meta, merr := os.read_entire_file(strings.concatenate(string.[dir, "/", k, ".meta"], temp), temp);
	if !is_null(merr) { return e, body, ok; }
	data, derr := os.read_entire_file(strings.concatenate(string.[dir, "/", k, ".body"], temp), temp);
	if !is_null(derr) { return e, body, ok; }
	text := as_string(meta);
	while true { line, __ok2 := strings.split_lines_iterator(*text); if !__ok2 break;
		tab := strings.index_byte(line, 9);
		if tab < 0 { continue; }
		key, v := sub(line, 0, tab), sub_from(line, tab + 1);
		if key == {
		case "url";
			if v != url { return e, body, ok; } // hash collision guard
		case "status";
			e.status, _ = strconv.parse_int(v);
		case "content-type";
			e.content_type = v;
		case "etag";
			e.etag = v;
		case "last-modified";
			e.last_modified = v;
		case "fresh-until";
			e.fresh_until, _ = strconv.parse_i64(v);
		}
	}
	return e, data, true;
}

cache_write :: (c: *Client, url: string, e: Cache_Entry, body: []u8, write_body: bool) {
	dir := cache_dir(c);
	if dir == "" { return; }
	os.make_directory_all(dir);
	k := cache_key(url);
	sb := strings.builder_make(temp);
	strings.write_string(*sb, "url\t");
	strings.write_string(*sb, url);
	strings.write_string(*sb, "\nstatus\t");
	strings.write_int(*sb, e.status);
	strings.write_string(*sb, "\ncontent-type\t");
	strings.write_string(*sb, e.content_type);
	strings.write_string(*sb, "\netag\t");
	strings.write_string(*sb, e.etag);
	strings.write_string(*sb, "\nlast-modified\t");
	strings.write_string(*sb, e.last_modified);
	strings.write_string(*sb, "\nfresh-until\t");
	strings.write_i64(*sb, e.fresh_until);
	strings.write_byte(*sb, 10);
	if write_body { write_file_atomic(strings.concatenate(string.[dir, "/", k, ".body"], temp), body); }
	write_file_atomic(strings.concatenate(string.[dir, "/", k, ".meta"], temp), transmute([]u8, strings.to_string(sb)));
}
#scope_export

// freshness_ms: Cache-Control max-age (no-store/no-cache honoured), else Expires - Date,
// else Chrome's heuristic 10% of (Date - Last-Modified).
freshness_ms :: (headers: []http.Header, now: s64) -> s64, bool {
	fresh_until: s64;
	storable: bool;
	storable = true;
	{ cc, ok := http.header_get(headers, "cache-control");
	if ok {
		it_ := cc;
		while true { part, __ok4 := strings.split_iterator(*it_, ","); if !__ok4 break;
			d := strings.trim_space(part);
			ld := strings.to_lower(d, temp);
			if ld == "no-store" { return 0, false; }
			if ld == "no-cache" { return 0, true; }
			if strings.has_prefix(ld, "max-age=") {
				{ n, nok := strconv.parse_i64(sub_from(ld, 8));
				if nok { return now + n * 1000, true; } }
			}
		}
	} }
	date := now;
	{ ds, ok := http.header_get(headers, "date");
	if ok {
		{ dt, dok := parse_http_date(ds);
		if dok { date = dt; } }
	} }
	{ ex, ok := http.header_get(headers, "expires");
	if ok {
		{ et, eok := parse_http_date(ex);
		if eok { return now + (et - date), true; } }
		return 0, true;
	} }
	{ lm, ok := http.header_get(headers, "last-modified");
	if ok {
		{ lt, lok := parse_http_date(lm);
		if lok && lt < date { return now + (date - lt) / 10, true; } }
	} }
	return 0, true;
}
#scope_module

media_deliver :: (c: *Client, j: *Job, status: int, from_cache: bool, ctype: string, body: []u8) {
	r := Media_Result.{
		tag = j.media.tag,
		url = clone(j.media.url, c.allocator),
		status = status,
		from_cache = from_cache,
		content_type = clone(ctype, c.allocator)
	};
	if len(body) > 0 {
		r.data = make_slice(u8, len(body), c.allocator);
		copy(r.data, body);
	}
	locks.lock(*c.media_mu);
	append(*c.media_results, r);
	locks.unlock(*c.media_mu);
	if c.cfg.wakeup != null { c.cfg.wakeup(c.cfg.wakeup_data); }
}
#scope_export

// run_media executes a media job on a worker thread.
run_media :: (c: *Client, j: *Job) {
	url := j.media.url;
	host, path, ok := split_url(url);
	if !ok {
		media_deliver(c, j, 0, false, "", .[]);
		return;
	}
	now := now_ms();
	entry, cached, have := cache_read(c, url);
	if have && entry.fresh_until > now {
		media_deliver(c, j, entry.status, true, entry.content_type, cached);
		return;
	}
	site := site_for_host(host);
	referer := j.media.referer;
	if referer == "" { referer = ifx site == .Same_Origin then client_route_referer(c) else #run join(API_ORIGIN, "/"); }
	cookie := cookie_header(*c.jar, host, path, true, now);
	etag, lm := "", "";
	if have {
		etag = entry.etag;
		lm = entry.last_modified;
	}
	req := http.Request.{method = "GET", scheme = "https", authority = host, path = path, headers = media_headers(c.id.platform, j.media.kind, site, j.media.visible, referer, cookie, etag, lm)};
	resp, err := transport_round_trip(*c.transport, host, req);
	defer http.response_destroy(*resp);
	if err != .None {
		if have { media_deliver(c, j, entry.status, true, entry.content_type, cached); } else { media_deliver(c, j, 0, false, "", .[]); }
		return;
	}
	now = now_ms();
	fresh, storable := freshness_ms(view(resp.headers), now);
	if resp.status == 304 && have {
		entry.fresh_until = fresh;
		{ e2, eok := http.header_get(view(resp.headers), "etag");
		if eok { entry.etag = e2; } }
		cache_write(c, url, entry, .[], false);
		media_deliver(c, j, entry.status, true, entry.content_type, cached);
		return;
	}
	ctype, _ := http.header_get(view(resp.headers), "content-type");
	if resp.status == 200 && storable {
		e := Cache_Entry.{status = 200, content_type = ctype, fresh_until = fresh};
		e.etag, _ = http.header_get(view(resp.headers), "etag");
		e.last_modified, _ = http.header_get(view(resp.headers), "last-modified");
		cache_write(c, url, e, view(resp.body), true);
	}
	media_deliver(c, j, resp.status, false, ctype, view(resp.body));
}

// client_take_media returns finished media loads (UI thread). Free each with media_result_free.
client_take_media :: (c: *Client, allocator := temp) -> []Media_Result {
	locks.lock(*c.media_mu);
	defer locks.unlock(*c.media_mu);
	out := make_slice(Media_Result, len(c.media_results), allocator);
	copy(out, view(c.media_results));
	clear(*c.media_results);
	return out;
}

// ---- URL builders (shapes used by the official client's asset utils) ----

CDN :: "https://cdn.discordapp.com";
MEDIA_PROXY :: "https://media.discordapp.net";
#scope_module

size_q :: (size: int) -> string {return itoa(size);}
#scope_export

// avatar_url: animated hashes ("a_...") request webp with animated=true.
avatar_url :: (user_id: Snowflake, avatar_hash: string, size := 80, animate := false, allocator := temp) -> string {
	if avatar_hash == "" { return default_avatar_url(user_id, "0", allocator); }
	anim := animate && strings.has_prefix(avatar_hash, "a_");
	return strings.concatenate(string.[CDN, "/avatars/", snowflake_string(user_id), "/", avatar_hash, ".webp?size=", size_q(size), ifx anim then "&animated=true" else ""], allocator);
}

// default_avatar_url: pomelo users (discriminator "0") use (id >> 22) % 6, legacy discriminator % 5.
default_avatar_url :: (user_id: Snowflake, discriminator: string, allocator := temp) -> string {
	idx := 0;
	if discriminator == "0" || discriminator == "" {
		idx = cast(int)(((cast(u64)(user_id)) >> 22) % 6);
	} else {
		d, _ := strconv.parse_int(discriminator);
		idx = d % 5;
	}
	return strings.concatenate(string.[CDN, "/embed/avatars/", itoa(idx), ".png"], allocator);
}

guild_member_avatar_url :: (guild_id: Snowflake, user_id: Snowflake, hash_: string, size := 80, allocator := temp) -> string {
	return strings.concatenate(string.[CDN, "/guilds/", snowflake_string(guild_id), "/users/", snowflake_string(user_id), "/avatars/", hash_, ".webp?size=", size_q(size)], allocator);
}

guild_icon_url :: (guild_id: Snowflake, icon_hash: string, size := 96, animate := false, allocator := temp) -> string {
	if icon_hash == "" { return ""; }
	anim := animate && strings.has_prefix(icon_hash, "a_");
	return strings.concatenate(string.[CDN, "/icons/", snowflake_string(guild_id), "/", icon_hash, ".webp?size=", size_q(size), ifx anim then "&animated=true" else ""], allocator);
}

banner_url :: (id: Snowflake, banner_hash: string, size := 600, allocator := temp) -> string {
	if banner_hash == "" { return ""; }
	return strings.concatenate(string.[CDN, "/banners/", snowflake_string(id), "/", banner_hash, ".webp?size=", size_q(size)], allocator);
}

custom_emoji_url :: (emoji_id: Snowflake, animated: bool, size := 48, allocator := temp) -> string {
	return strings.concatenate(string.[CDN, "/emojis/", snowflake_string(emoji_id), ".webp?size=", size_q(size), ifx animated then "&animated=true" else ""], allocator);
}

// sticker_url: png/apng/gif through the media proxy; lottie (format 3) json from discord.com.
sticker_url :: (sticker_id: Snowflake, format_type: int, size := 160, allocator := temp) -> string {
	if format_type == {
	case 3;
		return strings.concatenate(string.[API_ORIGIN, "/stickers/", snowflake_string(sticker_id), ".json"], allocator);
	case 4;
		return strings.concatenate(string.[MEDIA_PROXY, "/stickers/", snowflake_string(sticker_id), ".gif?size=", size_q(size)], allocator);
	}
	return strings.concatenate(string.[MEDIA_PROXY, "/stickers/", snowflake_string(sticker_id), ".webp?size=", size_q(size)], allocator);
}

// media_proxy_url: resized attachment/embed images: proxy_url + format=webp&width=&height=.
media_proxy_url :: (proxy_url: string, width: int, height: int, allocator := temp) -> string {
	sep := ifx strings.contains(proxy_url, "?") then "&" else "?";
	if strings.has_suffix(proxy_url, "&") { sep = ""; }
	return strings.concatenate(string.[proxy_url, sep, "format=webp&width=", itoa(width), "&height=", itoa(height)], allocator);
}


// media_viewer_url: the full-size image the media viewer loads for an
// attachment (proxy_url + "=&format=webp&quality=lossless"; fixture open_image_attachment).
media_viewer_url :: (proxy_url: string, allocator := temp) -> string {
	sep := ifx strings.contains(proxy_url, "?") then "&" else "?";
	if strings.has_suffix(proxy_url, "&") { sep = ""; }
	return strings.concatenate(string.[proxy_url, sep, "=&format=webp&quality=lossless"], allocator);
}

