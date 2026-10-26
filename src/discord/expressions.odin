package discord

import "core:encoding/base64"
import "core:mem/virtual"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import "fc:http"
import "fc:protobuf"

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

GIF_MEDIA_FORMAT :: "webm"

Expr_Op :: enum u8 {
	Gif_Trending,
	Gif_Trending_Gifs,
	Gif_Search,
	Gif_Suggest,
	Gif_Select,
	Sticker_Packs,
	Top_Emojis,
	Frecency,
	Media, // raw bytes (lottie json, svg) through the media cache
	Profile_Modal, // full profile modal (tag = user id)
	Mutual_Friends,
	App_Identities,
}

Expr_Result :: struct {
	op:           Expr_Op,
	tag:          u64,
	query:        string, // owned (client allocator): search query / media url
	ok:           bool,
	status:       int,
	body:         V, // API body (lives in arena)
	arena:        ^virtual.Arena,
	data:         []byte, // Media (owned)
	content_type: string, // Media (owned)
}

@(private = "file")
Expr_Job :: struct {
	op:      Expr_Op,
	tag:     u64,
	method:  string,
	path:    string,
	body:    string,
	query:   string,
	kind:    Media_Kind,
	client:  ^Client,
}

@(private = "file")
Expr_Pool :: struct {
	mu:      sync.Mutex,
	cond:    sync.Cond,
	jobs:    [dynamic]Expr_Job,
	results: [dynamic]Expr_Result,
	threads: [dynamic]^thread.Thread,
	owner:   ^Client,
}

@(private = "file")
pool: Expr_Pool

EXPR_THREADS :: 3

@(private = "file")
expr_worker :: proc(_: rawptr) {
	for {
		sync.mutex_lock(&pool.mu)
		for len(pool.jobs) == 0 {
			if pool.owner == nil || pool.owner.quit {
				sync.mutex_unlock(&pool.mu)
				return
			}
			sync.cond_wait_with_timeout(&pool.cond, &pool.mu, 500 * time.Millisecond)
		}
		j := pool.jobs[0]
		ordered_remove(&pool.jobs, 0)
		sync.mutex_unlock(&pool.mu)
		if j.client.quit {
			expr_job_free(&j)
			continue
		}
		expr_run(&j)
		expr_job_free(&j)
		free_all(context.temp_allocator)
	}
}

@(private = "file")
expr_job_free :: proc(j: ^Expr_Job) {
	delete(j.method)
	delete(j.path)
	delete(j.body)
	delete(j.query)
}

@(private = "file")
expr_submit :: proc(c: ^Client, j: Expr_Job) {
	sync.mutex_lock(&pool.mu)
	defer sync.mutex_unlock(&pool.mu)
	if pool.owner != c {
		pool.owner = c
		clear(&pool.threads)
	}
	if len(pool.threads) == 0 {
		for _ in 0 ..< EXPR_THREADS {
			th := thread.create_and_start_with_data(nil, expr_worker, c.ctx)
			append(&pool.threads, th)
		}
	}
	jj := j
	jj.client = c
	jj.method = strings.clone(j.method)
	jj.path = strings.clone(j.path)
	jj.body = strings.clone(j.body)
	jj.query = strings.clone(j.query)
	append(&pool.jobs, jj)
	sync.cond_signal(&pool.cond)
}

@(private = "file")
expr_deliver :: proc(c: ^Client, r: Expr_Result) {
	sync.mutex_lock(&pool.mu)
	append(&pool.results, r)
	sync.mutex_unlock(&pool.mu)
	if c.cfg.wakeup != nil do c.cfg.wakeup(c.cfg.wakeup_data)
}

@(private = "file")
expr_run :: proc(j: ^Expr_Job) {
	c := j.client
	res := Expr_Result{op = j.op, tag = j.tag, query = strings.clone(j.query, c.allocator)}
	if j.op == .Media {
		data, ctype, status := expr_media_get(c, j.query, j.kind)
		res.status = status
		res.ok = status == 200
		if len(data) > 0 {
			res.data = make([]byte, len(data), c.allocator)
			copy(res.data, data)
		}
		res.content_type = strings.clone(ctype, c.allocator)
		expr_deliver(c, res)
		return
	}
	ctype := "application/json" if j.body != "" else ""
	r := api_call(c, j.method, j.path, transmute([]byte)j.body, ctype, "", nil, 0, 1)
	res.ok = r.ok
	res.status = r.status
	res.body = r.body
	res.arena = r.arena
	expr_deliver(c, res)
}

