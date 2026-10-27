package app

import "core:testing"
import dc "fc:discord"

// The real app reports the viewport and accessibility flags itself: without
// them the library drops every /science event (the replay tests set them on
// their own, so this guards the app's side).
@(test)
test_analytics_env_lets_events_through :: proc(t: ^testing.T) {
	c := dc.client_create({token = "<token>", disable_startup = true})
	defer dc.client_destroy(c)
	dc.analytics_track(c, "test_event", "")
	testing.expect_value(t, dc.analytics_queued(c), 0) // nothing known yet: dropped
	saved := app.client
	app.client = c
	analytics_env_report({1280, 720}, force = true) // what connect() does right after client_create (window size in points)
	app.client = saved
	dc.analytics_track(c, "test_event", "")
	testing.expect_value(t, dc.analytics_queued(c), 1)
	testing.expect_value(t, dc.accessibility_flags({}), u64(524416)) // light OS, store defaults (fixtures)
}
