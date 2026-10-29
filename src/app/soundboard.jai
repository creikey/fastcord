// Soundboard: the voice panel's and the call view's soundboard button opens the picker (searchable;
// Favourites, this server's sounds, other servers' with Nitro, Discord's defaults). A click plays the
// sound to the call (dc.send_soundboard_sound) and here, or, with Voice & Video's "Play Soundboard
// Through My Mic", only mixes it into our microphone. Sounds others play (VOICE_CHANNEL_EFFECT_SEND)
// play here at their volume times Soundboard Volume. Other servers' sounds without Nitro are left out,
// never shown locked (no upsells).

sb: struct {
	open: bool;
	anchor: ui.Rect; // the button it opened from
	search: ui.Editor;
	focus: bool; // give the search field focus next frame
};

soundboard_toggle :: (anchor: ui.Rect) {
	sb.open = !sb.open;
	sb.anchor = anchor;
	if !sb.open return;
	ui.editor_set_text(*sb.search, "");
	sb.focus = true;
	// favourites live in FrecencyUserSettings (loadIfNecessary, as the pickers do)
	c := call_client();
	if c && !c.cfg.hosted.host dc.frecency_load(c);
}

// The soundboard button works while connected to a call (headless runs have no connection: always).
soundboard_available :: () -> bool {
	return app.voice_channel != 0 && (platform.is_headless() || (voice_conn() != null && voice.state(voice_conn()) == .Connected));
}

// sound_url: a sound's file, on the connection that has it.
sound_url :: (c: *dc.Client, id: dc.Snowflake) -> string {
	if c && c.cfg.hosted.host for hosted if it.client == c return tprint("https://%/soundboard-sounds/%", it.inv.id_hex, id);
	return dc.soundboard_url(id);
}

// soundboard_frame: sounds others played in our call. Not while deafened, nor from someone we muted.
soundboard_frame :: () {
	for c: connections() for e: dc.take_voice_effects(c) {
		if c != call_client() || e.channel_id != app.voice_channel || app.self_deaf continue;
		muted, _ := table_find(*vs.user_muted, e.user_id);
		if muted continue;
		if !e.sound_id { call_effect_show(e.user_id, .{id = e.emoji_id, animated = e.emoji_animated, name = to_string(e.emoji_name.data, e.emoji_len)}); continue; }
		sound_play_url(sound_url(c, e.sound_id), e.volume * vs.soundboard_volume / 100);
	}
}

