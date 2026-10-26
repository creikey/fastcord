package discord

import "core:mem/virtual"
import "core:strings"

// Invites (InstantInviteActionCreators in the official client).
//
// These are BLOCKING calls (api_call on the calling thread): use them from a
// worker thread, tooling or tests, not from the UI frame.

Invite_Result :: struct {
	status:       int, // HTTP status, 0 = network failure
	ok:           bool,
	code:         string, // allocated with the caller's allocator
	guild_id:     Snowflake,
	channel_id:   Snowflake,
	channel_type: int,
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
}

// create_invite: POST /channels/{id}/invites (createInvite(channelId, settings, location)).
// max_age 0 / max_uses 0 = never expires, unlimited uses.
create_invite :: proc(c: ^Client, channel_id: Snowflake, max_age := 0, max_uses := 0, temporary := false, location := "Guild Header", allocator := context.allocator) -> (res: Invite_Result) {
	w: Json
	json_init(&w)
	json_obj(&w)
	json_kint(&w, "max_age", i64(max_age))
	json_kint(&w, "max_uses", i64(max_uses))
	json_kbool(&w, "temporary", temporary)
	json_obj_end(&w)
	body := transmute([]byte)json_string(&w)
	r := api_call(c, "POST", strings.concatenate({"/channels/", snowflake_string(channel_id), "/invites"}, context.temp_allocator), body, "application/json", context_location(location), nil, 2, 1)
	defer api_free(&r)
	res.status = r.status
	res.ok = r.ok
	if r.ok do invite_fields(&res, r.body, allocator)
	return
}

// resolve_invite: GET /invites/{code}?with_counts=true&with_expiration=true (what the
// client fetches before showing the join modal).
resolve_invite :: proc(c: ^Client, code: string, allocator := context.allocator) -> (res: Invite_Result) {
	path := strings.concatenate({"/invites/", code, "?with_counts=true&with_expiration=true"}, context.temp_allocator)
	r := api_call(c, "GET", path, nil, "", "", nil, 2, 1)
	defer api_free(&r)
	res.status = r.status
	res.ok = r.ok
	if r.ok do invite_fields(&res, r.body, allocator)
	return
}

// accept_invite: POST /invites/{code} {"session_id":..} with
// x-context-properties = getInviteContext(location, invite):
// {"location":..,"location_guild_id":..,"location_channel_id":..,"location_channel_type":..}.
accept_invite :: proc(c: ^Client, invite: Invite_Result, location := "Desktop Invite Modal", allocator := context.allocator) -> (res: Invite_Result) {
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
	session := c.gw.session_id if c.gw != nil else ""
	json_kstr(&w, "session_id", session)
	json_obj_end(&w)
	body := transmute([]byte)json_string(&w)
	r := api_call(c, "POST", strings.concatenate({"/invites/", invite.code}, context.temp_allocator), body, "application/json", context_b64(json_string(&ctx)), nil, 2, 1)
	defer api_free(&r)
	res.status = r.status
	res.ok = r.ok
	if r.ok do invite_fields(&res, r.body, allocator)
	return
}
