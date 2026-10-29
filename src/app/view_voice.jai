// Voice: owns the fc:voice connection for the channel in app.voice_channel.
//   join_voice (views.jai) sends op 4 and sets app.voice_channel;
//   voice_frame (every frame) connects once VOICE_STATE_UPDATE +
//   VOICE_SERVER_UPDATE arrived, reconnects when the server moves (new
//   voice_server_info version) or the connection drops (with backoff), follows
//   a moderator's move, mirrors mute/deafen to the connection and op 4, and
//   tears down on leave or when the server removes our voice state.
//   voice_panel draws the "Voice Connected" section above the user panel.

VOICE_PANEL_H :: 56;
VOICE_BUTTONS_H :: 40; // the Video / Screen row under it
RTC_RECONNECT_TIMEOUT_MS :: 5 * 60 * 1000;
REJOIN_MS :: 5000; // how long a hang up offers Rejoin
REJOIN_H :: 48;

voice_set_headless :: (h: bool) { vc.headless = h; }

// The connection the call is on (Discord's, or a hosted server's), which stays while another is selected.
call_client :: () -> *dc.Client { return ifx vc.client then vc.client else app.client; }
call_store :: () -> *dc.Store { return ifx vc.client then *vc.client.store else store(); }

// call_on_selected: a call starts on the selected connection, ending one on another first.
call_on_selected :: () {
	if vc.client && vc.client != app.client && app.voice_channel voice_leave_channel();
	vc.client = app.client;
}

// hosted_voice: how a voice connection reaches cl's server when it is a hosted one.
hosted_voice :: (cl: *dc.Client) -> voice.Hosted {
	h := cl.cfg.hosted;
	return .{host = h.host, port = h.port, server_id = h.server_id, pin = h.pin};
}

// voice_client_gone: c is being released (a hosted server dropped or logged in again), so its call ends here.
voice_client_gone :: (c: *dc.Client) {
	if vc.rejoin.client == c vc.rejoin = .{};
	if !c || c != vc.client return;
	app.voice_channel = 0;
	voice_drop();
	vc.client = null;
}

// voice_join_channel: op 4 join (or move) and remember the guild for later op 4s.
voice_join_channel :: (gid: dc.Snowflake, cid: dc.Snowflake) {
	if app.voice_channel == cid && vc.client == app.client { return; }
	if voice_channel_full(cid) {
		toast_show(L("This voice channel is full."), false);
		return;
	}
	if !net_action() { return; }
	call_on_selected();
	vc.guild = gid;
	app.voice_channel = cid;
	dc.voice_join(app.client, gid, cid, app.self_mute || app.self_deaf, app.self_deaf);
	vc.sent_mute = app.self_mute;
	vc.sent_deaf = app.self_deaf;
}

// DM / group DM header phone button ("Start Voice Call"): joins the channel's
// call, or hangs up when already in it. A new call rings the others once its
// CALL_CREATE arrives (dc.dm_call_start).
dm_call_toggle :: (ch: *dc.Channel) {
	if app.voice_channel == ch.id {
		voice_hang_up();
		return;
	}
	if !net_action() { return; }
	if app.voice_channel == ch.id { return; }
	call_on_selected();
	vc.guild = 0;
	app.voice_channel = ch.id;
	dc.dm_call_start(app.client, ch.id, app.self_mute || app.self_deaf, app.self_deaf);
	vc.sent_mute = app.self_mute;
	vc.sent_deaf = app.self_deaf;
}

// The incoming call's "Join Call" (op 4 into the DM, like the caller's).
call_join_incoming :: (cid: dc.Snowflake) {
	if !net_action() { return; }
	call_on_selected();
	vc.guild = 0;
	app.voice_channel = cid;
	dc.call_accept(app.client, cid, app.self_mute || app.self_deaf, app.self_deaf);
	vc.sent_mute = app.self_mute;
	vc.sent_deaf = app.self_deaf;
}

// Ctrl+Alt+A or a click on the voice panel's channel: open the connected call.
voice_return :: () {
	ch := dc.channel_get(call_store(), app.voice_channel);
	if ch && vc.client app.client = vc.client; // The call's connection, which may not be the selected one.
	if ch select_channel(ch.guild_id, ch.id);
}

