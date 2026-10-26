package app

import "core:testing"
import dc "fc:discord"

@(test)
test_message_notify_rules :: proc(t: ^testing.T) {
	s := store()
	s.me = 1
	G_ALL :: dc.Snowflake(10)
	G_MENTIONS :: dc.Snowflake(11)
	s.guilds[G_ALL] = dc.Guild{id = G_ALL, default_message_notifications = 0}
	s.guilds[G_MENTIONS] = dc.Guild{id = G_MENTIONS, default_message_notifications = 1}
	defer {
		delete_key(&s.guilds, G_ALL)
		delete_key(&s.guilds, G_MENTIONS)
		delete_key(&s.guild_settings, G_ALL)
	}
	m := dc.New_Message{channel_id = 100, guild_id = 0, author_id = 2}
	testing.expect(t, message_notifies(&m), "DM notifies")
	m.author_id = 1
	testing.expect(t, !message_notifies(&m), "own message never")
	m = dc.New_Message{channel_id = 100, guild_id = G_ALL, author_id = 2}
	testing.expect(t, message_notifies(&m), "guild default all")
	m.guild_id = G_MENTIONS
	testing.expect(t, !message_notifies(&m), "guild default mentions: plain message silent")
	m.mentions_me = true
	testing.expect(t, message_notifies(&m), "mention notifies")
	s.guild_settings[G_ALL] = dc.Guild_Settings{guild_id = G_ALL, message_notifications = 2}
	m = dc.New_Message{channel_id = 100, guild_id = G_ALL, author_id = 2, mentions_me = true}
	testing.expect(t, !message_notifies(&m), "user override: nothing")
	s.guild_settings[G_ALL] = dc.Guild_Settings{guild_id = G_ALL, message_notifications = 3, muted = true}
	testing.expect(t, !message_notifies(&m), "muted guild")
}
