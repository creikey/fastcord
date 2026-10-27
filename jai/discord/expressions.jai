// Expression picker requests (GIFs, sticker packs, frecency), shaped like the
// official client's (bundle module 497685 "GIF actions", sticker actions,
// FrecencyUserSettingsManager). They go through api_call (same headers, rate
// limits, retries as every other REST call) but on a small pool of their own
// so the response body reaches the UI instead of being applied to the Store.
//
//   GET  /gifs/trending?locale=&media_format=           (picker opened: categories)
//   GET  /gifs/trending-gifs?media_format=&locale=      ("Trending GIFs" tile; limit omitted)
//   GET  /gifs/search?q=&media_format=&locale=[&limit=] (250 ms debounce while typing; limit omitted from tiles)
//   GET  /gifs/suggest?q=&limit=5&locale=               (scrolled near the end of results)
//   POST /gifs/select {"id","q"}                        (after sending a GIF)
//   GET  /sticker-packs?locale=
//   GET  /guilds/{id}/top-emojis
//   GET  /users/@me/settings-proto/2                    (FrecencyUserSettings, lazy)
//
// media_format is the GIFPickerViewStore's selected format: "webm" except on
// Linux ("tinywebp"). Query keys are in the client's object-literal order.

GIF_MEDIA_FORMAT :: "webm";

Expr_Op :: enum u8 {
	Gif_Trending;
	Gif_Trending_Gifs;
	Gif_Search;
	Gif_Suggest;
	Gif_Select;
	Sticker_Packs;
	Top_Emojis;
	Frecency;
	Media; // raw bytes (lottie json, svg) through the media cache
	Profile_Modal; // full profile modal (tag = user id)
	Mutual_Friends;
	App_Identities;
}

Expr_Result :: struct {
	op: Expr_Op;
	tag: u64;
	query: string; // owned (client allocator): search query / media url
	ok: bool;
	status: int;
	body: V; // API body (lives in arena)
	arena: *virtual.Arena;
	data: []u8; // Media (owned)
	content_type: string; // Media (owned)
}
#scope_file

Expr_Job :: struct {
	op: Expr_Op;
	tag: u64;
	method: string;
	path: string;
	body: string;
	query: string;
	kind: Media_Kind;
	client: *Client;
}

Expr_Pool :: struct {
	mu: locks.Mutex;
	cond: locks.Cond;
	jobs: [..]Expr_Job;
	results: [..]Expr_Result;
	threads: [..]*Thread;
	owner: *Client;
}

pool: Expr_Pool;
#scope_export

EXPR_THREADS :: 3;
#scope_file

expr_worker :: (_: *void) {
	while true {
		locks.lock(*pool.mu);
		while len(pool.jobs) == 0 {
			if pool.owner == null || pool.owner.quit {
				locks.unlock(*pool.mu);
				return;
			}
			locks.cond_wait_with_timeout(*pool.cond, *pool.mu, 500);
		}
		j := get(pool.jobs, 0);
		ordered_remove(*pool.jobs, 0);
		locks.unlock(*pool.mu);
		if j.client.quit {
			expr_job_free(*j);
			continue;
		}
		expr_run(*j);
		expr_job_free(*j);
		reset_temporary_storage();
	}
}

expr_job_free :: (j: *Expr_Job) {
	delete(j.method);
	delete(j.path);
	delete(j.body);
	delete(j.query);
}

expr_submit :: (c: *Client, j: Expr_Job) {
	locks.lock(*pool.mu);
	defer locks.unlock(*pool.mu);
	if pool.owner != c {
		pool.owner = c;
		clear(*pool.threads);
	}
	if len(pool.threads) == 0 {
		for _: 0..cast(int)(EXPR_THREADS)-1 {
			th := spawn(null, expr_worker);
			append(*pool.threads, th);
		}
	}
	jj := j;
	jj.client = c;
	jj.method = clone(j.method);
	jj.path = clone(j.path);
	jj.body = clone(j.body);
	jj.query = clone(j.query);
	append(*pool.jobs, jj);
	locks.cond_signal(*pool.cond);
}
#scope_export