// voice_hang_up: the panel's, call view's or DM header's hang up. For a few seconds the panel offers Rejoin,
// which joins again and turns the camera and screen share back on (fastcord-only).
voice_hang_up :: () {
	if !app.voice_channel return;
	vc.rejoin = .{client = call_client(), guild = vc.guild, channel = app.voice_channel, camera = camera_on(), screen = screen_sharing(),
		target = vid.own_target, until = dc.now_ms() + REJOIN_MS};
	if call_client() dc.analytics_call_disconnect(call_client(), vc.guild, app.voice_channel);
	voice_leave_channel();
	request_wake(platform.time_now() + REJOIN_MS / 1000.0 + 0.01);
}

rejoin_offered :: () -> bool { return vc.rejoin.channel && !app.voice_channel && dc.now_ms() < vc.rejoin.until; }

voice_rejoin :: () {
	r := vc.rejoin;
	vc.rejoin = .{};
	keep := app.client;
	app.client = r.client;
	if r.guild voice_join_channel(r.guild, r.channel);
	else if dc.channel_get(store(), r.channel) dm_call_toggle(dc.channel_get(store(), r.channel));
	app.client = keep;
	if app.voice_channel != r.channel return;
	vc.restore_camera, vc.restore_screen, vc.restore_target = r.camera, r.screen, r.target;
}

voice_leave_channel :: () {
	vc.restore_camera, vc.restore_screen = false, false;
	if call_client() != null && app.voice_channel != 0 { dc.voice_leave(call_client()); }
	app.voice_channel = 0;
	voice_drop();
	vc.client = null;
}

voice_shutdown :: () {
	voice_drop();
	video_shutdown();
	deinit(*vc.speaking);
}

voice_conn :: () -> *voice.Conn { return vc.conn; }
voice_headless :: () -> bool { return vc.headless; }
voice_audio_ready :: () -> bool { return vc.audio_ready; }

