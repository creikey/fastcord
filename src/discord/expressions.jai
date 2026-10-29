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
//   GET  /users/@me/settings-proto/2                    (FrecencyUserSettings, lazy; library-owned, see below)
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

// frecency_settings_fetch: a picker wants the proto (loadIfNecessary). It comes back as an
// Expr_Result .Frecency at once when loaded, else when the one load in flight answers.
frecency_settings_fetch :: (c: *Client) {
	f := *c.store.frecency;
	f.picker_waiting = true;
	if f.loaded frecency_to_picker(c, true);
	else frecency_load(c);
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
//   12 guild_and_channel_frecency {1 map<fixed64,FrecencyItem>}
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
	guild_channel: []Frecency_Item;
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

// gif_favorites_write: PATCH settings-proto/2 with only field 2 (favorite_gifs: the whole map, keeping
// hide_tooltip); the reply, the full proto, replaces the loaded one, as for soundboard favourites.
gif_favorites_write :: (c: *Client, gifs: []Favorite_Gif) {
	if !c.store.frecency.loaded return;
	raw, _ := base64_decode(c.store.frecency.proto,, temp);
	inner := pb_new();
	for gifs {
		g := pb_new();
		protobuf.write_uint(*g, 1, cast(u64) it.format);
		protobuf.write_string(*g, 2, it.src);
		protobuf.write_uint(*g, 3, cast(u64) it.width);
		protobuf.write_uint(*g, 4, cast(u64) it.height);
		protobuf.write_uint(*g, 5, cast(u64) it.order);
		e := pb_new();
		protobuf.write_string(*e, 1, it.url);
		pb_msg(*e, 2, g);
		pb_msg(*inner, 1, e);
	}
	tip, tok := protobuf.find_path(cast([]u8) raw, 2, 2);
	if tok && tip.value protobuf.write_uint(*inner, 2, tip.value);
	root := pb_new();
	pb_msg(*root, 2, inner);
	w: Json;
	json_init(*w);
	json_obj(*w);
	json_kstr(*w, "settings", base64_encode(cast(string) root.buf,, temp));
	json_obj_end(*w);
	j := job_new(.Api, .Settings);
	j.result.tag = SOUNDBOARD_FAVORITES_TAG; // a partial write whose reply replaces the proto
	j.method = "PATCH";
	j.path = "/users/@me/settings-proto/2";
	j.body = cast([]u8) job_str(j, json_string(*w));
	j.content_type = "application/json";
	job_submit(c, j);
	merged := protobuf.with_field(cast([]u8) raw, 2, root.buf,, temp);
	set_str(*c.store, *c.store.frecency.proto, base64_encode(cast(string) merged,, temp));
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
			case 12; fs.guild_channel = decode_item_map(f.bytes);
			case 13; fs.emoji_reaction = decode_item_map(f.bytes);
		}
	}
	return fs, true;
}

// ---- FrecencyUserSettings writes (FrecencyUserSettingsManager, bundle module 416380) ----
// A use goes into its store's usageHistory and pending usages: FrecencyStore (guilds and
// channels, on CHANNEL_SELECT / VOICE_CHANNEL_SELECT), EmojiStore (emoji; a reaction is a use
// of both its maps), StickersStore. Nothing is written per use. The manager's one timer runs
// R(startup) 10 ms-10 s after each READY / RESUMED (one draw per run), then every 2 h + 0-10 min,
// and R(false) runs at once when the gateway closes. R loads the proto if it isn't loaded and
// there is pending usage (guild/channel usage alone doesn't count in the startup run); loaded,
// it PATCHes {"settings": delta}, the delta holding every map with pending usage, whole, in
// field order: 4 stickers, 6 + 13 emoji (one store), 12 guilds and channels. The response is
// the full proto: it replaces the histories and clears the pending usage. Map order is the JS
// object's: integer-like keys ascending, then insertion order (the server's, new keys last).

Frecency_Kind :: enum u8 {
	Sticker;
	Emoji;
	Guild_Channel;
	Reaction;
}

Frecency_Use :: struct {
	kind: Frecency_Kind;
	key: string;
	at: s64;
}

