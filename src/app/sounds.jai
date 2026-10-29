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
//   call_ringing looped while a call rings us; call_calling looped while our DM call rings others and no
//   one else has joined (IncomingCalls, the ring manager);
//   message1 for messages that would notify (DMs, mentions, guilds set to
//   all messages), except our own and the focused selected channel.

SOUND_VOLUME :: 0.4;

// asset hashes from the web bundle ("./<name>.mp3" -> module -> n.p + "<hash>.mp3")
sound_asset :: (name: string) -> string, bool {
	if name == {
	case "message1"; return "3ed22d14f3c30bc4", true;
	case "deafen"; return "529ff198eac567af", true;
	case "undeafen"; return "b150f03c89944403", true;
	case "mute"; return "2d3b4ba32c34c862", true;
	case "unmute"; return "e74c4a06134a20e4", true;
	case "disconnect"; return "dd0911025fe00b2e", true;
	case "ptt_start"; return "f5c8ec31889c5317", true;
	case "ptt_stop"; return "34b5969be3a063ba", true;
	case "user_join"; return "b135ff6c8e091b43", true;
	case "user_leave"; return "7b9a183742515fc2", true;
	case "user_moved"; return "4003230e4086b680", true;
	case "reconnect"; return "7dfc49b36dea3a6c", true;
	case "call_calling"; return "5146737af413d88e", true;
	case "call_ringing"; return "c2a7111bb44b8da0", true;
	case "halloween_call_calling"; return "ef24e229a3413c8a", true;
	case "halloween_call_ringing"; return "7a287e2f88531f25", true;
	case "halloween_message1"; return "c269de500ca3cb7b", true;
	case "halloween_deafen"; return "514663b657bc4c7d", true;
	case "halloween_undeafen"; return "4dfa756a71484219", true;
	case "halloween_mute"; return "d5e69d2c2aac0a27", true;
	case "halloween_unmute"; return "6f0d538ed066a1a6", true;
	case "halloween_disconnect"; return "9b8ef0a59d731dd6", true;
	case "halloween_user_join"; return "00b48ea9fc787786", true;
	case "halloween_user_leave"; return "c9b6b9d1ef992f1b", true;
	case "bit_message1"; return "795109c70fe6ea7b", true;
	case "bop_message1"; return "909464bf55b13935", true;
	case "ducky_message1"; return "7d8709c9f90d5d1e", true;
	case "lofi_message1"; return "5aa5ffdc82cb3c74", true;
	case "asmr_message1"; return "7abbc45d8e7b179a", true;
	case "discodo"; return "cb85be48267eb1b4", true;
	}
	return "", false;
}

// ---- persistence ----

sounds_restore :: (p: *Persisted_Sounds) {
	snd.soundpack = copy_string(p.soundpack);
	snd.disable_all = p.disable_all;
	for p.disabled array_add(*snd.disabled, copy_string(it));
}

sounds_snapshot :: (p: *Persisted_Sounds) {
	p.soundpack = ifx snd.soundpack != "" then snd.soundpack else "classic";
	p.disable_all = snd.disable_all;
	p.disabled = snd.disabled;
}

// Settings > Notifications > Sounds
sounds_all_disabled :: () -> bool { return snd.disable_all; }
sounds_set_all_disabled :: (on: bool) { snd.disable_all = on; }
sound_set_disabled :: (name: string, off: bool) {
	for snd.disabled {
		if it != name continue;
		if !off {
			free(it);
			array_ordered_remove_by_index(*snd.disabled, it_index);
		}
		return;
	}
	if off array_add(*snd.disabled, copy_string(name));
}
// one sound's own switch (ignores Disable All)
sound_own_disabled :: (name: string) -> bool { return array_find(snd.disabled, name); }
sounds_reset_prefs_for_test :: () {
	snd.disable_all = false;
	for snd.disabled free(it);
	array_reset_keeping_memory(*snd.disabled);
}

sound_disabled :: (name: string) -> bool {
	return snd.disable_all || notify_prefs.lotus || streamer_disable_sounds() || sound_own_disabled(name);
}

// sound_play: SoundUtils.playSound(name, 0.4). Loads on first use.
sound_play :: (name: string) {
	if sound_disabled(name) return;
	hash, ok := sound_asset(pack_name(name));
	if ok sound_play_url(tprint("https://discord.com/assets/%.mp3", hash), SOUND_VOLUME);
}

// sound_play_url: plays an mp3 or ogg file at volume (0..1, before the output volume), loading it on
// first use; with conn, through that call's mic as well (voice.mix_in).
sound_play_url :: (url: string, volume: float32, conn: *voice.Conn = null) {
	if platform.is_headless() || app.client == null || volume <= 0 return;
	found := table_find_pointer(*snd.sounds, url);
	if !found {
		s := New(Sound);
		s.ready_volume, s.ready_conn = volume, conn;
		table_set(*snd.sounds, copy_string(url), s);
		c := media_client(url);
		if c dc.fetch_media(c, dc.Media_Request.{url = url, kind = .Audio, tag = SOUND_TAG});
		return;
	}
	s := found.*;
	if s.state == .Loading s.ready_volume, s.ready_conn = volume, conn;
	else if s.state == .Ready start(s, volume, conn);
}

