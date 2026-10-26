package discord

import "core:bytes"
import "core:encoding/base64"
import "core:fmt"
import "core:strings"
import "core:testing"
import "fc:etf"
import "fc:http"

GW_FIXTURE :: #load("testdata/gw_a.jsonl", string)
IDENTIFY_FIXTURE :: #load("testdata/identify_fast_connect.json", string)

@(private = "file")
test_identity :: proc(id: ^Identity) {
	identity_init(id, DEFAULT_PLATFORM, context.temp_allocator)
	id.fast_connect_launch_id = "<uuid:launch>"
	id.installation_id = "<id:installation>"
}

@(test)
identify_fast_connect_byte_exact :: proc(t: ^testing.T) {
	id: Identity
	test_identity(&id)
	d := identify_fast_connect_value(&id, "<token>")
	b := etf.map_builder(2, context.temp_allocator)
	etf.map_put(&b, "op", i64(2))
	etf.map_put(&b, "d", d)
	ours, err := etf.encode(etf.map_done(&b), context.temp_allocator)
	testing.expect_value(t, err, etf.Error.None)
	want_v, jerr := etf.from_json(IDENTIFY_FIXTURE, context.temp_allocator)
	testing.expect_value(t, jerr, etf.Error.None)
	want, _ := etf.encode(want_v, context.temp_allocator)
	if !bytes.equal(ours, want) {
		sb := strings.builder_make(context.temp_allocator)
		etf.to_json(etf.map_done(&b), &sb)
		testing.expectf(t, false, "identify differs:\n got %s\nwant %s", strings.to_string(sb), IDENTIFY_FIXTURE)
	}
}

@(test)
super_properties_layout :: proc(t: ^testing.T) {
	id: Identity
	test_identity(&id)
	id.client_launch_id = "L"
	id.launch_signature = "S"
	now: i64 = 1_800_000_000_000
	id.heartbeat = {"H", now - 1000, now - 1000}
	got := super_properties_json(&id, now)
	want := `{"os":"Mac OS X","browser":"Discord Client","release_channel":"stable","client_version":"0.0.419","os_version":"27.0.0","os_arch":"arm64","app_arch":"arm64","system_locale":"en-US","has_client_mods":false,"client_launch_id":"L","browser_user_agent":"` + DEFAULT_USER_AGENT + `","browser_version":"42.11.15","os_sdk_version":"27","client_build_number":649389,"native_build_number":96312,"client_event_source":null,"launch_signature":"S","client_heartbeat_session_id":"H","client_app_state":"focused"}`
	testing.expect_value(t, got, want)
	// Unfocused and expired: the key disappears but keeps its slot when it returns.
	id.app_state = .Unfocused
	later := now + HEARTBEAT_SESSION_TTL_MS + 1
	got2 := super_properties_json(&id, later)
	testing.expect(t, strings.has_suffix(got2, `"launch_signature":"S","client_app_state":"unfocused"}`), got2)
}

@(test)
super_properties_late_heartbeat_order :: proc(t: ^testing.T) {
	id: Identity
	test_identity(&id)
	id.client_launch_id = "L"
	id.launch_signature = "S"
	id.app_state = .Unfocused
	now: i64 = 1_800_000_000_000
	a := super_properties_json(&id, now) // no session yet: client_app_state is appended first
	testing.expect(t, strings.has_suffix(a, `"launch_signature":"S","client_app_state":"unfocused"}`), a)
	id.app_state = .Focused
	b := super_properties_json(&id, now)
	testing.expect(t, strings.contains(b, `"client_app_state":"focused","client_heartbeat_session_id":"`), b)
}

@(private = "file")
names :: proc(h: []http.Header) -> string {
	sb := strings.builder_make(context.temp_allocator)
	for x, i in h {
		if i > 0 do strings.write_string(&sb, ",")
		strings.write_string(&sb, x.name)
	}
	return strings.to_string(sb)
}

