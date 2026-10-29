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
	error_code: int; // a failure's JSON "code"
	captcha: bool; // the failure asks for a captcha
}

// invite_call: a blocking api_call whose body becomes an Invite_Result (code in allocator).
invite_call :: (c: *Client, method: string, path: string, body: string, context_b64: string, allocator: Allocator) -> Invite_Result {
	r := api_call(c, method, path, cast([]u8) body, ifx body then "application/json" else "", context_b64, .[], 2, 1);
	defer if r.arena {
		fini(r.arena);
		free(r.arena);
	}
	res := Invite_Result.{status = r.status, ok = r.ok};
	res.error_code, res.captcha = api_error(r);
	if !r.ok return res;
	m := vmap(r.body);
	res.code = copy_string(fstr(m, "code"),, allocator);
	res.guild_id = fsnow(fmap(m, "guild"), "id");
	if !res.guild_id res.guild_id = fsnow(m, "guild_id");
	ch := fmap(m, "channel");
	res.channel_id = fsnow(ch, "id");
	res.channel_type = fint(ch, "type");
	res.inviter_id = fsnow(fmap(m, "inviter"), "id");
	res.size_total = fint(m, "approximate_member_count");
	res.size_online = fint(m, "approximate_presence_count");
	return res;
}

// The invite modal's Edit invite link: Expire After (seconds, 0 = never), Max Number of Uses (0 = no
// limit) and Grant temporary membership.
Invite_Settings :: struct {
	max_age := INVITE_MAX_AGE;
	max_uses: int;
	temporary: bool;
}

// invite_body: the createInvite body for a modal open (key order as sent). fresh: Generate a New Link,
// which asks for a new code ("validate": null) with the edited settings.
invite_body :: (c: *Client, channel_id: Snowflake, location: string, settings := Invite_Settings.{}, fresh := false) -> string {
	w: Json;
	json_init(*w);
	json_obj(*w);
	code := ifx fresh then "" else invite_code_for(c, channel_id);
	if code json_kstr(*w, "validate", code); else json_knull(*w, "validate");
	json_kint(*w, "max_age", settings.max_age);
	json_kint(*w, "max_uses", settings.max_uses);
	if location == INVITE_LOC_CHANNELS json_knull(*w, "target_user_id");
	json_knull(*w, "target_type");
	json_kbool(*w, "temporary", settings.temporary);
	json_kint(*w, "flags", 0);
	json_obj_end(*w);
	return json_string(*w);
}

// invite_code_for: the code of the session's invite for this channel ("" = none yet).
invite_code_for :: (c: *Client, channel_id: Snowflake, allocator := temp) -> string {
	locks.lock(*c.invite_mu);
	defer locks.unlock(*c.invite_mu);
	_, code := table_find(*c.invite_codes, channel_id);
	return copy_string(code,, allocator);
}

// invite_note_code: an invite was created for the channel (any thread). The server
// answers a validate with the same code while it is valid, else with a new one.
invite_note_code :: (c: *Client, channel_id: Snowflake, code: string) {
	if !code || !channel_id return;
	locks.lock(*c.invite_mu);
	defer locks.unlock(*c.invite_mu);
	old := table_find_pointer(*c.invite_codes, channel_id);
	if old && old.* == code return;
	if old free(old.*,, c.allocator);
	table_set(*c.invite_codes, channel_id, copy_string(code,, c.allocator));
}

// create_invite: POST /channels/{id}/invites as the invite modal sends it. BLOCKING.
create_invite :: (c: *Client, channel_id: Snowflake, location := INVITE_LOC_HEADER, allocator := context.allocator) -> Invite_Result {
	res := invite_call(c, "POST", tprint("/channels/%/invites", channel_id), invite_body(c, channel_id, location), context_location(location), allocator);
	if res.ok invite_note_code(c, channel_id, res.code);
	return res;
}