// sounds_receive: media results for sound assets (called from images_receive).
sounds_receive :: (r: *dc.Media_Result) -> bool {
	found := table_find_pointer(*snd.sounds, r.url);
	if !found return false;
	s := found.*;
	if (r.status != 200 && r.status != 206) || r.data.count == 0 {
		s.state = .Failed;
		return true;
	}
	s.pcm = media.decode_sound(r.data);
	s.state = ifx s.pcm.count > 0 then .Ready else .Failed;
	if s.state == .Ready && s.ready_volume > 0 start(s, s.ready_volume, s.ready_conn);
	s.ready_volume = 0;
	return true;
}

// ---- per frame ----

sounds_frame :: () {
	feed();
	if app.client == null return;
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
		sound_play(ifx app.voice_channel != 0 then "user_join" else "disconnect");
		snd.prev_channel = app.voice_channel;
	}
	voice_members();
	ring_sounds();
	message_sounds();
	soundboard_frame();
}

// app_new_messages: this frame's MESSAGE_CREATEs from others (dc.take_new_messages,
// fed by the library's dispatch on the UI thread). Drained ONCE per frame and
// shared by every consumer (sounds, OS notifications): call this instead of
// dc.take_new_messages. Valid until the next frame.
// Every connection's messages are gathered; judge each with message_client(m), not app.client.
app_new_messages :: () -> []dc.New_Message {
	if app.client == null return .[];
	if new_msgs_frame != app.frame || new_msgs.data == null {
		if new_msgs.data {
			dc.new_messages_free(app.client, new_msgs);
			array_free(new_msgs);
		}
		new_msgs = .[];
		for connections() {
			got := dc.take_new_messages(it, context.allocator);
			if !got.count continue;
			if !new_msgs.count { new_msgs = got; continue; }
			joined := NewArray(new_msgs.count + got.count, dc.New_Message);
			memcpy(joined.data, new_msgs.data, new_msgs.count * size_of(dc.New_Message));
			memcpy(joined.data + new_msgs.count, got.data, got.count * size_of(dc.New_Message));
			array_free(new_msgs);
			array_free(got);
			new_msgs = joined;
		}
		new_msgs_frame = app.frame;
	}
	return new_msgs;
}

// Discord's client (or the fixture's), then each logged-in self-hosted server's.
connections :: () -> []*dc.Client {
	out: [..]*dc.Client;
	out.allocator = temp;
	main := ifx app.discord then app.discord else app.client;
	if main array_add(*out, main);
	for hosted if it.client && it.client != main array_add(*out, it.client);
	return out;
}

// The connection a message came on.
message_client :: (m: *dc.New_Message) -> *dc.Client {
	for connections() if *it.store == m.store return it;
	return app.client;
}

// message_notifies: the client's shouldNotify for one message, shared by the message sound and desktop
// notifications: never for @silent messages or blocked or ignored authors, else dc.channel_notifies.
message_notifies :: (m: *dc.New_Message) -> bool {
	s := *message_client(m).store;
	if m.author_id == s.me || m.author_id == 0 return false;
	if m.flags & SUPPRESS_NOTIFICATIONS return false;
	r := table_find_pointer(*s.relationships, m.author_id);
	if r && (r.kind == .Blocked || r.ignored) return false;
	ch := dc.channel_get(s, m.channel_id);
	if ch && (ch.msg_request || ch.spam) return false; // message requests wait under Message Requests
	return dc.channel_notifies(s, m.guild_id, m.channel_id, app.view.channel, m.mentions_me, m.mention_everyone, m.mention_roles, wall_ms());
}

#scope_file

SOUND_TAG :: cast(u64) 0x5d0d_0000_0000_0000;

Sound_State :: enum u8 {
	Loading;
	Ready;
	Failed;
}

Sound :: struct {
	state: Sound_State;
	pcm: []float32; // stereo 48 kHz
	ready_volume: float32; // > 0: play at this volume once loaded
	ready_conn: *voice.Conn; // and through this call's mic (start checks it is still the call)
}

Playing :: struct {
	source: audio.Source;
	pcm: []float32;
	pos: int; // samples written
	loop: string; // a looped sound's name (ring_sounds), else ""
}

snd: struct {
	sounds: Table(string, *Sound); // by asset url
	playing: [..]Playing;
	soundpack: string; // "" = classic
	disable_all: bool;
	disabled: [..]string;
	// trigger state
	init: bool;
	prev_mute: bool;
	prev_deaf: bool;
	prev_channel: dc.Snowflake;
	members: Table(dc.Snowflake, bool); // others in our voice channel
	members_ch: dc.Snowflake;
};

// app_new_messages' current batch and the frame it was taken in
new_msgs_frame: u64;
new_msgs: []dc.New_Message;

