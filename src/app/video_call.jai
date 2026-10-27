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
SCREEN_MAX_H :: 720; // Go Live without Nitro: 720p30
SCREEN_FPS :: 30;
SCREEN_BITRATE :: 4_000_000;

// A remote video: entries are never freed while the app runs, since a closing
// connection's UDP thread may still deliver a frame; a call's end only resets them.
Remote_Video :: struct {
	mu: locks.Mutex; // decoder and params (UDP thread) vs. reset (UI)
	codec: voice.Video_Codec;
	dec: *media.Video_Decoder;
	params: [3][..]u8;
	nparams: int;
	want_key: bool; // atomic: decoding failed, ask the sender for a keyframe
	pending: media.Video_Frame; // newest decoded frame not yet shown (under vid.mu)
	img: media.Video_Image;     // UI thread
	shown_ms: s64;              // UI thread: when img last changed
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
	// our Go Live
	own_key: string;
	own_conn: *voice.Conn;
	own_version: u64;
	own_target: video.Screen_Target;
	picker_open: bool;
	// the stream we watch
	watch_key: string;
	watch_user: dc.Snowflake;
	watch_conn: *voice.Conn;
	watch_version: u64;
}

vid: Video_App;

cam_sink := false;
stream_sink := true;

// voice_video_options: what every voice connection needs for receiving video.
add_video_options :: (o: *voice.Options, stream: bool) {
	o.video = on_remote_frame;
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
		dc.analytics_permissions_requested(app.client, "video");
		s := *vid.camera;
		sender_init(s, vc_conn(), CAMERA_FPS, CAMERA_BITRATE);
		if video_test("camera") s.capture = video.pattern_start(on_capture_frame, s, CAMERA_W, CAMERA_H, CAMERA_FPS);
		else s.capture = video.camera_start(on_capture_frame, s, CAMERA_W, CAMERA_H, CAMERA_FPS);
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
	ch := dc.channel_get(store(), app.voice_channel);
	gid := ifx ch then ch.guild_id else 0;
	vid.own_key = dc.stream_key(gid, app.voice_channel, store().me, context.allocator);
	vid.own_target = target;
	vid.own_target.name = "";
	dc.stream_create(app.client, gid, app.voice_channel);
}

go_live_stop :: () {
	if !screen_sharing() return;
	conn := vid.screen.conn;
	sender_stop(*vid.screen);
	if conn voice.set_video(conn, false);
	if app.client dc.stream_delete(app.client, vid.own_key);
	voice_release(vid.own_conn);
	vid.own_conn = null;
	vid.own_version = 0;
	free(vid.own_key);
	vid.own_key = "";
}

watch_stream :: (uid: dc.Snowflake) {
	if !net_action() || app.voice_channel == 0 return;
	if vid.watch_user == uid return;
	watch_stop();
	ch := dc.channel_get(store(), app.voice_channel);
	vid.watch_key = dc.stream_key(ifx ch then ch.guild_id else 0, app.voice_channel, uid, context.allocator);
	vid.watch_user = uid;
	dc.stream_watch(app.client, vid.watch_key);
}

watch_stop :: () {
	if vid.watch_key == "" return;
	if app.client dc.stream_delete(app.client, vid.watch_key);
	voice_release(vid.watch_conn);
	vid.watch_conn = null;
	vid.watch_version = 0;
	free(vid.watch_key);
	vid.watch_key = "";
	rv := remote_video(*vid.streams, cast(u64) vid.watch_user);
	remote_reset(rv);
	vid.watch_user = 0;
}

// video_stop_all: leaving the call ends every video (before the voice connection is released).
video_stop_all :: () {
	camera_stop();
	go_live_stop();
	watch_stop();
	for vid.cams remote_reset(it);
	vid.picker_open = false;
}

// The image to draw for a user's camera or stream (y == 0: none).
camera_image :: (uid: dc.Snowflake) -> media.Video_Image {
	if uid == store().me return ifx camera_on() then vid.camera.img else .{};
	vs := table_find_pointer(*store().voice_states, uid);
	if !vs || !vs.self_video return .{};
	locks.guard(*vid.mu);
	found, rv := table_find(*vid.cams, cast(u64) uid);
	return ifx found then rv.img else .{};
}

stream_image :: (uid: dc.Snowflake) -> media.Video_Image {
	if uid == store().me return ifx screen_sharing() then vid.screen.img else .{};
	if uid != vid.watch_user return .{};
	locks.guard(*vid.mu);
	found, rv := table_find(*vid.streams, cast(u64) uid);
	return ifx found then rv.img else .{};
}

