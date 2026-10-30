// Video in calls: remote cameras and the Go Live stream we watch, decoded as
// they arrive (voice.Options.video, on a connection's UDP thread) and shown by
// the call view; our camera (on the voice connection) and our screen (on our
// own Go Live connection), captured and encoded by src/video.
//
// Go Live: op 18 STREAM_CREATE (ours) or op 20 STREAM_WATCH (theirs), then
// STREAM_CREATE + STREAM_SERVER_UPDATE give a voice server for the stream; a
// second voice.Conn (info.stream) carries it. op 19 STREAM_DELETE ends either.

CAMERA_W :: 1280;
CAMERA_H :: 720;
CAMERA_FPS :: 30;
CAMERA_BITRATE :: 2_500_000;
SCREEN_BITRATE :: 4_000_000; // at 720p30; other settings scale it (go_live_bitrate)

// A remote video: entries are never freed while the app runs, since a closing
// connection's UDP thread may still deliver a frame; a call's end only resets them.
Remote_Video :: struct {
	mu: locks.Mutex; // decoder and params (UDP thread) vs. reset (UI)
	codec: voice.Video_Codec;
	dec: *media.Video_Decoder;
	sw: *media.Sw_Decoder; // VP8, AV1
	params: [3][..]u8;
	nparams: int;
	want_key: bool; // atomic: decoding failed, ask the sender for a keyframe
	pending: media.Video_Frame; // newest decoded frame not yet shown (under vid.mu)
	img: media.Video_Image;     // UI thread
	shown_ms: s64;              // UI thread: when img last changed
	fps_frames: int;            // UI thread: frames shown since fps_since, and the last whole second's rate
	fps_since: s64;
	fps: int;
}

// An outgoing video: the capture's frames are previewed and encoded on its
// thread, the encoder's output sent on the connection.
Sender :: struct {
	mu: locks.Mutex;
	conn: *voice.Conn;
	capture: *video.Capture;
	enc: *video.Encoder;
	codec: voice.Video_Codec;
	fps, bitrate: int;
	start: Apollo_Time;
	pending: media.Video_Frame; // preview (under mu)
	img: media.Video_Image;     // UI thread
}

Video_App :: struct {
	mu: locks.Mutex; // tables, pending frames
	cams: Table(u64, *Remote_Video);    // user -> camera
	streams: Table(u64, *Remote_Video); // streamer -> Go Live video
	camera: Sender;
	screen: Sender;
	preview: Sender; // Settings > Voice & Video "Test Video"; never sends
	// our Go Live
	own_key: string;
	own_conn: *voice.Conn;
	own_version: u64;
	own_target: video.Screen_Target;
	picker_open: bool;
	picker_test: bool; // the `screen_picker` script command: made-up targets, never the real screens
	go_height := 720; // Go Live settings: 480, 720, 1080, 1440, or 0 for the source's own height
	go_fps := 30;     // 15, 30 or 60
	// the streams we watch, each on a voice connection of its own, in the order they were opened
	watches: [..]Watch;
}

vid: Video_App;

cam_sink := false;
stream_sink := true;

// voice_video_options: what every voice connection needs for receiving video.
add_video_options :: (o: *voice.Options, stream: bool) {
	o.video = on_remote_frame;
	o.no_hevc_decode = !media.video_codec_supported(.HEVC);
	o.hevc_encode = video.encoder_supported(.H265);
	o.callback_data = ifx stream then *stream_sink else *cam_sink;
}

camera_on :: () -> bool { return vid.camera.capture != null; }
screen_sharing :: () -> bool { return vid.own_key != ""; }

// camera_toggle: the call view's camera button. Needs a connected voice call.
camera_toggle :: () {
	if !net_action() return;
	if camera_on() {
		camera_stop();
	} else {
		if vc_conn() == null || (!video_test("camera") && !video.camera_supported()) return;
		sender_stop(*vid.preview); // one capture per camera: a second open takes it from the first
		dc.analytics_permissions_requested(call_client(), "video");
		s := *vid.camera;
		sender_init(s, vc_conn(), CAMERA_FPS, CAMERA_BITRATE);
		if video_test("camera") s.capture = video.pattern_start(on_capture_frame, s, CAMERA_W, CAMERA_H, CAMERA_FPS);
		else s.capture = video.camera_start(on_capture_frame, s, CAMERA_W, CAMERA_H, CAMERA_FPS, vs.camera);
		if !s.capture return;
		voice.set_video(s.conn, true, CAMERA_W, CAMERA_H, CAMERA_FPS, CAMERA_BITRATE);
	}
	send_voice_state();
}