// expr_media_get: run_media's request (same headers, disk cache, revalidation)
// returning the bytes to the caller instead of the image queue.
@(private = "file")
expr_media_get :: proc(c: ^Client, url: string, kind: Media_Kind) -> (body: []byte, ctype: string, status: int) {
	host, path, ok := split_url(url)
	if !ok do return
	now := now_ms()
	entry, cached, have := cache_read(c, url)
	if have && entry.fresh_until > now do return cached, entry.content_type, entry.status
	site := site_for_host(host)
	referer := client_route_referer(c) if site == .Same_Origin else API_ORIGIN + "/"
	cookie := cookie_header(&c.jar, host, path, true, now)
	etag, lm := "", ""
	if have {
		etag = entry.etag
		lm = entry.last_modified
	}
	req := http.Request{method = "GET", scheme = "https", authority = host, path = path, headers = media_headers(c.id.platform, kind, site, true, referer, cookie, etag, lm)}
	resp, err := transport_round_trip(&c.transport, host, req)
	defer http.response_destroy(&resp)
	if err != .None {
		if have do return cached, entry.content_type, entry.status
		return
	}
	now = now_ms()
	fresh, storable := freshness_ms(resp.headers[:], now)
	if resp.status == 304 && have {
		entry.fresh_until = fresh
		cache_write(c, url, entry, nil, false)
		return cached, entry.content_type, entry.status
	}
	ct, _ := http.header_get(resp.headers[:], "content-type")
	if resp.status == 200 && storable {
		e := Cache_Entry{status = 200, content_type = ct, fresh_until = fresh}
		e.etag, _ = http.header_get(resp.headers[:], "etag")
		e.last_modified, _ = http.header_get(resp.headers[:], "last-modified")
		cache_write(c, url, e, resp.body[:], true)
	}
	out := make([]byte, len(resp.body), context.temp_allocator)
	copy(out, resp.body[:])
	return out, strings.clone(ct, context.temp_allocator), resp.status
}

// expr_take returns finished expression requests (UI thread). Free each with expr_result_free.
expr_take :: proc(c: ^Client, allocator := context.temp_allocator) -> []Expr_Result {
	sync.mutex_lock(&pool.mu)
	defer sync.mutex_unlock(&pool.mu)
	out := make([]Expr_Result, len(pool.results), allocator)
	copy(out, pool.results[:])
	clear(&pool.results)
	return out
}

expr_result_free :: proc(c: ^Client, r: ^Expr_Result) {
	delete(r.query, c.allocator)
	delete(r.data, c.allocator)
	delete(r.content_type, c.allocator)
	if r.arena != nil {
		virtual.arena_destroy(r.arena)
		free(r.arena)
	}
	r^ = {}
}

@(private = "file")
expr_get :: proc(c: ^Client, op: Expr_Op, path: string, query := "", tag: u64 = 0) {
	expr_submit(c, Expr_Job{op = op, tag = tag, method = "GET", path = path, query = query})
}

@(private = "file")
locale_of :: proc(c: ^Client) -> string {
	if c.store.settings.locale != "" do return c.store.settings.locale
	return c.id.platform.locale
}

// gifs_trending: categories for the picker's front page (+ the first trending GIF as the tile preview).
gifs_trending :: proc(c: ^Client, tag: u64 = 0) {
	q: Query
	query_init(&q, "/gifs/trending")
	query_add(&q, "locale", locale_of(c))
	query_add(&q, "media_format", GIF_MEDIA_FORMAT)
	expr_get(c, .Gif_Trending, query_string(&q), "", tag)
}

// gifs_trending_gifs: the "Trending GIFs" tile. limit <= 0 is omitted (the tile passes undefined).
gifs_trending_gifs :: proc(c: ^Client, limit := 0, tag: u64 = 0) {
	q: Query
	query_init(&q, "/gifs/trending-gifs")
	query_add(&q, "media_format", GIF_MEDIA_FORMAT)
	query_add(&q, "locale", locale_of(c))
	if limit > 0 do query_add_int(&q, "limit", limit)
	expr_get(c, .Gif_Trending_Gifs, query_string(&q), "", tag)
}

