// Guild management calls made from the channel list and the emoji picker, and
// the guild scheduled events side table. Results come back through
// feature_take; the app passes each to guild_admin_apply first, which sends the
// client's follow-ups. The gateway's CHANNEL_* / GUILD_EMOJIS_UPDATE /
// GUILD_SCHEDULED_EVENT_* dispatches update the tables themselves.
// Request shapes are the official client's (traffic/guild_events.jsonl,
// traffic/create_channel.jsonl, traffic/FEATURES_NEW.md):
//
//   POST   /guilds/{gid}/scheduled-events (event_create_body), then
//          GET /users/@me/scheduled-events?guild_ids=, GET .../{eid}/users/counts,
//          POST /channels/{cid}/invites (ctx Guild Events), POST /guilds/{gid}/ack/1/{eid} {}
//   PUT    /guilds/{gid}/scheduled-events/{eid}/users/@me {"response":1}   (Interested)
//   DELETE /guilds/{gid}/scheduled-events/{eid}/users/@me
//   DELETE /guilds/{gid}/scheduled-events/{eid}                           (Cancel Event)
//   GET    /guilds/{id}/profile (Create Channel opened), /regions (settings opened),
//          /roles/member-counts (Delete Channel opened), /templates (after a change)
//   POST   /guilds/{id}/channels {"type","name","permission_overwrites":[],"parent_id"} -> 201
//   PATCH  /channels/{id} with the whole Overview form (channel_edit_body)
//   DELETE /channels/{id}
//   POST   /guilds/{id}/emojis {"image":"data:<mime>;base64,..","name"}
//          with X-Discord-Original-MD5 and X-Context-Properties
//          {"client_event_source":"Emoji Studio"} (traffic/upload_custom_emoji.jsonl)

// ---- scheduled events ----

Event_Status :: enum u8 {
	Unknown :: 0;
	Scheduled :: 1;
	Active :: 2;
	Completed :: 3;
	Canceled :: 4;
}

Event_Entity :: enum u8 {
	Unknown :: 0;
	Stage_Instance :: 1;
	Voice :: 2;
	External :: 3;
}

Scheduled_Event :: struct {
	id: Snowflake;
	guild_id: Snowflake;
	channel_id: Snowflake;
	creator_id: Snowflake;
	name: string;
	description: string;
	location: string; // entity_metadata.location (external events)
	start_ms: s64; // unix ms
	end_ms: s64; // 0 = none
	status: Event_Status;
	entity: Event_Entity;
	user_count: int; // -1 until a with_user_count fetch
	interested: bool; // we RSVP'd (from our own toggles and USER_ADD/REMOVE)
	interest_pending: bool; // a PUT/DELETE is in flight
}
#scope_file

Events_Table :: struct {
	allocator: Allocator;
	list: Map(Snowflake, Scheduled_Event);
	counts_asked: Map(Snowflake, bool); // event -> its interested count was requested
	acks: [..]Event_Ack; // new events to ack (guild_admin_tick)
	epoch: int; // bumped on every change (the UI redraws on it)
}

Event_Ack :: struct {
	client: *Client; // the client whose create this was (its poll sends the ack)
	at: s64;
	guild_id: Snowflake;
	event_id: Snowflake;
}

evt: Events_Table;

events_init :: () {
	if !is_null(evt.list) { return; }
	allocator := context.default_allocator; // shared by every live client (like the feature pool)
	evt.allocator = allocator;
	evt.list = make_map(Snowflake, Scheduled_Event, allocator);
	evt.counts_asked = make_map(Snowflake, bool, allocator);
	evt.acks = make_dynamic(Event_Ack, 0, 0, allocator);
}

event_free :: (e: *Scheduled_Event) {
	a := evt.allocator;
	free_str(e.name, a);
	free_str(e.description, a);
	free_str(e.location, a);
}

iso_to_ms :: (s: string) -> s64 {
	if s == "" { return 0; }
	t, _, consumed := time.iso8601_to_time_and_offset(s);
	if consumed == 0 { return 0; }
	return time.time_to_unix_nano(t) / 1000000;
}

