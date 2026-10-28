// PreloadedUserSettings writes (UserSettingsProtoStore.updateAsync):
// each change builds a *delta* proto (ProtoClass.create() + the edited
// fields), deltas are merged until the save timer fires, and the save is
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

// The pending delta: each has_* says the field is part of it. Strings and folders are in c.allocator.
Settings_Edit :: struct {
	due: s64; // 0 = nothing pending
	status: Status;
	has_status: bool;
	status_ms: s64; // status_created_at_ms
	status_expires_ms: s64; // status_expires_at_ms (fixed64 4), 0 = forever
	custom: Custom_Status;
	has_custom: bool;
	custom_ms: s64; // CustomStatus.created_at_ms
	clear_custom: bool;
	theme: Theme;
	has_theme: bool;
	friend_online: bool; // NotificationSettings.notify_friends_on_launch (12)
	has_friend_online: bool;
	folders: []Guild_Folder;
	has_folders: bool;
	inbox_tab: Inbox_Tab;
	has_inbox_tab: bool;
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

pb_fixed64 :: (w: *protobuf.Writer, num: u32, v: u64) {
	protobuf.write_tag(w, num, .I64);
	for i: 0..7 array_add(*w.buf, cast(u8) (v >> (8 * i)));
}

pb_msg :: (w: *protobuf.Writer, num: u32, inner: protobuf.Writer) { protobuf.write_bytes(w, num, inner.buf); }

// pb_wrapped writes a wrapper message (StringValue, UInt64Value, ...) holding field 1.
pb_wrapped_uint :: (w: *protobuf.Writer, num: u32, v: u64) {
	inner := pb_new();
	protobuf.write_uint(*inner, 1, v);
	pb_msg(w, num, inner);
}

#scope_export

// settings_delta_proto encodes the pending edit as a PreloadedUserSettings delta (temp).
settings_delta_proto :: (e: *Settings_Edit) -> []u8 {
	root := pb_new();
	if e.has_inbox_tab {
		ib := pb_new(); // InboxSettings (2)
		if e.inbox_tab != .Unspecified protobuf.write_uint(*ib, 1, cast(u64) e.inbox_tab);
		pb_msg(*root, 2, ib);
	}
	if e.has_status || e.has_custom || e.clear_custom {
		st := pb_new(); // StatusSettings (11)
		if e.has_status {
			sv := pb_new(); // StringValue
			protobuf.write_string(*sv, 1, status_name(e.status));
			pb_msg(*st, 1, sv);
		}
		if e.has_custom {
			cs := *e.custom;
			cm := pb_new(); // CustomStatus (2)
			if cs.text protobuf.write_string(*cm, 1, cs.text);
			if cs.emoji_id pb_fixed64(*cm, 2, cs.emoji_id);
			if cs.emoji_name protobuf.write_string(*cm, 3, cs.emoji_name);
			if cs.expires_at_ms pb_fixed64(*cm, 4, cast(u64) cs.expires_at_ms);
			pb_fixed64(*cm, 5, cast(u64) e.custom_ms);
			pb_msg(*st, 2, cm);
		}
		if e.has_status && e.status_expires_ms pb_fixed64(*st, 4, cast(u64) e.status_expires_ms);
		// clearing: StatusSettings without custom_status (fixture custom_status)
		if e.has_status && e.status_ms pb_wrapped_uint(*st, 5, cast(u64) e.status_ms);
		pb_msg(*root, 11, st);
	}
	if e.has_friend_online {
		ns := pb_new(); // NotificationSettings (7)
		bv := pb_new(); // BoolValue: false is the empty message
		if e.friend_online protobuf.write_uint(*bv, 1, 1);
		pb_msg(*ns, 12, bv);
		pb_msg(*root, 7, ns);
	}
	if e.has_theme {
		ap := pb_new(); // AppearanceSettings (13): theme + client_theme_settings (3, empty)
		protobuf.write_uint(*ap, 1, cast(u64) e.theme);
		pb_msg(*ap, 3, pb_new());
		pb_msg(*root, 13, ap);
	}
	if e.has_folders {
		gf := pb_new(); // GuildFolders (14)
		for f: e.folders {
			fm := pb_new();
			if f.guild_ids {
				ids := pb_new();
				for g: f.guild_ids for i: 0..7 array_add(*ids.buf, cast(u8) (g >> (8 * i)));
				pb_msg(*fm, 1, ids);
			}
			if f.id pb_wrapped_uint(*fm, 2, cast(u64) f.id); // Int64Value
			if f.name {
				nm := pb_new();
				protobuf.write_string(*nm, 1, f.name);
				pb_msg(*fm, 3, nm);
			}
			if f.has_color pb_wrapped_uint(*fm, 4, f.color); // UInt64Value
			pb_msg(*gf, 1, fm);
		}
		pb_msg(*root, 14, gf);
	}
	return root.buf;
}

#scope_module

settings_mark :: (c: *Client, delay_ms: s64) {
	due := now_ms() + delay_ms;
	e := *c.settings_edit;
	// A pending timer with a longer delay is replaced by a shorter one (markDirty).
	if e.due == 0 || due < e.due e.due = due;
}

free_custom :: (c: *Client, e: *Settings_Edit) {
	if !e.has_custom return;
	free_str(e.custom.text, c.allocator);
	free_str(e.custom.emoji_name, c.allocator);
	e.custom = .{};
	e.has_custom = false;
}

free_folders :: (c: *Client, e: *Settings_Edit) {
	for e.folders {
		free_str(it.name, c.allocator);
		array_free(it.guild_ids);
	}
	free(e.folders.data,, c.allocator);
	e.folders = .[];
	e.has_folders = false;
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
	if s != st.status || st.status_created_ms == 0 st.status_created_ms = now;
	st.status = s;
	st.status_expires_ms = ifx duration_ms > 0 then now + duration_ms else 0;
	e := *c.settings_edit;
	e.status = s;
	e.has_status = true;
	e.status_ms = st.status_created_ms;
	e.status_expires_ms = st.status_expires_ms;
	c.store.changed += 1;
	settings_mark(c, SETTINGS_DELAY_INFREQUENT_MS);
}

// mirror_status: a self-hosted server's client takes the status picked on Discord's, which owns the
// setting, and tells its server at once; later Identifies carry it (flush_presence).
mirror_status :: (c: *Client, s: Status) {
	c.store.settings.status = s;
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
	e := *c.settings_edit;
	free_custom(c, e);
	if clearing {
		e.clear_custom = true;
	} else {
		e.custom = .{text = clone_str(cs.text, c.allocator), emoji_id = cs.emoji_id, emoji_name = clone_str(cs.emoji_name, c.allocator), expires_at_ms = cs.expires_at_ms};
		e.has_custom = true;
		e.custom_ms = now_ms();
		e.clear_custom = false;
	}
	// The whole StatusSettings is written: current status and its created time.
	if !e.has_status {
		e.status = c.store.settings.status;
		e.has_status = true;
		e.status_ms = c.store.settings.status_created_ms;
		e.status_expires_ms = c.store.settings.status_expires_ms;
	}
	st := *c.store.settings;
	free_str(st.custom_status_text, c.allocator);
	free_str(st.custom_status_emoji, c.allocator);
	st.custom_status_text = clone_str(cs.text, c.allocator);
	st.custom_status_emoji = clone_str(cs.emoji_name, c.allocator);
	st.custom_status_emoji_id = cs.emoji_id;
	st.custom_status_expires_ms = cs.expires_at_ms;
	c.store.changed += 1;
	settings_mark(c, SETTINGS_DELAY_INFREQUENT_MS);
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
	c.settings_edit.theme = t;
	c.settings_edit.has_theme = true;
	c.store.settings.theme = t;
	c.store.changed += 1;
	settings_mark(c, SETTINGS_DELAY_INFREQUENT_MS);
}

// set_inbox_tab: switching the Inbox tab (FREQUENT_USER_ACTION: the 10 s
// timer starts at the first switch and saves the tab current then; fixture
// inbox: Unreads at +0, Mentions at +6 s, one PATCH with MENTIONS at +10 s).
set_inbox_tab :: (c: *Client, tab: Inbox_Tab) {
	c.settings_edit.inbox_tab = tab;
	c.settings_edit.has_inbox_tab = true;
	c.store.settings.inbox_tab = tab;
	c.store.changed += 1;
	settings_mark(c, SETTINGS_DELAY_FREQUENT_MS);
}

// set_guild_folders replaces the sidebar folders (copied into c.allocator).
set_guild_folders :: (c: *Client, folders: []Guild_Folder) {
	cp := NewArray(folders.count, Guild_Folder,, c.allocator);
	for f, i: folders {
		ids: [..]Snowflake;
		ids.allocator = c.allocator;
		array_copy(*ids, f.guild_ids);
		cp[i] = f;
		cp[i].name = clone_str(f.name, c.allocator);
		cp[i].guild_ids = ids;
	}
	free_folders(c, *c.settings_edit);
	c.settings_edit.folders = cp;
	c.settings_edit.has_folders = true;
	settings_mark(c, SETTINGS_DELAY_FREQUENT_MS);
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
	if e.due == 0 || now < e.due return;
	delta := settings_delta_proto(e);
	// PresenceStore: the gateway presence goes out with the settings write
	if (e.has_status || e.has_custom || e.clear_custom) && c.gw gateway_send(c.gw, .Presence_Update, presence_value(c,, temp));
	free_custom(c, e);
	free_folders(c, e);
	e.* = .{};
	if !delta return;
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
