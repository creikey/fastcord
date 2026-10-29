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

// The events side table is process-wide, like the feature side tables: every live client
// (the parallel offline tests run several) shares it, on the heap, under evt_mu. The app's
// readers (event_get, guild_events) run on its one UI thread.
Events_Table :: struct {
	ready: bool;
	list: Table(Snowflake, Scheduled_Event);
	counts_asked: Table(Snowflake, bool); // event -> its interested count was requested
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
evt_mu: locks.Mutex;

events_init :: () {
	if evt.ready return;
	evt.ready = true;
	evt.list.allocator = context.default_allocator;
	evt.counts_asked.allocator = context.default_allocator;
	evt.acks.allocator = context.default_allocator;
}

event_free :: (e: *Scheduled_Event, a := context.default_allocator) {
	free_str(e.name, a);
	free_str(e.description, a);
	free_str(e.location, a);
}

event_upsert :: (m: etf.Map) {
	id := fsnow(m, "id");
	if !id return;
	e := table_find_pointer(*evt.list, id);
	if e event_free(e);
	else e = table_set(*evt.list, id, .{id = id, user_count = -1});
	event_fill(e, m, context.default_allocator);
	evt.epoch += 1;
}

// event_fill: a guild_scheduled_event object's fields (also an invite's event).
event_fill :: (e: *Scheduled_Event, m: etf.Map, a: Allocator) {
	e.id = fsnow(m, "id");
	e.guild_id = fsnow(m, "guild_id");
	e.channel_id = fsnow(m, "channel_id");
	e.creator_id = fsnow(m, "creator_id");
	e.name = clone_str(fstr(m, "name"), a);
	e.description = clone_str(fstr(m, "description"), a);
	e.location = clone_str(fstr(fmap(m, "entity_metadata"), "location"), a);
	e.start_ms = iso_to_ms(fstr(m, "scheduled_start_time"));
	e.end_ms = iso_to_ms(fstr(m, "scheduled_end_time"));
	e.status = cast(Event_Status) clamp(fint(m, "status"), 0, 4);
	e.entity = cast(Event_Entity) clamp(fint(m, "entity_type"), 0, 3);
	if vhas(m, "user_count") e.user_count = fint(m, "user_count");
}

event_remove :: (id: Snowflake) {
	e := table_find_pointer(*evt.list, id);
	if !e return;
	event_free(e);
	table_remove(*evt.list, id);
	evt.epoch += 1;
}

// events_dispatch: gateway side (called from extras_dispatch).
events_dispatch :: (allocator: Allocator, me: Snowflake, name: string, d: etf.Map) {
	locks.guard(*evt_mu);
	if name == {
		case "READY";
			events_init();
			for gv: flist(d, "guilds") for ev: flist(vmap(gv), "guild_scheduled_events") event_upsert(vmap(ev));
		case "GUILD_CREATE";
			events_init();
			for ev: flist(d, "guild_scheduled_events") event_upsert(vmap(ev));
		case "GUILD_SCHEDULED_EVENT_CREATE"; #through;
		case "GUILD_SCHEDULED_EVENT_UPDATE";
			events_init();
			event_upsert(d);
		case "GUILD_SCHEDULED_EVENT_DELETE";
			event_remove(fsnow(d, "id"));
		case "GUILD_SCHEDULED_EVENT_USER_ADD"; #through;
		case "GUILD_SCHEDULED_EVENT_USER_REMOVE";
			e := table_find_pointer(*evt.list, fsnow(d, "guild_scheduled_event_id"));
			if !e return;
			add := name == "GUILD_SCHEDULED_EVENT_USER_ADD";
			if fsnow(d, "user_id") == me {
				if e.interested == add return; // our own toggle, already counted
				e.interested = add;
			}
			if e.user_count >= 0 e.user_count = max(0, e.user_count + ifx add then 1 else -1);
			evt.epoch += 1;
		case "GUILD_DELETE";
			gid := fsnow(d, "id");
			ids: [..]Snowflake;
			ids.allocator = temp;
			for e, id: evt.list if e.guild_id == gid array_add(*ids, id);
			for ids event_remove(it);
	}
}

events_destroy :: () {
	locks.guard(*evt_mu);
	if !evt.ready return;
	for * evt.list event_free(it);
	deinit(*evt.list);
	deinit(*evt.counts_asked);
	array_free(evt.acks);
	evt = .{};
}

events_epoch :: () -> int { return evt.epoch; }

event_get :: (id: Snowflake) -> *Scheduled_Event { return table_find_pointer(*evt.list, id); }

// guild_events: the guild's scheduled and live events, live first, then by start time.
guild_events :: (guild_id: Snowflake, allocator := temp) -> []*Scheduled_Event {
	out: [..]*Scheduled_Event;
	out.allocator = allocator;
	for * evt.list if it.guild_id == guild_id && (it.status == .Scheduled || it.status == .Active) array_add(*out, it);
	quick_sort(out, (a: *Scheduled_Event, b: *Scheduled_Event) -> s64 {
		key :: (e: *Scheduled_Event) -> s64 { return (ifx e.status == .Active then 0 else 1 << 62) + e.start_ms; }
		ka, kb := key(a), key(b);
		if ka != kb return ifx ka < kb then -1 else 1;
		return ifx a.id < b.id then -1 else xx (a.id > b.id);
	});
	return out;
}

// ---- science context (the client's guild / channel decorations) ----

// guild_track_props: the guild + channel properties the client adds to modal and
// settings events (open_modal, impression_modal_root_legacy, settings_pane_viewed...),
// as an object body; "" for an unknown guild.
guild_track_props :: (c: *Client, guild_id: Snowflake, channel_id: Snowflake) -> string {
	if !guild_get(*c.store, guild_id) return "";
	w := aw_begin();
	aw_route_props(*w, c, guild_id, channel_id);
	json_obj_end(*w);
	return json_body(json_string(*w));
}

route_channel_of :: (c: *Client) -> Snowflake {
	locks.guard(*c.route_mu);
	return c.route_channel;
}

// impression_modal_root_legacy for a modal opened in a guild.
track_modal_impression :: (c: *Client, guild_id: Snowflake, variant: string) {
	analytics_track(c, "impression_modal_root_legacy", tprint("\"impression_type\":\"page\",%,\"variant\":\"%\",\"location\":\"impression_modal_root_legacy\",\"location_page\":\"impression_modal_root_legacy\"", guild_track_props(c, guild_id, route_channel_of(c)), variant));
}

// ---- scheduled events: REST (traffic/guild_events.jsonl) ----
//
// Opening the Events modal sends no REST: the list comes from READY /
// GUILD_CREATE / GUILD_SCHEDULED_EVENT_*.

// open_guild_events: the Events modal opened. Science only, plus the interested
// counts of listed events whose count is still unknown (once each).
open_guild_events :: (c: *Client, guild_id: Snowflake) {
	locks.guard(*evt_mu);
	evs := guild_events(guild_id);
	track_modal_impression(c, guild_id, "GuildEventsModal");
	analytics_track(c, "open_modal", tprint("\"type\":\"Guild Events Modal\",\"guild_id\":\"%\",\"guild_events_count\":%", guild_id, evs.count));
	for evs {
		if it.user_count >= 0 || table_contains(*evt.counts_asked, it.id) continue;
		table_set(*evt.counts_asked, it.id, true);
		fetch_event_counts(c, it.guild_id, it.id);
	}
}

// open_create_event: the Create Event wizard opened (science only).
open_create_event :: (c: *Client, guild_id: Snowflake) {
	track_modal_impression(c, guild_id, "ScheduleEventModal");
}

// event_ask_counts: an event's interested count, requested once (the event invite card).
event_ask_counts :: (c: *Client, event_id: Snowflake) {
	locks.guard(*evt_mu);
	e := event_get(event_id);
	if !e || e.user_count >= 0 || table_contains(*evt.counts_asked, event_id) return;
	table_set(*evt.counts_asked, event_id, true);
	fetch_event_counts(c, e.guild_id, event_id);
}

// GET /guilds/{gid}/scheduled-events/{eid}/users/counts -> {"guild_scheduled_event_count":n,..}
fetch_event_counts :: (c: *Client, guild_id: Snowflake, event_id: Snowflake) {
	feature_submit(c, .Event_Counts, "GET", tprint("/guilds/%/scheduled-events/%/users/counts", guild_id, event_id), channel_id = guild_id, tag = event_id);
}

// event_preview_counts: the wizard's Review step renders a preview card with
// event id -1 and asks for its counts; Discord answers 400 (as for the client).
event_preview_counts :: (c: *Client, guild_id: Snowflake) {
	aux_get(c, tprint("/guilds/%/scheduled-events/-1/users/counts", guild_id), guild_id);
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
	if d.entity == .External json_kstr(*w, "scheduled_end_time", ms_to_iso(d.end_ms));
	json_kint(*w, "entity_type", xx d.entity);
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
	feature_submit(c, .Event_Create, "POST", tprint("/guilds/%/scheduled-events", guild_id), event_create_body(d), channel_id = guild_id);
}

// The channel an event's invite points at: its own channel, else the guild's
// system channel or first text channel.
event_invite_channel :: (c: *Client, e: *Scheduled_Event) -> Snowflake {
	if e.channel_id return e.channel_id;
	s := *c.store;
	g := guild_get(s, e.guild_id);
	if g && g.system_channel_id return g.system_channel_id;
	for id: guild_channels_sorted(s, e.guild_id) {
		ch := channel_get(s, id);
		if ch && (ch.kind == .Guild_Text || ch.kind == .Guild_Announcement) return id;
	}
	return 0;
}

// event_share: POST /channels/{cid}/invites {"max_age":604800,"max_uses":0},
// X-Context-Properties {"location":"Guild Events"}. Result: op .Event_Invite, tag = event.
event_share :: (c: *Client, event_id: Snowflake) {
	locks.guard(*evt_mu);
	share_event(c, event_id);
}

share_event :: (c: *Client, event_id: Snowflake) {
	e := event_get(event_id);
	if !e return;
	cid := event_invite_channel(c, e);
	if !cid return;
	feature_submit(c, .Event_Invite, "POST", channel_path(cid, "/invites"), "{\"max_age\":604800,\"max_uses\":0}", channel_id = cid, tag = event_id, retries = 2, context_b64 = context_location("Guild Events"));
}

// event_link: what Copy Event Link puts on the clipboard.
event_link :: (e: *Scheduled_Event, allocator := temp) -> string {
	return sprint("https://discord.com/events/%/%", e.guild_id, e.id,, allocator);
}

// event_invite_link: the share dialog's link (the invite carries the event).
event_invite_link :: (code: string, event_id: Snowflake, allocator := temp) -> string {
	return sprint("https://discord.gg/%?event=%", code, event_id,, allocator);
}

// set_event_interest: PUT {"response":1} (interested) / DELETE
// /guilds/{gid}/scheduled-events/{eid}/users/@me. Applied optimistically;
// guild_admin_apply undoes it on failure.
set_event_interest :: (c: *Client, event_id: Snowflake, interested: bool) {
	locks.guard(*evt_mu);
	e := event_get(event_id);
	if !e || e.interest_pending || e.interested == interested return;
	e.interested = interested;
	e.interest_pending = true;
	if e.user_count >= 0 e.user_count = max(0, e.user_count + ifx interested then 1 else -1);
	evt.epoch += 1;
	feature_submit(c, .Event_Interest, ifx interested then "PUT" else "DELETE", tprint("/guilds/%/scheduled-events/%/users/@me", e.guild_id, event_id), ifx interested then "{\"response\":1}" else "", channel_id = e.guild_id, tag = event_id);
}

// cancel_scheduled_event: DELETE /guilds/{gid}/scheduled-events/{eid} ("Cancel Event").
cancel_scheduled_event :: (c: *Client, event_id: Snowflake) {
	e := event_get(event_id);
	if !e return;
	feature_submit(c, .Event_Delete, "DELETE", tprint("/guilds/%/scheduled-events/%", e.guild_id, event_id), channel_id = e.guild_id, tag = event_id);
}

// start_scheduled_event: PATCH /guilds/{gid}/scheduled-events/{eid} {"status":2}
// ("Start Event" on a voice event; not in the captures).
start_scheduled_event :: (c: *Client, event_id: Snowflake) {
	e := event_get(event_id);
	if !e return;
	feature_submit(c, .Event_Start, "PATCH", tprint("/guilds/%/scheduled-events/%", e.guild_id, event_id), "{\"status\":2}", channel_id = e.guild_id, tag = event_id);
}

// can_create_events / can_manage_event: the client's gates for Create Event and
// for Start / Cancel on a card (MANAGE_EVENTS, or CREATE_EVENTS for your own).
can_create_events :: (s: *Store, guild_id: Snowflake) -> bool {
	return (guild_permissions(s, guild_id) & (PERM_MANAGE_EVENTS | PERM_CREATE_EVENTS)) != 0;
}

can_manage_event :: (s: *Store, e: *Scheduled_Event) -> bool {
	p := guild_permissions(s, e.guild_id);
	return (p & PERM_MANAGE_EVENTS) != 0 || ((p & PERM_CREATE_EVENTS) != 0 && e.creator_id == s.me);
}

// ack delay after an event is created: the client acks the new event (guild
// feature ack type 1) about 3 s after its follow-ups (+1220 -> +4220 ms).
EVENT_ACK_DELAY_MS :: 3000;

// event_created (under evt_mu).
event_created :: (c: *Client, r: *Feature_Result) {
	m := vmap(r.body);
	events_init();
	event_upsert(m);
	id := fsnow(m, "id");
	e := event_get(id);
	if !e return;
	gid := e.guild_id;
	// the creator is marked interested by Discord (GUILD_SCHEDULED_EVENT_USER_ADD follows)
	e.interested = true;
	table_set(*evt.counts_asked, id, true);
	feature_submit(c, .Event_Rsvps, "GET", tprint("/users/@me/scheduled-events?guild_ids=%", gid), channel_id = gid);
	fetch_event_counts(c, gid, id);
	share_event(c, id);
	array_add(*evt.acks, .{client = c, at = now_ms() + EVENT_ACK_DELAY_MS, guild_id = gid, event_id = id});
}

// ---- channels ----

// channel_name_normalize: what the client does to a typed channel name. Text-like
// channels: lowercase, spaces and runs of dashes become one dash, other
// punctuation dropped; voice: trimmed only. 100 characters at most.
channel_name_normalize :: (name: string, text: bool, allocator := temp) -> string {
	if !text return copy_string(truncate_runes(trim(name), 100),, allocator);
	out: [..]u8;
	out.allocator = allocator;
	dash := false;
	n := 0;
	i := 0;
	while i < name.count && n < 100 {
		_, size := character_utf8_to_utf32(name.data + i, name.count - i);
		r := string.{size, name.data + i};
		i += size;
		c := to_lower(r[0]);
		if c == #char " " || c == #char "-" || c == #char "\t" {
			dash = true;
			continue;
		}
		if size == 1 && !is_alnum(c) continue; // ASCII letters, digits and _ stay; other punctuation goes
		if dash && n > 0 {
			array_add(*out, #char "-");
			n += 1;
		}
		dash = false;
		if size == 1 array_add(*out, c); else append_string(*out, r);
		n += 1;
	}
	// a trailing dash is kept while typing ("new-") like the client's input
	if dash && n > 0 && n < 100 array_add(*out, #char "-");
	return cast(string) out;
}

// truncate_runes: the first n characters of s.
truncate_runes :: (s: string, n: int) -> string {
	i := 0;
	for 1..n {
		if i >= s.count break;
		_, size := character_utf8_to_utf32(s.data + i, s.count - i);
		i += size;
	}
	return .{i, s.data};
}

// ---- channels: REST (traffic/create_channel.jsonl) ----

// aux_get sends a GET the official client makes only for parity; its answer is unused. A self-hosted
// server has none of these routes, so it never gets them.
aux_get :: (c: *Client, path: string, guild_id: Snowflake) {
	if !c.cfg.hosted.host feature_submit(c, .Guild_Aux, "GET", path, channel_id = guild_id);
}

// open_create_channel: the Create Channel modal opened: GET /guilds/{id}/profile, science open_modal.
open_create_channel :: (c: *Client, guild_id: Snowflake) {
	aux_get(c, tprint("/guilds/%/profile", guild_id), guild_id);
	analytics_track(c, "open_modal", tprint("\"type\":\"Create Channel\",%", guild_track_props(c, guild_id, route_channel_of(c))));
}

// open_channel_settings: channel settings (Overview) opened: GET /guilds/{id}/regions,
// science settings_pane_viewed.
open_channel_settings :: (c: *Client, ch: *Channel) {
	if !ch || !ch.guild_id return;
	aux_get(c, tprint("/guilds/%/regions", ch.guild_id), ch.guild_id);
	analytics_track(c, "settings_pane_viewed", tprint("\"settings_type\":\"channel\",\"origin_pane\":null,\"destination_pane\":\"OVERVIEW\",\"location\":null,%", guild_track_props(c, ch.guild_id, ch.id)));
}

// open_guild_settings: Server Settings opened (bundle GuildSettings componentDidMount): science
// settings_pane_viewed for the first section, GET /guilds/{id}/new-member-welcome (its home settings) and,
// with MANAGE_GUILD, the templates.
open_guild_settings :: (c: *Client, guild_id: Snowflake, pane: string) {
	guild_settings_pane(c, "", pane, guild_id);
	aux_get(c, tprint("/guilds/%/new-member-welcome", guild_id), guild_id);
	refresh_templates(c, guild_id);
}

// guild_settings_pane: another Server Settings section shown ("" origin: just opened).
guild_settings_pane :: (c: *Client, origin: string, dest: string, guild_id: Snowflake) {
	if !dest return;
	o := ifx origin then tprint("\"%\"", origin) else "null";
	analytics_track(c, "settings_pane_viewed", tprint("\"settings_type\":\"guild\",\"origin_pane\":%,\"destination_pane\":\"%\",%", o, dest, guild_track_props(c, guild_id, route_channel_of(c))));
}

guild_has_feature :: (g: *Guild, f: string) -> bool {
	for g.features if it == f return true;
	return false;
}

// open_delete_channel: the Delete Channel confirm opened: GET /guilds/{id}/roles/member-counts.
open_delete_channel :: (c: *Client, guild_id: Snowflake) {
	aux_get(c, tprint("/guilds/%/roles/member-counts", guild_id), guild_id);
}

// POST /guilds/{id}/channels {"type","name","permission_overwrites":[],"parent_id"} -> 201.
// tag: the channel type (guild_admin_apply reports it to science).
create_channel :: (c: *Client, guild_id: Snowflake, kind: Channel_Type, name: string, parent_id: Snowflake) {
	w: Json;
	json_init(*w);
	json_obj(*w);
	json_kint(*w, "type", xx kind);
	json_kstr(*w, "name", name);
	json_key(*w, "permission_overwrites");
	json_arr(*w);
	json_arr_end(*w);
	if parent_id json_ksnow(*w, "parent_id", parent_id);
	else json_knull(*w, "parent_id");
	json_obj_end(*w);
	feature_submit(c, .Channel_Create, "POST", tprint("/guilds/%/channels", guild_id), json_string(*w), channel_id = guild_id, tag = xx kind);
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
	json_kint(*w, "type", xx f.kind);
	json_kstr(*w, "topic", f.topic);
	json_kint(*w, "bitrate", f.bitrate);
	json_kint(*w, "user_limit", f.user_limit);
	json_kbool(*w, "nsfw", f.nsfw);
	json_kint(*w, "flags", xx f.flags);
	json_kint(*w, "rate_limit_per_user", f.rate_limit_per_user);
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

// PATCH /guilds/{id} {"name"}: only self-hosted servers offer it so far; GUILD_UPDATE applies it.
edit_guild_name :: (c: *Client, guild_id: Snowflake, name: string) {
	w: Json;
	json_init(*w);
	json_obj(*w);
	json_kstr(*w, "name", name);
	json_obj_end(*w);
	feature_submit(c, .Guild_Edit, "PATCH", tprint("/guilds/%", guild_id), json_string(*w), channel_id = guild_id);
}

// PATCH /users/@me {"avatar": data URI} from an image file, or null for "". Only hosted servers offer it:
// Discord's needs its own profile editor.
edit_my_avatar :: (c: *Client, path: string) {
	if path feature_submit(c, .Avatar_Edit, "PATCH", "/users/@me", file = path);
	else feature_submit(c, .Avatar_Edit, "PATCH", "/users/@me", "{\"avatar\":null}");
}

// The serve's caps (`ICON_MAX_BYTES`, `AVATAR_MAX_BYTES`), which keep the base64 body under its 1 MiB request limit.
HOSTED_ICON_MAX_BYTES :: 512 * 1024;

// PATCH /guilds/{id} {"icon": data URI} from an image file (read off the UI thread), or "" to remove it.
edit_guild_icon :: (c: *Client, guild_id: Snowflake, path: string) {
	if path feature_submit(c, .Guild_Edit, "PATCH", tprint("/guilds/%", guild_id), channel_id = guild_id, file = path);
	else feature_submit(c, .Guild_Edit, "PATCH", tprint("/guilds/%", guild_id), "{\"icon\":null}", channel_id = guild_id);
}

// After a channel is created, saved or deleted the client refreshes the guild's
// templates (their "unsynced" state): GET /guilds/{id}/templates (MANAGE_GUILD only).
refresh_templates :: (c: *Client, guild_id: Snowflake) {
	if !guild_id || (guild_permissions(*c.store, guild_id) & PERM_MANAGE_GUILD) == 0 return;
	aux_get(c, tprint("/guilds/%/templates", guild_id), guild_id);
}

// ---- results and timers ----

// guild_admin_apply: the library side of a finished events / channel request
// (UI thread; the app calls it from its feature_take loop before its own handling).
guild_admin_apply :: (c: *Client, r: *Feature_Result) {
	locks.guard(*evt_mu);
	if r.op == {
		case .Event_Create;
			if r.ok event_created(c, r);
		case .Event_Counts;
			e := event_get(r.tag);
			if !r.ok || !e return;
			e.user_count = fint(vmap(r.body), "guild_scheduled_event_count");
			evt.epoch += 1;
		case .Event_Rsvps;
			// [{"guild_scheduled_event_id","user_id","response"}] for the guild
			if !r.ok || !evt.ready return;
			mine: Table(Snowflake, bool);
			mine.allocator = temp;
			for vlist(r.body) table_set(*mine, fsnow(vmap(it), "guild_scheduled_event_id"), true);
			for * e, id: evt.list if e.guild_id == r.channel_id && !e.interest_pending e.interested = table_contains(*mine, id);
			evt.epoch += 1;
		case .Event_Interest;
			e := event_get(r.tag);
			if !e return;
			e.interest_pending = false;
			if !r.ok {
				e.interested = !e.interested;
				if e.user_count >= 0 e.user_count = max(0, e.user_count + ifx e.interested then 1 else -1);
			}
			evt.epoch += 1;
		case .Event_Delete;
			if r.ok event_remove(r.tag);
		case .Event_Start;
			if r.ok && vhas(vmap(r.body), "id") event_upsert(vmap(r.body));
		case .Channel_Create;
			if !r.ok return;
			analytics_track(c, "network_action_channel_create", tprint("\"status_code\":%,\"url\":\"/guilds/%/channels\",\"request_method\":\"post\",\"is_private\":false,\"channel_id\":\"%\",\"channel_type\":%", r.status, r.channel_id, fsnow(vmap(r.body), "id"), r.tag));
			refresh_templates(c, r.channel_id);
		case .Channel_Edit; #through;
		case .Channel_Delete;
			if !r.ok return;
			gid := fsnow(vmap(r.body), "guild_id");
			if !gid {
				ch := channel_get(*c.store, r.channel_id);
				if ch gid = ch.guild_id;
			}
			refresh_templates(c, gid);
	}
}

// guild_admin_tick: due new-event acks, POST /guilds/{gid}/ack/1/{eid} {} (from client_poll).
guild_admin_tick :: (c: *Client, now: s64) {
	locks.guard(*evt_mu);
	i := 0;
	while i < evt.acks.count {
		a := evt.acks[i];
		if a.client != c || now < a.at {
			i += 1;
			continue;
		}
		array_ordered_remove_by_index(*evt.acks, i);
		if !event_get(a.event_id) continue; // cancelled meanwhile
		feature_submit(c, .Guild_Aux, "POST", tprint("/guilds/%/ack/1/%", a.guild_id, a.event_id), "{}", channel_id = a.guild_id);
	}
}

// ---- custom emoji ----

EMOJI_MAX_BYTES :: 256 * 1024;

// emoji_name_from_filename: the file's base name without extension; characters
// other than A-Z a-z 0-9 _ become "_"; 2..32 characters ("emoji" when shorter).
emoji_name_from_filename :: (path: string, allocator := temp) -> string {
	base := path;
	slash := find_index_of_any_from_right(base, "/\\");
	if slash >= 0 base = advance(base, slash + 1);
	dot := find_index_from_right(base, #char ".");
	if dot > 0 base.count = dot;
	out: [..]u8;
	out.allocator = allocator;
	i := 0;
	while i < base.count && out.count < 32 {
		_, size := character_utf8_to_utf32(base.data + i, base.count - i);
		c := base[i];
		array_add(*out, ifx size == 1 && is_alnum(c) then c else #char "_");
		i += size;
	}
	if out.count < 2 {
		array_free(out);
		return copy_string("emoji",, allocator);
	}
	return cast(string) out;
}

image_mime :: (path: string) -> string {
	lower := to_lower_copy(path,, temp);
	if ends_with(lower, ".png") return "image/png";
	if ends_with(lower, ".jpg") || ends_with(lower, ".jpeg") return "image/jpeg";
	if ends_with(lower, ".gif") return "image/gif";
	if ends_with(lower, ".webp") return "image/webp";
	if ends_with(lower, ".avif") return "image/avif";
	return "";
}

// file_job_body (feature worker thread): reads the image at path and builds
// {"image":"data:<mime>;base64,..","name":<name>} plus X-Discord-Original-MD5, all in temp.
// status: 0 ok, -1 unreadable / not an image, -2 over EMOJI_MAX_BYTES.
file_job_body :: (path: string, name: string, op: Feature_Op) -> string, []http.Header, int {
	if op == .Sound_Upload {
		// {<name, volume, emoji fields>,"sound":"data:audio/<type>;base64,.."}; the type by magic bytes
		data, ok := read_entire_file(path, log_errors = false,, temp);
		if !ok || !data return "", .[], -1;
		if data.count > SOUNDBOARD_MAX_BYTES return "", .[], -2;
		mime := sound_mime(cast([]u8) data);
		if !mime return "", .[], -1;
		return tprint("{%,\"sound\":\"data:%;base64,%\"}", name, mime, base64_encode(data,, temp)), .[], 0;
	}
	mime := image_mime(path);
	if !mime return "", .[], -1;
	data, ok := read_entire_file(path, log_errors = false,, temp);
	if !ok || !data return "", .[], -1;
	if op == .Guild_Edit || op == .Avatar_Edit {
		if data.count > HOSTED_ICON_MAX_BYTES return "", .[], -2;
		w: Json;
		json_init(*w);
		json_obj(*w);
		json_kstr(*w, ifx op == .Avatar_Edit then "avatar" else "icon", tprint("data:%;base64,%", mime, base64_encode(data,, temp)));
		json_obj_end(*w);
		return json_string(*w), .[], 0;
	}
	if data.count > EMOJI_MAX_BYTES return "", .[], -2;
	digest := crypto.md5(cast([]u8) data);
	sb: String_Builder;
	sb.allocator = temp;
	for digest print_to_builder(*sb, "%", formatInt(it, base = 16, minimum_digits = 2));
	w: Json;
	json_init(*w);
	json_obj(*w);
	json_kstr(*w, "image", tprint("data:%;base64,%", mime, base64_encode(data,, temp)));
	json_kstr(*w, "name", name);
	json_obj_end(*w);
	extra := NewArray(1, http.Header,, temp);
	extra[0] = .{"x-discord-original-md5", builder_to_string(*sb,, temp)};
	return json_string(*w), extra, 0;
}

// upload_guild_emoji: POST /guilds/{id}/emojis from an image file (read off the UI thread).
upload_guild_emoji :: (c: *Client, guild_id: Snowflake, path: string, name: string) {
	feature_submit(c, .Emoji_Upload, "POST", tprint("/guilds/%/emojis", guild_id), name, channel_id = guild_id, context_b64 = context_b64("{\"client_event_source\":\"Emoji Studio\"}"), file = path);
}

// api_error_message: the "message" of a Discord error body (first field error when present).
api_error_message :: (body: V) -> string {
	// {"code":50035,"errors":{"name":{"_errors":[{"code":..,"message":..}]}},"message":"Invalid Form Body"}
	m := vmap(body);
	for kv: fmap(m, "errors") for ev: flist(vmap(kv.value), "_errors") {
		msg := fstr(vmap(ev), "message");
		if msg return msg;
	}
	return fstr(m, "message");
}

// kick_member and ban_member: the user menu's Kick and Ban. The reason rides in X-Audit-Log-Reason,
// URI-encoded as the client's HTTP layer sends it; Discord applies the result through GUILD_MEMBER_REMOVE.
kick_member :: (c: *Client, guild_id: Snowflake, user_id: Snowflake, reason: string) {
	j := job_new(.Api, .None);
	j.method = "DELETE";
	j.path = job_str(j, tprint("/guilds/%/members/%", guild_id, user_id));
	audit_reason(j, reason);
	job_submit(c, j);
}

ban_member :: (c: *Client, guild_id: Snowflake, user_id: Snowflake, reason: string, delete_message_seconds := 0) {
	j := job_new(.Api, .None);
	j.method = "PUT";
	j.path = job_str(j, tprint("/guilds/%/bans/%", guild_id, user_id));
	j.body = cast([]u8) job_str(j, tprint("{\"delete_message_seconds\":%}", delete_message_seconds));
	j.content_type = "application/json";
	audit_reason(j, reason);
	job_submit(c, j);
}

audit_reason :: (j: *Job, reason: string) {
	r := trim(reason);
	if !r return;
	j.extra = NewArray(1, http.Header,, job_alloc(j));
	j.extra[0] = .{"x-audit-log-reason", job_str(j, uri_component(r))};
}