camera_stop :: () {
	if !camera_on() return;
	conn := vid.camera.conn;
	sender_stop(*vid.camera);
	if conn voice.set_video(conn, false);
}

// go_live_start: STREAM_CREATE for the call we are in; capture starts once
// the stream's voice connection is up (video_frame).
go_live_start :: (target: video.Screen_Target) {
	if !net_action() || app.voice_channel == 0 || screen_sharing() return;
	ch := dc.channel_get(call_store(), app.voice_channel);
	gid := ifx ch then ch.guild_id else 0;
	vid.own_key = dc.stream_key(gid, app.voice_channel, call_store().me, context.allocator);
	vid.own_target = target;
	vid.own_target.name = "";
	dc.stream_create(call_client(), gid, app.voice_channel);
}

go_live_stop :: () {
	if !screen_sharing() return;
	conn := vid.screen.conn;
	sender_stop(*vid.screen);
	if conn voice.set_video(conn, false);
	if call_client() dc.stream_delete(call_client(), vid.own_key);
	voice_release(vid.own_conn);
	vid.own_conn = null;
	vid.own_version = 0;
	free(vid.own_key);
	vid.own_key = "";
}

Watch :: struct {
	key: string; // heap ("" in a script's made-up watch)
	user: dc.Snowflake;
	conn: *voice.Conn;
	version: u64;
}

MAX_WATCHES :: 4; // a fifth stream takes the place of the one opened first

watch_of :: (uid: dc.Snowflake) -> *Watch {
	for * vid.watches if it.user == uid return it;
	return null;
}

// watch_stream: start watching uid's stream, beside the ones already watched.
watch_stream :: (uid: dc.Snowflake) {
	if !net_action() || app.voice_channel == 0 || watch_of(uid) return;
	if vid.watches.count >= MAX_WATCHES watch_stop(vid.watches[0].user);
	ch := dc.channel_get(call_store(), app.voice_channel);
	w := array_add(*vid.watches);
	w.* = .{key = dc.stream_key(ifx ch then ch.guild_id else 0, app.voice_channel, uid, context.allocator), user = uid};
	dc.stream_watch(call_client(), w.key);
}

// watch_stop: stop watching uid's stream (0: every one).
watch_stop :: (uid: dc.Snowflake = 0) {
	i := 0;
	while i < vid.watches.count {
		w := vid.watches[i];
		if uid && w.user != uid { i += 1; continue; }
		if w.key && call_client() dc.stream_delete(call_client(), w.key);
		voice_release(w.conn);
		free(w.key);
		remote_reset(remote_video(*vid.streams, cast(u64) w.user));
		array_ordered_remove_by_index(*vid.watches, i);
	}
}

// video_stop_all: leaving the call ends every video (before the voice connection is released).
video_stop_all :: () {
	camera_stop();
	go_live_stop();
	watch_stop();
	for vid.cams remote_reset(it);
	vid.picker_open = false;
}

// The Voice & Video page's camera test. Headless runs get the test pattern, never the real camera.
camera_test_toggle :: () {
	if vid.preview.capture { sender_stop(*vid.preview); return; }
	headless := platform.is_headless();
	if camera_on() || (!headless && !video.camera_supported()) return;
	s := *vid.preview;
	sender_init(s, null, CAMERA_FPS, 0);
	if headless s.capture = video.pattern_start(on_capture_frame, s, CAMERA_W, CAMERA_H, CAMERA_FPS);
	else s.capture = video.camera_start(on_capture_frame, s, CAMERA_W, CAMERA_H, CAMERA_FPS, vs.camera);
}

// camera_switch: another camera was picked; the call's camera and the test move to it. The encoder is
// remade at the new camera's size by the next frame.
camera_switch :: () {
	if platform.is_headless() return; // the test pattern stays
	for s: (*Sender).[*vid.camera, *vid.preview] if s.capture {
		video.capture_stop(s.capture);
		video.encoder_destroy(s.enc);
		s.enc = null;
		s.codec = .None;
		s.capture = video.camera_start(on_capture_frame, s, CAMERA_W, CAMERA_H, CAMERA_FPS, vs.camera);
	}
}

