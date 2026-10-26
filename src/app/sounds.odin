package app

import "core:strings"
import "fc:audio"
import dc "fc:discord"
import "fc:media"
import "fc:platform"

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

SOUND_VOLUME :: 0.4

// asset hashes from the web bundle ("./<name>.mp3" -> module -> n.p + "<hash>.mp3")
sound_asset :: proc(name: string) -> (string, bool) {
	switch name {
	case "message1":
		return "3ed22d14f3c30bc4", true
	case "deafen":
		return "529ff198eac567af", true
	case "undeafen":
		return "b150f03c89944403", true
	case "mute":
		return "2d3b4ba32c34c862", true
	case "unmute":
		return "e74c4a06134a20e4", true
	case "disconnect":
		return "dd0911025fe00b2e", true
	case "ptt_start":
		return "f5c8ec31889c5317", true
	case "ptt_stop":
		return "34b5969be3a063ba", true
	case "user_join":
		return "b135ff6c8e091b43", true
	case "user_leave":
		return "7b9a183742515fc2", true
	case "user_moved":
		return "4003230e4086b680", true
	case "reconnect":
		return "7dfc49b36dea3a6c", true
	case "halloween_message1":
		return "c269de500ca3cb7b", true
	case "halloween_deafen":
		return "514663b657bc4c7d", true
	case "halloween_undeafen":
		return "4dfa756a71484219", true
	case "halloween_mute":
		return "d5e69d2c2aac0a27", true
	case "halloween_unmute":
		return "6f0d538ed066a1a6", true
	case "halloween_disconnect":
		return "9b8ef0a59d731dd6", true
	case "halloween_user_join":
		return "00b48ea9fc787786", true
	case "halloween_user_leave":
		return "c9b6b9d1ef992f1b", true
	case "bit_message1":
		return "795109c70fe6ea7b", true
	case "bop_message1":
		return "909464bf55b13935", true
	case "ducky_message1":
		return "7d8709c9f90d5d1e", true
	case "lofi_message1":
		return "5aa5ffdc82cb3c74", true
	case "asmr_message1":
		return "7abbc45d8e7b179a", true
	case "discodo":
		return "cb85be48267eb1b4", true
	}
	return "", false
}

@(private = "file")
SOUND_TAG :: u64(0x5d0d_0000_0000_0000)

@(private = "file")
Sound_State :: enum u8 {
	Loading,
	Ready,
	Failed,
}

@(private = "file")
Sound :: struct {
	state: Sound_State,
	pcm:   []f32, // stereo 48 kHz
	play_when_ready: bool,
}

@(private = "file")
Playing :: struct {
	source: audio.Source,
	pcm:    []f32,
	pos:    int, // samples written
}

@(private = "file")
snd: struct {
	sounds:        map[string]^Sound, // by asset url
	playing:       [dynamic]Playing,
	soundpack:     string, // "" = classic
	disable_all:   bool,
	disabled:      [dynamic]string,
	// trigger state
	init:          bool,
	prev_mute:     bool,
	prev_deaf:     bool,
	prev_channel:  dc.Snowflake,
	members:       map[dc.Snowflake]bool, // others in our voice channel
	members_ch:    dc.Snowflake,
}

// ---- persistence ----

sounds_restore :: proc(p: ^Persisted_Sounds) {
	snd.soundpack = strings.clone(p.soundpack)
	snd.disable_all = p.disable_all
	for d in p.disabled do append(&snd.disabled, strings.clone(d))
}

sounds_snapshot :: proc(p: ^Persisted_Sounds) {
	p.soundpack = snd.soundpack if snd.soundpack != "" else "classic"
	p.disable_all = snd.disable_all
	p.disabled = snd.disabled[:]
}

sound_disabled :: proc(name: string) -> bool {
	if snd.disable_all do return true
	for d in snd.disabled do if d == name do return true
	return false
}

