// PreloadedUserSettings writes (UserSettingsProtoStore.updateAsync):
// each change edits the kept proto at once and marks its category; at the
// save timer the delta is every marked category whole, and the save is
//   PATCH /users/@me/settings-proto/1 {"settings":"<base64 delta>"}
// Timer per change kind (UserSettingsDelay): INFREQUENT_USER_ACTION 0 s
// (status, custom status, theme), FREQUENT_USER_ACTION 10 s (guild folders).
// protobuf-ts writes fields in number order and skips defaults.

SETTINGS_DELAY_INFREQUENT_MS :: 0;
SETTINGS_DELAY_FREQUENT_MS :: 10_000;

Custom_Status :: struct {
	text: string;
	emoji_id: Snowflake;
	emoji_name: string;
	expires_at_ms: s64;
	clear_after: Clear_After; // the modal's "Clear after" choice (telemetry)
}

// The pending delta: whole categories of the kept proto, saved at `due`.
Settings_Edit :: struct {
	due: s64; // 0 = nothing pending
	cats: u64; // bit n: category n of the kept proto is part of the delta, whole (settings_put)
	sending: u64; // the categories of the PATCH in flight (one at a time)
	retry_ms: s64; // the wait before resending a failed PATCH: 10 s, doubling to 5 min
	presence: bool; // the status changed: op 3 goes out with the save
}

// InboxSettings.current_tab (PreloadedUserSettings field 2): the Inbox popout
// reopens on it.
Inbox_Tab :: enum u8 {
	Unspecified :: 0;
	Mentions :: 1;
	Unreads :: 2;
}

#scope_module

pb_new :: () -> protobuf.Writer {
	w: protobuf.Writer;
	w.buf.allocator = temp;
	return w;
}

pb_msg :: (w: *protobuf.Writer, num: u32, inner: protobuf.Writer) { protobuf.write_bytes(w, num, inner.buf); }

#scope_export

// settings_delta_proto: the pending delta (temp), the categories in e.cats whole from the kept
// proto, unknown fields byte for byte.
settings_delta_proto :: (e: *Settings_Edit, proto: []u8) -> []u8 { return pb_categories(proto, e.cats); }

// pb_categories: the top-level fields of proto whose bit is set in mask, whole (temp).
pb_categories :: (proto: []u8, mask: u64) -> []u8 {
	out: []u8;
	for n: 1..63 {
		if !(mask & ((cast(u64) 1) << n)) continue;
		r := protobuf.Reader.{buf = proto};
		while true {
			start := r.pos;
			f, more := protobuf.next(*r);
			if !more break;
			if f.num == xx n out = protobuf.with_field(out, xx n, array_view(proto, start, r.pos - start),, temp);
		}
	}
	return out;
}

// Field encoders for settings_put (temp). Like protobuf-ts, a default scalar is not written; a
// wrapper (BoolValue, StringValue...) is a message, written even when it holds the default.
pb_field_uint :: (num: u32, v: u64) -> []u8 {
	w := pb_new();
	if v protobuf.write_uint(*w, num, v);
	return w.buf;
}
pb_field_msg :: (num: u32, inner: []u8) -> []u8 {
	w := pb_new();
	protobuf.write_bytes(*w, num, inner);
	return w.buf;
}
pb_fixed64 :: (w: *protobuf.Writer, num: u32, v: u64) {
	protobuf.write_tag(w, num, .I64);
	for i: 0..7 array_add(*w.buf, cast(u8) (v >> (8 * i)));
}
pb_field_fixed64 :: (num: u32, v: u64) -> []u8 {
	w := pb_new();
	if v pb_fixed64(*w, num, v);
	return w.buf;
}
pb_field_bool_value :: (num: u32, v: bool) -> []u8 { return pb_field_msg(num, pb_field_uint(1, xx v)); }
pb_field_string_value :: (num: u32, v: string) -> []u8 {
	w := pb_new();
	if v protobuf.write_string(*w, 1, v);
	return pb_field_msg(num, w.buf);
}

// settings_put edits field `num` of category `cat` (a PreloadedUserSettings field) as
// updateAsync does: the delta carries the whole category as it now is, with the change
// (`encoded`: the whole field, empty to unset it), applied locally at once, saved after delay_ms.
settings_put :: (c: *Client, cat: u32, num: u32, encoded: []u8, sub: u32 = 0, delay_ms := SETTINGS_DELAY_INFREQUENT_MS) {
	assert(cat < 64);
	settings_proto_edit(*c.store, cat, num, encoded, sub);
	c.settings_edit.cats |= (cast(u64) 1) << cat;
	st := *c.store.settings;
	st.unsent |= (cast(u64) 1) << cat;
	// The edit itself is kept, not its category: an edit made before READY saw an empty proto, and
	// keeping that category whole would wipe the rest of it (Developer Mode reset the theme).
	for st.edits if it.cat == cat && it.num == num && it.sub == sub {
		free(it.encoded.data,, c.store.allocator);
		array_ordered_remove_by_index(*st.edits, it_index);
		break;
	}
	array_add(*st.edits, .{cat, num, sub, array_copy(encoded,, c.store.allocator)});
	settings_mark(c, delay_ms);
}