// Orders from netlog captures of the official client (HTTP3_HEADERS_SENT).
API_GET_ORDER :: "sec-ch-ua-platform,authorization,x-installation-id,x-debug-options,accept-language,sec-ch-ua,sec-ch-ua-mobile,x-discord-timezone,x-super-properties,x-discord-locale,user-agent,accept,sec-fetch-site,sec-fetch-mode,sec-fetch-dest,referer,accept-encoding,cookie,priority"
API_SEND_ORDER :: "content-length,sec-ch-ua-platform,authorization,x-installation-id,x-debug-options,accept-language,sec-ch-ua,sec-ch-ua-mobile,x-discord-timezone,x-context-properties,x-super-properties,x-discord-locale,user-agent,content-type,accept,origin,sec-fetch-site,sec-fetch-mode,sec-fetch-dest,referer,accept-encoding,cookie,priority"
API_TYPING_ORDER :: "content-length,sec-ch-ua-platform,authorization,x-installation-id,x-debug-options,accept-language,sec-ch-ua,sec-ch-ua-mobile,x-discord-timezone,x-super-properties,x-discord-locale,user-agent,accept,origin,sec-fetch-site,sec-fetch-mode,sec-fetch-dest,referer,accept-encoding,cookie,priority"
API_DELETE_ORDER :: "sec-ch-ua-platform,authorization,x-installation-id,x-debug-options,accept-language,sec-ch-ua,sec-ch-ua-mobile,x-discord-timezone,x-super-properties,x-discord-locale,user-agent,accept,origin,sec-fetch-site,sec-fetch-mode,sec-fetch-dest,referer,accept-encoding,cookie,priority"
API_ETAG_ORDER :: "cache-control,if-none-match,authorization,x-installation-id,sec-ch-ua-platform,x-debug-options,accept-language,sec-ch-ua,sec-ch-ua-mobile,x-discord-timezone,x-super-properties,x-discord-locale,user-agent,accept,sec-fetch-site,sec-fetch-mode,sec-fetch-dest,referer,accept-encoding,cookie,priority"
PREFLIGHT_ORDER :: "accept,access-control-request-method,access-control-request-headers,origin,user-agent,sec-fetch-mode,sec-fetch-site,sec-fetch-dest,referer,accept-encoding,accept-language,priority"
UPLOAD_PUT_ORDER :: "content-length,sec-ch-ua-platform,user-agent,sec-ch-ua,content-type,sec-ch-ua-mobile,accept,origin,sec-fetch-site,sec-fetch-mode,sec-fetch-dest,referer,accept-encoding,accept-language,priority"
WS_ORDER :: "Host,Connection,Pragma,Cache-Control,User-Agent,Upgrade,Origin,Sec-WebSocket-Version,Accept-Encoding,Accept-Language,Cookie,Sec-WebSocket-Key,Sec-WebSocket-Extensions"
STATUS_ORDER :: "sec-ch-ua-platform,user-agent,sec-ch-ua,sec-ch-ua-mobile,accept,origin,sec-fetch-site,sec-fetch-mode,sec-fetch-dest,referer,accept-encoding,accept-language,priority"