// What the camera test shows: the call's camera while it's on, else the test's.
camera_test_image :: () -> media.Video_Image {
	return ifx camera_on() then vid.camera.img else ifx vid.preview.capture then vid.preview.img else .{};
}

// The image to draw for a user's camera or stream (y == 0: none).
camera_image :: (uid: dc.Snowflake) -> media.Video_Image {
	if uid == call_store().me return ifx camera_on() then vid.camera.img else .{};
	vs := table_find_pointer(*call_store().voice_states, uid);
	if !vs || !vs.self_video return .{};
	locks.guard(*vid.mu);
	found, rv := table_find(*vid.cams, cast(u64) uid);
	return ifx found then rv.img else .{};
}

stream_image :: (uid: dc.Snowflake) -> media.Video_Image {
	if uid == call_store().me return ifx screen_sharing() then vid.screen.img else .{};
	if !watch_of(uid) return .{};
	locks.guard(*vid.mu);
	found, rv := table_find(*vid.streams, cast(u64) uid);
	return ifx found then rv.img else .{};
}

// video_frame: every frame. Connects Go Live streams once their servers are
// known, starts screen capture, ends streams that went away, and puts newly
// decoded or captured frames into textures.
video_frame :: () {
	if video_test("") video_test_frame();
	if call_client() != null {
		if screen_sharing() {
			info, ver, ok := dc.stream_server_info(call_client(), vid.own_key);
			if ok && ver != vid.own_version && !teardown_busy() {
				if vid.own_conn { sender_stop(*vid.screen); voice_release(vid.own_conn); }
				vid.own_conn = stream_connect(info, own = true);
				vid.own_version = ver;
			}
			if vid.own_conn && !vid.screen.capture {
				st, _ := voice.state(vid.own_conn);
				if st == .Connected {
					s := *vid.screen;
					w, h := screen_size(vid.own_target);
					sender_init(s, vid.own_conn, vid.go_fps, go_live_bitrate(w, h));
					if video_test("stream") s.capture = video.pattern_start(on_capture_frame, s, vid.own_target.width, vid.own_target.height, vid.go_fps);
					else s.capture = video.screen_start(vid.own_target, on_capture_frame, s, vid.go_fps, h, on_share_audio);
					voice.set_video(vid.own_conn, true, w, h, vid.go_fps, go_live_bitrate(w, h));
				} else if st == .Disconnected {
					go_live_stop();
				}
			}
		}
		for < vid.watches {
			if !it.key continue;
			vs := table_find_pointer(*call_store().voice_states, it.user);
			if !vs || !vs.self_stream || vs.channel_id != app.voice_channel {
				watch_stop(it.user);
				continue;
			}
			info, ver, ok := dc.stream_server_info(call_client(), it.key);
			if ok && ver != it.version && !teardown_busy() {
				voice_release(it.conn);
				vid.watches[it_index].conn = stream_connect(info);
				vid.watches[it_index].version = ver;
			}
		}
	}
	// a decoder that failed asks its sender for a keyframe (the voice connections do the rate limiting)
	locks.lock(*vid.mu);
	for rv, uid: vid.cams if atomic_swap(*rv.want_key, false) && vc_conn() voice.request_keyframe(vc_conn(), uid);
	for rv, uid: vid.streams if atomic_swap(*rv.want_key, false) {
		w := watch_of(cast(dc.Snowflake) uid);
		if w && w.conn voice.request_keyframe(w.conn, uid);
	}

	for vid.cams show_pending(*it.pending, *it.img, *it.shown_ms);
	for vid.streams {
		before := it.shown_ms;
		show_pending(*it.pending, *it.img, *it.shown_ms);
		if it.shown_ms == before continue;
		it.fps_frames += 1;
		if it.shown_ms - it.fps_since >= 1000 { it.fps, it.fps_frames, it.fps_since = cast(int) (it.fps_frames * 1000 / max(1, it.shown_ms - it.fps_since)), 0, it.shown_ms; }
	}
	locks.unlock(*vid.mu);
	err := video.capture_error(vid.camera.capture);
	if err {
		camera_stop();
		send_voice_state();
		toast_show(err, false);
	}
	if video.capture_error(vid.screen.capture) go_live_stop(); // stopped from outside (the macOS menu bar)
	if vid.preview.capture {
		err = video.capture_error(vid.preview.capture);
		if err toast_show(err, false);
		if err || !app.settings_open || settings_page != "Voice & Video" sender_stop(*vid.preview);
	}
	for s: (*Sender).[*vid.camera, *vid.screen, *vid.preview] {
		locks.lock(*s.mu);
		ms: s64;
		show_pending(*s.pending, *s.img, *ms);
		locks.unlock(*s.mu);
	}
}

