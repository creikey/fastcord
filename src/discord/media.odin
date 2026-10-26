package discord

import "core:crypto/hash"
import "core:encoding/hex"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "fc:http"

// Media loading, the way Chromium loads the official client's <img>, CSS
// fonts and fetch()ed media: no auth headers, per-origin pools
// (cdn.discordapp.com, media.discordapp.net, discord.com/assets ...) via the
// shared Transport, and an on-disk HTTP cache with Cache-Control / Expires
// freshness and ETag / Last-Modified revalidation (so repeated launches don't
// refetch). Header orders are from netlog captures (see media_headers).

Media_Kind :: enum u8 {
	Image, // <img>: no-cors, dest image
	Font, // @font-face from the app CSS: cors, dest font
	Fetch, // fetch()/XHR of media json/text (lottie stickers, .riv): cors, dest empty
	Audio, // new Audio(url) (UI sounds): no-cors, dest audio, identity encoding, range bytes=0- (206)
}

Media_Request :: struct {
	url:      string,
	kind:     Media_Kind,
	visible:  bool, // in-viewport images are boosted to priority "u=1, i"; others "i"
	referer:  string, // fonts: the stylesheet URL; "" -> https://discord.com/ (cross-site) or route
	tag:      u64,
}

Media_Result :: struct {
	tag:          u64,
	url:          string, // owned (client allocator)
	status:       int, // 200 (also for cache hits / 304 revalidations), 0 network error
	from_cache:   bool,
	content_type: string, // owned
	data:         []byte, // owned
}

media_result_free :: proc(c: ^Client, r: ^Media_Result) {
	delete(r.url, c.allocator)
	delete(r.content_type, c.allocator)
	delete(r.data, c.allocator)
	r^ = {}
}

IMAGE_ACCEPT :: "image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8"

// media_headers: captured orders.
//   image cross-site: sec-ch-ua-platform,user-agent,sec-ch-ua,sec-ch-ua-mobile,accept,sec-fetch-site,
//     sec-fetch-mode(no-cors),sec-fetch-dest(image),sec-fetch-storage-access,referer,accept-encoding,
//     accept-language,cookie,if-none-match,if-modified-since,priority
//   image same-origin: same without sec-fetch-storage-access; cookie after accept-language
//   font: origin first, then platform..accept(*/*),site,cors,font,referer(css),..,cookie,priority u=0
//   fetch cross-site: ...,accept,origin,site,cors,empty,referer,...
media_headers :: proc(p: Platform_Info, kind: Media_Kind, site: Fetch_Site, visible: bool, referer, cookie, etag, last_modified: string, allocator := context.temp_allocator) -> []http.Header {
	h := make([dynamic]http.Header, 0, 20, allocator)
	if kind == .Audio {
		// netlog (join_voice_channel): /assets/<hash>.mp3 played by WebAudioSound
		append(&h, http.Header{"sec-ch-ua-platform", p.sec_ch_ua_platform})
		append(&h, http.Header{"accept-encoding", "identity;q=1, *;q=0"})
		append(&h, http.Header{"user-agent", p.browser_user_agent})
		append(&h, http.Header{"sec-ch-ua", p.sec_ch_ua})
		append(&h, http.Header{"sec-ch-ua-mobile", "?0"})
		append(&h, http.Header{"accept", "*/*"})
		append(&h, http.Header{"sec-fetch-site", fetch_site_name(site)})
		append(&h, http.Header{"sec-fetch-mode", "no-cors"})
		append(&h, http.Header{"sec-fetch-dest", "audio"})
		append(&h, http.Header{"referer", referer})
		append(&h, http.Header{"accept-language", p.accept_language})
		if cookie != "" do append(&h, http.Header{"cookie", cookie})
		append(&h, http.Header{"range", "bytes=0-"})
		append(&h, http.Header{"priority", "i"})
		return h[:]
	}
	if kind == .Font do append(&h, http.Header{"origin", API_ORIGIN})
	append(&h, http.Header{"sec-ch-ua-platform", p.sec_ch_ua_platform})
	append(&h, http.Header{"user-agent", p.browser_user_agent})
	append(&h, http.Header{"sec-ch-ua", p.sec_ch_ua})
	append(&h, http.Header{"sec-ch-ua-mobile", "?0"})
	switch kind {
	case .Image:
		append(&h, http.Header{"accept", IMAGE_ACCEPT})
		append(&h, http.Header{"sec-fetch-site", fetch_site_name(site)})
		append(&h, http.Header{"sec-fetch-mode", "no-cors"})
		append(&h, http.Header{"sec-fetch-dest", "image"})
		if site == .Cross_Site do append(&h, http.Header{"sec-fetch-storage-access", "active" if cookie != "" else "none"})
	case .Font:
		append(&h, http.Header{"accept", "*/*"})
		append(&h, http.Header{"sec-fetch-site", fetch_site_name(site)})
		append(&h, http.Header{"sec-fetch-mode", "cors"})
		append(&h, http.Header{"sec-fetch-dest", "font"})
	case .Audio:
	case .Fetch:
		append(&h, http.Header{"accept", "*/*"})
		if site != .Same_Origin do append(&h, http.Header{"origin", API_ORIGIN})
		append(&h, http.Header{"sec-fetch-site", fetch_site_name(site)})
		append(&h, http.Header{"sec-fetch-mode", "cors"})
		append(&h, http.Header{"sec-fetch-dest", "empty"})
	}
	append(&h, http.Header{"referer", referer})
	append(&h, http.Header{"accept-encoding", ACCEPT_ENCODING})
	append(&h, http.Header{"accept-language", p.accept_language})
	if cookie != "" do append(&h, http.Header{"cookie", cookie})
	if etag != "" do append(&h, http.Header{"if-none-match", etag})
	if last_modified != "" do append(&h, http.Header{"if-modified-since", last_modified})
	prio := "i"
	if kind == .Font do prio = "u=0"
	else if kind == .Fetch || visible do prio = XHR_PRIORITY
	append(&h, http.Header{"priority", prio})
	return h[:]
}

