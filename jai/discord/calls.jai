// DM / group DM calls (fixture dm_call). The caller sends op 4 into the DM
// channel; the server creates the call (CALL_CREATE to every recipient) and
// the caller rings the others right after its own CALL_CREATE arrives:
//   POST /channels/{id}/call/ring {"recipients":null}
// followed by GET /activities/shelf twice. CALL_UPDATE carries who is ringing;
// the callee joins with the same op 4. CALL_DELETE ends it.
// Declining a ring was not captured, so a decline here only dismisses the
// ring locally (no request is sent).

Call :: struct {
	channel_id: Snowflake;
	message_id: Snowflake;
	ringing: [..]Snowflake;
	dismissed: bool; // ring declined locally
}
#scope_file

call_apply :: (c: *Client, d: etf.Map) {
	cid := fsnow(d, "channel_id");
	if cid == 0 { return; }
	if c.social.calls == null { c.social.calls = Map(Snowflake, Call).{}; }
	call, ok := map_find_ptr(*c.social.calls, cid);
	if !ok {
		at(*c.social.calls, cid).* = Call.{channel_id = cid, ringing = make_dynamic(Snowflake, 0, 0, c.allocator)};
		call = at(*c.social.calls, cid);
	}
	{ mid := fsnow(d, "message_id");
	if mid != 0 { call.message_id = mid; } }
	if vhas(d, "ringing") {
		was := slice_has(view(call.ringing), c.store.me);
		clear(*call.ringing);
		for r: flist(d, "ringing") { append(*call.ringing, vsnow(r)); }
		if !was { call.dismissed = false; } // a new ring
	}
}

slice_has :: (s: []Snowflake, v: Snowflake) -> bool {
	for x: s { if x == v { return true; } }
	return false;
}
#scope_export

// calls_dispatch: CALL_CREATE / CALL_UPDATE / CALL_DELETE (UI thread, from client_poll).
calls_dispatch :: (c: *Client, name: string, data: V) {
	if name == {
	case "CALL_CREATE"; #through; case "CALL_UPDATE";
		d := vmap(data);
		call_apply(c, d);
		cid := fsnow(d, "channel_id");
		if name == "CALL_CREATE" && cid != 0 && c.social.ring_on_create == cid {
			c.social.ring_on_create = 0;
			ring_call(c, cid);
			call_shelf_later(c, 30, analytics_shelf_fetched);
			call_shelf_later(c, 240, analytics_shelf_fetched_null);
		}
	case "CALL_DELETE";
		cid := fsnow(vmap(data), "channel_id");
		{ call, ok := map_find_ptr(*c.social.calls, cid);
		if ok {
			delete(call.ringing);
			delete_key(*c.social.calls, cid);
		} }
		if c.social.ring_on_create == cid { c.social.ring_on_create = 0; }
	case "READY";
		for * _, call: c.social.calls { delete(call.ringing); }
		clear(*c.social.calls);
	}
}
#scope_file

// call_shelf_later: GET /activities/shelf of a call (no guild), with its network_action.
call_shelf_later :: (c: *Client, delay_ms: s64, on_done: (c: *Client, j: *Job, status: int)) {
	j := job_new(.Api, .None);
	j.method = "GET";
	j.path = "/activities/shelf";
	j.not_before = now_ms() + delay_ms;
	j.on_done = on_done;
	job_submit(c, j);
}
#scope_export

// call_get: the ongoing call in a DM / group DM (nil when none).
call_get :: (c: *Client, channel_id: Snowflake) -> *Call {
	{ call, ok := map_find_ptr(*c.social.calls, channel_id);
	if ok { return call; } }
	return null;
}

// incoming_call: a call that rings us right now and that we haven't dismissed (0 if none).
incoming_call :: (c: *Client) -> Snowflake {
	for * cid, call: c.social.calls {
		if !call.dismissed && slice_has(view(call.ringing), c.store.me) { return cid; }
	}
	return 0;
}

// call_decline: dismiss the ring locally (declining was not captured).
call_decline :: (c: *Client, channel_id: Snowflake) {
	{ call := call_get(c, channel_id);
	if call != null { call.dismissed = true; } }
}

// dm_call_start: the DM header's "Start Voice Call". op 4 into the DM; the ring
// follows the call's CALL_CREATE. Joining a call that already exists rings nobody.
dm_call_start :: (c: *Client, channel_id: Snowflake, self_mute := false, self_deaf := false) {
	if call_get(c, channel_id) == null { c.social.ring_on_create = channel_id; }
	voice_join(c, 0, channel_id, self_mute, self_deaf, track = false);
	analytics_join_voice(c, 0, channel_id);
}

// call_accept: the incoming call's "Join Call" (fixture dm_call/b_join_from_ring).
call_accept :: (c: *Client, channel_id: Snowflake, self_mute := false, self_deaf := false) {
	voice_join(c, 0, channel_id, self_mute, self_deaf, track = false);
	call_shelf_later(c, 320, analytics_shelf_fetched);
	w := aw_begin();
	json_knull(*w, "guild_id");
	if channel_get(*c.store, channel_id) != null { aw_channel(*w, c, channel_id); }
	json_kstr(*w, "location", "incoming call modal");
	aw_track(c, "ring_call_accepted", *w);
	b := aw_begin();
	json_kstr(*b, "button_name", "Join Call");
	json_kstr(*b, "location", "incoming call modal");
	aw_track(c, "call_button_clicked", *b);
	analytics_join_voice(c, 0, channel_id);
	{ call := call_get(c, channel_id);
	if call != null { call.dismissed = true; } }
}

// analytics_call_disconnect: the voice panel's "Disconnect" (call_button_clicked;
// leave_voice_channel carries RTC statistics this client does not measure).
analytics_call_disconnect :: (c: *Client, guild_id: Snowflake, channel_id: Snowflake) {
	ch := channel_get(*c.store, channel_id);
	if ch == null { return; }
	w := aw_begin();
	json_kstr(*w, "button_name", "Disconnect");
	if guild_id != 0 { json_ksnow(*w, "guild_id", guild_id); } else { json_knull(*w, "guild_id"); }
	json_ksnow(*w, "channel_id", channel_id);
	json_kint(*w, "channel_type", cast(s64)(ch.kind));
	json_kstr(*w, "location", "rtc panel");
	aw_track(c, "call_button_clicked", *w);
}