@(test)
header_orders :: proc(t: ^testing.T) {
	p := DEFAULT_PLATFORM
	base := Api_Headers_Input{token = "T", installation_id = "I", super_props_b64 = "S", referer = "R", cookie = "C"}
	g := base
	g.method = "GET"
	testing.expect_value(t, names(api_headers(p, g)), API_GET_ORDER)
	s := base
	s.method = "POST"
	s.has_body = true
	s.body_len = 119
	s.content_type = "application/json"
	s.context_b64 = context_location("chat_input")
	h := api_headers(p, s)
	testing.expect_value(t, names(h), API_SEND_ORDER)
	testing.expect_value(t, h[0].value, "119")
	testing.expect_value(t, h[9].value, "eyJsb2NhdGlvbiI6ImNoYXRfaW5wdXQifQ==")
	ty := base
	ty.method = "POST"
	hh := api_headers(p, ty)
	testing.expect_value(t, names(hh), API_TYPING_ORDER)
	testing.expect_value(t, hh[0].value, "0")
	pu := base
	pu.method = "PUT" // reaction add: content-length 0, origin
	testing.expect_value(t, names(api_headers(p, pu)), API_TYPING_ORDER)
	de := base
	de.method = "DELETE"
	testing.expect_value(t, names(api_headers(p, de)), API_DELETE_ORDER)
	et := base
	et.method = "GET"
	et.extra = {{"cache-control", "max-age=0"}, {"if-none-match", `W/"x"`}}
	testing.expect_value(t, names(api_headers(p, et)), API_ETAG_ORDER)
	testing.expect_value(t, names(preflight_headers(p, "PUT", "content-type")), PREFLIGHT_ORDER)
	testing.expect_value(t, names(upload_put_headers(p, 22)), UPLOAD_PUT_ORDER)
	testing.expect_value(t, names(gateway_ws_headers(p, "gateway.discord.gg", "c=1")), WS_ORDER)
	testing.expect_value(t, names(web_headers(p, {method = "GET", site = .Same_Site, referer = "https://discord.com/"})), STATUS_ORDER)
}

@(test)
message_bodies :: proc(t: ^testing.T) {
	// content-length 119 / 217 / 33 / 38 / 44 in the capture.
	body := message_send_body(1, "fastcord header probe", 1564228897380376576, {})
	testing.expect_value(t, body, `{"mobile_network_type":"unknown","content":"fastcord header probe","nonce":"1564228897380376576","tts":false,"flags":0}`)
	testing.expect_value(t, len(body), 119)
	att := `[{"id":"0","filename":"probe.txt","uploaded_filename":"498671c5-7395-4dff-b46f-5aad56a73881/probe.txt"}]`
	testing.expect_value(t, len(message_send_body(1, "", 1564228897380376576, {}, att)), 217)
	reply := message_send_body(5, "hi", 7, {reply_to = 9, reply_guild_id = 3})
	testing.expect_value(t, reply, `{"mobile_network_type":"unknown","content":"hi","nonce":"7","tts":false,"message_reference":{"guild_id":"3","channel_id":"5","message_id":"9"},"allowed_mentions":{"parse":["users","roles","everyone"],"replied_user":false},"flags":0}`)
}

@(test)
reaction_paths :: proc(t: ^testing.T) {
	q: Query
	query_init(&q, strings.concatenate({"/channels/1/messages/2/reactions/", emoji_route("👍", 0), "/%40me"}, context.temp_allocator))
	query_add(&q, "location", "Message")
	query_add_int(&q, "type", 0)
	testing.expect_value(t, query_string(&q), "/channels/1/messages/2/reactions/%F0%9F%91%8D/%40me?location=Message&type=0")
	testing.expect_value(t, emoji_route("blob", 123), "blob%3A123")
}

@(test)
nonce_generation :: proc(t: ^testing.T) {
	g: Nonce_Gen
	ms: i64 = 1793011713423
	a := nonce_at(&g, ms)
	b := nonce_at(&g, ms)
	c := nonce_at(&g, ms + 1)
	testing.expect_value(t, u64(a), u64(ms - DISCORD_EPOCH_MS) << 22)
	testing.expect_value(t, u64(b), u64(a) + 1)
	testing.expect_value(t, u64(c), u64(ms + 1 - DISCORD_EPOCH_MS) << 22)
	testing.expect_value(t, snowflake_time_ms(a), ms)
	testing.expect_value(t, days_since_epoch(DISCORD_EPOCH_MS + 5 * 86_400_000 + 1), 5)
}