// expr_pool_stop joins the expression workers serving c and frees its queued jobs and unread
// results. client_destroy calls it after setting quit and before freeing c.
expr_pool_stop :: (c: *Client) {
	locks.lock(*pool.mu);
	if pool.owner != c {
		locks.unlock(*pool.mu);
		return;
	}
	threads := pool.threads;
	pool.threads = zero(type_of(pool.threads));
	pool.owner = null;
	locks.cond_broadcast(*pool.cond);
	locks.unlock(*pool.mu);
	for th: threads {
		locks.join(th);
	}
	delete(threads);
	for * j: pool.jobs { expr_job_free(j); }
	clear(*pool.jobs);
	for * r: pool.results { expr_result_free(c, r); }
	clear(*pool.results);
}
#scope_file

expr_deliver :: (c: *Client, r: Expr_Result) {
	locks.lock(*pool.mu);
	append(*pool.results, r);
	locks.unlock(*pool.mu);
	if c.cfg.wakeup != null { c.cfg.wakeup(c.cfg.wakeup_data); }
}

expr_run :: (j: *Expr_Job) {
	c := j.client;
	res := Expr_Result.{op = j.op, tag = j.tag, query = clone(j.query, c.allocator)};
	if j.op == .Media {
		data, ctype, status := expr_media_get(c, j.query, j.kind);
		res.status = status;
		res.ok = status == 200;
		if len(data) > 0 {
			res.data = make_slice(u8, len(data), c.allocator);
			copy(res.data, data);
		}
		res.content_type = clone(ctype, c.allocator);
		expr_deliver(c, res);
		return;
	}
	ctype := ifx j.body != "" then "application/json" else "";
	r := api_call(c, j.method, j.path, transmute([]u8, j.body), ctype, "", .[], 0, 1);
	res.ok = r.ok;
	res.status = r.status;
	res.body = r.body;
	res.arena = r.arena;
	expr_deliver(c, res);
}

// expr_media_get: run_media's request (same headers, disk cache, revalidation)
// returning the bytes to the caller instead of the image queue.
expr_media_get :: (c: *Client, url: string, kind: Media_Kind) -> []u8, string, int {
	body: []u8;
	ctype: string;
	status: int;
	host, path, ok := split_url(url);
	if !ok { return body, ctype, status; }
	now := now_ms();
	entry, cached, have := cache_read(c, url);
	if have && entry.fresh_until > now { return cached, entry.content_type, entry.status; }
	site := site_for_host(host);
	referer := ifx site == .Same_Origin then client_route_referer(c) else #run join(API_ORIGIN, "/");
	cookie := cookie_header(*c.jar, host, path, true, now);
	etag, lm := "", "";
	if have {
		etag = entry.etag;
		lm = entry.last_modified;
	}
	req := http.Request.{method = "GET", scheme = "https", authority = host, path = path, headers = media_headers(c.id.platform, kind, site, true, referer, cookie, etag, lm)};
	resp, err := transport_round_trip(*c.transport, host, req);
	defer http.response_destroy(*resp);
	if err != .None {
		if have { return cached, entry.content_type, entry.status; }
		return body, ctype, status;
	}
	now = now_ms();
	fresh, storable := freshness_ms(view(resp.headers), now);
	if resp.status == 304 && have {
		entry.fresh_until = fresh;
		cache_write(c, url, entry, .[], false);
		return cached, entry.content_type, entry.status;
	}
	ct, _ := http.header_get(view(resp.headers), "content-type");
	if resp.status == 200 && storable {
		e := Cache_Entry.{status = 200, content_type = ct, fresh_until = fresh};
		e.etag, _ = http.header_get(view(resp.headers), "etag");
		e.last_modified, _ = http.header_get(view(resp.headers), "last-modified");
		cache_write(c, url, e, view(resp.body), true);
	}
	out := make_slice(u8, len(resp.body), temp);
	copy(out, view(resp.body));
	return out, clone(ct, temp), resp.status;
}
#scope_export