soundboard_overlay :: () {
	if !sb.open return;
	if !soundboard_available() { sb.open = false; return; }
	for * e: app.ui.events if !e.consumed && e.kind == .Key_Down && e.key == .Escape {
		e.consumed = true;
		sb.open = false;
		return;
	}
	c := call_client();
	s := call_store();
	hosted_call := c && c.cfg.hosted.host != "";
	ch := dc.channel_get(s, app.voice_channel);
	gid := ifx ch then ch.guild_id else 0;
	perms := ifx gid then dc.channel_permissions(s, app.voice_channel) else dc.PERM_ALL;
	can_play := dc.has_permission(perms, dc.PERM_SPEAK | dc.PERM_USE_SOUNDBOARD) && !app.self_deaf;
	me := dc.user_get(s, s.me);
	external := me && me.premium_type != 0 && dc.has_permission(perms, dc.PERM_USE_EXTERNAL_SOUNDS) && !hosted_call;
	query := to_lower_copy(trim(ui.editor_text(*sb.search)),, temp);
	favs: []dc.Snowflake;
	if c favs = dc.soundboard_favorites(c);

	scrim := ui.box("sb_scrim", .Floating_X | .Floating_Y | .Overlay | .Clickable);
	scrim.semantic_size = .[ui.px(app.ui.window.x), ui.px(app.ui.window.y)];
	if ui.signal(scrim).pressed { sb.open = false; return; }
	W :: cast(float32) 440;
	H := min(cast(float32) 420, sb.anchor.y0 - 16);
	p := ui.box("soundboard", .Draw_Background | .Draw_Border | .Draw_Shadow | .Floating_X | .Floating_Y | .Overlay | .Clickable | .Clip);
	p.semantic_size = .[ui.px(W), ui.px(H)];
	p.fixed_pos = .{clamp(sb.anchor.x0, cast(float32) 8, app.ui.window.x - W - 8), max(cast(float32) 8, sb.anchor.y0 - H - 8)};
	p.layout_axis = .Y;
	p.style.bg = T("--background-surface-high");
	p.style.border = 1;
	p.style.border_color = T("--border-subtle");
	p.style.radius = all4(8);
	p.style.shadow_color = .{0, 0, 0, 0.3};
	p.style.shadow_blur = 16;
	ui.signal(p);
	ui.parent(p); defer ui.pop_parent();
	spacer(.Y, 12);
	srow := row("search_row");
	srow.semantic_size = .[ui.pct(1), ui.children()];
	{ ui.parent(srow); defer ui.pop_parent();
		spacer(.X, 12);
		box := row("search", .Draw_Background | .Draw_Border | .Clickable);
		box.semantic_size = .[ui.fill(), ui.children()];
		box.style.bg = T("--input-background-default");
		box.style.border_color = T("--input-border-default");
		box.style.border = 1;
		box.style.radius = all4(8);
		box.hover_cursor = .IBeam;
		if ui.signal(box).pressed || sb.focus app.ui.focus = box.key;
		sb.focus = false;
		{ ui.parent(box); defer ui.pop_parent();
			spacer(.X, 10);
			icon("mag", "magnifying-glass", 16, T("--icon-default"));
			spacer(.X, 8);
			text_field("f", *sb.search, "Search sounds", app.ui.focus == box.key, 14, 18, 7);
			spacer(.X, 10);
		}
		spacer(.X, 12);
	}
	spacer(.Y, 8);
	list := ui.box("sounds", .Scroll_Y | .Clip);
	list.semantic_size = .[ui.pct(1), ui.fill()];
	list.layout_axis = .Y;
	list.scrollbar = .Auto;
	ui.signal(list);
	ui.parent(list); defer ui.pop_parent();

	matches :: (snd: *dc.Soundboard_Sound, query: string) -> bool {
		return !query || contains(to_lower_copy(snd.name,, temp), query);
	}
	shown := 0;
	// Favourites: the ones we may play here, in the order they were added
	fav_list: [..]*dc.Soundboard_Sound;
	fav_list.allocator = temp;
	for favs {
		snd := dc.soundboard_sound(s, it);
		if snd && (snd.guild_id == 0 || snd.guild_id == gid || external) && matches(snd, query) array_add(*fav_list, snd);
	}
	shown += section("Favorites", "star", 0, fav_list, favs, can_play);
	order: [..]dc.Snowflake;
	order.allocator = temp;
	if gid array_add(*order, gid);
	if external for guild_order() if it != gid array_add(*order, it);
	for g: order {
		sounds: [..]*dc.Soundboard_Sound;
		sounds.allocator = temp;
		for dc.soundboard_list(s, g) if matches(it, query) array_add(*sounds, it);
		guild := dc.guild_get(s, g);
		shown += section(ifx guild then guild.name else "Server", "", g, sounds, favs, can_play);
	}
	defaults: [..]*dc.Soundboard_Sound;
	defaults.allocator = temp;
	for dc.soundboard_list(s, 0) if matches(it, query) array_add(*defaults, it);
	shown += section("Default", "music", 0, defaults, favs, can_play);
	if !shown {
		r := row("empty");
		r.semantic_size = .[ui.pct(1), ui.px(64)];
		ui.parent(r); defer ui.pop_parent();
		filler(.X);
		label(ifx query then "No sounds found" else "Loading sounds…", .Medium, 14, T("--text-muted"), 18);
		filler(.X);
	}
	spacer(.Y, 12);
}

#scope_file

SB_COLUMNS :: 3;
SB_BUTTON_H :: 40;

