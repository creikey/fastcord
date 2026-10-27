package discord

import "core:fmt"
import "core:mem/virtual"
import "core:slice"
import "core:strings"
import "fc:etf"
import "fc:locks"

// Invites (InstantInviteActionCreators in the official client), fixtures
// invite_people and join_leave_server:
//
//   open the invite modal  POST /channels/{cid}/invites, ctx {"location": <entry point>}
//                          {"validate":null|"<code>","max_age":2592000,"max_uses":0,
//                           ["target_user_id":null,] "target_type":null,"temporary":false,"flags":0}
//                          validate: null on the session's first open for the channel, then the
//                          code that open got (the server answers with the same invite).
//                          The row icon ("Guild Channels") adds target_user_id.
//                          First open per guild: op 8 for the invite suggestions' users whose
//                          membership is unknown. Science: [invite_suggestion_opened,] open_modal.
//   Join a Server          GET /invites/{code}?inputValue=<typed>&with_counts=true&with_expiration=true&with_permissions=true
//                          POST /invites/{code} {"session_id":..}, ctx {"location":"Join Guild",
//                          "location_guild_id","location_channel_id","location_channel_type"};
//                          the GUILD_CREATE that follows opens the guild (client_after_dispatch).
//
// The blocking calls (create_invite, resolve_invite, accept_invite, join_invite)
// run api_call on the calling thread: use them from a worker, tooling or tests.

INVITE_MAX_AGE :: 2592000 // 30 days: "Your invite link expires in 30 days."

INVITE_LOC_HEADER :: "Guild Header" // header menu -> Invite People
INVITE_LOC_HEADER_BUTTON :: "Guild Header Invite Button" // person+ icon in the guild header
INVITE_LOC_CHANNELS :: "Guild Channels" // channel row's "Invite to Channel" icon

Invite_Result :: struct {
	status:       int, // HTTP status, 0 = network failure
	ok:           bool,
	code:         string, // allocated with the caller's allocator
	guild_id:     Snowflake,
	channel_id:   Snowflake,
	channel_type: int,
	inviter_id:   Snowflake,
	size_total:   int, // approximate_member_count (with_counts)
	size_online:  int, // approximate_presence_count
}

@(private = "file")
api_free :: proc(r: ^Api_Response) {
	if r.arena != nil {
		virtual.arena_destroy(r.arena)
		free(r.arena)
		r.arena = nil
	}
}

@(private = "file")
invite_fields :: proc(out: ^Invite_Result, body: V, allocator := context.allocator) {
	m := vmap(body)
	out.code = strings.clone(fstr(m, "code"), allocator)
	g := fmap(m, "guild")
	out.guild_id = fsnow(g, "id")
	if out.guild_id == 0 do out.guild_id = fsnow(m, "guild_id")
	ch := fmap(m, "channel")
	out.channel_id = fsnow(ch, "id")
	out.channel_type = int(fint(ch, "type"))
	out.inviter_id = fsnow(fmap(m, "inviter"), "id")
	out.size_total = int(fint(m, "approximate_member_count"))
	out.size_online = int(fint(m, "approximate_presence_count"))
}

// invite_body: the createInvite body for a modal open (key order as sent).
@(private)
invite_body :: proc(c: ^Client, channel_id: Snowflake, location: string, max_age := INVITE_MAX_AGE) -> string {
	w: Json
	json_init(&w)
	json_obj(&w)
	if code := invite_code_for(c, channel_id); code != "" do json_kstr(&w, "validate", code)
	else do json_knull(&w, "validate")
	json_kint(&w, "max_age", i64(max_age))
	json_kint(&w, "max_uses", 0)
	if location == INVITE_LOC_CHANNELS do json_knull(&w, "target_user_id")
	json_knull(&w, "target_type")
	json_kbool(&w, "temporary", false)
	json_kint(&w, "flags", 0)
	json_obj_end(&w)
	return json_string(&w)
}

// invite_code_for: the code of the session's invite for this channel ("" = none yet).
invite_code_for :: proc(c: ^Client, channel_id: Snowflake, allocator := context.temp_allocator) -> string {
	locks.lock(&c.invite_mu)
	defer locks.unlock(&c.invite_mu)
	return strings.clone(c.invite_codes[channel_id], allocator)
}