@(private = "file")
pack_name :: proc(name: string) -> string {
	// SOUNDPACKS[pack][name] ?? name (halloween covers voice + message sounds,
	// the novelty packs only message1)
	switch snd.soundpack {
	case "", "classic":
		return name
	case "halloween":
		switch name {
		case "message1", "deafen", "undeafen", "mute", "unmute", "disconnect", "user_join", "user_leave":
			return strings.concatenate({"halloween_", name}, context.temp_allocator)
		}
	case "retro":
		if name == "message1" do return "bit_message1"
	case "bop":
		if name == "message1" do return "bop_message1"
	case "ducky":
		if name == "message1" do return "ducky_message1"
	case "lofi":
		if name == "message1" do return "lofi_message1"
	case "asmr":
		if name == "message1" do return "asmr_message1"
	case "discodo":
		if name == "message1" do return "discodo"
	}
	return name
}

// sound_play: SoundUtils.playSound(name, 0.4). Loads on first use.
sound_play :: proc(name: string) {
	if platform.is_headless() || app.client == nil || sound_disabled(name) do return
	hash, ok := sound_asset(pack_name(name))
	if !ok do return
	url := strings.concatenate({"https://discord.com/assets/", hash, ".mp3"}, context.temp_allocator)
	s, have := snd.sounds[url]
	if !have {
		s = new(Sound)
		snd.sounds[strings.clone(url)] = s
		s.play_when_ready = true
		dc.fetch_media(app.client, dc.Media_Request{url = url, kind = .Audio, tag = SOUND_TAG})
		return
	}
	switch s.state {
	case .Loading:
		s.play_when_ready = true
	case .Ready:
		start(s)
	case .Failed:
	}
}

@(private = "file")
start :: proc(s: ^Sound) {
	if !audio.init() do return
	src := audio.source_create()
	if src == 0 do return
	audio.source_set_volume(src, SOUND_VOLUME)
	append(&snd.playing, Playing{source = src, pcm = s.pcm})
}

// sounds_receive: media results for sound assets (called from images_receive).
sounds_receive :: proc(r: ^dc.Media_Result) -> bool {
	s, ok := snd.sounds[r.url]
	if !ok do return false
	if (r.status != 200 && r.status != 206) || len(r.data) == 0 {
		s.state = .Failed
		return true
	}
	s.pcm = decode_mp3(r.data)
	s.state = .Ready if len(s.pcm) > 0 else .Failed
	if s.state == .Ready && s.play_when_ready do start(s)
	s.play_when_ready = false
	return true
}

@(private = "file")
decode_mp3 :: proc(data: []byte) -> []f32 {
	src := media.source_from_memory(data)
	d, st := media.demux_open(&src)
	if d == nil || st == .Error do return nil
	defer media.demux_destroy(d)
	for media.demux_scan(d) == .Progress {}
	track := -1
	for t, i in d.tracks do if t.kind == .Audio {
		track = i
		break
	}
	if track < 0 do return nil
	dec, ok := media.audio_decoder_create(&d.tracks[track])
	if !ok do return nil
	defer media.audio_decoder_destroy(dec)
	out := make([dynamic]f32)
	pkt := make([dynamic]u8, context.temp_allocator)
	for p in d.tracks[track].packets {
		if media.demux_read(d, p, &pkt) != .Ok do break
		media.audio_decode(dec, pkt[:], &out)
	}
	return out[:]
}

// ---- per frame ----

sounds_frame :: proc() {
	feed()
	if app.client == nil do return
	if !snd.init {
		snd.init = true
		snd.prev_mute = app.self_mute
		snd.prev_deaf = app.self_deaf
	}
	// deafen / mute (MediaEngine: deafen wins)
	if app.self_deaf != snd.prev_deaf {
		sound_play("deafen" if app.self_deaf else "undeafen")
	} else if app.self_mute != snd.prev_mute {
		sound_play("mute" if app.self_mute else "unmute")
	}
	snd.prev_mute = app.self_mute
	snd.prev_deaf = app.self_deaf
	// own connection start / end
	if app.voice_channel != snd.prev_channel {
		if app.voice_channel != 0 {
			sound_play("user_join")
		} else {
			sound_play("disconnect")
		}
		snd.prev_channel = app.voice_channel
	}
	voice_members()
	message_sounds()
}

