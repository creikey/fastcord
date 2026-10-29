// UI-surface /science events of the Inbox, threads browser and back / forward
// (fixtures inbox, threads_browser, history_nav), on the analytics_events.jai
// pattern. The client spreads guild and channel metadata into an event's
// properties ({...props, ...guildMeta, ...channelMeta}): keys the event already
// has keep their place, so the callers write guild_id / channel_id themselves and
// add aw_guild / aw_channel without them.

// open_popout {type}: the Inbox popout ("Recent Mentions" / "Inbox" per tab).
track_open_popout :: (c: *Client, kind: string) {
	w := aw_begin();
	json_kstr(*w, "type", kind);
	aw_track(c, "open_popout", *w);
}

// inbox_channel_acked: the check on an Inbox unread channel card.
track_inbox_channel_acked :: (c: *Client, channel_id: Snowflake, marked_all := false) {
	s := *c.store;
	ch := channel_get(s, channel_id);
	if !ch return;
	w := aw_begin();
	json_ksnow(*w, "channel_id", channel_id);
	if ch.guild_id != 0 json_ksnow(*w, "guild_id", ch.guild_id);
	json_kbool(*w, "marked_all_channels_as_read", marked_all);
	json_kint(*w, "num_unread_channels_remaining", -1);
	if ch.guild_id != 0 aw_guild(*w, c, ch.guild_id, false);
	aw_channel(*w, c, channel_id, false);
	aw_track(c, "inbox_channel_acked", *w);
}

// notification_action ACK: a shown desktop notification cleared by an ack.
track_notification_ack :: (c: *Client, author_id: Snowflake, message_id: Snowflake, message_type: int, channel_id: Snowflake, badge: bool, banner: bool) {
	s := *c.store;
	ch := channel_get(s, channel_id);
	if !ch return;
	w := aw_begin();
	json_kstr(*w, "action", "ACK");
	json_kstr(*w, "notif_type", "MESSAGE_CREATE");
	json_ksnow(*w, "notif_user_id", author_id);
	json_ksnow(*w, "message_id", message_id);
	json_kint(*w, "message_type", message_type);
	json_ksnow(*w, "channel_id", channel_id);
	json_kint(*w, "channel_type", xx ch.kind);
	if ch.guild_id != 0 json_ksnow(*w, "guild_id", ch.guild_id);
	json_kbool(*w, "badge", badge);
	json_kbool(*w, "banner", banner);
	aw_track(c, "notification_action", *w);
}

// jump {context, channel_id, message_id, guild_id, ...}: "Jump to Message".
track_jump :: (c: *Client, ctx: string, channel_id: Snowflake, message_id: Snowflake) {
	s := *c.store;
	ch := channel_get(s, channel_id);
	if !ch return;
	w := aw_begin();
	json_kstr(*w, "context", ctx);
	json_ksnow(*w, "channel_id", channel_id);
	json_ksnow(*w, "message_id", message_id);
	if ch.guild_id != 0 {
		json_ksnow(*w, "guild_id", ch.guild_id);
		aw_guild(*w, c, ch.guild_id, false);
	}
	aw_channel(*w, c, channel_id, false);
	aw_track(c, "jump", *w);
}

// The thread browser opening: open_modal, then thread_browser_tab_changed
// twice (its tab state initialises and then settles on Active).
track_thread_browser_open :: (c: *Client, channel_id: Snowflake) {
	s := *c.store;
	ch := channel_get(s, channel_id);
	if !ch || ch.guild_id == 0 return;
	w := aw_begin();
	json_kstr(*w, "type", "Thread Browser");
	json_kstr(*w, "location_section", "Popout");
	json_ksnow(*w, "guild_id", ch.guild_id);
	aw_guild(*w, c, ch.guild_id, false);
	json_ksnow(*w, "channel_id", channel_id);
	aw_channel(*w, c, channel_id, false);
	aw_track(c, "open_modal", *w);
	for 1..2 track_thread_browser_tab_changed(c, channel_id);
}

// thread_browser_tab_changed {guild meta, channel meta}.
track_thread_browser_tab_changed :: (c: *Client, channel_id: Snowflake) {
	s := *c.store;
	ch := channel_get(s, channel_id);
	if !ch || ch.guild_id == 0 return;
	w := aw_begin();
	json_ksnow(*w, "guild_id", ch.guild_id);
	aw_guild(*w, c, ch.guild_id, false);
	json_ksnow(*w, "channel_id", channel_id);
	aw_channel(*w, c, channel_id, false);
	aw_track(c, "thread_browser_tab_changed", *w);
}

// thread_creation_started: "Create" in the thread browser.
track_thread_creation_started :: (c: *Client, channel_id: Snowflake, location: string) {
	s := *c.store;
	ch := channel_get(s, channel_id);
	if !ch || ch.guild_id == 0 return;
	w := aw_begin();
	json_ksnow(*w, "channel_id", channel_id);
	json_ksnow(*w, "guild_id", ch.guild_id);
	aw_guild(*w, c, ch.guild_id, false);
	aw_channel(*w, c, channel_id, false);
	json_kstr(*w, "location", location);
	aw_track(c, "thread_creation_started", *w);
	// the form opens in the channel's resizable side panel (0.0.420: fixture threads_browser)
	analytics_exposed(c, "ChannelChatResizableSidebar", "2026-09-friends-sidebar");
}

// Back / forward: keyboard_shortcut_used (keybind only), then app_back_forward_navigated.
track_back_forward :: (c: *Client, forward: bool, keybind: bool) {
	if keybind analytics_keyboard_shortcut(c, ifx forward then "NAVIGATE_FORWARD" else "NAVIGATE_BACK", ifx forward then "mod+]" else "mod+[");
	w := aw_begin();
	json_kint(*w, "nav_direction", ifx forward then 1 else -1);
	json_kstr(*w, "nav_trigger", ifx keybind then "keybind" else "nav_button");
	aw_track(c, "app_back_forward_navigated", *w);
}

// Dragging the channel sidebar's edge, on release: the whole sidebar's width (guild rail included).
track_channel_sidebar_resized :: (c: *Client, width: int) {
	w := aw_begin();
	json_kint(*w, "width", width);
	aw_track(c, "channel_sidebar_resized", *w);
}