// video_frame: every frame. Connects Go Live streams once their servers are
// known, starts screen capture, ends streams that went away, and puts newly
// decoded or captured frames into textures.
video_frame :: () {
	if video_test("") video_test_frame();
	if app.client != null {
		if screen_sharing() {
			info, ver, ok := dc.stream_server_info(app.client, vid.own_key);
			if ok && ver != vid.own_version && !teardown_busy() {
				if vid.own_conn { sender_stop(*vid.screen); voice_release(vid.own_conn); }
				vid.own_conn = stream_connect(info);
				vid.own_version = ver;
			}
			if vid.own_conn && !vid.screen.capture {
				st, _ := voice.state(vid.own_conn);
				if st == .Connected {
					s := *vid.screen;
					sender_init(s, vid.own_conn, SCREEN_FPS, SCREEN_BITRATE);
					if video_test("stream") s.capture = video.pattern_start(on_capture_frame, s, vid.own_target.width, vid.own_target.height, SCREEN_FPS);
					else s.capture = video.screen_start(vid.own_target, on_capture_frame, s, SCREEN_FPS, SCREEN_MAX_H);
					w, h := screen_size(vid.own_target);
					voice.set_video(vid.own_conn, true, w, h, SCREEN_FPS, SCREEN_BITRATE);
				} else if st == .Disconnected {
					go_live_stop();
				}
			}
		}
		if vid.watch_key != "" {
			vs := table_find_pointer(*store().voice_states, vid.watch_user);
			if !vs || !vs.self_stream || vs.channel_id != app.voice_channel {
				watch_stop();
			} else {
				info, ver, ok := dc.stream_server_info(app.client, vid.watch_key);
				if ok && ver != vid.watch_version && !teardown_busy() {
					voice_release(vid.watch_conn);
					vid.watch_conn = stream_connect(info);
					vid.watch_version = ver;
				}
			}
		}
	}
	// a decoder that failed asks its sender for a keyframe (the voice connections do the rate limiting)
	locks.lock(*vid.mu);
	for rv, uid: vid.cams if atomic_swap(*rv.want_key, false) && vc_conn() voice.request_keyframe(vc_conn(), uid);
	for rv, uid: vid.streams if atomic_swap(*rv.want_key, false) && vid.watch_conn voice.request_keyframe(vid.watch_conn, uid);

	for vid.cams show_pending(*it.pending, *it.img, *it.shown_ms);
	for vid.streams show_pending(*it.pending, *it.img, *it.shown_ms);
	locks.unlock(*vid.mu);
	for s: (*Sender).[*vid.camera, *vid.screen] {
		locks.lock(*s.mu);
		ms: s64;
		show_pending(*s.pending, *s.img, *ms);
		locks.unlock(*s.mu);
	}
}

video_shutdown :: () {
	video_stop_all();
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
	if video_test("watch") && vid.watch_key == "" {
		for vs, uid: store().voice_states if vs.channel_id == app.voice_channel && vs.self_stream && uid != store().me { watch_stream(uid); break; }
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
	report("watch", vid.watch_conn);
	locks.guard(*vid.mu);
	for rv, uid: vid.cams if rv.img.y print("[video-test] showing camera of % (%x%)\n", uid, rv.img.size[0], rv.img.size[1], to_standard_error = true);
	for rv, uid: vid.streams if rv.img.y print("[video-test] showing stream of % (%x%)\n", uid, rv.img.size[0], rv.img.size[1], to_standard_error = true);
}

vc_conn :: () -> *voice.Conn { return voice_conn(); }

send_voice_state :: () {
	if app.client == null || app.voice_channel == 0 return;
	ch := dc.channel_get(store(), app.voice_channel);
	dc.voice_set_state(app.client, ifx ch then ch.guild_id else 0, app.voice_channel, app.self_mute || app.self_deaf, app.self_deaf, camera_on());
}

stream_connect :: (info: dc.Voice_Server_Info) -> *voice.Conn {
	o := voice.Options.{no_audio_devices = voice_headless() || !voice_audio_ready()};
	add_video_options(*o, true);
	return voice.voice_connect(voice.Voice_Server_Info.{
		endpoint = info.endpoint,
		token = info.token,
		guild_or_channel_id = cast(u64) info.guild_or_channel_id,
		user_id = cast(u64) info.user_id,
		session_id = info.session_id,
		channel_id = cast(u64) info.channel_id,
		stream = true,
		user_agent = app.client.id.platform.browser_user_agent,
		accept_language = app.client.id.platform.accept_language
	}, o);
}

// The encoded size for a screen target: its aspect, at most SCREEN_MAX_H tall, even sides.
screen_size :: (t: video.Screen_Target) -> int, int {
	w, h := max(t.width, 2), max(t.height, 2);
	if h > SCREEN_MAX_H { w = w * SCREEN_MAX_H / h; h = SCREEN_MAX_H; }
	return w & ~1, h & ~1;
}

remote_video :: (t: *Table(u64, *Remote_Video), uid: u64) -> *Remote_Video {
	locks.guard(*vid.mu);
	found, rv := table_find(t, uid);
	if found return rv;
	rv = New(Remote_Video);
	table_set(t, uid, rv);
	return rv;
}

// remote_reset drops the decoder and the shown frame (UI thread).
remote_reset :: (rv: *Remote_Video) {
	{
		locks.guard(*rv.mu);
		media.video_decoder_destroy(rv.dec);
		rv.dec = null;
		rv.nparams = 0;
	}
	locks.guard(*vid.mu);
	media.video_frame_release(*rv.pending);
	image_free(*rv.img);
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
	if codec != .H264 && codec != .H265 return;
	stream := (cast(*bool) data).*;
	rv := remote_video(ifx stream then *vid.streams else *vid.cams, uid);
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
	frames: [..]media.Video_Frame;
	frames.allocator = temp;
	ok := rv.dec && avcc.count && media.video_decode(rv.dec, avcc, 0, 0, 0);
	if ok media.video_decoder_take(rv.dec, *frames);
	locks.unlock(*rv.mu);
	if !ok {
		if avcc.count atomic_store(*rv.want_key, true);
		return;
	}
	if !frames.count return;
	for 0..frames.count - 2 media.video_frame_release(*frames[it]);
	locks.lock(*vid.mu);
	media.video_frame_release(*rv.pending);
	rv.pending = peek(frames);
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
on_capture_frame :: (user: *void, pixbuf: *void, width: int, height: int) {
	s := cast(*Sender) user;
	{
		locks.guard(*s.mu);
		media.video_frame_release(*s.pending);
		s.pending = media.video_frame_from_pixbuf(pixbuf);
	}
	platform.request_frame();
	codec := voice.video_codec(s.conn);
	if codec != .H264 && codec != .H265 return; // not negotiated yet (or VP8 / AV1, which we don't encode)
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
