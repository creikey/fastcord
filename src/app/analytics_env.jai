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

// voice_analytics_frame: report the voice connection's steps (voice.timeline) and
// a per-frame sample to the library's voice telemetry (dc.analytics_voice_*).
// Called at the end of voice_frame.
voice_analytics_frame :: () {
	c := app.client;
	conn := voice_conn();
	if c == null || conn == null {
		va.conn = null;
		return;
	}
	tl := voice.timeline(conn,, temp);
	if conn != va.conn {
		va = .{conn = conn};
		d: dc.Voice_Devices;
		for input: bool.[true, false] {
			list := ifx voice_headless() then .[] else audio.list_devices(input,, temp);
			name := "";
			for list if it.is_default name = it.name;
			// the official lists hold a "Default" entry before the devices
			if input { d.input, d.inputs = name, list.count + 1; } else { d.output, d.outputs = name, list.count + 1; }
		}
		#if OS == .MACOS { d.camera, d.cameras = "FaceTime HD Camera", 2; } // synthesized: no camera enumeration without the permission prompt
		dc.analytics_voice_connecting(c, conn.rtc_connection_id, conn.host, d, app.self_mute || app.self_deaf);
	}
	if tl.ws_open && !va.ws_open {
		va.ws_open = true;
		dc.analytics_audio_input_initialized(c);
	}
	if tl.ready && !va.ready {
		va.ready = true;
		dc.analytics_voice_ready(c, tl.ws_open, tl.ready, tl.udp_port);
	}
	if tl.connected && !va.connected {
		va.connected = true;
		dc.analytics_voice_connected(c, tl.select_sent, tl.connected, tl.media_session_id);
	}
	if !va.connected return;
	st := voice.get_stats(conn);
	e2ee := voice.e2ee_status(conn,, temp);
	speaking := false;
	hearing := false;
	for voice.speaking_users(conn,, temp) {
		if it == cast(u64) c.store.me speaking = true; else hearing = true;
	}
	streams: [..]dc.Voice_Stream;
	streams.allocator = temp;
	for voice.stream_stats(conn,, temp) array_add(*streams, .{user_id = it.user_id, packets = xx it.packets, lost = xx it.lost, bytes = xx it.bytes, jitter_ms = it.jitter_ms, target_frames = it.target_frames});
	dc.analytics_voice_frame(c, .{
		speaking = speaking, hearing = hearing, muted = app.self_mute, deafened = app.self_deaf,
		packets_sent = cast(s64) st.packets_sent, packets_received = cast(s64) st.packets_received, packets_lost = cast(s64) st.jitter.lost,
		bytes_sent = cast(s64) st.bytes_sent, bytes_received = cast(s64) st.bytes_received,
		ping_ms = st.ws_ping_ms, jitter_ms = st.jitter.jitter_ms, target_frames = st.jitter.target_frames,
		members = ifx e2ee.active then e2ee.members else 0, streams = streams
	});
}

#scope_file

va: struct {
	conn: *voice.Conn; // the connection reported so far
	ws_open, ready, connected: bool;
};

env: struct {
	client: *dc.Client;
	w, h: int;
	a11y: u64;
	a11y_at: float64;
};
