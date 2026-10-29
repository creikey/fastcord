// Streamer Mode, after the client's StreamerModeStore (persisted locally, never
// synced): each option only acts while Streamer Mode is enabled. A background
// thread scans the process list every few seconds for the streaming tools in
// RunningGameStore's list (streamerTool: true); with "Automatically
// Enable/Disable" on, a change in whether one runs turns Streamer Mode on or off
// (RUNNING_STREAMER_TOOLS_CHANGE). Analytics as the client's: streamer_mode_toggle
// {enabled, automatic} when enabled changes, update_streamer_mode_settings for any
// other option, and the STREAMER_MODE notice's app_notice_* events.
//
// Hooks for other views: streamer_hide_personal (email, phone, connections, notes),
// streamer_hide_invites (invite links/codes).

Streamer_Settings :: struct {
	enabled: bool;
	auto_toggle: bool;
	hide_personal_information: bool;
	hide_instant_invites: bool;
	disable_sounds: bool;
	disable_notifications: bool;
	content_protection: bool; // "Hide Discord Window from Screen Capture"
}

STREAMER_DEFAULTS :: Streamer_Settings.{
	auto_toggle = true,
	hide_personal_information = true,
	hide_instant_invites = true,
	disable_sounds = true,
	disable_notifications = true
};

streamer_settings := STREAMER_DEFAULTS;

streamer_hide_personal :: () -> bool { return streamer_settings.enabled && streamer_settings.hide_personal_information; }
streamer_hide_invites :: () -> bool { return streamer_settings.enabled && streamer_settings.hide_instant_invites; }
streamer_disable_sounds :: () -> bool { return streamer_settings.enabled && streamer_settings.disable_sounds; }
streamer_disable_notifications :: () -> bool { return streamer_settings.enabled && streamer_settings.disable_notifications; }

streamer_reset_for_test :: () {
	streamer_settings = STREAMER_DEFAULTS;
	sm = .{};
}

streamer_set_detected_for_test :: (on: bool) { atomic_store(*sm.detected, on); }

// ---- detection ----

Streamer_Tool :: struct {
	target: string; // "win32" | "darwin"
	exe: string; // lower case: "/<tail of the path>" (win32) or "/<bundle>.app/" (darwin)
	name: string;
}

// RunningGameStore's built-in streamerTool entries.
STREAMER_TOOLS :: Streamer_Tool.[
	.{"win32", "/obs/obs.exe", "OBS"},
	.{"win32", "/obs32.exe", "OBS"},
	.{"win32", "/obs64.exe", "OBS"},
	.{"darwin", "/obs.app/", "OBS"},
	.{"win32", "/xsplit.gamecaster.exe", "XSplit"},
	.{"win32", "/xsplit.core.exe", "XSplit"},
	.{"win32", "/gamecaster.exe", "XSplit"},
	.{"win32", "/bebo.exe", "Bebo"},
	.{"win32", "/streamlabs obs.exe", "Streamlabs Desktop"},
	.{"win32", "/streamlabs desktop.exe", "Streamlabs Desktop"},
	.{"darwin", "/streamlabs desktop.app/", "Streamlabs Desktop"},
	.{"win32", "/twitchstudio.exe", "Twitch Studio"},
	.{"darwin", "/twitch studio.app/", "Twitch Studio"}
];

// Node's process.platform; the table has no "linux" entries, so Linux detects nothing
STREAMER_OS :: #run ifx OS == .MACOS then "darwin" else ifx OS == .LINUX then "linux" else "win32";

// streamer_tool_running: the first streaming tool among executable paths (or bare
// file names), case-insensitive.
streamer_tool_running :: (paths: []string, target := STREAMER_OS) -> string, bool {
	for p: paths {
		lp := tprint("/%", replace(to_lower_copy(p,, temp), "\\", "/",, temp));
		for t: STREAMER_TOOLS {
			if t.target != target continue;
			if ifx ends_with(t.exe, "/") then contains(lp, t.exe) else ends_with(lp, t.exe) return t.name, true;
		}
	}
	return "", false;
}

// streamer_start: the process scan thread (never in headless runs).
streamer_start :: () {
	if platform.is_headless() { return; }
	atomic_store(*sm.scan, streamer_settings.auto_toggle);
	dc.spawn(0, (_: int) {
		while true {
			if atomic_load(*sm.scan) {
				_, on := streamer_tool_running(dc.process_exe_paths(,, temp));
				if on != atomic_load(*sm.detected) {
					atomic_store(*sm.detected, on);
					platform.request_frame();
				}
				reset_temporary_storage();
			}
			sleep_milliseconds(5000);
		}
	});
}