@(private)
site_for_host :: proc(host: string) -> Fetch_Site {
	if host == API_HOST do return .Same_Origin
	if strings.has_suffix(host, ".discord.com") do return .Same_Site
	return .Cross_Site
}

// fetch_media queues a media load; the result arrives via client_take_media
// after client_poll (or the wakeup).
fetch_media :: proc(c: ^Client, req: Media_Request) {
	j := job_new(.Web, .Media)
	j.media = Media_Request{url = job_str(j, req.url), kind = req.kind, visible = req.visible, referer = job_str(j, req.referer), tag = req.tag}
	j.result.tag = req.tag
	job_submit(c, j)
}

// ---- disk cache ----

@(private)
Cache_Entry :: struct {
	status:        int,
	content_type:  string,
	etag:          string,
	last_modified: string,
	fresh_until:   i64, // unix ms; 0 = must revalidate
}

@(private)
cache_key :: proc(url: string) -> string {
	d := hash.hash_string(.SHA256, url, context.temp_allocator)
	return string(hex.encode(d[:16], context.temp_allocator))
}

@(private)
cache_dir :: proc(c: ^Client) -> string {
	if c.cfg.state_dir == "" do return ""
	return strings.concatenate({c.cfg.state_dir, "/cache"}, context.temp_allocator)
}

@(private)
cache_read :: proc(c: ^Client, url: string) -> (e: Cache_Entry, body: []byte, ok: bool) {
	dir := cache_dir(c)
	if dir == "" do return
	k := cache_key(url)
	meta, merr := os.read_entire_file(strings.concatenate({dir, "/", k, ".meta"}, context.temp_allocator), context.temp_allocator)
	if merr != nil do return
	data, derr := os.read_entire_file(strings.concatenate({dir, "/", k, ".body"}, context.temp_allocator), context.temp_allocator)
	if derr != nil do return
	text := string(meta)
	for line in strings.split_lines_iterator(&text) {
		tab := strings.index_byte(line, '\t')
		if tab < 0 do continue
		key, v := line[:tab], line[tab + 1:]
		switch key {
		case "url":
			if v != url do return // hash collision guard
		case "status":
			e.status, _ = strconv.parse_int(v)
		case "content-type":
			e.content_type = v
		case "etag":
			e.etag = v
		case "last-modified":
			e.last_modified = v
		case "fresh-until":
			e.fresh_until, _ = strconv.parse_i64(v)
		}
	}
	return e, data, true
}

@(private)
cache_write :: proc(c: ^Client, url: string, e: Cache_Entry, body: []byte, write_body: bool) {
	dir := cache_dir(c)
	if dir == "" do return
	_ = os.make_directory_all(dir)
	k := cache_key(url)
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, "url\t")
	strings.write_string(&sb, url)
	strings.write_string(&sb, "\nstatus\t")
	strings.write_int(&sb, e.status)
	strings.write_string(&sb, "\ncontent-type\t")
	strings.write_string(&sb, e.content_type)
	strings.write_string(&sb, "\netag\t")
	strings.write_string(&sb, e.etag)
	strings.write_string(&sb, "\nlast-modified\t")
	strings.write_string(&sb, e.last_modified)
	strings.write_string(&sb, "\nfresh-until\t")
	strings.write_i64(&sb, e.fresh_until)
	strings.write_byte(&sb, '\n')
	if write_body do write_file_atomic(strings.concatenate({dir, "/", k, ".body"}, context.temp_allocator), body)
	write_file_atomic(strings.concatenate({dir, "/", k, ".meta"}, context.temp_allocator), transmute([]byte)strings.to_string(sb))
}

