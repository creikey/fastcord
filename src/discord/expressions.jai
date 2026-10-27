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
	arena: *Flat_Pool;
	data: []u8; // Media (owned)
	content_type: string; // Media (owned)
}

// Expr_Job: a queued request; its strings are owned by the client's allocator.
Expr_Job :: struct {
	op: Expr_Op;
	tag: u64;
	method: string;
	path: string;
	body: string;
	query: string;
	kind: Media_Kind;
}

// Expr_Pool: one per client (tests run several at once), made on its first request and
// stopped by expr_pool_stop. Everything in it is in the client's allocator.
Expr_Pool :: struct {
	client: *Client;
	mu: locks.Mutex;
	cond: locks.Cond;
	jobs: [..]Expr_Job;
	results: [..]Expr_Result;
	threads: [EXPR_THREADS]*Thread;
	stop: bool;
}

EXPR_THREADS :: 3;

expr_pools_mu: locks.Mutex;
expr_pools: Table(*Client, *Expr_Pool); // under expr_pools_mu

expr_pool_of :: (c: *Client, create: bool) -> *Expr_Pool {
	locks.lock(*expr_pools_mu);
	defer locks.unlock(*expr_pools_mu);
	found, p := table_find(*expr_pools, c);
	if found || !create return p;
	push_allocator(c.allocator);
	p = New(Expr_Pool);
	p.client = c;
	p.jobs.allocator = c.allocator;
	p.results.allocator = c.allocator;
	if !expr_pools.allocator.proc expr_pools.allocator = context.default_allocator;
	table_set(*expr_pools, c, p);
	for * p.threads it.* = spawn(p, expr_worker);
	return p;
}

expr_worker :: (p: *Expr_Pool) {
	locks.lock(*p.mu);
	while !p.stop {
		if !p.jobs.count {
			locks.cond_wait(*p.cond, *p.mu);
			continue;
		}
		j := p.jobs[0];
		array_ordered_remove_by_index(*p.jobs, 0);
		locks.unlock(*p.mu);
		if !p.client.quit expr_run(p, *j);
		expr_job_free(p.client, *j);
		reset_temporary_storage();
		locks.lock(*p.mu);
	}
	locks.unlock(*p.mu);
}

expr_job_free :: (c: *Client, j: *Expr_Job) {
	push_allocator(c.allocator);
	free(j.method);
	free(j.path);
	free(j.body);
	free(j.query);
}

expr_submit :: (c: *Client, j: Expr_Job) {
	p := expr_pool_of(c, true);
	jj := j;
	{
		push_allocator(c.allocator);
		jj.method = copy_string(j.method);
		jj.path = copy_string(j.path);
		jj.body = copy_string(j.body);
		jj.query = copy_string(j.query);
	}
	locks.lock(*p.mu);
	array_add(*p.jobs, jj);
	locks.cond_signal(*p.cond);
	locks.unlock(*p.mu);
}

// expr_pool_stop joins the expression workers serving c and frees its queued jobs and unread
// results. client_destroy calls it after setting quit and before freeing c.
expr_pool_stop :: (c: *Client) {
	locks.lock(*expr_pools_mu);
	_, p := table_remove(*expr_pools, c);
	locks.unlock(*expr_pools_mu);
	if !p return;
	locks.lock(*p.mu);
	p.stop = true;
	locks.cond_broadcast(*p.cond);
	locks.unlock(*p.mu);
	for p.threads locks.join(it);
	for * p.jobs expr_job_free(c, it);
	for * p.results expr_result_free(c, it);
	array_free(p.jobs);
	array_free(p.results);
	free(p,, c.allocator);
}

expr_deliver :: (p: *Expr_Pool, r: Expr_Result) {
	locks.lock(*p.mu);
	array_add(*p.results, r);
	locks.unlock(*p.mu);
	c := p.client;
	if c.cfg.wakeup c.cfg.wakeup(c.cfg.wakeup_data);
}

expr_run :: (p: *Expr_Pool, j: *Expr_Job) {
	c := p.client;
	res := Expr_Result.{op = j.op, tag = j.tag, query = copy_string(j.query,, c.allocator)};
	if j.op == .Media {
		status, _, ctype, data := media_get(c, j.query, j.kind, true, "");
		res.status = status;
		res.ok = status == 200;
		if data res.data = array_copy(data,, c.allocator);
		res.content_type = copy_string(ctype,, c.allocator);
		expr_deliver(p, res);
		return;
	}
	r := api_call(c, j.method, j.path, cast([]u8) j.body, ifx j.body then "application/json" else "", "", .[], 0, 1);
	res.ok = r.ok;
	res.status = r.status;
	res.body = r.body;
	res.arena = r.arena;
	expr_deliver(p, res);
}