// section: a header and the sounds in rows of three; returns how many it showed.
section :: (title: string, icon_name: string, guild_id: dc.Snowflake, sounds: []*dc.Soundboard_Sound, favs: []dc.Snowflake, can_play: bool) -> int {
	if !sounds.count return 0;
	ui.id_scope(get_hash(title) ^ cast(u64) guild_id); defer ui.pop_seed();
	h := row("hdr");
	h.semantic_size = .[ui.pct(1), ui.px(32)];
	{ ui.parent(h); defer ui.pop_parent();
		spacer(.X, 16);
		g := dc.guild_get(call_store(), guild_id);
		if g && g.icon {
			gi := ui.box("gi");
			gi.semantic_size = .[ui.px(16), ui.px(16)];
			gi.style.radius = all4(8);
			set_remote_image(gi, guild_icon_url(guild_id, g.icon, 32), cover = true);
			spacer(.X, 8);
		} else if icon_name {
			icon("ic", icon_name, 16, T("--text-muted"));
			spacer(.X, 8);
		}
		label(to_upper_copy(title,, temp), .Semibold, 12, T("--text-muted"), 16);
	}
	for i: 0..(sounds.count + SB_COLUMNS - 1) / SB_COLUMNS - 1 {
		r := row(tprint("r%", i));
		r.semantic_size = .[ui.pct(1), ui.px(SB_BUTTON_H + 8)];
		ui.parent(r); defer ui.pop_parent();
		spacer(.X, 12);
		for c: 0..SB_COLUMNS - 1 {
			k := i * SB_COLUMNS + c;
			if k >= sounds.count { filler(.X); continue; }
			sound_button(sounds[k], array_find(favs, sounds[k].id), can_play && sounds[k].available);
			if c < SB_COLUMNS - 1 spacer(.X, 8);
		}
		spacer(.X, 12);
	}
	spacer(.Y, 4);
	return sounds.count;
}

sound_button :: (snd: *dc.Soundboard_Sound, fav: bool, enabled: bool) {
	c := call_client();
	ui.id_scope(cast(u64) snd.id); defer ui.pop_seed();
	b := row("snd", ifx enabled then ui.Box_Flags.Clickable | .Draw_Background | .Hot_Animation else .Draw_Background);
	b.semantic_size = .[ui.fill(), ui.px(SB_BUTTON_H)];
	b.style.radius = all4(8);
	b.style.bg = T("--background-mod-subtle");
	b.style.bg_hot = T("--background-mod-normal");
	b.cross_align = .Center;
	sig := ui.signal(b);
	text_col := ifx enabled then T("--interactive-text-default") else T("--text-muted");
	preview, star: ui.Signal;
	{ ui.parent(b); defer ui.pop_parent();
		spacer(.X, 10);
		if snd.emoji_id || snd.emoji_name emoji_box("e", .{id = snd.emoji_id, name = snd.emoji_name}, 20);
		else icon("e", "music", 18, text_col);
		spacer(.X, 8);
		m := app.ui.mouse;
		hover := m.x >= b.rect.x0 && m.x < b.rect.x1 && m.y >= b.rect.y0 && m.y < b.rect.y1 && enabled;
		room := cast(float32) (440 - 24 - 16) / SB_COLUMNS - 46 - (ifx hover then 44.0 else 0);
		label(ellipsize(snd.name, .Medium, 14, room), .Medium, 14, text_col, 18);
		filler(.X);
		if hover {
			pv := ui.box("preview", .Clickable);
			pv.semantic_size = .[ui.px(20), ui.px(20)];
			preview = ui.signal(pv);
			set_icon(pv, "play", ifx preview.hovering then T("--interactive-icon-hover") else T("--interactive-icon-default"));
			spacer(.X, 4);
		}
		loaded := c && c.store.frecency.loaded;
		if (hover && loaded) || fav {
			st := ui.box("star", ifx loaded then ui.Box_Flags.Clickable else 0);
			st.semantic_size = .[ui.px(18), ui.px(18)];
			star = ui.signal(st);
			set_icon(st, "star", ifx fav then T("--status-warning") else ifx star.hovering then T("--interactive-icon-hover") else T("--interactive-icon-default"));
		}
		spacer(.X, 8);
	}
	vol := snd.volume * vs.soundboard_volume / 100;
	url := sound_url(c, snd.id);
	if star.clicked {
		if net_action() && c dc.soundboard_set_favorite(c, snd.id, !fav);
	} else if preview.clicked {
		sound_play_url(url, vol); // a preview plays only here
	} else if sig.clicked && enabled {
		if vs.soundboard_mic {
			sound_play_url(url, vol, voice_conn());
		} else {
			if net_action() && c dc.send_soundboard_sound(c, app.voice_channel, snd);
			sound_play_url(url, vol);
		}
	}
}
