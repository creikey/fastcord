package discord

import "core:fmt"

// UI-surface /science events of the Inbox, threads browser and back / forward
// (fixtures inbox, threads_browser, history_nav), on the analytics_events.odin
// pattern. The client spreads guild and channel metadata into an event's
// properties ({...props, ...guildMeta, ...channelMeta}): keys the event already
// has keep their place, so the callers write guild_id / channel_id themselves and
// add aw_guild / aw_channel without them.

// open_popout {type}: the Inbox popout ("Recent Mentions" / "Inbox" per tab).
track_open_popout :: proc(c: ^Client, kind: string) {
	w := aw_begin()
	json_kstr(&w, "type", kind)
	aw_track(c, "open_popout", &w)
}

// inbox_channel_acked: the check on an Inbox unread channel card.
track_inbox_channel_acked :: proc(c: ^Client, channel_id: Snowflake, marked_all := false) {
	s := &c.store
	ch := channel_get(s, channel_id)
	if ch == nil do return
	w := aw_begin()
	json_ksnow(&w, "channel_id", channel_id)
	if ch.guild_id != 0 do json_ksnow(&w, "guild_id", ch.guild_id)
	json_kbool(&w, "marked_all_channels_as_read", marked_all)
	json_kint(&w, "num_unread_channels_remaining", -1)
	if ch.guild_id != 0 do aw_guild(&w, c, ch.guild_id, false)
	aw_channel(&w, c, channel_id, false)
	aw_track(c, "inbox_channel_acked", &w)
}

// notification_action ACK: a shown desktop notification cleared by an ack.
track_notification_ack :: proc(c: ^Client, author_id, message_id: Snowflake, message_type: int, channel_id: Snowflake, badge, banner: bool) {
	s := &c.store
	ch := channel_get(s, channel_id)
	if ch == nil do return
	w := aw_begin()
	json_kstr(&w, "action", "ACK")
	json_kstr(&w, "notif_type", "MESSAGE_CREATE")
	json_ksnow(&w, "notif_user_id", author_id)
	json_ksnow(&w, "message_id", message_id)
	json_kint(&w, "message_type", i64(message_type))
	json_ksnow(&w, "channel_id", channel_id)
	json_kint(&w, "channel_type", i64(ch.kind))
	if ch.guild_id != 0 do json_ksnow(&w, "guild_id", ch.guild_id)
	json_kbool(&w, "badge", badge)
	json_kbool(&w, "banner", banner)
	aw_track(c, "notification_action", &w)
}

// jump {context, channel_id, message_id, guild_id, ...}: "Jump to Message".
track_jump :: proc(c: ^Client, ctx: string, channel_id, message_id: Snowflake) {
	s := &c.store
	ch := channel_get(s, channel_id)
	if ch == nil do return
	w := aw_begin()
	json_kstr(&w, "context", ctx)
	json_ksnow(&w, "channel_id", channel_id)
	json_ksnow(&w, "message_id", message_id)
	if ch.guild_id != 0 {
		json_ksnow(&w, "guild_id", ch.guild_id)
		aw_guild(&w, c, ch.guild_id, false)
	}
	aw_channel(&w, c, channel_id, false)
	aw_track(c, "jump", &w)
}

// The thread browser opening: open_modal, then thread_browser_tab_changed
// twice (its tab state initialises and then settles on Active).
track_thread_browser_open :: proc(c: ^Client, channel_id: Snowflake) {
	s := &c.store
	ch := channel_get(s, channel_id)
	if ch == nil || ch.guild_id == 0 do return
	{
		w: Json
		json_init(&w)
		json_obj(&w)
		json_kstr(&w, "type", "Thread Browser")
		json_kstr(&w, "location_section", "Popout")
		json_ksnow(&w, "guild_id", ch.guild_id)
		aw_guild(&w, c, ch.guild_id, false)
		json_ksnow(&w, "channel_id", channel_id)
		aw_channel(&w, c, channel_id, false)
		aw_track(c, "open_modal", &w)
	}
	for _ in 0 ..< 2 do track_thread_browser_tab_changed(c, channel_id)
}

// thread_browser_tab_changed {guild meta, channel meta}.
track_thread_browser_tab_changed :: proc(c: ^Client, channel_id: Snowflake) {
	s := &c.store
	ch := channel_get(s, channel_id)
	if ch == nil || ch.guild_id == 0 do return
	w := aw_begin()
	json_ksnow(&w, "guild_id", ch.guild_id)
	aw_guild(&w, c, ch.guild_id, false)
	json_ksnow(&w, "channel_id", channel_id)
	aw_channel(&w, c, channel_id, false)
	aw_track(c, "thread_browser_tab_changed", &w)
}

// thread_creation_started: "Create" in the thread browser.
track_thread_creation_started :: proc(c: ^Client, channel_id: Snowflake, location: string) {
	s := &c.store
	ch := channel_get(s, channel_id)
	if ch == nil || ch.guild_id == 0 do return
	w := aw_begin()
	json_ksnow(&w, "channel_id", channel_id)
	json_ksnow(&w, "guild_id", ch.guild_id)
	aw_guild(&w, c, ch.guild_id, false)
	aw_channel(&w, c, channel_id, false)
	json_kstr(&w, "location", location)
	aw_track(c, "thread_creation_started", &w)
}

// Back / forward: keyboard_shortcut_used (keybind only), then app_back_forward_navigated.
track_back_forward :: proc(c: ^Client, forward, keybind: bool) {
	if keybind do analytics_keyboard_shortcut(c, "NAVIGATE_FORWARD" if forward else "NAVIGATE_BACK", "mod+]" if forward else "mod+[")
	w := aw_begin()
	json_kint(&w, "nav_direction", 1 if forward else -1)
	json_kstr(&w, "nav_trigger", "keybind" if keybind else "nav_button")
	aw_track(c, "app_back_forward_navigated", &w)
}