// In c.store (per account, UI thread); its allocations are in the store's allocator.
Frecency_State :: struct {
	loaded: bool;
	loading: bool;
	write_on_load: bool; // R started the load
	saving: bool; // PATCH in flight
	picker_waiting: bool; // a picker asked for the proto
	history: [4][..]Frecency_Item; // usageHistory by Frecency_Kind, in insertion order
	pending: [..]Frecency_Use;
	proto: string; // the server's last full proto (base64), for the pickers
	channel, guild: Snowflake; // FrecencyStore's last selected (0 = none)
	timer_at: s64; // the manager's timer (0 = none) and its R argument
	timer_startup: bool;
	load_at: s64; // the session's lazy load
	readies: u64;
	connected: bool;
	startup_ms, periodic_ms: s64; // drawn once, as the bundle does at module load
	reactions_read: bool; // the UI read the reaction frecency since the last proto (frecency_reactions_shown)
}

FRECENCY_FIELD :: u32.[4, 6, 12, 13];
FRECENCY_SETTINGS_TYPE :: 2; // Rest_Result.tag of the settings-proto/2 jobs
FRECENCY_LOAD_MS :: 5130; // the lazy load: READY + 4.9-5.2 s in the fixtures (guild and DM routes)
FRECENCY_MAX_SAMPLES :: 10;
FRECENCY_MAX_ENTRIES :: 100; // per map in the PATCH (application commands: 500, not modelled)
EMOJI_FRECENCY_SEED :: string.["thumbsup", "eyes", "laughing", "watermelon", "fork_and_knife", "yum", "weary", "tired_face", "poop", "100"];
REACTION_FRECENCY_SEED :: string.["100", "100", "thumbsup", "thumbsup", "thumbsdown", "thumbsdown", "heart", "point_up", "eyes", "weary", "laughing", "white_check_mark", "x"];

// frecency_use: a sticker sent, an emoji sent or reacted with (key: custom emoji id or the emoji's
// unique name, e.g. "thumbsup"). A reaction is also an emoji use (EmojiStore MESSAGE_REACTION_ADD).
frecency_use :: (c: *Client, kind: Frecency_Kind, key: string) {
	if !key return;
	use :: (c: *Client, kind: Frecency_Kind, key: string, at: s64) {
		f := *c.store.frecency;
		push_allocator(c.store.allocator);
		frecency_track(*f.history[kind], key, at);
		array_add(*f.pending, .{kind, copy_string(key), at});
	}
	now := now_ms();
	use(c, kind, key, now);
	if kind == .Reaction use(c, .Emoji, key, now);
}

// frecency_reactions_shown: the UI read the frecent reactions (quick reactions on the hover toolbar
// or a message menu), which computes the reaction history's frecency for the next write.
frecency_reactions_shown :: (c: *Client) { c.store.frecency.reactions_read = true; }

// frecency_select: FrecencyStore on CHANNEL_SELECT / VOICE_CHANNEL_SELECT: a channel or guild other
// than the last selected one is a use (0: home, a DM's guild, leaving voice).
frecency_select :: (c: *Client, guild_id: Snowflake, channel_id: Snowflake) {
	f := *c.store.frecency;
	if channel_id != f.channel {
		f.channel = channel_id;
		if channel_id frecency_use(c, .Guild_Channel, snowflake_string(channel_id));
	}
	if guild_id != f.guild {
		f.guild = guild_id;
		if guild_id frecency_use(c, .Guild_Channel, snowflake_string(guild_id));
	}
}

// frecency_load: loadIfNecessary.
frecency_load :: (c: *Client) {
	f := *c.store.frecency;
	if f.loaded || f.loading return;
	f.loading = true;
	frecency_job(c, "GET", "");
}

