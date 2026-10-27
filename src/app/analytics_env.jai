// What the analytics tracker decorates every event with, reported to the
// library: the window content size in CSS px (points: Chrome's innerWidth /
// innerHeight at zoom 100%) and the AccessibilityFeatureFlags. The library
// drops every event until both are known (dc.analytics_track), so this runs
// right after the client is created and then every frame (the size at once,
// the OS settings twice a second).

analytics_env_sync :: (force := false) {
	analytics_env_report(platform.window_size(), force);
}

// analytics_env_report: the same with the window size given (points).
analytics_env_report :: (sz: Vector2, force_in := false) {
	c := app.client;
	if c == null return;
	force := force_in;
	if c != env.client {
		env = .{client = c};
		force = true;
	}
	w, h := cast(int) sz.x, cast(int) sz.y;
	if force || w != env.w || h != env.h {
		env.w, env.h = w, h;
		dc.client_set_viewport(c, w, h);
	}
	now := platform.time_now();
	if force || now - env.a11y_at >= 0.5 {
		env.a11y_at = now;
		dark, known := platform.system_dark_mode();
		sys := platform.system_a11y();
		f := dc.accessibility_flags(.{os_dark = dark && known, reduce_motion = sys.reduce_motion, contrast_more = sys.contrast_more, invert_colors = sys.invert_colors, forced_colors = sys.forced_colors});
		if force || f != env.a11y {
			env.a11y = f;
			dc.client_set_accessibility(c, f);
		}
	}
}

#scope_file

env: struct {
	client: *dc.Client;
	w, h: int;
	a11y: u64;
	a11y_at: float64;
};
