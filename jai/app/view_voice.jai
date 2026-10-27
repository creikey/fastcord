// Voice: owns the fc:voice connection for the channel in app.voice_channel.
//   join_voice (views.odin) sends op 4 and sets app.voice_channel;
//   voice_frame (every frame) connects once VOICE_STATE_UPDATE +
//   VOICE_SERVER_UPDATE arrived, reconnects when the server moves (new
//   voice_server_info version), mirrors mute/deafen to the connection and
//   op 4, and tears down on leave / terminal close codes.
//   voice_panel draws the "Voice Connected" section above the user panel.

VOICE_PANEL_H :: 56;
#scope_file

Voice_App :: struct {
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
	speaking: Map(dc.Snowflake, bool); // this frame's speaking set
}

vc: Voice_App;
#scope_export

voice_set_headless :: (h: bool) {vc.headless = h;}

// voice_join_channel: op 4 join (or move) and remember the guild for later op 4s.
voice_join_channel :: (gid: dc.Snowflake, cid: dc.Snowflake) {
	if !net_action() { return; }
	if app.voice_channel == cid { return; }
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
		voice_leave_channel();
		return;
	}
	if !net_action() { return; }
	if app.voice_channel == ch.id { return; }
	vc.guild = 0;
	app.voice_channel = ch.id;
	dc.dm_call_start(app.client, ch.id, app.self_mute || app.self_deaf, app.self_deaf);
	vc.sent_mute = app.self_mute;
	vc.sent_deaf = app.self_deaf;
}

// The incoming call's "Join Call" (op 4 into the DM, like the caller's).
call_join_incoming :: (cid: dc.Snowflake) {
	if !net_action() { return; }
	vc.guild = 0;
	app.voice_channel = cid;
	dc.call_accept(app.client, cid, app.self_mute || app.self_deaf, app.self_deaf);
	vc.sent_mute = app.self_mute;
	vc.sent_deaf = app.self_deaf;
}

voice_leave_channel :: () {
	if app.client != null && app.voice_channel != 0 { dc.voice_leave(app.client); }
	app.voice_channel = 0;
	voice_drop();
}
#scope_file

voice_drop :: () {
	if vc.conn != null {
		voice_release(vc.conn);
		vc.conn = null;
	}
	vc.channel = 0;
	vc.version = 0;
	clear(*vc.speaking);
}
#scope_export

voice_shutdown :: () {
	voice_drop();
	delete(vc.speaking);
}
#scope_file

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
#scope_export

voice_frame :: () {
	voice_settings_frame(vc.conn, vc.headless, vc.audio_ready);
	if app.client == null { return; }
	if !vc.auto_checked && app.client.store.ready {
		vc.auto_checked = true;
		{ v := os.get_env("FASTCORD_JOIN_VOICE", temp);
		if v != "" {
			id, _ := strconv.parse_u64(v);
			{ ch := dc.channel_get(store(), cast(dc.Snowflake)(id));
			if ch != null { voice_join_channel(ch.guild_id, ch.id); } }
		} }
	}
	if app.voice_channel == 0 {
		if vc.conn != null { voice_drop(); }
		dc.client_set_rtc_state(app.client, .Disconnected);
		return;
	}
	// mute / deafen -> connection + op 4 (deafen implies mute, like the client)
	if app.self_mute != vc.sent_mute || app.self_deaf != vc.sent_deaf {
		vc.sent_mute = app.self_mute;
		vc.sent_deaf = app.self_deaf;
		dc.voice_join(app.client, vc.guild, app.voice_channel, app.self_mute || app.self_deaf, app.self_deaf);
	}
	if vc.conn != null {
		voice.set_self_mute(vc.conn, app.self_mute || app.self_deaf);
		voice.set_self_deaf(vc.conn, app.self_deaf);
	}

	info, ver, ok := dc.voice_server_info(app.client);
	// Channel move or server migration: drop the old connection, then connect once its teardown is done.
	if ok && vc.conn != null && ver != vc.version && cast(dc.Snowflake)(info.channel_id) == app.voice_channel { voice_drop(); }
	if ok && vc.conn == null && !teardown_busy() && cast(dc.Snowflake)(info.channel_id) == app.voice_channel {
		if !vc.headless {
			// opening the microphone asks the OS for it (permissions_requested)
			dc.analytics_permissions_requested(app.client, "audio");
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
			user_agent = app.client.id.platform.browser_user_agent,
			accept_language = app.client.id.platform.accept_language
		}, voice_options());
		vc.version = ver;
		vc.channel = app.voice_channel;
		voice.set_self_mute(vc.conn, app.self_mute || app.self_deaf);
		voice.set_self_deaf(vc.conn, app.self_deaf);
	}
	dc.client_set_rtc_state(app.client, voice_rtc_state()); // client_rtc_state while in voice
	if vc.conn != null {
		st, code := voice.state(vc.conn);
		if st == .Disconnected {
			voice_release(vc.conn);
			vc.conn = null;
			if code == {
			case voice.CLOSE_DISCONNECTED; #through; case voice.CLOSE_CALL_TERMINATED; #through; case voice.CLOSE_AUTHENTICATION_FAILED;
				// kicked / moved out / call ended: we are no longer in the channel
				app.voice_channel = 0;
			case;
				// the next VOICE_SERVER_UPDATE (new version) reconnects; until then retry once
				vc.version = 0;
			}
		}
	}
	clear(*vc.speaking);
	if vc.conn != null {
		for id: voice.speaking_users(vc.conn, temp) { at(*vc.speaking, cast(dc.Snowflake)(id)).* = true; }
		// speaking rings and the ping readout change without input events
		request_wake(platform.time_now() + 0.1);
	}
}
#scope_file