voice_frame :: () {
	cl := call_client();
	if cl == null { return; }
	if !vc.auto_checked && cl.store.ready {
		vc.auto_checked = true;
		id, _ := dc.parse_u64(env_var("FASTCORD_JOIN_VOICE"));
		ch := dc.channel_get(store(), cast(dc.Snowflake) id);
		if ch voice_join_channel(ch.guild_id, ch.id);
	}
	if app.voice_channel == 0 {
		if vc.conn != null { voice_drop(); }
		dc.client_set_rtc_state(cl, .Disconnected);
		return;
	}
	// A new gateway session (reconnect without resume): its READY's op 4 rejoined the call
	// (VoiceStateStore), and the connection moves to the new session's VOICE_SERVER_UPDATE.
	s := *cl.store;
	rejoin := vc.synced && vc.readies != s.readies;
	// Our account joined a call on another device: Discord moved the call there. Hang up here
	// without op 4 (a null channel would end the other device's call too).
	if vc.synced && vc.voice_elsewhere != s.voice_elsewhere {
		app.voice_channel = 0;
		voice_drop();
		return;
	}
	vc.synced = true;
	vc.readies = s.readies;
	vc.voice_elsewhere = s.voice_elsewhere;
	// The server moved us (a moderator): the call follows; removed us (kicked, channel deleted, call
	// ended): it ends here without an op 4.
	if rejoin vc.seen_channel = 0;
	followed := dc.voice_followed(cl, app.voice_channel, *vc.seen_channel);
	if followed != app.voice_channel {
		if followed && app.voice_channel sound_moved(followed); // sounds.jai
		app.voice_channel = followed;
		if !followed {
			voice_drop();
			return;
		}
	}
	// mute / deafen -> connection + op 4 (deafen implies mute, like the client)
	if app.self_mute != vc.sent_mute || app.self_deaf != vc.sent_deaf {
		vc.sent_mute = app.self_mute;
		vc.sent_deaf = app.self_deaf;
		dc.voice_set_state(cl, vc.guild, app.voice_channel, app.self_mute || app.self_deaf, app.self_deaf, camera_on());
	}
	if vc.conn != null {
		// A server mute or deafen also stops sending and playing here; op 4 keeps only our own choice.
		smute, sdeaf := server_muted();
		// a stage's audience sends nothing
		me := table_find_pointer(*s.voice_states, s.me);
		if me && me.channel_id == app.voice_channel && me.suppress && is_stage(app.voice_channel) smute = true;
		else vc.hand_raised = false;
		voice.set_self_mute(vc.conn, app.self_mute || app.self_deaf || smute || sdeaf);
		voice.set_self_deaf(vc.conn, app.self_deaf || sdeaf);
	}

	info, ver, ok := dc.voice_server_info(cl);
	// Channel move or server migration: drop the old connection, then connect once its teardown is done.
	if ok && vc.conn != null && ver != vc.version && cast(dc.Snowflake)(info.channel_id) == app.voice_channel { voice_drop(); }
	if ok && vc.conn == null && !teardown_busy() && cast(dc.Snowflake)(info.channel_id) == app.voice_channel && dc.now_ms() >= vc.retry_at {
		if !vc.headless {
			// opening the microphone asks the OS for it (permissions_requested)
			dc.analytics_permissions_requested(cl, "audio");
			if !vc.audio_ready { vc.audio_ready = audio.init(); }
		}
		vc.conn = voice.voice_connect(voice.Voice_Server_Info.{
			endpoint = info.endpoint,
			token = info.token,
			guild_or_channel_id = cast(u64)(info.guild_or_channel_id),
			user_id = cast(u64)(info.user_id),
			session_id = info.session_id,
			channel_id = cast(u64)(info.channel_id),
			stage = is_stage(app.voice_channel),
			user_agent = cl.id.platform.browser_user_agent,
			accept_language = cl.id.platform.accept_language
		}, voice_options(cl));
		vc.version = ver;
		vc.channel = app.voice_channel;
		voice.set_self_mute(vc.conn, app.self_mute || app.self_deaf);
		voice.set_self_deaf(vc.conn, app.self_deaf);
	}
	rtc := voice_rtc_state();
	dc.client_set_rtc_state(cl, rtc); // client_rtc_state while in voice
	if rtc == .Rtc_Connected dc.backoff_succeed(*vc.backoff);
	if rtc == .Rtc_Connected && vc.restore_camera { vc.restore_camera = false; if !camera_on() camera_toggle(); }
	if rtc == .Rtc_Connected && vc.restore_screen { vc.restore_screen = false; go_live_start(vc.restore_target); }
	// RTCReconnectTimeoutManager: in a call (our voice state is there) with no RTC connection for 5 minutes,
	// the official client hangs up rather than retry forever.
	if rtc == .Rtc_Connected || !vc.seen_channel vc.unconnected_since = 0;
	else if !vc.unconnected_since vc.unconnected_since = dc.now_ms();
	else if dc.now_ms() - vc.unconnected_since >= RTC_RECONNECT_TIMEOUT_MS {
		voice_leave_channel();
		return;
	}
	if vc.unconnected_since request_wake(platform.time_now() + cast(float64) (vc.unconnected_since + RTC_RECONNECT_TIMEOUT_MS - dc.now_ms()) / 1000 + 0.01);
	if vc.conn != null && voice.state(vc.conn) == .Disconnected {
		// RTCConnection._handleDisconnect: whatever the code, connect again (a fresh IDENTIFY) after
		// Backoff(1 s, 10 s); our voice state going away (above) is what ends the call.
		voice_release(vc.conn);
		vc.conn = null;
		vc.retry_at = dc.now_ms() + dc.backoff_fail(*vc.backoff);
		request_wake(platform.time_now() + cast(float64) (vc.retry_at - dc.now_ms()) / 1000 + 0.01);
	}
	voice_analytics_frame();
	table_reset_keeping_memory(*vc.speaking);
	if vc.conn != null {
		for voice.speaking_users(vc.conn,, temp) table_set(*vc.speaking, cast(dc.Snowflake) it, true);
		// speaking rings and the ping readout change without input events
		request_wake(platform.time_now() + 0.1);
	}
}

voice_is_speaking :: (uid: dc.Snowflake) -> bool { return table_contains(*vc.speaking, uid); }
vc_hand_raised :: (on: bool) { vc.hand_raised = on; }
vc_hand_raised_get :: () -> bool { return vc.hand_raised; }

// server_muted / server_deafened: a moderator muted or deafened us in the call (our voice state's mute / deaf).
server_muted :: () -> bool, deafened: bool {
	s := call_store();
	if !app.voice_channel return false, false;
	vs := table_find_pointer(*s.voice_states, s.me);
	if !vs || vs.channel_id != app.voice_channel return false, false;
	return vs.mute, vs.deaf;
}

// A guild voice channel at its user limit refuses joining, unless we may move members (who can join it
// anyway, as on Discord). A stage's limit isn't checked.
voice_channel_full :: (cid: dc.Snowflake) -> bool {
	s := store();
	ch := dc.channel_get(s, cid);
	if !ch || ch.kind != .Guild_Voice || ch.user_limit <= 0 return false;
	if dc.has_permission(dc.channel_permissions(s, cid), dc.PERM_MOVE_MEMBERS) return false;
	n := 0;
	for v, uid: s.voice_states if v.channel_id == cid && uid != s.me n += 1;
	return n >= ch.user_limit;
}