// gifs_search: typed queries and category tiles. limit <= 0 is omitted.
gifs_search :: proc(c: ^Client, query: string, limit := 0, tag: u64 = 0) {
	q: Query
	query_init(&q, "/gifs/search")
	query_add(&q, "q", query)
	query_add(&q, "media_format", GIF_MEDIA_FORMAT)
	query_add(&q, "locale", locale_of(c))
	if limit > 0 do query_add_int(&q, "limit", limit)
	expr_get(c, .Gif_Search, query_string(&q), query, tag)
}

gifs_suggest :: proc(c: ^Client, query: string, tag: u64 = 0) {
	if query == "" do return
	q: Query
	query_init(&q, "/gifs/suggest")
	query_add(&q, "q", query)
	query_add_int(&q, "limit", 5)
	query_add(&q, "locale", locale_of(c))
	expr_get(c, .Gif_Suggest, query_string(&q), query, tag)
}

// gif_select: analytics ping after a GIF is sent ({id, q}; q is the result query).
gif_select :: proc(c: ^Client, gif_id: string, query: string) {
	if gif_id == "" do return
	w: Json
	json_init(&w)
	json_obj(&w)
	json_kstr(&w, "id", gif_id)
	json_kstr(&w, "q", query)
	json_obj_end(&w)
	expr_submit(c, Expr_Job{op = .Gif_Select, method = "POST", path = "/gifs/select", body = json_string(&w)})
}

sticker_packs_fetch :: proc(c: ^Client, tag: u64 = 0) {
	q: Query
	query_init(&q, "/sticker-packs")
	query_add(&q, "locale", locale_of(c))
	expr_get(c, .Sticker_Packs, query_string(&q), "", tag)
}

guild_top_emojis :: proc(c: ^Client, guild_id: Snowflake, tag: u64 = 0) {
	expr_get(c, .Top_Emojis, strings.concatenate({"/guilds/", snowflake_string(guild_id), "/top-emojis"}, context.temp_allocator), "", guild_id == 0 ? tag : u64(guild_id))
}

frecency_settings_fetch :: proc(c: ^Client, tag: u64 = 0) {
	expr_get(c, .Frecency, "/users/@me/settings-proto/2", "", tag)
}

// expr_fetch_media: bytes of a media URL (Fetch kind for lottie json, Image for svg).
expr_fetch_media :: proc(c: ^Client, url: string, kind := Media_Kind.Fetch, tag: u64 = 0) {
	expr_submit(c, Expr_Job{op = .Media, tag = tag, query = url, kind = kind})
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
	key:         string, // emoji name / custom emoji id / sticker id (decimal)
	total_uses:  int,
	recent_uses: []i64, // unix ms
	frecency:    int,
	score:       int,
}

Favorite_Gif :: struct {
	url:    string, // map key: the GIF page url
	src:    string,
	format: int, // GIFType: 1 image, 2 video
	width:  int,
	height: int,
	order:  int,
}

Frecency_Settings :: struct {
	emoji:             []Frecency_Item,
	emoji_reaction:    []Frecency_Item,
	sticker:           []Frecency_Item,
	favorite_emojis:   []string,
	favorite_stickers: []Snowflake,
	favorite_gifs:     []Favorite_Gif,
}

@(private = "file")
pb_varints :: proc(b: []byte, allocator := context.allocator) -> []i64 {
	out := make([dynamic]i64, allocator)
	r := protobuf.Reader{buf = b}
	for r.pos < len(r.buf) {
		v, ok := protobuf.read_varint(&r)
		if !ok do break
		append(&out, i64(v))
	}
	return out[:]
}

@(private = "file")
decode_item :: proc(b: []byte, key: string, allocator := context.allocator) -> Frecency_Item {
	it := Frecency_Item{key = strings.clone(key, allocator)}
	uses := make([dynamic]i64, allocator)
	r := protobuf.Reader{buf = b}
	for f in protobuf.next(&r) {
		switch f.num {
		case 1:
			it.total_uses = int(f.value)
		case 2:
			if f.wire == .Len do append(&uses, ..pb_varints(f.bytes, context.temp_allocator))
			else do append(&uses, i64(f.value))
		case 3:
			it.frecency = int(i32(f.value))
		case 4:
			it.score = int(i32(f.value))
		}
	}
	it.recent_uses = uses[:]
	return it
}