video_shutdown :: () {
	video_stop_all();
	sender_stop(*vid.preview);
	for vid.cams remote_free(it);
	for vid.streams remote_free(it);
	deinit(*vid.cams);
	deinit(*vid.streams);
}

// FASTCORD_VIDEO_TEST=camera,stream,watch (live tests): a synthetic pattern instead of the
// camera / screen, turned on as soon as the call connects; "watch" watches the first stream
// in the channel. Video stats go to stderr every 2 s.
video_test :: (what: string) -> bool {
	v := env_var("FASTCORD_VIDEO_TEST");
	return ifx what then contains(v, what) else v != "";
}

// go_live_allowed: whether a resolution (0: Source) and frame rate may be streamed in this call, as the
// client's ApplicationStreamSettingRequirements: up to 720p30 for anyone; 480p60 and 720p60 with Nitro or a
// server at boost level 1; 1080p and 1440p with Nitro or level 2; Source with full Nitro only. Settings that
// aren't allowed are hidden, never offered. A hosted server allows them all.
go_live_allowed :: (height: int, fps: int) -> bool {
	cl := call_client();
	if cl && cl.cfg.hosted.host != "" return true;
	u := ifx cl then dc.user_get(*cl.store, cl.store.me);
	premium := ifx u then u.premium_type else 0;
	high := premium == 2;               // Nitro: streamHighQuality
	mid := premium == 1 || premium == 2; // Nitro and Nitro Classic: streamMidQuality; Basic (3) neither
	ch := dc.channel_get(call_store(), app.voice_channel);
	g := ifx ch && ch.guild_id then dc.guild_get(call_store(), ch.guild_id);
	boost := ifx g then g.premium_tier else 0;
	if height == 0 return high;
	if height >= 1080 return mid || boost >= 2;
	if fps >= 60 return mid || boost >= 1;
	return true;
}

// go_live_set: new settings (a frame rate the resolution doesn't allow drops to 30); a running stream restarts
// its capture and encoder with them.
go_live_set :: (height: int, fps: int) {
	if !go_live_allowed(height, fps) fps = 30;
	if vid.go_height == height && vid.go_fps == fps return;
	vid.go_height, vid.go_fps = height, fps;
	if screen_sharing() && vid.screen.capture sender_stop(*vid.screen); // video_frame starts it again
}

// watched_stream_quality: "720p 30FPS" for the stream we watch (the first one), once frames arrive.
watched_stream_quality :: () -> string {
	if !vid.watches.count return "";
	locks.guard(*vid.mu);
	found, rv := table_find(*vid.streams, cast(u64) vid.watches[0].user);
	if !found || !rv.img.y return "";
	return ifx rv.fps then tprint("%p %FPS", rv.img.size[1], rv.fps) else tprint("%p", rv.img.size[1]);
}

#scope_file

vt_next_log: s64;
vt_started_camera, vt_started_stream: bool;