// expr_take returns finished expression requests (UI thread). Free each with expr_result_free.
expr_take :: (c: *Client, allocator := temp) -> []Expr_Result {
	locks.lock(*pool.mu);
	defer locks.unlock(*pool.mu);
	out := make_slice(Expr_Result, len(pool.results), allocator);
	copy(out, view(pool.results));
	clear(*pool.results);
	return out;
}

expr_result_free :: (c: *Client, r: *Expr_Result) {
	delete(r.query, c.allocator);
	delete(r.data, c.allocator);
	delete(r.content_type, c.allocator);
	if r.arena != null {
		virtual.arena_destroy(r.arena);
		free(r.arena);
	}
	r.* = .{};
}
#scope_file

expr_get :: (c: *Client, op: Expr_Op, path: string, query := "", tag: u64 = 0) {
	expr_submit(c, Expr_Job.{op = op, tag = tag, method = "GET", path = path, query = query});
}

locale_of :: (c: *Client) -> string {
	if c.store.settings.locale != "" { return c.store.settings.locale; }
	return c.id.platform.locale;
}
#scope_export

// gifs_trending: categories for the picker's front page (+ the first trending GIF as the tile preview).
gifs_trending :: (c: *Client, tag: u64 = 0) {
	q: Query;
	query_init(*q, "/gifs/trending");
	query_add(*q, "locale", locale_of(c));
	query_add(*q, "media_format", GIF_MEDIA_FORMAT);
	expr_get(c, .Gif_Trending, query_string(*q), "", tag);
}

// gifs_trending_gifs: the "Trending GIFs" tile. limit <= 0 is omitted (the tile passes undefined).
gifs_trending_gifs :: (c: *Client, limit := 0, tag: u64 = 0) {
	q: Query;
	query_init(*q, "/gifs/trending-gifs");
	query_add(*q, "media_format", GIF_MEDIA_FORMAT);
	query_add(*q, "locale", locale_of(c));
	if limit > 0 { query_add_int(*q, "limit", limit); }
	expr_get(c, .Gif_Trending_Gifs, query_string(*q), "", tag);
}

// gifs_search: typed queries and category tiles. limit <= 0 is omitted.
gifs_search :: (c: *Client, query: string, limit := 0, tag: u64 = 0) {
	q: Query;
	query_init(*q, "/gifs/search");
	query_add(*q, "q", query);
	query_add(*q, "media_format", GIF_MEDIA_FORMAT);
	query_add(*q, "locale", locale_of(c));
	if limit > 0 { query_add_int(*q, "limit", limit); }
	expr_get(c, .Gif_Search, query_string(*q), query, tag);
}

gifs_suggest :: (c: *Client, query: string, tag: u64 = 0) {
	if query == "" { return; }
	q: Query;
	query_init(*q, "/gifs/suggest");
	query_add(*q, "q", query);
	query_add_int(*q, "limit", 5);
	query_add(*q, "locale", locale_of(c));
	expr_get(c, .Gif_Suggest, query_string(*q), query, tag);
}

// gif_select: analytics ping after a GIF is sent ({id, q}; q is the result query).
gif_select :: (c: *Client, gif_id: string, query: string) {
	if gif_id == "" { return; }
	w: Json;
	json_init(*w);
	json_obj(*w);
	json_kstr(*w, "id", gif_id);
	json_kstr(*w, "q", query);
	json_obj_end(*w);
	expr_submit(c, Expr_Job.{op = .Gif_Select, method = "POST", path = "/gifs/select", body = json_string(*w)});
}

sticker_packs_fetch :: (c: *Client, tag: u64 = 0) {
	q: Query;
	query_init(*q, "/sticker-packs");
	query_add(*q, "locale", locale_of(c));
	expr_get(c, .Sticker_Packs, query_string(*q), "", tag);
}

guild_top_emojis :: (c: *Client, guild_id: Snowflake, tag: u64 = 0) {
	expr_get(c, .Top_Emojis, strings.concatenate(string.["/guilds/", snowflake_string(guild_id), "/top-emojis"], temp), "", ifx guild_id == 0 then tag else cast(u64)(guild_id));
}

frecency_settings_fetch :: (c: *Client, tag: u64 = 0) {
	expr_get(c, .Frecency, "/users/@me/settings-proto/2", "", tag);
}

