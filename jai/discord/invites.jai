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

INVITE_MAX_AGE :: 2592000; // 30 days: "Your invite link expires in 30 days."

INVITE_LOC_HEADER :: "Guild Header"; // header menu -> Invite People
INVITE_LOC_HEADER_BUTTON :: "Guild Header Invite Button"; // person+ icon in the guild header
INVITE_LOC_CHANNELS :: "Guild Channels"; // channel row's "Invite to Channel" icon

Invite_Result :: struct {
	status: int; // HTTP status, 0 = network failure
	ok: bool;
	code: string; // allocated with the caller's allocator
	guild_id: Snowflake;
	channel_id: Snowflake;
	channel_type: int;
	inviter_id: Snowflake;
	size_total: int; // approximate_member_count (with_counts)
	size_online: int; // approximate_presence_count
}
#scope_file

api_free :: (r: *Api_Response) {
	if r.arena != null {
		virtual.arena_destroy(r.arena);
		free(r.arena);
		r.arena = null;
	}
}

invite_fields :: (out: *Invite_Result, body: V, allocator := context.allocator) {
	m := vmap(body);
	out.code = clone(fstr(m, "code"), allocator);
	g := fmap(m, "guild");
	out.guild_id = fsnow(g, "id");
	if out.guild_id == 0 { out.guild_id = fsnow(m, "guild_id"); }
	ch := fmap(m, "channel");
	out.channel_id = fsnow(ch, "id");
	out.channel_type = cast(int)(fint(ch, "type"));
	out.inviter_id = fsnow(fmap(m, "inviter"), "id");
	out.size_total = cast(int)(fint(m, "approximate_member_count"));
	out.size_online = cast(int)(fint(m, "approximate_presence_count"));
}
#scope_module

// invite_body: the createInvite body for a modal open (key order as sent).
invite_body :: (c: *Client, channel_id: Snowflake, location: string, max_age := INVITE_MAX_AGE) -> string {
	w: Json;
	json_init(*w);
	json_obj(*w);
	{ code := invite_code_for(c, channel_id);
	if code != "" { json_kstr(*w, "validate", code); } else { json_knull(*w, "validate"); } }
	json_kint(*w, "max_age", cast(s64)(max_age));
	json_kint(*w, "max_uses", 0);
	if location == INVITE_LOC_CHANNELS { json_knull(*w, "target_user_id"); }
	json_knull(*w, "target_type");
	json_kbool(*w, "temporary", false);
	json_kint(*w, "flags", 0);
	json_obj_end(*w);
	return json_string(*w);
}
#scope_export

// invite_code_for: the code of the session's invite for this channel ("" = none yet).
invite_code_for :: (c: *Client, channel_id: Snowflake, allocator := temp) -> string {
	locks.lock(*c.invite_mu);
	defer locks.unlock(*c.invite_mu);
	return clone(get(c.invite_codes, channel_id), allocator);
}

// invite_note_code: an invite was created for the channel (any thread). The server
// answers a validate with the same code while it is valid, else with a new one.
invite_note_code :: (c: *Client, channel_id: Snowflake, code: string) {
	if code == "" || channel_id == 0 { return; }
	locks.lock(*c.invite_mu);
	defer locks.unlock(*c.invite_mu);
	{ old, ok := map_find(c.invite_codes, channel_id);
	if ok {
		if old == code { return; }
		delete(old, c.allocator);
	} }
	at(*c.invite_codes, channel_id).* = clone(code, c.allocator);
}

// create_invite: POST /channels/{id}/invites as the invite modal sends it. BLOCKING.
create_invite :: (c: *Client, channel_id: Snowflake, location := INVITE_LOC_HEADER, allocator := context.allocator) -> Invite_Result {
	res: Invite_Result;
	body := transmute([]u8, invite_body(c, channel_id, location));
	r := api_call(c, "POST", strings.concatenate(string.["/channels/", snowflake_string(channel_id), "/invites"], temp), body, "application/json", context_location(location), .[], 2, 1);
	defer api_free(*r);
	res.status = r.status;
	res.ok = r.ok;
	if r.ok {
		invite_fields(*res, r.body, allocator);
		invite_note_code(c, channel_id, res.code);
	}
	return res;
}