// settings_proto_edit: the local half of settings_put (offline runs use it alone).
settings_proto_edit :: (s: *Store, cat: u32, num: u32, encoded: []u8, sub: u32 = 0) {
	settings_proto_set(s, proto_with_edit(s.settings.proto, cat, num, encoded, sub));
	s.changed += 1;
}

// proto_with_edit: proto with field `num` of category `cat` set (temp). A nested field (`sub` > 0)
// is field `sub` of message field `num`, the rest of that message kept.
proto_with_edit :: (proto: []u8, cat: u32, num: u32, encoded: []u8, sub: u32 = 0) -> []u8 {
	f := protobuf.find(proto, cat);
	field := encoded;
	if sub {
		inner := protobuf.find(f.bytes, num);
		field = pb_field_msg(num, protobuf.with_field(inner.bytes, sub, encoded,, temp));
	}
	body := protobuf.with_field(f.bytes, num, field,, temp);
	return protobuf.with_field(proto, cat, pb_field_msg(cat, body),, temp);
}

// settings_edits_prune drops the kept edits of categories the server has taken.
settings_edits_prune :: (s: *Store) {
	st := *s.settings;
	n := 0;
	for st.edits {
		if st.unsent & ((cast(u64) 1) << it.cat) {
			st.edits[n] = it;
			n += 1;
		} else {
			free(it.encoded.data,, s.allocator);
		}
	}
	st.edits.count = n;
}

// settings_ids: a packed repeated fixed64 field at path (guild ids), in temp.
settings_ids :: (s: *Store, path: ..u32) -> []u64 {
	f, ok := protobuf.find_path(s.settings.proto, ..path);
	if !ok || f.wire != .Len return .[];
	return protobuf.packed_fixed64(f.bytes,, temp);
}

// pb_field_ids: ids as a packed fixed64 field (nothing for none, as protobuf-ts writes it).
pb_field_ids :: (num: u32, ids: []u64) -> []u8 {
	if !ids return .[];
	b := NewArray(ids.count * 8, u8, false,, temp);
	for id, i: ids for k: 0..7 b[i * 8 + k] = cast(u8) (id >> (8 * k));
	return pb_field_msg(num, b);
}

// settings_bytes: a length-delimited value (a string) at path, viewing the kept proto.
settings_bytes :: (s: *Store, path: ..u32) -> []u8, bool {
	f, ok := protobuf.find_path(s.settings.proto, ..path);
	return f.bytes, ok && f.wire == .Len;
}

// settings_value: a varint at path in the kept proto (a wrapper's value: its field 1 last), and
// whether it is set.
settings_value :: (s: *Store, path: ..u32) -> u64, bool {
	f, ok := protobuf.find_path(s.settings.proto, ..path);
	return f.value, ok;
}

#scope_module

settings_mark :: (c: *Client, delay_ms: s64) {
	due := now_ms() + delay_ms;
	e := *c.settings_edit;
	// A pending timer with a longer delay is replaced by a shorter one (markDirty).
	if e.due == 0 || due < e.due e.due = due;
}

#scope_export

// set_status: online / idle / dnd / invisible (setStatus). duration_ms > 0 is
// a timed status ("For 15 Minutes"...): status_expires_at_ms = now + duration,
// and status_expiry_tick sets Online back when it passes. The created time is
// kept when the status does not change. expired: the expiry timer's call
// (location CUSTOM_STATUS_MANAGER).
set_status :: (c: *Client, s: Status, duration_ms: s64 = 0, expired := false) {
	st := *c.store.settings;
	analytics_status_updated(c, st.status, s, duration_ms, expired);
	now := now_ms();
	created := ifx s != st.status || st.status_created_ms == 0 then now else st.status_created_ms;
	settings_put(c, 11, 1, pb_field_string_value(1, status_name(s)));
	settings_put(c, 11, 4, pb_field_fixed64(4, xx ifx duration_ms > 0 then now + duration_ms else 0));
	settings_put(c, 11, 5, pb_field_msg(5, pb_field_uint(1, xx created))); // UInt64Value
	c.settings_edit.presence = true;
}