@(test)
rate_limits :: proc(t: ^testing.T) {
	r: Rate_Limiter
	rate_limiter_init(&r)
	defer rate_limiter_destroy(&r)
	url := "https://discord.com/api/v9/channels/1/messages"
	now: i64 = 1_000_000
	hdrs := []http.Header{{"retry-after", "2"}, {"x-ratelimit-bucket", "abc"}, {"x-ratelimit-limit", "5"}, {"x-ratelimit-remaining", "0"}, {"x-ratelimit-reset-after", "1.5"}}
	// backoff(1s,60s).fail with random 0 -> current stays 1000; floor = 2000.
	hold := rate_note_response(&r, "POST", url, 429, hdrs, nil, now, 0)
	testing.expect_value(t, hold, 2000)
	testing.expect_value(t, rate_wait_ms(&r, "POST", url, now + 500), 1500)
	testing.expect_value(t, rate_wait_ms(&r, "POST", "https://discord.com/api/v9/channels/2/messages", now), 0)
	// Second 429 extends with backoff: current = 1000 + 2*1000*1.0 = 3000 > floor 2000.
	hold2 := rate_note_response(&r, "POST", url, 429, hdrs, nil, now + 2000, 1)
	testing.expect_value(t, hold2, 3000)
	// Body retry_after when no header.
	body, _ := etf.from_json(`{"message":"You are being rate limited.","retry_after":0.5,"global":false}`, context.temp_allocator)
	h3 := rate_note_response(&r, "GET", "https://discord.com/api/v9/x", 429, nil, body, now, 0)
	testing.expect_value(t, h3, 1000) // backoff current 1000 > 500 floor
	b, ok := rate_bucket_for(&r, "POST", "/api/v9/channels/1/messages")
	testing.expect(t, ok)
	testing.expect_value(t, b.limit, 5)
	testing.expect_value(t, b.remaining, 0)
	testing.expect_value(t, route_key("PUT", "/api/v9/channels/1564227670806364343/messages/1564228897804001281/reactions/%F0%9F%91%8D/%40me?x=1"), "PUT /api/v9/channels/1564227670806364343/messages/:id/reactions/:emoji/*")
	testing.expect(t, is_retryable_status(502) && !is_retryable_status(500))
	bo := backoff_make(1000, 60000)
	testing.expect_value(t, backoff_fail(&bo, 0, 0.5), 2000)
	testing.expect_value(t, backoff_fail(&bo, 0, 0.5), 4000)
}

@(test)
cookie_jar_order :: proc(t: ^testing.T) {
	j: Cookie_Jar
	cookie_jar_init(&j)
	defer cookie_jar_destroy(&j)
	now: i64 = 1_800_000_000_000
	cookie_set_from_header(&j, "discord.com", "/", "__dcfduid=a; Expires=Fri, 22 Oct 2032 00:00:00 GMT; Max-Age=31536000; Secure; HttpOnly; Path=/; SameSite=Lax", now)
	cookie_set_from_header(&j, "discord.com", "/", "__sdcfduid=b; Max-Age=31536000; Secure; HttpOnly; Path=/", now + 1)
	cookie_set_from_header(&j, "discord.com", "/", "cf_clearance=c; Max-Age=31536000; Domain=.discord.com; Path=/; Secure", now + 2)
	cookie_set_from_header(&j, "discord.com", "/", "_cfuvid=d; HttpOnly; SameSite=None; Secure; Path=/; Domain=discord.com", now + 3)
	cookie_set_from_header(&j, "gateway.discord.gg", "/", "__cf_bm=e; HttpOnly; Secure; Path=/; Domain=discord.gg; Max-Age=1800", now)
	testing.expect_value(t, cookie_header(&j, "discord.com", "/api/v9/x", true, now + 10), "__dcfduid=a; __sdcfduid=b; cf_clearance=c; _cfuvid=d")
	// Re-set moves cf_clearance last (fresh creation time), as in the capture.
	cookie_set_from_header(&j, "discord.com", "/", "cf_clearance=c2; Max-Age=31536000; Domain=.discord.com; Path=/; Secure", now + 20)
	testing.expect_value(t, cookie_header(&j, "discord.com", "/", true, now + 30), "__dcfduid=a; __sdcfduid=b; _cfuvid=d; cf_clearance=c2")
	testing.expect_value(t, cookie_header(&j, "gateway.discord.gg", "/", true, now), "__cf_bm=e")
	testing.expect_value(t, cookie_header(&j, "cdn.discordapp.com", "/", true, now), "")
	ms, ok := parse_http_date("Mon, 26 Oct 2026 09:30:58 GMT")
	testing.expect(t, ok)
	testing.expect_value(t, ms, 1793007058000)
}