// create_invite_async: create_invite on the client's workers; a Rest_Result
// {op = .Invite, channel_id, tag} follows, and invite_code_for has the code.
create_invite_async :: (c: *Client, channel_id: Snowflake, location := INVITE_LOC_HEADER, tag: u64 = 0) {
	j := job_new(.Api, .None);
	j.method = "POST";
	j.path = job_str(j, channel_path(channel_id, "/invites"));
	j.body = transmute([]u8, job_str(j, invite_body(c, channel_id, location)));
	j.content_type = "application/json";
	j.context_b64 = job_str(j, context_location(location));
	j.retries = 2;
	j.result = Rest_Result.{op = .Invite, channel_id = channel_id, tag = tag};
	j.on_body = (cl: *Client, body: V) {invite_note_code(cl, invite_channel_of(body), fstr(vmap(body), "code"));};
	job_submit(c, j);
}
#scope_file

invite_channel_of :: (body: V) -> Snowflake {return fsnow(fmap(vmap(body), "channel"), "id");}
#scope_module

// invite_suggestion_users: who the invite modal suggests (friends, DM partners,
// people from the other servers), without us; in that order, deduplicated.
invite_suggestion_users :: (c: *Client, guild_id: Snowflake) -> []Snowflake {
	s := *c.store;
	out := make_dynamic(Snowflake, 0, 0, temp);
	add :: (out: *[..]Snowflake, me: Snowflake, u: Snowflake) {
		if u != 0 && u != me && !slice.contains(view(out.*), u) { append(out, u); }
	}
	friends := make_dynamic(Snowflake, 0, 0, temp);
	for id, r: s.relationships { if r.kind == .Friend { append(*friends, id); } }
	slice.sort(view(friends));
	for u: friends { add(*out, s.me, u); }
	for cid: s.private_channels {
		{ ch, ok := map_find(s.channels, cid);
		if ok && ch.kind == .DM && len(ch.recipient_ids) == 1 { add(*out, s.me, ch.recipient_ids[0]); } }
	}
	Joined :: struct {
		at: string;
		id: Snowflake;
	}
	for gid: s.guild_order {
		if gid == guild_id { continue; }
		gm, ok := map_find(s.members, gid);
		if !ok { continue; }
		js := make_dynamic(Joined, 0, len(gm), temp);
		for uid, m: gm { append(*js, Joined.{m.joined_at, uid}); }
		slice.sort_by(view(js), (a: Joined, b: Joined) -> bool {return compare(a.at, b.at) < 0 || a.at == b.at && a.id < b.id;});
		for j: js { add(*out, s.me, j.id); }
	}
	return view(out);
}
#scope_export

// open_invite_modal: what opening the Instant Invite modal sends (fixture
// invite_people): the invite POST, op 8 for the suggestions' unknown members on
// the guild's first open, then science. UI thread.
open_invite_modal :: (c: *Client, guild_id: Snowflake, channel_id: Snowflake, location: string, tag: u64 = 0) {
	if channel_id != 0 { create_invite_async(c, channel_id, location, tag); }
	users := invite_suggestion_users(c, guild_id);
	ask := make_dynamic(Snowflake, 0, 0, temp);
	members := 0;
	for u: users {
		if member_get(*c.store, guild_id, u) != null {
			members += 1;
			continue;
		}
		key := Snowflake.[guild_id, u];
		if table_contains(*c.members_requested, key) { continue; }
		table_set(*c.members_requested, key, true);
		append(*ask, u);
	}
	if len(ask) > 0 {
		request_guild_members(c, guild_id, view(ask));
	} else {
		// the suggestion list is ready (memberships known): it is shown at once
		groups := 0;
		for cid: c.store.private_channels {
			{ ch, ok := map_find(c.store.channels, cid);
			if ok && ch.kind == .Group_DM { groups += 1; } }
		}
		friends := len(users) - members;
		analytics_track(c, "invite_suggestion_opened", fmt.tprintf("\"num_suggestions\":%d,\"num_friends\":%d,\"num_dms\":0,\"num_group_dms\":%d,\"guild_id\":\"%d\",\"location\":%s", friends + groups, friends, groups, guild_id, json_quote(location)));
	}
	analytics_track(c, "open_modal", fmt.tprintf("\"type\":\"Instant Invite Modal\",\"location\":\"Guild Create Invite Suggestion\",\"source\":%s", json_quote(location)));
}

