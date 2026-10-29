// Desktop notifications, following the client's NotificationStore
// (MESSAGE_CREATE handler + shouldNotify): the shared per-frame message list
// (app_new_messages) filtered by message_notifies (DMs always; guild/channel
// mute, message_notifications with the guild default; mentions incl. roles and
// @everyone), never for SUPPRESS_NOTIFICATIONS messages, blocked authors, Do
// Not Disturb, or the channel being viewed in a focused window. The
// "message1" sound is played by sounds.jai for the same messages. Titles:
// "Author (#channel, Parent)" / "Author (Group)" / "Author". The dock badge
// shows the total unread mention count.

SUPPRESS_NOTIFICATIONS :: (cast(u64) 1) << 12;

notify_tick :: () {
	if app.client == null return;
	s := *connections()[0].store; // Discord's: its status is the one you set.
	for * m: app_new_messages() {
		mc := message_client(m);
		if app.focused && m.channel_id == app.view.channel && mc == app.client continue;
		if s.settings.status == .Dnd || streamer_disable_notifications() continue;
		if !message_notifies(m) || notify_prefs.desktop_off || notify_prefs.lotus continue;
		// name_in and the rest read app.client, so it is the message's connection while it's shown.
		prev := app.client;
		app.client = mc;
		if !notify_later(m) notify_message(*mc.store, m);
		app.client = prev;
	}
	// Encrypted messages, once opened: with their plaintext, or as "Encrypted message" after 5 s.
	for ns.waiting {
		sh := table_find_pointer(*ee.shown, it.id);
		if sh && sh.pending && platform.time_now() < it.until { request_wake(it.until); continue; }
		prev := app.client;
		app.client = message_client(*it);
		if !encrypted_silent(it.id) notify_message(*app.client.store, *it);
		app.client = prev;
		remove it;
	}
	// dock badge: unread mentions, on every connection, and incoming friend requests
	total := 0;
	for c: connections() {
		// only channels still there: a server you left or a DM you closed keeps its read state
		for c.store.read_states if dc.channel_get(*c.store, it.channel_id) total += max(it.mention_count, 0);
		for c.store.relationships if it.kind == .Incoming_Request total += 1;
	}
	if notify_prefs.badge_off || notify_prefs.lotus total = 0; // Settings > Notifications > Unread Message Badge
	if !ns.badge_set || total != ns.badge {
		ns.badge = total;
		ns.badge_set = true;
		platform.set_badge(ifx total > 0 then tprint("%", total) else "");
	}
}

notifications_sent :: () -> int { return ns.notified; }

notify_reset_for_test :: () { ns = .{}; }

// A click on a notification (Linux; id is the message's): opens its channel at the message, as the client's
// onClick does, when it's in the open connection's store.
notify_clicked :: (id: string) {
	mid, ok := dc.parse_u64(id);
	if !ok return;
	for ns.recent if it[0] == mid {
		ch := dc.channel_get(store(), it[1]);
		if ch jump_to_message(ch.id, mid);
		return;
	}
}

#scope_file

ns: struct {
	badge: int;
	badge_set: bool;
	notified: int;
	waiting: [..]Waiting;
	recent: [32][2]u64; // message and channel of the latest notifications (ring), for notify_clicked
	recent_next: int;
};

Waiting :: struct { #as using m: dc.New_Message; until: float64; }

// notify_later holds an encrypted DM's notification until its packet is opened, so it can show the
// plaintext, and drops it when the sender asked for silence inside the packet.
notify_later :: (m: *dc.New_Message) -> bool {
	if !encrypted_packet(m.channel_id, m.content) || streamer_hide_personal() return false;
	sh := encrypted_open(m.id, m.channel_id, m.content, m.author_id);
	if sh && sh.pending {
		w := Waiting.{m = m.*, until = platform.time_now() + 5};
		w.content, w.webhook_name, w.mention_roles = e2e.PREFIX, "", ([..]dc.Snowflake).{}; // m's own copies go with the frame.
		array_add(*ns.waiting, w);
		request_wake(w.until);
		return true;
	}
	return encrypted_silent(m.id);
}

notify_message :: (s: *dc.Store, m: *dc.New_Message) {
	ch := dc.channel_get(s, m.channel_id);
	author := author_name(m);
	title := author;
	if ch.kind == {
	case .DM;
	case .Group_DM;
		title = tprint("% (%)", author, dm_name(ch));
	case;
		parent := "";
		if ch.parent_id != 0 {
			p := dc.channel_get(s, ch.parent_id);
			if p parent = p.name;
		}
		title = ifx parent != "" then tprint("% (#%, %)", author, ch.name, parent) else tprint("% (#%)", author, ch.name);
	}
	body := notification_body(s, m);
	// Streamer Mode > Hide Personal Information: no DM names or DM content on screen
	if (ch.kind == .DM || ch.kind == .Group_DM) && streamer_hide_personal() title, body = author, "";
	platform.notify_show(title, body, tprint("%", cast(u64) m.id));
	ns.recent[ns.recent_next] = .[cast(u64) m.id, cast(u64) m.channel_id];
	ns.recent_next = (ns.recent_next + 1) % ns.recent.count;
	// the library reports it as acked (notification_action ACK) when the channel's MESSAGE_ACK comes
	if app.client != null dc.analytics_notification_shown(app.client, m.id, m.channel_id, m.author_id, m.kind, !notify_prefs.badge_off);
	ns.notified += 1;
}

// Content as plain text with <@id>/<@&id>/<#id> resolved, or a stand-in for media-only messages.
notification_body :: (s: *dc.Store, m: *dc.New_Message) -> string {
	if encrypted_packet(m.channel_id, m.content) return shown_text(m.id, m.channel_id, m.content);
	if m.content == "" {
		if m.sticker return "Sent a sticker";
		if m.attachments > 0 return "Uploaded a file";
		return "";
	}
	sb: String_Builder;
	sb.allocator = temp;
	c := m.content;
	while c.count > 0 {
		i := find_index_from_left(c, #char "<");
		if i < 0 {
			append(*sb, c);
			break;
		}
		append(*sb, to_string(c.data, i));
		advance(*c, i);
		end := find_index_from_left(c, #char ">");
		if end < 0 {
			append(*sb, c);
			break;
		}
		tag := to_string(c.data + 1, end - 1);
		if begins_with(tag, "@!") || begins_with(tag, "@") && !begins_with(tag, "@&") {
			id := dc.parse_snowflake(trim_left(tag, "@!"));
			print_to_builder(*sb, "@%", name_in(id, m.channel_id, "unknown-user"));
		} else if begins_with(tag, "@&") {
			id := dc.parse_snowflake(advance(tag, 2));
			name := "deleted-role";
			g := dc.guild_get(s, m.guild_id);
			if g for g.roles if it.id == id name = it.name;
			print_to_builder(*sb, "@%", name);
		} else if begins_with(tag, "#") {
			cc := dc.channel_get(s, dc.parse_snowflake(advance(tag, 1)));
			print_to_builder(*sb, "#%", ifx cc then cc.name else "unknown");
		} else if begins_with(tag, ":") || begins_with(tag, "a:") {
			parts := split(tag, ":",, temp);
			if parts.count >= 2 print_to_builder(*sb, ":%:", parts[parts.count - 2]);
		} else {
			append(*sb, to_string(c.data, end + 1));
		}
		advance(*c, end + 1);
	}
	return builder_to_string(*sb,, temp);
}