// invite_note_code: an invite was created for the channel (any thread). The server
// answers a validate with the same code while it is valid, else with a new one.
invite_note_code :: proc(c: ^Client, channel_id: Snowflake, code: string) {
	if code == "" || channel_id == 0 do return
	locks.lock(&c.invite_mu)
	defer locks.unlock(&c.invite_mu)
	if old, ok := c.invite_codes[channel_id]; ok {
		if old == code do return
		delete(old, c.allocator)
	}
	c.invite_codes[channel_id] = strings.clone(code, c.allocator)
}

// create_invite: POST /channels/{id}/invites as the invite modal sends it. BLOCKING.
create_invite :: proc(c: ^Client, channel_id: Snowflake, location := INVITE_LOC_HEADER, allocator := context.allocator) -> (res: Invite_Result) {
	body := transmute([]byte)invite_body(c, channel_id, location)
	r := api_call(c, "POST", strings.concatenate({"/channels/", snowflake_string(channel_id), "/invites"}, context.temp_allocator), body, "application/json", context_location(location), nil, 2, 1)
	defer api_free(&r)
	res.status = r.status
	res.ok = r.ok
	if r.ok {
		invite_fields(&res, r.body, allocator)
		invite_note_code(c, channel_id, res.code)
	}
	return
}

// create_invite_async: create_invite on the client's workers; a Rest_Result
// {op = .Invite, channel_id, tag} follows, and invite_code_for has the code.
create_invite_async :: proc(c: ^Client, channel_id: Snowflake, location := INVITE_LOC_HEADER, tag: u64 = 0) {
	j := job_new(.Api, .None)
	j.method = "POST"
	j.path = job_str(j, channel_path(channel_id, "/invites"))
	j.body = transmute([]byte)job_str(j, invite_body(c, channel_id, location))
	j.content_type = "application/json"
	j.context_b64 = job_str(j, context_location(location))
	j.retries = 2
	j.result = Rest_Result{op = .Invite, channel_id = channel_id, tag = tag}
	j.on_body = proc(cl: ^Client, body: V) {invite_note_code(cl, invite_channel_of(body), fstr(vmap(body), "code"))}
	job_submit(c, j)
}

@(private = "file")
invite_channel_of :: proc(body: V) -> Snowflake {return fsnow(fmap(vmap(body), "channel"), "id")}

// invite_suggestion_users: who the invite modal suggests (friends, DM partners,
// people from the other servers), without us; in that order, deduplicated.
@(private)
invite_suggestion_users :: proc(c: ^Client, guild_id: Snowflake) -> []Snowflake {
	s := &c.store
	out := make([dynamic]Snowflake, context.temp_allocator)
	add :: proc(out: ^[dynamic]Snowflake, me, u: Snowflake) {
		if u != 0 && u != me && !slice.contains(out[:], u) do append(out, u)
	}
	friends := make([dynamic]Snowflake, context.temp_allocator)
	for id, r in s.relationships do if r.kind == .Friend do append(&friends, id)
	slice.sort(friends[:])
	for u in friends do add(&out, s.me, u)
	for cid in s.private_channels {
		if ch, ok := s.channels[cid]; ok && ch.kind == .DM && len(ch.recipient_ids) == 1 do add(&out, s.me, ch.recipient_ids[0])
	}
	Joined :: struct {
		at: string,
		id: Snowflake,
	}
	for gid in s.guild_order {
		if gid == guild_id do continue
		gm, ok := s.members[gid]
		if !ok do continue
		js := make([dynamic]Joined, 0, len(gm), context.temp_allocator)
		for uid, m in gm do append(&js, Joined{m.joined_at, uid})
		slice.sort_by(js[:], proc(a, b: Joined) -> bool {return a.at < b.at || a.at == b.at && a.id < b.id})
		for j in js do add(&out, s.me, j.id)
	}
	return out[:]
}