@(private = "file")
feed :: proc() {
	for i := len(snd.playing) - 1; i >= 0; i -= 1 {
		p := &snd.playing[i]
		if p.pos < len(p.pcm) {
			n := audio.source_write(p.source, p.pcm[p.pos:])
			p.pos += n * 2
		}
		if p.pos >= len(p.pcm) && audio.source_queued_frames(p.source) == 0 {
			audio.source_destroy(p.source)
			ordered_remove(&snd.playing, i)
			continue
		}
		request_wake(platform.time_now() + 0.05)
	}
}

@(private = "file")
voice_members :: proc() {
	ch := app.voice_channel
	s := store()
	if ch != snd.members_ch {
		clear(&snd.members)
		snd.members_ch = ch
		if ch == 0 do return
		for uid, v in s.voice_states do if v.channel_id == ch && uid != s.me do snd.members[uid] = true
		return
	}
	if ch == 0 do return
	now := make(map[dc.Snowflake]bool, context.temp_allocator)
	for uid, v in s.voice_states do if v.channel_id == ch && uid != s.me do now[uid] = true
	joined, left := false, false
	for uid in now do if !snd.members[uid] do joined = true
	for uid in snd.members do if !now[uid] do left = true
	if joined do sound_play("user_join")
	else if left do sound_play("user_leave")
	clear(&snd.members)
	for uid in now do snd.members[uid] = true
}

// app_new_messages: this frame's MESSAGE_CREATEs from others (dc.take_new_messages,
// fed by the library's dispatch on the UI thread). Drained ONCE per frame and
// shared by every consumer (sounds, OS notifications): call this instead of
// dc.take_new_messages. Valid until the next frame.
app_new_messages :: proc() -> []dc.New_Message {
	@(static) frame: u64
	@(static) cur: []dc.New_Message
	if app.client == nil do return nil
	if frame != app.frame || cur == nil {
		if cur != nil {
			dc.new_messages_free(app.client, cur)
			delete(cur)
		}
		cur = dc.take_new_messages(app.client, context.allocator)
		frame = app.frame
	}
	return cur
}

// message_notifies: the client's notification rule for one message
// (message_notifications: 0 all, 1 only mentions, 2 nothing, 3 = guild default).
message_notifies :: proc(m: ^dc.New_Message) -> bool {
	s := store()
	if m.author_id == s.me || m.author_id == 0 do return false
	if m.guild_id == 0 do return true // DMs / group DMs
	level := 1
	if g := dc.guild_get(s, m.guild_id); g != nil do level = g.default_message_notifications
	if gs, has := s.guild_settings[m.guild_id]; has {
		if gs.muted do return false
		for c in gs.muted_channels do if c == m.channel_id do return false
		if gs.message_notifications <= 2 do level = gs.message_notifications
	}
	switch level {
	case 0:
		return true
	case 2:
		return false
	}
	if m.mentions_me || m.mention_everyone do return true
	if mem := dc.member_get(s, m.guild_id, s.me); mem != nil {
		for r in m.mention_roles do for mine in mem.roles do if mine == r do return true
	}
	return false
}

@(private = "file")
message_sounds :: proc() {
	s := store()
	for &m in app_new_messages() {
		if app.focused && m.channel_id == app.view.channel do continue // notifyMessagesInSelectedChannel: false
		if s.settings.status == .Dnd do continue
		if !message_notifies(&m) do continue
		sound_play("message1")
		break // one sound per frame
	}
}
