package app

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "fc:audio"
import dc "fc:discord"
import "fc:platform"
import "fc:ui"
import "fc:voice"

// Voice: owns the fc:voice connection for the channel in app.voice_channel.
//   join_voice (views.odin) sends op 4 and sets app.voice_channel;
//   voice_frame (every frame) connects once VOICE_STATE_UPDATE +
//   VOICE_SERVER_UPDATE arrived, reconnects when the server moves (new
//   voice_server_info version), mirrors mute/deafen to the connection and
//   op 4, and tears down on leave / terminal close codes.
//   voice_panel draws the "Voice Connected" section above the user panel.

VOICE_PANEL_H :: 56

@(private = "file")
Voice_App :: struct {
	conn:          ^voice.Conn,
	guild:         dc.Snowflake,
	channel:       dc.Snowflake, // channel the connection belongs to
	version:       u64, // voice_server_info version we connected with
	sent_mute:     bool,
	sent_deaf:     bool,
	audio_ready:   bool,
	headless:      bool, // no audio devices (screenshots / CI never open the mic)
	auto_join:     dc.Snowflake, // FASTCORD_JOIN_VOICE=<channel id>
	auto_checked:  bool,
	speaking:      map[dc.Snowflake]bool, // this frame's speaking set
}

@(private = "file")
vc: Voice_App

voice_set_headless :: proc(h: bool) {vc.headless = h}

// voice_join_channel: op 4 join (or move) and remember the guild for later op 4s.
voice_join_channel :: proc(gid, cid: dc.Snowflake) {
	if app.client == nil do return
	if app.voice_channel == cid do return
	vc.guild = gid
	app.voice_channel = cid
	dc.voice_join(app.client, gid, cid, app.self_mute || app.self_deaf, app.self_deaf)
	vc.sent_mute = app.self_mute
	vc.sent_deaf = app.self_deaf
}

voice_leave_channel :: proc() {
	if app.client != nil && app.voice_channel != 0 do dc.voice_leave(app.client)
	app.voice_channel = 0
	voice_drop()
}

@(private = "file")
voice_drop :: proc() {
	if vc.conn != nil {
		voice.voice_disconnect(vc.conn)
		vc.conn = nil
	}
	vc.channel = 0
	vc.version = 0
	clear(&vc.speaking)
}

voice_shutdown :: proc() {
	voice_drop()
	delete(vc.speaking)
}

voice_frame :: proc() {
	if app.client == nil do return
	if !vc.auto_checked && app.client.store.ready {
		vc.auto_checked = true
		if v := os.get_env("FASTCORD_JOIN_VOICE", context.temp_allocator); v != "" {
			id, _ := strconv.parse_u64(v)
			if ch := dc.channel_get(store(), dc.Snowflake(id)); ch != nil do voice_join_channel(ch.guild_id, ch.id)
		}
	}
	if app.voice_channel == 0 {
		if vc.conn != nil do voice_drop()
		return
	}
	// mute / deafen -> connection + op 4 (deafen implies mute, like the client)
	if app.self_mute != vc.sent_mute || app.self_deaf != vc.sent_deaf {
		vc.sent_mute = app.self_mute
		vc.sent_deaf = app.self_deaf
		dc.voice_join(app.client, vc.guild, app.voice_channel, app.self_mute || app.self_deaf, app.self_deaf)
	}
	if vc.conn != nil {
		voice.set_self_mute(vc.conn, app.self_mute || app.self_deaf)
		voice.set_self_deaf(vc.conn, app.self_deaf)
	}

	info, ver, ok := dc.voice_server_info(app.client)
	if ok && dc.Snowflake(info.channel_id) == app.voice_channel && (vc.conn == nil || ver != vc.version) {
		// first connect, channel move or server migration
		voice_drop()
		if !vc.headless && !vc.audio_ready do vc.audio_ready = audio.init()
		vc.conn = voice.voice_connect(voice.Voice_Server_Info {
			endpoint            = info.endpoint,
			token               = info.token,
			guild_or_channel_id = u64(info.guild_or_channel_id),
			user_id             = u64(info.user_id),
			session_id          = info.session_id,
			channel_id          = u64(info.channel_id),
			stage               = is_stage(app.voice_channel),
			user_agent          = app.client.id.platform.browser_user_agent,
			accept_language     = app.client.id.platform.accept_language,
		}, voice.Options{no_audio_devices = vc.headless || !vc.audio_ready})
		vc.version = ver
		vc.channel = app.voice_channel
		voice.set_self_mute(vc.conn, app.self_mute || app.self_deaf)
		voice.set_self_deaf(vc.conn, app.self_deaf)
	}
	if vc.conn != nil {
		st, code := voice.state(vc.conn)
		if st == .Disconnected {
			voice.voice_disconnect(vc.conn)
			vc.conn = nil
			switch code {
			case voice.CLOSE_DISCONNECTED, voice.CLOSE_CALL_TERMINATED, voice.CLOSE_AUTHENTICATION_FAILED:
				// kicked / moved out / call ended: we are no longer in the channel
				app.voice_channel = 0
			case:
				// the next VOICE_SERVER_UPDATE (new version) reconnects; until then retry once
				vc.version = 0
			}
		}
	}
	clear(&vc.speaking)
	if vc.conn != nil {
		for id in voice.speaking_users(vc.conn, context.temp_allocator) do vc.speaking[dc.Snowflake(id)] = true
		// speaking rings and the ping readout change without input events
		request_wake(platform.time_now() + 0.1)
	}
}

