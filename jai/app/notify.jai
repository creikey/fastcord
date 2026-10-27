// Desktop notifications, following the client's NotificationStore
// (MESSAGE_CREATE handler + shouldNotify): the shared per-frame message list
// (app_new_messages) filtered by message_notifies (DMs always; guild/channel
// mute, message_notifications with the guild default; mentions incl. roles and
// @everyone), never for SUPPRESS_NOTIFICATIONS messages, blocked authors, Do
// Not Disturb, or the channel being viewed in a focused window. The
// "message1" sound is played by sounds.odin for the same messages. Titles:
// "Author (#channel, Parent)" / "Author (Group)" / "Author". The dock badge
// shows the total unread mention count.

SUPPRESS_NOTIFICATIONS :: (cast(u64)(1)) << 12;
#scope_file

Notify_State :: struct {
	badge: int;
	badge_set: bool;
	notified: int;
}

ns: Notify_State;
#scope_export

notify_tick :: () {
	if app.client == null { return; }
	s := store();
	for * m: app_new_messages() {
		if (m.flags & SUPPRESS_NOTIFICATIONS) != 0 { continue; }
		if app.focused && m.channel_id == app.view.channel { continue; }
		if s.settings.status == .Dnd || streamer_disable_notifications() { continue; }
		{ r, ok := map_find(s.relationships, m.author_id);
		if ok && r.kind == .Blocked { continue; } }
		if !message_notifies(m) || notify_prefs.desktop_off { continue; }
		notify_message(s, m);
	}
	// dock badge: unread mentions
	total := 0;
	for rs: s.read_states { total += max(rs.mention_count, 0); }
	if notify_prefs.badge_off { total = 0; } // Settings > Notifications > Unread Message Badge
	if !ns.badge_set || total != ns.badge {
		ns.badge = total;
		ns.badge_set = true;
		platform.set_badge(ifx total > 0 then fmt.tprintf("%d", total) else "");
	}
}
#scope_file

notify_message :: (s: *dc.Store, m: *dc.New_Message) {
	ch := dc.channel_get(s, m.channel_id);
	author := name_in(m.author_id, m.channel_id);
	title := author;
	if ch.kind == {
	case .DM;
	case .Group_DM;
		title = fmt.tprintf("%s (%s)", author, dm_name(ch));
	case;
		parent := "";
		if ch.parent_id != 0 {
			{ p := dc.channel_get(s, ch.parent_id);
			if p != null { parent = p.name; } }
		}
		title = ifx parent != "" then fmt.tprintf("%s (#%s, %s)", author, ch.name, parent) else fmt.tprintf("%s (#%s)", author, ch.name);
	}
	body := notification_body(s, m);
	// Streamer Mode > Hide Personal Information: no DM names or DM content on screen
	if (ch.kind == .DM || ch.kind == .Group_DM) && streamer_hide_personal() { title, body = author, ""; }
	platform.notify_show(title, body, fmt.tprintf("%v", cast(u64)(m.id)));
	// the library reports it as acked (notification_action ACK) when the channel's MESSAGE_ACK comes
	if app.client != null { dc.analytics_notification_shown(app.client, m.id, m.channel_id, m.author_id, m.kind, !notify_prefs.badge_off); }
	ns.notified += 1;
}

// Content as plain text with <@id>/<#id> resolved, or a stand-in for media-only messages.
notification_body :: (s: *dc.Store, m: *dc.New_Message) -> string {
	if m.content == "" {
		if m.sticker { return "Sent a sticker"; }
		if m.attachments > 0 { return "Uploaded a file"; }
		return "";
	}
	sb := strings.builder_make(temp);
	c := m.content;
	while len(c) > 0 {
		i := strings.index_byte(c, #char "<");
		if i < 0 {
			strings.write_string(*sb, c);
			break;
		}
		strings.write_string(*sb, sub(c, 0, i));
		c = sub_from(c, i);
		end := strings.index_byte(c, #char ">");
		if end < 0 {
			strings.write_string(*sb, c);
			break;
		}
		tag := sub(c, 1, end);
		if strings.has_prefix(tag, "@!") || strings.has_prefix(tag, "@") && !strings.has_prefix(tag, "@&") {
			id := dc.parse_snowflake(strings.trim_left(tag, "@!"));
			fmt.sbprintf(*sb, "@%s", name_in(id, m.channel_id, "unknown-user"));
		} else if strings.has_prefix(tag, "#") {
			name := "unknown";
			{ cc := dc.channel_get(s, dc.parse_snowflake(sub_from(tag, 1)));
			if cc != null { name = cc.name; } }
			fmt.sbprintf(*sb, "#%s", name);
		} else if strings.has_prefix(tag, ":") || strings.has_prefix(tag, "a:") {
			parts := strings.split(tag, ":", temp);
			if len(parts) >= 2 { fmt.sbprintf(*sb, ":%s:", parts[len(parts) - 2]); }
		} else {
			strings.write_string(*sb, sub(c, 0, end + 1));
		}
		c = sub_from(c, end + 1);
	}
	return strings.to_string(sb);
}
#scope_export

notifications_sent :: () -> int {return ns.notified;}

notify_reset_for_test :: () {ns = .{};}