video_test_frame :: () {
	conn := vc_conn();
	if !conn || voice.state(conn) != .Connected return;
	if video_test("camera") && !vt_started_camera { vt_started_camera = true; camera_toggle(); }
	if video_test("stream") && !vt_started_stream {
		vt_started_stream = true;
		go_live_start(.{name = "test pattern", width = 1280, height = 720});
	}
	now := wall_ms();
	if video_test("watch") && !vid.watches.count {
		for vs, uid: call_store().voice_states if vs.channel_id == app.voice_channel && vs.self_stream && uid != call_store().me { watch_stream(uid); break; }
	}
	if now < vt_next_log return;
	vt_next_log = now + 2000;
	report :: (name: string, c: *voice.Conn) {
		if !c return;
		st := voice.get_stats(c);
		state, code := voice.state(c);
		print("[video-test] % state=% close=% codec=% sent=% recv=% plis=% pkts_out=% pkts_in=% udp_in=% bytes_in=% other_pt=% e2ee=% dave_fail=%\n", name, state, code, voice.video_codec(c),
			st.video_frames_sent, st.video_frames_received, st.plis_sent, st.packets_sent, st.packets_received, st.udp_datagrams, st.bytes_received, st.other_pt, voice.e2ee_status(c,, temp).active, st.e2ee_failures, to_standard_error = true);
	}
	report("voice", conn);
	report("own-stream", vid.own_conn);
	for vid.watches report("watch", it.conn);
	locks.guard(*vid.mu);
	for rv, uid: vid.cams if rv.img.y print("[video-test] showing camera of % (%x%)\n", uid, rv.img.size[0], rv.img.size[1], to_standard_error = true);
	for rv, uid: vid.streams if rv.img.y print("[video-test] showing stream of % (%x%)\n", uid, rv.img.size[0], rv.img.size[1], to_standard_error = true);
}

vc_conn :: () -> *voice.Conn { return voice_conn(); }

send_voice_state :: () {
	if call_client() == null || app.voice_channel == 0 return;
	ch := dc.channel_get(call_store(), app.voice_channel);
	dc.voice_set_state(call_client(), ifx ch then ch.guild_id else 0, app.voice_channel, app.self_mute || app.self_deaf, app.self_deaf, camera_on());
}

stream_connect :: (info: dc.Voice_Server_Info, own := false) -> *voice.Conn {
	o := voice.Options.{no_audio_devices = voice_headless() || !voice_audio_ready()};
	add_video_options(*o, true);
	if own {
		share_reset();
		o.capture = share_pull;
	}
	o.hosted = hosted_voice(call_client());
	return voice.voice_connect(voice.Voice_Server_Info.{
		endpoint = info.endpoint,
		token = info.token,
		guild_or_channel_id = cast(u64) info.guild_or_channel_id,
		user_id = cast(u64) info.user_id,
		session_id = info.session_id,
		channel_id = cast(u64) info.channel_id,
		stream = true,
		user_agent = call_client().id.platform.browser_user_agent,
		accept_language = call_client().id.platform.accept_language
	}, o);
}

// The encoded size for a screen target: its aspect, at most the chosen height (go_height), even sides.
screen_size :: (t: video.Screen_Target) -> int, int {
	w, h := max(t.width, 2), max(t.height, 2);
	if vid.go_height && h > vid.go_height { w = w * vid.go_height / h; h = vid.go_height; }
	return w & ~1, h & ~1;
}

// go_live_bitrate: 4 Mbit/s at 720p30, in proportion to pixels and frames, between 1.5 and 6 Mbit/s (a
// hosted server's cap per member).
go_live_bitrate :: (w: int, h: int) -> int {
	return clamp(cast(int) (cast(float64) SCREEN_BITRATE * (w * h) / (1280 * 720) * vid.go_fps / 30), 1_500_000, 6_000_000);
}

remote_video :: (t: *Table(u64, *Remote_Video), uid: u64) -> *Remote_Video {
	locks.guard(*vid.mu);
	found, rv := table_find(t, uid);
	if found return rv;
	rv = New(Remote_Video);
	table_set(t, uid, rv);
	return rv;
}

// Soundshare: the shared screen's sound (video.Audio_Proc, on the capture's queue) waits here for our
// stream's voice connection, which takes a 20 ms frame per tick (voice.Options.capture). At most
// SHARE_MAX samples wait: past that the oldest go, so a stalled connection never builds up delay.
SHARE_MAX :: 48000 / 5;
share: struct {
	mu: locks.Mutex;
	buf: [..]float32;
};

share_reset :: () {
	locks.guard(*share.mu);
	share.buf.count = 0;
}

