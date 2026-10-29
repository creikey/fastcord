// Soundboard (SoundboardStore and its action creators in the web bundle):
//   GET  /soundboard-default-sounds -> [{name, sound_id, volume, emoji_id, emoji_name, available}]
//        and op 31 {guild_ids} -> SOUNDBOARD_SOUNDS {guild_id, soundboard_sounds} per guild, both on
//        the session's first RTC_CONNECTED (voice_rtc_changed); a self-hosted server lists its sounds
//        in READY's guild instead.
//   GUILD_SOUNDBOARD_SOUND_CREATE / _UPDATE (a sound), _DELETE {sound_id, guild_id},
//   GUILD_SOUNDBOARD_SOUNDS_UPDATE {guild_id, soundboard_sounds}
//   POST /channels/{id}/send-soundboard-sound {sound_id[, source_guild_id]}: Discord plays it to the
//        channel; the others get VOICE_CHANNEL_EFFECT_SEND {channel_id, user_id, sound_id, sound_volume}.
//   Server Settings: GET /guilds/{id}/soundboard-sounds -> {items}, POST (name, sound data URI, volume,
//        emoji_id, emoji_name), PATCH and DELETE /guilds/{id}/soundboard-sounds/{sound}.
//   The file: https://cdn.discordapp.com/soundboard-sounds/{sound} (mp3 or ogg).
//   Favourites: FrecencyUserSettings field 8 favorite_soundboard_sounds {1 repeated fixed64}.

Soundboard_Sound :: struct {
	id: Snowflake;
	guild_id: Snowflake; // 0: one of Discord's default sounds
	user_id: Snowflake; // who added it
	name: string;
	emoji_id: Snowflake;
	emoji_name: string;
	volume: float32; // 0..1
	available: bool;
}

// A VOICE_CHANNEL_EFFECT_SEND with a sound, waiting for the app to play it.
Voice_Effect :: struct {
	channel_id: Snowflake;
	user_id: Snowflake;
	sound_id: Snowflake;
	volume: float32;
}

SOUNDBOARD_MAX_BYTES :: 512 * 1024; // Discord's cap per sound file
SOUNDBOARD_MAX_SECONDS :: 5.2;
SOUNDBOARD_MAX_PER_GUILD :: 500; // more than Discord's largest slot count (48); anything past it is dropped
SOUNDBOARD_MAX_EFFECTS :: 32; // queued and not yet played
SOUNDBOARD_FAVORITES_TAG :: 3; // Rest_Result.tag of the favourites PATCH (FRECENCY_SETTINGS_TYPE is 2)

soundboard_sound :: (s: *Store, id: Snowflake) -> *Soundboard_Sound {
	for * s.soundboard if it.id == id return it;
	return null;
}

// soundboard_list: a guild's sounds (0: the default ones), in the server's order (temp).
soundboard_list :: (s: *Store, guild_id: Snowflake) -> []*Soundboard_Sound {
	out: [..]*Soundboard_Sound;
	out.allocator = temp;
	for * s.soundboard if it.guild_id == guild_id array_add(*out, it);
	return out;
}

// soundboard_url: the sound's file on Discord's CDN.
soundboard_url :: (id: Snowflake) -> string { return tprint("https://cdn.discordapp.com/soundboard-sounds/%", id); }

// send_soundboard_sound: play a sound to the voice channel we are in.
send_soundboard_sound :: (c: *Client, channel_id: Snowflake, snd: *Soundboard_Sound) {
	w: Json;
	json_init(*w);
	json_obj(*w);
	json_ksnow(*w, "sound_id", snd.id);
	if snd.guild_id json_ksnow(*w, "source_guild_id", snd.guild_id);
	json_obj_end(*w);
	j := job_new(.Api, .None);
	j.method = "POST";
	j.path = job_str(j, tprint("/channels/%/send-soundboard-sound", channel_id));
	j.body = cast([]u8) job_str(j, json_string(*w));
	j.content_type = "application/json";
	job_submit(c, j);
}

// soundboard_fetch_guild: GET /guilds/{id}/soundboard-sounds (Server Settings > Soundboard).
soundboard_fetch_guild :: (c: *Client, guild_id: Snowflake) {
	j := job_new(.Api, .Soundboard);
	j.method = "GET";
	j.path = job_str(j, tprint("/guilds/%/soundboard-sounds", guild_id));
	j.result.tag = guild_id;
	job_submit(c, j);
}

// soundboard_fetch_default: GET /soundboard-default-sounds.
soundboard_fetch_default :: (c: *Client) {
	j := job_new(.Api, .Soundboard);
	j.method = "GET";
	j.path = "/soundboard-default-sounds";
	job_submit(c, j);
}

// take_voice_effects: the sounds others played since the last call (UI thread).
take_voice_effects :: (c: *Client, allocator := temp) -> []Voice_Effect {
	out := array_copy(c.store.effects,, allocator);
	c.store.effects.count = 0;
	return out;
}