// open_invite_modal: what opening the Instant Invite modal sends (fixture
// invite_people): the invite POST, op 8 for the suggestions' unknown members on
// the guild's first open, then science. UI thread.
open_invite_modal :: proc(c: ^Client, guild_id, channel_id: Snowflake, location: string, tag: u64 = 0) {
	if channel_id != 0 do create_invite_async(c, channel_id, location, tag)
	users := invite_suggestion_users(c, guild_id)
	ask := make([dynamic]Snowflake, context.temp_allocator)
	members := 0
	for u in users {
		if member_get(&c.store, guild_id, u) != nil {
			members += 1
			continue
		}
		key := [2]Snowflake{guild_id, u}
		if c.members_requested[key] do continue
		c.members_requested[key] = true
		append(&ask, u)
	}
	if len(ask) > 0 {
		request_guild_members(c, guild_id, ask[:])
	} else {
		// the suggestion list is ready (memberships known): it is shown at once
		groups := 0
		for cid in c.store.private_channels {
			if ch, ok := c.store.channels[cid]; ok && ch.kind == .Group_DM do groups += 1
		}
		friends := len(users) - members
		analytics_track(c, "invite_suggestion_opened", fmt.tprintf(`"num_suggestions":%d,"num_friends":%d,"num_dms":0,"num_group_dms":%d,"guild_id":"%d","location":%s`, friends + groups, friends, groups, guild_id, json_quote(location)))
	}
	analytics_track(c, "open_modal", fmt.tprintf(`"type":"Instant Invite Modal","location":"Guild Create Invite Suggestion","source":%s`, json_quote(location)))
}

// invite_copied: the modal's Copy button (the link goes to the clipboard).
invite_copied :: proc(c: ^Client, guild_id, channel_id: Snowflake, code, location: string) {
	ct := 0
	if ch, ok := c.store.channels[channel_id]; ok do ct = int(ch.kind)
	analytics_track(c, "copy_instant_invite", fmt.tprintf(`"server":"%d","channel":"%d","channel_type":%d,"code":%s,"location":%s`, guild_id, channel_id, ct, json_quote(code), json_quote(location)))
}

// escape_shortcut_used: Escape closing a modal is the MARK_CHANNEL_READ keybind to
// the client (fixtures invite_people, join_leave_server); the tracker throttles it
// for 2 minutes (analytics.odin SCI_THROTTLES).
escape_shortcut_used :: proc(c: ^Client) {
	analytics_keyboard_shortcut(c, "MARK_CHANNEL_READ", "esc")
}

@(private)
json_quote :: proc(s: string) -> string {
	sb := strings.builder_make(context.temp_allocator)
	json_write_escaped(&sb, s)
	return strings.to_string(sb)
}

// ---- Add a Server (CreateGuildModal) ----

Guild_Add_Step :: enum u8 {
	Templates, // "Create Your Server" (the modal's landing step)
	Join, // "Join a Server"
}

// guild_add_step: science of the Add a Server modal's steps. `from_ms`: when the
// previous step was shown (0 = the modal just opened).
guild_add_step :: proc(c: ^Client, step: Guild_Add_Step, from_ms: i64) {
	secs := f64(now_ms() - from_ms) / 1000 if from_ms != 0 else 0 // JS: ms / 1000, shortest form
	switch step {
	case .Templates:
		analytics_track(c, "impression_guild_add_landing", `"impression_type":"modal","impression_group":"guild_add_flow","location_stack":[],"location_section":"impression_guild_add_landing"`)
		analytics_track(c, "impression_modal_root_legacy", `"impression_type":"page","variant":"CreateGuildModal","location":"impression_modal_root_legacy","location_page":"impression_modal_root_legacy","location_section":"impression_guild_add_landing"`)
		analytics_track(c, "nuo_transition", fmt.tprintf(`"flow_type":"create_guild","from_step":"join_guild","to_step":"guild_templates","seconds_on_from_step":%v`, secs))
		analytics_track(c, "open_modal", `"type":"Create Guild Templates","location":"Guild List"`)
	case .Join:
		analytics_track(c, "impression_guild_add_join", `"impression_type":"modal","impression_group":"guild_add_flow","location_stack":[],"location_section":"impression_guild_add_join"`)
		analytics_track(c, "nuo_transition", fmt.tprintf(`"flow_type":"create_guild","from_step":"guild_templates","to_step":"join_guild","seconds_on_from_step":%v`, secs))
		analytics_track(c, "open_modal", `"type":"Join Guild","location":"Guild List"`)
	}
}