on_share_audio :: (user: *void, pcm: []float32) {
	locks.guard(*share.mu);
	array_add(*share.buf, ..pcm);
	if share.buf.count > SHARE_MAX {
		drop := share.buf.count - SHARE_MAX;
		memcpy(share.buf.data, share.buf.data + drop, SHARE_MAX * size_of(float32));
		share.buf.count = SHARE_MAX;
	}
}

share_pull :: (data: *void, out: []float32) -> int {
	locks.guard(*share.mu);
	n := min(out.count, share.buf.count);
	memcpy(out.data, share.buf.data, n * size_of(float32));
	for n..share.buf.count - 1 share.buf[it - n] = share.buf[it];
	share.buf.count -= n;
	return n;
}

// remote_reset drops the decoder and the shown frame (UI thread).
remote_reset :: (rv: *Remote_Video) {
	{
		locks.guard(*rv.mu);
		media.video_decoder_destroy(rv.dec);
		media.sw_decoder_destroy(rv.sw);
		rv.dec, rv.sw = null, null;
		rv.nparams = 0;
	}
	locks.guard(*vid.mu);
	media.video_frame_release(*rv.pending);
	image_free(*rv.img);
	rv.fps, rv.fps_frames, rv.fps_since = 0, 0, 0;
}

remote_free :: (rv: *Remote_Video) {
	remote_reset(rv);
	for * rv.params array_free(it.*);
	free(rv);
}

image_free :: (img: *media.Video_Image) {
	if img.y gfx.texture_destroy(img.y);
	if img.cbcr gfx.texture_destroy(img.cbcr);
	img.* = .{};
}

// show_pending turns a waiting frame into textures (UI thread, under the frame's lock).
show_pending :: (pending: *media.Video_Frame, img: *media.Video_Image, shown_ms: *s64) {
	if !pending.pixbuf return;
	y, uv, ok := media.video_frame_textures(pending);
	if ok {
		image_free(img);
		img.* = .{y = y, cbcr = uv, size = .[pending.width, pending.height], yuv = pending.yuv};
		shown_ms.* = wall_ms();
	}
	media.video_frame_release(pending);
}

// on_remote_frame: voice.Options.video, on a connection's UDP thread.
on_remote_frame :: (data: *void, uid: u64, codec: voice.Video_Codec, au: []u8, keyframe: bool) {
	if codec == .None return;
	stream := (cast(*bool) data).*;
	rv := remote_video(ifx stream then *vid.streams else *vid.cams, uid);
	frames: [..]media.Video_Frame;
	frames.allocator = temp;
	if codec == .VP8 || codec == .AV1 {
		// in software (libvpx, dav1d): a new decoder at each keyframe after a codec change or failure
		locks.lock(*rv.mu);
		if keyframe && (!rv.sw || rv.codec != codec) {
			media.sw_decoder_destroy(rv.sw);
			rv.sw = media.sw_decoder_create(ifx codec == .VP8 then media.Codec.VP8 else .AV1);
			rv.codec = codec;
		}
		ok := rv.sw && rv.codec == codec && media.sw_decode(rv.sw, au, *frames);
		locks.unlock(*rv.mu);
		if !ok { atomic_store(*rv.want_key, true); return; }
		show_latest(rv, frames);
		return;
	}
	h265 := codec == .H265;
	params: [3][]u8;
	np := 0;
	avcc: [..]u8;
	avcc.allocator = temp;
	array_reserve(*avcc, au.count + 16);
	for voice.annexb_nals(au) {
		nal := array_view(au, it.start, it.end - it.start);
		if !nal.count continue;
		t := voice.nal_type(codec, nal[0]);
		is_param := ifx h265 then t >= 32 && t <= 34 else t == 7 || t == 8;
		if is_param {
			if np < 3 { params[np] = nal; np += 1; }
			continue;
		}
		if (h265 && t == 35) || (!h265 && t == 9) continue; // access unit delimiters
		n: [4]u8;
		voice.put_u32(n, cast(u32) nal.count);
		array_add(*avcc, ..n);
		array_add(*avcc, ..nal);
	}
	locks.lock(*rv.mu);
	if keyframe && np && (!rv.dec || rv.codec != codec || !same_params(rv, array_view(params, 0, np))) {
		media.video_decoder_destroy(rv.dec);
		rv.dec = media.video_decoder_create_from_params(ifx h265 then media.Codec.HEVC else .H264, array_view(params, 0, np));
		rv.codec = codec;
		for * rv.params { it.count = 0; if it_index < np array_add(it, ..params[it_index]); }
		rv.nparams = np;
	}
	ok := rv.dec && avcc.count && media.video_decode(rv.dec, avcc, 0, 0, 0);
	if ok media.video_decoder_take(rv.dec, *frames);
	locks.unlock(*rv.mu);
	if !ok {
		if avcc.count atomic_store(*rv.want_key, true);
		return;
	}
	show_latest(rv, frames);
}