// freshness_ms: Cache-Control max-age (no-store/no-cache honoured), else Expires - Date,
// else Chrome's heuristic 10% of (Date - Last-Modified).
freshness_ms :: proc(headers: []http.Header, now: i64) -> (fresh_until: i64, storable: bool) {
	storable = true
	if cc, ok := http.header_get(headers, "cache-control"); ok {
		it := cc
		for part in strings.split_iterator(&it, ",") {
			d := strings.trim_space(part)
			ld := strings.to_lower(d, context.temp_allocator)
			if ld == "no-store" do return 0, false
			if ld == "no-cache" do return 0, true
			if strings.has_prefix(ld, "max-age=") {
				if n, nok := strconv.parse_i64(ld[8:]); nok do return now + n * 1000, true
			}
		}
	}
	date := now
	if ds, ok := http.header_get(headers, "date"); ok {
		if dt, dok := parse_http_date(ds); dok do date = dt
	}
	if ex, ok := http.header_get(headers, "expires"); ok {
		if et, eok := parse_http_date(ex); eok do return now + (et - date), true
		return 0, true
	}
	if lm, ok := http.header_get(headers, "last-modified"); ok {
		if lt, lok := parse_http_date(lm); lok && lt < date do return now + (date - lt) / 10, true
	}
	return 0, true
}

@(private)
media_deliver :: proc(c: ^Client, j: ^Job, status: int, from_cache: bool, ctype: string, body: []byte) {
	r := Media_Result{
		tag = j.media.tag,
		url = strings.clone(j.media.url, c.allocator),
		status = status,
		from_cache = from_cache,
		content_type = strings.clone(ctype, c.allocator),
	}
	if len(body) > 0 {
		r.data = make([]byte, len(body), c.allocator)
		copy(r.data, body)
	}
	sync.mutex_lock(&c.media_mu)
	append(&c.media_results, r)
	sync.mutex_unlock(&c.media_mu)
	if c.cfg.wakeup != nil do c.cfg.wakeup(c.cfg.wakeup_data)
}

// run_media executes a media job on a worker thread.
run_media :: proc(c: ^Client, j: ^Job) {
	url := j.media.url
	host, path, ok := split_url(url)
	if !ok {
		media_deliver(c, j, 0, false, "", nil)
		return
	}
	now := now_ms()
	entry, cached, have := cache_read(c, url)
	if have && entry.fresh_until > now {
		media_deliver(c, j, entry.status, true, entry.content_type, cached)
		return
	}
	site := site_for_host(host)
	referer := j.media.referer
	if referer == "" do referer = client_route_referer(c) if site == .Same_Origin else API_ORIGIN + "/"
	cookie := cookie_header(&c.jar, host, path, true, now)
	etag, lm := "", ""
	if have {
		etag = entry.etag
		lm = entry.last_modified
	}
	req := http.Request{method = "GET", scheme = "https", authority = host, path = path, headers = media_headers(c.id.platform, j.media.kind, site, j.media.visible, referer, cookie, etag, lm)}
	resp, err := transport_round_trip(&c.transport, host, req)
	defer http.response_destroy(&resp)
	if err != .None {
		if have do media_deliver(c, j, entry.status, true, entry.content_type, cached)
		else do media_deliver(c, j, 0, false, "", nil)
		return
	}
	now = now_ms()
	fresh, storable := freshness_ms(resp.headers[:], now)
	if resp.status == 304 && have {
		entry.fresh_until = fresh
		if e2, eok := http.header_get(resp.headers[:], "etag"); eok do entry.etag = e2
		cache_write(c, url, entry, nil, false)
		media_deliver(c, j, entry.status, true, entry.content_type, cached)
		return
	}
	ctype, _ := http.header_get(resp.headers[:], "content-type")
	if resp.status == 200 && storable {
		e := Cache_Entry{status = 200, content_type = ctype, fresh_until = fresh}
		e.etag, _ = http.header_get(resp.headers[:], "etag")
		e.last_modified, _ = http.header_get(resp.headers[:], "last-modified")
		cache_write(c, url, e, resp.body[:], true)
	}
	media_deliver(c, j, resp.status, false, ctype, resp.body[:])
}