// streamer_frame: auto toggle, analytics on changes, screen-capture protection.
streamer_frame :: () {
	s := *streamer_settings;
	if !sm.started {
		sm.started = true;
		sm.last = s.*;
	}
	atomic_store(*sm.scan, s.auto_toggle);
	d := atomic_load(*sm.detected);
	if d != sm.seen {
		sm.seen = d;
		if s.auto_toggle {
			s.enabled = d;
			sm.last.enabled = d;
			track_toggle(d, true);
		}
	}
	if memcmp(s, *sm.last, size_of(Streamer_Settings)) != 0 { // all bools: no padding
		if s.enabled != sm.last.enabled {
			track_toggle(s.enabled, false);
		} else if app.client != null {
			dc.analytics_streamer_settings_updated(app.client, streamer_analytics(s.*), streamer_analytics(sm.last));
		}
		sm.last = s.*;
	}
	hide := s.enabled && s.content_protection;
	if hide != sm.capture_hidden {
		sm.capture_hidden = hide;
		platform.set_capture_hidden(hide);
	}
	if !s.enabled sm.notice_closed, sm.notice_viewed = false, false;
}

// ---- UI ----

// The STREAMER_MODE notice bar under the title bar: text, "Disable", close.
streamer_notice :: () {
	if !streamer_settings.enabled || sm.notice_closed { return; }
	// the notice re-mounts (and is viewed again) when the route's guild changes
	if !sm.notice_viewed || sm.notice_guild != app.view.guild {
		sm.notice_viewed = true;
		sm.notice_guild = app.view.guild;
		if app.client != null { dc.analytics_app_notice(app.client, "app_notice_viewed", "STREAMER_MODE", app.view.guild); }
	}
	WHITE :: ui.Color.{1, 1, 1, 1};
	bar := row("streamer_notice", .Draw_Background);
	bar.semantic_size = .[ui.pct(1), ui.px(36)];
	bar.style.bg = .{0x59 / 255.0, 0x36 / 255.0, 0x95 / 255.0, 1}; // notice color STREAMER_MODE
	{ ui.parent(bar); defer ui.pop_parent();
		spacer(.X, 36);
		filler(.X);
		label(L("Streamer Mode is enabled. Usernames have been truncated."), .Medium, 14, WHITE, 18);
		spacer(.X, 10);
		b := row("disable", .Clickable | .Draw_Border | .Draw_Background | .Hot_Animation);
		b.semantic_size = .[ui.children(), ui.px(24)];
		b.style.border = 1;
		b.style.border_color = WHITE;
		b.style.radius = all4(4);
		b.style.bg_hot = with_alpha(WHITE, 0.1);
		{ ui.parent(b); defer ui.pop_parent();
			spacer(.X, 10);
			label(L("Disable"), .Medium, 14, WHITE, 18);
			spacer(.X, 10);
		}
		if ui.signal(b).clicked {
			track_notice("app_notice_primary_cta_opened");
			streamer_settings.enabled = false;
		}
		filler(.X);
		x := ui.box("close", .Clickable);
		x.semantic_size = .[ui.px(16), ui.px(16)];
		xs := ui.signal(x);
		set_icon(x, "x-large", with_alpha(WHITE, ifx xs.hovering then 1.0 else 0.8));
		if xs.clicked {
			sm.notice_closed = true;
			track_notice("app_notice_closed");
		}
		spacer(.X, 20);
	}
}

// A bar under the title bar while the open connection's gateway is down after its first READY (after a
// 3 s grace, so a quick resume shows nothing): the app is stale until it reconnects. Waiting out a
// backoff, "Reconnect" tries at once.
connection_notice :: () {
	s := store();
	now := platform.time_now();
	if s.connection == .Ready || s.connection == .Auth_Failed || s.me == 0 {
		sm.conn_lost_at = 0;
		return;
	}
	if sm.conn_lost_at == 0 sm.conn_lost_at = now;
	if now - sm.conn_lost_at < 3 && !platform.is_headless() { request_wake(sm.conn_lost_at + 3); return; }
	WHITE :: ui.Color.{1, 1, 1, 1};
	bar := row("conn_notice", .Draw_Background);
	bar.semantic_size = .[ui.pct(1), ui.px(36)];
	bar.style.bg = T("--status-warning");
	{ ui.parent(bar); defer ui.pop_parent();
		filler(.X);
		closed := s.connection == .Disconnected;
		label(ifx closed then L("Connection lost. Messages may be out of date.") else L("Connecting..."), .Medium, 14, WHITE, 18);
		if closed {
			spacer(.X, 10);
			b := row("reconnect", .Clickable | .Draw_Border | .Draw_Background | .Hot_Animation);
			b.semantic_size = .[ui.children(), ui.px(24)];
			b.style.border = 1;
			b.style.border_color = WHITE;
			b.style.radius = all4(4);
			b.style.bg_hot = with_alpha(WHITE, 0.1);
			{ ui.parent(b); defer ui.pop_parent();
				spacer(.X, 10);
				label(L("Reconnect"), .Medium, 14, WHITE, 18);
				spacer(.X, 10);
			}
			if ui.signal(b).clicked && app.client dc.gateway_reconnect_now(app.client);
		}
		filler(.X);
	}
}

