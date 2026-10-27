// UI sounds the way the official client plays them (WebAudioSound /
// SoundUtils in web.js): https://discord.com/assets/<hash>.mp3 loaded by an
// <audio> element (dc.Media_Kind.Audio: no-cors, dest audio, Range bytes=0-),
// volume = min(outputVolume/100 * 0.4, 1) (playSound default 0.4; output
// volume is applied by the audio master gain). Soundpacks (SoundpackStore,
// default "classic") remap names; NotificationSettingsStore defaults:
// disableAllSounds false, disabledSounds [].
//
// Triggers mirrored from the client's useSound hooks:
//   deafen/undeafen on self-deafen changes; mute/unmute on self-mute changes;
//   user_join when our voice connection starts, disconnect when it ends;
//   user_join/user_leave for others entering/leaving our voice channel;
//   ptt_start/ptt_stop on push-to-talk press/release (not while muted);
//   message1 for messages that would notify (DMs, mentions, guilds set to
//   all messages), except our own and the focused selected channel.

SOUND_VOLUME :: 0.4;

// asset hashes from the web bundle ("./<name>.mp3" -> module -> n.p + "<hash>.mp3")
sound_asset :: (name: string) -> string, bool {
	if name == {
	case "message1";
		return "3ed22d14f3c30bc4", true;
	case "deafen";
		return "529ff198eac567af", true;
	case "undeafen";
		return "b150f03c89944403", true;
	case "mute";
		return "2d3b4ba32c34c862", true;
	case "unmute";
		return "e74c4a06134a20e4", true;
	case "disconnect";
		return "dd0911025fe00b2e", true;
	case "ptt_start";
		return "f5c8ec31889c5317", true;
	case "ptt_stop";
		return "34b5969be3a063ba", true;
	case "user_join";
		return "b135ff6c8e091b43", true;
	case "user_leave";
		return "7b9a183742515fc2", true;
	case "user_moved";
		return "4003230e4086b680", true;
	case "reconnect";
		return "7dfc49b36dea3a6c", true;
	case "halloween_message1";
		return "c269de500ca3cb7b", true;
	case "halloween_deafen";
		return "514663b657bc4c7d", true;
	case "halloween_undeafen";
		return "4dfa756a71484219", true;
	case "halloween_mute";
		return "d5e69d2c2aac0a27", true;
	case "halloween_unmute";
		return "6f0d538ed066a1a6", true;
	case "halloween_disconnect";
		return "9b8ef0a59d731dd6", true;
	case "halloween_user_join";
		return "00b48ea9fc787786", true;
	case "halloween_user_leave";
		return "c9b6b9d1ef992f1b", true;
	case "bit_message1";
		return "795109c70fe6ea7b", true;
	case "bop_message1";
		return "909464bf55b13935", true;
	case "ducky_message1";
		return "7d8709c9f90d5d1e", true;
	case "lofi_message1";
		return "5aa5ffdc82cb3c74", true;
	case "asmr_message1";
		return "7abbc45d8e7b179a", true;
	case "discodo";
		return "cb85be48267eb1b4", true;
	}
	return "", false;
}
#scope_file

SOUND_TAG :: cast(u64)(0x5d0d_0000_0000_0000);

Sound_State :: enum u8 {
	Loading;
	Ready;
	Failed;
}

Sound :: struct {
	state: Sound_State;
	pcm: []float32; // stereo 48 kHz
	play_when_ready: bool;
}

Playing :: struct {
	source: audio.Source;
	pcm: []float32;
	pos: int; // samples written
}

snd: struct {
	sounds: Map(string, *Sound); // by asset url
	playing: [..]Playing;
	soundpack: string; // "" = classic
	disable_all: bool;
	disabled: [..]string;
	// trigger state
	init: bool;
	prev_mute: bool;
	prev_deaf: bool;
	prev_channel: dc.Snowflake;
	members: Map(dc.Snowflake, bool); // others in our voice channel
	members_ch: dc.Snowflake;
};
#scope_export

// ---- persistence ----

sounds_restore :: (p: *Persisted_Sounds) {
	snd.soundpack = clone(p.soundpack);
	snd.disable_all = p.disable_all;
	for d: p.disabled { append(*snd.disabled, clone(d)); }
}

sounds_snapshot :: (p: *Persisted_Sounds) {
	p.soundpack = ifx snd.soundpack != "" then snd.soundpack else "classic";
	p.disable_all = snd.disable_all;
	p.disabled = view(snd.disabled);
}