// map entries: {1 key, 2 value}; fixed64 keys become decimal strings.
@(private = "file")
decode_item_map :: proc(b: []byte, allocator := context.allocator) -> []Frecency_Item {
	out := make([dynamic]Frecency_Item, allocator)
	r := protobuf.Reader{buf = b}
	for f in protobuf.next(&r) {
		if f.num != 1 || f.wire != .Len do continue
		key := ""
		val: []byte
		er := protobuf.Reader{buf = f.bytes}
		for ef in protobuf.next(&er) {
			switch ef.num {
			case 1:
				if ef.wire == .Len do key = string(ef.bytes)
				else do key = snowflake_string(Snowflake(ef.value))
			case 2:
				val = ef.bytes
			}
		}
		append(&out, decode_item(val, key, allocator))
	}
	return out[:]
}

// frecency_settings_decode parses the base64 "settings" of GET /users/@me/settings-proto/2.
frecency_settings_decode :: proc(b64: string, allocator := context.allocator) -> (fs: Frecency_Settings, ok: bool) {
	raw, err := base64.decode(b64, allocator = context.temp_allocator)
	if err != nil do return
	r := protobuf.Reader{buf = raw}
	for f in protobuf.next(&r) {
		if f.wire != .Len do continue
		switch f.num {
		case 2:
			gifs := make([dynamic]Favorite_Gif, allocator)
			gr := protobuf.Reader{buf = f.bytes}
			for gf in protobuf.next(&gr) {
				if gf.num != 1 || gf.wire != .Len do continue
				g: Favorite_Gif
				er := protobuf.Reader{buf = gf.bytes}
				for ef in protobuf.next(&er) {
					switch ef.num {
					case 1:
						g.url = strings.clone(string(ef.bytes), allocator)
					case 2:
						vr := protobuf.Reader{buf = ef.bytes}
						for vf in protobuf.next(&vr) {
							switch vf.num {
							case 1:
								g.format = int(vf.value)
							case 2:
								g.src = strings.clone(string(vf.bytes), allocator)
							case 3:
								g.width = int(vf.value)
							case 4:
								g.height = int(vf.value)
							case 5:
								g.order = int(vf.value)
							}
						}
					}
				}
				append(&gifs, g)
			}
			fs.favorite_gifs = gifs[:]
		case 3:
			if ids, iok := protobuf.find(f.bytes, 1); iok {
				vals := protobuf.packed_fixed64(ids.bytes, context.temp_allocator)
				out := make([]Snowflake, len(vals), allocator)
				for v, i in vals do out[i] = Snowflake(v)
				fs.favorite_stickers = out
			}
		case 4:
			fs.sticker = decode_item_map(f.bytes, allocator)
		case 5:
			names := make([dynamic]string, allocator)
			er := protobuf.Reader{buf = f.bytes}
			for ef in protobuf.next(&er) do if ef.num == 1 do append(&names, strings.clone(string(ef.bytes), allocator))
			fs.favorite_emojis = names[:]
		case 6:
			fs.emoji = decode_item_map(f.bytes, allocator)
		case 13:
			fs.emoji_reaction = decode_item_map(f.bytes, allocator)
		}
	}
	return fs, true
}

// ---- full profile modal (UserProfileModalActionCreators) ----
// Opening the modal: GET /users/{id}/profile?type=modal&with_mutual_guilds=true
// &with_mutual_friends=false&with_mutual_friends_count=<!bot>[&guild_id=] and
// GET /users/{id}/application-identities?with_profiles=true (open_full_profile
// capture). The Mutual Friends tab: GET /users/{id}/relationships.

profile_modal_fetch :: proc(c: ^Client, user_id: Snowflake, guild_id: Snowflake = 0, bot := false) {
	q: Query
	query_init(&q, strings.concatenate({"/users/", snowflake_string(user_id), "/profile"}, context.temp_allocator))
	query_add(&q, "type", "modal")
	query_add_bool(&q, "with_mutual_guilds", true)
	query_add_bool(&q, "with_mutual_friends", false)
	query_add_bool(&q, "with_mutual_friends_count", !bot)
	if guild_id != 0 do query_add_snow(&q, "guild_id", guild_id)
	expr_get(c, .Profile_Modal, query_string(&q), "", u64(user_id))
	expr_get(c, .App_Identities, strings.concatenate({"/users/", snowflake_string(user_id), "/application-identities?with_profiles=true"}, context.temp_allocator), "", u64(user_id))
}

mutual_friends_fetch :: proc(c: ^Client, user_id: Snowflake) {
	expr_get(c, .Mutual_Friends, strings.concatenate({"/users/", snowflake_string(user_id), "/relationships"}, context.temp_allocator), "", u64(user_id))
}