@(private = "file")
is_stage :: proc(cid: dc.Snowflake) -> bool {
	ch := dc.channel_get(store(), cid)
	return ch != nil && ch.kind == .Guild_Stage_Voice
}

voice_is_speaking :: proc(uid: dc.Snowflake) -> bool {return vc.speaking[uid]}

voice_panel_height :: proc() -> f32 {return VOICE_PANEL_H if app.voice_channel != 0 else 0}

// Avatar with the green "speaking" ring (inset 2 px green + 1 px surface gap).
voice_avatar :: proc(id: string, uid: dc.Snowflake, size: f32, surface: ui.Color) -> ^ui.Box {
	b := avatar_box(id, uid, size)
	if !voice_is_speaking(uid) do return b
	if ui.parent(b) {
		r := ui.box("ring", {.Draw_Border, .Floating_X, .Floating_Y})
		r.semantic_size = {.X = ui.px(size), .Y = ui.px(size)}
		r.style.radius = size / 2
		r.style.border = 2
		r.style.border_color = T("--status-positive")
		g := ui.box("gap", {.Draw_Border, .Floating_X, .Floating_Y})
		g.semantic_size = {.X = ui.px(size - 4), .Y = ui.px(size - 4)}
		g.fixed_pos = {2, 2}
		g.style.radius = (size - 4) / 2
		g.style.border = 1
		g.style.border_color = surface
	}
	return b
}

// voice_panel: "Voice Connected" / channel / guild, disconnect button; ping on hover.
voice_panel :: proc() {
	s := store()
	p := row("voicepanel")
	p.semantic_size = {.X = ui.pct(1), .Y = ui.px(VOICE_PANEL_H)}
	status := "RTC Connecting"
	color := T("--text-feedback-warning")
	sig_icon := "connection-unknown"
	ping := -1
	e2ee := false
	if vc.conn != nil {
		st, _ := voice.state(vc.conn)
		stats := voice.get_stats(vc.conn)
		ping = stats.rtt_ms if stats.rtt_ms > 0 else stats.ws_ping_ms
		e2ee = voice.e2ee_status(vc.conn, context.temp_allocator).active
		#partial switch st {
		case .Connected:
			status = "Voice Connected"
			color = T("--text-feedback-positive")
			sig_icon = "connection-fine"
			if ping > 250 {
				sig_icon = "connection-bad"
				color = T("--text-feedback-critical")
			} else if ping > 150 {
				sig_icon = "connection-average"
				color = T("--text-feedback-warning")
			}
		case .Disconnected:
			status = "Voice Disconnected"
			color = T("--text-feedback-critical")
			sig_icon = "connection-bad"
		}
	}
	if ui.parent(p) {
		spacer(.X, 8)
		info := row("info", {.Clickable, .Draw_Background, .Hot_Animation})
		info.semantic_size = {.X = ui.fill(), .Y = ui.px(42)}
		info.style.radius = 8
		info.style.bg_hot = T("--background-mod-subtle")
		isig := ui.signal(info)
		if ui.parent(info) {
			spacer(.X, 6)
			icon("sig", sig_icon, 20, color)
			spacer(.X, 8)
			col := ui.box("text")
			col.semantic_size = {.X = ui.fill(), .Y = ui.children()}
			if ui.parent(col) {
				label(status, .Semibold, 14, color, 18)
				where_ := "Voice"
				if ch := dc.channel_get(s, app.voice_channel); ch != nil {
					if ch.guild_id != 0 {
						gname := ""
						if g := dc.guild_get(s, ch.guild_id); g != nil do gname = g.name
						where_ = strings.concatenate({ch.name, " / ", gname}, context.temp_allocator)
					} else {
						where_ = dm_name(ch)
					}
				}
				t := label(where_, .Normal, 12, T("--text-muted"), 14)
				t.flags += {.Clip}
			}
		}
		if isig.hovering {
			tip := row("pingtip", {.Draw_Background, .Draw_Shadow, .Floating_X, .Floating_Y, .Overlay})
			tip.semantic_size = {.X = ui.children(), .Y = ui.px(32)}
			tip.fixed_pos = {8, -40}
			tip.style.bg = T("--background-surface-highest")
			tip.style.radius = 8
			tip.style.shadow_color = {0, 0, 0, 0.3}
			tip.style.shadow_blur = 8
			tip.style.shadow_offset = {0, 4}
			if ui.parent(tip) {
				spacer(.X, 12)
				text := ping >= 0 ? fmt.tprintf("Ping: %d ms", ping) : "Ping: —"
				if e2ee do text = strings.concatenate({text, " · End-to-end encrypted"}, context.temp_allocator)
				label(text, .Semibold, 14, T("--text-strong"), 18)
				spacer(.X, 12)
			}
		}
		b := ui.box("disconnect", {.Clickable, .Draw_Background, .Hot_Animation})
		b.semantic_size = {.X = ui.px(32), .Y = ui.px(32)}
		b.style.radius = 8
		b.style.bg_hot = T("--background-mod-subtle")
		b.layout_axis = .X
		b.cross_align = .Center
		dsig := ui.signal(b)
		if ui.parent(b) {
			spacer(.X, 6)
			icon("i", "phone-hang-up", 20, dsig.hovering ? T("--interactive-icon-hover") : T("--interactive-icon-default"))
		}
		if dsig.clicked do voice_leave_channel()
		spacer(.X, 8)
	}
	div := ui.box("div", {.Draw_Background})
	div.semantic_size = {.X = ui.pct(1), .Y = ui.px(1)}
	div.style.bg = T("--border-subtle")
}