@(test)
qos_payloads :: proc(t: ^testing.T) {
	g := Gateway{}
	gateway_set_active(&g, qos_from_state(true, false))
	q1, _ := consume_qos_locked(&g).?
	testing.expect(t, q1.active && q1.n == 1 && q1.reasons[0] == "foregrounded")
	gateway_set_active(&g, qos_from_state(false, false))
	q2, _ := consume_qos_locked(&g).?
	testing.expect(t, q2.active) // payload already latched active (merged), like the client
	q3, _ := consume_qos_locked(&g).?
	testing.expect(t, !q3.active && q3.n == 0) // {active:false, reasons:[]} as in gw_a's 2nd beat
	// ETF of the heartbeat body matches the captured one.
	b := etf.map_builder(2, context.temp_allocator)
	etf.map_put(&b, "seq", i64(3))
	etf.map_put(&b, "qos", qos_value(q3))
	sb := strings.builder_make(context.temp_allocator)
	etf.to_json(etf.map_done(&b), &sb)
	testing.expect_value(t, strings.to_string(sb), `{"seq":3,"qos":{"active":false,"ver":31,"reasons":[]}}`)
	vs := voice_state_value(0, 0, true, false, false, 2)
	sb2 := strings.builder_make(context.temp_allocator)
	etf.to_json(vs, &sb2)
	testing.expect_value(t, strings.to_string(sb2), `{"guild_id":null,"channel_id":null,"self_mute":true,"self_deaf":false,"self_video":false,"flags":2}`)
}

@(test)
qos_token_encoding :: proc(t: ^testing.T) {
	derived := []byte{0x0a, 0x02, 0x01, 0x02}
	tok := base64.encode(derived, allocator = context.temp_allocator)
	out, _ := base64.decode(qos_token_b64(tok, true), allocator = context.temp_allocator)
	testing.expect(t, bytes.equal(out, []byte{0x0a, 0x02, 0x08, 0x01, 0x12, 0x04, 0x0a, 0x02, 0x01, 0x02}), fmt.tprint(out))
}

@(test)
store_replays_gateway_capture :: proc(t: ^testing.T) {
	s: Store
	store_init(&s, context.temp_allocator)
	n := store_load_fixture_text(&s, GW_FIXTURE)
	testing.expect_value(t, n, 3) // READY, READY_SUPPLEMENTAL, SESSIONS_REPLACE
	testing.expect(t, s.ready)
	testing.expect_value(t, s.me, Snowflake(1546819257420087346))
	me := user_get(&s, s.me)
	testing.expect(t, me != nil && me.global_name == "Dingus Battle")
	g := guild_get(&s, 1546820558300258304)
	testing.expect(t, g != nil)
	if g == nil do return
	testing.expect_value(t, g.name, "Dingus Battle")
	testing.expect_value(t, g.member_count, 5)
	testing.expect(t, len(g.roles) > 0)
	ch := channel_get(&s, 1546820603343016006)
	testing.expect(t, ch != nil && ch.name == "dingus-battle" && ch.guild_id == g.id && ch.kind == .Guild_Text)
	sorted := guild_channels_sorted(&s, g.id)
	testing.expect_value(t, len(sorted), len(g.channels))
	testing.expect_value(t, sorted[0], Snowflake(1546820558950371408)) // "Text Channels" category first
	rs := s.read_states[1546820603343016006]
	testing.expect_value(t, rs.last_message_id, Snowflake(1549558379905552466))
	testing.expect_value(t, rs.last_viewed, 4283)
	testing.expect(t, !channel_unread(&s, 1546820603343016006))
	testing.expect_value(t, s.settings.locale, "en-US")
	testing.expect_value(t, s.settings.timezone_offset, 420)
	testing.expect(t, member_get(&s, g.id, s.me) != nil)
	testing.expect(t, member_get(&s, g.id, 181531813351522304) != nil) // READY_SUPPLEMENTAL merged member
	testing.expect_value(t, len(s.sessions), 1)
	testing.expect_value(t, s.sessions[0].status, Status.Online)
	testing.expect_value(t, s.resume_gateway_url, "wss://gateway-us-east1-b.discord.gg")
}