// frecency_tick (client_poll): the manager's connection hooks and timer, and the lazy load.
frecency_tick :: (c: *Client, now: s64) {
	s := *c.store;
	f := *s.frecency;
	if c.quit || c.cfg.hosted.host return; // a self-hosted server has no settings protos
	if !f.startup_ms {
		f.startup_ms = 10 + cast(s64) (random_get_zero_to_one() * 10_000);
		f.periodic_ms = 7_200_000 + cast(s64) (random_get_zero_to_one() * 600_000);
	}
	open := s.connection == .Ready;
	if s.readies != f.readies || (open && !f.connected) { // POST_CONNECTION_OPEN / CONNECTION_RESUMED
		if f.readies == 0 && !c.cfg.disable_startup && client_route_kind(c.start_route_guild, c.start_route_channel) != .Home {
			locks.lock(*c.job_mu);
			f.load_at = c.ready_ms + FRECENCY_LOAD_MS;
			locks.unlock(*c.job_mu);
		}
		f.readies = s.readies;
		f.connected = true;
		f.timer_at, f.timer_startup = now + f.startup_ms, true;
	} else if f.connected && !open { // CONNECTION_CLOSED
		f.connected = false;
		frecency_run(c, false);
	}
	if f.load_at && now >= f.load_at {
		f.load_at = 0;
		frecency_load(c);
	}
	if f.timer_at && now >= f.timer_at frecency_run(c, f.timer_startup);
}

// frecency_apply: a settings-proto/2 response (USER_SETTINGS_PROTO_UPDATE): the load, or the
// PATCH's full proto (wasSaved: the pending usage is written). Each store then overwrites its
// history from the proto (frecency -1: not computed) and replays its pending usage.
frecency_apply :: (c: *Client, ok: bool, b64: string) {
	s := *c.store;
	f := *s.frecency;
	saved := f.loaded;
	if saved f.saving = false;
	else f.loading = false;
	push_allocator(s.allocator);
	ok = ok && frecency_overwrite(f, b64, saved, now_ms());
	if f.picker_waiting frecency_to_picker(c, ok);
	if !ok return;
	if f.write_on_load {
		f.write_on_load = false;
		frecency_write(c);
	}
}

// frecency_maps: the proto's usage maps by Frecency_Kind.
frecency_maps :: (fs: Frecency_Settings) -> [4][]Frecency_Item {
	m: [4][]Frecency_Item;
	m[0], m[1], m[2], m[3] = fs.sticker, fs.emoji, fs.guild_channel, fs.emoji_reaction;
	return m;
}

// frecency_overwrite: the stores' sync with a new proto (allocations: context.allocator).
frecency_overwrite :: (f: *Frecency_State, b64: string, saved: bool, now: s64) -> bool {
	fs, ok := frecency_settings_decode(b64, temp);
	if !ok return false;
	if saved {
		for f.pending free(it.key);
		f.pending.count = 0;
	}
	f.loaded = true;
	f.reactions_read = false; // the history is reloaded uncomputed
	free(f.proto);
	f.proto = copy_string(b64);
	server := frecency_maps(fs);
	for * h, k: f.history {
		frecency_free_items(h);
		for server[k] {
			item := it;
			item.key = copy_string(it.key);
			uses: [..]s64;
			for u: it.recent_uses if u > 0 array_add(*uses, u);
			item.recent_uses = uses;
			item.frecency = -1;
			array_add(h, item);
		}
		replayed := false;
		for f.pending if it.kind == xx k {
			frecency_track(h, it.key, it.at, sorted = true);
			replayed = true;
		}
		// EmojiStore seeds an empty history (not a pending usage)
		if server[k].count || replayed continue;
		if k == xx Frecency_Kind.Emoji for EMOJI_FRECENCY_SEED frecency_track(h, it, now);
		if k == xx Frecency_Kind.Reaction for REACTION_FRECENCY_SEED frecency_track(h, it, now);
	}
	return true;
}

frecency_free :: (s: *Store) {
	f := *s.frecency;
	push_allocator(s.allocator);
	for * f.history {
		frecency_free_items(it);
		array_free(it.*);
	}
	for f.pending free(it.key);
	array_free(f.pending);
	free_str(f.proto, s.allocator);
	f.* = .{};
}

#scope_file

