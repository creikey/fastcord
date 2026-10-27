package app

import "core:fmt"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import dc "fc:discord"
import "fc:platform"
import "fc:ui"

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
	enabled:                   bool,
	auto_toggle:               bool,
	hide_personal_information: bool,
	hide_instant_invites:      bool,
	disable_sounds:            bool,
	disable_notifications:     bool,
	content_protection:        bool, // "Hide Discord Window from Screen Capture"
}

STREAMER_DEFAULTS :: Streamer_Settings {
	auto_toggle               = true,
	hide_personal_information = true,
	hide_instant_invites      = true,
	disable_sounds            = true,
	disable_notifications     = true,
}

streamer_settings := STREAMER_DEFAULTS

streamer_hide_personal :: proc() -> bool {return streamer_settings.enabled && streamer_settings.hide_personal_information}
streamer_hide_invites :: proc() -> bool {return streamer_settings.enabled && streamer_settings.hide_instant_invites}
streamer_disable_sounds :: proc() -> bool {return streamer_settings.enabled && streamer_settings.disable_sounds}
streamer_disable_notifications :: proc() -> bool {return streamer_settings.enabled && streamer_settings.disable_notifications}

@(private = "file")
sm: struct {
	detected:       bool, // a streaming tool runs (written by the scan thread, atomic)
	scan:           bool, // auto_toggle, for the scan thread (atomic)
	seen:           bool, // last `detected` acted on
	last:           Streamer_Settings, // settings as of the last frame (change tracking)
	started:        bool,
	capture_hidden: bool,
	notice_closed:  bool,
	notice_viewed:  bool,
	notice_guild:   dc.Snowflake, // the route's guild when app_notice_viewed was sent
}

streamer_reset_for_test :: proc() {
	streamer_settings = STREAMER_DEFAULTS
	sm = {}
}

streamer_set_detected_for_test :: proc(on: bool) {sync.atomic_store(&sm.detected, on)}

// ---- detection ----

Streamer_Tool :: struct {
	os:   string, // "win32" | "darwin"
	exe:  string, // lower case: "/<tail of the path>" (win32) or "/<bundle>.app/" (darwin)
	name: string,
}

// RunningGameStore's built-in streamerTool entries.
STREAMER_TOOLS :: [?]Streamer_Tool {
	{"win32", "/obs/obs.exe", "OBS"},
	{"win32", "/obs32.exe", "OBS"},
	{"win32", "/obs64.exe", "OBS"},
	{"darwin", "/obs.app/", "OBS"},
	{"win32", "/xsplit.gamecaster.exe", "XSplit"},
	{"win32", "/xsplit.core.exe", "XSplit"},
	{"win32", "/gamecaster.exe", "XSplit"},
	{"win32", "/bebo.exe", "Bebo"},
	{"win32", "/streamlabs obs.exe", "Streamlabs Desktop"},
	{"win32", "/streamlabs desktop.exe", "Streamlabs Desktop"},
	{"darwin", "/streamlabs desktop.app/", "Streamlabs Desktop"},
	{"win32", "/twitchstudio.exe", "Twitch Studio"},
	{"darwin", "/twitch studio.app/", "Twitch Studio"},
}

STREAMER_OS :: "darwin" when ODIN_OS == .Darwin else "win32"

// streamer_tool_running: the first streaming tool among executable paths (or bare
// file names), case-insensitive.
streamer_tool_running :: proc(paths: []string, os := STREAMER_OS) -> (name: string, ok: bool) {
	tools := STREAMER_TOOLS
	for p in paths {
		lp, _ := strings.replace_all(strings.to_lower(p, context.temp_allocator), "\\", "/", context.temp_allocator)
		lp = strings.concatenate({"/", lp}, context.temp_allocator)
		for t in tools {
			if t.os != os do continue
			if strings.has_suffix(t.exe, "/") ? strings.contains(lp, t.exe) : strings.has_suffix(lp, t.exe) do return t.name, true
		}
	}
	return "", false
}

// streamer_start: the process scan thread (never in headless runs).
streamer_start :: proc() {
	if platform.is_headless() do return
	sync.atomic_store(&sm.scan, streamer_settings.auto_toggle)
	thread.create_and_start(proc() {
		for {
			if sync.atomic_load(&sm.scan) {
				_, on := streamer_tool_running(dc.process_exe_paths(context.temp_allocator))
				if on != sync.atomic_load(&sm.detected) {
					sync.atomic_store(&sm.detected, on)
					platform.request_frame()
				}
				free_all(context.temp_allocator)
			}
			time.sleep(5 * time.Second)
		}
	}, context)
}

// streamer_frame: auto toggle, analytics on changes, screen-capture protection.
streamer_frame :: proc() {
	s := &streamer_settings
	if !sm.started {
		sm.started = true
		sm.last = s^
	}
	sync.atomic_store(&sm.scan, s.auto_toggle)
	if d := sync.atomic_load(&sm.detected); d != sm.seen {
		sm.seen = d
		if s.auto_toggle {
			s.enabled = d
			sm.last.enabled = d
			track_toggle(d, true)
		}
	}
	if s^ != sm.last {
		if s.enabled != sm.last.enabled {
			track_toggle(s.enabled, false)
		} else if app.client != nil {
			dc.analytics_streamer_settings_updated(app.client, streamer_analytics(s^), streamer_analytics(sm.last))
		}
		sm.last = s^
	}
	if hide := s.enabled && s.content_protection; hide != sm.capture_hidden {
		sm.capture_hidden = hide
		platform.set_capture_hidden(hide)
	}
	if !s.enabled do sm.notice_closed, sm.notice_viewed = false, false
}