event_upsert :: (m: etf.Map) {
	id := fsnow(m, "id");
	if id == 0 { return; }
	a := evt.allocator;
	e, had := map_find_ptr(*evt.list, id);
	if !had {
		at(*evt.list, id).* = Scheduled_Event.{id = id, user_count = -1};
		e = at(*evt.list, id);
	} else {
		event_free(e);
	}
	e.guild_id = fsnow(m, "guild_id");
	e.channel_id = fsnow(m, "channel_id");
	e.creator_id = fsnow(m, "creator_id");
	e.name = clone_str(fstr(m, "name"), a);
	e.description = clone_str(fstr(m, "description"), a);
	e.location = clone_str(fstr(fmap(m, "entity_metadata"), "location"), a);
	e.start_ms = iso_to_ms(fstr(m, "scheduled_start_time"));
	e.end_ms = iso_to_ms(fstr(m, "scheduled_end_time"));
	e.status = cast(Event_Status)(clamp(fint(m, "status"), 0, 4));
	e.entity = cast(Event_Entity)(clamp(fint(m, "entity_type"), 0, 3));
	if vhas(m, "user_count") { e.user_count = cast(int)(fint(m, "user_count")); }
	evt.epoch += 1;
}

event_remove :: (id: Snowflake) {
	{ e, ok := map_find_ptr(*evt.list, id);
	if ok {
		event_free(e);
		delete_key(*evt.list, id);
		evt.epoch += 1;
	} }
}
#scope_export

// events_dispatch: gateway side (called from extras_dispatch).
events_dispatch :: (allocator: Allocator, me: Snowflake, name: string, d: etf.Map) {
	if name == {
	case "READY";
		events_init();
		for gv: flist(d, "guilds") { for ev: flist(vmap(gv), "guild_scheduled_events") { event_upsert(vmap(ev)); } }
	case "GUILD_CREATE";
		events_init();
		for ev: flist(d, "guild_scheduled_events") { event_upsert(vmap(ev)); }
	case "GUILD_SCHEDULED_EVENT_CREATE"; #through; case "GUILD_SCHEDULED_EVENT_UPDATE";
		events_init();
		event_upsert(d);
	case "GUILD_SCHEDULED_EVENT_DELETE";
		if !is_null(evt.list) { event_remove(fsnow(d, "id")); }
	case "GUILD_SCHEDULED_EVENT_USER_ADD"; #through; case "GUILD_SCHEDULED_EVENT_USER_REMOVE";
		if is_null(evt.list) { return; }
		e, ok := map_find_ptr(*evt.list, fsnow(d, "guild_scheduled_event_id"));
		if !ok { return; }
		add := name == "GUILD_SCHEDULED_EVENT_USER_ADD";
		if fsnow(d, "user_id") == me {
			if e.interested == add { return; } // our own toggle, already counted
			e.interested = add;
		}
		if e.user_count >= 0 { e.user_count = max(0, e.user_count + (ifx add then 1 else -1)); }
		evt.epoch += 1;
	case "GUILD_DELETE";
		if is_null(evt.list) { return; }
		gid := fsnow(d, "id");
		ids := make_dynamic(Snowflake, 0, 0, temp);
		for id, e: evt.list { if e.guild_id == gid { append(*ids, id); } }
		for id: ids { event_remove(id); }
	}
}

events_destroy :: () {
	if is_null(evt.list) { return; }
	for * _, e: evt.list { event_free(e); }
	delete(evt.list);
	delete(evt.counts_asked);
	delete(evt.acks);
	evt = zero(type_of(evt));
}

events_epoch :: () -> int {return evt.epoch;}

event_get :: (id: Snowflake) -> *Scheduled_Event {
	{ e, ok := map_find_ptr(*evt.list, id);
	if ok { return e; } }
	return null;
}

// guild_events: the guild's scheduled and live events, live first, then by start time.
guild_events :: (guild_id: Snowflake, allocator := temp) -> []*Scheduled_Event {
	out := make_dynamic(*Scheduled_Event, 0, 0, allocator);
	for * _, e: evt.list {
		if e.guild_id != guild_id || (e.status != .Scheduled && e.status != .Active) { continue; }
		append(*out, e);
	}
	key :: (e: *Scheduled_Event) -> s64 {return (ifx e.status == .Active then 0 else 1 << 62) + e.start_ms;}
	for i: 1..len(out)-1 {
		{ j := i;
		while j > 0 && (key(get(out, j)) < key(get(out, j - 1)) || (key(get(out, j)) == key(get(out, j - 1)) && get(out, j).id < get(out, j - 1).id)) {
			swap(*out[j], *out[j - 1]);
			j -= 1;
} }
	}
	return view(out);
}

