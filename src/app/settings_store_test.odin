package app

import "core:os"
import "core:strings"
import "core:testing"
import dc "fc:discord"
import "fc:locks"
import "fc:platform"

@(test)
test_settings_roundtrip :: proc(t: ^testing.T) {
	locks.lock(&streamer_test_mu)
	defer locks.unlock(&streamer_test_mu)
	dir := strings.concatenate({os.get_env("TMPDIR", context.temp_allocator), "/fastcord-settings-test"}, context.temp_allocator)
	os.make_directory(dir)
	defer os.remove(strings.concatenate({dir, "/", SETTINGS_FILE}, context.temp_allocator))
	settings_load_from(dir) // sets the directory (file may not exist)
	app.theme.name = .Ash
	vs_reset_for_test()
	vs.input_volume = 55
	vs.output_volume = 150
	vs.auto_sens = false
	vs.threshold_db = -42
	vs.ptt_mode = true
	vs.ptt_key = platform.Key.V
	vs.ptt_delay_ms = 120
	vs.user_volume[dc.Snowflake(1090123456789012345)] = 170
	vs.user_muted[dc.Snowflake(42)] = true
	app.view.collapsed[dc.Snowflake(777)] = true
	app.view.last_channel[dc.Snowflake(1)] = dc.Snowflake(2)
	streamer_settings = {enabled = true, hide_instant_invites = true, content_protection = true}
	settings_save()

	vs_reset_for_test()
	clear(&app.view.collapsed)
	clear(&app.view.last_channel)
	app_theme_pending = nil
	streamer_reset_for_test()
	settings_load_from(dir)
	testing.expect_value(t, streamer_settings, Streamer_Settings{enabled = true, hide_instant_invites = true, content_protection = true})
	streamer_reset_for_test()
	defer {
		// a file from before Streamer Mode keeps the client's defaults (auto toggle and every option on)
		_ = os.write_entire_file(strings.concatenate({dir, "/", SETTINGS_FILE}, context.temp_allocator), transmute([]byte)string(`{"version":1}`))
		streamer_settings = {}
		settings_load_from(dir)
		testing.expect_value(t, streamer_settings, STREAMER_DEFAULTS)
		streamer_reset_for_test()
	}
	testing.expect(t, vs.input_volume == 55 && vs.output_volume == 150 && !vs.auto_sens && vs.threshold_db == -42)
	testing.expect(t, vs.ptt_mode && vs.ptt_key == .V && vs.ptt_delay_ms == 120)
	testing.expect(t, vs.user_volume[dc.Snowflake(1090123456789012345)] == 170 && vs.user_muted[dc.Snowflake(42)])
	testing.expect(t, app.view.collapsed[dc.Snowflake(777)] && app.view.last_channel[dc.Snowflake(1)] == dc.Snowflake(2))
	th, ok := app_theme_pending.?
	testing.expect(t, ok && th == .Ash)
	settings_notify_prefs_roundtrip(t)
}

// settings-proto AppearanceSettings.theme: DARK=1 is the refresh's "Ash",
// DARKER=3 its "Dark" (account A runs Dark and must not come up as Ash).
@(test)
test_theme_proto_mapping :: proc(t: ^testing.T) {
	th, ok := theme_from_proto(.Darker)
	testing.expect(t, ok && th == .Dark)
	th, ok = theme_from_proto(.Dark)
	testing.expect(t, ok && th == .Ash)
	th, ok = theme_from_proto(.Midnight)
	testing.expect(t, ok && th == .Onyx)
	for n in Theme_Name {
		back, bok := theme_from_proto(theme_to_proto(n))
		testing.expect(t, bok && back == n)
	}
}

// Notifications, sounds and "Same as Device Theme" persist; a file without them reads as the
// client's defaults (notifications and the badge on). Run from test_settings_roundtrip: both
// use the store's directory, which is global.
settings_notify_prefs_roundtrip :: proc(t: ^testing.T) {
	dir := strings.concatenate({os.get_env("TMPDIR", context.temp_allocator), "/fastcord-settings-test-notify"}, context.temp_allocator)
	os.make_directory(dir)
	path := strings.concatenate({dir, "/", SETTINGS_FILE}, context.temp_allocator)
	defer os.remove(path)
	settings_load_from(dir)
	notify_prefs = {desktop_off = true, badge_off = true}
	theme_follow_os = true
	sounds_reset_prefs_for_test()
	sounds_set_all_disabled(true)
	sound_set_disabled("mute", true)
	settings_save()

	notify_prefs, theme_follow_os = {}, false
	sounds_reset_prefs_for_test()
	settings_load_from(dir)
	testing.expect(t, notify_prefs.desktop_off && notify_prefs.badge_off && theme_follow_os)
	testing.expect(t, sounds_all_disabled() && sound_own_disabled("mute") && !sound_own_disabled("deafen"))
	sound_set_disabled("mute", false)
	testing.expect(t, !sound_own_disabled("mute"))

	_ = os.write_entire_file(path, transmute([]byte)string(`{"version": 1, "theme": "Dark"}`))
	settings_load_from(dir)
	testing.expect(t, !notify_prefs.desktop_off && !notify_prefs.badge_off && !theme_follow_os)
	sounds_reset_prefs_for_test()
	notify_prefs, theme_follow_os = {}, false
}

@(test)
test_account_masks :: proc(t: ^testing.T) {
	testing.expect_value(t, mask_email("someone@gmail.com"), "*****@gmail.com")
	testing.expect_value(t, mask_email("<email>"), "*****")
	testing.expect_value(t, mask_phone("+15551234567"), "********4567")
}