// client_take_media returns finished media loads (UI thread). Free each with media_result_free.
client_take_media :: proc(c: ^Client, allocator := context.temp_allocator) -> []Media_Result {
	sync.mutex_lock(&c.media_mu)
	defer sync.mutex_unlock(&c.media_mu)
	out := make([]Media_Result, len(c.media_results), allocator)
	copy(out, c.media_results[:])
	clear(&c.media_results)
	return out
}

// ---- URL builders (shapes used by the official client's asset utils) ----

CDN :: "https://cdn.discordapp.com"
MEDIA_PROXY :: "https://media.discordapp.net"

@(private)
size_q :: proc(size: int) -> string {return itoa(size)}

// avatar_url: animated hashes ("a_...") request webp with animated=true.
avatar_url :: proc(user_id: Snowflake, avatar_hash: string, size := 80, animate := false, allocator := context.temp_allocator) -> string {
	if avatar_hash == "" do return default_avatar_url(user_id, "0", allocator)
	anim := animate && strings.has_prefix(avatar_hash, "a_")
	return strings.concatenate({CDN, "/avatars/", snowflake_string(user_id), "/", avatar_hash, ".webp?size=", size_q(size), "&animated=true" if anim else ""}, allocator)
}

// default_avatar_url: pomelo users (discriminator "0") use (id >> 22) % 6, legacy discriminator % 5.
default_avatar_url :: proc(user_id: Snowflake, discriminator: string, allocator := context.temp_allocator) -> string {
	idx := 0
	if discriminator == "0" || discriminator == "" {
		idx = int((u64(user_id) >> 22) % 6)
	} else {
		d, _ := strconv.parse_int(discriminator)
		idx = d % 5
	}
	return strings.concatenate({CDN, "/embed/avatars/", itoa(idx), ".png"}, allocator)
}

guild_member_avatar_url :: proc(guild_id, user_id: Snowflake, hash_: string, size := 80, allocator := context.temp_allocator) -> string {
	return strings.concatenate({CDN, "/guilds/", snowflake_string(guild_id), "/users/", snowflake_string(user_id), "/avatars/", hash_, ".webp?size=", size_q(size)}, allocator)
}

guild_icon_url :: proc(guild_id: Snowflake, icon_hash: string, size := 96, animate := false, allocator := context.temp_allocator) -> string {
	if icon_hash == "" do return ""
	anim := animate && strings.has_prefix(icon_hash, "a_")
	return strings.concatenate({CDN, "/icons/", snowflake_string(guild_id), "/", icon_hash, ".webp?size=", size_q(size), "&animated=true" if anim else ""}, allocator)
}

banner_url :: proc(id: Snowflake, banner_hash: string, size := 600, allocator := context.temp_allocator) -> string {
	if banner_hash == "" do return ""
	return strings.concatenate({CDN, "/banners/", snowflake_string(id), "/", banner_hash, ".webp?size=", size_q(size)}, allocator)
}

custom_emoji_url :: proc(emoji_id: Snowflake, animated: bool, size := 48, allocator := context.temp_allocator) -> string {
	return strings.concatenate({CDN, "/emojis/", snowflake_string(emoji_id), ".webp?size=", size_q(size), "&animated=true" if animated else ""}, allocator)
}

// sticker_url: png/apng/gif through the media proxy; lottie (format 3) json from discord.com.
sticker_url :: proc(sticker_id: Snowflake, format_type: int, size := 160, allocator := context.temp_allocator) -> string {
	switch format_type {
	case 3:
		return strings.concatenate({API_ORIGIN, "/stickers/", snowflake_string(sticker_id), ".json"}, allocator)
	case 4:
		return strings.concatenate({MEDIA_PROXY, "/stickers/", snowflake_string(sticker_id), ".gif?size=", size_q(size)}, allocator)
	}
	return strings.concatenate({MEDIA_PROXY, "/stickers/", snowflake_string(sticker_id), ".webp?size=", size_q(size)}, allocator)
}

// media_proxy_url: resized attachment/embed images: proxy_url + format=webp&width=&height=.
media_proxy_url :: proc(proxy_url: string, width, height: int, allocator := context.temp_allocator) -> string {
	sep := "&" if strings.contains(proxy_url, "?") else "?"
	if strings.has_suffix(proxy_url, "&") do sep = ""
	return strings.concatenate({proxy_url, sep, "format=webp&width=", itoa(width), "&height=", itoa(height)}, allocator)
}