// ---- science context (the client's guild / channel decorations) ----

// guild_track_props: the guild + channel properties the client adds to modal and
// settings events (open_modal, impression_modal_root_legacy, settings_pane_viewed...),
// as an object body; "" for an unknown guild.
guild_track_props :: (c: *Client, guild_id: Snowflake, channel_id: Snowflake) -> string {
	if guild_get(*c.store, guild_id) == null { return ""; }
	w := aw_begin();
	aw_route_props(*w, c, guild_id, channel_id);
	json_obj_end(*w);
	return json_body(json_string(*w));
}
#scope_file

route_channel :: (c: *Client) -> Snowflake {
	locks.lock(*c.route_mu);
	defer locks.unlock(*c.route_mu);
	return c.route_channel;
}

// impression_modal_root_legacy for a modal opened in a guild.
track_modal_impression :: (c: *Client, guild_id: Snowflake, variant: string) {
	ctx := guild_track_props(c, guild_id, route_channel(c));
	props := fmt.tprintf("\"impression_type\":\"page\",%s,\"variant\":\"%s\",\"location\":\"impression_modal_root_legacy\",\"location_page\":\"impression_modal_root_legacy\"", ctx, variant);
	analytics_track(c, "impression_modal_root_legacy", props);
}
#scope_export

// ---- scheduled events: REST (traffic/guild_events.jsonl) ----
//
// Opening the Events modal sends no REST: the list comes from READY /
// GUILD_CREATE / GUILD_SCHEDULED_EVENT_*.

// open_guild_events: the Events modal opened. Science only, plus the interested
// counts of listed events whose count is still unknown (once each).
open_guild_events :: (c: *Client, guild_id: Snowflake) {
	evs := guild_events(guild_id);
	track_modal_impression(c, guild_id, "GuildEventsModal");
	analytics_track(c, "open_modal", fmt.tprintf("\"type\":\"Guild Events Modal\",\"guild_id\":\"%d\",\"guild_events_count\":%d", cast(u64)(guild_id), len(evs)));
	for e: evs {
		if e.user_count >= 0 || get(evt.counts_asked, e.id) { continue; }
		at(*evt.counts_asked, e.id).* = true;
		fetch_event_counts(c, e.guild_id, e.id);
	}
}

// open_create_event: the Create Event wizard opened (science only).
open_create_event :: (c: *Client, guild_id: Snowflake) {
	track_modal_impression(c, guild_id, "ScheduleEventModal");
}

// GET /guilds/{gid}/scheduled-events/{eid}/users/counts -> {"guild_scheduled_event_count":n,..}
fetch_event_counts :: (c: *Client, guild_id: Snowflake, event_id: Snowflake) {
	path := fmt.tprintf("/guilds/%d/scheduled-events/%d/users/counts", cast(u64)(guild_id), cast(u64)(event_id));
	feature_submit(c, .Event_Counts, "GET", path, channel_id = guild_id, tag = cast(u64)(event_id));
}

// event_preview_counts: the wizard's Review step renders a preview card with
// event id -1 and asks for its counts; Discord answers 400 (as for the client).
event_preview_counts :: (c: *Client, guild_id: Snowflake) {
	path := fmt.tprintf("/guilds/%d/scheduled-events/-1/users/counts", cast(u64)(guild_id));
	feature_submit(c, .Guild_Aux, "GET", path, channel_id = guild_id);
}

// The wizard's result. entity .Voice (channel_id) or .External (location, end_ms).
Event_Draft :: struct {
	name: string;
	description: string;
	start_ms: s64;
	end_ms: s64; // external events only
	entity: Event_Entity;
	channel_id: Snowflake;
	location: string;
}

// default_event_start_ms: the wizard's default start, the next full local hour.
// The client sets minutes and seconds to 0 and keeps the milliseconds
// ("2026-10-26T23:00:00.650Z" in the fixture).
default_event_start_ms :: (now_ms: s64, utc_offset_ms: s64) -> s64 {
	local := now_ms + utc_offset_ms;
	return local - local % 3_600_000 + local % 1000 + 3_600_000 - utc_offset_ms;
}

