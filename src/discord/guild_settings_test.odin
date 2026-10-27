package discord

import "core:testing"
import "fc:etf"

@(test)
guild_settings_mutes_and_levels :: proc(t: ^testing.T) {
	s: Store
	store_init(&s)
	defer store_destroy(&s)
	ev := `{"guild_id":"10","muted":true,"mute_config":{"selected_time_window":3600,"end_time":"2026-10-26T13:00:00.000Z"},"message_notifications":1,"suppress_everyone":true,` +
		`"channel_overrides":[{"channel_id":"11","muted":true,"mute_config":{"selected_time_window":-1,"end_time":null},"message_notifications":3},` +
		`{"channel_id":"12","muted":false,"mute_config":null,"message_notifications":2}]}`
	v, err := etf.from_json(ev, context.temp_allocator)
	testing.expect_value(t, err, etf.Error.None)
	store_apply_dispatch(&s, "USER_GUILD_SETTINGS_UPDATE", v, 0)
	end := iso_to_ms("2026-10-26T13:00:00.000Z")
	testing.expect(t, end > 0)
	testing.expect_value(t, ms_to_iso(end), "2026-10-26T13:00:00.000Z")
	testing.expect(t, guild_is_muted(&s, 10, end - 1))
	testing.expect(t, !guild_is_muted(&s, 10, end + 1)) // expired
	testing.expect(t, channel_is_muted(&s, 10, 11, end + 1)) // until turned back on
	testing.expect(t, !channel_is_muted(&s, 10, 12, 0))
	testing.expect_value(t, guild_notify_level(&s, 10), NOTIFY_MENTIONS)
	testing.expect_value(t, channel_notify_level(&s, 10, 11), NOTIFY_INHERIT)
	testing.expect_value(t, channel_notify_level(&s, 10, 12), NOTIFY_NOTHING)
	testing.expect_value(t, channel_notify_level(&s, 10, 99), NOTIFY_INHERIT)
	testing.expect_value(t, len(s.guild_settings[10].muted_channels), 1)
	// the dispatch replaces the whole object
	v2, _ := etf.from_json(`{"guild_id":"10","muted":false,"message_notifications":0,"channel_overrides":[]}`, context.temp_allocator)
	store_apply_dispatch(&s, "USER_GUILD_SETTINGS_UPDATE", v2, 0)
	testing.expect(t, !guild_is_muted(&s, 10, 0))
	testing.expect(t, !channel_is_muted(&s, 10, 11, 0))
	testing.expect_value(t, guild_notify_level(&s, 10), NOTIFY_ALL)
}