// Settings > Notifications > Sounds
sounds_all_disabled :: () -> bool {return snd.disable_all;}
sounds_set_all_disabled :: (on: bool) {snd.disable_all = on;}
sound_set_disabled :: (name: string, off: bool) {
	for d, i: snd.disabled {
		if d != name { continue; }
		if !off {
			delete(d);
			ordered_remove(*snd.disabled, i);
		}
		return;
	}
	if off { append(*snd.disabled, clone(name)); }
}
// one sound's own switch (ignores Disable All)
sound_own_disabled :: (name: string) -> bool {
	for d: snd.disabled { if d == name { return true; } }
	return false;
}
sounds_reset_prefs_for_test :: () {
	snd.disable_all = false;
	for d: snd.disabled { delete(d); }
	clear(*snd.disabled);
}

sound_disabled :: (name: string) -> bool {
	if snd.disable_all || streamer_disable_sounds() { return true; }
	for d: snd.disabled { if d == name { return true; } }
	return false;
}
#scope_file

pack_name :: (name: string) -> string {
	// SOUNDPACKS[pack][name] ?? name (halloween covers voice + message sounds,
	// the novelty packs only message1)
	if snd.soundpack == {
	case ""; #through; case "classic";
		return name;
	case "halloween";
		if name == {
		case "message1"; #through; case "deafen"; #through; case "undeafen"; #through; case "mute"; #through; case "unmute"; #through; case "disconnect"; #through; case "user_join"; #through; case "user_leave";
			return strings.concatenate(.{"halloween_", name}, temp);
		}
	case "retro";
		if name == "message1" { return "bit_message1"; }
	case "bop";
		if name == "message1" { return "bop_message1"; }
	case "ducky";
		if name == "message1" { return "ducky_message1"; }
	case "lofi";
		if name == "message1" { return "lofi_message1"; }
	case "asmr";
		if name == "message1" { return "asmr_message1"; }
	case "discodo";
		if name == "message1" { return "discodo"; }
	}
	return name;
}
#scope_export

// sound_play: SoundUtils.playSound(name, 0.4). Loads on first use.
sound_play :: (name: string) {
	if platform.is_headless() || app.client == null || sound_disabled(name) { return; }
	hash, ok := sound_asset(pack_name(name));
	if !ok { return; }
	url := strings.concatenate(.{"https://discord.com/assets/", hash, ".mp3"}, temp);
	s, have := map_find(snd.sounds, url);
	if !have {
		s = new(Sound);
		at(*snd.sounds, clone(url)).* = s;
		s.play_when_ready = true;
		dc.fetch_media(app.client, dc.Media_Request.{url = url, kind = .Audio, tag = SOUND_TAG});
		return;
	}
	if s.state == {
	case .Loading;
		s.play_when_ready = true;
	case .Ready;
		start(s);
	case .Failed;
	}
}
#scope_file

start :: (s: *Sound) {
	if !audio.init() { return; }
	src := audio.source_create();
	if src == 0 { return; }
	audio.source_set_volume(src, SOUND_VOLUME);
	append(*snd.playing, Playing.{source = src, pcm = s.pcm});
}
#scope_export

// sounds_receive: media results for sound assets (called from images_receive).
sounds_receive :: (r: *dc.Media_Result) -> bool {
	s, ok := map_find(snd.sounds, r.url);
	if !ok { return false; }
	if (r.status != 200 && r.status != 206) || len(r.data) == 0 {
		s.state = .Failed;
		return true;
	}
	s.pcm = decode_mp3(r.data);
	s.state = ifx len(s.pcm) > 0 then .Ready else .Failed;
	if s.state == .Ready && s.play_when_ready { start(s); }
	s.play_when_ready = false;
	return true;
}
#scope_file

decode_mp3 :: (data: []u8) -> []float32 {
	src := media.source_from_memory(data);
	d, st := media.demux_open(*src);
	if d == null || st == .Error { return .{}; }
	defer media.demux_destroy(d);
	while media.demux_scan(d) == .Progress {}
	track := -1;
	for t, i: d.tracks { if t.kind == .Audio {
		track = i;
		break;
	} }
	if track < 0 { return .{}; }
	dec, ok := media.audio_decoder_create(*d.tracks[track]);
	if !ok { return .{}; }
	defer media.audio_decoder_destroy(dec);
	out := make_dynamic(float32, 0, 0);
	pkt := make_dynamic(u8, 0, 0, temp);
	for p: d.tracks[track].packets {
		if media.demux_read(d, p, *pkt) != .Ok { break; }
		media.audio_decode(dec, view(pkt), *out);
	}
	return view(out);
}
#scope_export

// ---- per frame ----