// show_latest keeps the newest decoded frame for the UI thread and drops the rest.
show_latest :: (rv: *Remote_Video, frames: []media.Video_Frame) {
	if !frames.count return;
	for 0..frames.count - 2 media.video_frame_release(*frames[it]);
	locks.lock(*vid.mu);
	media.video_frame_release(*rv.pending);
	rv.pending = frames[frames.count - 1];
	locks.unlock(*vid.mu);
	platform.request_frame();
}

same_params :: (rv: *Remote_Video, params: [][]u8) -> bool {
	if rv.nparams != params.count return false;
	for params if rv.params[it_index].count != it.count || memcmp(rv.params[it_index].data, it.data, it.count) != 0 return false;
	return true;
}

sender_init :: (s: *Sender, conn: *voice.Conn, fps: int, bitrate: int) {
	s.conn = conn;
	s.fps, s.bitrate = fps, bitrate;
	s.start = current_time_monotonic();
}

// sender_stop: capture first (no more frames), then the encoder (flushes its output), UI thread.
sender_stop :: (s: *Sender) {
	video.capture_stop(s.capture);
	s.capture = null;
	video.encoder_destroy(s.enc);
	s.enc = null;
	s.conn = null;
	s.codec = .None;
	locks.guard(*s.mu);
	media.video_frame_release(*s.pending);
	image_free(*s.img);
}

// on_capture_frame: video.Frame_Proc, on the capture's queue. Only the preview
// is shared with the UI (under mu); the encoder fields belong to this queue
// until sender_stop has stopped the capture.
on_capture_frame :: (user: *void, camera_frame: *void, width: int, height: int) {
	s := cast(*Sender) user;
	pixbuf := camera_frame;
	if vs.camera_blur && s != *vid.screen {
		blurred := video.blur_background(camera_frame);
		if blurred pixbuf = blurred;
	}
	defer if pixbuf != camera_frame video.pixbuf_release(pixbuf);
	{
		locks.guard(*s.mu);
		media.video_frame_release(*s.pending);
		s.pending = media.video_frame_from_pixbuf(pixbuf);
	}
	platform.request_frame();
	if !s.conn return; // the camera test
	codec := voice.video_codec(s.conn);
	if codec == .None return; // not negotiated yet
	// The server picks one codec for the whole call, also one we can't encode (H.265 on Windows and Linux,
	// VP8, AV1). Ask it for another (op 14), and send H.264 until it answers: receivers pick the decoder by
	// payload type, and every client decodes H.264.
	if codec != .H264 && !(codec == .H265 && video.encoder_supported(.H265)) {
		voice.cannot_encode(s.conn, codec);
		codec = .H264;
	}
	if s.enc && s.codec != codec { video.encoder_destroy(s.enc); s.enc = null; }
	if !s.enc {
		vcodec := ifx codec == .H265 then video.Video_Codec.H265 else .H264;
		if !video.encoder_supported(vcodec) return;
		s.codec = codec;
		s.enc = video.encoder_create(vcodec, width & ~1, height & ~1, s.fps, s.bitrate, on_encoded, s);
		if !s.enc return;
	}
	pts := cast,no_check(u32) (to_nanoseconds(current_time_monotonic() - s.start) * 9 / 100_000);
	video.encoder_encode(s.enc, pixbuf, pts, voice.take_keyframe_request(s.conn));
}

// on_encoded: video.Encoded_Proc, on the encoder's thread. The sender's
// connection outlives its encoder (sender_stop destroys the encoder first).
on_encoded :: (user: *void, annexb: []u8, keyframe: bool, pts_90k: u32) {
	s := cast(*Sender) user;
	if s.conn voice.send_video(s.conn, s.codec, annexb, pts_90k);
}