@(test)
store_message_lifecycle :: proc(t: ^testing.T) {
	s: Store
	store_init(&s, context.temp_allocator)
	s.me = 10
	l := message_list(&s, 5)
	pm := new_message(&s)
	pm.id = 100
	pm.channel_id = 5
	pm.nonce = clone_str("100", s.allocator)
	pm.pending = true
	insert_message(l, pm)
	create, _ := etf.from_json(`{"id":"200","channel_id":"5","author":{"id":"10","username":"me"},"content":"hi","nonce":"100","timestamp":"t","reactions":[]}`, context.temp_allocator)
	store_apply_dispatch(&s, "MESSAGE_CREATE", create, 0)
	msgs := messages_get(&s, 5)
	testing.expect_value(t, len(msgs), 1)
	testing.expect_value(t, msgs[0].id, Snowflake(200))
	testing.expect(t, !msgs[0].pending)
	add, _ := etf.from_json(`{"channel_id":"5","message_id":"200","user_id":"10","emoji":{"id":null,"name":"👍"},"burst":false}`, context.temp_allocator)
	store_apply_dispatch(&s, "MESSAGE_REACTION_ADD", add, 0)
	testing.expect(t, len(msgs[0].reactions) == 1 && msgs[0].reactions[0].me && msgs[0].reactions[0].count == 1)
	store_apply_dispatch(&s, "MESSAGE_REACTION_REMOVE", add, 0)
	testing.expect_value(t, len(messages_get(&s, 5)[0].reactions), 0)
	upd, _ := etf.from_json(`{"id":"200","channel_id":"5","content":"edited","edited_timestamp":"t2"}`, context.temp_allocator)
	store_apply_dispatch(&s, "MESSAGE_UPDATE", upd, 0)
	testing.expect_value(t, messages_get(&s, 5)[0].content, "edited")
	del, _ := etf.from_json(`{"id":"200","channel_id":"5"}`, context.temp_allocator)
	store_apply_dispatch(&s, "MESSAGE_DELETE", del, 0)
	testing.expect_value(t, len(messages_get(&s, 5)), 0)
	typ, _ := etf.from_json(`{"channel_id":"5","user_id":"11","timestamp":1}`, context.temp_allocator)
	store_apply_dispatch(&s, "TYPING_START", typ, 1000)
	testing.expect_value(t, len(typing_users(&s, 5)), 1)
	store_expire_typing(&s, 1000 + TYPING_DURATION_MS)
	testing.expect_value(t, len(typing_users(&s, 5)), 0)
	mlu, _ := etf.from_json(`{"guild_id":"1","id":"everyone","member_count":2,"online_count":1,"groups":[],"ops":[{"op":"SYNC","range":[0,99],"items":[{"group":{"id":"online","count":1}},{"member":{"user":{"id":"11","username":"x"},"roles":[]}}]}]}`, context.temp_allocator)
	store_apply_dispatch(&s, "GUILD_MEMBER_LIST_UPDATE", mlu, 0)
	ml := s.member_lists[1]
	testing.expect(t, len(ml.items) == 2 && ml.items[0].is_group && ml.items[1].user_id == 11)
}