pack_name :: (name: string) -> string {
	// SOUNDPACKS[pack][name] ?? name (halloween covers voice + message sounds,
	// the novelty packs only message1)
	if snd.soundpack == {
	case "halloween";
		if name == {
		case "message1"; #through; case "deafen"; #through; case "undeafen"; #through; case "mute"; #through;
		case "unmute"; #through; case "disconnect"; #through; case "user_join"; #through; case "user_leave"; #through;
		case "call_calling"; #through; case "call_ringing";
			return tprint("halloween_%", name);
		}
	case "retro";   if name == "message1" return "bit_message1";
	case "bop";     if name == "message1" return "bop_message1";
	case "ducky";   if name == "message1" return "ducky_message1";
	case "lofi";    if name == "message1" return "lofi_message1";
	case "asmr";    if name == "message1" return "asmr_message1";
	case "discodo"; if name == "message1" return "discodo";
	}
	return name;
}

start :: (s: *Sound, volume: float32, conn: *voice.Conn) {
	if conn && conn == voice_conn() {
		mono := NewArray(s.pcm.count / 2, float32,, temp);
		for * mono it.* = (s.pcm[it_index * 2] + s.pcm[it_index * 2 + 1]) * 0.5 * volume;
		voice.mix_in(conn, mono);
	}
	if !audio.init() return;
	src := audio.source_create();
	if src == 0 return;
	audio.source_set_volume(src, volume);
	array_add(*snd.playing, .{source = src, pcm = s.pcm});
}

feed :: () {
	for < i: 0..snd.playing.count - 1 {
		p := *snd.playing[i];
		if p.pos < p.pcm.count p.pos += audio.source_write(p.source, array_view(p.pcm, p.pos)) * 2;
		if p.loop && p.pos >= p.pcm.count p.pos = 0;
		if p.pos >= p.pcm.count && audio.source_queued_frames(p.source) == 0 {
			audio.source_destroy(p.source);
			array_ordered_remove_by_index(*snd.playing, i);
			continue;
		}
		request_wake(platform.time_now() + 0.05);
	}
}

// ring_sounds: the incoming ringtone while a call rings us, the outgoing one while our DM call rings
// others with no one else in it yet.
ring_sounds :: () {
	incoming := dc.incoming_call(app.client) != 0;
	outgoing := false;
	call := ifx app.voice_channel then dc.call_get(app.client, app.voice_channel) else null;
	if call && call.ringing.count {
		n := 0;
		for v: store().voice_states if v.channel_id == app.voice_channel n += 1;
		outgoing = n < 2;
	}
	for name: string.["call_ringing", "call_calling"] {
		want := ifx name == "call_ringing" then incoming else outgoing;
		if sound_disabled(name) want = false;
		at := -1;
		for snd.playing if it.loop == name at = it_index;
		if !want && at >= 0 {
			audio.source_destroy(snd.playing[at].source);
			array_ordered_remove_by_index(*snd.playing, at);
		}
		if !want || at >= 0 || platform.is_headless() continue;
		hash, ok := sound_asset(pack_name(name));
		if !ok continue;
		url := tprint("https://discord.com/assets/%.mp3", hash);
		found := table_find_pointer(*snd.sounds, url);
		if !found {
			// load it; it starts on a later frame once ready
			table_set(*snd.sounds, copy_string(url), New(Sound));
			c := media_client(url);
			if c dc.fetch_media(c, dc.Media_Request.{url = url, kind = .Audio, tag = SOUND_TAG});
		} else if found.*.state == .Ready {
			n := snd.playing.count;
			start(found.*, SOUND_VOLUME, null);
			if snd.playing.count > n peek_pointer(snd.playing).loop = name;
		}
	}
}

voice_members :: () {
	ch := app.voice_channel;
	s := store();
	if ch != snd.members_ch {
		table_reset_keeping_memory(*snd.members);
		snd.members_ch = ch;
		if ch == 0 return;
		for v, uid: s.voice_states if v.channel_id == ch && uid != s.me table_set(*snd.members, uid, true);
		return;
	}
	if ch == 0 return;
	now: Table(dc.Snowflake, bool);
	now.allocator = temp;
	for v, uid: s.voice_states if v.channel_id == ch && uid != s.me table_set(*now, uid, true);
	joined, left := false, false;
	for _, uid: now if !table_contains(*snd.members, uid) joined = true;
	for _, uid: snd.members if !table_contains(*now, uid) left = true;
	if joined sound_play("user_join");
	else if left sound_play("user_leave");
	table_reset_keeping_memory(*snd.members);
	for _, uid: now table_set(*snd.members, uid, true);
}

message_sounds :: () {
	s := *connections()[0].store; // Discord's: its status is the one you set.
	for * m: app_new_messages() {
		if app.focused && m.channel_id == app.view.channel && message_client(m) == app.client continue; // notifyMessagesInSelectedChannel: false
		if s.settings.status == .Dnd continue;
		if !message_notifies(m) continue;
		sound_play("message1");
		break; // one sound per frame
	}
}