voice_panel_height :: () -> float32 {
	if app.voice_channel == 0 return ifx rejoin_offered() then cast(float32) REJOIN_H else 0;
	return cast(float32) VOICE_PANEL_H + VOICE_BUTTONS_H;
}

// Avatar with the green "speaking" ring (inset 2 px green + 1 px surface gap).
voice_avatar :: (id: string, uid: dc.Snowflake, size: float32, surface: ui.Color) -> *ui.Box {
	b := avatar_box(id, uid, size);
	if !voice_is_speaking(uid) { return b; }
	{ ui.parent(b); defer ui.pop_parent();
		r := ui.box("ring", .Draw_Border | .Floating_X | .Floating_Y);
		r.semantic_size = .[ui.px(size), ui.px(size)];
		r.style.radius = all4(size / 2);
		r.style.border = 2;
		r.style.border_color = T("--status-positive");
		g := ui.box("gap", .Draw_Border | .Floating_X | .Floating_Y);
		g.semantic_size = .[ui.px(size - 4), ui.px(size - 4)];
		g.fixed_pos = .{2, 2};
		g.style.radius = all4((size - 4) / 2);
		g.style.border = 1;
		g.style.border_color = surface;
	}
	return b;
}

// voice_panel: "Voice Connected" / channel / guild, disconnect button; ping on hover.
voice_panel :: () {
	if !app.voice_channel {
		// the Rejoin offer after a hang up
		r := row("rejoin");
		r.semantic_size = .[ui.pct(1), ui.px(REJOIN_H)];
		{ ui.parent(r); defer ui.pop_parent();
			spacer(.X, 14);
			label(L("Disconnected"), .Semibold, 14, T("--text-muted"), 18);
			filler(.X);
			b := row("rejoinbtn", .Clickable | .Draw_Background | .Hot_Animation);
			b.semantic_size = .[ui.children(), ui.px(32)];
			b.style.radius = all4(8);
			b.style.bg = T("--background-brand");
			b.style.bg_hot = with_alpha(T("--background-brand"), 0.85);
			if ui.signal(b).clicked voice_rejoin();
			{ ui.parent(b); defer ui.pop_parent();
				spacer(.X, 14);
				label(L("Rejoin"), .Semibold, 14, .{1, 1, 1, 1}, 18);
				spacer(.X, 14);
			}
			spacer(.X, 8);
		}
		div := ui.box("div", .Draw_Background);
		div.semantic_size = .[ui.pct(1), ui.px(1)];
		div.style.bg = T("--border-subtle");
		return;
	}
	s := call_store();
	p := row("voicepanel");
	p.semantic_size = .[ui.pct(1), ui.px(VOICE_PANEL_H)];
	status := L("RTC Connecting");
	color := T("--text-feedback-warning");
	sig_icon := "connection-unknown";
	ping := -1;
	e2ee, plain := false, false;
	if vc.conn != null {
		st, _ := voice.state(vc.conn);
		stats := voice.get_stats(vc.conn);
		ping = ifx stats.rtt_ms > 0 then stats.rtt_ms else stats.ws_ping_ms;
		if ping <= 0 { ping = -1; } // no heartbeat ack / RTCP round trip yet
		es := voice.e2ee_status(vc.conn,, temp);
		e2ee = es.active;
		// A hosted server that didn't run DAVE (an old one, or a hostile one) gets a plain warning.
		plain = st == .Connected && es.protocol_version == 0 && call_client() && call_client().cfg.hosted.host != "";
		if st == {
		case .Connected;
			status = L("Voice Connected");
			color = T("--text-feedback-positive");
			sig_icon = "connection-fine";
			if ping > 250 {
				sig_icon = "connection-bad";
				color = T("--text-feedback-critical");
			} else if ping > 150 {
				sig_icon = "connection-average";
				color = T("--text-feedback-warning");
			}
		case .Disconnected;
			status = L("Voice Disconnected");
			color = T("--text-feedback-critical");
			sig_icon = "connection-bad";
		}
	}
	{ ui.parent(p); defer ui.pop_parent();
		spacer(.X, 8);
		info := row("info", .Clickable | .Draw_Background | .Hot_Animation);
		info.semantic_size = .[ui.fill(), ui.px(42)];
		info.style.radius = all4(8);
		info.style.bg_hot = T("--background-mod-subtle");
		isig := ui.signal(info);
		if isig.clicked vc.info_open = !vc.info_open; // connection info
		vc.info_anchor = info.rect;
		{ ui.parent(info); defer ui.pop_parent();
			spacer(.X, 6);
			icon("sig", sig_icon, 20, color);
			spacer(.X, 8);
			col := ui.box("text");
			col.semantic_size = .[ui.fill(), ui.children()];
			{ ui.parent(col); defer ui.pop_parent();
				label(status, .Semibold, 14, color, 18);
				where_ := L("Voice");
				ch := dc.channel_get(s, app.voice_channel);
				if ch && ch.guild_id != 0 {
					g := dc.guild_get(s, ch.guild_id);
					where_ = tprint("% / %", ch.name, ifx g then g.name else "");
				} else if ch {
					where_ = dm_name(ch);
				}
				t := ifx plain then label(L("Not end-to-end encrypted"), .Normal, 12, T("--text-feedback-warning"), 14) else label(where_, .Normal, 12, T("--text-muted"), 14);
				t.flags |= .Clip | .Clickable; // the channel's name goes to the call
				tsig := ui.signal(t);
				if tsig.hovering t.style.text_color = T("--text-default");
				if tsig.clicked voice_return();
			}
		}
		if isig.hovering && !vc.info_open {
			tip := row("pingtip", .Draw_Background | .Draw_Shadow | .Floating_X | .Floating_Y | .Overlay);
			tip.semantic_size = .[ui.children(), ui.px(32)];
			tip.fixed_pos = .{8, -40};
			tip.style.bg = T("--background-surface-highest");
			tip.style.radius = all4(8);
			tip.style.shadow_color = .{0, 0, 0, 0.3};
			tip.style.shadow_blur = 8;
			tip.style.shadow_offset = .{0, 4};
			{ ui.parent(tip); defer ui.pop_parent();
				spacer(.X, 12);
				text := ifx ping > 0 then tprint(L("Ping: % ms"), ping) else L("Ping: measuring…");
				if e2ee text = tprint(L("% · End-to-end encrypted"), text);
				label(text, .Semibold, 14, T("--text-strong"), 18);
				spacer(.X, 12);
			}
		}
		// Noise Suppression, as a quick toggle (Voice & Video's switch)
		nb := ui.box("noise", .Clickable | .Draw_Background | .Hot_Animation);
		nb.semantic_size = .[ui.px(32), ui.px(32)];
		nb.style.radius = all4(8);
		nb.style.bg_hot = T("--background-mod-subtle");
		nb.layout_axis = .X;
		nb.cross_align = .Center;
		nsig := ui.signal(nb);
		{ ui.parent(nb); defer ui.pop_parent();
			spacer(.X, 6);
			icon("i", "waveform", 20, ifx vs.noise then T("--text-feedback-positive") else T("--interactive-icon-default"));
		}
		if nsig.hovering tooltip_below(ifx vs.noise then L("Noise Suppression: On") else L("Noise Suppression: Off"), nb.rect, above = true);
		if nsig.clicked vs.noise = !vs.noise;
		b := ui.box("disconnect", .Clickable | .Draw_Background | .Hot_Animation);
		b.semantic_size = .[ui.px(32), ui.px(32)];
		b.style.radius = all4(8);
		b.style.bg_hot = T("--background-mod-subtle");
		b.layout_axis = .X;
		b.cross_align = .Center;
		dsig := ui.signal(b);
		{ ui.parent(b); defer ui.pop_parent();
			spacer(.X, 6);
			icon("i", "phone-hang-up", 20, ifx dsig.hovering then T("--interactive-icon-hover") else T("--interactive-icon-default"));
		}
		if dsig.clicked voice_hang_up();
		spacer(.X, 8);
	}
	can_video := vc.conn != null && voice.state(vc.conn) == .Connected;
	br := row("vbuttons");
	br.semantic_size = .[ui.pct(1), ui.px(VOICE_BUTTONS_H)];
	{ ui.parent(br); defer ui.pop_parent();
		spacer(.X, 8);
		if video.SUPPORTED {
			if voice_panel_button("video", "video", L("Video"), camera_on(), can_video) camera_toggle();
			spacer(.X, 8);
			if voice_panel_button("screen", "screen-stream", L("Screen"), screen_sharing(), can_video) {
				if !screen_sharing() video.screen_targets_refresh();
				vid.picker_open = true; // while streaming: its settings and Stop Streaming
			}
			spacer(.X, 8);
		}
		can_sb := soundboard_available();
		sbb := row("soundboard", ifx can_sb then ui.Box_Flags.Clickable | .Draw_Background | .Hot_Animation else .Draw_Background);
		sbb.semantic_size = .[ifx video.SUPPORTED then ui.px(40) else ui.fill(), ui.px(32)];
		sbb.style.radius = all4(8);
		sbb.style.bg = ifx sb.open then T("--background-mod-strong") else T("--background-mod-subtle");
		sbb.style.bg_hot = T("--background-mod-normal");
		sbb.cross_align = .Center;
		if ui.signal(sbb).clicked && can_sb soundboard_toggle(sbb.rect);
		{ ui.parent(sbb); defer ui.pop_parent();
			filler(.X);
			icon("i", "music", 18, ifx can_sb then T("--interactive-text-default") else T("--text-muted"));
			filler(.X);
		}
		spacer(.X, 8);
	}
	div := ui.box("div", .Draw_Background);
	div.semantic_size = .[ui.pct(1), ui.px(1)];
	div.style.bg = T("--border-subtle");
}