@(test)
alt_svc_cache :: proc(t: ^testing.T) {
	tr: Transport
	transport_init(&tr, nil)
	defer transport_destroy(&tr)
	transport_note_alt_svc(&tr, "discord.com", `h3=":443"; ma=86400`, now_ms())
	port, ok := transport_h3_alternative(&tr, "discord.com")
	testing.expect(t, ok && port == 443)
	transport_mark_h3_broken(&tr, "discord.com")
	_, ok2 := transport_h3_alternative(&tr, "discord.com")
	testing.expect(t, !ok2)
}

@(test)
message_limit_formula :: proc(t: ^testing.T) {
	testing.expect_value(t, initial_message_limit(400), 10)
	testing.expect_value(t, initial_message_limit(1200), 13)
}

@(test)
media_urls_and_headers :: proc(t: ^testing.T) {
	testing.expect_value(t, avatar_url(1, "abc"), "https://cdn.discordapp.com/avatars/1/abc.webp?size=80")
	testing.expect_value(t, avatar_url(1, "a_abc", 80, true), "https://cdn.discordapp.com/avatars/1/a_abc.webp?size=80&animated=true")
	testing.expect_value(t, default_avatar_url(Snowflake(6 << 22), "0"), "https://cdn.discordapp.com/embed/avatars/0.png")
	testing.expect_value(t, guild_icon_url(2, "h"), "https://cdn.discordapp.com/icons/2/h.webp?size=96")
	h := media_headers(DEFAULT_PLATFORM, .Image, .Cross_Site, false, "https://discord.com/", "c", `"e"`, "d")
	testing.expect_value(t, names(h), "sec-ch-ua-platform,user-agent,sec-ch-ua,sec-ch-ua-mobile,accept,sec-fetch-site,sec-fetch-mode,sec-fetch-dest,sec-fetch-storage-access,referer,accept-encoding,accept-language,cookie,if-none-match,if-modified-since,priority")
	f := media_headers(DEFAULT_PLATFORM, .Font, .Same_Origin, false, "css", "c", "", "")
	testing.expect_value(t, names(f), "origin,sec-ch-ua-platform,user-agent,sec-ch-ua,sec-ch-ua-mobile,accept,sec-fetch-site,sec-fetch-mode,sec-fetch-dest,referer,accept-encoding,accept-language,cookie,priority")
	fr, st := freshness_ms({{"cache-control", "public, max-age=3600"}}, 1000)
	testing.expect(t, st && fr == 1000 + 3_600_000)
}

@(test)
settings_delta :: proc(t: ^testing.T) {
	e := Settings_Edit{status = Status.Dnd, status_ms = 1788869911890}
	got := settings_delta_proto(&e)
	// 11 { 1 { 1: "dnd" }, 5 { 1: 1788869911890 } }
	want := []byte{0x5a, 0x10, 0x0a, 0x05, 0x0a, 0x03, 'd', 'n', 'd', 0x2a, 0x07, 0x08, 0xd2, 0xca, 0xd2, 0x87, 0x88, 0x34}
	testing.expect(t, bytes.equal(got, want), fmt.tprint(got))
	e2 := Settings_Edit{theme = Theme.Light}
	testing.expect(t, bytes.equal(settings_delta_proto(&e2), []byte{0x6a, 0x02, 0x08, 0x02}))
	// round trip through the reader used for READY
	s: Store
	store_init(&s, context.temp_allocator)
	apply_settings_proto(&s, base64.encode(got, allocator = context.temp_allocator))
	testing.expect_value(t, s.settings.status, Status.Dnd)
}