// invite_copied: the modal's Copy button (the link goes to the clipboard).
invite_copied :: (c: *Client, guild_id: Snowflake, channel_id: Snowflake, code: string, location: string) {
	ct := 0;
	{ ch, ok := map_find(c.store.channels, channel_id);
	if ok { ct = cast(int)(ch.kind); } }
	analytics_track(c, "copy_instant_invite", fmt.tprintf("\"server\":\"%d\",\"channel\":\"%d\",\"channel_type\":%d,\"code\":%s,\"location\":%s", guild_id, channel_id, ct, json_quote(code), json_quote(location)));
}

// escape_shortcut_used: Escape closing a modal is the MARK_CHANNEL_READ keybind to
// the client (fixtures invite_people, join_leave_server); the tracker throttles it
// for 2 minutes (analytics.odin SCI_THROTTLES).
escape_shortcut_used :: (c: *Client) {
	analytics_keyboard_shortcut(c, "MARK_CHANNEL_READ", "esc");
}
#scope_module

json_quote :: (s: string) -> string {
	sb := strings.builder_make(temp);
	json_write_escaped(*sb, s);
	return strings.to_string(sb);
}
#scope_export

// ---- Add a Server (CreateGuildModal) ----

Guild_Add_Step :: enum u8 {
	Templates; // "Create Your Server" (the modal's landing step)
	Join; // "Join a Server"
}

// guild_add_step: science of the Add a Server modal's steps. `from_ms`: when the
// previous step was shown (0 = the modal just opened).
guild_add_step :: (c: *Client, step: Guild_Add_Step, from_ms: s64) {
	secs := ifx from_ms != 0 then cast(float64)(now_ms() - from_ms) / 1000 else 0; // JS: ms / 1000, shortest form
	if step == {
	case .Templates;
		analytics_track(c, "impression_guild_add_landing", "\"impression_type\":\"modal\",\"impression_group\":\"guild_add_flow\",\"location_stack\":[],\"location_section\":\"impression_guild_add_landing\"");
		analytics_track(c, "impression_modal_root_legacy", "\"impression_type\":\"page\",\"variant\":\"CreateGuildModal\",\"location\":\"impression_modal_root_legacy\",\"location_page\":\"impression_modal_root_legacy\",\"location_section\":\"impression_guild_add_landing\"");
		analytics_track(c, "nuo_transition", fmt.tprintf("\"flow_type\":\"create_guild\",\"from_step\":\"join_guild\",\"to_step\":\"guild_templates\",\"seconds_on_from_step\":%v", secs));
		analytics_track(c, "open_modal", "\"type\":\"Create Guild Templates\",\"location\":\"Guild List\"");
	case .Join;
		analytics_track(c, "impression_guild_add_join", "\"impression_type\":\"modal\",\"impression_group\":\"guild_add_flow\",\"location_stack\":[],\"location_section\":\"impression_guild_add_join\"");
		analytics_track(c, "nuo_transition", fmt.tprintf("\"flow_type\":\"create_guild\",\"from_step\":\"guild_templates\",\"to_step\":\"join_guild\",\"seconds_on_from_step\":%v", secs));
		analytics_track(c, "open_modal", "\"type\":\"Join Guild\",\"location\":\"Guild List\"");
	}
}

// resolve_invite: GET /invites/{code}?inputValue=<typed>&with_counts=true&with_expiration=true&with_permissions=true
// (the Join a Server modal resolves on submit, not while typing). BLOCKING.
resolve_invite :: (c: *Client, code: string, allocator := context.allocator, input_value := "") -> Invite_Result {
	res: Invite_Result;
	q: Query;
	query_init(*q, strings.concatenate(string.["/invites/", code], temp));
	query_add(*q, "inputValue", ifx input_value != "" then input_value else code);
	query_add_bool(*q, "with_counts", true);
	query_add_bool(*q, "with_expiration", true);
	query_add_bool(*q, "with_permissions", true);
	r := api_call(c, "GET", query_string(*q), .[], "", "", .[], 2, 1);
	defer api_free(*r);
	res.status = r.status;
	res.ok = r.ok;
	if r.ok { invite_fields(*res, r.body, allocator); }
	return res;
}