tone_phase: float64;

// Headless runs never open the mic; FASTCORD_VOICE_TEST_TONE=1 sends a 440 Hz
// tone instead (to exercise speaking indicators in screenshots).
voice_options :: () -> voice.Options {
	o := voice.Options.{no_audio_devices = vc.headless || !vc.audio_ready};
	if o.no_audio_devices && os.get_env("FASTCORD_VOICE_TEST_TONE", temp) == "1" {
		o.capture = (_: *void, out: []float32) -> int {
			for i: 0..len(out)-1 {
				at(*out, i).* = 0.2 * cast(float32)(math.sin(tone_phase));
				tone_phase += 2 * math.PI * 440 / 48000;
			}
			return len(out);
		};
	}
	return o;
}

is_stage :: (cid: dc.Snowflake) -> bool {
	ch := dc.channel_get(store(), cid);
	return ch != null && ch.kind == .Guild_Stage_Voice;
}
#scope_export

voice_is_speaking :: (uid: dc.Snowflake) -> bool {return get(vc.speaking, uid);}

voice_panel_height :: () -> float32 {return ifx app.voice_channel != 0 then cast(float32) VOICE_PANEL_H else 0;}

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
	s := store();
	p := row("voicepanel");
	p.semantic_size = .[ui.pct(1), ui.px(VOICE_PANEL_H)];
	status := "RTC Connecting";
	color := T("--text-feedback-warning");
	sig_icon := "connection-unknown";
	ping := -1;
	e2ee := false;
	if vc.conn != null {
		st, _ := voice.state(vc.conn);
		stats := voice.get_stats(vc.conn);
		ping = ifx stats.rtt_ms > 0 then stats.rtt_ms else stats.ws_ping_ms;
		if ping <= 0 { ping = -1; } // no heartbeat ack / RTCP round trip yet
		e2ee = voice.e2ee_status(vc.conn, temp).active;
		if st == {
		case .Connected;
			status = "Voice Connected";
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
			status = "Voice Disconnected";
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
		{ ui.parent(info); defer ui.pop_parent();
			spacer(.X, 6);
			icon("sig", sig_icon, 20, color);
			spacer(.X, 8);
			col := ui.box("text");
			col.semantic_size = .[ui.fill(), ui.children()];
			{ ui.parent(col); defer ui.pop_parent();
				label(status, .Semibold, 14, color, 18);
				where_ := "Voice";
				{ ch := dc.channel_get(s, app.voice_channel);
				if ch != null {
					if ch.guild_id != 0 {
						gname := "";
						{ g := dc.guild_get(s, ch.guild_id);
						if g != null { gname = g.name; } }
						where_ = strings.concatenate(string.[ch.name, " / ", gname], temp);
					} else {
						where_ = dm_name(ch);
					}
				} }
				t := label(where_, .Normal, 12, T("--text-muted"), 14);
				t.flags |= .Clip;
			}
		}
		if isig.hovering {
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
				text := ifx ping > 0 then fmt.tprintf("Ping: %d ms", ping) else "Ping: measuring…";
				if e2ee { text = strings.concatenate(string.[text, " · End-to-end encrypted"], temp); }
				label(text, .Semibold, 14, T("--text-strong"), 18);
				spacer(.X, 12);
			}
		}
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
		if dsig.clicked {
			if app.client != null { dc.analytics_call_disconnect(app.client, vc.guild, app.voice_channel); }
			voice_leave_channel();
		}
		spacer(.X, 8);
	}
	div := ui.box("div", .Draw_Background);
	div.semantic_size = .[ui.pct(1), ui.px(1)];
	div.style.bg = T("--border-subtle");
}

voice_reset_for_test :: () {vc = .{headless = true};}

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
	{ call := dc.call_get(app.client, cid);
	if call != null {
		for uid, vs: store().voice_states { if vs.channel_id == cid && uid != store().me {caller = uid; break;} }
	} }
	if caller == 0 && len(ch.recipient_ids) > 0 { caller = ch.recipient_ids[0]; }
	W :: cast(float32)(234);
	H :: cast(float32)(270);
	area_x := cast(float32)(72 + 240);
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
		label("Incoming Call...", .Normal, 16, T("--text-default"), 20);
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
			if btn("Decline##decline", "x-large", T("--status-danger")) { dc.call_decline(app.client, cid); }
			if btn("Join Call##join", "phone-call", T("--status-positive")) { call_join_incoming(cid); }
		}
	}
}