// resolve_invite: GET /invites/{code}?inputValue=<typed>&with_counts=true&with_expiration=true&with_permissions=true
// (the Join a Server modal resolves on submit, not while typing). BLOCKING.
resolve_invite :: proc(c: ^Client, code: string, allocator := context.allocator, input_value := "") -> (res: Invite_Result) {
	q: Query
	query_init(&q, strings.concatenate({"/invites/", code}, context.temp_allocator))
	query_add(&q, "inputValue", input_value if input_value != "" else code)
	query_add_bool(&q, "with_counts", true)
	query_add_bool(&q, "with_expiration", true)
	query_add_bool(&q, "with_permissions", true)
	r := api_call(c, "GET", query_string(&q), nil, "", "", nil, 2, 1)
	defer api_free(&r)
	res.status = r.status
	res.ok = r.ok
	if r.ok do invite_fields(&res, r.body, allocator)
	return
}

// accept_invite: POST /invites/{code} {"session_id":..} with
// x-context-properties {"location":..,"location_guild_id":..,"location_channel_id":..,"location_channel_type":..}. BLOCKING.
accept_invite :: proc(c: ^Client, invite: Invite_Result, location := "Join Guild", allocator := context.allocator) -> (res: Invite_Result) {
	ctx: Json
	json_init(&ctx)
	json_obj(&ctx)
	json_kstr(&ctx, "location", location)
	if invite.guild_id != 0 do json_kstr(&ctx, "location_guild_id", snowflake_string(invite.guild_id))
	if invite.channel_id != 0 {
		json_kstr(&ctx, "location_channel_id", snowflake_string(invite.channel_id))
		json_kint(&ctx, "location_channel_type", i64(invite.channel_type))
	}
	json_obj_end(&ctx)
	w: Json
	json_init(&w)
	json_obj(&w)
	json_kstr(&w, "session_id", gateway_session_id(c))
	json_obj_end(&w)
	body := transmute([]byte)json_string(&w)
	r := api_call(c, "POST", strings.concatenate({"/invites/", invite.code}, context.temp_allocator), body, "application/json", context_b64(json_string(&ctx)), nil, 2, 1)
	defer api_free(&r)
	res.status = r.status
	res.ok = r.ok
	if r.ok do invite_fields(&res, r.body, allocator)
	return
}

@(private = "file")
gateway_session_id :: proc(c: ^Client) -> string {
	if c.gw != nil && c.gw.session_id != "" do return c.gw.session_id
	return c.store.session_id
}

// join_invite: the Join a Server modal's submit: resolve, then accept. The
// GUILD_CREATE that follows opens the guild at the invite's channel. BLOCKING:
// call it from a worker thread. `input`: the text as typed.
// member_of: the guilds we are in, copied from the store by the caller (this runs on a worker).
join_invite :: proc(c: ^Client, input: string, allocator := context.allocator, member_of: []Snowflake = nil) -> Invite_Result {
	code := invite_code_from_input(input)
	if code == "" do return {}
	analytics_track(c, "invite_opened", fmt.tprintf(`"invite_code":%s`, json_quote(code)))
	inv := resolve_invite(c, code, context.temp_allocator, strings.trim_space(input))
	if !inv.ok do return {status = inv.status}
	is_member := "false"
	for g in member_of do if g == inv.guild_id do is_member = "true"
	in_ := json_quote(strings.trim_space(input))
	analytics_track(c, "network_action_invite_resolve", fmt.tprintf(`"status_code":%d,"url":%s,"request_method":"get","resolved":true,"guild_id":"%d","channel_id":"%d","channel_type":%d,"inviter_id":"%d","code":%s,"input_value":%s,"authenticated":true,"size_total":%d,"size_online":%d,"invite_type":"Server Invite","user_banned":false,"user_is_member":%s,"location":"Join Guild"`, inv.status, json_quote(strings.concatenate({"/invites/", code}, context.temp_allocator)), inv.guild_id, inv.channel_id, inv.channel_type, inv.inviter_id, json_quote(code), in_, inv.size_total, inv.size_online, is_member))
	analytics_track(c, "resolve_invite", fmt.tprintf(`"resolved":true,"guild_id":"%d","channel_id":"%d","channel_type":%d,"inviter_id":"%d","code":%s,"input_value":%s,"authenticated":true,"size_total":%d,"size_online":%d,"destination_user_id":null,"invite_type":"Server Invite","user_is_member":%s,"invite_instance_id":null,"location":"Join Guild"`, inv.guild_id, inv.channel_id, inv.channel_type, inv.inviter_id, json_quote(code), in_, inv.size_total, inv.size_online, is_member))
	locks.lock(&c.invite_mu)
	c.pending_join_guild, c.pending_join_channel = inv.guild_id, inv.channel_id
	locks.unlock(&c.invite_mu)
	res := accept_invite(c, inv, "Join Guild", allocator)
	if !res.ok {
		locks.lock(&c.invite_mu)
		c.pending_join_guild, c.pending_join_channel = 0, 0
		locks.unlock(&c.invite_mu)
	}
	return res
}