// Settings > Appearance > Streamer Mode (a section of Appearance in 0.0.419).
streamer_settings_section :: () {
	s := *streamer_settings;
	row_toggle :: (id: string, text: string, help: string, v: *bool) -> bool {
		if set_toggle_row(id, text, help, v.*) {
			v.* = !v.*;
			return true;
		}
		return false;
	}
	if row_toggle("sm_enable", L("Enable Streamer Mode"), L("Streamer Mode hides your personal info so others watching your stream can't see it."), *s.enabled) && app.client != null {
		dc.analytics_ui_setting(app.client, "streaming_enable_streamer_mode");
	}
	spacer(.Y, 24);
	row_toggle("sm_auto", L("Automatically enable Streamer Mode if OBS or XSplit are running"), "", *s.auto_toggle);
	spacer(.Y, 32);
	label(L("If Streamer Mode is enabled..."), .Semibold, 16, T("--text-strong"), 20);
	spacer(.Y, 24);
	row_toggle("sm_personal", L("Hide my personal information, such as email, connected accounts, and notes"), "", *s.hide_personal_information);
	spacer(.Y, 24);
	row_toggle("sm_invites", L("Hide invite links to my Discord servers"), "", *s.hide_instant_invites);
	spacer(.Y, 24);
	row_toggle("sm_sounds", L("Disable all sound effects"), "", *s.disable_sounds);
	spacer(.Y, 24);
	row_toggle("sm_notifs", L("Disable all notifications"), "", *s.disable_notifications);
	spacer(.Y, 24);
	row_toggle("sm_capture", L("Hide Fastcord window from screen capture"), L("Hides Fastcord windows from most screen capture software."), *s.content_protection);
}

// Settings > Account while Streamer Mode is on: the page is replaced (email,
// phone and the rest are not shown at all) and nothing is fetched.
streamer_account_page :: () {
	page := ui.box("streameraccount");
	page.semantic_size = .[ui.pct(1), ui.fill()];
	page.layout_axis = .Y;
	page.cross_align = .Center;
	{ ui.parent(page); defer ui.pop_parent();
		filler(.Y);
		icon("art", "screen-stream", 160, T("--background-brand"));
		spacer(.Y, 24);
		b := row(L("Streamer Mode Enabled##smbadge"), .Draw_Background | .Draw_Text);
		b.semantic_size = .[ui.px(244), ui.px(48)];
		b.style.radius = all4(8);
		b.style.bg = T("--background-brand");
		b.style.font = F(.Medium);
		b.style.font_size = 18;
		b.style.text_align = .Center;
		b.style.text_color = .{1, 1, 1, 1};
		filler(.Y);
	}
}

#scope_file

sm: struct {
	detected: bool; // a streaming tool runs (written by the scan thread, atomic)
	scan: bool; // auto_toggle, for the scan thread (atomic)
	seen: bool; // last `detected` acted on
	last: Streamer_Settings; // settings as of the last frame (change tracking)
	started: bool;
	capture_hidden: bool;
	notice_closed: bool;
	notice_viewed: bool;
	notice_guild: dc.Snowflake; // the route's guild when app_notice_viewed was sent
	conn_lost_at: float64; // when the open connection left READY (0: it is up; connection_notice)
};

streamer_analytics :: (x: Streamer_Settings) -> dc.Streamer_Mode_Analytics {
	return .{x.enabled, x.auto_toggle, x.disable_notifications, x.disable_sounds, x.hide_instant_invites, x.hide_personal_information, x.content_protection};
}

track_toggle :: (on: bool, automatic: bool) {
	if app.client != null dc.analytics_streamer_mode_toggle(app.client, on, automatic);
}

track_notice :: (event: string) {
	if app.client != null dc.analytics_app_notice(app.client, event, "STREAMER_MODE");
}