// {"name","description","privacy_level":2,"scheduled_start_time",["scheduled_end_time",]
//  "entity_type", "channel_id" | "entity_metadata":{"location"}, "recurrence_rule":null}
event_create_body :: (d: Event_Draft) -> string {
	w: Json;
	json_init(*w);
	json_obj(*w);
	json_kstr(*w, "name", d.name);
	json_kstr(*w, "description", d.description);
	json_kint(*w, "privacy_level", 2); // GUILD_ONLY
	json_kstr(*w, "scheduled_start_time", ms_to_iso(d.start_ms));
	if d.entity == .External { json_kstr(*w, "scheduled_end_time", ms_to_iso(d.end_ms)); }
	json_kint(*w, "entity_type", cast(s64)(d.entity));
	if d.entity == .External {
		json_key(*w, "entity_metadata");
		json_obj(*w);
		json_kstr(*w, "location", d.location);
		json_obj_end(*w);
	} else {
		json_ksnow(*w, "channel_id", d.channel_id);
	}
	json_knull(*w, "recurrence_rule");
	json_obj_end(*w);
	return json_string(*w);
}

// POST /guilds/{gid}/scheduled-events. guild_admin_apply sends the follow-ups.
create_scheduled_event :: (c: *Client, guild_id: Snowflake, d: Event_Draft) {
	path := fmt.tprintf("/guilds/%d/scheduled-events", cast(u64)(guild_id));
	feature_submit(c, .Event_Create, "POST", path, event_create_body(d), channel_id = guild_id);
}

// The channel an event's invite points at: its own channel, else the guild's
// system channel or first text channel.
event_invite_channel :: (c: *Client, e: *Scheduled_Event) -> Snowflake {
	if e.channel_id != 0 { return e.channel_id; }
	s := *c.store;
	{ g := guild_get(s, e.guild_id);
	if g != null && g.system_channel_id != 0 { return g.system_channel_id; } }
	for id: guild_channels_sorted(s, e.guild_id) {
		{ ch := channel_get(s, id);
		if ch != null && (ch.kind == .Guild_Text || ch.kind == .Guild_Announcement) { return id; } }
	}
	return 0;
}

// event_share: POST /channels/{cid}/invites {"max_age":604800,"max_uses":0},
// X-Context-Properties {"location":"Guild Events"}. Result: op .Event_Invite, tag = event.
event_share :: (c: *Client, event_id: Snowflake) {
	e := event_get(event_id);
	if is_null(e) { return; }
	cid := event_invite_channel(c, e);
	if cid == 0 { return; }
	feature_submit(c, .Event_Invite, "POST", channel_path(cid, "/invites"), "{\"max_age\":604800,\"max_uses\":0}", channel_id = cid, tag = cast(u64)(event_id), retries = 2, context_b64 = context_location("Guild Events"));
}

// event_link: what Copy Event Link puts on the clipboard.
event_link :: (e: *Scheduled_Event, allocator := temp) -> string {
	return fmt.aprintf("https://discord.com/events/%d/%d", cast(u64)(e.guild_id), cast(u64)(e.id), allocator = allocator);
}

// event_invite_link: the share dialog's link (the invite carries the event).
event_invite_link :: (code: string, event_id: Snowflake, allocator := temp) -> string {
	return fmt.aprintf("https://discord.gg/%s?event=%d", code, cast(u64)(event_id), allocator = allocator);
}

// set_event_interest: PUT {"response":1} (interested) / DELETE
// /guilds/{gid}/scheduled-events/{eid}/users/@me. Applied optimistically;
// guild_admin_apply undoes it on failure.
set_event_interest :: (c: *Client, event_id: Snowflake, interested: bool) {
	e := event_get(event_id);
	if is_null(e) || e.interest_pending || e.interested == interested { return; }
	e.interested = interested;
	e.interest_pending = true;
	if e.user_count >= 0 { e.user_count = max(0, e.user_count + (ifx interested then 1 else -1)); }
	evt.epoch += 1;
	path := fmt.tprintf("/guilds/%d/scheduled-events/%d/users/@me", cast(u64)(e.guild_id), cast(u64)(event_id));
	feature_submit(c, .Event_Interest, ifx interested then "PUT" else "DELETE", path, ifx interested then "{\"response\":1}" else "", channel_id = e.guild_id, tag = cast(u64)(event_id));
}