sounds_frame :: () {
	feed();
	if app.client == null { return; }
	if !snd.init {
		snd.init = true;
		snd.prev_mute = app.self_mute;
		snd.prev_deaf = app.self_deaf;
	}
	// deafen / mute (MediaEngine: deafen wins)
	if app.self_deaf != snd.prev_deaf {
		sound_play(ifx app.self_deaf then "deafen" else "undeafen");
	} else if app.self_mute != snd.prev_mute {
		sound_play(ifx app.self_mute then "mute" else "unmute");
	}
	snd.prev_mute = app.self_mute;
	snd.prev_deaf = app.self_deaf;
	// own connection start / end
	if app.voice_channel != snd.prev_channel {
		if app.voice_channel != 0 {
			sound_play("user_join");
		} else {
			sound_play("disconnect");
		}
		snd.prev_channel = app.voice_channel;
	}
	voice_members();
	message_sounds();
}
#scope_file

feed :: () {
	for < i: len(snd.playing) - 1..0 {
		p := *snd.playing[i];
		if p.pos < len(p.pcm) {
			n := audio.source_write(p.source, sub_from(p.pcm, p.pos));
			p.pos += n * 2;
		}
		if p.pos >= len(p.pcm) && audio.source_queued_frames(p.source) == 0 {
			audio.source_destroy(p.source);
			ordered_remove(*snd.playing, i);
			continue;
		}
		request_wake(platform.time_now() + 0.05);
	}
}

voice_members :: () {
	ch := app.voice_channel;
	s := store();
	if ch != snd.members_ch {
		clear(*snd.members);
		snd.members_ch = ch;
		if ch == 0 { return; }
		for uid, v: s.voice_states { if v.channel_id == ch && uid != s.me { at(*snd.members, uid).* = true; } }
		return;
	}
	if ch == 0 { return; }
	now := Map(dc.Snowflake, bool).{};
	for uid, v: s.voice_states { if v.channel_id == ch && uid != s.me { at(*now, uid).* = true; } }
	joined, left := false, false;
	for uid: now { if !__MAPIDX__(snd.members|uid) { joined = true; } }
	for uid: snd.members { if !__MAPIDX__(now|uid) { left = true; } }
	if joined { sound_play("user_join"); } else if left { sound_play("user_leave"); }
	clear(*snd.members);
	for uid: now { at(*snd.members, uid).* = true; }
}
#scope_export

// app_new_messages: this frame's MESSAGE_CREATEs from others (dc.take_new_messages,
// fed by the library's dispatch on the UI thread). Drained ONCE per frame and
// shared by every consumer (sounds, OS notifications): call this instead of
// dc.take_new_messages. Valid until the next frame.
app_new_messages :: () -> []dc.New_Message {
	if app.client == null { return .{}; }
	if static_frame5 != app.frame || static_cur6 == null {
		if static_cur6 != null {
			dc.new_messages_free(app.client, static_cur6);
			delete(static_cur6);
		}
		static_cur6 = dc.take_new_messages(app.client, context.allocator);
		static_frame5 = app.frame;
	}
	return static_cur6;
}

// message_notifies: the client's notification rule for one message
// (message_notifications: 0 all, 1 only mentions, 2 nothing, 3 = guild default).
message_notifies :: (m: *dc.New_Message) -> bool {
	s := store();
	if m.author_id == s.me || m.author_id == 0 { return false; }
	if m.guild_id == 0 { return true; } // DMs / group DMs
	level := 1;
	{ g := dc.guild_get(s, m.guild_id);
	if g != null { level = g.default_message_notifications; } }
	{ gs, has := map_find(s.guild_settings, m.guild_id);
	if has {
		if gs.muted { return false; }
		for c: gs.muted_channels { if c == m.channel_id { return false; } }
		if gs.message_notifications <= 2 { level = gs.message_notifications; }
	} }
	if level == {
	case 0;
		return true;
	case 2;
		return false;
	}
	if m.mentions_me || m.mention_everyone { return true; }
	{ mem := dc.member_get(s, m.guild_id, s.me);
	if mem != null {
		for r: m.mention_roles { for mine: mem.roles { if mine == r { return true; } } }
	} }
	return false;
}
#scope_file

message_sounds :: () {
	s := store();
	for * m: app_new_messages() {
		if app.focused && m.channel_id == app.view.channel { continue; } // notifyMessagesInSelectedChannel: false
		if s.settings.status == .Dnd { continue; }
		if !message_notifies(*m) { continue; }
		sound_play("message1");
		break; // one sound per frame
	}
}
#scope_export

#scope_file static_frame5: u64; #scope_export
#scope_file static_cur6: []dc.New_Message; #scope_export