// accept_invite: POST /invites/{code} {"session_id":..} with
// x-context-properties {"location":..,"location_guild_id":..,"location_channel_id":..,"location_channel_type":..}. BLOCKING.
accept_invite :: (c: *Client, invite: Invite_Result, location := "Join Guild", allocator := context.allocator) -> Invite_Result {
	res: Invite_Result;
	ctx: Json;
	json_init(*ctx);
	json_obj(*ctx);
	json_kstr(*ctx, "location", location);
	if invite.guild_id != 0 { json_kstr(*ctx, "location_guild_id", snowflake_string(invite.guild_id)); }
	if invite.channel_id != 0 {
		json_kstr(*ctx, "location_channel_id", snowflake_string(invite.channel_id));
		json_kint(*ctx, "location_channel_type", cast(s64)(invite.channel_type));
	}
	json_obj_end(*ctx);
	w: Json;
	json_init(*w);
	json_obj(*w);
	json_kstr(*w, "session_id", gateway_session_id(c));
	json_obj_end(*w);
	body := transmute([]u8, json_string(*w));
	r := api_call(c, "POST", strings.concatenate(string.["/invites/", invite.code], temp), body, "application/json", context_b64(json_string(*ctx)), .[], 2, 1);
	defer api_free(*r);
	res.status = r.status;
	res.ok = r.ok;
	if r.ok { invite_fields(*res, r.body, allocator); }
	return res;
}
#scope_file

gateway_session_id :: (c: *Client) -> string {
	if c.gw != null && c.gw.session_id != "" { return c.gw.session_id; }
	return c.store.session_id;
}
#scope_export

// join_invite: the Join a Server modal's submit: resolve, then accept. The
// GUILD_CREATE that follows opens the guild at the invite's channel. BLOCKING:
// call it from a worker thread. `input`: the text as typed.
// member_of: the guilds we are in, copied from the store by the caller (this runs on a worker).
join_invite :: (c: *Client, input: string, allocator := context.allocator, member_of: []Snowflake = .{}) -> Invite_Result {
	code := invite_code_from_input(input);
	if code == "" { return .{}; }
	analytics_track(c, "invite_opened", fmt.tprintf("\"invite_code\":%s", json_quote(code)));
	inv := resolve_invite(c, code, temp, strings.trim_space(input));
	if !inv.ok { return .{status = inv.status}; }
	is_member := "false";
	for g: member_of { if g == inv.guild_id { is_member = "true"; } }
	in_ := json_quote(strings.trim_space(input));
	analytics_track(c, "network_action_invite_resolve", fmt.tprintf("\"status_code\":%d,\"url\":%s,\"request_method\":\"get\",\"resolved\":true,\"guild_id\":\"%d\",\"channel_id\":\"%d\",\"channel_type\":%d,\"inviter_id\":\"%d\",\"code\":%s,\"input_value\":%s,\"authenticated\":true,\"size_total\":%d,\"size_online\":%d,\"invite_type\":\"Server Invite\",\"user_banned\":false,\"user_is_member\":%s,\"location\":\"Join Guild\"", inv.status, json_quote(strings.concatenate(string.["/invites/", code], temp)), inv.guild_id, inv.channel_id, inv.channel_type, inv.inviter_id, json_quote(code), in_, inv.size_total, inv.size_online, is_member));
	analytics_track(c, "resolve_invite", fmt.tprintf("\"resolved\":true,\"guild_id\":\"%d\",\"channel_id\":\"%d\",\"channel_type\":%d,\"inviter_id\":\"%d\",\"code\":%s,\"input_value\":%s,\"authenticated\":true,\"size_total\":%d,\"size_online\":%d,\"destination_user_id\":null,\"invite_type\":\"Server Invite\",\"user_is_member\":%s,\"invite_instance_id\":null,\"location\":\"Join Guild\"", inv.guild_id, inv.channel_id, inv.channel_type, inv.inviter_id, json_quote(code), in_, inv.size_total, inv.size_online, is_member));
	locks.lock(*c.invite_mu);
	c.pending_join_guild, c.pending_join_channel = inv.guild_id, inv.channel_id;
	locks.unlock(*c.invite_mu);
	res := accept_invite(c, inv, "Join Guild", allocator);
	if !res.ok {
		locks.lock(*c.invite_mu);
		c.pending_join_guild, c.pending_join_channel = 0, 0;
		locks.unlock(*c.invite_mu);
	}
	return res;
}
#scope_module

