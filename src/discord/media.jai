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
	Video; // a <video> element's load: as Audio with dest video
}

Media_Request :: struct {
	url: string;
	kind: Media_Kind;
	visible: bool; // in-viewport images are boosted to priority "u=1, i"; others "i"
	referer: string; // fonts: the stylesheet URL; "" -> https://discord.com/ (cross-site) or route
	tag: u64;
	discard: bool; // loaded like the page does (cache included), then dropped: no result
	save_to: string; // set: a file download streamed to this path (no cache), see run_stream
	progress: *Media_Progress; // save_to's; the caller's, kept until the result arrives
	stream: http.Body_Sink; // set: the body goes here as it arrives (no cache), see run_stream; called on a worker
	any_host: bool; // a stream from an address the user chose to load (yt-dlp's), not only Discord's media hosts
	range_from: s64; // a <video>'s later range request: bytes=range_from- (a stream's moov after its media)
}

// A download's bytes so far, written by the worker and read by the UI thread.
Media_Progress :: struct {
	done: s64;
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
	push_allocator(c.allocator);
	free(r.url);
	free(r.content_type);
	array_free(r.data);
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
media_headers :: (p: Platform_Info, kind: Media_Kind, site: Fetch_Site, visible: bool, referer: string, cookie: string, etag: string, last_modified: string, allocator := temp, range_from: s64 = 0) -> []http.Header {
	h: [..]http.Header;
	h.allocator = allocator;
	array_reserve(*h, 20);
	add :: (name: string, value: string) #expand { array_add(*`h, .{name, value}); }
	if kind == .Audio || kind == .Video {
		// netlog (join_voice_channel): /assets/<hash>.mp3 played by WebAudioSound
		add("sec-ch-ua-platform", p.sec_ch_ua_platform);
		add("accept-encoding", "identity;q=1, *;q=0");
		add("user-agent", p.browser_user_agent);
		add("sec-ch-ua", p.sec_ch_ua);
		add("sec-ch-ua-mobile", "?0");
		add("accept", "*/*");
		add("sec-fetch-site", fetch_site_name(site));
		add("sec-fetch-mode", "no-cors");
		add("sec-fetch-dest", ifx kind == .Video then "video" else "audio");
		add("referer", referer);
		add("accept-language", p.accept_language);
		if cookie add("cookie", cookie);
		add("range", tprint("bytes=%-", range_from,, allocator));
		add("priority", "i");
		return h;
	}
	if kind == .Font add("origin", API_ORIGIN);
	add("sec-ch-ua-platform", p.sec_ch_ua_platform);
	add("user-agent", p.browser_user_agent);
	add("sec-ch-ua", p.sec_ch_ua);
	add("sec-ch-ua-mobile", "?0");
	if kind == {
		case .Image;
			add("accept", IMAGE_ACCEPT);
			add("sec-fetch-site", fetch_site_name(site));
			add("sec-fetch-mode", "no-cors");
			add("sec-fetch-dest", "image");
			if site == .Cross_Site add("sec-fetch-storage-access", ifx cookie then "active" else "none");
		case .Font;
			add("accept", "*/*");
			add("sec-fetch-site", fetch_site_name(site));
			add("sec-fetch-mode", "cors");
			add("sec-fetch-dest", "font");
		case .Fetch;
			add("accept", "*/*");
			if site != .Same_Origin add("origin", API_ORIGIN);
			add("sec-fetch-site", fetch_site_name(site));
			add("sec-fetch-mode", "cors");
			add("sec-fetch-dest", "empty");
	}
	add("referer", referer);
	add("accept-encoding", ACCEPT_ENCODING);
	add("accept-language", p.accept_language);
	if cookie add("cookie", cookie);
	if etag add("if-none-match", etag);
	if last_modified add("if-modified-since", last_modified);
	add("priority", ifx kind == .Font then "u=0" else ifx kind == .Fetch || visible then XHR_PRIORITY else "i");
	return h;
}

site_for_host :: (host: string) -> Fetch_Site {
	if host == API_HOST return .Same_Origin;
	if ends_with(host, ".discord.com") return .Same_Site;
	return .Cross_Site;
}

// fetch_media queues a media load; the result arrives via client_take_media
// after client_poll (or the wakeup).
fetch_media :: (c: *Client, req: Media_Request) {
	j := job_new(.Web, .Media);
	j.media = .{url = job_str(j, req.url), kind = req.kind, visible = req.visible, referer = job_str(j, req.referer), tag = req.tag, discard = req.discard, save_to = job_str(j, req.save_to), progress = req.progress, stream = req.stream, any_host = req.any_host, range_from = req.range_from};
	j.result.tag = req.tag;
	job_submit(c, j);
}

// ---- disk cache ----

// Cache_Entry: a cached URL's .meta file; the strings are views into it (temp).
Cache_Entry :: struct {
	status: int;
	content_type: string;
	etag: string;
	last_modified: string;
	fresh_until: s64; // unix ms; 0 = must revalidate
}

// cache_path: <state>/cache/<hex of sha256(url)[:16]><ext> (temp), "" without a state dir.
cache_path :: (c: *Client, url: string, ext: string) -> string {
	if !c.cfg.state_dir return "";
	d := crypto.sha256(cast([]u8) url);
	sb: String_Builder;
	sb.allocator = temp;
	print_to_builder(*sb, "%/cache/", c.cfg.state_dir);
	for 0..15 print_to_builder(*sb, "%", formatInt(d[it], base = 16, minimum_digits = 2));
	append(*sb, ext);
	return builder_to_string(*sb,, temp);
}

cache_read :: (c: *Client, url: string) -> Cache_Entry, []u8, bool {
	if !c.cfg.state_dir return .{}, .[], false;
	meta, mok := read_entire_file(cache_path(c, url, ".meta"), log_errors = false,, temp);
	if !mok return .{}, .[], false;
	data, dok := read_entire_file(cache_path(c, url, ".body"), log_errors = false,, temp);
	if !dok return .{}, .[], false;
	e: Cache_Entry;
	for line: split(meta, "\n",, temp) {
		found, key, v := split_from_left(line, #char "\t");
		if !found continue;
		if key == {
			case "url";           if v != url return .{}, .[], false; // hash collision guard
			case "status";        e.status = parse_s64(v);
			case "content-type";  e.content_type = v;
			case "etag";          e.etag = v;
			case "last-modified"; e.last_modified = v;
			case "fresh-until";   e.fresh_until = parse_s64(v);
		}
	}
	return e, cast([]u8) data, true;
}

cache_write :: (c: *Client, url: string, e: Cache_Entry, body: []u8, write_body: bool) {
	if !c.cfg.state_dir return;
	make_directory_if_it_does_not_exist(tprint("%/cache", c.cfg.state_dir), recursive = true);
	if write_body {
		write_file_atomic(cache_path(c, url, ".body"), body);
		if atomic_add(*c.cache_writes, 1) % CACHE_TRIM_EVERY == 0 cache_trim(tprint("%/cache", c.cfg.state_dir));
	}
	meta := tprint("url\t%\nstatus\t%\ncontent-type\t%\netag\t%\nlast-modified\t%\nfresh-until\t%\n", url, e.status, e.content_type, e.etag, e.last_modified, e.fresh_until);
	write_file_atomic(cache_path(c, url, ".meta"), cast([]u8) meta);
}

// The disk cache stays under CACHE_MAX_BYTES: past it, the files written longest ago go until it is down to
// three quarters (Chrome keeps its own cache bounded the same way). Checked at the first body written and
// every CACHE_TRIM_EVERY after, on the worker that wrote it.
CACHE_MAX_BYTES :: 512 << 20;
CACHE_TRIM_EVERY :: 200;
cache_trim :: (dir: string, max_bytes := CACHE_MAX_BYTES) {
	File :: struct { path: string; time: Apollo_Time; size: s64; }
	files: [..]File;
	files.allocator = temp;
	total: s64;
	for File_Utilities.file_list(dir,, temp) {
		t, size, ok := File_Utilities.file_modtime_and_size(it);
		if !ok continue;
		array_add(*files, .{it, t, size});
		total += size;
	}
	if total <= max_bytes return;
	quick_sort(files, (a: File, b: File) -> s64 { return ifx a.time < b.time then -1 else ifx a.time > b.time then 1 else 0; });
	for files {
		if total <= max_bytes / 4 * 3 break;
		if file_delete(it.path) total -= it.size; // a .body and its .meta go at about the same time
	}
}

// freshness_ms: Cache-Control max-age (no-store/no-cache honoured), else Expires - Date,
// else Chrome's heuristic 10% of (Date - Last-Modified).
freshness_ms :: (headers: []http.Header, now: s64) -> fresh_until: s64, storable: bool {
	cc, has_cc := http.header_get(headers, "cache-control");
	if has_cc for part: split(cc, ",",, temp) {
		d := to_lower_copy(trim(part),, temp);
		if d == "no-store" return 0, false;
		if d == "no-cache" return 0, true;
		if begins_with(d, "max-age=") {
			n, ok := parse_s64(advance(d, 8));
			if ok return now + n * 1000, true;
		}
	}
	date := now;
	ds, has_date := http.header_get(headers, "date");
	if has_date {
		dt, ok := parse_http_date(ds);
		if ok date = dt;
	}
	ex, has_expires := http.header_get(headers, "expires");
	if has_expires {
		et, ok := parse_http_date(ex);
		return ifx ok then now + (et - date) else 0, true;
	}
	lm, has_lm := http.header_get(headers, "last-modified");
	if has_lm {
		lt, ok := parse_http_date(lm);
		if ok && lt < date return now + (date - lt) / 10, true;
	}
	return 0, true;
}

// media_deliver hands a copy of the result (client allocator) to the UI thread.
media_deliver :: (c: *Client, j: *Job, status: int, from_cache: bool, ctype: string, body: []u8) {
	r := Media_Result.{tag = j.media.tag, status = status, from_cache = from_cache};
	r.url = copy_string(j.media.url,, c.allocator);
	r.content_type = copy_string(ctype,, c.allocator);
	if body r.data = array_copy(body,, c.allocator);
	locks.lock(*c.media_mu);
	array_add(*c.media_results, r);
	locks.unlock(*c.media_mu);
	if c.cfg.wakeup c.cfg.wakeup(c.cfg.wakeup_data);
}

// media_get loads url the way the page does (media_headers, disk cache, revalidation); worker
// thread. ctype and body are in temp. referer "" picks the route (same origin) or https://discord.com/.
media_get :: (c: *Client, url: string, kind: Media_Kind, visible: bool, referer: string) -> status: int, from_cache: bool, ctype: string, body: []u8 {
	host, path, ok := split_url(url);
	if !ok || !media_host_ok(c, host) return 0, false, "", .[];
	now := now_ms();
	entry, cached, have := cache_read(c, url);
	if have && entry.fresh_until > now return entry.status, true, entry.content_type, cached;
	site := site_for_host(host);
	ref := ifx referer then referer else ifx site == .Same_Origin then client_route_referer(c) else #run join(API_ORIGIN, "/");
	cookie := cookie_header(*c.jar, host, path, true, now);
	req := http.Request.{method = "GET", scheme = "https", authority = host, path = path, headers = media_headers(c.id.platform, kind, site, visible, ref, cookie, entry.etag, entry.last_modified)};
	resp, err := transport_round_trip(*c.transport, host, req);
	defer http.response_destroy(*resp);
	if err != .None {
		if have return entry.status, true, entry.content_type, cached;
		return 0, false, "", .[];
	}
	fresh, storable := freshness_ms(resp.headers, now_ms());
	if resp.status == 304 && have {
		entry.fresh_until = fresh;
		etag, has_etag := http.header_get(resp.headers, "etag");
		if has_etag entry.etag = etag;
		cache_write(c, url, entry, .[], false);
		return entry.status, true, entry.content_type, cached;
	}
	ctype := http.header_get(resp.headers, "content-type");
	if resp.status == 200 && storable {
		e := Cache_Entry.{status = 200, content_type = ctype, fresh_until = fresh};
		e.etag = http.header_get(resp.headers, "etag");
		e.last_modified = http.header_get(resp.headers, "last-modified");
		cache_write(c, url, e, resp.body, true);
	}
	return resp.status, false, copy_string(ctype,, temp), array_copy(resp.body,, temp);
}

// media_host_ok: media privacy. A URL a server sends can point anywhere, and fetching it shows the viewer's
// IP to whoever runs that host, so Discord's media loads only from Discord's own hosts (its CDN and media
// proxy, which fetches outside images for us), the GIF picker's Klipy (and Tenor) and Spotify's album art (a Listening
// activity's `spotify:` asset), as the official client's does.
// A hosted server's requests all reach the pinned server whatever the host (hosted_round_trip).
media_host_ok :: (c: *Client, host: string) -> bool {
	if c.cfg.hosted.host return true;
	return host == "discord.com" || ends_with(host, ".discord.com") || ends_with(host, ".discordapp.com")
		|| ends_with(host, ".discordapp.net") || host == "static.klipy.com" || host == "media.tenor.com" || host == "i.scdn.co"; // Spotify's album art, as the client loads it
}

// run_media executes a media job on a worker thread.
run_media :: (c: *Client, j: *Job) {
	if j.media.save_to || j.media.stream.take { run_stream(c, j); return; }
	status, from_cache, ctype, body := media_get(c, j.media.url, j.media.kind, j.media.visible, j.media.referer);
	if !j.media.discard media_deliver(c, j, status, from_cache, ctype, body);
}

// run_stream hands a body on as it arrives, with no disk cache and no data in the result. A file download
// (save_to) goes to that path, counted into progress, with the headers of a download the window starts
// (a navigation's, as Chrome's download manager sends); a failed one leaves no file. Otherwise the body
// goes to the request's stream sink, as a <video> or <audio> element loads (range bytes=0-, a 206).
run_stream :: (c: *Client, j: *Job) {
	m := *j.media;
	status := 0;
	host, path, ok := split_url(m.url);
	f: File;
	opened := false;
	if m.save_to f, opened = file_open(m.save_to, for_writing = true, log_errors = false);
	if (opened || !m.save_to) && ok && (media_host_ok(c, host) || (m.any_host && m.stream.take)) {
		Writer :: struct { f: *File; p: *Media_Progress; out: http.Body_Sink; ok := true; }
		w := Writer.{f = *f, p = m.progress, out = m.stream};
		take :: (data: *void, piece: []u8) -> bool {
			w := cast(*Writer) data;
			if w.out.take w.ok = w.ok && w.out.take(w.out.data, piece);
			else w.ok = w.ok && file_write(w.f, piece.data, piece.count);
			if w.p atomic_add(*w.p.done, piece.count);
			return w.ok;
		}
		now := now_ms();
		cookie := cookie_header(*c.jar, host, path, true, now);
		req := http.Request.{method = "GET", scheme = "https", authority = host, path = path, sink = .{*w, take}};
		if m.save_to req.headers = document_headers(c.id.platform, cookie);
		else {
			site := site_for_host(host);
			ref := ifx m.referer then m.referer else ifx site == .Same_Origin then client_route_referer(c) else #run join(API_ORIGIN, "/");
			req.headers = media_headers(c.id.platform, m.kind, site, m.visible, ref, cookie, "", "", range_from = m.range_from);
		}
		resp, err := transport_round_trip(*c.transport, host, req);
		if err == .None && resp.body take(*w, resp.body); // an encoded body, or a transport that doesn't sink
		if err == .None && w.ok status = ifx resp.status == 206 then 200 else resp.status;
		http.response_destroy(*resp);
	}
	if opened {
		file_close(*f);
		if status != 200 file_delete(m.save_to);
	}
	media_deliver(c, j, status, false, "", .[]);
}

// client_take_media returns finished media loads (UI thread). Free each with media_result_free.
client_take_media :: (c: *Client, allocator := temp) -> []Media_Result {
	locks.lock(*c.media_mu);
	defer locks.unlock(*c.media_mu);
	out := array_copy(c.media_results,, allocator);
	c.media_results.count = 0;
	return out;
}

// ---- URL builders (shapes used by the official client's asset utils) ----

CDN :: "https://cdn.discordapp.com";
MEDIA_PROXY :: "https://media.discordapp.net";

// avatar_url: animated hashes ("a_...") request webp with animated=true.
avatar_url :: (user_id: Snowflake, avatar_hash: string, size := 80, animate := false, allocator := temp) -> string {
	if !avatar_hash return default_avatar_url(user_id, "0", allocator);
	anim := animate && begins_with(avatar_hash, "a_");
	return sprint("%/avatars/%/%.webp?size=%%", CDN, user_id, avatar_hash, size, ifx anim then "&animated=true" else "",, allocator);
}

// default_avatar_url: pomelo users (discriminator "0") use (id >> 22) % 6, legacy discriminator % 5.
default_avatar_url :: (user_id: Snowflake, discriminator: string, allocator := temp) -> string {
	idx := ifx discriminator == "0" || !discriminator then cast(int) ((user_id >> 22) % 6) else parse_s64(discriminator) % 5;
	return sprint("%/embed/avatars/%.png", CDN, idx,, allocator);
}

guild_member_avatar_url :: (guild_id: Snowflake, user_id: Snowflake, hash_: string, size := 80, animate := false, allocator := temp) -> string {
	anim := animate && begins_with(hash_, "a_");
	return sprint("%/guilds/%/users/%/avatars/%.webp?size=%%", CDN, guild_id, user_id, hash_, size, ifx anim then "&animated=true" else "",, allocator);
}

guild_member_banner_url :: (guild_id: Snowflake, user_id: Snowflake, hash_: string, size := 600, allocator := temp) -> string {
	return sprint("%/guilds/%/users/%/banners/%.webp?size=%", CDN, guild_id, user_id, hash_, size,, allocator);
}

guild_icon_url :: (guild_id: Snowflake, icon_hash: string, size := 96, animate := false, allocator := temp) -> string {
	if !icon_hash return "";
	anim := animate && begins_with(icon_hash, "a_");
	return sprint("%/icons/%/%.webp?size=%%", CDN, guild_id, icon_hash, size, ifx anim then "&animated=true" else "",, allocator);
}

banner_url :: (id: Snowflake, banner_hash: string, size := 600, allocator := temp) -> string {
	if !banner_hash return "";
	return sprint("%/banners/%/%.webp?size=%", CDN, id, banner_hash, size,, allocator);
}

// clan_badge_url: a server tag's badge (getGuildTagBadgeUrl: /clan-badges/<guild>/<badge>.png).
clan_badge_url :: (guild_id: Snowflake, badge: string, size := 16, allocator := temp) -> string {
	return sprint("%/clan-badges/%/%.png?size=%", CDN, guild_id, badge, size,, allocator);
}

custom_emoji_url :: (emoji_id: Snowflake, animated: bool, size := 48, allocator := temp) -> string {
	return sprint("%/emojis/%.webp?size=%%", CDN, emoji_id, size, ifx animated then "&animated=true" else "",, allocator);
}

// sticker_url: png/apng/gif through the media proxy; lottie (format 3) json from discord.com.
sticker_url :: (sticker_id: Snowflake, format_type: int, size := 160, allocator := temp) -> string {
	if format_type == {
		case 3; return sprint("%/stickers/%.json", API_ORIGIN, sticker_id,, allocator);
		case 4; return sprint("%/stickers/%.gif?size=%", MEDIA_PROXY, sticker_id, size,, allocator);
		case 2; return sprint("%/stickers/%.png?size=%", MEDIA_PROXY, sticker_id, size,, allocator); // APNG: .webp would be a still
	}
	return sprint("%/stickers/%.webp?size=%", MEDIA_PROXY, sticker_id, size,, allocator);
}

// proxy_sep: how a query continues proxy_url ("&" after an existing query, "" after a trailing "&").
proxy_sep :: (proxy_url: string) -> string {
	if ends_with(proxy_url, "&") return "";
	return ifx contains(proxy_url, "?") then "&" else "?";
}

// media_proxy_url: resized attachment/embed images: proxy_url + format=webp&width=&height=.
media_proxy_url :: (proxy_url: string, width: int, height: int, allocator := temp) -> string {
	return sprint("%%format=webp&width=%&height=%", proxy_url, proxy_sep(proxy_url), width, height,, allocator);
}

// media_viewer_url: the full-size image the media viewer loads for an
// attachment (proxy_url + "=&format=webp&quality=lossless"; fixture open_image_attachment).
media_viewer_url :: (proxy_url: string, allocator := temp) -> string {
	return sprint("%%=&format=webp&quality=lossless", proxy_url, proxy_sep(proxy_url),, allocator);
}