// expr_fetch_media: bytes of a media URL (Fetch kind for lottie json, Image for svg).
expr_fetch_media :: (c: *Client, url: string, kind := Media_Kind.Fetch, tag: u64 = 0) {
	expr_submit(c, Expr_Job.{op = .Media, tag = tag, query = url, kind = kind});
}

// ---- FrecencyUserSettings (settings-proto type 2) ----
// Field numbers from discord_protos.discord_users.v1.FrecencyUserSettings:
//   2 favorite_gifs {1 map<string,FavoriteGIF{1 format,2 src,3 width,4 height,5 order}>, 2 hide_tooltip}
//   3 favorite_stickers {1 repeated fixed64 (packed)}
//   4 sticker_frecency {1 map<fixed64,FrecencyItem>}
//   5 favorite_emojis {1 repeated string}
//   6 emoji_frecency {1 map<string,FrecencyItem>}
//   13 emoji_reaction_frecency (same shape as 6)
//   FrecencyItem {1 total_uses u32, 2 recent_uses repeated u64 (packed), 3 frecency i32, 4 score i32}

Frecency_Item :: struct {
	key: string; // emoji name / custom emoji id / sticker id (decimal)
	total_uses: int;
	recent_uses: []s64; // unix ms
	frecency: int;
	score: int;
}

Favorite_Gif :: struct {
	url: string; // map key: the GIF page url
	src: string;
	format: int; // GIFType: 1 image, 2 video
	width: int;
	height: int;
	order: int;
}

Frecency_Settings :: struct {
	emoji: []Frecency_Item;
	emoji_reaction: []Frecency_Item;
	sticker: []Frecency_Item;
	favorite_emojis: []string;
	favorite_stickers: []Snowflake;
	favorite_gifs: []Favorite_Gif;
}
#scope_file

pb_varints :: (b: []u8, allocator := context.allocator) -> []s64 {
	out := make_dynamic(s64, 0, 0, allocator);
	r := protobuf.Reader.{buf = b};
	while r.pos < len(r.buf) {
		v, ok := protobuf.read_varint(*r);
		if !ok { break; }
		append(*out, cast(s64)(v));
	}
	return view(out);
}

decode_item :: (b: []u8, key: string, allocator := context.allocator) -> Frecency_Item {
	it_ := Frecency_Item.{key = clone(key, allocator)};
	uses := make_dynamic(s64, 0, 0, allocator);
	r := protobuf.Reader.{buf = b};
	while true { f, __ok1 := protobuf.next(*r); if !__ok1 break;
		if f.num == {
		case 1;
			it_.total_uses = cast(int)(f.value);
		case 2;
			if f.wire == .Len { append(*uses, ..pb_varints(f.bytes, temp)); } else { append(*uses, cast(s64)(f.value)); }
		case 3;
			it_.frecency = cast(int)(cast(s32)(f.value));
		case 4;
			it_.score = cast(int)(cast(s32)(f.value));
		}
	}
	it_.recent_uses = view(uses);
	return it_;
}

// map entries: {1 key, 2 value}; fixed64 keys become decimal strings.
decode_item_map :: (b: []u8, allocator := context.allocator) -> []Frecency_Item {
	out := make_dynamic(Frecency_Item, 0, 0, allocator);
	r := protobuf.Reader.{buf = b};
	while true { f, __ok3 := protobuf.next(*r); if !__ok3 break;
		if f.num != 1 || f.wire != .Len { continue; }
		key := "";
		val: []u8;
		er := protobuf.Reader.{buf = f.bytes};
		while true { ef, __ok4 := protobuf.next(*er); if !__ok4 break;
			if ef.num == {
			case 1;
				if ef.wire == .Len { key = as_string(ef.bytes); } else { key = snowflake_string(cast(Snowflake)(ef.value)); }
			case 2;
				val = ef.bytes;
			}
		}
		append(*out, decode_item(val, key, allocator));
	}
	return view(out);
}
#scope_export