// joined_guild_created: GUILD_CREATE of a guild the Join a Server modal accepted
// (UI thread). The Friends list re-checks referral eligibility (twice, as the
// route is still Friends), then the guild opens at the invite's channel: op 43,
// the first page, op 37 (fixture join_leave_server, b_join_submit).
joined_guild_created :: (c: *Client, d: etf.Map) -> bool {
	gid := fsnow(d, "id");
	locks.lock(*c.invite_mu);
	pg, pch := c.pending_join_guild, c.pending_join_channel;
	if pg == gid { c.pending_join_guild, c.pending_join_channel = 0, 0; }
	locks.unlock(*c.invite_mu);
	if pg == 0 || pg != gid { return false; }
	ch := pch;
	{ cc, ok := map_find(c.store.channels, ch);
	if !ok || cc.guild_id != gid {
		ch = 0;
		for cid: guild_channels_sorted(*c.store, gid) {
			if get(c.store.channels, cid).kind == .Guild_Text {
				ch = cid;
				break;
			}
		}
	} }
	for _: 0..1 {
		j := job_new(.Api, .None);
		j.method = "GET";
		j.path = "/users/@me/referrals/eligibility";
		j.referer = job_str(j, client_route_referer(c));
		job_submit(c, j);
	}
	h := ifx c.analytics.viewport_h > 0 then c.analytics.viewport_h else 720;
	select_channel(c, gid, ch, initial_message_limit(h));
	c.subs.not_before = now_ms() + 2; // op 37 follows op 43 and the page fetch
	if c.pending_guild_open == gid { guild_open_now(c, gid); }
	// the guild renders with the "verify your account" notice
	if !c.account_verified { analytics_app_notice(c, "app_notice_viewed", "UNVERIFIED_ACCOUNT", gid); }
	return true;
}
#scope_export

// friends_page_viewed: the Friends surface rendered after navigating to it (the
// app calls it on its route change to Friends): the DM list, the unverified
// account notice and the friends list (fixture join_leave_server, after Leave Server).
friends_page_viewed :: (c: *Client) {
	s := *c.store;
	vis := make_dynamic(Snowflake, 0, 0, temp);
	for cid: s.private_channels {
		{ ch, ok := map_find(s.channels, cid);
		if ok && len(ch.recipient_ids) > 0 { append(*vis, ch.recipient_ids[0]); } }
	}
	sb := strings.builder_make(temp);
	strings.write_byte(*sb, #char "[");
	for u, i: vis {
		if i > 0 { strings.write_byte(*sb, #char ","); }
		fmt.sbprintf(*sb, "\"%d\"", u);
	}
	strings.write_byte(*sb, #char "]");
	mobile := 0;
	for u: vis { { p, ok := map_find(s.presences, u);
if ok && p.mobile != .Offline { mobile += 1; } } }
	analytics_track(c, "dm_list_viewed", fmt.tprintf("\"num_users_visible\":%d,\"num_users_visible_with_mobile_indicator\":%d,\"now_playing_visible\":true,\"now_playing_num_cards\":0,\"now_playing_games_detected\":[],\"visible_user_ids\":%s,\"changelog_dm_visible\":false", len(vis), mobile, strings.to_string(sb)));
	if !c.account_verified { analytics_app_notice(c, "app_notice_viewed", "UNVERIFIED_ACCOUNT"); }
	// the page opens on Online, or on Add Friend while there is nobody to list
	people := 0;
	for _, r: s.relationships {
		if r.kind == {
		case .Friend; #through; case .Outgoing_Request; #through; case .Incoming_Request;
			people += 1;
		}
	}
	analytics_friends_list(c, "friends_list_viewed", ifx people > 0 then .Online else .Add_Friend);
}

