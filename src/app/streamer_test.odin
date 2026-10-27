package app

import "core:testing"
import "fc:locks"

// test_settings_roundtrip also sets streamer_settings; tests run on parallel threads
streamer_test_mu: locks.Mutex

@(test)
test_streamer_tool_detection :: proc(t: ^testing.T) {
	name, ok := streamer_tool_running({"/sbin/launchd", "/Applications/OBS.app/Contents/MacOS/OBS"}, "darwin")
	testing.expect(t, ok && name == "OBS")
	name, ok = streamer_tool_running({"/Applications/Streamlabs Desktop.app/Contents/MacOS/Streamlabs Desktop"}, "darwin")
	testing.expect(t, ok && name == "Streamlabs Desktop")
	// Windows: Toolhelp gives bare file names; full paths with backslashes work too
	name, ok = streamer_tool_running({"explorer.exe", "OBS64.EXE"}, "win32")
	testing.expect(t, ok && name == "OBS")
	name, ok = streamer_tool_running({`C:\Program Files\obs-studio\obs\obs.exe`}, "win32")
	testing.expect(t, ok && name == "OBS")
	name, ok = streamer_tool_running({"XSplit.Core.exe"}, "win32")
	testing.expect(t, ok && name == "XSplit")
	name, ok = streamer_tool_running({"TwitchStudio.exe"}, "win32")
	testing.expect(t, ok && name == "Twitch Studio")
	// no false hits: the other OS's entries, names merely containing a tool's, a bare "obs.exe"
	_, ok = streamer_tool_running({"obs64.exe"}, "darwin")
	testing.expect(t, !ok)
	_, ok = streamer_tool_running({"/Applications/NotOBS.app/Contents/MacOS/x", "/usr/bin/obs", "myobs64.exe"}, "darwin")
	testing.expect(t, !ok)
	_, ok = streamer_tool_running({"myobs64.exe", "obs.exe", "discord.exe"}, "win32")
	testing.expect(t, !ok)
	_, ok = streamer_tool_running({}, "win32")
	testing.expect(t, !ok)
}

// Options act only while Streamer Mode is on; the auto toggle follows the scan's
// changes, not its steady state (a manual enable stays until a tool starts or stops).
@(test)
test_streamer_effects_and_auto_toggle :: proc(t: ^testing.T) {
	locks.lock(&streamer_test_mu)
	defer locks.unlock(&streamer_test_mu)
	streamer_reset_for_test()
	defer streamer_reset_for_test()
	testing.expect(t, !streamer_hide_personal() && !streamer_hide_invites() && !streamer_disable_sounds() && !streamer_disable_notifications())
	testing.expect(t, !sound_disabled("message1"))
	streamer_settings.enabled = true
	testing.expect(t, streamer_hide_personal() && streamer_hide_invites() && streamer_disable_sounds() && streamer_disable_notifications())
	testing.expect(t, sound_disabled("message1"))
	streamer_settings.disable_sounds = false
	testing.expect(t, !sound_disabled("message1"))

	streamer_reset_for_test()
	streamer_frame()
	streamer_set_detected_for_test(true)
	streamer_frame()
	testing.expect(t, streamer_settings.enabled)
	streamer_settings.enabled = false // turned off by hand while OBS still runs
	streamer_frame()
	testing.expect(t, !streamer_settings.enabled)
	streamer_set_detected_for_test(false)
	streamer_frame()
	testing.expect(t, !streamer_settings.enabled)
	streamer_settings.enabled = true // a manual enable with no tool running stays
	streamer_frame()
	testing.expect(t, streamer_settings.enabled)
	streamer_settings.auto_toggle = false
	streamer_set_detected_for_test(true)
	streamer_frame()
	streamer_set_detected_for_test(false)
	streamer_frame()
	testing.expect(t, streamer_settings.enabled)
}