// expr_take returns c's finished expression requests (UI thread). Free each with expr_result_free.
expr_take :: (c: *Client, allocator := temp) -> []Expr_Result {
	p := expr_pool_of(c, false);
	if !p return .[];
	locks.lock(*p.mu);
	defer locks.unlock(*p.mu);
	out := array_copy(p.results,, allocator);
	p.results.count = 0;
	return out;
}

expr_result_free :: (c: *Client, r: *Expr_Result) {
	push_allocator(c.allocator);
	free(r.query);
	array_free(r.data);
	free(r.content_type);
	if r.arena {
		fini(r.arena);
		free(r.arena);
	}
	r.* = .{};
}

expr_get :: (c: *Client, op: Expr_Op, path: string, query := "", tag: u64 = 0) {
	expr_submit(c, .{op = op, tag = tag, method = "GET", path = path, query = query});
}

expr_locale :: (c: *Client) -> string { return ifx c.store.settings.locale then c.store.settings.locale else c.id.platform.locale; }

// gifs_trending: categories for the picker's front page (+ the first trending GIF as the tile preview).
gifs_trending :: (c: *Client, tag: u64 = 0) {
	q: Query;
	query_init(*q, "/gifs/trending");
	query_add(*q, "locale", expr_locale(c));
	query_add(*q, "media_format", GIF_MEDIA_FORMAT);
	expr_get(c, .Gif_Trending, query_string(*q), "", tag);
}

// gifs_trending_gifs: the "Trending GIFs" tile. limit <= 0 is omitted (the tile passes undefined).
gifs_trending_gifs :: (c: *Client, limit := 0, tag: u64 = 0) {
	q: Query;
	query_init(*q, "/gifs/trending-gifs");
	query_add(*q, "media_format", GIF_MEDIA_FORMAT);
	query_add(*q, "locale", expr_locale(c));
	if limit > 0 query_add_int(*q, "limit", limit);
	expr_get(c, .Gif_Trending_Gifs, query_string(*q), "", tag);
}

// gifs_search: typed queries and category tiles. limit <= 0 is omitted.
gifs_search :: (c: *Client, query: string, limit := 0, tag: u64 = 0) {
	q: Query;
	query_init(*q, "/gifs/search");
	query_add(*q, "q", query);
	query_add(*q, "media_format", GIF_MEDIA_FORMAT);
	query_add(*q, "locale", expr_locale(c));
	if limit > 0 query_add_int(*q, "limit", limit);
	expr_get(c, .Gif_Search, query_string(*q), query, tag);
}

gifs_suggest :: (c: *Client, query: string, tag: u64 = 0) {
	if !query return;
	q: Query;
	query_init(*q, "/gifs/suggest");
	query_add(*q, "q", query);
	query_add_int(*q, "limit", 5);
	query_add(*q, "locale", expr_locale(c));
	expr_get(c, .Gif_Suggest, query_string(*q), query, tag);
}

// gif_select: analytics ping after a GIF is sent ({id, q}; q is the result query).
gif_select :: (c: *Client, gif_id: string, query: string) {
	if !gif_id return;
	w: Json;
	json_init(*w);
	json_obj(*w);
	json_kstr(*w, "id", gif_id);
	json_kstr(*w, "q", query);
	json_obj_end(*w);
	expr_submit(c, .{op = .Gif_Select, method = "POST", path = "/gifs/select", body = json_string(*w)});
}

sticker_packs_fetch :: (c: *Client, tag: u64 = 0) {
	q: Query;
	query_init(*q, "/sticker-packs");
	query_add(*q, "locale", expr_locale(c));
	expr_get(c, .Sticker_Packs, query_string(*q), "", tag);
}

guild_top_emojis :: (c: *Client, guild_id: Snowflake, tag: u64 = 0) {
	expr_get(c, .Top_Emojis, tprint("/guilds/%/top-emojis", guild_id), "", ifx guild_id == 0 then tag else guild_id);
}

frecency_settings_fetch :: (c: *Client, tag: u64 = 0) {
	expr_get(c, .Frecency, "/users/@me/settings-proto/2", "", tag);
}

