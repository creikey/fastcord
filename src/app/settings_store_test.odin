package app

import "core:os"
import "core:strings"
import "core:testing"
import dc "fc:discord"
import "fc:platform"

@(test)
test_settings_roundtrip :: proc(t: ^testing.T) {
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
	settings_save()

	vs_reset_for_test()
	clear(&app.view.collapsed)
	clear(&app.view.last_channel)
	app_theme_pending = nil
	settings_load_from(dir)
	testing.expect(t, vs.input_volume == 55 && vs.output_volume == 150 && !vs.auto_sens && vs.threshold_db == -42)
	testing.expect(t, vs.ptt_mode && vs.ptt_key == .V && vs.ptt_delay_ms == 120)
	testing.expect(t, vs.user_volume[dc.Snowflake(1090123456789012345)] == 170 && vs.user_muted[dc.Snowflake(42)])
	testing.expect(t, app.view.collapsed[dc.Snowflake(777)] && app.view.last_channel[dc.Snowflake(1)] == dc.Snowflake(2))
	th, ok := app_theme_pending.?
	testing.expect(t, ok && th == .Ash)
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