// joined_guild_created: GUILD_CREATE of a guild the Join a Server modal accepted
// (UI thread). The Friends list re-checks referral eligibility (twice, as the
// route is still Friends), then the guild opens at the invite's channel: op 43,
// the first page, op 37 (fixture join_leave_server, b_join_submit).
@(private)
joined_guild_created :: proc(c: ^Client, d: etf.Map) -> bool {
	gid := fsnow(d, "id")
	locks.lock(&c.invite_mu)
	pg, pch := c.pending_join_guild, c.pending_join_channel
	if pg == gid do c.pending_join_guild, c.pending_join_channel = 0, 0
	locks.unlock(&c.invite_mu)
	if pg == 0 || pg != gid do return false
	ch := pch
	if cc, ok := c.store.channels[ch]; !ok || cc.guild_id != gid {
		ch = 0
		for cid in guild_channels_sorted(&c.store, gid) {
			if c.store.channels[cid].kind == .Guild_Text {
				ch = cid
				break
			}
		}
	}
	for _ in 0 ..< 2 {
		j := job_new(.Api, .None)
		j.method = "GET"
		j.path = "/users/@me/referrals/eligibility"
		j.referer = job_str(j, client_route_referer(c))
		job_submit(c, j)
	}
	h := c.analytics.viewport_h if c.analytics.viewport_h > 0 else 720
	select_channel(c, gid, ch, initial_message_limit(h))
	c.subs.not_before = now_ms() + 2 // op 37 follows op 43 and the page fetch
	if c.pending_guild_open == gid do guild_open_now(c, gid)
	// the guild renders with the "verify your account" notice
	if !c.account_verified do analytics_app_notice(c, "app_notice_viewed", "UNVERIFIED_ACCOUNT", gid)
	return true
}

// friends_page_viewed: the Friends surface rendered after navigating to it (the
// app calls it on its route change to Friends): the DM list, the unverified
// account notice and the friends list (fixture join_leave_server, after Leave Server).
friends_page_viewed :: proc(c: ^Client) {
	s := &c.store
	vis := make([dynamic]Snowflake, context.temp_allocator)
	for cid in s.private_channels {
		if ch, ok := s.channels[cid]; ok && len(ch.recipient_ids) > 0 do append(&vis, ch.recipient_ids[0])
	}
	sb := strings.builder_make(context.temp_allocator)
	strings.write_byte(&sb, '[')
	for u, i in vis {
		if i > 0 do strings.write_byte(&sb, ',')
		fmt.sbprintf(&sb, `"%d"`, u)
	}
	strings.write_byte(&sb, ']')
	mobile := 0
	for u in vis do if p, ok := s.presences[u]; ok && p.mobile != .Offline do mobile += 1
	analytics_track(c, "dm_list_viewed", fmt.tprintf(`"num_users_visible":%d,"num_users_visible_with_mobile_indicator":%d,"now_playing_visible":true,"now_playing_num_cards":0,"now_playing_games_detected":[],"visible_user_ids":%s,"changelog_dm_visible":false`, len(vis), mobile, strings.to_string(sb)))
	if !c.account_verified do analytics_app_notice(c, "app_notice_viewed", "UNVERIFIED_ACCOUNT")
	// the page opens on Online, or on Add Friend while there is nobody to list
	people := 0
	for _, r in s.relationships {
		#partial switch r.kind {
		case .Friend, .Outgoing_Request, .Incoming_Request:
			people += 1
		}
	}
	analytics_friends_list(c, "friends_list_viewed", .Online if people > 0 else .Add_Friend)
}