// expr_fetch_media: bytes of a media URL (Fetch kind for lottie json, Image for svg).
expr_fetch_media :: (c: *Client, url: string, kind := Media_Kind.Fetch, tag: u64 = 0) {
	expr_submit(c, .{op = .Media, tag = tag, query = url, kind = kind});
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

// Decoders: everything goes to context.allocator.

decode_item :: (b: []u8, key: string) -> Frecency_Item {
	item := Frecency_Item.{key = copy_string(key)};
	uses: [..]s64;
	r := protobuf.Reader.{buf = b};
	while true {
		f, ok := protobuf.next(*r);
		if !ok break;
		if f.num == {
			case 1; item.total_uses = cast(int) f.value;
			case 2;
				if f.wire != .Len {
					array_add(*uses, cast(s64) f.value);
					continue;
				}
				vr := protobuf.Reader.{buf = f.bytes};
				while vr.pos < vr.buf.count {
					v, vok := protobuf.read_varint(*vr);
					if !vok break;
					array_add(*uses, cast(s64) v);
				}
			case 3; item.frecency = cast(s32) f.value;
			case 4; item.score = cast(s32) f.value;
		}
	}
	item.recent_uses = uses;
	return item;
}

// map entries: {1 key, 2 value}; fixed64 keys become decimal strings.
decode_item_map :: (b: []u8) -> []Frecency_Item {
	out: [..]Frecency_Item;
	r := protobuf.Reader.{buf = b};
	while true {
		f, ok := protobuf.next(*r);
		if !ok break;
		if f.num != 1 || f.wire != .Len continue;
		key: string;
		val: []u8;
		er := protobuf.Reader.{buf = f.bytes};
		while true {
			ef, eok := protobuf.next(*er);
			if !eok break;
			if ef.num == 1 key = ifx ef.wire == .Len then cast(string) ef.bytes else tprint("%", ef.value);
			else if ef.num == 2 val = ef.bytes;
		}
		array_add(*out, decode_item(val, key));
	}
	return out;
}

decode_favorite_gif :: (b: []u8) -> Favorite_Gif {
	g: Favorite_Gif;
	r := protobuf.Reader.{buf = b};
	while true {
		f, ok := protobuf.next(*r);
		if !ok break;
		if f.num == 1 g.url = copy_string(cast(string) f.bytes);
		if f.num != 2 continue;
		vr := protobuf.Reader.{buf = f.bytes};
		while true {
			vf, vok := protobuf.next(*vr);
			if !vok break;
			if vf.num == {
				case 1; g.format = cast(int) vf.value;
				case 2; g.src = copy_string(cast(string) vf.bytes);
				case 3; g.width = cast(int) vf.value;
				case 4; g.height = cast(int) vf.value;
				case 5; g.order = cast(int) vf.value;
			}
		}
	}
	return g;
}

// frecency_settings_decode parses the base64 "settings" of GET /users/@me/settings-proto/2.
frecency_settings_decode :: (b64: string, allocator := context.allocator) -> Frecency_Settings, bool {
	raw, ok := base64_decode(b64,, temp);
	if !ok return .{}, false;
	push_allocator(allocator);
	fs: Frecency_Settings;
	r := protobuf.Reader.{buf = cast([]u8) raw};
	while true {
		f, fok := protobuf.next(*r);
		if !fok break;
		if f.wire != .Len continue;
		if f.num == {
			case 2;
				gifs: [..]Favorite_Gif;
				gr := protobuf.Reader.{buf = f.bytes};
				while true {
					gf, gok := protobuf.next(*gr);
					if !gok break;
					if gf.num == 1 && gf.wire == .Len array_add(*gifs, decode_favorite_gif(gf.bytes));
				}
				fs.favorite_gifs = gifs;
			case 3;
				ids, iok := protobuf.find(f.bytes, 1);
				if iok fs.favorite_stickers = protobuf.packed_fixed64(ids.bytes);
			case 4;  fs.sticker = decode_item_map(f.bytes);
			case 5;
				names: [..]string;
				er := protobuf.Reader.{buf = f.bytes};
				while true {
					ef, eok := protobuf.next(*er);
					if !eok break;
					if ef.num == 1 array_add(*names, copy_string(cast(string) ef.bytes));
				}
				fs.favorite_emojis = names;
			case 6;  fs.emoji = decode_item_map(f.bytes);
			case 13; fs.emoji_reaction = decode_item_map(f.bytes);
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
	query_init(*q, tprint("/users/%/profile", user_id));
	query_add(*q, "type", "modal");
	query_add_bool(*q, "with_mutual_guilds", true);
	query_add_bool(*q, "with_mutual_friends", false);
	query_add_bool(*q, "with_mutual_friends_count", !bot);
	if guild_id query_add_snow(*q, "guild_id", guild_id);
	expr_get(c, .Profile_Modal, query_string(*q), "", user_id);
	expr_get(c, .App_Identities, tprint("/users/%/application-identities?with_profiles=true", user_id), "", user_id);
}

mutual_friends_fetch :: (c: *Client, user_id: Snowflake) {
	expr_get(c, .Mutual_Friends, tprint("/users/%/relationships", user_id), "", user_id);
}