// create_invite_async: create_invite on the client's workers; a Rest_Result
// {op = .Invite, channel_id, tag} follows, and invite_code_for has the code.
create_invite_async :: (c: *Client, channel_id: Snowflake, location := INVITE_LOC_HEADER, tag: u64 = 0, settings := Invite_Settings.{}, fresh := false) {
	j := job_new(.Api, .None);
	j.method = "POST";
	j.path = job_str(j, channel_path(channel_id, "/invites"));
	j.body = cast([]u8) job_str(j, invite_body(c, channel_id, location, settings, fresh));
	j.content_type = "application/json";
	j.context_b64 = job_str(j, context_location(location));
	j.retries = 2;
	j.result = .{op = .Invite, channel_id = channel_id, tag = tag};
	j.on_body = (cl: *Client, body: V) {
		m := vmap(body);
		invite_note_code(cl, fsnow(fmap(m, "channel"), "id"), fstr(m, "code"));
	};
	job_submit(c, j);
}

// invite_suggestion_users: who the invite modal suggests (friends, DM partners,
// people from the other servers), without us; in that order, deduplicated (temp).
invite_suggestion_users :: (c: *Client, guild_id: Snowflake) -> []Snowflake {
	s := *c.store;
	out: [..]Snowflake;
	out.allocator = temp;
	add :: (u: Snowflake) #expand {
		if u && u != `s.me && !array_find(`out, u) array_add(*`out, u);
	}
	friends: [..]Snowflake;
	friends.allocator = temp;
	for r, id: s.relationships if r.kind == .Friend array_add(*friends, id);
	quick_sort(friends, (a: Snowflake, b: Snowflake) -> int { return ifx a < b then -1 else xx (a > b); });
	for friends add(it);
	for cid: s.private_channels {
		ch := table_find_pointer(*s.channels, cid);
		if ch && ch.kind == .DM && ch.recipient_ids.count == 1 add(ch.recipient_ids[0]);
	}
	Joined :: struct { at: string; id: Snowflake; }
	for gid: s.guild_order {
		if gid == guild_id continue;
		gm := table_find_pointer(*s.members, gid);
		if !gm continue;
		js: [..]Joined;
		js.allocator = temp;
		array_reserve(*js, gm.count);
		for m, uid: gm.* array_add(*js, .{m.joined_at, uid});
		quick_sort(js, (a: Joined, b: Joined) -> int {
			d := compare(a.at, b.at);
			return ifx d then d else ifx a.id < b.id then -1 else xx (a.id > b.id);
		});
		for js add(it.id);
	}
	return out;
}

// open_invite_modal: what opening the Instant Invite modal sends (fixture
// invite_people): the invite POST, op 8 for the suggestions' unknown members on
// the guild's first open, then science. UI thread.
open_invite_modal :: (c: *Client, guild_id: Snowflake, channel_id: Snowflake, location: string, tag: u64 = 0) {
	if channel_id create_invite_async(c, channel_id, location, tag);
	users := invite_suggestion_users(c, guild_id);
	ask: [..]Snowflake;
	ask.allocator = temp;
	members := 0;
	for u: users {
		if member_get(*c.store, guild_id, u) {
			members += 1;
			continue;
		}
		key := Snowflake.[guild_id, u];
		if table_contains(*c.members_requested, key) continue;
		table_set(*c.members_requested, key, true);
		array_add(*ask, u);
	}
	if ask {
		request_guild_members(c, guild_id, ask);
	} else {
		// the suggestion list is ready (memberships known): it is shown at once
		groups := 0;
		for cid: c.store.private_channels {
			ch := table_find_pointer(*c.store.channels, cid);
			if ch && ch.kind == .Group_DM groups += 1;
		}
		friends := users.count - members;
		analytics_track(c, "invite_suggestion_opened", tprint("\"num_suggestions\":%,\"num_friends\":%,\"num_dms\":0,\"num_group_dms\":%,\"guild_id\":\"%\",\"location\":%", friends + groups, friends, groups, guild_id, json_quote(location)));
	}
	analytics_track(c, "open_modal", tprint("\"type\":\"Instant Invite Modal\",\"location\":\"Guild Create Invite Suggestion\",\"source\":%", json_quote(location)));
}

// invite_copied: the modal's Copy button (the link goes to the clipboard).
invite_copied :: (c: *Client, guild_id: Snowflake, channel_id: Snowflake, code: string, location: string) {
	ch := table_find_pointer(*c.store.channels, channel_id);
	ct := ifx ch then cast(int) ch.kind else 0;
	analytics_track(c, "copy_instant_invite", tprint("\"server\":\"%\",\"channel\":\"%\",\"channel_type\":%,\"code\":%,\"location\":%", guild_id, channel_id, ct, json_quote(code), json_quote(location)));
}

// escape_shortcut_used: Escape closing a modal is the MARK_CHANNEL_READ keybind to
// the client (fixtures invite_people, join_leave_server); the tracker throttles it
// for 2 minutes (analytics.jai SCI_THROTTLES).
escape_shortcut_used :: (c: *Client) {
	analytics_keyboard_shortcut(c, "MARK_CHANNEL_READ", "esc");
}

// json_quote: s as a JSON string literal (temp).
json_quote :: (s: string) -> string {
	buf: [..]u8;
	buf.allocator = temp;
	json_write_escaped(*buf, s);
	return cast(string) buf;
}

// ---- Add a Server (CreateGuildModal) ----

Guild_Add_Step :: enum u8 {
	Templates; // "Create Your Server" (the modal's landing step)
	Join; // "Join a Server"
}

// guild_add_step: science of the Add a Server modal's steps. `from_ms`: when the
// previous step was shown (0 = the modal just opened).
guild_add_step :: (c: *Client, step: Guild_Add_Step, from_ms: s64) {
	secs: float64 = ifx from_ms then (now_ms() - from_ms) / 1000.0 else 0; // JS: ms / 1000, shortest form
	if step == {
		case .Templates;
			analytics_track(c, "impression_guild_add_landing", "\"impression_type\":\"modal\",\"impression_group\":\"guild_add_flow\",\"location_stack\":[],\"location_section\":\"impression_guild_add_landing\"");
			analytics_track(c, "impression_modal_root_legacy", "\"impression_type\":\"page\",\"variant\":\"CreateGuildModal\",\"location\":\"impression_modal_root_legacy\",\"location_page\":\"impression_modal_root_legacy\",\"location_section\":\"impression_guild_add_landing\"");
			analytics_track(c, "nuo_transition", tprint("\"flow_type\":\"create_guild\",\"from_step\":\"join_guild\",\"to_step\":\"guild_templates\",\"seconds_on_from_step\":%", formatFloat(secs, trailing_width = -1, zero_removal = .YES)));
			analytics_track(c, "open_modal", "\"type\":\"Create Guild Templates\",\"location\":\"Guild List\"");
		case .Join;
			analytics_track(c, "impression_guild_add_join", "\"impression_type\":\"modal\",\"impression_group\":\"guild_add_flow\",\"location_stack\":[],\"location_section\":\"impression_guild_add_join\"");
			analytics_track(c, "nuo_transition", tprint("\"flow_type\":\"create_guild\",\"from_step\":\"guild_templates\",\"to_step\":\"join_guild\",\"seconds_on_from_step\":%", formatFloat(secs, trailing_width = -1, zero_removal = .YES)));
			analytics_track(c, "open_modal", "\"type\":\"Join Guild\",\"location\":\"Guild List\"");
	}
}

// resolve_invite: GET /invites/{code}?inputValue=<typed>&with_counts=true&with_expiration=true&with_permissions=true
// (the Join a Server modal resolves on submit, not while typing). BLOCKING.
resolve_invite :: (c: *Client, code: string, allocator := context.allocator, input_value := "") -> Invite_Result {
	q: Query;
	query_init(*q, tprint("/invites/%", code));
	query_add(*q, "inputValue", ifx input_value then input_value else code);
	query_add_bool(*q, "with_counts", true);
	query_add_bool(*q, "with_expiration", true);
	query_add_bool(*q, "with_permissions", true);
	return invite_call(c, "GET", query_string(*q), "", "", allocator);
}

// accept_invite: POST /invites/{code} {"session_id":..} with
// x-context-properties {"location":..,"location_guild_id":..,"location_channel_id":..,"location_channel_type":..}. BLOCKING.
accept_invite :: (c: *Client, invite: Invite_Result, location := "Join Guild", allocator := context.allocator) -> Invite_Result {
	body, ctx := accept_parts(c, invite.guild_id, invite.channel_id, invite.channel_type, location);
	return invite_call(c, "POST", tprint("/invites/%", invite.code), body, ctx, allocator);
}

// accept_parts: the accept POST's body and x-context-properties (temp).
accept_parts :: (c: *Client, guild_id: Snowflake, channel_id: Snowflake, channel_type: int, location: string, instance_id := "") -> body: string, context_b64: string {
	ctx: Json;
	json_init(*ctx);
	json_obj(*ctx);
	json_kstr(*ctx, "location", location);
	if guild_id json_ksnow(*ctx, "location_guild_id", guild_id);
	if channel_id {
		json_ksnow(*ctx, "location_channel_id", channel_id);
		json_kint(*ctx, "location_channel_type", channel_type);
	}
	if instance_id json_kstr(*ctx, "invite_instance_id", instance_id);
	json_obj_end(*ctx);
	w: Json;
	json_init(*w);
	json_obj(*w);
	json_kstr(*w, "session_id", ifx c.gw && c.gw.session_id then c.gw.session_id else c.store.session_id);
	if instance_id json_kstr(*w, "invite_instance_id", instance_id);
	json_obj_end(*w);
	return json_string(*w), context_b64(json_string(*ctx));
}

// ---- Invite links in messages (the client's invite embed and invite modal) ----

INVITE_LOC_EMBED :: "Invite Button Embed";
INVITE_LOC_MODAL :: "Desktop Invite Modal";

Invite_Preview :: struct {
	state: enum u8 { Loading; Ok; Expired; Banned; Error; }; // Error: the accept failed (INVITE_ACCEPT_FAILURE)
	joining: bool; // accept in flight
	guild_id: Snowflake;
	channel_id: Snowflake;
	channel_type: int;
	name: string; // client allocator, set once
	icon: string;
	online: int;
	members: int;
	error_code: int; // the failed accept's body code
	error: string; // and message (client allocator)
	event: Scheduled_Event; // a link with ?event=<id>: the invite's guild_scheduled_event (id 0 = none)
}

// invite_preview_key: the previews table's key, "<code>" or "<code>?event=<id>" (temp).
invite_preview_key :: (code: string, event_id: Snowflake) -> string {
	return ifx event_id then tprint("%?event=%", code, event_id) else code;
}

invite_key_parts :: (key: string) -> code: string, event: Snowflake {
	i := find_index_from_left(key, "?event=");
	if i < 0 return key, 0;
	ev, ok := string_to_int(advance(key, i + "?event=".count), T = u64);
	return slice(key, 0, i), ifx ok then ev else 0;
}

// invite_instance_id: "<message id>:<code>" (module 21599 `_U`).
invite_instance_id :: (message_id: Snowflake, code: string) -> string { return tprint("%:%", message_id, code); }

// invite_preview: the resolved invite for a code seen in a message, fetched on first use
// (the embed's resolveInvite(code, undefined, {inviteInstanceId}): invite_opened, then
// GET /invites/{code} without inputValue, tracked as network_action_invite_resolve with no
// location, so no resolve_invite). UI thread; the copy's strings live as long as the client.
// member_of: the guilds we're in (user_is_member is computed on the worker).
// key: invite_preview_key (an event link adds guild_scheduled_event_id).
invite_preview :: (c: *Client, key: string, message_id: Snowflake, member_of: []Snowflake) -> Invite_Preview {
	locks.lock(*c.invite_mu);
	p := table_find_pointer(*c.invite_previews, key);
	if !p table_add(*c.invite_previews, copy_string(key,, c.allocator), .{});
	out := ifx p then p.* else .{};
	locks.unlock(*c.invite_mu);
	if p return out;
	code, event := invite_key_parts(key);
	analytics_track(c, "invite_opened", tprint("\"invite_code\":%,\"invite_instance_id\":%", json_quote(code), json_quote(invite_instance_id(message_id, code))));
	q: Query;
	query_init(*q, tprint("/invites/%", code));
	query_add_bool(*q, "with_counts", true);
	query_add_bool(*q, "with_expiration", true);
	if event query_add_snow(*q, "guild_scheduled_event_id", event);
	query_add_bool(*q, "with_permissions", true);
	j := job_new(.Api, .None);
	j.method = "GET";
	j.path = job_str(j, query_string(*q));
	j.retries = 2;
	sb: String_Builder;
	append(*sb, ",");
	for member_of print_to_builder(*sb, "%,", it);
	j.track_props = job_str(j, builder_to_string(*sb,, temp));
	j.on_response = (cl: *Client, j: *Job, status: int, body: V) {
		m := vmap(body);
		g := fmap(m, "guild");
		code := invite_path_code(j.path);
		url := json_quote(slice(j.path, 0, find_index_from_left(j.path, #char "?")));
		ok := status == 200 && g;
		if ok {
			gid := fsnow(g, "id");
			ch := fmap(m, "channel");
			analytics_track(cl, "network_action_invite_resolve", tprint("\"status_code\":%,\"url\":%,\"request_method\":\"get\",\"resolved\":true,\"guild_id\":\"%\",\"channel_id\":\"%\",\"channel_type\":%,\"inviter_id\":\"%\",\"code\":%,\"authenticated\":true,\"size_total\":%,\"size_online\":%,\"invite_type\":\"Server Invite\",\"user_banned\":false,\"user_is_member\":%",
				status, url, gid, fsnow(ch, "id"), fint(ch, "type"), fsnow(fmap(m, "inviter"), "id"), json_quote(code), fint(m, "approximate_member_count"), fint(m, "approximate_presence_count"), contains(j.track_props, tprint(",%,", gid))));
		} else {
			analytics_track(cl, "network_action_invite_resolve", tprint("\"status_code\":%,\"url\":%,\"request_method\":\"get\",\"resolved\":false,\"code\":%,\"authenticated\":true,\"user_banned\":%,\"user_is_member\":false",
				status, url, json_quote(code), fint(m, "code") == USER_BANNED));
		}
		locks.lock(*cl.invite_mu);
		defer locks.unlock(*cl.invite_mu);
		p := table_find_pointer(*cl.invite_previews, invite_path_key(j.path));
		if !p return;
		if !ok {
			p.state = ifx fint(m, "code") == USER_BANNED then .Banned else .Expired;
			return;
		}
		p.guild_id = fsnow(g, "id");
		p.name = copy_string(fstr(g, "name"),, cl.allocator);
		p.icon = copy_string(fstr(g, "icon"),, cl.allocator);
		ch := fmap(m, "channel");
		p.channel_id = fsnow(ch, "id");
		p.channel_type = fint(ch, "type");
		p.online = fint(m, "approximate_presence_count");
		p.members = fint(m, "approximate_member_count");
		ev := fmap(m, "guild_scheduled_event");
		if ev {
			event_fill(*p.event, ev, cl.allocator);
			p.event.user_count = -1; // the card's count comes from the counts request, not the invite
		}
		p.state = .Ok;
	};
	job_submit(c, j);
	return out;
}

USER_BANNED :: 40007;

// join_invite_preview: accept a resolved invite (acceptInvite): POST /invites/{code}
// {"session_id","invite_instance_id"} with the location's context plus invite_instance_id.
// The GUILD_CREATE that follows opens the invite's channel; a failure leaves the invite in
// the Error state with the body's code and message (INVITE_ACCEPT_FAILURE).
join_invite_preview :: (c: *Client, key: string, location: string, instance_id: string) {
	code := invite_key_parts(key);
	locks.lock(*c.invite_mu);
	p := table_find_pointer(*c.invite_previews, key);
	if !p || p.guild_id == 0 || p.joining {
		locks.unlock(*c.invite_mu);
		return;
	}
	p.joining = true;
	inv := p.*;
	c.pending_join_guild, c.pending_join_channel = inv.guild_id, inv.channel_id;
	locks.unlock(*c.invite_mu);
	body, ctx := accept_parts(c, inv.guild_id, inv.channel_id, inv.channel_type, location, instance_id);
	j := job_new(.Api, .None);
	j.method = "POST";
	j.path = job_str(j, tprint("/invites/%", code));
	j.body = cast([]u8) job_str(j, body);
	j.content_type = "application/json";
	j.context_b64 = job_str(j, ctx);
	j.retries = 2;
	j.retry_429 = 1;
	j.on_response = (cl: *Client, j: *Job, status: int, body: V) {
		locks.lock(*cl.invite_mu);
		defer locks.unlock(*cl.invite_mu);
		// every preview of the code (the plain link and its event links)
		code := invite_path_code(j.path);
		for * p, key: cl.invite_previews {
			if invite_key_parts(key) != code continue;
			p.joining = false;
			if status / 100 == 2 {
				p.state = .Ok; // INVITE_ACCEPT_SUCCESS
				continue;
			}
			if cl.pending_join_guild == p.guild_id cl.pending_join_guild, cl.pending_join_channel = 0, 0;
			m := vmap(body);
			p.state = .Error;
			p.error_code = fint(m, "code");
			free(p.error,, cl.allocator);
			p.error = copy_string(fstr(m, "message"),, cl.allocator);
		}
	};
	job_submit(c, j);
}

invite_path_code :: (path: string) -> string {
	t := advance(path, "/invites/".count);
	i := find_index_from_left(t, #char "?");
	if i >= 0 t.count = i;
	return t;
}

// invite_path_key: the previews key of a resolve request's path.
invite_path_key :: (path: string) -> string {
	PARAM :: "guild_scheduled_event_id=";
	i := find_index_from_left(path, PARAM);
	if i < 0 return invite_path_code(path);
	ev := advance(path, i + PARAM.count);
	j := find_index_from_left(ev, #char "&");
	if j >= 0 ev.count = j;
	return tprint("%?event=%", invite_path_code(path), ev);
}

// join_invite: the Join a Server modal's submit: resolve, then accept. The
// GUILD_CREATE that follows opens the guild at the invite's channel. BLOCKING:
// call it from a worker thread. `input`: the text as typed.
// member_of: the guilds we are in, copied from the store by the caller (this runs on a worker).
join_invite :: (c: *Client, input: string, allocator := context.allocator, member_of: []Snowflake = .[]) -> Invite_Result {
	code := invite_code_from_input(input);
	if !code return .{};
	analytics_track(c, "invite_opened", tprint("\"invite_code\":%", json_quote(code)));
	typed := trim(input);
	inv := resolve_invite(c, code, temp, typed);
	if !inv.ok return .{status = inv.status, error_code = inv.error_code, captcha = inv.captcha};
	is_member := array_find(member_of, inv.guild_id);
	in_ := json_quote(typed);
	analytics_track(c, "network_action_invite_resolve", tprint("\"status_code\":%,\"url\":%,\"request_method\":\"get\",\"resolved\":true,\"guild_id\":\"%\",\"channel_id\":\"%\",\"channel_type\":%,\"inviter_id\":\"%\",\"code\":%,\"input_value\":%,\"authenticated\":true,\"size_total\":%,\"size_online\":%,\"invite_type\":\"Server Invite\",\"user_banned\":false,\"user_is_member\":%,\"location\":\"Join Guild\"", inv.status, json_quote(tprint("/invites/%", code)), inv.guild_id, inv.channel_id, inv.channel_type, inv.inviter_id, json_quote(code), in_, inv.size_total, inv.size_online, is_member));
	analytics_track(c, "resolve_invite", tprint("\"resolved\":true,\"guild_id\":\"%\",\"channel_id\":\"%\",\"channel_type\":%,\"inviter_id\":\"%\",\"code\":%,\"input_value\":%,\"authenticated\":true,\"size_total\":%,\"size_online\":%,\"destination_user_id\":null,\"invite_type\":\"Server Invite\",\"user_is_member\":%,\"invite_instance_id\":null,\"location\":\"Join Guild\"", inv.guild_id, inv.channel_id, inv.channel_type, inv.inviter_id, json_quote(code), in_, inv.size_total, inv.size_online, is_member));
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

// joined_guild_created: GUILD_CREATE of a guild the Join a Server modal accepted
// (UI thread). The Friends list re-checks referral eligibility (twice, as the
// route is still Friends), then the guild opens at the invite's channel: op 43,
// the first page, op 37 (fixture join_leave_server, b_join_submit).
joined_guild_created :: (c: *Client, d: etf.Map) -> bool {
	gid := fsnow(d, "id");
	locks.lock(*c.invite_mu);
	pg, ch := c.pending_join_guild, c.pending_join_channel;
	if pg == gid c.pending_join_guild, c.pending_join_channel = 0, 0;
	locks.unlock(*c.invite_mu);
	if !pg || pg != gid return false;
	cc := table_find_pointer(*c.store.channels, ch);
	if !cc || cc.guild_id != gid {
		ch = 0;
		for cid: guild_channels_sorted(*c.store, gid) {
			chan := table_find_pointer(*c.store.channels, cid);
			if chan && chan.kind == .Guild_Text {
				ch = cid;
				break;
			}
		}
	}
	for 1..2 {
		j := job_new(.Api, .None);
		j.method = "GET";
		j.path = "/users/@me/referrals/eligibility";
		j.referer = job_str(j, client_route_referer(c));
		job_submit(c, j);
	}
	select_channel(c, gid, ch, initial_message_limit(ifx c.analytics.viewport_h > 0 then c.analytics.viewport_h else 720));
	c.subs.not_before = now_ms() + 2; // op 37 follows op 43 and the page fetch
	if c.pending_guild_open == gid guild_open_now(c, gid);
	// the guild renders with the "verify your account" notice
	if !c.account_verified analytics_app_notice(c, "app_notice_viewed", "UNVERIFIED_ACCOUNT", gid);
	return true;
}

// friends_page_viewed: the Friends surface rendered after navigating to it (the
// app calls it on its route change to Friends): the DM list, the unverified
// account notice and the friends list (fixture join_leave_server, after Leave Server).
friends_page_viewed :: (c: *Client) {
	s := *c.store;
	sb: String_Builder;
	sb.allocator = temp;
	append(*sb, "[");
	visible, mobile := 0, 0;
	for cid: s.private_channels {
		ch := table_find_pointer(*s.channels, cid);
		if !ch || !ch.recipient_ids continue;
		u := ch.recipient_ids[0];
		print_to_builder(*sb, ifx visible then ",\"%\"" else "\"%\"", u);
		visible += 1;
		p := table_find_pointer(*s.presences, u);
		if p && p.mobile != .Offline mobile += 1;
	}
	append(*sb, "]");
	analytics_track(c, "dm_list_viewed", tprint("\"num_users_visible\":%,\"num_users_visible_with_mobile_indicator\":%,\"now_playing_visible\":true,\"now_playing_num_cards\":0,\"now_playing_games_detected\":[],\"visible_user_ids\":%,\"changelog_dm_visible\":false", visible, mobile, builder_to_string(*sb,, temp)));
	promo_shop_entry(c); // at launch (fixture cold_start); a navigation mounted it already (select_channel)
	if !c.account_verified analytics_app_notice(c, "app_notice_viewed", "UNVERIFIED_ACCOUNT");
	// the page opens on Online, or on Add Friend while there is nobody to list
	people := 0;
	for s.relationships if it.kind == .Friend || it.kind == .Outgoing_Request || it.kind == .Incoming_Request people += 1;
	analytics_friends_list(c, "friends_list_viewed", ifx people > 0 then .Online else .Add_Friend);
}