// mirror_presence: a self-hosted server's client takes the status and custom status set on Discord's
// client, which owns the settings, and tells its server at once; later Identifies carry the status
// (flush_presence).
mirror_presence :: (c: *Client, from: *Client) {
	st, src := *c.store.settings, *from.store.settings;
	st.status = src.status;
	free_str(st.custom_status_text, c.allocator);
	free_str(st.custom_status_emoji, c.allocator);
	st.custom_status_text = clone_str(src.custom_status_text, c.allocator);
	st.custom_status_emoji = clone_str(src.custom_status_emoji, c.allocator);
	st.custom_status_emoji_id = src.custom_status_emoji_id;
	st.custom_status_expires_ms = src.custom_status_expires_ms;
	c.store.changed += 1;
	if c.gw gateway_send(c.gw, .Presence_Update, presence_value(c,, temp));
}

// status_expiry_tick: CustomStatusManager.manageExpiringStatus, a timed status
// that has passed goes back to Online.
status_expiry_tick :: (c: *Client, now: s64) {
	st := *c.store.settings;
	if st.status == .Online || st.status_expires_ms == 0 || now < st.status_expires_ms return;
	set_status(c, .Online, expired = true);
}

// set_custom_status; empty text and emoji clears it.
set_custom_status :: (c: *Client, cs: Custom_Status) {
	clearing := !cs.text && !cs.emoji_name && !cs.emoji_id;
	if !clearing analytics_custom_status_updated(c, cs);
	cm := pb_new(); // CustomStatus (11.2); clearing leaves it out
	if cs.text protobuf.write_string(*cm, 1, cs.text);
	if cs.emoji_id pb_fixed64(*cm, 2, cs.emoji_id);
	if cs.emoji_name protobuf.write_string(*cm, 3, cs.emoji_name);
	if cs.expires_at_ms pb_fixed64(*cm, 4, xx cs.expires_at_ms);
	pb_fixed64(*cm, 5, xx now_ms()); // created_at_ms
	settings_put(c, 11, 2, ifx clearing then .[] else pb_field_msg(2, cm.buf));
	c.settings_edit.presence = true;
}

// presence_value: op 3 (SelfPresenceStore.getLocalPresence) in context.allocator. While idle an
// online status reads "idle", since = idleSince for every status, afk = IdleStore.isAFK.
presence_value :: (c: *Client, old_afk := false) -> V {
	st := *c.store.settings;
	acts: [..]V;
	if st.custom_status_text || st.custom_status_emoji {
		a := etf.map_builder(8);
		etf.map_put(*a, "name", etf.vstring("Custom Status"));
		etf.map_put(*a, "type", etf.vint(4));
		if st.custom_status_text etf.map_put(*a, "state", etf.vstring(copy_string(st.custom_status_text)));
		if st.custom_status_expires_ms {
			ts := etf.map_builder(1);
			etf.map_put(*ts, "end", etf.vint(st.custom_status_expires_ms));
			etf.map_put(*a, "timestamps", etf.vmap(etf.map_done(*ts)));
		}
		if st.custom_status_emoji {
			em := etf.map_builder(3);
			etf.map_put(*em, "name", etf.vstring(copy_string(st.custom_status_emoji)));
			etf.map_put(*em, "id", ifx st.custom_status_emoji_id == 0 then V.{} else etf.vstring(snowflake_string(st.custom_status_emoji_id)));
			etf.map_put(*em, "animated", etf.vbool(false));
			etf.map_put(*a, "emoji", etf.vmap(etf.map_done(*em)));
		} else {
			etf.map_put(*a, "emoji", V.{});
		}
		etf.map_put(*a, "details", V.{});
		md := etf.map_builder(1);
		etf.map_put(*md, "label", V.{});
		etf.map_put(*a, "metadata", etf.vmap(etf.map_done(*md)));
		array_add(*acts, etf.vmap(etf.map_done(*a)));
	}
	b := etf.map_builder(4);
	etf.map_put(*b, "status", etf.vstring(status_name(ifx st.status == .Online && c.idle_sent then .Idle else st.status)));
	etf.map_put(*b, "since", etf.vint(c.idle_sent));
	etf.map_put(*b, "activities", etf.vlist(acts));
	etf.map_put(*b, "afk", etf.vbool((c.idle_sent != 0) != old_afk)); // old_afk: the AFK flag before an idle change
	return etf.vmap(etf.map_done(*b));
}

// set_theme: the user picked a theme (system: "Sync with computer", t resolved from the OS).
set_theme :: (c: *Client, t: Theme, system := false) {
	analytics_theme_updated(c, t, system);
	// AppearanceSettings (13): theme, and client_theme_settings (3) set, empty when it was unset
	settings_put(c, 13, 1, pb_field_uint(1, cast(u64) t));
	_, has := protobuf.find_path(c.store.settings.proto, 13, 3);
	if !has settings_put(c, 13, 3, pb_field_msg(3, .[]));
}