// cancel_scheduled_event: DELETE /guilds/{gid}/scheduled-events/{eid} ("Cancel Event").
cancel_scheduled_event :: (c: *Client, event_id: Snowflake) {
	e := event_get(event_id);
	if is_null(e) { return; }
	path := fmt.tprintf("/guilds/%d/scheduled-events/%d", cast(u64)(e.guild_id), cast(u64)(event_id));
	feature_submit(c, .Event_Delete, "DELETE", path, channel_id = e.guild_id, tag = cast(u64)(event_id));
}

// start_scheduled_event: PATCH /guilds/{gid}/scheduled-events/{eid} {"status":2}
// ("Start Event" on a voice event; not in the captures).
start_scheduled_event :: (c: *Client, event_id: Snowflake) {
	e := event_get(event_id);
	if is_null(e) { return; }
	path := fmt.tprintf("/guilds/%d/scheduled-events/%d", cast(u64)(e.guild_id), cast(u64)(event_id));
	feature_submit(c, .Event_Start, "PATCH", path, "{\"status\":2}", channel_id = e.guild_id, tag = cast(u64)(event_id));
}

// can_create_events / can_manage_event: the client's gates for Create Event and
// for Start / Cancel on a card (MANAGE_EVENTS, or CREATE_EVENTS for your own).
can_create_events :: (s: *Store, guild_id: Snowflake) -> bool {
	return (guild_permissions(s, guild_id) & (PERM_MANAGE_EVENTS | PERM_CREATE_EVENTS)) != 0;
}

can_manage_event :: (s: *Store, e: *Scheduled_Event) -> bool {
	p := guild_permissions(s, e.guild_id);
	if (p & PERM_MANAGE_EVENTS) != 0 { return true; }
	return (p & PERM_CREATE_EVENTS) != 0 && e.creator_id == s.me;
}

// ack delay after an event is created: the client acks the new event (guild
// feature ack type 1) about 3 s after its follow-ups (+1220 -> +4220 ms).
EVENT_ACK_DELAY_MS :: 3000;
#scope_file

event_created :: (c: *Client, r: *Feature_Result) {
	m := vmap(r.body);
	events_init();
	event_upsert(m);
	id := fsnow(m, "id");
	e := event_get(id);
	if is_null(e) { return; }
	gid := e.guild_id;
	// the creator is marked interested by Discord (GUILD_SCHEDULED_EVENT_USER_ADD follows)
	e.interested = true;
	at(*evt.counts_asked, id).* = true;
	feature_submit(c, .Event_Rsvps, "GET", fmt.tprintf("/users/@me/scheduled-events?guild_ids=%d", cast(u64)(gid)), channel_id = gid);
	fetch_event_counts(c, gid, id);
	event_share(c, id);
	append(*evt.acks, Event_Ack.{client = c, at = now_ms() + EVENT_ACK_DELAY_MS, guild_id = gid, event_id = id});
}
#scope_export
// ---- channels ----

