package app

import "core:fmt"
import "core:strings"
import dc "fc:discord"
import "fc:platform"

// Desktop notifications, following the client's NotificationStore
// (MESSAGE_CREATE handler + shouldNotify): the shared per-frame message list
// (app_new_messages) filtered by message_notifies (DMs always; guild/channel
// mute, message_notifications with the guild default; mentions incl. roles and
// @everyone), never for SUPPRESS_NOTIFICATIONS messages, blocked authors, Do
// Not Disturb, or the channel being viewed in a focused window. The
// "message1" sound is played by sounds.odin for the same messages. Titles:
// "Author (#channel, Parent)" / "Author (Group)" / "Author". The dock badge
// shows the total unread mention count.

SUPPRESS_NOTIFICATIONS :: u64(1) << 12

@(private = "file")
Notify_State :: struct {
	badge:     int,
	badge_set: bool,
	notified:  int,
}

@(private = "file")
ns: Notify_State

notify_tick :: proc() {
	if app.client == nil do return
	s := store()
	for &m in app_new_messages() {
		if m.flags & SUPPRESS_NOTIFICATIONS != 0 do continue
		if app.focused && m.channel_id == app.view.channel do continue
		if s.settings.status == .Dnd do continue
		if r, ok := s.relationships[m.author_id]; ok && r.kind == .Blocked do continue
		if !message_notifies(&m) do continue
		notify_message(s, &m)
	}
	// dock badge: unread mentions
	total := 0
	for _, rs in s.read_states do total += max(rs.mention_count, 0)
	if !ns.badge_set || total != ns.badge {
		ns.badge = total
		ns.badge_set = true
		platform.set_badge(total > 0 ? fmt.tprintf("%d", total) : "")
	}
}

@(private = "file")
notify_message :: proc(s: ^dc.Store, m: ^dc.New_Message) {
	ch := dc.channel_get(s, m.channel_id)
	author := "Unknown"
	if u := dc.user_get(s, m.author_id); u != nil do author = dc.display_name(u)
	title := author
	#partial switch ch.kind {
	case .DM:
	case .Group_DM:
		title = fmt.tprintf("%s (%s)", author, dm_name(ch))
	case:
		parent := ""
		if ch.parent_id != 0 {
			if p := dc.channel_get(s, ch.parent_id); p != nil do parent = p.name
		}
		title = parent != "" ? fmt.tprintf("%s (#%s, %s)", author, ch.name, parent) : fmt.tprintf("%s (#%s)", author, ch.name)
	}
	body := notification_body(s, m)
	platform.notify_show(title, body, fmt.tprintf("%v", u64(m.id)))
	ns.notified += 1
}

// Content as plain text with <@id>/<#id> resolved, or a stand-in for media-only messages.
@(private = "file")
notification_body :: proc(s: ^dc.Store, m: ^dc.New_Message) -> string {
	if m.content == "" {
		if m.sticker do return "Sent a sticker"
		if m.attachments > 0 do return "Uploaded a file"
		return ""
	}
	sb := strings.builder_make(context.temp_allocator)
	c := m.content
	for len(c) > 0 {
		i := strings.index_byte(c, '<')
		if i < 0 {
			strings.write_string(&sb, c)
			break
		}
		strings.write_string(&sb, c[:i])
		c = c[i:]
		end := strings.index_byte(c, '>')
		if end < 0 {
			strings.write_string(&sb, c)
			break
		}
		tag := c[1:end]
		switch {
		case strings.has_prefix(tag, "@!") || strings.has_prefix(tag, "@") && !strings.has_prefix(tag, "@&"):
			id := dc.parse_snowflake(strings.trim_left(tag, "@!"))
			name := "unknown-user"
			if u := dc.user_get(s, id); u != nil do name = dc.display_name(u)
			fmt.sbprintf(&sb, "@%s", name)
		case strings.has_prefix(tag, "#"):
			name := "unknown"
			if cc := dc.channel_get(s, dc.parse_snowflake(tag[1:])); cc != nil do name = cc.name
			fmt.sbprintf(&sb, "#%s", name)
		case strings.has_prefix(tag, ":") || strings.has_prefix(tag, "a:"):
			parts := strings.split(tag, ":", context.temp_allocator)
			if len(parts) >= 2 do fmt.sbprintf(&sb, ":%s:", parts[len(parts) - 2])
		case:
			strings.write_string(&sb, c[:end + 1])
		}
		c = c[end + 1:]
	}
	return strings.to_string(sb)
}

notifications_sent :: proc() -> int {return ns.notified}

notify_reset_for_test :: proc() {ns = {}}