// Upload, edit and delete (Server Settings > Soundboard). Results come back through feature_take.
// The file is read and checked on the feature worker (file_job_body).
soundboard_upload :: (c: *Client, guild_id: Snowflake, path: string, name: string, emoji_name: string, emoji_id: Snowflake, volume: float32) {
	feature_submit(c, .Sound_Upload, "POST", tprint("/guilds/%/soundboard-sounds", guild_id), soundboard_fields(name, emoji_name, emoji_id, volume), channel_id = guild_id, file = path);
}

soundboard_edit :: (c: *Client, guild_id: Snowflake, sound_id: Snowflake, name: string, emoji_name: string, emoji_id: Snowflake, volume: float32) {
	w: Json;
	json_init(*w);
	json_obj(*w);
	json_raw(*w, soundboard_fields(name, emoji_name, emoji_id, volume));
	json_obj_end(*w);
	feature_submit(c, .Sound_Edit, "PATCH", tprint("/guilds/%/soundboard-sounds/%", guild_id, sound_id), json_string(*w), channel_id = guild_id, tag = sound_id);
}

soundboard_delete :: (c: *Client, guild_id: Snowflake, sound_id: Snowflake) {
	feature_submit(c, .Sound_Delete, "DELETE", tprint("/guilds/%/soundboard-sounds/%", guild_id, sound_id), channel_id = guild_id, tag = sound_id);
}

// soundboard_fields: the members of the create / edit body other than the file, without braces (temp).
soundboard_fields :: (name: string, emoji_name: string, emoji_id: Snowflake, volume: float32) -> string {
	w: Json;
	json_init(*w);
	json_kstr(*w, "name", name);
	json_key(*w, "volume");
	json_raw(*w, tprint("%", formatFloat(clamp(volume, 0, 1), trailing_width = 2, zero_removal = .ONE_ZERO_AFTER_DECIMAL)));
	if emoji_id json_ksnow(*w, "emoji_id", emoji_id);
	else json_knull(*w, "emoji_id");
	if emoji_name && !emoji_id json_kstr(*w, "emoji_name", emoji_name);
	else json_knull(*w, "emoji_name");
	return json_string(*w);
}

// sound_mime: the type of a sound file Discord takes, by its magic bytes ("" for anything else).
sound_mime :: (data: []u8) -> string {
	head := cast(string) data;
	if begins_with(head, "OggS") return "audio/ogg";
	if begins_with(head, "ID3") return "audio/mpeg";
	if data.count >= 2 && data[0] == 0xFF && (data[1] & 0xE0) == 0xE0 return "audio/mpeg"; // an MPEG frame sync
	return "";
}

// ---- favourites (FrecencyUserSettings field 8) ----

// soundboard_favorites: the favourite sound IDs from the loaded frecency proto (temp; none until loaded).
soundboard_favorites :: (c: *Client) -> []Snowflake {
	f := *c.store.frecency;
	if !f.loaded return .[];
	raw, ok := base64_decode(f.proto,, temp);
	if !ok return .[];
	fav, fok := protobuf.find(cast([]u8) raw, 8);
	if !fok return .[];
	ids, iok := protobuf.find(fav.bytes, 1);
	if !iok return .[];
	return protobuf.packed_fixed64(ids.bytes,, temp);
}

// soundboard_set_favorite: PATCH settings-proto/2 with only field 8, the whole new list; the response
// is the full proto, which replaces the loaded one.
soundboard_set_favorite :: (c: *Client, id: Snowflake, on: bool) {
	if !c.store.frecency.loaded return;
	ids: [..]Snowflake;
	ids.allocator = temp;
	for soundboard_favorites(c) if it != id array_add(*ids, it);
	if on array_add(*ids, id);
	packed: [..]u8;
	packed.allocator = temp;
	for ids for b: 0..7 array_add(*packed, cast(u8) ((it >> (8 * b)) & 0xFF));
	inner := pb_new();
	protobuf.write_bytes(*inner, 1, packed);
	root := pb_new();
	pb_msg(*root, 8, inner);
	w: Json;
	json_init(*w);
	json_obj(*w);
	json_kstr(*w, "settings", base64_encode(cast(string) root.buf,, temp));
	json_obj_end(*w);
	j := job_new(.Api, .Settings);
	j.result.tag = SOUNDBOARD_FAVORITES_TAG;
	j.method = "PATCH";
	j.path = "/users/@me/settings-proto/2";
	j.body = cast([]u8) job_str(j, json_string(*w));
	j.content_type = "application/json";
	job_submit(c, j);
	// shown at once; the response confirms it
	push_allocator(c.store.allocator);
	free_str(c.store.frecency.proto, c.store.allocator);
	c.store.frecency.proto = copy_string(base64_encode(cast(string) frecency_with_favorites(c, root.buf),, temp));
}

#scope_file

// frecency_with_favorites: the loaded proto with field 8 replaced by fav (a whole field 8 record, temp).
frecency_with_favorites :: (c: *Client, fav: []u8) -> []u8 {
	raw, _ := base64_decode(c.store.frecency.proto,, temp);
	out: [..]u8;
	out.allocator = temp;
	r := protobuf.Reader.{buf = cast([]u8) raw};
	while true {
		start := r.pos;
		f, ok := protobuf.next(*r);
		if !ok break;
		if f.num != 8 array_add(*out, ..array_view(r.buf, start, r.pos - start));
	}
	array_add(*out, ..fav);
	return out;
}