// set_hour_cycle: Language & Time > Time format (AppearanceSettings.timestamp_hour_cycle).
set_hour_cycle :: (c: *Client, h: Hour_Cycle) { settings_put(c, 13, 9, pb_field_uint(9, xx h)); }

// set_developer_mode: Advanced > Developer Mode (AppearanceSettings.developer_mode).
set_developer_mode :: (c: *Client, on: bool) { settings_put(c, 13, 2, pb_field_uint(2, xx on)); }

// set_locale: Language & Time > Language (LocalizationSettings.locale, a StringValue).
set_locale :: (c: *Client, locale: string) { settings_put(c, 12, 1, pb_field_string_value(1, locale)); }

// set_inbox_tab: switching the Inbox tab (FREQUENT_USER_ACTION: the 10 s
// timer starts at the first switch and saves the tab current then; fixture
// inbox: Unreads at +0, Mentions at +6 s, one PATCH with MENTIONS at +10 s).
set_inbox_tab :: (c: *Client, tab: Inbox_Tab) { settings_put(c, 2, 1, pb_field_uint(1, xx tab), delay_ms = SETTINGS_DELAY_FREQUENT_MS); }

// set_guild_folders replaces the sidebar folders (GuildFolders.folders, 14.1, repeated).
set_guild_folders :: (c: *Client, folders: []Guild_Folder) {
	gf := pb_new();
	for f: folders {
		fm := pb_new();
		if f.guild_ids {
			ids := pb_new();
			for g: f.guild_ids for i: 0..7 array_add(*ids.buf, cast(u8) (g >> (8 * i)));
			protobuf.write_bytes(*fm, 1, ids.buf);
		}
		if f.id protobuf.write_bytes(*fm, 2, pb_field_uint(1, xx f.id)); // Int64Value
		if f.name array_add(*fm.buf, ..pb_field_string_value(3, f.name));
		if f.has_color protobuf.write_bytes(*fm, 4, pb_field_uint(1, f.color)); // UInt64Value
		protobuf.write_bytes(*gf, 1, fm.buf);
	}
	settings_put(c, 14, 1, gf.buf, delay_ms = SETTINGS_DELAY_FREQUENT_MS);
}

// flush_settings: persistChanges when the save timer fires.
flush_settings :: (c: *Client, now: s64) {
	// LocaleStore: the language setting (localization.locale) is x-discord-locale once known
	if c.store.settings.locale {
		l := discord_locale(c.store.settings.locale);
		if l != c.id.platform.locale identity_set_locale(*c.id, l);
	}
	frecency_tick(c, now); // settings-proto/2 (expressions.jai)
	e := *c.settings_edit;
	if e.due == 0 || now < e.due || e.sending return;
	delta := settings_delta_proto(e, c.store.settings.proto);
	// PresenceStore: the gateway presence goes out with the settings write
	if e.presence && c.gw gateway_send(c.gw, .Presence_Update, presence_value(c,, temp));
	e.sending, e.cats, e.due, e.presence = e.cats, 0, 0, false;
	if !delta {
		e.sending = 0;
		return;
	}
	w: Json;
	json_init(*w);
	json_obj(*w);
	json_kstr(*w, "settings", base64_encode(cast(string) delta,, temp));
	json_obj_end(*w);
	j := job_new(.Api, .Settings);
	j.method = "PATCH";
	j.path = "/users/@me/settings-proto/1";
	j.body = cast([]u8) job_str(j, json_string(*w));
	j.content_type = "application/json";
	j.retry_429 = 1; // retried after min(30 s, Retry-After)
	job_submit(c, j);
}

// settings_saved: the settings-proto/1 PATCH's answer. A failed one (offline, 429, 5xx) goes again
// after retry_ms, its categories kept over READY until then; one the server refuses is dropped.
settings_saved :: (c: *Client, r: *Rest_Result, b64: string) {
	e, st := *c.settings_edit, *c.store.settings;
	if !r.ok && (r.status == 0 || r.status == 429 || r.status >= 500) {
		e.retry_ms = clamp(e.retry_ms * 2, 10_000, 300_000);
		e.cats |= e.sending;
		settings_mark(c, e.retry_ms);
	} else {
		e.retry_ms = 0;
		st.unsent &= e.cats; // edits made since the PATCH left stay local
		settings_edits_prune(*c.store);
	}
	e.sending = 0;
	if b64 apply_settings_proto(*c.store, b64);
}