// frecency_settings_decode parses the base64 "settings" of GET /users/@me/settings-proto/2.
frecency_settings_decode :: (b64: string, allocator := context.allocator) -> Frecency_Settings, bool {
	fs: Frecency_Settings;
	ok: bool;
	raw, err := base64.decode(b64, allocator = temp);
	if err != null { return fs, ok; }
	r := protobuf.Reader.{buf = raw};
	while true { f, __ok6 := protobuf.next(*r); if !__ok6 break;
		if f.wire != .Len { continue; }
		if f.num == {
		case 2;
			gifs := make_dynamic(Favorite_Gif, 0, 0, allocator);
			gr := protobuf.Reader.{buf = f.bytes};
			while true { gf, __ok8 := protobuf.next(*gr); if !__ok8 break;
				if gf.num != 1 || gf.wire != .Len { continue; }
				g: Favorite_Gif;
				er := protobuf.Reader.{buf = gf.bytes};
				while true { ef, __ok9 := protobuf.next(*er); if !__ok9 break;
					if ef.num == {
					case 1;
						g.url = clone(as_string(ef.bytes), allocator);
					case 2;
						vr := protobuf.Reader.{buf = ef.bytes};
						while true { vf, __ok11 := protobuf.next(*vr); if !__ok11 break;
							if vf.num == {
							case 1;
								g.format = cast(int)(vf.value);
							case 2;
								g.src = clone(as_string(vf.bytes), allocator);
							case 3;
								g.width = cast(int)(vf.value);
							case 4;
								g.height = cast(int)(vf.value);
							case 5;
								g.order = cast(int)(vf.value);
							}
						}
					}
				}
				append(*gifs, g);
			}
			fs.favorite_gifs = view(gifs);
		case 3;
			{ ids, iok := protobuf.find(f.bytes, 1);
			if iok {
				vals := protobuf.packed_fixed64(ids.bytes,, temp);
				out := make_slice(Snowflake, len(vals), allocator);
				for v, i: vals { at(*out, i).* = cast(Snowflake)(v); }
				fs.favorite_stickers = out;
			} }
		case 4;
			fs.sticker = decode_item_map(f.bytes, allocator);
		case 5;
			names := make_dynamic(string, 0, 0, allocator);
			er := protobuf.Reader.{buf = f.bytes};
			while true { ef, __ok13 := protobuf.next(*er); if !__ok13 break; if ef.num == 1 { append(*names, clone(as_string(ef.bytes), allocator)); } }
			fs.favorite_emojis = view(names);
		case 6;
			fs.emoji = decode_item_map(f.bytes, allocator);
		case 13;
			fs.emoji_reaction = decode_item_map(f.bytes, allocator);
		}
	}
	return fs, true;
}

// ---- full profile modal (UserProfileModalActionCreators) ----
// Opening the modal: GET /users/{id}/profile?type=modal&with_mutual_guilds=true
// &with_mutual_friends=false&with_mutual_friends_count=<!bot>[&guild_id=] and
// GET /users/{id}/application-identities?with_profiles=true (open_full_profile
// capture). The Mutual Friends tab: GET /users/{id}/relationships.

profile_modal_fetch :: (c: *Client, user_id: Snowflake, guild_id: Snowflake = 0, bot := false) {
	q: Query;
	query_init(*q, strings.concatenate(string.["/users/", snowflake_string(user_id), "/profile"], temp));
	query_add(*q, "type", "modal");
	query_add_bool(*q, "with_mutual_guilds", true);
	query_add_bool(*q, "with_mutual_friends", false);
	query_add_bool(*q, "with_mutual_friends_count", !bot);
	if guild_id != 0 { query_add_snow(*q, "guild_id", guild_id); }
	expr_get(c, .Profile_Modal, query_string(*q), "", cast(u64)(user_id));
	expr_get(c, .App_Identities, strings.concatenate(string.["/users/", snowflake_string(user_id), "/application-identities?with_profiles=true"], temp), "", cast(u64)(user_id));
}

mutual_friends_fetch :: (c: *Client, user_id: Snowflake) {
	expr_get(c, .Mutual_Friends, strings.concatenate(string.["/users/", snowflake_string(user_id), "/relationships"], temp), "", cast(u64)(user_id));
}

