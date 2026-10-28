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
	s := store();
	for * m: app_new_messages() {
		if m.flags & SUPPRESS_NOTIFICATIONS continue;
		if app.focused && m.channel_id == app.view.channel continue;
		if s.settings.status == .Dnd || streamer_disable_notifications() continue;
		r := table_find_pointer(*s.relationships, m.author_id);
		if r && r.kind == .Blocked continue;
		if !message_notifies(m) || notify_prefs.desktop_off || notify_prefs.lotus continue;
		notify_message(s, m);
	}
	// dock badge: unread mentions
	total := 0;
	for s.read_states total += max(it.mention_count, 0);
	if notify_prefs.badge_off || notify_prefs.lotus total = 0; // Settings > Notifications > Unread Message Badge
	if !ns.badge_set || total != ns.badge {
		ns.badge = total;
		ns.badge_set = true;
		platform.set_badge(ifx total > 0 then tprint("%", total) else "");
	}
}

notifications_sent :: () -> int { return ns.notified; }

notify_reset_for_test :: () { ns = .{}; }

#scope_file

ns: struct {
	badge: int;
	badge_set: bool;
	notified: int;
};

notify_message :: (s: *dc.Store, m: *dc.New_Message) {
	ch := dc.channel_get(s, m.channel_id);
	author := name_in(m.author_id, m.channel_id);
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
	// the library reports it as acked (notification_action ACK) when the channel's MESSAGE_ACK comes
	if app.client != null dc.analytics_notification_shown(app.client, m.id, m.channel_id, m.author_id, m.kind, !notify_prefs.badge_off);
	ns.notified += 1;
}

// Content as plain text with <@id>/<#id> resolved, or a stand-in for media-only messages.
notification_body :: (s: *dc.Store, m: *dc.New_Message) -> string {
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