// voice_info_popout: the panel's connection info: the voice server, ping, packets, loss and jitter, and
// end-to-end encryption with the call's privacy code. A press outside or Escape closes it.
voice_info_popout :: () {
	if !vc.info_open return;
	if !app.voice_channel || outside_pressed("vinfo_scrim") || escape_pressed() {
		vc.info_open = false;
		return;
	}
	W :: cast(float32) 300;
	p := ui.box("vinfo", .Draw_Background | .Draw_Border | .Draw_Shadow | .Floating_X | .Floating_Y | .Overlay | .Clickable);
	h := p.rect.y1 - p.rect.y0; // last frame's
	p.semantic_size = .[ui.px(W), ui.children()];
	p.fixed_pos = .{vc.info_anchor.x0, max(8.0, vc.info_anchor.y0 - h - 8)};
	p.layout_axis = .Y;
	p.style.bg = T("--background-surface-higher");
	p.style.border = 1;
	p.style.border_color = T("--border-subtle");
	p.style.radius = all4(8);
	p.style.shadow_color = .{0, 0, 0, 0.3};
	p.style.shadow_blur = 16;
	ui.signal(p);
	ui.parent(p); defer ui.pop_parent();
	line :: (k: string, v: string) {
		r := row(k);
		r.semantic_size = .[ui.pct(1), ui.px(22)];
		ui.parent(r); defer ui.pop_parent();
		spacer(.X, 16);
		label(k, .Medium, 13, T("--text-muted"), 18);
		filler(.X);
		label(tprint("%##v", v), .Semibold, 13, T("--text-default"), 18);
		spacer(.X, 16);
	}
	spacer(.Y, 12);
	hdr := row("hdr");
	hdr.semantic_size = .[ui.pct(1), ui.px(22)];
	{ ui.parent(hdr); defer ui.pop_parent(); spacer(.X, 16); label(L("Connection Info"), .Semibold, 16, T("--text-strong"), 20); }
	spacer(.Y, 8);
	host: string;
	if call_client() {
		info, _, ok := dc.voice_server_info(call_client());
		if ok host = info.endpoint;
	}
	if find_index_from_left(host, #char ":") > 0 host.count = find_index_from_left(host, #char ":");
	line(L("Server"), ifx host then host else L("Waiting for a server"));
	if !vc.conn {
		line(L("State"), L("Connecting"));
	} else {
		st := voice.get_stats(vc.conn);
		ping := ifx st.rtt_ms > 0 then st.rtt_ms else st.ws_ping_ms;
		line(L("State"), tprint("%", voice.state(vc.conn)));
		line(L("Ping"), ifx ping > 0 then tprint("% ms", ping) else L("Measuring"));
		line(L("Packets sent"), tprint("%", st.packets_sent));
		line(L("Packets received"), tprint("%", st.packets_received));
		j := st.jitter;
		heard := j.received + j.lost;
		line(L("Packet loss"), ifx heard then tprint("%\%", formatFloat(100.0 * j.lost / heard, trailing_width = 1)) else "0%");
		line(L("Jitter"), tprint("% ms", formatFloat(j.jitter_ms, trailing_width = 1)));
		e := voice.e2ee_status(vc.conn,, temp);
		line(L("End-to-end encryption"), ifx e.active then tprint(L("DAVE v%, % members"), e.protocol_version, e.members) else L("Off"));
		if e.active && e.privacy_code {
			spacer(.Y, 6);
			r := row("pc");
			r.semantic_size = .[ui.pct(1), ui.px(18)];
			{ ui.parent(r); defer ui.pop_parent(); spacer(.X, 16); label(L("PRIVACY CODE"), .Semibold, 12, T("--text-muted"), 16); }
			// grouped in fives, as the official client shows it
			sb: String_Builder;
			sb.allocator = temp;
			for i: 0..e.privacy_code.count - 1 {
				if i && i % 5 == 0 append(*sb, " ");
				append(*sb, e.privacy_code[i]);
			}
			code := builder_to_string(*sb,, temp);
			cr := row("code");
			cr.semantic_size = .[ui.pct(1), ui.px(22)];
			{ ui.parent(cr); defer ui.pop_parent(); spacer(.X, 16); label(tprint("%##code", code), .Semibold, 15, T("--text-strong"), 20); }
		}
	}
	spacer(.Y, 12);
	request_wake(platform.time_now() + 1); // the numbers move
}

voice_reset_for_test :: () { vc = .{headless = true}; }

voice_panel_button :: (id: string, icon_name: string, text: string, on: bool, enabled: bool) -> bool {
	b := row(id, ifx enabled then ui.Box_Flags.Clickable | .Draw_Background | .Hot_Animation else .Draw_Background);
	b.semantic_size = .[ui.fill(), ui.px(32)];
	b.style.radius = all4(8);
	b.style.bg = ifx on then T("--status-positive") else T("--background-mod-subtle");
	b.style.bg_hot = ifx on then with_alpha(T("--status-positive"), 0.85) else T("--background-mod-normal");
	b.cross_align = .Center;
	sig := ui.signal(b);
	col := ifx on then ui.Color.{1, 1, 1, 1} else ifx enabled then T("--interactive-text-default") else T("--text-muted");
	{ ui.parent(b); defer ui.pop_parent();
		filler(.X);
		icon("i", icon_name, 18, col);
		spacer(.X, 6);
		label(text, .Semibold, 14, col, 18);
		filler(.X);
	}
	return enabled && sig.clicked;
}

// The ring popout of an incoming DM call (fixture dm_call, B's view): avatar,
// name, "Incoming Call...", Decline (red) and Join Call (green). Join sends op 4
// into the DM; Decline only dismisses the ring here, since declining was not
// captured (the official client's decline request is unknown).
incoming_call_popout :: () {
	if app.client == null { return; }
	cid := dc.incoming_call(app.client);
	if cid == 0 || cid == app.voice_channel { return; }
	ch := dc.channel_get(store(), cid);
	if ch == null { return; }
	caller: dc.Snowflake;
	if dc.call_get(app.client, cid) {
		for vs, uid: store().voice_states if vs.channel_id == cid && uid != store().me { caller = uid; break; }
	}
	if caller == 0 && ch.recipient_ids.count > 0 caller = ch.recipient_ids[0];
	W :: cast(float32) 234;
	H :: cast(float32) 270;
	area_x := cast(float32) (72 + 240);
	p := ui.box("incoming_call", .Draw_Background | .Draw_Border | .Draw_Shadow | .Floating_X | .Floating_Y | .Overlay | .Clickable);
	p.semantic_size = .[ui.px(W), ui.px(H)];
	p.fixed_pos = .{area_x + (app.ui.window.x - area_x - W) / 2, 160};
	p.layout_axis = .Y;
	p.cross_align = .Center;
	p.style.bg = T("--background-surface-high");
	p.style.border = 1;
	p.style.border_color = T("--border-subtle");
	p.style.radius = all4(8);
	p.style.shadow_color = .{0, 0, 0, 0.3};
	p.style.shadow_blur = 16;
	ui.signal(p);
	{ ui.parent(p); defer ui.pop_parent();
		spacer(.Y, 32);
		avatar_box("av", caller, 80);
		spacer(.Y, 16);
		name := ifx ch.kind == .DM then dc.user_name(store(), caller, 0, "Unknown") else dm_name(ch);
		label(ellipsize(name, .Semibold, 20, W - 32), .Semibold, 20, T("--text-strong"), 24);
		spacer(.Y, 2);
		label(L("Incoming Call..."), .Normal, 16, T("--text-default"), 20);
		spacer(.Y, 24);
		btns := row("btns");
		btns.semantic_size = .[ui.children(), ui.px(50)];
		btns.style.child_gap = 8;
		{ ui.parent(btns); defer ui.pop_parent();
			btn :: (id: string, ic: string, bg: ui.Color) -> bool {
				b := ui.box(id, .Clickable | .Draw_Background | .Hot_Animation);
				b.semantic_size = .[ui.px(66), ui.px(50)];
				b.style.radius = all4(8);
				b.style.bg = bg;
				b.style.bg_hot = with_alpha(bg, 0.85);
				b.layout_axis = .X;
				b.cross_align = .Center;
				clicked := ui.signal(b).clicked;
				{ ui.parent(b); defer ui.pop_parent();
					filler(.X);
					icon("i", ic, 20, .{1, 1, 1, 1});
					filler(.X);
				}
				return clicked;
			}
			if btn(L("Decline##decline"), "x-large", T("--status-danger")) { dc.call_decline(app.client, cid); }
			if btn(L("Join Call##join"), "phone-call", T("--status-positive")) { call_join_incoming(cid); }
		}
	}
}

#scope_file

Voice_App :: struct {
	client: *dc.Client; // The connection the call is on; null when none.
	conn: *voice.Conn;
	guild: dc.Snowflake;
	channel: dc.Snowflake; // channel the connection belongs to
	version: u64; // voice_server_info version we connected with
	sent_mute: bool;
	sent_deaf: bool;
	audio_ready: bool;
	headless: bool; // no audio devices (screenshots / CI never open the mic)
	auto_join: dc.Snowflake; // FASTCORD_JOIN_VOICE=<channel id>
	auto_checked: bool;
	synced: bool; // readies and voice_elsewhere below hold the store's values for this call
	readies: u64; // store().readies when we last sent op 4 for the call
	voice_elsewhere: u64; // store().voice_elsewhere when the call started
	seen_channel: dc.Snowflake; // our voice state's channel last frame (0: none, or not yet confirmed)
	backoff := dc.Backoff.{min_ms = 1000, max_ms = 10000, jitter = true, current = 1000}; // RTCConnection._backoff
	retry_at: s64; // no new connection before this (dc.now_ms)
	unconnected_since: s64; // dc.now_ms when the call lost (or had not yet) its RTC connection; 0 while connected
	speaking: Table(dc.Snowflake, bool); // this frame's speaking set
	rejoin: struct { // what a hang up left, for Rejoin (voice_hang_up)
		client: *dc.Client;
		guild, channel: dc.Snowflake;
		camera, screen: bool;
		target: video.Screen_Target;
		until: s64;
	};
	hand_raised: bool; // we raised our hand on this stage (else a raised hand is a moderator's invitation)
	info_open: bool; // the panel's connection info
	info_anchor: ui.Rect;
	restore_camera, restore_screen: bool; // Rejoin turns these back on once connected
	restore_target: video.Screen_Target;
}

vc: Voice_App;

voice_drop :: () {
	video_stop_all();
	if vc.conn != null {
		voice_release(vc.conn);
		vc.conn = null;
	}
	vc.channel = 0;
	vc.version = 0;
	vc.synced = false;
	vc.seen_channel = 0;
	vc.retry_at = 0;
	vc.unconnected_since = 0;
	dc.backoff_succeed(*vc.backoff);
	table_reset_keeping_memory(*vc.speaking);
}

// voice_rtc_state: our voice connection as the official RTCConnectionStore names it.
voice_rtc_state :: () -> dc.Rtc_State {
	if vc.conn == null { return .Awaiting_Endpoint; }
	st, _ := voice.state(vc.conn);
	if st == {
	case .Connecting; #through; case .Resuming;
		return .Connecting;
	case .Identifying;
		return .Authenticating;
	case .Discovering;
		return .Rtc_Connecting;
	case .Connected;
		return .Rtc_Connected;
	case .Disconnected;
		return .Disconnected;
	}
	return .Disconnected;
}

tone_phase: float64;

// Headless runs never open the mic; FASTCORD_VOICE_TEST_TONE=1 sends a 440 Hz
// tone instead (to exercise speaking indicators in screenshots).
voice_options :: (cl: *dc.Client) -> voice.Options {
	o := voice.Options.{no_audio_devices = vc.headless || !vc.audio_ready};
	o.hosted = hosted_voice(cl);
	add_video_options(*o, false);
	if o.no_audio_devices && env_var("FASTCORD_VOICE_TEST_TONE") == "1" {
		o.capture = (_: *void, out: []float32) -> int {
			for * out {
				it.* = 0.2 * cast(float32) sin(tone_phase);
				tone_phase += 2 * PI * 440 / 48000;
			}
			return out.count;
		};
	}
	return o;
}

is_stage :: (cid: dc.Snowflake) -> bool {
	ch := dc.channel_get(call_store(), cid);
	return ch != null && ch.kind == .Guild_Stage_Voice;
}