// channel_name_normalize: what the client does to a typed channel name. Text-like
// channels: lowercase, spaces and runs of dashes become one dash, other
// punctuation dropped; voice: trimmed only. 100 characters at most.
channel_name_normalize :: (name: string, text: bool, allocator := temp) -> string {
	if !text { return clone(truncate_runes(strings.trim_space(name), 100), allocator); }
	sb := strings.builder_make(allocator);
	dash := false;
	n := 0;
	for r: name {
		if n >= 100 { break; }
		c := r;
		if c >= #char "A" && c <= #char "Z" { c += #char "a" - #char "A"; }
		if c == #char " " || c == #char "-" || c == 9 {
			dash = true;
			continue;
		}
		keep := (c >= #char "a" && c <= #char "z") || (c >= #char "0" && c <= #char "9") || c == #char "_" || c > 0x7f;
		if !keep { continue; }
		if dash && n > 0 {
			strings.write_byte(*sb, #char "-");
			n += 1;
		}
		dash = false;
		strings.write_rune(*sb, c);
		n += 1;
	}
	// a trailing dash is kept while typing ("new-") like the client's input
	if dash && n > 0 && n < 100 { strings.write_byte(*sb, #char "-"); }
	return strings.to_string(sb);
}
#scope_file

truncate_runes :: (s: string, n: int) -> string {
	i := 0;
	for _, off: s {
		if i == n { return sub(s, 0, off); }
		i += 1;
	}
	return s;
}
#scope_export

// ---- channels: REST (traffic/create_channel.jsonl) ----

// open_create_channel: the Create Channel modal opened: GET /guilds/{id}/profile, science open_modal.
open_create_channel :: (c: *Client, guild_id: Snowflake) {
	feature_submit(c, .Guild_Aux, "GET", fmt.tprintf("/guilds/%d/profile", cast(u64)(guild_id)), channel_id = guild_id);
	analytics_track(c, "open_modal", fmt.tprintf("\"type\":\"Create Channel\",%s", guild_track_props(c, guild_id, route_channel(c))));
}

// open_channel_settings: channel settings (Overview) opened: GET /guilds/{id}/regions,
// science settings_pane_viewed.
open_channel_settings :: (c: *Client, ch: *Channel) {
	if ch == null || ch.guild_id == 0 { return; }
	feature_submit(c, .Guild_Aux, "GET", fmt.tprintf("/guilds/%d/regions", cast(u64)(ch.guild_id)), channel_id = ch.guild_id);
	props := fmt.tprintf("\"settings_type\":\"channel\",\"origin_pane\":null,\"destination_pane\":\"OVERVIEW\",\"location\":null,%s", guild_track_props(c, ch.guild_id, ch.id));
	analytics_track(c, "settings_pane_viewed", props);
}

// open_delete_channel: the Delete Channel confirm opened: GET /guilds/{id}/roles/member-counts.
open_delete_channel :: (c: *Client, guild_id: Snowflake) {
	feature_submit(c, .Guild_Aux, "GET", fmt.tprintf("/guilds/%d/roles/member-counts", cast(u64)(guild_id)), channel_id = guild_id);
}

// POST /guilds/{id}/channels {"type","name","permission_overwrites":[],"parent_id"} -> 201.
// tag: the channel type (guild_admin_apply reports it to science).
create_channel :: (c: *Client, guild_id: Snowflake, kind: Channel_Type, name: string, parent_id: Snowflake) {
	w: Json;
	json_init(*w);
	json_obj(*w);
	json_kint(*w, "type", cast(s64)(kind));
	json_kstr(*w, "name", name);
	json_key(*w, "permission_overwrites");
	json_arr(*w);
	json_arr_end(*w);
	if parent_id != 0 {
		json_ksnow(*w, "parent_id", parent_id);
	} else {
		json_knull(*w, "parent_id");
	}
	json_obj_end(*w);
	path := strings.concatenate(string.["/guilds/", snowflake_string(guild_id), "/channels"], temp);
	feature_submit(c, .Channel_Create, "POST", path, json_string(*w), channel_id = guild_id, tag = cast(u64)(kind));
}

// The channel settings Overview form. Save sends all of it, changed or not.
Channel_Form :: struct {
	name: string;
	kind: Channel_Type;
	topic: string;
	bitrate: int;
	user_limit: int;
	nsfw: bool;
	flags: u64;
	rate_limit_per_user: int;
}

channel_form_of :: (ch: *Channel) -> Channel_Form {
	return .{name = ch.name, kind = ch.kind, topic = ch.topic, bitrate = ifx ch.bitrate > 0 then ch.bitrate else 64000, user_limit = ch.user_limit, nsfw = ch.nsfw, flags = ch.flags, rate_limit_per_user = ch.rate_limit_per_user};
}

// {"name","type","topic","bitrate","user_limit","nsfw","flags","rate_limit_per_user"}
channel_edit_body :: (f: Channel_Form) -> string {
	w: Json;
	json_init(*w);
	json_obj(*w);
	json_kstr(*w, "name", f.name);
	json_kint(*w, "type", cast(s64)(f.kind));
	json_kstr(*w, "topic", f.topic);
	json_kint(*w, "bitrate", cast(s64)(f.bitrate));
	json_kint(*w, "user_limit", cast(s64)(f.user_limit));
	json_kbool(*w, "nsfw", f.nsfw);
	json_kint(*w, "flags", cast(s64)(f.flags));
	json_kint(*w, "rate_limit_per_user", cast(s64)(f.rate_limit_per_user));
	json_obj_end(*w);
	return json_string(*w);
}

// PATCH /channels/{id} with the whole Overview form.
edit_channel :: (c: *Client, channel_id: Snowflake, f: Channel_Form) {
	feature_submit(c, .Channel_Edit, "PATCH", channel_path(channel_id), channel_edit_body(f), channel_id = channel_id);
}

// DELETE /channels/{id}
delete_channel :: (c: *Client, channel_id: Snowflake) {
	feature_submit(c, .Channel_Delete, "DELETE", channel_path(channel_id), channel_id = channel_id);
}
#scope_file

// After a channel is created, saved or deleted the client refreshes the guild's
// templates (their "unsynced" state): GET /guilds/{id}/templates (MANAGE_GUILD only).
refresh_templates :: (c: *Client, guild_id: Snowflake) {
	if guild_id == 0 || (guild_permissions(*c.store, guild_id) & PERM_MANAGE_GUILD) == 0 { return; }
	feature_submit(c, .Guild_Aux, "GET", fmt.tprintf("/guilds/%d/templates", cast(u64)(guild_id)), channel_id = guild_id);
}
#scope_export

// ---- results and timers ----

// guild_admin_apply: the library side of a finished events / channel request
// (UI thread; the app calls it from its feature_take loop before its own handling).
guild_admin_apply :: (c: *Client, r: *Feature_Result) {
	if r.op == {
	case .Event_Create;
		if r.ok { event_created(c, r); }
	case .Event_Counts;
		if !r.ok { return; }
		{ e := event_get(cast(Snowflake)(r.tag));
		if !is_null(e) {
			e.user_count = cast(int)(fint(vmap(r.body), "guild_scheduled_event_count"));
			evt.epoch += 1;
		} }
	case .Event_Rsvps;
		// [{"guild_scheduled_event_id","user_id","response"}] for the guild
		if !r.ok || is_null(evt.list) { return; }
		mine := make_map(Snowflake, bool, temp);
		for v: vlist(r.body) { at(*mine, fsnow(vmap(v), "guild_scheduled_event_id")).* = true; }
		for * id, e: evt.list {
			if e.guild_id != r.channel_id || e.interest_pending { continue; }
			e.interested = get(mine, id);
		}
		evt.epoch += 1;
	case .Event_Interest;
		e := event_get(cast(Snowflake)(r.tag));
		if is_null(e) { return; }
		e.interest_pending = false;
		if !r.ok {
			e.interested = !e.interested;
			if e.user_count >= 0 { e.user_count = max(0, e.user_count + (ifx e.interested then 1 else -1)); }
		}
		evt.epoch += 1;
	case .Event_Delete;
		if r.ok && !is_null(evt.list) { event_remove(cast(Snowflake)(r.tag)); }
	case .Event_Start;
		if r.ok && vhas(vmap(r.body), "id") { event_upsert(vmap(r.body)); }
	case .Channel_Create;
		if !r.ok { return; }
		m := vmap(r.body);
		props := fmt.tprintf("\"status_code\":%d,\"url\":\"/guilds/%d/channels\",\"request_method\":\"post\",\"is_private\":false,\"channel_id\":\"%d\",\"channel_type\":%d", r.status, cast(u64)(r.channel_id), cast(u64)(fsnow(m, "id")), r.tag);
		analytics_track(c, "network_action_channel_create", props);
		refresh_templates(c, r.channel_id);
	case .Channel_Edit; #through; case .Channel_Delete;
		if !r.ok { return; }
		gid := fsnow(vmap(r.body), "guild_id");
		if gid == 0 { { ch := channel_get(*c.store, r.channel_id);
if ch != null { gid = ch.guild_id; } } }
		refresh_templates(c, gid);
	}
}

// guild_admin_tick: due new-event acks, POST /guilds/{gid}/ack/1/{eid} {} (from client_poll).
guild_admin_tick :: (c: *Client, now: s64) {
	if len(evt.acks) == 0 { return; }
	{ i := 0;
	while i < len(evt.acks) {
		a := evt.acks[i];
		if a.client != c || now < a.at {
			i += 1;
			continue;
		}
		ordered_remove(*evt.acks, i);
		if event_get(a.event_id) == null { continue; } // cancelled meanwhile
		feature_submit(c, .Guild_Aux, "POST", fmt.tprintf("/guilds/%d/ack/1/%d", cast(u64)(a.guild_id), cast(u64)(a.event_id)), "{}", channel_id = a.guild_id);
	} }
}
// ---- custom emoji ----

EMOJI_MAX_BYTES :: 256 * 1024;

// emoji_name_from_filename: the file's base name without extension; characters
// other than A-Z a-z 0-9 _ become "_"; 2..32 characters ("emoji" when shorter).
emoji_name_from_filename :: (path: string, allocator := temp) -> string {
	base := path;
	{ i := strings.last_index_any(base, "/\\");
	if i >= 0 { base = sub_from(base, i + 1); } }
	{ i := strings.last_index_byte(base, #char ".");
	if i > 0 { base = sub(base, 0, i); } }
	sb := strings.builder_make(allocator);
	n := 0;
	for r: base {
		if n >= 32 { break; }
		ok := (r >= #char "a" && r <= #char "z") || (r >= #char "A" && r <= #char "Z") || (r >= #char "0" && r <= #char "9") || r == #char "_";
		strings.write_byte(*sb, ifx ok then cast(u8)(r) else #char "_");
		n += 1;
	}
	if n < 2 {
		strings.builder_destroy(*sb);
		return clone("emoji", allocator);
	}
	return strings.to_string(sb);
}
#scope_file

image_mime :: (path: string) -> string {
	lower := strings.to_lower(path, temp);
	if strings.has_suffix(lower, ".png") {
		return "image/png";
	} else if (strings.has_suffix(lower, ".jpg")) || (strings.has_suffix(lower, ".jpeg")) {
		return "image/jpeg";
	} else if strings.has_suffix(lower, ".gif") {
		return "image/gif";
	} else if strings.has_suffix(lower, ".webp") {
		return "image/webp";
	} else if strings.has_suffix(lower, ".avif") {
		return "image/avif";
	}
	return "";
}
#scope_export

// file_job_body (feature worker thread): reads the image at path and builds
// {"image":"data:<mime>;base64,..","name":<name>} plus X-Discord-Original-MD5.
// status: 0 ok, -1 unreadable / not an image, -2 over EMOJI_MAX_BYTES.
file_job_body :: (path: string, name: string) -> string, []http.Header, int {
	body: string;
	extra: []http.Header;
	status: int;
	mime := image_mime(path);
	if mime == "" { return "", .{}, -1; }
	data, err := os.read_entire_file(path, temp);
	if err != null || len(data) == 0 { return "", .{}, -1; }
	if len(data) > EMOJI_MAX_BYTES { return "", .{}, -2; }
	ctx: md5.Context;
	md5.init(*ctx);
	md5.update(*ctx, data);
	digest: [md5.DIGEST_SIZE]u8;
	md5.final(*ctx, view(digest));
	HEX := "0123456789abcdef";
	hex := make_slice(u8, 32, temp);
	for b, i: digest {
		hex[i * 2] = HEX[b >> 4];
		hex[i * 2 + 1] = HEX[b & 15];
	}
	w: Json;
	json_init(*w);
	json_obj(*w);
	json_kstr(*w, "image", strings.concatenate(string.["data:", mime, ";base64,", base64.encode(data, allocator = temp)], temp));
	json_kstr(*w, "name", name);
	json_obj_end(*w);
	ex := make_slice(http.Header, 1, temp);
	ex[0] = .{"x-discord-original-md5", as_string(hex)};
	return json_string(*w), ex, 0;
}

// upload_guild_emoji: POST /guilds/{id}/emojis from an image file (read off the UI thread).
upload_guild_emoji :: (c: *Client, guild_id: Snowflake, path: string, name: string) {
	path_api := strings.concatenate(string.["/guilds/", snowflake_string(guild_id), "/emojis"], temp);
	ctx := context_b64("{\"client_event_source\":\"Emoji Studio\"}");
	feature_submit(c, .Emoji_Upload, "POST", path_api, name, channel_id = guild_id, retries = 0, context_b64 = ctx, file = path);
}

// api_error_message: the "message" of a Discord error body (first field error when present).
api_error_message :: (body: V) -> string {
	m := vmap(body);
	if is_null(m) { return ""; }
	// {"code":50035,"errors":{"name":{"_errors":[{"code":..,"message":..}]}},"message":"Invalid Form Body"}
	{ errs := fmap(m, "errors");
	if !is_null(errs) {
		for kv: errs {
			fm := vmap(kv.value);
			for ev: flist(fm, "_errors") {
				{ msg := fstr(vmap(ev), "message");
				if msg != "" { return msg; } }
			}
		}
	} }
	return fstr(m, "message");
}