frecency_job :: (c: *Client, method: string, body: string) {
	j := job_new(.Api, .Settings);
	j.result.tag = FRECENCY_SETTINGS_TYPE;
	j.method = method;
	j.path = "/users/@me/settings-proto/2";
	if body {
		j.body = cast([]u8) job_str(j, body);
		j.content_type = "application/json";
		j.retry_429 = 1; // retried after min(30 s, Retry-After)
	}
	job_submit(c, j);
}

// frecency_run: the manager's R(startup).
frecency_run :: (c: *Client, startup: bool) {
	f := *c.store.frecency;
	f.timer_at, f.timer_startup = now_ms() + f.periodic_ms, false;
	if f.loaded {
		frecency_write(c);
		return;
	}
	for f.pending if (it.kind != .Guild_Channel || !startup) && !f.loading {
		f.write_on_load = true;
		frecency_load(c);
		break;
	}
}

// frecency_write: markDirtyIfHasPendingChange, then persistChanges (no delay).
frecency_write :: (c: *Client) {
	f := *c.store.frecency;
	if !f.loaded || f.saving || !f.pending.count return;
	push_allocator(c.store.allocator);
	w: Json;
	json_init(*w);
	json_obj(*w);
	json_kstr(*w, "settings", base64_encode(cast(string) frecency_delta(f, now_ms()),, temp));
	json_obj_end(*w);
	f.saving = true;
	f.timer_at, f.timer_startup = now_ms() + f.periodic_ms, false; // processProto: the periodic run restarts
	frecency_job(c, "PATCH", json_string(*w));
}

#scope_module

// frecency_delta: the PATCH's proto (temp): each map with pending usage, whole, in field order.
frecency_delta :: (f: *Frecency_State, now: s64) -> []u8 {
	has: [4]bool;
	for f.pending has[it.kind] = true;
	emoji := has[Frecency_Kind.Emoji] || has[Frecency_Kind.Reaction];
	has[Frecency_Kind.Emoji], has[Frecency_Kind.Reaction] = emoji, emoji;
	root := pb_new();
	for * h, k: f.history {
		if !has[k] continue;
		if k == xx Frecency_Kind.Reaction frecency_compute_reactions(h, now, f.reactions_read);
		m := pb_new();
		frecency_encode_map(*m, h.*, fixed_keys = k == xx Frecency_Kind.Sticker || k == xx Frecency_Kind.Guild_Channel);
		pb_msg(*root, FRECENCY_FIELD[k], m);
	}
	return root.buf;
}

#scope_file

// frecency_track: Frecency.track. A pending usage replayed with its timestamp sorts the uses.
frecency_track :: (h: *[..]Frecency_Item, key: string, at: s64, sorted := false) {
	for * h.* {
		if it.key != key continue;
		it.frecency = -1;
		it.total_uses += 1;
		uses: [..]s64;
		array_add(*uses, ..it.recent_uses);
		array_add(*uses, at);
		if sorted quick_sort(uses, (a: s64, b: s64) -> int { return ifx a < b then -1 else ifx a > b then 1 else 0; });
		while uses.count > FRECENCY_MAX_SAMPLES array_ordered_remove_by_index(*uses, 0);
		array_free(it.recent_uses);
		it.recent_uses = uses;
		return;
	}
	uses := NewArray(1, s64);
	uses[0] = at;
	array_add(h, .{key = copy_string(key), total_uses = 1, recent_uses = uses, frecency = -1});
}

frecency_free_items :: (h: *[..]Frecency_Item) {
	for h.* {
		free(it.key);
		array_free(it.recent_uses);
	}
	h.count = 0;
}