@(private = "file")
streamer_analytics :: proc(x: Streamer_Settings) -> dc.Streamer_Mode_Analytics {
	return {x.enabled, x.auto_toggle, x.disable_notifications, x.disable_sounds, x.hide_instant_invites, x.hide_personal_information, x.content_protection}
}

@(private = "file")
track_toggle :: proc(on, automatic: bool) {
	if app.client != nil do dc.analytics_streamer_mode_toggle(app.client, on, automatic)
}

@(private = "file")
track_notice :: proc(event: string) {
	if app.client != nil do dc.analytics_app_notice(app.client, event, "STREAMER_MODE")
}

// ---- UI ----

// The STREAMER_MODE notice bar under the title bar: text, "Disable", close.
streamer_notice :: proc() {
	if !streamer_settings.enabled || sm.notice_closed do return
	// the notice re-mounts (and is viewed again) when the route's guild changes
	if !sm.notice_viewed || sm.notice_guild != app.view.guild {
		sm.notice_viewed = true
		sm.notice_guild = app.view.guild
		if app.client != nil do dc.analytics_app_notice(app.client, "app_notice_viewed", "STREAMER_MODE", app.view.guild)
	}
	WHITE :: ui.Color{1, 1, 1, 1}
	bar := row("streamer_notice", {.Draw_Background})
	bar.semantic_size = {.X = ui.pct(1), .Y = ui.px(36)}
	bar.style.bg = {0x59 / 255.0, 0x36 / 255.0, 0x95 / 255.0, 1} // notice color STREAMER_MODE
	if ui.parent(bar) {
		spacer(.X, 36)
		filler(.X)
		label("Streamer Mode is enabled. Usernames have been truncated.", .Medium, 14, WHITE, 18)
		spacer(.X, 10)
		b := row("disable", {.Clickable, .Draw_Border, .Draw_Background, .Hot_Animation})
		b.semantic_size = {.X = ui.children(), .Y = ui.px(24)}
		b.style.border = 1
		b.style.border_color = WHITE
		b.style.radius = 4
		b.style.bg_hot = with_alpha(WHITE, 0.1)
		if ui.parent(b) {
			spacer(.X, 10)
			label("Disable", .Medium, 14, WHITE, 18)
			spacer(.X, 10)
		}
		if ui.signal(b).clicked {
			track_notice("app_notice_primary_cta_opened")
			streamer_settings.enabled = false
		}
		filler(.X)
		x := ui.box("close", {.Clickable})
		x.semantic_size = {.X = ui.px(16), .Y = ui.px(16)}
		xs := ui.signal(x)
		set_icon(x, "x-large", with_alpha(WHITE, xs.hovering ? 1 : 0.8))
		if xs.clicked {
			sm.notice_closed = true
			track_notice("app_notice_closed")
		}
		spacer(.X, 20)
	}
}

// Settings > Appearance > Streamer Mode (a section of Appearance in 0.0.419).
streamer_settings_section :: proc() {
	s := &streamer_settings
	row_toggle :: proc(id, text, help: string, v: ^bool) -> bool {
		if set_toggle_row(id, text, help, v^) {
			v^ = !v^
			return true
		}
		return false
	}
	if row_toggle("sm_enable", "Enable Streamer Mode", "Streamer Mode hides your personal info so others watching your stream can't see it.", &s.enabled) && app.client != nil {
		dc.analytics_ui_setting(app.client, "streaming_enable_streamer_mode")
	}
	spacer(.Y, 24)
	row_toggle("sm_auto", "Automatically enable Streamer Mode if OBS or XSplit are running", "", &s.auto_toggle)
	spacer(.Y, 32)
	label("If Streamer Mode is enabled...", .Semibold, 16, T("--text-strong"), 20)
	spacer(.Y, 24)
	row_toggle("sm_personal", "Hide my personal information, such as email, connected accounts, and notes", "", &s.hide_personal_information)
	spacer(.Y, 24)
	row_toggle("sm_invites", "Hide invite links to my Discord servers", "", &s.hide_instant_invites)
	spacer(.Y, 24)
	row_toggle("sm_sounds", "Disable all sound effects", "", &s.disable_sounds)
	spacer(.Y, 24)
	row_toggle("sm_notifs", "Disable all notifications", "", &s.disable_notifications)
	spacer(.Y, 24)
	row_toggle("sm_capture", "Hide Discord window from screen capture", "Hides most Discord windows from most screen capture software.", &s.content_protection)
}

// Settings > Account while Streamer Mode is on: the page is replaced (email,
// phone and the rest are not shown at all) and nothing is fetched.
streamer_account_page :: proc() {
	page := ui.box("streameraccount")
	page.semantic_size = {.X = ui.pct(1), .Y = ui.fill()}
	page.layout_axis = .Y
	page.cross_align = .Center
	if ui.parent(page) {
		filler(.Y)
		icon("art", "screen-stream", 160, T("--background-brand"))
		spacer(.Y, 24)
		b := row("Streamer Mode Enabled##smbadge", {.Draw_Background, .Draw_Text})
		b.semantic_size = {.X = ui.px(244), .Y = ui.px(48)}
		b.style.radius = 8
		b.style.bg = T("--background-brand")
		b.style.font = F(.Medium)
		b.style.font_size = 18
		b.style.text_align = .Center
		b.style.text_color = {1, 1, 1, 1}
		filler(.Y)
	}
}