#scope_module

// ---- store side (UI thread, store allocator pushed) ----

// parse_sound: one sound object; false when it is malformed.
parse_sound :: (s: *Store, m: etf.Map, guild_hint: Snowflake) -> Soundboard_Sound, bool {
	id := fsnow(m, "sound_id");
	name := fstr(m, "name");
	if !id || !name || name.count > 64 return .{}, false;
	gid := ifx vhas(m, "guild_id") then fsnow(m, "guild_id") else guild_hint;
	vol := cast(float32) vf64(vget(m, "volume"));
	if !vhas(m, "volume") vol = 1;
	emoji := fstr(m, "emoji_name");
	if emoji.count > 64 emoji = "";
	return .{
		id = id, guild_id = gid, user_id = fsnow(m, "user_id"),
		name = clone_str(name, s.allocator),
		emoji_id = fsnow(m, "emoji_id"),
		emoji_name = clone_str(emoji, s.allocator),
		volume = clamp(vol, 0, 1),
		available = !vhas(m, "available") || fbool(m, "available"),
	}, true;
}

free_sound :: (s: *Store, snd: *Soundboard_Sound) {
	free_str(snd.name, s.allocator);
	free_str(snd.emoji_name, s.allocator);
}

// soundboard_set_guild: a guild's whole list (0: the defaults).
soundboard_set_guild :: (s: *Store, guild_id: Snowflake, list: []V) {
	soundboard_drop_guild(s, guild_id);
	n := 0;
	for list {
		if n >= SOUNDBOARD_MAX_PER_GUILD break;
		snd, ok := parse_sound(s, vmap(it), guild_id);
		if !ok continue;
		snd.guild_id = guild_id;
		if soundboard_sound(s, snd.id) { free_sound(s, *snd); continue; }
		array_add(*s.soundboard, snd);
		n += 1;
	}
	s.soundboard_epoch += 1;
}

soundboard_drop_guild :: (s: *Store, guild_id: Snowflake) {
	k := 0;
	for * s.soundboard {
		if it.guild_id == guild_id { free_sound(s, it); continue; }
		s.soundboard[k] = it.*;
		k += 1;
	}
	s.soundboard.count = k;
}

soundboard_upsert :: (s: *Store, m: etf.Map) {
	snd, ok := parse_sound(s, m, 0);
	if !ok || !snd.guild_id { free_sound(s, *snd); return; }
	old := soundboard_sound(s, snd.id);
	if old {
		free_sound(s, old);
		old.* = snd;
	} else {
		if soundboard_list(s, snd.guild_id).count >= SOUNDBOARD_MAX_PER_GUILD { free_sound(s, *snd); return; }
		array_add(*s.soundboard, snd);
	}
	s.soundboard_epoch += 1;
}

soundboard_remove :: (s: *Store, guild_id: Snowflake, id: Snowflake) {
	for * s.soundboard if it.id == id && it.guild_id == guild_id {
		free_sound(s, it);
		array_ordered_remove_by_index(*s.soundboard, it_index);
		s.soundboard_epoch += 1;
		return;
	}
}

// soundboard_dispatch: the soundboard's gateway events; false for any other.
soundboard_dispatch :: (s: *Store, name: string, d: etf.Map) -> bool {
	if name == {
		case "SOUNDBOARD_SOUNDS"; #through;
		case "GUILD_SOUNDBOARD_SOUNDS_UPDATE";
			gid := fsnow(d, "guild_id");
			if gid && guild_get(s, gid) soundboard_set_guild(s, gid, flist(d, "soundboard_sounds"));
		case "GUILD_SOUNDBOARD_SOUND_CREATE"; #through;
		case "GUILD_SOUNDBOARD_SOUND_UPDATE";
			if guild_get(s, fsnow(d, "guild_id")) soundboard_upsert(s, d);
		case "GUILD_SOUNDBOARD_SOUND_DELETE";
			soundboard_remove(s, fsnow(d, "guild_id"), fsnow(d, "sound_id"));
		case "VOICE_CHANNEL_EFFECT_SEND";
			sid := fsnow(d, "sound_id");
			uid := fsnow(d, "user_id");
			if !sid || uid == s.me || s.effects.count >= SOUNDBOARD_MAX_EFFECTS return true; // emoji-only effects aren't shown yet
			vol := ifx vhas(d, "sound_volume") then cast(float32) vf64(vget(d, "sound_volume")) else 1;
			array_add(*s.effects, .{channel_id = fsnow(d, "channel_id"), user_id = uid, sound_id = sid, volume = clamp(vol, 0, 1)});
		case;
			return false;
	}
	return true;
}

soundboard_free :: (s: *Store) {
	for * s.soundboard free_sound(s, it);
	array_reset(*s.soundboard);
	array_reset(*s.effects);
}