// frecency_compute_reactions: Frecency.compute of EmojiStore's reaction history (bonus 100,
// calculateMaxTotalUse): every fixture's write carries the computed scores. Their frecency is set
// once the UI has read the frecent reactions since the last proto (0.0.420: the hover toolbar's and
// the context menu's quick reactions); before that it stays -1, like emoji and guild/channel entries
// (fixture reply: a write before any hover). 0.0.419 computed it in every write.
frecency_compute_reactions :: (h: *[..]Frecency_Item, now: s64, read: bool) {
	max_total := 0;
	for h.* max_total = max(max_total, it.total_uses);
	i := 0;
	while i < h.count {
		it := *h.*[i];
		i += 1;
		if it.frecency != -1 continue;
		score := 0;
		for u: it.recent_uses {
			if it_index >= FRECENCY_MAX_SAMPLES break;
			days := (now - u) / 86_400_000;
			score += ifx days <= 3 then 100 else ifx days <= 15 then 70 else ifx days <= 30 then 50 else ifx days <= 45 then 30 else ifx days <= 80 then 10 else 1;
		}
		it.score = score;
		if read it.frecency = cast(int) (1000 * (cast(float64) it.total_uses / max_total * 0.2 + cast(float64) score / 1000 * 0.8));
		if score continue;
		i -= 1;
		free(it.key);
		array_free(it.recent_uses);
		array_ordered_remove_by_index(h, i);
	}
}

// frecency_encode_map: a map<key, FrecencyItem> as protobuf-ts writes the object (S in module 761821).
frecency_encode_map :: (w: *protobuf.Writer, items: []Frecency_Item, fixed_keys: bool) {
	order: [..]int;
	order.allocator = temp;
	for items array_add(*order, it_index);
	if order.count > FRECENCY_MAX_ENTRIES {
		// sortBy(last use) (stable), reversed, then the oldest dropped
		last :: (it: Frecency_Item) -> s64 { return ifx it.recent_uses.count then it.recent_uses[it.recent_uses.count - 1] else S64_MAX; }
		for i: 1..order.count - 1 {
			j := i;
			while j > 0 && last(items[order[j - 1]]) > last(items[order[j]]) {
				order[j - 1], order[j] = order[j], order[j - 1];
				j -= 1;
			}
		}
		for i: 0..order.count / 2 - 1 order[i], order[order.count - 1 - i] = order[order.count - 1 - i], order[i];
		order.count = FRECENCY_MAX_ENTRIES;
	}
	// a JS object lists array-index keys ("100") first, ascending
	index_key :: (k: string) -> u64, bool {
		if !k || k.count > 10 || (k.count > 1 && k[0] == #char "0") return 0, false;
		v: u64;
		for cast([]u8) k {
			if !is_digit(it) return 0, false;
			v = v * 10 + it - #char "0";
		}
		return v, v < 0xFFFF_FFFF;
	}
	sorted: [..]int;
	sorted.allocator = temp;
	for order {
		v, ok := index_key(items[it].key);
		if !ok continue;
		at := sorted.count;
		while at > 0 && index_key(items[sorted[at - 1]].key) > v at -= 1;
		array_insert_at(*sorted, it, at);
	}
	for order {
		_, ok := index_key(items[it].key);
		if !ok array_add(*sorted, it);
	}
	for i: sorted {
		it := items[i];
		entry := pb_new();
		if fixed_keys pb_fixed64(*entry, 1, string_to_int(it.key, T = u64));
		else protobuf.write_string(*entry, 1, it.key);
		v := pb_new();
		if it.total_uses protobuf.write_uint(*v, 1, xx it.total_uses);
		if it.recent_uses.count {
			p := pb_new();
			for it.recent_uses protobuf.write_varint(*p, xx it);
			pb_msg(*v, 2, p);
		}
		if it.frecency protobuf.write_uint(*v, 3, cast,no_check(u64) it.frecency); // int32: negatives as 10 bytes
		if it.score protobuf.write_uint(*v, 4, cast,no_check(u64) it.score);
		pb_msg(*entry, 2, v);
		pb_msg(w, 1, entry);
	}
}

// frecency_to_picker hands the loaded proto to the pickers as an Expr_Result.
frecency_to_picker :: (c: *Client, ok: bool) {
	c.store.frecency.picker_waiting = false;
	arena := New(Flat_Pool,, c.allocator);
	body: V;
	{
		push_allocator(pool_allocator(arena));
		m := etf.map_builder(1);
		etf.map_put(*m, "settings", etf.vstring(copy_string(c.store.frecency.proto)));
		body = etf.vmap(etf.map_done(*m));
	}
	expr_deliver(expr_pool_of(c, true), .{op = .Frecency, ok = ok, status = ifx ok then 200 else 0, body = body, arena = arena});
}

#scope_export

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
